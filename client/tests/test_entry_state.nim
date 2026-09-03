## **How a session BECOMES positioned** — the state on entry, not the rendering
## of a state handed to us.
##
## Ported in spirit from CodeTracer desktop's `test_column_*_vm.nim` family and
## `test_formatted_view_step_*_vm.nim`: those ask "after an action, where is the
## cursor and what is shown?" and they answer it by driving the session rather
## than by constructing the answer. Nothing about them is GUI code; what does not
## port is the mechanism — desktop drives a real `replay-server` over DAP and
## reads `getCurrentFile` / `getCurrentLine` back, where BlockTracer's static
## route has no process to drive. The invariant survives the difference intact,
## and it is the invariant that is worth having:
##
##   **The pane opens on the document that contains the position, and that
##   document has the position's line in it.**
##
## ## Why this file exists at all
##
## `test_debug_route.nim` has 115 cases over a positioned session and none of
## them could have caught the defect below, because every one of them checks a
## fixture built from `demo_session.FixtureFile` / `FixtureLine` against those
## same two constants. Fixture and assertion share a source, so the suite proves
## that a constant was applied to a fixture derived from the constant. It covers
## RENDERING a positioned session exhaustively and BECOMING one not at all.
##
## So no assertion here may name `src/shield.nr` or `32` as the expected answer.
## Every expectation below is derived from the session under test — the position
## it reports, the documents it holds — and the checks are relations between
## those, which hold for any trace, any bundle and any language.
##
## ## The trap this file is built around
##
## `Testing/Verification-Harness-Traps.md` trap 4: *universal quantification
## over an empty set is a pass*. That is not a hypothetical here, it is the
## defect's second symptom. `source_document.openAtCurrent` used to window the
## ACTIVE document to lines at or after `currentLine - lead`; point `activeIndex`
## at a 12-line `Nargo.toml` while `currentLine` is 32 and the window kept **no
## lines at all**. A pane rendering zero lines satisfies every `for ln in
## doc.lines` assertion ever written about it.
##
## That windower is GONE — the session pane renders every line of every document
## it holds, and `source_document.nim` says why — so the emptying it could
## produce is now structurally impossible rather than guarded against. The trap
## is not: `decodeSourceIsland` and `withPublishedSources` still choose which
## document the pane opens on, and either can still choose one with no lines in
## it. Hence `check doc.lines.len > 0` before any claim about what those lines
## contain, and hence the counts below are asserted as numbers rather than
## walked.

import std/[unittest, os, json, strutils, algorithm]

import ../src/ssr
import ../src/reader
import ../src/debugger/session_view
import ../src/debugger/source_document
import ../src/debugger/source_island
import ../src/debugger/demo_session
# The renderer, because one arm below asserts what the RENDERER is handed rather
# than what the pane holds — the two used to differ by a window, and the arm
# exists to keep them from differing again.
import ../src/components/debugger as dbgc
import blocktracer/demo/generator

proc occurrences(hay, needle: string): int =
  var i = 0
  while true:
    let at = hay.find(needle, i)
    if at < 0: break
    inc result
    i = at + needle.len

# ── a real tree, generated in-process ──────────────────────────────────────

let
  clientRoot = currentSourcePath().parentDir.parentDir
  repoRoot = clientRoot.parentDir
  fixtureDir = repoRoot / "fixtures" / "trace" / "noir_space_ship"
  fixture = fixtureDir / "zk_shields.ct"
  fixtureSources = fixtureDir / "sources"
  workDir = getTempDir() / ("blocktracer-entry-state-" & $getCurrentProcessId())

removeDir(workDir)
createDir(workDir)
doAssert fileExists(fixture),
  "the trace fixture is missing: " & fixture &
  " — with no tree to generate, every loop below would be empty and every " &
  "universal claim in this file would pass vacuously (trap 4)"
discard generate(DemoConfig(outDir: workDir, seed: "entry-state-test",
                            traceFixturePath: fixture,
                            traceSourcesDir: fixtureSources))

let root = newDataRoot(workDir)

# ── the sessions under test, collected once ────────────────────────────────

type Entry = object
  chain, hash: string
  pane: EditorPane          ## as the route hands it to the renderer

proc collectEntries(): seq[Entry] =
  ## Every transaction whose debug route renders a frame, with the pane the
  ## page actually renders. `pages/debug.nim` now hands `s.editor` to the
  ## renderers unchanged — it used to take a window first — so "the pane the
  ## page renders" and "the pane the session holds" are the same object, and
  ## this collection is that fact rather than a copy of it.
  for chain in chains(root):
    let info = chainInfo(root, chain)
    for h in blockHashes(root, info):
      for txh in readBlockDetail(root, info, h).transactions:
        let s = debugSessionFor(root, chain, txh)
        if not s.hasFrame: continue
        result.add Entry(chain: chain, hash: txh, pane: s.editor)

let entries = collectEntries()

# ── helpers that derive the expectation from the session ───────────────────

proc markedCurrent(pane: EditorPane): seq[tuple[path: string, line: int]] =
  ## Every line in the WHOLE pane that claims to be the current one. The
  ## session's own answer to "where am I", read off the data rather than
  ## supplied by the test.
  for d in pane.documents:
    for ln in d.lines:
      if ln.current: result.add (path: d.path, line: ln.number)

proc activePath(pane: EditorPane): string =
  if pane.documents.len == 0: ""
  elif pane.activeIndex >= 0 and pane.activeIndex < pane.documents.len:
    pane.documents[pane.activeIndex].path
  else: ""

# ---------------------------------------------------------------------------

suite "entry state — the session positions itself from its trace":

  test "the fixture set is not empty":
    ## Trap 4, guarded explicitly. Every `for e in entries` case below is a
    ## universal claim; over an empty seq they all pass and report green. The
    ## count is knowable, so it is asserted as a number.
    check entries.len == 6
    var withSource = 0
    for e in entries:
      if e.pane.availability == srcSourceLevel: inc withSource
    check withSource == 6

  test "the pane opens on a document that is not empty":
    ## The `Nargo.toml` symptom, stated as a property. A document selected for
    ## display with zero lines in it is never a correct entry state: there is
    ## nothing on screen, and every assertion about the lines it renders holds
    ## vacuously.
    var checked = 0
    for e in entries:
      if e.pane.availability != srcSourceLevel: continue
      inc checked
      check e.pane.documents.len > 0
      check e.pane.activeIndex >= 0
      check e.pane.activeIndex < e.pane.documents.len
      let doc = e.pane.documents[e.pane.activeIndex]
      check doc.lines.len > 0
    check checked == 6

  test "the active document is the one holding the current line":
    ## The defect the user reported, as a relation. Not "the active document is
    ## `src/shield.nr`" — that is the tautology — but "the active document is
    ## whichever document the session's own position falls in".
    var checked = 0
    for e in entries:
      if e.pane.availability != srcSourceLevel: continue
      inc checked
      let marks = markedCurrent(e.pane)
      # Exactly one line in the pane is current: `focus` clears the flag across
      # every document, and a second mark would mean two files claiming the
      # session at once.
      check marks.len == 1
      check marks[0].path == activePath(e.pane)
      check marks[0].line == e.pane.currentLine
    check checked == 6

  test "the pane the page renders holds the current line, and the whole file":
    ## This used to read "the current line survives the window the page takes",
    ## and it guarded `openAtCurrent` against dropping the very line it existed
    ## to reveal. There is no window to survive: the assertion is now that the
    ## active document runs from its own line 1 to its own last line, with the
    ## position somewhere inside it.
    ##
    ## The line-1 clause is what discriminates. "The current line is present" is
    ## true of a six-line lead-in window too, so on its own it would have passed
    ## against the behaviour this suite is now asserting is gone.
    var checked = 0
    for e in entries:
      if e.pane.availability != srcSourceLevel: continue
      inc checked
      let doc = e.pane.documents[e.pane.activeIndex]
      check doc.lines.len > 0
      var found = 0
      for ln in doc.lines:
        if ln.number == e.pane.currentLine: inc found
      check found == 1
      check doc.lines[0].number == 1
      check doc.lines[^1].number == doc.lines.len
    check checked == 6

# ---------------------------------------------------------------------------
# The unit the route's entry state rests on, driven directly.
#
# The cases above run over the demo tree, where the bundle happens to contain
# the file the fixture constant names — so they pass today. The defect lives one
# level down, on the paths that reach the same code with a position the constant
# does not describe: the LIVE session (`hydrate/session_project.projectEditor` ->
# `decodeSourceIsland`) and any bundle that does not carry `src/shield.nr`.
# ---------------------------------------------------------------------------

proc islandOf(paths: seq[string]; texts: seq[string]): string =
  ## A source island with the documents given, in the SORTED order a published
  ## bundle arrives in (`demo_session.sourceDocumentsFromBundle` sorts by path,
  ## and the generator publishes in `walkDirRec` sorted order). The order is the
  ## point: `Nargo.toml` sorts before `src/`, so index 0 is the manifest.
  var idx: seq[int]
  for i in 0 ..< paths.len: idx.add i
  idx.sort(proc (a, b: int): int = cmp(paths[a], paths[b]))
  var docs = newJArray()
  for i in idx:
    docs.add %*{"path": paths[i], "language": "noir", "text": texts[i],
                "executed": newJArray()}
  $(%*{"availability": "sourceLevel", "activeIndex": 0, "documents": docs})

const
  ManifestText = "[package]\nname = \"zk_shields\"\ntype = \"bin\"\n"   # 3 lines
  ProgramText = (block:
    var s = ""
    for i in 1 .. 40: s.add "let v" & $i & " = " & $i & ";\n"
    s)                                                                  # 40 lines

suite "entry state — a position the fixture constant does not describe":

  test "control: the engine's path matches a document, and the pane opens on it":
    ## The arm that must stay green. Without it, a red result below would not
    ## distinguish "the lookup is broken" from "the test builds a broken island".
    let island = islandOf(@["Nargo.toml", "src/prog.nr"],
                          @[ManifestText, ProgramText])
    let pane = decodeSourceIsland(island, "src/prog.nr", 32)
    check pane.documents.len == 2
    check activePath(pane) == "src/prog.nr"
    check pane.documents[pane.activeIndex].lines.len > 0
    let marks = markedCurrent(pane)
    check marks.len == 1
    check marks[0].path == "src/prog.nr"
    check marks[0].line == 32

  test "a position in a file the bundle does not carry must not open the manifest":
    ## **The defect.** `decodeSourceIsland` guards the case where the engine
    ## reports NO path (`currentPath.len == 0`, falls back to the island's own
    ## `activeIndex`) but not the case where it reports one that matches nothing:
    ## `activeIndex` keeps its initialised 0 while `currentLine` is set to a line
    ## number belonging to a different file. Index 0 after sorting is
    ## `Nargo.toml`.
    ##
    ## A pane may honestly say it cannot show the position. What it may not do is
    ## open an unrelated document and mark a line in it — or, worse, open one and
    ## show nothing at all.
    let island = islandOf(@["Nargo.toml", "src/prog.nr"],
                          @[ManifestText, ProgramText])
    let pane = decodeSourceIsland(island, "src/other.nr", 32)
    # Whatever the pane decides to show, it must not be a document with no lines.
    check pane.documents[pane.activeIndex].lines.len > 0
    # And it must not claim a position that the document it is showing does not
    # have. This is the assertion that separates the two fixes: showing the
    # manifest UNWINDOWED cures the emptiness above while leaving `currentLine`
    # at a line number belonging to a file that is not on screen. A pane
    # reporting "line 32" over a three-line manifest is still lying about where
    # the session is, and the toolbar and the deep link both read that number.
    #
    # Nothing here requires the pane to be positioned — an honest pane may say
    # it has no position. What it may not do is name one it cannot show.
    let doc = pane.documents[pane.activeIndex]
    if pane.currentLine != 0:
      var present = 0
      for ln in doc.lines:
        if ln.number == pane.currentLine: inc present
      check present == 1
    # No document may mark a current line either, for the same reason.
    let marks = markedCurrent(pane)
    check marks.len == 0

  test "a foreign currentLine cannot empty the document the renderer gets":
    ## This used to be "openAtCurrent never hands the renderer an empty
    ## document", and it drove the windower directly: a `currentLine` of 32 over
    ## a three-line manifest put the window's `first` past the last line, and
    ## without its guard the pane rendered nothing at all. A pane rendering zero
    ## lines satisfies every `for ln in doc.lines` assertion ever written about
    ## it (trap 4), which is why the guard needed a test and not a comment.
    ##
    ## The windower is gone, so the emptying is gone with it — and this arm is
    ## kept, aimed one layer out, because the CONDITION it was built from is
    ## still constructible: nothing stops a caller putting a foreign line number
    ## on a pane. What is asserted now is that no stage between the pane and the
    ## renderer reacts to that by dropping rows. It is the regression test for
    ## re-introducing a window, in the shape the old one would have taken.
    var pane = EditorPane(availability: srcSourceLevel, activeIndex: 0,
                          currentLine: 32,
                          documents: @[newSourceDocument(
                            "Nargo.toml", "toml", ManifestText)])
    check pane.documents[0].lines.len == 3      # the subject exists
    check pane.currentLine > pane.documents[0].lines.len   # …and is foreign
    let html = dbgc.renderSource(pane)
    check occurrences(html, "class=\"srcline") == 3
    # …and it says nothing about a reduction, because it made none.
    # The markup, not the retired sentence: "Showing from line" is no longer
    # emitted under any behaviour, so asserting its absence proved nothing.
    check "<div class=\"srcfrom\">" notin html

  test "stepping across files carries the pane with the position":
    ## Ported in spirit from desktop's `test_formatted_view_step_in_vm.nim` /
    ## `_step_out_vm.nim`: step into a callee that lives in another file, and
    ## the editor follows. Desktop drives `replay-server` over DAP and reads
    ## `getCurrentFile`/`getCurrentLine` back; BlockTracer's live path is
    ## `hydrate/session_project.projectEditor`, which resolves the same question
    ## through `decodeSourceIsland(island, position.file, position.line)` on
    ## every stop. The transport differs, the invariant does not.
    ##
    ## Driven as a SEQUENCE rather than as three independent cases, because the
    ## defect this file exists for is a state that survives a transition: the
    ## island is decoded afresh each time, so a pane that fails to re-derive its
    ## document leaves the previous file on screen under the new line number.
    let island = islandOf(@["Nargo.toml", "src/lib.nr", "src/main.nr"],
                          @[ManifestText, ProgramText, ProgramText])
    # main.nr:20 -> lib.nr:31 (a step in) -> main.nr:21 (the step out)
    let walk = @[("src/main.nr", 20), ("src/lib.nr", 31), ("src/main.nr", 21)]
    var seen = 0
    for (path, line) in walk:
      inc seen
      let pane = decodeSourceIsland(island, path, line)
      # The pane is on the file the position names …
      check activePath(pane) == path
      # … it is showing something …
      check pane.documents[pane.activeIndex].lines.len > 0
      # … the position's line is among the lines it holds …
      var present = 0
      for ln in pane.documents[pane.activeIndex].lines:
        if ln.number == line: inc present
      check present == 1
      # … and exactly one line in the WHOLE pane claims to be current, in the
      # file the session is actually in. Two marks would mean the file the
      # session just left is still advertising a position.
      let marks = markedCurrent(pane)
      check marks.len == 1
      check marks[0].path == path
      check marks[0].line == line
    check seen == 3

  test "a bundle without the fixture's file still opens on the position":
    ## The same defect on the STATIC path. `withPublishedSources` sets
    ## `activeIndex = 0` and then restores focus only `if documentIndex(pane,
    ## FixtureFile) >= 0` — so a bundle for any other Noir program leaves the
    ## pane on index 0 with the fixture's line number applied to it.
    # A REAL session out of the tree, so the position is the one the route
    # actually renders rather than one this test chose.
    check entries.len > 0
    var session = debugSessionFor(root, entries[0].chain, entries[0].hash)
    check session.hasFrame
    let before = markedCurrent(session.editor)
    check before.len == 1
    let posPath = before[0].path
    let posLine = before[0].line
    # A bundle carrying the position's own file, plus a manifest that sorts
    # ahead of it — the shape every published Noir bundle has.
    withPublishedSources(session, %*{
      "language": "noir",
      "sources": {
        "Nargo.toml": {"content": ManifestText},
        posPath: {"content": ProgramText}}})
    let pane = session.editor
    check pane.documents.len == 2
    check pane.documents[pane.activeIndex].lines.len > 0
    let marks = markedCurrent(pane)
    check marks.len == 1
    check marks[0].path == posPath
    check marks[0].line == posLine
    check activePath(pane) == posPath

  test "a session positioned in ANOTHER file keeps it when a bundle wins":
    ## The case above cannot distinguish a derived answer from the constant,
    ## because the demo session's position happens to BE
    ## `demo_session.FixtureFile`. So move the session first, to a file that is
    ## demonstrably not that constant, and apply a bundle carrying both.
    ##
    ## A `withPublishedSources` that derives the position from the session keeps
    ## the pane where the session is. One that restores it from a constant drags
    ## the pane back to `src/shield.nr` — a file the session is no longer in.
    check entries.len > 0
    var session = debugSessionFor(root, entries[0].chain, entries[0].hash)
    check session.hasFrame
    let fixturePath = markedCurrent(session.editor)[0].path
    # Pick a document in the pane that is NOT the one it starts on.
    # Prefer another SOURCE file over a manifest, so the scenario is the one a
    # step-into actually produces: the session moves between two `.nr` files of
    # the same program.
    var otherPath = ""
    var otherLine = 0
    let ext = fixturePath[fixturePath.rfind('.') .. ^1]
    for d in session.editor.documents:
      if d.path != fixturePath and d.lines.len >= 13 and d.path.endsWith(ext):
        otherPath = d.path
        otherLine = 13
        break
    check otherPath.len > 0        # trap 4: the move below must be possible
    focus(session.editor, otherPath, otherLine)
    check markedCurrent(session.editor).len == 1
    check markedCurrent(session.editor)[0].path == otherPath

    withPublishedSources(session, %*{
      "language": "noir",
      "sources": {
        "Nargo.toml": {"content": ManifestText},
        fixturePath: {"content": ProgramText},
        otherPath: {"content": ProgramText}}})
    let pane = session.editor
    check pane.documents.len == 3
    check pane.documents[pane.activeIndex].lines.len > 0
    check activePath(pane) == otherPath
    let marks = markedCurrent(pane)
    check marks.len == 1
    check marks[0].path == otherPath
    check marks[0].line == otherLine

suite "entry state — the engine and the bundle name the same file differently":
  ## The half of "becoming positioned" that only the HYDRATED session has, and
  ## that every suite in this tree was structurally unable to see.
  ##
  ## Everything above drives `renderToString` and constructs its position with
  ## paths it also wrote, so both sides of the comparison are this repository's
  ## spelling and they always agree. In a live session they come from two
  ## different producers and they never did:
  ##
  ##   the engine   `/private/tmp/blocktracer-fixture-rec/noir_space_ship/src/main.nr`
  ##   the bundle   `src/main.nr`
  ##
  ## The engine reports the path the program was RECORDED at — absolute, and
  ## belonging to the machine that ran it. The published bundle stores paths
  ## relative to the package root, because that is the only form that survives
  ## being served to someone else. `==` between them was false for every file in
  ## every session, so no hydrated session ever marked a line.
  ##
  ## It hid behind the fix directly above it. That fix made an unmatched
  ## position CLEAR `currentLine` rather than carry it onto the wrong document —
  ## correct, and it turned "marks the wrong line" into "marks no line", which
  ## is also what a bundle that genuinely lacks the file looks like. The safe
  ## fallback masked the broken comparison, and a browser was needed to tell
  ## them apart: `tools/journeys/` journey 06.
  ##
  ## No case below names a repository path as an expected answer. Each states a
  ## RELATION between a document list and a position, and holds for any project
  ## layout.

  const Docs = @["Nargo.toml", "Prover.toml", "src/main.nr", "src/shield.nr"]

  test "the resolver finds the file the engine names, absolutely":
    # The case that was live: an absolute record path against relative bundle
    # paths.
    let i = positionDocumentIndex(Docs, "/tmp/rec/noir_space_ship/src/main.nr")
    check i >= 0
    check Docs[i] == "src/main.nr"

  test "CONTROL: an exact path still resolves, and to the same document":
    # The pairing that makes the case above a measurement rather than a
    # coincidence — same function, same list, the spelling that always worked.
    let exact = positionDocumentIndex(Docs, "src/main.nr")
    let absolute = positionDocumentIndex(Docs, "/anywhere/at/all/src/main.nr")
    check exact >= 0
    check exact == absolute

  test "a suffix that is not a path segment is NOT a match":
    # `domain.nr` ends with the characters of `main.nr`. The boundary has to
    # fall on a separator, or the resolver marks a line in a file the session
    # is not in — the one outcome worse than marking none.
    check positionDocumentIndex(@["main.nr"], "/rec/src/domain.nr") < 0
    check positionDocumentIndex(@["shield.nr"], "/rec/src/myshield.nr") < 0

  test "the MOST SPECIFIC document wins when several could match":
    # A bundle holding both `main.nr` and `src/main.nr` has two documents whose
    # paths are suffixes of `/rec/src/main.nr`. Resolving to the shorter one
    # would open the wrong file while looking entirely successful.
    let ambiguous = @["main.nr", "src/main.nr"]
    let i = positionDocumentIndex(ambiguous, "/rec/src/main.nr")
    check i >= 0
    check ambiguous[i] == "src/main.nr"

  test "a file the bundle does not carry resolves to nothing":
    check positionDocumentIndex(Docs, "/rec/src/absent.nr") < 0
    check positionDocumentIndex(Docs, "") < 0
    check positionDocumentIndex(@[], "/rec/src/main.nr") < 0

  test "separators are normalised, and only for comparison":
    # A recording made on Windows names its files with `\`. The document's own
    # path is untouched — this is a comparison rule, not a rewrite.
    let i = positionDocumentIndex(Docs, "C:\\rec\\noir_space_ship\\src\\main.nr")
    check i >= 0
    check Docs[i] == "src/main.nr"

  test "the decoded pane marks the position, and marks it once":
    # End to end through the real decoder, with the two spellings that differ.
    var docs = newJArray()
    for p in Docs:
      docs.add %*{"path": p, "language": "noir",
                  "text": "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\nm\n"}
    let island = $(%*{"availability": "sourceLevel", "documents": docs,
                      "activeIndex": 0})

    let pane = decodeSourceIsland(island, "/rec/noir_space_ship/src/main.nr", 4)
    let marks = markedCurrent(pane)
    check marks.len == 1
    check marks[0].line == 4
    # The pane opens on the document the mark is in — asserted as a relation
    # between the pane's own two answers, never against a constant.
    check activePath(pane) == marks[0].path

  test "MUTATION BITE: exact-equality resolution marks nothing at all":
    # The pre-fix comparison, written out. If this ever passes, the resolver has
    # been narrowed back to `==` and journey 06 is the only thing left standing
    # between that and a visitor.
    var matched = 0
    for p in Docs:
      if p == "/rec/noir_space_ship/src/main.nr": inc matched
    check matched == 0                      # the old rule found nothing, and
    check positionDocumentIndex(Docs, "/rec/noir_space_ship/src/main.nr") >= 0
                                            # the new one finds the file

removeDir(workDir)
