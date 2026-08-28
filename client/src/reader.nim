## SDK-CONSUMER: the explorer's presentation projection over @blocktracer/client.
##
## The explorer's view of the data plane — and **only** the view part.
##
## Reading the `/d/**` tree, pinning a generation, resolving a transaction to a
## trace and interpreting `availability` all moved to the Client SDK
## (`blocktracer_client`, M12a) so a third party can do the same things without
## taking the explorer with them
## ([Client-SDK.md](../../../codetracer-specs/BlockTracer/Client-SDK.md)). What
## is left here is what is genuinely BlockTracer's rather than any consumer's:
## the row and view structs the three M5 pages render, projected from the SDK's
## types.
##
## This module imports **only the SDK facade**. Reaching into
## `blocktracer_client/*` would pin an SDK internal as public ABI, and
## `ci/test/client-sdk-boundary.sh` fails the build when a declared consumer
## does — the mirror of the same rule the Embed SDK enforces one layer down.

import blocktracer_client
export TraceAvailability, OutcomeOverall, BlockDetail, Role, Cost

type
  DataPlaneError* = object of CatchableError
    ## The tree cannot be read as a conformant static site. The exporter turns
    ## this into a failed build rather than a half-rendered page: a page that
    ## silently omits a chain is worse than one that was never published.

  DataRoot* = object
    ## Root of a static tree: the directory that contains `d/`, `idx/`,
    ## `registry/` and `t/` (i.e. the exporter's `dist/`).
    dir*: string
    store*: ObjectStore

  ChainInfo* = object
    ## A chain, at the generation this render pinned. `session` carries the pin;
    ## every read below takes it, so one rendered page cannot mix generations.
    session*: ChainSession
    slug*: string
    generation*: string
    traceSelectionVersion*: string
    headHeight*: int
    headHash*: string
    finalizedHeight*: int
    finalizedHash*: string
    blockCount*: int
    txCount*: int
    coverageMode*: string
    stale*: bool

  BlockRow* = object
    ## One row of the block-list / latest-blocks table.
    hash*: string
    height*: int
    parentHash*: string
    txCount*: int

  ExecView* = object
    ## One execution's trace availability, from the TraceSelection overlay.
    selector*: string          ## "" for a single-execution transaction
    availability*: TraceAvailability
    reason*: string
    bytes*: int
    validationStatus*: string  ## "" when the overlay carries no validation

  TxRow* = object
    ## One row of the shared transactions table (block detail, tx list).
    hash*: string
    height*: int
    index*: int
    fromAddr*: string
    toTarget*: string
    methodSel*: string
    outcome*: OutcomeOverall
    availability*: TraceAvailability   ## the row's headline trace state

  TxView* = object
    ## Everything the transaction-detail view renders.
    chain*, hash*: string
    height*, index*: int
    blockHash*: string
    outcome*: OutcomeOverall
    outcomeReason*: string
    roles*: seq[Role]
    cost*: seq[Cost]
    payloadRaw*, payloadSelector*, payloadTarget*: string
    executions*: seq[ExecView]
    headline*: TraceAvailability   ## the strongest availability among `executions`
    canonical*: bool
    finality*: string
    native*: JsonNode

func newDataRoot*(dir: string): DataRoot =
  DataRoot(dir: dir, store: localTree(dir))

# ── chains ─────────────────────────────────────────────────────────────────

proc chains*(r: DataRoot): seq[string] =
  ## Chain slugs present in the tree, from the registry — the honest inventory.
  chains(r.store)

proc chainInfo*(r: DataRoot, chain: string): ChainInfo =
  ## Open the chain and PIN its generation for the rest of this render.
  let opened = openChain(r.store, chain)
  if opened.outcome != ooOpened:
    raise newException(DataPlaneError,
      "cannot open chain '" & chain & "': " & opened.reason)
  let s = opened.session
  ChainInfo(session: s, slug: chain, generation: s.generation,
    traceSelectionVersion: s.traceSelectionVersion,
    headHeight: s.head.height, headHash: s.head.hash,
    finalizedHeight: s.finalized.height, finalizedHash: s.finalized.hash,
    blockCount: s.blockCount, txCount: s.txCount,
    coverageMode: s.coverageMode, stale: s.stale)

# ── blocks ───────────────────────────────────────────────────────────────

proc hasBlock*(r: DataRoot, chain, hash: string): bool =
  r.store.get(blockPath(chain, hash)).found

proc hasTx*(r: DataRoot, chain, hash: string): bool =
  r.store.get(txFactsPath(chain, hash)).found

proc readBlockDetail*(r: DataRoot, info: ChainInfo, hash: string): BlockDetail =
  let b = blockDetail(r.store, info.session, hash)
  if b.outcome != roFound:
    raise newException(DataPlaneError, "block " & hash & ": " & b.reason)
  b.detail

proc blockHashes*(r: DataRoot, info: ChainInfo): seq[string] =
  ## The chain's block hashes, newest first, at the pinned generation.
  for b in blockRefsNewestFirst(r.store, info.session): result.add b.hash

proc blocks*(r: DataRoot, info: ChainInfo): seq[BlockRow] =
  for b in blockRefsNewestFirst(r.store, info.session):
    let d = readBlockDetail(r, info, b.hash)
    result.add BlockRow(hash: d.hash, height: d.height,
                        parentHash: d.parentHash, txCount: d.transactions.len)

# ── transactions ─────────────────────────────────────────────────────────

proc txView*(r: DataRoot, info: ChainInfo, hash: string): TxView =
  ## The transaction-detail projection. The SDK assembles the three data-plane
  ## layers; this maps them onto the fields the page shows.
  let tr = transaction(r.store, info.session, hash)
  if tr.outcome != roFound:
    raise newException(DataPlaneError, "transaction " & hash & ": " & tr.reason)
  let v = tr.view
  let pos = blockPosition(v)
  result.chain = v.facts.chain
  result.hash = hash
  result.height = pos.height
  result.index = pos.index
  result.blockHash = pos.blockHash
  result.outcome = v.facts.outcome.overall
  result.outcomeReason = v.facts.outcome.reason
  result.roles = v.facts.roles
  result.cost = v.facts.cost
  result.payloadRaw = v.facts.payloadRaw
  result.payloadSelector = v.facts.payloadSelector
  result.payloadTarget = v.facts.payloadTarget
  result.native = v.facts.native
  result.canonical = v.canonical
  result.finality = v.finality
  for e in v.execTraces:
    result.executions.add ExecView(
      selector: e.selector, availability: e.availability, reason: e.reason,
      bytes: e.bytes,
      validationStatus: (if e.hasValidation: $e.validation.status else: ""))
  result.headline = headlineAvailability(v)

proc txRow*(r: DataRoot, info: ChainInfo, hash: string): TxRow =
  let v = txView(r, info, hash)
  result = TxRow(
    hash: hash, height: v.height, index: v.index,
    outcome: v.outcome, methodSel: v.payloadSelector, toTarget: v.payloadTarget,
    availability: v.headline)
  for role in v.roles:
    if role.role in ["feePayer", "signer", "initiator", "sender"]:
      result.fromAddr = role.address
      break
  if result.fromAddr.len == 0 and v.roles.len > 0:
    result.fromAddr = v.roles[0].address
