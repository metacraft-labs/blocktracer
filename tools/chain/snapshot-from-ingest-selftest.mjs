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

// THE SUITE'S OWN SIZE, AND WHY IT IS A CONSTANT RATHER THAN A TALLY.
//
// `refusal-selftest.mjs` cross-checks every suite under `tools/chain` against
// three documents — this constant, the `Justfile` recipe header's arithmetic,
// and the suite's own `ci.yml` step comment — so a suite that silently ran
// fewer arms than it claims is a red rather than a quieter green. Spelled
// `BASE_ARMS` because that is the spelling the cross-check reads; it is the
// total here because every arm is offline and needs only node.
//
// AND THE COUNT USED TO BE CONDITIONAL, WHICH IS THE DEFECT THIS CLOSES. The
// three green-path claims below sat inside `if (r.ok)`, so a bucket that failed
// to assemble ran NINE arms instead of eleven and reported nothing missing:
// the two claims that say WHAT it assembled simply disappeared, which is the
// `never ran` verdict wearing a pass's clothes. They are now always asserted
// and carry their own "this was not measured" detail.
const BASE_ARMS = 15;

let failures = 0;
let asserted = 0;
const check = (name, ok, detail) => {
  asserted += 1;
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
  const notMeasured = 'the complete bucket did not assemble, so this was not measured';
  check('…one transaction, one block, one container',
    r.ok && r.report.transactions === 1 && r.report.blocks === 1 && r.report.containers === 1,
    r.ok ? JSON.stringify(r.report) : notMeasured);
  check('…accountedFor counts the captured row',
    r.ok && r.report.accountedFor === 1,
    r.ok ? JSON.stringify(r.report) : notMeasured);
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

// -- TWO ROLLUPS MUST NOT MERGE INTO ONE CHAIN DIRECTORY --------------------------
//
// `--out` is the caller's choice, and the natural choice for a slug is that slug's
// existing corpus directory. Both Aztec networks restarted after their corpora were
// captured, and the live block numbers are back INSIDE the published ranges, so the
// natural choice would overwrite one rollup's blocks with another's under one name.
//
// THE CONTROL IS THE POINT. A guard that refused whenever `--out` already held a
// snapshot would be indistinguishable from one that compares identities, and it would
// break every legitimate re-run over the same chain. Arm 2 is that control.
{
  const sameRollup = {
    l1ChainId: 11155111, rollupVersion: 679261766,
    rollupAddress: '0x1f435a7f2da358caf887a470faeee7d5d5f4efba',
  };
  // What the bucket's observation record states, which `makeBucket` must carry for
  // these arms to mean anything. Asserted, not assumed: with no identity in the
  // bucket every comparison below would compare absence against absence.
  const bucketRoot = makeBucket((st) => {
    Object.assign(st.observation.provenance, sameRollup);
  });

  const plant = (ident) => {
    const out = mkdtempSync(join(tmpdir(), 'snap-pre-'));
    writeFileSync(join(out, 'snapshot.json'),
      `${JSON.stringify({ format: 'blocktracer/chain-snapshot@2', provenance: ident }, null, 2)}\n`);
    return out;
  };
  const runInto = (root, out) => {
    try {
      const stdout = execFileSync(process.execPath,
        [TOOL, '--bucket-dir', root, '--chain', CHAIN, '--out', out, '--json'],
        { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
      return { ok: true, report: JSON.parse(stdout) };
    } catch (err) {
      return { ok: false, stderr: String(err.stderr ?? '') };
    }
  };

  // ARM 1 -- a DIFFERENT rollup under the same slug is refused, and named.
  const differentOut = plant({
    l1ChainId: 11155111, rollupVersion: 1821665230,
    rollupAddress: '0xd73a91bdcf6891c7642f3e460036e1ef2cc23178',
  });
  const r1 = runInto(bucketRoot, differentOut);
  check('refuses: --out holds a DIFFERENT rollup under the same slug',
    !r1.ok && r1.stderr.includes('DIFFERENT rollup'),
    r1.ok ? 'it OVERWROTE a corpus from another rollup' : r1.stderr.slice(0, 200));
  check('...and names the field that differs, with both values',
    !r1.ok && r1.stderr.includes('rollupVersion') && r1.stderr.includes('1821665230'),
    r1.stderr?.slice(0, 200));
  rmSync(differentOut, { recursive: true, force: true });

  // ARM 2 -- THE CONTROL. The SAME rollup must still be written, or this guard is
  // just "refuse if the directory is occupied".
  const sameOut = plant(sameRollup);
  const r2 = runInto(bucketRoot, sameOut);
  check('CONTROL: the SAME rollup is accepted, so the guard compares identity and not occupancy',
    r2.ok, r2.ok ? '' : `refused its own chain: ${r2.stderr?.slice(0, 200)}`);
  rmSync(sameOut, { recursive: true, force: true });

  // ARM 3 -- A COMPARISON THAT DID NOT HAPPEN IS NOT AGREEMENT. An existing snapshot
  // stating none of the three identity fields cannot be shown to be the same rollup,
  // so it refuses rather than being waved through. Without this the guard would be
  // bypassed by exactly the oldest corpora: the ones most likely to predate the fields
  // and the most expensive to overwrite.
  const blindOut = plant({ chain: CHAIN, ordering: 'blockIndex' });
  const r3 = runInto(bucketRoot, blindOut);
  check('refuses: --out holds a snapshot stating no rollup identity at all',
    !r3.ok && r3.stderr.includes('is not agreement'),
    r3.ok ? 'it overwrote a corpus it could not identify' : r3.stderr.slice(0, 200));
  rmSync(blindOut, { recursive: true, force: true });

  rmSync(bucketRoot, { recursive: true, force: true });
}

console.log(`\nassertion count: ${asserted} (declared ${BASE_ARMS})`);
if (asserted !== BASE_ARMS) {
  // RECONCILED TO THE CODE, NOT THE OTHER WAY AROUND. A short tally means arms
  // did not run; editing `BASE_ARMS` down to match would cement that silence.
  console.log(`snapshot-from-ingest-selftest: REFUSED — it declares ${BASE_ARMS} assertion(s) `
    + `and ran ${asserted}. An arm that did not run is not an arm that passed.`);
  process.exit(1);
}
console.log(failures === 0 ? 'snapshot-from-ingest-selftest: PASS' : `snapshot-from-ingest-selftest: ${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
