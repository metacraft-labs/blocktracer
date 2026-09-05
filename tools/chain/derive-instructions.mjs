#!/usr/bin/env node
//
// derive-instructions.mjs — the INSTRUCTION STREAM of a captured chain recording,
// lifted out of its `.ct` container and written beside it so the static export can
// render a listing.
//
// ## Why this exists
//
// A real chain recording on this site is rung 3: the Aztec node serves
// `ContractClassPublic` and that object carries packed bytecode and no debug
// symbols, no file map and no source text, so nothing positions a step against a
// line. What the recording DOES carry, for every step, is the coordinate the VM
// actually had — a program counter — plus the opcode the VM was about to run and
// the gas meter's reading. Before this tool none of that reached a page: the Code
// pane described an instruction-level recording in prose and then rendered no
// instructions, on the only transactions this site publishes from a real chain.
//
// ## Why it is a separate, committed derivation and not part of the build
//
// Same argument as `client/fixtures/demo-session/extract-flow.mjs`, and the same
// shape. Reading a `.ct` needs `ct-print`, which is `codetracer-trace-format-nim`'s
// reader and is NOT a dependency of this repository — the site build is hermetic and
// has no network, and the containers are vendored precisely because recording is not
// byte-deterministic. So the derivation runs by hand, its output is committed beside
// the container it was derived from, and `ingest.nim` publishes whatever it finds.
//
// A snapshot with no `instructions/` directory is a VALID input and not a broken
// one: the pane falls back to the prose it has always shown. That is the honest
// degradation, and it is the same shape as `client/hydrate/build.sh` exit 3.
//
//     CT_PRINT=../codetracer-trace-format-nim/ct-print \
//       node tools/chain/derive-instructions.mjs client/fixtures/chain/aztec
//
// ## What is written, and what is deliberately not
//
// Per step: the program counter, the opcode NUMBER, the cumulative L2 gas, and the
// context id. Four facts the recorder wrote, republished verbatim.
//
// THE PROGRAM COUNTER IS THE ONLY SPARSE ONE, and a recording exists in which it is
// sparse. `aztec-testnet-frames/0x0a807e4e…` runs 459 steps across two contracts at
// two fidelities: the 86 steps this container could position spend their `line`
// field on the source line, so they have no counter to publish, and the other 373 —
// a contract whose artifact no distributor could prove — carry a real one. The op,
// gas and context columns are complete on all 459 (`REGISTERS.md` measured them), so
// only `pc` has holes, and a hole is written as `NoProgramCounter` rather than as a
// null or as the line number. See its declaration, and `Source-Resolution.md` §7.
//
// The opcode MNEMONIC is not written here, and that is the load-bearing decision.
// A name is an interpretation of a number against a version of the instruction set,
// and this file has no way to check one — so the number travels, the table lives in
// `client/src/debugger/avm_opcodes.nim` beside the check that has to pass before any
// name is rendered, and a recording the table cannot explain renders numbers. Baking
// names in here would move the claim to the one place nothing can falsify it.
//
// The contract address is not written either: it is already the transaction's own
// published fact and a second copy per step would be a second producer of it.

import { execFile } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";

const run = promisify(execFile);

// ---------------------------------------------------------------------------
// ct-print
// ---------------------------------------------------------------------------

/** `$CT_PRINT`, or a sibling checkout's built binary. Refuses loudly rather than
 *  writing a half-derived tree: a snapshot with SOME transactions listed is worse
 *  than one with none, because the pane cannot tell "not derived" from "the
 *  recording genuinely has no steps". */
function findCtPrint() {
  const explicit = process.env.CT_PRINT;
  if (explicit) {
    if (!existsSync(explicit)) {
      throw new Error(`CT_PRINT=${explicit} does not exist`);
    }
    return explicit;
  }
  const here = dirname(new URL(import.meta.url).pathname);
  for (const up of ["../../..", "../../../.."]) {
    const guess = resolve(here, up, "codetracer-trace-format-nim", "ct-print");
    if (existsSync(guess)) return guess;
  }
  throw new Error(
    "ct-print not found. Build it in a codetracer-trace-format-nim checkout " +
      "(`nimble buildCtPrint`) and pass CT_PRINT=<path>.",
  );
}

// ---------------------------------------------------------------------------
// the step stream
// ---------------------------------------------------------------------------

// The five names the Aztec replay recorder writes per step. They are the recorder's
// spelling and are matched by name rather than by variable id, because ids are
// assigned in first-seen order and a recording that never emitted one of these would
// silently shift every later id by one.
const PC_OF = (e) => e.line;

/** The `pc` column's value for a step that HAS a source position.
 *
 *  `-1` and not `null`: the column is read by `instruction_listing.intColumn`, which
 *  discards a column holding anything but integers, and a null would take the whole
 *  listing down with it. It is impossible as a bytecode offset — offsets are
 *  non-negative by construction — so nothing can mistake it for one, and every
 *  consumer that would do arithmetic on it (`hexWidth`, `destinationSuffix`,
 *  `explainsProgramCounters`) tests for it by name.
 *
 *  It is NOT "the program counter is unknown here". It is "this step spent the field
 *  on a source line, so there is no counter to publish and the source pane has the
 *  row instead" — which is the whole content of a partly-positioned recording. */
const NoProgramCounter = -1;

/** One container's steps, as parallel columns.
 *
 *  The `.ct` event stream is a flat sequence: a `Step` opens a step and the `Value`
 *  events after it are that step's snapshot, keyed by the `VariableName` events that
 *  introduced each id. Values before the first `Step` belong to the call frame, not
 *  to a step, and are dropped. */
function streamOf(events) {
  const names = [];
  const steps = [];
  let cur = null;
  for (const e of events) {
    switch (e.type) {
      case "VariableName":
        names.push(e.name);
        break;
      case "Step":
        // `PC_OF` READS `line`, AND `line` IS ONLY A PROGRAM COUNTER ON THE
        // PSEUDO-PATH. The recorder interns `/aztec/<txHash>.avm` at path id 0
        // and files an unpositionable step there with its pc in `line`; a step
        // it COULD position gets a real path id and a real source line in the
        // same field. So on a rung-2 container this function was reading Noir
        // line numbers and publishing them as program counters.
        //
        // It was not a theoretical mistake. Run against testnet 0x20ed5b91…,
        // the derived `pc` column came out
        // `[0,5,12,17,65,74,83,92,129,22,27,32,40,44,203,223,223,…]` — the
        // first fourteen are its genuine prologue pcs and everything after is
        // `main.nr:203`, `main.nr:223`. `resolve-frozen-artifacts.mjs` then
        // joined those against `brillig_locations`, matched nothing, and
        // reported the transaction as positioning zero steps — the one
        // transaction in the corpus that positions 86.
        //
        // A positioned step HAS no pc to publish: the container spent the field
        // on something better. So it gets `NoProgramCounter`, and it is the ONE
        // thing that may go in that column besides a real offset — a null or the
        // line number would both be a listing that reads as a pc and is not one.
        //
        // ── WHAT THIS USED TO DO, AND WHY REFUSING THE WHOLE CONTAINER WAS
        //    RIGHT ABOUT 86 STEPS AND WRONG ABOUT 373 ──────────────────────────
        //
        // It raised on the FIRST positioned step, and the reasoning above is
        // exactly why. What does not follow is refusing the container: a
        // recording may position some of its steps and not others, and
        // `aztec-testnet-frames/0x0a807e4e…` is the first one this tree
        // publishes — 459 steps across two contracts, of which `0x…0003`
        // positions 86 of its 108 and `0x2fcd3dd5…` positions none of its 351,
        // because no distributor could prove its artifact. 373 unpositioned in
        // all, and every one of those 373 steps DOES carry a program counter,
        // they are exactly the steps with no source line, and refusing them left
        // the page with no row of any kind to be stopped at for 373 of its 459
        // ticks. `Source-Resolution.md` §7 asks for the opposite: "Source-level
        // stepping where sources exist, instruction-level elsewhere."
        //
        // The refusal is KEPT for a container that positions EVERY step — see
        // below the loop. That one genuinely has no listing in it.
        cur = {
          pc: (e.path_id === 0 ? PC_OF(e) : NoProgramCounter),
          v: {},
        };
        steps.push(cur);
        break;
      case "Value": {
        if (cur === null) break;
        const n = names[e.variable_id];
        if (n === undefined) break;
        cur.v[n] = e.value?.i ?? e.value?.text ?? null;
        break;
      }
      default:
        break;
    }
  }
  // A CONTAINER THAT POSITIONS EVERY STEP IS STILL REFUSED, and the refusal is
  // the same one, moved from the first positioned step to the last unpositioned
  // one that never came. There is no `pc` anywhere in such a container, so the
  // listing would be 100% sentinel — a grid of dashes with an opcode column,
  // claiming to be a disassembly of an object whose offsets it does not hold.
  // What that recording has is its per-step positions, which is strictly more.
  if (steps.length > 0 && steps.every((s) => s.pc === NoProgramCounter)) {
    throw new Error(
      `this container positions ALL ${steps.length} of its steps (none is on ` +
        `the .avm pseudo-path at interned path 0), so its 'line' field carries a ` +
        `SOURCE LINE on every step and not a program counter. An instruction ` +
        `listing cannot be derived from it. Its per-step source positions are ` +
        `what it has: use tools/chain/derive-positions.mjs.`,
    );
  }
  return steps;
}

/** An integer column, or `null` when the recorder wrote no such variable.
 *
 *  A column that is present for SOME steps and absent for others is refused rather
 *  than padded: a gas reading of `0` where none was recorded is a number with no
 *  referent, and the listing would render it as a fact. */
function column(steps, name) {
  let seen = 0;
  const out = [];
  for (const s of steps) {
    const v = s.v[name];
    if (typeof v === "number") {
      seen += 1;
      out.push(v);
    } else {
      out.push(null);
    }
  }
  if (seen === 0) return null;
  if (seen !== steps.length) {
    throw new Error(
      `variable '${name}' is recorded on ${seen} of ${steps.length} steps; ` +
        `a partly-recorded column cannot be published as a per-step fact`,
    );
  }
  return out;
}

/** A METER THAT NEVER MOVED IS A METER THAT WAS NOT READ.
 *
 *  `client/fixtures/chain/aztec-testnet-frames/REGISTERS.md` draws exactly this
 *  distinction, and it is the whole point of that document: "A register that is
 *  written on every step and is sometimes 0 is not the same artefact as a
 *  register that is 0 on every step because nothing measured it." The
 *  reconstructed container behind `aztec-testnet/0x20ed5b91…` is the second
 *  thing — its own `provenance.json` says `contextId, pc, opcode, l2Gas, daGas
 *  and contractAddress are written as ZERO. The published fixture does not carry
 *  them and this tool does not invent them.`
 *
 *  `column` cannot see it: every entry is a number, so the column is "recorded"
 *  on all 108 steps. What gives it away is that the reading never CHANGES, and
 *  gas is monotonic in any execution that ran — so a constant column over a
 *  whole recording is not a measurement with a boring shape, it is the absence
 *  of one.
 *
 *  It is refused rather than published because the listing renders this column
 *  as a DIFFERENCE. A constant column renders as `0` on every row under the
 *  heading "L2 gas since the previous step", which reads as "every instruction
 *  here was free" — a per-step fact the recording never stated. `hasGas` then
 *  goes false, the column is not drawn and the caption stops naming it, which is
 *  the same honest degradation `explainsProgramCounters` applies to the opcode
 *  NAMES on this same container.
 *
 *  Deliberately NOT applied to `op` or `ctx`. `0` is a real opcode — it occurs
 *  100 times on `0x0a807e4e…` — and the table check already withdraws the
 *  mnemonics from a recording it cannot explain, so an unexplainable opcode
 *  column renders as numbers rather than taking the listing down with it. A
 *  constant context column is what a single-context recording HAS. Only the gas
 *  column is published as an arithmetic claim about each step. */
function meterMoved(col) {
  if (col === null) return false;
  return col.some((v) => v !== col[0]);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

const snapshotDir = process.argv[2];
if (!snapshotDir) {
  console.error("usage: derive-instructions.mjs <snapshot-dir>");
  console.error("  e.g. derive-instructions.mjs client/fixtures/chain/aztec");
  process.exit(2);
}

const ctPrint = findCtPrint();
const ctDir = join(snapshotDir, "ct");
if (!existsSync(ctDir)) {
  console.error(`no ct/ directory under ${snapshotDir} — nothing to derive`);
  process.exit(2);
}
const outDir = join(snapshotDir, "instructions");
mkdirSync(outDir, { recursive: true });

const snapshot = JSON.parse(await readFile(join(snapshotDir, "snapshot.json"), "utf8"));
const declared = new Map();
for (const t of snapshot.transactions ?? []) {
  if (typeof t.recording?.steps === "number") declared.set(t.txHash, t.recording.steps);
}

let written = 0;
let skipped = 0;
for (const file of readdirSync(ctDir).sort()) {
  if (!file.endsWith(".ct")) continue;
  const txHash = file.slice(0, -3);
  // `--events` and not `--full`: the full dump decodes every value in the container
  // and this needs five scalars per step. On the largest container here that is the
  // difference between 276 KB and 4 MB of intermediate JSON.
  const { stdout } = await run(ctPrint, ["--events", join(ctDir, file)], {
    maxBuffer: 1 << 30,
  });
  const events = JSON.parse(stdout);
  const paths = events.filter((e) => e.type === "Path").map((e) => e.name);
  // A FULLY POSITIONED CONTAINER IS SKIPPED, NOT FATAL. `streamOf` refuses it
  // because it cannot honestly produce a pc column at all (see its `Step` case),
  // and that refusal is right — but a snapshot may hold both kinds at once, and
  // one such recording must not stop the others from getting a listing. What it
  // gets instead is `positions/<txHash>.json`, which is strictly more than a
  // listing rather than less.
  //
  // A PARTLY positioned container is no longer in this set: it reaches the write
  // below with real counters at its unpositioned steps and `NoProgramCounter` at
  // the rest, which is what §7's "instruction-level elsewhere" needs a row for.
  let steps;
  try {
    steps = streamOf(events);
  } catch (err) {
    if (/positions ALL/.test(String(err.message))) {
      console.error(`derive-instructions: ${txHash.slice(0, 10)}… skipped — ` +
        `this recording positions its steps; derive-positions.mjs covers it`);
      skipped += 1;
      continue;
    }
    throw err;
  }

  // THE COUNT THE SNAPSHOT ALREADY PUBLISHED HAS TO AGREE. `recording.steps` is what
  // the capture measured and what the manifest publishes as `execution.steps`; the
  // listing is rendered against `totalSteps`, so a listing of a different length
  // would put the position marker on the wrong row and nothing would say so.
  const want = declared.get(txHash);
  if (want !== undefined && want !== steps.length) {
    throw new Error(
      `${txHash}: container holds ${steps.length} steps, snapshot declares ${want}`,
    );
  }

  const counters = steps.filter((s) => s.pc !== NoProgramCounter).length;
  const l2 = column(steps, "l2Gas");
  const payload = {
    // `/2` AND NOT `/1`, BECAUSE THE `pc` COLUMN'S DOMAIN CHANGED. Under `/1` every
    // entry was a bytecode offset; under `/2` an entry may be `-1`, meaning "this
    // step carries a source position instead, and the source pane holds its row".
    // That is a new obligation on every reader — the difference between a listing
    // that has a gap in it and one whose counters run from -1 — so it is a version
    // and not a field. Every `/1` payload is a valid `/2` payload that happens to
    // contain no sentinel; `instruction_listing.decodeInstructionListing` reads both
    // and refuses a version it has not been taught.
    schema: "avm-instructions/2",
    tx: txHash,
    isa: "aztec-avm",
    // The path the RECORDER interned for the executed object. Published so a reader
    // can tell that the coordinate below is an offset into that object and not a
    // line in a file — see `instruction_listing.nim`, which never displays it as one.
    path: paths[0] ?? "",
    steps: steps.length,
    // How many of `pc` are real offsets. Published rather than left to be counted,
    // for the reason the positions sidecar publishes its own: a consumer that
    // derived the number would be a second producer of it, and the caption a reader
    // sees ("N of M steps carry a program counter") is a claim this file measured.
    counters,
    pc: steps.map((s) => s.pc),
    op: column(steps, "opcode"),
    l2: meterMoved(l2) ? l2 : null,
    ctx: column(steps, "contextId"),
  };
  if (payload.op === null) {
    throw new Error(`${txHash}: no per-step opcode in this recording`);
  }
  writeFileSync(join(outDir, `${txHash}.json`), JSON.stringify(payload) + "\n");
  written += 1;
  const real = payload.pc.filter((p) => p !== NoProgramCounter);
  console.error(
    `derive-instructions: ${txHash.slice(0, 10)}… ${steps.length} steps, ` +
      `pc 0..${real.length > 0 ? Math.max(...real) : 0}` +
      (counters === steps.length
        ? ""
        : ` on ${counters} of them (${steps.length - counters} carry a source ` +
          `position instead)`) +
      `, ${new Set(payload.op).size} distinct opcodes`,
  );
}

console.error(`derive-instructions: wrote ${written} listing(s) to ${outDir}` +
  (skipped ? `, skipped ${skipped} positioned recording(s)` : ""));
