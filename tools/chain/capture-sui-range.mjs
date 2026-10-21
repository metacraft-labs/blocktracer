#!/usr/bin/env node
// capture-sui-range.mjs — trace a window of Sui checkpoints and produce one snapshot tree.
//
// The Sui twin of `capture-eth-range.mjs` (a concrete duplicate; see
// produce-sui-snapshot.mjs for why). One run:
//
//   1. reads every checkpoint of the window, and every transaction in each, over GraphQL
//      (Chain-Data-Ingestion.md §4.6), and the chain's tip;
//   2. MEASURES the tracing floor — the first checkpoint of the first epoch whose protocol
//      version runs an execution layer that emits trace events
//      (`lib/sui-producer-facts.mjs` MIN_TRACED_PROTOCOL) — by binary search over epochs,
//      rather than quoting it;
//   3. writes both to `<work>/acquisition.json`;
//   4. records up to `--max` of the window's transactions, in checkpoint order, through
//      `codetracer-move-recorder replay`, which runs `sui replay --trace` against the same
//      network: the replay fetches exactly the object versions each transaction names
//      (version-addressed prestate, Chain-Support-Matrix.md §1.4);
//   5. hands the acquisition and every recording to `produce-sui-snapshot.mjs`.
//
// A recording that the recorder refuses with `NO-TRACE-EVENTS` is an OUTCOME (the
// transaction predates traceable execution) and the run continues; any other recorder
// failure stops the run, with the log's tail, rather than reaching a tree.
//
// Work layout, resumable: `<work>/replay/<digest>/` (sui replay's artifacts, shared by
// reruns), `<work>/rec/<digest>/{capture/, run.log, done.json}`.

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { delimiter, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  checkpointWithTransactions, firstEpochAtProtocol, graphql, graphqlUrlFor, latestCheckpoint,
} from './lib/sui-graphql.mjs';
import { MIN_TRACED_PROTOCOL } from './lib/sui-producer-facts.mjs';
import {
  ACQUISITION_FORMAT, NO_TRACE_EVENTS, SUI_REPLAY_STACK_OVERFLOW, TRACE_TOO_LARGE,
} from './produce-sui-snapshot.mjs';

/** The exact signature of the tracer's stack overflow inside `sui replay --trace`. */
const TRACER_STACK_OVERFLOW = /sui replay failed[\s\S]*has overflowed its stack/;

const HERE = dirname(fileURLToPath(import.meta.url));

const USAGE = `usage: capture-sui-range.mjs --recorder PATH --recorder-commit SHA
         [--node mainnet|testnet|devnet|URL] [--sui PATH]
         [--from N --to M | --depth D [--checkpoints K]] [--max N]
         [--work DIR] [--out DIR] [--ct-print PATH] [--positions-reader PATH]
         [--fresh] [--plan]`;

function parse(argv) {
  const v = new Map();
  const f = new Set();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new Error(`unexpected argument '${a}'\n${USAGE}`);
    const name = a.slice(2);
    if (['fresh', 'plan', 'help'].includes(name)) { f.add(name); continue; }
    if (argv[i + 1] === undefined) throw new Error(`--${name} needs a value`);
    v.set(name, argv[++i]);
  }
  return { get: (n, d) => v.get(n) ?? d, has: (n) => f.has(n) };
}

const int = (s, name) => {
  if (s === undefined) return undefined;
  if (!/^\d+$/.test(s)) throw new Error(`--${name} must be a non-negative integer, got '${s}'`);
  return Number(s);
};

/** Run a child process with merged output to `logPath`; resolve to its exit code. */
function runLogged(cmd, args, logPath, env) {
  return new Promise((done, fail) => {
    const child = spawn(cmd, args, { env, stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = [];
    child.stdout.on('data', (d) => chunks.push(d));
    child.stderr.on('data', (d) => chunks.push(d));
    child.on('error', fail);
    child.on('close', (code) => {
      writeFileSync(logPath, Buffer.concat(chunks));
      done(code);
    });
  });
}

async function main(argv) {
  const a = parse(argv);
  if (a.has('help')) { console.log(USAGE); return; }
  const recorder = a.get('recorder');
  const recorderCommit = a.get('recorder-commit');
  if (!recorder || !recorderCommit) throw new Error(`--recorder and --recorder-commit are required\n${USAGE}`);
  if (!existsSync(recorder)) throw new Error(`--recorder ${recorder} does not exist`);
  const node = a.get('node', 'mainnet');
  const url = graphqlUrlFor(node);
  const work = resolve(a.get('work', '.sui-range/work'));
  const out = resolve(a.get('out', '.sui-range/tree'));
  const max = int(a.get('max', '6'), 'max');
  // `sui replay` is run by the recorder as `sui` on PATH; --sui puts a specific build first.
  const sui = a.get('sui');
  const env = { ...process.env };
  if (sui) {
    if (!existsSync(sui)) throw new Error(`--sui ${sui} does not exist`);
    env.PATH = `${dirname(resolve(sui))}${delimiter}${env.PATH}`;
  }

  const tipCp = await latestCheckpoint(url);
  const tip = tipCp.sequenceNumber;
  let lo = int(a.get('from'), 'from');
  let hi = int(a.get('to'), 'to');
  if ((lo === undefined) !== (hi === undefined)) throw new Error('--from and --to go together');
  if (lo === undefined) {
    const depth = int(a.get('depth', '100'), 'depth');
    const k = int(a.get('checkpoints', '1'), 'checkpoints');
    if (k < 1) throw new Error('--checkpoints must be at least 1');
    hi = tip - depth;
    lo = hi - k + 1;
  }
  if (lo > hi || hi > tip) throw new Error(`window ${lo}..${hi} is not inside 0..${tip}`);

  const epochNow = (await graphql(url, '{ epoch { epochId } }')).epoch.epochId;
  const floorEpoch = await firstEpochAtProtocol(url, MIN_TRACED_PROTOCOL, epochNow);
  if (floorEpoch === null || floorEpoch.firstCheckpoint === null) {
    throw new Error(`no epoch on ${url} runs protocol ${MIN_TRACED_PROTOCOL} or later`);
  }
  const tracedFloor = {
    checkpoint: floorEpoch.firstCheckpoint,
    epoch: floorEpoch.epoch,
    protocolVersion: floorEpoch.protocolVersion,
    previousProtocolVersion: floorEpoch.previousProtocolVersion,
    minProtocol: MIN_TRACED_PROTOCOL,
    method: 'binary search over epochs for the first protocol version at or above '
      + 'minProtocol; the floor is that epoch\'s first checkpoint',
    measuredAt: new Date().toISOString(),
  };

  const checkpoints = [];
  for (let s = lo; s <= hi; s++) {
    const cp = await checkpointWithTransactions(url, s);
    if (cp === null) throw new Error(`checkpoint ${s} is not served by ${url}`);
    checkpoints.push(cp);
  }
  const all = checkpoints.flatMap((cp) => cp.transactions.map((tx) => tx.digest));
  const planned = all.slice(0, max);
  if (a.has('plan')) {
    console.log(JSON.stringify({ node, window: `${lo}..${hi}`, tip, tracedFloor,
      transactions: all.length, planned }, null, 1));
    return;
  }

  let replayRuntime = '';
  {
    const vlog = join(work, 'sui-version.log');
    mkdirSync(work, { recursive: true });
    const code = await runLogged('sui', ['--version'], vlog, env);
    if (code !== 0) throw new Error(`\`sui --version\` failed; is sui on PATH or given by --sui?`);
    replayRuntime = readFileSync(vlog, 'utf8').trim();
  }
  const acquisitionPath = join(work, 'acquisition.json');
  writeFileSync(acquisitionPath, `${JSON.stringify({
    format: ACQUISITION_FORMAT,
    node,
    endpoint: url,
    fetchedAt: new Date().toISOString(),
    replayRuntime,
    tip: tipCp,
    tracedFloor,
    window: { from: lo, to: hi },
    checkpoints,
  }, null, 1)}\n`);

  const recDirs = [];
  for (const digest of planned) {
    const recDir = join(work, 'rec', digest);
    const donePath = join(recDir, 'done.json');
    if (a.has('fresh')) rmSync(recDir, { recursive: true, force: true });
    recDirs.push(recDir);
    // A recording is reused only when the SAME recorder build made it: every traced row
    // is attributed to --recorder-commit, and a container another build wrote would carry
    // that attribution falsely.
    if (existsSync(donePath)
        && JSON.parse(readFileSync(donePath, 'utf8')).recorderCommit === recorderCommit) {
      continue;
    }
    mkdirSync(recDir, { recursive: true });
    const logPath = join(recDir, 'run.log');
    const capture = join(recDir, 'capture');
    rmSync(capture, { recursive: true, force: true });
    // A replay directory without its trace is a leftover (the trace is deleted once it is
    // converted, and a rerun under another recorder build converts again): `sui replay`
    // refuses to overwrite the artifacts beside it, so the directory is cleared and the
    // transaction replayed from the network again.
    const replayed = join(work, 'replay', digest);
    if (existsSync(replayed) && !existsSync(join(replayed, 'trace.json.zst'))) {
      rmSync(replayed, { recursive: true, force: true });
    }
    const code = await runLogged(recorder, ['replay', '--digest', digest, '--node', node,
      '--replay-dir', join(work, 'replay'), '-o', capture], logPath, env);
    const log = readFileSync(logPath, 'utf8');
    const cts = existsSync(capture) ? readdirSync(capture).filter((x) => x.endsWith('.ct')) : [];
    let done;
    if (code === 0 && cts.length === 1) {
      done = { digest, outcome: 'traced', recorderCommit };
    } else if (code !== 0 && log.includes(NO_TRACE_EVENTS)) {
      done = { digest, outcome: 'no-trace-events', recorderCommit,
               message: log.split('\n').find((l) => l.includes(NO_TRACE_EVENTS)) };
    } else if (code !== 0 && log.includes(TRACE_TOO_LARGE)) {
      done = { digest, outcome: 'too-large', recorderCommit, refusal: TRACE_TOO_LARGE,
               message: log.split('\n').find((l) => l.includes(TRACE_TOO_LARGE)) };
    } else if (code !== 0 && TRACER_STACK_OVERFLOW.test(log)) {
      // `sui replay --trace` itself aborts on some transactions: the tracer overflows the
      // main thread's stack (a 64 MB stack does not help), while the same replay without
      // `--trace` succeeds. That is a statement about the replay runtime, so it is an
      // outcome; only this exact signature is, and every other failure still stops the run.
      done = { digest, outcome: 'replay-crashed', recorderCommit,
               refusal: SUI_REPLAY_STACK_OVERFLOW,
               message: log.split('\n').find((l) => l.includes('overflowed its stack')) };
    } else {
      throw new Error(`recording ${digest} failed (exit ${code}, ${cts.length} container(s)); `
        + `the run stops rather than publish around it. Log tail:\n${log.slice(-1500)}`);
    }
    writeFileSync(donePath, `${JSON.stringify(done, null, 1)}\n`);
    // The raw trace is converted (or refused) and the producer reads only the replay's
    // effects and disassembly, so the trace — a median of ~4 MB compressed, and 4 GB for
    // the largest seen — is removed now rather than at the end of the window.
    rmSync(join(work, 'replay', digest, 'trace.json.zst'), { force: true });
    console.log(`${digest}: ${done.outcome}`);
  }

  const produce = [join(HERE, 'produce-sui-snapshot.mjs'),
    '--acquisition', acquisitionPath, '--replay-root', join(work, 'replay'),
    '--recorder-commit', recorderCommit, '--out', out,
    ...(a.get('ct-print') ? ['--ct-print', a.get('ct-print')] : []),
    ...(a.get('positions-reader') ? ['--positions-reader', a.get('positions-reader')] : []),
    ...recDirs.flatMap((d) => ['--rec', d])];
  const code = await runLogged(process.execPath, produce, join(work, 'produce.log'), env);
  process.stdout.write(readFileSync(join(work, 'produce.log'), 'utf8'));
  if (code !== 0) process.exit(code);
}

main(process.argv.slice(2)).catch((e) => {
  console.error(`capture-sui-range.mjs: ${e.message}`);
  process.exit(1);
});
