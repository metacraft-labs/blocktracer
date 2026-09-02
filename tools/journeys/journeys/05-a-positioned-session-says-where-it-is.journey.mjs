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
// and reported six correct pages as broken. A recording no source resolved for
// is at instruction level, which is a specified state and not a failure.
//
// What was MISSING is the other half of the same sentence: the session is
// stopped somewhere — it publishes `data-step` and `data-total-steps` — and the
// page never said where. A visitor on a chain transaction was told there was no
// text and was not told which step they were on.
//
// So the claim is a DISJUNCTION over what the page shows, and it holds for both
// kinds of session:
//
//   a session that reports a position must SHOW that position — by marking the
//   row it is on, or by stating the step.
//
// The disjunction is deliberately kept even though both disjuncts now hold on
// every page: the pane states the step AND marks a row, because an
// instruction-level recording now renders the program counters it carries
// (journey 09). Collapsing this to "mark a row" would delete the assertion that
// the sentence is still there for a reader who cannot see a highlight.
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
export const assertions = 7;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session");
  j.subjects(sessions, 4, "transactions whose landing is a session");

  // THE SPLIT IS SOURCE / NO SOURCE, and it used to be spelled `hasListing`
  // because those were the same question: a recording no source resolved for
  // rendered prose and no rows. They came apart when the Code pane started
  // rendering the program counters such a recording carries, so a chain session
  // now has a row to mark AND still has no source. The claim below is unchanged
  // and both of its branches still have members; what changed is that the
  // second branch is no longer the one with nothing on screen.
  const withSource = sessions.filter((t) => t.hasSource);
  const withoutSource = sessions.filter((t) => !t.hasSource);
  j.atLeast(withSource.length, 1, "some session HAS source to mark a line in");
  j.atLeast(
    withoutSource.length,
    1,
    "some session has NO source — the branch the demo path never exercised",
  );
  j.note(
    `${sessions.length} sessions: ${withSource.length} with source, ` +
      `${withoutSource.length} at instruction level`,
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
  // THE SUBJECT COUNTS, AND WHY `atLeast(…, 1)` WAS NOT ENOUGH HERE.
  //
  // `Number(step) > 0` is the same predicate journey 06 was just corrected for,
  // and it fails the same way: a session the engine parks on tick 0 drops out of
  // `positioned` silently, taking itself out of BOTH the numerator and the
  // denominator of every count below. `atLeast(positioned.length, 1)` over a
  // corpus of 23 was satisfied by one survivor, so a change that put every chain
  // capture at step 0 would have left this file green over eight fewer subjects
  // than it believed it had — §4b's "one member of five", applied to the guard
  // rather than to the claim.
  //
  // The no-source branch is now counted against the CORPUS instead. `hasSource`
  // is read from the served markup by `corpus.mjs`, before any page is opened,
  // so it is a fact this journey's failure mode cannot reach — and "every chain
  // recording reports a position" is a claim worth making in its own right, not
  // merely a guard. It is the branch the seed defect is filed against, and it is
  // the one that must not be allowed to empty.
  const noSourcePositioned = positioned.filter((s) => !s.t.hasSource);
  const withSourcePositioned = positioned.filter((s) => s.t.hasSource);
  j.countIs(
    noSourcePositioned.length,
    withoutSource.length,
    "SUBJECTS: every session with NO source reports a position, so the branch below has all of its members",
  );
  j.atLeast(
    withSourcePositioned.length,
    1,
    "SUBJECTS: sessions WITH source that report a position",
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
  // defect. This is the assertion the seed defect is filed against — and its
  // population is pinned to the corpus above, so `0 of 0` is a red rather than
  // the pass it used to print.
  const noSourceSaysWhere = noSourcePositioned.filter((s) => saysWhere.includes(s));
  j.countIs(
    noSourceSaysWhere.length,
    noSourcePositioned.length,
    `every positioned session WITHOUT source still says where it is stopped` +
      ` (${noSourceSaysWhere.length} of ${noSourcePositioned.length})`,
  );
}
