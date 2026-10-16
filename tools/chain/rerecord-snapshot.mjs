#!/usr/bin/env node
// rerecord-snapshot.mjs — re-record the traced transactions a snapshot already names.
//
// Usage:
//   node tools/chain/rerecord-snapshot.mjs --dir <snapshot-dir> --runtime <dir> \
//        --avm <avm.wasm> --ct-writer <aztec_ct_writer.wasm> --node <node-bin> \
//        [--url <rpc>] [--body-store auto] [--compact-threshold N] [--dry-run]
//   node tools/chain/rerecord-snapshot.mjs --selftest
//
// ── WHY THIS EXISTS, AND IT IS NOT capture-chain ───────────────────────────
//
// `capture-chain.mjs` and `follow-chain.mjs` both enumerate FROM THE TIP and
// replay what they find. Neither can re-record a transaction a snapshot already
// names, and that is the operation the corpus needs: the committed containers
// were written by a producer that emitted container version 3, the replay
// engine this site pins accepts {5, 6}, and `ct-corpus.json`'s `remedyNotes`
// has said "re-record" since 2026-10-04 without naming a command — because
// there was none.
//
// THE POPULATION IS THE SNAPSHOT'S OWN, never the tip. A tool that re-enumerated
// would produce a DIFFERENT corpus and call it a re-record; the whole point is
// that the transactions, the blocks and the effects stay the same and only the
// container format moves. So the subjects are exactly the rows carrying a
// `container`, read out of `snapshot.json`.
//
// ── ALL OR NOTHING, BECAUSE HALF A CORPUS IS WORSE THAN NONE ───────────────
//
// Every replay runs first, into a staging directory. The snapshot and the
// containers are written only if EVERY subject succeeded. A corpus half at
// version 3 and half at 6 would pass `ct-corpus-census` as a legitimate reading
// and make every later question ("does the engine open this corpus?") answerable
// only per file — which is the state this tool exists to leave behind, not to
// create.
//
// ── WHAT IT WRITES, AND WHAT IT REFUSES TO TOUCH ──────────────────────────
//
// Writes: each `ct/<txHash>.ct`, and each row's `recording` block, which is the
// producer's own measurement of what it wrote. Adds one `rerecordings` entry to
// the snapshot's provenance, so a reader can see that these bytes are not the
// ones the original capture produced and when they were re-made.
//
// Refuses to touch: blocks, effects, costs, `capturedAt`, the window, the
// counts, anything about the transaction itself. Those are facts about the
// CHAIN and a re-record does not re-measure them. If a replay disagrees with
// the snapshot about a chain fact — a different revertCode, a different block —
// that is a finding and the run refuses, because it means the subject moved.
//
// ── THE DELTAS ARE PRINTED, NOT ABSORBED ──────────────────────────────────
//
// A new producer can legitimately record a different number of log events for
// the same transaction, and did: measured 2026-10-14 on mainnet
// 0x00c67f6f…753ed18d, `logEvents` went 5 -> 6 across the producer bump while
// `steps`, `events`, `callsOpened`, `contexts` and `distinctOpcodes` all held.
// Every changed field is named in the output so a commit can say which moved
// and why, instead of a diff showing a number and nobody knowing whether it
// was expected.

import { readFile, writeFile, mkdir, rm, copyFile, mkdtemp } from 'node:fs/promises';
import { existsSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

import { replayTransaction } from './lib/replay.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

function arg(name, dflt = undefined) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return dflt;
  const v = process.argv[i + 1];
  if (v === undefined || v.startsWith('--')) return true;
  return v;
}
const has = (name) => process.argv.includes(`--${name}`);
function die(msg) {
  console.error(`rerecord-snapshot: ${msg}`);
  process.exit(2);
}

/** The container version and compact profile byte, read from the bytes. */
export function headerOf(buf) {
  if (buf.length < 6) return { container: null, profile: null };
  const magic = [...buf.slice(0, 5)].map((b) => b.toString(16).padStart(2, '0')).join('');
  if (magic !== 'c0de72ace2') return { container: null, profile: null, magic };
  const container = buf[5];
  // Offset 16 is the profile byte, and it only MEANS anything at version 6:
  // `container.nim`'s V6 header is the only one that defines it. Reading it at
  // version 5 would report whatever that byte happens to be — 77 on a measured
  // container, which is not a profile.
  const profile = container === 6 && buf.length > 16 ? buf[16] : null;
  return { container, profile, magic };
}

/** The rows a re-record is about: those that carry a container. */
export function subjectsOf(snapshot) {
  return (snapshot.transactions ?? []).filter((t) => typeof t.container === 'string');
}

// NO LIST OF RECORDING FIELDS. The first version of this file carried one, and
// the aztec re-record moved a field that was not on it: the new producer adds
// `contractRungs` — an array with a 900-word `reason` per contract — to every
// recording, and the delta report said nothing about it. A fixed list reports
// the fields someone thought of; the union of the two key sets reports the
// fields that moved.
// SNAPSHOT FIELD -> DECIDED-ROW FIELD, mapped explicitly and not by name. The
// two vocabularies differ: `decideOutcome` returns `l2BlockNumber` and
// `publishedRevertCode` where a snapshot row says `blockNumber` and
// `revertCode`. Reading `decided[field]` for both would have compared
// `undefined` against a real number on every row — a conflict check that can
// never find a conflict, which is the shape of a gate that is not one. Found by
// driving the tool rather than by reading it.
const CHAIN_FACTS = [
  ['blockNumber', 'l2BlockNumber'],
  ['txIndexInBlock', 'txIndexInBlock'],
  ['revertCode', 'publishedRevertCode'],
];

/** What moved between two recording blocks, by name. */
export function recordingDelta(before = {}, after = {}) {
  const keys = [...new Set([...Object.keys(before ?? {}), ...Object.keys(after ?? {})])].sort();
  const out = [];
  for (const f of keys) {
    const a = before?.[f];
    const b = after?.[f];
    if (JSON.stringify(a) !== JSON.stringify(b)) out.push({ field: f, from: a, to: b });
  }
  return out;
}

// ── WHICH ROW FIELDS A RE-RECORD REFRESHES, COMPUTED AND NOT LISTED ───────
//
// The first version updated `row.recording` and nothing else, and the aztec
// re-record broke the build with a figure one level out:
//
//   [§5.2 S5-CONTAINER-BYTES] … states containerBytes 180224 and its container
//   … is 51002 bytes. `containerBytes` is a measurement of the container the
//   row names and must equal its size on disk
//
// A hand-written list of row fields would be the same mistake as the hand-
// written list of recording fields this file already removed. So the set is the
// INTERSECTION of what the replay returned with what the row already carries:
// every field the row has and the driver re-measured is refreshed, and a field
// the row does not have is not invented — adding one would be a schema change
// and not a re-record.
//
// The chain facts are compared BEFORE this and a disagreement refuses the run,
// so by the time these are copied they are equal to what was there.
const CAPTURE_FACTS = new Set([
  // Facts about the CHAIN and about the capture, not about the container. A
  // re-record does not re-measure them and must not overwrite them with this
  // run's circumstances.
  'capturedAt', 'capturedWindow', 'bodyRetained', 'effectVisible', 'firstInBlock',
  'cost', 'transactionFee', 'executions', 'blockNumber', 'txIndexInBlock',
  'revertCode', 'txHash', 'container',
]);
export function refreshableKeys(row, decided) {
  return Object.keys(decided ?? {})
    .filter((k) => Object.prototype.hasOwnProperty.call(row, k))
    .filter((k) => !CAPTURE_FACTS.has(k))
    .sort();
}

/** What moved on the ROW itself, by name, over the fields a re-record refreshes. */
export function rowDelta(row, decided) {
  const out = [];
  for (const k of refreshableKeys(row, decided)) {
    if (k === 'recording') continue;            // reported field by field below
    if (JSON.stringify(row[k]) !== JSON.stringify(decided[k])) {
      out.push({ field: k, from: row[k], to: decided[k] });
    }
  }
  return out;
}

/** A value short enough to print beside a field name, or a shape instead of it. */
function brief(v) {
  const s = JSON.stringify(v);
  if (s === undefined) return 'undefined';
  if (s.length <= 80) return s;
  if (Array.isArray(v)) return `[${v.length} entr${v.length === 1 ? 'y' : 'ies'}, ${s.length} B]`;
  return `{${Object.keys(v).length} field(s), ${s.length} B}`;
}

/** A chain fact the replay disagrees with is a moved subject, not a format change. */
export function chainFactConflicts(row, decided) {
  const out = [];
  for (const [snapField, decidedField] of CHAIN_FACTS) {
    if (row[snapField] === undefined) continue;
    const got = decided?.[decidedField];
    if (got !== undefined && got !== row[snapField]) {
      out.push({ field: snapField, snapshot: row[snapField], replay: got });
    }
  }
  return out;
}

async function main() {
  const dir = arg('dir');
  if (!dir) die('--dir <snapshot-dir> is required.');
  const snapPath = join(dir, 'snapshot.json');
  if (!existsSync(snapPath)) die(`no snapshot.json under ${dir}`);

  const runtime = arg('runtime', process.env.AVM_RUNTIME_DIR);
  const avm = arg('avm', process.env.AVM_WASM_PATH);
  const ctWriter = arg('ct-writer', process.env.CT_WRITER_WASM_PATH);
  const nodeBin = arg('node', process.env.REPLAY_NODE_BIN ?? process.execPath);
  if (!runtime) die('--runtime <aztec-avm-runtime checkout with replay/node_modules> is required.');
  if (!avm) die('--avm <avm.wasm> (or $AVM_WASM_PATH) is required.');
  if (!ctWriter) die('--ct-writer <aztec_ct_writer.wasm> (or $CT_WRITER_WASM_PATH) is required.');

  const snapText = await readFile(snapPath, 'utf8');
  const snapshot = JSON.parse(snapText);
  // ── THE INDENT IS READ, NOT CHOSEN ───────────────────────────────────────
  //
  // These snapshots are written with ONE space of indentation, and
  // `JSON.stringify(_, null, 2)` reformatted all 41,191 lines of the aztec one:
  // a diff of 82,154 changed lines around three changed numbers, which nobody
  // can review and which hides exactly the fields this tool prints by name. So
  // the indent comes from the file's own second line.
  const indentOf = (text) => {
    const m = /^\{\r?\n( +)"/.exec(text);
    return m ? m[1].length : 2;
  };
  const indent = indentOf(snapText);
  const url = arg('url', snapshot?.provenance?.endpoint);
  if (!url) die('--url <rpc> is required (the snapshot declares no provenance.endpoint).');

  const compactThreshold = String(arg('compact-threshold', '0'));
  if (!/^[0-9]+$/.test(compactThreshold)) {
    die(`--compact-threshold must be a non-negative integer of raw bytes, got [${compactThreshold}]`);
  }
  // `--body-store auto` is what makes a historic transaction re-recordable at
  // all: `getTxByHash` is the one call with a horizon, and these subjects are
  // tens of thousands of blocks behind the tip. Not defaulted ON, because a
  // caller re-recording a RECENT transaction should be asking the node.
  const bodyStore = arg('body-store', '');
  const dryRun = has('dry-run');

  const subjects = subjectsOf(snapshot);
  if (subjects.length === 0) die(`${snapPath} names no transaction carrying a container.`);

  console.log(`=== re-record ${subjects.length} traced transaction(s) of ${dir} ===\n`);
  console.log(`  node       ${url}`);
  console.log(`  threshold  ${compactThreshold} raw byte(s)` +
    (compactThreshold === '0' ? '  (0 = never compact; the full profile)' : ''));
  console.log(`  body store ${bodyStore || '— (the node, which has a ~1h horizon on getTxByHash)'}`);
  console.log(`  writer     ${ctWriter}\n`);

  // ── WHICH RUNTIME IS ABOUT TO PRODUCE THESE BYTES ────────────────────────
  //
  // Read from the runtime checkout itself, not taken on trust, because it
  // becomes the snapshot's `provenance.runtimeCommit` and therefore every new
  // container's `/t/**` address (`ingest.nim:recorderForTx` ->
  // `deriveTraceArtifactId`). A wrong value here does not fail — it silently
  // files new recordings under the old recorder's addresses.
  //
  // REFUSED RATHER THAN GUESSED. A runtime whose revision cannot be read is a
  // runtime whose output cannot be addressed honestly, and the all-or-nothing
  // rule above means refusing costs nothing: no container is installed.
  let runtimeCommit = null;
  let previousRuntimeCommit = null;
  {
    const r = spawnSync('git', ['-C', resolve(runtime), 'rev-parse', 'HEAD'],
                        { encoding: 'utf8' });
    const sha = (r.stdout ?? '').trim();
    if (r.status !== 0 || !/^[0-9a-f]{40}$/.test(sha)) {
      die(`cannot read the runtime's revision from ${resolve(runtime)} — `
        + `git rev-parse HEAD exited ${r.status}${sha ? ` with [${sha}]` : ''}. `
        + `That revision becomes provenance.runtimeCommit, and every re-recorded `
        + `container's /t/** address derives from it (contract/ids.nim: `
        + `"changing the recorder must change the URL so a stale artifact cannot `
        + `outlive a bug fix"). Guessing it would file these bytes under the `
        + `PREVIOUS recorder's addresses and overwrite its containers in place.`);
    }
    runtimeCommit = sha;
    const was = snapshot?.provenance?.runtimeCommit ?? null;
    console.log(`  runtime    ${sha}${was && was !== sha ? `  (was ${was})` : ''}`);
    if (was === sha) {
      console.log('             unchanged — the re-recorded containers keep their');
      console.log('             current /t/** addresses and supersede the bytes there.');
    } else {
      console.log('             CHANGED — the re-recorded containers get NEW /t/**');
      console.log('             addresses; the current ones stay valid where they are.');
    }
  }
  console.log('');

  const stage = await mkdtemp(join(tmpdir(), 'rerecord-'));
  const results = [];
  let refused = 0;

  for (const row of subjects) {
    const ctRel = row.container;
    const out = join(stage, `${row.txHash}.ct`);
    const before = readFileSync(join(dir, ctRel));
    const beforeHdr = headerOf(before);
    const decided = await replayTransaction({
      nodeBin, runtime, url, txHash: row.txHash,
      ctPath: out, ctRelative: ctRel,
      sourcesPath: join(stage, `${row.txHash}.sources.json`),
      sourcesRelative: `sources/${row.txHash}.json`,
      avm, ctWriter, compactThreshold, bodyStore,
    });

    const wrote = existsSync(out);
    const after = wrote ? readFileSync(out) : null;
    const afterHdr = after ? headerOf(after) : { container: null, profile: null };
    const conflicts = chainFactConflicts(row, decided);
    const delta = recordingDelta(row.recording, decided.recording);
    const rdelta = wrote ? rowDelta(row, decided) : [];
    const ok = wrote && decided.replayed === true && conflicts.length === 0;
    if (!ok) refused++;

    results.push({ row, decided, before, after, beforeHdr, afterHdr, conflicts, delta, rdelta, ok });

    const v = (h) => (h.container === null ? 'not-a-container'
      : `container ${h.container}${h.profile !== null ? ` profile ${h.profile}` : ''}`);
    console.log(`  ${ok ? '[OK]     ' : '[REFUSED]'} ${row.txHash}`);
    console.log(`             was ${before.length} B, ${v(beforeHdr)}`);
    if (after) console.log(`             now ${after.length} B, ${v(afterHdr)}`);
    else console.log(`             now — nothing written (${decided.outcome ?? 'no outcome'})`);
    for (const c of conflicts) {
      console.log(`             CHAIN FACT MOVED: ${c.field} snapshot=${c.snapshot} replay=${c.replay}`);
    }
    for (const d of rdelta) {
      console.log(`             ${d.field}: ${brief(d.from)} -> ${brief(d.to)}`);
    }
    for (const d of delta) {
      console.log(`             recording.${d.field}: ${brief(d.from)} -> ${brief(d.to)}`);
    }
  }

  console.log('');
  if (refused > 0) {
    console.error(`::error::${refused} of ${subjects.length} subject(s) did not re-record. NOTHING`);
    console.error('was written: a corpus half at one container version and half at another passes');
    console.error('a census as a legitimate reading and makes every later question answerable only');
    console.error('per file. Fix the refusals and re-run.');
    await rm(stage, { recursive: true, force: true });
    return 1;
  }

  if (dryRun) {
    console.log(`dry run: ${subjects.length} container(s) re-recorded into ${stage} and NOT installed.`);
    return 0;
  }

  for (const r of results) {
    await mkdir(dirname(join(dir, r.row.container)), { recursive: true });
    await copyFile(join(stage, `${r.row.txHash}.ct`), join(dir, r.row.container));
    for (const k of refreshableKeys(r.row, r.decided)) r.row[k] = r.decided[k];
  }
  // THE PROVENANCE SAYS THESE BYTES ARE NOT THE CAPTURE'S. A reader comparing a
  // container against `capturedAt` would otherwise conclude the producer wrote
  // it then, which is the sentence this entry exists to prevent.
  snapshot.provenance = snapshot.provenance ?? {};

  // ── THE RECORDER IDENTITY MOVES, OR THE NEW BYTES INHERIT THE OLD URL ─────
  //
  // `contract/ids.nim:deriveTraceArtifactId` states the contract on itself:
  // "`recorderBuild` is load-bearing: changing the recorder must change the URL
  // so a stale artifact cannot outlive a bug fix." `ingest.nim` derives every
  // `/t/**` address from it, via `recorderForTx` -> `provenance.runtimeCommit`.
  //
  // This tool re-records with a DIFFERENT producer by construction — that is
  // what it is for — and until now it left `runtimeCommit` alone. So the new
  // containers were addressed as the old recorder's work, and a publish would
  // overwrite the old bytes AT THE SAME URL. Measured on this corpus:
  // `0x12525d6d…` went `callsOpened` 1 -> 45, a materially different recording,
  // and both versions derived the same `/t/**` path. Nothing downstream — not a
  // cache, not a consumer holding the old address, not `check-freshness`'s
  // frozen-capture rule — could have told them apart.
  //
  // So the runtime that actually produced these bytes is recorded, and the old
  // value is kept beside it rather than discarded: the previous containers are
  // still valid at their own addresses, and a reader needs to know which
  // recorder those were.
  if (runtimeCommit && snapshot.provenance.runtimeCommit !== runtimeCommit) {
    previousRuntimeCommit = snapshot.provenance.runtimeCommit ?? null;
    snapshot.provenance.runtimeCommit = runtimeCommit;
  }

  snapshot.provenance.rerecordings = snapshot.provenance.rerecordings ?? [];
  snapshot.provenance.rerecordings.push({
    at: new Date().toISOString(),
    by: 'tools/chain/rerecord-snapshot.mjs',
    subjects: subjects.length,
    compactThreshold: Number(compactThreshold),
    runtimeCommit: runtimeCommit ?? '(unknown — see the refusal above)',
    previousRuntimeCommit,
    containerVersions: Object.fromEntries(
      Object.entries(results.reduce((acc, r) => {
        const k = `v${r.afterHdr.container}`;
        acc[k] = (acc[k] ?? 0) + 1;
        return acc;
      }, {})).sort(),
    ),
    url,
  });
  await writeFile(snapPath, `${JSON.stringify(snapshot, null, indent)}\n`);
  await rm(stage, { recursive: true, force: true });
  console.log(`installed ${subjects.length} container(s) and updated ${snapPath}.`);
  console.log('Re-read the census (`just ct-corpus-read`) and say in the commit which');
  console.log('recording fields moved — they are printed above, by name.');
  return 0;
}

if (has('selftest')) {
  const { selftest } = await import('./rerecord-snapshot-selftest.mjs');
  process.exit(await selftest());
}
main().then((c) => process.exit(c)).catch((e) => {
  console.error(`rerecord-snapshot: ${e.stack ?? e.message}`);
  process.exit(2);
});
