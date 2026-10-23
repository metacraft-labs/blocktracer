#!/usr/bin/env node
// sol-address-history.mjs — EACH PAGED ADDRESS'S CHAIN HISTORY BELOW A PUBLISHED WINDOW.
//
//   node tools/chain/sol-address-history.mjs --fixture <fixture dir> --from <slot> --to <slot>
//        [--rpc <url>] [--limit 100]
//
// Spine need (f), Recorder-Solana.milestones.org. A Solana address page built only from
// the snapshot's rows shows the captured window, but the chain serves every address's
// signature history with no index of ours (Chain-Support-Matrix §3.5). This tool asks for
// it once and commits the answer beside the window's other inputs, under
// `<fixture>/history/<from>-<to>.json`, so the build reads it offline.
//
// WHICH ADDRESSES: exactly those the reader gives a page — each published row's roles and
// its payload target (ingest.nim's `participate`), computed with the producer's own
// `rolesForRow` / `payloadForRow` so the two cannot disagree. No history-only address.
//
// WHY THE ANSWER IS STABLE: each query is pinned `before` the address's OLDEST signature in
// the window, at `finalized`. Finalized history below a fixed signature does not change,
// so re-running it returns the same entries (an RPC that has pruned them returns fewer,
// and `complete` then says so). Entries at or above `--from` are dropped: every
// transaction in a published slot is already a row.

import { existsSync, readFileSync, readdirSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

import { payloadForRow, rolesForRow } from './lib/solana-producer-facts.mjs';

const args = process.argv.slice(2);
const flag = (n) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i + 1] : undefined; };
const die = (m) => { console.error(`sol-address-history: ${m}`); process.exit(2); };

const fixture = flag('fixture');
const from = Number(flag('from')); const to = Number(flag('to'));
const url = flag('rpc') ?? 'https://api.mainnet-beta.solana.com';
const limit = Number(flag('limit') ?? 100);
if (!fixture || !Number.isFinite(from) || !Number.isFinite(to)) die('needs --fixture --from --to');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function rpc(method, params) {
  for (let attempt = 0; attempt < 10; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(60_000),
      });
      if (res.status === 429 || res.status >= 500) { console.error(`    ${method}: HTTP ${res.status}, retry ${attempt + 1}`); await sleep(1000 * (attempt + 1)); continue; }
      const body = await res.json();
      // -32019 ("Failed to query long-term storage; please try again") is the RPC's own
      // transient refusal, not an answer.
      if (body.error?.code === 429 || body.error?.code === -32005 || /try again/i.test(body.error?.message ?? '')) { await sleep(1000 * (attempt + 1)); continue; }
      return body;
    } catch { await sleep(1000 * (attempt + 1)); }
  }
  return { error: { code: 'gave-up', message: `${method}: no answer after 10 attempts` } };
}

// The oldest in-window signature per paged address: lowest slot, then lowest index.
const oldest = new Map();
for (const f of readdirSync(join(fixture, 'blocks')).sort()) {
  const b = JSON.parse(readFileSync(join(fixture, 'blocks', f), 'utf8'));
  if (b.slot < from || b.slot > to) continue;
  for (const t of b.transactions) {
    if (t.vote) continue;
    const paged = [...rolesForRow(t).map((r) => r.address), payloadForRow(t).target].filter(Boolean);
    for (const a of paged) {
      const cur = oldest.get(a);
      if (!cur || b.slot < cur.slot || (b.slot === cur.slot && t.index < cur.index)) {
        oldest.set(a, { slot: b.slot, index: t.index, signature: t.signature });
      }
    }
  }
}

// Resumable: a partial run's answers are kept and only the missing addresses asked.
mkdirSync(join(fixture, 'history'), { recursive: true });
const partial = join(fixture, 'history', `.${from}-${to}.partial.json`);
const out = existsSync(partial) ? JSON.parse(readFileSync(partial, 'utf8')) : {};
const addresses = [...oldest.keys()].sort();
let n = 0;
for (const address of addresses) {
  if (out[address]) { n++; continue; }
  const before = oldest.get(address).signature;
  const r = await rpc('getSignaturesForAddress', [address, { before, limit, commitment: 'finalized' }]);
  if (r.error) die(`${address}: ${r.error.message ?? JSON.stringify(r.error)}`);
  const entries = r.result
    .filter((s) => s.slot < from)
    .map((s) => ({ txHash: s.signature, blockNumber: s.slot, timestamp: s.blockTime ?? null, failed: s.err !== null }));
  out[address] = { before, limit, complete: r.result.length < limit, entries };
  console.error(`  ${++n}/${addresses.length} ${address} ${entries.length}${out[address].complete ? " complete" : ""}`);
  writeFileSync(partial, JSON.stringify(out));
  await sleep(250);
}

const path = join(fixture, 'history', `${from}-${to}.json`);
writeFileSync(path, `${JSON.stringify({ format: 'codetracer-solana/address-history@1', rpc: url, from, to, addresses: out }, null, 1)}\n`);
rmSync(partial);
console.error(`wrote ${path}: ${addresses.length} addresses, ${Object.values(out).reduce((s, a) => s + a.entries.length, 0)} entries`);
