#!/usr/bin/env node
//
// flow-era-probe.mjs — where, inside a Flow spork, the replay stops reproducing the chain.
//
//   node tools/chain/flow-era-probe.mjs --helper <cadence-replay-helper> \
//     --from <height> [--to <height>] [--out <file>] [--rest <url>]
//
// Recorder-Flow CXP-FLOW-1 asks for the Cadence language-version boundaries over the
// covered range to be enumerated and each tested for replayability, so that an era edge is
// found by probing rather than by a support ticket. The replay runs ONE FVM (the helper's
// flow-go, and the Cadence it pins) over every height, while the chain ran whatever the
// network had upgraded to. Two kinds of edge can change what the replay reproduces, and
// this finds both from the chain itself:
//
// * VERSION BOUNDARIES. The service account's `NodeVersionBeacon` contract holds every
//   height at which the network's node software changed. Each flow-go release pins one
//   Cadence release, so these are the language-version boundaries too.
// * SYSTEM CONTRACT UPDATES. Every user transaction runs the fee contracts. A contract the
//   chain accepted can be one the replay's newer Cadence refuses to check, and then every
//   transaction while it was deployed is unreplayable. Each contract's code hash is read
//   by script at the range's ends and at every version boundary, and each change between
//   two readings is bisected to the block that made it. A change undone within one interval
//   is not seen.
//
// At each edge the nearest executed user transaction below it, and the nearest whose
// block's prestate is past it, are replayed — the immediate pair, which is what attributes
// a difference to the edge. Replays run one at a time and a run that fails
// for any reason but a checking failure is retried, because the access node refuses bursts
// and a refused read is not an era. Network: the access node's REST and gRPC APIs.

import { execFile } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';

const run = promisify(execFile);
const argv = process.argv.slice(2);
const flag = (name, dflt) => {
  const i = argv.indexOf(`--${name}`);
  return i >= 0 ? argv[i + 1] : dflt;
};
const helper = flag('helper');
const rest = flag('rest', 'https://rest-mainnet.onflow.org');
const out = flag('out');
if (!helper || !flag('from')) {
  console.error('flow-era-probe: --helper <cadence-replay-helper> and --from <height> are required');
  process.exit(2);
}

// The contracts every user transaction executes: fee checks and deduction, the token the
// fee is paid in, and storage capacity.
const SYSTEM_CONTRACTS = [
  ['f919ee77447b7497', 'FlowFees'],
  ['1654653399040a61', 'FlowToken'],
  ['f233dcee88fe0abe', 'FungibleToken'],
  ['e467b9dd11fa00df', 'FlowStorageFees'],
  ['e467b9dd11fa00df', 'FlowServiceAccount'],
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const script = async (code, height) => {
  for (let attempt = 0; ; attempt += 1) {
    const res = await fetch(`${rest}/v1/scripts?block_height=${height}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ script: Buffer.from(code).toString('base64'), arguments: [] }),
    });
    const body = await res.text();
    if (res.ok) return JSON.parse(Buffer.from(JSON.parse(body), 'base64').toString());
    if (attempt === 4) throw new Error(`script at ${height}: ${res.status} ${body.slice(0, 300)}`);
    await sleep(1000 * (attempt + 1));
  }
};
const sealed = async () => {
  const res = await fetch(`${rest}/v1/blocks?height=sealed`);
  return Number((await res.json())[0].header.height);
};

const from = Number(flag('from'));
const to = Number(flag('to', await sealed()));

// ── the version boundaries ────────────────────────────────────────────────────────────
const beacon = await script(`import NodeVersionBeacon from 0xe467b9dd11fa00df
access(all) fun main(): [[String]] {
  let out: [[String]] = []
  let page = NodeVersionBeacon.getVersionBoundariesPage(page: 0, perPage: 1000)
  for b in page.values { out.append([b.blockHeight.toString(), b.version.toString()]) }
  return out
}`, to);
const allBoundaries = beacon.value.map((p) => ({ height: Number(p.value[0].value),
                                                 version: p.value[1].value }));
const inForceAtFrom = allBoundaries.filter((b) => b.height <= from).at(-1);
const boundaries = allBoundaries.filter((b) => b.height > from && b.height <= to);

// ── the system contracts' code changes ────────────────────────────────────────────────
const codeHash = async ([address, name], height) => (await script(
  `access(all) fun main(): String { return String.encodeHex(HashAlgorithm.SHA3_256.hash(`
  + `getAccount(0x${address}).contracts.get(name: "${name}")!.code)) }`, height)).value;
const anchors = [...new Set([from, ...boundaries.map((b) => b.height), to])].sort((a, b) => a - b);
const contractChanges = [];
for (const c of SYSTEM_CONTRACTS) {
  let prev = { height: anchors[0], hash: await codeHash(c, anchors[0]) };
  for (const h of anchors.slice(1)) {
    const cur = { height: h, hash: await codeHash(c, h) };
    if (cur.hash !== prev.hash) {
      // A script at height h reads the state at the END of block h, so the bisection
      // finds the block whose execution installed the new code.
      let lo = prev.height;
      let hi = cur.height;
      while (hi - lo > 1) {
        const mid = Math.floor((lo + hi) / 2);
        if ((await codeHash(c, mid)) === prev.hash) lo = mid; else hi = mid;
      }
      contractChanges.push({ contract: `A.${c[0]}.${c[1]}`, updatedInBlock: hi,
                             before: prev.hash, after: await codeHash(c, hi) });
    }
    prev = cur;
  }
}

// ── the immediate pair at every edge ──────────────────────────────────────────────────
// The user transactions nearest an edge on one side, nearest first.
async function* userTxs(start, step) {
  for (let h = start, n = 0; n < 200; h += step, n += 1) {
    const { stdout } = await run(helper, ['block', '--height', String(h)], { maxBuffer: 1 << 24 });
    const txs = JSON.parse(stdout).transactions.filter((x) => !x.system);
    for (const t of step > 0 ? txs : txs.reverse()) yield { height: h, tx: t.id };
  }
  throw new Error(`no user transaction within 200 blocks of ${start}`);
}
const replay = async (tx) => {
  for (let attempt = 1; ; attempt += 1) {
    const dir = mkdtempSync(join(tmpdir(), 'flow-era-probe-'));
    try {
      await run(helper, ['-tx-id', tx, '-source-dir', join(dir, 's'),
                         '-verdict-out', join(dir, 'v.json')], { maxBuffer: 1 << 28 });
      const v = JSON.parse(readFileSync(join(dir, 'v.json'), 'utf8'));
      return {
        attempts: attempt,
        reproduced: v.reproduced === true,
        statusMatched: v.statusMatched,
        events: `${v.eventsMatched}/${v.eventsCompared}`,
        computation: { chain: v.onChain.computationUsed, replay: v.replay.computationUsed },
        firstDifference: v.firstEventDiff ?? null,
      };
    } catch (e) {
      const text = String(e.stderr ?? e.message);
      if (/Checking failed/.test(text)) {
        const why = /error: (access denied[^\n]*|[^\n]*)\n\s*--> ([0-9a-f]{16}\.\w+:\d+:\d+)/.exec(text);
        return { attempts: attempt, reproduced: false, unreplayable: 'checking-failed',
                 error: why ? `${why[1]} (${why[2]})` : text.split('\n')[0] };
      }
      if (attempt === 3) {
        return { attempts: attempt, reproduced: false, unreplayable: 'helper-failed',
                 error: text.split('\n').filter((l) => !l.startsWith('{'))[0] ?? '' };
      }
      await sleep(5000 * attempt);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
};

const edges = [
  ...boundaries.map((b) => ({ kind: 'version-boundary', height: b.height,
                              what: `node version ${b.version}` })),
  ...contractChanges.map((c) => ({ kind: 'contract-update', height: c.updatedInBlock + 1,
                                   what: `${c.contract} ${c.before.slice(0, 12)} -> `
                                     + `${c.after.slice(0, 12)}, updated in block `
                                     + `${c.updatedInBlock}` })),
].sort((a, b) => a.height - b.height);
// A transaction the chain refused before executing it (computation 0: a payer who could
// not pay, a malformed script) runs no Cadence, so it reproduces under any runtime and says
// nothing about the edge. It is skipped for the next one on the same side, and counted.
const MAX_SKIPPED = 5;
for (const e of edges) {
  for (const [side, start, step] of [['below', e.height - 1, -1], ['above', e.height, 1]]) {
    let skipped = 0;
    for await (const at of userTxs(start, step)) {
      const r = await replay(at.tx);
      if (r.computation?.chain === 0 && r.statusMatched && skipped < MAX_SKIPPED) {
        skipped += 1;
        continue;
      }
      e[side] = { ...at, ...r, skippedUnexecuted: skipped };
      break;
    }
    const at = e[side];
    console.error(`  ${e.height} ${e.kind} ${side}: ${at.height} ${at.tx.slice(0, 12)} `
                  + `${e[side].reproduced ? 'reproduced' : e[side].unreplayable ?? 'divergent'}`);
  }
}

const reading = {
  format: 'blocktracer/flow-era-probe@1',
  measuredAt: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
  endpoint: rest,
  // The package and revision, not the machine's path to it.
  helper: helper.startsWith('/nix/store/')
    ? helper.split('/')[3].replace(/^[a-z0-9]{32}-/, '') : helper.split('/').at(-1),
  range: { from, to },
  versionInForceAtFrom: inForceAtFrom ?? null,
  versionBoundaries: boundaries,
  contractChanges,
  edges,
};
const text = `${JSON.stringify(reading, null, 2)}\n`;
if (out) writeFileSync(out, text); else process.stdout.write(text);
