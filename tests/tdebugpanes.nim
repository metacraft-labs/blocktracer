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

import std/[json, strutils, unittest]

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

proc servedFrame(step, total: int): DebugSessionView =
  ## What the static route rendered before hydration: identity, metadata, and
  ## the step count from the manifest. Everything else comes from the engine.
  result.chain = "aztec"
  result.txHash = "0xabc1230000000000000000000000000000000000"
  result.hasFrame = true
  result.phase = spFetching
  result.integrity = siValidated
  result.controls.step = step
  result.controls.totalSteps = total
  result.metadata = MetadataPane(
    chain: "aztec", hash: result.txHash, outcome: "Succeeded",
    outcomeBadge: "ok",
    rows: @[MetaRow(label: "Block", value: "102:0", identifier: true)])

proc projectSession(s: Session; path, text: string; step, total: int):
    DebugSessionView =
  ## The shipping projection, over the shipping island encoder.
  projectReplayPanes(s, servedFrame(step, total),
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
      # The class is BUILT from `panes.Copyable` rather than spelled out: a
      # frame name is a value a reader takes out of the session (§13), and a
      # test that restated the attribute would fail the next time the set of
      # copyable values changes, which is not what it is here to detect.
      check s.calltrace.visibleLines.val.len == 3
      for line in s.calltrace.visibleLines.val:
        check ("<span class=\"ctname " & panes.Copyable & "\">" &
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
      let stval = "<span class=\"stval " & panes.Copyable & "\">"
      let ctname = "<span class=\"ctname " & panes.Copyable & "\">"
      check (stval & "10000</span>") in before
      check (stval & "9000</span>") notin before
      check (stval & "9000</span>") in after
      check (ctname & "calculate_damage</span>") notin before
      check (ctname & "calculate_damage</span>") in after

      s.close()
      dispose()

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
      check rail.anchor == lineAnchor("src/shield.nr", 4)
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
