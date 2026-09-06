#!/usr/bin/env node
// backfill-bodies-selftest.mjs — proof that `backfill-bodies.mjs` REFUSES.
//
//   node tools/chain/backfill-bodies-selftest.mjs
//
// WHY THIS EXISTS. `backfill-bodies.mjs` accepts transaction bodies from a
// SINGLE UNTRUSTED SOURCE with no failover, and the only thing standing between
// that source and the corpus is one rule: the leading 32 bytes of a correct
// payload are the key that was requested. A verifier that has never been
// observed refusing is not known to verify — it is indistinguishable from
// `return true`. So every refusal path is driven here, and each one is paired
// with the passing control it must differ from.
//
// THE LIVE CHAIN CANNOT PRODUCE THESE CASES ON DEMAND. Aztec's file store has
// answered every real key it was asked for; a mismatched payload, a truncated
// one, and a rate limit are exactly the answers it does not give, which is why
// they are driven against a MOCK STORE whose answers this test chooses. The one
// thing the mock does NOT get to choose is the verifier — the tool under test is
// spawned as a subprocess, so what is exercised is the code that runs.
//
// THE THREE COUNTS THAT MUST NOT COLLAPSE. `absent` says the corpus has a hole,
// `mismatched` says the corpus lied, and `unavailable` says the run could not
// ask. Cases 2-4 assert that a single run reports all three as separate numbers
// rather than as one "failed" — folding them would hide the failure the design
// exists to catch, and would let a rate limit masquerade as a missing body.
//
// Each case has a control arm and a mutation arm, and the assertion count is
// declared at the bottom.

import { mkdtemp, writeFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  classify, storeBasePath, bodyUrl, bareHash,
  txCountFromNoteDelta, bucketize, summarise, NOTE_HASHES_PER_TX,
} from './backfill-bodies.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, 'backfill-bodies.mjs');

let asserted = 0, failed = 0;
const ck = (label, cond) => { asserted++; if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`); };
const bite = (label, cond) => { asserted++; if (!cond) { failed++; console.error(`  FAIL  MUTATION DID NOT BITE  ${label}`); } else console.error(`  bite  ${label}`); };

// ── the deployment the mock node claims to be ───────────────────────────────

const NODE_INFO = {
  nodeVersion: '5.2.0-mock',
  l1ChainId: 1,
  rollupVersion: 4248422647,
  l1ContractAddresses: { rollupAddress: '0x91ff8bbd8ebb07893010d50a48a1609e5ebd8e34' },
};
const BASE_PATH = storeBasePath(NODE_INFO);

const hash = (n) => `0x${String(n).padStart(2, '0').repeat(32).slice(0, 64)}`;
/** A body is its own hash, then payload. That is the whole contract. */
const body = (h, extra = 64) =>
  Buffer.concat([Buffer.from(bareHash(h), 'hex'), Buffer.alloc(extra, 0x5a)]);

// ── the mock node ───────────────────────────────────────────────────────────
// `blocks` maps block number -> array of tx hashes the block will claim.

let blocks = {};
// `hiddenFromHeaders` names blocks whose txs the note-hash tree will pretend
// never happened — the header says empty, the body says otherwise. `skew` names
// blocks whose tree grows by a number that is not a whole tx. Both exist because
// the bulk path DERIVES counts from headers, and a derivation nobody has watched
// be wrong is indistinguishable from one that cannot be.
let hiddenFromHeaders = new Set();
let skew = {};
let getBlocksCalls = 0;

/** The note-hash leaf index after block n, as the mock's headers report it. */
function noteIndexAfter(n) {
  let leaves = 0;
  for (const k of Object.keys(blocks).map(Number).sort((a, b) => a - b)) {
    if (k > n) break;
    if (!hiddenFromHeaders.has(k)) leaves += blocks[k].length * NOTE_HASHES_PER_TX;
    leaves += skew[k] ?? 0;
  }
  return leaves;
}

const header = (n) => ({
  number: n,
  header: {
    totalManaUsed: blocks[n].length ? '0x2710' : '0x0',
    state: { partial: {
      noteHashTree: { nextAvailableLeafIndex: noteIndexAfter(n) },
      nullifierTree: { nextAvailableLeafIndex: noteIndexAfter(n) + 128 },
      publicDataTree: { nextAvailableLeafIndex: 0 },
    } },
  },
});

const node = createServer((req, res) => {
  let raw = '';
  req.on('data', (d) => { raw += d; });
  req.on('end', () => {
    const { id, method, params } = JSON.parse(raw);
    const reply = (result) =>
      res.writeHead(200, { 'content-type': 'application/json' })
         .end(JSON.stringify({ jsonrpc: '2.0', id, result }));
    if (method === 'node_getNodeInfo') return reply(NODE_INFO);
    if (method === 'node_getBlocks') {
      getBlocksCalls++;
      const [start, limit] = params;
      const out = [];
      for (let n = start; n < start + limit; n++) {
        if (blocks[n] !== undefined) out.push(header(n));
      }
      return reply(out);
    }
    if (method === 'node_getBlock') {
      const n = params[0];
      const txs = blocks[n];
      if (txs === undefined) return reply(null);
      const head = { header: { totalManaUsed: txs.length ? '0x2710' : '0x0' } };
      if (params[1]?.includeTransactions) {
        head.body = { txEffects: txs.map((h) => ({ txHash: h })) };
      }
      return reply(head);
    }
    reply(null);
  });
});

// ── the mock store ──────────────────────────────────────────────────────────
// `answers` maps a bare hash -> what the store will do with it. Anything not
// named 404s, which is what the real store does.

let answers = {};
let answerEverything = false;   // the "a 200 means nothing" mutation
let storeRequests = 0;          // so "fetched nothing" can be checked, not claimed
const store = createServer((req, res) => {
  storeRequests++;
  const m = /^\/mainnet\/txs\/([^/]+)\/txs\/0x([0-9a-f]{64})\.bin$/.exec(req.url);
  if (!m) return res.writeHead(404).end();
  const [, prefix, h] = m;
  if (answerEverything) return res.writeHead(200).end(body(hash(99)));
  // The prefix is load-bearing: a real key under a wrong deployment path is not
  // this deployment's body, and the real store 404s it.
  if (prefix !== BASE_PATH) return res.writeHead(404).end();
  const a = answers[h];
  if (a === undefined) return res.writeHead(404).end();
  if (typeof a === 'number') return res.writeHead(a).end();
  res.writeHead(200, { 'content-type': 'application/octet-stream' }).end(a);
});

await new Promise((r) => node.listen(0, '127.0.0.1', r));
await new Promise((r) => store.listen(0, '127.0.0.1', r));
const NODE_URL = `http://127.0.0.1:${node.address().port}`;
const STORE_URL = `http://127.0.0.1:${store.address().port}/mainnet/txs`;

const dir = await mkdtemp(join(tmpdir(), 'bt-backfill-selftest-'));
const CONFIG = join(dir, 'network_config.json');
await writeFile(CONFIG, JSON.stringify({
  mainnet: { txCollectionFileStoreUrls: [STORE_URL] },
  twoSource: { txCollectionFileStoreUrls: [STORE_URL, STORE_URL] },
  noStore: { bootnodes: [] },
}));

/** Run the tool and hand back its exit code and parsed report. */
function run(extra = []) {
  return new Promise((resolve) => {
    // `extra` goes FIRST, because the tool reads the first occurrence of a flag —
    // so a case that wants a different `--network` gets one. Appending it instead
    // let two cases silently run against the default, and both of their mutations
    // stopped biting without either of them failing loudly.
    const p = spawn(process.execPath, [
      TOOL, ...extra, '--url', NODE_URL, '--config', CONFIG, '--network', 'mainnet',
      '--from', '10', '--to', '20', '--quiet',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    let out = '', err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('close', (code) => {
      let report = null;
      try { report = JSON.parse(out); } catch { /* refusals print no report */ }
      resolve({ code, report, err, out });
    });
  });
}

// ── case 1 — the leading-32-bytes rule, in isolation ────────────────────────

console.error('\ncase 1 — a payload is verified against the key that was requested');
{
  const h = hash(1);
  ck('control: a payload whose first 32 bytes are the key verifies',
     classify(h, 200, body(h)).outcome === 'verified');
  const flipped = body(h); flipped[7] ^= 0xff;
  const v = classify(h, 200, flipped);
  bite('mutation: one byte flipped INSIDE the key is a mismatch, not a body',
       v.outcome === 'mismatched' && v.saw !== h);
  const tail = body(h); tail[40] ^= 0xff;
  ck('control: a byte flipped OUTSIDE the key does not change the verdict — '
     + 'this rule is about the key, and claiming more would be a lie',
     classify(h, 200, tail).outcome === 'verified');
  bite('mutation: a payload too short to carry a key is `truncated`, not `verified`',
       classify(h, 200, body(h).subarray(0, 31)).outcome === 'truncated');
  bite('mutation: another transaction\'s intact body under this key is a mismatch',
       classify(h, 200, body(hash(2))).outcome === 'mismatched');
}

// ── case 2 — the three counts stay three counts ─────────────────────────────

console.error('\ncase 2 — absent, mismatched and unavailable are reported separately');
{
  const [a, b, c, d] = [hash(11), hash(12), hash(13), hash(14)];
  blocks = { 10: [], 11: [a, b], 12: [c, d], 13: [] };
  const wrong = body(hash(77)); // 200, but the wrong key inside
  answers = {
    [bareHash(a)]: body(a),        // verified
    [bareHash(b)]: wrong,          // mismatched
    // c is simply absent — the store 404s anything it does not name
    [bareHash(d)]: 503,            // unavailable
  };
  const r = await run();
  const k = r.report?.counts ?? {};
  ck('control: the verified body is counted verified', k.verified === 1);
  ck('the 404 is counted `absent` and nothing else', k.absent === 1);
  bite('the 200-with-the-wrong-key is counted `mismatched`, NOT absent and NOT verified',
       k.mismatched === 1 && k.absent === 1 && k.verified === 1);
  bite('the 503 is counted `unavailable`, NOT `absent` — a rate limit is a fact '
     + 'about the run, and must not masquerade as a missing body',
       k.unavailable === 1 && k.absent === 1);
  ck('every enumerated hash lands in exactly one outcome',
     Object.values(k).reduce((x, y) => x + y, 0) === 4
     && r.report.range.transactionsEnumerated === 4);
  ck('each refusal is named with its hash, its block and a reason — an absence '
     + 'with no stated reason is indistinguishable from a broken feature',
     r.report.refusals.length === 3
     && r.report.refusals.every((x) => x.txHash && x.reason.length > 40
                                   && Number.isInteger(x.blockNumber)));
  bite('a mismatch makes the run fail: the corpus contradicted itself',
       r.code === 1);
}

// ── case 3 — a clean range exits 0, so case 2's exit 1 means something ──────

console.error('\ncase 3 — the control arm for case 2\'s exit code');
{
  const [a, b] = [hash(21), hash(22)];
  blocks = { 10: [], 11: [a], 12: [b] };
  answers = { [bareHash(a)]: body(a), [bareHash(b)]: body(b) };
  const r = await run();
  ck('control: every key resolving to a self-verifying body exits 0',
     r.code === 0 && r.report.counts.verified === 2
     && r.report.counts.mismatched === 0);
  ck('the hash count equals the body count over the range',
     r.report.range.transactionsEnumerated === r.report.counts.verified);
}

// ── case 4 — an absent body alone does not fail the run ─────────────────────

console.error('\ncase 4 — a hole is reported, not silently lowered, and is not a mismatch');
{
  const [a, b] = [hash(31), hash(32)];
  blocks = { 10: [], 11: [a], 12: [b] };
  answers = { [bareHash(a)]: body(a) };     // b is absent
  const r = await run();
  ck('a gap NAMES the hash rather than lowering the expectation',
     r.report.range.transactionsEnumerated === 2
     && r.report.counts.verified === 1 && r.report.counts.absent === 1
     && r.report.refusals[0].txHash === b);
  ck('an absence is not a corpus contradiction, so it does not exit 1',
     r.code === 0);
}

// ── case 5 — the negative controls are checks, not prose ───────────────────

console.error('\ncase 5 — a 200 is measured against two things that fail');
{
  const a = hash(41);
  blocks = { 10: [], 11: [a] };
  answers = { [bareHash(a)]: body(a) };
  answerEverything = false;
  const good = await run();
  ck('control: against an honest store both negative controls pass',
     good.report.controls.length === 2 && good.report.controls.every((c) => c.pass));

  answerEverything = true;   // a store that says 200 to anything
  const bad = await run();
  bite('mutation: a store that answers everything fails the negative controls, '
     + 'because then a 200 does not mean it holds the key',
       bad.report.controls.some((c) => !c.pass) && bad.code === 1);
  answerEverything = false;
}

// ── case 6 — the store location is derived, never guessed ───────────────────

console.error('\ncase 6 — the location is a configuration fact');
{
  ck('control: the path segment is built from the node\'s own answer',
     BASE_PATH === 'aztec-1-4248422647-0x91ff8bbd8ebb07893010d50a48a1609e5ebd8e34');
  let threw = false;
  try { storeBasePath({ l1ChainId: 1, l1ContractAddresses: {} }); } catch { threw = true; }
  bite('mutation: a node that will not say which rollup it serves yields no path',
       threw);
  const r = await run(['--network', 'noStore']);
  bite('mutation: a network whose config declares no txCollectionFileStoreUrls is '
     + 'refused, not defaulted to a pasted URL',
       r.code === 1 && /no txCollectionFileStoreUrls/.test(r.err));
  ck('control: the URL is assembled from base, derived path and key',
     bodyUrl('https://x/mainnet/txs', BASE_PATH, hash(1))
       === `https://x/mainnet/txs/${BASE_PATH}/txs/${hash(1)}.bin`);
}

// ── case 7 — the unmet redundancy rule is recorded, not relaxed ─────────────

console.error('\ncase 7 — one source is reported as one source');
{
  const a = hash(51);
  blocks = { 10: [], 11: [a] };
  answers = { [bareHash(a)]: body(a) };
  const one = await run();
  ck('a single declared source records the two-source rule as UNMET',
     one.report.redundancy.met === false && /UNMET/.test(one.report.redundancy.note));
  const two = await run(['--network', 'twoSource']);
  bite('control arm: two declared sources do not report it unmet, so the flag is '
     + 'reading the config rather than hard-coded',
       two.report.redundancy.met === true);
}

// ── case 8 — mirroring is not publishing ───────────────────────────────────

console.error('\ncase 8 — a save into the published corpus is refused');
{
  const a = hash(61);
  blocks = { 10: [], 11: [a] };
  answers = { [bareHash(a)]: body(a) };
  const ok = join(dir, 'mirror');
  const r = await run(['--save', ok]);
  ck('control: a verified body mirrors to an ordinary directory',
     r.code === 0 && (await readdir(ok)).includes(`${hash(61)}.bin`));

  const forbidden = join(dir, 'client', 'fixtures', 'chain', 'x');
  const bad = await run(['--save', forbidden]);
  bite('mutation: a save inside client/fixtures/ is refused — the store publishes '
     + 'no terms, so anything derived from it is forbidden to publish until that '
     + 'is clarified',
       bad.code === 1 && /publishing surface/.test(bad.err));
  ck('the report says publication is not permitted, and says why',
     r.report.publication.permitted === false
     && /forbidden until clarified/.test(r.report.publication.reason));
}

// ── case 9 — an unverified payload is never written ─────────────────────────

console.error('\ncase 9 — only a body that verified reaches the mirror');
{
  const [a, b] = [hash(71), hash(72)];
  blocks = { 10: [], 11: [a, b] };
  answers = { [bareHash(a)]: body(a), [bareHash(b)]: body(hash(88)) };
  const out = join(dir, 'mirror2');
  const r = await run(['--save', out]);
  const written = await readdir(out);
  ck('control: the verified body is on disk', written.includes(`${a}.bin`));
  bite('mutation: the mismatched payload is NOT on disk — it is not a body, and a '
     + 'mirror of it would be a corpus entry the store cannot vouch for',
       !written.includes(`${b}.bin`) && written.length === 1
       && r.report.counts.mismatched === 1);
}

// ── case 10 — enumeration counts what the chain published ──────────────────

console.error('\ncase 10 — the transaction count is measured, with the range it covers');
{
  blocks = { 10: [], 11: [hash(81), hash(82), hash(83)], 12: [], 13: [hash(84)] };
  answers = Object.fromEntries([81, 82, 83, 84].map((n) => [bareHash(hash(n)), body(hash(n))]));
  const r = await run();
  ck('the count is the sum of the blocks\' txEffects, and carries its range',
     r.report.range.transactionsEnumerated === 4
     && r.report.range.blocksWithTransactions === 2
     && r.report.range.from === 10 && r.report.range.to === 20);
  ck('heights the node does not serve are counted, not silently dropped',
     r.report.range.blocksServed === 4 && r.report.range.blocksNotServed === 7);
}

// ── case 11 — counting a block from its header alone ────────────────────────
//
// The bulk path never sees a body for most of the chain. What it sees is how far
// the note-hash tree moved, and the ONLY reason that is a transaction count is
// the fixed-size padded subtree. So the arithmetic is pinned here, including the
// two shapes of growth that are not a count and must not be floored into one.

console.error('\ncase 11 — transactions per block, derived from the note-hash tree');
{
  ck('control: growth of exactly one subtree is exactly one transaction',
     txCountFromNoteDelta(0, 64).count === 1);
  ck('control: no growth is no transactions — the common case on this chain',
     txCountFromNoteDelta(4096, 4096).count === 0);
  ck('control: nine subtrees of growth is nine transactions',
     txCountFromNoteDelta(1000 * 64, 1009 * 64).count === 9);
  const partial = txCountFromNoteDelta(0, 100);
  bite('mutation: growth that is not a whole number of subtrees is NOT a count — '
     + 'flooring 100 leaves to one transaction would invent the answer',
       partial.ok === false && /multiple/.test(partial.reason));
  const shrank = txCountFromNoteDelta(128, 64);
  bite('mutation: an append-only tree that shrank is refused, not read as -1',
       shrank.ok === false && /shrank/.test(shrank.reason));
  bite('mutation: a header with no leaf index yields no count rather than NaN',
       txCountFromNoteDelta(undefined, 64).ok === false);
}

// ── case 12 — the distribution keeps the shape a mean destroys ──────────────

console.error('\ncase 12 — burstiness survives being reported');
{
  // 18 transactions inside one window and none in the next three: the shape this
  // campaign has already once flattened into a rate.
  const perBlock = new Map();
  for (let n = 1; n <= 4000; n++) perBlock.set(n, 0);
  perBlock.set(120, 18);
  const w = bucketize(perBlock, 1, 4000, 1000);
  ck('control: the windows tile the range with no gap and no overlap',
     w.length === 4 && w[0].from === 1 && w[0].to === 1000
     && w[3].to === 4000 && w.reduce((a, b) => a + b.blocks, 0) === 4000);
  ck('the burst stays in the window that held it', w[0].transactions === 18);
  bite('mutation: the three empty windows are REPORTED as zero, not dropped — '
     + 'dropping them is exactly what turns a bursty series into a rate',
       w.filter((x) => x.transactions === 0).length === 3);
  const s = summarise(w);
  ck('the summary says the median window held nothing while the max held 18, '
     + 'so the mean of 4.5 is visibly a number no window ever held',
     s.median === 0 && s.max === 18 && s.mean === 4.5 && s.emptyWindows === 3
     && s.total === 18);
  let threw = false;
  try { bucketize(perBlock, 1, 10, 0); } catch { threw = true; }
  bite('mutation: a zero-width window is refused rather than looping forever', threw);
}

// ── case 13 — the bulk path agrees with the path it replaces ───────────────
//
// The bulk path exists to make a 75k-block enumeration affordable. It is only
// worth having if it gets the SAME ANSWER as the per-block path it replaces, so
// both are run over the same mock chain and required to agree — and then the
// headers are made to lie, to check that the disagreement is caught rather than
// inherited.

console.error('\ncase 13 — bulk header derivation, checked against the bodies');
{
  const h = (n) => hash(n);
  blocks = { 9: [], 10: [], 11: [h(11), h(12)], 12: [], 13: [h(13)], 14: [], 15: [],
             16: [h(16), h(17), h(18)], 17: [], 18: [], 19: [], 20: [h(20)] };
  answers = Object.fromEntries(
    Object.values(blocks).flat().map((x) => [bareHash(x), body(x)]));

  hiddenFromHeaders = new Set(); skew = {};
  getBlocksCalls = 0;
  const bulk = await run(['--bulk-headers', '--window', '5']);
  const plain = await run([]);
  ck('control: the bulk path and the per-block path enumerate the same count',
     bulk.report.range.transactionsEnumerated === 7
     && plain.report.range.transactionsEnumerated === 7);
  ck('the bulk path actually used the bulk method — otherwise this case is '
     + 'testing the per-block path twice and would pass with the feature removed',
     getBlocksCalls > 0 && bulk.report.enumeration.strategy === 'bulk-headers+bodies');
  ck('the derivation opened only the blocks it said were non-empty, plus the '
     + 'sample of the ones it said were empty',
     bulk.report.enumeration.headerDerivation.blocksDerivedNonEmpty === 4
     && bulk.report.enumeration.headerDerivation.blocksIndeterminate === 0);
  ck('control: an honest chain produces no anomalies and exits 0',
     bulk.report.enumeration.anomalies.length === 0 && bulk.code === 0);
  ck('the distribution carries the windows, not just a total',
     bulk.report.enumeration.windows.length === 3
     && bulk.report.enumeration.distribution.total === 7
     && bulk.report.enumeration.windows[0].transactions === 3);

  // MUTATION: the header understates block 16, so the derivation calls it empty.
  // Phase D opens a sample of the blocks called empty precisely so this is found.
  hiddenFromHeaders = new Set([16]);
  const lying = await run(['--bulk-headers']);
  bite('mutation: a header that understates a block is caught by opening blocks '
     + 'the derivation called EMPTY — a rule checked only where it fires is not checked',
       lying.report.enumeration.anomalies.some(
         (a) => a.kind === 'derived-empty-but-body-has-transactions' && a.block === 16)
       && lying.code === 1);
  bite('and the understated transactions are still counted, from the body that '
     + 'has them rather than the header that denied them',
       lying.report.range.transactionsEnumerated === 7);

  // MUTATION: growth that is not a whole transaction must not be floored.
  hiddenFromHeaders = new Set(); skew = { 13: 7 };
  const skewed = await run(['--bulk-headers']);
  bite('mutation: a block whose tree grew by a fraction of a transaction is '
     + 'INDETERMINATE and gets opened, not counted from the arithmetic',
       skewed.report.enumeration.headerDerivation.blocksIndeterminate >= 1
       && skewed.report.range.transactionsEnumerated === 7);
  skew = {};
}

// ── case 14 — enumeration is not a download ────────────────────────────────
//
// The count and the corpus are different questions. Settling the count must not
// cost the ~GB that fetching every body costs, and "it did not fetch them" is
// checked against the store's own request counter rather than asserted.

console.error('\ncase 14 — --enumerate-only answers the count without fetching bodies');
{
  const h = (n) => hash(n);
  blocks = { 9: [], 10: [], 11: [h(11), h(12)], 12: [h(13)] };
  answers = Object.fromEntries(
    Object.values(blocks).flat().map((x) => [bareHash(x), body(x)]));

  storeRequests = 0;
  const only = await run(['--enumerate-only', '--bulk-headers']);
  const requestsWhileEnumerating = storeRequests;
  ck('control: the count is produced in full',
     only.report.range.transactionsEnumerated === 3
     && only.report.enumeration.transactionsFromPerBlockCounts === 3);
  bite('mutation: the store was asked for NOTHING — not a body, not even a '
     + 'negative control, because this run answers a question the store is not part of',
       requestsWhileEnumerating === 0
       && only.report.range.bodiesAttempted === 0
       && only.report.controls.length === 0);

  storeRequests = 0;
  const withBodies = await run(['--bulk-headers']);
  bite('control arm: the same range WITHOUT the flag does hit the store, so the '
     + 'zero above is the flag working rather than a mock that never answers',
       storeRequests > 0 && withBodies.report.counts.verified === 3);

  ck('a completed pass says so, and says how far it got',
     only.report.completion.complete === true
     && only.report.completion.reachedBlock === 20
     && only.report.completion.rpcCalls > 0);
}

// ── case 15 — the number the corpus estimate multiplies by ──────────────────
//
// Corpus size is count × mean body size, and the mean comes from a SAMPLE
// because fetching 36,629 bodies to measure them is the download the sample
// exists to avoid. A sample taken off the FRONT of the enumeration is a mean of
// one region of one day; this pins that `--sample-bodies` spreads across the
// whole range, using `--max-bodies` (which takes the first N, by design) as the
// arm it must differ from.

console.error('\ncase 15 — the mean body size is sampled across the range, not off the front');
{
  const hs = Array.from({ length: 10 }, (_, i) => hash(101 + i));
  blocks = { 10: [], 11: hs.slice(0, 4), 12: hs.slice(4, 7), 13: hs.slice(7) };
  // Body i is 32 + 100·i bytes, so WHICH bodies were sampled is readable off
  // the sizes alone — the report does not have to name them.
  answers = Object.fromEntries(hs.map((h, i) => [bareHash(h), body(h, 100 * i)]));

  const spread = await run(['--sample-bodies', '4']);
  const front = await run(['--max-bodies', '4']);
  ck('control: the sample is bounded, and says what it is a sample OF — so the '
     + 'product is read as an estimate rather than a measurement',
     spread.report.range.bodiesAttempted === 4
     && spread.report.bytes.sampledOf === 10
     && spread.report.counts.verified === 4);
  ck('the spread of the sampled sizes is reported, not just their mean — a mean '
     + 'with no spread cannot be told from a mean of something that has none',
     spread.report.bytes.verifiedSizeSpread.windows === 4
     && spread.report.bytes.meanVerifiedBodySize > 0);
  bite('mutation: --sample-bodies REACHES THE END of the enumeration, where '
     + '--max-bodies never does — the two disagree about the mean precisely '
     + 'because one of them only ever measures the front',
       spread.report.bytes.verifiedSizeSpread.max > front.report.bytes.verifiedSizeSpread.max
       && front.report.bytes.verifiedSizeSpread.max === 32 + 300
       && spread.report.bytes.meanVerifiedBodySize > front.report.bytes.meanVerifiedBodySize);
}

// ── done ────────────────────────────────────────────────────────────────────

node.close(); store.close();
await rm(dir, { recursive: true, force: true });
console.error('');
if (asserted !== 57) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 57 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (getBlocksCalls === 0) {
  console.error('THE BULK HEADER PATH WAS NEVER EXERCISED — case 13 measured nothing.');
  failed++;
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('PASS — the verifier refuses on every path it is supposed to');
