// "A visitor who opens a positioned session is told where it is stopped —
//  including on a chain transaction, where there is no line to mark."
//
// Page-Descriptions.md §14.1a: "The page never degrades. Every one of these
// states shows the complete transaction; what varies is whether a debugger can
// be opened over it." And §7.0's first row, which promises the debugging
// interface for `ready`/`divergent` without promising source text.
//
// THIS IS THE SEED DEFECT "no current-line indicator on chain transactions"
// ------------------------------------------------------------------------
// The defect and its journey are easy to state one notch too strongly, and the
// first draft of journey 01 did: it demanded a source listing of every session
// and reported six correct pages as broken. An Aztec contract class carries
// bytecode and no debug symbols, so a real-chain recording is at instruction
// level, and the pane says so in the producer's own words:
//
//   "The chain publishes no source for this contract ... The recording is
//    therefore at instruction level: every step is a program counter, and there
//    is nothing to position it against. Stepping is complete; only the text is
//    missing."
//
// That is correct and complete. What is MISSING is the other half of the same
// sentence: the session is stopped somewhere — it publishes `data-step` and
// `data-total-steps` — and the page never says where. A visitor on a chain
// transaction is told there is no text and is not told which step they are on.
//
// So the claim is a DISJUNCTION over what the page shows, and it holds for both
// kinds of session:
//
//   a session that reports a position must SHOW that position — by marking the
//   line it is on, or, where there is no line, by stating the step.
//
// WHY 108 `.srcline` ASSERTIONS DID NOT COVER THIS
// -----------------------------------------------
// All of them ran on the demo chain, which publishes source, so all of them
// took the first branch of that disjunction. The second branch had no
// assertions at all, because the pages that need it were never in any suite's
// subject set. This journey asserts BOTH branches and asserts that both have
// members — so a corpus that lost its real-chain captures fails here rather
// than quietly reverting to the demo-only coverage that hid the defect.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-positioned-session-says-where-it-is";
export const claim =
  "A visitor who opens a positioned session is told where it is stopped — including on a chain transaction, where there is no line to mark.";
export const spec = "Page-Descriptions.md §7.0, §14.1a — BlockTracer";
export const assertions = 6;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session");
  j.subjects(sessions, 4, "transactions whose landing is a session");

  const withListing = sessions.filter((t) => t.hasListing);
  const withoutListing = sessions.filter((t) => !t.hasListing);
  j.atLeast(withListing.length, 1, "some session HAS a line to mark");
  j.atLeast(
    withoutListing.length,
    1,
    "some session has NO line to mark — the branch the demo path never exercised",
  );
  j.note(
    `${sessions.length} sessions: ${withListing.length} with a listing, ` +
      `${withoutListing.length} without`,
  );

  const seen = [];
  for (const t of sessions) {
    const v = await visit(browser, site.origin, t.debugPath);
    try {
      // "says where it is" — either mark, or statement. The statement is read as
      // RENDERED text and is required to name the step the session publishes,
      // because a sentence that says "the session is stopped somewhere" without
      // the number is not the fact a visitor needs.
      const stated = await v.page.evaluate(() => {
        const el = document.querySelector(".srcpos, .dbgpos, [data-position-statement]");
        const shown =
          !!el &&
          typeof el.checkVisibility === "function" &&
          el.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
        return { present: !!el, shown, text: shown ? (el.innerText ?? "").trim() : "" };
      });
      seen.push({ t, facts: v.facts, stated });
    } finally {
      await v.page.close();
    }
  }

  // Only sessions that actually REPORT a position are held to the rule. One
  // that reports none has nothing to show, and demanding a statement of it
  // would be inventing a requirement §14.1a does not make.
  const positioned = seen.filter(
    (s) => Number(s.facts.step) > 0 && Number(s.facts.totalSteps) > 0,
  );
  j.atLeast(
    positioned.length,
    1,
    "some session reports a position, so the rule below has a subject",
  );

  const saysWhere = positioned.filter((s) => {
    if (s.facts.marked === 1 && s.facts.markedShown) return true; // it marked the line
    if (!s.stated.shown) return false;
    // The statement has to carry the number, not merely exist.
    return s.stated.text.includes(String(s.facts.step));
  });

  j.countIs(
    saysWhere.length,
    positioned.length,
    `every positioned session says where it is stopped${
      saysWhere.length === positioned.length
        ? ""
        : `; silent: ${positioned
            .filter((s) => !saysWhere.includes(s))
            .map((s) => `${s.t.txPath} (step ${s.facts.step}/${s.facts.totalSteps}, marked=${s.facts.marked}, statement=${s.stated.present ? "present but not shown or not numbered" : "absent"})`)
            .join("; ")}`
    }`,
  );

  // BOTH BRANCHES, SEPARATELY. Asserting only the total lets a corpus in which
  // every session has a listing satisfy the rule with the branch that hid the
  // defect. This is the assertion the seed defect is filed against.
  const noListingPositioned = positioned.filter((s) => !s.t.hasListing);
  const noListingSaysWhere = noListingPositioned.filter((s) => saysWhere.includes(s));
  j.countIs(
    noListingSaysWhere.length,
    noListingPositioned.length,
    `every positioned session WITHOUT a line to mark still states its step` +
      ` (${noListingSaysWhere.length} of ${noListingPositioned.length})`,
  );
}
