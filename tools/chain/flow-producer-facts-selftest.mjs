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

import { INSTRUCTION_SET, costVectorForRow, rolesForRow } from './lib/flow-producer-facts.mjs';

// The assertion count this suite declares, which `refusal-selftest.mjs` cross-checks
// against the `chain-selftest` header. No host configurations, so the base is the total.
const BASE_ARMS = 9;

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

// ═══════════════════════════════════════════════════════════════════════════════════════
//  THE DECLARED EXECUTABLE FORMAT (Chain-Delivery DEL-6, 2026-10-22)
// ═══════════════════════════════════════════════════════════════════════════════════════
//
// Flow's registry row carried no `vm` while four bytecode chains carried one, and the
// cause was two defects in one place: the token named the INTERPRETER rather than the
// format, and nothing imported the constant, so it could not have reached a row even
// spelled correctly. Configuration.md §2.1 now defines the member as the executable,
// formally defined format a program is executed from — a bytecode instruction set being
// the commonest kind of such format and not the only one — and `provenance.vm` is the
// route that does not run through an instruction listing.
//
// WHAT IS CHECKED HERE AND WHAT IS CHECKED ELSEWHERE. These three arms are about the
// TOKEN and about this producer SPELLING the member. That the member then reaches a
// registry row is a reader fact, and it is driven end to end through the real producer
// and the shipping validator in `tests/tchainprofile.nim`; it is not restated here.
//
// THE FOUR REFERENCE MODULES ARE READ AS TEXT, AND THAT IS A CHECK RATHER THAN A SEAM.
// The naming convention is written down nowhere as data — it is stated in the comments of
// the modules that hold the tokens — so the arm reads those modules' source and derives
// it. No producer imports another producer's facts, nothing dispatches per chain, and
// this file is a test: ING-7's rule is about the producer path and is untouched (DEL-7 is
// where any extraction happens).
const read = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');
const REFERENCE_MODULES = ['./lib/eth-producer-facts.mjs', './lib/solana-producer-facts.mjs',
                           './lib/starknet-producer-facts.mjs', './lib/sui-producer-facts.mjs'];
/** The INSTRUCTION_SET a facts module exports, and every schema-ish token beside it. */
const tokensOf = (src) => ({
  isa: (/^export const INSTRUCTION_SET = '([^']+)';/m.exec(src) ?? [])[1],
  siblings: [...src.matchAll(/^export const (?:POSITION_LANGUAGE|[A-Z_]*STREAM_SCHEMA) = '([^']+)';/gm)]
    .map((m) => m[1]),
});

// RULE 1, read off the Ethereum and Starknet notes: the token names the FORMAT, never the
// chain and never the engine that runs it. "`evm` AND NOT `ethereum-evm`" because the
// table "is the same on Base, Arbitrum and every other EVM instance"; `cairo` "is the same
// on every chain that runs the Cairo VM, so it names no chain". Asked one step further
// out, that excludes the executor too — and the test is per hyphen SEGMENT rather than per
// substring, because `evm` would fail a substring test for `vm` while being the
// convention's own example of a correct token.
const EXECUTOR_WORDS = new Set(['interpreter', 'runtime', 'engine', 'executor', 'machine',
                                'vm', 'node', 'client', 'replay', 'replayer']);
const namesAnExecutor = (isa) => isa.split('-').some((seg) => EXECUTOR_WORDS.has(seg));
// RULE 2: the token's STEM is the stem its sibling schema tokens are built from — `evm`
// under `evm-disassembly`, `cairo` under `cairo-casm`, `sbf` under `sbf-disassembly`,
// `move` under `move-disassembly`. A suffix on the token names the FORM the artifact is
// in, which is why `cairo-casm` is qualified where `cairo` is not.
const stemOf = (token) => token.split(/[-/]/)[0];
const keepsItsStem = (t) => t.isa !== undefined && t.siblings.length > 0
  && t.siblings.every((sib) => stemOf(sib) === stemOf(t.isa));

arm('the declared format names the format and not the executor, and keeps its stem', () => {
  const flow = tokensOf(read('./lib/flow-producer-facts.mjs'));
  assert.equal(flow.isa, INSTRUCTION_SET, 'the module under test exports what it declares');
  assert.ok(!namesAnExecutor(flow.isa), `${flow.isa} names an executor`);
  assert.ok(keepsItsStem(flow), `${flow.isa} does not share its siblings' stem: ${flow.siblings}`);
  // AND THE CONVENTION IS DERIVED RATHER THAN ASSERTED: the same two rules hold for every
  // chain that already declares one. Four of them, read out of their own modules — an
  // empty set would make both rules hold vacuously, so the population is asserted.
  const refs = REFERENCE_MODULES.map((m) => tokensOf(read(m)));
  assert.equal(refs.length, 4);
  for (const r of refs) {
    assert.ok(r.isa, 'every reference module exports an INSTRUCTION_SET');
    assert.ok(!namesAnExecutor(r.isa), `${r.isa} names an executor`);
    assert.ok(keepsItsStem(r), `${r.isa} does not share its siblings' stem: ${r.siblings}`);
  }
});

arm('control: the token this module used to export fails both rules it is checked by', () => {
  // `cadence-interpreter` is what this module exported until 2026-10-22. It fails rule 1
  // on its own second segment and rule 2 against a sibling of another stem — so neither
  // rule above is an assertion that cannot fail, and what was wrong with the old token is
  // exactly what the arm above measures.
  assert.ok(namesAnExecutor('cadence-interpreter'));
  assert.ok(!keepsItsStem({ isa: 'cadence-interpreter', siblings: ['evm-disassembly'] }));
  const flow = tokensOf(read('./lib/flow-producer-facts.mjs'));
  assert.ok(!namesAnExecutor(flow.isa), 'and the live token passes the rule the old one fails');
  // …and a bare-stem token still passes rule 2, so rule 2 is not secretly a ban on bare
  // tokens: that is how `evm`, `sbf`, `cairo` and `move` are spelled.
  assert.ok(keepsItsStem({ isa: 'cadence', siblings: ['cadence-positions/1'] }));
});

arm('the producer SPELLS the member, through the module rather than as a literal', () => {
  // THE DEFECT THIS ARM EXISTS FOR, measured 2026-10-21: the constant was exported and
  // imported by nothing — 0 occurrences in the producer — so no spelling of it could have
  // reached a row. An exported constant with no importer is invisible to every other check
  // in this repository, which is why this check is on the PRODUCER's text.
  const src = read('./produce-flow-snapshot.mjs');
  const imported = /import \{[^}]*\bINSTRUCTION_SET\b[^}]*\} from '\.\/lib\/flow-producer-facts\.mjs';/s;
  assert.ok(imported.test(src), 'the producer imports INSTRUCTION_SET from its facts module');
  // …inside the provenance literal, which is where the reader looks for it.
  const MEMBER = 'vm: { instructionSet: INSTRUCTION_SET }';
  const prov = src.indexOf('provenance: {');
  const win = src.indexOf('window: {', prov);
  const member = src.indexOf(MEMBER);
  assert.ok(prov > 0 && win > prov, 'the provenance literal is found');
  assert.ok(member > prov && member < win, 'provenance declares `vm` through the constant');
  // …and the token is not ALSO written down here, which would be a second place for it.
  assert.ok(!src.includes(INSTRUCTION_SET),
            `the producer restates the token '${INSTRUCTION_SET}' instead of importing it`);
  // CONTROL, in the same arm: each half is RE-EVALUATED — the same predicate, not a proxy
  // for it — against a mutated copy of the producer, and shown to be FALSE there, so
  // neither is an assertion that cannot fail. The first plant is the live defect this work
  // closed, the member absent; the second is the token inlined. (Asserting merely that the
  // deleted string is gone would be a tautology, which is the shape this file is checking
  // the producer for and must not adopt itself.)
  const deleted = src.replace(MEMBER, '');
  const dProv = deleted.indexOf('provenance: {');
  const dWin = deleted.indexOf('window: {', dProv);
  const dMember = deleted.indexOf(MEMBER);
  assert.ok(!(dMember > dProv && dMember < dWin),
            'with the member deleted, the position check above is false');
  assert.ok(src.replace(MEMBER, `vm: { instructionSet: '${INSTRUCTION_SET}' }`)
               .includes(INSTRUCTION_SET),
            'with the token inlined, the no-literal check above is false');
});

if (passed !== BASE_ARMS) {
  console.error(`flow-producer-facts-selftest: ${passed} arm(s) ran and ${BASE_ARMS} are declared`);
  process.exit(1);
}
console.log(`flow-producer-facts-selftest: ${passed} passed`);
