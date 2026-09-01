// "A visitor can trace a value to its origin — and until they can, the product
//  does not say they can."
//
// WHAT CHANGED, AND WHY THE JOURNEY DID NOT SIMPLY GO GREEN
// --------------------------------------------------------
// This journey was written as an implication: IF the home page promises that a
// value can be traced to its origin, THEN some control offers it. The promise
// has now been removed from `client/src/pages/home.nim` and `client/src/ssr.nim`,
// which under the old shape would have turned this file green by deleting its
// antecedent — a legitimate resolution, and the one that was taken, but one
// that would have taken the SIGNAL with it.
//
// So the journey keeps the id and inverts the first half. It now asserts that
// the false claim is GONE (a regression guard on the copy, in the one place a
// visitor and a search engine actually read it) and still asserts the
// capability, unconditionally. It is RED today on the capability half, and it
// goes green when the surface lands. That is the same signal, without the
// escape hatch.
//
// THE PREVIOUS DIAGNOSIS IN THIS FILE WAS WRONG, AND SO WAS ITS CONTROL ARM
// ------------------------------------------------------------------------
// It said the surface was "ONE ASSIGNMENT AWAY" — that `StateVM.originChainLookup`
// is declared and BlockTracer merely never assigns it. Both halves of that are
// true and the conclusion does not follow, because there is nothing to look the
// origin of UP. Measured against the pinned Embed SDK (`ci/embed-sdk-pin.env`,
// 8d1c84a8):
//
//   `ReplayDataStore.requestLocals` (store/replay_data_store.nim:664-680) sends
//   `ct/load-locals` and DISCARDS the reply. Its `onSuccess` sets
//   `loadingState` and `loadedForRRTicks` and nothing else, and its own comment
//   says why: "The actual JSON→Variable parsing will be added when the locals
//   panel is converted; for now we just update loading state."
//
//   The only writer of `store.locals.locals` is `updateLocals` (:795). Nothing
//   under `client/hydrate/` calls it — only `tests/tdebugpanes.nim` does, which
//   is why that suite is green about a data path the shipping bundle lacks.
//
// So `StateVM.currentVariables` is empty for the life of every hydrated
// session, `projectState` yields no values, and `hydrate.nim`'s PaneLatch —
// which only writes the State pane when `values.len > 0` — never fires. The
// visitor keeps looking at the STATICALLY EXPORTED State pane for as long as
// the tab is open.
//
// That is also what was wrong with the old control arm. It asserted
// `valuesShown >= 1` as its non-vacuity guard and concluded "there is something
// to ask the origin of". Those rows are the served frame's fixture text. The
// guard was satisfied by exactly the artefact whose persistence IS the defect,
// so the journey could not have detected the defect it was written for. This
// version measures the served frame and the hydrated page separately and
// compares them, which is the difference between "there are rows" and "the rows
// are the engine's".
//
// THE SECOND BLOCKER, WHICH OUTLIVES THE FIRST
// --------------------------------------------
// Fidelity. Every transaction this explorer publishes is declared rung 3, and
// `client/src/debugger/demo_session.nim` prints the consequence verbatim: "This
// recording carries no variable names: naming a local needs debug symbols,
// which an Aztec contract class does not publish." The origin classifier works
// by splitting the right-hand side of a source assignment (see codetracer's
// `tests/fixtures/origin/noir/simple_trivial_chain/ANSWERS.md`), so with no
// source and no names it has nothing to split. Fixing the SDK alone would give
// a live but nameless pane, and an origin chain over it would terminate at
// `UnknownVariable` on every hop.
//
// Where it WOULD be meaningful is the demo tour: eight real Noir programs
// recorded by `nargo trace`, each with a `sources/` tree and `varnames` in its
// trace. That — not the real chain — is the subject the surface should first be
// demonstrated on.
//
// AND IT IS DRIVEN OVER BOTH KINDS OF RECORDING
// ---------------------------------------------
// THIS FILE CARRIED THE SAME SUBJECT-SELECTION DEFECT AS JOURNEYS 03 AND 09,
// and was the third occurrence of it. Until it was removed the subject was
//
//     sessions.find((t) => !t.real) ?? sessions[0]
//
// which PREFERS a synthetic fixture. With 19 synthetic sessions in the corpus
// the `??` arm could never be reached, so every assertion this journey has ever
// made about the capability was made about the demo chain — including the
// "counted 0" its ledger entry is written from. The claim above names no
// chain, so a corpus-wide absence was being inferred from one recording.
//
// The fix is the one 03 and 09 took: TWO SUBJECT LISTS SELECTED BY FILTER, each
// asserted non-empty with its count printed, both driven, and NO `??` between
// them. The fallback is what made "no real capture was available" and "a real
// capture passed" the same green — a corpus that loses one kind of recording
// must be a RED, because the journey can no longer judge the claim it makes.
//
// Measured with the arm in place: the absence is real on both. The demo session
// and the chain capture each carry a live bundle with interactive controls, and
// each counts ZERO controls matching the generous origin selector. The chain
// arm's red is therefore the SAME defect the ledger entry names, restated over
// the subject that entry could not previously speak for — not a second, unnamed
// failure absorbed by it.

import { visit } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-value-can-be-traced-to-its-origin";
export const claim =
  "A visitor can trace a value to its origin — and until they can, the product does not say they can.";
export const spec =
  "client/src/pages/home.nim (the hero) and ssr.nim (the meta description) — the product's own promise, now withdrawn";
export const assertions = 14;
export const needsEngine = true;

const PROMISE = /trace any value to its origin/i;

/** The State pane's rows as the DOM holds them, from an already-loaded page. */
const READ_ROWS = () => {
  const shown = (e) =>
    !!e &&
    typeof e.checkVisibility === "function" &&
    e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  const rows = [...document.querySelectorAll(".strow")];
  return {
    rows: rows.length,
    shown: rows.filter(shown).length,
    // The reading, not the markup: a class change elsewhere must not read as
    // "the engine supplied different values".
    text: rows.map((e) => (e.textContent ?? "").replace(/\s+/g, " ").trim()).join("|"),
  };
};

/**
 * The origin affordances on screen, and the interactive controls beside them.
 *
 * ONE selector for both arms, hoisted here so that "counted 0" means the same
 * measurement on a demo session and on a chain capture. Two copies of the regex
 * is two chances for the arms to disagree about what an origin control looks
 * like, and a difference there would read as a difference in the product.
 *
 * THE LABEL, NOT THE CONTENT — AND THIS IS A MEASURED CORRECTION
 * -------------------------------------------------------------
 * The previous form matched the regex against each candidate's whole
 * `textContent`. On the demo chain it counted 0 and the journey read as
 * correct. The first run that reached a CHAIN capture counted 1, and the one
 * match was this, on every one of the eight real captures in the corpus:
 *
 *   <a class="evrow k-event" href="?v=1&t=344&…">
 *     …avm:11912 status=unavailable-in-principle origin=settled-chain …
 *
 * An EVENT-LOG ROW. `origin=` there is a field of the event the chain recorded,
 * and `textContent` on a row flattens every column into one string. Nothing on
 * that page offers to trace anything; the word was in the data.
 *
 * That number is the whole verdict of this journey. `atLeast(…, 1)` asserts
 * PRESENCE, so a match that is not a control is a FALSE GREEN — and because
 * this journey is ledgered known-red, a false green here does not merely
 * mis-measure, it FAILS THE RUN with "this journey is in ledger.json as
 * known-red and it is GREEN" and invites someone to delete a ledger entry over
 * an event-log string. The generosity was written when this assertion claimed
 * an ABSENCE, where erring wide is the safe direction; it is the unsafe
 * direction for the presence claim the file now makes.
 *
 * So the regex is applied to what an AUTHOR wrote as a label:
 *
 *   * `data-action`, `aria-label`, `title` — always authored, never content;
 *   * the element's text, but only where that text is SHORT ENOUGH TO BE A
 *     LABEL. A control says "Trace to origin"; a trace row is four columns of
 *     recorded data flattened together.
 *
 * The threshold is a property of labels, not a blacklist of classes, so a pane
 * that gains a row kind does not need an edit here. Both counts are returned
 * and both are printed: the wide one stays visible in the transcript, so a
 * future affordance that this narrowing would miss shows up as a gap between
 * two numbers rather than as silence.
 */
const READ_CONTROLS = () => {
  const RE = /origin|where did this come from|provenance|trace value/i;
  const LABEL_MAX_CHARS = 60;
  const shown = (e) =>
    !!e &&
    typeof e.checkVisibility === "function" &&
    e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
  const candidates = [
    ...document.querySelectorAll("a, button, [data-action], [role=button]"),
  ];
  const attrs = (e) =>
    `${e.getAttribute("data-action") ?? ""} ${e.getAttribute("aria-label") ?? ""} ${
      e.getAttribute("title") ?? ""
    }`;
  const label = (e) => (e.textContent ?? "").replace(/\s+/g, " ").trim();
  return {
    // The verdict: an authored label offering the gesture.
    originAffordances: candidates.filter(
      (e) => RE.test(attrs(e)) || (label(e).length <= LABEL_MAX_CHARS && RE.test(label(e))),
    ).length,
    // The old, fully generous reading, kept and REPORTED so the narrowing is
    // visible as a number rather than as an absence.
    originMentions: candidates.filter((e) => RE.test(`${label(e)} ${attrs(e)}`)).length,
    // UNCHANGED from the form this control was written in — `a, button,
    // [data-action]`, on screen. It answers "did the bundle run", and moving it
    // while narrowing the selector above would have made the two numbers
    // incomparable with every reading taken before today.
    interactive: [...document.querySelectorAll("a, button, [data-action]")].filter(shown).length,
  };
};

export async function run({ browser, site, j }) {
  // ---- half one: the product no longer claims what it cannot do -----------
  const home = await visit(browser, site.origin, "/");
  try {
    const rendered = await home.page.evaluate(() => document.body.innerText);
    j.expect(
      !PROMISE.test(rendered),
      "the home page does NOT promise that a value can be traced to its origin",
      PROMISE.test(rendered)
        ? "the sentence is back on screen — the surface must land before the copy does"
        : "the hero claims stepping and the call trace, both of which it has",
    );

    const meta = await home.page.evaluate(
      () =>
        document.querySelector('meta[name="description"]')?.getAttribute("content") ?? "",
    );
    j.expect(
      !PROMISE.test(meta),
      "and the meta description does not make the promise to search results either",
      meta.length > 0 ? "" : "NO meta description at all — this assertion would pass vacuously",
    );
    // Non-vacuity for the two above: an empty page and a missing tag each
    // satisfy "does not contain the sentence" for free.
    j.expect(
      rendered.length > 200 && meta.length > 40,
      "CONTROL: the page and the meta tag both have substantial copy, so the two absences above are measurements",
      `body ${rendered.length} chars, meta ${meta.length} chars`,
    );
  } finally {
    await home.page.close();
  }

  // ---- half two: the capability itself ------------------------------------
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(sessions, 3, "transactions whose landing is a session with rows in its Code pane");

  // TWO SUBJECT LISTS, EACH ASSERTED NON-EMPTY, AND NO FALLBACK BETWEEN THEM.
  // See the header: `find((t) => !t.real) ?? sessions[0]` is what kept this
  // journey on the demo chain for its whole life. Selecting by filter and
  // asserting each size makes a corpus that has lost one kind of recording a
  // RED — which is what it is, because the journey can no longer judge the
  // claim it makes — instead of a green over whichever kind survived.
  const synthetic = sessions.filter((t) => !t.real);
  const realCaptures = sessions.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the demo arm has a subject");
  j.atLeast(
    realCaptures.length,
    1,
    "SUBJECTS: REAL-capture sessions, so the chain arm has a subject",
  );

  const subject = synthetic[0];
  j.note(`driving ${subject.debugPath}`);

  // The SERVED frame: the same URL with scripting off, which is what the
  // exporter wrote and what the visitor sees before the bundle runs.
  //
  // `javaScriptEnabled` is a CONTEXT option in Playwright, not a page method —
  // this harness is Playwright (`chromium.launch` in lib/probe.mjs), and the
  // Puppeteer spelling `page.setJavaScriptEnabled(false)` throws here rather
  // than quietly leaving scripting on. Worth the sentence: a served-frame
  // reading taken with the bundle still running would compare the hydrated
  // page against itself and report "unchanged" for every session, which is the
  // failing verdict below arrived at for entirely the wrong reason.
  const servedCtx = await browser.newContext({ javaScriptEnabled: false });
  let served;
  try {
    const servedPage = await servedCtx.newPage();
    await servedPage.goto(site.origin + subject.debugPath, {
      waitUntil: "domcontentloaded",
      timeout: 45000,
    });
    served = await servedPage.evaluate(READ_ROWS);
  } finally {
    await servedCtx.close();
  }

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session went live, so the panes on screen are the bundle's to write",
      `phase=${live.facts.phase}`,
    );

    const probe = await live.page.evaluate(READ_CONTROLS);
    const hydrated = await live.page.evaluate(READ_ROWS);

    // NON-VACUITY. Comparing two empty panes would report "unchanged" for a
    // reason that has nothing to do with the engine.
    j.atLeast(
      served.shown,
      1,
      `the SERVED frame already shows Values rows, so the comparison below has something to compare (${served.rows} rows, ${served.shown} shown)`,
    );

    // CONTROL, and the one the previous version of this journey lacked: the
    // bundle demonstrably rewrites SOMETHING on this page. Without it, "the
    // Values pane did not change" is equally explained by a bundle that never
    // ran, and the defect below would be indistinguishable from a dead engine.
    j.atLeast(
      probe.interactive,
      5,
      `CONTROL: the live page has ${probe.interactive} interactive controls and reached phase=ready, so the bundle ran`,
    );

    // THE DEFECT. `ct/load-locals` is sent and its reply discarded upstream, so
    // the pane the visitor ends up reading is byte-for-byte the one the
    // exporter wrote. A pane that is the engine's would differ.
    j.expect(
      hydrated.text !== served.text,
      "the Values pane a live session shows is the ENGINE's, not the served frame's",
      hydrated.text === served.text
        ? `identical to the served frame (${hydrated.rows} rows) — the SDK discards the ct/load-locals reply, so StateVM.currentVariables is empty and the PaneLatch never fires`
        : `served ${served.rows} rows, live ${hydrated.rows} rows`,
    );

    // THE CONSEQUENT. The wide count is printed beside the verdict so the
    // narrowing in READ_CONTROLS is auditable from the transcript: on this page
    // the two agree, and where they ever diverge the gap says which reading to
    // go and look at.
    j.note(
      `origin affordances: ${probe.originAffordances} labelled, ${probe.originMentions} matched anywhere in a candidate's text`,
    );
    j.atLeast(
      probe.originAffordances,
      1,
      "some control offers to trace a value to its origin",
    );
  } finally {
    await live.page.close();
  }

  // ── THE CHAIN CAPTURE ─────────────────────────────────────────────────
  //
  // A separate subject and a separate page, so the chain arm reddens on its
  // own instead of being answered by a demo session. This is the arm the
  // fallback removed above had made unreachable for this journey's whole life.
  await realArm(browser, site, j, realCaptures[0]);
}

/**
 * The same claim, over a REAL capture.
 *
 * WHAT THIS ARM ASSERTS, AND WHAT IT DELIBERATELY DOES NOT
 * -------------------------------------------------------
 * Not the Values-pane comparison the demo arm makes. A chain recording is rung
 * 3 — `demo_session.nim` states the consequence verbatim: "This recording
 * carries no variable names: naming a local needs debug symbols, which an Aztec
 * contract class does not publish" — so its served frame may legitimately carry
 * no Values rows at all, and "the live pane differs from the served one" would
 * then be a claim about a corpus rather than about the engine. Asserting it
 * here would put a SECOND, unrelated red on a journey whose ledger entry speaks
 * for exactly one, which is how a ledgered entry comes to absorb a failure it
 * does not name.
 *
 * So the two panes are REPORTED, as notes, and the arm asserts the thing the
 * claim is actually about: that on a chain capture too, with the bundle
 * demonstrably running, nothing on screen offers to trace a value to its
 * origin. That is one number, measured by the same selector as the demo arm's,
 * on the subject this journey had never once looked at.
 *
 * The assertion texts are worded so that none of them CONTAINS another
 * assertion's text: `selftest.mjs` resolves an arm's target with
 * `r.what.includes(assertion)` and treats two hits as no hit, so a "REAL: " +
 * verbatim copy of a demo-arm assertion would silently make a future arm on
 * either of them unrunnable.
 */
async function realArm(browser, site, j, subject) {
  j.note(`driving REAL capture ${subject.debugPath}`);

  const servedCtx = await browser.newContext({ javaScriptEnabled: false });
  let served;
  try {
    const servedPage = await servedCtx.newPage();
    await servedPage.goto(site.origin + subject.debugPath, {
      waitUntil: "domcontentloaded",
      timeout: 45000,
    });
    served = await servedPage.evaluate(READ_ROWS);
  } finally {
    await servedCtx.close();
  }

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  try {
    j.expect(
      live.settled && !live.timedOut,
      "REAL: the chain capture reached a live session, so the bundle owns its panes",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );

    const probe = await live.page.evaluate(READ_CONTROLS);
    const hydrated = await live.page.evaluate(READ_ROWS);

    // REPORTED, NOT ASSERTED — see the header. A rung-3 recording with no
    // variable names is a state the product is allowed to be in, and the number
    // belongs in the transcript so the arm below is read with it in view.
    j.note(
      `REAL Values pane: served ${served.rows} rows (${served.shown} shown), live ${hydrated.rows} rows` +
        `${hydrated.text === served.text ? " — identical text" : " — different text"}`,
    );

    // CONTROL. Without it, "no origin affordance" is equally explained by a
    // page the bundle never reached, and the red below would be a statement
    // about this suite rather than about the product.
    j.atLeast(
      probe.interactive,
      5,
      `REAL: CONTROL — the chain capture's live page carries ${probe.interactive} interactive controls, so the bundle ran here too`,
    );

    // THE CONSEQUENT, on the subject this journey had never judged — and the
    // page the false positive was found on. The two numbers are printed
    // together because on a chain capture they DISAGREE: the event log's own
    // `origin=settled-chain` field is matched by the wide reading and by no
    // authored label, which is the whole reason READ_CONTROLS narrowed.
    j.note(
      `REAL origin affordances: ${probe.originAffordances} labelled, ${probe.originMentions} matched anywhere in a candidate's text`,
    );
    j.atLeast(
      probe.originAffordances,
      1,
      "REAL: a chain capture offers no way to trace a value to its origin either",
    );
  } finally {
    await live.page.close();
  }
}
