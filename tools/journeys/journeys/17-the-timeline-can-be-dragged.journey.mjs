// "A visitor who drags the timeline at the top of a session moves the session
//  to where they dropped it."
//
// Debugger-Integration.md §3 (the `ct/goto-ticks` item) and §4.2. The claim is
// the one a visitor made in a bug report — "the slider in the very top can be
// slidable" — and the control they meant is `.dctl`, the trace scrubber in the
// identity bar.
//
// WHY THIS IS NOT A CASE IN JOURNEY 09
// ------------------------------------
// 09 drives ROW CLICKS. A row carries `data-step` and the handler reads it; the
// gesture is a click on an element that already names its own target. A drag
// names nothing: the target is computed from a pointer coordinate against a
// laid-out box, on an element that `setControls` REPLACES on every stop, with a
// pointer capture that has to survive that replacement. None of that machinery
// is exercised by a row click, and all of it can fail on its own.
//
// THE TRAP THIS FILE IS WRITTEN AGAINST
// -------------------------------------
// ASSERTING THAT THE HANDLE MOVED PROVES ONLY THAT THE HANDLE MOVED. A
// decoration that followed the mouse would satisfy it completely — and that is
// not a hypothetical failure mode, it is the CHEAPEST way to implement this
// control wrongly, because painting a handle needs no engine, no round trip and
// no error path. It would look perfect and do nothing.
//
// So every drag is judged TWICE and the two are different claims:
//
//   * THE HANDLE TRACKS THE DRAG — read while the button is still down, which
//     is the only moment at which "follows the pointer" is a statement about
//     anything. After release a handle and a session that both ended up in the
//     right place are indistinguishable from a handle that was dragged and a
//     session that was seeked independently.
//
//   * THE SESSION IS WHERE IT WAS DROPPED — read from `data-step`, which is the
//     SESSION'S OWN account of its position, the same field journey 03's
//     stepping gate and journey 09's jump gate take their verdicts from. It is
//     NEVER read from the handle's coordinates: a handle asked where it is will
//     always say it is where it is, and that is the tautology this journey
//     exists to avoid.
//
// The second is what makes this a scrubber rather than an animation.
//
// AND THE POSITION IS ALSO CHECKED WHEN NOBODY IS DRAGGING
// --------------------------------------------------------
// A handle that does not follow the session while the session moves by other
// means is the same defect in a quieter form — the control lying about where
// you are rather than refusing to take you somewhere. It was TRUE of this
// control before the drag existed (measured: step 671 of 1315 drew tick 24 of
// 48, step 674 drew tick 25) and this file is what keeps it true, because the
// drag introduced a second writer of the handle and a second writer is how a
// readout starts to disagree with its subject.
//
// THE AFFORDANCE IS CHECKED AGAINST THE OTHER BUILD TOO
// -----------------------------------------------------
// This route ships twice (AGENTS.md, "The artefact you photograph is not the
// artefact the visitor loads"), and the crawled build has no script. A
// `role="slider"` on THAT artefact would be this repository's own recurring
// defect — an affordance promising an interaction it does not deliver, after
// the plus-cursor on unclickable rows and the `cursor: pointer` that outlived
// its click handler. So the export is fetched and asserted to carry the track
// and NOT the control.
//
// EMPTY SETS. Every count below is `countIs` against a set whose own size is
// asserted first. "Every drag landed correctly" is vacuously true of a run that
// performed no drags, and a `for` loop that threw on its first iteration is
// exactly how a suite comes to perform none.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "the-timeline-can-be-dragged";
export const claim =
  "A visitor who drags the timeline at the top of a session moves the session to where they dropped it.";
export const spec = "Debugger-Integration.md §3, §4.2 — BlockTracer";
export const assertions = 30;
export const needsEngine = true;

/** The three fractions every arm drags to. Named once so both arms drag the same. */
const DROPS = [0.75, 0.3, 0.55];

/**
 * The tick a step of a trace SHOULD land on, restated here from the control's
 * own description rather than imported from it.
 *
 * A test that computed this by calling the shipping `markedTick` would agree
 * with the renderer by construction and could not notice the two disagreeing —
 * which is the whole quantity in question. The tolerance below is one tick, and
 * it is there for float rounding at a boundary and NOT to be generous: a handle
 * that ignores the session entirely is off by tens of ticks, and a handle one
 * tick out is a rounding argument, not a defect.
 */
const TICKS = 48;
const tickFor = (step, total) => {
  if (!(total > 0) || step <= 0) return 0;
  if (step >= total) return TICKS;
  return Math.min(TICKS - 1, Math.max(1, Math.round((step / total) * TICKS)));
};

/** The step a pointer `f` of the way along the track is asking for. */
const stepFor = (f, total) =>
  Math.min(total, Math.max(1, Math.floor(Math.min(1, Math.max(0, f)) * total + 0.5)));

/**
 * The control, as the page presents it — geometry, affordance and handle.
 *
 * `hitAtCentre` is asked of `document.elementFromPoint` at the track's own
 * centre, and it is not a formality. A drag driven at coordinates that some
 * other element occupies would be a drag this suite performed on the wrong
 * thing, and every assertion after it would be a statement about that thing.
 */
const readTrack = (page) =>
  page.evaluate(() => {
    const track = document.querySelector(".dctl");
    if (!track) return { present: false };
    const ticks = [...track.querySelectorAll(".tick")];
    const r = track.getBoundingClientRect();
    const cx = r.left + r.width / 2;
    const cy = r.top + r.height / 2;
    const hit = document.elementFromPoint(cx, cy);
    return {
      present: true,
      rect: { x: r.left, y: r.top, w: r.width, h: r.height },
      ticks: ticks.length,
      // 1-based, matching the control's own numbering; 0 = no handle drawn.
      handleTick: ticks.findIndex((t) => t.classList.contains("at")) + 1,
      elapsed: ticks.filter((t) => t.classList.contains("on")).length,
      seekable: track.classList.contains("seekable"),
      role: track.getAttribute("role"),
      tabindex: track.getAttribute("tabindex"),
      valueMax: track.getAttribute("aria-valuemax"),
      valueNow: track.getAttribute("aria-valuenow"),
      hitAtCentre: !!hit && (hit === track || track.contains(hit)),
    };
  });

/**
 * What the EXPORT ships for this page, parsed the same way the live side is
 * read — journey 09's `servedNavRows` rule, for the same reason. `DOMParser`
 * runs no scripts, so this is the artefact a crawler gets.
 */
const servedControl = (page, url) =>
  page.evaluate(async (u) => {
    const doc = new DOMParser().parseFromString(
      await (await fetch(u, { cache: "no-store" })).text(),
      "text/html",
    );
    return {
      tracks: doc.querySelectorAll(".dctl").length,
      announced: doc.querySelectorAll(
        '.dctl[role], .dctl[tabindex], .dctl[aria-valuemax], .dctl.seekable',
      ).length,
    };
  }, url);

/**
 * Poll until the session's own step stops changing, or give up and SAY so.
 *
 * QUIESCENCE, NEVER "until it says what I want". Waiting for the expected value
 * would make the assertion after it unfalsifiable — it would pass whenever it
 * could pass and time out otherwise, which is a slower way of asserting
 * nothing. So this waits for the session to stop moving and the caller then
 * compares wherever it stopped against wherever the pointer was released.
 *
 * THE QUIET WINDOW IS SIX SECONDS AND THAT NUMBER IS MEASURED. A real chain
 * capture answers a seek in about 2.1 s and was observed taking 3.0; the first
 * draft of this helper accepted 750 ms of stillness and therefore declared the
 * session settled while a seek was still in flight, reporting three chain drags
 * as landing on step 7, 32 and 32 when the drop points were 259, 104 and 190.
 * It was the harness that was wrong, and it was wrong in the expensive
 * direction — a gate that cries wolf gets switched off, and then it is not
 * there for the real one. The window has to clear the SLOWEST seek, not the
 * typical one.
 */
async function settlePosition(page, quietMs = 6000, capMs = 90000) {
  const deadline = Date.now() + capMs;
  const period = 500;
  const need = Math.ceil(quietMs / period);
  let last = null;
  let stable = 0;
  while (Date.now() < deadline) {
    const f = await readFacts(page);
    if (f.step === last) {
      if (++stable >= need) return { facts: f, settled: true };
    } else {
      stable = 0;
      last = f.step;
    }
    await page.waitForTimeout(period);
  }
  return { facts: await readFacts(page), settled: false };
}

/**
 * ONE REAL DRAG: press, move, release — and a reading taken WHILE THE BUTTON IS
 * STILL DOWN.
 *
 * The mid-drag reading is the entire reason this is a drag and not two clicks.
 * It is taken at the last move, before `mouse.up`, so what it measures is the
 * handle under a pointer the visitor has not yet let go of.
 */
async function drag(page, fraction, total) {
  const t0 = await readTrack(page);
  const r = t0.rect;
  const y = r.y + r.h / 2;
  // Start near the left edge and drag to `fraction`, so the gesture always
  // crosses most of the track and the release point is never the press point.
  const startX = r.x + r.w * 0.02;
  const endX = r.x + Math.min(r.w - 1, r.w * fraction);
  const before = await readFacts(page);

  await page.mouse.move(startX, y);
  await page.mouse.down();
  let mid = null;
  const MOVES = 10;
  for (let i = 1; i <= MOVES; i++) {
    await page.mouse.move(startX + ((endX - startX) * i) / MOVES, y);
    if (i === MOVES) mid = await readTrack(page);
  }
  await page.mouse.up();

  const dropFraction = (endX - r.x) / r.w;
  const wanted = stepFor(dropFraction, total);
  const after = await settlePosition(page);
  return {
    fraction,
    wanted,
    before,
    mid,
    after: after.facts,
    settled: after.settled,
    landed: Number(after.facts.step),
    // Did the handle follow the pointer while it was down? Compared against the
    // step the RELEASE POINT names, because the last move is at that point.
    handleFollowed:
      mid.handleTick > 0 && Math.abs(mid.handleTick - tickFor(wanted, total)) <= 1,
    // Did the session end up there? Read from the session, never from the handle.
    landedAtDrop: Math.abs(Number(after.facts.step) - wanted) <= Math.ceil(total / (TICKS * 2)),
    exact: Number(after.facts.step) === wanted,
    markMoved:
      after.facts.markedNumber !== null &&
      (after.facts.markedNumber !== before.markedNumber ||
        after.facts.markedDoc !== before.markedDoc),
  };
}

/**
 * Does the handle follow the session when something ELSE moves it?
 *
 * Driven through the toolbar, which is a different sender entirely
 * (`invokeToolbarStep`, not `ct/goto-ticks`), so a handle wired only to its own
 * drag scores nothing here.
 */
async function steppingReadings(page, total, times = 4) {
  const out = [];
  for (let i = 0; i < times; i++) {
    const before = await readFacts(page);
    await page.click('.dcbtn[data-action="step-forward"]').catch(() => {});
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      const f = await readFacts(page);
      if (f.step !== before.step) break;
      await page.waitForTimeout(100);
    }
    const f = await readFacts(page);
    const t = await readTrack(page);
    out.push({
      step: Number(f.step),
      handleTick: t.handleTick,
      want: tickFor(Number(f.step), total),
      agrees: Math.abs(t.handleTick - tickFor(Number(f.step), total)) <= 1,
    });
  }
  return out;
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);

  // TWO SUBJECT LISTS, EACH ASSERTED NON-EMPTY, AND NO FALLBACK BETWEEN THEM —
  // journey 09's rule, and it earned its place on THIS control too. The two
  // engines behave completely differently under a scrub: the demo answers a
  // seek in a median of 46 ms and a chain capture takes about 2.1 s, so the
  // coalescing that keeps a drag honest is exercised in one shape by the first
  // and in a quite different one by the second. A synthetic-only run would have
  // judged the easy half.
  const synthetic = withSession.filter((t) => !t.real);
  const realCaptures = withSession.filter((t) => t.real);
  j.atLeast(synthetic.length, 1, "SUBJECTS: synthetic sessions, so the demo arm has a subject");
  j.atLeast(
    realCaptures.length,
    1,
    "SUBJECTS: REAL-capture sessions, so the slow-engine arm has a subject",
  );

  await demoArm(browser, site, j, synthetic[0]);
  await chainArm(browser, site, j, realCaptures[0]);
}

async function demoArm(browser, site, j, subject) {
  j.note(`dragging ${subject.debugPath}`);
  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session reached `ready` with live controls, so there is something to scrub",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );
    j.countIs(live.pageErrors.length, 0, "no uncaught page errors while the session came up");

    const total = Number(live.facts.totalSteps);
    const t = await readTrack(page);

    j.expect(
      t.present && t.hitAtCentre,
      "CONTROL: the pointer at the track's own centre lands on the track",
      `hit=${t.hitAtCentre} rect=${JSON.stringify(t.rect)}`,
    );
    j.countIs(t.ticks, TICKS, "the track is drawn as the 48 ticks the control is specified as");
    j.expect(
      t.seekable && t.role === "slider" && t.tabindex === "0" && t.valueMax === String(total),
      "the track is offered as a slider over the whole trace",
      `seekable=${t.seekable} role=${t.role} tabindex=${t.tabindex} max=${t.valueMax} of ${total}`,
    );

    // THE DEFECT-FAMILY GUARD. The crawled build must carry the timeline and
    // NOT the promise — the affordance arrives with the bundle that honours it,
    // or this control joins the plus-cursor and the orphaned `cursor: pointer`.
    const served = await servedControl(page, site.origin + subject.debugPath);
    j.countIs(
      served.tracks,
      1,
      "CONTROL: the export ships the timeline itself, so the check below is about a control that exists",
    );
    j.countIs(
      served.announced,
      0,
      "the scriptless build promises no gesture: no role, no tab stop, no range, no cursor class",
    );

    // ── the handle's truthfulness, with nobody dragging ────────────────────
    // THE CONTROL BELOW USED TO CONTAIN ITS OWN ESCAPE HATCH, and it is the
    // vacuity family in its purest form. It read
    //
    //     new Set(readings.map(r => r.handleTick)).size > 1 ||
    //       new Set(readings.map(r => r.step)).size === 1
    //
    // — "a frozen handle is fine if the session never moved". But a session that
    // never moves is precisely the state in which "the handle sits on the tick
    // the session's step names" is untestable: `tickFor` is a pure function of
    // the step, so four readings of one step agree four times for free. The
    // escape disjunct WAS the failure mode.
    //
    // And it was reachable, not theoretical. `steppingReadings` clicks with
    // `.catch(() => {})` and nothing asserted that any click landed, so a dead
    // toolbar produced four identical readings, four free agreements, and a
    // CONTROL that passed by its second disjunct — the whole block green over a
    // session that did not move.
    //
    // So the movement is asserted first, as its own record, read from
    // `data-step` — the session's own account, the field journeys 03 and 09 take
    // their verdicts from, and a fact about the engine rather than about the
    // control being judged. With it in place the agreement below has a subject
    // that is guaranteed to vary, and the disjunct is gone.
    const readings = await steppingReadings(page, total);
    j.countIs(readings.length, 4, "four toolbar steps were taken to read the handle against");
    j.atLeast(
      new Set(readings.map((r) => r.step)).size,
      2,
      "CONTROL: those toolbar steps actually moved the session, so the agreement below is not free",
    );
    j.countIs(
      readings.filter((r) => r.agrees).length,
      readings.length,
      "after every toolbar step the handle sits on the tick the session's own step names",
      );
    j.expect(
      new Set(readings.map((r) => r.handleTick)).size > 1,
      "CONTROL: the readings above are not all one frozen value",
      `steps ${readings.map((r) => r.step).join(",")} ticks ${readings.map((r) => r.handleTick).join(",")}`,
    );

    // ── the drags ──────────────────────────────────────────────────────────
    const drags = [];
    for (const f of DROPS) drags.push(await drag(page, f, total));
    j.countIs(drags.length, DROPS.length, "three drags were performed, each across most of the track");
    j.countIs(
      drags.filter((d) => d.settled).length,
      drags.length,
      "every drag left the session at a position that stopped changing",
    );
    j.countIs(
      drags.filter((d) => d.handleFollowed).length,
      drags.length,
      "while the button was still down the handle sat under the pointer",
      );
    j.countIs(
      drags.filter((d) => d.landedAtDrop).length,
      drags.length,
      "the step the session reports is the step the release point names",
    );
    j.countIs(
      drags.filter((d) => d.markMoved).length,
      drags.length,
      "every drop moved the marked source position, not only the readout",
    );
    j.note(
      "drops " +
        drags.map((d) => `f=${d.fraction} want ${d.wanted} got ${d.landed}`).join("; "),
    );

    // ── a click, and a key ─────────────────────────────────────────────────
    const r = (await readTrack(page)).rect;
    const beforeClick = await readFacts(page);
    await page.mouse.click(r.x + r.w * 0.9, r.y + r.h / 2);
    const clicked = await settlePosition(page);
    const clickWant = stepFor(0.9, total);
    j.expect(
      Math.abs(Number(clicked.facts.step) - clickWant) <= Math.ceil(total / (TICKS * 2)),
      "a click on the track, with no drag at all, takes the session to that point",
      `${beforeClick.step} -> ${clicked.facts.step}, the point names ${clickWant}`,
    );

    const beforeKey = await readFacts(page);
    await page.focus(".dctl");
    await page.keyboard.press("Home");
    const keyed = await settlePosition(page);
    j.expect(
      Number(keyed.facts.step) < Number(beforeKey.step) && Number(keyed.facts.step) >= 1,
      "the slider answers the keyboard it puts itself in the tab order for",
      `Home: ${beforeKey.step} -> ${keyed.facts.step}`,
    );

    j.countIs(
      live.pageErrors.length,
      0,
      "the whole set of gestures raised no uncaught page error",
    );
  } finally {
    await page.close();
  }
}

/**
 * The same claim against a REAL chain capture, whose engine is roughly 45x
 * slower per seek.
 *
 * THIS ARM IS WHERE THE COALESCING IS ACTUALLY JUDGED. Against the demo engine
 * a drag drains as fast as it is made and every pointer position reaches the
 * wire; against this one only the first target and the drop point do, and the
 * gesture is correct precisely BECAUSE the intermediate ones were superseded
 * rather than queued. A suite that ran only on the demo chain would call a
 * scrubber that replays the whole drag at 2 s a frame — arriving at the drop
 * point half a minute late — perfectly healthy.
 *
 * Its assertion texts are reworded rather than prefixed. See `nameCollisions`:
 * a text that CONTAINS a sibling's disarms every mutation arm aimed at the
 * shorter one.
 */
async function chainArm(browser, site, j, subject) {
  j.note(`dragging REAL capture ${subject.debugPath}`);
  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "REAL: the chain session reached `ready` with live controls",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );
    j.countIs(live.pageErrors.length, 0, "REAL: the chain session came up with no page errors");

    const total = Number(live.facts.totalSteps);
    const t = await readTrack(page);
    j.expect(
      t.present && t.hitAtCentre && t.seekable && t.role === "slider" && t.tabindex === "0",
      "REAL: the chain capture's timeline is a focusable slider under the pointer",
      `hit=${t.hitAtCentre} seekable=${t.seekable} role=${t.role} tabindex=${t.tabindex}`,
    );

    const drags = [];
    for (const f of DROPS) drags.push(await drag(page, f, total));
    j.countIs(drags.length, DROPS.length, "REAL: three drags were performed on the chain capture");
    j.countIs(
      drags.filter((d) => d.handleFollowed).length,
      drags.length,
      "REAL: the handle stayed under the pointer even while the engine lagged behind it",
    );
    j.countIs(
      drags.filter((d) => d.landedAtDrop).length,
      drags.length,
      "REAL: the slow engine still finished each drag at the released point",
    );
    j.countIs(
      drags.filter((d) => d.markMoved).length,
      drags.length,
      "REAL: each drop moved the chain session's marked position",
    );
    j.note(
      "REAL drops " +
        drags.map((d) => `f=${d.fraction} want ${d.wanted} got ${d.landed}`).join("; "),
    );

    // THIS ARM HAD NO DISCRIMINATION CONTROL AT ALL — not even the broken one
    // the demo arm carried. Three swallowed clicks give three identical
    // readings, and `agrees` is a pure function of the step, so three identical
    // readings agree three times and the assertion below passes over a session
    // that never moved. The same guard, on the arm the header calls the
    // interesting one.
    const readings = await steppingReadings(page, total, 3);
    j.atLeast(
      new Set(readings.map((r) => r.step)).size,
      2,
      "REAL: CONTROL — the chain session's toolbar steps reached more than one position",
    );
    j.countIs(
      readings.filter((r) => r.agrees).length,
      readings.length,
      "REAL: the chain capture's handle tracks its session across three toolbar steps",
    );
    j.note(
      `REAL stepping: steps ${readings.map((r) => r.step).join(",")} ` +
        `ticks ${readings.map((r) => r.handleTick).join(",")}`,
    );
  } finally {
    await page.close();
  }
}
