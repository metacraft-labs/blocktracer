#!/usr/bin/env node
// snapshot-from-ingest-selftest.mjs — the arms for `snapshot-from-ingest.mjs`.
//
// WHAT IS WORTH TESTING HERE IS THE REFUSALS, not the happy path. The happy path
// is assembly: it copies published members into a snapshot and the real producer
// (`blocktracer-chain-ingest`) validates every one of them against
// `snapshot-contract.json` immediately afterwards, so a mistake there is caught
// by a gate that already exists and is far stricter than anything this file could
// re-state.
//
// The refusals are the opposite: each one exists so that a bucket MISSING a
// member produces a named error instead of a snapshot with a plausible value in
// it. Nothing downstream can catch that — a snapshot with an invented `tip` or a
// `prestateStrategy` of "unknown" ingests, publishes, and is wrong in a way no
// reader of the site can detect. So every arm below removes exactly one published
// member and asserts the tool refuses by name.

import { mkdtempSync, mkdirSync, writeFileSync, rmSync, cpSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, 'snapshot-from-ingest.mjs');
const CHAIN = 'aztec-testnet';
const HASH = '0x1159d7e7bd7e91c6c86c4329b35ba482a812a9c6918cad4038909e3e9383da5b';

let failures = 0;
const check = (name, ok, detail) => {
  if (ok) console.log(`  ok   ${name}`);
  else { console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ''}`); failures += 1; }
};

/** A minimal but COMPLETE bucket mirror; each arm removes one thing from it. */
function makeBucket(mutate = () => {}) {
  const root = mkdtempSync(join(tmpdir(), 'ingest-bucket-'));
  const cap = join(root, 'captures', CHAIN);
  const blk = join(root, 'blocks', CHAIN);
  const obs = join(root, 'observations', CHAIN);
  for (const d of [cap, blk, obs]) mkdirSync(d, { recursive: true });
  const state = {
    root,
    row: {
      txHash: HASH, blockNumber: 30541, txIndexInBlock: 0, outcome: 'replayed',
      revertCode: 0, reason: null, refusalReason: null,
      container: `ct/${HASH}.ct`, containerBytes: 12,
      effects: { matched: 16, mismatched: 0, reproduced: true },
      recording: { steps: 31882 },
      cost: [{ name: 'transactionFee', used: '0x01', unit: 'fee-juice' }],
      executions: [{ selector: '0x374aab6a' }],
    },
    block: { number: 30541, hash: '0x1c19edeb', parentArchiveRoot: '0xaaa', transactions: [HASH] },
    observation: {
      format: 'blocktracer/ingest-observation@1', chain: CHAIN, observedAt: 0,
      range: { from: 30541, to: 30541 }, cumulative: true,
      tags: { tip: 30561, finalized: 30540, blocks: 1 },
      provenance: {
        chain: CHAIN, ordering: 'blockIndex', prestateStrategy: 'hydrated-from-node',
        recorder: { id: 'blocktracer-ingest', traceSchema: 'ct/v4' },
      },
      observed: [HASH], captured: [HASH], refusals: [], uploadedThisTick: 1,
    },
    containerPresent: true,
  };
  mutate(state);
  if (state.row) writeFileSync(join(cap, `${HASH}.tx.json`), JSON.stringify(state.row));
  if (state.containerPresent) writeFileSync(join(cap, `${HASH}.ct`), 'not-a-real-ct');
  if (state.block) writeFileSync(join(blk, '30541.json'), JSON.stringify(state.block));
  if (state.observation) writeFileSync(join(obs, '30541-30541.json'), JSON.stringify(state.observation));
  return root;
}

function run(root) {
  const out = mkdtempSync(join(tmpdir(), 'snap-out-'));
  try {
    const stdout = execFileSync(process.execPath,
      [TOOL, '--bucket-dir', root, '--chain', CHAIN, '--out', out, '--json'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return { ok: true, report: JSON.parse(stdout), out };
  } catch (err) {
    return { ok: false, stderr: String(err.stderr ?? ''), out };
  }
}

console.log('snapshot-from-ingest-selftest');

// GREEN first: a complete bucket must assemble, or every refusal below could be
// passing because the tool refuses everything.
{
  const r = run(makeBucket());
  check('a complete bucket assembles', r.ok, r.stderr);
  if (r.ok) {
    check('…one transaction, one block, one container',
      r.report.transactions === 1 && r.report.blocks === 1 && r.report.containers === 1,
      JSON.stringify(r.report));
    check('…accountedFor counts the captured row', r.report.accountedFor === 1);
  }
  rmSync(r.out, { recursive: true, force: true });
}

const refusals = [
  ['no observation record', (s) => { s.observation = null; }, 'no observation record'],
  ['no transaction row for a captured hash', (s) => { s.row = null; }, 'holds no `<hash>.tx.json` row'],
  ['no block row', (s) => { s.block = null; }, 'no block rows'],
  ['provenance.recorder missing', (s) => { delete s.observation.provenance.recorder; }, 'provenance.recorder'],
  ['provenance.prestateStrategy missing', (s) => { delete s.observation.provenance.prestateStrategy; }, 'provenance.prestateStrategy'],
  ['window.tip missing', (s) => { delete s.observation.tags.tip; }, 'window.tip'],
  ['window.finalized missing', (s) => { delete s.observation.tags.finalized; }, 'window.finalized'],
  ['a row naming an absent container', (s) => { s.containerPresent = false; }, 'name a container the bucket does not hold'],
];

for (const [name, mutate, needle] of refusals) {
  const r = run(makeBucket(mutate));
  check(`refuses: ${name}`, !r.ok && r.stderr.includes(needle),
    r.ok ? 'it ASSEMBLED instead of refusing' : `message did not name it: ${r.stderr.slice(0, 160)}`);
  rmSync(r.out, { recursive: true, force: true });
}

console.log(failures === 0 ? 'snapshot-from-ingest-selftest: PASS' : `snapshot-from-ingest-selftest: ${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
