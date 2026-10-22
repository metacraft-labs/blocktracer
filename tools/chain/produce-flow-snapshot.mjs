#!/usr/bin/env node
//
// produce-flow-snapshot.mjs — FLOW MAINNET: CTFS CONTAINERS PLUS CHAIN DATA, INTO A
// Data-Contract.md §5-CONFORMING SNAPSHOT TREE.
//
// ── WHAT THIS IS ──────────────────────────────────────────────────────────────────────
//
// `codetracer-flow-recorder replay` re-executes a Flow transaction with the network's own
// FVM (its `cadence-replay-helper`, flow-go v0.51.1) and writes a CTFS container, the
// Cadence source of every location the execution entered, and `replay-verdict.json`. This
// file turns one block's worth of those into a §5 tree. It is Chain-Delivery DEL-6's
// producer, written concretely for ONE chain and DUPLICATING `produce-eth-snapshot.mjs`
// rather than generalising it: it shares `lib/snapshot-format.mjs`, `lib/recount.mjs` and
// `lib/refusal.mjs`, which are chain-agnostic and already had several consumers, and
// nothing else. Where it wanted something the EVM producer has, it has its own copy;
// search for `DEL-7` for the places a seam would go.
//
// ── WHAT A FLOW TREE HAS THAT AN EVM TREE DOES NOT, AND THE REVERSE ───────────────────
//
// * SOURCE, NOT DISASSEMBLY. Cadence contracts are stored on chain as source text, and
//   the helper reads each one from the same register state the execution read, so the
//   source a step points into is the code that ran — `recording.sourceLevel` is true and
//   every step is a STATEMENT with named locals. There is no instruction listing to
//   publish, because there are no instructions: the interpreter walks the AST.
// * THREE ROLES. Proposer, payer and authorizers are different accounts routinely, and
//   each is its own role (`lib/flow-producer-facts.mjs`).
// * A VERDICT THE REPLAY COMPUTED. A row's `effects` is the helper's comparison of the
//   replay's status and every event, with values, against the chain's own result — not a
//   count this tool infers. A row is `replayed` exactly when that comparison held.
// * THE PROTOCOL'S OWN TRANSACTIONS ARE NOT ROWS. Every block ends with system
//   transactions whose ids are the SAME in every block (measured: `a9caece2…` and
//   `3408f8b1…` at heights 135,000,000 and 168,391,034). Rows are keyed by transaction id,
//   so publishing them would publish one id in every block; they are listed per block in
//   `blocks[].systemTransactions` and counted in `provenance.systemTransactionsExcluded`
//   instead, with the reason.
//
// ── THE FLOOR IS A PROBE, NOT A CONSTANT ──────────────────────────────────────────────
//
// `window.replayableFrom` is `probe-floor`'s reading of the access node the capture used:
// the lowest height it serves register state at, served there and refused `OutOfRange`
// one block below, both kept in `provenance.floorProbe`. It is that node's RETENTION —
// it equals the node's own spork root — and the chain's history goes deeper, through
// other sporks' nodes, so the registry's `historyFloor` reason says which it is.

import { execFile } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync,
         writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';

import { SNAPSHOT_FORMAT, assertReadableSnapshotFormat } from './lib/snapshot-format.mjs';
import { recountSnapshot } from './lib/recount.mjs';
import { assertRefusalsAreClosed } from './lib/refusal.mjs';
import {
  CONFIG_REFUSAL, SOURCE_REFUSAL, containerReaderPath, containerVersion, dieOperational,
  refuseOperation as refuse,
} from './lib/producer-runtime.mjs';
import {
  RECORDER, PRESTATE_STRATEGY, POSITION_LANGUAGE, POSITION_STREAM_SCHEMA,
  CALLTRACE_STREAM_SCHEMA, INSTRUCTION_SET, costVectorForRow, executionsForRow,
  rolesForRow,
} from './lib/flow-producer-facts.mjs';

const run = promisify(execFile);
const HERE = 'tools/chain/produce-flow-snapshot.mjs';
const CHAIN_SLUG = 'flow-mainnet';

// DEL-7: the operational refusal, its exit code and the CTFS container header come from
// `lib/producer-runtime.mjs`, shared with the other four producers. The tokens' VALUES are
// unchanged — `'config'` and `'source'`.
const die = (e) => dieOperational(HERE, e);

const argv = process.argv.slice(2);
const flag = (name, dflt = undefined) => {
  const i = argv.indexOf(`--${name}`);
  if (i === -1) return dflt;
  const v = argv[i + 1];
  if (v === undefined || v.startsWith('--')) throw refuse(CONFIG_REFUSAL, `--${name} takes a value`);
  return v;
};
const many = (name) => argv.flatMap((a, i) => (a === `--${name}` ? [argv[i + 1]] : []));

const readJson = (p) => JSON.parse(readFileSync(p, 'utf8'));

/** A transcript, gzipped or not, as the helper writes it. */
function readTranscript(dir) {
  const plain = join(dir, 'inputs.json');
  if (existsSync(plain)) return readJson(plain);
  return JSON.parse(gunzipSync(readFileSync(join(dir, 'inputs.json.gz'))).toString('utf8'));
}

/**
 * THE ONE FINDING THIS PRODUCER RECORDS AGAINST DEL-7'S CLASSIFICATION.
 *
 * Reader discovery was classified network-agnostic on the evidence of four copies in
 * three texts, and this chain is why that classification carries a finding rather than a
 * clean pass: Flow's reader is NOT the sibling `codetracer-trace-format-nim` checkout's
 * `ct-print` that the other three fall back to. It is the `flow-ct-print` flake package at
 * the writer revision this chain's recorder links, so the shared fallback would resolve to
 * a binary that cannot open a Flow container — a wrong answer, not a missing one. So
 * `fallbacks` is EMPTY here, deliberately, and the hint is this chain's own.
 * `ingestion-classification.json`, finding
 * `container-reader-fallbacks-are-network-specific`.
 */
const ctPrintPath = (explicit) => containerReaderPath({
  explicit,
  fallbacks: [],
  hint: 'The reader is the `flow-ct-print` flake package, at the writer revision the '
      + 'recorder links — NOT the sibling codetracer-trace-format-nim checkout.',
});

// DEL-7: the same reader `produce-eth-snapshot.mjs` has, kept separate on purpose.
async function readContainer(ctPrint, file) {
  let meta;
  try {
    const { stdout } = await run(ctPrint, ['--meta-json', file], { maxBuffer: 1 << 28 });
    meta = JSON.parse(stdout);
  } catch (e) {
    throw refuse(SOURCE_REFUSAL, `${ctPrint} would not open ${file}: `
      + `${String(e.stderr ?? e.message).slice(0, 400)}`);
  }
  const { stdout: ev } = await run(ctPrint, ['--events', file], { maxBuffer: 1 << 28 });
  const lines = ev.split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
  return {
    counts: meta.counts,
    flags: meta.metadata.flags,
    paths: (lines.find((l) => l.metadata) ?? {}).paths ?? [],
    steps: lines.filter((l) => l.kind === 'step'),
    callEntries: lines.filter((l) => l.kind === 'call_entry'),
    version: containerVersion(file),
  };
}

const hexId = (id) => `0x${String(id).replace(/^0x/, '').toLowerCase()}`;

async function main() {
  const blockPath = flag('block');
  const floorPath = flag('floor-probe');
  const inputsDir = flag('inputs');
  const captures = many('capture');
  const recorderCommit = flag('recorder-commit');
  const outDir = flag('out');
  const ctPrint = ctPrintPath(flag('ct-print'));
  for (const [n, v] of [['block', blockPath], ['floor-probe', floorPath], ['inputs', inputsDir],
                        ['capture', captures[0]], ['recorder-commit', recorderCommit],
                        ['out', outDir]]) {
    if (!v) throw refuse(CONFIG_REFUSAL, `--${n} is required`);
  }
  assertReadableSnapshotFormat(SNAPSHOT_FORMAT, HERE);
  assertRefusalsAreClosed();

  const block = readJson(blockPath);
  const floor = readJson(floorPath);
  if (floor.verdict === undefined || !String(floor.verdict).startsWith('floor:')) {
    throw refuse(SOURCE_REFUSAL, `the floor probe did not find a floor (${floor.verdict}); `
      + 'a window with no measured lower bound would claim reach nobody checked');
  }
  if (block.height < floor.floor) {
    throw refuse(SOURCE_REFUSAL, `block ${block.height} is below the measured floor `
      + `${floor.floor} of ${floor.accessNode}`);
  }

  // ── the recordings ──────────────────────────────────────────────────────────────────
  const recordings = new Map();
  for (const dir of captures) {
    const verdict = readJson(join(dir, 'replay-verdict.json'));
    const id = String(verdict.transactionId).toLowerCase();
    if (verdict.blockHeight !== block.height) {
      throw refuse(CONFIG_REFUSAL, `${dir} is a replay of block ${verdict.blockHeight}, `
        + `and this tree is block ${block.height}`);
    }
    if (recordings.has(id)) throw refuse(CONFIG_REFUSAL, `${id} is captured twice`);
    const cts = readdirSync(dir).filter((f) => f.endsWith('.ct'));
    if (cts.length !== 1) {
      throw refuse(CONFIG_REFUSAL, `${dir} holds ${cts.length} container(s); one per capture`);
    }
    const ctFile = join(dir, cts[0]);
    const transcript = readTranscript(join(inputsDir, id));
    if (transcript.transactionId !== id || transcript.blockId !== block.id) {
      throw refuse(SOURCE_REFUSAL, `the transcript for ${id} is for transaction `
        + `${transcript.transactionId} in block ${transcript.blockId}`);
    }
    // eslint-disable-next-line no-await-in-loop
    const c = await readContainer(ctPrint, ctFile);
    recordings.set(id, { dir, verdict, ctFile, c, transcript,
                         bytes: readFileSync(ctFile).length });
  }

  // ── the rows: every user transaction the block lists, traced or reasoned ──────────
  const userTxs = block.transactions.filter((t) => !t.system);
  const systemTxs = block.transactions.filter((t) => t.system);
  for (const id of recordings.keys()) {
    if (!userTxs.some((t) => t.id === id)) {
      throw refuse(SOURCE_REFUSAL, `${id} was replayed and is not a user transaction of `
        + `block ${block.height}; a container no row points at is not published`);
    }
  }
  const rows = [];
  userTxs.forEach((t, i) => {
    const h = hexId(t.id);
    const rec = recordings.get(t.id) ?? null;
    const onChain = rec?.transcript.onChain ?? null;
    const untracedReason = rec !== null ? null
      : `This capture replayed ${recordings.size} of block ${block.height}'s `
        + `${userTxs.length} user transactions and enumerated the whole block, so this row `
        + 'is in the denominator. Nothing about the transaction stopped it: the prestate '
        + `strategy reaches index ${i} by re-executing indices 0..${i - 1}.`;
    const base = {
      txHash: h,
      blockNumber: block.height,
      txIndexInBlock: i,
      revertCode: onChain === null ? 0 : (onChain.failed ? 1 : 0),
      cost: costVectorForRow({
        computationUsed: onChain?.computationUsed,
        gasLimit: t.gasLimit,
        events: onChain?.events,
      }),
      roles: rolesForRow(t),
      executions: executionsForRow(untracedReason),
      firstInBlock: i === 0,
      bodyRetained: true,
      effectVisible: true,
    };
    if (rec === null) {
      rows.push({ ...base, outcome: 'not-attempted', reason: untracedReason,
                  refusalReason: 'not-attempted' });
      return;
    }
    const { verdict, c, bytes } = rec;
    const mismatches = [];
    if (!verdict.statusMatched) {
      mismatches.push({ field: 'status', published: verdict.onChain.failed ? 'failed' : 'ok',
                        replayed: verdict.replay.failed ? 'failed' : 'ok', matches: false });
    }
    if (verdict.eventsMatched !== verdict.eventsCompared) {
      mismatches.push({ field: 'events', published: verdict.eventsCompared,
                        replayed: verdict.eventsMatched, matches: false,
                        firstDifference: verdict.firstEventDiff });
    }
    if (verdict.onChain.computationUsed !== verdict.replay.computationUsed) {
      mismatches.push({ field: 'computation', published: verdict.onChain.computationUsed,
                        replayed: verdict.replay.computationUsed, matches: false });
    }
    const reproduced = verdict.reproduced === true && mismatches.length === 0
      && verdict.observationPerturbed === false;
    const positioned = c.steps.filter((s) => s.path_id !== null && s.line > 0).length;
    rows.push({
      ...base,
      outcome: reproduced ? 'replayed' : 'divergent',
      kind: reproduced ? 'replayed' : 'divergent',
      reason: reproduced
        ? 'The replay reproduced the chain\'s status, every event with its values, and the '
          + 'computation, and an untraced run of the same transaction on the same state '
          + 'agreed with the traced one.'
        : `The replay did not reproduce the chain's result: ${mismatches
          .map((m) => m.field).join(', ')} differed.`,
      refusalReason: null,
      replayed: true,
      container: `ct/${h}.ct`,
      containerBytes: bytes,
      recordedBy: recorderCommit,
      preStateReadAt: verdict.prestateHeight,
      precedingReplayed: verdict.precedingReplayed,
      effects: {
        reproduced,
        matched: verdict.eventsMatched + (verdict.statusMatched ? 1 : 0)
          + (verdict.onChain.computationUsed === verdict.replay.computationUsed ? 1 : 0),
        mismatched: mismatches.length,
        mismatches,
      },
      recording: {
        bytes,
        steps: c.counts.steps,
        callsOpened: c.counts.calls,
        logEvents: c.counts.io_events,
        // TRUE, AND MEASURED: every path the container interns is a Cadence source file
        // the helper read from the contract-code register (or the transaction script) of
        // the state the execution read, and every step is a statement in one of them.
        sourceLevel: c.paths.length > 0 && positioned === c.counts.steps,
        stepsPositioned: positioned,
        stepsUnpositioned: c.counts.steps - positioned,
        contexts: c.paths.length,
        varnames: c.counts.varnames,
      },
      sourceBundles: `sources/${h}.json`,
      positions: `positions/${h}.json`,
      callTrace: `calltrace/${h}.json`,
      artifacts: verdict.sources.map((s) => ({
        address: s.location.startsWith('A.') ? `0x${s.location.split('.')[1]}` : null,
        contractClassId: s.sha256,
        resolved: true,
        origin: s.origin,
        corroboration: 'the chain itself',
        reason: s.origin === 'transaction-script'
          ? 'The transaction carries its own Cadence script.'
          : `The contract's code register at height ${verdict.prestateHeight}, the state `
            + 'this execution read, so the source is the code that ran.',
      })),
    });
  });

  // ── the snapshot ────────────────────────────────────────────────────────────────────
  const anyTranscript = [...recordings.values()][0].transcript;
  const capturedAt = anyTranscript.recordedAt;
  const tip = floor.sealedTip;
  const snapshot = {
    format: SNAPSHOT_FORMAT,
    provenance: {
      kind: 'live-capture',
      chain: CHAIN_SLUG,
      label: 'Real Flow mainnet data',
      endpoint: anyTranscript.accessNode,
      recorder: { ...RECORDER },
      prestateStrategy: PRESTATE_STRATEGY,
      // THE EXECUTABLE FORMAT THIS CAPTURE'S RECORDINGS ARE WRITTEN AGAINST, declared
      // rather than carried inside an instruction listing — this chain publishes none,
      // because Cadence is executed from its AST and a step IS a statement. The reader
      // publishes it onto the registry row's `vm.instructionSet`
      // (Data-Contract.md §5.2b, Configuration.md §2.1); the facts module says why the
      // token names the format and not the interpreter that walks it.
      vm: { instructionSet: INSTRUCTION_SET },
      capturedAt,
      nodeVersion: floor.nodeVersion,
      tool: HERE,
      runtimeCommit: recorderCommit,
      replayEngine: [...recordings.values()][0].verdict.flowGoVersion,
      floorProbe: floor,
      systemTransactionsExcluded: {
        count: systemTxs.length,
        reason: 'The protocol\'s system transactions run in every block under the same '
          + 'ids, so as rows they would publish one id per block; they are listed per '
          + 'block in `blocks[].systemTransactions` and not replayed.',
      },
      containerVersion: [...recordings.values()][0].c.version,
      containerFlags: [...recordings.values()][0].c.flags,
    },
    window: {
      // Flow's sealed tip, at the probe: sealed is the height whose execution result is
      // verified, which is what a replay's prestate needs, so it stands for both.
      tip,
      finalized: tip,
      replayableFrom: floor.floor,
      replayableTo: tip,
      blocks: tip - floor.floor + 1,
    },
    counts: {},
    blocks: [{
      number: block.height,
      hash: hexId(block.id),
      timestamp: Math.floor(Date.parse(block.timestamp) / 1000),
      // The commitment this block's parent left behind: Flow's is the parent's id.
      // DEL-7: the EVM producer makes the same substitution for the same member.
      parentArchiveRoot: hexId(block.parentId),
      transactions: userTxs.map((t) => hexId(t.id)),
      systemTransactions: systemTxs.map((t) => hexId(t.id)),
    }],
    transactions: rows,
    captures: [{
      capturedAt,
      by: HERE,
      window: { tip, finalized: tip, replayableFrom: floor.floor, replayableTo: tip,
                blocks: tip - floor.floor + 1 },
      nodeVersion: floor.nodeVersion,
      runtimeCommit: recorderCommit,
      yielded: rows.filter((r) => r.replayed).map((r) => ({ txHash: r.txHash,
                                                            outcome: r.outcome })),
    }],
    artifactResolution: 'artifact-resolution.json',
  };
  snapshot.counts = recountSnapshot(snapshot);

  // ── the tree ────────────────────────────────────────────────────────────────────────
  const out = resolve(outDir);
  for (const d of ['', 'ct', 'sources', 'positions', 'calltrace']) {
    mkdirSync(join(out, d), { recursive: true });
  }
  const writeJson = (rel, obj) => {
    const p = join(out, rel);
    writeFileSync(`${p}.tmp`, `${JSON.stringify(obj, null, 1)}\n`);
    renameSync(`${p}.tmp`, p);
  };

  for (const [id, rec] of recordings) {
    const h = hexId(id);
    const { c, dir, verdict } = rec;
    copyFileSync(rec.ctFile, join(out, 'ct', `${h}.ct`));
    // A bundle's keys are the paths the container interns, byte for byte (§5.4), and each
    // file is read from the capture by its own name.
    const byName = new Map(verdict.sources.map((s) => [s.file, s]));
    const bundles = c.paths.map((p) => {
      const name = p.split('/').pop();
      const fact = byName.get(name);
      const file = join(dir, 'sources', name);
      if (!fact || !existsSync(file)) {
        throw refuse(SOURCE_REFUSAL, `${h}: the container interns ${p} and the capture has `
          + 'no source by that name');
      }
      const text = readFileSync(file, 'utf8');
      const sha = createHash('sha256').update(text).digest('hex');
      if (sha !== fact.sha256) {
        throw refuse(SOURCE_REFUSAL, `${h}: ${name} hashes to ${sha} and the verdict `
          + `recorded ${fact.sha256} for the code that ran`);
      }
      return {
        address: fact.location.startsWith('A.') ? `0x${fact.location.split('.')[1]}` : null,
        location: fact.location,
        codeHash: sha,
        files: { [p]: text },
        origin: fact.origin,
        shape: 'source',
        corroboration: 'single-distributor',
        agreeingDistributors: ['the chain itself'],
        language: POSITION_LANGUAGE,
      };
    });
    writeJson(`sources/${h}.json`, { txHash: h, sourceLevel: true, bundles });

    const row = rows.find((r) => r.txHash === h);
    writeJson(`positions/${h}.json`, {
      schema: POSITION_STREAM_SCHEMA,
      tx: h,
      steps: row.recording.steps,
      positioned: row.recording.stepsPositioned,
      measuredPostHoc: false,
      measuredBy: `${HERE} (read from the container)`,
      paths: c.paths,
      pathId: c.steps.map((s) => s.path_id),
      line: c.steps.map((s) => s.line),
      column: c.steps.map((s) => s.column ?? null),
    });

    const frames = [{ name: '<transaction>', depth: 0, step: 0, path: null, line: null,
                      args: [], contractAddress: null, endStep: null, foldedBy: null,
                      foldWhy: null, hiddenDescendants: 0, hiddenSteps: 0 }];
    for (const ce of c.callEntries) {
      const s = c.steps[ce.entry_step] ?? null;
      const path = s === null ? null : c.paths[s.path_id] ?? null;
      const loc = path === null ? null : path.split('/').pop().replace(/\.cdc$/, '');
      frames.push({
        name: ce.function ?? '<toplevel>',
        depth: (ce.depth ?? 0) + 1,
        step: ce.entry_step ?? 0,
        path,
        line: s === null ? null : s.line,
        args: [],
        contractAddress: loc && loc.startsWith('A.') ? `0x${loc.split('.')[1]}` : null,
        endStep: ce.exit_step ?? null,
        foldedBy: null,
        foldWhy: null,
        hiddenDescendants: 0,
        hiddenSteps: 0,
      });
    }
    if (frames.length !== row.recording.callsOpened + 1) {
      throw refuse(SOURCE_REFUSAL, `${h}: the container's counts.calls is `
        + `${row.recording.callsOpened} and its call stream holds ${c.callEntries.length}`);
    }
    writeJson(`calltrace/${h}.json`, {
      schema: CALLTRACE_STREAM_SCHEMA,
      tx: h,
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

  const traced = rows.filter((r) => r.replayed);
  writeJson('artifact-resolution.json', {
    format: 'blocktracer/artifact-resolution@1',
    chain: CHAIN_SLUG,
    measuredAt: capturedAt,
    measuredBy: { tool: HERE,
                  resolver: 'contract code registers of the replayed state, through the recorder',
                  runtimeCommit: recorderCommit },
    endpoint: anyTranscript.accessNode,
    counts: {
      transactionsConsidered: traced.length,
      transactionsWithSourceBundle: traced.length,
      stepsPositioned: traced.reduce((n, r) => n + r.recording.stepsPositioned, 0),
      stepsTotal: traced.reduce((n, r) => n + r.recording.steps, 0),
      contracts: new Set(traced.flatMap((r) => r.artifacts.map((a) => a.contractClassId))).size,
      resolved: new Set(traced.flatMap((r) => r.artifacts.map((a) => a.contractClassId))).size,
    },
    transactions: traced.map((r) => ({ txHash: r.txHash, blockNumber: r.blockNumber,
                                       artifacts: r.artifacts, positions: null })),
  });
  writeJson('snapshot.json', snapshot);

  console.log(`${HERE}: wrote ${out}`);
  console.log(`  chain ${CHAIN_SLUG} · block ${block.height} · ${userTxs.length} user `
    + `transaction(s), ${systemTxs.length} system · ${traced.length} traced`);
  console.log(`  counts.transactions=${snapshot.counts.transactions} `
    + `counts.accountedFor=${snapshot.counts.accountedFor}`);
  console.log(`  window.replayableFrom=${floor.floor} (probe of ${floor.accessNode}, `
    + `${floor.verdict})`);
  for (const r of traced) {
    console.log(`  ${r.txHash.slice(0, 12)}…: ${r.outcome} steps=${r.recording.steps} `
      + `calls=${r.recording.callsOpened} varnames=${r.recording.varnames} `
      + `sourceLevel=${r.recording.sourceLevel} effects ${r.effects.matched}/`
      + `${r.effects.matched + r.effects.mismatched}`);
  }
}

main().catch(die);
