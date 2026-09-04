#!/usr/bin/env node
// Author the FIXTURE CONTAINER that carries a Noir call tree, so this repository
// can develop and test the folded Call Trace against a real `.ct` rather than
// against a hand-written JSON that only claims to be one.
//
// ── Why a fixture exists at all, said before anything else ───────────────────
//
// `aztec-avm-runtime@26cac14` taught both AVM recorders to open a Noir frame at
// every function boundary. The transaction this repository publishes —
// testnet 0x20ed5b91… — CANNOT BE RE-RECORDED: the node serves transaction
// bodies only out of its active pool, for about an hour, and that hour is long
// gone. So the container the capture held for it was the one the OLD recorder
// wrote, and it held two frames.
//
// This tool writes the container the NEW recorder would have written for that
// same execution, out of the same parts the new recorder uses.
//
// AND THAT CONTAINER IS NOW THE PUBLISHED ONE. `client/fixtures/chain/aztec-testnet`
// carries this tool's output for `0x20ed5b91…`, with the row naming its recorder
// in `transactions[].recordedBy` so `ingest.nim` files it under the build that
// produced it and leaves the other twenty-four containers at the addresses the
// old build's `provenance.runtimeCommit` derives. The copy under
// `client/fixtures/noir-frames/` is kept as the provenance record and as the
// fold suites' subject; it is the same bytes.
//
// ── What is measured and what is not. THE DISTINCTION IS THE FIXTURE. ────────
//
// MEASURED — not authored here, and not authored in this repository at all:
//
//   * the frame tree. `ContractSourceMap.framesFor` and `NoirFrameTracker`,
//     imported from an aztec-avm-runtime checkout and RUN, not re-implemented.
//     The same two modules both real recorders drive.
//   * the artifact behind it: `@aztec/protocol-contracts@5.3.0-nightly.20260819`
//     FeeJuice, the version the published snapshot resolved against. Its
//     `brillig_locations`, `location_tree` and `file_map` are upstream's bytes.
//   * the step stream's positions — 108 `(pathId, line)` pairs decoded out of
//     the PUBLISHED container and carried in that repository's tracked fixture
//     `replay/fixtures/published_snapshot_step_positions.json`.
//   * the interned path table's first twelve entries, in the published
//     container's own order, so a path id means here what it means there.
//   * the container bytes themselves: written by the REAL `CtWriter` driving the
//     REAL `aztec_ct_writer.wasm`. `ct-print` reads this file the same way it
//     reads a recorded one because it IS one.
//
// RECONSTRUCTED, under a rule aztec-avm-runtime states and asserts:
//
//   * the program counters of the 86 positioned steps. The container records
//     the innermost `(path, line)` and not the pc, and that is lossy. The rule
//     is "smallest candidate pc greater than the previous one", and
//     `test_noir_frames_open_at_function_boundaries` §2 asserts it is
//     over-determined: it lands on the 22 exact pcs it was never given.
//
// NOT MEASURED, AND DELIBERATELY WRITTEN AS ZERO:
//
//   * every per-step AVM register — `contextId`, `opcode`, `l2Gas`, `daGas`,
//     `contractAddress`. The published fixture does not carry them and this tool
//     will not invent them. They are written as zeros because a zero is VISIBLY
//     not a measurement, where a plausible gas figure would read as one. Nothing
//     in the call-trace path reads them; `derive-calltrace.mjs` counts `Step`
//     events and reads `Call`/`Function`/`Path`, and none of those is affected.
//
// A fixture that blurred those three categories would be worse than no fixture,
// which is why they are named here and restated in the provenance file written
// beside the container.
//
// ── Standing ────────────────────────────────────────────────────────────────
//
// The same standing as `derive-calltrace.mjs` and `derive-instructions.mjs`: NOT
// part of any build and not part of `just test`, needs a checkout this build
// does not have, run BY HAND, output committed. The site build stays hermetic.
//
// Needs node >= 22 (it imports TypeScript directly, as aztec-avm-runtime's own
// tools do) and an aztec-avm-runtime worktree at 26cac14 or later whose
// `ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm` has
// been built (`just ct-writer-build`).
//
// Usage:
//   node tools/chain/record-noir-frames-fixture.mjs \
//     --avm-runtime ../aztec-avm-runtime \
//     --artifact <path>/@aztec/protocol-contracts/artifacts/FeeJuice.json \
//     --out client/fixtures/chain/aztec-testnet-noirframes

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { inflateRawSync } from 'node:zlib';
import { join, resolve } from 'node:path';
import process from 'node:process';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(name);
  if (i < 0) {
    if (fallback === undefined) throw new Error(`missing required ${name}`);
    return fallback;
  }
  return argv[i + 1];
};

const AVM = resolve(arg('--avm-runtime'));
const ARTIFACT = resolve(arg('--artifact'));
const OUT = resolve(arg('--out'));

const {
  ContractSourceMap,
  NoirFrameTracker,
  CtWriter,
  resolveTracingConfig,
  WRITER_PATH_A_PURE_RUST,
  RUNG_SOURCE,
} = await import(join(AVM, 'ct-host/src/index.ts'));

// ---------------------------------------------------------------------------
// The artifact, and the source map over it — the arms tool's own setup
// ---------------------------------------------------------------------------
const artifact = JSON.parse(readFileSync(ARTIFACT, 'utf8'));
const dispatch = artifact.functions.find((f) => f.name === 'public_dispatch');
if (!dispatch) throw new Error(`${ARTIFACT} has no public_dispatch function`);
const bytecode = Buffer.from(dispatch.bytecode, 'base64');
const debugInfo = JSON.parse(
  inflateRawSync(Buffer.from(dispatch.debug_symbols, 'base64')).toString('utf8'),
).debug_infos[0];

const files = new Map();
for (const [id, entry] of Object.entries(artifact.file_map ?? {})) {
  files.set(Number(id), {
    path: entry.path,
    source: entry.source,
    functionLocations: entry.function_locations ?? [],
  });
}

const SNAPSHOT = join(AVM, 'replay/fixtures/published_snapshot_step_positions.json');
const snapshot = JSON.parse(readFileSync(SNAPSHOT, 'utf8'));
const containerPaths = snapshot.paths;
const steps = snapshot.steps;
const tx = snapshot.provenance.tx;

// ---------------------------------------------------------------------------
// The writer. Opened BEFORE the source map, because the source map interns
// through it: a frame's `pathId` is the WRITER's id, which is the whole point —
// the view resolves it back through the container's own `Path` table.
// ---------------------------------------------------------------------------
const wasmPath = join(AVM, 'ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm');
const { instance } = await WebAssembly.instantiate(readFileSync(wasmPath), {});

// `meta.dat` requires a 36-character UUID and refuses anything else — the tx
// hash is 66 and `ct-print` will not open a container carrying it. Derived from
// the tx hash rather than generated so a re-run of this tool produces the same
// container: a fixture whose bytes changed on every regeneration would make
// every provenance hash beside it a moving target.
// It must also be a UUID**v7** specifically: `meta.dat` checks the version
// nibble and the variant, so the two fixed nibbles are set and the rest is the
// tx hash's own digits.
const h = tx.replace(/^0x/, '');
const recordingId = [
  h.slice(0, 8),
  h.slice(8, 12),
  '7' + h.slice(13, 16),
  '8' + h.slice(17, 20),
  h.slice(20, 32),
].join('-');

const cfg = resolveTracingConfig({
  program: 'aztec-live-chain-replay',
  recordingId,
  sourcePath: `/aztec/${tx}.avm`,
  workdir: '/aztec',
  columns: false,
  mappingRung: RUNG_SOURCE,
}, WRITER_PATH_A_PURE_RUST);

const writer = new CtWriter(instance, cfg);

// THE PUBLISHED CONTAINER'S PATH TABLE, IN ITS ORDER, INTERNED FIRST. Index 0 is
// the pseudo-path the recorder files unplaceable coordinates under, and the
// eleven after it are the real Noir files the published container already
// carries. Interning them in that order is what makes a path id here mean what
// it means there, so the step positions can be written back verbatim rather than
// remapped. The frame tree reaches files the STEP stream never lands in — a
// function's declaration line is in a file the execution only passes through —
// and those get fresh ids after these twelve, exactly as a real recording would.
for (const p of containerPaths) writer.internPath(p);

const pathById = new Map();
const idByPath = new Map();
for (let i = 0; i < containerPaths.length; i++) {
  idByPath.set(containerPaths[i], i);
  pathById.set(i, containerPaths[i]);
}
const intern = (p) => {
  let id = idByPath.get(p);
  if (id === undefined) {
    id = writer.internPath(p);
    idByPath.set(p, id);
    pathById.set(id, p);
  }
  return id;
};

const map = new ContractSourceMap(debugInfo, bytecode.length, files, intern);

// ---------------------------------------------------------------------------
// The pc reconstruction — aztec-avm-runtime's stated rule, restated in full at
// the head of this file. Straight-line execution: the smallest candidate pc
// greater than the previous one.
// ---------------------------------------------------------------------------
const keyedPcs = Object.keys(debugInfo.brillig_locations['0']).map(Number).sort((a, b) => a - b);
const chainByPc = new Map();
for (const pc of keyedPcs) {
  const fr = map.framesFor(pc);
  if (fr !== null) chainByPc.set(pc, fr);
}

const byInner = new Map();
for (const [pc, fr] of chainByPc) {
  const last = fr[fr.length - 1];
  const key = `${pathById.get(last.pathId)}#${last.line}`;
  if (!byInner.has(key)) byInner.set(key, []);
  byInner.get(key).push(pc);
}
for (const v of byInner.values()) v.sort((a, b) => a - b);

let prev = -1;
const reconstructed = [];
for (const [pathIdx, line] of steps) {
  if (pathIdx === 0) { reconstructed.push(line); prev = line; continue; }
  const cands = byInner.get(`${containerPaths[pathIdx]}#${line}`) ?? [];
  if (cands.length === 0) { reconstructed.push(null); continue; }
  const fwd = cands.filter((c) => c > prev);
  const pick = fwd.length > 0 ? fwd[0] : cands[0];
  reconstructed.push(pick);
  prev = pick;
}

// ---------------------------------------------------------------------------
// The recording
// ---------------------------------------------------------------------------
// THE AVM FRAMES STAY. `<toplevel>` and `enqueued-call-0` are what the published
// container holds and what the Call Trace pane has always shown; the Noir tree
// nests INSIDE the enqueued call rather than replacing it. A fixture that
// dropped them would be testing a different pane.
//
// ONLY ONE OF THEM IS OPENED HERE, AND THAT WAS MEASURED RATHER THAN ASSUMED.
// `<toplevel>` is SYNTHETIC: the trace writer emits it on open, and it is not
// counted by `ct_calls_opened()`. Opening it explicitly produced a container
// with 47 `Call` records against 46 frames opened — one duplicate `<toplevel>` —
// which is also why the published container reads `callsOpened: 1` beside two
// `Call` records, and why `ingest.nim`'s refusal is `calls == callsOpened + 1`.
writer.call('enqueued-call-0');

const ZERO_ADDRESS = new Uint8Array(32);

// The tracker drives the WRITER through a sink that only counts on the way past.
// The counts are the tracker's own — `framesOpened`, `deepest`, `functionNames`
// — and are read back off it below rather than tallied here, so this file has no
// second opinion about how many frames it wrote.
const tracker = new NoirFrameTracker({
  call: (name, opts) => writer.call(name, opts),
  returnFrame: () => writer.returnFrame(),
});

for (let i = 0; i < reconstructed.length; i++) {
  const pc = reconstructed[i];
  tracker.step(pc === null ? null : (chainByPc.get(pc) ?? null));
  const [pathIdx, line] = steps[i];
  // EVERY AVM REGISTER IS ZERO AND THAT IS THE FIXTURE'S OWN DECLARATION, not
  // an oversight — see the header. The POSITION is the measurement, and an
  // unpositioned step keeps the published container's own spelling of "no
  // position": `pathId 0`, with the pc in `line`.
  writer.push({
    contextId: 0, pc: 0, opcode: 0, l2Gas: 0n, daGas: 0n, contractAddress: ZERO_ADDRESS,
  }, { pathId: pathIdx, line, column: 0 });
}

tracker.closeAll();
// The enqueued call closes; `<toplevel>` is left open, which is what the
// published container does — 2 `Call` records and 1 `Return`.
writer.returnFrame();

const rec = writer.close();

mkdirSync(join(OUT, 'ct'), { recursive: true });
const ctPath = join(OUT, 'ct', `${tx}.ct`);
writeFileSync(ctPath, rec.container);

const provenance = {
  format: 'noir-frames-fixture-container/1',
  tx,
  container: {
    file: `ct/${tx}.ct`,
    bytes: rec.container.length,
    sha1: 'sha1:' + createHash('sha1').update(rec.container).digest('hex'),
  },
  measured: {
    frameLogic: 'aztec-avm-runtime ct-host/src/{source_map,noir_frames}.ts, imported and RUN',
    artifact: 'npm:@aztec/protocol-contracts@5.3.0-nightly.20260819 FeeJuice',
    stepPositions: 'aztec-avm-runtime replay/fixtures/published_snapshot_step_positions.json, '
      + 'decoded from the published container',
    pathTable: "the published container's twelve interned paths, in its own order, then the "
      + 'files only the frame tree reaches',
    containerBytes: 'the real CtWriter driving the real aztec_ct_writer.wasm',
  },
  reconstructed: {
    programCounters: 'the 86 positioned steps, under the smallest-candidate-greater-than-previous '
      + 'rule aztec-avm-runtime states and asserts is over-determined',
  },
  notMeasured: {
    perStepAvmRegisters: 'contextId, pc, opcode, l2Gas, daGas and contractAddress are written as '
      + 'ZERO. The published fixture does not carry them and this tool does not invent them. '
      + 'Nothing in the call-trace path reads them.',
  },
  recording: {
    steps: reconstructed.length,
    callsOpened: rec.callsOpened,
    noirFramesOpened: tracker.framesOpened,
    noirMaxDepth: tracker.deepest,
    distinctNoirFunctions: tracker.functionNames.size,
    pathsInterned: rec.pathsInterned,
  },
};
writeFileSync(join(OUT, 'provenance.json'), JSON.stringify(provenance, null, 1) + '\n');

console.log(JSON.stringify({ wrote: ctPath, ...provenance.recording }, null, 1));
