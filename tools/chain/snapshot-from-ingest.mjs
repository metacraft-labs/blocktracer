#!/usr/bin/env node
// snapshot-from-ingest.mjs — rebuild a chain snapshot from the INGEST BUCKET, so
// that what a resident follower publishes can be ingested into the site's data
// plane by the producer that already exists.
//
// ── WHY THIS DID NOT EXIST, WHICH IS NOT "NOBODY WROTE IT" ───────────────────
//
// `services/blocktracer-ingest` (infra) uploads, per chain:
//
//   captures/<chain>/<hash>.ct        the trace container
//   captures/<chain>/<hash>.json      the source bundle
//   observations/<chain>/<from>-<to>.json   what has been LOOKED AT
//
// and `blocktracer-chain-ingest --snapshot DIR --out DIR` consumes a snapshot
// directory. The missing piece was called "the join", as though a converter had
// simply not been written. IT COULD NOT BE WRITTEN. Measured against
// `tools/chain/snapshot-contract.json`, a snapshot requires per transaction
// `blockNumber`, `txIndexInBlock`, `version`, `outcome`, `revertCode`, `reason`,
// `refusalReason`, `container`, `containerBytes`, `effects`, `recording`, `cost`
// and `executions`, and per block `number`, `hash`, `parentArchiveRoot` and
// `transactions`. The observation record's entire payload is three hash LISTS
// (`observed`, `captured`, `refusals`) plus a range and the node's tags. Every
// capture in that bucket was an orphan container whose facts existed only in a
// 10.6 MB `snapshot.json` on the follower's own disk.
//
// So the fix was in the PUBLISHER, not here: it now writes
// `captures/<chain>/<hash>.tx.json` (the snapshot row) and
// `blocks/<chain>/<n>.json` beside each capture, before the marker that retires
// it. This tool is the consumer of that, and it is deliberately small — if it
// needed logic beyond assembling published facts, the facts would be wrong.
//
// ── WHAT IT REFUSES, BY NAME ─────────────────────────────────────────────────
//
// A missing required member is a REFUSAL and never a default. A snapshot
// assembled with a plausible `tip`, an invented `prestateStrategy` or a
// `recorder.id` of "unknown" would ingest, publish, and be wrong in a way no
// reader could detect — which is the failure this whole repository is organised
// against. Each refusal below names the object that should have carried the
// member and the producer that should have written it.
//
// ── USAGE ────────────────────────────────────────────────────────────────────
//
//   node tools/chain/snapshot-from-ingest.mjs \
//     --bucket-dir <dir> --chain <slug> --out <snapshot dir> [--json]
//
// `--bucket-dir` is a LOCAL MIRROR of the ingest bucket (`aws s3 sync` of the
// four prefixes). A directory rather than an S3 client on purpose: this tool
// does no credentialed I/O, so it runs in a check, over a fixture, with no
// network and no token — the same reason `static_export.nim` takes a directory.

import { readFileSync, writeFileSync, mkdirSync, copyFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join, basename } from 'node:path';

const args = process.argv.slice(2);
const arg = (name, fallback = undefined) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? fallback : args[i + 1];
};
const has = (name) => args.includes(`--${name}`);

const bucketDir = arg('bucket-dir');
const chain = arg('chain');
const outDir = arg('out');
if (!bucketDir || !chain || !outDir) {
  console.error('usage: snapshot-from-ingest.mjs --bucket-dir DIR --chain SLUG --out DIR [--json]');
  process.exit(2);
}

class IngestBucketIncomplete extends Error {
  constructor(what, where, producer) {
    super(`${what}. Expected it in ${where}, which is written by ${producer}. `
      + 'Refusing to invent it: a snapshot assembled around a guessed member ingests and '
      + 'publishes cleanly and is wrong in a way no reader of the site can detect.');
    this.name = 'IngestBucketIncomplete';
  }
}

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));
const listDir = (p) => (existsSync(p) ? readdirSync(p).sort() : []);

const capturesDir = join(bucketDir, 'captures', chain);
const blocksDir = join(bucketDir, 'blocks', chain);
const obsDir = join(bucketDir, 'observations', chain);

// ── The observation record: chain-level facts, and the record of LOOKING ──────
//
// THE WIDEST KEY WINS, and that is not a tie-break — it follows from the
// publisher's own documented defect: the record is CUMULATIVE and its key widens
// as the follower runs, leaving the previous key behind as a stale orphan that
// nothing prunes. Taking the newest `observedAt` rather than the widest range
// would be correct too; taking an arbitrary one would silently publish a smaller
// chain than was observed.
const obsFiles = listDir(obsDir).filter((f) => f.endsWith('.json'));
if (obsFiles.length === 0) {
  throw new IngestBucketIncomplete(
    `no observation record for '${chain}'`,
    `${obsDir}/<from>-<to>.json`,
    "the follower's publish unit (services/blocktracer-ingest)");
}
const observations = obsFiles.map((f) => readJson(join(obsDir, f)));
const observation = observations.reduce((best, o) => {
  const span = (x) => (Number(x?.range?.to ?? -1) - Number(x?.range?.from ?? 0));
  return span(o) > span(best) ? o : best;
});

if (observation.format !== 'blocktracer/ingest-observation@1') {
  throw new IngestBucketIncomplete(
    `the observation record declares format '${observation.format}', which this tool does not read`,
    obsDir, 'the follower\'s publish unit');
}

// ── The transactions: one published row per capture ───────────────────────────
const rowFiles = listDir(capturesDir).filter((f) => f.endsWith('.tx.json'));
const transactions = rowFiles.map((f) => readJson(join(capturesDir, f)));

// ── The blocks ────────────────────────────────────────────────────────────────
const blocks = listDir(blocksDir)
  .filter((f) => f.endsWith('.json'))
  .map((f) => readJson(join(blocksDir, f)))
  .sort((a, b) => Number(a.number) - Number(b.number));

// ── What must be present, checked before anything is written ──────────────────
if (transactions.length === 0 && (observation.captured ?? []).length > 0) {
  throw new IngestBucketIncomplete(
    `the observation record names ${observation.captured.length} captured transaction(s) but the `
    + 'bucket holds no `<hash>.tx.json` row for any of them',
    `${capturesDir}/<hash>.tx.json`,
    'the follower\'s publish unit — a follower from before rows were published leaves exactly this shape');
}
if (blocks.length === 0 && transactions.length > 0) {
  throw new IngestBucketIncomplete(
    'the bucket holds transaction rows but no block rows',
    `${blocksDir}/<number>.json`, 'the follower\'s publish unit');
}

const provenance = observation.provenance;
for (const [member, where] of [
  ['recorder', 'provenance.recorder'],
  ['prestateStrategy', 'provenance.prestateStrategy'],
]) {
  if (provenance?.[member] === undefined) {
    throw new IngestBucketIncomplete(
      `the snapshot's required \`provenance.${member}\` is not published anywhere in the bucket`,
      `${obsDir}/<from>-<to>.json → .provenance.${member}`,
      'the follower\'s publish unit');
  }
  void where;
}

const window = observation.tags;
for (const member of ['tip', 'finalized', 'blocks']) {
  if (window?.[member] === undefined) {
    throw new IngestBucketIncomplete(
      `the snapshot's required \`window.${member}\` is not published`,
      `${obsDir}/<from>-<to>.json → .tags.${member}`,
      'the follower\'s publish unit');
  }
}

// ── Assemble ──────────────────────────────────────────────────────────────────
//
// `counts.accountedFor` is DERIVED and the derivation is the contract's own:
// every transaction is accounted for when it either produced a container or
// carries a refusal reason saying why it did not. Computing it here rather than
// copying a published number is deliberate — it is the one number that must agree
// with the rows beside it, and a copied one can disagree with them.
const accountedFor = transactions.filter(
  (t) => t.container != null || t.refusalReason != null || t.reason != null).length;

const snapshot = {
  format: 'blocktracer/chain-snapshot@2',
  provenance: { ...provenance, chain },
  window,
  counts: { blocks: blocks.length, transactions: transactions.length, accountedFor },
  blocks,
  transactions,
};

mkdirSync(join(outDir, 'ct'), { recursive: true });
mkdirSync(join(outDir, 'sources'), { recursive: true });

let containers = 0;
let sources = 0;
let missingContainers = [];
for (const tx of transactions) {
  if (tx.container == null) continue;
  const name = basename(tx.container);
  const src = join(capturesDir, `${tx.txHash}.ct`);
  if (!existsSync(src)) { missingContainers.push(tx.txHash); continue; }
  copyFileSync(src, join(outDir, 'ct', name));
  containers += 1;
  const bundle = join(capturesDir, `${tx.txHash}.json`);
  if (existsSync(bundle)) { copyFileSync(bundle, join(outDir, 'sources', `${tx.txHash}.json`)); sources += 1; }
}

// A ROW NAMING A CONTAINER THAT IS NOT THERE IS A REFUSAL, not a thinner tree.
// `ingest.nim` "refuses to publish a manifest naming a zero-byte trace", and a
// manifest naming an ABSENT one is the same fault one step earlier. The
// publisher's ordering rule (every capture uploaded before the record that names
// it) means this cannot happen on a healthy bucket, which is why it is a refusal
// and not a filter.
if (missingContainers.length > 0) {
  throw new IngestBucketIncomplete(
    `${missingContainers.length} row(s) name a container the bucket does not hold `
    + `(first: ${missingContainers[0]})`,
    `${capturesDir}/<hash>.ct`,
    'the follower\'s publish unit, whose ordering rule makes this impossible on a healthy bucket');
}

writeFileSync(join(outDir, 'snapshot.json'), `${JSON.stringify(snapshot, null, 2)}\n`);

const report = {
  chain,
  out: outDir,
  observationRecordsFound: obsFiles.length,
  observationUsed: `${observation.range?.from}-${observation.range?.to}`,
  blocks: blocks.length,
  transactions: transactions.length,
  accountedFor,
  containers,
  sourceBundles: sources,
  observed: (observation.observed ?? []).length,
  captured: (observation.captured ?? []).length,
  refusals: (observation.refusals ?? []).length,
};
if (has('json')) console.log(JSON.stringify(report, null, 2));
else console.error(`snapshot-from-ingest: ${transactions.length} transaction(s), ${blocks.length} block(s), `
  + `${containers} container(s) -> ${outDir}/snapshot.json`);
