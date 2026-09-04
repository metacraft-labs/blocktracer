## The Call Trace pane over a Noir call tree: folded by default, and OPENABLE.
##
## `just -f client/Justfile test-noir-frame-folding`
##
## WHAT THIS IS ABOUT
## ------------------
## `aztec-avm-runtime@26cac14` taught both AVM recorders to open a Noir frame at
## every function boundary. On the transaction this repository publishes that
## turns two frames into forty-six, nine deep, over thirty-three distinct
## functions — and a third of the reader's steps land inside poseidon2.
##
## The pane's answer is to start that subtree CLOSED. The distinction this suite
## exists to hold is between the two ways of getting there:
##
##   ELIDE  — leave the frames out. The trace stops saying what executed and no
##            reader, on any day, can get it back.
##   FOLD   — carry every frame and draw one of them shut. Present, named, at its
##            real depth, carrying the count of what is inside, one gesture from
##            being open.
##
## Only the second is implemented, and §3 and §4 below are what make that a
## measurement rather than an intention: the frames inside a closed node are
## asserted to be IN THE MARKUP, and the two derivations of the same container —
## with the policy and without it — are asserted to carry the same forty-six
## frames and differ only in the marks.
##
## THE FIXTURES, AND WHAT IN THEM IS MEASURED
## ------------------------------------------
## `client/fixtures/noir-frames/` is a container written by
## `tools/chain/record-noir-frames-fixture.mjs`. Its frame tree is
## `aztec-avm-runtime`'s own `ContractSourceMap` and `NoirFrameTracker` — the
## modules both real recorders drive — imported and RUN over the version-matched
## FeeJuice artifact and the published container's own decoded step positions.
## Its bytes are the real `CtWriter` driving the real `aztec_ct_writer.wasm`. Its
## per-step AVM registers are zeros and are declared as such in
## `provenance.json`; nothing in the call-trace path reads them.
##
## It exists because the published transaction CANNOT BE RE-RECORDED: the node
## serves transaction bodies out of its active pool for about an hour, and that
## hour is long past. See the tool's header for the full split of what is
## measured, what is reconstructed, and what is zero.
##
## §1 IS THE CONTROL AND IT IS NOT DECORATION
## ------------------------------------------
## The same view code, over the container this repository actually publishes,
## must still render its two frames. That container has no Noir frames in it and
## no library subtree to close, so the correct rendering is exactly the one the
## page served before any of this — `<toplevel>` / `enqueued-call-0`, no
## disclosure, no counts. A reader once reported seeing those two rows and asking
## where the call trace was; the answer must not become "nothing at all".

import std/[unittest, strutils, json, os, sets, sequtils]

import ../src/debugger/session_view
import ../src/debugger/demo_session
import ../src/components/debugger

const
  clientRoot = currentSourcePath().parentDir.parentDir
  Tx = "0x20ed5b91fae2fc7e564a062434b305d1c250ecad93da70e8e46e7f124d26185f"
  NoirDir = clientRoot / "fixtures" / "noir-frames"
  ChainDir = clientRoot / "fixtures" / "chain" / "aztec-testnet"

var asserted = 0
template ck(cond: untyped) =
  ## Counted, so a suite that stopped asserting is visible as a number rather
  ## than as a green run. The repository's convention.
  inc asserted
  check cond

proc paneOf(sidecar: string): CallTracePane =
  ## The pane the served page would hold for this sidecar — through the REAL
  ## producer, `demo_session.withCallFrames`, not a hand-built `CallFrame`.
  ## A fixture assembled here would test this file's idea of the wire shape.
  var s: DebugSessionView
  s.hasFrame = true
  withCallFrames(s, parseJson(readFile(sidecar)))
  s.calltrace

let foldedPane = paneOf(NoirDir / "calltrace" / (Tx & ".json"))
let unfoldedPane = paneOf(NoirDir / "calltrace-unfolded" / (Tx & ".json"))
let controlPane = paneOf(ChainDir / "calltrace" / (Tx & ".json"))

let foldedHtml = renderCallTrace(foldedPane)
let controlHtml = renderCallTrace(controlPane)

suite "1 — CONTROL: the container this repository publishes still renders":
  asserted = 0

  test "the published container's own call trace is still two frames":
    # Not a claim about the fixture: this is `client/fixtures/chain/aztec-testnet`,
    # the real recording, re-derived by the same tool that now resolves paths and
    # marks folds. Two frames is what it holds and two frames is what it must
    # keep holding.
    ck controlPane.frames.len == 2
    ck controlPane.frames[0].fn == "<toplevel>"
    ck controlPane.frames[1].fn == "enqueued-call-0"

  test "…on the pseudo-path, so they carry no file and no line":
    # The rung-3 fact. `path_id 0` is the recorder's "no source position", and
    # resolving paths must not have invented one for these.
    for f in controlPane.frames:
      ck f.module.len == 0
      ck f.line == 0

  test "…and NOTHING about them is folded":
    # An `avm-call-frames/1` sidecar carries no fold fields at all; absent must
    # read as "nothing is closed" rather than as a default that closes things.
    for f in controlPane.frames:
      ck f.foldedBy.len == 0
      ck f.hiddenDescendants == 0
      ck f.hiddenSteps == 0

  test "…and the rendered pane has no disclosure in it":
    # The negative that makes the three above worth having: a page that grew a
    # `<details>` around a two-frame trace would still pass every count.
    ck "ctfold" notin controlHtml
    ck "<details" notin controlHtml
    ck "<summary" notin controlHtml
    ck "cthidden" notin controlHtml
    # …and it still says what it always said.
    ck "&lt;toplevel&gt;" in controlHtml
    ck "enqueued-call-0</span>" in controlHtml

  test "COUNTED": ck asserted == 20

suite "2 — the Noir tree arrives whole, and two frames of it are marked":
  asserted = 0

  test "forty-six frames, nine deep, thirty-three Noir functions":
    # The recorder's own measurement, read back through the view. 44 Noir frames
    # inside the two AVM ones; `aztec-avm-runtime`'s
    # `test_noir_frames_open_at_function_boundaries` measures the same 44 opens,
    # depth 9 and 33 distinct functions from the other side of the container.
    ck foldedPane.frames.len == 46
    var names = initHashSet[string]()
    for f in foldedPane.frames: names.incl f.fn
    ck names.len == 35                       # 33 Noir + the two AVM frames
    ck "FeeJuice::public_dispatch" in names
    ck "PublicContext::maybe_msg_sender" in names
    ck "sender" in names
    # The tree is nested, not a list: the deepest frame is at 10 (depth 0 is
    # `<toplevel>`, so nine Noir levels below the enqueued call).
    ck foldedPane.frames.mapIt(it.depth).max == 10

  test "every Noir frame carries a real source path and line":
    # The whole point of resolving `path_id` through the container's `Path`
    # table. The two AVM frames sit on the pseudo-path and are excluded by name
    # rather than by index, so a reordering cannot make this vacuous.
    var placed = 0
    for f in foldedPane.frames:
      if f.fn == "<toplevel>" or f.fn == "enqueued-call-0":
        ck f.module.len == 0
        continue
      ck f.module.len > 0
      ck f.line > 0
      inc placed
    ck placed == 44

  test "exactly two frames are folded, and they are the hash":
    let folded = foldedPane.frames.filterIt(it.foldedBy.len > 0)
    ck folded.len == 2
    for f in folded:
      ck f.fn == "Poseidon2::hash"
      ck f.foldedBy == "vendored-crate"
      ck "/nargo/" in f.module
      # The rule's sentence rides with it, so the row can say WHY.
      ck f.foldWhy.len > 0

  test "…hiding two frames each, and 22 + 6 = 28 steps":
    # THE NUMBER THE OTHER REPOSITORY MEASURED INDEPENDENTLY. `frame_fold.ts`'s
    # own arm, run over the same artifact by a different implementation in a
    # different language, reports two fold points hiding 22 and 6 steps. This is
    # that answer arrived at through this repository's derivation and read back
    # off the pane. Two producers, one number.
    let folded = foldedPane.frames.filterIt(it.foldedBy.len > 0)
    ck folded.mapIt(it.hiddenDescendants) == @[2, 2]
    ck folded.mapIt(it.hiddenSteps) == @[22, 6]
    ck folded.mapIt(it.hiddenSteps).foldl(a + b) == 28

  test "COUNTED": ck asserted == 110

suite "3 — FOLDED IS NOT ELIDED: what is behind the triangle is in the page":
  asserted = 0

  test "the frames inside a closed node are still in the pane's data":
    # `Poseidon2::hash_internal` and `poseidon2_permutation` are the two frames
    # inside the fold. They are NOT dropped from `frames`, which is what lets
    # `selfCostRows` aggregate over them and what makes the disclosure openable.
    let names = foldedPane.frames.mapIt(it.fn).toHashSet
    ck "Poseidon2::hash_internal" in names
    ck "poseidon2_permutation" in names

  test "…and in the rendered HTML, inside a CLOSED disclosure":
    # THE ASSERTION THAT SEPARATES THIS FEATURE FROM ITS BAD TWIN. An
    # implementation that omitted the subtree would pass every count above and
    # fail here. The reader can open the node because the node's contents were
    # shipped.
    ck "Poseidon2::hash_internal" in foldedHtml
    ck "poseidon2_permutation" in foldedHtml
    ck "<details class=\"ctfold\">" in foldedHtml
    ck "<summary class=\"ctrow" in foldedHtml
    # CLOSED, so `open` must not be on the element. Quoted with the attribute's
    # own delimiter so the word "open" occurring in prose cannot satisfy it.
    ck "<details class=\"ctfold\" open" notin foldedHtml
    ck " open>" notin foldedHtml

  test "the disclosure is a summary, and it carries the row's own data":
    # `hydrate.rowsOf` and `deeplink_landing.resolveAnchor` find frames by
    # `.ctrow` and read `data-step` / `data-anchor` / `data-module` off them. A
    # folded row that lost any of those would silently drop out of deep-link
    # landing, which is exactly the coupling this pane has been bitten by before.
    ck "ctfolded" in foldedHtml
    for f in foldedPane.frames.filterIt(it.foldedBy.len > 0):
      ck ("data-step=\"" & $f.step & "\"") in foldedHtml
    ck "data-module=\"/home/aztec-dev/nargo/" in foldedHtml
    # `data-step` and `data-anchor` stay ADJACENT — `tools/capture/lib/entities.mjs`
    # matches them as one pair, so anything inserted between them stops the
    # harness finding rows.
    ck "data-step=\"59\" data-anchor=" in foldedHtml

  test "the closed row says how much is behind it, in both units":
    # Read off the frame, not recomputed. §5 is what proves that.
    ck "cthidden" in foldedHtml
    ck "2 frames · 22 steps" in foldedHtml
    ck "2 frames · 6 steps" in foldedHtml

  test "…and says WHY it is closed, in the row's own hover text":
    # A fold the reader cannot account for is indistinguishable from missing
    # data. The rule's sentence reaches the page through `frameTooltip`.
    ck "Folded by default —" in foldedHtml
    ck "vendored in through nargo" in foldedHtml

  test "COUNTED": ck asserted == 19

suite "4 — the default can be turned off, and then everything is visible":
  asserted = 0

  test "the same container derived with no rules carries the same 46 frames":
    # `derive-calltrace.mjs --no-fold`, committed beside the folded arm. If
    # folding were elision these two would differ in LENGTH; they differ only in
    # the marks, which is the whole claim stated as a comparison.
    ck unfoldedPane.frames.len == foldedPane.frames.len
    for i in 0 ..< unfoldedPane.frames.len:
      ck unfoldedPane.frames[i].fn == foldedPane.frames[i].fn
      ck unfoldedPane.frames[i].depth == foldedPane.frames[i].depth
      ck unfoldedPane.frames[i].step == foldedPane.frames[i].step
      ck unfoldedPane.frames[i].module == foldedPane.frames[i].module

  test "…with nothing marked, and nothing counted":
    for f in unfoldedPane.frames:
      ck f.foldedBy.len == 0
      ck f.hiddenSteps == 0

  test "…and every one of the 33 functions renders as an ordinary row":
    let html = renderCallTrace(unfoldedPane)
    ck "ctfold" notin html
    ck "<summary" notin html
    ck "cthidden" notin html
    ck "Poseidon2::hash_internal" in html
    ck "poseidon2_permutation" in html

  test "COUNTED": ck asserted == 283

suite "5 — the counts are READ FROM THE CONTAINER, never recomputed here":
  asserted = 0

  test "the pane's numbers are the sidecar's numbers, field for field":
    # Stated as an identity against the file rather than as a recomputation,
    # because a recomputation here would be the very thing this asserts does not
    # happen. `derive-calltrace.mjs` walks every Call, Return and Step event in
    # the container to get these, and cross-checks `hiddenSteps` against the
    # recording's own step clock (`endStep - step`) before writing it down.
    let doc = parseJson(readFile(NoirDir / "calltrace" / (Tx & ".json")))
    ck doc{"schema"}.getStr == "avm-call-frames/2"
    ck doc{"frames"}.getInt == foldedPane.frames.len
    ck doc{"foldedSteps"}.getInt == 28
    var i = 0
    for f in doc{"frame"}:
      ck f{"hiddenSteps"}.getInt(0) == foldedPane.frames[i].hiddenSteps
      ck f{"hiddenDescendants"}.getInt(0) == foldedPane.frames[i].hiddenDescendants
      inc i

  test "MUTATION BITE: a different number in the file is a different number on the row":
    # THE PROOF THAT THE VIEW IS READING AND NOT DERIVING. If `hiddenSteps` were
    # recomputed from the loaded rows this would render `22` no matter what the
    # file said, and the assertion above would be measuring nothing.
    var doc = parseJson(readFile(NoirDir / "calltrace" / (Tx & ".json")))
    for f in doc{"frame"}:
      if f{"foldedBy"}.getStr("").len > 0:
        f["hiddenSteps"] = %*(9991)
        f["hiddenDescendants"] = %*(7)
    var s: DebugSessionView
    s.hasFrame = true
    withCallFrames(s, doc)
    let html = renderCallTrace(s.calltrace)
    ck "7 frames · 9,991 steps" in html
    ck "2 frames · 22 steps" notin html

  test "…and the pane does not re-derive them from the rows it holds":
    # The complement, in the other direction: the frames inside the fold are all
    # present, so a view that DID count them would arrive at 2 descendants — the
    # right answer, by the wrong route, and indistinguishable from the right one
    # until the number the container carries differs from what the view holds.
    # The mutation above is what tells those two apart, and this records why the
    # assertion above had to be a mutation rather than an equality.
    ck foldedPane.frames.filterIt(it.foldedBy.len > 0).len == 2

  test "COUNTED": ck asserted == 99

suite "6 — a nine-deep tree is drawn deep, not flat":
  asserted = 0

  test "depth beyond the indentation ladder is clamped AND marked":
    # `MaxIndentDepth` is 8 and this tree reaches 10. A frame drawn past the
    # ladder with no class resolves to zero indentation, which makes a deep trace
    # look FLAT — indistinguishable from a correct one on a screenshot, and
    # exactly the density collapse the clamp exists to rule out.
    ck foldedPane.frames.mapIt(it.depth).max == 10
    ck "ctrow d8 deeper" in foldedHtml

  test "…and the ladder below it is really used":
    for d in 0 .. 8:
      ck ("ctrow d" & $d) in foldedHtml

  test "COUNTED": ck asserted == 12

suite "7 — the three shapes the published corpus actually holds":
  ## THE HISTOGRAM IS THE REASON THIS SUITE EXISTS. Across the 1,356 published
  ## rows the frame counts are `{absent: 957, 1: 298, 2: 101}` — so the shape the
  ## overwhelming majority of live containers have is NO FRAME RECORDS AT ALL,
  ## and the next most common is exactly one. A depth-eleven tree is the new
  ## shape, not the normal one.
  ##
  ## All three must render without throwing, and the absent case must render the
  ## pane's standing sentence rather than a blank. A reader has already reported
  ## once seeing an almost-empty Call Trace and asking where it had gone; a
  ## regression here would turn that into nothing at all, on 957 pages.
  asserted = 0

  proc paneFromFrames(frames: JsonNode): CallTracePane =
    var s: DebugSessionView
    s.hasFrame = true
    withCallFrames(s, %*{"schema": "avm-call-frames/2", "frame": frames})
    s.calltrace

  test "ABSENT: no frames at all renders the note, not a blank and not a crash":
    # `withCallFrames` leaves the pane untouched on an empty array — the
    # absent-is-valid contract the listing signs — and the renderer answers with
    # the pane's sentence. Both directions asserted: it does not throw, and what
    # comes back is not empty.
    let p = paneFromFrames(%*[])
    ck p.frames.len == 0
    let html = renderCallTrace(p)
    ck html.len > 0
    ck "The call structure comes from the execution trace." in html
    ck "ctfold" notin html

  test "…and so does a payload that is not a frame array at all":
    var s: DebugSessionView
    s.hasFrame = true
    withCallFrames(s, newJNull())
    ck s.calltrace.frames.len == 0
    withCallFrames(s, %*{"schema": "avm-call-frames/2"})
    ck s.calltrace.frames.len == 0

  test "ONE FRAME: a single row renders as a row":
    let p = paneFromFrames(%*[
      {"name": "<toplevel>", "depth": 0, "step": 0, "path": newJNull(),
       "line": newJNull(), "args": [], "endStep": newJNull()}])
    ck p.frames.len == 1
    let html = renderCallTrace(p)
    ck "&lt;toplevel&gt;" in html
    ck "ctrow d0" in html
    ck "<details" notin html

  test "…and a single frame MARKED folded is drawn as a row, not a triangle":
    # The defensive branch in `rows`. The producer never marks a leaf and the
    # publisher refuses one, so this shape cannot come from the tree — but a
    # disclosure over an empty subtree is the one failure here that is silent,
    # and the renderer does not rely on a promise to avoid it.
    let p = paneFromFrames(%*[
      {"name": "Poseidon2::hash", "depth": 0, "step": 0,
       "path": "/home/x/nargo/p/poseidon2.nr", "line": 16, "args": [],
       "endStep": 4, "foldedBy": "vendored-crate", "foldWhy": "vendored",
       "hiddenDescendants": 0, "hiddenSteps": 0}])
    ck p.frames.len == 1
    let html = renderCallTrace(p)
    ck "Poseidon2::hash" in html
    ck "<details" notin html
    ck "<summary" notin html

  test "A DEEP TREE: eleven levels render, each at its own depth":
    # The `absent` and `1` shapes are what is live; this is what lands. Built
    # here rather than read from the fixture so the depth is the subject: the
    # fixture reaches 10, and the recorder has already produced 11 on a longer
    # execution.
    var frames = newJArray()
    for d in 0 .. 10:
      frames.add %*{"name": "f" & $d, "depth": d, "step": d,
                    "path": "/src/a.nr", "line": d + 1, "args": [],
                    "endStep": 20}
    let p = paneFromFrames(frames)
    ck p.frames.len == 11
    let html = renderCallTrace(p)
    for d in 0 .. 8:
      ck ("ctrow d" & $d) in html
    # Past the ladder, clamped AND marked — never drawn flat.
    ck "ctrow d8 deeper" in html
    ck "ctrow d9" notin html
    ck "ctrow d10" notin html

  test "COUNTED": ck asserted == 28
