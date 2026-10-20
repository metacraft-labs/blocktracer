#!/usr/bin/env node
// capture-sol-window.mjs — A LIVE FORWARD-CHAINED CAPTURE OF A SOLANA SLOT WINDOW,
// REPLAYED THROUGH THE REAL RUNTIME AND CHECKED TRANSACTION BY TRANSACTION.
// Recorder-Solana CXP-SOL-1 (the route) and CXP-SOL-4 (the check), feeding CXP-SOL-3.
//
//   node tools/chain/capture-sol-window.mjs \
//     --recorder ../codetracer-solana-recorder/target/release/codetracer-solana-recorder \
//     --slots 50 --out <capture dir>
//
// ── WHY THE CAPTURE HAS TO BE LIVE ─────────────────────────────────────────────────────
//
// No RPC reads a Solana account at a past slot (sol-capability-matrix.json), so a
// transaction's prestate cannot be fetched after the fact; it can only be CARRIED. This
// tool reads each account once, at the slot the RPC's answer names, hands it to a
// long-running `codetracer-solana-recorder replay-stream`, and from then on the replay
// holds that account by executing — in chain order — every later transaction that touches
// it. The recorder checks every execution against the chain's recorded metadata and stops
// holding whatever a refused or divergent transaction wrote; this tool then reads those
// accounts again. A transaction runs only if every account it names is held, so a trace
// this tool keeps is one whose prestate was carried, and whose execution the chain's own
// record agreed with.
//
// ── THE ORDERING RULE THE WHOLE ROUTE STANDS ON ────────────────────────────────────────
//
// An account read at slot C reflects every transaction at or below C. It may therefore
// be handed to the replay before the first transaction of slot C+1 and NOT before: a
// state read after a transaction ran, handed in ahead of it, is that transaction's
// post-state presented as its prestate. Reads are therefore STAGED with the slot they
// were read at and released to the replay only when the capture reaches a later slot.
//
// ── WHAT IT WRITES ─────────────────────────────────────────────────────────────────────
//
//   <out>/capture.json   parameters, providers, window, counts, timings
//   <out>/blocks.jsonl   one line per slot: header and EVERY transaction (votes included)
//   <out>/results.jsonl  the recorder's line for each transaction sent to it
//   <out>/traces/<sig>/  the trace of each transaction whose verdict is `match`
//
// ── --program: A SCOPED CAPTURE, AND WHY SCOPING IS SAFE ───────────────────────────────
//
// Holding every account mainnet touches needs ~35,000 new account reads a minute, about
// ten times what the free RPCs answer (sol-capture-warmth.*.json). With `--program` given,
// only transactions that name one of those programs have their accounts read. Every
// other non-vote transaction is STILL sent to the replay: it is refused for want of
// accounts, and the refusal evicts any held account it writes. So scoping narrows what
// the capture can trace, never what it must account for — a held account written
// outside the scope is dropped, not silently kept stale.
//
// Votes are enumerated but not replayed: they are the consensus machinery, they touch
// only vote accounts, and holding ~1,000 vote accounts per slot would spend the account
// budget on transactions no one debugs. They are recorded in blocks.jsonl as such.

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { appendFileSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

const args = process.argv.slice(2);
const opt = {
  blockRpc: 'https://solana-rpc.publicnode.com',
  accountRpcs: [],
  featureRpc: 'https://api.mainnet-beta.solana.com',
  recorder: null,
  slots: 50,
  out: null,
  keepDivergent: false,
  concurrency: 8,
  programs: new Set(),
};
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--block-rpc') opt.blockRpc = args[++i];
  else if (a === '--account-rpc') opt.accountRpcs.push(parseAccountRpc(args[++i]));
  else if (a === '--feature-rpc') opt.featureRpc = args[++i];
  else if (a === '--recorder') opt.recorder = args[++i];
  else if (a === '--slots') opt.slots = Number(args[++i]);
  else if (a === '--out') opt.out = resolve(args[++i]);
  else if (a === '--keep-divergent') opt.keepDivergent = true;
  else if (a === '--concurrency') opt.concurrency = Number(args[++i]);
  else if (a === '--program') opt.programs.add(args[++i]);
  else { console.error(`unknown argument ${a}`); process.exit(2); }
}
if (!opt.recorder || !opt.out) {
  console.error('--recorder and --out are required');
  process.exit(2);
}
if (opt.accountRpcs.length === 0) {
  opt.accountRpcs.push(parseAccountRpc('https://api.mainnet-beta.solana.com,100'));
  opt.accountRpcs.push(parseAccountRpc('https://solana-rpc.publicnode.com,10'));
}

/** `url,keysPerCall` — publicnode allows 10 keys per getMultipleAccounts, the protocol 100. */
function parseAccountRpc(s) {
  const [url, per] = s.split(',');
  return { url, perCall: Number(per || 100), calls: 0, failed: 0 };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function rpc(url, method, params) {
  for (let attempt = 0; attempt < 8; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(60_000),
      });
      if (res.status === 429 || res.status >= 500) { await sleep(500 * (attempt + 1)); continue; }
      const body = await res.json();
      if (body.error?.code === 429 || body.error?.code === -32005) { await sleep(500 * (attempt + 1)); continue; }
      return body;
    } catch { await sleep(500 * (attempt + 1)); }
  }
  return { error: { code: 'gave-up', message: `${method}: no answer after 8 attempts` } };
}

const VOTE = 'Vote111111111111111111111111111111111111111';
const UPGRADEABLE = 'BPFLoaderUpgradeab1e11111111111111111111111';
const SYSVARS = [
  'SysvarC1ock11111111111111111111111111111111', 'SysvarRent111111111111111111111111111111111',
  'SysvarEpochSchedu1e111111111111111111111111', 'SysvarS1otHashes111111111111111111111111111',
  'SysvarStakeHistory1111111111111111111111111', 'SysvarEpochRewards1111111111111111111111111',
  'SysvarLastRestartS1ot1111111111111111111111',
];
// Programs the runtime provides itself; the recorder does not need them held.
const RUNTIME = new Set([
  '11111111111111111111111111111111', VOTE, 'Stake11111111111111111111111111111111111111',
  'ComputeBudget111111111111111111111111111111', 'AddressLookupTab1e1111111111111111111111111',
  UPGRADEABLE, 'BPFLoader2111111111111111111111111111111111', 'BPFLoader1111111111111111111111111111111111',
  'LoaderV411111111111111111111111111111111111', 'Config1111111111111111111111111111111111111',
  'Ed25519SigVerify111111111111111111111111111', 'KeccakSecp256k11111111111111111111111111111',
  'Secp256r1SigVerify1111111111111111111111111', 'ZkE1Gama1Proof11111111111111111111111111111',
  'NativeLoader1111111111111111111111111111111', 'Feature111111111111111111111111111111111111',
]);
const isRuntime = (k) => RUNTIME.has(k) || k.startsWith('Sysvar');
const inScope = (keys) => opt.programs.size === 0 || keys.some((k) => opt.programs.has(k));

function writableKeys(tx) {
  const m = tx.transaction.message;
  const h = m.header;
  const n = m.accountKeys.length;
  const out = [];
  m.accountKeys.forEach((k, i) => {
    const signed = i < h.numRequiredSignatures;
    const w = signed ? i < h.numRequiredSignatures - h.numReadonlySignedAccounts
      : i < n - h.numReadonlyUnsignedAccounts;
    if (w) out.push(k);
  });
  return [...out, ...(tx.meta?.loadedAddresses?.writable ?? [])];
}

function toEntry(key, v, readAt) {
  return v === null
    ? { pubkey: key, lamports: 0, owner: '11111111111111111111111111111111', executable: false, rentEpoch: 0, data: '', readAtSlot: readAt }
    : { pubkey: key, lamports: v.lamports, owner: v.owner, executable: v.executable, rentEpoch: Number(v.rentEpoch ?? 0) || 0, data: v.data[0], readAtSlot: readAt };
}

// ── the recorder, as a child process speaking replay-stream ───────────────────────────

mkdirSync(opt.out, { recursive: true });
for (const f of ['blocks.jsonl', 'results.jsonl']) rmSync(join(opt.out, f), { force: true });
const child = spawn(opt.recorder, ['replay-stream', '--out-dir', opt.out], { stdio: ['pipe', 'pipe', 'inherit'] });
const answers = createInterface({ input: child.stdout });
const waiting = [];
answers.on('line', (l) => { const w = waiting.shift(); if (w) w(JSON.parse(l)); });
child.on('exit', (code) => { if (waiting.length) { console.error(`recorder exited (${code}) with ${waiting.length} operation(s) unanswered`); process.exit(1); } });
function send(op) {
  return new Promise((res) => { waiting.push(res); child.stdin.write(JSON.stringify(op) + '\n'); });
}

// ── the account budget: staged reads and the providers that answer them ───────────────

/** key -> 'held' | 'pending' | {readAt, entry} (staged) */
const state = new Map();
const pending = new Set();
const staged = [];
/** key -> the slot its latest read was taken at; carried into results for diagnosis. */
const readAtOf = new Map();
let accountCalls = 0;

async function fetchPending() {
  const keys = [...pending];
  if (keys.length === 0) return;
  for (const k of keys) pending.delete(k);
  // Spread the keys over the providers in proportion to what each call can carry.
  const jobs = [];
  let p = 0;
  for (let i = 0; i < keys.length;) {
    const prov = opt.accountRpcs[p++ % opt.accountRpcs.length];
    jobs.push({ prov, keys: keys.slice(i, i + prov.perCall) });
    i += prov.perCall;
  }
  let next = 0;
  const programdata = [];
  await Promise.all(Array.from({ length: opt.concurrency }, async () => {
    while (next < jobs.length) {
      const { prov, keys: ks } = jobs[next++];
      prov.calls++; accountCalls++;
      const r = await rpc(prov.url, 'getMultipleAccounts', [ks, { encoding: 'base64', commitment: 'confirmed' }]);
      if (!r.result) {
        prov.failed++;
        for (const k of ks) { state.delete(k); }
        continue;
      }
      const at = r.result.context.slot;
      r.result.value.forEach((v, i) => {
        const entry = toEntry(ks[i], v, at);
        staged.push({ readAt: at, entry });
        readAtOf.set(ks[i], at);
        state.set(ks[i], 'staged');
        if (v && v.executable && v.owner === UPGRADEABLE) {
          const data = Buffer.from(v.data[0], 'base64');
          if (data.length >= 36 && data.readUInt32LE(0) === 2) programdata.push(base58(data.subarray(4, 36)));
        }
      });
    }
  }));
  for (const k of programdata) if (!state.has(k)) { state.set(k, 'pending'); pending.add(k); }
}

/** Hands the replay every staged read taken BEFORE `slot` (the ordering rule above). */
async function release(slot) {
  const ready = [];
  for (let i = staged.length - 1; i >= 0; i--) {
    if (staged[i].readAt < slot) { ready.push(staged[i].entry); staged.splice(i, 1); }
  }
  if (ready.length === 0) return;
  // Oldest read first, so an account read twice (evicted and read again) ends on its
  // newest state.
  ready.sort((a, b) => a.readAtSlot - b.readAtSlot);
  for (const e of ready) state.set(e.pubkey, 'held');
  await send({ op: 'accounts', accounts: ready });
}

const ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
function base58(bytes) {
  let n = BigInt('0x' + Buffer.from(bytes).toString('hex'));
  let s = '';
  while (n > 0n) { s = ALPHABET[Number(n % 58n)] + s; n /= 58n; }
  for (const b of bytes) { if (b === 0) s = '1' + s; else break; }
  return s;
}

// ── init: the cluster's sysvars and feature accounts ──────────────────────────────────

const t0 = Date.now();
const features = await rpc(opt.featureRpc, 'getProgramAccounts', ['Feature111111111111111111111111111111111111', { encoding: 'base64' }]);
if (!features.result) { console.error('feature accounts not served:', JSON.stringify(features.error)); process.exit(1); }
const featureEntries = features.result.map(({ pubkey, account }) => {
  const d = Buffer.from(account.data[0], 'base64');
  return { id: pubkey, activatedAt: d[0] === 1 && d.length >= 9 ? Number(d.readBigUInt64LE(1)) : null };
});
const sv = await rpc(opt.featureRpc, 'getMultipleAccounts', [SYSVARS, { encoding: 'base64', commitment: 'confirmed' }]);
if (!sv.result) { console.error('sysvars not served:', JSON.stringify(sv.error)); process.exit(1); }
const sysvarEntries = sv.result.value.map((v, i) => v && toEntry(SYSVARS[i], v, sv.result.context.slot)).filter(Boolean);
const init = await send({ op: 'init', sysvars: sysvarEntries, features: featureEntries });
if (!init.ok) { console.error('recorder refused init', init); process.exit(1); }

// ── the window ────────────────────────────────────────────────────────────────────────

// ── warm start ─────────────────────────────────────────────────────────────────────────
//
// An account is replayable only from its second use after it is read, so a scoped
// capture that learns its programs' accounts from the window itself loses the window's
// opening slots. Before the window opens, the accounts named by each program's most
// recent transactions (and the program accounts themselves) are read; the window then
// starts after the slot those reads were taken at.
if (opt.programs.size) {
  for (const program of opt.programs) {
    if (!state.has(program)) { state.set(program, 'pending'); pending.add(program); }
    const r = await rpc(opt.blockRpc, 'getSignaturesForAddress', [program, { limit: 40, commitment: 'confirmed' }]);
    await Promise.all((r.result ?? []).map(async ({ signature }) => {
      const t = await rpc(opt.blockRpc, 'getTransaction', [signature, { encoding: 'json', maxSupportedTransactionVersion: 1, commitment: 'confirmed' }]);
      if (!t.result) return;
      const keys = [...t.result.transaction.message.accountKeys, ...(t.result.meta?.loadedAddresses?.writable ?? []), ...(t.result.meta?.loadedAddresses?.readonly ?? [])];
      for (const k of keys) if (!isRuntime(k) && !state.has(k)) { state.set(k, 'pending'); pending.add(k); }
    }));
  }
  while (pending.size) await fetchPending();
  console.error(`warm start: ${staged.length} account(s) read before the window`);
}
// The window opens right after the OLDEST warm-start read, not at the head: every block
// after a read must be replayed, or the held account misses whatever those blocks did to
// it. (Opening at the head lost the slots between the reads and the head; the first
// verdicts of that window came back divergent, cause prestate, a wallet a few fees too
// rich — the check caught it.)
const head = staged.length
  ? Math.min(...staged.map((x) => x.readAt))
  : (await rpc(opt.blockRpc, 'getSlot', [{ commitment: 'confirmed' }])).result;
const first = head + 1;
const counts = { slots: 0, skipped: 0, transactions: 0, votes: 0, sent: 0, notExecuted: 0, match: 0, divergent: 0, unchecked: 0, evictions: 0 };
const BLOCK = (enc) => ({ maxSupportedTransactionVersion: 1, transactionDetails: 'full', rewards: false, encoding: enc, commitment: 'confirmed' });

// ── the head watcher ──────────────────────────────────────────────────────────────────
//
// The replay below trails the chain: executing a slot's transactions takes longer than
// the 400 ms the cluster takes to produce one. If accounts were only queued when the
// replay REACHED the block naming them, every read would land far after that block and
// stay staged, unusable, until the replay caught up to the read. So a second loop
// watches the HEAD and queues every account a new block names as the block appears. The
// read then lands a few slots after the account's first use, which is the irreducible
// cost of the route: an account's first transaction in the window is never replayable,
// and every later one can be.
let watching = true;
let watchedTo = head;
// Blocks at the head are fetched several at a time: one at a time, the watcher alone
// fell behind the chain, and every read it queued landed tens to hundreds of slots after
// the transaction that first needed it (measured: results.jsonl `missingState`).
const watchConcurrency = 4;
// With a scope, the head is watched through each program's own signature list instead:
// getSignaturesForAddress + getTransaction cost a few calls per in-scope transaction,
// where a block costs megabytes, so the reads land within a few slots of first use.
const lastSig = new Map();
const sigWatcher = async () => {
  while (watching) {
    for (const program of opt.programs) {
      const r = await rpc(opt.blockRpc, 'getSignaturesForAddress', [program, { limit: 100, commitment: 'confirmed', ...(lastSig.has(program) ? { until: lastSig.get(program) } : {}) }]);
      const sigs = (r.result ?? []).filter((x) => x.slot > head);
      if (r.result?.length) lastSig.set(program, r.result[0].signature);
      await Promise.all(sigs.map(async ({ signature }) => {
        const t = await rpc(opt.blockRpc, 'getTransaction', [signature, { encoding: 'json', maxSupportedTransactionVersion: 1, commitment: 'confirmed' }]);
        if (!t.result) return;
        const keys = [...t.result.transaction.message.accountKeys, ...(t.result.meta?.loadedAddresses?.writable ?? []), ...(t.result.meta?.loadedAddresses?.readonly ?? [])];
        for (const k of keys) if (!isRuntime(k) && !state.has(k)) { state.set(k, 'pending'); pending.add(k); }
      }));
    }
    const tip = (await rpc(opt.blockRpc, 'getSlot', [{ commitment: 'confirmed' }])).result;
    if (tip) watchedTo = tip;
    await sleep(300);
  }
};
const watcher = opt.programs.size ? sigWatcher() : (async () => {
  while (watching) {
    const tip = (await rpc(opt.blockRpc, 'getSlot', [{ commitment: 'confirmed' }])).result ?? watchedTo;
    const slots = [];
    for (let s = watchedTo + 1; s <= tip && slots.length < watchConcurrency * 4; s++) slots.push(s);
    let next = 0;
    await Promise.all(Array.from({ length: watchConcurrency }, async () => {
      while (next < slots.length && watching) {
        const s = slots[next++];
        const b = await rpc(opt.blockRpc, 'getBlock', [s, { ...BLOCK('json'), transactionDetails: 'accounts' }]);
        for (const t of b.result?.transactions ?? []) {
          const keys = t.transaction.accountKeys.map((x) => x.pubkey);
          if (keys.includes(VOTE) || !inScope(keys)) continue;
          for (const k of keys) if (!isRuntime(k) && !state.has(k)) { state.set(k, 'pending'); pending.add(k); }
        }
      }
    }));
    if (slots.length) watchedTo = slots[slots.length - 1];
    else await sleep(150);
  }
})();
// The account reads run on their own, so neither the watcher nor the replay waits on them.
const fetcher = (async () => {
  while (watching) {
    if (pending.size) await fetchPending(); else await sleep(50);
  }
})();

for (let slot = first; slot < first + opt.slots; slot++) {
  // Wait for the slot to be confirmed, so the block is the cluster's.
  for (;;) {
    const tip = (await rpc(opt.blockRpc, 'getSlot', [{ commitment: 'confirmed' }])).result;
    if (tip >= slot) break;
    await sleep(200);
  }
  const [bj, bb] = await Promise.all([rpc(opt.blockRpc, 'getBlock', [slot, BLOCK('json')]),
    rpc(opt.blockRpc, 'getBlock', [slot, BLOCK('base64')])]);
  counts.slots++;
  if (!bj.result || !bb.result) {
    counts.skipped++;
    appendFileSync(join(opt.out, 'blocks.jsonl'), JSON.stringify({ slot, skipped: true, error: bj.error ?? bb.error }) + '\n');
    continue;
  }
  await release(slot);
  const rows = [];
  for (let i = 0; i < bj.result.transactions.length; i++) {
    const t = bj.result.transactions[i];
    const sig = t.transaction.signatures[0];
    const keys = [...t.transaction.message.accountKeys, ...(t.meta?.loadedAddresses?.writable ?? []),
      ...(t.meta?.loadedAddresses?.readonly ?? [])];
    const vote = t.transaction.message.accountKeys.includes(VOTE);
    counts.transactions++;
    const row = { signature: sig, index: i, vote, err: t.meta?.err ?? null, fee: t.meta?.fee,
      computeUnitsConsumed: t.meta?.computeUnitsConsumed, costUnits: t.meta?.costUnits, version: t.version ?? 'legacy',
      accounts: keys.length };
    rows.push(row);
    if (vote) { counts.votes++; continue; }
    // A transaction outside the scope that writes nothing the replay holds can change
    // nothing the replay depends on, so it is not sent. One that writes a held account
    // IS sent: its refusal is what evicts that account.
    row.inScope = inScope(keys);
    if (!row.inScope && !writableKeys(t).some((k) => state.get(k) === 'held')) {
      row.result = 'not-sent';
      continue;
    }
    counts.sent++;
    const res = await send({
      op: 'tx', signature: sig, slot, indexInBlock: i, blockTime: bj.result.blockTime,
      wire: bb.result.transactions[i].transaction[0], meta: t.meta, trace: true,
    });
    if (!res.executed && typeof res.reason === 'string') {
      // Where each missing account stood on the capture's side: the refusal is the
      // replay's, and this says whether the capture had read it yet, and when.
      const missing = (res.reason.split(': ').pop() ?? '').split(', ').filter(Boolean);
      res.missingState = missing.map((k) => ({ k, state: state.get(k) ?? 'unseen', readAt: readAtOf.get(k) ?? null }));
    }
    appendFileSync(join(opt.out, 'results.jsonl'), JSON.stringify(res) + '\n');
    const status = res.executed ? res.verdict.status : 'not-executed';
    if (status === 'match') counts.match++;
    else {
      if (status === 'not-executed') counts.notExecuted++;
      else counts[status]++;
      counts.evictions += res.evicted ?? 0;
      if (res.trace && !opt.keepDivergent) rmSync(join(opt.out, 'traces', sig), { recursive: true, force: true });
      // What it wrote is no longer held: read it again.
      // The replay says which accounts it stopped holding (a wallet whose post-state
      // the chain's record states is carried, not evicted); read exactly those again.
      for (const k of res.evictedKeys ?? []) state.delete(k);
    }
    row.result = status;
    if (row.inScope) for (const k of keys) if (!isRuntime(k) && !state.has(k)) { state.set(k, 'pending'); pending.add(k); }
  }
  appendFileSync(join(opt.out, 'blocks.jsonl'), JSON.stringify({
    slot, blockhash: bj.result.blockhash, parentSlot: bj.result.parentSlot, blockTime: bj.result.blockTime,
    blockHeight: bj.result.blockHeight, previousBlockhash: bj.result.previousBlockhash, transactions: rows,
  }) + '\n');
  const tip = (await rpc(opt.blockRpc, 'getSlot', [{ commitment: 'confirmed' }])).result;
  console.error(`slot ${slot}: ${counts.match} match / ${counts.divergent} divergent / ${counts.notExecuted} refused of ${counts.sent} sent; replay lag ${tip - slot}; watcher lag ${tip - watchedTo}; pending ${pending.size}; staged ${staged.length}`);
}

watching = false;
await watcher;
await fetcher;
child.stdin.end();
await new Promise((r) => child.on('close', r));
writeFileSync(join(opt.out, 'capture.json'), JSON.stringify({
  format: 'blocktracer/sol-capture@1',
  tool: 'tools/chain/capture-sol-window.mjs',
  capturedAt: new Date(t0).toISOString(),
  wallSeconds: Math.round((Date.now() - t0) / 1000),
  window: { firstSlot: first, lastSlot: first + opt.slots - 1, slots: opt.slots },
  providers: { blocks: opt.blockRpc, features: opt.featureRpc,
    accounts: opt.accountRpcs.map(({ url, perCall, calls, failed }) => ({ url, perCall, calls, failed })) },
  prestateRoute: 'forward-chained-capture',
  scope: opt.programs.size ? [...opt.programs] : 'all',
  counts,
}, null, 2) + '\n');
console.error(JSON.stringify(counts));
