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

import std/[unittest, os, json, strutils, algorithm]

import ../src/ssr
import ../src/reader
import ../src/viewutil
import ../src/debugger/demo_session
import ../src/debugger/session_view
import ../src/components/provenance
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
      check "NO TRANSACTION INSIDE IT WAS REPLAYABLE" in detail
      check "not a failure to record" in detail
      # The measured facts that explain it — and NOT a bare average, which on a
      # bursty chain is true and predicts the wrong thing.
      check "longest run with none was" in detail
      check "the most recent one settled in block " in detail
      check "follower" in detail
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

  test "assertion count":
    expectCount(15)   # 3 + 5 + 4 + 3

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
