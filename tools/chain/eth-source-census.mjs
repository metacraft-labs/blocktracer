#!/usr/bin/env node
// eth-source-census.mjs — which of the contracts a reading's traced transactions executed have
// verified source, and of what kind: the per-contract half of Recorder-EVM CXP-EVM-5's T2
// fraction, measured.
//
// Usage:
//   node tools/chain/eth-source-census.mjs --work <window work dir> [--work …] \
//        --endpoint <url> --out <census.json>
//
// One `--work` per pinned window, each the `--work` directory `capture-eth-range.mjs
// --whole-blocks` recorded into. Every traced transaction left a recorder report
// (`blocks/<n>/<container>.log`) naming its entry point and every address whose code ran
// (codetracer-evm-recorder 2221328 onward lists them all), and those reports are the population.
//
// THE LADDER IS CHAIN-SUPPORT-MATRIX.md §1.2a's, AND ONLY ITS CONDITIONS ARE CHECKED.
//   D           Sourcify has no verified match for the address
//   C           verified, compiled with the optimizer or via-IR: source lines only, so T1
//   B-candidate verified Solidity, optimizer off, not via-IR. §1.2a's B also needs the
//               recompile to produce a source map, AST and storage layout that describe the
//               deployed code, which this census does NOT do, so this is an UPPER BOUND on B
//   vyper       verified Vyper. §1.2a states its conditions for solc, so it is reported
//               apart rather than placed on a rung the ladder does not define for it
// A is not graded: no Sourcify setting records `ethdebug` output.
//
// AN EIP-7702 ACCOUNT IS GRADED BY ITS DELEGATE, because the delegate's code is what ran.
// An address Sourcify does not know is asked for its code, and a 23-byte `0xef0100` designator
// sends the lookup to the delegate.
//
// TRANSACTION LEVEL IS NOT DECIDED HERE. §1.2a grades contracts. Whether a transaction is T2
// when its ENTRY contract is, or only when EVERY contract it ran is, the spec does not say, so
// both roll-ups are published and neither is called the T2 fraction.

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

const SOURCIFY = 'https://sourcify.dev/server/v2/contract/1';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchRetry(url, init, what) {
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetch(url, init);
      if (res.status === 429 || res.status >= 500) throw new Error(`HTTP ${res.status}`);
      return res;
    } catch (err) {
      if (attempt >= 5) throw new Error(`${what}: ${err.message}`);
      await sleep(1000 * 2 ** attempt);
    }
  }
}

async function sourcify(address) {
  const res = await fetchRetry(`${SOURCIFY}/${address}?fields=compilation`, {}, `Sourcify ${address}`);
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Sourcify ${address}: HTTP ${res.status}`);
  return (await res.json()).compilation;
}

async function codeAt(endpoint, address, block) {
  const res = await fetchRetry(endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_getCode',
                           params: [address, `0x${block.toString(16)}`] }),
  }, `eth_getCode ${address}`);
  const body = await res.json();
  if (typeof body.result !== 'string') {
    throw new Error(`eth_getCode ${address}: ${JSON.stringify(body.error ?? body)}`);
  }
  return body.result;
}

function grade(compilation) {
  if (!compilation) return 'D';
  if (compilation.language === 'Vyper') return 'vyper';
  const settings = compilation.compilerSettings ?? {};
  if (settings.viaIR === true || settings.optimizer?.enabled === true) return 'C';
  return 'B-candidate';
}

/** Every traced transaction's entry point and executed contracts, from its recorder report. */
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
        const contracts = [];
        for (const line of text.split('\n')) {
          const m = /^ {2}(0x[0-9a-fA-F]{40}) (.*)$/.exec(line);
          if (!m) continue;
          // Neither has code to grade: an account with none, and a creation's initcode,
          // which no address holds while it runs.
          if (m[2].startsWith('no code at the target block')) continue;
          if (m[2].startsWith('contract-creation initcode')) continue;
          contracts.push(m[1].toLowerCase());
        }
        txs.push({ tx: f.slice(6, 72), block: Number(b), entry: entry[1].toLowerCase(),
                   contracts: [...new Set(contracts)] });
      }
    }
  }
  return txs;
}

async function main() {
  const works = many('work');
  const endpoint = flag('endpoint');
  const out = flag('out');
  if (works.length === 0 || !endpoint || !out || works.some((w) => !existsSync(join(w, 'blocks')))) {
    console.error('usage: eth-source-census.mjs --work <dir>… --endpoint <url> --out <file>');
    return 2;
  }
  const txs = readReports(works);
  const firstSeen = new Map();
  for (const t of txs) for (const a of t.contracts) if (!firstSeen.has(a)) firstSeen.set(a, t.block);

  const contracts = {};
  let done = 0;
  for (const [address, block] of firstSeen) {
    let compilation = await sourcify(address);
    let delegate = null;
    if (!compilation) {
      const code = await codeAt(endpoint, address, block);
      if (code.length === 2 + 46 && code.toLowerCase().startsWith('0xef0100')) {
        delegate = `0x${code.slice(8)}`.toLowerCase();
        compilation = await sourcify(delegate);
      }
    }
    contracts[address] = {
      grade: grade(compilation),
      ...(delegate ? { eip7702Delegate: delegate } : {}),
      ...(compilation ? { compiler: `${compilation.compiler} ${compilation.compilerVersion}`,
                          optimizer: compilation.compilerSettings?.optimizer?.enabled ?? null,
                          viaIR: compilation.compilerSettings?.viaIR === true } : {}),
    };
    if (++done % 100 === 0) console.error(`  ${done} of ${firstSeen.size} contracts graded`);
    await sleep(100);
  }

  const GRADES = ['B-candidate', 'C', 'D', 'vyper'];
  const byGrade = Object.fromEntries(GRADES.map((g) => [g, 0]));
  for (const c of Object.values(contracts)) byGrade[c.grade]++;
  const B = (a) => contracts[a]?.grade === 'B-candidate';
  const withContract = txs.filter((t) => t.contracts.length > 0);
  const entryB = withContract.filter((t) => B(t.entry)).length;
  const allB = withContract.filter((t) => t.contracts.every(B)).length;
  const pct = (a, b) => (b === 0 ? null : Math.round(1000 * a / b) / 10);

  const doc = {
    format: 'blocktracer/eth-source-census@1',
    _comment: [
      'THE PER-CONTRACT HALF OF CXP-EVM-5\'S T2 FRACTION, against Chain-Support-Matrix.md',
      '§1.2a\'s ladder, from the recorder reports of the six pinned windows. `B-candidate` is an',
      'UPPER BOUND on level B: the recompile that would prove a source map, AST and storage',
      'layout describe the deployed code was not run. The transaction-level rule is not',
      'decided by the spec, so both roll-ups are published and neither is called T2.',
    ],
    measuredAt: new Date().toISOString(),
    sourcify: SOURCIFY,
    endpoint,
    tracedTransactions: txs.length,
    tracedTransactionsWithACodeContract: withContract.length,
    contracts: { distinct: firstSeen.size, byGrade },
    eip7702Accounts: Object.values(contracts).filter((c) => c.eip7702Delegate).length,
    transactionRollups: {
      entryContractBCandidate: { count: entryB, ofTracedWithContract: pct(entryB, withContract.length) },
      everyContractBCandidate: { count: allB, ofTracedWithContract: pct(allB, withContract.length) },
    },
    perContract: contracts,
  };
  writeFileSync(out, `${JSON.stringify(doc, null, 1)}\n`);
  console.log(`wrote ${out}: ${firstSeen.size} contracts over ${txs.length} traced transactions; `
              + `${GRADES.map((g) => `${g} ${byGrade[g]}`).join(', ')}; `
              + `${doc.eip7702Accounts} EIP-7702 account(s)`);
  console.log(`  entry contract B-candidate: ${entryB} (${pct(entryB, withContract.length)}%); `
              + `every contract B-candidate: ${allB} (${pct(allB, withContract.length)}%)`);
  return 0;
}

main().then((rc) => process.exit(rc), (err) => { console.error(`eth-source-census: ${err.message}`); process.exit(1); });
