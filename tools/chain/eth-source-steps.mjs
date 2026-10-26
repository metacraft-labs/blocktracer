#!/usr/bin/env node
// eth-source-steps.mjs — the share of each traced transaction's executed steps that has backing
// source: the per-transaction source-level figure the operator chose for Recorder-EVM
// CXP-EVM-5 (2026-10-23), in place of a rule that calls a whole transaction T2 or not.
//
// Usage:
//   node tools/chain/eth-source-steps.mjs --blocks <dir of per-block trace-block runs> \
//        --recorder <commit> --out <file> [--chain <label>] [--windows <from>-<to>[,…]]
//
// `--windows` defaults to Ethereum mainnet's six pinned windows; a second instance names its
// own (Recorder-EVM CXP-EVM-5's Sepolia comparison), and `--chain` labels the reading.
//
// Each block directory holds `trace-block`'s per-transaction reports (`evm-*.log`), recorded
// with Sourcify on, no lookup cap and the verified solc releases on PATH. A report states
//   captured N step(s), …                                   the replay's own count
//   S executed step(s) resolved to verified source and L to a disassembly listing
// (codetracer-evm-recorder c9b56b3 onward). S/N is the transaction's share of steps with
// backing source. N − S − L resolved to no line at all (compiler-generated code with no source
// range, an implicit STOP), and counts as not backed.
//
// "Verified source" means the recorder recompiled the contract from Sourcify and the result
// describes the deployed code, at any of Chain-Support-Matrix §1.2a's rungs: an optimized
// contract's source LINES are backing source even though its locals are not (level C).

import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const flag = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
};

const MAINNET_WINDOWS = [[4370100, 4370101], [12500000, 12500001], [13000000, 13000001],
                 [17100000, 17100001], [19500000, 19500001], [22500000, 22500001]];

function summarize(txs) {
  const n = txs.length;
  const steps = txs.reduce((a, t) => a + t.captured, 0);
  const onSource = txs.reduce((a, t) => a + t.onSource, 0);
  const onListing = txs.reduce((a, t) => a + t.onListing, 0);
  const ratios = txs.map((t) => (t.captured === 0 ? 0 : t.onSource / t.captured)).sort((a, b) => a - b);
  const pct = (x) => Math.round(1000 * x) / 10;
  const median = n === 0 ? null : (n % 2 ? ratios[(n - 1) / 2] : (ratios[n / 2 - 1] + ratios[n / 2]) / 2);
  return {
    transactions: n,
    steps, onSource, onListing, onNoLine: steps - onSource - onListing,
    aggregateSourceShare: steps === 0 ? null : pct(onSource / steps),
    meanPerTransaction: n === 0 ? null : pct(ratios.reduce((a, r) => a + r, 0) / n),
    medianPerTransaction: median === null ? null : pct(median),
    transactionsAllSource: txs.filter((t) => t.captured > 0 && t.onSource === t.captured).length,
    transactionsAtLeastHalf: ratios.filter((r) => r >= 0.5).length,
    transactionsNoSource: txs.filter((t) => t.onSource === 0).length,
  };
}

function main() {
  const dir = flag('blocks');
  const recorder = flag('recorder');
  const out = flag('out');
  const chain = flag('chain') ?? 'ethereum-mainnet';
  const WINDOWS = flag('windows')
    ? flag('windows').split(',').map((w) => w.split('-').map(Number))
    : MAINNET_WINDOWS;
  if (!dir || !recorder || !out || !existsSync(dir) ||
      WINDOWS.some((w) => w.length !== 2 || !w.every(Number.isInteger))) {
    console.error('usage: eth-source-steps.mjs --blocks <dir> --recorder <commit> --out <file>');
    return 2;
  }
  const txs = [];
  const missing = [];
  for (const [from, to] of WINDOWS) {
    for (let b = from; b <= to; b++) {
      const bd = join(dir, String(b));
      if (!existsSync(bd)) { missing.push(b); continue; }
      for (const f of readdirSync(bd)) {
        if (!f.startsWith('evm-') || !f.endsWith('.log')) continue;
        const text = readFileSync(join(bd, f), 'utf8');
        const cap = /captured (\d+) step\(s\)/.exec(text);
        const src = /^(\d+) executed step\(s\) resolved to verified source and (\d+) to a disassembly listing/m.exec(text);
        if (!cap || !src) {
          console.error(`eth-source-steps: ${bd}/${f} carries no step counts (recorder older than c9b56b3?)`);
          return 1;
        }
        txs.push({ block: b, tx: f.slice(6, 72), captured: Number(cap[1]),
                   onSource: Number(src[1]), onListing: Number(src[2]) });
      }
    }
  }
  if (missing.length) {
    console.error(`eth-source-steps: no recording for block(s) ${missing.join(', ')}`);
    return 1;
  }
  const windows = WINDOWS.map(([from, to]) => ({
    from, to, ...summarize(txs.filter((t) => t.block >= from && t.block <= to)),
  }));
  const doc = {
    format: 'blocktracer/eth-source-steps@1',
    _comment: [
      'THE SHARE OF EACH TRACED TRANSACTION\'S EXECUTED STEPS THAT HAS BACKING SOURCE, the',
      'per-transaction source-level figure the operator chose for CXP-EVM-5 on 2026-10-23.',
      'A step is backed when it resolved to a line of source the recorder recompiled from',
      'Sourcify and checked against the deployed code (any §1.2a rung: an optimized contract\'s',
      'lines count). Every transaction of the six pinned windows with an execution, recorded with',
      'Sourcify on, no lookup cap, and the 77 verified solc releases that have static Linux',
      'builds on PATH (8 older or nightly releases have none, so their contracts are unbacked).',
    ],
    measuredAt: new Date().toISOString(),
    chain,
    recorder: `metacraft-labs/codetracer-evm-recorder ${recorder}`,
    total: summarize(txs),
    windows,
  };
  writeFileSync(out, `${JSON.stringify(doc, null, 1)}\n`);
  const t = doc.total;
  console.log(`wrote ${out}: ${t.transactions} transactions, ${t.steps} steps; `
              + `${t.aggregateSourceShare}% of all steps on verified source; per transaction mean `
              + `${t.meanPerTransaction}%, median ${t.medianPerTransaction}%; `
              + `${t.transactionsAllSource} fully, ${t.transactionsAtLeastHalf} at least half, `
              + `${t.transactionsNoSource} not at all`);
  for (const w of windows) {
    console.log(`  ${w.from}-${w.to}  ${w.transactions} tx  aggregate ${w.aggregateSourceShare}%  `
                + `mean ${w.meanPerTransaction}%  median ${w.medianPerTransaction}%`);
  }
  return 0;
}

process.exit(main());
