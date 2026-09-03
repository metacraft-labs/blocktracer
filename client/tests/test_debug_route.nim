## M8a / M8b — the `/{chain}/tx/{hash}/debug` route.
##
## Everything here runs against a REAL demo tree generated in-process by the
## repository's own demo generator, and every expectation is checked against
## ground truth read INDEPENDENTLY out of that tree with `std/json` — never
## through `reader`, and never through the page's own producer. A renderer that
## dropped a field, a producer that invented one, or a route that stopped being
## served all fail here rather than being asserted against themselves.
##
## Two properties this file is deliberately built around, because the project
## has repeatedly found checks that could not fail:
##
##   * **Nothing passes when its subject is absent.** The suite refuses to run
##     if the tree contains no replayable transaction, no divergent one or no
##     on-demand one (`requireFixtures` below), rather than quietly reporting
##     green over an empty loop.
##
##   * **Every claim about the layout has a negative.** "The arrangement comes
##     from `LayoutNode`" is only worth checking if a DIFFERENT `LayoutNode`
##     produces a different render, so each structural test mutates the model
##     and asserts the output followed.

import std/[unittest, os, json, strutils, tables, sets, sequtils]

import ../src/ssr
import ../src/reader
import ../src/viewutil
import ../src/debugger/layout_model
import ../src/debugger/session_layout
import ../src/debugger/session_view
import ../src/debugger/keymap
import ../src/debugger/replay_engine
import ../src/debugger/source_document
import ../src/debugger/source_island
import ../src/debugger/demo_session
import ../src/debugger/deeplink_landing
import ../src/debugger/demo_flow
import ../src/debugger/flow_view
import ../src/components/debugger as dbgc
import ../src/components/shortcut_list
import ../src/debugger/hard_keys
import ../src/pages/settings
import ../src/components/debugger_css
import isonim/ssr/escape
import ../src/pages/debug as debugPg
import ../src/pages/tx as txPg
import blocktracer/demo/generator
import blocktracer/contract/ids   # `contentHashSha1`, as an independent oracle

const Chain = "demo"

# ── a real tree, generated in-process ──────────────────────────────────────

let
  clientRoot = currentSourcePath().parentDir.parentDir     # <repo>/client
  repoRoot = clientRoot.parentDir
  fixtureDir = repoRoot / "fixtures" / "trace" / "noir_space_ship"
  fixture = fixtureDir / "zk_shields.ct"
  fixtureSources = fixtureDir / "sources"
  workDir = getTempDir() / ("blocktracer-debug-route-test-" & $getCurrentProcessId())

removeDir(workDir)
createDir(workDir)
doAssert fileExists(fixture),
  "the trace fixture is missing: " & fixture &
  " — the demo generator cannot produce a tree, so nothing below would be a test"
# `traceSourcesDir` matters here beyond completeness. M5c publishes the traced
# program's sources as content-addressed bundles, and the debug route PREFERS a
# published bundle over the fixture files vendored beside the client
# (`withPublishedSources`). Generating without them would exercise only the
# fallback and leave the ranking rule — the one the route actually takes in
# production — asserted against nothing.
discard generate(DemoConfig(outDir: workDir, seed: "debug-route-test",
                            traceFixturePath: fixture,
                            traceSourcesDir: fixtureSources))

let root = newDataRoot(workDir)
let routes = staticRoutes(root)

# ── independent ground truth, straight out of the JSON ─────────────────────

proc shardOf(hash: string): string =
  let h = if hash.startsWith("0x"): hash[2 .. ^1] else: hash
  h[0 .. 3]

proc overlayPathIn(dir, hash: string): string =
  let generationJson = parseJson(readFile(dir / "d" / Chain / "current.json"))
  dir / "d" / Chain / "ts" / generationJson["traceSelectionVersion"].getStr /
    shardOf(hash) / (hash & ".json")

proc overlayIn(dir, hash: string): JsonNode =
  parseJson(readFile(overlayPathIn(dir, hash)))

proc overlayOf(hash: string): JsonNode = overlayIn(workDir, hash)

proc headlineIn(dir, hash: string): string =
  ## The strongest availability among a transaction's executions, computed here
  ## from the raw overlay rather than borrowed from the SDK — so a change to
  ## `bestTrace`'s ranking shows up as a disagreement instead of moving both
  ## sides of the assertion at once.
  let o = overlayIn(dir, hash)
  var execs: seq[JsonNode]
  if o.hasKey("trace"): execs.add o["trace"]
  elif o.hasKey("executions"):
    for e in o["executions"]: execs.add e
  for want in ["ready", "divergent", "onDemand"]:
    for e in execs:
      if e{"availability"}.getStr == want: return want
  if execs.len > 0: execs[0]{"availability"}.getStr else: ""

proc headlineAvailabilityOf(hash: string): string = headlineIn(workDir, hash)

proc allTxHashes(): seq[string] =
  for path in routes:
    let parts = path.strip(chars = {'/'}).split('/')
    if parts.len == 3 and parts[1] == "tx": result.add parts[2]

let txHashes = allTxHashes()

proc firstTxWith(availability: string): string =
  for h in txHashes:
    if headlineAvailabilityOf(h) == availability: return h
  ""

let
  readyTx = firstTxWith("ready")
  divergentTx = firstTxWith("divergent")
  onDemandTx = firstTxWith("onDemand")

proc requireFixtures() =
  ## The suite is only meaningful over a tree that actually exhibits the states
  ## it claims to test. Failing here is the difference between "the route
  ## handles every availability" and "no loop body ever executed".
  doAssert txHashes.len > 0, "the generated tree has no transactions"
  doAssert readyTx.len > 0, "no transaction in the tree has a ready trace"
  doAssert divergentTx.len > 0, "no transaction in the tree has a divergent trace"
  doAssert onDemandTx.len > 0, "no transaction in the tree is on-demand"

requireFixtures()

# ── a second tree, exhibiting §7.0's two non-session rows ──────────────────
#
# The demo generator publishes `ready`, `divergent` and `onDemand` headlines
# and no `absent` or `unsupported` one: the split transaction's private half is
# absent, but its public half is ready, so the transaction's HEADLINE is ready
# and the two rows §7.0 gives "no debugger, and no pretence of one" are not
# reachable through the route in the tree above.
#
# They are the rows the negative half of this milestone turns on — "the served
# page for a ready trace IS the session, and for absent is NOT" — so they get a
# real tree rather than a direct call to a renderer. This is a SECOND generated
# tree with two transactions' overlays rewritten in place, which means the
# reader, the resolver, the session producer, the router and the layout all run
# exactly as they do in production; only the published availability differs.
# `requireDegraded` below refuses to continue unless the rewrite actually took.
let degradedDir = getTempDir() /
  ("blocktracer-tx7-degraded-" & $getCurrentProcessId())
removeDir(degradedDir)
createDir(degradedDir)
discard generate(DemoConfig(outDir: degradedDir, seed: "debug-route-test",
                            traceFixturePath: fixture,
                            traceSourcesDir: fixtureSources))

proc degrade(hash, availability, reason: string) =
  ## Republish one transaction's trace selection with a different availability.
  ##
  ## Every execution moves, so the transaction's headline moves with it, and
  ## the fields that would claim a published artifact are removed: an `absent`
  ## execution with a byte count and a validation verdict is not a state the
  ## pipeline can emit, and testing the route against one would be testing a
  ## tree that cannot exist.
  let path = overlayPathIn(degradedDir, hash)
  var o = parseJson(readFile(path))
  proc rewrite(e: JsonNode) =
    e["availability"] = %availability
    e["reason"] = %reason
    for key in ["bytes", "validation", "traceArtifactId", "reconstructed"]:
      if e.hasKey(key): e.delete(key)
  if o.hasKey("trace"): rewrite(o["trace"])
  if o.hasKey("executions"):
    for e in o["executions"]: rewrite(e)
  writeFile(path, $o)

const
  AbsentReason = "aztec private execution: no call structure to trace"
  UnsupportedReason = "no recorder exists for this VM yet"

degrade(readyTx, "absent", AbsentReason)
degrade(divergentTx, "unsupported", UnsupportedReason)

let degradedRoot = newDataRoot(degradedDir)
let
  absentTx = readyTx
  unsupportedTx = divergentTx

proc requireDegraded() =
  ## The rewrite is a fixture, so it is verified against the tree it wrote
  ## rather than assumed. Without this the two negative tests below would pass
  ## over transactions that still had traces — which is the exact shape of
  ## check this suite exists to refuse.
  doAssert headlineIn(degradedDir, absentTx) == "absent",
    "the absent fixture did not take: " & headlineIn(degradedDir, absentTx)
  doAssert headlineIn(degradedDir, unsupportedTx) == "unsupported",
    "the unsupported fixture did not take: " &
    headlineIn(degradedDir, unsupportedTx)

requireDegraded()

proc debugHtmlIn(r: DataRoot, hash: string): string =
  let (status, body, _) = renderRoute(r, "/" & Chain & "/tx/" & hash & "/debug")
  doAssert status == 200, "debug route did not serve " & hash & ": " & $status
  body

proc txHtmlIn(r: DataRoot, hash: string): string =
  let (status, body, _) = renderRoute(r, "/" & Chain & "/tx/" & hash)
  doAssert status == 200, "tx route did not serve " & hash & ": " & $status
  body

proc debugHtml(hash: string): string = debugHtmlIn(root, hash)
proc txHtml(hash: string): string = txHtmlIn(root, hash)

# The markers that say "this document is a debugging session". Deliberately
# structural — the pane region, a walked pane id and a rendered line of source
# — rather than a word on the page: a page that merely SAID "debugger" would
# satisfy a copy match and none of these.
const SessionMarkers = [
  "class=\"dbgmain\"",          # the pane region
  "id=\"pane-editor\"",         # a pane the LayoutNode walk placed
  "id=\"pane-calltrace\"",
  "id=\"pane-metadata\"",       # §7.1's pane, beside the walked tree
  "class=\"srcline",            # real source, line by line
  "class=\"dc\"",               # the stepping toolbar
]

proc isSession(html: string): bool =
  for m in SessionMarkers:
    if m notin html.split("</style>")[1]: return false
  true

proc hasNoSessionMarker(html: string): bool =
  for m in SessionMarkers:
    if m in html.split("</style>")[1]: return false
  true

proc markup(html: string): string =
  ## The document with the inlined stylesheet removed. Every "this is NOT on
  ## the page" assertion is made against this: the `<style>` payload names
  ## `.btn`, `.dc` and every other class the whole site can render, so a
  ## negative matched against the whole document would be answered by the CSS
  ## rather than by the markup.
  html.split("</style>")[1]

proc sessionFor(hash: string): DebugSessionView =
  debugSessionFor(root, Chain, hash)

# Very small helpers for reading the rendered markup. Deliberately string
# matching rather than a DOM: the artifact under test is the HTML a browser is
# served, and a parser that repaired it would hide exactly the defects a
# hand-built fragment introduces.
proc idsInOrder(html: string; prefix: string): seq[string] =
  var i = 0
  while true:
    let at = html.find("id=\"" & prefix, i)
    if at < 0: break
    let start = at + len("id=\"")
    let stop = html.find('"', start)
    result.add html[start ..< stop]
    i = stop

proc codeLines(html: string): seq[string] =
  ## The TEXT of every rendered source line, recovered from the served markup.
  ##
  ## Since VD.5 a line is a run of `<span>`s inside its `<code>` rather than one
  ## text node, so a line's text is no longer a contiguous substring of the
  ## page. Stripping the tags and undoing the escaping is what lets a test still
  ## ask "is the real program on this page" without either asserting against the
  ## tokenisation (which would make every lexer change a test change) or
  ## weakening to a per-fragment search (which a placeholder renderer emitting
  ## the right words in the wrong order would pass).
  var i = 0
  while true:
    let at = html.find("<code class=\"t\">", i)
    if at < 0: break
    let start = at + len("<code class=\"t\">")
    let stop = html.find("</code>", start)
    if stop < 0: break
    var text = ""
    var j = start
    while j < stop:
      if html[j] == '<':
        j = html.find('>', j) + 1
      else:
        text.add html[j]
        inc j
    result.add text.multiReplace(("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
                                 ("&#39;", "'"), ("&amp;", "&"))
    i = stop

proc occurrences(html, needle: string): int =
  var i = 0
  while true:
    let at = html.find(needle, i)
    if at < 0: break
    inc result
    i = at + needle.len

proc executableScripts(html: string): int =
  ## How many `<script>` elements a browser would EXECUTE.
  ##
  ## Not the same as how many `<script>` substrings the document contains, and
  ## the difference is the whole of what hydration added to this page. Two
  ## kinds now appear and only one of them runs:
  ##
  ##   * `<script type="application/json" id="bt-session-source">` — the source
  ##     bundle as DATA (`source_island.nim`). A browser does not parse or run
  ##     it; it is markup carrying text, in the same standing as `data-copy`.
  ##     With scripting off it renders nothing.
  ##   * `<script src="…" defer>` — the hydration bundle, emitted only when
  ##     `replay_engine.HydrationBundle` names one. This suite compiles with the
  ##     default, which is empty, so it must find none.
  ##
  ## Counting the substring would make an inert data island indistinguishable
  ## from a script, and this file's whole standard is that a page ships nothing
  ## that could act unless it can. So the count is of things that act.
  var i = 0
  while true:
    let at = html.find("<script", i)
    if at < 0: break
    let close = html.find('>', at)
    if close < 0: break
    let tag = html[at .. close]
    if "type=\"application/json\"" notin tag: inc result
    i = close + 1

# ---------------------------------------------------------------------------

suite "M8a — the debug route is served":

  test "every transaction has a /debug route, and it renders":
    for h in txHashes:
      check ("/" & Chain & "/tx/" & h & "/debug") in routes
      let html = debugHtml(h)
      check html.startsWith("<!doctype html>")
      check "class=\"dbg\"" in html

  test "the route is scoped: a transaction that does not exist is a 404":
    let (status, _, _) = renderRoute(root,
      "/" & Chain & "/tx/0x0000000000000000000000000000000000000000/debug")
    check status == 404
    let (s2, _, _) = renderRoute(root, "/" & Chain & "/tx/" & readyTx & "/nonsense")
    check s2 == 404

  test "the debug route is the product register, with the explorer chrome gone":
    let html = debugHtml(readyTx)
    check "data-register=\"debugger\"" in html
    check "data-register=\"explorer\"" notin html
    # The two pieces of explorer chrome §8 says collapse.
    check "class=\"nav\"" notin html
    check "class=\"foot\"" notin html
    # …replaced by the slim identity bar, carrying the identity and the way
    # back. The way back is the CHAIN, which is what the link's label says:
    # §7.0 makes the transaction's own URL this same session, so a link there
    # would be a link to an identical page.
    check "class=\"dbgbar\"" in html
    check ("href=\"" & chainUrl(Chain) & "\"") in html
    check ("href=\"" & txUrl(Chain, readyTx) & "\"") notin html

  test "the register is a change of ATTRIBUTE VALUE, not a second stylesheet":
    # Design-System §2: the registers share everything but density, surface and
    # default theme. If the debug page shipped rules the explorer page does not,
    # the register would have become a component library.
    # The explorer half is read off a page that is STILL the explorer register:
    # §7.0 sends a transaction with a published trace into the session, so the
    # transaction route is only an explorer page for the rows that have no
    # session, and reading it off `readyTx` would compare the debug route with
    # itself.
    let debugCss = debugHtml(readyTx).split("<style>")[1].split("</style>")[0]
    let explorerCss = txHtml(onDemandTx).split("<style>")[1].split("</style>")[0]
    check "<html lang=\"en\" data-register=\"explorer\">" in txHtml(onDemandTx)
    check debugCss == explorerCss

suite "M8a — the arrangement is BlockTracer's, over CodeTracer's LayoutNode":

  test "the arrangement is PINNED: which panes, in which grouping":
    ## The structural claim, asserted against the model rather than against the
    ## markup, so a later change cannot revert the arrangement quietly. Every
    ## sentence of `session_layout`'s doc comment has a line here.
    let m = blockTracerReplayLayout()
    check isValid(m)

    # One row: Code on the left, a column of two regions on the right.
    check m.kind == lnRow
    check m.children.len == 2
    let code = m.children[0]
    let nav = m.children[1]
    check code.kind == lnPane
    check code.pane == paneEditor
    check code.title == "Code"          # not "Editor" — see §3 below
    check nav.kind == lnColumn
    check nav.children.len == 2

    # Call Trace and Event Log are ONE TABBED REGION, in that order, and Values
    # sits below it as a pane of its own. This is the grouping the change exists
    # for: an edit that flattens the region back into two stacked panes, or that
    # pulls Values into the tab strip, fails here.
    let region = nav.children[0]
    let values = nav.children[1]
    check region.kind == lnStack
    check region.children.len == 2
    check region.children[0].pane == paneCalltrace
    check region.children[1].pane == paneEventLog
    check region.children[0].title == "Call Trace"
    check region.children[1].title == "Event Log"
    check values.kind == lnPane
    check values.pane == paneState
    check values.title == "Values"              # not "State" — see §3 below

    # Call Trace is the tab that OPENS. Selection is the primary navigation
    # gesture and the call trace is the primary selection surface; it is also
    # the index `renderStack`'s `:target` CSS is correct for, which marks the
    # FIRST tab as active.
    check region.activeIndex == 0
    check visiblePanes(region) == @[paneCalltrace]

    # The Event Log is behind a tab, so `visiblePanes` and `allPanes` disagree
    # by exactly it — and by nothing else, which is what stops a later edit from
    # hiding a third pane and calling it the same arrangement.
    check allPanes(m).toHashSet ==
      [paneEditor, paneCalltrace, paneEventLog, paneState].toHashSet
    check visiblePanes(m).toHashSet ==
      [paneEditor, paneCalltrace, paneState].toHashSet
    check allPanes(m).toHashSet - visiblePanes(m).toHashSet ==
      [paneEventLog].toHashSet

    # The controls are NOT a pane of this tree. Named through the constant so
    # the absence is checked against the written decision and not against a
    # literal repeated here.
    check ControlsArePlacedInTheBar == paneDebugControls
    check not m.contains(ControlsArePlacedInTheBar)

    # The navigation region carries the larger share of the column, and Values
    # keeps a definite share rather than whatever is left.
    check region.weight > values.weight
    check values.weight > 0.0

  test "the vendored model is untouched — the composition is what differs":
    ## `ci/test/layout-model-vendor.sh` is the real guard; this is the cheap
    ## in-suite half of it, and it is what makes "we composed instead of
    ## forking" a checked statement rather than a claim in a comment.
    let upstream = defaultReplayLayout()
    check allPanes(upstream).len == 5              # still CodeTracer's five
    check paneDebugControls in allPanes(upstream)  # …including the controls
    check visiblePanes(upstream).len < allPanes(upstream).len  # …and its stack
    check $upstream != $blockTracerReplayLayout()
    # The pane titles differ; the ENUM does not, because the enum is a wire
    # format shared with the SDK and only the labels are BlockTracer's.
    check find(upstream, paneEditor).title == "Editor"
    check find(blockTracerReplayLayout(), paneEditor).title == "Code"
    check $paneEditor == "editor"
    check $paneState == "state"

  test "every pane of the arrangement is placed exactly once":
    let html = debugHtml(readyTx)
    let model = blockTracerReplayLayout()
    check allPanes(model).len == 4
    for pane in allPanes(model):
      let id = "id=\"pane-" & ($pane).toLowerAscii & "\""
      check occurrences(html, id) == 1
    # …and nothing outside the model's pane set was placed.
    let placed = idsInOrder(html, "pane-").toHashSet
    var expected = initHashSet[string]()
    for pane in allPanes(model): expected.incl "pane-" & ($pane).toLowerAscii
    expected.incl "pane-metadata"   # §7.1, BlockTracer's own, beside the tree
    check placed == expected
    # The controls pane is not among them, and is not merely missing either —
    # the next test finds it in the bar.
    check "id=\"pane-debugcontrols\"" notin html

  test "the debug controls render in the identity bar, not in the pane grid":
    ## The move, asserted in both directions. Half of this test is what stops
    ## "the controls moved to the bar" from decaying into "the controls were
    ## deleted", which is the failure a purely negative check would pass.
    let html = debugHtml(readyTx)
    let s = sessionFor(readyTx)

    # Present, complete, and inside the bar.
    let barStart = html.find("class=\"dbgbar\"")
    check barStart > 0
    let barEnd = html.find("class=\"dbgnarrow\"")
    check barEnd > barStart
    let bar = html[barStart ..< barEnd]
    check "class=\"dbgctl\"" in bar
    check "class=\"dc\"" in bar
    check occurrences(bar, "class=\"dcbtn off\"") == s.controls.buttons.len
    check "class=\"dctl\"" in bar          # the scrubber came with them
    check "class=\"dcsteps num\"" in bar   # …and the position readout
    # Every control the model names is in the bar, by its own label.
    for b in s.controls.buttons:
      check controlLabel(b.action) in bar

    # And nowhere else: not a pane, not a second copy in the grid.
    let grid = html[barEnd .. ^1]
    check "class=\"dc\"" notin grid
    check "p-controls" notin grid
    # The stylesheet no longer carries a rule for a pane that cannot exist.
    check ".p-controls" notin debugRouteCss

  test "the weights of the model become the flex fractions in the markup":
    let html = debugHtml(readyTx)
    # `blockTracerReplayLayout()`: code 3 / column 2, calltrace 4, eventlog 2,
    # state 2. Read the weights OFF THE MODEL so this cannot drift into a
    # restatement of the numbers.
    let model = blockTracerReplayLayout()
    let code = model.children[0]
    let nav = model.children[1]
    check ("ln row " & dbgc.weightClass(model.weight)) in html
    check ("pane p-source " & dbgc.weightClass(code.weight)) in html
    check ("ln col " & dbgc.weightClass(nav.weight)) in html
    # The navigation region is a STACK, so its weight lands on the container
    # rather than on a pane — the panels inside it each fill the region and
    # carry no fraction of their own, which is what a tab pair means.
    check ("ln stack " & dbgc.weightClass(nav.children[0].weight)) in html
    check (dbgc.paneClass(nav.children[1].pane) & " " &
           dbgc.weightClass(nav.children[1].weight)) in html

  test "a DIFFERENT layout renders differently — the walk is driven by the model":
    # The negative half. Without it, "the arrangement comes from LayoutNode"
    # would be satisfied by a renderer that ignores the argument entirely.
    let s = sessionFor(readyTx)
    let reference = dbgc.renderLayout(blockTracerReplayLayout(), s)

    var trimmed = blockTracerReplayLayout()
    check removePane(trimmed, paneCalltrace)
    let trimmedHtml = dbgc.renderLayout(trimmed, s)
    check "id=\"pane-calltrace\"" notin trimmedHtml
    check "id=\"pane-calltrace\"" in reference

    var reweighted = blockTracerReplayLayout()
    check setWeight(reweighted, paneEditor, 5.0)
    check ("pane p-source w5") in dbgc.renderLayout(reweighted, s)

    # The titles are the MODEL's, not the renderer's: a pane relabelled in the
    # tree is relabelled on the page, which is what makes "Code" and "Values"
    # BlockTracer's labels rather than a string buried in a `case`.
    var relabelled = blockTracerReplayLayout()
    find(relabelled, paneState).title = "Storage"
    check ">Storage<" in dbgc.renderLayout(relabelled, s)
    check ">Values<" in reference
    check ">Values<" notin dbgc.renderLayout(relabelled, s)

  test "Call Trace and Event Log are ONE tabbed region, Call Trace open":
    ## The grouping, asserted over the served MARKUP rather than the model, so
    ## the two halves of the claim — the model says tabs, the page renders tabs
    ## — are both pinned. Everything here is matched against the document with
    ## the inlined stylesheet removed: `<style>` carries the `.stackpanel` and
    ## `.stacktab` rules, so a whole-document match would answer itself.
    let markup = debugHtml(readyTx).split("</style>")[1]

    # One region, two panels, one strip.
    check occurrences(markup, "class=\"ln stack ") == 1
    check occurrences(markup, "class=\"stacktabs\"") == 1
    check "stackpanel p-eventlog alt" in markup
    # Call Trace is the DEFAULT panel — `activeIndex = 0` — and the Event Log
    # is the alternate. Reversing that fails here.
    check "stackpanel p-calltrace def" in markup
    check "stackpanel p-eventlog def" notin markup
    check "stackpanel p-calltrace alt" notin markup

    # The strip names both, in the model's order, and switches with `:target`
    # links rather than script. `.stacktab:first-child` is what the stylesheet
    # marks active, so the FIRST tab has to be the default panel: an arrangement
    # whose active child is not its first would render a strip that marks the
    # wrong tab, which is the latent defect this ordering avoids.
    check "class=\"stacktab t-pane-calltrace\" href=\"#pane-calltrace\"" in markup
    check "class=\"stacktab t-pane-eventlog\" href=\"#pane-eventlog\"" in markup
    check markup.find("t-pane-calltrace") < markup.find("t-pane-eventlog")
    check ".stacktabs > .stacktab:first-child" in debugRouteCss
    # The tabs are `:target` links and NOT script. Asserted as "no executable
    # script", which is what the claim has always meant and is now the sharper
    # spelling of it: this build declares no hydration bundle
    # (`HydrationBundle` is empty by default, `replay_engine.nim`), so the only
    # `<script>` on the page is the `application/json` source island, which a
    # browser neither parses nor runs. A `notin "<script"` would have made this
    # test fail on inert data.
    check executableScripts(markup) == 0

    # Values is NOT in the region: it is a pane below it, not a third tab. It
    # answers "what is true here" rather than "where do I want to be", and a
    # tab would rank it as an alternative to navigating.
    check "stackpanel p-state" notin markup
    check "t-pane-state" notin markup
    check "class=\"pane p-state " in markup

    # Both panes still exist and are both addressable — a tab is a change of
    # ranking, not a removal. This is the half that stops "tabbed" from decaying
    # into "the Event Log was dropped again".
    check "id=\"pane-calltrace\"" in markup
    check "id=\"pane-eventlog\"" in markup
    for row in sessionFor(readyTx).eventLog.rows:
      check escapeHtml(row.label) in markup

  test "renderLayout is total over lnStack, and the model decides the live tab":
    ## Driven over a SYNTHETIC node as well as the served one, because
    ## `renderLayout` must be total over `LayoutNodeKind` for any tree — a
    ## restored layout (`restoreLayout`) can carry a stack of panes this
    ## arrangement never groups, and CodeTracer's own default carries a
    ## different one. Deleting the branch would turn that into a blank region,
    ## which is the exact failure `lpUnknownPane` exists to prevent.
    let s = sessionFor(readyTx)
    let node = stack([pane(paneState, "Values"), pane(paneEventLog, "Event Log")],
                     activeIndex = 0)
    let html = dbgc.renderLayout(node, s)
    check "stackpanel p-state def" in html
    check "stackpanel p-eventlog alt" in html
    # The tab strip links to both, so the switch works with no JavaScript.
    check "href=\"#pane-state\"" in html
    check "href=\"#pane-eventlog\"" in html
    # …and the model decides which tab is live.
    let other = dbgc.renderLayout(
      stack([pane(paneState, "Values"), pane(paneEventLog, "Event Log")],
            activeIndex = 1), s)
    check "stackpanel p-eventlog def" in other
    check other != html
    # The rules that render it are in the shipped stylesheet, so the branch is
    # not styled by nothing.
    check ".stackpanel.alt:target" in debugRouteCss
    check ".stackpanel.alt:target ~ .stackpanel.def" in debugRouteCss

  test "§13's narrow reduction removes the Event Log's TAB, not just its panel":
    ## The Event Log is the alternate half of the region now, so at narrow width
    ## it is already hidden by `.stackpanel.alt` — which means the rule that
    ## USED to hide it is doing nothing, and the thing that would be left behind
    ## is a tab selecting a pane this viewport does not offer. That is the dead
    ## control this surface has removed twice; the stylesheet has to name the
    ## tab, and it has to answer `:target` so a stale fragment cannot blank the
    ## region either.
    check ".stacktab.t-pane-eventlog{display:none}" in debugRouteCss
    check ".stackpanel.p-eventlog:target{display:none}" in debugRouteCss
    check ".stackpanel.p-eventlog:target ~ .stackpanel.def{display:flex}" in
          debugRouteCss
    # …inside the narrow media query and not at top level, where it would hide
    # the Event Log at every width.
    let narrow = debugRouteCss.split("@media (max-width:1100px){")[1]
    check ".stacktab.t-pane-eventlog{display:none}" in narrow
    # The Code pane's narrow height fix is in the same block — the P1 where an
    # auto-height `.panebody` gave `.srcwrap`'s `height:100%` nothing to divide
    # and the pane rendered as an empty title bar.
    check ".p-source .panebody{height:" in narrow

  test "a weight the stylesheet has no fraction for is a build failure":
    # `weightClass` is the only place a layout can fail to be renderable, and
    # it must do so loudly: a silent fallback would render the panes at the
    # wrong proportions and look plausible.
    check dbgc.weightClass(0.0) == "w1"
    check dbgc.weightClass(9.0) == "w9"
    expect ValueError: discard dbgc.weightClass(13.0)
    expect ValueError: discard dbgc.weightClass(2.5)

suite "M8a — the source pane renders real source, with stable line identity":

  test "the recorded program's source is rendered, line by line":
    let s = sessionFor(readyTx)
    check s.editor.availability == srcSourceLevel
    let doc = activeDocument(s.editor)
    check doc.lines.len > 20
    let html = debugHtml(readyTx)
    # Lines of the real `zk_shields` program, not a placeholder.
    #
    # Taken from the WHOLE document, because the whole document is what the pane
    # renders. This used to read `activeDocument(openAtCurrent(s.editor, lead = 6))`
    # and assert `rendered.lines[0].number > 1` — "the window is a real window" —
    # which is precisely the behaviour that was removed. The strings below are
    # still `shield.nr`'s own source, read out of the document rather than
    # written in by hand, so a placeholder renderer still fails it.
    let rendered = activeDocument(s.editor)
    check rendered.lines.len > 20
    check rendered.lines[0].number == 1    # the file starts where the file starts
    # The served bytes, with the tokenisation undone — see `codeLines`. Every
    # line is compared WHOLE and in full, including the ones carrying HTML
    # -special characters, which are the ones most likely to be mangled.
    let served = codeLines(html)
    var matched = 0
    for ln in rendered.lines:
      if ln.text.strip().len > 0:
        check ln.text in served
        inc matched
    check matched > 20
    # The session's own line, by hand — so a renderer that emitted the right
    # COUNT of wrong lines still fails.
    check "        damage = mass * (100 - shield_pct);" in served
    # Still one `<code>` per line, and the per-line container is unchanged:
    # highlighting replaced the text node INSIDE it and moved nothing around
    # it, which is what the inline-value workstream is relying on.
    check "<code class=\"t\">" in html
    check served.len == occurrences(html, "class=\"srcline")

  test "every line has a stable id derived from (path, line), not render order":
    let s = sessionFor(readyTx)
    let doc = activeDocument(s.editor)
    var seen = initHashSet[string]()
    for ln in doc.lines:
      check ln.anchor == lineAnchor(doc.path, ln.number)
      check ln.anchor notin seen
      seen.incl ln.anchor
    check seen.len == doc.lines.len
    # The page renders every line of the file (see the next test), so the lines
    # it emits ARE the document's. The identity property is asserted over
    # exactly the lines the page emits — and, because the anchors are derived
    # from `(path, line)` and not from render order, they are the same ids the
    # document produced above.
    let html = debugHtml(readyTx)
    let rendered = activeDocument(s.editor)
    check rendered.lines.len > 0
    for ln in rendered.lines:
      check ln.anchor == lineAnchor(doc.path, ln.number)
      check ("id=\"" & ln.anchor & "\"") in html

  test "the source pane renders the WHOLE file and opens on the position":
    ## This test used to assert the opposite of half of what it asserts now, and
    ## the history is the point.
    ##
    ## The regression it was written for shipped, and four of six reviewers in
    ## VD.5's first round found it on the rendered page: the pane rendered the
    ## file from line 1, so at the `laptop` viewport the current line fell below
    ## the fold. The toolbar claimed a step and no pane showed one. The fix was
    ## `openAtCurrent`, which DELETED every line above the position, and this
    ## test then asserted `ids.find(cur) <= 8` plus `"Showing from line" in html`
    ## — the current line near the top, and the loss announced.
    ##
    ## That bought the position at the price of the program: on `loops and
    ## iteration`, an 83-line file whose `main` is at line 77, it showed thirteen
    ## lines and none of the four functions `main` calls. The window is gone.
    ##
    ## BOTH HALVES ARE STILL ASSERTED, because the position was never the wrong
    ## requirement — only the mechanism was. "Visible" cannot be asserted from
    ## markup, so what is asserted is what CAUSES it and does not depend on a
    ## viewport: the current row carries `autofocus`, and a browser scrolls a
    ## focused element into view before it paints, with or without a script on
    ## the page. The browser half of this claim is journey 12's, in a real
    ## browser, hit-testing painted pixels; this half is that the markup a
    ## browser would need is the markup that is served.
    let s = sessionFor(readyTx)
    let full = activeDocument(s.editor)
    # The fixture has to be able to fail this, or the test is decoration: a file
    # whose position is at line 3 would render whole under either behaviour.
    check s.editor.currentLine > 8
    check full.lines.len > s.editor.currentLine

    let html = debugHtml(readyTx)
    # The pane emits one panel per document, so the ids are scoped to the
    # ACTIVE document's own file before position within it is asserted.
    let prefix = "L-" & pathSlug(full.path) & "-"
    let ids = idsInOrder(html, "L-").filterIt(it.startsWith(prefix))
    # EVERY LINE, counted, and the count asserted against the file's own length
    # rather than against a number written here. `>= 1` would pass over a
    # one-line render; `== full.lines.len` is the only relation that separates
    # "whole file" from "some of it", and it is the assertion the old window
    # would have reddened.
    check ids.len == full.lines.len
    check ids[0] == lineAnchor(full.path, 1)
    check ids[^1] == lineAnchor(full.path, full.lines.len)

    let cur = lineAnchor(full.path, s.editor.currentLine)
    check cur in ids
    # …and it is NOT near the top any more, which is what makes the autofocus
    # below load-bearing rather than redundant. If the fixture's position ever
    # migrates into the first few rows this assertion fails loudly instead of
    # letting the next one pass for the wrong reason.
    check ids.find(cur) > 8

    # THE ROW THE BROWSER OPENS AT. One `autofocus` in the whole page — a second
    # would mean the browser honoured whichever came first, which on a document
    # rendered from line 1 is the defect inverted — and it is on the position
    # cell of the row whose number is the session's.
    check occurrences(html, "autofocus=\"autofocus\"") == 1
    check ("aria-label=\"the session is stopped on line " &
           $s.editor.currentLine & "\"") in html
    # Nothing was dropped, so nothing is announced. Asserted AFTER the count
    # above and never instead of it: a file SHORTER than the old window carried
    # no banner either, so an absent banner on its own proves nothing.
    # The MARKUP and not the sentence. This asserted the retired wording
    # "Showing from line", which no longer appears anywhere however the pane
    # behaves, so it had become a check that could not fail. `<div
    # class="srcfrom">` is the notice itself and is wording-independent; the
    # opening tag rather than the bare class name, because this page inlines a
    # stylesheet that declares `.srcfrom` and a substring test would be
    # answered by the CSS.
    check "<div class=\"srcfrom\">" notin html

  test "every file the tab strip names is reachable":
    ## The strip listed the published bundle's four files and exactly one of
    ## them could be opened — the other three were inert `<span>`s. A tab that
    ## names a file it cannot open is an affordance that lies, which is the
    ## same defect class as the toolbar this page is careful to render inert.
    let s = sessionFor(readyTx)
    let docs = s.editor.documents
    check docs.len > 1          # or the test proves nothing
    let html = debugHtml(readyTx)
    for d in docs:
      # a panel to land in …
      check ("id=\"" & docAnchor(d.path) & "\"") in html
      # … and a link that goes there.
      check ("href=\"#" & docAnchor(d.path) & "\"") in html
    # No inert tab left behind.
    check "<span class=\"srctab" notin html

  # ── the second view is an AGGREGATION, not an ordering ───────────────────
  #
  # The research finding this replaced: Chrome DevTools' `Bottom-up` view is an
  # aggregation of self cost per FUNCTION, and "sorting 500 frames gives 500
  # rows in a new order while aggregating gives ~30 and the top row is the
  # answer". The old view sorted. These tests are written so that a
  # re-introduced sort fails them: a sort cannot reduce the row count and
  # cannot produce a call count.

  proc selfCostView(html: string): string =
    let at = html.find("id=\"" & dbgc.SelfCostViewId & "\"")
    doAssert at > 0, "the self-cost view is not in the rendered page"
    let rest = html[at .. ^1]
    rest[0 ..< rest.find("ctview def")]

  test "the second call-trace view is a real `:target` view, not a styled span":
    ## It was accent-coloured, underlined, and a `<span>` with nothing behind
    ## it. It is a link that switches a view.
    let html = debugHtml(readyTx)
    check ("href=\"#" & dbgc.SelfCostViewId & "\"") in html
    check ("id=\"" & dbgc.SelfCostViewId & "\"") in html
    check "<span class=\"ctsort" notin html

  test "the self-cost view AGGREGATES by function — fewer rows than frames":
    let s = sessionFor(readyTx)
    let rows = selfCostRows(s.calltrace)
    # The fixture has to contain a repeated function or this proves nothing
    # about aggregation: with all-distinct names an aggregation and a sort
    # produce the same row count.
    check s.calltrace.frames.len > 0
    check rows.len > 0
    check rows.len < s.calltrace.frames.len
    var repeated = 0
    for r in rows:
      if r.calls > 1: inc repeated
    check repeated > 0

    let view = selfCostView(debugHtml(readyTx))
    # One row per function, not one per frame. Counted in the MARKUP, so a
    # renderer that aggregated the data and then emitted every frame fails.
    # `class="ctrow ` with the trailing space: `class="ctrows"` — the
    # container — is a prefix of the row class and would be counted as a row.
    check occurrences(view, "class=\"ctrow ") == rows.len
    for r in rows:
      check r.fn in view
    # The call count is rendered, which a sorted frame list has no way to show.
    check "Calls" in view
    for r in rows:
      if r.calls > 1:
        check ("class=\"ctcalls num\">" & $r.calls) in view

  test "self cost is the frame's own cost, with its direct callees taken out":
    ## The arithmetic, against an INDEPENDENT hand-computation over the same
    ## frames — not against `selfCost` calling itself. A view that summed
    ## INCLUSIVE cost would rank the entry point first on every trace ever
    ## recorded, which is the answer that is always true and never useful.
    let s = sessionFor(readyTx)
    let frames = s.calltrace.frames
    check frames.len > 3

    proc inclusive(f: CallFrame): int =
      for c in f.cost:
        if c in {'0'..'9'}: result = result * 10 + (ord(c) - ord('0'))

    var expected: seq[tuple[fn: string, calls, cost: int]]
    for i, f in frames:
      var own = inclusive(f)
      # Direct children: the run after `i` at depth+1, up to the first frame at
      # `f.depth` or shallower. Written out here rather than shared with the
      # implementation.
      var j = i + 1
      while j < frames.len and frames[j].depth > f.depth:
        if frames[j].depth == f.depth + 1: own -= inclusive(frames[j])
        inc j
      var at = -1
      for k in 0 ..< expected.len:
        if expected[k].fn == f.fn: at = k
      if at < 0:
        expected.add (f.fn, 0, 0)
        at = expected.len - 1
      expected[at].calls += 1
      expected[at].cost += own

    let rows = selfCostRows(s.calltrace)
    check rows.len == expected.len
    for e in expected:
      var found = false
      for r in rows:
        if r.fn == e.fn:
          found = true
          check r.calls == e.calls
          check r.cost == e.cost
      check found

    # The entry frame carries the whole trace inclusively and must NOT top the
    # ranking on self cost — the difference between the two views, in one
    # assertion over this fixture.
    check frames[0].depth == 0
    check inclusive(frames[0]) == frames.mapIt(inclusive(it)).max
    check rows[0].fn != frames[0].fn

  test "the self-cost view is ranked, and is flat":
    let html = debugHtml(readyTx)
    let view = selfCostView(html)
    let rows = selfCostRows(sessionFor(readyTx).calltrace)
    check rows.len > 1
    var last = high(int)
    for r in rows:
      check r.cost <= last
      last = r.cost
    # Rendered in that order.
    check view.find(rows[0].fn) < view.find(rows[^1].fn)
    # Flat: a function is not a frame and has no depth, so an indent would draw
    # a structure that does not exist. (The same reasoning the cost-SORTED view
    # was given, which survived the change that made it moot.)
    check "ctrow d0 flat" in view
    for d in 1 .. 8:
      check ("ctrow d" & $d & " ") notin view

  test "an unmetered frame makes the total a stated FLOOR, never a silent sum":
    ## A cost column can carry `—`. Dropping such a frame silently would rank
    ## its function below one it may well exceed, and the number would look
    ## exactly like a total.
    var p = CallTracePane(costLabel: "ACIR", costUnit: "opcodes")
    p.frames = @[
      CallFrame(depth: 0, fn: "root", module: "m", cost: "100"),
      CallFrame(depth: 1, fn: "child", module: "m", cost: "40"),
      CallFrame(depth: 1, fn: "child", module: "m", cost: "—"),
    ]
    let rows = selfCostRows(p)
    check rows.len == 2
    for r in rows:
      if r.fn == "child":
        check r.calls == 2          # the unmetered frame is COUNTED
        check r.cost == 40
        check r.unmetered           # and the total says it is partial
      else:
        check not r.unmetered
    let markup = dbgc.renderCallTrace(p)
    check "ctcost num floor" in markup
    check "this total is a floor" in markup
    # And the control: an all-metered pane says nothing about floors, or the
    # assertion above would pass on every render.
    var metered = p
    metered.frames[2].cost = "10"
    check "ctcost num floor" notin dbgc.renderCallTrace(metered)

  test "depth beyond the indentation ladder is clamped AND marked":
    ## The renderer emitted `d6`, `d7`, … for any depth; the stylesheet had
    ## rules to `d5`. An out-of-ladder class resolves to NO indentation, so a
    ## trace deeper than the ladder rendered FLAT — indistinguishable on a
    ## screenshot from a correct shallow one. That is the density collapse
    ## `verify_debugger_holds_under_load` exists to rule out.
    check depthClass(0) == "d0"
    check depthClass(5) == "d5"
    check depthClass(MaxIndentDepth) == "d" & $MaxIndentDepth
    # Past the ladder: clamped to a class that HAS a rule, and marked.
    for d in (MaxIndentDepth + 1) .. (MaxIndentDepth + 40):
      let c = depthClass(d)
      check c == "d" & $MaxIndentDepth & " deeper"
    # Every class the renderer can emit has an indentation rule behind it.
    for d in 0 .. (MaxIndentDepth + 40):
      let cls = depthClass(d).split(' ')[0]
      check (".ctrow." & cls & " .ctfn{padding-left") in debugRouteCss or cls == "d0"
      check (".strow." & cls & "{padding-left") in debugRouteCss or cls == "d0"

  test "the scrubber marks the NEAREST tick, and never rounds up to the end":
    ## `int()` truncates, and truncation biases every reading in one direction:
    ## the fixture sits at step 128 of 1315 = 9.73%, which truncated to tick 4
    ## of 48 and read as 8.33%. A scrubber whose only job is to say WHERE in
    ## the trace the session is may not be systematically early.
    ##
    ## The exception is the last tick, which is not a measurement but the claim
    ## that the trace has ENDED. That claim must come from `fraction == 1.0`
    ## and never from rounding, so 47/48 is the most a mid-trace step can show.
    proc atTick(step, total: int): int =
      ## The tick index the renderer marks with `.at`, read back out of the
      ## markup rather than recomputed — so this tests the renderer, not a
      ## copy of its arithmetic.
      var p = DebugControlsPane(step: step, totalSteps: total, positioned: true)
      let html = renderControls(p)
      var i = 0
      for chunk in html.split("<span class=\"tick"):
        if chunk.startsWith(" at\""): return i
        inc i
      -1

    # The fixture's own position: 128/1315 = 9.73%, which is nearer 5/48
    # (10.42%) than 4/48 (8.33%). It used to report 4.
    check atTick(128, 1315) == 5
    # The boundary either side of a half-tick, to pin the rounding direction.
    check atTick(1, 96) == 1           # 0.52 of a tick, rounds to the floor 1
    check atTick(3, 96) == 2           # 1.5 ticks exactly, rounds up
    # Never past the end, and never AT the end unless the trace is at the end.
    #
    # WHICH STEP *IS* THE END WAS WRONG HERE, and the correction is the whole
    # of the change to this case. It read 1314 as mid-trace and 1315 as the
    # end — but `totalSteps` is a COUNT over zero-based coordinates, so a
    # 1315-step recording's last coordinate is 1314 and 1315 is one past the
    # end. It is not merely absent: asking the engine for it PANICS the WASM
    # module and ends the session (`session_view.lastStep`). So the step this
    # case pinned as "the end" is a step no session can be at, and the step it
    # pinned as mid-trace is the end.
    check atTick(1313, 1315) == 47     # one before the last coordinate
    check atTick(1314, 1315) == 48     # …which IS the end of this recording
    # Past the end still clamps rather than drawing off the track — kept
    # because `data-step` is read from the DOM and a stale or hand-edited
    # value must not produce a 49th tick.
    check atTick(1315, 1315) == 48
    check atTick(9_999, 1315) == 48    # `fraction` clamps, and so does this
    # A positioned session always shows a mark, however early it is.
    check atTick(1, 1_000_000) == 1
    # And an unpositioned one shows none at all — no mark is a claim too.
    let none = renderControls(DebugControlsPane(step: 0, totalSteps: 1315))
    check "tick at\"" notin none
    check "tick on\"" notin none

  test "the metadata pane offers no control the page cannot honour":
    ## The `×` had nothing behind it — this page ships no JavaScript — and it
    ## was the only pane header carrying one. Dismissing it would also violate
    ## this route's own invariant that the metadata pane is present in every
    ## state.
    for hash in [readyTx, divergentTx]:
      let html = debugHtml(hash)
      check "panedismiss" notin html
      check "pane-metadata" in html

  test "no position anywhere in a file narrows what the pane renders":
    ## The negative, generalised. It used to say "a document whose position is
    ## near the top is NOT windowed" and drive `openAtCurrent` with
    ## `currentLine = 3` — the one case where the old lead-in happened to be a
    ## no-op. Every OTHER position was a reduction, which is the defect.
    ##
    ## So it is asked of every line in the file, not of the one that used to be
    ## safe: wherever the session stands, the pane emits the same rows.
    let base = sessionFor(readyTx).editor
    let want = activeDocument(base).lines.len
    check want > 20          # or this quantifies over nothing worth quantifying
    var asked = 0
    for line in 1 .. want:
      var e = base
      e.currentLine = line
      for i in 0 ..< e.documents.len:
        for j in 0 ..< e.documents[i].lines.len:
          e.documents[i].lines[j].current =
            e.documents[i].lines[j].number == line and i == e.activeIndex
      check activeDocument(e).lines.len == want
      check activeDocument(e).lines[0].number == 1
      # The markup, not the retired sentence — see the note at the "nothing
      # was dropped, so nothing is announced" check above.
      check dbgc.renderSource(e).contains("<div class=\"srcfrom\">") == false
      inc asked
    check asked == want

  test "narrowing the document to a window does not move a line's identity":
    # The property the anchors exist for. The home page's embed renders a
    # window; a link out of it must land on the same line of the full session.
    let s = sessionFor(readyTx)
    let windowed = windowAround(s.editor, radius = 5)
    check windowed.documents.len == 1
    check windowed.documents[0].lines.len <= 11
    let full = activeDocument(s.editor)
    for ln in windowed.documents[0].lines:
      var found = false
      for orig in full.lines:
        if orig.number == ln.number:
          check orig.anchor == ln.anchor
          found = true
      check found

  test "the current line is marked, and it is exactly one line":
    let s = sessionFor(readyTx)
    var currents = 0
    for d in s.editor.documents:
      for ln in d.lines:
        if ln.current: inc currents
    check currents == 1
    check occurrences(debugHtml(readyTx), "class=\"srcline cur") == 1

  test "executed lines are data, not a heuristic over the text":
    # A pane that marked "every non-blank line" would look right and be wrong.
    let s = sessionFor(readyTx)
    let doc = activeDocument(s.editor)
    var executed, nonBlank = 0
    for ln in doc.lines:
      if ln.executed: inc executed
      if ln.text.strip.len > 0: inc nonBlank
    check executed > 0
    check executed < nonBlank

    # Stronger, and tied to the program on screen. The session sits at
    # `src/shield.nr:32`, in the `else` of `if (shield_pct == 100)`. Both arms
    # are on the path — iterations 0 and 1 run at 100% shields and take line 29
    # — while line 35's clamp is never reached, because no iteration does more
    # damage than the shield has left. A marker derived from anything but the
    # control flow gets at least one of those three wrong.
    var hit: Table[int, bool]
    for ln in doc.lines: hit[ln.number] = ln.executed
    check doc.path == "src/shield.nr"
    check hit[32]                       # the current line
    check hit[29]                       # the other arm, taken earlier
    check not hit[35]                   # the clamp, never taken
    check not hit[19]                   # after the loop, not reached yet
    # A call site marked executed above an unmarked body is a contradiction a
    # reader can see. Line 11 calls `calculate_shield_regeneration`; 42 is its
    # first statement.
    check hit[11] == hit[42]
    check hit[11]

  test "an overlay attaches to a line without replacing it":
    # The structural half of the omniscience claim, kept as its own test because
    # it is the one a future change to `renderSource` would break silently: an
    # overlay must be ADDITIVE. The suite below asserts what the labels say;
    # this asserts that saying it costs the line nothing.
    let s = sessionFor(readyTx)
    var pane = s.editor
    var bare = pane
    for d in 0 ..< bare.documents.len:
      for i in 0 ..< bare.documents[d].lines.len:
        bare.documents[d].lines[i].annotations = @[]
    bare.flow = FlowRail()
    let before = dbgc.renderSource(bare)
    check "class=\"ann\"" notin before
    # No value chip of any kind. `class="fv ` is the prefix of every one of
    # them and of nothing else, so this is the whole overlay counted rather
    # than one class of it named.
    check occurrences(before, "class=\"fv ") == 0

    var doc = activeDocument(bare)
    let target = doc.lines[2].number
    let anchor = doc.lines[2].anchor
    doc.annotate(target, LineAnnotation(slot: asTrailing, column: -1,
                                        label: "remaining_shield",
                                        beforeValue: "10000",
                                        afterValue: "9000",
                                        mode: vmChanged,
                                        iteration: -1))
    bare.documents[bare.activeIndex] = doc
    let after = dbgc.renderSource(bare)
    check "class=\"ann\"" in after
    check "title=\"remaining_shield: 10000 \u2192 9000\"" in after
    # ONE annotation was added, so exactly one chip appeared. Counted, because
    # the assertion above is satisfied by a renderer that draws the label twice
    # and by one that draws it beside a chip nobody asked for.
    check occurrences(after, "class=\"fv ") ==
          occurrences(before, "class=\"fv ") + 1
    # The line kept its identity: an overlay attaches to the line, it does not
    # replace it.
    check ("id=\"" & anchor & "\"") in after
    check occurrences(after, "class=\"srcline") ==
          occurrences(before, "class=\"srcline")

  test "a published source bundle outranks the client's fixture sources":
    # Trace-Artifacts §4: the manifest's recommendation is "the interpretation
    # the page should use". M5c publishes bundles for the traced program, so
    # the ranking is the route's REAL path here, not only a direct call: the
    # tree's bundle carries `Nargo.toml` and `Prover.toml` beside the two Noir
    # files, and the fixture copies vendored beside the client do not.
    let s = sessionFor(readyTx)
    var bundlePaths: seq[string]
    for d in s.editor.documents: bundlePaths.add d.path
    check "Prover.toml" in bundlePaths
    check "src/shield.nr" in bundlePaths

    # ...and the bundle supplied TEXT, not a session. The trace's markers and
    # its position survived the substitution — the defect this asserts against
    # is a pane that renders published source as code that never ran.
    check s.editor.currentLine > 0
    check activeDocument(s.editor).path == "src/shield.nr"

    var withBundle = s
    withPublishedSources(withBundle, %*{
      "language": "noir",
      "sources": {"src/only.nr": {"content": "fn only() {}\n"}}})
    check withBundle.editor.documents.len == 1
    check withBundle.editor.documents[0].path == "src/only.nr"
    check withBundle.editor.documents[0].lines[0].text == "fn only() {}"
    # The bundle declared `noir`, so its text is lexed by the same profile the
    # vendored fixture sources get. The substitution changes where the text
    # came from and never how it is rendered — a bundle whose content arrived
    # as plain text while the fixture's was highlighted would be a visible
    # inconsistency between two paths that are supposed to be one.
    let onlyHtml = dbgc.renderSource(withBundle.editor)
    check "<span class=\"tk-keyword\">fn</span>" in onlyHtml
    check "<span class=\"tk-function\">only</span>" in onlyHtml
    # A bundle that resolves to nothing usable is IGNORED, never allowed to
    # empty a pane that had content.
    var withJunk = s
    withPublishedSources(withJunk, %*{"sources": {}})
    check withJunk.editor.documents.len == s.editor.documents.len

suite "§7.0 — the transaction page IS the debugger's first frame":
  ## "The transaction page is not a waiting room before the debugger; it is the
  ## debugger's first frame." The four assertions below are §7.0's table, read
  ## off the transaction's OWN URL — the address the divergence was at.

  test "a ready transaction's own URL serves the session, not a page about it":
    let html = txHtml(readyTx)
    check isSession(html)
    # The register follows the surface: this document is the product lineage,
    # and the explorer chrome §8 collapses is gone from it.
    check "<html lang=\"en\" data-register=\"debugger\">" in html
    check "<html lang=\"en\" data-register=\"explorer\">" notin html
    check "class=\"nav\"" notin markup(html)
    # …and it is a POSITIONED frame, not an empty debugger shell: exactly one
    # marked line, and it is the statement the fixture position names. Asserted
    # on the STATEMENT rather than on the enclosing function's signature,
    # because the source window opens on the position and elides what is above
    # it — a signature is not guaranteed to be inside the window, and the
    # positioned line always is.
    check occurrences(html, "class=\"srcline cur") == 1
    # Through `codeLines`, because the statement is a run of highlighted spans
    # in the served bytes rather than a contiguous string.
    check "        damage = mass * (100 - shield_pct);" in codeLines(html)
    check "id=\"L-src-shield-nr-32\"" in html   # demo_session's FixtureLine

  test "a divergent transaction's own URL serves it too, with the banner":
    let html = txHtml(divergentTx)
    check isSession(html)
    check "class=\"dbgbanner bad\"" in html
    check "Divergent trace" in html

  test "there is no Debug button, because arriving IS the primary action":
    # The divergence in one assertion. "A button that opens the debugger is a
    # link to the primary action, not the primary action" — so on a page that
    # IS the primary action there is neither the button nor its destination.
    for h in [readyTx, divergentTx]:
      let body = markup(txHtml(h))
      check ">Debug<" notin body
      check ">Debug (divergent)<" notin body
      check ("href=\"" & txUrl(Chain, h) & "/debug\"") notin body
      # …and the waiting room's copy went with it. "A recorded trace is
      # published — Debug loads it immediately and anonymously" was a sentence
      # about a button, on a page whose whole job was to carry that button.
      # (`Trace ready` survives, in the metadata pane's execution list, where
      # it is a fact about an execution rather than a caption for an action.)
      check "Debug loads it immediately" notin body
      check availabilityNote(taReady) notin body

  test "an ABSENT trace is NOT the session, and pretends nothing":
    # The negative half, over a real tree whose published availability is
    # `absent` (see `degrade`/`requireDegraded`). §7.0: "the metadata, with the
    # reason stated. No debugger, and no pretence of one."
    let html = txHtmlIn(degradedRoot, absentTx)
    let body = markup(html)
    check hasNoSessionMarker(html)
    check "<html lang=\"en\" data-register=\"explorer\">" in html
    check "<html lang=\"en\" data-register=\"debugger\">" notin html
    # The reason is stated — BOTH halves of it, and the split is the point.
    # The enum's sentence says only what is true of every absent execution
    # (permanent, not a failed fetch); the cause comes from the PUBLISHED
    # reason. A generic line that named a cause would be wrong for the other
    # kind of absence — a settled transaction whose body has been pruned past
    # the retention horizon — so this asserts the generic line does NOT claim
    # one, and that the specific one is present.
    check availabilityNote(taAbsent) in body
    check "permanent answer rather than a failed fetch" in body
    check "no call structure" notin availabilityNote(taAbsent)
    check AbsentReason in body
    check availabilityState(taAbsent) in body
    # …and there is no control at all, not even a disabled one. A greyed
    # button still occupies the primary action's position and still invites
    # the click it will refuse.
    check "<button" notin body
    check ">Debug<" notin body
    # The transaction itself is complete: §14.1a's "the page never degrades".
    check "<h2 class=\"sec-title next\">Overview</h2>" in body
    check "class=\"raw\"" in body
    # …and the trace-derived sections say NOT EVER rather than not yet.
    # §14.1a: presenting either as the other is the failure it exists to
    # prevent, and "they appear here once this transaction has a recorded
    # trace" is a promise nothing can keep for a structurally absent execution.
    check "empty permanently, not yet" in body
    check "once this transaction has a recorded trace" notin body
    check "Internal calls and state changes come from the execution trace." notin body

  test "an UNSUPPORTED trace is NOT the session either":
    let html = txHtmlIn(degradedRoot, unsupportedTx)
    let body = markup(html)
    check hasNoSessionMarker(html)
    check "No recorder exists for this VM yet" in body
    check availabilityState(taUnsupported) in body
    check "<button" notin body
    check "<h2 class=\"sec-title next\">Overview</h2>" in body
    check "no trace can be produced and this section stays empty" in body
    check "once this transaction has a recorded trace" notin body

  test "on-demand is the metadata and the generate action, and no debugger":
    let html = txHtml(onDemandTx)
    let body = markup(html)
    check hasNoSessionMarker(html)
    check availabilityLabel(taOnDemand) in body      # "Generate trace"
    check "it needs an account" in body
    check "<h2 class=\"sec-title next\">Overview</h2>" in body
    # …and this row DOES get §7.2's converting line, beside the action that
    # requests the trace, because on this row a trace can still be had.
    check "Internal calls and state changes come from the execution trace." in body
    check "once this transaction has a recorded trace" in body

  test "the availability decides it, exhaustively, over both trees":
    # Every transaction in both trees, checked against ground truth read out of
    # the overlay JSON. The counters make the loop's own coverage visible, so
    # this cannot pass by never reaching a branch.
    var landings: Table[string, int]
    for (r, dir) in [(root, workDir), (degradedRoot, degradedDir)]:
      for h in txHashes:
        let want = headlineIn(dir, h)
        let html = txHtmlIn(r, h)
        case want
        of "ready", "divergent": check isSession(html)
        else: check hasNoSessionMarker(html)
        landings.mgetOrPut(want, 0) += 1
    for want in ["ready", "divergent", "onDemand", "absent", "unsupported"]:
      check landings.getOrDefault(want, 0) > 0

  test "both addresses reach the SAME session, not two renderings of one":
    # §7.0: "Both addresses reach the same session; they differ in what the
    # visitor asked for." Checked as an equality of the served BODIES, which is
    # the only form of that claim a second renderer could not satisfy by
    # accident.
    for h in [readyTx, divergentTx]:
      let atTx = txHtml(h)
      let atDebug = debugHtml(h)
      check atTx.split("</head>")[1] == atDebug.split("</head>")[1]
      # What they differ in is what the visitor ASKED FOR, and it is confined
      # to the two head elements that describe the request: the title and the
      # description. Enumerated rather than described, so a third difference
      # growing into the head fails here instead of being discovered later —
      # `robots`, `canonical`, the viewport and the inlined stylesheet are the
      # crawl surface, and they must be the same bytes on both addresses.
      var headTx = atTx.split("</head>")[0]
      var headDebug = atDebug.split("</head>")[0]
      for tag in ["<title>", "<meta name=\"description\" content=\""]:
        for doc in [headTx.addr, headDebug.addr]:
          let at = doc[].find(tag)
          check at >= 0
          let stop = doc[].find((if tag == "<title>": "</title>" else: "\" />"),
                                at)
          doc[] = doc[][0 ..< at] & doc[][stop .. ^1]
      check headTx == headDebug
      check "<title>Transaction " in atTx
      check "<title>Debug " in atDebug
      check ("<link rel=\"canonical\" href=\"" & SiteDomain & "/" & Chain &
             "/tx/" & h & "\"") in atTx
      check ("<link rel=\"canonical\" href=\"" & SiteDomain & "/" & Chain &
             "/tx/" & h & "\"") in atDebug

  test "the transaction route is still the SUBMITTED address; /debug is not":
    # The pair that makes the two addresses different where it matters. Both
    # render; only the transaction's own URL is offered to a crawler.
    let submitted = sitemapRoutes(root)
    for h in txHashes:
      check ("/" & Chain & "/tx/" & h) in submitted
      check ("/" & Chain & "/tx/" & h & "/debug") notin submitted
      check ("/" & Chain & "/tx/" & h & "/debug") in staticRoutes(root)

  test "§7.0's non-session rows cannot be served the waiting room by accident":
    # `pages/tx.nim` REFUSES to render a transaction whose trace is published,
    # rather than trusting the router to route. Without this, reinstating the
    # divergence would be a one-line change in `ssr.renderTx` that no test
    # could see, because the old page would still render perfectly well.
    let info = chainInfo(root, Chain)
    expect ValueError:
      discard txPg.txPage(Chain, txView(root, info, readyTx), info)
    expect ValueError:
      discard txPg.txPage(Chain, txView(root, info, divergentTx), info)
    # …and it renders the rows that have no session, so the refusal is
    # specific rather than a page that never renders at all.
    check txPg.txPage(Chain, txView(root, info, onDemandTx), info).len > 0


suite "VD.5 — the source pane is syntax highlighted, at export time":

  # The subject is the REAL recorded program. `shieldSource` is the same
  # `src/shield.nr` the `zk_shields` trace was recorded from and that the demo
  # session renders — read from disk rather than retyped, so a test cannot
  # quietly assert against a convenient sample that the product never shows.
  let shieldSource = readFile(fixtureSources / "src" / "shield.nr")
  let shieldDoc = newSourceDocument("src/shield.nr", "noir", shieldSource)

  proc tokensOn(doc: SourceDocument; line: int): seq[SourceToken] =
    for ln in doc.lines:
      if ln.number == line: return ln.tokens

  proc textOf(doc: SourceDocument; line: int; kind: TokenKind): seq[string] =
    for t in tokensOn(doc, line):
      if t.kind == kind: result.add t.text

  test "the recorded program's keywords, types and calls are classified":
    # shield.nr:1 — `pub fn iterate_asteroids(initial_shield: Field, …) -> bool {`
    # One line carrying four of the eight kinds is worth more than four lines
    # carrying one each: it is where a lexer that decides a kind from the word
    # alone and one that also looks at its neighbours give different answers.
    check textOf(shieldDoc, 1, tkKeyword) == @["pub", "fn"]
    check textOf(shieldDoc, 1, tkFunction) == @["iterate_asteroids"]
    check textOf(shieldDoc, 1, tkType) == @["Field", "Field", "Field", "bool"]
    check textOf(shieldDoc, 1, tkNumber) == @["8"]

    # `println` is a call and not a keyword; `assert` is a keyword even though
    # it is also followed by `(`. A lexer that decided "followed by ( ⇒
    # function" before consulting the word list would get the second wrong.
    check textOf(shieldDoc, 54, tkFunction) == @["println"]

  test "strings, numbers and comments are classified over the real source":
    # shield.nr:54 — `println(f"----- iteration {iteration} -----");`
    # The `f` prefix belongs to the literal. A lexer that took it as an
    # identifier would emit a stray name before every format string in the
    # file, and shield.nr is full of them.
    check textOf(shieldDoc, 54, tkString) ==
          @["f\"----- iteration {iteration} -----\""]

    # shield.nr:17 is a whole-line comment; the text is carried verbatim,
    # leading delimiter included.
    let comments = textOf(shieldDoc, 17, tkComment)
    check comments.len == 1
    check comments[0].startsWith("// We need to have at least 1 unit")

    # shield.nr:4 — `for i in 0..8 {`. The range operator must NOT be eaten by
    # the number scanner: `0..8` is two numbers around a `..`, not one broken
    # float. This is the single most likely lexer defect on this file.
    check textOf(shieldDoc, 4, tkNumber) == @["0", "8"]
    check ".." in textOf(shieldDoc, 4, tkPunctuation)
    check textOf(shieldDoc, 4, tkKeyword) == @["for", "in"]

  test "every character of every line survives tokenisation, exactly":
    # The invariant that makes highlighting safe: the tokens PARTITION the
    # line. A lexer that dropped a character, or normalised whitespace, would
    # render source that is not the source — a worse failure than no
    # highlighting, because the pane would still look authoritative.
    var lexedLines = 0
    for path in ["src/shield.nr", "src/main.nr"]:
      let doc = newSourceDocument(
        path, "noir", readFile(fixtureSources / path))
      check doc.lines.len > 0
      for ln in doc.lines:
        check ln.tokens.len > 0 or ln.text.len == 0
        var joined = ""
        for t in ln.tokens: joined.add t.text
        check joined == ln.text
        inc lexedLines
    # Guard against the suite passing because both files lexed to nothing.
    check lexedLines >= 100

  test "an unknown language renders plain — it is never guessed at":
    # Trace-Artifacts and §14: a bundle from a chain whose language has no
    # profile is the ordinary case, not an error. A Noir lexer over Solidity
    # would produce confident nonsense, so it is not applied.
    let solidity = newSourceDocument(
      "Vault.sol", "solidity",
      "// SPDX-License-Identifier: MIT\ncontract Vault { uint256 x = 1; }\n")
    check solidity.lines.len == 2
    for ln in solidity.lines:
      check ln.tokens.len == 0

    var pane = EditorPane(availability: srcSourceLevel,
                          documents: @[solidity], activeIndex: 0)
    let html = dbgc.renderSource(pane)
    # The text is all there, as the ONE text node it was before highlighting
    # existed — and carries no lexical class at all.
    check "contract Vault { uint256 x = 1; }" in html
    check "tk-keyword" notin html
    check "tk-comment" notin html
    check "tk-number" notin html

    # A file with NO declared language at all takes the same path.
    let unlabelled = newSourceDocument("blob.txt", "", "fn main() {}\n")
    check unlabelled.lines[0].tokens.len == 0

  test "a bundle's declared language does not lex the files that are not it":
    # A bundle carries ONE language (Source-Resolution §5 puts it on the bundle)
    # and is not all one language. The demo's own bundle declares `noir` and
    # ships `Nargo.toml` and `Prover.toml` beside the two `.nr` files — and
    # they were being lexed as Noir: `[package]` in punctuation colours and
    # `initial_shield = "10000"` as a Noir string literal. A manifest wearing
    # source highlighting is exactly the confident nonsense the fallback exists
    # to prevent, so the EXTENSION decides and the declared language is only
    # consulted when there is no extension at all.
    let manifest = newSourceDocument(
      "Nargo.toml", "noir", "[package]\nname = \"zk_shields\"\n")
    for ln in manifest.lines:
      check ln.tokens.len == 0
    let prover = newSourceDocument(
      "Prover.toml", "noir", "initial_shield = \"10000\"\n")
    check prover.lines[0].tokens.len == 0

    # ...while the .nr files in the SAME bundle are still highlighted.
    check newSourceDocument("src/shield.nr", "noir", "let x = 1;\n")
            .lines[0].tokens.len > 0
    # An extension is trusted over the declaration in both directions: a .nr
    # file in a bundle that forgot to declare a language is still Noir.
    check newSourceDocument("src/shield.nr", "", "let x = 1;\n")
            .lines[0].tokens.len > 0

    # And the route that actually serves the demo bundle carries both kinds.
    let s = sessionFor(readyTx)
    var sawToml, sawNoir = false
    for d in s.editor.documents:
      if d.path.endsWith(".toml"):
        sawToml = true
        for ln in d.lines: check ln.tokens.len == 0
      elif d.path.endsWith(".nr"):
        sawNoir = true
        var any = false
        for ln in d.lines:
          if ln.tokens.len > 0: any = true
        check any
    check sawToml     # the bundle really does carry a non-Noir file
    check sawNoir

  test "at instruction level there is no source, so nothing is tokenised":
    # §14's fidelity ladder. `srcUnverified` means code ran and nobody
    # published source for it: the pane shows a stated reason and the supply
    # action, and no lexer is reached at all. The anti-requirement is a pane
    # that renders a bytecode listing as though it were highlighted source.
    for level in [srcUnverified, srcAbsent]:
      let pane = EditorPane(availability: level,
                            reason: "No source is published for this code.")
      let html = dbgc.renderSource(pane)
      check "srcnone" in html
      check "tk-keyword" notin html
      check "tk-punct" notin html
      check "class=\"srcline" notin html

    # And the ladder is legible in the route the visitor actually gets.
    # Matching on `class="tk-…"` and not on the bare name: the page inlines the
    # stylesheet, so every rule's SELECTOR is in the markup whether or not
    # anything is highlighted. A test that missed this would pass on a page
    # with no source pane for the wrong reason, and keep passing if one
    # appeared.
    let s = sessionFor(onDemandTx)
    check s.editor.availability != srcSourceLevel
    check "class=\"tk-keyword\"" notin debugHtml(onDemandTx)
    check "class=\"srcline" notin debugHtml(onDemandTx)

  test "every kind the lexer emits has a class AND a stylesheet rule":
    # `tokenClass` and `debugger_css` are the one place the mapping can drift.
    # A kind with a class but no rule renders as unremarkable text while the
    # lexer reports success — invisible in every test that only asserts kinds.
    for kind in TokenKind:
      let cls = dbgc.tokenClass(kind)
      if kind == tkPlain:
        check cls == ""          # emitted as a bare text node, by design
      else:
        check cls.len > 0
        check ("." & cls & "{") in debugRouteCss or
              ("." & cls & ",") in debugRouteCss
        # ...and the rule resolves to a design token, never a raw colour.
        check ("--bt-syntax-") in debugRouteCss

    # The other direction: no orphan rule for a class nothing can emit.
    var emitted: seq[string]
    for kind in TokenKind:
      if kind != tkPlain: emitted.add dbgc.tokenClass(kind)
    var i = 0
    while true:
      let at = debugRouteCss.find(".tk-", i)
      if at < 0: break
      let stop = debugRouteCss.find({'{', ',', ' '}, at)
      check debugRouteCss[at + 1 ..< stop] in emitted
      i = stop

  test "a second language is DATA, not another branch in the lexer":
    # The seam. BlockTracer will need Solidity, Move and Cadence; the claim is
    # that each is a `LanguageProfile` literal and no code change. Proving it
    # with a profile built here — not by shipping one and asserting it exists —
    # is what keeps the claim honest while only Noir is genuinely supported.
    let toy = LanguageProfile(
      names: @["toy"],
      identifierStart: {'a'..'z'},
      identifierBody: {'a'..'z', '0'..'9'},
      keywords: @["begin", "end"],
      types: @["num"],
      functionKeywords: @["begin"],
      lineComment: "#",
      stringDelimiters: {'\''},
      escape: '\\')
    let lines = highlightLines(@["begin adder # go", "x: num = 'hi'"], toy)
    check lines.len == 2
    var kinds: seq[TokenKind]
    for t in lines[0]: kinds.add t.kind
    check tkKeyword in kinds        # `begin`
    check tkFunction in kinds       # `adder`, because `begin` declares one
    check tkComment in kinds        # `# go`, this language's line comment
    var second: seq[TokenKind]
    for t in lines[1]: second.add t.kind
    check tkType in second          # `num`
    check tkString in second        # `'hi'`, this language's quote

    # The registry itself claims only what can be demonstrated.
    check KnownLanguages.len == 1
    check profileFor("noir").isKnown
    check not profileFor("solidity").isKnown
    check profileFor("NOIR").isKnown          # matching is case-insensitive

  test "highlighting escapes, and does not disturb ids or the overlay slot":
    # The parallel omniscience workstream depends on both, and this is the
    # change most likely to have broken them.
    let s = sessionFor(readyTx)
    var pane = s.editor
    let html = dbgc.renderSource(pane)
    for ln in activeDocument(pane).lines:
      check ("id=\"" & ln.anchor & "\"") in html
    check "class=\"srcline" in html

    # Narrowing copies lines into a new document; the tokens travel with them,
    # so a window is not silently unhighlighted.
    let windowed = windowAround(pane, 3)
    let wdoc = activeDocument(windowed)
    check wdoc.lines.len > 0
    var anyTokens = false
    for ln in wdoc.lines:
      if ln.tokens.len > 0: anyTokens = true
    check anyTokens
    check "tk-keyword" in dbgc.renderSource(windowed)

    # A token's text is ESCAPED by the renderer, exactly once. Source is
    # arbitrary text and `<` is a legal Noir operator.
    let sharp = newSourceDocument(
      "cmp.nr", "noir", "let ok = a < b && \"<script>\" != c;\n")
    var sharpPane = EditorPane(availability: srcSourceLevel,
                               documents: @[sharp], activeIndex: 0)
    let sharpHtml = dbgc.renderSource(sharpPane)
    check "<script>" notin sharpHtml
    check "&lt;script&gt;" in sharpHtml
    check "&amp;lt;" notin sharpHtml          # not double-escaped

  test "the served debug route is highlighted, in the markup a browser gets":
    # Everything above works on the renderer directly. This is the route.
    let html = debugHtml(readyTx)
    for cls in ["tk-keyword", "tk-type", "tk-function", "tk-string",
                "tk-number", "tk-comment", "tk-punct"]:
      check ("class=\"" & cls & "\"") in html
    # The pane still says which file it is showing, and still marks a position.
    check "src/shield.nr" in html
    check "class=\"srcline cur" in html

# ---------------------------------------------------------------------------
# Omniscience — inline values against the real recorded execution
# ---------------------------------------------------------------------------

proc flowPane(): EditorPane =
  ## The debug route's Code pane as the route builds it, unwindowed.
  sessionFor(readyTx).editor

proc annotationsAt(pane: EditorPane; path: string; line: int):
    seq[LineAnnotation] =
  for d in pane.documents:
    if d.path != path: continue
    for ln in d.lines:
      if ln.number == line: return ln.annotations
  @[]

proc labelAt(pane: EditorPane; line: int; expression: string;
             iteration: int): seq[LineAnnotation] =
  ## Every label for one expression, on one line, in one pass — in the order
  ## the renderer will draw them.
  for a in annotationsAt(pane, "src/shield.nr", line):
    if a.label == expression and a.iteration == iteration:
      result.add a

proc oneLabel(pane: EditorPane; line: int; expression: string;
              iteration: int): LineAnnotation =
  let all = labelAt(pane, line, expression, iteration)
  doAssert all.len == 1,
    "expected exactly one `" & expression & "` on line " & $line &
    " in pass " & $iteration & ", found " & $all.len &
    " — a test that accepted any number of them would pass over a duplicated" &
    " or a missing label alike"
  all[0]

proc sourceLineText(pane: EditorPane; line: int): string =
  for ln in activeDocument(pane).lines:
    if ln.number == line: return ln.text
  ""

proc asInt(s: string): int =
  ## A recorded value as a number, for the arithmetic checks below. Raises on
  ## anything else, which is the point: a label that stopped being a number is
  ## a label whose value has been mangled.
  parseInt(s.strip())

suite "Omniscience — the recorded values, against the real zk_shields trace":

  ## Everything in this suite is checked against the program in
  ## `client/fixtures/demo-session/src/shield.nr` and the arithmetic it
  ## performs — never against the fixture that feeds the overlay. `flow.json`
  ## is extracted from the real container by
  ## `client/fixtures/demo-session/extract-flow.mjs`, so asserting the labels
  ## match `flow.json` would assert a producer against its own input and could
  ## not fail. The invariants below are properties of the SOURCE CODE, and an
  ## overlay carrying plausible invented numbers fails every one of them.

  test "the trace's own compound assignments are on the lines that perform them":
    # `remaining_shield -= damage` (line 7) and `remaining_shield += regeneration`
    # (line 12) are the writes commit `906af2f42d` restored to the recorder; the
    # container's README says the fixture records 29 of these transitions. They
    # are the reason this program is the demo, and an overlay that showed the
    # shield frozen would be the bug that fix removed, drawn instead of stepped.
    let pane = flowPane()
    let hit = oneLabel(pane, 7, "remaining_shield", 0)
    check hit.mode == vmChanged
    check hit.beforeValue == "10000"
    check hit.afterValue == "9900"

    let regen = oneLabel(pane, 12, "remaining_shield", 0)
    check regen.mode == vmChanged
    check regen.beforeValue == "9900"
    check regen.afterValue == "10000"

  test "the labels satisfy the arithmetic of the line they sit on":
    # The strongest available check, and the one an invented overlay cannot
    # survive: every number is re-derived from OTHER numbers on the same line,
    # using the operation the source performs. It needs no fixture and no
    # recorded expectation — the program is the oracle.
    let pane = flowPane()
    var checkedPasses = 0
    for pass in 0 .. 1:                       # the passes this frame completed
      # line 7:  remaining_shield -= damage
      let shield = oneLabel(pane, 7, "remaining_shield", pass)
      let damage = oneLabel(pane, 7, "damage", pass)
      check asInt(shield.beforeValue) - asInt(damage.beforeValue) ==
            asInt(shield.afterValue)

      # line 12: remaining_shield += regeneration
      let grown = oneLabel(pane, 12, "remaining_shield", pass)
      let regeneration = oneLabel(pane, 12, "regeneration", pass)
      check asInt(grown.beforeValue) + asInt(regeneration.beforeValue) ==
            asInt(grown.afterValue)

      # And the two are the same variable across one pass: what line 7 left is
      # what line 12 found. A per-line overlay that read its values from
      # different passes would pass both lines above and fail this.
      check shield.afterValue == grown.beforeValue

      # line 29: damage = mass * 1, on the passes that took the 100% arm
      let dmg = oneLabel(pane, 29, "damage", pass)
      let mass = oneLabel(pane, 29, "mass", pass)
      check dmg.mode == vmChanged
      check asInt(dmg.afterValue) == asInt(mass.beforeValue)
      inc checkedPasses
    check checkedPasses == 2

    # line 32: damage = mass * (100 - shield_pct) — the OTHER arm, taken only in
    # the pass the session is in. Both arms of one conditional, each labelled on
    # exactly the passes that took it, is the property `executedLines()` states
    # in prose two files away.
    let d2 = oneLabel(pane, 32, "damage", 2)
    let m2 = oneLabel(pane, 32, "mass", 2)
    let pct2 = oneLabel(pane, 32, "shield_pct", 2)
    check asInt(m2.beforeValue) * (100 - asInt(pct2.beforeValue)) ==
          asInt(d2.afterValue)
    check labelAt(pane, 32, "damage", 0).len == 0
    check labelAt(pane, 29, "damage", 2).len == 0

  test "a value sits at the column its expression occupies in the source":
    # `flow_layout.findExpressionColumn` decides this and the column is
    # recomputed here from the rendered line's own text, independently. A label
    # anchored to the wrong offset is the failure the honesty constraint names
    # by name — "placed against the wrong expression".
    let pane = flowPane()
    for (line, expression) in [(7, "remaining_shield"), (7, "damage"),
                               (12, "regeneration"), (32, "shield_pct"),
                               (5, "mass"), (4, "i")]:
      let text = sourceLineText(pane, line)
      let expected = text.find(expression)
      check expected >= 0
      for a in annotationsAt(pane, "src/shield.nr", line):
        if a.label == expression:
          check a.slot == asInline
          check a.column == expected

  test "a line the loop ran twice in one pass keeps both values, in order":
    # `calculate_remaining_shield_pct` is called twice per pass — once from
    # `calculate_damage`, once from `status_report` — so line 49 genuinely has
    # two `result`s in pass 1. `flow_layout.orderIterationSteps` keeps execution
    # order, and the overlay must keep it too: 100 (at 100% shields) before 90
    # (after the second asteroid). Deduplicating to one would DROP a recorded
    # value, and reordering would report the pass running backwards.
    let pane = flowPane()
    let results = labelAt(pane, 49, "result", 1)
    check results.len == 2
    # `annotationText` and not a field: `let result = …` is the variable's FIRST
    # assignment, so there is no before-value and the mode is `vmAfter`. Reading
    # `beforeValue` here would compare two empty strings and pass whatever the
    # overlay said.
    check annotationText(results[0]) == "result=100"
    check annotationText(results[1]) == "result=90"

  test "a return value is a fact about the line, with no column and no name":
    # The spec's `[→230]`. It cannot travel as a `FlowLabel` at all —
    # `assignExpressionColumns` refuses an empty expression — so this is the
    # path that would silently disappear if the join were rewritten.
    let pane = flowPane()
    var returns: seq[LineAnnotation]
    for a in annotationsAt(pane, "src/shield.nr", 50):
      if a.label.len == 0: returns.add a
    check returns.len > 0
    for a in returns:
      check a.mode == vmAfter
      check a.slot == asTrailing
      check a.column == -1
      check annotationText(a).startsWith("→")
    # `calculate_remaining_shield_pct` returns the percentage, so the return on
    # pass 2 is the `shield_pct` `calculate_damage` then multiplies by.
    var pass2 = ""
    for a in returns:
      if a.iteration == 2: pass2 = a.afterValue
    check pass2 == oneLabel(pane, 32, "shield_pct", 2).beforeValue

  test "the overlay and the Values pane agree at the same coordinate":
    # Two producers, one frame. `demo_session.fixtureState` derives its numbers
    # by hand from the recorded inputs; the overlay reads them out of the
    # container. They are the same numbers or one of them is wrong, and a reader
    # looking at line 32 with the Values pane open can see which.
    let s = sessionFor(readyTx)
    var stateValues: Table[string, string]
    for v in s.state.values: stateValues[v.name] = v.value
    let pane = s.editor
    check oneLabel(pane, 32, "damage", 2).afterValue == stateValues["damage"]
    check oneLabel(pane, 32, "mass", 2).beforeValue == stateValues["mass"]
    check oneLabel(pane, 32, "shield_pct", 2).beforeValue ==
          stateValues["shield_pct"]
    # Line 22 is `calculate_damage`'s SIGNATURE: the frame has no variables on
    # the way in, so its parameters are after-values and read through
    # `annotationText` rather than off `beforeValue`.
    check annotationText(oneLabel(pane, 22, "remaining_shield", 2)) ==
          "remaining_shield=" & stateValues["remaining_shield"]
    check annotationText(oneLabel(pane, 22, "initial_shield", 2)) ==
          "initial_shield=" & stateValues["initial_shield"]

  test "the still frame carries nothing from after the position it claims":
    # Constraint: pre-hydration the page is a still frame at one coordinate, and
    # a value it shows must be a value at THAT coordinate. Passes 3..7 of the
    # loop happen later in the recording and are recorded in the container — and
    # are absent here, because at this position they have not happened.
    let pane = flowPane()
    var highest = -1
    for d in pane.documents:
      for ln in d.lines:
        for a in ln.annotations:
          if a.iteration > highest: highest = a.iteration
    check highest == pane.flow.active
    check pane.flow.active == 2

    # And the same rule in the other direction: the lines AFTER the loop
    # (`let result = remaining_shield as u32 > 0`) and the clamp arm the trace
    # never took carry nothing, however well the recorder knows their values.
    check annotationsAt(pane, "src/shield.nr", 18).len == 0
    check annotationsAt(pane, "src/shield.nr", 19).len == 0
    check annotationsAt(pane, "src/shield.nr", 35).len == 0

  test "every value the window records is drawn, and drawn once":
    # THE INVERSE of the five tests this replaces, and the reason they are gone.
    #
    # This suite used to grade a width budget: `flow_view.planElision` measured
    # each chip against the code pane's width in eight quantised regimes, drew a
    # prefix of each pass's labels and replaced the rest with a dashed `+N` chip
    # carrying them on `title`. The tests checked that the counts were honest —
    # and they were. What none of them asked was whether the page should be
    # withholding values at all. Counted over the exported demo session, it was
    # withholding 98 of 186 at the WIDEST pane it serves and all 186 below a
    # 515px one.
    #
    # CodeTracer desktop, which this pane's layout is vendored from, budgets
    # nothing: `ui/flow.nim:2191-2213` appends a chip for every entry of
    # `step.exprOrder` with no cap, `.flow-parallel` is
    # `overflow:visible !important` with no `max-width` and no `flex-wrap`
    # (`styles/components/text_editor.styl:307-312`), and
    # `ui/flow.nim:258-271` raises Monaco's `scrollBeyondLastColumn` so the
    # surplus is REACHED rather than removed. There is no `+N` in its debugger
    # at all.
    #
    # So the property is now the simple one: what the window recorded is what
    # the reader is given.
    #
    # ## Why this is asserted against the HTML and not against the pane
    #
    # Because the defect it rules out lived in the RENDERER. `planElision` wrote
    # a `bucket` onto each annotation and `renderAnnotations` skipped the ones it
    # did not like; `ln.annotations` carried every value throughout, so a check
    # that read the seq would have passed unchanged for the whole of that regime.
    # `class="fv ` is the prefix of every value chip and of nothing else.
    let pane = flowPane()
    let html = dbgc.renderSource(pane)
    var recorded = 0
    for d in pane.documents:
      for ln in d.lines:
        recorded += ln.annotations.len
    check recorded > 0
    check occurrences(html, "class=\"fv ") == recorded

  test "no value is summarised, counted or hidden behind a tooltip":
    # The user-visible half: none of the elision machinery's marks survive
    # anywhere on the served page. Named rather than counted, because these are
    # exactly the strings a reviewer would search for, and because each of them
    # is a separate way for the behaviour to come back — a chip (`fvmore`), a
    # row of its own (`fvrow`), a width gate on a label (`fvw`), a band on a
    # count (`fvr`/`fvs`), or the container query that switched them.
    let pane = flowPane()
    let html = dbgc.renderSource(pane)
    for mark in ["fvmore", "fvrow", "class=\"fvw", "class=\"fvr",
                 "fvs0", "+N"]:
      check mark notin html
    # …and the stylesheet neither styles nor generates them.
    for mark in ["fvmore", "fvrow", "fvw1", "fvr01", "fvs01",
                 "container-type", "@container"]:
      check mark notin debugRouteCss

  test "a line with more values than fit is wider, not emptier":
    # What replaces the budget. The desktop's answer to overflow is scroll, and
    # this pane was built for it: `.src` is `overflow:auto` and `.srcline` is
    # `min-width:max-content`, so a row carrying more labels is a WIDER row and
    # the pane reaches it. The labels cannot be separated from their line by
    # that scroll because they are items on the same flex row.
    #
    # Both halves are asserted because either alone permits the failure. Without
    # `max-content` the row is capped at the pane and the labels are clipped;
    # without `overflow:auto` the row is as wide as it likes and unreachable.
    check ".srcline{display:flex" in debugRouteCss
    check "min-width:max-content" in debugRouteCss
    check "flex:1 1 0;overflow:auto}" in debugRouteCss
    # And the run itself does not wrap or shrink — a wrapping `.ann` would put
    # a line's values on a row the line number does not reach.
    check "white-space:nowrap;\n  flex:0 0 auto}" in debugRouteCss

  test "the busiest line in the session keeps every one of its values":
    # The tests above are counts, and a count is satisfied by a page that
    # renders the right NUMBER of the wrong things. This one names the values:
    # it finds the line the demo session records the most of, and asserts each
    # of its labels is on the page by its own text.
    #
    # It is also the direct regression for the reported defect. Under the old
    # budget this line rendered as one `+N` chip at every pane width the route
    # serves, because its code alone overran the narrowest of them.
    let pane = flowPane()
    let html = dbgc.renderSource(pane)
    var busiest: SourceLine
    for d in pane.documents:
      for ln in d.lines:
        if ln.annotations.len > busiest.annotations.len: busiest = ln
    # The demo session has to HAVE a crowded line or every check below is
    # vacuous. Four is above what the narrowest regime ever drew.
    check busiest.annotations.len >= 4
    for a in busiest.annotations:
      # The value, not the whole label: `annotationText` is what `title`
      # carries and asserting it back would only be re-deriving the renderer's
      # own string. The VALUE is the fact the reader came for.
      let shown = (if a.mode == vmBefore: a.beforeValue else: a.afterValue)
      check (">" & shown & "<") in html

  test "no line carries a value the gutter says never executed":
    # The overlay and the executed-line set are two producers of "this ran", and
    # a page that disagreed with itself about that would be worse than either
    # answer alone. This is a cross-check, not a restatement: the executed set
    # is enumerated in `demo_session` and the overlay comes out of the container.
    let pane = flowPane()
    for d in pane.documents:
      for ln in d.lines:
        if ln.annotations.len > 0:
          check ln.executed

  test "the loop rail states which pass, out of how many, and where":
    let pane = flowPane()
    let rail = pane.flow
    check rail.loopIndex == 1
    check rail.line == 4                      # `for i in 0..8 {`
    check rail.label == "iterate_asteroids"
    check rail.anchor == lineAnchor("src/shield.nr", 4)
    check rail.iterations.len == 8            # the array has eight asteroids
    check rail.active == 2
    check rail.selected == rail.active
    # Reached versus recorded: three passes have happened at this coordinate.
    var reached = 0
    for it in rail.iterations:
      if it.reached: inc reached
    check reached == 3
    for it in rail.iterations:
      check it.reached == (it.index <= 2)
      # Every segment carries a real time coordinate — the pass's header tick —
      # which is what makes it deep-linkable and what hydration hands to
      # `ct/goto-ticks`. Strictly increasing, because the walker only moves
      # forward; a rail whose segments were numbered 1..8 with no ticks behind
      # them would look identical and be unable to navigate anywhere.
      check it.ticks > 0
    for i in 1 ..< rail.iterations.len:
      check rail.iterations[i].ticks > rail.iterations[i - 1].ticks

  test "the rail is rendered even though the loop's header is far off screen":
    # The reason the rail is on the PANE rather than on the loop's own line.
    # It used to be off-WINDOW — `openAtCurrent` served the pane from six lines
    # above line 32, so line 4 was not in the DOM at all. It is in the DOM now,
    # and twenty-eight rows above the position, which is well off screen at
    # every viewport this route is served at. A control drawn only at the header
    # would still be missing exactly when the reader is inside the loop.
    let s = sessionFor(readyTx)
    let windowed = s.editor
    check s.editor.currentLine - 4 > 20
    var first = 0
    for ln in activeDocument(windowed).lines:
      first = ln.number
      break
    check first == 1
    let html = dbgc.renderSource(windowed)
    check "class=\"flowrail\"" in html
    check "Iteration 3 of 8" in html
    # …and it links back to the header line, whose id is stable whether or not
    # the line is in this window.
    check ("href=\"#" & lineAnchor("src/shield.nr", 4) & "\"") in html

  test "exactly the session's pass is shown; the others are in the markup, inert":
    # The `:target` mechanism's contract, checked on the markup a browser gets.
    # Every pass the window carries is present — that is what makes the rail
    # work with no JavaScript — and exactly one is marked `now`, which is the
    # only one the stylesheet shows.
    let html = debugHtml(readyTx)
    check "class=\"fv inline m-changed fv-i0\"" in html      # pass 0, not shown
    check "class=\"fv inline m-changed fv-i2 now\"" in html  # pass 2, shown
    check "fv-i1 now" notin html
    check "fv-i0 now" notin html
    # The stylesheet is what enforces it, and it is checked in both directions:
    # the default is hidden, `.now` is shown, and a targeted pass swaps them.
    check ".fv{display:none" in debugRouteCss
    check ".fv.now{display:inline-flex}" in debugRouteCss

  test "every segment the rail can emit has a rung, and the rung switches":
    # `MaxStaticIterations` is read by the renderer and by the stylesheet, and a
    # segment whose id no rule answers would still render, still look like a
    # link, and show the wrong pass's values on click.
    for i in 0 ..< MaxStaticIterations:
      let t = "#fit-" & $i & ":target ~ "
      check (t & ".srcwrap .fv.now{display:none}") in debugRouteCss
      check (t & ".srcwrap .fv.fv-i" & $i & ",") in debugRouteCss
      check (t & ".flowrail .frseg.s" & $i & " .frdot{display:block}") in
            debugRouteCss
      check (t & ".flowrail .frcount.now{display:none}") in debugRouteCss
      check (t & ".flowrail .frcount.c" & $i & "{display:inline}") in
            debugRouteCss
    # And nothing beyond the ladder is emitted, in either file.
    check ("#fit-" & $MaxStaticIterations & ":target") notin debugRouteCss
    check ("id=\"fit-" & $MaxStaticIterations & "\"") notin debugHtml(readyTx)

    # THE ANCHORS ARE ACTUALLY EMITTED, and are SIBLINGS of the listing. Both
    # halves, because both were wrong and neither showed up as a failure: the
    # anchors were dropped entirely by a `for` at the top level of the `ui`
    # DSL, and the negative above passed over their absence without noticing.
    # Then, once emitted, a two-root `ui` block wrapped them in an anonymous
    # `<div>`, which put them in a different parent from `.srcwrap` — so
    # `#fit-3:target ~ .srcwrap` matched nothing and the control silently did
    # nothing. A capture found both; this is what would have.
    let served = debugHtml(readyTx)
    let rail = sessionFor(readyTx).editor.flow
    check rail.iterations.len == 8
    for i in 0 ..< rail.iterations.len:
      check ("id=\"fit-" & $i & "\"") in served
    let body = "<div class=\"panebody\">"
    let paneAt = served.find("id=\"pane-editor\"")
    check paneAt >= 0
    let bodyAt = served.find(body, paneAt)
    check bodyAt >= 0
    # Everything from the pane body's opening tag to the listing is anchors and
    # the rail: no element opens between them that could become their parent.
    let between = served[bodyAt + body.len ..< served.find("<div class=\"srcwrap\"", bodyAt)]
    check between.startsWith("<span class=\"frtarget\" id=\"fit-0\">")
    check occurrences(between, "<div") == 1          # the rail itself
    check "class=\"flowrail\"" in between

  test "a loop longer than the ladder is CLAMPED and says so":
    # `MaxIndentDepth`'s rule, applied to passes. The failure this prevents is
    # silent: an unclamped segment resolves to no rule, so the rail would look
    # complete and switch to the wrong pass.
    var rail = FlowRail(loopIndex: 1, line: 4, anchor: "L-x-4",
                        label: "wide_loop", selected: 0, active: 0)
    for i in 0 ..< MaxStaticIterations + 5:
      rail.iterations.add FlowIteration(index: i, ticks: 10 + i, reached: true)
    let html = dbgc.renderFlowRail(rail)
    check occurrences(html, "class=\"frseg") == MaxStaticIterations
    check ("Iteration 1 of " & $(MaxStaticIterations + 5)) in html
    check "Showing the first 16 of 21 passes" in html
    # …and a session PAST the ladder's end still gets its counter, which the
    # track alone cannot give it. Clamping the track is honest; clamping away
    # the one line that says where the session is would not be.
    var far = rail
    far.selected = MaxStaticIterations + 3
    far.active = far.selected
    let farHtml = dbgc.renderFlowRail(far)
    check ("Iteration " & $(far.selected + 1) & " of " &
           $(MaxStaticIterations + 5)) in farHtml
    check occurrences(farHtml, "frcount num c") == MaxStaticIterations + 1
    check occurrences(farHtml, " now\">Iteration") == 1

    # A rail INSIDE the ladder says nothing of the sort — the announcement is a
    # statement about a reduction, not decoration.
    rail.iterations.setLen(4)
    let small = dbgc.renderFlowRail(rail)
    check "Showing the first" notin small
    check occurrences(small, "frcount num c") == 4

  test "an unreached pass is not a link, and says why":
    let html = debugHtml(readyTx)
    check "class=\"frseg s2 here showing got\"" in html
    check "class=\"frseg s3 out\"" in html
    check "The session has not reached pass 4 at this position." in html
    # The reached ones ARE links, so the rail works with scripting off.
    check ("<a class=\"frseg s0 got\" href=\"#fit-0\"") in html

  test "the fidelity ladder: no source means no values and no rail":
    # §14's "No verified source" row. At instruction level there is no
    # expression to place a value against; values degrade to ABSENT rather than
    # to approximate. The shape this rules out is one `if` away — a placement
    # that fell back to column 0 would render a complete, confident fiction.
    #
    # The pane is given DOCUMENTS at the flow window's own path, which is what
    # makes this test able to fail. An unverified pane with no documents is
    # refused by the path join a line later, so it would report the guard
    # working while the guard was deleted — and a §14 mixed session is exactly
    # the case that HAS a listing (an instruction-level one) and no verified
    # source to place a value against.
    let shieldSource = readFile(
      clientRoot / "fixtures" / "demo-session" / "src" / "shield.nr")
    let input = demoFlowInput(shieldSource)
    let listing = newSourceDocument("src/shield.nr", "noir", shieldSource)

    # The document is handed in WITH an overlay already on it — the state a
    # pane is in when the session it belongs to drops to instruction level, or
    # when a published bundle replaces the file under it. Refusing to add is
    # only half the rule; what must not survive is the overlay that is already
    # there, because nothing on screen would announce that it now describes a
    # frame the pane is no longer showing.
    var stale = listing
    for i in 0 ..< stale.lines.len:
      stale.lines[i].annotations = @[LineAnnotation(
        slot: asInline, column: 0, label: "left_over",
        beforeValue: "1", mode: vmBefore, iteration: -1)]

    var unverified = EditorPane(
      availability: srcUnverified, activeIndex: 0, currentLine: 32,
      reason: "No source bundle is published for the code that ran.",
      documents: @[stale])
    applyFlow(unverified, input)
    check unverified.flow.loopIndex == 0
    var annotated = 0
    for ln in unverified.documents[0].lines:
      annotated += ln.annotations.len
    check annotated == 0

    var absent = EditorPane(
      availability: srcAbsent, activeIndex: 0, currentLine: 32,
      reason: "This execution ran no contract code.",
      documents: @[stale])
    applyFlow(absent, input)
    check absent.flow.loopIndex == 0
    annotated = 0
    for ln in absent.documents[0].lines:
      annotated += ln.annotations.len
    check annotated == 0

    # The same pane at source level DOES get them, so the assertions above are
    # about the availability and not about the window.
    var verified = EditorPane(
      availability: srcSourceLevel, activeIndex: 0, currentLine: 32,
      documents: @[listing])
    applyFlow(verified, input)
    check verified.flow.loopIndex == 1
    annotated = 0
    for ln in verified.documents[0].lines:
      annotated += ln.annotations.len
    check annotated > 0

    let html = dbgc.renderSource(unverified)
    check "class=\"fv" notin html
    check "class=\"flowrail\"" notin html

  test "an expression the source does not contain gets NO column, but is kept":
    # Rule 3. `fallbackExpressionColumn` parks such an expression past the end
    # of the line so the value is not lost; taking that column at face value
    # would point the label at an offset the expression has nothing to do with.
    var input = FlowWindowInput(
      path: "synth.nr", locationTicks: 0, functionLabel: "f",
      window: FlowLayoutWindow(
        sourceLines: @["let sum = a + b;"],
        tabSize: 4,
        loops: @[FlowLayoutLoop()],
        steps: @[FlowLayoutStep(
          stepCount: 1, line: 1, loopIndex: 0, iteration: 0, rrTicks: 1,
          exprOrder: @["a", "hidden_temp"],
          beforeValues: @[FlowValueText(expression: "a", text: "10"),
                          FlowValueText(expression: "hidden_temp", text: "77")],
          afterValues: @[])]))
    var pane = EditorPane(
      availability: srcSourceLevel, activeIndex: 0,
      documents: @[newSourceDocument("synth.nr", "noir", "let sum = a + b;\n")])
    applyFlow(pane, input)
    var placed, unplaced = 0
    for a in pane.documents[0].lines[0].annotations:
      if a.label == "a":
        inc placed
        check a.slot == asInline
        check a.column == 10                  # `a` in `let sum = a + b;`
      elif a.label == "hidden_temp":
        inc unplaced
        check a.slot == asTrailing
        check a.column == -1                  # never the fallback offset
        check a.beforeValue == "77"           # and never dropped
    check placed == 1
    check unplaced == 1

  test "the legend columns the desktop cannot compute ARE computed here":
    # `Omniscience-Flow.md` records that `makeLegend` on the desktop indexes a
    # `positions` map nothing ever writes — `calculatePositionMaxWidth` and
    # `realignPositionWidths` were dead code with no call site — so the loop
    # legend raises rather than laying out at 0%.
    #
    # BlockTracer's renderer does not read those fields: it draws labels in the
    # source's own reading order and has no parallel band, so it cannot inherit
    # the broken path. This test is what makes that a decision rather than an
    # omission — the arithmetic is exercised against the real window and its
    # answers are non-empty, so the day a parallel-column mode wants them they
    # are computed here and not inherited.
    let input = demoFlowInput(readFile(
      clientRoot / "fixtures" / "demo-session" / "src" / "shield.nr"))
    let plan = computeLoopColumnPlan(input.window, 1)
    check plan.loopIndex == 1
    check plan.legendChars > 0
    check plan.legend.len > 0
    check plan.positions.len > 0

    # Line 7 — `remaining_shield -= damage;` — pinned to EXACT numbers, because
    # ">0 somewhere" is the shape of a check that cannot fail. Two headings
    # budgeted at `max(len, 3)` characters plus one separator each, less the one
    # trailing separator the accumulation adds and takes back:
    # (16 + 1) + (6 + 1) - 1 = 23, and one gap is 100/23 of the legend row.
    var found = false
    for position in plan.positions:
      if position.line != 7: continue
      found = true
      check position.expressionChars == 23
      check abs(position.legendGapShare - 100.0 / 23.0) < 1e-9
      check position.iterations.len == 2       # the passes this frame reaches
      for iteration in position.iterations:
        check iteration.columns.len == 2
        check iteration.maxValueChars > 0
        for column in iteration.columns:
          check column.legendShare > 0.0
          check column.valueShare > 0.0
        check abs(iteration.columns[0].legendShare - 16.0 * 100.0 / 23.0) < 1e-9
        check abs(iteration.columns[1].legendShare - 6.0 * 100.0 / 23.0) < 1e-9
    check found

    # A line whose steps recorded no BEFORE values — `let mut damage = 0;`, a
    # first assignment — gets a zero budget, and that is upstream's own
    # behaviour rather than a gap here: `calculatePositionMaxWidth` accumulates
    # `beforeValues` only. Asserted so the day it changes, this file says so.
    for position in plan.positions:
      if position.line == 27:
        check position.expressionChars == 0

  test "the served debug route carries the overlay a browser is given":
    let html = debugHtml(readyTx)
    # The current line's own write, in the spec's headline rendering.
    check "class=\"fvn\">damage</span>" in html
    check "class=\"fvv was\">0</span>" in html
    check "class=\"fvv\">2000</span>" in html
    # The rail, and the phase-independent fact that the page ships no script to
    # drive it: the whole control is links and CSS.
    check "class=\"flowrail\"" in html
    check executableScripts(html) == 0

suite "Omniscience — the branch that was taken, and the ones that were not":
  ## The desktop feature, carried over with its unsound half left behind.
  ##
  ## Desktop CodeTracer produces `BranchState.NotTaken` two ways. One is sound:
  ## `load_branch_for_position` marks the arm the debugger stepped into `Taken`
  ## and its AST siblings `NotTaken`. The other, `final_branch_load`, sweeps the
  ## file after the flow walk and stamps `NotTaken` on every branch the walk did
  ## not reach — after all four of that walk's early exits, including a
  ## 10,000-step budget and a stall guard, with no truncation signal reaching the
  ## UI. Only the first is implemented here, and the tests below are what make
  ## that a decision rather than a claim: each one asserts a region is left
  ## UNDIMMED, and each one fails against an implementation that dimmed on
  ## absence.
  ##
  ## The subject is the real recorded window (`fixtures/demo-session/flow.json`,
  ## extracted from `zk_shields.ct`), so the passes and the lines below are the
  ## recorder's, not this file's.

  let shieldSource = readFile(
    clientRoot / "fixtures" / "demo-session" / "src" / "shield.nr")
  let flowInput = demoFlowInput(shieldSource)

  proc verifiedPane(): EditorPane =
    EditorPane(availability: srcSourceLevel, activeIndex: 0, currentLine: 32,
               documents: @[newSourceDocument("src/shield.nr", "noir", shieldSource)])

  proc dimmedLines(pane: EditorPane): Table[int, seq[int]] =
    for ln in pane.documents[0].lines:
      if ln.notTaken.len > 0: result[ln.number] = ln.notTaken

  test "the subject exists: shield.nr has the four conditionals this rests on":
    # `requireFixtures`' rule, applied to this feature. Every test below is
    # about a specific line of a specific construct, and a lexer change that
    # stopped finding conditionals would make all of them vacuously true —
    # which is precisely how this module first "passed": `highlightLine`
    # coalesces `)` and `{` into one `){` token, so the brace matcher found no
    # braces, `findConditionals` returned nothing, and every claim about the
    # result held over an empty seq.
    let conditionals = findConditionals(
      splitSourceLines(shieldSource), profileForDocument("src/shield.nr", "noir"))
    check conditionals.len == 4
    var byHeader: Table[int, Conditional]
    for c in conditionals: byHeader[c.headerLine] = c

    # The one `if`/`else` in the file, and the ONLY exhaustive chain: line 28's
    # `if(shield_pct == 100){…} else {…}`.
    check 28 in byHeader
    check byHeader[28].exhaustive
    check byHeader[28].arms.len == 2
    # The INTERIORS, and not the headers. An `else if` whose condition was
    # evaluated and came out false has executed that line; only what is inside
    # the braces can be claimed not to have run. Desktop keys its branch table
    # on `header_line` and therefore paints exactly the line this excludes.
    check byHeader[28].arms[0] == BranchArm(headerLine: 28, firstLine: 29, lastLine: 29)
    check byHeader[28].arms[1] == BranchArm(headerLine: 31, firstLine: 32, lastLine: 32)

    check 34 in byHeader
    check not byHeader[34].exhaustive        # a bare `if` with no `else`
    check byHeader[34].arms.len == 1

  test "the same two lines swap roles between passes, and the markup says so":
    # `calculate_damage` takes the `if` on passes 0 and 1 (shield still at
    # 100%) and the `else` on pass 2. A per-LINE answer would be wrong in one
    # of those; the claim is per-line-per-pass.
    var pane = verifiedPane()
    applyFlow(pane, flowInput)
    let dim = dimmedLines(pane)

    check dim.getOrDefault(29) == @[2]        # the `if` body — untaken on pass 2
    check dim.getOrDefault(32) == @[0, 1]     # the `else` body — untaken on 0, 1

    # The negative that makes the pair meaningful: neither line is claimed
    # untaken in a pass the other is. If both were listed for one pass the pane
    # would be asserting that a conditional took NO arm.
    for pass in 0 .. 2:
      check not (pass in dim.getOrDefault(29) and pass in dim.getOrDefault(32))

    # And the claim rides the same `:target` ladder the values do, so the rail
    # moves the dimming and the values together.
    check notTakenClasses(@[2], 2) == " nt-i2 ntnow"
    check notTakenClasses(@[2], 0) == " nt-i2"       # not the session's pass
    check notTakenClasses(@[-1], 5) == " nt-any ntnow"  # outside every loop
    check notTakenClasses(@[], 2) == ""

  test "a body with no recorded step ANYWHERE is not dimmed — the crux":
    # `shield.nr:35` is the body of `if(damage as u32 > remaining_shield…)`, a
    # clamp that never fires in this recording. Every ingredient for a dimming
    # is present except one: the header at line 34 ran on passes 0 and 1, the
    # execution demonstrably moved past it, and the chain has no `else` — so a
    # rule that concluded "not taken" from the absence of a step would dim it,
    # confidently, on both passes.
    #
    # It is left alone, because a body that recorded no step in the whole window
    # is indistinguishable from a body the recorder emits no steps for. "This
    # branch was not taken" and "this line was never instrumented" are different
    # sentences and only one of them is about the program.
    #
    # THIS TEST IS THE ONE THAT FAILS FIRST if the instrumentation guard is
    # dropped: `notTakenPasses` would then report line 35 for passes 0 and 1,
    # the build would stay green and the pane would gain two dimmed lines that
    # look exactly like the three true ones.
    var pane = verifiedPane()
    applyFlow(pane, flowInput)
    let dim = dimmedLines(pane)
    check 35 notin dim

    # The subject is real: line 35 IS an arm interior, and it IS unexecuted.
    var found = false
    for c in findConditionals(splitSourceLines(shieldSource),
                             profileForDocument("src/shield.nr", "noir")):
      if c.headerLine == 34:
        found = true
        check c.arms[0].firstLine == 35 and c.arms[0].lastLine == 35
    check found
    for ln in pane.documents[0].lines:
      if ln.number == 35: check not ln.executed

    # And the surrounding claim IS made where the evidence exists: line 44, the
    # body of the regeneration clamp, recorded a step on pass 0 and none on
    # pass 1 with the chain entered and left. So the guard is not simply
    # refusing everything.
    check dim.getOrDefault(44) == @[1]

  test "a condition the session is standing ON is not resolved, so nothing dims":
    # The third of the three things an unrecorded line can be: not a branch
    # declined, and not a line uninstrumented, but a line the window does not
    # COVER yet. The served frame is cut at the session's position, and the cut
    # can fall between evaluating a condition and entering an arm.
    #
    # Built synthetically so the cut can be placed exactly on that boundary.
    # Every other ingredient is present: the arm is instrumented (pass 0 ran
    # it), the chain has no `else`, and its header recorded a step in pass 1.
    # The only thing missing is proof that execution moved PAST the condition,
    # and that is the whole of the difference between "declined" and "deciding".
    let text = """fn f() {
    if (b) {
        two();
    }
    done();
}
"""
    var input = FlowWindowInput(
      path: "cut.nr", locationTicks: 4, functionLabel: "f",
      window: FlowLayoutWindow(
        sourceLines: splitSourceLines(text), tabSize: 4,
        loops: @[FlowLayoutLoop()],
        steps: @[
          # Pass 0 runs the whole construct, which is what makes line 3 known
          # to be instrumented.
          FlowLayoutStep(stepCount: 1, line: 2, loopIndex: 1, iteration: 0, rrTicks: 1),
          FlowLayoutStep(stepCount: 2, line: 3, loopIndex: 1, iteration: 0, rrTicks: 2),
          FlowLayoutStep(stepCount: 3, line: 5, loopIndex: 1, iteration: 0, rrTicks: 3),
          # Pass 1 evaluates the condition and the window stops there.
          FlowLayoutStep(stepCount: 4, line: 2, loopIndex: 1, iteration: 1, rrTicks: 4)]))
    var pane = EditorPane(
      availability: srcSourceLevel, activeIndex: 0, currentLine: 2,
      documents: @[newSourceDocument("cut.nr", "noir", text)])
    applyFlow(pane, input)
    check dimmedLines(pane).len == 0

    # One more step in pass 1, carrying a later tick, and the SAME window makes
    # the claim — so the assertion above is about resolution and not about a
    # fixture that could never produce a dimming.
    input.window.steps.add FlowLayoutStep(
      stepCount: 5, line: 5, loopIndex: 1, iteration: 1, rrTicks: 5)
    var after = EditorPane(
      availability: srcSourceLevel, activeIndex: 0, currentLine: 5,
      documents: @[newSourceDocument("cut.nr", "noir", text)])
    applyFlow(after, input)
    check dimmedLines(after).getOrDefault(3) == @[1]

  test "an exhaustive chain that recorded no arm claims nothing":
    # If an `if`/`else` was entered, exactly one arm ran. So "no arm recorded a
    # step" is a fact about the RECORDING — some arm ran and was not
    # instrumented — and nothing may be concluded from it. The tempting wrong
    # answer is to dim both arms, which would state that a chain with an `else`
    # took neither branch.
    let text = """fn f() {
    if (a) {
        one();
    }
    else {
        two();
    }
    done();
}
"""
    let input = FlowWindowInput(
      path: "both.nr", locationTicks: 9, functionLabel: "f",
      window: FlowLayoutWindow(
        sourceLines: splitSourceLines(text), tabSize: 4,
        loops: @[FlowLayoutLoop()],
        steps: @[
          # Both arms are instrumented — each recorded a step at SOME point —
          # so the instrumentation guard is satisfied and cannot be what is
          # doing the refusing here.
          FlowLayoutStep(stepCount: 1, line: 3, loopIndex: 1, iteration: 0, rrTicks: 1),
          FlowLayoutStep(stepCount: 2, line: 6, loopIndex: 1, iteration: 1, rrTicks: 2),
          # Pass 2 enters the chain and leaves it, recording neither arm.
          FlowLayoutStep(stepCount: 3, line: 2, loopIndex: 1, iteration: 2, rrTicks: 3),
          FlowLayoutStep(stepCount: 4, line: 8, loopIndex: 1, iteration: 2, rrTicks: 4)]))
    var pane = EditorPane(
      availability: srcSourceLevel, activeIndex: 0, currentLine: 8,
      documents: @[newSourceDocument("both.nr", "noir", text)])
    applyFlow(pane, input)
    let dim = dimmedLines(pane)
    check 2 notin dim.getOrDefault(3)
    check 2 notin dim.getOrDefault(6)
    # The passes where an arm DID record are claimed, so the window is not
    # simply producing nothing: pass 0 took line 3, so line 6 is untaken there.
    check dim.getOrDefault(6) == @[0]
    check dim.getOrDefault(3) == @[1]

  test "a chain that went BOTH ways in one pass claims nothing for that pass":
    # A conditional inside a function called twice in one loop pass can take
    # one arm on the first call and the other on the second. Both arms then
    # carry a step for the pass, and neither may be called untaken — a reader
    # looking at that pass has two evaluations in front of them and the pane
    # cannot say which.
    let text = """fn f() {
    if (a) {
        one();
    }
    else {
        two();
    }
}
"""
    let input = FlowWindowInput(
      path: "twice.nr", locationTicks: 4, functionLabel: "f",
      window: FlowLayoutWindow(
        sourceLines: splitSourceLines(text), tabSize: 4,
        loops: @[FlowLayoutLoop()],
        steps: @[
          FlowLayoutStep(stepCount: 1, line: 2, loopIndex: 1, iteration: 0, rrTicks: 1),
          FlowLayoutStep(stepCount: 2, line: 3, loopIndex: 1, iteration: 0, rrTicks: 2),
          FlowLayoutStep(stepCount: 3, line: 2, loopIndex: 1, iteration: 0, rrTicks: 3),
          FlowLayoutStep(stepCount: 4, line: 6, loopIndex: 1, iteration: 0, rrTicks: 4)]))
    var pane = EditorPane(
      availability: srcSourceLevel, activeIndex: 0, currentLine: 6,
      documents: @[newSourceDocument("twice.nr", "noir", text)])
    applyFlow(pane, input)
    check dimmedLines(pane).len == 0

  test "the fidelity ladder: a level that cannot support the claim never dims":
    # §14's rows, applied to the STRONGER claim. "This block did not execute" is
    # a bigger statement than "this variable held 4000", so it must not survive
    # a path the inline values are refused on — and it must not survive a path
    # where the SOURCE cannot be read either, because a region with no braces to
    # find is a region chosen by nothing.
    #
    # The panes are handed documents that already carry a dimming, which is what
    # makes this able to fail. Refusing to ADD is only half the rule: a pane
    # whose availability drops to instruction level, or whose bundle is replaced
    # by a file in a language nothing here lexes, would otherwise keep the
    # regions it was given for a frame it is no longer showing, and nothing on
    # screen would announce it.
    var stale = newSourceDocument("src/shield.nr", "noir", shieldSource)
    for i in 0 ..< stale.lines.len:
      stale.lines[i].notTaken = @[-1]

    for availability in [srcUnverified, srcAbsent]:
      var pane = EditorPane(
        availability: availability, activeIndex: 0, currentLine: 32,
        reason: "no source", documents: @[stale])
      applyFlow(pane, flowInput)
      var claimed = 0
      for ln in pane.documents[0].lines: claimed += ln.notTaken.len
      check claimed == 0
      # And nothing reaches the markup, on either channel.
      let html = dbgc.renderSource(pane)
      check "nt-i" notin html
      check "ntnow" notin html
      check "class=\"mn\"" notin html

    # A language with NO lexer profile is the same refusal one level down. The
    # window, the steps and the fidelity are all identical to the passing case;
    # only the document's language changes, so this cannot pass by accident.
    var unlexed = EditorPane(
      availability: srcSourceLevel, activeIndex: 0, currentLine: 32,
      documents: @[newSourceDocument("src/shield.sol", "solidity", shieldSource)])
    var solidityInput = flowInput
    solidityInput.path = "src/shield.sol"
    applyFlow(unlexed, solidityInput)
    var claimed = 0
    for ln in unlexed.documents[0].lines: claimed += ln.notTaken.len
    check claimed == 0

    # The control: the same source at source level, with its own lexer, DOES
    # produce the three claims. Without this the four checks above would pass
    # against a `notTakenPasses` that returned an empty table unconditionally.
    var verified = verifiedPane()
    applyFlow(verified, flowInput)
    check dimmedLines(verified).len == 3

  test "the markup carries both channels, and only where there is a claim":
    # REVISED with the affirmative mark: these two class strings gained `rn-*`,
    # because both lines now also carry the pass they DID run in. The exact
    # strings are kept exact rather than loosened to `in`-substrings — the class
    # list is the whole of what the `:target` ladder switches on, so an extra
    # class arriving unnoticed is exactly what this assertion is for.
    let html = debugHtml(readyTx)
    # Line 29 — the `if` body `calculate_damage` did not take on pass 2, the
    # pass the served page opens on. Dimmed by default, and marked. It DID run
    # on passes 0 and 1, and now says so.
    check "class=\"srcline hit nt-i2 ntnow rn-i0 rn-i1\"" in html
    # Line 32 is the session's own position, the arm passes 0 and 1 declined,
    # AND the arm pass 2 took — so it is the row where all three decorations
    # compose: current, untaken-in-another-pass, and ran-in-this-one.
    check "class=\"srcline cur hit nt-i0 nt-i1 rn-i2 rnnow\"" in html
    # The gutter triple: the ordinary marker and the two that replace it.
    check "<span class=\"mg\">" in html
    check "<span class=\"mn\">⊘</span>" in html
    check "<span class=\"mt\">⊙</span>" in html
    # And the block rails, which are what make a run of claimed lines read as a
    # region rather than as scattered rows.
    check "<span class=\"ntbar\">" in html
    check "<span class=\"rnbar\">" in html
    # A line with no claim is unchanged — no pair, no rail, no extra spans.
    # Counting is what makes that checkable.
    #
    # THE TAKEN AND NOT-TAKEN COUNTS ARE NO LONGER THE SAME NUMBER, and that
    # is a result rather than a nuisance. They used to both be 3 because the
    # pane was WINDOWED from line 26 and only lines 29, 32 and 44 were on the
    # page. The file renders whole now, and lines 11 and 12 — `rn-i0 rn-i1`,
    # the loop body that ran on the first two passes and carries no not-taken
    # claim at all — were being dropped along with everything above line 26.
    # Five affirmative claims and three negative ones is what this recording
    # always said; the window was hiding two of them.
    check occurrences(html, "<span class=\"mn\">") == 3
    check occurrences(html, "<span class=\"ntbar\">") == 3
    check occurrences(html, "<span class=\"mt\">") == 5
    check occurrences(html, "<span class=\"rnbar\">") == 5
    # `.mg` once per claimed LINE rather than once per claim: five lines carry
    # at least one claim (11, 12, 29, 32, 44).
    check occurrences(html, "<span class=\"mg\">") == 5
    for n in [11, 12, 29, 32, 44]:
      check ("id=\"L-src-shield-nr-" & $n & "\"") in html
    # Still no script. The whole control is links and CSS.
    check executableScripts(html) == 0

  test "the third state is a state: an uninstrumented arm takes NEITHER mark":
    # `shield.nr:35` is the body of a clamp that never fires. It is an arm
    # interior, it never ran, and no step was ever recorded on it in any pass —
    # so the pane cannot tell whether the program declined it or the recorder
    # simply never saw it, and it says so by marking it neither way.
    #
    # This is the assertion the affirmative mark exists for. Before it, "ran"
    # and "cannot tell" were both drawn as an unmarked line, so a check that
    # line 35 is unmarked was satisfied by a renderer that marked nothing at
    # all. Now the two are distinguishable, and the positive twin below is what
    # proves this one is not vacuous.
    let html = debugHtml(readyTx)
    check "class=\"srcline\" id=\"L-src-shield-nr-35\"" in html
    # The positive twin, through the same code path: a line that DID run in a
    # recorded pass is marked, so "35 is unmarked" is not the whole file being
    # unmarked.
    check "rn-i0" in html
    # …and the headers are unmarked too, which is the interiors-never-headers
    # rule holding for the affirmative claim as it does for the negative one.
    # Evaluating a condition is executing that line; it is not evidence about
    # the arm it introduces.
    for header in ["28", "31", "34", "43"]:
      check ("class=\"srcline hit\" id=\"L-src-shield-nr-" & header & "\"") in html

  test "no line claims it ran AND did not run in the SAME pass":
    # The contradiction `branchPasses` exists to make unrepresentable. Both
    # claims come from one walk over one `ranAt` table, so a line cannot be in
    # both sets for one pass — and this drives it over the real fixture rather
    # than trusting the structure.
    var pane = verifiedPane()
    applyFlow(pane, flowInput)     # the claims are attached by the walk, not
                                   # by the constructor — without this the loop
                                   # below iterates a pane with no claims at
                                   # all and every assertion in it is vacuous,
                                   # which is what `claimed > 0` catches.
    var claimed = 0
    for d in pane.documents:
      for ln in d.lines:
        for p in ln.ran:
          check p notin ln.notTaken
          inc claimed
        for p in ln.notTaken:
          check p notin ln.ran
          inc claimed
    check claimed > 0                 # the scan reached a claimed line

  test "the target ladder resets before it sets, on every rung":
    # The dimming has to move with the rail, because the demo's two lines swap
    # roles between passes. Each rung is a RESET (the session's pass stops being
    # dimmed) followed by a SET (the targeted pass starts), at equal specificity
    # so source order decides. Emitted the other way round, every claimed line
    # would stay dimmed in every pass — and a permanently dimmed block is
    # indistinguishable from a correctly dimmed one on a screenshot.
    let css = debugRouteCss
    for i in 0 ..< MaxStaticIterations:
      let t = "#fit-" & $i & ":target ~ "
      let reset = t & ".srcwrap .srcline.ntnow .t{opacity:1}"
      let setRule = t & ".srcwrap .srcline.nt-i" & $i & " .t"
      check reset in css
      check setRule in css
      check css.find(reset) < css.find(setRule)
      # `nt-any` — a conditional outside every loop — is set on every rung, so
      # it survives whichever pass is displayed.
      check (t & ".srcwrap .srcline.nt-any .t{opacity:var(--bt-opacity-not-run)}") in css
      # The glyph and the rail swap with it, so the gutter, the region mark and
      # the code never disagree about which pass is on screen.
      check (t & ".srcwrap .srcline.ntnow .mn{display:none}") in css
      check (t & ".srcwrap .srcline.nt-i" & $i & " .mn,") in css
      check (t & ".srcwrap .srcline.ntnow .ntbar{display:none}") in css
      check (t & ".srcwrap .srcline.nt-i" & $i & " .ntbar,") in css
    # The default, before any segment is targeted: the session's own pass.
    check ".srcline.ntnow .t{opacity:var(--bt-opacity-not-run)}" in css
    check ".srcline .mn{display:none;color:var(--bt-mark-not-taken)}" in css

suite "the current line is marked, and a branch claim cannot take the mark":
  ## THE DEFECT: on the flagship view the position glyph was not drawn at all.
  ##
  ## `.m` was one gutter cell answering two independent questions — "what does
  ## the recording say about this line" (`·`, `⊙`, `⊘`) and "is the session
  ## standing here" (`▶`) — and the stylesheet resolves that collision by
  ## hiding the second: `.srcline.ntnow .mg{display:none}` and
  ## `.srcline.rnnow .mg{display:none}`. The line a session is stopped at is
  ## STRUCTURALLY also the arm that ran in the displayed pass, so the row whose
  ## glyph matters most is the row that hid it. `debugger_css.nim` had already
  ## measured the consequence and filed it as Q18 — "`▶` is never painted
  ## anywhere in the corpus" — without connecting it to the cause.
  ##
  ## The fix is a channel and not a colour. `672dfc4` had already spent the
  ## colour channel (the current line's `⊙`/`⊘` take the position ink, to lift
  ## them off the position band), which left the row with a BRANCH glyph wearing
  ## POSITION ink and no position glyph — two facts collapsed onto one mark.
  ##
  ## Every test below asserts on the RENDERED page, through the shipping
  ## renderer, and counts what it finds. The demo fixture's `shield.nr:32` is
  ## the overlap case on purpose: it is where the session stands AND the arm the
  ## displayed pass took AND the arm two earlier passes declined.

  let html = debugHtml(readyTx)
  let onDemandHtml = debugHtml(onDemandTx)

  test "the subject exists: one positioned line, in a listing of many":
    # Nothing below is worth checking over a page with no listing or no
    # position, and both have been true of this route for a whole class of
    # transaction. The counts are asserted, not sampled.
    # 133 and not 108. The 25 are `shield.nr`'s lines 1–25, which the pane used
    # to drop and announce as "Showing from line 26"; the file is 67 lines and
    # all 67 are here. See "the source pane renders the WHOLE file …" above.
    check occurrences(html, "class=\"srcline") == 133
    check occurrences(html, "class=\"srcline cur") == 1
    check "id=\"L-src-shield-nr-32\"" in html
    check "id=\"L-src-shield-nr-1\"" in html

  test "the position has a gutter cell of its own, on EVERY row":
    # One `.p` per rendered line and not one per page. A cell that appeared
    # only where the session stands would shift that row's code text right by
    # its own width relative to every other row, so the current line would be
    # the one line that does not align — a worse artefact than no marker.
    #
    # Counted on the OPEN TAG and not on `<span class="p">`, because the current
    # row's cell now carries the `tabindex`/`autofocus`/`aria-label` triple that
    # opens the pane at the position on a page with no script. The total is the
    # invariant; the split below is what changed.
    check occurrences(html, "<span class=\"p\"") == 133
    # …and exactly one of them is inked, and it is the one that is focusable.
    # The other 132 hold a space and carry no attribute at all.
    check occurrences(html, "<span class=\"p\" tabindex=\"-1\" " &
                            "autofocus=\"autofocus\"") == 1
    check occurrences(html, "<span class=\"p\">▶</span>") == 0
    check occurrences(html, "<span class=\"p\"> </span>") == 132

  test "the OVERLAP row states both facts, in the order the renderer emits":
    # The whole composition question, as one exact string. `shield.nr:32` is
    # dimmed-in-two-passes, ran-in-this-one, and current — and the row carries
    # the not-taken rail, the ran rail, the POSITION glyph in its own cell, the
    # number, and the branch triple, none of which displaces another.
    #
    # Exact and not an `in`-substring on each piece: the defect being fixed was
    # precisely that two of these shared one cell, and a per-piece check passes
    # against a row that emits them in the wrong container.
    check ("<div class=\"srcline cur hit nt-i0 nt-i1 rn-i2 rnnow\" " &
           "id=\"L-src-shield-nr-32\" data-line=\"32\" aria-current=\"true\">" &
           "<span class=\"ntbar\"></span><span class=\"rnbar\"></span>" &
           "<span class=\"p\" tabindex=\"-1\" autofocus=\"autofocus\" " &
           "aria-label=\"the session is stopped on line 32\">▶</span>" &
           "<span class=\"n\">32</span>" &
           "<span class=\"m\"><span class=\"mg\">·</span>" &
           "<span class=\"mn\">⊘</span><span class=\"mt\">⊙</span></span>") in html

  test "the branch glyphs are untouched, in count and in spelling":
    # The fix may not be "drop the branch mark". Both facts are real, and the
    # five claimed lines (11, 12, 29, 32, 44) still carry every channel they
    # carried. See the count note in "the markup carries both channels" above
    # for why 11 and 12 joined the set: they were never unclaimed, they were
    # above the window.
    check occurrences(html, "<span class=\"mn\">⊘</span>") == 3
    check occurrences(html, "<span class=\"ntbar\">") == 3
    check occurrences(html, "<span class=\"mt\">⊙</span>") == 5
    check occurrences(html, "<span class=\"rnbar\">") == 5
    # `.mg` sheds `▶` and keeps `·`: the cell now answers ONE question, so a
    # steppable line the session is standing on says both things at once
    # instead of choosing. All five claimed lines are executed.
    check occurrences(html, "<span class=\"mg\">·</span>") == 5
    check "<span class=\"mg\">▶</span>" notin html

  test "NO branch rule can reach the position cell, in the whole stylesheet":
    # The structural half of the fix, asserted structurally. Every rule that
    # hides a gutter glyph selects `.mg`, `.mn` or `.mt` — all of them INSIDE
    # `.m` — so none of them can name `.p`. This is what makes the channel
    # uncontendable rather than merely currently-uncontended: a seventeenth
    # rung of the `:target` ladder, or a fourth branch state, cannot silently
    # take the position mark the way `.rnnow` took `.mg`.
    let css = debugRouteCss
    check ".srcline .p{" in css
    check ".srcline.cur .n,.srcline.cur .m,.srcline.cur .p{" &
          "color:var(--bt-mark-position)}" in css
    # The suppression rules that caused the defect are still there — they are
    # correct for `.mg` — and they still name only cells inside `.m`.
    check ".srcline.ntnow .mg{display:none}" in css
    check ".srcline.rnnow .mg{display:none}" in css
    var hidesPosition = 0
    for line in css.splitLines:
      if ".p{display:none" in line or " .p," in line or " .p{display" in line:
        inc hidesPosition
    check hidesPosition == 0

  test "the position reaches the ACCESSIBILITY tree, which it did not before":
    # Every other channel — the fill, the rail, the ink, the glyph — is a
    # paint. A reader who gets the DOM and not the pixels had no way at all to
    # tell the current line from any other row, on a view whose entire subject
    # is which line that is.
    #
    # Counted in BOTH directions. `aria-current="false"` is ARIA's spelling of
    # "does not represent the current item", and asserting the 107 is what
    # distinguishes "one row is marked current" from "the renderer stopped
    # emitting the attribute and one row happens to match".
    check occurrences(html, "aria-current=\"true\"") == 1
    # 132, up from 107, for the same reason `class="srcline"` went 108 -> 133.
    check occurrences(html, "aria-current=\"false\"") == 132
    check ("id=\"L-src-shield-nr-32\" data-line=\"32\" " &
           "aria-current=\"true\"") in html

  test "CONTROL: a page with no listing carries none of these marks":
    # Without this, every count above would be satisfied by a renderer that
    # emitted the position markup unconditionally. The on-demand transaction
    # has no session and no source, and it draws no `.p`, no `aria-current` on
    # a row, and no `▶` in a gutter.
    check "class=\"srcline" notin onDemandHtml
    check "<span class=\"p\"" notin onDemandHtml
    check "aria-current=\"false\"" notin onDemandHtml

  test "MUTATION BITE: the position moves when the SESSION does, not by luck":
    # The counts above hold for a renderer that marked line 32 because it is
    # line 32. Move the position and every one of them has to follow it — the
    # glyph, the class and the ARIA state together, and off the old line.
    var moved = EditorPane(
      availability: srcSourceLevel, activeIndex: 0,
      documents: @[newSourceDocument(
        "src/shield.nr", "noir",
        readFile(clientRoot / "fixtures" / "demo-session" / "src" / "shield.nr"))])
    focus(moved, "src/shield.nr", 29)
    let movedHtml = dbgc.renderSource(moved)
    check occurrences(movedHtml, "<span class=\"p\" tabindex=\"-1\" " &
                                 "autofocus=\"autofocus\" aria-label=\"the session " &
                                 "is stopped on line 29\">▶</span>") == 1
    check occurrences(movedHtml, "aria-current=\"true\"") == 1
    check "id=\"L-src-shield-nr-29\" data-line=\"29\" aria-current=\"true\"" in
          movedHtml
    check "id=\"L-src-shield-nr-32\" data-line=\"32\" aria-current=\"false\"" in
          movedHtml

  test "MUTATION BITE: the branch claim is what USED to erase the position":
    # The defect, reproduced through the model rather than asserted from
    # memory. `rnnow` on the current line is exactly the state that hides
    # `.mg`; the row still draws `▶`, because `▶` is no longer in `.mg`.
    #
    # The twin is the point: the SAME pane without the claim renders the same
    # position glyph, so this arm is not passing because the claim was dropped.
    let shieldSource = readFile(
      clientRoot / "fixtures" / "demo-session" / "src" / "shield.nr")
    proc paneAt(line: int; claimCurrent: bool): EditorPane =
      result = EditorPane(
        availability: srcSourceLevel, activeIndex: 0,
        documents: @[newSourceDocument("src/shield.nr", "noir", shieldSource)])
      focus(result, "src/shield.nr", line)
      if claimCurrent:
        for i in 0 ..< result.documents[0].lines.len:
          if result.documents[0].lines[i].number == line:
            result.documents[0].lines[i].ran = @[-1]
    let claimed = dbgc.renderSource(paneAt(32, true))
    let bare = dbgc.renderSource(paneAt(32, false))
    # The claim really is on the current row — otherwise this proves nothing.
    check "class=\"srcline cur rn-any rnnow\"" in claimed
    check "rn-any" notin bare
    # …and the position glyph survives it, exactly once, in both renders.
    check occurrences(claimed, "<span class=\"p\" tabindex=\"-1\"") == 1
    check occurrences(bare, "<span class=\"p\" tabindex=\"-1\"") == 1
    check occurrences(claimed, ">▶</span>") == 1
    check occurrences(bare, ">▶</span>") == 1
    # The branch glyph is there too, in the cell it has always been in. Two
    # marks, two facts, one row.
    check "<span class=\"mt\">⊙</span>" in claimed
    check "<span class=\"mt\">" notin bare

suite "the pane with no line to mark still says where the session is":
  ## `renderSource`'s OTHER output. A source-level pane says where the session
  ## is with `.srcline.cur`; an instruction-level pane — `srcUnverified`, which
  ## is every real chain transaction this site publishes — returned `.srcnone`,
  ## two paragraphs of prose, and no position mark of any kind. The pane whose
  ## whole question is "where is this stopped" answered it nowhere.
  ##
  ## `test_chain_provenance` asserts the same head on the REAL capture's page.
  ## This suite drives the renderer directly, so the branches a demo tree does
  ## not happen to contain are still covered.

  proc unverifiedPane(): EditorPane =
    EditorPane(availability: srcUnverified,
               reason: "No source bundle is published for the code that ran.")

  proc positioned(step, total: int): DebugControlsPane =
    DebugControlsPane(step: step, totalSteps: total, positioned: step > 0)

  test "the head is drawn, and it states the coordinate the session HAS":
    # The step, and only the step. No line number is claimed, because
    # `recording.stepsPositioned` is 0 for every real transaction — a line here
    # would be invented.
    let html = dbgc.renderSource(unverifiedPane(), positioned(128, 208))
    check occurrences(html, "<div class=\"srcpos\" aria-current=\"true\">") == 1
    check occurrences(html, "<span class=\"p\" aria-hidden=\"true\">▶</span>") == 1
    check "The session is stopped at step " in html
    check "<span class=\"num\">128</span>" in html
    check "<span class=\"num\">208</span>" in html
    # The head is ABOVE the explanation, not merged into it: the answer first,
    # then why there is no text to put it on.
    check html.find("srcpos") < html.find("srcnone")
    # …and `.srcnone` itself is untouched.
    check "class=\"panenote\"" in html
    check "Stepping continues at instruction level." in html

  test "it reads the same channels as the current source line, not new ones":
    # A reader who has learned one page's position mark must recognise this
    # one. Same fill token, same rail token, same glyph — and no new token, in
    # particular nothing from the danger family, which on this product means a
    # REVERTED execution.
    let css = debugRouteCss
    check ".srcpos{" in css
    check "background:var(--bt-mark-position-surface)" in css
    check "border-left:var(--bt-stroke-thick) solid var(--bt-mark-position)" in css
    check ".srcpos .p{" in css
    let rule = css[css.find(".srcpos{") ..< css.find(".srcnone{")]
    check "--bt-status-bad" notin rule
    check "--bt-status-danger" notin rule
    check "#" notin rule            # no raw colour, on the rule itself

  test "CONTROL: an UNPOSITIONED pane draws no head at all":
    # "Step 0 of 0" would be the confident-but-wrong answer this product may
    # not ship, and it is what an unguarded head renders on the on-demand row.
    # Three ways to be unpositioned, each one silent.
    for pos in [DebugControlsPane(),
                positioned(0, 208),
                DebugControlsPane(step: 128, totalSteps: 0, positioned: true)]:
      let html = dbgc.renderSource(unverifiedPane(), pos)
      check "srcpos" notin html
      check "class=\"srcnone\"" in html          # the pane still speaks
    # And a caller that passes nothing gets the old markup exactly.
    check "srcpos" notin dbgc.renderSource(unverifiedPane())

  test "MUTATION BITE: the coordinate is the SESSION's, not a constant":
    # The assertions above are satisfied by a head that hard-codes 128/208.
    let a = dbgc.renderSource(unverifiedPane(), positioned(7, 41))
    check "<span class=\"num\">7</span>" in a
    check "<span class=\"num\">41</span>" in a
    check "128" notin a
    check "208" notin a

  test "MUTATION BITE: a SOURCE-level pane draws the line, never the head":
    # The two outputs are exclusive. A pane that can mark a line marks the
    # line; adding the head there would be a second position mark on one page,
    # disagreeing with the first the moment either moved.
    var pane = EditorPane(
      availability: srcSourceLevel, activeIndex: 0,
      documents: @[newSourceDocument(
        "src/shield.nr", "noir",
        readFile(clientRoot / "fixtures" / "demo-session" / "src" / "shield.nr"))])
    focus(pane, "src/shield.nr", 32)
    let html = dbgc.renderSource(pane, positioned(128, 208))
    check "srcpos" notin html
    check occurrences(html, "aria-current=\"true\"") == 1
    check occurrences(html, "<span class=\"p\" tabindex=\"-1\"") == 1
    check occurrences(html, ">▶</span>") == 1
    # The twin, through the same call: strip the documents and the SAME
    # controls now produce the head. So "no head" above is about the pane's
    # availability and not about the controls being ignored.
    check "srcpos" in dbgc.renderSource(unverifiedPane(), positioned(128, 208))

suite "M8b — availability decides the landing, not a preference":

  test "every transaction's phase follows its published availability":
    var seenPhases: Table[string, int]
    for h in txHashes:
      let s = sessionFor(h)
      let want = headlineAvailabilityOf(h)
      # `hasFrame` is what says "there is a session here", NOT `phase`: the
      # static route serves a positioned frame with the engine still unfetched,
      # so a published trace is `spFetching` + `hasFrame`, and reading the
      # phase alone would report every ready transaction as still loading.
      let got =
        if s.hasFrame:
          (if s.integrity == siDivergent: "divergent" else: "ready")
        else:
          case s.phase
          of spAwaitingGeneration: "onDemand"
          of spUnavailable: "absent-or-unsupported"
          else: "other"
      case want
      of "ready": check got == "ready"
      of "divergent": check got == "divergent"
      of "onDemand": check got == "onDemand"
      else: check got == "absent-or-unsupported"
      seenPhases.mgetOrPut(want, 0) += 1
    # The loop actually visited more than one state.
    check seenPhases.len >= 3

  test "a query parameter cannot conjure a session availability refuses":
    # §7.0's rule is that `trace.availability` decides. `?state=`, `?pane=` and
    # `?t=` select a position inside a session, never whether one exists — and
    # a static route cannot read them at all, which is the strongest possible
    # form of that guarantee.
    let plain = debugHtml(onDemandTx)
    let (status, asked, _) = renderRoute(root,
      "/" & Chain & "/tx/" & onDemandTx & "/debug")
    check status == 200
    check asked == plain
    check "Generate trace" in plain
    check "class=\"dc\"" notin plain          # no stepping toolbar

  test "on-demand offers generation and states what it costs":
    let html = debugHtml(onDemandTx)
    check "Generate trace" in html
    check "signed-in account" in html
    check "No trace recorded yet" in html
    # No pretence: nothing to download, nothing to share.
    check "Download trace" notin html
    check ">Share<" notin html

  test "divergent opens, and says so in a banner that cannot be dismissed":
    let html = debugHtml(divergentTx)
    check "class=\"dbgbanner bad\"" in html
    check "Divergent trace" in html
    check "class=\"dc\"" in html               # it still steps
    # A banner with a dismiss control would be dismissible; there is none.
    let bannerStart = html.find("class=\"dbgbanner")
    let bannerEnd = html.find("</div>", bannerStart)
    check "panedismiss" notin html[bannerStart .. bannerEnd]

  test "a ready session shares the WHOLE §6.0a payload, not a coordinate alone":
    ## M8a: "Share **always** emits an anchor, never `t` alone", and §6.0a: `c`
    ## is required whenever `t` is present.
    ##
    ## The payload used to be `?t=<n>#<element-id>`. Both halves were wrong:
    ## there was no witness, so this product's own reader treats the coordinate
    ## as unverifiable; and the fragment carried an HTML element id where a
    ## recovery anchor should have been, which no client can resolve. The check
    ## is that the emitted URL PARSES as a valid link, through the SDK's own
    ## grammar, rather than that it contains some substrings.
    let s = sessionFor(readyTx)
    let html = debugHtml(readyTx)
    let at = html.find("href=\"?v=")
    check at > 0
    let stop = html.find('"', at + 6)
    # The attribute as a BROWSER reads it: `escapeAttr` turns every `&` into
    # `&amp;`, so the raw substring is not a URL and parsing it would silently
    # see one field and five unknown ones.
    let href = html[at + 6 ..< stop].replace("&amp;", "&")

    let parts = href.split('#')
    check parts.len == 2
    # The fragment still scrolls a scripting-off visitor to the line.
    check parts[1].startsWith("L-")

    let parsed = parseDeepLink(parts[0])
    check parsed.errors.len == 0
    check parsed.link.version == DeepLinkVersion
    check parsed.link.coordinate == $s.timeCoordinate
    check parsed.link.witness.len > 0
    # The anchor is a `src:` anchor naming a real file and the line the session
    # is on — a property of the transaction, resolvable in any correct trace.
    check parsed.link.anchor.kind == akSource
    check parsed.link.anchor.data == activeDocument(s.editor).path & ":" &
                                     $s.editor.currentLine
    # And it is a witness OF the artifact this page recommends, not a constant.
    check checkWitness(parsed.link.witness, s.traceContentHash) == wvMatches
    check s.traceContentHash.len > 0

  test "with no position there is no share link, only a stated refusal":
    var s = sessionFor(readyTx)
    for d in 0 ..< s.editor.documents.len:
      for i in 0 ..< s.editor.documents[d].lines.len:
        s.editor.documents[d].lines[i].current = false
    let html = debugPg.debugPage(s)
    check "btn disabled sm" in html
    check "href=\"?v=" notin html

suite "M8b — the metadata pane and the page cannot diverge":

  test "the pane and the page render the same facts, from one producer":
    # Two surfaces, and after §7.0 they are served at different addresses: the
    # metadata PAGE is what a transaction with no session gets, and the metadata
    # PANE is what one with a session gets. Both are checked against the same
    # producer, on their own transactions.
    let info = chainInfo(root, Chain)
    for h in [onDemandTx, readyTx]:
      let v = txView(root, info, h)
      let rows = txMetadataRows(Chain, v, info)
      check rows.len > 0
      let served = txHtml(h)
      let deep = debugHtml(h)
      for r in rows:
        check (">" & r.label & "</dt>") in served
        check (">" & r.label & "</dt>") in deep
        check r.value in served
        check r.value in deep

  proc dtLabelsIn(html, open: string): HashSet[string] =
    ## The `<dt>` set of one `<dl>`, by its opening tag.
    let start = html.find(open)
    doAssert start > 0, "no " & open & " in the served document"
    let stop = html.find("</dl>", start)
    let grid = html[start ..< stop]
    var i = 0
    while true:
      let at = grid.find("<dt>", i)
      if at < 0: break
      let close = grid.find("</dt>", at)
      result.incl grid[at + 4 ..< close]
      i = close

  test "neither surface carries a fact the shared producer does not name":
    # The other direction, and the one a shared helper does not give you for
    # free: either surface can always grow a hand-written row beside the loop.
    # The rendered <dt> set must equal the producer's label set exactly — on
    # the metadata page's `<dl class="dl">` AND on the pane's `<dl
    # class="mddl">`, which after §7.0 is the grid a crawler of a ready
    # transaction is actually served.
    let info = chainInfo(root, Chain)

    var expectedPage = initHashSet[string]()
    for r in txMetadataRows(Chain, txView(root, info, onDemandTx), info):
      expectedPage.incl r.label
    check dtLabelsIn(txHtml(onDemandTx), "<dl class=\"dl\">") == expectedPage

    var expectedPane = initHashSet[string]()
    for r in txMetadataRows(Chain, txView(root, info, readyTx), info):
      expectedPane.incl r.label
    check dtLabelsIn(txHtml(readyTx), "<dl class=\"mddl\">") == expectedPane
    check dtLabelsIn(debugHtml(readyTx), "<dl class=\"mddl\">") == expectedPane

  test "the decoded input has one producer too, on both surfaces":
    # §7.2 section 3. It used to be a hand-written `<dl>` in `pages/tx.nim`
    # only, which after §7.0 would have meant a ready transaction's own URL
    # stopped serving its selector and calldata at all.
    let info = chainInfo(root, Chain)

    var expectedPage = initHashSet[string]()
    for r in txPayloadRows(txView(root, info, onDemandTx)):
      expectedPage.incl r.label
    check expectedPage.len > 0
    let pageGrids = txHtml(onDemandTx)
    let decoded = pageGrids[pageGrids.find("Decoded input") .. ^1]
    check dtLabelsIn(decoded, "<dl class=\"dl\">") == expectedPage

    var expectedPane = initHashSet[string]()
    for r in txPayloadRows(txView(root, info, readyTx)):
      expectedPane.incl r.label
    check dtLabelsIn(txHtml(readyTx), "<dl class=\"mddl mdpayload\">") ==
          expectedPane

  test "the pane carries §7.2's chain-native payload, so the URL keeps it":
    # §7.2 section 8 — "the chain-native transaction and receipt JSON,
    # verbatim". The transaction's own URL served it before this milestone and
    # still does, on both shapes; that is the crawl surface not regressing.
    let info = chainInfo(root, Chain)
    for h in [onDemandTx, readyTx]:
      let native = txNativePayload(txView(root, info, h))
      check native.len > 0
      check "class=\"raw\"" in markup(txHtml(h))
      check "Raw (chain-native)" in markup(txHtml(h))

  test "a mutation to the underlying view moves BOTH surfaces":
    let info = chainInfo(root, Chain)
    # The page half is driven from a transaction the page actually renders:
    # `txPage` refuses a published trace outright (§7.0), so the old spelling
    # of this test would now be asserting against an exception.
    var pv = txView(root, info, onDemandTx)
    var sv = txView(root, info, readyTx)
    let pageBefore = txPg.txPage(Chain, pv, info)
    let paneBefore = dbgc.renderMetadata(metadataPane(Chain, sv, info))

    pv.finality = "reorged"
    sv.finality = "reorged"
    let pageAfter = txPg.txPage(Chain, pv, info)
    let paneAfter = dbgc.renderMetadata(metadataPane(Chain, sv, info))

    check pageBefore != pageAfter
    check paneBefore != paneAfter
    check "Reorged" in pageAfter
    check "Reorged" in paneAfter
    check "Reorged" notin pageBefore
    check "Reorged" notin paneBefore

  test "the status reason is coloured by the OUTCOME, not by its presence":
    # The demo's Aztec split transaction reports `partial` with both halves
    # succeeded, and its reason reads "private-part-succeeded-public-part-
    # succeeded". Naming that a "Status reason" and then painting it in the
    # danger colour says the same wrong thing twice, so the tone travels with
    # the label and comes from the same `case`.
    check outcomeReasonLabel(ooPartial) == "Status reason"
    check outcomeReasonTone(ooPartial) == "note"
    check outcomeReasonLabel(ooReverted) == "Revert reason"
    check outcomeReasonTone(ooReverted) == "bad"

    # …and the pane renders the tone it was given, on a real transaction.
    var partialTx = ""
    for h in txHashes:
      if txView(root, chainInfo(root, Chain), h).outcome == ooPartial:
        partialTx = h
        break
    check partialTx.len > 0
    let html = debugHtml(partialTx)
    check "class=\"mdrevert note\"" in html
    check "class=\"mdrevert bad\"" notin html

  test "a deliberate SECOND source is detectable as a disagreement":
    # The check the milestone asks for: "a deliberate second source fails the
    # check". A hand-built row set that adds a fact produces a label the page
    # does not render, and the comparison above is what catches it.
    let info = chainInfo(root, Chain)
    let v = txView(root, info, readyTx)
    var second = txMetadataRows(Chain, v, info)
    second.add MetaRow(label: "Gas price", value: "7 gwei")
    var secondLabels = initHashSet[string]()
    for r in second: secondLabels.incl r.label
    var producerLabels = initHashSet[string]()
    for r in txMetadataRows(Chain, v, info): producerLabels.incl r.label
    check secondLabels != producerLabels

  test "the static route never claims a live engine (§8, and the 18 MB wasm)":
    # The honesty the phase split exists for. The panes are FULL and the
    # toolbar is INERT, and the page says which is which — because the replay
    # engine is an 18 MB wasm bundle that no statically exported page has
    # fetched. A toolbar rendered enabled here would lie on the first click.
    let s = sessionFor(readyTx)
    check s.hasFrame
    check s.phase == spFetching
    check not s.engineLive
    for b in s.controls.buttons:
      check not b.enabled
    check s.controls.positioned          # …but the position is real

    let html = debugHtml(readyTx)
    check "data-session-phase=\"fetching\"" in html
    # Every stepping control carries the inert class; none is left enabled.
    check occurrences(html, "class=\"dcbtn off\"") == s.controls.buttons.len
    check "class=\"dcbtn\"" notin html
    # …and each one says so as a CONTROL, on the accessibility tree and in its
    # own tooltip, rather than relying on a paragraph elsewhere on the page.
    # Counted inside the CONTROL GROUP and not across the document. The loop
    # rail marks its unreachable passes inert with the same attribute, for the
    # same reason, and a page-wide count would silently become a count of two
    # different things. `renderControls`' output is embedded verbatim, so this
    # is a stronger assertion than the page-wide one it replaces: it also
    # establishes that the markup in the bar IS the renderer's.
    let controlsHtml = dbgc.renderControls(s.controls)
    check controlsHtml in html
    check occurrences(controlsHtml, "aria-disabled=\"true\"") ==
          s.controls.buttons.len
    check "aria-disabled=\"false\"" notin controlsHtml
    for b in s.controls.buttons:
      check (controlLabel(b.action) &
             " — inert until the replay engine loads") in html

    # The phase is NAMED, the sequence is shown, and the wait is quantified.
    check "class=\"phaserail\"" in html
    for p in [spFetching, spOpening, spPositioning]:
      # The one-word chip is what the visitor READS …
      check (">" & phaseShortLabel(p) & "<") in html
      # … and the sentence it is short for is still on the page, as its title.
      check ("title=\"" & phaseLabel(p)) in html
    check phaseShortLabel(spFetching) != phaseLabel(spFetching)
    check approxMegabytes(ReplayEngineWasmBytes) in html

    # The engine-notice row is GONE — the whole row, not just its wording. The
    # sentence it carried, the class that styled it, and the stylesheet rule
    # behind that class all have to be absent, because the stylesheet is
    # INLINED and a surviving rule would keep the removed band's name in the
    # served bytes.
    check "enginenotice" notin html
    check "enginetext" notin html
    check "This is the session's first frame" notin html
    check "fetched once and cached" notin html
    check ".enginenotice" notin debugRouteCss
    check ".enginetext" notin debugRouteCss
    # What it actually contributed survived, beside the controls it explains.
    check "class=\"dcphase\"" in html

    # …and it is not a spinner wearing words. Checked over the MARKUP with the
    # stylesheet removed: `<style>` carries a comment naming the thing being
    # ruled out, and matching against it would make this assertion pass or fail
    # on prose.
    let markup = html.split("</style>")[1]
    check "<progress" notin markup
    check "spin" notin markup

  test "the engine origin is configuration, and its default is same-origin":
    # CodeTracer-Embed-SDK §5.1: `assetBase` must not default to a cross-origin
    # URL. A default that reached another host would make every deployment of
    # this repository a client of an origin its operator never named. The stable
    # IDE origin a cross-origin build names is ide.codetracer.com (same
    # web-codetracer Pages bundle as web-codetracer.pages.dev) — the Pages
    # project keeps its web-codetracer name; only the hostname moved.
    check not replayEngineIsCrossOrigin()
    check ReplayEngineBase.startsWith("/")
    check "http" notin ReplayEngineBase
    # The decision is DERIVED from the value, so a build cannot declare one
    # thing and load another.
    check isCrossOrigin("https://ide.codetracer.com/")
    check isCrossOrigin("http://example.invalid/")
    check isCrossOrigin("//example.invalid/")
    check not isCrossOrigin("/replay-engine/")
    check not isCrossOrigin("")
    # Whatever it is, the built page records it, so hydration reads one value
    # and a reviewer can see which origin a build trusts.
    let html = debugHtml(readyTx)
    check ("data-replay-engine=\"" & ReplayEngineBase & "\"") in html
    # A same-origin build says nothing about an origin, because there is none
    # to disclose.
    check "class=\"engineorigin\"" notin html

  test "sharing does not wait for the engine, but does need a container":
    # Sharing the frame you are looking at is exactly what someone does while
    # 18 MB is still arriving, so `canShare` must not be gated on the engine.
    let ready = sessionFor(readyTx)
    check ready.canShare
    check not ready.engineLive
    check "Share" in debugHtml(readyTx)
    # An on-demand transaction has a DERIVABLE container path and no published
    # container, so it shares nothing.
    let pending = sessionFor(onDemandTx)
    check not pending.canShare
    check "Download trace" notin debugHtml(onDemandTx)

  test "the facts survive the collapse to a slim bar (§8)":
    let pane = debugHtml(readyTx)
    check "id=\"pane-metadata\"" in pane
    check "class=\"mddl\"" in pane
    # …and the split transaction's executions are named in the pane, which is
    # the only place a deep-linked visitor can see the half they are not in.
    var splitTx = ""
    for h in txHashes:
      if txView(root, chainInfo(root, Chain), h).executions.len > 1:
        splitTx = h
        break
    check splitTx.len > 0
    let splitHtml = debugHtml(splitTx)
    check "class=\"mdexec\"" in splitHtml
    check ">private<" in splitHtml
    check ">public<" in splitHtml

suite "§13 — values are copyable, and nothing pretends to copy them":

  test "a value rendered in FULL is one click from being selected":
    let s = sessionFor(readyTx)
    let html = debugHtml(readyTx)
    # The class has a rule behind it, in the stylesheet that is actually
    # shipped. Without this the class is decoration and every check below
    # would pass over markup that does nothing.
    check (".copyable{user-select:all") in debugRouteCss
    check ".copyable:hover{" in debugRouteCss

    # Frame names, event labels and variable values — the machine values a
    # reader takes out of a session — each carry it.
    check "class=\"ctname copyable\"" in html
    check "class=\"evlabel copyable\"" in html
    check "class=\"stval copyable\"" in html
    # …on every row, not on the first one only.
    check occurrences(html, "class=\"ctname copyable\"") >=
          s.calltrace.frames.len
    check occurrences(html, "class=\"stval copyable\"") == s.state.values.len

    # Addresses and targets in the metadata pane. Asserted through the shared
    # producer, so a row it stops marking as an identifier stops being asserted
    # here too rather than silently losing the affordance.
    let info = chainInfo(root, Chain)
    let v = txView(root, info, readyTx)
    var plainIdentifiers = 0
    for r in txMetadataRows(Chain, v, info):
      if r.identifier and r.href.len == 0 and r.badge.len == 0:
        check ("class=\"identifier copyable\">" & escapeHtml(r.value)) in html
        inc plainIdentifiers
    check plainIdentifiers > 0        # the loop had a body

  test "a TRUNCATED identifier is not copyable, and carries the full value":
    ## The trap this rule exists for: `user-select:all` on `0xa45907…9296`
    ## selects an ellipsis. A value that cannot be copied correctly must not
    ## advertise that it can.
    let s = sessionFor(readyTx)
    let html = debugHtml(readyTx)

    check truncatedHash(s.txHash) != s.txHash          # it IS truncated
    check truncHash(s.txHash, 10, 8) != s.txHash
    check "class=\"dbgid identifier copyable\"" notin html
    check "class=\"identifier mdhash copyable\"" notin html
    # …and the full value is on the element, both for a reader (title) and for
    # the hydration that will turn these into real copy buttons (data-copy).
    check ("class=\"dbgid identifier\" title=\"" & s.txHash &
           "\" data-copy=\"" & s.txHash & "\"") in html
    check ("data-copy=\"" & s.txHash & "\"") in html
    check occurrences(html, "data-copy=\"" & s.txHash & "\"") == 2  # bar + pane

  test "there is no copy CONTROL, because nothing could honour one":
    ## The page ships no JavaScript, so a copy button would be an affordance
    ## that lies on click — the `panedismiss` defect again. The affordance is
    ## CSS; the control is staged, not shipped.
    let html = debugHtml(readyTx)
    # No executable script in a build that declares no hydration bundle, and
    # NO copy control in the served markup even in a build that does — the
    # button is added by hydration, at run time, and only where
    # `navigator.clipboard` exists. `copybtn` is the class it adds, so its
    # absence here is the staging §13 describes.
    check executableScripts(html) == 0
    check "copybtn" notin html
    check "navigator.clipboard" notin html
    check ">Copy<" notin html
    # A `data-copy` is inert markup, not a control: it carries no role, no
    # tabindex and no handler.
    check "data-copy" in html
    check "onclick" notin html
    check "onkeydown" notin html
    check "javascript:" notin html

  test "a source line stays copyable WITHOUT its gutter":
    ## Source lines are deliberately not `.copyable` — one click selecting a
    ## whole line would make selecting a sub-expression impossible. What makes
    ## them copyable is the negative rule on the gutter, so a drag across the
    ## pane yields code and not line numbers.
    let html = debugHtml(readyTx)
    check ".srcline .n{" in debugRouteCss
    check "user-select:none" in debugRouteCss
    check "class=\"srcline" in html
    check "srcline copyable" notin html

suite "M8b — the crawl surface is unchanged":

  test "the transaction route keeps its robots class and canonical link":
    # Asserted against a stored baseline (client/tests/baselines/), so the SEO
    # surface cannot regress silently.
    let baseline = parseJson(readFile(
      clientRoot / "tests" / "baselines" / "tx-crawl-surface.json"))
    # Both trees, so the assertion covers all five availability rows and not
    # only the three the demo generator publishes.
    var sessions, pages = 0
    for (r, dir) in [(root, workDir), (degradedRoot, degradedDir)]:
      for h in txHashes:
        let html = txHtmlIn(r, h)
        check ("<meta name=\"robots\" content=\"" &
               baseline["txRobots"].getStr & "\"") in html
        check ("<link rel=\"canonical\" href=\"" & SiteDomain & "/" & Chain &
               "/tx/" & h & "\"") in html
        # The inlined entry data the crawler is served is still there, on both
        # shapes §7.0 gives this route.
        let body = markup(html)
        check baseline["txMustContain"].getElems.allIt(it.getStr in body)
        # …including the transaction's OWN HASH, in full. It cannot be a
        # `mustContain` literal because it differs per transaction, and it is
        # the fact most easily lost by a change of shape: both shapes carry a
        # truncation in their hero, and a page that states its subject's
        # identity only as `0x5c6787…f8df` has stopped serving the identifier
        # the URL is addressed by. §7.2 section 1: "hash with copy".
        check h in body
        if isSession(html):
          inc sessions
          check baseline["txSessionMustContain"].getElems.allIt(it.getStr in body)
        else:
          inc pages
          check baseline["txPageMustContain"].getElems.allIt(it.getStr in body)
    # Neither branch is passing over an empty loop.
    check sessions > 0
    check pages > 0

  test "the debug route adds no second indexable copy of the transaction":
    let baseline = parseJson(readFile(
      clientRoot / "tests" / "baselines" / "tx-crawl-surface.json"))
    let html = debugHtml(readyTx)
    check ("<meta name=\"robots\" content=\"" &
           baseline["debugRobots"].getStr & "\"") in html
    check ("<link rel=\"canonical\" href=\"" & SiteDomain & "/" & Chain &
           "/tx/" & readyTx & "\"") in html
    check baseline["debugRobots"].getStr.startsWith("noindex")

  test "the debug route is rendered but NOT submitted to search engines":
    # Rendered and submitted are different questions, and this is where they
    # part company. SEO-And-Crawl-Budget.md §5 gives every `noindex` class
    # "Sitemap: No", so a sitemap entry here would invite a crawler to fetch
    # the transaction's content a second time in order to be told not to index
    # it — the duplicate crawl surface M8b requires this milestone not to add.
    let baseline = parseJson(readFile(
      clientRoot / "tests" / "baselines" / "tx-crawl-surface.json"))
    check not baseline["debugInSitemap"].getBool
    let all = staticRoutes(root)
    let submitted = sitemapRoutes(root)
    var renderedDebug, submittedDebug = 0
    for route in all:
      if route.endsWith("/debug"): inc renderedDebug
    for route in submitted:
      if route.endsWith("/debug"): inc submittedDebug
    # The subject exists: this is not passing over an empty route set.
    check renderedDebug == txHashes.len
    check renderedDebug > 0
    check submittedDebug == 0
    # …and nothing ELSE was dropped on the way, so the transaction route's own
    # sitemap membership is exactly what it was.
    #
    # M9 added two more exclusion classes, both from SEO-And-Crawl-Budget.md
    # §6's own table — class N2 ("Never" promoted: `/search`; `/settings` was
    # the other member until the page was removed) and
    # pagination variants ("Never submitted") — so the identity is now stated
    # over the UNION of the three rather than over `/debug` alone. The bite is
    # unchanged and is in the second loop: every route that is not in one of
    # the three named classes must still be submitted, so narrowing the
    # sitemap to exclude, say, every `noindex` entity page fails here.
    proc excludedForAStatedReason(route: string): bool =
      route.endsWith("/debug") or routeClass(route) == rcUtility or
        isPaginationRoute(route)
    var excluded = 0
    for route in all:
      if excludedForAStatedReason(route): inc excluded
    check excluded > renderedDebug        # the two new classes are non-empty
    check submitted.len == all.len - excluded
    for route in all:
      if not excludedForAStatedReason(route): check route in submitted
    # Each new class is genuinely excluded, named rather than counted: a class
    # that stopped being excluded would still satisfy the arithmetic above if
    # another one grew by the same amount.
    check "/search" notin submitted
    check "/search" in all
    # `/settings` IS a route again — it carries the keyboard-shortcut preset
    # chooser and the full binding list — and it is class N2 like `/search`:
    # generated and served, never submitted. Both halves are asserted, because
    # "absent from the sitemap" is also true of a route that stopped being
    # generated by mistake, and that is exactly the state this page was in
    # between `2e0499c` and the commit that rebuilt it.
    check "/settings" notin submitted
    check "/settings" in all
    # N2 has TWO members, so the exclusion above is not vacuous and is not
    # carried by a single route either.
    check routeClass("/search") == rcUtility
    check routeClass("/settings") == rcUtility
    var paginated = 0
    for route in all:
      if isPaginationRoute(route):
        inc paginated
        check route notin submitted
    check paginated > 0

suite "the embedded demo on the home page is the same session surface":

  test "the home page carries a real, positioned session — not a picture":
    let (status, html, _) = renderRoute(root, "/")
    check status == 200
    check "id=\"live-demo\"" in html
    # The same pane renderers, so it cannot decay into a screenshot.
    check "class=\"srcline" in html
    check "id=\"pane-calltrace\"" in html
    check "Open the full session" in html
    # …and it is positioned, which is what makes it a demo rather than a shell.
    check "Stopped mid-execution at step" in html
    check "class=\"srcline cur" in html

suite "hydration — the seams the bundle reads, and the honesty they preserve":
  ## What hydration needs from the SERVED page, checked on the served page.
  ##
  ## Every one of these is inert markup, and that is the property under test as
  ## much as the presence is: `Debugger-Integration` §3 deferred making
  ## call-trace and event-log rows jump targets specifically because "until
  ## hydration lands such a link would reload the page at a coordinate the
  ## static export cannot honour", and "an affordance that cannot act is the
  ## defect this route has already removed twice". So the coordinate ships and
  ## the affordance does not.

  test "a build that ships no bundle ships no script, and is unchanged":
    ## §7.0's guarantee at BUILD time. `HydrationBundle` defaults to empty, and
    ## the page a default build serves is the page this route has always
    ## served. If this ever fails, some build has begun emitting a `<script>`
    ## for a file it may not have produced.
    check HydrationBundle.len == 0
    let html = debugHtml(readyTx)
    check executableScripts(html) == 0
    check "<script src=" notin html
    # …and the whole toolbar is still honestly inert, which is the state the
    # bundle's absence must leave behind.
    let s = sessionFor(readyTx)
    check occurrences(html, "class=\"dcbtn off\"") == s.controls.buttons.len

  test "every control names the MOVE it would make, in the enum's spelling":
    ## Hydration binds a button to a command by `data-action`. Matching on the
    ## label instead would make the toolbar's behaviour depend on its wording,
    ## so the attribute is derived from `DebugAction` and checked against it.
    let html = debugHtml(readyTx)
    let s = sessionFor(readyTx)
    check s.controls.buttons.len > 0
    for b in s.controls.buttons:
      check ("data-action=\"" & $b.action & "\"") in html
    check occurrences(html, "data-action=\"") == s.controls.buttons.len
    let markup = html.split("</style>")[1]
    # Distinct: eight buttons, eight different moves. A toolbar that emitted
    # one action eight times would satisfy the loop above.
    var seen: HashSet[string]
    for b in s.controls.buttons: seen.incl $b.action
    check seen.len == s.controls.buttons.len
    # The attribute is DATA, not an affordance: the inert button gains no role
    # and no handler from carrying it. Matched over the MARKUP — the inlined
    # stylesheet mentions `[tabindex]` in its focus rule, so a whole-document
    # match would answer itself with CSS.
    check "onclick" notin markup
    check "role=\"button\"" notin markup

  test "every control wears its OWN mark, and no media transport glyph":
    ## The defect this pins: Continue rendered `⏭` U+23ED — the media "next
    ## track / skip to end" mark — and Reverse Continue `⏮`, while `▶`, the
    ## universal Resume mark, sat on Step Over. A visitor identified the
    ## toolbar as a music player's, correctly.
    ##
    ## `components/icons` carries the survey; the rule it enforces is that a
    ## reverse mark is its forward partner reflected about the vertical axis,
    ## and that all eight are DISTINCT — the failure mode being Midas, an rr
    ## front-end that gives reverse-finish the forward step-out glyph verbatim,
    ## so two controls wear one mark and only the tooltip separates them.
    ##
    ## Signatures rather than whole paths: enough to tell all eight apart and
    ## to catch a swap, without pinning coordinates a redraw may legitimately
    ## move. That the marks are PAINTED, sized and coloured by the button is a
    ## claim markup cannot make and is asserted in a browser instead.
    let html = debugHtml(readyTx)
    let s = sessionFor(readyTx)
    check s.controls.buttons.len == 8
    const sigs = {
      daStepBackward:    "M8 11C6.897 11 6 11.897",   # codicon debug-step-back
      daStepForward:     "M9.99993 13C9.99993",       # codicon debug-step-over
      daReverseStepIn:   "M11.4 3.6L5.6 9.4",         # drawn, head bottom-left
      daStepIn:          "M4.6 3.6L10.4 9.4",         # drawn, head bottom-right
      daReverseStepOut:  "M10.4 9.4L4.6 3.6",         # drawn, head top-left
      daStepOut:         "M5.6 9.4L11.4 3.6",         # drawn, head top-right
      daReverseContinue: "M8.99688 2C8.80188",        # codicon debug-reverse-continue
      daContinue:        "M14.578 7.149L7.578",       # codicon debug-continue
    }.toTable
    var marks: HashSet[string]
    for b in s.controls.buttons:
      check sigs[b.action] in html
      marks.incl sigs[b.action]
    check marks.len == 8

    # The mirror rule, as arithmetic a reader can check: each drawn reverse
    # mark is its forward partner under x -> 16-x.
    check sigs[daReverseStepIn] == "M11.4 3.6L5.6 9.4"    # 4.6->11.4, 10.4->5.6
    check sigs[daReverseStepOut] == "M10.4 9.4L4.6 3.6"   # 5.6->10.4, 11.4->4.6

    # Not one of the eight old glyphs survives IN THE STRIP. Scoped to the
    # renderer's own output rather than the page, because `▶`/`◀` are ordinary
    # marks elsewhere on this page and a page-wide match would be answered by
    # something that is not this toolbar.
    let controlsHtml = dbgc.renderControls(s.controls)
    for glyph in ["⏭", "⏮", "▶", "◀", "⇱", "⇲", "⇤", "⇥"]:
      check glyph notin controlsHtml
    # `⏭` and `⏮` are the two the report was about and they belong to nothing
    # else here, so those two are held to the WHOLE page.
    check "⏭" notin html
    check "⏮" notin html

    # The marks are decoration beside a name the button already carries, so
    # they must not be announced. One accessible name per control, and none on
    # the marks themselves.
    check occurrences(controlsHtml, "aria-label=\"") == s.controls.buttons.len
    check occurrences(controlsHtml, "aria-hidden=\"true\"") ==
          s.controls.buttons.len
    for b in s.controls.buttons:
      check ("aria-label=\"" & controlLabel(b.action)) in controlsHtml

  test "the two controls that send `next` are named for what they send":
    ## `daStepForward` dispatches DAP `next` and `daStepBackward` `reverse-next`
    ## (`toolbarActionId`) — Step Over and its reverse. They were labelled "Step
    ## forward" and "Step backward", which names a granularity this product has
    ## no control for, and which reads next to Step In as though the two were
    ## alternatives rather than different-sized moves.
    ##
    ## The mapping itself is `hydrate/session_project.toolbarActionId`, which
    ## this hermetic suite cannot import — it reaches the Embed SDK — so what
    ## is pinned here is the NAME. `just debug-panes` compiles against the real
    ## SDK and is where the dispatch is exercised.
    check controlLabel(daStepForward) == "Step over"
    check controlLabel(daStepBackward) == "Reverse step over"
    let html = debugHtml(readyTx)
    check "Step forward" notin html
    check "Step backward" notin html

  test "every navigation row carries its coordinate AND its anchor as data":
    ## §3's deferred item, staged. `EventRow.step` and a frame's step are the
    ## same `?t=` the URL carries (§6.2); `data-anchor` is the row's §6.0a
    ## recovery anchor, and it is on the SERVED page because that is what lets a
    ## browser resolve an incoming link before it fetches an engine (§6.3's
    ## "before first paint").
    let html = debugHtml(readyTx)
    let s = sessionFor(readyTx)
    check s.calltrace.frames.len > 0
    check s.eventLog.rows.len > 0
    for f in s.calltrace.frames:
      check ("class=\"ctrow" in html)
      check ("data-step=\"" & $f.step & "\"") in html
      check f.anchor.len > 0
      check ("data-anchor=\"" & f.anchor & "\"") in html
    for r in s.eventLog.rows:
      check ("data-step=\"" & $r.step & "\"") in html
    # The anchors are DISTINCT, or a link would resolve to whichever row came
    # first and the whole recovery path would land in the wrong frame.
    var anchors: HashSet[string]
    for f in s.calltrace.frames: anchors.incl f.anchor
    check anchors.len == s.calltrace.frames.len

  test "a SERVED row is not a link; the same renderer makes a hydrated one":
    ## The staging, in one test, over one renderer.
    ##
    ## §3 deferred these because "until hydration lands such a link would
    ## reload the page at a coordinate the static export cannot honour". A
    ## static route still cannot honour one — a query string does not select a
    ## file — so the served page keeps rows that are rows. What changed is that
    ## hydration READS the coordinate now, so a link is honourable exactly
    ## where a script is running to honour it, and the producer decides which
    ## it is by supplying an `href` or not.
    let html = debugHtml(readyTx)
    let markup = html.split("</style>")[1]
    check "<a class=\"ctrow" notin markup
    check "<a class=\"evrow" notin markup
    # Matched over the markup, not the document: the inlined stylesheet names
    # `[tabindex]` in its focus rule, so a whole-document match would answer
    # itself with CSS.
    #
    # `tabindex="0"` and not `tabindex`. The claim is about the TAB ORDER —
    # "a served row is not a control" — and `0` is the spelling that puts an
    # element in it. The source pane's position cell carries `-1`, which is
    # the opposite: focusable programmatically and by `autofocus`, so the
    # pane opens at the position on a page with no script, and unreachable
    # by Tab. Counted rather than merely excluded, so that a future row that
    # DID take a `-1` would have to change this number and say why.
    check "tabindex=\"0\"" notin markup
    check occurrences(markup, "tabindex=") == 1
    check occurrences(markup, "tabindex=\"-1\"") == 1
    check "<span class=\"p\" tabindex=\"-1\"" in markup
    check "role=\"button\"" notin markup
    check "data-rows-navigable" notin markup

    # The other half of the staging, through the SAME renderers the bundle
    # links — so "hydration makes them links" is checked here rather than
    # asserted about a browser nobody runs in this suite.
    var s = sessionFor(readyTx)
    check s.calltrace.frames.len > 0
    check s.eventLog.rows.len > 0
    for i in 0 ..< s.calltrace.frames.len:
      s.calltrace.frames[i].href = positionQuery(
        s.traceContentHash, s.calltrace.frames[i].step,
        s.calltrace.frames[i].anchor)
    for i in 0 ..< s.eventLog.rows.len:
      s.eventLog.rows[i].href = positionQuery(
        s.traceContentHash, s.eventLog.rows[i].step, s.eventLog.rows[i].anchor)

    let live = dbgc.renderCallTrace(s.calltrace) & dbgc.renderEventLog(s.eventLog)
    check "<a class=\"ctrow" in live
    check "<a class=\"evrow" in live
    # An anchor is keyboard-operable by the platform: it takes focus and Enter
    # activates it. That is the whole reason it is an anchor rather than a
    # `role="button"` div with a click handler — neither Enter nor Space fires
    # a click on a div, so the previous staging shipped a control the research
    # calls PRIMARY that a keyboard could not reach.
    check "role=\"button\"" notin live
    check "tabindex" notin live
    # Every row's href is a valid §6.0a link, not a bare coordinate.
    var checked = 0
    for f in s.calltrace.frames:
      let parsed = parseDeepLink(f.href)
      check parsed.errors.len == 0
      check parsed.link.coordinate == $f.step
      check parsed.link.witness.len > 0
      check ("href=\"" & escapeAttr(f.href) & "\"") in live
      inc checked
    for r in s.eventLog.rows:
      let parsed = parseDeepLink(r.href)
      check parsed.errors.len == 0
      check parsed.link.coordinate == $r.step
      inc checked
    check checked == s.calltrace.frames.len + s.eventLog.rows.len

  test "the event log's rows are jump targets on the SAME terms as the frames":
    ## §4.2 calls a click on an event row "the single most valuable interaction
    ## in the product — 'take me to the line that wrote this value'", and the
    ## event log is the only surface on which an individual storage write is
    ## addressable. Call-trace rows became clickable with hydration; this is
    ## the assertion that the event rows are not a weaker case.
    var s = sessionFor(readyTx)
    check s.eventLog.rows.len > 0
    var kinds: HashSet[EventKind]
    for r in s.eventLog.rows: kinds.incl r.kind
    check evStorageWrite in kinds        # or this proves nothing about writes
    for i in 0 ..< s.eventLog.rows.len:
      s.eventLog.rows[i].href = positionQuery(
        s.traceContentHash, s.eventLog.rows[i].step, s.eventLog.rows[i].anchor)
    let live = dbgc.renderEventLog(s.eventLog)
    check occurrences(live, "<a class=\"evrow") == s.eventLog.rows.len
    # Every KIND is a target, not just the convenient ones.
    for r in s.eventLog.rows:
      check ("<a class=\"evrow k-" & $r.kind) in live
    # And the consensus-recorded kinds carry an anchor that survives
    # regeneration, per §6.0a's table.
    for r in s.eventLog.rows:
      case r.kind
      of evStorageWrite: check r.anchor.startsWith("sw:")
      of evEvent: check r.anchor.startsWith("log:")
      of evRevert: check r.anchor == "revert"
      of evCall, evOutput: check r.anchor == ""

  test "the source bundle is inlined as DATA, and it is the WHOLE file":
    ## The served pane used to be WINDOWED (`openAtCurrent`), so the served DOM
    ## did not contain the lines a backward step needed, and the island was what
    ## let hydration render a line the served page never had.
    ##
    ## THE ISLAND IS NOT THERE FOR THE WINDOW, and removing the window is what
    ## makes that visible rather than what threatens it. The served pane now
    ## holds every line of the ACTIVE document — but the island holds every line
    ## of every document in the bundle, and the active document is one of four.
    ## A step into `src/main.nr` needs a file the rendered pane paints on a
    ## different panel and the hydrated pane rebuilds from here; the counts below
    ## are asserted over the whole bundle for exactly that reason.
    let s = sessionFor(readyTx)
    let html = debugHtml(readyTx)
    check ("id=\"" & SourceIslandId & "\"") in html
    check "type=\"application/json\"" in html
    # It is not executable, so it does not count as a script.
    check executableScripts(html) == 0

    # The island round-trips through the SHIPPING encoder and decoder, and what
    # comes back is the whole bundle — every document, not just the one the
    # pane opened on.
    let active = activeDocument(s.editor)
    let island = encodeSourceIsland(s.editor)
    let restored = decodeSourceIsland(island, active.path, s.editor.currentLine)
    check restored.documents.len == s.editor.documents.len
    check restored.documents.len > 1        # the bundle really has several

    proc totalLines(p: EditorPane): int =
      for d in p.documents: result += d.lines.len
    proc totalExecuted(p: EditorPane): int =
      for d in p.documents:
        for ln in d.lines:
          if ln.executed: inc result

    check totalLines(restored) == totalLines(s.editor)
    # The island really is bigger than the ACTIVE document — or this test
    # proves nothing about why it is inlined at all. This is the whole
    # justification: the pane paints the file the session is in, and a step
    # into another file of the bundle needs a document the pane is not
    # currently drawing.
    check active.lines.len < totalLines(restored)
    check totalExecuted(s.editor) > 0
    check totalExecuted(restored) == totalExecuted(s.editor)
    # Text survives verbatim, and the pane opens on the file the session is IN
    # rather than on whichever document the export happened to open.
    check activeDocument(restored).path == active.path
    check activeDocument(restored).lines[0].text == active.lines[0].text
    # Re-lexed by the same lexer, so the hydrated pane is highlighted like the
    # served one rather than merely similarly.
    var tokensIn, tokensOut = 0
    for ln in active.lines: tokensIn += ln.tokens.len
    for ln in activeDocument(restored).lines: tokensOut += ln.tokens.len
    check tokensIn > 0
    check tokensOut == tokensIn
    # Exactly one line is current, and it is the session's.
    var currents = 0
    for d in restored.documents:
      for ln in d.lines:
        if ln.current:
          inc currents
          check ln.number == s.editor.currentLine
          check d.path == active.path
    check currents == 1

  test "the island cannot close its own element":
    ## Source is arbitrary text and `</script>` is a legal string in it. Inside
    ## a `<script>` element the content model is raw text with exactly one
    ## terminator, so an unescaped one would end the element early and spill the
    ## rest of the trace's source into the document as markup.
    var pane: EditorPane
    pane.availability = srcSourceLevel
    pane.documents = @[newSourceDocument(
      "evil.nr", "noir", "let s = \"</script><img onerror=x>\";\n")]
    let island = encodeSourceIsland(pane)
    check "</script" notin island
    check "<" notin island
    # …and it still decodes to the text it came from, so the escaping is a
    # transport detail and not a mutation of the source.
    let back = decodeSourceIsland(island, "evil.nr", 1)
    check back.documents[0].lines[0].text ==
          "let s = \"</script><img onerror=x>\";"

  test "a malformed island is nothing, not an exception":
    ## Hydration's contract is that a failure leaves the served DOM standing,
    ## which a raise crossing the entry point would break — it would abandon
    ## whatever had already been written.
    check decodeSourceIsland("", "a.nr", 1).documents.len == 0
    check decodeSourceIsland("not json", "a.nr", 1).documents.len == 0
    check decodeSourceIsland("[1,2,3]", "a.nr", 1).documents.len == 0
    check decodeSourceIsland("{}", "a.nr", 1).documents.len == 0
    # An island with documents but no match still renders them, with NO line
    # marked current — one position, or none, never two.
    var pane: EditorPane
    pane.availability = srcSourceLevel
    pane.documents = @[newSourceDocument("a.nr", "noir", "let x = 1;\n")]
    let back = decodeSourceIsland(encodeSourceIsland(pane), "other.nr", 3)
    check back.documents.len == 1
    for ln in back.documents[0].lines: check not ln.current

  test "hydration is offered a container on exactly the transactions a visitor is":
    ## `containerPath` is DERIVABLE for an on-demand execution, so its
    ## non-emptiness proves nothing — this page says so itself, about the
    ## download action. `data-trace` therefore reads the SAME predicate the
    ## download reads, and this is the check that they cannot drift apart: two
    ## predicates for "is there a container" is one predicate and a bug, and it
    ## was one — the demo tree's on-demand transaction had a `data-trace`
    ## pointing at a container that 404s while the button beside it correctly
    ## offered nothing.
    var checkedOffered, checkedRefused = 0
    for hash in txHashes:
      let s = sessionFor(hash)
      let html = debugHtml(hash)
      let hasDownload = ("download=\"trace.ct\"" in html)
      let offered = ("data-trace=\"/" & s.containerPath & "\"") in html and
                    s.containerPath.len > 0
      check offered == hasDownload
      if offered: inc checkedOffered else: inc checkedRefused
      if not offered: check "data-trace=\"\"" in html
    # Both sides of the rule were actually exercised by the demo tree.
    check checkedOffered > 0
    check checkedRefused > 0

  test "the served frame states the position hydration starts from":
    let s = sessionFor(readyTx)
    let html = debugHtml(readyTx)
    check ("data-step=\"" & $s.controls.step & "\"") in html
    check ("data-total-steps=\"" & $s.controls.totalSteps & "\"") in html
    check s.controls.totalSteps > 0

  test "the phase rail has ONE producer, and it goes quiet when the engine lives":
    ## Hydration re-renders the rail as the engine advances, so a copy of it in
    ## the bundle would be a second producer of the one element whose only job
    ## is to be an accurate statement about the engine. It is a shared renderer
    ## instead, and `pages/debug.nim` calls the same one.
    var s = sessionFor(readyTx)
    check s.phase == spFetching
    let fetching = dbgc.renderPhaseRail(s)
    check "class=\"phaserail\"" in fetching
    check (">" & phaseShortLabel(spFetching) & "<") in fetching
    check "class=\"phase on\"" in fetching
    # Each phase marks itself, and only itself.
    for p in [spFetching, spOpening, spPositioning]:
      s.phase = p
      let rail = dbgc.renderPhaseRail(s)
      check occurrences(rail, "class=\"phase on\"") == 1
      check ("class=\"phase on\" title=\"" & phaseLabel(p)) in rail
    # …and once the engine is live it renders nothing at all, which is how the
    # rail disappears on hydration without hydration knowing it exists.
    s.phase = spReady
    check s.engineLive
    check dbgc.renderPhaseRail(s) == ""
    # The served page's rail is this renderer's output, not a second one.
    check fetching in debugHtml(readyTx)

# ===========================================================================
# §6.0a — the link is READ, and every branch of the reading is visible
# ===========================================================================
#
# The route existed as a deep-link TARGET that never read its own link: `?t=`
# was written on every navigation and ignored on every arrival, so a shared
# link opened wherever the engine happened to land. §6.0a's precedence is the
# fix, and §8's rule is that no combination of missing witness, unresolvable
# anchor or absent artifact may produce a *silent* landing at the wrong
# position.
#
# The suite drives the SHIPPING resolver — `deeplink_landing.resolveLanding`,
# which `client/hydrate/hydrate.nim` calls — against the REAL demo session's
# rows, and asserts the RENDERED sentence, not only the struct. A page that
# resolved correctly and said nothing would pass a struct-only check and be
# exactly the defect.

suite "§6.0a — the five resolution branches, each one visible":

  let session = sessionFor(readyTx)
  let hash = session.traceContentHash
  # Nothing below is a test unless the fixture actually carries these.
  doAssert hash.len > 0,
    "the ready transaction has no traceContentHash — every witness branch " &
    "would collapse into `unknownArtifact` and four of the five cases would " &
    "be asserting about the same thing"
  doAssert session.calltrace.frames.len > 3
  doAssert session.eventLog.rows.len > 3

  let good = witnessFor(hash)                 ## a witness that matches
  let stale = "0123456789ab"                  ## one that does not
  doAssert checkWitness(good, hash) == wvMatches
  doAssert checkWitness(stale, hash) == wvDiffers

  # A row of each kind to anchor on, taken from the fixture rather than named.
  let anchoredFrame = session.calltrace.frames[^1]
  var anchoredEvent: EventRow
  for r in session.eventLog.rows:
    if r.anchor.startsWith("log:"): anchoredEvent = r
  doAssert anchoredEvent.anchor.len > 0

  proc land(payload: string; artifact = true;
            contentHash = hash): LinkLanding =
    resolveLanding(payload,
      artifactAvailable = artifact, currentContentHash = contentHash,
      calltrace = session.calltrace, eventLog = session.eventLog)

  proc noticeHtml(l: LinkLanding): string =
    ## What the visitor actually sees, through the renderer the page uses.
    var v = session
    v.landing = l.notice
    v.landingCoordinate = l.coordinate
    dbgc.renderPositionNotice(v)

  test "0. an ordinary visit resolves nothing and says nothing":
    ## Not step 5. "The link was honoured exactly" and "there was no link" are
    ## different facts, and only the second may render nothing without a
    ## sentence — a page that announced a failed recovery on every plain view
    ## would train readers to ignore the notice that matters.
    for payload in ["", "?", "#", "#L-src-shield-nr-32", "?utm_source=x"]:
      let l = land(payload)
      check not l.asked
      check l.coordinate == 0
      check l.notice.statement == ""
      check noticeHtml(l) == ""

  test "1. no replayable artifact — stated, and terminal":
    let l = land(positionQuery(hash, anchoredFrame.step, anchoredFrame.anchor),
                 artifact = false)
    check l.asked
    check l.notice.outcome == $poNoReplayableArtifact
    # Terminal: no position is offered, because there is nothing to position in.
    check l.coordinate == 0
    let html = noticeHtml(l)
    check html.len > 0
    check "not replayable" in html
    check "data-landing=\"" & $poNoReplayableArtifact & "\"" in html

  test "2. the witness matches — the exact step, and the ONLY silent branch":
    let l = land(positionQuery(hash, 41, "call:0.0.0"))
    check l.asked
    check l.notice.outcome == $poExact
    check l.coordinate == 41
    # §6.0a: only branch (2) is silent, and it is silent because the page is
    # showing precisely what was asked for.
    check l.notice.statement == ""
    check noticeHtml(l) == ""

  test "3. the witness differs — recovered through the anchor, and said so":
    ## The trace was regenerated, so `t` means nothing reliable. The anchor is
    ## a property of the TRANSACTION and still resolves, so the reader lands
    ## where the link meant and is told why it is not where the link said.
    for (anchor, want) in [(anchoredFrame.anchor, anchoredFrame.step),
                           (anchoredEvent.anchor, anchoredEvent.step)]:
      var link = DeepLink(version: DeepLinkVersion, coordinate: "999999",
                          witness: stale)
      let (a, err) = parseAnchor(anchor)
      check err == ""
      link.anchor = a
      let l = land(emitFragment(link))
      check l.notice.outcome == $poRecoveredByAnchor
      # It landed on the ANCHOR's coordinate, not the link's.
      check l.coordinate == want
      check l.coordinate != 999999
      let html = noticeHtml(l)
      check "regenerated" in html
      check "recovered" in html.toLowerAscii

  test "4. the anchor does not resolve — the nearest enclosing frame, plainly":
    ## A call path whose deepest segment this trace no longer makes still has a
    ## parent that ran. That is a weaker claim than the anchor's and gets a
    ## different sentence, which is the whole point of it being step 4 rather
    ## than a quiet variant of step 3.
    let parent = session.calltrace.frames[1]
    check parent.anchor.startsWith("call:")
    let missing = parent.anchor & ".99"
    # The premise: this path is genuinely not in the trace.
    for f in session.calltrace.frames: check f.anchor != missing

    var link = DeepLink(version: DeepLinkVersion, coordinate: "999999",
                        witness: stale)
    let (a, err) = parseAnchor(missing)
    check err == ""
    link.anchor = a
    let l = land(emitFragment(link))
    check l.notice.outcome == $poNearestEnclosingFrame
    check l.coordinate == parent.step
    let html = noticeHtml(l)
    check "could not be resolved" in html
    check "nearest" in html

    # A `src:` anchor for a line the trace never reaches, in a file it runs,
    # resolves the same way — the second of the two structural anchor kinds.
    let file = activeDocument(session.editor).path
    var srcLink = DeepLink(version: DeepLinkVersion, coordinate: "999999",
                           witness: stale,
                           anchor: Anchor(kind: akSource,
                                          data: file & ":99999"))
    let bySrc = land(emitFragment(srcLink))
    check bySrc.notice.outcome == $poNearestEnclosingFrame
    check bySrc.coordinate > 0
    check noticeHtml(bySrc).len > 0

  test "5. nothing usable — the start of the execution, plainly, and by REASON":
    ## Three ways to arrive here, and each says which one it was. "The trace was
    ## regenerated" and "this link predates the witness" are different facts
    ## about a link, and a reader who is being moved is owed the specific one:
    ## an older link's coordinate may well still be correct and merely cannot
    ## be CHECKED, so telling that reader the position was lost would itself be
    ## a confident wrong sentence.
    let start = startCoordinate(session.calltrace, session.eventLog)
    check start > 0

    # (a) a regenerated trace, no anchor
    let regenerated = land(emitFragment(DeepLink(
      version: DeepLinkVersion, coordinate: "999999", witness: stale)))
    check regenerated.notice.outcome == $poStartOfExecution
    check regenerated.coordinate == start
    check "regenerated" in noticeHtml(regenerated)

    # (b) an OLDER link: `t` with no `c` at all — §6.0's "Absent" row. This is
    # exactly the shape this page used to write on every navigation.
    let older = land("?t=999999")
    check older.asked
    check older.notice.outcome == $poStartOfExecution
    check older.coordinate == start
    check "predates the content witness" in noticeHtml(older)
    # And the grammar reported why, rather than accepting it silently.
    check older.parseErrors.len > 0

    # (c) the page knows no content hash, so the witness proves nothing.
    let unknown = land(positionQuery(hash, 41, ""), contentHash = "")
    check unknown.notice.outcome == $poStartOfExecution
    check "content hash is unknown" in noticeHtml(unknown)

    # The three sentences are DISTINCT, or "said plainly" would mean one
    # sentence covering three situations.
    var said: HashSet[string]
    for l in [regenerated, older, unknown]: said.incl l.notice.statement
    check said.len == 3

  test "NO branch lands silently, and the assertion is the rendered sentence":
    ## The property §8 makes load-bearing: "no combination of missing witness,
    ## unresolvable anchor or absent artifact may produce a *silent* landing at
    ## the wrong position".
    ##
    ## Driven as a matrix over every combination, with the rendered notice as
    ## the assertion. A resolver that landed correctly and rendered nothing
    ## passes a struct-only check and IS the defect.
    var seen: HashSet[string]
    var cases = 0
    let unreachableLine = "src:" & activeDocument(session.editor).path & ":99999"
    for artifact in [true, false]:
      for witness in ["", good, stale]:
        for anchor in ["", anchoredFrame.anchor, anchoredEvent.anchor,
                       "call:9.9.9", "log:99999", unreachableLine]:
          for coordinate in [0, 41, 999999]:
            if coordinate == 0 and anchor.len == 0: continue  # not a link
            var link = DeepLink(version: DeepLinkVersion, witness: witness)
            if coordinate > 0: link.coordinate = $coordinate
            if anchor.len > 0:
              let (a, err) = parseAnchor(anchor)
              check err == ""
              link.anchor = a
            let l = land(emitFragment(link), artifact = artifact)
            inc cases
            check l.asked
            check l.notice.outcome.len > 0
            let html = noticeHtml(l)
            if l.notice.outcome == $poExact:
              # The one silent branch, and it is silent only when the witness
              # actually matched AND a coordinate was carried.
              check witness == good
              check coordinate > 0
              check artifact
              check html == ""
            else:
              # Everything else SPEAKS. Checked in the markup, with a real
              # sentence in it — not merely a non-empty element.
              check html.len > 0
              check "class=\"dbgnotice\"" in html
              check ("data-landing=\"" & l.notice.outcome & "\"") in html
              let body = html[html.find("noticetext") .. ^1]
              check body.count(' ') >= 6      # a sentence, not a token
              check '.' in body
              seen.incl l.notice.outcome
    # Every non-exact outcome §6.0a defines was actually produced, or the loop
    # above proves the property for a subset and reports it for all of it.
    check cases > 100
    for o in [poNoReplayableArtifact, poRecoveredByAnchor,
              poNearestEnclosingFrame, poStartOfExecution]:
      check $o in seen

  test "the notice slot exists on every served page, and is empty on all of them":
    ## The slot is hydration's target and `readUi`-style lookups must not fail
    ## silently. It is always present, and always EMPTY as served: a static
    ## route serves one file per path, so `?t=` cannot select a rendering and
    ## the resolution necessarily happens in the browser.
    for h in [readyTx, divergentTx, onDemandTx]:
      let html = debugHtml(h)
      check ("id=\"" & dbgc.PositionNoticeSlotId & "\"") in html
      check "class=\"dbgnotice\"" notin html
    # `:empty` is what hides it, so an empty slot must really be empty.
    check ("<div class=\"dbgnotices\" id=\"" & dbgc.PositionNoticeSlotId &
           "\"></div>") in debugHtml(readyTx)
    check ".dbgnotices:empty{display:none}" in debugRouteCss

  test "the served page carries the witness's subject, in every state":
    ## §6.0's comparison happens in a browser before the engine has opened
    ## anything, against "the artifact currently recommended". The page is the
    ## only thing that knows which that is.
    let readyHtml = debugHtml(readyTx)
    check session.traceContentHash.len > 0
    check ("data-content-hash=\"" & session.traceContentHash & "\"") in readyHtml
    # INDEPENDENT ORACLE: the container's bytes off disk, hashed here — not the
    # manifest read back through `reader`, which would be the producer checking
    # itself.
    let info = chainInfo(root, Chain)
    let t = traceView(root, info, readyTx)
    check t.containerPath.len > 0
    check session.traceContentHash ==
          contentHashSha1(readFile(workDir / t.containerPath))
    # Present, and empty, where there is no artifact — `absent` is a value
    # §6.0's table treats as unverifiable, not as agreement.
    check "data-content-hash=\"\"" in debugHtml(onDemandTx)

suite "the stepping chords — one table, and every surface reads it":
  ## WHY THIS SUITE EXISTS, AND WHAT ITS ABSENCE COST
  ##
  ## It was written after the keymap shipped, because the keymap shipped with a
  ## defect that this file was green through. `renderControls` defaults its
  ## keymap argument to `kmNone`, so every pre-existing call renders EXACTLY as
  ## it did before — 520 assertions passed, no source file under `tests/`
  ## contained the word `keymap`, and the suite's greenness was independent of
  ## whether the feature worked at all.
  ##
  ## A suite that is green because it is not looking is worse than no suite,
  ## because it is counted as coverage. So the discipline this file states at
  ## the top is applied here literally: EVERY CLAIM HAS A NEGATIVE. It is not
  ## enough that a keymap renders chords; a DIFFERENT keymap must render
  ## DIFFERENT chords, and `kmNone` must render none — otherwise the assertion
  ## is satisfied by a renderer that ignores its argument, which is the exact
  ## shape of the bug that got through.
  ##
  ## Nothing below writes a chord as an expected literal except where the
  ## SPELLING RULE itself is the subject. Everywhere else the expectation is
  ## read out of `km.bindings` — the same sequence the dispatcher matches
  ## against — so these tests cannot drift when a binding moves, and cannot
  ## pass by agreeing with a copy of the table.

  let presets = [kmLetters, kmVsCode, kmDesktop]
    ## The presets that bind something. `kmNone` is the negative and is used as
    ## one throughout rather than iterated with these.

  test "a chord that is DISPLAYED is a chord that DISPATCHES — the round trip":
    ## The one invariant the whole design rests on. `chordFor` feeds every
    ## tooltip and every dialog row; `actionFor` is what the `keydown` handler
    ## matches against. If those two ever disagree, a visitor is shown a key
    ## that does nothing — §10.5's "what they learn is that the shortcuts do
    ## not work".
    for id in presets:
      let km = keymapOf(id)
      check km.bindings.len > 0          # nothing here quantifies over nothing
      for b in km.bindings:
        let (dispatched, action) = km.actionFor(b.chord)
        check dispatched
        check action == b.action
        let (shown, c) = km.chordFor(b.action)
        check shown
        check c == b.chord

  test "no preset gives one chord two meanings, or one move two chords":
    ## A duplicate would make `actionFor` depend on binding order — the defect
    ## §10.5 records in the sibling docs, where `Shift+F5` is given to both
    ## Reverse Continue and Stop in a single table.
    for id in presets:
      let km = keymapOf(id)
      var chords: HashSet[string]
      var actions: HashSet[string]
      for b in km.bindings:
        chords.incl describe(b.chord)
        actions.incl $b.action
      check chords.len == km.bindings.len
      check actions.len == km.bindings.len

  test "every preset binds every move the toolbar offers, and no other":
    ## The dialog's claim to list "exactly the bound set" is only meaningful if
    ## the bound set IS the toolbar's set. Checked against the projection the
    ## page actually renders, not against the number eight.
    let s = sessionFor(readyTx)
    check s.controls.buttons.len > 0
    var offered: HashSet[string]
    for b in s.controls.buttons: offered.incl $b.action
    for id in presets:
      let km = keymapOf(id)
      var bound: HashSet[string]
      for b in km.bindings: bound.incl $b.action
      check bound == offered
    # THE NEGATIVE. `kmNone` binds none of them, so the equality above is a
    # statement about the keymap and not something every value satisfies.
    check keymapOf(kmNone).bindings.len == 0

  test "the served toolbar names NO key; a hydrated one names every bound key":
    ## `renderControls`' default is `kmNone` because the pre-hydration page has
    ## no `keydown` handler. A tooltip naming a chord there would be a promise
    ## the only build that cannot keep it is making.
    let s = sessionFor(readyTx)
    let served = dbgc.renderControls(s.controls)
    let letters = dbgc.renderControls(s.controls, keymapOf(kmLetters))

    # The served frame carries each control's plain name and no chord.
    for b in s.controls.buttons:
      check controlLabel(b.action) in served
      let (_, c) = keymapOf(kmLetters).chordFor(b.action)
      check ("(" & describe(c) & ")") notin served

    # The hydrated one carries the SAME names plus the chord from the table.
    for b in s.controls.buttons:
      let (bound, c) = keymapOf(kmLetters).chordFor(b.action)
      check bound
      check (controlLabel(b.action) & " (" & describe(c) & ")") in letters

    # THE NEGATIVE, and the one that would have caught a renderer ignoring its
    # argument: the two renders are not the same bytes.
    check served != letters

  test "a DIFFERENT preset renders DIFFERENT chords in the same tooltips":
    ## Three renders of one toolbar, one per preset. Each must name its own
    ## table's chord for a given move, which no single hardcoded string can
    ## satisfy.
    let s = sessionFor(readyTx)
    var rendered: seq[string]
    for id in presets:
      let km = keymapOf(id)
      let html = dbgc.renderControls(s.controls, km)
      for b in s.controls.buttons:
        let (bound, c) = km.chordFor(b.action)
        check bound
        check (controlLabel(b.action) & " (" & describe(c) & ")") in html
      rendered.add html
    # Pairwise distinct: three presets, three different toolbars.
    check rendered.len == presets.len
    check rendered.toHashSet.len == presets.len

  test "the dialog lists EXACTLY the bindings, and declares the count it drew":
    ## `data-kb-rows` is what journey 20 counts, so it has to be the real
    ## number and not an intention.
    ##
    ## THE PRESETS ALONE CANNOT PROVE THIS, and the first version of this test
    ## did not notice. All three bind exactly eight moves, so
    ## `$km.bindings.len` and the literal `"8"` render identically — a mutation
    ## replacing the expression with `"8"` SURVIVED this test until the
    ## synthetic keymap below was added. That is the "check that cannot fail"
    ## this file's header is about, reproduced by the person writing the guard
    ## against it.
    for id in presets:
      let km = keymapOf(id)
      let html = renderShortcutsDialog(km, mac = false)
      # `data-kb-action` AND NOT `class="kbrow"`, which is what this counted
      # until the dialog grew the scrubber's keys and the always-active ones.
      # Those are `.kbrow` too — deliberately, they are the same kind of row to
      # a reader — so a count over the class now answers "how many rows are in
      # the dialog", and the claim being made here is the narrower and more
      # useful one: how many of them came from THIS KEYMAP.
      check occurrences(html, "data-kb-action=\"") == km.bindings.len
      check ("data-kb-rows=\"" & $km.bindings.len & "\"") in html
      for b in km.bindings:
        check ("data-kb-action=\"" & $b.action & "\"") in html
        # The chord is SPELLED in the row, from the same binding.
        check (">" & escapeHtml(describe(b.chord)) & "<") in html

    # A KEYMAP THAT IS NOT EIGHT. Built here rather than taken from a preset,
    # precisely because no preset can distinguish a count from the constant it
    # happens to equal. Three bindings must render three rows and declare
    # three.
    let full = keymapOf(kmLetters)
    check full.bindings.len > 3          # the slice below is a real subset
    var partial = Keymap(id: kmLetters, bindings: full.bindings[0 ..< 3])
    let partialHtml = renderShortcutsDialog(partial, mac = false)
    check occurrences(partialHtml, "data-kb-action=\"") == 3
    check "data-kb-rows=\"3\"" in partialHtml
    check "data-kb-rows=\"8\"" notin partialHtml
    # And the rows are the three it was given, not the first three of a preset
    # the renderer looked up for itself from `partial.id`.
    for b in partial.bindings:
      check ("data-kb-action=\"" & $b.action & "\"") in partialHtml
    for b in full.bindings[3 .. ^1]:
      check ("data-kb-action=\"" & $b.action & "\"") notin partialHtml

  test "the empty preset renders a sentence, never an empty table":
    ## `kmNone` is a choice a visitor can make. An empty table would read as a
    ## dialog that failed to load, which is the one thing a settings surface
    ## must not look like.
    let html = renderShortcutsDialog(keymapOf(kmNone), mac = false)
    check occurrences(html, "data-kb-action=\"") == 0
    # The OTHER registries are still listed under `kmNone`, and must be: the
    # scrubber's arrows and the gutter's Enter/Space do not stop working
    # because a visitor turned the stepping chords off. A dialog that emptied
    # completely here would be telling them the keyboard does nothing.
    check occurrences(html, "data-kb-scrub=\"") > 0
    check occurrences(html, "data-kb-hard=\"") > 0
    check "data-kb-rows" notin html
    check "kbempty" in html
    # It still offers every preset, so the choice is reversible from inside it.
    for id in KeymapId:
      check ("value=\"" & $id & "\"") in html

  test "hazards are COMPUTED per platform — the same preset differs on a Mac":
    ## `hazardOf` is a function of the chord and the platform, never a field on
    ## a preset. The test that this is real is that one keymap renders two
    ## different dialogs.
    let km = keymapOf(kmDesktop)
    let onMac = renderShortcutsDialog(km, mac = true)
    let notMac = renderShortcutsDialog(km, mac = false)
    check onMac != notMac
    # The Mac's function row is a weaker hazard than a browser-reserved key and
    # gets its own marker, so the two are counted separately.
    check occurrences(onMac, "data-kb-hazard=\"mac-fn\"") >
          occurrences(notMac, "data-kb-hazard=\"mac-fn\"")
    # F11 and F12 are taken above the page on every platform, so THAT count
    # does not move between the two renders.
    check occurrences(onMac, "data-kb-hazard=\"reserved\"") ==
          occurrences(notMac, "data-kb-hazard=\"reserved\"")
    check occurrences(onMac, "data-kb-hazard=\"reserved\"") > 0

  test "the dialog prints a hazard exactly where `hazardOf` finds one":
    ## Counted against the function rather than against a number, on both
    ## platforms and every preset — so a renderer that dropped the column, or
    ## printed it on every row, fails.
    for id in presets:
      let km = keymapOf(id)
      for mac in [false, true]:
        var expected = 0
        for b in km.bindings:
          if hazardOf(b.chord, mac) != hzNone: inc expected
        let html = renderShortcutsDialog(km, mac)
        check occurrences(html, "data-kb-hazard=\"") == expected

  test "the DEFAULT preset is hazard-free on every platform":
    ## `Configuration.md` §4.2: the default must be a preset with no platform
    ## hazard on any chord. A default a platform silently swallows reproduces,
    ## as a default, the defect the feature exists to fix.
    let km = keymapOf(DefaultKeymapId)
    check km.bindings.len > 0
    for b in km.bindings:
      for mac in [false, true]:
        check hazardOf(b.chord, mac) == hzNone
    # And its dialog therefore prints no hazard column at all, on either.
    for mac in [false, true]:
      check "data-kb-hazard" notin renderShortcutsDialog(km, mac)
    # THE NEGATIVE: the check above is not vacuous, because another preset DOES
    # report hazards through the same code path.
    check "data-kb-hazard" in renderShortcutsDialog(keymapOf(kmDesktop), true)

  test "a stored preset round-trips, and an unknown one falls back to default":
    ## The wire spellings go into `localStorage` under `bt.ui.keymap`
    ## (`Configuration.md` §4.2), so a rename is a migration. An unrecognised
    ## value must not leave a visitor with no chords — §4's forward-compatible
    ## rule applied at the field level.
    for id in KeymapId:
      check parseKeymapId($id) == id
    check parseKeymapId("nonsense-from-a-newer-build") == DefaultKeymapId
    check parseKeymapId("") == DefaultKeymapId
    # `none` is a real stored value and must NOT be mistaken for "unset".
    check parseKeymapId("none") == kmNone
    check parseKeymapId("none") != DefaultKeymapId

  test "Shift is spelled once — the capital IS the shift, for letters":
    ## The spelling rule is the subject here, so the expectations are literals
    ## deliberately. The browser reports Shift+n as `key == "N"`, so a chord
    ## whose key is `"N"` must not also print "Shift" — that would name two key
    ## presses for one, and a visitor who pressed both would be right and the
    ## tooltip wrong about why.
    check describe(chord("N")) == "N"
    check describe(chord("n")) == "n"
    # Function keys are the opposite: Shift does not change `key`, so the bit
    # is the only thing distinguishing forward from backward and IS printed.
    check describe(chord("F10", shift = true)) == "Shift+F10"
    check describe(chord("F10")) == "F10"
    check describe(chord("F5", alt = true)) == "Alt+F5"
    # The letters preset therefore names no modifier anywhere in its dialog.
    let html = renderShortcutsDialog(keymapOf(kmLetters), mac = false)
    check "Shift+" notin html
    # …while the preset that has real modifier bits does.
    check "Shift+" in renderShortcutsDialog(keymapOf(kmDesktop), mac = false)

  test "the default preset's tooltip is a VALUE, not just whatever the table says":
    ## THE ONE PLACE IN THIS SUITE THAT PINS A WHOLE TOOLTIP AS A LITERAL, and
    ## it is here because every other check above is RELATIONAL — "the tooltip
    ## says whatever `chordFor` says" is satisfied by a table and a renderer
    ## that are wrong together. Two of the three inputs are already pinned
    ## independently: `controlLabel(daStepForward) == "Step over"` is asserted
    ## by "the two controls that send `next` are named for what they send",
    ## and `describe(chord("n")) == "n"` by the case above. This pins the
    ## COMPOSITION of them, which nothing else does.
    ##
    ## `n` is not an arbitrary letter to have chosen and that is why it is
    ## safe to write down: it is gdb's `next`, which is where `LettersBindings`
    ## says it came from. A reader checking this line has an authority outside
    ## this repository to check it against.
    let km = keymapOf(DefaultKeymapId)
    check controlLabel(daStepForward, km) == "Step over (n)"
    check controlLabel(daContinue, km) == "Continue (c)"
    # And it reaches the attribute, on a real projection of a real session,
    # rather than stopping at the string that feeds it.
    #
    # The buttons are flipped to ENABLED first, because a served projection's
    # are not: `renderControls` appends "— inert until the replay engine
    # loads" to an inert control's name, and the whole attribute is then that
    # longer sentence. A live session is the state this pin is about — it is
    # the only one on which a chord is bound at all.
    var s = sessionFor(readyTx)
    check s.controls.buttons.len > 0
    for b in s.controls.buttons.mitems: b.enabled = true
    let html = dbgc.renderControls(s.controls, km)
    check "title=\"Step over (n)\"" in html
    check "aria-label=\"Step over (n)\"" in html
    check "title=\"Continue (c)\"" in html
    # THE NEGATIVE. The served frame binds nothing and must therefore say
    # nothing, and this is the same string checked for its absence — so a
    # renderer that ignored its keymap argument cannot satisfy both lines.
    check "title=\"Step over (n)\"" notin dbgc.renderControls(s.controls)

suite "the scrubber names the keys it answers to":
  ## The stepping buttons were given their chords and the control BESIDE them
  ## was not, though its keys had been bound for longer. `markScrubberSeekable`
  ## puts `role="slider"` and `tabindex="0"` on `.dctl` — which is a promise
  ## that a keyboard can move it — and named `aria-label="Position in the
  ## trace"` and nothing else. The arrows, `Page Up`/`Page Down` and
  ## `Home`/`End` were discoverable only by trying them.
  ##
  ## The rule that fixed the buttons applies unchanged: the sentence is derived
  ## from the table the dispatcher matches against. These tests are about the
  ## table and the derivation; that the keys MOVE the session is journey 17's,
  ## because only a browser can press one.

  test "a key that is DOCUMENTED is a key that DISPATCHES — the round trip":
    ## `scrubMoveFor` is the handler's read of the table and `scrubLabel` is
    ## the tooltip's, exactly as `actionFor`/`chordFor` split the stepping one.
    let bindings = scrubBindings()
    check bindings.len > 0            # nothing below quantifies over nothing
    var keyCount = 0
    for b in bindings:
      check b.keys.len > 0
      for k in b.keys:
        inc keyCount
        let (found, move) = scrubMoveFor(k)
        check found
        check move == b.move
        # …and the key a reader is shown is in the sentence the control carries.
        check keyLabel(k) in scrubLabel()
    check keyCount > 0
    # THE NEGATIVE: a key nothing binds is neither dispatched nor named.
    let (stray, _) = scrubMoveFor("Backspace")
    check not stray
    check "Backspace" notin scrubLabel()

  test "every move the table names is named in the sentence, in its own words":
    ## The words are `ScrubMove`'s own string values, so the handler's `case`
    ## and the tooltip cannot describe different sets of keys.
    let label = scrubLabel()
    check label.startsWith(ScrubName)
    for b in scrubBindings():
      check ($b.move) in label
      check describeScrub(b) in label
    # A count, not a "contains" — six moves, six phrases, and a sentence that
    # dropped one fails here rather than passing on the five it kept.
    check occurrences(label, ", ") == scrubBindings().len - 1

  test "no key means two moves, and no move is left without a key":
    ## A duplicate would make `scrubMoveFor` depend on table order.
    var keys: HashSet[string]
    var moves: HashSet[string]
    var total = 0
    for b in scrubBindings():
      moves.incl $b.move
      for k in b.keys:
        keys.incl k
        inc total
    check keys.len == total
    check moves.len == scrubBindings().len
    # And the table covers the enum: a move added without a key would be a
    # `ScrubMove` the handler can never be asked for.
    var declared = 0
    for m in ScrubMove: inc declared
    check moves.len == declared

  test "`aria-keyshortcuts` carries the same keys, in the attribute's own form":
    ## WAI-ARIA 1.2 defines the value as a space-delimited list of key values,
    ## so this is the machine-readable projection of the table and the tooltip
    ## is the human one. Both from `scrubBindings`, so neither can list a key
    ## the other does not.
    let attr = scrubKeyShortcuts()
    let listed = attr.split(' ')
    var expected = 0
    for b in scrubBindings():
      for k in b.keys:
        inc expected
        check k in listed
    check listed.len == expected
    check expected > 0
    # The RAW key values, not the printed ones: assistive technology matches
    # `KeyboardEvent.key`, and "←" is not a value any event carries.
    check "ArrowLeft" in listed
    check "←" notin attr

  test "the keys ARE the ARIA slider set — pinned as a value, not as a relation":
    ## THE OTHER FOUR TESTS IN THIS SUITE CANNOT SEE A MISSING KEY, and that
    ## was measured rather than reasoned: deleting `"ArrowDown"` from
    ## `ScrubKeys` left all of them green. Every one of them is a relation over
    ## `scrubBindings()` — "the sentence names what the table binds" — and a
    ## table with one fewer key satisfies it exactly as well. A slider that
    ## stopped answering ↓ would have shipped with a suite that agreed the
    ## tooltip was correct, because it would have stopped naming ↓ too.
    ##
    ## So the set is pinned against an authority OUTSIDE this repository: the
    ## WAI-ARIA Authoring Practices' Slider pattern, whose keyboard interaction
    ## is Left/Down to decrease, Right/Up to increase, Page Down/Page Up for a
    ## larger amount, Home for the minimum and End for the maximum. Eight keys.
    ## A `role="slider"` that answers fewer is a control the platform's own
    ## convention has already told the visitor how to use, failing to do what
    ## it was told.
    check scrubKeyShortcuts() ==
      "ArrowLeft ArrowDown ArrowRight ArrowUp PageDown PageUp Home End"
    # And two phrases of the sentence, so a key removed from the table is
    # caught in the channel a reader actually sees as well as in the attribute.
    check "←/↓ back one tick" in scrubLabel()
    check "→/↑ forward one tick" in scrubLabel()

  test "the last coordinate a seek may name is one BEFORE the count":
    ## THE DEFECT THE `End` KEY MADE REACHABLE, pinned where it is cheap to
    ## check. `totalSteps` is a count and the coordinates are zero-based, so
    ## `totalSteps` itself is one past the end — and the engine does not refuse
    ## it. It PANICS (`load_local_calltrace: invalid step_id`), traps the WASM
    ## module, and answers nothing for the rest of the visit.
    ##
    ## Measured against the published engine over the deployed build on a
    ## 345-step recording: 343 and 344 answered, 345 killed the session, and a
    ## `Home` pressed afterwards did nothing. 345 is written below as a literal
    ## for that reason — it is the number that was driven, not an example.
    check lastStep(345) == 344
    check lastStep(1) == 0        # a one-step recording's only coordinate is 0
    check lastStep(0) == 0        # and an empty one names nothing at all

    # A DRAG OR CLICK AT THE EXTREME RIGHT asks for the last coordinate and
    # never the count. This is the second gesture that could reach it, and the
    # one a visitor is more likely to perform.
    var p = DebugControlsPane(totalSteps: 345, positioned: true, step: 1)
    check p.stepAtFraction(1.0) == 344
    check p.stepAtFraction(1.0) != p.totalSteps
    # …and the clamp has not swallowed the range: a drop halfway along still
    # names a step halfway along, so the line above is a bound and not a stub.
    check p.stepAtFraction(0.5) == 173

    # AND THE HANDLE STILL REACHES THE END. `markedTick` reserves the final
    # tick for `fraction == 1.0` so that "the trace has ended" is a claim
    # rather than a rounding; with the seek correctly clamped, the step at
    # which that claim is true is `lastStep`, and a `fraction` still measured
    # against the count would have left the playhead one tick short forever.
    p.step = lastStep(p.totalSteps)
    check p.fraction == 1.0
    check p.markedTick == TimelineTicks
    # One step earlier is emphatically NOT the end — otherwise the check above
    # would be satisfied by a control that marks the last tick from anywhere.
    p.step = lastStep(p.totalSteps) - 1
    check p.fraction < 1.0
    check p.markedTick < TimelineTicks

  test "the printed key is a rendering of the bound key, and never a second list":
    ## `keyLabel` decides SPELLING only. An unrecognised key prints verbatim,
    ## so a key added to the table is documented the moment it is bound rather
    ## than silently dropped from the sentence by a lookup with no entry.
    check keyLabel("ArrowLeft") == "←"
    check keyLabel("ArrowRight") == "→"
    check keyLabel("Home") == "Home"
    check keyLabel("Enter") == "Enter"          # nothing binds it; it is itself
    # The space bar, whose `KeyboardEvent.key` IS " ". Printed verbatim it
    # rendered an empty key cap on `/settings` — a bordered box with nothing
    # in it — so it is the one non-scrubber key this function names.
    check keyLabel(" ") == "Space"
    check keyLabel(" ").strip().len > 0
    check keyLabel("zzz-not-a-key") == "zzz-not-a-key"

suite "/settings — the preset is chosen and every claimed key is listed":
  ## THE PAGE THIS COVERS REPLACED ONE THAT WAS DELETED FOR HAVING NO CONTROLS.
  ##
  ## So the assertions here are deliberately about ACTING and about
  ## COMPLETENESS, not about wording. A settings page can be re-worded freely
  ## and every check below stays green; it cannot lose its chooser, lose a
  ## preset, or stop listing one of the three registries without going red.

  test "the page serves a chooser for every preset, and it is served inert":
    ## The chooser must exist in the bytes AND must be `hidden` in them. Both
    ## halves matter and they fail in opposite directions: without the chooser
    ## the page is the deleted page again; without the `hidden` it is a radio
    ## group a script-less reader can move and that stores nothing, which is
    ## the "control that cannot succeed" this product refuses to ship.
    let html = settingsPage()
    check "data-kb-chooser" in html
    check "data-kb-chooser=\"\" hidden=\"hidden\"" in html
    # EXACTLY ONE radio is `checked`, and it is the default.
    #
    # The false branch used to render `checked=""`, which is CHECKED — so all
    # four were, a radio group keeps the last, and every surface showed `None`
    # as the active preset regardless of what was in force.
    check occurrences(html, "checked=") == 1
    check ("value=\"" & $DefaultKeymapId & "\" data-kb=\"preset\" checked=\"checked\"") in html
    for id in KeymapId:
      check ("value=\"" & $id & "\"") in html
      check (">" & escapeHtml(presetName(id)) & "<") in html

  test "every preset is served on BOTH platforms, and exactly one is visible":
    ## `hazardOf` is a function of the chord and the platform, and static bytes
    ## cannot know the platform — so both are served and the bundle reveals
    ## one. A panel that went missing would leave a reader on that platform
    ## with a chooser entry that reveals nothing.
    let html = settingsPage()
    for id in KeymapId:
      for mac in ["0", "1"]:
        check ("data-kb-panel=\"" & $id & "\" data-kb-mac=\"" & mac & "\"") in html
    # ONE visible panel, counted as panels that carry NO `hidden` at all.
    #
    # THIS ASSERTION USED TO BE THE BUG WRITTEN DOWN AS AN EXPECTATION. It
    # checked for `hidden=""` on exactly one panel and passed — and `hidden` is
    # an HTML boolean attribute, true whenever present, so the panel it was
    # confirming as visible was hidden along with the other seven. A reader
    # with no script got no shortcut list at all. Journey 22's script-less pass
    # is what found it; nothing in this file could, because the string it
    # searched for was there.
    #
    # `hidden=""` must now appear NOWHERE: the renderer emits the attribute or
    # omits it, and never emits it empty.
    check occurrences(html, "hidden=\"\"") == 0
    # A panel is VISIBLE exactly when its opening tag ENDS after `data-kb-mac`
    # — no `hidden` follows it. Counted over both platform variants, so a
    # second visible panel on either one fails here.
    check occurrences(html, "data-kb-mac=\"0\">") +
          occurrences(html, "data-kb-mac=\"1\">") == 1
    # And the visible one is the DEFAULT on the non-Mac variant, which is the
    # only preset a reader with no script can actually be under.
    check ("class=\"kbpanel\" data-kb-panel=\"" & $DefaultKeymapId &
           "\" data-kb-mac=\"0\">") in html
    check occurrences(html, "data-kb-mac=\"1\">") == 0
    # Every other panel is hidden by an attribute that is actually present.
    check occurrences(html, "hidden=\"hidden\"") == 8   # 7 panels + the chooser

  test "the page lists ALL THREE registries, not just the presets":
    ## The claim the page's title makes. A list drawn from the keymap alone
    ## would omit the scrubber's six moves and the gutter's Enter/Space —
    ## about a third of the keys this product answers to — while looking
    ## complete, which is the failure mode that matters.
    let html = settingsPage()
    check occurrences(html, "data-kb-rows=\"") > 0        # registry 1
    check occurrences(html, "data-kb-scrub=\"") == scrubBindings().len  # 2
    check occurrences(html, "data-kb-hard=\"") == 2       # registry 3
    # Named rather than counted, so a registry that stopped being drawn cannot
    # be covered for by another one growing.
    for b in scrubBindings():
      check ("data-kb-scrub=\"" & $b.move & "\"") in html
    for h in hardKeys():
      check escapeHtml(h.what) in html

  test "the settings page and the dialog render one binding row, not two":
    # The three presets that bind anything. `kmNone` binds nothing and so has
    # no row to compare; it is covered by the empty-preset test above.
    ## Both surfaces call `renderBindingRows`, so a row on one is
    ## byte-identical to the row on the other. This is the whole reason
    ## `components/shortcut_list.nim` exists, and it is asserted rather than
    ## trusted because two renderers drifting is invisible until a reader
    ## compares them.
    for id in [kmLetters, kmVsCode, kmDesktop]:
      let km = keymapOf(id)
      let dialog = renderShortcutsDialog(km, mac = false)
      let page = settingsPage()
      for b in km.bindings:
        let row = "data-kb-action=\"" & $b.action & "\""
        check row in dialog
        check row in page
        # The chord is spelled the same in both, from the same binding.
        check (">" & escapeHtml(describe(b.chord)) & "<") in dialog
        check (">" & escapeHtml(describe(b.chord)) & "<") in page

  test "no preset chord is shadowed by a key the bundle claims first":
    ## THE INVARIANT THE THIRD REGISTRY EXISTS TO PROTECT.
    ##
    ## `hydrate.nim` tests `Escape` and the gutter's `activationKey` BEFORE the
    ## stepping dispatcher sees a press. A preset binding one of those keys
    ## would produce a row that is true about the table and false about the
    ## browser: `actionFor` would agree the chord is bound, the list would draw
    ## it, and the key would do the other thing.
    ##
    ## Today nothing collides, so this passes over real data rather than
    ## vacuously — `hardKeys()` is non-empty and every preset is checked
    ## against all of it.
    check hardKeys().len > 0
    var checked = 0
    for id in KeymapId:
      for b in keymapOf(id).bindings:
        let (shadowed, by) = shadowOf(b.chord)
        check not shadowed
        if shadowed: echo "  ", describe(b.chord), " is taken by: ", by
        inc checked
    check checked > 0

  test "a chord that IS shadowed says so in its row — the negative":
    ## The control datum for the test above. Without it, "no row carries a
    ## shadow warning" would be satisfied by a renderer that cannot draw one,
    ## and the invariant would be guarded by a check that could not fail.
    ##
    ## A synthetic keymap binding `Escape` — which `hard_keys` derives from
    ## `hydrate.nim`, so this is a real collision with a real claim and not a
    ## fixture agreeing with itself.
    let (isClaimed, claimedBy) = hardClaim("Escape")
    check isClaimed                       # the derivation still finds it
    let clashing = Keymap(id: kmLetters, bindings: @[
      Binding(action: daStepForward, chord: chord("Escape"))])
    let html = renderBindingRows(clashing, mac = false)
    check "data-kb-shadow=\"hard\"" in html
    check escapeHtml(claimedBy) in html
    # And a chord that is NOT claimed draws no warning, so the marker tracks
    # the collision rather than being emitted on every row.
    let clean = Keymap(id: kmLetters, bindings: @[
      Binding(action: daStepForward, chord: chord("n"))])
    check "data-kb-shadow" notin renderBindingRows(clean, mac = false)

  test "the hard-key list is DERIVED from hydrate.nim, not written here":
    ## `hard_keys` reads the file that makes the claims with `staticRead` and
    ## fails the build if the described set and the derived set disagree. What
    ## can still be asserted at runtime is that the derivation produced the
    ## keys the claiming source actually contains — checked against the source
    ## text HERE, independently of the module's own parse.
    let src = readFile(currentSourcePath().parentDir.parentDir /
                       "hydrate" / "hydrate.nim")
    check DerivedKeys.len > 0
    for k in DerivedKeys:
      # Every derived key appears in the claiming file as a key comparison.
      check ("\"" & k & "\"") in src
    # The two forms the file uses are both represented, so a derivation that
    # silently lost one would be caught. `Escape` comes from the `keyName`
    # comparison; `Enter` from the `activationKey` FFI body.
    check "Escape" in DerivedKeys
    check "Enter" in DerivedKeys
    check " " in DerivedKeys

removeDir(workDir)
removeDir(degradedDir)
