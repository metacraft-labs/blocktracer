// "A visitor stepping a session sees the source pane hold still while the
//  position is on screen, and sees the position placed in context when it is
//  not."
//
// Page-Descriptions.md §7.0 (hydration "is what turns a POSITIONED first frame
// into a STEPPING one") and Debugger-Integration.md §7, which gives a whole
// navigation 50 ms — a pane that re-lays-out and re-scrolls on every step is
// spending that budget on movement the visitor did not ask for.
//
// THE REPORT THIS JOURNEY EXISTS FOR
// ----------------------------------
//     "When I step in through the instructions listing, the editor scrolls in a
//      way that the caret/cursor/current-line stay as the top line. No other
//      debugger that I know of behaves this way. My expectation is that the
//      editor should auto-scroll only when the caret leaves the visible area and
//      then I would scroll with half a screen perhaps to allow further movement
//      without auto-scroll."
//
// Two sentences, two claims, and they are different claims: the pane must not
// MOVE while the position is visible, and when it does move the position must
// land with context rather than against an edge.
//
// THE TRAP, AND IT IS THE WHOLE REASON THIS FILE IS WRITTEN THE WAY IT IS
// -----------------------------------------------------------------------
// "THE CURRENT LINE IS VISIBLE AFTER STEPPING" PASSES UNDER THE DEFECT.
//
// It is true when the line is pinned to the top of the pane — which is exactly
// what the visitor was complaining about — and it is true when the line is
// properly revealed. A journey shaped that way would have printed GREEN over
// the reported behaviour and certified it. Journeys 03, 06 and 09 all assert a
// marked line and all three were green on the defect; that is not a criticism of
// them, it is the point. They assert that the position is RENDERED. Nothing
// anywhere asserted where the pane was, and "somewhere" is not an answer to a
// complaint about movement.
//
// So `sourceScroll.inView` is read, reported and asserted by NOTHING. The four
// verdicts are the four that discriminate:
//
//   1. A step to a position that is ALREADY ON SCREEN leaves `scrollTop`
//      UNCHANGED. Under the defect, every step re-anchored the pane.
//
//   1b. AND THE POSITION MOVES DOWN THE BOX while it does. `scrollTop` alone is
//      not enough, because the defect had a second mechanism that leaves it
//      perfectly constant: the pane was re-windowed on every stop, so the
//      position sat at row 7 of a document rebuilt beneath it and `scrollTop`
//      was 0 throughout. Measured before the fix, the position stood at 65.7,
//      65.8, 65.9, 66.0, 66.1 and 66.2 pixels from the top over six steps —
//      "the current-line stays as the top line", with nothing scrolling at all.
//      Measured after: 27, 50, 73, 96, 119, 143, 166, 189.
//
//   2. A step to a position that is OFF SCREEN moves `scrollTop`, and the
//      position lands with context: not the first line on screen, not the last,
//      and not flush against either edge. Under the defect the destination was
//      always the top of the pane, which is the "top line" of the report.
//
//   3. Over a run of steps, the number of times the pane MOVED is FEWER than the
//      number of steps — the visitor's complaint expressed as a count. Under the
//      defect the two numbers were equal.
//
// WHY THE COUNT IS OF POSITIONS AND NOT OF `scroll` EVENTS
// --------------------------------------------------------
// Events cannot carry this claim on this product, and saying so is better than
// measuring the wrong thing. `renderPanes` writes the pane with `innerHTML`, so
// the scroller is a NEW element on every render and starts at 0; restoring the
// reader's offset onto it is a change, and fires a `scroll` event, whatever the
// reveal policy then decides. The visitor sees none of that — the write and the
// restore are one synchronous task, so nothing is painted at the zero — but an
// event listener cannot tell a restore from a policy scroll.
//
// The PAINTED offset can: it is read after the step has settled, it is what the
// visitor is looking at, and it is unchanged across a step that should not have
// moved the pane. So the count is of steps that changed `scrollTop`, which is
// the number the report is about.
//
// WHERE `scrollTop` IS READ FROM
// ------------------------------
// The scroller is FOUND by walking out from the marked line (`lib/probe.mjs`,
// `sourceScroll`), not named. `#pane-editor .panebody` is the element the
// product's own code holds and it is not the source pane's scroller — `.src` is.
// Measured: `.src` client 512 / scroll 886 on demo source, client 549 / scroll
// 7975 on a chain listing, while `.panebody` on the demo pane does not scroll at
// all (539 == 539). A journey that read `.panebody.scrollTop` would have read a
// constant 0 before the fix and 0 after, and a constant supports any assertion
// its author wants.
//
// AND IT IS DRIVEN OVER BOTH KINDS OF RECORDING
// ---------------------------------------------
// The visitor said "the instructions listing", which is the REAL-capture
// rendering: no source positions resolve, so the pane is a disassembly and the
// "line" is a program counter. That arm is therefore the one the report came
// from and it is not optional. The demo arm is source-level and is the one with
// a short enough document to step OFF the screen inside a journey's patience,
// which is what makes assertion 2 reachable at all. Two arms, each with its
// subject list asserted non-empty, and no fallback between them — a `??` there
// is how six journeys in this directory came to judge only the demo chain.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "source-pane-holds-still-while-the-position-is-visible";
export const claim =
  "A visitor stepping a session sees the source pane hold still while the position is on screen.";
export const spec = "Page-Descriptions.md §7.0; Debugger-Integration.md §7 — BlockTracer";
export const assertions = 33;
export const needsEngine = true;

// The walk stops at `MAX_STEPS` or when the trace ends, whichever comes first,
// and `MIN_STEPS` is the floor below which there is not enough of a walk to
// judge. The demo recording offers about thirteen steps past its landing and the
// chain captures offer hundreds; one cap and one floor cover both, and neither
// number is an expectation about a recording — every verdict below is a relation
// between two things the walk measured.
//
// The cap is what makes the listing arm reach a reveal at all: its box holds 23
// rows and the position starts one row into it, so it takes twenty-odd steps to
// walk out of the bottom. An eight-step walk left that arm — the rendering the
// report was about — judging the hold-still half and nothing else.
const MAX_STEPS = 30;
const MIN_STEPS = 10;

/**
 * Step once and wait for the session to actually move.
 *
 * A predicate, never a sleep. `scrollTop` read before the pane has been
 * rewritten is the PREVIOUS step's reading, and a journey whose central claim is
 * "this number did not change" must never be able to satisfy itself by reading
 * the same frame twice. So the wait is on the position — `data-step` or the
 * marked line — and the scroll reading is taken only after it has moved.
 */
async function stepOnce(page, before) {
  await page.click('[data-action="step-forward"]');
  const deadline = Date.now() + 15000;
  let moved = false;
  while (Date.now() < deadline) {
    const after = await readFacts(page);
    if (after.step !== before.step || after.markedNumber !== before.markedNumber) {
      moved = true;
      break;
    }
    await page.waitForTimeout(150);
  }
  // One more settle: the reveal runs inside the same task as the pane write, but
  // the READING is a separate round trip and the layout it reports must be the
  // one the visitor ends up looking at.
  await page.waitForTimeout(120);
  return { moved, facts: await readFacts(page) };
}

/**
 * Would the step's DESTINATION have been on screen without moving the pane?
 *
 * THIS PREDICATE IS THE JOURNEY, AND THE OBVIOUS ONE IS WRONG. The first draft
 * asked whether the position was visible BEFORE the step — which is a question
 * with a constant answer, because the position before the step is where the pane
 * is already looking. It classified a genuine reveal (line 17 to line 23, six
 * lines past the bottom edge) as "a step to a position already on screen", and
 * reported the correct product as broken. A gate that cries wolf gets switched
 * off, and then it is not there for the real one.
 *
 * The question is about the DESTINATION at the OLD offset, and it is exact
 * arithmetic rather than a second measurement: the document is not re-windowed,
 * so a line's offset into the scrolled content is the same before and after the
 * step, and `top + fromTop` recovers it from the reading taken afterwards.
 * Subtracting the offset the pane was at gives where that line WOULD have sat in
 * the box had nothing scrolled.
 *
 * A change of DOCUMENT is classified as off screen whatever the arithmetic says,
 * because the content geometry it is arithmetic over is a different file's.
 */
function destinationWasOnScreen(topBefore, docBefore, after) {
  const s = after.sourceScroll;
  if (!s || !s.scrollable || topBefore === null) return null;
  if (docBefore !== null && after.markedDoc !== docBefore) return false;
  const inContent = s.top + s.fromTop;
  const wouldSitAt = inContent - topBefore;
  return wouldSitAt >= 0 && wouldSitAt + s.lineHeight <= s.boxHeight;
}

/**
 * Walk a session forward, collecting one scroll reading per step.
 *
 * Each entry records whether the step's destination needed a reveal, and whether
 * the pane actually moved — the two numbers every verdict below is a relation
 * between.
 */
async function walk(page, maxSteps) {
  const trail = [];
  let prev = await readFacts(page);
  for (let i = 0; i < maxSteps; i++) {
    const topBefore = prev.sourceScroll?.top ?? null;
    const fromTopBefore = prev.sourceScroll?.fromTop ?? null;
    const docBefore = prev.markedDoc ?? null;
    const { moved: sessionMoved, facts: after } = await stepOnce(page, prev);

    // THE WALK STOPS WHEN THE SESSION DOES, and this is a correctness fix
    // rather than a speed one. The demo recording has about thirteen steps
    // ahead of its landing; a fixed thirty clicked seventeen times at a trace
    // that had ended, and every one of those non-steps entered the trail as a
    // step during which the pane did not move and the position did not advance.
    // The count assertions then read a product that was working perfectly as
    // one that had stopped moving the position — a false RED, which is the
    // direction that gets a gate switched off.
    //
    // A run that ends early is not silently shorter, either: the number of
    // steps actually taken is asserted against a floor below.
    if (!sessionMoved) break;

    trail.push({
      needsNoReveal: destinationWasOnScreen(topBefore, docBefore, after),
      topBefore,
      fromTopBefore,
      topAfter: after.sourceScroll?.top ?? null,
      moved: (after.sourceScroll?.top ?? null) !== topBefore,
      markedBefore: prev.markedNumber,
      markedAfter: after.markedNumber,
      scroll: after.sourceScroll,
      step: after.step,
    });
    prev = after;
  }
  return trail;
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with rows in its Code pane");

  const synthetic = withSession.filter((t) => !t.real);
  const realCaptures = withSession.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the source-level arm has a subject");
  j.atLeast(
    realCaptures.length,
    1,
    "SUBJECTS: REAL-capture sessions, so the instruction listing the report named has a subject",
  );

  // The two prefixes are SYMMETRIC, and that is a requirement of this harness
  // rather than a style choice: `nameCollisions` refuses an assertion whose name
  // CONTAINS another's, because a selftest arm aimed at the shorter one would
  // resolve to two records and silently never run. A bare name paired with a
  // `REAL:`-prefixed one is exactly that shape.
  await arm(browser, site, j, synthetic[0], "SOURCE");
  await arm(browser, site, j, realCaptures[0], "LISTING");
}

/**
 * The claim, over one recording. The same eleven assertions for both renderings
 * — the policy is not allowed to be right on source and wrong on a disassembly,
 * which is the surface the report was actually about.
 */
async function arm(browser, site, j, subject, rendering) {
  const tag = `${rendering}: `;
  j.note(`${tag}driving ${subject.debugPath}`);
  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      `${tag}the session reached \`ready\` with live controls, so there is something to step`,
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );

    // THE INSTRUMENT, BEFORE THE VERDICT. A pane with no scroll range cannot
    // demonstrate either behaviour: "it did not move" is vacuously true of
    // something that cannot move, and that is precisely the false green this
    // journey would produce if it read the wrong element. Asserted, not assumed.
    const at0 = live.facts.sourceScroll;
    j.expect(
      !!at0 && at0.scrollable === true,
      `${tag}INSTRUMENT: the source pane has a scroller, so "it did not move" is a fact and not a vacuity`,
      at0 ? `range=${at0.range}px over a ${at0.boxHeight}px box` : "no scroller found from the marked line",
    );
    j.atLeast(
      at0?.range ?? 0,
      1,
      `${tag}INSTRUMENT: that scroller has somewhere to go`,
    );

    const trail = await walk(page, MAX_STEPS);

    // CONTROL ON THE GESTURE, IN TWO PARTS. Neither is the verdict — together
    // they are the proof that the clicks reached the engine, so that a "the pane
    // did not move" reading below is a statement about the policy and not about
    // a session that never stepped. `moves < walked` and "no step scrolled" are
    // both trivially true of a walk of length zero.
    j.atLeast(
      trail.length,
      MIN_STEPS,
      `${tag}CONTROL: the session stepped far enough to judge (the walk stops when the trace does)`,
    );
    const advanced = trail.filter((t) => t.markedAfter !== t.markedBefore).length;
    j.countIs(
      advanced,
      trail.length,
      `${tag}CONTROL: every step of that walk moved the position`,
    );

    // ── VERDICT 1 — THE ONE THAT CATCHES THE REPORTED DEFECT ──────────────
    //
    // Of the steps that began with the position ON SCREEN, how many moved the
    // pane? The answer must be zero, and the number of such steps is asserted
    // first: "every step from a visible position left the pane alone" is
    // vacuously true of a run that never had one.
    const noRevealNeeded = trail.filter((t) => t.needsNoReveal === true);
    j.atLeast(
      noRevealNeeded.length,
      1,
      `${tag}SUBJECTS: steps whose destination was already on screen`,
    );
    const movedAnyway = noRevealNeeded.filter((t) => t.moved);
    j.countIs(
      movedAnyway.length,
      0,
      `${tag}a step to a position already on screen leaves \`scrollTop\` UNCHANGED`,
    );

    // ── VERDICT 1b — THE HALF `scrollTop` ALONE CANNOT SEE ────────────────
    //
    // `scrollTop` is not sufficient, and this assertion is here because the
    // reported defect had a SECOND mechanism that leaves it perfectly constant.
    // The bundle used to re-window the document on every stop — dropping every
    // line above `currentLine - 6` — so the position sat at row 7 of a document
    // that was rebuilt beneath it. `scrollTop` was 0 before that step and 0
    // after, and every assertion above would have gone green over a pane whose
    // content shifted up by a line each time and whose position never left the
    // top. That is the visitor's sentence exactly: "the current-line stays as
    // the top line".
    //
    // So the pane holding still is asserted the way the visitor perceives it —
    // if the viewport did not move and the position moved to another line, the
    // position must now be somewhere ELSE in the box. Measured before the fix:
    // 65.7, 65.8, 65.9, 66.0, 66.1, 66.2 pixels from the top over six steps
    // that walked six lines. Measured after: 293, 345, 368, 391, 415, 438.
    //
    // HALF A LINE, not a whole one and not zero. A step moves at least one line
    // pitch, so the true delta is never smaller than that; the floor is set
    // below it to absorb the sub-pixel drift visible in the numbers above, and
    // above zero so that rounding cannot manufacture a pass.
    const heldButAdvanced = noRevealNeeded.filter((t) => {
      if (!t.scroll || t.fromTopBefore === null) return false;
      return Math.abs(t.scroll.fromTop - t.fromTopBefore) >= t.scroll.lineHeight / 2;
    });
    j.countIs(
      heldButAdvanced.length,
      noRevealNeeded.length,
      `${tag}the position moves DOWN the box while the pane holds still, rather than staying pinned to one offset`,
    );
    j.note(
      `${tag}the position's distance from the top of the box, step by step: ` +
        trail.map((t) => t.scroll?.fromTop).join(" "),
    );
    if (movedAnyway.length > 0) {
      j.note(
        `${tag}moved anyway: ` +
          movedAnyway.map((t) => `${t.markedBefore}->${t.markedAfter} top ${t.topBefore}->${t.topAfter}`).join(", "),
      );
    }

    // ── VERDICT 3 — THE COMPLAINT AS A COUNT ──────────────────────────────
    //
    // Stated before verdict 2 because it does not depend on the run having
    // produced a departure, and because it is the sentence the report is: the
    // pane moved on EVERY step. `countIs` on the number of moves, so the
    // measurement is in the transcript whichever way it goes, and a strict
    // inequality against the step count as the verdict.
    const moves = trail.filter((t) => t.moved).length;
    j.note(
      `${tag}${trail.length} steps, ${moves} of them moved the pane; tops ` +
        trail.map((t) => t.topAfter).join(" "),
    );
    j.expect(
      moves < trail.length,
      `${tag}over ${trail.length} steps the pane moved FEWER than ${trail.length} times`,
      `it moved ${moves} times`,
    );

    // ── VERDICT 2 — WHERE THE POSITION LANDS WHEN THE PANE DOES MOVE ──────
    //
    // BOTH ARMS MUST REACH A REVEAL, which is why `STEPS` is what it is. An
    // earlier draft walked eight steps and branched on whether a departure had
    // happened, recording four "nothing to judge" assertions when it had not.
    // That kept the declared count constant and judged nothing: the listing arm
    // — the rendering the visitor actually reported — never left its box in
    // eight steps and so never judged the reveal at all. A branch whose empty
    // side records passes is trap 3 with extra steps. The subject list is
    // asserted non-empty instead, and the walk is long enough to produce one.
    const departures = trail.filter((t) => t.needsNoReveal === false);
    j.atLeast(departures.length, 1, `${tag}SUBJECTS: steps whose destination was off screen`);

    const revealed = departures.filter((t) => t.moved);
    j.countIs(
      revealed.length,
      departures.length,
      `${tag}a step to a position off screen MOVES the pane`,
    );

    // WHERE THE CONTEXT CLAIMS MAY BE MADE, AND WHERE THEY MAY NOT.
    //
    // "A line of context on both sides" is not a claim any policy can honour at
    // the ends of a document: the first line of a file has nothing above it and
    // the last has nothing below, and a scroller clamped to 0 or to its maximum
    // is at exactly that. Asserting it there would be demanding a scroll that
    // does not exist, and the journey would be reporting a correct product as
    // broken — the failure direction that gets a gate switched off.
    //
    // So the context claims are scoped to reveals that landed with the scroller
    // strictly inside its range, and THAT set is asserted non-empty in its own
    // right. Without the second half this scoping would be the vacuity it is
    // guarding against.
    const unclamped = departures.filter(
      (t) => t.scroll && t.scroll.top > 0 && t.scroll.top < t.scroll.range,
    );
    j.atLeast(
      unclamped.length,
      1,
      `${tag}SUBJECTS: reveals that landed away from both ends of the document`,
    );

    // "Not the first line on screen" is the report stated exactly: under the
    // reported behaviour the destination was ALWAYS the top line.
    const atTop = unclamped.filter((t) => t.scroll.indexOnScreen === 0);
    j.countIs(atTop.length, 0, `${tag}the revealed position is NOT the first line on screen`);
    const atBottom = unclamped.filter((t) => t.scroll.indexOnScreen === t.scroll.onScreen - 1);
    j.countIs(atBottom.length, 0, `${tag}nor is it the last line on screen`);

    // The same claim in pixels rather than in indices, so a pane that put the
    // line one pitch inside the edge could not pass by arithmetic on line
    // counts. One line of clearance is a FLOOR — the policy centres — and it is
    // stated as a floor so that a future policy of "a third of a screen" would
    // still satisfy the claim this journey is making.
    const flush = unclamped.filter(
      (t) => t.scroll.fromTop < t.scroll.lineHeight || t.scroll.fromBottom < t.scroll.lineHeight,
    );
    j.countIs(
      flush.length,
      0,
      `${tag}the revealed position has at least a line of context on both sides`,
    );
    j.note(
      `${tag}${departures.length} reveal(s), ${unclamped.length} of them clear of both ends: ` +
        unclamped
          .map(
            (t) =>
              `line ${t.markedAfter} at index ${t.scroll.indexOnScreen}/${t.scroll.onScreen}` +
              ` (${t.scroll.fromTop}px from the top, ${t.scroll.fromBottom}px from the bottom)`,
          )
          .join("; "),
    );
  } finally {
    await page.close();
  }
}
