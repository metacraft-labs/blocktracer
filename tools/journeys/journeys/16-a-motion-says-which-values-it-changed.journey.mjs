// "A visitor who moves is shown which values the motion changed."
//
// Debugger-Integration §4.2 (the pane's job is to mark change) and
// Page-Descriptions.md §7.0 (hydration turns a positioned frame into a stepping
// one — and stepping is the thing the mark is about).
//
// WHY A TIME-TRAVEL DEBUGGER CAN DO THIS AND OTHERS CANNOT
// -------------------------------------------------------
// The position you came from is still queryable, so the diff needs no extra
// recording and no second request: `LocalsFeed` has already held the previous
// position's values on the way past, and captures them as the baseline at the
// one moment the identity of "the position you came from" is knowable — the
// request for the NEW position going out while `forTicks` still names the old.
//
// FOUR DECISIONS, EACH ASSERTED HERE RATHER THAN STATED
// -----------------------------------------------------
// 1. CHANGED MEANS "DIFFERS FROM THE POSITION YOU CAME FROM", for every motion
//    and in both directions. Not "written by this line", not per-tick. Every
//    motion this product offers has a reverse, and the mark has to mean the
//    same thing coming back as it did going in.
// 2. THE COLOUR IS NEUTRAL — changed vs unchanged, never increase vs decrease.
//    A backward step reverses the sense of any directional encoding, so a
//    red/green reading would be wrong on half the motions on the toolbar. That
//    is why this file asserts a MEMBERSHIP (which rows are marked) and never a
//    direction: there is no direction to assert, by design.
// 3. A LONG MOTION MAY MARK EVERYTHING, AND THAT IS CORRECT. Asserted rather
//    than hoped: where every row on screen is marked, every row must still
//    carry its name and its value and the pane must still be a pane. A frame in
//    which everything changed should read as "everything here is different",
//    not as a pane that has broken.
// 4. A NAME THAT WAS NOT IN SCOPE IS "APPEARED", NOT "CHANGED". There is no
//    previous value for it to differ from, and a reader told "changed" would go
//    looking for one. It is the ordinary case on a step INTO a call.
//
// THE FALSE PASS THIS FILE IS WRITTEN AGAINST
// -------------------------------------------
// "A highlight class is present" proves nothing whatsoever. It is satisfied by
// a pane that marks every row, by one that marks a row at random, and — the
// case that actually shipped — by one that marked whichever row the ViewModel
// had SELECTED, under a stylesheet that says "changed". Nor is "some rows are
// marked and some are not" enough: that is satisfied by any arbitrary split.
//
// So the verdict is an EQUALITY OF SETS, taken over a step on which some values
// changed and some did not. A step where everything changed, or nothing did,
// cannot tell a working diff from a blanket highlight, so the existence of a
// mixed step is a counted control of its own — and the marked set is compared
// against a set this journey computes from its OWN two readings of the pane,
// never against anything a fixture supplied.
//
// NOTHING BELOW NAMES A VALUE, A VARIABLE, A STEP OR A TRANSACTION. Rule 4.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-motion-says-which-values-it-changed";
export const claim = "A visitor who moves is shown which values the motion changed.";
export const spec = "Debugger-Integration.md §4.2, Page-Descriptions.md §7.0 — BlockTracer";
// 3 subject counts, 7 per arm over two arms, and 7 taken across both walks
// together — the mixed step, the name that arrived, and the everything-marked
// reading are each rarer than one walk can be relied on to produce.
export const assertions = 3 + 2 * 7 + 6;
export const needsEngine = true;

const WALK = 8;

/** One settled reading of the Values pane, as a visitor could read it. */
const paneOf = (facts) => ({
  step: facts.step,
  rows: facts.stateRows,
  note: facts.stateNote,
});

/** Wait for the pane to stop changing. A predicate, never a sleep. */
async function settled(page, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  let seen = "";
  let stable = 0;
  let facts = await readFacts(page);
  while (Date.now() < deadline && stable < 3) {
    await page.waitForTimeout(130);
    facts = await readFacts(page);
    const now = JSON.stringify(paneOf(facts));
    stable = now === seen ? stable + 1 : 0;
    seen = now;
  }
  return paneOf(facts);
}

async function walk(page) {
  const readings = [await settled(page)];
  for (let i = 0; i < WALK; i++) {
    const before = await readFacts(page);
    await page.click('[data-action="step-forward"]');
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      if ((await readFacts(page)).step !== before.step) break;
      await page.waitForTimeout(90);
    }
    readings.push(await settled(page));
  }
  return readings;
}

/**
 * Judge one transition, from THIS journey's own two readings of the pane.
 *
 * The expected sets are computed from what the page reported at the previous
 * position and at this one. Nothing here consults a fixture, and nothing
 * consults the marks in order to decide what the marks should be.
 *
 * Transitions out of a position that showed no rows are not judged: with no
 * previous values there is nothing for the product to diff against, and the
 * feed correctly marks nothing. Judging them would be asserting a claim the
 * product deliberately does not make — and the COUNT of judged transitions is
 * asserted below, so excluding them cannot quietly empty the verdict.
 */
function judge(prev, cur) {
  if (prev.rows.length === 0 || cur.rows.length === 0) return null;
  const was = new Map(prev.rows.map((r) => [r.name, r.value]));
  const expectChanged = new Set();
  const expectAppeared = new Set();
  const expectUnmarked = new Set();
  for (const r of cur.rows) {
    if (!was.has(r.name)) expectAppeared.add(r.name);
    else if (was.get(r.name) !== r.value) expectChanged.add(r.name);
    else expectUnmarked.add(r.name);
  }
  const markedChanged = new Set(cur.rows.filter((r) => r.changed).map((r) => r.name));
  const markedAppeared = new Set(cur.rows.filter((r) => r.appeared).map((r) => r.name));
  const both = cur.rows.filter((r) => r.changed && r.appeared).map((r) => r.name);

  const diff = (a, b) => [...a].filter((x) => !b.has(x));
  return {
    step: cur.step,
    rows: cur.rows.length,
    expectChanged,
    expectAppeared,
    expectUnmarked,
    markedChanged,
    markedAppeared,
    // Marked but should not be — the "blanket highlight" failure.
    overMarked: diff(markedChanged, expectChanged).concat(diff(markedAppeared, expectAppeared)),
    // Should be marked and is not — the "the feature does nothing" failure.
    underMarked: diff(expectChanged, markedChanged).concat(diff(expectAppeared, markedAppeared)),
    // An unchanged row wearing either mark.
    markedUnchanged: [...expectUnmarked].filter(
      (n) => markedChanged.has(n) || markedAppeared.has(n),
    ),
    both,
    mixed: expectChanged.size > 0 && expectUnmarked.size > 0,
  };
}

/** One arm: drive a session, walk it, and judge every transition. */
async function arm(browser, site, j, subject, tag) {
  j.note(`${tag}: driving ${subject.debugPath}`);
  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      `${tag}: the session went live, so the marks on screen are the bundle's`,
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );
    const readings = await walk(page);
    const positions = new Set(readings.map((r) => r.step));
    j.atLeast(
      positions.size,
      3,
      `${tag}: CONTROL — the walk moved through distinct positions (${[...positions].join(" → ")})`,
    );

    const verdicts = [];
    for (let i = 1; i < readings.length; i++) {
      const v = judge(readings[i - 1], readings[i]);
      if (v) verdicts.push(v);
    }
    const judged = verdicts.reduce((a, v) => a + v.rows, 0);
    const differed = verdicts.reduce((a, v) => a + v.expectChanged.size, 0);
    const arrived = verdicts.reduce((a, v) => a + v.expectAppeared.size, 0);
    const held = verdicts.reduce((a, v) => a + v.expectUnmarked.size, 0);
    j.atLeast(
      verdicts.length,
      1,
      `${tag}: CONTROL — transitions with values on both sides, so there is something to judge`,
    );
    // THE BREAKDOWN IS IN THE MESSAGE BECAUSE ONE OF THESE SETS CAN BE EMPTY,
    // and an empty set makes the verdict below it pass over nothing. It is not
    // hypothetical: this walk's source-level arm changes no value IN PLACE —
    // every mark it produces is a name arriving — so `differed` is 0 there and
    // "every row whose value differs carries a mark" is vacuously true on that
    // arm. A mutation arm aimed at it SURVIVED, correctly, and said so.
    //
    // The claim is not weakened by that, because the non-vacuity control for it
    // is taken across BOTH walks below (the mixed step, which requires a
    // non-empty changed set by construction). What would be wrong is leaving a
    // reader to assume this arm's zero was a measurement. It prints the size of
    // what it quantified over.
    j.atLeast(
      judged,
      1,
      `${tag}: CONTROL — rows judged across the walk (${verdicts.length} transitions:` +
        ` ${differed} differed, ${arrived} arrived, ${held} held their value)`,
    );

    // THE TWO DIRECTIONS, SEPARATELY. Over-marking and under-marking are
    // different defects with different causes and neither implies the other: a
    // blanket highlight has zero under-marked rows, and a feature that does
    // nothing has zero over-marked ones.
    const over = verdicts.flatMap((v) => v.overMarked);
    const under = verdicts.flatMap((v) => v.underMarked);
    j.countIs(
      over.length,
      0,
      `${tag}: no row is marked whose value did not differ from the previous position`,
    );
    j.countIs(
      under.length,
      0,
      `${tag}: every row whose value differs from the previous position carries a mark`,
    );
    j.countIs(
      verdicts.flatMap((v) => v.both).length,
      0,
      `${tag}: no row carries both marks at once`,
    );

    return { readings, verdicts };
  } finally {
    await page.close();
  }
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(sessions, 3, "transactions whose landing is a session with rows in its Code pane");

  // TWO LISTS, EACH ASSERTED, NO `??` BETWEEN THEM — and BOTH driven. They are
  // not interchangeable here. A source-level recording steps INTO frames, so it
  // is where a name arrives that was not in scope; a rung-3 chain capture
  // reports the machine's own state, whose rows persist across every step and
  // change a few at a time, so it is where a MIXED step is reliable. Each arm
  // supplies the subject the other cannot.
  const synthetic = sessions.filter((t) => !t.real);
  const realCaptures = sessions.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the source-level arm has a subject");
  j.atLeast(realCaptures.length, 1, "SUBJECTS: REAL-capture sessions, so the chain arm has a subject");

  const a = await arm(browser, site, j, synthetic[0], "SOURCE-LEVEL");
  const b = await arm(browser, site, j, realCaptures[0], "CHAIN");

  const verdicts = [...a.verdicts, ...b.verdicts];
  const readings = [...a.readings, ...b.readings];

  // ── THE MIXED STEP: THE ONLY SHAPE THAT DISCRIMINATES ───────────────────
  // A step on which everything changed, or nothing did, is passed by a blanket
  // highlight and by a feature that does nothing respectively. The claim has to
  // be taken somewhere both answers are on screen at once.
  const mixed = verdicts.filter((v) => v.mixed);
  // THE FLOOR IS 2 AND NOT 1. §4b: an existential control is satisfied by one
  // member of five, and the mixed step is the ONLY shape that discriminates
  // here, so a walk that produced exactly one of them is a claim resting on a
  // single transition. Measured across both arms this walk finds seven.
  j.atLeast(
    mixed.length,
    2,
    "CONTROL: the walks included steps on which SOME values changed and some did not",
  );
  const mixedWrong = mixed.filter(
    (v) => v.overMarked.length || v.underMarked.length || v.markedUnchanged.length,
  );
  const sample = mixed[0];
  j.countIs(
    mixedWrong.length,
    0,
    `on every mixed step the marks are on exactly the values that changed` +
      (sample
        ? ` (first such step: ${sample.markedChanged.size} marked changed,` +
          ` ${sample.expectUnmarked.size} unchanged and unmarked, of ${sample.rows} rows)`
        : ""),
  );
  // A CONTROL THAT WAS TRUE BY CONSTRUCTION HAS BEEN REMOVED FROM HERE.
  //
  // It read
  //
  //     j.countIs(mixed.reduce((a, v) => a + v.expectUnmarked.size, 0) === 0 ? 1 : 0,
  //               0, "CONTROL: those mixed steps had unmarked rows …");
  //
  // and `v.mixed` is DEFINED as `expectChanged.size > 0 && expectUnmarked.size >
  // 0`. Every member of `mixed` therefore has unmarked rows by definition, the
  // sum over a non-empty `mixed` is always positive, the ternary always yields
  // 0, and `countIs(0, 0)` always passes. When `mixed` was empty it failed — but
  // that state is already caught one assertion earlier. It could never fail for
  // the reason its own text gave, and it could never be the only thing failing.
  //
  // It is not re-worded because there is nothing to re-word: ANY control derived
  // from `mixed` is entailed by `mixed`'s definition. What the control was
  // reaching for — "there were enough of these steps for the claim to mean
  // something" — is a statement about how many, and that is the floor raised
  // from 1 to 2 above. One assertion fewer, and the one that remains can fail.

  // ── A NAME THAT WAS NOT IN SCOPE READS AS ITS OWN THING ─────────────────
  const appearedRows = verdicts.reduce((a, v) => a + v.expectAppeared.size, 0);
  j.atLeast(
    appearedRows,
    1,
    "CONTROL: the walks brought names into scope that were not there at the previous position",
  );
  const misread = verdicts.flatMap((v) =>
    [...v.expectAppeared].filter((n) => v.markedChanged.has(n) || !v.markedAppeared.has(n)),
  );
  j.countIs(
    misread.length,
    0,
    "a name that was not in scope at the previous position is marked as arriving, not as changed",
  );

  // ── EVERYTHING MARKED IS A READING, NOT A BREAKAGE ──────────────────────
  // Decision 3. A long motion may legitimately mark every row on screen; what
  // must not happen is that such a pane stops being a pane.
  const allMarked = readings.filter(
    (r) => r.rows.length > 0 && r.rows.every((x) => x.changed || x.appeared),
  );
  j.atLeast(
    allMarked.length,
    1,
    "CONTROL: the walks reached a position at which EVERY row on screen is marked",
  );
  const broken = allMarked.filter((r) => r.rows.some((x) => !x.name || !x.value) || r.note.length > 0);
  j.countIs(
    broken.length,
    0,
    "a position at which every row is marked still draws every row, with its name and its value",
  );
}
