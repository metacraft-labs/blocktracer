// Prove coverage from the ledger rather than asserting it.
//
// The ledger records, per range, what was REQUESTED and what the node SERVED,
// plus the explicit list of heights it declined. Contiguity is therefore two
// separate claims, and they fail differently:
//
//   1. the ranges themselves tile [from..to] with no gap and no overlap;
//   2. inside every range, every height was actually served.
//
// A run that only checked (1) would call a range contiguous while the node had
// declined half of it, which is exactly the confusion the rate-limit fix was
// about. Both are checked, and the second is reported as the union of every
// `notServed` height so the answer is a list, not a boolean.
import { readFileSync } from 'node:fs';

const ledgerPath = process.argv[2] ?? '.chain-state/aztec-testnet/coverage.json';
const wantFrom = process.argv[3] != null ? Number(process.argv[3]) : null;
const wantTo = process.argv[4] != null ? Number(process.argv[4]) : null;

const l = JSON.parse(readFileSync(ledgerPath, 'utf8'));
const ranges = Object.entries(l.ranges ?? {})
  .map(([k, v]) => ({ key: k, from: v.from, to: v.to, ...v }))
  .sort((a, b) => a.from - b.from);

if (ranges.length === 0) { console.log('ledger has no ranges'); process.exit(1); }

console.log(`ledger      : ${ledgerPath}`);
console.log(`format      : ${l.format}  chain=${l.chain}  endpoint=${l.endpoint}`);
console.log(`ranges      : ${ranges.length}`);
console.log(`span        : ${ranges[0].from} .. ${ranges[ranges.length - 1].to}`);

// ── 1. do the ranges tile the span? ─────────────────────────────────────────
const gaps = [], overlaps = [];
for (let i = 1; i < ranges.length; i++) {
  const prev = ranges[i - 1], cur = ranges[i];
  if (cur.from > prev.to + 1) gaps.push([prev.to + 1, cur.from - 1]);
  if (cur.from <= prev.to) overlaps.push([cur.from, Math.min(prev.to, cur.to)]);
}
if (wantFrom != null && ranges[0].from > wantFrom) gaps.unshift([wantFrom, ranges[0].from - 1]);
if (wantTo != null && ranges[ranges.length - 1].to < wantTo) gaps.push([ranges[ranges.length - 1].to + 1, wantTo]);

// ── 2. was every height inside the ranges actually served? ──────────────────
let requested = 0, served = 0, blocks = 0, transactions = 0;
const notServed = [], throttled = [];
const outcomes = {};
for (const r of ranges) {
  const f = r.fetch ?? {};
  requested += f.requested ?? 0;
  served += f.served ?? 0;
  blocks += f.blocks ?? 0;
  transactions += f.transactions ?? 0;
  for (const n of f.notServed ?? []) notServed.push(n);
  for (const n of f.throttledOut ?? []) throttled.push(n);
  for (const [k, v] of Object.entries(f.outcomes ?? {})) outcomes[k] = (outcomes[k] ?? 0) + v;
}

const span = (wantTo ?? ranges[ranges.length - 1].to) - (wantFrom ?? ranges[0].from) + 1;
console.log(`\nrequested   : ${requested}`);
console.log(`served      : ${served}`);
console.log(`blocks      : ${blocks}`);
console.log(`transactions: ${transactions}  outcomes=${JSON.stringify(outcomes)}`);
console.log(`\ngaps between ranges   : ${gaps.length}${gaps.length ? ' -> ' + JSON.stringify(gaps.slice(0, 10)) : ''}`);
console.log(`overlaps between ranges: ${overlaps.length}${overlaps.length ? ' -> ' + JSON.stringify(overlaps.slice(0, 10)) : ''}`);
console.log(`heights the node declined (notServed): ${notServed.length}${notServed.length ? ' -> ' + JSON.stringify(notServed.slice(0, 20)) : ''}`);
console.log(`heights lost to throttling           : ${throttled.length}${throttled.length ? ' -> ' + JSON.stringify(throttled.slice(0, 20)) : ''}`);

const contiguous = gaps.length === 0 && overlaps.length === 0
  && notServed.length === 0 && throttled.length === 0 && requested === served;
console.log(`\ncovered span: ${span} heights`);
console.log(`CONTIGUOUS WITH ZERO GAPS: ${contiguous ? 'YES' : 'NO'}`);
if (!contiguous) {
  console.log('  reason(s): '
    + [gaps.length && `${gaps.length} gap(s) between ranges`,
       overlaps.length && `${overlaps.length} overlap(s)`,
       notServed.length && `${notServed.length} height(s) the node declined`,
       throttled.length && `${throttled.length} height(s) lost to throttling`,
       requested !== served && `requested ${requested} != served ${served}`]
      .filter(Boolean).join('; '));
}
process.exit(contiguous ? 0 : 1);
