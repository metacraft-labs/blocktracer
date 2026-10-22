#!/usr/bin/env node
// eth-regen-check-selftest.mjs — the canonical form `eth-regen-check.mjs` compares
// two decoded containers in, shown to erase exactly the recorder's interning order
// and nothing else.
//
// Offline and toolchain-free: no container and no `ct-print`. The two documents
// below are the two decoded variants measured on 2026-10-20, reduced to the
// members that moved between them (codetracer-evm-recorder 564ae30, writer
// 7b8b587, six offline runs of `just eth-capture`, two distinct `ct-print --full`
// outputs). The failure a canonicaliser can have without anyone noticing is
// erasing TOO MUCH: it reports every pair equal, and a regeneration check built
// on it passes forever. So six of the eight arms are differences that must
// survive canonicalisation, each a member a real regression would move.

import { canonical, firstDifference } from './eth-regen-check.mjs';

// ── THE DECLARED ARM COUNT ───────────────────────────────────────────────────
// Read by `refusal-selftest.mjs`, which checks it against the `chain-selftest`
// header's arithmetic and ci.yml's copy. No host configurations: the base IS the
// total.
const BASE_ARMS = 8;

let ran = 0;
let failed = 0;
const arm = (name, cond) => {
  ran++;
  if (!cond) failed++;
  console.log(`  ${cond ? 'ok  ' : 'FAIL'}  ${name}`);
};

const variantA = {
  varnames: ['storage[34]', 'storage[83]'],
  events: [{ kind: 'step', line: 4234, vars: [
    { varname_id: 1, varname: 'storage[83]', value: { r: '0xffbe233' } },
    { varname_id: 0, varname: 'storage[34]', value: { r: '0x71d712bf31' } },
  ] }],
};
const variantB = {
  varnames: ['storage[83]', 'storage[34]'],
  events: [{ kind: 'step', line: 4234, vars: [
    { varname_id: 0, varname: 'storage[34]', value: { r: '0x71d712bf31' } },
    { varname_id: 1, varname: 'storage[83]', value: { r: '0xffbe233' } },
  ] }],
};
const same = (x, y) => firstDifference(canonical(x), canonical(y)) === null;
const clone = (x) => JSON.parse(JSON.stringify(x));

arm('the two measured variants are one canonical document', same(variantA, variantB));
arm('CONTROL: without canonicalising they differ', firstDifference(variantA, variantB) !== null);

const value = clone(variantB); value.events[0].vars[0].value.r = '0x71d712bf32';
arm('a changed value is a difference', !same(variantA, value));
const name = clone(variantB); name.events[0].vars[1].varname = 'storage[84]';
arm('a changed variable name is a difference', !same(variantA, name));
const line = clone(variantB); line.events[0].line = 4235;
arm('a changed line is a difference', !same(variantA, line));
const extra = clone(variantB); extra.events.push({ kind: 'step', line: 1, vars: [] });
arm('an extra step is a difference', !same(variantA, extra));
const dropped = clone(variantB); dropped.events[0].vars.pop();
arm('a dropped variable is a difference', !same(variantA, dropped));
const swapped = clone(variantB);
swapped.events[0].vars[0].value.r = '0xffbe233';
swapped.events[0].vars[1].value.r = '0x71d712bf31';
arm('values swapped between two names are a difference', !same(variantA, swapped));

if (ran !== BASE_ARMS) {
  failed++;
  console.log(`  FAIL  arm count: ${ran} ran, ${BASE_ARMS} declared`);
} else {
  console.log(`arm count: ${ran} (as declared: ${BASE_ARMS})`);
}
console.log(`eth-regen-check-selftest: ${failed === 0 ? 'PASS' : `FAIL — ${failed}`}`);
process.exit(failed === 0 ? 0 : 1);
