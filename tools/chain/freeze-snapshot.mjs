#!/usr/bin/env node
// freeze-snapshot.mjs — declare a chain snapshot FINISHED, but only after re-proving it.
//
//   node tools/chain/freeze-snapshot.mjs --snapshot client/fixtures/chain/aztec \
//     [--url <rpc>] [--min-complete 2] [--check-only]
//
// ── WHAT FREEZING MEANS ────────────────────────────────────────────────────────────────
//
// The demo needs 2-3 COMPLETE blocks per network — blocks in which every transaction the
// chain published was re-executed and reproduced — captured once and then left alone. Full
// chain history is a later ingestion layer and explicitly not this.
//
// So `frozen` is not a flag a caller sets. It is a CONCLUSION this tool reaches, and it
// reaches it only by asking the chain again. The page's frozen wording says "these blocks
// were taken whole", which is a universal claim over the block's contents; the only way to
// know it is true is to re-read what the chain says is in those blocks and check that
// nothing in them is unaccounted for.
//
// ── THE FOUR CHECKS, AND WHY EACH ONE EXISTS ───────────────────────────────────────────
//
//   1. THE BLOCK'S CONTENTS, RE-READ FROM THE CHAIN. A snapshot's `block.transactions` is
//      the follower's record of what the chain said HOURS AGO. Completeness is asserted
//      against the chain's list now, not against the snapshot's memory of it, because a
//      block that gained a transaction between capture and freeze would otherwise be
//      published as whole while missing one.
//
//   2. EVERY TRANSACTION IN THE BLOCK REPLAYED. Not "the first one", not "at least one".
//      A block with one of three transactions replayed is exactly the overclaim this
//      campaign exists to prevent, and it is the reason the target counts blocks and not
//      transactions.
//
//   3. EVERY CONTAINER IS ON DISK AND ITS BYTE COUNT MATCHES ITS ROW. `containerBytes` is
//      what the page states and what the conformance suite compares against; a row whose
//      declared size disagrees with the file is a page telling a visitor a number the
//      bytes do not support.
//
//   4. THE CONTAINER CARRIES THE CTFS MAGIC. Cheap, and it catches a truncated or
//      half-written file that still has the right length. It is not a full parse — the
//      engine does that — but a file that fails this cannot possibly open.
//
// A snapshot that fails any check is NOT frozen and the file is not written. Refusing to
// freeze is the safe outcome; publishing a frozen claim over an unverified snapshot is not.

import { readFile, writeFile, rename } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join, resolve } from 'node:path';

import { completeBlockCount, completeBlockNumbers } from './lib/replay.mjs';

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };
const flag = (n) => argv.includes(`--${n}`);

const snapDir = resolve(arg('snapshot', ''));
const minComplete = Number(arg('min-complete', 2));
const checkOnly = flag('check-only');
if (!snapDir) { console.error('freeze-snapshot: --snapshot <dir> is required'); process.exit(2); }

const snapPath = join(snapDir, 'snapshot.json');
if (!existsSync(snapPath)) { console.error(`freeze-snapshot: no snapshot at ${snapPath}`); process.exit(2); }
const snap = JSON.parse(await readFile(snapPath, 'utf8'));
const url = arg('url', snap.provenance?.endpoint);
if (!url) { console.error('freeze-snapshot: no endpoint in provenance and no --url given'); process.exit(2); }

let rpcId = 0;
async function rpc(method, params = []) {
  try {
    const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }) });
    if (!r.ok) return { __err: `HTTP ${r.status}` };
    const j = await r.json();
    return j.error ? { __err: j.error.message ?? JSON.stringify(j.error) } : j.result;
  } catch (e) { return { __err: `fetch: ${e.message}` }; }
}

const problems = [];
const byHash = new Map((snap.transactions ?? []).map((t) => [t.txHash, t]));

// ── THE CANDIDATE SET IS EVERY BLOCK THAT HAS A TRACE IN IT ────────────────────────────
//
// NOT `completeBlockCount(snap)`. Deriving the candidates from the snapshot's own view of
// completeness makes the per-transaction check below unreachable: a block only became a
// candidate once every transaction in it was already known to be `replayed`, so re-checking
// them could never fail, and a block with one of three replayed simply vanished from the
// set instead of being reported. A check that cannot fire is not a check, and a block that
// vanishes silently is exactly the partial this gate exists to name.
//
// So a candidate is any block holding at least one reproduced replay — that is, any block
// this capture would have a reason to show — and the CHAIN decides whether it is whole.
// `getTxEffect`'s list for the block is the denominator; the snapshot does not get a vote.
const candidates = (snap.blocks ?? [])
  .filter((b) => (b?.transactions ?? []).some((h) => byHash.get(h)?.outcome === 'replayed'))
  .map((b) => b.number)
  .sort((a, b) => b - a);

console.error(`freeze-snapshot: ${snapPath}`);
console.error(`  endpoint          ${url}`);
console.error(`  blocks with a trace (candidates): ${candidates.length} -> ${JSON.stringify(candidates)}`);
console.error(`  snapshot's own completeness count: ${completeBlockCount(snap)}`);
console.error(`  minimum required  ${minComplete}`);

const verifiedComplete = [];
const partial = [];

for (const n of candidates) {
  const full = await rpc('node_getBlock', [n, { includeTransactions: true }]);
  if (!full || full.__err) {
    problems.push(`block ${n}: the node would not serve it (${full?.__err}); cannot re-verify`);
    continue;
  }
  const onChain = (full.body?.txEffects ?? []).map((e) => e.txHash);
  const recorded = (snap.blocks ?? []).find((b) => b.number === n)?.transactions ?? [];

  // The snapshot's record of the block must agree with the chain's, or the snapshot is
  // stale about the very thing completeness is measured over.
  if (onChain.length !== recorded.length || !onChain.every((h, i) => h === recorded[i])) {
    problems.push(`block ${n}: the chain lists ${onChain.length} transaction(s) and the `
      + `snapshot records ${recorded.length}; the block is not captured whole`);
    continue;
  }

  // EVERY transaction the chain published in the block, against the denominator the chain
  // supplied. `firstInBlock` selection means a multi-transaction block will have had its
  // later transactions recorded as `not-first-in-block`; this is where that shows up as an
  // incomplete block rather than as a complete one missing its tail.
  const notReplayed = onChain.filter((h) => byHash.get(h)?.outcome !== 'replayed');
  if (notReplayed.length > 0) {
    const why = notReplayed.map((h) => `${h} is ${byHash.get(h)?.outcome ?? 'absent from the snapshot'}, not replayed`);
    partial.push({ n, total: onChain.length, missing: notReplayed.length, why });
    console.error(`  block ${n}: PARTIAL — ${onChain.length - notReplayed.length}/${onChain.length} replayed; NOT published as complete`);
    for (const w of why) console.error(`      ${w}`);
    continue;
  }

  verifiedComplete.push(n);
  console.error(`  block ${n}: chain says ${onChain.length} tx, all ${onChain.length} replayed — WHOLE`);
}

// A partial block is not fatal — it is simply not published as complete, and the other
// blocks stand on their own. It IS reported, because "prefer blocks you can complete" is
// only an honest strategy if the ones you could not complete are said out loud.
if (partial.length) {
  console.error(`\n  ${partial.length} block(s) hold a trace but are NOT whole and are excluded: `
    + partial.map((p) => `${p.n} (${p.total - p.missing}/${p.total})`).join(', '));
}

if (verifiedComplete.length < minComplete) {
  problems.push(`only ${verifiedComplete.length} block(s) verified complete against the chain; `
    + `--min-complete is ${minComplete}. A capture is frozen when it has met its target, not `
    + `when it has stopped moving.`);
}

// ---- checks 3 and 4: the containers ----------------------------------------------------
const CTFS_MAGIC = Buffer.from([0xC0, 0xDE, 0x72, 0xAC, 0xE2]);
let checkedContainers = 0;
for (const t of snap.transactions ?? []) {
  if (t.outcome !== 'replayed') continue;
  if (!t.container) { problems.push(`${t.txHash}: replayed and names no container`); continue; }
  const p = join(snapDir, t.container);
  if (!existsSync(p)) { problems.push(`${t.txHash}: container missing at ${t.container}`); continue; }
  const bytes = await readFile(p);
  if (bytes.length !== t.containerBytes) {
    problems.push(`${t.txHash}: containerBytes says ${t.containerBytes}, the file is ${bytes.length}`);
  }
  if (!bytes.subarray(0, 5).equals(CTFS_MAGIC)) {
    problems.push(`${t.txHash}: container does not carry the CTFS magic; it cannot open`);
  }
  checkedContainers++;
}
console.error(`  containers verified: ${checkedContainers} (bytes match row, CTFS magic present)`);

if (problems.length) {
  console.error(`\nfreeze-snapshot: REFUSING TO FREEZE — ${problems.length} problem(s):`);
  for (const p of problems) console.error(`  * ${p}`);
  process.exit(1);
}

if (checkOnly) {
  console.error('\nfreeze-snapshot: all checks pass (--check-only; nothing written)');
  process.exit(0);
}

snap.provenance = {
  ...snap.provenance,
  frozen: true,
  frozenAt: new Date().toISOString(),
  // The CHAIN-VERIFIED set, not the snapshot's own count. This is the list the page names
  // when it says those blocks were taken whole.
  completeBlocks: verifiedComplete,
};
const tmp = `${snapPath}.tmp`;
await writeFile(tmp, JSON.stringify(snap, null, 1) + '\n');
await rename(tmp, snapPath);
console.error(`\nfreeze-snapshot: FROZEN — ${verifiedComplete.length} complete block(s): ${verifiedComplete.join(', ')}`);
