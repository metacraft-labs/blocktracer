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
import ../contract/[model, ids, version, identifier_encoding]
import ./refusal_reasons
import ./snapshot_format
import ./contract_rules

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
  # SIX FACTS USED TO BE SPELLED HERE AND ARE NOW READ, and what is left says
  # why the two that remain are not among them.
  #
  # The recorder's identity, the trace schema it writes, the language a source
  # bundle's positions are in, the cost vector, the prestate strategy and the
  # execution selector were all constants in this block or beside their use. Each
  # was a fact about ONE chain compiled into the consumer of every chain, so a
  # second producer would have had to OVERWRITE them rather than supply them —
  # and two of the six fail silently rather than loudly. Cost is a VECTOR, and a
  # single entry built here with a fixed name, unit and token cannot express a
  # chain with two fee dimensions; what it produces instead is a page that looks
  # right and states the wrong cost. The execution selector was one fixed value
  # at four sites, so a chain whose transactions hold two independently
  # debuggable executions collapsed into one unnamed one. All six now come out of
  # the snapshot, and the reader refuses a snapshot that states none rather than
  # choosing on a producer's behalf.
  #
  # THESE TWO ARE NOT CHAIN FACTS, which is why they stay. `profileName` is the
  # recording PROFILE this build asks for — a property of how we record, not of
  # what we record — and `tsv` is the version of our own TraceSelection overlay
  # layer (§2.3b), which is this tree's publication format and not a chain's.
  # Neither names a chain, a VM, a fee token or a language, and neither would be
  # different for a second chain ingested by this same build.
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

proc writeSourceBundle(cfg: IngestConfig, chain, codeHash, provider, language: string,
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
    # THE LANGUAGE IS THE BUNDLE'S OWN AND IS NOT NAMED HERE. It used to be a
    # constant in this module — the language of a contract compiled by one
    # ecosystem's toolchain, asserted over every bundle of every chain — so a
    # bundle and the language it was published under could not be checked against
    # each other, because only one of them existed. It now travels with the
    # bundle that carries the positions the language describes, which is the one
    # place the two cannot disagree.
    #
    # AND AN UNSTATED LANGUAGE IS PUBLISHED UNSTATED. A bundle whose producer
    # names no language publishes none and the manifest beside it claims none
    # (see `bundleLanguages` at the call site). Naming one here on the producer's
    # behalf is the defect this replaces, one indirection further in.
    "language": language,
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
    RuleChainUnique &
    "the slug '" & slug & "' is already published in this tree by a '" & incumbent &
    "' chain (see " & (outDir / "d" / slug / "current.json") & "), and a '" &
    claimantKind & "' chain is claiming it. Two chains at one " &
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
    raise newException(IOError, RuleSnapshotPresent & "chain snapshot not found: " & snapPath)
  let snap = parseJson(readFile(snapPath))
  # ── THE VERSION GATE, AGAINST AN ENUMERATED SET RATHER THAN ONE LITERAL ────
  #
  # This was `!= "blocktracer/chain-snapshot@1"` against a literal spelled here
  # and at nine other sites. What that could not express is what happened: ING-3
  # made `refusalReason` MANDATORY on every untraced row — `auditRefusals` refuses
  # a snapshot without it, in the write path of every producer — while the token
  # stayed `@1`. The proof it is not an additive change, which is all §3 permits
  # inside one version, is that `tools/chain/migrate-refusal-reasons.mjs` had to be
  # written: the committed `@1` captures could not pass the gate their own
  # producers now run. So `@1` named two incompatible shapes and nothing in an
  # artifact could say which.
  #
  # `@1` IS STILL READ, AND READ WHOLE. §3's rule is that a version the reader
  # does not SUPPORT is refused by name rather than misread, and §5.2's that an
  # unknown token is never partially read. `@1` is enumerated in
  # `tools/chain/snapshot-format.json` and every member of it is consumed here —
  # the one member `@2` adds is the one this reader already treated as optional
  # (see the `rr` block below). Nothing is skipped and nothing is guessed. A token
  # outside the list is refused by name, naming what this build does accept.
  #
  # The difference the token makes is enforced rather than advertised: on `@2` an
  # untraced row without a `refusalReason` raises, naming the row. A version whose
  # only difference the reader does not act on is a label.
  let snapFormat = snap{"format"}.getStr
  if not isReadableSnapshotFormat(snapFormat):
    raise newException(ValueError,
      RuleFormatUnknown &
      "unsupported chain snapshot format '" & snapFormat & "' in " & snapPath &
      "; this build reads " & readableSnapshotFormatList() &
      ". Refused by name rather than read in part — a snapshot half-read against " &
      "the wrong schema publishes a chain that never existed. An older tree is " &
      "brought forward with tools/chain/migrate-refusal-reasons.mjs.")
  let requireRefusalReason = snapshotRequiresRefusalReason(snapFormat)

  # ── §5.2's REQUIRED MEMBERS, CHECKED BY NAME BEFORE ANYTHING READS THEM ─────
  #
  # Every one of these was reached by an unguarded `snap["…"]` further down, so a
  # snapshot short of one failed with `std/json`'s own `key not found: window` from
  # a stack that names neither this module nor the rule it broke. A refusal has to
  # name the rule it enforces; "raises where it happens to notice" is the state that
  # replaces.
  #
  # The brackets below are LEFT ALONE deliberately: they are the evidence the
  # spec-coverage check reads for "the contract requires this", and replacing them
  # with a guarded accessor would move that evidence into an annotation nobody
  # checks. This block makes the FAILURE legible; the subscript keeps saying what
  # the member is.
  #
  # AND THE POPULATION IS GENERATED, not written out here. It used to be the literal
  # `["provenance", "window", "counts", "blocks", "transactions"]`, which is a second
  # copy of §5.2's required set living one file away from the census that states it —
  # so a member the contract began requiring would be reached by an unguarded
  # subscript further down and fail as `std/json`'s own `key not found:`, from a
  # stack naming neither this module nor the rule. `SnapshotRequired` is that set
  # read out of the census, which is the same treatment the row members already got.
  #
  # The walk BELONGS IN `contract_rules.nim` for the same reason the row walks do:
  # spelled here it would be `snap{member}` over a loop variable, which is a
  # subscript by a name and therefore says "this container is an open map" to the
  # coverage check — one generated guard would have cost the whole top level its
  # member-by-member census. `missingBracketMember` keeps the dynamic subscript on
  # the census side, where the members are data, and leaves the literal subscripts
  # below as the only statement about what this reader consumes.
  block requiredMembers:
    let missing = missingBracketMember(snap, SnapshotRequired, false)
    if missing.len > 0:
      raise newException(ValueError,
        RuleMembersRequired &
        "the snapshot at " & snapPath & " carries no `" & missing & "`. " &
        ruleStatement("S5-MEMBERS-REQUIRED") &
        " Every member of " & snapFormat & "'s required set is named in " &
        "tools/chain/snapshot-contract.json, which is Data-Contract.md §5.2's " &
        "census in machine-readable form.")

  # ── THE TALLY IS A MEASUREMENT OF THE ROWS BESIDE IT ────────────────────────
  #
  # `counts` has been required by §5.2 since it was written and was consumed by
  # NOBODY — the reader never opened it, so its stated purpose, "so a partial
  # ingest is detectable", was served by no one and a stale tally was the detector
  # reading clean on the one condition it detects. It is read here, which is the
  # only place a consumer of the snapshot can check it against the rows it counts.
  #
  # TWO MEMBERS ON EVERY TOKEN AND A THIRD ON `@2`. `blocks` and `transactions` are
  # lengths and every committed snapshot carries them; `accountedFor` names the
  # three-population figure §5.2's table defines and only `@2` producers write it,
  # so requiring it on `@1` would make three frozen captures non-conforming by a
  # paragraph written after they were taken — §3.1's rule 3 applied to this
  # contract rather than to somebody else's.
  let counts = snap{"counts"}
  if counts.kind != JObject:
    raise newException(ValueError,
      RuleCountsPresent &
      "the snapshot at " & snapPath & " carries a `counts` that is not an object. " &
      ruleStatement("S5-COUNTS-PRESENT"))
  block countsCheck:
    let statedBlocks = counts{"blocks"}.getInt(-1)
    let statedTx = counts{"transactions"}.getInt(-1)
    if statedBlocks != snap["blocks"].len or statedTx != snap["transactions"].len:
      raise newException(ValueError,
        RuleCountsRows &
        "the snapshot at " & snapPath & " states counts.blocks=" & $statedBlocks &
        " counts.transactions=" & $statedTx & " over " & $snap["blocks"].len &
        " block(s) and " & $snap["transactions"].len & " transaction(s). " &
        ruleStatement("S5-COUNTS-ROWS") &
        " A tally that is not recomputed is a tally that survives the rows it " &
        "described; derive it on every write rather than merging into it.")
    if requireRefusalReason:
      let accountedFor = counts{"accountedFor"}.getInt(-1)
      if accountedFor != statedTx:
        raise newException(ValueError,
          RuleCountsReconcile &
          "the snapshot at " & snapPath & " states counts.accountedFor=" &
          $accountedFor & " against counts.transactions=" & $statedTx & ". " &
          ruleStatement("S5-COUNTS-RECONCILE") &
          " The traced and untraced tallies are NOT a partition of the rows — a " &
          "transaction the chain never made public is in neither — so the figure " &
          "that reconciles is the one that ranges over all three.")


  # ── AND THE MEMBERS INSIDE THOSE CONTAINERS, GENERATED FROM §5.2b ──────────
  #
  # The loop above covers the five top-level members. Two dozen more are required
  # by the contract and taken by an unguarded subscript below — `blocks[].hash`,
  # `transactions[].outcome`, `recording.steps` — and every one of them used to
  # fail as `std/json`'s own `key not found: hash`, from a stack naming neither
  # this module nor the rule it broke.
  #
  # The check is GENERATED from the census rather than written twice: the same
  # file that says a member is required and unsafely read is the file this pass
  # ranges over, so a member added to §5.2b is checked here without anybody
  # remembering to add a guard. The subscripts stay exactly as they are, because
  # they are what the spec-coverage check reads as the statement that the member
  # is required.
  block windowMembers:
    let missing = missingBracketMember(snap["window"], WindowRequired, false)
    if missing.len > 0:
      raise newException(ValueError,
        RuleRowMembersRequired &
        "the `window` in " & snapPath & " carries no `" & missing & "`. " &
        ruleStatement("S5-ROW-MEMBERS-REQUIRED"))
  for b in snap["blocks"]:
    let missing = missingBracketMember(b, BlockRequired, false)
    if missing.len > 0:
      raise newException(ValueError,
        RuleRowMembersRequired &
        "a block row in " & snapPath & " carries no `" & missing & "`" &
        (if b{"number"} != nil: " (number " & $b{"number"}.getInt & ")" else: "") &
        ". " & ruleStatement("S5-ROW-MEMBERS-REQUIRED"))
  # ── `blocks` IS NEWEST FIRST, WHICH §5.2 HAS SAID SINCE IT WAS WRITTEN ──────
  #
  # …and which nothing enforced until 2026-09-17. §5.2's table says "the
  # enumerated blocks, newest first"; §5.2b's census row for `blocks` said only
  # "the enumerated blocks", the qualifier having been dropped in transcription;
  # and no rule ranged over the order at all. A producer that enumerated its
  # range ascending — which is the order every node API answers in — published a
  # tree whose block list was the reverse of the one the contract promised, and
  # every check in this repository was green on it.
  #
  # NON-STRICT, AND THAT IS DELIBERATE. The comparison is `<=` on the
  # predecessor's height rather than `<`: two entries at one height are a chain
  # with more than one block at a height, which is a reorg artefact a producer is
  # entitled to publish, and refusing it would be this rule deciding a question
  # about somebody else's chain. What it refuses is an ASCENDING pair, which is
  # the one thing "newest first" rules out.
  block blockOrder:
    var prev = high(int)
    for b in snap["blocks"]:
      let n = b["number"].getInt
      if n > prev:
        raise newException(ValueError,
          RuleBlocksOrder &
          "the snapshot at " & snapPath & " enumerates block " & $n &
          " after block " & $prev & ", so `blocks` is not newest first. " &
          ruleStatement("S5-BLOCKS-ORDER"))
      prev = n
  for t in snap["transactions"]:
    # ── THE OUTCOME IS A CLOSED SET, AND THE FOURTH BUCKET IS WHY ────────────
    #
    # `snapshot-format.json` states three populations and §5.2 calls them
    # "disjoint by construction". The build asserts DISJOINTNESS — an outcome in
    # two populations fails it — and nothing asserted EXHAUSTIVENESS, so a token
    # in none of the three was in no population at all. Every rule that ranges
    # over a population then declines to fire for it, silently, while the rules
    # that range over every row go on firing: measured from outside by a reader
    # who had only §5, a row with `outcome: "no-public-execution"` and no
    # `refusalReason` ingested CLEAN on `@2`, and the SAME row without a
    # `reason` was refused by `S5-REASON-REQUIRED`. Two rules disagreeing about
    # one row.
    #
    # IT IS CHECKED HERE, BEFORE THE ROW-MEMBER PASS, because `traced` below is
    # derived from the outcome: a pass that read an unrecognised token and then
    # decided which members to require of the row has already acted on it.
    let outcomeToken = t{"outcome"}.getStr
    if not isKnownSnapshotOutcome(outcomeToken):
      raise newException(ValueError,
        RuleOutcomeClosed &
        "a transaction row in " & snapPath &
        (if t{"txHash"} != nil: " (" & shortHash(t{"txHash"}.getStr) & ")" else: "") &
        " states outcome '" & outcomeToken &
        "', which is in none of the three populations (" & snapshotOutcomeList() &
        "). " & ruleStatement("S5-OUTCOME-CLOSED") &
        " Decide which of the three statements this row makes and use that " &
        "population's token, or add the token to " &
        "tools/chain/snapshot-format.json's `outcomes` deliberately, in the " &
        "population it belongs to, and say in Data-Contract.md §5.2 what it means.")
    let traced = isTracedSnapshotOutcome(outcomeToken)
    let missing = missingBracketMember(t, TransactionRequired, traced)
    if missing.len > 0:
      raise newException(ValueError,
        RuleRowMembersRequired &
        "a transaction row in " & snapPath & " carries no `" & missing & "`" &
        (if t{"txHash"} != nil: " (" & shortHash(t{"txHash"}.getStr) & ")" else: "") &
        ". " & ruleStatement("S5-ROW-MEMBERS-REQUIRED"))


  let gen = if cfg.generation.len > 0: cfg.generation else: "1"
  let prov = snap["provenance"]

  proc provOrNull(key: string): JsonNode =
    ## One provenance member, or an explicit JSON `null` when the capture has none.
    ##
    ## `prov[key]` RAISES `KeyError` on an absent string key and `prov{key}` returns a
    ## **nil** `JsonNode`, which `std/json`'s `toUgly` dereferences without a nil check.
    ## Neither is what a reader should do with an optional member, and the first was
    ## reproduced as a crash on a real mainnet capture — see the summary writer below.
    result = prov{key}
    if result == nil: result = newJNull()

  let chain = prov{"chain"}.getStr
  if chain.len == 0:
    raise newException(ValueError,
      RuleChainNamed &
      "the snapshot at " & snapPath & " names no chain in provenance.chain; " &
      "refusing to guess a slug")

  # ── WHO RECORDED THIS, AND IN WHAT SCHEMA — STATED, NOT ASSUMED ─────────────
  #
  # Both of these were `const`s in this module. They are inputs to
  # `deriveTraceArtifactId`, so every published `/t/**` address commits to them:
  # a reader that supplies them is a reader deciding, for every chain it ever
  # ingests, which recorder produced the containers it is publishing. That is not
  # a default that is merely wrong for a second chain — it is a wrong answer
  # baked into an address, which is the one kind of wrong answer this tree cannot
  # correct later without a migration.
  #
  # ONE GUARD, TWO MEMBERS, AND THE SUBSCRIPTS STAY SAFE. `{}` throughout, with
  # the refusal in front, because a bracket guarded three tokens to its left
  # still reads as "required" to every reader that does not re-derive the guard —
  # and the census records these as required-and-safely-read with the rule that
  # enforces them, which is the shape §5.2b exists to make legible.
  let recNode = prov{"recorder"}
  let recorderId = (if recNode == nil: "" else: recNode{"id"}.getStr)
  let traceSchema = (if recNode == nil: "" else: recNode{"traceSchema"}.getStr)
  if recorderId.len == 0 or traceSchema.len == 0:
    raise newException(ValueError,
      RuleRecorderStated &
      "the snapshot for chain '" & chain & "' at " & snapPath & " states " &
      (if recNode == nil: "no `provenance.recorder` at all"
       elif recorderId.len == 0 and traceSchema.len == 0:
         "a `provenance.recorder` with neither an `id` nor a `traceSchema`"
       elif recorderId.len == 0: "a `provenance.recorder` with no `id`"
       else: "a `provenance.recorder` with no `traceSchema`") & ". " &
      ruleStatement("S5-RECORDER-STATED") &
      " Both are inputs to every published trace address, so one supplied here " &
      "would attribute this chain's containers to whatever recorder this build " &
      "happened to be compiled with.")

  # ── HOW THE PRESTATE WAS OBTAINED, FROM A CLOSED SET ────────────────────────
  #
  # This was a literal on the manifest writer, ~900 lines below, naming one
  # chain's answer for every chain. It is now the producer's, and it is drawn
  # from Chain-Support-Matrix.md §1.4's closed set rather than accepted as free
  # text: §1.4 states that a producer emitting a value outside that table is a
  # GAP IN THE TABLE and that the remedy is a row there, never a new string in a
  # snapshot. The set is data (`snapshot-contract.json`), read at compile time,
  # so the refusal can name what it would have accepted.
  let prestateStrategy = prov{"prestateStrategy"}.getStr
  if prestateStrategy.len == 0:
    raise newException(ValueError,
      RulePrestateStated &
      "the snapshot for chain '" & chain & "' at " & snapPath &
      " states no `provenance.prestateStrategy`. " &
      ruleStatement("S5-PRESTATE-STATED") &
      " The accepted set is " & prestateStrategyList() & ".")
  if not isPrestateStrategy(prestateStrategy):
    raise newException(ValueError,
      RulePrestateClosed &
      "the snapshot for chain '" & chain & "' at " & snapPath &
      " states prestateStrategy '" & prestateStrategy &
      "', which is not in the closed set (" &
      prestateStrategyList() & "). " & ruleStatement("S5-PRESTATE-CLOSED") &
      " Add a row to Chain-Support-Matrix.md §1.4 saying what the strategy MEANS, " &
      "and the token to tools/chain/snapshot-contract.json beside it.")

  # ---- how this chain writes its identifiers: ONE decision, both uses --------
  #
  # Built here, at the top, because it is used twice and must not be decided
  # twice: the registry row below PUBLISHES it (`identifierEncodingNode`) and
  # every sharded object path this producer writes DERIVES from it
  # (`shardKeyFor`). One value doing both jobs is what makes it impossible for
  # this producer to declare `hex` and key a path some other way — which is the
  # failure the encoding-as-data seam exists to remove, and the reason the
  # declaration and the derivation are not two variables here.
  #
  # `hex` is MEASURED for this chain and not assumed — `hexIdentifierEncoding`
  # carries the counts and says where to re-run them.
  # AND EVERY PATH IS BUILT BY THE FUNCTIONS THE CLIENT USES, not by hand. That
  # is the other half of "one decision": handing the same value to `shardKeyFor`
  # and then naming the object with the RAW identifier is two decisions again,
  # and it was measured writing `d/{chain}/tx/0a80/0x0A807E….json` — folded
  # shard, unfolded name — for an uppercase `txHash`. `contract/shards.nim` holds
  # the builders for exactly this reason; see its header.
  let identifierEncoding = hexIdentifierEncoding()

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
  # ── NAMED BY THE SNAPSHOT, WITH THE OLD PATH AS THE CONTRACT'S OWN DEFAULT ──
  #
  # This was `cfg.snapshotDir / "artifact-resolution.json"`, i.e. a SECOND path read by
  # name — which §5.1's "only `snapshot.json` is read by name" said did not exist. The
  # sentence was false and had been for as long as this sidecar has. It is the snapshot's
  # own sidecar rather than a row's (one resolution run answers about contract classes,
  # not about one transaction), so it is the SNAPSHOT that names it; the default below is
  # stated in §5.1 rather than known only here, which is the difference between a default
  # and a convention.
  var sidecarRel = snap{"artifactResolution"}.getStr
  if sidecarRel.len == 0: sidecarRel = DefaultArtifactResolutionPath
  let sidecarPath = cfg.snapshotDir / sidecarRel
  if fileExists(sidecarPath):
    let side = parseJson(readFile(sidecarPath))
    if side{"format"}.getStr != "blocktracer/artifact-resolution@1":
      raise newException(ValueError,
        RuleSidecarFormatUnknown &
        "unsupported artifact-resolution format '" & side{"format"}.getStr &
        "' at " & sidecarPath & "; this build reads blocktracer/artifact-resolution@1")
    # A SIDECAR FROM ANOTHER CHAIN IS A REFUSAL, NOT A SKIP. Applying one silently would
    # attach one chain's resolution answers to another chain's transactions — invisible in
    # the tree, and wrong in the direction that invents evidence.
    if side{"chain"}.getStr != chain:
      raise newException(ValueError,
        RuleSidecarChain &
        sidecarPath & " resolves chain '" & side{"chain"}.getStr & "' but this snapshot is '" &
        chain & "'; refusing to attach one chain's resolution to another's transactions")
    postHocMeasuredAt = side{"measuredAt"}.getStr
    postHocResolver = side{"measuredBy"}{"runtimeCommit"}.getStr
    # ── THE ROWS IT ANSWERS ABOUT, WHICH §5.2b MARKS OPTIONAL ────────────────
    #
    # GUARDED, BECAUSE ITERATING A NIL `JsonNode` SEGFAULTS. This was
    # `for e in side{"transactions"}`, and `{}` answers a NIL node for an absent
    # key — `items` then dereferences it and the process DIES. A sidecar that
    # carries only the two members this contract requires of it, which §5.2b says
    # is conforming, killed the reader: not a refusal, not a `KeyError`, a
    # segfault. It is the fourth member of one family — a member the contract
    # marks optional, reached by the one form that cannot survive its absence —
    # after `provenance.l1ChainId` (a `KeyError`), `execSelectors[-1]` (an
    # `IndexDefect`, which is not even catchable) and the position stream's
    # `positioned`/`paths` (a nil stored into `%*` and dereferenced by `toPretty`).
    let answered = side{"transactions"}
    for e in (if answered != nil and answered.kind == JArray: answered
              else: newJArray()):
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

  # ---- WHICH RECORDER PRODUCED WHICH CONTAINER ------------------------------
  #
  # THIS USED TO BE ONE VALUE FOR THE WHOLE SNAPSHOT, AND THAT WAS A PROVENANCE
  # DEFECT WITH A URL ATTACHED TO IT.
  #
  # `traceArtifactId` commits to `recorderBuild` deliberately — ids.nim says why:
  # "changing the recorder must change the URL so a stale artifact cannot outlive
  # a bug fix". Derived from `provenance.runtimeCommit`, that commitment holds
  # only while a chain has been observed by exactly one recorder for its whole
  # life. It has not been. A chain is watched for days by `follow-chain.mjs`, the
  # recorder is improved during those days, and the snapshot then holds
  # containers produced by two different builds. With one value per snapshot the
  # only way to publish the newer container is to move the snapshot's commit —
  # which re-derives the address of every OLDER container and files bytes that
  # `29bd9cf` produced under a build that never ran them. That is precisely the
  # misattribution the artifact id exists to make impossible, arrived at through
  # the id's own front door.
  #
  # THE SNAPSHOT ALREADY KNEW. `follow-chain.mjs` has always written a
  # `captures[]` entry per catch carrying that catch's own `runtimeCommit` and
  # the `yielded[]` transactions it produced. The per-container truth was being
  # recorded and then thrown away one field short of the publisher. So this reads
  # it, and the fallback chain is ordered by how directly each source witnessed
  # the recording:
  #
  #   1. `transactions[].recordedBy` — the row's own statement, which is what a
  #      recorder that ran outside the follower (a re-record, a one-off) has to
  #      be able to say for itself.
  #   2. the `captures[]` entry that yielded this transaction — the follower's
  #      contemporaneous note of which build was running when it caught it.
  #   3. `provenance.runtimeCommit` — the snapshot-wide value, which is the right
  #      answer for the transactions of the initial one-shot scan and the only
  #      answer available for a snapshot written before `captures[]` existed.
  #
  # (3) IS WHY NOTHING MOVES THAT DID NOT ASK TO. When this rule landed, every row
  # of the committed captures resolved to the same commit under it as under the
  # old one — by (2) for the 20 the follower caught, by (3) for the rest — so
  # every derived id was byte-identical. The rule is not merely compatible with
  # the existing tree by luck; (3) is the old behaviour, kept as the floor.
  #
  # ONE ROW HAS SINCE TAKEN (1), and it is the demonstration the rule was built
  # for. `0x20ed5b91…` publishes the container the FRAMES recorder wrote for its
  # execution, so its row names that build in `recordedBy` and its `/t/**` address
  # is derived from it; the other 24 still come out of (2) and (3) and are
  # byte-identical to what they were. That is checked rather than asserted —
  # `tools/dev/dump_recorder_provenance.nim` exists to be diffed across exactly
  # this kind of change, and the diff over that publish is four files added, four
  # removed and two edited, out of 6,307.
  var recordedBy = initTable[string, string]()
  let caps = snap{"captures"}
  if caps != nil and caps.kind == JArray:
    for c in caps:
      let commit = c{"runtimeCommit"}.getStr
      if commit.len == 0: continue
      let yielded = c{"yielded"}
      if yielded == nil or yielded.kind != JArray: continue
      for y in yielded:
        let h = y{"txHash"}.getStr
        if h.len > 0: recordedBy[h] = commit
  for t in snap["transactions"]:
    let own = t{"recordedBy"}.getStr
    if own.len > 0: recordedBy[t["txHash"].getStr] = own

  let snapshotCommit = prov{"runtimeCommit"}.getStr

  proc recorderFor(commit: string): RecorderRef =
    ## The recorder ref for one runtime commit. Pure, so two containers from one
    ## build get one ref and one `/t/**` prefix, and two from different builds
    ## necessarily get two.
    let v = "l3-" & shortHash(commit)
    RecorderRef(id: recorderId, build: recorderBuildHash(recorderId, v),
                version: v)

  proc recorderForTx(txHash: string): RecorderRef =
    recorderFor(if txHash in recordedBy: recordedBy[txHash] else: snapshotCommit)

  # TWO COMMITS THAT SHORTEN TO ONE LABEL ARE REFUSED, and this became worth
  # checking on this commit rather than before it. `recorderVersion` has always
  # been `shortHash` — the first ten hex characters — and while a snapshot had
  # exactly one recorder that truncation was a cosmetic choice about a label.
  # It is now the DISCRIMINATOR: `recorderBuildHash` hashes the label, so two
  # builds sharing ten characters would produce one build hash, one `/t/**`
  # prefix, and two containers silently filed as one recorder's work — the exact
  # misattribution this whole change exists to prevent, reintroduced through the
  # naming. It is a ~40-bit coincidence and it costs one table to refuse.
  #
  # SORTED, so the sentence a failure prints is the same on every run. The
  # published bytes cannot depend on this — it only ever raises — but a refusal
  # that names its two commits in table order is a refusal that reproduces
  # differently each time it is investigated.
  var allCommits: seq[string] = @[prov{"runtimeCommit"}.getStr]
  for _, commit in recordedBy: allCommits.add commit
  allCommits.sort()
  var labelOwner = initTable[string, string]()
  for commit in allCommits:
    if commit.len == 0: continue
    let v = "l3-" & shortHash(commit)
    if v in labelOwner and labelOwner[v] != commit:
      raise newException(ValueError,
        RuleRecorderLabelUnique &
        "the snapshot at " & snapPath &
        " names two recorder commits that shorten to the same " &
        "version label '" & v & "': " & labelOwner[v] & " and " & commit &
        ". The label is what `recorderBuildHash` hashes, so publishing both " &
        "would file two builds' containers under one recorder. Lengthen " &
        "`shortHash` rather than picking one of them.")
    labelOwner[v] = commit

  # The chain's DEFAULT pin — see the registry note below for what it now means.
  let rRef = recorderFor(snapshotCommit)
  let pRef = ProfileRef(name: profileName, hash: profileHash(profileName))

  # ---- registry: ADD this chain, never replace the file --------------------
  # The demo generator writes the registry first. A second producer that
  # overwrote it would delete the other chain's recorder pin and turn every one
  # of its transactions into `unsupported` — a data-plane fact invented by a
  # build-order accident. So this reads what is there and adds one key.
  #
  # WHAT `recorder` MEANS NOW, AND IT IS NARROWER THAN IT WAS. It is the chain's
  # DEFAULT — the recorder an overlay row is addressed under when the row names
  # none of its own. Every row this ingest writes for a container DOES name one
  # (see the overlay write), so the default is load-bearing only for rows
  # published before that field existed. It is written from
  # `provenance.runtimeCommit` and nothing else, which is exactly the value the
  # old code used for every container, so a re-ingest of an existing snapshot
  # writes the identical pin.
  #
  # `recorders` IS THE INVENTORY, and it exists so the mixed case is legible from
  # the registry rather than only by walking every overlay row. A chain carrying
  # two builds says so here, in one place, sorted so a regeneration is
  # byte-identical.
  let regRel = "registry" / "chains.v" & $ContractVersion & ".json"
  var reg =
    if fileExists(cfg.outDir / regRel): parseJson(readFile(cfg.outDir / regRel))
    else: %*{"version": ContractVersion, "chains": {}}
  # A DIFFERENT DEFAULT OVER A TREE THAT ALREADY HAS ONE IS REFUSED, and this is
  # the structural half of the fix rather than a belt-and-braces check. Rows
  # published by an older producer carry no recorder and are addressed by this
  # pin alone; moving it re-derives every one of their `/t/**` addresses and
  # leaves the containers stranded at the old ones. There is no version of that
  # which is a smaller problem than refusing, so it refuses, and it names both
  # builds because "the pin changed" without saying from what to what is not a
  # diagnosis.
  let incumbentPin = reg{"chains"}{chain}{"recorder"}{"build"}.getStr
  if incumbentPin.len > 0 and incumbentPin != rRef.build:
    raise newException(ValueError,
      "chain '" & chain & "' is already pinned in " & regRel & " to recorder " &
      "build '" & incumbentPin & "' and this snapshot's provenance would " &
      "re-pin it to '" & rRef.build & "' (runtimeCommit " &
      shortHash(snapshotCommit) & "). Every overlay row that names no recorder " &
      "of its own is addressed under that pin, so moving it re-derives their " &
      "trace addresses and attributes their containers to a build that did not " &
      "produce them. Record the newer recorder per transaction instead — " &
      "`transactions[].recordedBy`, or a `captures[]` entry that yields it.")
  # THE INVENTORY IS FILLED BY THE TRANSACTION LOOP AND THE ROW IS WRITTEN AFTER
  # IT, which is a deliberate reordering. `recorders` claims to list the builds
  # that produced THE CONTAINERS THIS TREE PUBLISHES; computed up here it would
  # instead list the builds named anywhere in the snapshot, including for
  # transactions the curated window drops. Those are two different sets, and only
  # one of them is checkable against the tree it describes.
  var recorderInventory = initTable[string, RecorderRef]()

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
    cfg.writeJson(blockPath(chain, b.hash, identifierEncoding), bd.toJson)

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
  # ING-3: PER-REASON REFUSAL COUNTS, ZERO-FILLED OVER THE WHOLE CLOSED SET.
  #
  # `refusedCount` above counts one outcome string. It does not count
  # `not-first-in-block`, which is an outcome three of this repository's four
  # capture tools write, so a snapshot holding one had it in NO count at all.
  # These counters range over the reasons instead, every member present on every
  # summary whether or not it fired — an absent key reads as "this reason does
  # not exist here", where a published zero reads as "this reason exists and has
  # not fired", and only the second makes the first `not-first-in-block: 1` a
  # diff against a line somebody was already looking at.
  var refusalReasonCounts = initTable[string, int]()
  for id in refusalReasonIds(): refusalReasonCounts[id] = 0
  var untracedCount = 0
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
    let blockHash = byHeight.getOrDefault(height, "")
    inc txCount

    # -- immutable facts ----------------------------------------------------
    # `revertCode` is the chain's own: 0 succeeded, anything else reverted. The
    # cost is the chain's too. Nothing here is derived from the replay, because
    # these facts are true whether or not anyone ever re-executed the thing.
    let reverted = t["revertCode"].getInt != 0
    var roles: seq[Role]

    # ── COST IS A VECTOR AND IT IS CARRIED VERBATIM ────────────────────────
    #
    # This used to be ONE entry constructed here, with a name, a unit and a token
    # written out — one chain's single fee dimension asserted over every chain.
    # Static-Site-Architecture.md §2.3 makes cost a vector deliberately, because a
    # scalar produces silently wrong output on a real chain, and a chain with two
    # fee dimensions could not express itself through a fixed one-entry
    # constructor. The failure was not an error: it was a page that looked right
    # and stated the wrong cost.
    #
    # So every field of every entry is the producer's. The reader supplies no
    # name, no unit and no token — not even a default, because a default unit is
    # a unit and it would be read as a measurement. An entry that states no name
    # or no figure is REFUSED rather than completed here: a cost dimension
    # nothing can name is a number on a page with nothing to read it as.
    var costs: seq[Cost]
    let costNode = t["cost"]
    if costNode.kind != JArray:
      raise newException(ValueError,
        RuleCostVector &
        "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
        " carries a `cost` that is not an array. " &
        ruleStatement("S5-COST-VECTOR"))
    # ── AND AN EMPTY VECTOR IS NOT A CLEAN ONE ──────────────────────────────
    #
    # The loop below is the whole of this rule's force and it RANGES OVER
    # ENTRIES, so a vector with no entries satisfied it vacuously — in the one
    # seam §5.3 argues at length that the reader must supply nothing for. A row
    # with `cost: []` publishes a transaction page stating no cost at all, which
    # is indistinguishable from a producer that forgot to write one, and the
    # reader may not tell them apart because it has no default to fall back on.
    # That is the same argument §5.2 makes about an empty `reason`.
    if costNode.len == 0:
      raise newException(ValueError,
        RuleCostVector &
        "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
        " carries an EMPTY `cost` vector. " & ruleStatement("S5-COST-VECTOR") &
        " A transaction that was genuinely free in every dimension states that " &
        "dimension with a figure of zero; the reader supplies no entry, so an " &
        "empty vector and a forgotten one publish the same page.")
    for c in costNode:
      if c.kind != JObject or c{"name"} == nil or c{"used"} == nil or
         c{"name"}.getStr.len == 0:
        raise newException(ValueError,
          RuleCostVector &
          "a cost entry of transaction " & shortHash(txHash) & " in block " &
          $height & " of " & snapPath & " states " &
          (if c.kind != JObject: "something that is not an object"
           elif c{"name"} == nil or c{"name"}.getStr.len == 0: "no `name`"
           else: "no `used`") & ". " & ruleStatement("S5-COST-VECTOR"))
      costs.add Cost(name: c{"name"}.getStr, used: c{"used"}.getStr,
                     limit: c{"limit"}.getStr, price: c{"price"}.getStr,
                     unit: c{"unit"}.getStr, token: c{"token"}.getStr,
                     refundable: c{"refundable"}.getBool)
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
    # ONE SUBSCRIPT, for the reason `capturedLabel` gives below: `t{"artifacts"} != nil`
    # and `t["artifacts"]` in one expression is a safe bracket that reads as a required
    # member, and the member is genuinely optional — a capture taken before the runtime
    # could resolve artifacts carries no such key at all, and telling that from "looked,
    # found nothing" is the whole point of the three-state rule below.
    let artifactsNode = t{"artifacts"}
    let capturedArtifacts =
      if artifactsNode != nil and artifactsNode.kind == JArray: artifactsNode
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

    # ── THE EXECUTION PARTITION IS THE PRODUCER'S LIST, AT EVERY SITE ───────
    #
    # One fixed selector used to be written at four sites in this module: the
    # facts' execution list, the trace-artifact input id it is derived from, the
    # overlay row of a traced transaction and the overlay row of an untraced one.
    # A chain whose transactions hold two independently debuggable executions —
    # one observable, one not — collapsed into a single unnamed one, silently,
    # because nothing downstream could tell a partition of one from a partition
    # the reader had flattened.
    #
    # WHICH EXECUTION THE ROW'S CONTAINER BELONGS TO IS DECIDED BY DATA, NOT BY
    # POSITION. A row carries one container, and an execution entry that states
    # its OWN `reason` is one this capture did not trace — so the entry WITHOUT a
    # reason is the one the container is for. That makes the answer a fact the
    # producer wrote rather than a convention about array order, and it is why two
    # reasonless entries are refused: they would publish one recording as evidence
    # of two executions.
    var executions: seq[Execution]
    var execSelectors: seq[string]
    var execReasons: seq[string]
    let execNode = t["executions"]
    if execNode.kind != JArray or execNode.len == 0:
      raise newException(ValueError,
        RuleExecutionsNamed &
        "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
        " carries " & (if execNode.kind != JArray: "an `executions` that is not an array"
                       else: "an empty `executions`") & ". " &
        ruleStatement("S5-EXECUTIONS-NAMED"))
    for e in execNode:
      let sel = (if e.kind == JObject: e{"selector"}.getStr else: "")
      if sel.len == 0:
        raise newException(ValueError,
          RuleExecutionsNamed &
          "an execution of transaction " & shortHash(txHash) & " in block " &
          $height & " of " & snapPath & " states no `selector`. " &
          ruleStatement("S5-EXECUTIONS-NAMED"))
      execSelectors.add sel
      execReasons.add e{"reason"}.getStr
      executions.add Execution(selector: sel,
                               executionInputId: demoExecutionInputId(chain, txHash, sel))
    var tracedAt = -1
    for k in 0 ..< execSelectors.len:
      if execReasons[k].len != 0: continue
      if tracedAt >= 0:
        raise newException(ValueError,
          RuleExecutionsOneTraced &
          "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
          " leaves both '" & execSelectors[tracedAt] & "' and '" &
          execSelectors[k] & "' without a `reason` of their own. " &
          ruleStatement("S5-EXECUTIONS-ONE-TRACED"))
      tracedAt = k
    if replayed and tracedAt < 0:
      raise newException(ValueError,
        RuleExecutionsOneTraced &
        "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
        " carries a container and every one of its " & $execSelectors.len &
        " execution(s) states its own `reason`, so nothing names the execution " &
        "the container is a recording of. " &
        ruleStatement("S5-EXECUTIONS-ONE-TRACED"))
    let execInputId =
      if tracedAt >= 0: executions[tracedAt].executionInputId else: ""

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
    cfg.writeJson(txFactsPath(chain, txHash, identifierEncoding), facts.toJson)

    # -- mutable per-generation state ---------------------------------------
    cfg.writeJson(txStatePath(chain, gen, txHash, identifierEncoding),
      %*{"chain": chain, "tx": txHash, "canonical": true,
         "finality": (if height <= finalizedAt: "finalized" else: "pending")})

    # -- the §7.0 overlay ----------------------------------------------------
    var et: ExecTrace
    if replayed:
      # `let rec = t["recording"]` used to sit here with a `discard rec` 445 lines
      # below and no other use — a binding whose only effect was to make the member
      # look required in a place nothing read it. Every real use of `recording` is
      # spelled at its own site.
      let matched = t["effects"]["matched"].getInt
      let mismatched = t["effects"]["mismatched"].getInt
      # THIS CONTAINER'S OWN RECORDER — resolved per transaction, from the
      # fallback chain documented where `recordedBy` is built. Every use of a
      # recorder below is this one: the id derivation, the manifest, and the
      # overlay row. They must not be able to disagree, which is why there is one
      # binding rather than three lookups.
      let txRRef = recorderForTx(txHash)
      recorderInventory[txRRef.build] = txRRef
      et = ExecTrace(selector: execSelectors[tracedAt],
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
          strength: matched),
        # THE ROW STATES WHAT PRODUCED ITS CONTAINER, and this is the field that
        # lets one chain carry two recorders without either being misfiled. The
        # client derives the address from it (blocktracer_client/trace.nim); the
        # validator checks the address against it. Where it equals the chain pin
        # — which it does for every container in the committed captures — the
        # derived id is unchanged, so publishing it re-addresses nothing.
        hasRecorder: true, recorder: txRRef)
      inc withTrace
      if not reproduced: inc divergentCount
      inc totalContainerBytes, t["containerBytes"].getInt

      # ---- the artifact: manifest + the real container --------------------
      let tid = deriveTraceArtifactId(execInputId, txRRef.id, txRRef.build,
                                      pRef.hash, traceSchema)
      let shards = traceShards(tid)
      let dir = "t" / shards.a / shards.b / tid
      let ctBytes = readFile(cfg.snapshotDir / t["container"].getStr)
      if ctBytes.len == 0:
        raise newException(ValueError,
          RuleContainerNonEmpty &
          "the snapshot's container for " & txHash & " at " &
          (cfg.snapshotDir / t["container"].getStr) &
          " is empty; refusing to publish a manifest naming a zero-byte trace")
      # ── `containerBytes` IS A MEASUREMENT, AND IT WAS CHECKED BY NOBODY ─────
      #
      # The row's figure is republished on the overlay row verbatim — it is the
      # `bytes` a client shows before it fetches — and until 2026-09-17 the only
      # thing that compared it to the file was the PUBLISHED-tree validator, one
      # whole check later, citing no rule because there was none to cite. So a
      # producer whose tally was stale learned about it from a sentence with
      # nothing in it to look up. The container's bytes are in hand on the line
      # above, so this is the place the comparison belongs: §5.2's argument for
      # `counts` one level down, on a row rather than on a snapshot.
      if ctBytes.len != t["containerBytes"].getInt:
        raise newException(ValueError,
          RuleContainerBytes &
          "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
          " states containerBytes " & $t["containerBytes"].getInt & " and its container at " &
          (cfg.snapshotDir / t["container"].getStr) & " is " & $ctBytes.len &
          " bytes. " & ruleStatement("S5-CONTAINER-BYTES"))
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
      # THE LANGUAGES THIS ROW'S BUNDLES STATE, collected as they are published.
      # The manifest used to name one constant language for every source-level
      # recording of every chain; it now names exactly the distinct languages the
      # bundles it points at carry, so a manifest cannot claim a language no
      # bundle beside it is written in — and a bundle that states none puts
      # nothing here, which is how "the reader names none" is visible in the
      # published object rather than only in this comment.
      var bundleLanguages: seq[string]
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
      # The row names the file; §5.1's STATED default is the fallback, so a capture
      # written before the row carried the key still resolves. The default comes
      # from `DefaultSourcesDir` — i.e. out of the census — and not from a literal
      # here: a default this reader spells itself is knowledge only this reader has,
      # which is the difference §5.1 draws between a default and a convention. This
      # was `"sources"` open-coded until 2026-09-17, which made §5.1's claim that the
      # reader spells none of them false, and nothing could see it because the two
      # resolve identically. `snapshot-contract-selftest.mjs` §8 now refuses any of
      # the five defaults appearing as a path literal in this file.
      var srcRel = t{"sourceBundles"}.getStr
      if srcRel.len == 0: srcRel = DefaultSourcesDir / (txHash & ".json")
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
      # THE FILE THE STREAM CAME FROM, carried beside it so a refusal about the
      # stream can name the file a producer has to open. There are two sources and
      # they are different files; a refusal that named neither left a producer
      # grepping for a transaction hash across the tree.
      var posPath = ""
      # The row names the file, as it does for its container and its source bundle;
      # §5.1's default is the fallback, so a capture written before the row carried
      # the key still resolves and its bytes are unchanged.
      var posRel = t{"positions"}.getStr
      if posRel.len == 0: posRel = DefaultPositionsDir / (txHash & ".json")
      let capturedPosPath = cfg.snapshotDir / posRel
      if fileExists(capturedPosPath):
        posSource = parseJson(readFile(capturedPosPath))
        posIsPostHoc = posSource{"measuredPostHoc"}.getBool
        posPath = capturedPosPath
      elif txHash in postHocPositions:
        posSource = postHocPositions[txHash]
        posPath = sidecarPath

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
            RuleBundleRequired &
            why & " and this snapshot carries no source bundle for it (looked for " &
            srcPath & "); refusing to publish positions with no text to put behind " &
            "them, which would put the debugger's source pane on a file it cannot fetch")
        let srcDoc = parseJson(readFile(srcPath))
        let bundleList = srcDoc{"bundles"}
        if bundleList == nil or bundleList.kind != JArray or bundleList.len == 0:
          raise newException(ValueError,
            RuleBundleRequired &
            why & " and its source bundle file " & srcPath & " carries no bundle; " &
            "refusing to publish positions with no text to put behind them, which " &
            "would put the debugger's source pane on a file it cannot fetch")
        for b in bundleList:
          let codeHash = b{"codeHash"}.getStr
          if codeHash.len == 0:
            raise newException(ValueError,
              RuleBundleKeyed &
              "a source bundle for " & txHash & " in " & srcPath & " names no " &
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
              RuleBundleNonEmpty &
              "the source bundle for code hash " & codeHash & " of " & txHash &
              " in " & srcPath & " carries no files; refusing to publish an " &
              "empty bundle a manifest would then recommend")
          # WHAT THE CHAIN PROVED AND WHAT IT DID NOT, published beside the
          # text. `artifactHash` is the chain's commitment to the artifact and
          # does NOT cover `debug_symbols` or `file_map`, so `corroboration`
          # names how many independent distributors served the same symbols and
          # map — `corroborated` for two, `single-distributor` for one. A reader
          # who wants to know how much of the source below is attested by the
          # chain and how much by a package registry has it here.
          # ONE SUBSCRIPT, for `capturedLabel`'s reason: `b{"…"} != nil and b["…"].kind`
          # is a safe bracket that reads as a required member to every reader that does
          # not re-derive the guard three tokens to its left, and this member is
          # genuinely optional.
          let distributors = b{"agreeingDistributors"}
          var agreeing = newJArray()
          if distributors != nil and distributors.kind == JArray:
            agreeing = distributors
          let attestation = %*{
            "artifactHash": orNull(b{"artifactHash"}),
            "debugDigest": orNull(b{"debugDigest"}),
            "shape": orNull(b{"shape"}),
            "corroboration": orNull(b{"corroboration"}),
            "agreeingDistributors": agreeing}
          let bundleLang = b{"language"}.getStr
          if bundleLang.len > 0 and bundleLang notin bundleLanguages:
            bundleLanguages.add bundleLang
          bundles[codeHash] = %cfg.writeSourceBundle(
            chain, codeHash, b{"origin"}.getStr, bundleLang, files, attestation)


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
      # THE DELIVERABLE THIS SIDECAR WAS SINGLED OUT FOR. It was the one path in the
      # tree located by convention and by nothing else; it is now named by the row that
      # owns it, exactly as the container and the source bundle already were, with
      # §5.1's stated default behind it.
      var insRel = t{"instructions"}.getStr
      if insRel.len == 0: insRel = DefaultInstructionsDir / (txHash & ".json")
      let insFile = cfg.snapshotDir / insRel
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
            RuleInstructionsAgree &
            "the instruction listing for " & txHash & " at " & insFile & " holds " & $carried &
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
        # THE STREAM'S OWN SCHEMA TOKEN, REPUBLISHED RATHER THAN CHOSEN. This was
        # a literal here, and it named a VM — the seventh chain constant in this
        # module, arriving in a `schema` field where nobody was looking for one.
        # The token is a statement about the stream's columns, so the producer
        # that wrote the columns is what states it; a token written here would be
        # this reader asserting one ecosystem's positions format over whatever it
        # was handed. It is refused rather than defaulted, because every producer
        # of a stream in this tree writes it and a default would only ever be
        # reached by a producer that had not thought about it.
        let posSchema = pos{"schema"}.getStr
        if posSchema.len == 0:
          raise newException(ValueError,
            RulePositionsSchema &
            "the source positions for " & txHash & " at " & posPath & " state no `schema`. " &
            ruleStatement("S5-POSITIONS-SCHEMA"))
        let carried = pos{"steps"}.getInt(-1)
        let declared = t["recording"]["steps"].getInt
        # THE SAME REFUSAL THE LISTING MAKES, for the same defect: a position array of a
        # different length puts a source line against the wrong step, and every surface
        # involved would go on reporting success.
        if carried != declared:
          raise newException(ValueError,
            RulePositionsAgree &
            "the source positions for " & txHash & " at " & posPath & " hold " & $carried &
            " steps and the recording declares " & $declared &
            "; refusing to publish positions the steps cannot be located in")
        for col in ["pathId", "line", "column"]:
          let a = pos{col}
          if a == nil or a.kind != JArray or a.len != declared:
            raise newException(ValueError,
              RulePositionsColumns &
              "the source positions for " & txHash & " at " & posPath & " carry a '" & col &
              "' column of " & (if a == nil: "nothing" else: $a.len) &
              " against " & $declared & " steps; a partial column would mark " &
              "rows it was never measured for")
        cfg.writeJson(dir / "positions.json", %*{
          "schema": posSchema,
          "tx": txHash,
          "steps": carried,
          # `orNull`, NOT A BARE `{}`. §5.2b marks `positioned` and `paths` optional,
          # and a `{}` subscript answers a NIL node for an absent key — which `%*`
          # will happily store and `toPretty` then dereferences. So a stream that
          # omitted either member SEGFAULTED the reader: not a refusal, not a
          # KeyError, a dead process. It is the third member of a family this seam
          # has now produced three times — a member the contract marks optional,
          # reached by the one form that cannot survive its absence — and the other
          # two were `provenance.l1ChainId` (a `KeyError`) and `execSelectors[-1]`
          # (an `IndexDefect`, which is not even catchable). The three required
          # columns below are checked for nil directly above, so they cannot be one.
          "positioned": orNull(pos{"positioned"}),
          # THE ARTIFACT'S RUNG BESIDE THE RECORDING'S, because they differ here and the
          # difference is the whole finding: the artifact maps every pc it keys, and this
          # recording walks 22 the artifact does not key.
          "artifactRung": orNull(pos{"artifactRung"}),
          "measuredPostHoc": posIsPostHoc,
          "measuredAt": (if posIsPostHoc and postHocMeasuredAt.len > 0:
                           %postHocMeasuredAt else: newJNull()),
          "paths": orNull(pos{"paths"}),
          # `orNull` ON THE THREE REQUIRED COLUMNS TOO, and not because they can be
          # nil here — the loop 30 lines above RAISES when any of the three is absent,
          # not an array, or the wrong length, so a nil cannot reach this construction
          # and `orNull` of a non-nil node is the node. It is the uniform form because
          # the rule is a SHAPE rule: a bare `{}` in a `%*` value position is the
          # nil-access family, `tools/chain/lib/reader-contract.mjs` bans it over
          # `src/**/*.nim`, and a ban with three sites reading "this one is fine, we
          # checked" is a ban with three places to be wrong about that later.
          "pathId": orNull(pos{"pathId"}),
          "line": orNull(pos{"line"}),
          "column": orNull(pos{"column"})})

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
      var callRel = t{"callTrace"}.getStr
      if callRel.len == 0: callRel = DefaultCallTraceDir / (txHash & ".json")
      let ctFile = cfg.snapshotDir / callRel
      if fileExists(ctFile):
        let cf = parseJson(readFile(ctFile))
        let declaredCalls = t["recording"]{"callsOpened"}.getInt
        let carriedFrames = cf{"frames"}.getInt(-1)
        if carriedFrames != declaredCalls + 1:
          raise newException(ValueError,
            RuleCallTraceAgree &
            "the call trace for " & txHash & " at " & ctFile & " holds " & $carriedFrames &
            " frame(s) and the recording declares callsOpened=" &
            $declaredCalls & "; refusing to publish a call trace the " &
            "manifest's own frame count contradicts")
        let arr = cf{"frame"}
        if arr == nil or arr.kind != JArray or arr.len != carriedFrames:
          raise newException(ValueError,
            RuleCallTraceFrames &
            "the call trace for " & txHash & " at " & ctFile & " declares " & $carriedFrames &
            " frame(s) and carries " &
            (if arr == nil: "no" else: $arr.len) & " of them")
        # THE FOLD MARKS ARE REFUSED ON THE SAME TERMS AS THE FRAME COUNT, and
        # for the same reason: the pane is about to tell a reader how much of
        # the trace is behind a closed triangle, and that number is the ONE
        # thing on the row they cannot check by looking.
        #
        # `avm-call-frames/1` carries none of these fields, and that stays
        # valid — the twenty-seven snapshots captured before folding existed
        # publish exactly as they did. What is refused is a stream that carries
        # them and contradicts itself.
        var markedFolded = 0
        var markedSteps = 0
        for f in arr:
          if f{"foldedBy"}.getStr("").len == 0: continue
          markedFolded.inc
          markedSteps += f{"hiddenSteps"}.getInt(0)
          # A CLOSED ROW WITH NOTHING BEHIND IT IS THE DEFECT THIS CATCHES.
          # Folding is a claim that there is something inside; a frame marked
          # folded while claiming zero descendants puts a disclosure triangle on
          # an empty subtree, and the reader opens it and nothing happens.
          if f{"hiddenDescendants"}.getInt(0) <= 0:
            raise newException(ValueError,
              RuleCallTraceFoldNonEmpty &
              "the call trace for " & txHash & " at " & ctFile & " marks frame '" &
              f{"name"}.getStr & "' folded while claiming " &
              $f{"hiddenDescendants"}.getInt(0) & " descendant(s); refusing to " &
              "publish a closed row with nothing behind it")
        let declaredFolded = cf{"foldedFrames"}.getInt(0)
        let declaredSteps = cf{"foldedSteps"}.getInt(0)
        if markedFolded != declaredFolded or markedSteps != declaredSteps:
          raise newException(ValueError,
            RuleCallTraceFoldTally &
            "the call trace for " & txHash & " at " & ctFile & " declares foldedFrames=" &
            $declaredFolded & " foldedSteps=" & $declaredSteps &
            " and its frames carry " & $markedFolded & " / " & $markedSteps &
            "; refusing to publish a summary the rows contradict")
        # The steps behind every triangle cannot exceed the steps the recording
        # has. The fold points never nest — the derivation folds the outermost
        # match and stops descending — so this is a sum, not a union, and an
        # overrun means either the marks or the step count is wrong.
        let recSteps = t["recording"]["steps"].getInt
        if markedSteps > recSteps:
          raise newException(ValueError,
            RuleCallTraceFoldBound &
            "the call trace for " & txHash & " at " & ctFile & " folds " & $markedSteps &
            " step(s) out of a recording that has " & $recSteps)
        cfg.writeJson(dir / "calltrace.json", cf)

      let manifest = TraceManifest(
        schema: ContractVersion, traceArtifactId: tid,
        executionInputId: execInputId, chain: chain, tx: txHash,
        recorder: txRRef, profile: pRef,
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
          # The language is named only when there are positions to attach it to,
          # and it is the language the BUNDLES state rather than one named here.
          languages: (if measuredSourceLevel: bundleLanguages else: @[])),
        validation: ValidationSummary(
          status: (if reproduced: vsMatch else: vsDivergent),
          strength: matched),
        validationOracle: "published-effects",
        # The producer's, from §1.4's closed set, checked where it was read.
        prestateStrategy: prestateStrategy)
      cfg.writeJson(dir / "manifest.json", manifest.toJson)
    else:
      # Not replayed. The snapshot wrote the sentence; it is published verbatim
      # so the page states the measured reason rather than a generic one.
      inc untracedCount
      if outcome == "pruned": inc prunedCount
      if outcome == "refused":
        inc refusedCount
        let rn = t{"refusal"}.getStr
        if rn.len > 0 and rn notin refusalNames: refusalNames.add rn

      # ── ING-3: the closed-set reason, validated and carried ──────────────
      #
      # THE ONE FIELD THAT MAKES A REFUSAL DISTINGUISHABLE FROM AN ABSENCE.
      # Every untraced row published before this reached the page as
      # `availability: "absent"` with a sentence, and `absent` is what the
      # Aztec private half is published as too — so "the chain never made this
      # execution public" and "we declined this execution, and here is why"
      # were one statement wearing one word. The machine-readable name the
      # capture recorded was counted here and then thrown away.
      #
      # A REASON OUTSIDE THE SET RAISES rather than being carried or dropped.
      # Dropping it would republish the old ambiguity silently on exactly the
      # rows where something new had happened; carrying it would make the set
      # open at its last hop. `refusal_reasons.nim` reads the same file the
      # producer wrote the row against, so the two cannot disagree about
      # membership without the build saying so.
      let rr = t{"refusalReason"}.getStr
      # ── `@2` REQUIRES THE MEMBER; `@1` LEFT IT OPTIONAL ──────────────────
      #
      # THIS IS WHAT THE FORMAT BUMP MEANS, and it is checked here because this is
      # the reader. `auditRefusals` has required the member on the producer side
      # since ING-3 — which is what made the token's `@1` a false claim about
      # every committed capture — and this side went on accepting its absence. So
      # the two halves of the seam disagreed about whether the field was
      # mandatory, and the artifact's own version token said nothing either way.
      #
      # A chain-absent row (`private-only`) must carry NO id on either version:
      # the closed set is a set of things WE did, and "the chain never published
      # this execution" is not one of them. `auditRefusals` enforces the same
      # asymmetry on the producer side, and the populations come from the same
      # file both sides read, so the two cannot drift about which rows this
      # applies to.
      if requireRefusalReason and rr.len == 0 and isUntracedSnapshotOutcome(outcome):
        raise newException(ValueError,
          RuleRefusalReasonRequired &
          "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
          " has untraced outcome '" & outcome & "' and carries no refusalReason. " &
          snapFormat & " requires one on every untraced row — that requirement is " &
          "the whole difference between it and blocktracer/chain-snapshot@1, and " &
          "'absent with no explanation' is indistinguishable from a failed fetch. " &
          "Either the producer must classify this row through classifyRefusal, or " &
          "the snapshot is a blocktracer/chain-snapshot@1 wearing a newer token — " &
          "bring it forward with tools/chain/migrate-refusal-reasons.mjs rather " &
          "than relabelling it.")
      # ── AND THE OTHER DIRECTION, WHICH NOTHING ENFORCED ────────────────────
      #
      # §5.2: "Both directions are refused: a member on a chain-absent row, and a
      # missing sentence on one." Only the first half of the first direction was
      # ever checked here — a `private-only` row carrying `body-unavailable` was
      # counted into the published per-reason tally as though this pipeline had
      # declined an execution the chain never published. The closed set is a set of
      # things WE did; giving a chain-absent row one publishes a repairable fault
      # of ours in place of a permanent property of the chain.
      if rr.len > 0 and isChainAbsentSnapshotOutcome(outcome):
        raise newException(ValueError,
          RuleRefusalReasonForbidden &
          "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
          " has chain-absent outcome '" & outcome & "' and carries refusalReason '" &
          rr & "'. " & ruleStatement("S5-REFUSALREASON-FORBIDDEN"))
      if rr.len > 0:
        if not isRefusalReason(rr):
          raise newException(ValueError,
            RuleRefusalReasonClosed &
            "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
            " carries refusalReason '" & rr & "', which is not in the closed " &
            "set (" & refusalReasonList() & "). A reason outside the set is a " &
            "failure of this pipeline, not a free-text fallback: add it to " &
            "tools/chain/refusal-reasons.json deliberately, with the condition " &
            "that produces it, or fix the producer that invented it.")
        refusalReasonCounts[rr] = refusalReasonCounts.getOrDefault(rr) + 1
      # THE REASON IS NOT OPTIONAL. `blocktracer_client/decode.nim` refuses an
      # overlay whose `absent` execution carries no reason, and the validator
      # refuses it at publish time — both deliberately, because "absent with no
      # explanation" is indistinguishable from a failed fetch. This side refuses
      # it too, which it did not: the sentence that used to be here said a row
      # the capture left without words "gets words here", and that was the defect
      # rather than the design.
      # THE SENTENCE IS THE PRODUCER'S AND IS NOT INVENTED HERE.
      #
      # This block used to substitute "This transaction was not re-executed for this
      # snapshot (outcome: X), so no trace was recorded for it." for an absent
      # `reason`, and then — two lines later — raise on an empty one. The raise was
      # DEAD: the substitution had already made `why` non-empty, so the refusal
      # §5.2 states ("an empty reason is refused rather than published") could not
      # fire, and the reader published a generic sentence over the producer's
      # silence while the spec said it refused. Two behaviours in adjacent lines,
      # one of them unreachable.
      #
      # It refuses now, on every token, and the corpus pays nothing for it:
      # measured over all six committed snapshots, 948 of 948 untraced and
      # chain-absent rows carry a `reason`, so not one artifact moves.
      let why = t{"reason"}.getStr
      if why.len == 0:
        raise newException(ValueError,
          RuleReasonRequired &
          "transaction " & shortHash(txHash) & " in block " & $height & " of " & snapPath &
          " has outcome '" & outcome & "' and carries no `reason`. " &
          ruleStatement("S5-REASON-REQUIRED") &
          " A generic sentence written here would be this pipeline's words over " &
          "the producer's silence, and 'absent with no explanation' is " &
          "indistinguishable from a failed fetch.")
      # ── AN UNTRACED ROW MAY NAME NO CONTAINER-BEARING EXECUTION AT ALL ────
      #
      # `tracedAt` is -1 when EVERY execution states its own `reason`. On a
      # traced row that is refused above, because S5-EXECUTIONS-ONE-TRACED says
      # a row carrying a container must leave exactly one entry reasonless. On
      # an UNTRACED row it is contract-valid and says something true: §5.2b
      # marks `executions[].reason` optional, the rule constrains only the
      # traced case, and a row with no container has no execution its container
      # belongs to. A producer is entitled to write it.
      #
      # So THERE IS NO `et` TO BUILD, and the rule stated below the loop needs
      # no special case to cover it: with `tracedAt` at -1 no `k` equals it, so
      # every entry is an "other" entry and publishes as `absent` with THAT
      # PRODUCER'S OWN sentence — Static-Site-Architecture.md §2.3a's
      # vocabulary, not a new state, and not a selector the reader named.
      #
      # This line used to run unconditionally and index `execSelectors[-1]`,
      # which raises IndexDefect. A Defect is not a CatchableError: it escapes
      # every `except CatchableError` between here and the CLI and TERMINATES
      # the process, so a contract-valid snapshot killed the reader instead of
      # being refused by name — or, as here, published.
      #
      # WHAT THIS DELIBERATELY DOES NOT DO is spread the row's own `reason` or
      # its `refusalReason` across the rows. Both are statements about the ROW,
      # and the mapping from a row fact onto an execution row is the entry the
      # producer left reasonless; where the producer named none, deciding that
      # the row's refusal is true of each execution separately would be the
      # reader making a claim the producer did not. Every entry already carries
      # the producer's own sentence, so nothing is left unexplained, and the
      # per-reason tally is unaffected because it is counted once per row where
      # the member is validated, above.
      if tracedAt >= 0:
        et = ExecTrace(selector: execSelectors[tracedAt], availability: taAbsent,
          reason: why, refusalReason: rr, bytes: 0, reconstructed: false,
          hasValidation: false, validation: ValidationSummary())

    # ── THE OVERLAY CARRIES ONE ROW PER EXECUTION THE PRODUCER NAMED ────────
    #
    # `et` above is the row for the execution the container belongs to — the one
    # entry without a `reason` of its own. Every OTHER entry is an execution this
    # capture did not trace and said why, so it publishes as `absent` with the
    # producer's own sentence, which is Static-Site-Architecture.md §2.3a's
    # vocabulary and not a new state.
    #
    # An UNTRACED row may leave no entry reasonless at all, and then `tracedAt`
    # is -1, no `k` matches it, and every row comes from the producer's own
    # `execSelectors[k]` / `execReasons[k]` — the all-absent overlay. See the
    # guard on `et` above for why that shape is contract-valid.
    #
    # THE ONE-EXECUTION SHAPE IS PRESERVED EXACTLY. §2.3b's overlay admits two
    # shapes — `singleTrace` for a transaction with one execution and `executions`
    # for one with several — and both have been contract-valid since the overlay
    # existed. A row with one execution therefore publishes the object it always
    # published, byte for byte; the list shape appears only where the producer
    # named more than one, which is the difference between carrying a producer's
    # list and always emitting more than one row.
    var etRows: seq[ExecTrace]
    for k in 0 ..< execSelectors.len:
      if k == tracedAt: etRows.add et
      else: etRows.add ExecTrace(selector: execSelectors[k], availability: taAbsent,
        reason: execReasons[k], bytes: 0, reconstructed: false,
        hasValidation: false, validation: ValidationSummary())
    let overlay =
      if etRows.len == 1:
        TraceSelection(chain: chain, tx: txHash, executions: @[],
                       hasSingle: true, singleTrace: etRows[0])
      else:
        TraceSelection(chain: chain, tx: txHash, executions: etRows,
                       hasSingle: false)
    cfg.writeJson(traceSelectionPath(chain, tsv, txHash, identifierEncoding),
                  overlay.toJson)

    for r in roles: participate(r.address, height, txHash)

  # ---- registry row, now that the published set is known -------------------
  # See the block above where `reg` was read and the incumbent pin checked. The
  # WRITE waits until here because `recorders` describes the containers this
  # ingest actually published, and that set is not known until the loop that
  # publishes them has run.
  #
  # THE DEFAULT PIN IS IN THE INVENTORY WHETHER OR NOT A CONTAINER USED IT. A
  # chain whose every container names a newer recorder still addresses its
  # older, recorder-less rows under the default, so a list that dropped it would
  # be describing a smaller tree than the one on disk.
  recorderInventory[rRef.build] = rRef
  var inventoryBuilds: seq[string]
  for b in recorderInventory.keys: inventoryBuilds.add b
  inventoryBuilds.sort()
  var recordersNode = newJArray()
  for b in inventoryBuilds:
    let r = recorderInventory[b]
    recordersNode.add %*{"id": r.id, "build": r.build, "version": r.version}
  # `identifierEncoding` IS PUBLISHED HERE AND IS THE SAME VALUE THIS PRODUCER
  # DERIVED ITS SHARD PATHS FROM — see `let identifierEncoding` at the top of
  # this proc, which says why it is one variable and not two.
  #
  # It states which encoding this chain writes its identifiers in, per kind of
  # identifier, drawn from a closed set — `contract/identifier_encoding.nim`,
  # over the shared `tools/chain/identifier-encodings.json`. Configuration.md
  # §2.1 is the schema and §2.2 the additive rule that makes writing it safe.
  #
  # WHAT A CONSUMER DOES WITH IT. Shard derivation takes it: the validator reads
  # this row back and recomputes the paths below from it, and the client pins it
  # on its session and recomputes the same paths in a browser, which is what
  # makes Search-And-Routing.md §5's "two requests to resolve any hash on any
  # chain" true for a chain that is not hex.
  #
  # TWO SITES STILL DERIVE FROM THE STRING AND ARE LATER STEPS. The hash index
  # (`contract/hashshard.nim`) parses hex pairs and lowercases unconditionally,
  # and it is a published self-describing wire format — so widening it is a
  # migration of every published shard plus a compatibility window
  # (Publishing-And-Caching.md §6.1, §6.2) and must land on its own. The capture
  # tooling filters published directory entries on a literal `0x`; it enumerates
  # the tree the index keys, so it follows the index.
  #
  # `hex` is MEASURED for this chain, not assumed — see `hexIdentifierEncoding`.
  reg["chains"][chain] = %*{
    "recorder": {"id": rRef.id, "build": rRef.build, "version": rRef.version},
    "recorders": recordersNode,
    "profile": {"name": pRef.name, "hash": pRef.hash},
    "traceSchema": traceSchema,
    "identifierEncoding": identifierEncoding.identifierEncodingNode()}
  cfg.writeJson(regRel, reg)

  # ---- address history -----------------------------------------------------
  addrOrder.sort()
  var addrRels: seq[string]
  for address in addrOrder:
    var heights: seq[int]
    for h in addrTxsByHeight[address].keys: heights.add h
    heights.sort(SortOrder.Descending)
    var segRels: seq[string]
    for h in heights:
      let rel = addressSegmentPath(chain, address, $h & "-" & $h,
                                   identifierEncoding)
      cfg.writeJson(rel, %*{"chain": chain, "address": address,
        "fromBlock": h, "toBlock": h,
        "transactions": addrTxsByHeight[address][h]})
      segRels.add rel
    let rel = addressIndexPath(chain, gen, address, identifierEncoding)
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
    txstateRels.add txStatePath(chain, gen, h, identifierEncoding)

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
  #
  # READ ONCE, WITH THE SAFE SUBSCRIPT, and that is not a style preference. This was
  # `if prov{"label"}.getStr.len > 0: prov["label"].getStr`, which cannot raise — but it
  # spells an unguarded `prov["label"]` in the source, and the spec-coverage check
  # (`tools/chain/snapshot-contract-selftest.mjs`) reads the ACCESS FORM as the statement
  # of whether a member is required, because that is what it means to `std/json`. A
  # bracket that is safe only because of a test three tokens to its left is a bracket that
  # says "required" to every reader, human or mechanical, that does not re-derive the
  # guard. One binding says the true thing once.
  let capturedLabel = prov{"label"}.getStr
  let provLabel =
    if capturedLabel.len > 0: capturedLabel
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
  # The counts as JSON, in the shared file's order so two summaries line up in a
  # diff, and zero-filled because `refusalReasonCounts` was seeded from the whole
  # set before the loop ran.
  proc refusalReasonsJsonCounts(t: Table[string, int]): JsonNode =
    result = newJObject()
    for id in refusalReasonIds(): result[id] = %t.getOrDefault(id, 0)
  var refusalTotal = 0
  for id in refusalReasonIds(): refusalTotal += refusalReasonCounts.getOrDefault(id, 0)

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
      # ── FOUR SAFE ACCESSORS, AND THE REASON IS A REPRODUCED CRASH ──────────
      #
      # These were four unguarded `prov["…"]`. In Nim's `std/json`, `JsonNode.[]`
      # with an absent string key RAISES `KeyError` — it does not return null —
      # so all four were mandatory members of a shape whose own spec
      # (Data-Contract.md §5.2) names none of them.
      #
      # Reproduced 2026-09-12 against the snapshot the real follower wrote
      # against Aztec MAINNET (`blocktracer-follow-chain`, node 5.2.0, 403
      # blocks, `/build/bt-ingest/accidental-400block`):
      #
      #     blocktracer-chain-ingest --snapshot … --out …
      #     { "ok": false, "error": "key not found: l1ChainId",
      #       "errorType": "KeyError" }   exit 1
      #
      # AND THE PRODUCER DOES WRITE THE KEY, which is what made this invisible.
      # `follow-chain.mjs` and `ingest-range.mjs` both set `l1ChainId:
      # nodeInfo.l1ChainId` — and `JSON.stringify` DROPS a key whose value is
      # `undefined`, so a node whose `getNodeInfo` omits the field produces a
      # snapshot with no such member while the producer source says otherwise.
      # In the same object literal `rollupAddress` carries `?? ''` and
      # `l1ChainId`, `nodeVersion` and `rollupVersion` did not, so it is a
      # node-response asymmetry rather than a network one. The producers now
      # carry the fallback too; this side stops the reader being the place a
      # missing optional member becomes a crash.
      #
      # The committed testnet fixtures all carry `l1ChainId: 11155111`, so the
      # whole test suite and every fixture were blind to it — the mainnet path
      # was the only one that omitted it. `tests/tchainsnapshot.nim` now drives
      # the captured mainnet snapshot through `ingestSnapshot`.
      #
      # `provOrNull` AND NOT A BARE `prov{"…"}`, which would trade a KeyError for a
      # segfault. `prov{key}` returns a **nil** `JsonNode` for an absent key, and
      # `std/json`'s `toUgly` dispatches on `node.kind` with no nil guard — so a
      # nil child crashes at serialisation instead of at the read. `provOrNull`
      # turns absence into an explicit JSON `null`, which is the honest answer:
      # the capture did not record it. The safe-subscript idiom itself is the
      # file's own — `prov{"label"}`, `prov{"runtimeCommit"}`, `snap{"format"}`.
      "endpoint": provOrNull("endpoint"),
      "capturedAt": provOrNull("capturedAt"),
      "nodeVersion": provOrNull("nodeVersion"),
      "l1ChainId": provOrNull("l1ChainId"),
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
      "detail": provDetail},
    # ── ING-3: THE PER-REASON REFUSAL COUNTS, AS AN OPERATIONAL MEASUREMENT ──
    #
    # PUBLISHED, not merely computed. The milestone's deliverable is that "a
    # reason whose count moves from zero is visible without anyone looking for
    # it", and the previous state of this file is the argument for it: the
    # ingest counted refusals into `refusedCount` and their type names into
    # `refusalNames`, and then wrote NEITHER anywhere — both were dead the
    # moment the loop ended, so the only operational statement about a refusal
    # was whatever prose the capture had written into the row.
    #
    # Every member on every summary, including the zeros. `untraced` and
    # `accountedFor` are here so the figures can be RECONCILED against
    # `counters.transactions`: a count that does not add up is the shape the
    # original defect had, and it went unnoticed because nothing ever added it
    # up.
    "refusals": {
      "byReason": refusalReasonsJsonCounts(refusalReasonCounts),
      "total": refusalTotal,
      "untraced": untracedCount,
      "traced": withTrace,
      "accountedFor": withTrace + untracedCount,
      "transactions": txCount,
      # The runtime error classes seen behind `runtime-refused` and its four
      # named siblings, deduplicated. OURS is the closed set above; this is
      # THEIRS, kept as evidence so a reader can tell which of eighty-four
      # classes produced a row without opening the snapshot.
      "runtimeClassesSeen": %refusalNames}})

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
    # THE FINALIZED TIP CAN MISS THE ENUMERATED SET IN EITHER DIRECTION, AND THE
    # TWO ARE NOT THE SAME MISTAKE. Below the range is the narrow-recent-window
    # case this branch was written for. ABOVE the range is what a whole-history
    # pass produces: enumerating 75,971 blocks takes an hour, the chain finalizes
    # more blocks while it runs, and the run then publishes a finalized tip
    # taller than any block it holds.
    #
    # Measured, on a genesis-to-tip pass: covered 1..75,971, node finalized at
    # 75,979, and this branch published `finalized: {height: 1}` — the OLDEST
    # block in the chain named as the finalized tip, eight blocks of drift turned
    # into a pointer that is wrong by the entire length of the chain.
    #
    # So resolve to the tallest block this generation actually carries that is
    # not above the node's finalized tip, and only fall back to the oldest when
    # every block it holds is above it.
    var i = blockRows.len - 1
    while i >= 0 and blockRows[i].height > finalizedAt: dec i
    if i < 0: i = 0
    finalizedHeight = blockRows[i].height
    finalizedHash = blockRows[i].hash
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
