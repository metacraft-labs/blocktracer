#!/usr/bin/env node
// eth-rpc-transcript.mjs — run a command against a JSON-RPC endpoint that is a FILE.
//
//   # record: proxy to a real endpoint and write down every answer
//   node tools/chain/eth-rpc-transcript.mjs --record \
//     --upstream https://eth.drpc.org --out fixtures/chain-inputs/<slug> \
//     -- some-command --rpc-url '{{RPC}}'
//
//   # replay: serve ONLY what the transcript holds; a miss is a failure
//   node tools/chain/eth-rpc-transcript.mjs --replay \
//     --transcript fixtures/chain-inputs/<slug> \
//     -- some-command --rpc-url '{{RPC}}'
//
//   # deny: refuse every call, to prove the command reads the endpoint at all
//   node tools/chain/eth-rpc-transcript.mjs --deny -- some-command --rpc-url '{{RPC}}'
//
//   # verify: hash every committed file against the manifest and report the ledger
//   node tools/chain/eth-rpc-transcript.mjs --verify --transcript <dir>
//
// `{{RPC}}` in any argument is replaced with the server's own `http://127.0.0.1:<port>`.
// The server binds a loopback port chosen by the kernel, so two runs never collide.
//
// ── EXIT STATUS, WHICH IS THE POINT ───────────────────────────────────────────────────
//
//   0  the child exited 0 AND (in replay mode) the transcript answered every call
//   1  the child exited non-zero, or an argument is wrong
//   3  REPLAY MISS: the child may have succeeded, but it asked for something the
//      committed input set does not hold. Distinct from 1 because it is a statement about
//      the INPUTS and not about the producer, and the two have different remedies: a 1 is
//      a bug to fix, a 3 is a re-record.
//
// Why the child is launched by this tool rather than pointed at a separately-started
// server: a transcript is only evidence if the conversation it holds is the whole
// conversation, and a server someone else started may have answered calls from a run
// nobody is looking at. One process owns the server, the child, and the verdict.

import { spawn } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { resolve } from 'node:path';

import {
  startTranscriptServer,
  writeTranscript,
  loadTranscript,
  callFilesOnDisk,
} from './lib/eth-rpc-transcript.mjs';

const argv = process.argv.slice(2);
const sep = argv.indexOf('--');
const ours = sep >= 0 ? argv.slice(0, sep) : argv;
const childArgv = sep >= 0 ? argv.slice(sep + 1) : [];

const has = (n) => ours.includes(`--${n}`);
const flag = (n, d) => {
  const i = ours.indexOf(`--${n}`);
  return i >= 0 ? ours[i + 1] : d;
};

const die = (message) => {
  process.stderr.write(`eth-rpc-transcript: ${message}\n`);
  process.exit(1);
};

const modes = ['record', 'replay', 'deny', 'verify'].filter(has);
if (modes.length !== 1) {
  die(`exactly one of --record / --replay / --deny / --verify is required (got ${modes.length})`);
}
const mode = modes[0];

// ---------------------------------------------------------------------------
// --verify: the ledger over the committed bytes, with no child at all
// ---------------------------------------------------------------------------
if (mode === 'verify') {
  const dir = resolve(flag('transcript') ?? die('--verify needs --transcript <dir>'));
  const { manifest } = loadTranscript(dir);
  const listed = new Set(manifest.calls.map((c) => c.file));
  const onDisk = callFilesOnDisk(dir);
  const stray = onDisk.filter((n) => !listed.has(n));
  if (stray.length) {
    process.stderr.write(
      `eth-rpc-transcript: ${stray.length} file(s) under ${dir}/calls are not in the `
      + `manifest: ${stray.join(', ')}. An unlisted input is an input nothing pins.\n`);
    process.exit(1);
  }
  const t = manifest.totals;
  process.stdout.write(
    `transcript OK ${dir}\n`
    + `  calls ${t.calls} (${t.immutable} immutable, ${t.tipDependent} tip-dependent, `
    + `${t.endpointIdentity} endpoint-identity)\n`
    + `  bytes ${t.bytes} across ${onDisk.length} file(s), every sha256 as the manifest says\n`);
  process.exit(0);
}

if (!childArgv.length) die(`--${mode} needs a command after \`--\``);

const outDir = flag('out');
const transcriptDir = flag('transcript');
if (mode === 'record' && !outDir) die('--record needs --out <dir>');
if (mode === 'replay' && !transcriptDir) die('--replay needs --transcript <dir>');

const upstream = flag('upstream', process.env.CODETRACER_EVM_RECORDER_RPC_URL);
if (mode === 'record' && !upstream) die('--record needs --upstream <url>');

const transcript = mode === 'replay' ? loadTranscript(resolve(transcriptDir)) : null;

const server = await startTranscriptServer({ mode, upstream, transcript });
process.stderr.write(`eth-rpc-transcript: ${mode} endpoint at ${server.url}\n`);

const substituted = childArgv.map((a) => a.replaceAll('{{RPC}}', server.url));
const child = spawn(substituted[0], substituted.slice(1), {
  stdio: 'inherit',
  env: { ...process.env, CODETRACER_EVM_RECORDER_RPC_URL: server.url },
});

const childRc = await new Promise((done) => {
  child.on('exit', (code, signal) => done(signal ? 128 + 1 : (code ?? 1)));
  child.on('error', (e) => {
    process.stderr.write(`eth-rpc-transcript: cannot spawn ${substituted[0]}: ${e}\n`);
    done(1);
  });
});

await server.close();

if (mode === 'record') {
  const dir = resolve(outDir);
  mkdirSync(dir, { recursive: true });
  const manifest = writeTranscript(dir, server.recorded, {
    upstream,
    recordedAt: new Date().toISOString(),
    recordedBy: 'tools/chain/eth-rpc-transcript.mjs',
    command: substituted.map((a) => a.replaceAll(server.url, '{{RPC}}')),
  });
  const t = manifest.totals;
  process.stderr.write(
    `eth-rpc-transcript: recorded ${t.calls} distinct call(s) from ${server.stats.forwarded} `
    + `request(s), ${t.bytes} bytes -> ${dir}\n`
    + `  ${t.immutable} immutable, ${t.tipDependent} tip-dependent, `
    + `${t.endpointIdentity} endpoint-identity\n`);
  process.exit(childRc);
}

if (mode === 'deny') {
  process.stderr.write(
    `eth-rpc-transcript: refused ${server.stats.denied} call(s); child exited ${childRc}\n`);
  process.exit(childRc);
}

// replay
const { served, misses } = server.stats;
process.stderr.write(
  `eth-rpc-transcript: served ${served} call(s) from the transcript, `
  + `${misses.length} miss(es); child exited ${childRc}\n`);
if (misses.length) {
  const shown = misses.slice(0, 20);
  for (const m of shown) {
    process.stderr.write(`  MISS ${m.method} ${JSON.stringify(m.params)}\n`);
  }
  if (misses.length > shown.length) {
    process.stderr.write(`  ... and ${misses.length - shown.length} more\n`);
  }
  process.exit(3);
}
process.exit(childRc);
