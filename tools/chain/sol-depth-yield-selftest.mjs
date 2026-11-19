// sol-depth-yield-selftest.mjs — RECORDER-SOLANA CXP-SOL-5's THREE VERIFICATIONS, OVER
// THE REAL ACCOUNTING AND THE REAL CLASSIFIER.
//
//   test_a_divergent_trace_does_not_count_as_yield
//   test_the_window_set_spans_the_predicted_transition
//   test_the_depth_prediction_can_fail
//
// Offline and toolchain-free: each window is a capture directory written here in the
// shape `capture-sol-window.mjs` writes (capture.json, blocks.jsonl, results.jsonl,
// traces/<sig>/listings/), and read back by `sol-depth-yield.mjs`'s own
// `windowPopulations`. The prediction is judged by its own `classify`: the controls drive
// the predicate the measurement uses, never a copy of it.

import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { windowPopulations, yieldOf, classify } from './sol-depth-yield.mjs';

const BASE_ARMS = 25;
let asserted = 0;
let failed = 0;
function ck(name, ok) {
  asserted++;
  if (!ok) failed++;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}`);
}

const root = mkdtempSync(join(tmpdir(), 'sol-depth-yield-selftest-'));
let n = 0;

/** A capture directory with one block holding `rows`. */
function windowOf(depth, rows) {
  const dir = join(root, `w${n++}`);
  mkdirSync(dir);
  writeFileSync(join(dir, 'capture.json'), JSON.stringify({
    capturedAt: '2026-11-12T00:00:00Z', wallSeconds: 1,
    window: { firstSlot: 100, lastSlot: 100, slots: 1 },
    depth: { requested: depth, headAtOpen: 100 + depth },
    scope: ['Prog1111111111111111111111111111111111111111'],
    counts: { skipped: 0 },
  }));
  const txs = rows.map((r, i) => ({ signature: `sig${i}`, vote: !!r.vote, inScope: !!r.inScope, result: r.result }));
  writeFileSync(join(dir, 'blocks.jsonl'), JSON.stringify({ slot: 100, transactions: txs }) + '\n');
  const results = rows.map((r, i) => r.result === 'not-executed'
    ? { op: 'tx', signature: `sig${i}`, executed: false, reason: `${r.reason}: detail` }
    : { op: 'tx', signature: `sig${i}`, executed: r.result !== 'not-sent' });
  writeFileSync(join(dir, 'results.jsonl'), results.map((x) => JSON.stringify(x)).join('\n') + '\n');
  rows.forEach((r, i) => {
    if (r.result !== 'match') return;
    const listings = join(dir, 'traces', `sig${i}`, 'listings');
    mkdirSync(listings, { recursive: true });
    writeFileSync(join(listings, 'Prog-0.sbf'), '');
    if (r.source) writeFileSync(join(listings, 'lib.rs'), '');
  });
  return dir;
}

const M = { inScope: true, result: 'match' };
const D = { inScope: true, result: 'divergent' };
const U = { inScope: true, result: 'unchecked' };
const R = { inScope: true, result: 'not-executed', reason: 'prestate-unavailable' };
const OUT = { inScope: false, result: 'not-sent' };
const VOTE = { vote: true, result: 'not-sent' };

// ── the accounting, over a real-shaped window ─────────────────────────────────────────
const base = windowPopulations(windowOf(0, [M, M, M, R, R, D, OUT, VOTE]));
ck('every transaction is counted once — 8', base.transactions === 8);
ck('votes and out-of-scope rows are reported beside the population, not in it',
   base.votes === 1 && base.outOfScope === 1 && base.inScope === 6);
ck('the four populations sum to the in-scope count — 3 + 1 + 2 + 0 = 6',
   base.match + base.divergent + base.refusedTotal + base.absent === base.inScope);
ck('refusals are counted per reason class', base.refused['prestate-unavailable'] === 2);
ck('yield is match over in-scope — 3/6', base.yield === 0.5);
ck('the window carries its depth from capture.json', base.depth === 0);

// ── test_a_divergent_trace_does_not_count_as_yield ────────────────────────────────────
{
  const injected = windowPopulations(windowOf(0, [M, M, D, R, R, D, OUT, VOTE]));
  ck('an injected divergence lowers yield by exactly one transaction',
     Math.round((base.yield - injected.yield) * base.inScope) === 1);
  ck('…and raises the divergent count by the same one', injected.divergent - base.divergent === 1);
  ck('…while the in-scope population stays the same', injected.inScope === base.inScope);
  // CONTROL: a change that SHOULD move yield up does, so the arm above is about
  // divergence and not about any change lowering the number.
  const recovered = windowPopulations(windowOf(0, [M, M, M, M, R, D, OUT, VOTE]));
  ck('CONTROL: a refused row that matches instead raises yield by one', recovered.yield > base.yield);
}
{
  const unchecked = windowPopulations(windowOf(0, [M, M, U, R, R, D, OUT, VOTE]));
  ck('an unchecked trace is not yield either', unchecked.yield < base.yield);
  ck('…and is counted as unchecked', unchecked.unchecked === 1);
}
{
  let threw = false;
  try { yieldOf({ inScope: 5, match: 1, divergent: 0, unchecked: 0, refused: { x: 1 }, absent: 0 }); }
  catch { threw = true; }
  ck('a window whose populations do not sum to its in-scope count is refused', threw);
}
{
  const t1 = windowPopulations(windowOf(0, [M, M]));
  const t2 = windowPopulations(windowOf(0, [M, { ...M, source: true }]));
  ck('a trace whose listings are only SBF disassembly is not T2', t1.t2 === 0);
  ck('CONTROL: a trace with a source listing is T2', t2.t2 === 1 && t2.t2Fraction === 0.5);
}

// ── the classifier ────────────────────────────────────────────────────────────────────
const pt = (depth, y) => ({ depth, yield: y });
const shaped = [pt(0, 0.4), pt(15, 0.2), pt(30, 0.1), pt(60, 0), pt(1000, 0)];
{
  const c = classify(shaped);
  ck('a monotone decline to zero confirms the prediction', c.verdict === 'confirmed');
  ck('…and names the shallowest depth at which yield is zero', c.floorDepth === 60);
}

// ── test_the_window_set_spans_the_predicted_transition ────────────────────────────────
ck('without the zero windows the same curve does NOT confirm: no floor was found',
   classify(shaped.filter((p) => p.yield > 0)).verdict === 'refuted');
ck('with ONLY the zero windows nothing can be seen to decline: untestable, not confirmed',
   classify(shaped.filter((p) => p.yield === 0)).verdict === 'untestable');

// ── test_the_depth_prediction_can_fail ────────────────────────────────────────────────
{
  const flat = classify([pt(0, 0.3), pt(30, 0.3), pt(1000, 0.3)]);
  ck('a fabricated FLAT data set is classified as a refutation', flat.verdict === 'refuted');
  ck('…and says it was flat', /flat/.test(flat.why));
  const bump = classify([pt(0, 0.4), pt(15, 0.1), pt(30, 0.3), pt(60, 0)]);
  ck('a deeper window beating a shallower one refutes, even with a zero floor', bump.verdict === 'refuted');
  ck('…and names where the order broke', /30 > 15/.test(bump.why));
  ck('a curve that RISES from a zero shallow window refutes rather than being untestable',
     classify([pt(0, 0), pt(30, 0.3)]).verdict === 'refuted');
}
ck('one window cannot test a curve', classify([pt(0, 0.4)]).verdict === 'untestable');

rmSync(root, { recursive: true, force: true });
if (asserted !== BASE_ARMS) {
  console.error(`ASSERTION COUNT: ran ${asserted}, declared ${BASE_ARMS} — an arm was added, removed or skipped`);
  process.exit(1);
}
console.log(`${asserted - failed}/${asserted} passed`);
process.exit(failed ? 1 : 0);
