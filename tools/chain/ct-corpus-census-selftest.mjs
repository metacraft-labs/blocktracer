#!/usr/bin/env node
// ct-corpus-census-selftest.mjs — does the census GATE decide, in both directions?
//
//   node tools/chain/ct-corpus-census.mjs --selftest
//
// A census that only ever reports is documentation. This suite is the evidence
// that it REFUSES, and that it refuses on each field independently rather than
// on one coarse "something changed".
//
// The comparison arms perturb the COMMITTED READING and leave the tree alone. That is
// the deliberate direction: mutating the corpus would mean writing containers,
// and a selftest that rewrites 52 committed files to prove a comparison works
// is a worse trade than one that rewrites a JSON object. The two are equivalent
// for this gate because `compare()` is a pure function of (reading, census) —
// which is why it is exported and called directly here instead of through the
// CLI.
//
// Arm 3 is the base case and it is not decoration: arms 1 and 2 prove that a
// WRONG reading fails, and without a third arm proving the RIGHT reading passes
// they would both be satisfied by a comparison that refuses everything.

import { census, compare, loadRegistry, findReader, requireReader, trackedCtPaths, readIdentity, REPO_ROOT } from './ct-corpus-census.mjs';
import { readFileSync, mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { join } from 'node:path';

// ── THE DECLARED ASSERTION COUNT, in the shape `chain-health-selftest.mjs`
// established and for its reason: this suite runs a different number of arms in
// each of two host configurations, because two of them need a container reader
// and the rest are read from the bytes. So it declares a host-independent BASE
// plus one figure per configuration, and checks the base plus the configuration
// it actually ran in. `refusal-selftest.mjs` cross-checks the BASE against
// `chain-selftest`'s header arithmetic — the only one of the three figures that
// is the same on every host, and therefore the only one a static check can
// state.
//
// A SUITE THAT RAN FEWER ARMS THAN IT DECLARES IS A FAILURE, not a quieter
// pass. An arm that silently stopped running is the failure mode a count exists
// to catch, and the two configurations are exactly where one could hide.
const BASE_ARMS = 17;
const READER_ARMS = 2;

let pass = 0, fail = 0;
const ok = (what) => { pass++; console.log(`  ok    ${what}`); };
const bad = (what, detail) => { fail++; console.log(`  FAIL  ${what}${detail ? ` — ${detail}` : ''}`); };
/** An arm that must BITE: the perturbation has to produce a delta naming `field`. */
const bite = (what, deltas, field) => {
  const hit = deltas.find((d) => d.what === field);
  if (hit) ok(`bite  ${what} — refused by name on \`${field}\``);
  else bad(`bite  ${what}`, `expected a delta on \`${field}\`, got ${deltas.length ? deltas.map((d) => d.what).join(', ') : 'none at all'}`);
};

const clone = (x) => JSON.parse(JSON.stringify(x));

export async function selftest() {
  console.log('self-test — the committed reading must refuse a corpus that moved, field by field');

  // `--reader` FIRST, then the sibling walk. The parent forwards the flag now;
  // without it this suite measured whichever `ct-print` the host had, which is
  // how its base case came to fail on a workstation and pass on CI.
  const argv = process.argv.slice(2);
  const i = argv.indexOf('--reader');
  const reader = (i >= 0 && i + 1 < argv.length) ? requireReader(argv[i + 1]) : findReader();
  const actual = census({ reader });
  const readingPath = join(REPO_ROOT, 'tools', 'chain', 'measurements', 'ct-corpus.json');
  const reading = JSON.parse(readFileSync(readingPath, 'utf8'));

  // ── arm 3 first, because the other two mean nothing without it ───────────
  const base = compare(reading, actual);
  if (base.length === 0) ok('arm 3 (base case): the committed reading describes the tree, so the arms below are not vacuous');
  else bad('arm 3 (base case): the committed reading does NOT describe the tree',
           base.map((d) => `${d.what}: reading ${d.expected} vs tree ${d.actual}`).join('; '));

  // ── arm 1: a container that moved version ───────────────────────────────
  {
    const r = clone(reading);
    const pop = r.populations.find((p) => p.id === 'noir/capability-tour');
    pop.versions = { v4: pop.containers };            // as if the tour were still at v4
    bite('a population whose container version moved', compare(r, actual), 'noir/capability-tour.versions.v4');
  }

  // ── arm 2: a container that stopped being readable ──────────────────────
  if (actual.readerPresent) {
    const r = clone(reading);
    const pop = r.populations.find((p) => p.id === 'noir/capability-tour');
    pop.readable = 0;
    bite('a population whose readability moved', compare(r, actual), 'noir/capability-tour.readable');
  } else {
    console.log('  SKIP  arm 2 (readability) — no container reader on this host; it is NOT counted as passed');
  }

  // ── arm 4: a corpus that GREW, which is the delta a `.ct` ban should catch
  // first but which must also be visible here if one ever lands another way ─
  {
    const r = clone(reading);
    r.totals.trackedPaths -= 1;
    r.totals.containers -= 1;
    bite('a corpus that grew by one container', compare(r, actual), 'totals.trackedPaths');
  }

  // ── arm 5: a producer re-attributed. The producer field is what decides the
  // REMEDY, so a reading that silently disagreed about it would send the next
  // reader to the wrong repository — which is the exact defect this tool exists
  // to stop (CRR-4 attributed ten `nargo trace` recordings to a chain producer).
  {
    const r = clone(reading);
    const pop = r.populations.find((p) => p.id === 'noir/space-ship');
    pop.producer = 'aztec-avm-runtime replay + aztec_ct_writer.wasm (NOT in this workspace)';
    bite('a population re-attributed to the wrong producer', compare(r, actual), 'noir/space-ship.producer');
  }

  // ── arm 6: a refusal that changed FIELD. "refused" and "refused on container
  // version 3" are different facts, and the campaign turns on the second: a
  // chain container refused on its `meta.dat` SCHEMA instead would mean a
  // different reader or different bytes.
  //
  // THE PERTURBATION WAS THE TRUTH FOR A WHILE. It used to set
  // `container-version-3` and expect a delta, which worked only while the
  // committed reading said `meta.dat-schema-3`. That label was itself stale —
  // it came from a `ct-print` older than `pins.json`'s own — and correcting the
  // reading on 2026-10-14 made this arm's mutation a no-op: "expected a delta
  // on `chain/aztec-testnet.refusals.container-version-3`, got none at all".
  // A bite arm must perturb AWAY from whatever the reading says, so it now
  // writes the label that is wrong today.
  if (actual.readerPresent) {
    const r = clone(reading);
    const pop = r.populations.find((p) => p.id === 'chain/aztec-testnet');
    pop.refusals = { 'meta.dat-schema-3': pop.containers };
    bite('a refusal attributed to the meta.dat schema instead of the container version',
         compare(r, actual), 'chain/aztec-testnet.refusals.container-version-3');
  } else {
    console.log('  SKIP  arm 6 (refusal field) — no container reader on this host; it is NOT counted as passed');
  }

  // ── arm 7: every tracked path must be classified, and the registry is what
  // classifies it. An unclassified path is the failure mode the hand censuses
  // had, so the refusal is asserted rather than assumed.
  {
    const narrowed = clone(loadRegistry());
    narrowed.populations = narrowed.populations.filter((p) => p.id !== 'noir/space-ship');
    const c = census({ reader: null, registry: narrowed });
    if (c.unclassified.length > 0) {
      const deltas = compare(reading, c);
      bite('a tracked .ct belonging to no declared population', deltas, 'unclassified paths');
    } else {
      bad('arm 7', 'removing a population left nothing unclassified — the registry is not what classifies');
    }
  }

  // ── arm 8: the identity read is read from the BYTES and not from a name, so
  // a container is identified by its magic and version rather than by living in
  // a directory the registry lists.
  {
    const paths = trackedCtPaths();
    const tour = paths.find((p) => p.startsWith('fixtures/trace/tour/') && p.endsWith('.ct'));
    const ph = paths.find((p) => p.startsWith('conformance-kit/template/complete/ct/'));
    const a = readIdentity(join(REPO_ROOT, tour));
    const b = readIdentity(join(REPO_ROOT, ph));
    // THE VERSION MOVED 5 -> 6 when the Noir corpus was re-recorded onto CTFS
    // §1e's compact profile, and this arm was the only thing that noticed —
    // by going red with `tour={"container":true,"version":6,"size":9057}`.
    // That is the arm working: a corpus whose container version changes under
    // a reader is exactly what it is here to report.
    //
    // IT IS STILL PINNED TO ONE NUMBER rather than relaxed to a set. The
    // property being measured is that identity is read from the BYTES and not
    // from a path, and a single expected version is what makes a silent
    // re-record impossible to miss; `version >= 5` would have let this one
    // through without a word. The cost is this comment every time the corpus
    // moves deliberately, which is the right side of the trade.
    const vWant = 6;
    const aOk = a.container && a.version === vWant;
    const bOk = !b.container && b.reason === 'no CTFS magic';
    if (aOk && bOk) {
      ok(`arm 8: identity comes from the bytes — a tour container reads v${vWant} and a placeholder reads "no CTFS magic"`);
    } else {
      // WHICH HALF, because the two have different remedies: a changed tour
      // version is a corpus move to confirm and renumber, while a placeholder
      // that suddenly reads as a container means `readIdentity` is matching
      // something it should not.
      bad('arm 8', (aOk ? '' : `the tour container is not v${vWant}: ${JSON.stringify(a)}  `) +
                   (bOk ? '' : `the placeholder is not "no CTFS magic": ${JSON.stringify(b)}`));
    }
  }

  console.log('');
  const expected = BASE_ARMS + (actual.readerPresent ? READER_ARMS : 0);
  // ── arm 9: a NAMED reader that is not there is refused, not NOT MEASURED ──
  //
  // Needs no reader of its own, so it is a base arm. Spawned, because the
  // refusal is a throw and the subject is the process's own answer: `--reader`
  // never checked the path it was handed, so `--reader /nonexistent` made
  // `readerPresent` TRUE with every read failing, which reported as three
  // failing arms about the corpus. `findReader` has always checked the sibling
  // walk and `$CT_PRINT`; the flag is held to the same rule now.
  {
    const r = spawnSync(process.execPath,
      [join(REPO_ROOT, 'tools', 'chain', 'ct-corpus-census.mjs'), '--reader', '/nonexistent-reader'],
      { encoding: 'utf8' });
    const said = `${r.stdout ?? ''}${r.stderr ?? ''}`;
    // `ok()` here takes ONE argument and always passes — it is a reporter, not
    // an assert. Called with a condition as a second argument it would have
    // been a check that cannot fail, which is the shape this whole file exists
    // to refuse. So the condition is the `if`.
    const claim = 'a --reader that does not exist is REFUSED by name, not folded into NOT MEASURED';
    if (r.status === 1
        && /--reader \/nonexistent-reader does not exist/.test(said)
        && /not a NOT MEASURED/.test(said)) ok(claim);
    else bad(claim, `exit=${r.status}, said: ${said.split('\n').filter((l) => l.trim()).slice(-1)[0] ?? '(nothing)'}`);
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
  const config = actual.readerPresent ? 'reader-present' : 'reader-absent';
  if (ran !== expected) {
    fail++;
    console.log(`  FAIL  arm count: ${ran} ran, ${expected} declared for the `
      + `${config} configuration (base ${BASE_ARMS} + reader ${actual.readerPresent ? READER_ARMS : 0})`);
  }
  console.log(`arm count: ${ran} (as declared for ${config}: base ${BASE_ARMS} + `
    + `reader ${actual.readerPresent ? READER_ARMS : 0})`);
  if (!actual.readerPresent) {
    console.log(`NOT RUN: ${READER_ARMS} arm(s) need a container reader and there is none here. `
      + 'They are not counted as passed.');
  }
  console.log(`self-test: ${fail === 0 ? 'PASS' : 'FAIL'} — ${pass} ok, ${fail} failing`);
  return fail === 0 ? 0 : 1;
}

if (import.meta.url === `file://${process.argv[1]}`) process.exit(await selftest());
