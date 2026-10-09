#!/usr/bin/env node
// yield-method-selftest.mjs — proof that the YIELD METHOD is applied rather than described.
//
//   node tools/chain/yield-method-selftest.mjs
//
// ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
// A yield figure is the number that decides whether a chain ships, which makes it the
// number most exposed to being chosen after the fact — and the two committed readings this
// repository holds were, until this suite, READ BY NOTHING. `git grep -l` for either
// artifact token found only the files themselves. So the baseline several documents state
// their acceptance criteria against had no reader at all, which is the shape a whole
// directory of this repository's other suites exist to remove: a rule nobody has watched
// refuse is indistinguishable from `return true`.
//
// `tools/chain/yield-method.json` is the method as data and `tools/chain/lib/yield.mjs`
// applies it. This suite is where each of its rules is watched going red.
//
// ── WHAT EACH SECTION IS FOR ───────────────────────────────────────────────────────────
//
//   §1  the method file itself: format, and its rule ids DISJOINT from the contract's and
//       the health sweep's, in both directions, each with an anti-vacuity guard
//   §2  THE DENOMINATOR IS THE ENUMERATION. Driven over a real committed snapshot, so
//       "every transaction in the window" is an operation over rows rather than a figure
//       in an artifact — with the producer's own §5.2 tally as the second opinion
//   §3  PER-WINDOW FIGURES CANNOT CANCEL INTO A PASSING TOTAL. Two windows moved in
//       opposite directions by the same amount, which leaves every total untouched
//   §4  BOTH DENOMINATORS, AND THE DISTINCTION MEASURED. The corpus supplies committed
//       trees on BOTH sides — some with a population the chain never published an
//       execution for, some with none — and each side is floored, so a check that always
//       printed two numbers could not pass this
//   §5  A RE-RUN OVER THE PINNED WINDOWS, and the four verdicts. This is where the
//       measured 208-against-211 lives: a re-run may differ for a reason outside the
//       producer, and neither "reproduced" nor "the producer is broken" is true of it
//   §6  the windows PINNED by absolute range, their recorded provenance declared, and the
//       range BOUNDED below the finalized head
//   §7  `ledger.replay.attempted` is per-pass. The corpus holds both passes over one
//       window, so this is a measurement rather than a caution
//   §8  the classification is NOT restated here — the outcome partition is imported
//
// OFFLINE AND TOOLCHAIN-FREE, which is what qualifies it for `chain-selftest`: it reads
// files already in this repository and runs `node`. It reaches no network and spawns
// nothing but `git ls-files`, whose failure is a FAILURE here and not a skip.

import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  yieldMethod, yieldRuleIds, pinnedFor, checkReading, compareReadings, normaliseReading,
  readingFromSnapshot, denominatorsOf, populationOf, sameWindows,
  YIELD_METHOD_FORMAT,
} from './lib/yield.mjs';
import { SNAPSHOT_OUTCOMES } from './lib/snapshot-format.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..', '..');

let asserted = 0, failed = 0;
const ck = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`);
};
/** A mutation arm is only evidence if it REDDENS. */
const bite = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  MUTATION DID NOT BITE  ${label}`); }
  else console.error(`  bite  ${label}`);
};
const test = (name) => console.error(`\n${name}`);

const readJson = (p) => JSON.parse(readFileSync(join(ROOT, p), 'utf8'));
const clone = (x) => JSON.parse(JSON.stringify(x));

const METHOD = yieldMethod();
const PINNED = pinnedFor('aztec-testnet', METHOD);
const READING = readJson('tools/chain/measurements/historic-replay-yield.json');
const RERUN = readJson('tools/chain/measurements/baseline-rerun.json');

/** rule ids raised by a run of `checkReading` */
const raised = (doc, method = METHOD) =>
  [...new Set(checkReading(doc, method).findings.map((f) => f.rule))].sort();
const fires = (doc, rule, method = METHOD) => raised(doc, method).includes(rule);

// ═══ §1 the method file, and the three id sets that must stay apart ═════════════════════
test('§1 the method is data, and its rule ids are its own');
{
  ck(`the method declares ${YIELD_METHOD_FORMAT}`, METHOD.format === YIELD_METHOD_FORMAT);

  const mine = yieldRuleIds(METHOD);
  const contract = Object.keys(readJson('tools/chain/snapshot-contract.json').rules);
  const health = Object.keys(readJson('tools/chain/health-checks.json').checks);

  // ANTI-VACUITY FIRST, on all three. Disjointness between an empty set and anything is
  // trivially true, so an unreadable or renamed file would satisfy the rule below by
  // finding nothing — which is the failure mode the health registry's own header names.
  ck(`the three id sets are all non-empty — ${mine.length} method, ${contract.length} `
     + `contract, ${health.length} health`,
     mine.length >= 7 && contract.length >= 20 && health.length >= 5);
  const overlap = (a, b) => a.filter((x) => b.includes(x));
  ck('the method\'s rule ids are disjoint from the CONTRACT\'s rule ids — a rule stated '
     + 'twice is two answers to one question',
     overlap(mine, contract).length === 0 && overlap(contract, mine).length === 0);
  ck('…and from the recording-health finding ids',
     overlap(mine, health).length === 0 && overlap(health, mine).length === 0);

  const planted = clone(METHOD);
  planted.rules[contract[0]] = { question: 'q', healthy: 'h', fires: 'f', why: 'w' };
  bite(`mutation: the contract rule id \`${contract[0]}\` planted in the method makes the `
       + 'disjointness fail', overlap(yieldRuleIds(planted), contract).length > 0);
  const planted2 = clone(METHOD);
  planted2.rules[health[0]] = { question: 'q', healthy: 'h', fires: 'f', why: 'w' };
  bite(`mutation: the health finding id \`${health[0]}\` planted in the method makes it fail`,
       overlap(yieldRuleIds(planted2), health).length > 0);

  const incomplete = mine.filter((id) => ['question', 'healthy', 'fires', 'why']
    .some((k) => typeof METHOD.rules[id][k] !== 'string' || !METHOD.rules[id][k].length));
  ck(`every rule states its question, its healthy case, when it fires and why — `
     + `${mine.length} rule(s)${incomplete.length ? `, incomplete: ${incomplete}` : ''}`,
     incomplete.length === 0);

  const vocab = METHOD.expectedVariableVocabulary;
  ck(`the expected-variable vocabulary is a closed non-empty set with no repeat — `
     + `${vocab.length} member(s)`,
     Array.isArray(vocab) && vocab.length >= 3 && new Set(vocab).size === vocab.length);
}

// ═══ §2 the denominator is the enumeration, taken from the snapshot itself ══════════════
test('§2 the denominator is every transaction in the window, counted off the rows');
{
  // A REAL COMMITTED SNAPSHOT, not a constructed one, and specifically the one with a
  // population the chain never published an execution for: 88 rows over blocks
  // 66,749-70,176, of which 2 are traced. If the denominator were the count of rows that
  // produced a trace, this chain would read 100%.
  const path = 'client/fixtures/chain/aztec/snapshot.json';
  const snap = readJson(path);
  const lo = Math.min(...snap.transactions.map((t) => t.blockNumber));
  const hi = Math.max(...snap.transactions.map((t) => t.blockNumber));
  const r = readingFromSnapshot(snap, [[lo, hi]]);
  const w = r.windows[0];

  // an INDEPENDENT count of the same thing, so the assertion is not the function agreeing
  // with itself
  const enumerated = snap.transactions.filter((t) => t.blockNumber >= lo && t.blockNumber <= hi)
                         .length;
  ck(`${path}: the window's denominator is the enumerated row count — ${w.transactions} `
     + `= ${enumerated}`, w.transactions === enumerated);
  ck(`…and it is the producer's own §5.2 tally, which is a second opinion the run cannot `
     + `move — counts.transactions = ${snap.counts.transactions}`,
     w.transactions === snap.counts.transactions);
  ck(`…and it is NOT the numerator: ${w.traced} traced of ${w.transactions}`,
     w.traced > 0 && w.traced < w.transactions);
  ck(`…and every row is in exactly one population — ${w.traced} traced + ${w.untraced} `
     + `untraced + ${w.chainAbsent} chain-absent + ${w.unclassified} unclassified`,
     w.traced + w.untraced + w.chainAbsent + w.unclassified === w.transactions
     && w.unclassified === 0);

  // CONTROL: one transaction dropped from the enumeration.
  const dropped = clone(snap);
  const gone = dropped.transactions.splice(3, 1)[0];
  ck('the control perturbation changed the tree — one row removed',
     dropped.transactions.length === snap.transactions.length - 1);
  const rd = readingFromSnapshot(dropped, [[lo, hi]]).windows[0];
  bite(`control: dropping ${gone.txHash.slice(0, 10)}… from the enumeration leaves the `
       + `denominator ${rd.transactions} against the producer's tally `
       + `${dropped.counts.transactions}`,
       rd.transactions !== dropped.counts.transactions);

  // CONTROL: the denominator taken as the traced count — the failure the rule is named for.
  const published = clone(READING);
  for (const win of published.windows) win.transactions = win.traced;
  published.totals.transactions = published.totals.traced;
  bite('control: a reading whose `transactions` IS its `traced` count is refused by '
       + 'Y-WHOLE-WINDOWS', fires(published, 'Y-WHOLE-WINDOWS'));

  // the committed reading, unmodified: the green arm every control above is measured against
  const real = checkReading(READING, METHOD);
  ck(`the committed reading raises no finding — ${READING.windows.length} windows, `
     + `${READING.totals.transactions} transactions, ${READING.totals.traced} traced`,
     real.findings.length === 0);
  ck(`…and Y-EXPECTED-VARIABLE is reported NOT MEASURED for it rather than passed, because `
     + `this chain measured before the method was written down`,
     real.notMeasured.length === 1
     && real.notMeasured[0].includes('Y-EXPECTED-VARIABLE'));

  const short = clone(READING);
  short.windows[2].transactions -= 1;
  bite('control: one window\'s `transactions` short by one breaks the enumeration identity',
       fires(short, 'Y-WHOLE-WINDOWS'));
  const shortFib = clone(READING);
  shortFib.windows[0].firstInBlock -= 1;
  bite('control: a published denominator member that is not the derived population is '
       + 'refused by Y-DENOMINATORS-NAMED', fires(shortFib, 'Y-DENOMINATORS-NAMED'));
}

// ═══ §3 per-window figures cannot cancel into a passing total ═══════════════════════════
test('§3 two windows moving in opposite directions cannot cancel into a passing total');
{
  const columns = [...new Set([...METHOD.comparison.chainColumns,
                               ...METHOD.comparison.runColumns])];
  const summed = (doc, c) => doc.windows.reduce((s, w) => s + (w[c] ?? 0), 0);
  const mismatched = columns.filter((c) => (READING.totals[c] ?? 0) !== summed(READING, c));
  ck(`the totals are the sum of the per-window rows, column by column — ${columns.length} `
     + `column(s)${mismatched.length ? `, off: ${mismatched}` : ''}`,
     mismatched.length === 0);

  // THE CONTROL THE METHOD IS NAMED FOR: +3 in one window and -3 in another. Every total is
  // untouched, and only a per-window comparison can see it.
  const moved = clone(READING);
  moved.windows[0].traced += 3;
  moved.windows[0].refused -= 3;
  moved.windows[3].traced -= 3;
  moved.windows[3].refused += 3;
  ck('the control perturbation changed two windows and no total',
     moved.windows[0].traced === READING.windows[0].traced + 3
     && moved.windows[3].traced === READING.windows[3].traced - 3
     && columns.every((c) => summed(moved, c) === summed(READING, c)));

  const cmp = compareReadings(normaliseReading(READING), normaliseReading(moved),
                              PINNED, METHOD);
  const movedWindows = new Set(cmp.differences.map((d) => d.window.join('-')));
  bite(`control: the per-window comparison names exactly two windows — `
       + `[${[...movedWindows].join(', ')}]`, movedWindows.size === 2);
  bite('control: …and the verdict is not `reproduced`, though every total matched',
       cmp.verdict !== 'reproduced');
  bite('control: …and it is `not-reproduced` rather than environmental, because nothing '
       + 'names the transactions that moved', cmp.verdict === 'not-reproduced');

  // and the two shapes a totals-only reading can take
  const noRows = clone(READING);
  noRows.windows = [];
  bite('control: a reading with no per-window rows at all is refused — a total is the only '
       + 'thing it says', fires(noRows, 'Y-PER-WINDOW-PUBLISHED'));
  const totalMoved = clone(READING);
  totalMoved.totals.traced += 1;
  bite('control: a total that is not the sum of its column is refused',
       fires(totalMoved, 'Y-PER-WINDOW-PUBLISHED'));
}

// ═══ §4 both denominators, and the distinction measured rather than asserted ════════════
test('§4 both denominators are reported, and the distinction is measured');
{
  const dens = PINNED.denominators;
  ck(`this chain declares ${dens.length} denominators — two is the method's FLOOR and not `
     + `the count, because a chain with two distinct exclusions has three`, dens.length >= 2);
  const pct = dens.map((d) => READING.yield[d.yieldMember]);
  ck(`…and the published fractions are pairwise different — ${pct.join(' / ')} %`,
     new Set(pct).size === pct.length);

  // THE CORPUS SUPPLIES BOTH SIDES. `git ls-files` rather than a walk, for the reason
  // `refusal-selftest` gives: a walk also sees the snapshot a live follower writes on a
  // developer's machine. A git that cannot answer is a FAILURE, not an empty population.
  const ls = spawnSync('git', ['-C', ROOT, 'ls-files', '*snapshot.json'],
                       { encoding: 'utf8' });
  ck('the committed corpus can be enumerated, so the two sweeps below are not vacuous',
     ls.status === 0 && `${ls.stdout}`.trim().length > 0);
  const paths = `${ls.stdout}`.split('\n').map((s) => s.trim()).filter(Boolean).sort();

  const differ = [], equal = [], noTally = [], disagreed = [];
  let swept = 0;
  for (const p of paths) {
    const snap = readJson(p);
    const rows = snap.transactions ?? [];
    if (!rows.length) continue;
    swept++;
    const lo = Math.min(...rows.map((t) => t.blockNumber));
    const hi = Math.max(...rows.map((t) => t.blockNumber));
    const w = readingFromSnapshot(snap, [[lo, hi]]).windows[0];
    const d = denominatorsOf(w);
    (d.excluded > 0 ? differ : equal).push(`${p} (${d.all} vs ${d.observable})`);
    if (typeof snap.counts?.transactions !== 'number') noTally.push(p);
    else if (snap.counts.transactions !== w.transactions) {
      disagreed.push(`${p}: enumerated ${w.transactions} against a tally of `
        + `${snap.counts.transactions}`);
    }
  }
  ck(`the sweep read every committed tree with rows in it — ${swept} of ${paths.length}`,
     swept === paths.length && swept >= 8);
  ck(`every committed snapshot that declares a §5.2 tally agrees with the enumeration — `
     + `${swept - noTally.length} of ${swept}`
     + `${disagreed.length ? `; ${disagreed.join('; ')}` : ''}`, disagreed.length === 0);

  // BOTH SIDES FLOORED. A rule whose population can be empty passes for free, and this one
  // has two populations: without the floors, a corpus that lost every tree with a
  // chain-absent population would still report "the distinction is measured".
  ck(`trees where the two denominators DIFFER, because an exclusion population is `
     + `non-empty — ${differ.length}: ${differ.join('; ')}`, differ.length >= 3);
  ck(`trees where they are EQUAL, because there is no such population — ${equal.length}: `
     + `${equal.join('; ')}`, equal.length >= 2);
  ck(`…and exactly one committed snapshot declares no §5.2 tally at all, named rather than `
     + `skipped — ${noTally.join(', ') || '(none)'}`,
     noTally.length === 1 && noTally[0] === 'client/fixtures/noir-frames/snapshot.json');

  // the rows the chain never published an execution for are OUT of the untraced count and
  // IN the total, which is the two halves of Trace-Artifacts.md §6's `absent`
  const aztec = readJson('client/fixtures/chain/aztec/snapshot.json');
  const absent = aztec.transactions.filter((t) => t.outcome === 'private-only');
  const withReason = aztec.transactions.filter((t) => typeof t.refusalReason === 'string');
  ck(`the aztec capture has both kinds of untraced row — ${absent.length} the chain never `
     + `published and ${withReason.length} this pipeline declined`,
     absent.length > 0 && withReason.length > 0);
  ck('…a chain-absent row classifies as chainAbsent and never as untraced',
     absent.every((t) => populationOf(t.outcome) === 'chainAbsent'));
  ck('…and a declined row classifies as untraced, so it stays a failure to trace',
     withReason.every((t) => populationOf(t.outcome) === 'untraced'));

  // CONTROL: the check must be measuring the exclusion, not printing two numbers.
  const flat = clone(READING);
  flat.yield.tracedOverFirstInBlock = flat.yield.tracedOverAllTransactions;
  bite('control: a reading that declares a non-empty exclusion and publishes the SAME '
       + 'fraction over both denominators is refused — which is what a check that always '
       + 'printed two numbers would pass', fires(flat, 'Y-DENOMINATORS-NAMED'));
  const noYield = clone(READING);
  delete noYield.yield.tracedOverFirstInBlockWithPublicHalf;
  bite('control: a denominator with no published fraction is refused, so a quoted figure '
       + 'always has a stated denominator', fires(noYield, 'Y-DENOMINATORS-NAMED'));

  const asFailure = clone(METHOD);
  asFailure.pinned['aztec-testnet'] = clone(PINNED);
  asFailure.pinned['aztec-testnet'].exclusions.push(
    { id: 'refused', removes: 'refused', structural: true, why: 'x' });
  bite('control: an exclusion that removes a DECLINED column — a refusal carrying a '
       + 'reason — is refused by Y-ABSENT-IS-NOT-A-FAILURE',
       fires(READING, 'Y-ABSENT-IS-NOT-A-FAILURE', asFailure));
  const notStructural = clone(METHOD);
  notStructural.pinned['aztec-testnet'] = clone(PINNED);
  delete notStructural.pinned['aztec-testnet'].exclusions[1].structural;
  bite('control: an exclusion not declared structural is refused — an exclusion that is '
       + 'not a property of the chain is a choice about what to count',
       fires(READING, 'Y-ABSENT-IS-NOT-A-FAILURE', notStructural));
}

// ═══ §5 a re-run over the pinned windows, and the four verdicts ═════════════════════════
test('§5 a re-run over the pinned windows, and what a difference earns');
{
  const base = normaliseReading(READING);
  const re = normaliseReading(RERUN);
  const real = compareReadings(base, re, PINNED, METHOD);

  // THE MEASURED CASE. 208 of 343, not 211: three transactions that replayed in the reading
  // refused here, all three named, all three with a recorded observation beside them, and
  // every chain column identical.
  ck(`the committed re-run is \`differs-environmentally\` — ${real.differences.length} `
     + `difference(s), all in run columns`, real.verdict === 'differs-environmentally');
  ck(`…and that is NOT \`reproduced\`: ${re.totals.traced} of ${re.totals.transactions} `
     + `is not ${base.totals.traced} of ${base.totals.transactions}, and the method may `
     + `never say it is`, real.verdict !== 'reproduced');
  ck('…and NOT `not-reproduced`, because a difference outside the producer is not a '
     + 'producer defect', real.verdict !== 'not-reproduced');
  ck('…and every difference is in a run column, none in a chain column',
     real.differences.length > 0 && real.differences.every((d) => d.kind === 'run'));
  const names = RERUN.replay.hostFinding.transactions;
  const movedTraced = real.differences.filter((d) => d.column === 'traced')
    .reduce((s, d) => s + Math.abs(d.baseline - d.rerun), 0);
  ck(`…and the attribution reconciles arithmetically — ${names.length} transaction(s) `
     + `named against a movement of ${movedTraced}`, names.length === movedTraced);
  ck('…and every named transaction sits inside one of the pinned windows',
     names.every((t) => PINNED.windows.some(([f, to]) => t.blockNumber >= f
                                                      && t.blockNumber <= to)));

  // a re-run that really does reproduce
  const same = clone(RERUN);
  same.replay.windows = clone(READING.windows).map((w, i) => ({
    ...w, baseline: RERUN.replay.windows[i].baseline, delta: {} }));
  ck('a re-run whose every column is the reading\'s is `reproduced`',
     compareReadings(base, normaliseReading(same), PINNED, METHOD).verdict === 'reproduced');

  // CONTROL: a different window set is NON-COMPARABLE, not a failed repeat.
  const elsewhere = clone(RERUN);
  elsewhere.replay.windows[2].from = 50000;
  elsewhere.replay.windows[2].to = 50199;
  const nc = compareReadings(base, normaliseReading(elsewhere), PINNED, METHOD);
  bite('control: a run over a DIFFERENT set of windows is rejected as `non-comparable` '
       + 'rather than accepted as a repeat', nc.verdict === 'non-comparable');
  bite('control: …and nothing was compared, so no difference is reported as a regression',
       nc.differences.length === 0);
  const reordered = clone(RERUN);
  reordered.replay.windows.reverse();
  bite('control: the same five windows in a different ORDER are non-comparable too — a '
       + 'reader matches a row to a window by position',
       compareReadings(base, normaliseReading(reordered), PINNED, METHOD).verdict
       === 'non-comparable');

  // CONTROLS on the attribution, one clause at a time.
  const unnamed = clone(RERUN);
  unnamed.replay.hostFinding.transactions = [];
  bite('control: a run-column difference with NO transaction named is `not-reproduced`',
       compareReadings(base, normaliseReading(unnamed), PINNED, METHOD).verdict
       === 'not-reproduced');
  const unmeasured = clone(RERUN);
  delete unmeasured.replay.hostFinding.measurement;
  bite('control: an attribution with no recorded observation is `not-reproduced` — an '
       + 'inference about a difference is not a measurement of it',
       compareReadings(base, normaliseReading(unmeasured), PINNED, METHOD).verdict
       === 'not-reproduced');
  const partial = clone(RERUN);
  partial.replay.hostFinding.transactions.pop();
  bite('control: two transactions named against a movement of three is `not-reproduced` — '
       + 'a partial explanation presented as a complete one',
       compareReadings(base, normaliseReading(partial), PINNED, METHOD).verdict
       === 'not-reproduced');
  const offWindow = clone(RERUN);
  offWindow.replay.hostFinding.transactions[0].blockNumber = 30000;
  bite('control: a named transaction in a block outside every pinned window is '
       + '`not-reproduced`',
       compareReadings(base, normaliseReading(offWindow), PINNED, METHOD).verdict
       === 'not-reproduced');

  // THE RECONCILIATION IS PER WINDOW AND OVER EVERY RUN COLUMN, and this arm is why. Five
  // rows moving from `replayed` to `divergent` leave that window's `traced` untouched, so
  // the total movement in `traced` is unchanged and the attribution still reconciles against
  // it — while five real executions that DISAGREED with the block arrive named by nothing.
  const betweenTraced = clone(RERUN);
  betweenTraced.replay.windows[1].replayed -= 5;
  betweenTraced.replay.windows[1].divergent += 5;
  ck('the control perturbation left the window\'s `traced` and every total over it alone',
     betweenTraced.replay.windows[1].replayed + betweenTraced.replay.windows[1].divergent
     === RERUN.replay.windows[1].replayed + RERUN.replay.windows[1].divergent);
  bite('control: five rows moving BETWEEN two traced columns, with the attribution left '
       + 'fully intact, is `not-reproduced` — a total taken over `traced` alone cannot see '
       + 'them, and the per-window reconciliation over every run column can',
       compareReadings(base, normaliseReading(betweenTraced), PINNED, METHOD).verdict
       === 'not-reproduced');
  const declinedMoved = clone(RERUN);
  declinedMoved.replay.windows[4].bodyUnavailable = 40;
  bite('control: a DECLINED column — 40 rows the body store did not serve — is '
       + '`not-reproduced` rather than invisible, which is what it was while '
       + '`bodyUnavailable` was in neither column list',
       compareReadings(base, normaliseReading(declinedMoved), PINNED, METHOD).verdict
       === 'not-reproduced');

  // THE ONE THAT SEPARATES A HOST FROM A CHAIN. A chain column cannot move between two runs
  // over the same absolute range, so a moved one is `not-reproduced` however well attributed.
  const chainMoved = clone(RERUN);
  chainMoved.replay.windows[1].privateOnly += 1;
  const cm = compareReadings(base, normaliseReading(chainMoved), PINNED, METHOD);
  bite('control: a CHAIN column moved, with the attribution left fully intact, is '
       + '`not-reproduced` — this is the case that must not be laundered as environmental',
       cm.verdict === 'not-reproduced');
  bite('control: …and the verdict says which column and why',
       cm.notes.some((n) => n.includes('privateOnly') && n.includes('CHAIN')));
}

// ═══ §6 pinned by absolute range, provenance declared, range bounded ═══════════════════
test('§6 the windows are pinned by absolute range, and the range is bounded');
{
  ck(`the reading's windows are this chain's pinned set — `
     + `${PINNED.windows.map(([f, t]) => `${f}-${t}`).join(', ')}`,
     sameWindows(READING.windows.map((w) => [w.from, w.to]), PINNED.windows));
  ck(`…and it is ${METHOD.reading.windowsRequired} whole windows of `
     + `${PINNED.blocksPerWindow} blocks, nothing sampled within one`,
     READING.windows.length === METHOD.reading.windowsRequired
     && READING.windows.every((w) => w.blocks === PINNED.blocksPerWindow
                                  && w.to - w.from + 1 === PINNED.blocksPerWindow));

  const substituted = clone(READING);
  substituted.windows[4].from = 60000;
  substituted.windows[4].to = 60199;
  bite('control: one window substituted for another is refused by Y-WINDOWS-PINNED',
       fires(substituted, 'Y-WINDOWS-PINNED'));

  // THE PROVENANCE CLAUSE. Four of five windows carry a runtime commit; the fifth carries
  // only a fetch ledger and contributes the largest share of the total.
  const withLedger = READING.windows.filter((w) => w.ledger?.replay?.runtimeCommit);
  const without = READING.windows.filter((w) => !w.ledger?.replay?.runtimeCommit);
  ck(`${withLedger.length} of ${READING.windows.length} windows carry a recorded replay `
     + `commit, and the chain declares ${PINNED.provenanceCoverage.windowsWithRecordedReplayLedger}`,
     withLedger.length === PINNED.provenanceCoverage.windowsWithRecordedReplayLedger);
  ck(`…and the one without is ${without.map((w) => `${w.from}-${w.to}`).join(', ')}, which `
     + `contributes ${without.reduce((s, w) => s + w.traced, 0)} of the `
     + `${READING.totals.traced} traced — the largest share of any window`,
     without.length === 1
     && without[0].traced === Math.max(...READING.windows.map((w) => w.traced)));
  ck('…and the four that do all name one runtime build, so "the same windows reproduce" '
     + 'has one provenance to be asserted against rather than four',
     new Set(withLedger.map((w) => w.ledger.replay.runtimeCommit)).size === 1);

  const overclaimed = clone(METHOD);
  overclaimed.pinned['aztec-testnet'] = clone(PINNED);
  overclaimed.pinned['aztec-testnet'].provenanceCoverage = {
    windowsWithRecordedReplayLedger: 5, windowsWithout: [] };
  bite('control: declaring provenance for all five windows is refused, so the coverage '
       + 'cannot be quoted as though the fifth had one',
       fires(READING, 'Y-WINDOWS-PINNED', overclaimed));
  // AND THE COUNT CLAUSE IS ISOLATED FROM THE LIST CLAUSE, because the two arms around it
  // are both satisfied by the list alone. Measured: replacing
  // `cov.windowsWithRecordedReplayLedger` with the literal `4` in the module left this whole
  // suite GREEN — the `overclaimed` arm above still fired, but off the `windowsWithout`
  // comparison rather than off the number. A declaration of THREE with the list left right
  // is the arm only the number can refuse.
  const understated = clone(METHOD);
  understated.pinned['aztec-testnet'] = clone(PINNED);
  understated.pinned['aztec-testnet'].provenanceCoverage = {
    windowsWithRecordedReplayLedger: 3, windowsWithout: [[75700, 75899]] };
  bite('control: a declared coverage of three with the window list left correct is refused, '
       + 'so `windowsWithRecordedReplayLedger` is READ and is not the constant 4',
       fires(READING, 'Y-WINDOWS-PINNED', understated));

  // and the rule tracks the RECORD rather than the constant 4: give the fifth window a
  // ledger and the unchanged declaration must now be the thing that is wrong.
  const repaired = clone(READING);
  repaired.windows[4].ledger.replay = { runtimeCommit: 'dfb9ebe23246759f87a4503f35da51dfb2485050' };
  bite('control: a fifth replay ledger arriving makes the declared coverage of four fail — '
       + 'so the rule reads the record and is not the number 4',
       fires(repaired, 'Y-WINDOWS-PINNED'));

  // THE BOUNDED RANGE.
  ck(`every window lies inside the declared historic range `
     + `${PINNED.historicRange.from}-${PINNED.historicRange.to}`,
     READING.windows.every((w) => w.from >= PINNED.historicRange.from
                               && w.to <= PINNED.historicRange.to));
  ck(`…and every window's last block is below the finalized head recorded with the `
     + `reading (${READING.finalizedAtRun}), so none of them is measuring production `
     + `traffic`, READING.windows.every((w) => w.to < READING.finalizedAtRun));

  const beyond = clone(READING);
  beyond.windows[4].from = 90000;
  beyond.windows[4].to = 90199;
  bite('control: a window outside the declared historic range is refused',
       fires(beyond, 'Y-BOUNDED-RANGE'));
  const atTip = clone(READING);
  atTip.windows[4].to = READING.finalizedAtRun + 5;
  bite('control: a window reaching the finalized head is refused — above it the chain can '
       + 'still reorganise, so a re-run is a different set of transactions in the same '
       + 'block numbers', fires(atTip, 'Y-BOUNDED-RANGE'));
  const unbounded = clone(READING);
  delete unbounded.finalizedAtRun;
  delete unbounded.chainTipAtRun;
  bite('control: a reading that records no boundary at all FAILS rather than passing the '
       + 'rule it cannot be checked against', fires(unbounded, 'Y-BOUNDED-RANGE'));
}

// ═══ §7 `attempted` is per-pass, and the corpus holds both passes ══════════════════════
test('§7 `ledger.replay.attempted` is per-pass, and both passes over one window are here');
{
  const ledgered = READING.windows.filter((w) => w.ledger?.replay);
  ck(`in every window with a replay ledger, attempted EQUALS refused — `
     + `${ledgered.map((w) => `${w.ledger.replay.attempted}/${w.ledger.replay.refused}`).join(' ')}`
     + ` — which is the signature of a resumed pass`,
     ledgered.length === 4
     && ledgered.every((w) => w.ledger.replay.attempted === w.ledger.replay.refused));
  const w45 = READING.windows.find((w) => w.from === 45000);
  ck(`…and the 45000-45199 window reads attempted ${w45.ledger.replay.attempted} beside `
     + `replayed ${w45.replayed}, which reads as a contradiction and is not one: the loop `
     + `skips rows already decided, so a range with nothing left to attempt attempts nothing`,
     w45.ledger.replay.attempted === 0 && w45.replayed === 21);

  // THE FIRST PASS OVER THE SAME WINDOW IS ALSO COMMITTED, which is what makes this a
  // measurement rather than a caution.
  const first = RERUN.replay.windows.find((w) => w.from === 1);
  const resumed = READING.windows.find((w) => w.from === 1);
  ck(`a FIRST pass over 1-200 reports attempted ${first.attempted} = `
     + `${first.replayed} replayed + ${first.divergent} divergent + ${first.refused} refused`,
     first.attempted === first.replayed + first.divergent + first.refused);
  ck(`…while the resumed pass over the SAME window reports `
     + `${resumed.ledger.replay.attempted}, so the field is right about the pass that wrote `
     + `it and wrong as a total`,
     first.attempted !== resumed.ledger.replay.attempted);

  // and no figure this method checks comes from it
  const src = readFileSync(join(HERE, 'lib', 'yield.mjs'), 'utf8');
  ck('and `lib/yield.mjs` never reads `attempted`, so no published figure can come from it',
     !/\battempted\b/.test(src));
}

// ═══ §8 the classification is imported, not restated ═══════════════════════════════════
test('§8 the outcome partition is imported, so there is one of it');
{
  const src = readFileSync(join(HERE, 'lib', 'yield.mjs'), 'utf8');
  ck('`lib/yield.mjs` imports the outcome partition from the file both languages read',
     /import\s*\{[^}]*SNAPSHOT_OUTCOMES[^}]*\}\s*from\s*'\.\/snapshot-format\.mjs'/.test(src));
  const all = [...SNAPSHOT_OUTCOMES.traced, ...SNAPSHOT_OUTCOMES.untraced,
               ...SNAPSHOT_OUTCOMES.chainAbsent];
  const literal = all.filter((o) => src.includes(`'${o}'`) || src.includes(`"${o}"`));
  ck(`…and restates none of the ${all.length} outcome tokens as a literal of its own`
     + `${literal.length ? `, found: ${literal}` : ''}`, literal.length === 0);
  const misclassified = all.filter((o) => populationOf(o) === 'unclassified');
  ck(`every declared outcome classifies into one of the three populations — ${all.length} `
     + `token(s)${misclassified.length ? `, unclassified: ${misclassified}` : ''}`,
     all.length >= 7 && misclassified.length === 0);
  ck('…and a token in none of the three is `unclassified` rather than silently traced, so '
     + 'a row cannot go missing from the denominator',
     populationOf('no-public-execution') === 'unclassified'
     && populationOf(undefined) === 'unclassified');
}

console.error('');
if (asserted !== 83) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 83 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('PASS — the yield method is applied, and every rule has been watched refusing');
