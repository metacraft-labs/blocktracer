## SDK-CONSUMER: the ONE projection from CodeTracer's ViewModels onto the pane
## types the debug route renders.
##
## ## Why this is here and not in `client/src`
##
## Everything under `client/src` compiles with isonim and nim-everywhere on the
## Nim path and nothing else — that is what `static_export.nim` is, and the
## property is load-bearing rather than incidental (`AGENTS.md` §1a: "Everything
## else compiles with no debugger on the Nim path at all — that is the layering,
## not a comment about it"). This module imports `codetracer_embed`, so it
## belongs on the other side of that line.
##
## `client/hydrate/` is that side: the tree compiled by `nim js` WITH the Embed
## SDK, producing the bundle the debug route defers. It reads `client/src` and
## `client/src` never reads it.
##
## ## Why it is not in the test that used to own it
##
## `tests/tdebugpanes.nim` carried this projection and said of it: "`project*`
## below is deliberately small and deliberately in a test. The shipping adapter
## is `WorkerBackendService` plus a hydration entry point … When the adapter
## lands it replaces these functions and nothing below them."
##
## The adapter has landed, so this is that replacement. The suite now imports
## these functions instead of defining its own, which changes what `just
## debug-panes` is evidence FOR: it used to prove that a projection resembling
## the shipping one rendered; it now drives the shipping one. A private copy in
## the test would have made that suite green about code nobody serves — the
## exact failure `ci/test/debug-panes-test.sh` checks for in the other
## direction, on the renderers.
##
## ## Facade only
##
## The single import from the CodeTracer side is `codetracer_embed`
## (CodeTracer-Embed-SDK.md §7). Nothing here reaches an internal module, and
## `ci/test/debug-panes-test.sh` re-checks that against this file's own imports.

import std/[options, strutils]

import codetracer_embed

import ../src/debugger/deeplink_landing
import ../src/debugger/session_view
import ../src/debugger/source_island
export deeplink_landing

# ---------------------------------------------------------------------------
# One store, one backend, five ViewModels
# ---------------------------------------------------------------------------

type
  LiveSession* = object
    ## The five ViewModels of one session, plus the store they all read.
    ##
    ## An object of handles and not a `ref` with behaviour: the projection is a
    ## pure function of these, and giving it a lifecycle would create a second
    ## place where "what the panes show" is decided.
    store*: ReplayDataStore
    editor*: EditorVM
    calltrace*: CalltraceVM
    state*: StateVM
    eventLog*: EventLogVM
    controls*: DebugControlsVM
    flow*: FlowVM
      ## The sixth, and it is not one of the five panes.
      ##
      ## `FlowVM` is what issues `ct/load-flow` on every debugger move and
      ## consumes the queued `ct/updated-flow` EVENT the engine answers with —
      ## which is the hazard `Omniscience-Flow.md` records by name: a consumer
      ## that read only the reply stays permanently empty against the real
      ## engine while every mock-driven test passes. Using the SDK's own applier
      ## rather than parsing that payload here is the point. It is the code
      ## written against the engine by the people who wrote the engine, and its
      ## answer to "which pass is the debugger inside" is the one issue #593 was
      ## filed and fixed on.

const
  CalltraceViewportRows* = 64
    ## How many call-trace rows the session asks the engine for.
    ##
    ## `CalltraceVM`'s auto-load effect issues `ct/load-calltrace-section` with
    ## the VIEWPORT's height, and the viewport defaults to zero — a session
    ## that never sets it asks for a section of no rows and renders an empty
    ## pane while the engine is working perfectly. A web pane has no measured
    ## height (there is no resize observer on this route, by design), so a
    ## generous constant is the honest stand-in: it over-fetches a little and
    ## cannot under-fetch into a blank pane.

  EventLogPageRows* = 50
    ## `EventLogVM`'s own `DEFAULT_PAGE_SIZE`, restated so the page the
    ## projection slices is a decision this consumer made rather than one it
    ## inherited silently.

proc openLiveSession*(backend: BackendService; sourceIsPublished: bool):
    LiveSession =
  ## The five ViewModels over one store over one backend.
  ##
  ## The backend is a parameter and not a constructed `WorkerBackendService`,
  ## because that is what makes this the same code in the browser and under
  ## `MockBackendService` in `tests/tdebugpanes.nim`. A projection that could
  ## only be exercised against a live worker would be a projection nobody could
  ## test without an 18 MB download.
  ##
  ## Three things are set here that a session which did not set them would get
  ## wrong QUIETLY — each was found by driving the real engine:
  ##
  ##   * `completedReplay`. `canStepBackward` reads the session mode, and the
  ##     default is not it. A replay of a published container is completed by
  ##     definition — there is no recording head to track — and a toolbar whose
  ##     reverse half is disabled on this route would remove the product's
  ##     premise.
  ##   * the calltrace viewport. See `CalltraceViewportRows`.
  ##   * the source availability. The ENGINE does not know whether anyone
  ##     published source for this contract; the published data plane does, and
  ##     the page carries its answer as the source island. So the caller passes
  ##     what the page knows, and `projectEditor` renders §14's
  ##     "no verified source" row when it is false — instruction-level
  ##     stepping with the supply-sources action, rather than an empty pane.
  let store = createReplayDataStore(backend)
  store.setSessionMode(completedReplay)
  store.setSourceAvailability(
    if sourceIsPublished: savVerified else: savUnverified)
  result = LiveSession(
    store: store,
    editor: createEditorVM(store),
    calltrace: createCalltraceVM(store),
    state: createStateVM(store),
    eventLog: createEventLogVM(store),
    controls: createDebugControlsVM(store),
    flow: createFlowVM(store))
  result.calltrace.setViewportHeight(CalltraceViewportRows)
  result.eventLog.setPageSize(EventLogPageRows)

proc applyPosition*(s: LiveSession; ticks: uint64; file: string; line: int) =
  ## Write a stop into the store: the position, and the status that goes with
  ## having arrived.
  ##
  ## `updateDebuggerPosition` alone is not enough, and the reason is a real
  ## defect this fixed. `requestStep` sets `status = dsStepping` when it issues
  ## the command and — deliberately, because "the host owns event delivery" —
  ## resets it nowhere; `updateDebuggerPosition` PRESERVES the status it finds.
  ## So a session that only called that one stepped exactly once: the position
  ## moved, `status` stayed `dsStepping`, `canStepForward` (which is
  ## `status in {dsIdle}`) went false, and every button in the toolbar went
  ## inert with the served page's "waiting for the engine" tooltip on it.
  ##
  ## A fresh `DebuggerState` rather than a mutated one, for the reason the
  ## store's own setters give: on the JS backend `var x = signal.val` is a
  ## reference, so writing back a mutated copy compares equal to itself and the
  ## signal never fires.
  s.store.updateDebuggerPosition(ticks, file = file, line = line)
  let current = s.store.debugger.val
  s.store.debugger.val = DebuggerState(
    rrTicks: current.rrTicks,
    location: current.location,
    status: dsIdle,
    threadId: current.threadId)

proc close*(s: LiveSession) =
  s.editor.dispose()
  s.calltrace.dispose()
  s.state.dispose()
  s.eventLog.dispose()
  s.controls.dispose()
  s.flow.dispose()
  s.store.dispose()

# ---------------------------------------------------------------------------
# ViewModel state -> the pane types the renderers read
# ---------------------------------------------------------------------------

proc projectEditor*(vm: EditorVM; store: ReplayDataStore;
                    island: string): EditorPane =
  ## Position from the session, text from the published bundle, joined on the
  ## interned path — which is how a real session resolves a step to a line.
  ##
  ## The line comes from the STORE's debugger position, not from
  ## `EditorVM.cursorLine`: the second is the user's caret, which a shell moves
  ## on a click, and the pane's current-line marker has to mean "the step the
  ## session is on". They coincide in a real shell only because the shell sets
  ## the caret when a stop arrives.
  ##
  ## `island` is the inlined source bundle (`source_island.nim`) — the same
  ## bytes the static export rendered from. Passing it in rather than reaching
  ## for the DOM keeps this function callable from a test with no document.
  let position = store.debugger.val.location
  case vm.sourceAvailability.val
  of savVerified:
    if island.len == 0:
      # Verified source, and no bundle to render it from. Not an error and not
      # an empty pane: it is `srcUnverified`'s sentence, which is the honest
      # one — the session can still step, and there is no code to show.
      result.availability = SourceAvailabilityView.srcUnverified
      result.reason = "The source bundle did not reach this page."
    else:
      result = decodeSourceIsland(island, position.file, position.line)
      result.availability = SourceAvailabilityView.srcSourceLevel
      result.currentLine = position.line
  of savUnverified:
    result.availability = SourceAvailabilityView.srcUnverified
    result.reason = "No source bundle is published for the code that ran."
  else:
    result.availability = SourceAvailabilityView.srcAbsent
    result.reason = "This execution ran no contract code."

proc projectFlowRail*(vm: FlowVM; path: string): FlowRail =
  ## The loop-iteration control, from the engine's own flow window.
  ##
  ## ## What crosses, and what deliberately does not
  ##
  ## The RAIL crosses: which loop the debugger is inside, how many passes it
  ## made, which pass this position falls in, and each pass's header tick. All
  ## four come out of `FlowVM`, which parsed them from `ct/updated-flow` with
  ## the SDK's own applier — so none of them is this repository's reading of a
  ## wire format it cannot observe.
  ##
  ## The VALUES do not, and that is a deliberate stop rather than an oversight.
  ## Placing them needs `FlowViewUpdate.steps` — the per-step `beforeValues` and
  ## `afterValues`, each a CodeTracer `Value` — parsed and RENDERED TO TEXT, and
  ## neither the parse nor the rendering can be checked against anything here: a
  ## test written against a payload this repository invented would pass whatever
  ## the engine actually sends, which is the shape of check this project keeps
  ## finding. `FlowVM` does not carry them either (`applyFlowUpdate` populates
  ## the loop shape and the selection and leaves `steps` untouched), so there is
  ## no already-verified path to borrow.
  ##
  ## The consequence is stated rather than hidden: a hydrated session shows the
  ## rail and no inline values until that payload can be read against a live
  ## engine. The served page's values are not frozen onto the moved session in
  ## the meantime — `renderPanes`' own latch documents why ("a step to a frame
  ## with no locals is a true empty Values pane, and freezing the previous
  ## frame's values there would be the worse lie"), and a value from the
  ## position you WERE at is the same lie with a number in it.
  let loops = vm.loops.val
  let focused = vm.focusedLoop.val
  if focused < 0 or focused >= loops.len: return FlowRail(loopIndex: 0)
  let loop = loops[focused]
  if loop.rrTicksForIterations.len == 0: return FlowRail(loopIndex: 0)
  # `registeredLine` is the line the loop control attaches to. A window that did
  # not carry one (the field defaults to -1 in `parseFlowLoop`) gets no rail at
  # all rather than a rail pointing at line -1: the control's whole content is
  # "this loop, here", and half of that is not a control.
  if loop.registeredLine <= 0: return FlowRail(loopIndex: 0)
  result = FlowRail(
    loopIndex: focused,
    line: loop.registeredLine,
    anchor: lineAnchor(path, loop.registeredLine),
    selected: vm.selectedIteration.val,
    active: vm.selectedIteration.val,
    navigable: true,
    iterations: @[])
  for index, ticks in loop.rrTicksForIterations:
    # `reached` is a statement about the STATIC window, which is cut at the
    # served position. A live session can seek to any pass, so it is true here
    # for all of them — and `navigable` is what the renderer actually keys the
    # segment's behaviour on.
    result.iterations.add FlowIteration(
      index: index, ticks: ticks, reached: true)

proc projectCalltrace*(vm: CalltraceVM; contentHash = ""): CallTracePane =
  ## The frames, with the two things that make a row a jump target.
  ##
  ## `contentHash` is the artifact the page is opening — `traceContentHash`,
  ## from the served DOM. It is not decoration on the link: §6.0a requires `t`
  ## to travel with the content witness `c`, so a row link built without it
  ## would be one this product's own reader treats as unverifiable. The hash
  ## therefore reaches the projection rather than the renderer, because the
  ## renderer must not build URLs and the ViewModel does not know it.
  result.costLabel = "ACIR"
  for line in vm.visibleLines.val:
    result.frames.add CallFrame(
      depth: line.depth,
      fn: line.name,
      module: line.location.file,
      cost: $line.rrTicks,
      costUnit: "ticks",
      # The time coordinate the frame starts at — what `data-step` carries into
      # the markup, and what a click on the row hands back to the engine.
      step: int(line.rrTicks),
      current: vm.selectedEntry.val == some(line.index))
  # The anchors first, because the href carries one. Both derived by the shared
  # functions, so a live session's `call:` paths are the static export's.
  withCallAnchors(result)
  for i in 0 ..< result.frames.len:
    result.frames[i].href = positionQuery(
      contentHash, result.frames[i].step, result.frames[i].anchor)

proc projectState*(vm: StateVM): StatePane =
  for v in vm.currentVariables.val:
    result.values.add StateValue(
      name: v.name, typ: v.typeName, value: v.value,
      # `changed` is the pane's "written at this step" marker. The StateVM does
      # not model that yet, so the projection maps it to the VM's own selection
      # rather than inventing a value — a marker that lit up on nothing would
      # be indistinguishable from a correct one.
      changed: vm.selectedPath.val == v.name)

proc kindOf*(row: EventLogRow): EventKind =
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

proc projectEventLog*(vm: EventLogVM; contentHash = ""): EventLogPane =
  ## The page the EventLogVM's paging signals select. The VM owns the rows, the
  ## page index and the page size and exposes no pre-sliced memo, so the slice
  ## is the consumer's — which is the right side of the boundary for it: how
  ## many rows a pane shows is a property of the pane.
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
  # The same staging as the call trace, and the same reason it matters here
  # more: §4.2 calls a click on an event row "the single most valuable
  # interaction in the product — 'take me to the line that wrote this value'".
  # It is the only surface on which an individual storage write is addressable.
  withEventAnchors(result)
  for i in 0 ..< result.rows.len:
    result.rows[i].href = positionQuery(
      contentHash, result.rows[i].step, result.rows[i].anchor)

func toolbarActionId*(a: DebugAction): string =
  ## BlockTracer's `DebugAction` → the `actionId` `DebugControlsVM
  ## .invokeToolbarStep` dispatches on.
  ##
  ## Two vocabularies, and they agree on six of eight. `daStepForward` is DAP's
  ## `next` and `daStepBackward` is CodeTracer's `reverse-next`; the six others
  ## are spelled identically in both. A total `case` rather than a table so
  ## that a control added to the toolbar is a compile error here — an unmapped
  ## action would otherwise reach the VM as an unknown string, be ignored, and
  ## present as a button that is enabled and does nothing, which is the one
  ## failure mode this whole route is built to avoid.
  case a
  of daStepForward: "next"
  of daStepBackward: "reverse-next"
  of daStepIn: "step-in"
  of daStepOut: "step-out"
  of daContinue: "continue"
  of daReverseContinue: "reverse-continue"
  of daReverseStepIn: "reverse-step-in"
  of daReverseStepOut: "reverse-step-out"

proc canDo*(vm: DebugControlsVM; a: DebugAction): bool =
  ## Whether the VM says this move is available right now.
  ##
  ## `DebugControlsVM` derives four capability memos, not eight: forward,
  ## backward, continue and reverse-continue. The four step-in/step-out moves
  ## have no memo of their own and ride on the DIRECTION's — a step-in is
  ## available exactly when forward motion is, and a reverse-step-out exactly
  ## when backward motion is. Deriving them here rather than hard-coding `true`
  ## keeps a control from being offered at a trace boundary, which is where
  ## reverse stepping is known to trap the engine.
  case a
  of daStepForward, daStepIn: vm.canStepForward.val
  of daStepBackward, daReverseStepIn, daReverseStepOut: vm.canStepBackward.val
  of daStepOut: vm.canStepForward.val
  of daContinue: vm.canContinue.val
  of daReverseContinue: vm.canReverseContinue.val

proc projectControls*(vm: DebugControlsVM; step, total: int;
                      live: bool): DebugControlsPane =
  ## The toolbar, in the order `session_view.DebugAction` declares — which is
  ## CodeTracer's desktop order, backward first in each pair.
  ##
  ## `live` is separate from the per-button capability and gates all of them:
  ## before the engine is ready every button is inert whatever the VM's memos
  ## say, because those memos have a value from the moment the store exists and
  ## it is not yet a statement about a running engine.
  proc btn(a: DebugAction; label, glyph: string): ControlButton =
    ControlButton(action: a, label: label, glyph: glyph,
                  enabled: live and canDo(vm, a))
  result.buttons = @[
    btn(daStepBackward, "Step backward", "◀"),
    btn(daStepForward, "Step forward", "▶"),
    btn(daReverseStepIn, "Reverse step in", "⇱"),
    btn(daStepIn, "Step in", "⇲"),
    btn(daReverseStepOut, "Reverse step out", "⇤"),
    btn(daStepOut, "Step out", "⇥"),
    btn(daReverseContinue, "Reverse continue", "⏮"),
    btn(daContinue, "Continue", "⏭"),
  ]
  result.statusText = vm.statusText.val
  result.step = step
  result.totalSteps = total
  result.positioned = step > 0

proc projectReplayPanes*(s: LiveSession; base: DebugSessionView;
                         island: string): DebugSessionView =
  ## The served session, with the five replay panes replaced by the live ones.
  ##
  ## `base` is what the page was SERVED — identity, metadata, integrity,
  ## languages, the container path. Hydration owns none of that and must not
  ## restate it: §7.1 requires the transaction's facts to come "from one
  ## source", and a hydration that rebuilt the metadata pane from the engine
  ## would be a second producer of them, drifting from the crawled page the
  ## moment either changed.
  ##
  ## So this copies `base` and overwrites exactly what the engine owns. That is
  ## also the mechanical form of §7.0's guarantee: there is no field here that
  ## can be made empty by a live session, because every field is either the
  ## served value or a value the engine supplied.
  result = base
  result.phase = spReady
  result.hasFrame = true
  result.editor = projectEditor(s.editor, s.store, island)
  # The rail is attached to the pane, and only where the pane can host one:
  # §14's instruction-level row has no source to point a loop header at, and
  # `flow_view.applyFlow` refuses for the same reason on the static side. One
  # rule, enforced on both producers rather than remembered by both.
  if result.editor.availability == SourceAvailabilityView.srcSourceLevel:
    result.editor.flow =
      projectFlowRail(s.flow, s.store.debugger.val.location.file)
  # `base.traceContentHash` and not a value from the engine: §6.0's witness is
  # a fact about the artifact the PAGE recommends, which the served DOM carries
  # and the engine has no opinion about. Reading it from `base` is also what
  # keeps the rows' links pointing at the same trace the metadata pane
  # describes.
  result.calltrace = projectCalltrace(s.calltrace, base.traceContentHash)
  result.state = projectState(s.state)
  result.eventLog = projectEventLog(s.eventLog, base.traceContentHash)
  result.controls = projectControls(
    s.controls, int(s.store.debugger.val.rrTicks), base.controls.totalSteps,
    live = true)
  result.integrity =
    if s.controls.divergenceDetected.val: siDivergent
    elif s.controls.traceTruncated.val: siTruncated
    else: base.integrity
