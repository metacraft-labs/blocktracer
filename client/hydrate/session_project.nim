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
##
## `./live_locals` is not an exception to that: it is a sibling in this same
## tree, on this same side of the line, and it reaches CodeTracer through the
## facade exactly as this file does. It is separate because it is the only
## thing here that reads a WIRE FORMAT rather than a ViewModel, and that is a
## different kind of knowledge with a different way of being wrong.

import std/[options, strutils]

import codetracer_embed

import ../src/debugger/deeplink_landing
import ../src/debugger/flow_view
import ../src/debugger/instruction_listing
import ../src/debugger/session_view
import ../src/debugger/source_island
import ./live_flow
import ./live_locals
import ./live_navigation
import ./live_origin
export deeplink_landing
# `flow_view` is in this module's PUBLIC surface — `projectFlowWindow` returns
# its `FlowWindowInput` and `applyLiveFlow` takes its `EditorPane` — so a
# consumer that could call them but not name their types would have to reach
# past this facade to use it.
export flow_view
export live_flow
export live_locals
export live_navigation
export live_origin

# ---------------------------------------------------------------------------
# One store, one backend, five ViewModels
# ---------------------------------------------------------------------------

type
  PositionReport* = ref object
    ## WHETHER THE ENGINE HAS STATED A POSITION FOR THIS SESSION — the fact
    ## itself, carried explicitly, because every attempt to infer it from the
    ## step has been wrong.
    ##
    ## `ReplayDataStore` initialises `debugger.rrTicks` to `0`, so a session that
    ## has heard nothing and a session the engine has parked on the FIRST STEP OF
    ## THE TRACE hold the same number. Reading `step > 0` as "the engine has
    ## reported" therefore silently misclassifies tick 0, which is not a
    ## degenerate case: it is where `run-to-entry` lands, and it is the
    ## `data-step` of the first row of the call trace and the event log, so
    ## "click the first row" is the ordinary gesture that produces it.
    ##
    ## That sentinel shipped, and it broke the jump: a click on a row whose step
    ## is 0 produced an engine report indistinguishable from silence, the served
    ## frame won, and the session did not move
    ## (`09-a-jump-moves-the-position`). The flag exists so that no site has to
    ## ask "is this step real" of a number that cannot answer.
    ##
    ## A `ref` so that it survives being copied. `LiveSession` is an object of
    ## handles passed BY VALUE into the projection, and a plain `bool` field
    ## would be copied at that boundary — the projection would read one session's
    ## answer off another session's copy. One cell, shared by every copy, has one
    ## answer.
    arrived*: bool

  LiveSession* = object
    ## The five ViewModels of one session, plus the store they all read.
    ##
    ## An object of handles and not a `ref` with behaviour: the projection is a
    ## pure function of these, and giving it a lifecycle would create a second
    ## place where "what the panes show" is decided.
    store*: ReplayDataStore
    reported*: PositionReport
      ## Set the moment a stop is written through `applyPosition`, whatever tick
      ## it names. Read by `projectReplayPanes` and by nothing else.
    editor*: EditorVM
    calltrace*: CalltraceVM
    state*: StateVM
    eventLog*: EventLogVM
    controls*: DebugControlsVM
    originChain*: OriginChainVM
      ## The sixth ViewModel, and the one BlockTracer built five of and not
      ## this. It is driven entirely by the visitor — no auto-load effect —
      ## so it costs nothing on a session where nobody asks for an origin.
    origin*: OriginFeed
      ## The `ct/originChain` reply and the `ct/updated-origin-chain` event,
      ## which `OriginChainVM` issues and discards for itself
      ## (`live_origin.nim`). Beside `locals` and `navigation`, and for the
      ## third time the same reason: the engine answers, the pinned consumer
      ## drops it, and the surface looks like a missing feature.
    navigation*: NavigationFeed
      ## The `ct/updated-calltrace` and `ct/updated-events` payloads this
      ## session's store and EventLogVM cannot read for themselves
      ## (`live_navigation.nim`). Beside `locals` for the same reason and with
      ## the same shape: the engine answers, the pinned consumer drops it, and
      ## a pane that had never once shown a live row looked healthy because the
      ## static export shipped fixture rows for the demo chain.
    locals*: LocalsFeed
      ## The `ct/load-locals` traffic this session's store cannot read for
      ## itself (`live_locals.nim`). Held beside the ViewModels rather than
      ## inside one because it is not a ViewModel: it is what the pinned store
      ## would hold if its `requestLocals` kept the reply, and `projectState`
      ## reads it for exactly the reason `projectEditor` reads the store's
      ## position — the VM exposes the values but not whether they are THIS
      ## position's.
    flowWindow*: FlowFeed
      ## The `ct/updated-flow` STEPS this session's `FlowVM` cannot read for
      ## itself (`live_flow.nim`). Beside `locals` and `navigation` for the same
      ## reason and with the same shape, and it is the fifth time this exact
      ## shape has been found here: the engine answers in full, the pinned
      ## consumer keeps a part of the answer, and the pane looked healthy
      ## because the static export shipped a real overlay for the served frame.
      ##
      ## Measured on the wire before it was written — see `live_flow`'s header
      ## for the numbers, including the one that names the defect: 23 value
      ## labels on the served frame, 0 after hydration, 0 after four steps,
      ## with a window carrying 13 lines' worth of values arriving for every
      ## one of those positions.
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
  CalltraceViewportDepth* = 20
    ## The nesting the first request asks for. `DEFAULT_VIEWPORT_DEPTH` in the
    ## SDK, restated here for the same reason `CalltraceViewportRows` is: the
    ## request this module re-issues has to ask for the same window the VM's own
    ## effect asks for, or the two would disagree about what "the section" is.

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

  NoSourceOriginNote* =
    "This recording carries no source, so a value cannot be traced to its " &
    "origin: the origin is read from the line that assigned the value, and " &
    "an Aztec contract class does not publish one."
    ## The §14 sentence for a recording that cannot support the capability.
    ##
    ## Written in the register `demo_session.nim` already uses for the sibling
    ## fact ("This recording carries no variable names: naming a local needs
    ## debug symbols, which an Aztec contract class does not publish") — states
    ## what is missing, why it is missing, and stops. It does not apologise and
    ## it does not promise the feature later, because for this recording there
    ## is no later.

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
  ##   * the locals feed. `createReplayDataStore` is given the DECORATED
  ##     backend, so the `ct/load-locals` request `StateVM`'s own effect issues
  ##     on every move passes through `live_locals` and its reply is read on
  ##     the way back. Wrapping here rather than at the call site is what makes
  ##     it true of every session — the browser's and `tests/tdebugpanes.nim`'s
  ##     alike — instead of true of whichever caller remembered.
  ##   * the navigation feed. The same arrangement for the Call Trace and the
  ##     Event Log, whose payloads arrive as EVENTS rather than as responses —
  ##     `live_navigation` registers one handler on the decorated backend and
  ##     writes `updateCalltraceSection` / `appendLiveDebuggerStop`, which
  ##     nothing in this repository called outside `tests/tdebugpanes.nim`.
  let feed = LocalsFeed()
  let nav = NavigationFeed()
  let origin = OriginFeed()
  let flowWindow = FlowFeed()
  let store = createReplayDataStore(
    withLiveFlow(
      withLiveOrigin(withLiveNavigation(withLiveLocals(backend, feed), nav),
                     origin),
      flowWindow))
  feed.store = store
  feed.sourcePublished = sourceIsPublished
  nav.store = store
  store.setSessionMode(completedReplay)
  store.setSourceAvailability(
    if sourceIsPublished: savVerified else: savUnverified)
  result = LiveSession(
    store: store,
    # Constructed here and never left nil, so `projectReplayPanes` reads a fact
    # rather than testing a handle. A session that has not heard from the engine
    # says so with `arrived == false`, which is a different sentence from "there
    # is no cell to ask".
    reported: PositionReport(arrived: false),
    locals: feed,
    navigation: nav,
    editor: createEditorVM(store),
    calltrace: createCalltraceVM(store),
    state: createStateVM(store),
    eventLog: createEventLogVM(store),
    controls: createDebugControlsVM(store),
    originChain: createOriginChainVM(store),
    origin: origin,
    flowWindow: flowWindow,
    flow: createFlowVM(store))
  # AFTER the VMs exist: the feed writes event rows through the EventLogVM's own
  # `appendLiveDebuggerStop`, so it needs the handle the line above creates. The
  # handler registered inside `withLiveNavigation` reads this field when an
  # event arrives, which is necessarily later than here.
  nav.eventLog = result.eventLog
  # The same knot, tied for the locals' summaries and for the chain: both VMs
  # are built on the store which is built on the decorations, so neither could
  # have been handed to its feed at construction time.
  feed.state = result.state
  origin.chain = result.originChain
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
  # THE ENGINE HAS SPOKEN, whatever it said. Set unconditionally and never
  # cleared: `ticks` is the position the engine reported, and `0` is as real an
  # answer as any other — it is the first step of the trace, where run-to-entry
  # lands and what the first navigable row of every region carries. Anything
  # that gates this on the value would rebuild the sentinel this flag exists to
  # remove.
  if s.reported != nil: s.reported.arrived = true
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
    # INSTRUCTION LEVEL, AND IT STEPS. This branch used to throw the served pane
    # away and return a bare reason, which was right while there was nothing to
    # keep: the pane had no rows. It has rows now — the recording's own program
    # counters, one per step — and they are already in the island, because the
    # island is a serialisation of whatever documents the export rendered and
    # does not care what kind of document they are.
    #
    # So the listing survives the first step instead of vanishing on it. What
    # moves is the MARK, and it moves the way it does at source level: the pane
    # is re-decoded at the engine's position on every stop, so exactly one row is
    # current and it is the row the session is standing on.
    #
    # THE POSITION IS THE TICK, NOT THE ENGINE'S FILE AND LINE. At this fidelity
    # `location.line` is a program counter and `location.file` names a bytecode
    # object, so joining on them would resolve a step against a coordinate the
    # listing is not indexed by — and a program counter repeats the moment the
    # execution loops, which is precisely when a reader most needs the mark to be
    # on the right row. `rrTicks` is the session's own coordinate: it is what a
    # share link anchors to and what `data-step` carries.
    #
    # The listing is numbered in that same coordinate — row `n` is tick `n`,
    # from zero — so the join is the identity and there is nothing to convert.
    # That is the reason for the numbering: any other and the position head,
    # which states the tick, would name a different row from the one highlighted
    # beside it on every hydrated page.
    if island.len == 0:
      result.availability = SourceAvailabilityView.srcUnverified
      result.reason = "No source bundle is published for the code that ran."
    else:
      result = decodeSourceIsland(island, ListingPath,
                                  int(store.debugger.val.rrTicks))
      # The island's own availability is `unverified` already; restated for the
      # same reason the branch above restates it, so a malformed island that
      # decoded to `srcAbsent` cannot make a live instruction-level session
      # claim that no contract code ran.
      result.availability = SourceAvailabilityView.srcUnverified
      if result.documents.len == 0:
        result.reason = "No source bundle is published for the code that ran."
  else:
    result.availability = SourceAvailabilityView.srcAbsent
    result.reason = "This execution ran no contract code."

proc projectFlowWindow*(feed: FlowFeed; pane: EditorPane;
                        ticks: uint64): FlowWindowInput =
  ## The engine's window, joined to the page's source text.
  ##
  ## Two halves of one overlay that come from two places, which is
  ## `FlowLayoutWindow`'s own design ("who owns the source differs per
  ## consumer"): the engine sends the recorded values and knows nothing about
  ## what this page published, and the page holds the text and knows nothing
  ## about what ran. Only here are both present.
  ##
  ## ## The path is RESOLVED and not compared
  ##
  ## `location.path` is an absolute path on the recording machine —
  ## `/private/tmp/blocktracer-fixture-rec/noir_space_ship/src/main.nr` on the
  ## published fixture — while the pane's documents carry the path the trace
  ## interned, `src/main.nr`. A `==` between them is false for every real
  ## session, which would present as an overlay that silently never appears; and
  ## `flow_view.applyFlow` matches its input's path against the documents with
  ## `==`, so the resolution has to happen HERE and the resolved path has to be
  ## the one handed on.
  ##
  ## `source_island.positionDocumentIndex` is the resolver, and it is the same
  ## one `decodeSourceIsland` uses to decide which document the POSITION is in —
  ## longest matching suffix, resolved against the whole document list rather
  ## than one document at a time. Two different answers to "which file is the
  ## engine talking about" on one page would put the values in a different file
  ## from the current-line mark, which is a failure a reader could not see.
  ##
  ## An unresolvable path yields an input with an empty `path`, which
  ## `applyFlow` refuses — the honest reading of "no window has been loaded for
  ## any file this page is showing".
  if feed == nil: return
  # A window that named no file resolves to NOTHING, explicitly. The suffix rule
  # is written for two spellings of one real path and says nothing useful about
  # the empty string; letting it decide would make "the engine did not say which
  # file" indistinguishable from "the engine said this one", and the values
  # would land on whichever document sorted first. That is the invented-overlay
  # failure with no wrong data in it at all.
  if feed.enginePath.len == 0: return
  var paths: seq[string]
  for doc in pane.documents: paths.add doc.path
  let index = positionDocumentIndex(paths, feed.enginePath)
  if index < 0: return
  result.path = pane.documents[index].path
  result.returns = feed.returns
  # THE SESSION'S TICK, NOT THE WINDOW'S. `locationTicks` decides which loop
  # pass the overlay shows and which pass the rail opens on, and that is a
  # question about where the DEBUGGER is — `flow_view` rule 2, and issue #593,
  # which was a counter that read pass 1 of 8 for as long as the session lasted.
  # The window's own `location.rrTicks` is the engine's answer to a different
  # question and, measured on every answer this build receives, is 0 (journey
  # 15) — so reading it would pin every session to pass 0. `feed.locationTicks`
  # is kept on the feed and is what journey 19 reads; nothing draws from it.
  result.locationTicks = int(ticks)
  result.functionLabel = feed.functionLabel
  result.window = feed.window
  # The text, line for line, from the document the engine's path resolved to.
  # `SourceLine.text` and not the island's raw blob: the pane is what the
  # renderer draws, so placing an expression against anything else would let the
  # column a label is computed at and the line it is drawn on come from two
  # different strings.
  #
  # `sourceLines` is indexed from zero for line 1 (`FlowLayoutWindow.lineText`),
  # and an instruction listing's rows start at 0, so the offset is taken from
  # the document rather than assumed. A window whose first line is not 1 that
  # was indexed as though it were would place every label one row off — which
  # renders perfectly and is wrong everywhere.
  var lines: seq[string] = @[]
  for line in pane.documents[index].lines:
    while lines.len < max(0, line.number - 1): lines.add ""
    lines.add line.text
  result.window.sourceLines = lines

proc applyLiveFlow*(pane: var EditorPane; feed: FlowFeed;
                    ticks: uint64): bool =
  ## Draw the engine's window on the pane, if the window is THIS position's.
  ##
  ## The return value is the whole contract: `true` means the overlay and the
  ## rail on this pane both came from `feed`, `false` means nothing was written
  ## and the caller still owns the rail. It is a `bool` and not a silent
  ## mutation because the alternative — calling `applyFlow` unconditionally —
  ## would CLEAR the rail on every position whose window has not landed yet
  ## (`applyFlow` clears before it decides), so a session would flicker the loop
  ## control off and on at every step.
  ##
  ## `ticks` is the SESSION's position and it is what the overlay is laid out
  ## for — see `projectFlowWindow`. It is not a staleness gate: `hasWindow`'s
  ## header records why the tick stopped being one and what refuses a window
  ## that belongs to another file.
  if not feed.hasWindow(): return false
  let input = projectFlowWindow(feed, pane, ticks)
  if input.path.len == 0: return false
  applyFlow(pane, input)
  true

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
    # A SAME-PAGE FRAGMENT, and on this surface that is right: hydration runs on
    # the debug route, which renders every line of the document (`pages/debug`
    # and `hydrate/hydrate` both do), so the header line is on the page. The one
    # surface that narrows is the home page's embed, which carries no engine and
    # never reaches here — see `source_document.windowAround`, which is where a
    # narrowing has to re-aim this.
    href: "#" & lineAnchor(path, loop.registeredLine),
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
      # The frame's own source line, from the same `Location` the path comes
      # from — so a live row's coordinate and its path can never describe two
      # different places. `0` when the recording has no line for the call,
      # which the renderer draws as nothing rather than as `:0`.
      line: line.location.line,
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

proc selectCalltraceFrame*(s: LiveSession; anchor: string): bool =
  ## Make the frame `anchor` names the selected one, so the next projection
  ## marks THAT row and no other.
  ##
  ## ## Why this exists, when `projectCalltrace` above already renders a mark
  ##
  ## It renders `current: vm.selectedEntry.val == some(line.index)` — a
  ## SELECTION, not a coordinate comparison — and it has been right the whole
  ## time. Nothing ever wrote `selectedEntry`, so the comparison was against
  ## `none` on every row of every stop, and a hydrated session drew its frames
  ## with none of them marked. `session_view` records the measurement: "49
  ## frames drawn, none marked." The renderer was not the missing half; the
  ## write was.
  ##
  ## ## Why the anchor is what comes in, and an index is not
  ##
  ## The caller is a click on a row in the DOM, and what that row carries is
  ## `data-anchor`. It could carry a row ordinal instead, and that ordinal would
  ## be wrong twice over: the served page's rows are the static export's and the
  ## live pane's are the engine's, so an ordinal minted by one producer would be
  ## read by the other, and `CalltraceVM` indexes entries from
  ## `startLineIndex` — a windowed pane's first row is not entry zero. The
  ## anchor is a call PATH, both producers derive it from the same function, and
  ## it survives both.
  ##
  ## ## A miss CLEARS, and that is the same contract one layer down
  ##
  ## `false` when the anchor names no frame in the live pane: an event-log row,
  ## whose anchor is a `log:` or `sw:` and names no frame by construction; a
  ## flow segment, which carries none at all; or a served call-trace row the
  ## engine's window does not currently hold. In every one of those the reader
  ## has navigated by something that is not a frame, so the previous selection
  ## stops describing where they are — and a mark left behind would go on
  ## asserting a frame the reader has since navigated away from. It is retired
  ## rather than kept.
  ##
  ## The two layers differ here, and deliberately. `hydrate.markServedFrame`,
  ## which marks the SERVED rows for an incoming deep link, returns without
  ## touching a row on a miss — it must, because a link that names no frame
  ## (an ordinary visit, a `log:` anchor) has to leave the static producer's own
  ## mark alone rather than strip the page's answer and put nothing back. This
  ## layer clears, because here a miss is a GESTURE: the reader clicked
  ## something, and the honest report of "which frame did they choose" is
  ## `none`, not the frame they chose before.
  ##
  ## The caller keeps the seek it was going to do anyway, so a row still moves
  ## the session; it just cannot also claim to have selected a frame.
  ## ## The anchors are recomputed here rather than taken from `projectCalltrace`
  ##
  ## This used to call the full projection and match against its frames.
  ## `projectCalltrace` is a much larger function than it looks: it fills every
  ## pane field and builds a §6.0a URL per frame through `positionQuery`, so a
  ## click was minting forty-six deep links in order to throw all forty-six
  ## away. That is a per-click waste rather than a bundle one — measured, the
  ## bundle is the same size either way — and it is removed because a gesture on
  ## the 16 ms path should not build URLs nobody reads.
  ##
  ## An anchor is a function of the DEPTHS and nothing else — `callPath` reads
  ## no other field — so this builds the one column it needs and stamps it with
  ## the same shared `withCallAnchors` both producers use. The paths are
  ## therefore identical to the ones the pane renders, by construction rather
  ## than by coincidence, which is the property `withCallAnchors` exists to
  ## guarantee; if this derived them a second way, a click could disagree with
  ## the row it clicked.
  let lines = s.calltrace.visibleLines.val
  var probe = CallTracePane(frames: newSeq[CallFrame](lines.len))
  for k in 0 ..< lines.len:
    probe.frames[k].depth = lines[k].depth
  withCallAnchors(probe)
  let i = frameOfAnchor(probe.frames, anchor)
  if i < 0:
    s.calltrace.selectEntry(none(int64))
    return false
  # `visibleLines` is what the anchors were derived from just above, so frame
  # `i` IS line `i`. The index is read off the line rather than carried on the
  # frame because `CallFrame` has no entry index and must not grow one: it is
  # the live ViewModel's private numbering, and putting it on the shared pane
  # type would hand the static producer a field it can only fill with a lie.
  if i >= lines.len: return false
  # THE SDK'S SETTER, AND IT COSTS 140,588 BYTES OF BUNDLE — 8% — WHICH IS
  # ACCEPTED RATHER THAN UNNOTICED.
  #
  # Measured three ways on the same three pins, changing one call site at a
  # time: 1,746,191 bytes with this whole proc unreachable, 1,749,615 with it
  # reachable but writing `selectedEntry.val` directly, 1,890,203 through
  # `selectEntry`. The difference is not this proc — it is `CalltraceVM.
  # selectEntry`'s first branch, `collabCore.dispatchLocalViewOp(
  # vokSetCalltraceSelection, …)`, which pulls the whole local-view-op and
  # collaboration graph into a bundle that has no collaboration in it: this
  # product never constructs a `collabCore`, so that branch cannot be taken here
  # and every byte of it is dead at runtime.
  #
  # It is still called, because the alternative is writing a public Signal
  # behind its own setter's back. `selectEntry` is the API `CalltraceVM`
  # publishes for exactly this, and a consumer that assigns the field directly
  # silently opts out of whatever that setter is next taught to do — the
  # dead-code saving would be paid for with a seam that breaks without a
  # symptom. The 140 KB is also 0.8% of what this route already fetches, since
  # the same page pulls an 18 MB replay engine. If it ever matters, the fix
  # belongs in the SDK — a `selectEntry` whose collab branch is behind a
  # compile-time switch — and not in a local bypass here.
  s.calltrace.selectEntry(some(lines[i].index))
  true

proc applyLocals*(s: LiveSession; variables: seq[Variable]) =
  ## Mirror a backend locals response into the store, as the session's own
  ## position's.
  ##
  ## `store.updateLocals` is the SDK's documented bridge for a host that has
  ## already parsed a reply, and it is the whole of what a caller needed before
  ## the pane knew WHICH position its values belong to. It is not the whole of
  ## it now: values in the store with no statement about their position is the
  ## condition `projectState` refuses to render, so a driver that writes the
  ## store directly says here that it is writing this position's.
  s.store.updateLocals(variables)
  s.locals.adopt(s.store.debugger.val.rrTicks)

proc projectState*(vm: StateVM; feed: LocalsFeed; ticks: uint64): StatePane =
  ## The values at the position the session is AT, or the reason there are
  ## none to show.
  ##
  ## `feed` is the second argument because `currentVariables` alone cannot
  ## answer the question the pane asks. It is a memo over `store.locals.locals`,
  ## which holds whatever was last written into it — the previous position's
  ## values while this position's are in flight, and nothing at all for the life
  ## of a session whose store discards every reply. Neither of those is "the
  ## values here", and a pane that rendered them as if they were is the defect
  ## `live_locals` exists to close.
  ##
  ## `note` is what `renderState` draws when there are no values, and it is
  ## produced for EVERY state that is not "this position's values are in the
  ## store". So a live session's State pane always has something in it, which
  ## is what makes `renderPanes`' latch replace the statically exported one —
  ## the served frame's values are never left standing as a fallback.
  result.note = feed.noteFor(ticks, vm.currentVariables.val.len)
  if result.note.len > 0: return
  # WHY NO VALUE HERE CAN BE TRACED, when none can — said once, and said only
  # for the recording that cannot rather than for the value that happened not
  # to be. The origin classifier parses the right-hand side of a source
  # assignment, so a recording that published no source has nothing for it to
  # read; every chain capture this explorer publishes is in that state and
  # will stay there. Stating it is the correct behaviour for those sessions,
  # and it is what the alternative — a row of controls that each answer
  # "unknown" — would have hidden.
  if not feed.sourcePublished:
    result.originNote = NoSourceOriginNote
  for v in vm.currentVariables.val:
    let summary = vm.originSummaryFor(v.name)
    # WHAT THE LAST MOTION CHANGED, from the position the session came from.
    #
    # A time-travel session needs no extra recording for this: the prior
    # position is still queryable, and `LocalsFeed` has already held its values
    # on the way past. `diffFor` answers for one row; the feed decides whether
    # the question is answerable at all (`baselineValid`) and says "unchanged"
    # for every row when it is not — a marker on a guess would be worse than no
    # marker.
    #
    # `changed` used to be `vm.selectedPath.val == v.name`, which is a different
    # fact wearing this one's name: it lit the "changed at this step" hue on
    # whichever row the VM had selected, so the pane's only colour said
    # "selected" while its stylesheet said "changed".
    let diff = feed.diffFor(v.name, v.value)
    result.values.add StateValue(
      name: v.name, typ: v.typeName, value: v.value,
      changed: diff == dvChanged,
      appeared: diff == dvAppeared,
      # The control is offered for a CLASSIFIED origin and for nothing else —
      # see `classifiedOriginOf`. A summary is present on essentially every
      # local (6 of 6, measured), so "has a summary" would put a control
      # everywhere; what varies is whether the summary says anything.
      origin: (if summary.isSome: classifiedOriginOf(summary.get) else: ""))

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
                      live: bool; engineReported: bool;
                      served = DebugControlsPane()): DebugControlsPane =
  ## The toolbar, in the order `session_view.DebugAction` declares — which is
  ## CodeTracer's desktop order, backward first in each pair.
  ##
  ## `live` is separate from the per-button capability and gates all of them:
  ## before the engine is ready every button is inert whatever the VM's memos
  ## say, because those memos have a value from the moment the store exists and
  ## it is not yet a statement about a running engine.
  ##
  ## `engineReported` is whether `step` MEANS anything, and `served` is what to
  ## show while it does not. They are two parameters and not one derived
  ## quantity, which is the correction this proc exists in its current shape to
  ## record.
  ##
  ## ## Why not `step > 0`
  ##
  ## `ReplayDataStore` initialises `debugger.rrTicks` to `0`, so a session that
  ## has heard nothing from the engine and a session the engine has parked on the
  ## first step of the trace hold the same number. This proc previously read
  ## `step > 0` as "the engine has reported a frame" — and said so in a comment,
  ## which is how a reviewer, an author and an approver all read past it.
  ##
  ## It is wrong, and not at a boundary nobody visits: tick 0 is where
  ## `run-to-entry` lands, and it is the `data-step` of the FIRST ROW of the call
  ## trace and the event log. So "click the first row" produced an engine report
  ## indistinguishable from silence, the served frame won, the session did not
  ## move, and `09-a-jump-moves-the-position` went red on `dev` — while a
  ## measured before/after at step 128, three mutation arms, and a suite of nine
  ## all stayed green, because not one of them exercised 0.
  ##
  ## The lesson generalises past this proc: when a fix turns on a comparison
  ## against a constant, that constant is the value the tests must include. It is
  ## pinned here by "a session AT step 0 is positioned, and its playhead is on
  ## the first tick" in `tests/tdebugpanes.nim`.
  ##
  ## ## What the two parameters buy
  ##
  ## The engine's answer wins whenever there is one, at tick 0 as at any other.
  ## Until there is one the served frame stands, which keeps the position
  ## monotonic across hydration — Page-Descriptions §7.0's "**No state renders
  ## less than the pre-hydration page**" — and is the loss journey 06's header
  ## records observing ("its hydrated session lands at step 0 of 345") without
  ## asserting, its own implication being guarded by `step > 0` and so passing
  ## VACUOUSLY in exactly the state that was broken.
  # Every action, in declaration order, which is the toolbar's order. The name
  # and the mark come from the action (`controlLabel`, `components/icons`), so
  # this producer and `demo_session.fixtureControls` cannot disagree about
  # either — they used to hold a copy each, and the copies drifted.
  result.buttons = @[]
  for a in DebugAction:
    result.buttons.add ControlButton(action: a, enabled: live and canDo(vm, a))
  result.statusText = vm.statusText.val
  # The engine's tick when it has stated one — INCLUDING 0 — and the served
  # page's when it has not. Neither line asks anything of the step's value.
  result.step = if engineReported: step else: served.step
  result.totalSteps = total
  result.positioned = engineReported or served.positioned

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
    # THE VALUES FIRST, AND THE RAIL ONLY IF THEY DID NOT ARRIVE.
    #
    # `applyFlow` builds the rail itself, out of the same window the labels come
    # from, so calling both would set it twice from two parsers — the "two
    # producers of one fact" arrangement this route has already been bitten by.
    # When the engine's window is this position's, it is the one producer; when
    # it is not, `projectFlowRail` is what the pane had before this line existed
    # and the pane keeps it, so nothing regresses on a session whose window has
    # not landed yet.
    if not applyLiveFlow(result.editor, s.flowWindow,
                         s.store.debugger.val.rrTicks):
      result.editor.flow =
        projectFlowRail(s.flow, s.store.debugger.val.location.file)
  # `base.traceContentHash` and not a value from the engine: §6.0's witness is
  # a fact about the artifact the PAGE recommends, which the served DOM carries
  # and the engine has no opinion about. Reading it from `base` is also what
  # keeps the rows' links pointing at the same trace the metadata pane
  # describes.
  result.calltrace = projectCalltrace(s.calltrace, base.traceContentHash)
  result.state = projectState(s.state, s.locals, s.store.debugger.val.rrTicks)
  result.eventLog = projectEventLog(s.eventLog, base.traceContentHash)
  # `base.controls` and not `base.controls.totalSteps` alone: the served frame's
  # STEP is inherited for the same reason its total is, and for the window in
  # which the engine has not yet stated one. See `projectControls`.
  #
  # `engineReported` comes off the session's own cell and NOT off the step, which
  # is the whole of the fix: `s.reported.arrived` is set by `applyPosition` when
  # a frame arrives, so tick 0 reports as loudly as tick 128.
  result.controls = projectControls(
    s.controls, int(s.store.debugger.val.rrTicks), base.controls.totalSteps,
    live = true,
    engineReported = (s.reported != nil and s.reported.arrived),
    served = base.controls)
  result.integrity =
    if s.controls.divergenceDetected.val: siDivergent
    elif s.controls.traceTruncated.val: siTruncated
    else: base.integrity

proc requestNavigationSections*(s: LiveSession) =
  ## Ask the engine for the call trace, now that there is an engine to ask.
  ##
  ## `CalltraceVM`'s auto-load effect fires the moment the VM is CONSTRUCTED,
  ## which `goLive`'s own comment records is several hundred milliseconds before
  ## `startWorker` — so `postJson` finds no worker, drops the message, and the
  ## effect does not run again until something it reads changes. Clearing the
  ## `RequestTracker` (which `goLive` does) unblocks the NEXT request; it does
  ## not re-issue the one that was thrown away.
  ##
  ## For the call trace it is the difference between a pane that fills on
  ## arrival and one that stays empty until the visitor happens to step — which
  ## is what a visitor landing on a transaction saw: an empty Call Trace, and no
  ## row to click.
  ##
  ## THIS COMMENT USED TO CONTINUE "for locals that costs nothing, because
  ## `StateVM`'s effect re-fires on every move", and that sentence is why the
  ## Values pane kept the defect this one fixed for a week. See
  ## `requestLandingLocals` for what it got wrong: arriving is not a move.
  ##
  ## Issued through the store's own public request rather than by nudging a
  ## signal to make the effect re-run: a re-entry that depended on which signal
  ## the SDK's effect happens to read would break silently on any upstream
  ## change, and this says what it means.
  if s.store == nil: return
  let dbg = s.store.debugger.val
  s.store.requestCalltraceSection(
    startIndex = 0,
    height = CalltraceViewportRows,
    depth = CalltraceViewportDepth,
    rrTicks = dbg.rrTicks,
    file = dbg.location.file,
    line = dbg.location.line)

proc requestLandingLocals*(s: LiveSession) =
  ## Ask the engine for the values at the position the session LANDS on.
  ##
  ## ## ARRIVING IS NOT A MOVE, AND THAT IS THE WHOLE DEFECT
  ##
  ## `requestNavigationSections` above used to excuse the Values pane from the
  ## same treatment on the grounds that "`StateVM`'s effect re-fires on every
  ## move". The effect does. The first position a session takes is not reached
  ## by moving.
  ##
  ## THE SEQUENCE, MEASURED IN A BROWSER by logging
  ## `store.requestTracker.hasPending("load-locals")` at each of the three
  ## points below on the deployed engine and a real chain container, rather
  ## than reasoned about:
  ##
  ##   1. `openLiveSession` constructs the ViewModels. `StateVM`'s effect runs
  ##      immediately and calls `requestLocals(0)`, which marks `load-locals`
  ##      pending and sends — several hundred milliseconds before
  ##      `startWorker`, so `postJson` finds no worker and drops the message.
  ##      The future never settles, so `markComplete` never runs and the entry
  ##      stays pending.
  ##   2. `hydrate` seeds the store with the SERVED frame's position. That is
  ##      the one write that genuinely changes `store.debugger`, so it is the
  ##      one that re-runs the effect — and `requestLocals` finds its own key
  ##      and arguments already pending from step 1 and SKIPS THE SEND.
  ##      Measured at `goLive`, before its clear: `hasPending` is `true`.
  ##   3. `goLive` clears the tracker. One moment too late: every later write
  ##      of the position — the `stackTrace` reply, the `ct/complete-move` —
  ##      writes the SAME coordinate the served frame already put there, the
  ##      signal does not change, and the effect never runs again.
  ##
  ## So the request was issued exactly once, into nothing, and the pane waited
  ## on a reply to a message that was never delivered. Measured against
  ## `blocktracer-dev.pages.dev` on a real chain transaction: `ct/load-locals`
  ## requests reaching the engine at landing, ZERO; Values rows, ZERO; the pane
  ## reading "Reading the values at this position…" for as long as the tab was
  ## open. One click of Step forward moved the store to a coordinate nothing
  ## had asked about, the effect issued a request that was not a duplicate, and
  ## the same pane filled with five rows. The values were there the whole time.
  ##
  ## The Call Trace escaped it by luck rather than by design: `CalltraceVM`'s
  ## auto-load reads the viewport height as well as the position, and that
  ## changes between construction and first paint — so its second run carried
  ## different arguments, was not deduplicated, and went out. One pane in this
  ## pair has been fixed twice for one cause; this is the other half.
  ##
  ## ## WHY IT IS SAFE TO ASK FOR A POSITION THE STOP HAS NOT ARRIVED AT
  ##
  ## `goLive` runs on the `threads` reply, before the first `stackTrace`, so
  ## the coordinate read here is the store's — which for every ordinary visit
  ## IS the entry frame the engine is about to report. A deep link that seeks
  ## elsewhere moves the store to a coordinate this request did not name, and
  ## `StateVM`'s effect issues that one on its own, because THAT is a move.
  ## Neither answer can be shown under the wrong position: `live_locals.knows`
  ## requires a completed reply for the exact `rrTicks` the pane is rendering,
  ## so a reply for the entry frame under a sought position produces the
  ## sentence, never the wrong values.
  ##
  ## ## AND IT MUST BE CALLED AFTER `locals.scheduleTimeout` IS INSTALLED
  ##
  ## `LocalsFeed.awaiting` arms §8's deadline from `scheduleTimeout`, and a
  ## request issued while that hook is still nil is a request with no deadline
  ## — which would leave the pane on "Reading…" forever in exactly the case the
  ## deadline exists for. `goLive` orders the two, and this is the reason.
  if s.store == nil: return
  s.store.requestLocals(s.store.debugger.val.rrTicks)
