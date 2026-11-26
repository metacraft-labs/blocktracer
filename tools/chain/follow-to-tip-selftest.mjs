#!/usr/bin/env node
//
// follow-to-tip-selftest.mjs — the refusals of `follow-to-tip.mjs`, offline.
//
// WHAT IS WORTH TESTING HERE IS THE REFUSALS, for the same reason
// `snapshot-from-ingest-selftest.mjs` gives: the happy path is arithmetic, and
// `ingest-range.mjs` validates everything it is handed immediately afterwards.
// The refusals are the opposite — a follower that computes the WRONG next range
// publishes a well-formed generation that is a lie about which chain it holds,
// and nothing downstream can catch it.
//
// Every arm is pure: no node, no ledger on disk, no child process. The two
// functions under test (`planRange`, `checkIdentity`) were separated from the
// side effects for exactly that reason, and `highestCovered` is driven over
// made-up ledgers.
//
// GREEN-PATH ARMS COME FIRST AND ARE UNCONDITIONAL, so a tool that refused
// everything could not pass them all — the shape
// `snapshot-from-ingest-selftest.mjs`'s header had to be corrected into.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { planRange, checkIdentity, highestCovered, CHAIN_ENDPOINTS, EXIT_CAUGHT_UP }
  from './follow-to-tip.mjs';

const here = dirname(fileURLToPath(import.meta.url));

// Reconciled against the arms actually run, not maintained by hand: a short
// tally is a finding, and editing the expected number to match a short run is
// how a suite goes quiet.
const BASE_ARMS = 34;

let ran = 0, failed = 0;
const ok = (name, cond, detail = '') => {
  ran += 1;
  if (cond) { console.log(`  ok   ${name}`); return; }
  failed += 1;
  console.log(`  FAIL ${name}${detail ? `\n       ${detail}` : ''}`);
};

console.log('follow-to-tip-selftest');

// ── green path: the arithmetic a healthy follower does ──────────────────────
{
  const p = planRange({ highest: 100, head: 160, maxBlocks: 50 });
  ok('a covered ledger asks for the next window',
    p.kind === 'range' && p.from === 101 && p.to === 150, JSON.stringify(p));
}
{
  const p = planRange({ highest: 100, head: 120, maxBlocks: 50 });
  ok('a window shorter than --max-blocks stops at the head',
    p.kind === 'range' && p.from === 101 && p.to === 120, JSON.stringify(p));
}
{
  const p = planRange({ highest: null, head: 10, maxBlocks: 50 });
  ok('an empty ledger starts at height 1',
    p.kind === 'range' && p.from === 1 && p.to === 10, JSON.stringify(p));
}
{
  const p = planRange({ highest: 100, head: 100, maxBlocks: 50 });
  ok('head equal to the highest covered is caught up',
    p.kind === 'caught-up', JSON.stringify(p));
}
{
  // The one height that `!from` got wrong in ingest-range.mjs, kept as an arm
  // here so this tool cannot reintroduce it: head 0 with an empty ledger is a
  // chain with a genesis block and nothing else, not a usage error.
  const p = planRange({ highest: null, head: 0, maxBlocks: 50 });
  ok('head 0 on an empty ledger is caught up, not a usage error',
    p.kind === 'caught-up', JSON.stringify(p));
}
{
  const p = planRange({ highest: 1, head: 1_000_000, maxBlocks: 1 });
  ok('--max-blocks 1 asks for exactly one height',
    p.kind === 'range' && p.from === 2 && p.to === 2, JSON.stringify(p));
}

// ── the refusals ────────────────────────────────────────────────────────────
{
  // THE MEASURED HAZARD: mainnet captured head 102,690 against live tip 3,403.
  const p = planRange({ highest: 102_690, head: 3_403, maxBlocks: 50 });
  ok('a head below the highest covered is REFUSED as tip-regression',
    p.kind === 'refused' && p.reason === 'tip-regression', JSON.stringify(p));
  ok('the tip-regression message names both heights',
    p.kind === 'refused' && /102691\.\./.test(p.message) && p.message.includes('3403')
      && p.message.includes('102690'),
    p.message);
  ok('the tip-regression message says what to do about it',
    p.kind === 'refused' && /NEW --state directory/.test(p.message), p.message);
}
{
  const p = planRange({ highest: 100, head: 99, maxBlocks: 50 });
  ok('a head one below the highest covered is refused, not treated as caught up',
    p.kind === 'refused' && p.reason === 'tip-regression', JSON.stringify(p));
}
{
  const p = planRange({ highest: 100, head: 160, maxBlocks: 0 });
  ok('--max-blocks 0 is a usage error', p.kind === 'usage', JSON.stringify(p));
}
{
  const p = planRange({ highest: 100, head: Number.NaN, maxBlocks: 50 });
  ok('an unreadable head is a usage error rather than a range from NaN',
    p.kind === 'usage', JSON.stringify(p));
}

// ── identity ────────────────────────────────────────────────────────────────
{
  const c = checkIdentity(null, { l1ChainId: 11155111, rollupVersion: 679261766 });
  ok('a first cycle records the identity and proceeds',
    c.ok === true && c.record && c.record.l1ChainId === 11155111, JSON.stringify(c));
}
{
  const same = { l1ChainId: 11155111, rollupVersion: 679261766 };
  const c = checkIdentity(same, { ...same, nodeVersion: '6.0.1' });
  ok('an unchanged identity proceeds and rewrites nothing',
    c.ok === true && c.record === null, JSON.stringify(c));
}
{
  // The testnet restart, as it was measured on 2026-10-28: the node moved to
  // nodeVersion 6.0.0 / rollupVersion 679261766 under the SAME slug. The
  // attribution used to name `retired-networks.json`, which no longer carries
  // the entry — the live deployment is in `chain-identity.json` and the slug
  // reuse is why; the measurement itself is unchanged.
  const c = checkIdentity({ l1ChainId: 11155111, rollupVersion: 1 },
                          { l1ChainId: 11155111, rollupVersion: 679261766 });
  ok('a changed rollupVersion is REFUSED even when the tip is higher',
    c.ok === false && c.reason === 'identity-change', JSON.stringify(c));
  ok('the identity message names the field that changed',
    c.ok === false && c.message.includes('rollupVersion'), c.message);
}
{
  const c = checkIdentity({ l1ChainId: 1, rollupVersion: 5 }, { l1ChainId: 11155111, rollupVersion: 5 });
  ok('a changed l1ChainId is REFUSED (mainnet data under a testnet endpoint)',
    c.ok === false && c.reason === 'identity-change', JSON.stringify(c));
}

// ── the ledger reader ───────────────────────────────────────────────────────
{
  ok('highestCovered reads the keys numerically, not as strings',
    highestCovered({ ranges: { '000000100-000000199': {}, '000001000-000001099': {} } }) === 1099,
    String(highestCovered({ ranges: { '000000100-000000199': {}, '000001000-000001099': {} } })));
}
{
  ok('highestCovered is null for a ledger with no ranges',
    highestCovered({ ranges: {} }) === null);
}

// ── the endpoint table ──────────────────────────────────────────────────────
//
// THE TABLE REPLACED A RULE, and the rule is what these arms are really about.
// The URL used to be derived from the slug, which is correct only while every
// slug is a drpc hostname. A guess that RESOLVES is the dangerous case: it
// produces a well-formed ledger, snapshot and generation describing the wrong
// chain under this name, and nothing downstream can tell.
{
  ok('both live chains are known, under the canonical names',
    CHAIN_ENDPOINTS['aztec'] === 'https://aztec.drpc.org'
    && CHAIN_ENDPOINTS['aztec-testnet'] === 'https://aztec-testnet.drpc.org',
    JSON.stringify(CHAIN_ENDPOINTS));
}
{
  // The table is exactly the live set. An extra entry is not harmless: a slug
  // nobody publishes is a slug a dispatch can typo its way into, and the
  // tip-regression check cannot save a chain that has no ledger yet.
  ok('the table carries no slugs beyond the two live chains',
    Object.keys(CHAIN_ENDPOINTS).sort().join(',') === 'aztec,aztec-testnet',
    Object.keys(CHAIN_ENDPOINTS).sort().join(','));
}
{
  // The v6-suffixed names were this table's previous answer to a problem that
  // is now solved differently — the retired corpora are discarded, so the
  // canonical names are free. Asserted so a revert cannot reintroduce them
  // quietly alongside the canonical pair.
  ok('the superseded v6 slugs are gone',
    CHAIN_ENDPOINTS['aztec-v6'] === undefined
    && CHAIN_ENDPOINTS['aztec-testnet-v6'] === undefined);
}
{
  ok('an unknown slug has no endpoint, so the tool must be given one',
    CHAIN_ENDPOINTS['aztec-whatever'] === undefined);
}

// ── `--start-at`: WHERE A FRESH LEDGER BEGINS ─────────────────────────────────
//
// A fresh ledger planned 1..maxBlocks, which is right for a chain published
// from genesis and wrong for a tip-follower. Measured 2026-11-26: heads 60,001
// (`aztec`) and 69,177 (`aztec-testnet`); at 150 blocks per 15-minute cycle
// against chains advancing 5,700 and 3,800 a day, a walk from 1 reaches the tip
// in ~6.9 and ~6.5 days, and every block of that walk is outside the replayable
// window, so it publishes tens of thousands of rows that can never carry a
// trace before the first debuggable transaction appears.
{
  const p = planRange({ highest: null, head: 69177, maxBlocks: 150, startAt: 69000 });
  ok('a fresh ledger begins where --start-at says',
    p.kind === 'range' && p.from === 69000 && p.to === 69149, JSON.stringify(p));
  // THE CONTROL, so the arm above is not passing because the planner ignores
  // the whole call: the SAME head and maxBlocks with no --start-at must still
  // plan from 1.
  const d = planRange({ highest: null, head: 69177, maxBlocks: 150 });
  ok('…and without it a fresh ledger still begins at 1',
    d.kind === 'range' && d.from === 1 && d.to === 150, JSON.stringify(d));
  // The range stays clamped to the head, so a start inside the last maxBlocks
  // does not plan past the tip.
  const c = planRange({ highest: null, head: 69177, maxBlocks: 150, startAt: 69100 });
  ok('…and the range is still clamped to the head',
    c.kind === 'range' && c.from === 69100 && c.to === 69177, JSON.stringify(c));
}
{
  // A COVERED LEDGER REFUSES IT RATHER THAN IGNORING IT. Ignoring is the
  // dangerous reading: the operator believes they chose where the publish
  // begins and it begins at highest+1 instead.
  const p = planRange({ highest: 500, head: 69177, maxBlocks: 150, startAt: 69000 });
  ok('--start-at on a ledger that already covers something is REFUSED',
    p.kind === 'refused' && p.reason === 'start-at-on-covered-ledger', JSON.stringify(p));
  ok('…and the message names both the flag\'s height and the coverage it collides with',
    p.message.includes('69000') && p.message.includes('500'), p.message);
  // AND THE CONTROL: the same covered ledger with no flag proceeds normally,
  // so the refusal is about the flag and not about the coverage.
  const d = planRange({ highest: 500, head: 69177, maxBlocks: 150 });
  ok('…while the same covered ledger with no flag plans 501..650',
    d.kind === 'range' && d.from === 501 && d.to === 650, JSON.stringify(d));
}
{
  // ABOVE THE HEAD IS A REFUSAL, because the alternative is an empty range on
  // a still-fresh ledger reported as success.
  const p = planRange({ highest: null, head: 100, maxBlocks: 150, startAt: 101 });
  ok('--start-at above the endpoint head is REFUSED',
    p.kind === 'refused' && p.reason === 'start-at-above-head', JSON.stringify(p));
  // Malformed values are a USAGE error, which is a different exit code and a
  // different fix from either refusal above.
  const u = planRange({ highest: null, head: 100, maxBlocks: 150, startAt: 0 });
  ok('…and a non-positive --start-at is a usage error, not a refusal',
    u.kind === 'usage' && u.message.includes('--start-at'), JSON.stringify(u));
}

// ── THE TABLE IS COMPARED AGAINST THE OBITUARY, BECAUSE THIS IS THE MISTAKE
//    THAT WAS ACTUALLY MADE ───────────────────────────────────────────────────
//
// `tools/chain/retired-networks.json` says, per CHAIN SLUG, that the network
// which would serve a repair is gone, and twelve render sites read it through
// `isRetiredNetwork(chain)` — the slug is all they are handed. `aztec` and
// `aztec-testnet` were listed there from 2026-10-28, and the same two slugs are
// the ones this table now points at the LIVE rollups. Nothing in the tree
// objected, because no check had ever compared the two files.
//
// The symptom would not have been a crash. Every row the follower published
// would have rendered "No trace was recorded for this execution, and none can
// be now" — `akStranded` — on a chain that was up, inside its replayable
// window, with the repair one dispatch away. A silent, sitewide, false claim on
// the whole production corpus.
//
// THE TWO GATES OVERLAP NOW AND THIS ONE IS STILL NOT REDUNDANT.
// `retired_networks.nim` fails the BUILD when a retired slug also appears in
// `chain-identity.json` — the stronger refusal. It used to cover only
// `aztec-testnet`, because an entry in that file is a dated decode MEASUREMENT
// and none had been taken against Aztec mainnet; mainnet's was taken on
// 2026-11-26 and the entry followed, so the build gate now binds both live
// slugs. (That sentence is corrected rather than left standing: a comment
// overstating a gate's reach is worse than one understating it.)
//
// WHAT THIS ARM STILL COVERS ALONE: it compares the obituary against the
// FOLLOWER'S OWN endpoint table rather than against the decode registry, so it
// binds a chain the follower tracks BEFORE anyone has measured a decode for it
// — which is the state every new chain starts in, and the state both Aztec
// chains were in a day ago.
{
  const retiredPath = join(here, 'retired-networks.json');
  const retired = JSON.parse(readFileSync(retiredPath, 'utf8'));
  // NOT VACUOUS: a parse that produced no entries would pass the overlap arm
  // while measuring nothing, which is the shape a registry gate fails in.
  const retiredChains = (retired.networks ?? []).map((n) => n.chain);
  ok('the obituary parses and names at least one chain, so the overlap arm has a subject',
    retired.format === 'blocktracer/retired-networks@1' && retiredChains.length > 0,
    `${retired.format} / ${JSON.stringify(retiredChains)}`);

  const followed = Object.keys(CHAIN_ENDPOINTS);
  const overlap = followed.filter((c) => retiredChains.includes(c));
  ok('no chain this follower tracks is listed as retired',
    overlap.length === 0,
    `overlap=${JSON.stringify(overlap)} followed=${JSON.stringify(followed)} `
    + `retired=${JSON.stringify(retiredChains)}`);

  // AND THE CONTROL, so the arm above is not passing because the comparison
  // never finds anything. It must be INDEPENDENT of the real overlap — the
  // first draft was `retiredChains.concat(followed).filter(...)`, which is a
  // second copy of the arm above and went red with it under the mutation,
  // proving nothing. This one feeds the expression a slug taken out of the
  // obituary itself, so it answers "would an overlap be seen" whatever the
  // real answer is.
  const knownRetired = [retiredChains[0]];
  const control = knownRetired.filter((c) => retiredChains.includes(c));
  ok('…and the same comparison DOES detect a retired slug when given one',
    control.length === 1 && control[0] === retiredChains[0],
    `control=${JSON.stringify(control)} subject=${JSON.stringify(knownRetired)}`);
}

console.log(`\nfollow-to-tip-selftest: ${ran} arm(s), ${failed} failure(s)`);
if (ran !== BASE_ARMS) {
  console.log(`FAIL tally: ran ${ran} arm(s) but BASE_ARMS says ${BASE_ARMS}. `
    + `Reconcile the count to the code, never the code to the count.`);
  process.exit(1);
}
if (EXIT_CAUGHT_UP !== 75) {
  console.log('FAIL EXIT_CAUGHT_UP must stay 75 (EX_TEMPFAIL): the systemd unit lists it '
    + 'in SuccessExitStatus, so changing it here turns every caught-up tick red.');
  process.exit(1);
}
process.exit(failed === 0 ? 0 : 1);
