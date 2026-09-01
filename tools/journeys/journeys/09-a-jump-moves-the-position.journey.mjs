// "A visitor who clicks a row in the navigation regions sees the position move
//  THERE."
//
// Debugger-Integration.md §3 (the deferred `ct/goto-ticks` item) and §4.2, which
// calls this "the single most valuable interaction in the product — 'take me to
// the line that wrote this value'".
//
// WHY THIS IS A SECOND JOURNEY AND NOT A CASE IN 03
// -------------------------------------------------
// Journey 03 drives the TOOLBAR, and the toolbar and the rows are two different
// code paths that arrive at the same store. `invoke` goes through the ViewModel's
// `invokeToolbarStep`; a row click goes through `gotoTicks`, which sends
// `ct/goto-ticks` and — unlike the toolbar — does NOT call `applyStop` itself. It
// relies entirely on the position arriving back as an unsolicited event.
//
// So a defect that leaves the toolbar working and the rows dead is available,
// and it is the exact shape this repository's README already records from the
// sibling product: `test_every_entry_form_reaches_the_application` proved every
// URL form CLASSIFIES while the function that would consult the classifier at
// run time had ZERO CALLERS. Nothing noticed, because nothing asserted that the
// gesture produced anything. A row whose click handler was never bound, or whose
// bound handler returns before sending, is that defect with a different name —
// and until this file existed, eight journeys and 68 assertions did not click a
// single row.
//
// THE TRAP, THE SAME ONE 03 IS WRITTEN AGAINST
// --------------------------------------------
// Verification-Harness-Traps.md §2: a chain of `success: true` is not a result.
// Measured against the bundle blocktracer.org was serving while this file was
// written, a call-trace row click returns `ct/goto-ticks` success, advances `?t=`
// from absent to 1 and rewrites the recovery anchor from `main.nr:1` to
// `main.nr:12` — while `data-step` stays pinned at 128 and the source pane
// carries ZERO position marks. Every success along the way was real.
//
// So the URL is a CONTROL — proof the gesture reached the engine — and never the
// verdict. The verdict is the step the page reports and the line the pane marks.
//
// AND THE VERDICT IS "THERE", NOT "SOMEWHERE"
// -------------------------------------------
// The claim is that the position moves to the row the visitor clicked, so the
// assertion is an EQUALITY between two things the page reports: the step the row
// names in its own `data-step`, and the step the session reports afterwards.
// "The step changed" would be satisfied by a jump that landed anywhere, which is
// most of what a broken seek does. Nothing here names a step — the target is
// discovered by reading the rows, per rule 4.
//
// AND IT IS DRIVEN OVER BOTH KINDS OF RECORDING
// ---------------------------------------------
// THE DEFECT THIS SECTION EXISTS FOR WAS IN THIS FILE. Until 2026-09-01 the
// subject was chosen as
//
//     withSession.find((t) => !t.real) ?? withSession[0]
//
// which PREFERS a synthetic fixture. With 15 synthetic sessions in the corpus
// the `??` arm could never be reached, so eighteen assertions and thirteen
// killed mutation arms had proven the gesture exclusively on the demo chain —
// while a visitor reported the mark not following their jumps on a REAL
// `aztec-testnet` transaction. Machinery present, correct, and pointed at the
// wrong subject: the same shape as `demo_session.nim`'s `FixtureLine = 32`,
// which made 115 assertions tautological.
//
// Measured on production the day this was written, the two worlds differ
// exactly where it matters: on all six real captures the call trace and event
// log render NO rows at all — the recordings resolve no source positions, so
// there is nothing to click — while the demo chain renders seven navigable
// rows and the jump works. A synthetic-only subject could not see that.
//
// So the arms are SEPARATE and BOTH REQUIRED, and neither may fall back to the
// other. The real arm asserts what a real capture must honour whether or not it
// has rows: the mark exists, the mark FOLLOWS the session, and a region with no
// rows SAYS SO rather than rendering an empty box. A silent empty region is the
// visitor's "it does nothing when I click", and it is the one state that must
// never read as healthy.
//
// EMPTY SETS. `j.atLeast(…, 1)` guards each subject list, because universal
// quantification over nothing passes: "every real capture jumps correctly" is
// vacuously true of a corpus with no real captures, and that is precisely how
// the gap above stayed invisible for as long as it did.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-jump-moves-the-position";
export const claim =
  "A visitor who clicks a row in the navigation regions sees the position move there.";
export const spec = "Debugger-Integration.md §3, §4.2 — BlockTracer";
export const assertions = 34;
export const needsEngine = true;

/**
 * The rows of one navigation region, as the page presents them.
 *
 * RENDERED, NOT PRESENT — the same rule probe.mjs states for `.srcline`. The
 * call trace holds rows for sections that are not on screen, and a journey that
 * counted the DOM would quantify over rows no visitor can click.
 */
const readRows = (page, selector) =>
  page.evaluate((sel) => {
    const shown = (e) =>
      !!e &&
      typeof e.checkVisibility === "function" &&
      e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
    const all = [...document.querySelectorAll(sel)];
    const onScreen = all.filter(shown);
    const step = (r) => r.getAttribute("data-step");
    return {
      total: all.length,
      shown: onScreen.length,
      // A row "names a step to jump to" when it carries the coordinate the seek
      // is made of. `gotoTicks` returns before sending for a row that does not,
      // so a region of rows without one is a region of inert rows.
      shownNamingAStep: onScreen.filter((r) => (step(r) ?? "").length > 0).length,
      steps: onScreen.map(step),
    };
  }, selector);

/** The index, among ALL rows of `selector`, of one on screen naming a step the session is not on. */
const pickTarget = (page, selector) =>
  page.evaluate((sel) => {
    const shown = (e) =>
      !!e &&
      typeof e.checkVisibility === "function" &&
      e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
    const all = [...document.querySelectorAll(sel)];
    const now = document.querySelector(".dbg")?.getAttribute("data-step");
    const row = all
      .filter(shown)
      .find((r) => (r.getAttribute("data-step") ?? "") !== "" && r.getAttribute("data-step") !== now);
    if (!row) return null;
    return {
      index: all.indexOf(row),
      step: row.getAttribute("data-step"),
      label: (row.textContent ?? "").trim().slice(0, 60),
    };
  }, selector);

/**
 * Every pane in the session, and whether it says ANYTHING.
 *
 * A pane is MUTE when it renders no rows and states no reason — an empty box
 * where the product's own §7.0 requires that "no state renders less than the
 * truth". That is the state a visitor reads as "I clicked and nothing
 * happened", and on a recording with no resolved source positions it is the
 * difference between "this recording carries no frames, here is why" and a
 * navigation region that silently does not work.
 *
 * Read by PROPERTY and never by pane name: a pane counts as speaking if it has
 * rows of any kind or a non-empty note. A selector spelling `#pane-calltrace`
 * would be a second place to rename, and would go quietly green if the pane it
 * names ever stopped being rendered at all.
 */
const readPaneHealth = (page) =>
  page.evaluate(() => {
    const panes = [...document.querySelectorAll(".dbg .pane")];
    const speaks = (p) =>
      p.querySelectorAll(".ctrow,.evrow,.strow,.srcline").length > 0 ||
      [...p.querySelectorAll(".panenote")].some((n) => (n.textContent ?? "").trim().length > 0);
    return {
      panes: panes.length,
      mute: panes.filter((p) => !speaks(p)).length,
      muteTitles: panes
        .filter((p) => !speaks(p))
        .map((p) => p.querySelector(".panetitle")?.textContent?.trim() || p.id || "(unnamed)"),
    };
  });

/** The navigation rows on screen, across BOTH regions, and how many name a step. */
const readNavigable = (page) =>
  page.evaluate(() => {
    const shown = (e) =>
      !!e &&
      typeof e.checkVisibility === "function" &&
      e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
    const rows = [...document.querySelectorAll(".ctrow,.evrow")].filter(shown);
    return {
      shown: rows.length,
      namingAStep: rows.filter((r) => (r.getAttribute("data-step") ?? "").length > 0).length,
    };
  });

/**
 * "The position moved" as a RELATION, never a line number alone.
 *
 * THE DEMO ARM CAUGHT THIS THE DAY THE LIVE CALL TRACE LANDED. With the pane
 * fed by the engine rather than by the export, the first row naming a step the
 * session is not on is `iterate_asteroids` at step 9 — and jumping there moves
 * the mark from `main.nr:1` to `shield.nr:1`. The line number is 1 both times.
 * A journey comparing numbers would have called a working jump broken, which is
 * the expensive direction: a gate that cries wolf gets switched off.
 *
 * `probe.mjs` states this rule for its own reading of the marked line ("read as
 * a RELATION — its own number and its own text"); this is the same rule applied
 * to the comparison.
 */
const positionMoved = (before, after) =>
  after.markedNumber !== null &&
  (after.markedNumber !== before.markedNumber || after.markedDoc !== before.markedDoc);

const positionOf = (f) => `${f.markedDoc ?? "?"}:${f.markedNumber ?? "?"}`;

/**
 * How many navigation rows the EXPORT ships for this page, read out of the
 * served markup rather than out of a rendered DOM.
 *
 * THE CONTROL THAT WOULD HAVE CAUGHT THE DEFECT THIS JOURNEY WAS BLIND TO. The
 * live Call Trace and Event Log were never populated on any capture: the engine
 * answered `ct/updated-calltrace` and nothing wrote the reply into the store.
 * The demo chain hid it completely, because the static export ships fixture
 * rows for it — `ctrow` sat at 12 before a step and 12 after, and 12 was the
 * export's number. Every assertion in this file was satisfied by those rows.
 *
 * Fetched, then parsed with `DOMParser` and counted THROUGH THE SAME SELECTOR
 * the hydrated side uses. `DOMParser` runs no scripts, so this is still what the
 * export wrote rather than what hydration made of it — and counting both sides
 * the same way is the part that has to be right. The first draft split the raw
 * text on `class="ctrow`, which also matches the `ctrows` CONTAINER, so it
 * reported 22 where the DOM reported 20 and the control passed on a two-row
 * measurement artefact while the live path was fully disabled. Mutation arm O
 * caught exactly that, which is what arms are for.
 */
const servedNavRows = (page, url) =>
  page.evaluate(async (u) => {
    const text = await (await fetch(u, { cache: "no-store" })).text();
    const doc = new DOMParser().parseFromString(text, "text/html");
    return doc.querySelectorAll(".ctrow,.evrow").length;
  }, url);

/**
 * Click, then wait for ANY of the three things a jump could move.
 *
 * A predicate and never a sleep — journey 03's reason applies unchanged: a jump
 * that moves nothing must be a timeout with all three reported, not a race this
 * suite happened to lose.
 */
async function jump(page, index, selector, before) {
  await page.evaluate(
    ({ sel, i }) => document.querySelectorAll(sel)[i].scrollIntoView({ block: "center" }),
    { sel: selector, i: index },
  );
  await page.click(`${selector} >> nth=${index}`);
  const deadline = Date.now() + 15000;
  let after = before;
  while (Date.now() < deadline) {
    after = await readFacts(page);
    if (
      after.urlQuery !== before.urlQuery ||
      after.step !== before.step ||
      after.markedNumber !== before.markedNumber
    )
      break;
    await page.waitForTimeout(200);
  }
  return after;
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with rows in its Code pane");

  // TWO SUBJECT LISTS, EACH ASSERTED NON-EMPTY, AND NO FALLBACK BETWEEN THEM.
  // `find(…) ?? withSession[0]` is what hid this journey's synthetic-only reach
  // for its whole life: the fallback made "no real capture was available" and
  // "a real capture passed" the same green. Selecting by filter and asserting
  // the size makes a corpus that has lost one kind of recording a RED, which is
  // what it is — the journey can no longer judge the claim it makes.
  const synthetic = withSession.filter((t) => !t.real);
  const realCaptures = withSession.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the demo arm has a subject");
  j.atLeast(
    realCaptures.length,
    1,
    "SUBJECTS: REAL-capture sessions, so the arm the visitor's report came from has a subject",
  );

  const subject = synthetic[0];
  j.note(`driving ${subject.debugPath}`);

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session reached `ready` with live controls, so there are rows to click",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );
    // A row click that threw inside the bundle would leave the panes standing and
    // the page looking merely unresponsive; the page's own uncaught exceptions
    // are the only record (probe.mjs's header, Traps §3).
    j.countIs(live.pageErrors.length, 0, "no uncaught page errors while the session came up");

    // THE LIVE PATH RAN, AND THE EXPORT IS NOT ANSWERING FOR IT. See
    // `servedNavRows`. This is the assertion that would have failed for the
    // whole life of the two panes and did not exist to.
    const servedRows = await servedNavRows(page, site.origin + subject.debugPath);
    const hydratedRows = await page.evaluate(
      () => document.querySelectorAll(".ctrow,.evrow").length,
    );
    j.expect(
      hydratedRows > 0 && hydratedRows !== servedRows,
      "CONTROL: the navigation rows are the engine's, not the export's",
      `served ${servedRows} row(s), hydrated ${hydratedRows}`,
    );

    // ── the call trace ───────────────────────────────────────────────────
    const ct = await readRows(page, ".ctrow");
    j.atLeast(ct.shown, 1, "the call trace has rows on screen to click");
    // Counted, not existential (§4b): a region where one row of seven is
    // navigable is a broken region, and "at least one names a step" is exactly
    // the assertion that would call it healthy.
    j.countIs(
      ct.shownNamingAStep,
      ct.shown,
      "every call-trace row on screen names a step to jump to",
    );

    const ctTarget = await pickTarget(page, ".ctrow");
    j.expect(
      ctTarget !== null,
      "CONTROL: some call-trace row on screen names a step the session is not already on",
      ctTarget ? `row "${ctTarget.label}" names step ${ctTarget.step}` : "none found",
    );

    const ctBefore = live.facts;
    const ctAfter = ctTarget ? await jump(page, ctTarget.index, ".ctrow", ctBefore) : ctBefore;

    // CONTROL ON THE GESTURE. Not the verdict — the proof that the click reached
    // the engine, so that a red verdict below is a statement about the product
    // and not about a row this suite failed to press.
    j.expect(
      ctAfter.urlQuery !== ctBefore.urlQuery,
      "CONTROL: the call-trace click reached the engine (the time coordinate advanced)",
      `${ctBefore.urlQuery} -> ${ctAfter.urlQuery}`,
    );

    // THE VERDICT. Three readings of "the position moved there", each off the page.
    j.expect(
      ctTarget !== null && ctAfter.step === ctTarget.step,
      "the session's reported step is the step the call-trace row named",
      `data-step ${ctBefore.step} -> ${ctAfter.step}, the row named ${ctTarget?.step}`,
    );
    j.countIs(ctAfter.marked, 1, "after the jump, exactly one line carries the position mark");
    j.expect(
      ctAfter.markedShown,
      "the marked line is on screen, not merely in the DOM",
      `marked line ${ctAfter.markedNumber} in ${ctAfter.markedDoc}`,
    );
    j.expect(
      positionMoved(ctBefore, ctAfter),
      "the marked position moved to the row's step",
      `${positionOf(ctBefore)} -> ${positionOf(ctAfter)}`,
    );

    // ── the event log ────────────────────────────────────────────────────
    //
    // A SECOND REGION, AND IT IS NOT ON SCREEN UNTIL IT IS CHOSEN. The event log
    // shares a stacked column with the call trace, so its rows have zero size
    // until its tab is picked — which is why the first draft of this file scored
    // eight passes over a region no click had reached.
    //
    // The tab is found by PROPERTY, never by name: the pane that holds the event
    // rows, and the control whose fragment points at that pane. A renamed pane
    // moves this on its own; a selector spelling "eventlog" would not.
    const opened = await page.evaluate(() => {
      const pane = document.querySelector(".evrow")?.closest(".pane");
      if (!pane || !pane.id) return { ok: false, why: "the event rows are in no identified pane" };
      const tab = document.querySelector(`a[href="#${CSS.escape(pane.id)}"]`);
      if (!tab) return { ok: false, why: `no control targets #${pane.id}` };
      tab.click();
      return { ok: true, pane: pane.id };
    });
    await page.waitForTimeout(400);

    const ev = await readRows(page, ".evrow");
    j.atLeast(
      ev.shown,
      1,
      "choosing the Event Log puts its rows on screen",
      );
    j.countIs(
      ev.shownNamingAStep,
      ev.shown,
      "every event-log row on screen names a step to jump to",
    );

    const evTarget = await pickTarget(page, ".evrow");
    j.expect(
      evTarget !== null,
      "CONTROL: some event-log row on screen names a step the session is not already on",
      evTarget ? `row "${evTarget.label}" names step ${evTarget.step}` : `none found (${opened.why ?? opened.pane})`,
    );

    const evBefore = await readFacts(page);
    const evAfter = evTarget ? await jump(page, evTarget.index, ".evrow", evBefore) : evBefore;

    j.expect(
      evAfter.urlQuery !== evBefore.urlQuery,
      "CONTROL: the event-log click reached the engine (the time coordinate advanced)",
      `${evBefore.urlQuery} -> ${evAfter.urlQuery}`,
    );
    j.expect(
      evTarget !== null && evAfter.step === evTarget.step,
      "the session's reported step is the step the event-log row named",
      `data-step ${evBefore.step} -> ${evAfter.step}, the row named ${evTarget?.step}`,
    );
    j.countIs(
      evAfter.marked,
      1,
      "after the event-log jump, exactly one line carries the position mark",
    );
    j.expect(
      evAfter.markedShown && positionMoved(evBefore, evAfter),
      "the event-log jump moved the mark, and it is on screen",
      `${positionOf(evBefore)} -> ${positionOf(evAfter)}, on screen=${evAfter.markedShown}`,
    );
  } finally {
    await page.close();
  }

  // ── THE REAL CAPTURE ──────────────────────────────────────────────────
  //
  // The surface the visitor's report came from, and the one no assertion in
  // this suite had ever driven. It is a SEPARATE subject and a separate page,
  // so a real-capture regression reddens on its own rather than being masked
  // by a demo session that still works.
  await realArm(browser, site, j, realCaptures[0]);
}

/**
 * What a REAL capture must honour, whether or not it has rows to jump from.
 *
 * The jump gesture is not assertable in the same shape here, and pretending
 * otherwise would be the trap this file already fell into once. On every real
 * capture in the corpus the navigation regions render no rows — the recordings
 * resolve no source positions — so "every row jumps correctly" is a claim about
 * an empty set, which passes and means nothing.
 *
 * What IS assertable, and is what the visitor actually reported, is three
 * things: the mark exists, the mark FOLLOWS the session when it moves, and a
 * region with nothing to show says why instead of rendering an empty box. The
 * jump itself is asserted CONDITIONALLY and the branch taken is printed, so the
 * day a real capture gains navigable rows this arm judges them instead of
 * silently continuing to judge their absence.
 */
async function realArm(browser, site, j, subject) {
  j.note(`driving REAL capture ${subject.debugPath}`);
  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "REAL: the session reached `ready` with live controls",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );
    j.countIs(live.pageErrors.length, 0, "REAL: no uncaught page errors while the session came up");

    const before = await readFacts(page);
    j.countIs(before.marked, 1, "REAL: exactly one line carries the position mark");
    j.expect(
      before.markedShown,
      "REAL: the marked line is on screen, not merely in the DOM",
      `marked ${positionOf(before)}`,
    );

    // THE CONTROL, AND ON THIS ARM IT IS THE STRONGEST FORM OF IT. A rung-3
    // export ships NO navigation rows at all — the SSR constructor has no
    // instruction-level arm for these two panes — so every row on screen here
    // came from the engine and nothing else could have put it there.
    const servedRows = await servedNavRows(page, site.origin + subject.debugPath);
    const hydratedRows = await page.evaluate(
      () => document.querySelectorAll(".ctrow,.evrow").length,
    );
    j.expect(
      hydratedRows > 0 && hydratedRows !== servedRows,
      "REAL: CONTROL — the navigation rows are the engine's, not the export's",
      `served ${servedRows} row(s), hydrated ${hydratedRows}`,
    );

    // ROWS ARE REQUIRED, NOT EXCUSED. This assertion was written the day
    // before as "either jump where the row says, or state why there are no
    // rows", which was honest while the belief was that a rung-3 recording
    // carries no frames. It does carry them — the engine answers with
    // `<toplevel>` and `enqueued-call-0`, both named, both tick-bearing — so
    // the excusing arm was excusing a defect, and it is gone.
    const nav = await readRows(page, ".ctrow,.evrow");
    j.atLeast(nav.shown, 1, "REAL: the navigation regions have rows on screen to click");
    j.countIs(
      nav.shownNamingAStep,
      nav.shown,
      "REAL: every navigation row on screen names a step to jump to",
    );

    const target = await pickTarget(page, ".ctrow,.evrow");
    j.expect(
      target !== null,
      "REAL: CONTROL — some row on screen names a step the session is not already on",
      target ? `row "${target.label}" names step ${target.step}` : "none found",
    );

    const after = target ? await jump(page, target.index, ".ctrow,.evrow", before) : before;
    j.expect(
      after.urlQuery !== before.urlQuery,
      "REAL: CONTROL — the click reached the engine (the time coordinate advanced)",
      `${before.urlQuery} -> ${after.urlQuery}`,
    );

    // THE VERDICT, and it is the visitor's own sentence: the mark follows the
    // jump they performed.
    j.expect(
      target !== null && after.step === target.step,
      "REAL: the session's reported step is the step the row named",
      `data-step ${before.step} -> ${after.step}, the row named ${target?.step}`,
    );
    j.countIs(after.marked, 1, "REAL: after the jump, exactly one line carries the mark");
    j.expect(
      after.markedShown,
      "REAL: the marked line is on screen after the jump",
      `marked ${positionOf(after)}`,
    );
    j.expect(
      positionMoved(before, after),
      "REAL: the mark moved to where the row pointed",
      `${positionOf(before)} -> ${positionOf(after)}`,
    );
  } finally {
    await page.close();
  }
}
