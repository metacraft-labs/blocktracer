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

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-jump-moves-the-position";
export const claim =
  "A visitor who clicks a row in the navigation regions sees the position move there.";
export const spec = "Debugger-Integration.md §3, §4.2 — BlockTracer";
export const assertions = 18;
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

  const subject = withSession.find((t) => !t.real) ?? withSession[0];
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
      ctAfter.markedNumber !== null && ctAfter.markedNumber !== ctBefore.markedNumber,
      "the marked line moved",
      `marked line ${ctBefore.markedNumber} -> ${ctAfter.markedNumber}`,
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
      evAfter.markedShown && evAfter.markedNumber !== evBefore.markedNumber,
      "the marked line moved, and is on screen",
      `marked line ${evBefore.markedNumber} -> ${evAfter.markedNumber}, on screen=${evAfter.markedShown}`,
    );
  } finally {
    await page.close();
  }
}
