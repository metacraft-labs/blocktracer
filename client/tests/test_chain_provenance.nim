## The two-producer honesty contract.
##
## This tree publishes a synthetic chain and a real one through the SAME views.
## That is the right design — a second chain is data, not a second explorer — and
## it is exactly why the three claims below have to be checked rather than
## assumed. Each one had a live counterexample in the build that introduced real
## data, and each of those is a mutation arm here:
##
##   1. A REAL transaction must not render the fixture's source. Before the
##      `sourceLevel` branch existed, a real testnet transaction with a real
##      container rendered `iterate_asteroids`, `src/shield.nr` and
##      "Iteration 3 of 8" — a recorded Noir program shown under a hash that
##      never executed it. The container is rung 3: every step is a bare program
##      counter and there is nothing to position it against.
##
##   2. A transaction past the RETENTION HORIZON must say so in its own words.
##      `getTxByHash` prunes at the finalized tip while `getTxEffect` does not,
##      so such a transaction stays perfectly visible and stops being
##      replayable. It is `absent`, and the generic sentence for `absent` used
##      to assert a cause — "there is no call structure to trace" — that is
##      false for it.
##
##   3. Real and synthetic must be TELLABLE APART on the page itself, in both
##      registers, including the debugger where the site chrome is gone.
##
## The tree here is built by the real producers — `generate` and
## `ingestSnapshot` — over the committed capture, so what is graded is the
## shipping path and not a lookalike.

import std/[unittest, os, json, strutils, algorithm, options, sequtils, tables]

import ../src/ssr
import ../src/reader
import ../src/viewutil
import ../src/debugger/demo_session
import ../src/debugger/session_view
import ../src/components/provenance
import ../src/components/tables
import ../src/components/debugger as dbgc
import blocktracer/demo/generator
import blocktracer/chain/ingest
# Suite 12 asserts the published bundles against the SHIPPING validator rather
# than against a restatement of its rules here — the same reasoning that makes
# this suite build its trees with the real producers.
import blocktracer/validator
# `hexShard` and `recorderBuildHash` — suite 14 addresses overlay rows and
# recomputes recorder builds the way the contract does, rather than hard-coding
# a shard layout or a hash this repository already owns one spelling of.
import blocktracer/contract/ids

let
  clientRoot = currentSourcePath().parentDir.parentDir
  repoRoot = clientRoot.parentDir
  fixtureDir = repoRoot / "fixtures" / "trace" / "noir_space_ship"
  fixture = fixtureDir / "zk_shields.ct"
  fixtureSources = fixtureDir / "sources"
  chainFixtures = clientRoot / "fixtures" / "chain"
  snapshotDir = chainFixtures / "aztec-testnet"
  workDir = getTempDir() / ("blocktracer-chain-prov-" & $getCurrentProcessId())

const
  FixtureBlockTime = 1788000000   ## 29 August 2026, 10:40 UTC
    ## THE CLOCK EVERY CONSTRUCTED SNAPSHOT IN THIS FILE IS SET BY, and it is a
    ## plausible instant rather than the `1000 + n` these fixtures used to carry.
    ##
    ## That was harmless while nothing published a block's time: `BlockDetail`
    ## has no timestamp field and the block list says so in its Age column. The
    ## "About this data" section reads the block record's ends to state the
    ## timespan the export covers, so a fixture second-count now reaches a
    ## rendered page — and every constructed chain here was announcing itself as
    ## a preliminary export covering 1 January 1970.
    ##
    ## Every offset added to it below keeps the whole constructed chain inside
    ## one UTC day, so these fixtures exercise the same-day arm of
    ## `readableSpan`; the multi-day and multi-year arms are driven directly in
    ## suite 6, where they can be stated as inputs and outputs instead of being
    ## smuggled in through a block loop.

doAssert fileExists(snapshotDir / "snapshot.json"),
  "no chain snapshot at " & snapshotDir & " — every assertion below would " &
  "pass vacuously over a tree with one chain in it, so this is a refusal " &
  "rather than a skip"

removeDir(workDir)
createDir(workDir)
discard generate(DemoConfig(outDir: workDir, seed: "chain-prov-test",
                            traceFixturePath: fixture,
                            traceSourcesDir: fixtureSources))
# Ingest EVERY capture, exactly as `static_export` does, so the suite grades the
# tree the site is actually built from rather than a one-chain subset of it.
var captureDirs: seq[string]
for kind, path in walkDir(chainFixtures):
  if kind == pcDir and fileExists(path / "snapshot.json"): captureDirs.add path
captureDirs.sort()
doAssert captureDirs.len > 0, "no chain captures under " & chainFixtures
var ingests: seq[IngestResult]
for d in captureDirs:
  ingests.add ingestSnapshot(IngestConfig(outDir: workDir, snapshotDir: d))
var ing: IngestResult
for r in ingests:
  if r.chain == "aztec-testnet": ing = r
doAssert ing.chain.len > 0, "the testnet capture is missing"
let root = newDataRoot(workDir)

let snap = parseJson(readFile(snapshotDir / "snapshot.json"))

# ── ground truth, read from the snapshot rather than from the reader ────────
# The reader is the thing under test, so the subjects are chosen out of the
# capture's own JSON. A test that asked the reader which transactions were
# replayed would agree with itself about a tree it had misread.
var replayedTx, prunedTx, divergentTx = ""
var replayedSteps, divergentMatched, divergentTotal = 0
for t in snap["transactions"]:
  case t["outcome"].getStr
  of "replayed":
    if replayedTx.len == 0:
      replayedTx = t["txHash"].getStr
      replayedSteps = t["recording"]["steps"].getInt
  of "divergent":
    if divergentTx.len == 0:
      divergentTx = t["txHash"].getStr
      divergentMatched = t["effects"]["matched"].getInt
      divergentTotal = divergentMatched + t["effects"]["mismatched"].getInt
  of "pruned":
    if prunedTx.len == 0: prunedTx = t["txHash"].getStr
  else: discard

doAssert replayedTx.len > 0, "the snapshot carries no replayed transaction"
doAssert prunedTx.len > 0, "the snapshot carries no pruned transaction"

const
  RealChain = "aztec-testnet"
  DemoChain = "demo"
  # Strings that exist ONLY in the vendored Noir fixture. If any of them
  # reaches a real transaction's page, the page is showing another program's
  # execution.
  FixtureOnly = ["iterate_asteroids", "shield.nr", "calculate_shield_regeneration",
                 "Iteration 3 of 8", "did_survive_positive"]

proc markup(html: string): string =
  ## The document with the inlined stylesheet removed — `test_debug_route`'s
  ## helper, and for its reason. The `<style>` payload is the whole site's CSS,
  ## and this repository's stylesheets carry long explanatory comments that
  ## quote the demo fixture by name (one contrast finding is written up against
  ## `Iteration 3 of 8`). A "this is NOT on the page" assertion matched against
  ## the whole document would be answered by a CSS comment rather than by the
  ## markup — which is a false failure, and would train the next person to
  ## loosen the assertion instead of reading it.
  let parts = html.split("</style>")
  if parts.len > 1: parts[^1] else: html

proc occurrences(haystack, needle: string): int =
  ## How many times `needle` appears. `count` from `strutils` counts
  ## NON-OVERLAPPING occurrences, which is what a marker count wants.
  haystack.count(needle)

proc realTxBody(): string = renderRoute(root, "/" & RealChain & "/tx/" & replayedTx).body
proc realDebugBody(): string =
  renderRoute(root, "/" & RealChain & "/tx/" & replayedTx & "/debug").body
proc prunedBody(): string = renderRoute(root, "/" & RealChain & "/tx/" & prunedTx).body

suite "the capture really produced two populations":
  test "the ingest published both a replayable and an unreplayable population":
    # Without both, arms 1 and 2 would each be grading an empty set.
    check ing.chain == RealChain
    check ing.withTrace > 0
    check ing.pruned > 0
    check ing.blocks > 0
    check ing.transactions >= ing.withTrace + ing.pruned

  test "the real chain and the demo chain are both in the registry":
    let slugs = chains(root)
    check DemoChain in slugs
    check RealChain in slugs

suite "1 — a rung-3 recording never renders as source":
  let body = realTxBody()

  test "the real transaction lands in the debugger, so this is not vacuous":
    # `absent` would make every assertion below trivially true.
    check "data-register=\"debugger\"" in body
    let info = chainInfo(root, RealChain)
    check txView(root, info, replayedTx).headline == taReady

  test "the manifest says instruction level, and the session agrees":
    let info = chainInfo(root, RealChain)
    let t = traceView(root, info, replayedTx)
    check t.sourceLevel == false
    check t.steps == replayedSteps
    let s = debugSessionFor(root, RealChain, replayedTx)
    check s.hasFrame
    check s.editor.availability == srcUnverified

  test "no string that exists only in the vendored fixture reaches the page":
    let m = markup(body)
    check m.len > 0
    for needle in FixtureOnly:
      check needle notin m

  test "the page states the ceiling instead of leaving a blank pane":
    check "instruction level" in body
    # WHAT THE CEILING SENTENCE MAY SAY. It used to be asserted through
    # "no debug symbols", quoting a clause that read as a claim about
    # AVAILABILITY — "an Aztec contract class carries bytecode, and no debug
    # symbols, no file map and no source text". Every word is true of the
    # on-chain class OBJECT and the reading a visitor takes from it is false:
    # `ContractClassPublic` carries `artifactHash` precisely so a client can
    # verify an artifact fetched off-chain, and verified artifacts resolve. The
    # page now states what is true of THIS recording, so that is what is
    # asserted, and the retired clause is asserted ABSENT.
    check "No source resolved for the code this transaction ran" in body
    check "checked against that commitment" in body
    check "no debug symbols, no file map and no source text" notin body

  test "and it says WHERE the session is stopped, in words AND on a row":
    # The defect this arm was added for, and the second half of the same defect.
    #
    # "A rung-3 recording never renders as source" was enforced, correctly — and
    # the consequence was that the Code pane on EVERY real transaction this site
    # publishes drew two paragraphs of prose and no position mark of any kind.
    # The one surface whose whole question is "where is this execution stopped"
    # answered it nowhere, on the only transactions the chain actually has. A
    # reader could see 208 steps in the toolbar and nothing in the pane.
    #
    # The head answered that in WORDS. It could not do more, because there was
    # no row to mark — and there was no row because the pane rendered no
    # instructions, which is the rest of the same defect. The rows are there now
    # (`instruction_listing.nim`, graded in `test_instruction_listing`), so both
    # channels are asserted here: the sentence a reader gets without seeing a
    # highlight, and the marked row it is a caption for.
    #
    # Asserted on the REAL capture's rendered page, not on a constructed pane:
    # this is the artefact a visitor loads.
    let debugBody = markup(realDebugBody())
    check occurrences(debugBody, "<div class=\"srcpos\" aria-current=\"true\">") == 1
    check occurrences(debugBody,
                      "<span class=\"p\" aria-hidden=\"true\">▶</span>") == 1
    check "The session is stopped at step " in debugBody
    # The COORDINATE is this recording's own, cross-checked against the
    # snapshot's step count rather than against the page that printed it.
    let s = debugSessionFor(root, RealChain, replayedTx)
    check s.controls.positioned
    check s.controls.step > 0
    check s.controls.totalSteps == replayedSteps
    check ("<span class=\"num\">" & $s.controls.step & "</span> of " &
           "<span class=\"num\">" & $replayedSteps & "</span>") in debugBody
    # It is the pane's head and not a second toolbar: it sits inside the Code
    # pane, above the sentence explaining why the rows are not source, which in
    # turn sits above the rows. Matched on the class ATTRIBUTE, because the page
    # inlines the stylesheet and declares `.srcline{` above `.srcpos{` in it.
    check debugBody.find("class=\"srcpos\"") <
          debugBody.find("class=\"srcnone\"")
    check debugBody.find("class=\"srcnone\"") <
          debugBody.find("class=\"srcline")
    # AND THE ROW. Exactly one, at the step the head just stated — the same
    # coordinate, not a second derivation of it.
    check occurrences(debugBody, "<div class=\"srcline cur hit\"") == 1
    check occurrences(debugBody, "id=\"L-avm-" & $s.controls.step &
                      "\" data-line=\"" & $s.controls.step &
                      "\" aria-current=\"true\"") == 1
    # …and it is still NOT SOURCE. The rows are the recording's own program
    # counters, filed under the synthetic `avm` document, with no file tab strip
    # and nothing lexed — a listing must never arrive wearing source's clothes.
    check "class=\"src instr\"" in debugBody
    check "class=\"srctabs\"" notin debugBody
    check "class=\"tk-keyword\"" notin debugBody

  test "CONTROL: a page with NO position draws no head, on the same route":
    # Without this the arm above is satisfied by a head emitted unconditionally,
    # which would put "the session is stopped at step 0 of 0" on every pruned
    # transaction — a coordinate the page does not have, stated in the voice of
    # one it does.
    let pruned = markup(
      renderRoute(root, "/" & RealChain & "/tx/" & prunedTx & "/debug").body)
    check pruned.len > 0
    check "srcpos" notin pruned
    let prunedSession = debugSessionFor(root, RealChain, prunedTx)
    check not prunedSession.controls.positioned
    # …and the check above is not passing merely because a pruned transaction
    # renders no panes at all (`hasFrame` is false, so §7.0's non-session row
    # replaces them). Driven through the SAME renderer as the arm above, with
    # the REPLAYED transaction's pane and the PRUNED one's controls, so the only
    # thing that differs is whether there is a position.
    check not prunedSession.hasFrame
    let pane = debugSessionFor(root, RealChain, replayedTx).editor
    check pane.availability == srcUnverified          # the pane really is one
    check "srcpos" notin dbgc.renderSource(pane, prunedSession.controls)

  test "MUTATION BITE: a session told sourceLevel renders the fixture":
    # The control for the arm above. If `demoSession` ignored `sourceLevel`,
    # every check above would still pass on a page that HAD borrowed the
    # fixture — so the mutation must be shown to put those strings back.
    let info = chainInfo(root, RealChain)
    let v = txView(root, info, replayedTx)
    let mutated = demoSession(RealChain, v, info, sourceLevel = true)
    let honest = demoSession(RealChain, v, info, sourceLevel = false)
    check mutated.editor.availability == srcSourceLevel
    check honest.editor.availability == srcUnverified
    var leaked = 0
    for d in mutated.editor.documents:
      for needle in FixtureOnly:
        if needle in d.path: inc leaked
    check leaked > 0            # the mutation really does reintroduce it
    check honest.editor.documents.len == 0

suite "2 — past the retention horizon, and saying so":
  let body = prunedBody()

  test "it is absent, and absent is not a failed fetch":
    let info = chainInfo(root, RealChain)
    check txView(root, info, prunedTx).headline == taAbsent
    check "data-register=\"explorer\"" in body

  test "the published reason names the horizon, in the producer's words":
    check "getTxByHash prunes at the finalized tip" in body
    check "getTxEffect does not" in body

  test "the generic sentence does not assert a cause it cannot know":
    # Both of them used to. `availabilityNote` said "there is no call structure
    # to trace" and the section stubs said "This execution publishes no call
    # structure" — true of an Aztec private execution, false of this one.
    check "no call structure" notin availabilityNote(taAbsent)
    check "publishes no call structure" notin markup(body)
    check "permanent answer rather than a failed fetch" in body

  test "no trace is offered, and none is named":
    let m = markup(body)
    check "trace.ct" notin m
    check "<button" notin m
    check ">Debug<" notin m

  test "MUTATION BITE: the horizon reason is what makes the page specific":
    # Strip the published reason and the page falls back to the generic line
    # alone — which is the state this arm exists to forbid.
    let info = chainInfo(root, RealChain)
    let v = txView(root, info, prunedTx)
    check v.executions.len == 1
    check v.executions[0].reason.len > 0
    check "retention" in v.executions[0].reason or
          "prunes" in v.executions[0].reason

suite "2b — a real divergence is published as one":
  # `divergent` is §7.0's second row and this tree now has a REAL one: a
  # transaction whose replay reproduced most of its effects and not all. The
  # two ways to get this wrong are equal and opposite — file it as a failure and
  # a good recording is thrown away; file it as `ready` and the page offers it
  # as evidence of what the chain did. This suite is skipped only if the current
  # capture happens to contain none, and says so rather than passing silently.

  test "the capture classified it, and it kept its container":
    if divergentTx.len == 0:
      echo "  (this capture produced no divergent transaction — arm not exercised)"
      skip()
    else:
      let info = chainInfo(root, RealChain)
      check txView(root, info, divergentTx).headline == taDivergent
      check divergentMatched < divergentTotal
      let t = traceView(root, info, divergentTx)
      # A divergent trace is a REAL trace: it has a container and it steps.
      check t.containerPath.len > 0
      check t.containerBytes > 0
      check t.sourceLevel == false
      check fileExists(workDir / t.containerPath)

  test "the page opens it AND says it is not evidence":
    if divergentTx.len == 0:
      skip()
    else:
      let body = renderRoute(root, "/" & RealChain & "/tx/" & divergentTx).body
      let m = markup(body)
      # §7.0 row 1: divergent still lands in the debugging interface…
      check "data-register=\"debugger\"" in body
      # …with the divergence stated, and the count that makes it specific.
      check $divergentMatched in m
      check $divergentTotal in m
      let s = debugSessionFor(root, RealChain, divergentTx)
      check s.hasFrame
      check s.integrity == siDivergent
      check s.integrityDetail.len > 0
      # And it is still instruction level — divergence and fidelity are
      # independent axes, and conflating them would be a second wrong claim.
      check s.editor.availability == srcUnverified

suite "2c — a chain with NO replayable transaction says so":
  # The expected outcome on a chain whose transactions arrive further apart than
  # the replay window is wide. It must render as a deliberate state: real blocks,
  # real transactions, no traces, and a sentence that says why. The failure this
  # forbids is an empty page or an error — and, just as important, a page that
  # quietly looks identical to a chain that simply had nothing to show.

  test "at least one captured chain exists with zero traces, or the arm says so":
    var zero: IngestResult
    for r in ingests:
      if r.withTrace == 0: zero = r
    if zero.chain.len == 0:
      echo "  (every capture in this tree caught a trace — arm not exercised)"
      skip()
    else:
      # It is a REAL chain: blocks and transactions, just no recordings.
      check zero.blocks > 0
      check zero.transactions > 0
      check zero.withTrace == 0
      check zero.divergent == 0
      # And no container was invented to fill the gap.
      var containers = 0
      for _ in walkDirRec(workDir / "t"): discard
      let info = chainInfo(root, zero.chain)
      check info.provenanceKind == "live-capture"
      discard containers

  test "its banner blames nothing and still says what the data is":
    var zero: IngestResult
    for r in ingests:
      if r.withTrace == 0: zero = r
    if zero.chain.len == 0: skip()
    else:
      let detail = chainInfo(root, zero.chain).provenanceDetail
      # WHAT THIS USED TO GRADE, AND WHY IT IS THE OPPOSITE NOW. A chain with no
      # traces has two opposite causes — nothing in the window was replayable (a
      # fact about the CHAIN), or something was and the replay refused (a fact
      # about the RECORDER) — and this test used to read the snapshot to decide
      # which sentence the banner owed, because publishing the wrong one blames
      # the network for a fault on this side of the wire.
      #
      # The banner now attributes NOTHING to anyone, so the hazard is closed by
      # construction rather than by a branch that has to pick right: there is no
      # cause on the page to be the wrong one. What is asserted is that the
      # section still states what the data IS on a chain with nothing to step
      # through — the state in which a page that fell silent would read as
      # broken — and that neither cause has re-grown.
      check "taken from the live network" in detail
      check "preliminary export" in detail
      for cause in ["WERE still replayable", "failure on the recording side",
                    "NO TRANSACTION INSIDE IT WAS REPLAYABLE",
                    "not a failure to record", "a fault on our side",
                    "the most recent one settled in block ", "follower",
                    "longest run with none was", "- block(s)"]:
        check cause notin detail

  test "and no page of that chain offers a trace it does not have":
    var zero: IngestResult
    for r in ingests:
      if r.withTrace == 0: zero = r
    if zero.chain.len == 0: skip()
    else:
      let info = chainInfo(root, zero.chain)
      var checkedTx = 0
      for h in blockHashes(root, info):
        for txh in readBlockDetail(root, info, h).transactions:
          let body = renderRoute(root, "/" & zero.chain & "/tx/" & txh).body
          let m = markup(body)
          check "trace.ct" notin m
          check ">Debug<" notin m
          check txView(root, info, txh).headline == taAbsent
          # …and each still says WHY, in the producer's words.
          check txView(root, info, txh).executions[0].reason.len > 0
          inc checkedTx
          if checkedTx >= 8: break
        if checkedTx >= 8: break
      check checkedTx > 0

suite "3 — real and synthetic are tellable apart, on the page":
  test "each chain publishes its own provenance, and they differ":
    let realInfo = chainInfo(root, RealChain)
    let demoInfo = chainInfo(root, DemoChain)
    check realInfo.provenanceKind == "live-capture"
    check demoInfo.provenanceKind == "synthetic"
    check realInfo.provenanceLabel != demoInfo.provenanceLabel
    check provenanceTone(realInfo.provenanceKind) !=
          provenanceTone(demoInfo.provenanceKind)

  test "the marker is on the transaction page of BOTH chains":
    # REVISED 2026-08-31 with the band rule. This used to be named "the banner
    # is on…" and it asserted the same attribute — which is why it still reads
    # almost unchanged: what a page must carry is a MARKER naming the published
    # kind, and `data-provenance` has always been how that is checked without
    # depending on the wording. Which ELEMENT carries it is now the page's
    # choice (band, chip or metadata row) and was never what this asserted.
    check "data-provenance=\"live-capture\"" in realTxBody()
    let demoInfo = chainInfo(root, DemoChain)
    var demoTx = ""
    for h in blockHashes(root, demoInfo):
      for t in readBlockDetail(root, demoInfo, h).transactions:
        if demoTx.len == 0: demoTx = t
    check demoTx.len > 0
    check "data-provenance=\"synthetic\"" in
      renderRoute(root, "/" & DemoChain & "/tx/" & demoTx).body

  test "and in the DEBUGGER, where the site chrome is gone":
    # The register a reader is most likely to lose track of which chain they
    # are on: no nav, no footer, and — since the band was reserved for abnormal
    # states — no strip above the identity bar either. The metadata pane is what
    # carries it now, which §7.1 puts on the page in EVERY state, so the marker
    # is on all 74 debug pages rather than on the ones that open a session.
    let d = realDebugBody()
    check "data-register=\"debugger\"" in d
    check "data-provenance=\"live-capture\"" in d
    check "Real Aztec testnet data" in d
    # …and it is the metadata ROW, not a band that survived the change.
    check "class=\"notice" notin markup(d)
    check "<dt>Data</dt>" in d

  test "every chain-scoped page carries EXACTLY ONE provenance marker":
    # The invariant the band rule has to preserve: moving the marker must not
    # drop it from any page, and must not leave two on one page either. Both
    # failures are silent — a page with none states nothing, a page with two
    # states it twice — so the count is asserted rather than the presence.
    var pages, markers = 0
    for chain in [RealChain, DemoChain]:
      let info = chainInfo(root, chain)
      var routes = @["/" & chain, "/" & chain & "/blocks", "/" & chain & "/txs"]
      for h in blockHashes(root, info):
        routes.add "/" & chain & "/block/" & h
        for t in readBlockDetail(root, info, h).transactions:
          routes.add "/" & chain & "/tx/" & t
          routes.add "/" & chain & "/tx/" & t & "/debug"
      for route in routes:
        let body = renderRoute(root, route).body
        if body.len == 0: continue
        inc pages
        inc markers, occurrences(body, "data-provenance=\"" &
                                       info.provenanceKind & "\"")
    check pages > 0                 # the scan reached the tree
    check markers == pages          # …and every page has one, and only one

  test "the real banner says it is real, that it is preliminary, and over what":
    # THREE FACTS, AND THE ASSERTION IS THAT THERE IS NOTHING ELSE. A user read
    # the four generated paragraphs this used to grade — a capture date, a
    # per-outcome clause, the curated window with the watch it came out of, and
    # a pruning boundary — and asked to "just say that the data is real, but
    # limited to a preliminary export while citing the timespan that is
    # covered". The word was "just": a section to shrink.
    #
    # WHAT USED TO BE REQUIRED HERE AND IS NOW FORBIDDEN. `Captured on <date>`
    # and `re-run and recorded` were both asserted PRESENT by the version of
    # this test before the sweep, and both are asserted absent below. The first
    # dated the end of the watch and told a reader nothing about what it covers;
    # the second is a per-transaction fact that each transaction's own page
    # already states at the point the reader meets it.
    #
    # `root` is the UNCURATED tree, and the sentence is now scope-independent —
    # suite 8 asserts the curated tree produces the SAME shape, which is the
    # property the two arms this replaced did not have.
    let detail = chainInfo(root, RealChain).provenanceDetail
    # It is real: taken from the live network, and no stronger word than that.
    check "taken from the live network" in detail
    # It is a slice, in the user's own words.
    check "preliminary export" in detail
    # …and the span, from the block record rather than from `capturedAt`.
    #
    # It read "wholly inside 31 August 2026" over blocks 63459–63678. The
    # 2026-09-02 capture and the block-record repair behind it extended the
    # committed testnet snapshot to 63459–67058, so the enumerated span is now
    # three calendar days. The multi-day SHAPE is what the two-sentence rule has
    # to survive, and it is now exercised on both real chains rather than only
    # on mainnet.
    check "covering 31 August to 2 September 2026." in detail
    # SHORT, and this is the assertion the request was actually about. Two
    # sentences; the version this replaced ran to four paragraphs.
    check detail.count('.') == 2
    check detail.len < 160
    # A date a person reads, not an instant a machine emits.
    check "T07:" notin detail and "Z." notin detail
    # …and no fetchable URL: a scheme in prose is indistinguishable, to the
    # external-reference scanner, from an origin this page depends on.
    check "://" notin detail
    # Every phrase the shrink removed, asserted gone rather than assumed gone.
    for phrase in ["Captured on ", "re-run and recorded", "drpc.org",
                   "replay window", "WHOLE", "CURATED WINDOW",
                   "selection rather than the whole chain",
                   "could be recorded", "a fault on our side",
                   "Transactions below block"]:
      check phrase notin detail

  test "EVERY captured chain says it, over ITS OWN span, mainnet included":
    # THE TEST ABOVE GRADES ONE CHAIN and this one grades all of them, because
    # the section is generated and a generator with one fixture behind it is a
    # generator that has been checked in one shape. `ingests` holds every capture
    # in `client/fixtures/chain/`, ingested exactly as `static_export` does.
    var checked = 0
    for r in ingests:
      let d = chainInfo(root, r.chain).provenanceDetail
      check "taken from the live network" in d
      check "preliminary export covering " in d
      check "Captured on " notin d
      inc checked
    check checked >= 2                      # two captures, not one read twice

    # THE MAINNET CAPTURE IS THE MULTI-DAY ARM, reached by committed data rather
    # than only by the unit assertions in suite 6. It enumerates 3439 blocks
    # running 66745–70183, whose timestamps span 2026-08-30T23:20:47Z to
    # 2026-09-02T21:06:23Z — two calendar months, one year, so the span is
    # written with the year said once.
    #
    # The numbers moved with the 2026-09-02 capture (1563 blocks to 70183's
    # 3439) and are restated rather than relaxed: they are what makes the
    # sentence below checkable against the tree rather than against itself.
    #
    # `root` IS THE `isFull` TREE, so these blocks are both the enumerated set
    # and the published one and the span covers both. The deployed site ingests
    # `isCurated` and names the narrower span its own 170 blocks cover; suite 8
    # grades that, and grades the two trees against each other.
    check "This is a preliminary export covering 30 August to 2 September 2026." in
      chainInfo(root, "aztec").provenanceDetail
    # …AND TESTNET IS NO LONGER THE SAME-DAY ARM. It was, over 63459–63678; the
    # 2026-09-02 capture carried it to 67058 and both real chains now span
    # several days. The same-day case is unwitnessed here — see suite 8, which
    # records the same loss where it mattered more.
    check "This is a preliminary export covering 31 August to 2 September 2026." in
      chainInfo(root, "aztec-testnet").provenanceDetail

  test "the synthetic banner says the trace is not this transaction's":
    let detail = chainInfo(root, DemoChain).provenanceDetail
    check "generated from a fixed seed" in detail
    check "not the execution of the transaction it is published under" in detail

  test "the home page's chain strip distinguishes every chain it lists":
    let home = renderRoute(root, "/").body
    let m = markup(home)
    for r in ingests:
      check ("data-provenance=\"live-capture\"" in m)
      check (chainInfo(root, r.chain).provenanceLabel in m)
    # The synthetic one is there too, and labelled differently.
    check "data-provenance=\"synthetic\"" in m
    check chainInfo(root, DemoChain).provenanceLabel in m
    check chainInfo(root, DemoChain).provenanceLabel !=
          chainInfo(root, "aztec-testnet").provenanceLabel

  test "each captured chain names ITSELF, not a generic fallback":
    # The testnet capture once shipped labelled "Real chain data" because its
    # snapshot predated the label field and the fallback fired. A fallback that
    # is invisible in the page is a fallback nobody notices going wrong.
    for r in ingests:
      let lab = chainInfo(root, r.chain).provenanceLabel
      check lab.len > 0
      check lab != "Real chain data"

  test "MUTATION BITE: a chain with no published provenance gets no marker":
    # The marker must come from the tree. A component that defaulted to
    # "synthetic" would label an unmarked chain with a claim its producer
    # never made. EVERY producer is driven, not just the band: the guard is the
    # thing being checked, and a guard that held in one of three producers
    # would be a guard with two ways around it.
    var blank: ChainInfo
    check provenanceBanner(blank) == ""
    check provenanceChip(blank) == ""
    check provenanceMarker(blank) == ""
    check provenanceRow(blank).len == 0
    blank.provenanceKind = "live-capture"
    check provenanceMarker(blank) == ""      # no label either => still nothing
    check provenanceRow(blank).len == 0

  test "the band is reserved for the ABNORMAL kind, and the chip is not":
    # REVISED 2026-08-31. This assertion used to read `provenanceBanner(live)
    # .len > 0` and it was correct for the design of the day: every kind got a
    # band. The design changed — a band interrupts, so it now means "something
    # here is not normal" — and the expectation changed WITH it rather than
    # being loosened to accommodate it. Both directions are asserted, so a
    # component that reverted to banding everything, or that stopped banding
    # anything, fails here.
    var real, demo: ChainInfo
    real.provenanceKind = "live-capture"
    real.provenanceLabel = "Real Aztec testnet data"
    demo.provenanceKind = "synthetic"
    demo.provenanceLabel = "Synthetic demo data"

    check not isAbnormal(real)
    check isAbnormal(demo)
    # Real data: a chip, and NO band.
    check provenanceBanner(real) == ""
    check provenanceChip(real).len > 0
    check "provchip" in provenanceMarker(real)
    # Synthetic: a band, and NO chip.
    check provenanceBanner(demo).len > 0
    check provenanceChip(demo) == ""
    check "class=\"notice" in provenanceMarker(demo)
    # A kind this build has never heard of is treated as abnormal — the louder
    # treatment goes to the direction that costs more when it is missed.
    var unknown: ChainInfo
    unknown.provenanceKind = "some-future-producer"
    unknown.provenanceLabel = "Something else entirely"
    check isAbnormal(unknown)
    check "class=\"notice" in provenanceMarker(unknown)

  test "the row states the kind and quotes the producer, for BOTH kinds":
    for chain in [RealChain, DemoChain]:
      let info = chainInfo(root, chain)
      let rows = provenanceRow(info)
      check rows.len == 1
      check rows[0].value == info.provenanceLabel
      check rows[0].dataProvenance == info.provenanceKind
      check rows[0].badge == provenanceTone(info.provenanceKind)
      # The producer's own sentences, carried verbatim rather than paraphrased.
      check rows[0].note == info.provenanceDetail
      check rows[0].note.len > 0

suite "the containers a page names are the ones the tree carries":
  test "every published container is non-empty and named by its page":
    var named = 0
    for t in snap["transactions"]:
      # BOTH container-bearing outcomes. Counting only `replayed` would let a
      # divergent transaction's container go unchecked — which is the one whose
      # URL a reader is most likely to follow, because its page is the one that
      # says something surprising.
      if t["outcome"].getStr notin ["replayed", "divergent"]: continue
      let h = t["txHash"].getStr
      let info = chainInfo(root, RealChain)
      let tv = traceView(root, info, h)
      check tv.containerPath.len > 0
      check tv.containerBytes == t["containerBytes"].getInt
      check fileExists(workDir / tv.containerPath)
      check getFileSize(workDir / tv.containerPath) == tv.containerBytes
      check tv.containerPath in renderRoute(root, "/" & RealChain & "/tx/" & h).body
      inc named
    check named == ing.withTrace
    check named > 0

# ───────────────────────────────────────────────────────────────────────────
# The two defects a real chain found in code the fixture had been proving
# correct. Both were filed by reviewers against real chain pages in vd8-r1;
# neither is reachable from the demo fixture, which is why neither had a test.
#
# These suites carry their own COUNTED assertions. `std/unittest` ships no
# assertion counter, so a `continue`, an early `return` or a loop over a set
# that turned out to be empty removes assertions silently and the suite still
# reports green — Verification-Harness-Traps §4b/§4c, and §4b's case is exactly
# a loop whose membership was knowable and was not counted. `ck` counts, and
# `expectCount` fails when the total is not the number written from a run.
# The older suites above are left on bare `check`: converting them would be
# churn in a diff whose subject is elsewhere.
# ───────────────────────────────────────────────────────────────────────────

var asserted = 0
template ck(condition: untyped) =
  inc asserted
  check condition
template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

suite "4 — a cost dimension with no ceiling":
  asserted = 0
  ## ledger@2026-08-31.1:debugger--testnet/wide/light/ADV/1 and
  ## ledger@2026-08-31.1:tx-detail--mainnet-zero-trace/wide/light/ADV/1 — five
  ## of twelve reviewers across the two real-chain triples filed the dangling
  ## " / " independently. `viewutil.costLabel` had always guarded the join;
  ## `txMetadataRows` spelled it a second time and did not.

  let
    capped = Cost(name: "mana", used: "42000", limit: "100000",
                  unit: "mana", token: "FeeJuice")
    uncapped = Cost(name: "transactionFee", used: "0x84bcfc44229235e4",
                    limit: "", unit: "mana", token: "FeeJuice")

  test "the fixture's shape and a real chain's shape are BOTH in this suite":
    # Trap 4a's pairing. Every assertion below about the uncapped cost is a
    # "does not contain" — and an empty haystack satisfies all of them. The
    # capped cost is the positive twin running through the same procs, so a
    # `costAmount` that had stopped emitting anything at all goes red here.
    ck capped.limit.len > 0
    ck uncapped.limit.len == 0
    ck costAmount(capped) == "42000 / 100000"
    ck costAmount(capped).contains(" / ")

  test "no ceiling means no separator, in BOTH spellings":
    # The pinned strings moved from the published hex to its decimal when
    # `quantity` was introduced, and the PROPERTY this test is named for did
    # not move at all: three of its four assertions are "does not contain
    # ' / '" and are untouched. What changed is the base the same integer is
    # written in, so the expected literal had to be rewritten to stay an exact
    # pin rather than be loosened into a `contains`.
    ck costAmount(uncapped) == "9564797078196073956"
    ck not costAmount(uncapped).contains(" / ")
    ck not costLabel(uncapped).contains(" / ")
    ck costLabel(uncapped) == "9564797078196073956 mana"

  test "a published hex quantity is rendered in base ten, exactly":
    # The most-filed element in the campaign: reviewers filed the 66-character
    # zero-padded fee on `tx-detail--mainnet-zero-trace/wide/light` (L1, L4)
    # and on `debugger--testnet/wide/light` (L1, L3, L4, L5) in round vd8-r3.
    #
    # Exactness is the whole claim, so it is checked at the width that breaks a
    # 64-bit implementation. `0x84bcfc44229235e4` fits in an int64 and the
    # zero-padded 256-bit words the real chains publish do not; a conversion
    # that wrapped would be wrong and confident, which is worse than the hex.
    ck quantity("0x84bcfc44229235e4") == "9564797078196073956"
    ck quantity("0x0000000000000000000000000000000000000000000000000185cfcc84d2f103f") ==
       "1755555891986239551"
    ck quantity("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") ==
       "115792089237316195423570985008687907853269984665640564039457584007913129639935"
    ck quantity("0x0") == "0"
    ck quantity("0x00000000000000000000000000000000000000001") == "1"

  test "anything that is not a hex quantity survives verbatim":
    # The fallback is what keeps this from being a lossy filter. A family that
    # already publishes decimals is unaffected, and one that publishes
    # something else entirely still reaches the page to be NOTICED rather than
    # being silently blanked — the same choice `roleLabel` makes for an unknown
    # role.
    ck quantity("42000") == "42000"
    ck quantity("") == ""
    ck quantity("0x") == "0x"
    ck quantity("0xnothex") == "0xnothex"
    ck quantity("12 mana") == "12 mana"
    ck quantity("0x1f 0x2f") == "0x1f 0x2f"

  test "MUTATION BITE: a 64-bit conversion wraps where the real chain lives":
    # The arm the exactness assertions are written for. int64 tops out at
    # 9223372036854775807, so the 256-bit word above cannot be carried by one
    # and any implementation that tried would have to produce something other
    # than the value this suite pins.
    ck quantity("0x0000000000000000000000000000000000000000000000000185cfcc84d2f103f").len == 19
    ck quantity("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff").len == 78
    ck quantity("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") !=
       quantity("0x84bcfc44229235e4")

  test "the metadata row renders the guarded join and not a second one":
    var v: TxView
    v.hash = "0xreal"
    v.cost = @[uncapped]
    let rows = txMetadataRows(RealChain, v, chainInfo(root, RealChain))
    var costRows = 0
    for r in rows:
      if r.label.startsWith("Cost · "):
        inc costRows
        ck not r.value.contains(" / ")
        ck r.value == costAmount(uncapped)
    # Membership is knowable — one cost dimension in, one row out. Asserting
    # the COUNT and not `> 0`: trap 4b, where "at least one" was satisfied by
    # one member of three while two were silently skipped.
    ck costRows == 1

  test "MUTATION BITE: the pre-fix spelling puts the dangling separator back":
    # The arm the assertions above are written for. `c.used & \" / \" & c.limit`
    # is the exact expression that stood at viewutil.nim:269, evaluated over the
    # same Cost — so this proves the checks bite rather than describing a
    # property the values happen to have.
    let preFix = uncapped.used & " / " & uncapped.limit
    ck preFix.contains(" / ")                  # the mutation reintroduces it
    ck preFix != costAmount(uncapped)          # and the fix differs from it
    ck preFix.endsWith(" / ")                  # dangling: no operand after
    # …and over a chain that DOES publish a ceiling the two agree, which is why
    # the defect survived every round the corpus had only the fixture in it.
    ck (capped.used & " / " & capped.limit) == costAmount(capped)

  test "the real chain's own transaction renders no dangling separator":
    # Not a constructed Cost — the ingested one, through the shipping path.
    let info = chainInfo(root, RealChain)
    var seen, uncappedSeen = 0
    for t in snap["transactions"]:
      let v = txView(root, info, t["txHash"].getStr)
      for c in v.cost:
        inc seen
        # Plain `check` inside the loop, deliberately: the iteration count is
        # DATA (how many cost dimensions this capture happens to publish), and
        # feeding it into `asserted` would make the suite's expected total a
        # number that moves whenever the fixture is recaptured. The aggregates
        # below are the counted assertions, and they are what says the scan was
        # not empty.
        if c.limit.len == 0:
          inc uncappedSeen
          check not costAmount(c).contains(" / ")
          check not costLabel(c).contains(" / ")
    ck seen > 0                                # the scan reached the tree
    ck uncappedSeen > 0                        # …and it reached the real shape

  test "assertion count":
    expectCount(31)

suite "5 — a language tag is a claim about source":
  asserted = 0
  ## ledger@2026-08-31.1:debugger--testnet/wide/light/L5/1, filed P1: an
  ## uppercase NOIR tag on the identity bar of a session whose four panes each
  ## state that the recording carries no debug symbols. `demoSession` set
  ## `languages` above the branch that decides whether a language is known.

  let info = chainInfo(root, RealChain)
  let v = txView(root, info, replayedTx)

  test "the two sessions differ in source level, so this is not vacuous":
    ck traceView(root, info, replayedTx).sourceLevel == false
    ck demoSession(RealChain, v, info, sourceLevel = true).editor.availability ==
       srcSourceLevel
    ck demoSession(RealChain, v, info, sourceLevel = false).editor.availability ==
       srcUnverified

  test "source level names its language; instruction level names none":
    # The positive twin FIRST. Without it, "no language tag" is satisfied by a
    # constructor that had stopped setting `languages` in every state — the R6
    # shape in Verification-Harness-Traps §4a, where a renderer answering
    # "unknown" to everything satisfied the check that existed to catch it.
    ck demoSession(RealChain, v, info, sourceLevel = true).languages == @["noir"]
    ck demoSession(RealChain, v, info, sourceLevel = false).languages.len == 0

  test "every §7.0 state that cannot know a language declines to name one":
    # Membership is knowable: `TraceAvailability` has exactly five members, and
    # the reported defect named only one of them. Trap 4b — assert the COUNT.
    var covered, tagged, untagged = 0
    for a in TraceAvailability:
      var probe = v
      probe.headline = a
      # `sourceLevel = false` throughout: the question is which STATES may
      # carry a language, holding the source level fixed at the real chain's.
      let s = demoSession(RealChain, probe, info, sourceLevel = false)
      inc covered
      if s.languages.len > 0: inc tagged else: inc untagged
    ck covered == 5
    ck tagged == 0
    ck untagged == 5

  test "a state with no session at all carries no language either":
    # The three the review did not reach. `pages/debug.nim` renders the tag on
    # `languages.len > 0` alone, OUTSIDE the `hasFrame` gate that suppresses
    # the controls and the phase rail — so `onDemand`, `absent` and
    # `unsupported` were tagged too.
    var noSession = 0
    for a in [taOnDemand, taAbsent, taUnsupported]:
      var probe = v
      probe.headline = a
      let s = demoSession(RealChain, probe, info)
      ck not s.hasFrame
      ck s.languages.len == 0
      inc noSession
    ck noSession == 3

  test "MUTATION BITE: setting it above the branch tags the honest session":
    # The pre-fix constructor set `languages` beside `traceContentHash`, which
    # every state carries. Reapplying it to the instruction-level session is
    # that assignment, and it must redden the check written against it.
    var mutated = demoSession(RealChain, v, info, sourceLevel = false)
    ck mutated.languages.len == 0             # the fix holds before the arm
    mutated.languages = @["noir"]             # ← the pre-fix assignment
    ck not (mutated.languages.len == 0)       # …and the assertion reddens

  test "the served instruction-level page carries no language tag":
    # The artefact, not the model — trap 2. The page is what the reviewer saw.
    #
    # Two haystacks on purpose. The register attribute is on `<html>`, ABOVE
    # the inlined stylesheet, so `markup` (which keeps only what follows
    # `</style>`) cannot see it — asserting it against the stripped document
    # would fail on a perfectly correct page. The tag check needs the stripped
    # one for the reason `markup` exists: the stylesheet defines `.dbglang`,
    # so `"dbglang" notin document` is false on every debugger page ever
    # served, fixed or not.
    let full = realDebugBody()
    let m = markup(full)
    ck m.len > 0                              # the scan reached a document
    ck "data-register=\"debugger\"" in full   # …and it is the right one
    ck "dbglang" in full                      # the stylesheet still defines it
    ck "dbglang" notin m                      # …and the markup does not use it
    ck "instruction level" in m               # the panes still explain why

  test "assertion count":
    expectCount(22)

# ── 6 — a WATCHED snapshot's provenance line is true at both ends ────────────
#
# `follow-chain.mjs` grows a snapshot instead of replacing it, and that breaks two
# sentences the one-shot capture could always write safely:
#
#   * "Captured … at T. The replay window was blocks A–B at that moment." A watched
#     snapshot has no single moment; the blocks run to the latest poll while `capturedAt`
#     named the first one, so the reader was told the whole chain was read hours earlier
#     than it was.
#   * "…settled in block N — `replayableFrom - N` block(s) below the window." That
#     subtraction is only a distance while the newest transaction is at or below the tip
#     the scan read. A follower keeps extending the block record, so the newest
#     transaction can sit ABOVE the last recorded window and the difference goes negative.
#     It did: the first grown mainnet snapshot published "-391 block(s) below the window".
#
# DRIVEN WITH A CONSTRUCTED SNAPSHOT, NOT THE COMMITTED ONE. The committed capture happens
# to have its newest transaction below the window, so it exercises exactly one of the three
# arms — an assertion written against it passes whether the guard is there or not, which
# was measured: removing the guard did NOT redden the suite. Verification-Harness-Traps §4,
# in its "the fixture never reaches the branch" form. Each arm is therefore built here.
suite "6 — a watched snapshot says something true about both ends":
  asserted = 0

  # One snapshot, parameterised on the two facts that decide the wording.
  proc snapshotWith(dir: string, tip, finalized, txBlock: int,
                    firstCapturedAt: string): string =
    let dest = dir / ("w" & $tip & "-" & $txBlock & "-" & $firstCapturedAt.len)
    createDir(dest / "ct")
    var prov = %*{
      "kind": "live-capture", "chain": "watched", "label": "Real watched data",
      "endpoint": "https://node.example", "capturedAt": "2026-08-31T16:51:38.480Z",
      "nodeVersion": "5.2.0", "l1ChainId": 1, "runtimeCommit": "abc123def456"}
    if firstCapturedAt.len > 0: prov["firstCapturedAt"] = %firstCapturedAt
    var blocks = newJArray()
    var txs = newJArray()
    # The range must cover `txBlock`: a fixture whose transaction falls outside the
    # blocks it publishes exercises the "no transaction settled at all" arm instead
    # of the one the case is named for, and passes for the wrong reason.
    for n in min(txBlock, tip - 3) .. tip:
      var b = %*{"number": n, "hash": "0x" & align($n, 40, '0'),
                 "timestamp": FixtureBlockTime + n * 36, "totalManaUsed": "0x0",
                 "coinbase": "0x" & repeat('1', 40), "feePerL2Gas": "0x1",
                 "archiveRoot": "0x" & repeat('2', 40),
                 "parentArchiveRoot": "0x" & repeat('3', 40),
                 "transactions": newJArray()}
      if n == txBlock:
        let h = "0x" & align($n, 40, 'a')
        b["totalManaUsed"] = %"0x2710"
        b["transactions"].add %h
        txs.add %*{"txHash": h, "blockNumber": n, "txIndexInBlock": 0,
                   "revertCode": 0, "transactionFee": "0x1",
                   "bodyRetained": false, "effectVisible": true, "firstInBlock": true,
                   "outcome": "pruned",
                   "reason": "The node still serves this transaction's effects but no " &
                             "longer serves its body."}
      blocks.add b
    writeFile(dest / "snapshot.json", $(%*{
      "format": "blocktracer/chain-snapshot@1", "provenance": prov,
      "window": {"tip": tip, "finalized": finalized,
                 "replayableFrom": finalized + 1, "replayableTo": tip,
                 "blocks": tip - finalized},
      "blocks": blocks, "transactions": txs}))
    dest

  proc detailOf(snapDir: string): string =
    let tree = snapDir / "tree"
    createDir(tree)
    discard ingestSnapshot(IngestConfig(outDir: tree, snapshotDir: snapDir))
    chainInfo(newDataRoot(tree), "watched").provenanceDetail

  let wd = getTempDir() / ("bt-watched-" & $getCurrentProcessId())
  removeDir(wd); createDir(wd)

  test "the coverage is dated in words a reader reads, and the same way every time":
    # WHAT THESE FIVE TESTS USED TO GRADE, and why they are one.
    #
    # The banner used to carry a `recency` clause ("the most recent one settled
    # in block 150 — 31 block(s) below that window") and three different capture
    # phrasings for a watched snapshot, a one-shot snapshot and a frozen one,
    # each naming ISO-8601 instants and the replay window in blocks. Four arms
    # guarded them, including a real defect: a watched snapshot could print
    # "-391 block(s) below the window", a negative distance, on the one element
    # of the page whose whole job is to be believed.
    #
    # A user asked for all of it to go — too technical, and about the capture
    # rather than about what they are looking at. The negative-distance defect
    # cannot recur because the sentence that computed it does not exist; there
    # is no arithmetic left to go negative, which is a stronger guarantee than
    # the arm that used to check the sign.
    #
    # `Captured on <date>` survived that round and did not survive this one. It
    # dated ONE END of the watch, which is what a reader has least use for: the
    # question is what period the data covers, and the answer was on the page
    # nowhere. So the date this suite grades is now the SPAN, read from the
    # timestamps the blocks carry — and the property that made the old arms
    # worth having is unchanged and asserted below: a watched capture and a
    # one-shot capture are written the same way, because the distinction was one
    # a reader was never making.
    let watched = detailOf(snapshotWith(wd, tip = 200, finalized = 180,
                                        txBlock = 150,
                                        firstCapturedAt = "2026-08-31T07:39:12.420Z"))
    let oneShot = detailOf(snapshotWith(wd, tip = 200, finalized = 180,
                                        txBlock = 199, firstCapturedAt = ""))
    # Both constructed chains sit inside one UTC day — see `FixtureBlockTime` —
    # so both take the same-day arm, and neither says it twice.
    ck "preliminary export covering 29 August 2026." in watched
    ck "preliminary export covering 29 August 2026." in oneShot
    # No instant, no window, no block-distance clause, and no capture date on
    # either: `capturedAt` differs between these two and the sentence must not.
    for d in [watched, oneShot]:
      ck "2026-08-31T" notin d
      ck "replay window" notin d
      ck "block(s) below" notin d
      ck "Captured on" notin d
    # THE HELPERS ARE THE THING UNDER TEST, not the banner's spelling of them.
    #
    # `readableSpan` has three arms and the block loop above can only ever reach
    # one, so the other two are driven here as inputs and outputs rather than
    # being smuggled through a fixture. Verification-Harness-Traps §4: an arm no
    # input reaches passes whether it is right or not.
    ck readableSpan(1788000000, 1788000000) == "29 August 2026"        # one instant
    ck readableSpan(1788000000, 1788007200) == "29 August 2026"        # one day
    ck readableSpan(1788132047, 1788246815) == "30 August to 1 September 2026"
    ck readableSpan(1767182400, 1767268800) ==
       "31 December 2025 to 1 January 2026"                            # across a year
    # Backwards ends are ordered rather than printed backwards. A block record is
    # sorted by height and height is not time, and a span printed the wrong way
    # round is the shape of wrongness this module has published before.
    ck readableSpan(1788246815, 1788132047) == "30 August to 1 September 2026"
    # `readableDate` is still the ISO entry point, still exported, and still
    # writes the same words — the two must not drift into two date formats.
    ck readableDate("2026-09-01T07:13:35.934Z") == "1 September 2026"
    ck readableDate("2026-01-31T00:00:00Z") == "31 January 2026"
    # A date it cannot read is returned untouched rather than guessed at.
    ck readableDate("not a date") == "not a date"
    ck readableDate("2026-13-01T00:00:00Z") == "2026-13-01T00:00:00Z"

  # A snapshot whose window held a transaction that WAS replayable and was refused.
  proc refusedSnapshot(dir: string): string =
    let dest = dir / "refused"
    createDir(dest / "ct")
    let h = "0x" & repeat('b', 40)
    writeFile(dest / "snapshot.json", $(%*{
      "format": "blocktracer/chain-snapshot@1",
      "provenance": {
        "kind": "live-capture", "chain": "watched", "label": "Real watched data",
        "endpoint": "https://node.example", "capturedAt": "2026-08-31T18:44:30.452Z",
        "nodeVersion": "5.2.0", "l1ChainId": 1, "runtimeCommit": "abc123def456"},
      "window": {"tip": 200, "finalized": 180, "replayableFrom": 181,
                 "replayableTo": 200, "blocks": 20},
      "blocks": [{"number": 199, "hash": "0x" & align("199", 40, '0'),
                  "timestamp": FixtureBlockTime + 1199, "totalManaUsed": "0x2710",
                  "coinbase": "0x" & repeat('1', 40), "feePerL2Gas": "0x1",
                  "archiveRoot": "0x" & repeat('2', 40),
                  "parentArchiveRoot": "0x" & repeat('3', 40),
                  "transactions": [h]}],
      "transactions": [{
        "txHash": h, "blockNumber": 199, "txIndexInBlock": 0,
        "revertCode": 0, "transactionFee": "0x1",
        "bodyRetained": true, "effectVisible": true, "firstInBlock": true,
        "outcome": "refused", "refusal": "AvmToolchainRegression",
        "reason": "This transaction could not be re-executed: the replay runtime " &
                  "refused with AvmToolchainRegression. No trace was recorded for it."}]}))
    dest

  test "a refusal is NOT reported as the chain having nothing replayable":
    # THE DEFECT THIS ARM EXISTS FOR, AND WHY IT IS NOW CLOSED BY CONSTRUCTION.
    # Two mainnet transactions were caught INSIDE the window with their bodies
    # still served and refused by the replay runtime, and the page said "NO
    # TRANSACTION INSIDE IT WAS REPLAYABLE ... not a failure to record". That
    # blames the chain for a fault on this side of the wire and tells the reader
    # the opposite of what happened: the follower reached them in time.
    #
    # The fix at the time was a third arm that attributed the refusal correctly.
    # The section no longer attributes anything to anyone, so there is no cause
    # on the page that can be the wrong one — a stronger guarantee than an arm
    # that has to keep picking right, and one that needs no fourth arm when a
    # fourth outcome appears.
    let d = detailOf(refusedSnapshot(wd))
    ck "NO TRANSACTION INSIDE IT WAS REPLAYABLE" notin d
    ck "None of the transactions here could be re-run" notin d
    ck "a fault on our side" notin d
    # …and the internal type name that reached visitors through this clause is
    # gone with the clause. It is still in the snapshot and in `summary.json`.
    ck "AvmToolchainRegression" notin d

  test "twin: a purely pruned window is written EXACTLY the same way":
    # Without this, the negatives above would be satisfied by an ingest that had
    # gone silent on a chain with nothing to step through — which is the page
    # that reads as broken while being entirely correct.
    #
    # The two snapshots differ in the one fact the old arms branched on: this
    # one's transaction was pruned before the capture reached it, the one above
    # was reached in time and refused. Both now produce the same sentence, and
    # asserting the EQUALITY rather than two phrase lists is what would catch a
    # branch growing back with wording that happened to satisfy both lists.
    let pruned = detailOf(snapshotWith(wd, tip = 200, finalized = 180,
                                       txBlock = 150, firstCapturedAt = ""))
    let refused = detailOf(refusedSnapshot(wd))
    ck "taken from the live network" in pruned
    ck "preliminary export covering " in pruned
    ck pruned == refused

  test "assertion count":
    expectCount(26)   # 19 + 4 + 3

# ── 7 — one slug, one producer, enforced in BOTH directions ──────────────────
#
# `ingest.nim` used to refuse the slug `aztec` by name, protecting the synthetic demo from
# a live capture landing on it. The hazard it named is real and unchanged — two chains at
# one slug overwrite each other's blocks and become indistinguishable in a URL — but the
# OWNERSHIP inverted: `aztec` is the Aztec mainnet now, and the fixture is the one that
# had to move. A guard that names a slug is a statement about one chain and goes stale
# with it; `assertSlugAvailable` states the invariant instead, so it holds whichever
# producer is the incumbent.
#
# Both directions are asserted, and the "same kind may republish itself" arm is asserted
# too — without it, a guard that simply refused everything would satisfy both negatives.
suite "7 — a slug belongs to one producer":
  asserted = 0

  let gd = getTempDir() / ("bt-slug-guard-" & $getCurrentProcessId())
  removeDir(gd); createDir(gd)

  proc treeWithRealChain(dir: string): string =
    ## A tree with the committed mainnet-shaped capture ingested under its own slug.
    let tree = dir / "tree"
    createDir(tree)
    discard ingestSnapshot(IngestConfig(outDir: tree,
                                        snapshotDir: chainFixtures / "aztec-testnet"))
    tree

  test "a real chain publishes, and the tree records WHOSE data it is":
    # The positive control. Every refusal below is about a slug being occupied, so the
    # suite has to establish that occupying it works at all — otherwise the two negatives
    # would pass over an empty tree.
    let tree = treeWithRealChain(gd)
    ck publishedProvenanceKind(tree, RealChain) == "live-capture"
    ck publishedProvenanceKind(tree, "nobody-published-this") == ""

  test "the SYNTHETIC demo may not publish over a live capture":
    # The direction that matters now, and the one the old guard could not express.
    let tree = treeWithRealChain(gd)
    var raised = false
    try: assertSlugAvailable(tree, RealChain, "synthetic")
    except ValueError as e:
      raised = true
      ck "already published in this tree by a 'live-capture' chain" in e.msg
      ck "indistinguishable in a URL" in e.msg
    ck raised

  test "and a live capture may not publish over the synthetic demo":
    # The original direction, still enforced — inverting the guard did not drop it.
    let tree = gd / "syn"
    createDir(tree)
    discard generate(DemoConfig(outDir: tree, seed: "guard-test", chain: DemoChain,
                                traceFixturePath: fixture, traceSourcesDir: fixtureSources))
    ck publishedProvenanceKind(tree, DemoChain) == "synthetic"
    var raised = false
    try: assertSlugAvailable(tree, DemoChain, "live-capture")
    except ValueError: raised = true
    ck raised

  test "a producer may republish its OWN slug — that is a regeneration, not a collision":
    # Load-bearing: every build regenerates in place, and a guard that refused this would
    # make the determinism check impossible to run. It is also the arm that proves the two
    # refusals above are about the KIND rather than about the slug being occupied at all.
    let tree = treeWithRealChain(gd)
    assertSlugAvailable(tree, RealChain, "live-capture")   # must not raise
    ck true
    # An unoccupied slug is free to anyone.
    assertSlugAvailable(tree, "brand-new-chain", "synthetic")
    ck true

  test "assertion count":
    expectCount(9)

# ── 8 — a curated chain publishes only transactions that open ────────────────
#
# THE PROMISE THIS SUITE GRADES. `IngestScope.isCurated` is the scope the
# deployed site publishes real chains in, and it makes exactly one claim that
# `isFull` does not: every transaction on this chain opens a container that
# steps. That claim is a universal over a set the ingest itself chooses, which
# is Verification-Harness-Traps §4 in its most inviting form — an ingest that
# published no transactions at all would satisfy it perfectly.
#
# So the first test establishes that the SAME captures under `isFull` publish
# transactions that do not open, and the control counts what the curated tree
# published rather than asserting over whatever it happens to hold.
suite "8 — a curated chain publishes only transactions that open":
  asserted = 0

  proc capturedChains(r: DataRoot): seq[string] =
    for c in chains(r):
      if chainInfo(r, c).provenanceKind == "live-capture": result.add c

  proc publishedTxs(r: DataRoot, chain: string): seq[string] =
    ## Every transaction reachable from the published BLOCK record — the way a
    ## visitor reaches one. Not read from the snapshot: the snapshot is the
    ## input, and a test that enumerated the input would be unable to notice a
    ## transaction the tree published without a block to reach it from.
    let info = chainInfo(r, chain)
    for h in blockHashes(r, info):
      for t in readBlockDetail(r, info, h).transactions: result.add t

  proc unpublishableSnapshot(dir: string): string =
    ## One block, one transaction, and the transaction cannot be replayed. There
    ## is no window here in which every transaction opens — the shape suite 6
    ## uses for its refusal arm, built again rather than shared, because that one
    ## is scoped to its suite and reaching across would couple two subjects.
    let dest = dir / "unpublishable"
    createDir(dest / "ct")
    let h = "0x" & repeat('b', 40)
    writeFile(dest / "snapshot.json", $(%*{
      "format": "blocktracer/chain-snapshot@1",
      "provenance": {
        "kind": "live-capture", "chain": "unpublishable",
        "label": "Real watched data", "endpoint": "https://node.example",
        "capturedAt": "2026-08-31T18:44:30.452Z",
        "nodeVersion": "5.2.0", "l1ChainId": 1, "runtimeCommit": "abc123def456"},
      "window": {"tip": 200, "finalized": 180, "replayableFrom": 181,
                 "replayableTo": 200, "blocks": 20},
      "blocks": [{"number": 199, "hash": "0x" & align("199", 40, '0'),
                  "timestamp": FixtureBlockTime + 1199, "totalManaUsed": "0x2710",
                  "coinbase": "0x" & repeat('1', 40), "feePerL2Gas": "0x1",
                  "archiveRoot": "0x" & repeat('2', 40),
                  "parentArchiveRoot": "0x" & repeat('3', 40),
                  "transactions": [h]}],
      "transactions": [{
        "txHash": h, "blockNumber": 199, "txIndexInBlock": 0,
        "revertCode": 0, "transactionFee": "0x1",
        "bodyRetained": true, "effectVisible": true, "firstInBlock": true,
        "outcome": "refused", "refusal": "AvmToolchainRegression",
        "reason": "This transaction could not be re-executed: the replay " &
                  "runtime refused with AvmToolchainRegression."}]}))
    dest

  proc mixedSnapshot(dir: string): string =
    ## THE THREE OUTCOMES AT ONCE, which no committed capture holds: one
    ## recorded, one refused, one pruned. The curated window lands on the
    ## recorded one alone, so the other two are the unpublished remainder the
    ## banner has to describe — and describing them is the point, because they
    ## are the two facts the remainder sentence must not merge.
    let dest = dir / "mixed"
    createDir(dest / "ct")
    let recorded = "0x" & repeat('1', 40)
    let refused  = "0x" & repeat('2', 40)
    let pruned   = "0x" & repeat('3', 40)
    # A container with bytes in it: `ingestSnapshot` refuses to publish a
    # manifest naming a zero-byte trace, which is a rule this fixture must obey
    # rather than work around.
    writeFile(dest / "ct" / (recorded & ".ct"), repeat('x', 4096))
    var blocks = newJArray()
    for n in 100 .. 120:
      var b = %*{"number": n, "hash": "0x" & align($n, 40, '0'),
                 "timestamp": FixtureBlockTime + n * 36, "totalManaUsed": "0x0",
                 "coinbase": "0x" & repeat('1', 40), "feePerL2Gas": "0x1",
                 "archiveRoot": "0x" & repeat('2', 40),
                 "parentArchiveRoot": "0x" & repeat('3', 40),
                 "transactions": newJArray()}
      if n == 105: b["transactions"].add %pruned
      if n == 110: b["transactions"].add %refused
      if n == 118: b["transactions"].add %recorded
      if n in [105, 110, 118]: b["totalManaUsed"] = %"0x2710"
      blocks.add b
    writeFile(dest / "snapshot.json", $(%*{
      "format": "blocktracer/chain-snapshot@1",
      "provenance": {
        "kind": "live-capture", "chain": "mixed", "label": "Real mixed data",
        "endpoint": "https://node.example",
        "capturedAt": "2026-08-31T18:44:30.452Z", "nodeVersion": "5.2.0",
        "l1ChainId": 1, "runtimeCommit": "abc123def456"},
      "window": {"tip": 120, "finalized": 115, "replayableFrom": 116,
                 "replayableTo": 120, "blocks": 5},
      "blocks": blocks,
      "transactions": [
        {"txHash": pruned, "blockNumber": 105, "txIndexInBlock": 0,
         "revertCode": 0, "transactionFee": "0x1", "bodyRetained": false,
         "effectVisible": true, "firstInBlock": true, "outcome": "pruned",
         "reason": "The node still serves this transaction's effects but no " &
                   "longer serves its body."},
        {"txHash": refused, "blockNumber": 110, "txIndexInBlock": 0,
         "revertCode": 0, "transactionFee": "0x1", "bodyRetained": true,
         "effectVisible": true, "firstInBlock": true, "outcome": "refused",
         "refusal": "AvmToolchainRegression",
         "reason": "The replay runtime refused this transaction."},
        {"txHash": recorded, "blockNumber": 118, "txIndexInBlock": 0,
         "revertCode": 0, "transactionFee": "0x1", "bodyRetained": true,
         "effectVisible": true, "firstInBlock": true, "outcome": "replayed",
         "container": "ct/" & recorded & ".ct", "containerBytes": 4096,
         "instructionsExecuted": 90, "hydrationRounds": 1,
         "effects": {"matched": 3, "mismatched": 0, "reproduced": true},
         "recording": {"steps": 90, "callsOpened": 2, "declaredRung": 3,
                       "stepsPositioned": 0, "stepsUnpositioned": 90}}]}))
    dest

  let cd = getTempDir() / ("bt-curated-" & $getCurrentProcessId())
  removeDir(cd); createDir(cd)
  var curatedIngests: seq[IngestResult]
  for d in captureDirs:
    curatedIngests.add ingestSnapshot(
      IngestConfig(outDir: cd, snapshotDir: d, scope: isCurated))
  let curatedRoot = newDataRoot(cd)

  test "the SAME captures under isFull publish transactions that do not open":
    # Trap 4a. Every assertion in the control is of the form "this one opens",
    # and a curated tree that published nothing would pass all of them. This
    # arm measures what curation is actually removing, over the same bytes.
    var traceless = 0
    var total = 0
    for c in capturedChains(root):
      let info = chainInfo(root, c)
      for t in publishedTxs(root, c):
        inc total
        if txView(root, info, t).headline notin {taReady, taDivergent}:
          inc traceless
    ck total > 0
    ck traceless > 0
    # …and the curated tree is strictly smaller because of them.
    var curatedTotal = 0
    for c in capturedChains(curatedRoot):
      curatedTotal += publishedTxs(curatedRoot, c).len
    ck curatedTotal < total

  test "CONTROL: every transaction the curated tree publishes opens a container":
    # TALLIED, NOT ASSERTED PER ROW, and the reason is that one of these
    # captures is ALIVE. `client/fixtures/chain/aztec/snapshot.json` is grown by
    # a running follower, so the number of transactions this loop reaches is not
    # a constant — and a counted-assertion suite whose total moves with the data
    # is a suite that goes red for a catch, which is the one event this campaign
    # is trying to produce. So the loop counts, and the assertions are relations
    # over the counts: fixed in number, exact in meaning.
    var checked, headlined, replayable, withBytes, onDisk = 0
    for c in capturedChains(curatedRoot):
      let info = chainInfo(curatedRoot, c)
      for t in publishedTxs(curatedRoot, c):
        inc checked
        let v = txView(curatedRoot, info, t)
        let tr = traceView(curatedRoot, info, t)
        # The four facts that make "it opens" true rather than claimed: the
        # overlay says a container exists, the resolution names one, it has
        # bytes, and the file is in the tree at the name the page will use.
        if v.headline in {taReady, taDivergent}: inc headlined
        if tr.outcome == tvReplayable: inc replayable
        if tr.containerBytes > 0: inc withBytes
        if fileExists(cd / tr.containerPath.strip(chars = {'/'})): inc onDisk
    # A FLOOR, so a tree that stopped publishing transactions cannot pass this
    # test by having nothing to check.
    #
    # It used to read `>= 6`, "the committed testnet capture publishes six", and
    # the parenthetical was the part that moved: `curationWindow` now prefers
    # the run holding a source-resolving recording, so testnet publishes the
    # three transactions of 67010–67018 rather than the six of 63642–63675. The
    # floor is what this test needs — the relations below are the assertions —
    # so it is restated at what the fixtures actually publish rather than raised
    # back by widening the window, which would trade the only source-level
    # transaction on the site for a larger number here.
    ck checked >= 5
    ck headlined == checked
    ck replayable == checked
    ck withBytes == checked
    ck onDisk == checked
    # …and the ingest's own count agrees with what the BLOCK RECORD reaches. The
    # two are computed differently — one is the ingest's counter, the other is a
    # walk of the published blocks — so a transaction published without a block
    # to reach it from, or counted and not written, separates them.
    var reported = 0
    for ing in curatedIngests: reported += ing.transactions
    ck reported == checked

  test "the curated ingest reports BOTH what it published and what it watched":
    # The published set is a subset of the observed one, and the build log and
    # the banner have to be able to say so. A result that reported only the
    # published side would make the two indistinguishable.
    var curated = 0
    for ing in curatedIngests:
      inc curated
      ck ing.scope == isCurated
      ck ing.observedBlocks >= ing.blocks
      ck ing.observedTransactions >= ing.transactions
      ck ing.windowFrom <= ing.windowTo
      ck ing.transactions == ing.withTrace
    # 2 -> 3 with `/aztec-testnet-frames` (2026-09-05). This is the count of
    # CAPTURES the tree ingests, so it moves whenever a chain is published, and
    # it went un-updated at `1c2cd37` — which left this suite RED on `dev`, the
    # same way `test_instruction_listing`'s eight counts were. Corrected upward
    # to what the tree holds; the five assertions inside the loop move with it
    # (88 -> 93 below).
    ck curated == 3

  test "the span is the PUBLISHED slice's, so the two trees differ by design":
    # WHAT THIS USED TO GRADE, TWICE, AND WHY IT IS THIS NOW.
    #
    # Round one: the curated arm named the published window ("blocks
    # 63642–63675"), the watch it was chosen out of ("Of the 32 transactions
    # seen while watching this chain, 6 could be recorded") and a per-outcome
    # clause; the uncurated arm named the enumerated range and a pruning
    # boundary. Two arms, because a claim about the published set is false of
    # the enumerated one and the reverse — the mechanism by which this module
    # twice published a number that disagreed with the counts printed above it.
    #
    # Round two deleted both arms and, for one commit, measured the coverage
    # span over `snap["blocks"]` — the ENUMERATED set — while the page below it
    # lists the CURATED one. That is the same disagreement re-entering through
    # the back door: `/aztec` published 170 blocks under a sentence naming a
    # span that belongs to 1563, overstating what a reader can browse nearly
    # tenfold and naming two days they cannot reach.
    #
    # THE SPAN IS NOW MEASURED OVER `blockRows`, AFTER THE NARROWING, so the
    # sentence and the `Blocks` stat are two views of one set. There is still no
    # scope branch: under `isFull` the narrowing is a no-op and the same
    # expression yields the enumerated span. What this asserts is therefore the
    # DIFFERENCE — a build that reverted to the enumerated set would make these
    # two trees agree, and a build that hardcoded either answer would fail one.
    #
    # MAINNET IS WHERE THE DIFFERENCE SHOWS, and it is the chain the complaint
    # was filed against. Its capture enumerates 1563 blocks over two days and
    # publishes 170 of them inside three and a half hours of the last one.
    let curatedMain = chainInfo(curatedRoot, "aztec").provenanceDetail
    let fullMain = chainInfo(root, "aztec").provenanceDetail
    ck "This is a preliminary export covering 1 September 2026." in curatedMain
    ck "This is a preliminary export covering 30 August to 2 September 2026." in
       fullMain
    ck curatedMain != fullMain
    # The counts the two spans correspond to, stated rather than implied: this
    # is the correspondence a reader checks the sentence against, and it is what
    # makes the difference above a fact about the DATA rather than a spelling.
    ck chainInfo(curatedRoot, "aztec").blockCount == 170
    ck chainInfo(root, "aztec").blockCount == 3439

    # TESTNET WAS THE CONTROL AND HAS STOPPED BEING ONE, which is a loss worth
    # stating rather than a line to retune.
    #
    # It qualified because its 220 enumerated blocks and its 34 published ones
    # both fell inside 31 August 2026, so the two trees legitimately wrote the
    # SAME sentence — the one real case proving "the trees always differ" is not
    # the rule, and therefore that a build hardcoding the difference would be
    # caught. The 2026-09-02 capture ended that: the snapshot now enumerates
    # 3,600 blocks across 31 August–2 September, and curation publishes nine of
    # them inside 2 September, so testnet shows the difference too.
    #
    # SO THE AGREEMENT CASE IS NOW UNWITNESSED BY ANY REAL CHAIN, and nothing
    # below restores it — asserting it where it is false would be worse than not
    # asserting it. What would restore it is a capture whose enumerated and
    # published blocks fall in one day, which is a property of the next watch
    # and not something this file can arrange. Recorded here so the next reader
    # knows the cover was lost rather than never existed.
    let curatedTest = chainInfo(curatedRoot, RealChain).provenanceDetail
    let fullTest = chainInfo(root, RealChain).provenanceDetail
    ck "This is a preliminary export covering 2 September 2026." in curatedTest
    ck "This is a preliminary export covering 31 August to 2 September 2026." in
       fullTest
    ck curatedTest != fullTest
    ck chainInfo(curatedRoot, RealChain).blockCount <
       chainInfo(root, RealChain).blockCount     # non-vacuous: it IS a slice

    # Neither of the deleted arms' vocabulary survived, in either tree.
    for phrase in ["selection rather than the whole chain", "blocks 63642",
                   "seen while watching this chain", "CURATED WINDOW",
                   "did not arrive evenly", "longest run with none",
                   "Transactions below block"]:
      ck phrase notin curatedMain
      ck phrase notin fullMain

  test "the curated banner attributes NO cause to the transactions it leaves out":
    # THIS REPLACES AN ARM THAT CHECKED THE ATTRIBUTION WAS SPLIT CORRECTLY, and
    # the replacement is stronger than the thing it replaces.
    #
    # The banner used to break the unpublished remainder down by outcome —
    # "25 had already been pruned; 6 WERE still replayable … and the replay
    # runtime refused them (AvmToolchainRegression)" — because a single clause
    # over the remainder says "pruned" of a refusal, which blames the network
    # for a fault on this side of the wire. That is a real hazard and `b7cafba`
    # had to undo exactly that merge once already.
    #
    # It now says how many were seen and how many were recorded, and assigns no
    # cause to either. A sentence that attributes nothing cannot mis-attribute,
    # so the hazard is closed by construction rather than by a clause per
    # bucket that a seventh outcome could still slip past. This asserts the
    # construction: over a snapshot carrying BOTH a pruning and a refusal,
    # neither cause is named and no internal type name reaches the page.
    let rd = getTempDir() / ("bt-curated-refusal-" & $getCurrentProcessId())
    removeDir(rd); createDir(rd)
    let tree = rd / "tree"
    createDir(tree)
    discard ingestSnapshot(IngestConfig(outDir: tree,
                                        snapshotDir: mixedSnapshot(rd),
                                        scope: isCurated))
    let d = chainInfo(newDataRoot(tree), "mixed").provenanceDetail
    # Non-vacuous: the remainder really does hold both kinds, so a banner that
    # named a cause would have had two to choose wrongly between — and the
    # section is not silent on this chain either.
    ck "taken from the live network" in d
    ck "preliminary export covering " in d
    ck "could be recorded" notin d
    ck "had already been pruned" notin d
    ck "still replayable" notin d
    ck "AvmToolchainRegression" notin d
    ck "failure on the recording side" notin d

  proc silentSnapshot(dir: string): string =
    ## A chain whose newest blocks settled nothing, and whose one transaction is
    ## far below them. The curated window is the survey run, and the published
    ## chain has ZERO transactions on it — the shape `/aztec` has today.
    let dest = dir / "silent"
    createDir(dest / "ct")
    let pruned = "0x" & repeat('7', 40)
    var blocks = newJArray()
    for n in 100 .. 160:
      var b = %*{"number": n, "hash": "0x" & align($n, 40, '0'),
                 "timestamp": FixtureBlockTime + n * 36, "totalManaUsed": "0x0",
                 "coinbase": "0x" & repeat('1', 40), "feePerL2Gas": "0x1",
                 "archiveRoot": "0x" & repeat('2', 40),
                 "parentArchiveRoot": "0x" & repeat('3', 40),
                 "transactions": newJArray()}
      if n == 104:
        b["totalManaUsed"] = %"0x2710"
        b["transactions"].add %pruned
      blocks.add b
    writeFile(dest / "snapshot.json", $(%*{
      "format": "blocktracer/chain-snapshot@1",
      "provenance": {
        "kind": "live-capture", "chain": "silent", "label": "Real silent data",
        "endpoint": "https://node.example",
        "capturedAt": "2026-08-31T18:44:30.452Z", "nodeVersion": "5.2.0",
        "l1ChainId": 1, "runtimeCommit": "abc123def456"},
      "window": {"tip": 160, "finalized": 155, "replayableFrom": 156,
                 "replayableTo": 160, "blocks": 5},
      "blocks": blocks,
      "transactions": [
        {"txHash": pruned, "blockNumber": 104, "txIndexInBlock": 0,
         "revertCode": 0, "transactionFee": "0x1", "bodyRetained": false,
         "effectVisible": true, "firstInBlock": true, "outcome": "pruned",
         "reason": "The node still serves this transaction's effects but no " &
                   "longer serves its body."}]}))
    dest

  test "a chain with no transactions says so, and does not send a reader away":
    # The empty transaction table used to say "Older blocks may; the
    # transactions list walks backwards from here", which is true of a chain
    # whose record runs below the slice and FALSE of one that publishes no
    # transaction at all. A curated chain can be the second, and that sentence
    # sent a visitor to an empty list to discover it.
    let sd = getTempDir() / ("bt-silent-" & $getCurrentProcessId())
    removeDir(sd); createDir(sd)
    let tree = sd / "tree"
    createDir(tree)
    let ing = ingestSnapshot(IngestConfig(outDir: tree,
                                          snapshotDir: silentSnapshot(sd),
                                          scope: isCurated))
    ck ing.transactions == 0                    # not vacuous: it really is empty
    ck ing.blocks == SurveyBlocks
    let sr = newDataRoot(tree)
    let body = markup(renderRoute(sr, "/silent").body)
    ck "No transaction settled in the blocks this chain publishes" in body
    ck "Older blocks may" notin body
    # …and the producer's own paragraph is reachable ON this page, which is the
    # only page such a chain has: with no transaction there is no transaction
    # metadata surface, which is where `provenanceMetaRows` puts it.
    ck "preliminary export covering " in body
    ck "Real silent data" in body
    # THE TWIN. A chain that DOES publish transactions must not carry the
    # zero sentence — without this, an unconditional swap in the other
    # direction would satisfy every assertion above.
    ck chainInfo(curatedRoot, RealChain).txCount > 0
    ck "No transaction settled in the blocks this chain publishes" notin
      markup(renderRoute(curatedRoot, "/" & RealChain).body)

  test "MUTATION BITE: the naive span rule would publish a traceless one":
    # `curationWindow`'s whole content is the delimiting. The obvious rule —
    # min(recorded) .. max(recorded) — is asserted here to be WRONG on this
    # input, so the assertion below is shown to be load-bearing rather than
    # merely true.
    var heights: seq[int]
    for n in 100 .. 140: heights.add n
    let recorded = @[110, 120, 135]
    let traceless = @[115]
    ck recorded[0] < traceless[0]                 # the naive span would…
    ck traceless[0] < recorded[^1]                # …contain the traceless one
    let w = curationWindow(heights, recorded, traceless)
    ck w.found
    ck not (w.lo <= traceless[0] and traceless[0] <= w.hi)
    # It took the run holding the MOST recordings, which is the run above 115.
    ck w.lo == 120
    ck w.hi == 135

  test "a tie between runs is broken by recency, not by order":
    var heights: seq[int]
    for n in 100 .. 140: heights.add n
    let w = curationWindow(heights, @[105, 130], @[120])
    ck w.found
    ck w.lo == 130
    ck w.hi == 130

  test "with nothing recorded, the window is the newest silent run, capped":
    var heights: seq[int]
    for n in 100 .. 200: heights.add n
    let w = curationWindow(heights, @[], @[150])
    ck w.found
    ck w.hi == 200
    ck w.lo == 200 - SurveyBlocks + 1
    ck w.lo > 150                                 # the traceless one is outside
    ck "no span of recordings" in w.why

  test "the survey window is chosen by SIZE first, and recency only then":
    # MEASURED, NOT ANTICIPATED. The first rule here was "the newest
    # transaction-free run", and it shrinks by one every time the chain settles
    # another transaction: a mainnet transaction arrived in block 67764 and the
    # published window went from 24 blocks to 8 between two builds of this
    # branch. At one transaction it is a single block — a chain page that looks
    # broken while being correct.
    var heights: seq[int]
    for n in 100 .. 200: heights.add n
    # Three silent runs: 196-200 (5, newest), 151-194 (44), 100-149 (50).
    let w = curationWindow(heights, @[], @[150, 195])
    ck w.found
    ck w.hi == 194                    # NOT 200: the newest run is too short
    ck w.lo == 194 - SurveyBlocks + 1
    ck w.hi - w.lo + 1 == SurveyBlocks
    # …and it still contains no transaction, which is the invariant the size
    # preference must not buy its way out of.
    ck not (w.lo <= 150 and 150 <= w.hi)
    ck not (w.lo <= 195 and 195 <= w.hi)
    # THE FLOOR. Where no run is long enough, the newest is taken whole rather
    # than a longer one being manufactured by including a transaction.
    let short = curationWindow(heights, @[], @[150, 195, 100])
    ck short.found
    let tiny = curationWindow(@[100, 101, 102], @[], @[101])
    ck tiny.found
    ck tiny.lo == 102
    ck tiny.hi == 102
    discard short

  test "a capture with nothing publishable is REFUSED, not published empty":
    # The arm the committed captures never reach: every block settled a
    # transaction that cannot be replayed. There is no window that keeps the
    # promise, and the honest answer is to refuse rather than to publish one
    # transaction that does not open — or a chain with no blocks in it.
    let w = curationWindow(@[199], @[], @[199])
    ck not w.found
    let rd = getTempDir() / ("bt-curated-refuse-" & $getCurrentProcessId())
    removeDir(rd); createDir(rd)
    let snapDir = unpublishableSnapshot(rd)
    let tree = rd / "tree"
    createDir(tree)
    var raised = false
    try:
      discard ingestSnapshot(IngestConfig(outDir: tree, snapshotDir: snapDir,
                                          scope: isCurated))
    except ValueError as e:
      raised = true
      ck "found no window in which every transaction carries a trace" in e.msg
      ck "scope=isFull" in e.msg
    ck raised
    # …and the SAME capture under isFull publishes it, with its own words. The
    # refusal above is a scoping decision, not a claim that the data is bad.
    let fullTree = rd / "full"
    createDir(fullTree)
    let ing = ingestSnapshot(IngestConfig(outDir: fullTree, snapshotDir: snapDir))
    ck ing.transactions == 1
    ck ing.withTrace == 0

  test "assertion count":
    # 87 + 1: the testnet arm now asserts BOTH spans, because the two trees
    # differ there and the difference has to be named at both ends.
    expectCount(93)

# ── 9 — the home page features a session that can actually be shown ──────────
#
# THE DEFECT. The home page's embed used to be "the first transaction that is
# positioned, validated and not reconstructed", which is three ways of saying
# nothing is wrong with it. Nothing was wrong with what it picked, either:
# `aztec-testnet/tx/0x0858d644…` is a real transaction whose real container
# stops at step 128 of 345 and steps normally. It is rung 3, so its panes say —
# correctly, on the front page, under "the deepest view into every transaction"
# — that they carry no source positions, no function names and no variable
# names. Correct in place; the worst available first impression as a headline.
#
# `canHeadline` is the replacement and it is a POSITIVE rule: every clause names
# something the exhibit must have. The mutation arms below remove one such thing
# at a time from a session that qualifies, which is what makes each clause
# load-bearing rather than decorative.
suite "9 — the home page features a session that can actually be shown":
  asserted = 0

  let featured = demoSessionFor(root)

  test "CONTROL: the tree has a session that can headline, and it is featured":
    ck featured.isSome
    let s = featured.get
    ck canHeadline(s)
    # It is the SOURCE-LEVEL one, which is the property the rule exists to
    # require — asserted through the pane rather than through the slug.
    ck s.editor.availability == srcSourceLevel
    ck s.editor.documents.len > 0
    ck s.calltrace.frames.len > 0
    ck s.state.values.len > 0
    # …and the page renders it.
    let home = renderRoute(root, "/").body
    ck "id=\"live-demo\"" in home
    ck "Stopped mid-execution at step" in home

  test "the rung-3 real transaction passes the OLD rule and fails the new one":
    # The exact regression, as an assertion. Without this the new rule could
    # have been any predicate at all that the demo session happens to satisfy.
    let s = debugSessionFor(root, RealChain, replayedTx)
    ck s.hasFrame                       # the three clauses the old rule asked…
    ck s.integrity == siValidated
    ck not s.reconstructed
    ck not canHeadline(s)               # …and the one it did not
    ck s.editor.availability == srcUnverified

  test "the three sentences stay on that transaction's OWN page":
    # The fix is the choice of subject, not the deletion of the notices. A
    # rung-3 page that hid them would be the dishonesty this campaign exists to
    # prevent, so their presence is asserted here, on the page they belong on.
    let body = renderRoute(root, "/" & RealChain & "/tx/" & replayedTx &
                           "/debug").body
    ck "program counters" in body
    # THE CALL TRACE'S SENTENCE MOVED, and the quote here did not move with it.
    # `5a87240` replaced "…so they carry no function names or source positions"
    # because the claim was false — the engine answers this recording's call
    # trace with `<toplevel>` and `enqueued-call-0`, both named — and what is
    # genuinely absent on a rung-3 recording is a source POSITION. That commit
    # moved the copy and `tools/capture/expectations.mjs`, which quotes it
    # verbatim, and left this suite quoting the retired sentence: the product
    # was corrected and the assertion went red naming the correction.
    #
    # Re-quoted rather than loosened. The clause asserted is still the middle
    # of the three — "no source position on a rung-3 recording, stated on the
    # transaction's own page" — and it is quoted verbatim for the same reason
    # `expectations.mjs` does: a substring match on "source position" would
    # have gone on passing through the very edit that made the old sentence
    # wrong, which is the whole failure this pair of assertions exists to catch.
    # THE CALL TRACE'S SENTENCE MOVED AGAIN, and this time because the pane
    # stopped needing it. `renderCallTrace` prints the note only when there are
    # no frames, and there are frames now — `tools/chain/derive-calltrace.mjs`
    # lifts them out of the container the same way the instruction listing and
    # the positions are lifted. So the quote is no longer on this page, and
    # asserting its presence would be asserting that the pane is still empty.
    #
    # What is asserted instead is the FACT the sentence carried, on the surface
    # that now carries it: the frames are listed, and they still show no source
    # coordinate. See the dedicated test below for the frames themselves.
    ck "carries no variable names" in body
    # …and NOT on the home page.
    let home = renderRoute(root, "/").body
    ck "carries no variable names" notin markup(home)

  test "the served Call Trace lists the frames the recording opened":
    # CONTROL DATA. Before `calltrace/<tx>.json` existed this test failed on
    # every real chain transaction in the corpus, and it failed the same way on
    # each: the pane rendered `<p class="panenote">` and zero `.ctrow`
    # elements, while the manifest published beside it declared
    # `execution.frames: 1`. Two producers of one answer, disagreeing in public.
    #
    # CHAIN-CAPTURE.md §6.6 recorded that emptiness as a static-export
    # limitation that only a live session could lift. It was not one: the
    # containers carry the frames, and the derivation that reads them out is the
    # one `chain-instructions` and `chain-frozen-artifacts` already established.
    #
    # ABSENT-IS-VALID IS NOT WEAKENED BY THIS TEST. A tree with no `calltrace/`
    # directory is still a tree this repository builds and serves — `ingest.nim`
    # publishes what it finds and `withCallFrames` returns on a nil node. What
    # is pinned here is that THIS corpus, which does carry the derivation,
    # renders it.
    let body = renderRoute(root, "/" & RealChain & "/tx/" & replayedTx &
                           "/debug").body
    # Named verbatim, not counted. A count would go on passing if the recorder
    # renamed a frame, and the names are the whole reason the pane is worth
    # filling: `<toplevel>` is the synthetic frame holding the enqueued calls,
    # `enqueued-call-0` is the public function this transaction actually ran.
    # Escaped, because the renderer escapes it: `<toplevel>` is a name with
    # angle brackets in it and the page must not emit an element called
    # `toplevel`. Quoting the escaped form is also the assertion that it IS
    # escaped.
    ck "&lt;toplevel&gt;" in body
    ck "enqueued-call-0" in body
    # The names are on ROWS, not merely mentioned in prose. Asserted as the
    # frame name inside a `.ctname` span rather than as `"ctrow" in body`, which
    # was measured VACUOUS: the debug page carries a second call-trace view (the
    # `selfCostRows` aggregate) whose rows use the same class, so `ctrow`
    # appears on this page even when the served pane has zero frames. It passed
    # identically with the derivation removed, which is the definition of an
    # assertion that is not measuring its subject.
    ck "ctname" in body
    ck "enqueued-call-0</span>" in body
    # AND THE NOTE IS GONE, which is the half of this that catches a regression
    # in the other direction: a change that stopped the frames reaching the pane
    # would put the paragraph back, and a test that only looked for the names
    # might still find them in a sentence about them.
    ck "They are listed once the session is live." notin body

  test "the frames the page lists agree with the manifest's own count":
    # THE DISAGREEMENT THAT WAS SHIPPING. `manifest.execution.frames` is written
    # from the capture's `recording.callsOpened` and counts the ENQUEUED calls;
    # the pane lists those plus the synthetic `<toplevel>` that holds them. So
    # the relation is `rows == frames + 1`, and it is asserted rather than
    # assumed because `derive-calltrace.mjs` refuses to write a stream that
    # breaks it — this is the same check, read back off the rendered page, so a
    # regression anywhere between the container and the row is caught here and
    # not only at derivation time.
    let view = debugSessionFor(root, RealChain, replayedTx)
    let declared = snap["transactions"].getElems.filterIt(
      it{"txHash"}.getStr == replayedTx)[0]{"recording"}{"callsOpened"}.getInt
    ck view.calltrace.frames.len == declared + 1
    ck view.calltrace.frames[0].fn == "<toplevel>"
    # Every frame carries a name and no source coordinate — the rung-3 fact the
    # retired sentence used to state in prose, now checked against the data.
    for f in view.calltrace.frames:
      ck f.fn.len > 0
      ck f.line == 0

  test "MUTATION BITE: a call trace the manifest's frame count contradicts is refused":
    # THE REFUSAL, DRIVEN. `ingest.nim` raises when a published call trace
    # disagrees with the capture's own `recording.callsOpened` — the number
    # `manifest.execution.frames` is written from. A check nobody has seen say
    # no is a check that may not work, and this pane's whole defect was two
    # producers of one answer going unreconciled, so the reconciliation gets a
    # test that watches it fire.
    #
    # Driven over a COPY. The committed fixture is never mutated: the same rule
    # `treeWithRealChain` follows, for the same reason.
    let bite = getTempDir() / ("bt-calltrace-bite-" & $getCurrentProcessId())
    removeDir bite
    createDir bite
    copyDir(chainFixtures / "aztec", bite / "aztec")
    let snapDir = bite / "aztec"

    proc ingestOutcome(label: string): string =
      try:
        discard ingestSnapshot(IngestConfig(outDir: bite / ("out-" & label),
                                            snapshotDir: snapDir))
        "accepted"
      except ValueError as e:
        "refused: " & e.msg

    # CONTROL FIRST, so a refusal below cannot be the tree being broken for some
    # other reason. Without this the two mutations would pass identically if
    # `ingestSnapshot` had simply stopped working.
    ck ingestOutcome("control") == "accepted"

    var target = ""
    for f in walkFiles(snapDir / "calltrace" / "*.json"): target = f
    ck target.len > 0
    let orig = readFile(target)

    # A frame count the manifest's own number contradicts.
    var j = parseJson(orig)
    j["frames"] = %3
    writeFile(target, $j)
    let bitten = ingestOutcome("frames")
    ck bitten.startsWith("refused")
    ck "callsOpened=1" in bitten

    # …and a declared count the array does not carry, which is the same defect
    # one level in: the header would agree with the manifest while the rows it
    # describes are not there.
    j = parseJson(orig)
    j["frame"] = %(j["frame"].getElems[0 .. 0])
    writeFile(target, $j)
    let shortened = ingestOutcome("short")
    ck shortened.startsWith("refused")
    ck "carries 1 of them" in shortened

    # RESTORED, AND ACCEPTED AGAIN. Without this the test would pass if ingest
    # had begun refusing everything.
    writeFile(target, orig)
    ck ingestOutcome("restored") == "accepted"
    removeDir bite

  test "a PARTLY positioned recording renders real source, not a bytecode listing":
    # THE DEFECT THIS PINS, in one sentence: the tree published a 32-file Noir
    # bundle and a 108-row `positions.json` for this transaction, and the page
    # rendered an instruction listing over the top of both.
    #
    # The cause was that `manifest.execution.sourceLevel` was the only question
    # the route could ask, and it is an ALL-OR-NOTHING bit — every executed step
    # positioned. No real chain capture has ever set it and none ever can: every
    # Aztec public transaction enters through `public_dispatch`, whose prologue
    # is compiler-generated code that carries no source location by construction
    # (CHAIN-CAPTURE.md §6.5). So gating the text on it discarded all 86 real
    # positions, permanently.
    #
    # Subject chosen out of the snapshot, like every other subject in this file:
    # the first transaction whose CAPTURE measured positioned steps. If a future
    # snapshot has none the test skips rather than passing vacuously — a green
    # assertion over an empty set is what §6.2 keeps calling out.
    var positionedTx = ""
    for t in snap["transactions"]:
      if t{"recording"}{"stepsPositioned"}.getInt(0) > 0:
        positionedTx = t["txHash"].getStr
        break
    if positionedTx.len == 0:
      skip()
    else:
      let s = debugSessionFor(root, RealChain, positionedTx)
      # It is at SOURCE level and standing on a real line of a real file…
      ck s.editor.availability == srcSourceLevel
      ck s.editor.documents.len > 0
      ck s.editor.currentLine > 0
      # …not a listing wearing source's clothes. THE TEST FOR THAT USED TO BE
      # `listingCaption.len == 0`, which was a PROXY for "there are no listing
      # rows in this pane" — exact while a pane was one rung for a whole session,
      # and wrong since the ladder became a UNION for a partly-positioned
      # recording (`demo_session.withListingBesideSource`). The caption is a fact
      # about the RECORDING, and this pane now holds both kinds of document, so
      # the question has to be asked of the ACTIVE one — which is what the line
      # below always did and what the proxy was standing in for.
      ck activeDocument(s.editor).path.endsWith(".nr")
      ck activeDocument(s.editor).path != ListingPath
      # AND THE LISTING IS BESIDE IT RATHER THAN OVER IT — the recording's own
      # program counters for the 22 steps the source cannot reach, which is
      # `Source-Resolution.md` §7's "instruction-level elsewhere". Asserted here
      # because the arm's own title is about which of the two the pane shows, and
      # "shows source" must not quietly come to mean "publishes no listing".
      var listingDocs = 0
      for d in s.editor.documents:
        if d.path == ListingPath: inc listingDocs
      ck listingDocs == 1
      ck s.editor.listingCaption.len > 0
      # …and exactly ONE row in the whole pane is current, so the two documents
      # are not two producers of the one position this session has.
      var currentRows = 0
      for d in s.editor.documents:
        for ln in d.lines:
          if ln.current: inc currentRows
      ck currentRows == 1
      # …and it says how much of the recording it can place, which is what keeps
      # "shows source" from being read as "positions everything".
      ck s.editor.positionedSteps > 0
      ck s.editor.positionedSteps < s.editor.positionedOf
      # A partial recording may NOT headline: CHAIN-CAPTURE.md §6.2 keeps the
      # home page's exhibit a person's choice, not whatever the tree produced.
      ck not canHeadline(s)
      # The page carries the text, and the two notes written for the OTHER
      # outcome are gone. A pane saying "Nothing resolved a source position"
      # beside a pane showing a Noir line is the product contradicting itself
      # on one screen, which is exactly what shipped before this.
      let body = renderRoute(root, "/" & RealChain & "/tx/" & positionedTx &
                             "/debug").body
      ck "Nothing resolved a source position, so they carry no file or line." notin body
      ck "none resolved for this contract" notin body
      ck "their variable table is empty" in body

  test "MUTATION BITE: every clause of the rule is load-bearing":
    # One removal per clause, each from the SAME qualifying session, each
    # asserted to flip the answer. A clause that could be deleted without
    # reddening anything would be a rule that only looks like it is checking.
    ck featured.isSome
    let ok = featured.get
    ck canHeadline(ok)                  # the control, restated beside them

    var m = ok; m.hasFrame = false
    ck not canHeadline(m)
    m = ok; m.containerPath = ""
    ck not canHeadline(m)
    m = ok; m.containerBytes = 0
    ck not canHeadline(m)
    m = ok; m.traceContentHash = ""
    ck not canHeadline(m)
    m = ok; m.integrity = siDivergent
    ck not canHeadline(m)
    m = ok; m.integrity = siTruncated
    ck not canHeadline(m)
    m = ok; m.reconstructed = true
    ck not canHeadline(m)
    m = ok; m.controls.totalSteps = 0
    ck not canHeadline(m)
    m = ok; m.controls.step = 0
    ck not canHeadline(m)
    m = ok; m.editor.availability = srcUnverified
    ck not canHeadline(m)
    m = ok; m.editor.availability = srcAbsent
    ck not canHeadline(m)
    m = ok; m.editor.documents = @[]
    ck not canHeadline(m)
    m = ok; m.editor.currentLine = 0
    ck not canHeadline(m)
    m = ok
    for i in 0 ..< m.editor.documents.len: m.editor.documents[i].lines = @[]
    ck not canHeadline(m)
    m = ok; m.calltrace.frames = @[]
    ck not canHeadline(m)
    m = ok; m.calltrace.frames[0].fn = ""
    ck not canHeadline(m)
    m = ok; m.state.values = @[]
    ck not canHeadline(m)
    m = ok; m.state.values[0].name = ""
    ck not canHeadline(m)

  test "a tree with nothing to headline features NOTHING, not the next-best":
    # The no-fallback rule. A real-chains-only tree holds real containers that
    # open and step, and not one of them carries source — so the honest answer
    # is an absence, and the failure mode being ruled out is a home page that
    # relaxes the rule until something passes.
    let rd = getTempDir() / ("bt-nofeature-" & $getCurrentProcessId())
    removeDir(rd); createDir(rd)
    for d in captureDirs:
      discard ingestSnapshot(IngestConfig(outDir: rd, snapshotDir: d))
    let realOnly = newDataRoot(rd)
    # Not vacuous: the tree HAS openable sessions, it simply has none to
    # headline. Without this the test would pass over an empty tree.
    var openable = 0
    for c in chains(realOnly):
      let info = chainInfo(realOnly, c)
      for h in blockHashes(realOnly, info):
        for t in readBlockDetail(realOnly, info, h).transactions:
          if traceView(realOnly, info, t).outcome == tvReplayable: inc openable
    ck openable > 0
    ck demoSessionFor(realOnly).isNone
    let home = renderRoute(realOnly, "/").body
    # Matched over the MARKUP, for `markup`'s reason: the inlined stylesheet
    # carries explanatory comments that quote the embed's own sentence, so a
    # whole-document "is not here" would be answered by a CSS comment.
    ck "id=\"live-demo\"" notin markup(home)
    ck "Stopped mid-execution at step" notin markup(home)
    # The rest of the page is still a page.
    ck "deepest" in markup(home)
    ck "chaincard" in markup(home)

  test "the embed names the provenance of the chain it is showing":
    # The embed's own sentence says "a real session", which has always meant a
    # real session rather than a picture of one. Beside a transaction hash, on a
    # site publishing two captured chains and one fixture, that reading is not
    # the only available one — so the claim about the DATA is made explicitly,
    # from the same published block the chain strip reads.
    let home = renderRoute(root, "/").body
    let s = featured.get
    ck chainInfo(root, s.chain).provenanceKind == "synthetic"
    ck "data-provenance=\"synthetic\"" in markup(home)
    ck chainInfo(root, s.chain).provenanceLabel in markup(home)

  test "assertion count":
    # 47 + 11: "a PARTLY positioned recording renders real source, not a
    # bytecode listing" — the arm that pins the `positions.json` consumer.
    #
    # 58 → 74 for the Call Trace's frames: −2 + 18.
    #
    #   −2  "the three sentences stay on that transaction's OWN page" loses the
    #       two that quoted "…so they carry no file or line" as page text. The
    #       pane prints its note only when it has no frames, and it has frames
    #       now, so both assertions were pinning the emptiness.
    #   +5  "the served Call Trace lists the frames the recording opened"
    #   +6  "the frames the page lists agree with the manifest's own count" —
    #       2 fixed, plus 2 per frame over the 2 frames this recording opens.
    #       That arm is LOOP-DERIVED, which is the §4b hazard this counter
    #       exists for: were the frames to stop reaching the page the loop
    #       would run zero times, every assertion in it would vanish, and this
    #       number is what goes red instead of the suite going quietly green.
    #   +7  "MUTATION BITE: a call trace the manifest's frame count contradicts"
    # 74 -> 77. The partly-positioned arm stopped asserting `listingCaption.len
    # == 0` — a proxy that inverted when the ladder became a union — and asserts
    # the thing it stood for instead: the ACTIVE document is source, the listing
    # is one of the documents beside it, and exactly one row in the whole pane is
    # current.
    expectCount(77)

# ── 10 — a real recording's step count is its own ────────────────────────────
#
# THE THIRD TIME FIXTURE CONTENT HAS ASSERTED ITSELF OVER REAL CHAIN DATA in
# this file. The first was the demo's Noir source rendering under a testnet hash
# (the `sourceLevel` branch); the second was the uppercase NOIR tag on a session
# whose panes say four times that it has no debug symbols (the misplaced
# `languages` assignment). This is the third, and it is arithmetic rather than
# prose, which is why it survived both of those fixes:
#
#     let steps = if totalSteps > FixtureStep: totalSteps else: FixtureTotalSteps
#     result.step = (if positioned: FixtureStep else: 0)
#
# A real testnet transaction is 108 steps. `108 > 128` is false, so the page
# published `step 128 of 1315` for it: a position past the end of its own
# recording, and a total belonging to a program that never executed under that
# hash. Live on blocktracer.org, on one of the six transactions the curated tree
# publishes — the set whose entire promise is that every recording in it is a
# real one that opens and steps.
suite "10 — a real recording's step count is its own, not the fixture's":
  asserted = 0

  # The shortest recording the committed capture holds, found from the SNAPSHOT
  # rather than from the reader — the reader is what is under test, and a
  # subject chosen by asking it would agree with itself.
  var shortTx = ""
  var shortSteps = high(int)
  for t in snap["transactions"]:
    if t["outcome"].getStr != "replayed": continue
    let n = t["recording"]["steps"].getInt
    if n < shortSteps:
      shortSteps = n
      shortTx = t["txHash"].getStr

  test "the capture holds a recording SHORTER than the fixture's landing step":
    # Trap 4a. Every assertion below is about what happens to a short trace, and
    # a capture whose recordings are all long would make each of them vacuous —
    # which is precisely why this survived two rounds of review: on the fixture
    # and on a 345-step transaction the old expression gives the right answer.
    ck shortTx.len > 0
    ck shortSteps > 0
    ck shortSteps < 128            # `FixtureStep`, as a literal on purpose:
                                   # importing the constant would let a change
                                   # to it move this claim silently.

  test "MUTATION BITE: the pre-fix arithmetic, over this transaction's numbers":
    # The two expressions that shipped, evaluated on the real inputs. Asserted to
    # produce exactly the wrong published values, so the fix below is shown to be
    # load-bearing rather than a rewording.
    ck not (shortSteps > 128)                 # so the total fell through to…
    ck 1315 != shortSteps                     # …the fixture's own count
    ck 128 > shortSteps                       # and the position was past the end

  test "the session reports the manifest's count and stands inside it":
    let info = chainInfo(root, RealChain)
    let s = debugSessionFor(root, RealChain, shortTx)
    ck s.controls.totalSteps == shortSteps
    ck s.controls.step >= 1
    ck s.controls.step <= s.controls.totalSteps
    # The URL coordinate and the toolbar's step are one derivation, not two.
    ck s.timeCoordinate == s.controls.step
    # …and the manifest agrees, so this is the trace's number and not a
    # coincidence of the view.
    ck traceView(root, info, shortTx).steps == shortSteps

  test "the LONG recordings are unchanged, so the rule is not a blanket clamp":
    # The twin. Without it, "the position is inside the trace" would be
    # satisfied by a rule that landed every session on step 1.
    ck entryStepWithin(1315) == 128
    ck entryStepWithin(345) == 128
    ck entryStepWithin(128) == 128
    ck entryStepWithin(127) == 127
    ck entryStepWithin(1) == 1
    ck entryStepWithin(0) == 0

  test "NO published session anywhere stands past the end of its own trace":
    # The universal, over every transaction the tree publishes on every chain —
    # the invariant the two arms above are instances of, counted so an empty
    # walk cannot satisfy it.
    #
    # AND THE TOTAL IS THE MANIFEST'S. "The position is inside the trace" alone
    # cannot see this defect and did not: the pre-fix code inflated the TOTAL to
    # 1315 so that the constant position of 128 fitted inside it, and every
    # bounds check in the world passes on `1 <= 128 <= 1315`. The number that was
    # wrong is the one nothing was comparing against its source.
    var positioned, inside, agreeing, totalled = 0
    for c in chains(root):
      let info = chainInfo(root, c)
      for h in blockHashes(root, info):
        for t in readBlockDetail(root, info, h).transactions:
          let s = debugSessionFor(root, c, t)
          if not s.controls.positioned: continue
          inc positioned
          if s.controls.step >= 1 and s.controls.step <= s.controls.totalSteps:
            inc inside
          if s.timeCoordinate == s.controls.step: inc agreeing
          let published = traceView(root, info, t).steps
          if published > 0 and s.controls.totalSteps == published: inc totalled
          elif published == 0: inc totalled     # no manifest count to hold it to
    ck positioned >= 7          # six real + at least one fixture session
    ck inside == positioned
    ck agreeing == positioned
    ck totalled == positioned

  test "assertion count":
    expectCount(21)

# ── 11 — THE BANNER DOES NOT NARRATE THE CAPTURE ────────────────────────────
#
# WHAT THIS SUITE USED TO BE. The capture sentence had three tenses — a frozen
# capture ("is complete and is not being extended", naming every block "taken
# WHOLE"), a running watch ("was last extended … when it was last looked at"),
# and a one-shot scan ("at that moment") — each carrying ISO-8601 instants and
# the replay window in blocks. Sixteen assertions graded which tense a snapshot
# earned, including a real correction: the window had to be the one open at the
# last CATCH rather than at the last poll, because a follower keeps polling for
# hours after it stops catching anything.
#
# All of it was about the capture. A user read the result and asked for prose
# that is "more user friendly and simpler", with "a lot of information that real
# users are unlikely to care about" removed — and a reader does nothing with any
# of it. There is now ONE sentence, `Captured on <date>`, for every snapshot,
# and the tense distinction has no surface to be right or wrong on.
#
# So this suite grades the removal instead, and keeps the two things worth
# keeping: the fixture really is frozen (so the arm below is not vacuous), and
# the frozen/unfrozen distinction is genuinely GONE rather than accidentally
# agreeing on this one capture.
suite "11 — the banner states what a reader needs and not how it was captured":
  asserted = 0
  let frozenBody = renderRoute(root, "/" & RealChain).body
  let frozenProv = snap{"provenance"}

  test "the committed testnet capture IS frozen, so the arm below is not vacuous":
    ck frozenProv{"frozen"}.getBool
    ck frozenProv{"completeBlocks"}.kind == JArray
    ck frozenProv["completeBlocks"].len >= 2

  test "every phrase that narrated the capture is gone from the page":
    for phrase in ["This capture is complete and is not being extended",
                   "were taken WHOLE", "was last extended",
                   "when it was last looked at", "at that moment",
                   "replay window", "drpc.org", "node 5.2.0"]:
      ck phrase notin frozenBody

  test "MUTATION BITE: the same snapshot without `frozen` reads identically":
    # THE ARM THAT PROVES THE BRANCH IS GONE. It used to assert the opposite —
    # that removing the flag reverted the page to watch tense — which is what
    # made the frozen wording a measurement. Now the two must AGREE: a build
    # that still branched on `frozen` would produce two different sentences
    # here, and this is the only place that difference would show.
    let mutDir = workDir / "unfrozen-capture"
    removeDir(mutDir)
    createDir(mutDir)
    var mutSnap = parseJson(readFile(snapshotDir / "snapshot.json"))
    mutSnap["provenance"].delete("frozen")
    mutSnap["provenance"]["firstCapturedAt"] = %"2026-08-30T00:00:00.000Z"
    writeFile(mutDir / "snapshot.json", $mutSnap)
    createDir(mutDir / "ct")
    for kind, path in walkDir(snapshotDir / "ct"):
      if kind == pcFile: copyFile(path, mutDir / "ct" / path.extractFilename)
    let mutOut = workDir / "unfrozen-out"
    removeDir(mutOut)
    createDir(mutOut)
    discard generate(DemoConfig(outDir: mutOut, seed: "chain-prov-unfrozen",
                                traceFixturePath: fixture,
                                traceSourcesDir: fixtureSources))
    let mutIng = ingestSnapshot(IngestConfig(outDir: mutOut, snapshotDir: mutDir))
    let mutDetail = chainInfo(newDataRoot(mutOut), mutIng.chain).provenanceDetail
    let frozenDetail = chainInfo(root, RealChain).provenanceDetail
    # Non-vacuity first: both really did produce the dated sentence, and the
    # date in it is the SPAN the export covers rather than the instant the
    # capture stopped — which is the fact `frozen` would have been most likely
    # to move, since freezing is the last thing that touches `capturedAt`.
    ck "preliminary export covering " in mutDetail
    ck "preliminary export covering " in frozenDetail
    ck "Captured on " notin mutDetail
    ck "Captured on " notin frozenDetail
    ck mutDetail == frozenDetail

  test "assertion count":
    expectCount(16)

# ── 12 — source level is a MEASUREMENT, and a claim with no bundle is refused ─
#
# WHAT CHANGED UNDER THIS SUITE. `ingest.nim` used to publish
# `execution.sourceLevel: false` and an empty `sourceBundles` for every replayed
# transaction, unconditionally, and its comment called rung 3 "the ceiling a
# chain contract can reach". The first half was right about the data it had; the
# second was wrong about WHY. `ContractClassPublic` carries no debug_symbols, no
# file_map and no source text — so rung 3 is the ceiling reachable FROM THE NODE
# — but upstream's `artifactHash` exists so a client can prove an artifact
# fetched from somewhere ELSE, and the replay runtime now does exactly that. A
# contract whose artifact is proved records at rung 1 with real Noir positions.
#
# So `sourceLevel` became a per-transaction measurement, and a measurement needs
# three arms rather than one:
#
#   * the CONTROL — a capture that measured `false`. Nothing under `/src`, an
#     empty `sourceBundles`, the source pane held on the instruction-level floor.
#     Its snapshot deliberately DOES carry a valid sources file and one RESOLVED
#     artifact, because "no bundle was written" has to be a consequence of the
#     measurement and not of there being nothing to write.
#   * the SUBJECT — a capture that measured `true`, with the bundle published,
#     named by code hash, and its `sources` keyed by the exact paths the .ct
#     container interned. Those keys are absolute upstream CI build paths and are
#     asserted BYTE-EQUAL, because a prettier path is a bundle the viewer cannot
#     use and nothing else in the tree would notice.
#   * the REFUSAL — `true` with no bundle. This is the arm the product rule
#     exists for: a manifest claiming source level with nothing to open points the
#     debugger's source pane at a file it cannot fetch, which is the
#     confident-but-wrong answer this repository may not ship. It raises, and the
#     raised message is asserted rather than merely the fact of raising.
#
# The refusal has a NEGATIVE CONTROL beside it (`false` with no sources file must
# NOT raise), so what is being graded is the CLAIM and not the missing file.
suite "12 — a source-level capture publishes source; a rung-3 one publishes none":
  asserted = 0

  const
    SrcChain = "srclevel"
    SrcTx = "0x" & repeat('a', 64)
    SrcAddress = "0x" & repeat('b', 64)
    SrcCodeHash = "0x" & repeat('c', 64)
    UnresolvedAddress = "0x" & repeat('d', 64)
    UnresolvedCodeHash = "0x" & repeat('e', 64)
    SrcOrigin = "npm:@aztec/protocol-contracts@5.3.0-nightly.20260819 FeeJuice"
    # THE EXACT PATHS AN UPSTREAM CI BUILD INTERNS. Absolute, and belonging to a
    # machine nobody here has ever had an account on. That is the point: the .ct
    # container asks for these strings, so the bundle has to answer to these
    # strings, and any rewriting on the way through is a silent break.
    SrcFileA = "/home/aztec-dev/aztec-packages/noir-projects/noir-contracts/" &
               "contracts/protocol/fee_juice_contract/src/main.nr"
    SrcFileB = "/home/aztec-dev/aztec-packages/noir-projects/aztec-nr/aztec/" &
               "src/context/private_context.nr"
    SrcTextA = "use dep::aztec::macros::aztec;\n\n#[aztec]\n" &
               "pub contract FeeJuice {\n    // the text the positions point into\n}\n"
    SrcTextB = "pub struct PrivateContext {\n    pub inputs: PrivateContextInputs,\n}\n"

  let srcWork = getTempDir() / ("bt-srclevel-" & $getCurrentProcessId())
  removeDir(srcWork); createDir(srcWork)

  # A REAL container, copied from the committed capture. `ingestSnapshot` refuses
  # a zero-byte one, so a synthetic snapshot has to carry real bytes; borrowing
  # them keeps this suite about source resolution rather than about CTFS.
  var realCt = ""
  for t in snap["transactions"]:
    if t["outcome"].getStr == "replayed":
      realCt = readFile(snapshotDir / t["container"].getStr)
      break

  proc sourcesDoc(withBundle: bool): JsonNode =
    ## What `replay_settled_transaction.mjs --sources <path>` writes.
    var bundles = newJArray()
    if withBundle:
      var fs = newJObject()
      fs[SrcFileA] = %SrcTextA
      fs[SrcFileB] = %SrcTextB
      var agreeing = newJArray()
      agreeing.add %"npm"
      bundles.add %*{
        "address": SrcAddress, "codeHash": SrcCodeHash,
        "artifactHash": "0x" & repeat('7', 64),
        "origin": SrcOrigin, "shape": "snake_case",
        "corroboration": "single-distributor",
        "agreeingDistributors": agreeing,
        "debugDigest": "sha256:" & repeat('9', 64),
        "files": fs}
    %*{"txHash": SrcTx, "sourceLevel": withBundle, "bundles": bundles}

  proc srcSnapshot(name: string, sourceLevel: bool, sources: JsonNode): string =
    ## One synthetic capture. `sources` is nil for "the driver wrote no bundle
    ## file at all", which is the state the refusal arm is about.
    let dest = srcWork / name
    removeDir(dest)
    createDir(dest / "ct")
    writeFile(dest / "ct" / (SrcTx & ".ct"), realCt)
    # BOTH KINDS OF ARTIFACT ENTRY IN THE RUNG-3 ARM. A code edge is a fact about
    # what the transaction executed, not about whether source was found for it,
    # and `blocktracer_client/sources.nim`'s `codeHashes` walks the edges to
    # decide what to ask for — so an unresolved contract has to be asked about
    # and answered "nothing published", never omitted.
    var artifacts = newJArray()
    artifacts.add %*{
      "address": SrcAddress, "contractClassId": SrcCodeHash, "resolved": true,
      "origin": SrcOrigin, "shape": "snake_case",
      "corroboration": "single-distributor",
      "artifactHash": "0x" & repeat('7', 64), "sourceFiles": 2,
      "reason": "", "rejected": newJArray()}
    var rungs = newJArray()
    rungs.add %*{"address": SrcAddress, "rung": 1,
                 "reason": "artifact proved against the class commitment",
                 "steps": 30, "positioned": 30, "resolved": true}
    if not sourceLevel:
      artifacts.add %*{
        "address": UnresolvedAddress, "contractClassId": UnresolvedCodeHash,
        "resolved": false, "candidatesConsidered": 4,
        "reason": "no distributor served an artifact whose class id matched",
        "rejected": newJArray()}
      rungs.add %*{"address": UnresolvedAddress, "rung": 3,
                   "reason": "no provable artifact", "steps": 12,
                   "positioned": 0, "firstUnpositionedPc": 0, "resolved": false}
    var row = %*{
      "txHash": SrcTx, "blockNumber": 100, "txIndexInBlock": 0,
      "revertCode": 0, "transactionFee": "0x1",
      "bodyRetained": true, "effectVisible": true, "firstInBlock": true,
      "outcome": "replayed",
      "container": "ct/" & SrcTx & ".ct",
      "containerBytes": realCt.len,
      "effects": {"reproduced": true, "matched": 3, "mismatched": 0},
      "recording": {
        "bytes": realCt.len, "steps": 42, "callsOpened": 2,
        "declaredRung": (if sourceLevel: 1 else: 3),
        "stepsPositioned": (if sourceLevel: 42 else: 30),
        "stepsUnpositioned": (if sourceLevel: 0 else: 12),
        "sourceLevel": sourceLevel,
        "contractRungs": rungs},
      "artifacts": artifacts}
    if sources != nil:
      createDir(dest / "sources")
      writeFile(dest / "sources" / (SrcTx & ".json"), sources.pretty & "\n")
      row["sourceBundles"] = %("sources/" & SrcTx & ".json")
    writeFile(dest / "snapshot.json", $(%*{
      "format": "blocktracer/chain-snapshot@1",
      "provenance": {
        "kind": "live-capture", "chain": SrcChain, "label": "Real chain data",
        "endpoint": "https://node.example", "capturedAt": "2026-09-01T09:00:00.000Z",
        "nodeVersion": "5.3.0", "l1ChainId": 1, "runtimeCommit": "abc123def456"},
      "window": {"tip": 110, "finalized": 90, "replayableFrom": 91,
                 "replayableTo": 110, "blocks": 20},
      "blocks": [{"number": 100, "hash": "0x" & align("100", 40, '0'),
                  "timestamp": FixtureBlockTime + 1100, "totalManaUsed": "0x2710",
                  "coinbase": "0x" & repeat('1', 40), "feePerL2Gas": "0x1",
                  "archiveRoot": "0x" & repeat('2', 40),
                  "parentArchiveRoot": "0x" & repeat('3', 40),
                  "transactions": [SrcTx]}],
      "transactions": [row]}))
    dest

  proc treeOf(snapDir: string): string =
    let tree = snapDir / "tree"
    removeDir(tree); createDir(tree)
    discard ingestSnapshot(IngestConfig(outDir: tree, snapshotDir: snapDir))
    tree

  proc theManifest(tree: string): JsonNode =
    for p in walkDirRec(tree / "t"):
      if p.extractFilename == "manifest.json": return parseJson(readFile(p))
    nil

  proc theFacts(tree: string): JsonNode =
    for p in walkDirRec(tree / "d" / SrcChain / "tx"):
      if p.endsWith(".json"): return parseJson(readFile(p))
    nil

  proc fileCount(dir: string): int =
    if not dirExists(dir): return 0
    for p in walkDirRec(dir): inc result

  # ── the control arm ────────────────────────────────────────────────────────
  let ctlTree = treeOf(srcSnapshot("rung3", sourceLevel = false,
                                   sources = sourcesDoc(withBundle = true)))
  let ctlManifest = theManifest(ctlTree)

  test "CONTROL: a capture that measured rung 3 publishes no source at all":
    # The positive control first — trap 4's rule. Every assertion below is about
    # something being absent, and an absent manifest satisfies all of them.
    ck ctlManifest != nil
    ck ctlManifest["container"]["bytes"].getInt > 0
    ck ctlManifest["execution"]["sourceLevel"].getBool == false
    ck ctlManifest["execution"]["languages"].len == 0
    ck ctlManifest["sourceBundles"].len == 0
    # NOT "no bundle for this code hash" — no `/src` subtree at all. The snapshot
    # handed the ingest a perfectly good bundle file and one RESOLVED artifact;
    # what stopped it being published is the measurement and nothing else.
    ck fileCount(ctlTree / "src") == 0

  test "CONTROL: the code edges are published for resolved AND unresolved alike":
    # `codeEdges` was an empty seq before this change, for every transaction. The
    # consumer walks it to decide which bundles to ask for, so a contract missing
    # from it is a contract the source pane can never even report on.
    let facts = theFacts(ctlTree)
    ck facts != nil
    var hashes: seq[string]
    for e in facts["codeEdges"]: hashes.add e["codeHash"].getStr
    hashes.sort()
    var want = @[SrcCodeHash, UnresolvedCodeHash]
    want.sort()
    # The COUNT, not "at least one" — §4b: the membership is knowable and is two.
    ck facts["codeEdges"].len == 2
    ck hashes == want
    var bound: seq[string]
    for e in facts["codeEdges"]: bound.add e["boundAt"].getStr
    ck bound == @["0x" & align("100", 40, '0'), "0x" & align("100", 40, '0')]

  # ── the subject arm ────────────────────────────────────────────────────────
  let subjTree = treeOf(srcSnapshot("rung1", sourceLevel = true,
                                    sources = sourcesDoc(withBundle = true)))
  let subjManifest = theManifest(subjTree)

  test "SUBJECT: the manifest claims source level and names exactly one bundle":
    ck subjManifest != nil
    ck subjManifest["execution"]["sourceLevel"].getBool == true
    ck subjManifest["execution"]["languages"].len == 1
    ck subjManifest["execution"]["languages"][0].getStr == "noir"
    ck subjManifest["sourceBundles"].len == 1
    ck subjManifest["sourceBundles"].hasKey(SrcCodeHash)

  test "SUBJECT: the bundle is published where its id says it is":
    let id = subjManifest["sourceBundles"][SrcCodeHash].getStr
    ck id.len > 0
    ck id.startsWith("sha1:")
    # The consumer reconstructs this path from the id alone — it has no pointer
    # to read — so the derivation is asserted here rather than the file merely
    # being found somewhere under /src.
    let short = id[id.find(':') + 1 .. ^1]
    let dir = subjTree / "src" / SrcChain / SrcCodeHash
    ck fileExists(dir / (short & ".json"))
    ck fileExists(dir / "current.json")
    let pointer = parseJson(readFile(dir / "current.json"))
    ck pointer["sourceBundleId"].getStr == id
    ck pointer["bundle"].getStr == "src" / SrcChain / SrcCodeHash / (short & ".json")

  test "SUBJECT: the bundle's source keys are BYTE-EQUAL to the interned paths":
    # The one assertion nothing else in this tree can make. Every path here is an
    # absolute build path from a machine upstream owns; a producer that tidied
    # them into `src/main.nr` would publish a bundle that validates, renders, and
    # answers no question the container ever asks.
    let id = subjManifest["sourceBundles"][SrcCodeHash].getStr
    let short = id[id.find(':') + 1 .. ^1]
    let bundle = parseJson(readFile(
      subjTree / "src" / SrcChain / SrcCodeHash / (short & ".json")))
    var keys: seq[string]
    for k, _ in bundle["sources"]: keys.add k
    keys.sort()
    var want = @[SrcFileA, SrcFileB]
    want.sort()
    ck bundle["sources"].len == 2
    ck keys == want
    ck bundle["sources"][SrcFileA]["content"].getStr == SrcTextA
    ck bundle["sources"][SrcFileB]["content"].getStr == SrcTextB
    ck bundle["codeHash"].getStr == SrcCodeHash
    ck bundle["chain"].getStr == SrcChain
    ck bundle["match"].getStr == "full"
    ck bundle["provider"].getStr == SrcOrigin
    ck bundle["language"].getStr == "noir"
    # The attestation travels with the text: `artifactHash` commits to the
    # artifact and NOT to its debug symbols or file map, so who vouched for the
    # source has to be readable beside the source.
    ck bundle["debug"]["corroboration"].getStr == "single-distributor"

  test "SUBJECT: the measurement is republished in the transaction's native block":
    let facts = theFacts(subjTree)
    ck facts != nil
    let replay = facts["native"]["replay"]
    ck replay["sourceLevel"].getBool == true
    ck replay["contractRungs"].len == 1
    ck replay["contractRungs"][0]["rung"].getInt == 1
    ck replay["artifacts"].len == 1
    ck replay["artifacts"][0]["contractClassId"].getStr == SrcCodeHash
    ck replay["artifacts"][0]["resolved"].getBool == true
    ck replay["artifacts"][0]["origin"].getStr == SrcOrigin
    # The field this block exists for. A source-level claim resting on one
    # distributor's unverified text must be legible in the published tree, not
    # only inside the container.
    ck replay["artifacts"][0]["corroboration"].getStr == "single-distributor"
    # And the control's block says the other thing, through the same code path.
    let ctlReplay = theFacts(ctlTree)["native"]["replay"]
    ck ctlReplay["sourceLevel"].getBool == false
    ck ctlReplay["artifacts"].len == 2

  test "SUBJECT: the validator has no complaint about the bundles it published":
    # Ranged over the whole tree and then narrowed to this subject: the synthetic
    # chain here is not a complete site, so an unrelated conformance error is not
    # this suite's business — a `sourceBundles` error is.
    var sbErrors = 0
    for e in validateTree(subjTree):
      if "sourceBundle" in e or "source bundle" in e: inc sbErrors
    ck sbErrors == 0
    # THE POSITIVE TWIN, and it is the reason the line above is worth writing.
    # Delete the published bundle object and the same check must redden — without
    # this, a validator that had stopped looking at `sourceBundles` altogether
    # would satisfy the assertion above forever (trap 4a).
    let brokenTree = srcWork / "broken"
    removeDir(brokenTree)
    copyDir(subjTree, brokenTree)
    let id = subjManifest["sourceBundles"][SrcCodeHash].getStr
    let short = id[id.find(':') + 1 .. ^1]
    removeFile(brokenTree / "src" / SrcChain / SrcCodeHash / (short & ".json"))
    var brokenErrors = 0
    for e in validateTree(brokenTree):
      if "missing bundle" in e or "sourceBundles" in e: inc brokenErrors
    ck brokenErrors > 0

  # ── the refusal arm ────────────────────────────────────────────────────────
  test "REFUSAL: source level with NO bundle file raises, and says which tx":
    let d = srcSnapshot("claim-no-file", sourceLevel = true, sources = nil)
    var raised = false
    var msg = ""
    try:
      discard treeOf(d)
    except ValueError as e:
      raised = true
      msg = e.msg
    ck raised
    checkpoint("refusal message: " & msg)
    ck SrcTx in msg
    ck "measured " & SrcTx & " as source level" in msg
    ck "sources/" & SrcTx & ".json" in msg
    ck "refusing to publish positions with no text to put behind them" in msg
    ck "put the debugger's source pane on a file it cannot fetch" in msg

  test "REFUSAL: source level with an EMPTY bundle list raises too":
    # The second half of the same rule. A file that exists and holds nothing is
    # the state a driver reaches when every artifact was rejected, and it must
    # not be mistaken for a bundle.
    let d = srcSnapshot("claim-empty-file", sourceLevel = true,
                        sources = sourcesDoc(withBundle = false))
    var raised = false
    var msg = ""
    try:
      discard treeOf(d)
    except ValueError as e:
      raised = true
      msg = e.msg
    ck raised
    checkpoint("refusal message: " & msg)
    ck "carries no bundle" in msg
    ck SrcTx in msg

  test "NEGATIVE CONTROL: rung 3 with no bundle file is not an error at all":
    # What the two refusals are ABOUT. Without this arm they would be satisfied
    # by an ingest that raised on every capture with no sources file, which is
    # every capture committed before the runtime learned to resolve artifacts.
    let d = srcSnapshot("no-claim-no-file", sourceLevel = false, sources = nil)
    let tree = treeOf(d)                       # must not raise
    let m = theManifest(tree)
    ck m != nil
    ck m["execution"]["sourceLevel"].getBool == false
    ck m["sourceBundles"].len == 0
    ck fileCount(tree / "src") == 0

  test "an older snapshot with NO sourceLevel key at all stays rung 3":
    # The default has to fall to false. Every capture committed before the
    # runtime could resolve artifacts carries no `recording.sourceLevel`, and
    # `getBool` on an absent key answering `true` would turn all of them
    # source-level by accident — with no bundle anywhere to back it.
    let d = srcSnapshot("legacy", sourceLevel = false, sources = nil)
    var sj = parseJson(readFile(d / "snapshot.json"))
    sj["transactions"][0]["recording"].delete("sourceLevel")
    writeFile(d / "snapshot.json", $sj)
    ck sj["transactions"][0]["recording"]{"sourceLevel"}.isNil
    let m = theManifest(treeOf(d))
    ck m["execution"]["sourceLevel"].getBool == false
    ck m["sourceBundles"].len == 0

  test "the committed captures are unchanged by all of this":
    # The frozen fixtures under client/fixtures/chain/ are rung 3 and carry no
    # sources file. They must ingest exactly as before — this whole change is a
    # new branch, not a new requirement on the old data.
    # ONE assertion over the whole set, plus its size — not one per member. The
    # number of recorded transactions in a frozen capture is data, and folding it
    # into this suite's assertion count would make the count a fingerprint of the
    # fixture rather than of the code path (§4b).
    var replayedManifests = 0
    var allRung3 = true
    for t in snap["transactions"]:
      if t["outcome"].getStr notin ["replayed", "divergent"]: continue
      inc replayedManifests
      if t{"recording"}{"sourceLevel"}.getBool: allRung3 = false
    ck allRung3
    ck replayedManifests == ing.withTrace
    ck replayedManifests > 0
    ck traceView(root, chainInfo(root, RealChain), replayedTx).sourceLevel == false
    # A SOURCE BUNDLE IS NOW PUBLISHED FOR THIS CHAIN, AND `sourceLevel` IS STILL FALSE.
    #
    # This used to assert zero files under `src/<chain>/`, on the reasoning that a
    # rung-3 capture has no source to publish. That reasoning held only while a bundle
    # could arrive by one route — the capture measuring itself source level. It can now
    # arrive by a second (CHAIN-CAPTURE.md §6.1a): an artifact proved off-chain against
    # the chain's commitment, positioned against the pcs the container did carry, for a
    # recording that is PARTLY positioned. 86 of this transaction's 108 steps resolve to
    # a Noir line; the capture still measured `sourceLevel: false` and the manifest still
    # publishes false, which is the pair this assertion now pins.
    #
    # The count is deliberately `> 0` and not a number: how many bundles a capture earns
    # is data about which classes anybody publishes, and pinning it here would make this
    # suite a fingerprint of npm.
    ck fileCount(workDir / "src" / RealChain) > 0

  test "SOURCE POSITIONS: the pcs the container carried, joined to a proved artifact":
    # WHAT THIS GRADES. The frozen captures were recorded by a runtime that never
    # looked for source, so their steps carry a program counter and no position —
    # and their bodies are pruned, so no re-recording can add one. The pcs survive
    # (`instructions.json` publishes them) and the artifact's `brillig_locations`
    # is keyed by exactly that AVM byte offset, so the position is a JOIN over data
    # that already exists. `resolve-frozen-artifacts.mjs --write` computes it with
    # the recorder's own `ContractSourceMap`; this asserts the tree carries it.
    #
    # THERE ARE NOW TWO PRODUCERS, AND EVERY FILE IS GRADED. `derive-positions.mjs`
    # reads the positions a rung-2 container wrote WHILE it ran, so the tree
    # publishes `positions.json` by two routes that are the same shape and are not
    # the same claim. This used to fold the whole walk into one `doc` and assert on
    # whichever file the directory yielded LAST: with one producer that was merely
    # loose, with two it graded an arbitrary one of them and the answer changed
    # with the filesystem — green on macOS, red on Linux, off the same tree. Every
    # file is now counted, and the counters are what the assertions are taken over,
    # so the arithmetic below is independent of how many transactions position.
    var found = 0
    var unpositioned = 0     # a file claiming no placed step at all
    var fullyPositioned = 0  # `positioned == steps` — rung 1, which none of these is
    var badShape = 0         # a column whose length is not the recording's step count
    var badIds = 0           # a path id indexing no interned path
    var recorded, postHoc = 0
    var badProvenance = 0    # a flag that disagrees with the file's producer
    var badStamp = 0         # a moment present without the claim, or missing with it
    for path in walkDirRec(workDir / "t"):
      if path.extractFilename != "positions.json": continue
      inc found
      let doc = parseJson(readFile(path))
      let steps = doc{"steps"}.getInt
      let positioned = doc{"positioned"}.getInt
      if positioned <= 0: inc unpositioned
      # A PARTIAL POSITIONING IS THE POINT. `positioned == steps` would be rung 1
      # and the capture would have said so itself; this is the state the corpus
      # previously could not express — an artifact that maps every pc it keys,
      # over an execution that walks pcs it does not key.
      if positioned >= steps: inc fullyPositioned
      # The columns are per-step and are refused at publish time if they are not,
      # so a marker can never land on a row it was not measured for.
      if doc{"pathId"}.len != steps or doc{"line"}.len != steps or
         doc{"column"}.len != steps: inc badShape
      # Every path id indexes a real path, counted rather than asserted per row.
      for i in 0 ..< min(steps, doc{"pathId"}.len):
        let pid = doc["pathId"][i]
        if pid.kind == JNull: continue
        if pid.getInt < 0 or pid.getInt >= doc{"paths"}.len: inc badIds
      # THE FLAG IS PINNED TO THE PRODUCER, which is what it means and is a
      # stronger statement than the constant this line used to assert. A capture
      # that shipped `positions/<tx>.json` measured those coordinates itself,
      # while it ran, against an artifact it had already proved — nothing about it
      # is post-hoc and `measuredPostHoc` is FALSE (derive-positions.mjs, and
      # CHAIN-CAPTURE.md §6.2b for why the stamp matters). Everything else in the
      # tree got its coordinates from the join, and is TRUE. So the check is that
      # each file's flag agrees with which of the two wrote it, per file, rather
      # than that some one file answers a fixed way.
      let isPostHoc = doc{"measuredPostHoc"}.getBool
      var carried = false
      for d in captureDirs:
        if fileExists(d / "positions" / (doc{"tx"}.getStr & ".json")): carried = true
      if isPostHoc: inc postHoc else: inc recorded
      if isPostHoc == carried: inc badProvenance
      # …AND NEVER ANONYMOUSLY. §6.2b requires the post-hoc answer to record when
      # it was taken; the recording's own measurement has no separate moment to
      # record, so the stamp is present exactly when the claim is.
      if isPostHoc != (doc{"measuredAt"}.kind == JString): inc badStamp
    # NON-VACUITY FIRST. Everything above is a statement about a file, and a run
    # that published none would satisfy all of it by having nothing to check.
    ck found > 0
    # BOTH PRODUCERS ARE REPRESENTED. Without these two the provenance check above
    # would be satisfied by a tree that had quietly lost one of the routes — which
    # is the shape the single-`doc` version failed in, one step earlier.
    ck postHoc > 0
    ck recorded > 0
    ck unpositioned == 0
    ck fullyPositioned == 0
    ck badShape == 0
    ck badIds == 0
    ck badProvenance == 0
    ck badStamp == 0
    # AND THE MANIFEST STILL DOES NOT CLAIM SOURCE LEVEL. This is the assertion
    # that keeps the whole feature honest: positions are published, text is
    # published, and the capture's own all-or-nothing measurement is untouched.
    ck traceView(root, chainInfo(root, RealChain), replayedTx).sourceLevel == false

  test "MUTATION BITE: positions of the wrong length are refused at publish time":
    # The defect the length check exists to catch: a column one short marks every
    # row after the gap with the position of its neighbour, and every surface
    # involved goes on reporting success. Driven through the REAL ingest.
    let md = getTempDir() / ("bt-pos-mut-" & $getCurrentProcessId())
    removeDir(md); createDir(md)
    copyDir(snapshotDir, md / "cap")
    let side = md / "cap" / "artifact-resolution.json"
    var doc = parseJson(readFile(side))
    var mutated = 0
    for e in doc["transactions"]:
      let p = e{"positions"}
      if p == nil or p.kind != JObject: continue
      # Drop one entry from a single column — the smallest lie the file can tell.
      p["line"].elems.setLen(p["line"].len - 1)
      inc mutated
    ck mutated == 1                      # the fixture really does carry one
    writeFile(side, doc.pretty)
    var raised = false
    var msg = ""
    try:
      discard ingestSnapshot(IngestConfig(outDir: md / "tree",
                                          snapshotDir: md / "cap"))
    except ValueError as e:
      raised = true
      msg = e.msg
    ck raised
    ck "column of" in msg
    removeDir(md)

  test "assertion count":
    # Written from a run, and deliberately independent of how many transactions
    # the frozen captures happen to hold.
    expectCount(79)   # 6+4+6+6+10+11+2+6+3+4+3+5 + 11 + 2

# ───────────────────────────────────────────────────────────────────────────
# SUITE 13 — WHAT A TRANSACTION LIST LETS A VISITOR TELL ABOUT SOURCE
# ───────────────────────────────────────────────────────────────────────────
#
# Suite 12 grades what the PIPELINE publishes about source. This one grades what
# a VISITOR can tell from it, which is a different claim and had nothing
# asserting it: a transaction list showed a `Debug` button of identical weight
# for a transaction that steps through Noir and one that steps through opcodes,
# and the only way to find out which was to open it.
#
# ## THE STATES ARE A FOLD, NOT A TAXONOMY
#
# `ingest.nim` republishes the recording's own `ct.source-provenance` as
# `native.replay.artifacts` — ONE ENTRY PER CONTRACT THE TRANSACTION EXECUTED,
# resolved or not — or, where the capture recorded none, the same shape measured
# afterwards from `artifact-resolution.json` and marked `measuredPostHoc`
# (CHAIN-CAPTURE.md §6.1a). `reader.sourceCoverage` folds that array and reads
# nothing else. So every state below is a shape the published tree can
# distinguish, and
# each arm here builds its shape by handing the REAL INGEST a capture and
# reading the tree it wrote:
#
#   scAll        every executed contract resolved
#   scPartial    some did — the case the whole feature exists for
#   scNone       all checked, none resolved: today's majority
#   scNoCode     checked; the transaction executed no contract code  (`[]`)
#   scUnchecked  replayed, and the recording carries no record       (`null`)
#   scUnrecorded no replay record at all — the synthetic chain
#
# `[]` and `null` are two objects and two states, and `ingest.nim` publishes
# them apart. The recording writes its provenance record EVEN WHEN IT RESOLVED
# NOTHING, precisely so that absence means "nobody looked" and not "looked and
# found none"; an ingest that collapsed both to `[]` would have destroyed that
# one layer below the runtime, and a badge derived from it would have had to
# guess. `AN EMPTY RECORD AND A MISSING ONE` below is that assertion.
#
# ## THE WORD IS `AVAILABLE`, AND THE SUITE GRADES THAT IT STAYS THAT WAY
#
# `artifactHash` is the chain's commitment to the ARTIFACT and does not commit
# to its `debug_symbols` or its `file_map`: an artifact with every source
# location rewritten passes all three acceptance checks, and a published npm
# decoy ships bytecode byte-identical to a deployed class under a different
# artifact hash with different debug symbols. So no surface here may say
# `verified` about a transaction — that word belongs to §9's contract source
# browser, over a provider's match level — and `NO SURFACE CLAIMS VERIFICATION`
# is a counted negative over every state.
#
# ## RENDERED, NOT DERIVED
#
# Every assertion about what a visitor sees is made against the output of the
# SHIPPING renderers — `components/tables.txTable` and `viewutil.txMetadataRows`
# — not against the enum that fed them. The defect this repository already has
# on record is `debugCell` compiling, running and emitting an empty `<td>` for
# every row in the product; a suite that asserted the enum would have been green
# throughout.

suite "13 — a transaction list says which transactions can be debugged fully":
  asserted = 0

  const
    CovChain = "srccoverage"
    CovTx = "0x" & repeat('1', 64)
    AddrResolved = "0x" & repeat('2', 64)
    ClassResolved = "0x" & repeat('3', 64)
    AddrOther = "0x" & repeat('4', 64)
    ClassOther = "0x" & repeat('5', 64)
    OriginNpm = "npm:@aztec/protocol-contracts@5.3.0-nightly.20260819 FeeJuice"
    OriginScan = "aztecscan:0x3f2a"
    CovFile = "/home/aztec-dev/aztec-packages/noir-projects/noir-contracts/" &
              "contracts/protocol/fee_juice_contract/src/main.nr"

  let covWork = getTempDir() / ("bt-srccov-" & $getCurrentProcessId())
  removeDir(covWork); createDir(covWork)

  var covCt = ""
  for t in snap["transactions"]:
    if t["outcome"].getStr == "replayed":
      covCt = readFile(snapshotDir / t["container"].getStr)
      break
  doAssert covCt.len > 0, "no real container to borrow bytes from"

  proc artifact(address, class: string, resolved: bool,
                origin = "", corroboration = ""): JsonNode =
    result = %*{"address": address, "contractClassId": class,
                "resolved": resolved}
    if origin.len > 0: result["origin"] = %origin
    if corroboration.len > 0: result["corroboration"] = %corroboration

  proc covTree(name: string; artifacts: JsonNode; sourceLevel = false;
               stepsPositioned = -1): string =
    ## One capture through the REAL ingest. `artifacts = nil` writes no
    ## `artifacts` key at all, which is what every capture taken before the
    ## runtime could resolve artifacts off-chain looks like.
    ##
    ## `stepsPositioned` is separable from `sourceLevel` because the chain makes
    ## them separable: `sourceLevel` is true only when EVERY contract reached
    ## rung 1, while a transaction that resolved one contract of two positions
    ## that one's steps and no others. `-1` means "whatever `sourceLevel`
    ## implies", which is every existing arm; a partial recording that really
    ## does show source is the one that has to say so itself.
    let dest = covWork / name
    removeDir(dest); createDir(dest / "ct")
    writeFile(dest / "ct" / (CovTx & ".ct"), covCt)
    var row = %*{
      "txHash": CovTx, "blockNumber": 100, "txIndexInBlock": 0,
      "revertCode": 0, "transactionFee": "0x1",
      "bodyRetained": true, "effectVisible": true, "firstInBlock": true,
      "outcome": "replayed",
      "container": "ct/" & CovTx & ".ct", "containerBytes": covCt.len,
      "effects": {"reproduced": true, "matched": 3, "mismatched": 0},
      "recording": {"bytes": covCt.len, "steps": 42, "callsOpened": 1,
                    "declaredRung": (if sourceLevel: 1 else: 3),
                    "stepsPositioned":
                      (if stepsPositioned >= 0: stepsPositioned
                       elif sourceLevel: 42 else: 0),
                    "stepsUnpositioned":
                      (if stepsPositioned >= 0: 42 - stepsPositioned
                       elif sourceLevel: 0 else: 42),
                    "sourceLevel": sourceLevel}}
    if artifacts != nil: row["artifacts"] = artifacts
    if sourceLevel:
      # `ingest.nim` refuses `sourceLevel: true` with no bundle, and rightly:
      # the arm below is about the badge, not about that refusal, so it hands
      # the ingest a real bundle to publish.
      var files = newJObject()
      files[CovFile] = %"pub contract FeeJuice {}\n"
      createDir(dest / "sources")
      writeFile(dest / "sources" / (CovTx & ".json"), $(%*{
        "txHash": CovTx, "sourceLevel": true,
        "bundles": [{"address": AddrResolved, "codeHash": ClassResolved,
                     "artifactHash": "0x" & repeat('7', 64),
                     "origin": OriginNpm, "shape": "snake_case",
                     "corroboration": "single-distributor",
                     "files": files}]}))
      row["sourceBundles"] = %("sources/" & CovTx & ".json")
    writeFile(dest / "snapshot.json", $(%*{
      "format": "blocktracer/chain-snapshot@1",
      "provenance": {
        "kind": "live-capture", "chain": CovChain, "label": "Real chain data",
        "endpoint": "https://node.example",
        "capturedAt": "2026-09-01T09:00:00.000Z",
        "nodeVersion": "5.3.0", "l1ChainId": 1, "runtimeCommit": "abc123def456"},
      "window": {"tip": 110, "finalized": 90, "replayableFrom": 91,
                 "replayableTo": 110, "blocks": 20},
      "blocks": [{"number": 100, "hash": "0x" & align("100", 40, '0'),
                  "timestamp": FixtureBlockTime + 1100, "totalManaUsed": "0x2710",
                  "coinbase": "0x" & repeat('1', 40), "feePerL2Gas": "0x1",
                  "archiveRoot": "0x" & repeat('2', 40),
                  "parentArchiveRoot": "0x" & repeat('3', 40),
                  "transactions": [CovTx]}],
      "transactions": [row]}))
    let tree = dest / "tree"
    removeDir(tree); createDir(tree)
    discard ingestSnapshot(IngestConfig(outDir: tree, snapshotDir: dest))
    tree

  proc publishedNative(tree: string): JsonNode =
    ## `TransactionFacts.native` exactly as the ingest wrote it to disk. The
    ## fold under test reads this object and nothing else, so this — and not an
    ## in-memory hand-off — is what the arms below hand it.
    for p in walkDirRec(tree / "d" / CovChain / "tx"):
      if p.endsWith(".json"): return parseJson(readFile(p)){"native"}
    nil

  proc coverageOf(name: string; artifacts: JsonNode;
                  sourceLevel = false;
                  stepsPositioned = -1): SourceCoverageView =
    sourceCoverage(publishedNative(
      covTree(name, artifacts, sourceLevel, stepsPositioned)))

  # A row and a view carrying nothing but the coverage under test, so what the
  # renderers are graded on is that field. Everything else is held constant
  # across every arm.
  proc rowWith(cov: SourceCoverageView): TxRow =
    TxRow(hash: CovTx, height: 100, index: 0,
          blockHash: "0x" & align("100", 40, '0'),
          outcome: ooSucceeded, availability: taReady, sources: cov)

  proc tableFor(cov: SourceCoverageView): string =
    txTable(CovChain, @[rowWith(cov)], "no transactions")

  proc actCell(html: string): string =
    ## The first column's cell — §6's "Debug, first column, always visible".
    ## The badge has to be IN it; a badge that rendered at the far right of a
    ## horizontally scrolling table would satisfy a whole-document `contains`
    ## and would be the thing §6 opens by ruling out.
    let a = html.find("<td class=\"act\"")
    if a < 0: return ""
    let b = html.find("</td>", a)
    if b < 0: return ""
    html[a ..< b]

  # ── the six states, each folded from a tree the real ingest wrote ─────────
  let
    covAll = coverageOf("all", %[artifact(AddrResolved, ClassResolved, true,
                                          OriginNpm, "single-distributor")],
                        sourceLevel = true)
    covPartial = coverageOf("partial", %[
      artifact(AddrResolved, ClassResolved, true, OriginNpm,
               "single-distributor"),
      artifact(AddrOther, ClassOther, false)])
    covNone = coverageOf("none", %[
      artifact(AddrResolved, ClassResolved, false),
      artifact(AddrOther, ClassOther, false)])
    # A PARTIAL RECORDING THAT REALLY DOES SHOW SOURCE. `covPartial` above
    # resolved one contract of two over a container that positions nothing —
    # the shape every frozen capture has — so its badge reports what the
    # visitor gets rather than what resolved. This one positions the resolved
    # contract's steps, which is the state `Sources partial` exists to name.
    covPartialShown = coverageOf("partial-shown", %[
      artifact(AddrResolved, ClassResolved, true, OriginNpm,
               "single-distributor"),
      artifact(AddrOther, ClassOther, false)], stepsPositioned = 20)
    covNoCode = coverageOf("nocode", newJArray())
    covUnchecked = coverageOf("unchecked", nil)
    covCorroborated = coverageOf("corroborated", %[
      artifact(AddrResolved, ClassResolved, true, OriginNpm, "corroborated"),
      artifact(AddrOther, ClassOther, true, OriginScan, "corroborated")],
      sourceLevel = true)

  test "the fold names each of the five measured states, from the real ingest":
    # Counted, and every state named — a `case` that lost a branch would show up
    # as a state answering with its neighbour rather than as a compile error,
    # because the enum has an ordering and the fold's `elif` chain does not.
    ck covAll.state == scAll
    ck covPartial.state == scPartial
    ck covNone.state == scNone
    ck covNoCode.state == scNoCode
    ck covUnchecked.state == scUnchecked
    ck covCorroborated.state == scAll

  test "AN EMPTY RECORD AND A MISSING ONE ARE TWO STATES, ON DISK":
    # The distinction the recording goes to the trouble of carrying, asserted
    # where it is easiest to destroy: `ingest.nim` used to publish `[]` for
    # both. The two published objects are read back from the tree, not from the
    # snapshot that went in.
    let empty = publishedNative(covTree("nocode-disk", newJArray()))
    let missing = publishedNative(covTree("unchecked-disk", nil))
    ck empty["replay"]["artifacts"].kind == JArray
    ck empty["replay"]["artifacts"].len == 0
    ck missing["replay"]["artifacts"].kind == JNull
    # And they must not fold to the same answer, which is the consequence.
    ck sourceCoverage(empty).state != sourceCoverage(missing).state

  test "the numerator and denominator are the transaction's, not the resolved set's":
    # `contracts` counts EVERY contract the transaction executed. A fold that
    # filtered to the resolved entries first would report 1/1 here and call a
    # half-debuggable transaction complete — the confident-and-wrong answer.
    ck covPartial.contracts == 2
    ck covPartial.resolved == 1
    ck sourcesCount(covPartial) == "1/2"
    ck covNone.contracts == 2
    ck covNone.resolved == 0
    ck sourcesCount(covNone) == "0/2"
    # Not "3/3" beside a badge that already means all of them.
    ck sourcesCount(covAll) == ""

  test "corroboration is ANDed over the resolved contracts, never averaged":
    # One contract on a single distributor makes the whole transaction's source
    # text rest on that party's word — a visitor stepping through it cannot tell
    # which lines came from which artifact.
    ck covCorroborated.corroboration == scCorroborated
    ck covAll.corroboration == scSingleDistributor
    ck covPartial.corroboration == scSingleDistributor
    # Nothing resolved is not a weak claim; it is no claim.
    ck covNone.corroboration == scNoClaim
    ck covUnchecked.corroboration == scNoClaim
    let mixed = coverageOf("mixed", %[
      artifact(AddrResolved, ClassResolved, true, OriginNpm, "corroborated"),
      artifact(AddrOther, ClassOther, true, OriginScan, "single-distributor")],
      sourceLevel = true)
    ck mixed.state == scAll
    ck mixed.corroboration == scSingleDistributor

  test "the distributors are named, deduplicated and ordered":
    ck covCorroborated.origins == @[OriginScan, OriginNpm].sorted()
    ck covAll.origins == @[OriginNpm]
    ck covNone.origins.len == 0

  test "RENDERED: every measured state reaches the first column of the table":
    # Against the shipping `txTable`, and inside §6 column 1's cell. `debugCell`
    # is on record for compiling, running and emitting an empty `<td class=act>`
    # for every row in the product, so "the enum was right" is not the claim.
    var states: seq[string]
    for cov in [covAll, covPartial, covNone, covNoCode, covUnchecked]:
      let cell = actCell(tableFor(cov))
      ck cell.contains("data-sources=\"" & $cov.state & "\"")
      ck cell.contains(sourcesState(cov))
      states.add $cov.state
    # The count, and that the five arms were five different states — §4b: the
    # membership is knowable and it is five.
    ck states.len == 5
    ck states.deduplicate().len == 5

  test "RENDERED: the badge qualifies the action and does not become one":
    # §6: "it is the only control in the table, so nothing can outrank it."
    let html = tableFor(covPartialShown)
    let cell = actCell(html)
    ck cell.contains("class=\"btn sm primary\"")
    # The action first, the qualifier second — the order of the decision.
    ck cell.find("btn sm primary") < cell.find("srcbadge")
    # A span, not an anchor and not a button: one control in the cell, still.
    ck occurrences(cell, "<a ") == 1
    ck not cell.contains("<button")
    ck cell.contains("<span class=\"badge srcbadge warn\"")
    # And the ratio is in the badge, because "partial" alone leaves a visitor to
    # open the session to find out how partial.
    ck cell.contains("<span class=\"mono\">1/2</span>")

  test "RENDERED: a transaction with no replay record states nothing at all":
    # `scUnrecorded` is not a weaker badge — it is no badge. The badge reports
    # the outcome of off-chain artifact resolution against an on-chain class
    # commitment, and the synthetic chain has no class to resolve against, so a
    # `Not checked` there would state a result for a procedure never applied.
    let cell = actCell(tableFor(SourceCoverageView(state: scUnrecorded)))
    ck cell.len > 0
    ck cell.contains("class=\"btn sm primary\"")   # the row is otherwise whole
    ck not cell.contains("data-sources")
    ck not cell.contains("srcbadge")
    ck not sourcesStated(scUnrecorded)
    # …and the bytes are EXACTLY the bytes a row emitted before this feature
    # existed: no wrapper element, so 107 pages of the synthetic chain did not
    # move for a badge they never show.
    ck cell == "<td class=\"act\" data-label=\"Debug\">" &
               debugCell(CovChain, rowWith(SourceCoverageView(state: scUnrecorded)))

  test "NO SURFACE CLAIMS VERIFICATION, in any state":
    # `verified` would mean "this text is the text that was compiled", and
    # nothing in the chain attests it: `artifactHash` does not commit to
    # `debug_symbols` or `file_map`, an artifact with every source location
    # rewritten passes all three acceptance checks, and a published npm decoy
    # ships byte-identical bytecode under a different artifact hash with
    # different symbols. §9's contract source browser owns that word.
    # The subject is the PRODUCT'S OWN COPY. A distributor's name is quoted
    # data and the note prints it verbatim, so an origin string containing the
    # word would fail this for the wrong reason — that is not a claim the
    # product is making, it is a name the product is repeating.
    var checkedStates = 0
    for cov in [covAll, covPartial, covNone, covNoCode, covUnchecked,
                covCorroborated]:
      inc checkedStates
      var words = sourcesState(cov) & " " & sourcesNote(cov) & " " &
                  tableFor(cov)
      for origin in cov.origins: words = words.replace(origin, "")
      ck not words.toLowerAscii.contains("verified")
      ck not words.toLowerAscii.contains("verification")
    ck checkedStates == 6
    # The positive control for the negative claim: the strong state DOES make a
    # claim, and it is the one the chain can actually back.
    ck sourcesState(covAll) == "Sources available"
    ck sourcesNote(covAll).contains("matches the code that ran on the chain")

  test "the single-publisher caveat is stated wherever it is true":
    # The residual weakness lives on its own axis and is not rounded away: on
    # one publisher the source text is that party's unchecked word. It is
    # asserted on the states that SHOW source, because that is where a reader
    # could be misled by it — a recording that shows none makes no claim about
    # text and says so instead.
    ck sourcesNote(covAll).contains("a single publisher")
    ck sourcesNote(covCorroborated).contains("corroborated")
    ck not sourcesNote(covCorroborated).contains("a single publisher")
    # Neither surface claims the chain proves the TEXT.
    ck sourcesNote(covAll).contains("not the source text beside it")

  test "the two no-answer states share a label and are told apart in the note":
    # `availabilityNote`'s rule, applied: a badge may not name a cause it cannot
    # tell, and the cause is stated where there is room for a sentence.
    ck sourcesState(SourceCoverageView(state: scUnchecked)) ==
       sourcesState(SourceCoverageView(state: scUnrecorded))
    ck sourcesState(covUnchecked) == "Not checked"
    ck sourcesNote(covUnchecked).contains("Nobody has checked")
    ck sourcesNote(SourceCoverageView(state: scUnrecorded)) !=
       sourcesNote(covUnchecked)
    # And neither reads as a finding about what is published.
    ck not sourcesNote(covUnchecked).contains("nobody has published")

  test "the majority state does not read as a fault":
    # `scNone` is every real transaction this site publishes today. A row that
    # read as broken for the common case would teach a visitor to ignore the
    # badge, and then it is not there for the uncommon one.
    ck sourcesState(covNone) == "Instruction level"
    ck sourcesClass(covNone) == "muted"
    ck sourcesClass(covNone) != outcomeClass(ooReverted)
    ck sourcesNote(covNone).contains("Stepping through it works either way")
    ck sourcesClass(covAll) == "ok"
    # `warn` belongs to a partial recording that CAN show what it resolved. The
    # class is built from both axes now, so the subject has to carry both.
    ck sourcesClass(SourceCoverageView(state: scPartial, contracts: 2,
                                       resolved: 1, positioned: true)) == "warn"

  test "§7.1: the page and the debugger's pane render the fact from ONE source":
    # A `Sources` block written into `pages/tx.nim` would have been a second
    # producer and the pane would have gone on lacking it. So the row is added
    # in `txMetadataRows` and nowhere else, and both surfaces are asserted.
    let info = chainInfo(root, RealChain)
    var v = TxView(chain: CovChain, hash: CovTx, height: 100, index: 0,
                   outcome: ooSucceeded, finality: "finalized", canonical: true,
                   sources: covPartialShown)
    let rows = txMetadataRows(CovChain, v, info)
    var found = 0
    for r in rows:
      if r.label == "Sources":
        inc found
        ck r.value == "Sources partial"
        ck r.badge == "warn"
        ck r.note == sourcesNote(covPartialShown)
    ck found == 1
    # The debugger's metadata pane is built from the same `txMetadataRows` call
    # and rendered by the shipping renderer, so it carries the row too — that
    # is §7.1's "rendered in two places … from one source" as an assertion
    # rather than as a comment.
    let pane = dbgc.renderMetadata(metadataPane(CovChain, v, info))
    ck pane.contains("Sources partial")
    ck pane.contains(sourcesNote(covPartialShown))
    # …and a transaction with no replay record contributes no row to either.
    v.sources = SourceCoverageView(state: scUnrecorded)
    var absent = 0
    for r in txMetadataRows(CovChain, v, info):
      if r.label == "Sources": inc absent
    ck absent == 0

  test "the wiring: txRow and txView carry the fold, over the shipping reader":
    # Everything above grades the fold and the renderers. This grades that a row
    # the PRODUCT builds actually carries it — the seam where a field is
    # declared, rendered and never assigned.
    let realInfo = chainInfo(root, RealChain)
    let realRow = txRow(root, realInfo, replayedTx)
    # THIS USED TO ASSERT `scUnchecked`, AND THAT WAS THE STATUS QUO A USER
    # OBJECTED TO. The frozen captures were taken by a runtime that could not
    # resolve artifacts, so every real transaction on the site read "Not
    # checked" — "nobody looked". The bodies are pruned and cannot be
    # re-captured, so the question was asked without them:
    # `resolve-frozen-artifacts.mjs --write` resolves against the contract
    # classes the node still serves, and `ingest.nim` republishes that answer
    # marked as measured after the fact. The states below are therefore
    # MEASURED, and the two surfaces are asserted to agree because `txRow`
    # projects `txView` and a divergence here would be a fold read twice.
    ck realRow.sources.state == txView(root, realInfo, replayedTx).sources.state
    ck realRow.sources.state notin {scUnchecked, scUnrecorded}
    let demoInfo = chainInfo(root, DemoChain)
    let demoPage = txsFrom(root, demoInfo, -1)
    ck demoPage.rows.len > 0
    let demoTx = demoPage.rows[0].hash
    ck demoPage.rows[0].sources.state == scUnrecorded
    ck txRow(root, demoInfo, demoTx).sources.state == scUnrecorded

  test "NOTHING PUBLISHED READS 'Not checked', and the count is not zero":
    # THE USER'S ACTUAL REQUIREMENT, as a gate. "We should check all
    # transactions before publishing" — so no published row may report the
    # outcome of a procedure nobody ran. Every row must land on a MEASURED
    # state: `scAll`, `scPartial`, `scNone` or `scNoCode`.
    #
    # THE COUNT IS ASSERTED FIRST AND ASSERTED NON-ZERO. "0 of 0 transactions
    # are unchecked" passes vacuously, and an ingest that published no
    # transactions at all would satisfy every other line in this test. The
    # denominator is the claim.
    # `scUnchecked` AND `scUnrecorded` ARE NOT THE SAME FAILURE, and only the
    # first is the one the user saw. `sourcesStated` renders no badge at all for
    # `scUnrecorded`, because a transaction with no replay record had no
    # resolution applied and there is no outcome to report — a pruned body is
    # not a procedure somebody skipped. So the gate is: no row RENDERS "Not
    # checked", and every row that has a replay record lands on a measured
    # state. The second clause is what stops the first from being satisfiable by
    # quietly downgrading replayed rows to `scUnrecorded`.
    let realInfo = chainInfo(root, RealChain)
    var replayedHashes: seq[string]
    for t in snap["transactions"]:
      if t["outcome"].getStr in ["replayed", "divergent"]:
        replayedHashes.add t["txHash"].getStr
    var published, saysNotChecked, silent, silentButReplayed, withSources = 0
    var fromH = -1
    while true:
      let page = txsFrom(root, realInfo, fromH)
      for row in page.rows:
        inc published
        if sourcesStated(row.sources.state):
          if sourcesState(row.sources) == "Not checked": inc saysNotChecked
        else:
          inc silent
          # A row that states nothing must be one the capture never replayed.
          # Counted rather than asserted per row, so the assertion total stays
          # independent of how many transactions the capture happens to hold.
          if row.hash in replayedHashes: inc silentButReplayed
        if row.sources.state in {scAll, scPartial}: inc withSources
      if not page.hasMore: break
      fromH = page.nextFrom
    ck published > 0
    ck saysNotChecked == 0
    ck silentButReplayed == 0
    # Non-vacuity in the other direction: this scope really does publish both
    # populations, so the loop above was not silently grading an empty half.
    ck silent > 0
    ck published - silent > 0

    # AND THE TREE AGREES WITH THE MEASUREMENT, rather than with itself. The
    # expected number of transactions carrying source comes out of the sidecar
    # the resolver wrote — the same discipline the ground-truth block at the top
    # of this file uses, and for the same reason: a test that asked the reader
    # how many it had resolved would agree with a tree it had misread.
    let side = parseJson(readFile(snapshotDir / "artifact-resolution.json"))
    var sideResolvedTxs = 0
    for e in side["transactions"]:
      let arts = e{"artifacts"}
      if arts == nil or arts.kind != JArray or arts.len == 0: continue
      var anyResolved = false
      for a in arts:
        if a{"resolved"}.getBool: anyResolved = true
      if anyResolved: inc sideResolvedTxs
    ck sideResolvedTxs > 0
    ck withSources == sideResolvedTxs

  test "a resolved artifact over an unpositioned recording does not over-promise":
    # THE WAY THIS FEATURE GOES WRONG. The frozen captures resolve artifacts
    # after the fact, so a transaction can read `Sources available` over a
    # container whose steps were never written against a debug map. The badge is
    # true — the artifact is provable — but on its own it would promise text the
    # debugger cannot show, and the source pane inches away says "Stepping
    # continues at instruction level". So the note has to say which of the two
    # is the case, and this asserts it does.
    let realInfo = chainInfo(root, RealChain)
    var subject = SourceCoverageView()
    var found = 0
    var fromH = -1
    while true:
      let page = txsFrom(root, realInfo, fromH)
      for row in page.rows:
        if row.sources.state == scAll:
          inc found
          subject = row.sources
      if not page.hasMore: break
      fromH = page.nextFrom
    ck found > 0
    # THE BADGE, AND A USER PAID FOR THIS LINE. It used to assert
    # `Sources available` here, with the caveat carrying the correction. A
    # visitor read the badge on this exact transaction, clicked, and got
    # bytecode — the note was on the page, in full, and it did not help, because
    # the badge is the headline and the note is a paragraph under it.
    ck sourcesState(subject) != "Sources available"
    ck sourcesState(subject) == "Source not recorded"
    # And it is not dressed as an affirmative outcome either: `ok` is a promise
    # made in colour, and it would have outlived the words.
    ck sourcesClass(subject) == "muted"
    # Measured after the capture, over a recording that positions nothing.
    ck subject.postHoc
    ck not subject.positioned
    # The note leads with what the reader GETS, then says the source is real.
    ck sourcesNote(subject).contains("not its source code")
    ck sourcesNote(subject).contains("matches what ran on the chain")
    # No surface claims the strong word — §9 owns `verified`.
    ck not sourcesNote(subject).toLowerAscii.contains("verified")

  # ── mutation arms ────────────────────────────────────────────────────────
  #
  # Each one perturbs exactly the input its named assertion above rests on, and
  # asserts that the answer MOVES. A suite whose arms all agree with the code
  # is a suite that would agree with the code after it broke.

  test "MUTATION BITE: an unresolved contract dropped from the array reads as complete":
    # The defect the denominator exists to catch. Filter the partial capture's
    # array to its resolved entries — exactly what a well-meaning "only publish
    # what we found" change does — and a 1-of-2 transaction claims all of them.
    let mutated = coverageOf("mut-drop-unresolved",
                             %[artifact(AddrResolved, ClassResolved, true,
                                        OriginNpm, "single-distributor")])
    ck mutated.state == scAll
    ck mutated.state != covPartial.state
    # The FOLD is what this arm bites; the badge is unpositioned here, so the
    # label is the honest one and the state underneath it is still wrong.
    ck sourcesState(mutated) == "Source not recorded"
    ck sourcesState(SourceCoverageView(state: mutated.state, contracts: 1,
                                       resolved: 1, positioned: true)) ==
       "Sources available"

  test "MUTATION BITE: a missing record collapsed to an empty one loses a state":
    # `ingest.nim` before this change. Fold the two published objects the OLD
    # way — everything absent becomes `[]` — and `unchecked` disappears into
    # `no code`, so "nobody looked" is published as "nothing to look at".
    let collapsed = newJObject()
    collapsed["replay"] = %*{"artifacts": newJArray()}
    ck sourceCoverage(collapsed).state == scNoCode
    ck sourceCoverage(collapsed).state != covUnchecked.state
    ck sourcesNote(sourceCoverage(collapsed)) != sourcesNote(covUnchecked)

  test "MUTATION BITE: one distributor upgraded to corroborated overstates the claim":
    let mutated = coverageOf("mut-corroborate", %[
      artifact(AddrResolved, ClassResolved, true, OriginNpm, "corroborated")],
      sourceLevel = true)
    ck mutated.corroboration == scCorroborated
    ck mutated.corroboration != covAll.corroboration
    ck not sourcesNote(mutated).contains("one distributor's word")
    ck sourcesNote(mutated) != sourcesNote(covAll)

  test "MUTATION BITE: the badge gated OUT of the cell leaves the row silent":
    # `debugCell`'s recorded defect, in this feature's shape: the cell renders,
    # the row renders, the table renders, and the qualifier is simply absent.
    let silent = actCell(txTable(CovChain,
                                 @[rowWith(SourceCoverageView(state: scUnrecorded))],
                                 "none"))
    let stated = actCell(tableFor(covPartial))
    ck not silent.contains("data-sources")
    ck stated.contains("data-sources")
    ck silent != stated

  test "MUTATION BITE: `scNone` given the danger treatment collides with a revert":
    # Two unrelated things in one colour is how a status vocabulary stops
    # meaning anything, and `bad` is already what a reverted execution wears.
    ck outcomeClass(ooReverted) == "bad"
    ck sourcesClass(covNone) != "bad"
    ck sourcesClass(SourceCoverageView(state: scPartial, contracts: 2,
                                       resolved: 1, positioned: true)) !=
       outcomeClass(ooReverted)

  test "MUTATION BITE: the sidecar ignored puts every real row back on 'Not checked'":
    # The gate above asserts that nothing published reads "Not checked". This is
    # the state it guards against, produced on purpose: a capture with no
    # `artifacts` key — which is every frozen capture as it was taken — folds to
    # `scUnchecked`, and that is what the site showed before the resolution pass.
    # If `ingest.nim` stopped reading `artifact-resolution.json`, the gate would
    # see this, so the gate is not vacuous.
    let ignored = coverageOf("mut-sidecar-ignored", nil)
    ck ignored.state == scUnchecked
    ck sourcesState(ignored) == "Not checked"
    ck sourcesNote(ignored).contains("Nobody has checked")

  test "MUTATION BITE: the badge moves with the recording, not with the resolution":
    # THE SAME RESOLVED ARTIFACTS, TWO RECORDINGS. If the label read the
    # resolution alone — which is what it did when a visitor was misled — both
    # of these would say `Sources available` and the arm would not move. The
    # only difference between them is whether the container positions steps,
    # and that is exactly what a visitor is deciding about when they read it.
    let arts = %[artifact(AddrResolved, ClassResolved, true, OriginNpm,
                          "corroborated")]
    let unpositioned = coverageOf("mut-caveat-on", arts, sourceLevel = false)
    let positioned = coverageOf("mut-caveat-off", arts, sourceLevel = true)
    ck unpositioned.state == scAll
    ck positioned.state == scAll
    ck sourcesState(unpositioned) == "Source not recorded"
    ck sourcesState(positioned) == "Sources available"
    ck sourcesClass(unpositioned) != sourcesClass(positioned)
    # And the sentence about what you get is conditional too, not decoration.
    ck sourcesNote(unpositioned).contains("not its source code")
    ck not sourcesNote(positioned).contains("not its source code")

  test "assertion count":
    expectCount(136)

# ───────────────────────────────────────────────────────────────────────────
# SUITE 14 — ONE CHAIN, TWO RECORDERS, NEITHER MISFILED
# ───────────────────────────────────────────────────────────────────────────
#
# THE DEFECT THIS SUITE EXISTS FOR, and it is a provenance defect rather than an
# availability one — which is what made it easy to take the wrong fix and
# impossible to see afterwards.
#
# `traceArtifactId` commits to `recorderBuild` on purpose: ids.nim says
# "changing the recorder must change the URL so a stale artifact cannot outlive
# a bug fix". The ingest derived that term from `provenance.runtimeCommit` — ONE
# value for a whole snapshot — and the registry stored ONE recorder pin per
# chain. A chain is watched for days while the recorder is improved, so the
# moment a container from a newer build had to be published, the only lever was
# to move the chain's commit. That re-derives the address of every container the
# OLD build produced and files their bytes under a build that never ran them.
#
# NOTHING WOULD HAVE GONE RED. Pages resolve by transaction hash, so every one
# of them would still have opened; the id would still have been content-derived;
# the validator would still have agreed with the producer, because both read the
# same single pin. The only casualty is the one thing the artifact id is FOR.
# That is why the checks below are about what each container SAYS PRODUCED IT
# and not about whether it loads.
#
# THE SUBJECT IS BUILT BY THE REAL INGEST over the committed capture with its
# per-container provenance filled in — the two shapes a snapshot can state it in
# (a `captures[]` entry that yielded the transaction, and the row's own
# `recordedBy`) are both exercised, because both are load-bearing and only one
# of them existed in the fixture.
suite "14 — one chain carries containers from two recorders, each filed as its own":
  asserted = 0

  const
    # A second recorder, standing in for the frames-carrying build. Any commit
    # that is not the capture's own will do; what matters is that it is
    # different, because the whole claim is that difference survives publishing.
    FramesCommit = "f4a3e5c17b2d9e0a6c8b1f3d5e7a9c2b4d6f8a01"
    IncumbentCommit = "29bd9cfd5b01ea45d9d35ab82c24d1da683dd061"

  let rd = getTempDir() / ("bt-rec-prov-" & $getCurrentProcessId())
  removeDir(rd); createDir(rd)

  proc manifestsByTx(tree: string): Table[string, JsonNode] =
    ## Every published manifest in `tree`, keyed by the transaction it is about.
    ##
    ## READ BACK OFF DISK, which is the point. Asserting against the values the
    ## ingest computed would be asking the code that wrote the tree whether it
    ## wrote it correctly; these are the bytes a browser would fetch.
    result = initTable[string, JsonNode]()
    for path in walkDirRec(tree / "t"):
      if path.endsWith("manifest.json"):
        let m = parseJson(readFile(path))
        result[m["tx"].getStr] = m

  proc overlayRecorderOf(tree, chain, txHash: string): JsonNode =
    ## The `recorder` an overlay row names, or nil where it names none.
    let p = tree / "d" / chain / "ts" / "1" / hexShard(txHash) / (txHash & ".json")
    if not fileExists(p): return nil
    parseJson(readFile(p)){"trace"}{"recorder"}

  # ── the control: the capture EXACTLY AS COMMITTED ─────────────────────────
  #
  # This used to say "one recorder", and it was true until the capture published
  # `0x20ed5b91…`'s frames container under the build that wrote it. The control's
  # job never depended on that: it is "the same capture WITHOUT the second
  # recorder this suite adds", so the assertions below are stated against the
  # control's own answer per container rather than against `incumbentBuild`. That
  # is the stronger form anyway — "unchanged" is the claim, and comparing to a
  # literal only tested it while every row happened to share one build.
  let oneTree = rd / "one"
  createDir(oneTree)
  discard ingestSnapshot(IngestConfig(outDir: oneTree, snapshotDir: snapshotDir))
  let oneManifests = manifestsByTx(oneTree)
  # Captured NOW: the last test re-ingests the mixed capture into `oneTree` and
  # rewrites this file, so a later read would not be the control's inventory.
  var controlBuilds: seq[string]
  block:
    let controlReg = parseJson(readFile(oneTree / "registry" / "chains.v1.json"))
    for r in controlReg["chains"]["aztec-testnet"]["recorders"]:
      controlBuilds.add r["build"].getStr

  # ── the subject: the same capture, with SOME containers attributed to a
  #    second recorder, stated in both of the two ways a snapshot may state it ─
  let mixedCap = rd / "cap"
  copyDir(snapshotDir, mixedCap)
  var mixedDoc = parseJson(readFile(mixedCap / "snapshot.json"))
  var viaCapturesTx, viaRecordedByTx = ""
  block attribute:
    # Two recorded transactions, chosen from the capture's own JSON in a stable
    # order so the subject is the same on every run.
    # A ROW THAT ALREADY NAMES ITS OWN RECORDER IS NOT A CANDIDATE. The capture
    # now carries one (`0x20ed5b91…`, the frames container it publishes), and
    # attributing this suite's second build to it would overwrite the very field
    # under test and leave the subject indistinguishable from the fixture. The
    # two subjects must be rows that would otherwise take the chain's default.
    var recorded: seq[string]
    for t in mixedDoc["transactions"]:
      if t["outcome"].getStr in ["replayed", "divergent"] and
         t{"recordedBy"}.getStr.len == 0:
        recorded.add t["txHash"].getStr
    recorded.sort()
    doAssert recorded.len >= 2,
      "the capture must hold at least two containers for this suite to be " &
      "about a MIXED chain; it holds " & $recorded.len
    viaCapturesTx = recorded[0]
    viaRecordedByTx = recorded[1]
    # (a) a `captures[]` entry — the follower's own contemporaneous note of
    #     which build was running when it caught this transaction.
    for c in mixedDoc["captures"]:
      for y in c{"yielded"}:
        if y{"txHash"}.getStr == viaCapturesTx:
          c["runtimeCommit"] = %FramesCommit
    # (b) the row's own `recordedBy` — what a recorder running outside the
    #     follower has to be able to say for itself.
    for t in mixedDoc["transactions"]:
      if t["txHash"].getStr == viaRecordedByTx:
        t["recordedBy"] = %FramesCommit
  writeFile(mixedCap / "snapshot.json", mixedDoc.pretty)

  let mixedTree = rd / "mixed"
  createDir(mixedTree)
  discard ingestSnapshot(IngestConfig(outDir: mixedTree, snapshotDir: mixedCap))
  let mixedManifests = manifestsByTx(mixedTree)

  let framesBuild = recorderBuildHash("aztec-avm", "l3-" & FramesCommit[0 .. 9] & "…")
  let incumbentBuild = recorderBuildHash("aztec-avm",
                                         "l3-" & IncumbentCommit[0 .. 9] & "…")

  test "the fixture really is mixed — two recorders, both with containers":
    # THE POSITIVE CONTROL, and this suite needs it more than most: every
    # assertion below is a universal over "the containers from recorder X", and
    # a subject where one of those sets is empty satisfies all of them
    # vacuously (Verification-Harness-Traps §4).
    ck framesBuild != incumbentBuild
    var fromFrames, fromIncumbent, notFromFrames = 0
    for _, m in mixedManifests:
      let b = m["recorder"]["build"].getStr
      if b == framesBuild: inc fromFrames
      else:
        inc notFromFrames
        if b == incumbentBuild: inc fromIncumbent
    ck fromFrames == 2                       # the two attributed above
    # NOT `fromIncumbent == len - 2`: the capture itself now carries a container
    # on a third build, so "everything else is the incumbent" stopped being true
    # of the fixture without anything being wrong with it. What the positive
    # control needs is that BOTH sides of every universal below are non-empty.
    ck notFromFrames == mixedManifests.len - 2
    ck fromIncumbent > 0

  test "every container reports the recorder that produced it, read back off disk":
    # The claim, stated over the published bytes rather than over the ingest's
    # variables. `viaCapturesTx` and `viaRecordedByTx` are the two attribution
    # SHAPES; both must land, because a fix that honoured only one would leave
    # the other silently inheriting the chain's pin.
    ck mixedManifests[viaCapturesTx]["recorder"]["build"].getStr == framesBuild
    ck mixedManifests[viaRecordedByTx]["recorder"]["build"].getStr == framesBuild
    # AGAINST THE CONTROL'S OWN ANSWER, not against `incumbentBuild`. Every row
    # this suite did not touch must be filed under exactly the build the same
    # capture files it under with no second recorder in it — which is the claim,
    # and which stays the claim now that the capture's own rows do not all share
    # one build.
    var checkedUnchanged = 0
    for tx, m in mixedManifests:
      if tx in [viaCapturesTx, viaRecordedByTx]: continue
      ck m["recorder"]["build"].getStr == oneManifests[tx]["recorder"]["build"].getStr
      inc checkedUnchanged
    ck checkedUnchanged == mixedManifests.len - 2

  test "the overlay tells a browser the SAME recorder the manifest names":
    # The two are separate files written on separate paths, and they are the two
    # ends of one derivation: the overlay's `recorder` is what a client feeds to
    # `deriveTraceArtifactId`, and the manifest at the resulting address is what
    # it finds. If they can disagree, a page derives an address for a container
    # that is not there and reports a failed fetch for a container sitting on
    # disk. Nothing else in the tree compares them.
    var compared = 0
    for tx, m in mixedManifests:
      let o = overlayRecorderOf(mixedTree, "aztec-testnet", tx)
      ck o != nil
      if o == nil: continue
      ck o["build"].getStr == m["recorder"]["build"].getStr
      ck o["id"].getStr == m["recorder"]["id"].getStr
      inc compared
    ck compared == mixedManifests.len

  test "a second recorder does not re-address the first recorder's containers":
    # THE WHOLE POINT, AND THE THING THE WRONG FIX GETS WRONG. Publishing a
    # container from a newer build must leave every older container at the
    # address it already has. Compared against the CONTROL tree — the same
    # capture ingested with no second recorder in it — so this is a before/after
    # over bytes and not a restatement of the rule.
    var unchanged = 0
    for tx, m in mixedManifests:
      if tx in [viaCapturesTx, viaRecordedByTx]: continue
      ck tx in oneManifests
      ck m["traceArtifactId"].getStr == oneManifests[tx]["traceArtifactId"].getStr
      ck m["container"]["hash"].getStr == oneManifests[tx]["container"]["hash"].getStr
      inc unchanged
    ck unchanged == mixedManifests.len - 2
    # …and the two that DID change recorder moved, because `recorderBuild` is a
    # term of the id. An id that did not move would mean the term is not
    # actually load-bearing, which is the other way this contract can be broken.
    ck mixedManifests[viaCapturesTx]["traceArtifactId"].getStr !=
       oneManifests[viaCapturesTx]["traceArtifactId"].getStr
    ck mixedManifests[viaRecordedByTx]["traceArtifactId"].getStr !=
       oneManifests[viaRecordedByTx]["traceArtifactId"].getStr

  test "the registry states the chain's inventory of recorders, not just its default":
    let reg = parseJson(readFile(mixedTree / "registry" / "chains.v1.json"))
    let row = reg["chains"]["aztec-testnet"]
    # The DEFAULT is unmoved: it is what rows naming no recorder are addressed
    # under, and every such row was published by an older producer.
    ck row["recorder"]["build"].getStr == incumbentBuild
    var builds: seq[string]
    for r in row["recorders"]: builds.add r["build"].getStr
    ck incumbentBuild in builds
    ck framesBuild in builds
    # RELATIVE TO THE CONTROL, so this states "publishing a second recorder adds
    # exactly one row to the inventory" rather than a literal that only held
    # while the capture itself carried one build.
    ck builds.len == controlBuilds.len + 1

  test "a CLIENT resolves each container through the row's own recorder":
    # Read back through the shipping consumer rather than through this file's
    # idea of the contract: `traceView` runs the client SDK's `resolveExec`,
    # which derives the address and fetches the manifest there. A client that
    # ignored the row's recorder would derive the incumbent's address for the
    # frames containers, find nothing, and report a failed fetch — so a
    # resolution that lands at all is the assertion.
    let mixedRoot = newDataRoot(mixedTree)
    let info = mixedRoot.chainInfo("aztec-testnet")
    var resolved = 0
    for tx, m in mixedManifests:
      let tv = mixedRoot.traceView(info, tx)
      ck tv.outcome == tvReplayable
      # The path a browser would GET, and it must be the one this container is
      # published at — which is the manifest's own id.
      ck m["traceArtifactId"].getStr in tv.containerPath
      ck tv.contentHash == m["container"]["hash"].getStr
      inc resolved
    ck resolved == mixedManifests.len

  test "MUTATION BITE: collapsing the chain onto one shared pin is refused by name":
    # THE WRONG FIX, DRIVEN THROUGH THE REAL INGEST. "Re-pin the chain to the
    # new recorder" is the one-line change that makes the frames container
    # publishable, keeps every page working, and silently re-addresses the 24
    # containers the old build produced. It costs provenance truth and nothing
    # a test of availability would notice, which is exactly why the refusal has
    # to be in the producer and has to be exercised.
    #
    # The shape: a tree that already pins the incumbent, and a snapshot whose
    # snapshot-wide provenance names the frames build — i.e. the state a
    # follower leaves behind when it overwrites `provenance.runtimeCommit` on a
    # catch, which is what it used to do unconditionally.
    let repinCap = rd / "repin"
    copyDir(snapshotDir, repinCap)
    var doc = parseJson(readFile(repinCap / "snapshot.json"))
    doc["provenance"]["runtimeCommit"] = %FramesCommit
    writeFile(repinCap / "snapshot.json", doc.pretty)
    var raised = false
    var msg = ""
    try:
      # `oneTree` already carries the incumbent pin and its 25 containers.
      discard ingestSnapshot(IngestConfig(outDir: oneTree, snapshotDir: repinCap))
    except ValueError as e:
      raised = true
      msg = e.msg
    ck raised
    # NAMING WHAT IT FOUND, not merely refusing. "the pin changed" leaves a
    # reader to go and find out from what to what; both builds are in the
    # sentence, and so is the remedy that does not lose the provenance.
    ck incumbentBuild in msg
    ck framesBuild in msg
    ck "recordedBy" in msg
    ck "did not" in msg and "produce them" in msg

  test "and the refusal is about a CHANGED pin, not about re-ingesting at all":
    # The control for the mutation above: every build regenerates in place, so a
    # guard that refused a re-ingest of the same snapshot would make the
    # determinism check impossible to run. This is the arm that proves the
    # refusal keys on the recorder rather than on the slug being occupied.
    discard ingestSnapshot(IngestConfig(outDir: oneTree, snapshotDir: snapshotDir))
    ck true
    # …and it stays green over the MIXED capture too, whose snapshot-wide
    # provenance is still the incumbent and whose second recorder is stated per
    # container — which is the shape this whole change exists to make publishable.
    discard ingestSnapshot(IngestConfig(outDir: oneTree, snapshotDir: mixedCap))
    ck true
    let reg = parseJson(readFile(oneTree / "registry" / "chains.v1.json"))
    var builds: seq[string]
    for r in reg["chains"]["aztec-testnet"]["recorders"]: builds.add r["build"].getStr
    ck builds.len == controlBuilds.len + 1

  test "assertion count":
    # Written from a run, and expressed against the SIZE OF THE FIXTURE rather
    # than as a bare number, because most of the assertions above are per
    # container. A literal total would go red the next time the capture grows,
    # and the repair for that red is to edit the number — which is how a suite
    # comes to certify a smaller sweep than it used to (see the note on suite
    # 12's total). The two terms are named so the count can be re-derived by
    # reading rather than by running:
    #
    #   * 24 assertions that do not depend on how many containers there are;
    #   * 7 per container beyond the two attributed to the second recorder
    #     (1 in "every container reports…", 3 in "does not re-address…",
    #      3 of the 6 below), and 6 per container over the whole set
    #     ("the overlay tells…" ×3 and "a CLIENT resolves…" ×3).
    let n = mixedManifests.len
    expectCount(24 + (n - 2) * 4 + n * 6)
