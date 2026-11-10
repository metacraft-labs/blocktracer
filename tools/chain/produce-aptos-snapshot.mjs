#!/usr/bin/env node
// produce-aptos-snapshot.mjs — a `blocktracer/chain-snapshot` tree for a window of Aptos
// blocks, from a REST acquisition and per-transaction recordings.
//
// ── WHAT THIS IS, AND WHAT IT IS DELIBERATELY NOT ─────────────────────────────────────
//
// The Aptos twin of `produce-sui-snapshot.mjs`, written as a CONCRETE DUPLICATE: ING-7's
// two-consumer rule (Chain-Delivery DEL-7) forbids a shared producer seam until the
// producers have shipped without one. Chain facts come from `lib/aptos-producer-facts.mjs`
// and nowhere else (`lib/producer-scan.mjs` R1–R4).
//
// It reads three things and asks no network:
//
//   * `--acquisition FILE` — what `capture-aptos-range.mjs` read over REST: every block of
//     the window with every transaction in it, verbatim, the block below it, and the
//     node's ledger info (its tip and its retention boundary). The ROW SET comes from
//     here, so the denominator is every user transaction the enumeration saw
//     (Data-Contract.md §5.2), traced or not.
//   * `--rec DIR`, repeatable — one per attempted transaction: `done.json` (the outcome),
//     `capture/` (exactly one `.ct` when traced or divergent) and the run's log.
//   * `--replay-root DIR` — the recorder's replay artifacts, `<DIR>/<version>/`: each
//     entered module's `.mv` (the bytecode at the version before the transaction) and its
//     `.mv.masm` disassembly, which is the text the container's positions point into —
//     and, where `lib/aptos-source.mjs` proved a module's published source against those
//     bytes, `source/<m>.move` (the text its steps are positioned in instead) and the
//     resolution report `sources.json`, which names every entered module's outcome.
//
// ── SOURCE ────────────────────────────────────────────────────────────────────────────
//
// A module is `resolved` exactly when the report says `verified`: its published source,
// read from `0x1::code::PackageRegistry` at V−1, compiled to the very bytes the chain held
// (Source-Resolution.md §4, a full match). Its bundle carries that source and every other
// published file the compiler positioned its code in (inlined code); every other module
// keeps its disassembly bundle, and its artifact states why (§4's "not found" and "no
// match" rows, in the report's own words).
//
// ── THE ORDERING ──────────────────────────────────────────────────────────────────────
//
// An Aptos transaction is sequenced by its ledger VERSION (Static-Site-Architecture.md
// §2.3, `order.kind: "globalVersion"`), so this tree declares `provenance.ordering:
// "globalVersion"` and every row states its `version` as a decimal string
// (S5-VERSION-STATED). `blocks[]` carries BLOCKS — number = block height, hash = block
// hash — and so do the window and the floor. The transactions the protocol runs in every
// block (block metadata, block epilogue, state checkpoint, validator transactions) are
// listed in `blocks[].systemTransactions`, never as rows (S5-SYSTEM-TRANSACTIONS).
//
// ── EXIT STATUS ───────────────────────────────────────────────────────────────────────
//
//   0  tree written (or the plan printed, with --dry-run)
//   1  a SOURCE refusal: an input is inconsistent, and the message names which
//   2  a CONFIGURATION refusal: a flag is missing or malformed

import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import {
  copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync,
  statSync, writeFileSync,
} from 'node:fs';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

import { recountSnapshot } from './lib/recount.mjs';
import { assertRefusalsAreClosed } from './lib/refusal.mjs';
import { SNAPSHOT_FORMAT } from './lib/snapshot-format.mjs';
import {
  CONFIG_REFUSAL, SOURCE_REFUSAL, containerReaderPath, containerVersion, dieOperational,
  parseProducerArgs, pictureControlChars, readJsonOrRefuse as readJson, recorderProvenance,
  refuseOperation as refuse,
} from './lib/producer-runtime.mjs';
import {
  CALLTRACE_STREAM_SCHEMA, CHAIN_SLUG, IDENTIFIER_ENCODING, IDENTITY, INSTRUCTION_SET, ORDERING,
  POSITION_LANGUAGE, POSITION_STREAM_SCHEMA, PRESTATE_STRATEGY, RECORDER, SOURCE_LANGUAGE,
  SOURCE_POSITION_STREAM_SCHEMA, VERIFICATION,
  costVectorForRow, effectsFromReplay, executionsForRow, isUserTransaction, payloadForRow,
  reachReasonFor, rolesForRow,
} from './lib/aptos-producer-facts.mjs';
import { SOURCE_RESOLUTION_FORMAT, artifactFromResolution } from './lib/aptos-source.mjs';

const run = promisify(execFile);
const HERE = 'tools/chain/produce-aptos-snapshot.mjs';

/** The acquisition format this producer reads, written by `capture-aptos-range.mjs`. */
export const ACQUISITION_FORMAT = 'blocktracer/aptos-acquisition@1';

/** The stable token the recorder starts a no-trace-events refusal with. */
export const NO_TRACE_EVENTS = 'NO-TRACE-EVENTS';

/** The stable token the recorder starts an over-the-size-bound refusal with. */
export const TRACE_TOO_LARGE = 'TRACE-TOO-LARGE';

/** What `aptos move replay` says when its output does not match the chain's. */
export const REPLAY_MISMATCH = 'TransactionOutput does not match TransactionInfo';

const USAGE = `usage: produce-aptos-snapshot.mjs --acquisition FILE --replay-root DIR
         --recorder-commit SHA --out DIR [--rec DIR]... [--ct-print PATH]
         [--recorder-binary PATH] [--chain SLUG] [--label TEXT] [--captured-at ISO]
         [--positions-reader PATH] [--dry-run]`;

const parseArgs = (argv) => parseProducerArgs(argv, { usage: USAGE });

const ctPrintPath = (explicit) => containerReaderPath({
  explicit,
  fallbacks: [resolve('..', 'codetracer-trace-format-nim', 'ct-print')],
  hint: "The reader is codetracer-trace-format-nim's `ct-print`.",
});

const CTFS_NOTE = 'A snapshot container holds what a recorder wrote.';

/** Steps and calls through `codetracer-move-recorder positions` (no value is decoded). */
async function readContainer(ctPrint, reader, file) {
  let meta;
  try {
    const { stdout } = await run(ctPrint, ['--meta-json', file], { maxBuffer: 1 << 28 });
    meta = JSON.parse(stdout);
  } catch (e) {
    throw refuse(SOURCE_REFUSAL,
      `${ctPrint} would not open ${file}: ${String(e.stderr ?? e.message).slice(0, 400)}`);
  }
  const tmp = `${file}.positions.json`;
  try {
    await run(reader, ['positions', file, '--out', tmp], { maxBuffer: 1 << 24 });
    const doc = JSON.parse(readFileSync(tmp, 'utf8'));
    return {
      counts: meta.counts,
      flags: meta.metadata.flags,
      paths: doc.paths,
      steps: doc.pathId.map((pathId, i) => ({ step_index: i, path_id: pathId,
                                              line: doc.line[i], column: doc.column[i] })),
      callEntries: doc.calls.map((c) => ({ function: c.function, depth: c.depth,
                                           entry_step: c.entryStep, exit_step: c.exitStep })),
      version: containerVersion(file, { note: CTFS_NOTE }),
    };
  } catch (e) {
    throw refuse(SOURCE_REFUSAL, `${reader} positions ${file}: `
      + `${String(e.stderr ?? e.message).slice(0, 400)}`);
  } finally {
    rmSync(tmp, { force: true });
  }
}

/** Classify one attempted transaction's recording directory. */
function readRecording(dir) {
  const done = readJson(join(dir, 'done.json'), 'a recording outcome');
  if (typeof done.version !== 'string' || !/^\d+$/.test(done.version)) {
    throw refuse(SOURCE_REFUSAL, `${dir}/done.json names no version`);
  }
  if (done.outcome === 'traced' || done.outcome === 'divergent') {
    const capture = join(dir, 'capture');
    const cts = existsSync(capture) ? readdirSync(capture).filter((f) => f.endsWith('.ct')) : [];
    if (cts.length !== 1) {
      throw refuse(SOURCE_REFUSAL, `${capture} holds ${cts.length} container(s) for a `
        + `transaction recorded as ${done.outcome}; exactly one is required.`);
    }
    if (done.outcome === 'divergent' && !String(done.mismatch ?? '').includes(REPLAY_MISMATCH)) {
      throw refuse(SOURCE_REFUSAL, `${dir}/done.json is divergent and states no mismatch`);
    }
    return { ...done, container: join(capture, cts[0]) };
  }
  if (done.outcome === 'too-large' && done.refusal === TRACE_TOO_LARGE) return done;
  if (done.outcome === 'no-trace-events' && done.refusal === NO_TRACE_EVENTS) return done;
  throw refuse(SOURCE_REFUSAL, `${dir}/done.json states outcome '${done.outcome}', which is `
    + `none of traced, divergent, too-large or no-trace-events; a failed recording stops the `
    + `capture rather than reaching a tree.`);
}

/** The code identity of a module that ran: `0x` + SHA-256 of its bytecode at V−1. */
const moduleCodeHash = (bytes) => `0x${createHash('sha256').update(bytes).digest('hex')}`;

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
  const recorderBinary = args.one('recorder-binary');
  if (!/^[0-9a-f]{40}$/.test(recorderCommit)) {
    throw refuse(CONFIG_REFUSAL, `--recorder-commit must be a full 40-hex commit id; got `
      + `'${recorderCommit}'. It is the pin every traced row is attributed to.`);
  }
  const outDir = need('out');
  const chain = args.one('chain', CHAIN_SLUG);
  const label = args.one('label', 'Aptos mainnet');
  const dryRun = args.has('dry-run');
  assertRefusalsAreClosed();

  const acq = readJson(acquisitionPath, 'the acquisition');
  if (acq.format !== ACQUISITION_FORMAT) {
    throw refuse(SOURCE_REFUSAL, `${acquisitionPath} is format '${acq.format}'; this producer `
      + `reads ${ACQUISITION_FORMAT}.`);
  }
  const blocks = [...acq.blocks].sort((a, b) => Number(a.block_height) - Number(b.block_height));
  if (blocks.length === 0) throw refuse(SOURCE_REFUSAL, 'the acquisition holds no blocks');
  for (let i = 1; i < blocks.length; i++) {
    const prev = blocks[i - 1];
    const cur = blocks[i];
    if (Number(cur.block_height) !== Number(prev.block_height) + 1) {
      throw refuse(SOURCE_REFUSAL, `the acquisition skips from block ${prev.block_height} `
        + `to ${cur.block_height}; a window is whole or it is not a window.`);
    }
    if (BigInt(cur.first_version) !== BigInt(prev.last_version) + 1n) {
      throw refuse(SOURCE_REFUSAL, `block ${cur.block_height} starts at version `
        + `${cur.first_version}, not one after block ${prev.block_height}'s last `
        + `(${prev.last_version}); the window's versions are not contiguous.`);
    }
  }
  const lo = Number(blocks[0].block_height);
  const hi = Number(blocks[blocks.length - 1].block_height);
  if (Number(acq.predecessor?.height) !== lo - 1 || typeof acq.predecessor?.hash !== 'string') {
    throw refuse(SOURCE_REFUSAL, `the acquisition names no predecessor of block ${lo}`);
  }
  const ledger = acq.ledger ?? {};
  const tip = ledger.blockHeight;
  const floor = ledger.oldestBlockHeight;
  if (!Number.isInteger(tip) || tip < hi) {
    throw refuse(SOURCE_REFUSAL, `the acquisition's tip (${tip}) is below its window's top (${hi})`);
  }
  if (!Number.isInteger(floor) || floor > lo) {
    throw refuse(SOURCE_REFUSAL, `the acquisition's retention boundary (${floor}) is not at or `
      + `below its window (${lo}); the node had pruned what the replay read`);
  }

  const where = new Map();   // version -> { block, tx, index }
  for (const b of blocks) {
    b.transactions.forEach((tx, i) => {
      if (isUserTransaction(tx)) where.set(String(tx.version), { block: b, tx, index: i });
    });
  }

  const recordings = new Map();
  for (const dir of args.all('rec')) {
    const rec = readRecording(resolve(dir));
    if (rec.recorderCommit !== recorderCommit) {
      throw refuse(SOURCE_REFUSAL, `${dir} was recorded by ${rec.recorderCommit ?? 'an unstated '
        + 'build'}, not ${recorderCommit}; every traced row names the build that recorded it, `
        + `so a tree is produced from one build's recordings.`);
    }
    const w = where.get(rec.version);
    if (!w) {
      throw refuse(SOURCE_REFUSAL, `${dir} recorded version ${rec.version}, which is no user `
        + `transaction of the window ${lo}..${hi}; the tree would carry a container nothing `
        + `points at.`);
    }
    if (w.tx.hash !== rec.hash) {
      throw refuse(SOURCE_REFUSAL, `${dir} recorded version ${rec.version} as ${rec.hash}; the `
        + `chain names it ${w.tx.hash}.`);
    }
    if (recordings.has(rec.version)) {
      throw refuse(SOURCE_REFUSAL, `version ${rec.version} was recorded twice (${dir})`);
    }
    recordings.set(rec.version, rec);
  }

  const withContainer = [...recordings.values()].filter((r) => r.container);
  const ctPrint = withContainer.length > 0 ? ctPrintPath(args.one('ct-print')) : null;
  const positionsReader = args.one('positions-reader');
  if (withContainer.length > 0 && !positionsReader) {
    throw refuse(CONFIG_REFUSAL, '--positions-reader (a codetracer-move-recorder build) is '
      + 'required to read the containers\' steps and calls');
  }
  const traced = new Map();
  for (const rec of withContainer) {
    const c = await readContainer(ctPrint, positionsReader, rec.container);
    const replayDir = join(replayRoot, rec.version);
    // The resolution report, when the capture asked for source. A report that names a module
    // the replay did not enter, or misses one it did, is refused: the artifacts are built
    // from it.
    const reportPath = join(replayDir, 'sources.json');
    const report = existsSync(reportPath) ? readJson(reportPath, 'a source resolution') : null;
    if (report !== null && report.format !== SOURCE_RESOLUTION_FORMAT) {
      throw refuse(SOURCE_REFUSAL, `${reportPath} is format '${report.format}'; this producer `
        + `reads ${SOURCE_RESOLUTION_FORMAT}.`);
    }
    const verified = new Map((report?.modules ?? []).filter((m) => m.outcome === 'verified')
      .map((m) => [`${m.address}/source/${m.module}.move`, m]));
    // Every interned path is a module disassembly the recorder wrote, relative to the
    // replay directory (`0x<address>/bytecode/<module>.mv.masm`), or a published source a
    // verified module is positioned in (`0x<address>/source/<module>.move`) — except its
    // FALLBACK primary path, `transaction.masm`, interned when the first frame has no
    // loaded module. That path has no text; every other missing path is refused.
    const files = c.paths.map((p) => {
      const abs = join(replayDir, p);
      if (!p.startsWith('/') && !p.includes('..') && existsSync(abs) && p.endsWith('.move')
          && p.split('/')[1] === 'source') {
        // A published source is shown only as part of a verified module's bundle.
        const owners = [...verified.values()].filter((m) => (m.files ?? []).includes(p));
        if (owners.length === 0) {
          throw refuse(SOURCE_REFUSAL, `version ${rec.version}: the container interns '${p}', `
            + 'and no module the resolution report verified names it.');
        }
        return { path: p, address: p.split('/')[0], text: readFileSync(abs, 'utf8'),
                 codeHash: null, module: basename(p).replace(/\.move$/, ''), source: true };
      }
      if (!p.startsWith('/') && !p.includes('..') && existsSync(abs)) {
        const mv = abs.replace(/\.masm$/, '');
        if (!existsSync(mv)) {
          throw refuse(SOURCE_REFUSAL, `version ${rec.version}: '${p}' has no bytecode beside it `
            + `(${basename(mv)}), so the code it disassembles cannot be identified.`);
        }
        return { path: p, address: p.split('/')[0],
                 text: pictureControlChars(readFileSync(abs, 'utf8')),
                 codeHash: moduleCodeHash(readFileSync(mv)),
                 module: basename(p).replace(/\.mv\.masm$/, '') };
      }
      if (basename(p) === 'transaction.masm') {
        return { path: 'transaction.masm', address: null, text: null, codeHash: null, module: null };
      }
      throw refuse(SOURCE_REFUSAL, `version ${rec.version}: the container interns '${p}', which `
        + `is not a file under ${replayDir}.`);
    });
    let positionable = true;
    for (const s of c.steps) {
      const f = files[s.path_id];
      if (f !== undefined && f.text === null) { positionable = false; continue; }
      const lines = f === undefined ? 0 : f.text.split('\n').length;
      if (f === undefined || !(s.line >= 1 && s.line <= lines)) {
        throw refuse(SOURCE_REFUSAL, `version ${rec.version}: step ${s.step_index} is at path `
          + `${s.path_id} line ${s.line}, outside the disassembly it names.`);
      }
    }
    if (report !== null) {
      const named = new Set(report.modules.map((m) => `${m.address}::${m.module}`));
      const entered = readdirSync(replayDir).filter((d) => d.startsWith('0x')
        && existsSync(join(replayDir, d, 'bytecode'))).flatMap((d) =>
        readdirSync(join(replayDir, d, 'bytecode')).filter((f) => f.endsWith('.mv'))
          .map((f) => `${d}::${f.slice(0, -3)}`));
      if (entered.length !== named.size || entered.some((x) => !named.has(x))) {
        throw refuse(SOURCE_REFUSAL, `version ${rec.version}: ${reportPath} names `
          + `${named.size} module(s) and the replay entered ${entered.length}; a resolution `
          + 'answers for every module the transaction entered.');
      }
    }
    traced.set(rec.version, { rec, c, files, positionable, report, verified,
                              containerBytes: statSync(rec.container).size });
  }

  const versions = new Set([...traced.values()].map((t) => t.c.version));
  if (versions.size > 1) {
    throw refuse(SOURCE_REFUSAL, `the containers carry versions ${[...versions].join(', ')}; `
      + `one tree is read by one engine, so it holds one container version.`);
  }

  const rows = [];
  const tracedCount = [...recordings.values()].filter((r) => r.container).length;
  for (const b of blocks) {
    b.transactions.forEach((tx, i) => {
      if (!isUserTransaction(tx)) return;
      const version = String(tx.version);
      const rec = recordings.get(version) ?? null;
      const t = traced.get(version) ?? null;
      const untracedReason = rec === null
        ? `This run traced ${tracedCount} of the window's user transactions and enumerated `
          + `all of blocks ${lo}..${hi}, so the denominator is the window. Nothing about this `
          + `transaction or about Aptos stopped it: the run's budget did. A run with a wider `
          + `budget traces it.`
        : rec.outcome === 'too-large'
          ? '`aptos move replay --trace` completed, and its trace is larger than the '
            + 'recorder\'s bound (every trace event carries the values it touches), so no '
            + 'container was written. The execution is the chain\'s and is reachable; the '
            + 'recording is what is too large to make.'
          : rec.outcome === 'no-trace-events'
            ? '`aptos move replay --trace` re-executed this transaction and wrote a trace '
              + 'holding no execution events, so there is nothing to step.'
            : null;
      const base = {
        txHash: tx.hash,
        blockNumber: Number(b.block_height),
        txIndexInBlock: i,
        version,
        revertCode: tx.success === true ? 0 : 1,
        cost: costVectorForRow(tx),
        executions: executionsForRow(untracedReason),
        roles: rolesForRow(tx),
        payload: payloadForRow(tx),
        firstInBlock: i === 0,
        bodyRetained: true,
        effectVisible: true,
        transactionKind: tx.payload?.type ?? tx.type,
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
      if (rec.outcome === 'no-trace-events') {
        rows.push({ ...base, outcome: 'refused', reason: untracedReason,
                    refusalReason: 'runtime-refused', refusal: rec.refusal });
        return;
      }
      const { c, files, containerBytes, positionable, report } = t;
      const effects = effectsFromReplay(tx, rec.outcome === 'divergent' ? rec.mismatch : null);
      const steps = c.counts.steps;
      const positioned = c.steps.filter((s) => files[s.path_id]?.text != null && s.line > 0).length;
      const onSource = c.steps.filter((s) => files[s.path_id]?.source === true && s.line > 0)
        .length;
      const ran = new Map();
      for (const f of files) if (f.codeHash) ran.set(f.codeHash, f);
      rows.push({
        ...base,
        outcome: effects.reproduced ? 'replayed' : 'divergent',
        kind: effects.reproduced ? 'replayed' : 'divergent',
        replayed: true,
        container: `ct/${tx.hash}.ct`,
        containerBytes,
        recordedBy: recorderCommit,
        // A step is a source LINE where the module is on its source, so the instruction
        // count is the trace's own, which the capture counted; a recording made before it
        // did is all on disassembly, one step per instruction.
        instructionsExecuted: rec.instructions ?? steps,
        preStateReadAt: String(BigInt(version) - 1n),
        effects,
        recording: {
          bytes: containerBytes,
          steps,
          callsOpened: c.counts.calls,
          logEvents: c.counts.io_events,
          // TRUE ONLY WHEN EVERY STEP IS ON VERIFIED SOURCE — the AND over every module the
          // transaction executed; one module on its disassembly keeps it false.
          sourceLevel: steps > 0 && onSource === steps,
          stepsPositioned: positioned,
          stepsUnpositioned: steps - positioned,
          contexts: files.length,
          varnames: c.counts.varnames,
        },
        ...(positionable ? { sourceBundles: `sources/${tx.hash}.json`,
                             positions: `positions/${tx.hash}.json` } : {}),
        callTrace: `calltrace/${tx.hash}.json`,
        artifacts: report !== null
          ? report.modules.map((m) => artifactFromResolution(m, report.ledgerVersion))
          : [...ran.values()].map((f) => ({
            address: f.address,
            contractClassId: f.codeHash,
            resolved: false,
            origin: null,
            corroboration: null,
            reason: `No verified source was resolved for module ${f.address}::${f.module}, so `
              + 'its steps are positioned against the disassembly of its bytecode as the chain '
              + `held it at version ${BigInt(version) - 1n}, identified by the SHA-256 of that `
              + 'bytecode.',
          })),
      });
    });
  }

  for (const version of recordings.keys()) {
    if (!rows.some((r) => r.version === version)) {
      throw refuse(SOURCE_REFUSAL, `version ${version} was recorded and got no row`);
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
      recorder: recorderProvenance(RECORDER, recorderBinary),
      prestateStrategy: PRESTATE_STRATEGY,
      identifierEncoding: { ...IDENTIFIER_ENCODING },
      ordering: ORDERING,
      capturedAt,
      nodeVersion: acq.replayRuntime ?? '',
      tool: HERE,
      runtimeCommit: recorderCommit,
      reachReason: reachReasonFor(floor, ledger.oldestLedgerVersion),
      verification: VERIFICATION,
      vm: { instructionSet: INSTRUCTION_SET },
      identity: IDENTITY,
      containerVersion: anchor?.c.version ?? null,
      containerFlags: anchor?.c.flags ?? null,
    },
    window: {
      tip,
      finalized: tip,
      replayableFrom: floor,
      replayableTo: tip,
      blocks: tip - floor + 1,
    },
    counts: {},
    blocks: [...blocks].reverse().map((b, i, all) => {
      const system = b.transactions.filter((tx) => !isUserTransaction(tx)).map((tx) => tx.hash);
      const parent = i + 1 < all.length ? all[i + 1].block_hash : acq.predecessor.hash;
      return {
        number: Number(b.block_height),
        hash: b.block_hash,
        timestamp: Number(BigInt(b.block_timestamp) / 1000000n),
        parentArchiveRoot: parent,
        firstVersion: String(b.first_version),
        lastVersion: String(b.last_version),
        transactions: b.transactions.filter(isUserTransaction).map((tx) => tx.hash),
        ...(system.length > 0 ? { systemTransactions: system } : {}),
      };
    }),
    transactions: rows,
    captures: [{
      capturedAt,
      by: HERE,
      window: { from: lo, to: hi },
      runtimeCommit: recorderCommit,
      yielded: [...recordings.values()].map((r) => ({
        txHash: r.hash,
        outcome: rows.find((row) => row.version === r.version).outcome,
      })),
    }],
  };
  snapshot.counts = recountSnapshot(snapshot);

  if (dryRun) {
    console.log(JSON.stringify({ chain, blocks: `${lo}..${hi}`, counts: snapshot.counts,
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
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(`${p}.tmp`, `${JSON.stringify(obj, null, 1)}\n`);
    renameSync(`${p}.tmp`, p);
  };

  for (const [version, { rec, c, files, positionable, report, verified }] of traced) {
    const row = rows.find((r) => r.version === version);
    const hash = row.txHash;
    copyFileSync(rec.container, join(out, 'ct', `${hash}.ct`));
    // Only the modules a step lands in are published; the position stream still lists
    // every interned path, so a path id keeps its meaning.
    if (positionable) {
      const stepped = new Set(c.steps.map((s) => s.path_id));
      const byCode = new Map();
      for (const [id, f] of files.entries()) {
        if (!stepped.has(id) || f.codeHash === null) continue;
        if (!byCode.has(f.codeHash)) byCode.set(f.codeHash, { f, files: {} });
        byCode.get(f.codeHash).files[f.path] = f.text;
      }
      // A VERIFIED module's bundle is its published source and every other published file
      // its source map positions code in — the same set for the same code hash in every
      // transaction, so the content-addressed bundle never forks. It is published when a
      // step of the transaction landed in any of those files.
      const steppedPaths = new Set([...stepped].map((id) => files[id]?.path));
      const sourceBundles = [];
      for (const m of [...verified.values()].sort((x, y) => (x.codeHash < y.codeHash ? -1 : 1))) {
        if (!(m.files ?? []).some((p) => steppedPaths.has(p))) continue;
        sourceBundles.push({
          address: m.address,
          codeHash: m.codeHash,
          files: Object.fromEntries(m.files.map((p) => [p, readFileSync(join(replayRoot, version,
                                                                             p), 'utf8')])),
          origin: `the published source of ${m.package} (upgrade ${m.upgradeNumber}) from `
            + `0x1::code::PackageRegistry at ${m.address}, ledger version `
            + `${report.ledgerVersion}, compiled to the module's bytes exactly`,
          shape: 'source',
          corroboration: 'single-distributor',
          agreeingDistributors: ['the chain itself'],
          language: SOURCE_LANGUAGE,
        });
      }
      writeJson(`sources/${hash}.json`, {
        txHash: hash,
        sourceLevel: row.recording.sourceLevel,
        // A bundle is keyed by code identity (S5-BUNDLE-KEYED). An Aptos module is
        // upgradable in place at its address, so the address does not name the code; the
        // SHA-256 of the bytecode the chain held at V−1 does.
        bundles: [...byCode.values()].map(({ f, files: filesOf }) => ({
          address: f.address,
          codeHash: f.codeHash,
          files: filesOf,
          origin: `disassembly of module ${f.address}::${f.module} as the chain held it at `
            + `version ${BigInt(version) - 1n}, read over REST and disassembled by `
            + '`aptos move disassemble`',
          shape: 'disassembly',
          corroboration: 'single-distributor',
          agreeingDistributors: ['the chain itself'],
          language: POSITION_LANGUAGE,
        })).concat(sourceBundles),
      });
      writeJson(`positions/${hash}.json`, {
        // A stream with any step on a published source is no longer a disassembly stream.
        schema: files.some((f, id) => f.source && stepped.has(id))
          ? SOURCE_POSITION_STREAM_SCHEMA : POSITION_STREAM_SCHEMA,
        tx: hash,
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
        contractAddress: f === null ? null : f.address,
        endStep: ce.exit_step ?? null,
        foldedBy: null,
        foldWhy: null,
        hiddenDescendants: 0,
        hiddenSteps: 0,
      });
    }
    if (frames.length !== row.recording.callsOpened + 1) {
      throw refuse(SOURCE_REFUSAL, `version ${version}: the container counts `
        + `${row.recording.callsOpened} call(s) and its call stream holds `
        + `${c.callEntries.length}; S5-CALLTRACE-AGREE requires the published frames to be the `
        + 'count plus one.');
    }
    writeJson(`calltrace/${hash}.json`, {
      schema: CALLTRACE_STREAM_SCHEMA,
      tx: hash,
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
  console.log(`wrote ${out}: blocks ${lo}..${hi}, ${rows.length} transaction(s), `
    + `${traced.size} with a recording`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((e) => dieOperational(basename(HERE), e));
}

export { main };
