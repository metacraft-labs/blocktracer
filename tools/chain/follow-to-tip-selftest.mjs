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

import { planRange, checkIdentity, highestCovered, EXIT_CAUGHT_UP } from './follow-to-tip.mjs';

// Reconciled against the arms actually run, not maintained by hand: a short
// tally is a finding, and editing the expected number to match a short run is
// how a suite goes quiet.
const BASE_ARMS = 19;

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
  // The testnet restart, as retired-networks.json measured it: the node moved to
  // nodeVersion 6.0.0 / rollupVersion 679261766 under the SAME slug.
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
