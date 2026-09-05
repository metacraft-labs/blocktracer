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
import ../src/debugger/keymap
import ../src/debugger/scrub_queue
import ../src/debugger/source_island
import ../src/components/debugger as panes

import ./engine_transport
import ./live_breakpoints
import ./live_preferences
import ./live_origin
import ./live_source
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

proc isPlainActivation(ev: Event): bool {.importjs: """
(function(e){
  // A left-button click with no modifier. Everything else is the visitor
  // asking the BROWSER for something — a new tab, a new window, a download —
  // and a handler that cancelled those would be a page taking a gesture the
  // platform owns. `button` is undefined on a keyboard-generated click, which
  // is why the test is "not a non-zero button" rather than "button === 0":
  // Enter on a link must take the in-session jump, not a page reload.
  return !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey &&
         !(e.button > 0);
})(#)
""".}

# ── the scrubber drag's five questions of the platform ─────────────────────
#
# Each is one expression wrapped in a function, rather than a bare `#.field`,
# for the reason `isPlainActivation` is written that way: an `importjs` pattern
# consumes one argument per `#`, so a multi-clause test spelled inline silently
# becomes a call with the wrong arity. Wrapping keeps the arity at one.

proc isPrimaryDrag(ev: Event): bool {.importjs: """
(function(e){
  // The left button, unmodified. A right-click opens a menu, a middle-click is
  // the platform's, and a modified drag is a selection — none of them is
  // "take me to this point in the trace", and a handler that swallowed them
  // would be a control taking gestures it was not offered.
  return e.button === 0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey;
})(#)
""".}

proc pointerX(ev: Event): float {.importjs: "(function(e){ return e.clientX; })(#)".}
proc pointerIdOf(ev: Event): int {.importjs: "(function(e){ return e.pointerId; })(#)".}
proc keyName(ev: Event): cstring {.importjs: "(function(e){ return e.key || ''; })(#)".}
  ## `cstring`, and the distinction is not pedantry — it cost this file a
  ## silently dead keyboard. Declared as `string`, Nim wraps the return in
  ## `toJSStr`, which walks its argument as an array of CHARACTER CODES,
  ## because that is what a Nim `string` is on this backend. Handed a real JS
  ## string it compares `"H" < 128`, takes the non-ASCII branch for every
  ## character and produces a value no `case` branch matches. It compiles, it
  ## runs, it throws nothing, and every key falls through to `else`. The
  ## surrounding code already knew this — `attr` returns `cstring` and converts
  ## with `$` — and this proc simply did not follow it.

# ── the modifier bits, for chord matching ──────────────────────────────────
#
# Four separate one-expression procs rather than one that returns a record,
# because `importjs` hands back a JS value and a JS object would arrive as
# something Nim has no type for. Each is wrapped in a function for the arity
# reason stated above `isPrimaryDrag`.
#
# `bool` is safe here where `string` was not: a JS boolean and a Nim `bool` are
# the same value on this backend. It is the STRING case that needs `cstring`,
# which is the whole of `keyName`'s note.

proc shiftHeld(ev: Event): bool {.importjs: "(function(e){ return !!e.shiftKey; })(#)".}
proc ctrlHeld(ev: Event): bool {.importjs: "(function(e){ return !!e.ctrlKey; })(#)".}
proc altHeld(ev: Event): bool {.importjs: "(function(e){ return !!e.altKey; })(#)".}
proc metaHeld(ev: Event): bool {.importjs: "(function(e){ return !!e.metaKey; })(#)".}

proc isRepeat(ev: Event): bool {.importjs: "(function(e){ return !!e.repeat; })(#)".}
  ## Whether this is the OS's auto-repeat rather than a fresh press.
  ##
  ## Held-down keys are refused at the dispatch site. A held `n` would queue
  ## one `next` per repeat interval — tens of engine round trips the visitor
  ## did not ask for, arriving after they let go, with the session ending up
  ## somewhere they cannot account for. The pointer path cannot produce this
  ## and so has never needed the guard; the keyboard path can.

proc isTypingTarget(ev: Event): bool {.importjs: """
(function(e){
  // Is the visitor typing into something?
  //
  // The stepping chords are UNMODIFIED LETTERS, which is only safe while no
  // focused element wants letters.
  //
  // WHAT IS ACTUALLY ON THIS ROUTE, measured rather than assumed. This comment
  // used to say `components/nav.nim` puts a site-wide search box "on every page
  // including this one". IT DOES NOT: the debug route renders its own chrome
  // and no site nav, and the built page contains ZERO input elements — checked
  // against `client/dist/.../debug/index.html`, which has none, while
  // `dist/index.html` has two. The claim was wrong and would have sent the next
  // person looking for a box that is not there.
  //
  // The guard is kept, and on narrower grounds that are true:
  //
  //   * the listener is on `document`, so it sees every keystroke on the page
  //     regardless of what rendered the focused element;
  //   * the shortcuts dialog itself renders `input type="radio"` — so this
  //     route DOES have focusable inputs, and a letter pressed while the
  //     preset picker has focus must not step the session behind the dialog.
  //     That is the case journey 20 asserts, because it is the one that exists;
  //   * a product that grows a filter box later must not thereby acquire a
  //     debugger that steps while you type in it.
  //
  // So the guard is written against the DOM's own answer rather than against a
  // list of this page's inputs, and `isContentEditable` is included because a
  // contenteditable div reports `tagName` "DIV" and would otherwise pass.
  var t = e.target;
  if (!t) return false;
  if (t.isContentEditable) return true;
  var n = t.tagName;
  return n === "INPUT" || n === "TEXTAREA" || n === "SELECT";
})(#)
""".}

proc capturePointer(e: Element; id: int) {.importjs: """
(function(el, id){ try { el.setPointerCapture(id); } catch (_) {} })(#, #)
""".}
  ## Every pointer event for this gesture is delivered to `el` until release.
  ##
  ## `try` because a capture can be refused — a pointer that was already
  ## released, a browser that has taken it for a scroll — and a throw here
  ## would abort `pointerdown` and leave the drag half-armed, which is worse
  ## than a drag that simply stops tracking outside the element.

proc releasePointer(e: Element; id: int) {.importjs: """
(function(el, id){
  try { if (el.hasPointerCapture(id)) el.releasePointerCapture(id); } catch (_) {}
})(#, #)
""".}

proc deferTick(fn: proc()) {.importjs: "setTimeout(#, 0)".}
  ## Run `fn` after the current turn of the event loop.
  ##
  ## The scrub's next seek is issued through this rather than from inside the
  ## previous one's completion callback, so the transport is never asked to
  ## accept a request while it is still settling one. Nothing here is a
  ## workaround for a diagnosed drop — it is the ordering every OTHER caller of
  ## `gotoTicks` already has for free, since a row click and a deep link both
  ## arrive from an event of their own. Chaining is the one path that would not,
  ## and one task per answered seek is a negligible price beside the round trip
  ## it is sequencing.
  ##
  ## The deferral is also what makes `scrubDrain` take no argument, and that is
  ## not incidental: a gap between deciding to send and sending is exactly the
  ## window in which a target goes stale. Read that proc before changing this
  ## one.

proc trackLeft(e: Element): float {.importjs:
  "(function(el){ return el.getBoundingClientRect().left; })(#)".}
proc trackWidth(e: Element): float {.importjs:
  "(function(el){ return el.getBoundingClientRect().width; })(#)".}
  ## MEASURED PER MOVE, not once at `pointerdown`.
  ##
  ## The identity bar reflows: `.dcstatus` holds `step / totalSteps` and its
  ## width changes as the step counter gains digits, which a scrub does
  ## continuously. A rect cached at the press would be stale by the middle of
  ## the very drag it was taken for, and the handle would drift away from the
  ## pointer over the gesture — a defect that is invisible on a short drag and
  ## obvious on a long one. Two reads of a laid-out box per move is nothing
  ## beside the pane rebuild each answered seek already does.

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

proc closestOf(e: Element; selector: cstring): Element {.importjs: """
(function(el, s){ return el ? el.closest(s) : null; })(#, #)
""".}
  ## The element's nearest ancestor matching `selector`, or `nil`.
  ##
  ## The `Event`-rooted `closestFrom` above cannot answer this: a gutter click
  ## needs TWO ancestors of one target — the row, for the line number, and the
  ## document, for the path — and walking from the event twice would re-derive
  ## the same start node rather than continue from the row it already found.

proc activationKey(ev: Event): bool {.importjs: """
(function(e){ return e.key === "Enter" || e.key === " " || e.key === "Spacebar"; })(#)
""".}
  ## Is this the keystroke that presses a button?
  ##
  ## Needed because the breakpoint gutter is a `span`, and a `span` with
  ## `role="button"` receives neither a synthetic click from Enter nor one from
  ## Space — the exact trap `bindGestures` records against `role="button"`
  ## rows, which were fixed by making them real anchors. A breakpoint has no
  ## honest URL to be an anchor to, so the keyboard half is supplied here
  ## instead, and the role and this handler are a pair: neither is correct
  ## without the other. `"Spacebar"` is the legacy spelling older engines emit.

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

proc setControls(ui: Ui; view: DebugSessionView; km: Keymap) =
  ## The toolbar itself, replaced from a view that HAS buttons.
  ##
  ## Only ever called with a projection off the live ViewModels, which is the
  ## only kind of view that can populate all eight.
  ##
  ## `km` IS REQUIRED AND HAS NO DEFAULT HERE, deliberately, although
  ## `renderControls` gives it one. The renderer's default is `kmNone` because
  ## its other callers are the script-less page; this proc has exactly one
  ## caller family — hydration — and hydration always knows the answer. A
  ## default here would let a future call site silently re-render the toolbar
  ## with the chords stripped out of every tooltip, which presents as
  ## shortcuts that stop being documented after the first step.
  let dc = ui.controls.querySelector(".dc")
  if dc == nil: return
  dc.replaceWith(panes.renderControls(view.controls, km).cstring)
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

proc paintScrubber(ui: Ui; step, totalSteps: int) =
  ## Move the handle to `step`, without asking the engine anything.
  ##
  ## THE HALF OF THE GESTURE THAT MUST NOT WAIT. A seek answers in a median of
  ## 46 ms and occasionally in 446, and a handle that only moved when the engine
  ## replied would feel like a control being dragged through treacle at exactly
  ## the moments the engine is busiest. So the handle follows the pointer at
  ## pointer speed and the session follows the handle.
  ##
  ## It repaints THE SAME CLASSES `renderControls` emits, through the same
  ## `tickClass`, so this is the renderer's own answer reached without a
  ## re-render — not a lookalike that a later edit to the renderer would leave
  ## behind. Nothing here is a style: a handle moved by a `style` attribute
  ## would be the inline value `check-tokens.mjs` A5 forbids, arriving on the
  ## one build the linter does not read.
  let track = ui.controls.querySelector(".dctl")
  if track == nil: return
  let p = DebugControlsPane(step: step, totalSteps: totalSteps, positioned: step > 0)
  let marked = p.markedTick
  var i = 0
  for t in track.querySelectorAll(".tick"):
    inc i
    t.setAttribute("class", tickClass(p, i, marked).cstring)
  # The accessibility tree is a readout of the same position, so it moves with
  # the handle rather than with the engine's answer. A slider that announced a
  # value one round trip behind the one it is showing would be telling a screen
  # reader user something different from what it is telling everyone else.
  if track.classList.contains("seekable"):
    track.setAttribute("aria-valuenow", ($step).cstring)
    track.setAttribute("aria-valuetext",
                       ("step " & groupDigits(step) & " of " &
                        groupDigits(totalSteps)).cstring)

proc markScrubberSeekable(ui: Ui; p: DebugControlsPane) =
  ## The trace scrubber becomes a control once there is an engine to seek with.
  ##
  ## A visitor reported the track as something they expected to be able to drag
  ## and could not, and the report was right about the shape: `.dctl` is a
  ## timeline with a distinct playhead, which is a scrubber in every tool this
  ## product is measured against. What was missing was the gesture — the
  ## capability had been there since `ct/goto-ticks` landed, driving row clicks
  ## and deep links.
  ##
  ## Stamped HERE rather than rendered by `components/debugger`, and the choice
  ## is the same one `markRailNavigable` makes for the loop rail, plus one this
  ## control has of its own. The debug route is served TWICE: `just export`
  ## writes pages with no script at all, and that artefact is what a crawler and
  ## every capture review sees. A `role="slider"` on those pages would announce
  ## a range along which nothing can be moved — which is precisely the defect
  ## being fixed, reintroduced by the fix, on the one build where it would be
  ## hardest to notice. Affordance and behaviour are emitted by the same
  ## compilation, so they cannot ship apart.
  ##
  ## Re-applied after EVERY render, because `setControls` replaces `.dc`
  ## wholesale and an attribute set on the old element goes with it. The
  ## listener is delegated instead and survives — the same split
  ## `markRailNavigable` documents, for the same reason.
  ##
  ## The values are a live readout, not decoration: `aria-valuenow` moves with
  ## the session on every stop, and `aria-valuetext` carries the sentence,
  ## because "128" alone is not the quantity — "step 128 of 1,315" is.
  ## `aria-valuemin` is 1 and not 0: step 0 is `positioned = false`, the
  ## ABSENCE of a position rather than the first one, and a range that included
  ## it would offer a seek to nowhere.
  let track = ui.controls.querySelector(".dctl")
  if track == nil: return
  # THE GATE IS THE TRACE'S LENGTH, AND NOT `positioned`. A scrubber over a
  # trace whose length is unknown cannot map a pointer to a step, so there is
  # no gesture for the affordance to promise and none is offered.
  #
  # `positioned` was the first spelling of this line and it was wrong in the
  # worst available way. A session reports `rrTicks = 0` from the moment the
  # engine goes live until something moves it, so gating on a position made
  # the scrubber inert for exactly as long as the visitor had not yet used
  # anything else — which is to say, on arrival, which is when someone who
  # wants to jump into the middle of a trace reaches for a timeline. It was
  # measured: six clicks at six points on a freshly-live session, and all six
  # did nothing. Having no position is a REASON to offer the seek, not a
  # reason to withhold it; dragging is how a session that is nowhere gets
  # somewhere.
  if p.totalSteps <= 0: return
  track.classList.add("seekable")
  track.setAttribute("role", "slider")
  track.setAttribute("tabindex", "0")
  track.setAttribute("aria-label", ScrubName.cstring)
  # THE KEYS THIS CONTROL ANSWERS TO, NAMED ON THE CONTROL.
  #
  # The line above gave the slider a tab stop and a name, and the `keydown`
  # handler in `bindGestures` has answered the arrows, `Page Up`/`Page Down`
  # and `Home`/`End` on it ever since — and until now nothing on the page said
  # so. A visitor reported exactly this about the stepping buttons beside it
  # ("I still don't see the keyboard shortcuts being displayed in the
  # tooltips"), and the buttons were fixed while the one control on the strip
  # whose keys were already bound kept them secret.
  #
  # BOTH STRINGS COME FROM `keymap.ScrubKeys`, which is the table
  # `scrubMoveFor` dispatches from. That is the same structural guarantee
  # `controlLabel(a, km)` gives the buttons: the tooltip cannot name a key the
  # handler does not answer, because there is no literal here to go stale.
  #
  # STAMPED HERE, and not rendered by `components/debugger`, for the reason
  # every other line of this proc is: the served page has no bundle and
  # therefore no handler, and a `title` naming keys on that artefact would be
  # the "control that announces a range it cannot be moved along" this proc's
  # header is written against — in a different attribute.
  track.setAttribute("title", scrubLabel().cstring)
  # `aria-keyshortcuts` is WAI-ARIA 1.2's own attribute for this, so assistive
  # technology gets the list as data rather than as prose it would have to
  # parse out of the name. Same table, different projection of it.
  track.setAttribute("aria-keyshortcuts", scrubKeyShortcuts().cstring)
  track.setAttribute("aria-valuemin", "1")
  # `lastStep` AND NOT `totalSteps`: a slider announces the range it can be
  # moved along, and the count is one past the last coordinate the recording
  # has. Announcing it would have been this control telling a screen-reader
  # user that the value it traps the engine on is a value it can be set to.
  track.setAttribute("aria-valuemax", ($lastStep(p.totalSteps)).cstring)
  if p.positioned:
    track.setAttribute("aria-valuenow", ($p.step).cstring)
    track.setAttribute("aria-valuetext",
                       ("step " & groupDigits(p.step) & " of " &
                        groupDigits(p.totalSteps)).cstring)
  else:
    # No `aria-valuenow`, because there is no value. A slider that reported 1
    # here would be announcing a position the session is not at, which is the
    # untruthful handle in the one channel where it cannot be checked against
    # the screen. The element is rebuilt by `setControls` on every render, so
    # there is no stale value from an earlier stop to clear.
    track.setAttribute("aria-valuetext",
                       "no position yet — drag to seek into the trace")

# ---------------------------------------------------------------------------
# Revealing the position: WHEN the pane moves, and WHERE the line lands
# ---------------------------------------------------------------------------
#
# A VISITOR REPORTED THIS PANE AND IT IS WORTH QUOTING, BECAUSE THE COMPLAINT IS
# ABOUT MOVEMENT AND NOT ABOUT VISIBILITY
#
#     "When I step in through the instructions listing, the editor scrolls in a
#      way that the caret/cursor/current-line stay as the top line. No other
#      debugger that I know of behaves this way. My expectation is that the
#      editor should auto-scroll only when the caret leaves the visible area."
#
# Both halves of that were true here, and they came from two separate decisions
# that reinforced each other:
#
#   1. `renderPanes` re-windowed the pane through `openAtCurrent` on EVERY stop.
#      That function drops every line above `currentLine - SourceLeadIn` and runs
#      to the end of the file, so the current line is at row 7 of the rendered
#      document by construction. Measured on a real `aztec-testnet` capture
#      before this change, six consecutive steps left the mark at 65.7, 65.8,
#      65.9, 66.0, 66.1 and 66.2 pixels from the top of the pane while its number
#      went 1, 2, 3, 4, 5, 6. On a demo session the same six steps shortened the
#      document from 38 rendered lines to 21: the context above the position was
#      not scrolled past, it was DELETED.
#
#   2. `scrollToCurrentLine` then called `cur.scrollIntoView()` — the no-argument
#      form, which is `block: "start"` — unconditionally. Top-anchored, on every
#      render, whether or not the line had moved and whether or not it was
#      already on screen.
#
# MECHANISM 1 IS GONE FROM THE WHOLE REPOSITORY AND IT WAS NOT THIS BRANCH THAT
# FINISHED IT. `openAtCurrent`'s header gave the reason it existed — "The pane
# has no JavaScript to scroll with" — which was a fact about `pages/debug.nim`,
# the served frame, and never about this file. A sibling change arriving from the
# OTHER symptom (a reader who reported "Showing from line 71" over thirteen lines
# of an 83-line file) established that the premise had stopped holding for the
# served frame too, and removed the constant, the proc and both call sites. The
# no-script path is now `autofocus` plus `scroll-margin-block-start`, which buys
# the same six rows of context without deleting the rest of the program. See
# `renderPanes` for how that composes with this policy.
#
# MECHANISM 2 IS THIS BRANCH'S, AND REMOVING THE WINDOW DID NOT FIX IT. That is
# the thing to hold on to: with the document whole, `scrollIntoView()` still
# top-anchors the position on every render. `scroll-margin-block-start` shifts
# where "top" is, from row 1 to row 7, and a constant offset re-established on
# every step is exactly the sentence the visitor wrote. The window was the whole
# of "the line stays at the top" and only half of "it scrolls on every step".
#
# WHAT REPLACES IT, AND WHY THIS POLICY
#
# The hydrated pane renders the WHOLE active document, so there is a scroll
# surface with context on both sides of the position, and this reveal decides
# when to use it:
#
#   * the line is already inside the pane's box -> NOTHING MOVES. Not "scrolled
#     minimally", not "scrolled by a line": `scrollTop` is not written, and a
#     reader who has scrolled to read a helper above the position keeps their
#     place across the step.
#   * the line is outside the box -> it is CENTRED, clamped to the scrollable
#     range.
#   * the pane is showing a different DOCUMENT than it was -> centred
#     unconditionally, because the offset the reader was at is an offset into a
#     file they are no longer looking at.
#
# This is `revealLineInCenterIfOutsideViewport`, which is what CodeTracer's
# editor calls at all three of its stepping sites (`ui/editor.nim`,
# `ui/trace.nim`) and what VS Code, IntelliJ and GDB's TUI all do. It is also
# what the visitor asked for: leaving the box at the bottom edge and centring is
# a correction of half a pane, which is the "scroll with half a screen perhaps"
# in the report, and it buys the same further movement before the next scroll.
#
# ONE POLICY, NOT A SETTING. Alternative reveal policies are a desktop-product
# concern; this route picks the debugger norm and implements it.
#
# STEP AND JUMP ARE NOT DISTINGUISHABLE HERE, AND THAT IS A FINDING
#
# A toolbar step (`invoke` -> `invokeToolbarStep`) and a row click (`gotoTicks`)
# are two different requests, but they converge before anything renders: against
# the engine actually published at `/replay-engine/` the `ct/complete-move`
# branch of `onDapEvent` never fires (see its header), so BOTH arrive as a bare
# DAP `stopped`, go through `requestPosition` -> `stackTrace` -> `applyStop`, and
# reach `render` carrying no record of which gesture caused them. `applyStop` has
# no parameter for it and the `stopped` event's `reason` is not read.
#
# So there is one call site and it is tuned for STEPPING, which is what the
# report was about. A deliberate teleport is not left uncatered for by accident,
# though: a jump to another file changes the document and is centred by the third
# rule above, and a jump far down the same file is outside the box and is centred
# by the second. The two behaviours the distinction would have bought are what
# this policy already does — what it cannot do is centre a jump that lands
# somewhere already on screen, and holding still for that is the right failure.

#
# WHICH ELEMENT ACTUALLY SCROLLS, AND WHY IT IS NOT THE ONE THIS FILE HOLDS
#
# `Ui.editor` is `#pane-editor .panebody` and it is NOT the source pane's
# scroller. Measured in the browser on both renderings:
#
#   .srcline.cur                      23px
#   .src            overflow-y:auto   client 512 / scroll 886   (demo source)
#   .src.instr      overflow-y:auto   client 549 / scroll 7975  (chain listing)
#   .srcdoc         visible           client 539 / scroll 539
#   .srcwrap        visible           client 539 / scroll 539
#   .panebody       overflow-y:auto   client 614 / scroll 838
#
# `.src` is where the lines live and where the overflow is; `.panebody` scrolls
# only the tab strip or the listing caption above it, and on the demo pane it
# does not scroll at all (539 == 539). A reveal written against `.panebody`
# would have set `scrollTop` on an element with a scroll range of ZERO and moved
# nothing — which is a fix that measures as applied and is not.
#
# So the scroller is FOUND, from the line outward, rather than assumed. Both are
# then honoured: the inner one is where the line is placed, and the outer one is
# corrected afterwards if the inner scroller's own box is not fully on screen
# inside it. Two levels, because that is how many the measurement found, and the
# loop would be the same for three.

proc noteRevealAnchor(pane: Element) {.importjs: """
(function(pane){
  // Stashed ON the pane element, which SURVIVES the rewrite — `writePane`
  // assigns `pane.innerHTML`, so the pane is the same node and everything
  // inside it is new. That is why this is a property on `pane` and not a
  // `var` in this file: it needs to outlive exactly one innerHTML assignment
  // and nothing longer, and it is thrown away by a page load like the pane is.
  var cur = pane.querySelector(".srcline.cur");
  var doc = cur ? cur.closest(".srcdoc") : null;
  var inner = null;
  for (var e = cur; e && e !== pane; e = e.parentElement) {
    var oy = getComputedStyle(e).overflowY;
    if ((oy === "auto" || oy === "scroll") && e.scrollHeight > e.clientHeight + 1) {
      inner = e; break;
    }
  }
  pane.__btReveal = {
    doc: doc && doc.id ? doc.id : "",
    inner: inner ? inner.scrollTop : 0,
    outer: pane.scrollTop
  };
})(#)
""".}
  ## Where the reader had the source pane, read BEFORE `writePane` discards it.
  ##
  ## The `.srcdoc` id is taken with the offsets and compared with the id after,
  ## because "the reader's scroll offset still means something" is exactly the
  ## question "is this the same document". `docAnchor(path)` derives that id from
  ## the file path, so it is stable across renders of one file and differs across
  ## files — which is what makes this readable off the DOM with no state carried
  ## between renders.

proc revealCurrentLine(pane: Element) {.importjs: """
(function(pane){
  // THE REVEAL SAYS IT RAN, and it is the only thing here that does.
  //
  // Everything else this proc does is CONDITIONAL: the whole point of the
  // policy below is that a position already on screen leaves every scroller
  // untouched. So on the case this feature exists for, `scrollTop` is the same
  // before and after, no class changes, no event fires that a restore does not
  // also fire, and there is NOTHING a reader outside this function can observe
  // to know the reveal has happened. A harness waiting for it had no choice but
  // to sleep, which is how `13-…`'s "one more settle" came to be a duration.
  //
  // Incremented at ENTRY, deliberately, so the two early returns below are
  // counted too. The claim this attribute makes is "a reveal ran and has
  // finished deciding", not "a reveal moved something" — a reveal that found no
  // current line and did nothing HAS run, and a waiter that hung on those cases
  // would be waiting for a decision that had already been made. Entry and exit
  // are indistinguishable to any observer regardless: `renderPanes` is one
  // synchronous task and nothing is painted inside it.
  //
  // A `data-` attribute on the pane, which SURVIVES `writePane` for the same
  // reason `__btReveal` does — `innerHTML` replaces the children and not the
  // node. It is inert: no stylesheet selects it (checked), it takes no space
  // and it changes nothing a visitor sees.
  //
  // WHAT IT IS NOT: a count of scrolls. Two reveals that both hold still
  // advance it by two. `13-…` asserts exactly that pairing — the counter moved
  // AND `scrollTop` did not — because a counter that only advanced when the
  // pane scrolled would be a second spelling of `scrollTop` and would prove
  // nothing the existing assertion does not.
  var seq = Number(pane.getAttribute("data-reveal-seq") || "0");
  pane.setAttribute("data-reveal-seq", String(seq + 1));

  var a = pane.__btReveal || { doc: "", inner: 0, outer: 0 };
  var cur = pane.querySelector(".srcline.cur");
  if (!cur) return;
  var docEl = cur.closest(".srcdoc");
  var docId = docEl && docEl.id ? docEl.id : "";
  var sameDoc = a.doc !== "" && docId === a.doc;

  // Every scroller between the line and the pane, nearest first, plus the pane.
  var scrollers = [];
  for (var e = cur; e; e = e.parentElement) {
    var oy = getComputedStyle(e).overflowY;
    if ((oy === "auto" || oy === "scroll") && e.scrollHeight > e.clientHeight + 1)
      scrollers.push(e);
    if (e === pane) break;
  }
  if (scrollers.length === 0) return;

  // THE READER'S POSITION IS RESTORED FIRST, and this is load-bearing rather
  // than tidy. `writePane` assigns `innerHTML`, which resets every offset to 0,
  // so a policy that asked "is the line visible?" of the pane as it stands
  // would be asking about the top of a freshly-written document on every step
  // and would answer "no" every time — the reported defect, rebuilt out of the
  // fix. The question is about where the reader WAS.
  if (sameDoc) {
    scrollers[0].scrollTop = a.inner;
    if (scrollers[scrollers.length - 1] === pane) pane.scrollTop = a.outer;
  }

  // The CLIENT box of each scroller, not its border box: a line under a border
  // is not on screen. `clientTop` is that border's width and `clientHeight`
  // excludes it on both edges.
  var box = function(s){
    var r = s.getBoundingClientRect();
    var top = r.top + s.clientTop;
    return { top: top, bottom: top + s.clientHeight };
  };
  var inside = function(s){
    var b = box(s), cr = cur.getBoundingClientRect();
    return cr.top >= b.top && cr.bottom <= b.bottom;
  };

  // Innermost scroller first, so an outer one is judged against where the line
  // has actually landed rather than against where it started.
  //
  // THE WHOLE POLICY IS THE `continue` BELOW, and it is the only place that
  // decides. There was briefly a fast path above this loop — `if (sameDoc &&
  // scrollers.every(inside)) return;` — which read as the policy and was not:
  // it could only fire when every `continue` would have fired anyway. A
  // selftest arm aimed at it SURVIVED, correctly, and that is the useful
  // property of one decision point over two that agree. It is gone; the guard
  // here is load-bearing and mutating it is measurable.
  //
  // NOTE WHAT "HOLDS STILL" MEANS AND WHAT IT DOES NOT. The pane keeps its
  // offset; it does not fire no events. `writePane` assigns `innerHTML`, so
  // every scroller here is a NEW element starting at 0 and the restore above
  // moves it — one `scroll` event per render, whatever this decides. Nothing is
  // painted between the two, `renderPanes` being one synchronous task, so the
  // visitor sees the restored offset and never the zero. `scroll` events
  // therefore cannot tell a restore from a policy scroll and are the wrong
  // instrument; journey 13 counts changes in the PAINTED `scrollTop` from one
  // step to the next, which is what the visitor's complaint was counting.
  for (var i = 0; i < scrollers.length; i++) {
    var s = scrollers[i];

    // ALREADY VISIBLE HERE: leave this scroller exactly as it is. Not
    // "scrolled minimally", not "nudged by a line" — untouched, so a reader who
    // scrolled up to read a helper above the position keeps their place across
    // the step.
    if (sameDoc && inside(s)) continue;

    // OUTSIDE: centre it. `lineTop` is the line's offset into the scrolled
    // content, recovered from the two rects rather than from `offsetTop`, which
    // is relative to the nearest POSITIONED ancestor and not necessarily this
    // scroller.
    var b = box(s), cr = cur.getBoundingClientRect();
    var lineTop = s.scrollTop + (cr.top - b.top);
    var centred = lineTop - (s.clientHeight - cr.height) / 2;
    s.scrollTop = Math.max(0, Math.min(s.scrollHeight - s.clientHeight, centred));
  }
})(#)
""".}
  ## Move the source pane only if the position is not already in it, and centre
  ## the position when it moves. The policy and its provenance are the block
  ## comment above; this is `revealLineInCenterIfOutsideViewport` over a DOM that
  ## has no Monaco to ask for it.
  ##
  ## Publishes `data-reveal-seq` on the pane, incremented once per call. That is
  ## the only externally observable trace of a reveal that decided to hold
  ## still, and `readFacts` exposes it as `revealSeq`.

type
  PaneWrite = object
    ## One pane's write history: whether it has ever gone live, and the exact
    ## markup it currently holds.
    ##
    ## `written` is what makes the second field of this object a *cache* rather
    ## than bookkeeping. `writePane` compares against it instead of reading
    ## `target.innerHTML` back, because reading innerHTML serialises the whole
    ## subtree — 42 KB for the source pane — and the comparison happens on every
    ## pane on every render.
    latched: bool
    written: string

  PaneLatch = object
    ## Which panes the live session has ever had content for, and what each one
    ## currently says.
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
    editor, calltrace, state, eventLog: PaneWrite

proc writePane(target: Element; html: string; hasContent: bool;
               pane: var PaneWrite) =
  ## Write a pane if it has content, or if it has had content before — and only
  ## if the markup it would write is not the markup already on screen.
  ##
  ## ## THE FLICKER, AND WHY IT IS FIXED HERE
  ##
  ## `render` is not called once per stop. It is called by `applyStop`, by the
  ## locals feed's `onApplied`, and by the navigation feed's `onApplied` — each
  ## of them a real event that *could* change a pane. Measured against the
  ## published engine, one forward step produced SEVEN calls, and each call
  ## rewrote all four panes: 28 `innerHTML` assignments, of which 21 wrote
  ## byte-identical markup. The Call Trace's 24 KB and the Event Log's 7.5 KB
  ## were rebuilt seven times each to say exactly what they already said.
  ##
  ## An `innerHTML` assignment is a teardown. Every node in the pane is
  ## destroyed and replaced, which drops the visitor's scroll position inside
  ## it, drops any selection, restarts every transition, and — through
  ## `scrollToCurrentLine` at the end of `renderPanes` — moves the source pane
  ## seven times per step. A visitor sees that as flicker, and reported it as
  ## flicker.
  ##
  ## The fix is not to render less often. The events are real and a pane that
  ## refused to repaint on one of them would be stale. It is to make the pane's
  ## DOM a function of the pane's CONTENT rather than of how many times
  ## something asked for a repaint: identical markup is not written, so a pane
  ## whose data did not change keeps its nodes across the step. That is the
  ## no-virtual-DOM discipline the rest of this site is built on, applied at the
  ## one seam that had skipped it.
  ##
  ## NOT A CHEAPER `innerHTML`. The comparison is against `pane.written` — what
  ## this proc last wrote — and never against a value read back out of the DOM.
  ## Reading `target.innerHTML` would re-serialise the subtree on every pane on
  ## every render, which is more work than the assignment it is trying to avoid,
  ## and it would also compare against the browser's normalisation of the markup
  ## rather than against the markup, so the first write of every render would
  ## look like a change.
  if not hasContent and not pane.latched: return
  if pane.latched and html == pane.written: return
  pane.latched = true
  pane.written = html
  target.innerHTML = html.cstring

proc renderPanes(ui: Ui; view: DebugSessionView; latch: var PaneLatch;
                 km: Keymap) =
  ## The four replay panes and the controls, from the renderers the static
  ## export used.
  ##
  ## The source pane renders the WHOLE file, exactly as the served page does, so
  ## a hydrated frame and a served frame at the same position are the same
  ## markup. That equality is not decoration: it is what makes "hydrate over
  ## it" true rather than "replace it with something similar".
  ##
  ## `view.editor = openAtCurrent(view.editor, SourceLeadIn)` used to stand here,
  ## matching the identical call in `pages/debug.nim`. Both are gone — see
  ## `source_document.nim` for the reason the lead-in was there and what was
  ## measured about it — and the equality above is preserved by the same argument
  ## it always rested on: one decision, made in one place, for both builds. The
  ## place is now "no reduction", and `revealCurrentLine` below is what puts the
  ## reader at the position instead.
  ##
  ## ## ONE CAUSE, TWO REPORTS — and the second one is why BOTH calls had to go
  ##
  ## This call was independently found from the other end, by a reader who
  ## reported that "stepping pins the current line to the top of the pane". It is
  ## the same line of code: re-windowing to `currentLine - 6` on every stop put
  ## the position at row 7 BY CONSTRUCTION, so the pane could not have placed it
  ## anywhere else and no scroll policy could have moved it. Truncation and
  ## top-pinning were one mechanism wearing two symptoms.
  ##
  ## That investigation also established the measurement hazard, and it is
  ## recorded here because it is the thing a future regression will hide behind:
  ## `scrollTop` DOES NOT DISCRIMINATE. Under re-windowing the pane never
  ## scrolls — the CONTENT moves — so `scrollTop` reads 0 before and after, and a
  ## journey asserting on it stayed green across 23 consecutive steps with the
  ## position frozen at 189px. The assertion that separates a windowed pane from
  ## a whole one is the PAINTED ROW COUNT against the file's own published
  ## length, which is what `12-a-source-file-is-shown-whole` asserts and what its
  ## Q1 arm reddens.
  ##
  ## Fixing only this call would have left the SERVED frame windowed —
  ## `pages/debug.nim` made the identical call — which is 29 "Showing from
  ## line/step N" notices across the exported tree, on the exact artefact the
  ## design-review campaign photographs. That is why the constant and the proc
  ## are gone rather than one of their two callers.
  ##
  ## ## AND THE SECOND REPORT NEEDED A SECOND FIX, WHICH IS THE REVEAL POLICY
  ##
  ## Removing the window was necessary for the top-pinning report and it is not
  ## sufficient, which is worth being exact about because the two changes look
  ## like one. With the window gone the pane finally HAS somewhere to put the
  ## position — but `scrollToCurrentLine` still called `cur.scrollIntoView()`
  ## unconditionally, on every render, and that is `block: "start"`. Measured on
  ## a whole file, that pins the position to the top of the pane on every step
  ## just as the window did; `scroll-margin-block-start` moves the constant from
  ## row 1 to row 7 and it is still a constant.
  ##
  ## So the call is now `revealCurrentLine`, which moves the pane ONLY when the
  ## position is not already in it. The visitor's sentence was two claims — "it
  ## scrolls on every step" and "the current line stays as the top line" — and
  ## the window was the whole of the second and only half of the first.
  ##
  ## THE SERVED FRAME'S `autofocus` IS NOT A DUPLICATE OF THIS AND THE TWO
  ## COMPOSE. `autofocus` fires once, at parse time, on the row the EXPORTER
  ## marked, and `scroll-margin-block-start` gives it the six rows of context the
  ## lead-in used to give by deletion. That is the no-script path and it is the
  ## only path on a `just export` build. Once the bundle runs, every stop
  ## rewrites the pane and the offset has to be re-established — and re-focusing
  ## a row on every stop would take focus away from the stepping control the
  ## reader is holding.
  ##
  ## The composition is: `autofocus` places the landing, `noteRevealAnchor` reads
  ## that offset off the served DOM before the first rewrite, and the guard in
  ## `revealCurrentLine` finds the position already inside the box and leaves it
  ## exactly where the browser put it. The two do not fight because only one of
  ## them ever moves the pane, and journey 13 asserts that rather than assuming
  ## it — a hydrated landing whose offset differs from the served one would mean
  ## they do.
  noteRevealAnchor(ui.editor)
  var view = view

  # THE SESSION'S POSITION, WRITTEN WHERE THE SESSION PUBLISHES IT.
  #
  # `data-step` was READ once, out of the served DOM, and never written again.
  # So after the first step the root said 128 while the session stood somewhere
  # else, and it went on saying 128 for the rest of the session. Everything that
  # reads the page for a position — a share link, a test, a person with the
  # inspector open — was told the landing step forever.
  #
  # It is written HERE, in the one proc that draws the panes, rather than in
  # `applyStop`, so the attribute and the panes cannot disagree: they are the
  # same call over the same `view`. Writing it in the stepper would have made
  # them two facts that happen to be updated together, which is the arrangement
  # that let them drift in the first place.
  #
  # `totalSteps` is written too, because a step count without its denominator is
  # half a coordinate, and the served value is only correct until the engine has
  # its own opinion.
  ui.root.setAttribute("data-step", ($view.controls.step).cstring)
  # Rewritten beside the step for the reason the step is rewritten here: the
  # attribute and the panes are the same call over the same `view`, so they
  # cannot drift into two facts that happen to be updated together. A hydrated
  # session that has become positioned must say so, or the next reader of the
  # DOM — a journey, a share link, a person with the inspector open — is told the
  # served page's answer forever.
  ui.root.setAttribute("data-positioned",
                       (if view.controls.positioned: "1" else: "0").cstring)
  ui.root.setAttribute("data-total-steps", ($view.controls.totalSteps).cstring)
  # "Content" for the source pane is not "documents" — a pane that has resolved
  # to `srcUnverified` has no documents and IS the honest §14 row, so it counts
  # as something to say. What must never replace a served listing is a pane
  # that has resolved to nothing at all.
  # `view.controls` is passed for the same reason `paneBody` passes it: an
  # instruction-level pane has no line to mark, so its position head is drawn
  # from the session's step. Omitting it here would have shipped the fix on the
  # build the capture harness photographs and NOT on the build a visitor loads —
  # this route defers `/assets/hydrate.js`, and this call re-renders the pane the
  # static export drew. The two artefacts differ, and a fix has to land on both.
  writePane(ui.editor, panes.renderSource(view.editor, view.controls),
            view.editor.documents.len > 0 or view.editor.reason.len > 0,
            latch.editor)
  writePane(ui.calltrace, panes.renderCallTrace(view.calltrace),
            view.calltrace.frames.len > 0, latch.calltrace)
  # The State pane's "content" is not "values", for the reason the source pane's
  # is not "documents", one clause up. A live session that has asked the engine
  # for this position's values and not yet been answered has a true sentence to
  # print — and MUST print it, because the alternative is leaving the served
  # frame's values on screen under a position they do not belong to. That is the
  # shape of §7.0 violation the latch cannot see: the pane is full, and full of
  # the wrong frame. `session_project.projectState` produces the sentence and
  # `live_locals.noteFor` decides which one.
  writePane(ui.state, panes.renderState(view.state),
            view.state.values.len > 0 or view.state.note.len > 0, latch.state)
  writePane(ui.eventLog, panes.renderEventLog(view.eventLog),
            view.eventLog.rows.len > 0, latch.eventLog)
  setControls(ui, view, km)
  # The selection panel, from the SAME `view` the panes were just drawn from.
  #
  # In this proc and not in the stepper, for the reason `data-step` is written
  # here: the panel describes the row the panes are showing as current, and
  # deriving it from a second read of anything is how two facts that are
  # updated together become two facts that drift. One call, one view.
  #
  # No latch. Unlike a pane, this section is never blank-when-empty — it always
  # renders, and `selNone` is a sentence rather than an absence — so there is
  # no served content for an empty projection to wrongly replace.
  let sel = document.getElementById(panes.SelectionSlotId.cstring)
  if sel != nil:
    sel.outerHTML = panes.renderSelection(selectionDetail(view)).cstring
  markRailNavigable(ui)
  markScrubberSeekable(ui, view.controls)
  revealCurrentLine(ui.editor)

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
  ##
  ## ## The sentence goes ON THE PAGE (added VD.6)
  ##
  ## Everything below this line used to be everything this proc did, and none of
  ## it renders the reason: the sentence went into two attributes on a disabled
  ## button and one attribute on the root, and the only visible change was the
  ## status text becoming "Engine unavailable". A pointer user had to hover an
  ## inert control to learn which of three faults had occurred; a touch user
  ## could not, and a screen-reader user was told more than a sighted one.
  ##
  ## The three sentences this proc is called with are separated at their source
  ## because one sentence covering two faults cost hours of misdiagnosis. That
  ## separation only pays if the sentence is legible, so it is now drawn into
  ## the slot `pages/debug.nim` emits, through the renderer that page would have
  ## used. The attributes below stay: they are what a control announces about
  ## ITSELF, and the banner is what the page says about the session.
  let slot = ui.root.querySelector("#" & EngineFailureSlotId)
  if slot != nil:
    slot.innerHTML = panes.renderEngineFailure(reason).cstring
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
# §6.0a — reading the link, not only writing it
# ---------------------------------------------------------------------------
#
# The debug route existed as a deep-link TARGET that never read its own link.
# `?t=` was written on every navigation and ignored on every arrival, so a
# shared link opened wherever the engine happened to land — which is the
# silent wrong position §6.0a is written to forbid, produced by the half of
# the mechanism that was built first.
#
# Resolution happens HERE, before a byte of the engine is fetched, for two
# reasons. §6.3: "Resolution happens **before first paint**, so a shared link
# opens *at* the position rather than at the start with a visible jump" — and
# the first paint hydration controls is the one after `goLive`, so the decision
# has to precede it. And §6.0a's step 1, "no replayable artifact → state that",
# is reachable ONLY on a page with no container at all, which is a page whose
# panes do not exist and where nothing else in this file runs.
#
# The rows the anchor is resolved against are the SERVED ones. That is not a
# shortcut around asking the engine: §7.0 makes this page the session's first
# frame rendered from published data, so its call trace and event log already
# describe the artifact the link is about, and each row carries its §6.0a
# anchor as `data-anchor`. Asking the engine would cost a worker, an 18 MB
# wasm and a round trip to learn something the document already states.

proc rowsOf(root: Element; selector: cstring):
    seq[tuple[step: int, anchor, module: string]] =
  ## The path comes from `data-module` and NOT from a child element's text.
  ##
  ## It used to be `row.querySelector(".ctmod").textContent` — this reader
  ## scraped a value out of a span that existed for PRESENTATION, so the
  ## question "may the call trace stop painting the path?" silently had
  ## "no, deep-link landing reads it" as part of its answer, and nothing here
  ## or there said so. The row now states the path as data; the renderer is
  ## free to paint it, tooltip it or drop it, and this keeps working either
  ## way. An attribute is also what the row already does for `data-step` and
  ## `data-anchor`, which is the whole point — the other two facts a landing
  ## needs were never scraped out of the rendering.
  for row in root.querySelectorAll(selector):
    result.add (intAttr(row, "data-step"), attr(row, "data-anchor"),
                attr(row, "data-module"))

proc servedCallTrace(root: Element): CallTracePane =
  ## The served call trace as pane data. Only what an anchor lookup reads:
  ## the coordinate, the anchor, and the module path a `src:` anchor is matched
  ## against. Depth is left at 0, which `startCoordinate` handles by falling
  ## back to the first row — and the first row of a call trace rendered in call
  ## order IS the entry frame.
  for r in rowsOf(root, ".ctrow"):
    result.frames.add CallFrame(step: r.step, anchor: r.anchor, module: r.module)

proc servedEventLog(root: Element): EventLogPane =
  for r in rowsOf(root, ".evrow"):
    result.rows.add EventRow(step: r.step, anchor: r.anchor)

proc markServedFrame(root: Element; index: int) =
  ## Mark the served call-trace row a `call:` link named, and unmark the rest.
  ##
  ## ## Why this happens here, on rows the engine has not seen
  ##
  ## §6.3 wants a shared link resolved "before first paint", and the engine is
  ## 18 MB away. Between arriving and the session coming up, the served rows are
  ## the whole of what the visitor has — and the mark on them is the STATIC
  ## producer's answer to a different question. `demo_session.withCallFrames`
  ## marks the innermost frame containing the served coordinate, which is the
  ## right answer to "where is the session" and the wrong one to "which frame
  ## did this link name": for a link into the six frames that share step 59 it
  ## marks `Poseidon2::hash_internal` every time, because all six contain the
  ## step and it is the deepest.
  ##
  ## The index is `LinkLanding.frame`, and it indexes THESE rows: `resolveLanding`
  ## was handed `servedCallTrace(root)`, which `rowsOf` built from this same
  ## `.ctrow` selector in this same order. One walk, one numbering.
  ##
  ## CLEARED FIRST, AND ONLY WHEN A FRAME WAS NAMED. Two rows carrying `cur`
  ## would have the pane assert two positions, and the caller only reaches here
  ## with a frame in hand — an ordinary visit, or a link that named an event or
  ## no anchor at all, leaves the served mark exactly as served rather than
  ## stripping the page's own answer and replacing it with nothing.
  let rows = root.querySelectorAll(".ctrow")
  if index < 0 or index >= rows.len: return
  for i in 0 ..< rows.len:
    rows[i].classList.remove("cur".cstring)
  rows[index].classList.add("cur".cstring)

proc servedLandingAnchor(root: Element; landing: LinkLanding): string =
  ## The `call:` IDENTITY of the frame an incoming link named, read off the same
  ## served rows `resolveLanding` numbered.
  ##
  ## `LinkLanding.frame` is an INDEX, and an index is exactly what cannot be
  ## carried across to the live pane: the served rows are the static export's
  ## and the hydrated ones are the engine's, so the two lists are not the same
  ## length — measured on the deep capture, 47 served rows against 48 live ones,
  ## because the live window carries an `<end of program>` frame the exporter
  ## does not. An anchor survives that, both producers derive it from the same
  ## `withCallAnchors`, and `Click-Navigation.md` §4 requires exactly this ("a
  ## frame identity written by the static exporter and one resolved from a live
  ## session are the same string").
  ##
  ## Empty for a link that named no frame — a `log:` or `sw:` anchor, an
  ## enclosing-frame fallback, an ordinary visit — which is the case
  ## `selectLandingFrame` answers from the session's position instead.
  if landing.frame < 0: return ""
  let ct = servedCallTrace(root)
  if landing.frame >= ct.frames.len: return ""
  ct.frames[landing.frame].anchor

proc announceLanding(root: Element): LinkLanding =
  ## Resolve the link this page was opened with, and say where it landed.
  ##
  ## Written into the slot `pages/debug.nim` always emits, through the SAME
  ## renderer that page would have used — so the sentence a visitor reads is
  ## not a second wording of the one the static export knows how to draw. The
  ## slot is `:empty`-hidden, so an ordinary visit and an exact hit both leave
  ## the page exactly as served.
  result = resolveLanding(
    linkPayload(),
    # The page's own predicate for "there is a container here", which
    # `pages/debug.nim` derives from `canShare` rather than from a path that
    # may be merely derivable. Two predicates for one question is how a
    # `data-trace` pointing at a 404 got shipped once already.
    artifactAvailable = attr(root, "data-trace").len > 0,
    currentContentHash = attr(root, "data-content-hash"),
    calltrace = servedCallTrace(root),
    eventLog = servedEventLog(root))
  # The frame the link named, marked on the served rows. Before the notice,
  # because the notice is the sentence ABOUT the landing and this is the
  # landing: a visitor who reads "opened at the position this link names"
  # beside a pane marking a different frame has been told two things.
  markServedFrame(root, result.frame)
  let slot = document.getElementById(PositionNoticeSlotId.cstring)
  if slot == nil: return
  var view: DebugSessionView
  view.landing = result.notice
  view.landingCoordinate = result.coordinate
  slot.innerHTML = panes.renderPositionNotice(view).cstring

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
    sourceFilesGiven: int    ## files of the recording's source put in the VFS
      ## Zero is a legitimate answer and a load-bearing one. A chain capture
      ## publishes no source (`sourceBundles` empty, `execution.sourceLevel`
      ## false on all eight in the corpus), so its island is empty and the
      ## origin classifier necessarily has nothing to parse. Recording the
      ## count keeps "the chain found nothing" distinguishable from "the engine
      ## was never given a line", which are different sentences to put in front
      ## of a visitor and were previously the same one.
    engineLoaded: bool       ## the worker compiled the wasm and said so
      ## Recorded for ONE reason: so the deadline below can name which of two
      ## unrelated failures it is reporting. An engine that never arrived (a
      ## missing or misconfigured `/replay-engine/`) and an engine that arrived
      ## and would not open this container are different faults with different
      ## fixes, and a single sentence covering both sent a real diagnosis down
      ## the wrong path for hours.
    stopped: bool            ## `fail` has been called; the session is over
      ## Read by ONE thing: the locals feed's re-render (`goLive`). A failure
      ## settles every request the transport was holding — `WorkerBackend`
      ## .failAllPending exists so a dropped request cannot present as a pane
      ## that spins forever — so the `ct/load-locals` reply this bundle waits
      ## for ARRIVES on the failure path, as a refusal, milliseconds after
      ## `fail` has written the failure onto the page. Repainting then would
      ## put a live-looking toolbar and a live projection back over the
      ## sentence that says the engine is gone, which is §7.0's guarantee
      ## broken by the code that was added to keep it.
    prefs: PreferenceStore
      ## Where this visitor's choices are kept. The anonymous tier — the
      ## browser's own `localStorage` — and the ONLY thing on this page that
      ## touches it.
      ##
      ## Held as the store rather than as its contents so that the account
      ## tier is a different constructor here and no change anywhere else:
      ## configuration lives in the account when signed in and in local
      ## storage when anonymous, and the code below cannot tell which it has.
    keymap: Keymap
      ## The chords in force. ONE value, and the reason it is one:
      ##
      ##   * `bindShortcuts` matches key presses against it,
      ##   * `setControls` passes it to the renderer, which composes each
      ##     chord into the tooltip it labels the button with,
      ##   * `renderShortcutsDialog` lists it.
      ##
      ## Three readers, one table. A chord a visitor can SEE is therefore a
      ## chord the dispatcher will match, not because anything checks that but
      ## because there is no second place for either to be written down.
      ## `Debugger-Integration.md` §10.5 is the requirement ("the text is
      ## derived from the binding in force, not written beside the control as
      ## a label") and this field is where "in force" lives.
    latch: PaneLatch         ## which panes the live session has ever filled
    landing: LinkLanding     ## where §6.0a said this link puts the session
    landingAnchor: string
      ## The `call:` identity of `landing.frame`, read off the served rows
      ## before hydration replaced them. See `servedLandingAnchor` for why the
      ## index cannot be carried instead.
    frameSeeded: bool
      ## Whether the landing's call-trace selection has been written.
      ##
      ## Once, and only once: `selectLandingFrame` re-derived on every stop
      ## would overwrite a frame the visitor chose with the innermost frame at
      ## that coordinate, which is the collision `Click-Navigation.md` §2.2
      ## says a coordinate cannot decide.
    breakpoints: BreakpointSet
      ## The lines the visitor has marked, and the ONLY copy of them on this
      ## page that anything reads.
      ##
      ## The engine has its own registry and it is deliberately not consulted:
      ## `setBreakpoints` REPLACES a source's breakpoints, so the engine can
      ## answer "which lines are set" only for the last request it was sent,
      ## and asking it would make the gutter's marks depend on a round trip
      ## that a step could interleave with. This set is authoritative, the
      ## engine is told about every change to it, and the gutter is rendered
      ## from it — one producer, which is the rule §7.1 states for facts and
      ## which the toolbar's `toolbarActionId` follows for commands.
    continueOutcome: string
      ## §10.8's sentence for a continue that had nothing to reach. Empty
      ## whenever the last move went somewhere, which is the usual case.
    continueFrom: uint64
      ## Where a continue started, so a continue that reached no breakpoint can
      ## be undone. The engine moves to the end of the recording BEFORE it says
      ## it hit nothing (`dap_handler.step_continue` sends the notification
      ## after the jump), so "the position is unchanged" has to be restored
      ## rather than prevented.
    continueAwaiting: bool
      ## A continue is in flight and its outcome is not yet known.
      ##
      ## Gates the notification handler so that `ct/notification` is read as
      ## "this continue reached nothing" only for a continue this page issued.
      ## The engine emits notifications for other reasons, and a handler that
      ## treated any of them as a continue outcome would rewind the session
      ## from under an unrelated gesture.
    continueMissMessage: string
      ## The sentence for the continue in flight, chosen when it is ISSUED.
      ##
      ## Held here rather than derived on arrival because the notification says
      ## only that nothing was hit — it does not say which way the session was
      ## going, and "ahead of here" and "before here" are the two different
      ## things a visitor needs told apart.
    framePending: bool       ## a paint is already scheduled
    framesWaited: int        ## frames this paint has held for the values
    everPainted: bool        ## a live paint has replaced the served frame
    pendingQuery: string     ## the §6.3 coordinate the next paint publishes
      ## The address bar moves WITH the panes, not ahead of them.
      ##
      ## `applyStop` used to call `replaceQuery` itself, which was right while
      ## the paint was synchronous and became a defect the moment it was not: the
      ## URL advanced to the new position while the screen still showed the old
      ## one, for as long as the paint waited. That is the page contradicting
      ## itself in the one place a visitor can copy — and journey 09 caught it,
      ## by taking its reading the instant ANY of the three coordinates moved and
      ## finding the URL had moved without the page.
      ##
      ## §6.3's "`t` updates on every navigation" is a claim about EVERY, not
      ## about when: the query is composed at the stop, where the stack frame's
      ## path and line are in hand, and published by the paint that shows it.

    # ---- the scrubber drag ---------------------------------------------
    #
    # THE TWO DESIGN DECISIONS, HELD AS FOUR FIELDS.
    #
    # 1. THE SEEK IS LIVE, AND IT IS COALESCED RATHER THAN TIMED. Seeking on
    #    every pointermove floods the engine: a pointer reports at 60–120 Hz,
    #    and `ct/goto-ticks` answers this trace in a median of 46 ms over 127
    #    measured seeks (min 11, max 446) — every one of which also rebuilds
    #    five panes. Unthrottled, the requests would outrun the answers by
    #    three to eight times and the queue would put the handle seconds
    #    behind the hand by the end of a drag.
    #
    #    The conventional alternative is to move the handle live and seek only
    #    on release. A live scrub is genuinely nicer IF the engine can keep up,
    #    and 46 ms is ~21 seeks a second, so it can — which is why this is
    #    measured rather than assumed. So the seek stays live, with AT MOST ONE
    #    REQUEST IN FLIGHT: newer pointer positions overwrite `scrubPending`
    #    instead of queueing, and the pending one is issued when the in-flight
    #    one settles. That is a throttle clocked by the ENGINE rather than by
    #    an interval this file would have to guess and would be wrong about on
    #    a longer trace, a slower machine, or the 446 ms tail.
    #
    #    The handle itself never waits for any of it (`paintScrubber`), so the
    #    gesture is immediate even in that tail.
    #
    #    THE RULE ITSELF IS NOT HERE. It is `debugger/scrub_queue.nim`, which
    #    is ordinary data with no browser, no worker and no clock in front of
    #    it, so `tests/test_scrub_queue.nim` can state the orderings directly.
    #    That module's header records why: the one failure this rule has is a
    #    drag that ends where the visitor merely dragged THROUGH, it shipped
    #    once, and the browser-level gate written for it could not reproduce it
    #    reliably — the window is a single microtask drain wide. This file owns
    #    the DOM and the transport and none of the decision.
    #
    # 2. A CLICK ON THE TRACK SEEKS TO THAT POINT, and it falls out of the same
    #    code rather than being a case beside it: a click is a `pointerdown`
    #    and a `pointerup` at one place, so the press seeks and the release
    #    commits the same step. Most scrubbers behave this way and a visitor
    #    who has just learnt the track is draggable will try it. The rejected
    #    alternative — drag-only, with a click doing nothing — would leave a
    #    control that answers one gesture and silently ignores the cheaper one,
    #    which is a smaller version of the defect being fixed.
    scrubbing: bool          ## a pointer is down and owns the handle
    scrubTarget: int         ## the step under the pointer, painted, maybe unsent
    scrubQ: ScrubQueue       ## which seek to send, and when

const PositionSettleFrames = 6
  ## How long a paint may wait for the position's values before going ahead
  ## without them. Six frames is about 100 ms at 60 Hz — the same order as
  ## Debugger-Integration §7's whole-navigation budget, and two orders below
  ## `live_locals.LocalsDeadlineMs`, which is the bound on the WAIT rather than
  ## on the paint.
  ##
  ## A bound and not a promise. Past it the panes are painted with whatever the
  ## session knows, which is the position plus "Reading the values at this
  ## position…" — because a wait this long is a wait a visitor is entitled to
  ## see, and §8 forbids hiding one.

proc paintWhenSettled(h: Hydration)

proc paint(h: Hydration) =
  ## The panes, drawn from the live projection with everything this page owns
  ## stamped onto it — and then the address bar.
  ##
  ## Split out of `render` when `render` became the SCHEDULING half: the
  ## decoration below has to happen on the pass that actually draws, not on the
  ## one that asks for a draw. The §6.3 coordinate is published from here for
  ## the same reason and in the same breath — "what is on screen" and "what a
  ## reader would copy" cannot be published by two call sites at two moments,
  ## which is exactly how they came apart once the paint stopped being
  ## synchronous.
  # THE LANDING'S OWN FRAME, SELECTED ON THE FIRST RENDER THAT HAS ROWS TO
  # SELECT FROM — and before the projection, so the pane is never drawn once
  # unmarked and then marked.
  #
  # §7.0: "No state renders less than the pre-hydration page." The served page
  # marks exactly one call-trace row; without this the live pane replaced it
  # with a pane marking none, so hydration REMOVED a fact the visitor already
  # had. Gated on `visibleLines` rather than on a phase because the frames are
  # what this needs, and they arrive with `ct/updated-calltrace` rather than
  # with the stop.
  if not h.frameSeeded and h.session.calltrace.visibleLines.val.len > 0:
    h.frameSeeded = h.session.selectLandingFrame(h.landingAnchor)
  var view = projectReplayPanes(h.session, h.base, h.ui.island)
  # THE MARKS GO ON HERE, INSIDE THE RENDER, and that placement is the whole
  # reason they survive.
  #
  # `renderPanes` replaces the editor pane's `innerHTML` on every stop. A
  # breakpoint mark stamped onto the DOM by the click handler would therefore
  # last exactly until the visitor's next step — visible, correct, and then
  # silently gone, while the engine still stopped there. Projecting the set
  # into the view on every render means the same pass that moves the position
  # repaints the marks, and there is no path that renders one without the
  # other.
  #
  # The gesture is offered only where it can be honoured: `breakpointsEnabled`
  # is set here, in the live projection, and nowhere else — so the static
  # export renders the same gutter with no control on it.
  view.editor.breakpointsEnabled = true
  # §10.8's "the control says so", carried on the pane that owns the control.
  view.controls.outcome = h.continueOutcome
  for di in 0 ..< view.editor.documents.len:
    let path = view.editor.documents[di].path
    for li in 0 ..< view.editor.documents[di].lines.len:
      view.editor.documents[di].lines[li].breakpoint =
        h.breakpoints.contains(path, view.editor.documents[di].lines[li].number)
  renderPanes(h.ui, view, h.latch, h.keymap)
  # A DRAG OWNS THE HANDLE UNTIL IT IS RELEASED.
  #
  # `renderPanes` has just drawn the handle where the ENGINE is, which during a
  # scrub is one coalesced seek behind the pointer. Leaving it there would snap
  # the handle backwards on every answer — roughly twenty times a second — and
  # read as the control fighting the hand holding it.
  #
  # So the pointer's target is restored, and ONLY the handle: every other pane
  # keeps the engine's answer, because the engine's answer is what those panes
  # are about. The two are different claims. "Where the visitor is pointing" is
  # the handle's; "what the trace looks like there" is everything else's, and
  # the second may lag the first by a round trip without either being wrong.
  if h.scrubbing and h.scrubTarget > 0:
    paintScrubber(h.ui, h.scrubTarget, intAttr(h.ui.root, "data-total-steps"))
    # And the `grabbing` cursor with it. The class was added to the `.dctl`
    # that existed at `pointerdown`, and that element is gone — so without this
    # the cursor reverted to `grab` the first time the engine answered, roughly
    # 46 ms into a drag that was still very much under way. A cursor that stops
    # saying "you are dragging this" while the visitor is dragging it is a
    # small lie, but it is the same kind as the one being fixed.
    let track = h.ui.controls.querySelector(".dctl")
    if track != nil: track.classList.add("scrubbing")
  # After the panes and never before them, so a reader who copies the address
  # bar copies the position they are looking at.
  #
  # THROUGH `withPreservedFragment`, because `pendingQuery` is a query-only
  # reference and resolving one of those nulls the fragment. Writing it bare
  # dropped the visitor's `:target` state — the pane tab, the source-document
  # tab, the self-cost view, the loop rail rung — on the first live paint, and
  # took the `#…` half of the page's own Share link with it. The proc decides
  # which fragments are the visitor's to keep; see its comment for why a spent
  # payload is not one of them.
  if h.pendingQuery.len > 0:
    replaceQuery(withPreservedFragment(h.pendingQuery, locationHash()))
    h.pendingQuery = ""

proc render(h: Hydration) =
  ## Draw the panes now.
  ##
  ## Immediate and synchronous, which is what every caller but one wants: a
  ## locals reply, a call-trace section and an event-log section are each a fact
  ## arriving, with nothing half-finished to protect, and a page that painted
  ## them a frame later would make every reading of itself a race for no gain.
  ## `renderAfterMove` is the one caller that holds a paint back, and its comment
  ## is where the reasoning lives.
  h.everPainted = true
  h.paint()

proc renderAfterMove(h: Hydration) =
  ## A stop's paint, held until the move has settled — and the ONLY paint in
  ## this file that is held at all.
  ##
  ## ## WHY THIS IS COALESCED, AND WHY IT IS NOT A TIMING HACK
  ##
  ## One stop is not one event. `applyStop` knows the POSITION; the values for
  ## it have to be asked for and arrive about 13 ms later; the call trace and
  ## the event log arrive on their own. Each of those calls this proc, and each
  ## is right to.
  ##
  ## So between the stop and the reply there is a real, correct, unavoidable
  ## state: the session is at the new position and does not yet know its values,
  ## and `live_locals.noteFor` renders it as "Reading the values at this
  ## position…". Measured on the published engine, that state lasted 13 ms — and
  ## a frame is 16.7 ms, so it straddled a frame boundary roughly four times in
  ## five and WAS PAINTED. The Values pane visibly emptied to a sentence and
  ## refilled on almost every step. That is the flicker a visitor reported.
  ##
  ## The state is not wrong, so it must not be removed; the pane genuinely does
  ## not have those values yet, and showing the previous position's under the new
  ## one is the confident wrong answer this route exists to not give. What is
  ## wrong is PAINTING a state that a newer one replaces before anyone could
  ## read it. Coalescing to the frame says exactly that and nothing more: writes
  ## that arrive within one frame produce one paint, and the last one wins.
  ##
  ## ## AND WHY ONE FRAME IS NOT ENOUGH
  ##
  ## Coalescing alone took the flash from one-to-three frames down to exactly
  ## one, and no further: 13 ms and 16.7 ms are close enough that the position
  ## lands in frame N and its values in frame N+1, every time. One painted frame
  ## of a pane emptying and refilling is still a flicker — it is the definition
  ## of one.
  ##
  ## So the paint also waits, briefly and with a bound, for the move to settle.
  ## `PositionSettleFrames` is that bound and `live_locals.settlingPosition` is
  ## the question.
  ##
  ## THIS MAKES THE PAGE MORE HONEST RATHER THAN LESS, which is worth being
  ## precise about, because deferring a paint sounds like hiding something.
  ## What was painted in that one frame was a MIXED state: the new position's
  ## line marked, the new step in the toolbar, and no values, because the values
  ## had not arrived. The page was internally inconsistent for a frame. Waiting
  ## means every painted frame is a whole position — either all of A or all of
  ## B, never the head of one and the body of the other. Nothing is shown that
  ## is not true, and nothing true is withheld: the §6.3 coordinate is composed
  ## at the stop and published BY this paint (`pendingQuery`), so the address
  ## bar names the position on screen rather than one the screen has not
  ## reached.
  ##
  ## And it hides no wait. Past the bound the panes are painted exactly as they
  ## always were, "Reading the values at this position…" and all, because a wait
  ## that long is one a visitor is entitled to see. The rule is "do not paint
  ## what you are about to overwrite" — the same rule `writePane` applies one
  ## level down, there across frames and here within a move.
  ##
  ## `stopped` is re-checked INSIDE the callback and not only at the call sites.
  ## A scheduled paint outlives the moment it was asked for, so a session that
  ## fails between the request and the frame would otherwise repaint a live
  ## toolbar over the sentence saying the engine is gone — the same hazard
  ## `goLive`'s `onApplied` guards against, arriving one frame later.
  ##
  ## ## THE FIRST PAINT DOES NOT WAIT, AND THAT IS NOT AN EXCEPTION
  ##
  ## Everything above is about not disturbing what is already on screen. At the
  ## FIRST paint of a live session there is nothing of the session's on screen
  ## to disturb: what a visitor is looking at is the served frame, and §7.0
  ## wants it replaced as early as the engine can answer, not as late. A wait
  ## there buys no smoothness and costs the one thing it must not — `goLive`
  ## publishes `ready` before this runs, so every frame of the wait is a page
  ## that says it is a live session and still shows the exported one. Journey 09
  ## found exactly that, by taking its reading the instant the page called
  ## itself ready.
  ##
  ## ## WHY THIS IS A SECOND ENTRY POINT AND NOT A FLAG INSIDE `render`
  ##
  ## The first version deferred EVERY paint, and two journeys that had nothing
  ## to do with stepping went red: the chain capture's navigation regions read
  ## as empty, and a click on a row landed on an element the deferred paint had
  ## replaced ("not attached to the DOM"). Both were right to fail. A call-trace
  ## section arriving is not a move — there is no half-updated position to
  ## protect — so making the page paint it a frame later bought nothing and made
  ## every reading of the page a race.
  ##
  ## The wait is for the ONE case that needs it: `applyStop` has the position and
  ## the values are a round trip behind it, and painting between the two shows a
  ## frame in which the page contradicts itself. Everything else — the locals
  ## reply, the call trace, the event log — paints through `render`, immediately
  ## and synchronously, exactly as it always did.
  ##
  ## And the wait usually ends early rather than expiring. The locals reply calls
  ## `render` on its way in, `settlingPosition` is false by then, and the paint
  ## happens there — position and values in one synchronous call. The frame this
  ## proc scheduled still fires and paints again; `writePane` finds every pane
  ## already saying what it would write and does nothing, which is the guard one
  ## level down paying for itself.
  if not h.everPainted:
    h.everPainted = true
    h.paint()
    return
  if h.framePending: return
  h.framePending = true
  h.framesWaited = 0
  h.paintWhenSettled()

proc paintWhenSettled(h: Hydration) =
  ## The scheduled half of `renderAfterMove`. Re-arms itself while the move is
  ## still settling, up to `PositionSettleFrames`, then paints.
  onNextFrame(proc() =
    if h.stopped:
      h.framePending = false
      return
    if h.session.locals.settlingPosition() and
       h.framesWaited < PositionSettleFrames:
      inc h.framesWaited
      h.paintWhenSettled()
      return
    h.framePending = false
    h.paint())

proc fail(h: Hydration; reason: string) =
  ## Give up, and say so on the controls.
  ##
  ## Idempotent through `h.live`: several failures can arrive for one cause —
  ## a worker error, then every pending request settling failed — and the
  ## visitor must be told once. Once the session HAS gone live, a later failure
  ## does not roll the panes back to the served frame: they hold the last
  ## position the engine reached, which is a real frame of this trace and is
  ## strictly more than the pre-hydration page had.
  h.stopped = true
  if h.live:
    for b in h.ui.controls.querySelectorAll(".dcbtn"):
      b.classList.add("off")
      b.setAttribute("aria-disabled", "true")
      b.setAttribute("title", reason.cstring)
    return
  markUnavailable(h.ui, reason)

proc gotoTicks(h: Hydration; ticks: int; onRefused: proc() = nil;
               onSettled: proc() = nil)
  ## Forward-declared for ONE caller: the `ct/notification` branch of
  ## `onDapEvent`, which has to seek the session back to where a fruitless
  ## continue started. The event handler is necessarily defined before the
  ## commands it reacts to, and moving `gotoTicks` above it would put the
  ## seek primitive above `applyStop`, which it uses.

proc applyStop(h: Hydration; ticks: uint64; file: string; line: int) =
  ## One stop: the store's position, the URL's coordinate, and the panes.
  ##
  ## The store is the seam — everything the five ViewModels expose is a memo
  ## over it, so writing the position here is what moves the source pane, the
  ## call trace's auto-loaded section and the values, in that one call. This is
  ## the same entry point `MockBackendService` drives in `tests/tdebugpanes
  ## .nim`, which is why that suite is evidence about this path.
  #
  # §10.8'S SENTENCE IS NOT CLEARED HERE, and that is a correction rather than
  # an omission. It was, once, guarded by a "this stop is the restoring seek"
  # flag — and the flag was consumed by the WRONG stop: a fruitless continue
  # produces two stops (the engine's jump to the end, then the seek back), the
  # `ct/notification` that sets the sentence races the `stackTrace` that
  # reports the first of them, and when the notification won, the flag was
  # spent on the jump and the sentence was erased by the seek that restored the
  # position it was explaining. Measured: the position came back to step 7
  # correctly and the message was gone.
  #
  # An outcome belongs to a GESTURE, so it is cleared by the next gesture —
  # `invoke` and the navigation rows — and never by a stop, of which one
  # gesture can produce several in an order this file does not control.
  h.session.applyPosition(ticks, file, line)
  # §6.3: "`t` updates on **every** navigation via `history.replaceState`".
  # The COORDINATE, so a share link from a hydrated session lands where the
  # session is rather than where it was served.
  #
  # The WHOLE payload, not `t` alone. It used to write `?t=128`, which this
  # product's own reader now — correctly — treats as unverifiable: §6.0a
  # requires `c` wherever `t` appears, and §6.3 requires a share to carry an
  # anchor. So a visitor who copied the address bar after stepping got a link
  # that would land at the start of the execution and say so, which is a true
  # sentence about a link we had no reason to emit. `c` is the artifact's
  # witness and `a` is a `src:` anchor for the line the session is ON — both
  # recomputed here, because an anchor left at the position the page was
  # served at would recover a regenerated trace to the wrong frame.
  #
  # COMPOSED HERE, PUBLISHED BY THE PAINT. See `Hydration.pendingQuery`: the
  # path and the line are in hand at the stop and nowhere else, but the address
  # bar must not name a position the screen is not yet showing.
  h.pendingQuery = positionQuery(h.base.traceContentHash, int(ticks),
    (if file.len > 0 and line > 0: "src:" & file & ":" & $line else: ""))
  h.renderAfterMove()

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
    # The intent: the engine states the whole position here, so one message
    # replaces a round trip (Debugger-Integration §7 gives a whole navigation
    # 50 ms) and the tick arrives with it — a DAP stack frame has none, so a
    # session positioned from `stackTrace` alone reported `?t=0` for every step
    # it ever took. It did.
    #
    # DO NOT "FIX" THIS BY RENAMING THE KEY. Against the engine actually
    # published at `/replay-engine/`, this branch NEVER FIRES, and that is
    # load-bearing rather than a latent bug. Read off the wire on 2026-09-01,
    # every `ct/complete-move` body carries `cLocation` — not `location` — and
    # its every field is the zero value: `path: ""`, `line: 0`, `rrTicks: 0`.
    # (The wasm's own struct table spells it `…statuscLocationmainresetFlow
    # stopSignalframeInfoeventLogIndex…`; there is no `location` beside it.)
    #
    # So the lookup below misses, this returns, and the position arrives
    # instead through `stopped` -> `requestPosition` -> `stackTrace`. Point the
    # lookup at `cLocation` and `applyStop(0, "", 0)` runs on every move: the
    # session is thrown to tick 0 and the mark is cleared, which is precisely
    # the symptom a visitor reported this file being read for.
    #
    # The tick is NOT lost by taking the fallback, which is why nothing here
    # needs changing: `ReplayDataStore` reads `cLocation` itself, so the store
    # already holds the right `rrTicks` by the time `requestPosition` asks the
    # frame for a path and a line. Journey `a-jump-moves-the-position` asserts
    # the outcome end to end and is what would notice if that stopped being
    # true. Restore this as the primary path when the engine publishes a
    # populated position, and not before.
    let body = (if event.hasKey("body"): event["body"] else: event)
    let loc = body{"location"}
    if loc == nil or loc.kind != JObject: return
    h.applyStop(uint64(max(0, loc{"rrTicks"}.getInt(0))),
                loc{"path"}.getStr(""), loc{"line"}.getInt(0))
  of "stopped":
    # DAP's own stop event carries a reason and a thread and no location, so
    # the position has to be asked for. Written as the fallback and, against
    # today's published engine, the path every move actually takes — see the
    # branch above for why that is deliberate and what breaks if it is
    # "corrected".
    h.requestPosition()
  of "ct/notification":
    # THE ENGINE SAYING A CONTINUE REACHED NOTHING.
    #
    # `dap_handler.step_continue` sends exactly this when its traversal ran off
    # the end of the recording without matching a breakpoint:
    #
    #     if !hit_breakpoint {
    #         self.send_notification(NotificationKind::Info,
    #                                "No breakpoints were hit!", false, sender)?;
    #     }
    #
    # It is matched on a SUBSTRING of the engine's own wording, which is a real
    # coupling and is the narrowest one available: the reply carries no
    # structured "hit a breakpoint" field, so the alternative is to infer it
    # from the position landing on the last step — which is indistinguishable
    # from a breakpoint that genuinely sits on the last step.
    #
    # A wording change upstream therefore turns this branch off. It fails in
    # the SAFE direction — the session runs to the end, exactly as it did
    # before this feature — and `07-continuing-stops-at-a-breakpoint`'s
    # no-breakpoint arm is what notices, because it asserts the position is
    # unchanged rather than that a sentence appeared.
    if not h.continueAwaiting: return
    h.continueAwaiting = false
    let body = (if event.hasKey("body"): event["body"] else: event)
    let message = body{"message"}.getStr("") & body{"text"}.getStr("")
    if not message.contains("No breakpoints were hit"): return
    h.continueOutcome = h.continueMissMessage
    # §10.8: "rather than running to the end of the recording and stopping
    # there, which reads as a jump the visitor did not ask for". The engine has
    # already jumped, so being unchanged means going back.
    h.gotoTicks(int(h.continueFrom))
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
  ##
  ## CONTINUE IS THE ONE ACTION WITH AN OUTCOME OF ITS OWN. §10.8 requires that
  ## a continue with nothing to reach says so and leaves the position alone,
  ## which is not what the engine does on its own: `step_continue` runs to the
  ## end of the recording and then reports that it hit nothing. So the two
  ## continue actions are bracketed here — where they start is remembered, and
  ## `onDapEvent`'s `ct/notification` branch undoes the jump if there was one.
  # A new gesture retires the last one's outcome. Done for EVERY action, and
  # first, so the two continue branches below can set it without racing their
  # own clear — see `applyStop` for why this cannot live on the stop instead.
  #
  # AND IT IS REPAINTED IMMEDIATELY. Clearing the field alone left the sentence
  # on screen until the next stop arrived, which for a move that takes a round
  # trip is hundreds of milliseconds of a banner saying the session did not
  # move while it is moving. Worse, a move that ends in the SAME outcome would
  # never repaint at all, so "no breakpoint ahead" would sit unchanged across a
  # gesture and read as stale rather than as freshly true.
  if h.continueOutcome.len > 0:
    h.continueOutcome = ""
    h.render()
  if action in {daContinue, daReverseContinue}:
    let forward = action == daContinue
    # THE EMPTY SET IS SHORT-CIRCUITED AND NEVER SENT. Not an optimisation:
    # with no breakpoints at all the engine would run the whole recording and
    # then be seeked back, so the visitor would SEE the jump this section
    # exists to prevent. Answering here costs no round trip and cannot flicker.
    if h.breakpoints.isEmpty():
      h.continueOutcome =
        if forward: "No breakpoints are set, so there is nothing ahead to continue to."
        else: "No breakpoints are set, so there is nothing before here to continue back to."
      h.render()
      return
    h.continueFrom = h.session.store.debugger.val.rrTicks
    h.continueAwaiting = true
    h.continueMissMessage =
      if forward: "No breakpoint ahead of here — the session has not moved."
      else: "No breakpoint before here — the session has not moved."
  else:
    # Any other move settles a pending continue's bookkeeping: its outcome is
    # about a position the session is leaving.
    h.continueAwaiting = false
  h.session.controls.invokeToolbarStep(toolbarActionId(action))

proc gotoTicks(h: Hydration; ticks: int; onRefused: proc() = nil;
               onSettled: proc() = nil) =
  ## A row in the navigation region, clicked — or the coordinate a deep link
  ## resolved to.
  ##
  ## Debugger-Integration §3's deferred item, and §4.2's "single most valuable
  ## interaction in the product — 'take me to the line that wrote this
  ## value'". `ct/goto-ticks` is the engine's own primitive for it and it emits
  ## a `ct/complete-move` for the target tick, so the position arrives back
  ## through the same event path a step does. No new protocol, exactly as §3
  ## says none is needed.
  ##
  ## `onRefused` exists for the deep-link caller and for nothing else. A row
  ## click that the engine refuses leaves the session where it was, which is
  ## correct and needs no fallback; a REFUSED deep-link seek would otherwise
  ## leave the panes frozen at the served frame with no live position at all,
  ## because the seek replaces the `stackTrace` that would have fetched one.
  ##
  ## `onSettled` exists for the scrubber, and it fires on BOTH outcomes —
  ## answered and errored — because it is what releases the drag's one in-flight
  ## slot. A hook that only ran on success would wedge the slot closed on the
  ## first refusal and leave the rest of the drag painting a handle the session
  ## never followed: the handle would keep moving, the session would not, and
  ## the control would be back to being an animation. This is the ONE sender of
  ## `ct/goto-ticks` in the bundle and it stays that way — the drag is a new
  ## gesture on the existing capability, not a second path to it.
  h.service.send("ct/goto-ticks", %*{"threadId": 1, "ticks": ticks}).onComplete(
    onSuccess = proc(response: JsonNode) =
      if onSettled != nil: onSettled()
      if not response{"success"}.getBool(true):
        # The engine refused the jump. Nothing moves and nothing pretends to;
        # the row stays a row and the session stays where it was.
        if onRefused != nil: onRefused()
        return,
    onError = proc(message: string) =
      if onSettled != nil: onSettled()
      h.fail("The replay engine stopped answering: " & message))

proc scrubSend(h: Hydration; step: int)

proc scrubDrain(h: Hydration) =
  ## Fill the slot again, now that it is free.
  ##
  ## The decision is `scrub_queue.drain`'s and not this proc's — see that
  ## module for why it re-reads the pending target instead of being handed one,
  ## and for the drag that ended at step 707 when it was handed one. All this
  ## does is turn its answer into a request.
  h.scrubSend(h.scrubQ.drain())

proc scrubSend(h: Hydration; step: int) =
  ## Put `step` on the wire, if the queue said to.
  ##
  ## `0` is the queue's "nothing to send" and is the common answer: during a
  ## fast drag most pointer positions are superseded before they are ever
  ## asked for, which is the entire point of the coalescing.
  if step <= 0: return
  h.gotoTicks(step, onSettled = proc() =
    h.scrubQ.settled()
    # DEFERRED, and carrying nothing. `deferTick` says why the send waits for
    # the next turn of the loop; `scrub_queue.drain` says why what it sends is
    # decided then rather than now.
    deferTick(proc() = h.scrubDrain()))

proc scrubSeek(h: Hydration; step: int) =
  ## The visitor is asking for `step`; send it now, or supersede what waits.
  ##
  ## The throttle is clocked by the engine rather than by a number, and the
  ## rule lives in `debugger/scrub_queue.nim`. Because the pending slot is
  ## overwritten rather than appended to, the release path needs no special
  ## case: committing the drop point is just one more `scrubSeek`, which either
  ## goes out immediately or replaces the last intermediate target. The gesture
  ## therefore ENDS at the step the visitor let go on, whatever the engine was
  ## doing at the time — which is the property the journey asserts, because
  ## "the handle stopped there" would be true of a decoration.
  h.scrubSend(h.scrubQ.request(step))

proc sendBreakpoints(h: Hydration; path: string) =
  ## Tell the engine the breakpoints for ONE file.
  ##
  ## The whole per-path set goes every time, because that is what the command
  ## means: `dap_handler.set_breakpoints` clears the source's breakpoints
  ## before registering the request's lines, so a request naming one line makes
  ## that line the only breakpoint in the file. Sending a delta would delete
  ## every other mark in the gutter and leave them painted.
  ##
  ## The reply is read only to notice a refusal. A breakpoint the engine
  ## declined is not a breakpoint, and leaving its mark in the gutter would
  ## promise a stop that will never happen — so a refusal drops the lines the
  ## engine did not verify and repaints.
  h.service.send("setBreakpoints", h.breakpoints.requestFor(path)).onComplete(
    onSuccess = proc(response: JsonNode) =
      if not response{"success"}.getBool(true): return
      let verified = response{"body"}{"breakpoints"}
      if verified == nil or verified.kind != JArray: return
      # `verified: false` is the engine saying "there is no code at that line".
      # Measured on the `noir_space_ship` fixture the engine verifies every
      # line of a file it knows — including lines with no steps — so this arm
      # is defensive rather than routine, and it is written to be total: a
      # reply that carries no `verified` key at all leaves the set untouched
      # rather than clearing the gutter on a shape it did not recognise.
      var refused: seq[int] = @[]
      for b in verified:
        if b.kind != JObject: continue
        if b.hasKey("verified") and not b{"verified"}.getBool(true):
          let line = b{"line"}.getInt(0)
          if line > 0: refused.add line
      if refused.len == 0: return
      for line in refused:
        if h.breakpoints.contains(path, line):
          discard h.breakpoints.toggle(path, line)
      h.render(),
    onError = proc(message: string) = h.fail(
      "The replay engine stopped answering: " & message))

proc restoreBreakpoints(h: Hydration) =
  ## Re-arm the engine with whatever breakpoints this page starts with.
  ##
  ## TODAY THIS SENDS NOTHING, and that is correct rather than unfinished:
  ## `loadBreakpoints` returns an empty set because §10.8 leaves persistence
  ## explicitly open, so a fresh document has no marks to re-arm.
  ##
  ## It is kept, and called, because the engine is a NEW worker on every load
  ## and knows nothing about a set restored on the page side. The moment
  ## persistence is decided, a restored gutter without this call would show
  ## marks that Continue ignores — which is the worst of the three possible
  ## states, because it is the only one that looks like it works. Wiring the
  ## seam now means the decision is a change to one function rather than a
  ## change to one function plus a defect nobody predicted.
  for path in h.breakpoints.paths():
    if h.breakpoints.linesFor(path).len > 0:
      h.sendBreakpoints(path)

proc toggleBreakpoint(h: Hydration; path: string; line: int) =
  ## One gutter click, all the way through.
  if path.len == 0 or line <= 0: return
  discard h.breakpoints.toggle(path, line)
  # Painted BEFORE the round trip and not after. The mark is a statement about
  # what this page will ask the engine to do, and it is true the moment the
  # visitor clicks; waiting for the reply would put a click's worth of latency
  # between the gesture and its acknowledgement on the one control whose whole
  # purpose is to be aimed precisely. `sendBreakpoints` repaints if the engine
  # refuses.
  h.render()
  h.sendBreakpoints(path)

proc onMac(): bool {.importjs: """
(function(){
  // Whether the function row is a media row by default.
  //
  // `navigator.platform` is deprecated and `userAgentData` is Chromium-only,
  // so both are consulted and either answer is accepted. Getting this wrong is
  // cheap in one direction and not the other: a false positive prints a
  // hazard sentence about a Mac to somebody who is not on one, and a false
  // negative hides it from somebody who is. So the test is deliberately
  // GENEROUS — it is used only to decide whether to warn.
  try {
    var d = navigator.userAgentData;
    if (d && d.platform) return /mac/i.test(d.platform);
  } catch (_) {}
  return /Mac|iPhone|iPad|iPod/i.test(navigator.platform || navigator.userAgent || "");
})()
""".}

proc chordOf(ev: Event): Chord =
  ## The key press, as the table spells one.
  ##
  ## `$keyName(ev)` and not `keyName(ev)` — see `keyName`'s note. The `$` is
  ## the whole difference between a working keyboard and a silently dead one
  ## on this backend, and it is written here rather than inside `keyName`
  ## because the scrubber's handler converts at its own call site too.
  ##
  ## SHIFT IS DROPPED FOR SINGLE CHARACTERS, which is the other half of the
  ## rule `Chord` documents. The browser reports Shift+n as `key == "N"`, so
  ## the shift bit is already IN the key and recording it again would make the
  ## event match nothing — `Chord(key: "N", shift: true)` is not in any table.
  ## Function keys carry a `key` that Shift does not change, so there the bit
  ## is the only thing distinguishing forward from backward and is kept.
  let k = $keyName(ev)
  let singleChar = k.len == 1
  Chord(key: k,
        shift: (if singleChar: false else: shiftHeld(ev)),
        ctrl: ctrlHeld(ev), alt: altHeld(ev), meta: metaHeld(ev))

proc canAct(h: Hydration; action: DebugAction): bool =
  ## Is this move offered right now?
  ##
  ## READ OFF THE RENDERED BUTTON, not off the ViewModel, and deliberately.
  ## The pointer path already decides this by asking the DOM — the click
  ## handler's `if btn.classList.contains("off"): return` — and a keyboard path
  ## that consulted `canDo(vm, a)` instead would be a SECOND opinion about
  ## whether a control is live. Two opinions is how a key comes to fire a move
  ## the toolbar is showing as inert, which reads as the toolbar lying.
  ##
  ## So both gestures ask the same question of the same element, and a control
  ## that is grey to the eye is dead to the key by the same fact.
  let btn = h.ui.controls.querySelector(
    (".dcbtn[data-action=\"" & $action & "\"]").cstring)
  btn != nil and not btn.classList.contains("off")

proc shortcutsDialog(h: Hydration): Element =
  h.ui.root.querySelector("#dbg-shortcuts")

proc paintShortcuts(h: Hydration) =
  ## Redraw the dialog's contents from the keymap in force.
  ##
  ## Called when the preset changes and NOT on every step. The dialog is
  ## outside `.dc`, which `setControls` replaces on every stop — so an open
  ## dialog survives stepping, and a visitor can press a key and watch the
  ## session move without the thing that told them the key closing itself.
  let dlg = h.shortcutsDialog()
  if dlg == nil: return
  let open = not dlg.hasAttribute("hidden")
  dlg.outerHTML = panes.renderShortcutsDialog(h.keymap, onMac()).cstring
  if open:
    let again = h.shortcutsDialog()
    if again != nil: again.removeAttribute("hidden")

proc applyKeymap(h: Hydration; id: KeymapId) =
  ## Adopt a preset: in the table, on the page, and in storage.
  ##
  ## THE ORDER IS THE POINT. The keymap is set first, so that everything
  ## redrawn afterwards is redrawn from it — the tooltips through
  ## `renderControls`, the rows through `renderShortcutsDialog`. A save that
  ## failed would leave the visitor with the preset they asked for for the rest
  ## of the visit, which is the right failure: the store is best-effort by
  ## construction (`live_preferences`) and the session is not.
  h.keymap = keymapOf(id)
  var p = h.prefs.load()
  p.keymap = id
  h.prefs.save(p)
  # The toolbar, so the tooltips name the new keys immediately rather than at
  # the next step. `renderControls` reads the keymap it is handed, so this is
  # the same re-render a step performs and not a special path.
  let dc = h.ui.controls.querySelector(".dc")
  if dc != nil:
    dc.replaceWith(panes.renderControls(
      projectReplayPanes(h.session, h.base, h.ui.island).controls,
      h.keymap).cstring)
  h.paintShortcuts()

proc setShortcutsOpen(h: Hydration; open: bool) =
  let dlg = h.shortcutsDialog()
  if dlg == nil: return
  if open: dlg.removeAttribute("hidden") else: dlg.setAttribute("hidden", "hidden")
  let opener = h.ui.root.querySelector("#dbg-shortcuts-open")
  if opener != nil:
    opener.setAttribute("aria-expanded",
                        (if open: cstring"true" else: cstring"false"))
    # Focus returns to the control that opened the dialog when it closes.
    # Without this a keyboard visitor who closes the dialog is returned to the
    # top of the document, which on this page means scrolling back past four
    # panes to reach the toolbar they were using.
    if not open: opener.focus()

proc bindShortcuts(h: Hydration) =
  ## The chords, the gear, and the dialog that says what is bound.
  ##
  ## ## THE GEAR IS INSERTED HERE, which is what keeps the promise
  ##
  ## `pages/debug.nim` renders `.dbgacts` with Share and Download. This adds a
  ## third control to that group, from the bundle, at the moment the bundle
  ## also binds its behaviour. The served page therefore has no gear — because
  ## it has no dialog, no `localStorage` write and no chords, and a settings
  ## control on it would be a control that cannot succeed.
  ##
  ## ## AND THE KEY LISTENER IS ON `document`, which is new ground here
  ##
  ## Every other listener in this file is delegated on a container, because
  ## `renderPanes` replaces pane bodies. A stepping chord is not a gesture ON
  ## anything — a visitor reading the call trace and pressing `n` is asking the
  ## session to step, not asking the call trace for something — so it is bound
  ## once on `document` and survives every re-render for free.
  ##
  ## That is only safe because of two guards, and both are refusals rather
  ## than filters:
  ##
  ##   * `isTypingTarget` — the site-wide search box is on this page.
  ##   * a modifier the chord does not ask for is a MISMATCH, not an
  ##     approximation. `Ctrl+n` opens a window; it must not also step. This
  ##     falls out of `Chord`'s `==` comparing all four bits, so it needs no
  ##     code here — but it is the reason `==` is total rather than a subset
  ##     test, and a later "be lenient about modifiers" would break it.
  let acts = h.ui.root.querySelector(".dbgacts")
  if acts != nil and h.ui.root.querySelector("#dbg-shortcuts-open") == nil:
    acts.insertAdjacentHTML("beforeend", panes.renderShortcutsButton().cstring)
  if h.shortcutsDialog() == nil:
    h.ui.root.insertAdjacentHTML(
      "beforeend", panes.renderShortcutsDialog(h.keymap, onMac()).cstring)

  # Delegated on the root, so the dialog can be replaced wholesale by
  # `paintShortcuts` without the handlers going with it.
  h.ui.root.addEventListener("click", proc(ev: Event) =
    let hit = closestFrom(ev, "[data-kb]")
    if hit == nil: return
    case attr(hit, "data-kb")
    # TOGGLE, AND THE SENSE OF IT IS THE BUG THIS LINE ONCE HAD.
    #
    # `hidden` is present when the dialog is CLOSED, so "should it now be
    # open?" is `hasAttribute("hidden")` and not its negation. The negated
    # form — which is what shipped first — asked "is it already open?" and
    # answered `false` on a closed dialog, so the gear closed an already
    # closed dialog and the shortcuts surface could not be opened at all.
    #
    # It is worth naming because nothing else could see it: the dialog was
    # rendered, correct, and complete in the DOM the whole time, so every
    # assertion about its CONTENTS passed over a dialog no visitor could
    # reach. Journey 20 is what caught it, by asserting the state of the
    # element after the click rather than the markup inside it.
    of "open": h.setShortcutsOpen(h.shortcutsDialog().hasAttribute("hidden"))
    of "close": h.setShortcutsOpen(false)
    else: discard)

  # `change` and not `click`, so that a preset selected with the arrow keys —
  # which is how a radio group is operated from the keyboard, and this is a
  # dialog about the keyboard — takes effect the same way a click does.
  h.ui.root.addEventListener("change", proc(ev: Event) =
    let hit = closestFrom(ev, "input[data-kb=\"preset\"]")
    if hit == nil: return
    h.applyKeymap(parseKeymapId(attr(hit, "value"))))

  document.addEventListener("keydown", proc(ev: Event) =
    # Escape closes the dialog before anything else looks at the key, because
    # a visitor who has opened a dialog and pressed Escape is asking for the
    # dialog to go away and not for the session to do anything.
    if $keyName(ev) == "Escape":
      if h.shortcutsDialog() != nil and
         not h.shortcutsDialog().hasAttribute("hidden"):
        ev.preventDefault()
        h.setShortcutsOpen(false)
      return
    if isTypingTarget(ev): return
    # A held key is one gesture, not forty. See `isRepeat`.
    if isRepeat(ev): return
    let (found, action) = h.keymap.actionFor(chordOf(ev))
    if not found: return
    # THE ENABLED CHECK IS BEFORE `preventDefault`, deliberately. A chord for a
    # move this session cannot make is not this page's key: the visitor gets
    # whatever their browser does with it, rather than a keystroke that
    # vanishes into a handler which then declines to act. A key that silently
    # does nothing is the exact experience §10.5 says teaches a visitor that
    # the shortcuts do not work.
    if not h.canAct(action): return
    ev.preventDefault()
    h.invoke(action))

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
      # WHICH FRAME, before WHERE IN TIME. The row carries both and only one of
      # them identifies it: on the published transaction forty-six frames carry
      # twenty-two distinct steps, and the six that run
      # `Map::at` → `derive_storage_slot_in_map` → `poseidon2_hash_with_separator`
      # → `poseidon2_hash` → `Poseidon2::hash` → `Poseidon2::hash_internal` are
      # all open at step 59. A click carrying only the coordinate sends all six
      # to one place and leaves the pane unable to say which was asked for —
      # which is what it did, and why no row came back marked.
      #
      # `data-anchor` is the §6.0a call path. It has been rendered on every row
      # since the anchors landed, both producers compute it from the same
      # function, and it is in the row's own href — it was present, correct and
      # read by nothing at the moment it was needed. This is that moment.
      #
      # The seek below still happens, and still happens on EVERY row. Selecting
      # a frame says which one the reader means; it does not move the session,
      # and a row whose anchor the live window does not hold must still take the
      # visitor to its coordinate rather than becoming inert.
      #
      # Called for EVERY navigation row and not only for a call-trace one. An
      # event-log row and a flow segment name no frame, and the answer to "which
      # frame did the reader choose" after clicking one is "none" — which is a
      # real answer and has to be written, or the mark from the last call-trace
      # click would sit there describing a frame the reader has left.
      discard h.session.selectCalltraceFrame(attr(row, "data-anchor"))
      # The row IS a link in a hydrated page, and its href is a real, valid
      # §6.0a URL — which is what makes middle-click, "open in new tab" and
      # copy-link-address all work, and what makes Enter activate it without a
      # `keydown` handler here. What must not happen is the FULL NAVIGATION on
      # an ordinary click: the session is already open at the right trace, and
      # reloading it to move one frame would refetch an 18 MB engine to arrive
      # where a `ct/goto-ticks` gets in a millisecond.
      #
      # Cancelled only when the jump is actually taken. A modified click —
      # new tab, new window, download — is left to the browser, because the
      # visitor asked for the navigation rather than for the seek.
      if not isPlainActivation(ev): return
      ev.preventDefault()
      # A row click is a gesture, so it retires the last continue's outcome —
      # see `invoke`. Without this the sentence would sit over a session the
      # visitor had since navigated somewhere else entirely.
      h.continueOutcome = ""
      h.continueAwaiting = false
      try: h.gotoTicks(parseInt(step)) except CatchableError: discard)

  h.ui.controls.addEventListener("click", proc(ev: Event) =
    let btn = closestFrom(ev, ".dcbtn")
    if btn == nil: return
    if btn.classList.contains("off"): return
    let wire = attr(btn, "data-action")
    for a in DebugAction:
      if $a == wire: h.invoke(a))

  # "Where did this value come from" — delegated on the State pane's body for
  # the reason every other row handler is: `renderPanes` replaces that body on
  # every stop, and a listener bound to a button would be dropped by the first
  # step the visitor took.
  #
  # The button only exists on a row whose origin the engine actually
  # classified (`projectState`), so this handler cannot be reached for a value
  # that has no chain — which is what keeps "the control is offered" and "the
  # control can answer" the same claim.
  h.ui.state.addEventListener("click", proc(ev: Event) =
    let btn = closestFrom(ev, ".storigin")
    if btn == nil: return
    let name = attr(btn, "data-name")
    if name.len == 0: return
    if not isPlainActivation(ev): return
    ev.preventDefault()
    # `onShowOrigin` issues `ct/originChain` and discards the future; the
    # reply is read by `withLiveOrigin` on the way back. The location is the
    # session's own — the value is being asked about where it is being shown.
    h.session.originChain.onShowOrigin(
      name, h.session.store.debugger.val.location,
      int64(h.session.store.debugger.val.rrTicks)))

  # THE BREAKPOINT GUTTER. Delegated on the editor pane's body for the reason
  # every other handler here is: `renderPanes` replaces that body on every
  # stop, so a listener bound to a line number would be dropped by the first
  # step the visitor took — and this is the one control where that failure
  # would be invisible, because the marks would still be painted.
  #
  # The path comes from the DOCUMENT and the line from the ROW, which is why
  # `data-path` exists on `.srcdoc` at all: the engine has to be told the file
  # exactly as the trace interned it, and the document's `id` is a mangled,
  # non-invertible anchor (`components/debugger.renderSource`).
  proc gutterTarget(ev: Event): (string, int) =
    let cell = closestFrom(ev, ".srcline .n[role='button']")
    if cell == nil: return ("", 0)
    let row = closestOf(cell, ".srcline")
    let doc = closestOf(cell, ".srcdoc")
    if row == nil or doc == nil: return ("", 0)
    (attr(doc, "data-path"), intAttr(row, "data-line"))

  h.ui.editor.addEventListener("click", proc(ev: Event) =
    let (path, line) = gutterTarget(ev)
    if line == 0: return
    # A modified click is the visitor asking the BROWSER for something and is
    # left alone, the same rule the navigation rows follow.
    if not isPlainActivation(ev): return
    ev.preventDefault()
    h.toggleBreakpoint(path, line))

  # The keyboard half of the same control — see `activationKey`. Space is
  # cancelled because its default action scrolls the pane, which would move the
  # listing out from under the line the visitor just marked.
  h.ui.editor.addEventListener("keydown", proc(ev: Event) =
    if not activationKey(ev): return
    let (path, line) = gutterTarget(ev)
    if line == 0: return
    ev.preventDefault()
    h.toggleBreakpoint(path, line))

  # ── THE SCRUBBER ───────────────────────────────────────────────────────
  #
  # "The slider in the very top can be slidable." It is a scrubber, it always
  # looked like one, and the seek it needs has existed since `ct/goto-ticks`
  # landed — so this binds a gesture to a capability rather than building one.
  # It goes through `scrubSeek` -> `gotoTicks`, the same sender a row click and
  # a deep link use, for the reason `invoke` refuses to hand-build a DAP
  # request: a second path to one move is the arrangement where the two drift
  # and only one of them is ever tested.

  proc trackNow(): Element = h.ui.controls.querySelector(".dctl.seekable")
    ## Re-queried per event, never held. `setControls` replaces `.dc` wholesale
    ## on every stop, so the `.dctl` a drag started on is destroyed by the first
    ## seek that drag issues. A cached handle would be a stale node from the
    ## first answered move onward — the gesture would go on running and stop
    ## reaching anything, which is exactly the failure this whole file's
    ## delegation rule exists to prevent, in the one place where it happens
    ## mid-gesture instead of between them.

  proc totalNow(): int = intAttr(h.ui.root, "data-total-steps")
    ## The denominator, read from where the SESSION publishes it. `renderPanes`
    ## writes it on every render, so the gesture and the page cannot disagree
    ## about how long the trace is — and a scrubber that mapped a pointer
    ## against its own copy of that number is how a handle comes to be at 40%
    ## of one thing and the session at 40% of another.

  proc stepUnderPointer(track: Element; x: float): int =
    let w = trackWidth(track)
    if w <= 0.0: return 0
    let p = DebugControlsPane(totalSteps: totalNow(), positioned: true)
    p.stepAtFraction((x - trackLeft(track)) / w)

  proc scrubTo(step: int) =
    ## Paint now, ask the engine as fast as it will answer.
    if step <= 0: return
    h.scrubTarget = step
    paintScrubber(h.ui, step, totalNow())
    h.scrubSeek(step)

  h.ui.controls.addEventListener("pointerdown", proc(ev: Event) =
    let track = closestFrom(ev, ".dctl.seekable")
    if track == nil: return
    if not isPrimaryDrag(ev): return
    # Cancelled so the press does not begin a text selection across the bar —
    # a drag that selects the step counter on its way past is the browser and
    # the control both acting on one gesture.
    ev.preventDefault()
    # `preventDefault` above suppresses the text selection AND the focus the
    # press would otherwise have moved here, so the focus is put back by hand.
    # Without it the slider is reachable by Tab and not by the gesture everyone
    # actually uses to reach it: a visitor who drags the handle and then presses
    # an arrow key would find the keys doing nothing, having just demonstrated
    # to themselves that the control works.
    track.focus()
    h.scrubbing = true
    track.classList.add("scrubbing")
    # CAPTURED ON `.dbgctl`, NOT ON THE TRACK, and this is the load-bearing
    # line of the drag. `setControls` replaces `.dc` — and `.dctl` inside it —
    # on every stop, so a capture taken on the track is released by the browser
    # the instant the first seek is answered, roughly 46 ms into the gesture.
    # The drag would end there, having moved once, which is very close to the
    # defect being fixed and would have been reported as "it only jumps".
    # `.dbgctl` is the served element hydration writes INTO and never replaces.
    capturePointer(h.ui.controls, pointerIdOf(ev))
    # THE PRESS SEEKS. See the `scrubbing` field block: a click on the track is
    # a press and a release at one point, so making the press act is what makes
    # a bare click seek there, with no second code path to keep in agreement.
    scrubTo(stepUnderPointer(track, pointerX(ev))))

  h.ui.controls.addEventListener("pointermove", proc(ev: Event) =
    if not h.scrubbing: return
    let track = trackNow()
    if track == nil: return
    ev.preventDefault()
    scrubTo(stepUnderPointer(track, pointerX(ev))))

  proc endScrub(ev: Event) =
    if not h.scrubbing: return
    h.scrubbing = false
    releasePointer(h.ui.controls, pointerIdOf(ev))
    let track = trackNow()
    if track != nil: track.classList.remove("scrubbing")
    # THE COMMIT. `scrubSeek` supersedes rather than queues, so re-asking for
    # the drop point either goes out now or replaces whatever intermediate
    # target was still waiting — and the session therefore lands where the
    # visitor let go, not where the engine happened to have got to. Without
    # this the drag would settle at the last coalesced position, which on a
    # fast flick is not where the hand stopped.
    if h.scrubTarget > 0: h.scrubSeek(h.scrubTarget)

  h.ui.controls.addEventListener("pointerup", endScrub)
  # A cancelled pointer is the platform taking the gesture back — a touch that
  # became a scroll, a window that lost focus mid-drag. The state is unwound
  # the same way, because a `scrubbing` flag left set would leave the handle
  # pinned away from the session for the rest of the visit, which is the
  # untruthful-handle defect produced by the fix for the inert one.
  h.ui.controls.addEventListener("pointercancel", endScrub)

  # THE KEYBOARD, because `markScrubberSeekable` puts `role="slider"` and a tab
  # stop on this element. A slider a keyboard can focus and cannot move is the
  # same defect as a track a mouse can see and cannot drag — this route has
  # already shipped a `role="button"` neither Enter nor Space activated — so
  # the two arrive together or not at all.
  #
  # An arrow moves ONE TICK, not one step. The tick is the resolution the
  # control is drawn at, so a key press that moved a single step would move the
  # session visibly and the handle not at all, which reads as a broken key.
  #
  # WHICH KEYS MEAN WHAT IS `keymap.ScrubKeys`, AND NOT THIS `case`. It used to
  # be this `case`, and the keys were then documented nowhere a visitor could
  # reach — `markScrubberSeekable` gave the track a name and a tab stop and
  # said nothing about how to move it. Deriving the tooltip from a list spelled
  # here would have been the second copy, and §10.5's lesson is that the second
  # copy is the one that goes stale and the one a visitor believes. So the
  # table is the source, `scrubMoveFor` is this handler's read of it, and
  # `scrubLabel` is the tooltip's — the same split `actionFor`/`chordFor` gives
  # the stepping buttons.
  #
  # The ARITHMETIC stays here, because it needs `total` and the drawn tick
  # width, which are properties of this session and not of the keymap. What
  # moved out is the naming of the keys, which is the only part that had two
  # readers.
  h.ui.controls.addEventListener("keydown", proc(ev: Event) =
    let track = closestFrom(ev, ".dctl.seekable")
    if track == nil: return
    let total = totalNow()
    if total <= 0: return
    let now = intAttr(h.ui.root, "data-step")
    let tick = max(1, total div TimelineTicks)
    let (isScrub, move) = scrubMoveFor($keyName(ev))
    if not isScrub: return
    let step =
      case move
      of smBackTick: now - tick
      of smForwardTick: now + tick
      of smBackPage: now - tick * 5
      of smForwardPage: now + tick * 5
      of smStart: 1
      # `lastStep(total)` AND NOT `total`, which is what this asked for and
      # what killed the session. `totalSteps` is a count and the coordinates
      # are zero-based, so `total` is one past the end — and the engine does
      # not refuse it, it panics (`load_local_calltrace: invalid step_id`) and
      # answers nothing for the rest of the visit. See `session_view.lastStep`
      # for the measurement. One keystroke on a focused scrubber ended the
      # session, and nothing anywhere had ever pressed it.
      of smEnd: lastStep(total)
    # AND THE `if step == 0: return` THAT USED TO BE HERE IS GONE, because it
    # no longer means what it says. It was the `case`'s `else` arm reaching
    # this line — "the key was not one of ours" — and `scrubMoveFor` now
    # answers that question above, in the one place it is asked.
    #
    # Left in place it would have kept swallowing a REAL move: `now - tick` is
    # exactly 0 when the session sits one tick in, so a visitor pressing ← at
    # that position would have been the one press in the trace that did
    # nothing. `clamp` below already resolves it to step 1, which is where ←
    # from the first tick should land.
    ev.preventDefault()
    let want = clamp(step, 1, total)
    h.scrubTarget = want
    paintScrubber(h.ui, want, total)
    h.scrubSeek(want))

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
  # The rows become controls by being RENDERED as links, not by having
  # attributes added to them afterwards.
  #
  # This used to stamp `role="button"` and `tabindex="0"` onto every row here,
  # and it was wrong twice. It was lost on the next step, because `renderPanes`
  # replaces each pane's `innerHTML` on every stop and the attributes went with
  # the markup — so the rows were focusable for exactly as long as the session
  # stayed still. And `role="button"` with a click handler is a control that a
  # keyboard cannot operate: neither Enter nor Space fires a click on a `div`,
  # and the pair was the page's only navigation affordance while the research
  # this arrangement is built on says selection is the PRIMARY gesture.
  #
  # An `<a href>` fixes both structurally. `session_project` gives every row a
  # destination, `components/debugger` renders it as an anchor, and every
  # re-render emits one — so focus, Enter, the focus ring, the status bar and
  # the context menu arrive from the platform and cannot be forgotten by a
  # later change to this file.
  #
  # The loop rail is the ONE surface that cannot take that fix, and
  # `markRailNavigable` is where it is handled instead. A navigable segment is
  # deliberately a `<span>` with no `href` (`components/debugger`): its target
  # is not a document position but a seek to that pass's header tick, so there
  # is no honest URL to put on it. It therefore still needs the role and the
  # tabindex — but stamped after EVERY render rather than once here, which is
  # exactly the bug this comment describes, avoided by putting the call inside
  # `renderPanes` instead of in this proc.
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
  # The chords, and the gear that configures them. AFTER `bindGestures`, in
  # the same "once the engine has answered" moment and for the same reason: a
  # chord bound before there is a session to step would be a key that does
  # nothing, which is the failure this whole change exists to end.
  h.bindShortcuts()
  # The engine is new; the breakpoints are not. Re-arming here — and not at
  # construction — is what makes a reload keep working rather than merely
  # keep LOOKING like it works: `restoreBreakpoints` is the only thing
  # standing between a restored gutter and a Continue that ignores it.
  h.restoreBreakpoints()
  # NOTHING SENT BEFORE THIS POINT REACHED THE ENGINE, and the store does not
  # know that.
  #
  # `openLiveSession` creates the ViewModels, and two of them issue a backend
  # command from an effect that runs the moment they are constructed —
  # `CalltraceVM`'s auto-load and `StateVM`'s `requestLocals`. That is several
  # hundred milliseconds before `startWorker`, so `postJson` finds no
  # `__btReplayWorker` and drops the message; the future never settles and
  # `RequestTracker` holds the request pending forever.
  #
  # `requestLocals` skips a send whose key AND arguments match a pending one,
  # and the arguments include the position. The session's landing position is
  # rrTicks 0 — the store's own initial value, and the entry frame of every
  # trace this route opens — so the FIRST request that could have been answered
  # is deduplicated against one that was thrown away before the worker existed,
  # and the State pane would wait out its deadline and report an engine that
  # never answered. The engine answered nothing because it was never asked.
  #
  # Clearing here says exactly that: the engine is ready as of this line, and
  # every request issued before it is not in flight. One call, at the one moment
  # the claim becomes true.
  h.session.store.requestTracker.clear()

  # THE OTHER HALF OF A STOP, AND IT CANNOT BE SYNCHRONOUS.
  #
  # `applyStop` writes the position, the URL and the panes in one call, which is
  # what keeps them from becoming facts that happen to be updated together. The
  # values cannot be in that call: the position is known when the engine reports
  # it and the values have to be asked for, so they arrive one round trip later.
  #
  # `onApplied` is that call. `StateVM`'s effect issues the request the instant
  # `applyStop` moves the store, `live_locals` writes the reply into the store,
  # and this re-renders — so the store and the panes are made consistent by ONE
  # call on the reply's arrival, exactly as they are by one call on the stop's.
  # Nothing else re-renders for locals, and `renderPanes` remains the only
  # writer of the panes.
  #
  # WIRED HERE AND NOT IN `hydrate`, AND THIS WAS MEASURED RATHER THAN
  # REASONED. A page whose engine never loaded still issues these requests —
  # the ViewModels ask the moment they are constructed — and `WorkerBackend`
  # .failAllPending settles every one of them when the worker dies, precisely
  # so a dropped request cannot present as a pane that spins forever. So the
  # `ct/load-locals` reply ARRIVES on the failure path, as a refusal,
  # milliseconds after `fail` has written the failure onto the page.
  #
  # With the callback assigned at construction instead, a build with no
  # `/replay-engine/` ended up — measured in a browser, on the artefact the
  # exporter writes — with eight LIVE stepping controls, `data-session-phase`
  # `ready`, `data-step` reset from 128 to 0, the served frame's ten Values
  # rows replaced, and the position mark on the source pane GONE. That is
  # every clause of §7.0 broken at once, by the code added to keep it, on the
  # state every local build and every capture run is in.
  #
  # A session that never goes live now never gets the callback. One that goes
  # live and then fails is caught by `stopped` — the same mechanism, one
  # `failAllPending` later, where a repaint would re-enable with `live = true`
  # the very buttons `fail` had just turned off.
  h.session.locals.onApplied = proc() =
    if not h.stopped: h.render()
  # THE SAME CALLBACK FOR THE SAME REASON, two panes over. The Call Trace and
  # the Event Log arrive as unsolicited events after their request is answered,
  # so — exactly like locals — they cannot be written by `applyStop` and must
  # re-render on arrival or wait for the next move to be seen. Without this the
  # first section the engine sends would sit in the store, unrendered, until
  # something else happened to repaint.
  h.session.navigation.onApplied = proc() =
    if not h.stopped: h.render()
  # AND ONCE MORE FOR THE FLOW WINDOW, which is the same arrangement a third
  # time: `FlowVM` asks on every move, `ct/updated-flow` comes back as an
  # unsolicited event a round trip later, and `live_flow` parses it. Without
  # this the values overlay would land one STEP behind the position it belongs
  # to — visible, plausible, and describing the frame the visitor just left,
  # which is the failure the whole module is written against.
  h.session.flowWindow.onApplied = proc() =
    if not h.stopped: h.render()
  # AND RE-ISSUE THE ONE REQUEST THE CLEAR ABOVE CANNOT REPLAY. See
  # `requestNavigationSections`: the call trace's auto-load fired before the
  # worker existed and its effect will not run again until something it reads
  # changes, so without this the pane fills on the visitor's first STEP rather
  # than on arrival. `ct/event-load` needs no equivalent — it is issued after
  # the session is up and does arrive.
  h.session.requestNavigationSections()
  # §8's deadline, for the pane rather than for the session. The engine is
  # documented to drop requests silently in some handshake orders
  # (`backend/dap_dialect.md` §1), and a request that is never answered leaves a
  # promise that never settles — so without this the pane would say "Reading the
  # values at this position…" for as long as the tab is open, which is a spinner
  # with a name. Injected rather than reached for, so `live_locals` stays a
  # module a headless suite can drive.
  h.session.locals.scheduleTimeout = proc(ms: int; action: proc()) =
    afterMs(ms, action)
  # The same deadline for the flow window, and it matters more here than it
  # reads: an unanswered `ct/load-flow` would leave the feed `ffPending`
  # forever, `hasWindow` false forever, and the pane back on the loop rail
  # with no values — which is the state this change exists to leave. The
  # deadline is what turns that into a settled `ffUnavailable` the next answer
  # can replace.
  h.session.flowWindow.scheduleTimeout = proc(ms: int; action: proc()) =
    afterMs(ms, action)
  # THE VALUES PANE'S HALF OF THE RE-ISSUE ABOVE, and it is deliberately DOWN
  # HERE rather than beside `requestNavigationSections`: `LocalsFeed.awaiting`
  # arms §8's deadline out of `scheduleTimeout`, so a locals request issued
  # three lines earlier would be one with no deadline behind it — the pane
  # stuck on "Reading the values at this position…" with nothing to end it,
  # which is the state this call exists to leave rather than to enter.
  #
  # See `requestLandingLocals` for why the clear above is not enough on its
  # own: the one position write that would have re-run `StateVM`'s effect is
  # the served frame's, and it happens BEFORE that clear — so the effect's
  # request is deduplicated against the one dropped before the worker existed,
  # and every write after the clear names the same coordinate and changes no
  # signal. Measured on the deployed dev channel, a visitor landing on a chain
  # transaction got zero `ct/load-locals` at the engine and an empty Values
  # pane until they stepped.
  h.session.requestLandingLocals()
  # The CONTROLS only. Not the panes: at this instant the engine has answered
  # `threads` and has not yet produced a call trace, a set of locals or a
  # position, so every pane projection is empty and rendering them would blank
  # four full served panes. `renderPanes`'s latch would refuse most of that
  # anyway; not asking is clearer than being refused.
  #
  # The panes arrive on the first `ct/complete-move`, which is a real frame.
  setControls(h.ui,
              projectReplayPanes(h.session, h.base, h.ui.island),
              h.keymap)

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
            # §6.3: "Resolution happens before first paint, so a shared link
            # opens AT the position rather than at the start with a visible
            # jump." The decision was made at load (`announceLanding`); this is
            # where it is acted on, and it is acted on INSTEAD of asking where
            # the engine landed rather than after it — a `stackTrace` first
            # would render the panes at the container's entry point and then
            # move them, which is the visible jump, on the one route that
            # exists to be deep-linked into.
            #
            # The fallback is the ordinary path, so an engine that refuses the
            # seek still ends up with a live, positioned session rather than a
            # frozen served one.
            if h.landing.coordinate > 0:
              h.gotoTicks(h.landing.coordinate,
                          onRefused = proc() = h.requestPosition())
            else:
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
    # Past this point the engine demonstrably exists, so any later failure is
    # about the TRACE, not about reaching the engine.
    h.engineLoaded = true
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
    # THE RECORDING'S SOURCE, BEFORE `start` AND NOT AFTER.
    #
    # `vfs-write` is handled by the worker's PRE-START dispatcher; once
    # `wasm_start()` has swapped in the DAP handler the message has no handler
    # and is dropped in silence. This is the only window.
    #
    # Without it the value-origin classifier has no line to parse and answers
    # every query "source unavailable" — see `live_source`'s header for why the
    # path it writes is the island's own, and for the measurement.
    h.sourceFilesGiven = writeSourceToEngine(h.ui.island)
    postJson("""{"type":"start"}""")
  of "trace-load-error":
    h.fail("The trace container could not be opened: " &
           message{"error"}.getStr("no reason given"))
  of "worker-status":
    if message{"status"}.getStr("") == "ready": h.handshake()
  of "worker-error":
    # "Stopped" is a claim about something that was running, and the commonest
    # worker error by a distance is the one where nothing ever did: a module
    # worker whose script 404s. Every build of this repository is in that state
    # until `just replay-engine` copies the engine to its own origin, so the
    # first time this sentence was ever rendered — VD.7's
    # `debugger--engine-worker-missing` — it read "The replay engine stopped:
    # the worker script at /replay-engine/worker.js could not be loaded", which
    # tells a reader the engine ran and then died and sends them looking for why.
    #
    # `engineLoaded` is the same discriminator the deadline below already uses
    # and for the same reason: the worker posts `wasm-loaded` the moment the
    # module compiles, so its absence means nothing ever started. One field,
    # two places, one meaning.
    let detail = message{"error"}.getStr("no reason given")
    h.fail((if h.engineLoaded: "The replay engine stopped: "
            else: "The replay engine did not start: ") & detail)
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
  # STATED BY THE PAGE, not inferred from the step. `data-step="0"` is a real
  # position (the first step of the trace) as well as the value an unpositioned
  # page publishes, so the two cases are only distinguishable because the page
  # writes this attribute. Absent — a page served before it existed — reads as
  # false, which is the conservative answer: the served frame then contributes no
  # position and the engine's own report is the only one that can.
  result.controls.positioned = attr(ui.root, "data-positioned") == "1"
  # §6.0's witness needs the hash of the artifact this page recommends, and the
  # page is the only thing that knows it — the engine can hash the bytes it was
  # given but has no opinion about which artifact was recommended. It is read
  # here, with the other served facts, so the rows' links and the incoming
  # link's verdict are about one and the same trace.
  result.traceContentHash = attr(ui.root, "data-content-hash")

proc hydrate() =
  # The root, before `readUi`, because the two things below it apply to pages
  # `readUi` deliberately refuses: §7.0's `absent`, `unsupported` and
  # `onDemand` rows have no panes, and a hydration that bailed first would
  # leave a visitor who followed a link into one of them with no answer at all.
  let root = document.querySelector(".dbg")
  if root == nil: return

  # §13's copy buttons first, and unconditionally. They need no engine, no
  # worker and no wasm, so a browser that can run none of those still gains
  # them — which is the capability ladder's whole shape applied one rung down.
  upgradeCopyAffordances(root)

  # §6.0a, second, and for the same reason: it needs no engine either, and its
  # first step — "no replayable artifact → state that; show the transaction.
  # Terminal." — is reachable ONLY here, on a page that has none.
  let landing = announceLanding(root)

  let ui = readUi()
  if ui.root == nil: return

  # §14.2's detection half, before a byte is fetched.
  let capability = detectCapability()
  if capability != ecReady:
    markUnavailable(ui, capabilityReason(capability))
    return

  # No published container is not a failure — it is §7.0's `absent` row, which
  # this page already renders correctly and which offers no debugger and no
  # pretence of one. There is nothing left to change; what there WAS to say has
  # been said by `announceLanding` above.
  let traceUrl = attr(ui.root, "data-trace")
  if traceUrl.len == 0: return

  # The store first, then the preset it holds, then everything that reads it.
  # This is before the first render on purpose: `renderControls` composes each
  # chord into the tooltip it labels a button with, so a keymap adopted after
  # the first paint would show one frame of buttons whose tooltips name no key.
  let prefs = localPreferenceStore()
  let h = Hydration(ui: ui, base: servedFrame(ui), landing: landing,
                    landingAnchor: servedLandingAnchor(root, landing),
                    prefs: prefs, keymap: keymapOf(prefs.load().keymap))
  # Restored BEFORE the engine is started, so the first live render already
  # carries the marks and the visitor never sees the gutter empty and then
  # populated. The engine is told separately, in `goLive` — it is a fresh
  # worker on every load and this set means nothing to it until it is sent.
  h.breakpoints = loadBreakpoints(h.base.traceContentHash)
  h.backend = newWorkerBackend(
    postProc = proc(messageJson: string) = postJson(messageJson),
    terminateProc = proc() = terminateWorker())
  h.backend.onControl(proc(message: JsonNode) = h.onControl(message))
  h.backend.onEvent(proc(event: JsonNode) = h.onDapEvent(event))
  h.service = h.backend.toBackendService()
  # THE ISLAND'S OWN DECLARATION, not its presence. See `islandAvailability`:
  # a chain session inlines an INSTRUCTION LISTING, so "there is an island"
  # stopped meaning "source was published" and a presence test would have told
  # the store this session is source-level — which joins the engine's position
  # by file and line against rows that are step ordinals.
  h.session = openLiveSession(
    h.service,
    sourceIsPublished = islandAvailability(ui.island) == srcSourceLevel)

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
  # Two failures reach this deadline and they are not the same fault, so they
  # do not get the same sentence. `engineLoaded` is the discriminator: the
  # worker posts `wasm-loaded` the moment the module compiles, so its absence
  # means the engine was never reached, and its presence means the engine is
  # running and declined this container.
  afterMs(EngineDeadlineMs, proc() =
    if not h.live:
      if not h.engineLoaded:
        h.fail("The replay engine never loaded from " & ReplayEngineBase &
               ". Nothing answered at that path, so no trace could be opened; " &
               "the container can still be downloaded and opened in CodeTracer.")
      else:
        h.fail("The replay engine loaded but would not open this trace " &
               "container. The engine is running and reachable — it rejected " &
               "the container's format; the container can still be downloaded " &
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
