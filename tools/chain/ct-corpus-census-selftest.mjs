#!/usr/bin/env node
// The committed population can be empty while every detector must still bite.
// Compare the real Git census to its reading, then test comparison fields over
// an explicitly constructed positive census. That JSON models reader results;
// it is not evidence of readability. A separate actual-reader configuration
// prepares a genuine Noir recording and drives askReader through census over a
// disposable Git index, including a version-mutated refusal. The first Git index
// contains header-only identity subjects and a labeled ASCII placeholder; it
// exercises classification and byte identity without pretending to execute them.
import { census, compare, loadRegistry, findReader, requireReader, trackedCtPaths,
  readIdentity, REPO_ROOT } from './ct-corpus-census.mjs';
import { readFileSync, writeFileSync, mkdirSync, mkdtempSync, chmodSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { prepareRecordings } from '../fixtures/prepare-recordings.mjs';

const BASE_ARMS = 20;
const READER_ARMS = 4;
const clone = (value) => structuredClone(value);
let pass = 0, fail = 0;
const ok = (what) => { pass++; console.log(`  ok    ${what}`); };
const bad = (what, detail) => { fail++; console.log(`  FAIL  ${what}: ${detail}`); };
const bite = (what, deltas, field) => {
  if (deltas.some((delta) => delta.what === field)) ok(`${what}: ${field}`);
  else bad(what, `no delta named ${field}; got ${deltas.map((delta) => delta.what).join(', ')}`);
};

export async function selftest() {
  const at = process.argv.indexOf('--reader');
  const reader = at >= 0 ? requireReader(process.argv[at + 1]) : findReader();
  const fixtureReader = at >= 0 ? reader
    : process.env.CT_FIXTURE_PRINT ? requireReader(process.env.CT_FIXTURE_PRINT) : null;
  const reading = JSON.parse(readFileSync(join(REPO_ROOT, 'tools/chain/measurements/ct-corpus.json'), 'utf8'));
  const current = census({ reader });
  const actualDeltas = compare(reading, current);
  if (!actualDeltas.length) ok('real Git population agrees with the committed reading');
  else bad('real Git population', JSON.stringify(actualDeltas));

  const root = mkdtempSync(join(tmpdir(), 'ct-census-git-'));
  try {
    const git = (...args) => {
      const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
      if (result.status !== 0) throw new Error(result.stderr);
    };
    git('init', '--quiet');
    const header = (version) => Buffer.from([0xc0, 0xde, 0x72, 0xac, 0xe2, version]);
    const subjects = [
      ['fixtures/trace/tour/header.ct', header(6)],
      ['fixtures/trace/noir_space_ship/header.ct', header(6)],
      ['client/fixtures/chain/aztec-testnet/ct/header.ct', header(3)],
      ['conformance-kit/template/complete/ct/placeholder.ct', Buffer.from('explicit ASCII placeholder')],
    ];
    for (const [path, bytes] of subjects) {
      mkdirSync(dirname(join(root, path)), { recursive: true });
      writeFileSync(join(root, path), bytes);
      git('add', '--', path);
    }
    const registry = loadRegistry();
    const indexed = census({ root, reader: null, registry });
    const positive = clone(indexed);
    positive.readerPresent = true; // Deliberate comparison input, not an executed reader.
    positive.totals.readable = 2;
    for (const pop of positive.populations) {
      pop.readable = pop.id.startsWith('noir/') ? pop.containers : 0;
      pop.refusals = pop.id === 'chain/aztec-testnet' ? { 'container-version-3': 1 } : {};
    }
    if (!compare(positive, positive).length) ok('positive non-empty comparison input agrees with itself');
    else bad('positive comparison base', 'a matching non-empty census was refused');

    const version = clone(positive);
    version.populations.find((p) => p.id === 'noir/capability-tour').versions = { v4: 1 };
    bite('version movement', compare(version, positive), 'noir/capability-tour.versions.v4');
    const readability = clone(positive);
    readability.populations.find((p) => p.id === 'noir/capability-tour').readable = 0;
    bite('readability movement', compare(readability, positive), 'noir/capability-tour.readable');
    const size = clone(positive);
    size.totals.trackedPaths--;
    bite('population growth', compare(size, positive), 'totals.trackedPaths');
    const producer = clone(positive);
    producer.populations.find((p) => p.id === 'noir/space-ship').producer = 'wrong producer';
    bite('producer attribution', compare(producer, positive), 'noir/space-ship.producer');
    const refusal = clone(positive);
    refusal.populations.find((p) => p.id === 'chain/aztec-testnet').refusals = { 'meta.dat-schema-3': 1 };
    bite('refusal field', compare(refusal, positive), 'chain/aztec-testnet.refusals.container-version-3');
    const narrowed = clone(registry);
    narrowed.populations = narrowed.populations.filter((p) => p.id !== 'noir/space-ship');
    bite('unclassified tracked path', compare(indexed, census({ root, reader: null, registry: narrowed })), 'unclassified paths');
    const paths = trackedCtPaths(root);
    const ct = readIdentity(join(root, paths.find((p) => p.startsWith('fixtures/trace/tour/'))));
    const ph = readIdentity(join(root, paths.find((p) => p.startsWith('conformance-kit/'))));
    if (ct.container && ct.version === 6 && !ph.container && ph.reason === 'no CTFS magic') {
      ok('identity is read from actual indexed header and placeholder bytes');
    } else bad('byte identity', JSON.stringify({ ct, ph }));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
  const missing = spawnSync(process.execPath,
    [join(REPO_ROOT, 'tools/chain/ct-corpus-census.mjs'), '--reader', '/nonexistent-reader'],
    { encoding: 'utf8' });
  const said = `${missing.stdout ?? ''}${missing.stderr ?? ''}`;
  if (missing.status === 1 && /--reader \/nonexistent-reader does not exist/.test(said)
      && /not a NOT MEASURED/.test(said)) ok('a named missing reader refuses by name');
  else bad('named missing reader', `exit ${missing.status}: ${said}`);
  if (fixtureReader) {
    // This is a genuine producer invocation, not fabricated readable JSON or a
    // stand-in reader. Only the refused copy's container version is corrupted.
    prepareRecordings({ producer: 'noir' });
    const root = mkdtempSync(join(tmpdir(), 'ct-census-real-reader-'));
    try {
      const git = (...args) => {
        const result = spawnSync('git', args, { cwd: root, encoding: 'utf8' });
        if (result.status !== 0) throw new Error(result.stderr);
      };
      git('init', '--quiet');
      const actual = readFileSync(join(REPO_ROOT, 'fixtures/trace/tour/values/tour_values.ct'));
      const refused = Buffer.from(actual);
      refused[5] = 3;
      for (const [path, bytes] of [
        ['fixtures/trace/tour/values.ct', actual],
        ['client/fixtures/chain/aztec-testnet/ct/version3.ct', refused],
        ['conformance-kit/template/complete/ct/placeholder.ct', Buffer.from('explicit ASCII placeholder')],
      ]) {
        mkdirSync(dirname(join(root, path)), { recursive: true });
        writeFileSync(join(root, path), bytes);
        git('add', '--', path);
      }
      const measured = census({ root, reader: fixtureReader, registry: loadRegistry() });
      const noir = measured.populations.find((p) => p.id === 'noir/capability-tour');
      const aztec = measured.populations.find((p) => p.id === 'chain/aztec-testnet');
      if (measured.totals.trackedPaths === 3 && measured.totals.containers === 2
          && measured.totals.notContainers === 1 && measured.totals.readable === 1
          && noir.readable === 1) ok('actual reader opens the genuine indexed Noir recording');
      else bad('actual reader readability', JSON.stringify(measured));
      if (aztec.readable === 0 && aztec.refusals['container-version-3'] === 1) {
        ok('actual reader refusal is attributed to container version3');
      } else bad('actual reader refusal attribution', JSON.stringify(aztec));
      const readableMoved = clone(measured);
      readableMoved.populations.find((p) => p.id === noir.id).readable = 0;
      bite('actual reader readability movement', compare(readableMoved, measured), `${noir.id}.readable`);
      const refusalMoved = clone(measured);
      refusalMoved.populations.find((p) => p.id === aztec.id).refusals = { 'meta.dat-schema-3': 1 };
      bite('actual reader refusal movement', compare(refusalMoved, measured), `${aztec.id}.refusals.container-version-3`);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  } else {
    console.log(`NOT MEASURED: ${READER_ARMS} actual-reader integration arms require CT_FIXTURE_PRINT (or --reader) and the pinned Noir producer environment`);
  }
  // Reader discovery uses real filesystem trees. The executable placeholders
  // below are never run: this tests which path is selected, not container parsing.
  // An outer reader recreates the stale-build trap independently of host layout.
  {
    const scratch = mkdtempSync(join(tmpdir(), 'ct-corpus-reader-'));
    const saved = process.env.CT_PRINT;
    const expectReader = (what, root, want) => {
      const got = findReader(root);
      if (got === want) ok(what);
      else bad(what, `expected ${JSON.stringify(want)}, got ${JSON.stringify(got)}`);
    };
    const readerAt = (dir) => {
      const path = join(dir, 'codetracer-trace-format-nim', 'ct-print');
      mkdirSync(join(dir, 'codetracer-trace-format-nim'), { recursive: true });
      writeFileSync(path, '#!/bin/sh\nexit 1\n', { mode: 0o755 });
      return path;
    };
    try {
      delete process.env.CT_PRINT;
      const workspace = join(scratch, 'workspace');
      const repo = join(workspace, 'blocktracer');
      mkdirSync(repo, { recursive: true });
      writeFileSync(join(workspace, 'repro-workspace.toml'), '');
      const outer = readerAt(scratch);
      expectReader('reader discovery stops at the workspace instead of selecting an ancestor build', repo, null);
      expectReader('starting at the workspace root still respects its boundary', workspace, null);
      const sibling = readerAt(workspace);
      expectReader('the workspace root itself is searched for a sibling reader', repo, sibling);
      const local = readerAt(repo);
      expectReader('the nearest reader inside the workspace wins', repo, local);
      chmodSync(local, 0o644);
      expectReader('a non-executable candidate falls back to the workspace sibling', repo, sibling);
      const nested = join(repo, 'nested');
      mkdirSync(nested);
      writeFileSync(join(nested, 'repro-workspace.toml'), '');
      expectReader('the nearest workspace boundary excludes a containing workspace reader', nested, null);
      const standalone = join(scratch, 'standalone', 'blocktracer');
      mkdirSync(standalone, { recursive: true });
      const standaloneSibling = readerAt(join(scratch, 'standalone'));
      expectReader('a standalone checkout can discover its immediate sibling reader', standalone, standaloneSibling);
      rmSync(standaloneSibling);
      expectReader('a standalone checkout never searches beyond its immediate parent', standalone, null);
      process.env.CT_PRINT = outer;
      expectReader('CT_PRINT explicitly selects an outside reader ahead of local discovery', repo, outer);
      process.env.CT_PRINT = join(scratch, 'missing-reader');
      expectReader('a missing CT_PRINT retains automatic workspace discovery', repo, sibling);
    } finally {
      if (saved === undefined) delete process.env.CT_PRINT;
      else process.env.CT_PRINT = saved;
      rmSync(scratch, { recursive: true, force: true });
    }
  }


  const ran = pass + fail;
  const expected = BASE_ARMS + (fixtureReader ? READER_ARMS : 0);
  if (ran !== expected) { fail++; console.log(`  FAIL arm count: ${ran}, declared ${expected}`); }
  console.log(`self-test: ${fail ? 'FAIL' : 'PASS'} — ${pass} ok, ${fail} failing; ${BASE_ARMS} host-independent arms${fixtureReader ? ` + ${READER_ARMS} actual-reader arms` : ''}`);
  return fail ? 1 : 0;
}
if (import.meta.url === `file://${process.argv[1]}`) process.exit(await selftest());
