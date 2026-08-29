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

# ---------------------------------------------------------------------------
# Editor pane — the source view
# ---------------------------------------------------------------------------

type
  AnnotationSlot* = enum
    ## Where a per-line value overlay attaches.
    ##
    ## CodeTracer's omniscience shows values inline beside the expressions they
    ## belong to (`[x=10] [y=20]`, `[x: 10→20]`, `[→230]`). Building that is a
    ## separate workstream; reserving its attachment points is not, because
    ## retrofitting them means restructuring every rendered line. Two slots,
    ## because those examples are two different things: a value that belongs
    ## *at* a column in the line, and a value that belongs to the line as a
    ## whole.
    asInline = "inline"
    asTrailing = "trailing"

  LineAnnotation* = object
    ## One value overlay on one line. `annotations` is empty in everything this
    ## milestone ships; the renderer handles a non-empty one, and
    ## `tests/test_debug_route.nim` drives it so the slot is a tested path
    ## rather than a promise.
    slot*: AnnotationSlot
    column*: int          ## 1-based; meaningful for `asInline`, 0 otherwise
    label*: string        ## the expression, e.g. `remaining_shield`
    value*: string        ## its rendered value, e.g. `10 → 20`

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

  CallTracePane* = object
    frames*: seq[CallFrame]
    costLabel*: string    ## the column heading, e.g. `gas`, `ACIR opcodes`
    costUnit*: string     ## the unit the column is in, carried ONCE by the
                          ## header rather than repeated on every row. Empty
                          ## means "take it from the frames", so a producer
                          ## that only fills `CallFrame.costUnit` still renders
                          ## a labelled column.
    sortedByCost*: bool   ## whether the cost-sorted view is the active one
    note*: string         ## what the pane says when `frames` is empty

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
    languages*: seq[string]

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

func joinLanguages*(v: DebugSessionView): string =
  v.languages.join(", ")
