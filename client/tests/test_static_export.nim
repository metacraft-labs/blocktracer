## Static-export round-trip test for the BlockTracer IsoNim client (M5 skeleton).
##
## Modeled on codetracer-web-site / reprobuild-web-site: a genuine round-trip
## that compiles and runs the real exporter (src/static_export.nim) into a
## throwaway working dir, then asserts on the dist/ it produced.
##
## The point of THIS test is to prove the three M5 view types render for the demo
## entities and that they reference REAL demo data — not stubs. To make it bite,
## the ground truth is read INDEPENDENTLY from the `/d/**` JSON with std/json
## (never via the client's own reader), and the rendered HTML is asserted to
## carry those exact values. A stubbed or empty render, or a reader that dropped
## a field, fails here.
##
## What it proves:
##   1. The exporter emits a COMBINED tree: the demo data plane (/d /idx /t
##      /registry) AND the rendered client views over it.
##   2. Block-list view: every real block hash is linked.
##   3. Block-detail view: the block's real parent hash and its real transaction
##      hashes are present (and it is the CLIENT render, not the generator's
##      minimal entry page).
##   4. Transaction-detail view: the Aztec private/public split renders honestly
##      — the real `absent` reason string from the overlay, the real outcome, and
##      the real payload target all appear.
##   5. The design-system token layer resolved into the emitted CSS (the
##      "consume the design system" gate), and pages reference it via var(--ct-*).

import std/[unittest, os, json, strutils, osproc]

import ../src/ssr
import ../src/reader
import ../src/design_system/tokens

const
  Chain = "aztec"
  BrandIndigo600 = "#4f46e5"  # colors.brand.600 → colors.indigo.600 in the pinned DS

proc shard(hash: string): string =
  let h = if hash.startsWith("0x"): hash[2 .. ^1] else: hash
  if h.len >= 4: h[0 .. 3] else: h

# ── Perform a real static-export round-trip ────────────────────────────────
let
  repoRoot = currentSourcePath().parentDir.parentDir       # <repo>/client
  exporterSrc = repoRoot / "src" / "static_export.nim"
  workDir = getTempDir() / ("blocktracer-client-export-test-" & $getCurrentProcessId())

removeDir(workDir)
createDir(workDir)

let exporterBin = workDir / "static_export_bin"
let compileCmd =
  "nim c --mm:orc -d:isServer -d:release --hints:off --nimcache:" &
  quoteShell(workDir / "nimcache") & " -o:" & quoteShell(exporterBin) &
  " " & quoteShell(exporterSrc)
let (compileOut, compileCode) = execCmdEx(compileCmd)
doAssert compileCode == 0, "exporter failed to compile:\n" & compileOut

let (runOut, runCode) = execCmdEx(quoteShell(exporterBin), workingDir = workDir)
doAssert runCode == 0, "exporter failed to run:\n" & runOut

let dist = workDir / "dist"

# ── Independent ground truth from the /d tree (std/json only) ───────────────
let cur = parseJson(readFile(dist / "d" / Chain / "current.json"))
let headHash = cur["head"]["hash"].getStr
let gen = cur["generation"].getStr
let tsv = cur["traceSelectionVersion"].getStr

let headBlock = parseJson(readFile(dist / "d" / Chain / "block" / (headHash & ".json")))
let headParent = headBlock["parentHash"].getStr
var headBlockTxs: seq[string]
for t in headBlock["transactions"]: headBlockTxs.add t.getStr

# All block hashes (from the generation block index).
let root = parseJson(readFile(dist / "d" / Chain / "g" / gen / "root.json"))
var allBlockHashes: seq[string]
for rel in root["maps"]["blocks"]:
  let idx = parseJson(readFile(dist / rel.getStr))
  for bh in idx["blocks"]: allBlockHashes.add bh.getStr

# Find the transaction with a structurally-absent execution (the Aztec split).
var absentTx, absentReason, absentTarget, absentOutcome: string
block findAbsent:
  let tsDir = dist / "d" / Chain / "ts" / tsv
  for path in walkDirRec(tsDir):
    if path.endsWith(".json"):
      let ov = parseJson(readFile(path))
      if ov.hasKey("executions"):
        for e in ov["executions"]:
          if e{"availability"}.getStr == "absent":
            absentTx = ov["tx"].getStr
            absentReason = e["reason"].getStr
            let facts = parseJson(readFile(
              dist / "d" / Chain / "tx" / shard(absentTx) / (absentTx & ".json")))
            absentTarget = facts["payload"]{"target"}.getStr
            absentOutcome = facts["outcome"]{"overall"}.getStr
            break findAbsent

suite "In-process route enumeration + dispatch":
  let dr = newDataRoot(dist)

  test "staticRoutes covers home, chain, block list, and every block + tx":
    let routes = staticRoutes(dr)
    check "/" in routes
    check ("/" & Chain) in routes
    check ("/" & Chain & "/blocks") in routes
    check ("/" & Chain & "/block/" & headHash) in routes
    for txh in headBlockTxs:
      check ("/" & Chain & "/tx/" & txh) in routes

  test "renderRoute returns 200 for a real tx and 404 for unknown entities":
    let (okStatus, okBody, _) = renderRoute(dr, "/" & Chain & "/tx/" & headBlockTxs[0])
    check okStatus == 200
    check okBody.len > 0
    let (missStatus, _, _) = renderRoute(dr, "/" & Chain & "/tx/0xdeadbeef")
    check missStatus == 404
    let (bogusStatus, _, _) = renderRoute(dr, "/no/such/deep/route")
    check bogusStatus == 404

suite "Combined tree: data plane + client render":
  test "the demo data plane is present under dist/":
    check fileExists(dist / "d" / Chain / "current.json")
    check dirExists(dist / "idx")
    check dirExists(dist / "t")
    check fileExists(dist / "registry" / "chains.v1.json")

  test "client entry pages, fonts, sitemap and robots exist":
    check fileExists(dist / "index.html")
    check fileExists(dist / Chain / "index.html")
    check fileExists(dist / Chain / "blocks" / "index.html")
    check fileExists(dist / "assets" / "fonts" / "SpaceGrotesk-Regular.woff2")
    check fileExists(dist / "sitemap.xml")
    check fileExists(dist / "robots.txt")

suite "Block-list view renders real data":
  let html = readFile(dist / Chain / "blocks" / "index.html")
  test "every real block hash is linked":
    check allBlockHashes.len >= 3
    for bh in allBlockHashes:
      check ("/" & Chain & "/block/" & bh) in html

suite "Block-detail view renders real data":
  let html = readFile(dist / Chain / "block" / headHash / "index.html")
  test "it is the CLIENT render, not the generator's minimal entry page":
    check "var(--ct-action)" in html          # inlined design-system token layer
    check "class=\"crumbs\"" in html           # explorer chrome
  test "the real parent hash and every real tx hash appear":
    check headHash in html
    check headParent in html
    check ("/" & Chain & "/block/" & headParent) in html
    check headBlockTxs.len > 0
    for txh in headBlockTxs:
      check ("/" & Chain & "/tx/" & txh) in html

suite "Transaction-detail view renders real data (the Aztec split)":
  test "a transaction with a structurally-absent execution was found":
    check absentTx.len > 0
    check absentReason.len > 0
  test "the absent reason, outcome and target come through verbatim":
    let html = readFile(dist / Chain / "tx" / absentTx / "index.html")
    check absentReason in html               # the exact overlay reason string
    check "Not observable" in html           # absent → the honest label, not a spinner
    check absentTx in html
    if absentTarget.len > 0:
      check absentTarget in html
    # outcome label sanity: succeeded → "Succeeded"
    if absentOutcome == "succeeded":
      check "Succeeded" in html
  test "a DIFFERENT real tx does NOT carry the absent reason (proves it bites)":
    # A second, non-absent transaction renders through the same template but must
    # NOT contain the absent tx's reason string — so the assertions above are
    # testing per-entity data flow, not static boilerplate baked into the shell.
    let other = headBlockTxs[0]
    check other != absentTx
    let html = readFile(dist / Chain / "tx" / other / "index.html")
    check absentReason notin html

suite "Design-system token consumption gate":
  test "emitTokensCss resolves the DTCG brand/alias/mapped chain":
    let css = emitTokensCss()
    check css.startsWith(":root")
    check ("--ct-color-brand-600: " & BrandIndigo600) in css
    check "--ct-font-sans: 'Space Grotesk" in css
    check "--ct-space-md:" in css
  test "the home page inlines the token layer and references it via var(--ct-*)":
    let html = readFile(dist / "index.html")
    check ("--ct-color-brand-600: " & BrandIndigo600) in html
    check "var(--ct-action)" in html
    check "var(--ct-font-sans)" in html
    check Chain in html                      # the chain strip lists the demo chain

removeDir(workDir)
