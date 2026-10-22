#!/usr/bin/env node
// sui-graphql-transcript.mjs — a Sui GraphQL endpoint that is a DIRECTORY, and the
// recorder that writes it.
//
// The Sui twin of `eth-rpc-transcript.mjs` (a concrete duplicate, per ING-7), for the
// same reason: a Sui capture reads the network twice — `capture-sui-range.mjs` reads
// checkpoints and effects, and `sui replay --trace --node <url>` reads the transaction and
// the exact object versions it consumed — and a build that must reproduce its output
// cannot depend on somebody else's uptime. What a finalised checkpoint says cannot
// change, so the whole GraphQL conversation is committed as INPUT and served back.
//
//   record   proxy to `--upstream`, write one file per distinct request
//   replay   serve the directory and nothing else; a request it does not hold is a MISS,
//            answered with a GraphQL error naming it, and counted
//
//   node tools/chain/sui-graphql-transcript.mjs record --dir D --upstream URL [--port P]
//   node tools/chain/sui-graphql-transcript.mjs replay --dir D [--port P]
//
// The server prints `listening <url>` once it accepts connections, and writes
// `manifest.json` (record) or a miss count (replay) on SIGTERM / SIGINT.
//
// ── THE KEY ───────────────────────────────────────────────────────────────────────────
//
// A request is keyed by its `query` (whitespace-collapsed), its `variables` (canonical:
// keys sorted) and its `operationName`. Nothing else is normalised: a transcript that
// rewrote a request would stop being a record of what was asked. Order is not part of
// the key, so concurrent requests from `sui replay` answer the same in any order.
//
// ── WHAT IS NOT IMMUTABLE, AND IS MARKED ──────────────────────────────────────────────
//
// A query without an explicit sequence number (`checkpoint { … }`, `epoch { … }`) asks
// about the TIP. Its answer was true when recorded and is not now; it is recorded like any
// other, because the capture needs an answer, and the manifest marks it `tipDependent`.

import { createHash } from 'node:crypto';
import { createServer } from 'node:http';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export const TRANSCRIPT_FORMAT = 'blocktracer/sui-graphql-transcript@1';

/** Canonical JSON: object keys sorted, recursively. */
function canonical(v) {
  if (Array.isArray(v)) return `[${v.map(canonical).join(',')}]`;
  if (v && typeof v === 'object') {
    return `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canonical(v[k])}`).join(',')}}`;
  }
  return JSON.stringify(v);
}

/** The request's key, and a short human hint for the file name. */
export function requestKey(body) {
  const query = String(body?.query ?? '').replace(/\s+/g, ' ').trim();
  const material = canonical({ query, variables: body?.variables ?? {},
                               operationName: body?.operationName ?? null });
  const key = createHash('sha256').update(material).digest('hex').slice(0, 16);
  const hint = (query.match(/^\s*(?:query\s+)?(\w+)?\s*(?:\([^)]*\))?\s*\{\s*(\w+)/) ?? [])
    .slice(1).filter(Boolean).join('.') || 'query';
  return { key, hint: hint.replace(/[^\w.]/g, '').slice(0, 40) };
}

/** A query about the tip: a root `checkpoint`/`epoch` field with no argument. */
export function isTipDependent(body) {
  const q = String(body?.query ?? '');
  return /\{\s*(checkpoint|epoch)\s*\{/.test(q.replace(/\s+/g, ' '));
}

function loadDir(dir) {
  const calls = new Map();
  const d = join(dir, 'calls');
  if (!existsSync(d)) return calls;
  for (const f of readdirSync(d)) {
    if (!f.endsWith('.json')) continue;
    const rec = JSON.parse(readFileSync(join(d, f), 'utf8'));
    calls.set(requestKey(rec.request).key, rec);
  }
  return calls;
}

/** Start the server; resolves to `{url, close}` once it is listening. */
export async function startTranscriptServer({ mode, dir, upstream = null, port = 0,
                                              fetchImpl = fetch }) {
  if (mode !== 'record' && mode !== 'replay') throw new Error(`mode must be record or replay`);
  if (mode === 'record' && !upstream) throw new Error('record mode needs --upstream');
  mkdirSync(join(dir, 'calls'), { recursive: true });
  const calls = loadDir(dir);
  let misses = 0;
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', async () => {
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); }
      catch { body = {}; }
      const { key, hint } = requestKey(body);
      const send = (status, payload) => {
        res.writeHead(status, { 'content-type': 'application/json' });
        res.end(typeof payload === 'string' ? payload : JSON.stringify(payload));
      };
      if (calls.has(key)) { const r = calls.get(key); send(r.http, r.response); return; }
      if (mode === 'replay') {
        misses++;
        send(200, { errors: [{ message: `transcript MISS: no recorded answer for request `
          + `${key} (${hint}); replay mode never reaches the network` }] });
        return;
      }
      try {
        const up = await fetchImpl(upstream, { method: 'POST',
          headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
        const text = await up.text();
        let response;
        try { response = JSON.parse(text); } catch { response = text; }
        const rec = { request: body, http: up.status, tipDependent: isTipDependent(body),
                      response };
        // Only successful answers are kept: a transient upstream failure is not a fact
        // about the chain, and replaying it would make the build fail for no reason.
        if (up.status === 200 && !response?.errors) {
          writeFileSync(join(dir, 'calls', `${hint}.${key}.json`), `${JSON.stringify(rec)}\n`);
          calls.set(key, rec);
        }
        send(up.status, text);
      } catch (e) {
        send(502, { errors: [{ message: `upstream failed: ${e.message}` }] });
      }
    });
  });
  await new Promise((ok) => server.listen(port, '127.0.0.1', ok));
  const url = `http://127.0.0.1:${server.address().port}/graphql`;
  const close = () => new Promise((ok) => server.close(() => {
    if (mode === 'record') writeManifest(dir, upstream);
    ok({ misses, calls: calls.size });
  }));
  return { url, close, misses: () => misses };
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
  writeFileSync(join(dir, 'manifest.json'), `${JSON.stringify({ format: TRANSCRIPT_FORMAT,
    upstream, calls: rows.length, tipDependent: rows.filter((r) => r.tipDependent).length,
    files: rows }, null, 1)}\n`);
}

async function main(argv) {
  const [mode, ...rest] = argv;
  const get = (n) => { const i = rest.indexOf(`--${n}`); return i === -1 ? undefined : rest[i + 1]; };
  const dir = get('dir');
  if (!dir) { console.error('usage: record|replay --dir D [--upstream URL] [--port P]'); process.exit(2); }
  const srv = await startTranscriptServer({ mode, dir, upstream: get('upstream'),
                                            port: Number(get('port') ?? 0) });
  console.log(`listening ${srv.url}`);
  const stop = async () => {
    const { misses, calls } = await srv.close();
    console.error(`${mode}: ${calls} call(s) in the transcript, ${misses} miss(es)`);
    process.exit(misses > 0 ? 1 : 0);
  };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
}

if (process.argv[1]?.endsWith('sui-graphql-transcript.mjs')) {
  main(process.argv.slice(2)).catch((e) => { console.error(e.message); process.exit(1); });
}
