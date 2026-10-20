#!/usr/bin/env node
// sol-capture-warmth.mjs — HOW MUCH OF A SOLANA SLOT WINDOW A FORWARD-CHAINED CAPTURE
// COULD GIVE AN EXACT PRESTATE, MEASURED LIVE. Recorder-Solana CXP-SOL-1.
//
//   node tools/chain/sol-capture-warmth.mjs --rpc https://solana-rpc.publicnode.com \
//     --slots 300 --out tools/chain/measurements/sol-capture-warmth.json
//
// ── THE ROUTE THIS MEASURES, AND WHY IT IS THE ONLY ONE LEFT ──────────────────────────
//
// sol-capability-matrix.json shows that no provider in the probe reads an account at the
// slot of a transaction — not at any depth, not even at the finalized head, where the read
// lands slots LATER and is therefore the transaction's post-state. So prestate cannot be
// fetched; it can only be CARRIED. A capture that reads account A once, at the slot the
// RPC answer names (`context.slot` = C), holds A's exact state after every transaction up
// to C. If it then executes every later transaction that touches A, in chain order, it
// holds A's exact state before each of them. A transaction whose every account is held
// this way has an exact prestate; one that touches an account first read AFTER it ran
// does not, and is refused `prestate-unavailable`.
//
// That is §1.4's `replay-preceding` with the archive replaced by the capture's own
// history, and it only works going FORWARD from when the capture started: a window
// cannot be captured after the fact. This tool measures the part of the route that does
// not need the SVM: how quickly a live capture's held set covers what transactions touch.
// It does NOT measure replay fidelity — that is CXP-SOL-4's divergence check, and an
// exact prestate replayed by a wrong engine is still a wrong trace.
//
// ── WHAT COUNTS AS AN ACCOUNT THE TRANSACTION NEEDS ───────────────────────────────────
//
// Every static key and every lookup-table-loaded address. Excluded, each for a stated
// reason: sysvars (the capture constructs or re-reads them per slot, they are not carried
// state) and the native programs, whose accounts are builtins that no transaction changes.
// Program accounts are included; an upgradeable program's programdata account is not named
// by the transaction and is approximated by its program id being held — recorded as an
// approximation in the output rather than silently.

import { writeFileSync } from 'node:fs';

const args = process.argv.slice(2);
let rpcUrl = 'https://api.mainnet-beta.solana.com';
let slots = 300;
let out = null;
let fetchBudget = 1000; // getMultipleAccounts calls per processed block
let concurrency = 8;
let perCall = 100; // accounts per getMultipleAccounts call; publicnode allows 10
let failedFetches = 0;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--rpc') rpcUrl = args[++i];
  else if (args[i] === '--slots') slots = Number(args[++i]);
  else if (args[i] === '--out') out = args[++i];
  else if (args[i] === '--fetch-budget') fetchBudget = Number(args[++i]);
  else if (args[i] === '--concurrency') concurrency = Number(args[++i]);
  else if (args[i] === '--accounts-per-call') perCall = Number(args[++i]);
  else { console.error(`unknown argument ${args[i]}`); process.exit(1); }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let calls = 0;
async function rpc(method, params) {
  for (let attempt = 0; attempt < 8; attempt++) {
    try {
      calls++;
      const res = await fetch(rpcUrl, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(30_000),
      });
      if (res.status === 429 || res.status >= 500) { await sleep(800 * (attempt + 1)); continue; }
      const body = await res.json();
      if (body.error?.code === 429) { await sleep(800 * (attempt + 1)); continue; }
      return body;
    } catch { await sleep(800 * (attempt + 1)); }
  }
  return { error: { code: 'gave-up' } };
}

const NATIVE = new Set([
  '11111111111111111111111111111111', 'Vote111111111111111111111111111111111111111',
  'Stake11111111111111111111111111111111111111', 'ComputeBudget111111111111111111111111111111',
  'AddressLookupTab1e1111111111111111111111111', 'BPFLoaderUpgradeab1e11111111111111111111111',
  'BPFLoader2111111111111111111111111111111111', 'BPFLoader1111111111111111111111111111111111',
  'LoaderV411111111111111111111111111111111111', 'Config1111111111111111111111111111111111111',
  'Ed25519SigVerify111111111111111111111111111', 'KeccakSecp256k11111111111111111111111111111',
  'Secp256r1SigVerify1111111111111111111111111', 'ZkE1Gama1Proof11111111111111111111111111111',
  'NativeLoader1111111111111111111111111111111',
]);
const isSysvar = (k) => k.startsWith('Sysvar') || k === 'SysvarS1otHashes111111111111111111111111111';
const VOTE = 'Vote111111111111111111111111111111111111111';

/** The accounts a transaction may write: the message header's writable ranges plus the
 * lookup-table addresses loaded writable. */
function writableKeys(t) {
  const m = t.transaction.message;
  const h = m.header;
  const n = m.accountKeys.length;
  const out = [];
  m.accountKeys.forEach((k, i) => {
    const signed = i < h.numRequiredSignatures;
    const w = signed
      ? i < h.numRequiredSignatures - h.numReadonlySignedAccounts
      : i < n - h.numReadonlyUnsignedAccounts;
    if (w) out.push(k);
  });
  return [...out, ...(t.meta?.loadedAddresses?.writable ?? [])];
}
let evictions = 0;

/** account -> slot it was read at (exact state after every transaction up to that slot). */
const held = new Map();
const pendingFetch = new Set();

async function fetchHeld() {
  // Read up to fetchBudget*100 never-held accounts; each answer names the slot it was read at.
  const batch = [...pendingFetch].slice(0, fetchBudget * perCall);
  const chunks = [];
  for (let i = 0; i < batch.length; i += perCall) chunks.push(batch.slice(i, i + perCall));
  // Batches run concurrently; each answer still names the slot IT was read at,
  // so concurrency changes how fast accounts become held, never what "held" means.
  let next = 0;
  await Promise.all(Array.from({ length: concurrency }, async () => {
    while (next < chunks.length) {
      const keys = chunks[next++];
      const r = await rpc('getMultipleAccounts', [keys, { encoding: 'base64', commitment: 'finalized', dataSlice: { offset: 0, length: 0 } }]);
      // A refused call is COUNTED, never skipped silently: a run whose fetches all
      // failed would otherwise report a yield of zero as if it had been measured.
      if (!r.result) { failedFetches++; if (failedFetches <= 3) console.error('getMultipleAccounts refused:', JSON.stringify(r.error)); continue; }
      const at = r.result.context.slot;
      for (const k of keys) { held.set(k, at); pendingFetch.delete(k); }
    }
  }));
}

const head = (await rpc('getSlot', [{ commitment: 'finalized' }])).result;
const windowStart = head + 1;
const perSlot = [];
let slot = windowStart;
const startedAt = Date.now();
while (slot < windowStart + slots) {
  const fin = (await rpc('getSlot', [{ commitment: 'finalized' }])).result;
  if (slot > fin) { await sleep(300); continue; }
  const b = await rpc('getBlock', [slot, { maxSupportedTransactionVersion: 1, transactionDetails: 'full', rewards: false, encoding: 'json', commitment: 'finalized' }]);
  if (!b.result) { perSlot.push({ slot, skipped: true, error: b.error?.code }); slot++; continue; }
  let nonVote = 0, exact = 0, failedOnChain = 0;
  for (const t of b.result.transactions) {
    const keys = [...t.transaction.message.accountKeys,
      ...(t.meta?.loadedAddresses?.writable ?? []), ...(t.meta?.loadedAddresses?.readonly ?? [])];
    if (keys.includes(VOTE)) continue;
    nonVote++;
    if (t.meta?.err) failedOnChain++;
    const needed = keys.filter((k) => !NATIVE.has(k) && !isSysvar(k));
    // Held strictly before this slot: the read reflects every transaction at or below it.
    const isExact = needed.every((k) => held.has(k) && held.get(k) < slot);
    if (isExact) exact++;
    else if (!t.meta?.err) {
      // A transaction the capture cannot execute exactly still WROTE its writable
      // accounts, and nothing in the metadata says what it wrote to their data. Every
      // writable account it touched therefore stops being held and is read again.
      // (One that failed on chain changed only the fee payer's lamports, which
      // `postBalances` states exactly, so it evicts nothing.)
      for (const k of writableKeys(t)) if (held.has(k) && held.get(k) < slot) { held.delete(k); evictions++; }
    }
    for (const k of needed) if (!held.has(k)) pendingFetch.add(k);
  }
  await fetchHeld();
  perSlot.push({ slot, nonVote, exact, failedOnChain, held: held.size, evictions, backlog: pendingFetch.size, lagSlots: fin - slot });
  console.error(`slot ${slot}: ${exact}/${nonVote} exact, held ${held.size}, backlog ${pendingFetch.size}, lag ${fin - slot}`);
  slot++;
}

const produced = perSlot.filter((s) => !s.skipped);
const sum = (f) => produced.reduce((a, s) => a + f(s), 0);
const deciles = [];
for (let d = 0; d < 10; d++) {
  const part = produced.slice(Math.floor(d * produced.length / 10), Math.floor((d + 1) * produced.length / 10));
  const n = part.reduce((a, s) => a + s.nonVote, 0);
  const e = part.reduce((a, s) => a + s.exact, 0);
  deciles.push({ decile: d, firstSlot: part[0]?.slot, nonVote: n, exact: e, fraction: n ? +(e / n).toFixed(4) : null });
}
const result = {
  format: 'blocktracer/sol-capture-warmth@1',
  measuredOn: new Date().toISOString(),
  measuredBy: 'tools/chain/sol-capture-warmth.mjs',
  rpc: rpcUrl,
  window: { firstSlot: windowStart, lastSlot: windowStart + slots - 1, slots, produced: produced.length },
  fetchBudgetPerBlock: fetchBudget * perCall,
  accountsPerCall: perCall,
  failedFetches,
  concurrency,
  rpcCalls: calls,
  wallSeconds: Math.round((Date.now() - startedAt) / 1000),
  approximations: ['an upgradeable program\'s programdata account is taken as held when its program id is held'],
  totals: { nonVote: sum((s) => s.nonVote), exact: sum((s) => s.exact), evictions },
  deciles,
  perSlot,
};
const json = JSON.stringify(result, null, 2) + '\n';
if (out) writeFileSync(out, json); else process.stdout.write(json);
