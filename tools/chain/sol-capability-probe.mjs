#!/usr/bin/env node
// sol-capability-probe.mjs — WHERE, PER PROVIDER AND PER DEPTH, A SOLANA TRANSACTION'S
// PRE-EXECUTION STATE IS OBTAINABLE. Recorder-Solana CXP-SOL-1.
//
//   node tools/chain/sol-capability-probe.mjs \
//     --provider solana-foundation=https://api.mainnet-beta.solana.com \
//     --provider publicnode=https://solana-rpc.publicnode.com \
//     --out tools/chain/measurements/sol-capability-matrix.json
//
// ── EVERY CELL IS A FETCH ──────────────────────────────────────────────────────────────
//
// test_the_capability_matrix_is_probed_not_declared: a cell is written only from an
// answer this run received at that depth. A cell with no successful fetch reads
// `not-served` with the error the provider gave; nothing is inherited from a provider's
// documentation. The CONTROL is the transaction-metadata cell at the same depth from the
// same provider: where it is `served` and the account-state cell is not, the negative is
// attributable to the capability, not to an unreachable endpoint.
//
// ── WHAT "ACCOUNT STATE AT A DEPTH" IS TESTED BY ───────────────────────────────────────
//
// Solana's JSON-RPC has no parameter naming a past slot for an account read. The probe
// therefore asks the only questions the API admits and records what came back:
//
//   * `getMultipleAccounts` with `minContextSlot` set to the target slot. The answer's
//     `context.slot` is the slot the state was read at. A provider that served state AT
//     the target would answer with `context.slot == target`; one that serves current state
//     answers with the head. The cell records both slots, and is `served` only on equality.
//   * the transaction's own metadata, scanned for any member carrying account DATA (as
//     opposed to lamports or token amounts). Members are listed as found, so a provider
//     that adds a pre-account snapshot shows up as a new member rather than being missed
//     by a list of expected names.
//
// The floor of Chain-Support-Matrix.md §1.3 ("July 2025") is converted to a slot by
// bisecting `getBlockTime`, so the matrix carries a number a Debug button can enforce.

import { writeFileSync } from 'node:fs';

const args = process.argv.slice(2);
const providers = [];
let out = null;
let floorDate = '2025-07-01T00:00:00Z';
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--provider') {
    const [name, ...rest] = args[++i].split('=');
    providers.push({ name, url: rest.join('=') });
  } else if (args[i] === '--out') out = args[++i];
  else if (args[i] === '--floor-date') floorDate = args[++i];
  else { console.error(`unknown argument ${args[i]}`); process.exit(1); }
}
if (providers.length === 0) {
  console.error('at least one --provider name=url is required');
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** One JSON-RPC call; retries 429s and transport errors, returns {result} or {error}. */
async function rpc(url, method, params) {
  for (let attempt = 0; attempt < 6; attempt++) {
    try {
      const res = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(30_000),
      });
      if (res.status === 429 || res.status >= 500) { await sleep(1500 * (attempt + 1)); continue; }
      const text = await res.text();
      let body;
      try { body = JSON.parse(text); } catch { return { error: { code: `http-${res.status}`, message: text.slice(0, 200) } }; }
      if (body.error && body.error.code === 429) { await sleep(1500 * (attempt + 1)); continue; }
      await sleep(120);
      return body.error ? { error: body.error } : { result: body.result };
    } catch (e) {
      if (attempt === 5) return { error: { code: 'transport', message: String(e.message || e) } };
      await sleep(1000 * (attempt + 1));
    }
  }
  return { error: { code: 'rate-limited', message: 'gave up after 6 attempts' } };
}

const BLOCK_OPTS = { maxSupportedTransactionVersion: 1, transactionDetails: 'full', rewards: false, encoding: 'json', commitment: 'finalized' };
const VOTE_PROGRAM = 'Vote111111111111111111111111111111111111111';

/** Metadata members that carry no account data: everything else found is listed as a candidate. */
const KNOWN_META = new Set(['computeUnitsConsumed', 'costUnits', 'err', 'fee', 'innerInstructions',
  'loadedAddresses', 'logMessages', 'postBalances', 'postTokenBalances', 'preBalances',
  'preTokenBalances', 'returnData', 'rewards', 'status']);

/** The first produced slot at or above `slot`, with its block (skipped slots are walked past). */
async function blockAtOrAbove(url, slot, limit = 20) {
  let lastErr = null;
  for (let s = slot; s < slot + limit; s++) {
    const r = await rpc(url, 'getBlock', [s, BLOCK_OPTS]);
    if (r.result) return { slot: s, block: r.result };
    lastErr = r.error;
    // -32007 / -32009: skipped slot or missing in long-term storage; walk on. Anything else
    // is the provider refusing the range, and walking further would only repeat it.
    if (![-32007, -32009, -32004].includes(r.error?.code)) break;
  }
  return { slot, error: lastErr };
}

function firstNonVote(block) {
  return block.transactions.find((t) =>
    !t.transaction.message.accountKeys.includes(VOTE_PROGRAM) && t.meta);
}

async function probeCell(p, head, depth) {
  const target = Math.max(0, head - depth);
  const cell = { depth, targetSlot: target };
  const b = await blockAtOrAbove(p.url, target);
  if (!b.block) {
    cell.block = { status: 'not-served', error: b.error };
    cell.transactionMetadata = { status: 'not-served', reason: 'no block at this depth' };
    cell.accountState = { status: 'not-served', reason: 'no block at this depth' };
    cell.addressHistory = { status: 'not-probed', reason: 'no transaction at this depth' };
    return cell;
  }
  cell.slot = b.slot;
  cell.blockTime = b.block.blockTime;
  cell.block = { status: 'served', transactions: b.block.transactions.length };
  const tx = firstNonVote(b.block);
  if (!tx) {
    cell.transactionMetadata = { status: 'not-probed', reason: 'block holds only vote transactions' };
    cell.accountState = { status: 'not-probed', reason: 'block holds only vote transactions' };
    cell.addressHistory = { status: 'not-probed', reason: 'block holds only vote transactions' };
    return cell;
  }
  const sig = tx.transaction.signatures[0];
  cell.signature = sig;
  const t = await rpc(p.url, 'getTransaction', [sig, { maxSupportedTransactionVersion: 1, encoding: 'json', commitment: 'finalized' }]);
  if (!t.result) {
    cell.transactionMetadata = { status: 'not-served', error: t.error };
  } else {
    const meta = t.result.meta || {};
    const members = Object.keys(meta).sort();
    cell.transactionMetadata = {
      status: 'served',
      members,
      lamportBalances: Array.isArray(meta.preBalances) && Array.isArray(meta.postBalances),
      tokenBalances: Array.isArray(meta.preTokenBalances),
      logMessages: Array.isArray(meta.logMessages) ? meta.logMessages.length : null,
      logTruncated: Array.isArray(meta.logMessages) && meta.logMessages.some((l) => l === 'Log truncated'),
      computeUnitsConsumed: typeof meta.computeUnitsConsumed === 'number',
      innerInstructions: Array.isArray(meta.innerInstructions),
      returnData: meta.returnData !== undefined,
      unrecognisedMembers: members.filter((m) => !KNOWN_META.has(m)),
    };
  }
  // Account state at the target: the one question the API admits.
  const keys = tx.transaction.message.accountKeys.slice(0, 8);
  const a = await rpc(p.url, 'getMultipleAccounts', [keys, { encoding: 'base64', commitment: 'finalized', minContextSlot: b.slot }]);
  if (a.result) {
    const readAt = a.result.context.slot;
    cell.accountState = readAt === b.slot
      ? { status: 'served', readAtSlot: readAt }
      : { status: 'not-served', reason: 'state read at a later slot than the transaction', readAtSlot: readAt, slotsLater: readAt - b.slot };
  } else {
    cell.accountState = { status: 'not-served', error: a.error };
  }
  // Address history before this transaction: getSignaturesForAddress needs no index.
  const writable = tx.transaction.message.accountKeys[0];
  const h = await rpc(p.url, 'getSignaturesForAddress', [writable, { before: sig, limit: 5, commitment: 'finalized' }]);
  cell.addressHistory = h.result
    ? { status: 'served', address: writable, earlier: h.result.length }
    : { status: 'not-served', error: h.error };
  return cell;
}

/** §1.3's floor date as a slot: the first slot whose block time is at or after the date. */
async function floorSlot(url, head, isoDate) {
  const want = Math.floor(Date.parse(isoDate) / 1000);
  const timeOf = async (s) => {
    for (let k = 0; k < 40; k++) {
      const r = await rpc(url, 'getBlockTime', [s + k]);
      if (typeof r.result === 'number') return { slot: s + k, time: r.result };
      if (r.error && ![-32007, -32009, -32004].includes(r.error.code)) return { error: r.error };
    }
    return { error: { message: 'no block time in 40 slots' } };
  };
  let lo = 0, hi = head;
  const steps = [];
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    const t = await timeOf(mid);
    if (t.error) return { status: 'unverified', reason: 'block time not served during bisection', error: t.error };
    steps.push(t.slot);
    if (t.time >= want) hi = mid; else lo = mid;
  }
  const t = await timeOf(hi);
  return { status: 'measured', date: isoDate, slot: t.slot, blockTime: t.time, bisectionSteps: steps.length };
}

const DEPTHS = [0, 150, 10_000, 100_000, 432_000, 2_000_000, 10_000_000, 50_000_000, 100_000_000, 200_000_000, 400_000_000];

const result = {
  format: 'blocktracer/sol-capability-matrix@1',
  measuredOn: new Date().toISOString(),
  measuredBy: 'tools/chain/sol-capability-probe.mjs',
  depthUnit: 'slots below the provider\'s finalized head at probe time',
  providers: [],
};

for (const p of providers) {
  const hr = await rpc(p.url, 'getSlot', [{ commitment: 'finalized' }]);
  if (!hr.result) { result.providers.push({ name: p.name, url: p.url, status: 'unreachable', error: hr.error }); continue; }
  const head = hr.result;
  const first = await rpc(p.url, 'getFirstAvailableBlock', []);
  const entry = { name: p.name, url: p.url, finalizedHead: head, firstAvailableBlock: first.result ?? null, cells: [] };
  for (const d of DEPTHS) {
    const cell = await probeCell(p, head, d);
    entry.cells.push(cell);
    console.error(`${p.name} depth ${d}: block=${cell.block.status} meta=${cell.transactionMetadata.status} state=${cell.accountState.status}`);
  }
  // A provider that has pruned its ledger cannot be bisected below its first block; its
  // own floor is that block, and the §1.3 date is left to a provider that holds it.
  entry.floor = (first.result ?? 0) > 0
    ? { status: 'provider-pruned', providerFloorSlot: first.result, date: floorDate,
        reason: 'the provider serves no block below providerFloorSlot, so the date cannot be bisected here' }
    : await floorSlot(p.url, head, floorDate);
  result.providers.push(entry);
}

const json = JSON.stringify(result, null, 2) + '\n';
if (out) writeFileSync(out, json); else process.stdout.write(json);
