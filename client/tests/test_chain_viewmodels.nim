## SDK-CONSUMER: Tier-1 tests for BlockTracer's own ViewModel layer.
##
## M12's ViewModel layer — Front-End-Architecture §3's table — driven headlessly
## with no renderer, in the style Front-End-Architecture §6 asks for: "ViewModel
## unit tests — all state, all derivations", "the whole explorer is Tier-1
## testable against a mock chain".
##
## ## What plays the part of `MockBackendService` here
##
## M2b's suites drive the Embed SDK's ViewModels through `MockBackendService`.
## The equivalent seam on this side of the boundary already exists and is
## better: `@blocktracer/client`'s `ObjectStore` is a single injected
## `path -> bytes` closure, so a "mock chain" is a directory, and `deliveryStore`
## turns it into a transport that can also be made unreachable. Every test below
## therefore drives real Client SDK code over real bytes, and nothing about the
## data path is mocked away — which is the difference between testing the
## ViewModels and testing a fake.
##
## `recordingStore` / `RequestLog` are the SDK's own read-counter, so claims
## about how many reads something costs are measured rather than asserted.
##
## ## The discipline this file follows
##
## Three rules, taken from M2b and M12a because both campaigns found the same
## failure mode — a suite that reports `ok` while testing nothing:
##
##   1. **Exhaustive walks, not samples.** `for d in ChainDegradation`,
##      `for s in JobState`, `for k in TraceResolutionKind`, and every one of the
##      16 host-probe combinations. A row added to a catalogue and rendered by
##      nobody has to fail this file.
##   2. **Every §14 row is established from a TREE**, not from a hand-set enum,
##      and `EstablishedRows` records which — with a final test asserting the
##      record covers the catalogue. A row that is only ever set by a test is
##      not a row this layer can establish.
##   3. **Mutation bites.** A check that has never been seen to fail has not
##      been shown to test anything, so the checks that matter are each broken
##      deliberately and asserted to bite.

import std/[unittest, os, json, strutils, tables]

import isonim/core/[signals, computation]

import viewmodel
import blocktracer/contract/model as contractModel
import blocktracer/contract/ids as contractIds

const
  Fixture = currentSourcePath().parentDir.parentDir.parentDir /
            "fixtures" / "trace" / "minimal_trace.ct"

proc tmpDir(name: string): string =
  result = getTempDir() / "blocktracer-m12-vm-test" / name
  removeDir result
  createDir result

proc writeJsonNl(path: string, node: JsonNode) =
  createDir parentDir(path)
  writeFile(path, node.pretty & "\n")

# ===========================================================================
# The mock chain.
#
# One parameterised builder rather than a fixture per case: every §14 row below
# differs from the undegraded tree in exactly one field, and a builder makes
# that difference visible at the call site instead of buried in a second copy of
# a tree. `defaultTree()` is the undegraded chain, and every test names the one
# thing it changed.
# ===========================================================================

type
  TreeOpts = object
    chain: string
    generation: string
    recorderPinned: bool
    historyFloor: int             ## 0 => the registry states none
    floorReason: string
    stale: bool                   ## summary.json's own flag
    headHeight: int               ## current.json's canonical tip
    indexedHeight: int            ## the height the generation actually indexed
    txCanonical: bool
    txStatePublished: bool
    reIncludedIn: string
    availability: TraceAvailability
    publishManifest: bool
    truncated: bool
    manifestValidation: ValidationStatus
    overlayValidation: ValidationStatus
    overlayHasValidation: bool
    reconstructed: bool
    codeEdges: bool
    bundlePublished: bool
    bundleMatch: string           ## "full" / "partial"
    bundleWrongCodeHash: bool
    containerBlockSize: int

  Tree = object
    dir: string
    chain: string
    tx: string
    blk: string
    codeHash: string
    address: string
    traceArtifactId: string
    height: int

func defaultOpts(): TreeOpts =
  TreeOpts(
    chain: "eth", generation: "1",
    recorderPinned: true,
    historyFloor: 0, stale: false,
    headHeight: 19_000_000, indexedHeight: 19_000_000,
    txCanonical: true, txStatePublished: true,
    availability: taReady, publishManifest: true,
    truncated: false,
    manifestValidation: vsMatch,
    overlayValidation: vsMatch, overlayHasValidation: true,
    reconstructed: false,
    codeEdges: true,
    bundlePublished: true, bundleMatch: "full", bundleWrongCodeHash: false,
    containerBlockSize: 4096,
  )

proc buildTree(dir: string; o: TreeOpts): Tree =
  let chain = o.chain
  let recId = "evm"
  let recVer = "1.0.0"
  let recBuild = recorderBuildHash(recId, recVer)
  let profH = contractIds.profileHash("default")
  let traceSchema = "ctfs/v4"

  var chainEntry = %*{
    "recorder": {"id": recId, "build": recBuild, "version": recVer},
    "profile": {"name": "default", "hash": profH},
    "traceSchema": traceSchema}
  if o.historyFloor > 0:
    chainEntry["historyFloor"] =
      %*{"height": o.historyFloor, "reason": o.floorReason}
  # A registry with the chain present but no recorder pin is the tree shape
  # that produces `trkUnresolvable` — §14's "recorder unavailable" at chain
  # granularity. `decodeRecorderPin` needs `recorder`, so removing it is
  # exactly the condition, not an approximation of it.
  if not o.recorderPinned:
    chainEntry.delete("recorder")
  writeJsonNl(dir / "registry" / ("chains.v" & $ContractVersion & ".json"),
    %*{"version": ContractVersion, "chains": {chain: chainEntry}})

  let tx = "0xdeadbeef" & repeat("0", 56)
  let blk = "0xabc123" & repeat("0", 58)
  let codeHash = "0xc0de" & repeat("1", 36)
  let contractAddr = "0x3333" & repeat("0", 36)
  let execId = demoExecutionInputId(chain, tx, "call")

  var edges: seq[CodeEdge]
  if o.codeEdges:
    edges.add CodeEdge(address: contractAddr, codeHash: codeHash, boundAt: blk)
  let facts = contractModel.TransactionFacts(
    chain: chain,
    id: TxId(kind: tikHash, hash: tx),
    order: TxOrder(kind: tokBlockIndex, obBlock: blk,
                   obHeight: o.indexedHeight, obIndex: 12),
    outcome: Outcome(overall: ooSucceeded, parts: @[]),
    roles: @[Role(role: "initiator", address: "0x1111" & repeat("0", 36))],
    cost: @[Cost(name: "gas", used: "21000", limit: "21000", price: "12",
                 unit: "gas", token: "ETH", refundable: false)],
    payloadRaw: "0xa9059cbb", payloadSelector: "0xa9059cbb",
    payloadTarget: contractAddr, logs: @[],
    codeEdges: edges,
    executions: @[Execution(selector: "call", executionInputId: execId)],
    native: %*{"evm": {"type": 2}})
  writeJsonNl(dir / "d" / chain / "tx" / hexShard(tx) / tx & ".json", facts.toJson)
  writeJsonNl(dir / "d" / chain / "block" / blk & ".json",
    contractModel.BlockDetail(chain: chain, hash: blk, height: o.indexedHeight,
      parentHash: "0x00", transactions: @[tx]).toJson)

  let txstateRel = "d" / chain / "g" / o.generation / "txstate" /
                   hexShard(tx) / tx & ".json"
  if o.txStatePublished:
    var st = %*{"chain": chain, "tx": tx, "canonical": o.txCanonical,
                "finality": "finalized"}
    if o.reIncludedIn.len > 0:
      st["reIncludedIn"] = %o.reIncludedIn
    writeJsonNl(dir / txstateRel, st)

  var single = ExecTrace(availability: o.availability, bytes: 36864,
                         reconstructed: o.reconstructed,
                         hasValidation: o.overlayHasValidation,
                         validation: ValidationSummary(
                           status: o.overlayValidation, strength: 2))
  if o.availability in {taAbsent, taUnsupported}:
    single.reason = "the producer's own words for why there is no trace"
    single.bytes = 0
  let ov = contractModel.TraceSelection(chain: chain, tx: tx, hasSingle: true,
                                        singleTrace: single)
  writeJsonNl(dir / "d" / chain / "ts" / "1" / hexShard(tx) / tx & ".json",
              ov.toJson)

  let tid = deriveTraceArtifactId(execId, recId, recBuild, profH, traceSchema)
  if o.publishManifest:
    let sh = traceShards(tid)
    let adir = dir / "t" / sh.a / sh.b / tid
    createDir adir
    let bytes = readFile(Fixture)
    writeFile(adir / "trace.ct", bytes)
    let manifest = contractModel.TraceManifest(schema: ContractVersion,
      traceArtifactId: tid, executionInputId: execId, chain: chain, tx: tx,
      recorder: RecorderRef(id: recId, build: recBuild, version: recVer),
      profile: ProfileRef(name: "default", hash: profH),
      sourceBundles: %*{codeHash: "sha1:" & repeat("ab", 20)},
      container: ContainerRef(file: "trace.ct", bytes: bytes.len,
        blockSize: o.containerBlockSize, hash: contentHashSha1(bytes)),
      execution: ExecutionSummary(steps: 100, frames: 5,
        truncated: o.truncated, sourceLevel: true, languages: @["solidity"]),
      validation: ValidationSummary(status: o.manifestValidation, strength: 2),
      validationOracle: "receipt-compare", prestateStrategy: "prestate-trace")
    writeJsonNl(adir / "manifest.json", manifest.toJson)

  if o.bundlePublished:
    let bundleId = "sha1:" & repeat("ab", 20)
    let declared = if o.bundleWrongCodeHash: "0xffff" & repeat("2", 36)
                   else: codeHash
    writeJsonNl(dir / "src" / chain / codeHash /
                (shortBundleHash(bundleId) & ".json"),
      %*{"schema": ContractVersion, "codeHash": declared, "chain": chain,
         "match": o.bundleMatch, "provider": "test", "language": "solidity",
         "compiler": {"name": "solc", "version": "0.8.24"},
         "sources": {}, "debug": {}})
    writeJsonNl(dir / "src" / chain / codeHash / "current.json",
      %*{"sourceBundleId": bundleId})

  # One address, one segment, referencing the transaction.
  let address = "0x1111" & repeat("0", 36)
  let segRel = "d" / chain / "seg" / hexShard(address) / address /
               ($o.indexedHeight & "-" & $o.indexedHeight & ".json")
  writeJsonNl(dir / segRel, %*{"chain": chain, "address": address,
    "fromBlock": o.indexedHeight, "toBlock": o.indexedHeight,
    "transactions": [tx]})
  let addrRel = "d" / chain / "g" / o.generation / "addr" /
                hexShard(address) / address & ".json"
  writeJsonNl(dir / addrRel,
    %*{"chain": chain, "address": address, "segments": [segRel]})

  let summaryRel = "d" / chain / "g" / o.generation / "summary.json"
  let heightRel = "d" / chain / "g" / o.generation / "height" / "0.json"
  let blocksRel = "d" / chain / "g" / o.generation / "blocks" / "0.json"
  writeJsonNl(dir / summaryRel, %*{"chain": chain, "generation": o.generation,
    "counters": {"blocks": 1, "transactions": 1}, "coverageMode": "eager",
    "stale": o.stale})
  writeJsonNl(dir / heightRel, %*{"chain": chain, "epoch": 0,
    "heights": {$o.indexedHeight: blk}})
  writeJsonNl(dir / blocksRel, %*{"chain": chain, "epoch": 0, "blocks": [blk]})
  let root = contractModel.GenerationRoot(contractVersion: ContractVersion,
    chain: chain, generation: o.generation, traceSelectionVersion: "1",
    summaryPath: summaryRel, heightPaths: @[heightRel],
    blockIndexPaths: @[blocksRel], addrPaths: @[addrRel],
    txstatePaths: (if o.txStatePublished: @[txstateRel] else: @[]))
  writeJsonNl(dir / "d" / chain / "g" / o.generation / "root.json", root.toJson)
  writeJsonNl(dir / "d" / chain / "current.json", %*{"chain": chain,
    "generation": o.generation, "traceSelectionVersion": "1",
    "head": {"height": o.headHeight, "hash": blk},
    "finalized": {"height": o.indexedHeight, "hash": blk}})

  Tree(dir: dir, chain: chain, tx: tx, blk: blk, codeHash: codeHash,
       address: address, traceArtifactId: tid, height: o.indexedHeight)

# ---------------------------------------------------------------------------
# The whole layer, wired the way a page wires it.
# ---------------------------------------------------------------------------

type Layer = object
  store: ObjectStore
  monitor: DeliveryMonitor
  registry: ChainRegistryVM
  chain: ChainVM
  traceStatus: TraceStatusVM
  artifact: ArtifactVM
  divergence: DivergenceVM
  sources: SourceBundleVM
  capability: CapabilityVM
  job: GenerationJobVM
  tx: TransactionVM
  blk: BlockVM
  address: AddressVM
  search: SearchVM

proc newLayer(store: ObjectStore; monitor: DeliveryMonitor): Layer =
  let registry = createChainRegistryVM(store)
  let chain = createChainVM(store, registry, monitor)
  let traceStatus = createTraceStatusVM(registry)
  let job = createGenerationJobVM()
  Layer(
    store: store, monitor: monitor, registry: registry, chain: chain,
    traceStatus: traceStatus,
    artifact: createArtifactVM(store),
    divergence: createDivergenceVM(),
    sources: createSourceBundleVM(store),
    capability: createCapabilityVM(),
    job: job,
    tx: createTransactionVM(store, registry, chain, traceStatus, job),
    blk: createBlockVM(store, registry, chain),
    address: createAddressVM(store, registry, chain),
    search: createSearchVM(store, registry, chain),
  )

proc openTree(t: Tree; monitor: DeliveryMonitor = nil): Layer =
  ## Open a built tree through the whole layer, exactly as a page would.
  let m = if monitor.isNil: newDeliveryMonitor() else: monitor
  let store = deliveryStore("test:" & t.dir, m, proc(path: string): TransportResult =
    let full = t.dir / path
    if fileExists(full): TransportResult(outcome: toOk, body: readFile(full))
    else: TransportResult(outcome: toMissing))
  result = newLayer(store, m)
  result.registry.loadRegistry()
  result.registry.selectChain(t.chain)
  result.chain.loadBlocks()

proc loadTx(l: Layer; t: Tree) =
  ## Everything a transaction page loads, in the order it loads it.
  l.tx.load(t.tx)
  if l.tx.found.val:
    l.artifact.resolveAll(l.registry.session.val, l.tx.view.val)
    l.traceStatus.floorVerdict.val =
      l.registry.floorVerdictFor(l.tx.view.val)
    l.traceStatus.setTrace(l.artifact.current.val)
    l.divergence.setTrace(l.artifact.current.val)
    l.capability.setArtifact(l.artifact.current.val)
    l.job.startedFromTrace(l.artifact.current.val)
    l.sources.setSubject(t.chain, l.tx.codeHashes.val)
    l.sources.loadAll(l.artifact.current.val.manifest,
                      l.artifact.current.val.hasManifest)

# ===========================================================================
# The record of which §14 rows this layer actually established FROM A TREE.
#
# Rule 2 of the discipline in the header. A test that sets an axis by hand
# proves the resolution works; only a test that drives a tree proves the layer
# can *establish* the row. This set is written by the row tests below and
# asserted at the end of the file.
# ===========================================================================
var EstablishedRows: set[ChainDegradation]

proc established(d: ChainDegradation) =
  EstablishedRows.incl d

# ===========================================================================
# 1. The catalogue itself — exhaustive, in M2b's idiom.
# ===========================================================================

suite "M12 — §14's chain rows are a catalogue, walked exhaustively":

  test "every ChainDegradation value is reachable on at least one surface":
    # The guard that catches an eighth row being added and rendered by nobody.
    var union: set[ChainDegradation]
    for s in AllSurfaceDegradations:
      union = union + s
    for d in ChainDegradation:
      if d == cdNone: continue
      check d in union

  test "the per-surface sensitivity sets cover the whole catalogue":
    var union: set[ChainDegradation]
    for s in AllSurfaceDegradations:
      union = union + s
    check union.card == ChainDegradation.high.ord   # 7, i.e. all but cdNone
    check cdNone notin union

  test "the precedence lists every row exactly once":
    var seen: set[ChainDegradation]
    for d in ChainDegradationPrecedence:
      check d notin seen
      seen.incl d
    for d in ChainDegradation:
      if d == cdNone: continue
      check d in seen

  test "every row has a snapshot in which it holds, and it is detected":
    # `for d in ChainDegradation` with a total `case` inside: adding a row
    # without giving it a snapshot is a compile error here, not a silent gap.
    for d in ChainDegradation:
      var s = initChainStateSnapshot()
      case d
      of cdNone: discard
      of cdCdnUnreachable: s.reachability = drCdnUnreachable
      of cdObjectNotFound: s.presence = opNotOnThisChain
      of cdReorganisedAway: s.canonicality = ccReorganisedAway
      of cdBelowHistoryFloor: s.provenance = tpBelowHistoryFloor
      of cdRecorderUnavailable: s.provenance = tpRecorderUnavailable
      of cdTraceAwaitingGeneration: s.provenance = tpAwaitingGeneration
      of cdPipelineBehindTip: s.freshness = pfBehindTip
      check s.chainDegradationPresent(d)
      if d != cdNone:
        check not s.chainDegradationPresent(cdNone)
        # It resolves on a surface that renders it, and only there.
        var renderedSomewhere = false
        for sens in AllSurfaceDegradations:
          if d in sens:
            check resolveChainDegradation(s, sens) == d
            renderedSomewhere = true
          else:
            check resolveChainDegradation(s, sens) != d
        check renderedSomewhere

  test "both non-present values are one page row, and both non-canonical ones are":
    # §14 gives one treatment per row; the finer distinction stays on the axis
    # so a page can still word the two differently.
    for p in [opNotOnThisChain, opMalformed]:
      var s = initChainStateSnapshot()
      s.presence = p
      check s.chainDegradationPresent(cdObjectNotFound)
    for c in [ccReorganisedAway, ccReIncluded]:
      var s = initChainStateSnapshot()
      s.canonicality = c
      check s.chainDegradationPresent(cdReorganisedAway)

  test "precedence: for every ordered pair, the earlier row wins":
    proc withRow(s: var ChainStateSnapshot; d: ChainDegradation) =
      case d
      of cdNone: discard
      of cdCdnUnreachable: s.reachability = drCdnUnreachable
      of cdObjectNotFound: s.presence = opNotOnThisChain
      of cdReorganisedAway: s.canonicality = ccReorganisedAway
      of cdBelowHistoryFloor: s.provenance = tpBelowHistoryFloor
      of cdRecorderUnavailable: s.provenance = tpRecorderUnavailable
      of cdTraceAwaitingGeneration: s.provenance = tpAwaitingGeneration
      of cdPipelineBehindTip: s.freshness = pfBehindTip

    var pairs = 0
    for i in 0 ..< ChainDegradationPrecedence.len:
      for j in (i + 1) ..< ChainDegradationPrecedence.len:
        let a = ChainDegradationPrecedence[i]
        let b = ChainDegradationPrecedence[j]
        # The three provenance rows are one axis and cannot co-occur; a test
        # that pretended they could would assert a precedence that no snapshot
        # can produce.
        let bothProvenance =
          a in {cdBelowHistoryFloor, cdRecorderUnavailable,
                cdTraceAwaitingGeneration} and
          b in {cdBelowHistoryFloor, cdRecorderUnavailable,
                cdTraceAwaitingGeneration}
        if bothProvenance: continue
        var s = initChainStateSnapshot()
        s.withRow(a)
        s.withRow(b)
        check s.chainDegradationPresent(a)
        check s.chainDegradationPresent(b)
        check resolveChainDegradation(s, {a, b}) == a
        inc pairs
    check pairs > 0

  test "the CDN row outranks not-found, which is the whole reason it exists":
    var s = initChainStateSnapshot()
    s.reachability = drCdnUnreachable
    s.presence = opNotOnThisChain
    check resolveChainDegradation(s, SearchDegradations) == cdCdnUnreachable

  test "a surface that is not sensitive resolves cdNone, not a weaker row":
    var s = initChainStateSnapshot()
    s.provenance = tpRecorderUnavailable
    check resolveChainDegradation(s, TransactionDegradations) ==
      cdRecorderUnavailable
    check resolveChainDegradation(s, ChainOverviewDegradations) == cdNone
    check resolveChainDegradation(s, SearchDegradations) == cdNone

  test "the undegraded snapshot resolves cdNone on every surface":
    let s = initChainStateSnapshot()
    for sens in AllSurfaceDegradations:
      check resolveChainDegradation(s, sens) == cdNone
    check s.chainDegradationPresent(cdNone)

  test "MUTATION BITE: a row missing from every sensitivity set is caught":
    # The check in the first test, run against a deliberately holed catalogue.
    const Holed: array[6, set[ChainDegradation]] = [
      ChainOverviewDegradations - {cdPipelineBehindTip},
      BlockDegradations - {cdPipelineBehindTip},
      TransactionDegradations,
      AddressDegradations - {cdPipelineBehindTip},
      SearchDegradations,
      DebugRouteDegradations,
    ]
    var union: set[ChainDegradation]
    for s in Holed: union = union + s
    check cdPipelineBehindTip notin union    # the hole exists
    check union.card < ChainDegradation.high.ord   # and the cover check bites

  test "MUTATION BITE: a precedence with two rows swapped is caught":
    var s = initChainStateSnapshot()
    s.reachability = drCdnUnreachable
    s.presence = opNotOnThisChain
    # The real order gives cdCdnUnreachable; a resolver walking the reverse
    # order would give cdObjectNotFound, which is the false statement.
    var reversed: ChainDegradation = cdNone
    for i in countdown(ChainDegradationPrecedence.len - 1, 0):
      let c = ChainDegradationPrecedence[i]
      if c in SearchDegradations and s.chainDegradationPresent(c):
        reversed = c
        break
    check reversed == cdObjectNotFound
    check reversed != resolveChainDegradation(s, SearchDegradations)

# ===========================================================================
# 2. Each of §14's seven chain rows, ESTABLISHED FROM A TREE.
# ===========================================================================

suite "M12 — §14 row 1: pipeline behind the chain tip":
  test "the published stale flag is surfaced, not inferred":
    var o = defaultOpts()
    o.stale = true
    let t = buildTree(tmpDir("stale-flag"), o)
    let l = openTree(t)
    check l.chain.freshness.val == pfBehindTip
    check l.chain.blocksBehind.val == 0    # the flag said so; no distance implied
    check resolveChainDegradation(
      ChainStateSnapshot(freshness: l.chain.freshness.val,
                         presence: opPresent, canonicality: ccCanonical,
                         provenance: tpAvailable, reachability: drReachable),
      ChainOverviewDegradations) == cdPipelineBehindTip
    established cdPipelineBehindTip

  test "the distance is measured, and names how far behind":
    var o = defaultOpts()
    o.headHeight = 19_000_007
    o.indexedHeight = 19_000_000
    let t = buildTree(tmpDir("stale-distance"), o)
    let l = openTree(t)
    check l.chain.freshness.val == pfBehindTip
    check l.chain.blocksBehind.val == 7
    check l.chain.head.val.height == 19_000_007
    check l.chain.indexedHead.val.height == 19_000_000

  test "a current pipeline is not degraded, and the distance is zero":
    let t = buildTree(tmpDir("current"), defaultOpts())
    let l = openTree(t)
    check l.chain.freshness.val == pfCurrent
    check l.chain.blocksBehind.val == 0
    check l.blk.degradation.val == cdNone

  test "MUTATION BITE: an indexed height ABOVE the pointer is not negative lag":
    var o = defaultOpts()
    o.headHeight = 19_000_000
    o.indexedHeight = 19_000_005
    let t = buildTree(tmpDir("negative-lag"), o)
    let l = openTree(t)
    check l.chain.blocksBehind.val == 0
    check l.chain.freshness.val == pfCurrent

suite "M12 — §14 row 2: object not found, with the chains checked":
  test "a hash on no chain reports not-found and names what was searched":
    let t = buildTree(tmpDir("notfound"), defaultOpts())
    let l = openTree(t)
    l.search.setQuery("0x" & repeat("9", 64))
    l.search.resolve()
    check l.search.results.val.len == 0
    check l.search.chainsChecked.val == @[t.chain]
    check l.search.presence.val == opNotOnThisChain
    check l.search.degradation.val == cdObjectNotFound
    established cdObjectNotFound

  test "a hash that IS on the chain resolves, and is not degraded":
    let t = buildTree(tmpDir("found"), defaultOpts())
    let l = openTree(t)
    l.search.setQuery(t.tx)
    l.search.resolve()
    check l.search.results.val.len == 1
    check l.search.results.val[0].kind == rkTransaction
    check l.search.degradation.val == cdNone

  test "a block hash and a transaction hash are both tried, per §2's ambiguity":
    let t = buildTree(tmpDir("ambiguous"), defaultOpts())
    let l = openTree(t)
    check qsHash32 in shapesOf(t.blk)
    l.search.setQuery(t.blk)
    l.search.resolve()
    check l.search.results.val.len == 1
    check l.search.results.val[0].kind == rkBlock

  test "a shape only the blocked mechanisms could resolve is NOT reported absent":
    let t = buildTree(tmpDir("unsupported-shape"), defaultOpts())
    let l = openTree(t)
    l.search.setQuery("uniswap")
    l.search.resolve()
    check l.search.mechanism.val == smUnsupportedShape
    check l.search.presence.val == opPresent    # nothing was looked in
    check l.search.degradation.val == cdNone

  test "shape detection is total over the classes it claims":
    check shapesOf("") == {qsEmpty}
    check qsDecimal in shapesOf("18000000")
    check qsHash32 in shapesOf("0x" & repeat("a", 64))
    check qsAddress20 in shapesOf("0x" & repeat("a", 40))
    check qsHexShort in shapesOf("0x" & repeat("a", 40))   # also a felt
    check qsHexShort in shapesOf("0xabc")
    check qsText in shapesOf("uniswap")
    check qsText in shapesOf("0xzz")     # not hex: text, not a hash

  test "local inference costs no request at all":
    let t = buildTree(tmpDir("numeric"), defaultOpts())
    let log = newRequestLog()
    let m = newDeliveryMonitor()
    let inner = deliveryStore("t", m, proc(path: string): TransportResult =
      let full = t.dir / path
      if fileExists(full): TransportResult(outcome: toOk, body: readFile(full))
      else: TransportResult(outcome: toMissing))
    let store = recordingStore(inner, log)
    let l = newLayer(store, m)
    l.registry.loadRegistry()
    l.registry.selectChain(t.chain)
    l.chain.loadBlocks()
    let before = log.paths.len
    l.search.setQuery($t.height)
    l.search.resolve()
    check log.paths.len == before     # §3: "without issuing a single" request
    check l.search.results.val.len == 1
    check l.search.results.val[0].kind == rkBlock

  test "a malformed object is not 'not on this chain'":
    let t = buildTree(tmpDir("malformed"), defaultOpts())
    writeFile(t.dir / "d" / t.chain / "tx" / hexShard(t.tx) / (t.tx & ".json"),
              "{ this is not json")
    let l = openTree(t)
    l.tx.load(t.tx)
    check l.tx.outcome.val == roMalformed
    check l.tx.presence.val == opMalformed
    check l.tx.degradation.val == cdObjectNotFound   # one page row
    check l.tx.reason.val.len > 0                    # with the parse error

suite "M12 — §14 row 3: trace awaiting generation":
  test "an on-demand overlay with no published artifact awaits generation":
    var o = defaultOpts()
    o.availability = taOnDemand
    o.publishManifest = false
    let t = buildTree(tmpDir("ondemand"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.artifact.current.val.kind == trkOnDemand
    check not l.artifact.current.val.hasManifest
    check l.traceStatus.provenance.val == tpAwaitingGeneration
    check l.job.state.val == jsIdle
    check l.job.generationPending.val
    check l.job.provenance.val == tpAwaitingGeneration
    check l.tx.degradation.val == cdTraceAwaitingGeneration
    established cdTraceAwaitingGeneration

  test "an on-demand overlay whose artifact HAS since been published is ready":
    var o = defaultOpts()
    o.availability = taOnDemand
    o.publishManifest = true
    let t = buildTree(tmpDir("ondemand-published"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.artifact.current.val.hasManifest
    check l.traceStatus.provenance.val == tpAvailable
    check l.job.state.val == jsReady
    check l.tx.degradation.val == cdNone

  test "a page whose trace is ready does not show the awaiting row":
    let t = buildTree(tmpDir("ready"), defaultOpts())
    let l = openTree(t)
    l.loadTx(t)
    check l.tx.degradation.val == cdNone
    check not l.job.generationPending.val

suite "M12 — §14 row 4: recorder unavailable for the VM":
  test "no recorder pinned in the registry is the chain-scoped case":
    var o = defaultOpts()
    o.recorderPinned = false
    let t = buildTree(tmpDir("no-pin"), o)
    let l = openTree(t)
    check not l.registry.recorderPinned.val
    l.loadTx(t)
    check l.artifact.current.val.kind == trkUnresolvable
    check l.traceStatus.recorderUnavailableScope.val == rsChain
    check l.traceStatus.provenance.val == tpRecorderUnavailable
    check l.traceStatus.reason.val.len > 0
    check l.tx.degradation.val == cdRecorderUnavailable
    established cdRecorderUnavailable

  test "an `unsupported` overlay is the execution-scoped case, in the producer's words":
    var o = defaultOpts()
    o.availability = taUnsupported
    o.publishManifest = false
    let t = buildTree(tmpDir("unsupported"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.artifact.current.val.kind == trkUnsupported
    check l.traceStatus.recorderUnavailableScope.val == rsExecution
    check l.traceStatus.provenance.val == tpRecorderUnavailable
    check l.traceStatus.reason.val ==
      "the producer's own words for why there is no trace"
    check l.tx.degradation.val == cdRecorderUnavailable

  test "the two scopes are distinguishable, which is why they are separate":
    check rsChain != rsExecution

suite "M12 — §14 row 5: transaction below the history floor":
  test "a floor above the transaction refuses, stating the floor":
    var o = defaultOpts()
    o.historyFloor = 19_500_000
    o.floorReason = "prestate is not archived below this height"
    let t = buildTree(tmpDir("below-floor"), o)
    let l = openTree(t)
    check l.registry.floor.val.stated
    check l.registry.floor.val.height == 19_500_000
    l.loadTx(t)
    check l.traceStatus.floorVerdict.val == fvBelow
    check l.traceStatus.provenance.val == tpBelowHistoryFloor
    check "19500000" in l.traceStatus.reason.val
    check "prestate is not archived below this height" in l.traceStatus.reason.val
    check l.tx.degradation.val == cdBelowHistoryFloor
    established cdBelowHistoryFloor

  test "a floor below the transaction does not refuse":
    var o = defaultOpts()
    o.historyFloor = 18_000_000
    let t = buildTree(tmpDir("above-floor"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.traceStatus.floorVerdict.val == fvAbove
    check l.tx.degradation.val == cdNone

  test "a registry that states NO floor reports fvUnstated, never fvAbove":
    # The honest answer for every tree any producer in this repository writes
    # today. `fvUnstated` and `fvAbove` must not be the same value: one means
    # "we know it is fine", the other means "nobody said".
    let t = buildTree(tmpDir("no-floor"), defaultOpts())
    let l = openTree(t)
    check not l.registry.floor.val.stated
    l.loadTx(t)
    check l.traceStatus.floorVerdict.val == fvUnstated
    check l.tx.degradation.val == cdNone

  test "a chain that does not order by height cannot be compared to a floor":
    var o = defaultOpts()
    o.historyFloor = 19_500_000
    let t = buildTree(tmpDir("no-height"), o)
    let l = openTree(t)
    # A Hedera-shaped position: ordered by consensus time, no height at all.
    check l.registry.floorVerdict(BlockPosition(known: false)) == fvNotComparable
    check l.registry.floorVerdict(BlockPosition(known: true, height: 19_000_000)) == fvBelow

  test "both registry spellings of the floor are read":
    check readHistoryFloor(%*{"chains": {"eth": {"historyFloor": 42}}}, "eth") ==
      HistoryFloor(stated: true, height: 42)
    check readHistoryFloor(
      %*{"chains": {"eth": {"historyFloor": {"height": 42, "reason": "x"}}}},
      "eth") == HistoryFloor(stated: true, height: 42, reason: "x")
    check not readHistoryFloor(%*{"chains": {"eth": {}}}, "eth").stated
    check not readHistoryFloor(newJObject(), "eth").stated

suite "M12 — §14 row 6: reorganised away":
  test "a non-canonical transaction is reorganised away":
    var o = defaultOpts()
    o.txCanonical = false
    let t = buildTree(tmpDir("reorg"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.tx.reorg.val.known
    check l.tx.reorg.val.canonicality == ccReorganisedAway
    check l.tx.reorg.val.reIncludedIn == ""
    check l.tx.degradation.val == cdReorganisedAway
    established cdReorganisedAway

  test "a re-included transaction states the new location":
    var o = defaultOpts()
    o.txCanonical = false
    o.reIncludedIn = "0xnewblock" & repeat("0", 54)
    let t = buildTree(tmpDir("reincluded"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.tx.reorg.val.canonicality == ccReIncluded
    check l.tx.reorg.val.reIncludedIn == "0xnewblock" & repeat("0", 54)
    check l.tx.degradation.val == cdReorganisedAway   # one page row, two actions

  test "silence is not a reorg":
    # A generation that has not indexed a transaction is a lagging pipeline,
    # not a rewritten chain, and fabricating a reorg from it would be the worst
    # available reading of an absent object.
    var o = defaultOpts()
    o.txStatePublished = false
    let t = buildTree(tmpDir("no-txstate"), o)
    let l = openTree(t)
    l.loadTx(t)
    check not l.tx.reorg.val.known
    check l.tx.reorg.val.canonicality == ccCanonical
    check l.tx.degradation.val == cdNone

  test "a block the generation no longer indexes is reorganised away":
    let t = buildTree(tmpDir("reorg-block"), defaultOpts())
    let l = openTree(t)
    l.blk.load(t.blk)
    check l.blk.found.val
    check l.blk.inGeneration.val
    check l.blk.degradation.val == cdNone
    # Rewrite the height map so the generation no longer lists this block —
    # which is exactly what a reorg does (§2.2's "the height -> hash mapping a
    # reorg rewrites").
    writeJsonNl(t.dir / "d" / t.chain / "g" / "1" / "height" / "0.json",
      %*{"chain": t.chain, "epoch": 0,
         "heights": {$t.height: "0xother" & repeat("0", 57)}})
    let l2 = openTree(t)
    l2.blk.load(t.blk)
    check l2.blk.found.val          # the block detail is content-addressed
    check not l2.blk.inGeneration.val
    check l2.blk.degradation.val == cdReorganisedAway

suite "M12 — §14 row 7: CDN unreachable":
  test "an unanswered read is not evidence of absence":
    let t = buildTree(tmpDir("cdn"), defaultOpts())
    let m = newDeliveryMonitor()
    var offline = false
    let store = deliveryStore("flaky", m, proc(path: string): TransportResult =
      if offline: return TransportResult(outcome: toUnreachable)
      let full = t.dir / path
      if fileExists(full): TransportResult(outcome: toOk, body: readFile(full))
      else: TransportResult(outcome: toMissing))
    let l = newLayer(store, m)
    l.registry.loadRegistry()
    l.registry.selectChain(t.chain)
    l.chain.loadBlocks()
    check l.chain.reachability.val == drReachable

    offline = true
    l.search.setQuery(t.tx)
    l.search.resolve()
    check l.chain.reachability.val == drCdnUnreachable
    check l.search.results.val.len == 0
    # The whole point: the page says the origin is unreachable, NOT that the
    # transaction is not on this chain.
    check l.search.degradation.val == cdCdnUnreachable
    check l.search.degradation.val != cdObjectNotFound
    established cdCdnUnreachable

  test "a 404 is a success of the transport and clears the failure run":
    let m = newDeliveryMonitor()
    m.noteRead("a", toUnreachable)
    check not m.reachable.val
    m.noteRead("b", toMissing)
    check m.reachable.val
    check m.consecutiveFailures.val == 0

  test "the threshold is honoured, and recovery resets it":
    let m = newDeliveryMonitor(unreachableAfter = 3)
    m.noteRead("a", toUnreachable)
    m.noteRead("b", toUnreachable)
    check m.reachable.val
    m.noteRead("c", toUnreachable)
    check not m.reachable.val
    check m.lastUnreachablePath.val == "c"
    m.noteRead("d", toOk)
    check m.reachable.val

  test "MUTATION BITE: a transport that reported toMissing for a dead origin lies":
    # The same offline tree read through a store that cannot tell the two
    # apart — which is what every consumer that skips `deliveryStore` gets.
    let t = buildTree(tmpDir("cdn-bite"), defaultOpts())
    let m = newDeliveryMonitor()
    let blind = deliveryStore("blind", m, proc(path: string): TransportResult =
      TransportResult(outcome: toMissing))
    let l = newLayer(blind, m)
    l.registry.chains.val = @[t.chain]
    l.search.setQuery(t.tx)
    l.search.resolve()
    check l.chain.reachability.val == drReachable        # nothing was noticed
    check l.search.degradation.val != cdCdnUnreachable   # ... and the row is lost

suite "M12 — every §14 chain row was established from a tree":
  test "the record covers the catalogue, with nothing set only by hand":
    var missing: seq[string]
    for d in ChainDegradation:
      if d == cdNone: continue
      if d notin EstablishedRows: missing.add $d
    if missing.len > 0:
      echo "  rows modelled but never established from a tree: ", missing
    check missing.len == 0
    check EstablishedRows.card == ChainDegradation.high.ord

# ===========================================================================
# 3. The seam — the four axes the panes read, written from chain-shaped facts.
#
# This half runs with no Embed SDK on the path at all, which is the layering.
# The half that needs the real `ReplayDataStore` is `tests/tviewmodelseam.nim`.
# ===========================================================================

suite "M12 — the write half of the seam (Page-Descriptions §14.1a, §14.2)":

  test "retentionFor is total, and every TraceResolutionKind maps somewhere":
    # `for k in TraceResolutionKind` with a total case: a ninth kind added to
    # the Client SDK is a compile error here rather than a silent default.
    var reached: set[ArtifactRetention]
    for k in TraceResolutionKind:
      var r = ResolvedTrace(kind: k)
      case k
      of trkReady, trkDivergent, trkOnDemand:
        # Both sides of the manifest test, since that is what the value turns
        # on for these three.
        reached.incl retentionFor(r)
        r.hasManifest = true
        reached.incl retentionFor(r)
      else:
        reached.incl retentionFor(r)
    check arRetained in reached
    check arWindowExpired in reached
    check arNeverGenerated in reached
    check arUnreplayable in reached
    # THE REACHABILITY CENSUS. `arWindowedLive` is not reachable from the
    # current contract, because retention class is spec'd as a TraceSelection
    # field (Static-Site-Architecture §2.3b) that M5b's `ExecTrace` does not
    # carry. When that field lands, this assertion fails and `retentionFor`
    # must be updated — which is the point of asserting it rather than
    # omitting it.
    check arWindowedLive notin reached

  test "an overlay claiming `ready` with no published artifact is a WINDOW EXPIRY":
    # Trace-Artifacts §2.9: "a 404 under /t/ is now unambiguous — it means not
    # currently present, which is exactly the case that may become present
    # after a generation or a renewal."
    var o = defaultOpts()
    o.publishManifest = false
    let t = buildTree(tmpDir("expired"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.artifact.current.val.kind == trkReady
    check not l.artifact.current.val.hasManifest
    check l.artifact.retention.val == arWindowExpired
    check l.artifact.retention.val != arUnreplayable   # renewable, not terminal

  test "structural absence is terminal, and issues no read at all":
    var o = defaultOpts()
    o.availability = taAbsent
    o.publishManifest = false
    let t = buildTree(tmpDir("absent"), o)
    let log = newRequestLog()
    let m = newDeliveryMonitor()
    let inner = deliveryStore("t", m, proc(path: string): TransportResult =
      let full = t.dir / path
      if fileExists(full): TransportResult(outcome: toOk, body: readFile(full))
      else: TransportResult(outcome: toMissing))
    let l = newLayer(recordingStore(inner, log), m)
    l.registry.loadRegistry()
    l.registry.selectChain(t.chain)
    l.tx.load(t.tx)
    let before = log.paths.len
    l.artifact.resolveAll(l.registry.session.val, l.tx.view.val)
    check log.paths.len == before        # §2.3a: not a failed fetch
    check l.artifact.current.val.kind == trkAbsent
    check l.artifact.retention.val == arUnreplayable

  test "integrityFor ranks divergence above truncation, from either layer":
    var reached: set[ArtifactIntegrity]
    var complete = ResolvedTrace(kind: trkReady, hasManifest: true)
    reached.incl integrityFor(complete)
    check integrityFor(complete) == aiComplete

    var truncated = complete
    truncated.manifest.execution.truncated = true
    reached.incl integrityFor(truncated)
    check integrityFor(truncated) == aiTruncated

    var divergentManifest = truncated
    divergentManifest.manifest.validation.status = vsDivergent
    reached.incl integrityFor(divergentManifest)
    check integrityFor(divergentManifest) == aiDivergent   # ranked above

    var divergentOverlay = ResolvedTrace(kind: trkReady, hasValidation: true,
      validation: ValidationSummary(status: vsDivergent, strength: 1))
    check integrityFor(divergentOverlay) == aiDivergent     # before any fetch

    var byAvailability = ResolvedTrace(kind: trkDivergent)
    check integrityFor(byAvailability) == aiDivergent

    check reached == {aiComplete, aiTruncated, aiDivergent}

  test "verificationFor tells `nothing to verify` from `nothing published`":
    let loadedFull = BundleResult(outcome: boLoaded,
      bundle: SourceBundle(match: mqFull))
    let loadedPartial = BundleResult(outcome: boLoaded,
      bundle: SourceBundle(match: mqPartial))
    let notPublished = BundleResult(outcome: boNotPublished, reason: "none")
    let mismatched = BundleResult(outcome: boMismatched, reason: "wrong hash")

    check verificationFor([], 0) == svAbsent            # no code ran at all
    check verificationFor([], 1) == svUnverified        # a hash, nothing fetched
    check verificationFor([loadedFull], 1) == svVerified
    check verificationFor([loadedPartial], 1) == svUnverified
    check verificationFor([notPublished], 1) == svUnverified
    check verificationFor([mismatched], 1) == svUnverified
    check verificationFor([loadedFull], 2) == svUnverified   # one of two
    # All three values reachable — the census for this axis.
    var reached: set[SourceVerification]
    for v in [verificationFor([], 0), verificationFor([loadedFull], 1),
              verificationFor([notPublished], 1)]:
      reached.incl v
    check reached == {svAbsent, svVerified, svUnverified}

  test "the body carries only the axes that were learned":
    var u = ReplayStatusUpdate()
    check u.isEmpty
    check u.toReplayStatusBody.len == 0
    u.hasCapability = true
    u.capability = hcWorkerUnsupported
    check not u.isEmpty
    let body = u.toReplayStatusBody
    check body.len == 1
    check body["capability"].getStr == "worker-unsupported"
    check not body.hasKey("availability")

  test "every wire spelling is the §14 table row, not the Nim identifier":
    # The strings `ReplayDataStore.applyReplayStatus` parses. Asserted here as
    # a local contract; asserted against the REAL parsers in
    # tests/tviewmodelseam.nim, which is what makes drift on either side fail.
    check $arRetained == "retained"
    check $arWindowedLive == "windowed-live"
    check $arWindowExpired == "window-expired"
    check $arNeverGenerated == "never-generated"
    check $arUnreplayable == "unreplayable"
    check $aiComplete == "complete"
    check $aiTruncated == "truncated"
    check $aiDivergent == "divergent"
    check $hcCapable == "capable"
    check $hcWasmCompilationFailed == "wasm-compilation-failed"
    check $hcInsufficientMemory == "insufficient-memory"
    check $hcRangeRequestsUnsupported == "range-requests-unsupported"
    check $hcWorkerUnsupported == "worker-unsupported"
    check $svVerified == "verified"
    check $svUnverified == "unverified"
    check $svAbsent == "absent"

  test "a whole page's worth of chain facts becomes one CtReplayStatus body":
    var o = defaultOpts()
    o.truncated = true
    o.bundlePublished = false
    let t = buildTree(tmpDir("seam-body"), o)
    let l = openTree(t)
    l.loadTx(t)
    let u = replayStatusFor(l.artifact.current.val, l.sources.results,
                            l.tx.codeHashes.val.len, l.capability.capability.val)
    let body = u.toReplayStatusBody
    check body["availability"].getStr == "retained"
    check body["integrity"].getStr == "truncated"
    check body["capability"].getStr == "capable"
    check body["sourceAvailability"].getStr == "unverified"

# ===========================================================================
# 4. CapabilityVM — §14.2's ladder, walked over every probe combination.
# ===========================================================================

suite "M12 — CapabilityVM: §14.2's ladder and §9.5's ceiling":

  test "every probe combination is total, and every value is reachable":
    var caps: set[HostCapability]
    var rungs: set[FallbackRung]
    var combinations = 0
    for wasm in [false, true]:
      for worker in [false, true]:
        for ranges in [false, true]:
          for mem in [false, true]:
            for fits in [false, true]:
              let p = HostProbe(wasmCompiles: wasm, workerSupported: worker,
                                rangeRequestsHonoured: ranges,
                                memorySufficient: mem)
              let c = capabilityOf(p, fits)
              caps.incl c
              rungs.incl fallbackRung(c, ranges)
              inc combinations
    check combinations == 32
    # Every §14.2 failure row survives to the pane as its own cause.
    check caps == {hcCapable, hcWasmCompilationFailed, hcInsufficientMemory,
                   hcRangeRequestsUnsupported, hcWorkerUnsupported}
    # Every rung of the ladder is reachable, including the floor.
    check rungs == {frFullDebugger, frMemoryOnlyWholeFile, frTraceDownload,
                    frOpenInDesktop, frStaticSummary}

  test "a capable host on a capable browser is not on the ladder":
    let vm = createCapabilityVM()
    check vm.capability.val == hcCapable
    check vm.rung.val == frFullDebugger
    check vm.engineRuns.val
    check not vm.downloadOffered.val

  test "broken ranges take the whole-file path when the trace fits":
    let vm = createCapabilityVM(ceiling = 1_000_000)
    vm.containerBytes.val = 500_000
    vm.noteRangeRequestsBroken()
    check vm.wholeFileFits.val
    check vm.capability.val == hcCapable          # the engine still runs
    check vm.rung.val == frMemoryOnlyWholeFile
    check vm.engineRuns.val

  test "§9.5's ceiling REFUSES the whole-file path above it, and falls":
    let vm = createCapabilityVM(ceiling = 1_000_000)
    vm.containerBytes.val = 8_000_000
    vm.noteRangeRequestsBroken()
    check not vm.wholeFileFits.val
    check vm.capability.val == hcRangeRequestsUnsupported
    check vm.rung.val == frTraceDownload
    check not vm.engineRuns.val
    check vm.downloadOffered.val

  test "a container of unknown size does not get a whole-file promise":
    let vm = createCapabilityVM()
    vm.containerBytes.val = 0
    vm.noteRangeRequestsBroken()
    check not vm.wholeFileFits.val
    check vm.rung.val == frTraceDownload

  test "each §14.2 detection reports its own cause, not a generic error":
    block:
      let vm = createCapabilityVM()
      vm.noteWasmCompilationFailed()
      check vm.capability.val == hcWasmCompilationFailed
      check vm.rung.val == frOpenInDesktop
    block:
      let vm = createCapabilityVM()
      vm.noteWorkerUnsupported()
      check vm.capability.val == hcWorkerUnsupported
      check vm.rung.val == frOpenInDesktop
    block:
      let vm = createCapabilityVM()
      vm.noteInsufficientMemory()
      check vm.capability.val == hcInsufficientMemory
      check vm.rung.val == frStaticSummary
      check vm.staticSummaryOnly.val
      check vm.desktopOffered.val    # §14.2: "the one path that always works"

  test "worker support is checked before WASM, because the WASM lives in it":
    let p = HostProbe(wasmCompiles: false, workerSupported: false,
                      rangeRequestsHonoured: true, memorySufficient: true)
    check capabilityOf(p, false) == hcWorkerUnsupported

  test "the artifact's size comes from the manifest, which is chain-shaped":
    let t = buildTree(tmpDir("cap-size"), defaultOpts())
    let l = openTree(t)
    l.loadTx(t)
    check l.capability.containerBytes.val ==
      l.artifact.current.val.manifest.container.bytes
    check l.capability.containerBytes.val > 0

# ===========================================================================
# 5. GenerationJobVM — §14.1's state machine, walked exhaustively.
# ===========================================================================

suite "M12 — GenerationJobVM: §14.1's job, not a spinner":

  test "every JobState is classified, and the sets partition the machine":
    for s in JobState:
      let inFlight = s in InFlightStates
      let terminal = s in TerminalStates
      # `jsIdle` is in neither; every other state is in exactly one.
      if s == jsIdle:
        check not inFlight and not terminal
      else:
        check inFlight != terminal
      if s in CancellableStates:
        check inFlight     # §14.1: cancellable only before work starts
      if s in RetryableStates:
        check terminal

  test "the cancellable set is exactly §14.1's two rows":
    check CancellableStates == {jsAccepted, jsQueued}

  test "cancel works before work starts, and refuses once it has":
    for s in JobState:
      let vm = createGenerationJobVM()
      vm.applyJob(initJobUpdate(s))
      let accepted = vm.cancel()
      check accepted == (s in CancellableStates)
      if accepted:
        check vm.state.val == jsIdle
      else:
        check vm.state.val == s     # nothing moved

  test "`refused` is not `failed`: retry is offered on one and never the other":
    var refused = initJobUpdate(jsRefused)
    refused.refusalReason = rrOutOfQuota
    refused.retryable = true       # even if a server said so, §14.1 forbids it
    let a = createGenerationJobVM()
    a.applyJob(refused)
    check not a.canRetry.val
    check not a.retry()
    check a.state.val == jsRefused

    var failed = initJobUpdate(jsFailed)
    failed.retryable = true
    let b = createGenerationJobVM()
    b.applyJob(failed)
    check b.canRetry.val
    check b.retry()
    check b.state.val == jsAccepted

  test "retryable is the pipeline's word, never the client's guess":
    for s in [jsFailed, jsTimedOut]:
      for retryable in [false, true]:
        var u = initJobUpdate(s)
        u.retryable = retryable
        let vm = createGenerationJobVM()
        vm.applyJob(u)
        check vm.canRetry.val == retryable
        check vm.retry() == retryable

  test "a refusal that names a §14 row does not become 'awaiting generation'":
    for (reason, want) in [(rrBelowHistoryFloor, tpBelowHistoryFloor),
                           (rrChainUnsupported, tpRecorderUnavailable),
                           (rrOutOfQuota, tpAwaitingGeneration),
                           (rrTxNotPublished, tpAwaitingGeneration)]:
      var u = initJobUpdate(jsRefused)
      u.refusalReason = reason
      let vm = createGenerationJobVM()
      vm.applyJob(u)
      check vm.provenance.val == want

  test "phase, not percentage: every in-flight state has a named phase":
    for s in JobState:
      let vm = createGenerationJobVM()
      vm.applyJob(initJobUpdate(s))
      if s == jsIdle:
        check vm.phaseLabel.val == ""
      else:
        check vm.phaseLabel.val.len > 0

  test "elapsed time advances only while work is in flight":
    let vm = createGenerationJobVM()
    vm.request()
    check vm.state.val == jsAccepted
    vm.tick(3)
    check vm.elapsedSeconds.val == 3
    vm.applyJob(initJobUpdate(jsReady))
    vm.tick(5)
    check vm.elapsedSeconds.val == 3     # finished jobs do not keep ageing

  test "an absent estimate is not a zero estimate":
    let vm = createGenerationJobVM()
    check not vm.hasEstimate.val
    vm.estimateSeconds.val = 90
    check vm.hasEstimate.val

  test "retention is stated before the request and again at the end":
    let vm = createGenerationJobVM()
    check vm.resultRetention.val == rtUnstated
    var u = initJobUpdate(jsQueued)
    u.retention = rtWindowed
    u.retentionSeconds = 259200
    vm.applyJob(u)
    check vm.resultRetention.val == rtWindowed
    check vm.retentionSeconds.val == 259200
    # A later update that says nothing about retention does not erase it.
    vm.applyJob(initJobUpdate(jsReady))
    check vm.resultRetention.val == rtWindowed

  test "an idle job on a page that needs no trace is not degraded":
    let vm = createGenerationJobVM()
    check vm.provenance.val == tpAvailable
    vm.generationPending.val = true
    check vm.provenance.val == tpAwaitingGeneration

# ===========================================================================
# 6. ArtifactVM, DivergenceVM, SourceBundleVM.
# ===========================================================================

suite "M12 — ArtifactVM: derivation, availability filters, range residency":

  test "the artifact address is the producer's, by construction":
    let t = buildTree(tmpDir("artifact-id"), defaultOpts())
    let l = openTree(t)
    l.loadTx(t)
    check l.artifact.current.val.traceArtifactId == t.traceArtifactId
    check l.artifact.current.val.manifestPath ==
      traceManifestPath(t.traceArtifactId)
    check l.artifact.current.val.hasManifest

  test "availability filters count every execution, not just the chosen one":
    let t = buildTree(tmpDir("counts"), defaultOpts())
    let l = openTree(t)
    l.loadTx(t)
    check l.artifact.availabilityCounts.val[trkReady] == 1
    check l.artifact.availabilityCounts.val[trkAbsent] == 0

  test "select refuses an execution that does not exist, and moves nothing":
    let t = buildTree(tmpDir("select"), defaultOpts())
    let l = openTree(t)
    l.loadTx(t)
    let before = l.artifact.selected.val
    check not l.artifact.select("private")
    check l.artifact.selected.val == before
    # The overlay's single-execution shape carries no selector (§2.3a: "a
    # single-execution transaction emits `trace` with no selector"), so the
    # sole execution IS addressed by the empty string.
    check l.artifact.select("")

  test "range residency is aligned arithmetic over the manifest's block size":
    var r = ResolvedTrace(kind: trkReady, hasManifest: true)
    r.manifest.container.bytes = 10_000
    r.manifest.container.blockSize = 4096
    let res = residencyOf(r, [0, 1])
    check res.windowBytes == 4096
    check res.totalWindows == 3          # ceil(10000 / 4096)
    check res.residentWindows == 2
    check fillFractionOf(res) > 0.66 and fillFractionOf(res) < 0.67

  test "a window past the end of the container is not counted":
    var r = ResolvedTrace(kind: trkReady, hasManifest: true)
    r.manifest.container.bytes = 10_000
    r.manifest.container.blockSize = 4096
    check residencyOf(r, [0, 1, 2, 3, 99]).residentWindows == 3
    check fillFractionOf(residencyOf(r, [0, 1, 2, 3, 99])) == 1.0

  test "a duplicate window is counted once":
    var r = ResolvedTrace(kind: trkReady, hasManifest: true)
    r.manifest.container.bytes = 10_000
    r.manifest.container.blockSize = 4096
    check residencyOf(r, [1, 1, 1]).residentWindows == 1

  test "nothing to fetch is 0.0, not 1.0":
    check fillFractionOf(residencyOf(ResolvedTrace(), [])) == 0.0

  test "no resolved overlay reports unreplayable, never a healthy default":
    let vm = createArtifactVM(localTree(tmpDir("empty-artifact")))
    check vm.traces.val.len == 0
    check vm.retention.val == arUnreplayable

suite "M12 — DivergenceVM: a banner that cannot be dismissed":

  test "the manifest's verdict wins, and carries the oracle":
    var o = defaultOpts()
    o.manifestValidation = vsDivergent
    let t = buildTree(tmpDir("divergent"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.divergence.detected.val
    check l.divergence.source.val == dsManifest
    check l.divergence.status.val == vsDivergent
    check l.divergence.oracle.val == "receipt-compare"
    check l.divergence.hasDetail.val
    check l.artifact.integrity.val == aiDivergent

  test "the overlay's verdict shows the banner before any manifest is fetched":
    var r = ResolvedTrace(kind: trkReady, hasValidation: true,
      validation: ValidationSummary(status: vsDivergent, strength: 3))
    let vm = createDivergenceVM()
    vm.setTrace(r)
    check vm.detected.val
    check vm.source.val == dsOverlay
    check vm.strength.val == 3

  test "an availability of `divergent` with no summary still shows the banner":
    let vm = createDivergenceVM()
    vm.setTrace(ResolvedTrace(kind: trkDivergent))
    check vm.detected.val
    check vm.source.val == dsAvailability
    check not vm.hasDetail.val      # and says the detail is missing

  test "`unchecked` is not a divergence":
    let vm = createDivergenceVM()
    vm.setTrace(ResolvedTrace(kind: trkReady, hasValidation: true,
      validation: ValidationSummary(status: vsUnchecked)))
    check not vm.detected.val
    check vm.integrity.val == aiComplete

  test "there is no way to dismiss it — only the detail collapses":
    let vm = createDivergenceVM()
    vm.setTrace(ResolvedTrace(kind: trkDivergent))
    check vm.detected.val
    vm.toggleComparison()
    check vm.comparisonOpen.val
    check vm.detected.val           # the banner is untouched
    vm.toggleComparison()
    check not vm.comparisonOpen.val
    check vm.detected.val

  test "a new trace closes a comparison from the previous one":
    let vm = createDivergenceVM()
    vm.setTrace(ResolvedTrace(kind: trkDivergent))
    vm.toggleComparison()
    check vm.comparisonOpen.val
    vm.setTrace(ResolvedTrace(kind: trkReady, hasManifest: true))
    check not vm.comparisonOpen.val

suite "M12 — SourceBundleVM: per code hash, refused when mismatched":

  test "a full-match bundle verifies, and one fetch is issued":
    let t = buildTree(tmpDir("sources-full"), defaultOpts())
    let l = openTree(t)
    l.loadTx(t)
    check l.sources.codeHashes.val == @[t.codeHash]
    check l.sources.verified.val == 1
    check l.sources.verification.val == svVerified
    check l.sources.fetchCount.val == 1
    check l.sources.unresolved.val.len == 0

  test "a second load of the same code hash costs no second fetch":
    let t = buildTree(tmpDir("sources-cache"), defaultOpts())
    let l = openTree(t)
    l.loadTx(t)
    check l.sources.fetchCount.val == 1
    l.sources.loadAll(l.artifact.current.val.manifest, true)
    check l.sources.fetchCount.val == 1     # §5's whole caching argument

  test "an unpublished bundle is data with a reason, and issues no fetch":
    var o = defaultOpts()
    o.bundlePublished = false
    let t = buildTree(tmpDir("sources-none"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.sources.verification.val == svUnverified
    check l.sources.unresolved.val == @[t.codeHash]
    check l.sources.bundleFor(t.codeHash).outcome == boNotPublished
    check l.sources.bundleFor(t.codeHash).reason.len > 0

  test "a bundle filed under the wrong code hash is refused, not displayed":
    var o = defaultOpts()
    o.bundleWrongCodeHash = true
    let t = buildTree(tmpDir("sources-wrong"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.sources.bundleFor(t.codeHash).outcome == boMismatched
    check l.sources.anyMismatched.val
    check l.sources.verification.val == svUnverified

  test "a partial match is not a verified build":
    var o = defaultOpts()
    o.bundleMatch = "partial"
    let t = buildTree(tmpDir("sources-partial"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.sources.bundleFor(t.codeHash).outcome == boLoaded
    check l.sources.bundleFor(t.codeHash).bundle.match == mqPartial
    check l.sources.verification.val == svUnverified
    check not l.sources.anyMismatched.val    # different thing, different word

  test "a transaction that ran no contract code has nothing to supply sources for":
    var o = defaultOpts()
    o.codeEdges = false
    let t = buildTree(tmpDir("sources-absent"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.tx.codeHashes.val.len == 0
    check l.sources.verification.val == svAbsent
    check l.sources.verification.val != svUnverified

  test "changing chain drops the cache; changing transaction does not":
    let t = buildTree(tmpDir("sources-chain"), defaultOpts())
    let l = openTree(t)
    l.loadTx(t)
    check l.sources.bundles.val.len == 1
    l.sources.setSubject(t.chain, @[t.codeHash])
    check l.sources.bundles.val.len == 1     # same chain, cache kept
    l.sources.setSubject("other", @[t.codeHash])
    check l.sources.bundles.val.len == 0     # different namespace

# ===========================================================================
# 7. Composition — a memo in one VM reading a signal in another, no bridge.
# ===========================================================================

suite "M12 — cross-VM composition needs no bridge":

  test "TransactionVM.degradation is one memo over four other ViewModels":
    var o = defaultOpts()
    o.availability = taOnDemand
    o.publishManifest = false
    let t = buildTree(tmpDir("compose"), o)
    let m = newDeliveryMonitor()
    var offline = false
    let store = deliveryStore("compose", m, proc(path: string): TransportResult =
      if offline: return TransportResult(outcome: toUnreachable)
      let full = t.dir / path
      if fileExists(full): TransportResult(outcome: toOk, body: readFile(full))
      else: TransportResult(outcome: toMissing))
    let l = newLayer(store, m)
    l.registry.loadRegistry()
    l.registry.selectChain(t.chain)
    l.chain.loadBlocks()
    l.loadTx(t)
    check l.tx.degradation.val == cdTraceAwaitingGeneration

    # Write a signal in ChainVM's monitor; the memo in TransactionVM changes,
    # with no message passing, no serialisation and no re-load.
    offline = true
    m.noteRead("anything", toUnreachable)
    check l.tx.degradation.val == cdCdnUnreachable

    # And back.
    m.noteRead("anything", toOk)
    check l.tx.degradation.val == cdTraceAwaitingGeneration

  test "a cross-VM memo read issues NO reads of its own":
    let t = buildTree(tmpDir("compose-reads"), defaultOpts())
    let log = newRequestLog()
    let m = newDeliveryMonitor()
    let inner = deliveryStore("t", m, proc(path: string): TransportResult =
      let full = t.dir / path
      if fileExists(full): TransportResult(outcome: toOk, body: readFile(full))
      else: TransportResult(outcome: toMissing))
    let l = newLayer(recordingStore(inner, log), m)
    l.registry.loadRegistry()
    l.registry.selectChain(t.chain)
    l.chain.loadBlocks()
    l.loadTx(t)
    let before = log.paths.len
    for i in 0 .. 20:
      discard l.tx.degradation.val
      discard l.tx.snapshot.val
      discard l.blk.degradation.val
      discard l.search.degradation.val
      discard l.artifact.retention.val
      discard l.capability.rung.val
    check log.paths.len == before

  test "the registry VM's session is what every other VM reads — one pin":
    let t = buildTree(tmpDir("one-pin"), defaultOpts())
    let l = openTree(t)
    check l.registry.session.val.generation == "1"
    check l.chain.registry.session.val.generation == "1"
    check l.tx.registry.session.val.generation == "1"
    check l.blk.registry.session.val.generation == "1"

  test "adopting a new generation is deliberate, never a side effect of polling":
    let t = buildTree(tmpDir("adopt"), defaultOpts())
    let l = openTree(t)
    check l.registry.session.val.generation == "1"
    # Publish generation 2 and move the pointer, exactly as the pipeline does.
    var o2 = defaultOpts()
    o2.generation = "2"
    discard buildTree(t.dir, o2)
    l.chain.poll()
    check l.chain.supersededBy.val == "2"
    check l.registry.session.val.generation == "1"   # not swapped underneath
    check l.chain.adopt() == ooOpened
    check l.registry.session.val.generation == "2"
    check l.chain.supersededBy.val == ""

# ===========================================================================
# 8. AccountVM — the rule, and the mechanical proof that nothing gates on it.
# ===========================================================================

suite "M12 — AccountVM is reached only from the generation-request path":

  test "no page gated on it: the whole layer above ran with none in existence":
    # Every test in this file up to here constructed the full layer through
    # `newLayer`, drove every §14 row, and resolved every surface's
    # degradation. `newLayer` has no `AccountVM` field and no VM constructor
    # takes one. If a page started gating on an account, this file would stop
    # compiling — which is the check, and it is structural rather than a
    # convention.
    let t = buildTree(tmpDir("no-account"), defaultOpts())
    let l = openTree(t)
    l.loadTx(t)
    check l.tx.degradation.val == cdNone
    check l.blk.degradation.val == cdNone
    check l.search.degradation.val == cdNone

  test "anonymous is the default, and it reads everything":
    let vm = createAccountVM()
    check not vm.signedIn.val
    check vm.tier.val == qtAnonymous
    check not vm.mayRequestGeneration.val

  test "an unknown quota is not a zero quota":
    let vm = createAccountVM()
    vm.signIn(qtFree)
    check not vm.hasQuotaInformation.val
    check not vm.exhausted.val            # not "0 remaining"
    check not vm.mayRequestGeneration.val # and not offered either
    vm.setQuota(remaining = 3, limit = 5, resetSeconds = 3600)
    check vm.hasQuotaInformation.val
    check vm.mayRequestGeneration.val

  test "an exhausted quota withdraws the affordance, per §14.1's refusal row":
    let vm = createAccountVM()
    vm.signIn(qtPaid)
    vm.setQuota(0, 5, 60)
    check vm.exhausted.val
    check not vm.mayRequestGeneration.val

  test "signing out clears everything":
    let vm = createAccountVM()
    vm.signIn(qtPaid)
    vm.setQuota(3, 5, 60)
    vm.signOut()
    check vm.tier.val == qtAnonymous
    check not vm.hasQuotaInformation.val

# ===========================================================================
# 9. AddressVM and BlockVM.
# ===========================================================================

suite "M12 — AddressVM: paged history, and what has no producer yet":

  test "the index is one read; segments are paged explicitly":
    let t = buildTree(tmpDir("address"), defaultOpts())
    let log = newRequestLog()
    let m = newDeliveryMonitor()
    let inner = deliveryStore("t", m, proc(path: string): TransportResult =
      let full = t.dir / path
      if fileExists(full): TransportResult(outcome: toOk, body: readFile(full))
      else: TransportResult(outcome: toMissing))
    let l = newLayer(recordingStore(inner, log), m)
    l.registry.loadRegistry()
    l.registry.selectChain(t.chain)
    let before = log.paths.len
    l.address.loadIndex(t.address)
    check log.paths.len == before + 1        # exactly one read
    check l.address.indexFound.val
    check l.address.totalSegments.val == 1
    check l.address.loadedSegments.val == 0
    check l.address.hasMore.val
    check l.address.loadNextSegment()
    check l.address.loadedSegments.val == 1
    check not l.address.hasMore.val
    check not l.address.loadNextSegment()
    check l.address.knownTransactions.val == @[t.tx]

  test "an address with no history is not on this chain":
    let t = buildTree(tmpDir("address-none"), defaultOpts())
    let l = openTree(t)
    l.address.loadIndex("0x" & repeat("7", 40))
    check not l.address.indexFound.val
    check l.address.presence.val == opNotOnThisChain
    check l.address.degradation.val == cdObjectNotFound

  test "an address page IS sensitive to a behind-the-tip pipeline":
    var o = defaultOpts()
    o.stale = true
    let t = buildTree(tmpDir("address-stale"), o)
    let l = openTree(t)
    l.address.loadIndex(t.address)
    check l.address.degradation.val == cdPipelineBehindTip

  test "code hashes are filtered to this address, not to the transaction":
    let t = buildTree(tmpDir("address-code"), defaultOpts())
    let l = openTree(t)
    l.address.loadIndex(t.address)
    l.tx.load(t.tx)
    # The demo transaction binds its code hash to the CONTRACT address, not to
    # the initiator this address is. So the transaction has a code hash and
    # this address has none — which is the filtering, demonstrated rather than
    # described.
    check l.tx.codeHashes.val.len == 1
    check l.address.codeHashesFor(l.tx.view.val.facts).len == 0

suite "M12 — BlockVM: siblings from the generation, detail from the content":

  test "the detail is found and the siblings are computed from the height map":
    let t = buildTree(tmpDir("block"), defaultOpts())
    let l = openTree(t)
    l.blk.load(t.blk)
    check l.blk.found.val
    check l.blk.txCount.val == 1
    check l.blk.txHashes.val == @[t.tx]
    check l.blk.atHead.val
    check l.blk.atGenesis.val      # a one-block generation is both
    check l.blk.previousSibling.val.hash == ""
    check l.blk.nextSibling.val.hash == ""

  test "a block not in the tree is not found":
    let t = buildTree(tmpDir("block-none"), defaultOpts())
    let l = openTree(t)
    l.blk.load("0x" & repeat("5", 62))
    check not l.blk.found.val
    check l.blk.degradation.val == cdObjectNotFound

# ===========================================================================
# 10. TraceStatusVM's own outputs, including the one the seam must NOT carry.
# ===========================================================================

suite "M12 — TraceStatusVM: published, unsupported, divergent, reconstructed":

  test "a reconstructed trace is flagged here and NOT folded into integrity":
    var o = defaultOpts()
    o.reconstructed = true
    let t = buildTree(tmpDir("reconstructed"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.traceStatus.reconstructed.val
    check l.traceStatus.published.val
    # §2.3a: reconstructed is orthogonal to availability. The Embed SDK has no
    # value for it and must not grow one, so the seam reports a complete trace
    # and the explorer renders the flag.
    check l.artifact.integrity.val == aiComplete
    check l.tx.degradation.val == cdNone

  test "every provenance value is reachable, and only one at a time":
    var reached: set[TraceProvenance]
    block ready:
      let t = buildTree(tmpDir("prov-ready"), defaultOpts())
      let l = openTree(t); l.loadTx(t)
      reached.incl l.traceStatus.provenance.val
    block awaiting:
      var o = defaultOpts(); o.availability = taOnDemand; o.publishManifest = false
      let t = buildTree(tmpDir("prov-await"), o)
      let l = openTree(t); l.loadTx(t)
      reached.incl l.traceStatus.provenance.val
    block recorder:
      var o = defaultOpts(); o.recorderPinned = false
      let t = buildTree(tmpDir("prov-rec"), o)
      let l = openTree(t); l.loadTx(t)
      reached.incl l.traceStatus.provenance.val
    block floor:
      var o = defaultOpts(); o.historyFloor = 19_500_000
      let t = buildTree(tmpDir("prov-floor"), o)
      let l = openTree(t); l.loadTx(t)
      reached.incl l.traceStatus.provenance.val
    check reached == {tpAvailable, tpAwaitingGeneration,
                      tpRecorderUnavailable, tpBelowHistoryFloor}

  test "the floor outranks the artifact: no retry against a floor":
    var o = defaultOpts()
    o.historyFloor = 19_500_000
    o.availability = taOnDemand
    o.publishManifest = false
    let t = buildTree(tmpDir("floor-vs-ondemand"), o)
    let l = openTree(t)
    l.loadTx(t)
    check l.traceStatus.provenance.val == tpBelowHistoryFloor
    check l.tx.degradation.val == cdBelowHistoryFloor

  test "every non-available provenance states a reason":
    # §14 requires every one of these rows to say why. A blank reason is the
    # failure mode that turns a specific refusal into a generic error, so the
    # three ways to reach a non-available provenance are each driven and each
    # checked for words.
    var noRecorder = defaultOpts()
    noRecorder.recorderPinned = false
    var unsupported = defaultOpts()
    unsupported.availability = taUnsupported
    unsupported.publishManifest = false
    var belowFloor = defaultOpts()
    belowFloor.historyFloor = 19_500_000
    var i = 0
    for o in [noRecorder, unsupported, belowFloor]:
      inc i
      let t = buildTree(tmpDir("reason-" & $i), o)
      let l = openTree(t)
      l.loadTx(t)
      check l.traceStatus.provenance.val != tpAvailable
      check l.traceStatus.reason.val.len > 0
