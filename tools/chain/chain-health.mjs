#!/usr/bin/env node
// chain-health.mjs — IS THE RECORDING LAYER HEALTHY? A sweep over prepared snapshot trees
// that reports what the conformance gates structurally cannot see.
//
//   node tools/chain/chain-health.mjs <snapshot-dir> [<snapshot-dir> …]
//   node tools/chain/chain-health.mjs --corpus
//   node tools/chain/chain-health.mjs --corpus --out tools/chain/measurements/chain-health.json
//   node tools/chain/chain-health.mjs <dir> --container-reader '../codetracer-trace-format-nim/ct-print --meta-json'
//
// ── WHY THIS EXISTS, AND WHY IT IS NOT A CONFORMANCE CHECK ─────────────────────────────
//
// Two things an operator sees are recorder defects that nothing reports as a number:
// a transaction page with no linked verified source, and a trace that contradicts the source
// code it claims to be an execution of. Both are invisible to every gate this repository
// ships, and the reason is structural rather than an oversight:
//
//   * `snapshot-contract.json`'s member census declares the CONTAINER opaque. Its entry has
//     ZERO members. Every rule that mentions a recording reads the producer's own claim about
//     it — `transactions[].recording.steps`, `.callsOpened`, `.sourceLevel` — and never the
//     bytes. A producer that mis-measures its own recording and writes sidecars consistent
//     with the mis-measurement is conformant.
//   * The contract closes `outcome`, and it closes `refusalReason`, each on its own. It says
//     nothing about which COMBINATIONS a producer can reach, and nothing about whether a
//     reason agrees with the members sitting beside it on the row.
//
// So the subject of this tool is precisely what the contract cannot reach: the opaque
// container, and the joints the contract closes each side of but never relates.
//
// ── THE MEASUREMENT THAT MOTIVATES IT, RE-TAKEN BY THE TOOL ITSELF ────────────────────
//
// Over every committed snapshot in this repository on 2026-09-18: 45 traced rows, of which
// ONE declares `sourceLevel: true` — and that one is in the shipped conformance template,
// whose container is 229 bytes of ASCII. Setting the two synthetic templates and the one
// local Noir recording aside, the real chain corpus is 41 traced rows, ZERO source level,
// and 2 resolved artifacts. Every one of those trees passes `just conformance`.
//
// Run it and read the figures rather than these; that is the whole point of a tool over a
// sentence. `tools/chain/measurements/chain-health.json` is the committed reading.
//
// ── WHAT IT WRITES ────────────────────────────────────────────────────────────────────
//
// BOTH a `blocktracer/chain-health@1` artifact — one record per row, one summary per
// snapshot, one roll-up per corpus — and a short human verdict on stderr. The JSON is what
// gets diffed and asserted; the verdict is what an operator reads. They are produced from
// the same pass, so they cannot disagree.
//
// ── THE FINDING IDS ARE `H-`, AND A SUITE REFUSES AN `S5-` ────────────────────────────
//
// `tools/chain/health-checks.json` is the closed set, single-sourced the way
// `refusal-reasons.json` and `snapshot-format.json` are. `chain-health-selftest.mjs` asserts
// the `H-*` set is DISJOINT from the contract's rule ids, with a mutation arm that plants a
// contract rule id in the health file and requires the assertion to go red. A finding whose
// failure an `S5-*` rule already produces is a second copy of that rule.
//
// ── THE FIGURE THAT MAKES A ZERO MEAN SOMETHING ───────────────────────────────────────
//
// Every summary publishes `rowsExamined`, `containersNamed`, `containersOpened`,
// `containersRefused` and `checksNotRun`. A check that could not run is reported as NOT RUN
// and never as passed, and a check whose scope was empty is reported NOT RUN rather than
// passed over an empty population — "every row in an empty set is fine" is the default output
// of a broken sweep, not a measurement.
//
// `H-READ-NONE` is the control for the container half: it fires when nothing was opened and
// at least one requested check needs a recording. ITS KIND IS `not-measured`, NOT
// `unhealthy`. As things stand this tool carries no container reader, so H-READ-NONE is the
// NORMAL output and the verdict says so in those words — the tool is reporting that it could
// not answer, not that the answer is bad. `--container-reader` names one; naming it moves
// `containersOpened` off zero, and nothing more than that yet.
//
// ── TWO MEASURED FACTS THIS TOOL CARRIES AND DOES NOT FIX ─────────────────────────────
//
// Both are in `health-checks.json` under `carried`, both are echoed into every artifact, and
// both bound what a container-opening check can claim:
//
//   1. All 52 real containers here declare `meta.dat` schema version 3. The Nim reader
//      accepts 4 and 5 and refuses 3 by name — a version-3 writer packed a line-only step
//      position one line high relative to the current decode — while both Rust readers are
//      pinned at 3 and accept them. The supported sets are DISJOINT, so this corpus sits on
//      the superseded side of a disagreement no single repository settles.
//   2. That reader EXITS 0 WHILE REFUSING, 52 times out of 52. Nothing here keys a container
//      verdict on exit status; `containerReader.opened` in the data file spells both clauses.
//
// ── WHAT IT DOES NOT DO ───────────────────────────────────────────────────────────────
//
// It reaches no network, spawns nothing unless `--container-reader` is given, needs no Nim,
// no Nix and no toolchain, and writes nothing unless `--out` is given. It reads snapshot
// trees. That is deliberate: a health sweep expensive enough to think about is a health sweep
// nobody runs.

import { readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { resolve, join, dirname, relative } from 'node:path';

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HERE, '..', '..');
export const HEALTH_CHECKS_PATH = join(HERE, 'health-checks.json');
export const SNAPSHOT_CONTRACT_PATH = join(HERE, 'snapshot-contract.json');
export const SNAPSHOT_FORMAT_PATH = join(HERE, 'snapshot-format.json');

export const ARTIFACT_FORMAT = 'blocktracer/chain-health@1';

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));

// ── the two single-sourced tables, and the assertion that keeps them apart ─────────────

/** The health findings this tool can raise, as declared. */
export function healthChecks(path = HEALTH_CHECKS_PATH) {
  const d = readJson(path);
  if (d.format !== 'blocktracer/health-checks@1') {
    throw new Error(`${path}: format is ${JSON.stringify(d.format)}, expected `
      + `"blocktracer/health-checks@1"`);
  }
  return d;
}

/** The health finding ids. */
export const healthCheckIds = (path = HEALTH_CHECKS_PATH) =>
  Object.keys(healthChecks(path).checks);

/**
 * THE CONTRACT'S RULE IDS, read from the contract rather than listed here.
 *
 * This is the other half of the disjointness assertion, and it is a READ for the reason
 * every scan in this repository enumerates rather than names its subjects: a hardcoded list
 * cannot see a rule added to the contract tomorrow, and the assertion it feeds would then be
 * about the rules that existed when somebody typed them.
 */
export const contractRuleIds = (path = SNAPSHOT_CONTRACT_PATH) =>
  Object.keys(readJson(path).rules);

/** The outcome partition, read from the format file — never re-declared. */
function outcomePartition(path = SNAPSHOT_FORMAT_PATH) {
  const o = readJson(path).outcomes;
  return {
    traced: o.traced, untraced: o.untraced, chainAbsent: o.chainAbsent,
    all: [...o.traced, ...o.untraced, ...o.chainAbsent],
  };
}

// ── the container-open seam ────────────────────────────────────────────────────────────

/**
 * Open one container with the named reader, and decide whether it OPENED.
 *
 * THE EXIT STATUS IS NOT THE VERDICT and the rule is not spelled here — `containerReader`
 * in `health-checks.json` carries both clauses, because a refusal signature written in one
 * place and a verdict computed in another is two statements of one rule.
 *
 * @param {string[]} argv  program plus leading arguments; the container path is appended
 * @param {{opened: string, refusalSignature: string, refusalSignatureFlags: string}} rule
 */
export function openContainer(argv, containerPath, rule) {
  const [cmd, ...lead] = argv;
  const r = spawnSync(cmd, [...lead, containerPath],
                      { encoding: 'utf8', timeout: 120_000 });
  const said = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  if (r.error) {
    return { opened: false, why: `the reader could not be run: ${r.error.message}` };
  }
  const refused = new RegExp(rule.refusalSignature, rule.refusalSignatureFlags || undefined)
    .test(said);
  if (r.status !== 0) {
    return { opened: false, why: `the reader exited ${r.status}`, refusedByName: refused };
  }
  if (refused) {
    // The clause the exit status cannot supply. Keep the reader's own sentence: it is the
    // only thing that says WHY, and a count of refusals with no reason is a count.
    const line = (said.split('\n').find((l) => new RegExp(rule.refusalSignature).test(`\n${l}`))
                  ?? '').trim();
    return { opened: false, why: `the reader exited 0 and refused: ${line.slice(0, 300)}`,
             refusedByName: true };
  }
  return { opened: true, why: '' };
}

// ── reading one snapshot tree ──────────────────────────────────────────────────────────

const isTrue = (v) => v === true;
const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);

/**
 * Examine one snapshot tree and produce its record: one entry per row, one summary, and the
 * findings raised over it.
 *
 * @param {string} dir              the snapshot directory (the one holding `snapshot.json`)
 * @param {object} o
 * @param {object} o.registry       `health-checks.json`, already read
 * @param {string[]} [o.requested]  which check ids to run; default every declared one
 * @param {string[]} [o.readerArgv] `--container-reader`, split; absent means no reader
 */
export function examineSnapshot(dir, { registry, requested, readerArgv } = {}) {
  const reg = registry ?? healthChecks();
  const want = requested ?? Object.keys(reg.checks);
  const part = outcomePartition();
  const snapPath = join(dir, 'snapshot.json');
  const snap = readJson(snapPath);
  const prov = snap.provenance ?? {};
  const txs = Array.isArray(snap.transactions) ? snap.transactions : [];

  // ── the admissibility tables, indexed once ──────────────────────────────────────────
  const pairKey = (o, r) => `${o} ${r}`;
  const admissible = new Map(
    reg.admissibleOutcomeReasonPairs.map((p) => [pairKey(p.outcome, p.refusalReason), p]));
  const joints = reg.reasonMemberJoints;

  const rows = [];
  const sum = {
    rowsExamined: 0,
    tracedRows: 0, untracedRows: 0, chainAbsentRows: 0, unclassifiedRows: 0,
    containersNamed: 0, containersOpened: 0, containersRefused: 0,
    sourceLevelRows: 0, stepsPositionedRows: 0, sourceBundleRows: 0,
    artifacts: 0, artifactsResolved: 0,
    attributedRows: 0, unattributedRows: 0,
    declaredRungs: {},
    jointScopeRows: 0,
  };
  const raised = [];   // {check, ...detail}
  const add = (check, detail) => raised.push({ check, ...detail });

  for (const t of txs) {
    sum.rowsExamined++;
    const outcome = t?.outcome ?? null;
    const reason = t?.refusalReason ?? null;
    const traced = part.traced.includes(outcome);
    const untraced = part.untraced.includes(outcome);
    const chainAbsent = part.chainAbsent.includes(outcome);
    if (traced) sum.tracedRows++;
    else if (untraced) sum.untracedRows++;
    else if (chainAbsent) sum.chainAbsentRows++;
    else sum.unclassifiedRows++;

    const rec = t?.recording ?? {};
    const arts = Array.isArray(t?.artifacts) ? t.artifacts : [];
    const resolved = arts.filter((a) => isTrue(a?.resolved)).length;
    sum.artifacts += arts.length;
    sum.artifactsResolved += resolved;

    const row = { txHash: t?.txHash ?? null, outcome, traced };
    if (reason !== null) row.refusalReason = reason;

    if (traced) {
      if (isTrue(rec.sourceLevel)) { sum.sourceLevelRows++; row.sourceLevel = true; }
      if (num(rec.stepsPositioned) > 0) { sum.stepsPositionedRows++; row.stepsPositioned = num(rec.stepsPositioned); }
      if (t?.sourceBundles) { sum.sourceBundleRows++; row.sourceBundles = true; }
      const rung = rec.declaredRung === undefined ? 'none' : String(rec.declaredRung);
      sum.declaredRungs[rung] = (sum.declaredRungs[rung] ?? 0) + 1;
      if (rung !== 'none') row.declaredRung = rec.declaredRung;
    }
    if (arts.length) { row.artifacts = arts.length; row.artifactsResolved = resolved; }

    // ── H-RECORDER-UNATTRIBUTED — scope: rows that name a container ──────────────────
    const container = typeof t?.container === 'string' && t.container.length > 0
      ? t.container : null;
    if (container) {
      sum.containersNamed++;
      row.container = container;
      const via = t?.recordedBy ? 'recordedBy'
                : prov.runtimeCommit ? 'provenance.runtimeCommit' : null;
      if (via) { sum.attributedRows++; row.attributedBy = via; }
      else {
        sum.unattributedRows++;
        row.attributedBy = null;
        if (want.includes('H-RECORDER-UNATTRIBUTED')) {
          add('H-RECORDER-UNATTRIBUTED', {
            txHash: row.txHash,
            says: 'this row names a container and reaches neither its own `recordedBy` nor '
                + 'the snapshot\'s `provenance.runtimeCommit`, so a defect found in this '
                + 'recording cannot be pinned to the build that wrote it',
          });
        }
      }
    }

    // ── H-OUTCOME-REASON-JOINT — scope: untraced rows that carry a reason ────────────
    if (untraced && reason !== null) {
      sum.jointScopeRows++;
      const hit = admissible.get(pairKey(outcome, reason));
      row.joint = hit ? 'admissible' : 'inadmissible';
      if (!hit && want.includes('H-OUTCOME-REASON-JOINT')) {
        add('H-OUTCOME-REASON-JOINT', {
          txHash: row.txHash, outcome, refusalReason: reason,
          says: `no producer in this repository writes outcome ${JSON.stringify(outcome)} `
              + `together with reason ${JSON.stringify(reason)}; the admissible pairs for `
              + `this outcome are `
              + `[${reg.admissibleOutcomeReasonPairs.filter((p) => p.outcome === outcome)
                     .map((p) => p.refusalReason).join(', ') || 'none'}]`,
        });
      }
      for (const j of joints) {
        if (j.refusalReason !== reason) continue;
        let broken = false, says = '';
        if (j.member === 'container' && j.mustBe === 'absent' && container) {
          broken = true;
          says = `this row is reasoned ${JSON.stringify(reason)}, whose condition is that no `
               + `container was written, and it names ${JSON.stringify(container)}`;
        }
        if (j.member === 'artifacts' && j.mustBe === 'not-all-resolved'
            && arts.length > 0 && resolved === arts.length) {
          broken = true;
          says = `this row is reasoned ${JSON.stringify(reason)}, whose condition is that a `
               + `contract it executed has no provable artifact, and all ${arts.length} of `
               + `its artifacts are resolved`;
        }
        if (broken) {
          row.joint = 'inadmissible';
          if (want.includes('H-OUTCOME-REASON-JOINT')) {
            add('H-OUTCOME-REASON-JOINT', { txHash: row.txHash, outcome,
                                            refusalReason: reason, member: j.member, says });
          }
        }
      }
    }

    rows.push(row);
  }

  // ── the container-open seam ─────────────────────────────────────────────────────────
  //
  // No check consumes what a reader returns yet. What it produces is the ACCOUNTING — how
  // many of the containers this tree names could be opened at all — which is what makes
  // `H-READ-NONE` a measurement rather than a constant.
  const readerNotes = [];
  if (readerArgv && readerArgv.length) {
    for (const row of rows) {
      if (!row.container) continue;
      const p = resolve(dir, row.container);
      if (!existsSync(p)) {
        sum.containersRefused++;
        row.containerRead = 'absent';
        readerNotes.push(`${row.txHash}: ${row.container} is not on disk`);
        continue;
      }
      const v = openContainer(readerArgv, p, reg.containerReader);
      if (v.opened) { sum.containersOpened++; row.containerRead = 'opened'; }
      else {
        sum.containersRefused++;
        row.containerRead = 'refused';
        readerNotes.push(`${row.txHash}: ${v.why}`);
      }
    }
  }

  // ── which checks ran, which did not, and why ────────────────────────────────────────
  //
  // A check whose SCOPE WAS EMPTY is NOT RUN and not passed. "Every row in an empty set is
  // fine" is the default output of a sweep that found nothing to look at, and reporting it
  // green is how a broken sweep looks exactly like a clean one.
  const scope = {
    'H-SOURCE-ABSENT': sum.tracedRows,
    'H-OUTCOME-REASON-JOINT': sum.jointScopeRows,
    'H-RECORDER-UNATTRIBUTED': sum.containersNamed,
  };
  const status = {};
  const notRun = [];
  for (const id of Object.keys(reg.checks)) {
    const c = reg.checks[id];
    if (!want.includes(id)) { status[id] = { ran: false, why: 'not requested' }; continue; }
    if (c.implemented === false) {
      status[id] = { ran: false, why: c.notRunReason ?? 'not implemented' };
      notRun.push(id);
      continue;
    }
    if (id === 'H-READ-NONE') continue;              // decided below, over the whole sweep
    if (Object.prototype.hasOwnProperty.call(scope, id) && scope[id] === 0) {
      status[id] = { ran: false, why: `the scope is empty — 0 row(s) in this tree are `
                                    + `subject to it, so it measured nothing` };
      notRun.push(id);
      continue;
    }
    const mine = raised.filter((f) => f.check === id);
    status[id] = { ran: true, scope: scope[id] ?? null, raised: mine.length };
  }

  // ── H-SOURCE-ABSENT, decided over the tree ─────────────────────────────────────────
  if (want.includes('H-SOURCE-ABSENT') && sum.tracedRows > 0 && sum.sourceLevelRows === 0) {
    add('H-SOURCE-ABSENT', {
      chain: prov.chain ?? null,
      says: `not one of this tree's ${sum.tracedRows} traced row(s) declares `
          + `recording.sourceLevel — ${sum.stepsPositionedRows} carry positioned steps, `
          + `${sum.sourceBundleRows} name a source bundle, and `
          + `${sum.artifactsResolved} of ${sum.artifacts} artifact(s) resolved`,
      rates: {
        tracedRows: sum.tracedRows,
        sourceLevelRows: sum.sourceLevelRows,
        stepsPositionedRows: sum.stepsPositionedRows,
        sourceBundleRows: sum.sourceBundleRows,
        declaredRungs: sum.declaredRungs,
        artifacts: sum.artifacts,
        artifactsResolved: sum.artifactsResolved,
      },
    });
    status['H-SOURCE-ABSENT'] = { ran: true, scope: sum.tracedRows, raised: 1 };
  }

  return {
    path: relative(REPO_ROOT, resolve(dir)) || '.',
    chain: prov.chain ?? null,
    snapshotFormat: snap.format ?? null,
    summary: { ...sum, checksNotRun: notRun },
    checkStatus: status,
    findings: raised,
    readerNotes,
    rows,
  };
}

// ── the sweep ──────────────────────────────────────────────────────────────────────────

/**
 * Every snapshot tree in this repository, enumerated rather than named.
 *
 * `git ls-files -c -o --exclude-standard` is CACHED PLUS UNTRACKED-NOT-IGNORED on purpose. A
 * subject list built from `git ls-files` alone is a claim about the tree's HISTORY, so a
 * snapshot added by the change being measured is not in it and the sweep reports a population
 * the change is not in. The `-o` half closes that; the `--exclude-standard` half keeps
 * generated copies of the shipped templates out, which are the same trees twice.
 */
export function corpusSnapshotDirs(root = REPO_ROOT) {
  const out = execFileSync('git', ['-C', root, 'ls-files', '-c', '-o', '--exclude-standard'],
                           { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return [...new Set(out.split('\n')
    .filter((p) => p.endsWith('/snapshot.json') || p === 'snapshot.json')
    .map((p) => dirname(join(root, p))))].sort();
}

/** Roll the per-snapshot summaries up, and group the source census by chain.
 *
 *  `checksNotRun` AT CORPUS LEVEL IS NOT THE UNION of the per-tree lists, and the difference
 *  matters: a check whose scope was empty in one tree and full in five ran, and reporting it
 *  as "did not run" over the corpus understates what was measured exactly as badly as the
 *  other direction overstates it. So the corpus list is the checks that ran in NO tree at
 *  all, and `checkCoverage` carries the per-check split with the reasons behind it. */
function rollUp(snapshots) {
  const keys = ['rowsExamined', 'tracedRows', 'untracedRows', 'chainAbsentRows',
                'unclassifiedRows', 'containersNamed', 'containersOpened',
                'containersRefused', 'sourceLevelRows', 'stepsPositionedRows',
                'sourceBundleRows', 'artifacts', 'artifactsResolved', 'attributedRows',
                'unattributedRows', 'jointScopeRows'];
  const total = Object.fromEntries(keys.map((k) => [k, 0]));
  const rungs = {};
  const coverage = {};
  const byChain = {};
  for (const s of snapshots) {
    for (const k of keys) total[k] += s.summary[k] ?? 0;
    for (const [r, n] of Object.entries(s.summary.declaredRungs)) {
      rungs[r] = (rungs[r] ?? 0) + n;
    }
    for (const [id, st] of Object.entries(s.checkStatus)) {
      const c = coverage[id] ??= { ranIn: 0, notRunIn: 0, reasons: [] };
      if (st.ran) c.ranIn++;
      else {
        c.notRunIn++;
        if (!c.reasons.includes(st.why)) c.reasons.push(st.why);
      }
    }
    const c = s.chain ?? '(unnamed)';
    const b = byChain[c] ??= { snapshots: 0, tracedRows: 0, sourceLevelRows: 0,
                               stepsPositionedRows: 0, sourceBundleRows: 0,
                               artifacts: 0, artifactsResolved: 0 };
    b.snapshots++;
    for (const k of ['tracedRows', 'sourceLevelRows', 'stepsPositionedRows',
                     'sourceBundleRows', 'artifacts', 'artifactsResolved']) {
      b[k] += s.summary[k] ?? 0;
    }
  }
  total.declaredRungs = rungs;
  total.checksNotRun = Object.keys(coverage).filter((id) => coverage[id].ranIn === 0).sort();
  return { snapshots: snapshots.length, totals: total, checkCoverage: coverage,
           sourceCensusByChain: byChain };
}

/**
 * The whole sweep: examine each tree, then decide the one finding that ranges over the run.
 *
 * `H-READ-NONE` is decided HERE and not per tree, because it is a statement about the SWEEP:
 * nothing was opened, and a check that needs an opened recording was asked for.
 */
export function sweep(dirs, { registry, requested, readerArgv, now } = {}) {
  const reg = registry ?? healthChecks();
  const want = requested ?? Object.keys(reg.checks);
  const snapshots = dirs.map((d) => examineSnapshot(d, { registry: reg, requested: want, readerArgv }));
  const corpus = rollUp(snapshots);

  // `H-READ-NONE` ranges over the SWEEP rather than over a tree, so no tree's `checkStatus`
  // carries it and the roll-up cannot see it. Its coverage is stated here, where it is
  // decided, rather than being left out of a table whose whole job is to account for every
  // declared check.
  corpus.checkCoverage['H-READ-NONE'] = want.includes('H-READ-NONE')
    ? { ranIn: 1, notRunIn: 0, reasons: [], scope: 'the sweep as a whole' }
    : { ranIn: 0, notRunIn: 1, reasons: ['not requested'], scope: 'the sweep as a whole' };
  corpus.totals.checksNotRun = Object.keys(corpus.checkCoverage)
    .filter((id) => corpus.checkCoverage[id].ranIn === 0).sort();

  const needsContainerRequested = want.filter((id) => reg.checks[id]?.needsContainer === true);
  const findings = [];
  for (const s of snapshots) {
    for (const f of s.findings) findings.push({ ...f, path: s.path });
  }
  if (want.includes('H-READ-NONE') && needsContainerRequested.length > 0
      && corpus.totals.containersOpened === 0) {
    findings.push({
      check: 'H-READ-NONE',
      says: `no recording was opened on this sweep — ${corpus.totals.containersNamed} `
          + `container(s) are named by rows and 0 were opened — while `
          + `${needsContainerRequested.length} requested check(s) can only be answered by `
          + `opening one: ${needsContainerRequested.join(', ')}. Those checks are NOT RUN. `
          + `This is the tool saying it could not answer, not that the answer is bad.`,
      needsContainerRequested,
      containersNamed: corpus.totals.containersNamed,
      containersOpened: 0,
    });
    if (!corpus.totals.checksNotRun.includes('H-READ-NONE')) { /* H-READ-NONE itself ran */ }
  }

  const byKind = { unhealthy: [], 'not-measured': [] };
  for (const f of findings) {
    const kind = reg.checks[f.check]?.kind === 'not-measured' ? 'not-measured' : 'unhealthy';
    byKind[kind].push(f);
  }

  return {
    format: ARTIFACT_FORMAT,
    tool: 'tools/chain/chain-health.mjs',
    generatedAt: now ?? new Date().toISOString(),
    checksRequested: want,
    containerReader: readerArgv && readerArgv.length ? readerArgv.join(' ') : null,
    carried: reg.carried,
    corpus,
    findings,
    findingCounts: { unhealthy: byKind.unhealthy.length,
                     notMeasured: byKind['not-measured'].length },
    snapshots,
  };
}

// ── rendering ──────────────────────────────────────────────────────────────────────────

/**
 * Pretty-print with indent 1, EXCEPT that a per-row record is one line.
 *
 * A thousand rows at six lines each is a file nobody reads and a diff nobody can follow; one
 * row per line is both readable and the shape `git diff` is good at. `JSON.parse` of the
 * result is the same object either way, which the suite asserts.
 */
export function render(value, indent = 0, compact = false) {
  const pad = ' '.repeat(indent);
  if (compact || value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) {
    if (value.length === 0) return '[]';
    const rowish = value.every((v) => v && typeof v === 'object' && !Array.isArray(v)
                                      && Object.prototype.hasOwnProperty.call(v, 'txHash'));
    const parts = value.map((v) => `${pad} ${render(v, indent + 1, rowish)}`);
    return `[\n${parts.join(',\n')}\n${pad}]`;
  }
  const ks = Object.keys(value);
  if (ks.length === 0) return '{}';
  const parts = ks.map((k) => `${pad} ${JSON.stringify(k)}: ${render(value[k], indent + 1)}`);
  return `{\n${parts.join(',\n')}\n${pad}}`;
}

/** The short human verdict. Returns the lines; the caller decides where they go. */
export function verdict(report, registry) {
  const reg = registry ?? healthChecks();
  const t = report.corpus.totals;
  const L = [];
  L.push(`RECORDING HEALTH — ${report.corpus.snapshots} snapshot(s)`);
  L.push(`  rows examined        ${t.rowsExamined}`);
  L.push(`  containers named     ${t.containersNamed}`);
  L.push(`  containers opened    ${t.containersOpened}`
       + (report.containerReader ? '' : '   (no container reader named)'));
  L.push(`  containers refused   ${t.containersRefused}`);
  L.push(`  checks not run       ${t.checksNotRun.length}`
       + (t.checksNotRun.length ? `   ${t.checksNotRun.join(', ')}   (ran in no tree)` : ''));
  L.push('');
  L.push(`  source census: ${t.sourceLevelRows} of ${t.tracedRows} traced row(s) declare `
       + `source level; ${t.stepsPositionedRows} carry positioned steps; `
       + `${t.sourceBundleRows} name a source bundle; ${t.artifactsResolved} of `
       + `${t.artifacts} artifact(s) resolved`);
  for (const [chain, b] of Object.entries(report.corpus.sourceCensusByChain)) {
    L.push(`    ${chain.padEnd(24)} ${b.sourceLevelRows}/${b.tracedRows} source level, `
         + `${b.artifactsResolved}/${b.artifacts} artifacts resolved`);
  }
  L.push('');

  const unhealthy = report.findings.filter((f) => reg.checks[f.check]?.kind !== 'not-measured');
  const notMeasured = report.findings.filter((f) => reg.checks[f.check]?.kind === 'not-measured');

  if (unhealthy.length === 0) L.push('HEALTHY — no finding about the recordings themselves');
  else {
    L.push(`UNHEALTHY — ${unhealthy.length} finding(s) about the recordings themselves`);
    for (const f of unhealthy.slice(0, 40)) {
      L.push(`  ${f.check}  ${f.path ?? ''}${f.txHash ? ` ${f.txHash}` : ''}`);
      L.push(`    ${f.says}`);
    }
    if (unhealthy.length > 40) L.push(`  … and ${unhealthy.length - 40} more, in the artifact`);
  }
  L.push('');
  // THE TWO VERDICTS ARE SEPARATE SENTENCES. "Unhealthy" is a statement about the corpus;
  // "not measured" is a statement about this run. Folding them into one line is how a sweep
  // that read nothing comes to look like a sweep that found nothing.
  const cov = report.corpus.checkCoverage;
  const partial = Object.keys(cov).filter((id) => cov[id].ranIn > 0 && cov[id].notRunIn > 0);
  if (notMeasured.length === 0 && t.checksNotRun.length === 0 && partial.length === 0) {
    L.push('NOT MEASURED — nothing; every requested check ran over every tree');
  } else {
    L.push(`NOT MEASURED — ${notMeasured.length} finding(s); ${t.checksNotRun.length} `
         + `check(s) ran in no tree, ${partial.length} ran in some and not others`);
    for (const f of notMeasured) L.push(`  ${f.check}  ${f.says}`);
    for (const id of [...t.checksNotRun, ...partial]) {
      const c = cov[id];
      L.push(`  ${id}  ran in ${c.ranIn} of ${c.ranIn + c.notRunIn} tree(s)`
           + (c.reasons.length ? ` — ${c.reasons.join(' / ')}` : ''));
    }
  }
  L.push('');
  for (const c of report.carried ?? []) L.push(`  carried: ${c.note}`);
  return L;
}

// ── the CLI ────────────────────────────────────────────────────────────────────────────

const USAGE =
  'usage: node tools/chain/chain-health.mjs <snapshot-dir> [<snapshot-dir> …]\n'
+ '       node tools/chain/chain-health.mjs --corpus\n'
+ '\n'
+ '  --corpus                  every snapshot tree in this repository\n'
+ '  --out <file>              write the blocktracer/chain-health@1 artifact there\n'
+ '  --container-reader <cmd>  a program invoked as `<cmd> <container-path>`; it moves\n'
+ '                            containersOpened off zero and nothing else yet\n'
+ '  --check <id>              run only these findings (repeatable)\n'
+ '  --quiet                   the artifact on stdout, no verdict on stderr\n'
+ '\n'
+ 'exit 0 nothing found; 1 an unhealthy finding; 2 usage or IO; 3 only not-measured\n';

export function main(argv) {
  const dirs = [];
  let out = null, readerArgv = null, quiet = false, corpus = false;
  const requested = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--corpus') corpus = true;
    else if (a === '--out') out = argv[++i];
    else if (a === '--container-reader') readerArgv = String(argv[++i] ?? '').split(/\s+/).filter(Boolean);
    else if (a === '--check') requested.push(argv[++i]);
    else if (a === '--quiet') quiet = true;
    else if (a === '--help' || a === '-h') { process.stderr.write(USAGE); return 2; }
    else if (a.startsWith('--')) { process.stderr.write(`chain-health: unknown option ${a}\n${USAGE}`); return 2; }
    else dirs.push(a);
  }

  const reg = healthChecks();

  // A REQUESTED FINDING THAT DOES NOT EXIST IS A FAILURE, not an empty selection. A sweep
  // asked for a check it does not have and run anyway reports a clean pass over a question
  // nobody asked.
  for (const id of requested) {
    if (!Object.prototype.hasOwnProperty.call(reg.checks, id)) {
      process.stderr.write(`chain-health: no such finding ${JSON.stringify(id)} — the set is `
        + `[${Object.keys(reg.checks).join(', ')}]\n`);
      return 2;
    }
  }

  let subjects = dirs;
  if (corpus) {
    if (dirs.length) { process.stderr.write(`chain-health: --corpus takes no directories\n${USAGE}`); return 2; }
    subjects = corpusSnapshotDirs();
  }
  if (subjects.length === 0) { process.stderr.write(USAGE); return 2; }

  for (const d of subjects) {
    const p = join(d, 'snapshot.json');
    if (!existsSync(p) || !statSync(p).isFile()) {
      process.stderr.write(`chain-health: ${d} holds no snapshot.json\n`);
      return 2;
    }
  }

  const report = sweep(subjects, { registry: reg, requested: requested.length ? requested : undefined,
                                   readerArgv });
  const text = render(report) + '\n';
  if (out) writeFileSync(out, text);
  if (quiet) process.stdout.write(text);
  else {
    process.stdout.write(text);
    process.stderr.write('\n' + verdict(report, reg).join('\n') + '\n');
  }

  if (report.findingCounts.unhealthy > 0) return 1;
  if (report.findingCounts.notMeasured > 0) return 3;
  return 0;
}

// Run only when this file IS the program. `chain-health-selftest.mjs` imports it, and an
// unguarded `main()` would make that import sweep the corpus.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exit(main(process.argv.slice(2)));
  } catch (e) {
    process.stderr.write(`chain-health: ${e.stack ?? e.message}\n`);
    process.exit(2);
  }
}
