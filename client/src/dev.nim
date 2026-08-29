## Live-reload dev server for the BlockTracer IsoNim client site.
##
## A thin config of the shared `isonim/server/static_dist_dev_server`: it runs the
## site's REAL static exporter (`src/static_export.nim`, the same command `just
## export` ships), serves the resulting `dist/` — the demo data plane with the
## rendered explorer views written over it — and live-reloads every open tab after
## each rebuild, so what you preview is byte-for-byte the deployed tree.
##
## Watches both `src` (the client: pages, components, viewmodels, SSR, exporter)
## and `../src` (the shared blocktracer contract + demo generator the exporter
## compiles in), so an edit to either half retriggers the export.
##
## Run from the `client/` directory (the Justfile `dev` recipe does the `cd`):
##   nim c -r --mm:orc --hints:off src/dev.nim [PORT] [HOST]
## isonim + nim-everywhere resolve from the sibling checkouts (nim.cfg) or from
## ISONIM_SRC / NIM_EVERYWHERE_SRC (config.nims); the design-system tokens resolve
## from a sibling checkout or DESIGN_SYSTEM_SRC.

import std/[os, strutils]
import isonim/server/static_dist_dev_server

when isMainModule:
  let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8080
  let host =
    if paramCount() >= 2: paramStr(2)
    elif existsEnv("AH_DEV_HOST"): getEnv("AH_DEV_HOST")
    else: "127.0.0.1"
  staticDistDevServer(
    rebuildCommand = @["nim", "c", "-r", "--mm:orc", "-d:isServer", "-d:release",
                       "--hints:off", "src/static_export.nim"],
    distDir = "dist",
    watchRoots = @["src", "../src"],
    siteName = "blocktracer",
    port = port,
    host = host)
