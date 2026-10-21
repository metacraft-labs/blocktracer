#!/usr/bin/env node
// sui-producer-selftest.mjs — the Sui producer's facts and refusals, watched going red.
//
//   node tools/chain/sui-producer-selftest.mjs
//
// Offline and toolchain-free: no network, no recorder, no `ct-print`. Everything is
// driven from literals shaped exactly as Sui's GraphQL service and `sui replay` 1.81
// write them (field names and nesting copied from a mainnet transaction read on
// 2026-10-20). A TRACED row needs a container, which this repository refuses to commit,
// so traced rows are exercised by `just sui-range` against the network; this suite
// covers what can be decided without one:
//
//   §1  the facts module: roles (sponsored, self-paid, system), the cost vector's signed
//       rebate, the payload, and the declarations a reader must be told
//   §2  the effects comparison a traced row publishes, against a planted mismatch
//   §3  the version-addressed prestate read off the effects
//   §4  the producer end to end over a container-free window: the denominator is every
//       transaction the enumeration saw, and a broken window or a foreign recording is
//       refused rather than published around
//   §5  the endpoint-horizon probe's verdict: a rung that stops being served fails it,
//       and so does a control the endpoint answered
//
// Every arm that asserts a refusal or a distinction has a control beside it that takes
// the other branch, so the arm measures the rule and not the fixture
// (spec/Testing/Verification-Harness-Traps.md).

import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { graphqlUrlFor, inputVersionsOf } from './lib/sui-graphql.mjs';
import {
  CHAIN_SLUG, IDENTIFIER_ENCODING, MIN_TRACED_PROTOCOL, PRESTATE_STRATEGY, RECORDER,
  costVectorForRow, executionsForRow, payloadForRow, rolesForRow,
} from './lib/sui-producer-facts.mjs';
import { ACQUISITION_FORMAT, effectsFacts, main as produce } from './produce-sui-snapshot.mjs';
import { compareReadings } from './sui-horizon-probe.mjs';

let asserted = 0;
let failed = 0;
const ck = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`);
};
const test = (name) => console.error(`\n${name}`);

const A = `0x${'a'.repeat(64)}`;
const B = `0x${'b'.repeat(64)}`;
const ZERO = `0x${'0'.repeat(64)}`;

/** A transaction as `checkpointWithTransactions` returns it. */
const tx = ({ digest, sender = A, gasSponsor = A, status = 'SUCCESS', first } = {}) => ({
  digest,
  kind: 'ProgrammableTransaction',
  sender,
  gasSponsor,
  gasPrice: '750',
  gasBudget: '5000000',
  status,
  lamportVersion: 100,
  executionError: null,
  gasSummary: { computationCost: 1000, storageCost: 2000, storageRebate: 1500,
                nonRefundableStorageFee: 15 },
  effectsJson: {
    status: { success: status === 'SUCCESS' },
    gasUsed: { computationCost: '1000', storageCost: '2000', storageRebate: '1500',
               nonRefundableStorageFee: '15' },
    eventsDigest: 'EvT1',
    lamportVersion: '100',
    changedObjects: [
      { objectId: B, inputState: 'INPUT_OBJECT_STATE_EXISTS', inputVersion: '41' },
      { objectId: A, inputState: 'INPUT_OBJECT_STATE_DOES_NOT_EXIST' },
    ],
    unchangedConsensusObjects: [{ kind: 'READ_ONLY_ROOT', objectId: '0x6', version: '7' }],
    unchangedLoadedRuntimeObjects: [{ objectId: '0xd1', version: '9' }],
  },
  transactionJson: {
    kind: { programmableTransaction: { commands: [first ?? {
      moveCall: { package: B, module: 'pool', function: 'swap' } }] } },
    gasPayment: { owner: gasSponsor },
  },
});

test('§1 the facts module');
{
  const self = rolesForRow(tx({ digest: 'S' }));
  const sponsored = rolesForRow(tx({ digest: 'P', gasSponsor: B }));
  const system = rolesForRow(tx({ digest: 'Z', sender: ZERO, gasSponsor: ZERO }));
  ck('a sponsored transaction publishes sender, sponsor and fee payer as distinct roles',
     JSON.stringify(sponsored) === JSON.stringify([
       { role: 'sender', address: A }, { role: 'sponsor', address: B },
       { role: 'feePayer', address: B }]));
  ck('CONTROL: a self-paid one publishes no sponsor, so the role tracks the transaction',
     JSON.stringify(self) === JSON.stringify([
       { role: 'sender', address: A }, { role: 'feePayer', address: A }]));
  ck('a system transaction (sender and gas owner @0x0) publishes no role at all',
     system.length === 0);

  const cost = costVectorForRow({ computationCost: 1000, storageCost: 2000,
                                  storageRebate: 1500, nonRefundableStorageFee: 15,
                                  gasPrice: 750, gasBudget: 5000000 });
  const byName = Object.fromEntries(cost.map((c) => [c.name, c]));
  ck('the cost vector is four entries, not one',
     JSON.stringify(cost.map((c) => c.name))
       === '["computation","storage","storageRebate","nonRefundableStorageFee"]');
  ck('the storage rebate is its own NEGATIVE entry, not a subtraction left to the reader',
     byName.storageRebate.used === '-1500' && byName.storage.used === '2000');
  ck('CONTROL: a zero rebate is published as 0, not as -0',
     costVectorForRow({ storageRebate: 0 }).find((c) => c.name === 'storageRebate').used === '0');
  ck('computation carries its price and the budget as its limit',
     byName.computation.price === '750' && byName.computation.limit === '5000000');

  ck('the payload of a Move call names the call and its package',
     JSON.stringify(payloadForRow(tx({ digest: 'S' })))
       === JSON.stringify({ raw: '', selector: `${B}::pool::swap`, target: B }));
  ck('CONTROL: a block opening with a non-Move command names the command kind',
     payloadForRow(tx({ digest: 'S', first: { splitCoins: {} } })).selector === 'splitCoins');

  ck('the declarations: slug `sui`, a Move recorder, version-addressed prestate',
     CHAIN_SLUG === 'sui' && RECORDER.id === 'sui-move' && PRESTATE_STRATEGY === 'version-addressed');
  ck('digests are base58 and addresses hex — not base64 (codetracer-pm issue 2026-10-20)',
     IDENTIFIER_ENCODING.transaction === 'base58' && IDENTIFIER_ENCODING.block === 'base58'
     && IDENTIFIER_ENCODING.address === 'hex');
  ck('the traced floor is defined by protocol version 38', MIN_TRACED_PROTOCOL === 38);
  ck('an untraced execution carries its reason, a traced one does not',
     executionsForRow('why')[0].reason === 'why' && !('reason' in executionsForRow(null)[0]));
  ck('--node names resolve to GraphQL services and a URL passes through; garbage is refused',
     graphqlUrlFor('mainnet') === 'https://graphql.mainnet.sui.io/graphql'
     && graphqlUrlFor('https://x.invalid/graphql') === 'https://x.invalid/graphql'
     && (() => { try { graphqlUrlFor('mainnet-ish'); return false; } catch { return true; } })());
}

test('§2 the effects comparison');
{
  const published = tx({ digest: 'S' }).effectsJson;
  const replayed = { V2: { status: 'Success', events_digest: 'EvT1', lamport_version: 100,
    gas_used: { computationCost: '1000', storageCost: '2000', storageRebate: '1500',
                nonRefundableStorageFee: '15' } } };
  const same = effectsFacts(published, replayed);
  ck('a faithful replay reproduces all seven facts',
     same.reproduced && same.matched === 7 && same.mismatched === 0);
  const off = effectsFacts(published, { V2: { ...replayed.V2,
    gas_used: { ...replayed.V2.gas_used, computationCost: '1001' } } });
  ck('CONTROL: one gas figure off by one is a divergence that names the field',
     !off.reproduced && off.mismatched === 1 && off.mismatches[0].field === 'computationCost');
  const failure = effectsFacts({ ...published, status: { success: false } },
    { V2: { ...replayed.V2, status: { Failure: { error: 'InsufficientCoinBalance' } } } });
  ck('an on-chain failure that replays as a failure matches on status',
     failure.mismatches.every((m) => m.field !== 'status'));
  const missing = effectsFacts(published, {});
  ck('a replay with no effects is seven mismatches, not seven vacuous matches',
     missing.mismatched === 7 && !missing.reproduced);
}

test('§3 the version-addressed prestate');
{
  const iv = inputVersionsOf(tx({ digest: 'S' }).effectsJson);
  ck('every input version the effects name, with how it was read',
     JSON.stringify(iv) === JSON.stringify([
       { objectId: B, version: '41', read: 'changed' },
       { objectId: '0x6', version: '7', read: 'consensus-read-only' },
       { objectId: '0xd1', version: '9', read: 'runtime-loaded' }]));
  ck('CONTROL: an object the transaction CREATED has no input version and is not listed',
     !iv.some((x) => x.objectId === A));
}

test('§4 the producer, end to end, over a container-free window');
{
  const dir = mkdtempSync(join(tmpdir(), 'sui-producer-selftest-'));
  const cp = (seq, prev, digests) => ({
    sequenceNumber: seq, digest: `CP${seq}`, previousCheckpointDigest: prev,
    timestamp: '2026-10-20T00:00:00Z', networkTotalTransactions: 1, epoch: 1286,
    protocolVersion: 138, transactions: digests.map((d) => tx({ digest: d })),
  });
  const acquisition = (checkpoints) => ({
    format: ACQUISITION_FORMAT, node: 'mainnet', endpoint: 'https://graphql.example.invalid',
    fetchedAt: '2026-10-20T00:00:00Z', replayRuntime: 'sui 1.81.1',
    tip: { sequenceNumber: 20, timestamp: '2026-10-20T00:00:01Z' },
    tracedFloor: { checkpoint: 3, epoch: 1, protocolVersion: 38, previousProtocolVersion: 36,
                   minProtocol: 38 },
    window: { from: 10, to: 11 }, checkpoints,
  });
  const write = (name, obj) => {
    const p = join(dir, name);
    writeFileSync(p, JSON.stringify(obj));
    return p;
  };
  const commit = '1'.repeat(40);
  const run = async (acq, extra = []) => {
    try {
      await produce(['--acquisition', acq, '--replay-root', join(dir, 'replay'),
                     '--recorder-commit', commit, '--out', join(dir, 'tree'), ...extra]);
      return null;
    } catch (e) { return e.message; }
  };
  const good = write('good.json', acquisition([cp(10, 'CP9', ['d1', 'd2']), cp(11, 'CP10', ['d3', 'd4'])]));

  const refusedRec = join(dir, 'rec-d2');
  mkdirSync(refusedRec, { recursive: true });
  writeFileSync(join(refusedRec, 'done.json'), JSON.stringify({ digest: 'd2',
    outcome: 'no-trace-events', recorderCommit: commit }));

  const crashedRec = join(dir, 'rec-d3');
  mkdirSync(crashedRec, { recursive: true });
  writeFileSync(join(crashedRec, 'done.json'), JSON.stringify({ digest: 'd3',
    outcome: 'replay-crashed', refusal: 'SUI-REPLAY-STACK-OVERFLOW', recorderCommit: commit }));

  const bigRec = join(dir, 'rec-d1');
  mkdirSync(bigRec, { recursive: true });
  writeFileSync(join(bigRec, 'done.json'), JSON.stringify({ digest: 'd1',
    outcome: 'too-large', refusal: 'TRACE-TOO-LARGE', recorderCommit: commit }));

  const ok = await run(good, ['--rec', refusedRec, '--rec', crashedRec, '--rec', bigRec]);
  ck(`a whole window with one refused recording produces a tree — ${ok ?? 'no refusal'}`, ok === null);
  if (ok === null) {
    const snap = JSON.parse(readFileSync(join(dir, 'tree', 'snapshot.json'), 'utf8'));
    const by = Object.fromEntries(snap.transactions.map((t) => [t.txHash, t]));
    ck('the denominator is the enumeration: four rows for four transactions',
       snap.transactions.length === 4 && snap.counts.transactions === 4
       && snap.counts.accountedFor === 4);
    ck('the refused recording is runtime-refused with the recorder\'s class beside it',
       by.d2.outcome === 'refused' && by.d2.refusalReason === 'runtime-refused'
       && by.d2.refusal === 'NO-TRACE-EVENTS');
    ck('a replay whose tracer crashed stays in the denominator, refused with the crash named',
       by.d3.outcome === 'refused' && by.d3.refusalReason === 'runtime-refused'
       && by.d3.refusal === 'SUI-REPLAY-STACK-OVERFLOW');
    ck('a trace too large to record is refused as no-container-written, the size named',
       by.d1.outcome === 'refused' && by.d1.refusalReason === 'no-container-written'
       && by.d1.refusal === 'TRACE-TOO-LARGE');
    ck('CONTROL: an unattempted transaction is not-attempted, so the refusals are told apart',
       by.d4.outcome === 'not-attempted' && by.d4.refusalReason === 'not-attempted');
    ck('checkpoints are blocks, newest first, with digests and predecessor digests',
       JSON.stringify(snap.blocks.map((b) => [b.number, b.hash, b.parentArchiveRoot]))
         === JSON.stringify([[11, 'CP11', 'CP10'], [10, 'CP10', 'CP9']]));
    ck('the provenance declares the encoding, the strategy and the ordering it cannot yet publish',
       snap.provenance.identifierEncoding.transaction === 'base58'
       && snap.provenance.prestateStrategy === 'version-addressed'
       && snap.provenance.ordering === 'checkpoint');
    ck('the window floor is the measured traced floor, not a constant',
       snap.window.replayableFrom === 3 && snap.window.tip === 20);
  }

  const gap = write('gap.json', acquisition([cp(10, 'CP9', ['d1']), cp(12, 'CP11', ['d3'])]));
  const gapMsg = await run(gap);
  ck(`a window with a missing checkpoint is refused — ${gapMsg}`,
     gapMsg !== null && gapMsg.includes('skips from checkpoint 10 to 12'));
  const broken = write('broken.json', acquisition([cp(10, 'CP9', ['d1']), cp(11, 'CPX', ['d3'])]));
  const brokenMsg = await run(broken);
  ck(`a checkpoint whose predecessor digest does not chain is refused — ${brokenMsg}`,
     brokenMsg !== null && brokenMsg.includes('as its predecessor'));

  const foreign = join(dir, 'rec-foreign');
  mkdirSync(foreign, { recursive: true });
  writeFileSync(join(foreign, 'done.json'), JSON.stringify({ digest: 'd1',
    outcome: 'no-trace-events', recorderCommit: '2'.repeat(40) }));
  const foreignMsg = await run(good, ['--rec', foreign]);
  ck(`a recording made by another recorder build is refused — ${foreignMsg}`,
     foreignMsg !== null && foreignMsg.includes('was recorded by'));
  const outside = join(dir, 'rec-outside');
  mkdirSync(outside, { recursive: true });
  writeFileSync(join(outside, 'done.json'), JSON.stringify({ digest: 'elsewhere',
    outcome: 'no-trace-events', recorderCommit: commit }));
  const outsideMsg = await run(good, ['--rec', outside]);
  ck(`a recording of a transaction outside the window is refused — ${outsideMsg}`,
     outsideMsg !== null && outsideMsg.includes('is in no checkpoint'));
  rmSync(dir, { recursive: true, force: true });
}

test('§5 the endpoint-horizon verdict');
{
  const reading = (served, answeredNull = true) => ({
    measuredAt: '2026-10-20T00:00:00Z',
    control: { answeredNull },
    rungs: [{ name: 'near-tip', checkpoint: 100, served: true },
            { name: 'june-2023', checkpoint: 5, served }],
  });
  ck('an unchanged reading holds', compareReadings(reading(true), reading(true)).length === 0);
  const moved = compareReadings(reading(true), reading(false));
  ck('a rung served before and not now fails, naming the rung — the horizon moved',
     moved.length === 1 && moved[0].includes('june-2023') && moved[0].includes('moved'));
  ck('CONTROL: a control the endpoint answered with an object fails even with every rung '
     + 'served, so "served" is never an endpoint that answers everything',
     compareReadings(reading(true), reading(true, false)).length === 1);
}

// The count is a LITERAL because `refusal-selftest.mjs` reads it out of this line and
// cross-checks it against the Justfile header and ci.yml.
if (asserted !== 36) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 36 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('self-test: PASS');
