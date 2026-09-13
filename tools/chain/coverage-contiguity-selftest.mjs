#!/usr/bin/env node
// coverage-contiguity-selftest.mjs — proof that `coverage-contiguity.mjs` REFUSES.
//
//   node tools/chain/coverage-contiguity-selftest.mjs
//
// ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────
//
// `coverage-contiguity.mjs` arrived from a measurement scratch tree with a `just` recipe,
// NO TEST and NO CALLER. It is kept because CPC-6's deliverable requires "contiguity
// asserted from the ledger rather than inferred from a total", so it has a named future
// consumer — and a tool with a named future consumer and no proof of bite is the exact
// shape Verification-Harness-Traps §4 names: a check that has never been observed refusing
// is indistinguishable from `return true`. Its whole output is one line, `CONTIGUOUS WITH
// ZERO GAPS: YES`, and an exit code. Nothing had ever seen it print NO.
//
// The standard held to here is this campaign's own: the contiguity checker was validated
// against FIVE synthetic failing ledgers, and the tool enumerates exactly five reasons it
// can refuse. All five get their own case, each with a passing control that differs from
// it in one field, plus the two span assertions and the two argument paths.
//
// ── WHY IT IS A SPAWN AND NOT AN IMPORT ────────────────────────────────────────────────
//
// The tool is a script: it reads `process.argv`, prints, and calls `process.exit`. The
// thing under test is the VERDICT — an exit code and the sentence beside it — and an
// import could not observe either. It is also how the tool is actually used: `just
// coverage-contiguity <ledger>` runs it as a process and reads its status.
//
// OFFLINE AND TOOLCHAIN-FREE, which is what qualifies it for `chain-selftest`: it writes
// JSON to a temporary directory and runs `node`. It reaches no network — neither does the
// tool, which reads one file.
//
// ── THE LEDGERS ARE THE REAL SHAPE ─────────────────────────────────────────────────────
//
// `blocktracer/coverage-ledger@1` as `ingest-range.mjs` writes it: zero-padded range keys,
// `from`/`to` per entry and a `fetch` block carrying `requested`, `served`, `blocks`,
// `transactions`, `notServed`, `throttledOut` and `outcomes`. A fixture that invented its
// own shape would pass while the tool read something else, which is the failure this
// repository has paid for in the snapshot seam already.

import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const TOOL = join(HERE, 'coverage-contiguity.mjs');

let asserted = 0, failed = 0;
const ck = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`);
};
/** A mutation arm is only evidence if it REDDENS. */
const bite = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  MUTATION DID NOT BITE  ${label}`); }
  else console.error(`  bite  ${label}`);
};

const pad = 9;
const key = (from, to) =>
  `${String(from).padStart(pad, '0')}-${String(to).padStart(pad, '0')}`;

/** One ledger range entry, in the shape `ingest-range.mjs` writes. `over` lets a case
 *  change exactly one field, so a mutation arm differs from its control in one place. */
const range = (from, to, over = {}) => [key(from, to), {
  from, to,
  fetch: {
    requested: to - from + 1,
    served: to - from + 1,
    blocks: to - from + 1,
    transactions: 0,
    notServed: [],
    throttledOut: [],
    outcomes: {},
    ...over,
  },
  fetchedAt: '2026-09-12T00:00:00.000Z',
  codeVersion: { commit: 'deadbeefcafe' },
}];

const ledger = (entries) => ({
  format: 'blocktracer/coverage-ledger@1',
  chain: 'aztec-testnet',
  endpoint: 'https://aztec-testnet.drpc.org',
  keyPadding: pad,
  ranges: Object.fromEntries(entries),
});

let dir;
/** Write a ledger and run the tool over it. Returns its exit code and both streams. */
async function run(doc, args = []) {
  const path = join(dir, `ledger-${Math.random().toString(36).slice(2)}.json`);
  await writeFile(path, JSON.stringify(doc, null, 1) + '\n');
  const r = spawnSync(process.execPath, [TOOL, path, ...args],
                      { encoding: 'utf8', timeout: 30_000 });
  return { code: r.status, out: `${r.stdout}`, err: `${r.stderr}`, path };
}

const says = (r, re) => re.test(r.out) || re.test(r.err);

dir = await mkdtemp(join(tmpdir(), 'coverage-contiguity-selftest-'));

// ── THE CONTROL, AND IT IS FIRST FOR A REASON ──────────────────────────────────────────
//
// Every case below is a one-field mutation of THIS ledger. If the control does not pass,
// every "mutation refused" arm underneath it is satisfied by a tool that refuses
// everything, which is the §4a failure: a negative assertion with no positive twin running
// through the same code path has nothing to fail.
console.error('\ncase 1 — a contiguous ledger passes, and says so');
const CONTIGUOUS = ledger([range(1, 100), range(101, 200), range(201, 300)]);
{
  const r = await run(CONTIGUOUS);
  ck('a ledger whose ranges tile 1..300 with every height served exits 0', r.code === 0);
  ck('…and says CONTIGUOUS WITH ZERO GAPS: YES', says(r, /CONTIGUOUS WITH ZERO GAPS: YES/));
  ck('…and reports the span it checked, so the answer is attributable',
     says(r, /span\s*:\s*1 \.\. 300/) && says(r, /covered span: 300 heights/));
  ck('…and counts the ranges it read rather than leaving the population implicit',
     says(r, /ranges\s*:\s*3/));
}

// ── THE FIVE REFUSALS, EACH NAMING WHAT IT FOUND ───────────────────────────────────────
//
// The tool's verdict is a conjunction of five conditions and each one is separately
// reachable. A suite that drove one of them would prove the conjunction can be false and
// nothing about the other four.

console.error('\ncase 2 — a hole between two ranges is refused, and the gap is NAMED');
{
  // 101..200 removed: the ledger now tiles 1..100 and 201..300.
  const r = await run(ledger([range(1, 100), range(201, 300)]));
  bite('mutation: a ledger with a hole exits non-zero', r.code === 1);
  bite('…and says CONTIGUOUS WITH ZERO GAPS: NO',
       says(r, /CONTIGUOUS WITH ZERO GAPS: NO/));
  // NAMING THE GAP IS THE DELIVERABLE, not merely refusing. A checker that answered
  // "somewhere in 1..300" would send a reader back to the ledger to find it by hand, and
  // CPC-6 asks for contiguity asserted FROM the ledger — an answer that is a list.
  bite('…and names the missing span 101..200 rather than only reporting a count',
       says(r, /\[101,\s*200\]/));
  bite('…and attributes it to the gap check rather than to one of the other four',
       says(r, /1 gap\(s\) between ranges/));
}

console.error('\ncase 3 — two ranges covering the same heights are refused');
{
  // 150..250 overlaps 101..200 on 150..200. A total over these ranges would DOUBLE-COUNT
  // and read as more coverage than exists, which is why an overlap is a refusal and not a
  // tidiness complaint.
  const r = await run(ledger([range(1, 100), range(101, 200), range(150, 250)]));
  bite('mutation: overlapping ranges exit non-zero', r.code === 1);
  bite('…and the overlapping span 150..200 is named', says(r, /\[150,\s*200\]/));
  bite('…and it is attributed to the overlap check', says(r, /1 overlap\(s\)/));
  ck('control: the same three ranges with the overlap removed pass',
     (await run(ledger([range(1, 100), range(101, 200), range(201, 250)]))).code === 0);
}

console.error('\ncase 4 — a range the node declined heights inside is not contiguous');
{
  // THE CASE THE TOOL EXISTS FOR. The ranges tile perfectly; the node answered nothing for
  // three heights inside one of them. A checker that asked only whether the ranges tile
  // would call this contiguous while the node had declined part of it.
  const r = await run(ledger([
    range(1, 100), range(101, 200, { served: 97, notServed: [120, 121, 122] }),
    range(201, 300),
  ]));
  bite('mutation: heights inside a range that the node declined exit non-zero',
       r.code === 1);
  bite('…and the declined heights are listed, not counted',
       says(r, /\[120,\s*121,\s*122\]/));
  bite('…and it is attributed to the declined check',
       says(r, /3 height\(s\) the node declined/));
  ck('control: the ranges themselves still tile, so this is NOT the gap check firing',
     !says(r, /1 gap\(s\) between ranges/) && says(r, /gaps between ranges\s*:\s*0/));

  // ── AND THE CLAUSE ON ITS OWN, WHICH THE ARMS ABOVE DO NOT ISOLATE ──────────────────
  //
  // THIS ARM EXISTS BECAUSE THE ONES ABOVE WERE MEASURED NOT TO BITE. Deleting the
  // `notServed.length === 0` term from the tool's verdict left every assertion above
  // GREEN — because the realistic ledger they use also has `served` short of `requested`,
  // and the arithmetic clause refused it instead. Four "mutation bit" lines, and the
  // condition under test was not the one doing the refusing.
  //
  // So the clause is isolated: a ledger whose own `served` equals its `requested` while
  // it LISTS heights the node declined. That ledger is internally inconsistent, which is
  // the point — it is the only shape in which this clause is the sole reason to refuse,
  // and a checker that dropped the clause would call it contiguous.
  const isolated = await run(ledger([
    range(1, 100), range(101, 200, { notServed: [120, 121, 122] }), range(201, 300),
  ]));
  bite('mutation, ISOLATED: declined heights alone refuse, with `served` == `requested` '
       + 'so no other clause can be doing it', isolated.code === 1);
  // THE NEGATIVES MATCH THE REASON-LIST WORDING, NOT THE TALLY LINES. The tool prints
  // "heights lost to throttling : 0" on every run, so a negative keyed on "lost to
  // throttling" is satisfied by the header rather than by the absence of the finding —
  // measured, on the first draft of this arm. Every negative below names the `N height(s)`
  // / `N gap(s)` form the reason list uses and nothing else says.
  bite('…and the declined check is the ONLY reason given',
       says(isolated, /3 height\(s\) the node declined/)
         && !says(isolated, /requested \d+ != served/)
         && !says(isolated, /\d+ gap\(s\) between ranges/)
         && !says(isolated, /\d+ overlap\(s\)/)
         && !says(isolated, /height\(s\) lost to throttling/));
}

console.error('\ncase 5 — heights lost to throttling are OUR fault and still refuse');
{
  // A rate limit is a fact about this client's quota and says nothing about the chain —
  // which is exactly why it must not be silently absorbed into a coverage claim.
  const r = await run(ledger([
    range(1, 100), range(101, 200, { served: 98, throttledOut: [155, 156] }),
    range(201, 300),
  ]));
  bite('mutation: heights lost to throttling exit non-zero', r.code === 1);
  bite('…and they are listed', says(r, /\[155,\s*156\]/));
  bite('…and kept APART from the heights the node declined — one is about the chain and '
       + 'the other is about us',
       says(r, /2 height\(s\) lost to throttling/)
         && !says(r, /height\(s\) the node declined/));

  // ISOLATED, for the reason case 4 states: the arm above was measured NOT to bite when
  // the throttle clause was deleted, because its ledger also fails the arithmetic check.
  const isolated = await run(ledger([
    range(1, 100), range(101, 200, { throttledOut: [155, 156] }), range(201, 300),
  ]));
  bite('mutation, ISOLATED: throttled heights alone refuse, with `served` == `requested` '
       + 'so no other clause can be doing it', isolated.code === 1);
  bite('…and the throttle check is the ONLY reason given',
       says(isolated, /2 height\(s\) lost to throttling/)
         && !says(isolated, /requested \d+ != served/)
         && !says(isolated, /\d+ gap\(s\) between ranges/)
         && !says(isolated, /\d+ overlap\(s\)/)
         && !says(isolated, /\d+ height\(s\) the node declined/));
}

console.error('\ncase 6 — a range that served fewer heights than it requested refuses');
{
  // The arithmetic check, and it is separate from the three above: a range can list no
  // declined and no throttled height and still have served fewer than it asked for, which
  // is a ledger whose own numbers do not agree.
  const r = await run(ledger([
    range(1, 100), range(101, 200, { served: 95 }), range(201, 300),
  ]));
  bite('mutation: served < requested exits non-zero', r.code === 1);
  bite('…and both figures are named, so the discrepancy is checkable from the message',
       says(r, /requested 300 != served 295/));
}

// ── THE SPAN, WHICH IS THE OTHER HALF OF "CONTIGUOUS OVER WHAT?" ───────────────────────
//
// The tool takes an optional `[from] [to]`, and its own usage says why: "a ledger that
// tiles perfectly over the WRONG range is reported rather than called contiguous". Both
// ends are separately reachable and both are checked — a guard written for one end and
// silently missing the other is this repository's most-repeated defect shape.

console.error('\ncase 7 — a ledger that tiles the wrong span is reported, at both ends');
{
  const low = await run(CONTIGUOUS, ['1', '400']);
  bite('mutation: an asserted span reaching ABOVE the ledger reports the tail gap',
       low.code === 1 && says(low, /\[301,\s*400\]/));
  const high = await run(CONTIGUOUS, ['0', '300']);
  bite('mutation: an asserted span reaching BELOW the ledger reports the head gap',
       high.code === 1 && says(high, /\[0,\s*0\]/));
  ck('control: the same ledger against its own span passes',
     (await run(CONTIGUOUS, ['1', '300'])).code === 0);
}

// ── THE TWO ARGUMENT PATHS ─────────────────────────────────────────────────────────────

console.error('\ncase 8 — the ledger path is required, and an empty ledger is not coverage');
{
  // NO DEFAULT. The tool arrived defaulting to `.chain-state/aztec-testnet/coverage.json`,
  // a gitignored path that resolves on the machine that ran the backfill and nowhere else.
  // Asserted as BEHAVIOUR — exit 2, the usage code, and nothing on stdout — because that
  // is what a caller reads.
  const noArgs = spawnSync(process.execPath, [TOOL], { encoding: 'utf8', timeout: 30_000 });
  ck('no ledger argument exits 2 — the usage code, not a verdict', noArgs.status === 2);
  ck('…and says what it wanted', `${noArgs.stderr}`.includes('usage:')
     && `${noArgs.stderr}`.includes('<coverage.json>'));
  ck('…and printed no verdict, so an empty argv cannot read as a pass',
     !/CONTIGUOUS/.test(`${noArgs.stdout}`));
  // A ledger with no ranges is the empty-set green this whole campaign is about: every
  // universal claim over zero ranges is vacuously true, so "no gaps" would be YES.
  const empty = await run(ledger([]));
  bite('mutation: a ledger with NO ranges exits non-zero rather than reporting a '
       + 'vacuous YES', empty.code === 1);
  bite('…and says so in as many words', says(empty, /ledger has no ranges/));
}

await rm(dir, { recursive: true, force: true });

console.error('');
if (asserted !== 33) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 33 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('PASS — the contiguity check refuses on every path it is supposed to');
