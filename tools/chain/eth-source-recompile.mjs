#!/usr/bin/env node
// eth-source-recompile.mjs — which of the census's B-candidates the RECORDER actually maps at
// level B, measured by recompiling them: the half of Recorder-EVM CXP-EVM-5's T2 fraction that
// `eth-source-census.mjs` could only bound.
//
// Usage:
//   node tools/chain/eth-source-recompile.mjs --census tools/chain/measurements/eth-source-census.json \
//        --rec <dir of trace-onchain runs> --recorder <commit> --work <window work dir> [--work …] \
//        --out <file>
//
// `--rec` holds one directory per re-traced transaction, each with the recorder's `log`, from
// `trace-onchain --max-source-lookups 1000` with every verified solc release on PATH (a set of
// transactions that together execute every B-candidate). The recorder prints one outcome per
// address it looked up, and that line is the measurement:
//   B                 "mapped as …; source map, AST, storage layout" — §1.2a's level B
//                     conditions, all produced by a recompile that describes the deployed code
//   mapped-without-…  mapped, but the recompile produced no AST or no storage layout
//                     (storageLayout exists from solc 0.5.13), so source lines only
//   mismatch          the recompile does not describe the deployed code
//   failed            Sourcify answered and the recompile failed, with the recorder's reason
// A B-candidate no run looked up is reported, never assumed.
//
// The transaction roll-ups are the census's two, recomputed with MEASURED B in place of the
// candidate grade. Which of them is the T2 fraction is still not decided by the spec.

import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const many = (name) => {
  const out = [];
  for (let i = 0; i < process.argv.length; i++) {
    if (process.argv[i] === `--${name}`) out.push(process.argv[i + 1]);
  }
  return out;
};
const flag = (name) => many(name)[0];

/** Each traced transaction's entry point and code contracts, from the windows' recorder reports. */
function readReports(workDirs) {
  const txs = [];
  for (const work of workDirs) {
    const blocks = join(work, 'blocks');
    for (const b of readdirSync(blocks)) {
      for (const f of readdirSync(join(blocks, b))) {
        if (!f.startsWith('evm-') || !f.endsWith('.log')) continue;
        const text = readFileSync(join(blocks, b, f), 'utf8');
        const entry = /entry point (0x[0-9a-fA-F]{40})/.exec(text);
        if (!entry) continue;
        const contracts = new Set();
        for (const m of text.matchAll(/^ {2}(0x[0-9a-fA-F]{40}) (.*)$/gm)) {
          if (m[2].startsWith('no code at the target block')) continue;
          if (m[2].startsWith('contract-creation initcode')) continue;
          contracts.add(m[1].toLowerCase());
        }
        txs.push({ entry: entry[1].toLowerCase(), contracts: [...contracts] });
      }
    }
  }
  return txs;
}

function outcomeOf(text) {
  if (text.startsWith('mapped as ')) {
    const ast = /source map, AST,/.test(text);
    const layout = /, storage layout$/.test(text.replace(/; registered.*$/, ''));
    if (ast && layout) return 'B';
    if (!ast) return 'mapped-without-ast';
    return 'mapped-without-storage-layout';
  }
  if (text.startsWith('RECOMPILE DOES NOT DESCRIBE')) return 'mismatch';
  if (text.startsWith('source unavailable')) return 'failed';
  if (text.startsWith('no usable verified source')) return 'not-verified';
  if (text.startsWith('not looked up')) return 'not-looked-up';
  return 'other';
}

function main() {
  const censusPath = flag('census');
  const rec = flag('rec');
  const recorder = flag('recorder');
  const out = flag('out');
  const works = many('work');
  if (!censusPath || !rec || !recorder || !out || !existsSync(rec) || works.length === 0) {
    console.error('usage: eth-source-recompile.mjs --census <json> --rec <dir> --recorder <commit> --out <file>');
    return 2;
  }
  const census = JSON.parse(readFileSync(censusPath, 'utf8'));
  const candidates = Object.entries(census.perContract)
    .filter(([, c]) => c.grade === 'B-candidate').map(([a]) => a);
  const wanted = new Set(candidates);

  const seen = new Map();
  let runs = 0;
  for (const tx of readdirSync(rec)) {
    const log = join(rec, tx, 'log');
    if (!existsSync(log)) continue;
    runs++;
    for (const line of readFileSync(log, 'utf8').split('\n')) {
      const m = /^ {2}(0x[0-9a-fA-F]{40}) (.*)$/.exec(line);
      if (!m) continue;
      const a = m[1].toLowerCase();
      if (!wanted.has(a) || seen.has(a)) continue;
      const text = m[2];
      seen.set(a, { outcome: outcomeOf(text), tx,
                    ...(outcomeOf(text) === 'failed' || outcomeOf(text) === 'mismatch'
                      ? { detail: text.slice(0, 300) } : {}) });
    }
  }

  const OUTCOMES = ['B', 'mapped-without-storage-layout', 'mapped-without-ast', 'mismatch',
                    'failed', 'not-verified', 'not-looked-up', 'other', 'not-in-any-run'];
  const byOutcome = Object.fromEntries(OUTCOMES.map((o) => [o, 0]));
  const perContract = {};
  for (const a of candidates) {
    const r = seen.get(a) ?? { outcome: 'not-in-any-run' };
    perContract[a] = { ...r, compiler: census.perContract[a].compiler };
    byOutcome[r.outcome]++;
  }

  // The census's two roll-ups, with MEASURED B. Its per-transaction contract lists are not in
  // the census file, so they are re-read from the same recorder reports the census read.
  const isB = (a) => perContract[a]?.outcome === 'B';
  const withContract = readReports(works).filter((t) => t.contracts.length > 0);
  const entryB = withContract.filter((t) => isB(t.entry)).length;
  const allB = withContract.filter((t) => t.contracts.every(isB)).length;
  const pct = (a, b) => (b === 0 ? null : Math.round(1000 * a / b) / 10);

  const doc = {
    format: 'blocktracer/eth-source-recompile@1',
    _comment: [
      'LEVEL B, MEASURED: each of eth-source-census.json\'s B-candidates recompiled by',
      `codetracer-evm-recorder ${recorder} through Sourcify with its verified solc release, and`,
      'graded by the recorder\'s own outcome line. B = mapped with a source map, an AST and a',
      'storage layout, all from a recompile that describes the deployed code.',
    ],
    measuredAt: new Date().toISOString(),
    recorder: `metacraft-labs/codetracer-evm-recorder ${recorder}`,
    census: censusPath,
    runs,
    candidates: candidates.length,
    byOutcome,
    measuredBOfCandidates: pct(byOutcome.B, candidates.length),
    transactionRollups: {
      tracedTransactionsWithACodeContract: withContract.length,
      entryContractB: { count: entryB, ofTracedWithContract: pct(entryB, withContract.length) },
      everyContractB: { count: allB, ofTracedWithContract: pct(allB, withContract.length) },
    },
    perContract,
  };
  writeFileSync(out, `${JSON.stringify(doc, null, 1)}\n`);
  console.log(`wrote ${out}: ${candidates.length} B-candidates over ${runs} run(s); `
              + OUTCOMES.filter((o) => byOutcome[o]).map((o) => `${o} ${byOutcome[o]}`).join(', '));
  console.log(`  entry contract at B: ${entryB} (${pct(entryB, withContract.length)}%); `
              + `every contract at B: ${allB} (${pct(allB, withContract.length)}%) of `
              + `${withContract.length} traced transactions that ran a contract`);
  return 0;
}

process.exit(main());
