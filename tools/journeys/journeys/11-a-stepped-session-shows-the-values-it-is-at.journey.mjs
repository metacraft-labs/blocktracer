// "A visitor who steps sees the values at the new position."
//
// Page-Descriptions.md §7.0 ("hydration is what turns a POSITIONED first frame
// into a STEPPING one" — and every pane it turns, not four of five) and §14's
// rule that a pane with nothing in it must say why.
//
// WHAT WAS ON SCREEN BEFORE THIS JOURNEY EXISTED
// ----------------------------------------------
// The values of the frame the page was SERVED at, for the life of the tab,
// under whatever position the visitor had stepped to. Not a blank pane and not
// an error — ten rows of real-looking names, types and numbers, belonging to a
// frame the session had left. `StateVM` asks the engine for locals on every
// move (`state_vm.nim:575`), the engine answers (`dap_handler.rs:955`), and the
// pinned store's `requestLocals` discarded the reply — so `currentVariables`
// was empty for every hydrated session, `hydrate.nim`'s PaneLatch never fired
// for the State pane, and the statically exported one was never replaced.
//
// That is why this journey exists as a SEPARATE sentence from journey 03's.
// Both are about stepping. 03 asks whether the position moves; every assertion
// in it was green while the Values pane was showing another frame's numbers,
// because a position is not a value. A pane that is confidently wrong is
// strictly worse than one that is empty, and nothing in this repository could
// see the difference.
//
// THE TRAP THIS JOURNEY IS WRITTEN AGAINST
// ----------------------------------------
// Journey 07's first version asserted `valuesShown >= 1` as its non-vacuity
// control and concluded there was something live to work with. Those rows were
// the served frame's fixture text: the guard was satisfied by exactly the
// artefact whose persistence was the defect, so the journey could not have
// detected the thing it was written for.
//
// So "the pane has rows" is never the verdict here. The served frame is read
// FIRST, with scripting off — the bytes the exporter wrote, before the bundle
// runs — and every subsequent reading is judged against it. A pane that still
// says what the exporter said is a FAILURE however full it looks.
//
// WHY THE VERDICT IS A WALK AND NOT ONE STEP
// ------------------------------------------
// Two adjacent positions can legitimately have the same locals — a step within
// an expression changes the line and nothing else — so "the values changed
// after one click" is a claim about the trace, not about the product, and a
// journey asserting it would be red on a correct build whenever the corpus
// changed. The session is walked instead, and the claim is over the walk: the
// pane's contents are a FUNCTION OF THE POSITION, so a walk that visits several
// positions reads several panes. The number of positions visited is a counted
// control, so a walk that failed to move cannot satisfy it vacuously.
//
// NOTHING BELOW NAMES A VALUE. Not a variable, not a number, not a type, not a
// step. Rule 4: the fixture must not supply the answer. Every expectation is a
// relation between two things the page itself reported.
//
// AND IT IS DRIVEN OVER BOTH KINDS OF RECORDING
// ---------------------------------------------
// This file carried the same subject-selection defect journeys 03, 09, 07, 02
// and 06 did — the sixth occurrence, and the last one in this directory:
//
//     sessions.find((t) => !t.real) ?? sessions[0]
//
// PREFERS a synthetic fixture, and the corpus has 15 of them, so the `??` arm
// could never run. So the journey written to catch a pane frozen on the served
// frame had only ever watched the demo chain — over a defect whose cause,
// `requestLocals` discarding its reply, was upstream of both and identical for
// both.
//
// It was worth measuring rather than assuming. A chain recording is rung 3 and
// carries no variable names, and the reasonable expectation was that its Values
// pane could only ever be §14's sentence. It is not: the engine answers with
// the AVM's own machine state, so the walk reads 70 engine-supplied rows across
// 14 distinct sets of values over 15 positions, none of them blank and none of
// them the exporter's. The claim holds on both kinds of recording, and until
// now it had only ever been asked of one.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-stepped-session-shows-the-values-it-is-at";
export const claim = "A visitor who steps sees the values at the new position.";
export const spec = "Page-Descriptions.md §7.0, §14 — BlockTracer";
export const assertions = 3 + 8 + 8;
export const needsEngine = true;

/** How many times the session is stepped. See the header for why it is a walk. */
const WALK = 14;

/** One reading of the Values pane, reduced to what a visitor could read off it. */
const reading = (facts) => ({
  step: facts.step,
  rows: facts.stateRows.length,
  cells: facts.stateRows,
  // The READING, not the markup. A class change elsewhere must not present as
  // "the engine supplied different values".
  text: facts.stateRows.map((r) => `${r.name}=${r.value}:${r.type}`).join(" | "),
  note: facts.stateNote,
});

/**
 * Read the Values pane once it has stopped changing.
 *
 * The wait is for STABILITY, not for a particular sentence. A harness that
 * waited for the pane to stop saying some specific string would be asserting
 * the product's copy from inside its own timing loop, and would hang —
 * reporting a product failure — the day that string changed.
 *
 * It is used for the LANDING reading as well as for each step, and that is not
 * symmetry for its own sake. `phase=ready` is published by `goLive`, which
 * deliberately renders the controls and NOT the panes: at that instant the
 * engine has answered `threads` and has not yet produced a position, so the
 * served pane is still on screen and is CORRECTLY still on screen. A journey
 * that took its first reading there would call §7.0's own guarantee a defect.
 */
async function settledReading(page, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  let facts = await readFacts(page);
  let seen = JSON.stringify(reading(facts));
  let stable = 0;
  while (Date.now() < deadline && stable < 3) {
    await page.waitForTimeout(150);
    facts = await readFacts(page);
    const now = JSON.stringify(reading(facts));
    stable = now === seen ? stable + 1 : 0;
    seen = now;
  }
  return reading(facts);
}

/** The served frame's Values pane: the same URL with scripting off. */
async function servedPane(browser, origin, path) {
  // `javaScriptEnabled` is a CONTEXT option in Playwright, not a page method.
  // A served reading taken with the bundle still running would compare the
  // hydrated page against itself and report "unchanged" for every session.
  const ctx = await browser.newContext({ javaScriptEnabled: false });
  try {
    const page = await ctx.newPage();
    await page.goto(origin + path, { waitUntil: "domcontentloaded", timeout: 45000 });
    return reading(await readFacts(page));
  } finally {
    await ctx.close();
  }
}

/**
 * Walk the session, taking a settled reading at the landing and after each step.
 *
 * One implementation for both arms. Two hand-written walks would let the demo
 * and the chain arm drift in how long they wait, and a difference there reads
 * as a difference in the product.
 */
async function walk(page) {
  const readings = [await settledReading(page)];
  for (let i = 0; i < WALK; i++) {
    const before = await readFacts(page);
    await page.click('[data-action="step-forward"]');
    // A predicate, never a sleep. The POSITION first — a fixed sleep is how a
    // suite comes to measure the machine it runs on — and then the pane, which
    // the engine answers one round trip behind it.
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      if ((await readFacts(page)).step !== before.step) break;
      await page.waitForTimeout(150);
    }
    readings.push(await settledReading(page));
  }
  return readings;
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(sessions, 3, "transactions whose landing is a session with rows in its Code pane");

  // TWO SUBJECT LISTS, EACH ASSERTED NON-EMPTY, AND NO FALLBACK BETWEEN THEM —
  // see the header.
  const synthetic = sessions.filter((t) => !t.real);
  const realCaptures = sessions.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the demo arm has a subject");
  j.atLeast(
    realCaptures.length,
    1,
    "SUBJECTS: REAL-capture sessions, so the chain arm has a subject",
  );

  const subject = synthetic[0];
  j.note(`driving ${subject.debugPath}`);

  const served = await servedPane(browser, site.origin, subject.debugPath);
  j.note(`served frame: ${served.rows} Values rows`);

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session went live, so the Values pane on screen is the bundle's to write",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );

    // NON-VACUITY, and the reason it is stated as a count. Comparing a live
    // pane against an EMPTY served pane would report "different" for a reason
    // that has nothing to do with the engine, and every verdict below would be
    // green over a session that never loaded a value in its life.
    j.atLeast(
      served.rows,
      1,
      `CONTROL: the served frame already shows Values rows, so "not the served frame's" is a measurement`,
    );

    // The walk. Every reading a visitor could have taken, starting with the one
    // the landed session shows before any click.
    const readings = await walk(page);

    const positions = new Set(readings.map((r) => r.step));
    // DISTINCT SETS OF VALUES, and the word "values" is load-bearing.
    //
    // The first version of this counted distinct PANES — readings reduced to
    // their rows or, where there were none, to their sentence. The selftest
    // arm that discards the reply survived it: with no values at all the pane
    // still shows two different sentences over a walk ("reading the values
    // here" and "there are none here"), and two sentences satisfied "the pane
    // changed". A pane that never shows a value is exactly the defect, and the
    // assertion written for it counted its way to green.
    //
    // Empty readings are therefore excluded rather than mapped to their text:
    // this counts what the ENGINE supplied, and a walk on which it supplied
    // nothing has a count of zero.
    const valueSets = new Set(readings.filter((r) => r.rows > 0).map((r) => r.text));

    // CONTROL ON THE WALK. Not the verdict — the proof that the session
    // actually moved, so that a red verdict below is a statement about the
    // Values pane and not about a toolbar this suite failed to press. Journey
    // 03 owns "does stepping move the position"; this only needs to know that
    // it did.
    j.atLeast(
      positions.size,
      3,
      `CONTROL: the walk moved the session through distinct positions (${[...positions].join(" → ")})`,
    );

    // THE STALENESS VERDICT. Not one reading the visitor could have taken is
    // the pane the exporter wrote. This is the defect in its own words: the
    // served frame's values, standing under a position the session has left.
    const stale = readings.filter((r) => r.rows > 0 && r.text === served.text);
    j.countIs(
      stale.length,
      0,
      "no reading of the Values pane is the SERVED frame's values",
    );

    // THE HONESTY VERDICT. §14: a pane with nothing in it must say why. Every
    // reading is either the engine's rows or a sentence about why there are
    // none — never blank, and never the previous position's values left
    // standing because there was nothing to replace them with.
    const mute = readings.filter((r) => r.rows === 0 && r.note.length === 0);
    j.countIs(
      mute.length,
      0,
      "every reading is either values or a sentence saying why there are none",
    );

    // THE VERDICT PROPER. The values are a function of the position: a session
    // walked across several positions shows more than one set of them. One
    // distinct set over a walk of several positions is what a frozen pane looks
    // like — whether it is frozen on the served frame, or on the first frame
    // the engine answered for; zero is what a session with no live values at
    // all looks like.
    j.atLeast(
      valueSets.size,
      2,
      `the values the pane shows change as the session moves: ` +
        `${valueSets.size} distinct sets of values over ${positions.size} positions`,
    );

    // AND THE VALUES ARE VALUES. A row that carries a name and an empty value
    // is a row that says nothing, and it is exactly what a mis-read wire format
    // produces: the reply parsed, the names taken, every value blank. The
    // engine's `Value` is a flat tagged record whose `kind` is a NUMERIC
    // ordinal, and the pinned SDK's own comment on those ordinals is wrong for
    // six of the ten kinds it lists — so this is a mistake with a precedent in
    // the tree, not a hypothetical.
    //
    // Counted over every row of every reading rather than off the final page:
    // a walk that happens to end on a frame with no locals would satisfy "no
    // blank cells" over nothing.
    const cells = readings.flatMap((r) => r.cells);
    const blank = cells.filter((c) => !c.name || !c.value);
    j.atLeast(
      cells.length,
      1,
      `CONTROL: the walk read ${cells.length} engine-supplied Values rows in total`,
    );
    j.countIs(
      blank.length,
      0,
      "every row the pane draws carries both a name and a value",
    );
  } finally {
    await page.close();
  }

  // ── THE CHAIN CAPTURE ─────────────────────────────────────────────────
  await realArm(browser, site, j, realCaptures[0]);
}

/**
 * The same claim, over a REAL capture.
 *
 * WHAT IS DIFFERENT ABOUT THE SUBJECT, AND WHAT IS NOT
 * ----------------------------------------------------
 * The served frame. A chain recording carries no variable names, so what the
 * exporter writes into its Values pane is not ten rows — it is §14's sentence,
 * verbatim: "This recording carries no variable names. Naming a local needs the
 * debug symbols from the contract's compiled artifact, and none resolved for
 * this contract." So the demo arm's non-vacuity control ("the served frame
 * already shows Values rows") is false here for a correct reason, and this arm
 * states the control the subject actually supports: the served pane SAYS
 * something, rows or sentence.
 *
 * Everything else is the same claim and is asserted the same way — and it is
 * substantive, which was not obvious before it was measured. A rung-3 recording
 * has no source-level locals and the engine still answers with the AVM's own
 * machine state, so the walk reads real, changing, engine-supplied values:
 * measured over 15 positions, 14 distinct sets, 70 rows, none blank, none of
 * them the served frame's.
 *
 * The assertion texts are worded so that no text CONTAINS another — three
 * `selftest.mjs` arms target this journey by name, and a "REAL: " + verbatim
 * copy would resolve each of them to two records and silently stop all three
 * from running.
 */
async function realArm(browser, site, j, subject) {
  j.note(`driving REAL capture ${subject.debugPath}`);

  const served = await servedPane(browser, site.origin, subject.debugPath);
  j.note(
    `REAL served frame: ${served.rows} Values rows, note ${JSON.stringify(served.note.slice(0, 60))}`,
  );

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "REAL: the chain capture's session went live, so its Values pane is the bundle's",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );

    // NON-VACUITY, in the form this subject supports. The demo arm counts
    // served ROWS; a chain capture's served pane is a sentence, and a pane that
    // said NOTHING would make every verdict below green for a reason that has
    // nothing to do with the engine.
    j.atLeast(
      served.rows + (served.note.trim().length > 0 ? 1 : 0),
      1,
      `REAL CONTROL: the served frame states its Values pane (${served.rows} rows, ${served.note.trim().length} chars of sentence)`,
    );

    const readings = await walk(page);
    const positions = new Set(readings.map((r) => r.step));
    const valueSets = new Set(readings.filter((r) => r.rows > 0).map((r) => r.text));

    j.atLeast(
      positions.size,
      3,
      `REAL CONTROL: the walk moved the chain session through distinct positions (${[...positions].join(" → ")})`,
    );

    const stale = readings.filter((r) => r.rows > 0 && r.text === served.text);
    j.countIs(
      stale.length,
      0,
      "REAL: not one reading of the chain capture's pane is the frame the exporter wrote",
    );

    const mute = readings.filter((r) => r.rows === 0 && r.note.length === 0);
    j.countIs(mute.length, 0, "REAL: every reading is values or a sentence saying why there are none");

    j.atLeast(
      valueSets.size,
      2,
      `REAL: the values change as the chain session moves: ${valueSets.size} distinct sets over ${positions.size} positions`,
    );

    const cells = readings.flatMap((r) => r.cells);
    const blank = cells.filter((c) => !c.name || !c.value);
    j.atLeast(
      cells.length,
      1,
      `REAL CONTROL: the walk read ${cells.length} engine-supplied rows from the chain capture`,
    );
    j.countIs(blank.length, 0, "REAL: every row carries both a name and a value");
  } finally {
    await page.close();
  }
}
