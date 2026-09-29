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

import std/[algorithm, json, sets, strutils, tables]
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
  let r = store.getJson(blockPath(session.chain, blockHash,
                                  session.identifierEncoding))
  if not r.found:
    return BlockResult(outcome: roNotFound, reason: blockHash & " is not in this tree")
  if r.error.len > 0:
    return BlockResult(outcome: roMalformed, reason: r.error)
  try:
    BlockResult(outcome: roFound, detail: decodeBlockDetail(r.node))
  except ContractDecodeError as e:
    BlockResult(outcome: roMalformed, reason: e.msg)

# ---------------------------------------------------------------------------
# The generation block-list memo (opt-in, off by default).
# ---------------------------------------------------------------------------
#
# WHAT IS LEFT AFTER THE HashSet. Deduping with a set removed N^2/2 comparisons
# per call, and the 10,000-block export went 1,995 s -> 70.8 s. The function still
# BUILDS AND SORTS THE WHOLE LIST on every call, so cost per page stayed
# proportional to the chain: 0.82 ms/page at 1,000 blocks against 3.93 at 10,000.
# O(blocks) per call over O(pages) calls is still quadratic — a smaller constant
# on the same shape.
#
# The list cannot change during an export. It is derived from a SEALED generation
# root: `session.generation` names it, and a different generation is a different
# key. So the memo is keyed by store name, chain and generation, and a reorg
# publishing a new generation misses the memo by construction rather than by
# invalidation.
#
# OFF BY DEFAULT, for the reason `store.nim`'s cache is: a client must resolve the
# pointer once per navigation, and a memo that outlived a navigation would hand it
# a list from a generation it has stopped pointing at. An export is one moment and
# may. Nothing here caches across generations, so enabling it in a long-lived
# process would still be wrong for a different reason — it would grow without
# bound as generations advance.
var blockRefMemo: TableRef[string, seq[BlockRef]] = nil

const BlockRefMemoBound* = 64
  ## An export sees a handful of chains and one generation each. Anything past
  ## this is a long-lived process that enabled the memo, which is the misuse the
  ## header describes, and it grows without bound as generations advance.

proc enableBlockRefMemo*() =
  ## Turn the per-generation block-list memo on for THIS PROCESS. A whole-site
  ## export calls this; a client must not.
  ##
  ## THE BOUND IS A GATE AND NOT A COMMENT, which is the lesson of the four
  ## locality-class defects this repository has produced: each had accurate
  ## prose next to the defect and nothing that refused. A memo that silently
  ## grew would be the fifth, so it raises instead.
  blockRefMemo = newTable[string, seq[BlockRef]]()

proc blockRefsNewestFirst*(store: ObjectStore,
                           session: ChainSession): seq[BlockRef] =
  ## The generation's blocks, newest first, from the sealed root's height map.
  ##
  ## The height map is read rather than every block detail: the map is one
  ## object per epoch and states the height, so ordering a chain's blocks costs
  ## O(epochs) reads instead of O(blocks). A consumer that wants the details
  ## asks for the ones it will show.
  let memoKey =
    if blockRefMemo != nil: store.name & "\0" & session.chain & "\0" & session.generation
    else: ""
  if memoKey.len > 0 and blockRefMemo.hasKey(memoKey): return blockRefMemo[memoKey]
  # A `HashSet` AND NOT A `seq`, AND THE DIFFERENCE IS 1.05 TRILLION COMPARISONS.
  #
  # `if h in seen` over a `seq[string]` is a linear scan of everything already
  # accepted, so deduping N blocks costs N²/2 comparisons INSIDE ONE CALL. The
  # header above is right that this reads O(epochs) objects rather than
  # O(blocks) — and that is a statement about READS, which is not where the cost
  # was. Measured on a 10,000-block export: 21,266 calls, 210,947,112 `BlockRef`
  # constructions, and 1,054,594,684,900 `seen` comparisons — 49.6 M per call,
  # against the 50 M that N²/2 predicts for N = 10,000. That was 1,975 s of a
  # 1,995 s run: 99.0% of the whole export.
  #
  # It is invisible to the consumer this was written for. A client renders one
  # page and pays it once over the chain it is showing; an exporter renders
  # 288,046 and pays it every time. Same function, same correctness, different
  # consumer — see `docs/Replay-Toolchain-Artifacts.md` on that class.
  var seen: HashSet[string]
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
      seen.incl h
      var height = 0
      try: height = parseInt(heightStr)
      except ValueError: continue
      result.add BlockRef(height: height, hash: h)
  result.sort(proc(a, b: BlockRef): int = cmp(b.height, a.height))
  if memoKey.len > 0:
    if blockRefMemo.len >= BlockRefMemoBound:
      raise newException(ValueError,
        "blockRefsNewestFirst memo exceeded " & $BlockRefMemoBound & " entries. It is keyed " &
        "by store, chain and generation, so this many distinct keys means a long-lived " &
        "process enabled it and is accumulating generations — the misuse its header names. " &
        "An export sees one generation per chain. Do not raise the bound; stop enabling the " &
        "memo outside a whole-site export.")
    blockRefMemo[memoKey] = result

proc transaction*(store: ObjectStore, session: ChainSession,
                  txHash: string): TransactionResult =
  ## Assemble the three layers. A missing txstate or overlay is recorded as
  ## absent-layer data, never as a failure of the transaction itself: the facts
  ## are permanent and the other two are scoped to things that move.
  let f = store.getJson(txFactsPath(session.chain, txHash, session.identifierEncoding))
  if not f.found:
    return TransactionResult(outcome: roNotFound,
      reason: txHash & " is not in this tree")
  if f.error.len > 0:
    return TransactionResult(outcome: roMalformed, reason: f.error)

  # THE VIEW CARRIES THE TREE'S IDENTIFIER, NOT THE CALLER'S SPELLING.
  #
  # `txHash` is whatever the caller arrived with — a route segment, a pasted
  # query, a link — and the path above is built from its KEY form, so a
  # case-insensitive encoding resolves whichever spelling was used. Echoing the
  # argument back would then render the caller's spelling on the page: for hex
  # that is how an EIP-55 address pasted in a form nobody checksummed would be
  # displayed as though the tree had published it that way, and how a mixed-case
  # bech32 string — which BIP-173 makes invalid outright — would be shown as an
  # address.
  #
  # So the view's identifier is the DISPLAY form of what the object itself
  # states, and the argument is used only when the object states none, in which
  # case the key form is the only honest answer available. That is the consumer
  # side of the same rule `src/blocktracer/validator.nim` enforces on producers.
  let stated = f.node{"id"}{"hash"}.getStr
  var v = TransactionView(chain: session.chain,
    hash: if stated.len > 0:
            identifierDisplayForm(session.identifierEncoding, KindTransaction,
                                  stated)
          else:
            identifierKeyForm(session.identifierEncoding, KindTransaction,
                              txHash))
  try:
    v.facts = decodeTransactionFacts(f.node)
  except ContractDecodeError as e:
    return TransactionResult(outcome: roMalformed, reason: e.msg)

  let st = store.getJson(txStatePath(session.chain, session.generation, txHash, session.identifierEncoding))
  if st.found and st.error.len == 0 and st.node.kind == JObject:
    v.hasState = true
    v.canonical = st.node{"canonical"}.getBool
    v.finality = st.node{"finality"}.getStr

  let ov = store.getJson(
    traceSelectionPath(session.chain, session.traceSelectionVersion, txHash,
                       session.identifierEncoding))
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
