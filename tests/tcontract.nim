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
import ../src/blocktracer/contract/[model, version, ids, searchidx, entrypage]
import ../src/blocktracer/validator
import ../src/blocktracer/demo/generator

proc synthHash(seed, kind: string, n: int): string =
  "0x" & toLowerAscii($secureHash(seed & "|" & kind & "|" & $n))[0 .. 39]
proc synthAddr(seed, kind: string, n: int): string =
  "0x" & toLowerAscii($secureHash(seed & "|addr|" & kind & "|" & $n))[0 .. 39]

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

suite "M5c — /idx search indices and HTML entry pages":
  let outDir = tmp("idx")
  let seed = "idx-seed"
  discard generate(DemoConfig(outDir: outDir, seed: seed, traceFixturePath: fixture))

  test "the render + idx layers are emitted and declared in the generation root":
    let root = parseFile(outDir / "d" / "aztec" / "g" / "1" / "root.json")
    check "idx" in root and "render" in root
    check fileExists(outDir / "index.html")
    check fileExists(outDir / "idx" / "aztec" / "names" / "meta.json")
    # at least one hash shard and one name shard exist
    var hashShards, nameShards = 0
    for p in walkDirRec(outDir / "idx" / "hash"):
      if p.endsWith(".bin"): inc hashShards
    for p in walkDirRec(outDir / "idx" / "aztec" / "names"):
      if p.endsWith(".bin"): inc nameShards
    check hashShards > 0 and nameShards == 2

  test "the tx entry page inlines its data as a materialised view of /d":
    let h = synthHash(seed, "tx", 0)
    let page = outDir / "aztec" / "tx" / h / "index.html"
    check fileExists(page)
    let html = readFile(page)
    check "content=\"noindex,follow\"" in html          # N1 addressable-only
    check (siteBase & "/aztec/tx/" & h) in html          # canonical
    let (payload, found) = extractInlineData(html)
    check found
    let data = parseJson(payload)
    check data["kind"].getStr == "tx"
    check data["txHash"].getStr == h
    let onDisk = parseFile(outDir / "d" / "aztec" / "tx" / hexShard(h) / h & ".json")
    check data["facts"] == onDisk                        # a view, not a second truth

  test "the home page is the one index,follow page (§5 class I0)":
    let html = readFile(outDir / "index.html")
    check "content=\"index,follow\"" in html
    check (siteBase & "/\">") in html or (siteBase & "/\"") in html

  test "the hash index resolves every entity (tx, block, address)":
    let root = parseFile(outDir / "d" / "aztec" / "g" / "1" / "root.json")
    let hi = root["idx"]["hash"]
    let ver = hi["version"].getStr
    let pfx = hi["prefixLen"].getInt
    proc resolves(hexHash: string, kind: int): bool =
      let shard = outDir / "idx" / "hash" / ver / hashPrefix(hexHash, pfx) & ".bin"
      if not fileExists(shard): return false
      for e in lookupHash(readFile(shard), hexHash):
        if e.chain == "aztec" and e.kind == kind: return true
      false
    check resolves(synthHash(seed, "tx", 0), hkTx)
    check resolves(synthHash(seed, "block", 100), hkBlock)
    check resolves(synthAddr(seed, "feepayer", 0), hkAddress)

  test "name shards decode, place terms correctly, and carry provenance (§6.2)":
    let meta = parseFile(outDir / "idx" / "aztec" / "names" / "meta.json")
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
    discard generate(DemoConfig(outDir: result, seed: "bite", traceFixturePath: fixture))

  test "removing the home page fails conformance":
    let d = freshIdx("bite-home")
    removeFile(d / "index.html")
    check validateTree(d).len > 0

  test "flipping a tx entry page to index,follow fails":
    let d = freshIdx("bite-robots")
    let h = synthHash("bite", "tx", 0)
    let page = d / "aztec" / "tx" / h / "index.html"
    writeFile(page, readFile(page).replace("noindex,follow", "index,follow"))
    check validateTree(d).len > 0

  test "tampering with a tx entry page's inlined data fails (view drift)":
    let d = freshIdx("bite-view")
    let h = synthHash("bite", "tx", 0)
    let page = d / "aztec" / "tx" / h / "index.html"
    # Corrupt the inlined outcome so the page disagrees with /d — the materialised
    # view is no longer faithful.
    writeFile(page, readFile(page).replace("\"succeeded\"", "\"reverted\""))
    check validateTree(d).len > 0

  test "deleting a declared hash-index shard fails":
    let d = freshIdx("bite-hashdel")
    let h = synthHash("bite", "tx", 0)
    removeFile(d / "idx" / "hash" / "1" / hashPrefix(h, 2) & ".bin")
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
    writeFile(d / "idx" / "aztec" / "names" / "0.bin", "not a name shard")
    check validateTree(d).len > 0

  test "dropping shardBits from names meta.json fails":
    let d = freshIdx("bite-meta")
    let mp = d / "idx" / "aztec" / "names" / "meta.json"
    var m = parseFile(mp)
    m.delete("shardBits")
    writeFile(mp, m.pretty & "\n")
    check validateTree(d).len > 0

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
