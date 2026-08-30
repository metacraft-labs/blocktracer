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
import ../src/debugger/replay_engine
import ../src/debugger/source_document
import ../src/debugger/source_island
import ../src/debugger/demo_session
import ../src/debugger/deeplink_landing
import ../src/debugger/demo_flow
import ../src/debugger/flow_view
import ../src/components/debugger as dbgc
import ../src/components/debugger_css
import isonim/ssr/escape
import ../src/pages/debug as debugPg
import ../src/pages/tx as txPg
import blocktracer/demo/generator
import blocktracer/contract/ids   # `contentHashSha1`, as an independent oracle

const Chain = "aztec"

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
      check b.label in bar

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
    # Taken from the window the pane actually opens on rather than from the top
    # of the file: the pane opens ON the session's position, so line 1 is not
    # on the page. Asserting over the rendered window keeps this a check that
    # the REAL program is rendered — the strings below are still `shield.nr`'s
    # own source, read out of the document rather than written in by hand, so a
    # placeholder renderer still fails it.
    let rendered = activeDocument(openAtCurrent(s.editor, lead = 6))
    check rendered.lines.len > 20
    check rendered.lines[0].number > 1     # the window is a real window
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
    # The page opens the pane ON the position (see the next test), so the lines
    # it renders are the window's, not the whole file's. The identity property
    # is asserted over exactly the lines the page emits — and, because the
    # anchors are derived from `(path, line)` and not from render order, the
    # windowed ids are the same ids the full document produced above.
    let html = debugHtml(readyTx)
    let rendered = activeDocument(openAtCurrent(s.editor, lead = 6))
    check rendered.lines.len > 0
    for ln in rendered.lines:
      check ln.anchor == lineAnchor(doc.path, ln.number)
      check ("id=\"" & ln.anchor & "\"") in html

  test "the source pane OPENS on the position, at every viewport":
    ## The regression this test exists for shipped, and four of six reviewers
    ## in VD.5's first round found it on the rendered page: the pane rendered
    ## the file from line 1, so at the `laptop` viewport the current line fell
    ## below the fold. The toolbar claimed a step and no pane showed one.
    ##
    ## "Visible" cannot be asserted from markup, so the property asserted is
    ## the one that CAUSES it and does not depend on a viewport: the current
    ## line is among the first few lines the pane emits. A pane that opens on
    ## its position is visible in any pane tall enough to show a handful of
    ## rows; a pane that opens at line 1 is not.
    let s = sessionFor(readyTx)
    let full = activeDocument(s.editor)
    # The fixture has to be able to fail this, or the test is decoration.
    check s.editor.currentLine > 8
    check full.lines.len > s.editor.currentLine

    let html = debugHtml(readyTx)
    # The pane emits one panel per document, so the ids are scoped to the
    # ACTIVE document's own file before position within it is asserted.
    let prefix = "L-" & pathSlug(full.path) & "-"
    let ids = idsInOrder(html, "L-").filterIt(it.startsWith(prefix))
    check ids.len > 0
    let cur = lineAnchor(full.path, s.editor.currentLine)
    check cur in ids
    # Within the first handful of rendered rows, not merely present somewhere.
    check ids.find(cur) <= 8

    # And the lines that were dropped to get there are ANNOUNCED, not silently
    # missing — Page-Descriptions §13's rule applies to a reduction in a pane
    # exactly as it does to one at a viewport.
    check "Showing from line" in html

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
    check atTick(1314, 1315) == 47
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

  test "a document whose position is near the top is NOT windowed":
    ## The negative. `openAtCurrent` must be a no-op when the current line is
    ## already within the lead-in, or every session would claim a reduction it
    ## did not make.
    var e = sessionFor(readyTx).editor
    e.currentLine = 3
    for i in 0 ..< e.documents.len:
      for j in 0 ..< e.documents[i].lines.len:
        e.documents[i].lines[j].current =
          e.documents[i].lines[j].number == 3 and i == e.activeIndex
    let opened = openAtCurrent(e, lead = 6)
    check activeDocument(opened).lines.len == activeDocument(e).lines.len
    check activeDocument(opened).lines[0].number == 1

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
    # The reason is stated…
    check "Structurally unobservable" in body
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
      discard txPg.txPage(Chain, txView(root, info, readyTx))
    expect ValueError:
      discard txPg.txPage(Chain, txView(root, info, divergentTx))
    # …and it renders the rows that have no session, so the refusal is
    # specific rather than a page that never renders at all.
    check txPg.txPage(Chain, txView(root, info, onDemandTx)).len > 0


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

  test "the rail is rendered even though the loop's header is off-window":
    # The reason the rail is on the PANE rather than on the loop's own line.
    # `openAtCurrent` opens the served pane six lines above line 32, so line 4
    # is twenty-two lines above the first line served — a control drawn only at
    # the header would be missing exactly when the reader is inside the loop.
    let s = sessionFor(readyTx)
    let windowed = openAtCurrent(s.editor, SourceLeadIn)
    var first = 0
    for ln in activeDocument(windowed).lines:
      first = ln.number
      break
    check first > 4
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
    let html = debugHtml(readyTx)
    # Line 29 — the `if` body `calculate_damage` did not take on pass 2, the
    # pass the served page opens on. Dimmed by default, and marked.
    check "class=\"srcline hit nt-i2 ntnow\"" in html
    # Line 32 is the session's own position AND the arm passes 0 and 1 declined.
    # Both facts, on one row.
    check "class=\"srcline cur hit nt-i0 nt-i1\"" in html
    # The gutter pair: the ordinary marker and the one that replaces it.
    check "<span class=\"mg\">" in html
    check "<span class=\"mn\">⊘</span>" in html
    # And the block rail, which is what makes a run of untaken lines read as a
    # region rather than as scattered dim rows.
    check "<span class=\"ntbar\">" in html
    # A line with no claim is unchanged — no pair, no rail, no extra spans.
    # Counting is what makes that checkable: three claimed lines are in the
    # window, and each channel is emitted exactly three times.
    check occurrences(html, "<span class=\"mn\">") == 3
    check occurrences(html, "<span class=\"mg\">") == 3
    check occurrences(html, "<span class=\"ntbar\">") == 3
    # Still no script. The whole control is links and CSS.
    check executableScripts(html) == 0

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
      let rows = txMetadataRows(Chain, v)
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
    for r in txMetadataRows(Chain, txView(root, info, onDemandTx)):
      expectedPage.incl r.label
    check dtLabelsIn(txHtml(onDemandTx), "<dl class=\"dl\">") == expectedPage

    var expectedPane = initHashSet[string]()
    for r in txMetadataRows(Chain, txView(root, info, readyTx)):
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
    let pageBefore = txPg.txPage(Chain, pv)
    let paneBefore = dbgc.renderMetadata(metadataPane(Chain, sv))

    pv.finality = "reorged"
    sv.finality = "reorged"
    let pageAfter = txPg.txPage(Chain, pv)
    let paneAfter = dbgc.renderMetadata(metadataPane(Chain, sv))

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
    var second = txMetadataRows(Chain, v)
    second.add MetaRow(label: "Gas price", value: "7 gwei")
    var secondLabels = initHashSet[string]()
    for r in second: secondLabels.incl r.label
    var producerLabels = initHashSet[string]()
    for r in txMetadataRows(Chain, v): producerLabels.incl r.label
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
      check (b.label & " — inert until the replay engine loads") in html

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
    let v = txView(root, chainInfo(root, Chain), readyTx)
    var plainIdentifiers = 0
    for r in txMetadataRows(Chain, v):
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
    # §6's own table — class N2 ("Never" promoted: `/search`, `/settings`) and
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
    check "/settings" notin submitted
    check "/search" in all
    check "/settings" in all
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
    check "stopped mid-execution at step" in html
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
    check "tabindex" notin markup
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
    ## The pane is served WINDOWED (`openAtCurrent`), so the served DOM does not
    ## contain the lines a backward step needs. The island does, which is what
    ## lets hydration render a line the served page never had — without a
    ## second fetch and without a second producer of the markup.
    let s = sessionFor(readyTx)
    let html = debugHtml(readyTx)
    check ("id=\"" & SourceIslandId & "\"") in html
    check "type=\"application/json\"" in html
    # It is not executable, so it does not count as a script.
    check executableScripts(html) == 0

    # The island round-trips through the SHIPPING encoder and decoder, and what
    # comes back is the whole bundle — not the window the page rendered.
    let active = activeDocument(s.editor)
    let island = encodeSourceIsland(s.editor)
    let windowed = openAtCurrent(s.editor, 6)
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
    # The window really is smaller — or this test proves nothing about why the
    # island exists at all. This is the whole justification for inlining it:
    # the served DOM does not contain the lines a backward step needs.
    check totalLines(windowed) < totalLines(restored)
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

removeDir(workDir)
removeDir(degradedDir)
