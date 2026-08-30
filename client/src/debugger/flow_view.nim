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
##
## ## Rule 4 — a branch is "not taken" only where that is a fact, not a gap
##
## `notTakenPasses` below carries the taken/not-taken feature over from the
## desktop app, and it is the rule that decides where the dimming stops. Its
## whole reasoning is in that proc's header, because the temptation it resists —
## "no recorded step on this line, therefore this line did not run" — is one
## line of code away and would be wrong about two of the three things it
## covered.
##
## Like the values, it reaches the STATIC page and stops at hydration.
## `session_project.projectEditor` builds its lines from the engine and sets no
## claim, so a hydrated pane shows the rail and neither the values nor the
## dimming — the same stop, for the same reason, stated there: the per-step flow
## payload cannot yet be read against a live engine, and a claim about control
## flow derived from a payload nobody has observed would be exactly the
## confident fiction this module exists to refuse. What must never happen is the
## served page's dimming being FROZEN onto a moved session; it is not, because
## the marks live on the `SourceLine`s the hydrated pane replaces wholesale.

import std/tables

import ./branch_regions
import ./session_view
import ./vendor/frontend/viewmodel/viewmodels/flow_layout
export flow_layout
export branch_regions

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

# ---------------------------------------------------------------------------
# Rule 4 — the branch that was not taken
# ---------------------------------------------------------------------------

func passOf(step: FlowLayoutStep): int =
  ## Which pass a recorded step belongs to, in `LineAnnotation.iteration`'s
  ## vocabulary. `loopIndex == 0` is the backend's placeholder loop, so such a
  ## step is outside every loop and is `NoIteration` — true in all passes.
  if step.loopIndex > 0: step.iteration else: NoIteration

proc notTakenPasses*(window: FlowLayoutWindow;
                     conditionals: seq[Conditional]): Table[int, seq[int]] =
  ## For each source line, the passes in which it is inside a branch that was
  ## evaluated and **not taken**. Line numbers to pass indices, `NoIteration`
  ## for a conditional outside every loop.
  ##
  ## ## The claim this refuses to make
  ##
  ## A line with no recorded step is one of three things, and they are not
  ## interchangeable:
  ##
  ##   1. a branch the execution evaluated and did not take;
  ##   2. a line the recorder never emitted a step for; or
  ##   3. a line the window does not cover — the served frame is cut at the
  ##      session's position, so everything after it has not happened *yet*.
  ##
  ## Dimming all three identically tells the reader (1) about all three, and (1)
  ## is the only one of them that is a fact about the *program*. The other two
  ## are facts about the *recording*, and presenting them as the first is the
  ## confident-and-sometimes-wrong answer this product cannot afford.
  ##
  ## So nothing here is derived from absence alone. Every dimmed region rests on
  ## POSITIVE evidence of all three of the following, and a region that cannot
  ## supply all three is left alone:
  ##
  ##   * **the arm is instrumented** — some step in this window falls on its
  ##     interior, in some pass. This is what separates (1) from (2). Without
  ##     it, "no step here" is a statement about the recorder and not about the
  ##     execution, and the demo trace contains exactly such a case:
  ##     `shield.nr:35` is the body of a clamp that never fires, and it is
  ##     deliberately NOT dimmed, because a body that never recorded a step
  ##     anywhere is indistinguishable from a body nothing was recorded for;
  ##   * **the chain was entered in this pass** — a sibling arm recorded a step,
  ##     or the chain's own header did. This is what separates (1) from (3): a
  ##     conditional the session has not reached yet has neither;
  ##   * **the chain was resolved in this pass** — for the sibling case that is
  ##     implied, since a sibling that ran is the resolution. For a chain with
  ##     no arm running it is explicit: some step in the same pass carries a
  ##     later tick than the last header evaluation, proving execution moved
  ##     past the condition. Without it, a session suspended ON the `if` line
  ##     would have its untaken-so-far body dimmed while the branch was still
  ##     being decided.
  ##
  ## ## What follows from the arms being mutually exclusive
  ##
  ## Exactly one arm of an `if` chain runs per evaluation, which is the whole
  ## strength of the inference: "arm 2 ran" *proves* "arm 1 did not". That is the
  ## sound half of desktop CodeTracer's mechanism — `load_branch_for_position`
  ## marks the stepped-into arm `Taken` and its AST siblings `NotTaken`.
  ##
  ## Desktop has a second mechanism, `final_branch_load`, which sweeps the file
  ## once the flow walk ends and stamps `NotTaken` on every branch the walk never
  ## reached. That sweep runs unconditionally after all four of the walk's early
  ## exits — a 10,000-step budget, an eight-step stall guard, a move error and a
  ## parse error — and no truncation signal reaches the UI, so a branch the
  ## walker simply ran out of budget before is reported to the reader as a branch
  ## the program declined to take. That mechanism is deliberately NOT carried
  ## over. It is precisely claim (2)/(3) rendered as claim (1).
  ##
  ## ## Two facts that make the answer per-pass rather than per-line
  ##
  ## A conditional inside a loop can go one way on pass 1 and the other on pass
  ## 2 — the demo trace does exactly this, taking `shield.nr:29` on passes 0 and
  ## 1 and `shield.nr:32` on pass 2 — so a line's state is a function of the
  ## pass, and a single answer for the line would be wrong in half the passes.
  ##
  ## And a conditional can be evaluated MORE than once within one pass, when the
  ## function holding it is called twice. If two arms both recorded a step in
  ## the same pass, the chain went both ways and neither arm may be called
  ## untaken: that case yields nothing rather than a guess about which
  ## evaluation the reader is looking at.
  var ranAt = initTable[(int, int), bool]()     ## (pass, line) → a step exists
  var everLine = initTable[int, bool]()         ## line → a step exists in ANY pass
  var passes: seq[int] = @[]
  var lastTickAt = initTable[(int, int), int]()   ## (pass, line) → latest tick
  var lastTickIn = initTable[int, int]()          ## pass → latest tick anywhere
  for step in window.steps:
    let pass = passOf(step)
    ranAt[(pass, step.line)] = true
    everLine[step.line] = true
    if pass notin passes: passes.add pass
    if step.rrTicks > lastTickAt.getOrDefault((pass, step.line), low(int)):
      lastTickAt[(pass, step.line)] = step.rrTicks
    if step.rrTicks > lastTickIn.getOrDefault(pass, low(int)):
      lastTickIn[pass] = step.rrTicks

  func ran(arm: BranchArm; pass: int): bool =
    for line in arm.firstLine .. arm.lastLine:
      if ranAt.getOrDefault((pass, line), false): return true
    false

  func instrumented(arm: BranchArm): bool =
    ## Some step in this window lands on this arm's interior — in ANY pass, and
    ## for any call of the function holding it. That is deliberately the weakest
    ## form of the check that still does its job: it has to establish only that
    ## the recorder emits steps for these lines at all.
    for line in arm.firstLine .. arm.lastLine:
      if everLine.getOrDefault(line, false): return true
    false

  for conditional in conditionals:
    for pass in passes:
      var ranCount = 0
      for arm in conditional.arms:
        if ran(arm, pass): inc ranCount

      var dim: seq[BranchArm] = @[]
      if ranCount == 1:
        # A sibling ran. Every other instrumented arm is untaken, and the
        # sibling itself is the proof that the chain resolved.
        for arm in conditional.arms:
          if not ran(arm, pass) and instrumented(arm): dim.add arm
      elif ranCount == 0 and not conditional.exhaustive:
        # No arm ran and none had to. That is a fact about the program only if
        # the chain was entered AND left in this pass; otherwise it is a session
        # that has not got there, or one suspended on the condition.
        var lastHeader = low(int)
        for arm in conditional.arms:
          let tick = lastTickAt.getOrDefault((pass, arm.headerLine), low(int))
          if tick > lastHeader: lastHeader = tick
        if lastHeader > low(int) and
           lastTickIn.getOrDefault(pass, low(int)) > lastHeader:
          for arm in conditional.arms:
            if instrumented(arm): dim.add arm
      # `ranCount >= 2` (the chain went two ways in one pass) and the exhaustive
      # `ranCount == 0` (one arm MUST have run, and none was recorded — a fact
      # about the recording, not the program) both fall through with nothing.

      for arm in dim:
        for line in arm.firstLine .. arm.lastLine:
          if not result.hasKey(line): result[line] = @[]
          if pass notin result[line]: result[line].add pass

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
  ##
  ## The branch dimming is cleared by the same loop and gated by the same
  ## `return`, and that is not tidiness. "This block did not execute" is a
  ## stronger claim than "this variable held 4000", so it must not be reachable
  ## by a path the weaker one is refused on: at instruction level there is no
  ## source, no lexer applies, and there are no braces to find, so a dimmed
  ## region there would be a region chosen by nothing at all.
  pane.flow = FlowRail(loopIndex: 0)
  for d in 0 ..< pane.documents.len:
    for i in 0 ..< pane.documents[d].lines.len:
      pane.documents[d].lines[i].annotations = @[]
      pane.documents[d].lines[i].notTaken = @[]
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

  # Rule 4. The conditionals come from the WINDOW's `sourceLines`, which is the
  # whole file, and not from `pane.documents[index].lines`, which is a window of
  # it opened at the session's position (`source_document.openAtCurrent`). A
  # brace matcher fed a file that starts at line 26 sees an unbalanced file and
  # would either refuse everything or — far worse — match an `else`'s `}` to
  # some later block's. The pane's line NUMBERS are what the two are joined on,
  # and they are the file's own, which is exactly the property `lineAnchor`
  # exists to guarantee.
  let untaken = notTakenPasses(
    input.window,
    findConditionals(
      input.window.sourceLines,
      profileForDocument(pane.documents[index].path,
                         pane.documents[index].language)))

  for i in 0 ..< pane.documents[index].lines.len:
    let number = pane.documents[index].lines[i].number
    if byLine.hasKey(number):
      pane.documents[index].lines[i].annotations = byLine[number]
    if untaken.hasKey(number):
      pane.documents[index].lines[i].notTaken = untaken[number]

# ---------------------------------------------------------------------------
# What the renderer asks about an annotation
# ---------------------------------------------------------------------------

func iterationClass*(iteration: int): string =
  ## The class that carries an annotation's pass, and the one the stylesheet's
  ## `:target` ladder switches on. `-1` is `fv-any`: outside every loop, always
  ## shown.
  if iteration < 0: "fv-any" else: "fv-i" & $iteration

func notTakenClass*(iteration: int): string =
  ## The class that carries the pass a not-taken claim belongs to.
  ##
  ## A separate prefix from `iterationClass`'s `fv-i`, and not a reuse of it,
  ## because the two ride the same `:target` ladder and mean opposite things: an
  ## `fv-i2` is a value RECORDED in pass 2, an `nt-i2` is a statement that did
  ## NOT run in pass 2. One class doing both would need the stylesheet to know
  ## which element it was on, and a rung that got that backwards would dim the
  ## lines that ran.
  if iteration < 0: "nt-any" else: "nt-i" & $iteration

func notTakenClasses*(passes: seq[int]; selected: int): string =
  ## A source line's not-taken classes, including `ntnow` when the claim holds
  ## in the pass the SESSION is in — which is what the stylesheet shows before
  ## any rail segment is targeted, exactly as `.fv.now` is.
  ##
  ## Empty for a line with no claim, so the ordinary line's markup is unchanged.
  if passes.len == 0: return ""
  var now = false
  for pass in passes:
    result.add " " & notTakenClass(pass)
    if pass < 0 or pass == selected: now = true
  if now: result.add " ntnow"

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
