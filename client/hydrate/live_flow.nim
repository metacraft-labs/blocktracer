## SDK-CONSUMER: the `ct/updated-flow` window's STEPS, parsed into the overlay
## the source pane already knows how to draw.
##
## ## The defect this module is
##
## `FlowVM`'s auto-load effect issues `ct/load-flow` on every debugger move and
## the engine answers with the whole omniscience window. `applyFlowUpdate`
## (`viewmodels/flow_vm.nim`, behind `ci/embed-sdk-pin.env`) reads three things
## out of that answer — `loops`, `location.rrTicks` and the selection it derives
## from them — and returns. `FlowViewUpdate.steps`, which is where every
## recorded value in the window lives, is not read by it: `FlowVM.steps` has
## exactly one writer, the `setSteps` setter, and nothing in a browser calls it.
##
## So the fifth instance of one shape, and it was measured on the wire rather
## than reasoned about. Instrumenting `Worker.postMessage` and the worker's
## message handler before the page's own scripts run, on `dev`, over the built
## site with the published engine staged:
##
##   * `ct/load-flow` goes out on every position change — 4 requests over 4
##     steps, none before the first move. The request is not missing.
##   * `ct/updated-flow` comes back on every one of them, on BOTH paths (the
##     queued DAP event and the reply), carrying `viewUpdates[0].steps`.
##   * On the published Noir recording that window held 14 steps, 13 of them
##     carrying at least one value, across 13 distinct source lines.
##   * On a published Aztec chain capture it held 345 steps, all 345 carrying
##     values.
##   * The source pane showed 0 annotations at the landing position and 0 after
##     four steps — while the SERVED frame of the same page, read with scripting
##     off, showed 23. Hydration was REMOVING the overlay and never putting one
##     back.
##
## That last line is the user-visible report ("why is flow not displayed
## automatically? I expect it to track the current function") and it is why the
## fix is a projection and not a pane: the pane exists, `flow_view.applyFlow`
## draws it, and `demo_flow.nim` already feeds it from a container. Only the
## live feed was missing.
##
## ## Why this is not a change to `projectFlowRail`'s stated stop
##
## `session_project.projectFlowRail` records why the values did not cross:
##
##     neither the parse nor the rendering can be checked against anything
##     here: a test written against a payload this repository invented would
##     pass whatever the engine actually sends
##
## That objection was correct and it is the reason this module could not have
## been written earlier. What dissolves it is a payload this repository did NOT
## invent. `$CODETRACER_SRC/src/frontend/viewmodel/tests/fixtures/flow/
## zk_shields_flow_window.json` is `viewUpdates[0]` of a real `ct/updated-flow`
## event, captured verbatim by `capture_zk_shields_flow.nim` from the engine
## replaying `noir_space_ship` — which is this repository's own fixture
## program. `tests/tdebugpanes.nim` drives THAT file through `emitEvent`, so the
## parse below is checked against bytes the engine wrote, at the pin CI builds
## against, and a drift in the wire format fails the suite rather than passing
## it.
##
## ## Why a decorated `BackendService` and not a second request
##
## The same reason `live_locals.nim` gives, which is the reason that file
## exists: `openLiveSession` builds the service the store is built on, so
## `FlowVM`'s OWN request passes through here on its way out and its OWN answer
## passes back through on the way in. One request, one window, one writer. A
## second `ct/load-flow` beside the ViewModel's would be two producers of one
## fact against a 50 ms budget, which this route has already been bitten by.
##
## ## Both answer paths, because the engine uses both
##
## `ct/load-flow`'s documented answer is a queued `ct/updated-flow` EVENT
## (`db-backend/src/dap.rs`), and the backend-manager converts that event into a
## response for some deployments. The measurement above saw both arrive over the
## WASM worker. Worse, the two spell the envelope differently — the DAP event is
## `{type: "event", event: "ct/updated-flow", body: …}` while the
## backend-manager's is `{kind: "CtUpdatedFlow", data: …}` — and the pinned
## `flow_vm.nim` recognises only the second, so on this transport its own event
## handler never fires at all. Both spellings are accepted here; a consumer that
## knew one would be empty against the other deployment, which is the hazard
## `Omniscience-Flow.md` records by name.
##
## ## What is deliberately NOT decided here
##
## Placement. Which column a value sits at, which pass a label belongs to and
## whether two values read `[x=10]` or `[x: 10→20]` are all answered by
## `flow_layout.nim`, vendored byte-for-byte from CodeTracer, exactly as they
## are for the static frame. This module renders the engine's `Value`s to text
## and hands `flow_view.applyFlow` the same `FlowWindowInput` `demo_flow.nim`
## hands it — so the served page and a hydrated one are laid out by one piece of
## arithmetic and cannot disagree about where a value goes.

import std/[json, strutils]

import isonim/core/async_compat
import codetracer_embed

import ../src/debugger/flow_view
# The VENDORED `flow_layout`, named, and every layout type below spelled through
# it. `codetracer_embed` re-exports the Embed SDK's own copy of the same module,
# so `FlowLayoutWindow` unqualified is ambiguous here — and the two are not
# interchangeable however identical they look: `flow_view.FlowWindowInput.window`
# is the vendored type, and a window built from the other one would not be the
# type `applyFlow` takes. Nim reports that as an ambiguity today; qualifying is
# what keeps it from becoming a silent pick if either import list changes.
import ../src/debugger/vendor/frontend/viewmodel/viewmodels/flow_layout as
  vendored
import ./live_locals

const
  LoadFlowCommand* = "ct/load-flow"
    ## The command whose answer this module reads. Spelled here and compared
    ## against what `FlowVM` sends, so a rename upstream shows up as an overlay
    ## that never leaves `ffUnasked` rather than as a silent revert to the
    ## defect.

  UpdatedFlowEvent* = "ct/updated-flow"
    ## The DAP `event` name, as `dap.rs` queues it and as the WASM worker
    ## delivers it.

  UpdatedFlowEventKind* = "CtUpdatedFlow"
    ## The same event as the backend-manager's event bus spells it, in `kind`.
    ## See the header: which one arrives depends on the deployment.

  ReturnExpression* = "return"
    ## What the engine calls the recorded return value inside `beforeValues` /
    ## `afterValues`.
    ##
    ## It is lifted out of the value list and carried as a `FlowReturn` instead,
    ## which is not cosmetic. `Omniscience-Flow.md`'s `[→230]` is a fact about a
    ## LINE and has no expression to point at; left in the list it would be
    ## placed by `assignExpressionColumns`, which refuses to find `return` in a
    ## line that does not contain the word and would park it past the end of the
    ## line as a label reading `return: 230`. `flow_view.FlowReturn` exists for
    ## this and the static extractor already routes it there
    ## (`extract-flow.mjs`: "A `Void` return is dropped rather than rendered"),
    ## so doing anything else here would make the two frames disagree.

  NoneValueKind* = 30
    ## `TypeKind.None` — see `live_locals`' ordinal table, which is derived
    ## against this engine rather than borrowed from the pinned SDK's own
    ## (wrong) comment. A `return` of this kind is a Void return and is dropped
    ## rather than rendered, which is what the static extractor does.

  FlowDeadlineMs* = 8000
    ## How long a position may wait for its window before the overlay stops
    ## claiming one is coming. The same bound and the same reason as
    ## `live_locals.LocalsDeadlineMs`: §8 forbids an indeterminate wait, and the
    ## engine is known to drop requests silently in some handshake orders
    ## (`backend/dap_dialect.md` §1).

# ---------------------------------------------------------------------------
# The wire: `FlowViewUpdate`
# ---------------------------------------------------------------------------
#
# `src/db-backend/src/task.rs`, serde `rename_all = "camelCase"`. The fields
# read below are the ones `flow_layout.FlowLayoutWindow` is a subset of, and
# each was confirmed present in a captured event before it was parsed:
#
#   viewUpdates[0].steps[]        position, loop, iteration, rrTicks,
#                                 stepCount, exprOrder, beforeValues,
#                                 afterValues
#   viewUpdates[0].loops[]        first, last, registeredLine,
#                                 rrTicksForIterations, stepCounts
#   viewUpdates[0].loopIterationSteps[loop][iteration].table
#                                 the line -> stepCount map of one pass
#   location.rrTicks              the position the window was computed for
#   location.functionName         the function it is a window ON
#
# `beforeValues` / `afterValues` are OBJECTS keyed by expression name, not
# arrays, and each value is a `db-backend/src/value.rs` `Value` — the same type
# `ct/load-locals` carries, which is why `live_locals.valueText` renders them
# rather than a second renderer written here. Two spellings of one value across
# two panes of one session would be a difference with no cause.

func jsonInt(node: JsonNode; fallback = 0): int =
  ## Tolerant integer read, for the same reason `flow_vm.jsonInt` is tolerant:
  ## the backend's `RRTicks` / `Position` / `Iteration` are newtype structs that
  ## serde renders as bare numbers, and the DAP transport has historically
  ## delivered them as strings on some hosts. Silently producing 0 would look
  ## exactly like the bug this module exists to remove.
  if node.isNil: return fallback
  case node.kind
  of JInt: int(node.getBiggestInt)
  of JFloat: int(node.getFloat)
  of JString:
    try: parseInt(node.getStr) except ValueError: fallback
  else: fallback

func stringList(node: JsonNode): seq[string] =
  if node.isNil or node.kind != JArray: return
  for item in node:
    if item.kind == JString: result.add item.getStr

func intList(node: JsonNode): seq[int] =
  if node.isNil or node.kind != JArray: return
  for item in node: result.add jsonInt(item, 0)

proc valueList(node: JsonNode): seq[vendored.FlowValueText] =
  ## One `{name: Value}` map as the layout module's value list.
  ##
  ## `ReturnExpression` is skipped: it is lifted separately. Iteration order is
  ## the object's, which is the order the engine wrote — `exprOrder` is what
  ## decides the reading order downstream, so nothing here depends on it.
  if node.isNil or node.kind != JObject: return
  for name, value in node:
    if name == ReturnExpression: continue
    result.add vendored.FlowValueText(expression: name, text: valueText(value))

proc returnTextOf(step: JsonNode): string =
  ## The recorded return value of one step, or `""` when there is none.
  ##
  ## `afterValues` first: a return is a value the line PRODUCED, and the engine
  ## records the entry in both maps for a step it has passed. A `None`-kinded
  ## return is a Void return and yields `""`, so a function that returns nothing
  ## gets no `[→]` with nothing in it.
  for field in [$"afterValues", $"beforeValues"]:
    let map = step{field}
    if map.isNil or map.kind != JObject: continue
    let value = map{ReturnExpression}
    if value.isNil or value.kind != JObject: continue
    if value{"kind"}.getInt(-1) == NoneValueKind: continue
    let text = valueText(value)
    if text.len > 0: return text
  ""

proc parseLoop(node: JsonNode; passes: JsonNode): vendored.FlowLayoutLoop =
  ## One `Loop` of the window, with its per-pass line→step tables.
  ##
  ## `passes` is `loopIterationSteps[thisLoop]` — an array whose `i`th entry is
  ## pass `i`'s `{line: stepCount}` map, wrapped in a `table` field by serde's
  ## rendering of the Rust `BTreeMap` newtype. Flattened to pairs here because
  ## `FlowLayoutLoop.iterationSteps` is defined that way, so its iteration order
  ## is the caller's and not a hash order.
  result = vendored.FlowLayoutLoop(first: -1, last: -1, registeredLine: -1)
  if node.isNil or node.kind != JObject: return
  result.first = jsonInt(node{"first"}, -1)
  result.last = jsonInt(node{"last"}, -1)
  result.registeredLine = jsonInt(node{"registeredLine"}, -1)
  result.base = jsonInt(node{"base"}, 0)
  result.baseIteration = jsonInt(node{"baseIteration"}, 0)
  result.internal = intList(node{"internal"})
  result.stepCounts = intList(node{"stepCounts"})
  result.rrTicksForIterations = intList(node{"rrTicksForIterations"})
  if passes.isNil or passes.kind != JArray: return
  for pass in passes:
    var entries: seq[tuple[line: int, stepCount: int]] = @[]
    let table = if pass.kind == JObject and pass.hasKey("table"): pass{"table"}
                else: pass
    if not table.isNil and table.kind == JObject:
      for line, stepCount in table:
        entries.add (line: jsonInt(%line, 0), stepCount: jsonInt(stepCount, 0))
    result.iterationSteps.add entries

proc parseFlowWindow*(payload: JsonNode;
                      window: var vendored.FlowLayoutWindow;
                      returns: var seq[FlowReturn];
                      path: var string;
                      functionLabel: var string;
                      ticks: var int): bool =
  ## One `ct/updated-flow` payload into the layout module's own vocabulary.
  ##
  ## `false` when the payload is not a window — which is a state that occurs
  ## (`error` / `errorMessage` are fields on this envelope), not one guarded
  ## against in principle. The out-parameters are left untouched on `false`, so
  ## a refusal cannot half-write a window over the previous one.
  ##
  ## `window.sourceLines` is NOT filled here and cannot be: the engine sends the
  ## values and the PAGE owns the text — that split is `FlowLayoutWindow`'s own
  ## ("who owns the source differs per consumer"), and joining them is
  ## `session_project`'s job because only it has the decoded pane.
  if payload.isNil or payload.kind != JObject: return false
  let views = payload{"viewUpdates"}
  if views.isNil or views.kind != JArray or views.len == 0: return false
  # The backend returns one view update per `EditorView`; the source view is
  # first, and is the one the overlay is drawn on. Same index, same reason, as
  # `flow_vm.applyFlowUpdate`.
  let view = views[0]
  if view.isNil or view.kind != JObject: return false

  # `location` on the envelope is the position the window was computed for;
  # fall back to the view's own copy, exactly as the pinned applier does.
  var location = payload{"location"}
  if location.isNil or location.kind != JObject: location = view{"location"}
  if location.isNil or location.kind != JObject: location = newJObject()

  # WHICH file and WHICH function are asked of both locations, and the tick is
  # not. They are different questions about the same envelope: the tick is the
  # POSITION the window belongs to and the envelope's is the authoritative one —
  # the view's is the window's own start and is a different number, 9 against
  # 121 in the captured window this parse is tested against, so preferring the
  # wrong one would open the loop rail on the wrong pass. The path and the
  # function name are properties of the WINDOW and are the same on both, so the
  # one that is populated is taken; an envelope carrying a bare
  # `{path, line, rrTicks}` is a real shape and would otherwise lose the
  # function label the rail is named for.
  let viewLocation =
    if view{"location"}.isNil or view{"location"}.kind != JObject: newJObject()
    else: view{"location"}
  proc firstNonEmpty(field: string): string =
    result = location{field}.getStr("")
    if result.len == 0: result = viewLocation{field}.getStr("")

  var built = vendored.FlowLayoutWindow(tabSize: 4)

  let passesByLoop = view{"loopIterationSteps"}
  let loopNodes = view{"loops"}
  if not loopNodes.isNil and loopNodes.kind == JArray:
    # An explicit index, because `pairs` over a `JsonNode` yields the OBJECT
    # iterator's `(string, JsonNode)` and would not index `loopIterationSteps`
    # at all. The two arrays are index-aligned by the backend — entry `i` of
    # `loopIterationSteps` is loop `i`'s passes — so pairing them by position is
    # the whole join.
    var index = 0
    for loopNode in loopNodes:
      let passes =
        if not passesByLoop.isNil and passesByLoop.kind == JArray and
           index < passesByLoop.len: passesByLoop[index]
        else: nil
      built.loops.add parseLoop(loopNode, passes)
      inc index

  var recordedReturns: seq[FlowReturn] = @[]
  let stepNodes = view{"steps"}
  if not stepNodes.isNil and stepNodes.kind == JArray:
    for stepNode in stepNodes:
      if stepNode.isNil or stepNode.kind != JObject: continue
      # `position` IS the source line. The field is named for the backend's
      # `Position` newtype and `FlowLayoutStep.line` says so; reading `line`
      # here would silently produce a window every one of whose steps sits on
      # line 0, which lays out cleanly and is entirely fictional.
      let loopIndex = jsonInt(stepNode{"loop"}, 0)
      let iteration = jsonInt(stepNode{"iteration"}, 0)
      let line = jsonInt(stepNode{"position"}, 0)
      built.steps.add vendored.FlowLayoutStep(
        stepCount: jsonInt(stepNode{"stepCount"}, 0),
        line: line,
        loopIndex: loopIndex,
        iteration: iteration,
        rrTicks: jsonInt(stepNode{"rrTicks"}, 0),
        exprOrder: stringList(stepNode{"exprOrder"}),
        beforeValues: valueList(stepNode{"beforeValues"}),
        afterValues: valueList(stepNode{"afterValues"}))
      let returned = returnTextOf(stepNode)
      if returned.len > 0:
        recordedReturns.add FlowReturn(
          line: line,
          # A return recorded outside every real loop belongs to no pass and is
          # shown whatever the rail is set to; `flow_view.NoIteration` is that.
          iteration: (if loopIndex > 0: iteration else: NoIteration),
          text: returned)

  window = built
  returns = recordedReturns
  path = firstNonEmpty("path")
  functionLabel = firstNonEmpty("functionName")
  ticks = jsonInt(location{"rrTicks"}, 0)
  true

# ---------------------------------------------------------------------------
# The feed
# ---------------------------------------------------------------------------

type
  FlowPhase* = enum
    ## What this session knows about the flow window at the position it is at.
    ffUnasked       ## no `ct/load-flow` has been issued for any position yet
    ffPending       ## asked for `forTicks`, no answer yet
    ffLive          ## `forTicks`' window is parsed and in this feed
    ffUnavailable   ## `forTicks` was asked and the answer carried no window

  FlowFeed* = ref object
    ## One session's `ct/load-flow` traffic, and the window the overlay is drawn
    ## from.
    ##
    ## A `ref` because the decorated `BackendService` and the event handler both
    ## close over it and it outlives every individual request.
    ##
    ## It holds the WINDOW and not the finished overlay, and that is the same
    ## split `LocalsFeed` makes: the feed is what came back, the projection is
    ## what may be shown. Only the projection knows the pane, and only the pane
    ## knows whether this position's fidelity permits an overlay at all.
    phase*: FlowPhase
    forTicks*: uint64
      ## The position `phase` is a statement about. Compared against the
      ## session's current position by the projection, so a window computed for
      ## a position the session has already left is never drawn as if it were
      ## this one's — which is the stale-value failure `flow_view`'s rule 2 is
      ## written against, arriving through time instead of through a loop pass.
    epoch*: int
      ## Which request `phase` is about. The position alone is not enough: a
      ## session that steps away and back asks about the same `rrTicks` twice,
      ## and the first request's deadline would otherwise expire onto the
      ## second's pending state.
    reason*: string
    enginePath*: string
      ## `location.path` as the ENGINE spells it — an absolute path on the
      ## recording machine, not the interned path the pane's documents carry.
      ## Resolved against the pane by the projection, with the same
      ## longest-suffix rule `source_island.positionDocumentIndex` uses for the
      ## position, because they are the same question about the same wire.
    window*: vendored.FlowLayoutWindow
      ## Without `sourceLines`. See `parseFlowWindow`.
    returns*: seq[FlowReturn]
    locationTicks*: int
    functionLabel*: string
    onApplied*: proc()
      ## The host's re-render, called once per settled answer. The same
      ## discipline as `LocalsFeed.onApplied`: the window and the panes are left
      ## consistent by one call rather than by two facts updated in parallel.
    scheduleTimeout*: proc(ms: int; action: proc())
      ## Injected by the host (`afterMs`). Absent — under `nim c`, in the
      ## headless suites — there is no deadline and a pending position simply
      ## stays pending, which is correct for a driver that answers or does not.

proc settle(feed: FlowFeed; epoch: int; phase: FlowPhase; reason = "") =
  ## One request, ended. Every exit goes through here so that "the phase moved"
  ## and "the host was told" cannot come apart.
  ##
  ## An answer to a request the session has moved past is dropped: two requests
  ## can be in flight across a fast pair of steps, and the older one resolving
  ## second would overwrite the newer one's window with the previous frame's.
  if feed == nil or epoch != feed.epoch or feed.phase != ffPending: return
  feed.phase = phase
  feed.reason = reason
  if feed.onApplied != nil: feed.onApplied()

proc adoptWindow(feed: FlowFeed; epoch: int; payload: JsonNode) =
  ## A parsed window, into the feed.
  ##
  ## The window is written BEFORE the phase, so the one re-render `settle`
  ## triggers reads a feed that already holds it.
  if feed == nil or epoch != feed.epoch or feed.phase != ffPending: return
  var window: vendored.FlowLayoutWindow
  var returns: seq[FlowReturn]
  var path, label: string
  var ticks: int
  if not parseFlowWindow(payload, window, returns, path, label, ticks):
    feed.settle(epoch, ffUnavailable,
      "The replay engine's flow answer carried no window this page could read.")
    return
  feed.window = window
  feed.returns = returns
  feed.enginePath = path
  feed.functionLabel = label
  feed.locationTicks = ticks
  feed.settle(epoch, ffLive)

proc applyReply*(feed: FlowFeed; epoch: int; response: JsonNode) =
  ## A `ct/load-flow` DAP response.
  ##
  ## Sometimes the window and sometimes only an acknowledgement — the real
  ## answer is the queued event, and the backend-manager converts that event
  ## into a response for some deployments. Both are fed to one applier for that
  ## reason; a reply that is not a window leaves the request pending for the
  ## event rather than settling it `ffUnavailable`, because on the transport
  ## where the event is the answer, settling here would race it.
  if feed == nil or epoch != feed.epoch or feed.phase != ffPending: return
  if response.isNil or response.kind != JObject: return
  if not response{"success"}.getBool(true):
    feed.settle(epoch, ffUnavailable,
      "The replay engine refused the flow request for this position.")
    return
  let body = if response.hasKey("body"): response["body"] else: response
  if body.isNil or body.kind != JObject or body{"viewUpdates"} == nil: return
  feed.adoptWindow(epoch, body)

proc handleEvent*(feed: FlowFeed; event: JsonNode) =
  ## One backend event. Everything that is not `ct/updated-flow` is ignored —
  ## this is not a place to grow a second protocol layer.
  ##
  ## BOTH envelope spellings, because both occur. See the module header.
  if feed == nil or event.isNil or event.kind != JObject: return
  let name =
    if event.hasKey("event"): event{"event"}.getStr("")
    elif event.hasKey("kind"): event{"kind"}.getStr("")
    else: ""
  if name != UpdatedFlowEvent and name != UpdatedFlowEventKind: return
  let body =
    if event.hasKey("body"): event["body"]
    elif event.hasKey("data"): event["data"]
    else: event
  feed.adoptWindow(feed.epoch, body)

proc awaiting(feed: FlowFeed; ticks: uint64): int =
  ## A request has gone out for `ticks`. Returns its epoch.
  ##
  ## The previous window is NOT cleared here, and that is safe for one specific
  ## reason rather than by luck: `forTicks` moves to the new position at the
  ## same time, and the projection refuses to draw a window whose `forTicks` is
  ## not the session's current tick. So the stale window becomes undrawable in
  ## the same statement that makes it stale, and nothing can read it in between.
  inc feed.epoch
  feed.phase = ffPending
  feed.forTicks = ticks
  feed.reason = ""
  result = feed.epoch
  if feed.scheduleTimeout != nil:
    let deadline = feed.epoch
    feed.scheduleTimeout(FlowDeadlineMs, proc() =
      feed.settle(deadline, ffUnavailable,
        "The replay engine did not answer with a flow window for this position."))

proc withLiveFlow*(inner: BackendService; feed: FlowFeed): BackendService =
  ## `inner`, with `ct/load-flow`'s answer read on both of the paths it takes.
  ##
  ## The event handler is registered here, once, for the reason
  ## `withLiveNavigation` gives: `onEvent` appends, and registering from the
  ## returned `onEventProc` would add one handler per call.
  ##
  ## Every other command is passed through untouched.
  if inner == nil: return inner
  if inner.onEventProc != nil:
    inner.onEvent(proc(event: JsonNode) = feed.handleEvent(event))
  BackendService(
    sendProc: proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
      let fut = inner.send(command, args)
      if command == LoadFlowCommand:
        # The position the VIEWMODEL asked about, out of the arguments it built,
        # rather than the session's current position. `CtLoadFlowArguments` puts
        # the tick inside `location` and not at the top level — reading it from
        # the top level is why an earlier version of this request never once
        # succeeded, and reading it from the top level HERE would silently make
        # every window belong to tick 0.
        let location = args{"location"}
        let ticks = uint64(max(0, jsonInt(
          if location.isNil: nil else: location{"rrTicks"}, 0)))
        let epoch = feed.awaiting(ticks)
        fut.onComplete(
          onSuccess = proc(response: JsonNode) = feed.applyReply(epoch, response),
          onError = proc(message: string) =
            feed.settle(epoch, ffUnavailable,
              "The replay engine did not answer the flow request: " &
              (if message.len > 0: message else: "no reason given") & "."))
      fut,
    onEventProc: inner.onEventProc,
    disconnectProc: inner.disconnectProc)

proc hasWindowFor*(feed: FlowFeed; ticks: uint64): bool =
  ## Whether the window this feed holds is THIS position's.
  ##
  ## The one gate the projection asks. It is a conjunction and every conjunct
  ## earns its place: a feed that never asked has no window; a pending one's
  ## window is the previous position's; an unavailable one's is too; and a live
  ## one's is only this position's if it was computed for this position.
  ##
  ## A window with no steps is still a window and still passes — that is a real
  ## answer ("the engine recorded nothing at this position") and drawing no
  ## annotations for it is correct. Refusing it here would leave the PREVIOUS
  ## position's overlay on screen, which is the one outcome that must not
  ## happen.
  feed != nil and feed.phase == ffLive and feed.forTicks == ticks

proc adopt*(feed: FlowFeed; ticks: uint64; payload: JsonNode) =
  ## Declare that `payload` is the window at `ticks`, without a request.
  ##
  ## For drivers that deliver a window directly — `tests/tdebugpanes.nim` feeds
  ## the captured `zk_shields_flow_window.json` through the mock's `emitEvent`
  ## after moving the session, and the mock's auto-responder answers the VM's
  ## `ct/load-flow` before the event arrives. Without this the suite would drive
  ## a feed whose epoch had already settled on the acknowledgement.
  if feed == nil: return
  inc feed.epoch
  feed.phase = ffPending
  feed.forTicks = ticks
  feed.reason = ""
  feed.adoptWindow(feed.epoch, payload)
