## The Call Trace and the Event Log, from the engine that is already sending
## them.
##
## ## The defect
##
## Both panes had a complete pipeline with the last link missing, and both
## looked healthy because the STATIC EXPORT ships fixture rows for the demo
## chain. Measured on production, on every capture:
##
##   * the page sends `ct/load-calltrace-section`, the engine answers with a
##     `ct/updated-calltrace` EVENT carrying real `callLines`, and the pane
##     renders zero rows;
##   * the page sends `ct/event-load`, the engine answers with a
##     `ct/updated-events` event carrying real rows, and the pane renders zero.
##
## On the demo chain `ctrow` stayed at 12 — the served fixture's count — across
## a step, before and after, on a session whose engine had just answered with a
## call trace. That number not changing is the whole finding: a fixture was
## standing in for a live path, and every assertion in the suite was satisfied
## by the fixture.
##
## On a REAL `aztec-testnet` capture the static export ships no rows at all,
## because a rung-3 recording resolves no source positions and the SSR
## constructor has no instruction-level arm for these two panes. So the visitor
## got an empty Call Trace and an empty Event Log, nothing to click, and a
## position mark that could not be moved by anything except the toolbar. That
## is the reported defect: "it's not following properly the jumps I perform" —
## there were no jumps to perform.
##
## ## Why the reply is dropped, exactly
##
## `replay_data_store.requestCalltraceSection` sends the request and its
## `onComplete` takes NO response argument: it sets `loadingState` to idle and
## nothing else, under a comment saying the data "is handled by the existing
## event-bus subscription in calltrace.nim". That subscription is the DESKTOP
## UI's. Nothing in this repository subscribes, and `updateCalltraceSection` —
## the sole writer of `store.calltrace.lines` — has no caller here outside
## `tests/tdebugpanes.nim`.
##
## The event log failed one step further along: the SDK parsed `ct/event-load`
## into `applyMarkerRowsResponse`, which writes `vm.markerRows`, while
## `projectEventLog` reads `vm.eventRows` — a different signal, written only by
## `appendLiveDebuggerStop`, which was also called only by tests.
##
## THAT HALF IS FIXED UPSTREAM as of `af70456c9`. `EventLogVM`'s own auto-load
## effect now routes its `ct/event-load` reply through
## `ReplayDataStore.applyEventLogResponse`, and `vm.eventRows` is an ALIAS of
## `store.eventLog.rows` rather than a second signal. What is still missing
## there — and is why this module has not shrunk to nothing — is a subscriber:
## nothing in `src/frontend/viewmodel/` registers a handler for the
## `ct/updated-events` EVENT, which is the shape this consumer receives. So the
## subscription stays here and the DECODE moved to the store; see
## `positionedEvents`.
##
## This is the third instance of one shape. `live_locals` was written for the
## first: "the pinned store's `requestLocals` throws the answer away through a
## private `onComplete` wrapper written to discard the result value". Same
## disease, two more panes, and the same cure.
##
## ## The seam, and why it is this one
##
## `openLiveSession` constructs the `BackendService` the store is built on, so
## this module can read the engine's events on their way in without a pin bump
## and without a second producer of the same fact. It is a DECORATOR, exactly as
## `live_locals` is, and it differs in one way that the SDK's own shape forces:
## the payload arrives as an EVENT and not as a response, so it registers an
## event handler rather than wrapping `sendProc`. `WorkerBackend.eventHandlers`
## is a `seq` and every handler is invoked, so registering here takes nothing
## away from the store's own handler or from `hydrate.onDapEvent`.
##
## Registered ONCE, at decoration time, and not inside the returned
## `onEventProc`. `onEvent` is called more than once per session — the store
## registers, then `hydrate` registers — and a decorator that added our handler
## on each of those calls would apply every event twice and double every row.

import std/[json, strutils]

import codetracer_embed

const
  UpdatedCalltraceEvent* = "ct/updated-calltrace"
    ## The event whose body this module exists to read. Spelled here and
    ## compared against what the ENGINE sends, so a rename upstream shows up as
    ## a pane that stays empty rather than as a silent revert to the defect.

  UpdatedEventsEvent* = "ct/updated-events"

type
  NavigationFeed* = ref object
    ## What this consumer asked for, what came back, and what it made of it.
    ##
    ## Held here rather than read back off the store for the reason
    ## `live_locals` gives about `loadingState`: the store's own discarded-reply
    ## handler moves its bookkeeping on every reply INCLUDING one nothing could
    ## read, so a pane keyed on the store would report a successful load of
    ## nothing.
    store*: ReplayDataStore
    eventLog*: EventLogVM
    onApplied*: proc()
      ## The host's re-render, called once per applied payload. `applyStop`
      ## writes the position, the URL and the panes in one call; this is the
      ## same discipline for the half that cannot be synchronous.
    calltraceLines*: int
      ## How many call lines this module last wrote. A COUNT WE PRODUCED, never
      ## one read back off the store — the point of the module is that the two
      ## used to disagree silently.
    eventRowsWritten*: int
    sawCalltrace*: bool
    sawEvents*: bool
      ## Whether the engine has answered at all. "Never asked" and "answered
      ## with nothing" are different sentences and a pane that could not tell
      ## them apart is how this defect survived.

# ---------------------------------------------------------------------------
# The wire
# ---------------------------------------------------------------------------
#
# `ct/updated-calltrace` carries
#   { callLines: [ { depth, content: { call: { depth, key, rawName,
#                                              location: {...} } } } ],
#     startCallLineIndex, totalCallsCount, … }
#
# and the fields a row needs are split across the three levels: the row's own
# `depth`, the call's `key` and `rawName`, and the position in `location`.
# Read off a live `aztec-testnet` session on 2026-09-01, whose three lines are
# `<toplevel>` (depth 0, rrTicks 0), `enqueued-call-0` (depth 1, rrTicks 0) and
# `<end of program>` (depth 0, rrTicks 344).
#
# `location.functionName` IS EMPTY ON SOME ROWS and `rawName` is not — the
# end-of-program marker is the case in hand. A row whose name resolved to the
# empty string would render as a blank, clickable line, so `rawName` is the
# fallback rather than an alternative spelling.

proc callLineOf(node: JsonNode; index: int64): CallLine =
  ## One `callLines[i]`, as the row type the store holds.
  let call = node{"content"}{"call"}
  let loc = if call != nil: call{"location"} else: nil
  let name =
    block:
      let fn = if loc != nil: loc{"functionName"}.getStr("") else: ""
      if fn.len > 0: fn
      elif call != nil: call{"rawName"}.getStr("")
      else: ""
  # `highLevelPath` is the file a visitor is shown; `path` is the same string on
  # a chain recording and the low-level one elsewhere. Preferring the high-level
  # spelling keeps the row's module column the same text the source pane's tab
  # carries.
  let file =
    if loc == nil: ""
    else:
      let hi = loc{"highLevelPath"}.getStr("")
      if hi.len > 0: hi else: loc{"path"}.getStr("")
  let line =
    if loc == nil: 0
    else:
      let hi = loc{"highLevelLine"}.getInt(0)
      if hi > 0: hi else: loc{"line"}.getInt(0)
  CallLine(
    index: index,
    name: name,
    depth: node{"depth"}.getInt(if call != nil: call{"depth"}.getInt(0) else: 0),
    # THE JUMP TARGET. `projectCalltrace` carries this into `data-step`, and a
    # row without it is a row `gotoTicks` returns before sending for — an inert
    # row that looks exactly like a live one.
    rrTicks: uint64(max(0, (if loc != nil: loc{"rrTicks"}.getBiggestInt(0) else: 0))),
    location: Location(file: file, line: line),
    hasChildren: call != nil and call{"children"} != nil and
                 call{"children"}.kind == JArray and call{"children"}.len > 0,
    isExpanded: loc != nil and loc{"isExpanded"}.getBool(false),
    callKey: if call != nil: call{"key"}.getStr("") else: "")

proc callLinesOf*(body: JsonNode): seq[CallLine] =
  ## The section's rows, in the order the engine sent them.
  if body == nil or body.kind != JObject: return
  let lines = body{"callLines"}
  if lines == nil or lines.kind != JArray: return
  let start = body{"startCallLineIndex"}.getBiggestInt(0)
  var i = 0'i64
  for node in lines:
    if node.kind == JObject:
      result.add callLineOf(node, start + i)
    inc i

# ---------------------------------------------------------------------------
#
# `ct/updated-events` carries a flat array of
#   { rrEventId, eventIndex, kind, semanticKind, metadata, content,
#     directLocationRRTicks, highLevelPath, highLevelLine, maxRRTicks, … }
#
# A ROW THAT CANNOT NAME A POSITION IS NOT A NAVIGATION ROW. On the real
# capture read for this module, `ct.mapping-rung` carries
# `directLocationRRTicks: -1` — it is an annotation about the recording as a
# whole and not about a moment in it. Rendering it with the other five would put
# a row in a navigation region that does nothing when clicked, which is the
# defect this module exists to remove wearing different clothes. So it is
# dropped here, at the one place that knows the tick, rather than being rendered
# and then specially handled by every consumer.

proc positionedEvents*(body: JsonNode): JsonNode =
  ## The subset of a `ct/updated-events` body whose rows name a position.
  ##
  ## A FILTER AND NOT A DECODE, which is the whole point of this proc existing
  ## beside a store that owns the decode. The two jobs used to be one here, and
  ## the decode half was a second copy of a mapping the Embed SDK now has —
  ## `replay_data_store.eventLogRowsFromJson`, whose own doc names the bare
  ## array this event carries as one of the three envelopes it reads. The
  ## filter half has no equivalent there and should not: *which* rows a
  ## NAVIGATION region may offer is a property of this pane, not of the wire.
  ## The desktop's event log deliberately shows rows that name no position —
  ## every `stdout` line is one — so a store that dropped them would be wrong
  ## for its other three consumers to serve this one.
  ##
  ## Returns a `JsonNode` rather than `seq[EventLogRow]` so that the SDK's
  ## decoder is the only thing in the path that ever reads a key of this
  ## payload. A filter that returned rows would have had to decode to filter.
  result = newJArray()
  if body == nil or body.kind != JArray: return
  for node in body:
    if node.kind != JObject: continue
    if node{"directLocationRRTicks"}.getBiggestInt(-1) < 0: continue
    result.add node

proc eventRowsOf*(body: JsonNode): seq[EventLogRow] =
  ## The rows that name a position, decoded by the SDK. See the note above on
  ## why the others are dropped rather than rendered, and `positionedEvents` on
  ## why the decode is not done here.
  eventLogRowsFromJson(positionedEvents(body))

# ---------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------

proc applied(feed: NavigationFeed) =
  if feed.onApplied != nil: feed.onApplied()

proc applyCalltrace*(feed: NavigationFeed; body: JsonNode) =
  ## A `ct/updated-calltrace` body, into the store.
  ##
  ## The store first and the host second, so the one re-render this triggers
  ## reads a store that already holds the section.
  if feed == nil or feed.store == nil: return
  let lines = callLinesOf(body)
  feed.sawCalltrace = true
  feed.calltraceLines = lines.len
  # An EMPTY section is applied rather than skipped. A trace really can have no
  # calls, and refusing to write it would leave whatever the previous section
  # put there — the same staleness, one pane over.
  feed.store.updateCalltraceSection(
    lines,
    startIndex = body{"startCallLineIndex"}.getBiggestInt(0),
    totalCount = uint64(max(0, body{"totalCallsCount"}.getBiggestInt(0))))
  feed.applied()

proc applyEvents*(feed: NavigationFeed; body: JsonNode) =
  ## A `ct/updated-events` body, into the EventLogVM.
  ##
  ## `appendLiveDebuggerStop` is the SDK's documented per-row writer and it
  ## deduplicates on identity, so replaying a section the engine re-sends adds
  ## nothing.
  ##
  ## RETAINED DELIBERATELY over the bulk `applyEventLogResponse` the store now
  ## also offers, and the reason is a semantic difference and not inertia: the
  ## bulk applier REPLACES the window, and this pane's `projectEventLog` pages
  ## `vm.eventRows` locally — it treats the signal as the whole log, not as one
  ## window. A `ct/updated-events` echo that carried a later section would then
  ## empty every page before it. Append-with-dedup is what "the log so far"
  ## means, and it is the same call as before; only what fills `rows` changed.
  if feed == nil or feed.eventLog == nil: return
  let rows = eventRowsOf(body)
  feed.sawEvents = true
  feed.eventRowsWritten = rows.len
  for row in rows:
    feed.eventLog.appendLiveDebuggerStop(row)
  feed.applied()

proc handleEvent*(feed: NavigationFeed; event: JsonNode) =
  ## One backend event. Everything that is not one of the two this module is
  ## named for is ignored — this is not a place to grow a second protocol layer.
  if feed == nil or event == nil or event.kind != JObject: return
  let name = event{"event"}.getStr("")
  if name.len == 0: return
  let body = if event.hasKey("body"): event["body"] else: nil
  case name
  of UpdatedCalltraceEvent: feed.applyCalltrace(body)
  of UpdatedEventsEvent: feed.applyEvents(body)
  else: discard

proc withLiveNavigation*(inner: BackendService;
                         feed: NavigationFeed): BackendService =
  ## `inner`, with the two navigation events read on their way in.
  ##
  ## The handler is registered HERE, once, rather than from the returned
  ## `onEventProc` — see the header. `inner` is returned unchanged otherwise:
  ## there is nothing to wrap on the way out, because the request that produces
  ## these events is one the store already sends.
  if inner != nil and inner.onEventProc != nil:
    inner.onEvent(proc(event: JsonNode) = feed.handleEvent(event))
  inner
