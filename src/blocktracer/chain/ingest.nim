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
## THE RUNG IS PUBLISHED AS THE RUNG THE CAPTURE MEASURED, PER TRANSACTION.
##
## THIS PARAGRAPH USED TO READ "RUNG 3 IS PUBLISHED AS RUNG 3" AND TO EXPLAIN IT
## AS A PROPERTY OF THE CHAIN, AND THAT WAS A DOCUMENTATION DEFECT WITH A
## CONSEQUENCE. The half that was true: the AVM's `ContractClassPublic` carries no
## `debug_symbols`, no `file_map` and no source text, so *from the node* a step is
## a program counter and nothing positions it against a line. The half that was
## missing is the qualifier `from the node`. Upstream's own doc comment on
## `artifactHash` says the field exists so a client can "verify that an OFFCHAIN
## FETCHED ARTIFACT matches a registered class" — the chain holds a COMMITMENT to
## the artifact, not the artifact — and `aztec-avm-runtime`'s
## `replay/src/artifact_resolution.ts` now does that fetch and that verification.
## So rung 3 is the ceiling for a contract whose artifact CANNOT BE PROVED
## off-chain, and it was never the ceiling for a chain contract as such. Read
## `replay/src/recording.ts`'s header, which states the scoped version and always
## did; the unqualified version was this file's own and it is corrected here.
##
## WHAT IS PUBLISHED NOW, and it is a measurement per transaction rather than a
## constant: the manifest's `execution.sourceLevel` is TRUE exactly when the
## capture reports `recording.sourceLevel` — which the runtime sets only when
## EVERY contract that transaction executed reached rung 1, i.e. every one of its
## executed steps resolved to a real `(path, line, column)` through an artifact
## proved against the class's `artifactHash`, its `packedBytecode` and its class
## id. When it is true a source bundle is written, keyed by contract class id,
## whose `sources` keys are the exact paths the container interned. When it is
## false — which it still is for every third-party contract in these captures,
## because none has a published or explorer-verified artifact — no bundle is
## written and the debugger's source pane stays on `srcUnverified`, "Stepping
## continues at instruction level".
##
## NEITHER DIRECTION IS ASSUMED. `recording.stepsPositioned` and the per-contract
## `recording.contractRungs` come out of the capture and are republished in the
## tree, so a page that showed source would be showing it over a container that
## measured itself as carrying it.
##
## AND THE CLAIM IS NOT UNIFORMLY STRONG, SO THE TREE SAYS HOW STRONG IT IS.
## `artifactHash` is the chain's commitment to the ARTIFACT; it does not commit
## to that artifact's `debug_symbols` or its `file_map`. What the chain proves is
## therefore that the bytecode which ran is the bytecode in the artifact — the
## source TEXT beside it is attested by whoever distributed the artifact. The
## runtime reports which: `corroborated` when two independent distributors served
## the same debug symbols and file map, `single-distributor` when one did. That
## word is republished per contract under `native.replay.artifacts` and per
## bundle under the bundle's own `debug`, because a source-level claim resting on
## one party's unverified text is a different claim from one two parties agree
## on, and the difference has to be visible in the published tree rather than
## only inside the container.
##
## REFUSE RATHER THAN DEGRADE. If a capture says `sourceLevel: true` and carries
## no bundle for the transaction, this module raises. The alternative — publish
## the manifest with an empty `sourceBundles` — hands the debugger a source pane
## pointed at a file it cannot fetch, and the alternative in the other direction
## — quietly write `sourceLevel: false` — hides a capability the recording
## actually had. Both are answers about source that nobody measured, so neither
## is published.

import std/[json, os, algorithm, strutils, tables]
import ../contract/[model, ids, version]

type
  IngestScope* = enum
    ## HOW MUCH OF A SNAPSHOT BECOMES PAGES. Not a filter and not a cap: the two
    ## values answer two different questions, and a build has to say which one it
    ## is asking.
    ##
    ## `isFull` is the explorer's answer — every block the capture enumerated and
    ## every transaction it saw, including the ones it could not replay, each
    ## carrying the producer's own sentence about why. That is what an explorer
    ## owes a visitor who arrives with a hash: the transaction exists, so the page
    ## exists, and if it cannot be debugged the page says so in words.
    ##
    ## `isCurated` is the DEMO's answer, and it is a different promise: every
    ## transaction on this chain opens a container that steps. It is what the
    ## deployed site publishes today, because the alternative was measured and it
    ## reads badly — the Aztec mainnet capture is 994 blocks and 27 transactions
    ## of which ZERO carry a trace, and a visitor's first click into it lands on
    ## an honest paragraph about the retention horizon. Correct, and not a
    ## product. One transaction per ~37 blocks is a fact about the chain (checked
    ## against an independent indexer, not against our own scan), so breadth here
    ## buys unreplayable rows and nothing else.
    ##
    ## THE HONESTY MACHINERY IS NOT WEAKENED BY THIS AND MUST NOT BE. A curated
    ## build publishes fewer transactions; it does not publish a softer sentence
    ## about any of them. Everything `isFull` says about a pruned or refused
    ## transaction is still said, still tested, and still what this ingest emits
    ## the moment the scope is `isFull` — which is the scope
    ## `test_chain_provenance` grades those states in.
    isFull = "full"
    isCurated = "curated"

  IngestConfig* = object
    outDir*: string       ## the tree being written (shared with the demo generator)
    snapshotDir*: string  ## a directory holding snapshot.json and ct/
    generation*: string   ## "" => "1"
    scope*: IngestScope   ## see `IngestScope`; the zero value is `isFull`

  IngestResult* = object
    chain*: string
    scope*: IngestScope
    blocks*: int
    transactions*: int
    withTrace*: int        ## transactions that got a container (ready + divergent)
    divergent*: int        ## recorded, but the effects did not reproduce
    pruned*: int           ## visible to the node, no longer replayable
    containerBytes*: int   ## total bytes of published containers
    # WHAT THE SNAPSHOT HELD, beside what was published. Equal to the four above
    # under `isFull`; under `isCurated` they are the evidence the published set
    # was chosen out of, and a build log that reported only the published side
    # would be the first place the difference went missing.
    observedBlocks*: int
    observedTransactions*: int
    windowFrom*, windowTo*: int

const
  # THE SLUG IS DATA, NOT A CONSTANT. It comes out of the snapshot's provenance,
  # because a second real chain must be a capture-and-publish job rather than a
  # second producer — which is the property the two-producer split was built for.
  #
  # WHAT USED TO BE FIXED HERE, AND WHY IT NO LONGER IS. This module used to refuse the
  # slug `aztec` outright, on the grounds that the synthetic demo owned it. The hazard it
  # named is real and unchanged — "two chains at one slug would overwrite each other's
  # blocks and make real and generated data indistinguishable in a URL" — but the
  # OWNERSHIP has changed: `aztec` is the Aztec mainnet, served at blocktracer.org/aztec,
  # and the fixture is the one that has to move. Deleting the guard would have thrown away
  # a correct rule along with a stale premise, so it is inverted instead and made general:
  # `assertSlugAvailable` refuses a collision in EITHER direction, and the demo is now the
  # producer most likely to trip it.
  recorderId = "aztec-avm"
  traceSchema = "ctfs/v4"
  profileName = "default"
  tsv = "1"
  # THE LANGUAGE A PROVED AZTEC ARTIFACT'S POSITIONS ARE WRITTEN IN. The same
  # constant the demo generator publishes (`traceLanguage`), and it is spelled
  # here rather than imported because the two producers must be able to disagree
  # about it: this one is the language of a contract compiled by `nargo` and
  # fetched off-chain, and that is a fact about Aztec rather than about the
  # fixture. It is published ONLY on a manifest whose `sourceLevel` is true —
  # naming a language over a container with no positions in it would be a claim
  # about source that the recording does not carry.
  bundleLanguage = "noir"

proc writeJson(cfg: IngestConfig, rel: string, node: JsonNode) =
  let p = cfg.outDir / rel
  createDir parentDir(p)
  writeFile(p, node.pretty & "\n")

proc writeBytes(cfg: IngestConfig, rel: string, bytes: string) =
  let p = cfg.outDir / rel
  createDir parentDir(p)
  writeFile(p, bytes)

proc orNull(n: JsonNode): JsonNode =
  ## A missing optional key is JSON null, not a nil pointer.
  ##
  ## `JsonNode{"k"}` returns NIL for an absent key, and a nil node embedded in a
  ## `%*` literal segfaults inside `pretty` — not an exception, a SIGSEGV, from a
  ## stack that names `json.nim` and never mentions the snapshot that was short a
  ## key. Every `{}` below is there because the key is genuinely optional, so the
  ## absence has to have a VALUE. Found by a constructed snapshot in
  ## `test_chain_provenance` suite 8 that omitted `preStateReadAt`; the committed
  ## captures all carry every one of these, which is exactly why nothing had ever
  ## reached it.
  if n.isNil: newJNull() else: n

proc shortHash(s: string): string =
  ## A short, stable label for a hash-like string — used in prose, never as an id.
  if s.len <= 12: s else: s[0 .. 9] & "…"

proc writeSourceBundle(cfg: IngestConfig, chain, codeHash, provider: string,
                       files: seq[tuple[path, content: string]],
                       attestation: JsonNode): string =
  ## Publish one content-addressed source bundle plus its `current.json` pointer
  ## (Source-Resolution.md §5) and return its `sourceBundleId`.
  ##
  ## THE SAME OBJECT SHAPE AS `demo/generator.nim`'s `writeSourceBundle`, and it
  ## is DUPLICATED rather than imported, deliberately. The demo generator is the
  ## synthetic producer; importing it here would put a fixture-shaped module on
  ## the real chain's path and give this module an opinion about `nargo`
  ## versions and vendored tracer commits that it has not measured. The two
  ## producers emit the same CONTRACT, which is the thing that has to agree, and
  ## the validator checks that agreement over both trees.
  ##
  ## WHAT MAKES THE TRACE READABLE. The CTFS container carries no source text
  ## (Trace-Artifacts.md §2.5), so without a bundle whose `sources` keys match
  ## the paths the container interned, every step resolves to a position in a
  ## file the viewer cannot display. The keys here are the driver's, byte for
  ## byte — absolute upstream CI build paths — and nothing in this module
  ## rewrites them.
  ##
  ## THE ONE ORDERING DECISION. `files` is sorted by path before the object is
  ## built, because the bundle is content-addressed by its own pretty-printed
  ## bytes and JSON object order is insertion order. A bundle whose key order
  ## followed whatever the driver happened to emit would give a different id on a
  ## rerun of the same capture, which the determinism check diffs.
  var srcs = newJObject()
  var ordered = files
  ordered.sort(proc (x, y: auto): int = cmp(x.path, y.path))
  for f in ordered:
    srcs[f.path] = %*{"content": f.content}
  # NO `compiler` BLOCK, AND THAT IS THE HONEST SHAPE. The demo generator fills
  # one because it vendored a container it compiled itself and knows the nargo
  # version and tracer commit that produced it. This producer knows neither: the
  # artifact was fetched from a distributor and proved against the chain's
  # `artifactHash`, which commits to the artifact and not to the toolchain that
  # built it. An invented `{"name": "nargo", "version": ""}` would be a field a
  # reader could take for a measurement, so what is published instead is the
  # attestation that WAS measured, under `debug`.
  let bundle = %*{
    "schema": ContractVersion,
    "codeHash": codeHash,
    "chain": chain,
    # `full`: the bundle carries the whole file set the artifact's `file_map`
    # named, which is what makes every position in the recording resolvable.
    "match": "full",
    # WHO SERVED IT, IN ITS OWN WORDS — e.g.
    # `npm:@aztec/protocol-contracts@5.3.0-nightly.20260819 FeeJuice`. This is a
    # provenance string, not a verification claim: see `corroboration` in
    # `debug`, and the paragraph about it in this module's header.
    "provider": provider,
    "language": bundleLanguage,
    "sources": srcs,
    "debug": attestation}
  # `writeJson` emits exactly `pretty & "\n"`, so hashing that string content-
  # addresses the bytes actually published.
  let bundleId = contentHashSha1(bundle.pretty & "\n")
  # The filename must be the id with ONLY its algorithm tag stripped. A consumer
  # reaching the bundle through a manifest's `sourceBundles` has no pointer to
  # read, so it reconstructs this path from the id alone and may not assume any
  # further shortening (blocktracer_client/paths.nim `shortBundleHash`).
  let short = bundleId[bundleId.find(':') + 1 .. ^1]
  let dir = "src" / chain / codeHash
  let rel = dir / short & ".json"
  cfg.writeJson(rel, bundle)
  # Only `current.json` ever moves; bundle objects are immutable (§5).
  cfg.writeJson(dir / "current.json",
    %*{"chain": chain, "codeHash": codeHash, "sourceBundleId": bundleId,
       "bundle": rel})
  bundleId

proc publishedProvenanceKind*(outDir, slug: string): string =
  ## What has already been published under `slug` in this tree, or "" for nothing.
  ##
  ## Read from the generation's own `summary.json` rather than guessed from the slug,
  ## which is the rule the product follows everywhere else: keying on a name survives
  ## exactly until someone renames a chain.
  let cur = outDir / "d" / slug / "current.json"
  if not fileExists(cur): return ""
  let gen = parseJson(readFile(cur)){"generation"}.getStr
  if gen.len == 0: return ""
  let summary = outDir / "d" / slug / "g" / gen / "summary.json"
  if not fileExists(summary): return ""
  parseJson(readFile(summary)){"provenance"}{"kind"}.getStr

proc assertSlugAvailable*(outDir, slug, claimantKind: string) =
  ## Refuse to publish `slug` over a chain another producer already published there.
  ##
  ## THE RULE, NOT THE SLUG. The old form of this guard named `aztec` and protected the
  ## demo; naming a slug made it a statement about one chain that went stale the moment
  ## ownership moved. This one states the invariant instead — one slug, one producer —
  ## so it keeps holding whichever producer is the incumbent.
  ##
  ## Re-publishing the SAME kind over itself is allowed: that is a regeneration, which is
  ## what every build does, and what the determinism check diffs.
  let incumbent = publishedProvenanceKind(outDir, slug)
  if incumbent.len == 0 or incumbent == claimantKind: return
  raise newException(ValueError,
    "the slug '" & slug & "' is already published in this tree by a '" & incumbent &
    "' chain, and a '" & claimantKind & "' chain is claiming it. Two chains at one " &
    "slug would overwrite each other's blocks and make real and generated data " &
    "indistinguishable in a URL. Give one of them a different slug.")

const SurveyBlocks* = 24
  ## How many blocks a curated build publishes for a chain that recorded NOTHING.
  ##
  ## Such a chain still has to appear — it is real, it is being watched, and the
  ## watch is the reason the site will one day have a trace from it — but 994
  ## blocks of it is a block list, not an exhibit. Two dozen is enough for the
  ## list to show the cadence and for the banner's numbers to be checkable
  ## against it on the same page.

type
  CurationWindow* = object
    ## The contiguous block range a curated build publishes.
    lo*, hi*: int
    found*: bool
    why*: string   ## the rule that produced it, in words, for the banner

proc curationWindow*(blockHeights: seq[int];
                     recorded, traceless: seq[int]): CurationWindow =
  ## The window in which EVERY transaction carries a trace.
  ##
  ## `blockHeights` ascending; `recorded` are the heights of transactions that
  ## produced a container, `traceless` the heights of the ones that did not.
  ##
  ## THE RULE IS AN INVARIANT, NOT A PREFERENCE, and that is why it is computed
  ## rather than configured. "Publish the last N blocks" would have been one line
  ## and would satisfy the request on today's data by luck: the mainnet capture
  ## happens to end in a quiet stretch, so its last 24 blocks happen to hold no
  ## transaction. The moment a transaction settles in that stretch and is not
  ## replayable, an N-block rule publishes it and the promise this whole change
  ## exists to make — every transaction here opens — is silently false. So the
  ## window is DELIMITED BY the traceless transactions rather than sized past
  ## them, and `ingestSnapshot` re-checks the invariant over what it is about to
  ## write rather than trusting this proc to have held it.
  ##
  ## Two shapes, because there are two situations:
  ##
  ##   * SOMETHING WAS RECORDED. The window is the span of the recordings, cut at
  ##     whichever traceless transactions bound it. Where traceless transactions
  ##     split the recordings into several such runs, the run holding the most
  ##     recordings wins, and the NEWEST wins a tie — a demo should be looking at
  ##     the most recent thing the chain let it record.
  ##   * NOTHING WAS RECORDED. There is no span to take, so the window is the
  ##     newest run of blocks that settled no transaction at all, capped at
  ##     `SurveyBlocks`. It publishes real blocks and no transactions, which is
  ##     an honest picture of a chain nothing has been recorded from yet, and it
  ##     satisfies the invariant vacuously rather than by exception.
  result.found = false
  if blockHeights.len == 0: return
  let lowest = blockHeights[0]
  let highest = blockHeights[^1]

  var isTraceless = initTable[int, bool]()
  for h in traceless: isTraceless[h] = true

  if recorded.len > 0:
    # The delimiters around each recording, as a (below, above) pair. Recordings
    # sharing a pair are in the same run.
    var runs = initTable[string, seq[int]]()
    var order: seq[string]
    for h in recorded:
      var below = lowest - 1
      var above = highest + 1
      for t in traceless:
        if t < h and t > below: below = t
        if t > h and t < above: above = t
      let key = $below & ":" & $above
      if key notin runs:
        runs[key] = @[]
        order.add key
      runs[key].add h
    var bestKey = ""
    var bestCount = 0
    var bestHi = 0
    for key in order:
      let hs = runs[key]
      var hi = hs[0]
      for h in hs: hi = max(hi, h)
      # Most recordings wins; the newest run breaks a tie.
      if hs.len > bestCount or (hs.len == bestCount and hi > bestHi):
        bestKey = key
        bestCount = hs.len
        bestHi = hi
    var lo = bestHi
    for h in runs[bestKey]: lo = min(lo, h)
    result = CurationWindow(lo: lo, hi: bestHi, found: true,
      why: "This chain publishes the blocks its recordings span — blocks " &
           $lo & "–" & $bestHi & " — so that every transaction on it opens a " &
           "container that steps.")
    return

  # NOTHING RECORDED. Every maximal run of consecutive blocks that settled no
  # transaction is a candidate, and the choice between them is SIZE FIRST,
  # recency second.
  #
  # "The newest such run" was the first rule and it is not stable enough to
  # publish: the run above the newest transaction shrinks by one every time the
  # chain settles another, and it was measured doing exactly that — a mainnet
  # transaction arrived in block 67764 and the published window went from 24
  # blocks to 8 between two builds. At one transaction it would be a single
  # block, which is a chain page that looks broken while being correct.
  #
  # So a run of at least `SurveyBlocks` wins over a shorter one however recent,
  # and among those the newest wins; its newest `SurveyBlocks` blocks are what
  # is published. Where no run is that long the newest run is taken whole, which
  # is the honest floor: the alternative is publishing a block that settled a
  # transaction nothing can open, and the size of the page is not worth that.
  var runs: seq[tuple[lo, hi: int]]
  var i = blockHeights.len - 1
  while i >= 0:
    if isTraceless.getOrDefault(blockHeights[i], false):
      dec i
      continue
    let hi = blockHeights[i]
    var lo = hi
    while i - 1 >= 0 and blockHeights[i - 1] == blockHeights[i] - 1 and
          not isTraceless.getOrDefault(blockHeights[i - 1], false):
      dec i
      lo = blockHeights[i]
    runs.add (lo: lo, hi: hi)
    dec i
  if runs.len == 0: return
  # `runs` is newest-first by construction, so the FIRST match on each pass is
  # already the newest one and no tie-break is spelled twice.
  var chosen = runs[0]
  for r in runs:
    if r.hi - r.lo + 1 >= SurveyBlocks:
      chosen = r
      break
  let hi = chosen.hi
  let lo = max(chosen.lo, hi - SurveyBlocks + 1)
  result = CurationWindow(lo: lo, hi: hi, found: true,
    why: "Nothing on this chain has been recorded yet, so there is no span of " &
         "recordings to publish. What is published is a run of blocks that " &
         "settled no transaction at all — blocks " & $lo & "–" & $hi &
         " — which keeps the promise that every transaction here opens, and " &
         "keeps it without publishing a transaction that does not.")

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
  let prov = snap["provenance"]
  let chain = prov{"chain"}.getStr
  if chain.len == 0:
    raise newException(ValueError,
      "the snapshot names no chain in provenance.chain; refusing to guess a slug")
  assertSlugAvailable(cfg.outDir, chain, "live-capture")
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

  let observedBlocks = blockRows.len
  var observedTransactions = 0
  for t in snap["transactions"]: inc observedTransactions

  # ---- the curated window --------------------------------------------------
  # See `IngestScope`. `isFull` publishes everything and computes nothing here;
  # `isCurated` narrows the block record FIRST, so every loop below — blocks,
  # transactions, the height and block maps, the address segments, the head
  # pointer — is written over the published set rather than over the enumerated
  # one and then trimmed. A tree trimmed afterwards is a tree with two answers to
  # "what is on this chain" in it.
  var recordedHeights, tracelessHeights: seq[int]
  for t in snap["transactions"]:
    let o = t["outcome"].getStr
    if o == "replayed" or o == "divergent": recordedHeights.add t["blockNumber"].getInt
    else: tracelessHeights.add t["blockNumber"].getInt
  var allHeights: seq[int]
  for b in blockRows: allHeights.add b.height
  var window = CurationWindow(lo: (if allHeights.len > 0: allHeights[0] else: 0),
                              hi: (if allHeights.len > 0: allHeights[^1] else: 0),
                              found: true, why: "")
  if cfg.scope == isCurated:
    window = curationWindow(allHeights, recordedHeights, tracelessHeights)
    if not window.found:
      raise newException(ValueError,
        "a curated ingest of '" & chain & "' found no window in which every " &
        "transaction carries a trace: the capture recorded none, and every " &
        "block it enumerated settled a transaction it could not replay. There " &
        "is nothing here that satisfies the promise a curated build makes. " &
        "Ingest this capture with scope=isFull, which publishes each of those " &
        "transactions with the producer's own sentence about why it has no trace.")
    var kept: seq[typeof(blockRows[0])]
    for b in blockRows:
      if b.height >= window.lo and b.height <= window.hi: kept.add b
    blockRows = kept
    if blockRows.len == 0:
      raise newException(ValueError,
        "the curated window " & $window.lo & "–" & $window.hi & " for '" &
        chain & "' selected no block; refusing to publish an empty chain")

  # THE INVARIANT, RE-CHECKED OVER WHAT IS ABOUT TO BE WRITTEN. `curationWindow`
  # is supposed to guarantee this and the check does not trust it to: a window
  # off by one at either end publishes a transaction that cannot be opened, and
  # that is precisely the thing a curated build promises does not happen. It is
  # cheap and it is at the composition of the two facts — the window and the
  # outcomes — rather than inside the proc that produced only one of them.
  if cfg.scope == isCurated:
    for t in snap["transactions"]:
      let h = t["blockNumber"].getInt
      if h < window.lo or h > window.hi: continue
      let o = t["outcome"].getStr
      if o != "replayed" and o != "divergent":
        raise newException(ValueError,
          "the curated window " & $window.lo & "–" & $window.hi & " for '" &
          chain & "' contains transaction " & shortHash(t["txHash"].getStr) &
          " in block " & $h & " with outcome '" & o & "', which publishes no " &
          "container. A curated chain promises every transaction on it opens.")

  # `byHeight` MAPS ONLY PUBLISHED BLOCKS, and it is rebuilt here rather than
  # populated during enumeration. It answers two questions further down — which
  # block a transaction sits in, and which hash the finalized pointer names — and
  # both must be answerable only about blocks this generation actually carries.
  # Built over the enumerated set it would resolve `finalized` to the hash of a
  # block a curated tree does not publish, i.e. a pointer into a 404.
  byHeight.clear()
  for b in blockRows: byHeight[b.height] = b.hash

  for b in blockRows:
    let bd = BlockDetail(chain: chain, hash: b.hash, height: b.height,
                         parentHash: b.parent, transactions: b.txs)
    cfg.writeJson("d" / chain / "block" / b.hash & ".json", bd.toJson)

  # ---- transactions --------------------------------------------------------
  var txCount, withTrace, divergentCount, prunedCount, totalContainerBytes = 0
  # REFUSALS ARE COUNTED SEPARATELY FROM PRUNING, because they are opposite facts
  # about the same window and the page must not merge them. A pruned transaction was
  # never replayable when it was reached; a REFUSED one was — its body was still
  # served — and the replay declined. Saying "no transaction inside the window was
  # replayable" over a refusal is false in the direction that matters: it blames the
  # chain for a fault on this side of the wire.
  var refusedCount = 0
  var refusalNames: seq[string]
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
    # A transaction outside the published block record has no block to belong to.
    # Under `isFull` the window is the whole record and this excludes nothing.
    if height < window.lo or height > window.hi: continue
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
    # -- the code edges, from the artifact resolution ------------------------
    # ONE EDGE PER CONTRACT THE TRANSACTION EXECUTED, RESOLVED OR NOT.
    #
    # A code edge is a fact about the transaction — this address ran this
    # contract class, bound at this block — and it is true whether or not anyone
    # managed to fetch source for that class. Filtering to the resolved ones
    # would make `/tx` pages quietly narrower for exactly the contracts nobody
    # has published an artifact for, and it would break the consumer's own
    # lookup: `blocktracer_client/sources.nim`'s `codeHashes` walks these edges
    # to decide which bundles to ask for, so an unresolved contract has to be
    # ASKED about and answered "no bundle published for this code hash" rather
    # than never appearing.
    #
    # This is also why the edges do not depend on `sourceLevel`: they are
    # published for a rung-3 transaction too, and they were simply missing
    # before — the seq was declared and left empty.
    var codeEdges: seq[CodeEdge]
    if t{"artifacts"} != nil and t["artifacts"].kind == JArray:
      for a in t["artifacts"]:
        let addr0 = a{"address"}.getStr
        let cls = a{"contractClassId"}.getStr
        if addr0.len == 0 and cls.len == 0: continue
        codeEdges.add CodeEdge(address: addr0, codeHash: cls, boundAt: blockHash)
    # A PER-CONTRACT SUMMARY OF THE RESOLUTION, for republication under
    # `native.replay`. Five fields out of the capture's much larger entries: the
    # rejected candidates and the file lists belong in the capture and in the
    # container's `ct.source-provenance`, not on every transaction page. What is
    # kept is what a reader needs to judge the claim — who it is, which class it
    # ran, whether an artifact was proved for it, where that artifact came from,
    # and how many independent parties agreed on its source text.
    var artifactSummary = newJArray()
    if t{"artifacts"} != nil and t["artifacts"].kind == JArray:
      for a in t["artifacts"]:
        artifactSummary.add %*{
          "address": orNull(a{"address"}),
          "contractClassId": orNull(a{"contractClassId"}),
          "resolved": a{"resolved"}.getBool,
          "origin": orNull(a{"origin"}),
          "corroboration": orNull(a{"corroboration"})}

    # THE MEASUREMENT, AND IT DEFAULTS TO FALSE.
    #
    # `getBool` on an absent key answers `false`, and that is the direction the
    # default has to fall: an older snapshot — every capture committed before the
    # runtime learned to resolve artifacts off-chain — carries no
    # `recording.sourceLevel` at all, and must not become source-level by the
    # accident of a missing key. The refusal below only fires on a snapshot that
    # said `true` out loud.
    let measuredSourceLevel =
      replayed and t{"recording"}{"sourceLevel"}.getBool

    var executions: seq[Execution]
    let execInputId = demoExecutionInputId(chain, txHash, "public")
    executions.add Execution(selector: "public", executionInputId: execInputId)

    var native = %*{
      "l2BlockNumber": height,
      "txIndexInBlock": idx,
      "revertCode": t["revertCode"],
      "bodyRetainedAtCapture": orNull(t{"bodyRetained"}),
      "effectVisibleAtCapture": orNull(t{"effectVisible"})}
    if replayed:
      # The replay's own measurements, republished verbatim under `native`. They
      # are chain-native truth about this execution and the contract keeps such
      # payloads whole rather than flattening them.
      native["replay"] = %*{
        "instructionsExecuted": orNull(t{"instructionsExecuted"}),
        "hydrationRounds": orNull(t{"hydrationRounds"}),
        "preStateReadAt": orNull(t{"preStateReadAt"}),
        "effectsMatched": orNull(t["effects"]{"matched"}),
        "effectsMismatched": orNull(t["effects"]{"mismatched"}),
        "effectsReproduced": orNull(t["effects"]{"reproduced"}),
        # THE ROOTS DELIBERATELY DO NOT AGREE, and the divergence travels into
        # the tree rather than being dropped in transit. Replay hydrates only the
        # leaves the execution touched, so the trees it rebuilds are sparse and
        # their roots cannot equal the block's. A published recording whose roots
        # silently matched would be the surprising one.
        "rootsAnyAgree": orNull(t{"rootsAnyAgree"}),
        "roots": orNull(t{"roots"}),
        "declaredRung": orNull(t["recording"]{"declaredRung"}),
        "stepsPositioned": orNull(t["recording"]{"stepsPositioned"}),
        "stepsUnpositioned": orNull(t["recording"]{"stepsUnpositioned"}),
        # THE SOURCE-LEVEL MEASUREMENT AND WHAT IT RESTS ON, IN THE TREE.
        #
        # `sourceLevel` is the runtime's own AND over every contract the
        # transaction executed, and `contractRungs` is the per-contract detail
        # it was computed from — so a reader can see WHICH contract held a
        # transaction at rung 3, rather than only that one did.
        #
        # `artifacts` carries `corroboration`, and that is the field this block
        # exists for. `artifactHash` commits to the artifact but NOT to its
        # `debug_symbols` or its `file_map`, so the source TEXT is attested by
        # whoever served it. `corroborated` means two independent distributors
        # served the same debug symbols and file map; `single-distributor` means
        # one did, and the source a visitor is reading rests on that one party's
        # unverified word. That difference has to be legible in the published
        # tree and not only inside the container, because the tree is what a
        # page, a check or a reader can look at.
        "sourceLevel": %measuredSourceLevel,
        "contractRungs": orNull(t["recording"]{"contractRungs"}),
        "artifacts": artifactSummary}

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

      # ---- the source bundles, when the recording measured itself as source
      # level ---------------------------------------------------------------
      #
      # THE TWO STATES ARE PUBLISHED DIFFERENTLY AND THERE IS NO THIRD.
      #
      #   * `recording.sourceLevel` FALSE — every step in this container is a
      #     bare program counter, or at least one contract's was. `sourceBundles`
      #     stays empty, nothing is written under `/src`, and the debugger's
      #     source pane stays on `srcUnverified`, "Stepping continues at
      #     instruction level". That is still the answer for every contract with
      #     no published or provable artifact, which is most of them.
      #   * `recording.sourceLevel` TRUE — every contract this transaction
      #     executed reached rung 1 through an artifact proved against its
      #     class's `artifactHash`, its `packedBytecode` and its class id, and
      #     the capture carries the source text those positions point into. One
      #     bundle per contract class is published and named in the manifest.
      #
      # REFUSE RATHER THAN DEGRADE. A manifest claiming source level with no
      # bundle beside it is not a smaller version of the truth — it points the
      # debugger's source pane at a file it cannot fetch, which is the
      # confident-but-wrong answer this product may not ship. Silently
      # downgrading it to `sourceLevel: false` would be just as bad in the other
      # direction: the recording DID position its steps, and a tree that quietly
      # said otherwise would hide a working capability behind a missing file.
      # So both halves of the disagreement raise, in the same style as the
      # zero-byte-container refusal above.
      var bundles = newJObject()
      if measuredSourceLevel:
        # The row names the file; the conventional path is the fallback, so a
        # capture written before the row carried the key still resolves.
        var srcRel = t{"sourceBundles"}.getStr
        if srcRel.len == 0: srcRel = "sources" / (txHash & ".json")
        let srcPath = cfg.snapshotDir / srcRel
        if not fileExists(srcPath):
          raise newException(ValueError,
            "the capture measured " & txHash & " as source level and this " &
            "snapshot carries no source bundle for it (looked for " & srcRel &
            "); refusing to publish a manifest that claims source level with " &
            "no bundle to open, which would put the debugger's source pane on " &
            "a file it cannot fetch")
        let srcDoc = parseJson(readFile(srcPath))
        let bundleList = srcDoc{"bundles"}
        if bundleList == nil or bundleList.kind != JArray or bundleList.len == 0:
          raise newException(ValueError,
            "the capture measured " & txHash & " as source level and its " &
            "source bundle file " & srcRel & " carries no bundle; refusing to " &
            "publish a manifest that claims source level with no bundle to " &
            "open, which would put the debugger's source pane on a file it " &
            "cannot fetch")
        for b in bundleList:
          let codeHash = b{"codeHash"}.getStr
          if codeHash.len == 0:
            raise newException(ValueError,
              "a source bundle for " & txHash & " in " & srcRel & " names no " &
              "codeHash; a bundle is keyed by contract class id and one " &
              "without a key cannot be reached from a manifest")
          # THE KEYS ARE THE DRIVER'S, BYTE FOR BYTE. They are the absolute
          # upstream CI build paths the .ct container interned, and the whole
          # value of the bundle is that they match what the container asks for.
          # Prettifying them would be a cosmetic change that breaks the only
          # thing the file is for.
          var files: seq[tuple[path, content: string]]
          let fs = b{"files"}
          if fs != nil and fs.kind == JObject:
            for p, c in fs: files.add (path: p, content: c.getStr)
          if files.len == 0:
            raise newException(ValueError,
              "the source bundle for code hash " & codeHash & " of " & txHash &
              " in " & srcRel & " carries no files; refusing to publish an " &
              "empty bundle a manifest would then recommend")
          # WHAT THE CHAIN PROVED AND WHAT IT DID NOT, published beside the
          # text. `artifactHash` is the chain's commitment to the artifact and
          # does NOT cover `debug_symbols` or `file_map`, so `corroboration`
          # names how many independent distributors served the same symbols and
          # map — `corroborated` for two, `single-distributor` for one. A reader
          # who wants to know how much of the source below is attested by the
          # chain and how much by a package registry has it here.
          var agreeing = newJArray()
          if b{"agreeingDistributors"} != nil and
             b["agreeingDistributors"].kind == JArray:
            agreeing = b["agreeingDistributors"]
          let attestation = %*{
            "artifactHash": orNull(b{"artifactHash"}),
            "debugDigest": orNull(b{"debugDigest"}),
            "shape": orNull(b{"shape"}),
            "corroboration": orNull(b{"corroboration"}),
            "agreeingDistributors": agreeing}
          bundles[codeHash] = %cfg.writeSourceBundle(
            chain, codeHash, b{"origin"}.getStr, files, attestation)


      # ---- the recording's own program counters -----------------------------
      #
      # THE FLOOR OF THE LADDER, PUBLISHED SO A PAGE CAN RENDER IT. Rung 3 means
      # no step resolves to a source line; it does not mean a step has no
      # coordinate. Every step in these containers carries a program counter, an
      # opcode number and a gas reading, and until this object reached the tree
      # the Code pane described that recording in prose and then rendered none of
      # it.
      #
      # DERIVED OFFLINE AND COMMITTED, not read here. Opening a `.ct` needs the
      # container reader, which is not a dependency of this repository and could
      # not be one — the site build is hermetic. So
      # `tools/chain/derive-instructions.mjs` writes `instructions/<tx>.json`
      # beside the snapshot's `ct/`, exactly as `extract-flow.mjs` derives the
      # omniscience fixture from a vendored container, and this copies whatever
      # is there.
      #
      # ITS ABSENCE IS A VALID SNAPSHOT and is deliberately not an error: a
      # capture taken before the derivation existed publishes a manifest, a
      # container and no listing, and the pane falls back to the stated reason it
      # has always shown. Refusing the build would make an old snapshot
      # unpublishable to buy a pane a nicer degraded state.
      let insFile = cfg.snapshotDir / "instructions" / txHash & ".json"
      if fileExists(insFile):
        let ins = parseJson(readFile(insFile))
        # THE TWO COUNTS MUST AGREE. `execution.steps` is what the manifest
        # publishes and what the toolbar counts to; the listing is rendered
        # against it and its rows ARE those steps. A listing of a different
        # length would put the position marker on the wrong row, and every
        # surface involved would go on reporting success — so this is refused at
        # publish time rather than rendered.
        let declared = t["recording"]["steps"].getInt
        let carried = ins{"steps"}.getInt(-1)
        if carried != declared:
          raise newException(ValueError,
            "the instruction listing for " & txHash & " holds " & $carried &
            " steps and the recording declares " & $declared &
            "; refusing to publish a listing the position cannot be located in")
        cfg.writeJson(dir / "instructions.json", ins)
      let manifest = TraceManifest(
        schema: ContractVersion, traceArtifactId: tid,
        executionInputId: execInputId, chain: chain, tx: txHash,
        recorder: rRef, profile: pRef,
        # EMPTY IS THE HONEST ANSWER FOR A RUNG-3 RECORDING, and it is empty by
        # construction rather than by decision: `bundles` is only ever filled on
        # the branch above, which cannot be taken unless the capture measured
        # `sourceLevel` true AND a bundle file with contents was found for it.
        sourceBundles: bundles,
        container: ContainerRef(file: "trace.ct", bytes: ctBytes.len,
                                blockSize: 4096, hash: contentHashSha1(ctBytes)),
        execution: ExecutionSummary(
          steps: t["recording"]["steps"].getInt,
          frames: t["recording"]{"callsOpened"}.getInt,
          truncated: false,
          # THE MEASUREMENT, NOT A CONSTANT. This used to be a literal `false`
          # with a comment calling rung 3 the ceiling for a chain contract; that
          # was true only of what is reachable FROM THE NODE (see the module
          # header). What is published now is what the capture measured: true
          # exactly when every contract the transaction executed reached rung 1,
          # and the source pane is held on the instruction-level floor in every
          # other case.
          sourceLevel: measuredSourceLevel,
          # The language is named only when there are positions to attach it to.
          languages: (if measuredSourceLevel: @[bundleLanguage] else: @[])),
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
      if outcome == "refused":
        inc refusedCount
        let rn = t{"refusal"}.getStr
        if rn.len > 0 and rn notin refusalNames: refusalNames.add rn
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

  # THE SAME FILTER AS THE WRITE LOOP, and it has to be: this list names the
  # txstate objects the generation root points at, and a name here for a file the
  # transaction loop skipped is a root that points at nothing.
  var txstateRels: seq[string]
  for t in snap["transactions"]:
    let h = t["txHash"].getStr
    let height = t["blockNumber"].getInt
    if height < window.lo or height > window.hi: continue
    txstateRels.add "d" / chain / "g" / gen / "txstate" / hexShard(h) / h & ".json"

  # ---- summary, carrying the provenance ------------------------------------
  # THE PROVENANCE IS PUBLISHED DATA, not a template decision. Every page of this
  # chain renders its banner from here, so "is what I am looking at real?" is
  # answered by the tree rather than by which template happened to be used.
  # WHY A ZERO-TRACE CAPTURE CAME OUT ZERO — measured, not averaged.
  #
  # The obvious sentence to generate here is a RATE: "one transaction per N
  # blocks against an M-block window, so most captures catch none." It would
  # have been wrong on the first mainnet capture and wrong in the confident
  # direction. That capture found 20 transactions in 400 blocks — one per 20,
  # against a 25-block window, which as a rate predicts roughly one catch per
  # capture. It caught none, because the arrivals are BURSTY and not spread: 18
  # of the 20 fell inside a 53-block span, then nothing at all for 309 blocks.
  # An average over a bursty series is a number that is true and predicts the
  # wrong thing, which is precisely the shape of claim this product may not
  # publish.
  #
  # So the page states what was observed: how many, over what range, the longest
  # silence inside it, and how far the most recent transaction sat from the
  # window it missed. Those are facts a reader can check against the block list
  # on the same site.
  var txHeights: seq[int]
  for t in snap["transactions"]: txHeights.add t["blockNumber"].getInt
  txHeights.sort()
  let mostRecentTxBlock = if txHeights.len > 0: txHeights[^1] else: 0
  var largestGap = 0
  for i in 1 ..< txHeights.len:
    largestGap = max(largestGap, txHeights[i] - txHeights[i - 1])

  # HOW FAR THE NEWEST TRANSACTION SAT FROM THE WINDOW IT MISSED — and the arithmetic
  # only means that when it is actually below it.
  #
  # `replayableFrom - mostRecentTxBlock` was written when a snapshot was one scan, where
  # the newest transaction is necessarily at or below the tip that scan read. A WATCHED
  # snapshot breaks that: the follower keeps extending the block record, so the newest
  # transaction can sit far ABOVE the window recorded at the last catch, and the
  # subtraction goes negative. It did: the first grown mainnet snapshot published
  # "the most recent one settled in block 67511 — -391 block(s) below the window", a
  # sentence that is not merely ugly but false, on the one element of the page whose
  # entire job is to be believed.
  #
  # Three arms, because there are three states of the world and each says something
  # different to a reader: nothing settled at all, the newest is below the window and
  # therefore pruned, or the newest is inside it and simply was not replayable when the
  # capture reached it.
  let replFrom = win["replayableFrom"].getInt
  let belowBy = replFrom - mostRecentTxBlock
  let recency =
    if txHeights.len == 0:
      "no transaction settled in the enumerated range at all. "
    elif belowBy > 0:
      "the most recent one settled in block " & $mostRecentTxBlock & " — " &
      $belowBy & " block(s) below that window, so it had already been pruned " &
      "when this capture ran. "
    else:
      "the most recent one settled in block " & $mostRecentTxBlock &
      ", at or above the last window recorded here — it carries no trace " &
      "because its body was already gone when the capture reached it. "

  # The label a reader sees on the banner and on the home page's chain strip.
  # The capture supplies it; this is a fallback for a snapshot that named none,
  # and it deliberately does NOT try to prettify the slug beyond saying the data
  # is real — an invented display name is a claim nobody measured.
  let provLabel =
    if prov{"label"}.getStr.len > 0: prov["label"].getStr
    else: "Real chain data"

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
  # WHAT WAS CAPTURED, AND — WHEN IT IS NOTHING — THAT IT WAS NOTHING.
  #
  # A chain whose window held no replayable transaction is a real outcome, not a
  # broken capture, and it is the outcome a sparse chain will USUALLY produce:
  # if transactions arrive further apart than the window is wide, most captures
  # catch none. The sentence has to say that in the same breath as the numbers,
  # because a reader who sees real blocks and real transactions and no traces
  # will otherwise reasonably conclude the site is broken.
  #
  # The two arms differ only in the middle clause. Both state the window, both
  # state the pruning boundary, and neither apologises: "no transaction inside
  # the window was replayable" is a measurement, and the density that explains
  # it is published beside it.
  #
  # A SNAPSHOT MAY BE THE PRODUCT OF MORE THAN ONE MOMENT. `capture-chain.mjs` writes one
  # scan and its `capturedAt` is that scan; `follow-chain.mjs` WATCHES, and the snapshot it
  # grows spans every moment it was extended. "at that moment" is then a false sentence
  # about a true timestamp — the blocks run to the latest poll and the reader is told the
  # whole chain was read hours earlier.
  #
  # So the phrasing follows the snapshot. A single-moment capture reads exactly as it
  # always did, byte for byte; a watched one says it was watched, and names both ends.
  # `firstCapturedAt` is what distinguishes them, and it is absent from a one-shot
  # snapshot rather than equal to `capturedAt`, so this cannot misclassify a scan.
  let firstAt = prov{"firstCapturedAt"}.getStr
  let lastAt = prov{"capturedAt"}.getStr
  # A FROZEN CAPTURE IS FINISHED, AND SAYS SO IN THE PAST TENSE. The two arms below both
  # describe a capture that is still going: "was last extended" and "when it was last
  # looked at" are true only while something might extend it again. Once the demo's target
  # is met the snapshot stops changing, and those phrases become quietly wrong — they
  # invite a reader to expect a newer window than the one on the page, and they date the
  # capture to a "last look" that will never happen again.
  #
  # `frozen` is written by `tools/chain/freeze-snapshot.mjs` only after every complete
  # block has been verified against the chain, so this arm cannot be reached by a snapshot
  # that merely stopped being written to.
  var completeNums: seq[int] = @[]
  if prov{"completeBlocks"} != nil and prov["completeBlocks"].kind == JArray:
    for b in prov["completeBlocks"]: completeNums.add b.getInt
  let blockList =
    if completeNums.len == 1: "block " & $completeNums[0]
    elif completeNums.len == 2: "blocks " & $completeNums[0] & " and " & $completeNums[1]
    else:
      var parts: seq[string] = @[]
      for i, n in completeNums:
        if i == completeNums.high: parts.add "and " & $n
        else: parts.add $n
      "blocks " & parts.join(", ")
  # THE WINDOW THE FROZEN SENTENCE MEANS IS THE ONE AT THE LAST CAPTURE, NOT AT THE LAST
  # POLL. `snap["window"]` is rewritten on every backfill, and a follower keeps polling and
  # backfilling long after its final catch — mainnet's capture outlived its last catch by
  # 92 minutes and 76 blocks. Reading the snapshot-level window here made the page say "the
  # replay window was blocks 68287–68307 when the last of them was taken" about a block
  # taken at 68231, inside a window of 68191–68231: a true window, attached to the wrong
  # moment, in a sentence whose whole job is to date the capture. The per-transaction
  # `capturedWindow` is the window that was open when THAT transaction was recorded.
  var frozenFrom = replFrom
  var frozenTip = tipAt
  var frozenBlocks = win["blocks"].getInt
  if completeNums.len > 0:
    let newest = max(completeNums)
    for t in snap["transactions"]:
      if t{"blockNumber"}.getInt == newest and t{"capturedWindow"} != nil:
        let cw = t["capturedWindow"]
        frozenFrom = cw["replayableFrom"].getInt
        frozenTip = cw["tip"].getInt
        frozenBlocks = frozenTip - cw["finalized"].getInt
  let captured =
    if prov{"frozen"}.getBool and completeNums.len > 0:
      "Captured from " & endpointHost &
      (if firstAt.len > 0 and firstAt != lastAt: " between " & firstAt & " and " & lastAt
       else: " at " & lastAt) &
      " (node " & prov["nodeVersion"].getStr & "). This capture is complete and is not " &
      "being extended: " & blockList & " were taken WHOLE — every transaction the chain " &
      "published in " & (if completeNums.len == 1: "it" else: "them") &
      " was re-executed and its trace is published here. The replay window was blocks " &
      $frozenFrom & "–" & $frozenTip & " (" & $frozenBlocks &
      " blocks) when the last of them was taken. "
    elif firstAt.len > 0 and firstAt != lastAt:
      "Captured from " & endpointHost & " over a watch that began " & firstAt &
      " and was last extended " & lastAt & " (node " & prov["nodeVersion"].getStr &
      "). The replay window was blocks " & $replFrom & "–" & $tipAt & " (" &
      $win["blocks"].getInt & " blocks) when it was last looked at. "
    else:
      "Captured from " & endpointHost & " at " & lastAt &
      " (node " & prov["nodeVersion"].getStr & "). The replay window was blocks " &
      $replFrom & "–" & $tipAt & " (" & $win["blocks"].getInt &
      " blocks) at that moment. "
  let middle =
    if withTrace > 0:
      $withTrace & " transaction(s) inside it were re-executed and their " &
      "traces are published here. "
    elif refusedCount > 0:
      # THE HONEST DISTINCTION, and the reason this arm exists. The other arm says the
      # window held nothing replayable — a fact about the CHAIN. That sentence was
      # published over a snapshot in which two mainnet transactions had been caught
      # inside the window with their bodies still served, and refused by the replay
      # runtime for a toolchain reason on this side of the wire. Reporting that as "no
      # transaction inside it was replayable" blames the chain for our own fault, and
      # tells a reader the opposite of what happened: the follower reached them in time.
      $refusedCount & " transaction(s) inside it WERE still replayable and were " &
      "caught in time, and the replay runtime refused " &
      (if refusedCount == 1: "it" else: "them") &
      (if refusalNames.len > 0: " (" & refusalNames.join(", ") & ")" else: "") &
      ", so no trace was recorded. That is a failure on the recording side, not a " &
      "property of this chain, and it is stated here rather than shown as an absence. " &
      "Across the " & $blockRows.len &
      " blocks enumerated here this chain settled " & $txCount &
      " transaction(s), and they did not arrive evenly: the longest run with " &
      "none was " & $largestGap & " blocks. "
    else:
      "NO TRANSACTION INSIDE IT WAS REPLAYABLE, so this chain publishes real " &
      "blocks and real transactions and no traces. That is what the capture " &
      "found, not a failure to record. Across the " & $blockRows.len &
      " blocks enumerated here this chain settled " & $txCount &
      " transaction(s), and they did not arrive evenly: the longest run with " &
      "none was " & $largestGap & " blocks, and " & recency &
      "Catching one needs a follower that watches the tip continuously rather " &
      "than a single scan. "
  # THE CURATED PARAGRAPH IS A SEPARATE ARM, NOT AN EDIT TO THE ONE ABOVE.
  #
  # Every sentence in `middle` is a claim about the ENUMERATED range, and under
  # `isCurated` the enumerated range is no longer what the page shows. Splicing a
  # window clause into it would leave "across the N blocks enumerated here" next
  # to a block list of 34, which is the shape of wrongness this module has
  # already published twice (a nine-hour-stale window, and a negative distance).
  # So the curated arm states the two ranges separately and says which is which:
  # what is PUBLISHED, and what was WATCHED to choose it out of.
  #
  # It also states the zero explicitly instead of relying on a universal over an
  # empty set. "Every transaction here opens a container" is true and useless of a
  # chain with no transactions on it, and a reader who counts zero rows under that
  # sentence has been told nothing.
  # WHY THE UNPUBLISHED ONES ARE UNPUBLISHED, SPLIT BY WHOSE FAULT IT WAS.
  #
  # "their bodies were pruned before anything could re-execute them" is a fact
  # about the CHAIN, and it is false of a refusal: a refused transaction was
  # reached inside the window with its body still served, and the replay runtime
  # declined. Merging the two blames the network for a fault on this side of the
  # wire — the exact sentence commit b7cafba had to replace on the uncurated
  # banner, and it would have come straight back here, because the curated arm
  # is a new paragraph and `refusedCount` counts only the PUBLISHED set, which
  # under curation can never contain a refusal at all.
  # ONE CLAUSE PER BUCKET, and the buckets are the outcomes rather than
  # "replayed" and "everything else". A single sentence over the remainder is
  # what merges a refusal into a pruning; three clauses cannot, and a fourth
  # outcome the capture starts emitting gets its own clause naming itself rather
  # than being absorbed into whichever neighbour reads closest.
  var observedPruned, observedRefused, observedOther = 0
  var observedRefusalNames, otherOutcomes: seq[string]
  for t in snap["transactions"]:
    let o = t["outcome"].getStr
    case o
    of "replayed", "divergent": discard
    of "pruned": inc observedPruned
    of "refused":
      inc observedRefused
      let rn = t{"refusal"}.getStr
      if rn.len > 0 and rn notin observedRefusalNames: observedRefusalNames.add rn
    else:
      inc observedOther
      if o notin otherOutcomes: otherOutcomes.add o
  let unpublished = observedPruned + observedRefused + observedOther
  var whyParts: seq[string]
  if observedRefused > 0:
    whyParts.add $observedRefused & " WERE still replayable when the capture " &
      "reached " & (if observedRefused == 1: "it" else: "them") &
      " and the replay runtime refused " &
      (if observedRefused == 1: "it" else: "them") &
      (if observedRefusalNames.len > 0: " (" & observedRefusalNames.join(", ") & ")"
       else: "") & ", which is a failure on the recording side and not a " &
      "property of this chain"
  if observedPruned > 0:
    whyParts.add $observedPruned & " had already been pruned when " &
      (if observedPruned == 1: "it was" else: "they were") & " first seen"
  if observedOther > 0:
    whyParts.add $observedOther & " carried another outcome (" &
      otherOutcomes.join(", ") & ")"
  let whyUnpublished =
    if unpublished == 0: ""
    else: " Of the " & $unpublished & " not published here, " &
          whyParts.join("; ") & "."
  let watched =
    "Over the whole watch — " & $observedBlocks & " blocks, " &
    $observedTransactions & " transaction(s), blocks " & $allHeights[0] & "–" &
    $allHeights[^1] & " — they did not arrive evenly: the longest run with none " &
    "was " & $largestGap & " blocks." & whyUnpublished
  let curatedMiddle =
    if withTrace > 0:
      "THIS CHAIN IS PUBLISHED AS A CURATED WINDOW. " & window.why & " All " &
      $txCount & " of them were re-executed and their traces are published " &
      "here; " & $blockRows.len & " blocks carry them. " & watched & " "
    else:
      "THIS CHAIN IS PUBLISHED AS A CURATED WINDOW, AND IT CONTAINS NO " &
      "TRANSACTION. " & window.why & " " & watched & " Catching one needs the " &
      "follower to reach a transaction while its body is still served, which is " &
      "a watch measured in hours rather than a scan. "
  let provDetail =
    captured & (if cfg.scope == isCurated: curatedMiddle else: middle) &
    "Transactions below block " & $finalizedAt & " are still visible on the " &
    "network but their bodies have been pruned, so they can no longer be " &
    "replayed and carry no trace."
  cfg.writeJson(summaryRel, %*{
    "chain": chain, "generation": gen,
    "counters": {"blocks": blockRows.len, "transactions": txCount},
    "coverageMode": "selective", "stale": false,
    "provenance": {
      "kind": "live-capture",
      "label": provLabel,
      "endpoint": prov["endpoint"],
      "capturedAt": prov["capturedAt"],
      "nodeVersion": prov["nodeVersion"],
      "l1ChainId": prov["l1ChainId"],
      "tipAtCapture": tipAt,
      "finalizedAtCapture": finalizedAt,
      "replayableWindowBlocks": win["blocks"],
      "tracesPublished": withTrace,
      "mostRecentTxBlock": mostRecentTxBlock,
      "longestRunWithoutTx": largestGap,
      # THE SCOPE AND ITS TWO RANGES, AS DATA. `detail` says all of this in
      # prose because a banner has to read as a sentence, but a consumer that
      # wanted the numbers would otherwise have to parse that sentence — and
      # `test_explorer_breadth`'s scanners already demonstrate what happens when
      # a check has to read prose to learn a fact. The published set and the set
      # it was chosen out of are both here, so "is this chain curated, and out of
      # what" is answered by the tree.
      "scope": $cfg.scope,
      "publishedWindow": {"from": window.lo, "to": window.hi},
      "observedBlocks": observedBlocks,
      "observedTransactions": observedTransactions,
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

  IngestResult(chain: chain, scope: cfg.scope,
               blocks: blockRows.len, transactions: txCount,
               withTrace: withTrace, divergent: divergentCount,
               pruned: prunedCount, containerBytes: totalContainerBytes,
               observedBlocks: observedBlocks,
               observedTransactions: observedTransactions,
               windowFrom: window.lo, windowTo: window.hi)
