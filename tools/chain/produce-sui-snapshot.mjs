#!/usr/bin/env node
// produce-sui-snapshot.mjs — a `blocktracer/chain-snapshot` tree for a window of Sui
// checkpoints, from a GraphQL acquisition and per-transaction recordings.
//
// ── WHAT THIS IS, AND WHAT IT IS DELIBERATELY NOT ─────────────────────────────────────
//
// The Sui twin of `produce-eth-snapshot.mjs`, written as a CONCRETE DUPLICATE: ING-7's
// two-consumer rule (Chain-Delivery DEL-7) forbids a shared producer seam until a second
// and third producer have shipped without one. Chain facts come from
// `lib/sui-producer-facts.mjs` and nowhere else (`lib/producer-scan.mjs` R1–R4).
//
// It reads three things and asks no network:
//
//   * `--acquisition FILE` — what `capture-sui-range.mjs` read over GraphQL: every
//     checkpoint in the window with every transaction in it, verbatim, plus the tip and
//     the measured tracing floor. The ROW SET comes from here, so the denominator is every
//     transaction the enumeration saw (Data-Contract.md §5.2), traced or not.
//   * `--rec DIR`, repeatable — one per attempted transaction: `done.json` (the
//     outcome), `capture/` (exactly one `.ct` when traced) and `run.log`.
//   * `--replay-root DIR` — `sui replay`'s artifacts, `<DIR>/<digest>/`: the replayed
//     effects a traced row is compared against, and each entered package's disassembly,
//     which is the text the container's positions point into.
//
// ── THE ORDERING THIS TREE CANNOT YET STATE ───────────────────────────────────────────
//
// A Sui transaction is ordered by checkpoint (Static-Site-Architecture.md §2.3,
// `order.kind: "checkpoint"`). `snapshot.json` has no member through which a producer
// can say so: ingest builds every row's order from `blocks[]` as `blockIndex`
// (src/blocktracer/chain/ingest.nim, the `TxOrder(kind: tokBlockIndex, …)` row). So
// `blocks[]` here carries CHECKPOINTS — number = sequence number, hash = checkpoint
// digest — and the tree states it in `provenance.ordering` for the reader that will
// honour it. Until ingest does, this tree is validated locally and is not published;
// Recorder-Move's 2026-10-20 status note carries the request to the spine.
//
// ── EXIT STATUS ───────────────────────────────────────────────────────────────────────
//
//   0  tree written (or the plan printed, with --dry-run)
//   1  a SOURCE refusal: an input is inconsistent, and the message names which
//   2  a CONFIGURATION refusal: a flag is missing or malformed

import { execFile, spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import {
  copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync,
  statSync, writeFileSync,
} from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { recountSnapshot } from './lib/recount.mjs';
import { assertRefusalsAreClosed } from './lib/refusal.mjs';
import { SNAPSHOT_FORMAT } from './lib/snapshot-format.mjs';
import {
  CONFIG_REFUSAL, SOURCE_REFUSAL, containerReaderPath, containerVersion, dieOperational,
  parseProducerArgs, readJsonOrRefuse as readJson, refuseOperation as refuse,
} from './lib/producer-runtime.mjs';
import {
  CALLTRACE_STREAM_SCHEMA, CHAIN_SLUG, IDENTIFIER_ENCODING, MIN_TRACED_PROTOCOL,
  INSTRUCTION_SET, POSITION_LANGUAGE, POSITION_STREAM_SCHEMA, PRESTATE_STRATEGY, RECORDER,
  VERIFICATION,
  costVectorForRow, executionsForRow, payloadForRow, reachReasonFor, rolesForRow,
} from './lib/sui-producer-facts.mjs';
import { inputVersionsOf } from './lib/sui-graphql.mjs';

/** The committed endpoint-horizon reading's deepest served checkpoint, or null. */
function horizonDeepestServed() {
  try {
    const here = fileURLToPath(new URL('.', import.meta.url));
    const r = JSON.parse(readFileSync(join(here, 'measurements', 'sui-endpoint-horizon.json'), 'utf8'));
    return Number.isInteger(r.deepestServed) ? r.deepestServed : null;
  } catch { return null; }
}

const run = promisify(execFile);
const HERE = 'tools/chain/produce-sui-snapshot.mjs';

/** The acquisition format this producer reads, written by `capture-sui-range.mjs`. */
export const ACQUISITION_FORMAT = 'blocktracer/sui-acquisition@1';

/** The stable token the recorder starts a no-trace-events refusal with. */
export const NO_TRACE_EVENTS = 'NO-TRACE-EVENTS';

/**
 * The class a row carries when `sui replay --trace` itself aborted with a stack overflow
 * (sui 1.81.1, macOS; the same replay without `--trace` succeeds).
 */
export const SUI_REPLAY_STACK_OVERFLOW = 'SUI-REPLAY-STACK-OVERFLOW';

/** The stable token the recorder starts an over-the-size-bound refusal with. */
export const TRACE_TOO_LARGE = 'TRACE-TOO-LARGE';

// DEL-7: the operational refusal, its exit code, the argv grammar, the JSON reader, the
// container reader's path and the CTFS container header all come from
// `lib/producer-runtime.mjs`, shared with the other four producers. This file used to
// declare two `extends Error` classes for the config/source distinction; the field
// mechanism three of the five already used is the one kept, so adopting the shared module
// REMOVED two classes from this file rather than adding an abstraction over it.

const USAGE = `usage: produce-sui-snapshot.mjs --acquisition FILE --replay-root DIR
         --recorder-commit SHA --out DIR [--rec DIR]... [--ct-print PATH]
         [--chain SLUG] [--label TEXT] [--captured-at ISO] [--dry-run]
         [--positions-reader PATH]   codetracer-move-recorder build whose \`positions\`
                                     reads steps and calls (default: ct-print --events)`;

const parseArgs = (argv) => parseProducerArgs(argv, { usage: USAGE });

/** The reader this producer's containers are opened with: the sibling
 *  `codetracer-trace-format-nim` checkout's `ct-print`, unless one is named. */
const ctPrintPath = (explicit) => containerReaderPath({
  explicit,
  fallbacks: [resolve('..', 'codetracer-trace-format-nim', 'ct-print')],
  hint: "The reader is codetracer-trace-format-nim's `ct-print`.",
});

const CTFS_NOTE = 'A snapshot container holds what a recorder wrote.';

/** Counts, flags, path table, steps and call entries of a container, via `ct-print`. */
/**
 * Steps and calls through `codetracer-move-recorder positions`, which reads the step and
 * call streams without decoding a value: identical output to `ct-print --events` on the
 * members used here, about a thousand times faster on a large Sui container.
 */
async function readPositions(reader, file) {
  const tmp = `${file}.positions.json`;
  try {
    await run(reader, ['positions', file, '--out', tmp], { maxBuffer: 1 << 24 });
    const doc = JSON.parse(readFileSync(tmp, 'utf8'));
    const steps = doc.pathId.map((pathId, i) => ({ step_index: i, path_id: pathId,
                                                   line: doc.line[i], column: doc.column[i] }));
    const callEntries = doc.calls.map((c) => ({ function: c.function, depth: c.depth,
                                                entry_step: c.entryStep, exit_step: c.exitStep }));
    return { paths: doc.paths, steps, callEntries };
  } catch (e) {
    throw refuse(SOURCE_REFUSAL, `${reader} positions ${file}: `
      + `${String(e.stderr ?? e.message).slice(0, 400)}`);
  } finally {
    rmSync(tmp, { force: true });
  }
}

async function readContainer(ctPrint, file, positionsReader = null) {
  let meta;
  try {
    const { stdout } = await run(ctPrint, ['--meta-json', file], { maxBuffer: 1 << 28 });
    meta = JSON.parse(stdout);
  } catch (e) {
    throw refuse(SOURCE_REFUSAL,
      `${ctPrint} would not open ${file}: ${String(e.stderr ?? e.message).slice(0, 400)}`);
  }
  if (positionsReader !== null) {
    return { counts: meta.counts, flags: meta.metadata.flags,
             ...(await readPositions(positionsReader, file)),
             version: containerVersion(file, { note: CTFS_NOTE }) };
  }
  // STREAMED, line by line: one mainnet transaction's event listing exceeds the longest
  // string a JavaScript engine can hold (~512 MB), so collecting stdout whole fails with
  // `RangeError: Invalid string length`. Only the members this producer reads are kept.
  const steps = [];
  const callEntries = [];
  let paths = [];
  let headerSeen = false;
  const child = spawn(ctPrint, ['--events', file], { stdio: ['ignore', 'pipe', 'pipe'] });
  let stderr = '';
  child.stderr.on('data', (d) => { if (stderr.length < 4000) stderr += d; });
  const exited = new Promise((done) => child.on('close', done));
  for await (const line of createInterface({ input: child.stdout, crlfDelay: Infinity })) {
    if (line.trim().length === 0) continue;
    const e = JSON.parse(line);
    if (e.kind === 'step') {
      steps.push({ step_index: e.step_index, path_id: e.path_id, line: e.line,
                   column: e.column ?? null, depth: e.depth ?? 0 });
    } else if (e.kind === 'call_entry') {
      callEntries.push({ function: e.function, depth: e.depth, entry_step: e.entry_step,
                         exit_step: e.exit_step });
    } else if (e.kind === undefined && e.metadata && headerSeen === false) {
      // The header is the one line without a `kind`. An `io` event also carries a
      // `metadata` member (its tag, e.g. `MovePtbCommand`), so matching on `metadata`
      // alone let every later io event overwrite the path table.
      paths = e.paths ?? [];
      headerSeen = true;
    }
  }
  const code = await exited;
  if (code !== 0) {
    throw refuse(SOURCE_REFUSAL, `${ctPrint} --events ${file} exited ${code}: ${stderr.slice(0, 400)}`);
  }
  return {
    counts: meta.counts,
    flags: meta.metadata.flags,
    paths,
    steps,
    callEntries,
    version: containerVersion(file, { note: CTFS_NOTE }),
  };
}

/**
 * The facts a traced row compares between the chain's published effects and the
 * replay's. `sui replay` writes its effects as the `TransactionEffects` enum (`V1`/`V2`)
 * in snake case; the service publishes camel case. A field either side lacks is compared
 * as absent on that side, so it shows as a mismatch rather than vanishing.
 */
export function effectsFacts(published, replayedEnum) {
  const replayed = replayedEnum?.V2 ?? replayedEnum?.V1 ?? {};
  const status = (s) => (s === undefined || s === null ? null
    : (s === 'Success' || s?.success === true) ? 'success' : 'failure');
  const g = published?.gasUsed ?? {};
  const rg = replayed.gas_used ?? {};
  const facts = [
    { field: 'status', published: status(published?.status), replayed: status(replayed.status) },
    ...['computationCost', 'storageCost', 'storageRebate', 'nonRefundableStorageFee']
      .map((k) => ({ field: k, published: g[k] ?? null, replayed: rg[k] ?? null })),
    { field: 'eventsDigest', published: published?.eventsDigest ?? null,
      replayed: replayed.events_digest ?? null },
    { field: 'lamportVersion', published: published?.lamportVersion ?? null,
      replayed: replayed.lamport_version === undefined ? null
        : String(replayed.lamport_version) },
  ];
  const mismatches = facts.filter((f) => f.published !== f.replayed)
    .map((f) => ({ ...f, matches: false }));
  return {
    reproduced: mismatches.length === 0,
    matched: facts.length - mismatches.length,
    mismatched: mismatches.length,
    mismatches,
  };
}

/** Classify one attempted transaction's recording directory. */
function readRecording(dir) {
  const done = readJson(join(dir, 'done.json'), 'a recording outcome');
  if (typeof done.digest !== 'string' || done.digest.length === 0) {
    throw refuse(SOURCE_REFUSAL, `${dir}/done.json names no digest`);
  }
  if (done.outcome === 'traced') {
    const capture = join(dir, 'capture');
    const cts = existsSync(capture)
      ? readdirSync(capture).filter((f) => f.endsWith('.ct')) : [];
    if (cts.length !== 1) {
      throw refuse(SOURCE_REFUSAL, `${capture} holds ${cts.length} container(s) for a `
        + `transaction recorded as traced; exactly one is required.`);
    }
    return { ...done, container: join(capture, cts[0]) };
  }
  if (done.outcome === 'no-trace-events') return done;
  if (done.outcome === 'replay-crashed' && done.refusal === SUI_REPLAY_STACK_OVERFLOW) return done;
  if (done.outcome === 'too-large' && done.refusal === TRACE_TOO_LARGE) return done;
  throw refuse(SOURCE_REFUSAL, `${dir}/done.json states outcome '${done.outcome}', which is `
    + `neither 'traced' nor 'no-trace-events'; a failed recording stops the capture rather `
    + `than reaching a tree.`);
}

async function main(argv) {
  const args = parseArgs(argv);
  if (args.has('help')) { console.log(USAGE); return; }
  const need = (n) => {
    const v = args.one(n);
    if (v === undefined) throw refuse(CONFIG_REFUSAL, `--${n} is required\n${USAGE}`);
    return v;
  };
  const acquisitionPath = need('acquisition');
  const replayRoot = resolve(need('replay-root'));
  const recorderCommit = need('recorder-commit');
  if (!/^[0-9a-f]{40}$/.test(recorderCommit)) {
    throw refuse(CONFIG_REFUSAL, `--recorder-commit must be a full 40-hex commit id; got `
      + `'${recorderCommit}'. It is the pin every traced row is attributed to.`);
  }
  const outDir = need('out');
  const chain = args.one('chain', CHAIN_SLUG);
  const label = args.one('label', 'Sui mainnet');
  const dryRun = args.has('dry-run');
  assertRefusalsAreClosed();

  const acq = readJson(acquisitionPath, 'the acquisition');
  if (acq.format !== ACQUISITION_FORMAT) {
    throw refuse(SOURCE_REFUSAL, `${acquisitionPath} is format '${acq.format}'; this producer `
      + `reads ${ACQUISITION_FORMAT}.`);
  }
  const checkpoints = [...acq.checkpoints].sort((a, b) => a.sequenceNumber - b.sequenceNumber);
  if (checkpoints.length === 0) throw refuse(SOURCE_REFUSAL, 'the acquisition holds no checkpoints');
  for (let i = 1; i < checkpoints.length; i++) {
    const prev = checkpoints[i - 1];
    const cur = checkpoints[i];
    if (cur.sequenceNumber !== prev.sequenceNumber + 1) {
      throw refuse(SOURCE_REFUSAL, `the acquisition skips from checkpoint ${prev.sequenceNumber} `
        + `to ${cur.sequenceNumber}; a window is whole or it is not a window.`);
    }
    if (cur.previousCheckpointDigest !== prev.digest) {
      throw refuse(SOURCE_REFUSAL, `checkpoint ${cur.sequenceNumber} names `
        + `${cur.previousCheckpointDigest} as its predecessor, not ${prev.digest}.`);
    }
  }
  const lo = checkpoints[0].sequenceNumber;
  const hi = checkpoints[checkpoints.length - 1].sequenceNumber;
  const floor = acq.tracedFloor;
  if (!floor || !Number.isInteger(floor.checkpoint)) {
    throw refuse(SOURCE_REFUSAL, 'the acquisition carries no measured `tracedFloor.checkpoint`');
  }
  const tip = acq.tip?.sequenceNumber;
  if (!Number.isInteger(tip) || tip < hi) {
    throw refuse(SOURCE_REFUSAL, `the acquisition's tip (${tip}) is below its window's top `
      + `(${hi})`);
  }

  const where = new Map();
  checkpoints.forEach((cp) => cp.transactions.forEach((tx, i) => {
    where.set(tx.digest, { cp, tx, index: i });
  }));

  const recordings = new Map();
  for (const dir of args.all('rec')) {
    const rec = readRecording(resolve(dir));
    if (rec.recorderCommit !== recorderCommit) {
      throw refuse(SOURCE_REFUSAL, `${dir} was recorded by ${rec.recorderCommit ?? 'an unstated '
        + 'build'}, not ${recorderCommit}; every traced row names the build that recorded it, `
        + `so a tree is produced from one build's recordings.`);
    }
    if (!where.has(rec.digest)) {
      throw refuse(SOURCE_REFUSAL, `${dir} recorded ${rec.digest}, which is in no checkpoint of `
        + `the window ${lo}..${hi}; the tree would carry a container nothing points at.`);
    }
    if (recordings.has(rec.digest)) {
      throw refuse(SOURCE_REFUSAL, `${rec.digest} was recorded twice (${dir})`);
    }
    recordings.set(rec.digest, rec);
  }

  // The container reader is needed only to read containers: a window with no traced
  // recording produces its tree without one.
  const anyTraced = [...recordings.values()].some((r) => r.outcome === 'traced');
  const ctPrint = anyTraced ? ctPrintPath(args.one('ct-print')) : null;
  const traced = new Map();
  for (const rec of recordings.values()) {
    if (rec.outcome !== 'traced') continue;
    const c = await readContainer(ctPrint, rec.container, args.one('positions-reader') ?? null);
    const replayDir = join(replayRoot, rec.digest);
    // Every path the container interned is relative to the replay directory
    // (`0x<package>/bytecode/<module>.mvb`); its text is the disassembly `sui replay`
    // wrote there. A path whose text is missing is refused: positions into nothing are
    // worse than no positions.
    // Every interned path is a module disassembly `sui replay` wrote, relative to the
    // replay directory — except the recorder's FALLBACK primary path, `transaction.mvb`,
    // which it interns when the transaction's first frame has no loaded module: a
    // programmable block of non-Move commands only (SplitCoins, TransferObjects, …) runs
    // no Move code, and its one entry step lands there. That path has no text; every
    // other missing path is refused.
    const isFallback = (p) => basename(p) === 'transaction.mvb';
    const files = c.paths.map((p) => {
      const abs = join(replayDir, p);
      if (!p.startsWith('/') && !p.includes('..') && existsSync(abs)) {
        return { path: p, package: p.split('/')[0], text: readFileSync(abs, 'utf8') };
      }
      if (isFallback(p)) return { path: 'transaction.mvb', package: null, text: null };
      throw refuse(SOURCE_REFUSAL, `${rec.digest}: the container interns '${p}', which is `
        + `not a file under ${replayDir}; the recorder writes paths relative to the `
        + `replay directory and the producer publishes them as written.`);
    });
    // A row is POSITIONED when every step lands on a line of real disassembly; one that
    // steps on the textless fallback publishes no positions and no source bundle, which
    // the contract allows (a traced row may publish no bundle) and which is the truth.
    let positionable = true;
    for (const s of c.steps) {
      const f = files[s.path_id];
      if (f !== undefined && f.text === null) { positionable = false; continue; }
      const lines = f === undefined ? 0 : f.text.split('\n').length;
      if (f === undefined || !(s.line >= 1 && s.line <= lines)) {
        throw refuse(SOURCE_REFUSAL, `${rec.digest}: step ${s.step_index} is at path ${s.path_id} `
          + `line ${s.line}, outside the disassembly it names.`);
      }
    }
    const replayedEffects = readJson(join(replayDir, 'transaction_effects.json'),
      `the replayed effects of ${rec.digest}`);
    traced.set(rec.digest, { rec, c, files, replayedEffects, positionable,
                             containerBytes: statSync(rec.container).size });
  }

  const versions = new Set([...traced.values()].map((t) => t.c.version));
  if (versions.size > 1) {
    throw refuse(SOURCE_REFUSAL, `the containers carry versions ${[...versions].join(', ')}; `
      + `one tree is read by one engine, so it holds one container version.`);
  }

  const rows = [];
  for (const cp of checkpoints) {
    cp.transactions.forEach((tx, i) => {
      const revertCode = tx.status === 'SUCCESS' ? 0 : 1;
      const rec = recordings.get(tx.digest) ?? null;
      const t = traced.get(tx.digest) ?? null;
      const untracedReason = rec === null
        ? `This run traced ${traced.size} of the window's transactions and enumerated all `
          + `of checkpoints ${lo}..${hi}, so the denominator is the window. Nothing about this `
          + `transaction or about Sui stopped it: the run's budget did. A run with a wider `
          + `budget traces it.`
        : rec.outcome === 'no-trace-events'
          ? `This transaction executed at protocol version ${cp.protocolVersion}, on an `
            + `execution layer that emits no trace events (Sui's layers before protocol `
            + `${MIN_TRACED_PROTOCOL}). \`sui replay\` re-executed it from the object versions `
            + `it names and wrote a trace holding only its version header, so there is `
            + `nothing to step. Trace hooks in that layer would trace it.`
          : rec.outcome === 'replay-crashed'
            ? `\`sui replay --trace\` aborted on this transaction: its tracer overflowed the `
              + `main thread's stack (${rec.replayRuntime ?? 'sui 1.81.1'}), while the same replay `
              + `without --trace succeeds. The execution is the chain's and is reachable; the `
              + `replay runtime's tracer could not record it.`
            : rec.outcome === 'too-large'
              ? `\`sui replay --trace\` completed, and its trace decompresses past the `
                + `recorder's bound (every trace event carries full snapshots of the values it `
                + `touches), so no container was written. The execution is the chain's and is `
                + `reachable; the recording is what is too large to make.`
              : null;
      const base = {
        txHash: tx.digest,
        blockNumber: cp.sequenceNumber,
        txIndexInBlock: i,
        revertCode,
        cost: costVectorForRow({ ...(tx.gasSummary ?? {}), gasPrice: tx.gasPrice,
                                 gasBudget: tx.gasBudget }),
        executions: executionsForRow(untracedReason),
        roles: rolesForRow(tx),
        payload: payloadForRow(tx),
        firstInBlock: i === 0,
        bodyRetained: true,
        effectVisible: true,
        transactionKind: tx.kind,
        protocolVersion: cp.protocolVersion,
        inputVersions: inputVersionsOf(tx.effectsJson),
      };
      if (rec === null) {
        rows.push({ ...base, outcome: 'not-attempted', reason: untracedReason,
                    refusalReason: 'not-attempted' });
        return;
      }
      if (rec.outcome === 'too-large') {
        rows.push({ ...base, outcome: 'refused', reason: untracedReason,
                    refusalReason: 'no-container-written', refusal: rec.refusal });
        return;
      }
      if (rec.outcome === 'no-trace-events' || rec.outcome === 'replay-crashed') {
        rows.push({ ...base, outcome: 'refused', reason: untracedReason,
                    refusalReason: 'runtime-refused',
                    refusal: rec.outcome === 'no-trace-events' ? NO_TRACE_EVENTS : rec.refusal });
        return;
      }
      const { c, files, replayedEffects, containerBytes, positionable } = t;
      const effects = effectsFacts(tx.effectsJson, replayedEffects);
      const steps = c.counts.steps;
      const positioned = c.steps.filter((s) => files[s.path_id]?.text != null && s.line > 0).length;
      rows.push({
        ...base,
        outcome: effects.reproduced ? 'replayed' : 'divergent',
        kind: effects.reproduced ? 'replayed' : 'divergent',
        replayed: true,
        container: `ct/${tx.digest}.ct`,
        containerBytes,
        recordedBy: recorderCommit,
        instructionsExecuted: steps,
        effects,
        recording: {
          bytes: containerBytes,
          steps,
          callsOpened: c.counts.calls,
          logEvents: c.counts.io_events,
          sourceLevel: false,
          stepsPositioned: positioned,
          stepsUnpositioned: steps - positioned,
          contexts: files.length,
          varnames: c.counts.varnames,
        },
        ...(positionable ? { sourceBundles: `sources/${tx.digest}.json`,
                             positions: `positions/${tx.digest}.json` } : {}),
        callTrace: `calltrace/${tx.digest}.json`,
        artifacts: [...new Set(files.map((f) => f.package).filter(Boolean))].map((pkg) => ({
          address: pkg,
          contractClassId: pkg,
          resolved: false,
          origin: null,
          corroboration: null,
          reason: 'No verified source was resolved for this package, so its steps are '
            + 'positioned against the disassembly `sui replay` wrote for the exact package '
            + 'version that executed, identified by the storage id the trace records.',
        })),
      });
    });
  }

  for (const digest of recordings.keys()) {
    if (!rows.some((r) => r.txHash === digest)) {
      throw refuse(SOURCE_REFUSAL, `${digest} was recorded and got no row`);
    }
  }

  const capturedAt = args.one('captured-at', acq.fetchedAt ?? new Date().toISOString());
  const anchor = [...traced.values()][0] ?? null;
  const snapshot = {
    format: SNAPSHOT_FORMAT,
    provenance: {
      kind: 'live-capture',
      chain,
      label,
      endpoint: acq.endpoint,
      recorder: { ...RECORDER },
      prestateStrategy: PRESTATE_STRATEGY,
      identifierEncoding: { ...IDENTIFIER_ENCODING },
      ordering: 'checkpoint',
      capturedAt,
      nodeVersion: acq.replayRuntime ?? '',
      tool: HERE,
      runtimeCommit: recorderCommit,
      tracedFloor: floor,
      reachReason: reachReasonFor(floor.checkpoint, horizonDeepestServed()),
      verification: VERIFICATION,
      vm: { instructionSet: INSTRUCTION_SET },
      containerVersion: anchor?.c.version ?? null,
      containerFlags: anchor?.c.flags ?? null,
    },
    window: {
      tip,
      finalized: tip,
      replayableFrom: floor.checkpoint,
      replayableTo: tip,
      blocks: tip - floor.checkpoint + 1,
    },
    counts: {},
    blocks: [...checkpoints].reverse().map((cp) => ({
      number: cp.sequenceNumber,
      hash: cp.digest,
      timestamp: Math.floor(Date.parse(cp.timestamp) / 1000),
      parentArchiveRoot: cp.previousCheckpointDigest,
      epoch: cp.epoch,
      protocolVersion: cp.protocolVersion,
      transactions: cp.transactions.map((tx) => tx.digest),
    })),
    transactions: rows,
    captures: [{
      capturedAt,
      by: HERE,
      window: { from: lo, to: hi },
      runtimeCommit: recorderCommit,
      yielded: [...recordings.keys()].map((digest) => ({
        txHash: digest,
        outcome: rows.find((r) => r.txHash === digest).outcome,
      })),
    }],
  };
  snapshot.counts = recountSnapshot(snapshot);

  if (dryRun) {
    console.log(JSON.stringify({ chain, checkpoints: `${lo}..${hi}`, counts: snapshot.counts,
      outcomes: rows.reduce((m, r) => ({ ...m, [r.outcome]: (m[r.outcome] ?? 0) + 1 }), {}) },
    null, 1));
    return;
  }

  const out = resolve(outDir);
  if (existsSync(out) && readdirSync(out).length > 0
      && !existsSync(join(out, 'snapshot.json'))) {
    throw refuse(CONFIG_REFUSAL, `--out ${out} is not empty and holds no snapshot.json; this `
      + `tool replaces a tree it wrote and nothing else.`);
  }
  rmSync(out, { recursive: true, force: true });
  for (const d of ['', 'ct', 'sources', 'positions', 'calltrace']) {
    mkdirSync(join(out, d), { recursive: true });
  }
  const writeJson = (rel, obj) => {
    const p = join(out, rel);
    writeFileSync(`${p}.tmp`, `${JSON.stringify(obj, null, 1)}\n`);
    renameSync(`${p}.tmp`, p);
  };

  for (const [digest, { rec, c, files, positionable }] of traced) {
    const row = rows.find((r) => r.txHash === digest);
    copyFileSync(rec.container, join(out, 'ct', `${digest}.ct`));
    // Only the modules a step lands in are published. `sui replay` writes every module of
    // every package it fetched, and the recorder interns them all, so a bundle of the whole
    // path table carried ~90 disassemblies for a transaction that ran in two. The position
    // stream still lists every interned path, so a path id keeps its meaning; a path no
    // step uses has no text to point into and needs none.
    if (positionable) {
      const stepped = new Set(c.steps.map((s) => s.path_id));
      const byPackage = new Map();
      for (const [id, f] of files.entries()) {
        if (!stepped.has(id)) continue;
        if (!byPackage.has(f.package)) byPackage.set(f.package, {});
        byPackage.get(f.package)[f.path] = f.text;
      }
      writeJson(`sources/${digest}.json`, {
        txHash: digest,
        sourceLevel: false,
        // A bundle is keyed by code identity (S5-BUNDLE-KEYED). A Sui package's storage id
        // names one immutable package version — an upgrade publishes a new id — so it IS
        // the identity of the code that ran.
        bundles: [...byPackage].map(([pkg, filesOf]) => ({
          address: pkg,
          codeHash: pkg,
          files: filesOf,
          origin: `disassembly of package ${pkg} as \`sui replay\` fetched it at the version `
            + `that executed`,
          shape: 'disassembly',
          corroboration: 'single-distributor',
          agreeingDistributors: ['the chain itself'],
          language: POSITION_LANGUAGE,
        })),
      });
      writeJson(`positions/${digest}.json`, {
        schema: POSITION_STREAM_SCHEMA,
        tx: digest,
        steps: row.recording.steps,
        positioned: row.recording.stepsPositioned,
        measuredPostHoc: false,
        measuredBy: `${HERE} (read from the container)`,
        paths: files.map((f) => f.path),
        pathId: c.steps.map((s) => s.path_id),
        line: c.steps.map((s) => s.line),
        column: c.steps.map((s) => s.column ?? null),
      });
    }
    const frames = [
      { name: '<transaction>', depth: 0, step: 0, path: null, line: null, args: [],
        contractAddress: null, endStep: null, foldedBy: null, foldWhy: null,
        hiddenDescendants: 0, hiddenSteps: 0 },
    ];
    for (const ce of c.callEntries) {
      const s = c.steps[ce.entry_step] ?? null;
      const f = s === null ? null : files[s.path_id] ?? null;
      frames.push({
        name: ce.function ?? '<toplevel>',
        depth: (ce.depth ?? 0) + 1,
        step: ce.entry_step ?? 0,
        path: f === null ? null : f.path,
        line: s === null ? null : s.line,
        args: [],
        contractAddress: f === null ? null : f.package,
        endStep: ce.exit_step ?? null,
        foldedBy: null,
        foldWhy: null,
        hiddenDescendants: 0,
        hiddenSteps: 0,
      });
    }
    if (frames.length !== row.recording.callsOpened + 1) {
      throw refuse(SOURCE_REFUSAL, `${digest}: the container counts ${row.recording.callsOpened} `
        + `call(s) and its call stream holds ${c.callEntries.length}; S5-CALLTRACE-AGREE `
        + `requires the published frames to be the count plus one.`);
    }
    writeJson(`calltrace/${digest}.json`, {
      schema: CALLTRACE_STREAM_SCHEMA,
      tx: digest,
      callsOpened: row.recording.callsOpened,
      frames: frames.length,
      steps: row.recording.steps,
      foldRules: [],
      foldedFrames: 0,
      foldedSteps: 0,
      measuredPostHoc: false,
      measuredBy: `${HERE} (read from the container)`,
      frame: frames,
    });
  }
  writeJson('snapshot.json', snapshot);
  console.log(`wrote ${out}: checkpoints ${lo}..${hi}, ${rows.length} transaction(s), `
    + `${traced.size} traced`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((e) => dieOperational(basename(HERE), e));
}

export { main };
