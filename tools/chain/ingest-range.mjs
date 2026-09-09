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

import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync, readdirSync, statSync }
  from 'node:fs';
import { join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

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
const from = Number(arg('from', 0));
const to = Number(arg('to', 0));
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
const noPublish = flag('no-publish');
const noMerge = flag('no-merge');
const refetch = flag('refetch');
const jsonOnly = flag('json');

if (!from || !to || to < from) {
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

  for (let n = from; n <= to; n++) {
    requested++;
    const head = await rpc('node_getBlock', [n]);
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
        // Every transaction is recorded traceless with the producer's own
        // sentence about why. This tool NEVER replays: a historic range is by
        // definition below the finalized tip, its bodies are pruned, and a range
        // command that tried would be manufacturing a refusal per transaction
        // rather than reading the archive. `follow-chain.mjs` is the tool that
        // catches a body while it is still there.
        const why = i !== 0
          ? { outcome: 'not-first-in-block',
              reason: `Replaying this transaction needs the state left by the `
                + `transaction before it in block ${n}, and the node does not serve `
                + `intra-block intermediate state. Only the first transaction in a `
                + `block can be re-executed from published data.` }
          : { outcome: 'pruned',
              reason: `The node still serves this transaction's effects but no longer `
                + `serves its body: getTxByHash prunes at the finalized tip and `
                + `getTxEffect does not. This range was ingested from the archive, `
                + `below the replayable window, so it can no longer be re-executed `
                + `and no trace was recorded for it.` };
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
    format: 'blocktracer/chain-snapshot@1',
    provenance: {
      kind: 'live-capture',
      chain, label, endpoint: url,
      capturedAt: new Date().toISOString(),
      firstCapturedAt: new Date().toISOString(),
      nodeVersion: nodeInfo.nodeVersion,
      l1ChainId: nodeInfo.l1ChainId,
      rollupVersion: nodeInfo.rollupVersion,
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
    contentDigest: sha(JSON.stringify({ blocks, transactions })),
  };
}

function outcomeCounts(txs) {
  const o = {};
  for (const t of txs) o[t.outcome ?? 'unknown'] = (o[t.outcome ?? 'unknown'] ?? 0) + 1;
  return o;
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
  s.counts.tracesPublished = s.counts.replayed + s.counts.divergent;
  s.counts.captureSessions = (s.captures ?? []).length;
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
    format: 'blocktracer/chain-snapshot@1',
    provenance: { ...provenance, tool: 'tools/chain/ingest-range.mjs (merged)',
                  range: undefined, mergedRanges: keys.slice().sort() },
    captures, window, counts: {}, blocks, transactions,
  };
  recount(merged);
  const dir = join(stateDir, 'merged');
  mkdirSync(join(dir, 'ct'), { recursive: true });
  writeFileSync(join(dir, 'snapshot.json'), JSON.stringify(merged, null, 1) + '\n');
  return { dir, blocks: blocks.length, transactions: transactions.length,
           blockHashes: blocks.map((b) => b.hash) };
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
