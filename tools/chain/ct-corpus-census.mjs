#!/usr/bin/env node
// ct-corpus-census.mjs — what this repository's COMMITTED `.ct` corpus is, by
// population, and whether a current reader opens it.
//
// Usage:
//   node tools/chain/ct-corpus-census.mjs                      # report
//   node tools/chain/ct-corpus-census.mjs --expect <file>       # compare + gate
//   node tools/chain/ct-corpus-census.mjs --json
//   node tools/chain/ct-corpus-census.mjs --selftest
//   node tools/chain/ct-corpus-census.mjs --reader <path-to-ct-print>
//
// ── WHY THIS EXISTS, AND IT IS A DEFECT THIS REPOSITORY'S OWN HISTORY SHOWS ──
//
// The committed `.ct` corpus has been censused BY HAND three times, and the
// hand census was wrong twice:
//
//   * `codetracer-specs`' `CTFS-Reader-Revision-Rollout` CRR-1 counted "78
//     committed containers, 51 at container version 3 and 26 at version 4, 77
//     of 78 carrying `meta.dat` schema 3". There are 55 tracked `.ct` PATHS.
//     The 78 came from a `find`, which counts generated artifacts — published
//     containers under `client/dist/`, the `conformance-kit-release/` copies of
//     the template placeholders — and the word the finding used was
//     "committed".
//   * CRR-4 corrected the population to 55/52/42/10 and then described all 52
//     as "real chain recordings, published artefacts" whose remedy needs "a
//     node, a replay driver and `aztec_ct_writer.wasm` from a checkout that is
//     not in this workspace". Ten of them are not chain recordings at all:
//     they are `nargo trace` recordings of local Noir packages whose sources
//     are vendored beside them and whose re-record command is committed. The
//     split is visible in the version byte — every chain recording was at
//     container version 3 and every `nargo trace` one at 4 — and a census that
//     grouped by PRODUCER would have shown it.
//
// A paragraph cannot hold a number that moves. So the census is a committed
// READING plus a checker, and a corpus change that does not update the reading
// is a red gate naming every delta — the same shape
// `tools/chain/measurements/chain-health.json` already uses for the chain
// snapshots, applied to the population it does not cover.
//
// ── WHAT IT DOES NOT COVER, SAID RATHER THAN IMPLIED ────────────────────────
//
// `chain-health.mjs --corpus` sweeps the chain SNAPSHOT directories, selected
// by `corpusSnapshotDirs()`. `fixtures/trace/` carries no `snapshot.json`, so
// those ten containers are outside that sweep entirely — measured: the ten were
// re-recorded from container version 4 to version 5 and
// `just chain-health-check` reported "unchanged from it", correctly, because
// they are not its subject. This tool's subject is every TRACKED `.ct` path and
// nothing else: not `client/dist/`, not `conformance-kit-release/`, not an
// untracked working copy. `git ls-files` is the population, which is what the
// word "committed" means.
//
// ── POPULATIONS ARE DECLARED, NOT INFERRED ─────────────────────────────────
//
// `ct-corpus.json` names each population, the producer that writes it and the
// remedy when it goes stale. A path that matches no population is a FAILURE and
// not a silent "other": a new corpus arriving unclassified is exactly how the
// hand censuses went wrong, and a tool that swept it into a leftover bucket
// would repeat that.
//
// ── THE READER IS THREE-STATE, NOT TWO ─────────────────────────────────────
//
// CRR-3's rule, which this repository applies everywhere a reader is optional:
//
//   reader not found                      -> exit 2, SKIP; readability is
//                                            reported NOT MEASURED and the
//                                            version census still runs, because
//                                            it is read from the bytes
//   reader found, a reading disagrees      -> exit 1, FAIL
//   reader found, every reading agrees     -> exit 0
//
// A refusal is not an error here. The 42 chain recordings are EXPECTED to be
// refused at `meta.dat` schema 3, the committed reading says so by name, and a
// chain recording that suddenly opened would be as much a skew as one of the
// ten that stopped opening.

import { readFileSync, existsSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HERE, '..', '..');
const REGISTRY = join(HERE, 'ct-corpus.json');

/** The CTFS container magic — five bytes, so the version is byte 5. */
export const CTFS_MAGIC = Uint8Array.from([0xc0, 0xde, 0x72, 0xac, 0xe2]);

/** Every TRACKED `.ct` path, repo-relative, sorted. `git ls-files` IS the population. */
export function trackedCtPaths(root = REPO_ROOT) {
  const out = execFileSync('git', ['-C', root, 'ls-files', '*.ct'], { encoding: 'utf8' });
  return out.split('\n').map((s) => s.trim()).filter(Boolean).sort();
}

/**
 * Read a path's container identity FROM THE BYTES — no reader involved, so this
 * half is measurable on every host.
 *
 * A path with no magic is not a container and is reported as such rather than
 * as a container of version 0: the conformance kit ships three 229-byte ASCII
 * placeholders on purpose, and calling them broken containers would make a
 * deliberate fixture look like a defect.
 */
export function readIdentity(abs) {
  const bytes = readFileSync(abs);
  const size = bytes.length;
  if (size < 6) return { container: false, reason: 'shorter than a header', size };
  for (let i = 0; i < CTFS_MAGIC.length; i++) {
    if (bytes[i] !== CTFS_MAGIC[i]) return { container: false, reason: 'no CTFS magic', size };
  }
  return { container: true, version: bytes[5], size };
}

/**
 * Ask the reader to open a container.
 *
 * `--summary` rather than `--full`: the question is whether the bundle opens,
 * and decoding every value to answer it would make this sweep cost time
 * proportional to the corpus's content instead of its size.
 *
 * The SCHEMA a refusal names is extracted and kept, because "refused" and
 * "refused on `meta.dat` schema 3" are different facts and the second is the
 * one the campaign turns on.
 */
export function askReader(reader, abs) {
  let rc = 0, text = '';
  try {
    text = execFileSync(reader, ['--summary', abs], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    rc = typeof e.status === 'number' ? e.status : 1;
    text = `${e.stdout ?? ''}${e.stderr ?? ''}`;
  }
  // Read from a NUL-stripped copy: this reader writes NULs into its diagnostics
  // and a bare match against the raw buffer misses the sentence after one.
  const clean = text.replace(/\0/g, '');
  if (rc === 0) return { opened: true };
  const schema = clean.match(/schema version (\d+) is not supported/);
  const version = clean.match(/container version (\d+)/);
  return {
    opened: false,
    rc,
    refusedOn: schema ? 'meta.dat-schema' : version ? 'container-version' : 'other',
    refusedValue: schema ? Number(schema[1]) : version ? Number(version[1]) : null,
    message: clean.split('\n').find((l) => l.trim().length > 0)?.trim() ?? '',
  };
}

/** Find `ct-print` by walking up to the sibling checkout, the way the other tools do. */
export function findReader(root = REPO_ROOT) {
  if (process.env.CT_PRINT && existsSync(process.env.CT_PRINT)) return process.env.CT_PRINT;
  let dir = root;
  for (;;) {
    const p = join(dir, 'codetracer-trace-format-nim', 'ct-print');
    if (existsSync(p)) {
      try { if (statSync(p).mode & 0o111) return p; } catch { /* not executable */ }
    }
    const up = dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

export function loadRegistry(file = REGISTRY) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

/** Which declared population owns a path. Exactly one must, and that is checked. */
export function classify(registry, path) {
  const hits = registry.populations.filter((p) => p.paths.some((pre) => path.startsWith(pre)));
  return hits;
}

/**
 * The census. `reader` may be null, in which case readability is NOT MEASURED
 * and `readerPresent` says so — the version half is still a measurement.
 */
export function census({ root = REPO_ROOT, registry = loadRegistry(), reader = null } = {}) {
  const paths = trackedCtPaths(root);
  const rows = [];
  const unclassified = [];
  const ambiguous = [];
  for (const path of paths) {
    const hits = classify(registry, path);
    if (hits.length === 0) { unclassified.push(path); continue; }
    if (hits.length > 1) { ambiguous.push({ path, populations: hits.map((h) => h.id) }); continue; }
    const id = readIdentity(join(root, path));
    // The reader is asked only about CONTAINERS. A 229-byte ASCII placeholder
    // is refused for having no magic, which is correct and says nothing about
    // the corpus's revision — counting it beside the schema refusals would put
    // a deliberate fixture in the same column as a stale recording.
    const read = reader && id.container ? askReader(reader, join(root, path)) : null;
    rows.push({ path, population: hits[0].id, ...id, read });
  }
  const populations = registry.populations.map((p) => {
    const mine = rows.filter((r) => r.population === p.id);
    const versions = {};
    for (const r of mine) {
      const key = r.container ? `v${r.version}` : 'not-a-container';
      versions[key] = (versions[key] ?? 0) + 1;
    }
    const containers = mine.filter((r) => r.container).length;
    const readable = reader ? mine.filter((r) => r.read?.opened).length : null;
    const refusals = {};
    if (reader) {
      for (const r of mine) {
        if (r.read && !r.read.opened) {
          const key = r.read.refusedOn === 'meta.dat-schema'
            ? `meta.dat-schema-${r.read.refusedValue}`
            : r.read.refusedOn === 'container-version'
            ? `container-version-${r.read.refusedValue}`
            : 'other';
          refusals[key] = (refusals[key] ?? 0) + 1;
        }
      }
    }
    return {
      id: p.id, producer: p.producer, paths: mine.length, containers,
      versions: sortedKeys(versions), readable, refusals: reader ? sortedKeys(refusals) : null,
    };
  });
  const containers = rows.filter((r) => r.container);
  return {
    readerPresent: Boolean(reader),
    reader: reader ?? null,
    totals: {
      trackedPaths: paths.length,
      containers: containers.length,
      notContainers: rows.length - containers.length,
      readable: reader ? rows.filter((r) => r.read?.opened).length : null,
    },
    containerVersions: sortedKeys(countBy(containers, (r) => `v${r.version}`)),
    populations,
    unclassified,
    ambiguous,
    rows,
  };
}

const countBy = (xs, f) => xs.reduce((a, x) => ((a[f(x)] = (a[f(x)] ?? 0) + 1), a), {});
const sortedKeys = (o) => Object.fromEntries(Object.entries(o).sort(([a], [b]) => a.localeCompare(b)));

/**
 * Compare a census against a committed reading. Returns the list of deltas,
 * each NAMED — "42 became 41" is actionable and "the census changed" is not.
 *
 * Readability is compared only when the reader was present, and the skip is
 * reported rather than silently treated as agreement.
 */
export function compare(expected, actual) {
  const deltas = [];
  const d = (what, want, got) => { if (want !== got) deltas.push({ what, expected: want, actual: got }); };

  d('totals.trackedPaths', expected.totals.trackedPaths, actual.totals.trackedPaths);
  d('totals.containers', expected.totals.containers, actual.totals.containers);
  d('totals.notContainers', expected.totals.notContainers, actual.totals.notContainers);
  for (const k of new Set([...Object.keys(expected.containerVersions), ...Object.keys(actual.containerVersions)])) {
    d(`containerVersions.${k}`, expected.containerVersions[k] ?? 0, actual.containerVersions[k] ?? 0);
  }
  const byId = (xs) => new Map(xs.map((p) => [p.id, p]));
  const [ep, ap] = [byId(expected.populations), byId(actual.populations)];
  for (const id of new Set([...ep.keys(), ...ap.keys()])) {
    const e = ep.get(id), a = ap.get(id);
    if (!e) { deltas.push({ what: `population ${id}`, expected: 'not declared in the reading', actual: 'present' }); continue; }
    if (!a) { deltas.push({ what: `population ${id}`, expected: 'present', actual: 'gone from the tree' }); continue; }
    d(`${id}.paths`, e.paths, a.paths);
    d(`${id}.containers`, e.containers, a.containers);
    d(`${id}.producer`, e.producer, a.producer);
    for (const k of new Set([...Object.keys(e.versions), ...Object.keys(a.versions)])) {
      d(`${id}.versions.${k}`, e.versions[k] ?? 0, a.versions[k] ?? 0);
    }
    if (actual.readerPresent) {
      d(`${id}.readable`, e.readable, a.readable);
      for (const k of new Set([...Object.keys(e.refusals ?? {}), ...Object.keys(a.refusals ?? {})])) {
        d(`${id}.refusals.${k}`, (e.refusals ?? {})[k] ?? 0, (a.refusals ?? {})[k] ?? 0);
      }
    }
  }
  if (actual.readerPresent) d('totals.readable', expected.totals.readable, actual.totals.readable);
  if (actual.unclassified.length) {
    deltas.push({
      what: 'unclassified paths',
      expected: 'every tracked .ct belongs to a declared population',
      actual: actual.unclassified.join(', '),
    });
  }
  for (const a of actual.ambiguous) {
    deltas.push({ what: `ambiguous path ${a.path}`, expected: 'exactly one population', actual: a.populations.join(' + ') });
  }
  return deltas;
}

export function render(c) {
  const L = [];
  L.push(`tracked .ct paths: ${c.totals.trackedPaths}  containers: ${c.totals.containers}  not containers: ${c.totals.notContainers}`);
  L.push(`container versions: ${Object.entries(c.containerVersions).map(([k, v]) => `${k}=${v}`).join(' ')}`);
  if (c.readerPresent) L.push(`readable by ${c.reader}: ${c.totals.readable} of ${c.totals.containers}`);
  else L.push('readable: NOT MEASURED — no container reader found (set CT_PRINT= or --reader)');
  L.push('');
  for (const p of c.populations) {
    const v = Object.entries(p.versions).map(([k, n]) => `${k}=${n}`).join(' ');
    const r = p.readable === null ? 'NOT MEASURED' : `${p.readable}/${p.containers}`;
    L.push(`${p.id.padEnd(28)} ${String(p.paths).padStart(3)} path(s)  ${v.padEnd(16)} readable ${r}`);
    L.push(`${''.padEnd(28)} producer: ${p.producer}`);
    if (p.refusals && Object.keys(p.refusals).length) {
      L.push(`${''.padEnd(28)} refused on: ${Object.entries(p.refusals).map(([k, n]) => `${k} x${n}`).join(', ')}`);
    }
  }
  return L.join('\n');
}

// ── the driver ─────────────────────────────────────────────────────────────

if (import.meta.url === `file://${process.argv[1]}`) {
  const argv = process.argv.slice(2);
  const arg = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d; };
  if (argv.includes('--selftest')) {
    // SPAWNED, not imported. The selftest imports this module for `census`,
    // `compare` and the identity readers, so a dynamic import from inside this
    // module's own top-level await closes a cycle: node reports
    // "Detected unsettled top-level await" and the process exits having run
    // nothing. Measured, not theorised — that is what the first version did.
    // A child process has one direction of dependency and therefore no cycle.
    try {
      execFileSync(process.execPath, [join(HERE, 'ct-corpus-census-selftest.mjs')], { stdio: 'inherit' });
      process.exit(0);
    } catch (e) {
      process.exit(typeof e.status === 'number' ? e.status : 1);
    }
  }
  const reader = arg('reader', findReader());
  const c = census({ reader });
  if (argv.includes('--json')) {
    // Three fields are dropped, and each for its own reason:
    //
    //   `rows`         the working set, not the reading. One entry per container
    //                  would make the committed reading churn on every byte.
    //   `reader`       an ABSOLUTE PATH on whoever ran it. A reading that
    //                  carried it would differ between two machines that agree
    //                  perfectly about the corpus.
    //   `readerPresent` a property of the RUN. The reading says what is true of
    //                  the corpus; whether this host could check the readability
    //                  half is reported by the run, not recorded in the reading.
    //
    // `readable` counts stay, because they ARE facts about the corpus — and on a
    // host with no reader the comparison skips them and says so rather than
    // treating absence as agreement.
    const { rows, reader, readerPresent, ...rest } = c;
    if (!readerPresent) {
      console.error('refusing to write a reading with no container reader: the `readable`');
      console.error('counts would all be null and the next comparison would have nothing to');
      console.error('check. Set CT_PRINT= or --reader and re-read.');
      process.exit(2);
    }
    console.log(JSON.stringify({
      _comment: [
        'THE COMMITTED READING of this repository\'s tracked `.ct` corpus. Generated —',
        'do not hand-edit. Re-read with:',
        '',
        '  node tools/chain/ct-corpus-census.mjs --json > tools/chain/measurements/ct-corpus.json',
        '',
        'and checked by `just ct-corpus-check`. A corpus change is allowed; a corpus change',
        'that leaves this file stale is a red gate naming every delta. The populations, their',
        'producers and the remedy for each are declared in `tools/chain/ct-corpus.json`.',
      ],
      ...rest,
    }, null, 2));
    process.exit(0);
  }
  console.log(render(c));
  const expectPath = arg('expect', null);
  if (!expectPath) process.exit(c.readerPresent ? 0 : 2);

  const expected = JSON.parse(readFileSync(expectPath, 'utf8'));
  const deltas = compare(expected, c);
  console.log('');
  if (deltas.length === 0) {
    console.log(`AGAINST ${expectPath}: the committed reading still describes this corpus`);
    if (!c.readerPresent) {
      console.log('  readability was NOT MEASURED on this host, so that half of the reading was not checked');
      process.exit(2);
    }
    process.exit(0);
  }
  console.log(`AGAINST ${expectPath}: ${deltas.length} delta(s) — the corpus moved and the reading did not`);
  for (const x of deltas) console.log(`  ${x.what}: reading says ${x.expected}, the tree says ${x.actual}`);
  console.log('');
  console.log('A corpus change is allowed; a corpus change with a stale reading is not.');
  console.log(`Re-read it with: node tools/chain/ct-corpus-census.mjs --json > ${expectPath}`);
  console.log('and say in the commit WHY each delta moved — which producer wrote the new bytes,');
  console.log('and whether a checked fact moved with them or only a derived one.');
  process.exit(1);
}
