#!/usr/bin/env node
// eth-receipt-check.mjs — does each recorded transaction's replay agree with the receipt the
// chain recorded? The check `produce-eth-snapshot.mjs` makes for Ethereum mainnet (status, gas,
// log count), made over `trace-block` ledgers directly, for an EVM instance with no producer of
// its own yet (Recorder-EVM CXP-EVM-5's second instance).
//
// Usage:
//   node tools/chain/eth-receipt-check.mjs --blocks <dir of per-block trace-block runs> \
//        --rpc <archive endpoint> --out <file>
//
// For every `block-<n>.json` ledger under `--blocks`, each `recorded` row's `succeeded`,
// `gasUsed` and `logs` are compared with `eth_getTransactionReceipt`. A row that disagrees on any
// of the three is DIVERGENT and is named. `not recorded` rows are counted apart by reason, and a
// row that ran no code (`captured 0 EVM steps`) is a plain transfer, not a failure to trace.

import { readFileSync, readdirSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const flag = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function receipt(rpc, hash) {
  for (let attempt = 0; ; attempt++) {
    try {
      const res = await fetch(rpc, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_getTransactionReceipt', params: [hash] }),
      });
      const body = await res.json();
      if (body.result) return body.result;
      throw new Error(JSON.stringify(body.error ?? body));
    } catch (err) {
      if (attempt >= 5) throw new Error(`receipt ${hash}: ${err.message}`);
      await sleep(1000 * 2 ** attempt);
    }
  }
}

async function main() {
  const dir = flag('blocks');
  const rpc = flag('rpc');
  const out = flag('out');
  if (!dir || !rpc || !out || !existsSync(dir)) {
    console.error('usage: eth-receipt-check.mjs --blocks <dir> --rpc <url> --out <file>');
    return 2;
  }
  const blocks = [];
  for (const b of readdirSync(dir).filter((x) => /^\d+$/.test(x)).sort((a, z) => a - z)) {
    const ledger = join(dir, b, `block-${b}.json`);
    if (!existsSync(ledger)) { console.error(`eth-receipt-check: no ledger at ${ledger}`); return 1; }
    const j = JSON.parse(readFileSync(ledger, 'utf8'));
    let matched = 0;
    const divergent = [];
    const notRecorded = {};
    for (const row of j.rows) {
      if (row.outcome !== 'recorded') {
        const why = /captured 0 EVM steps/.test(row.reason ?? '') ? 'no-code-executed' : (row.outcome ?? 'other');
        notRecorded[why] = (notRecorded[why] ?? 0) + 1;
        continue;
      }
      const r = await receipt(rpc, row.txHash);
      const facts = {
        status: [row.succeeded, r.status === '0x1'],
        gasUsed: [row.gasUsed, parseInt(r.gasUsed, 16)],
        logs: [row.logs, r.logs.length],
      };
      const bad = Object.entries(facts).filter(([, [a, z]]) => a !== z);
      if (bad.length === 0) matched++;
      else divergent.push({ txHash: row.txHash, differs: Object.fromEntries(bad) });
    }
    blocks.push({ block: Number(b), rows: j.rows.length, matched, divergent: divergent.length,
                  notRecorded, divergentRows: divergent });
  }
  const sum = (k) => blocks.reduce((a, x) => a + x[k], 0);
  const doc = {
    format: 'blocktracer/eth-receipt-check@1',
    measuredAt: new Date().toISOString(),
    rpc,
    totals: { rows: sum('rows'), matched: sum('matched'), divergent: sum('divergent') },
    blocks,
  };
  writeFileSync(out, `${JSON.stringify(doc, null, 1)}\n`);
  console.log(`wrote ${out}: ${doc.totals.rows} rows, ${doc.totals.matched} recorded and matching the `
              + `receipt, ${doc.totals.divergent} divergent`);
  for (const x of blocks) {
    console.log(`  block ${x.block}: ${x.matched} matched, ${x.divergent} divergent, not recorded `
                + `${JSON.stringify(x.notRecorded)}`);
  }
  return doc.totals.divergent === 0 ? 0 : 1;
}

main().then((rc) => process.exit(rc), (err) => { console.error(`eth-receipt-check: ${err.message}`); process.exit(1); });
