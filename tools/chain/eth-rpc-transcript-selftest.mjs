#!/usr/bin/env node
// eth-rpc-transcript-selftest.mjs — the committed Ethereum input set, and the endpoint
// that serves it.
//
//   node tools/chain/eth-rpc-transcript-selftest.mjs
//
// ── WHAT THIS SUITE IS EVIDENCE FOR ───────────────────────────────────────────────────
//
// `fixtures/chain-inputs/ethereum-mainnet/<tx>/` is 2.29 MiB of committed JSON-RPC answers
// and `tools/chain/eth-rpc-transcript.mjs` is the endpoint that replays them. Together they
// are what makes the Ethereum capture reproducible without a network, which is the whole
// reason the `.ct` ban does not block the Ethereum landing page any more. Two distinct
// things can be wrong with that, and this suite covers both:
//
//   * THE MECHANISM (arms 1-20). A replay endpoint that quietly fell through to the network
//     on a miss would make every offline claim in this repository false while reporting
//     green. A transcript whose manifest did not pin its files would make the committed
//     bytes replaceable. Both are asserted here against planted defects, with in-process
//     `http.Server`s standing in for the upstream.
//   * THE INPUT SET (arms 21-30). The committed answers are CROSS-CHECKED against each
//     other: the hash-only block against the full block, the receipts against the block
//     order, the receipts' `blockHash` against the block's own. An input set whose members
//     disagree is not a record of a block, and no amount of sha256 would notice — the
//     hashes pin the bytes, these arms pin the MEANING.
//
// ── WHAT IS NOT VERIFIED HERE, AND WHY THAT IS A LIMIT RATHER THAN AN OVERSIGHT ───────
//
// The strongest possible check on a transaction body is that keccak256 of its RLP encoding
// equals the hash it is filed under, and on an `eth_getProof` answer that its Merkle path
// hashes up to the block's `stateRoot`. NEITHER IS DONE, because this repository has no
// keccak-256 and no RLP, deliberately: `tools/chain/identifier-encodings.json` carries the
// standing argument against growing one ("it needs a hash function that `contract/` does
// not have and that the JS backend would have to grow"), `blocktracer.nimble` declares no
// third-party dependencies, and `node:crypto` offers sha3-256 — which is a DIFFERENT
// function from keccak-256, same permutation, different padding, so reaching for it would
// produce a check that fails on correct data.
//
// So the committed inputs are verified three ways and not a fourth:
//   1. BYTES — every file's sha256 against the manifest (`loadTranscript`).
//   2. AGREEMENT — each answer against the other answers that overlap it (arms 24-28).
//      Three independent responses from the endpoint describe the same 208 transactions,
//      and a forged one would have to be forged consistently in all three.
//   3. REPRODUCTION — the capture replayed from them produces the decoded content the
//      LIVE capture produced, which is the end-to-end check and is not in this suite
//      (it needs the recorder binary; `just eth-capture` is where it lives).
// What is missing is CRYPTOGRAPHIC self-attestation, and until something in this repository
// needs keccak for another reason, trusting one recorded conversation and cross-checking it
// three ways is the trade being made. It is stated rather than left for a reader to notice.
//
// ── NO MOCKS, WITH ONE JUSTIFIED SUBSTITUTE ───────────────────────────────────────────
//
// Arms 21-30 read the REAL committed input set off disk — no fixture, no synthetic
// transcript. Arms 1-20 need an upstream to record FROM, and the upstream is an
// `http.Server` started in this file. That substitute is justified and not incidental: the
// arms are about what the proxy does with an answer (records it once, does not overwrite a
// result with a retry's error, refuses on a miss), and asserting that requires CHOOSING the
// answers and READING THE REQUEST LOG. A real endpoint can do neither, and an arm pointed
// at one would be measuring somebody else's uptime in a suite whose entire purpose is that
// nothing here needs a network. `body-proxy-selftest.mjs` makes the same trade for the same
// reason, in as many words.

import { createServer } from 'node:http';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

import {
  canonicaliseParams,
  callKey,
  classifyCall,
  startTranscriptServer,
  writeTranscript,
  loadTranscript,
  TRANSCRIPT_VERSION,
} from './lib/eth-rpc-transcript.mjs';

const exec = promisify(execFile);
const HERE = dirname(new URL(import.meta.url).pathname);
const REPO_ROOT = resolve(HERE, '..', '..');
const CLI = join(HERE, 'eth-rpc-transcript.mjs');

/**
 * The transaction the committed input set describes, and the three figures the capture
 * declares about it. Written here rather than read from the inputs on purpose: an arm that
 * read its expectation out of the thing it is checking would pass for any block.
 */
const TX = '0xf6998cac9f5d2843729743b866bdc4b09bd119774bbec5e56f69f8819f2b71aa';
const BLOCK = 26083328;
const TX_INDEX = 8;
const BLOCK_TX_COUNT = 208;
const ENTRY_POINT = '0xdac17f958d2ee523a2206206994597c13d831ec7';
const INPUTS = join(REPO_ROOT, 'fixtures', 'chain-inputs', 'ethereum-mainnet', TX);

// ── THE DECLARED ARM COUNT ───────────────────────────────────────────────────────────
//
// Host-independent: every arm is offline, needs only node, and reads either a temp
// directory this file wrote or the committed input set. There is no reader-present /
// reader-absent split to declare, unlike `ct-corpus-census-selftest.mjs`, because nothing
// here opens a container.
//
// A SUITE THAT RAN FEWER ARMS THAN IT DECLARES IS A FAILURE, not a quieter pass.
const BASE_ARMS = 30;

let pass = 0;
let fail = 0;
const ok = (what) => { pass += 1; console.log(`  ok    ${what}`); };
const bad = (what, detail) => {
  fail += 1;
  console.log(`  FAIL  ${what}${detail ? ` — ${detail}` : ''}`);
};
const arm = (what, held, detail) => (held ? ok(what) : bad(what, typeof detail === 'function' ? detail() : detail));

/** A JSON-RPC client against a URL, returning the raw envelope (or the batch array). */
async function call(url, payload) {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  return res.json();
}

/**
 * An in-process upstream whose answers this file chooses and whose requests it can read.
 * `answer(method, params, nth)` returns the envelope body; `log` is every request seen.
 */
async function fakeUpstream(answer) {
  const log = [];
  const server = createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      const nth = log.filter((l) => l.method === body.method).length;
      log.push({ method: body.method, params: body.params });
      const out = answer(body.method, body.params ?? [], nth);
      res.writeHead(out.http ?? 200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ jsonrpc: '2.0', id: body.id, ...out.envelope }));
    });
  });
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    log,
    close: () => new Promise((done) => server.close(done)),
  };
}

export async function selftest() {
  console.log('self-test — the committed Ethereum input set, and the endpoint that serves it');
  const tmp = mkdtempSync(join(tmpdir(), 'eth-rpc-transcript-selftest-'));

  try {
    // ───────────────────────────────────────────────────────────────────────────────
    // Part A — the keying.  Two spellings of one request must be one request, and two
    // different requests must never be.
    // ───────────────────────────────────────────────────────────────────────────────

    // arm 1
    {
      const c = canonicaliseParams(['0xABC', 42, true, null, ['0xDEF'], { B: '0xGH', a: 1 }]);
      arm('arm 1: canonicalisation lowercases strings recursively — inside arrays and inside '
          + 'objects — and leaves every other JSON type exactly as it was',
          c[0] === '0xabc' && c[1] === 42 && c[2] === true && c[3] === null
          && c[4][0] === '0xdef' && c[5].B === '0xgh' && c[5].a === 1
          // object keys are SORTED so that two orderings of one request key alike
          && Object.keys(c[5]).join(',') === 'B,a',
          () => `got ${JSON.stringify(c)}`);
    }

    // arm 2 — the case that actually occurs: alloy sends EIP-55 checksummed addresses and
    // `produce-eth-snapshot.mjs` lowercases on purpose.
    {
      const checksummed = callKey('eth_getCode', ['0xdAC17F958D2ee523a2206206994597C13D831ec7', '0x18dffff']);
      const lower = callKey('eth_getCode', [ENTRY_POINT, '0x18dffff']);
      arm('arm 2: a checksummed and a lowercase address are ONE key — the two clients in this '
          + 'pipeline spell addresses differently',
          checksummed === lower, () => `${checksummed} vs ${lower}`);
    }

    // arm 3
    {
      const base = callKey('eth_getCode', [ENTRY_POINT, '0x18dffff']);
      const otherMethod = callKey('eth_getBalance', [ENTRY_POINT, '0x18dffff']);
      const otherBlock = callKey('eth_getCode', [ENTRY_POINT, '0x18e0000']);
      const fewerParams = callKey('eth_getCode', [ENTRY_POINT]);
      const distinct = new Set([base, otherMethod, otherBlock, fewerParams]);
      arm('arm 3: a different method, a different block and a different param COUNT are three '
          + 'different keys',
          distinct.size === 4, () => `${distinct.size} distinct keys, expected 4`);
    }

    // arm 4
    arm('arm 4: `eth_blockNumber` is tip-dependent — its answer describes the chain now, not '
        + 'the captured block',
        classifyCall('eth_blockNumber', []) === 'tip-dependent',
        () => classifyCall('eth_blockNumber', []));

    // arm 5 — the classification is per CALL and not per METHOD, which is the distinction
    // that matters: the same method is immutable at a height and tip-dependent at a tag.
    {
      const tagged = classifyCall('eth_getBlockByNumber', ['finalized', false]);
      const numbered = classifyCall('eth_getBlockByNumber', ['0x18e0000', true]);
      arm('arm 5: `eth_getBlockByNumber` is tip-dependent at a TAG and immutable at a HEIGHT '
          + '— the classification is per call, not per method',
          tagged === 'tip-dependent' && numbered === 'immutable',
          () => `tag=${tagged} height=${numbered}`);
    }

    // arm 6
    {
      const version = classifyCall('web3_clientVersion', []);
      const control = classifyCall('thisMethodDoesNotExist', []);
      arm('arm 6: the two answers about the ENDPOINT rather than the chain are classified as '
          + 'endpoint-identity',
          version === 'endpoint-identity' && control === 'endpoint-identity',
          () => `clientVersion=${version} control=${control}`);
    }

    // ───────────────────────────────────────────────────────────────────────────────
    // Part B — the server.
    // ───────────────────────────────────────────────────────────────────────────────

    // arm 7
    {
      const up = await fakeUpstream(() => ({ envelope: { result: '0x1' } }));
      const srv = await startTranscriptServer({ mode: 'record', upstream: up.url });
      const answer = await call(srv.url, { jsonrpc: '2.0', id: 7, method: 'eth_chainId', params: [] });
      await srv.close();
      await up.close();
      arm('arm 7: record forwards the call upstream, returns the upstream answer, and remembers it',
          answer.result === '0x1'
          && up.log.length === 1 && up.log[0].method === 'eth_chainId'
          && srv.recorded.size === 1,
          () => `answer=${JSON.stringify(answer)} upstreamCalls=${up.log.length} recorded=${srv.recorded.size}`);
    }

    // arm 8 — both producers retry a throttled read up to 12 times. A transcript that let
    // the 12th answer overwrite the 1st would record the refusal and replay it forever.
    {
      const up = await fakeUpstream((_m, _p, nth) => (nth === 0
        ? { envelope: { result: '0xgood' } }
        : { http: 429, envelope: { error: { code: -32005, message: 'rate limit' } } }));
      const srv = await startTranscriptServer({ mode: 'record', upstream: up.url });
      await call(srv.url, { jsonrpc: '2.0', id: 1, method: 'eth_getBalance', params: ['0xa', '0x1'] });
      await call(srv.url, { jsonrpc: '2.0', id: 2, method: 'eth_getBalance', params: ['0xa', '0x1'] });
      const stored = [...srv.recorded.values()][0];
      await srv.close();
      await up.close();
      arm('arm 8: a retry that is throttled does not overwrite the good answer already recorded',
          srv.recorded.size === 1 && stored.response.result === '0xgood',
          () => JSON.stringify(stored?.response));
    }

    // arm 9 — and the converse: for the blind-proxy control the ERROR is the answer, so a
    // call that never produced a result must keep its error rather than go unrecorded.
    {
      const up = await fakeUpstream(() => ({ envelope: { error: { code: -32601, message: 'no such method' } } }));
      const srv = await startTranscriptServer({ mode: 'record', upstream: up.url });
      await call(srv.url, { jsonrpc: '2.0', id: 1, method: 'thisMethodDoesNotExist', params: [] });
      const stored = [...srv.recorded.values()][0];
      await srv.close();
      await up.close();
      arm('arm 9: a call that only ever errors IS recorded, with its error — the blind-proxy '
          + 'control has no other answer to keep',
          srv.recorded.size === 1 && stored.response.error?.code === -32601
          && stored.kind === 'endpoint-identity',
          () => JSON.stringify(stored));
    }

    // Build one small transcript on disk, used by arms 10-20.
    const smallDir = join(tmp, 'small');
    {
      const up = await fakeUpstream((m) => ({
        envelope: m === 'thisMethodDoesNotExist'
          ? { error: { code: -32601, message: 'no such method' } }
          : { result: `answer-for-${m}` },
      }));
      const srv = await startTranscriptServer({ mode: 'record', upstream: up.url });
      await call(srv.url, { jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] });
      await call(srv.url, { jsonrpc: '2.0', id: 2, method: 'eth_getCode', params: ['0xdAC17F958D2ee523a2206206994597C13D831ec7', '0x1'] });
      await call(srv.url, { jsonrpc: '2.0', id: 3, method: 'thisMethodDoesNotExist', params: [] });
      await srv.close();
      await up.close();
      writeTranscript(smallDir, srv.recorded, { upstream: up.url, recordedAt: '2026-01-01T00:00:00.000Z' });
    }
    const small = loadTranscript(smallDir);

    // arm 10
    {
      const srv = await startTranscriptServer({ mode: 'replay', transcript: small });
      const first = await call(srv.url, { jsonrpc: '2.0', id: 10, method: 'eth_chainId', params: [] });
      const second = await call(srv.url, { jsonrpc: '2.0', id: 11, method: 'eth_chainId', params: [] });
      await srv.close();
      arm('arm 10: replay serves a recorded answer, and serves it again — a keyed transcript is '
          + 'order-free and re-askable',
          first.result === 'answer-for-eth_chainId' && second.result === first.result
          && first.id === 10 && second.id === 11
          && srv.stats.served === 2,
          () => `${JSON.stringify(first)} / ${JSON.stringify(second)} served=${srv.stats.served}`);
    }

    // arm 11 — the recorded request used the checksummed spelling; this one does not.
    {
      const srv = await startTranscriptServer({ mode: 'replay', transcript: small });
      const answer = await call(srv.url, {
        jsonrpc: '2.0', id: 1, method: 'eth_getCode', params: [ENTRY_POINT, '0x1'],
      });
      await srv.close();
      arm('arm 11: replay answers a LOWERCASE spelling of a request that was recorded '
          + 'checksummed',
          answer.result === 'answer-for-eth_getCode', () => JSON.stringify(answer));
    }

    // arm 12
    {
      const srv = await startTranscriptServer({ mode: 'replay', transcript: small });
      const answer = await call(srv.url, { jsonrpc: '2.0', id: 1, method: 'eth_getStorageAt', params: ['0xa', '0x0', '0x1'] });
      await srv.close();
      arm('arm 12: a call the transcript does not hold is a MISS — answered with an error that '
          + 'names the method, and counted',
          answer.error && /MISS/.test(answer.error.message) && /eth_getStorageAt/.test(answer.error.message)
          && srv.stats.misses.length === 1 && srv.stats.misses[0].method === 'eth_getStorageAt',
          () => `${JSON.stringify(answer)} misses=${JSON.stringify(srv.stats.misses)}`);
    }

    // arm 13 — THE ARM THE WHOLE OFFLINE CLAIM RESTS ON. A replay that fell through to the
    // network on a miss would make every "no network" statement in this repository false
    // while reporting green, and the fall-through would be invisible from the answer.
    {
      const up = await fakeUpstream(() => ({ envelope: { result: '0xLEAKED' } }));
      const srv = await startTranscriptServer({ mode: 'replay', transcript: small, upstream: up.url });
      const answer = await call(srv.url, { jsonrpc: '2.0', id: 1, method: 'eth_getStorageAt', params: ['0xa', '0x0', '0x1'] });
      await srv.close();
      await up.close();
      arm('arm 13: replay NEVER reaches the upstream, even when one is handed to it and even '
          + 'on a miss — the fake upstream saw nothing',
          up.log.length === 0 && answer.error !== undefined && answer.result === undefined,
          () => `upstreamCalls=${up.log.length} answer=${JSON.stringify(answer)}`);
    }

    // arm 14
    {
      const srv = await startTranscriptServer({ mode: 'deny' });
      const answer = await call(srv.url, { jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] });
      await srv.close();
      arm('arm 14: deny refuses every call and says why — the mode that proves a producer '
          + 'reads the endpoint at all',
          answer.error && /DENY/.test(answer.error.message) && srv.stats.denied === 1,
          () => JSON.stringify(answer));
    }

    // arm 15 — alloy batches, and a positional transcript could not key a batch member.
    {
      const srv = await startTranscriptServer({ mode: 'replay', transcript: small });
      const answers = await call(srv.url, [
        { jsonrpc: '2.0', id: 1, method: 'eth_chainId', params: [] },
        { jsonrpc: '2.0', id: 2, method: 'eth_getStorageAt', params: ['0xa', '0x0', '0x1'] },
      ]);
      await srv.close();
      arm('arm 15: a BATCH is answered member-wise — one hit, one miss, in request order',
          Array.isArray(answers) && answers.length === 2
          && answers[0].id === 1 && answers[0].result === 'answer-for-eth_chainId'
          && answers[1].id === 2 && answers[1].error !== undefined
          && srv.stats.served === 1 && srv.stats.misses.length === 1,
          () => JSON.stringify(answers));
    }

    // ───────────────────────────────────────────────────────────────────────────────
    // Part C — the transcript on disk.  The manifest is what makes the committed bytes
    // the inputs rather than merely files that happen to be there.
    // ───────────────────────────────────────────────────────────────────────────────

    // arm 16
    {
      const recomputed = small.manifest.calls.reduce((n, c) => n + c.bytes, 0);
      arm('arm 16: writeTranscript -> loadTranscript round-trips, and the manifest\'s totals '
          + 'are the recomputed ones',
          small.byKey.size === 3
          && small.manifest.totals.calls === 3
          && small.manifest.totals.bytes === recomputed
          && small.manifest.totals.endpointIdentity === 1
          && small.manifest.totals.immutable === 2,
          () => JSON.stringify(small.manifest.totals));
    }

    // arm 17
    {
      const dir = join(tmp, 'tampered');
      cpSync(smallDir, dir, { recursive: true });
      const victim = small.manifest.calls.find((c) => c.method === 'eth_getCode');
      const path = join(dir, 'calls', victim.file);
      const body = JSON.parse(readFileSync(path, 'utf8'));
      body.response.result = 'answer-for-something-else';
      writeFileSync(path, `${JSON.stringify(body)}\n`);
      let message = null;
      try { loadTranscript(dir); } catch (e) { message = String(e.message); }
      arm('arm 17: a call file whose bytes were edited is REFUSED, naming the file and both '
          + 'hashes',
          message !== null && message.includes(victim.file) && message.includes(victim.sha256),
          () => `message=${message}`);
    }

    // arm 18 — the file's bytes and its sha256 agree, but it is filed under another call's
    // key, so the server would answer the wrong question with a well-hashed file.
    {
      const dir = join(tmp, 'miskeyed');
      cpSync(smallDir, dir, { recursive: true });
      const manifestPath = join(dir, 'manifest.json');
      const m = JSON.parse(readFileSync(manifestPath, 'utf8'));
      const victim = m.calls.find((c) => c.method === 'eth_getCode');
      victim.key = callKey('eth_getBalance', ['0xa', '0x1']);
      writeFileSync(manifestPath, `${JSON.stringify(m, null, 2)}\n`);
      let message = null;
      try { loadTranscript(dir); } catch (e) { message = String(e.message); }
      arm('arm 18: an entry filed under the wrong key is REFUSED — a well-hashed file that '
          + 'answers a different question is still the wrong answer',
          message !== null && /filed it under/.test(message),
          () => `message=${message}`);
    }

    // arm 19
    {
      const dir = join(tmp, 'future');
      cpSync(smallDir, dir, { recursive: true });
      const manifestPath = join(dir, 'manifest.json');
      const m = JSON.parse(readFileSync(manifestPath, 'utf8'));
      m.version = TRANSCRIPT_VERSION + 1;
      writeFileSync(manifestPath, `${JSON.stringify(m, null, 2)}\n`);
      let message = null;
      try { loadTranscript(dir); } catch (e) { message = String(e.message); }
      arm('arm 19: a transcript version this reader does not speak is REFUSED rather than '
          + 'read optimistically',
          message !== null && message.includes(`version ${TRANSCRIPT_VERSION + 1}`),
          () => `message=${message}`);
    }

    // arm 20 — an unlisted file is an input nothing pins, which is the shape a plausible
    // answer would arrive in.
    {
      const dir = join(tmp, 'stray');
      cpSync(smallDir, dir, { recursive: true });
      writeFileSync(join(dir, 'calls', 'eth_getStorageAt.planted.00000000.json'),
                    `${JSON.stringify({ method: 'eth_getStorageAt', params: [], response: { result: '0x0' } })}\n`);
      let rc = 0;
      let out = '';
      try {
        await exec(process.execPath, [CLI, '--verify', '--transcript', dir]);
      } catch (e) {
        rc = e.code ?? 1;
        out = `${e.stdout ?? ''}${e.stderr ?? ''}`;
      }
      arm('arm 20: `--verify` refuses a file under calls/ that the manifest does not list',
          rc === 1 && /not in the manifest/.test(out) && /planted/.test(out),
          () => `rc=${rc} out=${out.slice(0, 300)}`);
    }

    // ───────────────────────────────────────────────────────────────────────────────
    // Part D — THE COMMITTED INPUT SET ITSELF.
    //
    // Arm 21 is the base case and it is not decoration: arms 22-30 all read the real
    // transcript, and without an arm proving it LOADS they would be satisfied by a
    // transcript that could not be opened at all.
    // ───────────────────────────────────────────────────────────────────────────────

    const real = loadTranscript(INPUTS);
    /** The one recorded answer for `method` with `params`, or undefined. */
    const answerFor = (method, params) => real.byKey.get(callKey(method, params))?.response?.result;
    const hex = (n) => `0x${n.toString(16)}`;

    // arm 21
    {
      const { stdout } = await exec(process.execPath, [CLI, '--verify', '--transcript', INPUTS]);
      arm('arm 21 (base case): the committed input set loads, every sha256 as the manifest '
          + 'says, so the arms below are not vacuous',
          /transcript OK/.test(stdout) && real.byKey.size === real.manifest.totals.calls
          && real.byKey.size > 400,
          () => `calls=${real.byKey.size} stdout=${stdout.slice(0, 200)}`);
    }

    // arm 22
    {
      const chainId = answerFor('eth_chainId', []);
      arm('arm 22: the input set is Ethereum MAINNET — `eth_chainId` answers 0x1',
          chainId === '0x1', () => `eth_chainId=${chainId}`);
    }

    // arm 23 — the transaction's own answer about where it sits, against the three figures
    // this file declares rather than reads.
    {
      const tx = answerFor('eth_getTransactionByHash', [TX]);
      arm('arm 23: the target transaction sits where the capture says it does — block '
          + `${BLOCK}, index ${TX_INDEX}`,
          tx && parseInt(tx.blockNumber, 16) === BLOCK
          && parseInt(tx.transactionIndex, 16) === TX_INDEX
          && tx.hash.toLowerCase() === TX,
          () => `tx=${tx ? JSON.stringify({ b: tx.blockNumber, i: tx.transactionIndex, h: tx.hash }) : 'absent'}`);
    }

    // arm 24 — TWO INDEPENDENT ANSWERS ABOUT THE SAME BLOCK, cross-checked. This is the
    // kind of agreement that stands in for the keccak check this suite does not do: a
    // forged body would have to be forged identically in both responses.
    {
      const thin = answerFor('eth_getBlockByNumber', [hex(BLOCK), false]);
      const full = answerFor('eth_getBlockByNumber', [hex(BLOCK), true]);
      const thinHashes = (thin?.transactions ?? []).map((h) => h.toLowerCase());
      const fullHashes = (full?.transactions ?? []).map((t) => t.hash.toLowerCase());
      arm(`arm 24: the hash-only block and the full block agree on all ${BLOCK_TX_COUNT} `
          + 'transaction hashes, in order',
          thinHashes.length === BLOCK_TX_COUNT
          && fullHashes.length === BLOCK_TX_COUNT
          && thinHashes.every((h, i) => h === fullHashes[i])
          && thin.hash === full.hash,
          () => `thin=${thinHashes.length} full=${fullHashes.length} `
            + `firstMismatch=${thinHashes.findIndex((h, i) => h !== fullHashes[i])}`);
    }

    // arm 25 — a third independent answer about the same block.
    {
      const thin = answerFor('eth_getBlockByNumber', [hex(BLOCK), false]);
      const receipts = answerFor('eth_getBlockReceipts', [hex(BLOCK)]);
      const hashes = (thin?.transactions ?? []).map((h) => h.toLowerCase());
      arm(`arm 25: the receipts are ${BLOCK_TX_COUNT} and pair with the block IN ORDER — the `
          + 'producer pairs them by position, so position is what has to be right',
          Array.isArray(receipts) && receipts.length === BLOCK_TX_COUNT
          && receipts.every((r, i) => r.transactionHash.toLowerCase() === hashes[i]),
          () => `receipts=${Array.isArray(receipts) ? receipts.length : 'absent'} `
            + `firstMismatch=${(receipts ?? []).findIndex((r, i) => r.transactionHash.toLowerCase() !== hashes[i])}`);
    }

    // arm 26
    {
      const thin = answerFor('eth_getBlockByNumber', [hex(BLOCK), false]);
      const receipts = answerFor('eth_getBlockReceipts', [hex(BLOCK)]) ?? [];
      const strays = receipts.filter(
        (r) => r.blockHash?.toLowerCase() !== thin?.hash?.toLowerCase()
          || parseInt(r.blockNumber, 16) !== BLOCK);
      arm('arm 26: every receipt names the captured block — same `blockHash`, same height',
          receipts.length === BLOCK_TX_COUNT && strays.length === 0,
          () => `${strays.length} receipt(s) name another block`);
    }

    // arm 27 — the 9 bodies the replay actually executes (0..TX_INDEX), with every field
    // `alloy_tx_to_revm_tx` reads. A body missing one of these would make the prestate
    // wrong rather than make the run fail.
    {
      const full = answerFor('eth_getBlockByNumber', [hex(BLOCK), true]);
      const replayed = (full?.transactions ?? []).slice(0, TX_INDEX + 1);
      const needed = ['hash', 'from', 'gas', 'input', 'nonce', 'value'];
      const incomplete = replayed.filter((t) => needed.some((k) => t[k] === undefined || t[k] === null));
      arm(`arm 27: all ${TX_INDEX + 1} transaction bodies the replay executes (indices 0..`
          + `${TX_INDEX}) carry every field the replay converts`,
          replayed.length === TX_INDEX + 1 && incomplete.length === 0
          && replayed[TX_INDEX].hash.toLowerCase() === TX,
          () => `bodies=${replayed.length} incomplete=${incomplete.length} `
            + `last=${replayed[TX_INDEX]?.hash}`);
    }

    // arm 28 — the fork is pinned at the PARENT, and the source attribution reads code at
    // the TARGET block. Both reads must be in the input set, at the right heights, or the
    // offline run would miss.
    {
      const atParent = answerFor('eth_getCode', [ENTRY_POINT, hex(BLOCK - 1)]);
      const atTarget = answerFor('eth_getCode', [ENTRY_POINT, hex(BLOCK)]);
      arm('arm 28: the entry point\'s deployed code is in the input set at BOTH heights the '
          + 'capture reads — the parent (the fork pin) and the target block (the listing)',
          typeof atParent === 'string' && atParent.length > 2
          && typeof atTarget === 'string' && atTarget === atParent,
          () => `parent=${typeof atParent === 'string' ? atParent.length : atParent} `
            + `target=${typeof atTarget === 'string' ? atTarget.length : atTarget}`);
    }

    // arm 29 — the two answers that are NOT immutable are marked as such. An input set that
    // claimed every answer was a fact about a finalised block would be lying about two of
    // them, and a reader would have no way to tell which.
    {
      const tip = real.manifest.calls.filter((c) => c.kind === 'tip-dependent');
      const identity = real.manifest.calls.filter((c) => c.kind === 'endpoint-identity');
      const methods = tip.map((c) => c.method).sort();
      arm('arm 29: exactly the two tip-dependent answers are MARKED tip-dependent, and the '
          + 'two endpoint-identity ones endpoint-identity',
          tip.length === 2 && identity.length === 2
          && methods.join(',') === 'eth_blockNumber,eth_getBlockByNumber'
          && identity.map((c) => c.method).sort().join(',') === 'thisMethodDoesNotExist,web3_clientVersion',
          () => `tip=${JSON.stringify(methods)} identity=${JSON.stringify(identity.map((c) => c.method))}`);
    }

    // arm 30 — THE ONE CLASS OF RECORDED REFUSAL THAT IS ALLOWED, AND WHY THE DISTINCTION
    // DECIDES WHETHER THE INPUT SET IS SOUND.
    //
    // A recorded refusal replays forever, so most of them would be poison: the producers
    // retry a throttled read up to 12 times, and a transcript that captured the 429 instead
    // of the answer would turn one bad minute on a public endpoint into a permanently
    // broken input set. Arm 8 is the mechanism that prevents it; this is the reading over
    // the committed bytes.
    //
    // But one class is LOAD-BEARING. alloy probes `eth_getAccountInfo` — the combined
    // account read — and falls back to `eth_getBalance` + `eth_getTransactionCount` +
    // `eth_getCode` when the endpoint does not serve it. The endpoint this set was recorded
    // against does not, and the offline replay must answer the SAME `-32601` or the client
    // will not take the same path. Deleting that refusal would not make the input set
    // cleaner; it would make the replay miss.
    //
    // So the rule is by CLASS and not by presence, with `produce-eth-snapshot.mjs`'s own
    // partition: `-32601` is ABSENT (a capability the endpoint does not have, replayable),
    // everything else is POLICY or TRANSPORT (a refusal about this moment, never
    // replayable).
    {
      const absent = [];
      const notAbsent = [];
      for (const entry of real.manifest.calls) {
        const stored = real.byKey.get(entry.key);
        if (stored.response.result !== undefined) continue;
        (stored.response.error?.code === -32601 ? absent : notAbsent)
          .push(`${entry.method} (code ${stored.response.error?.code})`);
      }
      const chainRefusals = absent.filter((s) => !s.startsWith('thisMethodDoesNotExist'));
      arm('arm 30: every recorded refusal is an ABSENT-class `-32601`, and the only chain '
          + 'method refused is `eth_getAccountInfo` — whose refusal is what makes alloy take '
          + 'its fallback offline too. No policy or transport refusal was recorded.',
          notAbsent.length === 0
          && chainRefusals.length === 1
          && chainRefusals[0].startsWith('eth_getAccountInfo'),
          () => `notAbsent=${JSON.stringify(notAbsent)} chainRefusals=${JSON.stringify(chainRefusals)}`);
    }
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }

  console.log('');
  const ran = pass + fail;
  if (ran !== BASE_ARMS) {
    fail += 1;
    console.log(`  FAIL  arm count: ${ran} ran, ${BASE_ARMS} declared`);
  }
  console.log(`arm count: ${ran} (as declared: ${BASE_ARMS})`);
  console.log(`self-test: ${fail === 0 ? 'PASS' : 'FAIL'} — ${pass} ok, ${fail} failing`);
  return fail === 0 ? 0 : 1;
}

if (import.meta.url === `file://${process.argv[1]}`) process.exit(await selftest());
