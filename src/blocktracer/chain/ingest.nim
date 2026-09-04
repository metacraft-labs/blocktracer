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

import std/[json, os, algorithm, strutils, tables, times]
import ../contract/[model, ids, version]

const MonthNames = ["January", "February", "March", "April", "May", "June",
                    "July", "August", "September", "October", "November",
                    "December"]

proc readableDate*(iso: string): string =
  ## `2026-09-01T07:13:35.934Z` → `1 September 2026`.
  ##
  ## The banner is read by visitors. An ISO-8601 instant with milliseconds and a
  ## `Z` is a machine's way of writing a date, and it was being printed twice in
  ## one sentence on a paragraph whose whole job is to be understood. The exact
  ## instant is not lost: `summary.json` keeps `capturedAt` verbatim, which is
  ## where a check or a reader who wants the millisecond should read it.
  ##
  ## Anything that does not parse is returned unchanged rather than guessed at —
  ## a date this proc cannot read is a date it must not invent.
  if iso.len < 10: return iso
  try:
    let y = parseInt(iso[0 .. 3])
    let m = parseInt(iso[5 .. 6])
    let d = parseInt(iso[8 .. 9])
    if m < 1 or m > 12 or d < 1 or d > 31: return iso
    result = $d & " " & MonthNames[m - 1] & " " & $y
  except ValueError:
    return iso

proc readableSpan*(firstUnix, lastUnix: int64): string =
  ## The timespan a block record covers, written the way `readableDate` writes a
  ## date: `30 August to 1 September 2026`, or `31 August 2026` when both ends
  ## fall on one day.
  ##
  ## THE SNAPSHOT'S BLOCKS CARRY UNIX SECONDS, NOT ISO, so this is a second entry
  ## point to the same words rather than a second format — a page that wrote the
  ## capture's dates one way and the coverage another would read as two products.
  ##
  ## THE YEAR IS PRINTED ONCE WHEN BOTH ENDS SHARE IT. `30 August 2026 to 1
  ## September 2026` is the same fact said with a redundancy a person does not
  ## write, and this sentence is read by visitors.
  ##
  ## The ends are ordered here rather than trusted from the caller: a block
  ## record is sorted by height, and height is not time on a chain that ever
  ## reorged. A span printed backwards is the shape of wrongness this module has
  ## published before (a negative block distance) and it costs one comparison.
  let lo = utc(fromUnix(min(firstUnix, lastUnix)))
  let hi = utc(fromUnix(max(firstUnix, lastUnix)))
  let loDay = $lo.monthday & " " & MonthNames[ord(lo.month) - 1]
  let hiDay = $hi.monthday & " " & MonthNames[ord(hi.month) - 1]
  if lo.year == hi.year:
    if loDay == hiDay: loDay & " " & $hi.year
    else: loDay & " to " & hiDay & " " & $hi.year
  else:
    loDay & " " & $lo.year & " to " & hiDay & " " & $hi.year

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
                     recorded, traceless: seq[int];
                     positioned: seq[int] = @[]): CurationWindow =
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
    # WHICH RUN, AND THE ORDER OF THE THREE QUESTIONS. `positioned` names the
    # heights whose recording resolves to SOURCE — real (path, line, column) on
    # its steps — and a run holding one wins over a run that does not, however
    # many more recordings that other run has.
    #
    # This is a refinement of "most recordings wins", not a weakening of it. The
    # invariant is untouched: runs are still delimited by the traceless
    # transactions, every transaction in the chosen window still opens a
    # container that steps, and `ingestSnapshot` still re-checks that over what
    # it is about to write. What changes is only WHICH satisfying run is
    # published, and the count was always a proxy for "the richest exhibit"
    # rather than a value in itself.
    #
    # It was measured deciding the wrong way. The 2026-09-02 testnet capture
    # recorded twenty transactions in two runs split by a refusal at 67019:
    # three below it — including 0x20ed5b91…, the only transaction this
    # repository has ever captured from a real chain that positions steps
    # against real Noir — and sixteen above it, every one of them rung 3 over a
    # contract with no published artifact. Sixteen beat three, so the site
    # published the sixteen and dropped the one thing a visitor could open the
    # source of. A demo choosing the larger pile of identical bytecode listings
    # over its only source-level recording is the count being read as the goal.
    var bestKey = ""
    var bestCount = 0
    var bestHi = 0
    var bestSource = false
    var isPositioned = initTable[int, bool]()
    for h in positioned: isPositioned[h] = true
    for key in order:
      let hs = runs[key]
      var hi = hs[0]
      var hasSource = false
      for h in hs:
        hi = max(hi, h)
        if isPositioned.getOrDefault(h, false): hasSource = true
      # Source first; then most recordings; then the newest breaks the tie.
      let better =
        if hasSource != bestSource: hasSource
        elif hs.len != bestCount: hs.len > bestCount
        else: hi > bestHi
      if bestKey.len == 0 or better:
        bestKey = key
        bestCount = hs.len
        bestHi = hi
        bestSource = hasSource
    var lo = bestHi
    for h in runs[bestKey]: lo = min(lo, h)
    result = CurationWindow(lo: lo, hi: bestHi, found: true,
      why: "This chain publishes the blocks its recordings span — blocks " &
           $lo & "–" & $bestHi & " — so that every transaction on it opens a " &
           "container that steps." &
           (if bestSource:
              " This span was chosen over a longer one because a transaction " &
              "in it resolves to source."
            else: ""))
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

  # ---- the artifact-resolution SIDECAR, if this capture has one -------------
  #
  # WHAT IT IS FOR. Every transaction in `client/fixtures/chain/` was captured by a runtime
  # that predates off-chain artifact resolution, so its recording carries no
  # `ct.source-provenance` at all and every one of them publishes `Not checked` — "nobody
  # looked". Re-capturing to answer the question is impossible and permanently so: the bodies
  # are pruned at the finalized tip (CHAIN-CAPTURE.md §1). So the question is asked WITHOUT
  # the transaction, against contract instances and classes the node still serves, by
  # `tools/chain/resolve-frozen-artifacts.mjs --write` — which uses the resolver the driver
  # itself calls and writes its answer BESIDE the frozen capture rather than into it.
  #
  # WHAT IT MAY NOT DO, and these are the load-bearing restrictions:
  #
  #   * It may not touch `sourceLevel` or cause a source bundle to be written. A resolution
  #     says an artifact is PROVABLE; a source-level RECORDING additionally requires the step
  #     stream to have been written against that artifact's debug map, which needs the body.
  #     `measuredSourceLevel` below reads the snapshot and only the snapshot.
  #   * It may not override a capture that recorded its own answer. A real
  #     `ct.source-provenance` is the measurement taken at the moment of execution; a
  #     post-hoc one is an answer about the class today. Where both exist the capture wins,
  #     and this is a `notin` test rather than a merge for exactly that reason.
  #   * It may not arrive anonymously. The published entries are marked `measuredPostHoc`
  #     and the tree records when and by which resolver, so a reader is never asked to
  #     believe a capture recorded something it did not.
  var postHoc = initTable[string, JsonNode]()
  var postHocPositions = initTable[string, JsonNode]()
  var postHocMeasuredAt = ""
  var postHocResolver = ""
  let sidecarPath = cfg.snapshotDir / "artifact-resolution.json"
  if fileExists(sidecarPath):
    let side = parseJson(readFile(sidecarPath))
    if side{"format"}.getStr != "blocktracer/artifact-resolution@1":
      raise newException(ValueError,
        "unsupported artifact-resolution format '" & side{"format"}.getStr &
        "' at " & sidecarPath & "; this build reads blocktracer/artifact-resolution@1")
    # A SIDECAR FROM ANOTHER CHAIN IS A REFUSAL, NOT A SKIP. Applying one silently would
    # attach one chain's resolution answers to another chain's transactions — invisible in
    # the tree, and wrong in the direction that invents evidence.
    if side{"chain"}.getStr != chain:
      raise newException(ValueError,
        sidecarPath & " resolves chain '" & side{"chain"}.getStr & "' but this snapshot is '" &
        chain & "'; refusing to attach one chain's resolution to another's transactions")
    postHocMeasuredAt = side{"measuredAt"}.getStr
    postHocResolver = side{"measuredBy"}{"runtimeCommit"}.getStr
    for e in side{"transactions"}:
      let h = e{"txHash"}.getStr
      let arts = e{"artifacts"}
      # `null` is the tool's own "this run did not finish asking" and stays unanswered here,
      # which lands the row on `Not checked` — the same honest outcome as no sidecar at all.
      if h.len > 0 and arts != nil and arts.kind == JArray:
        postHoc[h] = arts
      # POSITIONS ARE SEPARATE FROM THE RESOLUTION AND ARRIVE SEPARATELY. A resolution can
      # succeed and position nothing (the artifact keys no pc this execution walked), and the
      # tool writes `positions: null` or an `unavailable` reason for that. Only a column set
      # that actually positioned a step is carried forward; the rest is not a lesser answer to
      # the same question, it is an answer to a question with no rows in it.
      let pos = e{"positions"}
      if h.len > 0 and pos != nil and pos.kind == JObject and
         pos{"positioned"}.getInt(0) > 0:
        postHocPositions[h] = pos
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
  # `time` IS CARRIED ON THE ROW, and it is the only field here that no
  # published file reads. `BlockDetail` has no timestamp — the block list says
  # so in its Age column — so this exists for one consumer: the coverage span in
  # "About this data". It rides on the row rather than being looked up later
  # because the span has to be measured over THE PUBLISHED SET, and the
  # published set is this seq after the curation narrowing below. A second
  # height→time table read afterwards would be a second answer to "which blocks
  # is this about", which is the disagreement the curated/uncurated arms used to
  # institutionalise.
  var blockRows: seq[tuple[hash: string, height: int, parent: string,
                           txs: seq[string], time: int64]]
  var byHeight = initTable[int, string]()
  for b in snap["blocks"]:
    let h = b["number"].getInt
    var txs: seq[string]
    for t in b["transactions"]: txs.add t.getStr
    blockRows.add (b["hash"].getStr, h, b["parentArchiveRoot"].getStr, txs,
                   b{"timestamp"}.getBiggestInt)
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
  var recordedHeights, tracelessHeights, positionedHeights: seq[int]
  for t in snap["transactions"]:
    let o = t["outcome"].getStr
    if o == "replayed" or o == "divergent":
      recordedHeights.add t["blockNumber"].getInt
      # READ OFF THE CAPTURE'S OWN MEASUREMENT and nothing else — the same field
      # `reader.sourcesView` reads, for the same reason. A post-hoc artifact
      # resolution can prove a class's source without the recording having
      # positioned a single step, and a window chosen on that would publish a
      # block whose transaction still opens a bytecode listing.
      if t{"recording"}{"stepsPositioned"}.getInt(0) > 0:
        positionedHeights.add t["blockNumber"].getInt
    else: tracelessHeights.add t["blockNumber"].getInt
  var allHeights: seq[int]
  for b in blockRows: allHeights.add b.height
  var window = CurationWindow(lo: (if allHeights.len > 0: allHeights[0] else: 0),
                              hi: (if allHeights.len > 0: allHeights[^1] else: 0),
                              found: true, why: "")
  if cfg.scope == isCurated:
    window = curationWindow(allHeights, recordedHeights, tracelessHeights,
                            positionedHeights)
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
    # THE CAPTURE'S OWN RECORD FIRST, the sidecar only where there is none. `artifactsOf` is
    # the one place that choice is made, so the code edges and the published summary below
    # cannot come to disagree about which array they were built from.
    let capturedArtifacts =
      if t{"artifacts"} != nil and t["artifacts"].kind == JArray: t["artifacts"]
      else: nil
    let postHocArtifacts =
      if capturedArtifacts == nil and txHash in postHoc: postHoc[txHash]
      else: nil
    let artifactsOf =
      if capturedArtifacts != nil: capturedArtifacts else: postHocArtifacts

    var codeEdges: seq[CodeEdge]
    if artifactsOf != nil:
      for a in artifactsOf:
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
    #
    # AND THE ABSENT RECORD IS NULL, NOT THE EMPTY LIST. `ct.source-provenance`
    # is written into every recording the current runtime produces, resolved or
    # not, precisely so that its ABSENCE is never ambiguous — a snapshot with no
    # `artifacts` key is one taken before the runtime could resolve artifacts at
    # all, which is a different fact from a snapshot that looked and found the
    # transaction executed no contract code. This block used to publish `[]` for
    # both and so destroyed, one layer down, exactly the distinction the
    # recording had gone to the trouble of carrying: a consumer could no longer
    # tell "nobody looked" from "looked, nothing to look at", and a badge derived
    # from it would have had to guess. `null` for the first, `[]` for the second.
    #
    # AND A POST-HOC ANSWER SAYS SO, PER ENTRY. `measuredPostHoc` is written on every entry
    # rather than once per transaction because the entries are what a consumer folds and
    # what a reviewer quotes; a flag one level up is a flag that gets separated from the
    # claim it qualifies. It is `false` on a capture's own record, not absent, so the two
    # are distinguishable without knowing which snapshots have sidecars.
    var artifactSummary = newJNull()
    if artifactsOf != nil:
      let isPostHoc = postHocArtifacts != nil
      artifactSummary = newJArray()
      for a in artifactsOf:
        artifactSummary.add %*{
          "address": orNull(a{"address"}),
          "contractClassId": orNull(a{"contractClassId"}),
          "resolved": a{"resolved"}.getBool,
          "origin": orNull(a{"origin"}),
          "corroboration": orNull(a{"corroboration"}),
          "measuredPostHoc": %isPostHoc}

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
        "artifacts": artifactSummary,
        # WHEN THE RESOLUTION WAS MEASURED, AND BY WHAT. Present only where the answer came
        # from the sidecar, so its absence means the capture recorded its own — the same
        # absence-is-informative discipline `artifacts: null` follows one field up.
        #
        # This is what keeps `sourceLevel: false` beside `artifacts[].resolved: true` from
        # reading as a contradiction. It is not one: the artifact is provable TODAY, and the
        # recording was written by a runtime that never asked. Both facts are true, they are
        # about different moments, and the tree now carries the moment.
        "artifactsMeasuredAt":
          (if postHocArtifacts != nil and postHocMeasuredAt.len > 0:
             %postHocMeasuredAt else: newJNull()),
        "artifactsMeasuredByRuntime":
          (if postHocArtifacts != nil and postHocResolver.len > 0:
             %postHocResolver else: newJNull())}

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
      # A BUNDLE IS PUBLISHED FOR A PARTLY-POSITIONED RECORDING TOO, AND THAT IS NEW.
      #
      # It used to be `if measuredSourceLevel`, which is the capture's own all-or-nothing
      # measurement: every executed step of every contract positioned. That gate is right
      # about what it gates — it decides whether the manifest may CLAIM source level — and
      # it was also, by accident, the only way any source text reached the tree. So a
      # recording that positions 86 of its 108 steps published no text at all, and its
      # source pane showed a bytecode listing over a contract whose source is on npm.
      #
      # The two questions are now separate. `measuredSourceLevel` still decides the CLAIM
      # and is still read from the capture and nowhere else. This decides whether there is
      # TEXT to put behind the positions, and the answer is yes exactly when some step has
      # a position to put in it.
      let hasPostHocPositions = txHash in postHocPositions
      # …AND A THIRD WAY IN, which is the one a LIVE capture takes. The two arms
      # above are "the capture measured every step positioned" and "a post-hoc
      # tool computed positions for a container that recorded none". Neither
      # describes a recording that positioned MOST of its steps while it ran —
      # `sourceLevel` is false, so the first declines, and nothing about it is
      # post-hoc, so the second does not apply. That is exactly the 2026-09-02
      # testnet capture: 86 of 108 steps positioned against a proved FeeJuice
      # artifact, a 32-file Noir bundle sitting in `sources/` beside it, and not
      # one byte of it reaching the tree.
      #
      # Publishing the text is not a claim that every step is positioned. The
      # claim stays where it was — `measuredSourceLevel`, read from the capture
      # — and this only answers "is there text to put behind the positions this
      # recording does have".
      # The row names the file; the conventional path is the fallback, so a
      # capture written before the row carried the key still resolves.
      var srcRel = t{"sourceBundles"}.getStr
      if srcRel.len == 0: srcRel = "sources" / (txHash & ".json")
      let srcPath = cfg.snapshotDir / srcRel
      # …AND A THIRD WAY IN, which is the one a LIVE capture takes. The two arms
      # above are "the capture measured every step positioned" and "a post-hoc
      # tool computed positions for a container that recorded none". Neither
      # describes a recording that positioned MOST of its steps while it ran —
      # `sourceLevel` is false, so the first declines, and nothing about it is
      # post-hoc, so the second does not apply. That is exactly the 2026-09-02
      # testnet capture: 86 of 108 steps positioned against a proved FeeJuice
      # artifact, a 32-file Noir bundle sitting in `sources/` beside it, and not
      # one byte of it reaching the tree.
      #
      # Publishing the text is not a claim that every step is positioned. The
      # claim stays where it was — `measuredSourceLevel`, read from the capture
      # — and this only answers "is there text to put behind the positions this
      # recording does have".
      #
      # IT REQUIRES THE BUNDLE TO EXIST RATHER THAN DEMANDING THAT IT SHOULD,
      # which is the one asymmetry between this arm and the two above it. Those
      # two are entered by a CLAIM — a capture that said "source level", a tool
      # that said "here are coordinates" — and a claim with no text behind it is
      # a producer that is broken, so they refuse. This arm is entered by a
      # MEASUREMENT, and `stepsPositioned > 0` says nothing about whether anyone
      # shipped source: a capture is perfectly entitled to count the steps it
      # placed and publish no bundle, and every such recording rendered a
      # correct instruction-level page before this arm existed and must go on
      # doing so. Raising there would turn a new capability into a new way for
      # an old snapshot to fail its build — which is exactly what it did, on
      # suite 13's fixture, before this line read as it does.
      # ── WHICH PER-STEP POSITION STREAM, RESOLVED BEFORE ANYTHING USES IT ──────
      # Hoisted above the bundle block because the bundle's own gate depends on
      # it: text is published exactly when there are positions to point into it,
      # and that question cannot be answered after the text has been written.
      #
      # The CAPTURE'S OWN STREAM OUTRANKS THE RECONSTRUCTION. A container
      # recorded at rung 2 or better wrote `(path, line)` on every step it could
      # place, while the session was running and against an artifact it had
      # already proved — `derive-positions.mjs` reads that out into
      # `positions/<txHash>.json`. There is nothing post-hoc about it, so where
      # both exist the recorded one wins and `measuredPostHoc` follows the file
      # rather than being hard-coded true as it was when only one producer
      # existed.
      var posSource: JsonNode = nil
      var posIsPostHoc = true
      let capturedPosPath = cfg.snapshotDir / "positions" / (txHash & ".json")
      if fileExists(capturedPosPath):
        posSource = parseJson(readFile(capturedPosPath))
        posIsPostHoc = posSource{"measuredPostHoc"}.getBool
      elif txHash in postHocPositions:
        posSource = postHocPositions[txHash]

      # …AND IT REQUIRES A POSITION STREAM, not merely a non-zero count. The
      # count says the RECORDING placed steps; it does not say this tree can
      # show where. A transaction that entered two contracts has no publishable
      # stream at all — `resolve-frozen-artifacts.mjs` refuses to attribute a pc
      # when the step stream does not say which contract executed it — so a
      # count-only gate published a `/src` subtree and a `sourceBundles` entry
      # that nothing could ever point into. Text with no positions behind it is
      # the mirror of the refusal ten lines down, and just as wrong.
      let capturedPositions = t{"recording"}{"stepsPositioned"}.getInt(0) > 0 and
                              posSource != nil
      if measuredSourceLevel or hasPostHocPositions or
         (capturedPositions and fileExists(srcPath)):
        # THE REASON IS NAMED, because there are now two ways to get here and they are
        # different facts. A capture that MEASURED source level and shipped no bundle is a
        # broken capture; a post-hoc positioning with no text is a tool that computed
        # coordinates into files it did not carry. Both are refusals and neither is the
        # other's diagnosis.
        let why =
          if measuredSourceLevel:
            "the capture measured " & txHash & " as source level"
          elif capturedPositions:
            "the capture positioned " &
            $t{"recording"}{"stepsPositioned"}.getInt(0) & " step(s) of " & txHash
          else:
            "source positions were computed for " & txHash
        if not fileExists(srcPath):
          raise newException(ValueError,
            why & " and this snapshot carries no source bundle for it (looked for " &
            srcRel & "); refusing to publish positions with no text to put behind " &
            "them, which would put the debugger's source pane on a file it cannot fetch")
        let srcDoc = parseJson(readFile(srcPath))
        let bundleList = srcDoc{"bundles"}
        if bundleList == nil or bundleList.kind != JArray or bundleList.len == 0:
          raise newException(ValueError,
            why & " and its source bundle file " & srcRel & " carries no bundle; " &
            "refusing to publish positions with no text to put behind them, which " &
            "would put the debugger's source pane on a file it cannot fetch")
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

      # ---- POSITIONS: the source coordinate per step, where one was computed ----
      #
      # A SIBLING OF THE LISTING, AND FOR THE LISTING'S REASONS. `instructions.json`
      # established the shape: a per-step parallel-array sidecar beside the container,
      # derived offline because the site build is hermetic, absent-is-valid, and refused
      # at publish time if its length disagrees with the recording. This is the same
      # object with `pathId`/`line`/`column` instead of `pc`/`op`, and it exists because
      # the coordinate it carries cannot be got any other way: the container's steps were
      # never written against a source map, and the transaction bodies that would let one
      # be re-recorded are pruned.
      #
      # WHAT IT IS NOT. It is not a claim that the recording is source level. It is the
      # result of joining the pcs the container DID carry with a map from an artifact
      # proved against the chain's commitment to the class — `resolve-frozen-artifacts.mjs`
      # does the join with the recorder's own `ContractSourceMap`. `sourceLevel` is
      # untouched by it and stays what the capture measured.
      if posSource != nil:
        let pos = posSource
        let carried = pos{"steps"}.getInt(-1)
        let declared = t["recording"]["steps"].getInt
        # THE SAME REFUSAL THE LISTING MAKES, for the same defect: a position array of a
        # different length puts a source line against the wrong step, and every surface
        # involved would go on reporting success.
        if carried != declared:
          raise newException(ValueError,
            "the source positions for " & txHash & " hold " & $carried &
            " steps and the recording declares " & $declared &
            "; refusing to publish positions the steps cannot be located in")
        for col in ["pathId", "line", "column"]:
          let a = pos{col}
          if a == nil or a.kind != JArray or a.len != declared:
            raise newException(ValueError,
              "the source positions for " & txHash & " carry a '" & col &
              "' column of " & (if a == nil: "nothing" else: $a.len) &
              " against " & $declared & " steps; a partial column would mark " &
              "rows it was never measured for")
        cfg.writeJson(dir / "positions.json", %*{
          "schema": "avm-source-positions/1",
          "tx": txHash,
          "steps": carried,
          "positioned": pos{"positioned"},
          # THE ARTIFACT'S RUNG BESIDE THE RECORDING'S, because they differ here and the
          # difference is the whole finding: the artifact maps every pc it keys, and this
          # recording walks 22 the artifact does not key.
          "artifactRung": orNull(pos{"artifactRung"}),
          "measuredPostHoc": posIsPostHoc,
          "measuredAt": (if posIsPostHoc and postHocMeasuredAt.len > 0:
                           %postHocMeasuredAt else: newJNull()),
          "paths": pos{"paths"},
          "pathId": pos{"pathId"},
          "line": pos{"line"},
          "column": pos{"column"}})

      # ---- CALL FRAMES: what called what ------------------------------------
      #
      # THE THIRD SIDECAR, AND THE ONE THAT CORRECTS A RECORDED MISTAKE.
      # CHAIN-CAPTURE.md §6.6 held that the Call Trace pane is empty on the
      # served page because "the site build is hermetic and cannot depend on
      # codetracer-trace-format-nim". Every clause was true and the conclusion
      # did not follow: the two sidecars ABOVE THIS ONE are also read out of a
      # `.ct` by a reader this build does not have, and they reach the page
      # because the read happens by hand, ahead of the build, and the result is
      # committed. Nobody had pointed that mechanism at the frames.
      #
      # So this is `instructions.json`'s shape a third time — derived offline,
      # absent-is-valid, refused at publish time if it disagrees with the
      # capture — and the build is exactly as hermetic as it was before.
      #
      # THE REFUSAL IS AGAINST `callsOpened`, WHICH IS THE MANIFEST'S OWN
      # NUMBER. `execution.frames` a few lines below is written from that same
      # field, so a stream that disagreed with it would put a pane rendering N
      # rows beside a manifest declaring M — two producers of one answer, which
      # is the defect that put an empty pane next to `frames: 1` in the first
      # place. `<toplevel>` is the synthetic frame the recorder opens to hold
      # the enqueued calls and is not counted by `callsOpened`, hence the + 1.
      let ctFile = cfg.snapshotDir / "calltrace" / txHash & ".json"
      if fileExists(ctFile):
        let cf = parseJson(readFile(ctFile))
        let declaredCalls = t["recording"]{"callsOpened"}.getInt
        let carriedFrames = cf{"frames"}.getInt(-1)
        if carriedFrames != declaredCalls + 1:
          raise newException(ValueError,
            "the call trace for " & txHash & " holds " & $carriedFrames &
            " frame(s) and the recording declares callsOpened=" &
            $declaredCalls & "; refusing to publish a call trace the " &
            "manifest's own frame count contradicts")
        let arr = cf{"frame"}
        if arr == nil or arr.kind != JArray or arr.len != carriedFrames:
          raise newException(ValueError,
            "the call trace for " & txHash & " declares " & $carriedFrames &
            " frame(s) and carries " &
            (if arr == nil: "no" else: $arr.len) & " of them")
        cfg.writeJson(dir / "calltrace.json", cf)

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
  # THE ARRIVAL-DENSITY NUMBERS ARE STILL MEASURED, AND THEY ARE NO LONGER PROSE.
  #
  # `longestRunWithoutTx` and `mostRecentTxBlock` below were computed for a
  # sentence the banner used to carry, and the reason they are measured rather
  # than averaged is worth keeping where they are: the obvious thing to publish
  # is a RATE — "one transaction per N blocks against an M-block window" — and it
  # would have been wrong on the first mainnet capture in the confident
  # direction. That capture found 20 transactions in 400 blocks, which as a rate
  # predicts roughly one catch per 25-block window; it caught none, because the
  # arrivals are BURSTY (18 of the 20 inside a 53-block span, then nothing for
  # 309 blocks). They stay in `summary.json`, where a consumer that wants them
  # can read them without a page having to narrate them.
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

  # The label a reader sees on the banner and on the home page's chain strip.
  # The capture supplies it; this is a fallback for a snapshot that named none,
  # and it deliberately does NOT try to prettify the slug beyond saying the data
  # is real — an invented display name is a claim nobody measured.
  let provLabel =
    if prov{"label"}.getStr.len > 0: prov["label"].getStr
    else: "Real chain data"

  let summaryRel = "d" / chain / "g" / gen / "summary.json"

  # ── WHAT THIS DATA IS, IN THREE FACTS AND NOTHING ELSE ─────────────────────
  #
  # A user read the previous version and asked for exactly this: say the data is
  # real, say it is limited to a preliminary export, and cite the timespan that
  # is covered. The word in the request was "just" — a section to SHRINK, not to
  # rewrite at the same length — so what follows is one pair of short sentences
  # and no arms.
  #
  # WHAT WENT, AND WHERE IT WENT INSTEAD. Four generated paragraphs: a capture
  # date, a per-outcome middle clause (how many were re-run, or how many the
  # runtime refused "because of a fault on our side", or that none was reached in
  # time), a curated clause naming the published window and the watch it was
  # chosen out of, and a pruning sentence naming the finalized boundary. Every
  # one of them was true. None of them is what a visitor arrives asking, and the
  # last three restate — with different numbers — what the block list, the
  # transaction list and each transaction's own page already say at the point the
  # reader meets them. The facts stay published beside this in `summary.json`
  # (`capturedAt`, `tracesPublished`, `publishedWindow`, `observedBlocks`,
  # `observedTransactions`, `finalizedAtCapture`, `longestRunWithoutTx`), which is
  # where a consumer that wants them should read them.
  #
  # THERE IS NO SCOPE BRANCH AND NO OUTCOME BRANCH ANY MORE. A reader's question
  # is the same whichever way this build was configured, and the two arms this
  # module used to carry are the mechanism by which a page came to describe a
  # chain in numbers that disagreed with the counts above them. One expression
  # over the published set answers for every scope: a curated build states a
  # narrower span than a full one because it publishes less, not because a second
  # arm was written to say so.
  #
  # WHAT "REAL" IS ALLOWED TO MEAN HERE. Taken from the live network — that, and
  # deliberately not a word more. It does not claim the export is complete (it is
  # not: this says so), and it does not claim a transaction can be read against
  # its sources.
  #
  # THE PARENTHETICAL THAT USED TO JUSTIFY THE SECOND HALF IS NOW FALSE, and it
  # is removed rather than edited: it read "it cannot: every published recording
  # is at instruction level". One is not. Testnet 0x20ed5b91… positions 86 of its
  # 108 steps against a proved FeeJuice artifact and opens on real Noir
  # (CHAIN-CAPTURE.md §6.5). The RULE is unchanged and is if anything better
  # founded now — silence here is right precisely because source is the exception
  # and not the rule, so a banner sentence about it would generalise one
  # transaction to a chain. What changed is that the silence can no longer be
  # defended by saying there is nothing to be silent about. Where a transaction
  # does resolve, the place that says so is that transaction's own row and its
  # own page, which is where a reader meets the claim they can check.
  #
  # A sentence that implied either would be the confident-but-wrong answer this
  # site exists to avoid. The chain's own name is not repeated because the label
  # beside this — `provLabel`, "Real Aztec mainnet data" — is always rendered
  # with it: the chip on a list page, the `Data` row on a transaction and in the
  # debugger, and the prefix of this very paragraph on the chain overview.
  #
  # THE SPAN IS THE PUBLISHED SLICE'S, MEASURED OVER `blockRows`. `capturedAt` is
  # one instant at one end of a watch and was the only date this section used to
  # carry, which told a reader when the reading stopped and nothing about what
  # period the data covers. The ends come from the timestamps the blocks
  # themselves carry, so the sentence and the `Blocks` stat above it are two
  # views of ONE set rather than two facts about two.
  #
  # THIS WAS `snap["blocks"]` FOR ONE COMMIT AND IT WAS THE WRONG SET. The
  # reasoning for it — the subject of "preliminary export" is the export, so
  # quote the export's own ends — is coherent and it loses to the reader:
  # "covered" is covered by what is in front of them. On `/aztec` that is 170
  # blocks, and a span belonging to the 1563 the snapshot enumerated overstates
  # it nearly tenfold while naming days the reader cannot browse to. "Preliminary
  # export" already says this is a slice; the dates have to say WHICH slice or
  # they say nothing anyone can act on.
  #
  # It is also, more seriously, the disagreement this whole change deleted,
  # re-entering through the back door. The curated and uncurated arms existed
  # because a claim about the published set is false of the enumerated set and
  # the reverse, and that is exactly what a span over the enumerated set printed
  # above a count of the curated one is. `curationWindow` narrows to a contiguous
  # height range and `blockRows` is narrowed to it in place, so measuring the
  # rows costs nothing and cannot drift from what the page lists.
  #
  # AND IT IS MEASURED UNCONDITIONALLY, WITH NO SCOPE TEST. Under `isFull` the
  # narrowing is a no-op and these rows ARE the enumerated set, so one expression
  # gives both answers. A `if cfg.scope == isCurated` here to pick which set to
  # measure would be a third arm of precisely the kind just removed.
  #
  # min/max over the rows rather than the first and last of them: `blockRows` is
  # sorted by HEIGHT, and height is not time on a chain that ever reorged.
  var firstBlockAt, lastBlockAt = int64(0)
  for b in blockRows:
    if b.time <= 0: continue
    if firstBlockAt == 0 or b.time < firstBlockAt: firstBlockAt = b.time
    if b.time > lastBlockAt: lastBlockAt = b.time
  # A snapshot whose blocks carry no readable time gets no span rather than an
  # invented one — the same rule `readableDate` follows for a date it cannot
  # parse. The claim that survives is the one that needs no clock.
  let provDetail =
    if lastBlockAt > 0:
      "Blocks and transactions taken from the live network. This is a " &
      "preliminary export covering " & readableSpan(firstBlockAt, lastBlockAt) & "."
    else:
      "Blocks and transactions taken from the live network. This is a " &
      "preliminary export."

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
