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
  let fixture = repoRoot() / "fixtures" / "trace" / "minimal_trace.ct"
  if not fileExists(fixture):
    stderr.writeLine "trace fixture not found: " & fixture
    quit 2
  let n = generate(DemoConfig(outDir: OutputDir, seed: DefaultSeed,
                              traceFixturePath: fixture))
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
  echo "  + client views: " & $rendered & " pages (home, chain, block list, block, tx)"

  # Step 3: assets + crawl files.
  copyFonts()
  generateSitemap(routes)
  generateRobots()

  let elapsed = epochTime() - startTime
  echo "\nExported " & $rendered & " client pages over the demo data tree in " &
    formatFloat(elapsed, ffDecimal, 2) & "s -> " & OutputDir & "/"

when isMainModule:
  echo "Building BlockTracer static site -> " & OutputDir & "/"
  exportSite()
