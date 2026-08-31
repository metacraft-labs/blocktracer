## Ingest a captured live-chain snapshot into the published static tree.
##
## THE OTHER PRODUCER. `demo/generator.nim` writes a synthetic chain from a seed;
## this module writes a REAL one from `tools/chain/capture-chain.mjs`'s snapshot.
## They emit the same contract shapes into the same tree, and everything
## downstream — the route enumeration, the reader, the five §7.0 views, the
## validator — is shared. That is the design: a second chain is DATA, not a
## second explorer.
##
## WHY A SNAPSHOT AND NOT A LIVE FETCH AT BUILD TIME. The site build is hermetic
## (`nix build` runs the exporter with no network), determinism is a published
## contract that CI diffs a regeneration against, and the chain's replay window is
## about an hour wide — so no build cadence could serve a "currently replayable"
## transaction anyway. What is honest is a recording taken while the transaction
## WAS replayable, published with the moment it was taken. `capture-chain.mjs`'s
## header argues this at length; this module is the consumer of that decision.
##
## THE TWO POPULATIONS, AND WHY BOTH ARE PUBLISHED.
##
## `getTxByHash` prunes at the finalized tip and `getTxEffect` does not, so a
## settled Aztec transaction becomes UNREPLAYABLE WHILE REMAINING VISIBLE. The
## snapshot carries both kinds and so does the tree:
##
##   * `replayed`  -> `taReady`, with a real CodeTracer container published at the
##                    derived `/t/**` path. The debugger opens it.
##   * `divergent` -> `taDivergent`, ALSO with its container. The execution was
##                    recorded completely and steps normally; its effects simply
##                    did not reproduce the block's, and the overlay says which
##                    ones and how many. Filing this as a failure would throw a
##                    real recording away; filing it as `ready` would let the
##                    page present it as evidence of what the chain did.
##   * everything else -> `taAbsent`, carrying the snapshot's own sentence about
##                    why. NOT `taOnDemand`: that state offers a "Generate trace"
##                    button, and for a transaction whose body the network has
##                    destroyed that button could never succeed. Offering it would
##                    be exactly the confident-but-wrong answer this product may
##                    not ship.
##
## RUNG 3 IS PUBLISHED AS RUNG 3. The recording is instruction-level: the AVM's
## `ContractClassPublic` carries no `debug_symbols`, no `file_map` and no source
## text, so a step is a program counter and nothing positions it against a line.
## Two published consequences, and neither is cosmetic: the manifest's
## `execution.sourceLevel` is FALSE, and no source bundle is written for any real
## contract. Together those put the debugger's source pane on `srcUnverified` —
## "Stepping continues at instruction level" — instead of letting it render as if
## it had source positions it does not have. The capture measured this rather than
## assuming it (`recording.stepsPositioned` is 0 for every transaction), and the
## measurement is republished in the tree.

import std/[json, os, algorithm, strutils, tables]
import ../contract/[model, ids, version]

type
  IngestConfig* = object
    outDir*: string       ## the tree being written (shared with the demo generator)
    snapshotDir*: string  ## a directory holding snapshot.json and ct/
    generation*: string   ## "" => "1"

  IngestResult* = object
    chain*: string
    blocks*: int
    transactions*: int
    withTrace*: int        ## transactions that got a container (ready + divergent)
    divergent*: int        ## recorded, but the effects did not reproduce
    pruned*: int           ## visible to the node, no longer replayable
    containerBytes*: int   ## total bytes of published containers

const
  # The chain slug. It is deliberately NOT `aztec`: the synthetic demo owns that
  # one, and two chains that cannot be told apart in a URL is the confusion this
  # whole design exists to prevent.
  realChain* = "aztec-testnet"
  recorderId = "aztec-avm"
  traceSchema = "ctfs/v4"
  profileName = "default"
  tsv = "1"

proc writeJson(cfg: IngestConfig, rel: string, node: JsonNode) =
  let p = cfg.outDir / rel
  createDir parentDir(p)
  writeFile(p, node.pretty & "\n")

proc writeBytes(cfg: IngestConfig, rel: string, bytes: string) =
  let p = cfg.outDir / rel
  createDir parentDir(p)
  writeFile(p, bytes)

proc shortHash(s: string): string =
  ## A short, stable label for a hash-like string — used in prose, never as an id.
  if s.len <= 12: s else: s[0 .. 9] & "…"

proc ingestSnapshot*(cfg: IngestConfig): IngestResult =
  ## Read the snapshot and write the real chain's whole generation.
  let snapPath = cfg.snapshotDir / "snapshot.json"
  if not fileExists(snapPath):
    raise newException(IOError, "chain snapshot not found: " & snapPath)
  let snap = parseJson(readFile(snapPath))
  if snap{"format"}.getStr != "blocktracer/chain-snapshot@1":
    raise newException(ValueError,
      "unsupported chain snapshot format '" & snap{"format"}.getStr &
      "'; this build reads blocktracer/chain-snapshot@1")

  let gen = if cfg.generation.len > 0: cfg.generation else: "1"
  let chain = realChain
  let prov = snap["provenance"]
  let win = snap["window"]
  let finalizedAt = win["finalized"].getInt
  let tipAt = win["tip"].getInt

  let recorderVersion = "l3-" & shortHash(prov{"runtimeCommit"}.getStr)
  let rRef = RecorderRef(id: recorderId,
                         build: recorderBuildHash(recorderId, recorderVersion),
                         version: recorderVersion)
  let pRef = ProfileRef(name: profileName, hash: profileHash(profileName))

  # ---- registry: ADD this chain, never replace the file --------------------
  # The demo generator writes the registry first. A second producer that
  # overwrote it would delete the other chain's recorder pin and turn every one
  # of its transactions into `unsupported` — a data-plane fact invented by a
  # build-order accident. So this reads what is there and adds one key.
  let regRel = "registry" / "chains.v" & $ContractVersion & ".json"
  var reg =
    if fileExists(cfg.outDir / regRel): parseJson(readFile(cfg.outDir / regRel))
    else: %*{"version": ContractVersion, "chains": {}}
  reg["chains"][chain] = %*{
    "recorder": {"id": rRef.id, "build": rRef.build, "version": rRef.version},
    "profile": {"name": pRef.name, "hash": pRef.hash},
    "traceSchema": traceSchema}
  cfg.writeJson(regRel, reg)

  # ---- blocks --------------------------------------------------------------
  # Every enumerated block is published, including the empty ones. A block list
  # showing only the blocks that did work would misrepresent this chain: Aztec
  # testnet is mostly empty blocks, and hiding them would turn a ~1-in-11
  # heartbeat into an apparently continuous stream of activity.
  var blockRows: seq[tuple[hash: string, height: int, parent: string, txs: seq[string]]]
  var byHeight = initTable[int, string]()
  for b in snap["blocks"]:
    let h = b["number"].getInt
    var txs: seq[string]
    for t in b["transactions"]: txs.add t.getStr
    blockRows.add (b["hash"].getStr, h, b["parentArchiveRoot"].getStr, txs)
    byHeight[h] = b["hash"].getStr
  # Ascending by height: the published maps and the block list are ordered by
  # the chain's own ordering, not by the order the capture happened to walk.
  blockRows.sort(proc (x, y: auto): int = cmp(x.height, y.height))

  for b in blockRows:
    let bd = BlockDetail(chain: chain, hash: b.hash, height: b.height,
                         parentHash: b.parent, transactions: b.txs)
    cfg.writeJson("d" / chain / "block" / b.hash & ".json", bd.toJson)

  # ---- transactions --------------------------------------------------------
  var txCount, withTrace, divergentCount, prunedCount, totalContainerBytes = 0
  var addrTxsByHeight = initTable[string, Table[int, seq[string]]]()
  var addrOrder: seq[string]

  proc participate(address: string, height: int, txHash: string) =
    if address.len == 0: return
    if address notin addrTxsByHeight:
      addrTxsByHeight[address] = initTable[int, seq[string]]()
      addrOrder.add address
    var bh = addrTxsByHeight[address]
    if height notin bh: bh[height] = @[]
    if txHash notin bh[height]: bh[height].add txHash
    addrTxsByHeight[address] = bh

  for t in snap["transactions"]:
    let txHash = t["txHash"].getStr
    let height = t["blockNumber"].getInt
    let idx = t["txIndexInBlock"].getInt
    let outcome = t["outcome"].getStr
    # BOTH OUTCOMES THAT PRODUCED A CONTAINER. `divergent` is a complete,
    # steppable recording whose effects did not reproduce the block's — §7.0's
    # second row, and a state this tree can now publish from real data rather
    # than from a fixture. It is emphatically not a failure to record: what
    # failed is the claim that the recording is evidence of what the chain did,
    # and those two are different sentences that the page keeps apart.
    let replayed = outcome == "replayed" or outcome == "divergent"
    let reproduced = outcome == "replayed"
    let sh = hexShard(txHash)
    let blockHash = byHeight.getOrDefault(height, "")
    inc txCount

    # -- immutable facts ----------------------------------------------------
    # `revertCode` is the chain's own: 0 succeeded, anything else reverted. The
    # fee is the chain's too. Nothing here is derived from the replay, because
    # these facts are true whether or not anyone ever re-executed the thing.
    let reverted = t["revertCode"].getInt != 0
    var roles: seq[Role]
    var costs: seq[Cost]
    costs.add Cost(name: "transactionFee", used: t{"transactionFee"}.getStr,
                   limit: "", price: "", unit: "mana", token: "FeeJuice",
                   refundable: false)
    var codeEdges: seq[CodeEdge]
    var executions: seq[Execution]
    let execInputId = demoExecutionInputId(chain, txHash, "public")
    executions.add Execution(selector: "public", executionInputId: execInputId)

    var native = %*{
      "l2BlockNumber": height,
      "txIndexInBlock": idx,
      "revertCode": t["revertCode"],
      "bodyRetainedAtCapture": t{"bodyRetained"},
      "effectVisibleAtCapture": t{"effectVisible"}}
    if replayed:
      # The replay's own measurements, republished verbatim under `native`. They
      # are chain-native truth about this execution and the contract keeps such
      # payloads whole rather than flattening them.
      native["replay"] = %*{
        "instructionsExecuted": t{"instructionsExecuted"},
        "hydrationRounds": t{"hydrationRounds"},
        "preStateReadAt": t{"preStateReadAt"},
        "effectsMatched": t["effects"]{"matched"},
        "effectsMismatched": t["effects"]{"mismatched"},
        "effectsReproduced": t["effects"]{"reproduced"},
        # THE ROOTS DELIBERATELY DO NOT AGREE, and the divergence travels into
        # the tree rather than being dropped in transit. Replay hydrates only the
        # leaves the execution touched, so the trees it rebuilds are sparse and
        # their roots cannot equal the block's. A published recording whose roots
        # silently matched would be the surprising one.
        "rootsAnyAgree": t{"rootsAnyAgree"},
        "roots": t{"roots"},
        "declaredRung": t["recording"]{"declaredRung"},
        "stepsPositioned": t["recording"]{"stepsPositioned"},
        "stepsUnpositioned": t["recording"]{"stepsUnpositioned"}}

    let facts = TransactionFacts(
      chain: chain,
      id: TxId(kind: tikHash, hash: txHash),
      order: TxOrder(kind: tokBlockIndex, obBlock: blockHash, obHeight: height,
                     obIndex: idx),
      outcome: Outcome(overall: (if reverted: ooReverted else: ooSucceeded),
                       reason: "", parts: @[]),
      roles: roles, cost: costs,
      payloadRaw: "", payloadSelector: "", payloadTarget: "",
      logs: @[], codeEdges: codeEdges, executions: executions,
      native: native)
    cfg.writeJson("d" / chain / "tx" / sh / txHash & ".json", facts.toJson)

    # -- mutable per-generation state ---------------------------------------
    cfg.writeJson("d" / chain / "g" / gen / "txstate" / sh / txHash & ".json",
      %*{"chain": chain, "tx": txHash, "canonical": true,
         "finality": (if height <= finalizedAt: "finalized" else: "pending")})

    # -- the §7.0 overlay ----------------------------------------------------
    var et: ExecTrace
    if replayed:
      let rec = t["recording"]
      let matched = t["effects"]["matched"].getInt
      let mismatched = t["effects"]["mismatched"].getInt
      et = ExecTrace(selector: "public",
        availability: (if reproduced: taReady else: taDivergent),
        reason: (if reproduced: ""
                 else: "Re-executing this transaction reproduced " & $matched &
                       " of its " & $(matched + mismatched) & " published " &
                       "effects. The trace is a real recording and steps " &
                       "normally; what it cannot be used for is proving what " &
                       "the chain did."),
        bytes: t["containerBytes"].getInt,
        reconstructed: false, hasValidation: true,
        # The differential oracle here is the chain itself: the replay's effects
        # were compared against the effects the block published. `strength` is
        # the number of effects that matched, so a run that matched nothing
        # cannot present as strongly as one that matched everything.
        validation: ValidationSummary(
          status: (if reproduced: vsMatch else: vsDivergent),
          strength: matched))
      inc withTrace
      if not reproduced: inc divergentCount
      inc totalContainerBytes, t["containerBytes"].getInt

      # ---- the artifact: manifest + the real container --------------------
      let tid = deriveTraceArtifactId(execInputId, rRef.id, rRef.build,
                                      pRef.hash, traceSchema)
      let shards = traceShards(tid)
      let dir = "t" / shards.a / shards.b / tid
      let ctBytes = readFile(cfg.snapshotDir / t["container"].getStr)
      if ctBytes.len == 0:
        raise newException(ValueError,
          "the snapshot's container for " & txHash & " is empty; refusing to " &
          "publish a manifest naming a zero-byte trace")
      cfg.writeBytes(dir / "trace.ct", ctBytes)
      let manifest = TraceManifest(
        schema: ContractVersion, traceArtifactId: tid,
        executionInputId: execInputId, chain: chain, tx: txHash,
        recorder: rRef, profile: pRef,
        # NO SOURCE BUNDLES, and that is the honest answer rather than a gap.
        # Nothing on chain carries this contract's source, so there is no bundle
        # to name and the debugger must not be handed one.
        sourceBundles: newJObject(),
        container: ContainerRef(file: "trace.ct", bytes: ctBytes.len,
                                blockSize: 4096, hash: contentHashSha1(ctBytes)),
        execution: ExecutionSummary(
          steps: t["recording"]["steps"].getInt,
          frames: t["recording"]{"callsOpened"}.getInt,
          truncated: false,
          # RUNG 3. Every step in this container is unpositioned; there is no
          # file map to position it with. `false` here is what keeps the source
          # pane on the fidelity ladder's instruction-level floor.
          sourceLevel: false,
          languages: @[]),
        validation: ValidationSummary(
          status: (if reproduced: vsMatch else: vsDivergent),
          strength: matched),
        validationOracle: "published-effects",
        prestateStrategy: "hydrated-from-node")
      cfg.writeJson(dir / "manifest.json", manifest.toJson)
      discard rec
    else:
      # Not replayed. The snapshot wrote the sentence; it is published verbatim
      # so the page states the measured reason rather than a generic one.
      if outcome == "pruned": inc prunedCount
      # THE REASON IS NOT OPTIONAL. `blocktracer_client/decode.nim` refuses an
      # overlay whose `absent` execution carries no reason, and the validator
      # refuses it at publish time — both deliberately, because "absent with no
      # explanation" is indistinguishable from a failed fetch. So a row the
      # capture left without words gets words here, naming the outcome it
      # actually had, and an empty reason raises rather than shipping.
      var why = t{"reason"}.getStr
      if why.len == 0:
        why = "This transaction was not re-executed for this snapshot " &
              "(outcome: " & outcome & "), so no trace was recorded for it."
      if why.len == 0:
        raise newException(ValueError, "empty absent reason for " & txHash)
      et = ExecTrace(selector: "public", availability: taAbsent,
        reason: why, bytes: 0, reconstructed: false,
        hasValidation: false, validation: ValidationSummary())

    let overlay = TraceSelection(chain: chain, tx: txHash, executions: @[],
                                 hasSingle: true, singleTrace: et)
    cfg.writeJson("d" / chain / "ts" / tsv / sh / txHash & ".json", overlay.toJson)

    for r in roles: participate(r.address, height, txHash)

  # ---- address history -----------------------------------------------------
  addrOrder.sort()
  var addrRels: seq[string]
  for address in addrOrder:
    var heights: seq[int]
    for h in addrTxsByHeight[address].keys: heights.add h
    heights.sort(SortOrder.Descending)
    var segRels: seq[string]
    for h in heights:
      let rel = "d" / chain / "seg" / hexShard(address) / address /
                ($h & "-" & $h) & ".json"
      cfg.writeJson(rel, %*{"chain": chain, "address": address,
        "fromBlock": h, "toBlock": h,
        "transactions": addrTxsByHeight[address][h]})
      segRels.add rel
    let rel = "d" / chain / "g" / gen / "addr" / hexShard(address) / address & ".json"
    var segArray = newJArray()
    for s in segRels: segArray.add %s
    cfg.writeJson(rel, %*{"chain": chain, "address": address, "segments": segArray})
    addrRels.add rel

  # ---- generation-scoped derived maps --------------------------------------
  let heightRel = "d" / chain / "g" / gen / "height" / "0.json"
  var heightsNode = newJObject()
  for b in blockRows: heightsNode[$b.height] = %b.hash
  cfg.writeJson(heightRel, %*{"chain": chain, "epoch": 0, "heights": heightsNode})

  let blocksRel = "d" / chain / "g" / gen / "blocks" / "0.json"
  var blockHashList: seq[string]
  for b in blockRows: blockHashList.add b.hash
  cfg.writeJson(blocksRel, %*{"chain": chain, "epoch": 0, "blocks": blockHashList})

  var txstateRels: seq[string]
  for t in snap["transactions"]:
    let h = t["txHash"].getStr
    txstateRels.add "d" / chain / "g" / gen / "txstate" / hexShard(h) / h & ".json"

  # ---- summary, carrying the provenance ------------------------------------
  # THE PROVENANCE IS PUBLISHED DATA, not a template decision. Every page of this
  # chain renders its banner from here, so "is what I am looking at real?" is
  # answered by the tree rather than by which template happened to be used.
  let summaryRel = "d" / chain / "g" / gen / "summary.json"
  # The endpoint WITHOUT its scheme. `summary.json` keeps the full URL, which is
  # where a machine-readable endpoint belongs; the rendered sentence names the
  # host only. A page that printed `https://…` in prose would be indistinguish-
  # able, to `test_explorer_breadth`'s external-reference scanner, from a page
  # that FETCHED from that origin — the scanner reads characters rather than
  # markup — and the right response to a check that cannot tell a mention from a
  # fetch is to stop putting fetchable-looking strings in prose, not to teach the
  # check to ignore a class of them.
  var endpointHost = prov["endpoint"].getStr
  for scheme in ["https://", "http://"]:
    if endpointHost.startsWith(scheme):
      endpointHost = endpointHost[scheme.len .. ^1]
  let provDetail =
    "Captured from " & endpointHost & " at " &
    prov["capturedAt"].getStr & " (node " & prov["nodeVersion"].getStr &
    "). Blocks " & $win["replayableFrom"].getInt & "–" & $tipAt &
    " were inside the replay window at that moment; " & $withTrace &
    " transaction(s) were re-executed and their traces are published here. " &
    "Transactions below block " & $finalizedAt & " are still visible on the " &
    "network but their bodies have been pruned, so they can no longer be " &
    "replayed and carry no trace."
  cfg.writeJson(summaryRel, %*{
    "chain": chain, "generation": gen,
    "counters": {"blocks": blockRows.len, "transactions": txCount},
    "coverageMode": "selective", "stale": false,
    "provenance": {
      "kind": "live-capture",
      "label": "Real Aztec testnet data",
      "endpoint": prov["endpoint"],
      "capturedAt": prov["capturedAt"],
      "nodeVersion": prov["nodeVersion"],
      "l1ChainId": prov["l1ChainId"],
      "tipAtCapture": tipAt,
      "finalizedAtCapture": finalizedAt,
      "replayableWindowBlocks": win["blocks"],
      "tracesPublished": withTrace,
      "detail": provDetail}})

  let root = GenerationRoot(contractVersion: ContractVersion, chain: chain,
    generation: gen, traceSelectionVersion: tsv, summaryPath: summaryRel,
    heightPaths: @[heightRel], blockIndexPaths: @[blocksRel],
    addrPaths: addrRels, txstatePaths: txstateRels, idx: nil, render: nil)
  cfg.writeJson("d" / chain / "g" / gen / "root.json", root.toJson)

  # The one mutable object. `finalized` is the node's own finalized tip at
  # capture, not the tallest block we happen to hold.
  let headB = blockRows[^1]
  var finalizedHash = byHeight.getOrDefault(finalizedAt, "")
  var finalizedHeight = finalizedAt
  if finalizedHash.len == 0:
    # The finalized tip was below the enumerated range. Point at the oldest block
    # this generation actually carries rather than at a hash it does not have.
    finalizedHeight = blockRows[0].height
    finalizedHash = blockRows[0].hash
  cfg.writeJson("d" / chain / "current.json", %*{
    "chain": chain, "generation": gen, "traceSelectionVersion": tsv,
    "head": {"height": headB.height, "hash": headB.hash},
    "finalized": {"height": finalizedHeight, "hash": finalizedHash}})

  IngestResult(chain: chain, blocks: blockRows.len, transactions: txCount,
               withTrace: withTrace, divergent: divergentCount,
               pruned: prunedCount, containerBytes: totalContainerBytes)
