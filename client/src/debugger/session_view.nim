## The projection the debug route's panes render — one frame of a replay
## session, as plain data.
##
## ## Why this type exists at all
##
## The five panes BlockTracer shows are CodeTracer's (`EditorVM`,
## `CalltraceVM`, `StateVM`, `EventLogVM`, `DebugControlsVM`), and they are
## reactive: signals, memos, an owner scope, a `BackendService` underneath. The
## debug route is rendered by `static_export.nim`, which is a `nim c` of the
## client with **isonim and nim-everywhere on the Nim path and nothing else**
## (`flake.nix`, `packages.default`). Those two facts cannot both be served by
## having the pane renderers read ViewModels directly.
##
## So the renderers read *this* instead: a settled, renderer-free snapshot of
## what the five panes contain at one time coordinate. It has two producers,
## and the split is deliberate:
##
##   * `demo_session.nim` — the static tree's producer. Everything it can
##     derive from published data it derives (identity, outcome, cost, the
##     manifest's execution summary, the source bundle); the replay content it
##     cannot derive without an engine it supplies as clearly-labelled fixture
##     data, exactly as `MockBackendService` does for CodeTracer's own unit
##     tests. That is what makes the debug route renderable today.
##
##   * `tests/tdebugpanes.nim` — the SDK producer, compiled against the real
##     Embed SDK. It drives the five ViewModels through `MockBackendService`
##     and projects them onto the types below, then renders the same panes over
##     the result. This is the half that proves the renderers are renderers of
##     *session* data and not of a bespoke fixture shape.
##
## When `WorkerBackendService` lands, hydration replaces producer one with a
## live session and neither the types below nor a single pane renderer changes.
##
## ## Deliberately not here
##
## No signals, no reactivity, no engine, no measurement and no CSS. A field
## here is a value a pane displays; anything a pane would *compute* belongs to
## the ViewModel that owns it, upstream of this projection.

import std/strutils
import ./source_highlight
export source_highlight

# ---------------------------------------------------------------------------
# Phases — Page-Descriptions §8: "Loading is phased and honest — fetching,
# then opening, then positioning — never an indeterminate spinner."
# ---------------------------------------------------------------------------

type
  SessionPhase* = enum
    ## Where the replay **engine** is. Not where the panes are — `hasFrame`
    ## answers that, and the two are deliberately separate.
    ##
    ## The separation is the whole of §7.0 made into a type. The static route
    ## serves a complete, positioned first frame out of published data while
    ## the engine — an 18 MB wasm bundle plus its worker, loaded from
    ## `replay_engine.ReplayEngineBase` — has not been fetched at all. A single
    ## field cannot say both "there is a step on screen" and "nothing can move
    ## it yet", and a page that collapsed them would either draw a loading
    ## skeleton over content it already has, or present inert controls as live
    ## ones. Both are lies this milestone is specifically trying not to tell.
    ##
    ## An enum, not a percentage and not a bool, because §8 requires the page
    ## to *name* the phase.
    spFetching = "fetching"
      ## The engine has not arrived. **This is what the static route serves**,
      ## with the panes already populated behind it.
    spOpening = "opening"
      ## The container is open; the engine is starting.
    spPositioning = "positioning"
      ## Seeking to the requested time coordinate before first paint.
    spReady = "ready"
      ## The engine is live and positioned: the controls can move time. Only
      ## hydration produces this, so no statically exported page carries it.
    spAwaitingGeneration = "awaitingGeneration"
      ## §7.0's `onDemand` row: no trace has been recorded yet. Distinct from
      ## `spFetching`, because nothing is being fetched, and distinct from
      ## `spUnavailable`, because a session CAN exist once generation runs.
      ## Collapsing either pair would make the route offer the wrong action.
    spUnavailable = "unavailable"
      ## No session will open. `unavailableReason` says why, and the route
      ## renders metadata with no debugging affordance (§7.0's `absent` /
      ## `unsupported` row).

  SessionIntegrity* = enum
    ## What the recorder verdict says about this trace, as it bears on the
    ## banner above the session (Page-Descriptions §8).
    siUnknown = "unknown"
    siValidated = "validated"
    siDivergent = "divergent"
      ## Non-dismissible banner. Never folded into a phase: a divergent trace
      ## still opens and still steps; what changed is what it may be trusted
      ## to prove.
    siTruncated = "truncated"

func phaseLabel*(p: SessionPhase): string =
  ## The word the visitor reads. §8 forbids an indeterminate spinner, so each
  ## phase has to have a name that means something on its own.
  case p
  of spFetching: "Fetching the engine and the trace"
  of spOpening: "Opening the trace"
  of spPositioning: "Positioning at the requested step"
  of spReady: "Stepping"
  of spAwaitingGeneration: "No trace recorded yet"
  of spUnavailable: "No session"

func phaseShortLabel*(p: SessionPhase): string =
  ## The same phase in one word, for the rail in the identity bar.
  ##
  ## §8 requires the loading to be "phased and honest — fetching, then opening,
  ## then positioning". Naming all three and marking the current one is what
  ## satisfies that, and it has to fit on a bar beside the toolbar it explains;
  ## `phaseLabel`'s sentences are for a pane header, where there is room for a
  ## sentence. Two spellings of one enum, both exhaustive `case`s over it, so a
  ## phase added later has to answer both rather than silently inheriting one.
  case p
  of spFetching: "Fetching"
  of spOpening: "Opening"
  of spPositioning: "Positioning"
  of spReady: "Stepping"
  of spAwaitingGeneration: "Not recorded"
  of spUnavailable: "No session"

# ---------------------------------------------------------------------------
# Editor pane — the source view
# ---------------------------------------------------------------------------

type
  AnnotationSlot* = enum
    ## Where a per-line value overlay attaches.
    ##
    ## CodeTracer's omniscience shows values beside the expressions they belong
    ## to (`[x=10] [y=20]`, `[x: 10→20]`, `[→230]`). Two slots, because those
    ## examples are two different things: a value that belongs *at* a column in
    ## the line, and a value that belongs to the line as a whole.
    ##
    ## The distinction is DATA, not a drawing instruction, and the two are
    ## deliberately not two visual treatments today. `renderSource` draws both
    ## in one trailing run after the code, which is what
    ## `Omniscience-Flow.md`'s own wireframe shows —
    ##
    ##     | 5  │  let mut remaining = initial_shield; │ [remaining=10000] |
    ##     | 8  │  let damage = compute(asteroid);  [damage=850]           |
    ##
    ## — and what its `# [x=10] [y=20] [sum=30]` examples show. Splitting a line
    ## of code to inject a label mid-expression is the spec's *Multiline
    ## Visualization*, which it records as "not fully implemented" upstream
    ## either, and it makes the code itself unreadable at the widths this pane
    ## is served at.
    ##
    ## What the slot decides is whether the label CAN be pointed at an
    ## expression: `asInline` carries the source column the value's expression
    ## occupies and reads in that order; `asTrailing` has no column because
    ## nothing in the line's text is what it names. That is exactly the
    ## fidelity rule — a value whose expression `flow_layout` could not find in
    ## the source is never given a column it might be wrong about, it is given
    ## none.
    asInline = "inline"
    asTrailing = "trailing"

  ValueMode* = enum
    ## Which of a recorded step's two values a label shows, and therefore how it
    ## reads. `Omniscience-Flow.md` §"Before/After Values", with its renderings:
    ##
    ## | Mode        | Display                     | Example      |
    ## | ----------- | --------------------------- | ------------ |
    ## | `vmBefore`  | value before the expression | `[x=10]`     |
    ## | `vmAfter`   | value after the expression  | `[→230]`     |
    ## | `vmChanged` | both                        | `[x: 10→20]` |
    ##
    ## Three members and the same three meanings as the Embed SDK's
    ## `FlowValueMode`, spelled `vm*` rather than `fvm*` for the reason
    ## `SourceAvailabilityView`'s members are spelled `src*`: the two enums live
    ## in one scope wherever both are imported, and a distinct prefix removes
    ## the class of mistake rather than relying on qualification at every use.
    ##
    ## `vmChanged` and not `vmBeforeAndAfter`: on this surface the mode's
    ## meaning to a reader is "this line wrote this variable", and that is the
    ## single most valuable thing an inline value can say.
    vmBefore = "before"
    vmAfter = "after"
    vmChanged = "changed"

  LineAnnotation* = object
    ## One value overlay on one line: a variable, its recorded value or values,
    ## and the loop pass it belongs to.
    ##
    ## `iteration` is what keeps the overlay honest across a loop. A line inside
    ## a `for` body has one label per pass, and only the selected pass's may be
    ## on screen — a value from pass 5 rendered while the session is in pass 2
    ## is a value that never existed at this position. It is `-1` for a line
    ## outside any loop, which is always shown.
    slot*: AnnotationSlot
    column*: int          ## 0-based source column of the expression;
                          ## meaningful for `asInline`, `-1` otherwise
    label*: string        ## the expression, e.g. `remaining_shield`
    beforeValue*: string  ## its value entering the line
    afterValue*: string   ## its value leaving the line
    mode*: ValueMode
    iteration*: int       ## the loop pass, or -1 for "outside any loop"

func annotationText*(a: LineAnnotation): string =
  ## The label as one string — the plain-text form of the three renderings.
  ##
  ## The renderer emits the same three shapes as separate spans so the name, the
  ## arrow and the value can be styled apart; this is the single definition they
  ## are both derived from, and it is what travels on `title` and what a test
  ## asserts against. Two spellings of one label would be two chances to render
  ## `10 → 20` as `20 → 10`.
  case a.mode
  of vmBefore: a.label & "=" & a.beforeValue
  of vmAfter:
    # A return value has no expression in the source at all — the spec's
    # `[→230]`. A first assignment does, and reads better as `[shield_pct=90]`
    # than as `[shield_pct→90]`: the arrow means "changed from", and there was
    # nothing to change from.
    if a.label.len == 0: "→" & a.afterValue
    else: a.label & "=" & a.afterValue
  of vmChanged: a.label & ": " & a.beforeValue & " → " & a.afterValue

type
  FlowIteration* = object
    ## One pass through a loop, as the iteration rail offers it.
    index*: int
    ticks*: int
      ## The trace tick of this pass's loop header — a real time coordinate,
      ## which is what makes the rail's segments deep-linkable and what
      ## hydration hands to `ct/goto-ticks`.
    reached*: bool
      ## The session has passed through it, so the window carries its values.
      ##
      ## The static page is a still frame at one position and the passes after
      ## that position have not happened yet AT THAT POSITION. Their segments
      ## render inert and say so, rather than showing nothing and looking
      ## broken, or — the failure this field exists to make impossible —
      ## showing the recorded future as though the session were already there.

  FlowRail* = object
    ## The loop-iteration control (`Omniscience-Flow.md` §"Loop Slider
    ## Control"): `[Iteration: 3/8]` with a track.
    ##
    ## It is carried by the PANE rather than attached to the loop's header line,
    ## and that is a departure from the spec's "a slider appears above loop
    ## constructs" with a concrete cause: the served pane is a WINDOW of the
    ## file opened at the session's position (`source_document.openAtCurrent`),
    ## and the loop the session is inside is very often above that window — the
    ## demo session sits at `src/shield.nr:32` in a body whose `for` header is
    ## on line 4, twenty-two lines above the first line served. A control drawn
    ## only at the header would be a control that is absent exactly when the
    ## reader is inside the loop. `line`/`anchor` name where the loop is, and
    ## the rail links to it.
    loopIndex*: int       ## 0 when there is no loop; the rail renders nothing
    line*: int            ## the loop header's source line
    anchor*: string       ## that line's stable id, so the rail can link to it
    label*: string        ## the enclosing function, e.g. `iterate_asteroids`
    selected*: int        ## the pass whose labels are on screen
    active*: int          ## the pass the SESSION is in — never moves
    iterations*: seq[FlowIteration]
    navigable*: bool
      ## A click on a segment MOVES THE SESSION rather than switching which pass
      ## is displayed.
      ##
      ## False on the served page and true once hydration has an engine, and the
      ## difference is not cosmetic: with no script a segment can only change
      ## what is shown, and `Omniscience-Flow.md`'s `SimpleLoopIterationJump`
      ## ("enter iteration number, verify cursor") is a navigation the static
      ## page cannot perform. Rendering a seek control that cannot seek is the
      ## affordance-that-lies defect this route has removed twice, so the rail
      ## renders as the thing it can actually be in each state — a display
      ## selector, then a seek — and `FlowIteration.ticks` is what the second
      ## one hands to `ct/goto-ticks`.

const MaxStaticIterations* = 16
  ## How many passes the rail can switch between WITHOUT JavaScript.
  ##
  ## The static mechanism is `:target`, which needs one pair of rules per pass in
  ## a stylesheet written before any trace is known — so the ladder is finite
  ## while a loop is not. Sixteen covers every loop the demo tree records.
  ##
  ## It lives HERE, beside the type, because it is read by two files that must
  ## agree: `components/debugger.renderFlowRail` emits at most this many
  ## segments, and `components/debugger_css` emits exactly this many rungs. A
  ## rail with a seventeenth segment would target an id no rule answers and show
  ## the wrong pass's values while looking completely normal — the same class of
  ## silent failure `MaxIndentDepth` exists to prevent for call depth, and the
  ## same answer: clamp, and SAY SO.
  ##
  ## The ceiling is on the no-JavaScript rung of the capability ladder and not
  ## on the product. A hydrated session seeks to any pass through the engine.

type
  SourceLine* = object
    ## One rendered line of source.
    ##
    ## `anchor` is the stable identity the whole design turns on: a per-line id
    ## that does not move when the pane re-renders, so an overlay, a deep link,
    ## a breakpoint gutter and a scroll-into-view all address the same thing.
    ## It is derived from the file path and the line number, never from a
    ## render-order counter.
    number*: int
    text*: string
    anchor*: string
    executed*: bool       ## the trace visited this line at least once
    current*: bool        ## the session's position is on this line
    annotations*: seq[LineAnnotation]
    tokens*: seq[SourceToken]
      ## The line, partitioned into classified spans by `source_highlight`.
      ##
      ## EMPTY means "render `text` as one text node", which is what a file in a
      ## language no profile covers gets, and what every line got before
      ## highlighting existed. It is deliberately not "a single `tkPlain`
      ## token": the renderer has to be able to tell "lexed, and every run came
      ## out unremarkable" from "not lexed at all", because only the second may
      ## fall back to the pre-highlighting markup.
      ##
      ## Computed once, at static-export time, by `newSourceDocument` — the page
      ## ships no JavaScript, so there is nowhere else it could happen. It
      ## travels WITH the line so that `openAtCurrent` and `windowAround`, which
      ## copy `SourceLine`s into a narrower document, keep the highlighting
      ## without re-lexing and without knowing the language.

  SourceDocument* = object
    ## One file in the editor pane.
    path*: string         ## as the trace interns it, e.g. `src/shield.nr`
    language*: string     ## `noir`, `solidity`, … — used for labelling only
    lines*: seq[SourceLine]

  SourceAvailabilityView* = enum
    ## What the source pane can show, and therefore what it must say when it
    ## shows nothing. Mirrors `SourceAvailability` on the Embed SDK's seam.
    ##
    ## The values are prefixed `src` and not `sav`, which is what the seam's own
    ## enum uses. They are two enums with the same three meanings living in one
    ## scope wherever both are imported — `tests/tdebugpanes.nim` projects one
    ## onto the other — and Nim resolves that by qualification, which is a rule
    ## a reader has to keep in their head at every use site. A distinct prefix
    ## costs nothing and removes the class of mistake entirely.
    srcSourceLevel = "sourceLevel"
      ## A bundle resolved; the pane shows code.
    srcUnverified = "unverified"
      ## Code ran, nobody published source for it. Instruction-level stepping,
      ## supply-sources prominent (§14).
    srcAbsent = "absent"
      ## No contract code executed. There is nothing to supply sources *for*,
      ## which is a different sentence.

  EditorPane* = object
    availability*: SourceAvailabilityView
    reason*: string           ## why, when `availability != srcSourceLevel`
    documents*: seq[SourceDocument]
    activeIndex*: int         ## which document the pane shows
    currentLine*: int         ## 0 when the session is not positioned
    flow*: FlowRail
      ## The loop-iteration control, when the session is inside a loop.
      ##
      ## On the PANE and not on a document because it is a statement about where
      ## the SESSION is, not about a file: the same file rendered for a session
      ## outside the loop carries no rail. `flow_view.applyFlow` is the only
      ## producer, and it refuses to produce one at all below source-level
      ## fidelity — see its header.

func pathSlug*(path: string): string =
  ## Path characters that are not safe in an HTML id, folded to `-`.
  result = newStringOfCap(path.len)
  for c in path:
    if c in {'a'..'z', 'A'..'Z', '0'..'9'}: result.add c
    else: result.add '-'

func lineAnchor*(path: string; line: int): string =
  ## The stable per-line id. Path characters that are not safe in an HTML id
  ## are folded to `-`; the line number keeps the id unique within the file.
  "L-" & pathSlug(path) & "-" & $line

func docAnchor*(path: string): string =
  ## The stable per-DOCUMENT id, which the source pane's tab strip targets.
  ##
  ## Same folding as `lineAnchor` and a different prefix, so a document id can
  ## never collide with one of its own line ids.
  "D-" & pathSlug(path)

func activeDocument*(p: EditorPane): SourceDocument =
  if p.documents.len == 0: SourceDocument()
  elif p.activeIndex >= 0 and p.activeIndex < p.documents.len:
    p.documents[p.activeIndex]
  else: p.documents[0]

# ---------------------------------------------------------------------------
# Call trace pane
# ---------------------------------------------------------------------------

type
  CallFrame* = object
    ## One frame. `depth` is the nesting level (0 = entry point); the renderer
    ## turns it into indentation, so the producer never spells a pixel.
    depth*: int
    fn*: string           ## function or entry-point name
    module*: string       ## the contract / module it belongs to
    cost*: string         ## already formatted by the producer
    costUnit*: string
    step*: int            ## the time coordinate the frame starts at
    current*: bool        ## contains the session's position
    anchor*: string
      ## The row's §6.0a recovery anchor, in the link's own wire spelling
      ## (`call:0.2.6`, `src:src/shield.nr:32`). Data, like `step`: it is what a
      ## share link from this row would carry and what
      ## `deeplink_landing.resolveAnchor` matches an incoming link against. A
      ## frame with no derivable anchor carries `""`, which is not an error —
      ## the coordinate alone still names the position while the container is
      ## the one it was taken from.
    href*: string
      ## Where clicking this row goes, or `""` for a row that is not a link.
      ##
      ## Empty on every statically exported page and non-empty only in a
      ## hydrated one, which is the staging Debugger-Integration §3 asks for:
      ## "until hydration lands such a link would reload the page at a
      ## coordinate the static export cannot honour". The static export still
      ## cannot honour one — a query string does not select a file — so the
      ## PRODUCER decides, not the renderer, and the served page keeps rows
      ## that are rows.

  CallTracePane* = object
    frames*: seq[CallFrame]
    costLabel*: string    ## the column heading, e.g. `gas`, `ACIR opcodes`
    costUnit*: string     ## the unit the column is in, carried ONCE by the
                          ## header rather than repeated on every row. Empty
                          ## means "take it from the frames", so a producer
                          ## that only fills `CallFrame.costUnit` still renders
                          ## a labelled column.
    note*: string         ## what the pane says when `frames` is empty
                          ##
                          ## `sortedByCost` used to sit here, meaning "the
                          ## cost-sorted view is the active one". Nothing ever
                          ## read it — the two views are `:target` alternates
                          ## and CSS decides which is shown — and the view it
                          ## named no longer exists: the second view is now an
                          ## aggregation by function (`selfCostRows`), not an
                          ## ordering of frames. A field carrying a stale
                          ## meaning that no code consults is worse than no
                          ## field, so it is gone rather than renamed.

  SelfCostRow* = object
    ## One function in the aggregate view: its own cost, summed over every
    ## frame of it, with the callees' cost taken out.
    ##
    ## Chrome DevTools' `Bottom-up` and Datadog's `Span List` are aggregations,
    ## not orderings, and the difference is the whole feature: sorting 500
    ## frames gives 500 rows in a new order, and aggregating gives ~30 whose top
    ## row is the answer. A frame is an *occurrence*; this is a *function*, so
    ## `calls` is part of the row rather than something the reader counts.
    fn*: string
    module*: string
    calls*: int           ## how many frames of this function the trace has
    cost*: int            ## summed self cost, in the pane's unit
    unmetered*: bool
      ## At least one frame of this function reported no numeric cost, so
      ## `cost` is a floor rather than the total. Carried rather than hidden:
      ## an aggregate that silently dropped an unmetered frame would rank a
      ## function below one it may well exceed, and nothing on screen would say
      ## the number was partial.

func costValue*(f: CallFrame): int =
  ## A frame's cost as a number, or `-1` when it has none.
  ##
  ## The producer has already FORMATTED the cost for display (`"1,315"`), so the
  ## separators come back out to work with it. A cost column can legitimately
  ## carry `—` for an unmetered frame, and that is `-1` rather than a crash or a
  ## zero — zero would be a claim, and the pane has to be able to say it does not
  ## know.
  for c in f.cost:
    if c in {'0'..'9'}: result = result * 10 + (ord(c) - ord('0'))
    elif c notin {',', '_', ' '}: return -1

func formatCost*(n: int): string =
  ## `1315` → `1,315`, matching the spelling the producers already emit so the
  ## aggregate column and the per-frame column read as one vocabulary.
  if n < 0: return "—"
  let digits = $n
  for i, c in digits:
    if i > 0 and (digits.len - i) mod 3 == 0: result.add ','
    result.add c

func selfCost*(frames: seq[CallFrame]; i: int): int =
  ## Frame `i`'s cost with its DIRECT callees' cost removed, or `-1` when the
  ## frame itself is unmetered.
  ##
  ## The cost a producer reports is inclusive — the demo's `main` carries the
  ## whole trace's 1,315 — so subtracting the children is what turns "this frame
  ## and everything under it" into "this frame". Direct children are the run of
  ## frames after `i` at `depth + 1`, up to the first frame at `depth` or
  ## shallower; that is the call order the pane is rendered in, and it is the
  ## only structure the pane has.
  let own = costValue(frames[i])
  if own < 0: return -1
  result = own
  let d = frames[i].depth
  for j in i + 1 ..< frames.len:
    if frames[j].depth <= d: break
    if frames[j].depth == d + 1:
      let child = costValue(frames[j])
      # An unmetered child cannot be subtracted, so it is not: the parent's
      # self cost then over-reports rather than under-reports, and
      # `SelfCostRow.unmetered` is what says the number is not exact.
      if child > 0: result -= child
  if result < 0: result = 0

func selfCostRows*(p: CallTracePane): seq[SelfCostRow] =
  ## The call trace aggregated by function, heaviest self cost first.
  ##
  ## This replaces a cost-SORTED view, and the replacement is the point rather
  ## than the ranking. Chrome's `Bottom-up` view answers "which function is this
  ## execution spending itself in", which a reordered frame list does not: the
  ## demo's seven frames become five rows, `calculate_damage`'s two occurrences
  ## become one row carrying `2` and their combined self cost, and the top row
  ## is the answer instead of the start of a comparison.
  ##
  ## Rendered flat by `renderCallTrace`, for the reason the sorted view was:
  ## these rows are not in call order and have no tree, so an indent would draw
  ## a structure the ordering does not describe. Here it is not even a risk —
  ## a function is not a frame and has no depth to draw.
  var index: seq[tuple[fn, module: string]]
  for i, f in p.frames:
    let self = selfCost(p.frames, i)
    var at = -1
    for k, key in index:
      if key.fn == f.fn and key.module == f.module: at = k
    if at < 0:
      index.add (f.fn, f.module)
      result.add SelfCostRow(fn: f.fn, module: f.module)
      at = result.len - 1
    inc result[at].calls
    if self < 0: result[at].unmetered = true
    else: result[at].cost += self
  # Insertion sort, descending by self cost — the same shape the pane's sorted
  # view used, kept because the row count is a pane's worth and a stable sort
  # keeps equal-cost functions in first-call order rather than in an arbitrary
  # one that would change between renders of the same trace.
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i - 1
    while j >= 0 and result[j].cost < cur.cost:
      result[j + 1] = result[j]
      dec j
    result[j + 1] = cur

# ---------------------------------------------------------------------------
# State pane
# ---------------------------------------------------------------------------

type
  StateValue* = object
    depth*: int           ## nesting inside a structured value
    name*: string
    typ*: string
    value*: string
    changed*: bool        ## written at the current step
  StatePane* = object
    values*: seq[StateValue]
    note*: string

# ---------------------------------------------------------------------------
# Event log pane
# ---------------------------------------------------------------------------

type
  EventKind* = enum
    ## The four kinds Debugger-Integration §3 puts in one stream, plus program
    ## output, which a Noir trace produces a great deal of.
    ##
    ## An enum and not a string because the pane's whole job is to make the
    ## kinds distinguishable, and the review brief's anti-requirement is "four
    ## kinds rendered identically with only a differing label". A closed set is
    ## what lets the renderer give each one a glyph and a shape.
    evCall = "call"
    evStorageWrite = "storageWrite"
    evEvent = "event"
    evRevert = "revert"
    evOutput = "output"

  EventRow* = object
    kind*: EventKind
    step*: int
    label*: string
    detail*: string
    current*: bool
    anchor*: string       ## §6.0a wire spelling — `log:3`, `sw:shields[0]#1`,
                          ## `revert`. See `CallFrame.anchor`.
    href*: string         ## `""` unless this row is a link. See `CallFrame.href`.

  EventLogPane* = object
    rows*: seq[EventRow]
    note*: string

func eventKindLabel*(k: EventKind): string =
  case k
  of evCall: "call"
  of evStorageWrite: "write"
  of evEvent: "event"
  of evRevert: "revert"
  of evOutput: "output"

func eventKindGlyph*(k: EventKind): string =
  ## A shape per kind, so the kinds differ by more than colour (rubric A7).
  case k
  of evCall: "→"
  of evStorageWrite: "◆"
  of evEvent: "◇"
  of evRevert: "✕"
  of evOutput: "·"

# ---------------------------------------------------------------------------
# Debug controls pane
# ---------------------------------------------------------------------------

type
  DebugAction* = enum
    ## The moves `DebugControlsVM` exposes, in toolbar order. Backward first in
    ## each pair: reverse stepping is the product's premise, and a toolbar that
    ## buries it behind a menu is the finding the review brief names.
    ##
    ## The order is CodeTracer's own — `isonim_debug_controls_view.nim` lays
    ## the desktop toolbar out as `[reverse-next][next]`,
    ## `[reverse-step-in][step-in]`, `[reverse-step-out][step-out]`,
    ## `[reverse-continue][continue]` — because a desktop user reaches for
    ## these by position before they read a glyph.
    ##
    ## It did not used to be. The list was a PALINDROME (all four reverse moves
    ## on the left, all three forward moves on the right) while this very
    ## comment claimed it was paired, and `reverse-step-in` was missing
    ## altogether — three reverse moves against four forward ones on the
    ## surface whose whole premise is that time runs both ways. VD.5's
    ## continuity check against the desktop app found both.
    daStepBackward = "step-backward"
    daStepForward = "step-forward"
    daReverseStepIn = "reverse-step-in"
    daStepIn = "step-in"
    daReverseStepOut = "reverse-step-out"
    daStepOut = "step-out"
    daReverseContinue = "reverse-continue"
    daContinue = "continue"

  ControlButton* = object
    action*: DebugAction
    label*: string
    glyph*: string
    enabled*: bool

  DebugControlsPane* = object
    buttons*: seq[ControlButton]
    statusText*: string
    step*: int            ## the current time coordinate
    totalSteps*: int      ## from the manifest's execution summary
    positioned*: bool     ## whether `step` means anything yet

func fraction*(p: DebugControlsPane): float =
  ## Where the scrubber sits, 0.0 .. 1.0. A float, because the renderer turns
  ## it into a percentage width and nothing else may.
  if p.totalSteps <= 0 or p.step <= 0: 0.0
  elif p.step >= p.totalSteps: 1.0
  else: p.step.float / p.totalSteps.float

# ---------------------------------------------------------------------------
# The transaction metadata pane (Page-Descriptions §7.1)
# ---------------------------------------------------------------------------

type
  MetaRow* = object
    ## One label/value pair of §7.2's facts.
    ##
    ## §7.1 requires the pane and the pre-rendered page to render **from one
    ## source**. This is that source: `viewutil.txMetadataRows` builds the seq
    ## once, the explorer's overview grid renders it, and the pane renders it.
    ## Two producers of the same facts is the failure mode the milestone names,
    ## so there is exactly one.
    label*: string
    value*: string
    suffix*: string       ## a muted trailer — a unit, a token symbol
    identifier*: bool     ## render as a machine value (mono)
    badge*: string        ## a badge class, "" for none
    href*: string         ## a link target, "" for none

  ExecutionRow* = object
    ## One execution's trace state — the Aztec private/public split, honestly.
    selector*: string
    availability*: string
    reason*: string
    badge*: string

  MetadataPane* = object
    chain*: string
    hash*: string
    outcome*: string
    outcomeBadge*: string
    revertReason*: string
    revertReasonLabel*: string
      ## What to call `revertReason`. Carried rather than derived in the pane
      ## because the pane must not hold a second opinion about the outcome
      ## vocabulary — `viewutil.outcomeReasonLabel` owns it, and the
      ## transaction page reads the same function.
    revertReasonTone*: string
      ## How severe `revertReason` is, as a class the stylesheet colours.
      ##
      ## Carried for the same reason as the label, and it has to travel WITH
      ## the label rather than be assumed by the stylesheet: a rule that
      ## painted every reason in the danger colour would render the demo's
      ## Aztec split transaction — `partial`, both halves succeeded — in red,
      ## which is the label defect `outcomeReasonLabel` fixed, made again in
      ## colour. Naming the outcome correctly and then colouring it as a
      ## failure says the same wrong thing twice as loudly.
    rows*: seq[MetaRow]
    executions*: seq[ExecutionRow]

    payload*: seq[MetaRow]
      ## §7.2 section 3 — the decoded input, as rows from the same producer as
      ## `rows`. Carried by the PANE and not only by an explorer page because
      ## §7.0 makes the transaction route land in the session for a published
      ## trace: a fact that lived only on a page nobody is served any more is a
      ## fact the product lost.
    payloadNote*: string
      ## Why the parameters are raw bytes, when they are.
    native*: string
      ## §7.2 section 8 — the chain-native transaction and receipt JSON,
      ## verbatim, already formatted by the producer. Empty when the tree
      ## publishes none.

# ---------------------------------------------------------------------------
# Where the link landed (Debugger-Integration §6.0a)
# ---------------------------------------------------------------------------

type
  PositionNotice* = object
    ## §6.0a's verdict about the link this page was opened with, reduced to the
    ## two things a pane renderer needs: a machine-readable outcome and the
    ## sentence to show.
    ##
    ## Two plain strings and no import of the Client SDK, deliberately. This
    ## module is the renderer-free projection every pane reads and is compiled
    ## twice — by `static_export.nim` and by `nim js` — and the SDK's facade
    ## does not compile for the second (`std/sha1`). The DECISION belongs to
    ## `blocktracer_client_deeplink.resolvePosition`, which owns §6.0a's
    ## precedence and writes the sentence so every consumer says the same true
    ## thing; `deeplink_landing.nim` is what carries its answer here. What this
    ## type must never become is a second opinion about the same question.
    outcome*: string
      ## `PositionOutcome`'s wire spelling — `exact`, `recoveredByAnchor`,
      ## `nearestEnclosingFrame`, `startOfExecution`, `noReplayableArtifact` —
      ## or `""` when no link asked for a position and there is nothing to
      ## decide. An ORDINARY visit is `""`, not `exact`: "the link was honoured
      ## exactly" and "there was no link" are different facts, and only the
      ## second may render nothing.
    statement*: string
      ## The sentence. Non-empty for every outcome §6.0a calls visible, and
      ## empty for `exact` — which is the one branch that is allowed to be
      ## silent, because the page is showing precisely what was asked for.

func isVisible*(n: PositionNotice): bool =
  ## Whether the visitor must be told. §6.0a: "Every branch below (2) is
  ## visible. The client never silently lands somewhere other than where the
  ## link pointed."
  n.statement.len > 0

# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------

type
  DebugSessionView* = object
    ## Everything the debug route renders. One value, so a producer cannot
    ## supply half a session and a renderer cannot reach for a second source.
    chain*: string
    txHash*: string
    blockHeight*: int
    blockHash*: string
    outcomeLabel*: string
    outcomeBadge*: string
    finality*: string

    phase*: SessionPhase
      ## Where the ENGINE is. See `SessionPhase`.
    hasFrame*: bool
      ## Whether the panes carry a positioned frame. True on the static route
      ## for a published trace, where `phase` is still `spFetching`.
    engineBase*: string
      ## The origin+prefix the engine will be loaded from
      ## (`replay_engine.ReplayEngineBase`), recorded in the page so a reader
      ## can see which origin this build trusts.
    engineCrossOrigin*: bool
    engineBytes*: int
      ## What the visitor is waiting for, in bytes. Shown as a quantity,
      ## because "loading" with no number is the indeterminate spinner §8 rules
      ## out with different words.
    unavailableReason*: string
    integrity*: SessionIntegrity
    integrityDetail*: string
    reconstructed*: bool
      ## The trace was heuristically reconstructed rather than recorded.
      ##
      ## Orthogonal to `integrity`, and deliberately a separate field:
      ## Trace-Artifacts.md §2.3a calls a trace that is BOTH `ready` and
      ## reconstructed the case where "presenting the second as a native
      ## execution trace is the confident lie". Folding it into the integrity
      ## enum would make a reconstructed-and-validated trace indistinguishable
      ## from a recorded one, which is the lie.

    timeCoordinate*: int      ## the `?t=` the URL asked for; 0 when absent
    containerPath*: string    ## the published container, for the download action
    containerBytes*: int
    traceContentHash*: string
      ## `traceContentHash` of the artifact this page currently recommends
      ## (Trace-Artifacts.md §2.8), algorithm tag and all.
      ##
      ## Not a pin and not part of any URL. Debugger-Integration §6.0 is
      ## explicit: the link "still resolves to whatever is currently
      ## recommended, so a corrected trace reaches every reader", and `c` only
      ## answers whether the coordinate transfers. This is the value a visitor's
      ## `c` is compared against, which is why it has to be on the SERVED page —
      ## the comparison happens in a browser, before the engine has opened
      ## anything, and there is nowhere else it could come from.
    languages*: seq[string]

    landing*: PositionNotice
      ## What §6.0a's precedence decided about the link this page was opened
      ## with, and the sentence the visitor is owed for it.
    landingCoordinate*: int
      ## The coordinate that precedence produced, or `0` for a branch that
      ## produced none. Separate from `timeCoordinate`, which is what the URL
      ## ASKED for: the two differ in exactly the branches the notice exists to
      ## announce, and collapsing them would make the page unable to say that
      ## they had.

    editor*: EditorPane
    calltrace*: CallTracePane
    state*: StatePane
    eventLog*: EventLogPane
    controls*: DebugControlsPane
    metadata*: MetadataPane

func opensASession*(v: DebugSessionView): bool =
  ## Whether this route may present a debugging affordance at all.
  ## §7.0: `absent` and `unsupported` get "no debugger, and no pretence of one".
  v.phase != spUnavailable

func engineLive*(v: DebugSessionView): bool =
  ## Whether the controls can actually move time. The one predicate the
  ## toolbar's enablement is allowed to read: a button that is enabled without
  ## an engine behind it is the affordance that lies on click.
  v.phase == spReady

func canShare*(v: DebugSessionView): bool =
  ## A share link needs a published container and a position — NOT a live
  ## engine. Sharing the frame you are looking at is exactly what someone does
  ## while the engine is still arriving.
  v.hasFrame and v.containerPath.len > 0

func truncatedHash*(h: string): string =
  if h.len <= 13: h else: h[0 ..< 8] & "…" & h[h.len - 4 .. ^1]

func truncHash*(h: string, lead = 6, tail = 4): string =
  ## `0x27a6c250…9a6c` — a middle-truncated hash for dense tables and for the
  ## metadata pane's hero.
  ##
  ## It lived in `viewutil` — which imports `blocktracer_client`, `reader` and
  ## `std/json`, and therefore the filesystem. `components/debugger.nim` used
  ## exactly one symbol from it, this one, and that single edge is what made
  ## the pane renderers unreachable from a `nim js` build: hydration compiles
  ## the SAME renderers to JavaScript, and a renderer that transitively imports
  ## a file reader cannot be compiled for a browser. `viewutil` re-exports
  ## `session_view`, so every existing call site is unchanged.
  if h.len <= lead + tail + 1: return h
  h[0 ..< lead] & "…" & h[h.len - tail ..< h.len]

func joinLanguages*(v: DebugSessionView): string =
  v.languages.join(", ")
