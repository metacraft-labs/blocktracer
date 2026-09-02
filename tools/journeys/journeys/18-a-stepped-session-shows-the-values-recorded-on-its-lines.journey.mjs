// "A visitor who steps sees the engine's recorded values, placed on the source
//  lines they were recorded on."
//
// The narrower half of the report. The other half — that the overlay FOLLOWS the
// position and belongs to the function the session is in — is journey 19, which
// is RED and ledgered with the cause. Splitting them is not bookkeeping: they
// close on different fixes, and one entry in the ledger has to be able to close
// on one of them.
//
// `Omniscience-Flow.md` (the inline values overlay and its loop rail), and
// Page-Descriptions.md §7.0 — "hydration is what turns a POSITIONED first frame
// into a STEPPING one", and every pane it turns.
//
// WHAT WAS ON SCREEN BEFORE THIS JOURNEY EXISTED
// ----------------------------------------------
// Nothing. Measured on `dev`, on the built site with the published engine
// staged, with `Worker.postMessage` and the worker's message handler wrapped
// before the page's own scripts ran:
//
//   * `ct/load-flow` went out on every position change — 4 requests over 4
//     steps. The request was never missing.
//   * `ct/updated-flow` came back on every one of them, on BOTH answer paths,
//     carrying `viewUpdates[0].steps`: 14 steps with values on 13 distinct
//     source lines for the Noir recording, 345 for an Aztec capture.
//   * The source pane carried 0 value labels at the landing position and 0
//     after four steps — against 23 on the SERVED frame of the same page, read
//     with scripting off.
//
// So the answer arrived and was discarded, and hydration REMOVED an overlay the
// static export had drawn. `flow_vm.applyFlowUpdate` reads `loops` and
// `location.rrTicks` out of that answer and leaves `steps` untouched;
// `FlowVM.steps` has one writer, a setter nothing calls.
//
// THE FALSE PASS THIS JOURNEY IS WRITTEN AGAINST
// ----------------------------------------------
// "The overlay is present" proves nothing, and would have been GREEN on the
// served frame throughout the defect — 23 labels, none of them live. The same
// trap journeys 07 and 11 were seeded from, and it arrives here in its purest
// form because the exporter ships a REAL overlay for the served position: the
// artefact whose persistence would be the defect is indistinguishable, by a
// presence check, from the fix.
//
// So presence is never the verdict. Three things are, and each is a relation
// between two readings the page itself produced:
//
//   1. the overlay CHANGES as the position moves — a pane frozen on the served
//      frame, or on the first window it received, fails;
//   2. every annotated line lies inside the function the session is in, where
//      "the function the session is in" is derived from the page's own source
//      text and the page's own position mark and from nothing the overlay says;
//   3. what is on screen is not what the exporter wrote — the served reading is
//      taken first, with scripting off, and is disqualifying.
//
// NOTHING BELOW NAMES A VALUE, a variable, a line or a step.
//
// AND IT IS DRIVEN OVER BOTH KINDS OF RECORDING, for the reason six journeys in
// this directory had to learn: a `??` fallback between subject kinds makes "none
// of this kind was available" and "one passed" the same green. The two kinds
// have DIFFERENT correct answers here and that is the point of driving both. A
// chain capture is rung 3 — instruction level, no published source — and
// `flow_view`'s rule 1 is that below source level there is nothing to place a
// value against and the honest overlay is ABSENT. The engine sends 345 steps
// with values for it anyway. So the real-capture arm asserts the overlay stays
// empty, which is the one assertion in this file that a "draw what we have"
// implementation would fail.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-stepped-session-shows-the-values-recorded-on-its-lines";
export const claim =
  "A visitor who steps sees the engine's recorded values, placed on the source lines they were recorded on.";
export const spec = "Omniscience-Flow.md; Page-Descriptions.md §7.0 — BlockTracer";
export const assertions = 2 + 6 + 5; // 13
export const needsEngine = true;

/** How many times each session is stepped. See journey 11 on why it is a walk. */
const WALK = 10;

/**
 * The viewport this journey judges at, stated rather than inherited.
 *
 * The overlay is laid out against the CODE PANE's width by a container-query
 * ladder — `session_view.ValueBucketPanePx`, eight regimes — and the markup
 * carries every regime's answer at once. So "how many values are on screen" is
 * a question about a width, and at Playwright's launch default the answer is
 * legitimately zero labels and a row of `+N` counts. That is the product
 * working (`flow_view` rule 5: "a value that is drawn where nobody can read it
 * has not been shown"), and a journey that had not said which width it meant
 * would have reported it as the defect.
 *
 * `wide` is `tools/capture/views.mjs`'s primary size, so this reads the overlay
 * at the width the visual corpus photographs it at rather than at a second one
 * invented here.
 */
const VIEWPORT = { width: 1920, height: 1080 };

/**
 * Merge the function headers several readings saw into one map per document.
 *
 * Necessary rather than tidy. `openAtCurrent` narrows the ACTIVE document to
 * six lines above the position, so a page whose session has stepped past a
 * function's header no longer renders it — at the demo session's later
 * positions `fn main` is not in the DOM at all, and a single reading would
 * report "no enclosing function" for a line plainly inside one. The headers are
 * a fact about the FILE and do not move, so accumulating them across the walk
 * (and across the served reading, whose window is at a different position and
 * therefore shows different ones) recovers the file's own list.
 */
function mergeHeaders(into, facts) {
  for (const [doc, heads] of Object.entries(facts.fnHeaders ?? {})) {
    const seen = (into[doc] ??= new Map());
    for (const h of heads) if (h.n >= 0) seen.set(h.n, h.name);
  }
  for (const [doc, last] of Object.entries(facts.docLastLine ?? {})) {
    into.$last ??= {};
    into.$last[doc] = Math.max(into.$last[doc] ?? -1, last);
  }
  return into;
}

/**
 * The function containing `line` in `doc`, from merged headers, or `null`.
 *
 * `null` is a real answer and not a failure: a Noir file's `mod` and `use`
 * lines are outside every function, and a session standing on one is standing
 * outside every function. The journey counts those readings separately rather
 * than folding them in, because "no function contains this line" and "the
 * overlay is in the wrong function" must not be the same verdict.
 */
function enclosing(headers, doc, line) {
  const heads = headers[doc];
  if (!heads || heads.size === 0 || !Number.isFinite(line) || line < 0) return null;
  const ns = [...heads.keys()].sort((a, b) => a - b);
  let open = null;
  for (const n of ns) if (n <= line && (open === null || n > open)) open = n;
  if (open === null) return null;
  const next = ns.find((n) => n > open);
  return {
    name: heads.get(open),
    first: open,
    last: next === undefined ? (headers.$last?.[doc] ?? open) : next - 1,
  };
}

/** One reading of the overlay, reduced to what a visitor could read off it. */
const reading = (facts) => ({
  step: facts.step,
  marked: Number(facts.markedNumber),
  doc: facts.shownDoc,
  facts,
  lines: (facts.flowLines ?? []).map((r) => r.n),
  // The whole overlay as one comparable string. A class change elsewhere must
  // not present as "the engine supplied different values", so this is the
  // rendered text and the line it is on, and nothing else.
  text: (facts.flowLines ?? []).map((r) => `${r.n}:${r.labels.join(",")}`).join(" | "),
  labels: (facts.flowLines ?? []).reduce((n, r) => n + r.labels.length, 0),
  labelValues: (facts.flowLines ?? []).flatMap((r) => r.values ?? []),
});

/**
 * Read once the page has stopped changing.
 *
 * For STABILITY, not for a particular sentence: the overlay arrives a round
 * trip after the position does, so a reading taken the instant the step lands
 * would catch the pane between the two and report the defect this journey
 * exists to detect. Waiting for a specific string instead would assert the
 * product's copy from inside the timing loop and hang the day it changed.
 */
async function settled(page, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  let seen = JSON.stringify(reading(await readFacts(page)));
  let stable = 0;
  let last = null;
  while (Date.now() < deadline && stable < 3) {
    await page.waitForTimeout(150);
    last = reading(await readFacts(page));
    const now = JSON.stringify(last);
    stable = now === seen ? stable + 1 : 0;
    seen = now;
  }
  return last ?? reading(await readFacts(page));
}

/** The served frame's overlay: the same URL with scripting off. */
async function servedOverlay(browser, origin, path) {
  // The SAME viewport as the live reading. Two widths would compare two regimes
  // of the same overlay and report a difference the position had nothing to do
  // with — which is the one comparison this journey cannot afford to get wrong,
  // since "it is still the exporter's overlay" is its central negative.
  const ctx = await browser.newContext({ javaScriptEnabled: false, viewport: VIEWPORT });
  try {
    const page = await ctx.newPage();
    await page.goto(origin + path, { waitUntil: "domcontentloaded", timeout: 45000 });
    return reading(await readFacts(page));
  } finally {
    await ctx.close();
  }
}

/** Step once and wait for the position to move; `null` when it did not. */
async function stepOnce(page, before) {
  await page.click('[data-action="step-forward"]').catch(() => {});
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    const now = reading(await readFacts(page));
    if (now.step !== before.step || now.marked !== before.marked) return now;
    await page.waitForTimeout(150);
  }
  return null;
}

/** Walk a session, collecting one settled reading per position reached. */
async function walk(browser, origin, tx) {
  const { page, facts } = await visit(browser, origin, tx.debugPath, {
    settle: (f) => f.phase === "ready",
    timeoutMs: 60000,
    viewport: VIEWPORT,
  });
  const readings = [await settled(page)];
  const headers = mergeHeaders({}, facts);
  mergeHeaders(headers, readings[0].facts);
  for (let i = 0; i < WALK; i++) {
    const moved = await stepOnce(page, readings[readings.length - 1]);
    if (moved === null) break;
    const next = await settled(page);
    mergeHeaders(headers, next.facts);
    readings.push(next);
  }
  return { readings, headers, phase: facts.phase };
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  // Two lists, each asserted non-empty, and both driven. Never a `??` between
  // them: they have different correct answers below, and a fallback would make
  // "the other kind was not in the tree" pass as "this kind was checked".
  //
  // The predicates are the corpus's OWN classification, read out of the served
  // markup — `hasSource` and `instructionLevel`, which it derives from the
  // rows the page actually rendered rather than from the chain's name. That is
  // what makes the two arms principled rather than a demo/real split that
  // happens to line up today: a chain capture whose contract gains a verified
  // artifact moves into the first arm on its own, and this file needs no edit.
  const sourceLevel = j.subjects(
    all.filter((t) => landingOf(t.phase) === "session" && t.hasSource),
    1,
    "the tree holds a session whose Code pane shows SOURCE",
  );
  const instructionLevel = j.subjects(
    all.filter((t) => landingOf(t.phase) === "session" && t.instructionLevel),
    1,
    "the tree holds a session whose Code pane shows an INSTRUCTION LISTING",
  );

  // ── the source-level arm ────────────────────────────────────────────────
  {
    const tx = sourceLevel[0];
    const served = await servedOverlay(browser, site.origin, tx.debugPath);
    const { readings, headers } = await walk(browser, site.origin, tx);
    // The served reading's window sits at a different position and therefore
    // renders different headers; folding it in is one more independent look at
    // the same file.
    mergeHeaders(headers, served.facts);

    // CONTROL, first and counted: the walk actually walked. Every claim below
    // quantifies over these readings, and a walk that never moved would satisfy
    // all of them vacuously.
    j.atLeast(readings.length, 4, "CONTROL: the session reached several positions");
    const positions = new Set(readings.map((r) => r.step));
    j.expect(
      positions.size === readings.length,
      "CONTROL: every reading was taken at a different position",
      `${positions.size} distinct steps over ${readings.length} readings`,
    );

    // 1. THERE ARE VALUES ON SCREEN AT ALL, and it is a verdict rather than a
    //    control: for the whole life of the defect this number was zero at
    //    every position of every hydrated session, while the SERVED frame of
    //    the same page showed 23 labels. It is the first half of the report,
    //    and the assertions after it are the half a presence check cannot see.
    const withOverlay = readings.filter((r) => r.labels > 0);
    j.atLeast(withOverlay.length, 1, "a live session is given a values overlay at all");

    // 2. AND EACH LABEL CARRIES A VALUE, not just a name.
    //
    //    `live_locals.valueText` renders CodeTracer's `Value`, and its own
    //    header records that the pinned SDK's equivalent has the wrong ordinal
    //    for seven of eleven kinds — it renders a Noir `Field` correctly and
    //    every string, bool, char, array and tuple as the empty string. That
    //    produces a full overlay of `name=` with nothing after the sign: the
    //    right number of labels, in the right places, saying nothing. A count
    //    cannot see it, so the labels are read.
    //
    //    NOTHING NAMES A VALUE. The test is that a label has a right-hand side,
    //    not what the right-hand side says.
    const allLabels = withOverlay.flatMap((r) => r.labelValues);
    j.atLeast(allLabels.length, 8, "SUBJECTS: label values to inspect");
    j.countIs(
      allLabels.filter((v) => !/[0-9A-Za-z]/.test(v)).length,
      0,
      "every value label carries a value and not just a name",
    );

    // 3. AND IT IS NOT THE EXPORTER'S. The served overlay is a real one, drawn
    //    for the frame the page was served at, and a hydrated session still
    //    showing it is the defect wearing the fix's clothes.
    j.expect(
      withOverlay.every((r) => r.text !== served.text),
      "no live reading is the overlay the exporter wrote",
      `served ${served.labels} labels on ${served.lines.length} lines; ` +
        `live readings ${withOverlay.map((r) => r.labels).join("/")}`,
    );

    // WHAT IS DELIBERATELY NOT ASSERTED HERE, AND WHERE IT WENT
    //
    // "The overlay changes as the position moves" and "every annotated line is
    // inside the function the session is in" are the OTHER half of the report,
    // and both are RED. They are journey 19's, with one ledger entry naming one
    // cause: the engine answers every `ct/load-flow` with the same file-wide
    // window, computed for tick 0, so the labels do not move and some of them
    // sit on lines outside the enclosing function.
    //
    // They were briefly asserted here and passed, and it is worth recording why
    // they did. The pane used to open six lines above the position
    // (`openAtCurrent`), so the SET OF LABELS ON SCREEN was a function of the
    // position even though the window behind it was a constant, and the labels
    // that fell outside the function were the ones scrolled off the top. When
    // `a-source-file-is-shown-whole` landed and the pane stopped cutting the
    // file, both assertions went red WITHOUT the overlay changing at all — the
    // cut had been supplying the evidence. Keeping them here would have made
    // this journey red for a defect it does not name, and moving them is what
    // lets one entry in the ledger close on one fix.
  }

  // ── the instruction-level arm ───────────────────────────────────────────
  // A different correct answer, and the assertion a "draw what we have"
  // implementation fails. The engine sends this recording a full window of
  // values; there is no source for them to be placed against, and rule 1 is
  // that they are ABSENT rather than approximate.
  {
    const tx = instructionLevel[0];
    const { readings } = await walk(browser, site.origin, tx);
    j.atLeast(readings.length, 2, "REAL: the chain session reached several positions");
    j.expect(
      readings.some((r) => r.step !== readings[0].step),
      "REAL: CONTROL — the walk moved the position",
      `steps ${readings.map((r) => r.step).join(" -> ")}`,
    );
    // THE PRECONDITION FOR AN ABSENCE TO BE A MEASUREMENT.
    //
    // Both assertions below are `countIs(…, 0)` over `flowLines`, and
    // `probe.mjs` returns `flowLines: []` for ANY page where `shownDocs.length
    // !== 1` — deliberately, because the source pane holds every document at
    // once and a document-wide read would report the overlay of a file nobody is
    // looking at. The consequence here is that a session showing zero documents,
    // or four, produces an empty overlay reading and satisfies "there is no
    // overlay" for a reason that has nothing to do with the claim.
    //
    // The source arm has a positive backstop — it asserts labels are PRESENT, so
    // an empty read reddens there. This arm asserts only absences, so it has
    // none, and the precondition has to be stated. `docsShown` comes from the
    // same reading and is exactly the condition `flowLines` gates on.
    j.countIs(
      readings.filter((r) => r.facts.docsShown === 1).length,
      readings.length,
      "REAL: CONTROL — every reading had one document on screen, so an empty overlay is a measurement",
    );
    j.countIs(
      readings.filter((r) => r.labels > 0).length,
      0,
      "REAL: an instruction-level session is given no values overlay",
    );
    j.countIs(
      readings.filter((r) => r.lines.length > 0).length,
      0,
      "REAL: and no annotated lines at all",
    );
  }
}
