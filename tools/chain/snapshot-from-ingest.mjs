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

// -- TWO ROLLUPS MUST NOT MERGE INTO ONE CHAIN DIRECTORY ------------------------------
//
// `--out` is chosen by the caller, and the obvious choice for a chain slug is the
// directory that slug's EXISTING corpus lives in. That is safe exactly when the bucket
// and that corpus are the same chain -- and both Aztec networks have been restarted
// since their corpora were captured (`retired-networks.json`, measured 2026-10-28), so
// the obvious choice is now the dangerous one.
//
// THE NUMBERS OVERLAP TODAY. blocktracer.org publishes blocks 1..99,092 under
// `aztec-testnet` from the retired rollup; the live testnet was at 39,467 on 2026-11-17,
// INSIDE that range. Writing a live snapshot over that corpus would not append -- it
// would replace a block 39,467 belonging to one rollup with a different block 39,467
// belonging to another, under one chain name, and every number in the overlap with it.
//
// THE IDENTITY IS RECORDED ON BOTH SIDES, so this needs no new data and no guess about
// what the chain "is". `follow-chain.mjs` writes `l1ChainId`, `rollupVersion` and
// `rollupAddress` into provenance, and the committed corpora carry the same three: the
// frozen `aztec-testnet` snapshot reads rollupVersion 1821665230 / rollupAddress
// 0xd73a91bd..., while the live chain answers 679261766 / 0x1f435a7f.... Differing on
// any of the three means two rollups, whatever they are called.
//
// A COMPARISON THAT DID NOT HAPPEN IS NOT AGREEMENT. An existing snapshot carrying none
// of the three cannot be shown to be the same chain, so it refuses too rather than being
// waved through as probably fine -- the rule `put_block_row` follows in the publish unit,
// for the same reason.
//
// This says nothing about WHICH slug a restarted chain should publish under. That is a
// decision about what the site calls things; this only makes every answer to it safe.
const ROLLUP_IDENTITY = ['l1ChainId', 'rollupVersion', 'rollupAddress'];
const existingSnapshotPath = join(outDir, 'snapshot.json');
if (existsSync(existingSnapshotPath)) {
  let existing;
  try {
    existing = JSON.parse(readFileSync(existingSnapshotPath, 'utf8'));
  } catch (err) {
    throw new IngestBucketIncomplete(
      `${existingSnapshotPath} exists and could not be parsed (${err.message}), so the `
      + 'chain it holds cannot be compared with this bucket. Refusing rather than '
      + 'overwriting it',
      existingSnapshotPath, 'whatever wrote that file');
  }
  const theirs = existing.provenance ?? {};
  const mine = observation.provenance ?? {};
  const stated = ROLLUP_IDENTITY.filter(
    (k) => theirs[k] !== undefined && theirs[k] !== null && theirs[k] !== '');
  if (stated.length === 0) {
    throw new IngestBucketIncomplete(
      `${existingSnapshotPath} already holds a snapshot stating none of `
      + `${ROLLUP_IDENTITY.join(', ')}, so it cannot be shown to be the same rollup as `
      + 'this bucket. Refusing rather than overwriting it: a comparison that did not '
      + 'happen is not agreement',
      `${existingSnapshotPath} -> .provenance`, 'whatever wrote that file');
  }
  const differing = stated.filter((k) => String(theirs[k]) !== String(mine[k] ?? ''));
  if (differing.length > 0) {
    const lines = differing.map(
      (k) => `${k}: published ${JSON.stringify(theirs[k])} vs bucket `
        + `${JSON.stringify(mine[k] ?? '')}`);
    throw new IngestBucketIncomplete(
      `${existingSnapshotPath} holds a DIFFERENT rollup than this bucket, so writing here `
      + `would merge two chains under the slug '${chain}' -- ${lines.join('; ')}. `
      + 'Refusing. Publish the new rollup under a slug of its own, or point --out '
      + 'somewhere else',
      `${existingSnapshotPath} -> .provenance`,
      'tools/chain/chain-identity.json records the live deployment; the retired '
      + 'ones left retired-networks.json when their slugs were reused');
  }
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
