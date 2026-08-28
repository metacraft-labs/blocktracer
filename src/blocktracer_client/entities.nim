## Blocks and transactions, read at a pinned generation.
##
## A transaction is assembled from the three layers the contract separates and
## never merges on the producer side
## ([Static-Site-Architecture.md](../../../codetracer-specs/BlockTracer/Static-Site-Architecture.md)
## §2.3, §2.3a, §2.3b):
##
##   1. `/d/{chain}/tx/**`            immutable facts, permanent
##   2. `/d/{chain}/g/{gen}/txstate/` canonicality + finality, generation-scoped
##   3. `/d/{chain}/ts/{v}/**`        trace availability, overlay-versioned
##
## They are kept as three fields rather than flattened into one row, because
## which layer a fact came from is what tells a consumer whether it can change:
## a flattened `finality` next to a `hash` invites caching the pair, and a
## pointer object cached across a navigation is the classic explorer bug §5.1
## names.

import std/[algorithm, json, strutils]
import ./store
import ./paths
import ./decode
import ./session

type
  ReadOutcome* = enum
    roFound = "found"
    roNotFound = "notFound"
    roMalformed = "malformed"

  BlockResult* = object
    case outcome*: ReadOutcome
    of roFound: detail*: BlockDetail
    else: reason*: string

  TransactionView* = object
    ## Everything the three layers say about one transaction, with each layer's
    ## presence explicit. `hasSelection = false` means the overlay carries no
    ## entry for this transaction — which is not the same as `availability:
    ## absent`, and conflating the two is exactly how "absent" becomes "a failed
    ## fetch".
    chain*: string
    hash*: string
    facts*: TransactionFacts
    hasState*: bool
    canonical*: bool
    finality*: string
    hasSelection*: bool
    selection*: TraceSelection

  TransactionResult* = object
    case outcome*: ReadOutcome
    of roFound: view*: TransactionView
    else: reason*: string

proc blockDetail*(store: ObjectStore, session: ChainSession,
                  blockHash: string): BlockResult =
  ## Block details are content-addressed and generation-independent (§2), so
  ## this read does not consult the pinned generation at all — and a reorg
  ## therefore does not invalidate it (§3.4).
  let r = store.getJson(blockPath(session.chain, blockHash))
  if not r.found:
    return BlockResult(outcome: roNotFound, reason: blockHash & " is not in this tree")
  if r.error.len > 0:
    return BlockResult(outcome: roMalformed, reason: r.error)
  try:
    BlockResult(outcome: roFound, detail: decodeBlockDetail(r.node))
  except ContractDecodeError as e:
    BlockResult(outcome: roMalformed, reason: e.msg)

proc blockRefsNewestFirst*(store: ObjectStore,
                           session: ChainSession): seq[BlockRef] =
  ## The generation's blocks, newest first, from the sealed root's height map.
  ##
  ## The height map is read rather than every block detail: the map is one
  ## object per epoch and states the height, so ordering a chain's blocks costs
  ## O(epochs) reads instead of O(blocks). A consumer that wants the details
  ## asks for the ones it will show.
  var seen: seq[string]
  for rel in session.root.heightPaths:
    let r = store.getJson(rel)
    if not r.found or r.error.len > 0 or r.node.isNil: continue
    if r.node.kind != JObject or not r.node.hasKey("heights"): continue
    let hs = r.node["heights"]
    if hs.kind != JObject: continue
    for heightStr, hashNode in hs:
      if hashNode.kind != JString: continue
      let h = hashNode.getStr
      if h in seen: continue
      seen.add h
      var height = 0
      try: height = parseInt(heightStr)
      except ValueError: continue
      result.add BlockRef(height: height, hash: h)
  result.sort(proc(a, b: BlockRef): int = cmp(b.height, a.height))

proc transaction*(store: ObjectStore, session: ChainSession,
                  txHash: string): TransactionResult =
  ## Assemble the three layers. A missing txstate or overlay is recorded as
  ## absent-layer data, never as a failure of the transaction itself: the facts
  ## are permanent and the other two are scoped to things that move.
  let f = store.getJson(txFactsPath(session.chain, txHash))
  if not f.found:
    return TransactionResult(outcome: roNotFound,
      reason: txHash & " is not in this tree")
  if f.error.len > 0:
    return TransactionResult(outcome: roMalformed, reason: f.error)

  var v = TransactionView(chain: session.chain, hash: txHash)
  try:
    v.facts = decodeTransactionFacts(f.node)
  except ContractDecodeError as e:
    return TransactionResult(outcome: roMalformed, reason: e.msg)

  let st = store.getJson(txStatePath(session.chain, session.generation, txHash))
  if st.found and st.error.len == 0 and st.node.kind == JObject:
    v.hasState = true
    v.canonical = st.node{"canonical"}.getBool
    v.finality = st.node{"finality"}.getStr

  let ov = store.getJson(
    traceSelectionPath(session.chain, session.traceSelectionVersion, txHash))
  if ov.found and ov.error.len == 0:
    try:
      v.selection = decodeTraceSelection(ov.node)
      v.hasSelection = true
    except ContractDecodeError as e:
      return TransactionResult(outcome: roMalformed, reason: e.msg)

  TransactionResult(outcome: roFound, view: v)

# ---------------------------------------------------------------------------
# Position within the chain, without assuming the chain has blocks.
#
# `TxOrder` is a discriminated union precisely because ordering is not
# universal (Hedera orders by consensus time, Aptos by a global version, Sui by
# checkpoint, TON by logical time). A consumer that wants "height and index"
# has to ask whether this chain has them, and this is where it asks.
# ---------------------------------------------------------------------------

type
  BlockPosition* = object
    known*: bool
    blockHash*: string
    height*: int
    index*: int

proc blockPosition*(v: TransactionView): BlockPosition =
  if v.facts.order.kind == tokBlockIndex:
    BlockPosition(known: true, blockHash: v.facts.order.obBlock,
                  height: v.facts.order.obHeight, index: v.facts.order.obIndex)
  else:
    BlockPosition(known: false)

proc orderLabel*(v: TransactionView): string =
  ## The chain's own ordering coordinate, spelled the chain's own way. Never a
  ## fabricated height for a chain that has none.
  case v.facts.order.kind
  of tokBlockIndex:
    $v.facts.order.obHeight & ":" & $v.facts.order.obIndex
  of tokConsensusTime: v.facts.order.ctTime
  of tokGlobalVersion: v.facts.order.gvVersion
  of tokCheckpoint: v.facts.order.cpSeq
  of tokLogicalTime: v.facts.order.ltAccount & ":" & v.facts.order.ltLt

proc primaryRole*(v: TransactionView): Role =
  ## The role a table row shows in its "from" column, or an empty `Role` when
  ## the chain has no sender — which some do not (§2.3, `roles`). The order
  ## below is a presentation preference and is deliberately NOT a claim that
  ## one of these always exists.
  for want in ["initiator", "signer", "sender", "feePayer"]:
    for r in v.facts.roles:
      if r.role == want: return r
  if v.facts.roles.len > 0: return v.facts.roles[0]
  Role()

proc execTraces*(v: TransactionView): seq[ExecTrace] =
  ## The overlay's per-execution availability, in either contract-valid shape.
  if v.hasSelection: allExecTraces(v.selection) else: @[]

proc headlineAvailability*(v: TransactionView): TraceAvailability =
  ## The one availability a dense table row can show for a transaction with
  ## several independently-debuggable executions: the strongest present, so the
  ## Debug affordance reflects the best debuggable execution rather than
  ## whichever the producer happened to list first.
  ##
  ## A transaction with no overlay entry at all is `unsupported` — the SDK does
  ## not invent `onDemand` for something the tree never claimed.
  const rank = [taReady, taDivergent, taOnDemand, taAbsent, taUnsupported]
  let execs = v.execTraces
  for want in rank:
    for e in execs:
      if e.availability == want: return want
  taUnsupported
