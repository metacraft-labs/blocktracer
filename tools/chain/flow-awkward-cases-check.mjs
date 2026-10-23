#!/usr/bin/env node
//
// flow-awkward-cases-check.mjs — what the Flow producer published for each awkward case.
//
//   node tools/chain/flow-awkward-cases-check.mjs --trees <dir>
//
// <dir> holds one §5 tree per block `fixtures/chain-inputs/flow-mainnet/awkward-cases.json`
// names, at <dir>/<height> — `.#flow-awkward-cases` builds exactly that, with the recorder
// and replay helper the flake pins and no network. `flow-awkward-cases-selftest.mjs`
// establishes that each listed transaction IS its case, from the chain's record; this
// asserts the tree carries it the way the case needs: replayed and source-level, the three
// roles as three roles, the moved NFT's contract entered, the failing pre-condition reached
// at the position the chain's error names, and the updated contract's source the code that
// ran rather than the code deployed now. Each arm runs beside a control on which the same
// predicate is false. Exit 1 on any failure, 2 on a missing input.

import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';

const ARMS = 9;

const i = process.argv.indexOf('--trees');
const trees = i > 0 ? process.argv[i + 1] : undefined;
if (!trees || !existsSync(trees)) {
  console.error('flow-awkward-cases-check: --trees <dir of <height>/snapshot.json> is required');
  process.exit(2);
}

const root = new URL('../../fixtures/chain-inputs/flow-mainnet/', import.meta.url);
const manifest = JSON.parse(readFileSync(new URL('awkward-cases.json', root)));
const byCase = Object.fromEntries(manifest.cases.map((c) => [c.case, c]));
const transcript = (ref) => JSON.parse(gunzipSync(
  readFileSync(new URL(`${ref.block}/${ref.tx}/inputs.json.gz`, root))));

const snapshots = new Map();
const tree = (block) => {
  if (!snapshots.has(block)) {
    const p = join(trees, String(block), 'snapshot.json');
    if (!existsSync(p)) {
      console.error(`flow-awkward-cases-check: no tree for block ${block} at ${p}`);
      process.exit(2);
    }
    snapshots.set(block, JSON.parse(readFileSync(p, 'utf8')));
  }
  return snapshots.get(block);
};
const readTreeJson = (block, rel) => JSON.parse(readFileSync(join(trees, String(block), rel),
                                                             'utf8'));
const row = (ref) => tree(ref.block).transactions.find((r) => r.txHash === `0x${ref.tx}`);
const bundles = (ref) => readTreeJson(ref.block, row(ref).sourceBundles).bundles;
const locations = (ref) => bundles(ref).map((b) => b.location);
const sha256 = (b) => createHash('sha256').update(b).digest('hex');
const sha3 = (b) => createHash('sha3-256').update(b).digest('hex');

let passed = 0;
let failed = 0;
const arm = (name, fn) => {
  try {
    fn();
    passed += 1;
    console.log(`  ok    ${name}`);
  } catch (e) {
    failed += 1;
    console.log(`  FAIL  ${name}\n        ${e.message.split('\n')[0]}`);
  }
};

arm('every case is published replayed and source-level, with every effect reproduced', () => {
  for (const c of manifest.cases) {
    const r = row(c);
    assert.ok(r, `${c.case}: block ${c.block}'s tree has a row for ${c.tx}`);
    assert.equal(r.outcome, 'replayed', `${c.case}: ${r.reason}`);
    assert.equal(r.effects.reproduced, true, c.case);
    assert.equal(r.effects.mismatched, 0, c.case);
    assert.equal(r.recording.sourceLevel, true, c.case);
  }
});

arm('three-roles: the row publishes three accounts, and the fee payer is not a signer', () => {
  const roles = row(byCase['three-roles']).roles;
  assert.ok(new Set(roles.map((r) => r.address)).size >= 3);
  const payer = roles.find((r) => r.role === 'feePayer').address;
  assert.ok(!roles.some((r) => r.role === 'signer' && r.address === payer));
});

arm('control: the one-account transaction publishes one account in every role', () => {
  assert.equal(new Set(row(byCase['three-roles'].control).roles.map((r) => r.address)).size,
               1);
});

const NFT = 'A.1d7e57aa55817448.NonFungibleToken';
arm('nft-across-accounts: the recording entered the NFT standard and reproduced every '
    + 'event, the Withdrawn/Deposited pair with it', () => {
  const c = byCase['nft-across-accounts'];
  assert.ok(locations(c).includes(NFT));
  const events = transcript(c).onChain.events.length;
  // effects.matched counts each event, the status and the computation.
  assert.equal(row(c).effects.matched, events + 2);
});

arm('control: the fee-only transaction\'s recording never enters the NFT standard', () => {
  assert.ok(!locations(byCase['nft-across-accounts'].control).includes(NFT));
});

// The innermost source position the chain's error message names: `--> <addr>.<Name>:L:C`
// for a contract, `--> <tx id>:L:C` for the transaction's own script. Null when the
// message names none, which is the case for a transaction refused before it executed.
const failurePosition = (message) => {
  const all = [...(message ?? '').matchAll(/--> ([0-9a-f]{16})\.(\w+):(\d+):\d+/g)];
  if (all.length === 0) return null;
  const [, address, name, line] = all[all.length - 1];
  return { path: `./sources/A.${address}.${name}.cdc`, line: Number(line) };
};

arm('pre-condition-failed: published as failed, and the recording holds a step at the '
    + 'pre-condition the chain\'s error names', () => {
  const c = byCase['pre-condition-failed'];
  assert.equal(row(c).revertCode, 1);
  const at = failurePosition(transcript(c).onChain.errorMessage);
  assert.ok(at, 'the error names a contract position');
  const pos = readTreeJson(c.block, row(c).positions);
  const pathId = pos.paths.indexOf(at.path);
  assert.ok(pathId >= 0, `${at.path} is a path of the recording`);
  assert.ok(pos.pathId.some((p, k) => p === pathId && pos.line[k] === at.line),
            `a step at ${at.path}:${at.line}`);
});

arm('control: the balance failure names no position, so the lookup can come back empty', () => {
  const ctl = byCase['pre-condition-failed'].control;
  assert.equal(row(ctl).revertCode, 1);
  assert.equal(failurePosition(transcript(ctl).onChain.errorMessage), null);
});

const upd = byCase['contract-updated-after'];
const published = () => {
  const b = bundles(upd).find((x) => x.location === upd.contract);
  const [file] = Object.values(b.files);
  return { b, bytes: Buffer.from(file) };
};
arm('contract-updated-after: the published source is the code register the transaction '
    + 'read, not the code the later update installed', () => {
  const { b, bytes } = published();
  assert.equal(sha256(bytes), b.codeHash);
  const art = row(upd).artifacts.find((a) => a.contractClassId === b.codeHash);
  assert.ok(art?.resolved, 'the row resolves that artifact');
  const [, address, name] = upd.contract.split('.');
  const key = Buffer.from(`code.${name}`).toString('hex');
  const reg = transcript(upd).registers.find((r) => r.owner === address && r.key === key);
  assert.deepEqual(bytes, Buffer.from(reg.value, 'base64'));
  assert.notEqual(sha3(bytes), upd.update.codeHash);
});

arm('control: the newer source, which hashes to the update\'s codeHash, is not what was '
    + 'published', () => {
  const newer = readFileSync(new URL(upd.update.source, root));
  assert.equal(sha3(newer), upd.update.codeHash);
  assert.notDeepEqual(published().bytes, newer);
});

if (passed + failed !== ARMS) {
  console.error(`flow-awkward-cases-check: ${passed + failed} arm(s) ran and ${ARMS} are declared`);
  process.exit(1);
}
console.log(`flow-awkward-cases-check: ${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
