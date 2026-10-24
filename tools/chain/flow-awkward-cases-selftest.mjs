#!/usr/bin/env node
//
// flow-awkward-cases-selftest.mjs — the Flow conformance fixture holds the cases it lists.
//
// Recorders/Recorder-Flow.milestones.org CXP-FLOW-4 asks for a conformance fixture over
// the four cases Flow makes awkward: a three-role transaction, a resource moved across
// accounts, a transaction that fails a pre-condition, and a contract updated after the
// transaction ran. `fixtures/chain-inputs/flow-mainnet/awkward-cases.json` names one
// mainnet transaction per case. This suite asserts, from the chain's own record in the
// committed block listings and transcripts, that each IS the case it is listed as — so a
// re-capture that swapped a transaction for an ordinary one fails here, not silently in a
// tree that still conforms. What the producer PUBLISHES for each case is
// `flow-awkward-cases-check.mjs`'s, over the built trees.
//
// Every predicate runs beside a control: the manifest's control transaction, or the newer
// code for the updated contract, on which the same predicate is false. Offline: only node
// and this repository.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';

// The assertion count this suite declares, which `refusal-selftest.mjs` cross-checks
// against the `chain-selftest` header. No host configurations, so the base is the total.
const BASE_ARMS = 10;

let passed = 0;
const arm = (name, fn) => {
  fn();
  passed += 1;
  console.log(`  ok  ${name}`);
};

const root = new URL('../../fixtures/chain-inputs/flow-mainnet/', import.meta.url);
const readJson = (rel) => JSON.parse(readFileSync(new URL(rel, root)));
const manifest = readJson('awkward-cases.json');
const byCase = Object.fromEntries(manifest.cases.map((c) => [c.case, c]));
const listing = (ref) => readJson(`${ref.block}/block.json`).transactions
  .find((t) => t.id === ref.tx);
const transcript = (ref) => JSON.parse(gunzipSync(
  readFileSync(new URL(`${ref.block}/${ref.tx}/inputs.json.gz`, root))));

// ── the predicates, each a statement about the chain's record of one transaction ─────

// Three roles: the payer is an account that neither proposed nor authorized, so the fee,
// the sequence number and the authority come from different places.
const threeRoles = (t) => new Set([t.payer, t.proposer, ...t.authorizers]).size >= 3
  && !t.authorizers.includes(t.payer);

// A resource across accounts: one NFT, by its UUID, leaves one account and arrives in a
// different one. The fee vault that every transaction moves from its payer to FlowFees is
// a fungible-token vault and is deliberately not counted, so the control can fail.
const NFT_EVENT = /^A\.1d7e57aa55817448\.NonFungibleToken\.(Withdrawn|Deposited)\(.*\buuid: (\d+), (?:from|to): (0x[0-9a-f]+|nil)/;
const nftMoves = (tr) => {
  const out = { Withdrawn: new Map(), Deposited: new Map() };
  for (const e of tr.onChain.events) {
    const m = NFT_EVENT.exec(e.value);
    if (m && m[3] !== 'nil') out[m[1]].set(m[2], m[3]);
  }
  return [...out.Withdrawn].filter(([uuid, from]) => out.Deposited.has(uuid)
    && out.Deposited.get(uuid) !== from);
};

const preConditionFailed = (tr) => tr.onChain.failed === true
  && /error: pre-condition failed: /.test(tr.onChain.errorMessage ?? '');

// The executed code of a contract, as the transcript recorded its `code.<Name>` register.
const codeRegister = (tr, location) => {
  const [, address, name] = location.split('.');
  const key = Buffer.from(`code.${name}`).toString('hex');
  const r = tr.registers.find((x) => x.owner === address && x.key === key);
  return r?.present ? Buffer.from(r.value, 'base64') : null;
};
const sha3 = (bytes) => createHash('sha3-256').update(bytes).digest('hex');

// ── the arms ─────────────────────────────────────────────────────────────────────────

arm('the manifest lists the four cases, each a user transaction of its block with a '
    + 'committed transcript', () => {
  assert.deepEqual(manifest.cases.map((c) => c.case),
                   ['three-roles', 'nft-across-accounts', 'pre-condition-failed',
                    'contract-updated-after']);
  for (const c of manifest.cases) {
    for (const ref of [c, c.control].filter(Boolean)) {
      const t = listing(ref);
      assert.ok(t && !t.system, `${ref.tx} is a user transaction of block ${ref.block}`);
      const tr = transcript(ref);
      assert.equal(tr.transactionId, ref.tx);
      assert.equal(tr.blockId, readJson(`${ref.block}/block.json`).id);
    }
  }
});

arm('three-roles: payer, proposer and authorizers are three accounts, the payer '
    + 'authorizing nothing', () => {
  assert.ok(threeRoles(listing(byCase['three-roles'])));
});

arm('control: one account in every role is not three roles', () => {
  assert.ok(!threeRoles(listing(byCase['three-roles'].control)));
});

arm('nft-across-accounts: an NFT withdrawn from one account is deposited, by the same '
    + 'UUID, into another', () => {
  const moves = nftMoves(transcript(byCase['nft-across-accounts']));
  assert.equal(moves.length, 1);
});

arm('control: a transaction whose only movement is the fee vault moves no NFT', () => {
  const ctl = transcript(byCase['nft-across-accounts'].control);
  assert.ok(ctl.onChain.events.some((e) => /FungibleToken\.Withdrawn/.test(e.type)),
            'the control does move a vault, so the predicate is what excludes it');
  assert.equal(nftMoves(ctl).length, 0);
});

arm('pre-condition-failed: the chain failed the transaction on a pre-condition', () => {
  assert.ok(preConditionFailed(transcript(byCase['pre-condition-failed'])));
});

arm('control: a transaction the chain failed for its payer\'s balance is not a '
    + 'pre-condition failure', () => {
  const ctl = transcript(byCase['pre-condition-failed'].control);
  assert.equal(ctl.onChain.failed, true, 'the control failed too, so failing is not enough');
  assert.ok(!preConditionFailed(ctl));
});

const upd = byCase['contract-updated-after'];
arm('contract-updated-after: the contract was updated at a height above the '
    + 'transaction\'s block', () => {
  assert.ok(upd.update.height > upd.block);
  assert.ok(codeRegister(transcript(upd), upd.contract) !== null,
            'the transcript recorded the code the transaction executed');
});

arm('contract-updated-after: the code the transaction executed is not the code the '
    + 'update installed', () => {
  assert.notEqual(sha3(codeRegister(transcript(upd), upd.contract)), upd.update.codeHash);
});

arm('control: the newer source hashes to the update event\'s codeHash, so the hash is '
    + 'the chain\'s and the inequality is the update', () => {
  const newer = readFileSync(new URL(upd.update.source, root));
  assert.equal(sha3(newer), upd.update.codeHash);
  assert.notDeepEqual(newer, codeRegister(transcript(upd), upd.contract));
});

if (passed !== BASE_ARMS) {
  console.error(`flow-awkward-cases-selftest: ${passed} arm(s) ran and ${BASE_ARMS} are declared`);
  process.exit(1);
}
console.log(`flow-awkward-cases-selftest: ${passed} passed`);
