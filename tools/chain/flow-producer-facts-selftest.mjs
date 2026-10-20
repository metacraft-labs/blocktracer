#!/usr/bin/env node
//
// flow-producer-facts-selftest.mjs — the Flow producer's row facts, asserted.
//
// Recorders/Recorder-Flow.milestones.org CXP-FLOW-3: proposer, payer and authorizers
// are published as three roles, none of them promoted to a synthesised `sender`; and
// the cost is Flow's fee vector, verbatim from the chain's own `FeesDeducted` event.
// Every arm has a control in the same run, so a function that returned a constant would
// fail one side or the other. Offline: only node and this repository.

import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';

import { costVectorForRow, rolesForRow } from './lib/flow-producer-facts.mjs';

// The assertion count this suite declares, which `refusal-selftest.mjs` cross-checks
// against the `chain-selftest` header. No host configurations, so the base is the total.
const BASE_ARMS = 6;

let passed = 0;
const arm = (name, fn) => {
  fn();
  passed += 1;
  console.log(`  ok  ${name}`);
};

// The committed block: one transaction whose three roles are three different accounts
// (well, two: the proposer is also the first authorizer), and one where one account
// fills every role.
const block = JSON.parse(readFileSync(
  new URL('../../fixtures/chain-inputs/flow-mainnet/168391034/block.json', import.meta.url)));
const [distinct, single] = block.transactions.filter((t) => !t.system);

arm('a distinct payer, proposer and authorizers publish three kinds of role', () => {
  const roles = rolesForRow(distinct);
  const byRole = (r) => roles.filter((x) => x.role === r).map((x) => x.address);
  assert.deepEqual(byRole('feePayer'), [distinct.payer]);
  assert.deepEqual(byRole('initiator'), [distinct.proposer]);
  assert.deepEqual(byRole('signer'), distinct.authorizers);
  assert.notEqual(distinct.payer, distinct.proposer, 'the fixture must keep them distinct');
});

arm('control: one account in every role is published once per role, not collapsed', () => {
  const roles = rolesForRow(single);
  assert.equal(new Set(roles.map((r) => r.address)).size, 1);
  assert.deepEqual(roles.map((r) => r.role), ['feePayer', 'initiator', 'signer']);
});

arm('no row carries a synthesised sender', () => {
  for (const t of block.transactions) {
    assert.ok(!rolesForRow(t).some((r) => r.role === 'sender'));
  }
});

arm('control: a protocol transaction with no payer publishes no payer role', () => {
  const system = block.transactions.find((t) => t.system);
  assert.ok(!rolesForRow(system).some((r) => r.role === 'feePayer'));
});

// The committed transcript of the first transaction: the chain's own result.
const transcript = JSON.parse(gunzipSync(readFileSync(new URL(
  `../../fixtures/chain-inputs/flow-mainnet/168391034/${distinct.id}/inputs.json.gz`,
  import.meta.url))).toString('utf8'));

arm('the fee vector is the FeesDeducted event\'s figures, verbatim', () => {
  const v = costVectorForRow({ computationUsed: transcript.onChain.computationUsed,
                              gasLimit: distinct.gasLimit, events: transcript.onChain.events });
  const fees = transcript.onChain.events.find((e) => e.type.endsWith('.FlowFees.FeesDeducted'));
  const by = (n) => v.find((x) => x.name === n)?.used;
  assert.ok(fees.value.includes(`amount: ${by('fee')}`), `${fees.value} vs ${by('fee')}`);
  assert.ok(fees.value.includes(`executionEffort: ${by('executionEffort')}`));
  assert.ok(fees.value.includes(`inclusionEffort: ${by('inclusionEffort')}`));
  assert.equal(by('computation'), String(transcript.onChain.computationUsed));
});

arm('control: a result with no FeesDeducted event publishes computation alone', () => {
  const v = costVectorForRow({ computationUsed: 7, gasLimit: 9999, events: [] });
  assert.deepEqual(v.map((x) => x.name), ['computation']);
});

if (passed !== BASE_ARMS) {
  console.error(`flow-producer-facts-selftest: ${passed} arm(s) ran and ${BASE_ARMS} are declared`);
  process.exit(1);
}
console.log(`flow-producer-facts-selftest: ${passed} passed`);
