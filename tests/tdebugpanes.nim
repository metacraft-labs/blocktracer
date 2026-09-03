## SDK-CONSUMER: the debug route's panes, rendered over the REAL Embed SDK.
##
## `client/src/debugger/session_view.nim` names two producers of a
## `DebugSessionView`. The static one (`demo_session.nim`) is covered by
## `client/tests/test_debug_route.nim`, which runs with no debugger on the Nim
## path at all. This is the other one, and it is the reason the split exists:
##
##   the five headless ViewModels of the Embed SDK — `EditorVM`,
##   `CalltraceVM`, `StateVM`, `EventLogVM`, `DebugControlsVM` — are driven
##   through `MockBackendService`, projected onto the pane types, and rendered
##   by the SAME pane renderers the route uses.
##
## What that buys, concretely: the pane renderers are renderers of *session*
## data. Without this file, `EditorPane`, `CallTracePane`, `StatePane`,
## `EventLogPane` and `DebugControlsPane` would be five shapes that happen to
## suit one fixture, and the first contact with a real session would be a
## rewrite. Here the values on screen come out of a ViewModel that a real
## backend writes through.
##
## ## The projection is the SHIPPING one (revised: hydration landed)
##
## This file used to carry its own `project*` procs and said of them: "the
## shipping adapter is `WorkerBackendService` plus a hydration entry point …
## When the adapter lands it replaces these functions and nothing below them."
##
## It has, and they are gone. The projection now imported from
## `client/hydrate/session_project.nim` is the one the browser bundle runs, and
## that changes what this suite is evidence FOR: it used to show that a
## projection RESEMBLING the shipping one rendered; it now drives the shipping
## one, through `MockBackendService` instead of a worker. A private copy left
## here would have made the suite green about code nobody serves — which is the
## failure `ci/test/debug-panes-test.sh` already guards against in the other
## direction, on the renderers.
##
## What is still local is the DRIVING: `openSession`, the fixture text, and the
## store writes below. Those belong to a test.
##
## ## Facade only
##
## Every import from the CodeTracer side is `codetracer_embed`. M8a's
## `test_thin_slice_uses_only_the_sdk_facade` requires that, and
## `ci/test/debug-panes-test.sh` re-checks it against the file's own imports so
## the claim is not merely a habit.
##
## Build:
##   just debug-panes                 # resolves CODETRACER_SRC / ../codetracer

import std/[json, strutils, tables, unittest]

import codetracer_embed

import ../client/src/debugger/layout_model
import ../client/src/debugger/session_view
import ../client/src/debugger/source_document
import ../client/src/debugger/source_island
import ../client/src/components/debugger as panes
import ../client/hydrate/session_project

# ---------------------------------------------------------------------------
# One store, one mock backend, five ViewModels — a consumer's view of them
# ---------------------------------------------------------------------------

type Session = LiveSession
  ## The shipped session shape. `session_project.openLiveSession` builds it,
  ## `session_project.close` tears it down, and this suite only supplies the
  ## backend — which is the whole point: the browser passes a
  ## `WorkerBackendService`, this passes a `MockBackendService`, and everything
  ## downstream is the same code.

proc openSessionWith(): tuple[session: Session, mock: MockBackendService] =
  ## The session AND the mock behind it.
  ##
  ## The mock is kept because one thing below cannot be driven any other way:
  ## `ct/load-flow`'s real answer is a queued `ct/updated-flow` EVENT, not its
  ## reply, and reaching the event path needs `emitEvent`. A suite that could
  ## only write through the store would be unable to express that at all.
  let mock = newMockBackendService(autoRespond = true)
  (openLiveSession(mock.toBackendService(), sourceIsPublished = true), mock)

proc openSession(): Session = openSessionWith().session

# The source text a real session gets from a published source bundle, not from
# the container (Trace-Artifacts §2.5: the container interns paths and
# positions and carries no source text). Kept tiny and inline here — the join
# under test is "position from the trace, text from the bundle, matched by the
# interned path", and a large file would not exercise it any harder.
const ShieldNr = """pub fn iterate_asteroids(initial_shield: Field) -> bool {
    let mut remaining_shield = initial_shield;
    for i in 0..8 {
        let damage = calculate_damage(remaining_shield);
        remaining_shield -= damage;
    }
    remaining_shield as u32 > 0
}
"""

# ---------------------------------------------------------------------------
# The projection: ViewModel state -> the pane types the renderers read
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# The one thing this suite still builds: the SERVED frame the projection
# overlays. In the browser that comes from the page; here it is stated.
# ---------------------------------------------------------------------------

proc sourceIsland(path, language, text: string): string =
  ## The inlined source bundle, built through the SAME encoder `pages/debug.nim`
  ## serves and the same decoder hydration reads — so "position from the trace,
  ## text from the bundle, matched by the interned path" is exercised over the
  ## real carrier rather than over a hand-made `EditorPane`.
  var pane: EditorPane
  pane.availability = SourceAvailabilityView.srcSourceLevel
  pane.documents = @[newSourceDocument(path, language, text)]
  encodeSourceIsland(pane)

proc servedFrame(step, total: int; positioned = true): DebugSessionView =
  ## What the static route rendered before hydration: identity, metadata, and
  ## the step count from the manifest. Everything else comes from the engine.
  ##
  ## `positioned` is a PARAMETER and not `step > 0`, mirroring the `data-positioned`
  ## attribute the served page now writes. Deriving it here would rebuild, inside
  ## the test harness, the exact sentinel the code under test was changed to
  ## remove — and a harness that shares the defect cannot witness it.
  result.chain = "aztec"
  result.txHash = "0xabc1230000000000000000000000000000000000"
  result.hasFrame = true
  result.phase = spFetching
  result.integrity = siValidated
  result.controls.step = step
  result.controls.totalSteps = total
  result.controls.positioned = positioned
  result.metadata = MetadataPane(
    chain: "aztec", hash: result.txHash, outcome: "Succeeded",
    outcomeBadge: "ok",
    rows: @[MetaRow(label: "Block", value: "102:0", identifier: true)])

proc projectSession(s: Session; path, text: string; step, total: int;
                    positioned = true): DebugSessionView =
  ## The shipping projection, over the shipping island encoder.
  projectReplayPanes(s, servedFrame(step, total, positioned),
                     sourceIsland(path, "noir", text))

proc writeRow(index: int; kind, file: string; line: int;
              value: string; ticks: uint64): EventLogRow =
  EventLogRow(eventId: ticks, eventIndex: index, kindId: 1, kind: kind,
              file: file, line: line, value: value,
              rrTicks: ticks, maxRRTicks: 4096'u64)

# ---------------------------------------------------------------------------

suite "M8a — the debug panes render the Embed SDK's own ViewModels":

  test "the Embed SDK is really the one being linked":
    # The same guard `tests/tembedhandoff.nim` opens with: if this file
    # compiled against a local stand-in, everything below would be a test of
    # nothing.
    check CodeTracerEmbedFacadeModule == "codetracer_embed"

  test "a session driven through MockBackendService renders every pane":
    createRoot proc(dispose: proc()) =
      let s = openSession()

      # Position: what a `stopped` event would write.
      s.store.updateDebuggerPosition(128'u64, file = "src/shield.nr", line = 5,
                                     sourceGeneration = 1, sourceDigest = "d1")
      s.store.setSourceAvailability(savVerified)
      s.store.setSessionMode(completedReplay)

      # Call structure.
      s.calltrace.setViewportHeight(8)
      s.store.updateCalltraceSection(@[
        makeCallLine("main", 0, 1'u64, file = "src/main.nr", line = 12),
        makeCallLine("iterate_asteroids", 1, 6'u64, file = "src/shield.nr", line = 1),
        makeCallLine("calculate_damage", 2, 41'u64, file = "src/shield.nr", line = 4),
      ], startIndex = 0'i64, totalCount = 3'u64)

      # Variables.
      # `applyLocals` and not `store.updateLocals`: since `live_locals`, values
      # in the store are not on their own a statement about WHICH position they
      # belong to, and `projectState` refuses to render values it cannot place.
      # A driver that mirrors a reply into the store directly — which is what
      # this suite is, standing in for the parse `live_locals` does against a
      # real engine — says here that they are this position's.
      s.applyLocals(@[
        makeVariable("initial_shield", "10000", "Field"),
        makeVariable("remaining_shield", "9000", "Field"),
      ])

      # Events, of more than one kind.
      s.eventLog.setPageSize(10)
      s.eventLog.appendLiveDebuggerStop(
        writeRow(0, "Call", "src/shield.nr", 1, "initial_shield=10000", 6'u64))
      s.eventLog.appendLiveDebuggerStop(
        writeRow(1, "Write", "src/shield.nr", 5, "10000 → 9900", 31'u64))
      s.eventLog.appendLiveDebuggerStop(
        writeRow(2, "Revert", "src/main.nr", 35, "constraint not satisfied", 1299'u64))

      let view = projectSession(s, "src/shield.nr", ShieldNr, 128, 1315)
      let html = panes.renderLayout(defaultReplayLayout(), view)

      # ── the values on screen came out of the ViewModels ──────────────────
      # Source: the position is the EditorVM's, the text is the bundle's, and
      # the two met on the interned path.
      check s.editor.activeFileName.val == "src/shield.nr"
      check s.store.debugger.val.location.line == 5
      # The bundle's text reached the pane. Checked on the PROJECTION rather
      # than by substring-matching the markup: since VD.5 a source line is a run
      # of `<span>`s, so its text is no longer contiguous in the HTML, and a
      # test that matched fragments of it would be asserting the tokenisation
      # instead of the handoff this suite is about.
      check view.editor.documents[0].lines[4].text ==
            "        remaining_shield -= damage;"
      check ("id=\"" & lineAnchor("src/shield.nr", 5) & "\"") in html
      check "class=\"srcline cur" in html

      # Call trace: every visible line of the CalltraceVM, at its depth.
      # Matched through the `ctname` class and not on the bare name — the
      # source pane now renders `calculate_damage` as a `tk-function` span too,
      # so an unqualified `>name</span>` would be satisfied by the wrong pane.
      # The class is BUILT from the `Copyable` constant rather than spelled
      # out: a frame name is a value a reader takes out of the session (§13),
      # and a test that restated the attribute would fail the next time the set
      # of copyable values changes, which is not what it is here to detect.
      #
      # Qualified `session_view.` and NOT `panes.`, which is what it said when
      # it landed and is why this file stopped compiling that same day.
      # `components/debugger` USES the constant but does not re-export it, and a
      # qualified name in Nim resolves only against what a module defines or
      # exports — so `panes.Copyable` is an undeclared identifier, and the whole
      # suite went dark on a symbol that was right there. `viewutil` re-exports
      # it for the explorer's pages; the renderers are the same constant's other
      # reader, and here the definition is named directly.
      check s.calltrace.visibleLines.val.len == 3
      for line in s.calltrace.visibleLines.val:
        check ("<span class=\"ctname " & session_view.Copyable & "\">" &
               line.name & "</span>") in html
        check ("ctrow d" & $line.depth) in html

      # State: every variable the StateVM currently exposes.
      check s.state.currentVariables.val.len == 2
      for v in s.state.currentVariables.val:
        check (">" & v.name & "</span>") in html
        check (">" & v.value & "</span>") in html

      # Event log: the three kinds, distinguished in the markup rather than
      # only in a label.
      check s.eventLog.totalEventCount.val == 3
      check "evrow k-call" in html
      check "evrow k-storageWrite" in html
      check "evrow k-revert" in html

      # Controls: the affordances the DebugControlsVM derives, including the
      # backward pair, which is the product's premise.
      check s.controls.canStepBackward.val
      check s.controls.canReverseContinue.val
      check ("<span class=\"dcphase\">" & s.controls.statusText.val) in html
      check "dcbtn off" notin html

      s.close()
      dispose()

  test "MUTATION BITE: moving a ViewModel moves the rendered pane":
    # Without this, every assertion above could be satisfied by a renderer
    # that ignores its argument and prints the fixture it was written against.
    createRoot proc(dispose: proc()) =
      let s = openSession()
      s.store.setSourceAvailability(savVerified)
      s.store.setSessionMode(completedReplay)
      s.calltrace.setViewportHeight(8)
      s.store.updateCalltraceSection(@[
        makeCallLine("main", 0, 1'u64, file = "src/main.nr", line = 12)],
        startIndex = 0'i64, totalCount = 1'u64)
      s.store.updateDebuggerPosition(10'u64, file = "src/shield.nr", line = 2)
      s.applyLocals(@[makeVariable("remaining_shield", "10000", "Field")])

      let before = panes.renderLayout(defaultReplayLayout(),
        projectSession(s, "src/shield.nr", ShieldNr, 10, 1315))

      # One step later: the position moved, the variable was written, and a
      # frame was pushed. Every one of those is a change to a signal in the
      # store — the seam a real backend writes through.
      s.store.updateDebuggerPosition(11'u64, file = "src/shield.nr", line = 5)
      s.applyLocals(@[makeVariable("remaining_shield", "9000", "Field")])
      s.store.updateCalltraceSection(@[
        makeCallLine("main", 0, 1'u64, file = "src/main.nr", line = 12),
        makeCallLine("calculate_damage", 1, 41'u64, file = "src/shield.nr", line = 4)],
        startIndex = 0'i64, totalCount = 2'u64)

      let after = panes.renderLayout(defaultReplayLayout(),
        projectSession(s, "src/shield.nr", ShieldNr, 11, 1315))

      check before != after
      check ("id=\"" & lineAnchor("src/shield.nr", 2) & "\" data-line=\"2\"") in before
      check "class=\"srcline cur" in before
      # Every one of these names the PANE it belongs to. An unqualified
      # `>value</span>` used to be unambiguous and is not any more: the source
      # pane emits `tk-number` spans around numeric literals and `tk-function`
      # spans around call names, so `>calculate_damage</span>` is now satisfied
      # by line 4 of the source in BOTH renders and the mutation bite would
      # have stopped biting — silently, and while still passing on the `in`
      # half of every pair.
      let stval = "<span class=\"stval " & session_view.Copyable & "\">"
      let ctname = "<span class=\"ctname " & session_view.Copyable & "\">"
      check (stval & "10000</span>") in before
      check (stval & "9000</span>") notin before
      check (stval & "9000</span>") in after
      check (ctname & "calculate_damage</span>") notin before
      check (ctname & "calculate_damage</span>") in after

      s.close()
      dispose()

  test "an integer local off the wire renders its digits":
    ## The two tests above hand `makeVariable` its value already spelled, so
    ## neither of them reads a `ct/load-locals` `Value` at all. This one does,
    ## and it is here because that gap let a one-line regression through:
    ## `4419c61` ("code pane: the exact price of the window…") replaced
    ## `live_locals.valueText`'s integer arm with `""` while changing nothing
    ## else about locals — a stray edit in a commit whose message is entirely
    ## about code-pane windowing and which says of its changes "neither of them
    ## a behaviour change". Every `Field` and `u32` in a Noir trace — which is
    ## most of a Noir frame — rendered as a blank cell, and the State pane went
    ## on presenting the blanks as confidently as it presents values.
    ##
    ## `kind` is the wire ORDINAL, not a name (`live_locals.nim:99-149`): 7 is
    ## `tkInt`, in the module's own spelling, and the payload is the DECIMAL
    ## STRING in `i` — an engine `Field` does not fit an i64, which is why the
    ## arm is `getStr` and why `getInt` would be the same defect with a
    ## different cause.
    const tkInt = 7

    let wireInt = %*{"kind": tkInt, "i": "42",
                     "typ": {"langType": "Field", "kind": tkInt}}
    # Both halves stated: the digits exactly, and that the result is not the
    # empty string. The second is what the regression produced, and an
    # assertion that only compared to "42" would have caught it while an
    # assertion that only checked non-emptiness would not have caught a wrong
    # number.
    check valueText(wireInt) == "42"
    check valueText(wireInt).len > 0

    # …and through the parse the store is actually written by, so this is a
    # statement about the reply path and not only about one helper.
    let parsed = variablesOf(%*{"locals": [
      {"expression": "remaining_shield", "value": wireInt}]})
    check parsed.len == 1
    check parsed[0].name == "remaining_shield"
    check parsed[0].value == "42"
    check parsed[0].value.len > 0
    check parsed[0].typeName == "Field"

  test "a degraded state arriving over the BACKEND SEAM reaches the panes":
    # Not a host-side setter: a `CtReplayStatus` event pushed through
    # `MockBackendService.emitEvent`, which is the path a real worker uses.
    createRoot proc(dispose: proc()) =
      let s = openSession()
      s.store.setSourceAvailability(savVerified)
      s.store.setSessionMode(completedReplay)
      s.store.updateDebuggerPosition(1'u64, file = "src/shield.nr", line = 2)
      check not s.controls.divergenceDetected.val

      s.store.setTraceIntegrity(tiDivergent)
      check s.controls.divergenceDetected.val
      let view = projectSession(s, "src/shield.nr", ShieldNr, 1, 1315)
      check view.integrity == siDivergent

      s.store.setSourceAvailability(savUnverified)
      let degraded = projectSession(s, "src/shield.nr", ShieldNr, 1, 1315)
      let html = panes.renderSource(degraded.editor)
      # §14's "no verified source" row: instruction-level stepping, with the
      # supply-sources action prominent — and nothing pretending to be code.
      check "Supply sources" in html
      check "instruction level" in html
      check "remaining_shield" notin html

      s.close()
      dispose()

  test "the loop rail arrives on the EVENT path, not on the reply":
    ## Omniscience's loop control, over the real `FlowVM`.
    ##
    ## `Omniscience-Flow.md` records the hazard this test is shaped around:
    ## `ct/load-flow`'s real answer is a queued `ct/updated-flow` EVENT
    ## (`db-backend/src/dap.rs`), so "a panel that consumed only the reply would
    ## stay empty forever against the real engine while every mock-driven test
    ## passed". Nothing here writes the window through a reply or through a
    ## setter: the ONLY way it reaches the ViewModel is `emitEvent`, which is
    ## the path a worker uses.
    createRoot proc(dispose: proc()) =
      let (s, mock) = openSessionWith()
      s.store.setSourceAvailability(savVerified)
      s.store.setSessionMode(completedReplay)

      # ── before the event: no loop, and therefore no rail ─────────────────
      # The negative first, so the assertions after it cannot be satisfied by a
      # rail that renders unconditionally.
      s.store.updateDebuggerPosition(175'u64, file = "src/shield.nr", line = 6)
      check s.flow.focusedLoop.val == -1
      check projectFlowRail(s.flow, "src/shield.nr").loopIndex == 0
      let blank = projectSession(s, "src/shield.nr", ShieldNr, 175, 1315)
      check blank.editor.flow.loopIndex == 0
      check "class=\"flowrail\"" notin panes.renderSource(blank.editor)

      # …and the position change DID make the VM ask. A rail that appeared
      # without the request having been issued would be reading something else.
      var asked = false
      for received in mock.receivedCommands:
        if received.command == "ct/load-flow": asked = true
      check asked

      # ── the window, delivered exactly as the engine delivers it ──────────
      # Eight passes of `for i in 0..8 {` on line 4, with the header tick of
      # each — the real `rrTicksForIterations` of the `zk_shields` recording.
      # `location.rrTicks` is 175, which is INSIDE the third pass's body and not
      # on any header: the case issue #593 got wrong by comparing for equality
      # and freezing the counter at pass 1.
      mock.emitEvent(%*{
        "kind": "CtUpdatedFlow",
        "data": {
          "location": {"rrTicks": 175},
          "viewUpdates": [{
            "location": {"rrTicks": 175},
            "loops": [
              {},
              {"first": 4, "last": 15, "registeredLine": 4,
               "rrTicksForIterations": [13, 95, 175, 257, 339, 421, 503, 585]}]
          }]
        }})

      check s.flow.focusedLoop.val == 1
      check s.flow.totalIterations.val == 8
      check s.flow.selectedIteration.val == 2      # the pass 175 falls inside

      let rail = projectFlowRail(s.flow, "src/shield.nr")
      check rail.loopIndex == 1
      check rail.line == 4
      # A same-page fragment: hydration runs on the debug route, which renders
      # every line, so the header is on the page. The narrowed home embed is a
      # different surface and is asserted in `test_debug_route`.
      check rail.href == "#" & lineAnchor("src/shield.nr", 4)
      check rail.selected == 2
      check rail.navigable                          # a live session SEEKS
      check rail.iterations.len == 8
      check rail.iterations[5].ticks == 421

      # ── and it reaches the markup, through the route's own renderer ──────
      let view = projectSession(s, "src/shield.nr", ShieldNr, 175, 1315)
      check view.editor.flow.loopIndex == 1
      let html = panes.renderSource(view.editor)
      check "class=\"flowrail\"" in html
      check "Iteration 3 of 8" in html
      # Every segment carries its pass's header tick, which is what
      # `hydrate.bindGestures` hands to `ct/goto-ticks` — no new protocol, the
      # same `data-step` a call-trace row already uses.
      check "data-step=\"421\"" in html
      # A live segment is NOT a `:target` link. That mechanism switches which
      # recorded pass is displayed, and a live rail does something else: it
      # moves the debugger. Offering both would be two meanings on one control.
      check "href=\"#fit-" notin html

      s.close()
      dispose()

  test "the rail refuses a window it cannot honestly draw":
    # Fail-closed, in the two shapes the engine can actually produce. Neither is
    # defensive coding: a rail is "this loop, at this line, N passes", and a
    # window missing any of those would be drawn as `line -1` or as `of 0`.
    createRoot proc(dispose: proc()) =
      let (s, mock) = openSessionWith()
      s.store.setSourceAvailability(savVerified)
      s.store.updateDebuggerPosition(175'u64, file = "src/shield.nr", line = 6)

      # A loop with no recorded passes: `pickFocusedLoop` skips it, so there is
      # no focused loop at all.
      mock.emitEvent(%*{
        "kind": "CtUpdatedFlow",
        "data": {"location": {"rrTicks": 175},
                 "viewUpdates": [{"loops": [{}, {"first": 4, "last": 15,
                                                 "registeredLine": 4,
                                                 "rrTicksForIterations": []}]}]}})
      check s.flow.focusedLoop.val == -1
      check projectFlowRail(s.flow, "src/shield.nr").loopIndex == 0

      # A loop with passes but no line to attach the control to. `parseFlowLoop`
      # defaults `registeredLine` to -1, and a rail reading "Loop line -1" is
      # worse than no rail: half of what the control says is where the loop is.
      mock.emitEvent(%*{
        "kind": "CtUpdatedFlow",
        "data": {"location": {"rrTicks": 175},
                 "viewUpdates": [{"loops": [{}, {"rrTicksForIterations": [13, 95]}]}]}})
      check s.flow.focusedLoop.val == 1
      check s.flow.totalIterations.val == 2
      check projectFlowRail(s.flow, "src/shield.nr").loopIndex == 0

      s.close()
      dispose()

  test "no verified source means no rail, on this producer too":
    # §14's row, and the same rule `flow_view.applyFlow` enforces on the static
    # side. Two producers of one frame, and the fidelity ladder has to bind both
    # — a rail pointing at a loop header in a file the pane is not showing would
    # be a control addressing nothing.
    createRoot proc(dispose: proc()) =
      let (s, mock) = openSessionWith()
      s.store.setSessionMode(completedReplay)
      s.store.updateDebuggerPosition(175'u64, file = "src/shield.nr", line = 6)
      mock.emitEvent(%*{
        "kind": "CtUpdatedFlow",
        "data": {"location": {"rrTicks": 175},
                 "viewUpdates": [{"loops": [{}, {"first": 4, "last": 15,
                                                 "registeredLine": 4,
                                                 "rrTicksForIterations": [13, 95, 175]}]}]}})
      # The window IS loaded — so the absence below is the availability's doing
      # and not an empty flow window's.
      check s.flow.focusedLoop.val == 1

      s.store.setSourceAvailability(savVerified)
      check projectSession(s, "src/shield.nr", ShieldNr, 175, 1315)
              .editor.flow.loopIndex == 1
      s.store.setSourceAvailability(savUnverified)
      let degraded = projectSession(s, "src/shield.nr", ShieldNr, 175, 1315)
      check degraded.editor.flow.loopIndex == 0
      check "class=\"flowrail\"" notin panes.renderSource(degraded.editor)

      s.close()
      dispose()

  test "the arrangement over SDK data is still the model's, not a copy":
    createRoot proc(dispose: proc()) =
      let s = openSession()
      s.store.setSourceAvailability(savVerified)
      s.store.updateDebuggerPosition(1'u64, file = "src/shield.nr", line = 2)
      let view = projectSession(s, "src/shield.nr", ShieldNr, 1, 1315)

      let reference = panes.renderLayout(defaultReplayLayout(), view)
      for pane in allPanes(defaultReplayLayout()):
        check ("id=\"pane-" & ($pane).toLowerAscii & "\"") in reference

      var swapped = defaultReplayLayout()
      check activate(swapped, paneEventLog)
      check panes.renderLayout(swapped, view) != reference

      s.close()
      dispose()

  test "the timeline's playhead SURVIVES hydration, on its own tick — step 0 included":
    ## Page-Descriptions §7.0: "No state renders less than the pre-hydration
    ## page." Journey 06 asserts the marked SOURCE LINE survives; nothing
    ## asserted the PLAYHEAD did, and it did not.
    ##
    ## `ReplayDataStore` initialises `debugger.rrTicks` to 0, and a freshly-live
    ## session has not been moved off it: `goLive` renders the ready page before
    ## its seek returns, and a session with no `?t=` issues no seek at all. So
    ## the store says 0, `positioned` was `step > 0`, and `renderControls`'s
    ## `filled` collapsed to 0 — not one of the 48 ticks carried `.at` or `.on`,
    ## on a page whose served frame had drawn the playhead moments before.
    ##
    ## THE FIRST FIX FOR THAT INTRODUCED A WORSE BUG, and arm D is the memorial.
    ## It distinguished "the engine has reported" from "there is a position" by
    ## testing `step > 0`, which is the same conflation one level up: tick 0 is a
    ## REAL position, so a session the engine parked there looked silent, the
    ## served frame won, and the jump stopped working. Presence is now carried by
    ## `LiveSession.reported`, and no assertion here may be satisfiable by a
    ## session that merely has a large step.
    ##
    ## THE PLAYHEAD'S TICK IS ASSERTED, NOT ITS EXISTENCE. "Something is marked"
    ## is satisfied by a playhead parked anywhere, including the wrong end of the
    ## trace, so each arm pins the SPECIFIC tick by counting the `.on` ticks that
    ## precede the `.at` one — `renderControls` marks `i == filled` as `.at` and
    ## every `i < filled` as `.on`, so that count IS the position, read off the
    ## rendered markup rather than from the pane object that produced it.
    createRoot proc(dispose: proc()) =
      let s = openSession()
      s.store.setSourceAvailability(savVerified)

      # The rendered scrubber, as three counts. Nothing here restates the
      # renderer's arithmetic — it reads the marks back off the HTML.
      proc scrubber(view: DebugSessionView):
          tuple[total, before, at: int] =
        let html = panes.renderControls(view.controls)
        (html.count("class=\"tick"),
         html.count("class=\"tick on\""),
         html.count("class=\"tick at\""))

      var asserted = 0

      # ARM A — THE DEFECT. The engine has said nothing, so the store still
      # holds its initial 0; the served page stood at step 128 of 1315.
      check s.store.debugger.val.rrTicks == 0'u64   # the arm's precondition
      inc asserted
      let live = projectSession(s, "src/shield.nr", ShieldNr, 128, 1315)
      let a = scrubber(live)

      # 48 ticks, asserted so that a change to the renderer's `TimelineTicks`
      # reddens HERE rather than silently shifting every expected index below.
      check a.total == 48
      inc asserted
      # 128/1315 = 0.09734; 0.09734*48 = 4.672; +0.5 -> 5.172; truncated -> 5.
      # So the playhead is the 5th tick and exactly 4 ticks are filled behind it.
      check a.at == 1
      inc asserted
      check a.before == 4
      inc asserted
      check live.controls.step == 128
      inc asserted
      check live.controls.positioned
      inc asserted

      # ARM B — THE ENGINE OVERRIDES IT. The fallback must yield the moment a
      # real frame arrives, or it is a hardcode that would pin every session to
      # the served step forever.
      #
      # `applyPosition` and NOT `store.updateDebuggerPosition`: the first is the
      # shipping path a stop takes (`applyStop` calls it) and the one that
      # records that the engine has reported. Writing the store directly would
      # move the number while leaving the session saying it had heard nothing,
      # which is a state the product cannot be in and would make this arm
      # evidence about a fiction.
      s.applyPosition(700'u64, file = "src/shield.nr", line = 5)
      check s.store.debugger.val.rrTicks == 700'u64  # the arm really mutated
      inc asserted
      let moved = projectSession(s, "src/shield.nr", ShieldNr, 128, 1315)
      let b = scrubber(moved)
      check moved.controls.step == 700          # the ENGINE's, not the served 128
      inc asserted
      # 700/1315 = 0.53232; *48 = 25.551; +0.5 -> 26.051; truncated -> 26.
      check b.at == 1
      inc asserted
      check b.before == 25
      inc asserted
      # And it MOVED — the two arms are distinguishable, which is what a third
      # position buys that a second one does not.
      check b.before != a.before
      inc asserted

      # ARM C — NO POSITION IS STILL NO POSITION. The fallback must not
      # MANUFACTURE one: a served page that published `data-step="0"` was not
      # positioned, and the hydrated session must not claim otherwise. Without
      # this arm "keep the served step" would be indistinguishable from "always
      # claim a position", which would put a playhead on every unpositioned page.
      let fresh = openSession()
      fresh.store.setSourceAvailability(savVerified)
      check fresh.store.debugger.val.rrTicks == 0'u64
      inc asserted
      let unpositioned =
        projectSession(fresh, "src/shield.nr", ShieldNr, 0, 1315,
                       positioned = false)
      let c = scrubber(unpositioned)
      check not unpositioned.controls.positioned
      inc asserted
      check unpositioned.controls.step == 0
      inc asserted
      check c.at == 0
      inc asserted
      check c.before == 0
      inc asserted
      check c.total == 48        # the ticks are drawn; none of them is marked
      inc asserted

      # ARM D — STEP 0 IS A POSITION. THIS IS THE ARM THE OTHERS DID NOT COVER.
      #
      # The first version of this fix read `step > 0` as "the engine has
      # reported", which collides with the engine reporting tick 0 — the first
      # step of the trace, where `run-to-entry` lands and what the FIRST ROW of
      # the call trace and event log carries. So clicking the first row produced
      # a report indistinguishable from silence, the served frame won, the
      # session did not move, and `09-a-jump-moves-the-position` went red on
      # `dev` while arms A, B and C above all stayed green — none of them
      # exercises 0. When a fix turns on a comparison against a constant, that
      # constant is the value the test must include.
      #
      # THE PAIR IS ASSERTED, because either half alone is forgeable: "positioned
      # at step 0" is satisfied by a session that reports a position it does not
      # draw, and "a playhead exists" is satisfied by one parked on the served
      # frame's tick. Together they say the session is AT step 0 and SHOWS it.
      let atZero = openSession()
      atZero.store.setSourceAvailability(savVerified)
      # The served page stood at 128 and was positioned, so a fallback that
      # ignored the engine would be VISIBLE here as tick 5 rather than tick 1.
      # That is what makes this arm able to fail.
      atZero.applyPosition(0'u64, file = "src/shield.nr", line = 2)
      check atZero.store.debugger.val.rrTicks == 0'u64
      inc asserted
      let zeroView = projectSession(atZero, "src/shield.nr", ShieldNr, 128, 1315)
      let d = scrubber(zeroView)
      check zeroView.controls.step == 0        # the ENGINE's 0, not the served 128
      inc asserted
      check zeroView.controls.positioned       # …and 0 is a POSITION
      inc asserted
      # fraction is 0.0 at step 0, and `filled` is clamped to a minimum of 1, so
      # the playhead is the FIRST tick and nothing is filled behind it.
      check d.at == 1
      inc asserted
      check d.before == 0
      inc asserted
      check d.total == 48
      inc asserted
      # And it is distinguishable from the served frame's tick, which is the
      # whole content of "the session moved THERE rather than somewhere".
      check d.before != a.before
      inc asserted
      atZero.close()

      # THE COUNT ITSELF. Twenty-four `check`s ran — an arm deleted, an arm that
      # failed to compile into the block, or a `check` that never executed
      # reddens HERE, which is the one failure a suite of passing assertions
      # cannot otherwise report.
      check asserted == 24

      fresh.close()
      s.close()
      dispose()

# ---------------------------------------------------------------------------
# The captured window: a real `ct/updated-flow`, from the pinned Embed SDK
# ---------------------------------------------------------------------------
#
# `projectFlowRail`'s header records why the VALUES did not cross before this
# suite grew the block below:
#
#     neither the parse nor the rendering can be checked against anything here:
#     a test written against a payload this repository invented would pass
#     whatever the engine actually sends
#
# The objection is answered by not inventing one. `capture_zk_shields_flow.nim`
# in the pinned SDK recorded `viewUpdates[0]` of a real `ct/updated-flow`
# event, verbatim, from the engine replaying `noir_space_ship` — the same
# program `fixtures/trace/noir_space_ship/zk_shields.ct` in THIS repository was
# recorded from — and ships it beside its own tests. So the parse below is
# checked against bytes the engine wrote, at the commit `ci/embed-sdk-pin.env`
# names, and a drift in the wire format fails this suite rather than passing it.
#
# THE EXPECTATIONS ARE RELATIONS, NOT CONSTANTS. Every value asserted below is
# recomputed from the capture by a second, deliberately naive reader in this
# file and compared against what the projection produced. A constant copied out
# of the capture would be satisfied by a projection that had copied the same
# constant; the two readers agreeing is the evidence. The SIZES are constants,
# and they are asserted, because a relation that quantifies over an empty set
# is a pass (`Verification-Harness-Traps.md` §4).

const CodetracerSrc* {.strdefine.} = ""
  ## The Embed SDK checkout `ci/test/debug-panes-test.sh` resolved, passed in
  ## rather than re-derived here — the script already finds it three ways
  ## (`$CODETRACER_SRC`, the sibling checkout, the Nix input) and two resolvers
  ## is how the tree this suite compiles against and the tree it reads fixtures
  ## from come to differ.

const CapturedWindowPath =
  "src/frontend/viewmodel/tests/fixtures/flow/zk_shields_flow_window.json"

proc capturedWindow(): JsonNode =
  ## The capture, or a raise. NOT an empty object and not a `skip`: a suite that
  ## quietly passed when it could not find the one artefact it is written
  ## against is the false green this block exists to be.
  parseJson(readFile(CodetracerSrc & "/" & CapturedWindowPath))

proc recordedPairs(view: JsonNode): seq[(int, string, int)] =
  ## Every (line, expression, pass) the engine recorded a value for, read
  ## straight out of the capture.
  ##
  ## The naive reader. It knows three things — a step's `position` is a source
  ## line, its `loop`/`iteration` name the pass, and `beforeValues`/`afterValues`
  ## are keyed by expression name — and nothing else. `return` is excluded
  ## because it is not an expression and does not travel as one
  ## (`live_flow.ReturnExpression`); a step outside every real loop is
  ## `flow_view.NoIteration`, which is the same rule `toAnnotation` applies.
  var seen = initTable[string, bool]()
  for step in view{"steps"}:
    let line = step{"position"}.getInt(0)
    let loop = step{"loop"}.getInt(0)
    let pass = if loop > 0: step{"iteration"}.getInt(0) else: NoIteration
    for field in ["beforeValues", "afterValues"]:
      let map = step{field}
      if map == nil or map.kind != JObject: continue
      for name, _ in map:
        if name == ReturnExpression: continue
        let key = $line & "\x1f" & name & "\x1f" & $pass
        if seen.hasKeyOrPut(key, true): continue
        result.add (line, name, pass)

proc paneLabels(pane: EditorPane; path: string): seq[(int, string, int)] =
  ## The same triple, read off the pane the renderers draw.
  for doc in pane.documents:
    if doc.path != path: continue
    for line in doc.lines:
      for ann in line.annotations:
        if ann.label.len == 0: continue
        result.add (line.number, ann.label, ann.iteration)

proc labelTextFor(pane: EditorPane; path: string; line: int;
                  expression: string): string =
  for doc in pane.documents:
    if doc.path != path: continue
    for row in doc.lines:
      if row.number != line: continue
      for ann in row.annotations:
        if ann.label == expression:
          return (if ann.afterValue.len > 0: ann.afterValue else: ann.beforeValue)
  ""

suite "M8b — omniscience follows a live session":

  test "a REAL ct/updated-flow window puts its values on the lines it recorded them on":
    createRoot proc(dispose: proc()) =
      # The capture first, and its own size asserted, so nothing below can
      # quantify over an empty set and pass.
      check CodetracerSrc.len > 0
      let capture = capturedWindow()
      let view = capture{"viewUpdate"}
      let position = capture{"position"}
      check view != nil and view.kind == JObject
      check view{"steps"}.len == 76        # the window the engine sent
      check view{"loops"}.len == 2         # the placeholder, and one real loop
      check capture{"sourceLines"}.len == 68

      # The file, from the capture's own `sourceLines`. Not a copy of
      # `shield.nr` kept here: the placement rules ask where an expression
      # occurs in a line, so the text the values were recorded against has to be
      # the text they are placed against, and the capture carries both.
      var shieldNr = ""
      for line in capture{"sourceLines"}:
        shieldNr.add line.getStr("") & "\n"

      let (s, mock) = openSessionWith()
      s.store.setSourceAvailability(savVerified)
      s.store.setSessionMode(completedReplay)

      let ticks = uint64(position{"rrTicks"}.getInt(0))
      check ticks == 121'u64               # the position the capture was taken at
      s.store.updateDebuggerPosition(
        ticks, file = "src/shield.nr", line = position{"line"}.getInt(0))

      # ── the negative first ────────────────────────────────────────────────
      # Before the window arrives there are no values, so nothing after it can
      # be satisfied by a pane that annotates unconditionally.
      let blank = projectSession(s, "src/shield.nr", shieldNr,
                                 int(ticks), 1315)
      check paneLabels(blank.editor, "src/shield.nr").len == 0
      check not s.flowWindow.hasWindow()

      # …and the move DID make the session ask. A window that appeared without
      # the request having gone out would be reading something else.
      var asked = 0
      for received in mock.receivedCommands:
        if received.command == "ct/load-flow": inc asked
      check asked >= 1

      # ── the window, delivered as the engine delivers it ───────────────────
      # `viewUpdates[0]` verbatim, under the envelope location the event
      # carries. The EVENT path and not a setter: `ct/load-flow`'s real answer
      # is a queued `ct/updated-flow`, and a consumer that read only the reply
      # would be empty against the real engine while this suite passed.
      mock.emitEvent(%*{
        "event": UpdatedFlowEvent,
        "body": {"location": position, "viewUpdates": [view]}})

      check s.flowWindow.hasWindow()
      check s.flowWindow.functionLabel == "iterate_asteroids"

      let live = projectSession(s, "src/shield.nr", shieldNr, int(ticks), 1315)
      let shown = paneLabels(live.editor, "src/shield.nr")
      let recorded = recordedPairs(view)

      # The two readers, and the size of the set the comparison is over.
      check recorded.len == 179
      check shown.len == recorded.len

      var missing = 0
      for pair in recorded:
        if pair notin shown: inc missing
      check missing == 0

      # Nothing INVENTED, either. The pane may not carry a label the engine did
      # not record — the direction a projection that fell back to "some
      # plausible value" would fail on, and the one a coverage check alone
      # cannot see.
      var invented = 0
      for pair in shown:
        if pair notin recorded: inc invented
      check invented == 0

      # ── the VALUE, not just the name ──────────────────────────────────────
      # `live_locals.valueText` renders the engine's `Value`; the capture holds
      # the same value as raw JSON. Both are read here and compared, so a
      # renderer that produced an empty string for every kind — the exact defect
      # `live_locals`' ordinal table was derived to avoid — fails.
      var wireValue = ""
      var wireLine = 0
      for step in view{"steps"}:
        let value = step{"afterValues"}{"initial_shield"}
        if value != nil and value.kind == JObject and
           value{"kind"}.getInt(-1) == 7:
          wireValue = value{"i"}.getStr("")
          wireLine = step{"position"}.getInt(0)
          break
      check wireValue.len > 0
      check wireLine > 0
      check labelTextFor(live.editor, "src/shield.nr", wireLine,
                         "initial_shield") == wireValue

      # ── the pass a label belongs to (rule 2) ──────────────────────────────
      # Every pass writes the SAME nine lines, so a projection that dropped the
      # pass would collapse them into one line's worth of labels and show pass
      # 7's numbers while the session is in pass 1. Counted, and the count is
      # cross-checked against the capture rather than stated: the two readers
      # have to agree about how many passes recorded anything.
      var passes: seq[int] = @[]
      for (_, _, pass) in shown:
        if pass >= 0 and pass notin passes: passes.add pass
      var wirePasses: seq[int] = @[]
      for (_, _, pass) in recorded:
        if pass >= 0 and pass notin wirePasses: wirePasses.add pass
      check passes.len == 8
      check wirePasses.len == passes.len

      # EIGHT PASSES OF VALUES AND NINE ITERATIONS ON THE RAIL, and the two
      # numbers are different because the ninth pass is the loop header's last
      # evaluation — the one that ended the loop. The engine records a step for
      # it (`exprOrder: ["i"]`, on line 4) and no values, so it is a pass the
      # rail can reach and a pass with nothing to show. Asserting one number for
      # both would have forced whichever is wrong onto the other.
      check live.editor.flow.iterations.len == 9

      # And the rail opens on the pass the POSITION is in, derived from the
      # tick and not defaulted to 0 (issue #593). 121 falls between the second
      # and third iteration headers, which is pass 1.
      check live.editor.flow.loopIndex == 1
      check live.editor.flow.line == 4
      check live.editor.flow.selected == 1

      # ── and moving inside the function RE-SELECTS THE PASS ────────────────
      #
      # The window is a window over `iterate_asteroids`, not over tick 121, so a
      # step to another position in the same loop is still this window's. What
      # changes is WHICH PASS is on screen, and that is decided by the SESSION's
      # tick and not by the window's own `location.rrTicks` — which the engine
      # leaves at 0 on every answer this build receives (journey 19), so a
      # projection reading it would pin every session to pass 0 for ever. That
      # is issue #593 arriving through a field that is not filled rather than
      # through a comparison that is wrong.
      #
      # 257 is the FOURTH iteration header of this loop, so the rail must open
      # on pass 3.
      s.store.updateDebuggerPosition(257'u64, file = "src/shield.nr", line = 9)
      check s.flowWindow.hasWindow()
      let moved = projectSession(s, "src/shield.nr", shieldNr, 257, 1315)
      check moved.editor.flow.loopIndex == 1
      check moved.editor.flow.selected == 3
      # …and the labels are still the engine's, on the same lines. The overlay
      # does not blink off between two positions of one function — which it did
      # while the tick was the gate, and which made the pane jump a beat after
      # every step (`live_flow.hasWindow`).
      check paneLabels(moved.editor, "src/shield.nr").len == 179

      s.close()
      dispose()

  test "instruction level gets no overlay, however full the window is":
    ## Rule 1, over the same real window. Below source-level fidelity there is
    ## nothing to place a value against, and the failure mode is not an empty
    ## pane — it is a complete, confident, entirely fictional one. The window
    ## here is the same 76 real steps; the only thing that changes is what the
    ## page published.
    createRoot proc(dispose: proc()) =
      let capture = capturedWindow()
      let view = capture{"viewUpdate"}
      let position = capture{"position"}
      var shieldNr = ""
      for line in capture{"sourceLines"}:
        shieldNr.add line.getStr("") & "\n"

      let (s, mock) = openSessionWith()
      s.store.setSessionMode(completedReplay)
      let ticks = uint64(position{"rrTicks"}.getInt(0))
      s.store.setSourceAvailability(savVerified)
      s.store.updateDebuggerPosition(ticks, file = "src/shield.nr", line = 7)
      mock.emitEvent(%*{
        "event": UpdatedFlowEvent,
        "body": {"location": position, "viewUpdates": [view]}})

      # The control: at source level this window DOES annotate. Without it the
      # assertion below would be satisfied by a window that never applied.
      check s.flowWindow.hasWindow()
      let verified = projectSession(s, "src/shield.nr", shieldNr,
                                    int(ticks), 1315)
      check paneLabels(verified.editor, "src/shield.nr").len == 179

      s.store.setSourceAvailability(savUnverified)
      let degraded = projectSession(s, "src/shield.nr", shieldNr,
                                    int(ticks), 1315)
      var labels = 0
      for doc in degraded.editor.documents:
        for line in doc.lines: labels += line.annotations.len
      check labels == 0
      check degraded.editor.flow.loopIndex == 0

      s.close()
      dispose()

  test "a window for another FILE annotates nothing on this one":
    ## The path is resolved, not compared — the engine sends an absolute path on
    ## the recording machine and the pane's documents carry the interned one, so
    ## a `==` would be false for every real session. Resolving it must not
    ## become resolving it to WHATEVER is open: a window loaded for `main.nr`
    ## has nothing to say about `shield.nr`, and putting its values there would
    ## be values on lines they were never recorded on.
    createRoot proc(dispose: proc()) =
      let capture = capturedWindow()
      let view = capture{"viewUpdate"}
      var shieldNr = ""
      for line in capture{"sourceLines"}:
        shieldNr.add line.getStr("") & "\n"

      let (s, mock) = openSessionWith()
      s.store.setSourceAvailability(savVerified)
      s.store.setSessionMode(completedReplay)
      s.store.updateDebuggerPosition(121'u64, file = "src/shield.nr", line = 7)

      # The same window, relabelled as another file's. Everything else about it
      # is the engine's.
      mock.emitEvent(%*{
        "event": UpdatedFlowEvent,
        "body": {
          "location": {
            "path": "/somewhere/noir_space_ship/src/main.nr",
            "line": 12, "rrTicks": 121},
          "viewUpdates": [view]}})

      check s.flowWindow.hasWindow()
      let view2 = projectSession(s, "src/shield.nr", shieldNr, 121, 1315)
      check paneLabels(view2.editor, "src/shield.nr").len == 0

      s.close()
      dispose()
