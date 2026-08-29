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
## THE TRACE IS REAL. Every published (`ready` / `divergent`) execution carries
## `fixtures/trace/noir_space_ship/zk_shields.ct` — a genuine CTFS container
## recorded by `nargo trace` from `codetracer/test-programs/noir_space_ship`
## (Noir tracer fork `codetracer` @ `906af2f42d`, nargo 1.0.0-beta.26). 1315 steps,
## 80 calls, max call depth 3, all 22 variables observed, 70 stdout events. See
## `fixtures/trace/noir_space_ship/README.md` for provenance and `ct-print` output.
##
## The container is VENDORED rather than recorded at generation time on purpose:
## `nargo trace` is not byte-deterministic (it stamps a fresh UUIDv7 recording id
## into the `CTMD` block on every run), so shelling out to it would break the
## byte-identical-tree requirement. Checking the bytes in is what makes the demo
## tree a usable regression fixture.
##
## SOURCE IS REFERENCED, NOT EMBEDDED (Trace-Artifacts.md §2.5). The container
## interns path names and positions but carries no source text
## (`ct-print --full` reports `source_views: []`), so a viewer given only
## `trace.ct` can step and show variables but cannot show code. The generator
## therefore publishes the Noir sources as content-addressed bundles at
## `/src/{chain}/{codeHash}/{bundleHash}.json` with a `current.json` pointer
## (Source-Resolution.md §5), and each manifest's `sourceBundles` names the
## bundle it recommends. The bundle's `sources` keys are exactly the paths the
## container interns (`src/main.nr`, `src/shield.nr`), which is what lets a step's
## position resolve to a line of code.

import std/[json, os, strutils, sha1, algorithm, tables]
import ../contract/[model, version, ids, searchidx]
import ./entrypages

type
  DemoConfig* = object
    outDir*: string
    seed*: string
    traceFixturePath*: string
    traceSourcesDir*: string  ## directory holding the traced program's sources,
                              ## published as content-addressed source bundles
                              ## (Source-Resolution.md §5). Its layout under
                              ## `src/` must match the paths the container
                              ## interns, or a step resolves to no source line.
    generation*: string       ## generation label; "" => "1" (the M5c default).
    extraBlocks*: seq[int]     ## heights appended after 102, each carrying one new
                               ## public transaction. Empty => the byte-identical
                               ## M5c generation-1 tree. This is what lets the M8
                               ## publisher exercise a real incremental delta:
                               ## `extraBlocks = @[103]` at `generation = "2"`
                               ## regenerates the whole tree with block 103 added,
                               ## every generation-1 object staying byte-identical
                               ## (so key-existence skips it) and the pointer
                               ## flipping to the sealed generation 2.

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

proc writeText(cfg: DemoConfig, rel, body: string) =
  ## Write a rendered artifact (an HTML entry page) verbatim. `body` is already the
  ## complete file content, so output stays byte-identical across runs.
  let p = cfg.outDir / rel
  createDir parentDir(p)
  writeFile(p, body)

proc writeBinary(cfg: DemoConfig, rel, bytes: string) =
  ## Write a binary index shard (`.bin`) verbatim.
  let p = cfg.outDir / rel
  createDir parentDir(p)
  writeFile(p, bytes)

# The Aztec recorder pin, as it would appear in the chain registry. The real
# values come from M5a; these are deterministic stand-ins.
const
  chain = "aztec"
  recorderId = "aztec-avm"
  recorderVersion = "0.0.0-demo"
  traceSchema = "ctfs/v4"
  profileName = "default"
  tsv = "1"

  # --- The REAL execution summary of the packaged `noir_space_ship` trace ------
  # These are not invented numbers. They are what `ct-print --summary` reports for
  # `fixtures/trace/noir_space_ship/zk_shields.ct`, and `tcontract` asserts the
  # manifests still agree with the vendored container, so re-recording the fixture
  # without updating them fails the suite rather than silently publishing a lie.
  traceSteps = 1315         ## ct-print: steps
  traceFrames = 80          ## ct-print: calls — one frame per call entry
  traceLanguage = "noir"
  # Provenance of the vendored container, surfaced in the source bundle's
  # `compiler` block so a reader can tell which tracer produced the execution.
  nargoVersion = "1.0.0-beta.26"
  tracerCommit = "906af2f42d6b874cf0f5dde193accb1e39e1bcd3"
  # Search-index parameters (Search-And-Routing §5.3, §6). Version-addressed and
  # independent of the contract version; the depths are small for the demo's tiny
  # dataset and are recomputable for the real pipeline (documented D4/D5).
  nameIdxVersion = "1"  ## the curated name corpus does not grow with new blocks,
                        ## so its version is fixed; the hash index is versioned by
                        ## generation instead (see `generate`).
  hashPrefixLen = 2      ## hex chars of the hash that select a hash-index shard
  nameShardBits = 1      ## low bits of the term hash that select a name shard (2 shards)

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

proc readSourceFiles(dir: string): seq[tuple[path, content: string]] =
  ## Collect the traced program's sources keyed by the path the CONTAINER interns
  ## (`src/main.nr`, `src/shield.nr`), in sorted order so bundle bytes are stable
  ## across runs and across filesystems with different directory ordering.
  if dir.len == 0 or not dirExists(dir): return
  var rels: seq[string]
  for p in walkDirRec(dir, relative = true):
    rels.add p.replace('\\', '/')
  rels.sort()
  for r in rels:
    result.add (path: r, content: readFile(dir / r))

proc writeSourceBundle(cfg: DemoConfig, codeHash: string,
                       files: seq[tuple[path, content: string]]): string =
  ## Publish one content-addressed source bundle plus its `current.json` pointer
  ## (Source-Resolution.md §5) and return its `sourceBundleId`.
  ##
  ## This is what makes the trace *readable*: the CTFS container carries no source
  ## text (Trace-Artifacts.md §2.5), so without a bundle whose `sources` keys match
  ## the interned paths, every step resolves to a position in a file the viewer
  ## cannot display.
  var srcs = newJObject()
  for f in files:
    srcs[f.path] = %*{"content": f.content}
  let bundle = %*{
    "schema": ContractVersion,
    "codeHash": codeHash,
    "chain": chain,
    "match": "full",
    "provider": "demo-vendored",
    "language": traceLanguage,
    "compiler": {"name": "nargo", "version": nargoVersion,
                 "settings": {"tracerCommit": tracerCommit}},
    "sources": srcs,
    "debug": newJObject()}
  # `writeJson` emits exactly `pretty & "\n"`, so hashing that string content-
  # addresses the bytes actually published.
  let bundleId = contentHashSha1(bundle.pretty & "\n")
  # The filename must be the id with ONLY its algorithm tag stripped. A consumer
  # reaching the bundle through a manifest's `sourceBundles` has no pointer to
  # read, so it reconstructs this path from the id alone and may not assume any
  # further shortening (blocktracer_client/paths.nim `shortBundleHash`).
  # Truncating here would publish a bundle only the pointer route could find.
  let short = bundleId[bundleId.find(':') + 1 .. ^1]
  let dir = "src" / chain / codeHash
  let rel = dir / short & ".json"
  cfg.writeJson(rel, bundle)
  # Only `current.json` ever moves; bundle objects are immutable (§5).
  cfg.writeJson(dir / "current.json",
    %*{"chain": chain, "codeHash": codeHash, "sourceBundleId": bundleId,
       "bundle": rel})
  bundleId

proc writeArtifact(cfg: DemoConfig, txHash, execInputId: string,
                   vs: ValidationStatus, strength: int, oracle: string,
                   codeHash, sourceBundleId: string) =
  ## Emit `/t/{shard}/{shard}/{tid}/` — manifest.json + trace.ct — for one
  ## published execution. `traceArtifactId` is DERIVED (Trace-Artifacts §2.1), so
  ## the URL is exactly what the client (and the validator) compute independently.
  let r = recorderRef()
  let p = profileRef()
  let tid = deriveTraceArtifactId(execInputId, r.id, r.build, p.hash, traceSchema)
  let sh = traceShards(tid)
  let dir = "t" / sh.a / sh.b / tid
  # The real `noir_space_ship` container, copied verbatim. Copying rather than
  # regenerating is what keeps the tree byte-identical (see the module header).
  let bytes = readFile(cfg.traceFixturePath)
  createDir(cfg.outDir / dir)
  writeFile(cfg.outDir / dir / "trace.ct", bytes)
  var bundles = newJObject()
  if sourceBundleId.len > 0:
    bundles[codeHash] = %sourceBundleId
  let manifest = TraceManifest(
    schema: ContractVersion,
    traceArtifactId: tid,
    executionInputId: execInputId,
    chain: chain,
    tx: txHash,
    recorder: r,
    profile: p,
    sourceBundles: bundles,
    container: ContainerRef(file: "trace.ct", bytes: bytes.len, blockSize: 4096,
                            hash: contentHashSha1(bytes)),
    execution: ExecutionSummary(steps: traceSteps, frames: traceFrames,
                                truncated: false, sourceLevel: true,
                                languages: @[traceLanguage]),
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

proc contractCodeHash(seed: string, contractIdx: int): string =
  ## The code hash bound to demo contract `contractIdx`.
  ##
  ## Keyed by the CONTRACT, not by the transaction's position in its block.
  ## Static-Site-Architecture.md §2.1a makes source interpretation
  ## code-hash-addressed precisely so that one bundle serves every deployment of
  ## the same bytecode — a code hash keyed by `obIndex` broke that in both
  ## directions: two unrelated contracts at index 0 shared a bundle, and one
  ## contract called from two positions had two. It also made "an unverified
  ## contract" unreachable in the demo tree, because every hash that any
  ## transaction used was also a hash some *other* transaction had published a
  ## bundle for. Contract 3 — the on-demand transaction's target — is now
  ## genuinely unverified, which is §14's "No verified source" row as data.
  synthHash(seed, "code", contractIdx)

proc mkPublicFacts(seed, txHash, blockHash: string, height, index: int;
                   contractIdx: int): TransactionFacts =
  let contractAddr = synthAddr(seed, "contract", contractIdx)
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
                          codeHash: contractCodeHash(seed, contractIdx),
                          boundAt: blockHash)],
    executions: @[Execution(selector: "public",
                            executionInputId: demoExecutionInputId(chain, txHash, "public"))],
    native: %*{"aztec": {"kind": "public-avm-call", "contract": contractAddr}})

proc txstateJson(canonical: bool, finality: string): JsonNode =
  %*{"chain": chain, "canonical": canonical, "finality": finality}

proc build(cfg: DemoConfig): seq[DemoTx] =
  let seed = cfg.seed
  # The overlay advertises the container's size so the client can pick a fetch
  # strategy (whole-object vs range-filled) BEFORE fetching it. Read it from the
  # fixture rather than hardcoding: a re-recorded trace of a different size must
  # not leave the overlay advertising the old one. The validator cross-checks this
  # against the artifact's real file size.
  let tbytes = int(getFileSize(cfg.traceFixturePath))
  # Blocks 100, 101, 102.
  let b100 = synthHash(seed, "block", 100)
  let b101 = synthHash(seed, "block", 101)
  let b102 = synthHash(seed, "block", 102)

  # --- Block 100 ---
  # txA: a plain public AVM call — single execution, trace ready, verdict match.
  block:
    let h = synthHash(seed, "tx", 0)
    let c = synthAddr(seed, "contract", 0)
    var facts = mkPublicFacts(seed, h, b100, 100, 0, 0)
    var ov = TraceSelection(chain: chain, tx: h, hasSingle: true,
      singleTrace: ExecTrace(availability: taReady, bytes: tbytes, hasValidation: true,
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
      ExecTrace(selector: "public", availability: taReady, bytes: tbytes,
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
    var facts = mkPublicFacts(seed, h, b101, 101, 1, 2)
    var ov = TraceSelection(chain: chain, tx: h, hasSingle: true,
      singleTrace: ExecTrace(availability: taDivergent, bytes: tbytes, hasValidation: true,
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
    var facts = mkPublicFacts(seed, h, b102, 102, 0, 3)
    var ov = TraceSelection(chain: chain, tx: h, hasSingle: true,
      singleTrace: ExecTrace(availability: taOnDemand))
    result.add DemoTx(hash: h, height: 102, index: 0, facts: facts,
      txstate: txstateJson(true, "pending"), overlay: ov, artifacts: @[])

  # txE: a heuristically-reconstructed trace, verdict unchecked — exercises the
  # `reconstructed` flag (§2.3a) and the `unchecked` verdict for M11.
  block:
    let h = synthHash(seed, "tx", 4)
    let c = synthAddr(seed, "contract", 4)
    var facts = mkPublicFacts(seed, h, b102, 102, 1, 4)
    var ov = TraceSelection(chain: chain, tx: h, hasSingle: true,
      singleTrace: ExecTrace(availability: taReady, bytes: tbytes, reconstructed: true,
        hasValidation: true, validation: ValidationSummary(status: vsUnchecked, strength: 0)))
    result.add DemoTx(hash: h, height: 102, index: 1, facts: facts,
      txstate: txstateJson(true, "pending"), overlay: ov,
      artifacts: @[(selector: "public",
        execInputId: demoExecutionInputId(chain, h, "public"),
        vs: vsUnchecked, strength: 0, oracle: "none", reconstructed: true)])

  # --- Extra blocks (M8 incremental delta) ---
  # Each appended height carries one plain public AVM call with a ready trace — the
  # simplest new-block-arrives case. Their hashes derive from the height, so gen 1
  # (empty extraBlocks) is untouched and each new block is deterministic. `n` keys
  # the synthetic entities off the height so two extra blocks never collide.
  for eb in cfg.extraBlocks:
    let n = 100 + eb            # 100..102 are used above; eb>=103 => n>=203, distinct
    let h = synthHash(seed, "tx", n)
    let c = synthAddr(seed, "contract", n)
    let bh = synthHash(seed, "block", eb)
    var facts = mkPublicFacts(seed, h, bh, eb, 0, n)
    var ov = TraceSelection(chain: chain, tx: h, hasSingle: true,
      singleTrace: ExecTrace(availability: taReady, bytes: tbytes, hasValidation: true,
        validation: ValidationSummary(status: vsMatch, strength: 2)))
    result.add DemoTx(hash: h, height: eb, index: 0, facts: facts,
      txstate: txstateJson(true, "finalized"), overlay: ov,
      artifacts: @[(selector: "public",
        execInputId: demoExecutionInputId(chain, h, "public"),
        vs: vsMatch, strength: 2, oracle: "avm-receipt-compare", reconstructed: false)])

proc generate*(cfg: DemoConfig): int =
  ## Emit the full demo tree. Returns the number of top-level objects written
  ## (for the CLI's summary line).
  let seed = cfg.seed
  # The generation label and the generation-versioned hash index. Both default to
  # "1" (the M5c tree) and move together when a new generation is emitted, so a
  # sealed generation's `/idx/hash/{gen}/**` is immutable at a distinct path rather
  # than an in-place rewrite (Publishing-And-Caching §4: version in the path).
  let gen = if cfg.generation.len > 0: cfg.generation else: "1"
  let hashIdxVersion = gen
  let heightList = @[100, 101, 102] & cfg.extraBlocks
  createDir cfg.outDir
  cfg.writeRegistry()

  let txs = build(cfg)

  # The traced program's sources, published once per code hash as a content-
  # addressed bundle (Source-Resolution.md §5). Read once: the bundle body is a
  # pure function of these bytes plus the code hash, so the tree stays
  # byte-identical at a given seed.
  let srcFiles = readSourceFiles(cfg.traceSourcesDir)

  # Group transactions by block.
  var blocks: seq[tuple[hash: string, height: int, parent: string, txs: seq[string]]]
  for height in heightList:
    let bh = synthHash(seed, "block", height)
    let parent = if height == 100: synthHash(seed, "block", 99)
                 else: synthHash(seed, "block", height - 1)
    var bt: seq[string]
    for t in txs:
      if t.height == height: bt.add t.hash
    blocks.add (bh, height, parent, bt)

  # Hash-index entries (§5): every hash-addressable entity that has an entry page —
  # blocks, transactions and the demo address — so the global hash → (chain, kind)
  # map resolves each of them without knowing the chain up front.
  var hashEntries: seq[HashEntry]

  # Block details (content-addressed) + tx facts + txstate + overlays + artifacts.
  # Each block/transaction also gets its pre-rendered HTML entry page (§2, §4.2).
  for b in blocks:
    let bd = BlockDetail(chain: chain, hash: b.hash, height: b.height,
                         parentHash: b.parent, transactions: b.txs)
    let bdJson = bd.toJson
    cfg.writeJson("d" / chain / "block" / b.hash & ".json", bdJson)
    cfg.writeText(chain / "block" / b.hash / "index.html",
                  renderBlockPage(chain, b.hash, bdJson))
    hashEntries.add HashEntry(hexHash: b.hash, chain: chain, kind: hkBlock)
  for t in txs:
    let sh = hexShard(t.hash)
    let factsJson = t.facts.toJson
    cfg.writeJson("d" / chain / "tx" / sh / t.hash & ".json", factsJson)
    var st = t.txstate
    st["tx"] = %t.hash
    cfg.writeJson("d" / chain / "g" / gen / "txstate" / sh / t.hash & ".json", st)
    let ovJson = t.overlay.toJson
    cfg.writeJson("d" / chain / "ts" / tsv / sh / t.hash & ".json", ovJson)
    if t.artifacts.len > 0:
      # Publish the source bundle for the code this transaction executed, then
      # name it from every one of that transaction's manifests. The bundle is
      # keyed by code hash, so a contract's source is stored once however many
      # executions reference it (Trace-Artifacts.md §2.5).
      let codeHash = if t.facts.codeEdges.len > 0: t.facts.codeEdges[0].codeHash
                     else: ""
      var bundleId = ""
      if codeHash.len > 0 and srcFiles.len > 0:
        bundleId = cfg.writeSourceBundle(codeHash, srcFiles)
      for a in t.artifacts:
        cfg.writeArtifact(t.hash, a.execInputId, a.vs, a.strength, a.oracle,
                          codeHash, bundleId)
    cfg.writeText(chain / "tx" / t.hash / "index.html",
                  renderTxPage(chain, t.hash, factsJson, st, ovJson))
    hashEntries.add HashEntry(hexHash: t.hash, chain: chain, kind: hkTx)

  # ---- Address history: every participating address, segmented by block ------
  #
  # Static-Site-Architecture.md §2.2. An address's history is stored as
  # IMMUTABLE segments keyed by block range, never as ordinal pages, and the
  # generation's `addr` object lists the segments that exist "and their display
  # order".
  #
  # Two things changed here for M9, and both were needed before the address page
  # (§9) and the contract-source page (§10) could be anything but a stub:
  #
  #   * **Every participating address is indexed**, not one hand-picked fee
  #     payer. An address participates if it holds a role, is the payload
  #     target, or carries a code edge. Before this, five of the tree's seven
  #     addresses appeared in the transactions table as text that linked
  #     nowhere, and no contract had a history at all — so `/{chain}/address/
  #     {contract}/code` had no subject in the published tree.
  #   * **One segment per block**, rather than one segment spanning the whole
  #     chain. A single segment makes paging unobservable: the client fetches
  #     the list, fetches the one segment, and there is nothing to page. Per
  #     block is the finest honest granularity (a segment's identity is a fact
  #     about the chain, and compaction merges them later — §2.2), and it is
  #     what makes "pages from first to last with constant per-page cost" a
  #     property the demo tree can actually exercise.
  #
  # Display order is newest block first, which is the order the client walks.
  let demoAddr = synthAddr(seed, "feepayer", 0)
  var addrOrder: seq[string]
  var addrTxsByHeight = initTable[string, OrderedTable[int, seq[string]]]()
  proc participate(address: string, height: int, txHash: string) =
    if address.len == 0: return
    if address notin addrTxsByHeight:
      addrTxsByHeight[address] = initOrderedTable[int, seq[string]]()
      addrOrder.add address
    var byHeight = addrTxsByHeight[address]
    if height notin byHeight: byHeight[height] = @[]
    if txHash notin byHeight[height]: byHeight[height].add txHash
    addrTxsByHeight[address] = byHeight
  for t in txs:
    for r in t.facts.roles: participate(r.address, t.height, t.hash)
    participate(t.facts.payloadTarget, t.height, t.hash)
    for e in t.facts.codeEdges: participate(e.address, t.height, t.hash)
  addrOrder.sort()

  # (address, [segment relative paths, newest block first])
  var addrSegs: seq[tuple[address: string, segments: seq[string],
                          segJson: seq[JsonNode]]]
  for address in addrOrder:
    var heights: seq[int]
    for h in addrTxsByHeight[address].keys: heights.add h
    heights.sort(SortOrder.Descending)
    var segRels: seq[string]
    var segNodes: seq[JsonNode]
    for h in heights:
      let node = %*{"chain": chain, "address": address, "fromBlock": h,
                    "toBlock": h, "transactions": addrTxsByHeight[address][h]}
      let rel = "d" / chain / "seg" / hexShard(address) / address /
                ($h & "-" & $h) & ".json"
      cfg.writeJson(rel, node)
      segRels.add rel
      segNodes.add node
    addrSegs.add (address, segRels, segNodes)
    hashEntries.add HashEntry(hexHash: address, chain: chain, kind: hkAddress)

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
    var segArray = newJArray()
    for s in a.segments: segArray.add %s
    let addrList = %*{"chain": chain, "address": a.address, "segments": segArray}
    cfg.writeJson(rel, addrList)
    addrRels.add rel
    cfg.writeText(chain / "address" / a.address / "index.html",
                  renderAddressPage(chain, a.address, addrList, a.segJson))

  var txstateRels: seq[string]
  for t in txs:
    txstateRels.add "d" / chain / "g" / gen / "txstate" / hexShard(t.hash) / t.hash & ".json"

  let summaryRel = "d" / chain / "g" / gen / "summary.json"
  cfg.writeJson(summaryRel, %*{"chain": chain, "generation": gen,
    "counters": {"blocks": blocks.len, "transactions": txs.len},
    "coverageMode": "selective", "stale": false})

  # ---- /idx/** search indices (Search-And-Routing §5, §6) ------------------
  # (1) The global hash index: shard the (chain, kind) claims by a leading hex slice
  # of the hash, so the client computes the shard path and resolves any hash in one
  # fetch without knowing the chain (§5). Emit one `.bin` per occupied prefix.
  var byPrefix = initTable[string, seq[HashEntry]]()
  for e in hashEntries:
    byPrefix.mgetOrPut(hashPrefix(e.hexHash, hashPrefixLen), @[]).add e
  var hashShardPrefixes: seq[string]
  for p in byPrefix.keys: hashShardPrefixes.add p
  hashShardPrefixes.sort()
  for p in hashShardPrefixes:
    cfg.writeBinary("idx" / "hash" / hashIdxVersion / p & ".bin",
                    encodeHashShard(byPrefix[p], hashPrefixLen))

  # (2) Name shards: a small CURATED label corpus (§6). The demo has no verified-
  # contract pipeline, so it publishes a labels object (§2.1a) and indexes it — the
  # honest, provenance-bearing source the real index is also built from (§6.2).
  let c0 = synthAddr(seed, "contract", 0)
  let c1 = synthAddr(seed, "contract", 1)
  let c2 = synthAddr(seed, "contract", 2)
  let labels = %*{"chain": chain, "labels": [
    {"id": c0, "kind": "token", "name": "Demo Token", "symbol": "DEMO",
     "provenance": provCurated},
    {"id": c1, "kind": "contract", "name": "Demo Router", "provenance": provCurated},
    {"id": c2, "kind": "contract", "name": "Demo Vault", "provenance": provCurated},
    {"id": demoAddr, "kind": "address", "name": "demo-payer.eth",
     "provenance": provSelfDeclared}]}
  cfg.writeJson("d" / chain / "labels" / "0.json", labels)

  # Flatten labels → (term, posting). A curated label outranks a self-declared one
  # (§6.2, §8): weight carries the provenance bonus.
  var flat: seq[NameTerm]
  proc addTerm(term: string, p: Posting) =
    let n = normTerm(term)
    if n.len == 0: return
    for i in 0 ..< flat.len:
      if flat[i].term == n: flat[i].postings.add p; return
    flat.add NameTerm(term: n, postings: @[p])
  # The chain's own route is indexed (§6: "the site's own routes").
  addTerm(chain, Posting(kind: "route", id: "/" & chain, displayName: chain,
    provenance: provCurated, weight: 100))
  for lab in labels["labels"]:
    let name = lab["name"].getStr
    let prov = lab["provenance"].getStr
    let w = if prov == provCurated: 100 else: 40
    let post = Posting(kind: lab["kind"].getStr, id: lab["id"].getStr,
      displayName: name, provenance: prov, weight: w)
    addTerm(name, post)
    if "symbol" in lab: addTerm(lab["symbol"].getStr, post)

  # Route terms to shards by the low bits of the term hash (§6).
  var byShard = initTable[int, seq[NameTerm]]()
  for t in flat:
    byShard.mgetOrPut(shardOf(t.term, nameShardBits), @[]).add t
  var shardRels: seq[string]
  for s in 0 ..< (1 shl nameShardBits):
    let rel = "idx" / chain / "names" / $s & ".bin"
    let terms = if s in byShard: byShard[s] else: @[]
    cfg.writeBinary(rel, encodeNameShard(s, nameShardBits, terms))
    shardRels.add rel
  let namesMetaRel = "idx" / chain / "names" / "meta.json"
  cfg.writeJson(namesMetaRel, %*{"indexVersion": nameIdxVersion, "chain": chain,
    "hashFunction": "sha1-low32", "shardBits": nameShardBits,
    "shardCount": (1 shl nameShardBits), "entryCount": labels["labels"].len,
    "termCount": flat.len, "shards": shardRels})

  # (3) The home page (Page-Descriptions §2) — the one demo page that is index,follow.
  cfg.writeText("index.html", renderHomePage(@[chain]))

  # The idx + render layer descriptors the sealed root enumerates (§2.9: `/idx/**`
  # is "in root"). Their presence tells the validator to require these layers whole.
  let idxJson = %*{
    "hash": {"version": hashIdxVersion, "prefixLen": hashPrefixLen,
             "shards": hashShardPrefixes},
    "names": [namesMetaRel]}
  let renderJson = %*{"home": "index.html", "entryPages": true}

  # The sealed, immutable generation root — every derived map is reachable here.
  let root = GenerationRoot(contractVersion: ContractVersion, chain: chain,
    generation: gen, traceSelectionVersion: tsv, summaryPath: summaryRel,
    heightPaths: @[heightRel], blockIndexPaths: @[blocksRel], addrPaths: addrRels,
    txstatePaths: txstateRels, idx: idxJson, render: renderJson)
  cfg.writeJson("d" / chain / "g" / gen / "root.json", root.toJson)

  # The one mutable object per chain: the pointer. Its head advances to the tallest
  # block in this generation, so a new generation flips it forward.
  let headH = heightList[^1]
  cfg.writeJson("d" / chain / "current.json", %*{
    "chain": chain, "generation": gen, "traceSelectionVersion": tsv,
    "head": {"height": headH, "hash": synthHash(seed, "block", headH)},
    "finalized": {"height": 100, "hash": synthHash(seed, "block", 100)}})

  txs.len
