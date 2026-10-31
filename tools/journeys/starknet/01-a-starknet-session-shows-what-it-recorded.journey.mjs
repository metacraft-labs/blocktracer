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
// The fourth shape the issue names — `ValueRecord::Error` returns and
// `EventLogKind::Error` events on a frame whose entry point failed — has NO
// SUBJECT in this corpus: none of the five published Starknet traces carries
// either (measured with the pinned `ct-print --full` over every container on
// 2026-10-30). A claim with no subject is not asserted here; it would be a
// pass about nothing.
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
export const assertions = 13;
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
  let deepest = { steps: 0, path: "", ct: { shown: 0, overflowing: 0, longestName: 0 } };

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

      // 3. The call tree of the deepest session.
      const steps = Number(facts.totalSteps ?? 0);
      if (steps > deepest.steps) {
        deepest = { steps, path: t.debugPath, ct: await readCalltrace(page) };
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
  j.atLeast(deepest.ct.shown, 1, "the deepest session's call trace has rows on screen");
  j.atLeast(deepest.ct.longestName, 60, "CONTROL: its frames carry long Cairo paths");
  j.countIs(deepest.ct.overflowing, 0, "no call-trace row, and not the pane, overflows sideways");
}
