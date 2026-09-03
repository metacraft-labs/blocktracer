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

import std/[algorithm, strutils]
import blocktracer_client
export TraceAvailability, OutcomeOverall, ExecutionEnding, BlockDetail, Role, Cost
# The read seam itself, so a consumer of THIS module can hand `newDataRoot` a
# transport of its own — a recording wrapper, a synthetic tree, a store that
# refuses everything off the published prefixes. Re-exported rather than
# re-declared: there is one `ObjectStore` type in this product and it is the
# SDK's (Client-SDK.md §1.1), and a second one here would be a second seam for
# an identity to be attached at.
export ObjectStore, ObjectResponse, newObjectStore, localTree, get, getJson,
       RequestLog, newRequestLog, recordingStore

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
    hasRecorder*: bool
      ## Whether the registry pins a recorder for this chain. `false` is §14's
      ## "Recorder unavailable for the VM" as a fact about the tree rather than
      ## as an inference from an empty Debug column.
    recorderId*, recorderVersion*, recorderBuild*: string
    profileName*, traceSchema*: string
    provenanceKind*, provenanceLabel*, provenanceDetail*: string
      ## Where this chain's data came from, as the tree states it. Empty
      ## `provenanceKind` means the generation published none, which for this
      ## repository's demo tree is the synthetic case.

  TourRow* = object
    ## One entry of a chain's capability tour: a small program written to be
    ## read, published with its own recording so that opening it opens THAT
    ## program rather than a fixture standing in for all of them.
    id*: string
      ## Stable across regenerations and across seeds — it names the program,
      ## not its position. It is what a test selects a fixture by and what a
      ## link fragment is built from; the transaction hash is neither.
    title*, summary*: string
    capabilities*: seq[string]
    language*: seq[string]
    tx*: string
    steps*, calls*: int

  BlockRow* = object
    ## One row of the block-list / latest-blocks table.
    hash*: string
    height*: int
    parentHash*: string
    parentIndexed*: bool
      ## Whether this generation indexes the parent at all.
      ##
      ## The oldest block a generation holds has a parent that is a real block
      ## of a real chain and is simply not in this tree — backfill has not
      ## reached it, or never will. Linking to it produces a dead link on a
      ## static site, which is the one failure a published explorer cannot
      ## explain away: it is not §14's "not on this chain", it is a link the
      ## product itself emitted to a page it never wrote.
    txCount*: int

  ExecView* = object
    ## One execution's trace availability, from the TraceSelection overlay.
    selector*: string          ## "" for a single-execution transaction
    availability*: TraceAvailability
    reason*: string
    bytes*: int
    validationStatus*: string  ## "" when the overlay carries no validation

  SourceCoverage* = enum
    ## WHETHER A TRANSACTION CAN BE DEBUGGED AGAINST SOURCE, and every value
    ## here is a state the published tree can DISTINGUISH rather than a grade
    ## somebody picked.
    ##
    ## ## Where the states come from
    ##
    ## `ingest.nim` republishes, per transaction, the recording's own
    ## `ct.source-provenance` as `native.replay.artifacts` — **one entry per
    ## contract the transaction executed, resolved or not** — each carrying
    ## `resolved`, the `origin` that served the artifact, and a `corroboration`
    ## word.
    ##
    ## OR, where the capture recorded none, the same shape measured AFTER the
    ## fact from `artifact-resolution.json` — every frozen capture in this
    ## repository predates off-chain resolution, and their bodies are pruned, so
    ## the question was asked against the contract classes the node still serves
    ## (CHAIN-CAPTURE.md §6.1a). Those entries carry `measuredPostHoc: true` and
    ## fold identically, because the question and the resolver are the same one.
    ## What they may NOT do is imply the recording can show what resolved — see
    ## `positioned`, which is the field that keeps the two apart. The runtime accepts an artifact only when `computeArtifactHash`
    ## equals the class's `artifactHash`, its `public_dispatch` is byte-equal to
    ## `packedBytecode`, and the class id recomputes; the rung is then measured
    ## per contract over the executed stream and never rounded up.
    ##
    ## So the states below are a fold over that array and nothing else. A
    ## transaction that executed three contracts and resolved one is a real and
    ## common shape — it is the reason the strong state is called *available*
    ## and not *verified* (see `viewutil.sourcesState`).
    ##
    ## ## The two "no answer" states are two answers, not one
    ##
    ## A recording written by the current runtime carries the provenance record
    ## **even when it resolved nothing**, so absence is informative:
    ##
    ##   * `scUnrecorded` — this transaction has no chain-replay record at all.
    ##     No artifact resolution was attempted, because there was nothing to
    ##     attempt it against. Every transaction of the SYNTHETIC demo chain is
    ##     here, and so is every real transaction the pipeline could not replay.
    ##   * `scUnchecked` — replayed, and the recording carries no provenance
    ##     record. That is a capture taken before the runtime could resolve
    ##     artifacts off-chain. Somebody replayed it; nobody looked for source.
    ##
    ## They are collapsed to ONE label in the product (`Not checked`) and kept
    ## apart here, which is the same shape `availabilityNote` uses for `absent`:
    ## a badge may not name a cause it cannot tell, and the cause is stated in
    ## the row's note where there is room for a sentence.
    scUnrecorded = "unrecorded"
    scUnchecked = "unchecked"
    scNoCode = "no-code"
      ## Checked, and this transaction executed no contract code — an empty
      ## record, which is NOT the same object as a missing one. `ingest.nim`
      ## publishes `null` for the second and `[]` for the first precisely so
      ## this line can exist.
    scNone = "none"          ## every executed contract checked, none resolved
    scPartial = "partial"    ## some executed contracts resolved, some did not
    scAll = "all"            ## every executed contract resolved

  SourceCorroboration* = enum
    ## HOW STRONG THE SOURCE CLAIM IS, over the contracts that resolved.
    ##
    ## `artifactHash` is the chain's commitment to the ARTIFACT and it does not
    ## commit to that artifact's `debug_symbols` or its `file_map`. What the
    ## chain proves is that the bytecode which ran is the bytecode in the
    ## artifact; the source TEXT beside it is attested by whoever distributed
    ## it. So this axis is orthogonal to `SourceCoverage` and has to travel with
    ## it: "every contract resolved, on one distributor's unverified word" and
    ## "every contract resolved, two independent distributors agreeing" are
    ## different claims and the page may not spell them the same way.
    scNoClaim = "no-claim"                ## nothing resolved; there is no claim
    scSingleDistributor = "single-distributor"
    scCorroborated = "corroborated"

  SourceCoverageView* = object
    ## The fold, with the numbers it was folded from — because "2 of 3" is the
    ## thing a visitor with a partially-resolvable transaction actually needs,
    ## and a state alone cannot say it.
    state*: SourceCoverage
    contracts*: int          ## executed contracts the recording accounted for
    resolved*: int           ## how many of them resolved an artifact
    corroboration*: SourceCorroboration
    origins*: seq[string]    ## the distinct distributors named, sorted
    positioned*: bool
      ## WHETHER THIS RECORDING CAN SHOW THE SOURCE IT RESOLVED, which is a
      ## SEPARATE QUESTION from whether the source resolved and became a
      ## separate field the moment the two could differ.
      ##
      ## Resolution asks "is this contract's artifact provable against the
      ## chain's commitment to its class". Positioning asks "were this
      ## recording's steps written against that artifact's debug map". The
      ## second needs the transaction body; the first needs only world state,
      ## which outlives it. So a transaction can now be `scAll` — every
      ## executed contract resolved — over a container that positions nothing,
      ## and every real transaction this site publishes today is exactly that
      ## shape: captured by a runtime that never looked, resolved afterwards by
      ## `resolve-frozen-artifacts.mjs` against classes the node still serves.
      ##
      ## Without this field `sourcesNote` would say an artifact resolved and
      ## stop, and a visitor would open the debugger onto a source pane reading
      ## "Stepping continues at instruction level" — the page promising what
      ## the container cannot keep. It is read from the tree's own
      ## `replay.sourceLevel` rather than inferred from the presence of a
      ## resolution, because those are the two things that must not be
      ## conflated.
    postHoc*: bool
      ## Whether the resolution was measured AFTER the capture rather than
      ## during it. Folded from the entries' `measuredPostHoc`, and true only
      ## when EVERY resolved entry carries it — a mixed record makes the
      ## weaker, and therefore honest, claim about the transaction as a whole.

  TxRow* = object
    ## One row of the shared transactions table (block detail, tx list).
    hash*: string
    height*: int
    index*: int
    blockHash*: string
      ## §6 column 3 links `height:index` to the block detail, and the block is
      ## addressed by HASH (§2.1: "content is addressed by what it is,
      ## references are addressed by where you look for it"). Carrying the hash
      ## on the row is what lets the link be built without a second read of the
      ## generation's height map per row.
    fromAddr*: string
    toTarget*: string
    methodSel*: string
    outcome*: OutcomeOverall
    outcomeReason*: string
      ## §6 column 10: "Success / reverted, with the revert reason inline when
      ## decodable". The reason travels with the row rather than being fetched
      ## again by the view, so the table and the transaction page cannot
      ## disagree about why something failed.
    cost*: seq[Cost]
      ## §6 column 9's fee, as the VECTOR it is in the schema (§2.3: "Cost is a
      ## VECTOR, never a scalar"). Flattening it to one number here is how a
      ## multi-dimensional chain's fee silently becomes an EVM-shaped one.
    availability*: TraceAvailability   ## the row's headline trace state
    sources*: SourceCoverageView
      ## §6 column 1's qualifier: whether the Debug action beside it opens a
      ## session that can show source, and for how much of the transaction.
      ##
      ## It rides on the ROW rather than being fetched by the table for the same
      ## reason `outcomeReason` does — the list and the transaction page must not
      ## be able to disagree — and it is derived from `TransactionFacts.native`,
      ## which `txView` has already read. That is what keeps it free: the
      ## manifest, which also carries a per-transaction `execution.sourceLevel`,
      ## is a SECOND object per row, and reading it here would turn a page of 25
      ## rows into 25 extra requests and break `test_explorer_breadth`'s
      ## constant-per-page cost. The facts object is the one already in hand.

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
    executionSelectors*: seq[string]
      ## The parts this transaction ran in, from the IMMUTABLE FACTS —
      ## `TransactionFacts.executions[].selector`, which is required and always
      ## populated ("public", "private", …).
      ##
      ## Deliberately NOT read off `executions` above, and the difference is not
      ## cosmetic: that seq is projected from the TraceSelection OVERLAY, and
      ## `ExecView.selector` is documented as `""` for a single-execution
      ## transaction. Deriving §7.2's transaction type from it would therefore
      ## have produced a type for the Aztec private/public split and an em dash
      ## for every other transaction in the tree — nine of the demo's ten and
      ## every single one on both live chains — while looking correct in the one
      ## case a reviewer would think to check.
      ##
      ## Two seqs because they answer two questions. What a transaction IS comes
      ## from the permanent facts; whether its parts can be REPLAYED comes from
      ## a versioned overlay that is rewritten as traces appear.
    canonical*: bool
    finality*: string
    native*: JsonNode
    sources*: SourceCoverageView
      ## The same fold as `TxRow.sources`, over the same `native`, produced by
      ## the same proc. §7.1's rule — the metadata is "rendered in two places …
      ## from one source, and the two cannot be allowed to diverge" — applies to
      ## this fact as much as to the rest, and the transaction page, the
      ## debugger's metadata pane and every list row now read one derivation.

func newDataRoot*(dir: string): DataRoot =
  DataRoot(dir: dir, store: localTree(dir))

func newDataRoot*(dir: string, store: ObjectStore): DataRoot =
  ## A root over an arbitrary transport rather than over a directory.
  ##
  ## The exporter always uses the filesystem one above. This overload exists so
  ## a test can render the very same pages over a `recordingStore` — which is
  ## how "renders from published files only" and "constant per-page cost" are
  ## checked as counts of reads rather than asserted in a comment — and so a
  ## synthetic tree far larger than any fixture can be served from a closure
  ## without being written to disk.
  DataRoot(dir: dir, store: store)

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
    coverageMode: s.coverageMode, stale: s.stale,
    hasRecorder: s.hasPin,
    recorderId: s.pin.recorder.id, recorderVersion: s.pin.recorder.version,
    recorderBuild: s.pin.recorder.build,
    profileName: s.pin.profile.name, traceSchema: s.pin.traceSchema,
    provenanceKind: s.provenanceKind, provenanceLabel: s.provenanceLabel,
    provenanceDetail: s.provenanceDetail)

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

proc highestIndexedHeight*(r: DataRoot, info: ChainInfo): int =
  ## The tallest block this generation indexes, from the height MAP.
  ##
  ## One object per epoch, never one per block: this is what tells a page how
  ## far behind the tip the pipeline is, and a staleness figure that cost a
  ## read per block would be a decoration with a cap on it.
  result = -1
  for b in blockRefsNewestFirst(r.store, info.session):
    if b.height > result: result = b.height

proc canonicalBlockAt*(r: DataRoot, info: ChainInfo, height: int): string =
  ## The hash this generation's height map gives for a height, or `""`.
  ##
  ## §2.1: "Blocks are stored under their **hash**, which is immutable content.
  ## The **height → hash** mapping lives in a separate, mutable epoch file. A
  ## reorg is therefore a change to a small map." Which makes this the one
  ## question a block page has to ask to know whether it is still canonical:
  ## the block object is correct either way, and being orphaned is a property
  ## of the generation that references it, not of the object.
  for b in blockRefsNewestFirst(r.store, info.session):
    if b.height == height: return b.hash

proc nextBlockHash*(r: DataRoot, info: ChainInfo, height: int): string =
  ## The canonical block one height above — §5.2's "next", absent at the head.
  canonicalBlockAt(r, info, height + 1)

proc blocks*(r: DataRoot, info: ChainInfo): seq[BlockRow] =
  var indexed: seq[string]
  for b in blockRefsNewestFirst(r.store, info.session): indexed.add b.hash
  for h in indexed:
    let d = readBlockDetail(r, info, h)
    result.add BlockRow(hash: d.hash, height: d.height,
                        parentHash: d.parentHash,
                        parentIndexed: d.parentHash in indexed,
                        txCount: d.transactions.len)

const
  BlockPageSize* = 25
    ## §5.1: the block list is "sorted descending from head, paginated by
    ## walking backwards — cursor is a block number, so pagination needs no
    ## server". This is the page size that cursor advances by.
  TxPageSize* = 25
    ## §4's "latest transactions" and §6's list. Blocks are taken whole, so a
    ## page may exceed this by the size of the block that crossed it: splitting
    ## a block across two pages would make the cursor — a block number —
    ## ambiguous about which half it meant.

type
  BlockPage* = object
    ## One page of the block list, plus the cursor that continues it.
    rows*: seq[BlockRow]
    hasMore*: bool
    nextFrom*: int
      ## The height the NEXT page starts at, walking backwards. Meaningful only
      ## when `hasMore`.

  TxPage* = object
    rows*: seq[TxRow]
    hasMore*: bool
    nextFrom*: int
    fromHeight*, toHeight*: int   ## the block range this page actually covers

proc blocksFrom*(r: DataRoot, info: ChainInfo, fromHeight: int,
                 size = BlockPageSize): BlockPage =
  ## One page of blocks, walking backwards from `fromHeight` inclusive.
  ##
  ## `fromHeight < 0` means "from the head", which is what `/{chain}/blocks`
  ## asks for. Only the page's own block details are read — the ordering comes
  ## from the generation's height map, which is one object per epoch — so the
  ## cost of page N does not grow with N.
  let refs = blockRefsNewestFirst(r.store, info.session)
  var indexed: seq[string]
  for b in refs: indexed.add b.hash
  var taken = 0
  for b in refs:
    if fromHeight >= 0 and b.height > fromHeight: continue
    if taken < size:
      let d = readBlockDetail(r, info, b.hash)
      result.rows.add BlockRow(hash: d.hash, height: d.height,
                               parentHash: d.parentHash,
                               parentIndexed: d.parentHash in indexed,
                               txCount: d.transactions.len)
      inc taken
    else:
      result.hasMore = true
      result.nextFrom = b.height
      break

# ── transactions ─────────────────────────────────────────────────────────

proc sourceCoverage*(native: JsonNode): SourceCoverageView =
  ## Fold `native.replay.artifacts` — the recording's `ct.source-provenance`, as
  ## `ingest.nim` republishes it — into the one state a page may claim.
  ##
  ## ## Every branch here is a distinction the TREE makes
  ##
  ## Nothing is inferred from a chain's name, a slug, a language tag or the
  ## presence of a source bundle. The published array is the evidence and the
  ## fold is total over it, so a transaction that gains a resolved contract on
  ## the next capture moves state on its own.
  ##
  ## ## Why the strong state is not rounded up
  ##
  ## `resolved == contracts` is required for `scAll`, and `contracts` counts
  ## EVERY contract the transaction executed — `ingest.nim`'s code edges and
  ## this array are published for unresolved contracts too, deliberately, "so
  ## an unresolved contract has to be ASKED about and answered". A fold that
  ## filtered to the resolved entries first would find every transaction
  ## complete, which is the confident-and-wrong answer this product may not
  ## ship.
  ##
  ## ## Corroboration is ANDed, never averaged
  ##
  ## One contract served by a single distributor makes the whole transaction's
  ## source claim rest on that one party's unverified word, because a visitor
  ## stepping through it cannot tell which lines came from which artifact. So a
  ## single `single-distributor` — or a resolved entry with no corroboration
  ## word at all — pulls the transaction down to `scSingleDistributor`.
  result.corroboration = scNoClaim
  if native.isNil or native.kind != JObject: return
  let replay = native{"replay"}
  if replay.isNil or replay.kind != JObject: return
  # From here on the transaction HAS a replay record, so "nobody looked" and
  # "looked and found nothing" are separable.
  # WHETHER THE CONTAINER POSITIONS ITS STEPS, read from the tree and not inferred. This is
  # the recording's own `sourceLevel`, which `ingest.nim` writes from the capture and from
  # nothing else — in particular a post-hoc resolution cannot raise it, which is what keeps
  # "the artifact is provable" and "this recording shows it" apart. See `positioned`.
  result.positioned = replay{"sourceLevel"}.getBool
  let artifacts = replay{"artifacts"}
  if artifacts.isNil or artifacts.kind != JArray:
    result.state = scUnchecked
    return
  result.state = scNoCode
  result.contracts = artifacts.len
  if artifacts.len == 0: return
  var everyResolvedIsCorroborated = true
  var everyResolvedIsPostHoc = true
  for a in artifacts:
    if not a{"resolved"}.getBool: continue
    inc result.resolved
    if not a{"measuredPostHoc"}.getBool: everyResolvedIsPostHoc = false
    let origin = a{"origin"}.getStr
    if origin.len > 0 and origin notin result.origins:
      result.origins.add origin
    if a{"corroboration"}.getStr != $scCorroborated:
      everyResolvedIsCorroborated = false
  sort(result.origins)
  result.state =
    if result.resolved == 0: scNone
    elif result.resolved == result.contracts: scAll
    else: scPartial
  if result.resolved > 0:
    result.corroboration =
      if everyResolvedIsCorroborated: scCorroborated else: scSingleDistributor
    result.postHoc = everyResolvedIsPostHoc

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
  result.sources = sourceCoverage(v.facts.native)
  result.canonical = v.canonical
  result.finality = v.finality
  for e in v.execTraces:
    result.executions.add ExecView(
      selector: e.selector, availability: e.availability, reason: e.reason,
      bytes: e.bytes,
      validationStatus: (if e.hasValidation: $e.validation.status else: ""))
  for e in v.facts.executions:
    result.executionSelectors.add e.selector
  result.headline = headlineAvailability(v)

proc txRow*(r: DataRoot, info: ChainInfo, hash: string): TxRow =
  let v = txView(r, info, hash)
  result = TxRow(
    hash: hash, height: v.height, index: v.index, blockHash: v.blockHash,
    outcome: v.outcome, outcomeReason: v.outcomeReason, cost: v.cost,
    methodSel: v.payloadSelector, toTarget: v.payloadTarget,
    availability: v.headline, sources: v.sources)
  for role in v.roles:
    if role.role in ["feePayer", "signer", "initiator", "sender"]:
      result.fromAddr = role.address
      break
  if result.fromAddr.len == 0 and v.roles.len > 0:
    result.fromAddr = v.roles[0].address

proc txsFrom*(r: DataRoot, info: ChainInfo, fromHeight: int,
              size = TxPageSize): TxPage =
  ## One page of transactions, in block order, walking backwards from
  ## `fromHeight` inclusive. Blocks are taken whole — see `TxPageSize`.
  result.fromHeight = -1
  result.toHeight = -1
  for b in blockRefsNewestFirst(r.store, info.session):
    if fromHeight >= 0 and b.height > fromHeight: continue
    if result.rows.len >= size:
      result.hasMore = true
      result.nextFrom = b.height
      break
    let d = readBlockDetail(r, info, b.hash)
    if result.toHeight < 0: result.toHeight = d.height
    result.fromHeight = d.height
    for h in d.transactions:
      result.rows.add txRow(r, info, h)

# ── the trace behind a transaction, and the source behind the trace ────────
#
# Debugger-Integration.md §2's first two lines: "resolve trace status from the
# transaction's data" and "attach a BlockSource". The debug route needs the
# resolved artifact — where the container is, how big it is, what the manifest
# says the execution contains — plus the source bundle the manifest recommends,
# because Trace-Artifacts.md §2.5 is emphatic that the container carries
# positions and interned paths and NO SOURCE TEXT. A viewer handed only
# `trace.ct` steps correctly through code it cannot display.
#
# Resolution order is NOT re-decided here. `resolveSourceBundle` owns it
# (manifest recommendation first, then the chain-wide `current.json` pointer),
# which is the same function `viewmodel/source_bundle_vm.nim` delegates to and
# for the same stated reason: a second copy of the order is a second thing to
# keep in sync.

type
  TraceViewOutcome* = enum
    tvReplayable = "replayable"     ## a container exists to open
    tvPending = "pending"           ## derivable, not published (on demand)
    tvNone = "none"                 ## absent, unsupported, or unresolvable

  TraceView* = object
    ## What the debug route needs about one execution's trace.
    outcome*: TraceViewOutcome
    availability*: TraceAvailability
    reason*: string
    selector*: string
    containerPath*: string
    containerBytes*: int
    contentHash*: string
      ## `traceContentHash` of the artifact this resolution recommends
      ## (Trace-Artifacts.md §2.8). The debug page carries it so a browser can
      ## check an incoming deep link's content witness against the trace it is
      ## actually about to open (Debugger-Integration §6.0). Empty until the
      ## manifest is in hand — the address proves the inputs and nothing about
      ## the bytes — and an empty one resolves as "unverifiable", never as
      ## "matches".
    steps*, frames*: int
    truncated*: bool
    sourceLevel*: bool
    reconstructed*: bool
    ending*: ExecutionEnding
      ## How the RECORDING ended, which is not how the transaction ended — see
      ## `contract/model.ExecutionEnding`. `eeUnstated` on every trace whose
      ## manifest does not say, which is every real-chain one today.
    languages*: seq[string]
    validationStatus*: string
    sourceBundle*: JsonNode        ## the recommended bundle's raw node, or nil
    sourceBundleReason*: string    ## why there is none
    instructions*: JsonNode
      ## The recording's per-step program counters, or nil.
      ##
      ## The FLOOR of the fidelity ladder, carried beside the rung above it
      ## rather than instead of it. Both are resolved on every trace view and
      ## the pane decides: a transaction whose artifact resolved renders source,
      ## one whose did not renders instructions, and `nil` here is the third
      ## state — an instruction-level recording whose stream this tree does not
      ## publish, which renders the stated reason and nothing else, as it always
      ## did.

proc traceView*(r: DataRoot, info: ChainInfo, hash: string;
                selector = ""): TraceView =
  ## Resolve the execution a Debug affordance would open, and the source
  ## bundle that makes its positions legible.
  ##
  ## With no selector this follows `bestTrace` — "the strongest first, so a
  ## transaction whose private half is absent and whose public half is ready
  ## opens the public half". That is the behaviour §7.1's private/public split
  ## needs: the route lands in the half that can be debugged, and the metadata
  ## pane still states that the other half is structurally absent.
  let tr = transaction(r.store, info.session, hash)
  if tr.outcome != roFound:
    raise newException(DataPlaneError, "transaction " & hash & ": " & tr.reason)
  let traces = resolveTraces(r.store, info.session, tr.view,
                             probeOnDemand = false)
  var idx = -1
  if selector.len > 0:
    for i, t in traces:
      if t.selector == selector: idx = i
  else:
    idx = bestTrace(traces)
  if idx < 0:
    return TraceView(outcome: tvNone,
      reason: "no execution to open for " & hash &
              (if selector.len > 0: " (selector '" & selector & "')" else: ""))

  let t = traces[idx]
  result.selector = t.selector
  result.availability = t.availability
  result.reason = t.reason
  result.containerPath = t.containerPath
  result.containerBytes = containerBytes(t)
  result.contentHash = contentHash(t)
  result.reconstructed = t.reconstructed
  result.outcome =
    if isReplayable(t): tvReplayable
    elif t.kind == trkOnDemand: tvPending
    else: tvNone
  if t.hasValidation: result.validationStatus = $t.validation.status

  # ONLY FOR A TRACE THERE IS SOMETHING TO OPEN. An `absent` or `on-demand`
  # resolution derives no artifact address, so asking would be a request built
  # from an empty id — and §2.3a's rule that a terminal state fetches nothing
  # is the reason `resolveExec` returns before deriving one.
  if isReplayable(t) and t.instructionsPath.len > 0:
    let ins = r.store.getJson(t.instructionsPath)
    if ins.found and ins.error.len == 0: result.instructions = ins.node
  if t.hasManifest:
    result.steps = t.manifest.execution.steps
    result.frames = t.manifest.execution.frames
    result.truncated = t.manifest.execution.truncated
    result.sourceLevel = t.manifest.execution.sourceLevel
    result.ending = t.manifest.execution.ending
    result.languages = t.manifest.execution.languages

  # The source bundle the manifest recommends, for the first code hash the
  # transaction executed. One hash covers the demo's single-contract
  # transactions; a multi-contract transaction resolves the rest the same way,
  # and the pane shows whichever documents resolved.
  let hashes = codeHashes(tr.view.facts)
  if hashes.len == 0:
    result.sourceBundleReason = "this transaction executed no contract code"
    return
  let reference = resolveSourceBundle(r.store, info.slug, t.manifest,
                                      t.hasManifest, hashes[0])
  if reference.origin == bsNone:
    result.sourceBundleReason = reference.reason
    return
  let fetched = fetchSourceBundle(r.store, reference)
  case fetched.outcome
  of boLoaded:
    let raw = r.store.getJson(reference.path)
    if raw.found and raw.error.len == 0:
      result.sourceBundle = raw.node
    else:
      result.sourceBundleReason = raw.error
  else:
    # `boMismatched` in particular is REFUSED, never displayed: a bundle filed
    # under a different code hash would attribute source to code that never
    # ran (Source-Resolution.md §4).
    result.sourceBundleReason = fetched.reason

# ── the chain registry, as the /chains capability inventory ────────────────
#
# Page-Descriptions §3: "This page must be generated from the registry, never
# hand-maintained, so it cannot drift from reality." So every column below is
# read from a published object — the registry row for the recorder pin, the
# sealed generation's summary for coverage and freshness — and there is no
# literal chain name, tier or note anywhere in the view that renders it.

type
  ChainRow* = object
    ## One row of `/chains`. `opened = false` is a real row, not a skipped one:
    ## a chain the registry publishes and whose pointer cannot be resolved is
    ## exactly the case a capability inventory exists to disclose.
    slug*: string
    opened*: bool
    reason*: string
    info*: ChainInfo

proc chainRows*(r: DataRoot): seq[ChainRow] =
  for slug in chains(r):
    let opened = openChain(r.store, slug)
    if opened.outcome != ooOpened:
      result.add ChainRow(slug: slug, opened: false, reason: opened.reason)
    else:
      result.add ChainRow(slug: slug, opened: true, info: chainInfo(r, slug))

# ── labels: names, keyed outside the generation (§2.1a) ────────────────────

type
  LabelRow* = object
    ## One entry of `/d/{chain}/labels/{shard}.json` — a NAME for an address,
    ## with the provenance that ranks it (Search-And-Routing §6.2).
    id*, kind*, name*, symbol*, provenance*: string

proc labels*(r: DataRoot, chain: string): seq[LabelRow] =
  ## Every published label for a chain, in published order.
  ##
  ## Labels are deliberately outside the generation (§2.1a: "cosmetic naming
  ## cannot make a page incorrect, only less annotated"), so this read does not
  ## take a `ChainInfo` and a missing shard is silence rather than an error.
  var shard = 0
  while true:
    let res = r.store.getJson("d/" & chain & "/labels/" & $shard & ".json")
    if not res.found: break
    if res.error.len == 0 and not res.node.isNil and res.node.kind == JObject and
       res.node.hasKey("labels") and res.node["labels"].kind == JArray:
      for l in res.node["labels"]:
        result.add LabelRow(
          id: l{"id"}.getStr, kind: l{"kind"}.getStr, name: l{"name"}.getStr,
          symbol: l{"symbol"}.getStr, provenance: l{"provenance"}.getStr)
    inc shard

proc labelFor*(rows: seq[LabelRow], id: string): LabelRow =
  for l in rows:
    if l.id == id: return l

# ── the capability tour ────────────────────────────────────────────────────

proc tour*(r: DataRoot, info: ChainInfo): seq[TourRow] =
  ## The chain's capability tour, in the order the generation published it.
  ##
  ## Read from the pinned generation and not from a compiled-in copy of
  ## `fixtures/trace/tour/manifest.json`, for the reason every other read on a
  ## rendered page is: a tour whose transaction hashes came from somewhere other
  ## than the tree would go on rendering links after the tree stopped publishing
  ## them, and each dead link would be a session that does not open.
  ##
  ## A chain with no `tour.json` has no tour — an empty result, not an error.
  ## Every chain but the demo one is in that case and always will be: a tour is
  ## a claim about programs someone wrote to be read, and a captured chain has
  ## none.
  let res = r.store.getJson(
    "d/" & info.slug & "/g/" & info.generation & "/tour.json")
  if not res.found or res.error.len > 0 or res.node.isNil or
     res.node.kind != JObject or not res.node.hasKey("programs"):
    return
  for p in res.node["programs"]:
    var row = TourRow(
      id: p{"id"}.getStr, title: p{"title"}.getStr,
      summary: p{"summary"}.getStr, tx: p{"tx"}.getStr,
      steps: p{"steps"}.getInt, calls: p{"calls"}.getInt)
    if p.hasKey("capabilities") and p["capabilities"].kind == JArray:
      for c in p["capabilities"]: row.capabilities.add c.getStr
    if p.hasKey("language") and p["language"].kind == JArray:
      for l in p["language"]: row.language.add l.getStr
    # A row without a transaction is a row whose link goes nowhere. Drop it
    # rather than render a control that cannot be used.
    if row.id.len > 0 and row.tx.len > 0:
      result.add row

# ── address history: block-range segments, never ordinal pages (§2.2) ──────

type
  AddressSegmentRow* = object
    ## One immutable block-range page of an address's history.
    path*: string
    fromBlock*, toBlock*: int
    transactions*: seq[string]
    loaded*: bool
      ## `false` when the generation listed the segment and the object did not
      ## resolve. The row is still returned: dropping it would make the page
      ## silently shorter and make "older" step over a gap nobody was told
      ## about.

  AddressView* = object
    ## What `/{chain}/address/{address}` renders, at ONE segment.
    ##
    ## Deliberately not "the address's transactions": §2.2 stores history as
    ## segments keyed by block range precisely so that a page costs one segment
    ## rather than a whole history, and a projection that flattened them would
    ## put the cap back that the storage layout exists to remove.
    address*: string
    indexed*: bool
    reason*: string
    segmentPaths*: seq[string]   ## in the generation's display order, newest first
    index*: int                  ## which segment this view is positioned on, -1 for none
    segment*: AddressSegmentRow

proc addressSegmentPaths*(r: DataRoot, info: ChainInfo,
                          address: string): tuple[found: bool, reason: string,
                                                  paths: seq[string]] =
  ## The generation's segment list for an address. ONE read, whatever the
  ## length of the history.
  let res = r.store.getJson(addressIndexPath(info.slug, info.generation, address))
  if not res.found:
    return (false,
      address & " has no history in generation " & info.generation &
      " of " & info.slug, @[])
  if res.error.len > 0 or res.node.isNil or res.node.kind != JObject:
    return (false,
      (if res.error.len > 0: res.error else: "address index is not an object"),
      @[])
  var paths: seq[string]
  if res.node.hasKey("segments") and res.node["segments"].kind == JArray:
    for p in res.node["segments"]:
      if p.kind == JString and p.getStr.len > 0: paths.add p.getStr
  (true, "", paths)

proc readAddressSegment*(r: DataRoot, path: string): AddressSegmentRow =
  result.path = path
  let res = r.store.getJson(path)
  if not res.found or res.error.len > 0 or res.node.isNil or
     res.node.kind != JObject:
    return
  result.loaded = true
  result.fromBlock = res.node{"fromBlock"}.getInt
  result.toBlock = res.node{"toBlock"}.getInt
  if res.node.hasKey("transactions") and res.node["transactions"].kind == JArray:
    for t in res.node["transactions"]:
      if t.kind == JString: result.transactions.add t.getStr

func segmentIdOf*(path: string): string =
  ## The cursor a segment's published PATH carries, read out of the path rather
  ## than recomputed from the object — so a page link cannot name a range the
  ## generation did not list.
  var last = path
  let slash = path.rfind('/')
  if slash >= 0: last = path[slash + 1 .. ^1]
  if last.endsWith(".json"): last = last[0 ..< last.len - 5]
  last

func segmentId*(row: AddressSegmentRow): string =
  ## The cursor a paged URL carries: the block range itself.
  ##
  ## §2.2 rules out ordinal pages, so the page's identity in the URL is the
  ## same thing the object's identity is — a range of block numbers — and
  ## `?page=3` never exists to go stale when backfill discovers older history.
  $row.fromBlock & "-" & $row.toBlock

proc addressView*(r: DataRoot, info: ChainInfo, address: string;
                  segmentId = ""): AddressView =
  ## The address page at one segment: the newest by default, or the one whose
  ## block range the URL names.
  result.address = address
  result.index = -1
  let listed = addressSegmentPaths(r, info, address)
  result.indexed = listed.found
  result.reason = listed.reason
  result.segmentPaths = listed.paths
  if not listed.found or listed.paths.len == 0: return
  var want = 0
  if segmentId.len > 0:
    want = -1
    for i, p in listed.paths:
      # The path ENDS with the range, so matching on the suffix reads the
      # cursor out of the published path rather than re-deriving it.
      if p.endsWith("/" & segmentId & ".json"): want = i; break
    if want < 0:
      result.indexed = false
      result.reason = "no segment " & segmentId & " in " & address &
                      "'s history at generation " & info.generation
      return
  result.index = want
  # One segment read, for the one page being rendered. The naive shape — load
  # every segment, then show one page of it — makes per-page cost grow with the
  # length of the history, which is what `e2e_address_history_pagination_has_no_cap`
  # measures at depths 0, 1, 2500 and 4999 over a hundred thousand transactions.
  # That shape was briefly here as a deliberate mutation to prove the test bites;
  # it bit, and this is the implementation.
  result.segment = readAddressSegment(r, listed.paths[want])

proc addressRows*(r: DataRoot, info: ChainInfo, v: AddressView): seq[TxRow] =
  ## The transactions of the segment this view is positioned on.
  if v.index < 0: return
  for h in v.segment.transactions:
    if r.store.get(txFactsPath(info.slug, h)).found:
      result.add txRow(r, info, h)

proc codeHashesAt*(r: DataRoot, info: ChainInfo, address: string,
                   rows: seq[TxRow]): seq[string] =
  ## The code hashes bound to THIS address by the transactions on this page.
  ##
  ## Filtered by address rather than taking every hash a transaction touched:
  ## a transaction that also called three other contracts would otherwise make
  ## this address look verified because somebody else's code is
  ## (`viewmodel/address_vm.codeHashesFor`, same rule, same reason).
  for row in rows:
    let tr = transaction(r.store, info.session, row.hash)
    if tr.outcome != roFound: continue
    for e in tr.view.facts.codeEdges:
      if e.address == address and e.codeHash.len > 0 and e.codeHash notin result:
        result.add e.codeHash

# ── verified source, by code hash (Source-Resolution.md §5) ────────────────

type
  SourceFile* = object
    path*, content*: string

  SourceBundleView* = object
    ## `/{chain}/address/{address}/code`'s subject. `resolved = false` is §14's
    ## "No verified source" row, and it carries the reason rather than an empty
    ## file tree.
    codeHash*: string
    resolved*: bool
    reason*: string
    origin*: string          ## which resolution route found it
    sourceBundleId*: string
    path*: string
    match*: string
    provider*, language*: string
    compilerName*, compilerVersion*: string
    files*: seq[SourceFile]

proc sourceBundleAt*(r: DataRoot, chain, codeHash: string): SourceBundleView =
  ## Resolve a code hash to its best published bundle.
  ##
  ## Through the pointer (`/src/{chain}/{codeHash}/current.json`) rather than
  ## through a manifest: this page is about the code at an address, and an
  ## address is not an execution — there may be no trace to carry a
  ## recommendation. `resolveSourceBundle` owns the order and is given no
  ## manifest, which is the same function `traceView` calls with one.
  result.codeHash = codeHash
  let reference = resolveSourceBundle(r.store, chain, TraceManifest(), false,
                                      codeHash)
  result.origin = $reference.origin
  result.sourceBundleId = reference.sourceBundleId
  result.path = reference.path
  if reference.origin == bsNone:
    result.reason = reference.reason
    return
  let fetched = fetchSourceBundle(r.store, reference)
  if fetched.outcome != boLoaded:
    # `boMismatched` in particular is REFUSED rather than displayed: a bundle
    # filed under a different code hash would attribute source to code that
    # never ran (Source-Resolution.md §4).
    result.reason = fetched.reason
    return
  result.resolved = true
  result.match = $fetched.bundle.match
  result.provider = fetched.bundle.provider
  result.language = fetched.bundle.language
  result.compilerName = fetched.bundle.compilerName
  result.compilerVersion = fetched.bundle.compilerVersion
  if not fetched.bundle.sources.isNil and fetched.bundle.sources.kind == JObject:
    var paths: seq[string]
    for p, _ in fetched.bundle.sources: paths.add p
    paths.sort()
    for p in paths:
      result.files.add SourceFile(path: p,
        content: fetched.bundle.sources[p]{"content"}.getStr)

proc deploymentsOf*(r: DataRoot, info: ChainInfo, codeHash: string): seq[string] =
  ## Every address in this generation's address index that is bound to the same
  ## code hash — §10's "Deployments: other addresses sharing this code hash".
  ##
  ## Walked from the sealed root's `addr` map, which is the published
  ## enumeration of the generation's addresses, so this is a read of the data
  ## plane and not a directory listing.
  for rel in info.session.root.addrPaths:
    let res = r.store.getJson(rel)
    if not res.found or res.error.len > 0 or res.node.isNil: continue
    if res.node.kind != JObject: continue
    let address = res.node{"address"}.getStr
    if address.len == 0 or address in result: continue
    var segs: seq[string]
    if res.node.hasKey("segments") and res.node["segments"].kind == JArray:
      for p in res.node["segments"]:
        if p.kind == JString: segs.add p.getStr
    if segs.len == 0: continue
    # The newest segment is enough to decide whether this address carries the
    # code hash: a code edge binds an address to code, and the binding is on
    # every transaction that ran it.
    let seg = readAddressSegment(r, segs[0])
    for h in seg.transactions:
      let tr = transaction(r.store, info.session, h)
      if tr.outcome != roFound: continue
      for e in tr.view.facts.codeEdges:
        if e.address == address and e.codeHash == codeHash:
          result.add address
          break
    if address in result: continue

proc addressesInGeneration*(r: DataRoot, info: ChainInfo): seq[string] =
  ## Every address the sealed generation indexes, in the root's own order.
  for rel in info.session.root.addrPaths:
    let res = r.store.getJson(rel)
    if not res.found or res.error.len > 0 or res.node.isNil: continue
    if res.node.kind != JObject: continue
    let address = res.node{"address"}.getStr
    if address.len > 0 and address notin result: result.add address
