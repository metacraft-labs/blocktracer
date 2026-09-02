// "A visitor who marks lines can continue to them, forwards and backwards."
//
// Debugger-Integration.md §10.8 ("Breakpoints, and continuing in both
// directions"), over the indicator and states specified in
// GUI/Debugging-Features/Breakpoints-And-Tracepoints.md.
//
// THE FALSE PASS THIS JOURNEY IS WRITTEN AGAINST
// ----------------------------------------------
// **Asserting that a marker appears in the gutter proves only that a marker
// appears.** The gutter is rendered by this repository from a set this
// repository owns, so a build in which `setBreakpoints` was never sent — which
// is exactly the state `dev` was in when this was written, measured at zero
// sends by the whole product — paints all three marks correctly and continues
// straight past them to the end of the recording.
//
// So no verdict here is read from a mark. Every one is read from the position
// the SESSION reports, the way journeys 03 and 09 read theirs. The marks are
// asserted too, but as a CONTROL: proof that the gesture landed, so that a red
// verdict below is a statement about the product and not about a click this
// suite failed to make.
//
// AND THE ERROR A SINGLE BREAKPOINT CANNOT CATCH
// ----------------------------------------------
// Reverse continue must land on the breakpoint NEAREST BEFORE the position —
// not on the first one in the file. Those two are the same answer whenever
// there is one breakpoint, and they are the same answer whenever the session is
// standing just after the first. A test built on either would pass over an
// implementation that always rewinds to the top.
//
// This journey therefore sets THREE, walks the whole forward sequence of stops,
// and then walks it back — asserting the reverse walk is the forward walk
// reversed, element by element. `guardsDiscrimination` below asserts that the
// nearest-preceding stop and the first stop are DIFFERENT before that
// comparison is trusted, so the discrimination cannot be vacuous.
//
// WHAT IT DOES NOT CLAIM
// ----------------------
// §10.8: "**Not checkable from the position alone, and stated as such:**
// whether reverse continue is a seek or a re-execution." The two land on the
// same line and only latency separates them; this suite measures no timings and
// asserts nothing about it.
//
// PROVING THE INSTRUMENT BEFORE JUDGING THE SUBJECT
// -------------------------------------------------
// §10's caveat: a gesture that never fires produces a clean, confident green.
// The gutter click is a gesture no journey here had performed. It is proved in
// two ways that a no-op click could not satisfy: the marks appear (a DOM change
// only a real click produces) AND the number of `setBreakpoints` frames on the
// worker's wire equals the number of clicks. The second is why this file wraps
// `Worker.postMessage` at all — the DOM alone cannot distinguish "the click ran
// the handler" from "the click ran the handler and reached the engine", and it
// is the second that every verdict below depends on.
//
// The click is also aimed only at a VISIBLE row. The source pane holds every
// document at once and hides all but one, so an unfiltered selector finds a
// hidden line first; that mistake was made writing this file and surfaced as a
// 30-second click timeout rather than as a silent pass, which is the direction
// it should fail in and the reason the filter is explicit here.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "continuing-stops-at-a-breakpoint";
export const claim =
  "A visitor who marks lines can continue to them, forwards and backwards.";
export const spec = "Debugger-Integration.md §10.8 — BlockTracer";
export const assertions = 29;
export const needsEngine = true;

/** Wrap the worker before any page script runs, and count DAP frames by name. */
const WIRE = () => {
  window.__sentCommands = [];
  const OrigWorker = window.Worker;
  window.Worker = function (url, opts) {
    const w = new OrigWorker(url, opts);
    const origPost = w.postMessage.bind(w);
    w.postMessage = (m, ...rest) => {
      if (m && m.command) window.__sentCommands.push(m.command);
      return origPost(m, ...rest);
    };
    return w;
  };
  window.Worker.prototype = OrigWorker.prototype;
};

const sent = (page, command) =>
  page.evaluate((c) => window.__sentCommands.filter((x) => x === c).length, command);

/**
 * The breakpoint-specific readings, beside the ones `readFacts` already takes.
 *
 * Scoped to the VISIBLE document throughout — see the header. `bpLines` and
 * `pressed` are read separately and asserted against each other, because the
 * painted class and the announced state are two different channels and a
 * renderer that stopped emitting one is exactly what `aria-pressed` is valued
 * on every row to make countable.
 */
const readGutter = (page) =>
  page.evaluate(() => {
    const shown = (e) =>
      !!e && typeof e.checkVisibility === "function"
        ? e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
        : false;
    const doc = [...document.querySelectorAll(".srcdoc")].filter(shown)[0] ?? null;
    const rows = doc ? [...doc.querySelectorAll(".srcline")].filter(shown) : [];
    const num = (r) => Number(r.getAttribute("data-line"));
    return {
      docPath: doc?.getAttribute("data-path") ?? null,
      rows: rows.length,
      gutterButtons: rows.filter((r) => r.querySelector(".n[role='button']")).length,
      // The lines the RECORDING visited. A breakpoint can only be hit on one of
      // these, so the subject lines are chosen from them — a property read off
      // the page, never a line number written in this file (rule 4).
      executed: rows.filter((r) => r.classList.contains("hit")).map(num),
      marked: rows.filter((r) => r.classList.contains("bp")).map(num),
      pressed: rows.filter((r) => r.querySelector(".n[aria-pressed='true']")).length,
    };
  });

const readOutcome = (page) =>
  page.evaluate(
    () => document.querySelector(".dcoutcome")?.getAttribute("data-outcome") ?? "",
  );

/** Click the gutter of one line, in the visible document only. */
async function clickGutter(page, line) {
  const candidates = await page.$$(`.srcline[data-line="${line}"] .n[role="button"]`);
  for (const c of candidates) {
    if (await c.isVisible()) {
      await c.click();
      return true;
    }
  }
  return false;
}

/** The session's own account of where it is, as a comparable pair. */
async function position(page) {
  const f = await readFacts(page);
  return { step: Number(f.step), line: f.markedNumber };
}

/**
 * Press a continue control and wait for the session to answer.
 *
 * A predicate over two possible answers, never a sleep: a continue either MOVES
 * or REPORTS that it had nowhere to go, and both are outcomes this journey
 * asserts on. Waiting only for movement would turn the second into a timeout.
 */
async function continueOnce(page, action) {
  const before = await position(page);
  await page.click(`[data-action="${action}"]`);
  const deadline = Date.now() + 20000;
  for (;;) {
    const after = await position(page);
    const outcome = await readOutcome(page);
    // THE TERMINAL CONDITION IS A NON-EMPTY OUTCOME, never a CHANGED one.
    //
    // Pressing a continue control clears the previous gesture's outcome as its
    // first act, so "the outcome differs from before the click" is satisfied
    // the instant the click is handled — before the engine has answered. This
    // loop was written that way and it made the first call of every walk return
    // immediately, recording the position the session had NOT yet left as a
    // stop, and swallowing the real stop that followed. It read as a product
    // defect (a reverse continue landing on the wrong step) and was an
    // instrument defect.
    if (outcome !== "") {
      // THE OUTCOME ARRIVES BEFORE THE POSITION SETTLES, so the position is
      // read after it has stopped changing rather than at the instant the
      // sentence appears.
      //
      // A continue that reaches no breakpoint is not one engine operation but
      // three: the engine runs to the end of the recording, THEN reports that
      // it hit nothing, and only then is it seeked back to where it started.
      // Reading at the sentence therefore catches the session at the end of
      // the trace — measured at step 1314 of 1315 on the demo capture, on a
      // session that settles at 670. That is a real (and brief) excursion the
      // visitor can see, and it is recorded in the report as such; it is not
      // what this journey is asserting, which is where the session ENDS UP.
      return { ...(await settle(page)), outcome, moved: true };
    }
    if (after.step !== before.step) return { ...after, outcome, moved: true };
    if (Date.now() > deadline)
      return { ...after, outcome, moved: false, timedOut: true };
    await page.waitForTimeout(120);
  }
}

/** Read the position once it has stopped changing. */
async function settle(page, quietMs = 700, limitMs = 10000) {
  const deadline = Date.now() + limitMs;
  let last = await position(page);
  for (;;) {
    await page.waitForTimeout(quietMs);
    const now = await position(page);
    if (now.step === last.step) return now;
    last = now;
    if (Date.now() > deadline) return now;
  }
}

/**
 * Walk one direction until the control says there is nothing further.
 *
 * Returns the stops AND the reading that ended the walk, because the ending is
 * itself a claim: §10.8 requires that the continue which found nothing leaves
 * the session where it was, and that is a fact about `final`, not about the
 * stops before it.
 */
async function walk(page, action, limit = 24) {
  const stops = [];
  let final = null;
  for (let i = 0; i < limit; i++) {
    const r = await continueOnce(page, action);
    final = r;
    if (r.outcome || r.timedOut) break;
    stops.push({ step: r.step, line: Number(r.line) });
  }
  return { stops, final };
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  const withSession = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  j.subjects(withSession, 3, "transactions whose landing is a session with rows in its Code pane");

  // A breakpoint addresses a line of SOURCE. The chain captures in this corpus
  // resolve no source positions and render an instruction listing instead
  // (§5), where the "line" is a program counter — a different claim needing a
  // different journey. The subject is therefore selected by what the page
  // renders, and the list is asserted non-empty rather than fallen back from.
  const sourceLevel = withSession.filter((t) => !t.real);
  j.atLeast(
    sourceLevel.length,
    1,
    "SUBJECTS: source-level sessions, whose Code pane has lines a breakpoint can name",
  );

  const subject = sourceLevel[0];
  j.note(`driving ${subject.debugPath}`);

  const live = await visit(browser, site.origin, subject.debugPath, {
    settle: (f) => f.phase === "ready" && f.controlsLive > 0,
    initScript: WIRE,
  });
  const page = live.page;
  try {
    j.expect(
      live.settled && !live.timedOut,
      "the session reached `ready` with live controls, so there is something to continue",
      `phase=${live.facts.phase} live=${live.facts.controlsLive}`,
    );

    // ── THE CONTROL IS OFFERED WHERE IT CAN BE HONOURED ───────────────────
    const gutter0 = await readGutter(page);
    // THE SUBJECT COUNT COMES FIRST, AND IT USED NOT TO EXIST HERE.
    //
    // `readGutter` returns `rows: []` when no `.srcdoc` is on screen, so the
    // assertion below was `countIs(0, 0)` — a pass — over a source pane that had
    // rendered nothing at all. The condition WAS caught, thirty-five lines
    // further down by `atLeast(executed.length, 3)`, so the journey went red;
    // but this record went GREEN in the same run, and a `selftest.mjs` arm aimed
    // at its text over a defect that empties the pane would have scored
    // SURVIVED. An assertion's own guard has to sit above it, not somewhere in
    // the same file.
    j.atLeast(gutter0.rows, 1, "SUBJECTS: rendered lines in the document the session opened");
    j.countIs(
      gutter0.gutterButtons,
      gutter0.rows,
      "every rendered line of the open document offers the breakpoint gesture",
    );
    j.countIs(gutter0.marked.length, 0, "a session opens with no breakpoints marked");

    // ── CONTINUING WITH NONE SET SAYS SO, AND DOES NOT MOVE ───────────────
    //
    // §10.8: "Where there is no breakpoint to reach in a direction, the control
    // says so — rather than running to the end of the recording and stopping
    // there." Asserted FIRST, on a session that has never had a breakpoint, so
    // it cannot be satisfied by leftover state from the arms below.
    const beforeEmpty = await position(page);
    const empty = await continueOnce(page, "continue");
    j.expect(
      empty.outcome === "no-breakpoint",
      "continuing with nothing set reports that there was nothing to reach",
      `data-outcome=${JSON.stringify(empty.outcome)}`,
    );
    j.countIs(
      empty.step,
      beforeEmpty.step,
      "and the session has not moved — it did not run to the end of the recording",
    );
    j.countIs(
      await sent(page, "continue"),
      0,
      "no `continue` reached the engine at all, so there was no jump to undo",
    );

    // ── THREE BREAKPOINTS, ON LINES THE RECORDING ACTUALLY VISITED ────────
    const chosen = [];
    const executed = gutter0.executed;
    j.atLeast(executed.length, 3, "SUBJECTS: executed lines, so three breakpoints can be set");
    // Spread across the file rather than adjacent, so the forward walk has
    // distance to cover and "nearest preceding" is a different answer from
    // "the first one".
    for (const fraction of [0, 0.5, 1]) {
      const line = executed[Math.min(executed.length - 1, Math.round(fraction * (executed.length - 1)))];
      if (!chosen.includes(line)) chosen.push(line);
    }
    j.countIs(chosen.length, 3, "three distinct executed lines were chosen to mark");
    j.note(`marking lines ${JSON.stringify(chosen)} of ${gutter0.docPath}`);

    let clicked = 0;
    for (const line of chosen) if (await clickGutter(page, line)) clicked++;
    j.countIs(clicked, 3, "CONTROL: three gutter rows were visible and were clicked");

    await page.waitForTimeout(500);
    const gutter1 = await readGutter(page);
    // THE MARK IS A CONTROL, NOT THE VERDICT — see the header.
    j.countIs(gutter1.marked.length, 3, "CONTROL: exactly three lines carry a breakpoint mark");
    j.expect(
      JSON.stringify(gutter1.marked.slice().sort((a, b) => a - b)) ===
        JSON.stringify(chosen.slice().sort((a, b) => a - b)),
      "CONTROL: the marked lines are the lines that were clicked",
      `marked ${JSON.stringify(gutter1.marked)} vs clicked ${JSON.stringify(chosen)}`,
    );
    j.countIs(
      gutter1.pressed,
      3,
      "CONTROL: the same three rows announce themselves pressed to a screen reader",
    );
    // THE GESTURE REACHED THE ENGINE. The DOM cannot tell this apart from a
    // handler that painted a mark and sent nothing — which is the exact build
    // this feature replaced.
    j.countIs(
      await sent(page, "setBreakpoints"),
      3,
      "CONTROL: three `setBreakpoints` frames reached the engine, one per click",
    );

    // ── THE VERDICT: WHERE CONTINUE STOPS ─────────────────────────────────
    const forwardWalk = await walk(page, "continue");
    const forward = forwardWalk.stops;
    j.atLeast(forward.length, 3, "continuing forward stops at least three times");
    j.countIs(
      forward.filter((s) => chosen.includes(s.line)).length,
      forward.length,
      "every forward stop is on one of the marked lines, and none is anywhere else",
    );
    j.countIs(
      new Set(forward.map((s) => s.line)).size,
      3,
      "the forward walk reaches all three marked lines, not just the first",
    );
    j.expect(
      forward.every((s, i) => i === 0 || s.step > forward[i - 1].step),
      "each forward stop is strictly later in the recording than the one before",
      forward.map((s) => `${s.step}@${s.line}`).join(" -> "),
    );

    // RUNNING OUT OF BREAKPOINTS DOES NOT MOVE THE SESSION EITHER.
    //
    // The arm above proves it for a session with NO breakpoints, which this
    // implementation answers without touching the engine. This proves it for
    // the harder case the engine does reach: `step_continue` runs to the end of
    // the recording and only then reports that it hit nothing, so "unchanged"
    // here is a position that was actually left and restored. Without the
    // restore the session would sit at the last step of the trace — a jump the
    // visitor did not ask for, and §10.8's named failure.
    j.expect(
      forwardWalk.final !== null && forwardWalk.final.outcome === "no-breakpoint",
      "the forward walk ends by reporting there was no further breakpoint",
      `data-outcome=${JSON.stringify(forwardWalk.final?.outcome ?? null)}`,
    );
    j.countIs(
      forwardWalk.final?.step ?? -1,
      forward.length > 0 ? forward[forward.length - 1].step : -2,
      "and that continue left the session on the last breakpoint it reached",
    );

    // ── REVERSE: THE NEAREST PRECEDING ONE, NOT THE FIRST ─────────────────
    //
    // The discrimination is asserted before it is relied on. If the stop
    // nearest before the end happened to BE the first stop, the comparison
    // below would pass for an implementation that always rewinds to the top,
    // and this journey would be reporting a green it had not earned.
    const guardsDiscrimination =
      forward.length >= 3 && forward[forward.length - 2].step !== forward[0].step;
    j.expect(
      guardsDiscrimination,
      "the nearest-preceding stop differs from the first, so reversing can tell them apart",
      forward.length >= 2
        ? `nearest preceding = ${forward[forward.length - 2].step}, first = ${forward[0].step}`
        : "too few stops to say",
    );

    const back = (await walk(page, "reverse-continue")).stops;
    // Reversing from the last stop must retrace the forward stops in reverse,
    // minus the one it started on.
    const wanted = forward.slice(0, -1).reverse();
    j.countIs(
      back.length,
      wanted.length,
      "reversing from the last stop makes one stop for each earlier forward stop",
    );
    j.expect(
      back.length > 0 && back[0].step === forward[forward.length - 2].step,
      "the first reverse continue lands on the stop NEAREST BEFORE it, not the first in the file",
      back.length > 0
        ? `landed on ${back[0].step}, nearest preceding is ${forward[forward.length - 2].step},` +
          ` first is ${forward[0].step}`
        : "no reverse stop was made",
    );
    j.expect(
      JSON.stringify(back.map((s) => s.step)) === JSON.stringify(wanted.map((s) => s.step)),
      "the whole reverse walk is the forward walk retraced, stop for stop",
      `back ${JSON.stringify(back.map((s) => s.step))} vs expected ${JSON.stringify(wanted.map((s) => s.step))}`,
    );
    j.expect(
      back.every((s, i) => i === 0 || s.step < back[i - 1].step),
      "each reverse stop is strictly earlier in the recording than the one before",
      back.map((s) => `${s.step}@${s.line}`).join(" -> "),
    );

    // ── AND CLEARING IS THE SAME GESTURE ──────────────────────────────────
    // §10.8: "set by clicking the gutter beside a line, and cleared the same
    // way". Asserted on the DOM and on the wire together, because a clear that
    // repainted the gutter without telling the engine would leave the session
    // stopping at a line with no mark on it.
    const before = await sent(page, "setBreakpoints");
    await clickGutter(page, chosen[0]);
    await page.waitForTimeout(500);
    const gutter2 = await readGutter(page);
    j.countIs(gutter2.marked.length, 2, "clicking a marked line again clears it");
    j.countIs(
      (await sent(page, "setBreakpoints")) - before,
      1,
      "and the clear reaches the engine as its own `setBreakpoints`",
    );
  } finally {
    await page.close();
  }
}
