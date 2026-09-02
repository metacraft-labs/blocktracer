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
// THE ASSERTION IS NAMED, NOT COUNTED
// -----------------------------------
// An arm passes only if the assertion WRITTEN FOR IT flipped. "The journey went
// red" is satisfied by a mutation that broke some other assertion — a mutation
// that removes the source pane reddens the position check too, and would score
// a kill it did not earn.

import { readFile, writeFile, readdir } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const run = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");
const CLIENT = join(REPO, "client");
const REPORT = join(HERE, ".selftest-report.json");

/**
 * The arms.
 *
 * `find` must occur EXACTLY ONCE in the file — asserted before the edit. A
 * mutation applied twice, or to a line that moved, is a different experiment
 * from the one described here, and a `replaceAll` would hide that.
 */
const ARMS = [
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
    assertion: "the session's reported step is the step the event-log row named",
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
];

const log = (s = "") => console.log(s);

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

async function rebuild({ hydration = false } = {}) {
  // The exporter is always rebuilt. The hydration BUNDLE is rebuilt only for
  // arms whose journey judges it, because `nim js` over `hydrate.nim` costs
  // about a minute and most arms cannot affect what it measures.
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
  return { found: true, ok: hits[0].ok, detail: hits[0].detail };
}

async function main() {
  log("=== journey selftest — do the journeys bite? ===");
  log("    One mutation per arm, in real product source, each aimed at ONE");
  log("    assertion. An arm passes only if THAT assertion flips, and only if");
  log("    it was green before and is green again after.");
  log("");

  const base = await rebuild();
  if (!base.built) {
    log("the unmutated tree does not build; nothing below would mean anything");
    log(base.log);
    process.exitCode = 2;
    return;
  }

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
  const arms = armFilter ? ARMS.filter((a) => a.id.includes(armFilter)) : ARMS;
  if (armFilter) {
    log(`--arm ${armFilter}: running ${arms.length} of ${ARMS.length} arm(s)`);
    log("");
    if (arms.length === 0) {
      log(`RESULT: FAILED — no arm's id contains ${armFilter}`);
      process.exitCode = 2;
      return;
    }
  }

  for (const arm of arms) {
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
      log("");
      continue;
    }
    if (!before.ok) {
      log(`    NEVER RAN — the assertion is ALREADY RED before the mutation`);
      log(`               (${before.detail})`);
      log(`               A mutation cannot demonstrate anything about an assertion that`);
      log(`               was not green to begin with.`);
      neverRan += 1;
      log("");
      continue;
    }
    log(`    before:  GREEN`);

    // 2. mutate
    await writeFile(arm.file, original.split(arm.find).join(arm.replace));
    let verdict;
    try {
      const built = await rebuild({ hydration: needsBundle });
      if (!built.built) {
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
        } else {
          log(`    KILLED   — ${after.detail}`);
          verdict = "killed";
        }
      }
    } finally {
      // 3. restore, byte-for-byte, whatever happened above
      await writeFile(arm.file, original);
    }

    // 4. and prove the restore took
    const restored = await rebuild({ hydration: needsBundle });
    const back = restored.built ? await verdictFor(arm.journey, arm.assertion) : { found: false };
    if (!back.found || !back.ok) {
      log(`    NEVER RAN — the assertion did not come back green after restoring, so the`);
      log(`               red above cannot be attributed to the mutation`);
      verdict = "never";
    } else {
      log(`    after:   GREEN again`);
    }

    if (verdict === "killed") killed += 1;
    else if (verdict === "survived") survived += 1;
    else neverRan += 1;
    log("");
  }

  log(`${arms.length} arm(s): ${killed} killed, ${survived} survived, ${neverRan} never ran`);
  if (armFilter) log(`(filtered run — ${ARMS.length - arms.length} arm(s) not exercised)`);
  if (killed !== arms.length) {
    log("RESULT: FAILED — every arm must be killed by the assertion written for it");
    process.exitCode = 1;
    return;
  }
  log("  Each journey reddens on the defect it exists to catch, and only then.");
  log("RESULT: OK");
}

main().catch((e) => {
  console.error(String(e && e.stack ? e.stack : e));
  process.exitCode = 1;
});
