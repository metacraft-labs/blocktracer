#!/usr/bin/env node
// chain-health-selftest.mjs — proof that the recording-health sweep MEASURES.
//
//   node tools/chain/chain-health-selftest.mjs
//
// WHY THIS EXISTS. `chain-health.mjs` reports figures about trees that are already
// conformant, so nothing else in this repository can contradict it: there is no second
// opinion on "0 of 41 recordings reach source level" and no gate that goes red when the
// figure is wrong. A tool whose output nobody can check is a tool whose output is a claim.
//
// So every finding it can raise is driven here against a TWIN — a synthetic row that must
// NOT raise it — beside a MUTATION with one field changed that must. A check that fires on
// everything measures nothing, and a check that fires on nothing measures nothing either.
//
// ── THE ONE ARM THAT IS ABOUT THE TOOL'S RIGHT TO EXIST ───────────────────────────────
//
// §1 asserts that the `H-*` finding ids are DISJOINT from the contract's rule ids, in both
// directions, with an anti-vacuity guard so an empty read on either side cannot satisfy it.
// Its mutation plants `S5-COUNTS-ROWS` in the health registry and requires the assertion to
// go red. A health finding whose failure a contract rule already produces is a second copy
// of that rule, and this file is where that is refused rather than left to a reviewer.
//
// ── THE ARM THAT IS ABOUT A ZERO ──────────────────────────────────────────────────────
//
// §2 drives the container-open accounting with a STAND-IN READER, because the figures
// `containersOpened` / `containersRefused` are the control for every question the sweep
// cannot yet answer, and a control that can never produce a non-zero value is not one. One
// of its arms is the measured fact that the real reader for these containers EXITS 0 WHILE
// REFUSING: a stand-in that does the same must be counted refused, and its twin — a reader
// that mentions the word error in passing and succeeds — must be counted opened.
//
// Offline and toolchain-free: it builds small trees in a temporary directory, runs `node`,
// and reads files already in this repository.

import { mkdtempSync, writeFileSync, rmSync, mkdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  healthChecks, healthCheckIds, contractRuleIds, corpusSnapshotDirs,
  examineSnapshot, sweep, render, verdict, HEALTH_CHECKS_PATH, REPO_ROOT,
} from './chain-health.mjs';
import { REFUSAL_REASON_IDS, UNTRACED_OUTCOMES, TRACED_OUTCOMES, CHAIN_ABSENT_OUTCOMES }
  from './lib/refusal.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, 'chain-health.mjs');

let asserted = 0, failed = 0;
const ck = (label, cond) => { asserted++; if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`); };
const bite = (label, cond) => { asserted++; if (!cond) { failed++; console.error(`  FAIL  MUTATION DID NOT BITE  ${label}`); } else console.error(`  bite  ${label}`); };

const REG = healthChecks();
const tmp = mkdtempSync(join(tmpdir(), 'bt-health-'));
// §6 plants this INSIDE the repository — it has to be inside, because what it proves is that
// the corpus enumeration sees an untracked tree — so it is removed by the same handler that
// removes the temporary directory, and not only by its own `finally`.
const PROBE = join(REPO_ROOT, 'tools', 'chain', '.health-selftest-probe');
const cleanup = () => {
  for (const p of [tmp, PROBE]) {
    try { rmSync(p, { recursive: true, force: true }); } catch { /* best effort */ }
  }
};
// §32h: a harness killed between writing its subjects and removing them leaves them behind.
// Everything this suite writes is under one temporary directory it owns, so the handler is
// three lines and it converts the likeliest manual intervention into a clean exit.
for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => { cleanup(); process.exit(130); });
}

let treeN = 0;
/** A snapshot tree, written where this suite can delete it. `rows` are spread verbatim. */
function tree({ rows, provenance = {}, format = 'blocktracer/chain-snapshot@2',
                containers = [] } = {}) {
  const dir = join(tmp, `t${treeN++}`);
  mkdirSync(join(dir, 'ct'), { recursive: true });
  for (const c of containers) {
    writeFileSync(join(dir, 'ct', c), Buffer.from([0xC0, 0xDE, 0x72, 0xAC, 0xE2, 3, 0, 0]));
  }
  writeFileSync(join(dir, 'snapshot.json'), JSON.stringify({
    format,
    provenance: { chain: 'twin-chain', runtimeCommit: 'a'.repeat(40), ...provenance },
    transactions: rows,
  }, null, 1));
  return dir;
}

const one = (dir, opts = {}) => examineSnapshot(dir, { registry: REG, ...opts });
const raisedIds = (rep) => rep.findings.map((f) => f.check);
const has = (rep, id) => raisedIds(rep).includes(id);

const run = (args) => {
  const r = spawnSync(process.execPath, [TOOL, ...args], { encoding: 'utf8', timeout: 120_000 });
  return { rc: r.status, out: `${r.stdout}`, err: `${r.stderr}` };
};

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§1 — the finding ids are the contract\'s rule ids\' complement, and that is asserted');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  /**
   * The disjointness verdict, as a function, so the mutation arms can drive it.
   *
   * ANTI-VACUITY IS PART OF THE VERDICT AND NOT A SEPARATE CHECK. Two empty sets are
   * disjoint, so a read that returned nothing — a renamed key, a moved file, a table
   * emptied by an edit — satisfies "no id is in both" perfectly. Trap 4: the scan that
   * finds nothing passes every must-not-contain check written over it.
   */
  const disjointVerdict = (hIds, cIds) => {
    if (hIds.length === 0) return { ok: false, why: 'the health id set is EMPTY' };
    if (cIds.length === 0) return { ok: false, why: 'the contract rule id set is EMPTY' };
    const both = hIds.filter((id) => cIds.includes(id));
    return both.length === 0
      ? { ok: true, why: `${hIds.length} health id(s) vs ${cIds.length} contract rule id(s)` }
      : { ok: false, why: `these ids are in BOTH tables: ${both.join(', ')}` };
  };

  const h = healthCheckIds(), c = contractRuleIds();
  const v = disjointVerdict(h, c);
  ck(`control: the two sets are disjoint — ${v.why}`, v.ok);
  ck(`control: both sets were actually read — ${h.length} health, ${c.length} contract`,
     h.length > 0 && c.length > 0);
  // THE IDS ARE ENUMERATED, NOT NAMED. A hardcoded list of the health ids could not see a
  // finding added tomorrow, and the assertion it fed would be about the ids that existed
  // when somebody typed them (trap 35).
  ck(`control: every health id carries the H- prefix — [${h.join(', ')}]`,
     h.length > 0 && h.every((id) => /^H-[A-Z0-9-]+$/.test(id)));
  ck('control: no contract rule id carries the H- prefix, so the prefix alone separates them',
     c.every((id) => !id.startsWith('H-')));

  // MUTATION, the one the design names: a contract rule id planted in the health registry.
  const bad = JSON.parse(readFileSync(HEALTH_CHECKS_PATH, 'utf8'));
  bad.checks['S5-COUNTS-ROWS'] = { kind: 'unhealthy', needsContainer: false, implemented: true,
                                   question: 'planted', healthy: 'planted', fires: 'planted',
                                   why: 'planted' };
  const badPath = join(tmp, 'health-checks-mutated.json');
  writeFileSync(badPath, JSON.stringify(bad));
  const mv = disjointVerdict(healthCheckIds(badPath), c);
  bite('mutation: a contract rule id added to the health registry is refused by name',
       !mv.ok && /S5-COUNTS-ROWS/.test(mv.why));

  // MUTATION, the other direction: a health id planted in the contract's rule table.
  const mv2 = disjointVerdict(h, [...c, 'H-SOURCE-ABSENT']);
  bite('mutation: a health id added to the contract rule table is refused by name',
       !mv2.ok && /H-SOURCE-ABSENT/.test(mv2.why));

  // ANTI-VACUITY ARMS. Each side emptied in turn.
  bite('mutation: an EMPTY health id set is refused rather than found disjoint',
       !disjointVerdict([], c).ok);
  bite('mutation: an EMPTY contract rule id set is refused rather than found disjoint',
       !disjointVerdict(h, []).ok);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§2 — H-READ-NONE: a sweep that opened nothing says so, and one that opened something does not');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  const row = {
    txHash: '0xaa', blockNumber: 1, txIndexInBlock: 0, outcome: 'replayed',
    container: 'ct/0xaa.ct', containerBytes: 8,
    recording: { steps: 1, sourceLevel: true, stepsPositioned: 1 },
    sourceBundles: 'text/0xaa.json',
  };
  const dir = tree({ rows: [row], containers: ['0xaa.ct'] });

  // A stand-in reader. The seam invokes `<cmd> <container-path>`; what the reader IS is not
  // this suite's subject — that it is ASKED, and that its answer is read by both clauses, is.
  const stub = (body) => {
    const p = join(tmp, `reader${treeN++}.mjs`);
    writeFileSync(p, body);
    return `${process.execPath} ${p}`;
  };
  const READS = stub('process.stdout.write("meta.dat v4, 1 chunk, no errors detected\\n");\n');
  const REFUSES_WITH_ZERO = stub(
    'process.stdout.write("Error: meta.dat present but corrupt: schema version 3 predates '
    + 'the global line index correction\\n"); process.exit(0);\n');
  const EXITS_NONZERO = stub('process.exit(4);\n');

  const control = run([dir, '--container-reader', READS, '--quiet']);
  const cRep = JSON.parse(control.out);
  ck('control: a tree with one readable container reports containersOpened: 1',
     cRep.corpus.totals.containersOpened === 1);
  ck('control: …and containersRefused: 0', cRep.corpus.totals.containersRefused === 0);
  ck('control: …and does NOT raise H-READ-NONE', !has(cRep, 'H-READ-NONE'));
  ck('control: …and exits 0', control.rc === 0);
  // THE TWIN FOR THE REFUSAL SIGNATURE. This reader's output contains the word "errors" and
  // it succeeded. A signature matched anywhere in the text rather than as a line-leading
  // `Error:` would call this a refusal, which is the false RED the two-clause rule risks.
  ck('twin: a reader that MENTIONS errors and succeeds is counted OPENED, not refused',
     cRep.snapshots[0].rows[0].containerRead === 'opened');

  // MUTATION 1, the one the design names: the same tree with the container removed.
  const gone = tree({ rows: [row], containers: [] });
  const m1 = run([gone, '--container-reader', READS, '--quiet']);
  const m1Rep = JSON.parse(m1.out);
  bite('mutation: the same tree with the container removed reports containersOpened 0',
       m1Rep.corpus.totals.containersOpened === 0);
  bite('mutation: …and containersRefused 1, so the absence was COUNTED and not skipped',
       m1Rep.corpus.totals.containersRefused === 1);
  bite('mutation: …and raises H-READ-NONE', has(m1Rep, 'H-READ-NONE'));
  bite('mutation: …and exits non-zero', m1.rc !== 0 && m1.rc !== null);

  // MUTATION 2, the measured trap: a reader that REFUSES AND EXITS 0.
  const m2 = run([dir, '--container-reader', REFUSES_WITH_ZERO, '--quiet']);
  const m2Rep = JSON.parse(m2.out);
  bite('mutation: a reader that refuses by name and exits 0 is counted REFUSED, not opened',
       m2Rep.corpus.totals.containersOpened === 0
       && m2Rep.corpus.totals.containersRefused === 1);
  bite('mutation: …and the reader\'s own sentence is kept, so the refusal has a reason',
       /schema version 3/.test(JSON.stringify(m2Rep.snapshots[0].readerNotes)));
  bite('mutation: …and H-READ-NONE fires over a tree whose container is present and intact',
       has(m2Rep, 'H-READ-NONE'));

  // MUTATION 3: a reader that simply fails.
  const m3 = run([dir, '--container-reader', EXITS_NONZERO, '--quiet']);
  const m3Rep = JSON.parse(m3.out);
  bite('mutation: a reader that exits non-zero is counted refused',
       m3Rep.corpus.totals.containersRefused === 1 && has(m3Rep, 'H-READ-NONE'));

  // NO READER AT ALL — which is the NORMAL state of this tool, and it must present as NOT
  // MEASURED rather than as a failure of the tree.
  const none = run([dir, '--quiet']);
  const nRep = JSON.parse(none.out);
  ck('no reader named: containersOpened is 0 and H-READ-NONE fires — the normal output today',
     nRep.corpus.totals.containersOpened === 0 && has(nRep, 'H-READ-NONE'));
  ck('no reader named: H-READ-NONE\'s kind is not-measured, not unhealthy',
     REG.checks['H-READ-NONE'].kind === 'not-measured');
  ck('no reader named: the exit distinguishes not-measured (3) from unhealthy (1)',
     none.rc === 3 && nRep.findingCounts.unhealthy === 0
     && nRep.findingCounts.notMeasured === 1);
  const V = verdict(nRep, REG).join('\n');
  ck('no reader named: the human verdict says HEALTHY and NOT MEASURED as separate sentences',
     /^HEALTHY —/m.test(V) && /^NOT MEASURED —/m.test(V));
  ck('no reader named: …and it names the check that could not run, with its reason',
     /H-CONTAINER-UNREADABLE/.test(V) && /container reader/.test(V));

  // A check that could not run is never reported as passed. Asserted over the ENUMERATED
  // set of declared container checks, not over a name typed here.
  const needsContainer = Object.keys(REG.checks)
    .filter((id) => REG.checks[id].needsContainer === true);
  ck(`the registry declares at least one container check, so H-READ-NONE is reachable — `
     + `[${needsContainer.join(', ')}]`, needsContainer.length > 0);
  ck('every declared container check is reported NOT RUN on a sweep with no reader',
     needsContainer.every((id) => nRep.corpus.totals.checksNotRun.includes(id)));
  ck('…and none of them appears as a passed check anywhere in the artifact',
     needsContainer.every((id) => nRep.snapshots.every((s) => s.checkStatus[id]?.ran !== true)));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§3 — H-SOURCE-ABSENT: operator symptom #1 as a number');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  const sourceRow = (over = {}) => ({
    txHash: '0xs1', blockNumber: 1, txIndexInBlock: 0, outcome: 'replayed',
    container: 'ct/0xs1.ct', containerBytes: 8,
    recording: { steps: 4, sourceLevel: true, stepsPositioned: 4, declaredRung: 1 },
    sourceBundles: 'text/0xs1.json',
    artifacts: [{ address: '0xc1', resolved: true }],
    ...over,
  });

  const twin = one(tree({ rows: [sourceRow()], containers: ['0xs1.ct'] }));
  ck('twin: a traced row that declares source level raises nothing',
     !has(twin, 'H-SOURCE-ABSENT'));
  ck('twin: …and the check RAN rather than being skipped',
     twin.checkStatus['H-SOURCE-ABSENT'].ran === true);
  ck('twin: …and the rates are published whether or not it fires',
     twin.summary.tracedRows === 1 && twin.summary.sourceLevelRows === 1
     && twin.summary.stepsPositionedRows === 1 && twin.summary.sourceBundleRows === 1
     && twin.summary.artifacts === 1 && twin.summary.artifactsResolved === 1);

  // MUTATION: ONE FIELD. Everything else about the row is unchanged — it still carries
  // positions, a bundle and a resolved artifact — so the finding is about `sourceLevel` and
  // not about a row stripped of everything.
  const mut = one(tree({
    rows: [sourceRow({ recording: { steps: 4, sourceLevel: false, stepsPositioned: 4,
                                    declaredRung: 1 } })],
    containers: ['0xs1.ct'] }));
  bite('mutation: sourceLevel false on the only traced row raises H-SOURCE-ABSENT',
       has(mut, 'H-SOURCE-ABSENT'));
  const f = mut.findings.find((x) => x.check === 'H-SOURCE-ABSENT');
  bite('mutation: …and the finding carries the per-chain rates, not just a verdict',
       f.chain === 'twin-chain' && f.rates.tracedRows === 1 && f.rates.sourceLevelRows === 0
       && f.rates.stepsPositionedRows === 1 && f.rates.sourceBundleRows === 1
       && f.rates.artifactsResolved === 1 && f.rates.declaredRungs['1'] === 1);

  // ONE SOURCE-LEVEL ROW AMONG SEVERAL IS HEALTH. The finding is "does this chain EVER reach
  // source level", so a tree with one of three must not fire — otherwise the shipped
  // template would, and a check that fires on everything measures nothing.
  const mixed = one(tree({
    rows: [sourceRow(),
           sourceRow({ txHash: '0xs2', recording: { steps: 1, sourceLevel: false } }),
           sourceRow({ txHash: '0xs3', outcome: 'divergent', recording: { steps: 1 } })],
    containers: ['0xs1.ct'] }));
  ck('twin: one source-level row among three is not a finding',
     !has(mixed, 'H-SOURCE-ABSENT') && mixed.summary.tracedRows === 3
     && mixed.summary.sourceLevelRows === 1);

  // ANTI-VACUITY: no traced rows at all is NOT RUN, never passed.
  const empty = one(tree({ rows: [{ txHash: '0xz', blockNumber: 1, txIndexInBlock: 0,
                                    outcome: 'pruned', refusalReason: 'not-attempted',
                                    reason: 'x' }] }));
  ck('anti-vacuity: a tree with no traced row reports H-SOURCE-ABSENT NOT RUN',
     empty.checkStatus['H-SOURCE-ABSENT'].ran === false
     && /scope is empty/.test(empty.checkStatus['H-SOURCE-ABSENT'].why));
  ck('anti-vacuity: …and lists it in the summary\'s checksNotRun',
     empty.summary.checksNotRun.includes('H-SOURCE-ABSENT'));
  ck('anti-vacuity: …and does not report it as a finding either way',
     !has(empty, 'H-SOURCE-ABSENT'));

  // THE STANDING CONTROL, over a REAL tree in this repository.
  const kit = one(join(REPO_ROOT, 'conformance-kit', 'template', 'complete'));
  ck('control: the shipped complete template\'s source-level row does NOT raise the finding',
     !has(kit, 'H-SOURCE-ABSENT'));
  ck(`control: …and it is a real reading — ${kit.summary.sourceLevelRows} of `
     + `${kit.summary.tracedRows} traced row(s) declare source level`,
     kit.summary.tracedRows === 3 && kit.summary.sourceLevelRows === 1);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§4 — H-OUTCOME-REASON-JOINT: the product the contract never constrains');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  const declined = (over) => ({ txHash: '0xd1', blockNumber: 1, txIndexInBlock: 0,
                                reason: 'a sentence', ...over });

  // TWIN: the pair 912 committed rows carry. `pruned` names what the producer OBSERVED of
  // the node and `not-attempted` what the run ESTABLISHED, and the producer writes them
  // together on purpose. A table written from the outcome's name would redden all 912.
  const t1 = one(tree({ rows: [declined({ outcome: 'pruned', refusalReason: 'not-attempted' })] }));
  ck('twin: outcome pruned with reason not-attempted is admissible — the corpus\'s 912 rows',
     !has(t1, 'H-OUTCOME-REASON-JOINT') && t1.rows[0].joint === 'admissible');
  ck('twin: …and the check RAN, over a scope of 1', t1.checkStatus['H-OUTCOME-REASON-JOINT'].ran === true
     && t1.summary.jointScopeRows === 1);

  const m1 = one(tree({ rows: [declined({ outcome: 'pruned', refusalReason: 'prestate-unavailable' })] }));
  bite('mutation: outcome pruned with reason prestate-unavailable raises the finding',
       has(m1, 'H-OUTCOME-REASON-JOINT') && m1.rows[0].joint === 'inadmissible');
  bite('mutation: …and the finding names the pair and the admissible alternatives',
       /body-unavailable/.test(m1.findings[0].says)
       && /not-attempted/.test(m1.findings[0].says));

  // THE REASON-MEMBER JOINT, first half.
  const t2 = one(tree({ rows: [declined({ outcome: 'refused',
                                          refusalReason: 'no-container-written' })] }));
  ck('twin: a no-container-written row that names no container is admissible',
     !has(t2, 'H-OUTCOME-REASON-JOINT'));
  const m2 = one(tree({ rows: [declined({ outcome: 'refused',
                                          refusalReason: 'no-container-written',
                                          container: 'ct/0xd1.ct', containerBytes: 8 })],
                        containers: ['0xd1.ct'] }));
  bite('mutation: a no-container-written row that NAMES a container raises the finding',
       has(m2, 'H-OUTCOME-REASON-JOINT')
       && /whose condition is that no container was written/.test(
            m2.findings.find((x) => x.check === 'H-OUTCOME-REASON-JOINT').says));

  // THE REASON-MEMBER JOINT, second half — and its twin is the one that matters, because
  // a transaction executes several contracts and one resolving while another does not is
  // the condition rather than a contradiction.
  const t3 = one(tree({ rows: [declined({ outcome: 'refused',
                                          refusalReason: 'artifact-unresolvable',
                                          artifacts: [{ address: '0xa', resolved: true },
                                                      { address: '0xb', resolved: false }] })] }));
  ck('twin: artifact-unresolvable with SOME artifacts resolved is admissible',
     !has(t3, 'H-OUTCOME-REASON-JOINT'));
  const t3b = one(tree({ rows: [declined({ outcome: 'refused',
                                           refusalReason: 'artifact-unresolvable' })] }));
  ck('twin: …and a row carrying no artifacts array at all is not a finding either',
     !has(t3b, 'H-OUTCOME-REASON-JOINT'));
  const m3 = one(tree({ rows: [declined({ outcome: 'refused',
                                          refusalReason: 'artifact-unresolvable',
                                          artifacts: [{ address: '0xa', resolved: true }] })] }));
  bite('mutation: artifact-unresolvable with EVERY artifact resolved raises the finding',
       has(m3, 'H-OUTCOME-REASON-JOINT')
       && /all 1 of its artifacts are resolved/.test(
            m3.findings.find((x) => x.check === 'H-OUTCOME-REASON-JOINT').says));

  // ── THE SCOPE, WHICH IS WHAT KEEPS THIS FROM BEING A SECOND COPY OF A CONTRACT RULE ──
  //
  // Three populations are deliberately out of scope because a named rule already refuses
  // each. If this finding fired on any of them it would be that rule, spelled again.
  const s1 = one(tree({ rows: [{ txHash: '0xs', blockNumber: 1, txIndexInBlock: 0,
                                 outcome: 'replayed', container: 'ct/0xs.ct',
                                 containerBytes: 8, recording: { steps: 1, sourceLevel: true },
                                 refusalReason: 'runtime-refused' }],
                        containers: ['0xs.ct'] }));
  ck('scope: a TRACED row carrying a reason is not this finding\'s business — auditRefusals\'',
     !has(s1, 'H-OUTCOME-REASON-JOINT') && s1.summary.jointScopeRows === 0);
  const s2 = one(tree({ rows: [{ txHash: '0xp', blockNumber: 1, txIndexInBlock: 0,
                                 outcome: 'private-only', reason: 'no public half',
                                 refusalReason: 'runtime-refused' }] }));
  ck('scope: a chain-absent row carrying a reason is S5-REFUSALREASON-FORBIDDEN\'s',
     !has(s2, 'H-OUTCOME-REASON-JOINT') && s2.summary.jointScopeRows === 0);
  const s3 = one(tree({ format: 'blocktracer/chain-snapshot@1',
                        rows: [{ txHash: '0xq', blockNumber: 1, txIndexInBlock: 0,
                                 outcome: 'pruned', reason: 'a sentence' }] }));
  ck('scope: an untraced row with NO reason is S5-REFUSALREASON-REQUIRED\'s',
     !has(s3, 'H-OUTCOME-REASON-JOINT') && s3.summary.jointScopeRows === 0);
  ck('anti-vacuity: an empty scope is reported NOT RUN, not passed',
     s3.checkStatus['H-OUTCOME-REASON-JOINT'].ran === false
     && s3.summary.checksNotRun.includes('H-OUTCOME-REASON-JOINT'));

  // ── THE TABLE IS DERIVED, AND THE CORPUS IS THE EVIDENCE ────────────────────────────
  //
  // Every pair the committed corpus actually carries must be admissible. This is the arm
  // that would have caught a table written from the outcome names: it reddens on 912 rows.
  const corpus = sweep(corpusSnapshotDirs(), { registry: REG });
  const jointFindings = corpus.findings.filter((f) => f.check === 'H-OUTCOME-REASON-JOINT');
  ck(`control: every one of the corpus's ${corpus.corpus.totals.jointScopeRows} in-scope `
     + `row(s) carries an admissible pair — ${jointFindings.length} finding(s)`,
     jointFindings.length === 0);
  ck('control: …over a scope that is not empty, so the zero is a measurement',
     corpus.corpus.totals.jointScopeRows > 900);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§5 — H-RECORDER-UNATTRIBUTED: a defect has to be pinnable to a build');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  const rec = (over = {}) => ({ txHash: '0xr1', blockNumber: 1, txIndexInBlock: 0,
                                outcome: 'replayed', container: 'ct/0xr1.ct', containerBytes: 8,
                                recording: { steps: 1, sourceLevel: true }, ...over });

  const t1 = one(tree({ rows: [rec()], containers: ['0xr1.ct'] }));
  ck('twin: a row reaching provenance.runtimeCommit raises nothing',
     !has(t1, 'H-RECORDER-UNATTRIBUTED')
     && t1.rows[0].attributedBy === 'provenance.runtimeCommit');

  const t2 = one(tree({ rows: [rec({ recordedBy: 'b'.repeat(40) })],
                        provenance: { runtimeCommit: undefined },
                        containers: ['0xr1.ct'] }));
  ck('twin: a row with its OWN recordedBy and no snapshot-wide commit raises nothing',
     !has(t2, 'H-RECORDER-UNATTRIBUTED') && t2.rows[0].attributedBy === 'recordedBy');

  const m1 = one(tree({ rows: [rec()], provenance: { runtimeCommit: undefined },
                        containers: ['0xr1.ct'] }));
  bite('mutation: a row reaching neither raises H-RECORDER-UNATTRIBUTED, naming the row',
       has(m1, 'H-RECORDER-UNATTRIBUTED')
       && m1.findings.find((x) => x.check === 'H-RECORDER-UNATTRIBUTED').txHash === '0xr1');
  bite('mutation: …and the summary counts it rather than only narrating it',
       m1.summary.unattributedRows === 1 && m1.summary.attributedRows === 0);

  // SCOPE: a row with no container is a row with no recording to attribute.
  const s1 = one(tree({ rows: [{ txHash: '0xn', blockNumber: 1, txIndexInBlock: 0,
                                 outcome: 'pruned', refusalReason: 'not-attempted',
                                 reason: 'x' }],
                        provenance: { runtimeCommit: undefined } }));
  ck('scope: a row naming no container is out of scope, and the check reports NOT RUN',
     !has(s1, 'H-RECORDER-UNATTRIBUTED')
     && s1.checkStatus['H-RECORDER-UNATTRIBUTED'].ran === false);

  // THE REAL READING. The corpus carries exactly one such row, and this arm is what makes
  // that a number rather than a sentence.
  const corpus = sweep(corpusSnapshotDirs(), { registry: REG });
  ck(`control: over the committed corpus, ${corpus.corpus.totals.unattributedRows} of `
     + `${corpus.corpus.totals.containersNamed} container-naming row(s) are unattributed`,
     corpus.corpus.totals.containersNamed > 0
     && corpus.corpus.totals.attributedRows + corpus.corpus.totals.unattributedRows
        === corpus.corpus.totals.containersNamed);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§6 — the accounting, the artifact and the CLI');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  const rows = Array.from({ length: 7 }, (_, i) => ({
    txHash: `0x${i}`, blockNumber: 1, txIndexInBlock: i, outcome: 'pruned',
    refusalReason: 'not-attempted', reason: 'x' }));
  const r = one(tree({ rows }));
  ck('rowsExamined is the number of rows, not the number the checks happened to look at',
     r.summary.rowsExamined === 7 && r.rows.length === 7);

  // THE FOUR FIGURES ARE ASSERTED OVER EVERY SUMMARY, ENUMERATED. Naming one snapshot here
  // would be a claim about the snapshot somebody typed.
  const corpus = sweep(corpusSnapshotDirs(), { registry: REG });
  const FIGURES = ['rowsExamined', 'containersOpened', 'containersRefused', 'checksNotRun'];
  ck(`every snapshot summary publishes ${FIGURES.join(', ')} — over `
     + `${corpus.snapshots.length} tree(s)`,
     corpus.snapshots.length > 0
     && corpus.snapshots.every((s) => FIGURES.every((k) =>
          Object.prototype.hasOwnProperty.call(s.summary, k))));
  ck('…and the corpus roll-up publishes them too',
     FIGURES.every((k) => Object.prototype.hasOwnProperty.call(corpus.corpus.totals, k)));
  // EVERY DECLARED CHECK IS ACCOUNTED FOR IN THE COVERAGE TABLE. Enumerated from the
  // registry, so a finding added tomorrow is covered or this arm goes red (trap 35).
  ck('every declared check appears in the corpus coverage table',
     Object.keys(REG.checks).every((id) =>
       Object.prototype.hasOwnProperty.call(corpus.corpus.checkCoverage, id)));
  ck('…and a check that ran in some trees and not others is not called "not run" wholesale',
     corpus.corpus.totals.checksNotRun.every((id) => corpus.corpus.checkCoverage[id].ranIn === 0));
  ck('the roll-up accounts for every row in every tree',
     corpus.corpus.totals.rowsExamined
       === corpus.snapshots.reduce((a, s) => a + s.summary.rowsExamined, 0));
  ck('…and every row falls in exactly one outcome population',
     corpus.corpus.totals.tracedRows + corpus.corpus.totals.untracedRows
       + corpus.corpus.totals.chainAbsentRows + corpus.corpus.totals.unclassifiedRows
       === corpus.corpus.totals.rowsExamined);

  // THE ARTIFACT IS JSON. `render` prints a row record on one line so a thousand-row diff is
  // readable; that must not make it a different document.
  const back = JSON.parse(render(corpus));
  ck('the rendered artifact parses back to the same report',
     JSON.stringify(back) === JSON.stringify(corpus));
  ck('…and its rows are one per line, which is what makes it diffable',
     render(corpus).split('\n').filter((l) => l.trim().startsWith('{"txHash"')).length
       === corpus.corpus.totals.rowsExamined);
  ck('the artifact declares its format', corpus.format === 'blocktracer/chain-health@1');

  // THE TWO CARRIED FACTS REACH A READER.
  ck('the artifact carries the two measured facts that bound what it can claim',
     Array.isArray(corpus.carried) && corpus.carried.length === 2
     && corpus.carried.every((c) => c.note.length > 100 && c.measuredOn && c.bounds));
  const V = verdict(corpus, REG).join('\n');
  ck('…and the human verdict states both where a reader will meet them',
     /meta.dat` schema version 3|meta\.dat. schema version 3/.test(V)
     && /exits 0/.test(V));

  // THE CLI'S OWN GUARDS.
  const noArgs = run(['--quiet']);
  ck('the CLI with no subject prints usage and exits 2', noArgs.rc === 2
     && /usage:/.test(noArgs.err));
  const badCheck = run([join(REPO_ROOT, 'conformance-kit', 'template', 'complete'),
                        '--check', 'H-NOT-A-CHECK', '--quiet']);
  bite('a requested finding that does not exist is a failure, not an empty selection',
       badCheck.rc === 2 && /no such finding/.test(badCheck.err));
  const badDir = run([join(tmp, 'nothing-here'), '--quiet']);
  ck('a directory with no snapshot.json is refused by name', badDir.rc === 2
     && /holds no snapshot.json/.test(badDir.err));

  // THE CORPUS ENUMERATION SEES AN UNTRACKED TREE. A subject list built from `git ls-files`
  // alone is a claim about the tree's HISTORY, so a snapshot added by the change being
  // measured would not be in it (trap 32d). This arm plants one and requires it to appear.
  const planted = PROBE;
  try {
    mkdirSync(planted, { recursive: true });
    writeFileSync(join(planted, 'snapshot.json'), JSON.stringify({
      format: 'blocktracer/chain-snapshot@2',
      provenance: { chain: 'probe' }, transactions: [] }));
    const dirs = corpusSnapshotDirs();
    bite('an UNTRACKED snapshot tree is in the corpus enumeration — git ls-files alone is not',
         dirs.some((d) => d.endsWith('.health-selftest-probe')));
  } finally {
    rmSync(planted, { recursive: true, force: true });
  }
  ck('…and the probe is gone again, so the enumeration is back to the committed corpus',
     !corpusSnapshotDirs().some((d) => d.endsWith('.health-selftest-probe')));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§7 — the registry\'s own shape, so a table cannot name a token nothing defines');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  const ids = Object.keys(REG.checks);
  ck('every declared check states its question, its healthy answer and needsContainer',
     ids.length > 0 && ids.every((id) => {
       const c = REG.checks[id];
       return typeof c.question === 'string' && c.question.length > 20
           && typeof c.healthy === 'string' && c.healthy.length > 20
           && typeof c.needsContainer === 'boolean'
           && ['unhealthy', 'not-measured'].includes(c.kind);
     }));
  ck('a check that is not implemented says why, and one that is does not need to',
     ids.every((id) => REG.checks[id].implemented !== false
                    || (REG.checks[id].notRunReason ?? '').length > 40));

  // THE ADMISSIBLE PAIRS MAY ONLY NAME TOKENS THE CLOSED SETS DEFINE. Both sides are read
  // from the files that own them — the outcome partition from `snapshot-format.json` and the
  // reasons from `refusal-reasons.json`, through `lib/refusal.mjs` — so this table cannot
  // become a third declaration of either set.
  const pairs = REG.admissibleOutcomeReasonPairs;
  ck(`the admissible table is not empty — ${pairs.length} pair(s)`, pairs.length > 0);
  ck('every admissible pair\'s outcome is in the format file\'s UNTRACED set',
     pairs.every((p) => UNTRACED_OUTCOMES.includes(p.outcome)));
  ck('every admissible pair\'s reason is a member of the closed refusal set',
     pairs.every((p) => REFUSAL_REASON_IDS.includes(p.refusalReason)));
  ck('no admissible pair names a traced or chain-absent outcome, which are out of scope',
     pairs.every((p) => !TRACED_OUTCOMES.includes(p.outcome)
                     && !CHAIN_ABSENT_OUTCOMES.includes(p.outcome)));
  ck('every pair states WHO writes it and WHY it is admissible — an arbitrary table is a '
     + 'fifth place for a rule to drift',
     pairs.every((p) => (p.statedBy ?? '').length > 10 && (p.justification ?? '').length > 60));
  ck('no pair is declared twice',
     new Set(pairs.map((p) => `${p.outcome} ${p.refusalReason}`)).size === pairs.length);
  ck('every reason-member joint names a member of the closed refusal set, with its reasoning',
     REG.reasonMemberJoints.length > 0
     && REG.reasonMemberJoints.every((j) => REFUSAL_REASON_IDS.includes(j.refusalReason)
                                         && (j.justification ?? '').length > 60
                                         && (j.statedBy ?? '').length > 10));

  // EVERY UNTRACED OUTCOME THE FORMAT DEFINES HAS AT LEAST ONE ADMISSIBLE PARTNER. An
  // outcome with none is an outcome every row of which this finding would flag — a check
  // that fires on everything measures nothing, and the table would be the bug.
  const covered = new Set(pairs.map((p) => p.outcome));
  ck(`every untraced outcome has at least one admissible reason — `
     + `[${UNTRACED_OUTCOMES.join(', ')}]`,
     UNTRACED_OUTCOMES.every((o) => covered.has(o)));

  // MUTATION: a pair naming a reason outside the closed set must be refused.
  const mutPairs = [...pairs, { outcome: 'pruned', refusalReason: 'absent',
                                statedBy: 'planted', justification: 'planted' }];
  bite('mutation: an admissible pair naming a non-member reason is refused',
       !mutPairs.every((p) => REFUSAL_REASON_IDS.includes(p.refusalReason)));
  bite('mutation: an admissible pair naming a TRACED outcome is refused',
       ![...pairs, { outcome: 'replayed', refusalReason: 'runtime-refused' }]
         .every((p) => UNTRACED_OUTCOMES.includes(p.outcome)));
}

cleanup();
console.error('');
if (asserted !== 90) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 90 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('PASS — every finding has a twin it must not fire on and a mutation it must');
