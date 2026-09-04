// "A visitor who opens a transaction sees the values at the position it opened
//  at — without stepping."
//
// Page-Descriptions.md §7.0 (hydration replaces the served frame with a live
// one) and §8 (no indeterminate wait).
//
// THE REPORT THIS FILE IS WRITTEN FROM
// ------------------------------------
// "I clicked on a transaction … I still got bytecode listing and no working
// call trace and values panels." Measured against `blocktracer-dev.pages.dev`
// on the transaction named: the Call Trace filled with three frames at 1.2s
// and the Values pane never filled at all. It sat on "Reading the values at
// this position…" for as long as the tab was open, and one click of Step
// forward filled it with five rows. The values were in the container the whole
// time; nothing ever asked for them. `ct/load-locals` requests reaching the
// engine at the landing position: ZERO.
//
// WHY EVERY EXISTING VALUES JOURNEY WAS GREEN THROUGH IT
// -----------------------------------------------------
// Journey 11 takes a landing reading. Its honesty verdict is that every reading
// is "either values or a sentence saying why there are none" — and "Reading the
// values at this position…" IS a sentence, so a pane that never stops saying it
// satisfies the check written to catch a pane that says nothing. Every other
// arm of 11, 16 and 18 STEPS first, and stepping is the thing that repairs the
// defect. A suite can walk fifteen positions of a session and never judge the
// one a visitor actually arrives at.
//
// THE VERDICT IS A ROUND TRIP, NOT A ROW COUNT
// --------------------------------------------
// "The pane has rows at landing" is the obvious assertion and it is the wrong
// one: a frame with no locals is a TRUE empty Values pane, and a journey that
// demanded rows would fail on a correct product the first time a recording
// landed on one. So the claim is stated as a relation between two readings of
// ONE page at ONE coordinate — read the landing, step away, step back, read
// again. The second reading is taken after a motion, which is the path the
// product was already known to serve correctly, so the pair answers the only
// question that matters: does arriving show what returning shows?
//
//   before the fix   landing "" rows / "Reading the values at this position…"
//                    returned 5 rows          -> DISAGREE, red
//   after the fix    landing  5 rows
//                    returned 5 rows          -> agree, green
//   a frame that genuinely has no locals
//                    landing  0 rows / "The engine reports no values at this
//                    returned 0 rows /  position."   -> agree, green
//
// It cannot pass vacuously on an empty pane — an all-empty corpus is caught by
// the counted non-vacuity control below, which requires at least one subject
// whose returned reading has rows in it, so the equality is being asserted over
// something.
//
// NOTHING BELOW NAMES A TRANSACTION, A CHAIN, A FILE, A STEP OR A VALUE.
// Rule 4. The subjects are the sessions that carry a container, ranked by the
// length of their recording and capped, because hydrating one costs a worker
// and an 18 MB wasm.

import { visit, readFacts } from "../lib/probe.mjs";
import { transactions } from "../lib/corpus.mjs";

export const id = "a-session-shows-the-values-it-landed-on";
export const claim =
  "A visitor who opens a transaction sees the values at the position it opened at, without stepping — the same values returning to that position shows.";
export const spec = "Page-Descriptions.md §7.0, §8 — BlockTracer";
export const assertions = 9;
export const needsEngine = true;

/**
 * The sentence the pane shows between a move and its answer.
 *
 * `live_locals.ReadingNote`. Spelled here so that a rename upstream shows up as
 * this journey failing to recognise the state it forbids, rather than as a
 * silent green — and it is the ONE state forbidden as a resting place, because
 * it is the only one that promises an arrival. Every other sentence the pane
 * can show is terminal and truthful.
 */
const READING_NOTE = "Reading the values at this position…";

/**
 * The prefix `live_locals` puts on an ENGINE refusal.
 *
 * `live_locals.RefusedNotePrefix`. A session the engine would not serve is not
 * a subject for a claim about the product: the pane is doing exactly the right
 * thing with the answer it was given, and counting it as a defect here would
 * report an engine fault in the product's vocabulary — which is the mistake
 * `run.mjs`'s Arm II exists one level up to refuse. Refusals are counted,
 * named, and excluded, and the count of what SURVIVES that exclusion is itself
 * a subject assertion, so an engine that refuses everything fails this journey
 * BY NAME rather than emptying it into a green.
 */
const REFUSED_PREFIX = "The replay engine did not answer with values here:";

/**
 * How many sessions of EACH KIND are hydrated. A budget, never the claim.
 *
 * Per kind, and not a single cap over the whole corpus, for the reason
 * `corpus.mjs` gives about `check-coverage.mjs`: ranked by recording length, a
 * single cap of four took four demo recordings and judged no chain capture at
 * all — on a journey written from a report about a chain transaction. The two
 * kinds are separated by the product's own `data-provenance` marker rather than
 * by a chain name.
 */
const CAP_PER_KIND = 2;

/** One reading of both panes, as a visitor could read them. */
const READ = () => {
  const shown = (e) =>
    !!e && typeof e.checkVisibility === "function"
      ? e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true })
      : false;
  const all = (s) => [...document.querySelectorAll(s)];
  // The call-ORDER view only. The aggregate view is a `:target` alternate whose
  // rows are functions rather than frames, and counting the class alone would
  // count one pane's rows twice in two different meanings (journey 14).
  const ct = all(".ctview.def .ctrow").filter(shown);
  const st = all("#pane-state .strow").filter(shown);
  return {
    step: document.querySelector(".dbg")?.getAttribute("data-step") ?? null,
    calltraceRows: ct.length,
    calltraceNames: ct.map((r) => r.querySelector(".ctname")?.textContent ?? ""),
    valueRows: st.length,
    valueCells: st.map((r) => ({
      name: r.querySelector(".stname")?.textContent?.trim() ?? "",
      value: r.querySelector(".stval")?.textContent?.trim() ?? "",
      type: r.querySelector(".sttype")?.textContent?.trim() ?? "",
    })),
    note: document.querySelector("#pane-state .panenote")?.textContent?.trim() ?? "",
  };
};

/**
 * The pane's content as one comparable string.
 *
 * The RENDERED text and the note, and nothing else. A class change elsewhere —
 * the changed/appeared marks a motion legitimately adds — must not present as
 * "the engine supplied different values", which is the comparison this journey
 * would otherwise be making instead of the one it means.
 */
const content = (r) =>
  `${r.valueRows} rows [${r.valueCells.map((c) => `${c.name}=${c.value}:${c.type}`).join(" | ")}] note=${JSON.stringify(r.note)}`;

/**
 * Read once the panes have stopped changing.
 *
 * For STABILITY, not for a particular sentence: waiting on a string would be
 * asserting the product's copy from inside the timing loop, and would hang the
 * day the copy changed. The defect this file is written against produces a
 * PERFECTLY STABLE reading — the Reading note never goes away — so settling is
 * not the verdict and must not be mistaken for one. It only guarantees that the
 * two readings compared below are each a whole state rather than a pane caught
 * mid-update.
 */
async function settled(page, timeoutMs = 20000) {
  const deadline = Date.now() + timeoutMs;
  let last = await page.evaluate(READ);
  let seen = JSON.stringify(last);
  let stable = 0;
  while (Date.now() < deadline && stable < 3) {
    await page.waitForTimeout(200);
    last = await page.evaluate(READ);
    const now = JSON.stringify(last);
    stable = now === seen ? stable + 1 : 0;
    seen = now;
  }
  return last;
}

/**
 * Click a control and wait for the engine to report the stop it caused.
 *
 * A SELECTOR AND NOT AN `ElementHandle`, which is what broke this journey as an
 * instrument. `page.$` resolves the node once and returns a handle to THAT node;
 * the debugger re-renders its control strip on every engine stop, so between the
 * resolve and the click the node the handle names has been replaced and
 * Playwright throws `Element is not attached to the DOM`. That threw out of
 * `run()` and took the seven assertions below the loop with it: the journey
 * declared nine and made two, which reports nothing about the seven rather than
 * reporting them red. `page.click` re-resolves the selector on each retry, so a
 * re-render is waited through instead of raced — and it is what the nine other
 * journeys driving this same control already do.
 *
 * A FAILED CLICK IS STILL A FINDING, not a swallow. It returns `moved: false`,
 * which is the same answer the pre-existing "the control is not available" path
 * gives, and that answer is already GATED: `judged`/`comparable` both carry a
 * `j.subjects(…, 1, …)` floor, so a run in which no session could be moved fails
 * by name. The reason is threaded back to the caller so it reaches the journal
 * rather than disappearing into an empty set.
 */
async function gesture(page, action) {
  const before = await page.evaluate(READ);
  const sel = `[data-action="${action}"]:not(.off)`;
  // `$` for PRESENCE only — "is this control offered at this stop?" is a
  // question about now, and an absent control must answer immediately rather
  // than being waited for. The handle is deliberately not kept.
  if ((await page.$(sel)) === null)
    return { moved: false, reading: before, why: `no enabled ${action} control` };
  try {
    await page.click(sel, { timeout: 15000 });
  } catch (e) {
    return {
      moved: false,
      reading: before,
      why: `${action} never became clickable: ${String(e).split("\n")[0]}`,
    };
  }
  const deadline = Date.now() + 25000;
  while (Date.now() < deadline) {
    const now = await page.evaluate(READ);
    if (now.step !== before.step) break;
    await page.waitForTimeout(200);
  }
  return { moved: true, reading: await settled(page) };
}

export async function run({ browser, site, j }) {
  const all = await transactions(site.root);

  // Ranked by the length of the recording so that the cap takes the sessions
  // with the most to say, and never by name. Taken per KIND — see CAP_PER_KIND.
  const longest = (xs) => xs.sort((a, b) => b.totalSteps - a.totalSteps).slice(0, CAP_PER_KIND);
  const withContainer = all.filter((t) => t.hasContainer);
  const candidates = [
    ...longest(withContainer.filter((t) => t.real)),
    ...longest(withContainer.filter((t) => !t.real)),
  ];
  j.subjects(candidates, 1, "sessions that carry a container to replay");

  const seen = [];
  for (const t of candidates) {
    // `phase === "ready"` is published by `goLive`, which renders the CONTROLS
    // and deliberately not the panes — so this settles the arrival and the
    // reading below settles the panes. Two waits, because they are two facts.
    const v = await visit(browser, site.origin, t.debugPath, {
      settle: (f) => f.phase === "ready",
    });
    try {
      if (!v.settled) {
        j.note(`SKIPPED (never went live): ${t.debugPath} — ${v.facts.engineNotice || "no notice"}`);
        continue;
      }
      const landing = await settled(v.page);

      // AWAY AND BACK. The second reading is of the SAME coordinate, reached by
      // the path the product was already known to serve — a motion. If the
      // session cannot be moved and returned, it is not a subject for the
      // comparison and says so rather than being counted as agreeing.
      const away = await gesture(v.page, "step-forward");
      const back = away.moved
        ? await gesture(v.page, "step-backward")
        : { moved: false, why: `never left: ${away.why}` };
      const returned =
        back.moved && back.reading.step === landing.step ? back.reading : null;

      seen.push({ t, landing, returned });
      // WHY IT WAS NOT REACHED, and not merely THAT it was not. A session that
      // drops out of `comparable` shrinks the set the equality is taken over,
      // and the `j.subjects` floor tells you the set went empty but not what
      // emptied it. The reason a gesture gave is the only record of that.
      const notReached =
        !back.moved
          ? `not reached — ${back.why}`
          : back.reading.step !== landing.step
            ? `not reached — returned to step ${back.reading.step}, landed at ${landing.step}`
            : null;
      j.note(
        `${t.debugPath}: landing ${landing.valueRows} value rows / ` +
          `${landing.calltraceRows} frames / note=${JSON.stringify(landing.note)}; ` +
          `returned ${returned ? `${returned.valueRows} value rows` : notReached}`,
      );
    } finally {
      await v.page.close();
    }
  }

  // ── 0. WHAT THE ENGINE ACTUALLY SERVED ────────────────────────────────────
  //
  // A session the engine refused is excluded from every values arm below, and
  // the size of what is left is asserted — so an engine that refuses the whole
  // corpus fails HERE, by name, instead of emptying four verdicts into a green.
  const refused = seen.filter((s) => s.landing.note.startsWith(REFUSED_PREFIX));
  for (const s of refused) j.note(`ENGINE REFUSED (not judged): ${s.t.debugPath}`);
  const judged = seen.filter((s) => !refused.includes(s));
  j.subjects(judged, 1, "landed sessions the replay engine served rather than refused");

  // ── 1. THE LANDING PANE IS NEVER LEFT PROMISING AN ARRIVAL ────────────────
  //
  // §8 forbids an indeterminate wait, and this is the one resting state that is
  // one. Asserted over every subject and not over one, because the defect was
  // universal: it is a property of arriving, not of a recording.
  const promising = judged.filter((s) => s.landing.note === READING_NOTE);
  j.countIs(
    promising.length,
    0,
    `no landed session is left saying it is still reading its values` +
      (promising.length === 0
        ? ""
        : `; stuck: ${promising.map((s) => s.t.debugPath).join(", ")}`),
  );

  // ── 2. THE VERDICT: arriving shows what returning shows ───────────────────
  const comparable = judged.filter((s) => s.returned !== null);
  j.subjects(
    comparable,
    1,
    "landed sessions that could be stepped away from and back to their landing",
  );
  const disagreeing = comparable.filter(
    (s) => content(s.landing) !== content(s.returned),
  );
  j.countIs(
    disagreeing.length,
    0,
    `the Values pane at the landing position says what it says on returning to it` +
      (disagreeing.length === 0
        ? ""
        : `; disagreeing: ${disagreeing
            .map(
              (s) =>
                `${s.t.debugPath}\n             landing  ${content(s.landing)}` +
                `\n             returned ${content(s.returned)}`,
            )
            .join("\n           ")}`),
  );

  // ── 3. NON-VACUITY, COUNTED ───────────────────────────────────────────────
  //
  // The equality above is satisfied by a corpus in which every pane is empty at
  // both readings. This is the control that says the comparison was made over
  // values that exist: at least one subject's RETURNED reading — the one taken
  // after a motion, on the path known to work — has rows in it.
  const withValues = comparable.filter((s) => s.returned.valueRows > 0);
  j.atLeast(
    withValues.length,
    1,
    "at least one session's Values pane has rows in it at all, so the equality is asserted over something",
  );

  // ── 4. …AND THOSE ROWS ARE PAINTED AT THE LANDING, not only after a step ──
  //
  // The positive form of the claim, stated separately from the equality so that
  // a run in which both readings were empty for a NEW reason cannot report this
  // capability as present.
  const landedWithValues = judged.filter((s) => s.landing.valueRows > 0);
  j.atLeast(
    landedWithValues.length,
    1,
    "at least one session paints Values rows at the position it landed on, before any motion",
  );

  // ── 5. THE OTHER PANE OF THE PAIR THE REPORT NAMED ────────────────────────
  //
  // The Call Trace is the half that was already working, and it is asserted
  // here so that a regression which empties BOTH panes cannot present as this
  // journey's Values arms merely agreeing with each other.
  const landedWithFrames = seen.filter((s) => s.landing.calltraceRows > 0);
  j.atLeast(
    landedWithFrames.length,
    1,
    "at least one session paints Call Trace frame rows at the position it landed on",
  );

  // ── 6. A PAINTED ROW IS A ROW WITH SOMETHING IN IT ────────────────────────
  //
  // "The pane has rows" is satisfied by rows rendering blank cells, which is a
  // defect this campaign has already had once, one layer down, in the value
  // decoder (`live_locals`' `tkInt` arm). Counted over the cells rather than
  // over the panes so that one blank row in one session is visible.
  const blank = judged.flatMap((s) =>
    s.landing.valueCells
      .filter((c) => c.name === "" || c.value === "")
      .map((c) => `${s.t.debugPath} ${JSON.stringify(c)}`),
  );
  j.countIs(
    blank.length,
    0,
    `every value row painted at a landing carries a name and a value` +
      (blank.length === 0 ? "" : `; blank: ${blank.join("; ")}`),
  );
}
