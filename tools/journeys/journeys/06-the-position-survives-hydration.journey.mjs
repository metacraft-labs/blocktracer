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
// One thing the arm reports and deliberately does not assert: a chain capture's
// served frame stands at step 128 of 345 and its hydrated session lands at step
// 0 of 345. That is a MOVE, not a loss — §7.0's rule is that no state renders
// LESS, and the hydrated page renders a position with the same six properties.
// Whether the landing position should be the served one is a question about
// `?t=` and the entry state, and it belongs to whoever owns that, stated here
// rather than smuggled in as an assertion this journey did not come to make.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";
import { judgeFrame, FRAME_ASSERTIONS } from "../lib/frame.mjs";

export const id = "position-survives-hydration";
export const claim = "A visitor still sees the execution position after the session goes live.";
export const spec = "Page-Descriptions.md §7.0 ('No state renders less than the pre-hydration page') — BlockTracer";
export const assertions = 3 + 2 * (FRAME_ASSERTIONS + 3);
export const needsEngine = true;

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

    // The implication the whole layer is for: a session that REPORTS a position
    // must SHOW one. Both halves come from the page; nothing here supplies
    // either.
    const reportsPosition = Number(live.facts.step) > 0 && Number(live.facts.totalSteps) > 0;
    j.expect(
      !reportsPosition || (live.facts.marked === 1 && live.facts.markedShown),
      `${arm}: a session that REPORTS a position also SHOWS one`,
      `step=${live.facts.step}/${live.facts.totalSteps}, marked and on screen=${
        live.facts.marked === 1 && live.facts.markedShown
      }`,
    );
  } finally {
    await live.page.close();
  }
}
