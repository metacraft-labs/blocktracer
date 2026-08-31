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

import std/[unittest, os, json, strutils]

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
  snapshotDir = clientRoot / "fixtures" / "chain" / "aztec-testnet"
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
let ing = ingestSnapshot(IngestConfig(outDir: workDir, snapshotDir: snapshotDir))
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
  DemoChain = "aztec"
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
    let mutated = demoSession(RealChain, v, sourceLevel = true)
    let honest = demoSession(RealChain, v, sourceLevel = false)
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

suite "3 — real and synthetic are tellable apart, on the page":
  test "each chain publishes its own provenance, and they differ":
    let realInfo = chainInfo(root, RealChain)
    let demoInfo = chainInfo(root, DemoChain)
    check realInfo.provenanceKind == "live-capture"
    check demoInfo.provenanceKind == "synthetic"
    check realInfo.provenanceLabel != demoInfo.provenanceLabel
    check provenanceTone(realInfo.provenanceKind) !=
          provenanceTone(demoInfo.provenanceKind)

  test "the banner is on the transaction page of BOTH chains":
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
    # are on: no nav, no footer, the viewport is an execution.
    let d = realDebugBody()
    check "data-register=\"debugger\"" in d
    check "data-provenance=\"live-capture\"" in d
    check "Real Aztec testnet data" in d

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

  test "MUTATION BITE: a chain with no published provenance gets no banner":
    # The banner must come from the tree. A component that defaulted to
    # "synthetic" would label an unmarked chain with a claim its producer
    # never made.
    var blank: ChainInfo
    check provenanceBanner(blank) == ""
    blank.provenanceKind = "live-capture"
    check provenanceBanner(blank) == ""      # no label either => still nothing
    blank.provenanceLabel = "Real Aztec testnet data"
    check provenanceBanner(blank).len > 0

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
