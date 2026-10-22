#!/usr/bin/env node
// sol-capture.mjs — A SOLANA SNAPSHOT TREE FROM COMMITTED INPUTS, WITH NO NETWORK.
//
//   node tools/chain/sol-capture.mjs --recorder <codetracer-solana-recorder> \
//     --recorder-commit <rev> --fixture fixtures/chain-inputs/solana-mainnet/<window> \
//     --ct-print <ct-print> --out <tree> --work <scratch>
//
// What tools/chain/nix/sol.nix runs in the sandbox. The live capture that produced the
// fixture cannot be repeated (it read account states the RPC no longer serves), so the
// build does the part that CAN be repeated: every traced transaction is replayed again from
// its committed bundle through the real runtime, and the container that replay writes is
// the one the tree publishes. Nothing is copied from the capture except its enumeration
// and its verdict lines.
//
// THE REPLAY MUST AGREE WITH THE CAPTURE. Each re-run's divergence verdict is compared with
// the one the live capture recorded for the same transaction, and any difference fails the
// build: a sandbox replay that disagrees with the live one means the bundle, the runtime
// pin or the recorder changed what executed, and publishing its container would publish a
// different execution under the live verdict's name.

import { execFile } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);
const argv = process.argv.slice(2);
const flag = (n) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : undefined; };
const die = (m) => { console.error(`sol-capture: ${m}`); process.exit(1); };

const recorder = flag('recorder');
const recorderCommit = flag('recorder-commit');
const fixture = flag('fixture');
const ctPrint = flag('ct-print') ?? process.env.CT_PRINT;
const out = flag('out');
const work = resolve(flag('work') ?? 'sol-capture-work');
if (!recorder || !recorderCommit || !fixture || !ctPrint || !out) {
  die('--recorder, --recorder-commit, --fixture, --ct-print and --out are required');
}

const here = (p) => resolve(new URL('.', import.meta.url).pathname, p);
rmSync(work, { recursive: true, force: true });
const capture = join(work, 'capture');
await run(process.execPath, [here('sol-fixture.mjs'), 'unpack', '--fixture', fixture, '--out', capture]);

const recorded = new Map(readFileSync(join(capture, 'results.jsonl'), 'utf8').split('\n')
  .filter((l) => l.trim()).map((l) => JSON.parse(l)).map((r) => [r.signature, r]));

const bundles = readdirSync(join(capture, 'bundles')).filter((f) => f.endsWith('.json')).sort();
let agreed = 0;
for (const f of bundles) {
  const sig = f.replace(/\.json$/, '');
  const dir = join(work, 'replay', sig);
  try {
    await run(recorder, ['replay-bundle', '--bundle', join(capture, 'bundles', f), '--out-dir', dir],
      { maxBuffer: 1 << 26 });
  } catch (e) {
    // replay-bundle exits 2 on a divergent verdict; that is compared below like any other.
    if (e.code !== 2) die(`${sig}: the recorder failed: ${String(e.stderr ?? e.message).slice(0, 400)}`);
  }
  const line = JSON.parse(readFileSync(join(dir, 'verdicts.jsonl'), 'utf8').split('\n')[0]);
  const live = recorded.get(sig);
  if (!live) die(`${sig}: a bundle with no verdict line in the capture`);
  const was = live.executed ? live.verdict.status : 'not-executed';
  const now = line.executed ? line.verdict.status : 'not-executed';
  if (was !== now) die(`${sig}: the live capture recorded \`${was}\`, the sandbox replay \`${now}\``);
  const traceDir = join(dir, 'traces', sig);
  if (!existsSync(join(traceDir, `${sig}.ct`))) die(`${sig}: the replay wrote no container`);
  mkdirSync(join(capture, 'traces'), { recursive: true });
  cpSync(traceDir, join(capture, 'traces', sig), { recursive: true });
  agreed++;
}
console.error(`sol-capture: ${agreed} of ${bundles.length} bundle(s) replayed to the verdict the live capture recorded`);

// --from/--to narrow the PUBLISHED window. Every committed bundle is still replayed and
// checked above; only the tree's enumeration is narrowed, because every enumerated
// transaction costs published objects (see sol.nix).
const windowFlags = [...(flag('from') ? ['--from', flag('from')] : []), ...(flag('to') ? ['--to', flag('to')] : [])];
await run(process.execPath, [here('produce-sol-snapshot.mjs'), '--capture', capture,
  '--recorder-commit', recorderCommit, '--ct-print', ctPrint, '--out', resolve(out), ...windowFlags],
  { maxBuffer: 1 << 26 }).then(({ stderr }) => process.stderr.write(stderr));
