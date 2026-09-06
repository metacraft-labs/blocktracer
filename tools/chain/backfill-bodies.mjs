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
const proveRejection = flag('prove-rejection');
const quiet = flag('quiet');

if (!from || !to || to < from) {
  console.error('usage: --from N --to M [--url U] [--network mainnet] [--config U] '
              + '[--save DIR] [--report PATH] [--concurrency N] [--max-bodies N] '
              + '[--prove-rejection]');
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

const config = await readConfig(configRef);
const bases = config?.[network]?.txCollectionFileStoreUrls;
if (!Array.isArray(bases) || bases.length === 0) {
  console.error(`refusing: ${configRef} declares no txCollectionFileStoreUrls for `
              + `network "${network}". The location is a configuration fact and this `
              + `tool will not invent one.`);
  process.exit(1);
}
const storeBase = bases[0];
// §5's two-source rule, recorded as unmet rather than quietly relaxed.
const redundancy = bases.length >= 2
  ? { met: true, sources: bases.length }
  : { met: false, sources: bases.length,
      note: 'Single source, no failover: the published config declares one '
          + 'txCollectionFileStoreUrl for this network, so the two-independent-sources '
          + 'rule is UNMET for Aztec transaction bodies. What partially compensates is '
          + 'that payloads self-verify against their own keys, so a wrong answer is '
          + 'detectable from one source — but detectability is not availability.' };

// ── 2. the node, and the store path derived from it ─────────────────────────

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

const info = await rpc('node_getNodeInfo', []);
const basePath = storeBasePath(info);
log(`node       ${endpoint} (${info.nodeVersion ?? '?'})`);
log(`store      ${storeBase}/${basePath}/txs/`);
log(`           base URL from ${network}.txCollectionFileStoreUrls; path segment derived`);
log(`           from node_getNodeInfo (l1ChainId ${info.l1ChainId}, rollupVersion `
  + `${info.rollupVersion}, rollup ${info.l1ContractAddresses?.rollupAddress})`);

// ── 3. enumeration: the keys, and the count §4.8.1 records as unsettled ─────

log(`\nenumerating blocks ${from}..${to} …`);
const keys = [];            // {txHash, blockNumber, index}
let blocksSeen = 0, blocksMissing = 0, blocksWithTxs = 0;

for (let n = from; n <= to; n++) {
  let head;
  try {
    head = await rpc('node_getBlock', [n]);
  } catch (e) {
    console.error(`  block ${n}: ${e.message}`);
    blocksMissing++;
    continue;
  }
  if (!head) { blocksMissing++; continue; }
  blocksSeen++;
  const mana = String(head.header?.totalManaUsed ?? '0x0');
  // A block that burned no mana settled no transaction; asking for its bodies
  // is a round trip that cannot return one.
  if (/^0x0*$/.test(mana) || mana === '0') continue;
  const full = await rpc('node_getBlock', [n, { includeTransactions: true }]);
  const effects = full?.body?.txEffects ?? [];
  if (effects.length) blocksWithTxs++;
  for (const [i, eff] of effects.entries()) {
    keys.push({ txHash: eff.txHash, blockNumber: n, index: i });
  }
  if (!quiet && effects.length) log(`  block ${n}: ${effects.length} tx`);
}

log(`\nenumeration: ${blocksSeen} blocks served, ${blocksMissing} not served, `
  + `${blocksWithTxs} with transactions, ${keys.length} transaction hashes`);

let fetchKeys = keys;
if (maxBodies > 0 && keys.length > maxBodies) {
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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const controls = [];
{
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
if (fetchKeys.length) {
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
let bytesFetched = 0, bytesSaved = 0;
let done = 0;

async function handle(key) {
  const url = bodyUrl(storeBase, basePath, key.txHash);
  const r = await raw(url);
  if (r.bytes) bytesFetched += r.bytes.length;
  const verdict = classify(key.txHash, r.status, r.bytes);
  counts[verdict.outcome]++;
  if (verdict.outcome !== 'verified') {
    refusals.push({ ...key, url, httpStatus: r.status, ...verdict });
  } else if (saveDir) {
    // Mirrored only on request, and only after it verified. An unverified
    // payload is not a body and does not get written anywhere.
    const p = join(resolve(saveDir), `0x${bareHash(key.txHash)}.bin`);
    writeFileSync(p, r.bytes);
    bytesSaved += r.bytes.length;
  }
  done++;
  if (!quiet && done % 10 === 0) log(`  … ${done}/${fetchKeys.length}`);
}

log(`\nfetching ${fetchKeys.length} bodies (concurrency ${concurrency})…`);
const queue = fetchKeys.slice();
await Promise.all(Array.from({ length: Math.min(concurrency, queue.length) }, async () => {
  for (let k = queue.shift(); k; k = queue.shift()) await handle(k);
}));

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
           example: bodyUrl(storeBase, basePath, '00'.repeat(32)) },
  range: { from, to,
           blocksServed: blocksSeen, blocksNotServed: blocksMissing,
           blocksWithTransactions: blocksWithTxs,
           transactionsEnumerated: keys.length,
           bodiesAttempted: fetchKeys.length },
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
  bytes: { fetched: bytesFetched, saved: bytesSaved,
           meanBodySize: fetchKeys.length ? Math.round(bytesFetched / Math.max(1, counts.verified)) : 0 },
  refusals,
};

log('\n── counts ' + '─'.repeat(60));
for (const o of OUTCOMES) log(`  ${o.padEnd(12)} ${counts[o]}`);
log(`  ${'—'.repeat(12)}`);
log(`  ${'enumerated'.padEnd(12)} ${keys.length}   (transactions in blocks ${from}..${to})`);
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
const controlsFailed = controls.some((c) => !c.pass);
const proofFailed = rejectionProof && rejectionProof.ran && !rejectionProof.pass;
if (counts.mismatched || counts.truncated || controlsFailed || proofFailed) process.exit(1);
process.exit(0);
}
