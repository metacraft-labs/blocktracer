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
##   5. The web-lineage token layer resolved into the emitted CSS (the "consume
##      the design system" gate), and pages reference it via var(--bt-*).
##   6. VD.2's foundations reached the SHIPPED page rather than only the source:
##      both themes, both `[data-theme]` overrides and the debugger register are
##      present; every `var(--bt-*)` a page uses is declared; the primitive
##      `--ct-*` ramp has not leaked back in; and the emitter refuses an
##      untracked literal (Design-System.md §4.1, the build-time half).

import std/[unittest, os, json, strutils, osproc, re, sets]

import ../src/ssr
import ../src/reader
import ../src/design_system/tokens

const
  Chain = "aztec"
  BrandIndigo600 = "#4f46e5"  # colors.brand.600 → colors.indigo.600 in the pinned DS
  # (no palette constant needed: the theme checks below are properties)

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
    check "var(--bt-action-bg)" in html       # inlined design-system token layer
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

suite "Design-system token consumption gate (VD.2 web lineage)":
  let css = emitTokensCss()

  test "the web lineage resolves through alias to a brand primitive":
    # --bt-action-bg = {colors.brand.600} → {colors.indigo.600} → #4f46e5.
    # A three-hop resolution, so a broken alias layer cannot pass this.
    check css.startsWith(":root")
    check ("--bt-action-bg:" & BrandIndigo600) in css
    check "--bt-font-sans:'Space Grotesk" in css
    check "--bt-space-md:16px" in css

  test "the rhythm roles resolve to strictly increasing, separated values":
    # VD.1 measured a 49px row pitch against a 49px section boundary. This test
    # used to assert four hard-coded px strings under a comment claiming it
    # checked the SEPARATION; it did not — it checked four constants, and would
    # have passed just as happily on 24/24/24/24 spelled differently. The
    # separation is a property, so it is read out of the emitted CSS and
    # computed here. (check-tokens.mjs C3 asserts the same property against the
    # TOKEN SOURCE, which is the other end of the same pipe: this end proves the
    # numbers survived emission.)
    #
    # The bottom rung is the row-to-row GAP — TWO --bt-density-cell-y paddings
    # meeting at a hairline — and not the padding itself. Every other rung is a
    # gap, and a ladder whose rungs are different kinds of quantity ranks
    # nothing: ranking the padding reported 3.00x where the real separation was
    # 1.50x, and passed at cell-y = 12px, where the row gap EQUALS the 24px
    # stack rung. That is the VD.1 defect verbatim.
    # --bt-rhythm-row was emitted and referenced by no rule, and VD.3 removed it.
    check "--bt-rhythm-row" notin css
    proc pxOf(name: string): int =
      var got: array[1, string]
      let i = css.find(re("""\{[^}]*""" & name & """:(\d+)px"""), got)
      check i >= 0
      parseInt(got[0])
    let rungs = @[2 * pxOf("--bt-density-cell-y"), pxOf("--bt-rhythm-stack"),
                  pxOf("--bt-rhythm-group"), pxOf("--bt-rhythm-section")]
    for i in 1 ..< rungs.len:
      # Strictly increasing AND separated: 1.75x is the bar check-tokens.mjs C3
      # applies, expressed here in integers so no float comparison is involved.
      check rungs[i] * 100 >= rungs[i - 1] * 175

  test "both themes exist independently — the light theme is not the dark one":
    # Asserted as a PROPERTY rather than against two hard-coded hexes, so the
    # palette can move without the test going stale — and so it cannot be
    # satisfied by the dark-only :root block VD.0 found (24 of 32 light/dark
    # captures were byte-identical because there was no light theme at all).
    check "@media (prefers-color-scheme:dark)" in css
    check "[data-theme=\"light\"]" in css
    check "[data-theme=\"dark\"]" in css
    var lightCanvas, darkCanvas: array[1, string]
    let iLight = css.find(
      re("""\[data-theme="light"\]\{[^}]*--bt-surface-canvas:(#[0-9a-f]{6})"""), lightCanvas)
    let iDark = css.find(
      re("""\[data-theme="dark"\]\{[^}]*--bt-surface-canvas:(#[0-9a-f]{6})"""), darkCanvas)
    check iLight >= 0
    check iDark >= 0
    check lightCanvas[0] != darkCanvas[0]
    # And the light one really is the light one: a theme axis wired to two
    # identical or inverted values would pass a mere inequality check.
    proc lumaOf(hex: string): int =
      parseHexInt(hex[1 .. 2]) + parseHexInt(hex[3 .. 4]) + parseHexInt(hex[5 .. 6])
    check lumaOf(lightCanvas[0]) > lumaOf(darkCanvas[0]) + 300
    # The surface ladder is a real ladder, not one tone repeated. Asserted as a
    # property for the same reason as the canvas: five roles, five distinct
    # values, in EACH theme independently. The VD.2 round found one tone doing
    # four jobs (input, label column, callout, code region) and this is the
    # shape of that defect.
    for themeSel in ["""\[data-theme="light"\]""", """\[data-theme="dark"\]"""]:
      var seen = initHashSet[string]()
      for role in ["canvas", "raised", "sunken", "code", "hover"]:
        var m: array[1, string]
        let i = css.find(re(themeSel & """\{[^}]*--bt-surface-""" & role &
                            """:(#[0-9a-f]{6})"""), m)
        check i >= 0
        seen.incl m[0]
      # canvas/raised legitimately coincide on a white light canvas, so the
      # bar is "at least three distinct tones", not five.
      check seen.len >= 3

  test "the debugger register is a density parametrisation, not a second CSS":
    check "[data-register=\"debugger\"]" in css
    # A property, not two constants: the debugger's cell padding is STRICTLY
    # tighter than the explorer's, whatever the two rungs happen to be. A
    # register parametrisation that resolved to the same density in both would
    # be two names for one thing.
    var expY, dbgY: array[1, string]
    check css.find(re("""^:root\{[^}]*--bt-density-cell-y:(\d+)px"""), expY) >= 0
    check css.find(re("""\[data-register="debugger"\]\{[^}]*--bt-density-cell-y:(\d+)px"""), dbgY) >= 0
    check parseInt(dbgY[0]) < parseInt(expY[0])

  test "the primitive ramp is NOT emitted, so a Layer 2 reference to one breaks":
    # VD.2 stopped emitting --ct-*. That is what makes the lint constructive:
    # a brand primitive in a view is undefined as well as forbidden.
    check "--ct-" notin css

  test "the emitter carries a binding kind for every token":
    let toks = loadWebTokens()
    check toks.len > 100
    var literals = 0
    for t in toks:
      case t.kind
      of bkToken:
        check t.counterpart.len > 0
      of bkLiteral:
        # Design-System.md §4.1, the build-time half: an untracked literal
        # raises in loadWebTokens(), so reaching here means every one is named.
        check t.divergence.len > 0
        inc literals
    check literals > 0

suite "The foundations reached the SHIPPED page":
  let html = readFile(dist / "index.html")
  var style: array[1, string]
  let hasStyle = html.find(re"(?s)<style>(.*?)</style>", style) >= 0
  let shipped = if hasStyle: style[0] else: ""

  test "the page carries an inlined <style> block":
    check hasStyle
    check shipped.len > 1000

  test "every var(--bt-*) the page references is declared in the same page":
    # The check that a token rename cannot half-land: a rule referring to a
    # variable nothing declares renders as nothing at all, silently.
    var declared = initHashSet[string]()
    for m in shipped.findAll(re"--bt-[a-z0-9-]+\s*:"):
      declared.incl m.strip(chars = {' ', ':'})
    var dangling: seq[string]
    for m in shipped.findAll(re"var\(--bt-[a-z0-9-]+"):
      let name = m[4 .. ^1]
      if name notin declared and name notin dangling:
        dangling.add name
    check dangling.len == 0
    if dangling.len > 0:
      echo "  dangling --bt-* references: ", dangling

  test "both themes, both overrides and both registers shipped":
    check "prefers-color-scheme:dark" in shipped
    check "[data-theme=\"light\"]" in shipped
    check "[data-theme=\"dark\"]" in shipped
    check "[data-register=\"debugger\"]" in shipped
    check "data-register=\"explorer\"" in html   # the element, not just the rule

  test "no raw hex colour survives in the SHIPPED view rules":
    # Token DECLARATIONS are hex by definition — that is what a resolved token
    # is. What must not appear is a hex value in a rule BODY, which would mean
    # a Layer 2 view wrote a colour rather than referencing a role. The
    # declarations are stripped, and what is left is scanned.
    let rulesOnly = shipped.replace(re"--bt-[a-z0-9-]+:[^;}]*", "")
    var offenders: seq[string]
    for m in rulesOnly.findAll(re"#[0-9a-fA-F]{3,8}\b"):
      offenders.add m
    check offenders.len == 0
    if offenders.len > 0:
      echo "  raw colours in shipped rule bodies: ", offenders

removeDir(workDir)
