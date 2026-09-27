#!/usr/bin/env node
// chain-health.mjs — IS THE RECORDING LAYER HEALTHY? A sweep over prepared snapshot trees
// that reports what the conformance gates structurally cannot see.
//
//   node tools/chain/chain-health.mjs <snapshot-dir> [<snapshot-dir> …]
//   node tools/chain/chain-health.mjs --corpus
//   node tools/chain/chain-health.mjs --corpus --out tools/chain/measurements/chain-health.json
//   node tools/chain/chain-health.mjs <dir> --container-reader ../codetracer-trace-format-nim/ct-print
//
// `--container-reader` NAMES THE PROGRAM AND NOT A MODE. The modes are the reader's own
// interface, so they live in `health-checks.json` under `containerReader.probes`, and a mode
// flag in the caller's argv is refused by name — `--meta-json --events <path>` leaves the
// reader printing one shape and this tool parsing another while every other clause looks fine.
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
// `unhealthy`. With no `--container-reader` named, H-READ-NONE is the NORMAL output and the
// verdict says so in those words — the tool is reporting that it could not answer, not that
// the answer is bad.
//
// ── WHAT THE CONTAINER HALF REPORTS, AND WHAT IT REFUSES TO BLAME ─────────────────────
//
// With a reader named, every container a row names is opened and two questions are answered.
// `H-CONTAINER-UNREADABLE` asks whether it opened at all, and `H-CONTAINER-SCHEMA-SKEW` asks,
// SEPARATELY FOR EACH CONSUMER, whether the schema version it declares is one that consumer
// accepts.
//
// OVER THIS REPOSITORY'S CORPUS THE HONEST ANSWER IS THAT NOTHING OPENS, and the tool is
// written so that answer cannot be mistaken for a broken reader. Every container declares
// `meta.dat` schema version 3; the pinned reader accepts [4, 5] and refuses 3 BY NAME rather
// than decoding it under a rule that would put every source position one line high; so it
// refuses all of them and says exactly why. Each finding therefore carries the reader's own
// sentence, the reader's BUILD ID, and the version the container declared — the reader is
// identified, not accused, and the defect named is the recording's schema and not the reader.
//
// The skew is per consumer because the consumers disagree with each other. The shipped replay
// engine — the wasm a visitor's browser runs, pinned by sha256 in `client/hydrate/engine-pin.txt`
// — accepts [3] and refuses nothing, so it accepts every container the pinned reader refuses.
// One combined verdict would have to pick which consumer matters, and that is not a tie a
// sweep breaks.
//
// ── THE MEASURED FACTS THIS TOOL CARRIES AND DOES NOT FIX ─────────────────────────────
//
// They are in `health-checks.json` under `carried`, echoed into every artifact, and they bound
// what a container-opening check can claim. Read them there; the figures in a comment go
// stale, and one of these already did: the note that the reader EXITS 0 WHILE REFUSING was
// measured on a build that is no longer the one on disk. A reader built from a current
// checkout exits 1, on all 58 `.ct` files here. The two-clause `opened` rule is kept anyway —
// it costs one regular-expression test and the behaviour it guards against was real.
//
// ── WHAT IT DOES NOT DO ───────────────────────────────────────────────────────────────
//
// It reaches no network, spawns nothing unless `--container-reader` is given, needs no Nim,
// no Nix and no toolchain, and writes nothing unless `--out` is given. It reads snapshot
// trees. That is deliberate: a health sweep expensive enough to think about is a health sweep
// nobody runs.

import { readFileSync, writeFileSync, existsSync, statSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
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
 * THE READER'S BUILD ID, which is its own bytes.
 *
 * `ct-print --version` answers `Unknown option: version` and exits 1, so the reader states no
 * id. That is not a cosmetic gap: this repository's history already holds two builds of the
 * same reader that refuse the same container DIFFERENTLY — one exited 0 while refusing and the
 * current one exits 1 — so a refusal reported without saying which build produced it is a
 * refusal nobody can reproduce. Content-addressing the program is `engine-pin.txt`'s idiom
 * applied to the reader.
 *
 * A failure here is reported, never swallowed: `null` plus the reason, so it reads as "not
 * established" rather than as an absent field.
 */
export function readerBuildId(programPath) {
  try {
    const bytes = readFileSync(programPath);
    return { path: programPath, sha256: createHash('sha256').update(bytes).digest('hex'),
             bytes: bytes.length };
  } catch (e) {
    return { path: programPath, sha256: null, bytes: null,
             why: `the reader's own bytes could not be read: ${e.message}` };
  }
}

/**
 * Open one container with the named reader, and decide whether it OPENED.
 *
 * THE EXIT STATUS IS NOT THE VERDICT and the rule is not spelled here — `containerReader`
 * in `health-checks.json` carries both clauses, because a refusal signature written in one
 * place and a verdict computed in another is two statements of one rule.
 *
 * WHAT IT RETURNS BESIDES THE VERDICT is the reader's own sentence and, when the refusal names
 * a schema version, that version. Both are the reader's EVIDENCE rather than a judgement on
 * it: over this repository's corpus the refusal is unanimous, so a finding that said only
 * "unreadable" would read as a broken tool once per row and point an operator at the wrong
 * repository. The version is taken from the refusal and not from the container's bytes
 * deliberately — walking a CTFS directory here would be a second implementation of another
 * repository's format in a tool whose whole argument is that it adds none.
 *
 * @param {string[]} argv  program plus leading arguments; the container path is appended
 * @param {object} rule    `containerReader` from the registry
 * @param {string[]} [probeArgv]  the probe's own mode arguments, from the registry
 */
export function openContainer(argv, containerPath, rule, probeArgv = []) {
  const [cmd, ...lead] = argv;
  const r = spawnSync(cmd, [...lead, ...probeArgv, containerPath],
                      { encoding: 'utf8', timeout: 120_000 });
  const said = `${r.stdout ?? ''}${r.stderr ?? ''}`;
  const schema = rule.schemaRefusal ?? null;
  // The version the reader NAMED, when it named one. `undefined` would be indistinguishable
  // from a key nobody set, so an unstated version is an explicit null.
  let declaredSchemaVersion = null;
  if (schema) {
    const m = new RegExp(schema.signature, schema.signatureFlags || undefined).exec(said);
    if (m && m[1] !== undefined) declaredSchemaVersion = Number(m[1]);
  }
  // The reader's own sentence, kept whole enough to say WHY. A count of refusals with no
  // reason is a count.
  const sig = new RegExp(rule.refusalSignature, rule.refusalSignatureFlags || undefined);
  const firstSaid = (said.split('\n').map((l) => l.trim()).find((l) => l.length > 0) ?? '');
  const refusalLine = (said.split('\n').find((l) => new RegExp(rule.refusalSignature).test(`\n${l}`))
                       ?? firstSaid).trim();
  const base = { readerSaid: refusalLine.slice(0, 400), declaredSchemaVersion,
                 stdout: r.stdout ?? '' };

  if (r.error) {
    return { ...base, opened: false, readerSaid: `the reader could not be run: ${r.error.message}`,
             why: `the reader could not be run: ${r.error.message}`, ran: false };
  }
  const refused = sig.test(said);
  if (r.status !== 0) {
    return { ...base, opened: false, ran: true, exit: r.status, refusedByName: refused,
             why: `the reader exited ${r.status}`
                + (refusalLine ? ` and said: ${refusalLine.slice(0, 300)}` : '') };
  }
  if (refused) {
    return { ...base, opened: false, ran: true, exit: 0, refusedByName: true,
             why: `the reader exited 0 and refused: ${refusalLine.slice(0, 300)}` };
  }
  return { ...base, opened: true, ran: true, exit: 0, refusedByName: false, why: '' };
}

/**
 * The counts the container itself states, out of the `counts` probe's payload.
 *
 * A PAYLOAD THAT DOES NOT PARSE IS NOT A CLOSED CONTAINER. The verdicts are kept apart on
 * purpose: a reader that exited 0 and printed something this parser cannot read HAS opened the
 * recording, and calling it refused would blame the container for the parser. So this returns
 * `{ available: false, why }` and the container stays counted as opened.
 */
export function countsFromProbeOutput(stdout, rule) {
  const p = rule.probes?.counts;
  if (!p || p.parse !== 'json') {
    return { available: false, why: 'the registry declares no JSON counts probe' };
  }
  let doc;
  try { doc = JSON.parse(stdout); }
  catch (e) {
    return { available: false,
             why: `the counts probe's output is not JSON (${e.message.slice(0, 120)}), so the `
                + `container's own counts were not read — the container itself opened` };
  }
  const at = p.at ? doc?.[p.at] : doc;
  if (!at || typeof at !== 'object') {
    return { available: false,
             why: `the counts probe's output carries no ${JSON.stringify(p.at ?? '(root)')} `
                + `object, so the container's own counts were not read` };
  }
  const out = { available: true };
  for (const k of p.yields ?? Object.keys(at)) {
    if (typeof at[k] === 'number' && Number.isFinite(at[k])) out[k] = at[k];
  }
  return out;
}

/**
 * The probe registry's own guard: a caller that passes a MODE FLAG breaks every probe.
 *
 * `--meta-json --events <path>` leaves the reader printing whichever mode it parsed last and
 * this tool reading a document of the wrong shape, while the exit status, the refusal
 * signature and the container path all look exactly right. That is a silent wrong answer, so
 * it is refused by name with the flag quoted rather than tolerated.
 */
export function modeFlagInCallerArgv(argv, rule) {
  const banned = rule.callerMustNotPassAModeFlag?.flags ?? [];
  return argv.find((a) => banned.includes(a)) ?? null;
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
    // THE SCHEMA CENSUS IS PUBLISHED WHETHER OR NOT THE SKEW FINDING FIRES, for the same
    // reason H-SOURCE-ABSENT publishes its rates: the finding is a threshold and the census
    // is the gradient. `unstated` is its own key rather than an omission, because a container
    // the reader OPENED states no version anywhere the reader prints — see
    // `containerReader.schemaRefusal.cost` — and "opened, version unknown" and "not probed"
    // are different measurements.
    containerSchemaCensus: {},
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
  // Two things come out of it. The ACCOUNTING — how many of the containers this tree names
  // could be opened at all — which is what makes `H-READ-NONE` a measurement rather than a
  // constant. And, for every container that did not open, the reader's own evidence: its
  // sentence, its build id, and the schema version its refusal named.
  const readerNotes = [];
  const build = readerArgv && readerArgv.length ? readerBuildId(readerArgv[0]) : null;
  if (readerArgv && readerArgv.length) {
    const probe = reg.containerReader.probes?.open?.argv ?? [];
    for (const row of rows) {
      if (!row.container) continue;
      const p = resolve(dir, row.container);
      if (!existsSync(p)) {
        sum.containersRefused++;
        row.containerRead = 'absent';
        readerNotes.push(`${row.txHash}: ${row.container} is not on disk`);
        if (want.includes('H-CONTAINER-UNREADABLE')) {
          add('H-CONTAINER-UNREADABLE', {
            txHash: row.txHash, container: row.container,
            readerSaid: null, readerBuildId: build, declaredSchemaVersion: null,
            says: `this row names ${JSON.stringify(row.container)} and no such file is on `
                + `disk, so the recording it claims to have made cannot be opened by anybody`,
          });
        }
        continue;
      }
      const v = openContainer(readerArgv, p, reg.containerReader, probe);
      row.containerProbe = { exit: v.exit ?? null };
      if (v.declaredSchemaVersion !== null) {
        row.declaredSchemaVersion = v.declaredSchemaVersion;
        const k = String(v.declaredSchemaVersion);
        sum.containerSchemaCensus[k] = (sum.containerSchemaCensus[k] ?? 0) + 1;
      } else {
        sum.containerSchemaCensus.unstated = (sum.containerSchemaCensus.unstated ?? 0) + 1;
      }
      if (v.opened) {
        sum.containersOpened++;
        row.containerRead = 'opened';
        row.containerCounts = countsFromProbeOutput(v.stdout, reg.containerReader);
      } else {
        sum.containersRefused++;
        row.containerRead = 'refused';
        readerNotes.push(`${row.txHash}: ${v.why}`);
        if (want.includes('H-CONTAINER-UNREADABLE')) {
          // THE SENTENCE NAMES THE CONTAINER'S PROPERTY WHEN THERE IS ONE, AND THE READER'S
          // WORDS OTHERWISE. Over this repository's corpus every refusal names a schema
          // version, so every one of these findings says what about the CONTAINER made it
          // unreadable — which is the difference between reporting a corpus fact and
          // reporting a broken tool.
          const ver = v.declaredSchemaVersion;
          add('H-CONTAINER-UNREADABLE', {
            txHash: row.txHash, container: row.container,
            readerSaid: v.readerSaid, readerBuildId: build, declaredSchemaVersion: ver,
            says: ver !== null
              ? `this container declares meta.dat schema version ${ver}, which the reader at `
                + `build ${build?.sha256?.slice(0, 16) ?? 'unknown'} does not accept — it `
                + `refused the container BY NAME rather than decoding it under the wrong rule, `
                + `so this is a fact about the recording and not a reader failure. The reader `
                + `said: ${v.readerSaid}`
              : `the reader at build ${build?.sha256?.slice(0, 16) ?? 'unknown'} did not open `
                + `this container and named no schema version, so what it found is only what `
                + `it said: ${v.readerSaid || '(it said nothing)'}`,
          });
        }
      }
    }
  }

  // ── H-CONTAINER-SCHEMA-SKEW — one finding per (declared version, consumer) ───────────
  //
  // PER CONSUMER, NEVER COMBINED. A single verdict would have to decide which consumer
  // matters, and over this corpus the two answer oppositely: the pinned reader refuses every
  // container and the shipped engine accepts every one. That is not a tie to break in a tool.
  const consumers = reg.containerSchema?.consumers ?? [];
  const declaredVersions = Object.keys(sum.containerSchemaCensus)
    .filter((k) => k !== 'unstated').map(Number).sort((a, b) => a - b);
  if (want.includes('H-CONTAINER-SCHEMA-SKEW')) {
    for (const ver of declaredVersions) {
      for (const c of consumers) {
        if (c.accepts.includes(ver)) continue;
        add('H-CONTAINER-SCHEMA-SKEW', {
          consumer: c.id, declaredSchemaVersion: ver,
          containers: sum.containerSchemaCensus[String(ver)],
          accepts: c.accepts,
          refusesByName: (c.refusesByName ?? []).includes(ver),
          statedBy: c.statedBy, readFrom: c.readFrom,
          says: `${sum.containerSchemaCensus[String(ver)]} container(s) in this tree declare `
              + `meta.dat schema version ${ver}, and the consumer ${JSON.stringify(c.id)} — `
              + `${c.what} — accepts [${c.accepts.join(', ')}]. `
              + ((c.refusesByName ?? []).includes(ver)
                  ? `It refuses ${ver} BY NAME, so it will decline rather than mis-read.`
                  : `It does NOT refuse ${ver} by name, so it will attempt the decode; `
                    + `whether that decode is right is the disagreement recorded under `
                    + `\`carried\` and is not settled here.`)
              + ` Its accepted set was read from ${c.statedBy}.`,
        });
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
    // The containers this sweep actually PROBED — not the ones the rows name. With no reader
    // the two differ by everything, and the difference is the whole point of the accounting.
    'H-CONTAINER-UNREADABLE': sum.containersOpened + sum.containersRefused,
    // The distinct versions there are to compare, not the containers. One version stated by
    // forty containers is one comparison per consumer.
    'H-CONTAINER-SCHEMA-SKEW': declaredVersions.length,
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
    // A CONTAINER CHECK WITH NO READER DID NOT MEASURE AN EMPTY POPULATION — IT WAS NEVER
    // ASKED. Both read as NOT RUN, and they must not read as the same reason: "the scope is
    // empty" says the tree has nothing subject to the check, which is a fact about the tree,
    // and this is a fact about the invocation.
    if (c.needsContainer === true && !(readerArgv && readerArgv.length)) {
      status[id] = { ran: false, why: c.notRunReason ?? 'no container reader was named' };
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
  const schemaCensus = {};
  const coverage = {};
  const byChain = {};
  for (const s of snapshots) {
    for (const k of keys) total[k] += s.summary[k] ?? 0;
    for (const [r, n] of Object.entries(s.summary.declaredRungs)) {
      rungs[r] = (rungs[r] ?? 0) + n;
    }
    for (const [v, n] of Object.entries(s.summary.containerSchemaCensus ?? {})) {
      schemaCensus[v] = (schemaCensus[v] ?? 0) + n;
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
  total.containerSchemaCensus = schemaCensus;
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
    // WHICH OF THEM ANSWERED ANYWAY, READ OFF THE COVERAGE TABLE RATHER THAN ASSUMED.
    //
    // This sentence used to say flatly that every container check was NOT RUN, and that became
    // FALSE the moment a refusal was made into an answer: a container the reader declines by
    // name settles `is it readable` (no) and, when the refusal states a version, `is that
    // version one each consumer accepts`. Reporting those as unrun understates the sweep
    // exactly as badly as reporting the unanswered ones as passed overstates it, and both
    // failures have the same cause — a message that names a population instead of measuring it.
    const answered = needsContainerRequested.filter((id) => (corpus.checkCoverage[id]?.ranIn ?? 0) > 0);
    const unanswered = needsContainerRequested.filter((id) => (corpus.checkCoverage[id]?.ranIn ?? 0) === 0);
    findings.push({
      check: 'H-READ-NONE',
      says: `no recording was OPENED on this sweep — ${corpus.totals.containersNamed} `
          + `container(s) are named by rows, ${corpus.totals.containersRefused} were probed and `
          + `refused, and 0 opened. `
          + (unanswered.length
              ? `${unanswered.length} requested check(s) could not be answered in any tree: `
                + `${unanswered.join(', ')}. `
              : `Every requested container check answered in at least one tree. `)
          + (answered.length
              ? `${answered.length} answered from the refusals themselves — `
                + `${answered.join(', ')} — because a reader declining a container BY NAME is a `
                + `measurement of the container and not a missing one. `
              : '')
          + `Anything that needs a recording to actually open is unanswered here. This is the `
          + `tool saying what it could and could not answer, not that the answer is bad.`,
      needsContainerRequested,
      answeredFromRefusals: answered,
      unansweredInEveryTree: unanswered,
      containersNamed: corpus.totals.containersNamed,
      containersRefused: corpus.totals.containersRefused,
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
    // WHICH BUILD ANSWERED. A refusal reported without the build that produced it is a
    // refusal nobody can reproduce, and this reader's two builds refuse the same container
    // with different exit statuses — so the id travels on the artifact, not only inside the
    // findings that happen to quote it.
    containerReaderBuild: readerArgv && readerArgv.length ? readerBuildId(readerArgv[0]) : null,
    containerSchemaConsumers: reg.containerSchema?.consumers ?? [],
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
  // WHICH BUILD ANSWERED, ON THE OPERATOR'S SCREEN AND NOT ONLY IN THE ARTIFACT. The one
  // question a reader of "45 refused" asks next is "by what", and two builds of this reader
  // refuse the same container differently.
  if (report.containerReaderBuild) {
    const b = report.containerReaderBuild;
    L.push(`  reader build         ${b.sha256 ? `${b.sha256.slice(0, 16)}… ${b.bytes} bytes` : `NOT ESTABLISHED — ${b.why}`}`);
  }
  const census = Object.entries(t.containerSchemaCensus ?? {});
  if (census.length) {
    // `unstated` IS NOT A VERSION and must not print as one. It is the count of containers
    // that were probed and declared nothing the reader printed — an opened container states no
    // version anywhere, and a file that is not a container at all names none either.
    const stated = census.filter(([v]) => v !== 'unstated');
    const unstated = census.find(([v]) => v === 'unstated')?.[1] ?? 0;
    L.push(`  container schema     ${stated.map(([v, n]) => `v${v}: ${n}`).join(', ') || 'none stated'}`
         + (unstated ? `; ${unstated} probed container(s) stated no version` : ''));
    for (const c of report.containerSchemaConsumers ?? []) {
      const bad = stated.filter(([v]) => !c.accepts.includes(Number(v)));
      L.push(`    ${c.id.padEnd(16)} accepts [${c.accepts.join(', ')}] — `
           + (stated.length === 0
               ? 'no declared version to compare it against'
               : bad.length
                 ? `${bad.reduce((a, [, n]) => a + n, 0)} container(s) outside it `
                   + `(v${bad.map(([v]) => v).join(', v')})`
                 : 'every declared version is in it'));
    }
  }
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
+ '  --container-reader <prog> the reader PROGRAM (not a mode — the modes come from\n'
+ '                            health-checks.json); it opens every container a row names\n'
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

  // THE PROBES APPEND THEIR OWN MODE, so a caller that also passes one produces
  // `--meta-json --events <path>`: the reader keeps whichever it parsed last, this tool reads
  // a document of the wrong shape, and the exit status, the refusal signature and the path all
  // look right. A silent wrong answer, refused by name with the flag quoted.
  if (readerArgv && readerArgv.length) {
    const bad = modeFlagInCallerArgv(readerArgv, reg.containerReader);
    if (bad) {
      process.stderr.write(`chain-health: --container-reader must name the PROGRAM and not a `
        + `mode — ${JSON.stringify(bad)} is one of the flags this tool appends itself, and `
        + `passing it makes every probe read a document of the wrong shape while looking `
        + `fine. Drop it: --container-reader '${readerArgv.filter((a) => a !== bad).join(' ')}'\n`);
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
