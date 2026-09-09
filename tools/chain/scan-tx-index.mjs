#!/usr/bin/env node
// scan-tx-index.mjs — MEASURE how many transactions this chain puts at an index other than
// zero, over a range someone names, on a date.
//
//   node tools/chain/scan-tx-index.mjs --url https://aztec-testnet.drpc.org --depth 2000
//   node tools/chain/scan-tx-index.mjs --url … --from 60000 --to 62000 --out scan.json
//
// ── WHY THIS TOOL EXISTS ───────────────────────────────────────────────────────────────
//
// The pipeline refuses every transaction that is not first in its block, because the
// historical-state mechanism answers reads at the settling block's PARENT and that is only
// the state transaction 0 saw. The standing justification for that costing nothing is a
// sentence: "a sample of sixty-one mainnet transactions were all at index 0".
//
// A sentence is not a measurement. That one has no date on it, no stated range, and no way
// for a reader to find out whether it is still true — and it is a claim about TRAFFIC, which
// is the most changeable thing about a chain. A single busy block, one contract that starts
// batching, one sequencer configuration change, and `not-first-in-block` goes from a branch
// nobody has seen fire to the reason a visible fraction of the chain has no trace.
//
// So the claim is re-taken rather than quoted. This tool is committed, it names its
// population, and its output carries the moment it ran.
//
// ── WHAT MAKES THE ZERO A MEASUREMENT AND NOT A SILENCE ────────────────────────────────
//
// A scan that finds no non-zero index and a scan that finds no transactions at all print the
// same headline, and only one of them is evidence. Aztec blocks are mostly empty — in a
// 50-block sample of testnet, four blocks carried any mana and none of those carried a
// transaction — so "0 transactions at index > 0" is the DEFAULT output of a broken scan.
//
// Three things therefore travel with every result and the tool refuses to state a verdict
// without them:
//
//   1. THE POPULATION, enumerated: how many blocks were REQUESTED, how many the node
//      actually SERVED, how many carried transactions, and how many transactions were seen.
//      A range the node did not serve is not a range that was empty.
//   2. THE PREFILTER CONTROL. Blocks are triaged by `header.totalManaUsed == 0`, which is a
//      DERIVATION about emptiness and not an observation of it. A rule only ever checked
//      where it predicts something is not checked at all, so a sample of the blocks the
//      prefilter calls empty is fetched WITH its body and required to hold no transactions.
//      If that control fails, the scan is void — it was skipping blocks that had content.
//   3. AN EXPLICIT VERDICT of `measured` or `no-population`. A run that saw zero
//      transactions reports `no-population` and exits non-zero. It does not report that
//      every transaction was at index 0, because it did not see one.
//
// ── WHICH NETWORK IT CAN BE POINTED AT, AND A NOTE WITH A DATE ON IT ───────────────────
//
// The default is TESTNET, and that is not a preference. On 2026-09-09 the mainnet endpoint
// this repository's tooling names, `https://aztec.drpc.org`, answered every node method with
// either `-32601 does not exist/is not available` (`node_getBlockNumber`, `node_getBlock`,
// `node_getNodeInfo`) or `35 method is not available on free plan, please upgrade to paid
// plan` (`node_getBlockHeader`, `node_getProvenBlockNumber`, `node_getL2Tips`). The testnet
// endpoint served all of them. So a mainnet distribution cannot be taken from the free plan
// as things stand, and the tool says so by failing rather than by reporting an empty range:
// `getNodeInfo` refusing is a fact about the RUN, and the exit is 2 with no report written.
//
// Point it at whatever endpoint can answer. The population it prints names the endpoint, so
// a testnet reading is never mistakable for a mainnet one.
//
// ── WHAT IT DOES NOT DO ────────────────────────────────────────────────────────────────
//
// It does not replay, does not write a snapshot and does not need a runtime, an AVM or a
// `.ct` writer. It reads two node methods. That is deliberate: the measurement has to be
// cheap enough to re-run, or it becomes another sentence with an old date on it.

import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };
const flag = (n) => argv.includes(`--${n}`);

const url = arg('url', 'https://aztec-testnet.drpc.org');
const depth = Number(arg('depth', 1000));
const fromArg = arg('from', '');
const toArg = arg('to', '');
const out = arg('out', '');
const headerBatch = Number(arg('header-batch', 50));
const controlSample = Number(arg('control-sample', 12));
const pauseMs = Number(arg('pause-ms', 0));
const quiet = flag('quiet');

const note = (m) => { if (!quiet) console.error(`scan-tx-index: ${m}`); };
const sleep = (ms) => (ms > 0 ? new Promise((r) => setTimeout(r, ms)) : Promise.resolve());

let rpcId = 0;
let rpcCalls = 0;
let rpcFaults = 0;
async function rpc(method, params = []) {
  rpcCalls++;
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
    });
    if (!r.ok) { rpcFaults++; return { __err: `HTTP ${r.status}` }; }
    const j = await r.json();
    if (j.error) { rpcFaults++; return { __err: j.error.message ?? JSON.stringify(j.error) }; }
    return j.result;
  } catch (e) { rpcFaults++; return { __err: `fetch: ${e.message}` }; }
}

const isEmptyMana = (h) => /^0x0*$/.test(String(h?.header?.totalManaUsed ?? '0x0'));

/** Headers for `[from, to]`, in batches. Returns what the node SERVED, which is not
 *  necessarily what was asked for — the difference is part of the population statement. */
async function headers(from, to) {
  const got = new Map();
  for (let n = from; n <= to; n += headerBatch) {
    const limit = Math.min(headerBatch, to - n + 1);
    const batch = await rpc('node_getBlocks', [n, limit]);
    if (batch?.__err || !Array.isArray(batch)) {
      note(`headers ${n}..${n + limit - 1}: ${batch?.__err ?? 'not an array'}`);
      await sleep(pauseMs);
      continue;
    }
    for (const b of batch) if (typeof b?.number === 'number') got.set(b.number, b);
    await sleep(pauseMs);
  }
  return got;
}

/**
 * The verdict rule, extracted so it can be driven without a chain.
 *
 * THIS IS THE ASSERTION THAT KEEPS THE ZERO HONEST, and it has to be reachable offline for
 * the same reason `lib/replay.mjs`'s `decideOutcome` is: the arm that matters most —
 * `no-population` — is the one a live run against a busy chain will never take, so a suite
 * that only ever ran the scanner against a node would report green while never once
 * checking that an empty scan refuses to claim anything.
 *
 *   void            the prefilter control failed, or nothing was sampled to check it with.
 *                   The distribution is not the chain's and no reading may be taken from it.
 *   no-population   the control held and NOT ONE transaction was seen. "Every transaction
 *                   was at index 0" is vacuously true here and must not be said.
 *   measured        the control held and there were transactions to measure.
 *
 * `controlChecked > 0` is part of `controlHeld` on purpose: zero violations out of zero
 * samples is the same empty-set pass in miniature, one layer down.
 */
export function scanVerdict({ transactions, controlChecked, controlViolations }) {
  const controlHeld = (controlViolations?.length ?? 0) === 0 && controlChecked > 0;
  return {
    controlHeld,
    verdict: !controlHeld ? 'void' : transactions === 0 ? 'no-population' : 'measured',
  };
}

async function main() {
  const scannedAt = new Date().toISOString();
  const info = await rpc('node_getNodeInfo');
  if (info?.__err) {
    console.error(`scan-tx-index: the node refused getNodeInfo (${info.__err}). Nothing was `
      + `measured; this is a fact about the run and not about the chain.`);
    return 2;
  }
  const tip = await rpc('node_getBlockNumber');
  if (typeof tip !== 'number') {
    console.error(`scan-tx-index: the node did not serve a block number (${tip?.__err ?? tip}).`);
    return 2;
  }

  const to = toArg ? Number(toArg) : tip;
  const from = fromArg ? Number(fromArg) : Math.max(1, to - depth + 1);
  if (!(from >= 1 && to >= from)) {
    console.error(`scan-tx-index: refusing the range ${from}..${to}.`);
    return 2;
  }
  note(`tip ${tip}; scanning blocks ${from}..${to} (${to - from + 1} requested) at ${url}`);

  const served = await headers(from, to);
  const requested = to - from + 1;
  note(`${served.size} of ${requested} block headers served`);

  const candidates = [...served.values()].filter((b) => !isEmptyMana(b)).map((b) => b.number).sort((a, b) => a - b);
  const predictedEmpty = [...served.keys()].filter((n) => !candidates.includes(n)).sort((a, b) => a - b);
  note(`${candidates.length} blocks carry mana; ${predictedEmpty.length} predicted empty`);

  // ── the measurement ────────────────────────────────────────────────────────────────
  const byIndex = new Map();
  const nonZero = [];
  let blocksWithTransactions = 0;
  let transactions = 0;
  let unservedBodies = 0;
  for (const n of candidates) {
    const full = await rpc('node_getBlock', [n, { includeTransactions: true }]);
    if (full?.__err) { unservedBodies++; note(`block ${n}: body not served (${full.__err})`); await sleep(pauseMs); continue; }
    const effs = full?.body?.txEffects ?? [];
    if (effs.length) blocksWithTransactions++;
    for (const [i, eff] of effs.entries()) {
      transactions++;
      byIndex.set(i, (byIndex.get(i) ?? 0) + 1);
      if (i !== 0) nonZero.push({ txHash: eff.txHash, blockNumber: n, txIndexInBlock: i });
    }
    await sleep(pauseMs);
  }

  // ── the prefilter control ──────────────────────────────────────────────────────────
  // Evenly spaced rather than the first N: the first N of a contiguous range are all from
  // one moment of the chain's life, and a prefilter that fails only under load would be
  // sampled entirely where it works.
  const step = predictedEmpty.length > controlSample
    ? Math.floor(predictedEmpty.length / controlSample) : 1;
  const controlBlocks = [];
  for (let i = 0; i < predictedEmpty.length && controlBlocks.length < controlSample; i += step) {
    controlBlocks.push(predictedEmpty[i]);
  }
  let controlChecked = 0;
  const controlViolations = [];
  for (const n of controlBlocks) {
    const full = await rpc('node_getBlock', [n, { includeTransactions: true }]);
    if (full?.__err) { note(`control block ${n}: not served`); await sleep(pauseMs); continue; }
    controlChecked++;
    const effs = full?.body?.txEffects ?? [];
    if (effs.length) controlViolations.push({ blockNumber: n, transactions: effs.length });
    await sleep(pauseMs);
  }

  const { controlHeld, verdict } = scanVerdict({ transactions, controlChecked, controlViolations });

  const report = {
    format: 'blocktracer/tx-index-distribution@1',
    scannedAt,
    endpoint: url,
    nodeVersion: info?.nodeVersion ?? '',
    l1ChainId: info?.l1ChainId ?? null,
    rollupVersion: info?.rollupVersion ?? null,
    tip,
    // THE POPULATION, enumerated. Every number a reader needs to say what this scan looked
    // at, without any of them being inferable from the others.
    population: {
      blocksRequested: requested,
      blockRange: { from, to },
      blockHeadersServed: served.size,
      blocksCarryingMana: candidates.length,
      blockBodiesNotServed: unservedBodies,
      blocksWithTransactions,
      transactions,
    },
    prefilterControl: {
      rule: 'header.totalManaUsed == 0 predicts a block with no transactions',
      predictedEmpty: predictedEmpty.length,
      sampled: controlChecked,
      violations: controlViolations,
      held: controlHeld,
    },
    distribution: Object.fromEntries([...byIndex.entries()].sort((a, b) => a[0] - b[0])),
    maxIndexObserved: byIndex.size ? Math.max(...byIndex.keys()) : null,
    atIndexZero: byIndex.get(0) ?? 0,
    beyondIndexZero: transactions - (byIndex.get(0) ?? 0),
    // The ones the pipeline would refuse with `not-first-in-block`, listed rather than
    // counted: a count of one is a thing to argue about, a transaction hash is a thing to
    // go and look at.
    wouldBeRefused: nonZero,
    rpc: { calls: rpcCalls, faults: rpcFaults },
    verdict,
  };

  if (out) { writeFileSync(out, JSON.stringify(report, null, 1) + '\n'); note(`wrote ${out}`); }

  // ── the sentence, with its date and its population attached ────────────────────────
  const p = report.population;
  console.log(JSON.stringify(report, null, 1));
  if (verdict === 'void') {
    console.error(`\nVOID — the mana prefilter does not hold. ${controlViolations.length} of `
      + `${controlChecked} blocks it predicted were empty carried transactions, so the scan `
      + `was skipping blocks with content and its distribution is not the chain's.`);
    return 3;
  }
  if (verdict === 'no-population') {
    console.error(`\nNO POPULATION — ${p.blockHeadersServed} of ${p.blocksRequested} block `
      + `headers served over ${from}..${to}, ${p.blocksCarryingMana} carrying mana, and NOT `
      + `ONE TRANSACTION in any of them. This scan says nothing about the index distribution: `
      + `"every transaction was at index 0" is vacuously true of an empty set. Widen the `
      + `range or scan a busier chain.`);
    return 1;
  }
  console.error(`\nMEASURED at ${scannedAt} over blocks ${from}..${to} of ${url}\n`
    + `  population: ${p.transactions} transaction(s) in ${p.blocksWithTransactions} block(s), `
    + `from ${p.blockHeadersServed} of ${p.blocksRequested} headers served\n`
    + `  at index 0: ${report.atIndexZero}\n`
    + `  beyond index 0: ${report.beyondIndexZero}`
    + (report.beyondIndexZero
        ? `  ← the pipeline refuses these with not-first-in-block`
        : `  ← the refusal branch costs nothing OVER THIS POPULATION, on this date`)
    + `\n  prefilter control: ${controlChecked} predicted-empty block(s) fetched with bodies, `
    + `${controlViolations.length} violation(s)`);
  return 0;
}

// Run only when this file IS the program. It is also imported by `refusal-selftest.mjs`,
// which drives `scanVerdict` against recorded populations; an unguarded `main()` would make
// that import open a network connection.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().then((c) => process.exit(c)).catch((e) => {
    console.error(`scan-tx-index: ${e.stack ?? e.message}`);
    process.exit(2);
  });
}
