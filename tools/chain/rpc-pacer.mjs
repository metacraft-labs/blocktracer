#!/usr/bin/env node
// rpc-pacer.mjs — a loopback JSON-RPC proxy that paces requests to rate-limited upstreams and
// retries the answers that mean "slow down" (HTTP 429, -32005, eRPC failsafe timeouts).
// Usage: node rpc-pacer.mjs --port <p> --upstream <url>[,<url>…] [--interval-ms 120]
// Upstreams are tried round-robin; a request is retried until it gets a non-rate-limit
// answer or 40 attempts. Errors that are not rate limits are passed through unchanged.
import http from 'node:http';

const flag = (n, d) => { const i = process.argv.indexOf(`--${n}`); return i > 0 ? process.argv[i + 1] : d; };
const ups = flag('upstream').split(',');
const interval = Number(flag('interval-ms', '120'));
const port = Number(flag('port', '18545'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let next = 0;
let gate = Promise.resolve();
const paced = () => { const g = gate.then(() => sleep(interval)); gate = g; return g; };
const LIMITED = /429|-32005|rate limit|Too Many|failsafe|timeout|ErrUpstreams|capacity/i;
let stats = { requests: 0, retries: 0 };

async function forward(body) {
  for (let attempt = 0; attempt < 40; attempt++) {
    await paced();
    const up = ups[next++ % ups.length];
    try {
      const res = await fetch(up, { method: 'POST', headers: { 'content-type': 'application/json' },
                                    body, signal: AbortSignal.timeout(60000) });
      const text = await res.text();
      if (res.status === 429 || res.status >= 500 || (LIMITED.test(text) && /"error"/.test(text))) {
        stats.retries++;
        await sleep(Math.min(30000, 500 * 2 ** Math.min(attempt, 6)));
        continue;
      }
      return { status: res.status, text };
    } catch {
      stats.retries++;
      await sleep(Math.min(30000, 500 * 2 ** Math.min(attempt, 6)));
    }
  }
  return { status: 503, text: JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32005, message: 'rpc-pacer: gave up after 40 attempts' } }) };
}

http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', async () => {
    stats.requests++;
    const r = await forward(body);
    res.writeHead(r.status, { 'content-type': 'application/json' });
    res.end(r.text);
  });
}).listen(port, '127.0.0.1', () => console.error(`rpc-pacer on http://127.0.0.1:${port} -> ${ups.join(', ')}`));
setInterval(() => console.error(`rpc-pacer: ${stats.requests} requests, ${stats.retries} retries`), 60000);
