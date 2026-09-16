## Conformance test suite for the M5b data contract and the M5c demo generator.
##
## Covers the milestone verification points:
##   - M5c test_demo_tree_satisfies_the_contract
##   - M5c test_demo_aztec_private_half_is_absent_not_missing
##   - M5c e2e_demo_tree_is_walkable_from_current_json
##   - M5c test_demo_output_is_deterministic
##   - M5b test_contract_conformance_fixture_validates (negative cases)
##   - M5b test_both_producers_satisfy_one_contract (demo + a hand-built EVM tree)

import std/[unittest, os, json, strutils, algorithm, sha1, sequtils, tables, sets]
import ../src/blocktracer/contract/[model, version, ids, searchidx, entrypage]
import ../client/src/viewmodel/search_shapes
import ../src/blocktracer/validator
import ../src/blocktracer/demo/generator

# The synthetic demo tree's slug. It is no longer `aztec`: that slug is the Aztec
# MAINNET's, served at blocktracer.org/aztec, and the fixture moved off it.
const DemoChain = "demo"

proc synthHash(seed, kind: string, n: int): string =
  "0x" & toLowerAscii($secureHash(seed & "|" & kind & "|" & $n))[0 .. 39]
proc synthAddr(seed, kind: string, n: int): string =
  "0x" & toLowerAscii($secureHash(seed & "|addr|" & kind & "|" & $n))[0 .. 39]

# The REAL `noir_space_ship` trace: a CTFS container recorded by `nargo trace`
# (see fixtures/trace/noir_space_ship/README.md), plus the Noir sources the
# generator publishes as content-addressed source bundles.
const fixtureDir = currentSourcePath().parentDir.parentDir / "fixtures" / "trace" / "noir_space_ship"
const fixture = fixtureDir / "zk_shields.ct"
const sourcesDir = fixtureDir / "sources"

proc tmp(name: string): string =
  result = getTempDir() / "blocktracer-test" / name
  removeDir result
  createDir result

proc listFiles(dir: string): seq[string] =
  for p in walkDirRec(dir):
    result.add p.relativePath(dir)
  result.sort()

proc writeJsonNl(path: string, node: JsonNode) =
  createDir parentDir(path)
  writeFile(path, node.pretty & "\n")

suite "M5c — demo tree conformance":
  let outDir = tmp("demo")
  let seed = "test-seed-1"
  let nTx = generate(DemoConfig(outDir: outDir, seed: seed, traceFixturePath: fixture, traceSourcesDir: sourcesDir))

  test "the generator emits ten transactions":
    # Eight until VD.6 added txI and txJ, the two subjects §7.0's third row
    # (`absent`, `unsupported`) had never had — see `demo/generator.nim`.
    check nTx == 10

  test "the demo tree validates against the contract (walkable, no dangles)":
    let errs = validateTree(outDir)
    if errs.len > 0:
      for e in errs: echo "  ERR ", e
    check errs.len == 0

  test "the Aztec private half is absent-with-reason, not a failed fetch":
    # txB is the private+public split at block 101, index 0.
    let h = "0x" & toLowerAscii($secureHash(seed & "|tx|1"))[0 .. 39]
    let sh = shardKeyFor("hex", h)
    let ov = parseFile(outDir / "d" / DemoChain / "ts" / "1" / sh / h & ".json")
    check "executions" in ov
    var sawAbsent, sawReady = false
    for e in ov["executions"]:
      if e["selector"].getStr == "private":
        check e["availability"].getStr == "absent"
        check e["reason"].getStr.len > 0
        check "bytes" notin e            # never a container for the private half
        sawAbsent = true
      elif e["selector"].getStr == "public":
        check e["availability"].getStr == "ready"
        sawReady = true
    check sawAbsent and sawReady

  test "immutable facts carry no mutable interpretation":
    let h = "0x" & toLowerAscii($secureHash(seed & "|tx|1"))[0 .. 39]
    let facts = parseFile(outDir / "d" / DemoChain / "tx" / shardKeyFor("hex", h) / h & ".json")
    for forbidden in ["trace", "validation", "finality", "canonical"]:
      check forbidden notin facts

  test "a divergent verdict and an onDemand tx are both represented":
    # txC divergent (block 101 idx1), txD onDemand (block 102 idx0)
    let hc = "0x" & toLowerAscii($secureHash(seed & "|tx|2"))[0 .. 39]
    let hd = "0x" & toLowerAscii($secureHash(seed & "|tx|3"))[0 .. 39]
    let ovc = parseFile(outDir / "d" / DemoChain / "ts" / "1" / shardKeyFor("hex", hc) / hc & ".json")
    let ovd = parseFile(outDir / "d" / DemoChain / "ts" / "1" / shardKeyFor("hex", hd) / hd & ".json")
    check ovc["trace"]["availability"].getStr == "divergent"
    check ovd["trace"]["availability"].getStr == "onDemand"

  # ── §14's degraded subjects, and §8's fifth event kind, as DATA ───────────
  #
  # Three named capture views could not be graded because the tree held no
  # instance of what they are named for: `debugger--event-log` needs a revert,
  # `debugger--truncated` needs `execution.truncated`, and `tx-detail--dense`
  # needs a SECOND transaction with no session (the first is `tx-detail`'s own
  # subject). The renderers were already right in all three cases; only the data
  # was missing. These checks are what stop it going missing again — each one
  # fails if its subject is absent rather than passing over a tree without it.

  proc manifestFor(outDir, tx: string): JsonNode =
    for p in walkDirRec(outDir / "t"):
      if p.extractFilename != "manifest.json": continue
      let m = parseFile(p)
      if m["tx"].getStr == tx: return m
    nil

  proc factsFor(outDir, tx: string): JsonNode =
    parseFile(outDir / "d" / DemoChain / "tx" / shardKeyFor("hex", tx) / tx & ".json")

  proc overlayFor(outDir, tx: string): JsonNode =
    parseFile(outDir / "d" / DemoChain / "ts" / "1" / shardKeyFor("hex", tx) / tx & ".json")

  test "one transaction REVERTED, and its trace is published and undisputed":
    # `debugger--event-log`'s fifth entry kind. The pane appends `evRevert` off
    # the outcome, so without a reverted transaction it renders four of five and
    # correctly refuses to dress txB's `partial` split up as a revert.
    let h = synthHash(seed, "tx", 5)
    let facts = factsFor(outDir, h)
    check facts["outcome"]["overall"].getStr == "reverted"
    # Quantified, not asserted: a revert with no reason gives the metadata pane
    # a label and nothing to put under it.
    check facts["outcome"]["reason"].getStr.len > 0
    # A revert is an outcome, not a recording fault — the session must still
    # OPEN on it, or the event log has no surface to render the revert on.
    check overlayFor(outDir, h)["trace"]["availability"].getStr == "ready"
    check manifestFor(outDir, h)["validation"]["status"].getStr == "match"
    # Exactly one, so the count is a fact a reader can rely on rather than a
    # lower bound that would still pass if a later change made every tx revert.
    var reverted = 0
    for p in walkDirRec(outDir / "d" / DemoChain / "tx"):
      if parseFile(p)["outcome"]["overall"].getStr == "reverted": inc reverted
    check reverted == 1

  test "one recording hit the profile's budget — `execution.truncated`":
    # `debugger--truncated`'s subject. §14's banner is rendered from this flag by
    # `ssr.debugSessionFor`; nothing published it before.
    let h = synthHash(seed, "tx", 6)
    let m = manifestFor(outDir, h)
    check m["execution"]["truncated"].getBool
    # …and it is the ONLY one, so `debugger--truncated` and the plain debugger
    # views cannot both be photographing a truncated session.
    var truncated: seq[string]
    for p in walkDirRec(outDir / "t"):
      if p.extractFilename != "manifest.json": continue
      let mm = parseFile(p)
      if mm["execution"]["truncated"].getBool: truncated.add mm["tx"].getStr
    check truncated == @[h]
    # The transaction SUCCEEDED. Truncation is a fact about the recording, and a
    # truncated recording is precisely one whose ending is missing — so it must
    # not also be the transaction whose terminal event the event log renders.
    check factsFor(outDir, h)["outcome"]["overall"].getStr == "succeeded"
    check factsFor(outDir, h)["outcome"]["overall"].getStr !=
          factsFor(outDir, synthHash(seed, "tx", 5))["outcome"]["overall"].getStr

  test "a SECOND transaction has no session, and it is the densest one":
    # `tx-detail--dense`. After Page-Descriptions §7.0 the metadata page is
    # served only where there is no session, so a dense metadata page needs a
    # second traceless transaction — capturing the first one twice would answer
    # VD.4's extreme-content verification with a duplicate of `tx-detail`.
    var traceless: seq[string]
    for p in walkDirRec(outDir / "d" / DemoChain / "ts"):
      let ov = parseFile(p)
      if "trace" in ov and ov["trace"]["availability"].getStr == "onDemand":
        traceless.add ov["tx"].getStr
    check traceless.len == 2
    let dense = factsFor(outDir, synthHash(seed, "tx", 7))
    let plain = factsFor(outDir, synthHash(seed, "tx", 3))
    check synthHash(seed, "tx", 7) in traceless
    check synthHash(seed, "tx", 3) in traceless
    # Dense on every axis the view's must-show names, and dense RELATIVE to the
    # other traceless transaction — which is the comparison a reviewer makes,
    # and the one a fixed threshold would not survive a reseed of.
    check dense["roles"].len > plain["roles"].len
    check dense["roles"].len >= 5
    check dense["cost"].len > plain["cost"].len
    check dense["cost"].len >= 5
    check dense["payload"]["raw"].getStr.len > plain["payload"]["raw"].getStr.len
    check dense["payload"]["raw"].getStr.len > 1000
    # Every role a DISTINCT address, or "many roles" is one address repeated.
    var addrs: seq[string]
    for r in dense["roles"]: addrs.add r["address"].getStr
    check addrs.deduplicate.len == addrs.len

  test "the new subjects sit in the OLDEST block, so no capture view re-points":
    # `tools/capture/lib/entities.mjs` walks transactions newest block first and
    # every debugger view pins its subject with `txWithAvailability(...)` — "the
    # FIRST transaction whose trace is ready", and so on. A new ready
    # transaction in block 102 would therefore become `readyTx` and silently
    # move the flagship `debugger` view, `tx-detail--session` and four pane
    # views onto a different session, superseding every review recorded against
    # them. This asserts the placement that stops that, in the same order the
    # harness walks.
    for n in [5, 6, 7]:
      check factsFor(outDir, synthHash(seed, "tx", n))["order"]["height"].getInt == 100
    var firstReady = ""
    for height in [102, 101, 100]:
      let bh = synthHash(seed, "block", height)
      for tx in parseFile(outDir / "d" / DemoChain / "block" / bh & ".json")["transactions"]:
        let h = tx.getStr
        let ov = overlayFor(outDir, h)
        let execs = if "trace" in ov: @[ov["trace"]] else: ov["executions"].getElems
        if firstReady.len == 0 and execs.anyIt(it["availability"].getStr == "ready") and
           not execs.anyIt(it{"reconstructed"}.getBool):
          firstReady = h
    # txB, the private/public split at block 101 — unchanged by this milestone.
    check firstReady == synthHash(seed, "tx", 1)

suite "M5c — the published traces are the real noir_space_ship execution":
  # These tests exist because a well-formed but WRONG container passes every
  # structural check in the validator: `container.bytes`/`hash` describe whatever
  # bytes are there, so a stand-in from a different program validates perfectly.
  # The only way to catch that is to assert on the container's own contents.
  let outDir = tmp("realtrace")
  discard generate(DemoConfig(outDir: outDir, seed: "test-seed-1",
                              traceFixturePath: fixture,
                              traceSourcesDir: sourcesDir))

  proc containers(): seq[string] =
    for p in walkDirRec(outDir / "t"):
      if p.extractFilename == "trace.ct": result.add p
    result.sort()

  test "every published container really is the noir_space_ship program":
    let cs = containers()
    # txA, txB-public, txC-divergent, txE-reconstructed, txF-reverted,
    # txG-truncated. Every published execution carries the SAME real container:
    # the demo tree varies the chain facts and the published verdicts around it,
    # never the bytes.
    check cs.len == 6
    let want = readFile(fixture)
    for c in cs:
      let got = readFile(c)
      # Byte-identical to the vendored `nargo trace` output — not merely the same
      # size, and not a re-encoding.
      check got == want
      # CTFS container magic (`c0 de 72 ac`), so this is a real container and not
      # a JSON blob that happens to sit at the right path.
      check got.len > 4
      check got[0] == '\xC0' and got[1] == '\xDE'
      check got[2] == '\x72' and got[3] == '\xAC'
      # The program's own identifiers are interned in the container. `factorial`
      # (the old stand-in) has none of these, so this assertion is what would
      # have failed while the stand-in was in place.
      for marker in ["zk_shields", "src/main.nr", "src/shield.nr",
                     "iterate_asteroids", "remaining_shield"]:
        check marker in got

  test "the manifests describe the real container, not invented numbers":
    # `truncated` is the ONE field in `execution` that is a published claim
    # rather than a measurement of the container, and it is deliberately checked
    # here rather than exempted: `steps` and `frames` stay at the container's
    # real 1315/80 on the truncated manifest too. A manifest that shrank them to
    # look truncated would be describing a container that is not the one beside
    # it, which is exactly the "well-formed but wrong" failure this suite exists
    # to catch. What `truncated` says is where the recording STOPS — the
    # profile's budget rather than the program's end — and that is demo data in
    # the same way `validation: divergent` over the same completed container
    # already is.
    var seen = 0
    var truncatedSeen = 0
    for p in walkDirRec(outDir / "t"):
      if p.extractFilename != "manifest.json": continue
      inc seen
      let m = parseFile(p)
      # ct-print --summary on fixtures/trace/noir_space_ship/zk_shields.ct
      check m["execution"]["steps"].getInt == 1315
      check m["execution"]["frames"].getInt == 80
      check m["execution"]["languages"].getElems.mapIt(it.getStr) == @["noir"]
      check m["execution"]["sourceLevel"].getBool
      check m["container"]["bytes"].getInt == readFile(fixture).len
      check m["container"]["bytes"].getInt == 147456
      if m["execution"]["truncated"].getBool: inc truncatedSeen
    check seen == 6
    # Exactly one truncated recording, and therefore five that are not: the
    # §14 banner has a subject, and it is not on every session.
    check truncatedSeen == 1

  test "the overlay advertises the container's true size":
    # The client picks its fetch strategy from this number before it has the
    # object, so a stale value mis-sizes the request.
    let want = readFile(fixture).len
    var checkedAny = false
    for p in walkDirRec(outDir / "d" / DemoChain / "ts"):
      let ov = parseFile(p)
      var traces: seq[JsonNode]
      if "trace" in ov: traces.add ov["trace"]
      if "executions" in ov:
        for e in ov["executions"]: traces.add e
      for t in traces:
        if t{"availability"}.getStr in ["ready", "divergent"]:
          check t["bytes"].getInt == want
          checkedAny = true
    check checkedAny

  test "each manifest names a source bundle that resolves to real Noir source":
    # The container carries no source text (ct-print reports `source_views: []`),
    # so without this edge the debugger steps through code it cannot display.
    var checkedAny = false
    for p in walkDirRec(outDir / "t"):
      if p.extractFilename != "manifest.json": continue
      let m = parseFile(p)
      check m["sourceBundles"].len == 1
      for codeHash, idNode in m["sourceBundles"]:
        let cur = parseFile(outDir / "src" / DemoChain / codeHash / "current.json")
        check cur["sourceBundleId"].getStr == idNode.getStr
        let bundle = parseFile(outDir / cur["bundle"].getStr)
        check bundle["codeHash"].getStr == codeHash
        check bundle["language"].getStr == "noir"
        # The bundle must cover the paths the CONTAINER interns, or a step
        # resolves to a file the viewer does not have. `std/lib.nr` is the Noir
        # stdlib and is legitimately absent.
        for path in ["src/main.nr", "src/shield.nr"]:
          check path in bundle["sources"]
          check bundle["sources"][path]["content"].getStr.len > 0
        # Real source, not a placeholder.
        check "iterate_asteroids" in bundle["sources"]["src/shield.nr"]["content"].getStr
        check "mod shield;" in bundle["sources"]["src/main.nr"]["content"].getStr
        checkedAny = true
    check checkedAny

  test "the bundle id is the content hash of the bytes actually published":
    var checkedAny = false
    for p in walkDirRec(outDir / "src"):
      if p.extractFilename == "current.json": continue
      let body = readFile(p)
      let cur = parseFile(p.parentDir / "current.json")
      check cur["sourceBundleId"].getStr == contentHashSha1(body)
      checkedAny = true
    check checkedAny

suite "M5c — determinism":
  ## The property that makes the demo tree a usable regression fixture: the same
  ## seed produces a byte-identical tree AND byte-identical `.ct` containers.
  ## Verified by DIFFING the trees, never by asserting a recorded hash — a hash
  ## constant is a number somebody updates when it goes red.
  let a = tmp("det-a")
  let b = tmp("det-b")
  let other = tmp("det-other")
  discard generate(DemoConfig(outDir: a, seed: "same", traceFixturePath: fixture, traceSourcesDir: sourcesDir))
  discard generate(DemoConfig(outDir: b, seed: "same", traceFixturePath: fixture, traceSourcesDir: sourcesDir))
  discard generate(DemoConfig(outDir: other, seed: "different", traceFixturePath: fixture, traceSourcesDir: sourcesDir))

  test "the same seed produces a byte-identical tree, containers included":
    let fa = listFiles(a)
    check fa == listFiles(b)
    # A floor on the comparison, so this cannot pass over a tree the generator
    # failed to write. Without it the whole suite reduces to `@[] == @[]`, which
    # is the shape of a check that passes when its subject is absent.
    check fa.len >= 61
    check fa.anyIt(it.endsWith(".ct"))
    var compared = 0
    for rel in fa:
      check readFile(a / rel) == readFile(b / rel)
      inc compared
    check compared == fa.len

  test "a DIFFERENT seed produces a different tree — the check is not vacuous":
    # The negative control. "Byte-identical" is only evidence of determinism if
    # the generator is capable of producing something else; a generator that
    # ignored its seed entirely would pass the test above perfectly.
    let fa = listFiles(a)
    let fo = listFiles(other)
    check fa.len >= 61
    check fo.len >= 61
    # Nearly every path in the tree is hash-addressed, so the seed moves the
    # paths themselves. The two file LISTS are not merely different — they
    # barely overlap, and the handful that do are the fixed-name objects
    # (`registry/…`, `index.html`, `d/aztec/current.json`, the generation maps).
    check fa != fo
    check fa.filterIt(it in fo).len < fa.len div 2
    # The file COUNT is deliberately not asserted equal. The hash index emits one
    # `.bin` per OCCUPIED two-hex prefix, so how many shards exist depends on how
    # the seed's hashes collide — 145 at one seed and 146 at another, both
    # correct. A test that demanded equal counts would be asserting a property
    # the design does not have.
    #
    # The fixed-name objects, however, must differ in CONTENT — otherwise the
    # trees could differ only in filenames while publishing identical facts.
    check readFile(a / "d" / DemoChain / "current.json") !=
          readFile(other / "d" / DemoChain / "current.json")
    check readFile(a / "d" / DemoChain / "labels" / "0.json") !=
          readFile(other / "d" / DemoChain / "labels" / "0.json")
    # The containers, however, are the SAME bytes at every seed: they are
    # vendored, not generated, and the seed keys the chain facts around them.
    proc oneContainer(dir: string): string =
      for p in walkDirRec(dir / "t"):
        if p.extractFilename == "trace.ct": return readFile(p)
      ""
    check oneContainer(a).len > 0
    check oneContainer(a) == oneContainer(other)

suite "M5b — the contract names no producer":
  test "a hand-built EVM-shaped tree validates against the same contract version":
    # A DIFFERENT producer, DIFFERENT chain, DIFFERENT discriminated-union values,
    # validated by the same validator with no producer-specific branch.
    let d = tmp("evm")
    let chain = "eth"
    let recId = "evm"; let recVer = "1.0.0"
    let recBuild = recorderBuildHash(recId, recVer)
    let profH = profileHash("default")
    let traceSchema = "ctfs/v4"
    writeJsonNl(d / "registry" / "chains.v1.json", %*{
      "version": ContractVersion,
      "chains": {chain: {
        "recorder": {"id": recId, "build": recBuild, "version": recVer},
        "profile": {"name": "default", "hash": profH},
        "traceSchema": traceSchema}}})
    let tx = "0xdeadbeef" & repeat("0", 56)
    let blk = "0xabc123" & repeat("0", 58)
    let execId = demoExecutionInputId(chain, tx, "call")
    let facts = TransactionFacts(
      chain: chain,
      id: TxId(kind: tikHash, hash: tx),
      order: TxOrder(kind: tokBlockIndex, obBlock: blk, obHeight: 19_000_000, obIndex: 12),
      outcome: Outcome(overall: ooReverted, reason: "InsufficientBalance()", parts: @[]),
      roles: @[Role(role: "initiator", address: "0x1111" & repeat("0", 36)),
               Role(role: "feePayer", address: "0x2222" & repeat("0", 36))],
      cost: @[Cost(name: "gas", used: "21000", limit: "21000", price: "12",
                   unit: "gas", token: "ETH", refundable: false)],
      payloadRaw: "0xa9059cbb", payloadSelector: "0xa9059cbb",
      payloadTarget: "0x3333" & repeat("0", 36), logs: @[],
      codeEdges: @[], executions: @[Execution(selector: "call", executionInputId: execId)],
      native: %*{"evm": {"type": 2}})
    writeJsonNl(d / "d" / chain / "tx" / shardKeyFor("hex", tx) / tx & ".json", facts.toJson)
    writeJsonNl(d / "d" / chain / "block" / blk & ".json",
      BlockDetail(chain: chain, hash: blk, height: 19_000_000,
        parentHash: "0x00", transactions: @[tx]).toJson)
    writeJsonNl(d / "d" / chain / "g" / "1" / "txstate" / shardKeyFor("hex", tx) / tx & ".json",
      %*{"chain": chain, "tx": tx, "canonical": true, "finality": "finalized"})
    let ov = TraceSelection(chain: chain, tx: tx, hasSingle: true,
      singleTrace: ExecTrace(availability: taReady, bytes: readFile(fixture).len,
        hasValidation: true,
        validation: ValidationSummary(status: vsMatch, strength: 2)))
    writeJsonNl(d / "d" / chain / "ts" / "1" / shardKeyFor("hex", tx) / tx & ".json", ov.toJson)
    # the derived artifact
    let tid = deriveTraceArtifactId(execId, recId, recBuild, profH, traceSchema)
    let sh = traceShards(tid)
    let adir = d / "t" / sh.a / sh.b / tid
    createDir adir
    let bytes = readFile(fixture)
    writeFile(adir / "trace.ct", bytes)
    let manifest = TraceManifest(schema: ContractVersion, traceArtifactId: tid,
      executionInputId: execId, chain: chain, tx: tx,
      recorder: RecorderRef(id: recId, build: recBuild, version: recVer),
      profile: ProfileRef(name: "default", hash: profH), sourceBundles: newJObject(),
      container: ContainerRef(file: "trace.ct", bytes: bytes.len, blockSize: 4096,
        hash: contentHashSha1(bytes)),
      execution: ExecutionSummary(steps: 100, frames: 5, truncated: false,
        sourceLevel: true, languages: @["solidity"]),
      validation: ValidationSummary(status: vsMatch, strength: 2),
      validationOracle: "receipt-compare", prestateStrategy: "prestate-trace")
    writeJsonNl(adir / "manifest.json", manifest.toJson)
    # generation root + current pointer
    let summaryRel = "d" / chain / "g" / "1" / "summary.json"
    let heightRel = "d" / chain / "g" / "1" / "height" / "0.json"
    let blocksRel = "d" / chain / "g" / "1" / "blocks" / "0.json"
    let txstateRel = "d" / chain / "g" / "1" / "txstate" / shardKeyFor("hex", tx) / tx & ".json"
    writeJsonNl(d / summaryRel, %*{"chain": chain, "generation": "1",
      "counters": {"blocks": 1, "transactions": 1}, "coverageMode": "eager", "stale": false})
    writeJsonNl(d / heightRel, %*{"chain": chain, "epoch": 0, "heights": {"19000000": blk}})
    writeJsonNl(d / blocksRel, %*{"chain": chain, "epoch": 0, "blocks": [blk]})
    let root = GenerationRoot(contractVersion: ContractVersion, chain: chain,
      generation: "1", traceSelectionVersion: "1", summaryPath: summaryRel,
      heightPaths: @[heightRel], blockIndexPaths: @[blocksRel], addrPaths: @[],
      txstatePaths: @[txstateRel])
    writeJsonNl(d / "d" / chain / "g" / "1" / "root.json", root.toJson)
    writeJsonNl(d / "d" / chain / "current.json", %*{"chain": chain,
      "generation": "1", "traceSelectionVersion": "1",
      "head": {"height": 19000000, "hash": blk},
      "finalized": {"height": 19000000, "hash": blk}})

    let errs = validateTree(d)
    if errs.len > 0:
      for e in errs: echo "  ERR ", e
    check errs.len == 0

suite "M5c — /idx search indices and HTML entry pages":
  let outDir = tmp("idx")
  let seed = "idx-seed"
  discard generate(DemoConfig(outDir: outDir, seed: seed, traceFixturePath: fixture, traceSourcesDir: sourcesDir))

  test "the render + idx layers are emitted and declared in the generation root":
    let root = parseFile(outDir / "d" / DemoChain / "g" / "1" / "root.json")
    check "idx" in root and "render" in root
    check fileExists(outDir / "index.html")
    check fileExists(outDir / "idx" / DemoChain / "names" / "meta.json")
    # at least one hash shard and one name shard exist
    var hashShards, nameShards = 0
    for p in walkDirRec(outDir / "idx" / "hash"):
      if p.endsWith(".bin"): inc hashShards
    for p in walkDirRec(outDir / "idx" / DemoChain / "names"):
      if p.endsWith(".bin"): inc nameShards
    check hashShards > 0 and nameShards == 2

  test "the tx entry page inlines its data as a materialised view of /d":
    let h = synthHash(seed, "tx", 0)
    let page = outDir / DemoChain / "tx" / h / "index.html"
    check fileExists(page)
    let html = readFile(page)
    check "content=\"noindex,follow\"" in html          # N1 addressable-only
    check (siteBase & "/" & DemoChain & "/tx/" & h) in html          # canonical
    let (payload, found) = extractInlineData(html)
    check found
    let data = parseJson(payload)
    check data["kind"].getStr == "tx"
    check data["txHash"].getStr == h
    let onDisk = parseFile(outDir / "d" / DemoChain / "tx" / shardKeyFor("hex", h) / h & ".json")
    check data["facts"] == onDisk                        # a view, not a second truth

  test "the home page is the one index,follow page (§5 class I0)":
    let html = readFile(outDir / "index.html")
    check "content=\"index,follow\"" in html
    check (siteBase & "/\">") in html or (siteBase & "/\"") in html

  test "the hash index resolves every entity (tx, block, address)":
    let root = parseFile(outDir / "d" / DemoChain / "g" / "1" / "root.json")
    let hi = root["idx"]["hash"]
    let ver = hi["version"].getStr
    let pfx = hi["prefixLen"].getInt
    proc resolves(hexHash: string, kind: int): bool =
      let shard = outDir / "idx" / "hash" / ver /
        hashPrefix("hex", hexHash, pfx) & ".bin"
      if not fileExists(shard): return false
      for e in lookupHash(readFile(shard), "hex", hexHash):
        if e.chain == DemoChain and e.kind == kind: return true
      false
    check resolves(synthHash(seed, "tx", 0), hkTx)
    check resolves(synthHash(seed, "block", 100), hkBlock)
    check resolves(synthAddr(seed, "feepayer", 0), hkAddress)

  test "name shards decode, place terms correctly, and carry provenance (§6.2)":
    let meta = parseFile(outDir / "idx" / DemoChain / "names" / "meta.json")
    let shardBits = meta["shardBits"].getInt
    var sawCurated, sawSelf = false
    for sp in meta["shards"]:
      let dec = decodeNameShard(readFile(outDir / sp.getStr))
      check dec.err.len == 0
      for t in dec.terms:
        check shardOf(t.term, shardBits) == dec.shardNo
        for p in t.postings:
          check p.provenance in [provCurated, provSelfDeclared]
          if p.provenance == provCurated: sawCurated = true
          if p.provenance == provSelfDeclared: sawSelf = true
    check sawCurated and sawSelf    # curated names AND a self-declared one (adversarial corpus)

suite "M5c — the new /idx + entry-page assertions bite":
  proc freshIdx(name: string): string =
    result = tmp(name)
    discard generate(DemoConfig(outDir: result, seed: "bite", traceFixturePath: fixture, traceSourcesDir: sourcesDir))

  test "removing the home page fails conformance":
    let d = freshIdx("bite-home")
    removeFile(d / "index.html")
    check validateTree(d).len > 0

  test "flipping a tx entry page to index,follow fails":
    let d = freshIdx("bite-robots")
    let h = synthHash("bite", "tx", 0)
    let page = d / DemoChain / "tx" / h / "index.html"
    writeFile(page, readFile(page).replace("noindex,follow", "index,follow"))
    check validateTree(d).len > 0

  test "tampering with a tx entry page's inlined data fails (view drift)":
    let d = freshIdx("bite-view")
    let h = synthHash("bite", "tx", 0)
    let page = d / DemoChain / "tx" / h / "index.html"
    # Corrupt the inlined outcome so the page disagrees with /d — the materialised
    # view is no longer faithful.
    writeFile(page, readFile(page).replace("\"succeeded\"", "\"reverted\""))
    check validateTree(d).len > 0

  test "deleting a declared hash-index shard fails":
    let d = freshIdx("bite-hashdel")
    let h = synthHash("bite", "tx", 0)
    removeFile(d / "idx" / "hash" / "1" / hashPrefix("hex", h, 2) & ".bin")
    check validateTree(d).len > 0

  test "corrupting a hash-index shard's bytes fails":
    let d = freshIdx("bite-hashbytes")
    var shard = ""
    for p in walkDirRec(d / "idx" / "hash"):
      if p.endsWith(".bin"): shard = p; break
    writeFile(shard, "XXXX not a shard")
    check validateTree(d).len > 0

  test "corrupting a name shard's bytes fails":
    let d = freshIdx("bite-namebytes")
    writeFile(d / "idx" / DemoChain / "names" / "0.bin", "not a name shard")
    check validateTree(d).len > 0

  test "dropping shardBits from names meta.json fails":
    let d = freshIdx("bite-meta")
    let mp = d / "idx" / DemoChain / "names" / "meta.json"
    var m = parseFile(mp)
    m.delete("shardBits")
    writeFile(mp, m.pretty & "\n")
    check validateTree(d).len > 0

suite "M5b — malformed trees fail conformance":
  proc freshDemo(name: string): string =
    result = tmp(name)
    discard generate(DemoConfig(outDir: result, seed: "neg", traceFixturePath: fixture, traceSourcesDir: sourcesDir))

  proc firstTxFactsPath(dir: string): string =
    for p in walkDirRec(dir / "d" / DemoChain / "tx"):
      if p.endsWith(".json"): return p
    ""

  test "a forbidden mutable field in immutable facts fails":
    let d = freshDemo("neg-forbidden")
    let fp = firstTxFactsPath(d)
    var n = parseFile(fp)
    n["validation"] = %*{"status": "match"}
    writeFile(fp, n.pretty & "\n")
    check validateTree(d).len > 0

  test "availability:absent without a reason fails":
    let d = freshDemo("neg-absent")
    # txB overlay (private+public) — drop the private reason.
    let h = "0x" & toLowerAscii($secureHash("neg" & "|tx|1"))[0 .. 39]
    let ovp = d / "d" / DemoChain / "ts" / "1" / shardKeyFor("hex", h) / h & ".json"
    var ov = parseFile(ovp)
    for e in ov["executions"]:
      if e["selector"].getStr == "private": e.delete("reason")
    writeFile(ovp, ov.pretty & "\n")
    check validateTree(d).len > 0

  test "a broken discriminated-union tag fails":
    let d = freshDemo("neg-union")
    let fp = firstTxFactsPath(d)
    var n = parseFile(fp)
    n["id"].delete("kind")
    writeFile(fp, n.pretty & "\n")
    check validateTree(d).len > 0

  test "a container byte-size mismatch fails":
    let d = freshDemo("neg-bytes")
    var mp = ""
    for p in walkDirRec(d / "t"):
      if p.endsWith("manifest.json"): mp = p; break
    var n = parseFile(mp)
    n["container"]["bytes"] = %(n["container"]["bytes"].getInt + 1)
    writeFile(mp, n.pretty & "\n")
    check validateTree(d).len > 0

  test "an unsupported contract version in root.json fails":
    let d = freshDemo("neg-version")
    let rp = d / "d" / DemoChain / "g" / "1" / "root.json"
    var n = parseFile(rp)
    n["contractVersion"] = %(ContractVersion + 99)
    writeFile(rp, n.pretty & "\n")
    check validateTree(d).len > 0

  # --- the M5c real-trace edges, each verified to bite -----------------------

  # SORTED, and it requires the field the caller is about to mutate.
  #
  # This used to return the first `walkDirRec` hit whose overlay had a `trace`,
  # and `walkDirRec` yields in FILESYSTEM order — which differs between hosts.
  # Of the 17 overlays the demo tree publishes with a `trace`, four carry no
  # `bytes` at all (an on-demand trace advertises no container size), so the
  # selector had a 4-in-17 chance of handing back an overlay the test then
  # indexed with ["bytes"]. It drew a good one on GitHub-hosted ubuntu for as
  # long as anyone had looked, and drew a bad one the first time this job ran
  # on the self-hosted runner: `Unhandled exception: key not found: bytes`.
  #
  # The test was never about "whichever overlay comes first"; it is about an
  # overlay that ADVERTISES A SIZE. So the predicate now says so, and the sort
  # makes the choice the same on every host.
  proc firstOverlayAdvertisingBytes(dir: string): seq[string] =
    for p in walkDirRec(dir / "d" / DemoChain / "ts"):
      let n = parseFile(p)
      if n{"trace"} != nil and n{"trace"}{"bytes"} != nil: result.add p
    sort(result)

  test "an overlay advertising the wrong container size fails":
    # The client sizes its fetch from this before it has the object.
    let d = freshDemo("neg-overlay-bytes")
    let candidates = firstOverlayAdvertisingBytes(d)
    # The positive control on the scan: an empty candidate list would make the
    # mutation below a no-op and the assertion after it vacuous.
    check candidates.len > 0
    let op = candidates[0]
    var n = parseFile(op)
    n["trace"]["bytes"] = %(n["trace"]["bytes"].getInt div 2)
    writeFile(op, n.pretty & "\n")
    let errs = validateTree(d)
    check errs.len > 0
    check errs.anyIt("overlay advertises bytes" in it)

  test "a manifest naming a source bundle that was never published fails":
    let d = freshDemo("neg-bundle-missing")
    var mp = ""
    for p in walkDirRec(d / "t"):
      if p.endsWith("manifest.json"): mp = p; break
    let n = parseFile(mp)
    # Delete the bundle the manifest recommends, leaving the reference dangling.
    for codeHash, _ in n["sourceBundles"]:
      removeDir(d / "src" / DemoChain / codeHash)
    let errs = validateTree(d)
    check errs.len > 0
    check errs.anyIt("with no published" in it)

  test "a source bundle whose pointer dangles fails":
    let d = freshDemo("neg-bundle-pointer")
    var cp = ""
    for p in walkDirRec(d / "src"):
      if p.endsWith("current.json"): cp = p; break
    check cp.len > 0
    var n = parseFile(cp)
    n["bundle"] = %("src/" & DemoChain & "/nope/deadbeef.json")
    writeFile(cp, n.pretty & "\n")
    let errs = validateTree(d)
    check errs.len > 0
    check errs.anyIt("references a missing bundle" in it)

  test "a source bundle with empty source content fails":
    # A bundle that is structurally perfect but carries no readable source is
    # exactly the failure this edge exists to catch.
    let d = freshDemo("neg-bundle-empty")
    var bp = ""
    for p in walkDirRec(d / "src"):
      if p.endsWith(".json") and not p.endsWith("current.json"): bp = p; break
    check bp.len > 0
    var n = parseFile(bp)
    n["sources"]["src/shield.nr"]["content"] = %""
    writeFile(bp, n.pretty & "\n")
    let errs = validateTree(d)
    check errs.len > 0
    check errs.anyIt("has empty content" in it)

suite "contract version wiring":
  test "the artifact-schema constant is in lock-step with version.nim":
    check ArtifactSchemaVersion == 1
    check ContractVersion == 1

# ═══════════════════════════════════════════════════════════════════════════
# The §5 hash index, once it stopped being hex-only.
#
# NO MOCKS ARE USED IN THIS SUITE AND NONE ARE JUSTIFIED, because none are
# needed: every arm below runs the real codec over real values, and the arms
# that need a non-hex chain build one out of `HashEntry`s directly — which is
# the producers' own input type, not a stand-in for it. The one thing that is
# constructed rather than captured is the base58/bech32 IDENTIFIERS, and those
# are literals of the alphabets `tools/chain/identifier-encodings.json`
# declares, not fixtures of a chain this tree does not yet publish.
# ═══════════════════════════════════════════════════════════════════════════

suite "§5 hash index — keying per identifier shape":

  # Two real-shaped non-hex identifiers, spelled out so the arms below read as
  # the alphabets they are. The Solana address is 44 base58 characters; the
  # Cardano address is a bech32 string whose payload begins after its last `1`.
  const SolAddr = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
  const AdaAddr = "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer" &
                  "3n0d3vllmyqwsx5wktcd8cc3sq835lu7drv2xwl2wywfgse35a3x"
  const HexHash = "0x" & repeat("ab", 32)

  test "the shard key is the payload's leading slice, in the identifier's own alphabet":
    # hex strips `0x`; bech32 begins after the LAST `1`, which is what stops a
    # whole chain of `addr1…` landing in one bucket.
    check hashPrefix("hex", HexHash, 2) == "ab"
    check hashPrefix("base58", SolAddr, 2) == "9W"
    check hashPrefix("bech32", AdaAddr, 2) == AdaAddr[AdaAddr.rfind("1") + 1 .. ^1][0 .. 1]
    # …and it is the SAME payload the object tree's shard derivation slices, so
    # the index and the object layout cannot disagree about where one starts.
    check hashPrefix("bech32", AdaAddr, 4) == shardKeyFor("bech32", AdaAddr)

  test "a hex identifier's shard key is byte-for-byte what it always was":
    # The one property `just byte-identity` is the tree-wide form of.
    for n in [1, 2, 4]:
      check hashPrefix("hex", HexHash, n) ==
        identifierPayload("hex", HexHash)[0 ..< n]

  # ═════════════════════════════════════════════════════════════════════════
  # THE SWEEP. Read this before changing anything below it.
  #
  # WHY IT IS A SWEEP AND NOT A LIST OF LITERALS. §5's consumption rule needs the
  # property "every member a single query matches yields the same payload", and
  # that property is FALSE over the table as declared — 420 of 53,935 candidates
  # yield two distinct payloads (see "§5.5's old claim is FALSE" below). A handful
  # of hand-picked identifiers cannot find that out: the only realistic non-hex
  # identifier anyone reaches for is a 103-character Cardano address, and it could
  # not collide for TWO independent reasons — 103 is outside base58's 43–44 and
  # 87–88 bands, and the string contains `0` and `l`, two of the four digits
  # base58's alphabet deliberately excludes. An arm built from such literals would
  # assert the property and be evidence of nothing.
  #
  # NO EARLIER VERSION OF THIS FILE CONTAINED SUCH AN ARM, and an earlier draft of
  # this comment said one "used to sit here". It did not. The whole index-key
  # derivation is new in this change: at `a145e68`, and equally at the merged
  # `dev` this work now sits on (`4db3414`, which touches only CI and carries
  # these two files unchanged — verified by diffing both refs),
  # `client/src/viewmodel/search_shapes.nim` is 219 lines
  # with no `IndexProbe`, no `indexProbesOf` and no `indexKeysOf`, `hashPrefix`
  # takes no encoding, and neither this file nor that one contains the phrase
  # "same payload". The six-literal arm, the `keys[0]` consumption rule and the
  # payload-dedup rule that replaced it are all intermediate states of ONE
  # uncommitted change. Describing any of them as "the pre-fix code" invites a
  # reader to `git show` a state that does not exist, so this file does not.
  #
  # What follows generates candidates FROM THE DECLARED TABLE: every member's
  # prefixes × every character of its alphabet × every length up to a bound
  # derived from the widest band, plus deterministic mixed-alphabet fills. The
  # bound is derived rather than written down so that widening a band cannot
  # silently outrun the sweep.
  #
  # AND THE PROPERTY IT PINS IS A DIFFERENT ONE, because the old one is false
  # and is not being restored. See `indexProbesOf`: the client fetches EVERY
  # distinct payload, so what has to be true is that the probe set REACHES every
  # (SHARD, ENCODING) pair a producer could have written — which is a property of
  # the derivation and not of the table's current contents.
  #
  # THE PAIR, NOT THE SHARD. Reaching the shard is necessary and not sufficient,
  # because the fetched bytes are then scanned under an encoding and `hitsFor`
  # compares it for equality. A shards-only invariant is green on all 216 queries
  # where two admitted encodings share one payload — see that arm's header.
  # ═════════════════════════════════════════════════════════════════════════

  proc sweepCandidates(): seq[string] =
    var seen = initHashSet[string]()
    var widestPayload, longestPrefix = 0
    for e in IdentifierEncodings:
      for r in e.shapes:
        if r.maxPayload > widestPayload: widestPayload = r.maxPayload
        for p in r.prefixes:
          if p.len > longestPrefix: longestPrefix = p.len
    # Two past the widest reachable identifier: a candidate one character over
    # every band is what proves the band's upper edge is the edge.
    let top = widestPayload + longestPrefix + 2
    for e in IdentifierEncodings:
      if e.shapes.len == 0: continue
      var prefixes = @[""]
      for r in e.shapes:
        for p in r.prefixes:
          if p notin prefixes: prefixes.add p
      let alpha = e.shardKey.alphabet
      for p in prefixes:
        for c in alpha:
          var s = p
          for n in 1 .. top:
            s.add c
            if s notin seen: seen.incl s; result.add s
        # MIXED FILLS, because a uniform one cannot reach a string whose
        # alphabet membership depends on WHICH characters it drew: a bech32
        # payload containing `0` or `l` is not writable in base58, and a sweep
        # of single-character repeats would report every such length clean.
        for seed in 1 .. 4:
          var st = uint32(seed * 7919 + 12345)
          var s = p
          for n in 1 .. top:
            st = st * 1664525'u32 + 1013904223'u32
            s.add alpha[int(st shr 16) mod alpha.len]
            if s notin seen: seen.incl s; result.add s

  # `let`, not `const`: evaluating a hundred thousand strings in the
  # compile-time VM costs minutes and buys nothing — the sweep is run, not baked.
  let Sweep = sweepCandidates()

  test "the sweep covers the closed set's bands and alphabets, not six literals":
    # The generator is derived from the table, so its SIZE is a fact about the
    # table and worth stating: if a member is dropped the count falls, and if a
    # band is widened it rises. It is checked as a floor rather than an equality
    # because a member added to the closed set must not turn this arm red for
    # being bigger than it was.
    check Sweep.len > 50_000
    # Every member with shapes is REACHED — a generator that quietly produced
    # nothing for an encoding would satisfy every "must not contain" assertion
    # below it, which is the trap `Verification-Harness-Traps.md` names first.
    var reached: seq[string] = @[]
    for q in Sweep:
      for enc in identifierEncodingsMatching(q):
        if enc notin reached: reached.add enc
    for e in IdentifierEncodings:
      if e.shapes.len == 0:
        check e.id notin reached          # `decimal` declares none, on purpose
      else:
        check e.id in reached

  test "§5.5's old claim is FALSE, and this is the census that says so":
    # "every member a single query matches yields the SAME payload… §2's rows
    # for those are mutually exclusive with every other row" — the sentence the
    # client's `keys[0]` rested on. Swept, it fails. The arm records WHERE, so a
    # reader can re-derive §5.5's replacement text rather than trust it.
    var overlapping = 0
    var pairs = initCountTable[string]()
    var maxPayloads = 1
    for q in Sweep:
      var safe: seq[string] = @[]
      var payloads: seq[string] = @[]
      for enc in identifierEncodingsMatching(q):
        if not identifierEncodingRule(enc).pathSafe: continue
        safe.add enc
        let p = identifierPayload(enc, q)
        if p notin payloads: payloads.add p
      if payloads.len > 1:
        inc overlapping
        pairs.inc safe.join("+")
        if payloads.len > maxPayloads: maxPayloads = payloads.len
    check overlapping > 0
    # PRINTED, NOT MERELY COMPUTED — and that distinction was a defect here until
    # 2026-09-16. Two docstrings said these figures were "printed by `just test`'s
    # `tcontract` arm", and they were not: `unittest` shows a value only when a
    # `check` FAILS, so a green run printed none of them and a reader following
    # that instruction to re-derive the number got an empty grep. Measured on the
    # log before this line existed: 0 occurrences of `420`, `462` or `53,935`.
    # A figure documented as re-derivable from a run has to actually be in the run.
    echo "  sweep: ", Sweep.len, " candidates; ", overlapping,
         " with >1 distinct payload over pathSafe MATCHES; pairs: ", $pairs
    # TWO pairs, and the second one is not the one the defect was reported
    # against: `bech32`×`ss58` is the same mechanism at SS58's 46–48 band as
    # `bech32`×`base58` is at base58's 43–44 and 87–88.
    check "base58+bech32" in pairs
    check "bech32+ss58" in pairs
    # …AND THE COST BOUND §5's request arithmetic now rests on. Two distinct
    # payloads is two shards is one extra request. A table edit that made it
    # three would turn this red, which is the point: §5's bullet says "at most
    # three requests", and that number has to be re-derivable.
    check maxPayloads == 2

  test "a BARE hex string is also an SS58 account, and the hex arm dropped it":
    # THE THIRD FAMILY, AND IT IS NOT IN §2's TABLE — which is why the arm above
    # cannot see it and why nothing in the spec's wording covers it.
    # `identifierEncodingsMatching` never returns `hex` here: §2's hex rows carry
    # a `0x` prefix and this string has none. It is `hexBodyOf`'s MEASURED
    # EXTENSION — a bare hash, accepted above `BareHexFloor` — that makes the
    # string a hex query at all, and `indexKeysOf` used to `return` on that arm,
    # discarding every other reading before `indexProbesOf` could see it.
    #
    # The hex digits are a subset of base58's and SS58's alphabets, hex folds
    # case and both of those preserve it, so the two payloads differ in case and
    # the two shards are different directories.
    for (q, other) in [("A".repeat(46), "ss58"), ("A".repeat(43), "base58"),
                       ("A".repeat(44), "base58")]:
      check identifierEncodingsMatching(q) == @[other] or
            identifierEncodingsMatching(q) == @[other, "base64"]
      let probes = indexProbesOf(q)
      check probes.len == 2
      check probes[0].encoding == "hex"
      check probes[1].encoding == other
      # Folded against preserved — the same 46 characters in two cases, which
      # `Threat-Model` §11 is explicit are not one identifier.
      check probes[0].payload == toLowerAscii(q)
      check probes[1].payload == q
      check probes[0].payload != probes[1].payload

  test "the ambiguity census, by family and by cost":
    # WHAT AN AMBIGUOUS QUERY COSTS, re-derivable rather than remembered. §5's
    # first bullet is a request count, so the number of distinct shards a query
    # can imply is a number the spec has to be able to state — and this is where
    # it is measured. Four families, one extra request at most.
    var fams = initCountTable[string]()
    var maxProbes = 1
    var ambiguous = 0
    for q in Sweep:
      let probes = indexProbesOf(q)
      if probes.len <= 1: continue
      inc ambiguous
      if probes.len > maxProbes: maxProbes = probes.len
      fams.inc probes.mapIt(it.encoding).join("+")
    # THE COST HALF OF THIS ARM'S SUBJECT, against the declared bound rather than
    # against a `2` written here. Note what this arm can and cannot see: its
    # population is `sweepCandidates`, which cannot reach a three-payload query at
    # all (see the cross-alphabet header below), so this assertion passing is
    # evidence about the GENERATOR. The cross arm is where the bound is tested
    # against a population that could falsify it.
    # PRINTED for the reason the arm above prints its census: `ambiguous` is the
    # **462** that `indexProbesOf`'s docstring and §5.3's histogram both cite, and
    # it is a DIFFERENT population from the arm above's 420 — probes include the
    # bare-hex arm, pathSafe matches do not. The two were stated as one number for
    # a while, which is the defect that made this line worth adding.
    echo "  probes: ", Sweep.len, " candidates; ", ambiguous,
         " imply >1 distinct payload (= >1 shard = one extra request); max ",
         maxProbes, "; families: ", $fams
    check maxProbes == MaxDistinctPayloadsPerQuery
    check ambiguous > 0
    # The two §2-table families…
    check "base58+bech32" in fams
    check "bech32+ss58" in fams
    # …and the two the bare-hex extension adds, which are this repository's own
    # and are in no version of §2.
    check "hex+base58" in fams
    check "hex+ss58" in fams
    # Nothing else — OVER THIS GENERATOR, which is a weaker statement than it
    # reads as. See the cross-alphabet arm below: filling a prefix from another
    # encoding's alphabet, or in another case, reaches two further families. This
    # count is the census of what `sweepCandidates` can emit and is pinned at that.
    check fams.len == 4

  # ═════════════════════════════════════════════════════════════════════════
  # THE CROSS-ALPHABET, MIXED-CASE SWEEP — because the bound asserted above is
  # TRUE BY CONSTRUCTION OF THE GENERATOR AND NOT BY MEASUREMENT.
  #
  # `sweepCandidates` fills a candidate carrying encoding *E*'s prefix from *E's
  # OWN alphabet* (`let alpha = e.shardKey.alphabet`, inside the `for e in
  # IdentifierEncodings` loop). It never crosses one encoding's prefix with
  # another's alphabet, and it never varies case. Both omissions bound what it
  # can conclude:
  #
  #   - bech32's and bech32m's alphabet is ALL-LOWERCASE, so every
  #     bech32-matching candidate it emits is all-lowercase. hex's fold is then a
  #     no-op, and hex's payload is character-identical to base58's and ss58's —
  #     so the generator cannot produce a string where hex, a base58-family
  #     reading AND a bech32 reading are three DIFFERENT payloads.
  #   - an hrp is only ever filled from its own charset, so `FUEL1…` — base58
  #     accepts `L` and rejects `l` — is unreachable, and with it every overlap
  #     that needs a case-varied hrp.
  #
  # So the bound asserted above is a property of the generator. What it guards
  # is §5.3's request arithmetic, which is a claim about the world.
  #
  # THE CONCRETE COUNTEREXAMPLE, executed rather than argued: adding one
  # plausible additive row to bech32 — `bc1`, Bitcoin segwit, whose hrp is
  # spellable in hex because `b`, `c` and `1` are all hex digits — makes
  # `BC1` + `2`×40 imply THREE distinct payloads, and `sweepCandidates` still
  # reports 2. Re-measured 2026-09-16 with the row temporarily added to the shared
  # file and both sweeps recompiled against it:
  #
  #   own-alphabet sweep   53,935 -> 58,539 candidates, maxProbes 2 (UNCHANGED)
  #                        probe families 4 -> 5 (`hex+bech32` is the new one)
  #   cross-alphabet sweep 223,670 -> 251,748 candidates, maxProbes 2 -> 3
  #                        worst = BC1 + `2`×40, exactly the string below
  #
  # READ THE TWO ARMS' REACTIONS TOGETHER, because that is the reason this number
  # is now named. In the arm ABOVE — whose title is "by family AND by cost" — the
  # COST assertion stays green while the FAMILY census (`fams.len == 4`) reddens:
  # it reports a change in the family list while the bound it also claims to
  # measure has moved underneath it unremarked. In THIS arm the bound assertion is
  # the one that reddens. Against a bare `== 2` both reds read as "the client
  # regressed"; against `MaxDistinctPayloadsPerQuery` they read as what they are —
  # the table grew, so the declared bound and §5.3's sentence must move with it.
  #
  #   q = BC12222222222222222222222222222222222222222   (43)
  #     hex     payload = bc1222…  (43)  <- folds
  #     base58  payload = BC1222…  (43)  <- preserves
  #     bech32  payload = 222…     (40)  <- after the last `1`
  #
  # THE BOUND IS STILL 2 AND STILL ABOUT REQUESTS. The (shard, encoding) fix
  # below widens what a fetched shard is SCANNED under; it does not change how
  # many shards are fetched, because the dedup that produces one request per
  # distinct payload is unchanged. So §5.3's arithmetic rests on the same number
  # it did — this arm is what measures it over a population that could have
  # falsified it.
  # ═════════════════════════════════════════════════════════════════════════

  proc caseVariants(s: string): seq[string] =
    ## As typed, folded, raised, and alternating — the fourth because BIP-173
    ## makes a MIXED-case bech32 string invalid while base58 and SS58 treat case
    ## as identity, so a mixed spelling is exactly where the two rules disagree.
    result = @[s, s.toLowerAscii, s.toUpperAscii]
    var alt = ""
    for i, c in s:
      alt.add (if i mod 2 == 0: c.toUpperAscii else: c.toLowerAscii)
    result.add alt

  proc crossCandidates(): seq[string] =
    ## Every declared prefix × every declared alphabet × four case variants —
    ## the cross product `sweepCandidates` does not take.
    var seen = initHashSet[string]()
    var widestPayload, longestPrefix = 0
    var prefixes = @[""]
    var alphabets: seq[string] = @[]
    for e in IdentifierEncodings:
      for r in e.shapes:
        if r.maxPayload > widestPayload: widestPayload = r.maxPayload
        for p in r.prefixes:
          if p.len > longestPrefix: longestPrefix = p.len
          if p notin prefixes: prefixes.add p
      if e.shapes.len > 0 and e.shardKey.alphabet notin alphabets:
        alphabets.add e.shardKey.alphabet
    let top = widestPayload + longestPrefix + 2
    for p in prefixes:
      for alpha in alphabets:
        for c in alpha:
          var s = p
          for n in 1 .. top:
            s.add c
            for v in caseVariants(s):
              if v notin seen: seen.incl v; result.add v
        for seed in 1 .. 4:
          var st = uint32(seed * 7919 + 12345)
          var s = p
          for n in 1 .. top:
            st = st * 1664525'u32 + 1013904223'u32
            s.add alpha[int(st shr 16) mod alpha.len]
            for v in caseVariants(s):
              if v notin seen: seen.incl v; result.add v

  let Cross = crossCandidates()

  test "the request bound survives a CROSS-ALPHABET, MIXED-CASE sweep":
    # ── EVERY FIGURE THIS ARM STATES IS ONE CONSTANT, ASSERTED AS AN EQUALITY, AND
    # ECHOED, for exactly the reason the sibling arm below spells out at
    # `PairsChecked`. It did not used to be. All four numbers lived in PROSE over
    # guards that were nowhere near them — `> 200_000` under a stated 223,670,
    # `> 20_000` under 22,976, a bare `> 0`, and bare membership for 124 and 93 —
    # so nothing compared a stated measurement to the measurement and nothing
    # printed either. Every one of them could have drifted by thousands while this
    # arm went on reporting success, which is the stale-figure shape this campaign
    # has now hit three times in three files.
    #
    # An equality reddens when the closed set grows. That is the intended cost: a
    # new row legitimately moves these counts, and being told to re-read them is
    # the point. A floor absorbs the growth and keeps asserting a figure nobody
    # re-measured. Re-measured 2026-09-16 under Nim 2.2.10.
    const
      CrossCandidates = 223_670    # the population, on the table as declared
      MixedCaseBech32 = 22_976     # …of which reach a mixed-case bech32 reading
      FoldedVsPreserved = 84       # …which are hex in one reading and
                                   #   base58-family in another, DIFFERENT payload
      CrossBase58Bech32m = 124     # the two families the own-alphabet generator
      CrossBech32mSs58 = 93        #   cannot see; both need a case-varied hrp
    # The population `sweepCandidates` cannot emit, and the bound re-measured over
    # it.
    echo "    cross-alphabet candidates: ", Cross.len
    check Cross.len == CrossCandidates
    # NOT VACUOUS, and this is the assertion that says so. A cross sweep that
    # reached no mixed-case bech32 string would satisfy the bound below for the
    # same reason the generator above does, and would be the trap
    # `Verification-Harness-Traps.md` names first: a sweep whose population is
    # empty in exactly the region it was written to cover.
    var mixedCaseBech = 0
    for q in Cross:
      if "bech32" in identifierEncodingsMatching(q) and q != q.toLowerAscii:
        inc mixedCaseBech
    echo "    …reaching a mixed-case bech32 reading: ", mixedCaseBech
    check mixedCaseBech == MixedCaseBech32
    # …and it reaches strings that are hex in one reading and base58-family in
    # another with a DIFFERENT payload, which is the shape a three-payload query
    # would have to have. THE `> 0` HERE WAS THE WEAKEST GUARD IN THE FILE: this
    # population is the whole reason the arm exists, and one witness satisfied it.
    var foldedAgainstPreserved = 0
    for q in Cross:
      if canonicalHash(q).len == 0: continue
      for enc in identifierEncodingsMatching(q):
        if not identifierEncodingRule(enc).pathSafe: continue
        if identifierPayload(enc, q) != identifierPayload("hex", q):
          inc foldedAgainstPreserved
          break
    echo "    …hex-folded against a preserved payload: ", foldedAgainstPreserved
    check foldedAgainstPreserved == FoldedVsPreserved
    # THE BOUND. One request per distinct payload; §5.3 spends at most one extra.
    var maxProbes = 1
    var worst = ""
    for q in Cross:
      let n = indexProbesOf(q).len
      if n > maxProbes: maxProbes = n; worst = q
    # THE BOUND, against the one declared number rather than a literal. This is
    # the arm whose population CAN reach 3 — measured, by adding a `bc1` row and
    # re-running: this reports 3 and the own-alphabet arm still reports 2. Before
    # this read `MaxDistinctPayloadsPerQuery`, that measurement reddened a `== 2`
    # written here, which reads as "the client regressed" when what actually
    # happened is that the table grew and the spec's arithmetic moved with it.
    # Now the row and this number move together, in one place, deliberately.
    check maxProbes == MaxDistinctPayloadsPerQuery
    check worst.len > 0
    # THE TWO FAMILIES THE GENERATOR ABOVE CANNOT SEE, named so that this arm
    # reports rather than merely passes. Both need a case-varied hrp: `FUEL1…` is
    # writable in base58 (`L` is in the alphabet, `l` is one of the four digits it
    # excludes) and folds to a bech32m string.
    var fams = initCountTable[string]()
    for q in Cross:
      var safe: seq[string] = @[]
      var payloads: seq[string] = @[]
      for enc in identifierEncodingsMatching(q):
        if not identifierEncodingRule(enc).pathSafe: continue
        safe.add enc
        let p = identifierPayload(enc, q)
        if p notin payloads: payloads.add p
      if payloads.len > 1: fams.inc safe.join("+")
    # ECHOED WHOLE, not just the two that are asserted. Membership was all this
    # used to check, so a family that collapsed from 124 witnesses to 1 passed
    # identically — and the other two families this table holds were neither
    # asserted nor printed, so a reader had no way to see them at all.
    #
    # READ BEFORE ORDERING, and not with `CountTable.sort`: that sort permutes the
    # table's slots in place without rehashing, so every later `[]` on it is
    # undefined. The pairs are copied out into a seq and THAT is ordered.
    let base58Bech32m = fams["base58+bech32m"]
    let bech32mSs58 = fams["bech32m+ss58"]
    var famRows: seq[(int, string)] = @[]
    for fam, n in fams: famRows.add (n, fam)
    famRows.sort(Descending)
    for (n, fam) in famRows: echo "    cross family ", fam, ": ", n
    check base58Bech32m == CrossBase58Bech32m
    check bech32mSs58 == CrossBech32mSs58

  test "the probe set REACHES every (shard, encoding) a producer could have written":
    # THE REPLACEMENT INVARIANT, and the one the design now rests on. For every
    # candidate and every pathSafe member it matches, the shard that member
    # implies is one of the shards `indexProbesOf` will fetch. A producer keyed
    # by its chain's DECLARED encoding; the client does not know the chain; so
    # unless the client's probe set covers every admissible reading, some
    # producer's shard is one the client never asks for — §5.0a's false absence.
    #
    # **IT COMPARED SHARDS ONLY, AND THAT IS WHY IT DID NOT CATCH THE SECOND
    # FALSE ABSENCE.** Reaching the shard is necessary and NOT sufficient: the
    # client also has to scan the bytes it fetched under the encoding the
    # producer declared, because `hitsFor` compares the entry's encoding for
    # equality. `indexProbesOf` deduplicates by payload, so where two admitted
    # encodings shared one payload the probe used to carry only the first by JSON
    # DECLARATION ORDER — and this arm returned `true` on exactly those queries
    # while "does any probe carry the producer's encoding" returned `false`. The
    # shard was fetched, the entry was in it, and the answer was still "absent".
    #
    # So the unit of the invariant is the PAIR. 0 pairs unreachable after the fix,
    # and 216 queries unreachable before it — `base64url`+`ss58` 174,
    # `hex`+`base58` 24, `hex`+`ss58` 18.
    #
    # THE SIZE OF THE POPULATION IS PINNED AS A CONSTANT AND NOT RESTATED IN THIS
    # PROSE, and that is deliberate. This sentence used to carry the figure as
    # words — "15,975 (shard, encoding) pairs checked" — over an assertion that
    # read `checked > 15_000`. The true count was 19,256, so the stated
    # measurement was wrong by 3,281 and the floor beneath it was 4,256 short of
    # the value it was guarding: it could not have caught the error at any point,
    # and the number drifted precisely because nothing compared it to the run.
    # There is now ONE copy of the figure — `PairsChecked` below — and the
    # assertion is an EQUALITY against it, so a divergence between the stated
    # measurement and the measurement is the failure rather than the silence.
    #
    # An equality is right here even though it reddens when the closed set grows:
    # a new row legitimately moves this count, and being told to re-read it is the
    # intended cost. A floor would absorb the growth and go on asserting a figure
    # nobody had re-measured, which is the failure this arm has now had twice.
    const PairsChecked = 19_256
    #
    # `shardOnly` IS KEPT AND ASSERTED SEPARATELY, rather than deleted as
    # subsumed, because the two can fail independently and a reader who sees only
    # the pair count cannot tell which half moved: a derivation that stopped
    # emitting a payload fails both, and one that stopped carrying an encoding
    # fails only the pair.
    var checked = 0
    var unreachableShard: seq[string] = @[]
    var unreachablePair: seq[string] = @[]
    for q in Sweep:
      let probes = indexProbesOf(q)
      # EVERY ENCODING A PRODUCER COULD HAVE DECLARED FOR THIS STRING, which is
      # the table's matches PLUS the bare-hex extension. `identifierEncodingsMatching`
      # does not return `hex` for a string with no `0x` — §2's hex rows carry the
      # prefix — so enumerating it alone would have left the hex half of the two
      # bare-hex families out of the invariant that is supposed to cover them.
      var declarable: seq[string] = @[]
      if canonicalHash(q).len > 0: declarable.add "hex"
      for enc in identifierEncodingsMatching(q):
        if enc notin declarable: declarable.add enc
      for enc in declarable:
        if not identifierEncodingRule(enc).pathSafe: continue
        inc checked
        let want = hashPrefix(enc, q, HashShardPrefixLen)
        var shardReached = false
        var pairReached = false
        for p in probes:
          if hashPrefix(p.encoding, p.identifier, HashShardPrefixLen) == want:
            shardReached = true
            # …and the fetched bytes are scanned under this encoding too.
            if enc in p.encodings: pairReached = true
        if not shardReached and q notin unreachableShard: unreachableShard.add q
        if not pairReached and q notin unreachablePair: unreachablePair.add q
    # PRINTED, so the equality below can be re-derived from a green log instead of
    # only from a red one. This is the figure the header used to state as words.
    echo "  pairs: ", checked, " (shard, encoding) pairs checked over ",
         Sweep.len, " candidates; unreachable shard ", unreachableShard.len,
         ", unreachable pair ", unreachablePair.len
    check checked == PairsChecked
    check unreachableShard.len == 0
    # THE STRENGTHENED HALF. This is the assertion that goes red on the code as it
    # stood before the payload-dedup fix, with 216 witnesses.
    check unreachablePair.len == 0

  test "the `addr1…` family reaches BOTH shards — the witness that was missed":
    # The exact strings the review executed, named rather than generated, so
    # this arm reads as the defect report it closes. Each is 43/44/87 characters
    # of base58's alphabet AND a bech32 string with an `addr1`/`stake1` human-
    # readable part, and both members are `pathSafe`, so neither is skipped.
    for q in ["addr1" & repeat("q", 38),      # 43 — base58's lower band
              "addr1" & repeat("q", 39),      # 44 — base58's upper band
              "addr1" & repeat("q", 82),      # 87 — base58's signature band
              "stake1" & repeat("q", 38),     # 44
              "addr1" & repeat("q", 41),      # 46 — SS58's band
              "stake1" & repeat("q", 42)]:    # 48 — SS58's band
      let matches = identifierEncodingsMatching(q)
      check "bech32" in matches
      check matches.len >= 2
      # Two probes, two payloads, two shards. The pre-fix client took the first
      # and asked ONE of them.
      let probes = indexProbesOf(q)
      check probes.len == 2
      var shards: seq[string] = @[]
      for p in probes:
        let s = hashPrefix(p.encoding, p.identifier, ShardWidth)
        if s notin shards: shards.add s
      check shards.len == 2
      # The bech32 reading — the one a Cardano producer would have written — is
      # among them, and it is NOT the one declaration order puts first.
      var bechShard = ""
      for p in probes:
        if p.encoding == "bech32":
          bechShard = hashPrefix(p.encoding, p.identifier, ShardWidth)
      check bechShard.len > 0
      check bechShard in shards
      # …and so is the WHOLE-STRING reading, which is the human-readable part
      # keyed as though it were payload: `addr`, `stak`.
      check q[0 ..< ShardWidth] in shards
      check bechShard != q[0 ..< ShardWidth]
    # WHICH ONE `keys[0]` WOULD HAVE PICKED DEPENDS ON DECLARATION ORDER, which
    # is the second and independent reason the rule was unsafe. `base58`
    # precedes `bech32` in the shared file and `bech32` precedes `ss58`, so the
    # pre-fix client asked `addr` for the base58-band witnesses and `qqqq` for
    # the SS58-band ones — missing the other one each time, for a reason that is
    # a fact about the order of a JSON array and nothing else.
    check indexProbesOf("addr1" & repeat("q", 38))[0].encoding == "base58"
    check indexProbesOf("addr1" & repeat("q", 41))[0].encoding == "bech32"

  test "an unambiguous query still costs exactly one shard":
    # The other half of the cost claim, and the reason option (a) was affordable:
    # NOTHING realistically shaped is ambiguous. Nine identifiers, one per member
    # of the closed set that has a realistic spelling, each yielding one probe.
    for q in [HexHash, "0x" & repeat("ab", 20), SolAddr, AdaAddr,
              "stake1uyehkck0lajq8gldd8dk2x2mwm8fnvlqpnvgfvj4pnflkdgkm4y9m",
              "5VERv8NsvbmPmDwPAP2FBQ2QSfmvsFbbLpMqZvnTwsL9VJNRQvKPGqGcmsxRTgcbGGnTA8JvHqHPmmWMPWDvbRXX",
              "fuel1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
              "EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N",
              "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"]:
      check indexProbesOf(q).len == 1

  test "a 44-character string matches base58 AND base64, and §2 says both":
    let ms = identifierEncodingsMatching(SolAddr)
    check "base58" in ms
    check "base64" in ms
    # base64's alphabet contains `/`, so it has no shard — and skipping it must
    # not cost the base58 candidate, which is the one the producer wrote.
    check not identifierEncodingRule("base64").pathSafe

  test "a base58 and a bech32 identifier round-trip through a shard":
    let entries = @[
      HashEntry(encoding: "hex", identifier: HexHash, chain: "aztec", kind: hkTx),
      HashEntry(encoding: "base58", identifier: SolAddr, chain: "solana",
                kind: hkAddress),
      HashEntry(encoding: "bech32", identifier: AdaAddr, chain: "cardano",
                kind: hkAddress)]
    let bytes = encodeHashShard(entries, 2)
    let dec = decodeHashShard(bytes)
    check dec.err.len == 0
    check dec.fmt == HashFmtKeyForm          # a non-hex entry forces format 2
    check dec.entries.len == 3
    # Every identifier comes back EXACTLY as published — including bech32's
    # human-readable part, which a payload-only entry would have lost.
    var byChain = initTable[string, HashEntry]()
    for e in dec.entries: byChain[e.chain] = e
    check byChain["solana"].identifier == SolAddr
    check byChain["solana"].encoding == "base58"
    check byChain["cardano"].identifier == AdaAddr
    check byChain["cardano"].encoding == "bech32"
    check byChain["aztec"].identifier == HexHash
    # …and the route is reconstructible, which is what "retrievable" means.
    check routeFor(byChain["cardano"].chain, byChain["cardano"].kind,
                   byChain["cardano"].identifier) ==
          "/cardano/address/" & AdaAddr & "/"
    # Exact lookup finds each one under its own encoding.
    check lookupHash(bytes, "base58", SolAddr).len == 1
    check lookupHash(bytes, "bech32", AdaAddr).len == 1
    check lookupHash(bytes, "hex", HexHash).len == 1

  test "the CLIENT recomputes the producer's shard from the query alone":
    # §5: "a derivation the producer can do and the browser cannot is not done."
    # The producer keys from the CHAIN's declared encoding; the client keys from
    # the QUERY's shape, with no registry in hand. They must land on one shard.
    for (declared, id) in [("base58", SolAddr), ("bech32", AdaAddr),
                           ("hex", HexHash)]:
      let producerShard = hashPrefix(declared, id, 2)
      let keys = indexKeysOf(id)
      check keys.len > 0
      var reached = false
      for k in keys:
        if hashPrefix(k.encoding, k.identifier, 2) == producerShard: reached = true
      check reached

  test "an all-hex shard is still format 1, and its bytes have not moved":
    let entries = @[
      HashEntry(encoding: "hex", identifier: HexHash, chain: "aztec", kind: hkTx),
      HashEntry(encoding: "hex", identifier: "0x" & repeat("ab", 20),
                chain: "aztec", kind: hkAddress)]
    check entries.shardIsAllHex
    let bytes = encodeHashShard(entries, 2)
    check ord(bytes[4]) == HashFmtHexBytes
    let dec = decodeHashShard(bytes)
    check dec.err.len == 0
    check dec.fmt == HashFmtHexBytes
    # Format 1 cannot store the `0x` — it stores decoded pairs — so the decoder
    # puts it back rather than leaving every caller to.
    for e in dec.entries:
      check e.encoding == "hex"
      check e.identifier.startsWith("0x")
    check lookupHash(bytes, "hex", HexHash).len == 1

  test "a client that reads only format 1 REFUSES a format-2 shard by name":
    # §6.1: "a client encountering an unknown major version renders a 'please
    # reload' state rather than misinterpreting". The decoder's half of that is
    # a message naming what arrived — which is why v2 lives at its own
    # `{version}` path and never inside `/idx/hash/1/`.
    let v2 = encodeHashShard(@[
      HashEntry(encoding: "base58", identifier: SolAddr, chain: "solana",
                kind: hkAddress)], 2)
    var tampered = v2
    tampered[4] = chr(99)                       # a format neither build knows
    let dec = decodeHashShard(tampered)
    check dec.err.len > 0
    check "unsupported hash-index format 99" in dec.err

  test "a non-hex identifier REFUSES BY NAME instead of crashing a producer":
    # The replaced `hexToBytes` reached `parseHexInt` and raised an unhandled
    # `ValueError` — measured as `parseHexInt: invalid hex integer: 0x`, which
    # names a string function and nothing else. The refusal names the encoding,
    # the identifier, the offending character and the alphabet.
    var msg = ""
    try:
      discard identifierIndexKey("hex", "0xZZZZ")
    except ValueError as e:
      msg = e.msg
    check msg.len > 0
    check "'0xZZZZ'" in msg
    check "'hex'" in msg
    check "'z'" in msg                          # the offending character, folded
    check "0123456789abcdef" in msg             # the alphabet that admits digits
    check "parseHexInt" notin msg

  test "…and so does an identifier whose declared separator is missing":
    var msg = ""
    try:
      discard identifierIndexKey("bech32", "addrqqqqqq")
    except ValueError as e:
      msg = e.msg
    check msg.len > 0
    check "separator" in msg

  test "a base58 identifier declared as hex is refused, not silently keyed":
    # The realistic producer bug: a registry row declaring the wrong encoding
    # for a kind. Keying it anyway publishes an entry nothing can recompute.
    var msg = ""
    try:
      discard identifierIndexKey("hex", SolAddr)
    except ValueError as e:
      msg = e.msg
    check msg.len > 0
    check "registry row declares the wrong encoding" in msg

  test "`decimal` is deliberately not recognised from a bare string (§3's budget)":
    # A block number is answered by local inference at ZERO requests (§8).
    # Recognising it here would route it to the index and cost a fetch.
    check identifierEncodingsMatching("68231").len == 0
    check indexKeysOf("68231").len == 0
    check qsDecimal in shapesOf("68231")

  test "the shared file's shape rule and the hex reader agree about every 0x query":
    # `hexBodyOf` implements a measured extension of §2 that the data cannot
    # express (a bare hash above `BareHexFloor`, and a bare number refused). The
    # two must still agree wherever the user wrote the prefix.
    for body in ["ab", "abcd", repeat("ab", 20), repeat("ab", 32), "0"]:
      check identifierEncodingsMatching("0x" & body) == @["hex"]
      check hexBodyOf("0x" & body) == body

  test "a non-hex query is hash-like now and was NOT before — the window's basis":
    # The compatibility window rests on this: a client built before the widening
    # classified every non-hex string as `qsText`, so it never asked the index
    # about one, so the hex-only `/idx/hash/1/` was complete for every question
    # it could be asked. `qsEncodedId` is what changed.
    check qsEncodedId in shapesOf(SolAddr)
    check qsEncodedId in shapesOf(AdaAddr)
    check isHashLike(shapesOf(SolAddr))
    # …and the hex shapes are untouched, which is the other half.
    check shapesOf(HexHash) == {qsHash32}
    check qsEncodedId notin shapesOf(HexHash)
    check qsText in shapesOf("a plain name")

  test "FORMAT 1's encode path refuses too, and does not reach parseHexInt":
    # THE GAP THE MUTANT FOUND, PINNED SO IT CANNOT COME BACK. For one revision
    # only the format-2 arm keyed through `identifierIndexKey`; format 1 called
    # the hex parser directly. So `just byte-identity-mutant` still killed the
    # demo producer with `invalid hex integer: 0x` — the exact crash this whole
    # step replaced, surviving on the one path left in FRONT of the parser.
    #
    # The shard below is all-`hex` by declaration, so it takes the format-1 arm,
    # and its identifier is not writable in hex.
    var msg = ""
    try:
      discard encodeHashShard(@[HashEntry(encoding: "hex", identifier: "0xQQQQ",
                                          chain: "c", kind: hkTx)], 2)
    except ValueError as e:
      msg = e.msg
    check msg.len > 0
    check "invalid hex integer" notin msg       # NOT the parser's message
    check "identifier encoding 'hex'" in msg
    check "0123456789abcdef" in msg

  test "an SS58 identifier round-trips too — the third row the milestone names":
    # SS58 is base58 of a network prefix plus the account bytes, so its payload
    # rule is base58's and its shard is the leading slice of the whole string.
    # Named separately because the deliverable names all three, and because its
    # length band is the one that distinguishes it from a Solana address.
    const Ss58 = "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY"
    check Ss58.len == 48
    check identifierEncodingsMatching(Ss58) == @["ss58"]
    check hashPrefix("ss58", Ss58, 2) == "5G"      # case PRESERVED, not folded
    let bytes = encodeHashShard(@[HashEntry(encoding: "ss58", identifier: Ss58,
                                            chain: "polkadot", kind: hkAddress)], 2)
    let dec = decodeHashShard(bytes)
    check dec.err.len == 0
    check dec.entries[0].identifier == Ss58
    check dec.entries[0].encoding == "ss58"
    check lookupHash(bytes, "ss58", Ss58).len == 1
    # …and the client reaches the same shard from the query alone. ONE probe,
    # because a 48-character SS58 account is not admissible under any other
    # path-safe row — which is checked rather than assumed, since the whole
    # point of §5.6 is that some queries are admissible under two.
    let probes = indexProbesOf(Ss58)
    check probes.len == 1
    check hashPrefix(probes[0].encoding, probes[0].identifier, 2) == "5G"

  test "an identifier kind code maps to the kind a registry row declares":
    check identifierKindOf(hkTx) == KindTransaction
    check identifierKindOf(hkBlock) == KindBlock
    check identifierKindOf(hkAddress) == KindAddress
    check identifierKindOf(0) == ""
