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
        cur = { pc: PC_OF(e), v: {} };
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
  const steps = streamOf(events);

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

  const payload = {
    schema: "avm-instructions/1",
    tx: txHash,
    isa: "aztec-avm",
    // The path the RECORDER interned for the executed object. Published so a reader
    // can tell that the coordinate below is an offset into that object and not a
    // line in a file — see `instruction_listing.nim`, which never displays it as one.
    path: paths[0] ?? "",
    steps: steps.length,
    pc: steps.map((s) => s.pc),
    op: column(steps, "opcode"),
    l2: column(steps, "l2Gas"),
    ctx: column(steps, "contextId"),
  };
  if (payload.op === null) {
    throw new Error(`${txHash}: no per-step opcode in this recording`);
  }
  writeFileSync(join(outDir, `${txHash}.json`), JSON.stringify(payload) + "\n");
  written += 1;
  console.error(
    `derive-instructions: ${txHash.slice(0, 10)}… ${steps.length} steps, ` +
      `pc 0..${Math.max(...payload.pc)}, ` +
      `${new Set(payload.op).size} distinct opcodes`,
  );
}

console.error(`derive-instructions: wrote ${written} listing(s) to ${outDir}`);
