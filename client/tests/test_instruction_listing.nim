## The instruction listing — the Code pane's honest floor.
##
## THE DEFECT. On `blocktracer.org/aztec/tx/0x00c67f6f…/debug` the Code pane
## rendered prose and nothing else: two paragraphs, one of which said "the
## recording is therefore at instruction level: every step is a program counter",
## followed by no instructions. The recording has 208 steps, each carrying a
## program counter, and the pane whose whole question is "where is this stopped"
## had nothing on screen to be stopped at. Every real chain transaction this site
## publishes was in that state, which is also why a sibling had to add a separate
## `.srcpos` element: with no listing there was no row to mark.
##
## What is graded here is the shipping path over the COMMITTED CAPTURES, built by
## the real producers (`ingestSnapshot`, `renderRoute`), plus the two seams the
## rendered page cannot show — the opcode table's own honesty check, and the
## island a hydrated session re-renders from.
##
## ## Counted, with a control and a mutation per case
##
## `std/unittest` has no assertion counter, so a loop over a set that turned out
## to be empty removes assertions silently and the suite still reports green
## (Verification-Harness-Traps §4b). `ck` counts and `expectCount` fails on a
## total that is not the number written from a run.
##
## Every claim also carries the arm that could have made it vacuous: a control
## that shows the assertion has something to look at, and a mutation of the real
## product value that is asserted to flip it.

import std/[unittest, os, json, strutils, algorithm, tables]

import ../src/ssr
import ../src/reader
import ../src/debugger/avm_opcodes
import ../src/debugger/demo_session
import ../src/debugger/instruction_listing
import ../src/debugger/session_view
import ../src/debugger/source_document
import ../src/debugger/source_island
import ../src/components/debugger as dbgc
import blocktracer/demo/generator
import blocktracer/chain/ingest

let
  clientRoot = currentSourcePath().parentDir.parentDir
  repoRoot = clientRoot.parentDir
  fixtureDir = repoRoot / "fixtures" / "trace" / "noir_space_ship"
  fixture = fixtureDir / "zk_shields.ct"
  fixtureSources = fixtureDir / "sources"
  chainFixtures = clientRoot / "fixtures" / "chain"
  workDir = getTempDir() / ("blocktracer-instr-" & $getCurrentProcessId())

doAssert dirExists(chainFixtures),
  "no chain captures under " & chainFixtures & " — every arm below would pass " &
  "vacuously over a tree with no real recording in it, so this refuses rather " &
  "than skips"

removeDir(workDir)
createDir(workDir)
discard generate(DemoConfig(outDir: workDir, seed: "instr-listing-test",
                            traceFixturePath: fixture,
                            traceSourcesDir: fixtureSources))
var captureDirs: seq[string]
for kind, path in walkDir(chainFixtures):
  if kind == pcDir and fileExists(path / "snapshot.json"): captureDirs.add path
captureDirs.sort()
doAssert captureDirs.len > 0, "no chain captures under " & chainFixtures
for d in captureDirs:
  discard ingestSnapshot(IngestConfig(outDir: workDir, snapshotDir: d))
let root = newDataRoot(workDir)
# EVERY chain in the tree, real and synthetic. The synthetic one is not
# decoration here: it is the only source-level recording this tree can publish,
# and the coexistence claim in suite 5 has nothing to be a control against
# without it.
let allChains = chains(root)

# ── the subjects, chosen by a PROPERTY and never by name ────────────────────
#
# `tools/journeys/README.md`'s first rule applies to a unit suite for the same
# reason it applies to a journey: the `Nargo.toml` defect survived 115 cases
# because the fixture supplied the position they asserted back. So the subjects
# here are "every transaction on a real chain whose recording is instruction
# level", read off the tree, and a capture that gains or loses one changes what
# is graded without this file being edited.
type Subject = object
  chain, tx: string
  steps, step: int
  listing: JsonNode

var subjects: seq[Subject]
var sourceLevelSubjects: seq[Subject]
var positionedSubjects: seq[Subject]
  ## Recordings whose manifest does NOT claim source level and which render
  ## source anyway, from the per-step stream in `positions.json`.
  ##
  ## THE PARTITION USED TO BE `t.sourceLevel` AND THAT IS THE WRONG QUESTION
  ## HERE. This file grades what the Code pane RENDERS — it looks for listing
  ## rows, a `▶`, a "stopped at step" caption — and the manifest bit stopped
  ## predicting that. `sourceLevel` means EVERY executed step is positioned, a
  ## claim no real chain capture can make (CHAIN-CAPTURE.md §6.5), while a
  ## recording that positions MOST of its steps now renders real Noir. Testnet
  ## 0x20ed5b91… is exactly that: `sourceLevel: false`, 86 of 108 steps placed,
  ## a Code pane full of `avm.nr`. Partitioned by the bit it landed in
  ## `subjects` and failed five assertions that are true of every listing and
  ## none of it — including "the tree publishes a listing for each", which it
  ## deliberately does not, because `derive-instructions.mjs` refuses a
  ## container whose `line` field holds source lines rather than pcs.
  ##
  ## So the discriminator is the pane's own availability, which is the thing
  ## being graded rather than a proxy for it.
for chain in allChains:
  let info = chainInfo(root, chain)
  for h in blockHashes(root, info):
    for tx in readBlockDetail(root, info, h).transactions:
      let t = traceView(root, info, tx)
      if t.outcome != tvReplayable: continue
      let s = debugSessionFor(root, chain, tx)
      let subj = Subject(chain: chain, tx: tx, steps: t.steps,
                         step: s.controls.step, listing: t.instructions)
      if t.sourceLevel: sourceLevelSubjects.add subj
      elif s.editor.availability == srcSourceLevel: positionedSubjects.add subj
      else: subjects.add subj

var asserted = 0
template ck(condition: untyped) =
  inc asserted
  check condition
template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

proc debugBody(s: Subject): string =
  renderRoute(root, "/" & s.chain & "/tx/" & s.tx & "/debug").body

proc occurrences(hay, needle: string): int =
  var i = 0
  while true:
    let j = hay.find(needle, i)
    if j < 0: break
    inc result
    i = j + needle.len

# ---------------------------------------------------------------------------

suite "1 — the mnemonics are checked against the recording, never asserted":
  asserted = 0
  ## A name is an interpretation of an opcode NUMBER against a version of the
  ## instruction set, and this repository has a standing rule about the
  ## difference: "Applying Noir's lexer to a Solidity file … would produce
  ## confident nonsense, which is worse than plain text because it looks
  ## authoritative" (`source_document.nim`).
  ##
  ## So the table predicts something falsifiable. Every entry carries the
  ## instruction's encoded length, and a recording's program counters are
  ## offsets into the bytecode — so for two consecutive steps that did not
  ## branch, `pc[i+1] - pc[i]` must be that length. A table naming the wrong
  ## instructions would have to agree with the recorder's own counters by
  ## accident, hundreds of times, on a stream neither side derived from the
  ## other.

  test "there ARE real instruction-level recordings to check":
    # The control for the whole file. Without it every loop below is a loop
    # over nothing and the suite is green about code it never reached.
    ck subjects.len > 0
    var withListing = 0
    for s in subjects:
      if s.listing != nil: inc withListing
    ck withListing == subjects.len       # the tree publishes one for each
    ck subjects.len == 26

    # AND THE EXCLUDED ONE IS EXCLUDED FOR A REASON THAT IS ITSELF CHECKED.
    # Narrowing a population is how a suite goes green by grading less, so the
    # recording this file no longer asks for a listing is asserted to render the
    # better thing instead — real source, from its own per-step positions, with
    # no listing published for it at all.
    ck positionedSubjects.len == 1
    for s in positionedSubjects:
      ck s.listing == nil                # `derive-instructions.mjs` refused it
      let sess = debugSessionFor(root, s.chain, s.tx)
      ck sess.editor.availability == srcSourceLevel
      ck sess.editor.positionedSteps > 0
      ck sess.editor.positionedSteps < sess.editor.positionedOf
      ck activeDocument(sess.editor).path.endsWith(".nr")

  test "the table reproduces every program counter it predicts":
    var checked = 0
    var matched = 0
    var recordings = 0
    for s in subjects:
      let l = decodeInstructionListing(s.listing)
      ck l.hasListing
      ck l.named                         # the names were EARNED, per recording
      ck l.check.explains
      ck l.check.unknown == 0
      checked += l.check.checked
      matched += l.check.matched
      inc recordings
    # The population grew with the 2026-09-02 testnet capture: 8 real
    # instruction-level recordings became 26, and one further recording —
    # 0x20ed5b91… — left this population entirely because it renders source.
    # Restated at the measured value rather than relaxed to `> 0`: an exact
    # count is what makes a check that silently stopped predicting fail
    # differently from one that predicted everything and was right.
    ck recordings == 26
    # The count is asserted, not merely non-zero: a check that silently stopped
    # predicting would otherwise report the same green as one that predicted
    # everything and was right.
    ck checked == 5167
    ck matched == checked

  test "MUTATION BITE: a table shifted by one explains nothing":
    # The mutation is on the DATA and not on the table, because the table is a
    # `const` — shifting every opcode number by one in a real recording is the
    # same experiment seen from the other side, and it is what would actually
    # happen if upstream's enum gained a member.
    ck subjects.len > 0
    let victim = subjects[0]
    var shifted = victim.listing.copy
    var ops = newJArray()
    for v in shifted["op"]: ops.add newJInt(v.getInt + 1)
    shifted["op"] = ops
    let l = decodeInstructionListing(shifted)
    ck l.hasListing                      # it still lists — losing names is not
    ck not l.named                       # …losing the listing
    ck l.check.checked > 0               # and it was actually asked
    ck l.check.matched < l.check.checked

  test "MUTATION BITE: an opcode outside the table is refused, not guessed":
    ck subjects.len > 0
    var alien = subjects[0].listing.copy
    var ops = newJArray()
    var first = true
    for v in alien["op"]:
      ops.add newJInt(if first: 9_999 else: v.getInt)
      first = false
    alien["op"] = ops
    let l = decodeInstructionListing(alien)
    ck l.check.unknown == 1
    ck not l.check.explains
    ck not l.named
    # …and the row for it is a NUMBER, not a name-shaped placeholder that would
    # be read as one.
    let doc = listingDocument(l, 1)
    ck doc.lines[0].text.contains("opcode 9999")
    ck not doc.lines[0].text.contains("UNKNOWN")

  test "CONTROL: the check refuses to pass by never being asked":
    # A recording of pure branches makes no prediction, and `explains` must be
    # false for it — otherwise "nothing was checked" and "everything checked
    # out" are the same answer.
    let jumpOnly = %*{
      "isa": "aztec-avm", "steps": 2,
      "pc": [0, 64], "op": [35, 35], "l2": [1, 2], "ctx": [1, 1]}
    let l = decodeInstructionListing(jumpOnly)
    ck l.hasListing
    ck l.check.checked == 0
    ck l.check.skipped == 1
    ck not l.check.explains
    ck not l.named

  test "assertion count":
    expectCount(132)

suite "2 — the pane renders instructions, with the current one marked":
  asserted = 0
  ## The defect, stated as the thing that must now be true of the RENDERED tree:
  ## a real chain transaction's Code pane shows its instructions, and the one the
  ## session is stopped at is marked.

  test "every real recording's Code pane holds rows, and exactly one is current":
    var pages = 0
    for s in subjects:
      let body = debugBody(s)
      # The listing exists, and it is a listing rather than a source pane.
      ck occurrences(body, "<div class=\"src instr\">") == 1
      ck occurrences(body, "<p class=\"instrcap\">") == 1
      ck occurrences(body, "class=\"srcline") > 0
      # Exactly ONE current row, and its number is the step the toolbar counts.
      # Two producers of the position would disagree the first time either
      # changed, which is the defect `entryStepWithin` was written to close.
      ck occurrences(body, "<div class=\"srcline cur hit\"") == 1
      ck occurrences(body, "id=\"L-avm-" & $s.step & "\" data-line=\"" &
                     $s.step & "\" aria-current=\"true\"") == 1
      ck occurrences(body, "<span class=\"p\" tabindex=\"-1\" " &
                     "autofocus=\"autofocus\" aria-label=\"the session is " &
                     "stopped on line " & $s.step & "\">▶</span>") == 1
      # The position is on the ACCESSIBILITY TREE and countable in both
      # directions: one `true`, and every other row explicitly `false`.
      ck occurrences(body, "aria-current=\"false\"") ==
         occurrences(body, "class=\"srcline") - 1
      # …and the pane still states it in words, above the rows.
      ck occurrences(body, "The session is stopped at step ") == 1
      # Matched on the CLASS ATTRIBUTE and not on the bare name: the page
      # inlines the stylesheet, and `.srcline{` is declared above `.srcpos{` in
      # it, so a bare `find` compares two positions inside the CSS.
      ck body.find("class=\"srcpos\"") < body.find("class=\"srcline")
      inc pages
    ck pages == 26

  test "the rows carry the program counters the recording actually holds":
    # Not "some hex appears". Every counter in the published stream that falls
    # inside the served window has to be on the page, at the row its ordinal
    # names — which is the claim "the program counters the recording carries,
    # positioned" reduces to.
    var rows = 0
    var want = 0
    for s in subjects:
      let body = debugBody(s)
      let l = decodeInstructionListing(s.listing)
      ck l.stepCount == s.steps
      let doc = listingDocument(l, s.step)
      ck doc.lines.len == s.steps
      var onPage = 0
      for i, ln in doc.lines:
        if not body.contains("id=\"L-avm-" & $ln.number & "\""): continue
        # the row's own text, verbatim, including its counter
        ck body.contains(">" & ln.text & "</code>")
        inc onPage
      ck onPage > 0
      # EVERY row of the recording is on the page, not merely some of them. This
      # used to be `onPage > 0` plus a total of 1314, which held while the pane
      # was served windowed; the eight containers hold 2269 steps between them
      # and 955 of those rows were never in the DOM.
      ck onPage == s.steps
      rows += onPage
      want += s.steps
    ck rows == want
    ck want == 5746

  test "MUTATION BITE: an unpositioned session marks no row":
    # The listing is still rendered — "here is the whole recording and this page
    # does not know where in it you are" is a true frame — but nothing claims to
    # be current. Without this arm, a renderer that marked row 1 unconditionally
    # would satisfy every count above.
    ck subjects.len > 0
    let l = decodeInstructionListing(subjects[0].listing)
    # `-1`, not `0`: row 0 is tick 0 and is a real position. "No position" is a
    # coordinate the listing does not contain, which is what an unpositioned
    # session has.
    var pane = EditorPane(availability: srcUnverified, reason: "no source",
                          listingCaption: listingCaption(l),
                          documents: @[listingDocument(l, -1)],
                          activeIndex: 0, currentLine: -1)
    let html = dbgc.renderSource(pane)
    ck occurrences(html, "class=\"srcline") == l.stepCount
    ck occurrences(html, "aria-current=\"true\"") == 0
    ck occurrences(html, ">▶</span>") == 0
    # An unpositioned listing autofocuses nothing, because there is nothing to
    # open it at — the attribute travels with the position and not with the pane.
    ck occurrences(html, "autofocus") == 0
    # …and the control: the same pane WITH a position marks exactly one.
    pane.documents = @[listingDocument(l, 42)]
    pane.currentLine = 42
    let marked = dbgc.renderSource(pane)
    ck occurrences(marked, "aria-current=\"true\"") == 1
    ck occurrences(marked, ">▶</span>") == 1
    ck occurrences(marked, "autofocus=\"autofocus\"") == 1

  test "the listing is served WHOLE, so it announces no reduction at all":
    # This used to read "the window announces itself in STEPS, not in lines".
    # `openAtCurrent` dropped the rows above a six-row lead-in and `renderSource`
    # said "Showing from step 122" over what was left, which was the right
    # sentence about the wrong behaviour: the same lead-in that hid 70 of an
    # 83-line Noir file hid 122 of a 338-step listing, and a reader looking for
    # the instruction before the one they are on had to hydrate to see it.
    #
    # The reduction is gone, so the notice is silent. THE COUNT IS WHAT MAKES
    # THIS AN ASSERTION: a listing SHORTER than the old lead-in carried no
    # `srcfrom` either, so "no banner" on its own would pass over a pane that
    # rendered six rows. Every listing here is compared against its own recorded
    # step count.
    var judged = 0
    for s in subjects:
      let body = debugBody(s)
      ck occurrences(body, "class=\"srcline") == s.steps
      # The SENTENCE and not the class name: `.srcfrom` is a rule in the
      # stylesheet this page inlines, so `"srcfrom" notin body` would be
      # answered by the CSS and never by the markup.
      ck occurrences(body, "<div class=\"srcfrom\">") == 0
      ck not body.contains("class=\"srcfrom\">Steps ")
      ck not body.contains("class=\"srcfrom\">Lines ")
      inc judged
    ck judged == 26

  test "assertion count":
    expectCount(6200)

suite "3 — it composes with the marks the pane already draws":
  asserted = 0
  ## The listing goes through `renderSource`, which is what makes "the position
  ## is marked the same way" a property of the code rather than a claim about it.
  ## These are the collisions that would show up if it did not.

  test "the position glyph is in .p and the branch cell is untouched":
    # A sibling moved `▶` out of `.m` into a cell of its own, because `.m` was
    # answering two questions and CSS resolved the collision by hiding one of
    # them — on the current row, which is the row whose glyph matters most.
    # Reintroducing that would look exactly like a listing with no marker.
    for s in subjects:
      let body = debugBody(s)
      # The row's cell, spelled EXACTLY, because this page carries a second `.p`
      # that also holds `▶`: `.srcpos`, the position head, which states the same
      # coordinate in words above the rows. A loose `">▶</span>"` match counts
      # both and would go on passing if the listing lost its own marker.
      ck occurrences(body, "<span class=\"p\" tabindex=\"-1\" " &
                     "autofocus=\"autofocus\" aria-label=\"the session is " &
                     "stopped on line " & $s.step & "\">▶</span>") == 1
      ck occurrences(body, "<span class=\"m\">▶</span>") == 0
      # every row has a `.p` cell, current or not, so the current row's text
      # cannot be the one row that does not align. The un-attributed spelling
      # counts the non-current rows — the current one carries the
      # `tabindex`/`autofocus` pair that opens the pane at the position with no
      # script on the page — and `.srcpos` is not among them, because that cell
      # carries `aria-hidden`.
      ck occurrences(body, "<span class=\"p\">") ==
         occurrences(body, "class=\"srcline") - 1

  test "no branch claim is made, on either channel":
    # `notTaken`/`ran` are the source pane's claim about a branch ARM, drawn as
    # a dimmed block with `⊘`. This listing has no arms and no passes, and empty
    # means "nothing is claimed" rather than "did not run".
    for s in subjects:
      let body = debugBody(s)
      let pane = debugSessionFor(root, s.chain, s.tx).editor
      var claims = 0
      for d in pane.documents:
        for ln in d.lines: claims += ln.notTaken.len + ln.ran.len
      ck claims == 0
      # The PANE and not the whole page for the two class-name channels: the
      # page inlines the stylesheet, so `.srcline.ntnow` is in the markup as a
      # SELECTOR whether or not any row wears it — the trap
      # `test_debug_route` records beside its own `tk-` assertions.
      let paneHtml = dbgc.renderSource(pane)
      ck occurrences(paneHtml, "class=\"mn\"") == 0
      ck occurrences(paneHtml, "class=\"mt\"") == 0
      ck occurrences(paneHtml, "ntnow") == 0
      ck occurrences(paneHtml, "rnnow") == 0
      # …and no loop rail, by `applyFlow`'s own rule.
      ck occurrences(body, "class=\"flowrail\"") == 0

  test "MUTATION BITE: the branch assertions can see a branch mark":
    # Without this the four `== 0` above would pass on a renderer that had
    # stopped emitting branch marks entirely.
    ck subjects.len > 0
    let l = decodeInstructionListing(subjects[0].listing)
    var doc = listingDocument(l, 1)
    doc.lines[0].notTaken = @[-1]
    doc.lines[1].ran = @[-1]
    let html = dbgc.renderSource(EditorPane(
      availability: srcUnverified, reason: "no source",
      documents: @[doc], activeIndex: 0, currentLine: 1))
    ck occurrences(html, "class=\"mn\"") == 1
    ck occurrences(html, "class=\"mt\"") == 1
    ck occurrences(html, "ntnow") > 0

  test "nothing is lexed — a listing wears no source colours":
    # The anti-requirement `expectations.mjs` names: "a bytecode or instruction
    # listing wearing source colours … confident mis-tokenisation is a worse
    # failure than plain text because it looks authoritative". Matching on
    # `class="tk-…"` and not on the bare name, because the page inlines the
    # stylesheet and every rule's selector is in the markup regardless.
    for s in subjects:
      let body = debugBody(s)
      ck occurrences(body, "class=\"tk-keyword\"") == 0
      ck occurrences(body, "class=\"tk-number\"") == 0
      ck occurrences(body, "class=\"tk-punct\"") == 0
      let pane = debugSessionFor(root, s.chain, s.tx).editor
      var toks = 0
      for d in pane.documents:
        for ln in d.lines: toks += ln.tokens.len
      ck toks == 0

  test "the caption strip replaces the tab strip, and says what the rows are":
    for s in subjects:
      let body = debugBody(s)
      ck occurrences(body, "class=\"srctabs\"") == 0
      ck body.contains(" as the session counts them · program counter")
      # the object the counters index — the fact that separates "unpositioned"
      # from "unlabelled"
      ck body.contains("counters are offsets into ")

  test "assertion count":
    expectCount(420)

suite "4 — the prose sits beside the listing, and says what is true now":
  asserted = 0
  ## Some of it has to stay: a reader deserves to know why there is no source.
  ## What it may not do is BE the pane, and what it may not say is that the
  ## chain never has source — `artifactHash` exists precisely so a client can
  ## verify an artifact fetched off-chain, and verified artifacts resolve.

  test "the reason is present, and above the rows":
    for s in subjects:
      let body = debugBody(s)
      ck occurrences(body, "class=\"srcnone\"") == 1
      ck occurrences(body, "class=\"src instr\"") == 1
      # above, because the rows scroll and an explanation at the bottom of a
      # scrollport is one nobody reaches
      ck body.find("class=\"srcnone\"") < body.find("class=\"srcline")
      # and the action, still inert and still saying so on three channels
      ck occurrences(body, "aria-disabled=\"true\" title=\"BlockTracer cannot " &
                     "accept supplied sources yet.") == 1

  test "the retired claim is gone from every page of the site":
    # "an Aztec contract class carries bytecode, and no debug symbols, no file
    # map and no source text" is true of the on-chain class OBJECT and false as
    # a claim about availability, which is what a reader takes from it.
    for chain in allChains:
      let info = chainInfo(root, chain)
      for h in blockHashes(root, info):
        for tx in readBlockDetail(root, info, h).transactions:
          for suffix in ["", "/debug"]:
            let body = renderRoute(root, "/" & chain & "/tx/" & tx &
                                   suffix).body
            ck "no debug symbols, no file map and no source text" notin body
            ck "The chain publishes no source for this contract" notin body

  test "what it says instead is about THIS recording, and names the route out":
    for s in subjects:
      let body = debugBody(s)
      ck body.contains("No source resolved for the code this transaction ran")
      ck body.contains("commitment to a contract's compiled artifact")
      ck body.contains("fetched off-chain and checked against that commitment")
      ck body.contains("which has not happened for this contract")
      ck body.contains("Stepping is complete")

  test "CONTROL: with no listing published, the pane is what it always was":
    # The third state, and it is a real one: a capture taken before the
    # derivation existed publishes a manifest, a container and no listing. It
    # must not become an empty pane, and it must not become a listing of
    # nothing.
    var s = debugSessionFor(root, subjects[0].chain, subjects[0].tx)
    s.editor = EditorPane(availability: srcUnverified, reason: s.editor.reason)
    withInstructionListing(s, nil)
    ck s.editor.documents.len == 0
    let html = dbgc.renderSource(s.editor, s.controls)
    ck occurrences(html, "class=\"srcnone\"") == 1
    ck occurrences(html, "class=\"srcline") == 0
    ck html.contains("Stepping continues at instruction level.")
    ck occurrences(html, "class=\"srcpos\"") == 1

  test "assertion count":
    expectCount(4095)

suite "5 — source and instructions coexist; neither is hard-coded":
  asserted = 0
  ## Off-chain artifact resolution is landing, and fidelity is becoming a
  ## per-transaction fact rather than a constant of the chain. The listing is the
  ## floor for what does not resolve and must never be able to displace a rung
  ## above it.

  test "a source-level session still renders source and no listing":
    # The control arm for the whole coexistence claim. The demo chain publishes
    # the only source-level recordings this tree has.
    ck sourceLevelSubjects.len > 0
    var pages = 0
    for s in sourceLevelSubjects:
      let body = debugBody(s)
      ck occurrences(body, "class=\"instrcap\"") == 0
      ck occurrences(body, "class=\"src instr\"") == 0
      ck occurrences(body, "class=\"srctabs\"") > 0
      inc pages
    ck pages == sourceLevelSubjects.len

  test "MUTATION BITE: the floor refuses a pane that already has a rung":
    # Handed a real listing and a source-level pane, `withInstructionListing`
    # must decline. Without the refusal, the moment a bundle resolves for one of
    # these contracts its source would be replaced by program counters — the
    # exact inversion of the defect being fixed.
    ck subjects.len > 0
    let node = subjects[0].listing
    ck node != nil

    var srcSession = debugSessionFor(root, sourceLevelSubjects[0].chain,
                                     sourceLevelSubjects[0].tx)
    let before = srcSession.editor.documents.len
    ck before > 0
    withInstructionListing(srcSession, node)
    ck srcSession.editor.documents.len == before
    ck srcSession.editor.availability == srcSourceLevel
    ck srcSession.editor.listingCaption.len == 0
    ck activeDocument(srcSession.editor).path.endsWith(".nr")

    # …and an unverified pane that ALREADY has documents is refused too, so a
    # second call cannot rebuild a listing over one that is already positioned.
    var twice = debugSessionFor(root, subjects[0].chain, subjects[0].tx)
    let docs = twice.editor.documents.len
    ck docs > 0
    var poisoned = node.copy
    poisoned["pc"] = %*[0]
    poisoned["op"] = %*[39]
    poisoned["l2"] = %*[1]
    poisoned["ctx"] = %*[1]
    withInstructionListing(twice, poisoned)
    ck twice.editor.documents.len == docs
    ck twice.editor.documents[0].lines.len ==
       activeDocument(twice.editor).lines.len
    ck twice.editor.documents[0].lines.len > 1

  test "the published tree carries a listing beside every real container":
    # The data-plane half. `instructions.json` is a sibling of `trace.ct`, and
    # its step count must equal the manifest's — a listing of a different length
    # would put the marker on the wrong row with every surface reporting success.
    var found = 0
    var positioned = 0
    for chain in allChains:
      let info = chainInfo(root, chain)
      for h in blockHashes(root, info):
        for tx in readBlockDetail(root, info, h).transactions:
          let t = traceView(root, info, tx)
          if t.outcome != tvReplayable or t.sourceLevel: continue
          # A RECORDING THAT PUBLISHES POSITIONS PUBLISHES NO LISTING, and the
          # skip is on the object rather than on `sourceLevel`, which is the
          # manifest's all-or-nothing claim and false for exactly this case.
          # Reading it the other way dereferenced a nil `instructions` and took
          # the suite down with a SIGSEGV rather than a failed check — the
          # partition was wrong on the data plane in the same way it was wrong
          # on the pane.
          #
          # `derive-instructions.mjs` refuses the container: a positioned
          # recording spends its `line` field on a source line, so there is no
          # pc column to publish and a listing derived anyway would be Noir line
          # numbers presented as program counters.
          #
          # AND `measuredPostHoc` IS PART OF THE TEST, because two transactions
          # here publish positions and only one of them renders source. Frozen
          # 0x12525d6d… is a rung-3 container whose positions were computed
          # AFTERWARDS by `resolve-frozen-artifacts.mjs`: its `line` field holds
          # real program counters, so it has a listing, and the pane refuses its
          # positions because the capture measured 0 where the derivation says
          # 86 (CHAIN-CAPTURE.md §6.2b). It therefore belongs in the listing
          # population below, and this branch is only for a recording that
          # measured its own positions while it ran.
          if t.positions != nil and not t.positions{"measuredPostHoc"}.getBool:
            ck t.instructions == nil
            ck t.positions{"steps"}.getInt(-1) == t.steps
            ck t.positions{"positioned"}.getInt(0) > 0
            ck t.positions{"positioned"}.getInt(0) < t.steps
            inc positioned
            continue
          ck t.instructions != nil
          ck t.instructions{"steps"}.getInt(-1) == t.steps
          ck t.instructions{"isa"}.getStr("") == "aztec-avm"
          ck t.instructions{"pc"}.len == t.steps
          inc found
    ck found == 26
    # Non-vacuous in the other direction too: the skip above is a real
    # population, not a branch nothing takes.
    ck positioned == 1

  test "MUTATION BITE: publish refuses a listing the position cannot be in":
    # The one guard in `ingest.nim`. `execution.steps` is what the toolbar counts
    # to and the listing's rows ARE those steps, so a listing of a different
    # length puts the marker on the wrong row — and every surface involved goes
    # on reporting success, which is why this is refused at publish time rather
    # than rendered.
    let mutDir = getTempDir() / ("blocktracer-instr-mut-" &
                                 $getCurrentProcessId())
    removeDir(mutDir)
    createDir(mutDir / "ct")
    createDir(mutDir / "instructions")
    let src = captureDirs[0]
    writeFile(mutDir / "snapshot.json", readFile(src / "snapshot.json"))
    for kind, path in walkDir(src / "ct"):
      if kind == pcFile: writeFile(mutDir / "ct" / path.extractFilename,
                                   readFile(path))
    var touched = 0
    for kind, path in walkDir(src / "instructions"):
      if kind != pcFile: continue
      var node = parseJson(readFile(path))
      # one step short, and nothing else changed
      var pcs = newJArray()
      var i = 0
      for v in node["pc"]:
        if i > 0: pcs.add v
        inc i
      node["pc"] = pcs
      node["steps"] = newJInt(node["steps"].getInt - 1)
      writeFile(mutDir / "instructions" / path.extractFilename, $node)
      inc touched
    ck touched > 0                       # the mutation had something to bite

    let outDir = mutDir / "out"
    createDir(outDir)
    var refused = false
    try:
      discard ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: mutDir))
    except ValueError as e:
      refused = e.msg.contains("refusing to publish a listing")
    ck refused

    # …and the CONTROL: the same ingest over the UNMUTATED capture succeeds, so
    # the refusal is the mismatch and not the temporary directory.
    let okDir = mutDir / "ok"
    createDir(okDir)
    var published = false
    try:
      discard ingestSnapshot(IngestConfig(outDir: okDir, snapshotDir: src))
      published = true
    except CatchableError:
      published = false
    ck published
    removeDir(mutDir)

  test "assertion count":
    expectCount(144)

suite "6 — the listing survives hydration, in the artefact a visitor loads":
  asserted = 0
  ## `just export` ships zero JavaScript; `flake.nix`'s `packages.default` ships
  ## the hydration bundle, and the two disagree about this route. A suite that
  ## looked only at the served rows would be grading the artefact the capture
  ## harness photographs rather than the one a visitor loads — which has already
  ## produced two defects in the review record.
  ##
  ## What the bundle re-renders from is the source island, so the island is the
  ## seam this asserts on: `projectEditor` decodes it at the engine's tick and
  ## the renderer draws the result. Driven through the SAME functions the bundle
  ## calls, so it is the shipping path and not a lookalike.

  test "the island carries the WHOLE listing, and so does the served DOM":
    # The served DOM used to hold a WINDOW (`openAtCurrent`), so the first
    # backward step out of it asked for a row the DOM did not have, and this arm
    # asserted `occurrences(body, "class=\"srcline") < s.steps` — "it IS
    # windowed" — as the justification for inlining the island at all.
    #
    # The window is gone and the island is not, because it was never only about
    # the window: hydration re-derives the pane from data on every stop rather
    # than reading rows back out of markup it wrote, which is what keeps ONE
    # producer of the position. So both are asserted whole, against the same
    # recorded step count, and neither number is written here by hand.
    for s in subjects:
      let body = debugBody(s)
      let full = debugSessionFor(root, s.chain, s.tx).editor
      ck full.documents[0].lines.len == s.steps
      ck occurrences(body, "id=\"bt-session-source\"") == 1
      ck occurrences(body, "class=\"srcline") == s.steps
      ck body.contains("\"listingCaption\":\"" & $s.steps & " recorded steps")

  test "a step re-marks the listing at the tick, through the shipping decoder":
    # `projectEditor`'s `savUnverified` branch is
    # `decodeSourceIsland(island, ListingPath, rrTicks)`. That call is made here
    # with the ticks a step would produce, so what is graded is the join the
    # bundle performs — and the reason it joins on the TICK: a program counter
    # repeats the moment the execution loops, which is exactly when the mark
    # must be on the right row.
    for s in subjects:
      let island = encodeSourceIsland(debugSessionFor(root, s.chain, s.tx).editor)
      for tick in [0, s.step, s.steps - 1]:
        let pane = decodeSourceIsland(island, ListingPath, tick)
        ck pane.availability == srcUnverified
        ck pane.documents.len == 1
        ck pane.currentLine == tick
        var marked: seq[int]
        for ln in pane.documents[0].lines:
          if ln.current: marked.add ln.number
        ck marked == @[tick]
        # the caption survives, so a hydrated pane does not lose the one line
        # that says what its columns are
        ck pane.listingCaption.contains("recorded steps")
        # and re-rendering marks exactly one row, as the served page did
        let html = dbgc.renderSource(pane)
        ck occurrences(html, "aria-current=\"true\"") == 1

  test "the engine's LANDING tick marks a row, because row n IS tick n":
    # ONE COORDINATE, END TO END. The engine lands at tick 0 and that is a real
    # position — on the source path it resolves to the program's first line. The
    # listing is numbered in the same coordinate, so the join is the identity and
    # the landing frame marks the first row rather than nothing.
    #
    # Numbering the rows 1..N as "the n-th recorded step" reads more naturally
    # and is the arrangement this arm exists to rule out: the position head
    # states the TICK, so on every hydrated page it would have said "stopped at
    # step 1" beside a highlighted second row.
    for s in subjects:
      let island = encodeSourceIsland(debugSessionFor(root, s.chain, s.tx).editor)
      let landed = decodeSourceIsland(island, ListingPath, 0)
      var marked: seq[int]
      for ln in landed.documents[0].lines:
        if ln.current: marked.add ln.number
      ck marked == @[0]
      ck landed.documents[0].lines[0].number == 0
      # …and the last tick reaches the last row, so the numbering is a range and
      # not a special case at the head.
      let lastTick = decodeSourceIsland(island, ListingPath, s.steps - 1)
      marked = @[]
      for ln in lastTick.documents[0].lines:
        if ln.current: marked.add ln.number
      ck marked == @[s.steps - 1]

  test "MUTATION BITE: the island's row numbers survive the round trip":
    # `decodeSourceIsland` rebuilds documents through `newSourceDocument`, which
    # numbered every row from 1 regardless of what the island said — harmless
    # while every island held whole source files, and a silent one-row shift for
    # a listing that starts at 0. The island has always PUBLISHED `firstLine`;
    # until now the decoder dropped it.
    ck subjects.len > 0
    let s = subjects[0]
    let pane = debugSessionFor(root, s.chain, s.tx).editor
    let island = encodeSourceIsland(pane)
    ck island.contains("\"firstLine\":0")
    let back = decodeSourceIsland(island, ListingPath, 0)
    ck back.documents[0].lines[0].number == pane.documents[0].lines[0].number
    ck back.documents[0].lines[^1].number == pane.documents[0].lines[^1].number
    ck back.documents[0].lines[^1].number == s.steps - 1
    # The mutation: the same island with `firstLine` removed is what the old
    # decoder saw, and it shifts every row by one.
    var stripped = parseJson(island)
    stripped["documents"][0].delete("firstLine")
    let shifted = decodeSourceIsland($stripped, ListingPath, 0)
    ck shifted.documents[0].lines[0].number == 1
    ck shifted.documents[0].lines[0].number !=
       pane.documents[0].lines[0].number

  test "MUTATION BITE: a landing past the end of the recording is corrected":
    # `entryStepWithin` lands a trace shorter than the fixture's step on `steps`
    # itself, which under the session's zero-based numbering is one PAST the end.
    # The listing is the only place that knows how long the recording is, so it
    # is where the landing is resolved — and the session's own coordinate is
    # corrected with it, because a page may not report a position outside its own
    # recording.
    ck subjects.len > 0
    var found = 0
    for s in subjects:
      let session = debugSessionFor(root, s.chain, s.tx)
      ck session.controls.step < s.steps       # never past the end
      ck session.timeCoordinate == session.controls.step
      if session.controls.step == s.steps - 1 and s.steps < 128: inc found
      # …and the row it names exists and is marked.
      var marked: seq[int]
      for ln in session.editor.documents[0].lines:
        if ln.current: marked.add ln.number
      ck marked == @[session.controls.step]
    # The capture HAS a recording short enough for the landing rule to overshoot,
    # so this is not a rule with no subject.
    ck found > 0

  test "MUTATION BITE: a tick outside the recording marks nothing":
    # The join must not wrap, clamp or land on the last row. A hydrated session
    # that reported a tick this listing does not hold has to say so by marking
    # nothing, which is what an unpositioned pane already means everywhere else.
    ck subjects.len > 0
    let s = subjects[0]
    let island = encodeSourceIsland(debugSessionFor(root, s.chain, s.tx).editor)
    let pane = decodeSourceIsland(island, ListingPath, s.steps)
    var marked = 0
    for ln in pane.documents[0].lines:
      if ln.current: inc marked
    ck marked == 0
    # …and the control, one tick lower, does mark.
    let ok = decodeSourceIsland(island, ListingPath, s.steps - 1)
    marked = 0
    for ln in ok.documents[0].lines:
      if ln.current: inc marked
    ck marked == 1

  test "assertion count":
    expectCount(740)
