#!/usr/bin/env node
//
// solana-producer-selftest.mjs — the Solana producer's row facts and its committed inputs,
// asserted. Recorder-Solana CXP-SOL-3.
//
// Offline and toolchain-free: every arm reads the committed window under
// fixtures/chain-inputs/solana-mainnet/ and needs only node. Traced rows need the recorder
// and are exercised by `nix build .#sol-capture-tree` (tools/chain/nix/sol.nix). Every arm
// runs beside a control, so a function returning a constant fails one side.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cpSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  PRESTATE_STRATEGY, VERIFICATION, addressHistoryFor, costVectorForRow, executionsForRow, payloadForRow, reachReasonFor, rolesForRow,
} from './lib/solana-producer-facts.mjs';
import { REFUSAL_REASON_IDS } from './lib/refusal.mjs';
import { CELLS, census } from './lib/solana-corpus-census.mjs';

// The assertion count this suite declares, which `refusal-selftest.mjs` cross-checks
// against the `chain-selftest` header. No host configurations, so the base is the total.
const BASE_ARMS = 12;

let passed = 0;
const arm = (name, fn) => {
  fn();
  passed += 1;
  console.log(`  ok  ${name}`);
};

const FIXTURE = new URL('../../fixtures/chain-inputs/solana-mainnet/459262600-459262602/',
  import.meta.url).pathname;
const rows = readdirSync(join(FIXTURE, 'blocks'))
  .flatMap((f) => JSON.parse(readFileSync(join(FIXTURE, 'blocks', f), 'utf8')).transactions);
const nonVote = rows.filter((t) => !t.vote);
const COMPUTE_BUDGET = 'ComputeBudget111111111111111111111111111111';

arm('the fee, compute units and cost units are three named entries, each the chain\'s figure', () => {
  const t = nonVote.find((x) => x.costUnits !== undefined && x.costUnits !== null);
  const v = costVectorForRow({ fee: t.fee, computeUnitsConsumed: t.computeUnitsConsumed, costUnits: t.costUnits });
  assert.deepEqual(v.map((e) => e.name), ['fee', 'computeUnits', 'costUnits']);
  assert.equal(v[0].used, String(t.fee));
  assert.equal(v[0].unit, 'lamport');
  assert.equal(v[1].used, String(t.computeUnitsConsumed));
  assert.notEqual(v[0].unit, v[1].unit);
  // Control: with no cost units stated, no third entry is invented.
  assert.equal(costVectorForRow({ fee: t.fee, computeUnitsConsumed: t.computeUnitsConsumed }).length, 2);
});

arm('the sender is the fee payer the message names, not a constant', () => {
  const [a, b] = nonVote.filter((x, i, all) => all.findIndex((y) => y.feePayer === x.feePayer) === i);
  assert.deepEqual(rolesForRow(a), [{ role: 'sender', address: a.feePayer }]);
  // Control: a different transaction's payer gives a different sender.
  assert.notEqual(rolesForRow(b)[0].address, rolesForRow(a)[0].address);
  assert.deepEqual(rolesForRow({}), []);
});

arm('the target is the first top-level program that is not ComputeBudget', () => {
  const withBudget = nonVote.find((x) => x.programs[0] === COMPUTE_BUDGET && x.programs.some((p) => p !== COMPUTE_BUDGET));
  assert.equal(payloadForRow(withBudget).target, withBudget.programs.find((p) => p !== COMPUTE_BUDGET));
  // Control: a transaction whose first program is not ComputeBudget targets that one.
  const plain = nonVote.find((x) => x.programs[0] !== COMPUTE_BUDGET);
  assert.equal(payloadForRow(plain).target, plain.programs[0]);
  assert.equal(payloadForRow(plain).selector, '');
});

arm('an untraced row states its reason on its one execution; a traced row leaves it unreasoned', () => {
  assert.deepEqual(executionsForRow('refused'), [{ selector: 'transaction', reason: 'refused' }]);
  assert.deepEqual(executionsForRow(null), [{ selector: 'transaction' }]);
});

arm('the committed inputs unpack to bundles matching the digest packed beside each', () => {
  const work = mkdtempSync(join(tmpdir(), 'sol-fixture-'));
  try {
    const tool = new URL('./sol-fixture.mjs', import.meta.url).pathname;
    execFileSync(process.execPath, [tool, 'unpack', '--fixture', FIXTURE, '--out', join(work, 'ok')]);
    assert.ok(readdirSync(join(work, 'ok', 'bundles')).length > 0);
    // Control: one byte of one stored object changed, and unpack refuses.
    const fx = join(work, 'fx');
    cpSync(FIXTURE, fx, { recursive: true });
    const obj = readdirSync(join(fx, 'objects'))[0];
    const p = join(fx, 'objects', obj);
    const o = JSON.parse(readFileSync(p, 'utf8'));
    if (Array.isArray(o)) o.push(null); else o.lamports = (o.lamports ?? 0) + 1;
    writeFileSync(p, JSON.stringify(o));
    assert.throws(() => execFileSync(process.execPath, [tool, 'unpack', '--fixture', fx, '--out', join(work, 'bad')],
      { stdio: 'pipe' }));
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
});

arm('the prestate token is `forward-capture`, and the contract\'s closed set holds it', () => {
  // Until 2026-10-22 this arm asserted the OPPOSITE — that the token was outside the set —
  // so that it would go red the day §1.4 gained the row and force this file and sol.nix's
  // place in produced-captures to be revisited. It went red that day and was turned round.
  const contract = JSON.parse(readFileSync(new URL('./snapshot-contract.json', import.meta.url), 'utf8'));
  assert.equal(PRESTATE_STRATEGY, 'forward-capture');
  assert.equal(contract.prestateStrategies.tokens.includes(PRESTATE_STRATEGY), true);
  // Control: the set is a closed set and not a free-text field — a token no §1.4 row
  // states is not in it.
  assert.equal(contract.prestateStrategies.tokens.includes('balances-only'), false);
});

arm('the floor reason names the capture start, and the verification sentence names the refusal', () => {
  // Both are optional contract members the reader publishes verbatim (§5.3). A node-limit
  // sentence would misstate a forward capture, and a policy without its refusal would
  // read as a promise every transaction is traced.
  const contract = JSON.parse(readFileSync(new URL('./snapshot-contract.json', import.meta.url), 'utf8'));
  const text = JSON.stringify(contract);
  assert.ok(text.includes('"reachReason"') && text.includes('"verification"'));
  assert.match(reachReasonFor(459262600, 459262600), /^this capture began reading account state at slot 459262600\b/);
  // A later published slice names where it publishes from AND where the capture began.
  const slice = reachReasonFor(459262600, 459262601);
  assert.match(slice, /publishes from slot 459262601\b.*began reading account state at slot 459262600\b/);
  assert.match(VERIFICATION, /refused, never guessed/);
});

arm('address history is the committed answer below the window, refusing what would misstate it', () => {
  // Spine need (f). The committed answer must pass as it stands, and each refusal bites.
  const answer = JSON.parse(readFileSync(join(FIXTURE, 'history', '459262601-459262601.json'), 'utf8'));
  const rowHashes = new Set(JSON.parse(readFileSync(join(FIXTURE, 'blocks', '459262601.json'), 'utf8'))
    .transactions.map((r) => r.signature));
  const paged = new Set(Object.keys(answer.addresses));
  const kept = addressHistoryFor(answer, rowHashes, paged, 459262601);
  assert.equal(kept.length, paged.size);
  assert.ok(kept.every((a) => a.entries.every((e) => e.blockNumber < 459262601)));
  const [addr] = [...paged];
  const one = (entries) => ({ addresses: { [addr]: { ...answer.addresses[addr], entries } } });
  const e0 = answer.addresses[addr].entries[0];
  assert.throws(() => addressHistoryFor(one([{ ...e0, blockNumber: 459262601 }]), rowHashes, paged, 459262601), /not below/);
  assert.throws(() => addressHistoryFor(one([{ ...e0, txHash: [...rowHashes][0] }]), rowHashes, paged, 459262601), /already a published row/);
  assert.throws(() => addressHistoryFor(one([{ ...e0, blockNumber: 5 }, e0]), rowHashes, paged, 459262601), /newest first/);
  // An address without a page gets no history: history never creates a page.
  assert.deepEqual(addressHistoryFor(one([e0]), rowHashes, new Set(), 459262601), []);
});


// ── the producer itself, over the committed window ──────────────────────────────────────
//
// Run with a STUB ct-print that fails loudly if invoked: the unpacked inputs carry replay
// bundles and no container, so every row the recorder traced arrives as
// `no-container-written` and the stub must never run. That keeps these two arms offline
// and node-only, and a producer that started reading a container here would turn them red
// rather than quietly needing a toolchain.
function produce(mutateResults, mutateBlocks) {
  const work = mkdtempSync(join(tmpdir(), 'sol-produce-'));
  const tool = (name) => new URL(`./${name}`, import.meta.url).pathname;
  execFileSync(process.execPath, [tool('sol-fixture.mjs'), 'unpack', '--fixture', FIXTURE, '--out', join(work, 'cap')]);
  const stub = join(work, 'ct-print');
  writeFileSync(stub, '#!/bin/sh\necho "ct-print stub invoked" >&2\nexit 99\n', { mode: 0o755 });
  if (mutateResults) {
    const p = join(work, 'cap', 'results.jsonl');
    writeFileSync(p, mutateResults(readFileSync(p, 'utf8')));
  }
  if (mutateBlocks) {
    const p = join(work, 'cap', 'blocks.jsonl');
    writeFileSync(p, mutateBlocks(readFileSync(p, 'utf8')));
  }
  try {
    execFileSync(process.execPath, [tool('produce-sol-snapshot.mjs'), '--capture', join(work, 'cap'),
      '--ct-print', stub, '--recorder-commit', 'c3ca118c312661ae51a68afcccaa49376fdc91dd',
      '--from', '459262600', '--to', '459262602', '--out', join(work, 'snap')], { stdio: 'pipe' });
    return { ok: true, snapshot: JSON.parse(readFileSync(join(work, 'snap', 'snapshot.json'), 'utf8')) };
  } catch (e) {
    return { ok: false, stderr: String(e.stderr ?? '') + String(e.stdout ?? '') };
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
const produced = produce(null);

arm('test_an_unchecked_trace_is_not_published: one `unchecked` verdict refuses the whole tree', () => {
  // CXP-SOL-3. The check is mandatory on Solana and the contract has no `unchecked` value,
  // so the producer refuses rather than publishing the trace or a reason it did not have.
  let flipped = 0;
  const refused = produce((text) => text.split('\n').map((l) => {
    if (flipped === 0 && l.includes('"status":"match"')) { flipped++; return l.replace('"status":"match"', '"status":"unchecked"'); }
    return l;
  }).join('\n'));
  assert.equal(flipped, 1);
  assert.equal(refused.ok, false);
  assert.match(refused.stderr, /unchecked/);
  assert.doesNotMatch(refused.stderr, /ct-print stub invoked/);
  // Control: the same capture with its `match` verdicts publishes, so the refusal is the verdict's.
  assert.equal(produced.ok, true, produced.stderr);
});

arm('test_a_mostly_refused_window_still_enumerates_completely: a row per transaction the chain lists', () => {
  // CXP-SOL-3. The window is mostly refused (no recorder here, no carried prestate for most),
  // and still every transaction of every slot's getBlock is a row with a reason. The count
  // is the CHAIN's — the committed block listings, votes included — never the tree's own.
  const chainCount = rows.length;
  const s = produced.snapshot;
  assert.ok(chainCount > 0);
  assert.equal(s.transactions.length, chainCount);
  assert.equal(s.counts.accountedFor, chainCount);
  const untraced = s.transactions.filter((t) => t.outcome !== 'replayed');
  assert.ok(untraced.length / chainCount > 0.9, `${untraced.length} of ${chainCount} untraced`);
  assert.ok(untraced.every((t) => REFUSAL_REASON_IDS.includes(t.refusalReason)),
    'every untraced row carries a reason from the closed set');
  assert.deepEqual(new Set(s.transactions.map((t) => t.txHash)), new Set(rows.map((t) => t.signature)));
  // Control: a capture that lost one transaction still produces a self-consistent tree
  // (its own tally closes), and the CHAIN's count is what exposes the shortfall.
  const short = produce(null, (text) => text.split('\n').map((l, i) => {
    if (i !== 0 || !l) return l;
    const b = JSON.parse(l);
    b.transactions = b.transactions.slice(1);
    return JSON.stringify(b);
  }).join('\n'));
  assert.equal(short.ok, true, short.stderr);
  assert.equal(short.snapshot.counts.accountedFor, short.snapshot.transactions.length);
  assert.equal(short.snapshot.transactions.length, chainCount - 1);
});

// ── the divergence corpus, per cell (CXP-SOL-4) ─────────────────────────────────────────
function pinnedBundles() {
  const work = mkdtempSync(join(tmpdir(), 'sol-census-'));
  try {
    execFileSync(process.execPath, [new URL('./sol-fixture.mjs', import.meta.url).pathname,
      'unpack', '--fixture', FIXTURE, '--out', join(work, 'cap')]);
    const dir = join(work, 'cap', 'bundles');
    return readdirSync(dir).map((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')));
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
const bundles = pinnedBundles();

arm('the committed corpus census is the census of the pinned bundles, every cell named', () => {
  const committed = JSON.parse(readFileSync(new URL('./measurements/sol-corpus-census.json', import.meta.url), 'utf8'));
  const fresh = census(bundles);
  const { _comment, ...stated } = committed;
  assert.deepEqual(stated, fresh, 'measurements/sol-corpus-census.json has drifted from the pinned bundles');
  // Every cell is present — the two era cells plus one per CELLS row — and an
  // uncovered one carries its reason rather than being dropped.
  assert.equal(fresh.cells.length, CELLS.length + 2);
  assert.equal(fresh.covered + fresh.uncovered, fresh.cells.length);
  assert.ok(fresh.cells.every((c) => c.covered > 0 || (typeof c.uncovered === 'string' && c.uncovered.length > 0)));
  assert.ok(fresh.uncovered > 0, 'the pinned corpus is known to leave cells uncovered; a census reporting none is wrong');
});

arm('a cell loses its coverage when the bundles that reach it are removed', () => {
  // Control: the census is computed from the bundles, not stated. Remove every bundle
  // that invokes a native program and that cell, covered above, reads uncovered.
  const cell = '4.4 builtin: a native program invoked';
  assert.ok(census(bundles).cells.find((c) => c.cell === cell).covered > 0);
  const NATIVE = 'NativeLoader1111111111111111111111111111111';
  const without = bundles.filter((b) => !b.accounts.some((a) => a.executable && a.owner === NATIVE
    && (b.transactions[0].meta.logMessages ?? []).some((l) => l.startsWith(`Program ${a.pubkey} invoke`))));
  assert.ok(without.length < bundles.length && without.length > 0);
  const after = census(without).cells.find((c) => c.cell === cell);
  assert.equal(after.covered, 0);
  assert.match(after.uncovered, /no pinned fixture/);
});
if (passed !== BASE_ARMS) {
  console.error(`FAIL — ${passed} of ${BASE_ARMS} declared arm(s) ran`);
  process.exit(1);
}
console.log(`\nPASS — ${passed} arm(s)`);
