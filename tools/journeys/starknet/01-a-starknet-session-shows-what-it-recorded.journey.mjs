// "A Starknet session shows what its recording carries, in the shared panes."
//
// A Starknet recording puts three shapes in front of the debugger that no
// Aztec recording does (codetracer-pm 2026-10-20, "HSF-B2's shared views must
// render Starknet recordings"):
//
//   1. VALUES ARE FELTS. Call arguments are `ValueRecord::BigInt` — 252-bit
//      field elements — and `calldata` is a Sequence of them, beside String
//      arguments (`contract`, `class_hash`, `caller`). A value view that drew
//      Int and not BigInt would show a name and nothing else for every one.
//   2. SOURCE IS A CASM LISTING. Each class publishes `<class hash>.casm`, one
//      line per instruction (`0x<pc>  <instruction>`) with label and sierra
//      comment lines between, and steps are positioned on instruction lines
//      only. Until the position reader was taught `cairo-casm-positions/1`
//      the pane drew no listing at all and said no source was resolved.
//      A STEP MUST NOT REWRITE THE LISTING. 28,936 lines is about 146,000
//      nodes, and rewriting them on every stop held the page for 6 to 64
//      seconds a step. A stop that stays in the shown document moves the mark
//      and leaves the rows where they are, so the row this journey tags before
//      a step is the same element after it — deterministic, where a time
//      bound on a loaded runner would not be.
//   3. THE CALL TREE IS DEEP AND WIDE, with frames named by full Cairo paths
//      (`core::array::deserialize_array_helper::<…>`) — the call trace must
//      hold them inside the pane.
//
//   4. A CALL CAN FAIL INSIDE A TRANSACTION THAT SUCCEEDS. The entry point's
//      frame returns `ValueRecord::Error` and the recording carries an
//      `EventLogKind::Error` event at the failure. The event must read as the
//      error and not as program output — the engine marked every non-write
//      event `stdout`, so it read "stdout: Entry point … not found in
//      contract." — and jumping to it must mark the call that failed, whose
//      return names the same error. Until 2026-11-01 this shape had no subject
//      in the corpus; block 17,261,713's only transaction (a call to a selector
//      its target does not have, at call depth 3) is it. Its SUBJECTS are read
//      from the engine's event kind, never from the text the verdicts judge.
//
// This set runs over `packages.site-starknet`, not the Aztec-only `default`
// site the main suite judges: `node tools/journeys/run.mjs --set starknet`.

import {
  visit,
  readFacts,
  consoleMark,
  waitForConsoleLine,
  POSITION_ANSWERED,
  tickOf,
  waitForFacts,
} from "../lib/probe.mjs";
import { transactions, landingOf } from "../lib/corpus.mjs";

export const id = "a-starknet-session-shows-what-it-recorded";
export const claim = "A Starknet session shows what its recording carries, in the shared panes.";
export const spec = "codetracer-pm issue 2026-10-20 (HSF-B2, Starknet) — BlockTracer";
export const assertions = 18;
export const needsEngine = true;

/** How many steps each session is walked, reading the mark at every stop. */
const WALK = 4;

/** A CASM instruction line: a program counter, two spaces, an instruction. */
const INSTRUCTION = /^0x[0-9a-f]+ {2}\S/;
/** A felt as the State view draws it: decimal, or hex. */
const FELT = /^(\d+|0x[0-9a-f]+)$/;

/** The call-trace rows on screen, and how many overflow their own box. */
const readCalltrace = (page) =>
  page.evaluate(() => {
    const shown = (e) =>
      !!e &&
      typeof e.checkVisibility === "function" &&
      e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
    const rows = [...document.querySelectorAll(".calltrace-call-line")].filter(shown);
    const pane = document.querySelector("#pane-calltrace");
    return {
      shown: rows.length,
      overflowing: rows.filter((r) => r.scrollWidth > r.clientWidth + 1).length +
        (pane && pane.scrollWidth > pane.clientWidth + 1 ? 1 : 0),
      longestName: Math.max(0, ...rows.map((r) => (r.getAttribute("data-function") ?? "").length)),
    };
  });

/** The live Event Log's rows, and the pane they are in, found by PROPERTY. */
const EV_LIVE = "tr.eventLog-row";

/**
 * Show the Event Log. The shared view mounts when its tab is shown and draws
 * rows only once it has measured its viewport, so its rows are not there
 * before. The tab is found the way journey 09 finds it: the pane that holds
 * the event rows, and the control whose fragment points at that pane.
 */
async function showEventLog(page) {
  const opened = await page.evaluate(() => {
    const pane = document.querySelector(".evrow,.eventLog-row")?.closest(".lm_content");
    if (!pane || !pane.id) return false;
    const tab = document.querySelector(`a[href="#${CSS.escape(pane.id)}"]`);
    if (!tab) return false;
    tab.click();
    return true;
  });
  if (opened) {
    await page
      .waitForFunction((ev) => document.querySelectorAll(ev).length > 0, EV_LIVE, { timeout: 15000 })
      .catch(() => {});
  }
  return opened;
}

/**
 * The Event Log's Error rows. THE KIND IS THE ENGINE'S (`data-event-kind`,
 * the recorded `EventLogKind`), NOT THE TEXT: the text is what the verdicts
 * judge, and a subject taken from it would vanish under the very defect it
 * exists to catch.
 */
const errorRows = (page) =>
  page.evaluate((ev) =>
    [...document.querySelectorAll(ev)]
      .map((r, i) => ({
        i,
        kind: r.getAttribute("data-event-kind"),
        text: (r.querySelector(".eventLog-text")?.textContent ?? "").trim(),
      }))
      .filter((r) => r.kind === "Error"), EV_LIVE);

/** The call-trace row marked current, and the return it draws. */
const currentCall = (page) =>
  page.evaluate(() => {
    const row = document.querySelector(".call-current")?.closest(".calltrace-call-line");
    if (!row) return null;
    return {
      fn: row.getAttribute("data-function") ?? "",
      ret: (row.querySelector(".return-text")?.textContent ?? "").trim(),
    };
  });

/** An Error value as the shared presenter draws one. */
const ERROR_RETURN = /^<error: (.+)>$/;

/** One step forward, waiting for the engine's answer rather than for a change. */
async function stepForward(page) {
  const mark = consoleMark(page);
  await page.click('[data-action="step-forward"]');
  const answered = await waitForConsoleLine(page, POSITION_ANSWERED, { sinceIndex: mark, budgetMs: 15000 });
  const tick = tickOf(answered);
  if (tick !== null) await waitForFacts(page, (f) => f.step === tick, 8000);
  return readFacts(page);
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);
  // SMALLEST FIRST. The first session a browser opens compiles the replay
  // engine; opening the 18,903-step recording first put that cost and its own
  // on one deadline. The order changes no claim: each is judged per session.
  //
  // ALL BUT THE DEEPEST. The one with the most frames is judged by its own
  // journey (`02-the-deepest-starknet-session-comes-up`), because its first
  // paint is the one whose cost can regress; keeping it here would turn every
  // claim below red for that one reason.
  const ordered = all
    .filter((t) => t.chain === "starknet-mainnet" && landingOf(t.phase) === "session")
    .sort((a, b) => (a.calltraceFrames ?? 0) - (b.calltraceFrames ?? 0));
  const sessions = j.subjects(
    ordered.slice(0, -1),
    2,
    "Starknet transactions whose landing is a session, the deepest one aside",
  );

  let ready = 0;
  let pageErrors = 0;
  let feltsShown = 0;
  let stringsShown = 0;
  let casmMarks = 0;
  const offInstruction = [];
  let sameDocSteps = 0;
  const rewrites = [];
  let deepest = { steps: 0, path: "" };
  // EVERY JUDGED SESSION'S CALL TRACE, read before the failed-call jump moves
  // it. Until 2026-11-02 these claims were taken from the session with the
  // most steps, and the long-path CONTROL held only because that session's
  // classes happen to be bound to a proved build of their source (their
  // frames are named by Cairo path). The failed-call transaction has more
  // steps and unbound classes, whose frames are `fn@0x…` labels; picking a
  // subject by name length instead would be choosing it by the CONTROL. So
  // every session is read, the CONTROL asks that SOME frame carries a long
  // Cairo path, and no row of any session may overflow.
  const calltraces = [];
  let errorSessions = 0;
  let errorEvents = 0;
  const errorsAsStdout = [];
  let errorsNamed = 0;
  const errorJumps = [];
  let errorReturnsMatch = 0;

  for (const t of sessions) {
    const live = await visit(browser, site.origin, t.debugPath, {
      settle: (f) => f.phase === "ready" && f.controlsLive > 0,
    });
    const page = live.page;
    try {
      pageErrors += live.pageErrors.length;
      // A session that never came up is counted by the first verdict below;
      // walking it would only time out on a control that is not live.
      if (!live.settled || live.timedOut) continue;
      ready += 1;
      let facts = await readFacts(page);

      // 1. Felts: a Sequence of felt252 with every element drawn, and the
      //    String arguments beside it.
      const seq = facts.stateRows.find((r) => /felt252/.test(r.type) && /^@\[/.test(r.value));
      const elems = seq ? seq.value.replace(/^@\[|\]$/g, "").split(",").map((x) => x.trim()) : [];
      if (elems.length > 0 && elems.every((x) => FELT.test(x))) feltsShown += 1;
      const strings = facts.stateRows.filter((r) => r.type === "String" && /^0x[0-9a-f]+$/.test(r.value));
      if (strings.some((r) => /^contract/.test(r.name)) && strings.some((r) => /^class_hash/.test(r.name))) {
        stringsShown += 1;
      }

      // 2. The mark, at the landing and over a short walk: wherever it is in a
      //    CASM listing, it is on an instruction line.
      for (let i = 0; i <= WALK; i++) {
        if (i > 0) {
          const before = facts.markedDoc;
          await page.evaluate(() => {
            const row = document.querySelector("#pane-editor .srcline");
            if (row) row.__btKept = true;
          });
          facts = await stepForward(page);
          if (before && facts.markedDoc === before) {
            sameDocSteps += 1;
            const kept = await page.evaluate(
              () => document.querySelector("#pane-editor .srcline")?.__btKept === true,
            );
            if (!kept) rewrites.push(`${t.hash.slice(0, 10)} step ${facts.step}`);
          }
        }
        if (facts.marked === 1 && /casm$/.test(facts.markedDoc ?? "")) {
          casmMarks += 1;
          if (!INSTRUCTION.test(facts.markedText ?? "")) {
            offInstruction.push(`${t.hash.slice(0, 10)} step ${facts.step}: ${facts.markedText}`);
          }
        }
      }

      // 3. The call tree, and the session with the longest execution.
      const steps = Number(facts.totalSteps ?? 0);
      if (steps > deepest.steps) deepest = { steps, path: t.debugPath };
      calltraces.push({ at: t.hash.slice(0, 10), ...(await readCalltrace(page)) });

      // 4. A failed call. A Starknet entry point that fails inside a
      //    transaction that does not revert is recorded with an Error event
      //    and an Error return (HSF-B2's fourth shape). The event reads as
      //    the error, and jumping to it marks the call that failed, whose
      //    return names the same error.
      if (await showEventLog(page)) {
        const errs = await errorRows(page);
        if (errs.length > 0) errorSessions += 1;
        for (const e of errs) {
          errorEvents += 1;
          if (/^stdout:/.test(e.text)) errorsAsStdout.push(`${t.hash.slice(0, 10)}: ${e.text.slice(0, 60)}`);
          if (e.text.length > 0) errorsNamed += 1;
          const mark = consoleMark(page);
          await page.locator(EV_LIVE).nth(e.i).click();
          await waitForConsoleLine(page, POSITION_ANSWERED, { sinceIndex: mark, budgetMs: 15000 });
          // Waited for BY ITS CONTENT, bounded: the mark is first still on
          // the frame the session was on, and a read taken then would judge
          // the move rather than where it ends.
          await page
            .waitForFunction(
              (re) => {
                const row = document.querySelector(".call-current")?.closest(".calltrace-call-line");
                return !!row && new RegExp(re).test((row.querySelector(".return-text")?.textContent ?? "").trim());
              },
              ERROR_RETURN.source,
              { timeout: 15000, polling: 250 },
            )
            .catch(() => {});
          const cur = await currentCall(page);
          const m = cur ? ERROR_RETURN.exec(cur.ret) : null;
          errorJumps.push({ at: t.hash.slice(0, 10), fn: cur?.fn ?? "(none)", ret: cur?.ret ?? "", ok: !!m });
          if (m && e.text.replace(/^stdout:\s*/, "").includes(m[1])) errorReturnsMatch += 1;
        }
      }
    } finally {
      await page.close();
    }
  }

  const n = sessions.length;
  j.countIs(ready, n, "every Starknet session came up live");
  j.countIs(pageErrors, 0, "no uncaught page errors in any Starknet session");
  j.countIs(feltsShown, n, "every Starknet session draws its calldata felts, each with a value");
  j.countIs(stringsShown, n, "every Starknet session draws its contract and class hash arguments");
  j.atLeast(casmMarks, 1, "CONTROL: the walks put the mark in a CASM listing");
  j.countIs(
    offInstruction.length,
    0,
    "a mark in a CASM listing is always on an instruction line, never a label or comment" +
      (offInstruction.length ? ` (${offInstruction.slice(0, 3).join("; ")})` : ""),
  );
  j.atLeast(sameDocSteps, 1, "CONTROL: the walks took steps that stayed in the shown document");
  j.countIs(
    rewrites.length,
    0,
    "a step that stays in the shown document moves the mark and does not rewrite the listing" +
      (rewrites.length ? ` (rewritten at ${rewrites.slice(0, 3).join("; ")})` : ""),
  );
  j.atLeast(deepest.steps, 5000, `CONTROL: the deepest session judged here is a long execution (${deepest.path})`);
  const bare = calltraces.filter((c) => c.shown < 1).map((c) => c.at);
  j.countIs(
    calltraces.length - bare.length,
    ready,
    "every Starknet session's call trace has rows on screen" + (bare.length ? ` (none at ${bare.join(", ")})` : ""),
  );
  j.atLeast(
    Math.max(0, ...calltraces.map((c) => c.longestName)),
    60,
    "CONTROL: the call traces judged carry long Cairo paths",
  );
  const overflowing = calltraces.reduce((n, c) => n + c.overflowing, 0);
  j.countIs(overflowing, 0, "no call-trace row, and not the pane, overflows sideways, in any session");

  j.atLeast(errorSessions, 1, "SUBJECTS: Starknet sessions whose Event Log carries an Error event");
  j.countIs(
    errorsAsStdout.length,
    0,
    "no Error event reads as standard output" +
      (errorsAsStdout.length ? ` (${errorsAsStdout.slice(0, 2).join("; ")})` : ""),
  );
  j.countIs(errorsNamed, errorEvents, "every Error event names the error it recorded");
  const missed = errorJumps.filter((x) => !x.ok);
  j.countIs(
    errorJumps.length - missed.length,
    errorEvents,
    "jumping to an Error event marks a call whose return is an error" +
      (missed.length ? ` (marked ${missed.slice(0, 2).map((x) => `${x.fn.slice(0, 24)} => ${x.ret.slice(0, 40) || "(no return)"}`).join("; ")})` : ""),
  );
  j.countIs(errorReturnsMatch, errorEvents, "and that return names the same error as the event");
}
