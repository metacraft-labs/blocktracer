#!/usr/bin/env node
// backfill-bodies.mjs — transaction BODIES for a historical block range, by
// joining block enumeration to Aztec's keyless `TxFileStore`.
//
// Usage:
//   node tools/chain/backfill-bodies.mjs --from N --to M
//        [--url https://aztec.drpc.org] [--network mainnet]
//        [--config <url|path>] [--save <dir>] [--concurrency 4]
//        [--report <path>] [--prove-rejection]
//
// ── WHY THIS EXISTS, AND WHY IT IS A JOIN ───────────────────────────────────
//
// A node cannot supply an Aztec transaction body below the finalized tip. The
// archiver never stores a `Tx` — its `Body` is `TxEffect[]` — and the L1 blobs
// carry effects only, so there is no archive-node mode and no blob archive can
// substitute. `getTxByHash` serves from the active pool and the pool deletes at
// the finalized tip. `backfill-blocks.mjs` records that fact in every row it
// writes: `bodyRetained: false`, "it can no longer be re-executed".
//
// The bodies are nonetheless retrievable, from Aztec's own node-internal
// `TxFileStore`, published keyless over HTTPS as one content-addressed `.bin`
// per transaction hash. The store is keyed by hash and KNOWS NOTHING ABOUT
// BLOCKS: there is no listing endpoint, a directory GET is a 404, and none is
// needed. So backfill is a JOIN and neither half is sufficient alone —
//
//   * BLOCK ENUMERATION SUPPLIES THE KEYS. `getBlock(n, {includeTransactions:
//     true})` → `body.txEffects[].txHash`, which is archival and prunes never.
//     This is the same call `backfill-blocks.mjs` already relies on.
//   * THE STORE SUPPLIES THE BODIES, at `<base>/<basePath>/txs/<hash>.bin`.
//
// ── THE PAYLOAD SELF-VERIFIES AGAINST ITS OWN KEY ───────────────────────────
//
// `Tx.toBuffer()` serialises `txHash` first, so THE FIRST 32 BYTES OF A CORRECT
// PAYLOAD ARE THE KEY THAT WAS REQUESTED. A response whose leading 32 bytes are
// not the requested hash is a MISS, not a body, and is refused by name.
//
// This is the only reason an untrusted single source is usable here at all. The
// two-independent-sources rule is UNMET for Aztec bodies — the sibling snapshot
// host does not serve this path — and is recorded as unmet rather than quietly
// relaxed. Self-verification makes a wrong answer detectable from one source;
// detectability is not availability, and it does not close the gap.
//
// ── NOTHING HERE IS PASTED ──────────────────────────────────────────────────
//
// The store's base URL is read from `txCollectionFileStoreUrls` in
// `AztecProtocol/networks`' `network_config.json`, and the path segment beneath
// it is DERIVED FROM THE NODE'S OWN ANSWER — `aztec-<l1ChainId>-<rollupVersion>-
// <rollupAddress>` from `node_getNodeInfo`. A location that is computed from the
// deployment the hashes came from cannot silently drift onto a different one,
// which a pasted constant can and would not announce.
//
// ── FIVE OUTCOMES, AND NONE OF THEM COLLAPSE ────────────────────────────────
//
// Continuous ingestion declines transactions constantly, and an absence with no
// stated reason is indistinguishable from a broken feature. So every key ends in
// exactly one named outcome from a closed set, and the three that are NOT the
// same fact stay three different counts:
//
//   verified     200, and the leading 32 bytes are the key that was requested
//   absent       404 — the store does not hold this key
//   mismatched   200, but the leading 32 bytes are some other hash
//   truncated    200, but the payload is too short to even carry a key
//   unavailable  the store could not be asked (rate limit, 5xx, transport)
//
// `absent` and `mismatched` are the pair this design exists to tell apart: one
// says the corpus has a hole, the other says the corpus lied. Reporting them as
// a single "failed" would hide exactly the failure self-verification guards
// against. `unavailable` is separate again because it is a statement about the
// RUN, not about the corpus, and folding it into `absent` would let a rate limit
// masquerade as a missing body.
//
// ── WHAT THIS TOOL DOES NOT DO ──────────────────────────────────────────────
//
// It does not publish. The store's operator publishes no terms document at the
// conventional paths, so the ambiguity rule applies unchanged: AMBIGUOUS TERMS
// ARE TREATED AS FORBIDDEN UNTIL CLARIFIED. That gates publication of anything
// derived from these bodies; it does not gate ingesting or verifying them. This
// tool verifies, counts and — only when asked with `--save` — mirrors to a local
// directory. It writes nothing into the published corpus, and `--save` refuses a
// destination inside `client/fixtures/`, which is a publishing surface.

import { writeFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';

// ── the verifier, which is the whole point ──────────────────────────────────

export const HASH_BYTES = 32;

/** Normalise a `0x…` hash to lowercase hex with no prefix. */
export const bareHash = (h) => String(h).replace(/^0x/i, '').toLowerCase();

/**
 * Decide what a store response WAS, from the key that was asked for.
 *
 * This is the single place the leading-32-bytes rule is implemented, and both
 * the live fetch path and the selftest go through it — a verifier the tests
 * reach by a second route is not the verifier that runs.
 *
 * @param {string} txHash  the key that was requested
 * @param {number} status  HTTP status, or 0 for a transport failure
 * @param {Uint8Array|null} bytes  the response body, if there was one
 * @returns {{outcome: string, reason: string, saw?: string}}
 */
export function classify(txHash, status, bytes) {
  const want = bareHash(txHash);
  if (status === 404) {
    return {
      outcome: 'absent',
      reason: `The file store does not hold an object for this transaction hash. `
        + `It answered 404 for the key, and the negative controls show a 404 from `
        + `this store means the key is not there rather than that the request was `
        + `malformed.`,
    };
  }
  if (status !== 200) {
    return {
      outcome: 'unavailable',
      reason: status === 0
        ? `The file store could not be reached for this key, so nothing is known `
          + `about whether it holds the body. This is a fact about the run, not `
          + `about the corpus.`
        : `The file store answered HTTP ${status} for this key, which is neither a `
          + `body nor a denial that it holds one. Nothing is known about the `
          + `corpus from this response.`,
    };
  }
  if (!bytes || bytes.length < HASH_BYTES) {
    return {
      outcome: 'truncated',
      reason: `The store returned ${bytes ? bytes.length : 0} bytes with a 200. A body `
        + `serialises its own hash first, so a payload shorter than ${HASH_BYTES} bytes `
        + `cannot even carry the key it was fetched by, and is not a body.`,
    };
  }
  const saw = Buffer.from(bytes.subarray(0, HASH_BYTES)).toString('hex');
  if (saw !== want) {
    return {
      outcome: 'mismatched',
      saw: `0x${saw}`,
      reason: `The store returned a 200 whose leading ${HASH_BYTES} bytes are 0x${saw}, `
        + `not the key 0x${want} that was requested. Tx.toBuffer() serialises txHash `
        + `first, so those bytes ARE the key on a correct payload. This is a miss `
        + `wearing a success, and it is refused.`,
    };
  }
  return {
    outcome: 'verified',
    reason: `The leading ${HASH_BYTES} bytes of the payload are the key that was `
      + `requested, which is what a correct body serialises first.`,
  };
}

/** Every outcome `classify` can return. Nothing else may be counted. */
export const OUTCOMES = ['verified', 'absent', 'mismatched', 'truncated', 'unavailable'];

// ── counting transactions from the header alone ─────────────────────────────
//
// WHY THERE IS A SECOND WAY TO COUNT. Enumerating a 75k-block chain one
// `getBlock(n, {includeTransactions: true})` at a time is 75k requests against
// somebody else's free-plan endpoint. `node_getBlocks(from, limit)` serves 50
// HEADERS per request — fifty times fewer round trips — but it strips `body`,
// so it cannot hand back a single txHash. What it does carry is the state after
// the block, and Aztec inserts a FIXED-SIZE SUBTREE PER TRANSACTION: every tx
// appends exactly MAX_NOTE_HASHES_PER_TX note-hash leaves, padded, whether or
// not it produced that many notes. So
//
//     (noteHashTree.nextAvailableLeafIndex[n] - …[n-1]) / 64
//
// is the number of transactions in block n, computable from headers alone.
//
// THIS IS A DERIVATION, NOT A GUESS, AND IT IS NOT TRUSTED ON ITS OWN. Every
// block the derivation says is non-empty is then fetched WITH its body and the
// two numbers are required to agree; a sample of the blocks it says are EMPTY is
// fetched too, because a rule that is only ever checked where it predicts
// something is not checked at all. A delta that is negative or not a multiple of
// the subtree size is not silently floored — it is an `indeterminate` block, and
// the block is fetched rather than counted.
//
// The nullifier tree gives a second, independent reading of the same count
// (every tx appends 64 nullifier leaves as well), offset by the genesis prefill.

export const NOTE_HASHES_PER_TX = 64;
export const NULLIFIERS_PER_TX = 64;

/**
 * Transactions in a block, from the note-hash tree's growth across it.
 *
 * @returns {{ok: true, count: number} | {ok: false, reason: string}}
 */
export function txCountFromNoteDelta(prevIndex, index) {
  if (!Number.isInteger(prevIndex) || !Number.isInteger(index)) {
    return { ok: false, reason: 'a note-hash leaf index was missing or not an integer, '
      + 'so the block\'s transaction count cannot be derived from its header' };
  }
  const delta = index - prevIndex;
  if (delta < 0) {
    return { ok: false, reason: `the note-hash tree shrank by ${-delta} leaves across this `
      + `block. An append-only tree does not shrink, so this is not a count.` };
  }
  if (delta % NOTE_HASHES_PER_TX !== 0) {
    return { ok: false, reason: `the note-hash tree grew by ${delta} leaves, which is not a `
      + `multiple of the ${NOTE_HASHES_PER_TX}-leaf subtree each transaction appends. `
      + `Flooring this would invent a count; the block is fetched instead.` };
  }
  return { ok: true, count: delta / NOTE_HASHES_PER_TX };
}

/**
 * Transactions per window, so burstiness survives being reported.
 *
 * A mean over a chain that settles 18 transactions in 53 blocks and then none
 * for 309 is a number no window ever held. The windows are returned whole,
 * including the empty ones — dropping a zero window is what turns a bursty
 * series into a rate.
 *
 * @param {Map<number, number>} perBlock  block number -> transactions
 * @returns {Array<{from: number, to: number, blocks: number, transactions: number}>}
 */
export function bucketize(perBlock, from, to, windowSize) {
  if (!Number.isInteger(windowSize) || windowSize < 1) {
    throw new Error('window size must be a positive integer');
  }
  const out = [];
  for (let start = from; start <= to; start += windowSize) {
    const end = Math.min(start + windowSize - 1, to);
    let transactions = 0, blocks = 0;
    for (let n = start; n <= end; n++) {
      const v = perBlock.get(n);
      if (v === undefined) continue;
      blocks++;
      transactions += v;
    }
    out.push({ from: start, to: end, blocks, transactions });
  }
  return out;
}

/** Order statistics over the windows, which is what "bursty" means concretely. */
export function summarise(windows) {
  const v = windows.map((w) => w.transactions).sort((a, b) => a - b);
  if (!v.length) return null;
  const at = (q) => v[Math.min(v.length - 1, Math.floor(q * v.length))];
  const total = v.reduce((a, b) => a + b, 0);
  return {
    windows: v.length,
    total,
    mean: Number((total / v.length).toFixed(2)),
    min: v[0], p10: at(0.10), p25: at(0.25), median: at(0.50),
    p75: at(0.75), p90: at(0.90), p99: at(0.99), max: v[v.length - 1],
    emptyWindows: v.filter((x) => x === 0).length,
  };
}

// ── the store location, derived rather than pasted ──────────────────────────

/** `aztec-<l1ChainId>-<rollupVersion>-<rollupAddress>`, from the node's own answer. */
export function storeBasePath(info) {
  const chain = info?.l1ChainId;
  const version = info?.rollupVersion;
  const rollup = info?.l1ContractAddresses?.rollupAddress;
  if (chain == null || version == null || !rollup) {
    throw new Error(
      'node_getNodeInfo did not supply l1ChainId, rollupVersion and rollupAddress; '
      + 'the store path is derived from the deployment the hashes came from and '
      + 'cannot be guessed');
  }
  return `aztec-${chain}-${version}-${String(rollup).toLowerCase()}`;
}

export const bodyUrl = (base, basePath, txHash) =>
  `${base.replace(/\/+$/, '')}/${basePath}/txs/0x${bareHash(txHash)}.bin`;

// ── everything below is the driver ──────────────────────────────────────────

if (import.meta.url === `file://${process.argv[1]}`) await main();

async function main() {
const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : dflt;
};
const flag = (name) => argv.includes(`--${name}`);

const from = Number(arg('from', 0));
const to = Number(arg('to', 0));
const endpoint = arg('url', 'https://aztec.drpc.org');
const network = arg('network', 'mainnet');
const configRef = arg('config',
  'https://raw.githubusercontent.com/AztecProtocol/networks/main/network_config.json');
const saveDir = arg('save', '');
const reportPath = arg('report', '');
const concurrency = Math.max(1, Number(arg('concurrency', 4)));
const maxBodies = Number(arg('max-bodies', 0));   // 0 = no cap
const sampleBodies = Number(arg('sample-bodies', 0)); // 0 = no sampling
const proveRejection = flag('prove-rejection');
const quiet = flag('quiet');
// Enumeration answers "how many transactions are there"; the join answers "can
// their bodies be had". They are separate questions and a chain-wide count does
// not need — and must not incur — a chain-wide body download.
const enumerateOnly = flag('enumerate-only');
const bulkHeaders = flag('bulk-headers');
const windowSize = Math.max(1, Number(arg('window', 1000)));
const zeroSample = Number(arg('zero-sample', 200));

if (!from || !to || to < from) {
  console.error('usage: --from N --to M [--url U] [--network mainnet] [--config U] '
              + '[--save DIR] [--report PATH] [--concurrency N] [--max-bodies N] '
              + '[--sample-bodies N] [--prove-rejection]\n'
              + '       [--enumerate-only] [--bulk-headers] [--window 1000] '
              + '[--zero-sample N]');
  process.exit(2);
}

// A save destination inside the published fixtures would make mirroring a
// publishing act, and the terms are unclarified. Refused rather than warned.
if (saveDir) {
  const abs = resolve(saveDir);
  if (abs.includes(`${sep}client${sep}fixtures${sep}`) || abs.endsWith(`${sep}client${sep}fixtures`)) {
    console.error(`refusing: --save ${saveDir} is inside client/fixtures/, which is a\n`
      + '  publishing surface. The file store publishes no terms, so anything derived\n'
      + '  from it is treated as forbidden to publish until that is clarified. Mirror\n'
      + '  somewhere that is not the published corpus.');
    process.exit(1);
  }
  mkdirSync(abs, { recursive: true });
}

const log = (...a) => { if (!quiet) console.error(...a); };

// ── 1. the store's base URL, from the published network config ──────────────

async function readConfig(ref) {
  if (/^https?:/.test(ref)) {
    const res = await fetch(ref);
    if (!res.ok) throw new Error(`network_config.json: HTTP ${res.status} from ${ref}`);
    return await res.json();
  }
  return JSON.parse(readFileSync(ref, 'utf8'));
}

// An enumeration-only pass never speaks to the store, so an unreachable network
// config must not stop it. It is still READ when it can be, because the report
// says where bodies would come from and a null there is a fact worth carrying.
let config = null, configError = null;
try {
  config = await readConfig(configRef);
} catch (e) {
  if (!enumerateOnly) throw e;
  configError = e.message;
}
const bases = config?.[network]?.txCollectionFileStoreUrls;
if (!enumerateOnly && (!Array.isArray(bases) || bases.length === 0)) {
  console.error(`refusing: ${configRef} declares no txCollectionFileStoreUrls for `
              + `network "${network}". The location is a configuration fact and this `
              + `tool will not invent one.`);
  process.exit(1);
}
const storeBase = Array.isArray(bases) && bases.length ? bases[0] : null;
// §5's two-source rule, recorded as unmet rather than quietly relaxed.
const redundancy = !Array.isArray(bases) || bases.length === 0
  ? { met: false, sources: 0,
      note: `The network config could not be read (${configError ?? 'no '
        + 'txCollectionFileStoreUrls declared'}), so no body source is known. This run `
        + 'enumerated only and never needed one.' }
  : bases.length >= 2
  ? { met: true, sources: bases.length }
  : { met: false, sources: bases.length,
      note: 'Single source, no failover: the published config declares one '
          + 'txCollectionFileStoreUrl for this network, so the two-independent-sources '
          + 'rule is UNMET for Aztec transaction bodies. What partially compensates is '
          + 'that payloads self-verify against their own keys, so a wrong answer is '
          + 'detectable from one source — but detectability is not availability.' };

// ── 2. the node, and the store path derived from it ─────────────────────────

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A long enumeration is a guest on somebody else's endpoint. A 429 or a 5xx is
// the host asking for room, and the only correct answer is to take less of it —
// so retries back off with jitter, and a run of them that does not clear is
// treated as a REASON TO STOP rather than a transient to grind through. Stopping
// with a stated boundary is a good outcome; a completed pass that annoyed the
// provider into blocking us is not.
const STOP_AFTER_CONSECUTIVE_UNAVAILABLE = 12;
let consecutiveUnavailable = 0;
let stopReason = null;
class Halted extends Error {}
function noteUnavailable(what) {
  if (++consecutiveUnavailable >= STOP_AFTER_CONSECUTIVE_UNAVAILABLE) {
    stopReason ??= `${consecutiveUnavailable} consecutive unavailable responses `
      + `(last: ${what}). Sustained 5xx/429 is the endpoint asking us to stop, not a `
      + `transient to retry through, so the pass was halted at its current boundary.`;
    throw new Halted(stopReason);
  }
}

let rpcId = 0, rpcCalls = 0, rpcRetries = 0;
async function rpc(method, params) {
  for (let attempt = 0; ; attempt++) {
    rpcCalls++;
    let res;
    try {
      res = await fetch(endpoint, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: ++rpcId, method, params }),
      });
    } catch (e) {
      if (attempt >= 4) { noteUnavailable(`${method}: ${e.message}`); throw new Error(`${method}: ${e.message}`); }
      rpcRetries++;
      await sleep(500 * 2 ** attempt + Math.random() * 400);
      continue;
    }
    if (res.status === 429 || res.status >= 500) {
      if (attempt >= 4) { noteUnavailable(`${method}: HTTP ${res.status}`); throw new Error(`${method}: HTTP ${res.status}`); }
      rpcRetries++;
      const ra = Number(res.headers.get('retry-after'));
      await sleep((Number.isFinite(ra) && ra > 0 ? ra * 1000 : 750 * 2 ** attempt)
                  + Math.random() * 400);
      continue;
    }
    if (!res.ok) throw new Error(`${method}: HTTP ${res.status}`);
    const body = await res.json();
    if (body.error) throw new Error(`${method}: ${body.error.message ?? 'rpc error'}`);
    consecutiveUnavailable = 0;
    return body.result;
  }
}

/** Run `worker` over `items` with a bounded number in flight. */
async function pool(items, width, worker) {
  const queue = items.slice();
  await Promise.all(Array.from({ length: Math.min(width, queue.length) }, async () => {
    for (let it = queue.shift(); it !== undefined; it = queue.shift()) await worker(it);
  }));
}

const info = await rpc('node_getNodeInfo', []);
const basePath = storeBasePath(info);
log(`node       ${endpoint} (${info.nodeVersion ?? '?'})`);
log(`store      ${storeBase ? `${storeBase}/${basePath}/txs/` : '(not resolved; enumeration only)'}`);
log(`           base URL from ${network}.txCollectionFileStoreUrls; path segment derived`);
log(`           from node_getNodeInfo (l1ChainId ${info.l1ChainId}, rollupVersion `
  + `${info.rollupVersion}, rollup ${info.l1ContractAddresses?.rollupAddress})`);

// ── 3. enumeration: the keys, and the count §4.8.1 records as unsettled ─────

log(`\nenumerating blocks ${from}..${to} (${bulkHeaders ? 'bulk headers' : 'per block'})…`);
const keys = [];            // {txHash, blockNumber, index}
const perBlock = new Map(); // block number -> transactions, for the distribution
let blocksSeen = 0, blocksMissing = 0, blocksWithTxs = 0;
let reachedBlock = from - 1;   // the honest boundary if the pass stops early
const anomalies = [];          // every place the two ways of counting disagreed

/** Pull one block WITH its body and record its hashes. Returns the count. */
async function readBodyBlock(n) {
  const full = await rpc('node_getBlock', [n, { includeTransactions: true }]);
  if (!full) return null;
  const effects = full?.body?.txEffects ?? [];
  for (const [i, eff] of effects.entries()) {
    keys.push({ txHash: eff.txHash, blockNumber: n, index: i });
  }
  return effects.length;
}

const enumeration = { strategy: bulkHeaders ? 'bulk-headers+bodies' : 'per-block' };

try {
if (!bulkHeaders) {
  // The original path: one header per block, and a body only where the mana says
  // there is something to fetch. Correct, and 75k round trips on a 75k chain.
  for (let n = from; n <= to; n++) {
    let head;
    try {
      head = await rpc('node_getBlock', [n]);
    } catch (e) {
      if (e instanceof Halted) throw e;
      console.error(`  block ${n}: ${e.message}`);
      blocksMissing++;
      reachedBlock = n;
      continue;
    }
    reachedBlock = n;
    if (!head) { blocksMissing++; continue; }
    blocksSeen++;
    const mana = String(head.header?.totalManaUsed ?? '0x0');
    // A block that burned no mana settled no transaction; asking for its bodies
    // is a round trip that cannot return one.
    if (/^0x0*$/.test(mana) || mana === '0') { perBlock.set(n, 0); continue; }
    const count = await readBodyBlock(n) ?? 0;
    perBlock.set(n, count);
    if (count) blocksWithTxs++;
    if (!quiet && count) log(`  block ${n}: ${count} tx`);
  }
} else {
  // ── phase A: every header in the range, 50 to a request ───────────────────
  //
  // The delta needs the PREDECESSOR of `from`, so the scan starts one block
  // early. At the very first block there is no predecessor and the note-hash
  // tree is empty by construction, so the baseline is 0.
  const scanFrom = Math.max(1, from - 1);
  const CHUNK = 50;
  const chunks = [];
  for (let s = scanFrom; s <= to; s += CHUNK) chunks.push(s);
  const headers = new Map();  // block number -> {note, nullifier, mana}
  let chunksDone = 0;
  await pool(chunks, concurrency, async (s) => {
    const limit = Math.min(CHUNK, to - s + 1);
    let batch;
    try {
      batch = await rpc('node_getBlocks', [s, limit]);
    } catch (e) {
      if (e instanceof Halted) throw e;
      console.error(`  headers ${s}..${s + limit - 1}: ${e.message}`);
      return;
    }
    for (const b of batch ?? []) {
      const p = b?.header?.state?.partial;
      headers.set(b.number, {
        note: p?.noteHashTree?.nextAvailableLeafIndex,
        nullifier: p?.nullifierTree?.nextAvailableLeafIndex,
        mana: String(b?.header?.totalManaUsed ?? '0x0'),
      });
    }
    if (!quiet && ++chunksDone % 50 === 0) {
      log(`  headers … ${chunksDone}/${chunks.length} chunks, ${headers.size} blocks`);
    }
  });
  log(`  headers: ${headers.size} of ${to - scanFrom + 1} blocks served`);

  // ── phase B: derive a per-block count, and name what cannot be derived ────
  const candidates = [];      // blocks the headers say are non-empty
  const indeterminate = [];   // blocks the headers cannot speak for
  for (let n = from; n <= to; n++) {
    const h = headers.get(n);
    if (!h) { blocksMissing++; reachedBlock = Math.max(reachedBlock, n - 1); continue; }
    blocksSeen++;
    const prev = n === 1 ? { note: 0 } : headers.get(n - 1);
    if (!prev) { indeterminate.push({ n, why: 'predecessor header not served' }); continue; }
    const d = txCountFromNoteDelta(prev.note, h.note);
    if (!d.ok) { indeterminate.push({ n, why: d.reason }); continue; }
    if (d.count > 0) candidates.push(n); else perBlock.set(n, 0);
  }
  log(`  derived: ${candidates.length} blocks with transactions, `
    + `${indeterminate.length} indeterminate`);

  // ── phase C: the hashes, from the blocks the headers point at ─────────────
  //
  // The derivation supplies WHERE to look; the body supplies WHAT is there, and
  // the two must agree. A block whose body contradicts its header is an anomaly
  // and the BODY wins — it is the thing that actually carries the hashes.
  const toFetch = [...candidates, ...indeterminate.map((x) => x.n)]
    .sort((a, b) => a - b);
  let fetched = 0;
  await pool(toFetch, concurrency, async (n) => {
    let count;
    try {
      count = await readBodyBlock(n);
    } catch (e) {
      if (e instanceof Halted) throw e;
      console.error(`  block ${n}: ${e.message}`);
      anomalies.push({ block: n, kind: 'body-unreadable', detail: e.message });
      return;
    }
    if (count === null) { anomalies.push({ block: n, kind: 'body-not-served' }); return; }
    perBlock.set(n, count);
    if (count) blocksWithTxs++;
    const h = headers.get(n), prev = n === 1 ? { note: 0 } : headers.get(n - 1);
    const d = prev ? txCountFromNoteDelta(prev.note, h.note) : { ok: false };
    if (d.ok && d.count !== count) {
      anomalies.push({ block: n, kind: 'header-body-disagree',
        derivedFromNoteHashTree: d.count, txEffects: count });
    }
    if (!quiet && ++fetched % 200 === 0) log(`  bodies … ${fetched}/${toFetch.length}`);
  });
  reachedBlock = to;

  // ── phase D: the control the derivation does not get to skip ──────────────
  //
  // Phase C only ever looks where the rule PREDICTS something. A rule checked
  // only where it fires is not checked, so a random sample of the blocks it
  // calls empty is opened and required to be empty. Without this arm, a
  // derivation that silently under-counted would look perfect.
  const zeros = [];
  for (const [n, c] of perBlock) if (c === 0) zeros.push(n);
  const wanted = Math.min(zeroSample, zeros.length);
  const picked = [];
  {   // deterministic spread, so the control covers the chain rather than a corner
    const stride = zeros.length / (wanted || 1);
    for (let i = 0; i < wanted; i++) picked.push(zeros[Math.floor(i * stride)]);
  }
  let zeroViolations = 0;
  await pool(picked, concurrency, async (n) => {
    let count;
    try { count = await readBodyBlock(n); } catch (e) {
      if (e instanceof Halted) throw e;
      return;
    }
    if (count) {
      zeroViolations++;
      anomalies.push({ block: n, kind: 'derived-empty-but-body-has-transactions',
        txEffects: count });
      perBlock.set(n, count);
      blocksWithTxs++;
    }
  });
  log(`  control: ${picked.length} blocks the headers called empty were opened, `
    + `${zeroViolations} were not`);

  enumeration.headerDerivation = {
    rule: `transactions in block n = (noteHashTree.nextAvailableLeafIndex[n] − [n−1]) `
        + `/ ${NOTE_HASHES_PER_TX}, because each transaction appends a fixed padded `
        + `subtree of that size`,
    headersServed: headers.size,
    blocksDerivedNonEmpty: candidates.length,
    blocksIndeterminate: indeterminate.length,
    indeterminateExamples: indeterminate.slice(0, 10),
    emptyBlocksSampled: picked.length,
    emptyBlocksThatWereNotEmpty: zeroViolations,
    disagreements: anomalies.filter((a) => a.kind === 'header-body-disagree').length,
    // The second, independent reading of the same total. Every transaction
    // appends 64 nullifier leaves too, above whatever genesis prefilled.
    nullifierCrossCheck: (() => {
      const first = headers.get(from) ?? headers.get(scanFrom);
      const last = headers.get(to) ?? [...headers.values()].pop();
      if (!first || !last) return null;
      const baseline = headers.get(1)?.nullifier ?? null;
      return {
        genesisNullifierLeaves: baseline,
        tipNullifierLeaves: last.nullifier,
        tipNoteHashLeaves: last.note,
        txFromNoteHashTree: Number.isInteger(last.note)
          ? last.note / NOTE_HASHES_PER_TX : null,
        txFromNullifierTree: Number.isInteger(last.nullifier) && Number.isInteger(baseline)
          ? (last.nullifier - baseline) / NULLIFIERS_PER_TX : null,
      };
    })(),
  };
}
} catch (e) {
  if (!(e instanceof Halted)) throw e;
  console.error(`\nHALTED: ${e.message}`);
}

// The bulk path fetches bodies concurrently, so hashes arrive in whatever order
// the pool finished them. Chain order is restored here because everything
// downstream reads this array positionally — an evenly spread sample is only
// evenly spread over the CHAIN if the array is in chain order, and a report that
// reordered itself run to run would be a diff nobody could review.
keys.sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);

const enumerated = [...perBlock.values()].reduce((a, b) => a + b, 0);
log(`\nenumeration: ${blocksSeen} blocks served, ${blocksMissing} not served, `
  + `${blocksWithTxs} with transactions, ${keys.length} transaction hashes`);

// ── 3b. the distribution, because a mean is not what any window held ────────

const windows = bucketize(perBlock, from, to, windowSize);
const distributionSummary = summarise(windows);
if (distributionSummary) {
  const s = distributionSummary;
  log(`\ntransactions per ${windowSize} blocks over ${s.windows} windows:`);
  log(`  min ${s.min}  p10 ${s.p10}  p25 ${s.p25}  median ${s.median}  p75 ${s.p75}`
    + `  p90 ${s.p90}  p99 ${s.p99}  max ${s.max}`);
  log(`  mean ${s.mean} — and ${s.emptyWindows} of ${s.windows} windows held NONE, `
    + `which is why the mean describes no window in particular`);
}

let fetchKeys = keys;
if (enumerateOnly) {
  fetchKeys = [];
  log(`\nenumeration only (--enumerate-only): no bodies fetched. The count above is `
    + `the answer; the bodies are a separate question and a separate ~GB.`);
} else if (sampleBodies > 0 && keys.length > sampleBodies) {
  // A mean body size taken from the FIRST N hashes is a mean of one region of
  // one day. Spread the sample across the whole enumeration instead, so the
  // figure the corpus estimate multiplies by is a figure about the whole chain.
  const stride = keys.length / sampleBodies;
  fetchKeys = Array.from({ length: sampleBodies }, (_, i) => keys[Math.floor(i * stride)]);
  log(`sampling ${sampleBodies} of ${keys.length} hashes, evenly spread (--sample-bodies). `
    + `The enumeration count above is over the FULL range.`);
} else if (maxBodies > 0 && keys.length > maxBodies) {
  fetchKeys = keys.slice(0, maxBodies);
  log(`bounded: fetching the first ${maxBodies} of ${keys.length} hashes `
    + `(--max-bodies). The enumeration count above is over the FULL range.`);
}

// ── 4. negative controls, run as checks rather than written as prose ────────

async function raw(url) {
  for (let attempt = 0; ; attempt++) {
    let res;
    try {
      res = await fetch(url);
    } catch (e) {
      if (attempt >= 3) return { status: 0, bytes: null, error: e.message };
      await sleep(250 * 2 ** attempt + Math.random() * 250);
      continue;
    }
    // Respect published limits and Retry-After, with jitter.
    if ((res.status === 429 || res.status >= 500) && attempt < 3) {
      const ra = Number(res.headers.get('retry-after'));
      const wait = Number.isFinite(ra) && ra > 0
        ? ra * 1000
        : 500 * 2 ** attempt;
      await sleep(wait + Math.random() * 250);
      continue;
    }
    if (res.status !== 200) return { status: res.status, bytes: null };
    return { status: 200, bytes: new Uint8Array(await res.arrayBuffer()) };
  }
}

const controls = [];
// Controls interrogate the STORE. An enumeration-only pass never asks the store
// anything, so running them would be traffic in service of a question this run
// is not answering — and a control on a connection nothing depends on proves
// nothing anyway.
if (!enumerateOnly) {
  // A fabricated hash under the CORRECT prefix must 404 — otherwise a 200 does
  // not mean the store holds the key, it means the store answers anything.
  const bogus = 'de'.repeat(32);
  const r = await raw(bodyUrl(storeBase, basePath, bogus));
  controls.push({
    name: 'fabricated hash under the correct prefix 404s',
    url: bodyUrl(storeBase, basePath, bogus),
    status: r.status, pass: r.status === 404,
  });
}
if (!enumerateOnly && fetchKeys.length) {
  // A REAL hash under a WRONG prefix must 404 — otherwise the prefix is not
  // load-bearing and a success says nothing about which deployment answered.
  const wrong = `${basePath.slice(0, -1)}0`;
  const r = await raw(bodyUrl(storeBase, wrong, fetchKeys[0].txHash));
  controls.push({
    name: 'a real hash under a wrong base path 404s',
    url: bodyUrl(storeBase, wrong, fetchKeys[0].txHash),
    status: r.status, pass: r.status === 404,
  });
}
log('');
for (const c of controls) log(`control    ${c.pass ? 'ok  ' : 'FAIL'} ${c.name} (HTTP ${c.status})`);

// ── 5. the join: fetch each key, verify each payload against that key ───────

const counts = Object.fromEntries(OUTCOMES.map((o) => [o, 0]));
const refusals = [];        // every key that did not end `verified`, by name
let bytesFetched = 0, bytesSaved = 0, bytesVerified = 0;
// Every accepted body's size, kept rather than folded straight into a mean. A
// corpus estimate is count × mean, and a mean is the right multiplier — but a
// mean quoted with no spread cannot be told apart from a mean of a distribution
// that has one, and this one is read off a SAMPLE. The sizes are what let a
// reader see how much the estimate is allowed to move.
const verifiedSizes = [];
let done = 0;

async function handle(key) {
  const url = bodyUrl(storeBase, basePath, key.txHash);
  const r = await raw(url);
  if (r.bytes) bytesFetched += r.bytes.length;
  const verdict = classify(key.txHash, r.status, r.bytes);
  counts[verdict.outcome]++;
  if (verdict.outcome !== 'verified') {
    refusals.push({ ...key, url, httpStatus: r.status, ...verdict });
  } else {
    // Only verified bytes count toward the mean body size — averaging in a
    // payload that was refused would describe a corpus that was not accepted.
    bytesVerified += r.bytes.length;
    verifiedSizes.push(r.bytes.length);
    if (saveDir) {
      // Mirrored only on request, and only after it verified. An unverified
      // payload is not a body and does not get written anywhere.
      writeFileSync(join(resolve(saveDir), `0x${bareHash(key.txHash)}.bin`), r.bytes);
      bytesSaved += r.bytes.length;
    }
  }
  done++;
  if (!quiet && done % 10 === 0) log(`  … ${done}/${fetchKeys.length}`);
}

if (fetchKeys.length) log(`\nfetching ${fetchKeys.length} bodies (concurrency ${concurrency})…`);
await pool(fetchKeys, concurrency, handle);

// ── 6. proof that the verifier refuses ──────────────────────────────────────
//
// A verifier never observed refusing is not known to verify. This takes a body
// this run actually accepted, corrupts one byte INSIDE the key it verifies, and
// puts it back through the SAME `classify` that accepted it. The control arm is
// the intact payload; the mutation arm must be refused.

let rejectionProof = null;
if (proveRejection) {
  const good = fetchKeys.find((k) =>
    !refusals.some((r) => r.txHash === k.txHash));
  if (!good) {
    rejectionProof = { ran: false, why: 'no verified body in this range to corrupt' };
  } else {
    const r = await raw(bodyUrl(storeBase, basePath, good.txHash));
    const intact = classify(good.txHash, r.status, r.bytes);
    const corrupted = new Uint8Array(r.bytes);
    corrupted[7] ^= 0xff;                      // one byte, inside the key
    const flipped = classify(good.txHash, 200, corrupted);
    const short = classify(good.txHash, 200, r.bytes.subarray(0, 31));
    rejectionProof = {
      ran: true,
      txHash: good.txHash,
      control_intact: intact.outcome,
      mutation_one_byte_flipped_in_key: flipped.outcome,
      mutation_saw: flipped.saw,
      mutation_truncated_to_31_bytes: short.outcome,
      pass: intact.outcome === 'verified'
         && flipped.outcome === 'mismatched'
         && short.outcome === 'truncated',
    };
    log('\nrejection proof');
    log(`  control  intact payload for ${good.txHash.slice(0, 18)}… → ${intact.outcome}`);
    log(`  mutation one byte flipped inside the key → ${flipped.outcome} (saw ${flipped.saw?.slice(0, 18)}…)`);
    log(`  mutation payload truncated to 31 bytes → ${short.outcome}`);
    log(`  ${rejectionProof.pass ? 'PASS' : 'FAIL'} — the same classify() that accepted `
      + `the intact body refused both mutations`);
  }
}

// ── 7. the report ───────────────────────────────────────────────────────────

const report = {
  format: 'blocktracer/backfill-bodies-report@1',
  ranAt: new Date().toISOString(),
  network,
  node: { endpoint, version: info.nodeVersion ?? null,
          l1ChainId: info.l1ChainId, rollupVersion: info.rollupVersion,
          rollupAddress: info.l1ContractAddresses?.rollupAddress ?? null },
  store: { configSource: configRef, base: storeBase, basePath,
           example: storeBase ? bodyUrl(storeBase, basePath, '00'.repeat(32)) : null },
  range: { from, to,
           blocksServed: blocksSeen, blocksNotServed: blocksMissing,
           blocksWithTransactions: blocksWithTxs,
           transactionsEnumerated: keys.length,
           bodiesAttempted: fetchKeys.length },
  // A pass that stopped early says where it stopped and why. A partial answer
  // with a stated boundary is usable; a partial answer wearing a total's clothes
  // is worse than none.
  completion: {
    complete: stopReason === null,
    reachedBlock,
    stopReason,
    rpcCalls, rpcRetries,
  },
  enumeration: {
    ...enumeration,
    enumerateOnly,
    // The distribution is the point. `transactionsEnumerated` is one number and
    // this chain does not have one rate — a window series is what a backfill
    // plan can actually be sized against.
    transactionsFromPerBlockCounts: enumerated,
    windowSize,
    distribution: distributionSummary,
    windows,
    anomalies,
  },
  counts,
  controls,
  rejectionProof,
  redundancy,
  publication: {
    permitted: false,
    reason: 'The file store\'s operator publishes no terms document and no ToS at the '
          + 'conventional paths. Ambiguous terms are treated as forbidden until '
          + 'clarified, which gates PUBLICATION of anything derived from these bodies '
          + 'and does not gate ingesting, mirroring or verifying them.',
  },
  bytes: { fetched: bytesFetched, verified: bytesVerified, saved: bytesSaved,
           meanVerifiedBodySize: counts.verified ? Math.round(bytesVerified / counts.verified) : null,
           // The whole point of keeping these: a corpus estimate is count ×
           // mean, and the mean here comes from a sample. `sampledOf` says what
           // it is a sample OF, so nobody reads the product as a measurement of
           // the corpus rather than an estimate of it.
           verifiedSizeSpread: summarise(verifiedSizes.map((transactions) => ({ transactions }))),
           sampledOf: keys.length },
  refusals,
};

log('\n── counts ' + '─'.repeat(60));
for (const o of OUTCOMES) log(`  ${o.padEnd(12)} ${counts[o]}`);
log(`  ${'—'.repeat(12)}`);
log(`  ${'enumerated'.padEnd(12)} ${keys.length}   (transactions in blocks ${from}..${to})`);
if (anomalies.length) log(`  ${'anomalies'.padEnd(12)} ${anomalies.length}   `
  + `(the header arithmetic and the block body disagreed, or a block could not be read)`);
log(`  fetched ${(bytesFetched / 1048576).toFixed(1)} MiB` + (saveDir ? `, saved ${(bytesSaved / 1048576).toFixed(1)} MiB to ${saveDir}` : ', saved nothing (no --save)'));

if (refusals.length) {
  log('\n── refusals, by name ' + '─'.repeat(49));
  for (const r of refusals.slice(0, 40)) {
    log(`  ${r.outcome.toUpperCase()}  ${r.txHash}  block ${r.blockNumber}:${r.index}`);
    log(`     ${r.reason}`);
  }
  if (refusals.length > 40) log(`  … and ${refusals.length - 40} more, in the report`);
}

if (reportPath) {
  writeFileSync(reportPath, JSON.stringify(report, null, 1) + '\n');
  log(`\nreport → ${reportPath}`);
}
if (quiet) console.log(JSON.stringify(report, null, 1));

// The exit code says whether the JOIN HELD, not whether the run finished. A
// mismatch or a truncation is the corpus contradicting itself and is never a 0.
// An enumeration anomaly is the same kind of fact one layer down: the header
// arithmetic and the block body gave different answers about the same block.
const controlsFailed = controls.some((c) => !c.pass);
const proofFailed = rejectionProof && rejectionProof.ran && !rejectionProof.pass;
const enumerationContradicted = anomalies.some((a) =>
  a.kind === 'header-body-disagree' || a.kind === 'derived-empty-but-body-has-transactions');
if (counts.mismatched || counts.truncated || controlsFailed || proofFailed
    || enumerationContradicted) process.exit(1);
// A halt is not a contradiction — it is a boundary, and it gets its own code so
// a caller can tell "the chain disagreed with itself" from "we stopped asking".
if (stopReason) process.exit(2);
process.exit(0);
}
