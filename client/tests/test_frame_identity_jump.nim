## Which FRAME a call-trace row names, and whether a click can land on it.
##
## `just -f client/Justfile test-frame-identity-jump`
##
## WHAT THIS IS ABOUT
## ------------------
## A call-trace row is a jump target. Until this suite the only thing a click on
## one carried was `data-step` — a TIME — and a time does not name a frame.
##
## On the transaction this repository publishes, forty-six frames carry
## twenty-two distinct steps. Thirty-four of the forty-six share their step with
## a sibling. The worst case is a chain of six:
##
##     Map<K, V, Context>::at              map.nr:36        step 59
##     derive_storage_slot_in_map          map.nr:11        step 59
##     poseidon2_hash_with_separator       hash.nr:221      step 59
##     poseidon2_hash                      hash.nr:212      step 59
##     Poseidon2::hash                     poseidon2.nr:16  step 59
##     Poseidon2::hash_internal            poseidon2.nr:68  step 59
##
## Six rows, three files, six different functions, ONE coordinate. That is not a
## flaw in the recording — a call that immediately calls another records no step
## in between, so at step 59 the stack really is ten deep and all six frames
## really are open. It is the reason the coordinate cannot be asked which of the
## six a reader meant, and the reason a click that carries only the coordinate
## lands all six in the same place and marks none of them.
##
## THE IDENTITY THAT DOES WORK WAS ALREADY ON THE ROW
## --------------------------------------------------
## `deeplink_landing.withCallAnchors` stamps every frame with its §6.0a call
## path — `call:0.0.0.3.3.0.0.0.0.0` — computed by BOTH producers from the same
## function, rendered into `data-anchor` on every row, and put in the href. On
## the same pane where the steps collide thirty-four times, the anchors are
## forty-six for forty-six. `test_debug_route` has asserted that distinctness
## since the anchors landed.
##
## So the identity was present, correct, and discarded at the moment of use.
## This suite is what makes that discarding visible: §3 asserts that six rows
## sharing a coordinate resolve to six different frames at six different source
## positions, and §4 that selecting a row marks THAT row.
##
## WHAT IS DELIBERATELY NOT ASSERTED HERE
## --------------------------------------
## Not the coordinate's VALUE. The static export mints a frame's `step` from the
## container's step clock (`tools/chain/lib/calltrace_frames.mjs`) and a live
## session takes it from the engine's `rrTicks`; the two disagree by one on
## almost every frame, and that disagreement is a separate finding with a
## separate fix. Everything below is keyed on the anchor, which is the same
## string under both numbering conventions — so this seam is correct whichever
## way that one is settled, and none of these checks moves when it is.
##
## §5 IS THE CONTROL AND §6 IS THE BITE
## ------------------------------------
## §5 drives a recording whose steps do NOT collide, through the same producer:
## the mechanism must be the same mechanism there, not one that only engages on
## a degenerate pane. That is the shape the synthetic demo corpus has, and it is
## why the corpus that runs most often never caught any of this.
##
## §6 removes the anchors and asserts the suite goes red — because a gate that
## passes on a pane with no identities on it is not measuring the identities.

import std/[unittest, json, os, sets, strutils, tables]

import ../src/debugger/session_view
import ../src/debugger/demo_session
import ../src/debugger/deeplink_landing

const
  clientRoot = currentSourcePath().parentDir.parentDir
  Tx = "0x20ed5b91fae2fc7e564a062434b305d1c250ecad93da70e8e46e7f124d26185f"
  NoirDir = clientRoot / "fixtures" / "noir-frames"

var asserted = 0
template ck(cond: untyped) =
  ## Counted, so a suite that stopped asserting is visible as a number rather
  ## than as a green run. The repository's convention.
  inc asserted
  check cond

proc paneOf(sidecar: string): CallTracePane =
  ## The pane the served page would hold for this sidecar — through the REAL
  ## producer, `demo_session.withCallFrames`, not a hand-built `CallFrame`.
  var s: DebugSessionView
  s.hasFrame = true
  withCallFrames(s, parseJson(readFile(sidecar)))
  s.calltrace

proc paneOfNode(node: JsonNode): CallTracePane =
  ## The same producer, over a sidecar held in memory. §7 of
  ## `test_noir_frame_folding` establishes this shape: the wire form is the one
  ## the published corpus uses, and driving the real producer over it is what
  ## keeps it from being this file's idea of the format.
  var s: DebugSessionView
  s.hasFrame = true
  withCallFrames(s, node)
  s.calltrace

let pane = paneOf(NoirDir / "calltrace" / (Tx & ".json"))

# The six, named by the FUNCTION each row shows, in call order. Named rather
# than discovered so the suite asserts the corpus still holds the case it was
# written for — a capture that stopped containing this chain would make every
# check below vacuously true, and §1 is what turns that into a failure.
const Six = [
  "Map<K, V, Context>::at",
  "derive_storage_slot_in_map",
  "poseidon2_hash_with_separator",
  "poseidon2_hash",
  "Poseidon2::hash",
  "Poseidon2::hash_internal",
]

proc indexOfFn(p: CallTracePane; fn: string; step: int): int =
  ## The first frame of `fn` that starts at `step`. Both halves are needed:
  ## `Poseidon2::hash` occurs twice in this recording, at 59 and at 92, and a
  ## lookup by name alone would take whichever came first and silently measure a
  ## different frame than the one this suite names.
  result = -1
  for i in 0 ..< p.frames.len:
    if p.frames[i].fn == fn and p.frames[i].step == step: return i

suite "1 — THE SUBJECT: the collision is in the recording, and it is this one":
  asserted = 0

  test "the published transaction still holds forty-six frames":
    ck pane.frames.len == 46

  test "…carrying only twenty-two distinct coordinates between them":
    var steps: HashSet[int]
    for f in pane.frames: steps.incl f.step
    ck steps.len == 22

  test "…so most rows cannot be told apart by the coordinate they carry":
    ## The number is the finding, stated as a number so it cannot drift into
    ## prose. 34 of 46 rows share their step with at least one sibling.
    var counts: CountTable[int]
    for f in pane.frames: counts.inc f.step
    var colliding = 0
    for f in pane.frames:
      if counts[f.step] > 1: inc colliding
    ck colliding == 34

  test "the six frames this suite is written about are all present, at step 59":
    for fn in Six:
      ck indexOfFn(pane, fn, 59) >= 0

  test "…they are six DIFFERENT functions across three files":
    var fns, files: HashSet[string]
    for fn in Six:
      let i = indexOfFn(pane, fn, 59)
      fns.incl pane.frames[i].fn
      files.incl pane.frames[i].module.extractFilename
    ck fns.len == 6
    ck files.len == 3

  test "…and they are a single nested chain, one frame per depth":
    ## Six frames at six consecutive depths. This is why no coordinate can
    ## separate them: each calls the next with no step in between, so all six
    ## are open at once and the innermost-containing-frame rule — the one every
    ## producer reaches for — returns the LAST of them whichever was asked for.
    var depths: seq[int]
    for fn in Six: depths.add pane.frames[indexOfFn(pane, fn, 59)].depth
    ck depths == @[4, 5, 6, 7, 8, 9]

  test "COUNTED":
    check asserted == 12

suite "2 — THE IDENTITY: the anchor separates what the coordinate cannot":
  asserted = 0

  test "every frame carries an anchor":
    var withAnchor = 0
    for f in pane.frames:
      if f.anchor.len > 0: inc withAnchor
    ck withAnchor == 46

  test "…and forty-six frames carry forty-six DISTINCT anchors":
    ## The same pane, the same rows, the same instant — twenty-two distinct
    ## coordinates and forty-six distinct anchors. One of these two identifies a
    ## frame and the other does not, and this is the assertion that says which.
    var anchors: HashSet[string]
    for f in pane.frames: anchors.incl f.anchor
    ck anchors.len == 46

  test "the six that share a coordinate have six different anchors":
    var anchors: HashSet[string]
    for fn in Six: anchors.incl pane.frames[indexOfFn(pane, fn, 59)].anchor
    ck anchors.len == 6

  test "COUNTED":
    check asserted == 3

suite "3 — THE LANDING: an anchor resolves to a FRAME, not merely to a tick":
  asserted = 0

  test "each of the six anchors finds its own frame":
    for fn in Six:
      let i = indexOfFn(pane, fn, 59)
      ck frameOfAnchor(pane, pane.frames[i].anchor) == i

  test "…so the six land on six DIFFERENT frames":
    ## The check the coordinate fails. Six anchors in, six distinct frame
    ## indices out; six steps in, one value out.
    var found: HashSet[int]
    for fn in Six: found.incl frameOfAnchor(pane, pane.frames[indexOfFn(pane, fn, 59)].anchor)
    ck found.len == 6

  test "…and on six DIFFERENT source positions":
    ## What the reader sees, which is the point of the whole exercise: six rows
    ## that used to open the same file at the same line now open six.
    var positions: HashSet[string]
    for fn in Six:
      let i = frameOfAnchor(pane, pane.frames[indexOfFn(pane, fn, 59)].anchor)
      positions.incl pane.frames[i].module & ":" & $pane.frames[i].line
    ck positions.len == 6

  test "…each of them INSIDE the function its row names":
    ## Not merely different — right. A landing that moved six rows to six wrong
    ## places would satisfy the check above and fail a reader completely.
    const Want = {
      "Map<K, V, Context>::at": ("map.nr", 36),
      "derive_storage_slot_in_map": ("map.nr", 11),
      "poseidon2_hash_with_separator": ("hash.nr", 221),
      "poseidon2_hash": ("hash.nr", 212),
      "Poseidon2::hash": ("poseidon2.nr", 16),
      "Poseidon2::hash_internal": ("poseidon2.nr", 68),
    }.toTable
    for fn in Six:
      let i = frameOfAnchor(pane, pane.frames[indexOfFn(pane, fn, 59)].anchor)
      ck pane.frames[i].module.extractFilename == Want[fn][0]
      ck pane.frames[i].line == Want[fn][1]

  test "an anchor no frame carries resolves to nothing, and does not guess":
    ck frameOfAnchor(pane, "call:0.0.0.9.9.9") == -1
    ck frameOfAnchor(pane, "") == -1

  test "COUNTED":
    check asserted == 22

suite "4 — THE MARK: the row that was chosen is the row that is current":
  asserted = 0

  test "selecting each of the six marks exactly one row":
    for fn in Six:
      var p = pane
      discard p.selectFrame(p.frames[indexOfFn(p, fn, 59)].anchor)
      var marked = 0
      for f in p.frames:
        if f.current: inc marked
      ck marked == 1

  test "…and the row it marks is the row that was chosen":
    ## The assertion the product could not make before this change. The rule it
    ## replaces — innermost frame containing the step — marks
    ## `Poseidon2::hash_internal` for all six, because all six contain step 59
    ## and it is the deepest.
    for fn in Six:
      var p = pane
      let want = indexOfFn(p, fn, 59)
      discard p.selectFrame(p.frames[want].anchor)
      var got = -1
      for i in 0 ..< p.frames.len:
        if p.frames[i].current: got = i
      ck got == want
      ck p.frames[got].fn == fn

  test "selecting reports the index it marked":
    for fn in Six:
      var p = pane
      let want = indexOfFn(p, fn, 59)
      ck p.selectFrame(p.frames[want].anchor) == want

  test "a selection REPLACES the previous one; two rows are never both current":
    ## Six selections in a row over one pane, which is what a reader clicking
    ## down the chain does. A mark that accumulated would leave the pane
    ## asserting six positions at once.
    var p = pane
    for fn in Six:
      discard p.selectFrame(p.frames[indexOfFn(p, fn, 59)].anchor)
    var marked = 0
    for f in p.frames:
      if f.current: inc marked
    ck marked == 1
    ck p.frames[indexOfFn(p, Six[^1], 59)].current

  test "an anchor that names no frame marks NOTHING, rather than guessing":
    ## The refusal, and it is load-bearing: a selection that fell back to row 0
    ## on a miss would put the mark on `<toplevel>` and call it an answer.
    var p = pane
    discard p.selectFrame(p.frames[indexOfFn(p, "poseidon2_hash", 59)].anchor)
    ck p.selectFrame("call:0.0.0.9.9.9") == -1
    var marked = 0
    for f in p.frames:
      if f.current: inc marked
    ck marked == 0

  test "COUNTED":
    check asserted == 28

suite "5 — CONTROL: a recording whose coordinates do NOT collide":
  ## The mechanism must be the same mechanism on a pane where the coordinate
  ## would have worked — otherwise this is a special case for a degenerate
  ## recording rather than a frame identity. The synthetic demo corpus has
  ## exactly this shape (its seven frames carry seven distinct steps), which is
  ## why it never caught any of the above.
  asserted = 0

  let distinctPane = paneOfNode(%*{
    "frame": [
      {"name": "main", "depth": 0, "step": 1, "endStep": 130},
      {"name": "iterate_asteroids", "depth": 1, "step": 6, "endStep": 128},
      {"name": "calculate_damage", "depth": 2, "step": 41, "endStep": 48},
      {"name": "calculate_remaining_shield_pct", "depth": 3, "step": 49,
       "endStep": 60},
      {"name": "status_report", "depth": 2, "step": 74, "endStep": 110},
      {"name": "calculate_damage", "depth": 2, "step": 112, "endStep": 119},
      {"name": "calculate_remaining_shield_pct", "depth": 3, "step": 120,
       "endStep": 128},
    ]})

  test "CONTROL: the control really has no collisions":
    ## The premise, counted. A control that quietly gained a collision would
    ## stop being a control while every check below stayed green.
    var steps: HashSet[int]
    for f in distinctPane.frames: steps.incl f.step
    ck distinctPane.frames.len == 7
    ck steps.len == 7

  test "CONTROL: it still carries one distinct anchor per frame":
    var anchors: HashSet[string]
    for f in distinctPane.frames: anchors.incl f.anchor
    ck anchors.len == 7

  test "CONTROL: every frame resolves to itself":
    for i in 0 ..< distinctPane.frames.len:
      ck frameOfAnchor(distinctPane, distinctPane.frames[i].anchor) == i

  test "CONTROL: selecting any frame marks that frame and only that frame":
    for i in 0 ..< distinctPane.frames.len:
      var p = distinctPane
      ck p.selectFrame(p.frames[i].anchor) == i
      var marked = 0
      for f in p.frames:
        if f.current: inc marked
      ck marked == 1
      ck p.frames[i].current

  test "CONTROL: the two frames of ONE function are still told apart":
    ## `calculate_damage` twice, at 41 and at 112 — the demo's own recursion
    ## case. Distinct steps here, so the coordinate WOULD separate them; the
    ## anchor separates them too, which is what makes it a replacement rather
    ## than a second mechanism to keep in step.
    var p = distinctPane
    let first = 2
    let second = 5
    ck p.frames[first].fn == p.frames[second].fn
    ck p.frames[first].anchor != p.frames[second].anchor
    discard p.selectFrame(p.frames[second].anchor)
    ck p.frames[second].current
    ck not p.frames[first].current

  test "COUNTED":
    check asserted == 35

suite "6 — MUTATION BITE: with the identity discarded, none of this holds":
  ## The proof that §3 and §4 measure the anchor rather than passing over it.
  ## This is the state the product was in: rows rendered, anchors computed,
  ## and the identity dropped at the moment of use. If a change reintroduced
  ## the anchor and then discarded it again, these are the checks that notice.
  asserted = 0

  proc anchorless(p: CallTracePane): CallTracePane =
    result = p
    for i in 0 ..< result.frames.len: result.frames[i].anchor = ""

  test "BITE: with no anchors, no frame can be found":
    let p = anchorless(pane)
    for fn in Six:
      ck frameOfAnchor(p, pane.frames[indexOfFn(pane, fn, 59)].anchor) == -1

  test "BITE: …and selecting marks nothing at all":
    for fn in Six:
      var p = anchorless(pane)
      ck p.selectFrame(pane.frames[indexOfFn(pane, fn, 59)].anchor) == -1
      var marked = 0
      for f in p.frames:
        if f.current: inc marked
      ck marked == 0

  test "BITE: the coordinate, which is what was used instead, collapses to one":
    ## The counter-measurement, and the whole finding in one number: the six
    ## rows carry six anchors and ONE step, so a click keyed on the step has a
    ## single destination for all six however it is dispatched.
    var steps: HashSet[int]
    var anchorSet: HashSet[string]
    for fn in Six:
      let i = indexOfFn(pane, fn, 59)
      steps.incl pane.frames[i].step
      anchorSet.incl pane.frames[i].anchor
    ck steps.len == 1
    ck anchorSet.len == 6

  test "COUNTED":
    check asserted == 20
