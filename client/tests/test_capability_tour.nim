## The capability tour — that every entry is a real recording of its own program.
##
## ## What this suite exists to prevent
##
## The demo chain used to serve ONE recording behind every transaction. That was
## defensible while it was a fixture for tests and captures to render, and it
## became indefensible the moment the chain was asked to answer "what can this
## debugger show me?" — the answer was the same program, ten times.
##
## The tour replaces it with eight programs, each with its own container. Every
## way that can go quietly wrong is a case below:
##
##   1. **Two programs on one screen.** The Code pane reads a published bundle
##      and the replay panes are fixture data describing `zk_shields`. Before
##      `withPublishedSources` learned to check, a tour transaction rendered
##      `triangular` and `collatz` in the source pane while the Call Trace beside
##      it named `iterate_asteroids` and the Values pane showed
##      `remaining_shield`. Two programs, presented as one session.
##
##   2. **One container behind eight transactions.** `writeArtifact` used to read
##      `cfg.traceFixturePath` unconditionally. A tour that published eight
##      manifests over the same bytes would look exactly like a working one from
##      every page, and differ only in the thing it exists for.
##
##   3. **A manifest describing some other recording.** The step and frame counts
##      are published per transaction. Numbers belonging to a different container
##      than the one beside them is the class of defect no page can show.
##
##   4. **An entry that does not open.** A tour entry whose debug route cannot
##      resolve a source line is worse than no entry: it is the product
##      demonstrating that it does not work.
##
## ## The expectations are NOT read out of the recording
##
## `fixtures/trace/tour/manifest.json` states what each program does in prose
## derived from its SOURCE — "`triangular(6)` sums 0..5, so `acc` takes the
## sequence 0, 0, 1, 3, 6, 10, 15". This suite checks the STRUCTURE of that
## claim (every program has one, it is non-empty, it names the program's own
## identifiers) and the numbers the tree publishes against the containers on
## disk. It deliberately does not re-derive the prose: a test that computed the
## expected value the same way the fixture did would agree with itself.

import std/[unittest, os, json, strutils, algorithm, sets]

import ../src/ssr
import ../src/reader
import blocktracer/demo/generator

let
  clientRoot = currentSourcePath().parentDir.parentDir
  repoRoot = clientRoot.parentDir
  fixtureDir = repoRoot / "fixtures" / "trace" / "noir_space_ship"
  fixture = fixtureDir / "zk_shields.ct"
  fixtureSources = fixtureDir / "sources"
  tourDir = repoRoot / "fixtures" / "trace" / "tour"
  workDir = getTempDir() / ("blocktracer-tour-" & $getCurrentProcessId())

doAssert fileExists(tourDir / "manifest.json"),
  "no tour manifest at " & tourDir & " — every assertion below would pass " &
  "vacuously, so this is a refusal rather than a skip"

removeDir(workDir)
createDir(workDir)
discard generate(DemoConfig(outDir: workDir, seed: "tour-test",
                            traceFixturePath: fixture,
                            traceSourcesDir: fixtureSources,
                            tourDir: tourDir))
let root = newDataRoot(workDir)
let info = chainInfo(root, DemoChainSlug)
let programs = readTour(tourDir)
let rows = tour(root, info)

## Strings that exist ONLY in the vendored `zk_shields` fixture. If one of them
## reaches a tour page, that page is showing another program's execution — case
## 1 above. Taken from `test_chain_provenance`'s list, which exists for the same
## reason on the other side of the same seam.
const FixtureOnly = ["iterate_asteroids", "calculate_damage",
                     "calculate_shield_regeneration",
                     "calculate_remaining_shield_pct", "remaining_shield",
                     "shield.nr", "zk_shields", "status_report"]

proc renderedBody(html: string): string =
  ## The page with its stylesheet removed. The design system's CSS carries long
  ## prose comments that discuss the fixture by name — legitimately, they are
  ## about the fixture — and a substring search over the whole document would
  ## report every one of them as leakage.
  let i = html.find("</style>")
  if i < 0: html else: html[i .. ^1]

suite "1 — the corpus is real, and each program is its own":

  test "CONTROL: the tour has programs, and the tree publishes one row each":
    check programs.len >= 6
    check rows.len == programs.len
    var manifestIds, publishedIds: seq[string]
    for p in programs: manifestIds.add p.id
    for r in rows: publishedIds.add r.id
    check manifestIds == publishedIds

  test "every program names a container and a sources tree that exist":
    for p in programs:
      check fileExists(p.containerPath)
      check fileExists(p.sourcesDir / "Nargo.toml")
      check fileExists(p.sourcesDir / "src" / "main.nr")
      # A container of a few hundred bytes is a container that failed to
      # record. The streams cost ~16 KiB before any payload.
      check getFileSize(p.containerPath) > 16_000

  test "every container is DISTINCT — the defect this whole change removes":
    var seen = initHashSet[string]()
    for p in programs:
      let bytes = readFile(p.containerPath)
      check not seen.contains(bytes)
      seen.incl bytes
    check seen.len == programs.len

  test "MUTATION BITE: the pre-change generator would fail the case above":
    # What the generator did before: one fixture, copied into every artifact.
    # The set collapses to one element, and the check above is what says so.
    var seen = initHashSet[string]()
    for _ in programs: seen.incl readFile(fixture)
    check seen.len == 1

  test "every program states what its recording must contain":
    let m = parseJson(readFile(tourDir / "manifest.json"))
    for prog in m["programs"]:
      let id = prog["id"].getStr
      checkpoint id
      check prog.hasKey("expectations")
      check prog["expectations"].len >= 3
      for e in prog["expectations"]:
        # A claim short enough to be a label is not a claim.
        check e.getStr.len > 40
      check prog["capabilities"].len >= 1
      check prog["summary"].getStr.len > 40

suite "2 — what the tree publishes agrees with the container beside it":

  test "each tour transaction publishes ITS program's container, byte for byte":
    for i, p in programs:
      checkpoint p.id
      let t = traceView(root, info, rows[i].tx)
      check t.containerPath.len > 0
      let published = workDir / t.containerPath
      check fileExists(published)
      check readFile(published) == readFile(p.containerPath)

  test "no two tour transactions resolve to the same artifact":
    var paths = initHashSet[string]()
    for r in rows:
      let t = traceView(root, info, r.tx)
      check not paths.contains(t.containerPath)
      paths.incl t.containerPath

  test "the published step and frame counts are the manifest corpus's own":
    for i, p in programs:
      checkpoint p.id
      let t = traceView(root, info, rows[i].tx)
      check t.steps == p.steps
      check t.frames == p.frames
      # And they are not the fixture's, which is the number they would be if
      # `writeArtifact` had gone on reading the module-level constants.
      check t.steps != 1315

  test "each tour transaction publishes ITS program's source bundle":
    for i, p in programs:
      checkpoint p.id
      let t = traceView(root, info, rows[i].tx)
      let bundle = t.sourceBundle
      check not bundle.isNil
      check bundle.hasKey("sources")
      let mainSrc = readFile(p.sourcesDir / "src" / "main.nr")
      var found = false
      for path, node in bundle["sources"].pairs:
        if path.endsWith("main.nr") and node{"content"}.getStr == mainSrc:
          found = true
      check found

  test "the tour index is published as DATA, and its links resolve":
    check fileExists(workDir / "d" / DemoChainSlug / "g" / info.generation /
                     "tour.json")
    for r in rows:
      check r.tx.len > 0
      check hasTx(root, DemoChainSlug, r.tx)
      check r.title.len > 0
      check r.summary.len > 0

  test "a chain with no tour publishes none, and reports none":
    let bare = getTempDir() / ("blocktracer-tour-none-" & $getCurrentProcessId())
    removeDir(bare); createDir(bare)
    discard generate(DemoConfig(outDir: bare, seed: "tour-test",
                                traceFixturePath: fixture,
                                traceSourcesDir: fixtureSources))
    let bareRoot = newDataRoot(bare)
    let bareInfo = chainInfo(bareRoot, DemoChainSlug)
    check not fileExists(bare / "d" / DemoChainSlug / "g" /
                         bareInfo.generation / "tour.json")
    check tour(bareRoot, bareInfo).len == 0
    # And the M5c tree is exactly what it always was: three blocks, ten
    # transactions. The tour ADDS; it does not rewrite.
    check bareInfo.blockCount == 3
    check bareInfo.txCount == 10
    removeDir(bare)

suite "3 — a tour entry opens, on its own program":

  test "every tour transaction's debug route renders that program's source":
    for i, p in programs:
      checkpoint p.id
      let body = renderedBody(renderDebug(root, DemoChainSlug, rows[i].tx))
      # The package's own name is in its `Nargo.toml`, which the bundle carries.
      check body.contains(p.package)
      # And a line of its actual source. `main.nr`'s first `fn` is the cheapest
      # identifier that cannot come from anywhere else.
      let src = readFile(p.sourcesDir / "src" / "main.nr")
      var fnName = ""
      for line in src.splitLines:
        let s = line.strip
        if s.startsWith("unconstrained fn ") or s.startsWith("fn "):
          let after = s.split("fn ")[1]
          fnName = after.split('(')[0].split('<')[0].strip
          break
      check fnName.len > 0
      checkpoint fnName
      check body.contains(fnName)

  test "and NO tour page carries a string from the zk_shields fixture":
    for i, p in programs:
      checkpoint p.id
      let body = renderedBody(renderDebug(root, DemoChainSlug, rows[i].tx))
      for s in FixtureOnly:
        checkpoint s
        check not body.contains(s)

  test "a tour page states that the recorded detail needs the engine":
    # The static frame cannot position itself inside a recording it has not
    # read. What it may NOT do is borrow another program's position — so the
    # three replay panes say so, and the controls report no position.
    let body = renderedBody(renderDebug(root, DemoChainSlug, rows[0].tx))
    check body.contains("replay engine, which this page has not started")
    check body.contains("No position yet")

  test "CONTROL: exactly the six M5c sessions still carry the fixture":
    # The seam keys on the bundle's contents, so it must not have swept the
    # fixture's own transactions along with the tour's. Every published M5c
    # session is unchanged, which is also why every capture over one still
    # resolves — and the count is exact, so a seam that had taken one away or
    # left one behind fails here rather than in a screenshot.
    var fixtureSessions: seq[int]
    var tourHashes: seq[string]
    for r in rows: tourHashes.add r.tx
    for b in blocks(root, info):
      for h in readBlockDetail(root, info, b.hash).transactions:
        let body = renderedBody(renderDebug(root, DemoChainSlug, h))
        if body.contains("iterate_asteroids"):
          checkpoint h
          # Never a tour transaction: that is the defect, stated as a check.
          check h notin tourHashes
          fixtureSessions.add b.height
    check fixtureSessions.len == 6
    # And they are where they always were — blocks 100, 101 and 102.
    for height in fixtureSessions: check height != TourBlockHeight

  test "the tour's block is the OLDEST, so no newest-first selector moves":
    # `tools/capture/lib/entities.mjs` walks newest block first and pins every
    # debugger view by what the trace IS. A tour block above 102 would take
    # `readyTx` from the transaction six months of review is recorded against.
    var heights: seq[int]
    for b in blocks(root, info): heights.add b.height
    heights.sort()
    check heights[0] == TourBlockHeight
    check TourBlockHeight < 100

  test "the chain overview offers the tour, by capability, above the tables":
    let page = renderedBody(renderChain(root, DemoChainSlug))
    check page.contains("What this debugger can show")
    for r in rows:
      check page.contains(r.title)
      check page.contains("/" & DemoChainSlug & "/tx/" & r.tx & "/debug")
      for c in r.capabilities:
        check page.contains(c)
    # Above the tables, which is the ordering argument in `pages/chain.nim`.
    check page.find("What this debugger can show") < page.find("Latest blocks")

  test "and a real chain's overview offers no tour at all":
    for slug in chains(root):
      if slug == DemoChainSlug: continue
      let page = renderedBody(renderChain(root, slug))
      check not page.contains("What this debugger can show")

suite "4 — the tour stays unmistakably a demo":

  test "the chain still declares itself synthetic, unchanged by the tour":
    check info.provenanceKind == "synthetic"
    check info.provenanceLabel == "Synthetic demo data"
    check info.provenanceDetail.len > 0

  test "and every tour page carries that declaration":
    for r in rows:
      checkpoint r.id
      let page = renderDebug(root, DemoChainSlug, r.tx)
      check page.contains("Synthetic demo data")

  test "the tour's own words never claim the TRANSACTION is real":
    # The programs and their recordings are real; the transactions they are
    # published under are not, like every other transaction on this chain. The
    # page has to say which is which, because a visitor who reads "real
    # recording" beside a hash may reasonably conclude the hash is real too.
    let page = renderedBody(renderChain(root, DemoChainSlug))
    check page.contains("synthetic, like every other transaction on this chain")

removeDir(workDir)
