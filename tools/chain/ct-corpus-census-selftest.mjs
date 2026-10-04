#!/usr/bin/env node
// ct-corpus-census-selftest.mjs — does the census GATE decide, in both directions?
//
//   node tools/chain/ct-corpus-census.mjs --selftest
//
// A census that only ever reports is documentation. This suite is the evidence
// that it REFUSES, and that it refuses on each field independently rather than
// on one coarse "something changed".
//
// Every arm perturbs the COMMITTED READING and leaves the tree alone. That is
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

import { census, compare, loadRegistry, findReader, trackedCtPaths, readIdentity, REPO_ROOT } from './ct-corpus-census.mjs';
import { readFileSync } from 'node:fs';
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
const BASE_ARMS = 6;
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

  const reader = findReader();
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

  // ── arm 6: a refusal that changed FIELD. "refused" and "refused on meta.dat
  // schema 3" are different facts, and the campaign turns on the second: a
  // chain container refused on its CONTAINER VERSION instead would mean a
  // different reader or different bytes.
  if (actual.readerPresent) {
    const r = clone(reading);
    const pop = r.populations.find((p) => p.id === 'chain/aztec-testnet');
    pop.refusals = { 'container-version-3': pop.containers };
    bite('a refusal attributed to the container version instead of the schema',
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
    if (a.container && a.version === 5 && !b.container && b.reason === 'no CTFS magic') {
      ok('arm 8: identity comes from the bytes — a tour container reads v5 and a placeholder reads "no CTFS magic"');
    } else {
      bad('arm 8', `tour=${JSON.stringify(a)} placeholder=${JSON.stringify(b)}`);
    }
  }

  console.log('');
  const expected = BASE_ARMS + (actual.readerPresent ? READER_ARMS : 0);
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
