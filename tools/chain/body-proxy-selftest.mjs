#!/usr/bin/env node
// body-proxy-selftest.mjs — every arm of the historic-replay seam, offline.
//
// Usage:
//   node tools/chain/body-proxy-selftest.mjs --runtime <path-to-aztec-avm-runtime>
//
// ── WHY THIS EXISTS AND WHAT IT REFUSES TO ASSUME ──────────────────────────────────────
//
// `lib/body-proxy.mjs` sits between the replay driver and two remote services and decides,
// per call, which one answers. Every one of its decisions is invisible from the outside: a
// body served from a mirror and a body served from the node produce the same replay, a
// cached witness and a re-fetched one produce the same replay, and a rate limit that leaked
// into a transaction's row produces a plausible-looking refusal. The only way any of that is
// checkable is to drive the proxy against a store and an endpoint whose answers this file
// chose, so it can assert what was ASKED as well as what came back.
//
// NO NETWORK. The "store" and the "node" are two `http.Server`s started here, and the
// assertions are about their request logs. A check that reached the real endpoints would be
// measuring somebody else's uptime and would spend the one budget this campaign is rationed
// by.
//
// NO COMMITTED BINARY EITHER, and that is the part worth reading. A body is a `Tx.toBuffer()`
// payload; the obvious way to test the decode is to commit one, which would put a 200 KiB
// opaque blob in the tree that nobody can regenerate and whose validity nobody can restate.
// Instead the body is BUILT from the runtime's own committed fixture: the JSON
// `getTxByHash` answer inside `replay/fixtures/testnet_replay_tx.json` is parsed with
// upstream's `Tx.schema` and re-serialised with `Tx.toBuffer()`. That is a real transaction
// in the real wire encoding, produced by the same library the store's bytes were produced
// by, and it costs nothing to keep true.
//
// `--runtime` is required for the same reason `capture-chain.mjs` requires it: this
// repository carries no AVM and no Aztec dependency, and the proxy's whole job is to speak a
// protocol whose serialisation lives over there.

import { createServer } from 'node:http';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { startBodyProxy, TX_BY_HASH } from './lib/body-proxy.mjs';
import { bareHash } from './backfill-bodies.mjs';

const argv = process.argv.slice(2);
const arg = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : d; };
const runtime = resolve(arg('runtime', process.env.AVM_RUNTIME ?? ''));

let asserted = 0;
let failed = 0;
const test = (n) => console.error(`\n── ${n} ──`);
const ck = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`);
};
const expectCount = (n) => {
  if (asserted !== n) {
    failed++;
    console.error(`\nASSERTION COUNT IS ${asserted}, EXPECTED ${n} — a case was added, `
      + `removed or silently skipped.`);
  } else {
    console.error(`\nassertion count: ${asserted} (as declared)`);
  }
};

if (!runtime || !existsSync(join(runtime, 'replay/node_modules'))) {
  console.error('body-proxy-selftest: --runtime <path-to-aztec-avm-runtime> is required, and it '
    + 'must have `replay/node_modules` installed. This repository carries no Aztec dependency '
    + 'and the proxy speaks a protocol whose serialisation lives in that checkout.');
  process.exit(2);
}

// ── the subject body, built from the runtime's own fixture ──────────────────────────────

const at = (p) => pathToFileURL(resolve(runtime, 'replay/node_modules', p)).href;
const { BarretenbergSync } = await import(at('@aztec/bb.js/dest/node/index.js'));
await BarretenbergSync.initSingleton();
const { Tx } = await import(at('@aztec/stdlib/dest/tx/index.js'));

const fixturePath = join(runtime, 'replay/fixtures/testnet_replay_tx.json');
const fixture = JSON.parse(await readFile(fixturePath, 'utf8'));
const recorded = fixture.calls.find((c) => c.method === TX_BY_HASH);
if (!recorded) {
  console.error(`body-proxy-selftest: ${fixturePath} records no ${TX_BY_HASH} call to build a `
    + 'body from. The fixture format changed and this check would otherwise pass vacuously.');
  process.exit(2);
}
const subject = await Tx.schema.parseAsync(recorded.result);
const subjectHash = subject.txHash.toString();
const subjectBytes = subject.toBuffer();

// ── the two fake services ───────────────────────────────────────────────────────────────

/** Records every request so the assertions can be about what was ASKED. */
function service(handler) {
  const log = [];
  const server = createServer((req, res) => {
    let raw = '';
    req.on('data', (d) => { raw += d; });
    req.on('end', () => handler({ url: req.url, body: raw, log }, res));
  });
  return {
    log,
    listen: () => new Promise((r) => server.listen(0, '127.0.0.1', () => r(
      `http://127.0.0.1:${server.address().port}`))),
    close: () => new Promise((r) => server.close(r)),
  };
}

/** `<base>/<basePath>/txs/0x<hash>.bin`. Four keys, four different answers. */
const OTHER_HASH = `0x${'ab'.repeat(32)}`;
const MISSING_HASH = `0x${'cd'.repeat(32)}`;
const TRUNCATED_HASH = `0x${'ef'.repeat(32)}`;
const store = service(({ url, log }, res) => {
  log.push(url);
  const key = (url.match(/0x([0-9a-f]{64})\.bin$/) ?? [])[1] ?? '';
  if (key === bareHash(subjectHash)) {
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    res.end(subjectBytes);
  } else if (key === bareHash(OTHER_HASH)) {
    // A 200 whose leading 32 bytes are SOMEBODY ELSE'S key. The whole reason a single
    // untrusted source is usable at all is that this is detectable.
    res.writeHead(200); res.end(subjectBytes);
  } else if (key === bareHash(TRUNCATED_HASH)) {
    res.writeHead(200); res.end(Buffer.alloc(8));
  } else {
    res.writeHead(404); res.end('not found');
  }
});

/** The node. Answers, or throttles, depending on `mode`. */
let mode = 'ok';
const upstream = service(({ body, log }, res) => {
  const reqs = JSON.parse(body);
  log.push(reqs.map((r) => r.method));
  if (mode === 'throttle') {
    res.writeHead(429, { 'retry-after': '2465' });
    res.end(JSON.stringify({ error: { code: 429, message: 'Too many requests' } }));
    return;
  }
  res.writeHead(200, {
    'content-type': 'application/json',
    'x-aztec-l1chainid': '11155111',
    'x-aztec-rollupversion': '1821665230',
  });
  res.end(JSON.stringify(reqs.map((r) => ({
    jsonrpc: '2.0', id: r.id, result: `${r.method}:${JSON.stringify(r.params ?? [])}`,
  }))));
});

const storeUrl = await store.listen();
const upstreamUrl = await upstream.listen();
const dir = await mkdtemp(join(tmpdir(), 'body-proxy-'));

const post = async (url, payload, raw = false) => {
  const r = await fetch(url, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  return raw ? r : r.json();
};

try {
  const proxy = await startBodyProxy({
    upstreamUrl, runtime,
    storeBase: storeUrl, storeBasePath: 'aztec-1-1-0xdeadbeef',
    bodyDir: join(dir, 'bodies'), rps: 0, attempts: 2,
  });

  // ── 1. the body half ──────────────────────────────────────────────────────────────────

  test('a settled historic body is served from the store, and it is the transaction asked for');
  {
    const [answer] = await post(proxy.url, [
      { jsonrpc: '2.0', id: 1, method: TX_BY_HASH, params: [subjectHash] }]);
    ck('the proxy answers with a result rather than an error',
       answer.id === 1 && answer.error === undefined && answer.result !== null);
    ck('nothing was forwarded to the node — the body half never touches the endpoint',
       upstream.log.length === 0);
    ck('the store was asked for exactly this key',
       store.log.length === 1 && store.log[0].endsWith(`/txs/${subjectHash}.bin`));

    // THE ANSWER IS PARSED BY UPSTREAM'S OWN SCHEMA, which is what the driver does to it.
    // Asserting the shape by hand would be this file's opinion of the wire format; parsing
    // it with `Tx.schema` is the format itself, and it re-derives the hash from `data` on
    // the way through, so a body that decoded into a DIFFERENT transaction cannot pass.
    const back = await Tx.schema.parseAsync(answer.result);
    ck('it parses with upstream\'s Tx.schema and hashes to the key that was requested',
       back.txHash.toString() === subjectHash);
    ck('the chonk proof is the empty sentinel, exactly as a live node serves it',
       String(answer.result.chonkProof) === 'AAAAAA==');
    ck('and the public calldata survived the round trip',
       back.publicFunctionCalldata.length === subject.publicFunctionCalldata.length);
  }

  test('a key the store does not hold is `null`, which is what a pruned node answers');
  {
    const before = store.log.length;
    const [answer] = await post(proxy.url, [
      { jsonrpc: '2.0', id: 2, method: TX_BY_HASH, params: [MISSING_HASH] }]);
    ck('the result is null and not an error — `fetchSettledTx` turns this into its own '
       + 'SettledTransactionNotFound, which lands on `body-unavailable`',
       answer.result === null && answer.error === undefined);
    ck('it is counted as `absent`, the store outcome that means "the corpus has a hole"',
       proxy.stats.bodyOutcomes.absent === 1);
    ck('and it was not forwarded to the node either', upstream.log.length === 0);
    ck('the store WAS asked', store.log.length === before + 1);
  }

  test('a 200 carrying somebody else\'s transaction is a MISS wearing a success');
  {
    const [answer] = await post(proxy.url, [
      { jsonrpc: '2.0', id: 3, method: TX_BY_HASH, params: [OTHER_HASH] }]);
    ck('it is refused — the proxy never hands the driver a transaction it did not ask for',
       answer.result === null);
    ck('and it is counted apart from `absent`: one says the corpus has a hole, the other '
       + 'says the corpus lied', proxy.stats.bodyOutcomes.mismatched === 1
       && proxy.stats.bodyOutcomes.absent === 1);
  }

  test('a 200 too short to carry a key is not a body');
  {
    const [answer] = await post(proxy.url, [
      { jsonrpc: '2.0', id: 4, method: TX_BY_HASH, params: [TRUNCATED_HASH] }]);
    ck('refused', answer.result === null);
    ck('counted as `truncated`', proxy.stats.bodyOutcomes.truncated === 1);
  }

  test('the proxy can be asked about a transaction without the driver being spawned');
  {
    const got = await proxy.inspect(subjectHash);
    ck('it reports the store outcome', got.outcome === 'verified');
    // THE NUMBER THAT DECIDES WHETHER A DRIVER RUNS AT ALL. Zero means the transaction has
    // no public execution — nothing to re-run — and the pipeline records `private-only`
    // instead of spawning a process that would crash inside upstream's unguarded
    // `getPublicCallRequestsWithCalldata()` and be filed as a repairable runtime fault.
    ck('…and how many public calls the body makes, measured with upstream\'s own guarded '
       + 'accessor rather than inferred from a crash',
       got.publicCalls === subject.numberOfPublicCalls() && got.publicCalls > 0);
    const gone = await proxy.inspect(MISSING_HASH);
    ck('a body nothing serves reports its store outcome and no call count — "we could not '
       + 'look" is not "we looked and found none"',
       gone.outcome === 'absent' && gone.publicCalls === null);
  }

  test('the mirror is re-verified on read, not trusted because we wrote it');
  {
    const before = store.log.length;
    const [answer] = await post(proxy.url, [
      { jsonrpc: '2.0', id: 5, method: TX_BY_HASH, params: [subjectHash] }]);
    ck('the second ask is served without going back to the store',
       store.log.length === before && answer.result !== null);
    ck('and the decode is not repeated either — one decode per hash per run',
       proxy.stats.bodiesServed === 1);
  }

  // ── 2. the forwarding half ────────────────────────────────────────────────────────────

  test('everything that is not a body is forwarded, in order, with ids preserved');
  {
    upstream.log.length = 0;
    const answers = await post(proxy.url, [
      { jsonrpc: '2.0', id: 10, method: 'aztec_getBlockData', params: [7] },
      { jsonrpc: '2.0', id: 11, method: TX_BY_HASH, params: [subjectHash] },
      { jsonrpc: '2.0', id: 12, method: 'aztec_getPublicDataWitness', params: [6, '0x1'] },
    ]);
    ck('the batch comes back whole and in the order it was sent',
       answers.length === 3 && answers.map((a) => a.id).join(',') === '10,11,12');
    ck('the mixed batch reached the node with ONLY the two calls it had to answer',
       upstream.log.length === 1 && upstream.log[0].join(',')
         === 'aztec_getBlockData,aztec_getPublicDataWitness');
    ck('the body was spliced back into its own slot', answers[1].result !== null
       && answers[1].result.txHash === subjectHash);
    ck('and the forwarded answers landed in theirs',
       answers[0].result === 'aztec_getBlockData:[7]'
       && answers[2].result === 'aztec_getPublicDataWitness:[6,"0x1"]');
  }

  test('an immutable historic answer is asked for once; a moving one is never cached');
  {
    upstream.log.length = 0;
    await post(proxy.url, [{ jsonrpc: '2.0', id: 20, method: 'aztec_getBlockData', params: [7] }]);
    ck('the repeat of a cacheable call did not reach the node at all',
       upstream.log.length === 0);
    await post(proxy.url, [{ jsonrpc: '2.0', id: 21, method: 'aztec_getBlockData', params: [8] }]);
    ck('…but a different parameter did — the cache is keyed by the question, not the method',
       upstream.log.length === 1);
    upstream.log.length = 0;
    await post(proxy.url, [{ jsonrpc: '2.0', id: 22, method: 'aztec_getBlockNumber', params: [] }]);
    await post(proxy.url, [{ jsonrpc: '2.0', id: 23, method: 'aztec_getBlockNumber', params: [] }]);
    ck('the tip is asked for every single time: a cached tip would be a fact about when '
       + 'this proxy started, not about the chain', upstream.log.length === 2);
  }

  test('the node\'s protocol-version headers reach the driver');
  {
    const r = await post(proxy.url,
      [{ jsonrpc: '2.0', id: 30, method: 'aztec_getNodeInfo', params: [] }], true);
    ck('x-aztec-* is forwarded — upstream SKIPS a version field whose header is absent, so '
       + 'dropping these would make every reply pass the version check in silence',
       r.headers.get('x-aztec-l1chainid') === '11155111'
       && r.headers.get('x-aztec-rollupversion') === '1821665230');
  }

  // ── 3. the rate limit ─────────────────────────────────────────────────────────────────

  test('a rate limit stops the proxy and never becomes a result');
  {
    mode = 'throttle';
    ck('not throttled before the endpoint says so', proxy.throttled === false);
    const [answer] = await post(proxy.url,
      [{ jsonrpc: '2.0', id: 40, method: 'aztec_getContract', params: ['0xfeed'] }]);
    ck('the call comes back as an ERROR and never as a result — a caller that read this as '
       + 'an answer would be recording our quota as a property of the chain',
       answer.error !== undefined && answer.result === undefined);
    ck('the proxy raises its own flag, which is what makes the caller stop',
       proxy.throttled === true);
    ck('and it records what the endpoint asked for, rather than sleeping it inside a request',
       proxy.stats.throttledRetryAfterMs === 2465 * 1000);

    // THE BODY HALF STILL WORKS WHILE THE NODE IS REFUSING, and that is not a curiosity:
    // it is why the two halves are separate services. A ban on the node endpoint says
    // nothing about the file store.
    const [body] = await post(proxy.url, [
      { jsonrpc: '2.0', id: 41, method: TX_BY_HASH, params: [subjectHash] }]);
    ck('a body is still served while the node endpoint is refusing', body.result !== null);
  }

  await proxy.close();
} finally {
  await store.close();
  await upstream.close();
  await rm(dir, { recursive: true, force: true });
}

expectCount(32);
console.error(failed === 0
  ? '\nPASS — the seam serves bodies, refuses misses, forwards the rest and stops when banned'
  : `\nFAIL — ${failed} assertion(s)`);
process.exit(failed === 0 ? 0 : 1);
