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
// THE HOLE IS REPAIRABLE AND THIS TOOL DOES NOT REPAIR THE RECORDING, which is
// the whole reason it is a separate tool rather than a note to re-run the watch.
// A block's header, its archive roots and its `txEffects` are ARCHIVAL and prune
// never, so every field of a block row is still exactly as readable today as it
// was during the watch. Re-fetching them invents nothing and re-derives nothing;
// it reads the same node method the follower would have read, and writes the
// same row shape.
//
// THIS PARAGRAPH USED TO SAY THE TRANSACTIONS "CAN NEVER BE REPLAYED AGAIN",
// AND THAT WAS CORRECTED ON 2026-09-10. What was re-measured here is true and
// narrower than the conclusion drawn from it: `getTxByHash` prunes at
// finalization, so THE NODE no longer serves 0x20ed5b91…'s body. The network
// still does — Aztec's keyless `TxFileStore` serves one content-addressed `.bin`
// per transaction hash for the whole chain — and `ingest-range.mjs --replay`
// re-executes settled historic transactions from it. See `lib/body-proxy.mjs`
// and CHAIN-CAPTURE.md §1. This tool still writes no container and replays
// nothing, because repairing a BLOCK record is a different job from tracing the
// transactions in it; the rows it writes now say `not-attempted` rather than
// asserting the transaction is beyond reach.
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

import { assertRefusalsAreClosed, refuseNotFirstInBlock,
         classifyRefusal } from './lib/refusal.mjs';
import { recountSnapshot } from './lib/recount.mjs';
import { assertReadableSnapshotFormat } from './lib/snapshot-format.mjs';

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : dflt;
};
const flag = (name) => argv.includes(`--${name}`);

const snapshotDir = arg('snapshot', '');
const url = arg('url', '');
// `undefined`, NOT `0` — the same correction `ingest-range.mjs` carries at length.
// `Number(arg('from', 0))` is a finite `0` whether or not the flag was passed, so a
// guard cannot ask whether numbers were SUPPLIED. Here it also refused height zero
// outright (`!from`), which is the one height a genesis-to-tip pass starts at.
// `Number(undefined)` is `NaN`, so absence fails `Number.isFinite` and reaches the
// usage message while `--from 0` reaches the range.
const from = Number(arg('from', undefined));
const to = Number(arg('to', undefined));
const checkpoint = Number(arg('checkpoint', 100));
const dryRun = flag('dry-run');

if (!snapshotDir || !Number.isFinite(from) || !Number.isFinite(to)
    || from < 0 || to < from) {
  console.error('usage: --snapshot <dir> --from N --to M [--url U] [--checkpoint N] [--dry-run]');
  process.exit(2);
}

const snapPath = join(snapshotDir, 'snapshot.json');
const snap = JSON.parse(readFileSync(snapPath, 'utf8'));
// REFUSED BY NAME, AGAINST THE SHARED LIST. This was `!== 'blocktracer/chain-snapshot@1'`
// against a literal of its own — a third copy of the version gate, in the tool whose job is
// to rewrite a committed snapshot in place. `assertReadableSnapshotFormat` is the one
// implementation (Data-Contract.md §3, §5.2). This tool does NOT promote the token: it adds
// untraced rows through `classifyRefusal`, so every row IT writes carries the member, but an
// `@1` file's existing rows are the migration's business and `assertRefusalsAreClosed` at
// save time refuses rather than stamping a token over rows that do not meet it.
try {
  assertReadableSnapshotFormat(snap.format, snapPath);
} catch (e) {
  console.error(`refusing: ${e.message}`);
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
  // ING-3's gate, the same one `follow-chain.mjs` applies at its own save: a snapshot may
  // not be written holding a transaction that is untraced for no stated reason.
  assertRefusalsAreClosed(snap.transactions);
  const tmp = `${snapPath}.tmp`;
  // INDENT 1, WHICH IS `follow-chain.mjs`'s `saveSnapshot` AND NOT A TASTE.
  // These files are 40,000 lines; a repair that re-indented one would land a
  // whole-file diff in which the fifty rows that actually changed cannot be
  // found, and a reviewer's only way to check that a frozen capture survived
  // is to read the diff.
  writeFileSync(tmp, JSON.stringify(snap, null, 1) + '\n');
  renameSync(tmp, snapPath);
}

// THE TALLY IS `lib/recount.mjs`'s, AND THIS IS THE COPY THAT DID THE DAMAGE.
//
// The comment this replaces said it right — "this tool adds untraced rows and a snapshot
// whose counts described a different set of rows than it holds is worse than one with no
// counts at all" — and then the code did the opposite: it spread `...s.counts` and
// recomputed only `blocks`, `blocksWithTransactions`, `transactions` and the refusal block.
// Every OUTCOME line therefore survived a run that added rows, by construction.
//
// Measured in the committed tree: `client/fixtures/chain/aztec-testnet/snapshot.json` began
// as 51 transactions with `counts.pruned: 25`; a whole-history backfill added 815 rows,
// every one of them untraced, and the file shipped `transactions: 866` beside
// `pruned: 25` — 835 pruned rows counted as 25. Data-Contract.md §5.2 gives `counts` one
// job, "so a partial ingest is detectable", so this was the detector reading clean on the
// one condition it detects.
//
// `recountSnapshot` REPLACES the counts object rather than merging into it, which is the
// whole difference: a field that is not derived on every call is not published.
const recount = recountSnapshot;

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
        ? refuseNotFirstInBlock({ blockNumber: n, txIndexInBlock: i,
                                  where: 'backfill-blocks.mjs' })
        // WAS `refuseBodyUnavailable`, WHOSE SENTENCE ENDS "it can no longer be
        // re-executed" — measured false on 2026-09-10. The node's pruning is real
        // and it is not the only publisher: the keyless `TxFileStore` serves the
        // body for the whole chain, and `ingest-range.mjs --replay` traced 211 of
        // 343 historic transactions through it. A repair tool that writes no
        // container has not met an obstacle, it has not looked, and that is the
        // one thing `not-attempted` means.
        : { outcome: 'not-attempted', ...classifyRefusal({
            condition: 'historic-range-not-replayed',
            where: 'backfill-blocks.mjs',
            narrative: `This transaction is first in block ${n}, so it can be re-executed `
              + `from published data: the node no longer serves its body, but the keyless `
              + `transaction file store does. This record was REPAIRED rather than `
              + `captured — the tool that wrote it re-reads block metadata and replays `
              + `nothing — so no trace was recorded. Nothing about the chain stopped it.`,
          }) };
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
