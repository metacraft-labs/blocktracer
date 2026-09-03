## `session_view.selectionDetail` — the selection panel's contents, as values.
##
## `just test-selection-detail`
##
## WHY THIS SUITE EXISTS
## ---------------------
## `selectionDetail` had NO check of its own anywhere in this repository. Its
## only guard was journey 14's `LIVE: selecting a repeated frame makes the panel
## name that function`, and the mutation arm that proves that assertion bites —
## `P4/no-frame-is-current-on-a-live-session` — was DEAD: its `find` string
## still carried the `and v.controls.step > 0` conjunct the fallback shed when
## step 0 was recognised as a real position, so the string occurred ZERO times
## and the arm reported NEVER RAN. For as long as that was true the behaviour
## below had no working guard at ANY layer: no unit test, and a journey
## assertion nothing proved could fail.
##
## The arm is repaired and does bite. This file exists so the behaviour does not
## depend on a journey AND a harness string both staying alive — two things that
## must hold, in two files, neither of which is where the code is.
##
## WHAT IS ASSERTED, AND WHY IT IS THESE VALUES
## --------------------------------------------
## The defect P4 restores is precisely a panel that falls through to `selNone`
## on the one kind of session that has the most frames to describe. Probed in
## the shape P4's own `why` describes — frames drawn, none of them marked
## current, a real position, two frames of the same function — the two readings
## are:
##
##   unmutated:    kind=frame  heading="Current frame"  subject=triangular   Function fact present
##   arm applied:  kind=none   heading="Selection"      subject=(empty)      Function fact ABSENT
##
## So those four are what is checked, in both directions: the frame reading on a
## session that has a position, and the `selNone` reading on one that does not.
## A test that only asserted `kind == selFrame` would pass over a panel headed
## "Selection" with an empty subject.
##
## WHY NO FRAME IS MARKED IN THE FIXTURES BELOW
## --------------------------------------------
## `CallFrame.current` is `CalltraceVM.selectedEntry`, which is READ and never
## WRITTEN on a hydrated session — nothing in the hydration bundle or the Embed
## SDK's projection sets it, because a click on a row is `ct/goto-ticks` and the
## session's answer is a POSITION. Measured on the hydrated calls-and-recursion
## trace: 49 frames drawn, none marked. A fixture that marked one would be
## testing the branch that cannot fire in the browser, and would stay green
## under exactly the mutation this file is here to catch — so `noneMarked`
## below is asserted rather than assumed, on every frame fixture.
##
## COUNTED, AND THE COUNT ASSERTED. Same device as `test_scrub_queue.nim` and
## `test_instruction_listing.nim`: `std/unittest` has no assertion counter, so a
## case that returned early makes FEWER checks rather than failing one.

import std/[unittest, strutils]

import ../src/debugger/session_view

var asserted = 0
template ck(condition: untyped) =
  inc asserted
  check condition
template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

# ── fixtures ────────────────────────────────────────────────────────────────
#
# Built here rather than read from the demo tree, because the point is to reach
# states the demo producer does not produce. The served demo session DOES mark a
# frame; the hydrated one does not, and the second is the state under test.

func frame(fn: string; depth, step: int; module = ""; line = 0;
           current = false; cost = ""; anchor = ""): CallFrame =
  CallFrame(fn: fn, module: module, line: line, depth: depth, step: step,
            current: current, cost: cost, anchor: anchor)

func hydratedSession(frames: seq[CallFrame]; step: int;
                     positioned = true): DebugSessionView =
  ## A session with frames drawn and NONE of them marked — the hydrated shape.
  DebugSessionView(
    hasFrame: true,
    phase: spReady,
    calltrace: CallTracePane(frames: frames, costLabel: "gas"),
    controls: DebugControlsPane(step: step, totalSteps: 1315,
                                positioned: positioned))

func noneMarked(v: DebugSessionView): bool =
  for f in v.calltrace.frames:
    if f.current: return false
  true

func factValue(d: SelectionDetail; label: string): string =
  ## `""` when the panel does not state that fact at all. Distinguishable from
  ## a stated-and-empty fact by `hasFact`, which is the check the arm flips.
  for r in d.facts:
    if r.label == label: return r.value
  ""

func hasFact(d: SelectionDetail; label: string): bool =
  for r in d.facts:
    if r.label == label: return true
  false

func factIsIdentifier(d: SelectionDetail; label: string): bool =
  for r in d.facts:
    if r.label == label: return r.identifier
  false

# The two frames of one function, in call order, each starting at its own step.
# `triangular` is recursive: the same name, the same source line, two frames —
# which is the case the panel's own comment says the STEP is there to tell
# apart, and the case journey 14's live assertion drives.
let recursion = @[
  frame("main", depth = 0, step = 1, module = "src/main.nr", line = 3),
  frame("triangular", depth = 1, step = 5, module = "src/main.nr", line = 11,
        cost = "410"),
  frame("triangular", depth = 2, step = 12, module = "src/main.nr", line = 11,
        cost = "180", anchor = "call:0.1.1"),
]


suite "1 — a hydrated session names the frame its POSITION is in":
  ## The fallback P4 removes. Every fixture here has frames and no mark, so if
  ## the fallback goes, every check in this suite reads the `selNone` panel.

  test "frames drawn, none marked, a real position — the panel is a FRAME":
    let v = hydratedSession(recursion, step = 7)
    # Non-vacuity, above the assertion and not elsewhere in the file: the
    # subject exists, and it is in the state the defect needs.
    ck v.calltrace.frames.len == 3
    ck v.noneMarked

    let d = selectionDetail(v)
    ck d.kind == selFrame
    ck d.heading == "Current frame"
    ck d.subject == "triangular"
    ck d.hasFact("Function")
    ck d.factValue("Function") == "triangular"
    # `identifier` is what renders it as a machine value; a Function row that
    # lost it would still answer `hasFact`.
    ck d.factIsIdentifier("Function")
    ck d.note == ""

  test "the frame chosen is the LAST one that started at or before the position":
    ## Not the first, and not the innermost by depth — frames are in call order
    ## and each carries the coordinate it STARTS at.
    let v = hydratedSession(recursion, step = 4)   # after `main`, before either
    ck v.noneMarked
    let d = selectionDetail(v)
    ck d.kind == selFrame
    ck d.subject == "main"
    ck d.factValue("Depth") == "0"
    ck d.factValue("Starts at step") == "1"

  test "a position exactly ON a frame's first step selects THAT frame":
    ## `f.step <= v.controls.step`, not `<`. A frame's own first step belongs to
    ## it, and `<` would attribute it to the caller.
    let v = hydratedSession(recursion, step = 12)
    let d = selectionDetail(v)
    ck d.subject == "triangular"
    ck d.factValue("Starts at step") == "12"
    ck d.factValue("Depth") == "2"

  test "a position past every frame stays in the last one that started":
    let v = hydratedSession(recursion, step = 900)
    let d = selectionDetail(v)
    ck d.kind == selFrame
    ck d.factValue("Starts at step") == "12"

  test "an explicitly marked frame WINS over the position — the served shape":
    ## The static export's producer does mark a frame, and the mark must beat
    ## the fallback rather than the other way round: otherwise a click that the
    ## page CAN represent would be overridden by where the session stands.
    var frames = recursion
    frames[0].current = true
    let v = hydratedSession(frames, step = 900)
    ck not v.noneMarked
    let d = selectionDetail(v)
    ck d.subject == "main"
    ck d.factValue("Depth") == "0"


suite "2 — two frames of the SAME function are told apart":
  ## The panel earns its place in a recursion trace only if it can say WHICH
  ## `triangular` the session is in. `fn` cannot say it and neither can `line`
  ## — both producers give the frame's SOURCE location, and a function is
  ## declared once — so the fact that separates them is the step.

  test "both positions name the function, and the readings differ by step":
    let inner = selectionDetail(hydratedSession(recursion, step = 13))
    let outer = selectionDetail(hydratedSession(recursion, step = 6))

    # Same function named from both.
    ck inner.subject == "triangular"
    ck outer.subject == "triangular"
    ck inner.factValue("Function") == "triangular"
    ck outer.factValue("Function") == "triangular"

    # And the two frames' shared facts really are shared, so the discriminator
    # below is load-bearing rather than incidental.
    ck inner.factValue("Source") == outer.factValue("Source")
    ck inner.factValue("Source") == "src/main.nr:11"

    # The one fact that differs.
    ck inner.factValue("Starts at step") != outer.factValue("Starts at step")
    ck inner.factValue("Starts at step") == "12"
    ck outer.factValue("Starts at step") == "5"
    ck inner.factValue("Depth") == "2"
    ck outer.factValue("Depth") == "1"
    # Per-frame facts follow the frame, not the function.
    ck inner.factValue("Cost") == "180"
    ck outer.factValue("Cost") == "410"
    ck inner.factValue("Share anchor") == "call:0.1.1"
    ck not outer.hasFact("Share anchor")   # the frame carries none

  test "a frame's step is grouped for reading, like every other read-only count":
    let long = @[frame("deep", depth = 0, step = 1315, module = "src/main.nr")]
    let d = selectionDetail(hydratedSession(long, step = 2000))
    ck d.factValue("Starts at step") == "1,315"

  test "the path the row no longer paints is stated here":
    ## `renderCallTrace` gives the row's whole text width to `fn`, so the panel
    ## holds the other end of that trade. Journey 14's `SERVED: the selection
    ## area states the path the row no longer paints` is the same claim.
    let d = selectionDetail(hydratedSession(recursion, step = 7))
    ck d.hasFact("Source")
    ck d.factValue("Source") == "src/main.nr:11"

  test "a frame with no module and no line states no path at all":
    ## Rung 3: an Aztec contract class publishes no debug symbols, so frames
    ## carry no names or source positions. The absent fact must be ABSENT and
    ## not a `"":0`.
    let d = selectionDetail(hydratedSession(
      @[frame("", depth = 0, step = 1)], step = 4))
    ck d.kind == selFrame
    ck not d.hasFact("Source")
    ck d.hasFact("Function")


suite "3 — with no position and no mark, the panel says so":
  ## The `selNone` reading, which is what P4's mutation produces on the fixture
  ## above. Asserted as VALUES so the two readings are distinguishable: a check
  ## for `kind == selNone` alone is satisfied by a panel with the wrong heading
  ## and a stray subject.

  test "frames drawn, none marked, NO position — kind none, and it explains why":
    let v = hydratedSession(recursion, step = 0, positioned = false)
    ck v.calltrace.frames.len == 3     # the frames really are there
    ck v.noneMarked
    let d = selectionDetail(v)
    ck d.kind == selNone
    ck d.heading == "Selection"
    ck d.subject == ""
    ck not d.hasFact("Function")
    ck d.facts.len == 0
    # A section that renders empty is indistinguishable from a broken one.
    ck d.note == "No row is selected."

  test "a session with no frame at all gets the other sentence":
    var v = hydratedSession(@[], step = 0, positioned = false)
    v.hasFrame = false
    let d = selectionDetail(v)
    ck d.kind == selNone
    ck d.heading == "Selection"
    ck d.subject == ""
    ck d.note.startsWith("This session has no position yet")
    ck d.note != "No row is selected."

  test "step 0 IS a position, so `positioned` and not the step decides":
    ## The sentinel-colliding-with-a-valid-value family: `step > 0` asked the
    ## STEP whether the session had a position, and 0 is the first step of the
    ## trace. A frame beginning at step 0 does not exist — frames begin at 1 —
    ## so a session AT step 0 has no frame to fall back to and correctly says
    ## so, but it must reach that answer through the LINE branch, which does
    ## state its step.
    var v = hydratedSession(recursion, step = 0, positioned = true)
    v.editor = EditorPane(
      documents: @[SourceDocument(path: "src/main.nr", language: "noir",
                                  lines: @[SourceLine(number: 1, text: "fn main() {")])],
      activeIndex: 0, currentLine: 1)
    let d = selectionDetail(v)
    ck d.kind == selLine
    ck d.factValue("Step") == "0"      # stated, not suppressed


suite "4 — precedence: frame, then event, then line":
  ## Every branch is reachable, and the order is a claim in its own right: on a
  ## positioned session all three are true at once.

  let doc = SourceDocument(
    path: "src/shield.nr", language: "noir",
    lines: @[SourceLine(number: 41, text: "    let hit = damage(x);")])
  let editor = EditorPane(documents: @[doc], activeIndex: 0, currentLine: 41)
  let events = EventLogPane(rows: @[
    EventRow(kind: evStorageWrite, step: 6, label: "shields[0]",
             detail: "3 -> 1", current: true, anchor: "sw:shields[0]#1")])

  test "a frame wins over an event and a line that are BOTH current":
    var v = hydratedSession(recursion, step = 7)
    v.eventLog = events
    v.editor = editor
    let d = selectionDetail(v)
    ck d.kind == selFrame
    ck d.heading == "Current frame"
    ck d.subject == "triangular"

  test "with no frames, the current event is the subject":
    var v = hydratedSession(@[], step = 7)
    v.eventLog = events
    v.editor = editor
    let d = selectionDetail(v)
    ck d.kind == selEvent
    ck d.heading == "Current event"
    ck d.subject == "shields[0]"
    ck d.factValue("Kind") == "write"
    ck d.factValue("Detail") == "3 -> 1"
    ck d.factValue("Step") == "6"
    ck not d.hasFact("Function")

  test "with no frames and no CURRENT event, the line is the subject":
    var v = hydratedSession(@[], step = 7)
    v.eventLog = events
    v.eventLog.rows[0].current = false     # rows present, none of them current
    v.editor = editor
    ck v.eventLog.rows.len == 1
    let d = selectionDetail(v)
    ck d.kind == selLine
    ck d.heading == "Current line"
    ck d.subject == "src/shield.nr:41"
    ck d.factValue("File") == "src/shield.nr"
    ck d.factValue("Line") == "41"
    ck d.factValue("Step") == "7"
    ck d.factValue("Source") == "let hit = damage(x);"   # stripped

  test "a listing pane labels the row an Instruction, not a Source line":
    ## Rung 3 again: the row carries a program counter, an opcode and a gas
    ## reading, and `listingCaption` is how the pane says the rows are not code.
    var v = hydratedSession(@[], step = 7)
    v.editor = editor
    v.editor.listingCaption = "345 ACIR opcodes"
    let d = selectionDetail(v)
    ck d.kind == selLine
    ck d.hasFact("Instruction")
    ck not d.hasFact("Source")


suite "5 — the count":
  test "assertion count":
    expectCount(79)
