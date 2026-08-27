## The Demo Data Generator (M5c).
##
## A fake chain-extractor and trace-gen that emits the *exact* static-site tree and
## trace manifests the real pipeline emits, so the front end, publishing and the
## visual-design campaign can be built and reviewed BEFORE real Aztec ingestion
## (M6) or real replay (M10) exist. It satisfies the M5b contract; the real
## producer satisfies the same one; the two are interchangeable behind the seam.
##
## The demo data is deliberately **Aztec-shaped**, so the hardest case is exercised
## from the first render: a transaction's private part is structurally unobservable
## and carries `availability: absent` with a reason, while its public part carries
## a trace (Static-Site-Architecture.md §2.3, §2.3a).
##
## Determinism (M5c): output is a pure function of the seed. No timestamps, fixed
## field order, and the trace container bytes are copied verbatim from a fixture,
## so two runs at the same seed produce a byte-identical tree.
##
## TRACE STAND-IN: `nargo trace` on `noir_space_ship` was NOT available in this
## environment (`nargo` is not installed), so the public executions reuse
## `fixtures/trace/minimal_trace.ct` as a clearly-labelled stand-in `.ct`. The
## manifest's `container.bytes`/`hash` describe those real bytes, so the artifact
## still validates. Swapping in a real spaceship `.ct` is a one-line change in
## `traceFixturePath` plus per-execution `recorder`/`execution` metadata.

import std/[json, os, strutils, sha1]
import ../contract/[model, version, ids]

type
  DemoConfig* = object
    outDir*: string
    seed*: string
    traceFixturePath*: string

proc synthHash(seed, kind: string, n: int): string =
  ## Deterministic 32-byte (0x + 40 hex) synthetic hash.
  "0x" & toLowerAscii($secureHash(seed & "|" & kind & "|" & $n))[0 .. 39]

proc synthAddr(seed, kind: string, n: int): string =
  ## Deterministic 20-byte (0x + 40 hex) synthetic address.
  "0x" & toLowerAscii($secureHash(seed & "|addr|" & kind & "|" & $n))[0 .. 39]

proc writeJson(cfg: DemoConfig, rel: string, node: JsonNode) =
  let p = cfg.outDir / rel
  createDir parentDir(p)
  # `pretty` with a trailing newline; stable field order => byte-identical output.
  writeFile(p, node.pretty & "\n")

# The Aztec recorder pin, as it would appear in the chain registry. The real
# values come from M5a; these are deterministic stand-ins.
const
  chain = "aztec"
  recorderId = "aztec-avm"
  recorderVersion = "0.0.0-demo"
  traceSchema = "ctfs/v4"
  profileName = "default"
  gen = "1"
  tsv = "1"

proc recorderRef(): RecorderRef =
  RecorderRef(id: recorderId, build: recorderBuildHash(recorderId, recorderVersion),
              version: recorderVersion)

proc profileRef(): ProfileRef =
  ProfileRef(name: profileName, hash: profileHash(profileName))

proc writeRegistry(cfg: DemoConfig) =
  let reg = %*{
    "version": ContractVersion,
    "chains": {
      chain: {
        "recorder": {"id": recorderId, "build": recorderBuildHash(recorderId, recorderVersion),
                     "version": recorderVersion},
        "profile": {"name": profileName, "hash": profileHash(profileName)},
        "traceSchema": traceSchema
      }
    }
  }
  cfg.writeJson("registry" / "chains.v" & $ContractVersion & ".json", reg)

proc writeArtifact(cfg: DemoConfig, txHash, execInputId: string,
                   vs: ValidationStatus, strength: int, oracle: string) =
  ## Emit `/t/{shard}/{shard}/{tid}/` — manifest.json + trace.ct — for one
  ## published execution. `traceArtifactId` is DERIVED (Trace-Artifacts §2.1), so
  ## the URL is exactly what the client (and the validator) compute independently.
  let r = recorderRef()
  let p = profileRef()
  let tid = deriveTraceArtifactId(execInputId, r.id, r.build, p.hash, traceSchema)
  let sh = traceShards(tid)
  let dir = "t" / sh.a / sh.b / tid
  let bytes = readFile(cfg.traceFixturePath)
  createDir(cfg.outDir / dir)
  writeFile(cfg.outDir / dir / "trace.ct", bytes)  # raw container bytes (stand-in)
  let manifest = TraceManifest(
    schema: ContractVersion,
    traceArtifactId: tid,
    executionInputId: execInputId,
    chain: chain,
    tx: txHash,
    recorder: r,
    profile: p,
    sourceBundles: newJObject(),
    container: ContainerRef(file: "trace.ct", bytes: bytes.len, blockSize: 4096,
                            hash: contentHashSha1(bytes)),
    execution: ExecutionSummary(steps: 11, frames: 1, truncated: false,
                                sourceLevel: true, languages: @["noir"]),
    validation: ValidationSummary(status: vs, strength: strength),
    validationOracle: oracle,
    prestateStrategy: "self-contained-circuit")
  cfg.writeJson(dir / "manifest.json", manifest.toJson)

type DemoTx = object
  hash: string
  height: int
  index: int
  facts: TransactionFacts
  txstate: JsonNode
  overlay: TraceSelection
  artifacts: seq[tuple[selector, execInputId: string, vs: ValidationStatus,
                       strength: int, oracle: string, reconstructed: bool]]

proc mkPublicFacts(seed, txHash, blockHash: string, height, index: int;
                   contractAddr: string): TransactionFacts =
  TransactionFacts(
    chain: chain,
    id: TxId(kind: tikHash, hash: txHash),
    order: TxOrder(kind: tokBlockIndex, obBlock: blockHash, obHeight: height,
                   obIndex: index),
    outcome: Outcome(overall: ooSucceeded, parts: @[]),
    roles: @[Role(role: "feePayer", address: synthAddr(seed, "feepayer", index))],
    cost: @[Cost(name: "mana", used: "42000", limit: "100000", price: "1",
                 unit: "mana", token: "FeeJuice", refundable: false)],
    payloadRaw: "0x", payloadSelector: "0x1a2b3c4d", payloadTarget: contractAddr,
    logs: @[],
    codeEdges: @[CodeEdge(address: contractAddr,
                          codeHash: synthHash(seed, "code", index),
                          boundAt: blockHash)],
    executions: @[Execution(selector: "public",
                            executionInputId: demoExecutionInputId(chain, txHash, "public"))],
    native: %*{"aztec": {"kind": "public-avm-call", "contract": contractAddr}})

proc txstateJson(canonical: bool, finality: string): JsonNode =
  %*{"chain": chain, "canonical": canonical, "finality": finality}

proc build(cfg: DemoConfig): seq[DemoTx] =
  let seed = cfg.seed
  # Blocks 100, 101, 102.
  let b100 = synthHash(seed, "block", 100)
  let b101 = synthHash(seed, "block", 101)
  let b102 = synthHash(seed, "block", 102)

  # --- Block 100 ---
  # txA: a plain public AVM call — single execution, trace ready, verdict match.
  block:
    let h = synthHash(seed, "tx", 0)
    let c = synthAddr(seed, "contract", 0)
    var facts = mkPublicFacts(seed, h, b100, 100, 0, c)
    var ov = TraceSelection(chain: chain, tx: h, hasSingle: true,
      singleTrace: ExecTrace(availability: taReady, bytes: 36864, hasValidation: true,
        validation: ValidationSummary(status: vsMatch, strength: 2)))
    result.add DemoTx(hash: h, height: 100, index: 0, facts: facts,
      txstate: txstateJson(true, "finalized"), overlay: ov,
      artifacts: @[(selector: "public",
        execInputId: demoExecutionInputId(chain, h, "public"),
        vs: vsMatch, strength: 2, oracle: "avm-receipt-compare", reconstructed: false)])

  # --- Block 101 ---
  # txB: the Aztec private/public split — the hardest case, from the first render.
  # The PRIVATE part is structurally unobservable => availability: absent, with a
  # reason, never a failed fetch (§2.3a). The PUBLIC part carries a trace.
  block:
    let h = synthHash(seed, "tx", 1)
    let c = synthAddr(seed, "contract", 1)
    let privId = demoExecutionInputId(chain, h, "private")
    let pubId = demoExecutionInputId(chain, h, "public")
    var facts = TransactionFacts(
      chain: chain,
      id: TxId(kind: tikHash, hash: h),
      order: TxOrder(kind: tokBlockIndex, obBlock: b101, obHeight: 101, obIndex: 0),
      outcome: Outcome(overall: ooPartial,
        reason: "private-part-succeeded-public-part-succeeded",
        parts: @[%*{"unit": "private", "outcome": "succeeded"},
                 %*{"unit": "public", "outcome": "succeeded"}]),
      roles: @[Role(role: "feePayer", address: synthAddr(seed, "feepayer", 1))],
      cost: @[Cost(name: "mana", used: "88000", limit: "200000", price: "1",
                   unit: "mana", token: "FeeJuice", refundable: false)],
      payloadRaw: "0x", payloadSelector: "0x", payloadTarget: c, logs: @[],
      codeEdges: @[CodeEdge(address: c, codeHash: synthHash(seed, "code", 1), boundAt: b101)],
      executions: @[
        Execution(selector: "private", executionInputId: privId),
        Execution(selector: "public", executionInputId: pubId)],
      native: %*{"aztec": {"kind": "private+public", "contract": c,
                           "privateFunctions": ["transfer"], "publicCall": "settle"}})
    var ov = TraceSelection(chain: chain, tx: h, executions: @[
      ExecTrace(selector: "private", availability: taAbsent,
        reason: "aztec private function executed client-side; only proofs, " &
                "nullifiers and commitments are published — no call structure to trace"),
      ExecTrace(selector: "public", availability: taReady, bytes: 36864,
        hasValidation: true, validation: ValidationSummary(status: vsMatch, strength: 2))])
    result.add DemoTx(hash: h, height: 101, index: 0, facts: facts,
      txstate: txstateJson(true, "safe"), overlay: ov,
      artifacts: @[(selector: "public", execInputId: pubId, vs: vsMatch,
        strength: 2, oracle: "avm-receipt-compare", reconstructed: false)])

  # txC: a public call whose recorder verdict DIVERGED — the trace still exists and
  # remains inspectable, but the overlay is `divergent` (§ Failure Modes; §6).
  block:
    let h = synthHash(seed, "tx", 2)
    let c = synthAddr(seed, "contract", 2)
    var facts = mkPublicFacts(seed, h, b101, 101, 1, c)
    var ov = TraceSelection(chain: chain, tx: h, hasSingle: true,
      singleTrace: ExecTrace(availability: taDivergent, bytes: 36864, hasValidation: true,
        validation: ValidationSummary(status: vsDivergent, strength: 0)))
    result.add DemoTx(hash: h, height: 101, index: 1, facts: facts,
      txstate: txstateJson(true, "safe"), overlay: ov,
      artifacts: @[(selector: "public",
        execInputId: demoExecutionInputId(chain, h, "public"),
        vs: vsDivergent, strength: 0, oracle: "avm-receipt-compare", reconstructed: false)])

  # --- Block 102 ---
  # txD: a public call whose trace is not published yet — availability onDemand.
  # No `/t/` artifact exists; the client would compute the URL and offer generation.
  block:
    let h = synthHash(seed, "tx", 3)
    let c = synthAddr(seed, "contract", 3)
    var facts = mkPublicFacts(seed, h, b102, 102, 0, c)
    var ov = TraceSelection(chain: chain, tx: h, hasSingle: true,
      singleTrace: ExecTrace(availability: taOnDemand))
    result.add DemoTx(hash: h, height: 102, index: 0, facts: facts,
      txstate: txstateJson(true, "pending"), overlay: ov, artifacts: @[])

  # txE: a heuristically-reconstructed trace, verdict unchecked — exercises the
  # `reconstructed` flag (§2.3a) and the `unchecked` verdict for M11.
  block:
    let h = synthHash(seed, "tx", 4)
    let c = synthAddr(seed, "contract", 4)
    var facts = mkPublicFacts(seed, h, b102, 102, 1, c)
    var ov = TraceSelection(chain: chain, tx: h, hasSingle: true,
      singleTrace: ExecTrace(availability: taReady, bytes: 36864, reconstructed: true,
        hasValidation: true, validation: ValidationSummary(status: vsUnchecked, strength: 0)))
    result.add DemoTx(hash: h, height: 102, index: 1, facts: facts,
      txstate: txstateJson(true, "pending"), overlay: ov,
      artifacts: @[(selector: "public",
        execInputId: demoExecutionInputId(chain, h, "public"),
        vs: vsUnchecked, strength: 0, oracle: "none", reconstructed: true)])

proc generate*(cfg: DemoConfig): int =
  ## Emit the full demo tree. Returns the number of top-level objects written
  ## (for the CLI's summary line).
  let seed = cfg.seed
  createDir cfg.outDir
  cfg.writeRegistry()

  let txs = build(cfg)

  # Group transactions by block.
  var blocks: seq[tuple[hash: string, height: int, parent: string, txs: seq[string]]]
  for height in [100, 101, 102]:
    let bh = synthHash(seed, "block", height)
    let parent = if height == 100: synthHash(seed, "block", 99)
                 else: synthHash(seed, "block", height - 1)
    var bt: seq[string]
    for t in txs:
      if t.height == height: bt.add t.hash
    blocks.add (bh, height, parent, bt)

  # Block details (content-addressed) + tx facts + txstate + overlays + artifacts.
  var addrSegs: seq[tuple[address, seg: string, fromB, toB: int, txs: seq[string]]]
  for b in blocks:
    let bd = BlockDetail(chain: chain, hash: b.hash, height: b.height,
                         parentHash: b.parent, transactions: b.txs)
    cfg.writeJson("d" / chain / "block" / b.hash & ".json", bd.toJson)
  for t in txs:
    let sh = hexShard(t.hash)
    cfg.writeJson("d" / chain / "tx" / sh / t.hash & ".json", t.facts.toJson)
    var st = t.txstate
    st["tx"] = %t.hash
    cfg.writeJson("d" / chain / "g" / gen / "txstate" / sh / t.hash & ".json", st)
    cfg.writeJson("d" / chain / "ts" / tsv / sh / t.hash & ".json", t.overlay.toJson)
    for a in t.artifacts:
      cfg.writeArtifact(t.hash, a.execInputId, a.vs, a.strength, a.oracle)

  # One demo address with a single block-range segment referencing the fee payers.
  let demoAddr = synthAddr(seed, "feepayer", 0)
  block:
    var segTxs: seq[string]
    for t in txs: segTxs.add t.hash
    let seg = "100-102"
    cfg.writeJson("d" / chain / "seg" / hexShard(demoAddr) / demoAddr / seg & ".json",
      %*{"chain": chain, "address": demoAddr, "fromBlock": 100, "toBlock": 102,
         "transactions": segTxs})
    addrSegs.add (demoAddr, seg, 100, 102, segTxs)

  # Generation-scoped derived maps.
  let heightRel = "d" / chain / "g" / gen / "height" / "0.json"
  var heights = newJObject()
  for b in blocks: heights[$b.height] = %b.hash
  cfg.writeJson(heightRel, %*{"chain": chain, "epoch": 0, "heights": heights})

  let blocksRel = "d" / chain / "g" / gen / "blocks" / "0.json"
  var blockHashes: seq[string]
  for b in blocks: blockHashes.add b.hash
  cfg.writeJson(blocksRel, %*{"chain": chain, "epoch": 0, "blocks": blockHashes})

  var addrRels: seq[string]
  for a in addrSegs:
    let rel = "d" / chain / "g" / gen / "addr" / hexShard(a.address) / a.address & ".json"
    cfg.writeJson(rel, %*{"chain": chain, "address": a.address,
      "segments": [("d" / chain / "seg" / hexShard(a.address) / a.address / a.seg & ".json")]})
    addrRels.add rel

  var txstateRels: seq[string]
  for t in txs:
    txstateRels.add "d" / chain / "g" / gen / "txstate" / hexShard(t.hash) / t.hash & ".json"

  let summaryRel = "d" / chain / "g" / gen / "summary.json"
  cfg.writeJson(summaryRel, %*{"chain": chain, "generation": gen,
    "counters": {"blocks": blocks.len, "transactions": txs.len},
    "coverageMode": "selective", "stale": false})

  # The sealed, immutable generation root — every derived map is reachable here.
  let root = GenerationRoot(contractVersion: ContractVersion, chain: chain,
    generation: gen, traceSelectionVersion: tsv, summaryPath: summaryRel,
    heightPaths: @[heightRel], blockIndexPaths: @[blocksRel], addrPaths: addrRels,
    txstatePaths: txstateRels)
  cfg.writeJson("d" / chain / "g" / gen / "root.json", root.toJson)

  # The one mutable object per chain: the pointer.
  cfg.writeJson("d" / chain / "current.json", %*{
    "chain": chain, "generation": gen, "traceSelectionVersion": tsv,
    "head": {"height": 102, "hash": synthHash(seed, "block", 102)},
    "finalized": {"height": 100, "hash": synthHash(seed, "block", 100)}})

  txs.len
