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

import { mkdtempSync, writeFileSync, rmSync, mkdirSync, readFileSync, existsSync, cpSync }
  from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import {
  healthChecks, healthCheckIds, contractRuleIds, corpusSnapshotDirs,
  examineSnapshot, sweep, render, verdict, readerBuildId, modeFlagInCallerArgv,
  compareToReading, COMMITTED_READING_PATH, HEALTH_CHECKS_PATH, REPO_ROOT,
} from './chain-health.mjs';
import { REFUSAL_REASON_IDS, UNTRACED_OUTCOMES, TRACED_OUTCOMES, CHAIN_ABSENT_OUTCOMES }
  from './lib/refusal.mjs';
import { POSITION_STREAM_SCHEMA } from './lib/producer-facts.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, 'chain-health.mjs');

// THE CONFORMANCE BINARY, IF ONE IS BUILT. §9's load-bearing control is that `conformance`
// stays GREEN over the same mutated tree the health sweep reddens on — which is what makes
// these findings coverage the contract does not have rather than a second copy of an `S5-*`
// rule. `just conformance` compiles it on every run and this suite must not compile anything,
// so it uses a build if one is on disk and RECORDS its absence otherwise. A control that did
// not run is reported as not run; it is never counted as having passed.
const CONFORMANCE = join(REPO_ROOT, 'src', 'blocktracer_conformance');
const CONFORMANCE_BUILT = existsSync(CONFORMANCE);

let asserted = 0, failed = 0;

// ── TWO COUNTERS, AND THE REASON IS THAT ONE BLOCK OF ARMS NEEDS A BINARY CI HAS NOT GOT ──
//
// The container-versus-claim arms need the REAL reader, because their whole subject is whether
// a container's own measurements match a row's claim about them — drive that with a stand-in
// and the check is asserting that the stub agrees with the stub. `ct-print` is not a dependency
// of this repository and is not built in CI.
//
// A single declared total would therefore be TWO different numbers depending on the host, and a
// suite whose declared count is unreproducible is a suite whose count checks nothing: the
// `chain-selftest` header, the recipe body and the CI step comments all cross-check it, and all
// three would have to name whichever host the last person ran on.
//
// So the arms that need the reader increment their own counter. `asserted` is host-independent
// and is the number the three cross-check sites read; `assertedWithReader` is declared here and
// asserted only where the reader exists, and where it does not the suite PRINTS how many arms
// did not run. That is the honest shape: not a skip, a recorded absence with a figure on it.
let assertedWithReader = 0;
let readerArms = false;
const tally = () => { if (readerArms) assertedWithReader++; else asserted++; };
const ck = (label, cond) => { tally(); if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`); };
const bite = (label, cond) => { tally(); if (!cond) { failed++; console.error(`  FAIL  MUTATION DID NOT BITE  ${label}`); } else console.error(`  bite  ${label}`); };

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

const num = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : 0);
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

  // THE CARRIED FACTS REACH A READER. ENUMERATED FROM THE REGISTRY, never counted here: a
  // number typed in this file is a claim about the facts that were carried when somebody typed
  // it, and the floor is what stops an emptied list satisfying the shape test for free.
  ck(`the artifact carries every measured fact the registry carries — ${REG.carried.length}`,
     Array.isArray(corpus.carried) && corpus.carried.length === REG.carried.length);
  ck(`…and there are at least three of them, so an emptied list cannot pass the shape test `
     + `below for free — ${REG.carried.length}`, REG.carried.length >= 3);
  ck('…and each states its note, the date it was measured and what it bounds',
     corpus.carried.every((c) => c.note.length > 100 && c.measuredOn && c.bounds));
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

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§8 — the container opens, or it does not, and the reader is identified rather than blamed');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  const row = (over = {}) => ({
    txHash: '0xc1', blockNumber: 1, txIndexInBlock: 0, outcome: 'replayed',
    container: 'ct/0xc1.ct', containerBytes: 8,
    recording: { steps: 1, sourceLevel: true, stepsPositioned: 1 },
    sourceBundles: 'text/0xc1.json', ...over,
  });
  const dir = tree({ rows: [row()], containers: ['0xc1.ct'] });

  /** A stand-in reader. The probes append the mode, so a stub that ignores argv is exactly
   *  what the seam invokes; what the reader IS is not this suite's subject, that it is ASKED
   *  and that its ANSWER reaches the finding is. */
  const stub = (body) => {
    const p = join(tmp, `r${treeN++}.mjs`);
    writeFileSync(p, body);
    return `${process.execPath} ${p}`;
  };
  // A reader that opens: a `--meta-json` document with counts, which is what the real one
  // prints on a container it accepts.
  const OPENS = stub('process.stdout.write(JSON.stringify({metadata:{program:"p"},'
    + 'counts:{steps:1,calls:1,values:1,io_events:0,paths:1,functions:1,types:1,varnames:1}})'
    + '+"\\n");\n');
  // A reader that refuses the way the real one refuses this corpus — the sentence, and the
  // schema version inside it, copied from the measured output rather than invented.
  const refusesAt = (v) => stub('process.stderr.write("Error: meta.dat present but corrupt: '
    + `meta.dat: schema version ${v} predates the global line index correction, and this trace `
    + 'cannot be read.\\n"); process.exit(1);\n');
  const REFUSES_V3 = refusesAt(3);
  const REFUSES_V4 = refusesAt(4);
  // A refusal that names NO version — the shape the conformance template's ASCII placeholders
  // produce ("not a recognised .ct file"), which is a different measurement from v3.
  const REFUSES_NAMELESS = stub(
    'process.stderr.write("ct-print: not a recognised .ct file: no CTFS magic\\n");'
    + ' process.exit(1);\n');

  // ── CONTROL: a container that opens raises nothing, and the check RAN ────────────────
  const ok = run([dir, '--container-reader', OPENS, '--quiet']);
  const okRep = JSON.parse(ok.out);
  ck('control: a container the reader opens raises no H-CONTAINER-UNREADABLE',
     !has(okRep, 'H-CONTAINER-UNREADABLE'));
  ck('control: …and the check RAN over a scope of 1, rather than being skipped',
     okRep.snapshots[0].checkStatus['H-CONTAINER-UNREADABLE'].ran === true
     && okRep.snapshots[0].checkStatus['H-CONTAINER-UNREADABLE'].scope === 1);
  ck('control: …and the artifact names the build that answered, by its own bytes',
     /^[0-9a-f]{64}$/.test(okRep.containerReaderBuild?.sha256 ?? '')
     && okRep.containerReaderBuild.bytes > 0);

  // ── MUTATION: the same tree, a reader that refuses it by name ────────────────────────
  const m3 = run([dir, '--container-reader', REFUSES_V3, '--quiet']);
  const m3Rep = JSON.parse(m3.out);
  const f3 = m3Rep.findings.find((x) => x.check === 'H-CONTAINER-UNREADABLE');
  bite('mutation: a reader that refuses the container raises H-CONTAINER-UNREADABLE',
       f3 !== undefined && f3.txHash === '0xc1');
  bite('mutation: …and the finding keeps the reader\'s OWN sentence, so the refusal has a reason',
       /schema version 3 predates the global line index correction/.test(f3.readerSaid));
  bite('mutation: …and names the build that refused, so the refusal is reproducible',
       /^[0-9a-f]{64}$/.test(f3.readerBuildId?.sha256 ?? ''));
  bite('mutation: …and states the version THE CONTAINER declared, out of the refusal',
       f3.declaredSchemaVersion === 3 && m3Rep.corpus.totals.containerSchemaCensus['3'] === 1);
  // THE ARM THIS WHOLE FINDING EXISTS FOR. Over the real corpus the refusal is unanimous, so a
  // sentence that blamed the reader would read as a broken tool once per row. The finding must
  // name the CONTAINER'S property as the defect and the reader as the witness.
  bite('mutation: …and its sentence names the CONTAINER as the defect, not the reader — it says '
     + 'the container declares a version the reader does not accept and refused BY NAME',
       /this container declares meta\.dat schema version 3/.test(f3.says)
       && /refused the container BY NAME/.test(f3.says)
       && /a fact about the recording and not a reader failure/.test(f3.says));

  // A REFUSAL THAT NAMES NO VERSION IS A DIFFERENT MEASUREMENT, and must not be recorded as a
  // version. `unstated` is its own census key for exactly this reason.
  const mn = JSON.parse(run([dir, '--container-reader', REFUSES_NAMELESS, '--quiet']).out);
  const fn = mn.findings.find((x) => x.check === 'H-CONTAINER-UNREADABLE');
  bite('mutation: a refusal naming no version is counted `unstated`, never as a version',
       mn.corpus.totals.containerSchemaCensus.unstated === 1
       && mn.corpus.totals.containerSchemaCensus['3'] === undefined
       && fn.declaredSchemaVersion === null);
  bite('mutation: …and its sentence says only what the reader said, claiming nothing more',
       /named no schema version/.test(fn.says) && /not a recognised \.ct file/.test(fn.says));

  // ── THE ABSENT CONTAINER: a row naming a file nobody has ────────────────────────────
  const gone = tree({ rows: [row()], containers: [] });
  const mg = JSON.parse(run([gone, '--container-reader', OPENS, '--quiet']).out);
  const fg = mg.findings.find((x) => x.check === 'H-CONTAINER-UNREADABLE');
  bite('mutation: a row naming a container that is not on disk raises the finding by name',
       fg !== undefined && /no such file is on disk/.test(fg.says)
       && mg.corpus.totals.containersRefused === 1);

  // ── PREMISE: WITH NO READER THE CHECK IS NOT RUN, AND FOR ITS OWN REASON ────────────
  //
  // A negative assertion is satisfied when its premise does not hold, so the premise is
  // asserted in the same arm: the check did not merely raise nothing, it was never asked, and
  // its reason must be the INVOCATION's rather than the tree's. "The scope is empty" is a fact
  // about the tree and would be the wrong sentence here.
  const nr = JSON.parse(run([dir, '--quiet']).out);
  ck('premise: with no reader named, H-CONTAINER-UNREADABLE is NOT RUN',
     nr.snapshots[0].checkStatus['H-CONTAINER-UNREADABLE'].ran === false
     && !has(nr, 'H-CONTAINER-UNREADABLE'));
  ck('premise: …and its reason is the INVOCATION\'s, not "the scope is empty"',
     /No container reader was named/.test(nr.snapshots[0].checkStatus['H-CONTAINER-UNREADABLE'].why)
     && !/scope is empty/.test(nr.snapshots[0].checkStatus['H-CONTAINER-UNREADABLE'].why));
  ck('premise: …and the schema census is empty rather than absent, so a zero is readable',
     JSON.stringify(nr.corpus.totals.containerSchemaCensus) === '{}');
  ck('premise: …and the artifact carries no build id, because no reader answered',
     nr.containerReaderBuild === null);

  // ── THE BUILD ID IS THE READER'S OWN BYTES, AND A FAILURE TO GET IT IS REPORTED ─────
  const realId = readerBuildId(join(REPO_ROOT, 'tools', 'chain', 'chain-health.mjs'));
  ck('the build id is a sha256 of the program\'s own bytes plus its size',
     /^[0-9a-f]{64}$/.test(realId.sha256) && realId.bytes > 1000);
  const noId = readerBuildId(join(tmp, 'no-such-reader'));
  bite('mutation: a reader whose bytes cannot be read reports sha256 null WITH the reason, '
     + 'never an absent field', noId.sha256 === null && 'sha256' in noId
       && (noId.why ?? '').length > 20);

  // ── H-CONTAINER-SCHEMA-SKEW: TWO CONSUMERS, TWO ANSWERS, NEITHER A COPY ─────────────
  //
  // This is the pair that proves the arms are independent. The SAME tree, probed by two
  // readers that differ only in the version they name, must move the two consumers in
  // OPPOSITE directions — and if one finding covered both consumers, one of these two arms
  // could not be written.
  const CONS = REG.containerSchema.consumers;
  ck(`the registry declares more than one consumer, so "per consumer" is not one consumer — `
     + `[${CONS.map((c) => c.id).join(', ')}]`, CONS.length >= 2);
  ck('…and every consumer states a non-empty accepted set, what it is, who it is for, the '
     + 'constant it was read from and the revision it was read at',
     CONS.every((c) => Array.isArray(c.accepts) && c.accepts.length > 0
       && c.accepts.every((v) => Number.isInteger(v))
       && (c.what ?? '').length > 20 && (c.audience ?? '').length > 20
       && (c.statedBy ?? '').length > 30 && (c.readFrom?.revision ?? '').length > 6
       && (c.readFrom?.on ?? '').length === 10));
  // ANTI-VACUITY ON THE TABLE ITSELF: if the two consumers accepted the same set the finding
  // could never distinguish them and the whole per-consumer design would be decoration.
  ck('…and no two consumers accept the same set, or the per-consumer split measures nothing',
     new Set(CONS.map((c) => [...c.accepts].sort().join(','))).size === CONS.length);

  const skewOf = (rep) => rep.findings.filter((f) => f.check === 'H-CONTAINER-SCHEMA-SKEW')
    .map((f) => `${f.consumer}@v${f.declaredSchemaVersion}`).sort();
  const s3 = skewOf(m3Rep);
  bite('mutation: a container declaring v3 skews the PINNED READER, which accepts [4, 5]',
       s3.includes('pinned-reader@v3'));
  bite('mutation: …and does NOT skew the shipped engine, which accepts [3] — so the two arms '
     + 'are not one finding wearing two names', !s3.includes('shipped-engine@v3'));
  const m4Rep = JSON.parse(run([dir, '--container-reader', REFUSES_V4, '--quiet']).out);
  const s4 = skewOf(m4Rep);
  bite('mutation: the SAME tree declaring v4 instead skews the shipped engine',
       s4.includes('shipped-engine@v4'));
  bite('mutation: …and no longer skews the pinned reader — the pair moves in opposite '
     + 'directions, which one combined verdict could not report',
       !s4.includes('pinned-reader@v4'));
  const f4 = m4Rep.findings.find((x) => x.check === 'H-CONTAINER-SCHEMA-SKEW');
  bite('mutation: …and the skew finding names the consumer, its accepted set, the count of '
     + 'containers and the constant the set was read from',
       f4.consumer === 'shipped-engine' && f4.containers === 1
       && JSON.stringify(f4.accepts) === JSON.stringify([3])
       && /SUPPORTED_VERSIONS/.test(f4.statedBy) && f4.readFrom.revision.length > 6);
  bite('mutation: …and says whether that consumer refuses the version BY NAME or will attempt '
     + 'the decode, because those are different outcomes for an operator',
       /does NOT refuse 4 by name, so it will attempt the decode/.test(f4.says));
  const f3s = m3Rep.findings.find((x) => x.check === 'H-CONTAINER-SCHEMA-SKEW');
  bite('mutation: …and the by-name case says so instead', f3s.refusesByName === true
       && /refuses 3 BY NAME, so it will decline rather than mis-read/.test(f3s.says));

  // ── THREE REASONS REACH NOT RUN, AND EACH MUST SAY WHICH IT IS ──────────────────────
  //
  // A reader was NAMED here and the container was PROBED and REFUSED. So a check that needs
  // the recording to open is unanswered — but not for the reason an empty tree is unanswered,
  // and not for the reason a missing reader is. All three print NOT RUN, and collapsing them
  // is how "we could not look" comes to read like "there was nothing to see".
  //
  // This arm exists because the branch that distinguishes them was INERT: disabling it left
  // the whole suite green, because the arms above assert only that the check did not run and
  // that it is listed, which the empty-scope branch below it satisfies just as well. Measured:
  // nine control plants over this section, eight turned it red and this one did not.
  const needOpenedIds = Object.keys(REG.checks)
    .filter((id) => REG.checks[id].needsOpenedContainer === true);
  ck(`the registry declares ${needOpenedIds.length} check(s) that need the recording to OPEN, `
     + `so this arm has a subject — [${needOpenedIds.join(', ')}]`, needOpenedIds.length >= 5);
  const refusedStatus = m3Rep.snapshots[0].checkStatus;
  bite('a check needing an OPENED recording, over a tree whose container was probed and '
     + 'REFUSED, gives the reader-shaped reason and names how many were probed',
       needOpenedIds.every((id) => refusedStatus[id]?.ran === false
         && /A reader was named and 1 container\(s\) were probed; none opened\./
              .test(refusedStatus[id].why)));
  bite('…and never "the scope is empty", which is a statement about the TREE and would be the '
     + 'wrong sentence for a tree that has exactly the row the check wants',
       needOpenedIds.every((id) => !/scope is empty/.test(refusedStatus[id].why)));
  ck('…while the no-reader case keeps its own third reason, so all three are distinguishable',
     needOpenedIds.every((id) => /No container was opened/.test(nr.snapshots[0].checkStatus[id].why)
       && !/were probed/.test(nr.snapshots[0].checkStatus[id].why)));

  // AN UNSTATED VERSION IS NOT A SKEW, AND THE CHECK REPORTS NOT RUN RATHER THAN PASSED.
  ck('anti-vacuity: a probed container that stated no version leaves the skew check NOT RUN, '
     + 'never passed',
     mn.snapshots[0].checkStatus['H-CONTAINER-SCHEMA-SKEW'].ran === false
     && mn.snapshots[0].summary.checksNotRun.includes('H-CONTAINER-SCHEMA-SKEW')
     && !has(mn, 'H-CONTAINER-SCHEMA-SKEW'));

  // ── THE ENGINE PIN FORCES A RE-READ. ────────────────────────────────────────────────
  //
  // The shipped engine's accepted set is a constant in ANOTHER repository, transcribed here.
  // Transcriptions rot, and this file's own `carried` records one that did. The only thing
  // that makes a re-read unavoidable is tying the entry to something in THIS repository that
  // changes when the engine changes — and `engine-pin.txt` asserts the engine's sha256 on
  // every fetch, so a new engine means a new pin means this arm goes red.
  const pinText = readFileSync(join(REPO_ROOT, 'client', 'hydrate', 'engine-pin.txt'), 'utf8');
  const wasmPin = pinText.split('\n').map((l) => l.trim())
    .filter((l) => l && !l.startsWith('#'))
    .map((l) => l.split(/\s+/))
    .find((c) => c[0] === 'pkg/db_backend_bg.wasm')?.[2] ?? null;
  ck('control: the engine pin file yields the wasm\'s sha256, so the comparison below is not '
     + 'two nulls being equal', /^[0-9a-f]{64}$/.test(wasmPin ?? ''));
  const engine = CONS.find((c) => c.id === 'shipped-engine');
  ck('control: the shipped-engine entry exists and records the pin it was read against',
     engine !== undefined && /^[0-9a-f]{64}$/.test(engine.readFrom?.pin ?? ''));
  ck('the shipped engine\'s accepted set was read against the engine this repository PINS — a '
     + 're-pin therefore cannot land without re-reading the constant',
     engine.readFrom.pin === wasmPin);
  bite('mutation: a pin that moved makes that arm red rather than silently stale',
       engine.readFrom.pin !== `${wasmPin.slice(0, 63)}${wasmPin[63] === '0' ? '1' : '0'}`);

  // ── THE CALLER MUST NOT PASS A MODE FLAG ────────────────────────────────────────────
  //
  // The probes append their own mode. `--meta-json --events <path>` leaves the reader printing
  // one shape and this tool parsing another, while the exit status, the refusal signature and
  // the container path all look right. A silent wrong answer.
  const withMode = run([dir, '--container-reader', `${OPENS} --meta-json`, '--quiet']);
  bite('a caller that passes a reader MODE flag is refused by name, with the flag quoted',
       withMode.rc === 2 && /must name the PROGRAM and not a mode/.test(withMode.err)
       && /"--meta-json"/.test(withMode.err));
  ck('control: the same reader without the flag runs, so the refusal is about the flag',
     ok.rc === 0 || ok.rc === 3);
  const banned = REG.containerReader.callerMustNotPassAModeFlag.flags;
  ck(`the banned mode set is not empty and covers every mode the probes use — `
     + `[${banned.join(' ')}]`,
     banned.length > 0
     && Object.values(REG.containerReader.probes).filter((p) => p && p.argv)
          .every((p) => p.argv.every((a) => banned.includes(a))));
  bite('mutation: a mode flag the ban does not list is NOT refused, so the list is what bites',
       modeFlagInCallerArgv(['prog', '--not-a-mode'], REG.containerReader) === null
       && modeFlagInCallerArgv(['prog', banned[0]], REG.containerReader) === banned[0]);

  // ── THE REAL CORPUS, WITHOUT A READER — which is how this suite runs everywhere ─────
  //
  // `ct-print` is not built in CI and is not a dependency of this repository, so this suite
  // never assumes it. What it CAN assert over the real trees is that the container half
  // reports itself unanswered rather than passed, with its own reason, on every tree.
  const real = sweep(corpusSnapshotDirs(), { registry: REG });
  const needsC = Object.keys(REG.checks).filter((id) => REG.checks[id].needsContainer === true);
  ck(`control: the registry declares ${needsC.length} container check(s), so the sweep below is `
     + `not vacuous — [${needsC.join(', ')}]`, needsC.length >= 2);
  ck('over the real corpus with no reader, every container check reports NOT RUN in every tree '
     + 'and is nowhere reported as having run',
     real.snapshots.length > 0
     && needsC.every((id) => real.snapshots.every((s) => s.checkStatus[id]?.ran === false))
     && needsC.every((id) => real.corpus.totals.checksNotRun.includes(id)));
  ck('…and the human verdict states the container half as NOT MEASURED, naming both checks',
     needsC.every((id) => verdict(real, REG).join('\n').includes(id)));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§9 — the container against the claim, over the one recording a reader can open');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  // THE SUBJECT IS A REAL CONTAINER AND A REAL READER, and that is the whole reason this
  // section is different from every other one here. Everything above drives synthetic trees
  // with stand-in readers, which is right for accounting rules. A comparison between a
  // container's own measurements and a row's claim about them cannot be driven that way: the
  // claim would be compared to a number this suite typed, and the check would be asserting
  // that the stub agrees with the stub.
  //
  // So the subject is `fixtures/chain-health/readable-container`, whose MAKING.md states what
  // it is and what it is NOT, and the reader is the real one. And because that reader is not a
  // dependency of this repository and is not built in CI, the section HAS TO handle its
  // absence — which it does by asserting the tool reports NOT RUN with the right reason, and by
  // asserting, in that same arm, that the reason is the reader's absence and nothing else.
  // Skipping silently is what a suite does when it has been told to be green.
  const SUBJECT = join(REPO_ROOT, 'fixtures', 'chain-health', 'readable-container');
  const READER = join(REPO_ROOT, '..', 'codetracer-trace-format-nim', 'ct-print');
  const haveReader = existsSync(READER);
  console.error(`  (the real reader is ${haveReader ? 'present' : 'ABSENT'} at ${READER})`);

  // ── WHAT THE SUBJECT DECLARES, ASSERTED HERE SO ITS MAKING.md CANNOT DRIFT FROM IT ──
  //
  // Read from the committed snapshot, not typed: the figures below are what the checks compare,
  // and a suite that typed them would be checking itself.
  const snap = JSON.parse(readFileSync(join(SUBJECT, 'snapshot.json'), 'utf8'));
  const subjectRow = snap.transactions[0];
  const rec = subjectRow.recording;
  ck('the readable-container subject is committed, is one traced row, and names a container',
     snap.transactions.length === 1 && subjectRow.outcome === 'replayed'
     && typeof subjectRow.container === 'string'
     && existsSync(join(SUBJECT, subjectRow.container)));
  ck(`…and it declares every claim member the agreements name — `
     + `steps ${rec.steps}, events ${rec.events}, callsOpened ${rec.callsOpened}`,
     REG.containerClaimAgreements.agreements.every((a) =>
       typeof rec[a.claim.replace(/^recording\./, '')] === 'number'));
  ck('…and it is source level, names a source bundle and names a positions sidecar, so the '
     + 'source-side checks have a subject too',
     rec.sourceLevel === true
     && existsSync(join(SUBJECT, subjectRow.sourceBundles))
     && existsSync(join(SUBJECT, subjectRow.positions)));

  // ── THE AGREEMENT TABLE'S OWN SHAPE ────────────────────────────────────────────────
  const AG = REG.containerClaimAgreements.agreements;
  ck(`the agreement table is not empty — ${AG.length} agreement(s)`, AG.length >= 3);
  ck('every agreement names one claim member, one container count, an integer offset, who '
     + 'states the relation and why',
     AG.every((a) => /^recording\.[a-zA-Z]+$/.test(a.claim)
       && typeof a.containerCount === 'string' && a.containerCount.length > 0
       && Number.isInteger(a.containerEqualsClaimPlus)
       && (a.statedBy ?? '').length > 30 && (a.justification ?? '').length > 60));
  ck('every agreement id is a declared check, and every check declaring an agreement has one '
     + '— so neither table can name a row the other does not',
     AG.every((a) => REG.checks[a.id]?.agreement === a.id)
     && Object.keys(REG.checks).filter((id) => REG.checks[id].agreement)
          .every((id) => AG.some((a) => a.id === id)));
  ck('no two agreements check the same claim member, or one finding would cover two and '
     + 'neither could be told from the other in a log',
     new Set(AG.map((a) => a.claim)).size === AG.length);
  // THE OFFSET IS THE ONE THING THAT CANNOT BE GUESSED, so at least one must be non-zero —
  // a table of all-equal relations would make the offset machinery decoration, and the
  // `callsOpened + 1` relation is precisely the fact a reader of the corpus gets wrong.
  ck(`at least one agreement carries a non-zero offset, so the relation is not always equality `
     + `— [${AG.map((a) => `${a.claim}+${a.containerEqualsClaimPlus}`).join(', ')}]`,
     AG.some((a) => a.containerEqualsClaimPlus !== 0));

  if (!haveReader) {
    // THE PREMISE IS ASSERTED IN THE SAME ARM AS THE ABSENCE. Without it this is a negative
    // assertion satisfied because nothing was looked at.
    const noR = one(SUBJECT);
    const needOpened = Object.keys(REG.checks)
      .filter((id) => REG.checks[id].needsOpenedContainer === true);
    ck(`the reader is absent, so every check needing an opened recording reports NOT RUN with `
       + `its own reason — [${needOpened.join(', ')}]`,
       needOpened.length >= 5
       && needOpened.every((id) => noR.checkStatus[id]?.ran === false)
       && needOpened.every((id) => noR.summary.checksNotRun.includes(id)));
    ck('…and none of them is reported as having raised nothing, which is how "we could not '
       + 'look" comes to read like "there was nothing to see"',
       needOpened.every((id) => noR.checkStatus[id]?.raised === undefined));
    ck(`(the container-versus-claim arms need the real reader and it is not on this host — `
       + `they are NOT RUN here, and this line is the record of that rather than a pass)`,
       true);
  } else {
    readerArms = true;
    const R = [READER];
    const base = one(SUBJECT, { readerArgv: R });
    ck('control: the subject opens under the real reader',
       base.summary.containersOpened === 1 && base.summary.containersRefused === 0);
    ck('control: …and the container states its own counts, read out of the reader\'s payload',
       base.rows[0].containerCounts.available === true
       && base.rows[0].containerCounts.steps === rec.steps
       && base.rows[0].containerCounts.calls === rec.callsOpened + 1);
    ck('control: …and every agreement check RAN over a scope of 1 and raised nothing, so the '
       + 'row and its recording agree',
       AG.every((a) => base.checkStatus[a.id].ran === true
                    && base.checkStatus[a.id].scope === 1
                    && base.checkStatus[a.id].raised === 0));

    // ── ONE MUTATION PER AGREEMENT, EACH MOVING ONE MEMBER BY ONE ────────────────────
    //
    // The mutated tree is a COPY of the committed one, so the committed subject is never
    // touched — a mutation left on disk that a later copy launders into a reference is the
    // most dangerous thing this campaign has recorded.
    const posRelEarly = subjectRow.positions;
    const copyTree = (edit) => {
      const d = join(tmp, `subj${treeN++}`);
      cpSync(SUBJECT, d, { recursive: true });
      const s = JSON.parse(readFileSync(join(d, 'snapshot.json'), 'utf8'));
      edit(s);
      writeFileSync(join(d, 'snapshot.json'), JSON.stringify(s, null, 2) + '\n');
      return d;
    };
    // ── THE MUTATION IS A *CONSISTENT* MIS-MEASUREMENT, AND THAT WAS MEASURED ────────
    //
    // The obvious mutation — bump `recording.steps` and change nothing else — does NOT keep
    // the tree conformant, and finding that out changed this control. `S5-POSITIONS-AGREE`
    // refuses a positions stream whose length differs from `recording.steps`, so on a subject
    // that carries a positions sidecar the naive bump is caught by the CONTRACT: measured, rc
    // 1, "hold 10 steps and the recording declares 11". A control built on it would have
    // proved the opposite of what it claimed.
    //
    // What the checks here actually cover is stated in their own `why`: a producer that
    // mis-measured its own recording AND DERIVED EVERY SIDECAR FROM THE MIS-MEASUREMENT is
    // conformant in every direction. So the mutation moves the claim and brings every derived
    // file with it. That tree is internally consistent, conformance is green over it, and the
    // container is the only thing left that disagrees — which is the whole argument.
    const CONSISTENTLY = {
      'recording.steps': (s) => {
        const t = s.transactions[0];
        t.recording.steps += 1;
        t.recording.stepsUnpositioned += 1;
        t.instructionsExecuted += 1;
      },
      // `callsOpened` has no derived file in this subject: it names no call trace, so nothing
      // in the tree is keyed to it and the bump alone leaves a conformant tree.
      'recording.callsOpened': (s) => { s.transactions[0].recording.callsOpened += 1; },
      // `events` is read by nothing in this repository at all — no rule, no reader, no sidecar.
      'recording.events': (s) => { s.transactions[0].recording.events += 1; },
    };
    /** The positions sidecar lengthened to match a step count that moved. */
    const growPositions = (d, by) => {
      const p = join(d, posRelEarly);
      const s = JSON.parse(readFileSync(p, 'utf8'));
      s.steps += by;
      for (const col of ['pathId', 'line', 'column']) {
        for (let i = 0; i < by; i++) s[col].push(null);
      }
      writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
    };
    for (const a of AG) {
      const member = a.claim.replace(/^recording\./, '');
      const d = copyTree(CONSISTENTLY[a.claim]);
      if (a.claim === 'recording.steps') growPositions(d, 1);
      const m = one(d, { readerArgv: R });
      const f = m.findings.find((x) => x.check === a.id);
      bite(`mutation: ${a.claim} incremented by one raises ${a.id}`, f !== undefined);
      bite(`mutation: …and the finding names BOTH figures and the member the claim came from`,
           f.claimMember === a.claim && f.claimed === rec[member] + 1
           && f.held === rec[member] + (a.containerEqualsClaimPlus ?? 0)
           && new RegExp(`row claims ${f.claimed}`).test(f.says)
           && new RegExp(`count is ${f.held}`).test(f.says));
      bite(`mutation: …and no OTHER agreement fires on it, so the finding is about ${a.claim} `
         + `and not about the row`,
           m.findings.filter((x) => AG.some((b) => b.id === x.check)).length === 1);
      // ── THE CONTROL THAT PROVES THIS ADDS COVERAGE RATHER THAN DUPLICATING IT ──────
      //
      // The whole argument for these checks is that the contract cannot reach them. An
      // assertion that the health sweep goes red is only half of it; the other half is that
      // `just conformance` over THE SAME MUTATED TREE stays green. If it did not, this would
      // be a second copy of an `S5-*` rule, which is what the disjointness arm in §1 refuses
      // at the level of ids and this refuses at the level of behaviour.
      if (CONFORMANCE_BUILT) {
        const conf = spawnSync(CONFORMANCE, ['--snapshot', d],
                               { encoding: 'utf8', timeout: 300_000 });
        bite(`control: \`conformance\` over the SAME mutated tree stays GREEN — so ${a.id} is `
           + `coverage the contract does not have, not a second copy of an S5 rule`,
             conf.status === 0 && /this tree conforms/.test(`${conf.stdout}`));
      } else {
        ck(`(the conformance binary is not built, so the "conformance stays green" control for `
           + `${a.id} did not run — recorded rather than assumed)`, true);
      }
    }

    // ── §10: THE SOURCE SIDE ────────────────────────────────────────────────────────
    console.error('\n§10 — the bundle, the positions and the container, against each other');
    ck('control: the source-side checks all RAN over the unmutated subject and raised nothing',
       ['H-PATHS-NOT-IN-BUNDLE', 'H-BUNDLE-LANGUAGE-SKEW', 'H-POSITIONS-VALUE-SKEW']
         .every((id) => base.checkStatus[id].ran === true && base.checkStatus[id].raised === 0));
    ck('control: …and the container really did state its interned paths, so the comparisons '
       + 'above were not two empty sets agreeing',
       base.rows[0].containerStream.available === true
       && base.rows[0].containerStream.paths.length >= 2
       && base.rows[0].containerStream.steps.length >= 10);

    /** A copy of the subject with one sidecar rewritten. */
    const copyWithSidecar = (rel, edit) => {
      const d = join(tmp, `subj${treeN++}`);
      cpSync(SUBJECT, d, { recursive: true });
      const p = join(d, rel);
      const s = JSON.parse(readFileSync(p, 'utf8'));
      edit(s);
      writeFileSync(p, JSON.stringify(s, null, 2) + '\n');
      return d;
    };
    const bundleRel = subjectRow.sourceBundles;
    const posRel = subjectRow.positions;

    // H-PATHS-NOT-IN-BUNDLE: drop one file from the bundle. Everything else is untouched —
    // the bundle is still present, still declares source level, still has files — so the
    // finding is about the MISSING PATH and not about a stripped bundle.
    {
      const d = copyWithSidecar(bundleRel, (b) => {
        const keys = Object.keys(b.bundles[0].files);
        delete b.bundles[0].files[keys[keys.length - 1]];
      });
      const m = one(d, { readerArgv: R });
      const f = m.findings.find((x) => x.check === 'H-PATHS-NOT-IN-BUNDLE');
      bite('mutation: a bundle missing ONE of the container\'s interned paths raises '
         + 'H-PATHS-NOT-IN-BUNDLE', f !== undefined);
      bite('mutation: …and the finding names the missing path and both totals, so a reader '
         + 'knows which file has no text rather than that one does',
           f.missing.length === 1 && /\.py$/.test(f.missing[0])
           && f.internedPaths === 2 && f.publishedFiles === 1);
      bite('mutation: …and the OTHER source checks do not fire on it — the bundle still '
         + 'declares its language and the positions are untouched',
           !has(m, 'H-BUNDLE-LANGUAGE-SKEW') && !has(m, 'H-POSITIONS-VALUE-SKEW'));
    }

    // H-BUNDLE-LANGUAGE-SKEW, axis 1: the declared language changed to another the table
    // knows, so the files are now the wrong extension for it.
    {
      const d = copyWithSidecar(bundleRel, (b) => { b.bundles[0].language = 'noir'; });
      const m = one(d, { readerArgv: R });
      const fs2 = m.findings.filter((x) => x.check === 'H-BUNDLE-LANGUAGE-SKEW');
      bite('mutation: a bundle declaring a language its own files are not written in raises '
         + 'H-BUNDLE-LANGUAGE-SKEW on the bundle-files axis',
           fs2.some((f) => f.axis === 'bundle-files' && f.language === 'noir'
                        && f.outside.includes('.py')));
      bite('mutation: …and on the positions-paths axis too, separately, because the steps are '
         + 'being positioned in files the declared language does not write',
           fs2.some((f) => f.axis === 'positions-paths' && f.outside.includes('.py')));
      bite('mutation: …and the two axes are separate findings rather than one, so a bundle '
         + 'that is wrong in one way and right in the other can be told apart',
           new Set(fs2.map((f) => f.axis)).size === 2);
    }

    // H-BUNDLE-LANGUAGE-SKEW, axis 3: a positions schema token nothing defines. This is the
    // gap `S5-POSITIONS-SCHEMA` leaves — it refuses an ABSENT token and republishes whatever
    // it is handed — so the mutation keeps a token and makes it one nobody declares.
    {
      const d = copyWithSidecar(posRel, (p) => { p.schema = 'avm-source-positions/99'; });
      const m = one(d, { readerArgv: R });
      const f = m.findings.find((x) => x.check === 'H-BUNDLE-LANGUAGE-SKEW'
                                    && x.axis === 'positions-schema');
      bite('mutation: a positions stream stating a schema token nothing defines is refused by '
         + 'name, with the defined set printed', f !== undefined
           && f.schema === 'avm-source-positions/99' && f.defined.length > 0);
      bite('mutation: …and the value skew does NOT fire on it, because the coordinates are '
         + 'unchanged — the schema axis is about the token and nothing else',
           !has(m, 'H-POSITIONS-VALUE-SKEW'));
    }

    // H-POSITIONS-VALUE-SKEW: the columns are the RIGHT LENGTH and the values are wrong. That
    // is the whole point — `S5-POSITIONS-AGREE` and `S5-POSITIONS-COLUMNS` are both about
    // length, so a stream mutated this way passes every existing rule.
    {
      const d = copyWithSidecar(posRel, (p) => {
        // Every step re-pointed at the other interned file. Same column length, same step
        // count, same paths array — only the index each step carries has moved, which is
        // exactly what an off-by-one in a path remap produces.
        p.pathId = p.pathId.map((v) => (v === 0 ? 1 : 0));
      });
      const m = one(d, { readerArgv: R });
      const f = m.findings.find((x) => x.check === 'H-POSITIONS-VALUE-SKEW');
      bite('mutation: a positions sidecar of the RIGHT LENGTH whose every step points at the '
         + 'wrong file raises H-POSITIONS-VALUE-SKEW', f !== undefined);
      bite('mutation: …and it publishes how many steps were COMPARED beside how many '
         + 'disagreed, so a comparison over nothing cannot look like a pass',
           f.stepsCompared >= 10 && f.stepsDisagreeing >= 10
           && f.stepsDisagreeing <= f.stepsCompared);
      bite('mutation: …and it carries the FIRST disagreement, both sides, because a count of '
         + 'wrong steps is not something anybody can act on',
           f.firstDisagreement.sidecar.path !== f.firstDisagreement.container.path
           && typeof f.firstDisagreement.step === 'number');
      // THE CONTROL THAT MAKES IT A VALUE CHECK AND NOT A LENGTH CHECK.
      if (CONFORMANCE_BUILT) {
        const conf = spawnSync(CONFORMANCE, ['--snapshot', d],
                               { encoding: 'utf8', timeout: 300_000 });
        bite('control: `conformance` over that same tree stays GREEN — every column is the '
           + 'right length, which is all any existing rule asks',
             conf.status === 0 && /this tree conforms/.test(`${conf.stdout}`));
      } else {
        ck('(the conformance binary is not built, so the value-versus-length control did not '
           + 'run — recorded rather than assumed)', true);
      }
      // A LINE-ONLY MUTATION, so the finding is not only reachable through the path index.
      const d2 = copyWithSidecar(posRel, (p) => { p.line = p.line.map((v) => (v === null ? null : v + 1)); });
      const m2 = one(d2, { readerArgv: R });
      bite('mutation: the same sidecar with every LINE one higher — the shape of the defect '
         + 'the reader refuses version 3 to avoid — also raises the finding',
           has(m2, 'H-POSITIONS-VALUE-SKEW'));
    }
    readerArms = false;
  }

  // ── THE LANGUAGE TABLE'S OWN SHAPE AND ITS GAPS ────────────────────────────────────
  //
  // Asserted whether or not the reader is present: it is a table, not a measurement.
  const LT = REG.bundleLanguages.languages;
  ck(`the language table is not empty — [${LT.map((l) => l.language).join(', ')}]`,
     LT.length >= 2);
  ck('every language names a non-empty extension set, who states it and why',
     LT.every((l) => Array.isArray(l.extensions) && l.extensions.length > 0
       && l.extensions.every((e) => /^\.[a-z0-9]+$/.test(e))
       && (l.statedBy ?? '').length > 30 && (l.justification ?? '').length > 60));
  ck('no two languages claim the same extension, or the table could not tell them apart',
     new Set(LT.flatMap((l) => l.extensions)).size === LT.flatMap((l) => l.extensions).length);
  ck(`the position-stream schema set is closed and non-empty — `
     + `[${REG.bundleLanguages.positionStreamSchemas.map((s) => s.schema).join(', ')}]`,
     REG.bundleLanguages.positionStreamSchemas.length >= 1
     && REG.bundleLanguages.positionStreamSchemas.every((s) => (s.statedBy ?? '').length > 30));
  // AND IT IS THE PRODUCER'S TOKEN, not a second declaration of it. A set typed here would be
  // a fifth place for the token to drift; it must contain what the producer single-sources.
  ck('…and it contains the token the producers single-source, so this set is not a second '
     + 'declaration of it',
     REG.bundleLanguages.positionStreamSchemas.some((s) => s.schema === POSITION_STREAM_SCHEMA));

  // ── AN UNKNOWN LANGUAGE IS COUNTED, NEVER PASSED ───────────────────────────────────
  //
  // The shipped conformance template declares `example-lang` deliberately. A known-language
  // table that treated an unknown language as agreeing would be satisfiable by inventing a
  // name, so the honest output is a census — and the template is the standing subject for it.
  const kit = one(join(REPO_ROOT, 'conformance-kit', 'template', 'complete'));
  ck('control: the shipped template declares a language the table does not know, and it is '
     + 'COUNTED rather than flagged or passed',
     kit.summary.bundleLanguagesUnknown['example-lang'] === 1);
  ck('control: …and no language finding is raised over it, because an unknown language is not '
     + 'a disagreement — it is an unanswered question',
     !kit.findings.some((f) => f.check === 'H-BUNDLE-LANGUAGE-SKEW'
                            && f.axis !== 'positions-schema'));

  // ── THE REAL CORPUS: H-BUNDLE-LANGUAGE-SKEW IS THE ONE THAT NEEDS NO CONTAINER ─────
  //
  // Its three subjects are the bundle's own files, the positions stream's own paths and that
  // stream's own token — all in the tree. So it has a population over the committed corpus
  // where its siblings have none, and this is where that population is floored.
  const real = sweep(corpusSnapshotDirs(), { registry: REG });
  const ranIn = real.corpus.checkCoverage['H-BUNDLE-LANGUAGE-SKEW'].ranIn;
  ck(`H-BUNDLE-LANGUAGE-SKEW needs no container, so it runs over the committed corpus — `
     + `${ranIn} of ${real.corpus.snapshots} tree(s)`,
     REG.checks['H-BUNDLE-LANGUAGE-SKEW'].needsContainer === false && ranIn >= 3);
  ck('…and it raises nothing there, over a population that is not empty',
     !real.findings.some((f) => f.check === 'H-BUNDLE-LANGUAGE-SKEW'));
  ck(`…and every other source-side and claim-side check reports NOT RUN with a reader-shaped `
     + `reason rather than a clean pass`,
     Object.keys(REG.checks).filter((id) => REG.checks[id].needsOpenedContainer === true)
       .every((id) => real.corpus.totals.checksNotRun.includes(id)));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
console.error('\n§11 — the committed reading, and the ratchet H-SOURCE-ABSENT cannot be');
// ═══════════════════════════════════════════════════════════════════════════════════════
{
  // ── FIRST, THE MEASUREMENT THAT MAKES THE RATCHET NECESSARY ────────────────────────
  //
  // H-SOURCE-ABSENT is a THRESHOLD AT ZERO, and that is measured here rather than read off its
  // `fires` line, because the whole case for a second finding rests on it. A chain at 1 of 40
  // source-level rows is a chain that has lost 39 and it is GREEN — so the check aimed at the
  // operator's primary symptom is silent on the regression an operator would actually notice.
  const at = (sourceLevel, total) => {
    const rows = Array.from({ length: total }, (_, i) => ({
      txHash: `0x${i.toString(16)}`, blockNumber: 1, txIndexInBlock: i, outcome: 'replayed',
      container: `ct/0x${i.toString(16)}.ct`, containerBytes: 8,
      recording: { steps: 1, sourceLevel: i < sourceLevel, stepsPositioned: i < sourceLevel ? 1 : 0 },
      ...(i < sourceLevel ? { sourceBundles: `text/0x${i.toString(16)}.json` } : {}),
    }));
    return one(tree({ rows }));
  };
  const LADDER = [[40, 40], [20, 40], [5, 40], [1, 40]];
  for (const [n, total] of LADDER) {
    ck(`measured: a chain at ${n} of ${total} source-level row(s) does NOT raise `
       + `H-SOURCE-ABSENT — the check is a threshold at zero`,
       !has(at(n, total), 'H-SOURCE-ABSENT'));
  }
  const floorCase = at(0, 40);
  ck('measured: …and 0 of 40 DOES, which is the only place it fires',
     has(floorCase, 'H-SOURCE-ABSENT') && floorCase.summary.tracedRows === 40
     && floorCase.summary.sourceLevelRows === 0);

  // ── THE RATCHET, DRIVEN BOTH WAYS OVER SYNTHETIC READINGS ──────────────────────────
  //
  // A reading is just a report, so a synthetic one is a real subject: the comparison reads
  // `corpus.sourceCensusByChain` and nothing else about it.
  const readingWith = (byChain, over = {}) => ({
    format: 'blocktracer/chain-health@1',
    containerReader: null,
    corpus: {
      snapshots: 1,
      totals: { rowsExamined: 1000, tracedRows: 40, untracedRows: 960, chainAbsentRows: 0,
                unclassifiedRows: 0, containersNamed: 40, jointScopeRows: 960,
                sourceLevelRows: 40, stepsPositionedRows: 40, sourceBundleRows: 40,
                artifactsResolved: 0, attributedRows: 40,
                containersOpened: 0, containersRefused: 0,
                ...over },
      sourceCensusByChain: byChain,
    },
  });
  const census = (sourceLevelRows, tracedRows = 40) =>
    ({ snapshots: 1, tracedRows, sourceLevelRows, stepsPositionedRows: sourceLevelRows,
       sourceBundleRows: sourceLevelRows, artifacts: 0, artifactsResolved: 0 });

  const dirs40 = [tree({ rows: Array.from({ length: 40 }, (_, i) => ({
    txHash: `0x${i.toString(16)}`, blockNumber: 1, txIndexInBlock: i, outcome: 'replayed',
    container: `ct/0x${i.toString(16)}.ct`, containerBytes: 8,
    recording: { steps: 1, sourceLevel: i < 1 },
    ...(i < 1 ? { sourceBundles: `text/0x0.json` } : {}) })),
    provenance: { chain: 'twin-chain' } })];

  const slipped = sweep(dirs40, { registry: REG,
                                  baseline: readingWith({ 'twin-chain': census(40) }) });
  const rf = slipped.findings.find((f) => f.check === 'H-SOURCE-RATCHET');
  bite('a chain that went from 40 source-level rows to 1 raises H-SOURCE-RATCHET — the '
     + 'regression H-SOURCE-ABSENT is structurally blind to', rf !== undefined);
  bite('…and the finding names BOTH readings of BOTH figures, because a drop in reach and a '
     + 'smaller corpus are different things',
       rf.baseline === 40 && rf.now === 1 && rf.baselineTracedRows === 40
       && rf.tracedRows === 40 && /gone BACKWARDS by 39/.test(rf.says));
  ck('…and the same tree raises NO H-SOURCE-ABSENT, so the two findings are not one check '
     + 'reported twice',
     !slipped.findings.some((f) => f.check === 'H-SOURCE-ABSENT'));
  ck('…and the ratchet is reported as having RUN, over a stated number of chains',
     slipped.corpus.checkCoverage['H-SOURCE-RATCHET'].ranIn === 1
     && slipped.corpus.checkCoverage['H-SOURCE-RATCHET'].chainsCompared === 1);

  // A RISE IS NOT A FINDING. A floor that reddened on improvement would have stasis as its
  // only stable state, and that is the asymmetry the registry states.
  const risen = sweep(dirs40, { registry: REG,
                                baseline: readingWith({ 'twin-chain': census(0) }) });
  ck('twin: a chain ABOVE its committed floor raises nothing — the reading is a floor and not '
     + 'an equality',
     !risen.findings.some((f) => f.check === 'H-SOURCE-RATCHET')
     && risen.corpus.checkCoverage['H-SOURCE-RATCHET'].ranIn === 1);

  // ANTI-VACUITY: A RATCHET WHOSE POPULATION IS EMPTY REPORTS NOT RUN, NEVER PASSED.
  const noShared = sweep(dirs40, { registry: REG,
                                   baseline: readingWith({ 'a-chain-that-left': census(40) }) });
  bite('anti-vacuity: a baseline sharing NO chain with the sweep reports the ratchet NOT RUN, '
     + 'with both chain lists, rather than finding every chain fine',
       noShared.corpus.checkCoverage['H-SOURCE-RATCHET'].ranIn === 0
       && /share NO chain/.test(noShared.corpus.checkCoverage['H-SOURCE-RATCHET'].reasons[0])
       && noShared.corpus.totals.checksNotRun.includes('H-SOURCE-RATCHET'));
  const noBase = sweep(dirs40, { registry: REG });
  ck('premise: with NO baseline at all the ratchet reports NOT RUN with its own reason, so a '
     + 'run without one cannot look like a run that found nothing',
     noBase.corpus.checkCoverage['H-SOURCE-RATCHET'].ranIn === 0
     && /No committed reading was available/
          .test(noBase.corpus.checkCoverage['H-SOURCE-RATCHET'].reasons[0]));
  // A CHAIN THE BASELINE HAS AND THE SWEEP DOES NOT IS A WITHDRAWAL, NOT A SLIP. Reporting it
  // here as well as in the `equal` figures would report one change twice and make a legitimate
  // withdrawal unlandable.
  const withdrew = sweep(dirs40, { registry: REG,
    baseline: readingWith({ 'twin-chain': census(1), 'gone-chain': census(9) }) });
  ck('a chain in the baseline and not in the sweep is recorded as WITHDRAWN rather than as a '
     + 'slip — the equal figures report the tree leaving',
     !withdrew.findings.some((f) => f.check === 'H-SOURCE-RATCHET')
     && withdrew.corpus.checkCoverage['H-SOURCE-RATCHET'].chainsWithdrawn
          .includes('gone-chain'));

  // ── `--expect`: THE ROLL-UP AGAINST THE COMMITTED READING ──────────────────────────
  const SPEC = REG.committedReading;
  ck('the reading comparison declares its equal keys, its floor keys, its reader-dependent '
     + 'keys and its per-chain floor, each non-empty',
     [SPEC.equal, SPEC.floor, SPEC.reader, SPEC.perChainFloor]
       .every((a) => Array.isArray(a) && a.length > 0));
  ck('…and no key is in two directions at once, which would make one comparison override the '
     + 'other silently',
     new Set([...SPEC.equal, ...SPEC.floor, ...SPEC.reader]).size
       === SPEC.equal.length + SPEC.floor.length + SPEC.reader.length);
  ck(`…and the anti-vacuity floors are stated with the reading they were calibrated against — `
     + `${SPEC.antiVacuity.minSnapshots} snapshot(s), ${SPEC.antiVacuity.minRowsExamined} row(s) `
     + `against a measured ${SPEC.antiVacuity.measuredRowsExamined}`,
     SPEC.antiVacuity.minSnapshots >= 1
     && SPEC.antiVacuity.minRowsExamined > 100
     && SPEC.antiVacuity.minRowsExamined < SPEC.antiVacuity.measuredRowsExamined
     && (SPEC.antiVacuity.why ?? '').length > 100);

  // THE COMMITTED READING IS COMMITTED, AND IT STILL DESCRIBES THIS TREE.
  ck('the committed reading exists where the recipe writes it', existsSync(COMMITTED_READING_PATH));
  const reading = JSON.parse(readFileSync(COMMITTED_READING_PATH, 'utf8'));
  const live = sweep(corpusSnapshotDirs(), { registry: REG, baseline: reading });
  const v = compareToReading(live, reading, REG);
  ck(`the committed reading still describes this tree — ${v.compared} comparison(s), `
     + `${v.problems.length} problem(s)`, v.ok);
  if (!v.ok) for (const pr of v.problems.slice(0, 6)) console.error(`      ${pr}`);
  ck(`…over a comparison count that is not zero — ${v.compared}`, v.compared >= 20);
  // AND IT WAS TAKEN WITHOUT A READER, deliberately: the reading is asserted on hosts that have
  // no `ct-print`, so a reading taken WITH one would fail the gate everywhere it matters.
  ck('the committed reading was taken WITHOUT a container reader, so a host that has none can '
     + 'still assert it', reading.containerReader === null);

  // ── THE CONTROL THAT MATTERS MOST: AN EMPTY CORPUS MUST FAIL ───────────────────────
  //
  // Every `equal` comparison over a reading with no snapshots is satisfied and every `floor`
  // comparison against a zero baseline is satisfied, so a checker pointed at an empty corpus
  // prints that the reading still describes the tree. A corpus checker that passes on an empty
  // corpus is this campaign's most-repeated failure; both sides are floored, and both floors
  // are driven here.
  const emptyDir = tree({ rows: [] });
  const emptySweep = sweep([emptyDir], { registry: REG, baseline: reading });
  const ev = compareToReading(emptySweep, reading, REG);
  bite('anti-vacuity: --expect over a corpus with nothing in it FAILS, quoting the figure and '
     + 'the floor', !ev.ok && ev.problems.some((p) => /this sweep: 0 row\(s\) examined, below the floor/.test(p)));
  bite('anti-vacuity: …and it compares NOTHING rather than comparing successfully',
       ev.compared === 0);
  const emptied = JSON.parse(JSON.stringify(reading));
  emptied.corpus.snapshots = 0;
  emptied.corpus.totals.rowsExamined = 0;
  emptied.corpus.sourceCensusByChain = {};
  const ev2 = compareToReading(live, emptied, REG);
  bite('anti-vacuity: an EMPTIED committed reading fails too — the floor is on both sides, '
     + 'because either one being empty makes the comparison free',
       !ev2.ok && ev2.problems.some((p) => /the committed reading: 0 snapshot\(s\)/.test(p))
       && ev2.compared === 0);
  const wrongShape = compareToReading(live, { format: 'blocktracer/chain-health@1' }, REG);
  bite('anti-vacuity: a reading with no roll-up at all is refused rather than agreed with',
       !wrongShape.ok && wrongShape.compared === 0
       && wrongShape.problems.some((p) => /no corpus roll-up at all/.test(p)));

  // ── EACH DIRECTION BITES, AND IN ITS OWN DIRECTION ────────────────────────────────
  const bump = (k, by) => {
    const r = JSON.parse(JSON.stringify(reading));
    r.corpus.totals[k] = num(r.corpus.totals[k]) + by;
    return r;
  };
  const eqKey = SPEC.equal[0], floorKey = SPEC.floor[0];
  bite(`an \`equal\` figure moving UP in the reading is a problem — ${eqKey}`,
       !compareToReading(live, bump(eqKey, 1), REG).ok);
  bite(`…and moving DOWN is a problem too, because it is about the tree — ${eqKey}`,
       !compareToReading(live, bump(eqKey, -1), REG).ok);
  bite(`a \`floor\` figure the reading sets ABOVE the sweep is a problem — ${floorKey}`,
       !compareToReading(live, bump(floorKey, 1), REG).ok);
  ck(`…and one the reading sets BELOW the sweep is NOT, because a rise is improvement — `
     + `${floorKey}`, compareToReading(live, bump(floorKey, -1), REG).ok);
  // READER-DEPENDENT FIGURES ARE SKIPPED BETWEEN UNLIKE RUNS AND COMPARED BETWEEN LIKE ONES.
  const readerReading = JSON.parse(JSON.stringify(reading));
  readerReading.containerReader = 'some-reader';
  const rv = compareToReading(live, readerReading, REG);
  ck('a reader-dependent figure is SKIPPED with its reason when the two runs disagree about '
     + 'whether a reader was named, not failed',
     rv.ok && SPEC.reader.every((k) => rv.skipped.some((s) => s.startsWith(`${k} —`))));
  bite('…and IS compared when both ran the same way — otherwise the skip would be a hole',
       !compareToReading(live, bump(SPEC.reader[0], 1), REG).ok);

  // ── THE TWO CLI-LEVEL GUARDS, WHICH ONLY THE CLI CAN SHOW ─────────────────────────
  //
  // Everything above drives `compareToReading` and `sweep` directly, which is right — they are
  // where the rules live. But two of this mode's guards are decisions the CLI makes before
  // either function is reached, and they were INERT: driven by hand and asserted nowhere, so a
  // control plant that removed either left the suite green. Measured: ten plants over this
  // section, nine turned it red and the missing-baseline one did not.
  const missing = run([join(REPO_ROOT, 'conformance-kit', 'template', 'complete'),
                       '--quiet', '--baseline', join(tmp, 'no-such-reading.json')]);
  bite('a --baseline naming a file that does not exist is REFUSED by name, not replaced by the '
     + 'committed default — a typo must not quietly switch the ratchet off',
       missing.rc === 2 && /does not exist/.test(missing.err)
       && /must not quietly switch the ratchet off/.test(missing.err));
  const okBaseline = run([join(REPO_ROOT, 'conformance-kit', 'template', 'complete'),
                          '--quiet', '--baseline', COMMITTED_READING_PATH]);
  ck('control: the same invocation with a baseline that DOES exist runs, so the refusal is '
     + 'about the missing file and not about the flag',
     okBaseline.rc !== 2);

  // AND THE EMPTY GLOB. `--expect` with no subject named is the shape a glob that expanded to
  // nothing takes, and it is refused with a sentence about the empty corpus rather than by
  // printing the flags again — a corpus checker that passes on an empty corpus is this
  // campaign's most-repeated failure, and "you forgot an argument" is not that message.
  const emptyGlob = run(['--quiet', '--expect', COMMITTED_READING_PATH]);
  bite('--expect with NO snapshot tree named is refused by name, saying that an empty corpus '
     + 'is what the flag exists to refuse',
       emptyGlob.rc === 2 && /NO snapshot tree was named/.test(emptyGlob.err)
       && /empty corpus this flag exists to refuse/.test(emptyGlob.err));
  ck('control: the same flag WITH a subject does not hit that refusal, so it is about the '
     + 'empty subject list',
     !/NO snapshot tree was named/.test(
       run([join(REPO_ROOT, 'conformance-kit', 'template', 'complete'), '--quiet',
            '--expect', COMMITTED_READING_PATH]).err));
}

cleanup();
console.error('');
// THE HOST-INDEPENDENT TOTAL. This is the one the `chain-selftest` header, the recipe body and
// the CI step comments cross-check, and it is the same on every host by construction.
if (asserted !== 187) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 187 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared: 187)`);
}
// AND THE READER-DEPENDENT ONES, DECLARED AND EITHER ASSERTED OR REPORTED UNRUN. A block of arms
// that quietly contributes nothing on the host where it matters is how a suite comes to be green
// everywhere and load-bearing nowhere.
const READER_ARMS = 30;
if (assertedWithReader === 0) {
  console.error(`NOT RUN: ${READER_ARMS} arm(s) need the container reader `
    + `(../codetracer-trace-format-nim/ct-print) and it is not on this host. They are not `
    + `counted as passed. Build it with \`nimble buildCtPrint\` in that checkout's own devshell.`);
} else if (assertedWithReader !== READER_ARMS) {
  console.error(`READER-ARM COUNT IS ${assertedWithReader}, EXPECTED ${READER_ARMS} — an arm `
    + `in the reader-dependent block was added, removed or skipped.`);
  failed++;
} else {
  console.error(`reader-dependent arms: ${assertedWithReader} (as declared: ${READER_ARMS})`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('PASS — every finding has a twin it must not fire on and a mutation it must');
