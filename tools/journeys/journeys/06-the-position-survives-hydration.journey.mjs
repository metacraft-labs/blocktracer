// "A visitor still sees the execution position after the session goes live."
//
// Page-Descriptions.md §7.0's closing rule: hydration "is what turns a
// POSITIONED first frame into a STEPPING one", and — the sentence this journey
// is named after — "**No state renders less than the pre-hydration page.**"
//
// WHY THIS IS A SEPARATE JOURNEY FROM 02
// --------------------------------------
// Because they judge two different products. `client/src` renders the frame the
// server sends; `client/hydrate/hydrate.js` is a second compilation that
// re-renders every pane on every stop, and it is the only build in the
// repository that links a debugger. `flake.nix packages.default` — what CI
// deploys — ships both. Every Nim suite in this tree drives `renderToString`
// and therefore sees only the first.
//
// Measured on `dev` at the commit that introduces this file, the two DISAGREE:
// the served frame shows `src/shield.nr` with line 32 marked, and after
// hydration the same page shows the same file with nothing marked at all, while
// the session still publishes `data-step="128"` of 1315. That is strictly less
// than the pre-hydration page, which is the one thing §7.0 says no state may
// render.
//
// Journey 02 asks the same six questions of the served frame and is green. That
// pairing is the control: the position is not missing because the assertion is
// wrong, because the corpus is empty, or because the browser cannot lay out
// text — it was there, in this page, measured by this function, moments before.
//
// AND IT IS DRIVEN OVER BOTH KINDS OF RECORDING
// ---------------------------------------------
// This file carried the same subject-selection defect journeys 03, 09, 07 and
// 02 did:
//
//     withSession.find((t) => !t.real) ?? withSession[0]
//
// PREFERS a synthetic fixture, and the corpus has 15 of them, so the `??` arm
// could never run. The pairing with 02 is this journey's whole argument, and a
// subject 02 judges and this one does not is a hole straight through it — which
// is what the fallback produced on both files at once.
//
// The chain captures are the harder half of the claim, not the easier one:
// their Code pane is an INSTRUCTION LISTING, a different rendering with a
// different notion of a "line", and it is the rendering the `Nargo.toml`
// path-matching defect never had to survive. Measured with the arm in place,
// the hydrated chain capture marks one line, on screen, in the one document on
// screen, reading as disassembly.
//
// WHAT THIS JOURNEY REPORTED BUT DID NOT ASSERT, AND WHAT CAME OF IT
// -------------------------------------------------------------------
// This header used to record, as an observation deliberately left unasserted,
// that "a chain capture's served frame stands at step 128 of 345 and its
// hydrated session lands at step 0 of 345", and filed the question of whether
// the landing position should be the served one to "whoever owns `?t=` and the
// entry state".
//
// It was not a move. It was the loss §7.0 forbids, in the one pane this journey
// does not look at. `projectControls` read the store's `rrTicks` as a position
// and `positioned` as `step > 0`; `ReplayDataStore` initialises `rrTicks` to 0
// and a session with no `?t=` never seeks off it, so `renderControls`'s `filled`
// collapsed to 0 and NOT ONE of the 48 ticks carried `.at` or `.on` — no
// playhead at all, on a page whose served frame had just drawn one on its
// correct tick. Fixed in `client/hydrate/session_project.nim`: the served frame
// stands until the engine states a position.
//
// WHY THIS FILE DID NOT CATCH IT, WHICH IS THE PART WORTH KEEPING. The
// implication used to read
//
//     const reportsPosition = Number(live.facts.step) > 0 && …;
//     j.expect(!reportsPosition || (live.facts.marked === 1 && …), …)
//
// so AT step 0 it passed VACUOUSLY — the antecedent was false precisely when the
// defect was present. A test that cannot fail, and its own header had already
// written down the number ("lands at step 0 of 345") as an observation it chose
// not to assert.
//
// IT WAS NOT A HISTORICAL PROBLEM. Measured on this branch, with the fix in
// place and the product correct, BOTH arms of this journey land on step 0: the
// engine's `run-to-entry` parks at tick 0 and says so, and `projectControls`
// correctly reports that as a POSITION rather than as silence. So `step > 0` was
// false on every subject this file has, on every run, and that one assertion was
// asserting nothing at all — on a green journey, indefinitely.
//
// WHAT REPLACED IT: THE IMPLICATION IS GONE, NOT RE-WORDED
// ---------------------------------------------------------
// Re-guarding it would have been the small fix and the wrong one. An implication
// is only ever as strong as its antecedent, and an antecedent nobody asserts is
// one product change away from being false on every subject — which is precisely
// what happened here, silently, on a green journey.
//
// So this file now makes both halves of §7.0 as separate UNCONDITIONAL claims,
// over two frames read by one function:
//
//   * the SERVED frame marks the position and draws its playhead on the tick its
//     own step names — 128 of 1315 puts `.at` on tick 5 of 48 with 4 elapsed
//     behind it;
//   * the LIVE frame marks the position (`judgeFrame`) and draws its playhead on
//     the tick ITS step names — at tick 0 that is tick 1 of 48 with 0 elapsed.
//
// "Nothing renders less than the pre-hydration page" is the conjunction of those,
// and it has no antecedent left to be falsified by the thing it is watching. The
// served reading is taken with `visitWithoutScript`, so no bundle — working or
// broken — participates in it at all.
//
// THE PAIR IS WHAT MAKES IT UNFORGEABLE. `.at` alone is satisfied by a renderer
// that always marks tick 1; `.on` alone is satisfied by a progress bar with no
// playhead at all — which is the control this repository explicitly refused to
// ship (`tickClass`: "a progress bar at 10% on a page loading an 18 MB engine
// reads as the engine's load progress"). Asserting the index AND the elapsed
// count against the session's own step admits one answer.
//
// The same claim is also made in `tests/tdebugpanes.nim` over the shipping
// projection and renderer. That is a unit test on two functions; this is the
// claim on the page, after a real bundle has run in a real browser, and the two
// have already disagreed once about this exact control.

import { visit, visitWithoutScript } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";
import { judgeFrame, FRAME_ASSERTIONS } from "../lib/frame.mjs";

export const id = "position-survives-hydration";
export const claim = "A visitor still sees the execution position after the session goes live.";
export const spec = "Page-Descriptions.md §7.0 ('No state renders less than the pre-hydration page') — BlockTracer";
export const assertions = 3 + 2 * (FRAME_ASSERTIONS + 7);
export const needsEngine = true;

/**
 * How many ticks the control is drawn as, and WHICH one a step lands on.
 *
 * RESTATED FROM THE CONTROL'S DESCRIPTION, NEVER IMPORTED FROM IT — journey 17
 * gives the argument and it is the same one: a check that computed this by
 * calling the shipping `markedTick` would agree with the renderer by
 * construction and could not notice the two disagreeing, which is the entire
 * quantity in question.
 *
 * AND IT IS EXACT HERE, with no tolerance. Journey 17 allows one tick because it
 * compares a handle against a pointer coordinate mid-gesture, where a rounding
 * at a box boundary is a real and uninteresting source of disagreement. Nothing
 * here is mid-gesture: both readings are of a settled page reporting its own
 * step, so the tick is a function of two integers the page publishes and there
 * is exactly one right answer.
 *
 * `session_view.markedTick`'s three decisions, restated:
 *   * NEAREST tick, not the one below — truncation biased every position in the
 *     trace EARLIER by up to a whole tick;
 *   * never tick 0 for a positioned session — step 0 is a position (the engine
 *     parks there) and it is drawn on the first tick;
 *   * the LAST tick is reserved for the end of the trace, because "the trace has
 *     ended" is a different claim from "roughly here" and must not be reached by
 *     rounding error.
 */
const TIMELINE_TICKS = 48;
const tickFor = (step, total) => {
  if (!(total > 0)) return 0;
  const f = step <= 0 ? 0 : step >= total ? 1 : step / total;
  const ceiling = f >= 1 ? TIMELINE_TICKS : TIMELINE_TICKS - 1;
  return Math.min(ceiling, Math.max(1, Math.round(f * TIMELINE_TICKS)));
};

/**
 * The playhead claim, over ONE frame, as two counted assertions.
 *
 * Called for the served frame and for the live one with the same code, for
 * `frame.mjs`'s reason: the whole argument of this journey is that the second
 * reading is judged by the same function that produced the first one's green.
 *
 * `describe` is spelled out in the detail string on both sides, so a red says
 * which tick was drawn and which one the step names rather than "false".
 */
function judgePlayhead(j, label, facts) {
  const t = facts.timeline;
  const step = Number(facts.step);
  const total = Number(facts.totalSteps);
  const want = tickFor(step, total);
  const shape = t
    ? `${t.ticks} ticks, playhead on ${t.at} (${t.atCount} marked), ${t.on} elapsed`
    : "no timeline in the page at all";

  j.expect(
    !!t && t.ticks === TIMELINE_TICKS && t.atCount === 1 && t.at === want,
    `${label}: the playhead is on the tick the session's own step names`,
    `step ${step} of ${total} names tick ${want} of ${TIMELINE_TICKS} — drew ${shape}`,
  );
  // The elapsed run, which is the half a "the playhead exists" check cannot see
  // and vice versa. Ticks 1..at-1 carry `on`; the playhead's own tick carries
  // `at` and NOT `on` (`tickClass` puts the two in an if/elif), so a session on
  // tick 5 shows exactly 4 elapsed.
  j.expect(
    !!t && t.on === Math.max(0, t.at - 1),
    `${label}: the elapsed run ends exactly where the playhead stands`,
    `playhead on ${t ? t.at : "no tick"}, elapsed ${t ? t.on : "n/a"}, expected ${
      t ? Math.max(0, t.at - 1) : "n/a"
    }`,
  );
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with rows in its Code pane");

  // TWO SUBJECT LISTS, EACH ASSERTED NON-EMPTY, AND NO FALLBACK BETWEEN THEM —
  // see the header. This journey's whole meaning is the pairing with 02, so a
  // subject set 02 judges and this one does not is a hole in the pair.
  const synthetic = withSession.filter((t) => !t.real);
  const realCaptures = withSession.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the demo arm has a subject");
  j.atLeast(
    realCaptures.length,
    1,
    "SUBJECTS: REAL-capture sessions, so the chain arm has a subject",
  );

  await hydratedArm(browser, site, j, synthetic[0], "HYDRATED");
  await hydratedArm(browser, site, j, realCaptures[0], "HYDRATED-REAL");
}

/**
 * The same six questions plus this journey's three, over one subject's HYDRATED
 * frame.
 *
 * The arm name is hyphenated (`HYDRATED-REAL`) for the reason journey 02's is:
 * no assertion's text may CONTAIN another's, or `selftest.mjs` resolves arm C
 * to two records and never runs it.
 */
async function hydratedArm(browser, site, j, subject, arm) {
  j.note(`${arm}: driving ${subject.debugPath} (phase=${subject.phase})`);

  // THE SERVED FRAME IS READ FIRST, AND IT IS NOT A CONVENIENCE.
  //
  // It is the only reading of this page taken outside the failure mode. With the
  // bundle running, the served playhead and the hydrated one are the same 48
  // spans and there is no way to ask which mechanism drew the mark that is
  // there; scripting off is the only state in which the pre-hydration answer
  // exists on its own (`visitWithoutScript`'s header, and journey 13 uses it for
  // the same single purpose).
  //
  // Everything the guard below rests on comes from here, so a bundle that
  // renders nothing at all cannot move it.
  const served = await visitWithoutScript(browser, site.origin, subject.debugPath);
  j.note(
    `${arm}: served frame stands at step ${served.step}/${served.totalSteps}, ` +
      `marked=${served.marked}, timeline=${JSON.stringify(served.timeline)}`,
  );

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  try {
    // The wait is reported as a wait. A timeout here is a statement about the
    // engine, not about the position, and must never be read as the latter
    // (Verification-Harness-Traps.md §3: a timeout is a symptom, not a
    // diagnosis).
    j.expect(
      live.settled && !live.timedOut,
      `${arm}: the session reached \`ready\` with live controls, so hydration ran`,
      `phase=${live.facts.phase} live=${live.facts.controlsLive} inert=${live.facts.controlsInert}`,
    );
    j.countIs(
      live.pageErrors.length,
      0,
      `${arm}: no uncaught page errors${
        live.pageErrors.length ? `: ${live.pageErrors.join(" | ")}` : ""
      }`,
    );

    judgeFrame(j, arm, live.facts);

    // ── THE PLAYHEAD, ON BOTH FRAMES, UNGUARDED ────────────────────────────
    //
    // The served pair is the CONTROL and it is asserted rather than assumed. It
    // is what makes the live pair mean something: the position is not on the
    // wrong tick because this file's arithmetic is wrong, because the corpus is
    // empty, or because the browser cannot lay out the control — it was right,
    // on this page, by this function, moments earlier. That is journey 02's
    // argument for the marked line, and the control it needs.
    judgePlayhead(j, `${arm}-SERVED`, served);
    judgePlayhead(j, arm, live.facts);

    // ── §7.0 ITSELF, AND IT IS NO LONGER AN IMPLICATION ───────────────────
    //
    // "No state renders less than the pre-hydration page" is a comparison, and
    // the obvious way to write it is `servedShowed → liveShows`. That is the
    // shape this file was just corrected FOR: an implication is only as good as
    // its antecedent, and an antecedent nobody asserts is one product change
    // away from being false on every subject — which is how the old guard came
    // to gate an assertion that then ran, green and empty, indefinitely.
    //
    // So both sides are stated as their own unconditional claims instead. The
    // served frame marks the position (here), the live frame marks it
    // (`judgeFrame` above), and both draw the playhead their own step names
    // (`judgePlayhead`, twice). The implication follows from the conjunction and
    // there is nothing left for a false antecedent to hide behind: if the
    // pre-hydration page stops showing a position, THIS assertion reddens and
    // says so, rather than quietly disarming the one after it.
    j.expect(
      served.marked === 1 && served.markedShown,
      `${arm}-SERVED: the pre-hydration frame marks the position, so hydration has something to keep`,
      `step ${served.step}/${served.totalSteps}, marked=${served.marked}, ` +
        `on screen=${served.markedShown}, line ${served.markedNumber} of ${served.markedDoc}`,
    );
  } finally {
    await live.page.close();
  }
}
