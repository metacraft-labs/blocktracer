// "The deepest Starknet session comes up, and its call tree fits the pane."
//
// The corpus's deepest Starknet transaction runs 18,903 steps through 354
// frames (353 calls opened — entry points and internal Cairo functions), and
// its source pane carries 70,727 lines of CASM listings and the Cairo sources
// behind them. That is the shape codetracer-pm's 2026-10-20 issue names for
// the call trace ("deep and wide") and the shape no Aztec recording has.
//
// It is its own journey because its first live paint is the costly one: it
// renders and lays out the whole listing, and before the island was decoded
// once per page and the pane stopped copying it on every paint, the session
// reached `ready` after 97-141 s, outside the visit budget. Judged on its own,
// a regression in that cost turns this journey red without hiding the other
// Starknet claims, which `01-a-starknet-session-shows-what-it-recorded` makes.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "the-deepest-starknet-session-comes-up";
export const claim = "The deepest Starknet session comes up, and its call tree fits the pane.";
export const spec = "codetracer-pm issue 2026-10-20 (HSF-B2, Starknet) — BlockTracer";
export const assertions = 5;
export const needsEngine = true;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const ordered = all
    .filter((t) => t.chain === "starknet-mainnet" && landingOf(t.phase) === "session")
    .sort((a, b) => (a.calltraceFrames ?? 0) - (b.calltraceFrames ?? 0));
  const [deepest] = j.subjects(ordered.slice(-1), 1, "the deepest Starknet session");
  if (!deepest) return;

  const live = await visit(browser, site.origin, deepest.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the deepest Starknet session comes up live inside the visit budget",
      `phase=${live.facts.phase} · ${live.facts.totalSteps} steps · ${deepest.debugPath}`,
    );
    const ct = await page.evaluate(() => {
      const shown = (e) =>
        !!e &&
        typeof e.checkVisibility === "function" &&
        e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
      const rows = [...document.querySelectorAll(".calltrace-call-line")].filter(shown);
      const pane = document.querySelector("#pane-calltrace");
      return {
        shown: rows.length,
        overflowing: rows.filter((r) => r.scrollWidth > r.clientWidth + 1).length +
          (pane && pane.scrollWidth > pane.clientWidth + 1 ? 1 : 0),
        longestName: Math.max(0, ...rows.map((r) => (r.getAttribute("data-function") ?? "").length)),
      };
    });
    j.atLeast(Number(live.facts.totalSteps ?? 0), 10000, "CONTROL: it is a long execution");
    j.atLeast(ct.shown, 1, "its call trace has rows on screen");
    j.countIs(ct.overflowing, 0, "no call-trace row, and not the pane, overflows sideways");
  } finally {
    await page.close();
  }
}
