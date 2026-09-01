// "A visitor who opens a transaction's debug page sees the code at the
//  execution position, with the position marked."
//
// Page-Descriptions.md §7.0 ("where a trace is available, what it serves IS the
// session's first frame"; "The first frame is served, not hydrated over ... the
// landing is correct without it") and Debugger-Integration.md §6.0b.
//
// THIS IS THE SEED DEFECT, AND WHY 115 TESTS MISSED IT
// ---------------------------------------------------
// `client/tests/test_debug_route.nim` had 115 cases over a positioned session
// and every one built its fixture from `demo_session.FixtureFile` / `FixtureLine`
// and asserted those same two constants back — so the suite proved that a
// constant had been applied to a fixture derived from the constant. It covered
// RENDERING a positioned session exhaustively and BECOMING one not at all.
// `client/tests/test_entry_state.nim` closed that on the Nim path and states the
// rule this file also obeys:
//
//   "Nothing in this suite may name a path or a line as the expected answer —
//    every expectation is a RELATION over the session's own reported position."
//
// So no assertion below names a file, a line number or a count of lines.
//
// THIS JOURNEY IS THE CONTROL FOR JOURNEY 06
// ------------------------------------------
// It judges the frame the SERVER sent, which needs no replay engine and runs
// everywhere. Journey 06 asks the same six questions of the frame the hydration
// bundle leaves behind. Keeping them apart is what makes 06's red mean
// something: the position is not missing because the assertion is wrong or the
// page is broken — it is present here, in the same page, measured by the same
// function, moments earlier.
//
// AND IT IS DRIVEN OVER BOTH KINDS OF RECORDING
// ---------------------------------------------
// This file carried the same subject-selection defect journeys 03, 09 and 07
// did — the fourth occurrence, found by sweeping for the shape rather than by
// waiting for a fifth report:
//
//     withSession.find((t) => !t.real) ?? withSession[0]
//
// PREFERS a synthetic fixture, and with 15 synthetic sessions in the corpus the
// `??` arm could never be reached. So the seed defect's own control journey had
// only ever judged the demo chain — while journey 06, which exists to be read
// against this one, was in exactly the same position.
//
// The two frames a chain capture and a demo session serve are NOT the same
// rendering: a chain recording resolves no source positions, so its Code pane
// is an instruction listing and the "line" the mark sits on is a program
// counter. All six questions still apply, and all six are asked of both.
//
// Measured with the arm in place, on all eight real captures in the corpus: one
// document on screen, one line marked and visible, the marked document IS the
// shown document, and the marked line reads as disassembly ("0x2a02  ADD_8").
//
// EVERY ASSERTION IS ABOUT WHAT IS RENDERED
// -----------------------------------------
// The pane holds every file in the bundle at once and hides all but one with
// CSS, so the manifest is in the DOM of a correct page too. An earlier draft
// read the first `.srcline` in document order and called a correct page broken.
// Presence is not the claim; being on screen is.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";
import { judgeFrame, FRAME_ASSERTIONS } from "../lib/frame.mjs";

export const id = "served-frame-marks-the-position";
export const claim =
  "A visitor who opens a transaction's debug page sees the code at the execution position, with the position marked.";
export const spec = "Page-Descriptions.md §7.0; Debugger-Integration.md §6.0b — BlockTracer";
export const assertions = 3 + 2 * FRAME_ASSERTIONS;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  // A session with no source listing has no line to mark — the chain published
  // no debug symbols for that contract, which is a specified state and journey
  // 05's subject, not this one's. Filtering here rather than naming a
  // transaction keeps the choice a property of the tree.
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with rows in its Code pane");

  // TWO SUBJECT LISTS, EACH ASSERTED NON-EMPTY, AND NO FALLBACK BETWEEN THEM —
  // see the header. `find((t) => !t.real) ?? withSession[0]` is what kept this
  // journey on the demo chain.
  const synthetic = withSession.filter((t) => !t.real);
  const realCaptures = withSession.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the demo arm has a subject");
  j.atLeast(
    realCaptures.length,
    1,
    "SUBJECTS: REAL-capture sessions, so the chain arm has a subject",
  );

  await frameArm(browser, site, j, synthetic[0], "SERVED");
  await frameArm(browser, site, j, realCaptures[0], "SERVED-REAL");
}

/**
 * The six questions, over one subject's served frame.
 *
 * The arm name is hyphenated (`SERVED-REAL`, never `REAL: SERVED`) so that no
 * assertion's text CONTAINS another's: `selftest.mjs` resolves an arm's target
 * with `r.what.includes(assertion)` and treats two hits as no hit, so a prefix
 * collision here would silently make arms A and B unrunnable — a mutation that
 * scores NEVER RAN rather than SURVIVED, which reads as a harness problem
 * instead of an unguarded defect.
 */
async function frameArm(browser, site, j, subject, arm) {
  j.note(`${arm}: driving ${subject.debugPath} (phase=${subject.phase})`);
  const served = await visit(browser, site.origin, subject.debugPath);
  try {
    judgeFrame(j, arm, served.facts);
  } finally {
    await served.page.close();
  }
}
