## SDK-CONSUMER: the debug route's hydration entry point — the bundle that
## turns a served session into a running one.
##
## ## What this is allowed to do, and what it is not
##
## `Page-Descriptions.md` §7.0: "If wasm, workers or range requests fail,
## hydration does not happen and the visitor is already looking at the page that
## fallback would have produced. **No state renders less than the pre-hydration
## page.**"
##
## Read as an instruction to this file, that is one rule with teeth: **nothing
## here removes anything until the thing that replaces it exists.** Every DOM
## write below happens after a success, never before an attempt — the panes are
## rewritten when a live session has produced their contents, the controls are
## enabled when the engine has answered, and the phase rail advances when a
## phase has actually completed. There is no path that blanks a pane, no
## skeleton, and no "loading" state that replaces content the server already
## rendered. A hydration that dies halfway leaves a correct page behind it.
##
## The inverse is equally load-bearing and easier to get wrong: when the engine
## CANNOT load, the controls must stop saying they are waiting for it. The
## served page's buttons read "inert until the replay engine loads", which is
## true while it is coming and a lie once we know it is not. `settle` below is
## what changes that sentence, and it is the only place the honest-failure text
## is written.
##
## ## Why the panes are re-rendered rather than patched
##
## Every pane update calls the SAME renderer `static_export.nim` called — this
## bundle links `client/src/components/debugger.nim` itself. So the hydrated
## markup is the served markup by construction, not by review: there is no
## second implementation of a source line, a call frame or an event row that
## could drift from the one a crawler sees. That is worth more here than the
## bytes a surgical patch would save, and it is why the pane renderers were
## made reachable from a browser build at all (see the import note in
## `components/debugger.nim`).
##
## ## Facade only
##
## The only import from the CodeTracer side is `codetracer_embed`
## (CodeTracer-Embed-SDK.md §7), and it is reached through `session_project`,
## which owns the projection.

when not defined(js):
  {.error: "hydrate is the browser bundle; it is built with `nim js`.".}

import std/[dom, json, strutils]

import isonim/core/async_compat
import codetracer_embed

import ../src/debugger/replay_engine
import ../src/debugger/session_view
import ../src/debugger/source_document
import ../src/debugger/source_island
import ../src/components/debugger as panes

import ./engine_transport
import ./session_project

# ---------------------------------------------------------------------------
# The served page, as this bundle reads it
# ---------------------------------------------------------------------------

const
  VfsTraceFolder = "trace"
  VfsTracePath = VfsTraceFolder & "/trace.ct"
    ## Where the container is written inside the worker's VFS, and the folder
    ## `launch` is then pointed at.
    ##
    ## `TraceSource.httpRangeTrace` and the other three non-folder kinds are
    ## refused by name by the engine today (`dap_dialect.md` §6), so the
    ## working shape is the one its own e2e suite uses: write the bytes into
    ## the VFS out of band, then `launch` with `{"traceFolder": "trace"}`. The
    ## two constants are derived from one another because they must agree —
    ## a launch pointed at a folder nothing was written to fails with a
    ## "not found" the taxonomy would report as `TraceUnavailable`, which
    ## would be a true sentence about a false situation.

  EngineDeadlineMs = 45_000
    ## How long the engine has to become ready before hydration says it will
    ## not. See the watchdog in `hydrate` for why there is one at all.

type
  Ui = object
    ## The elements hydration writes to, resolved once.
    ##
    ## Held rather than re-queried per update because a `querySelector` per
    ## pane per step is main-thread work inside the 16 ms Debugger-Integration
    ## §7 allows for a whole navigation, and because a lookup that can fail is
    ## better made once, at a point where failing means "do not hydrate", than
    ## on every step, where it would mean "silently skip a pane".
    root: Element
    controls: Element      ## `.dbgctl` — the toolbar and the phase rail
    editor: Element        ## `#pane-editor .panebody`
    calltrace: Element
    state: Element
    eventLog: Element
    island: string         ## the inlined source bundle

proc closestFrom(ev: Event; selector: cstring): Element {.importjs: """
(function(e, s){
  var t = e.target;
  if (!t) return null;
  // A click lands on whatever node is under the pointer, which for a row of
  // text is the TEXT node. `closest` is an Element method, so the walk starts
  // at the nearest element — without this, every click on a frame's NAME (the
  // most likely place to click a frame) would miss its row.
  if (t.nodeType !== 1) t = t.parentElement;
  return t ? t.closest(s) : null;
})(#, #)
""".}
  ## The clicked element's nearest ancestor matching `selector`, or `nil`.
  ##
  ## Not in `std/dom`, and it is what makes one listener per pane possible
  ## instead of one per row — see `bindGestures` for why that distinction is
  ## load-bearing rather than tidy.

proc documentIsLoading(): bool {.importjs:
  "(document.readyState === 'loading')".}

proc paneBody(root: Element; id: cstring): Element =
  let pane = root.querySelector(id)
  if pane == nil: nil else: pane.querySelector(".panebody")

proc readUi(): Ui =
  ## Everything the bundle needs from the served document, or a `root` of `nil`.
  ##
  ## A missing element is not defended against later: it is grounds for not
  ## hydrating at all. The served page either has this shape or it is not the
  ## debug route, and a hydration that pressed on with three of five panes
  ## would produce precisely the mixed state §7.0 rules out — some panes live,
  ## some frozen at the served frame, and nothing on the page saying which.
  result.root = document.querySelector(".dbg")
  if result.root == nil: return
  result.controls = result.root.querySelector(".dbgctl")
  result.editor = paneBody(result.root, "#pane-editor")
  result.calltrace = paneBody(result.root, "#pane-calltrace")
  result.state = paneBody(result.root, "#pane-state")
  result.eventLog = paneBody(result.root, "#pane-eventlog")
  let island = document.getElementById(SourceIslandId.cstring)
  if island != nil: result.island = $island.textContent
  if result.controls == nil or result.editor == nil or
     result.calltrace == nil or result.state == nil or result.eventLog == nil:
    result.root = nil

proc attr(e: Element; name: cstring): string =
  let v = e.getAttribute(name)
  if v == nil: "" else: $v

proc intAttr(e: Element; name: cstring): int =
  try: parseInt(attr(e, name).strip()) except CatchableError: 0

# ---------------------------------------------------------------------------
# Writing the panes
# ---------------------------------------------------------------------------

proc replaceWith(e: Element; html: cstring) {.importjs: "#.outerHTML = #".}

proc setRail(ui: Ui; view: DebugSessionView) =
  ## Advance the phase — the root attribute and the rail, and NOTHING else.
  ##
  ## This used to rewrite the whole of `.dbgctl`, which is the toolbar AND the
  ## rail, from a `DebugSessionView` that only carried a phase. The eight
  ## buttons had no entry in it, so advancing from `fetching` to `opening`
  ## DELETED THE TOOLBAR — and then the engine failed to open the container and
  ## the page sat there, honest about its phase, with no stepping controls at
  ## all. That is precisely the §7.0 violation this whole file is written to
  ## avoid, produced by the code meant to avoid it, and it was invisible in
  ## every state except the one where the engine is slow.
  ##
  ## So the rule is now structural rather than remembered: the two writes are
  ## two procs, and the one that runs during loading cannot reach a button.
  ui.root.setAttribute("data-session-phase", ($view.phase).cstring)
  let rail = ui.controls.querySelector(".phaserail")
  if rail == nil: return
  let html = panes.renderPhaseRail(view)
  if html.len == 0:
    # The engine is live; the rail has nothing left to say and goes.
    if rail.parentNode != nil: rail.parentNode.removeChild(rail)
  else:
    rail.replaceWith(html.cstring)

proc setControls(ui: Ui; view: DebugSessionView) =
  ## The toolbar itself, replaced from a view that HAS buttons.
  ##
  ## Only ever called with a projection off the live ViewModels, which is the
  ## only kind of view that can populate all eight.
  let dc = ui.controls.querySelector(".dc")
  if dc == nil: return
  dc.replaceWith(panes.renderControls(view.controls).cstring)
  setRail(ui, view)

proc markRailNavigable(ui: Ui) =
  ## The rail's segments become controls once there is an engine behind them.
  ##
  ## Re-applied after every render rather than once in `bindGestures`, because
  ## the rail is re-rendered with the pane and a role set on the old element is
  ## gone with it. That is the opposite decision from the click LISTENER, which
  ## is delegated exactly so it survives — a role is a property of the node and
  ## a listener does not have to be.
  for seg in ui.editor.querySelectorAll(".frseg"):
    seg.setAttribute("role", "button")
    seg.setAttribute("tabindex", "0")

proc scrollToCurrentLine(ui: Ui) =
  ## Bring the session's line into view after the source pane is rewritten.
  ##
  ## `pages/debug.nim` solves this at export time by opening the document AT
  ## the position, because "there is no JavaScript on this page to scroll it
  ## with". There is now, so the window can stay generous and the pane can be
  ## moved instead — which is the better behaviour for a reader who has
  ## scrolled away and then stepped.
  let cur = ui.editor.querySelector(".srcline.cur")
  if cur != nil: cur.scrollIntoView()

type
  PaneLatch = object
    ## Which panes the live session has ever had content for.
    ##
    ## This is §7.0's guarantee reduced to four bits, and it exists because the
    ## obvious implementation violates the guarantee within a second of going
    ## live. The engine answers `initialize`/`launch` long before it has
    ## produced a call-trace section or a set of locals, so a hydration that
    ## rendered every pane the moment it went ready replaced four FULL served
    ## panes — real values, a real call trace, a real positioned listing — with
    ## four empty ones, and then filled them back in over the next second. That
    ## is "renders less than the pre-hydration page", for a second, on every
    ## visit. It was measured in a browser, not reasoned about.
    ##
    ## The rule: a served pane is replaced only by a pane that has something in
    ## it. Once a pane HAS gone live, it stays live and may legitimately become
    ## empty — a step to a frame with no locals is a true empty Values pane,
    ## and freezing the previous frame's values there would be the worse lie.
    ## So this latches once and never resets.
    editor, calltrace, state, eventLog: bool

proc writePane(target: Element; html: string; hasContent: bool;
               latch: var bool) =
  ## Write a pane if it has content, or if it has had content before.
  if not hasContent and not latch: return
  latch = true
  target.innerHTML = html.cstring

proc renderPanes(ui: Ui; view: DebugSessionView; latch: var PaneLatch) =
  ## The four replay panes and the controls, from the renderers the static
  ## export used.
  ##
  ## The source pane is windowed with the same lead-in the served page used, so
  ## a hydrated frame and a served frame at the same position are the same
  ## markup. That equality is not decoration: it is what makes "hydrate over
  ## it" true rather than "replace it with something similar".
  var view = view
  view.editor = openAtCurrent(view.editor, SourceLeadIn)
  # "Content" for the source pane is not "documents" — a pane that has resolved
  # to `srcUnverified` has no documents and IS the honest §14 row, so it counts
  # as something to say. What must never replace a served listing is a pane
  # that has resolved to nothing at all.
  writePane(ui.editor, panes.renderSource(view.editor),
            view.editor.documents.len > 0 or view.editor.reason.len > 0,
            latch.editor)
  writePane(ui.calltrace, panes.renderCallTrace(view.calltrace),
            view.calltrace.frames.len > 0, latch.calltrace)
  writePane(ui.state, panes.renderState(view.state),
            view.state.values.len > 0, latch.state)
  writePane(ui.eventLog, panes.renderEventLog(view.eventLog),
            view.eventLog.rows.len > 0, latch.eventLog)
  setControls(ui, view)
  markRailNavigable(ui)
  scrollToCurrentLine(ui)

proc markUnavailable(ui: Ui; reason: string) =
  ## The engine will not load, and the controls stop implying it might.
  ##
  ## This is the honest-failure path §14 requires — "a terminal state with a
  ## reason, never a retry that cannot succeed". Every button keeps its inert
  ## rendering and swaps the sentence that explains it: from "inert until the
  ## replay engine loads", which promises an arrival, to what actually
  ## happened. Nothing is removed, nothing is added, and the ladder's surviving
  ## rungs — the container download in the identity bar, and the static call
  ## and event summary that is this whole page — are already on screen.
  ##
  ## The phase rail goes, because it names a sequence that is not running. A
  ## rail still pointing at "Fetching" beside a control that says the engine
  ## cannot start is the page contradicting itself.
  for b in ui.controls.querySelectorAll(".dcbtn"):
    b.setAttribute("title", reason.cstring)
    b.setAttribute("aria-label", reason.cstring)
  let rail = ui.controls.querySelector(".phaserail")
  if rail != nil and rail.parentNode != nil:
    rail.parentNode.removeChild(rail)
  let status = ui.controls.querySelector(".dcphase")
  if status != nil: status.textContent = "Engine unavailable".cstring
  ui.root.setAttribute("data-session-phase", ($spFetching).cstring)
  ui.root.setAttribute("data-engine-unavailable", reason.cstring)

# ---------------------------------------------------------------------------
# §13 — the copy affordance, upgraded
# ---------------------------------------------------------------------------

proc bindCopy(e: Element; value: string) =
  e.setAttribute("role", "button")
  e.setAttribute("tabindex", "0")
  e.setAttribute("title", ("Copy " & value).cstring)
  e.classList.add("copybtn")
  e.addEventListener("click", proc(ev: Event) =
    ev.preventDefault()
    writeClipboard(value, proc(ok: bool) =
      # The result is SHOWN, both ways. `writeText` rejects in a non-secure
      # context and when the document is not focused, and a copy control that
      # silently failed would be the affordance-that-lies defect wearing a
      # tick.
      e.classList.add(if ok: "copied".cstring else: "copyfailed".cstring)))

proc upgradeCopyAffordances(root: Element) =
  ## §13: "a true one-click copy button arrives with hydration, because
  ## writing to the clipboard needs script and this route ships none."
  ##
  ## Two populations, staged exactly as §7.1 stages them:
  ##
  ##   * `[data-copy]` — values rendered TRUNCATED, which were never offered as
  ##     copyable because selecting `0xa45907…9296` yields something that is
  ##     not the value. The attribute carries the full string, and it exists
  ##     for precisely this moment.
  ##   * `.copyable` — values rendered IN FULL, whose pre-hydration affordance
  ##     is `user-select: all`. The button is added; the `user-select` stays,
  ##     so the gesture that already worked keeps working.
  ##
  ## Nothing happens at all without a clipboard API. That is the §13 staging
  ## rule applied one level down: the button "arrives with hydration" only
  ## where hydration can honour it, and in a browser without
  ## `navigator.clipboard` the visitor keeps the select-all affordance rather
  ## than gaining a control that cannot succeed.
  if not hasClipboard(): return
  for e in root.querySelectorAll("[data-copy]"):
    let full = attr(e, "data-copy")
    if full.len > 0: bindCopy(e, full)
  for e in root.querySelectorAll(".copyable"):
    let text = $e.textContent
    if text.len > 0: bindCopy(e, text)

# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------

type
  Hydration = ref object
    ## The live session and everything that writes to the page for it.
    ##
    ## A `ref` because every callback below closes over it and the worker's
    ## messages arrive over the lifetime of the document.
    ui: Ui
    backend: WorkerBackend
    service: BackendService
    session: LiveSession
    base: DebugSessionView   ## the served frame's non-engine facts
    started: bool            ## the DAP handshake has been issued
    live: bool               ## the engine has answered and the panes are live
    latch: PaneLatch         ## which panes the live session has ever filled

proc render(h: Hydration) =
  renderPanes(h.ui, projectReplayPanes(h.session, h.base, h.ui.island), h.latch)

proc fail(h: Hydration; reason: string) =
  ## Give up, and say so on the controls.
  ##
  ## Idempotent through `h.live`: several failures can arrive for one cause —
  ## a worker error, then every pending request settling failed — and the
  ## visitor must be told once. Once the session HAS gone live, a later failure
  ## does not roll the panes back to the served frame: they hold the last
  ## position the engine reached, which is a real frame of this trace and is
  ## strictly more than the pre-hydration page had.
  if h.live:
    for b in h.ui.controls.querySelectorAll(".dcbtn"):
      b.classList.add("off")
      b.setAttribute("aria-disabled", "true")
      b.setAttribute("title", reason.cstring)
    return
  markUnavailable(h.ui, reason)

proc applyStop(h: Hydration; ticks: uint64; file: string; line: int) =
  ## One stop: the store's position, the URL's coordinate, and the panes.
  ##
  ## The store is the seam — everything the five ViewModels expose is a memo
  ## over it, so writing the position here is what moves the source pane, the
  ## call trace's auto-loaded section and the values, in that one call. This is
  ## the same entry point `MockBackendService` drives in `tests/tdebugpanes
  ## .nim`, which is why that suite is evidence about this path.
  h.session.applyPosition(ticks, file, line)
  # §6.3: "`t` updates on **every** navigation via `history.replaceState`".
  # The COORDINATE, so a share link from a hydrated session lands where the
  # session is rather than where it was served.
  replaceQuery("?t=" & $ticks)
  h.render()

proc requestPosition(h: Hydration) =
  ## Ask where the session is, and apply it.
  ##
  ## `stackTrace` rather than reading the `stopped` event's body: DAP's
  ## `stopped` carries a reason and a thread, not a location, and the engine's
  ## `ct/complete-move` carries a tick without a resolved source position. The
  ## frame is the one place both are stated together, and it is what the
  ## engine's own e2e suite reads after every step.
  h.service.send("stackTrace", %*{"threadId": 1}).onComplete(
    onSuccess = proc(response: JsonNode) =
      if not response{"success"}.getBool(true):
        # A refused `stackTrace` is not fatal — the previous frame is still a
        # true frame — so the panes are left where they are and the toolbar
        # keeps working. Silence here would be wrong; a rollback would be
        # worse.
        return
      let frames = response{"body"}{"stackFrames"}
      if frames == nil or frames.kind != JArray or frames.len == 0: return
      let top = frames[0]
      # The tick is NOT on a DAP stack frame. `ct/complete-move` is where the
      # engine states it, so this path keeps whatever tick the session already
      # had rather than inventing a zero — which is what it did, and it put
      # `?t=0` in the URL of a session sitting at step 128.
      h.applyStop(h.session.store.debugger.val.rrTicks,
                  top{"source"}{"path"}.getStr(""),
                  top{"line"}.getInt(0)),
    onError = proc(message: string) = h.fail(
      "The replay engine stopped answering: " & message))

proc onDapEvent(h: Hydration; event: JsonNode) =
  ## The unsolicited half.
  ##
  ## `ReplayDataStore` installs exactly one backend event handler and it keys
  ## on `event["kind"]` for three CodeTracer-internal kinds; a DAP `stopped`
  ## reaches nothing. So the host owns this, which is what
  ## `DebuggerSession.recordPosition`'s own contract says: event delivery is
  ## the embedder's.
  let name = event{"event"}.getStr(event{"command"}.getStr(""))
  case name
  of "ct/complete-move":
    # The engine states the whole position here: `body.location` is its own
    # `Location`, which carries `rrTicks` alongside `path` and `line`. That is
    # strictly better than asking for a stack frame afterwards — it is one
    # message instead of a round trip (Debugger-Integration §7 gives a whole
    # navigation 50 ms), and a DAP stack frame has no tick on it at all, so a
    # session positioned from `stackTrace` reports `?t=0` for every step it
    # ever takes. It did.
    let body = (if event.hasKey("body"): event["body"] else: event)
    let loc = body{"location"}
    if loc == nil or loc.kind != JObject: return
    h.applyStop(uint64(max(0, loc{"rrTicks"}.getInt(0))),
                loc{"path"}.getStr(""), loc{"line"}.getInt(0))
  of "stopped":
    # DAP's own stop event carries a reason and a thread and no location, so
    # the position has to be asked for. Kept as the fallback rather than the
    # primary: an engine that emits `stopped` without a `ct/complete-move`
    # still moves the panes, at the cost of the round trip and of holding the
    # previous tick.
    h.requestPosition()
  else:
    discard

proc invoke(h: Hydration; action: DebugAction) =
  ## A toolbar button, through the ViewModel that owns the move.
  ##
  ## `invokeToolbarStep` and not a hand-built DAP request: the VM is what knows
  ## the command spelling for each direction, and it is what
  ## `tests/tdebugpanes.nim` exercises. A second mapping in this file would be
  ## the "two producers" failure applied to the one surface where being wrong
  ## means stepping the wrong way.
  h.session.controls.invokeToolbarStep(toolbarActionId(action))

proc gotoTicks(h: Hydration; ticks: int) =
  ## A row in the navigation region, clicked.
  ##
  ## Debugger-Integration §3's deferred item, and §4.2's "single most valuable
  ## interaction in the product — 'take me to the line that wrote this
  ## value'". `ct/goto-ticks` is the engine's own primitive for it and it emits
  ## a `ct/complete-move` for the target tick, so the position arrives back
  ## through the same event path a step does. No new protocol, exactly as §3
  ## says none is needed.
  h.service.send("ct/goto-ticks", %*{"threadId": 1, "ticks": ticks}).onComplete(
    onSuccess = proc(response: JsonNode) =
      if not response{"success"}.getBool(true):
        # The engine refused the jump. Nothing moves and nothing pretends to;
        # the row stays a row and the session stays where it was.
        return,
    onError = proc(message: string) = h.fail(
      "The replay engine stopped answering: " & message))

proc bindGestures(h: Hydration) =
  ## The controls and the navigation rows become real, once.
  ##
  ## Bound on the pane BODIES and not on the rows, because `renderPanes`
  ## replaces the rows' markup on every stop and a per-row listener would be
  ## dropped with it — rebinding after each render would then be a per-step
  ## cost inside §7's 16 ms, and a forgotten one would leave rows that had
  ## silently stopped responding. Delegation binds once and survives every
  ## re-render.
  ##
  ## The toolbar reads `data-action`, which is the enum's own wire spelling,
  ## rather than matching a label — a toolbar whose behaviour depended on its
  ## wording would break on the first rename.
  proc rowHandler(container: Element; selector: cstring) =
    container.addEventListener("click", proc(ev: Event) =
      let row = closestFrom(ev, selector)
      if row == nil: return
      let step = attr(row, "data-step")
      if step.len == 0: return
      try: h.gotoTicks(parseInt(step)) except CatchableError: discard)

  h.ui.controls.addEventListener("click", proc(ev: Event) =
    let btn = closestFrom(ev, ".dcbtn")
    if btn == nil: return
    if btn.classList.contains("off"): return
    let wire = attr(btn, "data-action")
    for a in DebugAction:
      if $a == wire: h.invoke(a))

  rowHandler(h.ui.calltrace, ".ctrow")
  rowHandler(h.ui.eventLog, ".evrow")
  # The loop rail's segments, through the SAME primitive. A segment's
  # `data-step` is its pass's loop-header tick, so "show me pass 6" is
  # `ct/goto-ticks` at that tick and needs no protocol of its own — which is
  # `Omniscience-Flow.md`'s `SimpleLoopIterationJump` ("enter iteration number,
  # verify cursor") reached with one line rather than a slider widget.
  #
  # Bound on the EDITOR pane's body and not on the rail, because `renderPanes`
  # replaces the whole body on every stop and the rail with it; a listener on
  # the rail would be dropped by the first step it took.
  rowHandler(h.ui.editor, ".frseg")
  # The rows are now controls, so they say so — but only NOW. The served
  # markup deliberately carries no role and no tabindex, because §3's reason
  # for deferring these was that "an affordance that cannot act is the defect
  # this route has already removed twice".
  for row in h.ui.calltrace.querySelectorAll(".ctrow"):
    row.setAttribute("role", "button")
    row.setAttribute("tabindex", "0")
  for row in h.ui.eventLog.querySelectorAll(".evrow"):
    row.setAttribute("role", "button")
    row.setAttribute("tabindex", "0")
  h.ui.root.setAttribute("data-rows-navigable", "true")

# ---------------------------------------------------------------------------
# The bootstrap sequence
# ---------------------------------------------------------------------------

proc goLive(h: Hydration) =
  ## The engine has answered and the session is positioned.
  ##
  ## This is the ONLY place `spReady` is produced anywhere in the product —
  ## `session_view.SessionPhase` says so of `spReady` ("Only hydration produces
  ## this, so no statically exported page carries it") and this line is what
  ## makes that true.
  h.live = true
  h.bindGestures()
  # The CONTROLS only. Not the panes: at this instant the engine has answered
  # `threads` and has not yet produced a call trace, a set of locals or a
  # position, so every pane projection is empty and rendering them would blank
  # four full served panes. `renderPanes`'s latch would refuse most of that
  # anyway; not asking is clearer than being refused.
  #
  # The panes arrive on the first `ct/complete-move`, which is a real frame.
  setControls(h.ui,
              projectReplayPanes(h.session, h.base, h.ui.island))

proc handshake(h: Hydration) =
  ## DAP: initialize → launch → configurationDone, then the first position.
  ##
  ## This order and not `DebuggerSession.launch`'s `initialize →
  ## configurationDone → launch`. Both work against an engine that was made
  ## order-independent, and this is the one its own WASM e2e suite drives, so
  ## it is the one with evidence behind it against the published bundle. When
  ## the engine's order-independence is verified against the DEPLOYED wasm,
  ## this can become `session.launch` and lose a dozen lines.
  if h.started: return
  h.started = true
  proc step(command: string; args: JsonNode; next: proc()) =
    h.service.send(command, args).onComplete(
      onSuccess = proc(response: JsonNode) =
        if not response{"success"}.getBool(true):
          # The §6.3 taxonomy, from the SDK's own classifier rather than from a
          # string match here — a consumer "must be able to distinguish 'this
          # trace does not exist' from 'the worker died' without string
          # matching", and doing it twice would be one place for the two
          # answers to differ.
          h.fail("The trace could not be opened (" &
                 $classifyBackendFailure(response) & ").")
          return
        next(),
      onError = proc(message: string) =
        h.fail("The replay engine failed to start: " & message))

  step("initialize", %*{
    "clientID": "blocktracer",
    "adapterID": "codetracer",
    "supportsProgressReporting": false,
  }, proc() =
    step("launch", %*{"traceFolder": VfsTraceFolder}, proc() =
      step("configurationDone", newJObject(), proc() =
        # `positioning` is a phase the visitor sees, briefly and truthfully:
        # the container is open and the session is being seeked to the frame
        # the URL asked for. §8 requires the three phases to be named; this is
        # the third arriving on its own account rather than as decoration.
        var positioning = h.base
        positioning.phase = spPositioning
        setRail(h.ui, positioning)
        h.service.send("threads", newJObject()).onComplete(
          onSuccess = proc(_: JsonNode) =
            h.goLive()
            h.requestPosition(),
          onError = proc(message: string) =
            h.fail("The replay engine failed to start: " & message)))))

proc onControl(h: Hydration; message: JsonNode) =
  ## The worker's own bootstrap traffic — everything that is not a DAP frame.
  ##
  ## Kept on `onControl` and off `onEvent` deliberately: a `vfs-ack` delivered
  ## as a DAP event reaches `dapCommandToEventKind`, which raises, and the
  ## raise kills every subsequent reactive effect in the session.
  ## `WorkerBackend` separates the two channels for exactly this, and the
  ## separation only helps if the consumer keeps it.
  case message{"type"}.getStr("")
  of "wasm-loaded":
    # The engine is compiled. Now the container — 144 KB, same origin, one
    # request, issued BY THE WORKER. `fetching` is still the honest phase until
    # the bytes are in, and it is still the phase the served page was showing,
    # so nothing on screen changes for a state that has not changed.
    postJson(loadTraceMessage(absoluteUrl(attr(h.ui.root, "data-trace")),
                              VfsTracePath))
  of "trace-loaded":
    var opening = h.base
    opening.phase = spOpening
    setRail(h.ui, opening)
    postJson("""{"type":"start"}""")
  of "trace-load-error":
    h.fail("The trace container could not be opened: " &
           message{"error"}.getStr("no reason given"))
  of "worker-status":
    if message{"status"}.getStr("") == "ready": h.handshake()
  of "worker-error":
    h.fail("The replay engine stopped: " &
           message{"error"}.getStr("no reason given"))
  else:
    discard

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

proc servedFrame(ui: Ui): DebugSessionView =
  ## The facts hydration inherits from the served page rather than restating.
  ##
  ## Only what the projection reads. The metadata pane, the identity bar and
  ## the banner are NOT rebuilt from anything here — §7.1 requires those facts
  ## to come "from one source", and this bundle is not it. They stay exactly as
  ## served, which is also why hydration cannot make them wrong.
  result.engineBase = ReplayEngineBase
  result.engineCrossOrigin = replayEngineIsCrossOrigin()
  result.engineBytes = ReplayEngineWasmBytes
  result.hasFrame = true
  result.phase = spFetching
  result.controls.totalSteps = intAttr(ui.root, "data-total-steps")
  result.controls.step = intAttr(ui.root, "data-step")

proc hydrate() =
  let ui = readUi()
  if ui.root == nil: return

  # §13's copy buttons first, and unconditionally. They need no engine, no
  # worker and no wasm, so a browser that can run none of those still gains
  # them — which is the capability ladder's whole shape applied one rung down.
  upgradeCopyAffordances(ui.root)

  # §14.2's detection half, before a byte is fetched.
  let capability = detectCapability()
  if capability != ecReady:
    markUnavailable(ui, capabilityReason(capability))
    return

  # No published container is not a failure — it is §7.0's `absent` row, which
  # this page already renders correctly and which offers no debugger and no
  # pretence of one. There is nothing to say and nothing to change.
  let traceUrl = attr(ui.root, "data-trace")
  if traceUrl.len == 0: return

  let h = Hydration(ui: ui, base: servedFrame(ui))
  h.backend = newWorkerBackend(
    postProc = proc(messageJson: string) = postJson(messageJson),
    terminateProc = proc() = terminateWorker())
  h.backend.onControl(proc(message: JsonNode) = h.onControl(message))
  h.backend.onEvent(proc(event: JsonNode) = h.onDapEvent(event))
  h.service = h.backend.toBackendService()
  h.session = openLiveSession(h.service, sourceIsPublished = ui.island.len > 0)

  # §8 forbids an indeterminate wait, and a phase rail stuck on `opening` is
  # one — it is a spinner with a name. Not every engine failure arrives as a
  # message: the deployed engine logs its container-format refusal to the
  # WORKER's console and posts nothing, so `configurationDone` answers success,
  # the next request is dropped with "no handler yet", and the session sits in
  # `positioning` for as long as the tab is open. That is exactly the state a
  # visitor cannot tell from a slow connection, so it gets a deadline.
  #
  # Generous, because the deadline it must not trip is a cold fetch of an 18 MB
  # wasm on a slow link — that is a legitimate wait, not a failure, and cutting
  # it short would report a broken engine to someone whose engine was merely
  # arriving. Debugger-Integration §7's 3 s p75 budget is the target; this is
  # the point past which something is wrong rather than slow.
  afterMs(EngineDeadlineMs, proc() =
    if not h.live:
      h.fail("The replay engine did not become ready. The trace could not be " &
             "opened in this browser; the container can still be downloaded " &
             "and opened in CodeTracer."))

  if not startWorker(ReplayEngineBase & "worker.js",
                     proc(raw: string) = h.backend.deliver(raw)):
    # A synchronous construction failure — in practice §5.1's cross-origin
    # `SecurityError`. The URL is in the message the transport built, and it is
    # already on the page as `data-replay-engine`, so a reader can see which
    # origin this build asked for.
    h.fail("The replay engine could not be started from " & ReplayEngineBase &
           ". Its worker must be served from this site's own origin.")

when isMainModule:
  # The bundle is `defer`red, so the document is parsed by the time this runs
  # and there is nothing to wait for. Guarded anyway, because a build that
  # loses the `defer` would otherwise fail by finding no `.dbg` and doing
  # nothing at all — a silent no-op is the one failure mode that would look
  # exactly like success.
  if documentIsLoading():
    document.addEventListener("DOMContentLoaded", proc(ev: Event) = hydrate())
  else:
    hydrate()
