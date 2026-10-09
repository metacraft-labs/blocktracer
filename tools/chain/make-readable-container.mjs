#!/usr/bin/env node
// make-readable-container.mjs — RECORD the one container a current reader can open,
// at the moment the test that needs it runs.
//
//   node tools/chain/make-readable-container.mjs          # materialise, print a verdict
//   node tools/chain/make-readable-container.mjs --check   # say what it WOULD do, write nothing
//
// ── WHY THIS EXISTS, AND IT IS A POLICY AND A DEFECT ──────────────────────────────────
//
// `fixtures/chain-health/readable-container` is the ONE subject the container-versus-claim
// and source-versus-container checks have (`chain-health-selftest.mjs` §9, §10 — 31 arms).
// Its container used to be COMMITTED, 151,552 bytes of version-4 CTFS, and the cost of that
// is the whole of CRR-4: the canonical writer moved to container version 5 / `meta.dat`
// schema 6 on 2026-10-01, the committed bytes did not, and from that moment every one of the
// 31 arms was unreachable — silently at first, and since `18b7eec8` loudly, but still not
// run.
//
// The workspace policy this closes is `metacraft-dev-guidelines/policies/repo-requirements.md`
// §4.3: `*.ct` may be committed in exactly one repo, `codetracer-example-recordings`, and
// "everywhere else, a test that needs a recording RECORDS IT ON THE FLY, so it cannot go
// stale against the recorder that produced it." The ban is deliberately not a size ceiling —
// §4.3 measures that a 1 MB ceiling waves through 19 of 20 committed recordings — because
// the objection is that a recording is DERIVED, and a derived artefact committed beside the
// thing it was derived from is a clock running down.
//
// Re-recording resets that clock. Recording on the fly stops it, and this is that.
//
// ── WHAT IS COMMITTED AND WHAT IS NOT, AND THE LINE IS MEASURED ───────────────────────
//
// The tree's OTHER files stay committed, and the reason is that they are facts about the
// RECORDING while the container is a fact about the WRITER. Measured, 2026-10-04, by
// regenerating the container at `codetracer-trace-format-nim` `7967c179` and comparing it to
// what the committed sidecars say:
//
//   * `positions/<tx>.json` — the `(pathId, line, column)` columns of the regenerated step
//     stream are IDENTICAL to the committed ones, value by value: pathId
//     [0,0,0,0,0,0,1,1,1,0], line [1..6,1,2,3,7], column all null. Zero disagreements.
//   * `snapshot.json`'s `recording` — steps 10, events 10, callsOpened 1 (container `calls`
//     2 = claim + 1), pathsInterned 2, stepsPositioned 10. Every one unchanged.
//   * `sources/<tx>.json` — the bundle's `files` keys are the container's two interned
//     paths. Unchanged.
//
// So the writer moved two container versions and a `meta.dat` schema, and not one fact the
// 31 arms check moved with it. That is the separation the policy predicts: the recording is
// committable, the container is not.
//
// ONE FIGURE DOES CROSS THE LINE AND IS NOT HIDDEN: `snapshot.json`'s `containerBytes`, which
// `S5-CONTAINER-BYTES` requires to equal the file's size on disk. It is a property of the
// writer's LAYOUT and not of the recording — the same recording is 151,552 bytes at the old
// revision and 77,824 at the current one, a 48.6% change in which no step, path or call
// moved. It stays committed, because the alternative is a generated `snapshot.json`, which
// would take the tree out of `git ls-files` and therefore out of `corpusSnapshotDirs()`, the
// committed reading and `refusal-selftest`'s snapshot census — four declared populations
// moved to avoid carrying one integer. The selftest ASSERTS the regenerated container's size
// against it, so the one residual is a red gate with the two figures in the message rather
// than a silent skew.
//
// ── THE SIZE IS REPRODUCIBLE AND THE BYTES ARE NOT, AND BOTH WERE MEASURED ────────────
//
// Two runs of the generator at the same revision: 77,824 bytes both times, differing in
// exactly 19 bytes at offsets 49,177..49,200 — the time-based uuid inside `meta.dat`'s
// recording id, and nothing else. The committed `snapshot.json` carries no container hash
// (only `containerBytes`), so byte-irreproducibility costs nothing here. The old MAKING.md
// gave irreproducibility as the reason the container was vendored rather than generated at
// test time; the measurement says the irreproducibility is 19 bytes of uuid and the size is
// stable, so it was never a reason not to generate.
//
// ── THREE STATES, NEVER TWO (CRR-3) ───────────────────────────────────────────────────
//
//   | state                            | exit | what a caller does                        |
//   |----------------------------------|------|-------------------------------------------|
//   | the sibling is not checked out   |  2   | SKIP, naming what is missing              |
//   | it is here and would not produce |  1   | FAIL — this is a break, not an absence    |
//   | it produced the container        |  0   | assert the content                        |
//
// Exit 2 and exit 1 are the two halves `existsSync` used to collapse, which is how a product
// break came to read as a green run. Exit 2 is the state CI is in: `codetracer-trace-format-nim`
// is not a dependency of this repository and is not built here.
//
// ── THE CACHE, AND WHY IT IS DATED AGAINST THE SIBLING'S WHOLE `src/` ─────────────────
//
// Ported from `codetracer-trace-format-nim/tests/ct_print_binary.nim`, whose own header says
// why: the generator is a thin front end over the WRITER library, so nearly everything it
// can get wrong lives in a module other than its own source. A binary dated against
// `generate_ct_print_fixture.nim` alone answers "fresh" for a build that predates a writer
// change, and the arms then measure a container no revision in the tree produces — which is
// the identical defect `chain-health-selftest.mjs`'s own backlog records for
// `m1_ctprint_build.nim`.
//
// The binary lives OUTSIDE both repositories so it survives between runs and branches.
//
// ── COST PER RUN, MEASURED ────────────────────────────────────────────────────────────
//
//   | step                                    | wall  |
//   |-----------------------------------------|-------|
//   | the generator binary is fresh: generate | 0.2 s |
//   | it is stale: `nix develop` + `nim c`    |  30 s |
//
// The build needs the sibling's own devshell (a plain `nim c` fails on `zstd.h`, and
// `pkg-config` is not on PATH outside it, so `ct_print_binary.nim`'s pkg-config route is not
// available from here). RUNNING the built binary does not: it is linked and runs outside the
// shell, which is what keeps the steady-state cost at 0.2 s.

import { existsSync, mkdirSync, statSync, readdirSync, readFileSync, renameSync, rmSync }
  from 'node:fs';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = join(HERE, '..', '..');

/** The sibling checkout that owns the writer AND the generator. */
export const SIBLING = join(REPO_ROOT, '..', 'codetracer-trace-format-nim');
const GEN_SRC = join(SIBLING, 'tests', 'generate_ct_print_fixture.nim');
const GEN_BIN = '/tmp/bt-readable-container/generate_ct_print_fixture';

/** The subject tree, and the container the committed `snapshot.json` names. */
export const SUBJECT = join(REPO_ROOT, 'fixtures', 'chain-health', 'readable-container');
const SNAPSHOT = join(SUBJECT, 'snapshot.json');

/** The newest mtime under the sibling's `src/`, plus the generator's own source. */
const newestSourceTime = () => {
  let newest = statSync(GEN_SRC).mtimeMs;
  const walk = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.nim')) {
        const t = statSync(p).mtimeMs;
        if (t > newest) newest = t;
      }
    }
  };
  walk(join(SIBLING, 'src'));
  return newest;
};

/** `{ state, reason, path?, bytes?, declaredBytes?, built? }` — see the table above. */
export function makeReadableContainer({ check = false } = {}) {
  // ── absent: the sibling, or the generator inside it ────────────────────────────────
  if (!existsSync(SIBLING)) {
    return { state: 'absent', reason: `the sibling checkout is not here (${SIBLING})` };
  }
  if (!existsSync(GEN_SRC)) {
    // PRESENT BUT WITHOUT THE GENERATOR IS A FAILURE, NOT AN ABSENCE. The sibling is
    // checked out; a revision of it that has dropped the generator this subject is made
    // by is a break in the seam, and the remedy is to find what replaced it rather than
    // to check anything out.
    return { state: 'failed',
             reason: `${SIBLING} is checked out and carries no ${GEN_SRC.slice(SIBLING.length + 1)} `
                   + '— the generator this subject is recorded by has moved or gone' };
  }

  const snap = JSON.parse(readFileSync(SNAPSHOT, 'utf8'));
  const row = snap.transactions[0];
  const out = join(SUBJECT, row.container);
  const declaredBytes = row.containerBytes;

  // ── the cache chain: sibling sources -> binary -> container ───────────────────────
  const srcTime = newestSourceTime();
  const binFresh = existsSync(GEN_BIN) && statSync(GEN_BIN).mtimeMs >= srcTime;
  const ctFresh = binFresh && existsSync(out)
                && statSync(out).mtimeMs >= statSync(GEN_BIN).mtimeMs;
  if (ctFresh) {
    return { state: 'ready', reason: 'the container is already recorded at this revision',
             path: out, bytes: statSync(out).size, declaredBytes, built: false };
  }
  if (check) {
    return { state: 'stale', path: out, declaredBytes,
             reason: binFresh ? 'the container needs recording' : 'the generator needs building' };
  }

  // ── build, in the sibling's OWN devshell ───────────────────────────────────────────
  if (!binFresh) {
    mkdirSync(dirname(GEN_BIN), { recursive: true });
    const nimc = `nim c -d:release --mm:arc -p:src --hints:off --warnings:off `
               + `-o:${GEN_BIN} tests/generate_ct_print_fixture.nim`;
    const b = spawnSync('nix', ['develop', '--command', 'bash', '-c', nimc],
                        { cwd: SIBLING, encoding: 'utf8', timeout: 1_800_000 });
    if (b.error) {
      return { state: 'failed',
               reason: `could not run \`nix develop\` in ${SIBLING}: ${b.error.message}` };
    }
    if (b.status !== 0 || !existsSync(GEN_BIN)) {
      const said = `${b.stderr || ''}${b.stdout || ''}`.trim().split('\n').slice(-6).join('\n    ');
      return { state: 'failed',
               reason: `building the fixture generator in ${SIBLING} exited ${b.status}:\n    ${said}` };
    }
  }

  // ── record ─────────────────────────────────────────────────────────────────────────
  //
  // Into a temp path and then renamed, so a generator that fails half way through cannot
  // leave a short container behind for the next run's freshness check to accept.
  mkdirSync(dirname(out), { recursive: true });
  const tmp = `${out}.recording`;
  try { rmSync(tmp, { force: true }); } catch { /* best effort */ }
  const g = spawnSync(GEN_BIN, [tmp], { encoding: 'utf8', timeout: 600_000 });
  if (g.error || g.status !== 0 || !existsSync(tmp)) {
    try { rmSync(tmp, { force: true }); } catch { /* best effort */ }
    const said = g.error ? g.error.message
                         : `${g.stderr || ''}${g.stdout || ''}`.trim().split('\n').slice(-4).join(' ');
    return { state: 'failed', reason: `the fixture generator exited ${g.status}: ${said}` };
  }
  renameSync(tmp, out);
  return { state: 'ready', reason: 'the container was recorded by the current writer',
           path: out, bytes: statSync(out).size, declaredBytes, built: true };
}

// ── the command ─────────────────────────────────────────────────────────────────────
if (process.argv[1] && process.argv[1].endsWith('make-readable-container.mjs')) {
  const check = process.argv.includes('--check');
  const r = makeReadableContainer({ check });
  switch (r.state) {
    case 'ready':
      console.error(`recorded: ${r.path}`);
      console.error(`  ${r.bytes} bytes (snapshot.json declares ${r.declaredBytes})`
                  + `${r.built ? ', generator rebuilt' : ', from cache'}`);
      // THE ONE FIGURE THAT CROSSES THE LINE IS CHECKED HERE TOO, so the command and the
      // selftest cannot disagree about whether the tree is conformant.
      if (r.bytes !== r.declaredBytes) {
        console.error(`FAIL: S5-CONTAINER-BYTES — the recorded container is ${r.bytes} bytes and `
                    + `fixtures/chain-health/readable-container/snapshot.json declares `
                    + `containerBytes ${r.declaredBytes}. The writer's layout moved; update that `
                    + `one field and say so, do not widen anything.`);
        process.exit(1);
      }
      process.exit(0);
    case 'stale':
      console.error(`NOT RECORDED (--check): ${r.reason}`);
      process.exit(0);
    case 'absent':
      console.error(`SKIP: ${r.reason}`);
      console.error('  the 31 reader-dependent arms of chain-health-selftest.mjs cannot run '
                  + 'here. This is an absence, not a failure.');
      process.exit(2);
    default:
      console.error(`FAIL: ${r.reason}`);
      process.exit(1);
  }
}
