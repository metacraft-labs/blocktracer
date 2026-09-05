// "A visitor in a recording that resolves source for only SOME of its steps is
//  still shown where the session is at the steps it does not."
//
// `Source-Resolution.md` §7, the "Failure and Degradation" table's last row,
// which names this state and says what it must look like:
//
//   | Partial source coverage | Source-level stepping where sources exist,
//     instruction-level elsewhere, with the boundary visible in the source pane
//     rather than silent |
//
// and `Debugger-Integration.md` §5, from the other side:
//
//   "A single transaction routinely mixes both. The debugger must handle this
//    without ceremony — it is the normal case, not an edge case."
//   "The transition is visible: entering an unverified contract from a verified
//    one changes the pane's header to say so, so the user is never confused
//    about why names disappeared."
//
// WHY THIS IS A JOURNEY OF ITS OWN, AND WHY IT WAS WRITTEN THE DAY THE OTHERS
// WENT GREEN
// ---------------------------------------------------------------------------
// On 2026-09-05 nine journeys were red at once, every one of them on
// `aztec-testnet-frames/0x0a807e4e…`, and the shared symptom was `position is
// in null` — a hydrated session marking no line at all. The cause is this
// recording's shape: 459 steps across TWO contracts at two fidelities, 86
// positioned and 373 not, the unpositioned runs being ticks 0..13, 27..34 and
// 108..458. `ssr.nim`'s ladder gives the Code pane to whichever rung won, so
// the page is 32 Noir documents and no instruction listing, and at 373 of its
// 459 steps there is no row of any kind to be stopped at. Hydration lands at
// tick 0, which is one of them.
//
// EIGHT OF THOSE NINE WENT GREEN WITHOUT THE DEFECT BEING TOUCHED, AND THAT IS
// THIS FILE'S REASON TO EXIST. Every one of them selects its chain arm as
// `withSession.filter((t) => t.real)[0]`, and `withSession` requires
// `hasListing`. Four of that chain's rung-3 transactions had NO listing —
// `/aztec-testnet-frames` was published without `just chain-instructions` ever
// being run over it — so they carried no `.srcline`, failed `hasListing`, and
// were not in the set. Deriving the missing listings put them back in it, and
// `0x00689495…` sorts ahead of `0x0a807e4e…`, so every chain arm moved onto an
// ordinary instruction-level capture and passed.
//
// The suite went from nine red to zero and the defect did not move an inch. A
// corpus that stops covering a defect looks exactly like a defect that was
// fixed, and the difference is invisible from the verdict line — which is the
// failure mode this whole directory exists to refuse. So the class is named in
// `corpus.mjs` (`partiallyPositioned`, read from the published `/d/**` facts
// rather than from a page), and this journey selects on it, so no future
// corpus change can quietly stop judging it.
//
// WHAT IT ASSERTS, AND WHY BOTH HALVES ARE UNCONDITIONAL
// ------------------------------------------------------
// §7 gives two things: instruction-level rows where source does not reach, and
// a boundary that is VISIBLE "rather than silent". They are separate claims and
// a product could satisfy either without the other, so they are separate
// records here and neither guards the other. An implication is only ever as
// strong as its antecedent, and this directory has paid for that twice.
//
// The SERVED frame is the control, and it is asserted rather than assumed. It
// is the reading taken outside the failure mode: the exporter's own landing
// rule (`demo_session.withSourceIsland` — "a page may not report a position it
// is not showing") moves the served step to one there IS source for, so the
// served page marks a line. That is what makes the live zero a measurement
// about hydration rather than about this file's arithmetic, the corpus being
// empty, or the browser being unable to lay out text.
//
// WHAT IT DELIBERATELY DOES NOT ASSERT
// ------------------------------------
// Nothing here says the live session must LAND on a positioned step.
// `Debugger-Integration.md` §6.0a rule 5 says a link with no coordinate lands
// at "the start of the execution", and tick 0 is the start; the served frame's
// mid-point landing is the departure from that, not hydration's. Asserting the
// served step back onto the live session would be asserting a rule the spec
// does not state, against a behaviour the spec does. What is asserted is what
// §7 asks for and §6.0a does not touch: wherever the session IS, the pane says
// where that is.

import { visit, visitWithoutScript } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-partly-positioned-recording-says-where-it-is";
export const claim =
  "A visitor in a recording that resolves source for only some of its steps is still shown where the session is at the steps it does not.";
export const spec =
  "Source-Resolution.md §7 ('Partial source coverage'); Debugger-Integration.md §5 — BlockTracer";
export const assertions = 10;
export const needsEngine = true;

/**
 * Where the pane says the session is, by any of the channels the product has.
 *
 * THREE CHANNELS AND NOT ONE, because §7 asks for a visible boundary and does
 * not prescribe its markup, and a check that named a single element would go
 * red the day the product answered correctly through another one. All three
 * are the product's own existing surfaces:
 *
 *   * `.srcline.cur` — the mark, on a source line or on a listing row. This is
 *     what §7's "instruction-level elsewhere" would produce.
 *   * `.srcpos` — `renderPositionHead`'s sentence, "The session is stopped at
 *     step N of M", which the product already draws on a pane with no line to
 *     mark. This is the weaker answer and it counts.
 *   * `.srcnone .panenote` — the reason a pane with no rows shows instead.
 *
 * Read with `checkVisibility` throughout, for the reason `probe.mjs` gives at
 * length: the source pane holds every document at once and hides all but one,
 * so presence in the DOM is not the question.
 */
const READ_WHERE = () => {
  const shown = (e) =>
    !!e &&
    typeof e.checkVisibility === "function" &&
    e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  const cur = document.querySelector(".srcline.cur");
  const head = document.querySelector(".srcpos");
  const none = document.querySelector(".srcnone .panenote");
  const text = (e) => (shown(e) ? (e.innerText ?? "").trim() : "");
  return {
    marked: [...document.querySelectorAll(".srcline.cur")].filter(shown).length,
    markedNumber: cur?.querySelector(".n")?.textContent?.trim() ?? null,
    markedDoc: cur?.closest(".srcdoc")?.id ?? null,
    rowsShown: [...document.querySelectorAll(".srcline")].filter(shown).length,
    headText: text(head),
    noteText: text(none),
    step: document.querySelector(".dbg")?.getAttribute("data-step") ?? null,
    totalSteps:
      document.querySelector(".dbg")?.getAttribute("data-total-steps") ?? null,
  };
};

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session");

  // THE SUBJECT SET IS THE CLASS, NOT A TRANSACTION. `partiallyPositioned` is
  // `stepsPositioned > 0 && stepsUnpositioned > 0`, read off the published
  // facts. A corpus in which no recording is in that state fails HERE, by name,
  // rather than reporting a green run over an empty loop — and that is the
  // right failure, because it means this claim has become unjudgeable and
  // somebody has to say so out loud rather than inherit a green.
  const partial = sessions.filter((t) => t.partiallyPositioned);
  j.subjects(partial, 1, "sessions whose recording positions SOME of its steps and not others");

  // …and the other side of the class, so "partial" is a real partition rather
  // than a name for "every session here". Without it a build that reported
  // every recording as partial would satisfy the guard above.
  j.atLeast(
    sessions.filter((t) => !t.partiallyPositioned).length,
    1,
    "CONTROL: sessions that are NOT partial, so the class above is a partition",
  );

  const subject = partial[0];
  j.note(
    `driving ${subject.debugPath} — ${subject.stepsPositioned} of ` +
      `${subject.stepsPositioned + subject.stepsUnpositioned} steps carry a source position`,
  );

  // The class, restated as an assertion over the numbers this file selected on.
  // Selecting on a property and then never asserting it is how a subject set
  // comes to mean something other than its name.
  j.expect(
    subject.stepsPositioned > 0 && subject.stepsUnpositioned > 0,
    "CONTROL: the subject really does position some of its steps and not others",
    `${subject.stepsPositioned} positioned, ${subject.stepsUnpositioned} not`,
  );

  // ── THE CONTROL, OUTSIDE THE FAILURE MODE ────────────────────────────────
  //
  // `visitWithoutScript`, so no bundle — working or broken — participates. The
  // served frame is where the exporter's landing rule applies, and it is what
  // makes every zero below a measurement.
  const served = await visitWithoutScript(browser, site.origin, subject.debugPath);
  j.note(
    `SERVED: step ${served.step}/${served.totalSteps}, marked=${served.marked}, ` +
      `doc=${served.markedDoc}, line ${served.markedNumber}`,
  );
  j.countIs(
    served.marked,
    1,
    "SERVED: the pre-hydration frame marks the position, so the pane works on this page",
  );

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  try {
    j.expect(
      live.settled && !live.timedOut,
      "LIVE: the session reached `ready` with live controls, so hydration ran",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );
    j.countIs(
      live.pageErrors.length,
      0,
      `LIVE: no uncaught page errors${
        live.pageErrors.length ? `: ${live.pageErrors.join(" | ")}` : ""
      }`,
    );

    const where = await live.page.evaluate(READ_WHERE);
    j.note(
      `LIVE: step ${where.step}/${where.totalSteps}, ${where.rowsShown} rows on screen, ` +
        `marked=${where.marked}, head=${JSON.stringify(where.headText)}, ` +
        `note=${JSON.stringify(where.noteText)}`,
    );

    // INSTRUMENT. The pane rendered something, so "nothing says where the
    // session is" below is a statement about what it says and not about whether
    // it ran at all. Without this the two records after it are satisfied by a
    // blank page.
    j.atLeast(
      where.rowsShown,
      1,
      "LIVE: INSTRUMENT — the Code pane has rows on screen, so the readings below are of a rendered pane",
    );

    // §7's FIRST HALF: "instruction-level elsewhere". Wherever the session
    // stands, the pane has a row for it and marks it. At a positioned step that
    // row is a source line; at an unpositioned one it is the instruction — and
    // the assertion is the same either way, deliberately, because §7's sentence
    // is one sentence about one pane.
    j.countIs(
      where.marked,
      1,
      "LIVE: the pane marks the row the session is standing on",
      `step ${where.step} of ${where.totalSteps}, marked ${where.marked}` +
        (where.marked === 1 ? ` at ${where.markedDoc}:${where.markedNumber}` : ""),
    );

    // §7's SECOND HALF: "with the boundary visible in the source pane rather
    // than silent". A separate record from the mark, and unconditional, because
    // a product could mark a row and still not say which rung it is on — and
    // could say which rung it is on while marking nothing. Neither guards the
    // other.
    //
    // The bar is low on purpose: ANY of the product's three existing channels
    // counts. What it forbids is the state measured on 2026-09-05 — 224 lines
    // of Noir on screen, no mark, no head, no note, and nothing anywhere saying
    // that the session had stepped into code this recording publishes no source
    // for.
    j.expect(
      where.marked === 1 || where.headText.length > 0 || where.noteText.length > 0,
      "LIVE: and the pane SAYS where the session is, rather than leaving the absence unexplained",
      where.marked === 1 || where.headText.length > 0 || where.noteText.length > 0
        ? `mark=${where.marked} head=${JSON.stringify(where.headText)} note=${JSON.stringify(where.noteText)}`
        : `${where.rowsShown} rows on screen, no mark, no position head and no note — ` +
          `the session is at step ${where.step} of ${where.totalSteps} and nothing on the page says so`,
    );

    // AND THE MARK IS IN THE DOCUMENT ON SCREEN, which is the relation the
    // `Nargo.toml` defect survived 115 cases by not having asserted. Read as a
    // relation between two things the page reports; neither is named here.
    j.expect(
      where.marked === 1 && where.markedDoc !== null,
      "LIVE: the marked row is in a document the pane is showing",
      `marked=${where.marked}, document=${where.markedDoc}`,
    );
  } finally {
    await live.page.close();
  }
}
