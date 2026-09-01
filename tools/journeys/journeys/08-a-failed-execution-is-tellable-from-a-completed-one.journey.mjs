// "A visitor can tell an execution that FAILED from one that completed."
//
// Page-Descriptions.md §7.1 — the transaction's facts come from one producer and
// are rendered around the session — and §14.1a's rule that every state "shows
// the complete transaction". An execution that stopped on a constraint that did
// not hold is not the same transaction as one that ran to the end, and a page
// that renders them identically is not showing the complete transaction.
//
// WHY THIS NEEDED THE TOUR CORPUS
// ------------------------------
// It could not be written before. Every published demo transaction ran to
// completion, so "the product distinguishes a failure" quantified over an empty
// set and would have passed forever — Verification-Harness-Traps.md §4, the
// cheapest false green there is.
//
// `fixtures/trace/tour/manifest.json` ships a program that fails ON PURPOSE.
// `constraints` carries the capability `failure`, and its expectations say what
// that means, derived from the source rather than read back out of the trace:
//
//   "`solvency_margin(alice, bob, 1_000_000)` compares 170 against a floor of a
//    million, so it returns 0. The recording therefore STOPS at
//    `assert(margin > 0, ...)`. The last entry in its event log is the message
//    `accounts must clear the reserve floor`, and there is no step after it."
//
// SELECTED BY CAPABILITY, NEVER BY NAME
// -------------------------------------
// The subject is "the programs whose capabilities include `failure`", and the
// control is "the programs whose capabilities do not". Neither names a program,
// a package or a transaction, so the corpus can be rewritten under this journey
// without touching it — which is the whole point of the manifest being
// addressable by capability. `DEMO_CHAIN = "aztec"` went stale in a day; a
// capability does not.
//
// WHAT THIS ASSERTS, AND WHAT IT DELIBERATELY DOES NOT
// ---------------------------------------------------
// It asserts that the two are TELLABLE APART on the page, and that the page
// agrees with the manifest about how long the recording is. It does NOT assert
// the failure message, the last event-log entry, or that the recording stops
// where the manifest says — all three are true claims and all three need a
// session stepped to its end, which is a second, larger journey. The manifest's
// own note bounds this: a tour entry's source is its own, but its replay is
// nobody's until hydration runs.
//
// Saying so matters more than covering it. A journey that quietly checked less
// than its name suggests is the defect this layer exists to end.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf, tourManifest, programsWith, txForProgram } from "../lib/corpus.mjs";

export const id = "a-failed-execution-is-tellable-from-a-completed-one";
export const claim = "A visitor can tell an execution that FAILED from one that completed.";
export const spec =
  "Page-Descriptions.md §7.1, §14.1a; fixtures/trace/tour/manifest.json (capability `failure`)";
export const assertions = 7;

export async function run({ browser, site, j }) {
  const manifest = await tourManifest(site.repoRoot);
  const failing = programsWith(manifest, "failure");
  const completing = (manifest.programs ?? []).filter(
    (p) => !(p.capabilities ?? []).includes("failure"),
  );

  // NON-VACUITY, BOTH SIDES. A comparison needs two populated sides, and the
  // failing side is the one that did not exist until the tour landed.
  j.atLeast(failing.length, 1, "the tour publishes a program that fails on purpose");
  j.atLeast(completing.length, 1, "and programs that complete, to compare it against");

  const all = await transactions(site.root);
  const failTx = await txForProgram(site.root, all, failing[0]);
  const okTx = await txForProgram(site.root, all, completing[0]);

  j.expect(
    failTx !== null && okTx !== null,
    "both programs are published as transactions a visitor can open",
    `failing=${failTx?.debugPath ?? "NOT PUBLISHED"}, completing=${okTx?.debugPath ?? "NOT PUBLISHED"}`,
  );
  if (!failTx || !okTx) return; // the assertion count check will catch the shortfall

  j.note(`failing: ${failing[0].id} -> ${failTx.debugPath}`);
  j.note(`completing: ${completing[0].id} -> ${okTx.debugPath}`);

  const look = async (t) => {
    const v = await visit(browser, site.origin, t.debugPath);
    try {
      const badges = await v.page.evaluate(() =>
        [...document.querySelectorAll(".badge")].map((e) => e.textContent.trim()),
      );
      return { facts: v.facts, badges };
    } finally {
      await v.page.close();
    }
  };
  const failed = await look(failTx);
  const completed = await look(okTx);

  // Both land in a session, or the comparison below is between two error pages.
  j.countIs(
    [failed, completed].filter((r) => landingOf(r.facts.phase) === "session").length,
    2,
    "both land in a session, so the pages being compared are both debugging frames",
  );

  // THE PAGE AGREES WITH THE MANIFEST about how long each recording is. This is
  // the cross-source check: the manifest counted the steps from the recording,
  // the exporter published them, and neither read the other.
  j.countIs(
    Number(failed.facts.totalSteps),
    failing[0].trace.steps,
    `the failing recording's published length matches the manifest (${failed.facts.totalSteps})`,
  );
  j.countIs(
    Number(completed.facts.totalSteps),
    completing[0].trace.steps,
    `the completing recording's too (${completed.facts.totalSteps})`,
  );

  // THE CLAIM. Something on the page — a badge, a notice, a stated reason —
  // must differ. Rendered text, so a difference that exists only in the DOM
  // does not count as telling a visitor anything.
  const failedMarks = `${failed.badges.join("|")} ${failed.facts.reasonText ?? ""}`.trim();
  const completedMarks = `${completed.badges.join("|")} ${completed.facts.reasonText ?? ""}`.trim();
  j.expect(
    failedMarks !== completedMarks,
    "the two are tellable apart by what the page says about the execution",
    failedMarks === completedMarks
      ? `both say exactly "${failedMarks}" — an execution that stops on a constraint that did not hold is presented as one that ran to the end`
      : `failing: "${failedMarks}" vs completing: "${completedMarks}"`,
  );
}
