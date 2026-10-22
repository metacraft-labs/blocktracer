#!/usr/bin/env node
// eth-yield-reading.mjs — Ethereum mainnet's yield reading, built from whole-window snapshot
// trees and checked against the method before it is written.
//
// Usage:
//   node tools/chain/eth-yield-reading.mjs --tree <window tree> [--tree …] \
//        --endpoint <url> --tip <height> --finalized <height> --out <reading.json> \
//        [--verdict <text>]
//
// One `--tree` per pinned window, each the output of
// `capture-eth-range.mjs --whole-blocks --from <w> --to <w+1>` (Recorder-EVM CXP-EVM-5).
// The reading is a `blocktracer/historic-replay-yield@1` document, the shape Aztec's reading
// has, and `lib/yield.mjs`'s `checkReading` is run over it against `yield-method.json`
// BEFORE it is written. A finding is printed and the file is still written, because a
// reading that fails a rule is a result to publish with its failure, not to suppress.
//
// EVERY COUNT COMES OFF THE ROWS. `readingFromSnapshot` enumerates each tree over its
// window and classifies every row by `snapshot-format.json`'s partition; nothing here
// declares a population.
//
// THE DENOMINATORS are `pinned.eth`'s: all transactions, and those with an execution at all
// (`with-execution`, which removes the `no-code-executed` exclusion: plain value transfers,
// `private-only` here, Data-Contract.md §5.2's "the chain published no execution"). The second
// was declared on 2026-10-22, when this reading showed the pin's premise wrong. The
// expectation was not touched, and the correction is recorded in the method itself.
//
// T2 IS NOT TRACED. `tracedAtSourceLevel` counts traced rows whose recording measured
// `sourceLevel`. The windows are recorded with `--skip-source-fetch`, so it is expected to be
// 0 here, and `sourceFetch: false` says why.
//
// THE VERDICT is the reading's answer to `pinned.eth`'s declared expectation, as the other
// chains' readings carry one. It is passed in rather than computed, because confirming or
// refuting an expectation is a judgement over the per-window figures, not a count.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readingFromSnapshot, checkReading, READING_FORMAT } from './lib/yield.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

const many = (name) => {
  const out = [];
  for (let i = 0; i < process.argv.length; i++) {
    if (process.argv[i] === `--${name}`) out.push(process.argv[i + 1]);
  }
  return out;
};
const flag = (name) => many(name)[0];

function main() {
  const trees = many('tree');
  const endpoint = flag('endpoint');
  const tip = Number(flag('tip'));
  const finalized = Number(flag('finalized'));
  const out = flag('out');
  const verdict = flag('verdict');
  if (trees.length === 0 || !endpoint || !Number.isInteger(tip) || !Number.isInteger(finalized)
      || !out) {
    console.error('usage: eth-yield-reading.mjs --tree <dir>… --endpoint <url> --tip <n> '
                  + '--finalized <n> --out <file>');
    return 2;
  }
  const method = JSON.parse(readFileSync(join(HERE, 'yield-method.json'), 'utf8'));
  const pinned = method.pinned.eth;

  const windows = [];
  const runtimeCommits = new Set();
  for (const dir of trees) {
    const path = join(dir, 'snapshot.json');
    if (!existsSync(path)) {
      console.error(`eth-yield-reading: no snapshot at ${path}`);
      return 2;
    }
    const snap = JSON.parse(readFileSync(path, 'utf8'));
    const heights = snap.transactions.map((t) => t.blockNumber);
    const lo = Math.min(...heights);
    const pin = pinned.windows.find(([a, b]) => lo >= a && lo <= b);
    if (!pin) {
      console.error(`eth-yield-reading: ${dir} holds block ${lo}, which is in no pinned window`);
      return 2;
    }
    const [from, to] = pin;
    const r = readingFromSnapshot(snap, [[from, to]]).windows[0];
    const rows = snap.transactions.filter((t) => t.blockNumber >= from && t.blockNumber <= to);
    const by = (o) => rows.filter((t) => t.outcome === o).length;
    const replayed = by('replayed');
    const divergent = by('divergent');
    const refused = by('refused');
    const notAttempted = by('not-attempted');
    const tracedRows = rows.filter((t) => t.outcome === 'replayed' || t.outcome === 'divergent');
    for (const t of tracedRows) {
      const c = t.recording?.runtimeCommit ?? t.runtimeCommit ?? snap.provenance?.runtimeCommit;
      if (c) runtimeCommits.add(c);
    }
    const commit = [...runtimeCommits][0] ?? null;
    windows.push({
      from, to,
      blocksBelowTip: tip - to,
      blocks: to - from + 1,
      transactions: r.transactions,
      firstInBlock: r.transactions - r.notFirstInBlock,
      notFirstInBlock: r.notFirstInBlock,
      replayed, divergent,
      traced: r.traced,
      privateOnly: r.chainAbsent,
      refused,
      bodyUnavailable: 0,
      notAttempted,
      withExecution: r.transactions - r.chainAbsent,
      tracedAtSourceLevel: tracedRows.filter((t) => t.recording?.sourceLevel === true).length,
      unclassified: r.unclassified,
      ledger: {
        replay: {
          attempted: r.transactions - r.chainAbsent,
          replayed, divergent, refused, notAttempted,
          stoppedBy: null,
          runtimeCommit: commit,
        },
      },
    });
  }
  windows.sort((a, b) => a.from - b.from);

  const sum = (k) => windows.reduce((n, w) => n + w[k], 0);
  const totals = {};
  for (const k of ['transactions', 'firstInBlock', 'notFirstInBlock', 'replayed', 'divergent',
                   'traced', 'privateOnly', 'refused', 'bodyUnavailable', 'notAttempted',
                   'withExecution', 'tracedAtSourceLevel']) totals[k] = sum(k);
  const pct = (a, b) => (b === 0 ? null : Math.round(1000 * a / b) / 10);

  const doc = {
    format: READING_FORMAT,
    _comment: [
      'ETHEREUM MAINNET, EVERY TRANSACTION OF EACH PINNED WINDOW. Recorder-EVM CXP-EVM-5,',
      'built by tools/chain/eth-yield-reading.mjs from whole-block captures',
      '(capture-eth-range.mjs --whole-blocks). Each block was replayed once, in order, from',
      'its parent block (replay-preceding).',
    ],
    measuredAt: new Date().toISOString(),
    chain: 'eth',
    endpoint,
    chainTipAtRun: tip,
    finalizedAtRun: finalized,
    toolchain: { recorder: `metacraft-labs/codetracer-evm-recorder ${[...runtimeCommits].join(', ')}`,
                 sourceFetch: false },
    windows,
    totals,
    yield: {
      tracedOverAllTransactions: pct(totals.traced, totals.transactions),
      perWindowTracedOverAllTransactions: windows.map((w) => pct(w.traced, w.transactions)),
      tracedOverWithExecution: pct(totals.traced, totals.withExecution),
      perWindowTracedOverWithExecution: windows.map((w) => pct(w.traced, w.withExecution)),
    },
    sourceLevel: {
      _note: 'T2, separately from traced (CXP-EVM-5): the windows were recorded with '
        + '--skip-source-fetch, so no recording resolved verified source.',
      tracedAtSourceLevelOverTraced: pct(totals.tracedAtSourceLevel, totals.traced),
    },
  };
  if (verdict) doc.verdict = verdict;

  const check = checkReading(doc, method);
  writeFileSync(out, `${JSON.stringify(doc, null, 1)}\n`);
  console.log(`wrote ${out}: ${windows.length} window(s), ${totals.transactions} transactions, `
              + `${totals.traced} traced (${doc.yield.tracedOverAllTransactions}% of all, `
              + `${doc.yield.tracedOverWithExecution}% of those with an execution), `
              + `${totals.divergent} divergent, ${totals.refused} refused`);
  for (const w of windows) {
    console.log(`  ${w.from}-${w.to}  ${w.blocksBelowTip} below tip  ${w.transactions} tx  `
                + `${w.traced} traced  ${w.privateOnly} no-execution  ${w.divergent} divergent`);
  }
  for (const f of check.findings) console.log(`  FINDING ${f.rule}: ${f.detail}`);
  for (const n of check.notMeasured) console.log(`  NOT MEASURED: ${JSON.stringify(n)}`);
  return check.findings.length === 0 ? 0 : 1;
}

process.exit(main());
