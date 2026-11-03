#!/usr/bin/env node
// The self-test for `tools/chain/check-chain-compat.mjs`. Offline: no chain, no AVM, no
// network — a fake node over `createServer` and an injected decoder.
//
//   node tools/chain/check-chain-compat-selftest.mjs
//
// ── THE BAR ───────────────────────────────────────────────────────────────────────────
//
// The check exists because two real guards stayed silent for two months, so a green from
// it is worth exactly what it can be shown to do. Thirteen arms, each asserting the
// OUTCOME NAME and not just the exit code: a run that said `node-unreachable` where the
// truth was `identity-moved` would score identically on exit codes and send the next
// reader after the wrong thing.
//
// Four arms invert it and require a PASS — the control, `--identity-only`, a rollup
// address that differs only in case, and a successful decode. A check that cried wolf on
// a healthy chain would be switched off, and then the silence it was written for returns
// with it nominally in place.
//
// THE ONE THAT MATTERS MOST is `decoder-refused-under-matching-identity`: that is today's
// real state on aztec-testnet, and the arm asserts the sentence says SERIALISATION rather
// than letting a reader infer a restart from a matching identity.

import { createServer } from 'node:http';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const HERE = dirname(fileURLToPath(import.meta.url));
const CHECKER = join(HERE, 'check-chain-compat.mjs');

const TX = '0x284813bc0b7ecd556ab91ce564c5865cdd81f9e0a51bc28baa488f72a271c380';
const IDENTITY = {
  l1ChainId: 11155111,
  rollupVersion: 679261766,
  rollupAddress: '0x1f435a7f2da358caf887a470faeee7d5d5f4efba',
  nodeVersion: '6.0.0',
};

/** A node that answers the four calls the check makes, with whatever this arm chose. */
function fakeNode({ info, tip = 100, finalized = 90, txAtBlock = 99, txBelowFinalized = -1,
                    body = { txHash: TX, data: '0x00' } }) {
  const server = createServer((req, res) => {
    let raw = '';
    req.on('data', (d) => { raw += d; });
    req.on('end', () => {
      const { id, method, params } = JSON.parse(raw || '{}');
      const reply = (result) => {
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ jsonrpc: '2.0', id, result }));
      };
      if (method === 'node_getNodeInfo') return reply(info);
      if (method === 'node_getBlockNumber') return reply(params?.[0] === 'finalized' ? finalized : tip);
      if (method === 'node_getBlock') {
        const n = params?.[0];
        return reply(n === txAtBlock || n === txBelowFinalized
          ? { body: { txEffects: [{ txHash: TX }] } } : { body: { txEffects: [] } });
      }
      if (method === 'node_getTxByHash') return reply(body);
      return reply(null);
    });
  });
  // `keepAliveTimeout = 1` AND `closeAllConnections`, because `server.close()` waits for
  // idle keep-alive sockets and undici keeps one open after each request — which hung this
  // self-test on its first arm until the whole run was killed.
  server.keepAliveTimeout = 200;
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((d) => { server.closeAllConnections?.(); server.close(d); }),
  })));
}

/** A store that serves one key, with the leading-32-bytes property a real body has — so
 *  `classify` passes and the DECODE is what the arm is actually about. `--body-store`
 *  points the check here, which is what keeps every store arm offline. */
function fakeStore({ serve = true }) {
  const bytes = Buffer.concat([Buffer.from(TX.slice(2), 'hex'), Buffer.alloc(64, 7)]);
  const server = createServer((req, res) => {
    if (!serve) { res.writeHead(404); return res.end('nope'); }
    res.writeHead(200, { 'content-type': 'application/octet-stream' });
    res.end(bytes);
  });
  server.keepAliveTimeout = 200;
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({
    url: `http://127.0.0.1:${server.address().port}`,
    close: () => new Promise((d) => { server.closeAllConnections?.(); server.close(d); }),
  })));
}

const nodeInfoFor = (id) => ({
  nodeVersion: id.nodeVersion,
  l1ChainId: id.l1ChainId,
  rollupVersion: id.rollupVersion,
  l1ContractAddresses: { rollupAddress: id.rollupAddress },
});

const DIR = mkdtempSync(join(tmpdir(), 'chaincompat-'));
const decl = (chains) => {
  const p = join(DIR, `decl-${Math.random().toString(36).slice(2)}.json`);
  writeFileSync(p, JSON.stringify({ format: 'blocktracer/chain-identity@1', chains }));
  return p;
};
const declared = decl({ 'aztec-testnet': { ...IDENTITY, decoder: { package: '@aztec-labs/stdlib', version: '6.0.0', verifiedOn: '2026-11-03' } } });

// Injected decoders — the reason every decode arm runs without a 300 MB checkout.
const stub = (bodyJs) => {
  const p = join(DIR, `dec-${Math.random().toString(36).slice(2)}.mjs`);
  writeFileSync(p, bodyJs);
  return p;
};
const DEC_OK = stub(`export async function decodeOne() { return { ok: true, publicCalls: 2, txHash: '${TX}' }; }\n`);
const DEC_THROWS = stub(`export async function decodeOne() { throw new Error('Value 0x5f1b9f11ca0fbc75 is greater or equal to field modulus.'); }\n`);
const DEC_STORE_OK = stub(`export async function decodeOne() { throw new Error('the node path must not be used in this arm'); }\nexport async function decodeBytes() { return { ok: true, publicCalls: 1, txHash: '${TX}' }; }\n`);
const DEC_STORE_THROWS = stub(`export async function decodeOne() { throw new Error('the node path must not be used in this arm'); }\nexport async function decodeBytes() { throw new Error('Value 0xc0ea27fcdba81d7c is greater or equal to field modulus.'); }\n`);
const DEC_WRONG_HASH = stub(`export async function decodeOne() { return { ok: true, publicCalls: 2, txHash: '0x' + 'ab'.repeat(32) }; }\n`);

const arms = [
  { name: 'control-identity-only-passes', pass: true,
    node: { info: nodeInfoFor(IDENTITY) }, args: ['--identity-only'],
    expect: 'identity-ok' },

  { name: 'identity-matches-but-nothing-decoded-is-not-a-pass',
    node: { info: nodeInfoFor(IDENTITY) }, args: [],
    expect: 'decode-not-attempted', says: /DECISIVE half did not run/ },

  { name: 'rollup-version-moved',
    node: { info: nodeInfoFor({ ...IDENTITY, rollupVersion: 999 }) }, args: ['--identity-only'],
    expect: 'identity-moved', says: /rollupVersion declared 679261766, observed 999/ },

  { name: 'rollup-address-differing-only-in-case-still-matches', pass: true,
    node: { info: nodeInfoFor({ ...IDENTITY, rollupAddress: IDENTITY.rollupAddress.toUpperCase() }) },
    args: ['--identity-only'], expect: 'identity-ok' },

  { name: 'node-version-moved-alone',
    node: { info: nodeInfoFor({ ...IDENTITY, nodeVersion: '5.2.0' }) }, args: ['--identity-only'],
    expect: 'identity-moved', says: /nodeVersion declared 6\.0\.0, observed 5\.2\.0/ },

  { name: 'a-restart-moves-several-and-all-are-named',
    node: { info: nodeInfoFor({ l1ChainId: 1, rollupVersion: 3, rollupAddress: '0x' + '11'.repeat(20), nodeVersion: '5.2.0' }) },
    args: ['--identity-only'], expect: 'identity-moved', says: /4 identity field\(s\) moved/ },

  { name: 'node-unreachable-is-its-own-answer', noNode: true, args: ['--identity-only'],
    expect: 'node-unreachable' },

  { name: 'an-undeclared-chain-refuses', node: { info: nodeInfoFor(IDENTITY) },
    args: ['--identity-only', '--chain', 'aztec-mainnet'], expect: 'chain-not-declared',
    says: /carries no entry for aztec-mainnet/ },

  { name: 'a-declaration-with-no-chains-refuses', node: { info: nodeInfoFor(IDENTITY) },
    declFile: decl({}), args: ['--identity-only'], expect: 'chain-not-declared',
    says: /declares no chains/ },

  { name: 'a-decode-that-works-is-compatible', pass: true,
    node: { info: nodeInfoFor(IDENTITY) }, args: [], decoder: DEC_OK,
    expect: 'compatible', says: /publicCalls=2.*equals the key requested/ },

  { name: 'decoder-refused-under-matching-identity',
    node: { info: nodeInfoFor(IDENTITY) }, args: [], decoder: DEC_THROWS,
    expect: 'decoder-refused', says: /SERIALISATION difference under an unchanged deployment/ },

  { name: 'a-decode-naming-a-different-hash-is-a-miss',
    node: { info: nodeInfoFor(IDENTITY) }, args: [], decoder: DEC_WRONG_HASH,
    expect: 'decoder-refused', says: /miss wearing a success/ },

  { name: 'a-quiet-window-is-not-a-verdict',
    node: { info: nodeInfoFor(IDENTITY), txAtBlock: -1 }, args: ['--source', 'node'], decoder: DEC_OK,
    expect: 'decode-not-attempted', says: /bursty — this is a quiet window and not a verdict/ },

  // ── the second source, which is what makes the probe answerable at any hour ───────
  { name: 'an-empty-live-window-falls-through-to-the-store', pass: true,
    node: { info: nodeInfoFor(IDENTITY), txAtBlock: -1, txBelowFinalized: 85 },
    store: { serve: true }, args: [], decoder: DEC_STORE_OK,
    expect: 'compatible', says: /decoded block 85's .* from the store/ },

  { name: 'the-store-decoder-refusing-is-still-a-refusal',
    node: { info: nodeInfoFor(IDENTITY), txAtBlock: -1, txBelowFinalized: 85 },
    store: { serve: true }, args: [], decoder: DEC_STORE_THROWS,
    expect: 'decoder-refused', says: /from the store.*field modulus/ },

  { name: 'a-store-that-holds-nothing-is-unmeasured-not-refuted',
    node: { info: nodeInfoFor(IDENTITY), txAtBlock: -1, txBelowFinalized: 85 },
    store: { serve: false }, args: [], decoder: DEC_STORE_OK,
    expect: 'decode-not-attempted', says: /classify calls that absent.*unmeasured rather than refuted/s },

  { name: 'neither-source-has-one-and-the-report-names-both',
    node: { info: nodeInfoFor(IDENTITY), txAtBlock: -1 }, store: { serve: true },
    args: [], decoder: DEC_STORE_OK,
    expect: 'decode-not-attempted', says: /neither source could supply a transaction/ },
];

let failures = 0;
for (const arm of arms) {
  const problems = [];
  let n = null;
  let s = null;
  try {
    n = arm.noNode ? { url: 'http://127.0.0.1:1', close: async () => {} } : await fakeNode(arm.node);
    s = arm.store ? await fakeStore(arm.store) : null;
    const args = [CHECKER, '--url', n.url, '--expect', arm.declFile ?? declared,
                  ...(s ? ['--body-store', s.url] : []),
                  ...(arm.args.includes('--chain') ? [] : ['--chain', 'aztec-testnet']), ...arm.args];
    const env = { ...process.env };
    if (arm.decoder) env.CHAIN_COMPAT_DECODER = arm.decoder; else delete env.CHAIN_COMPAT_DECODER;
    // ASYNC `spawn`, NEVER `spawnSync`, AND THAT IS THE WHOLE REASON THIS SUITE WORKS.
    //
    // `spawnSync` blocks the parent's event loop — which is where the fake node above is
    // listening — so the child's very first request could never be answered and all ten
    // node-dependent arms reported `node-unreachable` with a 20s timeout each. The
    // outcome name is what caught it: every arm agreed on an answer none of them had
    // asked for, which is the shape of a harness fault rather than ten subject faults.
    const r = await new Promise((done) => {
      const c = spawn(process.execPath, args, { env });
      let out = '';
      const t = setTimeout(() => { c.kill('SIGKILL'); done({ out, status: null, timedOut: true }); }, 30_000);
      c.stdout.on('data', (d) => { out += d; });
      c.stderr.on('data', (d) => { out += d; });
      c.on('close', (status) => { clearTimeout(t); done({ out, status, timedOut: false }); });
    });
    if (r.timedOut) problems.push('the checker did not finish within 30s');
    const out = r.out;
    if (!out.includes(arm.expect)) problems.push(`outcome was not ${arm.expect}; output: ${out.trim().split('\n').slice(-2).join(' / ').slice(0, 220)}`);
    const wantCode = arm.pass ? 0 : 1;
    if (r.status !== wantCode) problems.push(`exit ${r.status}, wanted ${wantCode}`);
    if (arm.says && !arm.says.test(out)) problems.push(`the sentence did not match ${arm.says}`);
  } catch (e) {
    problems.push(`threw: ${e.message}`);
  } finally {
    await n?.close();
    await s?.close();
  }
  if (problems.length) {
    failures += 1;
    console.log(`  FAIL  ${arm.name}`);
    for (const p of problems) console.log(`        ${p}`);
  } else {
    console.log(`  ok    ${arm.name}${arm.pass ? '  (must PASS)' : ''}`);
  }
}
rmSync(DIR, { recursive: true, force: true });

// THE ARM COUNT IS DECLARED AND CHECKED, in the shape `refusal-selftest.mjs`'s
// cross-check reads out of this file. Its header records why: every term of
// `chain-selftest`'s total has gone stale silently at least once, so a suite states its
// own number here and the aggregate's copy is compared against it rather than retyped.
const asserted = arms.length;
if (asserted !== 17) {
  console.log(`  FAIL  this suite declares 17 arms and ran ${asserted}`);
  failures += 1;
}
console.log(failures === 0
  ? `\nall ${asserted} arms decided as written.`
  : `\n${failures} of ${asserted} arms did not decide as written.`);
process.exit(failures === 0 ? 0 : 1);
