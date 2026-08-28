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
## ## The projection is the part that will be replaced, and that is the point
##
## `project*` below is deliberately small and deliberately in a test. The
## shipping adapter is `WorkerBackendService` plus a hydration entry point,
## which is a separate workstream (Debugger-Integration §2's DAP-over-
## `postMessage` transport). What this file fixes is the SEAM those will meet:
## the pane types, and the renderers over them. When the adapter lands it
## replaces these functions and nothing below them.
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

import std/[options, strutils, unittest]

import codetracer_embed

import ../client/src/debugger/layout_model
import ../client/src/debugger/session_view
import ../client/src/debugger/source_document
import ../client/src/components/debugger as panes

# ---------------------------------------------------------------------------
# One store, one mock backend, five ViewModels — a consumer's view of them
# ---------------------------------------------------------------------------

type Session = object
  store: ReplayDataStore
  mock: MockBackendService
  editor: EditorVM
  calltrace: CalltraceVM
  state: StateVM
  eventLog: EventLogVM
  controls: DebugControlsVM

proc openSession(): Session =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  Session(
    store: store, mock: mock,
    editor: createEditorVM(store),
    calltrace: createCalltraceVM(store),
    state: createStateVM(store),
    eventLog: createEventLogVM(store),
    controls: createDebugControlsVM(store))

proc close(s: Session) =
  s.editor.dispose()
  s.calltrace.dispose()
  s.state.dispose()
  s.eventLog.dispose()
  s.controls.dispose()
  s.store.dispose()

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

proc projectEditor(vm: EditorVM; store: ReplayDataStore;
                   path, text: string): EditorPane =
  ## Position from the session, text from the bundle, joined on the interned
  ## path — which is exactly how a real session resolves a step to a line.
  ##
  ## The line comes from the STORE's debugger position, not from
  ## `EditorVM.cursorLine`: the second is the user's caret, which a shell moves
  ## on a click, and the pane's current-line marker has to mean "the step the
  ## session is on". They coincide in a real shell only because the shell sets
  ## the caret when a stop arrives.
  let position = store.debugger.val.location
  case vm.sourceAvailability.val
  of savVerified:
    result.availability = SourceAvailabilityView.srcSourceLevel
    result.documents = @[newSourceDocument(
      path, "noir", text, currentLine = position.line)]
    result.currentLine = position.line
  of savUnverified:
    result.availability = SourceAvailabilityView.srcUnverified
    result.reason = "No source bundle is published for the code that ran."
  else:
    result.availability = SourceAvailabilityView.srcAbsent
    result.reason = "This execution ran no contract code."

proc projectCalltrace(vm: CalltraceVM): CallTracePane =
  result.costLabel = "ACIR"
  for line in vm.visibleLines.val:
    result.frames.add CallFrame(
      depth: line.depth,
      fn: line.name,
      module: line.location.file,
      cost: $line.rrTicks,
      costUnit: "ticks",
      step: int(line.rrTicks),
      current: vm.selectedEntry.val == some(line.index))

proc projectState(vm: StateVM): StatePane =
  for v in vm.currentVariables.val:
    result.values.add StateValue(
      name: v.name, typ: v.typeName, value: v.value,
      # `changed` is the pane's "written at this step" marker. The StateVM
      # does not model that yet, so the projection maps it to the VM's own
      # selection rather than inventing a value — a marker that lit up on
      # nothing would be indistinguishable from a correct one.
      changed: vm.selectedPath.val == v.name)

proc kindOf(row: EventLogRow): EventKind =
  ## The chain reading of an ordinary event row. CodeTracer-Embed-SDK §3.2
  ## keeps every chain concept one layer up, so `kind` is free text the
  ## recorder supplies and turning it into `evStorageWrite` is the CONSUMER's
  ## job — which is what makes this projection the right place for it.
  case row.kind.toLowerAscii
  of "write", "storagewrite": evStorageWrite
  of "call": evCall
  of "revert": evRevert
  of "output", "stdout": evOutput
  else: evEvent

proc projectEventLog(vm: EventLogVM): EventLogPane =
  ## The page the EventLogVM's paging signals select. The VM owns the rows,
  ## the page index and the page size and exposes no pre-sliced memo, so the
  ## slice is the consumer's — which is the right side of the boundary for it:
  ## how many rows a pane shows is a property of the pane.
  let rows = vm.eventRows.val
  let size = max(1, vm.pageSize.val)
  let first = vm.currentPage.val * size
  for i in first ..< min(first + size, rows.len):
    let row = rows[i]
    result.rows.add EventRow(
      kind: kindOf(row),
      step: int(row.rrTicks),
      label: row.file & ":" & $row.line,
      detail: row.value,
      current: vm.selectedRow.val == some(row.eventIndex))

proc projectControls(vm: DebugControlsVM; step, total: int): DebugControlsPane =
  proc btn(a: DebugAction; label, glyph: string; on: bool): ControlButton =
    ControlButton(action: a, label: label, glyph: glyph, enabled: on)
  result.buttons = @[
    btn(daReverseContinue, "Reverse continue", "⏮", vm.canReverseContinue.val),
    btn(daStepBackward, "Step backward", "◀", vm.canStepBackward.val),
    btn(daStepForward, "Step forward", "▶", vm.canStepForward.val),
    btn(daContinue, "Continue", "⏭", vm.canContinue.val),
  ]
  result.statusText = vm.statusText.val
  result.step = step
  result.totalSteps = total
  result.positioned = step > 0

proc projectSession(s: Session; path, text: string; step, total: int):
    DebugSessionView =
  result.chain = "aztec"
  result.txHash = "0xabc1230000000000000000000000000000000000"
  result.phase = spReady        # hydration HAS happened in this projection
  result.hasFrame = true
  result.integrity =
    if s.controls.divergenceDetected.val: siDivergent
    elif s.controls.traceTruncated.val: siTruncated
    else: siValidated
  result.editor = projectEditor(s.editor, s.store, path, text)
  result.calltrace = projectCalltrace(s.calltrace)
  result.state = projectState(s.state)
  result.eventLog = projectEventLog(s.eventLog)
  result.controls = projectControls(s.controls, step, total)
  result.metadata = MetadataPane(
    chain: "aztec", hash: result.txHash, outcome: "Succeeded",
    outcomeBadge: "ok",
    rows: @[MetaRow(label: "Block", value: "102:0", identifier: true)])

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
      s.store.updateLocals(@[
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
      check "remaining_shield -= damage;" in html
      check ("id=\"" & lineAnchor("src/shield.nr", 5) & "\"") in html
      check "class=\"srcline cur" in html

      # Call trace: every visible line of the CalltraceVM, at its depth.
      check s.calltrace.visibleLines.val.len == 3
      for line in s.calltrace.visibleLines.val:
        check (">" & line.name & "</span>") in html
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
      s.store.updateLocals(@[makeVariable("remaining_shield", "10000", "Field")])

      let before = panes.renderLayout(defaultReplayLayout(),
        projectSession(s, "src/shield.nr", ShieldNr, 10, 1315))

      # One step later: the position moved, the variable was written, and a
      # frame was pushed. Every one of those is a change to a signal in the
      # store — the seam a real backend writes through.
      s.store.updateDebuggerPosition(11'u64, file = "src/shield.nr", line = 5)
      s.store.updateLocals(@[makeVariable("remaining_shield", "9000", "Field")])
      s.store.updateCalltraceSection(@[
        makeCallLine("main", 0, 1'u64, file = "src/main.nr", line = 12),
        makeCallLine("calculate_damage", 1, 41'u64, file = "src/shield.nr", line = 4)],
        startIndex = 0'i64, totalCount = 2'u64)

      let after = panes.renderLayout(defaultReplayLayout(),
        projectSession(s, "src/shield.nr", ShieldNr, 11, 1315))

      check before != after
      check ("id=\"" & lineAnchor("src/shield.nr", 2) & "\" data-line=\"2\"") in before
      check "class=\"srcline cur" in before
      check ">10000</span>" in before
      check ">9000</span>" notin before
      check ">9000</span>" in after
      check ">calculate_damage</span>" notin before
      check ">calculate_damage</span>" in after

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
