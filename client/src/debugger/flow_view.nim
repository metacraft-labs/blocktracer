## Omniscience for the debug route: recorded values placed against the source.
##
## `Debugger-UX-Research.md` records that nobody else in this category does
## this — Pernosco, the most sophisticated omniscient debugger extant, lists
## inline value display as a *roadmap* item. So this is not catching up, and the
## standard it has to meet is correspondingly higher: a values overlay that is
## sometimes wrong is worse than no overlay, because a reader cannot tell which
## kind they are looking at.
##
## ## What is computed here, and what is not
##
## Nothing about *placement*. Which column an expression occupies, what order a
## line's labels read in, which steps belong to pass 4 of loop 2, and whether
## two recorded values make an `[x=10]`, a `[→230]` or an `[x: 10→20]` are all
## answered by `vendor/…/flow_layout.nim` — CodeTracer's own arithmetic,
## vendored byte-for-byte (see `vendor/flow_layout.vendor.json`), so the desktop
## app and this page cannot disagree about where a value goes.
##
## What is here is the join: a `FlowLayout` on one side, the `SourceDocument`s
## and `EditorPane` the renderers read on the other, and the three rules below
## between them.
##
## ## Rule 1 — the fidelity ladder decides whether there are values at all
##
## `Page-Descriptions.md` §14 catalogues source-level, instruction-level and
## mixed sessions, and §7.0's table gives each its own landing. At instruction
## level there is no source text, so there is no expression to place a value
## against and no column to place it at; `applyFlow` returns without writing a
## single annotation and without a rail. Values may degrade to ABSENT. What they
## may never do is degrade to approximate — and the shape that would produce
## that is not hypothetical, it is one `if` away: a placement routine that fell
## back to "first line of the pane" or "column 0" when the source was
## unavailable would render a complete, confident, entirely fictional overlay.
##
## ## Rule 2 — a label belongs to the pass that produced it
##
## Every annotation carries the loop iteration it was recorded in, and the
## renderer shows exactly one pass at a time. A `remaining_shield: 4000 → 5000`
## from pass 4 sitting on line 12 while the session is in pass 2 is not a
## rendering bug, it is a false statement about the execution; it is also the
## single easiest thing to get wrong here, because every pass writes the same
## line and the labels look interchangeable.
##
## ## Rule 3 — an expression the source does not contain gets no column
##
## `flow_layout.assignExpressionColumns` never drops a recorded value: an
## expression it cannot find in the line's text is parked past the end of the
## line by `fallbackExpressionColumn`, with `found = false`, precisely so that a
## value that WAS recorded is still shown. This module reads that flag and
## demotes such a label to `asTrailing` with no column. The alternative — taking
## the fallback column at face value — would point a label at a character
## position in the source that has nothing to do with it, which is the "placed
## against the wrong expression" half of the honesty constraint.

import std/tables

import ./session_view
import ./vendor/frontend/viewmodel/viewmodels/flow_layout
export flow_layout

const NoIteration* = -1
  ## `LineAnnotation.iteration` for a line outside every loop. Such a label is
  ## shown whatever the rail is set to, because there is no pass it could belong
  ## to another of.

# ---------------------------------------------------------------------------
# One label
# ---------------------------------------------------------------------------

func toValueMode*(m: FlowValueMode): ValueMode =
  ## The SDK's three modes as this surface spells them. Total, so a fourth
  ## upstream member is a compile error here rather than a silently mis-rendered
  ## label.
  case m
  of fvmBefore: vmBefore
  of fvmAfter: vmAfter
  of fvmBeforeAndAfter: vmChanged

func placedInSource*(label: FlowLabel; lineText: string): bool =
  ## Whether this label's column is a real occurrence in the source line.
  ##
  ## `FlowExpressionColumn` carries a `found` flag for exactly this and
  ## `FlowLabel` does not carry it forward, so it is recovered from the column
  ## itself. That recovery is exact rather than a heuristic:
  ## `fallbackExpressionColumn` returns `lineLength + 2 + 2n`, which always
  ## starts strictly past the end of the line, while a found expression lies
  ## wholly within it. There is no column both answers can produce.
  ##
  ## It matters which side of that line a label falls on. Rule 3: a fallback
  ## column is an ORDERING, not a position in the text — treating it as one
  ## would point the label at a character offset the expression has nothing to
  ## do with.
  label.sourceColumn >= 0 and
    label.sourceColumn + label.expression.len <= lineText.len

func toAnnotation*(label: FlowLabel; found: bool): LineAnnotation =
  ## One `FlowLabel` as the overlay the renderer draws. See rule 3 for `found`.
  LineAnnotation(
    slot: (if found: asInline else: asTrailing),
    column: (if found: label.sourceColumn else: -1),
    label: label.expression,
    beforeValue: label.beforeText,
    afterValue: label.afterText,
    mode: toValueMode(label.mode),
    iteration: (if label.loopIndex > 0: label.iteration else: NoIteration))

# ---------------------------------------------------------------------------
# Return values
# ---------------------------------------------------------------------------

type
  FlowReturn* = object
    ## A recorded return value, which is a fact about a LINE and not about any
    ## expression in it.
    ##
    ## `assignExpressionColumns` refuses an empty expression by construction
    ## (`if expression.len == 0 … return`), so the spec's `[→230]` cannot travel
    ## as a `FlowLabel` at all — and should not: it has no name, no column and
    ## nothing in the source text to point at. It is carried beside the window
    ## and joined here.
    line*: int
    iteration*: int
    text*: string

func returnAnnotation*(r: FlowReturn): LineAnnotation =
  LineAnnotation(
    slot: asTrailing, column: -1, label: "",
    beforeValue: "", afterValue: r.text,
    mode: vmAfter, iteration: r.iteration)

# ---------------------------------------------------------------------------
# The whole overlay
# ---------------------------------------------------------------------------

type
  FlowWindowInput* = object
    ## Everything one flow overlay needs, in this repository's own vocabulary.
    ##
    ## `path` is which document the window is about. A window is per-FILE
    ## because `FlowLayoutWindow.sourceLines` is one file's text; a session whose
    ## stack spans two files gets an overlay on the one it is in, and the other
    ## document renders with no annotations — which is the honest reading of "no
    ## flow window has been loaded for this file", not a gap.
    path*: string
    window*: FlowLayoutWindow
    returns*: seq[FlowReturn]
    locationTicks*: int
      ## The trace tick the session is at. It is what decides which pass the
      ## rail OPENS on, and getting it from anywhere else is issue #593 — a
      ## counter that reads 1 of 8 for as long as the session lasts however far
      ## into the loop the debugger actually is.
    functionLabel*: string
      ## The function the loop is in, for the rail's own label.

func iterationsWithSteps(window: FlowLayoutWindow; loopIndex: int): Table[int, bool] =
  ## Which passes this window actually carries steps for.
  ##
  ## Not the same as "which passes the loop ran". `rrTicksForIterations` names
  ## every pass in the recording, and the static frame's window is cut at the
  ## session's position, so the later passes are named and empty. The rail has
  ## to be able to say "eight passes, and this frame reaches three of them"
  ## rather than offering five empty ones as though the values were missing.
  result = initTable[int, bool]()
  for step in window.steps:
    if step.loopIndex == loopIndex:
      result[step.iteration] = true

func focusedLoop*(window: FlowLayoutWindow): int =
  ## The loop whose control is on screen, or 0 for none.
  ##
  ## Index 0 is the backend's placeholder `Loop::default()` and is never a real
  ## loop — `flow_layout.computeFlowLayout` skips it and `flow_vm.pickFocusedLoop`
  ## skips it for the same reason. Among the rest, the first that recorded any
  ## pass at all.
  for index in 1 ..< window.loops.len:
    if window.loops[index].rrTicksForIterations.len > 0 or
       window.loops[index].iterationSteps.len > 0:
      return index
  0

proc buildRail(input: FlowWindowInput; loopIndex: int;
               anchorOf: proc(line: int): string): FlowRail =
  if loopIndex <= 0 or loopIndex >= input.window.loops.len:
    return FlowRail(loopIndex: 0)
  let loop = input.window.loops[loopIndex]
  let carried = iterationsWithSteps(input.window, loopIndex)
  let active = activeIteration(loop, input.locationTicks)
  result = FlowRail(
    loopIndex: loopIndex,
    line: loop.registeredLine,
    anchor: anchorOf(loop.registeredLine),
    label: input.functionLabel,
    selected: active,
    active: active,
    iterations: @[])
  let total = max(loop.rrTicksForIterations.len, loop.iterationSteps.len)
  for i in 0 ..< total:
    result.iterations.add FlowIteration(
      index: i,
      ticks: (if i < loop.rrTicksForIterations.len:
                loop.rrTicksForIterations[i] else: 0),
      reached: carried.getOrDefault(i, false))

proc applyFlow*(pane: var EditorPane; input: FlowWindowInput) =
  ## Attach the window's values to the pane's document, and set its rail.
  ##
  ## ## Why every pass is attached and not only the selected one
  ##
  ## The served page ships no JavaScript, so a rail that could only be moved by
  ## script would be an affordance that cannot act — the defect this route has
  ## already removed twice (`components/debugger.Copyable`, the old `.ctsort`).
  ## Every pass the window carries is therefore in the markup, tagged with its
  ## iteration, and the stylesheet shows one of them; the rail's segments are
  ## `:target` links, on the same no-JavaScript mechanism the pane stack's tabs
  ## and the cost-sorted call trace already use. That makes the loop slider a
  ## control that works with scripting off, which is what `Omniscience-Flow.md`
  ## asks for and what the fidelity ladder's bottom rung has to be able to
  ## deliver.
  ##
  ## The cost is bounded by the window, and the window is cut at the session's
  ## position, so it is the passes that have HAPPENED — not the whole loop.
  ##
  ## ## Rule 1, first and unconditionally
  ##
  ## Below source-level fidelity there is nothing to place a value against.
  ## Returning here rather than "rendering what we have" is the difference
  ## between an absent overlay and an invented one.
  ##
  ## ## It CLEARS before it writes
  ##
  ## Every rejection below leaves the pane with no overlay at all, not with the
  ## previous one. That matters most on the path that rejects: a pane whose
  ## availability has dropped to instruction level, or whose window no longer
  ## covers this file, would otherwise keep the values it was given for a
  ## different frame — which is the stale-value failure in its purest form,
  ## since nothing on screen would have changed to announce it.
  pane.flow = FlowRail(loopIndex: 0)
  for d in 0 ..< pane.documents.len:
    for i in 0 ..< pane.documents[d].lines.len:
      pane.documents[d].lines[i].annotations = @[]
  if pane.availability != srcSourceLevel: return
  if input.path.len == 0: return

  var index = -1
  for i, doc in pane.documents:
    if doc.path == input.path:
      index = i
      break
  if index < 0: return

  let loopIndex = focusedLoop(input.window)
  pane.flow = buildRail(input, loopIndex,
                        proc(line: int): string = lineAnchor(input.path, line))

  # Which passes to lay out. Every pass the window carries a step for, so the
  # rail can reach them; `computeFlowLayout` is asked once per pass with that
  # pass selected, which is exactly the entry point the loop slider drives.
  var passes: seq[int] = @[]
  if loopIndex > 0:
    for it in pane.flow.iterations:
      if it.reached: passes.add it.index
  if passes.len == 0: passes.add FirstIterationIndex

  # A line outside every loop is laid out identically by every pass, so it would
  # be attached once per pass. Deduplicated on the whole label, not on the line:
  # two passes CAN legitimately produce the same text for the same expression on
  # the same line, and they are then genuinely the same statement.
  var seen = initTable[string, bool]()
  var byLine = initTable[int, seq[LineAnnotation]]()

  proc take(line: int; ann: LineAnnotation) =
    let key = $line & "\x1f" & $ann.iteration & "\x1f" & ann.label & "\x1f" &
              ann.beforeValue & "\x1f" & ann.afterValue & "\x1f" & $ann.mode &
              "\x1f" & $ann.column
    if seen.hasKeyOrPut(key, true): return
    byLine.mgetOrPut(line, @[]).add ann

  for pass in passes:
    let selection =
      if loopIndex > 0: @[(loopIndex: loopIndex, iteration: pass)]
      else: newSeq[tuple[loopIndex: int, iteration: int]]()
    let layout = computeFlowLayout(input.window, input.locationTicks, selection)
    for lineLayout in layout.lines:
      # `labelsForStep` has already ordered the line's labels left to right by
      # source column; `orderExpressionsByColumn` is what did it. Preserved by
      # appending in that order and never re-sorting here — the reading order of
      # a line's values is a layout decision and it has one owner.
      let text = input.window.lineText(lineLayout.line)
      for label in lineLayout.labels:
        take(lineLayout.line, toAnnotation(label, placedInSource(label, text)))

  for r in input.returns:
    take(r.line, returnAnnotation(r))

  for i in 0 ..< pane.documents[index].lines.len:
    let number = pane.documents[index].lines[i].number
    if byLine.hasKey(number):
      pane.documents[index].lines[i].annotations = byLine[number]

# ---------------------------------------------------------------------------
# What the renderer asks about an annotation
# ---------------------------------------------------------------------------

func iterationClass*(iteration: int): string =
  ## The class that carries an annotation's pass, and the one the stylesheet's
  ## `:target` ladder switches on. `-1` is `fv-any`: outside every loop, always
  ## shown.
  if iteration < 0: "fv-any" else: "fv-i" & $iteration

func railTargetId*(iteration: int): string =
  ## The id a rail segment targets.
  ##
  ## Keyed on the pass alone and not on the loop. `FlowRail` describes exactly
  ## one loop — the focused one, which is the one whose control is on screen —
  ## and the stylesheet's ladder is written against these ids, so a second
  ## concurrently-rendered rail would need a second ladder rather than a second
  ## id space. Nested loops are `Omniscience-Flow.md`'s `Flow.NestedLoops`,
  ## listed there as planned, and are deferred here too.
  "fit-" & $iteration
