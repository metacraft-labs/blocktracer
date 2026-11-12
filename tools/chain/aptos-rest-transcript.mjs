#!/usr/bin/env node
// aptos-rest-transcript.mjs — an Aptos REST endpoint that is a DIRECTORY, and the recorder
// that writes it.
//
// The Aptos twin of `sui-graphql-transcript.mjs` (a concrete duplicate, per ING-7), for the
// same reason: an Aptos capture reads the network four times — `capture-aptos-range.mjs`
// reads blocks and their transactions, `aptos move replay --network <url>` reads the
// transaction and every state value it touches at the version before it, the recorder reads
// each entered module's bytecode at that version, and `lib/aptos-source.mjs` reads each
// entered account's package registry (its published source) there too — and a build that
// must reproduce its output cannot depend on somebody else's uptime. What a committed
// version says cannot change, so the whole REST conversation is committed as INPUT and
// served back.
//
//   record   proxy to `--upstream`, write one file per distinct request
//   replay   serve the directory and nothing else; a request it does not hold is a MISS,
//            answered 599 with a body naming it, and counted
//
//   node tools/chain/aptos-rest-transcript.mjs record --dir D --upstream URL [--port P]
//   node tools/chain/aptos-rest-transcript.mjs replay --dir D [--port P]
//
// ── THE KEY ───────────────────────────────────────────────────────────────────────────
//
// A request is keyed by its method, its path WITH the query string exactly as sent, its
// `Accept` header (the REST API answers one path in JSON or in BCS, and `aptos move replay`
// asks for BCS) and the SHA-256 of its body (a raw state-value read is a POST whose body is
// the BCS state key). Nothing else is normalised.
//
// ── WHAT A RECORD HOLDS, AND WHY THE BODY IS COMPRESSED ───────────────────────────────
//
// `calls/<hint>.<key>.json`: the request, the status, the response's `content-type` and
// its `x-aptos-*` headers (the REST client reads the chain id and ledger version from them
// and refuses a response without them) except the node's current encryption key, and the
// NAME of the body. Bodies live once each under `bodies/<sha256 of the body>`, gzipped and
// base64-encoded: a block with its transactions is ~70–500 KB of JSON, a module is its
// bytecode in hex beside its whole ABI, and the same module is answered at every version a
// window's transactions read it at. Measured on the committed window: 551 calls, 268
// distinct bodies, 7.5 MB inline and 2.1 MB content-addressed — 0.77 MB of it the framework's
// package registry (its published source, read at each transaction's V−1 and stored once,
// in BCS). Compression is deterministic (no mtime), so a re-recorded identical answer is
// byte-identical.
//
// ── WHAT IS KEPT ──────────────────────────────────────────────────────────────────────
//
// 2xx answers and 404s. A 404 from a state read at a version is a FACT — the resource did
// not exist then — and the replay depends on hearing it again. A 429 or a 5xx is a fact
// about the run and is never kept: in record mode a 429 is WAITED OUT and retried (the
// public fullnode allows an anonymous IP 40,000 compute units per 300 s), so the client
// behind the proxy never sees the rate limit, and requests are spaced by `--min-gap-ms`.
//
// ── WHAT IS NOT IMMUTABLE, AND IS MARKED ──────────────────────────────────────────────
//
// `GET /v1` (ledger info) asks about the TIP. Its answer was true when recorded and is not
// now; it is recorded like any other, and the manifest marks it `tipDependent`. So is every
// response's `x-aptos-ledger-version` header, which no capture reads.

import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { gunzipSync, gzipSync } from 'node:zlib';

export const TRANSCRIPT_FORMAT = 'blocktracer/aptos-rest-transcript@1';

const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

/** The request's key, and a short human hint for the file name. */
export function requestKey({ method, path, accept = '', body = Buffer.alloc(0) }) {
  const bodySha = createHash('sha256').update(body).digest('hex');
  const material = JSON.stringify([method.toUpperCase(), path, accept, bodySha]);
  const key = createHash('sha256').update(material).digest('hex').slice(0, 16);
  const segs = path.split('?')[0].split('/').filter(Boolean).filter((s) => s !== 'v1');
  const words = segs.filter((s) => !/^(0x)?[0-9a-f]{8,}$/i.test(s) && !/^\d+$/.test(s));
  const hint = `${method.toLowerCase()}.${words.slice(0, 4).join('.') || 'root'}`
    .replace(/[^\w.-]/g, '').slice(0, 48);
  return { key, hint, bodySha };
}

/** A request about the tip: ledger info, with no version in it. */
export function isTipDependent(path) {
  return /^\/v1\/?(\?.*)?$/.test(path);
}

/** Response headers worth keeping: the body's type and the chain's own `x-aptos-*`. */
export function keptHeaders(headers) {
  const out = {};
  for (const [k, v] of headers) {
    const name = k.toLowerCase();
    // `x-aptos-txn-encryption-key` is the node's CURRENT encryption key, ~330 hex digits on
    // every answer: it says nothing about the version asked for, no reader here needs it,
    // and it was a fifth of a window's transcript.
    if (name === 'x-aptos-txn-encryption-key') continue;
    if (name === 'content-type' || name.startsWith('x-aptos-')) out[name] = v;
  }
  return Object.fromEntries(Object.entries(out).sort(([a], [b]) => (a < b ? -1 : 1)));
}

/** Write a body under `bodies/<sha256 of the body>` (gzip, base64) and return the name. */
export function storeBody(dir, buf) {
  const name = createHash('sha256').update(buf).digest('hex');
  const p = join(dir, 'bodies', name);
  mkdirSync(join(dir, 'bodies'), { recursive: true });
  if (!existsSync(p)) writeFileSync(p, `${encodeBody(buf)}\n`);
  return name;
}

export function encodeBody(buf) {
  return gzipSync(buf, { level: 9 }).toString('base64');
}
export function decodeBody(text) {
  return gunzipSync(Buffer.from(text.trim(), 'base64'));
}

function loadDir(dir) {
  const calls = new Map();
  const d = join(dir, 'calls');
  if (!existsSync(d)) return calls;
  for (const f of readdirSync(d)) {
    if (!f.endsWith('.json')) continue;
    const rec = JSON.parse(readFileSync(join(d, f), 'utf8'));
    calls.set(rec.key, rec);
  }
  return calls;
}

/** Start the server; resolves to `{url, close, misses}` once it is listening. */
export async function startTranscriptServer({ mode, dir, upstream = null, port = 0,
                                              minGapMs = 250, fetchImpl = fetch,
                                              log = () => {} }) {
  if (mode !== 'record' && mode !== 'replay') throw new Error('mode must be record or replay');
  if (mode === 'record' && !upstream) throw new Error('record mode needs --upstream');
  mkdirSync(join(dir, 'calls'), { recursive: true });
  const calls = loadDir(dir);
  let misses = 0;
  const hits = new Set();
  let upstreamRequests = 0;
  let waited429 = 0;
  // ONE upstream request at a time, spaced: the rate limit is per IP and per window, and a
  // burst that trips it costs a whole window of waiting.
  let gate = Promise.resolve();
  let last = 0;
  const throttled = (fn) => {
    const run = gate.then(async () => {
      const gap = last + minGapMs - Date.now();
      if (gap > 0) await sleep(gap);
      try { return await fn(); } finally { last = Date.now(); }
    });
    gate = run.catch(() => {});
    return run;
  };
  const askUpstream = async (method, path, accept, contentType, body) => {
    for (let attempt = 0; ; attempt++) {
      let res;
      let buf;
      try {
        res = await throttled(() => {
          upstreamRequests++;
          return fetchImpl(`${upstream.replace(/\/$/, '')}${path}`, {
            method,
            headers: { ...(accept ? { accept } : {}),
                       ...(contentType ? { 'content-type': contentType } : {}) },
            body: method === 'GET' || method === 'HEAD' ? undefined : body,
          });
        });
        buf = Buffer.from(await res.arrayBuffer());
      } catch (e) {
        // A transport failure (reset, TLS, timeout) says nothing about the chain. It is
        // retried like a 5xx; passing it through would hand the replay a failed state
        // read, which `aptos move replay` turns into a STORAGE_ERROR and a false
        // divergence — measured, on version 7881330401, before this retry existed.
        if (attempt < 20) {
          log(`upstream transport failure on ${method} ${path}: ${e.message}; retrying`);
          await sleep(5_000 * (attempt + 1));
          continue;
        }
        throw e;
      }
      if ((res.status === 429 || res.status >= 500) && attempt < 20) {
        const ra = Number(res.headers.get('retry-after'));
        const wait = res.status === 429 ? (Number.isFinite(ra) && ra > 0 ? ra * 1000 : 30_000)
          : 5_000 * (attempt + 1);
        if (res.status === 429) waited429++;
        log(`upstream ${res.status} on ${method} ${path}; waiting ${wait} ms (attempt ${attempt + 1})`);
        await sleep(wait);
        continue;
      }
      return { status: res.status, headers: keptHeaders(res.headers), body: buf };
    }
  };

  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', async () => {
      const body = Buffer.concat(chunks);
      const method = req.method.toUpperCase();
      const path = req.url;
      const accept = req.headers.accept ?? '';
      const { key, hint, bodySha } = requestKey({ method, path, accept, body });
      const send = (status, headers, payload) => {
        res.writeHead(status, headers);
        res.end(payload);
      };
      if (calls.has(key)) {
        hits.add(key);
        const r = calls.get(key);
        send(r.status, r.headers, decodeBody(readFileSync(join(dir, 'bodies', r.body), 'utf8')));
        return;
      }
      if (mode === 'replay') {
        misses++;
        log(`MISS ${method} ${path} (accept ${accept || '-'}, key ${key})`
          + (body.length > 0 ? ` body ${body.toString('utf8').slice(0, 300)}` : ''));
        send(599, { 'content-type': 'text/plain' }, `transcript MISS: no recorded answer for `
          + `${method} ${path} (accept ${accept || '-'}, key ${key}); replay mode never reaches `
          + 'the network');
        return;
      }
      try {
        const up = await askUpstream(method, path, accept, req.headers['content-type'], body);
        // Kept: answers that are facts about the chain (see the header).
        if ((up.status >= 200 && up.status < 300) || up.status === 404) {
          const rec = {
            key,
            request: { method, path, accept, bodySha256: bodySha,
                       ...(body.length > 0 ? { body: body.toString('base64') } : {}) },
            tipDependent: isTipDependent(path),
            status: up.status,
            headers: up.headers,
            // CONTENT-ADDRESSED: the body is stored once under its own SHA-256, because the
            // same module is answered at every version a window's transactions read it at.
            body: storeBody(dir, up.body),
          };
          writeFileSync(join(dir, 'calls', `${hint}.${key}.json`), `${JSON.stringify(rec)}\n`);
          calls.set(key, rec);
        } else {
          log(`not kept: ${up.status} on ${method} ${path}: ${up.body.toString('utf8').slice(0, 300)}`);
        }
        send(up.status, up.headers, up.body);
      } catch (e) {
        log(`upstream FAILED for ${method} ${path}: ${e.message}`);
        send(502, { 'content-type': 'text/plain' }, `upstream failed: ${e.message}`);
      }
    });
  });
  await new Promise((ok) => server.listen(port, '127.0.0.1', ok));
  const url = `http://127.0.0.1:${server.address().port}`;
  const close = () => new Promise((ok) => {
    server.closeAllConnections?.();
    server.close(() => {
      if (mode === 'record') writeManifest(dir, upstream);
      ok({ misses, calls: calls.size, upstreamRequests, waited429, hits });
    });
  });
  return { url, close, misses: () => misses };
}

/**
 * Delete every call file whose request was not asked in a run, and rewrite the manifest.
 * A record run keeps every answer it was given, including those of attempts that were
 * retried; a replay of the finished capture asks for exactly what the tree needs, and that
 * is the set worth committing. Returns how many files were removed.
 */
export function pruneTranscript(dir, hits) {
  const d = join(dir, 'calls');
  const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'));
  let removed = 0;
  for (const f of readdirSync(d)) {
    if (!f.endsWith('.json')) continue;
    const rec = JSON.parse(readFileSync(join(d, f), 'utf8'));
    if (!hits.has(rec.key)) { rmSync(join(d, f)); removed++; }
  }
  // …and every body no remaining call names.
  const named = new Set(readdirSync(d).filter((f) => f.endsWith('.json'))
    .map((f) => JSON.parse(readFileSync(join(d, f), 'utf8')).body));
  const b = join(dir, 'bodies');
  for (const f of existsSync(b) ? readdirSync(b) : []) if (!named.has(f)) rmSync(join(b, f));
  writeManifest(dir, manifest.upstream);
  return removed;
}

/** `manifest.json`: every call file with its sha256, and which ones ask about the tip. */
export function writeManifest(dir, upstream) {
  const d = join(dir, 'calls');
  const rows = readdirSync(d).filter((f) => f.endsWith('.json')).sort().map((f) => {
    const bytes = readFileSync(join(d, f));
    const rec = JSON.parse(bytes.toString('utf8'));
    return { file: `calls/${f}`, sha256: createHash('sha256').update(bytes).digest('hex'),
             tipDependent: rec.tipDependent === true };
  });
  // Bodies are named by the SHA-256 of their decoded bytes, so each verifies itself; the
  // manifest counts them rather than hashing them twice.
  const b = join(dir, 'bodies');
  const bodies = existsSync(b) ? readdirSync(b).length : 0;
  writeFileSync(join(dir, 'manifest.json'), `${JSON.stringify({ format: TRANSCRIPT_FORMAT,
    upstream, calls: rows.length, bodies,
    tipDependent: rows.filter((r) => r.tipDependent).length, files: rows }, null, 1)}\n`);
}

async function main(argv) {
  const [mode, ...rest] = argv;
  const get = (n) => { const i = rest.indexOf(`--${n}`); return i === -1 ? undefined : rest[i + 1]; };
  const dir = get('dir');
  if (!dir) {
    console.error('usage: record|replay --dir D [--upstream URL] [--port P] [--min-gap-ms MS]');
    process.exit(2);
  }
  const srv = await startTranscriptServer({ mode, dir, upstream: get('upstream'),
    port: Number(get('port') ?? 0), minGapMs: Number(get('min-gap-ms') ?? 250),
    log: (m) => console.error(m) });
  console.log(`listening ${srv.url}`);
  const stop = async () => {
    const { misses, calls } = await srv.close();
    console.error(`${mode}: ${calls} call(s) in the transcript, ${misses} miss(es)`);
    process.exit(misses > 0 ? 1 : 0);
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

if (process.argv[1]?.endsWith('aptos-rest-transcript.mjs')) {
  main(process.argv.slice(2)).catch((e) => { console.error(e.message); process.exit(1); });
}
