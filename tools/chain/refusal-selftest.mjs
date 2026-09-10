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
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  REFUSAL_REASONS, REFUSAL_REASON_IDS, REFUSAL_REASONS_PATH,
  UnknownRefusalCondition, UnexplainedAbsence,
  classifyRefusal, reasonForRuntimeClass, refusalCounts, auditRefusals,
  assertRefusalsAreClosed, assertAbsentIsNotARefusal, isRefusalReason, refusalDurability,
  refuseNotFirstInBlock, refuseBodyUnavailable,
  OUTCOMES, TRACED_OUTCOMES, UNTRACED_OUTCOMES,
} from './lib/refusal.mjs';
import { decideOutcome } from './lib/replay.mjs';
import { scanVerdict } from './scan-tx-index.mjs';

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
  // 2. body-unavailable — likewise.
  rows.push({ txHash: '0x02', blockNumber: 101, txIndexInBlock: 0,
              ...refuseBodyUnavailable({ blockNumber: 101, observedAs: 'it was below the window',
                                         where: 'selftest' }) });
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
  ck('and all seven are counted as untraced', audit.untraced === rows.length);
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
    ck('…and publishes per-reason counts in `recount`',
       /function recount[\s\S]{0,2000}?refusalCounts/.test(followSrc));
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
    ck('…and publishes per-reason counts in its own `recount`',
       /function recount[\s\S]{0,1600}?refusalCounts/.test(rangeSrc));
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
  const seen = new Set();
  const problems = [];
  for (const p of snaps) {
    const rows = JSON.parse(readFileSync(p, 'utf8')).transactions ?? [];
    const a = auditRefusals(rows);
    untraced += a.untraced;
    traced += a.traced;
    for (const q of a.problems) problems.push(`${p}: ${q}`);
    for (const id of Object.keys(refusalCounts(rows).byReason)) {
      if (refusalCounts(rows).byReason[id] > 0) seen.add(id);
    }
  }
  ck(`the population is not empty — ${untraced} untraced row(s) across ${snaps.length} `
     + `captures, against ${traced} traced`, untraced > 100);
  ck('every one of them carries a reason from the closed set', problems.length === 0);
  if (problems.length) console.error(`    ${problems.slice(0, 5).join('\n    ')}`);
  // WHICH MEMBERS THE REAL DATA HAS ALREADY REACHED, asserted so the fact stops being
  // something someone once noticed. `not-first-in-block` is among them: the committed
  // testnet capture holds four transactions at a non-zero index, which is a refusal branch
  // firing on real traffic, not a hypothetical.
  ck('the real captures have already reached `not-first-in-block` — the branch whose '
     + 'production count on mainnet is zero', seen.has('not-first-in-block'));
  ck('…and `body-unavailable`', seen.has('body-unavailable'));
  ck('…and `runtime-refused`', seen.has('runtime-refused'));
  ck('…and `not-attempted`', seen.has('not-attempted'));
  // The three that real data has NOT reached are named rather than left implicit: a set
  // whose unreached members are invisible is a set nobody can ask questions about.
  ck('three members are not yet reached by any committed capture, and that is stated '
     + `rather than silent: ${REFUSAL_REASON_IDS.filter((i) => !seen.has(i)).join(', ')}`,
     REFUSAL_REASON_IDS.filter((i) => !seen.has(i)).length === 3);
}

// 102 before `ingest-range.mjs --replay`; +4 for the fourth producer's own gate, its
// per-reason counts, its outcome literals and the arm that keeps a rate limit off the
// transaction's row. Each of the four was run against `ingest-range.mjs` as it stood at
// 77b1d59, before the seam existed, and all four are FALSE there — so they are checks and
// not restatements.
expectCount(106);
console.error(failed === 0
  ? '\nPASS — the closed set bites on every arm'
  : `\nFAIL — ${failed} assertion(s)`);
process.exit(failed === 0 ? 0 : 1);
