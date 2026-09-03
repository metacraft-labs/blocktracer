// "A visitor stepping a session sees the position move."
//
// Page-Descriptions.md §8 ("`?t=` carries the time coordinate and updates on
// every navigation, so the URL always reflects the current position") and §7.0's
// closing sentence — hydration "is what turns a POSITIONED first frame into a
// STEPPING one".
//
// THE TRAP THIS JOURNEY IS WRITTEN AGAINST
// ----------------------------------------
// Verification-Harness-Traps.md §2: "A chain of `success: true` is not a result
// — assert what the thing PRODUCED." A DAP server once answered `success: true`
// to `initialize`, `launch`, `configurationDone` and `threads` over a session in
// which no trace had been opened at all.
//
// The same shape is available here and is CHEAPER to write than the right one.
// Clicking step-forward on this product mutates `location.search` — `?t=`
// advances, and the recovery anchor's line number advances with it. A journey
// that asserted "the URL changed" would be green. Measured on `dev` while this
// file was written, that is exactly what happens and nothing else does: `?t=`
// goes 1 -> 5 and the anchor goes `main.nr:12` -> `main.nr:13`, while
// `data-step` stays pinned at its landing value and no line in the source pane
// is ever marked.
//
// So the URL is read and REPORTED, and asserted on only as a control — proof
// that the click reached the engine at all. The verdict is taken from the
// rendered position: the step the session reports, and the line the pane marks.
//
// AND IT IS DRIVEN OVER BOTH KINDS OF RECORDING
// ---------------------------------------------
// This file carried the same subject-selection defect journey 09 did, found on
// 2026-09-01 when a visitor reported the mark not following on a REAL
// `aztec-testnet` transaction:
//
//     withSession.find((t) => !t.real) ?? withSession[0]
//
// prefers a synthetic fixture, and with 15 synthetic sessions in the corpus the
// fallback could never run. So "stepping moves the position" had been proven
// only on the demo chain, on a product whose real captures resolve no source
// positions at all and render a completely different Code pane — an
// instruction listing rather than source lines.
//
// The two arms are separate and both required, and neither falls back to the
// other. `j.atLeast(…, 1)` guards each list, because "every real capture steps
// correctly" is vacuously true of a corpus that contains none — which is
// exactly how the gap stayed invisible.

import { visit, readFacts, consoleMark, waitForConsoleLine, POSITION_ANSWERED, tickOf, waitForFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "stepping-moves-the-position";
export const claim = "A visitor stepping a session sees the position move.";
export const spec = "Page-Descriptions.md §7.0, §8 — BlockTracer";
export const assertions = 16;
export const needsEngine = true;

/**
 * Step once and wait for THE ENGINE TO ANSWER, then for the panes to carry that
 * answer.
 *
 * IT USED TO WAIT FOR THE DOM TO DIFFER, and that cannot tell two situations
 * apart: the engine has not answered yet, and the engine answered and the
 * position legitimately did not move — two steps landing on one line, or a step
 * at the end of a range. The first is a wait; the second is a RESULT. Treating
 * them alike meant a no-move step spun the full 15s and then handed back the
 * reading it started with, so the journey judged a stale `before` as an `after`.
 *
 * `[PIPELINE] updateDebuggerPosition` is emitted on every stop whether or not
 * anything moved, and it names the tick it moved to — so the wait is now "the
 * engine answered this gesture", the DOM wait keys off the tick that answer
 * NAMES rather than off a fixed interval, and whether anything moved is left to
 * the assertions, which is where it belongs.
 */
async function stepOnce(page, before) {
  const mark = consoleMark(page);
  await page.click('[data-action="step-forward"]');
  const answered = await waitForConsoleLine(page, POSITION_ANSWERED, {
    sinceIndex: mark,
    budgetMs: 15000,
  });
  const tick = tickOf(answered);
  if (tick !== null) {
    // The panes are written from that same answer, so this waits for the DOM to
    // carry the tick the engine just named — not for a duration.
    await waitForFacts(page, (f) => f.step === tick, 8000);
  }
  return readFacts(page);
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with rows in its Code pane");

  // Two lists, each asserted non-empty, and NO fallback between them — see the
  // header. The fallback made "no real capture was available" and "a real
  // capture passed" the same green.
  const synthetic = withSession.filter((t) => !t.real);
  const realCaptures = withSession.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the demo arm has a subject");
  j.atLeast(
    realCaptures.length,
    1,
    "SUBJECTS: REAL-capture sessions, so the arm the visitor's report came from has a subject",
  );

  const subject = synthetic[0];
  j.note(`driving ${subject.debugPath}`);

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session reached `ready` with live controls, so there is something to step",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );

    // The eight controls §7.0's session offers. Counted, not "at least one":
    // an existential control is satisfied by one member of eight (trap 4b), and
    // a toolbar that lost six buttons would otherwise read as a stepping
    // session.
    j.countIs(live.facts.controlsLive, 8, "all eight stepping controls are live");
    j.countIs(live.facts.controlsInert, 0, "none of them is still declared inert");

    const before = live.facts;
    const after = await stepOnce(page, before);

    // CONTROL ON THE CLICK. Not the verdict — the proof that the interaction
    // reached the engine, so that a red verdict below is a statement about the
    // product and not about a button this suite failed to press.
    j.expect(
      after.urlQuery !== before.urlQuery,
      "CONTROL: the click reached the engine (the time coordinate advanced)",
      `${before.urlQuery} -> ${after.urlQuery}`,
    );

    // THE VERDICT. Both halves of "the position moved", each read off the
    // rendered page.
    j.expect(
      after.step !== before.step,
      "the session's reported step advanced",
      `data-step ${before.step} -> ${after.step} (of ${after.totalSteps})`,
    );
    j.countIs(after.marked, 1, "after the step, exactly one line still carries the position mark");
    j.expect(
      after.markedNumber !== null && after.markedNumber !== before.markedNumber,
      "the marked line moved",
      `marked line ${before.markedNumber} -> ${after.markedNumber}`,
    );
  } finally {
    await page.close();
  }

  // ── THE REAL CAPTURE ──────────────────────────────────────────────────
  //
  // A separate subject and a separate page, so a real-capture regression
  // reddens on its own instead of being masked by a demo session that still
  // works. This is the exact gesture and the exact surface the visitor's
  // report was about.
  await realArm(browser, site, j, realCaptures[0]);
}

/**
 * The same claim, over a REAL capture.
 *
 * Its Code pane is a different rendering — these recordings resolve no source
 * positions, so the pane is an instruction listing and the "line" the mark
 * sits on is a program counter. The claim is unchanged and so are the
 * verdicts: the step the session reports, and the line the pane marks.
 */
async function realArm(browser, site, j, subject) {
  j.note(`driving REAL capture ${subject.debugPath}`);
  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "REAL: the session reached `ready` with live controls",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );
    // Worded so it does not CONTAIN the demo arm's text: `selftest.mjs`
    // resolves an arm with `r.what.includes(assertion)`, so "REAL: " + a
    // verbatim copy would make an arm on the demo assertion resolve to two
    // records and never run. `lib/harness.mjs`'s `nameCollisions` now refuses
    // the shape; this is the reword it asked for.
    j.countIs(
      live.facts.controlsLive,
      8,
      "REAL: the chain capture offers all eight stepping controls, live",
    );

    const before = live.facts;
    const after = await stepOnce(page, before);

    j.expect(
      after.urlQuery !== before.urlQuery || after.step !== before.step,
      "REAL: CONTROL — the click reached the engine",
      `${before.urlQuery} -> ${after.urlQuery}`,
    );
    j.expect(
      after.step !== before.step,
      "REAL: the step this session reports advanced",
      `data-step ${before.step} -> ${after.step} (of ${after.totalSteps})`,
    );
    j.countIs(after.marked, 1, "REAL: after the step, exactly one line still carries the mark");
    j.expect(
      after.markedNumber !== null && after.markedNumber !== before.markedNumber,
      "REAL: the mark moved to the new position",
      `marked line ${before.markedNumber} -> ${after.markedNumber}`,
    );
  } finally {
    await page.close();
  }
}
