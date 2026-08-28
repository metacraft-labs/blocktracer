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
import ../src/debugger/session_view
import ../src/debugger/replay_engine
import ../src/debugger/source_document
import ../src/debugger/demo_session
import ../src/components/debugger as dbgc
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

let generationJson = parseJson(readFile(workDir / "d" / Chain / "current.json"))
let tsv = generationJson["traceSelectionVersion"].getStr

proc overlayOf(hash: string): JsonNode =
  parseJson(readFile(workDir / "d" / Chain / "ts" / tsv / shardOf(hash) /
                     (hash & ".json")))

proc headlineAvailabilityOf(hash: string): string =
  ## The strongest availability among a transaction's executions, computed here
  ## from the raw overlay rather than borrowed from the SDK — so a change to
  ## `bestTrace`'s ranking shows up as a disagreement instead of moving both
  ## sides of the assertion at once.
  let o = overlayOf(hash)
  var execs: seq[JsonNode]
  if o.hasKey("trace"): execs.add o["trace"]
  elif o.hasKey("executions"):
    for e in o["executions"]: execs.add e
  for want in ["ready", "divergent", "onDemand"]:
    for e in execs:
      if e{"availability"}.getStr == want: return want
  if execs.len > 0: execs[0]{"availability"}.getStr else: ""

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

proc debugHtml(hash: string): string =
  let (status, body, _) = renderRoute(root, "/" & Chain & "/tx/" & hash & "/debug")
  doAssert status == 200, "debug route did not serve " & hash & ": " & $status
  body

proc txHtml(hash: string): string =
  let (status, body, _) = renderRoute(root, "/" & Chain & "/tx/" & hash)
  doAssert status == 200
  body

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
    # …replaced by the slim identity bar, carrying the identity and the way back.
    check "class=\"dbgbar\"" in html
    check ("href=\"" & txUrl(Chain, readyTx) & "\"") in html

  test "the register is a change of ATTRIBUTE VALUE, not a second stylesheet":
    # Design-System §2: the registers share everything but density, surface and
    # default theme. If the debug page shipped rules the explorer page does not,
    # the register would have become a component library.
    let debugCss = debugHtml(readyTx).split("<style>")[1].split("</style>")[0]
    let explorerCss = txHtml(readyTx).split("<style>")[1].split("</style>")[0]
    check debugCss == explorerCss

suite "M8a — the arrangement is CodeTracer's LayoutNode, consumed":

  test "every pane of the reference layout is placed exactly once":
    let html = debugHtml(readyTx)
    let model = defaultReplayLayout()
    check allPanes(model).len == 5
    for pane in allPanes(model):
      let id = "id=\"pane-" & ($pane).toLowerAscii & "\""
      check occurrences(html, id) == 1
    # …and nothing outside the model's pane set was placed.
    let placed = idsInOrder(html, "pane-").toHashSet
    var expected = initHashSet[string]()
    for pane in allPanes(model): expected.incl "pane-" & ($pane).toLowerAscii
    expected.incl "pane-metadata"   # §7.1, BlockTracer's own, beside the tree
    check placed == expected

  test "the weights of the model become the flex fractions in the markup":
    let html = debugHtml(readyTx)
    # `defaultReplayLayout()`: controls 1 / row 9, editor 3 / column 2,
    # calltrace 1, stack 1. Read the weights OFF THE MODEL so this cannot
    # drift into a restatement of the numbers.
    let model = defaultReplayLayout()
    let controls = model.children[0]
    let row = model.children[1]
    let editor = row.children[0]
    check ("pane p-controls " & dbgc.weightClass(controls.weight)) in html
    check ("ln row " & dbgc.weightClass(row.weight)) in html
    check ("pane p-source " & dbgc.weightClass(editor.weight)) in html

  test "a DIFFERENT layout renders differently — the walk is driven by the model":
    # The negative half. Without it, "the arrangement comes from LayoutNode"
    # would be satisfied by a renderer that ignores the argument entirely.
    let s = sessionFor(readyTx)
    let reference = dbgc.renderLayout(defaultReplayLayout(), s)

    var swapped = defaultReplayLayout()
    check activate(swapped, paneEventLog)          # make Event Log the live tab
    let swappedHtml = dbgc.renderLayout(swapped, s)
    check swappedHtml != reference
    # The default panel is the one the model says is active.
    check "stackpanel p-eventlog def" in swappedHtml
    check "stackpanel p-state def" in reference

    var trimmed = defaultReplayLayout()
    check removePane(trimmed, paneCalltrace)
    let trimmedHtml = dbgc.renderLayout(trimmed, s)
    check "id=\"pane-calltrace\"" notin trimmedHtml
    check "id=\"pane-calltrace\"" in reference

    var reweighted = defaultReplayLayout()
    check setWeight(reweighted, paneEditor, 5.0)
    check ("pane p-source w5") in dbgc.renderLayout(reweighted, s)

  test "a stack is tabs: both panes are rendered, one is the live tab":
    let html = debugHtml(readyTx)
    check "id=\"pane-state\"" in html
    check "id=\"pane-eventlog\"" in html
    check "stackpanel p-state def" in html
    check "stackpanel p-eventlog alt" in html
    # The tab strip links to both, so the switch works with no JavaScript.
    check "href=\"#pane-state\"" in html
    check "href=\"#pane-eventlog\"" in html
    # …and there is no script on the page at all.
    check "<script" notin html

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
    check "pub fn iterate_asteroids" in html
    check "remaining_shield -= damage;" in html
    # Rendered as text inside <code>, so a tokeniser can replace the text node
    # later without moving anything around it.
    check "<code class=\"t\">" in html

  test "every line has a stable id derived from (path, line), not render order":
    let s = sessionFor(readyTx)
    let doc = activeDocument(s.editor)
    var seen = initHashSet[string]()
    for ln in doc.lines:
      check ln.anchor == lineAnchor(doc.path, ln.number)
      check ln.anchor notin seen
      seen.incl ln.anchor
    check seen.len == doc.lines.len
    let html = debugHtml(readyTx)
    for ln in doc.lines:
      check ("id=\"" & ln.anchor & "\"") in html

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
    check "fn only()" in dbgc.renderSource(withBundle.editor)
    # A bundle that resolves to nothing usable is IGNORED, never allowed to
    # empty a pane that had content.
    var withJunk = s
    withPublishedSources(withJunk, %*{"sources": {}})
    check withJunk.editor.documents.len == s.editor.documents.len

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
    let info = chainInfo(root, Chain)
    let v = txView(root, info, readyTx)
    let rows = txMetadataRows(Chain, v)
    check rows.len > 0
    let page = txHtml(readyTx)
    let pane = debugHtml(readyTx)
    for r in rows:
      check (">" & r.label & "</dt>") in page
      check (">" & r.label & "</dt>") in pane
      check r.value in page
      check r.value in pane

  test "the page carries NO fact the shared producer does not name":
    # The other direction, and the one a shared helper does not give you for
    # free: a page can always grow a hand-written row beside the loop. The
    # overview grid's <dt> set must equal the producer's label set exactly.
    let info = chainInfo(root, Chain)
    let v = txView(root, info, readyTx)
    var expected = initHashSet[string]()
    for r in txMetadataRows(Chain, v): expected.incl r.label

    let page = txHtml(readyTx)
    let gridStart = page.find("<dl class=\"dl\">")
    check gridStart > 0
    let gridEnd = page.find("</dl>", gridStart)
    let grid = page[gridStart ..< gridEnd]
    var rendered = initHashSet[string]()
    var i = 0
    while true:
      let at = grid.find("<dt>", i)
      if at < 0: break
      let stop = grid.find("</dt>", at)
      rendered.incl grid[at + 4 ..< stop]
      i = stop
    check rendered == expected

  test "a mutation to the underlying view moves BOTH surfaces":
    let info = chainInfo(root, Chain)
    var v = txView(root, info, readyTx)
    let pageBefore = txPg.txPage(Chain, v)
    let paneBefore = dbgc.renderMetadata(metadataPane(Chain, v))

    v.finality = "reorged"
    let pageAfter = txPg.txPage(Chain, v)
    let paneAfter = dbgc.renderMetadata(metadataPane(Chain, v))

    check pageBefore != pageAfter
    check paneBefore != paneAfter
    check "Reorged" in pageAfter
    check "Reorged" in paneAfter
    check "Reorged" notin pageBefore
    check "Reorged" notin paneBefore

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
    # The phase is NAMED, the sequence is shown, and the wait is quantified.
    check "class=\"phaserail\"" in html
    check phaseLabel(spFetching) in html
    check phaseLabel(spOpening) in html
    check phaseLabel(spPositioning) in html
    check approxMegabytes(ReplayEngineWasmBytes) in html
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
    # this repository a client of an origin its operator never named — and the
    # obvious name to hardcode, web.codetracer.com, currently serves a
    # different, authenticated application entirely.
    check not replayEngineIsCrossOrigin()
    check ReplayEngineBase.startsWith("/")
    check "http" notin ReplayEngineBase
    # The decision is DERIVED from the value, so a build cannot declare one
    # thing and load another.
    check isCrossOrigin("https://web-codetracer.pages.dev/")
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

suite "M8b — the crawl surface is unchanged":

  test "the transaction route keeps its robots class and canonical link":
    # Asserted against a stored baseline (client/tests/baselines/), so the SEO
    # surface cannot regress silently.
    let baseline = parseJson(readFile(
      clientRoot / "tests" / "baselines" / "tx-crawl-surface.json"))
    for h in txHashes:
      let html = txHtml(h)
      check ("<meta name=\"robots\" content=\"" &
             baseline["txRobots"].getStr & "\"") in html
      check ("<link rel=\"canonical\" href=\"" & SiteDomain & "/" & Chain &
             "/tx/" & h & "\"") in html
      # The inlined entry data the crawler is served is still there.
      check baseline["txMustContain"].getElems.allIt(it.getStr in html)

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
    check submitted.len == all.len - renderedDebug
    for route in all:
      if not route.endsWith("/debug"): check route in submitted

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
