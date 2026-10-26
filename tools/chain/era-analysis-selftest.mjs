#!/usr/bin/env node
//
// era-analysis-selftest.mjs — the era expectation can be refuted, and is judged on data.
//
// Recorder-Flow CXP-FLOW-5, `test_the_era_prediction_can_fail`: per-window yield is fitted
// against depth and against boundary positions, and a smooth decline is recorded as a
// refutation with retention named as the suspected cause. Control: the analysis is run on a
// fabricated smooth data set and reports refutation. `lib/era-analysis.mjs` is the analysis;
// every arm here runs it, on fabricated sets whose answer is known and on the committed era
// probe reading. Offline: only node and this repository.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import { judgeEra, pointsFromEraProbe } from './lib/era-analysis.mjs';

// The assertion count this suite declares, which `refusal-selftest.mjs` cross-checks
// against the `chain-selftest` header. No host configurations, so the base is the total.
const BASE_ARMS = 7;

let passed = 0;
const arm = (name, fn) => {
  fn();
  passed += 1;
  console.log(`  ok  ${name}`);
};

const reading = JSON.parse(readFileSync(
  new URL('./measurements/flow-era-edges.json', import.meta.url)));
// Declared by the chain, not chosen from yields: the NodeVersionBeacon's boundaries.
const BOUNDARIES = reading.versionBoundaries.map((b) => b.height);
const FROM = 'NodeVersionBeacon (measurements/flow-era-edges.json)';
const heights = Array.from({ length: 20 }, (_, i) => 137_400_000 + i * 1_500_000);

arm('a smooth decline with depth is reported as a REFUTATION, naming retention', () => {
  const smooth = heights.map((h, i) => ({ height: h, attempted: 100, reproduced: 10 + 4 * i }));
  const v = judgeEra(smooth, BOUNDARIES, FROM);
  assert.equal(v.verdict, 'smooth-decline');
  assert.match(v.reason, /era expectation is REFUTED/);
  assert.match(v.reason, /suspected cause is retention/);
});

arm('control: a step at a declared boundary is reported as a step', () => {
  const step = heights.map((h) => ({ height: h, attempted: 100,
                                     reproduced: h >= 151_898_000 ? 95 : 5 }));
  assert.equal(judgeEra(step, BOUNDARIES, FROM).verdict, 'step');
});

arm('control: a decline in the OTHER direction (yield rising with depth) is not a decline', () => {
  const rising = heights.map((h, i) => ({ height: h, attempted: 100, reproduced: 90 - 4 * i }));
  const v = judgeEra(rising, BOUNDARIES, FROM);
  assert.notEqual(v.verdict, 'smooth-decline');
  assert.ok(v.fit.trend.slopePerMillionBlocks < 0);
});

arm('a flat yield is not established either way, and says why', () => {
  const flat = heights.map((h) => ({ height: h, attempted: 10, reproduced: 5 }));
  const v = judgeEra(flat, BOUNDARIES, FROM);
  assert.equal(v.verdict, 'not-established');
  assert.match(v.reason, /nothing varies/);
});

arm('too few points is not established, and windows with no attempt do not count', () => {
  const few = [{ height: 1, attempted: 3, reproduced: 0 }, { height: 2, attempted: 0, reproduced: 0 },
               { height: 3, attempted: 5, reproduced: 1 }];
  const v = judgeEra(few, BOUNDARIES, FROM);
  assert.equal(v.verdict, 'not-established');
  assert.equal(v.points, 2);
});

arm('the step model is charged for its segments: one boundary per point does not win by fitting', () => {
  // Every point in a segment of its own fits perfectly and explains everything, so a judge
  // that compared residuals alone would always answer `step`. The smooth set again, with a
  // boundary at every point: the trend must still win.
  const smooth = heights.map((h, i) => ({ height: h, attempted: 100, reproduced: 10 + 4 * i }));
  const v = judgeEra(smooth, heights, 'one per point');
  assert.equal(v.fit.step.explained, 1);
  assert.equal(v.verdict, 'smooth-decline');
});

arm('the committed era reading, against the chain\'s own boundaries, is judged and not assumed', () => {
  const v = judgeEra(pointsFromEraProbe(reading), BOUNDARIES, FROM);
  assert.equal(v.points, reading.edges.length * 2);
  assert.equal(v.boundariesFrom, FROM);
  // The figures this verdict rests on are the reading's own, recorded in Recorder-Flow
  // CXP-FLOW-5: a pair sample is built to test edges, not to fit yields, and the FlowFees
  // window sits inside version segments, so neither fit is convincing.
  assert.equal(v.verdict, 'not-established');
  assert.ok(v.fit.step.explained > v.fit.trend.explained);
});

if (passed !== BASE_ARMS) {
  console.error(`era-analysis-selftest: ${passed} arm(s) ran and ${BASE_ARMS} are declared`);
  process.exit(1);
}
console.log(`era-analysis-selftest: ${passed} passed`);
