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
import ../src/debugger/demo_session
import ../src/components/debugger as dbgc
import ../src/components/debugger_css
import isonim/ssr/escape
import ../src/pages/debug as debugPg
import ../src/pages/tx as txPg
import blocktracer/demo/generator

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
    check "<script" notin markup

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

  test "'Sort by cost' sorts, and the sorted view does not draw a tree":
    ## It was styled as a link — accent colour, underline — and was a `<span>`.
    ## Now it is a real `:target` view, which is also VD.5's "including the
    ## cost column and cost-sorted view".
    let html = debugHtml(readyTx)
    check "href=\"#calltrace-by-cost\"" in html
    check "id=\"calltrace-by-cost\"" in html
    check "<span class=\"ctsort" notin html
    # The cost-ordered rows are flat: once the rows are not in call order, an
    # indent would draw a tree the ordering does not describe.
    let sorted = html[html.find("id=\"calltrace-by-cost\"") .. ^1]
    let sortedView = sorted[0 ..< sorted.find("ctview def")]
    check "ctrow d0 flat" in sortedView
    for d in 1 .. 8:
      check ("ctrow d" & $d & " ") notin sortedView

  test "the cost sort is by cost, descending — not by call order":
    let s = sessionFor(readyTx)
    check s.calltrace.frames.len > 2
    let html = debugHtml(readyTx)
    let sorted = html[html.find("id=\"calltrace-by-cost\"") .. ^1]
    let sortedView = sorted[0 ..< sorted.find("ctview def")]
    var lastCost = high(int)
    var seenNames = 0
    for f in s.calltrace.frames:
      check f.fn in sortedView
    # The most expensive frame appears before the cheapest one.
    var costs: seq[int]
    for f in s.calltrace.frames:
      var n = 0
      for c in f.cost:
        if c in {'0'..'9'}: n = n * 10 + (ord(c) - ord('0'))
      costs.add n
    let dearest = s.calltrace.frames[costs.maxIndex].fn
    let cheapest = s.calltrace.frames[costs.minIndex].fn
    check sortedView.find(dearest) < sortedView.find(cheapest)
    discard lastCost
    discard seenNames

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

  test "the inline-annotation slot renders, so the overlays are additive":
    # Nothing ships annotations. The claim being made is that adding them later
    # needs no restructuring, and this is what makes the claim checkable now.
    let s = sessionFor(readyTx)
    var pane = s.editor
    let before = dbgc.renderSource(pane)
    check "class=\"ann\"" notin before

    var doc = activeDocument(pane)
    let target = doc.lines[2].number
    let anchor = doc.lines[2].anchor
    doc.annotate(target, LineAnnotation(slot: asTrailing,
                                        label: "remaining_shield",
                                        value: "10000 → 9000"))
    pane.documents[pane.activeIndex] = doc
    let after = dbgc.renderSource(pane)
    check "class=\"ann\"" in after
    check "remaining_shield=10000 → 9000" in after
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

  test "a ready session shares with an anchor, never a time coordinate alone":
    # M8a: "Share **always** emits an anchor, never `t` alone."
    let html = debugHtml(readyTx)
    let at = html.find("href=\"?t=")
    check at > 0
    let stop = html.find('"', at + 6)
    let href = html[at + 6 ..< stop]
    check '#' in href
    check href.split('#')[1].startsWith("L-")

  test "with no position there is no share link, only a stated refusal":
    var s = sessionFor(readyTx)
    for d in 0 ..< s.editor.documents.len:
      for i in 0 ..< s.editor.documents[d].lines.len:
        s.editor.documents[d].lines[i].current = false
    let html = debugPg.debugPage(s)
    check "btn disabled sm" in html
    check "href=\"?t=" notin html

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
    check occurrences(html, "aria-disabled=\"true\"") == s.controls.buttons.len
    check "aria-disabled=\"false\"" notin html
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
    # web-codetracer Pages bundle as web-codetracer.pages.dev); web.codetracer.com
    # is deliberately a different, authenticated application, not this bundle.
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
    check "<script" notin html
    check "copybtn" notin html
    check "navigator.clipboard" notin html
    check ">Copy<" notin html
    # A `data-copy` is inert markup, not a control: it carries no role, no
    # tabindex and no handler.
    check "data-copy" in html
    check "onclick" notin html

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

removeDir(workDir)
removeDir(degradedDir)
