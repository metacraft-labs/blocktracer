#!/usr/bin/env node
// merge-sui-windows.mjs — one Sui snapshot tree from several separately captured windows.
//
//   node tools/chain/merge-sui-windows.mjs --tree DIR --tree DIR [...] --out DIR
//
// ── WHY ───────────────────────────────────────────────────────────────────────────────
//
// A chain's history is published as RANGES, not as one window: `ingest-range.mjs` keeps a
// per-range snapshot and hands the ingest the UNION of every range its ledger covers,
// because the published content is keyed by hash and never mentions a range, while the
// generation maps are whole-chain singletons. The ingest already tolerates a gap between
// two ranges (a block row carries `parentIndexed`). That is the route to a whole chain:
// ranges accumulate until the gaps close.
//
// `produce-sui-snapshot.mjs` writes ONE window and refuses a gap inside it ("a window is
// whole or it is not a window"), which stays right: inside one acquisition a skipped
// checkpoint is a defect. This tool is the other half: it unions windows that were each
// whole. It is the Sui twin of `ingest-range.mjs`'s `mergeSnapshots` (a concrete
// duplicate, per ING-7), and differs where Sui does:
//
//   * every artifact a Sui row names is carried — `container`, `positions`, `callTrace`
//     and `sourceBundles` — not only the container and the sources;
//   * a conflict is REFUSED rather than resolved by order: two windows that disagree about
//     a checkpoint's digest, a row's facts, the chain's floor or the producer that wrote
//     them are not one chain's history, and letting the later tree win would publish
//     whichever was merged last;
//   * the windows it was built from are recorded in `provenance.mergedWindows`.
//
// Deterministic: the same trees give the same bytes, whatever order `--tree` names them.

import { copyFileSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { recountSnapshot } from './lib/recount.mjs';

/** The artifact members a Sui row names, each a path relative to its tree. */
export const ARTIFACT_MEMBERS = Object.freeze(['container', 'positions', 'callTrace',
                                               'sourceBundles']);

/** Provenance members every window must agree on: they are facts about the producer and
 *  the chain, and a union of windows that disagree on one is not one chain's history. */
const AGREED_PROVENANCE = Object.freeze(['chain', 'recorder', 'prestateStrategy',
  'identifierEncoding', 'ordering', 'runtimeCommit', 'reachReason', 'verification', 'vm']);

const canonical = (v) => JSON.stringify(v, (_, x) => (x && typeof x === 'object' && !Array.isArray(x)
  ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, x[k]])) : x));

const refuse = (msg) => Object.assign(new Error(msg), { refusal: true });

/** The relative artifact paths a row names. */
export function artifactsOf(row) {
  const out = [];
  for (const m of ARTIFACT_MEMBERS) {
    const v = row[m];
    for (const p of Array.isArray(v) ? v : [v]) {
      if (typeof p === 'string' && p.length > 0) out.push(p);
    }
  }
  return out;
}

/**
 * The union of `snapshots` (each `{dir, snap}`), as `{merged, artifacts}` where
 * `artifacts` is `[from, rel]` pairs to copy. Pure apart from reading nothing: the caller
 * owns the filesystem.
 */
export function mergeWindows(snapshots) {
  if (snapshots.length < 2) throw refuse('a merge needs at least two windows');
  const ordered = [...snapshots].sort((a, b) => windowOf(a.snap).from - windowOf(b.snap).from);
  const first = ordered[0].snap;
  for (const { dir, snap } of ordered) {
    if (snap.format !== first.format) {
      throw refuse(`${dir} is format '${snap.format}', not '${first.format}'`);
    }
    for (const k of AGREED_PROVENANCE) {
      if (canonical(snap.provenance?.[k]) !== canonical(first.provenance?.[k])) {
        throw refuse(`${dir} disagrees on provenance.${k}; windows of one chain's history `
          + 'are written by one producer about one chain');
      }
    }
    if (snap.window?.replayableFrom !== first.window?.replayableFrom) {
      throw refuse(`${dir} measured the floor at ${snap.window?.replayableFrom}, not `
        + `${first.window?.replayableFrom}; the floor is a fact about the chain`);
    }
  }
  const blocks = new Map();
  const rows = new Map();
  const artifacts = new Map();
  let captures = [];
  for (const { dir, snap } of ordered) {
    for (const b of snap.blocks) {
      const had = blocks.get(b.number);
      if (had && canonical(had) !== canonical(b)) {
        throw refuse(`checkpoint ${b.number} differs between windows (${had.hash} / ${b.hash})`);
      }
      blocks.set(b.number, b);
    }
    for (const t of snap.transactions) {
      const had = rows.get(t.txHash);
      if (had && canonical(had) !== canonical(t)) {
        throw refuse(`transaction ${t.txHash} differs between windows`);
      }
      rows.set(t.txHash, t);
      for (const rel of artifactsOf(t)) {
        const from = join(dir, rel);
        if (artifacts.has(rel) && artifacts.get(rel) !== from) {
          const a = readFileSync(artifacts.get(rel));
          if (!a.equals(readFileSync(from))) {
            throw refuse(`artifact ${rel} differs between windows`);
          }
          continue;
        }
        artifacts.set(rel, from);
      }
    }
    captures = captures.concat(snap.captures ?? []);
  }
  // The window observed LATEST describes what was replayable when the newest window was
  // read, as `mergeSnapshots` decides; ties go to the higher tip, then the later window.
  const latest = [...ordered].sort((a, b) =>
    String(a.snap.provenance?.capturedAt ?? '').localeCompare(String(b.snap.provenance?.capturedAt ?? ''))
    || (a.snap.window?.tip ?? 0) - (b.snap.window?.tip ?? 0)).at(-1).snap;
  const mergedWindows = ordered.map(({ snap }) => windowOf(snap));
  const merged = {
    format: first.format,
    provenance: { ...latest.provenance, mergedWindows },
    window: latest.window,
    counts: {},
    blocks: [...blocks.values()].sort((a, b) => b.number - a.number),
    transactions: [...rows.values()].sort(
      (a, b) => a.blockNumber - b.blockNumber || a.txIndexInBlock - b.txIndexInBlock),
    captures,
  };
  recountSnapshot(merged);
  return { merged, artifacts: [...artifacts.entries()].sort(([a], [b]) => a.localeCompare(b)) };
}

/** A window's checkpoint span, read from its blocks. */
function windowOf(snap) {
  const nums = snap.blocks.map((b) => b.number);
  return { from: Math.min(...nums), to: Math.max(...nums) };
}

function main(argv) {
  const trees = [];
  let out = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--tree') trees.push(resolve(argv[++i]));
    else if (argv[i] === '--out') out = resolve(argv[++i]);
    else throw new Error(`unknown argument ${argv[i]}`);
  }
  if (!out || trees.length < 2) {
    console.error('usage: merge-sui-windows.mjs --tree DIR --tree DIR [...] --out DIR');
    process.exit(2);
  }
  const snapshots = trees.map((dir) => ({
    dir, snap: JSON.parse(readFileSync(join(dir, 'snapshot.json'), 'utf8')) }));
  const { merged, artifacts } = mergeWindows(snapshots);
  rmSync(out, { recursive: true, force: true });
  for (const [rel, from] of artifacts) {
    if (!existsSync(from)) throw refuse(`row names ${rel}, which ${dirname(from)} does not hold`);
    mkdirSync(dirname(join(out, rel)), { recursive: true });
    copyFileSync(from, join(out, rel));
  }
  writeFileSync(join(out, 'snapshot.json'), `${JSON.stringify(merged, null, 1)}\n`);
  const w = merged.provenance.mergedWindows.map((x) => `${x.from}..${x.to}`).join(', ');
  console.log(`wrote ${out}: windows ${w}, ${merged.blocks.length} checkpoint(s), `
    + `${merged.transactions.length} transaction(s), ${artifacts.length} artifact(s)`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { main(process.argv.slice(2)); }
  catch (e) { console.error(`merge-sui-windows.mjs: ${e.message}`); process.exit(1); }
}
