#!/usr/bin/env node
// object-set-selftest.mjs — proof that `object-set.mjs` is about the SET.
//
//   node tools/chain/object-set-selftest.mjs
//
// ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
// The deliverable this tool serves is stated as a count — 138,287 objects — and a count is
// precisely the statistic a refactor can hold still while changing what is published. The
// milestone says so in its own control: *a tree with one object renamed has the same count
// and fails, so the check is shown to be about the set.* That control is case R2 below,
// and it is the reason this file is not optional: a tool that reports a number nobody has
// watched move is indistinguishable from one that prints the number it was told.
//
// Every case is a pair — a MUTATION and a CONTROL that differs from it in one respect —
// because "the digest changed" is only evidence if something comparable left it unchanged.
//
// OFFLINE AND TOOLCHAIN-FREE: it builds small trees in a temporary directory and spawns
// `node`. It reaches no network; neither does the tool, which reads one directory.
//
// ── THE FIXTURE IS THE REAL KEY LAYOUT ─────────────────────────────────────────────────
//
// The paths below are the ones `ingest.nim` actually writes — `d/{chain}/block/{hash}.json`,
// `d/{chain}/tx/{shard}/{hash}.json`, `d/{chain}/ts/{v}/{shard}/{hash}.json`,
// `d/{chain}/g/{gen}/…`, `registry/chains.v1.json`. A fixture with invented paths would
// pass while every object fell into `unclassified`, which is the failure the class table
// exists to surface.

import { mkdtemp, writeFile, mkdir, rm, rename } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, 'object-set.mjs');

let asserted = 0, failed = 0;
const ck = (label, cond) => {
  asserted += 1;
  if (!cond) { failed += 1; console.error(`  FAIL  ${label}`); }
};

const run = (...args) => {
  const r = spawnSync(process.execPath, [TOOL, ...args], { encoding: 'utf8' });
  let json = null;
  try { json = JSON.parse(r.stdout); } catch { /* a refusal prints no JSON, by design */ }
  return { code: r.status, out: r.stdout, err: r.stderr, json };
};

// ── the fixture ────────────────────────────────────────────────────────────────────────
// Two blocks, two transactions (so three objects each), and the six singletons: the same
// shape as a real metadata-only publish, at 2 + 3*2 + 6 = 14 objects.
const CHAIN = 'aztec-testnet';
const GEN = 'rcab127b14cf4';
const TX = ['0x2e5611aa', '0x0987ffbb'];
const BLK = ['0xaaa1', '0xbbb2'];

const FIXTURE = [
  ['registry/chains.v1.json', '{"chains":["aztec-testnet"]}'],
  [`d/${CHAIN}/current.json`, '{"head":{"height":2}}'],
  [`d/${CHAIN}/g/${GEN}/root.json`, '{"maps":{}}'],
  [`d/${CHAIN}/g/${GEN}/summary.json`, '{"counters":{"blocks":2,"transactions":2}}'],
  [`d/${CHAIN}/g/${GEN}/height/0.json`, '{"1":"0xaaa1","2":"0xbbb2"}'],
  [`d/${CHAIN}/g/${GEN}/blocks/0.json`, '["0xaaa1","0xbbb2"]'],
  ...BLK.map((h, i) => [`d/${CHAIN}/block/${h}.json`, `{"height":${i + 1}}`]),
  ...TX.flatMap((h) => {
    const shard = h.slice(2, 6);
    return [
      [`d/${CHAIN}/tx/${shard}/${h}.json`, `{"hash":"${h}"}`],
      [`d/${CHAIN}/ts/1/${shard}/${h}.json`, `{"executions":[{"availability":"absent"}]}`],
      [`d/${CHAIN}/g/${GEN}/txstate/${shard}/${h}.json`, `{"canonical":true}`],
    ];
  }),
];
const EXPECTED_OBJECTS = 14;

const build = async (root, mutate = (f) => f) => {
  for (const [rel, body] of mutate(FIXTURE.map((e) => [...e]))) {
    const p = join(root, ...rel.split('/'));
    await mkdir(dirname(p), { recursive: true });
    await writeFile(p, body);
  }
  return root;
};

const tmp = await mkdtemp(join(tmpdir(), 'object-set-selftest-'));
const dir = async (name) => { const p = join(tmp, name); await mkdir(p, { recursive: true }); return p; };

try {
  // ── case 0: the fixture is the shape the tool is for ─────────────────────────────────
  // If every object landed in `unclassified` the rest of this file would still pass while
  // measuring a tree the publisher never writes, so this is asserted before anything else.
  const base = run(await build(await dir('base')));
  console.log('R0  the fixture reads as a publish, not as an unclassified heap');
  ck('R0.1 exit 0', base.code === 0);
  ck('R0.2 the format token', base.json?.format === 'blocktracer/published-object-set@1');
  ck(`R0.3 ${EXPECTED_OBJECTS} objects`, base.json?.objects === EXPECTED_OBJECTS);
  ck('R0.4 nothing unclassified', base.json && !('unclassified' in base.json.classes));
  ck('R0.5 the per-class counts sum to the total',
    Object.values(base.json?.classes ?? {}).reduce((n, c) => n + c.objects, 0) === EXPECTED_OBJECTS);
  ck('R0.6 the formula blocks + 3*transactions + 6 holds on the fixture',
    base.json?.classes[`d/{chain}/block/{blockHash}.json`].objects === 2
    && base.json?.classes[`d/{chain}/tx/{shard}/{txHash}.json`].objects === 2
    && base.json?.classes[`d/{chain}/ts/{v}/{shard}/{txHash}.json`].objects === 2
    && base.json?.classes[`d/{chain}/g/{gen}/txstate/{shard}/{txHash}.json`].objects === 2);
  ck('R0.7 every class carries its own two digests',
    Object.values(base.json?.classes ?? {}).every((c) => /^sha256:[0-9a-f]{64}$/.test(c.setDigest)
      && /^sha256:[0-9a-f]{64}$/.test(c.pathDigest)));

  // ── case 1: it is a measurement, so it repeats ───────────────────────────────────────
  // CONTROL for everything below: if a second reading of the SAME tree moved, a moved
  // digest would be evidence of nothing at all.
  console.log('R1  the same tree twice is the same reading');
  const again = run(join(tmp, 'base'));
  ck('R1.1 objects stable', again.json?.objects === base.json?.objects);
  ck('R1.2 bytes stable', again.json?.bytes === base.json?.bytes);
  ck('R1.3 pathDigest stable', again.json?.pathDigest === base.json?.pathDigest);
  ck('R1.4 setDigest stable', again.json?.setDigest === base.json?.setDigest);

  // A tree written in a DIFFERENT ORDER is the same set.
  //
  // THIS CASE IS WEAKER THAN IT LOOKS AND SAYING SO IS THE POINT. It was written to prove
  // the walk sorts, and it does not: deleting the sort from the tool leaves it GREEN,
  // because APFS returns directory entries in name order, so the reverse-written tree is
  // walked in sorted order anyway. What it actually establishes is that creation order does
  // not reach the reading — worth having, but it is not a test of the sort, and a machine
  // whose filesystem returns entries in creation order is where it would first matter.
  const shuffled = await build(await dir('shuffled'), (f) => f.reverse());
  const sr = run(shuffled);
  ck('R1.5 written in reverse order, identical setDigest', sr.json?.setDigest === base.json?.setDigest);

  // AND THE COMPARATOR IS NOT TESTED HERE EITHER, DELIBERATELY. The tool sorts by UTF-8
  // byte value rather than by JavaScript's default (UTF-16 code-unit) order. The two
  // disagree only above the BMP, and every key the publisher writes is ASCII — `d`, a chain
  // slug, and hex — so on real data the choice cannot be observed at all. An attempt to
  // exercise it with an above-the-BMP filename was written and then removed: it needs names
  // the filesystem may refuse (macOS returned EILSEQ for one), which buys a test that can
  // fail for a reason unrelated to the tool. The byte-order comparator stays because it is
  // the right definition for a digest that has to match `sha256sum` and `LC_ALL=C sort`
  // elsewhere, and this comment — not a green assertion — is the honest statement of how
  // far it has been checked.

  // ── case 2: THE MILESTONE'S OWN CONTROL — a rename keeps the count and must fail ──────
  console.log('R2  one object renamed: same count, different set');
  const renamed = await build(await dir('renamed'), (f) => f.map(([rel, body]) =>
    rel === `d/${CHAIN}/tx/2e56/${TX[0]}.json`
      ? [`d/${CHAIN}/tx/2e56/0xdeadbeef.json`, body] : [rel, body]));
  const rn = run(renamed);
  ck('R2.1 the count did NOT move — which is why a count alone cannot detect this',
    rn.json?.objects === base.json?.objects);
  ck('R2.2 ...and the bytes did not move either', rn.json?.bytes === base.json?.bytes);
  ck('R2.3 pathDigest MOVED', rn.json?.pathDigest !== base.json?.pathDigest);
  ck('R2.4 setDigest MOVED', rn.json?.setDigest !== base.json?.setDigest);
  ck('R2.5 the tx class names itself as the one that moved',
    rn.json?.classes[`d/{chain}/tx/{shard}/{txHash}.json`].pathDigest
      !== base.json?.classes[`d/{chain}/tx/{shard}/{txHash}.json`].pathDigest);
  ck('R2.6 a class that did not move did not move',
    rn.json?.classes[`d/{chain}/block/{blockHash}.json`].setDigest
      === base.json?.classes[`d/{chain}/block/{blockHash}.json`].setDigest);

  // ── case 3: same keys, different bytes ───────────────────────────────────────────────
  // The mirror of R2, and the reason both digests are published rather than one: here the
  // key set is untouched, so `pathDigest` must hold still while `setDigest` moves. A single
  // digest could not tell an operator which of the two happened.
  console.log('R3  one object rewritten: same keys, different content');
  const rewritten = await build(await dir('rewritten'), (f) => f.map(([rel, body]) =>
    rel === `d/${CHAIN}/ts/1/2e56/${TX[0]}.json`
      ? [rel, '{"executions":[{"availability":"trace"}]}'] : [rel, body]));
  const rw = run(rewritten);
  ck('R3.1 the count did not move', rw.json?.objects === base.json?.objects);
  ck('R3.2 pathDigest HELD STILL', rw.json?.pathDigest === base.json?.pathDigest);
  ck('R3.3 setDigest MOVED', rw.json?.setDigest !== base.json?.setDigest);
  ck('R3.4 the ts class is named', rw.json?.classes[`d/{chain}/ts/{v}/{shard}/{txHash}.json`].setDigest
      !== base.json?.classes[`d/{chain}/ts/{v}/{shard}/{txHash}.json`].setDigest);

  // ── case 4: two objects swap contents ────────────────────────────────────────────────
  // The adversarial case a per-class *count* and a naive "sum of hashes" would both miss:
  // the key set is identical, the multiset of contents is identical, and the total byte
  // count is identical. Only a digest that BINDS each hash to its path can see it.
  console.log('R4  two objects swap contents: every total identical, binding broken');
  const swapped = await build(await dir('swapped'), (f) => {
    const a = f.find(([r]) => r === `d/${CHAIN}/block/${BLK[0]}.json`);
    const b = f.find(([r]) => r === `d/${CHAIN}/block/${BLK[1]}.json`);
    const t = a[1]; a[1] = b[1]; b[1] = t;
    return f;
  });
  const sw = run(swapped);
  ck('R4.1 count identical', sw.json?.objects === base.json?.objects);
  ck('R4.2 bytes identical', sw.json?.bytes === base.json?.bytes);
  ck('R4.3 pathDigest identical', sw.json?.pathDigest === base.json?.pathDigest);
  ck('R4.4 setDigest MOVED — the hash is bound to its key', sw.json?.setDigest !== base.json?.setDigest);

  // ── case 5: an object added and an object removed ────────────────────────────────────
  console.log('R5  the count moves in both directions and is reported');
  const extra = await build(await dir('extra'), (f) => [...f,
    [`d/${CHAIN}/block/0xccc3.json`, '{"height":3}']]);
  const ex = run(extra);
  ck('R5.1 one more object', ex.json?.objects === EXPECTED_OBJECTS + 1);
  ck('R5.2 the block class carries it', ex.json?.classes[`d/{chain}/block/{blockHash}.json`].objects === 3);
  const fewer = await build(await dir('fewer'), (f) => f.filter(([r]) => r !== `d/${CHAIN}/block/${BLK[1]}.json`));
  const fw = run(fewer);
  ck('R5.3 one fewer object', fw.json?.objects === EXPECTED_OBJECTS - 1);

  // ── case 6: an unknown class is reported, not folded into a neighbour ────────────────
  // A refactor that starts publishing a new kind of object is the "higher count is equally
  // a finding" case. If an unrecognised path were silently absorbed, the count would move
  // with no indication of what moved it.
  console.log('R6  an object the class table does not know is named, not absorbed');
  const unknown = await build(await dir('unknown'), (f) => [...f,
    [`d/${CHAIN}/newthing/0xff.json`, '{}']]);
  const uk = run(unknown);
  ck('R6.1 it is counted', uk.json?.objects === EXPECTED_OBJECTS + 1);
  ck('R6.2 it is reported as unclassified', uk.json?.classes.unclassified?.objects === 1);
  ck('R6.3 the known classes are unchanged',
    uk.json?.classes[`d/{chain}/block/{blockHash}.json`].setDigest
      === base.json?.classes[`d/{chain}/block/{blockHash}.json`].setDigest);

  // ── case 7: --expect is the comparison, and it BITES ─────────────────────────────────
  console.log('R7  --expect refuses a moved reading and accepts an unmoved one');
  const expFile = join(tmp, 'expected.json');
  await writeFile(expFile, JSON.stringify(base.json, null, 1));
  const same = run(join(tmp, 'base'), '--expect', expFile);
  ck('R7.1 identical tree: exit 0', same.code === 0);
  ck('R7.2 ...and it says so', /IDENTICAL TO/.test(same.out));
  const moved = run(renamed, '--expect', expFile);
  ck('R7.3 renamed tree: exit 1', moved.code === 1);
  ck('R7.4 it names the SET, not the count', /pathDigest moved/.test(moved.err));
  ck('R7.5 it names the class', /class d\/\{chain\}\/tx/.test(moved.err));
  const contentMoved = run(rewritten, '--expect', expFile);
  ck('R7.6 rewritten tree: exit 1', contentMoved.code === 1);
  ck('R7.7 and it distinguishes content from keys',
    /setDigest moved/.test(contentMoved.err) && !/pathDigest moved/.test(contentMoved.err));
  const grew = run(extra, '--expect', expFile);
  ck('R7.8 a HIGHER count is a failure too', grew.code === 1 && /objects 14 -> 15/.test(grew.err));

  // ── case 8: the manifest is the real comparison surface ─────────────────────────────
  console.log('R8  --manifest writes the sha256sum-shaped listing');
  const mf = join(tmp, 'm.txt');
  const withMf = run(join(tmp, 'base'), '--manifest', mf);
  const { readFileSync } = await import('node:fs');
  const text = readFileSync(mf, 'utf8');
  const lines = text.split('\n').filter(Boolean);
  ck('R8.1 one line per object', lines.length === EXPECTED_OBJECTS);
  ck('R8.2 every line is `<64 hex>  <path>`', lines.every((l) => /^[0-9a-f]{64} {2}\S/.test(l)));
  ck('R8.3 sorted by byte value', lines.map((l) => l.slice(66)).every((p, i, a) =>
    i === 0 || Buffer.compare(Buffer.from(a[i - 1]), Buffer.from(p)) < 0));
  // The digest is recomputable from the manifest, which is the whole claim of the header
  // comment. If it were not, the committed digest would be unfalsifiable.
  const { createHash } = await import('node:crypto');
  ck('R8.4 setDigest is sha256 of the manifest bytes',
    `sha256:${createHash('sha256').update(text).digest('hex')}` === withMf.json?.setDigest);

  // ── case 9: it refuses rather than reporting zero ────────────────────────────────────
  // The empty-set pass, in its two disguises: unaimed, and aimed at nothing.
  console.log('R9  unaimed and empty runs refuse');
  const unaimed = run();
  ck('R9.1 no argument: exit 2', unaimed.code === 2);
  ck('R9.2 ...with a usage message', /usage: object-set\.mjs/.test(unaimed.err));
  ck('R9.3 ...and no JSON, so nothing downstream reads a reading', unaimed.json === null);
  const missing = run(join(tmp, 'no-such-tree'));
  ck('R9.4 absent tree: exit 1', missing.code === 1);
  ck('R9.5 ...naming the path', missing.err.includes('no-such-tree'));
  const emptyDir = await dir('empty');
  const empty = run(emptyDir);
  ck('R9.6 empty tree: exit 1 rather than a digest of nothing', empty.code === 1);
  ck('R9.7 ...and it says why', /holds no objects/.test(empty.err));
  // A tree of empty DIRECTORIES is the same refusal: a directory is not a key.
  const dirsOnly = await dir('dirs-only');
  await mkdir(join(dirsOnly, 'd', CHAIN, 'block'), { recursive: true });
  const dOnly = run(dirsOnly);
  ck('R9.8 directories are not objects', dOnly.code === 1);
  // And a flag given no value is a usage error, not a silently-ignored flag.
  const danglingFlag = run(join(tmp, 'base'), '--manifest');
  ck('R9.9 a flag with no path: exit 2', danglingFlag.code === 2);

} finally {
  await rm(tmp, { recursive: true, force: true });
}

console.log(`\nobject-set-selftest: ${asserted} assertions, ${failed} failed`);
// 53 = R0 7 + R1 5 + R2 6 + R3 4 + R4 4 + R5 3 + R6 3 + R7 8 + R8 4 + R9 9, read off the
// cases term by term. This guard caught the number stale on the very run that introduced
// it — it was written 55 before anything had executed — which is the argument for it.
if (asserted !== 53) {
  console.error(`DECLARED 53 assertions, executed ${asserted}. The count is derived by reading\n`
    + 'the cases term by term; a mismatch means a case stopped running, which is the failure\n'
    + 'mode a green suite hides best.');
  process.exit(1);
}
process.exit(failed ? 1 : 0);
