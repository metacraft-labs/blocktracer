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

// The assertion count this suite declares, which `refusal-selftest.mjs` cross-checks
// against the `chain-selftest` header. No host configurations, so the base is the total.
const BASE_ARMS = 8;

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
  assert.equal(Object.keys(kept).length, paged.size);
  assert.ok(Object.values(kept).every((a) => a.entries.every((e) => e.blockNumber < 459262601)));
  const [addr] = [...paged];
  const one = (entries) => ({ addresses: { [addr]: { ...answer.addresses[addr], entries } } });
  const e0 = answer.addresses[addr].entries[0];
  assert.throws(() => addressHistoryFor(one([{ ...e0, blockNumber: 459262601 }]), rowHashes, paged, 459262601), /not below/);
  assert.throws(() => addressHistoryFor(one([{ ...e0, txHash: [...rowHashes][0] }]), rowHashes, paged, 459262601), /already a published row/);
  assert.throws(() => addressHistoryFor(one([{ ...e0, blockNumber: 5 }, e0]), rowHashes, paged, 459262601), /newest first/);
  // An address without a page gets no history: history never creates a page.
  assert.deepEqual(addressHistoryFor(one([e0]), rowHashes, new Set(), 459262601), {});
});

if (passed !== BASE_ARMS) {
  console.error(`FAIL — ${passed} of ${BASE_ARMS} declared arm(s) ran`);
  process.exit(1);
}
console.log(`\nPASS — ${passed} arm(s)`);
