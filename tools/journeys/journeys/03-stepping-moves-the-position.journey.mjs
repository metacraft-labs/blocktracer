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

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "stepping-moves-the-position";
export const claim = "A visitor stepping a session sees the position move.";
export const spec = "Page-Descriptions.md §7.0, §8 — BlockTracer";
export const assertions = 8;
export const needsEngine = true;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with a source listing");

  const subject = withSession.find((t) => !t.real) ?? withSession[0];
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
    await page.click('[data-action="step-forward"]');
    // A predicate, never a sleep: wait for ANY of the three things a step could
    // move, so a step that moves nothing is a timeout with all three reported
    // rather than a race this suite lost.
    const deadline = Date.now() + 15000;
    let after = before;
    while (Date.now() < deadline) {
      after = await readFacts(page);
      if (
        after.urlQuery !== before.urlQuery ||
        after.step !== before.step ||
        after.markedNumber !== before.markedNumber
      )
        break;
      await page.waitForTimeout(200);
    }

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
}
