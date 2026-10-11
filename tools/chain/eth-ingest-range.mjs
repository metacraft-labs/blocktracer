#!/usr/bin/env node
//
// eth-ingest-range.mjs — ETHEREUM MAINNET: RECORD THAT A CAPTURED RANGE IS COVERED, AND
// PUBLISH THE UNION OF EVERYTHING COVERED SO FAR.
//
// ── THE DEFECT THIS EXISTS FOR, MEASURED ON THIS MACHINE ──────────────────────────────
//
// `capture-eth-range.mjs` produces one `blocktracer/chain-snapshot@2` tree per range, and
// `eth-publish-proof.sh` proved that `blocktracer-chain-ingest` + `blocktracer-publish`
// accept such a tree and fill an object store with it. Both of those are per-range
// statements, and the thing a DEPLOYED FOLLOWER does is publish range after range into one
// store. That composition was never measured. It was, and it loses coverage silently:
//
//   Two real adjacent ranges — 26157390-26157392 and 26157393-26157395, both captured by
//   `capture-eth-range.mjs` against `https://eth.drpc.org` — ingested separately at
//   generation "1" and published into one local store. The second cycle reported
//
//       content uploaded : 2254
//       content skipped  : 4
//       pointer flipped  : true
//       rc               : 0
//
//   and the four skipped objects were exactly the whole-chain singletons:
//
//       d/ethereum-mainnet/g/1/height/0.json
//       d/ethereum-mainnet/g/1/blocks/0.json
//       d/ethereum-mainnet/g/1/summary.json
//       d/ethereum-mainnet/g/1/root.json
//
//   `publisher.nim` classifies `d/{chain}/g/{gen}/**` as `ocGenMap` / `ocGenRoot`, whose
//   strategy is `stKeyExistence` — present implies skip. So range B's versions of all four
//   were DECLINED as "already there", while `current.json` is `stUnconditional` and was
//   rewritten. The store ended with every block object of both ranges present and
//   fetchable by hash, and:
//
//       FAIL  POINTER — each chain's current.json names a generation whose root is sealed
//                       and a head the height map contains
//         ! chain 'ethereum-mainnet': `current.json` advertises head height 26157395 and
//           generation '1's height map does not contain it — the map's highest is
//           26157392. The pointer is advertising 3 height(s) of data that the generation
//           it names does not map.
//
//   Nothing failed. Both cycles exited 0. Three heights were unlisted.
//
// THE KEY-EXISTENCE STRATEGY IS NOT THE BUG AND IS NOT TOUCHED HERE. A generation map is
// immutable at its path — that is what the contract's whole ordering argument (content
// before references, root before pointer) rests on — so "present implies skip" is the
// correct strategy for it. What is wrong is publishing DIFFERENT content at a path that
// has already been sealed. There are two separable mistakes in doing that, and this tool
// fixes both:
//
//   1. THE CONTENT WAS PARTIAL. The maps are whole-chain singletons written from the one
//      snapshot the ingest was handed, so a per-range snapshot produces a per-range map.
//      Fixed by ingesting the UNION over the coverage ledger — see `mergeSnapshots`.
//   2. THE GENERATION ID DID NOT MOVE. New content owes a new generation. Fixed by
//      DERIVING the id from what the generation contains — see `generationFor`.
//
// Either alone is insufficient, and that is the reason both are here rather than one:
// a union at a fixed generation is skipped exactly as before (the maps are already sealed
// at `g/1/`), and a fresh generation over a per-range snapshot writes a map that the
// pointer agrees with and that still lists only the newest range — a pointer that no
// longer lies about a map that has quietly dropped range A. The second shape is worse than
// the first, because the detector that caught the first cannot see it.
//
// ── WHAT IS PER-RANGE AND WHAT IS WHOLE-CHAIN, FOR THIS CHAIN'S LAYOUT ────────────────
//
// Measured, by intersecting the two ingested trees' key sets: 15 of their keys collide, and
// they fall into three groups that behave differently.
//
//   * `registry/chains.v1.json` — collides and is BYTE-IDENTICAL. Nothing to resolve.
//   * 10 pointers (`d/{chain}/current.json` and nine `src/{chain}/{hash}/current.json`) —
//     collide, differ, and are `stUnconditional`, so they are rewritten every cycle by
//     design. Correct, and the reason the defect is invisible: the pointer always moves.
//   * 4 generation singletons — collide, differ, and are skipped. The defect.
//
// Everything else is keyed by hash (`d/{chain}/block/{hash}.json`, `d/{chain}/tx/**`,
// `t/**`, `src/{chain}/{hash}/**`) and never collides between ranges. That is the property
// the whole operation rests on and this tool does not disturb it: a range stays
// independently capturable and independently refreshable, and only the four singletons are
// recomputed from the union.
//
// ── NO ABSTRACTION IS INTRODUCED, AND NONE IS SHARED WITH THE AZTEC PATH ─────────────
//
// `tools/chain/ingest-range.mjs` is Aztec's range ingest and solves the same problem; this
// is Ethereum's, and the two share no interface, no plugin, no registered module and no
// dispatch site. This file imports nothing from `ingest-range.mjs` and `ingest-range.mjs`
// imports nothing from this file. ING-7's two-consumer rule is SPENT BY THIS FILE'S
// EXISTENCE rather than by this file: a second CONCRETE range ingest is what licenses DEL-7
// to extract a seam from the two and measure it, and a seam guessed from one consumer is
// what that rule exists to prevent. Where this file wanted to share something with the
// Aztec one, the wanting is a comment — search for `DEL-7`.
//
// What IS shared is shared because it already had two consumers before this file:
//
//   * `lib/recount.mjs` — the snapshot tallies. A merged snapshot is a new tree and its
//     `counts` must be recomputed, which is the exact defect that module's header records
//     having reached committed data. Consumers before this file: `ingest-range.mjs`,
//     `migrate-chain-facts.mjs`.
//   * `lib/snapshot-format.mjs` — the format string a reader accepts.
//
// It states NO transaction row and therefore is not a producer in
// `lib/producer-scan.mjs`'s sense, and must not become one: `mergeSnapshots` carries rows
// across by reference, so every published row member is still stated once, by
// `produce-eth-snapshot.mjs`, in the range snapshot this tool merely unions. `§14` of
// `snapshot-contract-selftest.mjs` compares the producer roster by name, so a row literal
// added here would arrive as a named failure — correctly.
//
// ── THE RANGE KEY IS DERIVED FROM THE SNAPSHOT, NOT STATED BY THE CALLER ─────────────
//
// `--from`/`--to` would be a claim about a tree this tool can simply read: the range is
// `min..max` of the snapshot's own `blocks[]`. A stated range that disagreed with the tree
// would put a key in the ledger that describes something other than the snapshot filed
// under it, and the coverage claim is then about the key rather than about the data. So the
// range is MEASURED, and `--expect-from`/`--expect-to` are available for a caller that
// wants its request checked rather than trusted — a daemon that asked for 26157390-92
// should find out if it filed 26157390-91.
//
// THE DERIVED RANGE MUST BE CONTIGUOUS, and a hole is refused rather than spanned.
// `§5.2` requires every enumerated block to appear in the snapshot, so a gap in `blocks[]`
// means the capture did not enumerate what its own span claims, and filing it as
// `min-max` would make the ledger assert coverage of heights no object exists for — which
// is the precise falsehood the ledger exists to make checkable.
//
// ── THE KEY IS ZERO-PADDED, AND THAT IS LOAD-BEARING ─────────────────────────────────
//
// Directory and bucket listings are LEXICOGRAPHIC. Ethereum mainnet is past block
// 26,000,000, so eight digits is already not enough headroom to be comfortable and nine
// sorts correctly to a billion blocks. The padding width is recorded in the ledger and a
// ledger written at another width is REFUSED rather than merged: `026157390-026157392` and
// `26157390-26157392` are two keys for one range, and the coverage arithmetic would count
// both.
//
// ── OVERLAP IS MERGED, NOT REFUSED, AND IS DEDUPED BY HEIGHT ─────────────────────────
//
// A daemon restarted mid-range re-asks for part of what it already has, so overlap is a
// normal input and not an operator error. `mergeSnapshots` unions by block NUMBER and by
// transaction HASH, both into a `Map`, so a height covered by two ranges contributes one
// block and one set of rows however many ranges name it. That makes overlap idempotent by
// construction rather than by a check.
//
// The ledger still records both ranges verbatim, because each is an honest record of what
// was fetched and when and at what code version. One consequence is worth naming rather
// than hiding: `blocktracer-verify-published --ledger` sums `served` PER RANGE, so with
// overlapping ranges its `servedTotal` note counts a shared height once per range that
// names it. Its actual comparison is against a SET (`servedAll`), so the missing-height
// verdict is unaffected — only the printed total is a multiset. `coverage-contiguity.mjs`
// reports the overlap by name, which is what it is for.
//
// ── THE LEDGER IS THE SHAPE TWO EXISTING READERS ALREADY PARSE ───────────────────────
//
// `blocktracer/coverage-ledger@1`, with `ranges[key].from`, `.to` and
// `.fetch.notServed`. That is not a new format and adopting it is not an abstraction: it
// is the published shape `src/blocktracer/verify/audit.nim`'s `readLedger` and
// `tools/chain/coverage-contiguity.mjs` ALREADY read, and writing anything else would mean
// this chain's coverage could not be audited by the tool whose whole purpose is auditing
// coverage. Writing it turns `verify-published`'s LEDGER check from UNRUNNABLE into an
// exhaustive whole-range comparison that costs two objects and no traffic.
//
// ── USAGE ─────────────────────────────────────────────────────────────────────────────
//
//   node tools/chain/eth-ingest-range.mjs --snapshot <capture tree> \
//     [--state .eth-chain-state] [--chain ethereum-mainnet] \
//     [--ingest-bin blocktracer-chain-ingest] [--publish-bin blocktracer-publish] \
//     [--backend local|s3] [--dest DIR | --bucket B --endpoint U --prefix P] \
//     [--expect-from N --expect-to M] [--generation G] [--pad 9] \
//     [--no-publish] [--no-merge] [--refile] [--json]
//
//   --no-merge    ingest ONLY this range's snapshot, not the union — THE REPRODUCTION of
//                 the defect above, kept reachable on purpose. With `--generation 1` it
//                 reproduces the exact key-existence collision and the POINTER failure
//                 quoted at the top; without it, it reproduces the quieter shape (a fresh
//                 generation whose map lists only the newest range).
//   --refile      re-file a range the ledger already covers, from this snapshot
//   --no-publish  file and ingest, stop before the object store
//
// Exit codes: 0 the range is filed (and published, unless `--no-publish`) · 1 a step
// refused · 2 this invocation is wrong.
//
// ── NO MOCKS ──────────────────────────────────────────────────────────────────────────
//
// There are none. The snapshots are real captures of Ethereum mainnet, the ingest and the
// publisher are the shipping binaries driven by their documented flags, and the store is a
// real directory whose `putIfAbsent` is a genuine `O_CREAT|O_EXCL`. Every figure this file
// prints is read from one of those or counted from the ledger.

import { readFileSync, writeFileSync, existsSync, mkdirSync, renameSync, readdirSync,
         statSync, linkSync, copyFileSync, rmSync } from 'node:fs';
import { join, resolve, dirname, relative } from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';

import { recountSnapshot } from './lib/recount.mjs';
import { SNAPSHOT_FORMAT } from './lib/snapshot-format.mjs';

const HERE = 'tools/chain/eth-ingest-range.mjs';

/** This tool's one chain's default slug. Not a parameter over chains. */
const DEFAULT_CHAIN = 'ethereum-mainnet';

/** The ledger format, i.e. the shape `audit.nim` and `coverage-contiguity.mjs` parse. */
const LEDGER_FORMAT = 'blocktracer/coverage-ledger@1';

// ---------------------------------------------------------------------------
// refusals — a FIELD and not a class, for the reason `capture-eth-range.mjs` gives where
// it makes the same choice: the exit code needs two kinds of refusal, not two kinds of
// object.
// ---------------------------------------------------------------------------

const ConfigRefusal = 'config';
const SourceRefusal = 'source';
const refuse = (kind, message) => Object.assign(new Error(message), { refusalKind: kind });

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const argv = process.argv.slice(2);
const arg = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  if (i === -1) {
    const eq = argv.find((a) => a.startsWith(`--${name}=`));
    return eq ? eq.slice(name.length + 3) : dflt;
  }
  const v = argv[i + 1];
  if (v === undefined || v.startsWith('--')) {
    throw refuse(ConfigRefusal, `--${name} takes a value`);
  }
  return v;
};
const flag = (name) => argv.includes(`--${name}`);

const intArg = (name, dflt) => {
  const raw = arg(name);
  if (raw === undefined) return dflt;
  const n = Number(raw);
  if (!Number.isInteger(n)) {
    throw refuse(ConfigRefusal, `--${name} must be an integer (got ${raw})`);
  }
  return n;
};

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const sha = (s) => createHash('sha256').update(s).digest('hex');

/**
 * Every file under `dir`, as paths relative to it, sorted.
 * Used for the tree digests this tool reports and for copying a range into the ledger.
 */
function walkFiles(dir, base = dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
         a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walkFiles(p, base, out);
    else out.push(relative(base, p));
  }
  return out;
}

/** Hard-link, falling back to a copy across devices. The bytes are identical either way. */
function linkOrCopy(from, to) {
  mkdirSync(dirname(to), { recursive: true });
  try { linkSync(from, to); } catch { copyFileSync(from, to); }
}

export function main() {
  const snapshotArg = arg('snapshot');
  const stateDir = resolve(arg('state', '.eth-chain-state'));
  const chain = arg('chain', DEFAULT_CHAIN);
  const pad = intArg('pad', 9);
  const ingestBin = arg('ingest-bin', 'blocktracer-chain-ingest');
  const publishBin = arg('publish-bin', 'blocktracer-publish');
  const backend = arg('backend', 'local');
  const dest = arg('dest', join(stateDir, 'store'));
  const bucket = arg('bucket', '');
  const endpoint = arg('endpoint', '');
  const prefix = arg('prefix', '');
  // "" => derived from what the generation CONTAINS. See `generationFor`.
  const generation = arg('generation', '');
  const expectFrom = intArg('expect-from', undefined);
  const expectTo = intArg('expect-to', undefined);
  const noPublish = flag('no-publish');
  const noMerge = flag('no-merge');
  const refile = flag('refile');
  const jsonOnly = flag('json');
  const writer = arg('writer', HERE);

  if (!snapshotArg) {
    throw refuse(ConfigRefusal,
      '--snapshot <dir> is required: a `blocktracer/chain-snapshot@2` tree that '
      + '`capture-eth-range.mjs` (or `produce-eth-snapshot.mjs`) wrote. This tool files a '
      + 'CAPTURED range and publishes the union of everything filed; it reaches no chain '
      + 'and runs no recorder, which is what keeps the capture independently refreshable.');
  }
  if (pad < 1 || pad > 18) {
    throw refuse(ConfigRefusal, `--pad must be between 1 and 18 (got ${pad})`);
  }
  if ((expectFrom === undefined) !== (expectTo === undefined)) {
    throw refuse(ConfigRefusal,
      `--expect-from and --expect-to are given together or not at all (got `
      + `from=${expectFrom} to=${expectTo}). Half a stated range is a range whose other `
      + `end this tool would have to invent, which is the opposite of checking a claim.`);
  }

  const say = (m) => { if (!jsonOnly) console.error(`eth-ingest-range: ${m}`); };
  const padN = (n) => String(n).padStart(pad, '0');

  const LEDGER = join(stateDir, 'coverage.json');
  const RANGES = join(stateDir, 'ranges');
  const MERGED = join(stateDir, 'merged');
  const TREE = join(stateDir, 'tree');

  // ── the snapshot, and the range it actually holds ────────────────────────
  const snapshotDir = resolve(snapshotArg);
  const snapshotPath = join(snapshotDir, 'snapshot.json');
  if (!existsSync(snapshotPath)) {
    throw refuse(ConfigRefusal, `no snapshot at ${snapshotPath}`);
  }
  const snap = JSON.parse(readFileSync(snapshotPath, 'utf8'));
  if (snap.format !== SNAPSHOT_FORMAT) {
    throw refuse(SourceRefusal,
      `${snapshotPath} states format '${snap.format}' and this tool reads `
      + `'${SNAPSHOT_FORMAT}'. A reader that guesses at a format it does not know is how a `
      + `member that moved becomes a silently absent member.`);
  }
  if (snap.provenance?.chain && snap.provenance.chain !== chain) {
    throw refuse(SourceRefusal,
      `${snapshotPath} was captured from chain '${snap.provenance.chain}' and this run `
      + `files under '${chain}'. Publishing one chain's blocks under another's slug would `
      + `make them indistinguishable in a URL.`);
  }
  if (!Array.isArray(snap.blocks) || snap.blocks.length === 0) {
    throw refuse(SourceRefusal,
      `${snapshotPath} holds no blocks, so there is no range to file. A ledger entry over `
      + `no block would assert coverage of nothing while counting as a covered range.`);
  }

  const heights = snap.blocks.map((b) => b.number).sort((a, b) => a - b);
  const from = heights[0];
  const to = heights[heights.length - 1];
  // CONTIGUITY IS CHECKED, NOT ASSUMED — see the header. A hole means the capture did not
  // enumerate its own span, and filing it as `min-max` would make the ledger claim heights
  // no object exists for.
  const holes = [];
  for (let h = from, i = 0; h <= to; h++) {
    if (heights[i] === h) { i++; continue; }
    holes.push(h);
    if (holes.length >= 10) break;
  }
  if (holes.length > 0) {
    throw refuse(SourceRefusal,
      `${snapshotPath} spans ${from}..${to} but its blocks[] does not contain `
      + `${holes.join(', ')}${holes.length >= 10 ? ', …' : ''}. §5.2 requires every `
      + `enumerated block to appear, so this snapshot's own span is not what it covers — `
      + `filing it as '${from}-${to}' would make the ledger assert coverage of heights no `
      + `object exists for. Re-capture the range.`);
  }
  if (new Set(heights).size !== heights.length) {
    throw refuse(SourceRefusal,
      `${snapshotPath} lists the same block height twice, so its blocks[] is not a set of `
      + `heights and the range it covers cannot be derived from it.`);
  }
  if (expectFrom !== undefined && (expectFrom !== from || expectTo !== to)) {
    throw refuse(SourceRefusal,
      `--expect-from ${expectFrom} --expect-to ${expectTo} was asked for and `
      + `${snapshotPath} holds ${from}..${to}. The range is DERIVED from the snapshot, so `
      + `this is the capture disagreeing with the request rather than a naming choice: `
      + `filing it would record coverage of a span the caller did not ask for.`);
  }

  const rangeKey = `${padN(from)}-${padN(to)}`;
  say(`snapshot ${snapshotDir}`);
  say(`range    ${from}..${to} (derived from blocks[]) => key '${rangeKey}'`);

  // ── the code version a range was filed AT ───────────────────────────────
  //
  // "Eventually full coverage" is only measurable if a range records WHAT produced it, so
  // a defect found later becomes a list of ranges to redo rather than a decision to redo
  // everything. Four identities, because they answer four questions: the repository commit
  // says which source, the two binary digests say which build (a dirty tree and a rebuilt
  // binary move these without moving the commit), and the snapshot digest says which
  // capture — which is the one this tool does not produce and therefore cannot infer.
  const codeVersion = () => {
    const git = (a) => {
      const r = spawnSync('git', a, { cwd: process.cwd(), encoding: 'utf8' });
      return r.status === 0 ? r.stdout.trim() : '';
    };
    const digest = (p) => {
      try { return sha(readFileSync(p)).slice(0, 16); } catch { return ''; }
    };
    const resolveBin = (b) => {
      if (b.includes('/')) return resolve(b);
      const r = spawnSync('command', ['-v', b], { shell: true, encoding: 'utf8' });
      return r.status === 0 ? r.stdout.trim() : b;
    };
    return {
      commit: git(['rev-parse', 'HEAD']),
      dirty: git(['status', '--porcelain']).length > 0,
      ingestBinDigest: digest(resolveBin(ingestBin)),
      publishBinDigest: digest(resolveBin(publishBin)),
      snapshotDigest: sha(readFileSync(snapshotPath)).slice(0, 16),
      recorderCommit: snap.provenance?.runtimeCommit ?? '',
    };
  };

  // ── the ledger ──────────────────────────────────────────────────────────
  const loadLedger = () => {
    if (!existsSync(LEDGER)) {
      return {
        format: LEDGER_FORMAT,
        chain,
        endpoint: snap.provenance?.endpoint ?? '',
        // Padded, and the width is RECORDED so a later reader can tell a nine-digit key
        // from a ten-digit one rather than inferring it from the keys it happens to see.
        keyPadding: pad,
        ranges: {},
      };
    }
    const l = JSON.parse(readFileSync(LEDGER, 'utf8'));
    if (l.format !== LEDGER_FORMAT) {
      throw refuse(SourceRefusal, `${LEDGER} is not a ${LEDGER_FORMAT}`);
    }
    // A LEDGER WRITTEN AT ANOTHER PADDING IS REFUSED RATHER THAN MERGED. Mixing widths in
    // one key space reintroduces exactly the ordering defect the padding exists to remove,
    // and does it invisibly: two keys for one range, both counted.
    if (l.keyPadding !== pad) {
      throw refuse(SourceRefusal,
        `${LEDGER} uses keyPadding ${l.keyPadding} and this run uses ${pad}`);
    }
    if (l.chain && l.chain !== chain) {
      throw refuse(SourceRefusal, `${LEDGER} covers chain '${l.chain}', this run files '${chain}'`);
    }
    return l;
  };
  const saveLedger = (l) => {
    mkdirSync(stateDir, { recursive: true });
    const tmp = `${LEDGER}.tmp`;
    writeFileSync(tmp, JSON.stringify(l, null, 1) + '\n');
    renameSync(tmp, LEDGER);
  };

  const ledger = loadLedger();
  const already = ledger.ranges[rangeKey];
  if (already && !refile) {
    say(`range ${rangeKey} is already in the ledger (filed at `
        + `${already.codeVersion?.snapshotDigest ?? '?'}); re-using its filed snapshot. `
        + `Pass --refile to replace it from --snapshot.`);
  }

  // ── file the range's snapshot into the ledger's own tree ────────────────
  //
  // COPIED IN RATHER THAN REFERENCED BY PATH. The ledger's claim is that a range is
  // covered, and a claim that resolves through a path outside the state directory is a
  // claim about whatever is at that path today — `capture-eth-range.mjs` defaults `--out`
  // to one directory (`.eth-range/tree`) and overwrites it on the next range, so
  // referencing it would make every filed range mean the most recent capture.
  const rangeDir = join(RANGES, rangeKey);
  if (!already || refile) {
    if (existsSync(rangeDir)) rmSync(rangeDir, { recursive: true, force: true });
    mkdirSync(rangeDir, { recursive: true });
    let filed = 0;
    for (const rel of walkFiles(snapshotDir)) {
      linkOrCopy(join(snapshotDir, rel), join(rangeDir, rel));
      filed++;
    }
    say(`filed    ${filed} file(s) into ${rangeDir}`);
  }

  // ── THE LEDGER ENTRY IS WRITTEN BEFORE THE PUBLISH ─────────────────────
  //
  // An interrupted run must leave a ledger that is honest about what it has, and the two
  // failure directions are not symmetric: a range the ledger has never heard of is simply
  // re-captured, while a range it records as published that is not would be a coverage
  // claim nothing can detect. So "filed" is recorded first and "published" only after the
  // publisher returns.
  //
  // `fetch.notServed` is EMPTY and that is a measurement rather than an optimism: the
  // contiguity check above refused any hole in `blocks[]`, so every height in [from..to]
  // has a block object in this snapshot. A capture that could not read a height does not
  // reach this line.
  ledger.ranges[rangeKey] = {
    ...(already ?? {}),
    from, to,
    fetch: { requested: to - from + 1, served: to - from + 1, notServed: [] },
    blocks: snap.blocks.length,
    transactions: snap.transactions?.length ?? 0,
    tracesPublished: snap.counts?.tracesPublished ?? 0,
    capturedAt: snap.provenance?.capturedAt ?? '',
    endpoint: snap.provenance?.endpoint ?? '',
    codeVersion: codeVersion(),
    filedAt: new Date().toISOString(),
  };
  saveLedger(ledger);

  // ── phase 2: the union snapshot the tree is ingested from ───────────────
  //
  // DEL-7: `ingest-range.mjs:mergeSnapshots` does the same job for Aztec and the two are
  // close enough that an extraction is worth measuring — the differences are the sidecar
  // members carried across (this chain has `positions`, `instructions` and `calltrace`
  // where Aztec has `sourceBundles`) and the window member's meaning. Not extracted here:
  // see the header on ING-7.
  const mergeSnapshots = (keys) => {
    const blocksByNumber = new Map();
    const txByHash = new Map();
    let newest = null;
    let window = null;
    let provenance = null;
    let captures = [];
    let artifactResolution = null;
    // Padded, so lexicographic order IS numeric order and the newest range is last.
    for (const k of keys.slice().sort()) {
      const p = join(RANGES, k, 'snapshot.json');
      if (!existsSync(p)) continue;
      const s = JSON.parse(readFileSync(p, 'utf8'));
      // BY REFERENCE, NOT RESTATED. A row is carried across exactly as the producer wrote
      // it, which is what keeps every published row member stated once and keeps this file
      // out of `producer-scan.mjs`'s roster. Overlap dedups here: one entry per height and
      // one per transaction hash, however many ranges name them.
      for (const b of s.blocks) blocksByNumber.set(b.number, b);
      for (const t of s.transactions) if (!txByHash.has(t.txHash)) txByHash.set(t.txHash, t);
      captures = captures.concat(s.captures ?? []);
      // The union's window is the one observed LATEST: it describes what was replayable at
      // the moment the newest range was read, which is the only moment any of it is true of.
      const at = s.provenance?.capturedAt ?? '';
      if (newest === null || at > newest) {
        newest = at; window = s.window; provenance = s.provenance;
        artifactResolution = s.artifactResolution;
      }
    }
    const blocks = [...blocksByNumber.values()].sort((a, b) => b.number - a.number);
    const transactions = [...txByHash.values()].sort(
      (a, b) => a.blockNumber - b.blockNumber || a.txIndexInBlock - b.txIndexInBlock);
    const merged = {
      format: SNAPSHOT_FORMAT,
      provenance: { ...provenance, tool: `${HERE} (merged)`,
                    mergedRanges: keys.slice().sort() },
      window, counts: {}, blocks, transactions, captures,
      ...(artifactResolution === undefined ? {} : { artifactResolution }),
    };
    // RECOUNTED, NEVER CARRIED. `counts` are whole-tree facts and a merged tree is a new
    // tree; N tallies nobody recomputed is the exact defect `lib/recount.mjs`'s header
    // records having reached committed data.
    recountSnapshot(merged);

    // ── THE ARTIFACTS HAVE TO BE WHERE THE MERGED SNAPSHOT SAYS THEY ARE ─
    //
    // A row's sidecar paths are RELATIVE to the snapshot directory, deliberately, so a
    // snapshot carries no absolute path from whoever ran the capture. That makes the merged
    // directory a snapshot with no artifacts beside it unless they are brought along, and
    // `blocktracer-chain-ingest` would refuse the row — or, worse, publish a row pointing
    // at nothing.
    //
    // Linked rather than copied: a range's artifacts are its own, the merged directory is a
    // rendering of one moment (rebuilt from scratch every run for that reason), and a
    // container runs to hundreds of kilobytes.
    if (existsSync(MERGED)) rmSync(MERGED, { recursive: true, force: true });
    mkdirSync(MERGED, { recursive: true });
    // THE SIDECAR MEMBER NAMES ARE DERIVED FROM THE ROWS, NOT LISTED HERE. A hardcoded
    // list of sidecar members cannot see the one a later producer adds, and the symptom
    // would be a published row referencing an artifact that was never linked across —
    // invisible until a reader followed it. Any row member whose value is a relative path
    // to a file that exists under the owning range is brought along.
    let linked = 0;
    const owners = keys.slice().sort();
    const ownerOf = (blockNumber) => {
      // Arithmetic on the block number rather than a directory scan: a scan would pick the
      // first match silently, and with overlapping ranges `mergeSnapshots` has already
      // resolved WHICH range's row won, so the artifact must come from a range that
      // actually contains the height.
      for (const k of owners) {
        const [a, b] = k.split('-').map(Number);
        if (Number.isFinite(a) && Number.isFinite(b) && blockNumber >= a && blockNumber <= b) {
          const p = join(RANGES, k);
          if (existsSync(p)) return k;
        }
      }
      return null;
    };
    for (const t of transactions) {
      const owner = ownerOf(t.blockNumber);
      if (!owner) continue;
      for (const v of Object.values(t)) {
        if (typeof v !== 'string' || v.length === 0 || v.startsWith('/')) continue;
        const src = join(RANGES, owner, v);
        const dst = join(MERGED, v);
        if (!existsSync(src) || existsSync(dst)) continue;
        try { if (!statSync(src).isFile()) continue; } catch { continue; }
        linkOrCopy(src, dst);
        linked++;
      }
    }
    writeFileSync(join(MERGED, 'snapshot.json'), JSON.stringify(merged, null, 1) + '\n');
    return { dir: MERGED, blocks: blocks.length, transactions: transactions.length,
             linked, blockHashes: blocks.map((b) => b.hash),
             heights: blocks.map((b) => b.number).sort((a, b) => a - b) };
  };

  // ── the generation id, derived from what the generation CONTAINS ────────
  //
  // A GENERATION MAP IS IMMUTABLE AT ITS PATH, AND THAT IS NOT A STYLE NOTE. See the
  // header's measurement: `publisher.nim` classifies `d/{chain}/g/{gen}/**` as `ocGenMap` /
  // `ocGenRoot` with `stKeyExistence`, so a second publish at the SAME generation id skips
  // the height map, the block list, the summary and the root, while `current.json` — a
  // pointer — is rewritten unconditionally and moves the head.
  //
  // The fix is not to make the maps mutable: the contract's ordering argument (content
  // before references, root before pointer) depends on them being sealed. It is to give
  // DIFFERENT content a DIFFERENT generation.
  //
  // DERIVED rather than counted, so that idempotence survives it. A counter would bump on
  // every run and re-upload the whole index layer for an unchanged chain, turning the
  // "re-run uploads zero objects" property that `eth-publish-proof.sh` arm 2 measures into
  // its opposite. A digest of the covered content changes exactly when the covered content
  // changes, which is exactly when a new generation is owed.
  const generationFor = (keys, blockHashes) => {
    if (generation.length > 0) return generation;
    return 'r' + sha(JSON.stringify({ ranges: keys.slice().sort(), blocks: blockHashes }))
      .slice(0, 12);
  };

  const covered = Object.keys(ledger.ranges);
  const sourceKeys = noMerge ? [rangeKey] : covered;
  const source = mergeSnapshots(sourceKeys);
  const gen = generationFor(sourceKeys, source.blockHashes);

  if (noMerge) {
    say('');
    say('--no-merge: THE REPRODUCTION, not the fix. This ingests ONLY this range\'s');
    say(`snapshot (${source.blocks} block(s)), while the ledger covers `
        + `${covered.length} range(s). The published generation maps are whole-chain`);
    say('singletons, so the height map, the block list, the summary and the root will');
    say('describe this range alone. With --generation held fixed across two runs the');
    say('publisher SKIPS all four as already-present and the pointer moves anyway —');
    say('`blocktracer-verify-published` then fails POINTER by name. Without a fixed');
    say('generation the maps are written at a fresh id and the pointer agrees with a map');
    say('that has quietly dropped every other range.');
    say('');
  }

  say(`union    ${source.blocks} block(s), ${source.transactions} transaction(s), `
      + `${source.linked} artifact(s) linked, over ${sourceKeys.length} range(s)`);
  say(`heights  ${source.heights[0]}..${source.heights[source.heights.length - 1]} `
      + `(${source.heights.length} distinct)`);
  say(`generation ${gen}${generation.length > 0 ? ' (stated)' : ' (derived from content)'}`);

  const report = {
    tool: HERE, chain, rangeKey, from, to,
    merged: !noMerge,
    coveredRanges: covered.length,
    ingestSource: source.dir,
    union: { blocks: source.blocks, transactions: source.transactions,
             heights: source.heights.length, linked: source.linked },
    generation: gen,
  };

  // ── phase 3: the ingest ─────────────────────────────────────────────────
  if (existsSync(TREE)) rmSync(TREE, { recursive: true, force: true });
  const ing = spawnSync(ingestBin,
    ['--snapshot', source.dir, '--out', TREE, '--generation', gen],
    { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (ing.error) {
    throw refuse(ConfigRefusal, `could not run '${ingestBin}': ${ing.error.message}`);
  }
  if (ing.status !== 0) {
    throw refuse(SourceRefusal,
      `${ingestBin} refused the union snapshot (rc=${ing.status}):\n`
      + `${(ing.stdout ?? '') + (ing.stderr ?? '')}`);
  }
  try { report.ingest = JSON.parse(ing.stdout); } catch { report.ingest = { raw: ing.stdout }; }
  const treeObjects = existsSync(TREE) ? walkFiles(TREE).length : 0;
  report.treeObjects = treeObjects;
  say(`ingest   rc=0, ${treeObjects} object(s) in ${TREE}`);

  ledger.ranges[rangeKey].ingestedAt = new Date().toISOString();
  ledger.liveGeneration = gen;
  saveLedger(ledger);

  // ── phase 4: the publish ────────────────────────────────────────────────
  if (noPublish) {
    say('--no-publish: stopping before the object store.');
  } else {
    const pubArgs = ['--tree', TREE, '--backend', backend, '--writer', writer];
    if (backend === 'local') pubArgs.push('--dest', dest);
    else {
      if (!bucket) {
        throw refuse(ConfigRefusal, `--backend ${backend} needs --bucket`);
      }
      pubArgs.push('--bucket', bucket);
      if (endpoint) pubArgs.push('--endpoint', endpoint);
      if (prefix) pubArgs.push('--prefix', prefix);
    }
    const pub = spawnSync(publishBin, pubArgs,
      { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
    if (pub.error) {
      throw refuse(ConfigRefusal, `could not run '${publishBin}': ${pub.error.message}`);
    }
    const out = (pub.stdout ?? '') + (pub.stderr ?? '');
    if (pub.status !== 0) {
      throw refuse(SourceRefusal, `${publishBin} refused (rc=${pub.status}):\n${out}`);
    }
    const field = (label) => {
      const m = out.match(new RegExp(`^\\s*${label}\\s*:\\s*(.*)$`, 'm'));
      return m ? m[1].trim() : '';
    };
    report.publish = {
      dest: backend === 'local' ? dest : `${bucket}${prefix ? '/' + prefix : ''}`,
      uploaded: Number(field('content uploaded')),
      skipped: Number(field('content skipped')),
      refreshed: Number(field('content refreshed')),
      pointers: Number(field('pointers written')),
      flipped: field('pointer flipped') === 'true',
      generation: field('published generation'),
    };
    say(`publish  rc=0, uploaded ${report.publish.uploaded}, `
        + `skipped ${report.publish.skipped}, pointers ${report.publish.pointers}, `
        + `flipped ${report.publish.flipped}, generation ${report.publish.generation}`);

    ledger.ranges[rangeKey].publishedAt = new Date().toISOString();
    ledger.ranges[rangeKey].publishedTo = report.publish.dest;
    // PUBLISHED IS NOT VISIBLE, and the difference is the whole point of this tool. A range
    // is only reachable once a live generation's maps LIST it, so the ledger records which
    // generation made it visible rather than only that an upload happened.
    ledger.ranges[rangeKey].visibleInGeneration = report.publish.generation || gen;
    ledger.liveGeneration = report.publish.generation || gen;
    saveLedger(ledger);
  }

  // ── coverage arithmetic: the claim the ledger exists to make checkable ──
  const coverage = (l) => {
    const rs = Object.values(l.ranges);
    if (rs.length === 0) return { ranges: 0, distinctHeights: 0 };
    const all = new Set();
    for (const r of rs) for (let h = r.from; h <= r.to; h++) all.add(h);
    const lo = Math.min(...rs.map((r) => r.from));
    const hi = Math.max(...rs.map((r) => r.to));
    const missing = [];
    for (let h = lo; h <= hi && missing.length < 10; h++) if (!all.has(h)) missing.push(h);
    // STATED AS A MULTISET TOO, so an overlap is visible rather than averaged away: the
    // sum over ranges exceeding the distinct count is exactly what overlap means.
    const summed = rs.reduce((n, r) => n + (r.to - r.from + 1), 0);
    return {
      ranges: rs.length,
      lowest: lo, highest: hi,
      distinctHeights: all.size,
      summedHeights: summed,
      overlapping: summed - all.size,
      span: hi - lo + 1,
      contiguous: all.size === hi - lo + 1,
      firstHoles: missing,
    };
  };
  ledger.coverage = coverage(ledger);
  ledger.updatedAt = new Date().toISOString();
  saveLedger(ledger);
  report.coverage = ledger.coverage;

  say(`coverage ${ledger.coverage.ranges} range(s), `
      + `${ledger.coverage.distinctHeights} distinct height(s) over span `
      + `${ledger.coverage.lowest}..${ledger.coverage.highest}, `
      + `contiguous=${ledger.coverage.contiguous}, `
      + `overlapping=${ledger.coverage.overlapping}`);
  say(`ledger   ${LEDGER}`);

  if (jsonOnly) console.log(JSON.stringify(report, null, 1));
  return report;
}

try {
  main();
} catch (e) {
  if (!e.refusalKind) throw e;
  console.error(`${HERE}: ${e.message}`);
  process.exit(e.refusalKind === ConfigRefusal ? 2 : 1);
}
