#!/usr/bin/env node
// object-set.mjs — read a published tree as a SET of objects, not as a count.
//
//   node tools/chain/object-set.mjs <tree-dir> [--manifest PATH] [--expect FILE]
//
// ── WHY A SET AND NOT A TOTAL ───────────────────────────────────────────────────────────
//
// The zero-regression baseline this exists for is stated as an exact object count, and a
// count is the one statistic a refactor can preserve while changing what is published.
// Rename every `ts` object and the total does not move. Rewrite the contents of one and
// the total does not move. So the reading this tool emits is three numbers and two
// digests, and it is the digests that carry the claim:
//
//   pathDigest — sha256 over the sorted relative paths. Moves iff the SET OF KEYS moves.
//   setDigest  — sha256 over the sorted "<sha256-of-content>  <relpath>" lines. Moves iff
//                the set of keys OR the bytes behind any of them move.
//
// Publishing both is what makes a difference diagnosable rather than merely detected: a
// changed `setDigest` with an unchanged `pathDigest` is a content change over the same
// keys, and the two failures want different explanations.
//
// ── AND THE SAME PAIR PER CLASS, BECAUSE A WHOLE-TREE DIGEST NAMES NOTHING ──────────────
//
// The full manifest for the genesis-to-tip tree is 22.7 MB — 10.7 MB compressed — so it is
// not committed, and a reading that is only two tree-wide digests can say THAT a refactor
// moved the set and nothing more. The per-class digests are the affordable middle: each
// object class carries its own count, bytes and two digests, so a difference localises to
// `d/{chain}/ts/**` or `d/{chain}/block/**` before anyone re-runs anything. Getting the
// objects themselves still needs `--manifest` on both trees, and the record says so.
//
// ── THE DIGEST IS DEFINED HERE, IN WORDS, BECAUSE A DIGEST NOBODY CAN RECOMPUTE IS A ────
// ── NUMBER AND NOT A CHECK ──────────────────────────────────────────────────────────────
//
//   * paths are relative to <tree-dir>, `/`-separated, with no leading `./`;
//   * they are sorted by BYTE VALUE of their UTF-8 encoding, not by locale — a locale
//     collation would make the digest depend on the environment that computed it;
//   * each manifest line is exactly `<64 lowercase hex>  <path>\n`, two spaces, the
//     `sha256sum` shape, so the manifest a run writes can be checked by other tools;
//   * `setDigest` is sha256 over that byte stream; `pathDigest` is sha256 over the same
//     paths in the same order, one per line;
//   * directories, symlinks and anything that is not a regular file are NOT objects and
//     are not in either digest. A published tree is a set of keys; an empty directory is
//     not a key, and on one filesystem it would survive a copy that dropped it on another.
//
// ── IT REFUSES RATHER THAN REPORTS ZERO ─────────────────────────────────────────────────
//
// An unaimed run (no argument) exits 2, and a directory that is absent or holds no objects
// exits 1 with the path in the message. "0 objects, digest of the empty stream" is a
// reading that compares equal to nothing and unequal to everything, and it is the empty-set
// pass in the one disguise this repository has already paid for: a tool that looks like it
// ran. There is no default tree path for the same reason `coverage-contiguity.mjs` has
// none — a default that resolves only on the machine that did the publish is how a tool
// comes to report on a tree nobody asked it about.
//
// Offline, toolchain-free, reads one directory and reaches no network.
import { readFileSync, writeFileSync, statSync, readdirSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { join, sep } from 'node:path';

const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(name);
  if (i < 0) return null;
  const v = argv[i + 1];
  if (v == null || v.startsWith('--')) {
    console.error(`object-set.mjs: ${name} needs a path`);
    process.exit(2);
  }
  argv.splice(i, 2);
  return v;
};

const manifestPath = flag('--manifest');
const expectPath = flag('--expect');
const root = argv[0];

if (!root) {
  console.error('usage: object-set.mjs <tree-dir> [--manifest PATH] [--expect FILE]\n'
    + '  <tree-dir> is a published tree — the directory holding `d/` and `registry/`,\n'
    + '  as written by `ingest.nim`\'s publish path (its --out DIR, or the `tree/`\n'
    + '  beside a run\'s `--state DIR`). It is required: a default that resolves only\n'
    + '  on the machine that ran the publish is how a reading comes to be taken of a\n'
    + '  tree nobody named.\n'
    + '  --manifest writes the full `<sha256>  <path>` listing, which is what a set\n'
    + '  COMPARISON needs; the digests alone can only say THAT two trees differ.\n'
    + '  --expect reads a previous reading (this tool\'s own JSON) and exits non-zero\n'
    + '  on any difference, naming which of the two digests moved.');
  process.exit(2);
}

if (!existsSync(root)) {
  console.error(`object-set.mjs: no such tree: ${root}`);
  process.exit(1);
}

// ── the walk ───────────────────────────────────────────────────────────────────────────
// `readdirSync(withFileTypes)` so a symlink is identified without following it: following
// one could count an object twice, or walk out of the tree entirely.
const objects = [];
const walk = (dir, rel) => {
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, ent.name);
    const r = rel ? `${rel}/${ent.name}` : ent.name;
    if (ent.isSymbolicLink()) continue;
    if (ent.isDirectory()) walk(full, r);
    else if (ent.isFile()) objects.push(r);
  }
};
walk(root, '');

if (objects.length === 0) {
  console.error(`object-set.mjs: ${root} holds no objects. A reading over an empty tree\n`
    + '  compares equal to nothing and unequal to everything; it is refused rather than\n'
    + '  published.');
  process.exit(1);
}

// BYTE order, not locale order. `Buffer.compare` is the definition; `Array#sort`'s default
// is UTF-16 code-unit order, which differs from UTF-8 byte order above the BMP.
objects.sort((a, b) => Buffer.compare(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8')));

// ── the classes ────────────────────────────────────────────────────────────────────────
// Named as the publisher builds them (`ingest.nim`), so a moved count names the writer.
// A path that matches none is reported under `unclassified` rather than folded into a
// neighbour: an object class this does not know about is exactly the news worth having.
const CLASSES = [
  [/^registry\/chains\.v1\.json$/, 'registry/chains.v1.json'],
  [/^d\/[^/]+\/current\.json$/, 'd/{chain}/current.json'],
  [/^d\/[^/]+\/block\/[^/]+$/, 'd/{chain}/block/{blockHash}.json'],
  [/^d\/[^/]+\/tx\/[^/]+\/[^/]+$/, 'd/{chain}/tx/{shard}/{txHash}.json'],
  [/^d\/[^/]+\/ts\/[^/]+\/[^/]+\/[^/]+$/, 'd/{chain}/ts/{v}/{shard}/{txHash}.json'],
  [/^d\/[^/]+\/g\/[^/]+\/root\.json$/, 'd/{chain}/g/{gen}/root.json'],
  [/^d\/[^/]+\/g\/[^/]+\/summary\.json$/, 'd/{chain}/g/{gen}/summary.json'],
  [/^d\/[^/]+\/g\/[^/]+\/height\/.+$/, 'd/{chain}/g/{gen}/height/**'],
  [/^d\/[^/]+\/g\/[^/]+\/blocks\/.+$/, 'd/{chain}/g/{gen}/blocks/**'],
  [/^d\/[^/]+\/g\/[^/]+\/txstate\/[^/]+\/[^/]+$/, 'd/{chain}/g/{gen}/txstate/{shard}/{txHash}.json'],
];
const classify = (rel) => {
  for (const [re, name] of CLASSES) if (re.test(rel)) return name;
  return 'unclassified';
};

const setH = createHash('sha256');
const pathH = createHash('sha256');
const classes = new Map();
const manifest = [];
let bytes = 0;

for (const rel of objects) {
  const data = readFileSync(join(root, ...rel.split('/')));
  const h = createHash('sha256').update(data).digest('hex');
  bytes += data.length;
  const line = `${h}  ${rel}\n`;
  setH.update(line);
  pathH.update(`${rel}\n`);
  if (manifestPath) manifest.push(line);
  const c = classify(rel);
  let e = classes.get(c);
  if (!e) {
    e = { objects: 0, bytes: 0, _set: createHash('sha256'), _path: createHash('sha256') };
    classes.set(c, e);
  }
  e.objects += 1;
  e.bytes += data.length;
  // The same two definitions, over this class's slice of the same sorted stream — so a
  // class digest is reproducible from the manifest by grepping the class and re-hashing.
  e._set.update(line);
  e._path.update(`${rel}\n`);
}

const sealClasses = () => Object.fromEntries(
  [...classes.entries()]
    .sort((a, b) => (a[0] < b[0] ? -1 : 1))
    .map(([name, e]) => [name, {
      objects: e.objects,
      bytes: e.bytes,
      pathDigest: `sha256:${e._path.digest('hex')}`,
      setDigest: `sha256:${e._set.digest('hex')}`,
    }]));

const reading = {
  format: 'blocktracer/published-object-set@1',
  objects: objects.length,
  bytes,
  pathDigest: `sha256:${pathH.digest('hex')}`,
  setDigest: `sha256:${setH.digest('hex')}`,
  classes: sealClasses(),
};

// The breakdown is checked against the total here rather than trusted: a class table that
// does not sum to the count is a classifier bug reported as a data finding.
const summed = Object.values(reading.classes).reduce((n, c) => n + c.objects, 0);
if (summed !== reading.objects) {
  console.error(`object-set.mjs: classes sum to ${summed}, not ${reading.objects}`);
  process.exit(1);
}

if (manifestPath) writeFileSync(manifestPath, manifest.join(''));

console.log(JSON.stringify(reading, null, 1));

if (expectPath) {
  const want = JSON.parse(readFileSync(expectPath, 'utf8'));
  const diffs = [];
  if (want.objects !== reading.objects) diffs.push(`objects ${want.objects} -> ${reading.objects}`);
  if (want.bytes !== reading.bytes) diffs.push(`bytes ${want.bytes} -> ${reading.bytes}`);
  if (want.pathDigest !== reading.pathDigest) diffs.push('pathDigest moved: the SET OF KEYS is different');
  if (want.setDigest !== reading.setDigest) diffs.push('setDigest moved: the bytes behind some key are different');
  // Per class, so the report names WHERE before anyone re-runs anything. A class present
  // on one side and absent on the other is the loudest case and is reported as such.
  for (const name of [...new Set([...Object.keys(want.classes ?? {}), ...Object.keys(reading.classes)])].sort()) {
    const a = want.classes?.[name], b = reading.classes[name];
    if (!a) { diffs.push(`  class ${name}: NEW, ${b.objects} objects`); continue; }
    if (!b) { diffs.push(`  class ${name}: GONE, was ${a.objects} objects`); continue; }
    if (a.objects !== b.objects) diffs.push(`  class ${name}: objects ${a.objects} -> ${b.objects}`);
    else if (a.pathDigest !== b.pathDigest) diffs.push(`  class ${name}: same count, different keys`);
    else if (a.setDigest !== b.setDigest) diffs.push(`  class ${name}: same keys, different content`);
  }
  if (diffs.length) {
    console.error(`\nDIFFERS FROM ${expectPath}:`);
    for (const d of diffs) console.error(`  ${d}`);
    console.error('\nA difference in either direction is a finding to be named, not a rounding\n'
      + 'difference. Compare the manifests (--manifest on both) to get the objects.');
    process.exit(1);
  }
  console.log(`\nIDENTICAL TO ${expectPath}: count, bytes, key set and content.`);
}
