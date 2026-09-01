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
export const assertions = 1 + FRAME_ASSERTIONS;

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  // A session with no source listing has no line to mark — the chain published
  // no debug symbols for that contract, which is a specified state and journey
  // 05's subject, not this one's. Filtering here rather than naming a
  // transaction keeps the choice a property of the tree.
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session WITH a source listing");

  const subject = withSession.find((t) => !t.real) ?? withSession[0];
  j.note(`driving ${subject.debugPath} (phase=${subject.phase})`);

  const served = await visit(browser, site.origin, subject.debugPath);
  try {
    judgeFrame(j, "SERVED", served.facts);
  } finally {
    await served.page.close();
  }
}
