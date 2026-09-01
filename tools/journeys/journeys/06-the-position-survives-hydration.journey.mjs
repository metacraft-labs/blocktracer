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

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";
import { judgeFrame, FRAME_ASSERTIONS } from "../lib/frame.mjs";

export const id = "position-survives-hydration";
export const claim = "A visitor still sees the execution position after the session goes live.";
export const spec = "Page-Descriptions.md §7.0 ('No state renders less than the pre-hydration page') — BlockTracer";
export const assertions = 3 + FRAME_ASSERTIONS + 1;
export const needsEngine = true;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with rows in its Code pane");

  const subject = withSession.find((t) => !t.real) ?? withSession[0];
  j.note(`driving ${subject.debugPath} (phase=${subject.phase})`);

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
      "the session reached `ready` with live controls, so hydration ran",
      `phase=${live.facts.phase} live=${live.facts.controlsLive} inert=${live.facts.controlsInert}`,
    );
    j.countIs(
      live.pageErrors.length,
      0,
      `no uncaught page errors${live.pageErrors.length ? `: ${live.pageErrors.join(" | ")}` : ""}`,
    );

    judgeFrame(j, "HYDRATED", live.facts);

    // The implication the whole layer is for: a session that REPORTS a position
    // must SHOW one. Both halves come from the page; nothing here supplies
    // either.
    const reportsPosition = Number(live.facts.step) > 0 && Number(live.facts.totalSteps) > 0;
    j.expect(
      !reportsPosition || (live.facts.marked === 1 && live.facts.markedShown),
      "a session that REPORTS a position also SHOWS one",
      `step=${live.facts.step}/${live.facts.totalSteps}, marked and on screen=${
        live.facts.marked === 1 && live.facts.markedShown
      }`,
    );
  } finally {
    await live.page.close();
  }
}
