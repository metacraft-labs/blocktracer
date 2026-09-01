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

import std/[unittest, os, json, strutils, algorithm, options]

import ../src/ssr
import ../src/reader
import ../src/viewutil
import ../src/debugger/demo_session
import ../src/debugger/session_view
import ../src/components/provenance
import ../src/components/debugger as dbgc
import blocktracer/demo/generator
import blocktracer/chain/ingest

let
  clientRoot = currentSourcePath().parentDir.parentDir
  repoRoot = clientRoot.parentDir
  fixtureDir = repoRoot / "fixtures" / "trace" / "noir_space_ship"
  fixture = fixtureDir / "zk_shields.ct"
  fixtureSources = fixtureDir / "sources"
  chainFixtures = clientRoot / "fixtures" / "chain"
  snapshotDir = chainFixtures / "aztec-testnet"
  workDir = getTempDir() / ("blocktracer-chain-prov-" & $getCurrentProcessId())

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
    check "no debug symbols" in body

  test "and it still says WHERE the session is stopped, with no line to mark":
    # The defect this arm was added for. "A rung-3 recording never renders as
    # source" was enforced, correctly — and the consequence was that the Code
    # pane on EVERY real transaction this site publishes drew two paragraphs of
    # prose and no position mark of any kind. The one surface whose whole
    # question is "where is this execution stopped" answered it nowhere, on the
    # only transactions the chain actually has. A reader could see 208 steps in
    # the toolbar and nothing in the pane.
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
    # pane, above the sentence that explains why there is no text under it, and
    # the instruction-level prose is untouched.
    check debugBody.find("srcpos") < debugBody.find("srcnone")
    check "Stepping continues at instruction level." in debugBody
    # And no line is claimed. A rung-3 recording has no source position, so the
    # head must not have produced a listing by the back door.
    check "class=\"srcline" notin debugBody

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

  test "its banner states the zero rather than omitting it":
    var zero: IngestResult
    for r in ingests:
      if r.withTrace == 0: zero = r
    if zero.chain.len == 0: skip()
    else:
      let detail = chainInfo(root, zero.chain).provenanceDetail
      # WHICH SENTENCE IS CORRECT DEPENDS ON THE DATA, so the assertion reads the data
      # rather than pinning one arm. A chain with no traces has two distinct reasons for
      # it and they are opposite claims: nothing in the window was replayable (a fact
      # about the CHAIN), or something was and the replay refused (a fact about the
      # RECORDER). Asserting the first unconditionally is what made this test fail the
      # moment the follower caught two transactions and the runtime refused them — the
      # test was demanding the page keep saying the thing that had stopped being true.
      let snapZero = parseJson(readFile(
        chainFixtures / (if zero.chain == "aztec": "aztec" else: zero.chain) /
        "snapshot.json"))
      var refused = 0
      for t in snapZero["transactions"]:
        if t{"outcome"}.getStr == "refused": inc refused
      if refused > 0:
        check "WERE still replayable and were caught in time" in detail
        check "failure on the recording side" in detail
        check "NO TRANSACTION INSIDE IT WAS REPLAYABLE" notin detail
      else:
        check "NO TRANSACTION INSIDE IT WAS REPLAYABLE" in detail
        check "not a failure to record" in detail
        check "the most recent one settled in block " in detail
        check "follower" in detail
      # Measured facts, and NOT a bare average — which on a bursty chain is true and
      # predicts the wrong thing. Present in both arms.
      check "longest run with none was" in detail
      # A GROWN SNAPSHOT MUST NOT PUBLISH A NEGATIVE DISTANCE.
      #
      # The clause used to be an unguarded `replayableFrom - mostRecentTxBlock`, which
      # holds only while a snapshot is a single scan: the newest transaction is then at
      # or below the tip that scan read. `follow-chain.mjs` keeps extending the block
      # record, so the newest transaction can sit far ABOVE the window recorded at the
      # last catch — and the first watched mainnet snapshot published "settled in block
      # 67511 — -391 block(s) below the window" on the one element of the page whose
      # whole job is to be believed.
      #
      # This arm only ever sees one of the three shapes, so it is a REGRESSION witness
      # rather than the proof; suite 6 builds all three deliberately.
      check "- block(s)" notin detail

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

  test "the real banner names the endpoint, the moment and the window":
    let detail = chainInfo(root, RealChain).provenanceDetail
    check "aztec-testnet.drpc.org" in detail
    check "replay window" in detail
    # …and NOT as a fetchable URL: a scheme in prose is indistinguishable, to
    # the external-reference scanner, from an origin this page depends on.
    check "://" notin detail

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
                 "timestamp": 1000 + n, "totalManaUsed": "0x0",
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

  test "the newest transaction BELOW the window reads as a distance":
    # The positive twin. Without it, "no negative number appears" would be satisfied by a
    # clause that had stopped printing a number at all.
    let d = detailOf(snapshotWith(wd, tip = 200, finalized = 180, txBlock = 150,
                                  firstCapturedAt = ""))
    ck "the most recent one settled in block 150" in d
    ck "31 block(s) below that window" in d      # replayableFrom 181 - 150
    ck "already been pruned" in d

  test "the newest transaction ABOVE the window does NOT print a negative distance":
    # The arm the committed fixture never reaches, and the one the defect lived in.
    let d = detailOf(snapshotWith(wd, tip = 200, finalized = 180, txBlock = 199,
                                  firstCapturedAt = ""))
    ck "the most recent one settled in block 199" in d
    ck "at or above the last window recorded here" in d
    ck "block(s) below" notin d                  # no distance is claimed at all
    ck "-" & $18 notin d                         # and specifically not "-18"
    # MUTATION BITE: the pre-fix expression over the same inputs. Asserted to produce
    # exactly the sentence that shipped, so the guard above is shown to be load-bearing
    # rather than merely present.
    ck $(181 - 199) == "-18"

  test "a watched snapshot names both ends of the watch":
    let d = detailOf(snapshotWith(wd, tip = 200, finalized = 180, txBlock = 150,
                                  firstCapturedAt = "2026-08-31T07:39:12.420Z"))
    ck "over a watch that began 2026-08-31T07:39:12.420Z" in d
    ck "was last extended 2026-08-31T16:51:38.480Z" in d
    ck "when it was last looked at" in d
    ck "at that moment" notin d                  # the one-shot phrasing is NOT used

  test "a one-shot snapshot keeps the single-moment phrasing, byte for byte":
    # The negative above ("at that moment" is absent) is only meaningful beside a case
    # where it is present — otherwise a build that deleted the phrase entirely would pass.
    let d = detailOf(snapshotWith(wd, tip = 200, finalized = 180, txBlock = 150,
                                  firstCapturedAt = ""))
    ck "at 2026-08-31T16:51:38.480Z" in d
    ck "blocks) at that moment. " in d
    ck "over a watch that began" notin d

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
                  "timestamp": 1199, "totalManaUsed": "0x2710",
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

  test "a refusal is NOT reported as 'no transaction was replayable'":
    # The defect this arm exists for. Two mainnet transactions were caught INSIDE the
    # window with their bodies still served and refused by the replay runtime, and the
    # page said "NO TRANSACTION INSIDE IT WAS REPLAYABLE ... not a failure to record".
    # That blames the chain for a fault on the recording side and tells the reader the
    # opposite of what happened: the follower reached them in time.
    let d = detailOf(refusedSnapshot(wd))
    ck "WERE still replayable and were caught in time" in d
    ck "AvmToolchainRegression" in d
    ck "failure on the recording side" in d
    # The negative that matters, and it has a positive twin two tests below.
    ck "NO TRANSACTION INSIDE IT WAS REPLAYABLE" notin d
    ck "not a failure to record" notin d

  test "twin: a purely pruned window DOES still say nothing was replayable":
    # Without this, the two negatives above would be satisfied by an ingest that had
    # stopped emitting the zero arm at all.
    let d = detailOf(snapshotWith(wd, tip = 200, finalized = 180, txBlock = 150,
                                  firstCapturedAt = ""))
    ck "NO TRANSACTION INSIDE IT WAS REPLAYABLE" in d
    ck "not a failure to record" in d
    ck "WERE still replayable" notin d

  test "assertion count":
    expectCount(23)   # 3 + 5 + 4 + 3 + 5 + 3

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
                  "timestamp": 1199, "totalManaUsed": "0x2710",
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
                 "timestamp": 1000 + n, "totalManaUsed": "0x0",
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
    # A FLOOR, from the fixture that does not move: the committed testnet
    # capture publishes six. A tree that stopped publishing transactions cannot
    # pass this test by having nothing to check.
    ck checked >= 6
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
    ck curated == 2

  test "the banner states the window and the watch it was chosen out of":
    let info = chainInfo(curatedRoot, RealChain)
    let d = info.provenanceDetail
    ck "CURATED WINDOW" in d
    ck "blocks 63642–63675" in d
    ck "Over the whole watch — 220 blocks, 32 transaction(s)" in d
    # The uncurated phrasing is NOT reused, because it describes the enumerated
    # range and the enumerated range is no longer what the page shows.
    ck "blocks enumerated here this chain settled" notin d
    # ONE CLAUSE PER OUTCOME. This capture holds 25 pruned and one that the
    # capture declined to attempt, and the two are different sentences: the
    # first is the network's retention horizon, the second is a choice this
    # side of the wire made. A remainder clause would have said "pruned" of
    # both — the same merge `b7cafba` had to undo on the uncurated banner.
    ck "25 had already been pruned" in d
    ck "1 carried another outcome (not-attempted)" in d

  test "a REFUSAL in the unpublished remainder is never called a pruning":
    # The arm the testnet capture cannot reach and the mainnet one can. Built
    # from a constructed snapshot so it is graded whichever capture is
    # committed: a refused transaction was reached in time with its body still
    # served, and saying it was pruned blames the chain for our own fault.
    let rd = getTempDir() / ("bt-curated-refusal-" & $getCurrentProcessId())
    removeDir(rd); createDir(rd)
    let tree = rd / "tree"
    createDir(tree)
    discard ingestSnapshot(IngestConfig(outDir: tree,
                                        snapshotDir: mixedSnapshot(rd),
                                        scope: isCurated))
    let d = chainInfo(newDataRoot(tree), "mixed").provenanceDetail
    ck "1 WERE still replayable when the capture reached it" in d
    ck "AvmToolchainRegression" in d
    ck "failure on the recording side and not a property of this chain" in d
    ck "1 had already been pruned" in d
    # The twin negative: the pruned clause is present, so the refusal clause
    # being present is not just "the sentence mentions everything".
    ck "2 had already been pruned" notin d

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
                 "timestamp": 1000 + n, "totalManaUsed": "0x0",
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
    ck "CURATED WINDOW" in body
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
    expectCount(69)

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
    ck "stopped mid-execution at step" in home

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
    ck "no function names or source positions" in body
    ck "carries no variable names" in body
    # …and NOT on the home page.
    let home = renderRoute(root, "/").body
    ck "carries no variable names" notin markup(home)
    ck "no function names or source positions" notin markup(home)

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
    ck "stopped mid-execution at step" notin markup(home)
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
    expectCount(47)

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
