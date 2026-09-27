// yield.mjs — HOW A CHAIN'S TRACE YIELD IS COUNTED, as code, from the method as data.
//
// `tools/chain/yield-method.json` is the method; this module applies it. The split is the
// one `snapshot-format.json` / `lib/snapshot-format.mjs` already uses, and for the same
// reason: a rule spelled in the tool that reads it is a rule the tool can quietly change.
//
// ── WHAT THIS DOES NOT CLASSIFY ────────────────────────────────────────────────────────
//
// It does not decide which outcomes are traced, which are declined, and which mean the
// chain published no execution at all. That partition is `snapshot-format.json`'s
// `outcomes`, imported here as `SNAPSHOT_OUTCOMES`. A yield module with its own copy would
// be a second answer to the question whose answer IS the denominator, and this repository
// has spent enough of its history deleting duplicated rules to know how that ends —
// `chain-health.mjs` reads the same partition for its own census, and the two agree because
// there is one of it.
//
// ── THE TWO THINGS IT COMPUTES, AND WHY THEY ARE SEPARATE FUNCTIONS ────────────────────
//
//   `readingFromSnapshot`  builds a reading by ENUMERATING a snapshot's rows over absolute
//                          block ranges. This is where "the denominator is every
//                          transaction in the window" becomes an operation rather than an
//                          intention: the count comes off the rows, classified but never
//                          filtered, so nothing a run did can move it.
//   `checkReading`         applies the method's rules to a reading somebody else published,
//                          in the `blocktracer/historic-replay-yield@1` shape. Its
//                          denominators are checked against the exclusion populations and
//                          its percentages against the denominators, so no figure in it is
//                          taken on trust.
//
// And `compareReadings` is the third thing, which is neither: it decides whether two
// readings are comparable at all, and if they are, which of four verdicts a difference
// between them earns. Read the `comparison` block of the method file before changing it —
// the reason there are four verdicts and not two is measured, and two of them would force
// the method to lie in one direction or the other.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { SNAPSHOT_OUTCOMES } from './snapshot-format.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

export const YIELD_METHOD_PATH = join(HERE, '..', 'yield-method.json');
export const YIELD_METHOD_FORMAT = 'blocktracer/yield-method@1';
export const READING_FORMAT = 'blocktracer/historic-replay-yield@1';
export const COMPARISON_FORMAT = 'blocktracer/baseline-rerun@1';

/** The method, read from the one file that states it. Format-gated for the reason
 *  `lib/snapshot-format.mjs` gives: a half-read policy is no policy. */
export function yieldMethod(path = YIELD_METHOD_PATH) {
  const d = JSON.parse(readFileSync(path, 'utf8'));
  if (d.format !== YIELD_METHOD_FORMAT) {
    throw new Error(`${path}: format is ${JSON.stringify(d.format)}, and this module only `
      + `knows ${YIELD_METHOD_FORMAT}. Refusing to apply a method it may not understand.`);
  }
  return d;
}

/** The rule ids. Asserted disjoint from the contract's and the health sweep's. */
export const yieldRuleIds = (method) => Object.keys(method.rules);

/** The pinned entry for one chain, or null. A chain with no entry has not pinned its
 *  windows, which is a finding rather than a default. */
export function pinnedFor(chain, method) {
  return Object.prototype.hasOwnProperty.call(method.pinned, chain)
    ? method.pinned[chain] : null;
}

const asRanges = (ws) => ws.map(([f, t]) => `${f}-${t}`).join(',');

/** Are two window sets the same set of absolute ranges, in the same order?
 *
 *  ORDER IS PART OF IT, because a reader matches a per-window row to a window by position
 *  in every table this produces, and a reordered set names the wrong window in every diff.
 *  A reordering is still reported as non-comparable rather than as a difference, which is
 *  the honest answer: nothing about the counts has been compared yet. */
export const sameWindows = (a, b) => asRanges(a) === asRanges(b);

const round1 = (x) => Math.round(x * 1000) / 10;

// ── enumerating a snapshot over absolute ranges ────────────────────────────────────────

/**
 * Classify one row into the format's three populations. No fourth bucket: a token in none
 * of the three is `unclassified`, and an unclassified row is reported rather than dropped —
 * a row silently in no population is a row missing from the denominator.
 */
export function populationOf(outcome) {
  if (SNAPSHOT_OUTCOMES.traced.includes(outcome)) return 'traced';
  if (SNAPSHOT_OUTCOMES.untraced.includes(outcome)) return 'untraced';
  if (SNAPSHOT_OUTCOMES.chainAbsent.includes(outcome)) return 'chainAbsent';
  return 'unclassified';
}

/**
 * Build a reading by enumerating a snapshot's rows over absolute block ranges.
 *
 * THE DENOMINATOR IS THE ENUMERATION AND NOTHING ELSE. Every row whose block falls in the
 * range is counted, whatever its outcome, before anything is subtracted — and the
 * subtractions are reported beside it rather than folded into it, so the two denominators
 * the method requires are both present and both derived.
 *
 * @param {object} snap      a `blocktracer/chain-snapshot@…` document
 * @param {Array<[number,number]>} windows  absolute ranges, inclusive
 */
export function readingFromSnapshot(snap, windows) {
  const rows = Array.isArray(snap?.transactions) ? snap.transactions : [];
  const out = { windows: [], totals: null, rowsRead: rows.length };
  const zero = () => ({
    transactions: 0, traced: 0, untraced: 0, chainAbsent: 0, unclassified: 0,
    notFirstInBlock: 0,
  });
  const totals = zero();
  for (const [from, to] of windows) {
    const w = { from, to, ...zero() };
    for (const t of rows) {
      const b = t?.blockNumber;
      if (typeof b !== 'number' || b < from || b > to) continue;
      w.transactions++;
      w[populationOf(t?.outcome)]++;
      if (t?.firstInBlock === false) w.notFirstInBlock++;
    }
    for (const k of Object.keys(totals)) totals[k] += w[k];
    out.windows.push(w);
  }
  out.totals = totals;
  return out;
}

/**
 * The two denominators, derived from an enumeration rather than declared.
 *
 * `all` is every transaction. `observable` removes the rows the chain never published an
 * execution for — Trace-Artifacts.md §6's `absent`, which is the chain's limit and not a
 * failure to trace — and the rows no node method can serve intermediate state for. A row
 * this pipeline DECLINED stays in both, which is the whole point: a refusal with a reason
 * is ours, and dropping it is the chosen denominator the method exists to forbid.
 */
export const denominatorsOf = (w) => ({
  all: w.transactions,
  observable: w.transactions - w.chainAbsent - w.notFirstInBlock,
  excluded: w.chainAbsent + w.notFirstInBlock,
});

// ── checking a published reading ────────────────────────────────────────────────────────

const fin = (findings, rule, detail) => findings.push({ rule, detail });

/**
 * Apply the method to a published reading.
 *
 * @param {object} doc     a `blocktracer/historic-replay-yield@1` document
 * @param {object} method  `yield-method.json`, already read
 * @returns {{findings: Array, notMeasured: Array, windows: Array, chain: string}}
 */
export function checkReading(doc, method) {
  const findings = [];
  const notMeasured = [];
  const chain = doc?.chain ?? null;

  if (doc?.format !== READING_FORMAT) {
    fin(findings, 'Y-WINDOWS-PINNED', `the reading declares format `
      + `${JSON.stringify(doc?.format ?? null)}, not ${READING_FORMAT}, so no rule below `
      + `can be applied to it by name`);
    return { findings, notMeasured, windows: [], chain };
  }

  const pinned = chain === null ? null : pinnedFor(chain, method);
  if (!pinned) {
    fin(findings, 'Y-WINDOWS-PINNED', `chain ${JSON.stringify(chain)} has no pinned entry `
      + `in the method, so its windows were not pinned before it measured and a re-run has `
      + `nothing to be compared against`);
    return { findings, notMeasured, windows: [], chain };
  }

  const ws = Array.isArray(doc.windows) ? doc.windows : [];

  // ── Y-WINDOWS-PINNED ────────────────────────────────────────────────────────────────
  const declared = ws.map((w) => [w.from, w.to]);
  if (!sameWindows(declared, pinned.windows)) {
    fin(findings, 'Y-WINDOWS-PINNED', `the reading's windows are [${asRanges(declared)}] `
      + `and this chain pinned [${asRanges(pinned.windows)}]. A window substituted for `
      + `another measures a different thing`);
  }
  if (ws.length < method.reading.windowsRequired) {
    fin(findings, 'Y-WINDOWS-PINNED', `the reading publishes ${ws.length} window(s) and `
      + `the method's floor is ${method.reading.windowsRequired}`);
  }

  // the provenance clause: a window with no replay ledger carries no runtime commit
  const withLedger = ws.filter((w) => w?.ledger?.replay
                                   && typeof w.ledger.replay.runtimeCommit === 'string'
                                   && w.ledger.replay.runtimeCommit.length > 0);
  const without = ws.filter((w) => !withLedger.includes(w)).map((w) => [w.from, w.to]);
  const cov = pinned.provenanceCoverage ?? {};
  if (withLedger.length !== cov.windowsWithRecordedReplayLedger) {
    fin(findings, 'Y-WINDOWS-PINNED', `${withLedger.length} window(s) carry a recorded `
      + `replay ledger and the chain declares ${cov.windowsWithRecordedReplayLedger}. `
      + `A claim that "the same windows reproduce" is assertable against recorded `
      + `provenance only for the windows that have one, so the coverage is declared and `
      + `checked rather than implied`);
  }
  if (asRanges(without) !== asRanges(cov.windowsWithout ?? [])) {
    fin(findings, 'Y-WINDOWS-PINNED', `the windows with NO recorded replay provenance are `
      + `[${asRanges(without)}] and the chain declares [${asRanges(cov.windowsWithout ?? [])}]`);
  }

  // ── Y-BOUNDED-RANGE ─────────────────────────────────────────────────────────────────
  const hr = pinned.historicRange ?? {};
  const bound = typeof doc.finalizedAtRun === 'number' ? doc.finalizedAtRun
              : (typeof doc.chainTipAtRun === 'number' ? doc.chainTipAtRun : null);
  if (bound === null) {
    fin(findings, 'Y-BOUNDED-RANGE', `the reading records neither a finalized head nor a `
      + `chain tip, so there is no recorded boundary between historic data and production `
      + `traffic and the rule cannot be applied — which is a failure, not a pass`);
  }
  for (const w of ws) {
    if (typeof hr.from !== 'number' || typeof hr.to !== 'number') {
      fin(findings, 'Y-BOUNDED-RANGE', `this chain declares no bounded historic range`);
      break;
    }
    if (w.from < hr.from || w.to > hr.to) {
      fin(findings, 'Y-BOUNDED-RANGE', `window ${w.from}-${w.to} falls outside the `
        + `declared historic range ${hr.from}-${hr.to}`);
    }
    if (bound !== null && w.to >= bound) {
      fin(findings, 'Y-BOUNDED-RANGE', `window ${w.from}-${w.to} reaches the finalized `
        + `head recorded with the reading (${bound}), so it is measuring traffic the chain `
        + `can still reorganise rather than a bounded historic range`);
    }
  }

  // ── Y-WHOLE-WINDOWS, Y-ABSENT-IS-NOT-A-FAILURE, Y-DENOMINATORS-NAMED ────────────────
  const excl = pinned.exclusions ?? [];
  const declinedCols = pinned.declinedColumns ?? [];
  const tracedCols = pinned.tracedColumns ?? [];
  const n = (w, k) => (typeof w?.[k] === 'number' ? w[k] : 0);

  const rowsAndTotals = [...ws.map((w) => ({ label: `window ${w.from}-${w.to}`, w })),
                         { label: 'the totals', w: doc.totals ?? {} }];
  for (const { label, w } of rowsAndTotals) {
    const excluded = excl.reduce((s, e) => s + n(w, e.removes), 0);
    const observable = n(w, 'transactions') - excluded;
    const declined = declinedCols.reduce((s, c) => s + n(w, c), 0);

    // the traced column is the sum of the columns the chain declares traced
    const tracedSum = tracedCols.reduce((s, c) => s + n(w, c), 0);
    if (n(w, 'traced') !== tracedSum) {
      fin(findings, 'Y-WHOLE-WINDOWS', `${label}: traced is ${n(w, 'traced')} and `
        + `[${tracedCols.join(' + ')}] is ${tracedSum}`);
    }
    // the denominator identity: every row is in exactly one place
    if (observable !== n(w, 'traced') + declined) {
      fin(findings, 'Y-WHOLE-WINDOWS', `${label}: ${n(w, 'transactions')} transactions `
        + `minus ${excluded} excluded is ${observable}, and traced ${n(w, 'traced')} plus `
        + `declined ${declined} is ${n(w, 'traced') + declined}. A row is in two places or `
        + `in none, so the denominator is not the enumeration`);
    }
    // each declared denominator's member must BE the derived population, not a transcription
    for (const d of pinned.denominators ?? []) {
      const removed = d.excludes.reduce((s, id) => {
        const e = excl.find((x) => x.id === id);
        return s + (e ? n(w, e.removes) : 0);
      }, 0);
      const derived = n(w, 'transactions') - removed;
      if (n(w, d.member) !== derived) {
        fin(findings, 'Y-DENOMINATORS-NAMED', `${label}: the reading publishes `
          + `\`${d.member}\` as ${n(w, d.member)} and removing [${d.excludes.join(', ')}] `
          + `from ${n(w, 'transactions')} transactions gives ${derived}`);
      }
    }
  }

  // ── Y-PER-WINDOW-PUBLISHED: the totals are the sum of the rows, column by column ─────
  const columns = [...new Set([
    ...(method.comparison.chainColumns ?? []), ...(method.comparison.runColumns ?? []),
    ...declinedCols, ...tracedCols,
  ])];
  if (ws.length === 0) {
    fin(findings, 'Y-PER-WINDOW-PUBLISHED', `the reading publishes no per-window rows at `
      + `all, so a total is the only thing it says and two windows moving in opposite `
      + `directions would be invisible`);
  }
  for (const c of columns) {
    const summed = ws.reduce((s, w) => s + n(w, c), 0);
    if (n(doc.totals ?? {}, c) !== summed) {
      fin(findings, 'Y-PER-WINDOW-PUBLISHED', `totals.${c} is `
        + `${n(doc.totals ?? {}, c)} and the ${ws.length} per-window rows sum to ${summed}`);
    }
  }

  // ── Y-DENOMINATORS-NAMED: every published percentage is the derived one ──────────────
  const dens = pinned.denominators ?? [];
  if (dens.length < 2) {
    fin(findings, 'Y-DENOMINATORS-NAMED', `this chain declares ${dens.length} `
      + `denominator(s); the method's floor is two — every transaction, and every `
      + `transaction that was structurally observable at all`);
  }
  for (const d of dens) {
    const den = n(doc.totals ?? {}, d.member);
    const got = doc.yield?.[d.yieldMember];
    if (typeof got !== 'number') {
      fin(findings, 'Y-DENOMINATORS-NAMED', `the reading publishes no `
        + `\`yield.${d.yieldMember}\`, so the fraction over \`${d.member}\` is not stated `
        + `and a reader has no way to know which denominator a quoted figure is over`);
      continue;
    }
    const want = den === 0 ? 0 : round1(n(doc.totals ?? {}, 'traced') / den);
    if (got !== want) {
      fin(findings, 'Y-DENOMINATORS-NAMED', `yield.${d.yieldMember} is ${got}% and `
        + `${n(doc.totals ?? {}, 'traced')} / ${den} is ${want}%`);
    }
  }

  // ── Y-ABSENT-IS-NOT-A-FAILURE: the exclusions must be the chain-absent population and
  // the structural one, and the DECLINED columns must not be among them ────────────────
  for (const e of excl) {
    if (declinedCols.includes(e.removes)) {
      fin(findings, 'Y-ABSENT-IS-NOT-A-FAILURE', `exclusion \`${e.id}\` removes `
        + `\`${e.removes}\`, which this chain also declares a DECLINED column. A refusal `
        + `carrying a reason is ours and must stay in the denominator; only a population `
        + `the chain never published an execution for may leave it`);
    }
    if (e.structural !== true) {
      fin(findings, 'Y-ABSENT-IS-NOT-A-FAILURE', `exclusion \`${e.id}\` is not declared `
        + `structural. An exclusion that is not a property of the chain is a choice about `
        + `what to count, which is the chosen denominator this method forbids`);
    }
  }

  // ── Y-EXPECTED-VARIABLE: NOT MEASURED is not a pass ─────────────────────────────────
  const vocab = method.expectedVariableVocabulary ?? [];
  if (pinned.expectationDeclaredInAdvance === false) {
    notMeasured.push(`Y-EXPECTED-VARIABLE over ${chain}: no expectation was declared `
      + `before this chain measured, and the chain's entry says so. It is reported NOT `
      + `MEASURED rather than passed — an expectation entered after the reading is the `
      + `story-written-afterwards the rule exists to forbid`);
  } else if (!vocab.includes(pinned.expectedDominantVariable)) {
    fin(findings, 'Y-EXPECTED-VARIABLE', `${chain} declares expected dominant variable `
      + `${JSON.stringify(pinned.expectedDominantVariable ?? null)}, which is not in the `
      + `vocabulary [${vocab.join(', ')}]`);
  } else if (typeof pinned.expectedOn !== 'string') {
    fin(findings, 'Y-EXPECTED-VARIABLE', `${chain} declares an expected dominant variable `
      + `and no date it was declared on, so "before measuring" is not checkable`);
  }

  return { findings, notMeasured, windows: declared, chain };
}

// ── comparing two readings ─────────────────────────────────────────────────────────────

/** Normalise either artifact shape to `{chain, windows:[…]}`. The re-run artifact nests its
 *  windows under `replay`; the reading carries them at the top. One shape from here on, so
 *  no rule below has to know which document it came from. */
export function normaliseReading(doc) {
  if (doc?.format === COMPARISON_FORMAT) {
    return { chain: doc.chain ?? null, windows: doc.replay?.windows ?? [],
             totals: doc.replay?.totals ?? {}, hostFinding: doc.replay?.hostFinding ?? null,
             from: COMPARISON_FORMAT };
  }
  return { chain: doc?.chain ?? null, windows: doc?.windows ?? [], totals: doc?.totals ?? {},
           hostFinding: doc?.hostFinding ?? null, from: doc?.format ?? null };
}

/**
 * Decide whether a re-run reproduces a reading, and if not, which of four things happened.
 *
 * @param {object} baseline  normalised reading
 * @param {object} rerun     normalised reading
 * @param {object} pinned    the chain's pinned entry
 * @param {object} method    `yield-method.json`
 */
export function compareReadings(baseline, rerun, pinned, method) {
  const chainCols = method.comparison.chainColumns;
  const runCols = method.comparison.runColumns;
  const notes = [];

  const bw = baseline.windows.map((w) => [w.from, w.to]);
  const rw = rerun.windows.map((w) => [w.from, w.to]);

  // ── comparability comes FIRST, and it is not a count comparison ──────────────────────
  // A run over a different set of windows has measured a different thing. Reporting that
  // as a regression would hand a methodological error the shape of a producer defect, so
  // it is refused before any column is looked at.
  if (!sameWindows(bw, rw)) {
    return { verdict: 'non-comparable', differences: [],
             notes: [`the baseline is over [${asRanges(bw)}] and the re-run over `
                     + `[${asRanges(rw)}]; nothing has been compared`] };
  }
  if (!sameWindows(rw, pinned.windows)) {
    return { verdict: 'non-comparable', differences: [],
             notes: [`both readings are over [${asRanges(rw)}] and this chain pinned `
                     + `[${asRanges(pinned.windows)}]`] };
  }

  const differences = [];
  for (let i = 0; i < bw.length; i++) {
    const b = baseline.windows[i], r = rerun.windows[i];
    for (const c of [...chainCols, ...runCols]) {
      const bv = typeof b[c] === 'number' ? b[c] : 0;
      const rv = typeof r[c] === 'number' ? r[c] : 0;
      if (bv !== rv) {
        differences.push({ window: [b.from, b.to], column: c, baseline: bv, rerun: rv,
                           kind: chainCols.includes(c) ? 'chain' : 'run' });
      }
    }
  }

  if (differences.length === 0) return { verdict: 'reproduced', differences, notes };

  const chainMoved = differences.filter((d) => d.kind === 'chain');
  if (chainMoved.length) {
    return { verdict: 'not-reproduced', differences,
             notes: [`${chainMoved.length} difference(s) are in a CHAIN column `
               + `(${[...new Set(chainMoved.map((d) => d.column))].join(', ')}). Two runs `
               + `over the same absolute range cannot disagree about what the chain `
               + `published, so this is not an environmental difference however well the `
               + `rest is attributed`] };
  }

  // ── only run columns moved: the difference is admissible only if it is ATTRIBUTED ────
  const hf = rerun.hostFinding;
  const named = Array.isArray(hf?.transactions) ? hf.transactions : [];
  const moved = differences.filter((d) => d.column === 'traced')
                           .reduce((s, d) => s + Math.abs(d.baseline - d.rerun), 0);
  const problems = [];
  if (named.length === 0) {
    problems.push('no transaction is named');
  }
  if (typeof hf?.measurement !== 'string' || hf.measurement.length === 0) {
    problems.push('no recorded observation accompanies the attribution, so it is an '
                  + 'inference about a difference rather than a measurement of it');
  }
  if (named.length !== moved) {
    problems.push(`${named.length} transaction(s) named against a movement of ${moved} in `
      + `the traced column. A partial explanation presented as a complete one is what this `
      + `clause is for`);
  }
  for (const t of named) {
    if (typeof t?.txHash !== 'string' || t.txHash.length === 0) {
      problems.push('a named transaction has no hash'); continue;
    }
    const b = t?.blockNumber;
    if (typeof b !== 'number') { problems.push(`${t.txHash} names no block`); continue; }
    if (!pinned.windows.some(([f, to]) => b >= f && b <= to)) {
      problems.push(`${t.txHash} is in block ${b}, which is in none of the pinned windows`);
    }
  }

  // ── AND IT IS RECONCILED PER WINDOW, OVER EVERY RUN COLUMN ───────────────────────────
  //
  // MEASURED as a hole in the first version of this rule rather than anticipated. The
  // clause above reconciles the named count against the movement in `traced` ALONE, and
  // `traced` is a SUM of the columns the chain declares traced. So a re-run in which rows
  // moved BETWEEN two of them — five `replayed` becoming five `divergent` — leaves `traced`
  // untouched in that window, leaves the total movement at whatever the other windows
  // contributed, and was accepted as `differs-environmentally` with nothing naming the
  // five. That is the §3 cancellation defect one level up: the rule already refuses two
  // WINDOWS cancelling and had nothing to say about two COLUMNS cancelling inside one. And
  // it lands on the worst possible column, because `divergent` is a real execution that
  // disagreed with the block — the strongest signal this pipeline emits. It may not arrive
  // unattributed inside a verdict whose whole content is that everything is attributed.
  //
  // THE MAX RATHER THAN THE SUM, because one transaction leaving `replayed` for `refused`
  // moves three columns by one and is one transaction. AN EQUALITY rather than a ceiling,
  // because a transaction named in a window where nothing moved is an attribution to a
  // window that had none — the same reason the total clause is an equality.
  for (let i = 0; i < bw.length; i++) {
    const b = baseline.windows[i], r = rerun.windows[i];
    const [f, to] = bw[i];
    const here = named.filter((t) => typeof t?.blockNumber === 'number'
                                  && t.blockNumber >= f && t.blockNumber <= to).length;
    let biggest = 0, worst = null;
    for (const c of runCols) {
      const d = Math.abs((typeof b[c] === 'number' ? b[c] : 0)
                       - (typeof r[c] === 'number' ? r[c] : 0));
      if (d > biggest) { biggest = d; worst = c; }
    }
    if (biggest !== here) {
      problems.push(`window ${f}-${to} moved by ${biggest} in \`${worst ?? '(nothing)'}\` `
        + `and ${here} transaction(s) are named inside it. The reconciliation is per window `
        + `and over every run column, because a row moving between two TRACED columns `
        + `leaves \`traced\` — and any total taken over it — untouched`);
    }
  }

  if (problems.length) {
    return { verdict: 'not-reproduced', differences,
             notes: problems.map((p) => `attribution incomplete: ${p}`) };
  }
  return {
    verdict: 'differs-environmentally', differences,
    notes: [`${differences.length} difference(s), all in run columns, all attributed: `
      + `${named.length} transaction(s) named with a recorded observation; the named count `
      + `equals the ${moved} the traced column moved, and in every window the largest `
      + `movement in any run column equals the number of transactions named inside it. `
      + `THIS IS NOT \`reproduced\` — the re-run's figure is its own and may not be quoted `
      + `as the baseline's`],
  };
}
