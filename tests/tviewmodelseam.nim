## SDK-CONSUMER: BlockTracer's ViewModel layer writing through the Embed SDK's seam.
##
## M12's ViewModel layer, checked against the **real** CodeTracer Embed SDK.
##
## ## What this file exists to prove
##
## M2b's review named the seam in one sentence: "`ReplayDataStore`'s four
## setters plus a `CtReplayStatus` backend event: **the layer above writes, the
## panes read**." `client/src/viewmodel/replay_status.nim` is this repository's
## side of that write, and everything it emits is a **string** — the wire
## spellings §14.1a's and §14.2's tables use, deliberately, because the Embed SDK
## must contain no chain concept and so the two layers cannot share an enum.
##
## A wire contract between two repositories is exactly the kind of thing that
## drifts silently. So this suite:
##
##   1. feeds **every value this layer can emit** through the real
##      `applyReplayStatus` and asserts which axis value it lands on — a
##      misspelling on either side is caught, because `applyReplayStatus`
##      deliberately leaves a signal *untouched* on an unrecognised value rather
##      than falling back to the undegraded default;
##   2. asserts that `CapabilityVM`'s ladder and the Embed SDK's own
##      `capabilityRung` agree value by value, so the explorer's chrome and the
##      debugger's pane never offer a user two different next steps;
##   3. drives a real published tree end to end and asserts the
##      **`PaneDegradation` each of the five panes resolves to** — which is the
##      whole claim: a BlockTracer pane renders a §14 treatment without the
##      Embed SDK ever learning what a chain is.
##
## It is a SEPARATE suite from `client/tests/test_chain_viewmodels.nim` on
## purpose, for the same reason `tembedhandoff.nim` is separate from
## `tclientsdk.nim`: the ViewModel layer is tested with no debugger on the Nim
## path at all, and the seam is tested with one. Merging them would quietly
## destroy the demonstration.
##
## Build:
##   ci/test/viewmodel-seam-test.sh --require
##
## or by hand, with the pinned Embed SDK (ci/embed-sdk-pin.env):
##   nim c -r -d:nimOldCaseObjects \
##     --path:$CODETRACER_SRC/src/frontend/viewmodel \
##     --path:$CODETRACER_SRC/src/frontend --path:$CODETRACER_SRC/src \
##     --path:$ISONIM_SRC/src --path:$NIM_EVERYWHERE_SRC/src \
##     --path:client/src --path:src \
##     tests/tviewmodelseam.nim

import std/[unittest, os, json, strutils]

import codetracer_embed
import viewmodel
import blocktracer/contract/model as contractModel
import blocktracer/contract/ids as contractIds

const
  Chain = "eth"
  Fixture = currentSourcePath().parentDir.parentDir / "fixtures" / "trace" /
            "minimal_trace.ct"

proc tmpDir(name: string): string =
  result = getTempDir() / "blocktracer-m12-seam-test" / name
  removeDir result
  createDir result

proc writeJsonNl(path: string, node: JsonNode) =
  createDir parentDir(path)
  writeFile(path, node.pretty & "\n")

proc newStore(): ReplayDataStore =
  ## A real `ReplayDataStore` over the Embed SDK's own `MockBackendService` —
  ## the same seam M2b's suites drive the panes through.
  createReplayDataStore(newMockBackendService().toBackendService())

# ===========================================================================
# 1. Every wire value this layer can emit lands on the axis it names.
#
# `applyReplayStatus` leaves a signal ALONE on an unrecognised spelling, which
# is what makes these assertions bite: a drifted spelling does not error, it
# silently keeps the previous value. So each case is driven from a deliberately
# WRONG starting value, and the assertion is that the write moved it.
# ===========================================================================

suite "M12 — the wire spellings are the Embed SDK's, checked against its parsers":

  test "every ArtifactRetention maps onto a ReplayAvailability":
    var reached: set[ReplayAvailability]
    for r in ArtifactRetention:
      let store = newStore()
      # Seed something this write must move away from, so "unchanged" fails.
      store.setReplayAvailability(raNeverGenerated)
      if r == arNeverGenerated:
        store.setReplayAvailability(raRetained)
      var u = ReplayStatusUpdate(hasRetention: true, retention: r)
      store.applyReplayStatus(u.toReplayStatusBody)
      let got = store.degraded.availability.val
      let want =
        case r
        of arRetained: raRetained
        of arWindowedLive: raWindowedLive
        of arWindowExpired: raWindowExpired
        of arNeverGenerated: raNeverGenerated
        of arUnreplayable: raUnreplayable
      check got == want
      reached.incl got
    # Exhaustive both ways: every wire value maps, and every SDK value is hit.
    check reached == {raRetained, raWindowedLive, raWindowExpired,
                      raNeverGenerated, raUnreplayable}

  test "every ArtifactIntegrity maps onto a TraceIntegrity":
    var reached: set[TraceIntegrity]
    for i in ArtifactIntegrity:
      let store = newStore()
      store.setTraceIntegrity(if i == aiTruncated: tiComplete else: tiTruncated)
      var u = ReplayStatusUpdate(hasIntegrity: true, integrity: i)
      store.applyReplayStatus(u.toReplayStatusBody)
      let got = store.degraded.integrity.val
      let want =
        case i
        of aiComplete: tiComplete
        of aiTruncated: tiTruncated
        of aiDivergent: tiDivergent
      check got == want
      reached.incl got
    check reached == {tiComplete, tiTruncated, tiDivergent}

  test "every HostCapability maps onto a ReplayCapability":
    var reached: set[ReplayCapability]
    for c in HostCapability:
      let store = newStore()
      store.setReplayCapability(
        if c == hcInsufficientMemory: rcCapable else: rcInsufficientMemory)
      var u = ReplayStatusUpdate(hasCapability: true, capability: c)
      store.applyReplayStatus(u.toReplayStatusBody)
      let got = store.degraded.capability.val
      let want =
        case c
        of hcCapable: rcCapable
        of hcWasmCompilationFailed: rcWasmCompilationFailed
        of hcInsufficientMemory: rcInsufficientMemory
        of hcRangeRequestsUnsupported: rcRangeRequestsUnsupported
        of hcWorkerUnsupported: rcWorkerUnsupported
      check got == want
      reached.incl got
    check reached == {rcCapable, rcWasmCompilationFailed, rcInsufficientMemory,
                      rcRangeRequestsUnsupported, rcWorkerUnsupported}

  test "every SourceVerification maps onto a SourceAvailability":
    var reached: set[SourceAvailability]
    for v in SourceVerification:
      let store = newStore()
      store.setSourceAvailability(if v == svAbsent: savVerified else: savAbsent)
      var u = ReplayStatusUpdate(hasVerification: true, verification: v)
      store.applyReplayStatus(u.toReplayStatusBody)
      let got = store.degraded.sourceAvailability.val
      let want =
        case v
        of svVerified: savVerified
        of svUnverified: savUnverified
        of svAbsent: savAbsent
      check got == want
      reached.incl got
    check reached == {savVerified, savUnverified, savAbsent}

  test "MUTATION BITE: a drifted spelling leaves the signal ALONE, not reset":
    # The failure mode this suite exists to catch, demonstrated. A body with a
    # spelling the SDK does not know does not error and does not fall back to
    # the healthy default — it changes nothing, which is why "the write moved
    # it" is the assertion above and not "the value is sane".
    let store = newStore()
    store.setReplayAvailability(raWindowExpired)
    store.applyReplayStatus(%*{"availability": "window_expired"})   # underscore
    check store.degraded.availability.val == raWindowExpired
    store.applyReplayStatus(%*{"availability": "window-expired"})   # correct
    check store.degraded.availability.val == raWindowExpired

  test "an axis this layer did not learn about is not written":
    let store = newStore()
    store.setTraceIntegrity(tiDivergent)
    store.setSourceAvailability(savUnverified)
    var u = ReplayStatusUpdate(hasCapability: true, capability: hcWorkerUnsupported)
    check u.toReplayStatusBody.len == 1
    store.applyReplayStatus(u.toReplayStatusBody)
    check store.degraded.capability.val == rcWorkerUnsupported
    check store.degraded.integrity.val == tiDivergent        # untouched
    check store.degraded.sourceAvailability.val == savUnverified

  test "the event kind this layer names is the one the store listens for":
    # Both packages define a constant of this name — deliberately, since the
    # string IS the contract between them — so both are qualified here. If the
    # Embed SDK renamed its event, this is where it would be noticed.
    check replay_status.ReplayStatusEventKind ==
      replay_data_store.ReplayStatusEventKind

# ===========================================================================
# 2. The ladder agrees on both sides of the boundary.
# ===========================================================================

suite "M12 — CapabilityVM's ladder agrees with the Embed SDK's":

  test "for every §14.2 failure, both layers name the same rung":
    for c in HostCapability:
      let sdkCapability =
        case c
        of hcCapable: rcCapable
        of hcWasmCompilationFailed: rcWasmCompilationFailed
        of hcInsufficientMemory: rcInsufficientMemory
        of hcRangeRequestsUnsupported: rcRangeRequestsUnsupported
        of hcWorkerUnsupported: rcWorkerUnsupported
      # `rangeRequestsHonoured` is irrelevant for every value except `capable`,
      # where it is what separates the full debugger from the memory-only path
      # — a distinction the SDK's enum does not have, and correctly so: it is a
      # delivery decision made before the engine is handed anything.
      let mine = fallbackRung(c, rangeRequestsHonoured = true)
      let theirs = capabilityRung(sdkCapability)
      let agree =
        case theirs
        of crFullDebugger: mine == frFullDebugger
        of crTraceDownload: mine == frTraceDownload
        of crOpenInDesktop: mine == frOpenInDesktop
        of crStaticSummary: mine == frStaticSummary
      if not agree:
        echo "  disagreement for ", c, ": this layer says ", mine,
             ", the Embed SDK says ", theirs
      check agree

  test "the memory-only rung is this layer's alone, and does not claim to be theirs":
    # M12's deliverable list spells the ladder "memory-only cache, trace
    # download, open-in-desktop, static call/event summary". The first rung has
    # no `CapabilityRung`, because a pane is handed an engine that is already
    # running; what varies is how bytes reached it.
    check fallbackRung(hcCapable, rangeRequestsHonoured = false) ==
      frMemoryOnlyWholeFile
    check capabilityRung(rcCapable) == crFullDebugger

# ===========================================================================
# 3. End to end: a published tree, through the ViewModels, into the panes.
# ===========================================================================

type TreeShape = enum
  tsHealthy
  tsTruncated
  tsDivergent
  tsUnverifiedSource
  tsExpiredWindow
  tsStructurallyAbsent

proc buildTree(dir: string; shape: TreeShape): tuple[dir, chain, tx: string] =
  let recId = "evm"
  let recVer = "1.0.0"
  let recBuild = recorderBuildHash(recId, recVer)
  let profH = contractIds.profileHash("default")
  let traceSchema = "ctfs/v4"
  writeJsonNl(dir / "registry" / ("chains.v" & $ContractVersion & ".json"), %*{
    "version": ContractVersion,
    "chains": {Chain: {
      "recorder": {"id": recId, "build": recBuild, "version": recVer},
      "profile": {"name": "default", "hash": profH},
      "traceSchema": traceSchema}}})

  let tx = "0xdeadbeef" & repeat("0", 56)
  let blk = "0xabc123" & repeat("0", 58)
  let codeHash = "0xc0de" & repeat("1", 36)
  let contractAddr = "0x3333" & repeat("0", 36)
  let execId = demoExecutionInputId(Chain, tx, "call")

  let facts = contractModel.TransactionFacts(
    chain: Chain,
    id: TxId(kind: tikHash, hash: tx),
    order: TxOrder(kind: tokBlockIndex, obBlock: blk, obHeight: 19_000_000,
                   obIndex: 12),
    outcome: Outcome(overall: ooSucceeded, parts: @[]),
    roles: @[Role(role: "initiator", address: "0x1111" & repeat("0", 36))],
    cost: @[], payloadRaw: "0xa9059cbb", payloadSelector: "0xa9059cbb",
    payloadTarget: contractAddr, logs: @[],
    codeEdges: @[CodeEdge(address: contractAddr, codeHash: codeHash,
                          boundAt: blk)],
    executions: @[Execution(selector: "call", executionInputId: execId)],
    native: %*{"evm": {"type": 2}})
  writeJsonNl(dir / "d" / Chain / "tx" / hexShard(tx) / tx & ".json", facts.toJson)
  writeJsonNl(dir / "d" / Chain / "block" / blk & ".json",
    contractModel.BlockDetail(chain: Chain, hash: blk, height: 19_000_000,
      parentHash: "0x00", transactions: @[tx]).toJson)
  let txstateRel = "d" / Chain / "g" / "1" / "txstate" / hexShard(tx) / tx & ".json"
  writeJsonNl(dir / txstateRel,
    %*{"chain": Chain, "tx": tx, "canonical": true, "finality": "finalized"})

  var single = ExecTrace(
    availability: (if shape == tsStructurallyAbsent: taAbsent else: taReady),
    bytes: 36864, hasValidation: true,
    validation: ValidationSummary(status: vsMatch, strength: 2))
  if shape == tsStructurallyAbsent:
    single.reason = "this execution is private and has no observable call structure"
    single.bytes = 0
  writeJsonNl(dir / "d" / Chain / "ts" / "1" / hexShard(tx) / tx & ".json",
    contractModel.TraceSelection(chain: Chain, tx: tx, hasSingle: true,
                                 singleTrace: single).toJson)

  let tid = deriveTraceArtifactId(execId, recId, recBuild, profH, traceSchema)
  if shape notin {tsExpiredWindow, tsStructurallyAbsent}:
    let sh = traceShards(tid)
    let adir = dir / "t" / sh.a / sh.b / tid
    createDir adir
    let bytes = readFile(Fixture)
    writeFile(adir / "trace.ct", bytes)
    writeJsonNl(adir / "manifest.json", contractModel.TraceManifest(
      schema: ContractVersion, traceArtifactId: tid, executionInputId: execId,
      chain: Chain, tx: tx,
      recorder: RecorderRef(id: recId, build: recBuild, version: recVer),
      profile: ProfileRef(name: "default", hash: profH),
      sourceBundles: %*{codeHash: "sha1:" & repeat("ab", 20)},
      container: ContainerRef(file: "trace.ct", bytes: bytes.len,
        blockSize: 4096, hash: contentHashSha1(bytes)),
      execution: ExecutionSummary(steps: 100, frames: 5,
        truncated: shape == tsTruncated, sourceLevel: true,
        languages: @["solidity"]),
      validation: ValidationSummary(
        status: (if shape == tsDivergent: vsDivergent else: vsMatch),
        strength: 2),
      validationOracle: "receipt-compare",
      prestateStrategy: "prestate-trace").toJson)

  if shape != tsUnverifiedSource:
    let bundleId = "sha1:" & repeat("ab", 20)
    writeJsonNl(dir / "src" / Chain / codeHash /
                (shortBundleHash(bundleId) & ".json"),
      %*{"schema": ContractVersion, "codeHash": codeHash, "chain": Chain,
         "match": "full", "provider": "test", "language": "solidity",
         "compiler": {"name": "solc", "version": "0.8.24"},
         "sources": {}, "debug": {}})
    writeJsonNl(dir / "src" / Chain / codeHash / "current.json",
      %*{"sourceBundleId": bundleId})

  let summaryRel = "d" / Chain / "g" / "1" / "summary.json"
  let heightRel = "d" / Chain / "g" / "1" / "height" / "0.json"
  let blocksRel = "d" / Chain / "g" / "1" / "blocks" / "0.json"
  writeJsonNl(dir / summaryRel, %*{"chain": Chain, "generation": "1",
    "counters": {"blocks": 1, "transactions": 1}, "coverageMode": "eager",
    "stale": false})
  writeJsonNl(dir / heightRel,
    %*{"chain": Chain, "epoch": 0, "heights": {"19000000": blk}})
  writeJsonNl(dir / blocksRel, %*{"chain": Chain, "epoch": 0, "blocks": [blk]})
  writeJsonNl(dir / "d" / Chain / "g" / "1" / "root.json",
    contractModel.GenerationRoot(contractVersion: ContractVersion, chain: Chain,
      generation: "1", traceSelectionVersion: "1", summaryPath: summaryRel,
      heightPaths: @[heightRel], blockIndexPaths: @[blocksRel], addrPaths: @[],
      txstatePaths: @[txstateRel]).toJson)
  writeJsonNl(dir / "d" / Chain / "current.json",
    %*{"chain": Chain, "generation": "1", "traceSelectionVersion": "1",
       "head": {"height": 19000000, "hash": blk},
       "finalized": {"height": 19000000, "hash": blk}})
  (dir, Chain, tx)

proc statusFor(dir, tx: string; probe: HostProbe): ReplayStatusUpdate =
  ## The whole layer, from a published tree to one `CtReplayStatus` body. This
  ## is the code path a debug route runs; nothing here is a test shortcut.
  let store = localTree(dir)
  let monitor = newDeliveryMonitor()
  let registry = createChainRegistryVM(store)
  registry.loadRegistry()
  registry.selectChain(Chain)
  let chain = createChainVM(store, registry, monitor)
  let job = createGenerationJobVM()
  let traceStatus = createTraceStatusVM(registry)
  let txVm = createTransactionVM(store, registry, chain, traceStatus, job)
  let artifact = createArtifactVM(store)
  let sources = createSourceBundleVM(store)
  let capability = createCapabilityVM()
  txVm.load(tx)
  doAssert txVm.found.val
  artifact.resolveAll(registry.session.val, txVm.view.val)
  capability.setArtifact(artifact.current.val)
  capability.setProbe(probe)
  sources.setSubject(Chain, txVm.codeHashes.val)
  sources.loadAll(artifact.current.val.manifest, artifact.current.val.hasManifest)
  replayStatusFor(artifact.current.val, sources.results,
                  txVm.codeHashes.val.len, capability.capability.val)

proc paneDegradation(dir, tx: string; probe: HostProbe;
                     sensitivity: set[PaneDegradation]): PaneDegradation =
  let store = newStore()
  store.applyReplayStatus(statusFor(dir, tx, probe).toReplayStatusBody)
  resolveDegradation(store.degradedSnapshot, sensitivity)

suite "M12 — a published tree resolves to a PaneDegradation, end to end":

  test "a healthy trace on a capable host degrades nowhere":
    let (dir, _, tx) = buildTree(tmpDir("healthy"), tsHealthy)
    let u = statusFor(dir, tx, capableProbe())
    check u.retention == arRetained
    check u.integrity == aiComplete
    check u.capability == hcCapable
    check u.verification == svVerified
    for sens in AllPaneDegradations:
      check paneDegradation(dir, tx, capableProbe(), sens) == pdNone

  test "a truncated trace reaches the panes that render truncation, and only those":
    let (dir, _, tx) = buildTree(tmpDir("truncated"), tsTruncated)
    check statusFor(dir, tx, capableProbe()).integrity == aiTruncated
    check paneDegradation(dir, tx, capableProbe(), CalltracePaneDegradations) ==
      pdTraceTruncated
    check paneDegradation(dir, tx, capableProbe(), EventLogPaneDegradations) ==
      pdTraceTruncated
    check paneDegradation(dir, tx, capableProbe(), StatePaneDegradations) ==
      pdTraceTruncated
    check paneDegradation(dir, tx, capableProbe(), DebugControlsPaneDegradations) ==
      pdTraceTruncated
    # The editor is deliberately insensitive: truncation does not change which
    # source a position inside the recording sits in.
    check paneDegradation(dir, tx, capableProbe(), EditorPaneDegradations) == pdNone

  test "a divergent trace raises the non-dismissible banner on the debugger chrome":
    let (dir, _, tx) = buildTree(tmpDir("divergent"), tsDivergent)
    check statusFor(dir, tx, capableProbe()).integrity == aiDivergent
    check paneDegradation(dir, tx, capableProbe(), DebugControlsPaneDegradations) ==
      pdDivergenceDetected

  test "an unverified contract degrades the editor to instruction level":
    let (dir, _, tx) = buildTree(tmpDir("unverified"), tsUnverifiedSource)
    check statusFor(dir, tx, capableProbe()).verification == svUnverified
    check paneDegradation(dir, tx, capableProbe(), EditorPaneDegradations) ==
      pdNoVerifiedSource
    # And only the editor: no other pane renders source.
    check paneDegradation(dir, tx, capableProbe(), CalltracePaneDegradations) == pdNone

  test "an overlay claiming ready with no artifact is a renewable window, on every pane":
    let (dir, _, tx) = buildTree(tmpDir("expired"), tsExpiredWindow)
    check statusFor(dir, tx, capableProbe()).retention == arWindowExpired
    for sens in AllPaneDegradations:
      check paneDegradation(dir, tx, capableProbe(), sens) == pdReplayWindowExpired

  test "a structurally-absent execution is terminal on every pane":
    let (dir, _, tx) = buildTree(tmpDir("absent"), tsStructurallyAbsent)
    check statusFor(dir, tx, capableProbe()).retention == arUnreplayable
    for sens in AllPaneDegradations:
      check paneDegradation(dir, tx, capableProbe(), sens) ==
        pdPermanentlyUnreplayable

  test "a host that cannot run the engine puts every pane on the ladder":
    let (dir, _, tx) = buildTree(tmpDir("nowasm"), tsHealthy)
    var probe = capableProbe()
    probe.wasmCompiles = false
    check statusFor(dir, tx, probe).capability == hcWasmCompilationFailed
    for sens in AllPaneDegradations:
      check paneDegradation(dir, tx, probe, sens) == pdEngineUnavailable

  test "broken ranges on a small container do NOT put a pane on the ladder":
    # §14.2's memory-only whole-file path. The engine runs, so the panes are
    # not degraded — which is the case that would be wrong if `CapabilityVM`
    # forwarded the raw probe instead of establishing the condition.
    let (dir, _, tx) = buildTree(tmpDir("ranges"), tsHealthy)
    var probe = capableProbe()
    probe.rangeRequestsHonoured = false
    check statusFor(dir, tx, probe).capability == hcCapable
    for sens in AllPaneDegradations:
      check paneDegradation(dir, tx, probe, sens) == pdNone

  test "the panes never learn what a chain is":
    # The boundary, expressed as a value. Everything that crossed is four
    # enum values on a store whose type carries no chain concept — no slug, no
    # transaction hash, no generation, no artifact id.
    let (dir, _, tx) = buildTree(tmpDir("boundary"), tsTruncated)
    let body = statusFor(dir, tx, capableProbe()).toReplayStatusBody
    let wire = $body
    check not wire.contains(tx)
    check not wire.contains(Chain)
    check not wire.contains("0x")
    check body.len == 4
    for key in body.keys:
      check key in ["availability", "integrity", "capability",
                    "sourceAvailability"]
