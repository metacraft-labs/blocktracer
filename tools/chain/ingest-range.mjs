#!/usr/bin/env node
// ingest-range.mjs — ingest ONE NAMED BLOCK RANGE end to end, and record that it
// is covered.
//
// ── WHY THIS IS THE UNIT ─────────────────────────────────────────────────────
//
// The storage model this repository publishes into is content-addressed: a block
// lives at `d/{chain}/block/{hash}.json`, a transaction's facts at
// `d/{chain}/tx/{shard}/{hash}.json`, a container at `t/**`. None of those keys
// mentions a range, a generation or a run, so any range of blocks can be fetched,
// ingested and uploaded on its own, and re-done later without disturbing another
// range's objects. That is the property the whole operation is built on, and this
// tool is the smallest command that exercises it: fetch a range, ingest it,
// publish it, write down that it is covered and at what code version.
//
// It is NOT a service. A resident follower is a scheduler over this operation,
// and the operation has to be right first — an always-on process whose per-range
// step is unproven is an unproven step running unattended.
//
// ── WHAT IS INDEPENDENT AND WHAT IS NOT, MEASURED ───────────────────────────
//
// Two of the three layers a range writes are genuinely per-range:
//
//   * CONTENT — `d/{chain}/block/{hash}.json`, `d/{chain}/tx/**`, `t/**`,
//     `{chain}/**/index.html`. Keyed by hash. Range A's objects and range B's
//     objects never collide, and re-running a range rewrites byte-identical
//     bytes (which the publisher then skips outright, since present ⇒ skip).
//   * The per-range SNAPSHOT under `ranges/`, which is the refreshable unit: a
//     range re-fetched after a code change replaces its own snapshot and nothing
//     else's.
//
// The third is not, and pretending otherwise would have shipped a hole:
//
//   * The GENERATION MAPS — `d/{chain}/g/{gen}/height/0.json`,
//     `.../blocks/0.json`, `.../summary.json`, and the `current.json` that makes
//     them visible — are whole-chain singletons written by `ingest.nim` from the
//     snapshot it is given. Ingest range A alone and publish, then ingest range B
//     alone and publish, and `blocks/0.json` names B's blocks and ONLY B's: A's
//     block objects are all still in the store, still fetchable by hash, and no
//     longer listed anywhere. The block list renders B. This was measured, not
//     reasoned about — see the `--no-merge` flag, which reproduces it.
//
// So the tree handed to the ingest is built from the UNION of every range the
// ledger says is covered, and the per-range snapshots are what that union is
// assembled from. Ranges stay independently fetchable and independently
// refreshable; the maps stay whole-chain because the contract says they are one
// object. The alternative — sharding the height and blocks maps by range — is a
// change to the published data contract and to every reader of it, and is the
// right eventual fix; it is not something to do inside a range command.
//
// ── THE RANGE KEY IS ZERO-PADDED, AND THAT IS LOAD-BEARING ──────────────────
//
// Directory and bucket listings are LEXICOGRAPHIC. `74000-74099` and
// `100000-100099` sort with the six-digit range FIRST, so the moment a chain
// crosses 99999 an unpadded ledger lists its newest ranges as its oldest and any
// "what is the highest covered block" that reads the listing answers with a
// stale number — silently, and only from that day onward. Aztec testnet was at
// block 75270 when this was written and produces a block roughly every 65
// seconds, which puts the crossing about three weeks out. Every range artifact
// this tool names is therefore padded to `--pad` (default 9) digits, which sorts
// correctly to a billion blocks.
//
// ── USAGE ───────────────────────────────────────────────────────────────────
//
//   node tools/chain/ingest-range.mjs --from N --to M \
//     [--url https://aztec-testnet.drpc.org] [--chain aztec-testnet] \
//     [--state .chain-state/<chain>] [--ingest-bin ./blocktracer-chain-ingest] \
//     [--publish-bin ./blocktracer-publish] \
//     [--backend local|s3] [--dest DIR | --bucket B --endpoint U --prefix P] \
//     [--no-publish] [--no-merge] [--refetch] [--pad 9] [--json]
//
//   --refetch     re-fetch a range the ledger already covers (the refresh path)
//   --no-merge    ingest ONLY this range's snapshot, not the union — the
//                 demonstration of what whole-chain generation maps do
//   --no-publish  fetch and ingest, stop before the object store

import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync, readdirSync, statSync,
         linkSync, copyFileSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

import { classifyRefusal, refusalCounts, assertRefusalsAreClosed, refuseNotFirstInBlock,
         refuseBodyUnavailable, refuseBodySourceUnreachable,
         chainPublishedNoPublicExecution } from './lib/refusal.mjs';
import { preflightToolchain, replayTransaction } from './lib/replay.mjs';
import { startBodyProxy } from './lib/body-proxy.mjs';
import { recountSnapshot } from './lib/recount.mjs';
import { SNAPSHOT_FORMAT } from './lib/snapshot-format.mjs';
import { storeBasePath } from './backfill-bodies.mjs';

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : dflt;
};
const flag = (name) => argv.includes(`--${name}`);

const url = arg('url', 'https://aztec-testnet.drpc.org');
const chain = arg('chain', url.includes('testnet') ? 'aztec-testnet' : 'aztec-mainnet');
const label = arg('label', chain === 'aztec-testnet' ? 'Real Aztec testnet data'
  : 'Real Aztec mainnet data');
// ── ABSENCE HAS TO BE DISTINGUISHABLE FROM ZERO, AND `0` IS NOT ─────────────
//
// These defaulted to `0`, so `Number(arg('from', 0))` was a finite `0` whether or
// not `--from` was passed — and the guard below, which exists to ask "were numbers
// supplied", could not. `node tools/chain/ingest-range.mjs` with NO ARGUMENTS
// therefore passed the guard and silently ingested range 0..0 against the default
// testnet endpoint, writing a state directory, a range, a ledger entry and a
// publish attempt, instead of printing the usage the guard below was written to
// print. That contradicts the comment on the guard in the same breath as it.
//
// `undefined` is the honest default: `Number(undefined)` is `NaN`, which
// `Number.isFinite` rejects, so an absent flag reaches the usage message and
// `--from 0` reaches the range. The guard keeps admitting height zero — that is
// the one height a genesis-to-tip pass starts at, and refusing it was the previous
// defect here.
const from = Number(arg('from', undefined));
const to = Number(arg('to', undefined));
const pad = Number(arg('pad', 9));
const stateDir = resolve(arg('state', `.chain-state/${chain}`));
const ingestBin = arg('ingest-bin', 'blocktracer-chain-ingest');
const publishBin = arg('publish-bin', 'blocktracer-publish');
const backend = arg('backend', 'local');
const dest = arg('dest', join(stateDir, 'store'));
const bucket = arg('bucket', '');
const endpoint = arg('endpoint', '');
const prefix = arg('prefix', '');
// "" ⇒ derive it from the covered set; see `generationFor`.
const generation = arg('generation', '');
// Pacing and patience, both operator-set, because the sustainable rate is a
// property of somebody else's endpoint and not of this tool. `--rps 0` disables
// pacing entirely (the behaviour before this flag existed).
const rps = Number(arg('rps', '0'));
const minGapMs = rps > 0 ? 1000 / rps : 0;
let lastCallAt = 0;
const maxAttempts = Math.max(1, Number(arg('attempts', '8')));
// 0 = one request per height (the proven path). N = ask for N headers at a time.
const batchHeaders = Math.max(0, Number(arg('batch-headers', '0')));
const noPublish = flag('no-publish');
const noMerge = flag('no-merge');
const refetch = flag('refetch');
const jsonOnly = flag('json');

// ── HISTORIC REPLAY ─────────────────────────────────────────────────────────
//
// Off by default, and the default is not timidity: replay needs an
// `aztec-avm-runtime` checkout, an `--import-memory` avm.wasm, a ct-writer
// module and a Node with `--experimental-wasm-exnref`, none of which this
// repository carries. A range command that silently produced no traces because
// one of them was absent would be the quiet failure `preflightToolchain` exists
// to stop, so `--replay` is asked for explicitly and refuses loudly.
//
// With it on, this tool stops being metadata-only. See `replayRange`.
const doReplay = flag('replay');
const runtime = arg('runtime', '');
const nodeBin = arg('node', process.execPath);
const avm = arg('avm', process.env.AVM_WASM_PATH ?? '');
const ctWriter = arg('ct-writer', process.env.CT_WRITER_WASM_PATH ?? '');
// 0 = every first-in-block transaction in the range. A budget is a statement
// about the RUN and the rows it does not reach say so — `not-attempted`.
const replayMax = Math.max(0, Number(arg('replay-max', '0')));
// The proxy's pacing to the UPSTREAM node. Defaults to `--rps` when that is set
// (one endpoint, one budget) and to the rate the genesis-to-tip backfill was run
// at otherwise. `aztec-testnet.drpc.org` is clean to 12/s sustained and answers a
// throttled client with `retry-after: 2465` — forty-one minutes, across every
// dRPC host at once — so this is the number that decides whether a long run
// finishes or is banned halfway.
const replayRps = Number(arg('replay-rps', rps > 0 ? String(rps) : '6'));
const network = arg('network', chain.includes('testnet') ? 'testnet' : 'mainnet');
const bodyStore = arg('body-store', '');
const bodyDir = arg('body-dir', join(stateDir, 'bodies'));
// The body source's own patience, separate from the node's. It is a different host with a
// different owner and — for Aztec — no failover at all (Chain-Data-Ingestion.md §4.8), so
// "how long do we wait for a body" is not the same operator decision as "how fast may we
// poll the node". Past these the run ENDS, and every row it did not reach says
// `body-source-unreachable` rather than claiming a permanent property of the chain.
const storeAttempts = Math.max(1, Number(arg('store-attempts', '4')));
const storeTimeoutMs = Math.max(1000, Number(arg('store-timeout-ms', '30000')));
const configRef = arg('config',
  'https://raw.githubusercontent.com/AztecProtocol/networks/main/network_config.json');

// `!from` REFUSED HEIGHT ZERO, which is the one height a genesis-to-tip pass
// starts at. The guard means "were numbers supplied", so it has to ask that
// question rather than ask whether they are truthy: `--from 0` is a request,
// `--from` absent is not. Aztec's own first settled block is 1 — the node
// reports `oldestHistoricBlockNumber: 1` — but that is a fact about the chain
// and belongs in the caller's range, not in an argument check that cannot say
// why it refused.
if (!Number.isFinite(from) || !Number.isFinite(to) || from < 0 || to < from) {
  console.error('usage: --from N --to M [--url U] [--chain C] [--state DIR] …');
  process.exit(2);
}

const say = (m) => { if (!jsonOnly) console.error(`ingest-range: ${m}`); };
const padN = (n) => String(n).padStart(pad, '0');
const rangeKey = `${padN(from)}-${padN(to)}`;
const sha = (s) => createHash('sha256').update(s).digest('hex');

const LEDGER = join(stateDir, 'coverage.json');
const RANGES = join(stateDir, 'ranges');
const TREE = join(stateDir, 'tree');

// ── the code version a range was covered AT ─────────────────────────────────
//
// "Eventually full coverage" is only measurable if a range records WHAT ingested
// it, so a defect found later can be turned into a list of ranges to redo rather
// than a decision to redo everything. Two identities, because they answer two
// questions: the repository commit says which source, and the digest of the two
// binaries says which build — a dirty tree and a rebuilt binary both move the
// second without moving the first.
function codeVersion() {
  const git = (a) => {
    const r = spawnSync('git', a, { cwd: process.cwd(), encoding: 'utf8' });
    return r.status === 0 ? r.stdout.trim() : '';
  };
  const digest = (p) => {
    try { return sha(readFileSync(p)).slice(0, 16); } catch { return ''; }
  };
  const resolveBin = (b) => {
    if (b.includes('/')) return resolve(b);
    const r = spawnSync('command', ['-v', b], { shell: true, encoding: 'utf8' });
    return r.status === 0 ? r.stdout.trim() : b;
  };
  return {
    commit: git(['rev-parse', 'HEAD']),
    dirty: git(['status', '--porcelain']).length > 0,
    ingestBinDigest: digest(resolveBin(ingestBin)),
    publishBinDigest: digest(resolveBin(publishBin)),
  };
}

function loadLedger() {
  if (!existsSync(LEDGER)) {
    return {
      format: 'blocktracer/coverage-ledger@1',
      chain, endpoint: url,
      // Padded, and the width is recorded so a later reader can tell a
      // nine-digit key from a ten-digit one rather than inferring it.
      keyPadding: pad,
      ranges: {},
    };
  }
  const l = JSON.parse(readFileSync(LEDGER, 'utf8'));
  if (l.format !== 'blocktracer/coverage-ledger@1') {
    console.error(`refusing: ${LEDGER} is not a blocktracer/coverage-ledger@1`);
    process.exit(1);
  }
  // A LEDGER WRITTEN AT ANOTHER PADDING IS REFUSED RATHER THAN MERGED. Mixing
  // widths in one key space reintroduces exactly the ordering defect the padding
  // exists to remove, and does it invisibly: `000074000-…` and `74000-…` are two
  // keys for one range, both of which the coverage arithmetic would count.
  if (l.keyPadding !== pad) {
    console.error(`refusing: ${LEDGER} uses keyPadding ${l.keyPadding}, this run uses ${pad}`);
    process.exit(1);
  }
  if (l.endpoint && l.endpoint !== url) {
    console.error(`refusing: ${LEDGER} covers ${l.endpoint}, this run reads ${url}`);
    process.exit(1);
  }
  return l;
}

function saveLedger(l) {
  mkdirSync(stateDir, { recursive: true });
  const tmp = `${LEDGER}.tmp`;
  writeFileSync(tmp, JSON.stringify(l, null, 1) + '\n');
  renameSync(tmp, LEDGER);
}

// ── RPC ─────────────────────────────────────────────────────────────────────
//
// A RATE LIMIT IS NOT A HEIGHT THE NODE DECLINES TO SERVE, AND THE DIFFERENCE
// IS THE WHOLE COVERAGE CLAIM. `fetchRange` records any `__err` as `notServed`,
// which is correct for "Unknown block" — a height above the tip — and a
// falsehood for "Too many requests", which says nothing about the height at
// all. The public endpoint returns its limit BOTH as HTTP 429 and as a
// JSON-RPC error body, and the previous shape mishandled each: `!r.ok` retried
// three times with no delay (three more requests into a bucket that is already
// empty), and `j.error` returned on the first sighting with no retry at all.
// Either path ended with the block written down as one the chain does not have.
// Over a genesis-to-tip backfill that turns a throttle into thousands of
// invented holes in a ledger whose entire job is to say which blocks are
// covered.
//
// So: rate limits are told apart from every other error, waited out with
// exponential backoff (honouring `Retry-After` when the endpoint sends one),
// and — if the wait is exhausted — returned as a DISTINCT marker that
// `fetchRange` refuses to record as `notServed`.
let rpcId = 0;
let rpcCalls = 0;
let rpcFaults = 0;
let rpcRateLimited = 0;      // how many individual attempts were throttled
let rpcBackoffMs = 0;        // total time spent waiting out a limit
let rpcRetryAfterMs = 0;     // the longest `Retry-After` the endpoint asked for
/** Past this, a `Retry-After` is reported rather than slept through. */
const MAX_HONOURED_RETRY_AFTER_MS = 90_000;
const RATE_LIMIT_RE = /too many requests|rate limit|quota/i;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Returned instead of `__err` when the endpoint throttled us. Never a height. */
const isThrottle = (v) => v && typeof v === 'object' && v.__throttled === true;

async function rpc(method, params = []) {
  rpcCalls++;
  let sawThrottle = false;
  // Pace every call, so a long range is a steady trickle rather than a burst
  // that empties the bucket in the first second and then fails for minutes.
  if (minGapMs > 0) {
    const wait = lastCallAt + minGapMs - Date.now();
    if (wait > 0) await sleep(wait);
    lastCallAt = Date.now();
  }
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    let limited = false, retryAfterMs = 0;
    try {
      const r = await fetch(url, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
      });
      if (r.status === 429) {
        limited = true;
        const ra = Number(r.headers.get('retry-after'));
        if (Number.isFinite(ra) && ra > 0) retryAfterMs = ra * 1000;
      } else if (!r.ok) {
        rpcFaults++;
        await sleep(250 * (attempt + 1));
        continue;
      } else {
        const j = await r.json();
        if (j.error) {
          const msg = j.error.message ?? 'rpc error';
          // The endpoint also delivers its limit inside a 200. Same thing.
          if (j.error.code === 429 || RATE_LIMIT_RE.test(msg)) limited = true;
          else { rpcFaults++; return { __err: msg }; }
        } else return j.result;
      }
    } catch (e) {
      rpcFaults++;
      if (attempt === maxAttempts - 1) return { __err: `fetch: ${e.message}` };
      await sleep(250 * (attempt + 1));
      continue;
    }
    if (limited) {
      rpcRateLimited++; sawThrottle = true;
      // `Retry-After` WINS, BUT IT IS NOT OBEYED SILENTLY AT ANY LENGTH. This
      // endpoint answers a throttled request with `retry-after: 2465` — forty-one
      // minutes — and sleeping that inside a per-call retry loop turns one block
      // into a forty-one-minute stall that looks exactly like a hang. Past the
      // cap the wait is the CALLER'S decision, so the marker carries the number
      // the endpoint gave and the run ends promptly enough to say why.
      if (retryAfterMs > MAX_HONOURED_RETRY_AFTER_MS) {
        rpcRetryAfterMs = Math.max(rpcRetryAfterMs, retryAfterMs);
        return { __throttled: true, __retryAfterMs: retryAfterMs,
                 __err: `rate limited; endpoint asked for ${Math.round(retryAfterMs / 1000)}s` };
      }
      const backoff = retryAfterMs > 0
        ? retryAfterMs
        // Exponential with a floor and a ceiling, jittered so many callers do
        // not step back in lockstep.
        : Math.min(60_000, 1000 * 2 ** attempt) * (0.75 + Math.random() * 0.5);
      rpcBackoffMs += backoff;
      await sleep(backoff);
    }
  }
  // Out of attempts. If the last thing we saw was a throttle, say so — the
  // caller must not write this height down as absent from the chain.
  if (sawThrottle) return { __throttled: true, __err: 'rate limited' };
  return { __err: 'exhausted retries' };
}

// ── phase 1: fetch the range into its own snapshot ──────────────────────────
async function fetchRange(nodeInfo, tip, finalized) {
  const dir = join(RANGES, rangeKey);
  mkdirSync(join(dir, 'ct'), { recursive: true });
  const p = join(dir, 'snapshot.json');

  const blocks = [];
  const transactions = [];
  let requested = 0, served = 0, notServed = [], throttledOut = [];
  const t0 = Date.now();

  // ── headers, optionally 50 to a request ───────────────────────────────────
  //
  // WHY THIS FLAG EXISTS, AND WHY IT IS OFF BY DEFAULT. One `node_getBlock(n)`
  // per height is 75,911 requests for a genesis-to-tip pass, and on the public
  // endpoint the REQUEST COUNT — not latency, not bandwidth — is what the
  // backfill is rationed by. `node_getBlocks(from, limit)` returns the same
  // block objects fifty at a time, which cuts the header half of the pass by
  // 50x. It does not touch the body half: `totalManaUsed` is a header field, so
  // the existing "did this block burn mana" test still decides which blocks are
  // fetched again WITH their transactions, and those stay one request each.
  //
  // Off by default because the one-at-a-time path is the one that has been run
  // end to end, and a coverage backfill is not the place to make a fetch
  // strategy prove itself implicitly.
  const headerCache = new Map();
  async function headerFor(n) {
    if (!batchHeaders) return rpc('node_getBlock', [n]);
    if (headerCache.has(n)) return headerCache.get(n);
    headerCache.clear();
    const span = Math.min(batchHeaders, to - n + 1);
    const batch = await rpc('node_getBlocks', [n, span]);
    if (isThrottle(batch) || !batch || batch.__err || !Array.isArray(batch)) {
      // Fall back to the single-block call for this height rather than writing
      // off fifty heights on one failed request.
      return batchHeaders && !isThrottle(batch) ? rpc('node_getBlock', [n]) : batch;
    }
    for (const b of batch) {
      // `node_getBlocks` keys its answers with a top-level `number`; the
      // per-block call's shape has it under `globalVariables` instead.
      const num = Number(b?.number ?? b?.header?.globalVariables?.blockNumber ?? NaN);
      if (Number.isFinite(num)) headerCache.set(num, b);
    }
    // A height the batch simply omitted is asked for directly, so "the batch
    // was short" never silently becomes "the chain has no such block".
    return headerCache.has(n) ? headerCache.get(n) : rpc('node_getBlock', [n]);
  }

  for (let n = from; n <= to; n++) {
    requested++;
    const head = await headerFor(n);
    // A height we never got an answer about is NOT a height the node declined.
    // It is recorded separately and the range is reported short, so the ledger
    // cannot later be read as "the chain has no block here".
    if (isThrottle(head)) { throttledOut.push(n); continue; }
    if (!head || head.__err) {
      // A height the node does not serve is RECORDED as not served, never
      // written as an empty block: an invented row is indistinguishable from a
      // real block that settled nothing, and the ledger has to be able to say
      // this range is short rather than claiming it is complete.
      notServed.push(n);
      continue;
    }
    served++;
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
      // The header says this block burned mana, so it HAS transactions. A
      // throttled or failed body read here would otherwise publish the block
      // with an empty transaction list — a block that silently loses its
      // contents is worse than a block that is missing, because nothing
      // downstream can tell it apart from a genuinely empty one.
      if (isThrottle(full) || !full || full.__err || !full.body) {
        // `row` is not appended until the end of the iteration, so skipping
        // here leaves nothing behind to undo beyond the `served` tally.
        served--; throttledOut.push(n); continue;
      }
      for (const [i, eff] of (full.body.txEffects ?? []).entries()) {
        row.transactions.push(eff.txHash);
        // ── WHAT A ROW SAYS BEFORE ANYTHING IS REPLAYED ────────────────────
        //
        // THE SENTENCE THIS USED TO WRITE WAS FALSE, and it was written onto
        // 18,508 rows. Every first-in-block transaction in a historic range was
        // recorded `pruned` with "it can no longer be re-executed", on the
        // reasoning that a range below the finalized tip has no bodies. The
        // first half is right — `getTxByHash` is a mempool query and the pool
        // deletes at finalization — and the conclusion does not follow, because
        // the node is not the only source. Aztec's own keyless `TxFileStore`
        // serves one content-addressed `.bin` per transaction hash for the whole
        // chain, self-verifying (`Tx.toBuffer()` writes `txHash` first), and
        // `backfill-bodies.mjs` has been able to fetch from it since before this
        // sentence was written. Measured on this chain: 21 of 21 bodies sampled
        // from block 10 to block 75,969 came back 200 and self-verified, and
        // six of the ten oldest sampled transactions replayed and reproduced
        // their block's published effects exactly.
        //
        // So a first-in-block transaction in a range ingested WITHOUT `--replay`
        // has not met an obstacle. It has not been looked at. That is
        // `not-attempted` — a member of the closed set whose whole purpose is to
        // be a statement about the run rather than about the chain — and the
        // narrative says where the body can be had, so a later run knows this is
        // work outstanding rather than a limit reached.
        //
        // With `--replay` on, this is a PLACEHOLDER: `replayRange` overwrites
        // every one of these rows with what the driver decided. What survives it
        // are the transactions a budget or a rate limit stopped the run reaching,
        // which is exactly what this reason means.
        const why = i !== 0
          ? refuseNotFirstInBlock({ blockNumber: n, txIndexInBlock: i,
                                    where: 'ingest-range.mjs' })
          : { outcome: 'not-attempted', ...classifyRefusal({
              condition: 'historic-range-not-replayed',
              where: 'ingest-range.mjs',
              narrative: doReplay
                ? `This transaction is first in block ${n} and its body is obtainable `
                  + `from the keyless transaction file store, so it is replayable from `
                  + `published data. This run was asked to replay and did not reach it.`
                : `This transaction is first in block ${n}, so it can be re-executed `
                  + `from published data: the node no longer serves its body, but the `
                  + `keyless transaction file store does, for the whole chain. This `
                  + `range was ingested without --replay, so nothing was attempted and `
                  + `no trace was recorded. Nothing about the chain stopped it.`,
            }) };
        transactions.push({
          txHash: eff.txHash, blockNumber: n, txIndexInBlock: i,
          revertCode: eff.revertCode, transactionFee: eff.transactionFee,
          bodyRetained: false, effectVisible: true, firstInBlock: i === 0,
          observedAt: new Date().toISOString(), ...why,
        });
      }
    }
    blocks.push(row);
  }

  blocks.sort((a, b) => b.number - a.number);
  const snap = {
    format: SNAPSHOT_FORMAT,
    provenance: {
      kind: 'live-capture',
      chain, label, endpoint: url,
      capturedAt: new Date().toISOString(),
      firstCapturedAt: new Date().toISOString(),
      // `?? ''` ON ALL FOUR. `rollupAddress` had it and the three beside it did not,
      // and `JSON.stringify` drops an `undefined`-valued key — so a node whose
      // `getNodeInfo` omits a field wrote a snapshot missing the member while this
      // source said it wrote one, and `ingest.nim` read four of them by unguarded
      // bracket access (a `KeyError` in Nim's `std/json`). Reproduced against a real
      // mainnet capture; see the same block in `follow-chain.mjs` for the measurement.
      nodeVersion: nodeInfo.nodeVersion ?? '',
      l1ChainId: nodeInfo.l1ChainId ?? '',
      rollupVersion: nodeInfo.rollupVersion ?? '',
      rollupAddress: nodeInfo.l1ContractAddresses?.rollupAddress ?? '',
      tool: 'tools/chain/ingest-range.mjs',
      range: { from, to },
    },
    captures: [],
    window: { tip, finalized, replayableFrom: finalized + 1, replayableTo: tip,
              blocks: tip - finalized },
    counts: {},
    blocks,
    transactions,
  };
  recount(snap);
  // The gate on the metadata-only path too, not only after a replay. Every row this function
  // writes is untraced by construction, so if the closed set can ever be open here it is open
  // for the whole chain — 138,287 objects were published from rows this branch produced.
  assertRefusalsAreClosed(snap.transactions);
  const tmp = `${p}.tmp`;
  writeFileSync(tmp, JSON.stringify(snap, null, 1) + '\n');
  renameSync(tmp, p);

  return {
    dir, requested, served, notServed, throttledOut,
    blocks: blocks.length,
    transactions: transactions.length,
    outcomes: outcomeCounts(transactions),
    fetchMs: Date.now() - t0,
    snapshotBytes: statSync(p).size,
    // The snapshot's IDENTITY, over the chain data only — the two timestamps in
    // `provenance` move on every fetch and would make a byte-identical re-fetch
    // of an immutable historic range look like a different one.
    //
    // `observedAt` DID EXACTLY THAT, and it is per-transaction so it hid inside
    // the very array this digest is supposed to be over. Measured: the same 200
    // blocks fetched twice produced identical blocks and identical transactions
    // in every other field, and two different digests. The cost is not cosmetic
    // — `supersedes` is set when a range's digest changes, so every re-fetch of
    // an immutable range recorded that its content had been replaced, which is
    // the ledger asserting the chain rewrote itself.
    //
    // It is stripped rather than removed from the snapshot: when a height was
    // read is worth keeping, it just is not part of what was read.
    contentDigest: sha(JSON.stringify({
      blocks,
      transactions: transactions.map(({ observedAt, ...rest }) => rest),
    })),
  };
}

function outcomeCounts(txs) {
  const o = {};
  for (const t of txs) o[t.outcome ?? 'unknown'] = (o[t.outcome ?? 'unknown'] ?? 0) + 1;
  return o;
}

// THE TALLY IS `lib/recount.mjs`'s, and it used to be this file's own copy of it. Three
// producers had three copies and they had drifted — one omitted `privateOnly`, one
// preserved every outcome line across a run that added rows — and the drift reached
// committed data. See that module's header: a snapshot's `counts` exists "so a partial
// ingest is detectable" (Data-Contract.md §5.2), so a restatable tally is a detector with
// more than one answer.
const recount = recountSnapshot;

// ── phase 1b: replay what the range can replay ──────────────────────────────
//
// SEPARATE FROM THE FETCH, AND RE-RUNNABLE ON ITS OWN. The fetch is metadata and
// costs one or two requests per height; a replay costs roughly fifteen node calls
// per transaction after the proxy's cache, and on this endpoint requests are the
// only budget. Splitting them means a range whose replay was cut short by a rate
// limit is resumed by re-running the same command — the snapshot is on disk, the
// bodies are mirrored, the rows that were reached are traced, and the ones that
// were not still say `not-attempted`, which is the query for what remains.
//
// It is IDEMPOTENT over already-traced rows: a transaction that produced a
// container is never replayed again, so a re-run costs only what it has left to do.
async function replayRange(dir) {
  const p = join(dir, 'snapshot.json');
  const snap = JSON.parse(readFileSync(p, 'utf8'));
  const t0 = Date.now();

  // ── the toolchain, proved BEFORE anything is spent on it ──────────────────
  //
  // `preflightToolchain` is `follow-chain.mjs`'s, unchanged, and its header
  // records what it cost to learn: five live transactions were caught inside the
  // replayable window and recorded `refused / unknown` in twelve milliseconds
  // each because `--node` was a Node 20 with no `--experimental-wasm-exnref`.
  // A historic body does not prune, so the loss here is a wasted run rather than
  // an unrepeatable one — but a range of 200 transactions each refusing in 12 ms
  // is still 200 rows asserting something false about the chain.
  if (!runtime) {
    return { ok: false, problems: ['--replay needs --runtime <path-to-aztec-avm-runtime>; '
      + 'this repository carries no AVM'] };
  }
  const pre = await preflightToolchain({ nodeBin, runtime, avm, ctWriter });
  if (!pre.ok) return { ok: false, problems: pre.problems };

  // ── where the bodies come from ────────────────────────────────────────────
  //
  // DERIVED, NEVER PASTED — the rule `backfill-bodies.mjs` states at length. The
  // base URL is `txCollectionFileStoreUrls` out of `AztecProtocol/networks`, and
  // the path segment beneath it is computed from THIS node's own answer, so a
  // store location cannot silently drift onto a different deployment from the one
  // the hashes came from.
  let base = bodyStore;
  if (!base) {
    try {
      const res = await fetch(configRef);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const cfg = await res.json();
      base = cfg?.[network]?.txCollectionFileStoreUrls?.[0] ?? '';
    } catch (e) {
      return { ok: false, problems: [`could not read ${configRef}: ${e.message}. `
        + `Pass --body-store <url> to name the transaction file store directly.`] };
    }
  }
  if (!base) {
    return { ok: false, problems: [`${configRef} declares no txCollectionFileStoreUrls for `
      + `${network}, so no body source is known and nothing historic can be replayed.`] };
  }
  let basePath;
  try {
    basePath = storeBasePath(nodeInfo);
  } catch (e) {
    return { ok: false, problems: [e.message] };
  }

  const proxy = await startBodyProxy({
    upstreamUrl: url, runtime, storeBase: base, storeBasePath: basePath,
    bodyDir, rps: replayRps, storeAttempts, storeTimeoutMs,
    log: (m) => say(`proxy: ${m}`),
  });

  const runtimeCommit = (() => {
    const r = spawnSync('git', ['rev-parse', 'HEAD'], { cwd: runtime, encoding: 'utf8' });
    return r.status === 0 ? r.stdout.trim() : '';
  })();

  const perTxMs = [];
  let attempted = 0;
  let stoppedBy = null;
  // THE TWO STORE FACTS THAT REACH THE REPORT AND THE EXIT CODE. `storeOutcome` and
  // `storeReason` were written onto rows and read by nothing — the review's finding, and
  // a field with no consumer is a field nobody notices going wrong. These are the
  // consumers: `storeUnreachable` is how much of the range is outstanding for want of a
  // host, and `mismatchedBodies` is a corpus contradiction, which the driver turns into a
  // non-zero exit the way `backfill-bodies.mjs` already does.
  let storeUnreachable = 0;
  const mismatchedBodies = [];
  mkdirSync(join(dir, 'ct'), { recursive: true });
  mkdirSync(join(dir, 'sources'), { recursive: true });

  for (const t of snap.transactions) {
    // Already traced by an earlier run of this same range. Nothing to redo.
    if (t.outcome === 'replayed' || t.outcome === 'divergent') continue;
    // Not ours to attempt: index > 0 cannot be re-executed from published data
    // at any age, which is the runtime's constraint and not a budget.
    if (!t.firstInBlock) continue;
    if (proxy.throttled) { stoppedBy = 'endpoint-throttled-this-run'; break; }
    if (replayMax > 0 && attempted >= replayMax) { stoppedBy = 'beyond-this-run-budget'; break; }

    // ── A RE-RUN RE-DECIDES, AND A STALE VERDICT MUST NOT SURVIVE IT ──────
    //
    // This loop is resumable, so a row reaching it may already carry the
    // findings of an earlier attempt — a `refusal` class name, a `detail`, a
    // `refusalReason`. `Object.assign` does not clear a key the new verdict
    // fails to set, so without this a transaction reclassified from
    // `runtime-refused` to `private-only` would keep the crash it was misfiled
    // by, and one that came to be traced would keep the sentence saying it was
    // not. Every field that is a JUDGEMENT is dropped; every field that is an
    // OBSERVATION about the transaction — hash, block, index, revertCode, fee —
    // is untouched, because those came from the chain and not from us.
    for (const k of ['refusal', 'refusalReason', 'reason', 'detail',
                     'storeOutcome', 'storeReason', 'container', 'containerBytes',
                     'sourceBundles', 'effects', 'recording', 'artifacts',
                     'skipped', 'roots', 'rootsAnyAgree', 'publicCalls']) {
      delete t[k];
    }

    // ── ASK THE BODY BEFORE SPENDING A PROCESS ON IT ──────────────────────
    //
    // Two of the outcomes a transaction can have are decidable from the body
    // alone, and both were previously reached the expensive way — by spawning
    // the driver, letting it make a dozen node calls, and reading what it died
    // of. The proxy has already fetched and decoded the body by the time either
    // question is asked, so asking costs nothing that the replay would not have
    // spent one moment later, and it saves the process, the calls and — in the
    // second case — a crash that has to be INTERPRETED rather than measured.
    const seen = await proxy.inspect(t.txHash);

    // ── FOUR STORE OUTCOMES, AND THEY ARE NOT ONE FACT ────────────────────
    //
    // This was `if (seen.outcome !== 'verified')` into `refuseBodyUnavailable`
    // for all four of `absent`, `mismatched`, `truncated` and `unavailable`.
    // `backfill-bodies.mjs`'s own header states at length why that collapse is
    // wrong — "one says the corpus has a hole, the other says the corpus lied",
    // and `unavailable` "is a statement about the RUN, not about the corpus" —
    // and this seam folded all of it back together at the one place where the
    // answer is PUBLISHED. `body-unavailable` is declared durability
    // `permanent`, so a store 503, a 429 or a TLS failure published "this
    // transaction can never be re-executed" about a body the store holds.
    if (seen.outcome === 'unavailable') {
      // A STATEMENT ABOUT THE RUN. Repairable, and it says what to do about it.
      Object.assign(t, refuseBodySourceUnreachable({
        blockNumber: t.blockNumber,
        storeOutcome: seen.outcome, storeReason: seen.reason,
        where: 'ingest-range.mjs replayRange',
      }), { storeOutcome: seen.outcome, storeReason: seen.reason });
      storeUnreachable++;
      // AND IT CAN END THE RUN, exactly as the node path's throttle does. The
      // proxy sets this when the store asked for longer than the honoured wait
      // or stopped answering altogether; continuing would meet the same host
      // for every remaining key and write this reason onto the whole range.
      if (proxy.storeThrottled) {
        stoppedBy = 'body-store-unreachable-this-run';
        break;
      }
      continue;
    }

    if (seen.outcome === 'mismatched') {
      // ── "THE CORPUS LIED", AND IT IS AN ALARM HERE TOO ──────────────────
      //
      // A 200 whose leading 32 bytes are some other hash is a miss wearing a
      // success, and it is the one failure the whole single-source trust model
      // rests on catching: `Tx.toBuffer()` serialises `txHash` first, so on a
      // correct payload those bytes ARE the key. `backfill-bodies.mjs` exits 1
      // on it — "the exit code says whether the JOIN HELD" — and this seam
      // filed it as `body-unavailable` and exited 0, so the mirroring tool
      // treated it as a contradiction and the publishing path treated it as a
      // pruned body. Two tools, one corpus, opposite verdicts.
      //
      // The row still gets an honest reason so the page is not blank, and the
      // RUN is what fails: this is not a property of the transaction.
      Object.assign(t, refuseBodyUnavailable({
        blockNumber: t.blockNumber,
        observedAs: `the keyless transaction file store answered a 200 for its key whose `
          + `leading 32 bytes are a DIFFERENT transaction hash, which is not a body`,
        // THE EVIDENCE FOR THE SECOND CLAUSE, PASSED IN RATHER THAN ASSUMED. This member
        // is durability PERMANENT and `refuseBodyUnavailable` now refuses to write it
        // without the store's own answer about this key — see
        // `BodyUnavailableWithoutStoreEvidence`. The same value goes onto the row below,
        // so the evidence outlives the run that gathered it.
        storeOutcome: seen.outcome,
        where: 'ingest-range.mjs replayRange',
      }), { storeOutcome: seen.outcome, storeReason: seen.reason });
      mismatchedBodies.push({ txHash: t.txHash, blockNumber: t.blockNumber,
                              reason: seen.reason });
      continue;
    }

    if (seen.outcome !== 'verified') {
      // `absent` — the store answered 404 — or `truncated`, a 200 that is not a
      // body. The node prunes bodies and the file store does not hold this one
      // either, so nothing serves it. That is `body-unavailable`, permanent, and
      // it is the ONE case where the old `pruned` sentence was right all along.
      Object.assign(t, refuseBodyUnavailable({
        blockNumber: t.blockNumber,
        observedAs: `the keyless transaction file store — which serves bodies for the rest `
          + `of this chain's history — answered ${seen.outcome} for its key too`,
        // As above: the store's answer is the evidence for the permanent claim and is
        // required by the producer rather than inferred from the branch it is in.
        storeOutcome: seen.outcome,
        where: 'ingest-range.mjs replayRange',
      }), { storeOutcome: seen.outcome, storeReason: seen.reason });
      continue;
    }

    if (seen.publicCalls === 0) {
      // A PRIVATE-ONLY TRANSACTION, AND IT IS NOT A REFUSAL. There is no public
      // execution to re-run: the private half ran in a wallet and only its
      // effects were published. `private-only` carries a sentence and NO reason
      // id, which is how `blocktracer_client/trace.nim` has always distinguished
      // "the chain never published this execution" from "we declined it" — a
      // distinction the producer side could not express until this outcome
      // existed, so these rows used to be `runtime-refused` (repairable) off the
      // back of a driver crash.
      Object.assign(t, { bodyRetained: true, publicCalls: 0 },
                    chainPublishedNoPublicExecution({ blockNumber: t.blockNumber }));
      delete t.refusalReason;
      continue;
    }

    attempted++;
    const started = Date.now();
    const ctRel = `ct/${t.txHash}.ct`;
    const srcRel = `sources/${t.txHash}.json`;
    const decided = await replayTransaction({
      nodeBin, runtime, url: proxy.url, txHash: t.txHash,
      ctPath: join(dir, ctRel), ctRelative: ctRel,
      sourcesPath: join(dir, srcRel), sourcesRelative: srcRel,
      avm, ctWriter,
    });
    const ms = Date.now() - started;
    perTxMs.push(ms);

    // A THROTTLE THAT ARRIVED DURING THIS REPLAY IS NOT THIS TRANSACTION'S
    // REFUSAL. The proxy answers a throttled call with a JSON-RPC error, the
    // driver dies on it, and `decideOutcome` would file whatever class it named
    // against a transaction that had done nothing wrong. So the proxy's own flag
    // is consulted first and the row is left `not-attempted`, which is what it is.
    if (proxy.throttled) {
      stoppedBy = 'endpoint-throttled-this-run';
      attempted--;
      perTxMs.pop();
      break;
    }

    // `recordedBy` is per ROW and not per snapshot: a range may be replayed over
    // more than one runtime build, and `ingest.nim` derives `recorderVersion` from
    // this field first. Same reason `follow-chain.mjs` stamps it.
    Object.assign(t, { bodyRetained: true, recordedBy: runtimeCommit,
                       replayedAt: new Date().toISOString(), replayMs: ms }, decided);
    // A traced row must carry NO refusal reason — `auditRefusals` refuses the two
    // statements folded together — and `decided` does not clear a key it does not
    // set, so a placeholder's reason would survive onto a successful replay.
    if (decided.replayed) { delete t.refusalReason; delete t.reason; delete t.detail; }
  }

  // Whatever the run did not reach keeps `not-attempted`, and the narrative names
  // WHICH of the run's own limits stopped it. The reason id is the same because
  // the statement is the same; the sentence differs because the operator's next
  // action differs — wait out a ban, or raise a budget.
  if (stoppedBy) {
    for (const t of snap.transactions) {
      if (t.outcome !== 'not-attempted' || !t.firstInBlock) continue;
      // A ROW THIS RUN ALREADY DECIDED IS NOT A ROW IT DID NOT REACH. `not-attempted` is
      // the OUTCOME of both "never looked at" and `body-source-unreachable`, so this loop
      // — whose whole subject is the rows the run's own limit stopped it reaching — would
      // otherwise overwrite a measured store outage with a sentence claiming the body is
      // served and nobody asked. The reason id is what distinguishes them.
      if (t.refusalReason !== 'not-attempted') continue;
      Object.assign(t, classifyRefusal({
        condition: stoppedBy === 'body-store-unreachable-this-run'
          ? 'body-source-could-not-be-asked' : stoppedBy,
        where: 'ingest-range.mjs replayRange',
        narrative: stoppedBy === 'endpoint-throttled-this-run'
          ? `This transaction is first in block ${t.blockNumber} and its body is served by `
            + `the keyless transaction file store, so it is replayable from published data. `
            + `The node endpoint began rate-limiting this client before the run reached it `
            + `and the run stopped rather than record a limit of ours as a property of the `
            + `chain. Re-running this range replays it.`
          : stoppedBy === 'body-store-unreachable-this-run'
          ? `This transaction is first in block ${t.blockNumber}, so it can be re-executed `
            + `from published data. The source that serves transaction bodies stopped `
            + `answering this client before the run reached this transaction, and the run `
            + `stopped rather than record somebody else's outage as a permanent property `
            + `of the chain. Nothing is known here about whether the body is held; `
            + `re-running this range asks again.`
          : `This transaction is first in block ${t.blockNumber} and its body is served by `
            + `the keyless transaction file store, so it is replayable from published data. `
            + `This run reached its own --replay-max of ${replayMax} before taking it. `
            + `Nothing about the transaction or the chain stopped it; the run did.`,
      }));
    }
  }

  recount(snap);
  assertRefusalsAreClosed(snap.transactions);
  const tmp = `${p}.tmp`;
  writeFileSync(tmp, JSON.stringify(snap, null, 1) + '\n');
  renameSync(tmp, p);

  perTxMs.sort((a, b) => a - b);
  const outcomes = outcomeCounts(snap.transactions.filter((t) => t.firstInBlock));
  return {
    ok: true,
    note: pre.note ?? '',
    runtime, runtimeCommit, avm, ctWriter, nodeBin,
    store: { base, basePath },
    // `attempted` is DRIVER RUNS, and the three counts beside it are what became of the
    // first-in-block population — which is larger, because a private-only transaction and a
    // body nothing serves are both decided without the driver ever starting. Reporting one
    // number for both would make "attempted" mean two things in one report.
    firstInBlock: snap.transactions.filter((t) => t.firstInBlock).length,
    attempted,
    replayed: outcomes.replayed ?? 0,
    divergent: outcomes.divergent ?? 0,
    refused: outcomes.refused ?? 0,
    privateOnly: outcomes['private-only'] ?? 0,
    bodyUnavailable: outcomes.pruned ?? 0,
    notAttempted: outcomes['not-attempted'] ?? 0,
    // ── THE STORE'S OWN ANSWERS, NOW WITH A CONSUMER ────────────────────────────────
    //
    // `storeOutcome` / `storeReason` were written onto rows and read by nothing. These
    // are the two facts they carry that a run has to act on: how much of the range is
    // outstanding for want of a host (repairable, and the count IS the work queue), and
    // whether the corpus contradicted itself. The second is a non-zero exit in the
    // driver, matching `backfill-bodies.mjs`, which exits 1 on `counts.mismatched`.
    bodySourceUnreachable: storeUnreachable,
    mismatchedBodies,
    stoppedBy,
    wallMs: Date.now() - t0,
    perTxMs: perTxMs.length
      ? { min: perTxMs[0], median: perTxMs[Math.floor(perTxMs.length / 2)],
          max: perTxMs[perTxMs.length - 1],
          mean: Math.round(perTxMs.reduce((a, b) => a + b, 0) / perTxMs.length) }
      : null,
    refusals: refusalCounts(snap.transactions).byReason,
    // The runtime's own class names, which are EVIDENCE and not the closed set.
    // A `runtime-refused` count of forty says our vocabulary held; this says what
    // it held against, and it is the list a runtime fix would be aimed at.
    runtimeClasses: snap.transactions.reduce((m, t) => {
      if (t.outcome === 'refused' && t.refusal) m[t.refusal] = (m[t.refusal] ?? 0) + 1;
      return m;
    }, {}),
    proxy: { ...proxy.stats, closed: await proxy.close().then(() => true) },
  };
}

// ── phase 2: the union snapshot the tree is ingested from ───────────────────
function mergeSnapshots(keys) {
  const blocksByNumber = new Map();
  const txByHash = new Map();
  let newest = null;
  let window = null;
  let provenance = null;
  let captures = [];
  for (const k of keys.slice().sort()) {         // padded ⇒ lexicographic == numeric
    const p = join(RANGES, k, 'snapshot.json');
    if (!existsSync(p)) continue;
    const s = JSON.parse(readFileSync(p, 'utf8'));
    for (const b of s.blocks) blocksByNumber.set(b.number, b);
    for (const t of s.transactions) if (!txByHash.has(t.txHash)) txByHash.set(t.txHash, t);
    captures = captures.concat(s.captures ?? []);
    // The union's window is the one observed LATEST: it describes what was
    // replayable at the moment the newest range was read, which is the only
    // moment any of it is true of.
    const at = s.provenance?.capturedAt ?? '';
    if (newest === null || at > newest) {
      newest = at; window = s.window; provenance = s.provenance;
    }
  }
  const blocks = [...blocksByNumber.values()].sort((a, b) => b.number - a.number);
  const transactions = [...txByHash.values()].sort(
    (a, b) => a.blockNumber - b.blockNumber || a.txIndexInBlock - b.txIndexInBlock);
  const merged = {
    format: SNAPSHOT_FORMAT,
    provenance: { ...provenance, tool: 'tools/chain/ingest-range.mjs (merged)',
                  range: undefined, mergedRanges: keys.slice().sort() },
    captures, window, counts: {}, blocks, transactions,
  };
  recount(merged);
  const dir = join(stateDir, 'merged');
  mkdirSync(join(dir, 'ct'), { recursive: true });
  mkdirSync(join(dir, 'sources'), { recursive: true });
  // ── THE CONTAINERS HAVE TO BE WHERE THE MERGED SNAPSHOT SAYS THEY ARE ─────
  //
  // A row's `container` is `ct/{hash}.ct`, RELATIVE to the snapshot directory —
  // deliberately, so a committed snapshot carries no absolute path from whoever
  // ran the capture. That made the merged directory a snapshot with no artifacts
  // beside it: correct for a metadata-only backfill, which is all this tool
  // produced, and a silent hole the moment a range starts writing containers.
  // `ingest.nim` would find the row, look for the file and refuse — or worse,
  // publish a row pointing at nothing.
  //
  // Linked rather than copied: a range's containers are its own, the merged
  // directory is a rendering of one moment (`ingest-range` deletes and rebuilds
  // the tree every run for the same reason), and hard-linking keeps one copy of
  // bytes that can run to hundreds of kilobytes per transaction. A cross-device
  // link falls back to a copy rather than failing the run.
  let linked = 0;
  for (const t of transactions) {
    for (const rel of [t.container, t.sourceBundles]) {
      if (typeof rel !== 'string' || rel.length === 0) continue;
      const owner = rangeKeyFor(t, keys);
      if (!owner) continue;
      const from = join(RANGES, owner, rel);
      const to = join(dir, rel);
      if (!existsSync(from) || existsSync(to)) continue;
      mkdirSync(dirname(to), { recursive: true });
      try { linkSync(from, to); } catch { copyFileSync(from, to); }
      linked++;
    }
  }
  writeFileSync(join(dir, 'snapshot.json'), JSON.stringify(merged, null, 1) + '\n');
  return { dir, blocks: blocks.length, transactions: transactions.length, linked,
           blockHashes: blocks.map((b) => b.hash) };
}

/** Which covered range holds this transaction's artifacts. The ledger's keys are
 *  padded `from-to`, so the range is found by arithmetic on the block number and
 *  not by scanning directories — a scan would silently pick the first match if two
 *  ranges ever overlapped, and this way an overlap is simply the first one that
 *  contains it, which is also what `mergeSnapshots` itself resolved to. */
function rangeKeyFor(t, keys) {
  for (const k of keys) {
    const [a, b] = k.split('-').map(Number);
    if (Number.isFinite(a) && Number.isFinite(b) && t.blockNumber >= a && t.blockNumber <= b) {
      return k;
    }
  }
  return null;
}

// ── the generation id, derived from what the generation CONTAINS ────────────
//
// A GENERATION MAP IS IMMUTABLE AT ITS PATH, AND THAT IS NOT A STYLE NOTE.
// `publisher.nim` classifies `d/{chain}/g/{gen}/**` as `ocGenMap` /
// `ocGenRoot`, whose strategy is `stKeyExistence`: present ⇒ skip. So a second
// publish at the SAME generation id does not update the height map, the block
// list or the generation root — it skips all three — while `current.json`, a
// pointer, is rewritten unconditionally and moves the head.
//
// Measured, on this machine, with `--no-merge` and generation "1": publish
// 74000-74049, then publish 74050-74099. The store ends with all 100 block
// objects present and correct, `current.json` naming head 74099 — and
// `g/1/height/0.json` holding exactly the 50 heights 74000-74049, with no
// entry for 74099 at all. The pointer advertises a head the generation it
// points at cannot resolve.
//
// `ingest.nim` defaults the generation to the literal "1" and
// `static_export.nim` never varies it, so any pipeline that publishes a growing
// chain more than once lands in that state. The fix is not to make the maps
// mutable — the contract's whole ordering argument (content before references,
// root before pointer) depends on them being sealed — it is to give a DIFFERENT
// content a DIFFERENT generation.
//
// It is derived rather than counted so that idempotence survives it. A counter
// would bump on every run and re-upload every map for an unchanged chain,
// turning the "re-run uploads zero objects" property into "re-run uploads the
// whole index layer". A digest of the covered set changes exactly when the
// covered set changes, which is exactly when a new generation is owed.
function generationFor(keys, blockHashes) {
  if (generation.length > 0) return generation;
  const h = sha(JSON.stringify({ ranges: keys.slice().sort(), blocks: blockHashes }));
  return 'r' + h.slice(0, 12);
}

function runCapture(bin, args, cwd) {
  const r = spawnSync(bin, args, { encoding: 'utf8', cwd, maxBuffer: 64 * 1024 * 1024 });
  return { status: r.status, stdout: r.stdout ?? '', stderr: r.stderr ?? '',
           error: r.error ? String(r.error) : null };
}

function treeStats(dir) {
  let files = 0, bytes = 0;
  const walk = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else { files++; bytes += statSync(p).size; }
    }
  };
  if (existsSync(dir)) walk(dir);
  return { files, bytes };
}

// ── main ────────────────────────────────────────────────────────────────────
const started = Date.now();
const report = { chain, endpoint: url, range: [from, to], rangeKey, startedAt: new Date().toISOString() };

const nodeInfo = await rpc('node_getNodeInfo');
// Tell a throttle apart from a refusal here too, and exit 3 for it — the code
// the chunk driver retries — rather than 2, which means "this endpoint is not
// usable" and should not be retried at all.
if (isThrottle(nodeInfo)) {
  console.error(`ingest-range: the endpoint is rate-limiting this client`
    + (rpcRetryAfterMs > 0 ? `; it asked for ${Math.round(rpcRetryAfterMs / 1000)}s` : '')
    + `. Nothing was fetched and nothing was written.`);
  process.exit(3);
}
if (nodeInfo?.__err) { console.error(`ingest-range: node refused getNodeInfo: ${nodeInfo.__err}`); process.exit(2); }
const tip = await rpc('node_getBlockNumber');
const finalized = await rpc('node_getBlockNumber', ['finalized']);
if (tip?.__err || finalized?.__err) { console.error('ingest-range: node refused getBlockNumber'); process.exit(2); }
report.tipAtRun = tip;
report.finalizedAtRun = finalized;

const ledger = loadLedger();
const already = ledger.ranges[rangeKey];
if (already && !refetch) {
  say(`range ${rangeKey} already in the ledger (covered at ${already.codeVersion?.commit?.slice(0, 12) ?? '?'}); re-using its snapshot. Pass --refetch to re-read the chain.`);
  report.fetch = { reused: true, ...already.fetch };
} else {
  say(`fetching blocks ${from}..${to} from ${url}`);
  report.fetch = await fetchRange(nodeInfo, tip, finalized);
  say(`fetched: ${report.fetch.served}/${report.fetch.requested} served, ` +
      `${report.fetch.transactions} transactions, ${report.fetch.fetchMs} ms`);
  // A RANGE THINNED BY A RATE LIMIT IS NOT A COVERED RANGE. Writing it to the
  // ledger would record our own throttling as a property of the chain, and the
  // next run — finding the key present — would never ask again. Exit without
  // writing, so the range stays absent and is simply re-run.
  const lost = report.fetch.throttledOut ?? [];
  if (lost.length > 0) {
    console.error(`ingest-range: REFUSING to record ${rangeKey}: ${lost.length} of `
      + `${report.fetch.requested} heights went unanswered because the endpoint `
      + `rate-limited this run (first ${lost.slice(0, 5).join(', ')}). Nothing was `
      + `written to the ledger. Re-run the range, more slowly (--rps).`);
    process.exit(3);
  }
}
report.rpc = { calls: rpcCalls, faults: rpcFaults,
               rateLimited: rpcRateLimited, backoffMs: Math.round(rpcBackoffMs) };

// The ledger entry is written BEFORE the publish, so an interrupted run leaves a
// range recorded as fetched-not-published rather than as absent. A range the
// ledger has never heard of is re-fetched from the chain; a range it has is a
// local file away from being re-published.
const prior = already ?? {};
ledger.ranges[rangeKey] = {
  from, to,
  // WHAT THE CHAIN SAID, and it is the fetch's own report rather than a re-read
  // of the snapshot: `served` vs `requested` is the difference between a range
  // that is covered and a range that is merely attempted, and a re-read cannot
  // recover the heights the node declined.
  //
  // `reused` is stripped: it is a fact about THIS RUN — that it did not have to
  // ask the chain again — and writing it into the ledger would make the next
  // reader think the range had never been fetched from the node at all.
  fetch: (({ reused, ...rest }) => rest)(report.fetch),
  fetchedAt: (already && !refetch) ? (prior.fetchedAt ?? null) : new Date().toISOString(),
  // THE VERSION THAT COVERED IT. Re-stamped on a refetch and preserved on a
  // reuse, because that is the question a later defect asks: which ranges were
  // produced by the code that had the bug.
  codeVersion: (already && !refetch) ? (prior.codeVersion ?? codeVersion()) : codeVersion(),
  // Cleared, not carried: this run is about to ingest and publish, and a stamp
  // from the previous run would claim the new bytes are the published ones.
  ingestedAt: null,
  publishedAt: null,
  publishedTo: prior.publishedTo ?? null,
  supersedes: prior.contentDigest && prior.contentDigest !== report.fetch.contentDigest
    ? prior.contentDigest : (prior.supersedes ?? null),
  contentDigest: report.fetch.contentDigest ?? prior.contentDigest ?? null,
};
saveLedger(ledger);

// ── replay ──────────────────────────────────────────────────────────────────
//
// AFTER THE LEDGER ENTRY AND BEFORE THE MERGE. After, because a replay that is
// interrupted must leave the range recorded as fetched — the metadata is right
// whatever happens to the traces, and re-running the command resumes the replay
// without re-reading 500 heights. Before, because `mergeSnapshots` builds the
// tree from the per-range snapshots on disk and would otherwise ingest the
// placeholder rows this phase is about to replace.
if (doReplay) {
  const dir = join(RANGES, rangeKey);
  if (!existsSync(join(dir, 'snapshot.json'))) {
    console.error(`ingest-range: --replay has no snapshot for ${rangeKey} to work on`);
    process.exit(2);
  }
  say(`replaying first-in-block transactions in ${rangeKey}…`);
  report.replay = await replayRange(dir);
  if (!report.replay.ok) {
    console.error(`ingest-range: --replay refused before attempting anything:\n  `
      + report.replay.problems.join('\n  '));
    console.log(JSON.stringify(report, null, 2));
    process.exit(2);
  }
  // TWO DENOMINATORS, AND THEY ARE NOT THE SAME NUMBER. The counts describe the
  // whole first-in-block population of the range, including rows an earlier run
  // already settled; `attempted` is how many driver runs THIS pass made. Printing
  // `replayed/attempted` read as a ratio and was not one — a resumed range logged
  // "replayed 27/12 attempted", which is either nonsense or a claim that a replay
  // happened without a run.
  const r = report.replay;
  say(`${r.replayed} replayed, ${r.divergent} divergent, ${r.refused} refused, `
      + `${r.privateOnly} private-only, ${r.bodyUnavailable} body-unavailable, `
      + `${r.notAttempted} not attempted — of ${r.firstInBlock} first-in-block `
      + `(${r.attempted} driver run(s) this pass, ${Math.round(r.wallMs / 1000)}s)`);
  ledger.ranges[rangeKey].replay = {
    at: new Date().toISOString(),
    attempted: report.replay.attempted,
    replayed: report.replay.replayed,
    divergent: report.replay.divergent,
    refused: report.replay.refused,
    notAttempted: report.replay.notAttempted,
    stoppedBy: report.replay.stoppedBy,
    runtimeCommit: report.replay.runtimeCommit,
  };
  saveLedger(ledger);
  // A THROTTLE ENDS THE RUN, AND IT ENDS IT AFTER SAVING. Everything replayed so
  // far is on disk and in the ledger; publishing a half-replayed range would be
  // fine (the rows are honest) but continuing to the NEXT range would walk
  // straight back into a forty-one-minute ban and make it longer. Exit 3, which
  // is the code the chunk driver treats as "back off and retry", rather than 1.
  if (report.replay.stoppedBy === 'endpoint-throttled-this-run') {
    console.error(`ingest-range: the endpoint began rate-limiting this client during replay `
      + `(${report.replay.replayed} traced before it did`
      + (report.replay.proxy.throttledRetryAfterMs
        ? `; it asked for ${Math.round(report.replay.proxy.throttledRetryAfterMs / 1000)}s`
        : '')
      + `). Everything traced so far is saved and the rest is recorded not-attempted. `
      + `GO SILENT AND WAIT — polling this endpoint extends the ban.`);
    console.log(JSON.stringify(report, null, 2));
    process.exit(3);
  }
  // ── THE BODY SOURCE IS THE OTHER HOST, AND IT GETS THE SAME TREATMENT ─────
  //
  // Exit 3 for the same reason: the range is half-done, everything done is
  // saved, the rest says so in a repairable member, and the right next action is
  // to wait rather than to walk into the next range against the same host. It is
  // a DIFFERENT message because the host is different and so is the remedy — a
  // mirror under Pipeline-Architecture §3.7 fixes this one and nothing fixes a
  // node ban but time.
  if (report.replay.stoppedBy === 'body-store-unreachable-this-run') {
    console.error(`ingest-range: the transaction body source stopped answering during `
      + `replay (${report.replay.replayed} traced before it did; `
      + `${report.replay.bodySourceUnreachable} row(s) recorded `
      + `body-source-unreachable`
      + (report.replay.proxy.storeThrottledRetryAfterMs
        ? `; it asked for `
          + `${Math.round(report.replay.proxy.storeThrottledRetryAfterMs / 1000)}s`
        : '')
      + `). Those rows are REPAIRABLE and say nothing about the chain — re-running this `
      + `range asks again. Aztec bodies have a single source with no failover `
      + `(Chain-Data-Ingestion.md §4.8); the standing mitigation is a mirror.`);
    console.log(JSON.stringify(report, null, 2));
    process.exit(3);
  }
  // ── "THE CORPUS LIED" IS A CONTRADICTION AND NEVER A 0 ────────────────────
  //
  // `backfill-bodies.mjs` exits 1 on `counts.mismatched` because "the exit code
  // says whether the JOIN HELD, not whether the run finished". This seam reads
  // the same store through the same `classify` and used to exit 0 on it, so the
  // mirroring tool and the publishing tool gave opposite verdicts about one
  // corpus. Checked before the ingest so nothing derived from a store that
  // answered a 200 for the wrong key is published.
  if (report.replay.mismatchedBodies?.length) {
    console.error(`ingest-range: the body source answered a 200 for `
      + `${report.replay.mismatchedBodies.length} key(s) whose leading 32 bytes are a `
      + `DIFFERENT transaction hash. Tx.toBuffer() serialises txHash first, so on a `
      + `correct payload those bytes ARE the key: this is the corpus contradicting `
      + `itself, not a missing body, and it is the one failure the single-source trust `
      + `model exists to catch. Nothing is published from this run.`);
    for (const m of report.replay.mismatchedBodies.slice(0, 10)) {
      console.error(`  ${m.txHash}  block ${m.blockNumber}\n     ${m.reason}`);
    }
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
  }
}

// ── ingest ──────────────────────────────────────────────────────────────────
const covered = Object.keys(ledger.ranges);
const source = noMerge
  ? (() => {
      const s = JSON.parse(readFileSync(join(RANGES, rangeKey, 'snapshot.json'), 'utf8'));
      return { dir: join(RANGES, rangeKey), blocks: s.blocks.length,
               transactions: s.transactions.length, blockHashes: s.blocks.map((b) => b.hash) };
    })()
  : mergeSnapshots(covered);
const gen = generationFor(noMerge ? [rangeKey] : covered, source.blockHashes);
report.ingestSource = { merged: !noMerge, coveredRanges: covered.length,
                        blocks: source.blocks, transactions: source.transactions,
                        generation: gen };

// A FRESH TREE DIRECTORY EVERY RUN. `ingest.nim` adds to a registry it finds and
// refuses a second pin, and a stale `d/{chain}/g/1/` from a previous, narrower
// run would be re-published as if it were this run's output. The store is what
// accumulates; the tree is a rendering of one moment.
const treeDir = TREE;
spawnSync('rm', ['-rf', treeDir]);
mkdirSync(treeDir, { recursive: true });

say(`ingesting ${source.blocks} blocks / ${source.transactions} transactions -> ${treeDir}`);
const tIngest = Date.now();
const ing = runCapture(ingestBin, ['--snapshot', source.dir, '--out', treeDir,
                                   '--generation', gen, '--scope', 'full']);
report.ingest = { ms: Date.now() - tIngest, status: ing.status };
try { report.ingest.result = JSON.parse(ing.stdout); } catch { report.ingest.raw = ing.stdout.slice(0, 2000); }
if (ing.status !== 0) {
  report.ingest.stderr = ing.stderr.slice(0, 4000);
  console.log(JSON.stringify(report, null, 2));
  process.exit(1);
}
report.tree = treeStats(treeDir);
ledger.ranges[rangeKey].ingestedAt = new Date().toISOString();
saveLedger(ledger);

// ── publish ─────────────────────────────────────────────────────────────────
if (!noPublish) {
  // ── WHEN A CYCLE RE-VERIFIES WHAT IS ALREADY OUT THERE ────────────────────
  //
  // `--refresh` makes the publisher GET every key-existence object and rewrite
  // the ones whose bytes have moved. It is the only way a producer fix reaches a
  // store that already holds the old rendering — `d/{chain}/block/{hash}.json`
  // is keyed by the BLOCK, not by its bytes, so the corrected object has the old
  // object's key and the default cycle skips it forever.
  //
  // It costs a GET per object, so it is not the default. The trigger is the
  // question it answers: has the code that produced what is published changed
  // since it was published. The ledger already records a `codeVersion` per range
  // and a `lastPublishedCodeVersion` for the store, so the answer is a
  // comparison rather than an operator's memory.
  const nowVersion = codeVersion();
  const lastVersion = ledger.lastPublishedCodeVersion ?? null;
  const versionMoved = !lastVersion
    || lastVersion.commit !== nowVersion.commit
    || lastVersion.ingestBinDigest !== nowVersion.ingestBinDigest
    || lastVersion.dirty || nowVersion.dirty;
  const doRefresh = flag('refresh') || (versionMoved && lastVersion !== null);
  const pargs = ['--tree', treeDir, '--backend', backend, '--chain', chain];
  if (doRefresh) pargs.push('--refresh');
  report.refresh = { requested: doRefresh, reason: flag('refresh') ? 'explicit'
    : (lastVersion === null ? 'first publish into this store — nothing to supersede'
       : 'the producing code version moved since the last publish'),
    lastPublishedCodeVersion: lastVersion, thisCodeVersion: nowVersion };
  if (backend === 'local') pargs.push('--dest', dest);
  else {
    if (!bucket) { console.error('ingest-range: --backend s3 needs --bucket'); process.exit(2); }
    pargs.push('--bucket', bucket);
    if (endpoint) pargs.push('--endpoint', endpoint);
    if (prefix) pargs.push('--prefix', prefix);
  }
  say(`publishing ${report.tree.files} objects via ${backend}…`);
  const tPub = Date.now();
  const pub = runCapture(publishBin, pargs);
  report.publish = { ms: Date.now() - tPub, status: pub.status, backend,
                     dest: backend === 'local' ? dest : `${bucket}@${endpoint || 'aws'}`,
                     summary: parsePublish(pub.stdout) };
  if (pub.status !== 0) {
    report.publish.stdout = pub.stdout.slice(0, 4000);
    report.publish.stderr = pub.stderr.slice(0, 4000);
    console.log(JSON.stringify(report, null, 2));
    process.exit(1);
  }
  ledger.ranges[rangeKey].publishedAt = new Date().toISOString();
  ledger.ranges[rangeKey].publishedTo = report.publish.dest;
  // WHICH GENERATION MADE THIS RANGE VISIBLE. A range's content objects are
  // generation-independent, but "is it on the site" is answered by whether the
  // live generation's maps list it — so a ledger that recorded only "published"
  // would be recording the weaker of the two facts.
  ledger.ranges[rangeKey].visibleInGeneration = gen;
  ledger.liveGeneration = gen;
  ledger.lastPublishedCodeVersion = nowVersion;
  saveLedger(ledger);
}

// ── coverage arithmetic: the claim the ledger exists to make checkable ──────
function coverage(l) {
  const rs = Object.values(l.ranges).map((r) => [r.from, r.to]).sort((a, b) => a[0] - b[0]);
  const merged = [];
  for (const [a, b] of rs) {
    const last = merged[merged.length - 1];
    if (last && a <= last[1] + 1) last[1] = Math.max(last[1], b);
    else merged.push([a, b]);
  }
  let blocks = 0;
  for (const [a, b] of merged) blocks += b - a + 1;
  const gaps = [];
  for (let i = 1; i < merged.length; i++) gaps.push([merged[i - 1][1] + 1, merged[i][0] - 1]);
  return { ranges: rs.length, spans: merged, contiguousSpans: merged.length,
           blocksCovered: blocks, gaps,
           lowest: merged.length ? merged[0][0] : null,
           highest: merged.length ? merged[merged.length - 1][1] : null };
}
ledger.coverage = coverage(ledger);
ledger.updatedAt = new Date().toISOString();
saveLedger(ledger);
report.coverage = ledger.coverage;
report.wallMs = Date.now() - started;

function parsePublish(out) {
  const g = (re) => { const m = out.match(re); return m ? m[1].trim() : null; };
  return {
    resumedFrom: g(/resumed-from generation\s*:\s*(.+)/),
    publishedGeneration: g(/published generation\s*:\s*(.+)/),
    contentUploaded: Number(g(/content uploaded\s*:\s*(\d+)/) ?? -1),
    contentSkipped: Number(g(/content skipped\s*:\s*(\d+)/) ?? -1),
    contentRefreshed: Number(g(/content refreshed\s*:\s*(\d+)/) ?? -1),
    pointersWritten: Number(g(/pointers written\s*:\s*(\d+)/) ?? -1),
    pointerFlipped: g(/pointer flipped\s*:\s*(.+)/) === 'true',
    determinismIncidents: Number(g(/DETERMINISM INCIDENTS\s*:\s*(\d+)/) ?? 0),
  };
}

console.log(JSON.stringify(report, null, 2));
