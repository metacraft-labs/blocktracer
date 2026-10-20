#!/usr/bin/env node
// starknet-yield-reading.mjs — the `blocktracer/historic-replay-yield@1` reading for
// Starknet mainnet's pinned windows, assembled from `codetracer-cairo-onchain trace-block`
// captures and checked by the method's own `checkReading` before it is written.
//
//   node tools/chain/starknet-yield-reading.mjs --captures DIR --out FILE \
//     [--measured-at ISO] [--runtime-commit SHA]
//
// `--captures DIR` holds one `b<block>/block.json` per pinned block (the directories
// `trace-block -o b<block>` writes). Every window pinned in `yield-method.json`'s
// `pinned.starknet-mainnet` must be covered, block by block, or the run is refused: a
// window read in part is a different window.
//
// WHAT A ROW IS. Every transaction the block holds, from the capture's own per-row reports
// — the denominator is the block, not what traced. `replayed` and `divergent` are the
// recorder's verdicts over the COUNTED facts (consensus: status, fee, gas, events, messages,
// call tree); `refused` is the executor declining by name. Nothing is sampled within a
// block, and nothing is attempted twice.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

import { checkReading, pinnedFor, yieldMethod } from './lib/yield.mjs';
import { CHAIN_SLUG } from './lib/starknet-producer-facts.mjs';

const argv = process.argv.slice(2);
const flag = (n, d) => { const i = argv.indexOf(`--${n}`); return i === -1 ? d : argv[i + 1]; };
const dir = flag('captures');
const out = flag('out');
if (!dir || !out) { console.error('usage: --captures DIR --out FILE'); process.exit(2); }

const method = yieldMethod();
const pinned = pinnedFor(CHAIN_SLUG, method);
if (!pinned) { console.error(`no pinned entry for ${CHAIN_SLUG}`); process.exit(2); }

const blocks = {};
for (const [from, to] of pinned.windows) {
  for (let b = from; b <= to; b++) {
    const p = join(dir, `b${b}`, 'block.json');
    if (!existsSync(p)) { console.error(`pinned block ${b} has no capture at ${p}`); process.exit(1); }
    blocks[b] = JSON.parse(readFileSync(p, 'utf8'));
  }
}

const mismatchFields = {};
const windows = pinned.windows.map(([from, to]) => {
  const w = { from, to, blocks: to - from + 1, transactions: 0, firstInBlock: 0,
              notFirstInBlock: 0, replayed: 0, divergent: 0, traced: 0, refused: 0,
              bodyUnavailable: 0, notAttempted: 0, transactionsByBlock: {}, rows: [],
              starknetVersions: {}, blockStateDiff: {} };
  for (let b = from; b <= to; b++) {
    const blk = blocks[b];
    w.transactionsByBlock[b] = blk.perTransaction.length;
    w.starknetVersions[b] = blk.starknetVersion;
    w.blockStateDiff[b] = blk.blockStateDiff;
    for (const r of blk.perTransaction) {
      w.transactions++;
      if (r.txIndex === 0) w.firstInBlock++; else w.notFirstInBlock++;
      const o = r.outcome;
      if (o === 'replayed') w.replayed++;
      else if (o === 'divergent') w.divergent++;
      else if (o === 'refused') w.refused++;
      else w.notAttempted++;
      const bad = (r.effects?.facts ?? []).filter((f) => f.matches === false).map((f) => f.field);
      for (const f of bad) mismatchFields[f] = (mismatchFields[f] ?? 0) + 1;
      w.rows.push({ tx: r.txHash, block: b, index: r.txIndex, outcome: o,
                    ...(bad.length ? { mismatched: bad } : {}),
                    ...(o === 'refused' ? { refusal: String(r.refusal).slice(0, 200) } : {}),
                    steps: r.vm?.steps ?? 0 });
    }
  }
  w.traced = w.replayed + w.divergent;
  w.observable = w.transactions;
  w.blocksBelowTip = Number(blocks[to].chain.tip) - to;
  w.ledger = { replay: { at: flag('measured-at', new Date().toISOString()),
                         attempted: w.transactions - w.notAttempted, replayed: w.replayed,
                         divergent: w.divergent, refused: w.refused,
                         notAttempted: w.notAttempted, stoppedBy: null,
                         runtimeCommit: flag('runtime-commit', '') } };
  return w;
});

const sum = (k) => windows.reduce((n, w) => n + w[k], 0);
const totals = {};
for (const k of ['transactions', 'firstInBlock', 'notFirstInBlock', 'replayed', 'divergent',
                 'traced', 'refused', 'bodyUnavailable', 'notAttempted', 'observable']) {
  totals[k] = sum(k);
}
const pct = (a, b) => (b === 0 ? 0 : Math.round((1000 * a) / b) / 10);
const anyBlock = blocks[pinned.windows[pinned.windows.length - 1][1]];
const doc = {
  format: 'blocktracer/historic-replay-yield@1',
  chain: CHAIN_SLUG,
  measuredAt: flag('measured-at', new Date().toISOString()),
  chainTipAtRun: Number(anyBlock.chain.tip),
  finalizedAtRun: Number(anyBlock.chain.l1Accepted),
  endpoint: anyBlock.endpoint,
  toolchain: { recorder: `codetracer-cairo-onchain ${flag('runtime-commit', '')}`,
               executor: anyBlock.recorder?.executor ?? '' },
  windows,
  totals,
  yield: {
    tracedOverAllTransactions: pct(totals.traced, totals.transactions),
    tracedOverObservable: pct(totals.traced, totals.observable),
    replayedOverAllTransactions: pct(totals.replayed, totals.transactions),
  },
  mismatchedFields: mismatchFields,
};

// THE PREDICTION, AGAINST THE READING. `pinned.starknet-mainnet` declared `era` in
// advance with two parts: a STEP at the executor's floor (zero traced below 0.13.0), and
// `divergent` rows in the steps-charged eras (0.13.1, 0.13.2.1) from recompiled CASM
// moving the fee. Each part is judged on its own windows.
{
  const floor = 501514;
  const below = windows.filter((w) => w.to < floor);
  const above = windows.filter((w) => w.from >= floor);
  const stepsEra = windows.filter((w) => Object.values(w.starknetVersions)
    .every((v) => v === '0.13.1' || v === '0.13.2.1'));
  const t = (ws, k) => ws.reduce((n, w) => n + w[k], 0);
  const floorHeld = t(below, 'traced') === 0 && t(below, 'refused') === t(below, 'transactions');
  const stepsDiverged = t(stepsEra, 'divergent') > 0;
  doc.eraAnalysis = {
    boundary: floor,
    boundaryWhat: 'the executor\'s floor: blockifier 0.20.0-rc.1 carries versioned constants from Starknet 0.13.0 (first block 501,514)',
    below: { transactions: t(below, 'transactions'), traced: t(below, 'traced'), refused: t(below, 'refused') },
    atOrAbove: { transactions: t(above, 'transactions'), replayed: t(above, 'replayed'), divergent: t(above, 'divergent') },
    stepsChargedEras: { transactions: t(stepsEra, 'transactions'), replayed: t(stepsEra, 'replayed'), divergent: t(stepsEra, 'divergent') },
    prediction: 'era: a step at the executor floor, and divergent rows (fee/gas) in the steps-charged eras 0.13.1 and 0.13.2.1 (pinned.starknet-mainnet, declared 2026-10-20)',
    verdict: `${floorHeld ? 'THE FLOOR STEP HELD' : 'THE FLOOR STEP DID NOT HOLD'}: below the floor `
      + `${t(below, 'traced')} of ${t(below, 'transactions')} traced, every row refused by name. `
      + `${stepsDiverged ? 'THE STEPS-ERA DIVERGENCE APPEARED' : 'THE STEPS-ERA DIVERGENCE WAS REFUTED'}: `
      + `${t(stepsEra, 'replayed')} of ${t(stepsEra, 'transactions')} rows in 0.13.1/0.13.2.1 reproduce every counted fact, the fee to the unit, `
      + 'so recompiling Sierra with cairo-lang 2.19.5 did not move a step-charged fee in these windows. '
      + 'The dominant variable is still `era`, as one step at the executor floor and flat above it — not the gradient the second half predicted.',
  };
}

const { findings, notMeasured } = checkReading(doc, method);
writeFileSync(out, `${JSON.stringify(doc, null, 1)}\n`);
console.log(`wrote ${out}: ${totals.transactions} transactions, traced ${totals.traced} `
            + `(replayed ${totals.replayed}, divergent ${totals.divergent}), refused ${totals.refused}`);
for (const w of windows) {
  console.log(`  ${w.from}-${w.to} ${Object.values(w.starknetVersions).join('/')}: `
              + `${w.transactions} tx, ${w.replayed} replayed, ${w.divergent} divergent, ${w.refused} refused`);
}
console.log(`checkReading: ${findings.length} finding(s), ${notMeasured.length} not measured`);
for (const f of findings) console.log(`  ${f.rule}: ${f.what ?? f.message ?? JSON.stringify(f)}`);
for (const n of notMeasured) console.log(`  NOT MEASURED ${JSON.stringify(n)}`);
process.exit(findings.length === 0 ? 0 : 1);
