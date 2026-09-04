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
// ── What the container carries, and what CHANGED under it ───────────────────
//
// Two shapes, and this tool reads both.
//
// THE AVM-CONTEXT SHAPE, which every container committed under
// `client/fixtures/chain/` has: two `Function` events (`<toplevel>` and
// `enqueued-call-0`), two `Call` events, one `Return`. Both calls open before
// step 0 and the return lands after the last step — a two-deep stack open for
// the whole recording, not a tree that evolves as it runs. Both frames sit on
// `path_id: 0`, the pseudo-path `/aztec/<txHash>.avm` the recorder interns first
// and files unplaceable coordinates under, so both carry `path: null`.
//
// THE NOIR SHAPE, which `aztec-avm-runtime@26cac14` taught both recorders to
// write: the same two AVM frames, and INSIDE the enqueued call a frame per Noir
// function boundary, each on a REAL interned path with a real declaration line.
// On the published snapshot's own 108 steps that is 44 more frames, nine deep,
// over 33 distinct functions.
//
// This tool used to REFUSE the second shape — `if (fn.path_id > 0) … exit(1)`,
// on the grounds that writing `path: null` under it would discard a coordinate
// the recording took the trouble to write. That refusal was right and it has
// been paid off rather than deleted: the path is now RESOLVED through the
// container's own `Path` table instead of dropped.
//
// ── Resolving a frame's path, and the pseudo-path that is not one ───────────
//
// `Path` events arrive in interning order, so their index IS the `path_id` a
// `Function` event quotes — the same identity `derive-positions.mjs` relies on
// for steps. Index 0 is the pseudo-path; a frame there has no source position
// and is written `path: null, line: null`, which is what `CallFrame.line == 0`
// means downstream and what the renderer draws as nothing rather than as `:0`.
//
// ── Folding, and why the counts are computed HERE ────────────────────────────
//
// A third of the reader's steps on a typical Aztec public call are inside
// poseidon2. `fold_rules.mjs` says which subtrees the pane starts with CLOSED —
// library code the contract author did not write — and this tool applies it and
// writes the answer down. Nothing is omitted: every frame the recorder wrote is
// in the output, at its real depth, in order. A folded frame is one that carries
// `foldedBy`, and the pane draws it shut with a disclosure the reader can open.
//
// THE COUNTS ARE THIS TOOL'S BECAUSE ONLY THIS TOOL HOLDS THE WHOLE TREE. It
// reads every `Call`, `Return` and `Step` event in the container, in order, so
// `hiddenDescendants` and `hiddenSteps` are properties of the RECORDING. A
// renderer that counted its way down the rows it happened to have would be
// answering a different question — and would answer it differently depending on
// what else the page had loaded. `session_view.CallFrame` therefore has no
// arithmetic in it; it carries these two numbers and paints them.
//
// `hiddenSteps` is cross-checked against a second, independent reading of the
// same fact — `endStep - step`, the recording's own step clock across the
// frame's life — and a disagreement is fatal. See `foldSubtrees` below.
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
//
//   …--no-fold writes the same frames with no fold marks at all, which is how
//   the OTHER direction of the default gets measured. A default that cannot be
//   turned off is not a default.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';

import { DEFAULT_FOLD_RULES, foldRuleFor } from './fold_rules.mjs';
import { buildFrames } from './lib/calltrace_frames.mjs';

const args = process.argv.slice(2);
const noFold = args.includes('--no-fold');
const dir = args.find((a) => !a.startsWith('--'));
if (!dir) {
  console.error('usage: derive-calltrace.mjs [--no-fold] <snapshot-dir>');
  process.exit(2);
}
const rules = noFold ? [] : DEFAULT_FOLD_RULES;

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
  // COUNTED, NOT SILENTLY DROPPED. A transaction with no container is a pruned
  // body or an unreplayed one — a valid, expected row — but a run that wrote
  // nothing and reported nothing would look identical to a run that found no
  // snapshot at all, so the two outcomes are told apart in the report.
  if (t.outcome !== 'replayed' && t.outcome !== 'divergent') { skipped++; continue; }
  if (!t.container) { skipped++; continue; }
  const ct = join(dir, t.container);
  if (!existsSync(ct)) { skipped++; continue; }

  const events = JSON.parse(execFileSync(ctPrint, ['--events', ct],
    { encoding: 'utf8', maxBuffer: 512 * 1024 * 1024 }));

  // Walk in stream order, counting Steps, so every frame gets the time
  // coordinate it opened at. That coordinate is what the pane's row carries as
  // `data-step` and what a share link from the row resolves against, so it has
  // to be the recording's own step index and not the frame's position in a list.
  //
  // The walk, the path resolution and the fold marking are in
  // `lib/calltrace_frames.mjs` so the self-test can drive them over hand-built
  // streams with no container and no `ct-print`. Its refusals are exceptions,
  // and they become this tool's `exit(1)` here — a tool stops, a library reports.
  let built;
  try {
    built = buildFrames(events, { rules, foldRuleFor });
  } catch (err) {
    console.error(`derive-calltrace: ${t.txHash}: ${err.message}`);
    process.exit(1);
  }
  const { frames, calls, returns } = built;

  // THE CAPTURE'S OWN COUNT IS THE ORACLE, and a disagreement is fatal rather
  // than reported — the same contract `derive-positions.mjs` signs.
  //
  // `recording.callsOpened` is the writer module's own `ct_calls_opened()` — it
  // counts every frame the RECORDER opened and excludes the synthetic
  // `<toplevel>` the trace writer emits on open, so the relation is
  // `calls == callsOpened + 1`. That is an assumption about how the recorder
  // counts, which is exactly the kind of assumption that must be checked rather
  // than believed: if it is wrong, the pane renders a frame the recording never
  // opened, and `manifest.execution.frames` — which is written FROM
  // `callsOpened` — would go on reporting the other number beside it.
  //
  // IT SURVIVED THE NOIR FRAMES UNCHANGED, AND THAT WAS MEASURED RATHER THAN
  // HOPED FOR. This comment used to say `callsOpened` counts "the ENQUEUED
  // calls", which was true of every container that existed when it was written
  // and is not the rule. Read off both shapes of the same transaction:
  //
  //   published, AVM-context frames    2 Call, 1 Return, callsOpened 1
  //   fixture, Noir frames            46 Call, 45 Return, callsOpened 45
  //
  // One unmatched `Call` in each, `function_id 0`, first in the container, no
  // args and no `Return` — the `<toplevel>` row this pane has always drawn.
  // `+ 1` is that frame, on both shapes, which is why the refusal needed no
  // widening for a tree forty-four frames deeper.
  const declared = t.recording?.callsOpened ?? 0;
  if (calls !== declared + 1) {
    console.error(`derive-calltrace: ${t.txHash}: the capture recorded `
      + `callsOpened=${declared} and the container yields ${calls} Call event(s), `
      + `which is not ${declared + 1}. Refusing to write a call trace neither `
      + `number describes.`);
    process.exit(1);
  }

  const folded = frames.filter((f) => f.foldedBy !== null);

  mkdirSync(outDir, { recursive: true });
  const out = {
    // BUMPED FROM `/1`, AND THE FIELDS ARE ADDITIVE. Every frame carries
    // `foldedBy`, `foldWhy`, `hiddenDescendants` and `hiddenSteps`; a `/1`
    // sidecar has none of them and still renders, because their absence reads as
    // "nothing is folded", which is exactly what a `/1` recording's two frames
    // are. The version moves so a reviewer can tell the two apart, not because
    // one of them stopped working.
    schema: 'avm-call-frames/2',
    tx: t.txHash,
    // Republished so the ingest can refuse a stream that disagrees with the
    // manifest it is about to write, without re-deriving anything.
    callsOpened: declared,
    frames: frames.length,
    steps: t.recording?.steps ?? null,
    // THE FOLD POLICY THAT PRODUCED THIS FILE, NAMED IN IT. Two derivations of
    // one container differ only by this, and a sidecar that did not say which
    // one it was would be indistinguishable from a recording with no library
    // code in it. `--no-fold` writes `[]` here rather than omitting the field.
    foldRules: rules.map((r) => ({ id: r.id, why: r.why })),
    foldedFrames: folded.length,
    // The reader-facing total: how much of the trace starts behind a triangle.
    // Summed over the fold POINTS, which never nest — the fold lands on the
    // outermost matching frame — so this cannot double-count.
    foldedSteps: folded.reduce((a, f) => a + f.hiddenSteps, 0),
    measuredPostHoc: false,
    measuredBy: 'tools/chain/derive-calltrace.mjs (read from the container)',
    frame: frames,
  };
  writeFileSync(join(outDir, `${t.txHash}.json`), JSON.stringify(out, null, 1) + '\n');
  wrote++;
  report.push({
    tx: t.txHash, frames: frames.length, returns,
    folded: folded.length, foldedSteps: out.foldedSteps,
  });
  const shown = frames.length <= 4
    ? ` [${frames.map((f) => f.name).join(', ')}]`
    : ` [${frames.slice(0, 3).map((f) => f.name).join(', ')}, …]`;
  console.error(`derive-calltrace: ${t.txHash.slice(0, 10)}… ${frames.length} frame(s)${shown}, `
    + `${returns} return(s), ${folded.length} folded hiding ${out.foldedSteps} step(s)`);
}

console.log(JSON.stringify({ snapshot: dir, wrote, skipped, report }, null, 1));
