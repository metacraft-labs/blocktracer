// selftest.mjs — proof that the journeys BITE.
//
//   node tools/journeys/selftest.mjs
//   just journeys-selftest
//
// A journey that cannot fail is not a test, and this repository already knows
// it: every `ci/test/<subject>.sh` here has a `<subject>-test.sh` beside it that
// plants deliberate violations in real source and proves the check reports them.
// `tools/design/check-tokens-selftest.mjs` does the same, "by planting each
// violation in the real source and restoring it byte-identically". This is that
// file for the journey layer.
//
// HOW AN ARM WORKS
// ----------------
// One arm = one MUTATION in real product source, chosen to break exactly one
// spec claim, plus the NAME of the assertion that must go red. The arm:
//
//   1. records the assertion's verdict on the unmutated tree (it must be GREEN
//      — a mutation that "reddens" something already red proves nothing);
//   2. applies the mutation and rebuilds the exporter;
//   3. reruns that journey alone and demands the NAMED assertion is now RED;
//   4. restores the file byte-for-byte and rebuilds, and demands the assertion
//      is GREEN again.
//
// Step 4 is not tidiness. Without it a mutation that failed to apply, or a
// rebuild that silently reused a stale `dist/`, is indistinguishable from a
// mutation that was killed.
//
// THREE VERDICTS, NEVER TWO
// -------------------------
// Verification-Harness-Traps.md §1a: "A mutation harness needs three verdicts,
// not two. Killed, survived, and NEVER RAN — and the third is the one a
// rc-based harness silently folds into the first." A mutation that does not
// compile has demonstrated nothing about the journey, and is reported as
// DID-NOT-BUILD rather than as a kill. So the verdict is taken from the parsed
// per-assertion records, never from an exit code: `node run.mjs` exits non-zero
// for a red journey, for a browser that would not start and for a syntax error
// in this file, all the same number.
//
// DO NOT COLLAPSE THIS TO TWO. It has already caught the thing it exists for,
// and the case is worth keeping because it is invisible from every other angle.
// `Z3/the-document-is-re-windowed-under-the-position` stopped compiling the day
// a sibling change gave `renderPanes` its own `var view = view` — the mutation
// supplied a second one — and it reported:
//
//     before:  GREEN
//     NEVER RAN — the mutated tree did not compile, so nothing was measured
//                 hydrate.nim(594, 7) Error: redefinition of 'view'
//
// Z3 is the sole arm behind journey 13's "the position moves DOWN the box while
// the pane holds still", which is the one assertion that catches a pane
// re-windowed UNDER the position — a defect `scrollTop` cannot see, because the
// content moves and the viewport does not. So for as long as those two changes
// coexisted, that assertion had no mutation proving it bites: an untested test
// wearing the appearance of a tested one, on the branch that had just been
// merged. Folded into "killed", it would have read as a pass and stayed one.
//
// THE ASSERTION IS NAMED, NOT COUNTED
// -----------------------------------
// An arm passes only if the assertion WRITTEN FOR IT flipped. "The journey went
// red" is satisfied by a mutation that broke some other assertion — a mutation
// that removes the source pane reddens the position check too, and would score
// a kill it did not earn.
//
// EVERY VERDICT NAMES THE ARTEFACT IT WAS TAKEN ON
// ------------------------------------------------
// See `artefactIdentity`. A verdict printed without the identity of the thing it
// was measured on is unfalsifiable, and this file spent a run reporting confident
// verdicts about a bundle nobody had built.
//
// TWO TRAPS, RECORDED SO THE NEXT PERSON DOES NOT LOSE AN HOUR
// -----------------------------------------------------------
// 1. A FRESH WORKTREE BUILDS NOTHING UNTIL `direnv allow` HAS BEEN RUN. The
//    toolchain comes from the flake devShell via `.envrc`, and an unallowed
//    `.envrc` fails by producing an environment without `nim` in it — which
//    surfaces much further downstream than it happens.
//
// 2. GREPPING THE HYDRATION BUNDLE FOR A STRING LITERAL FINDS NOTHING, and that
//    is NOT evidence the string is absent. `nim js` emits Nim string literals as
//    CHAR-CODE ARRAYS, so "Trace to origin" is in the bundle as
//    `[84,114,97,99,101,32,116,111,32,111,114,105,103,105,110]` and matches no
//    text search for itself. Encode the string before searching, or check the
//    behaviour in a browser instead — which is what the journeys are for.

import { readFile, writeFile, readdir } from "node:fs/promises";
import { writeFileSync, readFileSync, writeSync } from "node:fs";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const run = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");
const CLIENT = join(REPO, "client");
const REPORT = join(HERE, ".selftest-report.json");
const JOURNAL = join(HERE, ".selftest-journal.json");

/**
 * The arms.
 *
 * `find` must occur EXACTLY ONCE in the file — asserted before the edit. A
 * mutation applied twice, or to a line that moved, is a different experiment
 * from the one described here, and a `replaceAll` would hide that.
 */
const ARMS = [
  {
    id: "Z/link-to-a-line-that-is-not-there",
    why:
      "Stop `windowAround` re-aiming the flow rail's link after it narrows the pane." +
      " This is the defect exactly as it shipped and exactly as it was reported —" +
      " 'there is a link line 4 that does nothing when clicked'. The rail's href is" +
      " built against the WHOLE document, the home page's embed is then narrowed to" +
      " lines 20..44 around the position, and without this line the href still reads" +
      " `#L-src-shield-nr-4` over a document whose ids start at 20. One anchor," +
      " twenty-five ids, no overlap: the browser has nothing to scroll to." +
      " The arm is aimed at the SCROLL assertion rather than at the href, because a" +
      " check that the anchor's target exists in the DOM passes on a target that" +
      " sits in a container fragment navigation cannot move.",
    file: join(CLIENT, "src", "debugger", "source_document.nim"),
    find: `          fullDocumentUrl & "#" & lineAnchor(doc.path, result.flow.line)`,
    replace: `          result.flow.href`,
    journey: "a-link-to-a-line-arrives-at-that-line",
    assertion: "and it is inside the viewport — the click arrived somewhere a reader can see",
  },
  {
    id: "A/no-position-mark",
    why:
      "Remove the class that marks the execution position. This is the shape of the" +
      " defect a user reported as 'no current-line indicator': the listing renders," +
      " the session knows where it is, and nothing on screen says so.",
    file: join(CLIENT, "src", "components", "debugger.nim"),
    find: `(if ln.current: " cur" else: "") &`,
    replace: `(if false: " cur" else: "") &`,
    journey: "served-frame-marks-the-position",
    assertion: "SERVED: exactly one line carries the position mark",
  },
  {
    id: "B/opens-on-the-manifest",
    why:
      "Force the source pane onto the first document instead of the one the session" +
      " is positioned in. This is the mechanism of the `Nargo.toml` defect, stated in" +
      " the fix's own comment: 'left activeIndex at 0 — which after the sort is" +
      " whatever path sorts first, typically Nargo.toml — while currentLine kept a" +
      " line number belonging to a different file.' 115 debug-route cases could not" +
      " see it because their fixture supplied the position they then asserted back.",
    file: join(CLIENT, "src", "debugger", "demo_session.nim"),
    find: `    focus(pane, posPath, posLine)`,
    replace: `    focus(pane, docs[0].path, posLine)`,
    journey: "served-frame-marks-the-position",
    assertion: "SERVED: the file on screen is the file the position is in",
  },
  {
    id: "E/the-position-path-never-matches",
    why:
      "Narrow the position resolver back to exact string equality. The engine" +
      " names the file it RECORDED at ('/…/noir_space_ship/src/main.nr') and the" +
      " bundle names it relative to the package root ('src/main.nr'), so `==` is" +
      " false for every file in every session and no hydrated session marks a" +
      " line. This shipped, and it hid behind the Nargo.toml fix: an unmatched" +
      " position clears currentLine, so the pane marked none instead of marking" +
      " the wrong one — indistinguishable from a bundle that lacks the file.",
    file: join(CLIENT, "src", "debugger", "source_island.nim"),
    find: `  let positionIndex = positionDocumentIndex(paths, currentPath)`,
    replace: `  var positionIndex = -1
  for pi, pp in paths:
    if pp == currentPath: positionIndex = pi`,
    journey: "position-survives-hydration",
    assertion: "HYDRATED: exactly one line carries the position mark",
  },
  {
    id: "F/data-step-goes-stale",
    why:
      "Stop writing the session's step back to the root. `data-step` was READ" +
      " once out of the served DOM and never written again, so it reported the" +
      " landing step for the rest of the session however far the session moved." +
      " Note which assertion this arm targets: the URL still advances with every" +
      " step, so a check written against `location.search` stays green. The" +
      " verdict has to come from what the page RENDERS.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `  ui.root.setAttribute("data-step", ($view.controls.step).cstring)`,
    replace: `  discard ($view.controls.step)`,
    journey: "stepping-moves-the-position",
    assertion: "the session's reported step advanced",
  },
  {
    id: "J/the-locals-reply-is-discarded-again",
    why:
      "Throw the ct/load-locals reply away, which is what the pinned Embed SDK's" +
      " own `requestLocals` does: it sends the request and drops the response" +
      " through a private `onComplete` wrapper written to discard the result" +
      " value. That is the defect journey 11 exists for, and it is the one shape" +
      " of it a row count cannot see — the pane keeps saying something, every" +
      " step keeps moving the position, and the values never change.",
    file: join(CLIENT, "hydrate", "live_locals.nim"),
    find: `feed.store.updateLocals(variablesOf(body))`,
    replace: `feed.store.updateLocals(variablesOf(newJObject()))`,
    journey: "a-stepped-session-shows-the-values-it-is-at",
    assertion: "the values the pane shows change as the session moves",
  },
  {
    id: "K/the-served-values-stand",
    why:
      "Narrow the State pane's latch back to `values.len > 0`, so a pane with a" +
      " sentence and no values is not 'content' and never replaces the served" +
      " one. This is the mechanism by which the defect was INVISIBLE rather than" +
      " the defect itself: the exporter's ten fixture rows stayed on screen under" +
      " whatever position the visitor stepped to, and journey 07's original" +
      " non-vacuity control was satisfied by exactly those rows. Note which" +
      " assertion this targets — the pane is full, it is just full of another" +
      " frame, so every count of it stays green.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `            view.state.values.len > 0 or view.state.note.len > 0, latch.state)`,
    replace: `            view.state.values.len > 0, latch.state)`,
    journey: "a-stepped-session-shows-the-values-it-is-at",
    assertion: "no reading of the Values pane is the SERVED frame's values",
  },
  {
    id: "L/the-value-kind-is-misread",
    why:
      "Render one wire kind as the empty string. The engine's `Value` is a flat" +
      " tagged record whose `kind` is a NUMERIC ordinal, and getting one wrong" +
      " produces rows with names, types and no values — which every count of the" +
      " pane survives. This is a mistake with a precedent in the tree rather than" +
      " a hypothetical: the pinned SDK's `headless_session.nim` lists the ordinals" +
      " in a comment and six of the ten are wrong, so a parser written by copying" +
      " it renders every string, bool, char, array and tuple exactly this way.",
    file: join(CLIENT, "hydrate", "live_locals.nim"),
    find: `  of tkInt: node{"i"}.getStr("")`,
    replace: `  of tkInt: ""`,
    journey: "a-stepped-session-shows-the-values-it-is-at",
    assertion: "every row the pane draws carries both a name and a value",
  },
  {
    id: "C/phase-renamed",
    why:
      "Rename a SessionPhase's published string. §7.0's table is a claim about" +
      " availability, and the page publishes a phase; the mapping between them is" +
      " the one place the two vocabularies meet. A renamed phase must fail there, by" +
      " name, rather than quietly reclassifying 48 of 62 pages into no row at all.",
    file: join(CLIENT, "src", "debugger", "session_view.nim"),
    find: `    spUnavailable = "unavailable"`,
    replace: `    spUnavailable = "no-trace-possible"`,
    journey: "availability-decides-the-landing",
    assertion: "every transaction's phase is one §7.0 names",
  },
  {
    id: "D/a-link-to-the-primary-action",
    why:
      "Label a control on the session page 'Debug'. Page-Descriptions.md §7.0 names" +
      " this exact regression as rule 1's anti-goal — 'a button that opens the" +
      " debugger is a link to the primary action, not the primary action' — and" +
      " records that it 'survived a review with this section open'.",
    file: join(CLIENT, "src", "pages", "debug.nim"),
    find: `        text "← " & s.chain`,
    replace: `        text "Debug"`,
    journey: "tx-page-is-the-session",
    assertion: "no page offers to open a debugger",
  },
  {
    id: "G/the-seek-lands-somewhere-else",
    why:
      "Seek one tick past the row the visitor clicked. This arm exists to prove the" +
      " jump journey asserts the DESTINATION and not merely motion: with it in place" +
      " both CONTROLS stay green (the click still reaches the engine and `?t=` still" +
      " advances), the mark still moves, and the pane still shows a line — every" +
      " symptom of a working jump — while the session is at a step nobody asked for." +
      " A journey that had written `after.step !== before.step` would score this as a" +
      " pass, which is why the assertion is an equality against the step the row" +
      " names in its own markup.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `      try: h.gotoTicks(parseInt(step)) except CatchableError: discard)`,
    replace: `      try: h.gotoTicks(parseInt(step) + 1) except CatchableError: discard)`,
    journey: "a-jump-moves-the-position",
    assertion: "the session's reported step is the step the call-trace row named",
  },
  {
    id: "H/the-event-log-rows-are-not-bound",
    why:
      "Stop binding the event log's rows, leaving the call trace's binding alone." +
      " The two navigation regions are separate `rowHandler` calls over separate" +
      " pane bodies, so one can go dead while the other keeps working — and the" +
      " event log is the region a visitor cannot even see until its tab is chosen," +
      " which is how it came to be the region no assertion had ever reached. This is" +
      " the README's `currentEntryRequest()` shape: the machinery present, the" +
      " gesture wired to nothing, every component contract still green. The arm is" +
      " surgical on purpose — the six call-trace assertions must stay green, or it" +
      " would be proving something weaker than it claims.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `  rowHandler(h.ui.eventLog, ".evrow")`,
    replace: `  discard h.ui.eventLog`,
    journey: "a-jump-moves-the-position",
    // REPOINTED, AND THE OLD TARGET IS THE FINDING. This arm named "the
    // session's reported step is the step the event-log row named" and SURVIVED
    // it in three independent runs, because that assertion — and every other
    // reading in that block — is taken AFTER the gesture settles, and an
    // unbound row settles in exactly the right place: the browser follows the
    // anchor's href, tears the document down, and a new session opens at the
    // named step. Right step, right mark, right `?t=`, 18 MB of engine
    // refetched to move one frame.
    //
    // The assertion that bites is the one that reads DURING: a token stamped on
    // `window` before the click survives a seek and cannot survive a
    // navigation. The old assertion is kept and still made — it is a true claim
    // about where the session ends up — it simply never was this arm's.
    assertion: "the event-log jump SEEKS the open session and does not reload the page",
  },
  {
    id: "M/the-calltrace-reply-is-discarded-again",
    why:
      "Drop the `ct/updated-calltrace` payload on the floor, which is exactly what" +
      " the pinned store does with it: `requestCalltraceSection`'s `onComplete` takes" +
      " no response argument and only sets `loadingState` idle, and" +
      " `updateCalltraceSection` had no caller in this repository outside" +
      " `tests/tdebugpanes.nim`. That is the defect this module was written for, and" +
      " it was INVISIBLE for the life of both panes because the static export ships" +
      " fixture rows for the demo chain — `ctrow` read 12 before a step and 12 after," +
      " on a session whose engine had just answered. The arm restores the defect on" +
      " the one surface the fixture cannot cover: a rung-3 capture, whose export" +
      " ships no navigation rows at all, so every row on screen came from the engine" +
      " or from nowhere.",
    file: join(CLIENT, "hydrate", "live_navigation.nim"),
    find: `  feed.store.updateCalltraceSection(`,
    replace: `  if false: feed.store.updateCalltraceSection(`,
    journey: "a-jump-moves-the-position",
    assertion: "REAL: the navigation regions have rows on screen to click",
  },
  {
    id: "N/the-position-is-compared-by-number-alone",
    why:
      "Compare the marked LINE NUMBER instead of the marked position. The demo" +
      " session's first row naming a step it is not on is `iterate_asteroids` at step" +
      " 9, and jumping there moves the mark from `main.nr:1` to `shield.nr:1` — the" +
      " number is 1 both times and the FILE is not. This arm proves the comparison is" +
      " a relation rather than an integer: with it in place a working jump reads as a" +
      " mark that never moved, which is the direction that gets a gate switched off." +
      " It went in the day the live call trace landed, because that is the day the" +
      " demo arm's target stopped being a row in the same file.",
    file: join(REPO, "tools", "journeys", "journeys",
               "09-a-jump-moves-the-position.journey.mjs"),
    find: `  (after.markedNumber !== before.markedNumber || after.markedDoc !== before.markedDoc);`,
    replace: `  after.markedNumber !== before.markedNumber;`,
    journey: "a-jump-moves-the-position",
    assertion: "the marked position moved to the row's step",
  },
  {
    id: "O/the-export-answers-for-the-live-path",
    why:
      "Ignore BOTH navigation events, so the panes fall back to whatever the static" +
      " export drew. On the demo chain that is 12 call-trace rows and 8 event rows —" +
      " a full, plausible, clickable pane that no engine reply touched. This is the" +
      " precise state the product shipped in, and the reason it survived every" +
      " assertion in this file: the fixture was standing in for a dead live path and" +
      " nothing compared the two. The arm's target is the control that now does — a" +
      " hydrated row count equal to the served one is the signature, and it is the" +
      " thing a reader would never notice by looking at the pane.",
    file: join(CLIENT, "hydrate", "live_navigation.nim"),
    find: `  if feed == nil or event == nil or event.kind != JObject: return`,
    replace: `  if true: return`,
    journey: "a-jump-moves-the-position",
    assertion: "CONTROL: the navigation rows are the engine's, not the export's",
  },
  {
    id: "I/the-list-goes-silent-about-source",
    why:
      "Gate the source badge out of the shared transactions table. Every row still" +
      " renders, the Debug action still resolves, the transaction page still states" +
      " the fact, and the table is once again unable to tell a session that steps" +
      " through Noir from one that steps through opcodes. This is `debugCell`'s own" +
      " recorded defect in this feature's shape — the cell compiled, ran, and" +
      " emitted nothing — and it is the reason the assertion compares the row to" +
      " the PUBLISHED FACTS rather than to whatever the row happens to say.",
    file: join(CLIENT, "src", "components", "tables.nim"),
    find: `                  if sourcesStated(t.sources.state):`,
    replace: `                  if false and sourcesStated(t.sources.state):`,
    journey: "a-transaction-list-says-what-can-be-debugged",
    assertion: "every row states the state its recording carries",
  },
  {
    id: "J/the-page-drops-what-the-list-promised",
    why:
      "Stop producing the `Sources` metadata row, leaving the list badge alone. The" +
      " list goes on offering the state and the surface a visitor ACTS on stops" +
      " mentioning it — §7.1's 'rendered in two places … from one source, and the" +
      " two cannot be allowed to diverge', diverging. Surgical on purpose: every" +
      " list assertion must stay green or the arm would be proving something" +
      " weaker than it claims.",
    file: join(CLIENT, "src", "viewutil.nim"),
    find: `  if sourcesStated(v.sources.state):`,
    replace: `  if false and sourcesStated(v.sources.state):`,
    journey: "a-transaction-list-says-what-can-be-debugged",
    assertion: "the transaction's own page states what its list row did",
  },
  {
    id: "P/the-recordings-ending-never-leaves-the-manifest",
    why:
      "Withhold the manifest's `ending` from the one place that has both the" +
      " transaction's facts and its trace manifest in hand. `ExecutionSummary" +
      ".ending` is still published, still decoded, still on the `TraceView` — it" +
      " simply stops being passed to the row producer, so every debug page falls" +
      " back to stating nothing about where its recording stops. That is the exact" +
      " shape of the defect this journey was written for, and it is the shape a" +
      " regression would take: the fact reaches the consumer and the consumer drops" +
      " it on the floor one call short of the screen. Aimed at the wiring rather" +
      " than at the two strings, because a value spelled twice in one function is" +
      " a typo and a value that never arrives is the failure that shipped.",
    file: join(CLIENT, "src", "ssr.nim"),
    find: `    ending = t.ending)`,
    replace: `    ending = eeUnstated)`,
    journey: "a-failed-execution-is-tellable-from-a-completed-one",
    assertion: "the two are tellable apart by what the page says about the execution",
  },
  {
    id: "O1/the-engine-never-gets-the-source",
    why:
      "Stop writing the recording's own source into the engine's VFS. This is the" +
      " state every session was in before today: `ct/originChain` still answers" +
      " `success: true` for every value, still returns one hop each, and every hop" +
      " says kind `unknown`, confidence 0, 'built-in: source unavailable'. The arm" +
      " exists because that is a CHAIN OF SUCCESSFUL CALLS carrying no information," +
      " and an assertion that counted replies rather than classifications would not" +
      " move.",
    file: join(CLIENT, "hydrate", "live_source.nim"),
    find: `  let files = sourceFilesOf(island)`,
    replace: `  let files: seq[SourceFile] = @[]`,
    journey: "a-value-can-be-traced-to-its-origin",
    assertion: "a value's origin is actually CLASSIFIED, not merely answered",
  },
  {
    id: "O2/a-control-on-every-row",
    why:
      "Offer the origin control wherever a summary arrived, instead of wherever the" +
      " summary says something. A summary is present on essentially every local (6" +
      " of 6, measured), so this is the exact shape NR-05 calls 'a confident-looking" +
      " affordance that resolves nothing … worse than the absence': the control" +
      " appears on every row of every session, including recordings that published" +
      " no source, and answers 'unknown' on all of them. It is aimed at the" +
      " source-less arm because that is where the mistake is unambiguous — there," +
      " no control can possibly answer.",
    file: join(CLIENT, "hydrate", "live_origin.nim"),
    // ALL THREE GUARDS, and a non-empty fallback. Dropping only the
    // `unknownSource` test does NOT reproduce the defect — the confidence
    // guard still suppresses the control and `terminatorExpr` is empty on an
    // unattributed summary, so the surface is unchanged and the arm SURVIVES.
    // That happened, and it is what this harness is for: a mutation has to
    // change the behaviour, not merely the source.
    find: `  if summary.isPlaceholder: return ""
  if summary.terminatorKind == tkwUnknownSource: return ""
  if summary.confidence <= 0.0: return ""
  summary.terminatorExpr`,
    replace: `  if summary.isPlaceholder: return ""
  if summary.terminatorExpr.len > 0: return summary.terminatorExpr
  "unknown"`,
    journey: "a-value-can-be-traced-to-its-origin",
    assertion: "NO-SOURCE: and it offers no origin control, because none could answer",
  },
  {
    id: "Q1/the-lead-in-window-comes-back",
    why:
      "Re-introduce the six-line lead-in the Code pane used to take, in the" +
      " renderer this time. This IS the reported defect: on `loops and iteration`" +
      " the pane showed thirteen lines of an 83-line file under a banner reading" +
      " 'Showing from line 71'. It is aimed at the COUNT and not at the banner," +
      " because the banner is the false pass this journey is built to exclude — a" +
      " file shorter than the lead-in carries no banner either, so only an" +
      " equality against the file's own published length can tell 'the whole file'" +
      " from 'some of it'.",
    file: join(CLIENT, "src", "components", "debugger.nim"),
    find: `    let first = (if d.lines.len > 0: d.lines[0].number else: 1)`,
    replace: `    var d = d
    if p.currentLine > 7:
      var keep: seq[SourceLine]
      for ln in d.lines:
        if ln.number >= p.currentLine - 6: keep.add ln
      if keep.len > 0: d.lines = keep
    let first = (if d.lines.len > 0: d.lines[0].number else: 1)`,
    journey: "a-source-file-is-shown-whole",
    assertion: "every Code pane holds one row per line of the file its page publishes",
  },
  {
    id: "Q2/a-reduction-announced-that-nobody-made",
    why:
      "Emit the `Showing from line N` notice unconditionally, WITHOUT dropping a" +
      " single row. The pane then renders the whole file and tells the reader it" +
      " is a window onto it — an announcement of a reduction that was not made," +
      " which §13 rules out in the same breath as a silent one. The arm is the" +
      " orthogonal half of Q1 and is surgical on purpose: every count in the" +
      " journey must stay green, or it would be proving the banner assertion with" +
      " a mutation that had already broken the file.",
    file: join(CLIENT, "src", "components", "debugger.nim"),
    find: `        if first > 1:`,
    replace: `        if first >= 1:`,
    journey: "a-source-file-is-shown-whole",
    assertion: "no Code pane announces a window onto the file",
  },
  {
    id: "Q3/the-files-last-line-is-dropped",
    why:
      "Drop the last line of every file at the splitter: `setLen(len - 1)` becomes" +
      " `setLen(len - 2)`, so the trailing-newline guard eats a real line along" +
      " with the phantom one. That off-by-one is the most ordinary way a" +
      " whole-file pane stops being one, and it is invisible to a reader who never" +
      " scrolls — the pane opens on the position, the position is marked, and the" +
      " file simply ends one line early. It reaches the RENDERED rows and not the" +
      " island (`#bt-session-source` carries the file's TEXT, which this does not" +
      " touch), so what the page publishes and what the page paints disagree by" +
      " exactly one line, which is the comparison this journey makes." +
      " NOT SURGICAL, deliberately: a lost line also reddens the count and the" +
      " unbroken-range assertions, which is honest, because a product that lost" +
      " its last line HAS lost a line. The claim is only that the assertion NAMED" +
      " here flips; the surgical arm of the set is Q2." +
      " THE OBVIOUS ARM DOES NOT WORK, and that is worth recording: setting" +
      " `.src` to `overflow:hidden` was tried first and SURVIVED, because an" +
      " `overflow:hidden` box is still scrollable PROGRAMMATICALLY — `scrollTop`" +
      " moves it and only the reader cannot. A probe that drives the container" +
      " reports such a pane as reachable, and it is not.",
    file: join(CLIENT, "src", "debugger", "source_document.nim"),
    find: `    result.setLen(result.len - 1)`,
    replace: `    result.setLen(result.len - 2)`,
    journey: "a-source-file-is-shown-whole",
    assertion: "scrolling a Code pane to its end paints the file's last line",
  },
  {
    id: "FL1/the-pane-is-rebuilt-with-what-it-already-says",
    why:
      "Remove the content guard from `writePane`, restoring the state a visitor" +
      " reported as flicker. Every event that could change a pane rewrites all four" +
      " of them, so one forward step becomes 28 `innerHTML` assignments of which 21" +
      " are byte-identical — the Call Trace's 24 KB and the Event Log's 7.5 KB torn" +
      " down and rebuilt seven times each to say what they already said. NOTE WHICH" +
      " ASSERTION THIS TARGETS. The pane shows the right rows before and after, the" +
      " position moves, the values are the engine's: every reading taken AFTER a" +
      " step is green, which is why this survived journeys 03, 09 and 11 for the" +
      " life of the route. Only a reading taken during the step can see it.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `  if pane.latched and html == pane.written: return`,
    replace: `  if false and pane.latched and html == pane.written: return`,
    journey: "a-step-repaints-only-what-it-changed",
    assertion: "no pane write rewrote the markup the pane already held",
  },
  {
    id: "FL2/the-panes-move-before-the-values-arrive",
    why:
      "Paint each stop as soon as it is known instead of when the move has settled." +
      " `applyStop` has the position about 13 ms before the engine answers with its" +
      " values, and a frame is 16.7 ms, so the page paints one frame in which it" +
      " contradicts itself: the new line marked, the new step on the toolbar, and" +
      " the Values pane empty because there is nothing in it yet. Measured on the" +
      " unmutated tree, a six-step walk paints that frame six or seven times. It is" +
      " the flicker the visitor actually reported, and it is invisible to every" +
      " reading this suite could take before per-frame sampling existed — the" +
      " content guard alone does NOT fix it, which is why the two are separate arms.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `    if h.session.locals.settlingPosition() and`,
    replace: `    if false and h.session.locals.settlingPosition() and`,
    journey: "a-step-repaints-only-what-it-changed",
    assertion: "no painted frame showed an empty Values pane at a position that has values",
  },
  {
    id: "VD1/the-mark-follows-the-selection-again",
    why:
      "Restore `changed: vm.selectedPath.val == v.name` — the projection that" +
      " shipped. It is a different fact wearing this one's name: the pane's only" +
      " colour said 'selected' while its stylesheet said 'changed'. The arm is the" +
      " reason the verdict is an equality of sets rather than 'a highlight class is" +
      " present', because with this in place a class IS present, on a row, on every" +
      " position — and it is on the wrong row.",
    file: join(CLIENT, "hydrate", "session_project.nim"),
    find: `      changed: diff == dvChanged,`,
    replace: `      changed: vm.selectedPath.val == v.name,`,
    journey: "a-motion-says-which-values-it-changed",
    // AIMED AT THE CHAIN ARM, and that is a finding rather than a preference.
    // The source-level walk changes no value in place — every mark it produces
    // is a name arriving — so the identical SOURCE-LEVEL assertion quantifies
    // over an empty set and this mutation SURVIVED it. It did so correctly, and
    // the journey now prints the size of the set each arm judged so the zero is
    // legible. A rung-3 capture reports the machine's own state, whose rows
    // persist and change a few at a time, so it is the arm where "a changed
    // value must be marked" has subjects.
    assertion: "CHAIN: every row whose value differs from the previous position carries a mark",
  },
  {
    id: "VD2/every-value-is-marked-changed",
    why:
      "Mark every value that was in scope at the previous position, whether or not" +
      " it changed. A blanket highlight passes 'the highlight is present', passes" +
      " 'a marked row is on screen', and passes any step on which everything" +
      " happened to change — which is why the verdict is taken on a MIXED step and" +
      " compares two sets. This arm is that argument made falsifiable.",
    file: join(CLIENT, "hydrate", "live_locals.nim"),
    find: `      return if prior.value == value: dvUnchanged else: dvChanged`,
    replace: `      return dvChanged`,
    journey: "a-motion-says-which-values-it-changed",
    assertion: "on every mixed step the marks are on exactly the values that changed",
  },
  {
    id: "VD3/an-arrival-reads-as-a-change",
    why:
      "Collapse 'this name was not in scope where you came from' into 'this value" +
      " changed'. Both are true statements about a motion and they are not the same" +
      " statement: a reader told a value CHANGED goes looking for what it changed" +
      " from, and on a step into a call there is nothing to find. The arm is" +
      " surgical — every changed/unchanged assertion stays green, because the only" +
      " rows it misdescribes are the ones that arrived.",
    file: join(CLIENT, "hydrate", "live_locals.nim"),
    find: `  dvAppeared

proc noteFor*`,
    replace: `  dvChanged

proc noteFor*`,
    journey: "a-motion-says-which-values-it-changed",
    assertion: "a name that was not in scope at the previous position is marked as arriving, not as changed",
  },
  {
    id: "O3/an-unexplained-absence",
    why:
      "Drop the sentence that says why a value in a source-less recording cannot be" +
      " traced. The pane then shows values, offers no origin control, and explains" +
      " nothing — which is correct behaviour and an unreadable surface at the same" +
      " time, and is indistinguishable from the feature having silently broken. The" +
      " arm guards the half of this journey that is about what the product SAYS" +
      " rather than what it offers.",
    file: join(CLIENT, "hydrate", "session_project.nim"),
    find: `    result.originNote = NoSourceOriginNote`,
    replace: `    result.originNote = ""`,
    journey: "a-value-can-be-traced-to-its-origin",
    assertion: "NO-SOURCE: the pane says why a value here cannot be traced",
  },
  {
    id: "Z/the-plus-comes-back",
    why:
      "Put the reported defect back exactly as it was. `.ctname` and `.evlabel` carry" +
      " `.copyable`, so restoring `cursor:copy` on a copyable inside a clickable row" +
      " returns the plus to the widest cell of every navigable row — which is the" +
      " part of the row a pointer actually rests on, and is what the visitor saw. The" +
      " row's own `a.ctrow{cursor:pointer}` is untouched by this arm, which is the" +
      " point: the rule that looks correct in the stylesheet stays correct, and the" +
      " surface still lies.",
    file: join(CLIENT, "src", "components", "debugger_css.nim"),
    find: `a .copyable,button .copyable{cursor:pointer}`,
    replace: `a .copyable,button .copyable{cursor:copy}`,
    journey: "a-clickable-surface-shows-the-hand",
    assertion:
      "copyable value cells sitting inside a navigable row — each computes `pointer`",
  },
  {
    id: "Q/the-copy-control-loses-its-cursor",
    why:
      "Return the controls hydration adds to having no cursor of their own, the state" +
      " in which they shipped: a focusable, click-bound control on the truncated" +
      " identifiers — the one population whose ONLY route to the full value is that" +
      " control — presenting under a plain arrow. `auto` rather than deleting the rule," +
      " so the mutation is one token and cannot be confused with a file that failed to" +
      " save.",
    file: join(CLIENT, "src", "components", "debugger_css.nim"),
    // ANCHORED TO THE COMMENT ABOVE IT, and it has to be. The bare selector
    // `[role="button"]{cursor:pointer}` stopped being unique the moment the
    // breakpoint gutter landed in this same stylesheet: `.srcline .n[role=
    // "button"]{cursor:pointer}` CONTAINS it as a substring, so the bare form
    // matches twice and `find` must occur exactly once. Two independently
    // correct changes composing into an ambiguous mutation target is precisely
    // what the exactly-once rule is for — without it this arm would have
    // silently mutated the gutter's rule instead of the copy control's and
    // gone on reporting a kill it did not earn.
    find: `keep \`not-allowed\` from their own, higher-specificity rules. */
[role="button"]{cursor:pointer}`,
    replace: `keep \`not-allowed\` from their own, higher-specificity rules. */
[role="button"]{cursor:auto}`,
    journey: "a-clickable-surface-shows-the-hand",
    assertion: "copy controls hydration added to this page — each computes `pointer`",
  },
  {
    id: "R/the-blanket-fix",
    why:
      "THE WRONG FIX, WHICH PASSES EVERY ASSERTION ON THE HYDRATED PAGE. Change" +
      " `.copyable` itself to `pointer` instead of subordinating it where a click means" +
      " something else. Arm 1 of the journey goes green — the rows show the hand — and" +
      " the copy affordance is gone from the served page, where the rows are inert" +
      " `div.ctrow` and `user-select:all` plus a copy cursor was the only true thing" +
      " that surface said. This is the arm the NO-SCRIPT scope control exists for, and" +
      " without it the journey could not tell a scoped fix from a deletion.",
    file: join(CLIENT, "src", "components", "debugger_css.nim"),
    find: `.copyable{user-select:all;cursor:copy;border-radius:var(--bt-radius-xs);`,
    replace: `.copyable{user-select:all;cursor:pointer;border-radius:var(--bt-radius-xs);`,
    journey: "a-clickable-surface-shows-the-hand",
    assertion: "NO-SCRIPT: the copy affordance survives where nothing encloses it",
  },
  {
    id: "S/a-hand-on-something-inert",
    why:
      "THE DEFECT MIRRORED. Widen the row rule from `a.ctrow,a.evrow` to `.ctrow,.evrow`" +
      " so it also paints the served page's rows, which carry no `href` and jump" +
      " nowhere. Every assertion about the hydrated page stays green — those rows are" +
      " anchors and were already `pointer` — and what reddens is the inverse claim on" +
      " the one population where it is not vacuous. This is the sibling repository's" +
      " `build-clickable` shape: a cursor promising a click the element cannot deliver," +
      " which a spec asserting the CLASS would have gone on passing.",
    file: join(CLIENT, "src", "components", "debugger_css.nim"),
    find: `a.ctrow,a.evrow{cursor:pointer}`,
    replace: `.ctrow,.evrow{cursor:pointer}`,
    journey: "a-clickable-surface-shows-the-hand",
    assertion:
      "NO-SCRIPT: no row that cannot be clicked offers the hand that says it can",
  },
  {
    id: "T/a-hand-on-a-heading",
    why:
      "THE INVERSE DIRECTION OF §13, AIMED AT THE PAGE-WIDE RULE RATHER THAN AT ONE" +
      " PANE. Leak `cursor:pointer` onto `.panetitle` — a heading, inside no anchor and" +
      " carrying no role, which Front-End-Architecture §7 guarantees cannot be a" +
      " hand-rolled control either. Every surface this journey names stays green," +
      " because none of them is a pane title; what reddens is the set-equality sweep," +
      " which is the assertion that has to catch a cursor defect on a pane nobody" +
      " thought to enumerate. Without this arm the sweep could be reading a constant" +
      " and reporting zero violations forever.",
    file: join(CLIENT, "src", "components", "styles.nim"),
    find: `button{cursor:pointer}`,
    replace: `button,.panetitle{cursor:pointer}`,
    journey: "a-clickable-surface-shows-the-hand",
    assertion:
      "nothing that is not an anchor, a button or an interactive role shows the hand",
  },
  {
    id: "U/the-mark-is-painted-and-nothing-is-sent",
    why:
      "Paint the breakpoint and tell the engine nothing. This is not a" +
      " hypothetical shape — it is what the product did until this feature" +
      " landed, measured at ZERO `setBreakpoints` frames sent by the whole" +
      " bundle. The gutter is rendered from a set this repository owns, so all" +
      " three marks appear, `aria-pressed` is correct on all three, and" +
      " Continue runs straight past them to the end of the recording. Every" +
      " assertion that reads the DOM stays green; only the wire says otherwise," +
      " which is why the journey counts frames at all.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `  h.render()
  h.sendBreakpoints(path)`,
    replace: `  h.render()
  discard path`,
    journey: "continuing-stops-at-a-breakpoint",
    assertion: "CONTROL: three `setBreakpoints` frames reached the engine, one per click",
  },
  {
    id: "V/only-the-clicked-line-is-sent",
    why:
      "Send just the line that was clicked instead of the file's whole set." +
      " DAP `setBreakpoints` REPLACES a source's breakpoints —" +
      " `dap_handler.set_breakpoints` calls `clear_breakpoints_for_source`" +
      " first — so a request naming one line does not add a breakpoint, it" +
      " makes that line the ONLY one in the file. The gutter still shows three" +
      " marks because the page's own set is untouched; the engine has one, and" +
      " the forward walk reaches a single line instead of all three. This is" +
      " the arm for the sentence in `live_breakpoints`'s header that a reader" +
      " would most plausibly 'simplify'.",
    file: join(CLIENT, "hydrate", "live_breakpoints.nim"),
    find: `  let lines = s.linesFor(path)
  let name =`,
    replace: `  let lines = (if s.linesFor(path).len > 0: @[s.linesFor(path)[^1]] else: @[])
  let name =`,
    journey: "continuing-stops-at-a-breakpoint",
    assertion: "the forward walk reaches all three marked lines, not just the first",
  },
  {
    id: "W/the-breakpoint-names-a-file-the-trace-does-not-have",
    why:
      "Name a file the recording never interned, so no breakpoint resolves and" +
      " Continue reaches none of them. Aimed at the forward walk rather than at" +
      " the mark, because the marks are painted from this page's own set and" +
      " all three still appear." +
      "\n    THIS ARM WAS FIRST WRITTEN AS THE ABSOLUTE PATH — prefixing the" +
      " document's path with the recording machine's directory, the correction" +
      " `live_source.nim` warns silently removes a feature — AND IT SURVIVED." +
      " That is worth recording rather than hiding: `set_breakpoints` resolves" +
      " through `db.rs`'s `load_path_id`, which is `reader.fuzzy_path_id_for`," +
      " and the fuzzy match absorbs a prefix. So the absolute spelling is NOT a" +
      " defect for breakpoints, even though it is one for the origin" +
      " classifier, which builds its own probe path and does not go through" +
      " that lookup. The two failure modes are not the same and this arm may" +
      " not pretend they are.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `    (attr(doc, "data-path"), intAttr(row, "data-line"))`,
    replace: `    ("not-a-file-in-this-trace.nr", intAttr(row, "data-line"))`,
    journey: "continuing-stops-at-a-breakpoint",
    assertion: "continuing forward stops at least three times",
  },
  {
    id: "X/an-empty-set-still-reaches-the-engine",
    why:
      "Remove the short-circuit that answers a continue with no breakpoints" +
      " without a round trip. §10.8 requires the control to SAY there was" +
      " nothing to reach rather than run to the end; the engine does the" +
      " opposite, so a session with no breakpoints would be sent to the last" +
      " step of the recording and seeked back — a jump the visitor did not ask" +
      " for, and one they would SEE. The restore keeps the final position" +
      " correct, which is exactly why this arm is aimed at the wire: the" +
      " position assertion alone would survive it.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `    if h.breakpoints.isEmpty():`,
    replace: `    if false:`,
    journey: "continuing-stops-at-a-breakpoint",
    assertion: "no `continue` reached the engine at all, so there was no jump to undo",
  },
  {
    id: "Y/reversing-rewinds-to-the-first-breakpoint",
    why:
      "Make reverse continue seek to the earliest breakpoint hit instead of" +
      " asking the engine to find the nearest preceding one. THE ERROR A" +
      " SINGLE BREAKPOINT CANNOT CATCH: with one breakpoint, or from a" +
      " position just after the first, 'nearest preceding' and 'first in the" +
      " file' are the same answer and this mutation is invisible. The journey" +
      " sets three and reverses from the last, and it asserts the two are" +
      " DIFFERENT before comparing, so the discrimination is not vacuous." +
      " Implemented as a seek to the recording's start, which is where a" +
      " reverse-continue that ignores the current position ends up.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `    h.continueFrom = h.session.store.debugger.val.rrTicks
    h.continueAwaiting = true`,
    replace: `    h.continueFrom = h.session.store.debugger.val.rrTicks
    if not forward:
      h.gotoTicks(0)
      return
    h.continueAwaiting = true`,
    journey: "continuing-stops-at-a-breakpoint",
    assertion:
      "the first reverse continue lands on the stop NEAREST BEFORE it, not the first in the file",
  },

  // ── The three halves of the reveal policy, one arm each ─────────────────
  //
  // A visitor reported that stepping scrolled the pane on every step and pinned
  // the position to its top edge. The fix has three separable parts — WHEN the
  // pane moves, WHERE the position lands when it does, and whether the document
  // underneath it is stable enough for either question to mean anything — and a
  // single arm that reverted the lot would prove only that journey 13 notices
  // SOMETHING. Each of these reverts exactly one part and names the assertion
  // that must go red, and R and S are written so that the assertion Q targets
  // stays GREEN under them: if it did not, the three would be one arm wearing
  // three hats.
  {
    id: "Z1/the-pane-scrolls-on-every-step",
    why:
      "Remove the guard that leaves an already-correct scroller alone, so the reveal" +
      " centres on every step whether or not the position is on screen. This is the" +
      " first half of the reported defect — 'the editor should auto-scroll only when" +
      " the caret leaves the visible area' — and it is the half NO other journey can" +
      " see: the position is still marked, still on screen and still correct, so" +
      " journeys 03, 06 and 09 stay green throughout. The only thing that changes is a" +
      " number nothing else in this directory reads." +
      " THIS ARM ALREADY EARNED ITS KEEP ONCE. Aimed at an earlier fast path above" +
      " the loop it SURVIVED, because that path could only fire when this guard would" +
      " have fired anyway — two places that agreed, one of them dead. The fast path" +
      " is gone and the policy has one home, which is the difference between a" +
      " mutation that measures something and one that measures a duplicate.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `    if (sameDoc && inside(s)) continue;`,
    replace: `    if (false) continue;`,
    journey: "source-pane-holds-still-while-the-position-is-visible",
    assertion: "SOURCE: a step to a position already on screen leaves `scrollTop` UNCHANGED",
  },
  {
    id: "Z2/the-revealed-position-is-anchored-to-the-top",
    why:
      "Anchor the reveal to the TOP of the box instead of centring it — the" +
      " `revealLineNearTop` behaviour the product had, via `scrollIntoView()`'s" +
      " no-argument form. The gate stays: the pane still moves only when the position" +
      " has left the box, so Q's assertion stays green and this arm is judged on the" +
      " destination alone. That separation is the point. It is also the second" +
      " sentence of the report — 'I would scroll with half a screen perhaps to allow" +
      " further movement without auto-scroll' — which is a claim about where the line" +
      " lands and not about whether it moved." +
      " IT IS AIMED AT THE LISTING ARM, and the first draft aimed at the source arm" +
      " and SURVIVED. The demo document is 886px against a 512px box, so its only" +
      " reveal is 138px from the end and a top-anchored scroll CLAMPS — the line lands" +
      " six rows down, satisfying every context assertion, because the scroller ran" +
      " out of document before it could put the line at the top. The chain listing is" +
      " 7975px and its reveal is nowhere near either end, so the defect is expressible" +
      " there. Which arm can express a defect is a property of the subject, not of the" +
      " assertion, and the journey states the same claim about both.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `    var centred = lineTop - (s.clientHeight - cr.height) / 2;`,
    replace: `    var centred = lineTop;`,
    journey: "source-pane-holds-still-while-the-position-is-visible",
    // REPOINTED, AND THE OLD TARGET IS THE FINDING. This arm SURVIVED two
    // independent full passes against "LISTING: the revealed position is NOT
    // the first line on screen", and the reason is that THE MUTATION ERASES ITS
    // OWN SUBJECT:
    //
    //   unmutated  LISTING  30 steps → 29 on screen, 1 DEPARTURE, 1 reveal
    //   mutated    LISTING  30 steps → 30 on screen, 0 DEPARTURES, 0 reveals
    //
    // Centring leaves half a box below the revealed line, so the walk departs
    // again a dozen steps later. Top-anchoring leaves a WHOLE box below it, and
    // thirty steps never depart a second time. The assertion then quantified
    // over nothing and `countIs(0, 0)` was green — a defect that makes itself
    // unobservable, read as a defect that was not there. The harder it bites,
    // the fewer subjects survive to notice it.
    //
    // The paragraph above claiming the SOURCE arm cannot express this — "the
    // demo document is 886px against a 512px box … a top-anchored scroll
    // CLAMPS" — has also expired: that document is now 369px of range over a
    // 517px box and produces two reveals, one of them clear of both ends and
    // landing at index 0. Repointing to the source arm would work today and
    // would be the same bet on geometry that failed here.
    //
    // So the target is the claim made over BOTH arms' reveals at once. It can
    // only lose its subject if NEITHER document produced a reveal clear of its
    // ends, and that is an asserted subject count rather than a silent zero.
    assertion: "no reveal in EITHER rendering puts the position on the first line of the box",
  },
  {
    id: "Z3/the-document-is-re-windowed-under-the-position",
    why:
      "Restore the windowing `renderPanes` used to do — drop every line above" +
      " `currentLine - 6` on every stop — while leaving the reveal policy entirely" +
      " alone. This is the SECOND mechanism of the reported defect and the reason" +
      " journey 13 does not judge `scrollTop` alone: with the document rebuilt" +
      " beneath the position on every step, the position sits at row 7 by" +
      " construction and `scrollTop` is 0 before and 0 after. Q's assertion stays" +
      " GREEN under this arm — nothing scrolls, because nothing needs to — and so" +
      " does every assertion in journeys 03, 06 and 09, which is precisely how this" +
      " half shipped. The pane moves under the reader and no reading of the scroll" +
      " offset can see it; only the position's distance from the top of the box can." +
      " The windowing is written out inline rather than restored as a call, because" +
      " an arm is one edit in one file and `openAtCurrent` no longer exists — the" +
      " sibling fix removed the constant, the proc and both call sites, so there is" +
      " nothing left to call and the mutation has to spell the window out." +
      " IT HANGS OFF `var view = view`, AND IT DID NOT USED TO. Anchored to" +
      " `noteRevealAnchor(ui.editor)` — the line above — it inserted a SECOND" +
      " `var view = view` over the one already there, and the mutated tree stopped" +
      " compiling: `hydrate.nim(594, 7) Error: redefinition of 'view'`. This arm was" +
      " therefore NEVER RAN on `dev`, not killed, for as long as both changes have" +
      " been in the tree together. It measured nothing, and the journey assertion it" +
      " is the sole guard for — the one that catches the half `scrollTop` cannot" +
      " see — had no mutation proving it bites." +
      " That is the third verdict earning its place. An rc-based harness scores a" +
      " build failure as a kill, because a red journey and a broken build both exit" +
      " non-zero; this one reports DID-NOT-BUILD and is why the gap was visible at" +
      " all rather than sitting under a green summary.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `  var view = view`,
    replace: `  var view = view
  block:
    let ai = view.editor.activeIndex
    if ai >= 0 and ai < view.editor.documents.len:
      let all = view.editor.documents[ai].lines
      var keep = all
      keep.setLen(0)
      for ln in all:
        if ln.number >= view.editor.currentLine - 6: keep.add ln
      if keep.len > 0: view.editor.documents[ai].lines = keep`,
    journey: "source-pane-holds-still-while-the-position-is-visible",
    assertion:
      "LISTING: the position moves DOWN the box while the pane holds still, rather than staying pinned to one offset",
  },
  {
    id: "P2/the-path-leaves-the-page-as-well-as-the-row",
    why:
      "Stop stating the path as data on the row. This is the FALSE PASS this" +
      " journey exists to exclude, made real: 'the row does not paint a path' is" +
      " still true — truer than before — and the pane has quietly stopped being able" +
      " to say where any frame is. It is also the live defect, because" +
      " `hydrate.rowsOf` resolves a `src:` deep link against this attribute.",
    file: join(CLIENT, "src", "components", "debugger.nim"),
    find: `            tdiv(class = cls, \`data-step\` = $f.step, \`data-anchor\` = f.anchor,
                 title = tip, \`data-module\` = f.module):`,
    replace: `            tdiv(class = cls, \`data-step\` = $f.step, \`data-anchor\` = f.anchor,
                 title = tip, \`data-module\` = ""):`,
    journey: "call-trace-names-its-frames-in-full",
    assertion: "SERVED: rows carry their path as data",
  },
  {
    id: "P3/the-panel-drops-the-path-it-was-given-to-hold",
    why:
      "Remove the one fact that makes the path's departure from the row safe. The" +
      " row stops painting it, the panel stops stating it, and the path is then" +
      " reachable on hover and nowhere a reader can select or read it at length —" +
      " which is the trade this change is only allowed to make because the panel" +
      " holds the other end of it.",
    file: join(CLIENT, "src", "debugger", "session_view.nim"),
    find: `      result.facts.add selectionFact("Source", where, identifier = true)`,
    replace: `      discard where`,
    journey: "call-trace-names-its-frames-in-full",
    assertion: "SERVED: the selection area states the path the row no longer paints",
  },
  {
    id: "P4/no-frame-is-current-on-a-live-session",
    why:
      "Remove the position fallback and wait for `CallFrame.current` alone. This is" +
      " not a hypothetical: `CalltraceVM.selectedEntry` is read and never written," +
      " so on a hydrated session NO frame is ever marked, and the panel measured" +
      " here fell through to the source line while 49 frames were on screen beside" +
      " it. The arm is the reason that fallback exists, and it targets a LIVE" +
      " assertion because the served page — where the demo producer does mark a" +
      " frame — stays green throughout." +
      " THIS ARM WAS DEAD AND HAS BEEN REPAIRED: its `find` still carried the" +
      " `and v.controls.step > 0` conjunct that the guard shed when step 0 was" +
      " recognised as a real position, so the string occurred ZERO times and the" +
      " arm silently proved nothing about the assertion below.",
    file: join(CLIENT, "src", "debugger", "session_view.nim"),
    find: `  if chosen < 0 and v.controls.positioned:
    for i, f in v.calltrace.frames:
      if f.step > 0 and f.step <= v.controls.step: chosen = i`,
    replace: `  if false:
    discard`,
    journey: "call-trace-names-its-frames-in-full",
    assertion: "LIVE: selecting a repeated frame makes the panel name that function",
  },
  {
    id: "SC1/the-scrubber-is-only-an-animation",
    why:
      "Make every scrub seek a no-op while leaving the painting alone. This is THE" +
      " defect journey 12 was written against and the cheapest way to build the" +
      " control wrongly: the handle follows the pointer perfectly, the cursor" +
      " changes, the readout counts up, and the session never moves — a decoration" +
      " with a grab cursor. Note which assertion it is aimed at. The mid-drag" +
      " tracking check stays GREEN with this in place, because the handle really" +
      " does track, and that is exactly why 'the handle moved' cannot be the" +
      " verdict.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `  if step <= 0: return
  h.gotoTicks(step, onSettled = proc() =`,
    replace: `  if step <= 0 or true: return
  h.gotoTicks(step, onSettled = proc() =`,
    journey: "the-timeline-can-be-dragged",
    assertion: "every drop moved the marked source position, not only the readout",
  },
  {
    id: "SC2/the-handle-waits-for-the-engine",
    why:
      "Stop painting the handle under the pointer, so it only moves when a seek is" +
      " answered. The session still ends up exactly where it was dropped — every" +
      " landing assertion stays green — and the control becomes unusable, because" +
      " on a real chain capture a seek takes about 2.1 s and the handle spends the" +
      " whole gesture two seconds behind the hand. Aimed at the REAL arm because" +
      " that is where the lag is large enough to be a fact rather than a" +
      " stopwatch argument, and because it is the arm that proves the mid-drag" +
      " reading is doing work no post-release reading could do.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `  let track = ui.controls.querySelector(".dctl")
  if track == nil: return
  let p = DebugControlsPane(step: step, totalSteps: totalSteps, positioned: step > 0)`,
    replace: `  let track = ui.controls.querySelector(".dctl")
  if track == nil or true: return
  let p = DebugControlsPane(step: step, totalSteps: totalSteps, positioned: step > 0)`,
    journey: "the-timeline-can-be-dragged",
    assertion: "REAL: the handle stayed under the pointer even while the engine lagged behind it",
  },
  // ── THE ARM THAT IS NOT HERE, AND WHERE ITS DEFECT IS COVERED INSTEAD ──
  //
  // There was an arm `SC-stale/the-drop-point-loses-to-a-stale-target`, restoring the
  // coalescing regression that shipped in the drag's first draft: a target
  // decided when an earlier seek settled, issued after a newer one had already
  // gone out, so the gesture finished on a step the visitor merely dragged
  // THROUGH (released at 1052, ended at 707).
  //
  // IT SURVIVED, AND THE HONEST READING IS THAT THIS LAYER CANNOT JUDGE IT.
  // Reproducing the defect needs a pointer move to arrive after the in-flight
  // slot is released and before the deferred send — a window one microtask
  // drain wide. Across roughly two dozen chances in a full journey run, no real
  // pointer move landed there. Forcing it with injected pointer events from
  // deep in the microtask queue did produce the stale REQUEST, and still not
  // the stale resting place, because the engine's own latency varies by a
  // factor of forty-five between the demo recording (46 ms median) and a real
  // chain capture (~2.1 s) and the staging depends on which one answers when.
  //
  // An arm that reproduces its own defect only sometimes is a coin, not
  // evidence, and a green run containing one is worse than no arm at all.
  //
  // So the rule moved out of the browser instead: `client/src/debugger/
  // scrub_queue.nim` is the coalescing decision as ordinary data, and
  // `client/tests/test_scrub_queue.nim` states that exact ordering as six
  // lines with no clock in it, plus a MUTATION BITE case writing out the
  // defective variant and showing it lands on the dragged-through step. Two
  // deliberate mutations of the shipping module were checked by hand: removing
  // the pending-clear reddens suite 1 case 2 and nothing else, and removing
  // `drain`'s `nxt != sent` guard reddened NOTHING — which is how that guard
  // was found to be unreachable and deleted, with the invariant it claimed
  // asserted across a sixty-move drag instead.
  //
  // What journey 12 still owns is the end-to-end claim: the handle tracks the
  // pointer while the button is down, and the session's own `data-step`
  // afterwards is the step the release point names.
  {
    id: "SC3/the-affordance-ships-without-the-gesture",
    why:
      "Put the seekable class on the track in the RENDERER, so the scriptless build" +
      " carries it too. That build has no bundle, so nothing there can honour it —" +
      " which makes this the house defect in its purest form, after the plus-cursor" +
      " on rows that were not clickable and the `cursor: pointer` that outlived the" +
      " click handler it belonged to (with a spec asserting the class by name). It" +
      " is a ONE-WORD edit and it changes nothing a visitor of the hydrated page" +
      " could see, which is precisely why the guard has to read the other artefact" +
      " rather than the DOM in front of it.",
    file: join(CLIENT, "src", "components", "debugger.nim"),
    find: `      tdiv(class = "dctl"):`,
    replace: `      tdiv(class = "dctl seekable"):`,
    journey: "the-timeline-can-be-dragged",
    assertion: "the scriptless build promises no gesture: no role, no tab stop, no range, no cursor class",
  },
  {
    id: "SC4/the-handle-stops-telling-the-truth",
    why:
      "Freeze the drawn playhead at the first tick, leaving the drag untouched." +
      " This is the QUIETER member of the same defect family — not a control that" +
      " refuses to take you somewhere, but one that lies about where you are — and" +
      " it is the form the drag made newly possible, because painting the handle" +
      " from a pointer added a second writer of a readout that used to have one." +
      " Every drag assertion stays green: the mid-drag paint goes through" +
      " `paintScrubber`, which is not mutated, and the landings are read from the" +
      " session. Only the stepping readings, taken through the toolbar's entirely" +
      " separate sender, can see it.",
    file: join(CLIENT, "src", "components", "debugger.nim"),
    find: `  let filled = p.markedTick`,
    replace: `  let filled = (if p.positioned: 1 else: 0)`,
    journey: "the-timeline-can-be-dragged",
    assertion: "after every toolbar step the handle sits on the tick the session's own step names",
  },
  {
    id: "SC5/only-a-drag-counts-as-a-gesture",
    why:
      "Stop seeking on the press, so the control answers a drag and ignores a" +
      " click. A visitor who has just learnt the track is draggable will click it," +
      " and this is the version of the product where that does nothing — or worse," +
      " re-seeks to wherever the previous drag ended, because the release path" +
      " still commits the last target. The drags all keep working, which is the" +
      " point: the click was a deliberate decision and it needs an assertion of its" +
      " own or it is one refactor from being dropped as redundant.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `    # THE PRESS SEEKS. See the \`scrubbing\` field block: a click on the track is
    # a press and a release at one point, so making the press act is what makes
    # a bare click seek there, with no second code path to keep in agreement.
    scrubTo(stepUnderPointer(track, pointerX(ev))))`,
    replace: `    discard track)`,
    journey: "the-timeline-can-be-dragged",
    assertion: "a click on the track, with no drag at all, takes the session to that point",
  },
  {
    id: "SC6/the-keyboard-goes-dead-again",
    why:
      "Return from the keydown handler before it reads a key. The slider keeps" +
      " `role=\"slider\"` and its tab stop, so it is still announced as a range" +
      " control and still focusable — and no key moves it, which is a" +
      " `role=\"button\"` that neither Enter nor Space activates wearing a" +
      " different name. This route has shipped that once already. The arm exists" +
      " because the real defect here was not a missing handler but a WORKING one" +
      " whose key never matched: `keyName` was declared `string`, so Nim wrapped" +
      " it in `toJSStr`, which walks its argument as character codes and returns" +
      " something no branch matches — it compiled, ran, threw nothing, and every" +
      " key fell through to `else`.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `    if track == nil: return
    let total = totalNow()`,
    replace: `    if track == nil: return
    if true: return
    let total = totalNow()`,
    journey: "the-timeline-can-be-dragged",
    assertion: "the slider answers the keyboard it puts itself in the tab order for",
  },
  {
    id: "SC7/End-asks-for-a-coordinate-past-the-end",
    why:
      "Put back the number `End` used to ask for. This is not a synthetic" +
      " mutation — it is the defect as it shipped, and it was found by the" +
      " assertion it is aimed at. `totalSteps` is a COUNT and the time" +
      " coordinates are zero-based, so `total` is one past the last step the" +
      " recording has; the engine does not refuse it, it PANICS" +
      " (`load_local_calltrace: invalid step_id`) and traps the WASM module, and" +
      " the session answers nothing for the rest of the visit. Measured on a" +
      " 345-step recording: ticks 343 and 344 answered, 345 killed it, and a" +
      " `Home` pressed afterwards did nothing at all. Nothing in the repository" +
      " had ever asked for that coordinate — the drags release at 0.9 — so the" +
      " one value that ends the session sat exactly where no check looked.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `      of smEnd: lastStep(total)`,
    replace: `      of smEnd: total`,
    journey: "the-timeline-can-be-dragged",
    assertion: "every key the scrubber advertises moves the session",
  },
  {
    id: "SC8/the-scrubber-stops-naming-its-keys",
    why:
      "Reduce the scrubber's tooltip to the control's name, which is what it" +
      " said for the whole life of the control: `role=\"slider\"`, a tab stop," +
      " eight keys answered, and not one of them named anywhere a visitor could" +
      " read. That is the same complaint a visitor made about the stepping" +
      " buttons beside it, and the arm exists because a sentence derived from a" +
      " table is exactly the kind of thing a later edit replaces with a literal" +
      " that then stops tracking the table.",
    file: join(CLIENT, "src", "debugger", "keymap.nim"),
    find: `  ScrubName & " — " & parts.join(", ")`,
    replace: `  ScrubName`,
    journey: "the-timeline-can-be-dragged",
    assertion: "the tooltip names every key the control advertises",
  },

  // ── THE CHORD IN THE TOOLTIP, WHICH IS WHAT WAS REPORTED (journey 20) ────
  //
  // The keymap landed with no mutation arm at all, and its Nim suite is where
  // the composition is checked. That suite compares the RENDERER'S OUTPUT
  // STRING; this arm is aimed at the assertion that reads the attribute off a
  // hydrated page, because a renderer that is correct and a page that never
  // shows its output is this route's signature defect and the Nim suite cannot
  // tell the difference.
  {
    id: "KB1/the-tooltip-drops-the-chord",
    why:
      "Return the control's plain name from the keymap-aware `controlLabel`, so" +
      " the button is labelled exactly as the served frame labels it. The chord" +
      " is still bound, the dialog still lists it, and the one channel the" +
      " visitor's report was about — 'I still don't see the keyboard shortcuts" +
      " being displayed in the tooltips of the debugger control buttons' —" +
      " silently stops carrying it. Every Nim assertion about the DIALOG, every" +
      " assertion about dispatch, and the chord that steps the session all stay" +
      " green.",
    file: join(CLIENT, "src", "debugger", "keymap.nim"),
    find: `  if not bound: name
  else: name & " (" & describe(c) & ")"`,
    replace: `  if not bound: name
  else: name`,
    journey: "a-chord-steps-the-session",
    assertion: "every button's tooltip names the chord the dialog gives that same move",
  },

  // ── THE PLAYHEAD, AS A FACT JOURNEY 06 CAN NOW SEE (journey 06) ──────────
  //
  // Both arms exist because that journey's one conditional assertion could not
  // fail. It read
  //
  //     const reportsPosition = Number(live.facts.step) > 0 && …;
  //     j.expect(!reportsPosition || (live.facts.marked === 1 && …), …)
  //
  // and BOTH of its subjects land on step 0 — the engine's `run-to-entry` parks
  // at tick 0 and says so — so the antecedent was false on every run, and the
  // assertion asserted nothing on a journey that was green throughout.
  //
  // The replacement asserts the tick UNCONDITIONALLY, on both the served frame
  // and the live one, as a PAIR: which tick carries `.at` and how many carry
  // `.on`. These two arms are aimed one at each, and they are aimed at different
  // halves on purpose — PH1 moves the playhead without changing whether there is
  // one, PH2 removes it without moving anything else. A single arm could not
  // tell those apart, and the second is the defect this journey missed.
  {
    id: "PH1/the-playhead-drifts-back-a-tick",
    why:
      "Truncate instead of rounding when the step is turned into a tick, which is" +
      " the exact regression `markedTick`'s header records: every position in the" +
      " trace is drawn EARLIER than it is, by up to a whole tick, in one direction." +
      " The playhead is still there, still moves, still leads a correct elapsed run" +
      " — only its ARITHMETIC is wrong, which is why nothing that asks whether a" +
      " playhead exists can see it. Aimed at the SERVED frame: at step 128 of 1315" +
      " the tick goes 5 -> 4, while the live frame sits at step 0 where truncation" +
      " and rounding agree, so this arm reddens the served assertion and leaves the" +
      " live one green.",
    file: join(CLIENT, "src", "debugger", "session_view.nim"),
    find: `  else: clamp(int(p.fraction * float(TimelineTicks) + 0.5),`,
    replace: `  else: clamp(int(p.fraction * float(TimelineTicks) + 0.0),`,
    journey: "position-survives-hydration",
    assertion: "HYDRATED-SERVED: the playhead is on the tick the session's own step names",
  },
  {
    id: "PH2/a-session-at-tick-zero-has-no-position-again",
    why:
      "Restore `positioned = step > 0` in `projectControls` — the defect this" +
      " journey's header describes and could not assert. `ReplayDataStore`" +
      " initialises `rrTicks` to 0, so a session the engine has PARKED on the first" +
      " step and a session that has heard nothing hold the same number; reading the" +
      " number instead of the arrival makes 48 ticks with not one marked, on a page" +
      " whose served frame had just drawn the playhead on tick 18. Nothing else" +
      " changes: the source mark stays, `data-step` stays, every other assertion in" +
      " the journey stays green. That is what made it invisible, and it is why the" +
      " tick had to become a fact `probe.mjs` collects.",
    file: join(CLIENT, "hydrate", "session_project.nim"),
    find: `  result.positioned = engineReported or served.positioned`,
    replace: `  result.positioned = step > 0`,
    journey: "position-survives-hydration",
    assertion: "HYDRATED: the playhead is on the tick the session's own step names",
  },

  // ── THE CURSOR SWEEP'S NEW ROLES (journey 12) ────────────────────────────
  //
  // The sweep's interactive selector had fallen behind the product: it named no
  // `[role="slider"]`, so the scrubber — the one control whose correct cursor is
  // not `pointer` — was never measured, and it spelled "inert" as `[disabled]`
  // while `renderControls` spells it `aria-disabled`, so eight dead buttons were
  // required to show the hand and never had a subject to prove it on.
  {
    id: "CU1/the-scrubber-offers-the-wrong-hand",
    why:
      "Give the track `cursor:pointer`. This is the fix a sweep with ONE expectation" +
      " across all roles would have forced: a range is dragged to a value, not" +
      " clicked to one, and a pointing hand on a continuous control says the wrong" +
      " thing about the gesture. It is also the shape of the sibling repository's" +
      " `build-clickable` defect, where a class kept `cursor:pointer` with a spec" +
      " pinned to the class name. Note that §13's INVERSE catches it too — the" +
      " slider is deliberately not in `CLICKABLE`, so a hand there has no clickable" +
      " ancestor and is reported as an orphan. The two directions cross-check.",
    file: join(CLIENT, "src", "components", "debugger_css.nim"),
    find: `.dctl.seekable{cursor:grab}`,
    replace: `.dctl.seekable{cursor:pointer}`,
    journey: "a-clickable-surface-shows-the-hand",
    assertion: "the timeline scrubber, which is dragged and not clicked — each computes `grab`",
  },
  {
    id: "CU2/the-hand-never-closes",
    why:
      "Leave the offer and remove the operation: the track keeps `grab` at rest and" +
      " stops going to `grabbing` under the pointer. Every at-rest reading in the" +
      " file stays green, because at rest nothing changed — this is only visible to" +
      " a reading taken with the button still down, which is the one reading a" +
      " cursor sweep has no reason to take unless somebody wrote it. `.scrubbing`" +
      " and `:active` are removed together, since the pointer is captured for the" +
      " duration and either alone would leave the other answering.",
    file: join(CLIENT, "src", "components", "debugger_css.nim"),
    find: `.dctl.seekable:active,.dctl.scrubbing{cursor:grabbing}`,
    replace: `.dctl.seekable:active,.dctl.scrubbing{cursor:grab}`,
    journey: "a-clickable-surface-shows-the-hand",
    assertion: "the scrubber closes the hand while it is being dragged, and offers it open at rest",
  },
  {
    id: "CU3/a-dead-control-offers-the-hand",
    why:
      "Give the inert stepping buttons `cursor:pointer`. §13's second half, broken" +
      " as plainly as it can be — eight controls that cannot be operated, saying" +
      " they can. This arm is the reason the inert population is judged on the" +
      " NO-SCRIPT frame at all: the hydrated arm settles on `controlsLive > 0` and" +
      " has zero inert buttons, so the same mutation there reddens nothing. An" +
      " assertion whose subject set is empty on every arm that runs it is the" +
      " failure this whole directory is written against.",
    file: join(CLIENT, "src", "components", "debugger_css.nim"),
    find: `.dcbtn.off{background:var(--bt-surface-raised);
  color:var(--bt-text-subtle);border-color:var(--bt-border-subtle);
  cursor:not-allowed}`,
    replace: `.dcbtn.off{background:var(--bt-surface-raised);
  color:var(--bt-text-subtle);border-color:var(--bt-border-subtle);
  cursor:pointer}`,
    journey: "a-clickable-surface-shows-the-hand",
    assertion:
      "NO-SCRIPT: inert stepping controls, which cannot be operated — each computes `not-allowed`",
  },
  {
    id: "CU4/a-role-the-sweep-has-never-heard-of",
    why:
      "Relabel the scrubber `role=\"progressbar\"` — which is precisely what" +
      " `tickClass`'s header says this control must not be mistaken for, and a" +
      " plausible edit for someone who has only seen the elapsed run. The point of" +
      " the arm is not the role: it is that ADDING A ROLE IS HOW THIS SWEEP WENT" +
      " STALE. `role=\"slider\"` arrived on the track from a change with no reason to" +
      " think about the cursor journey, and nothing here noticed for as long as the" +
      " control existed. The inventory assertion is that omission mechanised, and" +
      " this proves it fires.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `  track.setAttribute("role", "slider")`,
    replace: `  track.setAttribute("role", "progressbar")`,
    journey: "a-clickable-surface-shows-the-hand",
    assertion:
      "every role the page uses is one this sweep either expects a cursor for or knows is not actuated",
  },

  // ── the omniscience overlay (journey 18) ─────────────────────────────────
  //
  // Two arms, aimed at two things the overlay claims — and NOT at "the overlay
  // is present", which was TRUE throughout the defect on the served frame and is
  // the false pass journey 18 is written against.
  //
  // ONE ARM WAS TRIED AND WITHDRAWN, and it is worth the lines. "Keep the first
  // flow window and drop every later one" should be a kill and cannot be:
  // measured on the wire, the engine ALREADY answers every `ct/load-flow` with
  // one window computed for tick 0 whatever position was asked about, so
  // freezing it changes nothing observable. That is journey 19's defect, and
  // the arm that would have proved journey 18 could see it is exactly the arm
  // that proves journey 18 cannot. Journey 19 exists because of it.

  {
    id: "F1/an-overlay-of-names-with-no-values",
    why:
      "Render every recorded value as the empty string. The overlay keeps its shape" +
      " — the right labels, in the right places, on the right lines — and says" +
      " nothing. This is not hypothetical: `live_locals`' own header records that" +
      " the pinned SDK's `extractValueText` has the wrong ordinal for seven of" +
      " eleven kinds and renders every string, bool, char, array and tuple as the" +
      " empty string, which is why the ordinals here were derived against the" +
      " engine rather than borrowed. A count cannot see it.",
    file: join(CLIENT, "hydrate", "live_locals.nim"),
    find: `  of tkInt: node{"i"}.getStr("")`,
    replace: `  of tkInt: ""`,
    journey: "a-stepped-session-shows-the-values-recorded-on-its-lines",
    assertion: "every value label carries a value and not just a name",
  },

  {
    id: "F2/the-engine-window-never-reaches-the-pane",
    why:
      "Refuse every parsed window where the projection asks for it. The session still" +
      " asks, the engine still answers, the answer is still parsed — and the pane" +
      " falls back to the loop rail with no values, which is EXACTLY the state `dev`" +
      " was in before this work and exactly the state a visitor reported. The arm" +
      " proves the overlay on screen is the live one and not the exporter's, which" +
      " is the one thing a presence check cannot establish.",
    file: join(CLIENT, "hydrate", "live_flow.nim"),
    find: `  feed != nil and feed.window.steps.len > 0`,
    replace: `  feed != nil and feed.window.steps.len > 0 and false`,
    journey: "a-stepped-session-shows-the-values-recorded-on-its-lines",
    assertion: "a live session is given a values overlay at all",
  },

  // A THIRD ARM WAS TRIED AND WITHDRAWN TOO — `flow_view.applyFlow`'s rule 1,
  // `if pane.availability != srcSourceLevel: return`, aimed at the journey's
  // "REAL: an instruction-level session is given no values overlay". It
  // SURVIVES, and for a reason worth writing down rather than working around:
  // the gate is doubled. `session_project.projectReplayPanes` only calls
  // `applyLiveFlow` inside `if result.editor.availability == srcSourceLevel`,
  // so removing rule 1 leaves the outer gate holding, and removing the outer
  // gate leaves rule 1 holding. No single edit reaches it, which is what
  // "belt and braces" means when it is true rather than claimed — and it is
  // deliberate on both sides: one producer is the static export's and one is
  // hydration's, and `applyFlow`'s header states the rule for both.
  //
  // The assertion is kept unarmed rather than weakened. An arm that mutated
  // both sites at once would be testing that two `if`s can both be deleted,
  // which nothing needs to know.
  {
    id: "O4/the-control-does-not-say-what-it-would-answer",
    why:
      "Drop the classified expression out of the origin control's own title, leaving" +
      " the label 'Trace to origin: ' with nothing after it. Every other reading of" +
      " the surface is unmoved — the control is rendered, it is rendered on exactly" +
      " the two values whose origin the engine classified, and the labelled and" +
      " authored counts both still read 2 — so this is the shape a presence check" +
      " cannot see, and the shape a `startsWith` check cannot see either. It is the" +
      " same NR-05 direction as O2 arriving through the label instead of through the" +
      " guard: the button says it will answer and names no answer. The journey" +
      " printed these titles as notes for its whole life and asserted nothing about" +
      " them, so the evidence sat two lines above a green verdict.",
    file: join(CLIENT, "src", "components", "debugger.nim"),
    find: `                   title = "Trace to origin: " & v.origin):`,
    replace: `                   title = "Trace to origin: "):`,
    journey: "a-value-can-be-traced-to-its-origin",
    assertion: "and each control names the origin it would trace to",
  },
  {
    id: "R/the-landing-position-is-never-asked-about",
    why:
      "Remove the re-issue of the locals request at the position the session LANDS" +
      " on. This is the defect exactly as it shipped, not an analogue of it: the" +
      " request `StateVM`'s effect issues at construction is dropped before the" +
      " worker exists and stays pending, the one store write that would re-run that" +
      " effect happens BEFORE `goLive` clears the tracker so its send is skipped as" +
      " a duplicate, and every write after the clear names the same coordinate and" +
      " changes no signal. The pane then says 'Reading the values at this position…'" +
      " for as long as the tab is open, and one step repairs it — which is why" +
      " journeys 11, 16 and 18 were green through it for a week: every one of them" +
      " steps before it reads, and journey 11's landing reading accepts any" +
      " sentence, so a pane that never stops promising satisfied the check written" +
      " to catch a pane that says nothing.",
    file: join(CLIENT, "hydrate", "hydrate.nim"),
    find: `  h.session.requestLandingLocals()`,
    replace: `  discard  # MUTATED: the landing locals request is not issued`,
    journey: "a-session-shows-the-values-it-landed-on",
    assertion: "the Values pane at the landing position says what it says on returning to it",
  },
];

const log = (s = "") => console.log(s);

// ---------------------------------------------------------------------------
// "DID NOT RUN" AND "FAILED" MUST NOT LOOK THE SAME TO A HUMAN
// ---------------------------------------------------------------------------
//
// Verification-Harness-Traps.md §1a's third verdict, applied to THE SUITE and
// not only to its arms. The arms have had it since this file was written: a
// mutation that does not compile is DID-NOT-BUILD, never a kill. The suite
// itself had two verdicts — `RESULT: OK` and `RESULT: FAILED` — and a third
// state it could reach and could not say: it never got there at all.
//
// THIS IS NOT HYPOTHETICAL AND IT IS THE WORSE FAILURE OF THE FAMILY. This
// suite has been observed dying part-way through with NO `RESULT` line, and
// **a stall producing no verdict reads to a human exactly like a suite nobody
// bothered to run.** A suite that never completes cannot tell you which of its
// arms are dead — which is the one question it exists to answer — so every
// journey's green is unbacked for as long as it is in that state. Two dead arms
// (`P4`'s `find` string occurring zero times, `break-check.mjs`'s two markers
// renamed out from under it) were found BY HAND rather than by this file
// reporting them, because this file was not reaching its summary.
//
// Three mechanisms, in increasing order of how violent an ending they survive:
//
//   1. EVERY EXIT PATH PRINTS A `RESULT:` LINE. `finish()` is the only way to
//      set an exit code, and an `exit` handler prints `RESULT: DID NOT RUN` if
//      nothing else did — which covers a `throw`, a `process.exit()` from a
//      dependency, and the top-level `catch`. The catch used to print a stack
//      and no verdict, which is exactly the shape being ruled out.
//   2. SIGINT / SIGTERM / SIGHUP ARE CAUGHT. An agent's shell wrapper giving up
//      at a timeout, a Ctrl-C, a CI cancellation: all three arrive as signals,
//      and a signal handler can both print the verdict and — see `inFlight` —
//      put the mutated file back. `finally` cannot; it does not run when the
//      process is signalled, which is how `K/the-served-values-stand` was left
//      in a worktree.
//   3. A JOURNAL ON DISK, written before the first arm and rewritten after each
//      one. `SIGKILL` and an OOM kill defeat 1 and 2 by construction — nothing
//      runs — so the evidence has to be something already written. The NEXT run
//      reads it and says how far the last one got. That turns "the log just
//      stops" into a named arm and a count.
//
// The journal is NOT a cache and is never read to skip work. It is read for
// exactly one purpose: to say that a previous run did not finish, and where.
// ---------------------------------------------------------------------------
// SHARDS, BECAUSE THE SUITE DOES NOT FIT IN AN HOUR
// ---------------------------------------------------------------------------
//
// MEASURED, on a warm tree with local builds: 62 arms, ~115 minutes. Each arm
// rebuilds and reruns its journey THREE times — before, mutated, restored — so
// the cost is a journey's runtime times three, times the number of arms aimed
// at it. `the-timeline-can-be-dragged` runs 339 s per arm and has eight arms:
// 45 minutes, about 39% of the whole suite, from one journey. It earns it —
// two subject arms, three real drags each, and a settle budget whose 6 s quiet
// window is measured against a chain seek observed at 3.0 s — but it means the
// suite has no hope of finishing inside a box smaller than two hours.
//
// AND THINGS THAT RUN IT HAVE SUCH BOXES. A run under an agent's background
// task was killed at ~60 minutes while running arm 47 of 62, with no verdict:
// the reported symptom, reproduced exactly. `--arm` cannot answer it, because
// it selects by NAME and a name is not a budget.
//
// `--shard i/n` slices the arms, and `--combine n` reads the shards' journals
// back and issues ONE verdict over the union. The slice is by STRIDE and not by
// contiguous block, deliberately: the eight expensive arms are adjacent in the
// list, so a contiguous shard would hold all of them and be the whole problem
// again. A stride spreads them.
//
// THE COMBINE IS NOT AN OR OF PASSES. It fails unless the shards' arms, unioned,
// are EXACTLY the full arm list — every arm once, none missing, none twice —
// and every one of them killed. A shard that never ran leaves no journal and
// the combine says which one, as DID NOT RUN rather than as a failure. That is
// the same three-verdict rule one level up: "n-1 shards passed" is not a claim
// about the suite.
// `i/n` -> {i, of}, or null. ONE parser, used by `--shard` and `--list-shard`,
// for the same reason there is one `shardOf`: a second copy could accept an
// argument the first rejects, and then the partition proof and the run would be
// talking about different slices.
const shardArg = (s) => {
  const m = /^(\d+)\/(\d+)$/.exec(s ?? "");
  if (!m) return null;
  const [i, of] = [Number(m[1]), Number(m[2])];
  return i >= 1 && i <= of ? { i, of } : null;
};

const shardIdx = process.argv.indexOf("--shard");
const shard = shardIdx < 0 ? null : shardArg(process.argv[shardIdx + 1]);

// Set by the `--list-*` modes. See the `process.on("exit")` hook: a query must
// not leave a journal behind, and must not print a verdict onto output the
// caller is reading as data.
let queryMode = false;

// THE SLICE, AS ONE EXPRESSION IN ONE PLACE.
//
// `main` slices the arms with this, and `--list-shard` reports the slice with
// it. Written twice, the report would be a MODEL of the slice rather than the
// slice, and a partition proof over a model proves nothing about what runs —
// the two could drift and every check would still pass. Whatever is wrong with
// this function is wrong in both directions at once, which is the property that
// makes the proof in `selftest-verdict-test.sh` worth having.
const shardOf = (arms, s) => arms.filter((_, i) => i % s.of === s.i - 1);

const journalPath = shard
  ? JOURNAL.replace(/\.json$/, `.shard-${shard.i}of${shard.of}.json`)
  : JOURNAL;

const journal = {
  startedAt: new Date().toISOString(),
  finishedAt: null,
  status: "running",
  planned: null,
  armFilter: null,
  shard,
  arms: [],
  lastArmStarted: null,
};

const writeJournal = () => {
  try {
    writeFileSync(journalPath, JSON.stringify(journal, null, 2));
  } catch {
    /* a journal that cannot be written must not be able to fail the run */
  }
};

/**
 * The file this run has mutated and not yet put back, or `null`.
 *
 * Held at module scope precisely so a SIGNAL HANDLER can reach it. The restore
 * in `main` is a `finally` and remains the normal path; this is the one that
 * runs when there is no normal path left.
 */
let inFlight = null;
const restoreInFlight = () => {
  if (!inFlight) return null;
  const { file, original } = inFlight;
  inFlight = null;
  try {
    writeFileSync(file, original);
    return file;
  } catch {
    return `${file} — RESTORE FAILED, the mutation is still in the tree`;
  }
};

let verdictPrinted = false;

/**
 * `console.log` STRAIGHT TO THE FILE DESCRIPTOR, and this is not a style
 * preference.
 *
 * Node's `process.stdout` is synchronous only for files and TTYs. **To a PIPE
 * it is asynchronous** — and `process.exit()` does not drain it, nor does an
 * `exit` handler get another turn of the loop. So the two paths that exist to
 * guarantee a verdict, the signal handler and the `exit` handler, are exactly
 * the two whose `console.log` can be discarded, and only when the output is
 * piped. Under `> file` it works; under `| tee run.log`, in a CI log collector,
 * or through an agent's shell wrapper, the verdict silently disappears — which
 * would restore the very thing this whole section removes, on the runs most
 * likely to need it.
 *
 * `selftest-verdict-test.sh` runs the SIGTERM probe both redirected and piped
 * for this reason. With `console.log` here the piped one prints no verdict.
 */
const logSync = (s) => {
  try {
    writeSync(1, s + "\n");
  } catch {
    console.log(s); // EAGAIN on a full pipe: better a late line than none
  }
};

/**
 * Print the run's one verdict, and record it. The ONLY way an exit code is set.
 *
 * `status` is the machine word and goes in the journal; `line` is what a human
 * reads. They are produced together so they cannot disagree, which is the same
 * rule `artefactIdentity` imposes on a verdict and the thing it was measured on.
 */
const finish = (status, line, code) => {
  verdictPrinted = true;
  journal.status = status;
  journal.finishedAt = new Date().toISOString();
  writeJournal();
  logSync(line);
  process.exitCode = code;
};

const progressSoFar = () => {
  const done = journal.arms.length;
  const planned = journal.planned ?? ARMS.length;
  const where = journal.lastArmStarted
    ? `, while running ${journal.lastArmStarted}`
    : done === 0
      ? ", before the first arm"
      : "";
  return `after ${done} of ${planned} arm(s)${where}`;
};

for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) {
  process.on(sig, () => {
    const restored = restoreInFlight();
    logSync("");
    if (restored) logSync(`  ${sig} — restored the mutated file: ${restored}`);
    finish(
      "did-not-run",
      `RESULT: DID NOT RUN — ${sig} ${progressSoFar()}.\n` +
        `        No arm's verdict below is a statement about the arms that never ran,\n` +
        `        and this run has judged NOTHING. Re-run, or run the remainder with\n` +
        `        \`--arm <substring>\`.`,
      2,
    );
    process.exit(2);
  });
}

process.on("exit", () => {
  // A QUERY IS NOT A RUN. `--list-shard` and `--list-arms` mutate nothing,
  // build nothing and judge nothing; they answer a question about the arm list
  // and return. Without this line the hook below treated them as a run that
  // ended without a verdict — printing `RESULT: DID NOT RUN` onto the stdout
  // the caller is parsing as arm ids, AND overwriting the journal of whatever
  // real run last happened. Caught by the partition proof itself: the union of
  // four shards came to 72 lines against a 64-arm list.
  if (queryMode) return;
  if (verdictPrinted) return;
  // A `throw`, a dependency calling `process.exit`, or any path that reached
  // the end without going through `finish`. Printing here is the difference
  // between "this run has no verdict" and a log that merely stops.
  restoreInFlight();
  journal.status = "did-not-run";
  journal.finishedAt = new Date().toISOString();
  writeJournal();
  logSync("");
  logSync(`RESULT: DID NOT RUN — the run ended without a verdict ${progressSoFar()}.`);
});

/** What the PREVIOUS run's journal says, or `null` if there is none. */
function previousRun() {
  try {
    return JSON.parse(readFileSync(journalPath, "utf8"));
  } catch {
    return null;
  }
}

/** The per-journey wall-clock table, over any list of journalled arms. */
function timingTable(arms) {
  const per = new Map();
  for (const a of arms) {
    const e = per.get(a.journey) ?? { arms: 0, seconds: 0 };
    e.arms += 1;
    e.seconds += a.seconds ?? 0;
    per.set(a.journey, e);
  }
  const total = arms.reduce((n, a) => n + (a.seconds ?? 0), 0) || 1;
  log("wall clock, by journey:");
  for (const [j, e] of [...per].sort((a, b) => b[1].seconds - a[1].seconds)) {
    log(
      `  ${String(e.seconds).padStart(5)}s  ${String(Math.round((100 * e.seconds) / total)).padStart(3)}%  ` +
        `${String(e.arms).padStart(2)} arm(s)  ${String(Math.round(e.seconds / e.arms)).padStart(4)}s/arm  ${j}`,
    );
  }
  log(`  ${String(total).padStart(5)}s                ${arms.length} arm(s)  TOTAL`);
  log("");
}

/**
 * `--combine n` — one verdict over n shards' journals.
 *
 * Read `combine` as an ASSERTION about coverage, not as a merge. It is the
 * place where "the full set" is claimed, so it has to be the place that checks
 * the full set is what was run.
 */
function combine(n) {
  log("=== journey selftest — combining shards ===");
  log("");
  const shards = [];
  const missing = [];
  for (let i = 1; i <= n; i += 1) {
    const p = JOURNAL.replace(/\.json$/, `.shard-${i}of${n}.json`);
    try {
      shards.push({ i, ...JSON.parse(readFileSync(p, "utf8")) });
    } catch {
      missing.push(i);
    }
  }
  for (const s of shards) {
    log(`  shard ${s.i}/${n}: ${s.status}, ${(s.arms ?? []).length} of ${s.planned ?? "?"} arm(s), ` +
        `started ${s.startedAt}`);
  }
  for (const i of missing) log(`  shard ${i}/${n}: NO JOURNAL — it did not run, or ran elsewhere`);
  log("");

  const unfinished = shards.filter((s) => s.status === "running");
  if (missing.length > 0 || unfinished.length > 0) {
    for (const s of unfinished) {
      log(`  shard ${s.i}/${n} never finished` +
          (s.lastArmStarted ? ` — it stopped while running ${s.lastArmStarted}` : ""));
    }
    finish(
      "did-not-run",
      `RESULT: DID NOT RUN — ${missing.length + unfinished.length} of ${n} shard(s) produced no` +
        " verdict, so there is nothing here to combine. This is NOT a failure: the arms in\n" +
        "        those shards were not judged either way.",
      2,
    );
    return;
  }

  // EVERY ARM ONCE. A stride that skipped one, an `n` that disagrees between
  // the shards and the combine, or two shards run with the same index would all
  // otherwise produce a confident verdict over a subset.
  const seen = new Map();
  for (const s of shards) for (const a of s.arms ?? []) {
    seen.set(a.id, [...(seen.get(a.id) ?? []), { ...a, shard: s.i }]);
  }
  const absent = ARMS.filter((a) => !seen.has(a.id)).map((a) => a.id);
  const twice = [...seen].filter(([, v]) => v.length > 1).map(([k]) => k);
  const alien = [...seen.keys()].filter((id) => !ARMS.some((a) => a.id === id));
  if (absent.length || twice.length || alien.length) {
    for (const id of absent) log(`  NOT RUN BY ANY SHARD  ${id}`);
    for (const id of twice) log(`  RUN BY MORE THAN ONE SHARD  ${id}`);
    for (const id of alien) log(`  AN ARM NO LONGER IN THIS FILE  ${id}  (the shards are stale)`);
    finish(
      "did-not-run",
      `RESULT: DID NOT RUN — the shards do not cover the arm list exactly, so a verdict\n` +
        "        over them would be a verdict over a subset wearing the full set's name.",
      2,
    );
    return;
  }

  const all = [...seen.values()].map((v) => v[0]);
  const notKilled = all.filter((a) => a.verdict !== "killed");
  timingTable(all);
  log(`${all.length} arm(s) over ${n} shard(s): ` +
      `${all.length - notKilled.length} killed, ` +
      `${notKilled.filter((a) => a.verdict === "survived").length} survived, ` +
      `${notKilled.filter((a) => a.verdict === "never").length} never ran`);
  for (const a of notKilled) {
    log(`  ${a.verdict === "survived" ? "SURVIVED " : "NEVER RAN"}  ${a.id}  [shard ${a.shard}]`);
  }
  if (notKilled.length > 0) {
    finish("failed", "RESULT: FAILED — every arm must be killed by the assertion written for it", 1);
    return;
  }
  log("  Each journey reddens on the defect it exists to catch, and only then.");
  finish("ok", "RESULT: OK", 0);
}

/**
 * Does this arm's journey judge the HYDRATED artefact?
 *
 * If it does, the mutation has to reach `hydrate.js` or the arm measures the
 * previous bundle — the mutation on disk, absent from the thing under test, and
 * the arm reporting SURVIVED against a defect it never introduced.
 *
 * THIS IS DERIVED, NOT DECLARED, because the declared version was wrong on its
 * first use. The rule was written as "arms that touch `client/hydrate/`", and
 * arm E touches `client/src/debugger/source_island.nim` — which the bundle
 * compiles against just as much, because `hydrate.nim` imports it through
 * `session_project`. The arm rebuilt only the exporter and survived. The
 * comment in this file already said what would happen; the flag encoding it
 * asked the wrong question.
 *
 * The right question is not "which file did I edit" — that needs an import
 * closure nobody maintains — but "which artefact is this journey judging",
 * which the journey already answers: `needsEngine` is exactly the set of
 * journeys that drive a live session. So an arm cannot forget the flag, because
 * there is no flag.
 */
async function judgesHydratedArtefact(journeyId) {
  const dir = join(HERE, "journeys");
  for (const f of await readdir(dir)) {
    if (!f.endsWith(".journey.mjs")) continue;
    const m = await import(join(dir, f));
    if (m.id === journeyId) return !!m.needsEngine;
  }
  throw new Error(`arm targets journey '${journeyId}', which does not exist`);
}

const DIST = join(CLIENT, "dist");
const BUNDLE = join(DIST, "assets", "hydrate.js");

/**
 * WHICH ARTEFACT WAS MEASURED — printed beside every verdict, and checked.
 *
 * ## The defect this exists for
 *
 * `rebuild()` used to be called ONCE at the top with no `hydration`, so the
 * "before" reading of every arm was taken against whatever `dist/` happened to
 * hold. It was found because an arm scored `NEVER RAN — the assertion is
 * ALREADY RED before the mutation`, from a hand-staged mutation still sitting in
 * a stale bundle. That is the LUCKY outcome, because it is loud.
 *
 * The quiet outcomes are the reason this function exists. A stale bundle that is
 * CORRECT gives a green before-reading, a mutation that never reaches the
 * artefact, a green after-reading — and a false `SURVIVED`, which reads as "this
 * assertion does not detect this defect" and sends someone to strengthen a test
 * that was already fine. A stale bundle that is already MUTATED gives the mirror
 * image, a false `KILLED`: an assertion certified as biting when it does not.
 * Neither prints anything unusual.
 *
 * That is an instrument reporting a VERDICT rather than a VALUE, inside the one
 * tool whose job is to certify that every other instrument is honest — so it can
 * launder exactly the class of error it was built to catch. The fix is not to
 * remember to rebuild. It is that a verdict with no artefact identity beside it
 * is unfalsifiable, so every verdict below carries one and the run refuses to
 * score an arm whose artefact did not move.
 *
 * ## What is hashed, and what is not
 *
 * The bundle, separately and by name, because that is the artefact the stale
 * reading was of. And everything the build WRITES that a journey can read: the
 * exported pages and their JavaScript and CSS.
 *
 * `dist/replay-engine/**` is excluded. It is 18 MB of `.js` and `.wasm` that
 * `lib/engine.mjs` STAGES into the tree from a cache — it is fetched, never
 * built, so no mutation can change it and its presence or absence depends only
 * on whether a journey has run yet. Including it made two consecutive exports of
 * identical source hash differently, which would have made the restore check
 * below fail on every arm.
 *
 * Verified byte-deterministic across three consecutive exports of an unchanged
 * tree: the bundle and the rendered digest are both stable.
 */
async function filesUnder(dir, out = []) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
    if (e.name === "replay-engine") continue;
    const full = join(dir, e.name);
    if (e.isDirectory()) await filesUnder(full, out);
    else if (/\.(html|js|css)$/.test(e.name)) out.push(full);
  }
  return out;
}

const shortHash = (buf) => createHash("sha256").update(buf).digest("hex").slice(0, 16);

/**
 * THE MEASURING INSTRUMENT IS PART OF THE ARTEFACT, AND LEAVING IT OUT COST AN
 * ARM ITS WHOLE LIFE.
 *
 * `N/the-position-is-compared-by-number-alone` mutates
 * `journeys/09-a-jump-moves-the-position.journey.mjs` — a JOURNEY, not product
 * source — because what it is testing is journey 09's own comparison: whether
 * "the marked position moved" is a RELATION or an integer. That is a legitimate
 * arm and a valuable one; the demo session's first row naming a step it is not
 * on moves the mark from `main.nr:1` to `shield.nr:1`, so a comparison on the
 * number alone reads a working jump as a mark that never moved.
 *
 * It scored `NEVER RAN — the artefact is byte-identical to the unmutated one`
 * on the first complete pass, and the diagnosis written from that — "the
 * mutation does not reach what the journey measures" — WAS WRONG. Editing a
 * journey file cannot change `client/dist` or the hydration bundle. By
 * construction. So `sameArtefact` was always true for this arm, and it would
 * have reported NEVER RAN on every run forever, including the run in which the
 * comparison was deleted outright.
 *
 * MEASURED, by applying the arm's own mutation by hand and running journey 09:
 *
 *     [FAILED] the marked position moved to the row's step
 *              — D-src-main-nr:1 -> D-src-shield-nr:1
 *
 * The arm is aimed at the right site and the journey does depend on it. The
 * only thing wrong was that the identity this harness compares did not include
 * the file the arm edits.
 *
 * So the journey sources are hashed too. `run.mjs` imports every
 * `journeys/*.journey.mjs` and everything under `lib/` at run time, which makes
 * them as much a part of what a verdict was taken on as `dist/` is — and, for a
 * meta-arm, the only part that moves. Product arms are unaffected: they touch no
 * file under here, so their before/after `instrument` hash is identical and the
 * byte-identity guard still catches a product mutation that missed the build.
 */
async function instrumentIdentity() {
  const h = createHash("sha256");
  for (const dir of [join(HERE, "journeys"), join(HERE, "lib")]) {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
      if (!e.isFile() || !e.name.endsWith(".mjs")) continue;
      h.update(e.name);
      h.update(await readFile(join(dir, e.name)).catch(() => Buffer.alloc(0)));
    }
  }
  return h.digest("hex").slice(0, 16);
}

async function artefactIdentity() {
  const bundle = await readFile(BUNDLE).catch(() => null);
  const files = await filesUnder(DIST);
  const h = createHash("sha256");
  for (const f of files.sort()) {
    h.update(f.slice(DIST.length));
    h.update(await readFile(f).catch(() => Buffer.alloc(0)));
  }
  return {
    rendered: h.digest("hex").slice(0, 16),
    bundle: bundle ? shortHash(bundle) : "ABSENT",
    bundleBytes: bundle ? bundle.length : 0,
    files: files.length,
    instrument: await instrumentIdentity(),
  };
}

const sameArtefact = (a, b) =>
  a.rendered === b.rendered && a.bundle === b.bundle && a.instrument === b.instrument;
const describe = (id) =>
  `rendered ${id.rendered} · bundle ${id.bundle} · instrument ${id.instrument}` +
  ` (${id.bundleBytes} B over ${id.files} files)`;

async function rebuild({ hydration = false } = {}) {
  // The exporter is always rebuilt. The hydration BUNDLE is rebuilt only for
  // arms whose journey judges it, because `nim js` over `hydrate.nim` costs
  // about a minute and most arms cannot affect what it measures.
  //
  // THE BASELINE BUILD PASSES `hydration: true` REGARDLESS — see
  // `artefactIdentity`. "Most arms cannot affect the bundle" is a reason not to
  // rebuild it PER ARM; it was never a reason to start the run against a bundle
  // nobody built, and that is what it had been read as.
  if (hydration) {
    try {
      await run("bash", [join(CLIENT, "hydrate", "build.sh"), "--require"], {
        cwd: REPO,
        maxBuffer: 64 * 1024 * 1024,
      });
    } catch (err) {
      return { built: false, log: String(err.stderr ?? err.stdout ?? err).slice(-1500) };
    }
  }
  try {
    await run(
      "nim",
      [
        "c",
        "-r",
        "--mm:orc",
        "-d:isServer",
        "-d:release",
        "-d:hydrationBundle=/assets/hydrate.js",
        "--hints:off",
        // A NIMCACHE INSIDE THIS WORKTREE, and it is not a speed setting.
        //
        // Nim's default is `~/.cache/nim/static_export_r`, keyed on the project
        // FILE NAME and not on its path, so every worktree of this repository
        // on the machine compiles the exporter through ONE directory. Two
        // selftests running at once — which is exactly what `--shard` is for —
        // then interleave their generated C, and both fail with things like
        // `use of undeclared identifier 'T1_'` in a stdlib file neither of them
        // touched. MEASURED: two shards launched together, in two worktrees,
        // both dead inside a minute.
        //
        // `hydrate/build.sh` already passes `--nimcache:"${here}/nimcache"` for
        // the bundle; the exporter was the half that did not. `client/nimcache`
        // is already gitignored by pattern.
        `--nimcache:${join(CLIENT, "nimcache", "selftest-export")}`,
        "src/static_export.nim",
      ],
      { cwd: CLIENT, maxBuffer: 64 * 1024 * 1024 },
    );
    return { built: true };
  } catch (err) {
    return { built: false, log: String(err.stderr ?? err.stdout ?? err).slice(-1500) };
  }
}

/** Run one journey and return its per-assertion records. Never an exit code. */
async function verdictFor(journey, assertion) {
  try {
    await run("node", [join(HERE, "run.mjs"), "--only", journey, "--json", REPORT], {
      cwd: REPO,
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch {
    /* a red journey exits 1; the verdict comes from the report, not from this */
  }
  const report = JSON.parse(await readFile(REPORT, "utf8").catch(() => "{}"));
  const j = (report.journeys ?? []).find((x) => x.id === journey);
  if (!j || !j.records) return { found: false };
  const hits = j.records.filter((r) => r.what.includes(assertion));
  if (hits.length !== 1) return { found: false, ambiguous: hits.length };
  // `vacuous` is carried through because a red that is only a poisoned
  // zero-against-zero is NOT a kill — see the verdict block below and
  // `harness.mjs`'s `#vacuityCheck`.
  return { found: true, ok: hits[0].ok, vacuous: !!hits[0].vacuous, detail: hits[0].detail };
}

/**
 * Is a previous run's mutation still sitting in the tree?
 *
 * THE RESTORE IS A `finally`, AND A `finally` DOES NOT RUN WHEN THE PROCESS IS
 * KILLED. A timeout, a Ctrl-C, an OOM, an agent's shell wrapper giving up at ten
 * minutes — any of those between the write and the restore leaves real product
 * source mutated on disk, and nothing downstream notices. Every later arm then
 * measures a defective tree: `before:` readings are taken against it, and an arm
 * whose assertion is already red is reported NEVER RAN for a reason that has
 * nothing to do with the arm.
 *
 * BOTH OF THIS REPOSITORY'S REAL INCIDENTS ARE THIS SHAPE, and neither was found
 * by the harness:
 *
 *   * `L/the-value-kind-is-misread` — `of tkInt: ""` reached `dev` inside a
 *     commit whose own message says "neither of them a behaviour change". Every
 *     integer local rendered blank until someone re-read the diff.
 *   * `K/the-served-values-stand` — left in a worktree when a selftest process
 *     was killed at a shell timeout, found by `git diff HEAD` and not by
 *     anything here.
 *
 * The test is exact rather than a dirty-tree check, because a dirty tree is
 * normal — an agent's own uncommitted work must not block the suite. A STRANDED
 * MUTATION has a signature no ordinary edit has: the arm's `find` is absent from
 * its file and the arm's `replace` is present. That is precisely "this file has
 * been through this arm and has not come back".
 *
 * Arms whose `replace` CONTAINS their `find` (the mutation appends rather than
 * substitutes) are unaffected: `find` is still there, so they cannot be flagged.
 *
 * Exit 2, never a verdict. A suite that measures a mutated tree is not a suite
 * that failed, it is one that did not run — and saying so is the whole of
 * Verification-Harness-Traps.md §1a's third verdict applied to the harness
 * itself rather than to the arms.
 */
async function strandedMutations() {
  const stranded = [];
  const seen = new Map();
  for (const arm of ARMS) {
    let text = seen.get(arm.file);
    if (text === undefined) {
      text = await readFile(arm.file, "utf8").catch(() => null);
      seen.set(arm.file, text);
    }
    if (text === null) continue;
    if (!text.includes(arm.find) && text.includes(arm.replace)) stranded.push(arm);
  }
  return stranded;
}

async function main() {
  const combineIdx = process.argv.indexOf("--combine");
  if (combineIdx >= 0) {
    const n = Number(process.argv[combineIdx + 1]);
    if (!Number.isInteger(n) || n < 1) {
      finish("did-not-run", "RESULT: DID NOT RUN — --combine needs the shard COUNT, e.g. `--combine 4`", 2);
      return;
    }
    combine(n);
    return;
  }
  if (shardIdx >= 0 && !shard) {
    finish("did-not-run", "RESULT: DID NOT RUN — --shard needs `i/n` with 1 <= i <= n, e.g. `--shard 2/4`", 2);
    return;
  }

  // `--list-shard i/n` — the arm ids this shard WOULD run, one per line, and
  // nothing else. No mutation, no build, no browser.
  //
  // It exists so that "every arm runs in exactly one shard, and the union is
  // the whole set" can be PROVED rather than trusted, in a second, without a
  // 280-minute sweep. `--combine` already refuses a union that is not exactly
  // the arm list, but that check only speaks after four shards have run — and
  // a partition defect discovered then has already cost the runner-hours. This
  // answers the same question before anything is spent, and it answers it
  // through `shardOf`, which is the function that does the slicing.
  //
  // `--list-arms` prints the full list, so the union can be compared against
  // the arm list itself rather than against a number.
  const listIdx = process.argv.indexOf("--list-shard");
  if (listIdx >= 0) {
    queryMode = true;
    if (!shardArg(process.argv[listIdx + 1])) {
      console.error("--list-shard needs `i/n` with 1 <= i <= n, e.g. `--list-shard 2/4`");
      process.exitCode = 2;
      return;
    }
    for (const a of shardOf(ARMS, shardArg(process.argv[listIdx + 1]))) console.log(a.id);
    return;
  }
  if (process.argv.includes("--list-arms")) {
    queryMode = true;
    for (const a of ARMS) console.log(a.id);
    return;
  }

  log("=== journey selftest — do the journeys bite? ===");
  log("    One mutation per arm, in real product source, each aimed at ONE");
  log("    assertion. An arm passes only if THAT assertion flips, and only if");
  log("    it was green before and is green again after.");
  log("");

  // WHAT HAPPENED LAST TIME, said out loud before anything else.
  //
  // A run killed by `SIGKILL`, an OOM or a lost machine cannot print its own
  // verdict — nothing of it runs. What it leaves is the journal, and this is
  // the only thing that reads it. Without this, the previous run's silence is
  // indistinguishable from nobody having run the suite at all, which is the
  // whole complaint this block exists to answer.
  const prev = previousRun();
  if (prev && prev.status === "running") {
    const done = (prev.arms ?? []).length;
    log(`the PREVIOUS run did not finish. It started ${prev.startedAt} and stopped`);
    log(`after ${done} of ${prev.planned ?? "?"} arm(s)` +
        (prev.lastArmStarted ? `, while running ${prev.lastArmStarted}.` : "."));
    log(`It printed no verdict, so it judged nothing — NOT a pass, and NOT a failure.`);
    if (done > 0) {
      const kills = prev.arms.filter((a) => a.verdict === "killed").length;
      log(`(what it did reach: ${kills} killed, ` +
          `${prev.arms.filter((a) => a.verdict === "survived").length} survived, ` +
          `${prev.arms.filter((a) => a.verdict === "never").length} never ran — ` +
          `over ${done} arm(s) only, and a verdict over a subset is not this suite's claim.)`);
    }
    log("");
  }

  // BEFORE ANYTHING IS MEASURED. See `strandedMutations` for the two incidents
  // this exists for; the second of them was created by killing this very file
  // at a shell timeout, so it is not a hypothetical.
  const stranded = await strandedMutations();
  if (stranded.length > 0) {
    log("a previous run's mutation is still in the tree, so nothing below would mean");
    log("anything — every `before:` reading would be taken against a defective product.");
    log("");
    for (const arm of stranded) {
      log(`  ${arm.id}`);
      log(`    ${arm.file}`);
      log(`    its \`find\` is absent and its \`replace\` is present, which is this arm`);
      log(`    applied and not restored.`);
    }
    log("");
    log("  remedy: restore those files, then re-run.");
    log("          `git diff HEAD -- <file>` shows it; `git checkout HEAD -- <file>`");
    log("          undoes it. Diff against HEAD and NOT against a branch ref —");
    log("          `origin/dev` moves under you while other agents push, and a diff");
    log("          against a moving base reports their commits as your damage.");
    log("");
    finish("did-not-run", "RESULT: DID NOT RUN", 2);
    return;
  }

  // `hydration: true`, ALWAYS. Not an optimisation to revisit: without it the
  // whole run is judged against whatever bundle was left in `dist/` by whoever
  // built last. See `artefactIdentity` for the two silent verdicts that buys.
  const base = await rebuild({ hydration: true });
  if (!base.built) {
    log("the unmutated tree does not build; nothing below would mean anything");
    log(base.log);
    finish("did-not-run", "RESULT: DID NOT RUN — the unmutated tree does not build", 2);
    return;
  }
  log(`baseline artefact: ${describe(await artefactIdentity())}`);
  log("");

  let killed = 0;
  let survived = 0;
  let neverRan = 0;

  // `--arm <substring>` runs a subset, matching `run.mjs --only`. Each arm
  // rebuilds the tree and re-runs its journey, so the full set is a long job
  // and landing one arm should not require re-proving nineteen others.
  //
  // The FULL set is what the suite claims, so a filtered run says so in its
  // own summary rather than reporting a pass over the arms it skipped.
  const armFilterIdx = process.argv.indexOf("--arm");
  const armFilter = armFilterIdx >= 0 ? process.argv[armFilterIdx + 1] : null;
  let arms = armFilter ? ARMS.filter((a) => a.id.includes(armFilter)) : ARMS;
  if (armFilter) {
    log(`--arm ${armFilter}: running ${arms.length} of ${ARMS.length} arm(s)`);
    log("");
    if (arms.length === 0) {
      finish("did-not-run", `RESULT: DID NOT RUN — no arm's id contains ${armFilter}`, 2);
      return;
    }
  }
  if (shard) {
    arms = shardOf(arms, shard);
    log(`--shard ${shard.i}/${shard.of}: running ${arms.length} of ${ARMS.length} arm(s)`);
    log(`  A SHARD IS NOT A RUN. Its verdict is about the arms it holds, and the`);
    log(`  suite's claim is the full set — \`--combine ${shard.of}\` makes it, or says`);
    log(`  which shard is missing.`);
    log("");
  }
  journal.planned = arms.length;
  journal.armFilter = armFilter;
  journal.shard = shard;
  writeJournal();

  // Recorded per arm, and reported as a table at the end. Not decoration: the
  // question "does one journey's arms dominate this suite's wall clock, and do
  // they belong in it" is only answerable from measurements, and a suite that
  // does not carry its own timings makes that a matter of opinion every time it
  // is asked. It also localises a stall — an arm that is running when the run
  // is killed is named in the journal, beside how long its neighbours took.
  const recordArm = (arm, verdict, startedAt) => {
    const seconds = Math.round((Date.now() - startedAt) / 1000);
    journal.arms.push({ id: arm.id, journey: arm.journey, verdict, seconds });
    journal.lastArmStarted = null;
    writeJournal();
    return seconds;
  };

  for (const arm of arms) {
    const started = Date.now();
    journal.lastArmStarted = arm.id;
    writeJournal();
    const needsBundle = await judgesHydratedArtefact(arm.journey);
    log(`--- ${arm.id}`);
    log(`    ${arm.why}`);
    if (needsBundle) {
      log(`    (its journey judges the hydrated artefact, so the bundle is rebuilt too)`);
    }
    log(`    target: ${arm.journey} :: "${arm.assertion}"`);

    const original = await readFile(arm.file, "utf8");
    const occurrences = original.split(arm.find).length - 1;
    if (occurrences !== 1) {
      log(`    NEVER RAN — the mutation site occurs ${occurrences} times, expected exactly 1`);
      log(`               (the source moved; this arm is describing a file that no longer exists)`);
      neverRan += 1;
      recordArm(arm, "never", started);
      log("");
      continue;
    }

    // 1. before
    const before = await verdictFor(arm.journey, arm.assertion);
    if (!before.found) {
      log(`    NEVER RAN — no single assertion matched that name on the unmutated tree`);
      // AND WHICH OF THE TWO WAYS IT MISSED. `verdictFor` matches with
      // `r.what.includes(assertion)` and treats any count but 1 as no match, so
      // "the assertion was renamed" and "a SECOND assertion's text now CONTAINS
      // this one" arrive here identically — and the second is a live hazard,
      // because every journey that grows a REAL-capture arm grows a set of
      // near-duplicate assertion texts. Naming the count turns a puzzling
      // NEVER RAN into a one-word diagnosis.
      if (before.ambiguous > 1) {
        log(`               AMBIGUOUS: ${before.ambiguous} assertions contain that text.`);
        log(`               An arm must name exactly one. Reword whichever assertion`);
        log(`               CONTAINS the other — a "REAL: " + verbatim copy is the usual cause.`);
      }
      neverRan += 1;
      recordArm(arm, "never", started);
      log("");
      continue;
    }
    if (!before.ok) {
      log(`    NEVER RAN — the assertion is ALREADY RED before the mutation`);
      log(`               (${before.detail})`);
      log(`               A mutation cannot demonstrate anything about an assertion that`);
      log(`               was not green to begin with.`);
      neverRan += 1;
      recordArm(arm, "never", started);
      log("");
      continue;
    }
    const beforeId = await artefactIdentity();
    log(`    before:  GREEN   on ${describe(beforeId)}`);

    // 2. mutate
    //
    // `inFlight` is set BEFORE the write and cleared in the `finally` beside
    // the restore, so a signal arriving anywhere in between has the file and
    // its original bytes to hand. The `finally` is still the normal path; this
    // is the one that exists because a `finally` does not run when the process
    // is signalled, and `K/the-served-values-stand` was left in a worktree by
    // exactly that.
    inFlight = { file: arm.file, original };
    await writeFile(arm.file, original.split(arm.find).join(arm.replace));
    let verdict;
    let mutatedId = beforeId;
    try {
      const built = await rebuild({ hydration: needsBundle });
      mutatedId = await artefactIdentity();
      if (built.built) log(`    mutated: ${describe(mutatedId)}`);
      if (built.built && sameArtefact(mutatedId, beforeId)) {
        // THE MUTATION DID NOT REACH THE ARTEFACT, so whatever the journey says
        // next is a statement about the unmutated build. Scored NEVER RAN and
        // not SURVIVED, because "survived" would be read as a fact about the
        // assertion — Verification-Harness-Traps.md §1a: killed, survived and
        // never-ran, and the third is the one an rc-based harness folds into
        // the first.
        log(`    NEVER RAN — the artefact is byte-identical to the unmutated one, so the`);
        log(`               mutation did not reach what the journey measures.`);
        log(`               Either the file is outside this build's graph, or the build`);
        log(`               that would carry it was not run (a bundle arm whose journey`);
        log(`               reports needsEngine === false rebuilds no bundle).`);
        verdict = "never";
      } else if (!built.built) {
        log(`    NEVER RAN — the mutated tree did not compile, so nothing was measured`);
        log(`               ${built.log.split("\n").slice(-3).join(" / ")}`);
        verdict = "never";
      } else {
        const after = await verdictFor(arm.journey, arm.assertion);
        if (!after.found) {
          log(`    NEVER RAN — the assertion vanished from the mutated run`);
          verdict = "never";
        } else if (after.ok) {
          log(`    SURVIVED — the assertion is still GREEN with the defect in place.`);
          log(`               ${after.detail}`);
          verdict = "survived";
        } else if (after.vacuous) {
          // THE FOURTH WAY TO LEARN NOTHING, and it wears a kill's clothes. The
          // assertion went red, but it went red because its own journey had
          // ALREADY failed somewhere upstream and the harness refused to count
          // its zero-against-zero as green (`harness.mjs`, `#vacuityCheck`).
          // That is a fact about the run, not about the mutation: the mutation
          // may have done nothing at all. Scoring it KILLED would certify the
          // assertion as biting on evidence that it never saw the defect —
          // "an assertion certified as biting when it does not", which this
          // file's own header calls the worse of the two false verdicts.
          log(`    NEVER RAN — the assertion went red only as a VACUITY: its journey had`);
          log(`               already failed upstream, so its set was empty and the`);
          log(`               harness refused the zero-against-zero. The mutation was not`);
          log(`               judged. Fix the upstream red first, then re-run this arm.`);
          log(`               ${after.detail}`);
          verdict = "never";
        } else {
          log(`    KILLED   — ${after.detail}`);
          verdict = "killed";
        }
      }
    } finally {
      // 3. restore, byte-for-byte, whatever happened above
      await writeFile(arm.file, original);
      inFlight = null;
    }

    // 4. and prove the restore took
    const restored = await rebuild({ hydration: needsBundle });
    const restoredId = await artefactIdentity();
    if (!sameArtefact(restoredId, beforeId)) {
      // The SOURCE is restored byte-for-byte above; this says the ARTEFACT came
      // back too. They are not the same claim — a build that silently reused a
      // stale object file, or a `nim js` that exited 0 without writing, leaves
      // the source correct and the tree measuring something else, and every arm
      // after this one would inherit it.
      log(`    NEVER RAN — the artefact did not come back: ${describe(restoredId)}`);
      log(`               was ${describe(beforeId)}`);
      verdict = "never";
    }
    const back = restored.built ? await verdictFor(arm.journey, arm.assertion) : { found: false };
    if (!back.found || !back.ok) {
      log(`    NEVER RAN — the assertion did not come back green after restoring, so the`);
      log(`               red above cannot be attributed to the mutation`);
      verdict = "never";
    } else {
      log(`    after:   GREEN again on ${describe(restoredId)}`);
    }

    if (verdict === "killed") killed += 1;
    else if (verdict === "survived") survived += 1;
    else neverRan += 1;
    const seconds = recordArm(arm, verdict, started);
    log(`    took ${seconds}s`);
    log("");
  }

  // Every arm rebuilds the tree and reruns its journey THREE times — before,
  // mutated, restored — so an arm costs three runs of one journey plus two
  // builds, and a journey that is slow is slow eight times over if eight arms
  // point at it. Printed as a table because the alternative is arguing about
  // it: the suite's own numbers decide whether one journey's arms dominate.
  timingTable(journal.arms);

  log(`${arms.length} arm(s): ${killed} killed, ${survived} survived, ${neverRan} never ran`);
  if (armFilter || shard) log(`(partial run — ${ARMS.length - arms.length} arm(s) not exercised)`);
  if (killed !== arms.length) {
    // Named, not counted. "Some arm is not killed" sends the reader back
    // through the log; the arms that are not killed are known here, and a dead
    // arm is the finding this suite exists to produce.
    for (const a of journal.arms.filter((x) => x.verdict !== "killed")) {
      log(`  ${a.verdict === "survived" ? "SURVIVED " : "NEVER RAN"}  ${a.id}`);
    }
    finish(
      "failed",
      armFilter || shard
        ? "RESULT: FAILED — over this subset only; the full set is still this suite's claim"
        : "RESULT: FAILED — every arm must be killed by the assertion written for it",
      1,
    );
    return;
  }
  log("  Each journey reddens on the defect it exists to catch, and only then.");
  // A partial run still exits 0 — `--arm` is the supported way to land one arm
  // without re-proving sixty-one others, and a shard is one leg of a run that
  // does not fit in one box — but neither gets to print the same word as a full
  // run. The suite's claim is the full set, and "OK" over a subset is the
  // sentence someone quotes later.
  finish(
    "ok",
    shard
      ? `RESULT: OK OVER SHARD ${shard.i}/${shard.of} (${arms.length} of ${ARMS.length} arms).` +
          ` The suite's claim needs \`--combine ${shard.of}\`.`
      : armFilter
        ? `RESULT: OK OVER ${arms.length} OF ${ARMS.length} ARMS — a filtered run. The full set is` +
            " this suite's claim, and it has NOT been made here."
        : "RESULT: OK",
    0,
  );
}

main().catch((e) => {
  // A verdict, not just a stack. This path used to print the stack and nothing
  // else, so a `playwright is not installed` — which judges nothing — left a log
  // ending in an exception and no `RESULT:` line at all: the exact shape that
  // reads to a human like a suite nobody ran.
  console.error(String(e && e.stack ? e.stack : e));
  restoreInFlight();
  finish("did-not-run", `RESULT: DID NOT RUN — the run threw ${progressSoFar()}`, 2);
});
