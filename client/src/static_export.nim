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

import std/[os, strutils, times]
import blocktracer/demo/generator
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

  # Step 1: emit the demo data plane + entry pages into dist/.
  # The REAL `noir_space_ship` trace, plus the Noir sources published as
  # content-addressed source bundles. The container carries no source text, so
  # without the sources the exported site would step through code it cannot show.
  let fixtureDir = repoRoot() / "fixtures" / "trace" / "noir_space_ship"
  let fixture = fixtureDir / "zk_shields.ct"
  let sources = fixtureDir / "sources"
  if not fileExists(fixture):
    stderr.writeLine "trace fixture not found: " & fixture
    quit 2
  if not dirExists(sources):
    stderr.writeLine "trace sources not found: " & sources
    quit 2
  let n = generate(DemoConfig(outDir: OutputDir, seed: DefaultSeed,
                              traceFixturePath: fixture,
                              traceSourcesDir: sources))
  echo "  + data plane: /d /idx /t /registry + entry pages (" & $n & " transactions)"

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
