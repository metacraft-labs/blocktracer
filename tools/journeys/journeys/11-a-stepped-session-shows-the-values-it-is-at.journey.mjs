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

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-stepped-session-shows-the-values-it-is-at";
export const claim = "A visitor who steps sees the values at the new position.";
export const spec = "Page-Descriptions.md §7.0, §14 — BlockTracer";
export const assertions = 9;
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

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(sessions, 3, "transactions whose landing is a session with rows in its Code pane");

  const subject = sessions.find((t) => !t.real) ?? sessions[0];
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
    const readings = [await settledReading(page)];
    for (let i = 0; i < WALK; i++) {
      const before = await readFacts(page);
      await page.click('[data-action="step-forward"]');
      // A predicate, never a sleep. The POSITION first — a fixed sleep is how a
      // suite comes to measure the machine it runs on — and then the pane,
      // which the engine answers one round trip behind it.
      const deadline = Date.now() + 15000;
      while (Date.now() < deadline) {
        if ((await readFacts(page)).step !== before.step) break;
        await page.waitForTimeout(150);
      }
      readings.push(await settledReading(page));
    }

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
}
