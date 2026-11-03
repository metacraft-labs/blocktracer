#!/usr/bin/env node
// capture-aptos-range.mjs — trace a window of Aptos blocks and produce one snapshot tree.
//
// The Aptos twin of `capture-sui-range.mjs` (a concrete duplicate; see
// produce-aptos-snapshot.mjs for why). One run:
//
//   1. reads the node's ledger info — its tip and the retention boundary it states
//      (`oldest_block_height`, `oldest_ledger_version`), which is the window's floor;
//   2. reads every block of the window with every transaction in it, over REST
//      (`/v1/blocks/by_height/{h}?with_transactions=true`), and the header of the block
//      below it, whose hash is the window's predecessor link;
//   3. writes them to `<work>/acquisition.json`;
//   4. records up to `--max` of the window's USER transactions, in version order, through
//      `codetracer-move-recorder aptos-replay`, which runs `aptos move replay --trace`
//      against the same node: the replay reads every state value at the version before the
//      transaction (version-addressed prestate, Chain-Support-Matrix.md §1.4) and compares
//      its output with the transaction info the chain committed;
//   5. hands the acquisition and every recording to `produce-aptos-snapshot.mjs`.
//
// A replay whose output does not match the chain's is an OUTCOME, `divergent`: the CLI
// writes its trace before it compares, so the recorder converts that trace on a second
// run and the row is published as a recording that did not reproduce the chain. A trace
// over the recorder's bound is `too-large`. Any other failure stops the run, with the
// log's tail, rather than reaching a tree.
//
// THE NETWORK IS ONE OF THREE THINGS. `--node` (default mainnet) reads it directly;
// `--record DIR` reads it through `aptos-rest-transcript.mjs` in record mode, which waits
// out the public node's rate limit and writes every answer into DIR; `--transcript DIR`
// serves DIR on loopback in replay mode and reaches no network at all — a request it does
// not hold fails the run. The aptos CLI and the recorder both read through the same URL.
//
// Work layout, resumable: `<work>/replay/<version>/` (the replay's trace and each entered
// module's `.mv` and `.mv.masm`, shared by reruns), `<work>/rec/<version>/{capture/,
// run.log, done.json}`.

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  blockHeader, blockWithTransactions, derivedRecordingId, ledgerInfo, restBaseFor,
} from './lib/aptos-rest.mjs';
import { isUserTransaction } from './lib/aptos-producer-facts.mjs';
import { pruneTranscript, startTranscriptServer } from './aptos-rest-transcript.mjs';
import {
  ACQUISITION_FORMAT, NO_TRACE_EVENTS, REPLAY_MISMATCH, TRACE_TOO_LARGE,
} from './produce-aptos-snapshot.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

const USAGE = `usage: capture-aptos-range.mjs --recorder PATH --recorder-commit SHA --aptos PATH
         --from N --to M [--node mainnet|URL] [--max N]
         [--work DIR] [--out DIR] [--ct-print PATH] [--positions-reader PATH]
         [--fixed-time ISO] [--transcript DIR [--prune-transcript] | --record DIR]
         [--fresh] [--plan]`;

function parse(argv) {
  const v = new Map();
  const f = new Set();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) throw new Error(`unexpected argument '${a}'\n${USAGE}`);
    const name = a.slice(2);
    if (['fresh', 'plan', 'help', 'prune-transcript'].includes(name)) { f.add(name); continue; }
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
  const aptos = a.get('aptos');
  if (!recorder || !recorderCommit || !aptos) {
    throw new Error(`--recorder, --recorder-commit and --aptos are required\n${USAGE}`);
  }
  for (const [flag, p] of [['recorder', recorder], ['aptos', aptos]]) {
    if (!existsSync(p)) throw new Error(`--${flag} ${p} does not exist`);
  }
  if (a.get('transcript') && a.get('record')) throw new Error('--transcript and --record exclude each other');
  const transcriptDir = a.get('transcript') ?? a.get('record');
  const upstream = restBaseFor(a.get('node', 'mainnet'));
  const transcript = transcriptDir
    ? await startTranscriptServer({ mode: a.get('transcript') ? 'replay' : 'record',
                                    dir: resolve(transcriptDir), upstream,
                                    // Slow enough that the public node's anonymous limit is
                                    // rarely reached; each 429 costs a replay a retry.
                                    minGapMs: 600,
                                    log: (m) => console.error(`transcript: ${m}`) })
    : null;
  const base = transcript ? transcript.url : upstream;
  const work = resolve(a.get('work', '.aptos-range/work'));
  const out = resolve(a.get('out', '.aptos-range/tree'));
  const max = int(a.get('max', '6'), 'max');
  const fixedTime = a.get('fixed-time');
  if (fixedTime !== undefined && Number.isNaN(Date.parse(fixedTime))) {
    throw new Error(`--fixed-time must be an ISO instant, got '${fixedTime}'`);
  }
  const lo = int(a.get('from'), 'from');
  const hi = int(a.get('to'), 'to');
  if (lo === undefined || hi === undefined) throw new Error(`--from and --to are required\n${USAGE}`);

  const stop = async (completed) => {
    if (!transcript) return;
    const { misses, calls, hits } = await transcript.close();
    if (misses > 0) {
      throw new Error(`${misses} REST request(s) missed the transcript at ${transcriptDir}; `
        + 'the capture asked for something it was not recorded with');
    }
    if (a.get('transcript')) {
      console.error(`transcript: ${hits.size} of ${calls} recorded call(s) asked for`);
      // `--prune-transcript`: after a whole, clean replay, keep only what it asked for.
      if (a.has('prune-transcript') && completed) {
        console.error(`transcript: pruned ${pruneTranscript(resolve(transcriptDir), hits)} call(s)`);
      }
    }
  };

  let completed = false;
  try {
    const ledger = await ledgerInfo(base);
    if (lo > hi || hi > ledger.blockHeight) {
      throw new Error(`window ${lo}..${hi} is not inside 0..${ledger.blockHeight}`);
    }
    if (lo < ledger.oldestBlockHeight) {
      throw new Error(`window ${lo}..${hi} starts below the node's oldest block `
        + `${ledger.oldestBlockHeight}; it has pruned what the replay would read`);
    }
    const below = await blockHeader(base, lo - 1);
    const blocks = [];
    for (let h = lo; h <= hi; h++) blocks.push(await blockWithTransactions(base, h));

    const user = blocks.flatMap((b) => b.transactions.filter(isUserTransaction)
      .map((tx) => ({ tx, block: b })));
    const planned = user.slice(0, max);
    if (a.has('plan')) {
      console.log(JSON.stringify({ base, window: `${lo}..${hi}`, ledger,
        transactions: blocks.reduce((n, b) => n + b.transactions.length, 0),
        user: user.length, planned: planned.map((p) => p.tx.version) }, null, 1));
      return;
    }

    mkdirSync(work, { recursive: true });
    let replayRuntime = '';
    {
      const vlog = join(work, 'aptos-version.log');
      const code = await runLogged(aptos, ['--version'], vlog, process.env);
      if (code !== 0) throw new Error(`\`${aptos} --version\` failed`);
      replayRuntime = readFileSync(vlog, 'utf8').trim();
    }
    const acquisitionPath = join(work, 'acquisition.json');
    writeFileSync(acquisitionPath, `${JSON.stringify({
      format: ACQUISITION_FORMAT,
      // From a transcript, the endpoint is the one it was RECORDED against; the loopback
      // port it was served on is incidental and changes every run.
      endpoint: transcript
        ? `${a.get('transcript')
          ? JSON.parse(readFileSync(join(resolve(transcriptDir), 'manifest.json'), 'utf8')).upstream
          : upstream} (transcript)`
        : upstream,
      fetchedAt: fixedTime ?? new Date().toISOString(),
      replayRuntime,
      ledger,
      window: { from: lo, to: hi },
      predecessor: { height: lo - 1, hash: below.block_hash },
      blocks,
    }, null, 1)}\n`);

    const recDirs = [];
    for (const { tx, block } of planned) {
      const version = String(tx.version);
      const recDir = join(work, 'rec', version);
      const donePath = join(recDir, 'done.json');
      if (a.has('fresh')) rmSync(recDir, { recursive: true, force: true });
      recDirs.push(recDir);
      // A recording is reused only when the SAME recorder build made it.
      if (existsSync(donePath)
          && JSON.parse(readFileSync(donePath, 'utf8')).recorderCommit === recorderCommit) {
        continue;
      }
      mkdirSync(recDir, { recursive: true });
      const capture = join(recDir, 'capture');
      const replayDir = join(work, 'replay', version);
      const recordingId = await derivedRecordingId(
        Number(BigInt(block.block_timestamp) / 1000n), tx.hash);
      const runOnce = async (logName) => {
        rmSync(capture, { recursive: true, force: true });
        const logPath = join(recDir, logName);
        const code = await runLogged(recorder, ['aptos-replay', '--txn-version', version,
          '--network', base, '--aptos-cli', resolve(aptos), '--replay-dir', replayDir,
          '-o', capture, '--recording-id', recordingId], logPath, process.env);
        const log = readFileSync(logPath, 'utf8');
        const cts = existsSync(capture) ? readdirSync(capture).filter((x) => x.endsWith('.ct')) : [];
        return { code, log, cts };
      };
      // A trace left in the replay directory by an interrupted or superseded run is not a
      // recording of this one: the recorder converts an existing trace WITHOUT replaying, so
      // a stale one would be judged instead of the transaction. Only the modules are reused.
      rmSync(join(replayDir, 'trace.json'), { force: true });
      let { code, log, cts } = await runOnce('run.log');
      // A STATE READ THAT TIMED OUT IS A FACT ABOUT THE RUN, NEVER ABOUT THE CHAIN. The CLI's
      // REST client gives up on a request after a few seconds, and while the recording proxy
      // waits out the public node's rate limit it answers nothing — so the replay reads a
      // module or a resource as a storage error and fails, or diverges, for no reason the
      // chain has. Measured on version 7881330401: three record runs, three different
      // failures, every one of them this. Each retry starts from a transcript that holds
      // every read the last attempt completed, so it gets further, and the replay is only
      // judged once a run completes without one. In replay mode nothing waits, so this never
      // fires there.
      const TRANSIENT = /error sending request for url \(http:\/\/127\.0\.0\.1[^)]*\): (?:operation timed out|error sending request|connection closed)|Per anonymous IP rate limit exceeded/;
      for (let attempt = 1; code !== 0 && TRANSIENT.test(log) && attempt <= 8; attempt++) {
        console.error(`version ${version}: a state read timed out against the rate-limited `
          + `node (attempt ${attempt}); replaying again from the transcript so far`);
        rmSync(join(replayDir, 'trace.json'), { force: true });
        await new Promise((ok) => setTimeout(ok, 30_000));
        ({ code, log, cts } = await runOnce('run.log'));
      }
      if (code !== 0 && TRANSIENT.test(log)) {
        throw new Error(`version ${version}: state reads kept timing out; the replay was never `
          + 'judged. Rerun when the node\'s rate limit allows.');
      }
      let done;
      if (code === 0 && cts.length === 1) {
        done = { version, hash: tx.hash, outcome: 'traced', recorderCommit, recordingId };
      } else if (code !== 0 && log.includes(REPLAY_MISMATCH)
                 && existsSync(join(replayDir, 'trace.json'))) {
        // THE CLI WROTE ITS TRACE AND THEN REFUSED THE COMPARISON. The trace is a complete
        // recording of what the replay executed; the recorder converts an existing trace
        // without replaying, so a second run turns it into a container, published as
        // divergent with the fact the CLI named.
        const mismatch = log.split('\n').find((l) => l.includes(REPLAY_MISMATCH)).trim();
        ({ code, log, cts } = await runOnce('convert.log'));
        if (code !== 0 || cts.length !== 1) {
          throw new Error(`version ${version} diverged and its trace did not convert `
            + `(exit ${code}). Log tail:\n${log.slice(-1500)}`);
        }
        done = { version, hash: tx.hash, outcome: 'divergent', recorderCommit, recordingId,
                 mismatch: mismatch.slice(0, 2000) };
      } else if (code !== 0 && log.includes(TRACE_TOO_LARGE)) {
        done = { version, hash: tx.hash, outcome: 'too-large', recorderCommit,
                 refusal: TRACE_TOO_LARGE,
                 message: log.split('\n').find((l) => l.includes(TRACE_TOO_LARGE)) };
      } else if (code !== 0 && log.includes(NO_TRACE_EVENTS)) {
        done = { version, hash: tx.hash, outcome: 'no-trace-events', recorderCommit,
                 refusal: NO_TRACE_EVENTS,
                 message: log.split('\n').find((l) => l.includes(NO_TRACE_EVENTS)) };
      } else {
        throw new Error(`recording version ${version} failed (exit ${code}, ${cts.length} `
          + `container(s)); the run stops rather than publish around it. Log tail:\n`
          + `${log.slice(-1500)}`);
      }
      writeFileSync(donePath, `${JSON.stringify(done, null, 1)}\n`);
      // The producer reads the modules' disassembly, never the trace; the trace (up to
      // tens of MB for a swap) is removed once it is converted.
      rmSync(join(replayDir, 'trace.json'), { force: true });
      console.log(`${version}: ${done.outcome}`);
    }

    const produce = [join(HERE, 'produce-aptos-snapshot.mjs'),
      '--acquisition', acquisitionPath, '--replay-root', join(work, 'replay'),
      '--recorder-commit', recorderCommit, '--recorder-binary', resolve(recorder), '--out', out,
      ...(a.get('ct-print') ? ['--ct-print', a.get('ct-print')] : []),
      ...(a.get('positions-reader') ? ['--positions-reader', a.get('positions-reader')] : []),
      ...recDirs.flatMap((d) => ['--rec', d])];
    const code = await runLogged(process.execPath, produce, join(work, 'produce.log'), process.env);
    process.stdout.write(readFileSync(join(work, 'produce.log'), 'utf8'));
    if (code !== 0) process.exitCode = code;
    completed = code === 0 && !a.has('plan');
  } finally {
    await stop(completed);
  }
}

main(process.argv.slice(2)).catch((e) => {
  console.error(`capture-aptos-range.mjs: ${e.message}`);
  process.exit(1);
});
