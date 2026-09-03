// selection-detail-selftest.mjs — proof that `test_selection_detail.nim` BITES.
//
//   cd client && just test-selection-detail-selftest
//
// A test that cannot fail is not a test, and this repository already knows it:
// every `ci/test/<subject>.sh` has a `<subject>-test.sh` beside it that plants
// deliberate violations in real source and proves the check reports them, and
// `tools/journeys/selftest.mjs` does it for the journey layer. This is that
// file for the one Nim suite whose whole reason for existing is that a guard
// somewhere else was dead.
//
// WHY THIS ONE SUITE HAS A SELFTEST AND ITS SIBLINGS DO NOT
// ---------------------------------------------------------
// `selectionDetail`'s only guard was journey 14's live assertion, and the
// mutation arm proving that assertion bites — `P4/no-frame-is-current-on-a-live-
// session` — was DEAD: its `find` string occurred zero times, so it reported
// NEVER RAN and demonstrated nothing. The behaviour had no working guard at any
// layer. A new suite written in answer to that, whose own bite nobody has
// proved, would be the same object one layer down.
//
// TWO SWEEPS, BECAUSE THEY EXCLUDE DIFFERENT THINGS
// -------------------------------------------------
// 1. NEGATION. Every `ck` in the suite is rewritten to `ck not (...)`, one at a
//    time, and must go red. An assertion that is never reached — a case that
//    returned early, a loop that ran zero times — survives its own negation,
//    and so does one whose condition is true of every input. This is the
//    vacuity `Journey.subjects()` and `countIs` exist for in the journey layer,
//    made mechanical.
//
//    It does NOT prove the suite has anything to do with the product. A file
//    full of `ck 1 == 1` … `ck 1 == 2` would score a clean sweep.
//
// 2. PRODUCT ARMS. A defect planted in `session_view.selectionDetail` itself
//    must be reported, and reported BY THE CASE WRITTEN FOR IT. "Some test went
//    red" is satisfied by a mutation that broke a different claim.
//
//    It does not prove the individual assertions inside a killing case are all
//    doing work. Sweep 1 does that. Neither is redundant.
//
// THREE VERDICTS, NEVER TWO — the same rule as the journey selftest. A mutated
// tree that does not COMPILE has demonstrated nothing, and a Nim compile error
// and a red suite exit with the same number. The verdict is taken from whether
// the runner printed the named case, never from an exit code.
//
// Measured on `dev` at the time of writing: 79 negations, 79 killed; 17 product
// arms, 17 killed.

import { readFile, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const run = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url)); // <repo>/client/tests
const CLIENT = resolve(HERE, "..");
const SUITE = join(HERE, "test_selection_detail.nim");
const SUBJECT = join(CLIENT, "src", "debugger", "session_view.nim");

const log = (s = "") => console.log(s);

/**
 * The product arms.
 *
 * `find` must occur EXACTLY ONCE in the file — asserted before the edit. A
 * mutation applied twice, or to a line that has moved, is a different
 * experiment from the one described here, and a `replaceAll` would hide that.
 */
const ARMS = [
  {
    id: "P4/the-position-fallback-is-removed",
    why:
      "The journey arm that was dead, as a mutation of the same source. On a" +
      " hydrated session `CallFrame.current` is never set, so without the fallback" +
      " the panel falls through to `selNone` with every frame on screen beside it.",
    find: `  if chosen < 0 and v.controls.positioned:
    for i, f in v.calltrace.frames:
      if f.step > 0 and f.step <= v.controls.step: chosen = i`,
    replace: `  if false:
    discard`,
    case: "frames drawn, none marked, a real position — the panel is a FRAME",
  },
  {
    id: "the-heading-says-Selected-instead-of-Current",
    why:
      "A panel that showed the POSITION under the word 'Selected' would report a" +
      " click that never happened. `kind` cannot see this and neither can the facts.",
    find: `    result.heading = "Current frame"`,
    replace: `    result.heading = "Selected frame"`,
    case: "frames drawn, none marked, a real position — the panel is a FRAME",
  },
  {
    id: "the-subject-is-left-empty",
    why:
      "`kind` stays `selFrame` and every fact is present; the section just leads" +
      " with nothing. This is half of the reading the P4 defect produces.",
    find: `    result.subject = f.fn`,
    replace: `    result.subject = ""`,
    case: "frames drawn, none marked, a real position — the panel is a FRAME",
  },
  {
    id: "the-function-is-never-named",
    why: "The one fact journey 14's live assertion looks for.",
    find: `    result.facts.add selectionFact("Function", f.fn, identifier = true)`,
    replace: `    discard f.fn`,
    case: "frames drawn, none marked, a real position — the panel is a FRAME",
  },
  {
    id: "the-function-row-stops-being-a-machine-value",
    why:
      "`identifier` is what renders it mono. A `hasFact` check alone survives" +
      " this, which is why the suite asserts the flag as well as the row.",
    find: `    result.facts.add selectionFact("Function", f.fn, identifier = true)`,
    replace: `    result.facts.add selectionFact("Function", f.fn)`,
    case: "frames drawn, none marked, a real position — the panel is a FRAME",
  },
  {
    id: "the-FIRST-frame-at-or-before-the-position-wins",
    why:
      "Off by a frame: the OUTERMOST frame that has started rather than the one" +
      " the session is in. Both are 'a frame that started before the position'," +
      " and on a recursion trace they are two frames of the same function — so" +
      " `fn` and `Source` cannot tell them apart and only the step can.",
    find: `      if f.step > 0 and f.step <= v.controls.step: chosen = i`,
    replace: `      if f.step > 0 and f.step <= v.controls.step and chosen < 0: chosen = i`,
    case: "a position exactly ON a frame's first step selects THAT frame",
  },
  {
    id: "a-frames-own-first-step-is-attributed-to-its-caller",
    why: "`<` for `<=`. Wrong by one step, at exactly the boundary.",
    find: `      if f.step > 0 and f.step <= v.controls.step: chosen = i`,
    replace: `      if f.step > 0 and f.step < v.controls.step: chosen = i`,
    case: "a position exactly ON a frame's first step selects THAT frame",
  },
  {
    id: "the-explicit-mark-is-ignored",
    why:
      "The statically exported page's producer DOES mark a frame. Dropping the" +
      " mark leaves the fallback, which lands somewhere else — a click the page" +
      " can represent, overridden by where the session stands.",
    find: `  for i, f in v.calltrace.frames:
    if f.current:
      chosen = i
      break`,
    replace: `  for i, f in v.calltrace.frames:
    if false:
      chosen = i
      break`,
    case: "an explicitly marked frame WINS over the position — the served shape",
  },
  {
    id: "the-step-that-tells-two-frames-apart-is-dropped",
    why:
      "`fn`, `line` and `Source` are identical across two frames of one function" +
      " — both producers give the frame's SOURCE location and a function is" +
      " declared once. Without the step the panel cannot say which one it means.",
    find: `      result.facts.add selectionFact("Starts at step", groupDigits(f.step))`,
    replace: `      discard f.step`,
    case: "both positions name the function, and the readings differ by step",
  },
  {
    id: "the-step-is-printed-ungrouped",
    why: "A figure the reader only READS is grouped; one they will COPY is not.",
    find: `      result.facts.add selectionFact("Starts at step", groupDigits(f.step))`,
    replace: `      result.facts.add selectionFact("Starts at step", $f.step)`,
    case: "a frame's step is grouped for reading, like every other read-only count",
  },
  {
    id: "the-panel-drops-the-path-the-row-no-longer-paints",
    why:
      "Journey 14's arm P3, as a unit claim. `renderCallTrace` gave the row's" +
      " whole text width to `fn` on the promise that the panel holds the path.",
    find: `      result.facts.add selectionFact("Source", where, identifier = true)`,
    replace: `      discard where`,
    case: "the path the row no longer paints is stated here",
  },
  {
    id: "a-frame-with-no-path-states-an-empty-one",
    why:
      "`where.len > 0` is what keeps a rung-3 frame — an Aztec contract class" +
      " publishes no debug symbols — from claiming a source location it has not got.",
    find: `    let where = frameWhere(f)
    if where.len > 0:`,
    replace: `    let where = frameWhere(f)
    if true:`,
    case: "a frame with no module and no line states no path at all",
  },
  {
    id: "the-empty-panel-loses-its-heading",
    why:
      "The reading the P4 defect produces has to be distinguishable BY VALUE from" +
      " the frame reading, or the two are one verdict and the suite cannot say" +
      " which of them it saw.",
    find: `  result.heading = "Selection"`,
    replace: `  result.heading = ""`,
    case: "frames drawn, none marked, NO position — kind none, and it explains why",
  },
  {
    id: "the-two-absences-are-described-by-one-sentence",
    why:
      "'no position yet' and 'no row selected' are different facts about the" +
      " session, and a section that renders empty is indistinguishable from a" +
      " broken one.",
    find: `    if not v.hasFrame:`,
    replace: `    if true:`,
    case: "frames drawn, none marked, NO position — kind none, and it explains why",
  },
  {
    id: "step-0-is-treated-as-no-position-again",
    why:
      "The sentinel colliding with a valid value, restored in the line branch." +
      " Step 0 is the first step of the trace, and suppressing its readout told" +
      " the visitor the session had no position when it had the first one.",
    find: `    if v.controls.positioned:
      result.facts.add selectionFact("Step", groupDigits(v.controls.step))`,
    replace: `    if v.controls.positioned and v.controls.step > 0:
      result.facts.add selectionFact("Step", groupDigits(v.controls.step))`,
    case: "step 0 IS a position, so `positioned` and not the step decides",
  },
  {
    id: "an-event-that-is-not-current-becomes-the-subject",
    why:
      "`r.current` is the whole of what makes the event branch describe the" +
      " SESSION rather than the first row in the log.",
    find: `    if not r.current: continue`,
    replace: `    if false: continue`,
    case: "with no frames and no CURRENT event, the line is the subject",
  },
  {
    id: "a-listing-row-is-labelled-Source",
    why:
      "A rung-3 row is a program counter, an opcode and a gas reading. Calling it" +
      " Source claims debug symbols the recording has not got.",
    find: `          (if v.editor.listingCaption.len > 0: "Instruction" else: "Source"),`,
    replace: `          "Source",`,
    case: "a listing pane labels the row an Instruction, not a Source line",
  },
];

// ── running the suite ───────────────────────────────────────────────────────

async function suiteRun() {
  try {
    const { stdout } = await run(
      "nim",
      ["c", "-r", "--mm:orc", "--hints:off", "tests/test_selection_detail.nim"],
      { cwd: CLIENT, maxBuffer: 64 * 1024 * 1024 },
    );
    return { built: true, out: stdout };
  } catch (err) {
    const out = String(err.stdout ?? "") + String(err.stderr ?? "");
    // THE THIRD VERDICT. A Nim compile error and a red suite both exit
    // non-zero; they are told apart by whether the runner printed any case at
    // all, never by the number.
    return { built: out.includes("[Suite]"), out };
  }
}

/** Did THAT case pass? Taken from the runner's own per-case lines. */
const caseVerdict = (out, name) => {
  const ok = out.includes(`  [OK] ${name}`);
  const bad = out.includes(`  [FAILED] ${name}`);
  if (ok === bad) return { found: false }; // absent, or renamed, or ambiguous
  return { found: true, ok };
};

/**
 * `ck X` -> `ck not (X)` on one line.
 *
 * A trailing `# comment` stays OUTSIDE the parentheses. Nim does not care where
 * a comment sits, but a comment swallowed into the expression takes the closing
 * paren onto the next line and the file stops compiling — which is a NEVER RAN
 * dressed as a survival, and the first draft of this sweep reported four.
 */
function negateLine(line) {
  const indent = line.slice(0, line.length - line.trimStart().length);
  const body = line.trimStart();
  if (!body.startsWith("ck ")) return null;
  let cond = body.slice(3);
  let comment = "";
  let depth = 0;
  let inStr = false;
  for (let i = 0; i < cond.length; i += 1) {
    const c = cond[i];
    if (c === '"') inStr = !inStr;
    else if (inStr) continue;
    else if (c === "(" || c === "[") depth += 1;
    else if (c === ")" || c === "]") depth -= 1;
    else if (c === "#" && depth === 0 && i > 0 && cond[i - 1] === " ") {
      comment = "   " + cond.slice(i);
      cond = cond.slice(0, i);
      break;
    }
  }
  return `${indent}ck not (${cond.trimEnd()})${comment}`;
}

// ── sweep 1: every assertion can fail ───────────────────────────────────────

async function negationSweep() {
  log("=== sweep 1 — can every assertion in the suite FAIL? ===");
  log("    Each `ck` is negated in turn and must go red. One that is never");
  log("    reached, or whose condition is true of every input, survives.");
  log("");
  const original = await readFile(SUITE, "utf8");
  const lines = original.split("\n");
  const targets = [];
  lines.forEach((l, i) => {
    if (/^\s*ck /.test(l)) targets.push(i);
  });
  if (targets.length === 0) {
    log("RESULT: DID NOT RUN — no `ck ` lines found; has the suite been renamed?");
    return { ok: false, total: 0 };
  }
  let killed = 0;
  const survived = [];
  try {
    for (const i of targets) {
      const mutated = lines.slice();
      mutated[i] = negateLine(lines[i]);
      await writeFile(SUITE, mutated.join("\n"));
      const r = await suiteRun();
      if (r.built && r.out.includes("[FAILED]")) killed += 1;
      else {
        survived.push({
          line: i + 1,
          text: lines[i].trim(),
          why: r.built ? "still GREEN with the assertion inverted" : "did not compile",
        });
      }
    }
  } finally {
    await writeFile(SUITE, original);
  }
  log(`  ${targets.length} negations: ${killed} killed, ${survived.length} survived`);
  for (const s of survived) log(`    SURVIVED  line ${s.line}  ${s.text}   (${s.why})`);
  log("");
  return { ok: survived.length === 0, total: targets.length };
}

// ── sweep 2: the suite bites the product ────────────────────────────────────

async function productSweep() {
  log("=== sweep 2 — does a defect in `selectionDetail` reach the suite? ===");
  log("    One mutation per arm, in real product source, each aimed at ONE case.");
  log("    An arm passes only if THAT case flips, and only if it was green");
  log("    before and is green again after.");
  log("");
  const original = await readFile(SUBJECT, "utf8");
  const base = await suiteRun();
  if (!base.built) {
    log("  the unmutated tree does not build; nothing below would mean anything");
    log(base.out.split("\n").slice(-4).join("\n"));
    return { ok: false, killed: 0 };
  }
  if (base.out.includes("[FAILED]")) {
    log("  the suite is RED unmutated, so no mutation below can demonstrate anything");
    return { ok: false, killed: 0 };
  }

  let killed = 0;
  const notKilled = [];
  for (const arm of ARMS) {
    log(`--- ${arm.id}`);
    log(`    ${arm.why}`);
    log(`    target: "${arm.case}"`);
    const occurrences = original.split(arm.find).length - 1;
    if (occurrences !== 1) {
      log(`    NEVER RAN — the mutation site occurs ${occurrences} times, expected exactly 1`);
      log(`               (the source moved; this arm describes code that is no longer there)`);
      notKilled.push([arm.id, "never"]);
      log("");
      continue;
    }
    const before = caseVerdict(base.out, arm.case);
    if (!before.found || !before.ok) {
      log(`    NEVER RAN — that case is ${before.found ? "already RED" : "not present"} unmutated`);
      notKilled.push([arm.id, "never"]);
      log("");
      continue;
    }
    let verdict;
    try {
      await writeFile(SUBJECT, original.split(arm.find).join(arm.replace));
      const r = await suiteRun();
      if (!r.built) {
        const err = r.out.split("\n").filter((l) => l.includes("Error:")).slice(-1)[0] ?? "";
        log(`    NEVER RAN — the mutated tree did not compile, so nothing was measured`);
        log(`               ${err.trim()}`);
        verdict = "never";
      } else {
        const after = caseVerdict(r.out, arm.case);
        if (!after.found) {
          log(`    NEVER RAN — that case vanished from the mutated run`);
          verdict = "never";
        } else if (after.ok) {
          log(`    SURVIVED — the case is still GREEN with the defect in place`);
          verdict = "survived";
        } else {
          // The COUNT has to survive too. A mutation that shortens the run —
          // an exception part-way through a case — reddens it without any
          // assertion having judged anything, and would read as a kill.
          const counted = r.out.includes("[OK] assertion count");
          log(`    KILLED   — the named case went red` +
              (counted ? "" : "   (but the assertion COUNT moved: investigate)"));
          verdict = counted ? "killed" : "never";
        }
      }
    } finally {
      // Byte-for-byte, whatever happened above.
      await writeFile(SUBJECT, original);
    }
    // And prove the restore took. Without this a mutation that failed to apply
    // is indistinguishable from one that was killed.
    const back = await suiteRun();
    const b = caseVerdict(back.out, arm.case);
    if (!back.built || !b.found || !b.ok) {
      log(`    NEVER RAN — the case did not come back green after restoring, so the red`);
      log(`               above cannot be attributed to the mutation`);
      verdict = "never";
    }
    if (verdict === "killed") killed += 1;
    else notKilled.push([arm.id, verdict]);
    log("");
  }
  log(`  ${ARMS.length} arm(s): ${killed} killed, ` +
      `${notKilled.filter(([, v]) => v === "survived").length} survived, ` +
      `${notKilled.filter(([, v]) => v === "never").length} never ran`);
  for (const [id, v] of notKilled) log(`    ${v === "survived" ? "SURVIVED " : "NEVER RAN"}  ${id}`);
  log("");
  return { ok: notKilled.length === 0, killed };
}

// ── main ────────────────────────────────────────────────────────────────────

async function main() {
  const a = await negationSweep();
  const b = await productSweep();
  if (a.ok && b.ok) {
    log("  Every assertion can fail, and every planted defect is reported by the");
    log("  case written for it.");
    log("RESULT: OK");
    return;
  }
  log("RESULT: FAILED — the suite does not bite everywhere it claims to");
  process.exitCode = 1;
}

main().catch((e) => {
  console.error(String(e && e.stack ? e.stack : e));
  // A verdict, never just a stack: a run that threw judged nothing, and saying
  // so is the difference between a failure and a suite nobody ran.
  log("RESULT: DID NOT RUN — the sweep threw; check that both files are restored");
  process.exitCode = 2;
});
