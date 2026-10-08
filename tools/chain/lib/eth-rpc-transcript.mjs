// eth-rpc-transcript.mjs — a JSON-RPC endpoint that is a FILE, and the recorder that
// writes it.
//
// ── WHAT PROBLEM THIS SOLVES ──────────────────────────────────────────────────────────
//
// `codetracer-evm-recorder trace-onchain` and `tools/chain/produce-eth-snapshot.mjs` both
// read Ethereum mainnet through one JSON-RPC endpoint. That makes the Ethereum capture a
// measurement of somebody else's uptime: it cannot run in a hermetic `nix build`, it cannot
// run in CI, and it cannot be re-run in two years to check that a change to the producers
// did not move the result. The obvious fix — commit the container the capture produced — is
// what the `.ct` ban refuses, and rightly: a committed recording pins a recorder version
// nothing tracks, and derived bytes churn. `fixtures/chain-health/readable-container`
// already demonstrated that from the other side (regenerating it moved `containerBytes`
// 151,552 -> 77,824 across two container versions while not one checked fact moved).
//
// What CAN be committed is the INPUT: a transaction body, a block header, and the account /
// storage / code state a replay reads are immutable facts about a finalised block. They do
// not churn, because the chain they describe cannot change. So this module makes the whole
// JSON-RPC conversation a committed artifact:
//
//   * RECORD mode proxies to a real endpoint and writes every distinct (method, params)
//     answer to a file.
//   * REPLAY mode serves those files and NOTHING ELSE. A call the transcript does not hold
//     is a MISS: it is answered with an error that says so, and the server's exit status
//     reports it. There is no fall-through to the network, by construction — replay mode
//     never constructs an upstream client at all.
//   * DENY mode refuses every call. It exists so "the producer needs the transcript" is a
//     reading rather than an assumption: a producer that still succeeds against DENY was
//     never reading the endpoint.
//
// ── WHY (method, params) AND NOT A SEQUENCE ───────────────────────────────────────────
//
// The recorder's state reads come from `foundry-fork-db`'s `SharedBackend`, which services
// database misses from a background thread and issues them CONCURRENTLY. The order of
// `eth_getStorageAt` calls is therefore not stable between two runs of the same replay, so a
// positional transcript would mismatch on a run that was otherwise identical. A keyed
// transcript is order-free: it answers what was asked, whenever it is asked, as many times
// as it is asked.
//
// The key is `method` plus the params, canonicalised by lowercasing every string in them.
// Case is the one axis on which two spellings of the SAME Ethereum request differ —
// EIP-55-checksummed and lowercase addresses, `0xA` and `0xa` quantities — and two clients
// in this pipeline do differ there (alloy checksums; the producer lowercases on purpose).
// Nothing else is normalised: a transcript that rewrote a request would stop being a record
// of what was asked.
//
// ── WHAT IS NOT IMMUTABLE, AND IS MARKED ──────────────────────────────────────────────
//
// Two of the producer's reads are about the chain's TIP, not about the captured block:
// `eth_blockNumber` and `eth_getBlockByNumber ['finalized', ...]`. Their answers were true
// when recorded and are false now. They are recorded like everything else — the producer
// needs an answer — but the manifest marks them `tipDependent: true` so a reader is told,
// rather than discovering it. See `TIP_DEPENDENT_METHODS` below.

import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

/** Transcript format version. Bumped when the on-disk shape changes. */
export const TRANSCRIPT_VERSION = 1;

/**
 * The calls whose answer describes the chain's tip rather than the captured block.
 *
 * `eth_getBlockByNumber` is tip-dependent only for the tags; the same method with a numeric
 * height is immutable, so the classification is per CALL and not per method —
 * `classifyCall` is what decides, and it is exported so the selftest can hold it to both
 * halves of that distinction.
 */
export const TIP_DEPENDENT_METHODS = new Set(['eth_blockNumber', 'eth_syncing']);

/** Block tags whose meaning moves with the chain. */
export const MOVING_BLOCK_TAGS = new Set(['latest', 'pending', 'safe', 'finalized']);

/**
 * `immutable` | `tip-dependent` | `endpoint-identity` — what KIND of fact one answer is.
 *
 * `endpoint-identity` is `web3_clientVersion` and the blind-proxy control: the answer is
 * about the endpoint that was asked, not about the chain at all, so re-recording it against
 * a different endpoint legitimately changes it.
 */
export function classifyCall(method, params) {
  if (method === 'web3_clientVersion' || method === 'thisMethodDoesNotExist') {
    return 'endpoint-identity';
  }
  if (TIP_DEPENDENT_METHODS.has(method)) return 'tip-dependent';
  for (const p of params ?? []) {
    if (typeof p === 'string' && MOVING_BLOCK_TAGS.has(p.toLowerCase())) return 'tip-dependent';
  }
  return 'immutable';
}

/**
 * Canonicalise params for keying: lowercase every string, recursively, and leave every
 * other JSON type alone.
 *
 * NOT a rewrite of the request — the stored `params` are the ones that were sent. This is
 * only how two spellings of one request are recognised as one request.
 */
export function canonicaliseParams(params) {
  const walk = (v) => {
    if (typeof v === 'string') return v.toLowerCase();
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === 'object') {
      const out = {};
      for (const k of Object.keys(v).sort()) out[k] = walk(v[k]);
      return out;
    }
    return v;
  };
  return walk(params ?? []);
}

/** The transcript key for one call. */
export function callKey(method, params) {
  const canonical = `${method}\n${JSON.stringify(canonicaliseParams(params))}`;
  return createHash('sha256').update(canonical).digest('hex').slice(0, 32);
}

/** A filesystem-safe, human-readable file name for one call. */
function callFileName(method, params, key) {
  const hint = (params ?? [])
    .map((p) => (typeof p === 'string' ? p.replace(/[^0-9a-zA-Z]/g, '').slice(0, 12) : String(p)))
    .join('-')
    .slice(0, 40);
  return `${method}${hint ? `.${hint}` : ''}.${key.slice(0, 8)}.json`;
}

// ---------------------------------------------------------------------------
// reading a transcript
// ---------------------------------------------------------------------------

/**
 * Load a transcript directory into `{ manifest, byKey }`.
 *
 * Every entry's stored bytes are hashed and checked against the manifest's `sha256`. A
 * transcript whose files and manifest disagree is REFUSED rather than loaded: the whole
 * point of committing the inputs is that the bytes are what the manifest says, and a
 * replay served from a file nobody can attribute is not reproducible.
 */
export function loadTranscript(dir) {
  const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'));
  if (manifest.version !== TRANSCRIPT_VERSION) {
    throw new Error(
      `transcript at ${dir} is version ${manifest.version}; this reader speaks `
      + `${TRANSCRIPT_VERSION}`);
  }
  const byKey = new Map();
  for (const entry of manifest.calls) {
    const path = join(dir, 'calls', entry.file);
    const bytes = readFileSync(path);
    const sha = createHash('sha256').update(bytes).digest('hex');
    if (sha !== entry.sha256) {
      throw new Error(
        `transcript entry ${entry.file} hashes ${sha} and the manifest says `
        + `${entry.sha256} — the committed inputs and their manifest disagree`);
    }
    const stored = JSON.parse(bytes.toString('utf8'));
    const key = callKey(stored.method, stored.params);
    if (key !== entry.key) {
      throw new Error(
        `transcript entry ${entry.file} holds ${stored.method} keyed ${key} and the `
        + `manifest filed it under ${entry.key}`);
    }
    byKey.set(key, stored);
  }
  return { manifest, byKey };
}

/** Every `calls/` file present on disk, whether or not the manifest lists it. */
export function callFilesOnDisk(dir) {
  try {
    return readdirSync(join(dir, 'calls')).filter((n) => n.endsWith('.json')).sort();
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// the server
// ---------------------------------------------------------------------------

/**
 * Start a JSON-RPC server on 127.0.0.1 in one of three modes.
 *
 * `mode: 'record'` — proxy to `upstream`, remember every answer.
 * `mode: 'replay'` — answer from `transcript` (a `loadTranscript` result) and from nothing
 *                    else. No upstream is constructed.
 * `mode: 'deny'`   — refuse every call.
 *
 * Returns `{ url, port, stats, close }`. `stats` accumulates:
 *   `served`  — calls answered from the transcript (replay) or forwarded (record)
 *   `misses`  — calls the transcript does not hold, as `[{method, params}]`
 *   `denied`  — calls refused (deny mode)
 */
export async function startTranscriptServer(options) {
  const { mode } = options;
  const stats = { served: 0, forwarded: 0, misses: [], denied: 0, hits: new Map() };
  const recorded = new Map();

  /** Answer ONE JSON-RPC request object. Returns the response envelope. */
  const answerOne = async (req) => {
    const { id, method, params } = req;
    const key = callKey(method, params ?? []);

    if (mode === 'deny') {
      stats.denied += 1;
      return {
        jsonrpc: '2.0',
        id,
        error: {
          code: -32000,
          message:
            `eth-rpc-transcript is in DENY mode: ${method} was refused. This endpoint `
            + `exists to prove a producer reads the endpoint at all.`,
        },
      };
    }

    if (mode === 'replay') {
      const stored = options.transcript.byKey.get(key);
      if (!stored) {
        stats.misses.push({ method, params: params ?? [], key });
        return {
          jsonrpc: '2.0',
          id,
          error: {
            code: -32000,
            message:
              `eth-rpc-transcript MISS: the committed transcript holds no answer for `
              + `${method} ${JSON.stringify(params ?? [])} (key ${key}). The transcript is `
              + `the whole input set; a miss means the input set is incomplete, not that `
              + `the endpoint is down.`,
          },
        };
      }
      stats.served += 1;
      stats.hits.set(key, (stats.hits.get(key) ?? 0) + 1);
      // The stored envelope verbatim, re-`id`ed to the caller's request. `id` is the
      // caller's correlation token and nothing else; echoing the recorded one would
      // break any client that multiplexes.
      const out = { jsonrpc: '2.0', id };
      if ('error' in stored.response) out.error = stored.response.error;
      else out.result = stored.response.result;
      return out;
    }

    // record
    const res = await fetch(options.upstream, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params: params ?? [] }),
    });
    const text = await res.text();
    let body = null;
    try { body = JSON.parse(text); } catch { /* reported as itself below */ }
    stats.forwarded += 1;

    // An answer is recorded once. A retried call (the producers both retry a throttled
    // read up to 12 times) must not overwrite a good answer with a later refusal, and a
    // transcript that recorded the refusal would replay the refusal forever. So: only an
    // answer with a `result` is stored, and only the FIRST one — except for the calls whose
    // whole purpose is to elicit an error (the blind-proxy control), where the error IS the
    // answer and there is nothing else to keep.
    const envelope = body && typeof body === 'object' ? body : { error: { code: -32603, message: text.slice(0, 400) } };
    const isResult = envelope && envelope.result !== undefined;
    const existing = recorded.get(key);
    if (!existing || (isResult && existing.response.result === undefined)) {
      recorded.set(key, {
        method,
        params: params ?? [],
        kind: classifyCall(method, params ?? []),
        http: res.status,
        response: envelope.result !== undefined
          ? { result: envelope.result }
          : { error: envelope.error ?? { code: -32603, message: text.slice(0, 400) } },
      });
    }
    const out = { jsonrpc: '2.0', id };
    if (envelope.result !== undefined) out.result = envelope.result;
    else out.error = envelope.error ?? { code: -32603, message: text.slice(0, 400) };
    return out;
  };

  const server = createServer((req, res) => {
    if (req.method !== 'POST') {
      res.writeHead(405, { 'content-type': 'text/plain' });
      res.end('eth-rpc-transcript speaks JSON-RPC over POST only\n');
      return;
    }
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', async () => {
      let payload;
      try {
        payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      } catch (e) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: String(e) } }));
        return;
      }
      try {
        // A JSON-RPC batch is an array, and alloy sends them. Each member is keyed and
        // answered independently, which is the whole reason the transcript is keyed.
        const answer = Array.isArray(payload)
          ? await Promise.all(payload.map(answerOne))
          : await answerOne(payload);
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify(answer));
      } catch (e) {
        res.writeHead(500, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          jsonrpc: '2.0',
          id: Array.isArray(payload) ? null : payload.id,
          error: { code: -32603, message: `eth-rpc-transcript failed: ${e}` },
        }));
      }
    });
  });

  await new Promise((done) => server.listen(options.port ?? 0, '127.0.0.1', done));
  const port = server.address().port;

  return {
    port,
    url: `http://127.0.0.1:${port}`,
    stats,
    /** The calls recorded so far, for `writeTranscript`. */
    recorded,
    close: () => new Promise((done) => server.close(done)),
  };
}

/**
 * Write a recorded conversation to `dir` as a transcript.
 *
 * One file per distinct call, named after the method and a prefix of its key so the
 * directory listing reads as the conversation it is. The manifest carries each file's
 * sha256, which is what `loadTranscript` checks — the committed bytes are the inputs, and
 * a manifest that did not pin them would make the files replaceable.
 */
export function writeTranscript(dir, recorded, meta) {
  mkdirSync(join(dir, 'calls'), { recursive: true });
  const calls = [];
  for (const [key, stored] of [...recorded.entries()].sort((a, b) => {
    const m = a[1].method.localeCompare(b[1].method);
    return m !== 0 ? m : a[0].localeCompare(b[0]);
  })) {
    const file = callFileName(stored.method, stored.params, key);
    // Minified, which is how the endpoint sent it: a pretty-printed mainnet block is
    // several times the size for no added legibility (the values are hex strings).
    const bytes = Buffer.from(`${JSON.stringify(stored)}\n`, 'utf8');
    writeFileSync(join(dir, 'calls', file), bytes);
    calls.push({
      key,
      method: stored.method,
      params: stored.params,
      kind: stored.kind,
      file,
      bytes: bytes.length,
      sha256: createHash('sha256').update(bytes).digest('hex'),
    });
  }
  const manifest = {
    version: TRANSCRIPT_VERSION,
    ...meta,
    totals: {
      calls: calls.length,
      bytes: calls.reduce((n, c) => n + c.bytes, 0),
      immutable: calls.filter((c) => c.kind === 'immutable').length,
      tipDependent: calls.filter((c) => c.kind === 'tip-dependent').length,
      endpointIdentity: calls.filter((c) => c.kind === 'endpoint-identity').length,
    },
    calls,
  };
  writeFileSync(join(dir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
  return manifest;
}
