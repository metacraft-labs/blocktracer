#!/usr/bin/env node
//
// flow-floor-census.mjs — the deepest Flow mainnet height any public access node serves.
//
//   node tools/chain/flow-floor-census.mjs --helper <cadence-replay-helper> [--out <file>]
//
// Recorder-Flow CXP-FLOW-1 keeps the chain's floor apart from one node's retention. A
// Flow access node serves state only for its own spork, from that spork's root, so
// `probe-floor` against the current node measures its RETENTION. The chain's floor is the
// lowest root among every spork whose node still answers. This reads the network's own
// list of sporks (onflow/flow `sporks.json`), resolves each mainnet spork's access node,
// and probes the floor of each one that resolves. A spork whose node does not resolve is
// recorded with the answer, so the floor is a statement about which nodes exist today
// and not a guess about which ones should.

import { execFile } from 'node:child_process';
import { resolve4 } from 'node:dns/promises';
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
const out = flag('out');
const SPORKS = flag('sporks',
  'https://raw.githubusercontent.com/onflow/flow/master/sporks.json');
if (!helper) {
  console.error('flow-floor-census: --helper <cadence-replay-helper> is required');
  process.exit(2);
}

const sporks = (await (await fetch(SPORKS)).json()).networks.mainnet;
const rows = [];
for (const [name, s] of Object.entries(sporks)) {
  const node = (s.accessNodes ?? [])[0] ?? null;
  const row = { spork: name, rootHeight: Number(s.rootHeight), live: s.live === true, node };
  if (node) {
    const host = node.split(':')[0];
    try {
      row.resolves = (await resolve4(host)).length > 0;
    } catch (e) {
      row.resolves = false;
      row.dns = e.code;
    }
  }
  if (row.resolves) {
    const dir = mkdtempSync(join(tmpdir(), 'flow-floor-census-'));
    try {
      await run(helper, ['probe-floor', '--access-node', node, '--out', join(dir, 'p.json')],
                { timeout: 600000 });
      const p = JSON.parse(readFileSync(join(dir, 'p.json'), 'utf8'));
      row.probe = { verdict: p.verdict, floor: p.floor, sealedTip: p.sealedTip,
                    nodeVersion: p.nodeVersion, measuredAt: p.measuredAt };
    } catch (e) {
      row.probe = { error: String(e.stderr ?? e.message).split('\n')[0] };
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  }
  rows.push(row);
  console.error(`  ${name} root ${row.rootHeight} ${node ?? '(no node)'} `
                + `${row.resolves ? (row.probe.floor ?? row.probe.error) : row.dns ?? 'unresolved'}`);
}

const floors = rows.filter((r) => Number.isInteger(r.probe?.floor));
const reading = {
  format: 'blocktracer/flow-floor-census@1',
  measuredAt: new Date().toISOString().replace(/\.\d+Z$/, 'Z'),
  sporksList: SPORKS,
  helper: helper.startsWith('/nix/store/')
    ? helper.split('/')[3].replace(/^[a-z0-9]{32}-/, '') : helper.split('/').at(-1),
  // The chain's floor: the lowest height any reachable node serves state at.
  chainFloor: floors.length ? Math.min(...floors.map((r) => r.probe.floor)) : null,
  // The current spork's node: the retention a capture against it is bounded by.
  liveRetention: rows.find((r) => r.live)?.probe?.floor ?? null,
  sporks: rows,
};
const text = `${JSON.stringify(reading, null, 2)}\n`;
if (out) writeFileSync(out, text); else process.stdout.write(text);
