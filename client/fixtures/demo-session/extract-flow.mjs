#!/usr/bin/env node
//
// extract-flow.mjs — build `flow.json` from the REAL `zk_shields.ct` container.
//
// ## Why this script is committed
//
// `flow.json` beside it is the omniscience fixture: the inline values the debug
// route's Code pane renders against `src/shield.nr`. Every number in it is a
// value the recorder wrote into `fixtures/trace/noir_space_ship/zk_shields.ct`,
// not a number anybody typed. The difference matters more here than anywhere
// else on this route: a values overlay whose numbers do not satisfy the source
// beside them is unfalsifiable — nobody can tell it from a correct one — and
// `Page-Descriptions.md` names an unconditional values claim as "the one thing
// this product cannot afford: a confident answer that is sometimes wrong".
//
// So the fixture is DERIVED, and this is the derivation, committed so that the
// claim can be re-checked rather than believed:
//
//     ct-print --full fixtures/trace/noir_space_ship/zk_shields.ct > /tmp/zk.json
//     node client/fixtures/demo-session/extract-flow.mjs /tmp/zk.json \
//       > client/fixtures/demo-session/flow.json
//
// `ct-print` is `codetracer-trace-format-nim`'s reader. It is NOT a build
// dependency of this repository and is deliberately not wired into any `just`
// target: the container is vendored precisely because `nargo trace` is not
// byte-deterministic (see `fixtures/trace/noir_space_ship/README.md`), and a
// fixture regenerated on every build would inherit that.
//
// ## The three rules this script encodes, and why each one is a rule
//
// 1. **Nothing after the session's position.** Steps with a trace tick greater
//    than `POSITION_TICKS` are dropped. The static page is a still frame at one
//    position; a label showing what a line will do LATER in the pass the
//    session is currently inside is a value that does not exist yet at the
//    coordinate the page claims to be at. It is also directly contradicted by
//    the gutter: `demo_session.executedLines()` marks line 19 unvisited, and a
//    value against line 19 would put a number on a line the same page says has
//    not run.
//
//    What this rule does NOT drop is the rest of a COMPLETED pass. Iterations 0
//    and 1 of the loop ran to the end before the session reached iteration 2,
//    so their `remaining_shield -= damage` and `+= regeneration` are recorded
//    facts at this coordinate and the loop control reaches them. That is the
//    whole point of an omniscient debugger and it is what the iteration slider
//    is for.
//
// 2. **A label belongs to the pass that produced it.** Every step carries the
//    loop iteration it happened in — including steps in the CALLEES the loop
//    body invokes, which get the iteration of the call that made them. Without
//    that, moving the slider to iteration 5 would leave `calculate_damage`'s
//    iteration-2 locals on screen, which is a value from a different call
//    presented as this one's.
//
// 3. **A line's labels are the variables that line actually mentions, plus the
//    ones it wrote.** The recorder writes a full variable snapshot at every
//    step — seven or eight names by the middle of the loop — and rendering all
//    of them against every line would put `masses` beside `let mut regeneration
//    = 0`. `named()` below is the same standalone-identifier test
//    `flow_layout.findExpressionColumn` uses to place the label, so a variable
//    is labelled exactly where the layout can point at it.
//
// ## What a "flow step" is here
//
// One (source line, call) pair, not one recorded step. The recorder is
// column-aware, so `damage = mass * (100 - shield_pct);` is three steps at
// three columns, and a call splits its caller's line into two runs — the steps
// before the call and the steps after it. Both are collapsed: `before` is the
// snapshot on entering the line for the first time and `after` is the snapshot
// on leaving it for the last, which is what makes `let damage =
// calculate_damage(…)` read `[damage=2000]` rather than showing nothing on the
// way in and everything on the way back.

import { readFileSync } from "node:fs";

// ---------------------------------------------------------------------------
// The position, and the frame this window covers
// ---------------------------------------------------------------------------

const FILE = "src/shield.nr";

const POSITION_TICKS = 195;
// The trace tick of `src/shield.nr:32` in the third pass of the loop —
// `damage = mass * (100 - shield_pct);` with `mass = 200` and
// `shield_pct = 90`, which is the position `demo_session.nim` declares
// (`FixtureFile`/`FixtureLine`) and reasons its state pane from.
//
// It is NOT `demo_session.FixtureStep` (128). That constant is the DISPLAY
// coordinate the demo tree publishes and `views.mjs` pins its captures to; the
// real container's step 128 is `calculate_shield_regeneration:42` in the second
// pass. The two have disagreed since the fixture was written, and this script
// does not resolve that — it takes the position `demo_session.nim` states in
// words and finds the tick that IS that position, so the values are the values
// of the frame the rest of the page describes.

const CALL_UNDER_TEST = "iterate_asteroids";
// The first `iterate_asteroids` call — `main` runs it twice, once per test
// case, and the session is in the first. Everything it and its callees did in
// `src/shield.nr` is this window.

const LOOP = { first: 4, last: 15, registeredLine: 4 };
// `for i in 0..8 {` opens on 4 and the body closes on 15. `firstBodyStepIn`
// treats the range as `> first .. <= last`, so the header is excluded and the
// closing line is not.

// ---------------------------------------------------------------------------

const raw = JSON.parse(readFileSync(process.argv[2] ?? "/dev/stdin", "utf8"));
const events = raw.events ?? [];

const steps = events.filter((e) => e.kind === "step");
const byTick = new Map(steps.map((s) => [s.step_index, s]));
const entries = events.filter((e) => e.kind === "call_entry");
const exitsAt = new Map(
  events.filter((e) => e.kind === "call_exit").map((e) => [e.exit_step, e]),
);

const outer = entries.find((c) => c.function === CALL_UNDER_TEST);
if (!outer) throw new Error(`no ${CALL_UNDER_TEST} call in this trace`);

/** The innermost call containing `tick`. */
function callAt(tick) {
  let best = null;
  for (const c of entries) {
    if (c.entry_step <= tick && tick <= c.exit_step) {
      if (best === null || c.depth > best.depth) best = c;
    }
  }
  return best;
}

/** A recorded value, as the string a label shows. */
function text(v) {
  switch (v?.kind) {
    case "Int":
      return String(v.i);
    case "Bool":
      return v.b ? "true" : "false";
    case "Sequence":
    case "Array":
      return "[" + (v.elements ?? []).map(text).join(", ") + "]";
    case "String":
      return v.s ?? "";
    default:
      return JSON.stringify(v);
  }
}

function snapshot(step) {
  const out = {};
  for (const v of step.vars ?? []) out[v.varname] = text(v.value);
  return out;
}

// `flow_layout.isFlowIdentifierChar`, restated. Quote characters count as
// identifier characters on purpose: it is what keeps a search for `x` from
// matching inside `"x"`, and this file has to agree with the module that will
// place the label or the two disagree about whether a line mentions a name.
const IDENT = /[A-Za-z0-9_'"]/;

function named(line, name) {
  let from = 0;
  for (;;) {
    const at = line.indexOf(name, from);
    if (at < 0) return false;
    const before = at === 0 || !IDENT.test(line[at - 1]);
    const end = at + name.length;
    const after = end >= line.length || !IDENT.test(line[end]);
    if (before && after) return true;
    from = at + 1;
  }
}

// ---------------------------------------------------------------------------
// Iterations
// ---------------------------------------------------------------------------

// The loop header's tick on each pass. `flow_loop_math.activeIterationForTicks`
// reads this as a list of interval STARTS, so it is the first tick of each pass
// and never a tick the debugger stops on inside a body.
const headerTicks = [];
{
  let previous = -2;
  for (const s of steps) {
    if (s.step_index < outer.entry_step || s.step_index > outer.exit_step) continue;
    if (s.path !== FILE || s.line !== LOOP.registeredLine || s.depth !== outer.depth) continue;
    if (s.step_index !== previous + 1) headerTicks.push(s.step_index);
    previous = s.step_index;
  }
}
// The last entry is the pass that FAILED the condition and left the loop; it is
// a header evaluation, not an iteration, and counting it would report nine
// passes through an eight-element array.
const iterationTicks = headerTicks.slice(0, -1);

function iterationOf(tick, line, depth) {
  const inBody =
    (depth === outer.depth && line >= LOOP.first && line <= LOOP.last) ||
    depth > outer.depth;
  if (!inBody) return -1;
  let index = -1;
  for (let i = 0; i < iterationTicks.length; i++) {
    if (tick >= iterationTicks[i]) index = i;
  }
  return index;
}

// ---------------------------------------------------------------------------
// Runs → flow steps
// ---------------------------------------------------------------------------

const runs = [];
for (const s of steps) {
  if (s.step_index < outer.entry_step || s.step_index > outer.exit_step) continue;
  if (s.path !== FILE) continue;
  // Rule 1, applied HERE and not after merging. A line the session is inside —
  // `let damage = calculate_damage(…)` on the pass it is currently in — has a
  // run before the call and another after it returns, and the second is past
  // the position. Merging first and cutting afterwards would give that entry a
  // span that CONTAINS the position, so the stopped-on-line exception below
  // would fire for it and put the call's result on a line whose call has not
  // returned. That is the future value this whole script exists to keep off
  // the page, and it appeared on the first run that had the exception.
  if (s.step_index > POSITION_TICKS) continue;
  const last = runs[runs.length - 1];
  if (
    last &&
    last.line === s.line &&
    last.depth === s.depth &&
    last.end + 1 === s.step_index
  ) {
    last.end = s.step_index;
    continue;
  }
  runs.push({
    line: s.line,
    depth: s.depth,
    fn: s.function,
    start: s.step_index,
    end: s.step_index,
    call: callAt(s.step_index)?.call_key ?? -1,
  });
}

/** The next step in the SAME frame ON ANOTHER LINE — where this line's writes land.
 *
 * "Another line" matters because the recorder is column-aware: `damage = mass *
 * (100 - shield_pct);` is three steps at three columns and the assignment has
 * not landed on any of them. Stopping at the first of those would report a
 * statement as having done nothing, which is what it did report for the line
 * the session sits on — the one line a reader is guaranteed to look at.
 *
 * It scans `byTick` rather than the run list, so it can look one step past the
 * position when the caller is allowed to. Whether it is allowed to is the
 * caller's decision, not this function's. */
function afterStep(run) {
  for (let t = run.end + 1; t <= outer.exit_step; t++) {
    const s = byTick.get(t);
    if (!s) return null;
    if (s.depth < run.depth) return null; // the frame returned
    if (s.depth === run.depth && s.path === FILE && s.line !== run.line) return s;
  }
  return null;
}

// One entry per (call, line, iteration), merging the runs a nested call split
// apart. The ITERATION is part of the key and not an afterthought: `outer` is a
// single call containing all eight passes, so keying on `(call, line)` alone
// folds every pass of `remaining_shield -= damage` into one entry whose
// `before` is the first pass's and whose `after` is the last's. That produces a
// label spanning eight passes and belonging to none — which was this script's
// first output, and it is exactly the "value placed against the wrong
// expression" the fidelity rule forbids, wearing a plausible number.
const merged = new Map();
for (const run of runs) {
  const iteration = iterationOf(run.start, run.line, run.depth);
  const key = `${run.call}:${run.line}:${iteration}`;
  const existing = merged.get(key);
  if (existing) {
    existing.end = run.end;
    existing.runs.push(run);
  } else {
    merged.set(key, { ...run, iteration, runs: [run] });
  }
}

const source = readFileSync(new URL("./src/shield.nr", import.meta.url), "utf8")
  .replace(/\r\n/g, "\n")
  .split("\n");

const out = [];
for (const entry of merged.values()) {
  // Rule 1: nothing the session has not reached.
  if (entry.start > POSITION_TICKS) continue;

  const first = byTick.get(entry.start);
  const before = snapshot(first);
  const lastRun = entry.runs[entry.runs.length - 1];
  const tail = afterStep(lastRun);

  // THE LINE THE SESSION IS STOPPED ON is the one exception to rule 1, and it
  // is a narrow one: its `after` is taken even though the step that carries it
  // is past the position.
  //
  // Two reasons, and the second is the one that makes it necessary rather than
  // convenient. The first is that "what does this statement do" is the question
  // a reader has about the statement they are stopped on, and `[damage: 0 →
  // 2000]` answers it in the spec's own headline rendering while naming both
  // sides, so it cannot be read as a claim that `damage` IS 2000 right now.
  //
  // The second: `demo_session.fixtureState` renders `damage = 2000` in the
  // Values pane at this coordinate, derived from the same line. Withholding it
  // here would put `[damage=0]` on line 32 with `damage 2000` in the pane
  // beside it — one screen contradicting itself, which is a worse failure than
  // either answer alone.
  //
  // It cannot leak a future value anywhere else, because the exception is
  // keyed on the position falling INSIDE this entry's own recorded span. Line 6
  // of the same pass — `let damage = calculate_damage(…)`, entered and not yet
  // returned — is not that line, and correctly shows no `damage` at all.
  const stoppedHere = entry.start <= POSITION_TICKS && POSITION_TICKS <= entry.end;
  const after =
    tail && (stoppedHere || tail.step_index <= POSITION_TICKS)
      ? snapshot(tail)
      : { ...before };

  const line = source[entry.line - 1] ?? "";
  const names = new Set([...Object.keys(before), ...Object.keys(after)]);
  // "Written" means the name is in `after` with a different value — NOT merely
  // that the two snapshots differ. A name present in `before` and absent from
  // `after` went OUT OF SCOPE: `mass` is a `let` inside the loop body, so the
  // last statement of every pass appears to change it, and `status_report(i,
  // initial_shield, …)` was labelled `[mass=100]` for a variable it does not
  // mention and did not touch. Scope exit is not an assignment.
  const chosen = [...names].filter(
    (n) =>
      (after[n] !== undefined && before[n] !== after[n]) || named(line, n),
  );
  const exitHere = exitsAt.get(entry.end);
  const hasReturn =
    exitHere !== undefined &&
    entry.end <= POSITION_TICKS &&
    exitHere.return_value?.kind !== "Void";
  if (chosen.length === 0 && !hasReturn) continue;

  // Reading order: as the line spells them, then anything the line wrote
  // without naming. `assignExpressionColumns` re-places them against the source
  // text; this only decides which of two absent expressions gets the earlier
  // fallback slot.
  chosen.sort((a, b) => {
    const ca = line.indexOf(a);
    const cb = line.indexOf(b);
    if (ca === cb) return a < b ? -1 : 1;
    if (ca < 0) return 1;
    if (cb < 0) return -1;
    return ca - cb;
  });

  const step = {
    ticks: entry.start,
    line: entry.line,
    iteration: entry.iteration,
    function: entry.fn,
    order: chosen,
    before: {},
    after: {},
  };
  for (const n of chosen) {
    if (before[n] !== undefined) step.before[n] = before[n];
    if (after[n] !== undefined) step.after[n] = after[n];
  }
  // The spec's `[→230]`: a return has no expression in the source text at all,
  // so it travels as a property of the line rather than as a named value.
  //
  // A `Void` return is dropped rather than rendered. `status_report` returns
  // `()`, and `[→()]` would be a label whose only content is that there is no
  // value — furniture where the rule is that a pane with nothing to say says
  // nothing.
  if (hasReturn) step.returns = text(exitHere.return_value);
  out.push(step);
}
out.sort((a, b) => a.ticks - b.ticks);

const position = byTick.get(POSITION_TICKS);
const document = {
  _: [
    "DERIVED, NOT WRITTEN. Every value below is a value the recorder wrote into",
    "fixtures/trace/noir_space_ship/zk_shields.ct. Regenerate with",
    "  ct-print --full fixtures/trace/noir_space_ship/zk_shields.ct > /tmp/zk.json",
    "  node client/fixtures/demo-session/extract-flow.mjs /tmp/zk.json \\",
    "    > client/fixtures/demo-session/flow.json",
    "and see extract-flow.mjs for the three rules that decide what is in here.",
  ],
  path: FILE,
  position: {
    ticks: POSITION_TICKS,
    line: position.line,
    function: position.function,
    iteration: iterationOf(POSITION_TICKS, position.line, position.depth),
  },
  loop: { ...LOOP, iterationTicks },
  steps: out,
};

process.stdout.write(JSON.stringify(document, null, 1) + "\n");
