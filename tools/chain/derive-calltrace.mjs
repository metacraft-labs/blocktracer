#!/usr/bin/env node
// Read the CALL FRAMES a recording wrote into its own container, and publish
// them as `calltrace/<txHash>.json` beside it.
//
// ── Why this exists, and what it corrects ────────────────────────────────────
//
// CHAIN-CAPTURE.md §6.6 recorded the Call Trace pane's emptiness as a property
// of the STATIC EXPORT: "they are absent from the statically exported page only
// because that page has no CTFS reader — the site build is hermetic". Every
// clause of that is true and the conclusion did not follow. `instructions/` and
// `positions/` are also read out of a `.ct` by a reader the build does not have;
// they reach the page because the read happens BY HAND, ahead of the build, and
// the result is committed. The frames were the one stream nobody had pointed
// that same, already-accepted mechanism at.
//
// So nothing here is new architecture. This is `derive-positions.mjs` with
// `Call`/`Function` events instead of `Step` events, and the build stays exactly
// as hermetic as it was.
//
// ── What the container actually carries ──────────────────────────────────────
//
// Measured across all 27 committed containers (`client/fixtures/chain/aztec`
// and `aztec-testnet`), the structure is uniform: two `Function` events
// (`<toplevel>` and `enqueued-call-0`), two `Call` events, one `Return`. The
// second `Call` carries the enqueued call's target contract as its one argument.
//
// BOTH CALLS OPEN BEFORE STEP 0 AND THE RETURN LANDS AFTER THE LAST STEP. This
// is a two-deep stack that is open for the whole recording, not a tree that
// evolves as it runs — an AVM enqueued call is one public function invocation
// and the recorder does not open a frame per Noir inlined callee. A reader of
// this file should expect a short, flat answer, and the pane rendering two rows
// is that answer and not a truncation of a longer one.
//
// ── No file, no line, and that stays true ────────────────────────────────────
//
// The `Function` events name `path_id: 0`, which is the synthetic pseudo-path
// `/aztec/<txHash>.avm` the recorder interns first and files unplaceable
// coordinates under (see `derive-positions.mjs` for the same structural test).
// A frame's declared `line: 1` there is a slot filler, not a source line.
//
// So `path` and `line` are written as `null` and the pseudo-path is DROPPED
// rather than renumbered, exactly as the positions stream drops it. The pane's
// standing sentence — "Nothing resolved a source position, so they carry no
// file or line" — remains literally true after this tool runs; what stops being
// true is only the clause that said the frames are listed *once the session is
// live*, because they are listed now.
//
// ── Cost is deliberately not written ─────────────────────────────────────────
//
// `CallFrame` carries a `cost`/`costUnit` column and the container does carry a
// per-step `l2Gas` reading. Attributing that gas to a frame would mean deciding
// how to split it between two frames that are BOTH open for all 108 steps —
// there is no interval where one is running and the other is not. Any number
// here would be an arithmetic convention presented as a measurement, so the
// column stays empty and the renderer renders no cost.
//
// Usage:
//   CT_PRINT=../codetracer-trace-format-nim/ct-print \
//     node tools/chain/derive-calltrace.mjs client/fixtures/chain/aztec-testnet

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

const dir = process.argv[2];
if (!dir) {
  console.error('usage: derive-calltrace.mjs <snapshot-dir>');
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
const snap = JSON.parse(readFileSync(join(dir, 'snapshot.json'), 'utf8'));
const outDir = join(dir, 'calltrace');

let wrote = 0;
let skipped = 0;
const report = [];

for (const t of snap.transactions) {
  if (t.outcome !== 'replayed' && t.outcome !== 'divergent') continue;
  if (!t.container) continue;
  const ct = join(dir, t.container);
  if (!existsSync(ct)) continue;

  const events = JSON.parse(execFileSync(ctPrint, ['--events', ct],
    { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 }));

  // The interning tables, in the order the container declares them. A
  // `Function` event is a DEFINITION and a `Call` event is an INVOCATION that
  // references one by index; the two are separate streams and this tool must
  // not assume they interleave one-to-one, even though on this corpus they do.
  const functions = events.filter((e) => e.type === 'Function');
  const varNames = events.filter((e) => e.type === 'VariableName').map((e) => e.name);

  // Walk in stream order, counting Steps, so every frame gets the time
  // coordinate it opened at. That coordinate is what the pane's row carries as
  // `data-step` and what a share link from the row resolves against, so it has
  // to be the recording's own step index and not the frame's position in a list.
  let step = 0;
  const open = [];
  const frames = [];
  let calls = 0;
  let returns = 0;

  for (const e of events) {
    if (e.type === 'Step') { step++; continue; }

    if (e.type === 'Call') {
      calls++;
      const fn = functions[e.function_id];
      if (!fn) {
        console.error(`derive-calltrace: ${t.txHash}: Call references function_id `
          + `${e.function_id} and the container declares ${functions.length} `
          + `function(s). Refusing to write a frame with no definition behind it.`);
        process.exit(1);
      }
      // The corpus-wide fact this file rests on, checked per frame. If a
      // recorder ever positions a frame on a real interned path, writing
      // `path: null` below would DISCARD a source coordinate the recording
      // took the trouble to write — a silent downgrade, and the exact shape of
      // defect this repository refuses elsewhere. Stop instead.
      if (fn.path_id > 0) {
        console.error(`derive-calltrace: ${t.txHash}: frame '${fn.name}' is placed on `
          + `interned path ${fn.path_id}, not the pseudo-path. This tool would drop `
          + `that position. Teach it to emit path/line before deriving this container.`);
        process.exit(1);
      }
      const frame = {
        name: fn.name,
        depth: open.length,
        // The step the frame opened at. Both frames on this corpus open at 0,
        // before the first Step event is read.
        step,
        // NULL BY MEASUREMENT, NOT BY OMISSION, and asserted rather than
        // assumed. `path_id === 0` is the pseudo-path — the recorder's "no
        // source position" — so there is no file and no line to write. Every
        // frame in this corpus sits there; a recorder that one day places a
        // frame on a real path must not have that position silently dropped,
        // so it is refused below instead.
        path: null,
        line: null,
        args: (e.args ?? []).map((a) => ({
          name: varNames[a.variable_id] ?? null,
          value: a.value?.text ?? (a.value?.i !== undefined ? String(a.value.i) : null),
        })),
        endStep: null,
      };
      open.push(frame);
      frames.push(frame);
      continue;
    }

    if (e.type === 'Return') {
      returns++;
      const frame = open.pop();
      // A Return with nothing open is a malformed stream, not a frame at
      // depth -1. Refusing beats writing a call trace that claims a structure
      // the container does not have.
      if (!frame) {
        console.error(`derive-calltrace: ${t.txHash}: a Return event closes a frame `
          + `that was never opened. Refusing to write a malformed call trace.`);
        process.exit(1);
      }
      frame.endStep = step;
    }
  }

  // THE CAPTURE'S OWN COUNT IS THE ORACLE, and a disagreement is fatal rather
  // than reported — the same contract `derive-positions.mjs` signs.
  //
  // `recording.callsOpened` counts the ENQUEUED calls and excludes the
  // synthetic `<toplevel>` frame the recorder opens to hold them, so the
  // relation is `calls == callsOpened + 1`. That is an assumption about how the
  // recorder counts, which is exactly the kind of assumption that must be
  // checked rather than believed: if it is wrong, the pane renders a frame the
  // recording never opened, and `manifest.execution.frames` — which is written
  // FROM `callsOpened` — would go on reporting the other number beside it.
  const declared = t.recording?.callsOpened ?? 0;
  if (calls !== declared + 1) {
    console.error(`derive-calltrace: ${t.txHash}: the capture recorded `
      + `callsOpened=${declared} and the container yields ${calls} Call event(s), `
      + `which is not ${declared + 1}. Refusing to write a call trace neither `
      + `number describes.`);
    process.exit(1);
  }

  mkdirSync(outDir, { recursive: true });
  const out = {
    schema: 'avm-call-frames/1',
    tx: t.txHash,
    // Republished so the ingest can refuse a stream that disagrees with the
    // manifest it is about to write, without re-deriving anything.
    callsOpened: declared,
    frames: frames.length,
    steps: t.recording?.steps ?? null,
    measuredPostHoc: false,
    measuredBy: 'tools/chain/derive-calltrace.mjs (read from the container)',
    frame: frames,
  };
  writeFileSync(join(outDir, `${t.txHash}.json`), JSON.stringify(out, null, 1) + '\n');
  wrote++;
  report.push({ tx: t.txHash, frames: frames.length, returns });
  console.error(`derive-calltrace: ${t.txHash.slice(0, 10)}… ${frames.length} frame(s) `
    + `[${frames.map((f) => f.name).join(', ')}], ${returns} return(s)`);
}

console.log(JSON.stringify({ snapshot: dir, wrote, skipped, report }, null, 1));
