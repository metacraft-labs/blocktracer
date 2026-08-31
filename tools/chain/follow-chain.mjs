#!/usr/bin/env node
// follow-chain.mjs — watch a live Aztec chain's tip and capture a transaction WHILE IT IS
// STILL REPLAYABLE, growing a committed snapshot.
//
// ── WHY A FOLLOWER AND NOT A BIGGER SCAN ───────────────────────────────────────────────
//
// `capture-chain.mjs` enumerates `--depth` blocks below the tip once and replays whatever
// is still replayable at that instant. On testnet that wins, because testnet is busy. On
// mainnet it lost, and the measurement says why — the arrivals are BURSTY, and a scan can
// only win if it happens to run during a burst:
//
//   * The 2026-08-31T07:39Z mainnet scan enumerated 400 blocks and found 20 transactions.
//     EIGHTEEN of them fell inside blocks 66749-66802 — a 53-block span — and then the
//     chain produced nothing at all for 309 blocks. The last two were at 67111 and 67113.
//   * The replayable window at that moment was 67120-67144. The most recent transaction
//     had settled SEVEN BLOCKS below it. Every one of the 20 was already pruned:
//     `bodyRetained: 0`, and the snapshot published zero traces.
//
// An average rate over that series — 20 transactions across 400 blocks, one per 20 blocks,
// one per 25 minutes — is arithmetically true and predicts the wrong thing. It describes a
// chain that would put roughly one transaction inside every replayable window. The real
// chain puts eighteen in one hour and none in the next six. A previous version of this
// site's own explanatory copy made exactly that mistake and had to be replaced; this
// comment is not going to make it again.
//
// ── WHY DURATION AND NOT CADENCE ───────────────────────────────────────────────────────
//
// A 30-second poller was tried and caught zero over an entire session. The instinct is to
// poll faster. That is the wrong fix, and the measurement says so.
//
// Measured on mainnet, 2026-08-31, over blocks 67145-67579 (435 blocks, ~8.7 hours):
//
//     block   67242  67384  67409  67468  67511
//     gap (blocks)  142     25     59     43
//
// Five transactions, all of them first-in-block and therefore replay candidates. The
// inter-arrival gaps are 25 to 142 blocks — 30 minutes to 2.8 HOURS at the measured
// 72-second cadence. The replayable window is `tip - finalized` = 25 blocks ≈ 30 minutes.
//
// So a poll every 60 seconds cannot miss an arrival: the window is thirty times the poll
// interval. What the 30-second poller lacked was not frequency but RUNTIME — it polled for
// less time than a single inter-arrival gap. A follower has to outlive the drought, which
// means it is a process measured in hours, not a step in a pipeline measured in seconds.
// `--deadline` therefore defaults to hours and `--interval` to a minute, and raising the
// interval to five minutes would still not miss one.
//
// ── WHAT REPLAYABILITY ACTUALLY IS ─────────────────────────────────────────────────────
//
// Not arithmetic. `getTxByHash` reads the mempool, which is emptied at finalization;
// `getTxEffect` reads the archive, which is not. The window `finalized+1 .. tip` is where
// a body is EXPECTED to still be served, and this tool uses it to decide where to look —
// but before replaying anything it ASKS `getTxByHash`, because the node's answer is the
// fact and the window is an inference about it. A follower that trusted the arithmetic
// would hand the runtime a transaction whose body had just been pruned and record the
// resulting refusal as if it were a property of the transaction.
//
// This tool NEVER reaches below the finalized tip to manufacture a candidate, and never
// publishes a container the driver did not write. See `lib/replay.mjs` for the verdict
// rule, which is shared with `capture-chain.mjs` rather than restated here.
//
// ── HOW THE SNAPSHOT ACCUMULATES ───────────────────────────────────────────────────────
//
// ONE snapshot per chain, which GROWS. Not one per catch: the explorer renders one chain,
// and several snapshots of it would be several generations of the same blocks that the
// ingest would have to merge anyway.
//
// Growing it makes a single `capturedAt` and a single `window` untrue the moment a second
// session adds a row, so both become per-session facts and the sessions are listed:
//
//   provenance.capturedAt      the MOST RECENT session (what a reader means by "captured")
//   provenance.firstCapturedAt the earliest session
//   captures[]                 every session: its moment, its window, its tool, its yield
//   transactions[].capturedAt  the moment THIS transaction was observed
//   transactions[].capturedWindow  the window that was replayable when it was observed
//
// A transaction's page can then state the moment its own trace was recorded, rather than
// inheriting a chain-level timestamp that is only true of the newest row.
//
// ── USAGE ──────────────────────────────────────────────────────────────────────────────
//
//   node tools/chain/follow-chain.mjs --runtime <aztec-avm-runtime> --node <node>=24 \
//     [--url <rpc>] [--chain <slug>] [--snapshot <dir>] [--interval 60] \
//     [--deadline-min 480] [--until 1] [--log <file>] [--dry-run]
//
//   --until N        stop after N NEW replays land (default 1; 0 = never stop early)
//   --deadline-min   stop after this many minutes regardless (default 480 = 8h)
//   --dry-run        watch and log, never replay and never write the snapshot
//   --log <file>     append one JSON object per poll. Written even when nothing is caught,
//                    because "caught nothing" is only an honest claim if the looking is on
//                    the record — an empty result set makes every universal statement
//                    about it vacuously true, so the LOG is the evidence, not the snapshot.

import { mkdir, writeFile, readFile, rename } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { appendFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

import { replayTransaction, run } from './lib/replay.mjs';

const argv = process.argv.slice(2);
const arg = (name, fallback) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : fallback;
};
const flag = (name) => argv.includes(`--${name}`);

const url = arg('url', 'https://aztec.drpc.org');
const chain = arg('chain', url.includes('testnet') ? 'aztec-testnet' : 'aztec-mainnet');
const label = arg('label', chain === 'aztec-testnet' ? 'Real Aztec testnet data'
  : 'Real Aztec mainnet data');
const snapDir = resolve(arg('snapshot', `client/fixtures/chain/${chain}`));
const runtime = arg('runtime');
const avm = arg('avm', process.env.AVM_WASM_PATH);
const ctWriter = arg('ct-writer', process.env.CT_WRITER_WASM_PATH);
const nodeBin = arg('node', process.execPath);
const intervalS = Number(arg('interval', 60));
const deadlineMin = Number(arg('deadline-min', 480));
const until = Number(arg('until', 1));
const logPath = arg('log', '');
const dryRun = flag('dry-run');
const backfillCap = Number(arg('backfill-cap', 400));

const die = (m) => { console.error(`follow-chain: ${m}`); process.exit(2); };

if (!dryRun) {
  if (!runtime) die('--runtime <path-to-aztec-avm-runtime> is required. This repository carries no AVM.');
  if (!avm) die('--avm <avm.wasm> (or $AVM_WASM_PATH) is required. It must be the --import-memory build.');
  if (!ctWriter) die('--ct-writer <aztec_ct_writer.wasm> (or $CT_WRITER_WASM_PATH) is required.');
  for (const [what, p] of [['runtime', runtime], ['avm', avm], ['ct-writer', ctWriter]]) {
    if (!existsSync(p)) die(`${what} path does not exist: ${p}`);
  }
}

let rpcId = 0;
async function rpc(method, params = []) {
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
    });
    if (!r.ok) return { __err: `HTTP ${r.status}` };
    const j = await r.json();
    if (j.error) return { __err: j.error.message ?? JSON.stringify(j.error) };
    return j.result;
  } catch (e) {
    // A transient network fault must not end an eight-hour watch. It is logged and the
    // poll is retried; the alternative is a follower that dies at hour three and reports
    // "caught nothing" for a reason that has nothing to do with the chain.
    return { __err: `fetch: ${e.message}` };
  }
}

const log = (obj) => {
  const line = JSON.stringify({ at: new Date().toISOString(), ...obj });
  console.error(`follow-chain: ${line}`);
  if (logPath) { try { appendFileSync(logPath, line + '\n'); } catch { /* logging must not kill the watch */ } }
};

// ── the snapshot, loaded or started ──────────────────────────────────────────────────
async function loadSnapshot() {
  const p = join(snapDir, 'snapshot.json');
  if (existsSync(p)) return JSON.parse(await readFile(p, 'utf8'));
  // `@1`, deliberately, for a snapshot this tool STARTS as well as one it grows.
  // `ingest.nim:103-106` refuses any other format string outright, and everything this
  // tool adds — `captures[]`, `transactions[].capturedAt`, `transactions[].capturedWindow`
  // — is ADDITIVE: every key the ingest reads is still where it was and still means what
  // it meant. Bumping the format here would be a second change, to another module's
  // parser, buried inside this one.
  return {
    format: 'blocktracer/chain-snapshot@1',
    provenance: { kind: 'live-capture', chain, label, endpoint: url },
    captures: [],
    window: null,
    counts: {},
    blocks: [],
    transactions: [],
  };
}

/** Write the snapshot atomically. A follower is killed by whoever is running it, and a
 *  half-written committed fixture would be a corrupt data plane rather than a missed
 *  capture. */
async function saveSnapshot(s) {
  const p = join(snapDir, 'snapshot.json');
  const tmp = `${p}.tmp`;
  await writeFile(tmp, JSON.stringify(s, null, 1) + '\n');
  await rename(tmp, p);
}

function recount(s) {
  const by = (o) => s.transactions.filter((t) => t.outcome === o).length;
  s.counts = {
    blocks: s.blocks.length,
    blocksWithTransactions: s.blocks.filter((b) => b.transactions.length).length,
    transactions: s.transactions.length,
    bodyRetained: s.transactions.filter((t) => t.bodyRetained).length,
    replayed: by('replayed'),
    divergent: by('divergent'),
    refused: by('refused'),
    pruned: by('pruned'),
  };
  // The two figures a page actually needs to tell the truth about this chain.
  s.counts.tracesPublished = s.counts.replayed + s.counts.divergent;
  s.counts.captureSessions = (s.captures ?? []).length;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  await mkdir(join(snapDir, 'ct'), { recursive: true });
  const snap = await loadSnapshot();

  const nodeInfo = await rpc('node_getNodeInfo');
  if (nodeInfo?.__err) die(`the node refused getNodeInfo: ${nodeInfo.__err}`);

  // Resolved once, at start, and not per catch: it is a fact about the driver this
  // process will use for every replay it makes, and re-reading it mid-watch would let a
  // snapshot claim two recorder versions for one session.
  const runtimeCommit = dryRun ? ''
    : (await run('git', ['rev-parse', 'HEAD'], runtime)).out.trim();

  const startedAt = Date.now();
  const deadline = startedAt + deadlineMin * 60_000;
  const seen = new Set(snap.transactions.map((t) => t.txHash));
  const knownBlocks = new Map(snap.blocks.map((b) => [b.number, b]));
  let caught = 0;
  let polls = 0;

  log({ event: 'start', chain, url, nodeVersion: nodeInfo.nodeVersion,
        knownTransactions: seen.size, knownBlocks: knownBlocks.size,
        intervalS, deadlineMin, until, dryRun });

  while (Date.now() < deadline) {
    polls++;
    const tip = await rpc('node_getBlockNumber');
    const finalized = await rpc('node_getBlockNumber', ['finalized']);
    if (tip?.__err || finalized?.__err) {
      log({ event: 'poll-error', tip, finalized });
      await sleep(intervalS * 1000);
      continue;
    }

    // ── 1. the replayable window, newest first ──────────────────────────────────────
    // Newest first because the oldest block in the window is the one about to finalize:
    // if two are waiting, the one with the least time left is NOT the one to take, since
    // it may prune mid-replay. The newest has the full window ahead of it.
    const candidates = [];
    for (let n = tip; n > finalized; n--) {
      const head = await rpc('node_getBlock', [n]);
      if (!head || head.__err) continue;
      const mana = String(head.header.totalManaUsed);
      if (/^0x0*$/.test(mana)) continue;
      const full = await rpc('node_getBlock', [n, { includeTransactions: true }]);
      for (const [i, eff] of (full?.body?.txEffects ?? []).entries()) {
        if (seen.has(eff.txHash)) continue;
        // Only the first transaction in a block can be re-executed from published data:
        // replaying transaction k needs the state after k-1 and the node does not serve
        // intra-block intermediate state. This is the runtime's constraint, not ours.
        if (i !== 0) {
          candidates.push({ txHash: eff.txHash, blockNumber: n, txIndexInBlock: i,
                            revertCode: eff.revertCode, transactionFee: eff.transactionFee,
                            skip: 'not-first-in-block' });
          continue;
        }
        candidates.push({ txHash: eff.txHash, blockNumber: n, txIndexInBlock: i,
                          revertCode: eff.revertCode, transactionFee: eff.transactionFee });
      }
    }

    const replayable = candidates.filter((c) => !c.skip);
    log({ event: 'poll', n: polls, tip, finalized, windowBlocks: tip - finalized,
          inWindow: candidates.length, candidates: replayable.length,
          caught, elapsedMin: Math.round((Date.now() - startedAt) / 60000) });

    // ── 2. take one, and ASK whether its body is still there ────────────────────────
    for (const c of replayable) {
      const byHash = await rpc('node_getTxByHash', [c.txHash]);
      const bodyRetained = !!byHash && !byHash.__err;
      if (!bodyRetained) {
        // Inside the window by arithmetic and pruned in fact. Recorded, not replayed.
        log({ event: 'body-gone', tx: c.txHash, block: c.blockNumber });
        continue;
      }
      log({ event: 'catch', tx: c.txHash, block: c.blockNumber, tip, finalized,
            blocksOfHeadroom: c.blockNumber - finalized });
      if (dryRun) { seen.add(c.txHash); continue; }

      const capturedAt = new Date().toISOString();
      const ctRel = `ct/${c.txHash}.ct`;
      const decided = await replayTransaction({
        nodeBin, runtime, url, txHash: c.txHash,
        ctPath: join(snapDir, ctRel), ctRelative: ctRel, avm, ctWriter,
      });

      const row = {
        txHash: c.txHash,
        blockNumber: c.blockNumber,
        txIndexInBlock: c.txIndexInBlock,
        revertCode: c.revertCode,
        transactionFee: c.transactionFee,
        bodyRetained: true,
        effectVisible: true,
        firstInBlock: true,
        capturedAt,
        capturedWindow: { tip, finalized, replayableFrom: finalized + 1, replayableTo: tip },
        ...decided,
      };
      snap.transactions.push(row);
      seen.add(c.txHash);

      (snap.captures ??= []).push({
        capturedAt,
        by: 'tools/chain/follow-chain.mjs',
        window: { tip, finalized, replayableFrom: finalized + 1, replayableTo: tip,
                  blocks: tip - finalized },
        nodeVersion: nodeInfo.nodeVersion,
        runtimeCommit,
        yielded: [{ txHash: c.txHash, outcome: decided.outcome }],
      });
      // `firstCapturedAt` is pinned BEFORE `capturedAt` is overwritten, and falls back to
      // the value being replaced rather than to the new one: the snapshot being grown was
      // captured by the one-shot scan, whose `capturedAt` is the earliest moment this
      // chain was looked at and is the honest lower bound for "captured over".
      const priorCapturedAt = snap.provenance?.capturedAt;
      snap.provenance = {
        ...snap.provenance,
        kind: 'live-capture',
        chain, label, endpoint: url,
        capturedAt,
        firstCapturedAt: snap.provenance?.firstCapturedAt ?? priorCapturedAt ?? capturedAt,
        nodeVersion: nodeInfo.nodeVersion,
        l1ChainId: nodeInfo.l1ChainId,
        rollupVersion: nodeInfo.rollupVersion,
        rollupAddress: nodeInfo.l1ContractAddresses?.rollupAddress ?? '',
        // `runtimeCommit` is REQUIRED by `ingest.nim:123`, which derives the published
        // `recorderVersion` from it. A follower that grew a snapshot without it would
        // write a fixture the exporter cannot read.
        runtimeCommit,
        tool: 'tools/chain/follow-chain.mjs',
      };
      snap.window = { tip, finalized, replayableFrom: finalized + 1, replayableTo: tip,
                      blocks: tip - finalized };

      log({ event: 'replayed', tx: c.txHash, outcome: decided.outcome,
            effects: decided.effects
              ? `${decided.effects.matched}/${decided.effects.matched + decided.effects.mismatched}`
              : null,
            steps: decided.recording?.steps, refusal: decided.refusal });

      if (decided.replayed) caught++;
      recount(snap);
      await saveSnapshot(snap);
      if (until > 0 && caught >= until) break;
    }

    // ── 3. backfill the block record so the chain stays contiguous ──────────────────
    // The explorer renders a block list; a snapshot with a hole in it would render one
    // too. Cheap when caught up (a block a minute), one larger catch-up on first run.
    if (!dryRun) {
      // THE CAP BOUNDS A COLD START ONLY. Applying it to a snapshot that already has
      // blocks in it puts a HOLE in the block record: the first run of this follower
      // against the 2026-08-31T07:39Z mainnet snapshot (blocks 66745-67144, tip 67584)
      // took `max(67145, 67185)` and left 67145-67184 missing — forty blocks the explorer
      // would have rendered a list around without anything saying they were absent. A
      // bounded catch-up is a performance choice; a hole is a wrong answer, so the two
      // must not be spelled by one expression.
      const known = snap.blocks.map((b) => b.number);
      const highest = known.length ? Math.max(...known) : tip - backfillCap;
      const from = known.length ? highest + 1 : Math.max(1, tip - backfillCap + 1);
      let added = 0;
      for (let n = from; n <= tip; n++) {
        if (knownBlocks.has(n)) continue;
        const head = await rpc('node_getBlock', [n]);
        if (!head || head.__err) continue;
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
            if (!seen.has(eff.txHash)) {
              // Seen too late to replay: it is below the window or was not first in its
              // block. Recorded with the reason, never omitted — the explorer has to be
              // able to say why a visible transaction has no trace.
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
                      + `when this follower first saw it, so it can no longer be `
                      + `re-executed and no trace was recorded for it.` };
              snap.transactions.push({
                txHash: eff.txHash, blockNumber: n, txIndexInBlock: i,
                revertCode: eff.revertCode, transactionFee: eff.transactionFee,
                bodyRetained: false, effectVisible: true, firstInBlock: i === 0,
                observedAt: new Date().toISOString(), ...why,
              });
              seen.add(eff.txHash);
            }
          }
        }
        snap.blocks.push(row);
        knownBlocks.set(n, row);
        added++;
      }
      if (added) {
        snap.blocks.sort((a, b) => b.number - a.number);
        // EXTENDING THE BLOCK RECORD IS ALSO A CAPTURE, so the moment and the window move
        // with it. Updating these only on a catch left the snapshot claiming it was read
        // at 07:39 while carrying blocks the follower had just fetched at 16:49 — and the
        // published sentence "the replay window was blocks A–B at that moment" then
        // described a window nine hours stale. `firstCapturedAt` is pinned to the moment
        // BEFORE this watch started, which is what makes the accumulated phrasing in
        // `ingest.nim` say something true about both ends.
        snap.provenance = {
          ...snap.provenance,
          firstCapturedAt: snap.provenance?.firstCapturedAt
            ?? snap.provenance?.capturedAt ?? new Date().toISOString(),
          capturedAt: new Date().toISOString(),
          nodeVersion: nodeInfo.nodeVersion,
          runtimeCommit: snap.provenance?.runtimeCommit ?? runtimeCommit,
        };
        snap.window = { tip, finalized, replayableFrom: finalized + 1, replayableTo: tip,
                        blocks: tip - finalized };
        recount(snap);
        await saveSnapshot(snap);
        log({ event: 'backfill', added, highest: tip });
      }
    }

    if (until > 0 && caught >= until) {
      log({ event: 'done', reason: 'until-reached', caught, polls });
      return 0;
    }
    await sleep(intervalS * 1000);
  }

  log({ event: 'done', reason: 'deadline', caught, polls,
        elapsedMin: Math.round((Date.now() - startedAt) / 60000) });
  return caught > 0 ? 0 : 1;
}

main().then((c) => process.exit(c)).catch((e) => {
  console.error(`follow-chain: ${e.stack ?? e.message}`);
  process.exit(2);
});
