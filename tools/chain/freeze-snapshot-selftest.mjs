#!/usr/bin/env node
// freeze-snapshot-selftest.mjs — proof that `freeze-snapshot.mjs` REFUSES.
//
//   node tools/chain/freeze-snapshot-selftest.mjs
//
// WHY THIS EXISTS. `freeze-snapshot.mjs` is the gate in front of a published claim: a
// frozen snapshot is one whose complete blocks have been re-read from the chain and found
// to hold exactly the transactions the capture recorded. That is a universal statement over
// the contents of a block, and a gate that never says no would let it be published over
// anything. Verification-Harness-Traps §4: the check that has never refused is
// indistinguishable from no check.
//
// The BANNER no longer quotes the claim — it used to read "were taken WHOLE — every
// transaction the chain published in them was re-executed", which narrated the capture to a
// reader who was not asking. The claim itself is unchanged and still gates the flag; what
// rests on it now is the curated window, which publishes only blocks whose transactions all
// have containers.
//
// So every refusal path is driven here against a MOCK NODE whose answers this test chooses,
// and each one is paired with the passing control it must differ from. No live chain: the
// interesting cases (a block that gained a transaction, a block whose second transaction
// did not replay) cannot be produced on demand from a real one.
//
// Each case has a control arm and a mutation arm, and the assertion count is declared.

import { mkdtemp, writeFile, rm, mkdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, 'freeze-snapshot.mjs');

let asserted = 0, failed = 0;
const ck = (label, cond) => { asserted++; if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`); };
const bite = (label, cond) => { asserted++; if (!cond) { failed++; console.error(`  FAIL  MUTATION DID NOT BITE  ${label}`); } else console.error(`  bite  ${label}`); };

const CTFS = Buffer.from([0xC0, 0xDE, 0x72, 0xAC, 0xE2, 0x03, 0x00, 0x00]);
const container = (n) => Buffer.concat([CTFS, Buffer.alloc(n - CTFS.length, 7)]);

// ── the mock node ──────────────────────────────────────────────────────────────────────
// `blocks` maps block number -> array of tx hashes it will claim the block holds.
let blocks = {};
const server = createServer((req, res) => {
  let body = '';
  req.on('data', (d) => { body += d; });
  req.on('end', () => {
    const { id, method, params } = JSON.parse(body);
    let result = null;
    if (method === 'node_getBlock') {
      const n = params[0];
      result = blocks[n] ? { body: { txEffects: blocks[n].map((h) => ({ txHash: h })) } } : null;
    }
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify(result === null ? { jsonrpc: '2.0', id, error: { message: 'no such block' } }
                                            : { jsonrpc: '2.0', id, result }));
  });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const URL_ = `http://127.0.0.1:${server.address().port}`;

const run = (dir, extra = []) => new Promise((res) => {
  const p = spawn(process.execPath, [TOOL, '--snapshot', dir, '--url', URL_, ...extra]);
  let err = '';
  p.stderr.on('data', (d) => { err += d; });
  p.on('close', (code) => res({ code, err }));
});

/** A snapshot with two complete single-transaction blocks and their containers. */
async function makeGood() {
  const dir = await mkdtemp(join(tmpdir(), 'bt-freeze-'));
  await mkdir(join(dir, 'ct'), { recursive: true });
  await writeFile(join(dir, 'ct', '0xaa.ct'), container(4096));
  await writeFile(join(dir, 'ct', '0xbb.ct'), container(8192));
  const snap = {
    format: 'blocktracer/chain-snapshot@1',
    provenance: { kind: 'live-capture', chain: 'x', endpoint: URL_, nodeVersion: '5.2.0',
                  capturedAt: '2026-09-01T00:00:00Z' },
    blocks: [{ number: 20, transactions: ['0xbb'] }, { number: 10, transactions: ['0xaa'] }],
    transactions: [
      { txHash: '0xaa', blockNumber: 10, outcome: 'replayed', container: 'ct/0xaa.ct', containerBytes: 4096 },
      { txHash: '0xbb', blockNumber: 20, outcome: 'replayed', container: 'ct/0xbb.ct', containerBytes: 8192 },
    ],
  };
  await writeFile(join(dir, 'snapshot.json'), JSON.stringify(snap, null, 1));
  blocks = { 10: ['0xaa'], 20: ['0xbb'] };
  return { dir, snap };
}
const write = (dir, snap) => writeFile(join(dir, 'snapshot.json'), JSON.stringify(snap, null, 1));

console.error('\ncase 1 — a verified snapshot freezes, and the freeze is recorded');
{
  const { dir } = await makeGood();
  const r = await run(dir, ['--min-complete', '2']);
  ck('control: it froze', r.code === 0 && /FROZEN/.test(r.err));
  const after = JSON.parse(await readFile(join(dir, 'snapshot.json'), 'utf8'));
  ck('control: provenance.frozen is set', after.provenance.frozen === true);
  ck('control: the complete blocks are named, newest first',
     JSON.stringify(after.provenance.completeBlocks) === JSON.stringify([20, 10]));
  ck('control: frozenAt records when', typeof after.provenance.frozenAt === 'string');
  await rm(dir, { recursive: true, force: true });
}

console.error('\ncase 2 — --check-only proves without writing');
{
  const { dir } = await makeGood();
  const r = await run(dir, ['--min-complete', '2', '--check-only']);
  ck('control: the checks pass', r.code === 0 && /all checks pass/.test(r.err));
  const after = JSON.parse(await readFile(join(dir, 'snapshot.json'), 'utf8'));
  bite('mutation: nothing was written — the snapshot is still unfrozen',
       after.provenance.frozen === undefined);
  await rm(dir, { recursive: true, force: true });
}

console.error('\ncase 3 — a block that GAINED a transaction is not whole');
{
  const { dir } = await makeGood();
  blocks[20] = ['0xbb', '0xcc'];        // the chain now lists two; the snapshot recorded one
  const r = await run(dir, ['--min-complete', '2']);
  bite('mutation: it refuses when the chain lists more than the snapshot recorded',
       r.code === 1 && /not captured whole/.test(r.err));
  bite('mutation: and it wrote nothing',
       JSON.parse(await readFile(join(dir, 'snapshot.json'), 'utf8')).provenance.frozen === undefined);
  await rm(dir, { recursive: true, force: true });
}

console.error('\ncase 4 — a block whose second transaction did not replay is not complete');
{
  const { dir, snap } = await makeGood();
  // Two transactions in block 20, and only one of them replayed: the headline overclaim.
  snap.blocks[0].transactions = ['0xbb', '0xcc'];
  snap.transactions.push({ txHash: '0xcc', blockNumber: 20, outcome: 'pruned' });
  await write(dir, snap);
  blocks[20] = ['0xbb', '0xcc'];
  const r = await run(dir, ['--min-complete', '2']);
  // It must NAME the partial and exclude it — not drop it silently, and not publish it.
  bite('mutation: the half-covered block is named PARTIAL, with the transaction that failed',
       /block 20: PARTIAL — 1\/2 replayed/.test(r.err) && /0xcc is pruned, not replayed/.test(r.err));
  bite('mutation: and with only block 10 left, the target of two is not met',
       r.code === 1 && /only 1 block\(s\) verified complete/.test(r.err));
  // CONTROL TWIN: the same two-transaction block, with BOTH replayed, must pass — so the
  // refusal above is about completeness and not about multi-transaction blocks as such.
  const { dir: d2, snap: s2 } = await makeGood();
  await writeFile(join(d2, 'ct', '0xcc.ct'), container(2048));
  s2.blocks[0].transactions = ['0xbb', '0xcc'];
  s2.transactions.push({ txHash: '0xcc', blockNumber: 20, outcome: 'replayed',
                         container: 'ct/0xcc.ct', containerBytes: 2048 });
  await write(d2, s2);
  blocks[20] = ['0xbb', '0xcc'];
  const r2 = await run(d2, ['--min-complete', '2', '--check-only']);
  ck('twin: the SAME block with both transactions replayed passes', r2.code === 0);
  await rm(dir, { recursive: true, force: true });
  await rm(d2, { recursive: true, force: true });
}

console.error('\ncase 5 — the containers have to be there, the right size, and openable');
{
  const { dir, snap } = await makeGood();
  snap.transactions[0].containerBytes = 4095;      // one byte off
  await write(dir, snap);
  const r = await run(dir, ['--min-complete', '2']);
  bite('mutation: a containerBytes that disagrees with the file refuses',
       r.code === 1 && /containerBytes says 4095, the file is 4096/.test(r.err));
  await rm(dir, { recursive: true, force: true });

  const { dir: d2 } = await makeGood();
  await writeFile(join(d2, 'ct', '0xaa.ct'), Buffer.alloc(4096, 9));  // right size, no magic
  const r2 = await run(d2, ['--min-complete', '2']);
  bite('mutation: a right-sized file without the CTFS magic refuses',
       r2.code === 1 && /does not carry the CTFS magic/.test(r2.err));
  await rm(d2, { recursive: true, force: true });

  const { dir: d3 } = await makeGood();
  await rm(join(d3, 'ct', '0xbb.ct'));
  const r3 = await run(d3, ['--min-complete', '2']);
  bite('mutation: a missing container refuses', r3.code === 1 && /container missing/.test(r3.err));
  await rm(d3, { recursive: true, force: true });
}

console.error('\ncase 6b — a partial block does not block a freeze the OTHER blocks earn');
{
  // Three blocks: two whole, one partial. The partial is excluded and named; the freeze
  // still succeeds on the two that stand on their own, and completeBlocks omits the partial.
  const { dir, snap } = await makeGood();
  await writeFile(join(dir, 'ct', '0xdd.ct'), container(1024));
  snap.blocks.unshift({ number: 30, transactions: ['0xdd', '0xee'] });
  snap.transactions.push({ txHash: '0xdd', blockNumber: 30, outcome: 'replayed',
                           container: 'ct/0xdd.ct', containerBytes: 1024 });
  snap.transactions.push({ txHash: '0xee', blockNumber: 30, outcome: 'not-first-in-block' });
  await write(dir, snap);
  blocks[30] = ['0xdd', '0xee'];
  const r = await run(dir, ['--min-complete', '2']);
  ck('control: it froze on the two whole blocks', r.code === 0 && /FROZEN/.test(r.err));
  const after = JSON.parse(await readFile(join(dir, 'snapshot.json'), 'utf8'));
  ck('control: the partial block is NOT in completeBlocks',
     JSON.stringify(after.provenance.completeBlocks) === JSON.stringify([20, 10]));
  bite('mutation: and the partial was reported rather than dropped in silence',
       /block 30: PARTIAL/.test(r.err) && /excluded/.test(r.err));
  await rm(dir, { recursive: true, force: true });
}

console.error('\ncase 6 — a snapshot short of the target is not frozen just because it stopped');
{
  const { dir } = await makeGood();
  const r = await run(dir, ['--min-complete', '3']);
  bite('mutation: two complete blocks against a target of three refuses',
       r.code === 1 && /--min-complete is 3/.test(r.err));
  ck('control: the same snapshot against a target of two passes',
     (await run(dir, ['--min-complete', '2', '--check-only'])).code === 0);
  await rm(dir, { recursive: true, force: true });
}

server.close();
console.error('');
if (asserted !== 19) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 19 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('PASS — the gate refuses on every path it is supposed to');
