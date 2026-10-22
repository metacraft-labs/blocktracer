#!/usr/bin/env node
// produce-starknet-snapshot.mjs — a `blocktracer/chain-snapshot` tree for Starknet mainnet
// blocks, from `codetracer-cairo-onchain trace-block` captures.
//
// ── WHAT THIS IS, AND WHAT IT IS DELIBERATELY NOT ─────────────────────────────────────
//
// The Starknet twin of `produce-eth-snapshot.mjs` and `produce-sui-snapshot.mjs`, written
// as a CONCRETE DUPLICATE: ING-7's two-consumer rule (Chain-Delivery DEL-7) forbids a
// shared producer seam until the producers it would serve have shipped without one. Chain
// facts come from `lib/starknet-producer-facts.mjs` and nowhere else
// (`lib/producer-scan.mjs` R1–R4).
//
// IT ASKS NO NETWORK. Every input is a capture directory `trace-block` wrote — one per
// block — and the recorder already put the chain's side of the capture into it:
//
//   <capture>/block.json            the block report: header, every transaction's body
//                                   and receipt verbatim, the node's tip and L1-accepted
//                                   head, a `thisMethodDoesNotExist` control, the floor
//                                   probe, and every row's full report — outcome,
//                                   refusal, and the counted facts the replay compared
//   <capture>/<tx>/*.ct             one CTFS container per recorded transaction
//   <capture>/<tx>/sources/*.casm   one CASM listing per class the transaction entered
//
// so the tree can be produced inside a build sandbox over a committed transcript, the way
// `tools/chain/nix/eth.nix` produces chain two's.
//
// ── WHAT A ROW'S OUTCOME MEANS HERE ───────────────────────────────────────────────────
//
//   replayed   cairo-vm, in StarkWare's own executor, re-ran it on the sequencer's
//              prestate and every counted fact matched the chain: execution status,
//              actual fee, L2 gas, L1 data gas, L1 gas, the event count and every event,
//              L2->L1 messages, and the call tree entry point by entry point
//   divergent  it ran and at least one counted fact did not match; `effects.mismatches`
//              names which, with both readings
//   refused    the executor declined by name (`runtime-refused`): an era it carries no
//              constants for, an executor error, or a preceding refusal that took this
//              transaction's prestate with it. The reason is the executor's own sentence
//   not-attempted  replayed but not recorded by this run (`trace-block --tx` narrowed it)
//
// ── EXIT STATUS ───────────────────────────────────────────────────────────────────────
//
//   0  tree written (or the plan printed, with --dry-run)
//   1  a SOURCE refusal: an input is inconsistent, and the message names which
//   2  a CONFIGURATION refusal: a flag is missing or malformed

import { spawn } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, renameSync,
         writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline';
import { pathToFileURL } from 'node:url';

import { recountSnapshot } from './lib/recount.mjs';
import { assertRefusalsAreClosed } from './lib/refusal.mjs';
import { SNAPSHOT_FORMAT, assertReadableSnapshotFormat } from './lib/snapshot-format.mjs';
import {
  CONFIG_REFUSAL, SOURCE_REFUSAL, containerReaderPath, containerVersion, dieOperational,
  parseProducerArgs, readJsonOrRefuse as readJson, refuseOperation as refuse,
} from './lib/producer-runtime.mjs';
import {
  CALLTRACE_STREAM_SCHEMA, CHAIN_SLUG, IDENTIFIER_ENCODING, INSTRUCTION_SET,
  INSTRUCTION_STREAM_SCHEMA, POSITION_LANGUAGE, POSITION_STREAM_SCHEMA, PRESTATE_STRATEGY,
  RECORDER, costVectorForRow, executionsForRow, l1MessageForRow, payloadForRow, rolesForRow,
} from './lib/starknet-producer-facts.mjs';

// WHAT THE RECORDER PROVED ABOUT A CLASS'S SOURCE, republished. A class the recorder ran
// with a `bind-class` binding (`trace-block --class-sources`) has a build of its published
// source proved against the chain's own class: the Sierra program felt for felt, the entry
// points, the class version and the ABI, with the class hash recomputed from the chain's
// answer (Source-Resolution.md §4). That proves an ARTIFACT, so the row says `resolved`;
// what the artifact gives this recording is NAMES — every Cairo function, type and
// libfunc in the listing — and not lines, unless the build recorded statement locations,
// which `codeLocations` states. `recording.sourceLevel` is not raised by a binding.
/** The SPDX licence the recorder's binding states for class `classHash`'s build. */
function licenceOf(rec, classHash) {
  const row = (rec.report.classes ?? []).find((k) => k.classHash === classHash);
  return row?.source?.provenance?.build?.license ?? null;
}

/** The Cairo files of `rec` that class `classHash`'s own steps were shown in. */
function cairoFilesOf(rec, classHash) {
  const row = (rec.report.classes ?? []).find((k) => k.classHash === classHash);
  const want = new Set(row?.cairoSources ?? []);
  return rec.listings.filter((L) => L.classHash === null && want.has(L.interned));
}

export function artifactRow(k, r) {
  const address = (r.frames.find((f) => f.classHash === k.classHash) ?? {}).contract ?? '';
  const src = k.source ?? null;
  if (src?.bound === true) {
    const b = src.provenance?.build ?? {};
    const what = [b.repository, b.tag ?? b.revision, b.contract].filter(Boolean).join(' ');
    return {
      address,
      contractClassId: k.classHash,
      resolved: true,
      // THE SPDX IDENTIFIER IS SHOWN WHEREVER THE SOURCE IS (Source-Resolution.md §8):
      // the build's own `license` (its Scarb.toml), named in the origin a page prints.
      origin: `a build of ${what || 'the class\'s published source'}`
        + (b.toolchain ? ` with ${b.toolchain}` : '')
        + (b.license ? ` — licence ${b.license}` : ''),
      corroboration: 'the chain itself',
      reason: 'A build of this class\'s published source was proved against the class the '
        + 'chain serves — the same Sierra program felt for felt, the same entry points, '
        + 'class version and ABI, and the class hash recomputed from the chain\'s answer — so '
        + `its debug info names the program: ${src.functionsNamed} Cairo functions, and every `
        + 'type and libfunc, are named in the listing. '
        + (!src.codeLocations
          ? 'Its compiler records no file and line per statement, so steps stay positioned '
            + 'on CASM instructions, under those names.'
          : (k.cairoSources ?? []).length > 0
            ? 'The build also records a Cairo file and line per Sierra statement, and its '
              + `sources are republished, so this class's steps are shown at those lines, in `
              + `${k.cairoSources.length} file(s); a step whose statement has no location `
              + 'stays on its CASM instruction.'
            : 'The build records a Cairo file and line per Sierra statement, but its sources '
              + 'are not republished here, so steps stay positioned on CASM instructions.'),
      sourceBinding: src.provenance ?? null,
    };
  }
  return {
    address,
    contractClassId: k.classHash,
    resolved: false,
    origin: null,
    corroboration: null,
    reason: 'A declared class carries its Sierra program and ABI and no debug info that '
      + 'maps a program counter to a Cairo source line, and no build of its source was '
      + 'proved against it'
      + (src?.bound === false ? ` (a binding was offered and refused: ${src.refused})` : '')
      + ', so every step is positioned in a listing of the CASM the VM ran — compiled from '
      + 'the Sierra class the node served, by the recorder.',
  };
}

const HERE = 'tools/chain/produce-starknet-snapshot.mjs';

/** The block report format `codetracer-cairo-onchain trace-block` writes. */
export const BLOCK_REPORT_FORMAT = 'codetracer-cairo-onchain/block-report@1';

// DEL-7: the operational refusal, its exit code, the argv grammar, the JSON reader, the
// container reader's path and the CTFS container header come from
// `lib/producer-runtime.mjs`, shared with the other four producers. The tokens' VALUES are
// unchanged — `'config'` and `'source'` — which is what keeps this file's selftest arms
// asserting on `e.refusalKind` valid across the move.

const USAGE = `usage: produce-starknet-snapshot.mjs --capture DIR [--capture DIR]...
         --recorder-commit SHA --out DIR [--ct-print PATH] [--label TEXT]
         [--endpoint-label URL] [--captured-at ISO] [--dry-run]`;

const parseArgs = (argv) => parseProducerArgs(argv, { usage: USAGE });

/** The reader this producer's containers are opened with: the sibling
 *  `codetracer-trace-format-nim` checkout's `ct-print`, unless one is named. */
const ctPrintPath = (explicit) => containerReaderPath({
  explicit,
  fallbacks: [resolve('..', 'codetracer-trace-format-nim', 'ct-print')],
  hint: "The reader is codetracer-trace-format-nim's `ct-print`.",
});

const CTFS_NOTE = 'A snapshot container holds what a recorder wrote.';

/** Run `ct-print` and hand each line of its stdout to `onLine`, without buffering it:
 *  a Starknet transaction can run a million VM steps, and one JSON line per step is more
 *  than a child-process buffer should hold. */
function streamLines(cmd, args, onLine) {
  return new Promise((ok, fail) => {
    const p = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let err = '';
    p.stderr.on('data', (d) => { err += d; });
    const rl = createInterface({ input: p.stdout, crlfDelay: Infinity });
    rl.on('line', (l) => { if (l.trim().length > 0) onLine(l); });
    p.on('close', (code) => (code === 0 ? ok()
      : fail(refuse(SOURCE_REFUSAL, `${cmd} ${args.join(' ')} exited ${code}: ${err.slice(0, 400)}`))));
  });
}

/** Counts, flags, path table, per-step (path, line) and the call stream of a container,
 *  read back through the reader the db-backend consumes. */
async function readContainer(ctPrint, file) {
  let metaText = '';
  await streamLines(ctPrint, ['--meta-json', file], (l) => { metaText += `${l}\n`; });
  let meta;
  try { meta = JSON.parse(metaText); } catch (e) {
    throw refuse(SOURCE_REFUSAL, `${ctPrint} --meta-json ${file} did not answer JSON: ${e.message}`);
  }
  const pathId = [];
  const line = [];
  const callEntries = [];
  let paths = [];
  let ioEvents = 0;
  await streamLines(ctPrint, ['--events', file], (l) => {
    const o = JSON.parse(l);
    if (o.metadata) { paths = o.paths ?? paths; return; }
    if (o.kind === 'step') { pathId.push(o.path_id); line.push(o.line); return; }
    if (o.kind === 'call_entry') {
      callEntries.push({ function: o.function, entry_step: o.entry_step,
                         exit_step: o.exit_step, depth: o.depth, args: o.args });
      return;
    }
    if (o.kind === 'io') ioEvents += 1;
  });
  return { counts: meta.counts, flags: meta.metadata.flags, paths, pathId, line, callEntries,
           ioEvents, version: containerVersion(file, { note: CTFS_NOTE }) };
}

/** `0x<pc>  <instruction>` per line; label lines (no `0x` lead) are holes, kept as holes
 *  so the line numbers the container carries index straight in. */
export function parseListing(text) {
  const out = text.split('\n').map((l) => {
    const m = /^0x([0-9a-f]+) {2}(.*)$/.exec(l);
    return m ? { pc: Number.parseInt(m[1], 16), text: m[2] } : null;
  });
  if (out.length > 0 && out[out.length - 1] === null && text.endsWith('\n')) out.pop();
  return out;
}

/** The instruction's kind, as a mnemonic a column can hold: the listing line is the full
 *  CASM text, the instruction sidecar carries what kind of instruction it was. */
export function mnemonic(insn) {
  if (insn === undefined || insn === null) return null;
  const t = insn.text;
  if (t.startsWith('call ')) return 'call';
  if (t === 'ret') return 'ret';
  if (/^jmp .* if /.test(t)) return 'jnz';
  if (t.startsWith('jmp ')) return 'jmp';
  if (t.startsWith('ap += ')) return 'ap_add';
  if (t.startsWith('dw ')) return 'data';
  if (/^\[[af]p[+-]\d+\] = /.test(t)) return 'assert_eq';
  return 'other';
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

/** The whole run, over `argv` (without the node and script names), so the offline
 *  selftest drives exactly what the command line does. */
export async function main(argv) {
  const args = parseArgs(argv);
  if (args.has('help')) { console.log(USAGE); return; }
  const captureDirs = args.all('capture');
  const recorderCommit = args.one('recorder-commit');
  const outDir = args.one('out');
  if (captureDirs.length === 0) throw refuse(CONFIG_REFUSAL, `--capture is required\n${USAGE}`);
  if (!recorderCommit) throw refuse(CONFIG_REFUSAL, `--recorder-commit is required\n${USAGE}`);
  if (!outDir && !args.has('dry-run')) throw refuse(CONFIG_REFUSAL, `--out is required\n${USAGE}`);
  const capturedAtFlag = args.one('captured-at');
  if (capturedAtFlag && Number.isNaN(Date.parse(capturedAtFlag))) {
    throw refuse(CONFIG_REFUSAL, `--captured-at must be a date Date.parse accepts`);
  }
  assertReadableSnapshotFormat(SNAPSHOT_FORMAT, HERE);
  assertRefusalsAreClosed();

  // ── the captures, one per block, in chain order ──────────────────────────
  const caps = captureDirs.map((dir) => {
    const b = readJson(join(dir, 'block.json'), 'the block report');
    if (b.format !== BLOCK_REPORT_FORMAT) {
      throw refuse(SOURCE_REFUSAL, `${dir}/block.json is ${JSON.stringify(b.format)}, and this `
        + `producer reads ${BLOCK_REPORT_FORMAT} only.`);
    }
    if (!b.chain?.header || !Array.isArray(b.chain?.transactions)) {
      throw refuse(SOURCE_REFUSAL, `${dir}/block.json carries no \`chain\` member — it was `
        + `written by a recorder older than the one that records the chain's side of the `
        + `capture, and this producer will not ask the network for it.`);
    }
    return { dir, b };
  }).sort((x, y) => x.b.blockNumber - y.b.blockNumber);
  {
    const seen = new Set();
    for (const c of caps) {
      if (seen.has(c.b.blockNumber)) {
        throw refuse(CONFIG_REFUSAL, `block ${c.b.blockNumber} is captured twice`);
      }
      seen.add(c.b.blockNumber);
    }
  }

  // THE BOUNDARY. `window.replayableFrom` is the member the reader derives `reach` and
  // `historyFloor` from, so it is measured, never typed: the recorder's `--probe-floor`
  // bisected the executor's OWN acceptance over block versions and checked the node
  // serves state at the floor's parent, with a negative control. One capture of the run
  // must carry it.
  const probed = caps.filter((c) => c.b.floorProbe);
  if (probed.length === 0) {
    throw refuse(SOURCE_REFUSAL, `no capture carries a floor probe. Run one block of the set `
      + `with \`trace-block --probe-floor\`: \`window.replayableFrom\` is derived from it, `
      + `and a typed floor is the defect CPC-5 records.`);
  }
  const floorProbe = probed[probed.length - 1].b.floorProbe;
  const ex = floorProbe.executorFloor;
  const ns = floorProbe.nodeState;
  if (!(ex?.acceptedAtFloor === true && ex?.refusedBelow === true
        && ns?.positiveControlHeld === true && ns?.negativeControlHeld === true)) {
    throw refuse(SOURCE_REFUSAL, `the floor probe's controls did not all hold `
      + `(${JSON.stringify({ acceptedAtFloor: ex?.acceptedAtFloor, refusedBelow: ex?.refusedBelow,
                             positive: ns?.positiveControlHeld, negative: ns?.negativeControlHeld })}); `
      + `a floor whose instrument did not discriminate is not a measurement.`);
  }
  const floor = floorProbe.pipelineFloor;
  const newest = caps[caps.length - 1].b;
  const tip = Number(newest.chain.tip);
  const finalized = Number(newest.chain.l1Accepted);
  const control = newest.chain.endpointControl;
  if (control?.classified === 'ok') {
    throw refuse(SOURCE_REFUSAL, `the endpoint answered \`thisMethodDoesNotExist\` with a `
      + `result: it is a blind proxy and none of its answers discriminate.`);
  }

  // ── the containers, read back ─────────────────────────────────────────────
  // The reader is needed only when there is a container to read: a window of refused rows
  // (an era the executor does not carry) is a tree with no recording in it.
  const anyRecorded = caps.some((c) => c.b.perTransaction.some((r) => r.recorded === true));
  const ctPrint = args.has('dry-run') || !anyRecorded ? null : ctPrintPath(args.one('ct-print'));
  const recordings = new Map();
  for (const { dir, b } of caps) {
    for (const r of b.perTransaction) {
      if (r.recorded !== true) continue;
      const tdir = join(dir, r.txHash);
      const cts = readdirSync(tdir).filter((f) => f.endsWith('.ct'));
      if (cts.length !== 1) {
        throw refuse(SOURCE_REFUSAL, `${tdir} holds ${cts.length} container(s); a recorded `
          + `transaction has exactly one.`);
      }
      const src = join(tdir, cts[0]);
      const rec = { txHash: r.txHash, dir: tdir, containerSrc: src,
                    containerBytes: readFileSync(src).length, report: r };
      if (ctPrint) {
        // eslint-disable-next-line no-await-in-loop
        rec.c = await readContainer(ctPrint, src);
        if (rec.c.version !== 5) {
          throw refuse(SOURCE_REFUSAL, `${src} is container version ${rec.c.version}, and this `
            + `producer declares ${RECORDER.traceSchema}.`);
        }
        if (rec.c.counts.steps !== r.container.steps) {
          throw refuse(SOURCE_REFUSAL, `${src}: the reader counts ${rec.c.counts.steps} steps `
            + `and the recorder reported writing ${r.container.steps}. A recording the two `
            + `disagree about is not published.`);
        }
        // ONE LISTING PER INTERNED PATH, located by the name the recorder gave it inside
        // THIS transaction's own capture, never by arithmetic on the interned string.
        rec.listings = rec.c.paths.map((interned) => {
          // A CAIRO SOURCE FILE, interned by the recorder for a class bound to a proved
          // build that embeds its sources (`./sources/cairo/<package@version or root>/…`).
          // It is published under `cairo/<…>`, a trailing suffix of the interned path, and
          // carries no instruction listing: a step there is placed at a source line.
          const cm = /^\.\/sources\/(cairo\/.+\.cairo)$/.exec(interned);
          if (cm) {
            if (cm[1].split('/').includes('..')) {
              throw refuse(SOURCE_REFUSAL, `${src} interns ${interned}, which climbs out of `
                + 'its capture directory.');
            }
            const file = join(tdir, 'sources', cm[1]);
            if (!existsSync(file)) {
              throw refuse(SOURCE_REFUSAL, `${src} interns ${interned} and ${file} does not exist.`);
            }
            const text = readFileSync(file, 'utf8');
            return { interned, publishedPath: cm[1], classHash: null, text, listing: null,
                     lines: text.split('\n').length };
          }
          const name = interned.split('/').pop();
          const m = /^(0x[0-9a-f]{1,64})\.casm$/.exec(name);
          if (!m) {
            throw refuse(SOURCE_REFUSAL, `${src} interns ${interned}, whose name is not `
              + `\`<class hash>.casm\`; the class a listing is of is the name the recorder `
              + `gave it.`);
          }
          const file = join(tdir, 'sources', name);
          if (!existsSync(file)) {
            throw refuse(SOURCE_REFUSAL, `${src} interns ${interned} and ${file} does not exist.`);
          }
          const text = readFileSync(file, 'utf8');
          const listing = parseListing(text);
          return { interned, publishedPath: name, classHash: m[1], text, listing,
                   lines: listing.length };
        });
        // Every step lands inside its own listing, or nothing is published: an
        // out-of-range (path, line) would place a step at an instruction it did not run.
        const bad = [];
        for (let i = 0; i < rec.c.pathId.length; i++) {
          const L = rec.listings[rec.c.pathId[i]];
          const ln = rec.c.line[i];
          if (!L || ln < 1 || ln > L.lines) bad.push(i);
          if (bad.length > 5) break;
        }
        if (bad.length > 0) {
          throw refuse(SOURCE_REFUSAL, `${src}: step(s) ${bad.join(', ')} do not land inside a `
            + `listing this capture holds.`);
        }
      }
      recordings.set(r.txHash, rec);
    }
  }

  // ── the rows ──────────────────────────────────────────────────────────────
  const rows = [];
  const blocks = [];
  const yielded = [];
  for (const { b } of caps) {
    const byHash = new Map(b.chain.transactions.map((t) => [t.hash, t]));
    const header = b.chain.header;
    if (b.perTransaction.length !== b.chain.transactions.length) {
      throw refuse(SOURCE_REFUSAL, `block ${b.blockNumber}: ${b.perTransaction.length} report(s) `
        + `for ${b.chain.transactions.length} transaction(s).`);
    }
    blocks.push({
      number: b.blockNumber,
      hash: b.blockHash,
      timestamp: b.timestamp,
      // `parentArchiveRoot` is §5.2b's required predecessor link, named after Aztec's
      // object (DEL-5's note); Starknet's predecessor link is the parent block hash.
      parentArchiveRoot: b.parentHash,
      stateRoot: header.new_root ?? '',
      starknetVersion: b.starknetVersion,
      transactions: b.chain.transactions.map((t) => t.hash),
    });
    for (const r of b.perTransaction) {
      const t = byHash.get(r.txHash);
      if (!t) {
        throw refuse(SOURCE_REFUSAL, `block ${b.blockNumber}: report for ${r.txHash}, which the `
          + `block's transaction list does not hold.`);
      }
      const { body, receipt } = t;
      const rec = recordings.get(r.txHash) ?? null;
      const untracedReason = rec !== null ? null
        : r.outcome === 'refused' ? r.refusal
          : `Replayed by ${HERE}'s capture and not recorded in this run (the capture was `
            + `narrowed with \`trace-block --tx\`); a run without that narrowing records it.`;
      const base = {
        txHash: r.txHash,
        blockNumber: b.blockNumber,
        txIndexInBlock: r.txIndex,
        revertCode: receipt.execution_status === 'REVERTED' ? 1 : 0,
        cost: costVectorForRow({ body, receipt, header }),
        executions: executionsForRow(untracedReason),
        roles: rolesForRow({ body, receipt }),
        payload: payloadForRow({ body }),
        firstInBlock: r.txIndex === 0,
        bodyRetained: true,
        effectVisible: true,
        starknetType: body.type,
        ...(body.type === 'L1_HANDLER' ? { l1Message: l1MessageForRow({ body, receipt }) } : {}),
        // A CLASS THIS TRANSACTION SET — an upgrade's `replace_class`, or a deployment —
        // republished from the recorder's replay (`classChanges`), only where there is one.
        // Consensus on the classes is the block's state diff, which the recorder matched.
        ...((r.classChanges ?? []).length > 0 ? { classChanges: r.classChanges } : {}),
      };
      if (rec === null) {
        const refused = r.outcome === 'refused';
        rows.push({
          ...base,
          outcome: refused ? 'refused' : 'not-attempted',
          reason: untracedReason,
          refusalReason: refused ? r.refusalReason : 'not-attempted',
        });
        continue;
      }
      const facts = r.effects?.facts ?? [];
      const mismatches = facts.filter((f) => f.matches === false)
        .map((f) => ({ field: f.field, published: f.published ?? null,
                       replayed: f.replayed ?? null, matches: false }));
      const reproduced = mismatches.length === 0;
      const c = rec.c;
      const steps = c ? c.counts.steps : r.container.steps;
      const positioned = c ? c.pathId.filter((p, i) => p !== null && c.line[i] > 0).length : 0;
      // MEASURED, never declared: source level means EVERY step sits on a Cairo source line
      // (a class bound to a proved build whose sources are republished). One step on a CASM
      // listing — any class with no such build, or a statement its build did not locate —
      // makes it false, which is the AND Data-Contract §5.2b defines.
      const onSource = c ? c.pathId.filter((p) => rec.listings[p]?.classHash === null).length : 0;
      rec.sourceLevel = c ? steps > 0 && onSource === steps : false;
      rec.stepsOnSource = onSource;
      rows.push({
        ...base,
        outcome: reproduced ? 'replayed' : 'divergent',
        kind: reproduced ? 'replayed' : 'divergent',
        replayed: true,
        container: `ct/${r.txHash}.ct`,
        containerBytes: rec.containerBytes,
        recordedBy: recorderCommit,
        preStateReadAt: b.blockNumber - 1,
        instructionsExecuted: r.vm.steps,
        effects: { reproduced, matched: r.effects.matched, mismatched: mismatches.length,
                   mismatches },
        recording: {
          bytes: rec.containerBytes,
          steps,
          callsOpened: c ? c.counts.calls : r.container.entryPointFrames + r.container.internalCalls,
          logEvents: c ? c.counts.io_events : r.container.eventsWritten,
          sourceLevel: rec.sourceLevel,
          // How many steps are on a Cairo source line rather than a CASM listing line.
          stepsOnSource: rec.stepsOnSource,
          stepsPositioned: positioned,
          stepsUnpositioned: steps - positioned,
          contexts: rec.listings ? rec.listings.length : r.classes.length,
          entryPointFrames: r.container.entryPointFrames,
          varnames: c ? c.counts.varnames : 0,
        },
        sourceBundles: `sources/${r.txHash}.json`,
        instructions: `instructions/${r.txHash}.json`,
        positions: `positions/${r.txHash}.json`,
        callTrace: `calltrace/${r.txHash}.json`,
        artifacts: r.classes.map((k) => artifactRow(k, r)),
      });
      yielded.push({ txHash: r.txHash, outcome: reproduced ? 'replayed' : 'divergent' });
    }
  }

  const capturedAt = capturedAtFlag ?? new Date().toISOString();
  const endpointLabel = args.one('endpoint-label', newest.endpoint);
  const containerVersions = [...new Set([...recordings.values()].map((x) => x.c?.version)
    .filter((v) => v !== undefined))];
  const snapshot = {
    format: SNAPSHOT_FORMAT,
    provenance: {
      kind: 'live-capture',
      chain: CHAIN_SLUG,
      label: args.one('label', 'Real Starknet mainnet data'),
      endpoint: endpointLabel,
      recorder: { ...RECORDER },
      prestateStrategy: PRESTATE_STRATEGY,
      identifierEncoding: { ...IDENTIFIER_ENCODING },
      capturedAt,
      nodeVersion: `starknet spec ${newest.chain.specVersion}`,
      tool: HERE,
      runtimeCommit: recorderCommit,
      executor: newest.recorder?.executor ?? '',
      endpointControl: { method: 'thisMethodDoesNotExist', ...control },
      // THE BOUNDARY, WHOLE, so `window.replayableFrom` can be re-derived from readings
      // rather than trusted. The EXECUTOR binds on this endpoint: the node serves state
      // below the floor (`nodeState.belowFloor`), and the executor carries no constants
      // for any Starknet version older than the floor block's.
      floorProbe,
      containerVersion: containerVersions.length === 1 ? containerVersions[0] : null,
    },
    window: {
      tip,
      finalized,
      replayableFrom: floor,
      replayableTo: tip,
      blocks: tip - floor + 1,
    },
    counts: {},
    blocks: [...blocks].reverse(),
    transactions: rows,
    captures: [{
      capturedAt,
      by: HERE,
      window: { tip, finalized, replayableFrom: floor, replayableTo: tip, blocks: tip - floor + 1 },
      nodeVersion: `starknet spec ${newest.chain.specVersion}`,
      runtimeCommit: recorderCommit,
      yielded,
    }],
    artifactResolution: 'artifact-resolution.json',
  };
  snapshot.counts = recountSnapshot(snapshot);

  if (args.has('dry-run')) {
    console.log(JSON.stringify({ chain: CHAIN_SLUG,
                                 blocks: caps.map((c) => c.b.blockNumber),
                                 counts: snapshot.counts, window: snapshot.window }, null, 1));
    return;
  }

  // ── the tree ──────────────────────────────────────────────────────────────
  const out = resolve(outDir);
  for (const d of ['', 'ct', 'sources', 'instructions', 'positions', 'calltrace']) {
    mkdirSync(join(out, d), { recursive: true });
  }
  const writeJson = (rel, obj) => {
    const p = join(out, rel);
    writeFileSync(`${p}.tmp`, `${JSON.stringify(obj, null, 1)}\n`);
    renameSync(`${p}.tmp`, p);
  };

  for (const rec of recordings.values()) {
    const { txHash, c, listings } = rec;
    const row = rows.find((x) => x.txHash === txHash);
    copyFileSync(rec.containerSrc, join(out, 'ct', `${txHash}.ct`));
    // SOURCE BUNDLE — one entry per class the recording entered, keyed by the CLASS HASH
    // (Source-Resolution.md §4: on Starknet a class hash IS the code's identity), and
    // inside by `<class hash>.casm` — a trailing path-segment suffix of the interned
    // `./sources/<class hash>.casm`, which is how the source island matches them.
    writeJson(`sources/${txHash}.json`, {
      txHash,
      sourceLevel: rec.sourceLevel,
      // A class bound to a proved build that embeds its sources ALSO carries the Cairo
      // files its own steps were shown in (the recorder's `classes[].cairoSources`), in
      // the same bundle: the reader keys bundles by class. Its language is then `cairo`.
      bundles: listings.filter((L) => L.classHash !== null).map((L) => {
        const cairo = cairoFilesOf(rec, L.classHash);
        return {
        address: row.artifacts.find((a) => a.contractClassId === L.classHash)?.address ?? '',
        codeHash: L.classHash,
        files: { [L.publishedPath]: L.text,
                 ...Object.fromEntries(cairo.map((F) => [F.publishedPath, F.text])) },
        origin: 'CASM compiled by the recorder from the Sierra class starknet_getClass '
          + `served at block ${row.preStateReadAt}`
          + (row.artifacts.find((a) => a.contractClassId === L.classHash)?.resolved
            ? ', labelled with the names of a build of its source proved against that class'
            : '')
          + (cairo.length
            ? `; and ${cairo.length} Cairo source file(s) of that build, read by it, which `
              + 'the steps of this class are shown in where the build located them'
              + (licenceOf(rec, L.classHash) ? ` (licence ${licenceOf(rec, L.classHash)}; `
                + 'files under package@version/ are that dependency\'s own)' : '')
            : ''),
        shape: cairo.length ? 'source' : 'disassembly',
        corroboration: 'single-distributor',
        agreeingDistributors: ['the chain itself'],
        language: cairo.length ? 'cairo' : POSITION_LANGUAGE,
        };
      }),
    });
    // A step on a Cairo source line has no instruction listing behind it, so its pc
    // and opcode are not stated (null), never guessed.
    const at = (i) => listings[c.pathId[i]]?.listing?.[c.line[i] - 1] ?? null;
    const pc = new Array(c.pathId.length);
    const op = new Array(c.pathId.length);
    let counters = 0;
    for (let i = 0; i < c.pathId.length; i++) {
      const insn = at(i);
      pc[i] = insn ? insn.pc : null;
      op[i] = mnemonic(insn);
      if (insn) counters += 1;
    }
    writeJson(`instructions/${txHash}.json`, {
      schema: INSTRUCTION_STREAM_SCHEMA,
      tx: txHash,
      isa: INSTRUCTION_SET,
      paths: listings.map((L) => L.publishedPath),
      steps: row.recording.steps,
      counters,
      pathId: c.pathId,
      pc,
      op,
    });
    writeJson(`positions/${txHash}.json`, {
      schema: POSITION_STREAM_SCHEMA,
      tx: txHash,
      steps: row.recording.steps,
      positioned: row.recording.stepsPositioned,
      measuredPostHoc: false,
      measuredBy: `${HERE} (read from the container)`,
      paths: listings.map((L) => L.publishedPath),
      pathId: c.pathId,
      line: c.line,
      column: c.line.map(() => null),
    });
    // CALL TRACE — one frame per call the container opened, plus the synthetic top frame
    // `S5-CALLTRACE-AGREE` counts. A frame's place is the step it opened at, so frames in
    // different classes say so. The container's own `<toplevel>` call is the synthetic
    // frame and is not repeated.
    const entries = c.callEntries.filter((e) => e.function !== '<toplevel>');
    const frames = [{ name: '<transaction>', depth: 0, step: 0, path: null, line: null,
                      args: [], contractAddress: null, endStep: null, foldedBy: null,
                      foldWhy: null, hiddenDescendants: 0, hiddenSteps: 0 }];
    for (const e of entries) {
      const L = listings[c.pathId[e.entry_step]] ?? null;
      const contract = (e.args ?? []).find((a) => a.varname === 'contract')?.value?.text ?? null;
      frames.push({
        name: e.function ?? '<unnamed>',
        depth: e.depth ?? 1,
        step: e.entry_step ?? 0,
        path: L ? L.publishedPath : null,
        line: c.line[e.entry_step] ?? null,
        args: [],
        contractAddress: contract,
        endStep: e.exit_step ?? null,
        foldedBy: null,
        foldWhy: null,
        hiddenDescendants: 0,
        hiddenSteps: 0,
      });
    }
    if (frames.length !== row.recording.callsOpened) {
      // `counts.calls` includes the container's own top-level call, which is the
      // synthetic frame here — so the two readings must agree exactly.
      throw refuse(SOURCE_REFUSAL, `${txHash}: the container counts ${row.recording.callsOpened} `
        + `call(s) and its call stream yields ${frames.length} frame(s).`);
    }
    row.recording.callsOpened = frames.length - 1;
    writeJson(`calltrace/${txHash}.json`, {
      schema: CALLTRACE_STREAM_SCHEMA,
      tx: txHash,
      callsOpened: row.recording.callsOpened,
      frames: frames.length,
      steps: row.recording.steps,
      // No fold rules yet: every frame is a class the chain ran. Folding Cairo's corelib
      // helpers (the `fn@0x…` internal calls) is a presentation decision for later.
      foldRules: [],
      foldedFrames: 0,
      foldedSteps: 0,
      measuredPostHoc: false,
      measuredBy: `${HERE} (read from the container)`,
      frame: frames,
    });
  }

  writeJson('artifact-resolution.json', {
    format: 'blocktracer/artifact-resolution@1',
    chain: CHAIN_SLUG,
    measuredAt: capturedAt,
    // THE RESOLVER IS THE RECORDER'S `bind-class` CHECK, applied at trace time: a class is
    // resolved when a build of its source was proved against it (see `artifactRow`).
    // Counted over distinct classes, so a class two transactions entered counts once.
    measuredBy: { tool: HERE,
                  resolver: 'codetracer-cairo-onchain bind-class bindings, re-checked against '
                    + 'the class that ran (trace-block --class-sources); names, not lines',
                  runtimeCommit: recorderCommit },
    endpoint: endpointLabel,
    counts: {
      transactionsConsidered: recordings.size,
      transactionsWithSourceBundle: recordings.size,
      stepsPositioned: rows.reduce((n, x) => n + (x.recording?.stepsPositioned ?? 0), 0),
      stepsTotal: rows.reduce((n, x) => n + (x.recording?.steps ?? 0), 0),
      contracts: new Set(rows.flatMap((x) => (x.artifacts ?? []).map((a) => a.contractClassId))).size,
      resolved: new Set(rows.flatMap((x) => (x.artifacts ?? [])
        .filter((a) => a.resolved === true).map((a) => a.contractClassId))).size,
    },
    transactions: rows.filter((x) => x.replayed === true).map((x) => ({
      txHash: x.txHash, blockNumber: x.blockNumber, artifacts: x.artifacts, positions: null,
    })),
  });

  writeJson('snapshot.json', snapshot);

  console.log(`${HERE}: wrote ${out}`);
  console.log(`  chain ${CHAIN_SLUG} · blocks ${caps.map((c) => c.b.blockNumber).join(', ')} · `
              + `${rows.length} transaction(s), ${recordings.size} recorded`);
  console.log(`  counts.blocks=${snapshot.counts.blocks} counts.transactions=`
              + `${snapshot.counts.transactions} counts.accountedFor=${snapshot.counts.accountedFor}`);
  console.log(`  window.replayableFrom=${floor} (the executor's floor: Starknet `
              + `${ex.version}; ${ex.versionBelow} below it is refused) finalized=${finalized}`);
  for (const x of rows.filter((y) => y.replayed === true)) {
    console.log(`  ${x.txHash.slice(0, 12)}… ${x.outcome} steps=${x.recording.steps} `
                + `calls=${x.recording.callsOpened} effects ${x.effects.matched}/`
                + `${x.effects.matched + x.effects.mismatched}`);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? '').href) {
  main(process.argv.slice(2)).catch((e) => dieOperational(HERE, e));
}
