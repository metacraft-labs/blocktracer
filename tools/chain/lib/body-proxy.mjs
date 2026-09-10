// body-proxy.mjs — the seam that makes a SETTLED, HISTORIC transaction replayable.
//
// ── THE ONE THING THAT WAS MISSING ─────────────────────────────────────────────────────
//
// Everything a replay needs from a historic Aztec transaction is served for the whole chain
// except one input, and that one input is not served by the node at all:
//
//   header / effects            `getTxEffect`, `getBlockData` — archival, prune never
//   pre-state witnesses         `getPublicDataWitness`, `getNullifierMembershipWitness` at
//                               the SETTLING BLOCK'S PARENT. The testnet node reports
//                               `oldestHistoricBlockNumber: 1`, so it keeps world-state
//                               history for the entire chain rather than the ~64 checkpoints
//                               the default config implies.
//   contract instance / class   `getContract`, `getContractClass` — world state
//   ── the transaction BODY ──   `getTxByHash`, WHICH IS A MEMPOOL QUERY.
//
// `AztecNodeService.getTxByHash` serves only from the active tx pool and the pool deletes a
// mined transaction when its block is FINALIZED. So the body — the one thing
// `AvmTxHint.fromTx` consumes — is gone about an hour after the transaction lands, while
// everything else about it stays visible forever. That is the whole reason 18,508 of this
// chain's 20,770 transactions were recorded `pruned` by the backfill: not "we could not get
// the state", just "we could not get the body".
//
// `backfill-bodies.mjs` already proved the bodies are retrievable from Aztec's own keyless
// `TxFileStore` — one content-addressed `.bin` per hash, self-verifying because
// `Tx.toBuffer()` serialises `txHash` first. What did not exist was a way to hand one to the
// replay driver. The driver takes `--tx` and calls `getTxByHash`; there is no `--body` flag.
//
// ── WHY A PROXY AND NOT A `--body` FLAG ────────────────────────────────────────────────
//
// A `--body` flag would have to be added to `aztec-avm-runtime`, which is a different
// repository on a different release cadence, and `blocktracer`'s established relationship
// with it is "point `--runtime` at a checkout and drive its CLI" — every chain tool here
// does exactly that and none of them patches it. A proxy keeps that relationship: the driver
// is run UNMODIFIED, told `--url http://127.0.0.1:<port>`, and answers `getTxByHash` from the
// file store while everything else is forwarded to the real endpoint.
//
// It also buys three things a flag could not:
//
//   * ONE CHOKE POINT FOR THE RATE LIMIT. `aztec-testnet.drpc.org` is measured at 12 req/s
//     sustained before it starts refusing, and it answers a throttled request with
//     `retry-after: 2465` — forty-one minutes — across every dRPC host at once. A replay
//     makes ~30 node calls, so a range of 200 transactions is ~6,000 requests that MUST be
//     paced. Pacing inside the driver would need a driver change; pacing here needs none,
//     and it paces every call the driver makes whether or not this file knows about it.
//   * DEDUPLICATION ACROSS TRANSACTIONS. `getNodeInfo`, `getContract`, `getContractClass`
//     and `getBlockData` are asked again for every transaction in a range and the answers are
//     immutable at a historic height. Measured over the sample ranges, caching them removes
//     roughly a third of the requests, which is a third less of the only budget that matters.
//   * A THROTTLE CANNOT BECOME A REFUSAL. If the endpoint starts refusing, the proxy stops
//     and says so, and the caller abandons the range. Without that, every transaction after
//     the limit would record `runtime-refused` — our vocabulary asserting a property of the
//     transaction when the truth is a property of the run. That is the exact failure
//     `backfill-bodies.mjs` keeps `unavailable` apart from `absent` for.
//
// ── WHAT IT REFUSES TO DO ──────────────────────────────────────────────────────────────
//
// It never manufactures a body. A key the store does not hold is answered `null`, which is
// what a node with a pruned body answers, so `fetchSettledTx` raises its own
// `SettledTransactionNotFound` and the row lands on `body-unavailable` — a member of the
// closed set whose stated condition already covers this case in so many words ("the node no
// longer serves the transaction's body AND the file store cannot supply it either"). A 200
// whose leading 32 bytes are not the requested key is a MISS wearing a success and is
// answered `null` as well, counted separately as `mismatched`, because `classify` in
// `backfill-bodies.mjs` is the one implementation of that rule and this file calls it rather
// than restating it.

import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

import { classify, bareHash, bodyUrl } from '../backfill-bodies.mjs';

/** The wire spelling. Upstream's client is built with `namespaceMethods: 'aztec'`. */
export const TX_BY_HASH = 'aztec_getTxByHash';

/** Methods whose answer at a HISTORIC height cannot change, so one answer serves a range.
 *
 *  `aztec_getBlockNumber` is deliberately absent: the tip moves, and a cached tip would be a
 *  fact about when the proxy started rather than about the chain. Nothing in the `--tx` path
 *  calls it, and if something starts to, it must get the real answer.
 *
 *  The witness reads ARE cacheable by (method, params) — a witness at a named block is a
 *  fixed value — and they are the bulk of the traffic within one transaction's hydration
 *  rounds, which re-ask the same slots as the seed grows. */
const CACHEABLE = new Set([
  'aztec_getNodeInfo',
  'aztec_getBlockData',
  'aztec_getContract',
  'aztec_getContractClass',
  'aztec_getTxEffect',
  'aztec_getPublicDataWitness',
  'aztec_getNullifierMembershipWitness',
]);

/** Past this, a `Retry-After` is reported rather than slept through — the same cap
 *  `ingest-range.mjs` uses, and for the same reason: this endpoint asks for 2465 seconds and
 *  sleeping that inside a request handler is indistinguishable from a hang. */
const MAX_HONOURED_RETRY_AFTER_MS = 90_000;
const RATE_LIMIT_RE = /too many requests|rate limit|quota/i;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Load the two upstream classes this file needs, from the RUNTIME's `node_modules`.
 *
 *  BY ABSOLUTE PATH, not by bare specifier. This repository carries no `node_modules` and no
 *  Aztec dependency — `--runtime` is how it reaches one, and `lib/replay.mjs`'s preflight
 *  already imports the runtime's loader exactly this way. A bare `import '@aztec/stdlib'`
 *  would resolve against THIS file's directory and fail, and adding the dependency here would
 *  give the repository a second, independently-versioned copy of a protocol library whose
 *  serialisation must agree byte for byte with the one the driver runs. */
async function loadAztec(runtime) {
  const at = (p) => pathToFileURL(resolve(runtime, 'replay/node_modules', p)).href;
  // `Tx.fromBuffer` reaches `ChonkProof.fromCompressedBytes`, which reaches barretenberg's
  // synchronous singleton. Not initialising it throws `First call
  // BarretenbergSync.initSingleton()` from inside the decode, which reads like a corrupt body
  // and is not one.
  const { BarretenbergSync } = await import(at('@aztec/bb.js/dest/node/index.js'));
  await BarretenbergSync.initSingleton();
  const { Tx } = await import(at('@aztec/stdlib/dest/tx/index.js'));
  const { jsonStringify } = await import(at('@aztec/foundation/dest/json-rpc/convert.js'));
  return { Tx, jsonStringify };
}

/**
 * Start the proxy.
 *
 * @param {object} o
 * @param {string} o.upstreamUrl   the real node, e.g. `https://aztec-testnet.drpc.org`
 * @param {string} o.runtime       an `aztec-avm-runtime` checkout with `replay/node_modules`
 * @param {string} o.storeBase     `txCollectionFileStoreUrls[0]` for this network
 * @param {string} o.storeBasePath `aztec-<l1ChainId>-<rollupVersion>-<rollupAddress>`
 * @param {string} [o.bodyDir]     mirror bodies here, and read them from here on a re-run
 * @param {number} [o.rps]         requests per second to the UPSTREAM. 0 disables pacing.
 * @param {number} [o.attempts]    upstream attempts before giving a batch up
 * @param {(m: string) => void} [o.log]
 */
export async function startBodyProxy({
  upstreamUrl, runtime, storeBase, storeBasePath, bodyDir = '',
  rps = 6, attempts = 6, log = () => {},
}) {
  const { Tx, jsonStringify } = await loadAztec(runtime);
  if (bodyDir) mkdirSync(bodyDir, { recursive: true });

  const minGapMs = rps > 0 ? 1000 / rps : 0;
  let lastCallAt = 0;

  const stats = {
    upstreamBatches: 0, upstreamCalls: 0, upstreamFaults: 0,
    rateLimited: 0, backoffMs: 0, retryAfterMs: 0,
    cacheHits: 0, cacheMisses: 0,
    bodiesServed: 0, bodiesFromDisk: 0, bodyBytes: 0,
    bodyOutcomes: { verified: 0, absent: 0, mismatched: 0, truncated: 0, unavailable: 0 },
    // Set when the endpoint refuses past the honoured wait. THE RUN IS OVER at that point:
    // see the header on why this must not become a per-transaction refusal.
    throttled: false, throttledAt: null, throttledRetryAfterMs: 0,
  };

  const answers = new Map();      // `${method} ${JSON.stringify(params)}` -> result
  const bodies = new Map();       // bare hash -> { outcome, json|null }
  const inflight = new Map();     // bare hash -> Promise, so one hash is fetched once

  // ── the body half ────────────────────────────────────────────────────────────────────

  async function fetchBodyBytes(hash) {
    const cached = bodyDir ? join(bodyDir, `0x${bareHash(hash)}.bin`) : '';
    if (cached && existsSync(cached)) {
      const bytes = readFileSync(cached);
      // RE-VERIFIED ON READ, not trusted because we wrote it. A mirror is a corpus like any
      // other and the leading-32-bytes rule is the only reason a single untrusted source is
      // usable at all; skipping it for the local copy would relax exactly the guarantee.
      const c = classify(hash, 200, bytes);
      stats.bodiesFromDisk++;
      return { ...c, bytes: c.outcome === 'verified' ? bytes : null };
    }
    const url = bodyUrl(storeBase, storeBasePath, hash);
    let status = 0;
    let bytes = null;
    try {
      const r = await fetch(url);
      status = r.status;
      if (status === 200) bytes = Buffer.from(await r.arrayBuffer());
    } catch {
      status = 0;
    }
    const c = classify(hash, status, bytes);
    if (c.outcome === 'verified') {
      stats.bodyBytes += bytes.length;
      if (cached) writeFileSync(cached, bytes);
      return { ...c, bytes };
    }
    return { ...c, bytes: null };
  }

  /** The wire value for `getTxByHash`, or `null`. Decoded and re-encoded ONCE per hash. */
  async function bodyAnswer(hash) {
    const key = bareHash(hash);
    if (bodies.has(key)) return bodies.get(key);
    if (inflight.has(key)) return inflight.get(key);
    const p = (async () => {
      const got = await fetchBodyBytes(hash);
      stats.bodyOutcomes[got.outcome] = (stats.bodyOutcomes[got.outcome] ?? 0) + 1;
      let entry = { outcome: got.outcome, reason: got.reason, json: null };
      if (got.bytes) {
        // THE DECODE IS ITS OWN FAILURE MODE AND IT IS NOT A MISSING BODY. A payload whose
        // first 32 bytes are the key and whose remainder this protocol version cannot parse
        // is a real thing — a body written by a different serialisation — and answering
        // `null` for it would file it as `body-unavailable`, which is false. It is counted as
        // `truncated`, the store outcome that already means "a 200 that is not a body".
        try {
          const tx = Tx.fromBuffer(got.bytes);
          entry = {
            outcome: 'verified',
            reason: got.reason,
            // HOW MANY PUBLIC CALLS THIS TRANSACTION MAKES, measured here because this is
            // where the body is already decoded and nowhere else in the pipeline has one.
            //
            // A transaction with zero has no public execution at all — its private half ran
            // in a wallet and only its effects were published — and there is nothing to
            // replay. Without this the driver is spawned anyway and CRASHES on it:
            // upstream's `getPublicCallRequestsWithCalldata()` reads
            // `data.forPublic.nonRevertibleAccumulatedData` and `forPublic` is `undefined`,
            // so the pipeline learns "there was no public half" by interpreting a
            // `TypeError`. That is not a measurement, and `decideOutcome` correctly files an
            // unrecognised crash as a repairable runtime refusal — a false claim about a
            // permanent property of the chain.
            //
            // `numberOfPublicCalls()` is upstream's own accessor and it is the guarded one:
            // `numberOfPublicCallRequests()` tests `forPublic` before every read, which is
            // exactly what the crashing accessor does not do. So this asks upstream rather
            // than restating a rule about a field, and it costs one method call on an object
            // this function had already built.
            publicCalls: tx.numberOfPublicCalls(),
            // `withoutProof()` — AND IT IS WHAT THE NODE ITSELF SERVES, not a convenience.
            //
            // The file store keeps the transaction as it was submitted, chonk proof and all.
            // A node does not: EVERY `getTxByHash` answer captured from a live Aztec node in
            // this campaign carries `chonkProof: "AAAAAA=="` — the four-zero-byte empty
            // sentinel `ChonkProof.fromBuffer` short-circuits on — across all four committed
            // fixtures. So serving the proof would make this proxy's answer a DIFFERENT shape
            // from the one the driver has ever been given, and it breaks it outright: the
            // driver parses the reply with `Tx.schema`, whose `ChonkProof` branch reaches
            // `fromCompressedBytes` -> `BarretenbergSync.getSingleton()`, and the driver never
            // initialises that singleton. Measured: the first historic replay attempted
            // through this seam died with "First call BarretenbergSync.initSingleton()" while
            // decoding a body the store had served correctly.
            //
            // NOTHING IS LOST BY DROPPING IT. `Tx.computeTxHash` is over `data` alone, and
            // `Tx.schema` re-derives the hash through `Tx.create`, so the transaction the
            // driver receives still hashes to the key that was requested — which is asserted,
            // not assumed, by `bodySelftest`. The replay consumes `data` and
            // `publicFunctionCalldata`; `AvmTxHint.fromTx` never reads the proof. And this
            // pipeline does not verify proofs: it re-executes a settled transaction and
            // compares the effects it produces against the ones the chain published, which is
            // a stronger check than the proof would give it and is the only one it claims.
            json: JSON.parse(jsonStringify(tx.withoutProof())),
          };
          stats.bodiesServed++;
        } catch (e) {
          stats.bodyOutcomes.verified--;
          stats.bodyOutcomes.truncated++;
          entry = {
            outcome: 'truncated',
            reason: `The store returned ${got.bytes.length} bytes whose leading 32 are the key `
              + `that was requested, and Tx.fromBuffer could not decode the rest: `
              + `${e?.constructor?.name ?? 'Error'}: ${String(e?.message ?? e).split('\n')[0]}`,
            json: null,
          };
        }
      }
      bodies.set(key, entry);
      inflight.delete(key);
      return entry;
    })();
    inflight.set(key, p);
    return p;
  }

  // ── the forwarding half ──────────────────────────────────────────────────────────────

  /** POST a batch upstream, paced, with the throttle discipline. Returns the parsed array
   *  and the response headers, or `{ throttled: true }`. */
  async function postUpstream(requests) {
    if (minGapMs > 0) {
      const wait = lastCallAt + minGapMs - Date.now();
      if (wait > 0) await sleep(wait);
      lastCallAt = Date.now();
    }
    stats.upstreamBatches++;
    stats.upstreamCalls += requests.length;
    let sawThrottle = false;
    for (let attempt = 0; attempt < attempts; attempt++) {
      let limited = false;
      let retryAfterMs = 0;
      try {
        const r = await fetch(upstreamUrl, {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify(requests),
        });
        if (r.status === 429) {
          limited = true;
          const ra = Number(r.headers.get('retry-after'));
          if (Number.isFinite(ra) && ra > 0) retryAfterMs = ra * 1000;
        } else if (!r.ok) {
          stats.upstreamFaults++;
          await sleep(250 * (attempt + 1));
          continue;
        } else {
          const text = await r.text();
          let parsed;
          try {
            parsed = JSON.parse(text);
          } catch {
            stats.upstreamFaults++;
            await sleep(250 * (attempt + 1));
            continue;
          }
          // The endpoint also delivers its limit inside a 200, as a JSON-RPC error.
          const errs = (Array.isArray(parsed) ? parsed : [parsed])
            .map((x) => x?.error?.message).filter(Boolean);
          if (errs.some((m) => RATE_LIMIT_RE.test(m))) {
            limited = true;
          } else {
            return { response: parsed, headers: r.headers };
          }
        }
      } catch {
        stats.upstreamFaults++;
        if (attempt === attempts - 1) return { transport: true };
        await sleep(250 * (attempt + 1));
        continue;
      }
      if (limited) {
        stats.rateLimited++;
        sawThrottle = true;
        if (retryAfterMs > MAX_HONOURED_RETRY_AFTER_MS) {
          stats.retryAfterMs = Math.max(stats.retryAfterMs, retryAfterMs);
          stats.throttled = true;
          stats.throttledAt = new Date().toISOString();
          stats.throttledRetryAfterMs = retryAfterMs;
          log(`endpoint asked for ${Math.round(retryAfterMs / 1000)}s — stopping`);
          return { throttled: true };
        }
        const backoff = retryAfterMs > 0
          ? retryAfterMs
          : Math.min(60_000, 1000 * 2 ** attempt) * (0.75 + Math.random() * 0.5);
        stats.backoffMs += backoff;
        await sleep(backoff);
      }
    }
    if (sawThrottle) {
      stats.throttled = true;
      stats.throttledAt = new Date().toISOString();
      log('out of attempts while rate limited — stopping');
      return { throttled: true };
    }
    return { exhausted: true };
  }

  // ── the server ───────────────────────────────────────────────────────────────────────

  const server = createServer((req, res) => {
    let raw = '';
    req.on('data', (d) => { raw += d; });
    req.on('end', async () => {
      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: null,
          error: { code: -32700, message: 'proxy: body is not JSON' } }));
        return;
      }
      // Upstream's client always batches, so the body is an array. A single object is handled
      // anyway rather than refused: this proxy's contract is "a JSON-RPC endpoint", and a
      // shape assumption that happens to hold today is not a contract.
      const wasArray = Array.isArray(parsed);
      const requests = wasArray ? parsed : [parsed];

      const out = new Array(requests.length);
      const forward = [];
      const forwardAt = [];

      for (const [i, rq] of requests.entries()) {
        const key = `${rq?.method} ${JSON.stringify(rq?.params ?? [])}`;
        if (rq?.method === TX_BY_HASH) {
          const hash = String(rq?.params?.[0] ?? '');
          // eslint-disable-next-line no-await-in-loop
          const entry = await bodyAnswer(hash);
          out[i] = { jsonrpc: '2.0', id: rq.id, result: entry.json };
          continue;
        }
        if (CACHEABLE.has(rq?.method) && answers.has(key)) {
          stats.cacheHits++;
          out[i] = { jsonrpc: '2.0', id: rq.id, result: answers.get(key) };
          continue;
        }
        if (CACHEABLE.has(rq?.method)) stats.cacheMisses++;
        forward.push(rq);
        forwardAt.push(i);
      }

      let headers = null;
      if (forward.length > 0) {
        const got = await postUpstream(forward);
        if (got.throttled || got.transport || got.exhausted) {
          const message = got.throttled
            ? `proxy: the endpoint is rate-limiting this client`
            : 'proxy: the endpoint could not be reached';
          for (const [k, at] of forwardAt.entries()) {
            out[at] = { jsonrpc: '2.0', id: forward[k].id,
                        error: { code: -32000, message } };
          }
        } else {
          headers = got.headers;
          const list = Array.isArray(got.response) ? got.response : [got.response];
          for (const [k, at] of forwardAt.entries()) {
            const answer = list[k] ?? { jsonrpc: '2.0', id: forward[k].id,
              error: { code: -32000, message: 'proxy: upstream returned a short batch' } };
            out[at] = answer;
            if (CACHEABLE.has(forward[k].method)
                && Object.prototype.hasOwnProperty.call(answer, 'result')) {
              answers.set(`${forward[k].method} ${JSON.stringify(forward[k].params ?? [])}`,
                          answer.result);
            }
          }
        }
      }

      // THE VERSION HEADERS ARE FORWARDED, NOT INVENTED. `createReplayNodeClient` reads
      // `x-aztec-*` off every response and upstream's `getVersioningResponseHandler` compares
      // them to the pin. A proxy that dropped them would make every reply pass the version
      // check in silence — upstream skips a field whose header is absent — so a protocol
      // mismatch would be invisible for exactly the replays this seam exists to enable.
      const outHeaders = { 'content-type': 'application/json' };
      if (headers) {
        for (const [k, v] of headers.entries()) {
          if (k.toLowerCase().startsWith('x-aztec-')) outHeaders[k] = v;
        }
      }
      res.writeHead(200, outHeaders);
      res.end(JSON.stringify(wasArray ? out : out[0]));
    });
  });

  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  const url = `http://127.0.0.1:${port}`;
  log(`serving ${url} -> ${upstreamUrl} (bodies from ${storeBase}/${storeBasePath}/txs/)`);

  return {
    url,
    stats,
    /** Whether the endpoint has refused past the honoured wait. The caller MUST stop. */
    get throttled() { return stats.throttled; },
    /**
     * What the store says about one transaction, WITHOUT the driver being spawned.
     *
     * The caller uses this to decide before it spends anything: a body the store does not
     * hold and a transaction with no public execution are both answerable from here, and
     * both would otherwise cost a process, ~15 node calls and — for the second — a crash
     * that has to be interpreted. The body is decoded once either way and cached, so asking
     * costs nothing that the replay would not have spent a moment later.
     *
     * @returns {Promise<{outcome: string, reason: string, publicCalls: number|null}>}
     */
    inspect: async (hash) => {
      const e = await bodyAnswer(hash);
      return { outcome: e.outcome, reason: e.reason, publicCalls: e.publicCalls ?? null };
    },
    close: () => new Promise((r) => server.close(r)),
  };
}
