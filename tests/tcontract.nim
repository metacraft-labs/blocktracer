## Conformance test suite for the M5b data contract and the M5c demo generator.
##
## Covers the milestone verification points:
##   - M5c test_demo_tree_satisfies_the_contract
##   - M5c test_demo_aztec_private_half_is_absent_not_missing
##   - M5c e2e_demo_tree_is_walkable_from_current_json
##   - M5c test_demo_output_is_deterministic
##   - M5b test_contract_conformance_fixture_validates (negative cases)
##   - M5b test_both_producers_satisfy_one_contract (demo + a hand-built EVM tree)

import std/[unittest, os, json, strutils, algorithm, sha1]
import ../src/blocktracer/contract/[model, version, ids]
import ../src/blocktracer/validator
import ../src/blocktracer/demo/generator

const fixture = currentSourcePath().parentDir.parentDir / "fixtures" / "trace" / "minimal_trace.ct"

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
  let nTx = generate(DemoConfig(outDir: outDir, seed: seed, traceFixturePath: fixture))

  test "the generator emits five transactions":
    check nTx == 5

  test "the demo tree validates against the contract (walkable, no dangles)":
    let errs = validateTree(outDir)
    if errs.len > 0:
      for e in errs: echo "  ERR ", e
    check errs.len == 0

  test "the Aztec private half is absent-with-reason, not a failed fetch":
    # txB is the private+public split at block 101, index 0.
    let h = "0x" & toLowerAscii($secureHash(seed & "|tx|1"))[0 .. 39]
    let sh = hexShard(h)
    let ov = parseFile(outDir / "d" / "aztec" / "ts" / "1" / sh / h & ".json")
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
    let facts = parseFile(outDir / "d" / "aztec" / "tx" / hexShard(h) / h & ".json")
    for forbidden in ["trace", "validation", "finality", "canonical"]:
      check forbidden notin facts

  test "a divergent verdict and an onDemand tx are both represented":
    # txC divergent (block 101 idx1), txD onDemand (block 102 idx0)
    let hc = "0x" & toLowerAscii($secureHash(seed & "|tx|2"))[0 .. 39]
    let hd = "0x" & toLowerAscii($secureHash(seed & "|tx|3"))[0 .. 39]
    let ovc = parseFile(outDir / "d" / "aztec" / "ts" / "1" / hexShard(hc) / hc & ".json")
    let ovd = parseFile(outDir / "d" / "aztec" / "ts" / "1" / hexShard(hd) / hd & ".json")
    check ovc["trace"]["availability"].getStr == "divergent"
    check ovd["trace"]["availability"].getStr == "onDemand"

suite "M5c — determinism":
  test "the same seed produces a byte-identical tree, containers included":
    let a = tmp("det-a")
    let b = tmp("det-b")
    discard generate(DemoConfig(outDir: a, seed: "same", traceFixturePath: fixture))
    discard generate(DemoConfig(outDir: b, seed: "same", traceFixturePath: fixture))
    let fa = listFiles(a)
    check fa == listFiles(b)
    for rel in fa:
      check readFile(a / rel) == readFile(b / rel)

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
    writeJsonNl(d / "d" / chain / "tx" / hexShard(tx) / tx & ".json", facts.toJson)
    writeJsonNl(d / "d" / chain / "block" / blk & ".json",
      BlockDetail(chain: chain, hash: blk, height: 19_000_000,
        parentHash: "0x00", transactions: @[tx]).toJson)
    writeJsonNl(d / "d" / chain / "g" / "1" / "txstate" / hexShard(tx) / tx & ".json",
      %*{"chain": chain, "tx": tx, "canonical": true, "finality": "finalized"})
    let ov = TraceSelection(chain: chain, tx: tx, hasSingle: true,
      singleTrace: ExecTrace(availability: taReady, bytes: 36864, hasValidation: true,
        validation: ValidationSummary(status: vsMatch, strength: 2)))
    writeJsonNl(d / "d" / chain / "ts" / "1" / hexShard(tx) / tx & ".json", ov.toJson)
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
    let txstateRel = "d" / chain / "g" / "1" / "txstate" / hexShard(tx) / tx & ".json"
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

suite "M5b — malformed trees fail conformance":
  proc freshDemo(name: string): string =
    result = tmp(name)
    discard generate(DemoConfig(outDir: result, seed: "neg", traceFixturePath: fixture))

  proc firstTxFactsPath(dir: string): string =
    for p in walkDirRec(dir / "d" / "aztec" / "tx"):
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
    let ovp = d / "d" / "aztec" / "ts" / "1" / hexShard(h) / h & ".json"
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
    let rp = d / "d" / "aztec" / "g" / "1" / "root.json"
    var n = parseFile(rp)
    n["contractVersion"] = %(ContractVersion + 99)
    writeFile(rp, n.pretty & "\n")
    check validateTree(d).len > 0

suite "contract version wiring":
  test "the artifact-schema constant is in lock-step with version.nim":
    check ArtifactSchemaVersion == 1
    check ContractVersion == 1
