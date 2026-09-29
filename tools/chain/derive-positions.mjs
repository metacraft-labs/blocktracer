#!/usr/bin/env node
// Read the PER-STEP SOURCE POSITIONS a recording wrote into its own container,
// and publish them as `positions/<txHash>.json` beside it.
//
// ── Why this is not `resolve-frozen-artifacts.mjs` ───────────────────────────
//
// That tool answers a question the recording never asked: it takes a container
// that positioned NOTHING, joins its program counters against an artifact
// fetched today, and computes where the steps WOULD have been. Its output is
// honestly stamped `measuredPostHoc: true`, and CHAIN-CAPTURE.md §6.2b is why
// that stamp matters.
//
// This tool asks nothing. A container recorded at rung 2 or better already
// HOLDS the positions — the recording session had the proved artifact in hand
// while it ran and wrote `(path_id, line)` on every step it could place. So
// these coordinates are the recording's own measurement, `measuredPostHoc` is
// FALSE, and there is no artifact fetch, no npm, and nothing to corroborate.
// The only new thing here is that they are being read out.
//
// ── How a positioned step is told from an unpositioned one ───────────────────
//
// The container interns a synthetic pseudo-path FIRST —
// `/aztec/<txHash>.avm` — and files every step it could not place under it,
// carrying the AVM program counter in the `line` field. Every other path is a
// real source file and `line` is a real line in it. So `path_id == 0` is
// exactly "this step has no source position", and it is a structural test
// rather than a heuristic about the file's name.
//
// Measured on testnet 0x20ed5b91… (block 67011, FeeJuice): 108 steps, 86 with
// `path_id != 0` across 11 real Noir files, 22 on the pseudo-path — and the
// capture's own `recording.stepsPositioned` says 86. The two agree because
// they are the same measurement read twice.
//
// THE PSEUDO-PATH IS DROPPED FROM THE OUTPUT, not renumbered into it. A reader
// of `positions.json` gets `pathId: null` for an unpositioned step, which is
// the schema's own spelling of "no position", and never an index pointing at a
// file that does not exist. The pcs those steps carried are the instruction
// listing's business (`derive-instructions.mjs`) and are not smuggled through a
// field that means something else.
//
// Usage:
//   CT_PRINT=<path> node tools/chain/derive-positions.mjs <snapshot-dir>

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { POSITION_STREAM_SCHEMA } from './lib/producer-facts.mjs';

const dir = process.argv[2];
if (!dir) {
  console.error('usage: derive-positions.mjs <snapshot-dir>');
  process.exit(2);
}

function findCtPrint() {
  const explicit = process.env.CT_PRINT;
  if (explicit) {
    if (!existsSync(explicit)) throw new Error(`CT_PRINT=${explicit} does not exist`);
    return explicit;
  }
  const here = dirname(new URL(import.meta.url).pathname);
  for (const up of ['../../..', '../../../..']) {
    const guess = resolve(here, up, 'codetracer-trace-format-nim', 'ct-print');
    if (existsSync(guess)) return guess;
  }
  throw new Error('ct-print not found. Build it in a codetracer-trace-format-nim '
    + 'checkout (`nimble buildCtPrint`) and pass CT_PRINT=<path>.');
}

const ctPrint = findCtPrint();
// ── READING A CONTAINER WHOSE VERSION STAMP PREDATES THE GLOBAL-LINE-INDEX
//    CORRECTION ───────────────────────────────────────────────────────────────
//
// OFF BY DEFAULT. `ct-print` refuses such a container by name, because its
// line-only step positions would come back ONE LINE HIGH under the current
// decode — silently, with nothing in the bytes to tell the two packings apart.
// That refusal is correct and this tool does not override it on its own
// authority.
//
// `CT_PRINT_ACCEPT_SHIFTED_GLOBAL_INDEX=1` says the OPERATOR holds the evidence
// that this corpus's writer already used the corrected packing. For the
// containers in this repository that evidence exists and is recorded in
// `codetracer-specs/BlockTracer/Recording-Readers.md` §3.2: the same bytes read
// under both decodes give identical positions, and all 21 distinct (path, line)
// pairs of `0x20ed5b91…` land on the one-line BODY of the function they name
// rather than on the `fn` signature above it, checked against the container's
// own corroborated Noir text. A one-line-high decode would move all 21.
//
// THE DERIVED FILE SAYS SO. `readWithAcceptShiftedGlobalIndex: true` is written
// into the sidecar when and only when this was used, so a sidecar that rests on
// an operator's argument is distinguishable afterwards from one the container
// vouched for itself. The key is ABSENT rather than false on an ordinary read,
// which is what keeps every already-published sidecar byte-identical.
const ACCEPT_SHIFTED = process.env.CT_PRINT_ACCEPT_SHIFTED_GLOBAL_INDEX === '1';
const CT_PRINT_FLAGS = ACCEPT_SHIFTED ? ['--accept-shifted-global-index'] : [];

const snap = JSON.parse(readFileSync(join(dir, 'snapshot.json'), 'utf8'));
const outDir = join(dir, 'positions');

let wrote = 0;
let skipped = 0;
const report = [];

for (const t of snap.transactions) {
  if (t.outcome !== 'replayed' && t.outcome !== 'divergent') continue;
  if (!t.container) continue;
  const ct = join(dir, t.container);
  if (!existsSync(ct)) continue;

  // ONLY A RECORDING THAT SAYS IT POSITIONED SOMETHING. This is read from the
  // capture's own `recording.stepsPositioned` rather than discovered by
  // scanning the container, so the file this tool writes and the number the
  // product reads come from one source. A rung-3 container has every step on
  // the pseudo-path and would produce an all-null stream — a file whose only
  // content is "no positions", which is what its absence already says.
  const declared = t.recording?.stepsPositioned ?? 0;
  if (declared <= 0) { skipped++; continue; }

  const events = JSON.parse(execFileSync(ctPrint, ['--events', ...CT_PRINT_FLAGS, ct],
    { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 }));
  const allPaths = events.filter((e) => e.type === 'Path').map((e) => e.name);
  const steps = events.filter((e) => e.type === 'Step');

  // The interned paths, minus the pseudo-path at index 0, re-indexed. The map
  // from container path id to output path id is built explicitly rather than
  // by subtracting one, because "index 0 is the pseudo-path" is a fact about
  // how the recorder interns and not a rule this file may assume twice.
  const paths = [];
  const remap = new Map();
  for (let i = 1; i < allPaths.length; i++) {
    remap.set(i, paths.length);
    paths.push(allPaths[i]);
  }

  const pathId = [], line = [], column = [];
  let positioned = 0;
  for (const s of steps) {
    const to = remap.get(s.path_id);
    if (to === undefined || !(s.line > 0)) {
      pathId.push(null); line.push(null); column.push(null);
      continue;
    }
    positioned++;
    pathId.push(to);
    line.push(s.line);
    // The container carries no column on a Step event. `null` is the schema's
    // "unknown", and a fabricated 1 would put a caret on a character the
    // recording never named.
    column.push(s.column ?? null);
  }

  // THE CAPTURE'S OWN COUNT IS THE ORACLE, and a disagreement is fatal rather
  // than reported. These are two readings of one measurement — the recorder
  // counted the steps it placed, and this counts the steps it wrote a real
  // path on. If they differ, one of the two assumptions this file rests on is
  // wrong (that `path_id == 0` is the pseudo-path, or that every placed step
  // gets a Step event), and a positions file built on a wrong assumption puts
  // the debugger's caret on lines the execution never touched.
  if (positioned !== declared) {
    console.error(`derive-positions: ${t.txHash}: the capture recorded `
      + `stepsPositioned=${declared} and the container yields ${positioned}. `
      + `Refusing to write a stream neither number describes.`);
    process.exit(1);
  }

  mkdirSync(outDir, { recursive: true });
  const out = {
    // §5.3: the stream's own schema token. The READER used to spell this and now
    // republishes whatever the stream states, so it is single-sourced beside the rest
    // of this producer's facts rather than spelled once here and once there.
    schema: POSITION_STREAM_SCHEMA,
    tx: t.txHash,
    steps: steps.length,
    positioned,
    // FALSE, AND THAT IS THE POINT OF THE FILE. These coordinates were written
    // by the recording session against an artifact it had proved before it
    // executed a step; nothing here was reconstructed afterwards.
    measuredPostHoc: false,
    measuredBy: 'tools/chain/derive-positions.mjs (read from the container)',
    // Present only when the read rested on the operator's evidence rather than
    // on the container's own version stamp — see `ACCEPT_SHIFTED` above. Spread
    // rather than written as `false`, so an ordinary derivation's bytes are
    // unchanged and absence means "the container vouched for itself".
    ...(ACCEPT_SHIFTED ? { readWithAcceptShiftedGlobalIndex: true } : {}),
    paths, pathId, line, column,
  };
  writeFileSync(join(outDir, `${t.txHash}.json`), JSON.stringify(out, null, 1) + '\n');
  wrote++;
  report.push({ tx: t.txHash, steps: steps.length, positioned, files: paths.length });
  console.error(`derive-positions: ${t.txHash.slice(0, 10)}… ${positioned}/${steps.length} `
    + `step(s) positioned over ${paths.length} file(s)`);
}

console.log(JSON.stringify({ snapshot: dir, wrote, skipped, report }, null, 1));
