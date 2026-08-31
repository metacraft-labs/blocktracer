## Static site generator for the BlockTracer IsoNim client.
##
## One command produces a servable `dist/` that combines the demo DATA plane and
## the rendered CLIENT:
##
##   1. Wire the demo generator (blocktracer-demo-gen) straight into dist: call
##      `generate` in-process so the `/d`, `/idx`, `/t`, `/registry` object tree
##      and the pre-rendered per-entity entry pages land under dist/. This is the
##      exact tree the real pipeline will emit (the M5b contract) — the client
##      never learns which producer wrote it.
##   2. Render the explorer views (home, chain overview, block list, block
##      detail, transaction detail) from that same tree via the isonim SSR
##      string renderer + the codetracer-design-system token layer, and write
##      them at their clean URLs — OVERWRITING the generator's minimal entry
##      pages with the full client render (the M5/M9 render, not §4.3's minimal
##      per-entity page).
##   3. Copy the vendored brand fonts and emit sitemap.xml + robots.txt.
##
## Usage:
##   nim c -r --mm:orc -d:isServer -d:release src/static_export.nim
##   # or via the Justfile:  just export

import std/[os, strutils, times, algorithm]
import blocktracer/demo/generator
import blocktracer/chain/ingest
import ssr
import reader
import debugger/replay_engine

const
  OutputDir = "dist"
  DefaultSeed = "blocktracer-demo-0"

proc repoRoot(): string =
  ## <repo>/client/src/static_export.nim → <repo>.
  currentSourcePath().parentDir.parentDir.parentDir

proc ensureDir(path: string) =
  if not dirExists(path): createDir(path)

proc writeCleanUrl(path, html: string) =
  ## dist/path/index.html (clean URLs); "/" → dist/index.html.
  let outputPath = if path == "/": OutputDir / "index.html"
                   else: OutputDir / path.strip(chars = {'/'}) / "index.html"
  ensureDir(parentDir(outputPath))
  writeFile(outputPath, html)

proc copyFonts() =
  let src = repoRoot() / "client" / "src" / "assets" / "fonts"
  if dirExists(src):
    let dest = OutputDir / "assets" / "fonts"
    ensureDir(OutputDir / "assets")
    ensureDir(dest)
    for kind, path in walkDir(src):
      if kind == pcFile:
        copyFile(path, dest / extractFilename(path))

proc installHydrationBundle() =
  ## Put the built hydration bundle where the pages say it is — or fail.
  ##
  ## `HydrationBundle` is a build-time URL (`replay_engine.nim`) and its
  ## default is empty, which is a build that ships no script and produces the
  ## page this route has always produced. That case does nothing here, and it
  ## must not warn: it is the ordinary shape of a build without the CodeTracer
  ## Embed SDK on its Nim path.
  ##
  ## When it is NOT empty, the page carries a `<script src=…>`, and a `<script>`
  ## pointing at a 404 is the one outcome this must never produce quietly. It is
  ## not merely a dead script tag — it is the page CLAIMING to hydrate while its
  ## controls sit inert forever, saying they are waiting for an engine nothing
  ## will ever ask for. That is the affordance-that-lies defect with a build
  ## error's cause, so it is made a build error: `quit 2`, at the point where a
  ## missing file is still cheap to notice.
  if HydrationBundle.len == 0: return
  let built = repoRoot() / "client" / "hydrate" / "hydrate.js"
  if not fileExists(built):
    stderr.writeLine "hydration bundle not built: " & built
    stderr.writeLine "  This build declares -d:hydrationBundle=" & HydrationBundle &
                     ", so every debug page carries a <script> for it."
    stderr.writeLine "  Build it first (cd client && just hydrate) or drop the define."
    quit 2
  let dest = OutputDir / HydrationBundle.strip(chars = {'/'})
  ensureDir(parentDir(dest))
  copyFile(built, dest)
  echo "  + hydration bundle: " & HydrationBundle & " (" &
    $(getFileSize(built) div 1024) & " KB)"

proc generateSitemap(routes: seq[string]) =
  var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
  xml.add "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n"
  for route in routes:
    xml.add "  <url><loc>" & SiteDomain & route & "</loc></url>\n"
  xml.add "</urlset>\n"
  writeFile(OutputDir / "sitemap.xml", xml)

proc generateRobots() =
  writeFile(OutputDir / "robots.txt",
    "User-agent: *\nAllow: /\nSitemap: " & SiteDomain & "/sitemap.xml\n")

proc exportSite() =
  let startTime = epochTime()

  # Fresh output tree.
  if dirExists(OutputDir): removeDir(OutputDir)
  ensureDir(OutputDir)

  # Step 1: ingest every captured live-chain snapshot. Two producers, one tree, one
  # contract — everything below (route enumeration, reader, the five §7.0 views, the
  # validator) is shared, because a second chain is data rather than a second explorer.
  #
  # THE REAL CHAINS GO FIRST, AND THE ORDER IS THE POINT. They used to go second, behind
  # the demo, which was harmless while the demo owned a slug of its own. It is not
  # harmless now that the Aztec mainnet IS `/aztec`: whoever writes second is the one
  # able to overwrite, so the producer that must never overwrite a real chain is the one
  # that has to run last and check. The real chains are the site's subject; the fixture
  # is a guest.
  #
  # ITS ABSENCE IS A VALID BUILD, and deliberately so: a checkout without a
  # capture serves exactly the synthetic demo it always did. What must never
  # happen is the opposite — a snapshot present and silently half-ingested — so
  # `ingestSnapshot` raises rather than skipping a transaction it cannot publish.
  # EVERY capture in the tree, in a stable order. A second real chain is a
  # directory, not a code change — which is the whole claim the two-producer
  # split makes, and this loop is where it is either true or it is not.
  let chainFixtures = repoRoot() / "client" / "fixtures" / "chain"
  var snapshotDirs: seq[string]
  if dirExists(chainFixtures):
    for kind, path in walkDir(chainFixtures):
      if kind == pcDir and fileExists(path / "snapshot.json"):
        snapshotDirs.add path
  sort(snapshotDirs)
  if snapshotDirs.len == 0:
    echo "  + live-chain snapshots: none in this checkout (synthetic demo only)"
  for snapshotDir in snapshotDirs:
    let ing = ingestSnapshot(IngestConfig(outDir: OutputDir,
                                          snapshotDir: snapshotDir))
    # A chain with NO traces is reported as such rather than omitted. It is the
    # expected outcome on a chain whose transactions arrive further apart than
    # the replay window is wide, and a build log that quietly said nothing about
    # it would be the first place the fact went missing.
    let traceNote =
      if ing.withTrace == 0: "NO replayable transaction in the window"
      else: $ing.withTrace & " with a published trace (" & $ing.divergent &
            " divergent, " & $ing.containerBytes & " bytes)"
    echo "  + live-chain snapshot: /" & ing.chain & " — " & $ing.blocks &
      " blocks, " & $ing.transactions & " transactions, " & traceNote & ", " &
      $ing.pruned & " past the replay horizon"

  # Step 1b: the SYNTHETIC demo tree — off by default, and that default is the change.
  #
  # The published site carries real chains only. The demo chain is a fixture: it is the
  # subject of most of the visual-review corpus and of the exporter-driven suites, and
  # those are reasons to keep GENERATING it, not reasons to SERVE it. Publishing and
  # testing are separated here rather than argued about elsewhere — `-d:publishDemoChain`
  # turns it on for the capture harness and for the two tests that render over it, and
  # nothing turns it on for a deploy.
  #
  # The trace fixture is still required when it IS enabled: the real `noir_space_ship`
  # container carries no source text, so without the Noir sources the exported site would
  # step through code it cannot show.
  when defined(publishDemoChain):
    let fixtureDir = repoRoot() / "fixtures" / "trace" / "noir_space_ship"
    let fixture = fixtureDir / "zk_shields.ct"
    let sources = fixtureDir / "sources"
    if not fileExists(fixture):
      stderr.writeLine "trace fixture not found: " & fixture
      quit 2
    if not dirExists(sources):
      stderr.writeLine "trace sources not found: " & sources
      quit 2
    # The guard, at the composition root — the one place both producers meet. It refuses
    # rather than trusting the slugs not to have collided, which is what the rule it
    # replaced did in the other direction.
    assertSlugAvailable(OutputDir, DemoChainSlug, "synthetic")
    let n = generate(DemoConfig(outDir: OutputDir, seed: DefaultSeed,
                                chain: DemoChainSlug,
                                traceFixturePath: fixture,
                                traceSourcesDir: sources))
    echo "  + synthetic demo chain: /" & DemoChainSlug & " (" & $n & " transactions) " &
      "— NOT PUBLISHED on a deploy; this build set -d:publishDemoChain"
  else:
    echo "  + synthetic demo chain: not published (build -d:publishDemoChain to include it)"

  # Step 2: render the explorer views over that tree, at clean URLs.
  let root = newDataRoot(OutputDir)
  let routes = staticRoutes(root)
  var rendered = 0
  for route in routes:
    let (status, body, _) = renderRoute(root, route)
    if status == 200:
      writeCleanUrl(route, body)
      inc rendered
    else:
      echo "  ! " & route & " (status " & $status & ")"
  echo "  + client views: " & $rendered &
    " pages (home, chains, chain, blocks, block, txs, tx, debug, address, code, search, settings, about)"

  # The not-found body, at the file a static host serves for an unmatched path.
  #
  # SEO-And-Crawl-Budget.md §6 class G0: "Real `404`, never a successful
  # generic shell", and "unknown paths must produce genuine `404` responses
  # rather than mapping every path to `index.html`". The BYTES are the same
  # ones `renderRoute` returns with a 404 status, taken from `renderRoute`
  # itself rather than re-rendered here: a 404 file that differs from the 404
  # body is two answers to one question, and only one of them would be tested.
  let (notFoundStatus, notFoundBody, _) = renderRoute(root, "/__not_found__")
  doAssert notFoundStatus == 404, "renderRoute stopped 404ing an unknown path"
  writeFile(OutputDir / "404.html", notFoundBody)
  echo "  + 404.html (Page-Descriptions §14 'not on this chain')"

  # Step 3: assets + crawl files.
  copyFonts()
  installHydrationBundle()
  # `sitemapRoutes`, not `routes`: every route is RENDERED, and a `noindex`
  # route is not SUBMITTED (SEO-And-Crawl-Budget.md §5). The debug route is the
  # transaction's content at a second address, so a sitemap entry for it would
  # invite a crawler to fetch a duplicate and be told not to index it.
  generateSitemap(sitemapRoutes(root))
  generateRobots()

  let elapsed = epochTime() - startTime
  echo "\nExported " & $rendered & " client pages over the demo data tree in " &
    formatFloat(elapsed, ffDecimal, 2) & "s -> " & OutputDir & "/"

when isMainModule:
  echo "Building BlockTracer static site -> " & OutputDir & "/"
  exportSite()
