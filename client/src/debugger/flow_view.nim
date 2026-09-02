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

import std/[strutils, tables, unicode]

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
# Rule 5 — a value that is drawn where nobody can read it has not been shown
# ---------------------------------------------------------------------------
#
# ## The defect this answers
#
# Measured in a browser against the served page, at the pinned coordinate, in
# both themes: of the fifteen labels the default pass puts on screen at 1920,
# eight were wholly inside the code pane; at 1440 it was six. On the rail's
# first pass, where the window carries fifty-one, it was twenty-two and twelve.
# The rest were cut by the pane's right edge or past it entirely.
#
# Three things that look like the fix are not:
#
#   * **The labels are not what overflows.** The CODE alone reaches 1127px in a
#     pane that is 911px at 1920 and 681px at 1440. A line whose text already
#     runs past the pane puts everything after it past the pane too, and the
#     values are after it.
#   * **Scrolling is not a remedy.** The listing scrolls horizontally, to
#     1834px; but a label sits at the END of its own line, so scrolling right
#     far enough to read one takes the line it belongs to off the other side.
#     A value read against the wrong line is worse than one not read.
#   * **Width will not reach it.** The code pane is `weight = 3.0` against the
#     navigation column's `2.0` in `blockTracerReplayLayout()`. Taking it to 4.0
#     buys about 100px against a shortfall of 900.
#
# So the answer is not to make room. It is `Debugger-UX-Research.md` row 9:
# show what fits, and draw the rest as a COUNTED pill — "elision drawn as a
# counted, expandable pill, never a silent cut". The count is the product's own
# claim about its own overlay, so it is computed, not estimated; see
# `LineElision`.
#
# ## Why the arithmetic is here and not in the stylesheet
#
# CSS can hide what does not fit. It cannot say how many it hid, and the number
# is the whole point. So the fit is decided where the labels are — before they
# are markup — which means this renderer-free module has to carry a few facts
# about the shape the renderer gives them. They are named below, each with the
# declaration it mirrors, and every one of them is rounded in the direction
# that shows FEWER labels: a label that was budgeted 4px too wide is a label
# that did not have to be, while one budgeted 4px too narrow is the defect
# coming back.
#
# ## Why the alignment in the wireframe is a different change
#
# `Omniscience-Flow.md` draws a column of labels and the served page does not:
# left edges spread over 862px on one pass. Aligning them is NOT this fix, and
# measurement says it would work against it. A column has to sit past the
# longest line in the file or it draws over source text, and past the longest
# line is past the pane — the two lines that are worst off now would be exactly
# as far off-screen, while every SHORT line, which today gets its labels early
# and legibly, would have them pushed out to the same column and lose them. The
# spec files strict alignment under "Proposed Enhancement" for the desktop app
# and records its upstream implementation as dead code; it stays a separate
# piece of work, and it is one that costs visibility rather than buying it.

const
  CodeAdvancePx = 8.35
    ## One character of `--bt-type-code-size` in `--bt-font-code`. Measured at
    ## 8.291 and rounded up: the code is monospaced, so a line's width is its
    ## length times this, and over-stating it moves the labels left.

  LabelAdvancePx = 7.30
    ## One character of `--bt-type-label-size` in the same face — measured at
    ## 7.226 and rounded up, so a label is budgeted slightly wider than it is.

  LabelChromePx = 10.0
    ## A `.fv` chip's own width: `--bt-space-2xs` of padding and a
    ## `--bt-stroke-hairline` border, on both sides.

  LabelMaxPx = 160.0
    ## `--bt-layout-label-column`, the `max-width` a chip is capped at. A label
    ## longer than this does not measure longer than this — the NAME elides and
    ## the value survives whole — so the budget must not think it does.

  LabelGapPx = 4.0
    ## `--bt-space-2xs`, the gap between two chips in `.ann`.

  ArrowMarginPx = 4.0
    ## The two `--bt-space-3xs` margins around `.fvto`'s arrow.

  ChangeMarginPx = 6.0
    ## `.fvto`'s two plus the one `.fv.m-changed .fvsep` adds after the colon.

  RunOffsetPx = 122.0
    ## Line left edge to the first chip, with the code taken out of it: the
    ## gutter (`--bt-density-cell-x` padding, a `--bt-stroke-thick` border,
    ## `--bt-space-2xl` of line number, `--bt-space-md` of marker and two
    ## `--bt-space-xs` gaps = 90px), then `.srcline`'s third `--bt-space-xs` gap
    ## after the code, then `.ann`'s own `--bt-space-lg` margin.

  PillGapPx = 8.0
    ## `--bt-space-xs`, `.srcline`'s gap — what separates the pill from the run.

  FadePx = 48.0
    ## `--bt-space-2xl`, the width of the mask `.src` fades its right edge over.
    ## Subtracted from every budget because a label that ends inside the fade is
    ## a label rendered half-transparent, and "shown" has to mean "readable".

  SlackPx = 2.0
    ## A last pixel or two against sub-pixel rounding in the measurements above.

func valuePriority*(a: LineAnnotation): int =
  ## Which values give way first when they do not all fit. **The judgement.**
  ##
  ## A reader with this pane open is stepping through a transaction and asking
  ## what THIS step did. The value that changed on this row is the only thing on
  ## the row that answers that, and it exists nowhere else on the page; the
  ## values the row merely read are still in scope, still in the Values pane,
  ## and still on the rows above that wrote them. So when a row cannot show
  ## everything, what it gives up is the context that is available elsewhere,
  ## and what it keeps is the fact that is not.
  ##
  ## Three tiers, in the order `ValueMode` already ranks them —
  ## `vmChanged`'s own documentation says a write is "the single most valuable
  ## thing an inline value can say", and this is that sentence made operative:
  ##
  ##   0. `vmChanged` — this line wrote this variable and the value moved.
  ##   1. `vmAfter` — this line produced this value: a first assignment, or the
  ##      call's return (`→230`), which is the whole outcome of its row.
  ##   2. `vmBefore` — this line read this variable. Context, not news.
  ##
  ## Ties keep SOURCE order, which is `orderExpressionsByColumn`'s order, so the
  ## rule never reaches inside a tier to reorder what the layout decided.
  ##
  ## Two orderings that were considered and rejected. **Shortest first** fits
  ## the most labels per row and is the wrong maximisation — it would drop a
  ## write of `remaining_shield` to keep two reads of `i`, and a count is not
  ## what the reader came for. **Source order**, the order the labels arrive in,
  ## is worse still: it is `assignExpressionColumns`' left-to-right sweep, which
  ## correlates with nothing a reader wants and would make the surviving label
  ## on a tight row a matter of where the variable happened to be typed.
  case a.mode
  of vmChanged: 0
  of vmAfter: 1
  of vmBefore: 2

func labelWidthPx*(a: LineAnnotation): float =
  ## How wide the renderer will draw this chip, capped as the stylesheet caps
  ## it. Counted in RUNES and not bytes: `→` is one glyph and three bytes, and
  ## a value could carry any others.
  let glyphs =
    case a.mode
    of vmBefore: a.label.runeLen + 1 + a.beforeValue.runeLen
    of vmAfter:
      # `→230` when there is no name — the arrow IS the label there.
      (if a.label.len == 0: 1 else: a.label.runeLen + 1) + a.afterValue.runeLen
    of vmChanged:
      a.label.runeLen + 1 + a.beforeValue.runeLen + 1 + a.afterValue.runeLen
  let margins =
    case a.mode
    of vmBefore: 0.0
    of vmAfter: (if a.label.len == 0: ArrowMarginPx else: 0.0)
    of vmChanged: ChangeMarginPx
  min(LabelChromePx + margins + LabelAdvancePx * float(glyphs), LabelMaxPx)

func pillWidthPx(count: int): float =
  ## `+12` drawn as the same chip the labels are.
  LabelChromePx + LabelAdvancePx * float(1 + len($count))

func valueBudgetPx*(bucket: int; codeText: string): float =
  ## How much readable width this line leaves for its values in this regime.
  ##
  ## Negative is a real answer and the important one: it is a line whose CODE
  ## already runs past the pane, and it means no label may be drawn beside it at
  ## all. Clamping it to zero would be the same lie one pixel smaller.
  float(ValueBucketPanePx[bucket]) - FadePx - RunOffsetPx - SlackPx -
    CodeAdvancePx * float(codeText.runeLen)

func fitCount(widths: seq[float]; budget: float): int =
  ## How many of these chips fit, in order, with room left for the `+N` pill
  ## that accounts for the ones that do not.
  ##
  ## A PREFIX, not a subset. Skipping a wide label to squeeze in a narrow one
  ## behind it would fit more chips and would break the only promise the pill
  ## makes worth making: that what was dropped is the least of what this row
  ## recorded, and `+N` is a suffix of a stated order rather than a bag.
  ##
  ## Every k is tried rather than stopping at the first that does not fit,
  ## because the pill's own width is part of the sum and it goes away when the
  ## last label is included — so the whole run can fit where the run minus one
  ## label plus a `+1` did not.
  result = 0
  var run = 0.0
  for k in 1 .. widths.len:
    if k > 1: run += LabelGapPx
    run += widths[k - 1]
    var need = run
    if k < widths.len: need += PillGapPx + pillWidthPx(widths.len - k)
    if need <= budget: result = k

func runWidthPx*(widths: seq[float]; count: int): float =
  for i in 0 ..< count:
    if i > 0: result += LabelGapPx
    result += widths[i]

func pillFitsInline*(drawnPx: float; count: int; budget: float): bool =
  ## Whether a `+count` pill can sit at the end of a row that is already
  ## carrying `drawnPx` of value chips. **Rule 6's whole test.**
  ##
  ## `fitCount` reserved room for the pill whenever it kept a label, so this can
  ## only answer no where it kept none — on a line whose CODE has taken the row
  ## by itself. There the pill has nowhere to go that is not on top of source
  ## text, and `LineElision.stacked` sends it below the line instead.
  ##
  ## Exported because it is the rule a test has to be able to check: an inline
  ## pill must be one that PROVABLY fits, and "provably" means against this
  ## expression rather than against a second copy of it that agrees today.
  drawnPx + PillGapPx + pillWidthPx(count) <= budget

proc planElision*(annotations: var seq[LineAnnotation];
                  codeText: string): seq[LineElision] =
  ## Decide which of a line's values are drawn at which widths, and count the
  ## rest. Writes `bucket` on every annotation and returns the line's pills.
  ##
  ## ## The groups are the passes, because that is what is on screen at once
  ##
  ## Every pass the window carries is in the markup and the stylesheet shows one
  ## (`applyFlow`), so the labels competing for a row's width are the labels of
  ## ONE pass — budgeting them against the whole line's worth would elide a row
  ## that had room and would count values that were never beside each other.
  ##
  ## `NoIteration` is the exception and is handled first: those labels belong to
  ## no pass and are therefore on screen in ALL of them, so they take their
  ## width out of every pass's budget before any pass is measured. The demo
  ## trace has no line that carries both kinds, and the arrangement is here for
  ## the one that will: a per-pass count that ignored the labels permanently
  ## beside it would be a count of the wrong row.
  result = @[]
  if annotations.len == 0: return

  var order: seq[int] = @[]          ## group keys, in first-appearance order
  var groups = initTable[int, seq[int]]()
  for i, a in annotations:
    if a.iteration notin groups:
      order.add a.iteration
      groups[a.iteration] = @[]
    groups[a.iteration].add i
  # The always-on group is measured first so the passes can subtract it.
  if NoIteration in groups and order[0] != NoIteration:
    order.delete(order.find(NoIteration))
    order.insert(NoIteration, 0)

  var reserved: array[ValueWidthBuckets, float]  ## what `NoIteration` occupies
  var dropped = initTable[int, array[ValueWidthBuckets, seq[string]]]()
  var fits = initTable[int, array[ValueWidthBuckets, bool]]()

  for key in order:
    # Priority order inside the group, source order inside a priority — a
    # stable insertion sort, because `seq` sorting in Nim is not stable and the
    # tie-break IS the guarantee (see `valuePriority`).
    var ranked: seq[int] = @[]
    for idx in groups[key]:
      var at = ranked.len
      while at > 0 and
            valuePriority(annotations[ranked[at - 1]]) >
              valuePriority(annotations[idx]):
        dec at
      ranked.insert(idx, at)

    var widths: seq[float] = @[]
    for idx in ranked: widths.add labelWidthPx(annotations[idx])

    # Budgets, then a suffix minimum over them. `fitCount` is monotone in the
    # budget, so the kept sets nest and a label's `bucket` can be a single
    # threshold — but only if the budgets themselves never fall as the pane
    # grows. They can, by a few pixels, when the `NoIteration` group takes one
    # more label at a wider pane than it did at a narrower one. Taking each
    # budget down to the smallest that follows it costs a label nobody would
    # notice and keeps the thresholds honest.
    var budgets: array[ValueWidthBuckets, float]
    for b in 0 ..< ValueWidthBuckets:
      budgets[b] = valueBudgetPx(b, codeText) -
                   (if reserved[b] > 0.0: reserved[b] + LabelGapPx else: 0.0)
    for b in countdown(ValueWidthBuckets - 2, 0):
      budgets[b] = min(budgets[b], budgets[b + 1])

    var kept: array[ValueWidthBuckets, int]
    for b in 0 ..< ValueWidthBuckets:
      kept[b] = fitCount(widths, budgets[b])

    for rank, idx in ranked:
      var bucket = ElidedEverywhere
      for b in 0 ..< ValueWidthBuckets:
        if rank < kept[b]:
          bucket = b
          break
      annotations[idx].bucket = bucket

    if key == NoIteration:
      for b in 0 ..< ValueWidthBuckets:
        reserved[b] = runWidthPx(widths, kept[b])

    var missingAt: array[ValueWidthBuckets, seq[string]]
    var fitsAt: array[ValueWidthBuckets, bool]
    for b in 0 ..< ValueWidthBuckets:
      # Listed in SOURCE order, not in the order they were given up: the pill's
      # list is read as "the other values on this row", and a row's values read
      # left to right. `groups[key]` is already that order.
      for idx in groups[key]:
        if annotations[idx].bucket == ElidedEverywhere or
           annotations[idx].bucket > b:
          missingAt[b].add annotationText(annotations[idx])
      # Rule 6. Does the pill fit on the row, after the labels that did?
      #
      # `fitCount` reserved room for it whenever it kept anything, so this can
      # only be false where it kept NOTHING — a line whose code alone has
      # already taken the row. There the answer is not to draw the pill anyway.
      fitsAt[b] = pillFitsInline(runWidthPx(widths, kept[b]),
                                 max(missingAt[b].len, 1), budgets[b])
    dropped[key] = missingAt
    fits[key] = fitsAt

  # ── Rule 6, continued: one placement per REGIME, not one per pass ─────────
  #
  # A stacked pill leaves the row it belongs to and takes a row of its own, and
  # a row is a fact about the LINE: if one pass's count has to go below, they
  # all do. Passes are shown one at a time, so pills that disagreed about this
  # would make the listing's rows change height as the rail moved — the same
  # line taller in pass 1 than in pass 3, for a reason nothing on screen states.
  var stacked: array[ValueWidthBuckets, bool]
  for b in 0 ..< ValueWidthBuckets:
    for key in order:
      if dropped[key][b].len > 0 and not fits[key][b]:
        stacked[b] = true

  # One pill per RUN of regimes with the same answer — the same counts AND the
  # same placement. Merged over the whole LINE rather than per pass, so that
  # every pill sharing a regime shares a band, and the stacked ones can be
  # collected into ONE row per band instead of one row per pass.
  var b = 0
  while b < ValueWidthBuckets:
    var last = b
    while last + 1 < ValueWidthBuckets and stacked[last + 1] == stacked[b] and
          (block:
            var same = true
            for key in order:
              if dropped[key][last + 1] != dropped[key][b]: same = false
            same):
      inc last
    for key in order:
      if dropped[key][b].len == 0: continue
      # `count` is `dropped[key][b].len` and not `ranked.len - kept[b]`, which
      # is the same number by construction. The point of taking it from the list
      # is that it CANNOT stop being the same number: what `+N` says and what
      # the pill hands over are then one value read twice, and no later edit can
      # make the count drift from the thing it counts.
      result.add LineElision(iteration: key, bucket: b, lastBucket: last,
                             stacked: stacked[b],
                             count: dropped[key][b].len,
                             hidden: dropped[key][b].join("\n"))
    b = last + 1

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

type
  BranchPasses* = object
    ## The two per-pass branch claims, produced together.
    ##
    ## ONE PRODUCER, because they are two answers to one question over one body
    ## of evidence and they must not be able to disagree. A line claimed both
    ## `ran` and `notTaken` in the SAME pass is a contradiction — the pane would
    ## be saying a statement executed and did not execute in one evaluation —
    ## and the only way to make that unrepresentable is to derive both from the
    ## same `ranAt` table in the same walk. Two procs reading the same window
    ## would agree today and would be one edit away from not agreeing.
    notTaken*: Table[int, seq[int]]
      ## Line → the passes in which it sits in a branch that was evaluated and
      ## NOT taken. The three positive facts in `branchPasses`'s header.
    ran*: Table[int, seq[int]]
      ## Line → the passes in which a step was RECORDED on it, restricted to
      ## branch-arm interiors.
      ##
      ## THE POSITIVE CLAIM IS HELD TO THE SAME BAR AS THE NEGATIVE ONE, which
      ## is the whole reason it is computed here rather than read off
      ## `SourceLine.executed`. `executed` is a whole-window boolean — it says
      ## the trace visited this line at some point in some pass — and painting
      ## an affirmative "this arm ran in THIS pass" from it would state pass 0's
      ## control flow over pass 2's, which is exactly the defect rules 7-11 of
      ## the `:target` ladder exist to stop for the negative claim.
      ##
      ## And it is never a default. Nothing is marked `ran` because it was not
      ## dimmed: the evidence is a recorded step, on that line, in that pass.
      ## An arm the recorder emitted no step for gets neither mark, and that
      ## third state — CANNOT TELL — is the one the fixture's `shield.nr:35`
      ## exists to hold: it is an arm interior, it never ran, and the recorder
      ## never instrumented it, so the pane declines both ways.

proc branchPasses*(window: FlowLayoutWindow;
                   conditionals: seq[Conditional]): BranchPasses =
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
          if not result.notTaken.hasKey(line): result.notTaken[line] = @[]
          if pass notin result.notTaken[line]: result.notTaken[line].add pass

      # THE POSITIVE HALF, from the same `ranAt` and in the same walk.
      #
      # Per LINE and not per arm: an arm that ran may still contain a line the
      # recorder emitted no step for — an early return leaves the rest of the
      # block unvisited — and marking the whole interior would be inferring
      # those lines from their neighbours, which is the inference the negative
      # half refuses. A recorded step on the line, in this pass, or nothing.
      #
      # Restricted to arm INTERIORS, which is what makes this a branch mark
      # rather than a second executable marker: the question the reader is
      # asking here is "which way did it go", and `.hit`'s gutter dot already
      # answers "is this line executable". Headers are excluded by the same
      # rule that excludes them from dimming — evaluating a condition is
      # executing that line, so an `else if` header is not evidence about the
      # arm it introduces.
      for arm in conditional.arms:
        for line in arm.firstLine .. arm.lastLine:
          if not ranAt.getOrDefault((pass, line), false): continue
          if not result.ran.hasKey(line): result.ran[line] = @[]
          if pass notin result.ran[line]: result.ran[line].add pass

proc notTakenPasses*(window: FlowLayoutWindow;
                     conditionals: seq[Conditional]): Table[int, seq[int]] =
  ## The negative half alone. A wrapper, so the many existing callers and tests
  ## that only ask about dimming did not have to learn about the pair.
  branchPasses(window, conditionals).notTaken

proc applyFlow*(pane: var EditorPane; input: FlowWindowInput) =
  ## Attach the window's values to the pane's document, and set its rail.
  ##
  ## ## Why every pass is attached and not only the selected one
  ##
  ## The served page ships no JavaScript, so a rail that could only be moved by
  ## script would be an affordance that cannot act — the defect this route has
  ## already removed twice (`session_view.Copyable`, the old `.ctsort`).
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
      pane.documents[d].lines[i].elisions = @[]
      pane.documents[d].lines[i].notTaken = @[]
      pane.documents[d].lines[i].ran = @[]
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
  # whole file, and not from `pane.documents[index].lines`. A brace matcher fed
  # a file that starts at line 26 sees an unbalanced file and would either refuse
  # everything or — far worse — match an `else`'s `}` to some later block's. The
  # pane's line NUMBERS are what the two are joined on, and they are the file's
  # own, which is exactly the property `lineAnchor` exists to guarantee.
  #
  # THE HAZARD IS LATENT, NOT ACTIVE, AND THAT IS WHY THIS IS NOT SIMPLIFIED.
  # This comment used to name `source_document.openAtCurrent` as the thing that
  # made the pane's lines a window; that proc is gone from the repository and the
  # debug route now renders whole documents. The remaining narrower is
  # `source_document.windowAround`, which `ssr.featuredSession` applies to the
  # home page's embed — and it runs AFTER `applyFlow` (see
  # `demo_session.withDemoFlow`), so no call path reaches here with narrowed
  # lines today. Reading the pane instead would work, and would go wrong the
  # first time an order changed or a second narrowing arrived. The pane is not
  # the authority on the file's text; the window is.
  let branches = branchPasses(
    input.window,
    findConditionals(
      input.window.sourceLines,
      profileForDocument(pane.documents[index].path,
                         pane.documents[index].language)))

  for i in 0 ..< pane.documents[index].lines.len:
    let number = pane.documents[index].lines[i].number
    if byLine.hasKey(number):
      pane.documents[index].lines[i].annotations = byLine[number]
      # Rule 5, and it is measured against the line the READER sees. The width
      # a label has to fit in is what its own row leaves, so the code it is
      # counted against is `lines[i].text` — the pane's copy, the one the
      # renderer emits — and not `window.lineText`, which is the same text
      # today and is the wrong thing to depend on: the pane's document is what
      # gets drawn, and a budget computed from a second copy of it would go
      # quietly wrong the first time the two differed.
      pane.documents[index].lines[i].elisions =
        planElision(pane.documents[index].lines[i].annotations,
                    pane.documents[index].lines[i].text)
    if branches.notTaken.hasKey(number):
      pane.documents[index].lines[i].notTaken = branches.notTaken[number]
    if branches.ran.hasKey(number):
      pane.documents[index].lines[i].ran = branches.ran[number]

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

func ranClass*(iteration: int): string =
  ## The class carrying the pass in which a line RAN — `rn-i<N>`, or `rn-any`
  ## for a conditional outside every loop.
  ##
  ## `rn-` and not `tk-`: `tk-` is already the syntax-token prefix
  ## (`tk-keyword`, `tk-comment`), and a second meaning on one prefix would put
  ## "this ran" and "this is a keyword" in the same namespace on the same
  ## element. A separate prefix from `nt-` for the reason `nt-` is separate from
  ## `fv-`: they ride the same `:target` ladder and mean opposite things.
  if iteration < 0: "rn-any" else: "rn-i" & $iteration

func ranClasses*(passes: seq[int]; selected: int): string =
  ## The same shape as `notTakenClasses`, and deliberately so: the two claims
  ## are drawn by one ladder and any asymmetry here would be an asymmetry in
  ## which passes each is shown for.
  if passes.len == 0: return ""
  var now = false
  for pass in passes:
    result.add " " & ranClass(pass)
    if pass < 0 or pass == selected: now = true
  if now: result.add " rnnow"

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
