#!/usr/bin/env node
// refusal-selftest.mjs — proof that the closed set in `lib/refusal.mjs` bites.
//
//   node tools/chain/refusal-selftest.mjs
//
// Chain-Ingestion ING-3's four named verifications, run offline. The four test names below
// are the spec's, verbatim, so a reader of the milestone can grep for them here.
//
// ── WHY OFFLINE, AND WHY THAT IS THE POINT RATHER THAN A COMPROMISE ────────────────────
//
// This milestone exists because of a ZERO. A 400-block mainnet backfill exited 0 reporting
// "0 divergent, 0 refused", and a sample of sixty-one mainnet transactions were all at index
// 0 — so the refusal path has never fired in a real run. Every universal claim about it is
// therefore vacuously true (Verification-Harness-Traps §4), and a suite that only exercised
// the pipeline against a live chain would report green while never once executing the branch
// it was written to check. A refusal branch that only appears when it first fires appears for
// the first time in production.
//
// So every reason in the closed set is reached HERE, on every run, from recorded inputs, and
// the count of them is asserted rather than their non-emptiness (§4b: an "at least one"
// control was satisfied by one member of three).
//
// Each test carries a CONTROL arm and, where there is something to mutate, a MUTATION arm
// that is checked to REDDEN (§4a: a negative assertion with no positive twin running through
// the same code path has nothing to fail).

import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  REFUSAL_REASONS, REFUSAL_REASON_IDS, REFUSAL_REASONS_PATH,
  UnknownRefusalCondition, UnexplainedAbsence,
  classifyRefusal, reasonForRuntimeClass, refusalCounts, auditRefusals,
  assertRefusalsAreClosed, assertAbsentIsNotARefusal, isRefusalReason, refusalDurability,
  refuseNotFirstInBlock, refuseBodyUnavailable, refuseBodySourceUnreachable,
  refuseBodyNotSoughtFromStore, storeWasAskedAndSaidNoBody,
  STORE_ANSWERS_MEANING_NO_BODY, BodyUnavailableWithoutStoreEvidence,
  memberForLegacyUntracedRow,
  chainPublishedNoPublicExecution, looksLikePrivateOnlyCrash,
  OUTCOMES, TRACED_OUTCOMES, UNTRACED_OUTCOMES, CHAIN_ABSENT_OUTCOMES,
} from './lib/refusal.mjs';
import { decideOutcome } from './lib/replay.mjs';
import { scanVerdict } from './scan-tx-index.mjs';
import { countsDisagreements, recountSnapshot } from './lib/recount.mjs';
import { SNAPSHOT_FORMAT, READABLE_SNAPSHOT_FORMATS, requiresRefusalReason,
         isReadableSnapshotFormat } from './lib/snapshot-format.mjs';

let asserted = 0;
let failed = 0;
let current = '';
const test = (name) => { current = name; console.error(`\n── ${name} ──`); };
const ck = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  ${label}`); }
  else console.error(`  ok    ${label}`);
};
/** A mutation arm is only evidence if it REDDENS. */
const bite = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  MUTATION DID NOT BITE  ${label}`); }
  else console.error(`  bite  ${label}`);
};
const expectCount = (expected) => {
  if (asserted !== expected) {
    failed++;
    console.error(`\nASSERTION COUNT IS ${asserted}, EXPECTED ${expected} — a case was `
      + `added, removed or silently skipped.`);
  } else {
    console.error(`\nassertion count: ${asserted} (as declared)`);
  }
};
/** Run `fn` and return the error it threw, or `null`. Never rethrows: a test asserts about
 *  the throw, and a suite that died on the first one could not check the rest. */
const threw = (fn) => { try { fn(); return null; } catch (e) { return e; } };

/** EVERY snapshot this repository commits, repo-relative.
 *
 *  WRITTEN DOWN RATHER THAN GLOBBED, and the reason is that a glob is what missed them. The
 *  committed-captures block below reads `client/fixtures/chain/` and finds three; the other
 *  three live under `client/fixtures/noir-frames/`, `fixtures/chain-artifacts/` and
 *  `tests/fixtures/chain-snapshots/`, and a sweep aimed at one directory cannot report on a
 *  file in another. The `existsSync` arm on this list is what makes the list fail LOUDLY
 *  when a file moves, rather than quietly shrinking the population — which is the failure
 *  mode a glob has and a list does not. */
const ALL_COMMITTED_SNAPSHOTS = Object.freeze([
  'client/fixtures/chain/aztec/snapshot.json',
  'client/fixtures/chain/aztec-testnet/snapshot.json',
  'client/fixtures/chain/aztec-testnet-frames/snapshot.json',
  'client/fixtures/noir-frames/snapshot.json',
  'fixtures/chain-artifacts/aztec-testnet/snapshot.json',
  'tests/fixtures/chain-snapshots/aztec-mainnet-live/snapshot.json',
]);

/** The three of those the migration tool must not promote. See the hold-out test below. */
const HELD_OUT_PATHS = Object.freeze([
  'client/fixtures/noir-frames/snapshot.json',
  'fixtures/chain-artifacts/aztec-testnet/snapshot.json',
  'tests/fixtures/chain-snapshots/aztec-mainnet-live/snapshot.json',
]);

// ── recorded driver output, shaped as `replay_settled_transaction.mjs --json` prints it ──
//
// A refusal reaches `decideOutcome` as an EMPTY stdout and a Node uncaught-throw on stderr,
// which is what the driver produces when the runtime declines. The stderr below is the real
// shape — the `(node:…) ExperimentalWarning` preamble included, because that preamble is
// what once made `refusalDetail` structurally incapable of its job.
const nodeThrow = (className, message) =>
  `(node:42017) ExperimentalWarning: WASI is an experimental feature and might change at any time\n`
  + `(Use \`node --trace-warnings ...\` to show where the warning was created)\n`
  + `replay: 0xabc via https://aztec.drpc.org\n`
  + `file:///runtime/replay/src/settled_transaction.ts:180\n`
  + `    throw new ${className}(\n`
  + `    ^\n\n`
  + `${className}: ${message}\n`
  + `    at file:///runtime/replay/src/settled_transaction.ts:180:11\n`
  + `\nNode.js v24.19.0\n`;

const reproducedReport = {
  l2BlockNumber: 63675, txIndexInBlock: 0, preStateReadAt: 63674,
  contractReferenceBlock: 63674, rounds: 3, seedSize: 4096, instructionsExecuted: 128_311,
  published: { revertCode: 0 }, replayed: { revertCode: 0 },
  verdict: { reproduced: true, matched: 13, mismatched: 0 },
  mismatches: [], recording: { steps: 41_233, declaredRung: 3, stepsPositioned: 0 },
  roots: { noteHash: '0xaa' }, rootsAnyAgree: false, skipped: [],
};

/** One untraced row of each reachable reason, built through the REAL producers rather than
 *  written out by hand. A fixture that spelled the rows itself would pass while every
 *  producer in the tree wrote something else. */
function untracedRowOfEveryReason() {
  const rows = [];
  // 1. not-first-in-block — through the producer three tools now share.
  rows.push({ txHash: '0x01', blockNumber: 100, txIndexInBlock: 2,
              ...refuseNotFirstInBlock({ blockNumber: 100, txIndexInBlock: 2, where: 'selftest' }) });
  // 2. body-unavailable — likewise, AND WITH THE STORE'S ANSWER, because it cannot be
  //    reached without one any more. The member asserts two clauses and the producer now
  //    demands the evidence for the second; a row here built without `storeOutcome` would
  //    throw, which is the point.
  rows.push({ txHash: '0x02', blockNumber: 101, txIndexInBlock: 0, storeOutcome: 'absent',
              ...refuseBodyUnavailable({ blockNumber: 101, observedAs: 'it was below the window',
                                         storeOutcome: 'absent', where: 'selftest' }) });
  // 3-5. the three that arrive as a runtime throw, through `decideOutcome`.
  for (const [hash, cls] of [
    ['0x03', 'MissingContractArtifact'],
    ['0x04', 'SettlingBlockUnavailable'],
    ['0x05', 'AvmToolchainRegression'],
  ]) {
    rows.push({ txHash: hash, blockNumber: 102, txIndexInBlock: 0,
                ...decideOutcome({ code: 1, out: '', err: nodeThrow(cls, 'declined') },
                                 'ct/x.ct', false, 0) });
  }
  // 6. no-container-written — a report that claims success over nothing.
  rows.push({ txHash: '0x06', blockNumber: 103, txIndexInBlock: 0,
              ...decideOutcome({ code: 0, out: JSON.stringify(reproducedReport), err: '' },
                               'ct/y.ct', false, 0) });
  // 7. not-attempted — the run's own budget.
  rows.push({ txHash: '0x07', blockNumber: 104, txIndexInBlock: 0, outcome: 'not-attempted',
              ...classifyRefusal({ condition: 'beyond-this-run-budget', where: 'selftest',
                                   narrative: 'This transaction was replayable when it was '
                                     + 'seen and this run reached its own --max of 1 before '
                                     + 'taking it. The run declined it, not the chain.' }) });
  // 8. body-source-unreachable — the BODY SOURCE could not be asked. Reached through the
  //    shared producer, like the two above it, because a row this file spelled itself would
  //    pass while `ingest-range.mjs` wrote something else.
  //
  //    IT IS ITS OWN MEMBER AND NOT `body-unavailable`, which is the whole reason it exists:
  //    `ingest-range.mjs replayRange` routed `absent`, `mismatched`, `truncated` AND
  //    `unavailable` into `refuseBodyUnavailable`, whose member is durability PERMANENT — so
  //    one store 5xx published "this transaction can never be re-executed" about a body the
  //    store holds. And it is not `not-attempted` either: every `not-attempted` narrative in
  //    this tree asserts the body IS obtainable, which is precisely the claim a run that
  //    could not reach the store has failed to establish.
  rows.push({ txHash: '0x08', blockNumber: 105, txIndexInBlock: 0,
              ...refuseBodySourceUnreachable({
                blockNumber: 105, storeOutcome: 'unavailable',
                storeReason: 'The file store answered HTTP 503 for this key, which is '
                  + 'neither a body nor a denial that it holds one.',
                where: 'selftest' }) });
  return rows;
}

/** A range in which everything traced. The CONTROL for test 1. */
const tracedRows = () => [
  { txHash: '0xf1', blockNumber: 200, txIndexInBlock: 0,
    ...decideOutcome({ code: 0, out: JSON.stringify(reproducedReport), err: '' }, 'ct/a.ct', true, 4096) },
  { txHash: '0xf2', blockNumber: 201, txIndexInBlock: 0,
    ...decideOutcome({ code: 1, out: JSON.stringify({ ...reproducedReport,
        verdict: { reproduced: false, matched: 11, mismatched: 2 },
        mismatches: [{ kind: 'transactionFee' }] }), err: '' }, 'ct/b.ct', true, 4096) },
];

// ═══════════════════════════════════════════════════════════════════════════════════════
// 1. test_every_untraced_transaction_carries_a_reason
// ═══════════════════════════════════════════════════════════════════════════════════════
//
// "Over a range containing at least one refusal of each reachable reason, no transaction is
//  left with an untraced status and no reason. Control: a range in which every transaction
//  traces produces no reasons at all."

test('test_every_untraced_transaction_carries_a_reason');
{
  const rows = untracedRowOfEveryReason();
  const audit = auditRefusals(rows);

  ck('every reachable reason is reached by a real producer, and the SIZE is asserted — '
     + `${REFUSAL_REASON_IDS.length} members, ${rows.length} rows`,
     rows.length === REFUSAL_REASON_IDS.length);
  const reached = new Set(rows.map((r) => r.refusalReason));
  for (const id of REFUSAL_REASON_IDS) {
    ck(`reason ${id} is reached`, reached.has(id));
  }
  ck('no transaction is untraced-without-reason', audit.problems.length === 0);
  ck(`and all ${rows.length} are counted as untraced`, audit.untraced === rows.length);
  ck('…and none as traced', audit.traced === 0);

  const counts = refusalCounts(rows);
  ck('the per-reason counts total the untraced rows', counts.total === rows.length);
  ck('nothing is unclassified', counts.unclassified === 0);
  ck('every member has a key in the published counts, zero-filled or not',
     REFUSAL_REASON_IDS.every((id) => Object.prototype.hasOwnProperty.call(counts.byReason, id)));
  ck('every reason states WHY in a sentence, not just an id',
     rows.every((r) => typeof r.reason === 'string' && r.reason.length > 40));
  ck('every reason has a durability the page can grade its claim against — LOOKED UP from '
     + 'the member, never stored on the row, so it cannot disagree with the table it came from',
     rows.every((r) => ['permanent', 'repairable'].includes(refusalDurability(r.refusalReason))));
  ck('…and no producer writes it onto a row', rows.every((r) => r.durability === undefined));

  // THE CONTROL. A range where everything traced must produce NO reasons at all — not an
  // empty string, not a zero-length list, no key. An assertion that only ever ran over
  // refusals could be satisfied by a rule that labelled everything.
  const traced = tracedRows();
  const tracedAudit = auditRefusals(traced);
  const tracedCounts = refusalCounts(traced);
  ck('control: a fully-traced range produces no problems', tracedAudit.problems.length === 0);
  ck('control: …and no untraced rows', tracedAudit.untraced === 0);
  ck('control: …and every per-reason count is zero', tracedCounts.total === 0
     && REFUSAL_REASON_IDS.every((id) => tracedCounts.byReason[id] === 0));
  ck('control: …and no traced row carries a refusalReason',
     traced.every((r) => r.refusalReason === undefined));
  ck('control: the two traced rows are `replayed` and `divergent` — divergent is NOT a refusal',
     traced[0].outcome === 'replayed' && traced[1].outcome === 'divergent');

  // MUTATION. Strip the reason from one row and the audit must name that row. Without this
  // arm, "no problems" is a sentence the audit could produce by never looking.
  const stripped = untracedRowOfEveryReason();
  delete stripped[0].refusalReason;
  const strippedAudit = auditRefusals(stripped);
  bite('mutation: a row with no refusalReason is reported, by hash',
       strippedAudit.problems.length === 1 && strippedAudit.problems[0].includes('0x01'));
  bite('mutation: …and `refusalCounts` reports it as unclassified rather than dropping it',
       refusalCounts(stripped).unclassified === 1);

  const blanked = untracedRowOfEveryReason();
  blanked[3].reason = '   ';
  bite('mutation: a member id with a BLANK sentence is reported — an id is a machine\'s word '
       + 'and §14 requires the page to state why',
       auditRefusals(blanked).problems.length === 1);

  const mislabelled = tracedRows();
  mislabelled[0].refusalReason = 'not-first-in-block';
  bite('mutation: a TRACED row carrying a refusal reason is reported too — the fold is a '
       + 'defect in both directions',
       auditRefusals(mislabelled).problems.length === 1);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
// 2. test_unknown_refusal_condition_fails_rather_than_defaults
// ═══════════════════════════════════════════════════════════════════════════════════════
//
// "A condition outside the closed set is injected; the pipeline fails naming it, rather than
//  recording a generic or empty reason. This is the assertion that keeps the set closed."
//
// THE MOST IMPORTANT TEST IN THIS FILE. Everything else here checks that reasons are
// present; this one checks that the set is CLOSED, which is the only thing standing between
// a registry and a free-text field with seven popular values.

test('test_unknown_refusal_condition_fails_rather_than_defaults');
{
  // ── injected at the PRODUCER boundary ──
  const injected = 'the-sequencer-ate-it';
  let returned = 'NOTHING WAS RETURNED';
  const e = threw(() => { returned = classifyRefusal({ condition: injected, where: 'selftest' }); });

  ck('an unknown condition THROWS', e !== null);
  ck('…and the throw is UnknownRefusalCondition, not a bare Error',
     e instanceof UnknownRefusalCondition);
  ck('…and it NAMES the condition it did not recognise, in a field a caller can read',
     e?.condition === injected);
  ck('…and in the message, so a log line is enough to diagnose it',
     String(e?.message).includes(injected));
  ck('…and it names WHERE, so four producers do not become four searches',
     String(e?.message).includes('selftest'));
  ck('…and it enumerates the conditions it does know, rather than saying only "unknown"',
     String(e?.message).includes('transaction-index-is-not-zero'));
  ck('…and it says a NEW member must be added rather than a neighbour widened',
     /add it to REFUSAL_REASONS/.test(String(e?.message)));
  ck('NOTHING was returned — not a generic reason, not an empty one',
     returned === 'NOTHING WAS RETURNED');

  // ── injected at the SNAPSHOT boundary ──
  // The producers are guarded above. This is the other half: a row that reached a snapshot
  // some other way — hand-edited, or written by a tool that predates this registry — must
  // not be publishable either.
  const outside = [{ txHash: '0xbad', outcome: 'refused', reason: 'it did not work',
                     refusalReason: 'because-reasons' }];
  const e2 = threw(() => assertRefusalsAreClosed(outside));
  ck('a snapshot row whose refusalReason is outside the set is refused',
     e2 instanceof UnexplainedAbsence);
  ck('…naming the offending value', String(e2?.message).includes('because-reasons'));
  ck('…and naming the transaction', String(e2?.message).includes('0xbad'));
  ck('…and listing the closed set, so the fix is visible from the failure',
     String(e2?.message).includes('prestate-unavailable'));

  const noReason = [{ txHash: '0xnone', outcome: 'pruned', reason: 'it is gone' }];
  const e3 = threw(() => assertRefusalsAreClosed(noReason));
  ck('an untraced row with NO refusalReason is refused — an unexplained absence',
     e3 instanceof UnexplainedAbsence);
  ck('…and the failure calls it that, in the milestone\'s own words',
     /unexplained absence/i.test(String(e3?.message)));

  const strangeOutcome = [{ txHash: '0xodd', outcome: 'sort-of-worked', reason: 'hm',
                            refusalReason: 'runtime-refused' }];
  const e4 = threw(() => assertRefusalsAreClosed(strangeOutcome));
  ck('the OUTCOME vocabulary is closed too — a reason inside the set does not license an '
     + 'outcome outside it', e4 instanceof UnexplainedAbsence);
  ck('…and the failure enumerates the outcomes it knows',
     OUTCOMES.every((o) => String(e4?.message).includes(o)));

  // ── the CONTROL: the same call with a known condition must work ──
  // Without this, every assertion above is satisfied by a `classifyRefusal` that throws
  // unconditionally, which is the shape of green that costs the most.
  const good = classifyRefusal({ condition: 'transaction-index-is-not-zero', where: 'selftest' });
  ck('control: a KNOWN condition returns a member', isRefusalReason(good.refusalReason));
  ck('control: …the right one', good.refusalReason === 'not-first-in-block');
  ck('control: …with a sentence, defaulted from the registry when none was passed',
     good.reason === REFUSAL_REASONS['not-first-in-block'].condition);
  ck('control: …and a caller-supplied narrative wins over the registry\'s general one',
     classifyRefusal({ condition: 'transaction-index-is-not-zero', narrative: 'this one, here' })
       .reason === 'this one, here');
  ck('control: a well-formed snapshot passes the same gate that refused the four above',
     threw(() => assertRefusalsAreClosed(untracedRowOfEveryReason())) === null);

  // ── the runtime's open set does NOT leak into ours ──
  ck('a runtime class the registry classifies maps to its named member',
     reasonForRuntimeClass('IntraBlockPredecessorsUnavailable') === 'not-first-in-block');
  ck('a runtime class it does not classify becomes `runtime-refused`, a MEMBER with its own '
     + 'count — not an unknown reason', reasonForRuntimeClass('SomeClassInventedTomorrow') === 'runtime-refused');
  ck('…and `runtime-refused` is in the set, so it is counted rather than swallowed',
     isRefusalReason('runtime-refused'));
  ck('…and the class name survives as EVIDENCE beside it, so the specific condition is '
     + 'recoverable from the row',
     decideOutcome({ code: 1, out: '', err: nodeThrow('SomeClassInventedTomorrow', 'no') },
                   'ct/x.ct', false, 0).refusal === 'SomeClassInventedTomorrow');

  // ── the registry cannot silently lose a member ──
  const disk = JSON.parse(readFileSync(REFUSAL_REASONS_PATH, 'utf8'));
  ck('the members come from the file the Nim side also reads, not from a second copy',
     disk.reasons.map((r) => r.id).join(',') === REFUSAL_REASON_IDS.join(','));
  ck('and `absent` may never be one of them — it is the chain\'s statement, not ours',
     threw(assertAbsentIsNotARefusal) === null && !isRefusalReason('absent'));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
// 3. test_absent_and_refused_are_not_the_same_statement
// ═══════════════════════════════════════════════════════════════════════════════════════
//
// "An Aztec private half is published as `absent` and a non-index-0 public half as
//  refused-with-reason, and the two render differently. Control: a transaction with a traced
//  public half carries neither."
//
// The RENDER half of this is `client/tests/test_chain_provenance.nim`, which drives the real
// ingest and the real page. What is checked here is the half this side owns: that the two
// statements are structurally distinguishable BEFORE they reach the ingest, because a
// distinction the producer never made cannot be recovered by any renderer.

test('test_absent_and_refused_are_not_the_same_statement');
{
  // The Aztec private half. The chain never published this execution — there is nothing to
  // decline, so this is not a refusal and carries no reason from the set. It is not even an
  // untraced OUTCOME: it is a second execution on a transaction whose public half traced.
  const privateHalf = { selector: 'private', availability: 'absent',
    reason: 'Aztec does not publish the private half of a transaction\'s execution; there is '
      + 'no call structure on chain to record.' };

  // The non-index-0 public half. WE declined it, and the set says why.
  const publicHalf = { txHash: '0x11', blockNumber: 300, txIndexInBlock: 1,
    ...refuseNotFirstInBlock({ blockNumber: 300, txIndexInBlock: 1, where: 'selftest' }) };

  ck('the refusal carries a member of the closed set', isRefusalReason(publicHalf.refusalReason));
  ck('the private half carries none — nothing was declined',
     privateHalf.refusalReason === undefined);
  ck('the private half is `absent`, which is not an untraced outcome of ours',
     privateHalf.availability === 'absent' && !UNTRACED_OUTCOMES.includes('absent'));
  ck('the refusal is counted', refusalCounts([publicHalf]).total === 1);
  ck('the private half is NOT counted as a refusal — it would inflate every per-reason '
     + 'figure on a chain with a private half on every transaction',
     refusalCounts([privateHalf]).total === 0);
  ck('their sentences are different sentences', privateHalf.reason !== publicHalf.reason);
  ck('the refusal\'s sentence locates the limitation in OUR pipeline',
     /node does not serve intra-block/.test(publicHalf.reason));
  ck('the absent sentence locates it in the CHAIN',
     /Aztec does not publish/.test(privateHalf.reason));
  ck('the refusal claims permanence, and the registry — not the prose — decides that',
     refusalDurability(publicHalf.refusalReason) === 'permanent');
  ck('a repairable refusal does NOT claim permanence, so a page cannot assert the strong '
     + 'sentence under it',
     refusalDurability('runtime-refused') === 'repairable'
     && refusalDurability('artifact-unresolvable') === 'repairable');

  // THE CONTROL. A traced public half carries neither statement.
  const tracedHalf = tracedRows()[0];
  ck('control: a traced public half carries no refusalReason',
     tracedHalf.refusalReason === undefined);
  ck('control: …and is not `absent`', tracedHalf.outcome === 'replayed'
     && TRACED_OUTCOMES.includes(tracedHalf.outcome));
  ck('control: …and contributes nothing to any per-reason count',
     refusalCounts([tracedHalf]).total === 0);

  // MUTATION. Fold them together — give the private half a refusal reason — and the audit
  // must not be able to tell the two apart any more. This is the arm that proves the
  // distinction above is carried by the data and not by the test's own arrangement.
  const folded = { ...privateHalf, txHash: '0x12', outcome: 'refused',
                   refusalReason: 'runtime-refused' };
  bite('mutation: an `absent` private half given a refusal reason IS counted as a refusal — '
       + 'which is the overcount the separation prevents',
       refusalCounts([folded]).total === 1);

  // ── THE SAME DISTINCTION ON A WHOLE TRANSACTION, WHICH IS THE CASE HISTORIC REPLAY
  //    FOUND AND THE PRODUCER SIDE COULD NOT EXPRESS ────────────────────────────────────
  //
  // Everything above is about the private HALF of a transaction whose public half traced.
  // A private-ONLY transaction has no public half at all: `data.forPublic` is undefined,
  // `numberOfPublicCalls()` is 0, and there is nothing anywhere to re-execute. Until
  // `private-only` existed the driver was spawned on these, crashed inside upstream's
  // `getPublicCallRequestsWithCalldata()`, and `decideOutcome` filed the crash as
  // `runtime-refused` — durability `repairable`, on a limit that is permanent and is the
  // chain's. Measured on the historic sample, that was 21% of the first-in-block
  // transactions in one 200-block window.
  const privateOnly = { txHash: '0x13', blockNumber: 301, txIndexInBlock: 0,
    firstInBlock: true, ...chainPublishedNoPublicExecution({ blockNumber: 301 }) };

  ck('a private-only transaction is an OUTCOME this pipeline writes, unlike bare `absent`',
     OUTCOMES.includes(privateOnly.outcome) && privateOnly.outcome === 'private-only');
  ck('…and it is not one of the untraced outcomes, which all owe a reason id',
     !UNTRACED_OUTCOMES.includes(privateOnly.outcome)
     && CHAIN_ABSENT_OUTCOMES.includes(privateOnly.outcome));
  ck('it carries NO refusalReason — nothing was declined',
     privateOnly.refusalReason === undefined);
  ck('it carries a sentence anyway: `absent` with no explanation is indistinguishable from '
     + 'a failed fetch', privateOnly.reason.length > 0);
  ck('its sentence locates the limitation in the CHAIN, not in this pipeline',
     /execution was never public/.test(privateOnly.reason));
  ck('the audit accepts it', auditRefusals([privateOnly]).problems.length === 0);
  ck('…and counts it apart from both traces and refusals, so it lands in no total it '
     + 'does not belong in',
     refusalCounts([privateOnly]).total === 0
     && refusalCounts([privateOnly]).unclassified === 0
     && refusalCounts([privateOnly]).chainAbsent === 1);
  ck('…and is in no traced count either',
     auditRefusals([privateOnly]).traced === 0
     && auditRefusals([privateOnly]).untraced === 0
     && auditRefusals([privateOnly]).chainAbsent === 1);

  bite('mutation: strip its sentence and the audit refuses it — the id may be absent, the '
       + 'explanation may not',
       auditRefusals([{ ...privateOnly, reason: '' }]).problems.length === 1);
  bite('mutation: give it a reason id and the audit refuses it — that is "we declined" and '
       + '"it was never public" folded into one row, which is what this outcome exists to '
       + 'keep apart',
       auditRefusals([{ ...privateOnly, refusalReason: 'runtime-refused' }])
         .problems.length === 1);
  bite('mutation: file it as `runtime-refused` instead and the durability claim flips from '
       + 'permanent-by-the-chain to repairable-by-us, which is the false sentence a page '
       + 'would print', refusalDurability('runtime-refused') === 'repairable');
}

// ═══════════════════════════════════════════════════════════════════════════════════════
// 4. test_index_zero_distribution_is_measured_not_assumed
// ═══════════════════════════════════════════════════════════════════════════════════════
//
// "The committed scanner reports the observed index distribution over a live range and the
//  refusal branch is exercised against a synthetic non-zero-index subject, so the branch is
//  proven to work while its production count is zero."
//
// TWO CLAIMS, AND THEY FAIL DIFFERENTLY. The first is that the distribution is measured
// rather than quoted — checked against the committed measurement, which has a date and a
// population on it. The second is that the branch WORKS, which cannot be checked against
// production data at all while production produces none of it, so it is checked against a
// subject constructed to have index 3.

test('test_index_zero_distribution_is_measured_not_assumed');
{
  // ── the branch, exercised against a synthetic non-zero-index subject ──
  const subject = { txHash: '0x21', blockNumber: 400, txIndexInBlock: 3 };
  const refused = { ...subject, ...refuseNotFirstInBlock({ ...subject, where: 'selftest' }) };
  ck('a synthetic index-3 subject is refused', refused.outcome === 'not-first-in-block');
  ck('…with the member the milestone names', refused.refusalReason === 'not-first-in-block');
  ck('…and the sentence carries THIS transaction\'s index and block, not the general rule',
     refused.reason.includes('3 transaction(s)') && refused.reason.includes('block 400'));
  ck('…and it is counted', refusalCounts([refused]).byReason['not-first-in-block'] === 1);
  ck('…and the snapshot gate accepts it', threw(() => assertRefusalsAreClosed([refused])) === null);

  // THE CONTROL. The same path with index 0 must not refuse. Without it, "index 3 refuses"
  // is satisfied by a rule that refuses everything — which is exactly how a branch that
  // never fires in production could be "proven" by a test that proves nothing.
  const atZero = { txHash: '0x22', blockNumber: 401, txIndexInBlock: 0 };
  const zeroCounts = refusalCounts([{ ...atZero,
    ...decideOutcome({ code: 0, out: JSON.stringify(reproducedReport), err: '' },
                     'ct/z.ct', true, 4096) }]);
  ck('control: an index-0 subject through the same producers is not refused at all',
     zeroCounts.total === 0 && zeroCounts.byReason['not-first-in-block'] === 0);

  // ── the scanner's verdict rule, driven with recorded populations ──
  //
  // The arm that matters is `no-population`, and a live run against a chain with traffic
  // will never take it. It is unreachable from production and therefore only ever checked
  // here.
  ck('a scan that saw transactions and whose control held is `measured`',
     scanVerdict({ transactions: 43, controlChecked: 12, controlViolations: [] }).verdict === 'measured');
  bite('mutation: a scan that saw NOTHING refuses to report a distribution — it is '
       + '`no-population`, not "all at index 0"',
       scanVerdict({ transactions: 0, controlChecked: 12, controlViolations: [] }).verdict === 'no-population');
  bite('mutation: a scan whose prefilter control was VIOLATED is void — it was skipping '
       + 'blocks that had content',
       scanVerdict({ transactions: 43, controlChecked: 12,
                     controlViolations: [{ blockNumber: 7, transactions: 1 }] }).verdict === 'void');
  bite('mutation: a control with ZERO samples is void too — no violations out of no samples '
       + 'is the empty-set pass one layer down',
       scanVerdict({ transactions: 43, controlChecked: 0, controlViolations: [] }).verdict === 'void');

  // ── the committed measurement: a sentence with a date on it ──
  const measured = join(new URL('.', import.meta.url).pathname, 'measurements',
                        'tx-index-distribution.json');
  ck('the scanner\'s measurement is COMMITTED, so "it costs nothing today" can be checked '
     + 'rather than believed', existsSync(measured));
  if (existsSync(measured)) {
    const m = JSON.parse(readFileSync(measured, 'utf8'));
    ck('…and it carries the moment it was taken', typeof m.scannedAt === 'string'
       && !Number.isNaN(Date.parse(m.scannedAt)));
    ck('…and the endpoint it was taken against', typeof m.endpoint === 'string' && m.endpoint.length > 0);
    ck('…and an ENUMERATED population, not just a headline', m.population
       && typeof m.population.blocksRequested === 'number'
       && typeof m.population.blockHeadersServed === 'number'
       && typeof m.population.transactions === 'number');
    ck('…and it distinguishes blocks REQUESTED from blocks the node SERVED, so an '
       + 'unreachable range cannot pass as an empty one',
       m.population.blockHeadersServed <= m.population.blocksRequested);
    ck('…and its verdict is `measured`, which it may only be with a non-empty population',
       m.verdict === 'measured' && m.population.transactions > 0);
    ck('…and its prefilter control was checked against real bodies and held',
       m.prefilterControl?.held === true && m.prefilterControl.sampled > 0);
    ck('…and the distribution accounts for every transaction it counted',
       Object.values(m.distribution).reduce((a, b) => a + b, 0) === m.population.transactions);
    ck('…and `wouldBeRefused` lists the subjects rather than only counting them',
       Array.isArray(m.wouldBeRefused) && m.wouldBeRefused.length === m.beyondIndexZero);
  }
}

// ── the snapshot gate, end to end, on a temporary file ──────────────────────────────────
//
// The three assertions above are about functions. This is about the FILE: the gate has to be
// in the path that writes a snapshot, or it is a check nobody runs.

test('the gate is in the write path, not beside it');
{
  const dir = await mkdtemp(join(tmpdir(), 'refusal-'));
  try {
    const good = { transactions: untracedRowOfEveryReason() };
    await writeFile(join(dir, 'ok.json'), JSON.stringify(good));
    ck('a snapshot whose rows all classify is writable',
       threw(() => assertRefusalsAreClosed(good.transactions)) === null);

    const followSrc = readFileSync(new URL('./follow-chain.mjs', import.meta.url), 'utf8');
    ck('`follow-chain.mjs` calls the gate inside `saveSnapshot`',
       /async function saveSnapshot[\s\S]{0,700}?assertRefusalsAreClosed/.test(followSrc));
    // ── ONE TALLY, AND THE CHECK IS THAT NOBODY CARRIES A SECOND ────────────────────
    //
    // This used to assert `/function recount[\s\S]{0,2000}?refusalCounts/` per producer —
    // that each of them had its own `recount` and that its own copy reached
    // `refusalCounts`. It passed while the three copies DISAGREED:
    // `follow-chain.mjs`'s had no `privateOnly` line, so its `accountedFor` omitted every
    // chain-absent row, and `backfill-blocks.mjs`'s spread `...s.counts` and preserved
    // every outcome line across a run that added rows — which is how
    // `client/fixtures/chain/aztec-testnet/snapshot.json` came to declare
    // `counts.pruned: 25` against 835 pruned rows. A check that each producer has its own
    // spelling of a measurement is a check that there are three answers.
    //
    // So the assertion is inverted: the tally lives in `lib/recount.mjs`, every producer
    // calls it, and NONE of them defines a `recount` of its own.
    const recountSrc = readFileSync(new URL('./lib/recount.mjs', import.meta.url), 'utf8');
    ck('the tally is single-sourced in `lib/recount.mjs`, and it publishes per-reason counts',
       /export function recountSnapshot[\s\S]*?counts\.refusals = refusals\.byReason/
         .test(recountSrc));
    ck('…and it publishes the three-population reconciliation, `privateOnly` included',
       /counts\.privateOnly = refusals\.chainAbsent/.test(recountSrc)
         && /counts\.accountedFor =[\s\S]{0,120}?counts\.privateOnly/.test(recountSrc));
    ck('`follow-chain.mjs` takes the tally from there rather than spelling its own',
       /import \{ recountSnapshot \} from '\.\/lib\/recount\.mjs'/.test(followSrc)
         && !/function recount\s*\(/.test(followSrc));
    const captureSrc = readFileSync(new URL('./capture-chain.mjs', import.meta.url), 'utf8');
    ck('`capture-chain.mjs` calls the gate before it writes',
       /assertRefusalsAreClosed[\s\S]{0,200}?writeFile\(join\(outDir, 'snapshot\.json'\)/.test(captureSrc));
    const backfillSrc = readFileSync(new URL('./backfill-blocks.mjs', import.meta.url), 'utf8');
    ck('`backfill-blocks.mjs` calls the gate before it writes',
       /assertRefusalsAreClosed[\s\S]{0,900}?writeFileSync\(tmp/.test(backfillSrc));
    // `ingest-range.mjs` BECAME A PRODUCER WHEN IT GAINED `--replay`, and a producer this
    // check does not name is a producer whose rows nothing gates. It writes untraced rows in
    // two places — the placeholder each first-in-block transaction starts as, and the
    // `not-attempted` a budget or a rate limit leaves behind — and both go through
    // `classifyRefusal`, with the gate immediately before the snapshot is written.
    const rangeSrc = readFileSync(new URL('./ingest-range.mjs', import.meta.url), 'utf8');
    ck('`ingest-range.mjs` calls the gate before it writes a replayed range',
       /assertRefusalsAreClosed[\s\S]{0,300}?writeFileSync\(tmp/.test(rangeSrc));
    ck('…and takes the tally from `lib/recount.mjs` rather than spelling its own',
       /import \{ recountSnapshot \} from '\.\/lib\/recount\.mjs'/.test(rangeSrc)
         && !/function recount\s*\(/.test(rangeSrc));
    ck('…and so does `backfill-blocks.mjs`, whose own copy PRESERVED every outcome line '
       + 'across a run that added rows',
       /import \{ recountSnapshot \} from '\.\/lib\/recount\.mjs'/.test(backfillSrc)
         && !/function recount\s*\(/.test(backfillSrc));
    ck('…and never writes an outcome for a declined transaction outside `classifyRefusal`',
       // Every `outcome:` literal it writes is either traced (which comes from the driver's
       // own verdict, via `decideOutcome`) or is immediately followed by a classification.
       [...rangeSrc.matchAll(/outcome: '([a-z-]+)'/g)]
         .every(([, o]) => o === 'not-attempted'));
    ck('…and a rate limit reaches `not-attempted` rather than the transaction\'s own row',
       /endpoint-throttled-this-run/.test(rangeSrc)
       && /if \(proxy\.throttled\)[\s\S]{0,400}?attempted--/.test(rangeSrc));
    ck('…and no producer spells the two shared sentences a second time',
       ![followSrc, captureSrc, backfillSrc, rangeSrc].some((s) =>
         s.includes('getTxByHash prunes at the finalized tip and')));

    // THE HOSTILE CORPUS MUST NOT POISON A MEMBER ID. `tools/ci/hostile-chain-corpus.mjs`
    // appends an XSS payload to every non-structural string in a capture and re-ingests it,
    // and a member id with a payload on the end is outside the closed set — so the ingest
    // would refuse the fixture and the run would measure nothing, which is the exact failure
    // that file's header records having already paid for with `outcome`/`kind`/`origin`.
    // The SENTENCE beside it must stay poisonable: it is free text that reaches the page.
    const hostileSrc = readFileSync(new URL('../ci/hostile-chain-corpus.mjs', import.meta.url), 'utf8');
    ck('the hostile corpus treats `refusalReason` as structural, like `outcome` beside it',
       /STRUCTURAL_KEYS[\s\S]{0,1400}?"refusalReason"/.test(hostileSrc));
    ck('…and does NOT exempt `reason`, which is free text and must stay poisonable',
       !/STRUCTURAL_KEYS = new Set\(\[[\s\S]*?"reason"[\s\S]*?\]\)/.test(hostileSrc));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

// ── and the committed data plane, which is the only population there is ────────────────
//
// Every assertion above runs over rows this file constructed. That is deliberate — it is
// the only way to reach a branch production has never taken — and it is also the classic
// way for a suite to be green over a tree that is broken. So the gate is also run against
// the snapshots this repository actually ships, with the population STATED: a pass over
// zero untraced rows would be the empty-set green this whole milestone is about.

test('the committed captures are inside the closed set');
{
  const fixtures = join(new URL('../../', import.meta.url).pathname, 'client', 'fixtures', 'chain');
  const snaps = readdirSync(fixtures, { withFileTypes: true })
    .filter((d) => d.isDirectory() && existsSync(join(fixtures, d.name, 'snapshot.json')))
    .map((d) => join(fixtures, d.name, 'snapshot.json'));
  ck(`there are committed captures to check — ${snaps.length} of them`, snaps.length >= 3);

  let untraced = 0;
  let traced = 0;
  let chainAbsent = 0;
  const seen = new Set();
  const problems = [];
  // ── WIDENED PAST `.transactions`, BECAUSE THAT IS WHY IT MISSED ────────────────────────
  //
  // This block read `.transactions` and nothing else, so it could not see — and did not —
  // that `client/fixtures/chain/aztec-testnet/snapshot.json` declared `counts.pruned: 25`
  // against 835 actual pruned rows, and that its four outcome lines summed to 51 against
  // `counts.transactions: 866`. Data-Contract.md §5.2 gives `counts` exactly one job, "so a
  // partial ingest is detectable", so a `counts` that disagrees with the rows is the
  // detector reading clean on the condition it detects — and it is the defect ING-3 was
  // written to eliminate, surviving in committed data because the gate over that data only
  // looked at half the file.
  //
  // Three more things about the FILE are checked here for the same reason: each was wrong in
  // the committed tree and invisible to a check that read only the rows.
  const staleCounts = [];
  const badFormat = [];
  const notArray = [];
  const claimedButMissing = [];
  for (const p of snaps) {
    const snap = JSON.parse(readFileSync(p, 'utf8'));
    const rows = snap.transactions ?? [];
    const a = auditRefusals(rows);
    untraced += a.untraced;
    traced += a.traced;
    chainAbsent += a.chainAbsent;
    for (const q of a.problems) problems.push(`${p}: ${q}`);
    const byReason = refusalCounts(rows).byReason;
    for (const id of Object.keys(byReason)) if (byReason[id] > 0) seen.add(id);

    // 1. THE TALLY AGREES WITH THE ROWS, member by member.
    for (const d of countsDisagreements(snap)) {
      staleCounts.push(`${p}: counts.${d.member} declares ${JSON.stringify(d.declared)}, `
        + `the rows say ${JSON.stringify(d.actual)}`);
    }
    // 2. THE TOKEN IS ONE THIS TREE READS, and if it is one that makes `refusalReason`
    //    mandatory, every untraced row carries one. A tree that claimed `@1` while carrying
    //    mandatory `@2` members, or the reverse, is the ambiguity the bump removed.
    if (!isReadableSnapshotFormat(snap.format)) {
      badFormat.push(`${p}: format ${JSON.stringify(snap.format)} is not one of `
        + `${READABLE_SNAPSHOT_FORMATS.join(', ')}`);
    } else if (!requiresRefusalReason(snap.format)
               && rows.some((t) => typeof t.refusalReason === 'string')) {
      claimedButMissing.push(`${p}: format ${snap.format} does not require `
        + `refusalReason and rows carry it — the token understates the tree`);
    } else if (requiresRefusalReason(snap.format)) {
      const missing = rows.filter((t) => UNTRACED_OUTCOMES.includes(t.outcome)
                                         && t.refusalReason == null);
      if (missing.length) {
        claimedButMissing.push(`${p}: format ${snap.format} requires refusalReason and `
          + `${missing.length} untraced row(s) carry none`);
      }
    }
    // 3. `captures` IS AN ARRAY. `ingest.nim` gates the per-capture recorder attribution on
    //    `caps.kind == JArray`, so a `captures` committed as a JSON OBJECT with numeric
    //    string keys — which `aztec-testnet-frames` was — silently skips the whole mapping
    //    and files every container under the snapshot-level `runtimeCommit`. It cost nothing
    //    there only because all eight commits happened to be identical; the next snapshot
    //    grown by a second runtime build would misattribute containers, which is exactly
    //    what `traceArtifactId`'s commitment to `recorderBuild` exists to prevent.
    if (snap.captures !== undefined && !Array.isArray(snap.captures)) {
      notArray.push(`${p}: captures is ${typeof snap.captures}, not an array — `
        + `ingest.nim skips per-capture recorder attribution for it entirely`);
    }
  }
  ck(`the population is not empty — ${untraced} untraced row(s) across ${snaps.length} `
     + `captures, against ${traced} traced and ${chainAbsent} chain-absent`, untraced > 100);
  ck('every one of them carries a reason from the closed set', problems.length === 0);
  if (problems.length) console.error(`    ${problems.slice(0, 5).join('\n    ')}`);
  ck('every capture\'s `counts` agrees with its own rows, member by member — §5.2\'s '
     + '"so a partial ingest is detectable"', staleCounts.length === 0);
  if (staleCounts.length) console.error(`    ${staleCounts.slice(0, 8).join('\n    ')}`);
  ck(`every capture declares a format this tree reads — ${SNAPSHOT_FORMAT} or an earlier `
     + 'one it still accepts', badFormat.length === 0);
  if (badFormat.length) console.error(`    ${badFormat.join('\n    ')}`);
  ck('…and no capture claims a token whose mandatory members it does not carry, in either '
     + 'direction', claimedButMissing.length === 0);
  if (claimedButMissing.length) console.error(`    ${claimedButMissing.join('\n    ')}`);
  ck('every capture\'s `captures` is an ARRAY, which is the shape ingest.nim attributes '
     + 'recorders from', notArray.length === 0);
  if (notArray.length) console.error(`    ${notArray.join('\n    ')}`);

  // ── AND THE SEVEN RECLASSIFIED ROWS STAY RECLASSIFIED ──────────────────────────────────
  //
  // Seven committed rows carried `refusalReason: runtime-refused` — durability REPAIRABLE,
  // so every one of them told a reader that a better runtime would trace it — and were
  // `private-only`: no public execution, nothing to re-run, nothing this pipeline declined.
  // The signature is in the row: a driver `TypeError` naming `forPublic`'s accumulator,
  // which is what the crash looked like before the outcome existed. Asserted both ways so a
  // re-migration, a re-capture or a hand edit cannot quietly put them back.
  const crashSignature = [];
  const stillMisfiled = [];
  for (const p of snaps) {
    for (const t of JSON.parse(readFileSync(p, 'utf8')).transactions ?? []) {
      if (!looksLikePrivateOnlyCrash(t)) continue;
      crashSignature.push(t.txHash);
      if (t.outcome !== 'private-only' || t.refusalReason != null) {
        stillMisfiled.push(`${p}: ${t.txHash} carries the private-only crash signature and `
          + `is filed ${t.outcome} / ${JSON.stringify(t.refusalReason ?? null)}`);
      }
    }
  }
  ck(`the signature still matches the rows it was derived from — ${crashSignature.length} `
     + 'of them, so this arm is not vacuous', crashSignature.length === 7);
  ck('…and every one is `private-only` with NO reason id — a permanent property of the '
     + 'CHAIN is never published as a repairable fault of ours', stillMisfiled.length === 0);
  if (stillMisfiled.length) console.error(`    ${stillMisfiled.join('\n    ')}`);
  // WHICH MEMBERS THE REAL DATA HAS ALREADY REACHED, asserted so the fact stops being
  // something someone once noticed. `not-first-in-block` is among them: the committed
  // testnet capture holds four transactions at a non-zero index, which is a refusal branch
  // firing on real traffic, not a hypothetical.
  ck('the real captures have already reached `not-first-in-block` — the branch whose '
     + 'production count on mainnet is zero', seen.has('not-first-in-block'));
  ck('…and `runtime-refused`', seen.has('runtime-refused'));
  ck('…and `not-attempted`', seen.has('not-attempted'));
  // ── `body-unavailable`'S PRODUCTION COUNT IS ZERO, AND THAT IS THE CORRECTION ────────
  //
  // It read 912 — 835 here and 77 in the mainnet capture — and every one of them was
  // written by a producer that had spoken only to the node. The member's condition needs
  // the file store to have been asked and to have answered that it holds no such body, and
  // no committed capture ever asked it. So the honest figure is ZERO, and it is asserted
  // as zero rather than left as an absence: a member whose count silently returns to
  // non-zero is a producer having found a way back to the claim.
  ck('…and `body-unavailable` is reached by NO committed capture, because no committed '
     + 'capture ever asked the file store — the member needs both of its clauses',
     !seen.has('body-unavailable'));
  // The members real data has NOT reached are named rather than left implicit: a set whose
  // unreached members are invisible is a set nobody can ask questions about. FIVE now —
  // `body-unavailable` joined them when the 912 rows that were claiming it were shown to
  // have established only half its condition.
  ck('five members are not yet reached by any committed capture, and that is stated '
     + `rather than silent: ${REFUSAL_REASON_IDS.filter((i) => !seen.has(i)).join(', ')}`,
     REFUSAL_REASON_IDS.filter((i) => !seen.has(i)).length === 5);
}

// ── the version policy, and the four store outcomes that are not one fact ───────────────
//
// Two properties of the SEAM, both of which were published false and neither of which the
// suite above could see.

test('the format token says something checkable, and `@1` is read whole');
{
  ck(`the token this tree writes is ${SNAPSHOT_FORMAT}`,
     SNAPSHOT_FORMAT === 'blocktracer/chain-snapshot@2');
  // §3: a version the reader does not SUPPORT is refused by name. `@1` is supported, so it
  // is read — and read WHOLE, which is the other half of §5.2's rule. The bump is not a
  // drop of the old format; it is the end of one token meaning two shapes.
  ck('…and `@1` is still readable, so an existing tree is not orphaned',
     isReadableSnapshotFormat('blocktracer/chain-snapshot@1'));
  ck('…and an unknown token is NOT readable, so it is refused by name rather than guessed',
     !isReadableSnapshotFormat('blocktracer/chain-snapshot@3')
       && !isReadableSnapshotFormat('')
       && !isReadableSnapshotFormat('blocktracer/chain-snapshot'));
  // THE DIFFERENCE BETWEEN THE TWO TOKENS, asserted. A version whose only difference a
  // reader does not act on is a label, and that is exactly what `@1` had become: ING-3 made
  // `refusalReason` mandatory on the producer side while the token and the reader both went
  // on treating it as optional.
  ck('`@2` requires `refusalReason` on every untraced row and `@1` does not — which is the '
     + 'whole content of the bump',
     requiresRefusalReason('blocktracer/chain-snapshot@2')
       && !requiresRefusalReason('blocktracer/chain-snapshot@1'));
  // The Nim reader reads the SAME file, with `staticRead`. Asserted over the source because
  // the two halves of the seam are in different languages and a token closed in one and open
  // in the other is not closed — the reasoning `refusal-reasons.json` already carries.
  const nimSrc = readFileSync(
    new URL('../../src/blocktracer/chain/snapshot_format.nim', import.meta.url), 'utf8');
  ck('the reader takes the policy from the same file, at COMPILE time, rather than spelling '
     + 'a literal of its own',
     /staticRead\("\.\.\/\.\.\/\.\.\/tools\/chain\/snapshot-format\.json"\)/.test(nimSrc));
  const ingestSrc = readFileSync(
    new URL('../../src/blocktracer/chain/ingest.nim', import.meta.url), 'utf8');
  ck('…and `ingest.nim`\'s gate is that policy and not a `!=` against one token',
     /isReadableSnapshotFormat\(snapFormat\)/.test(ingestSrc)
       && !/getStr != "blocktracer\/chain-snapshot@/.test(ingestSrc));
  ck('…and it ENFORCES the mandatory member on the token that requires it, naming the row',
     /requireRefusalReason and rr\.len == 0 and isUntracedSnapshotOutcome\(outcome\)/
       .test(ingestSrc));
  // And the migration is expressible: the tool that adds the member is the tool that stamps
  // the token, and it stamps only what it has just proved.
  const migrateSrc = readFileSync(
    new URL('./migrate-refusal-reasons.mjs', import.meta.url), 'utf8');
  ck('the `@1` -> `@2` migration is one command, and it stamps the token only after the '
     + 'audit is clean',
     /audit\.problems\.length === 0 && noReason\.length === 0\s*\n?\s*&& snap\.format !== SNAPSHOT_FORMAT/
       .test(migrateSrc)
       && /snap\.format = SNAPSHOT_FORMAT/.test(migrateSrc));
}

test('a store that could not be asked is not a body that does not exist');
{
  const rangeSrc = readFileSync(new URL('./ingest-range.mjs', import.meta.url), 'utf8');
  // ── C6: `unavailable` MUST NOT BECOME `body-unavailable` ────────────────────────────
  //
  // `replayRange` had one arm — `if (seen.outcome !== 'verified')` — into
  // `refuseBodyUnavailable`, whose member is declared durability PERMANENT. So a store 5xx,
  // a 429 or a TLS failure published "this transaction can never be re-executed" about a
  // body the store holds and serves, and the run exited 0.
  ck('`unavailable` reaches `body-source-unreachable`, which is repairable',
     refusalDurability('body-source-unreachable') === 'repairable'
       && /seen\.outcome === 'unavailable'[\s\S]{0,400}?refuseBodySourceUnreachable/
            .test(rangeSrc));
  ck('…and `body-unavailable`, which the four used to share, is permanent — so the split is '
     + 'between two different claims and not two spellings of one',
     refusalDurability('body-unavailable') === 'permanent');
  ck('…and a store throttle ends the run, the way the node path\'s already does',
     /if \(proxy\.storeThrottled\)[\s\S]{0,200}?stoppedBy = 'body-store-unreachable-this-run'/
       .test(rangeSrc)
       && /body-store-unreachable-this-run'\)[\s\S]{0,900}?process\.exit\(3\)/.test(rangeSrc));
  // ── C7: `mismatched` IS AN ALARM, matching the mirroring tool ───────────────────────
  //
  // "The corpus lied." `backfill-bodies.mjs` exits 1 on `counts.mismatched` because "the
  // exit code says whether the JOIN HELD"; this seam read the same store through the same
  // `classify`, filed it as `body-unavailable` and exited 0. Two tools, one corpus, opposite
  // verdicts — and the publishing one was the forgiving one.
  ck('`mismatched` is collected rather than published as a pruned body',
     /seen\.outcome === 'mismatched'[\s\S]{0,2500}?mismatchedBodies\.push/.test(rangeSrc));
  ck('…and it is FATAL in the replay path too, matching backfill-bodies.mjs',
     /report\.replay\.mismatchedBodies\?\.length[\s\S]{0,1400}?process\.exit\(1\)/
       .test(rangeSrc));
  const bodiesSrc = readFileSync(new URL('./backfill-bodies.mjs', import.meta.url), 'utf8');
  ck('…which is the tool it now agrees with', /counts\.mismatched \|\|/.test(bodiesSrc));
  // ── C6: THE STORE PATH HAS THE DISCIPLINE THE NODE PATH HAD ─────────────────────────
  //
  // No retry, no backoff, no `Retry-After`, no timeout, and the negative answer cached
  // unconditionally — so ONE 503 decided a key for the rest of the run.
  const proxySrc = readFileSync(new URL('./lib/body-proxy.mjs', import.meta.url), 'utf8');
  ck('the body fetch retries, backs off and honours `Retry-After` up to the same cap the '
     + 'node path uses',
     /for \(let attempt = 0; attempt < storeAttempts/.test(proxySrc)
       && /retryAfterMs > MAX_HONOURED_RETRY_AFTER_MS[\s\S]{0,300}?stats\.storeThrottled = true/
            .test(proxySrc));
  ck('…and it has a TIMEOUT, so a store that accepts a connection and stalls cannot hang '
     + 'the handler the driver is blocked on',
     /AbortSignal\.timeout\(storeTimeoutMs\)/.test(proxySrc));
  ck('…and an `unavailable` answer is NOT cached, because it is a fact about the run',
     /if \(entry\.outcome !== 'unavailable'\) bodies\.set\(key, entry\)/.test(proxySrc));
  // The guard is on ONE write site, and the condition names `unavailable` alone — so
  // `verified`, `absent`, `mismatched` and `truncated` are all still cached, which is the
  // deduplication this proxy exists for. A second, unguarded `bodies.set` would restore the
  // defect beside the fix, so the count of write sites is what is asserted.
  ck('…while every answer about the CORPUS still is, which is what the proxy is for — and '
     + 'there is exactly one place a body answer is cached, so the guard cannot be bypassed',
     (proxySrc.match(/bodies\.set\(/g) ?? []).length === 1);
  // ── `storeOutcome` / `storeReason` HAVE A CONSUMER ──────────────────────────────────
  //
  // They were written onto rows and read by nothing. A field with no consumer is a field
  // nobody notices going wrong.
  ck('the store\'s own answers reach the run report rather than only the row',
     /bodySourceUnreachable: storeUnreachable/.test(rangeSrc)
       && /mismatchedBodies,/.test(rangeSrc));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
// A PERMANENT CLAIM NEEDS BOTH ITS CLAUSES, AND THE CORPUS IS SWEPT FOR ONE THAT DOES NOT
// ═══════════════════════════════════════════════════════════════════════════════════════
//
// ── THE DEFECT, WHICH HAS NOW BEEN REPORTED THREE TIMES ────────────────────────────────
//
// `body-unavailable` is durability **permanent** — the page it reaches tells a reader that
// nothing anyone does to this pipeline will ever produce a trace — and its stated condition
// is a CONJUNCTION: "the node no longer serves the transaction's body AND THE FILE STORE
// CANNOT SUPPLY IT EITHER".
//
// Only the first clause is observable from a node. Four producers reached the member having
// established only that one, because the condition key they named (`node-no-longer-serves-
// body`) was spelled after that half, and a static migration map turned the legacy outcome
// `pruned` straight into the member with a comment calling the mapping "exact". 912
// committed rows carried the full permanent claim off the half: 835 in
// `client/fixtures/chain/aztec-testnet` and 77 in `client/fixtures/chain/aztec`, every one
// `firstInBlock: true` and `bodyRetained: 0`, in blocks 63,520–67,007 and 66,749–70,151.
//
// The second clause was then measured FALSE across exactly that range — 21 of 21 bodies
// sampled from block 10 to block 75,969 served and self-verified, and 12 of 12 from the
// frozen mainnet capture, six of them rows it had recorded as `pruned`.
//
// ── WHY THE CHECK IS OVER THE DATA AND NOT OVER THE CODE ───────────────────────────────
//
// Because the previous two reports were fixed in the code and the DATA kept the claim. A
// source scan asserting that `follow-chain.mjs` no longer calls `refuseBodyUnavailable`
// would go green over a tree holding 912 rows that say it did. So the row is asked for its
// evidence: `storeOutcome` is written onto a row by every producer that asked the store,
// and its absence beside `body-unavailable` is a permanent claim whose second clause
// nobody checked.
//
// Both halves are here — the corpus sweep, and the producer that can no longer be talked
// into it — and each has a mutation arm, because a sweep over a corpus that happens to be
// clean proves nothing about the sweep.

test('no committed row claims a permanent body loss the store was never asked about');
{
  // EVERY snapshot in the tree, not only `client/fixtures/chain/`. The block above reads
  // that one directory, and two of the three `@1` subjects live outside it — a sweep that
  // could not see them is a sweep the migration tool could walk past.
  const root = new URL('../../', import.meta.url).pathname;
  const all = ALL_COMMITTED_SNAPSHOTS.map((p) => join(root, p));
  ck(`the corpus is the whole tree's — ${all.length} snapshot(s), and every one exists`,
     all.length === 6 && all.every((p) => existsSync(p)));

  const unevidenced = [];
  let bodyUnavailable = 0;
  let rows = 0;
  for (const p of all) {
    for (const t of JSON.parse(readFileSync(p, 'utf8')).transactions ?? []) {
      rows++;
      if (t.refusalReason !== 'body-unavailable') continue;
      bodyUnavailable++;
      if (!storeWasAskedAndSaidNoBody(t)) {
        unevidenced.push(`${p}: ${t.txHash} claims body-unavailable (PERMANENT) with `
          + `storeOutcome ${JSON.stringify(t.storeOutcome ?? null)} — the store was never `
          + `asked, so the member's second clause was never established`);
      }
    }
  }
  ck(`the sweep is not vacuous — ${rows} committed row(s) read`, rows > 900);
  ck(`no row claims \`body-unavailable\` without the store's own answer beside it `
     + `(${bodyUnavailable} row(s) carry the member)`, unevidenced.length === 0);
  if (unevidenced.length) console.error(`    ${unevidenced.slice(0, 5).join('\n    ')}`);

  // MUTATION: the sweep's own predicate, driven against the shape 912 rows had. A sweep
  // that reported zero over a clean corpus and would also report zero over a dirty one is
  // the check reading `return true`.
  const asShipped = { txHash: '0xdead', blockNumber: 63620, outcome: 'pruned',
                      firstInBlock: true, bodyRetained: false,
                      refusalReason: 'body-unavailable',
                      reason: 'The node still serves this transaction\'s effects but no '
                        + 'longer serves its body … it can no longer be re-executed.' };
  bite('mutation: a row in the shape all 912 were committed in is CAUGHT by the predicate '
       + 'this sweep uses', !storeWasAskedAndSaidNoBody(asShipped));
  ck('control: the same row with the store\'s 404 recorded on it is accepted, so the '
     + 'predicate is not simply refusing the member',
     storeWasAskedAndSaidNoBody({ ...asShipped, storeOutcome: 'absent' }));
  // And the three answers that establish the clause are the three that mean "the store
  // spoke about this key and holds no body". `unavailable` is NOT one: a 503 is the store
  // saying nothing at all, and folding it in here would restore the defect the
  // `body-source-unreachable` split was made to end, at the evidence layer instead.
  ck('the three store answers that establish the clause are exactly absent, truncated and '
     + 'mismatched — and `unavailable` is not among them',
     STORE_ANSWERS_MEANING_NO_BODY.length === 3
       && ['absent', 'truncated', 'mismatched']
            .every((o) => storeWasAskedAndSaidNoBody({ storeOutcome: o }))
       && !storeWasAskedAndSaidNoBody({ storeOutcome: 'unavailable' })
       && !storeWasAskedAndSaidNoBody({ storeOutcome: 'verified' }));
}

test('the producer refuses to write the permanent member without the evidence for it');
{
  // THE ROOT CAUSE, CLOSED AT THE ONLY PLACE THE MEMBER CAN BE PRODUCED. A guard in one
  // producer would be a guard a fifth producer walks around; this one is in the function
  // all of them call.
  const e = threw(() => refuseBodyUnavailable({
    blockNumber: 63620, observedAs: 'it was below the replayable window', where: 'selftest' }));
  bite('mutation: `refuseBodyUnavailable` with no store answer THROWS rather than '
       + 'publishing a permanent claim', e !== null);
  bite('…and it throws the named error rather than dying near the problem',
       e?.name === 'BodyUnavailableWithoutStoreEvidence');
  bite('…and the message says what to write instead, both ways — `not-attempted` if the '
       + 'run did not ask, `body-source-unreachable` if it could not',
       /refuseBodyNotSoughtFromStore/.test(`${e?.message}`)
         && /refuseBodySourceUnreachable/.test(`${e?.message}`));
  // A 503 is not evidence EITHER, and this is the arm that keeps the two splits from
  // collapsing into each other: `unavailable` must not buy its way into the permanent
  // member by being a `storeOutcome`.
  bite('mutation: a store answer of `unavailable` is not evidence — the store said nothing '
       + 'about this key',
       threw(() => refuseBodyUnavailable({ blockNumber: 1, observedAs: 'x',
         storeOutcome: 'unavailable', where: 'selftest' }))
         ?.name === 'BodyUnavailableWithoutStoreEvidence');
  const ok = refuseBodyUnavailable({ blockNumber: 63620, observedAs: 'it was below the window',
                                     storeOutcome: 'absent', where: 'selftest' });
  ck('control: with the store\'s 404 it returns the member, so the guard is not refusing '
     + 'the whole path', ok.refusalReason === 'body-unavailable' && ok.outcome === 'pruned');
  ck('…and the sentence it writes SAYS the store was asked and what it answered, so the '
     + 'evidence is on the page and not only in a field',
     /was asked for it on this run and answered absent/.test(ok.reason));

  // AND THE MEMBER THE FOUR PRODUCERS GET INSTEAD, whose narrative is the one this
  // repository can support: the run did not look.
  const notSought = refuseBodyNotSoughtFromStore({
    blockNumber: 63620, observedAs: 'it was already below the replayable window when this '
      + 'follower first saw it', where: 'selftest' });
  ck('`refuseBodyNotSoughtFromStore` writes `not-attempted`, which is repairable',
     notSought.refusalReason === 'not-attempted'
       && refusalDurability(notSought.refusalReason) === 'repairable');
  ck('…and its outcome stays `pruned`, because that IS what the producer observed of the '
     + 'node — the correction is to the published claim, not to the observation',
     notSought.outcome === 'pruned');
  ck('…and its sentence does NOT say the transaction can no longer be re-executed, which '
     + 'is the clause that was measured false',
     !/can no longer be re-executed/.test(notSought.reason)
       && /this run never asked it/.test(notSought.reason));

  // THE OLD CONDITION KEY IS GONE RATHER THAN LEFT AS AN ALIAS. A producer still naming the
  // one-clause condition gets `UnknownRefusalCondition` — this module's stated policy for a
  // condition it does not know — instead of the member it used to reach.
  bite('mutation: the one-clause condition key `node-no-longer-serves-body` is no longer a '
       + 'condition at all',
       threw(() => classifyRefusal({ condition: 'node-no-longer-serves-body',
                                     where: 'selftest' }))
         ?.name === 'UnknownRefusalCondition');
  ck('…and the condition that does reach the member names BOTH clauses in its own key',
     classifyRefusal({ condition: 'node-pruned-and-store-does-not-hold-it',
                       where: 'selftest' }).refusalReason === 'body-unavailable');

  // THE THREE NODE-ONLY PRODUCERS CANNOT REACH IT, checked at the import. This is the
  // cheap half and it is kept because it names WHICH file would have to change to bring
  // the defect back, which the data sweep above cannot say.
  for (const tool of ['follow-chain.mjs', 'capture-chain.mjs', 'backfill-blocks.mjs']) {
    // COMMENTS STRIPPED FIRST, and that is not a convenience. All three carry a comment
    // naming `refuseBodyUnavailable` to say why they no longer call it — which is exactly
    // the record a later reader needs — and a scan that could not tell an explanation from
    // a call would force the explanation to be deleted to make the check green. A check
    // that penalises the note about itself is a check that erases its own history.
    const code = readFileSync(new URL(`./${tool}`, import.meta.url), 'utf8')
      .replace(/^[ \t]*\/\/.*$/gm, '');
    ck(`${tool} — which talks to the node and to nothing else — neither imports nor calls `
       + `\`refuseBodyUnavailable\``, !/refuseBodyUnavailable/.test(code));
  }
  // …and the one that DOES ask the store passes the answer at every site that produces the
  // member. Counted, so a new site added without the argument is a red arm rather than a
  // silent third call.
  const rangeSrc = readFileSync(new URL('./ingest-range.mjs', import.meta.url), 'utf8');
  const calls = rangeSrc.match(/refuseBodyUnavailable\(\{/g) ?? [];
  ck(`ingest-range.mjs is the only producer that reaches the member, at ${calls.length} `
     + `site(s), and every one passes \`storeOutcome\``,
     calls.length === 2
       && (rangeSrc.match(/refuseBodyUnavailable\(\{[\s\S]{0,700}?storeOutcome: seen\.outcome/g)
           ?? []).length === 2);
}

test('the legacy classifier decides `pruned` from evidence, not from the outcome\'s name');
{
  // THE MIGRATION MAP THAT MADE THE 912. It was `FROM_OUTCOME = { pruned: 'body-unavailable',
  // … }`, a frozen literal under a comment calling the mapping exact. It is now a function
  // in `lib/refusal.mjs` — shared with the tool, for the reason `looksLikePrivateOnlyCrash`
  // is shared — and it asks the row.
  const bare = { outcome: 'pruned', txHash: '0x1', blockNumber: 63620 };
  bite('mutation: a `pruned` row with no record of the store being asked classifies as '
       + '`not-attempted`, NOT as the permanent member',
       memberForLegacyUntracedRow(bare).member === 'not-attempted');
  ck('…and the classifier says why, so a reader can check the grounds rather than the map',
     /never established/.test(memberForLegacyUntracedRow(bare).why));
  ck('control: the same row carrying the store\'s 404 classifies as `body-unavailable`, so '
     + 'the arm is a decision and not a blanket rewrite',
     memberForLegacyUntracedRow({ ...bare, storeOutcome: 'absent' }).member
       === 'body-unavailable');
  // The two that really do name their member, and the one decided by the runtime class —
  // unchanged, and asserted so this correction cannot quietly move them.
  ck('`not-first-in-block` and `not-attempted` still come from the outcome, which names '
     + 'the member in both',
     memberForLegacyUntracedRow({ outcome: 'not-first-in-block' }).member
       === 'not-first-in-block'
       && memberForLegacyUntracedRow({ outcome: 'not-attempted' }).member === 'not-attempted');
  ck('…and `refused` still comes from the runtime class the row recorded',
     memberForLegacyUntracedRow({ outcome: 'refused', refusal: 'MissingContractArtifact' })
       .member === 'artifact-unresolvable'
       && memberForLegacyUntracedRow({ outcome: 'refused', refusal: 'unknown' }).member
            === 'runtime-refused');
  ck('an outcome with no rule returns null rather than a default — this tool\'s job is to '
     + 'leave nothing unclassified, and a default would hide the gap',
     memberForLegacyUntracedRow({ outcome: 'something-else' }).member === null);
  // AND THE TOOL USES IT. A shared classifier the migration tool does not call would be two
  // classifiers again, which is the arrangement that produced the defect.
  const migrateSrc = readFileSync(
    new URL('./migrate-refusal-reasons.mjs', import.meta.url), 'utf8');
  ck('the migration tool takes its classification from the shared function and declares no '
     + 'outcome→member literal of its own',
     /memberForLegacyUntracedRow\(t\)/.test(migrateSrc)
       && !/FROM_OUTCOME/.test(migrateSrc));
  ck('…and it corrects a WRONG member rather than only filling in blanks, asking before '
     + 'the already-classified short-circuit',
     /t\.refusalReason === 'body-unavailable'\s*\n?\s*&& !storeWasAskedAndSaidNoBody\(t\)/
       .test(migrateSrc)
       && migrateSrc.indexOf('!storeWasAskedAndSaidNoBody(t)')
            < migrateSrc.indexOf('if (isRefusalReason(t.refusalReason)) { already++'));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
// THE THREE `@1` SUBJECTS THE MIGRATION TOOL MUST NOT CONSUME
// ═══════════════════════════════════════════════════════════════════════════════════════
//
// `@1` is not only a legacy token, it is a SHAPE THE READER HAS TO BE TESTED AGAINST:
// Data-Contract.md §3.1 rule 2 obliges a reader that accepts a token to consume every member
// that token defines, and the only way to check that obligation is to hold an artifact in
// that shape and read it. This repository has exactly three, and
// `migrate-refusal-reasons.mjs` run over the corpus with a glob would promote all three in
// one command — it did, in a review rehearsal. The reader's `@1` path would then have no
// population and the `@1` half of §5.2a's both-directions token audit would be vacuously
// true, which is a gate losing its subjects through the tool written to close it.
//
// Nothing in the tree recorded that intent, so both halves are asserted: the tool holds
// them out, and each file says why it is frozen.

test('the three `@1` subjects stay `@1`, and each one records why');
{
  const root = new URL('../../', import.meta.url).pathname;
  const migrateSrc = readFileSync(
    new URL('./migrate-refusal-reasons.mjs', import.meta.url), 'utf8');
  ck(`the tool carries an explicit hold-out list — ${HELD_OUT_PATHS.length} path(s)`,
     HELD_OUT_PATHS.length === 3
       && HELD_OUT_PATHS.every((p) => migrateSrc.includes(p)));
  ck('…and an explicit override for the day `@1` support is actually retired, so the '
     + 'hold-out is a decision and not a wall',
     /--include-held-out/.test(migrateSrc));
  const stillV1 = HELD_OUT_PATHS.filter((p) =>
    JSON.parse(readFileSync(join(root, p), 'utf8')).format
      === 'blocktracer/chain-snapshot@1');
  ck('every held-out subject is still `blocktracer/chain-snapshot@1` on disk',
     stillV1.length === 3);
  // THE SHAPES THEY CARRY ARE DIFFERENT, and that is why three are held rather than one: a
  // single `@1` subject would leave two of the three shapes with no population.
  const shapes = HELD_OUT_PATHS.map((p) => {
    const s = JSON.parse(readFileSync(join(root, p), 'utf8'));
    const rows = s.transactions ?? [];
    return { untraced: rows.filter((t) => UNTRACED_OUTCOMES.includes(t.outcome)).length,
             withMember: rows.filter((t) => typeof t.refusalReason === 'string').length,
             counts: s.counts !== undefined };
  });
  ck('one carries NO untraced rows at all, which is the simplest `@1` tree there is',
     shapes.some((s) => s.untraced === 0));
  ck('…and two carry untraced rows with NO member, which is exactly the shape `@1` permits '
     + 'and `@2` forbids — the population the reader\'s older-token path is checked on',
     shapes.filter((s) => s.untraced > 0 && s.withMember === 0).length === 2);
  // THE INTENT IS RECORDED IN THE TREE, which is what was missing. Two say so in a
  // `_comment` inside the JSON; the third cannot, because it is the live follower's output
  // byte for byte and editing it would end the property that makes it worth keeping — so
  // it says so in a sidecar beside it. Either is accepted; NEITHER is not.
  const undocumented = [];
  for (const p of HELD_OUT_PATHS) {
    const doc = JSON.parse(readFileSync(join(root, p), 'utf8'));
    const inFile = `${JSON.stringify(doc._comment ?? '')}`;
    const sidecar = join(root, p.replace(/snapshot\.json$/, 'HELD-AT-V1.md'));
    const beside = existsSync(sidecar) ? readFileSync(sidecar, 'utf8') : '';
    if (!/HELD AT blocktracer\/chain-snapshot@1/.test(inFile)
        && !/held at `blocktracer\/chain-snapshot@1`/.test(beside)) {
      undocumented.push(p);
    }
  }
  ck('each held-out subject records the intent where a reader of that file meets it — in '
     + 'its own `_comment`, or in a `HELD-AT-V1.md` beside it', undocumented.length === 0);
  if (undocumented.length) console.error(`    ${undocumented.join('\n    ')}`);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
// `captureSessions`: THE HALF OF THE `captures` FIX NOTHING COVERED
// ═══════════════════════════════════════════════════════════════════════════════════════
//
// `recount.mjs` writes `counts.captureSessions = Array.isArray(s.captures) ? s.captures.length
// : null`, and the comment above it explains at length why `null` and not `undefined`. A
// review reverted it to `(s.captures ?? []).length` — the exact half the comment is about —
// and EVERY SUITE IN THIS REPOSITORY STILL PASSED. The member appears at one site tree-wide
// and nothing read it.
//
// The mechanism is the one that produced the `l1ChainId` crash: `JSON.stringify` DROPS an
// undefined-valued key, so the reverted line does not write a wrong number, it writes NO
// KEY — and an absent count reads as a snapshot that never had one rather than as a count
// that could not be taken. That is not hypothetical: `aztec-testnet-frames`' `captures` was
// committed as a JSON OBJECT with numeric string keys, `.length` on it is `undefined`, and
// `ingest.nim` — gating on `caps.kind == JArray` — silently skipped the whole per-capture
// recorder attribution for that snapshot.
//
// So the assertion is made where the defect lives: after a round trip through JSON, which
// is the only place the difference between `null` and `undefined` becomes visible.

test('a `captures` that cannot be counted publishes `null`, and the key SURVIVES');
{
  const base = { blocks: [], transactions: [] };
  const roundTrip = (s) => { const c = { ...s }; recountSnapshot(c);
                             return JSON.parse(JSON.stringify(c)).counts; };

  // 1. THE COMMITTED SHAPE. `aztec-testnet-frames` shipped `captures` as an object.
  const asObject = roundTrip({ ...base, captures: { 0: { at: 'x' }, 1: { at: 'y' } } });
  bite('mutation: a `captures` committed as a JSON OBJECT counts as `null` — not countable '
       + '— rather than as a number', asObject.captureSessions === null);
  bite('…and the key is STILL THERE after a JSON round trip, which is the whole difference '
       + 'between `null` and `undefined` and the mechanism behind the `l1ChainId` crash',
       Object.prototype.hasOwnProperty.call(asObject, 'captureSessions'));

  // 2. AND AN ABSENT `captures`, which the reverted line scores as a confident zero.
  const absent = roundTrip({ ...base });
  bite('mutation: an ABSENT `captures` is `null` and not `0` — "no sessions were recorded" '
       + 'and "this is not countable" are different facts', absent.captureSessions === null);
  bite('…and it too survives the round trip rather than vanishing from the tally',
       Object.prototype.hasOwnProperty.call(absent, 'captureSessions'));

  // 3. THE CONTROL. A real `captures` array still counts, so none of the above is satisfied
  //    by a member that is always `null`.
  const real = roundTrip({ ...base, captures: [{ at: 'a' }, { at: 'b' }, { at: 'c' }] });
  ck('control: an ARRAY of three capture sessions still counts as 3',
     real.captureSessions === 3);
  ck('…and an EMPTY array counts as 0, which is a measurement and not an absence — the one '
     + 'value the reverted line and this one agree on, stated so the split is visible',
     roundTrip({ ...base, captures: [] }).captureSessions === 0);

  // 4. AND THE COMMITTED TREE IS ASKED THE SAME QUESTION. The arms above run over rows this
  //    file built; this is the population.
  const root = new URL('../../', import.meta.url).pathname;
  const missing = [];
  for (const p of ALL_COMMITTED_SNAPSHOTS) {
    const s = JSON.parse(readFileSync(join(root, p), 'utf8'));
    if (s.counts === undefined) continue;   // `@1` subjects predate the tally — §5.2 scopes
                                            // the reconciliation to `@2`.
    if (!Object.prototype.hasOwnProperty.call(s.counts, 'captureSessions')) missing.push(p);
  }
  ck('every committed snapshot that publishes a `counts` publishes a `captureSessions` in '
     + 'it, present rather than dropped', missing.length === 0);
  if (missing.length) console.error(`    ${missing.join('\n    ')}`);
}

test('the recipe\'s declared assertion total is the one the suites declare');
{
  // ── WHY A CHECK FOR AN ARITHMETIC SENTENCE IN A JUSTFILE ────────────────────────────
  //
  // Because it has been wrong three times, in the same way each time, and nothing ever
  // compared it to anything. `chain-selftest`'s header states
  // `A + B + C + D + E + F = T`, every term is a COPY of a number the suite itself
  // declares, and the copy goes stale silently:
  //
  //   * "three suites, 124" while the recipe ran four — the fold suite was wired in and
  //     the sentence was not moved;
  //   * 31 for the body verifier while that suite printed 57, its own CI step having said
  //     57 for as long as the enumeration split;
  //   * `87 + 19 + 24 + 24 + 57 + 102 = 313` at the pre-landing review, against a real
  //     334 — `replay-selftest` had reached 93 and `refusal-selftest` 117.
  //
  // Correcting it a third time without closing the loop would guarantee a fourth. So the
  // sentence is now CHECKED: each term is read out of the suite that owns it, and the
  // arithmetic is checked as arithmetic.
  //
  // THE SIX DECLARATIONS ARE IN FIVE DIFFERENT SHAPES, which is why each has its own
  // pattern rather than one generic sweep. A generic regex over six phrasings is the
  // false-green this file exists to refuse: it would silently match five and score the
  // sixth as absent. If a suite rephrases its declaration this arm goes RED, which is
  // correct — the declaration moved, and a checker that guessed where it went would be
  // back to reading prose.
  const declared = [
    ['replay-selftest.mjs', /^\s*expectCount\((\d+)\);/m],
    ['freeze-snapshot-selftest.mjs', /asserted !== (\d+)\) \{/],
    ['watch-chain-selftest.sh', /"\$asserted" -ne (\d+) \]/],
    ['calltrace-fold-selftest.mjs', /asserted !== (\d+)\) \{/],
    ['backfill-bodies-selftest.mjs', /asserted !== (\d+)\) \{/],
    ['refusal-selftest.mjs', /^expectCount\((\d+)\);/m],
    ['coverage-contiguity-selftest.mjs', /asserted !== (\d+)\) \{/],
  ];
  const terms = [];
  for (const [file, re] of declared) {
    const src = readFileSync(new URL(`./${file}`, import.meta.url), 'utf8');
    const m = re.exec(src);
    ck(`${file} declares its own assertion count${m ? ` — ${m[1]}` : ''}`, m !== null);
    terms.push(m ? Number(m[1]) : NaN);
  }
  // The recipe's sentence, parsed as the arithmetic it is. `Justfile` is two directories
  // up from this file.
  const justfile = readFileSync(new URL('../../Justfile', import.meta.url), 'utf8');
  const m = /# SEVEN suites — ((?:\d+ \+ )+\d+) = (\d+) counted assertions/.exec(justfile);
  ck('the `chain-selftest` header states the total as arithmetic over per-suite terms',
     m !== null);
  if (m) {
    const stated = m[1].split(' + ').map(Number);
    const statedTotal = Number(m[2]);
    // ORDER MATTERS and is asserted, because the recipe runs the suites in that order and
    // a reader matches term to suite by position. A header whose terms are the right
    // multiset in the wrong order names the wrong suite in every diff.
    ck(`the header's seven terms are the suites' own declarations, in recipe order — `
       + `[${stated.join(', ')}] vs [${terms.join(', ')}]`,
       stated.length === terms.length && stated.every((n, i) => n === terms[i]));
    ck(`…and the header's arithmetic closes — ${stated.join(' + ')} = ${statedTotal}`,
       stated.reduce((a, b) => a + b, 0) === statedTotal);
  } else {
    ck('(header unparsed, so its terms cannot be checked)', false);
    ck('(header unparsed, so its total cannot be checked)', false);
  }
}

test('a producer with no arguments prints usage instead of ingesting range 0..0');
{
  // ── WHY THIS IS A SPAWN AND NOT A SOURCE SCAN ─────────────────────────────────────
  //
  // `Number(arg('from', 0))` yields a finite `0` whether or not `--from` was passed, so
  // the guard at the top of each of these tools — whose stated job is to ask "were
  // numbers supplied" — could not ask it. `node tools/chain/ingest-range.mjs` with NO
  // ARGUMENTS therefore passed the guard and silently ingested range 0..0 against the
  // default testnet endpoint: a state directory, a range, a ledger entry and a publish
  // attempt, instead of the usage message the guard was written to print. The comment
  // above that guard said the opposite in the same breath.
  //
  // A source scan would assert the shape of the fix; this asserts the BEHAVIOUR, which
  // is the thing that was wrong. It is safe to run offline precisely because the fix
  // works — the process exits 2 before any `fetch` — so an arm that hung or reached the
  // network would itself be the failure. `--url` is pointed at a closed loopback port
  // as a second belt: if a future edit ever lets one of these past the guard with no
  // range, it fails to connect instead of touching a real endpoint.
  const guarded = [
    ['ingest-range.mjs', '--from N --to M'],
    ['backfill-blocks.mjs', '--snapshot <dir> --from N --to M'],
    ['backfill-bodies.mjs', '--from N --to M'],
  ];
  for (const [tool, wants] of guarded) {
    const r = spawnSync(process.execPath,
                        [new URL(`./${tool}`, import.meta.url).pathname,
                         '--url', 'http://127.0.0.1:1'],
                        { encoding: 'utf8', timeout: 30_000 });
    ck(`${tool} with no range exits 2 — the usage code, not a run`, r.status === 2);
    ck(`…and says what it wanted: ${wants}`,
       `${r.stderr}`.includes('usage:') && `${r.stderr}`.includes(wants));
    // AND IT DID NOT DO ANYTHING. A tool that printed usage and also wrote a state
    // directory would satisfy the two arms above and still be the defect.
    ck(`…and wrote nothing to stdout, so no report was produced`,
       `${r.stdout}`.trim().length === 0);
  }
  // THE DEFAULT IS `undefined` AND NOT `0`, which is the mechanism rather than the
  // symptom — asserted so a future edit cannot restore the `0` while leaving the
  // `Number.isFinite` guard in place and passing the arms above by accident on a
  // different path.
  for (const tool of ['ingest-range.mjs', 'backfill-blocks.mjs', 'backfill-bodies.mjs']) {
    const src = readFileSync(new URL(`./${tool}`, import.meta.url), 'utf8');
    ck(`${tool} defaults --from/--to to \`undefined\`, so absence is distinguishable `
       + `from zero`,
       /const from = Number\(arg\('from', undefined\)\)/.test(src)
         && /const to = Number\(arg\('to', undefined\)\)/.test(src));
    // …and height ZERO is still a legal request. `!from` refused it in two of the three,
    // and zero is the one height a genesis-to-tip pass starts at.
    ck(`…and its guard admits height zero`,
       /Number\.isFinite\(from\)/.test(src) && !/!from \|\|/.test(src));
  }
}

// 102 before `ingest-range.mjs --replay`.
//   +4  the fourth producer: its own gate, its per-reason counts, its outcome literals, and
//       the arm that keeps a rate limit off the transaction's row. Each of the four was run
//       against `ingest-range.mjs` as it stood at 77b1d59, before the seam existed, and all
//       four are FALSE there — so they are checks and not restatements.
//   +11 `private-only`: eight properties of the outcome and three mutations, all of which
//       redden. It is a whole new answer a transaction can have and it is the one that keeps
//       a permanent limit of the CHAIN'S from being published as a repairable fault of ours.
// = 117, which is where the pre-landing review found it.
//   +2  `body-source-unreachable`, the eighth member: one row of it built through the shared
//       producer, and the unreached-member count widened from three to four.
//   +1  the shared tally publishes the three-population reconciliation — the assertion that
//       `follow-chain.mjs`'s own copy of `recount` FAILED, because it had no `privateOnly`
//       line and its `accountedFor` therefore could not equal `transactions`.
//   +2  the two producers whose `recount` copies are gone take the tally from `lib/recount.mjs`.
//   +5  the committed captures, widened past `.transactions`: their `counts` agrees with
//       their rows member by member, their token is one this tree reads, the token's
//       mandatory members are all present, and `captures` is an array. Each of the four was
//       FALSE in the committed tree — `pruned: 25` against 835 rows, `privateOnly` absent
//       everywhere, and a `captures` committed as a JSON object.
//   +2  the seven reclassified rows keep the private-only crash signature AND stay
//       `private-only` with no reason id.
//   +8  the version policy: what this tree writes, that `@1` is still read, that an unknown
//       token is not, that the two tokens differ by the mandatory member, that the Nim
//       reader takes the policy from the same file at compile time, that its gate is that
//       policy rather than a `!=`, that it ENFORCES the member, and that the migration is
//       one command which stamps only what it proved.
//   +9  the store outcomes that are not one fact: `unavailable` is repairable and
//       `body-unavailable` permanent, a store throttle ends the run, `mismatched` is
//       collected and FATAL and agrees with the mirroring tool, the fetch retries/backs
//       off/honours Retry-After, it has a timeout, an `unavailable` answer is not cached
//       while corpus answers are, and the store's answers reach the report.
// = 170, which is where the landing review found it.
//   +8  THE SECOND CLAUSE OF `body-unavailable`, over the committed corpus: the sweep
//       covers all six snapshots tree-wide and is proved non-vacuous, no row claims the
//       permanent member without the store's own answer, the predicate CATCHES the shape
//       all 912 rows shipped in and ACCEPTS the same row with a 404 recorded, and the
//       three answers that establish the clause are exactly the three that mean the store
//       spoke about this key.
//   +11 …and the producer side of it: `refuseBodyUnavailable` throws a NAMED error without
//       evidence, its message says what to write instead in both directions, a 503 is not
//       evidence either, the control still returns the member and its sentence says what
//       the store answered, `refuseBodyNotSoughtFromStore` is repairable / keeps `pruned`
//       / drops the false clause, the one-clause condition key is gone rather than
//       aliased, and the three node-only producers cannot reach the member while the one
//       that asks the store passes its answer at both sites.
//   +8  the legacy classifier: `pruned` with no evidence is `not-attempted` and with a 404
//       is `body-unavailable`, it states its grounds, the two outcomes that really do name
//       their member still do, `refused` still comes from the runtime class, an unknown
//       outcome returns null, the tool uses the shared function and declares no literal of
//       its own, and it corrects a wrong member before the already-classified short-circuit.
//   +8  the three `@1` subjects: the hold-out list exists and names them, there is a
//       deliberate override, all three are still `@1` on disk, the three shapes they carry
//       are different, and each records the intent where a reader of that file meets it.
//   +8  `counts.captureSessions`, which appeared at ONE site tree-wide and was covered by
//       nothing — so the landing review's revert of it passed every suite. Asserted AFTER
//       a JSON round trip, which is the only place `null` and `undefined` differ, on the
//       object shape `aztec-testnet-frames` actually shipped and on an absent key, with an
//       array control and the committed tree asked the same question.
expectCount(213);
console.error(failed === 0
  ? '\nPASS — the closed set bites on every arm'
  : `\nFAIL — ${failed} assertion(s)`);
process.exit(failed === 0 ? 0 : 1);
