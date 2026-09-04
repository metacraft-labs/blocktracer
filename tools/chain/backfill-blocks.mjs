#!/usr/bin/env node
// Fill in a snapshot's BLOCK RECORD from the archive, for a range the capture
// left a hole in.
//
// ── Why this exists, and why it is not a second capture ──────────────────────
//
// `follow-chain.mjs` backfills the block record itself (see its §3), and it is
// right to: "a bounded catch-up is a performance choice; a hole is a wrong
// answer". But it accumulates the whole range in memory and saves ONCE, after
// the loop. Against a snapshot whose newest block was 63678 while the tip was
// 67058 that is one 3,380-block loop before the first write, and a watch that
// ends — a session closing, a supervisor re-arming, an operator stopping it —
// loses every row of it. That is exactly what happened to the 2026-09-02
// testnet watch: it caught twenty transactions and saved every one of them,
// and then wrote NOT ONE of the blocks they sit in. The snapshot it left has
// transactions at heights 67010-67055 and a block record that stops at 63678,
// which `ingest.nim` refuses with "the curated window … selected no block".
//
// THE HOLE IS REPAIRABLE AND THE RECORDING IS NOT, which is the whole reason
// this is a separate tool rather than a note to re-run the watch. §1's
// constraint is about BODIES: `getTxByHash` prunes at finalization and those
// transactions can never be replayed again — re-measured here, 0x20ed5b91…'s
// body is gone. But a block's header, its archive roots and its `txEffects`
// are ARCHIVAL and prune never, so every field of a block row is still exactly
// as readable today as it was during the watch. Re-fetching them invents
// nothing and re-derives nothing; it reads the same node method the follower
// would have read, and writes the same row shape.
//
// So this is a REPAIR of a record that was observed and dropped, not a capture
// of one that was missed. It writes no container, replays nothing, and cannot
// add a `replayed` outcome to anything — every transaction it discovers is
// recorded traceless, with the producer's own sentence about why, exactly as
// the follower records the ones it sees too late.
//
// ── The two rules it keeps ───────────────────────────────────────────────────
//
//   * IT NEVER TOUCHES A ROW THAT IS ALREADY THERE. A transaction the watch
//     caught and replayed keeps its outcome, its container and its recording;
//     this only adds heights and hashes the record is missing. Runs are
//     idempotent, and a second run over a range it already filled is a no-op.
//   * IT SAVES AS IT GOES (`--checkpoint`, default 100 blocks), which is the
//     defect it exists because of. An interrupted repair leaves a shorter
//     contiguous record, never a lost one.
//
// Usage:
//   node tools/chain/backfill-blocks.mjs --snapshot <dir> --from N --to M
//        [--url https://aztec-testnet.drpc.org] [--checkpoint 100] [--dry-run]

import { readFileSync, writeFileSync, renameSync } from 'node:fs';
import { join } from 'node:path';

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : dflt;
};
const flag = (name) => argv.includes(`--${name}`);

const snapshotDir = arg('snapshot', '');
const url = arg('url', '');
const from = Number(arg('from', 0));
const to = Number(arg('to', 0));
const checkpoint = Number(arg('checkpoint', 100));
const dryRun = flag('dry-run');

if (!snapshotDir || !from || !to || to < from) {
  console.error('usage: --snapshot <dir> --from N --to M [--url U] [--checkpoint N] [--dry-run]');
  process.exit(2);
}

const snapPath = join(snapshotDir, 'snapshot.json');
const snap = JSON.parse(readFileSync(snapPath, 'utf8'));
if (snap.format !== 'blocktracer/chain-snapshot@1') {
  console.error(`refusing: ${snapPath} is not a blocktracer/chain-snapshot@1`);
  process.exit(1);
}

// THE ENDPOINT IS THE SNAPSHOT'S OWN, and a mismatch is refused rather than
// merged. A block record half-read from one deployment and half from another
// would be a chain that never existed, and the hashes would not even disagree
// visibly — they would simply be someone else's.
const endpoint = url || snap.provenance?.endpoint;
if (!endpoint) {
  console.error('refusing: no --url and the snapshot names no provenance.endpoint');
  process.exit(1);
}
if (url && snap.provenance?.endpoint && url !== snap.provenance.endpoint) {
  console.error(`refusing: --url ${url} is not this snapshot's endpoint ` +
                `${snap.provenance.endpoint}`);
  process.exit(1);
}

let rpcId = 0;
async function rpc(method, params) {
  const res = await fetch(endpoint, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
  });
  if (!res.ok) throw new Error(`${method}: HTTP ${res.status}`);
  const body = await res.json();
  if (body.error) throw new Error(`${method}: ${body.error.message ?? 'rpc error'}`);
  return body.result;
}

// The same identity check `follow-chain.mjs` makes before it writes a row: a
// snapshot carries the rollup it was taken against, and a node that answers for
// a different one is not a source for this record.
const info = await rpc('node_getNodeInfo', []);
const rollup = info?.l1ContractAddresses?.rollupAddress;
if (snap.provenance?.rollupAddress && rollup &&
    String(rollup).toLowerCase() !== String(snap.provenance.rollupAddress).toLowerCase()) {
  console.error(`refusing: node serves rollup ${rollup}, snapshot was taken ` +
                `against ${snap.provenance.rollupAddress}`);
  process.exit(1);
}

const known = new Map(snap.blocks.map((b) => [b.number, b]));
const seen = new Set(snap.transactions.map((t) => t.txHash));
const before = { blocks: snap.blocks.length, transactions: snap.transactions.length };

function save() {
  if (dryRun) return;
  // Newest first, which is the order `follow-chain.mjs` keeps and therefore the
  // order every reader of this file already expects.
  snap.blocks.sort((a, b) => b.number - a.number);
  recount(snap);
  const tmp = `${snapPath}.tmp`;
  // INDENT 1, WHICH IS `follow-chain.mjs`'s `saveSnapshot` AND NOT A TASTE.
  // These files are 40,000 lines; a repair that re-indented one would land a
  // whole-file diff in which the fifty rows that actually changed cannot be
  // found, and a reviewer's only way to check that a frozen capture survived
  // is to read the diff.
  writeFileSync(tmp, JSON.stringify(snap, null, 1) + '\n');
  renameSync(tmp, snapPath);
}

function recount(s) {
  s.counts = {
    ...s.counts,
    blocks: s.blocks.length,
    blocksWithTransactions: s.blocks.filter((b) => b.transactions.length).length,
    transactions: s.transactions.length,
  };
}

let addedBlocks = 0;
let addedTxs = 0;
let sinceCheckpoint = 0;

for (let n = from; n <= to; n++) {
  if (known.has(n)) continue;
  const head = await rpc('node_getBlock', [n]);
  if (!head) {
    // A height the node does not serve is reported and skipped, never written
    // as an empty block: an invented row is indistinguishable from a real
    // block that settled nothing, and one of those two is a lie.
    console.error(`  block ${n}: not served, skipped`);
    continue;
  }
  const mana = String(head.header.totalManaUsed);
  const row = {
    number: n,
    hash: head.hash,
    timestamp: Number(head.header.globalVariables.timestamp),
    totalManaUsed: mana,
    coinbase: head.header.globalVariables.coinbase,
    feePerL2Gas: head.header.globalVariables.gasFees.feePerL2Gas,
    archiveRoot: head.archive.root,
    parentArchiveRoot: head.header.lastArchive.root,
    transactions: [],
  };
  if (!/^0x0*$/.test(mana)) {
    const full = await rpc('node_getBlock', [n, { includeTransactions: true }]);
    for (const [i, eff] of (full?.body?.txEffects ?? []).entries()) {
      row.transactions.push(eff.txHash);
      if (seen.has(eff.txHash)) continue;
      // Recorded traceless, with the reason, and never omitted — the explorer
      // has to be able to say why a visible transaction has no trace. The two
      // sentences are the follower's own, because they describe the same two
      // situations and a second wording of them would be a second thing to keep
      // true.
      const why = i !== 0
        ? { outcome: 'not-first-in-block',
            reason: `Replaying this transaction needs the state left by the `
              + `transaction before it in block ${n}, and the node does not serve `
              + `intra-block intermediate state. Only the first transaction in a `
              + `block can be re-executed from published data.` }
        : { outcome: 'pruned',
            reason: `The node still serves this transaction's effects but no longer `
              + `serves its body: getTxByHash prunes at the finalized tip and `
              + `getTxEffect does not. It was already below the replayable window `
              + `when this record was repaired, so it can no longer be `
              + `re-executed and no trace was recorded for it.` };
      snap.transactions.push({
        txHash: eff.txHash, blockNumber: n, txIndexInBlock: i,
        revertCode: eff.revertCode, transactionFee: eff.transactionFee,
        bodyRetained: false, effectVisible: true, firstInBlock: i === 0,
        observedAt: new Date().toISOString(), ...why,
      });
      seen.add(eff.txHash);
      addedTxs++;
    }
  }
  snap.blocks.push(row);
  known.set(n, row);
  addedBlocks++;
  if (++sinceCheckpoint >= checkpoint) {
    save();
    sinceCheckpoint = 0;
    console.error(`  … ${n}: +${addedBlocks} blocks, +${addedTxs} transactions`);
  }
}

save();

// The record's own contiguity, asserted over what was just written rather than
// assumed from the loop having run. This is the property the whole tool is for,
// and a range that still has a gap in it is worth saying out loud: the export
// will publish a block list around it without anything on the page admitting
// the missing heights.
const heights = snap.blocks.map((b) => b.number).sort((a, b) => a - b);
const gaps = [];
for (let i = 1; i < heights.length; i++) {
  if (heights[i] !== heights[i - 1] + 1) gaps.push([heights[i - 1], heights[i]]);
}

console.log(JSON.stringify({
  snapshot: snapshotDir,
  endpoint,
  range: [from, to],
  dryRun,
  before,
  after: { blocks: snap.blocks.length, transactions: snap.transactions.length },
  added: { blocks: addedBlocks, transactions: addedTxs },
  contiguous: gaps.length === 0,
  gaps,
}, null, 2));
