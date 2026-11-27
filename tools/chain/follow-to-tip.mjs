#!/usr/bin/env node
//
// follow-to-tip.mjs — AZTEC: turn "a named range is ingested and published" into
// "the chain is followed", by computing the next range from the coverage ledger
// and the node's own tip and handing it to `ingest-range.mjs`.
//
// ── WHY THIS DID NOT EXIST, WHICH IS NOT "NOBODY WROTE IT" ───────────────────
//
// Ethereum has this and Aztec does not, and the asymmetry is visible in the file
// names rather than in anybody's notes:
//
//   capture-eth-range.mjs  ->  eth-ingest-range.mjs  ->  follow-eth-chain.mjs
//   follow-chain.mjs           ingest-range.mjs           ** nothing **
//
// `follow-eth-chain.mjs`'s own header says what it is for: it captures at the
// tip and then calls `eth-ingest-range.mjs` to "file, union, ingest, publish".
// Aztec has both halves — `ingest-range.mjs` fetches, replays, files, unions,
// ingests and publishes ONE NAMED RANGE, and `follow-chain.mjs` watches the tip
// — and no caller that keeps asking for the next range. So Aztec's publish path
// is a thing an operator runs with two numbers in it, which is the shape a
// CONTINUOUS publisher cannot have.
//
// This file is that caller and nothing more. It reaches the node for two
// numbers, reads the ledger for one, does arithmetic, and execs
// `ingest-range.mjs`. Every flag it does not recognise is passed straight
// through, so `--replay`, `--runtime`, `--backend`, `--bucket`, `--rps` and the
// rest keep ONE definition — the one in `ingest-range.mjs`'s header — and this
// tool cannot drift from it by restating it.
//
// ── THE TWO REFUSALS THAT ARE THE WHOLE POINT ────────────────────────────────
//
// A tip-follower that is wrong is worse than no tip-follower, because it
// publishes. Both refusals below are about the SAME measured hazard, recorded in
// `tools/chain/retired-networks.json`: BOTH Aztec networks were restarted after
// this project captured them.
//
//   mainnet  captured head 102,690   live tip 3,403   (observed 2026-10-28)
//   testnet  captured head  99,092   live tip 9,405   (observed 2026-10-28)
//
//   1. TIP REGRESSION. The live tip being BELOW the ledger's highest covered
//      height is not "nothing to do" and must never be treated as caught up. It
//      means the endpoint is serving a DIFFERENT chain at heights this ledger
//      already claims, and the next range computed from `highest + 1` would file
//      a new rollup's blocks into a generation whose height map belongs to a
//      retired one. The site would then serve two chains under one slug, with a
//      pointer that agrees with the map and a map that is a lie. Nothing
//      downstream can detect that: every object is individually well-formed.
//
//   2. IDENTITY CHANGE. A restart does not have to lower the tip to be a
//      different chain, and once the new rollup climbs past the old head the
//      arithmetic above stops noticing. So the node's own
//      `node_getNodeInfo` identity (`l1ChainId`, `rollupVersion`) is recorded
//      beside the ledger on the first cycle and compared on every later one.
//      This is a SIDECAR (`chain-identity.json`) and deliberately not a new
//      field in `coverage.json`: that file's format is
//      `blocktracer/coverage-ledger@1` and `ingest-range.mjs` owns it, so
//      adding to it would make two tools' notions of the format disagree the
//      first time either changed.
//
// Neither refusal is recoverable by retrying, and both print what to do: a
// restarted chain needs a NEW state directory (and, if the slug is to be
// reused, the replacement of the published generation), not a follower that
// keeps going.
//
// ── A MISSING LEDGER IS ALSO A REFUSAL ───────────────────────────────────────
//
// `ingest-range.mjs` publishes the UNION of what its ledger holds. An absent
// ledger is therefore not an empty start, it is a FORGOTTEN one: the next cycle
// would ingest one range, derive a generation from it alone, and flip
// `current.json` to a map holding nothing else — the precise defect
// `eth-ingest-range.mjs`'s header measured ("a pointer that no longer lies about
// a map that has quietly dropped range A ... is worse than the first, because the
// detector that caught the first cannot see it"). On a continuous publisher that
// condition arrives by accident — a wiped state directory, a new host, a
// mistyped `--state` — so it is refused by default and `--allow-fresh-ledger`
// is how an operator says "this chain genuinely starts here".
//
// ── USAGE ────────────────────────────────────────────────────────────────────
//
//   node tools/chain/follow-to-tip.mjs --chain aztec-testnet --state DIR \
//     [--url URL] [--max-blocks N] [--below-finalized] [--allow-fresh-ledger] \
//     [--plan-only] [--json] [-- ...every ingest-range.mjs flag...]
//
//   --max-blocks N      the most heights one cycle may request (default 150).
//                       A cycle is BOUNDED so a follower that fell a day behind
//                       catches up over many short runs instead of one run that
//                       a timer kills in the middle of a publish.
//
//                       150 IS A MEASUREMENT AND THE FIRST VALUE HERE WAS WRONG.
//                       It was 50, chosen before anything measured the chains,
//                       and 50 is BELOW what mainnet produces between cycles — a
//                       follower capped there falls about ten blocks further
//                       behind every quarter hour, for ever, while every cycle
//                       exits 0 and publishes something. Taken from block
//                       timestamps 200 apart on 2026-11-23:
//
//                         aztec          15.1 s/block -> 60 blocks per 15 min
//                         aztec-testnet  22.7 s/block -> 40 blocks per 15 min
//
//                       So the cap has to clear 60, and the headroom above it is
//                       what lets a cycle that was skipped be made up by the
//                       next one rather than by an operator. The ceiling that
//                       bounds it is the REPLAYABLE WINDOW, measured the same
//                       day as `tip - finalized`: 194 blocks (~49 min) on
//                       mainnet and 83 (~31 min) on testnet. A cap far above
//                       that would ask for heights whose bodies have pruned, and
//                       a height with no body is a transaction published with no
//                       trace.
//   --below-finalized   follow `finalized` rather than the unproven tip. OFF by
//                       default, because the replayable window is
//                       `finalized+1 .. tip` (`follow-chain.mjs`'s header: ~25
//                       blocks, ~30 minutes) — a follower that waits for
//                       finality can never replay a body and so can never
//                       publish a trace, which is the whole product.
//   --plan-only         print the range and exit without running anything.

import { existsSync, readFileSync, writeFileSync, renameSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

// Exit codes, named so the systemd unit and the selftest agree on them.
export { CHAIN_ENDPOINTS };
export const EXIT_OK = 0;
export const EXIT_REFUSED = 1;
export const EXIT_USAGE = 2;
// 75 is EX_TEMPFAIL. "Caught up" is the steady state of a healthy follower, and
// a timer firing into it must not colour the unit red nor read as success that
// published something. The infra unit lists it in `SuccessExitStatus`.
export const EXIT_CAUGHT_UP = 75;

/**
 * The endpoint each slug is followed from — a TABLE, not a rule.
 *
 * This derived the URL from the slug (`https://${chain}.drpc.org`), which works
 * only while every slug happens to be a drpc hostname. It stopped being true the
 * moment the live rollups needed slugs of their own: both Aztec networks
 * restarted, and the corpora published under `aztec` and `aztec-testnet` belong
 * to the retired ones, so the live chains are published beside them rather than
 * over them. `https://aztec-testnet-v6.drpc.org` is not a host.
 *
 * A WRONG URL IS NOT A LOUD FAILURE HERE, which is why this refuses instead of
 * guessing: a slug that resolves to some other chain's endpoint produces a
 * perfectly well-formed ledger, snapshot and generation describing the WRONG
 * chain under this name, and nothing downstream can tell. `--url` always wins,
 * so an operator can follow anything; it is only the DEFAULT that is a table.
 */
const CHAIN_ENDPOINTS = {
  // The live rollups, which is what a follower follows.
  'aztec-v6': 'https://aztec.drpc.org',
  'aztec-testnet-v6': 'https://aztec-testnet.drpc.org',
  // The retired slugs keep their mapping so an operator can still point a tool
  // at them deliberately. `tools/chain/retired-networks.json` records that the
  // networks behind them are gone, so a follower aimed here will be refused by
  // the tip-regression check rather than by this table — which is the right
  // refusal, because it is about the data and not about a hostname.
  'aztec': 'https://aztec.drpc.org',
  'aztec-testnet': 'https://aztec-testnet.drpc.org',
};

export function parseArgs(argv) {
  // Everything after a bare `--` is ingest-range.mjs's, verbatim and unparsed.
  const sep = argv.indexOf('--');
  const mine = sep === -1 ? argv.slice() : argv.slice(0, sep);
  const passthrough = sep === -1 ? [] : argv.slice(sep + 1);
  const arg = (n, d) => {
    const i = mine.indexOf(`--${n}`);
    return i === -1 ? d : mine[i + 1];
  };
  const flag = (n) => mine.includes(`--${n}`);
  const chain = arg('chain', '');
  return {
    chain,
    url: arg('url', '') || CHAIN_ENDPOINTS[chain] || '',
    stateDir: arg('state', ''),
    // See the header: 150 clears mainnet's measured 60 blocks per 15-minute
    // cycle with headroom, and stays well inside the 83-block testnet
    // replayable window that bounds it from above.
    maxBlocks: Number(arg('max-blocks', '150')),
    belowFinalized: flag('below-finalized'),
    allowFreshLedger: flag('allow-fresh-ledger'),
    planOnly: flag('plan-only'),
    jsonOnly: flag('json'),
    passthrough,
  };
}

/**
 * The highest height the ledger says is covered, or null for an empty ledger.
 *
 * READ FROM THE RANGE KEYS AND NOT FROM A STORED HIGH-WATER MARK, because a
 * mark is a second place the same fact lives. The keys are `<from>-<to>` zero
 * padded to the ledger's own `keyPadding`, so they are parsed rather than
 * sorted as strings — that padding exists precisely because string order is
 * wrong across a digit boundary, and a reader that re-derives the order from
 * numbers cannot inherit the bug the padding was added to fix.
 */
export function highestCovered(ledger) {
  let hi = null;
  for (const key of Object.keys(ledger?.ranges ?? {})) {
    const m = /^(\d+)-(\d+)$/.exec(key);
    if (!m) continue;
    const to = Number(m[2]);
    if (!Number.isFinite(to)) continue;
    if (hi === null || to > hi) hi = to;
  }
  return hi;
}

/**
 * The next range to request, or a reason there is none.
 *
 * Pure, and separated from every side effect so the selftest can drive the
 * arithmetic over made-up numbers with no node, no ledger and no child process.
 */
export function planRange({ highest, head, maxBlocks }) {
  if (!Number.isFinite(maxBlocks) || maxBlocks < 1) {
    return { kind: 'usage', message: `--max-blocks must be a positive integer, got [${maxBlocks}]` };
  }
  if (!Number.isFinite(head) || head < 0) {
    return { kind: 'usage', message: `the node returned no usable head height, got [${head}]` };
  }
  if (highest !== null && head < highest) {
    return {
      kind: 'refused',
      reason: 'tip-regression',
      message:
        `the endpoint's head is ${head} and this ledger's highest covered height is `
        + `${highest}. A head BELOW what is already covered is not "nothing to do": it `
        + `means this endpoint is serving a different chain at heights this ledger has `
        + `already published, which is what tools/chain/retired-networks.json records for `
        + `both Aztec networks. Filing ${highest + 1}.. from here would put a new rollup's `
        + `blocks into a generation whose height map belongs to the old one. A restarted `
        + `chain needs a NEW --state directory, and a reused slug needs its published `
        + `generation replaced.`,
    };
  }
  const from = highest === null ? 1 : highest + 1;
  if (from > head) {
    return { kind: 'caught-up', from, head, highest };
  }
  return { kind: 'range', from, to: Math.min(head, from + maxBlocks - 1), head, highest };
}

/**
 * Compare the node's identity against the one this state directory was started
 * on. `null` recorded identity means "first cycle": record and proceed.
 */
export function checkIdentity(recorded, observed) {
  if (!recorded) return { ok: true, record: observed };
  const differs = (k) =>
    recorded[k] !== undefined && observed[k] !== undefined && String(recorded[k]) !== String(observed[k]);
  const changed = ['l1ChainId', 'rollupVersion'].filter(differs);
  if (changed.length === 0) return { ok: true, record: null };
  return {
    ok: false,
    reason: 'identity-change',
    message:
      `the endpoint's chain identity changed on ${changed.join(' and ')}: this state `
      + `directory was started against ${JSON.stringify(recorded)} and the node now reports `
      + `${JSON.stringify(observed)}. The published generation's height map belongs to the `
      + `FIRST of those, so continuing would file a second chain's blocks under one slug. `
      + `A restarted chain needs a NEW --state directory.`,
  };
}

async function rpc(url, method, params = []) {
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
  });
  if (!r.ok) throw new Error(`${method}: HTTP ${r.status}`);
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message ?? JSON.stringify(j.error)}`);
  return j.result;
}

async function main() {
  const o = parseArgs(process.argv.slice(2));
  const say = (m) => { if (!o.jsonOnly) console.error(`follow-to-tip: ${m}`); };
  const out = (obj) => console.log(JSON.stringify(obj, null, 1));

  if (!o.chain || !o.stateDir) {
    console.error('usage: --chain SLUG --state DIR [--url U] [--max-blocks N] '
      + '[--below-finalized] [--allow-fresh-ledger] [--plan-only] [--json] [-- …]');
    process.exit(EXIT_USAGE);
  }
  if (!o.url) {
    console.error(`follow-to-tip: refusing: no endpoint for chain '${o.chain}' and no --url.\n`
      + `  Known slugs: ${Object.keys(CHAIN_ENDPOINTS).join(', ')}.\n`
      + '  This used to derive the host from the slug, which silently produces a ledger,\n'
      + '  a snapshot and a generation describing the WRONG chain under this name when the\n'
      + '  guess happens to resolve. Pass --url to follow a chain this table does not know.');
    process.exit(EXIT_USAGE);
  }

  const ledgerPath = join(o.stateDir, 'coverage.json');
  const identityPath = join(o.stateDir, 'chain-identity.json');

  let ledger = null;
  if (existsSync(ledgerPath)) {
    ledger = JSON.parse(readFileSync(ledgerPath, 'utf8'));
  } else if (!o.allowFreshLedger) {
    say(`refusing: ${ledgerPath} does not exist.\n`
      + `  ingest-range.mjs publishes the UNION of what this ledger holds, so an absent\n`
      + `  ledger is a FORGOTTEN one and not an empty start: the next cycle would derive a\n`
      + `  generation from one range and flip current.json to a map holding nothing else.\n`
      + `  Pass --allow-fresh-ledger if this chain genuinely starts here.`);
    process.exit(EXIT_REFUSED);
  }

  const highest = highestCovered(ledger);

  let info, tip, finalized;
  try {
    info = await rpc(o.url, 'node_getNodeInfo');
    tip = Number(await rpc(o.url, 'node_getBlockNumber'));
    finalized = Number(await rpc(o.url, 'node_getBlockNumber', ['finalized']));
  } catch (e) {
    say(`the endpoint ${o.url} could not be read: ${e.message}. `
      + `That is the node being unreachable, not a chain with no new blocks, so nothing `
      + `is filed and nothing is published.`);
    process.exit(EXIT_REFUSED);
  }

  const observed = {
    l1ChainId: info?.l1ChainId ?? null,
    rollupVersion: info?.rollupVersion ?? null,
    nodeVersion: info?.nodeVersion ?? null,
  };
  const recorded = existsSync(identityPath)
    ? JSON.parse(readFileSync(identityPath, 'utf8')).observed ?? null
    : null;
  const idc = checkIdentity(recorded, observed);
  if (!idc.ok) {
    say(`refusing (${idc.reason}): ${idc.message}`);
    process.exit(EXIT_REFUSED);
  }

  const head = o.belowFinalized ? finalized : tip;
  const plan = planRange({ highest, head, maxBlocks: o.maxBlocks });

  if (plan.kind === 'usage') { say(plan.message); process.exit(EXIT_USAGE); }
  if (plan.kind === 'refused') { say(`refusing (${plan.reason}): ${plan.message}`); process.exit(EXIT_REFUSED); }
  if (plan.kind === 'caught-up') {
    if (o.jsonOnly) out({ tool: 'follow-to-tip', chain: o.chain, caughtUp: true, head, highest, tip, finalized });
    else say(`caught up: highest covered ${highest}, head ${head} (tip ${tip}, finalized ${finalized}).`);
    process.exit(EXIT_CAUGHT_UP);
  }

  // Record the identity only once there is a range to run, so a refused cycle
  // never leaves behind the very baseline it would have been compared against.
  if (idc.record) {
    mkdirSync(o.stateDir, { recursive: true });
    const tmp = `${identityPath}.tmp`;
    writeFileSync(tmp, JSON.stringify({
      _comment: 'Written by tools/chain/follow-to-tip.mjs on the first cycle of this state '
        + 'directory. A later cycle whose node reports a different l1ChainId or rollupVersion '
        + 'is REFUSED: a restarted chain needs a new state directory, because the published '
        + 'generation it would extend belongs to the chain recorded here.',
      chain: o.chain, endpoint: o.url, firstSeenAt: new Date().toISOString(), observed,
    }, null, 1) + '\n');
    renameSync(tmp, identityPath);
  }

  const argv = [
    join(HERE, 'ingest-range.mjs'),
    '--from', String(plan.from), '--to', String(plan.to),
    '--chain', o.chain, '--url', o.url, '--state', o.stateDir,
    ...o.passthrough,
  ];

  if (o.planOnly) {
    out({ tool: 'follow-to-tip', chain: o.chain, plan, tip, finalized, identity: observed,
          would: ['node', ...argv] });
    process.exit(EXIT_OK);
  }

  say(`range ${plan.from}-${plan.to} (head ${head}, tip ${tip}, finalized ${finalized})`);
  const r = spawnSync(process.execPath, argv, { stdio: 'inherit' });
  process.exit(r.status ?? EXIT_REFUSED);
}

// Importable for the selftest without running anything.
if (process.argv[1] && process.argv[1].endsWith('follow-to-tip.mjs')) {
  await main();
}
