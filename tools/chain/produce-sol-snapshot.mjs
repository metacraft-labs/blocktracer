#!/usr/bin/env node
//
// produce-sol-snapshot.mjs — SOLANA MAINNET: A FORWARD-CHAINED CAPTURE INTO A
// Data-Contract.md §5-CONFORMING SNAPSHOT TREE. Recorder-Solana CXP-SOL-3.
//
//   node tools/chain/produce-sol-snapshot.mjs \
//     --capture <capture-sol-window.mjs --out dir> \
//     --recorder-commit <codetracer-solana-recorder HEAD> \
//     --out <snapshot dir> \
//     [--from <slot> --to <slot>] [--ct-print ../codetracer-trace-format-nim/ct-print] \
//     [--chain solana-mainnet] [--label 'Real Solana mainnet data'] [--captured-at <iso>]
//
// Exit codes: 0 wrote a tree · 1 a source would not answer · 2 a configuration refusal.
//
// ── WHAT IT READS, AND WHY NOTHING HERE TALKS TO THE CHAIN ─────────────────────────────
//
// Everything comes out of one capture directory: `blocks.jsonl` (every transaction of
// every slot, votes included), `results.jsonl` (the recorder's verdict line for each
// transaction it was sent) and `traces/<signature>/` (the container, the listings and the
// replay bundle that rebuilds them). The capture is the live part and cannot be re-run;
// this producer is the deterministic part, so its tree is a function of the capture
// directory alone. That is what lets the tree be rebuilt in a sandbox from committed
// inputs (the deploy's freshness gate F4 accepts an uncommitted container only from a
// reproducible derivation).
//
// ── ITS ROWS, AND THE ONE RULE THAT DECIDES THEM ───────────────────────────────────────
//
// A row is TRACED only when the recorder executed it and its divergence check returned
// `match` — every fact the chain recorded agreeing — or `divergent`, which is published
// as divergent with the facts that disagreed. An `unchecked` verdict refuses the whole
// tree: the check is mandatory on Solana (Chain-Support-Matrix.md §3.5), the snapshot
// contract has no way to carry `unchecked` (Recorder-Solana spine need (c)), and an
// untraced row cannot honestly claim a refusal the recorder did not make. Every other
// enumerated transaction is a row with a reason: refused for want of a carried prestate,
// refused by the runtime, a vote, or outside the capture's scope.
//
// ── WHAT IS SHARED, AND WHAT IS NOT ────────────────────────────────────────────────────
//
// Shared, as eth's producer argues: `lib/snapshot-format.mjs`, `lib/recount.mjs`,
// `lib/refusal.mjs`. Everything Solana states is in `lib/solana-producer-facts.mjs`.
// DEL-7 notes are marked as such.
//
// ── THE PRESTATE TOKEN, WHICH THE READER WILL REFUSE TODAY ─────────────────────────────
//
// `forward-capture` is not yet in §1.4's closed set, so ingest refuses this tree by name
// (`S5-PRESTATE-CLOSED`). That is the honest state and it is the one place this tree is
// expected to fail conformance; see the facts module's header.

import { execFile } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync,
  statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';

import { SNAPSHOT_FORMAT, assertReadableSnapshotFormat } from './lib/snapshot-format.mjs';
import { recountSnapshot } from './lib/recount.mjs';
import { assertRefusalsAreClosed } from './lib/refusal.mjs';
import {
  RECORDER, PRESTATE_STRATEGY, IDENTIFIER_ENCODING, POSITION_LANGUAGE, POSITION_STREAM_SCHEMA,
  INSTRUCTION_STREAM_SCHEMA, CALLTRACE_STREAM_SCHEMA, INSTRUCTION_SET,
  executionsForRow, costVectorForRow, rolesForRow, payloadForRow,
} from './lib/solana-producer-facts.mjs';

const run = promisify(execFile);
const HERE = 'tools/chain/produce-sol-snapshot.mjs';

class ConfigRefusal extends Error {}
class SourceRefusal extends Error {}
const refuse = (Cls, msg) => new Cls(msg);

// ── arguments ─────────────────────────────────────────────────────────────────────────

const argv = process.argv.slice(2);
const flag = (name) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : undefined;
};

/** Reads the capture's JSON-lines file. */
function readJsonl(path) {
  if (!existsSync(path)) throw refuse(SourceRefusal, `${path} does not exist`);
  return readFileSync(path, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
}

async function readContainer(ctPrint, file) {
  const { stdout: metaOut } = await run(ctPrint, ['--meta-json', file], { maxBuffer: 1 << 28 });
  const meta = JSON.parse(metaOut);
  const { stdout: ev } = await run(ctPrint, ['--events', file], { maxBuffer: 1 << 30 });
  const lines = ev.split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
  const header = lines.find((l) => l.metadata) ?? {};
  const b = readFileSync(file).subarray(0, 8);
  if (b[0] !== 0xc0 || b[1] !== 0xde || b[2] !== 0x72 || b[3] !== 0xac) {
    throw refuse(SourceRefusal, `${file} does not begin with the CTFS magic`);
  }
  return {
    counts: meta.counts,
    flags: meta.metadata.flags,
    paths: header.paths ?? [],
    steps: lines.filter((l) => l.kind === 'step'),
    callEntries: lines.filter((l) => l.kind === 'call_entry'),
    version: b[5],
  };
}

/**
 * The recorder's listing, as `{pc, op}` per 1-based line. Instruction lines are
 * `<pc>  <mnemonic> <operands>`; a function label line (`name:`) has no counter and is a
 * hole, never skipped, because skipping renumbers every later line.
 */
export function parseListing(text) {
  const out = [];
  for (const line of text.split('\n')) {
    const m = /^\s*(\d+)\s{2}(\S+)/.exec(line);
    out.push(m ? { pc: Number(m[1]), op: m[2] } : null);
  }
  if (out.length > 0 && out[out.length - 1] === null && text.endsWith('\n')) out.pop();
  return out;
}

async function main() {
  const captureDir = flag('capture');
  const outDir = flag('out');
  const recorderCommit = flag('recorder-commit');
  if (!captureDir || !outDir || !recorderCommit) {
    throw refuse(ConfigRefusal, '--capture, --out and --recorder-commit are required');
  }
  const chain = flag('chain') ?? 'solana-mainnet';
  const label = flag('label') ?? 'Real Solana mainnet data';
  const ctPrint = resolve(flag('ct-print') ?? '../codetracer-trace-format-nim/ct-print');
  if (!existsSync(ctPrint)) throw refuse(ConfigRefusal, `ct-print not found at ${ctPrint}`);
  assertReadableSnapshotFormat(SNAPSHOT_FORMAT, HERE);

  const capture = JSON.parse(readFileSync(join(captureDir, 'capture.json'), 'utf8'));
  const from = Number(flag('from') ?? capture.window.firstSlot);
  const to = Number(flag('to') ?? capture.window.lastSlot);
  const slots = readJsonl(join(captureDir, 'blocks.jsonl'))
    .filter((b) => b.slot >= from && b.slot <= to);
  if (slots.length === 0) throw refuse(ConfigRefusal, `no slot of ${from}..${to} is in the capture`);
  const results = new Map(readJsonl(join(captureDir, 'results.jsonl'))
    .filter((r) => r.signature).map((r) => [r.signature, r]));
  const scope = Array.isArray(capture.scope) ? capture.scope : null;

  // ── the rows ──────────────────────────────────────────────────────────────────────
  const rows = [];
  const traced = [];
  for (const block of slots) {
    if (block.skipped) continue;
    for (const t of block.transactions) {
      const res = results.get(t.signature) ?? null;
      const verdict = res?.executed ? res.verdict : null;
      if (verdict && verdict.status === 'unchecked') {
        throw refuse(SourceRefusal,
          `${t.signature}: the recorder's check returned \`unchecked\`. On Solana the check is `
          + 'mandatory and the snapshot contract cannot carry this verdict, so the tree is '
          + 'refused rather than written with an unverified trace or an invented refusal.');
      }
      const traceDir = join(captureDir, 'traces', t.signature);
      const isTraced = verdict !== null && existsSync(join(traceDir, `${t.signature}.ct`));

      let untraced = null; // { reason, refusalReason }
      if (!isTraced) {
        if (t.vote) {
          untraced = { refusalReason: 'not-attempted', reason:
            'A vote transaction: the cluster\'s consensus machinery, which this capture '
            + 'enumerates and does not replay.' };
        } else if (res === null) {
          untraced = { refusalReason: 'not-attempted', reason: scope
            ? `Outside this capture's scope (${scope.join(', ')}) and writing no account the `
              + 'capture held, so it could change nothing a traced transaction ran on and was '
              + 'not replayed.'
            : 'This capture did not send it to the replay.' };
        } else if (!res.executed && /^prestate-unavailable/.test(res.reason ?? '')) {
          untraced = { refusalReason: 'prestate-unavailable', reason:
            'No RPC serves a Solana account at a past slot, so this capture carries prestate '
            + 'forward from accounts it read itself; this transaction named account(s) the '
            + `capture did not hold when it ran (${res.reason.split(': ').pop()}).` };
        } else if (!res.executed) {
          untraced = { refusalReason: 'runtime-refused', reason: res.reason ?? 'refused' };
        } else {
          // Executed but its trace is not in the capture (the capture discards divergent
          // traces unless --keep-divergent).
          untraced = { refusalReason: 'no-container-written', reason:
            `Replayed with verdict \`${verdict.status}\`, and the capture kept no trace of it.` };
        }
      }

      const base = {
        txHash: t.signature,
        blockNumber: block.slot,
        txIndexInBlock: t.index,
        revertCode: t.err === null ? 0 : 1,
        cost: costVectorForRow({ fee: t.fee, computeUnitsConsumed: t.computeUnitsConsumed,
          costUnits: t.costUnits }),
        executions: executionsForRow(untraced?.reason ?? null),
        roles: rolesForRow(t),
        payload: payloadForRow(t),
        firstInBlock: t.index === 0,
        bodyRetained: true,
        effectVisible: true,
      };
      if (untraced) {
        rows.push({ ...base, outcome: 'refused', reason: untraced.reason,
          refusalReason: untraced.refusalReason,
          ...(untraced.refusalReason === 'not-attempted' ? { outcome: 'not-attempted' } : {}) });
        continue;
      }
      traced.push({ t, block, verdict, traceDir, res });
      rows.push({ ...base, pendingTrace: true });
    }
  }

  // ── the traced rows, read back from their containers ──────────────────────────────
  for (const rec of traced) {
    const { t, verdict, traceDir, res } = rec;
    const ctFile = join(traceDir, `${t.signature}.ct`);
    const c = await readContainer(ctPrint, ctFile);
    const containerBytes = statSync(ctFile).size;
    // The container interns paths relative to its own directory (the recorder writes them
    // so, to keep the bytes independent of where it ran); each is published under that
    // same relative name.
    const listings = c.paths.map((p) => {
      const rel = /(^|\/)listings\//.test(p) ? `listings/${p.split('listings/').pop()}`
        : p.split('/').pop();
      const text = readFileSync(join(traceDir, rel), 'utf8');
      const isListing = rel.startsWith('listings/');
      const program = isListing ? rel.slice('listings/'.length).split('-')[0] : null;
      const key = isListing ? rel.replace(/\.sbf$/, '').split('-').pop() : null;
      return { publishedPath: rel, text, program, key,
        listing: isListing ? parseListing(text) : text.split('\n').map(() => null) };
    });
    const at = (s) => listings[s.path_id]?.listing[s.line - 1] ?? null;
    const steps = c.counts.steps;
    const facts = verdict.facts ?? [];
    const mismatches = facts.filter((f) => !f.matched)
      .map((f) => ({ field: f.name, detail: f.detail ?? '', matches: false }));
    const reproduced = verdict.status === 'match';
    rec.c = c; rec.listings = listings; rec.at = at; rec.containerBytes = containerBytes;
    rec.row = {
      outcome: reproduced ? 'replayed' : 'divergent',
      kind: reproduced ? 'replayed' : 'divergent',
      replayed: true,
      container: `ct/${t.signature}.ct`,
      containerBytes,
      recordedBy: recorderCommit,
      // Not a slot the state was READ at: the carried prestate is the capture's own replay
      // of every earlier transaction since each account was read. The bundle beside the
      // trace holds exactly that state.
      preStateCarriedFrom: 'forward-capture',
      instructionsExecuted: (res.invocations ?? [])
        .reduce((n, i) => n + (i.sbfInstructions ?? 0), 0),
      effects: { reproduced, matched: facts.length - mismatches.length,
        mismatched: mismatches.length, mismatches },
      validation: { status: verdict.status, oracle: verdict.oracle,
        ...(verdict.cause ? { cause: verdict.cause } : {}) },
      recording: {
        bytes: containerBytes,
        steps,
        callsOpened: c.counts.calls,
        logEvents: c.counts.io_events,
        // A disassembly of the deployed executable is what every position points into;
        // deployed Solana programs carry no DWARF (§3.5), so nothing here is source level.
        sourceLevel: false,
        stepsPositioned: c.steps.filter((s) => s.path_id !== null && s.line > 0).length,
        stepsUnpositioned: c.steps.filter((s) => !(s.path_id !== null && s.line > 0)).length,
        distinctOpcodes: new Set(c.steps.map((s) => at(s)?.op).filter(Boolean)).size,
        contexts: listings.filter((L) => L.program).length,
        varnames: c.counts.varnames,
      },
      sourceBundles: `sources/${t.signature}.json`,
      instructions: `instructions/${t.signature}.json`,
      positions: `positions/${t.signature}.json`,
      callTrace: `calltrace/${t.signature}.json`,
    };
  }
  for (let i = 0; i < rows.length; i++) {
    if (!rows[i].pendingTrace) continue;
    const rec = traced.find((r) => r.t.signature === rows[i].txHash);
    const { pendingTrace, ...base } = rows[i];
    rows[i] = { ...base, ...rec.row };
  }

  // ── the snapshot ────────────────────────────────────────────────────────────────
  const produced = slots.filter((b) => !b.skipped);
  const capturedAt = flag('captured-at') ?? capture.capturedAt;
  const snapshot = {
    format: SNAPSHOT_FORMAT,
    provenance: {
      kind: 'live-capture',
      chain,
      label,
      endpoint: capture.providers?.blocks ?? '',
      recorder: { ...RECORDER },
      prestateStrategy: PRESTATE_STRATEGY,
      identifierEncoding: { ...IDENTIFIER_ENCODING },
      capturedAt,
      tool: HERE,
      captureTool: capture.tool,
      runtimeCommit: recorderCommit,
      captureScope: scope ?? 'all',
      accountProviders: (capture.providers?.accounts ?? []).map((p) => p.url),
    },
    window: {
      tip: to,
      finalized: to,
      // The capture carries prestate forward from its own reads, so the window it can
      // replay is exactly the window it captured: nothing before `from` is reachable.
      replayableFrom: from,
      replayableTo: to,
      blocks: to - from + 1,
    },
    counts: {},
    // NEWEST FIRST (S5-BLOCKS-ORDER).
    blocks: [...produced].reverse().map((b) => ({
      number: b.slot,
      hash: b.blockhash,
      timestamp: b.blockTime,
      // DEL-7 NOTE: `parentArchiveRoot` is an Aztec-named required member. The honest
      // Solana value for "the commitment this block's parent left" is the parent's
      // blockhash, which the block itself names as `previousBlockhash`.
      parentArchiveRoot: b.previousBlockhash,
      parentSlot: b.parentSlot,
      blockHeight: b.blockHeight,
      transactions: b.transactions.map((t) => t.signature),
    })),
    transactions: rows,
    captures: [{
      capturedAt,
      by: capture.tool,
      window: { tip: to, finalized: to, replayableFrom: from, replayableTo: to, blocks: to - from + 1 },
      runtimeCommit: recorderCommit,
      yielded: traced.map((r) => ({ txHash: r.t.signature, outcome: r.row.outcome })),
    }],
  };
  snapshot.counts = recountSnapshot(snapshot);
  assertRefusalsAreClosed(snapshot.transactions, HERE);

  // ── the tree ────────────────────────────────────────────────────────────────────
  const out = resolve(outDir);
  for (const d of ['', 'ct', 'sources', 'instructions', 'positions', 'calltrace', 'bundles']) {
    mkdirSync(join(out, d), { recursive: true });
  }
  const writeJson = (rel, obj) => {
    const p = join(out, rel);
    writeFileSync(`${p}.tmp`, `${JSON.stringify(obj, null, 1)}\n`);
    renameSync(`${p}.tmp`, p);
  };
  for (const rec of traced) {
    const { t, c, listings, at, row } = rec;
    const sig = t.signature;
    copyFileSync(join(rec.traceDir, `${sig}.ct`), join(out, 'ct', `${sig}.ct`));
    // The replay bundle that rebuilds this container offline, byte for byte.
    copyFileSync(join(rec.traceDir, 'replay.bundle.json'), join(out, 'bundles', `${sig}.json`));

    writeJson(`sources/${sig}.json`, {
      txHash: sig,
      sourceLevel: false,
      bundles: listings.map((L) => ({
        address: L.program ?? '',
        codeHash: L.key ? `fnv1a64:${L.key}` : `transaction:${sig}`,
        files: { [L.publishedPath]: L.text },
        origin: L.program
          ? `disassembly of the executable the runtime loaded for ${L.program} at slot ${t.slot ?? rec.block.slot}`
          : 'the transaction\'s own instruction trace, as the runtime recorded it',
        shape: 'disassembly',
        corroboration: 'single-distributor',
        agreeingDistributors: ['the chain itself'],
        language: POSITION_LANGUAGE,
      })),
    });
    writeJson(`instructions/${sig}.json`, {
      schema: INSTRUCTION_STREAM_SCHEMA,
      tx: sig,
      isa: INSTRUCTION_SET,
      paths: listings.map((L) => L.publishedPath),
      steps: row.recording.steps,
      counters: c.steps.filter((s) => at(s)).length,
      pathId: c.steps.map((s) => s.path_id),
      pc: c.steps.map((s) => at(s)?.pc ?? -1),
      op: c.steps.map((s) => at(s)?.op ?? null),
      ctx: c.steps.map((s) => s.depth ?? 0),
    });
    writeJson(`positions/${sig}.json`, {
      schema: POSITION_STREAM_SCHEMA,
      tx: sig,
      steps: row.recording.steps,
      positioned: row.recording.stepsPositioned,
      measuredPostHoc: false,
      measuredBy: `${HERE} (read from the container)`,
      paths: listings.map((L) => L.publishedPath),
      pathId: c.steps.map((s) => s.path_id),
      line: c.steps.map((s) => s.line),
      column: c.steps.map((s) => s.column ?? null),
    });
    const frames = [{ name: '<transaction>', depth: 0, step: 0, path: null, line: null, args: [],
      contractAddress: null, endStep: null, foldedBy: null, foldWhy: null,
      hiddenDescendants: 0, hiddenSteps: 0 }];
    for (const ce of c.callEntries) {
      const s = c.steps[ce.entry_step] ?? null;
      const L = s === null ? null : listings[s.path_id] ?? null;
      frames.push({ name: ce.function ?? '<toplevel>', depth: (ce.depth ?? 0) + 1,
        step: ce.entry_step ?? 0, path: L?.publishedPath ?? null, line: s?.line ?? null,
        args: [], contractAddress: L?.program ?? null, endStep: ce.exit_step ?? null,
        foldedBy: null, foldWhy: null, hiddenDescendants: 0, hiddenSteps: 0 });
    }
    if (frames.length !== row.recording.callsOpened + 1) {
      throw refuse(SourceRefusal, `${sig}: counts.calls ${row.recording.callsOpened} but `
        + `${c.callEntries.length} call entries (S5-CALLTRACE-AGREE)`);
    }
    writeJson(`calltrace/${sig}.json`, {
      schema: CALLTRACE_STREAM_SCHEMA,
      tx: sig,
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
  console.error(JSON.stringify({ chain, window: snapshot.window, counts: snapshot.counts }));
}

main().catch((e) => {
  console.error(`${HERE}: ${e.message}`);
  process.exit(e instanceof ConfigRefusal ? 2 : 1);
});
