#!/usr/bin/env node
// eth-regen-check.mjs — does a container regenerated from the committed inputs
// record the same execution as a container we already hold?
//
// Usage:
//   node tools/chain/eth-regen-check.mjs --ct-print <path> <held.ct> <regenerated.ct>
//
// Its selftest is `tools/chain/eth-regen-check-selftest.mjs`, one of `chain-selftest`'s suites.
//
// ── WHY THIS EXISTS ─────────────────────────────────────────────────────────
//
// `ban-added-ct-recordings` refuses a committed recording because "a recording
// pins a recorder version nothing tracks". For Ethereum that argument has an
// answer the Aztec corpus never had: `just eth-capture` regenerates the
// container from the committed JSON-RPC transcript, offline, in seconds. A held
// container is therefore checkable — regenerate it and compare. This is the
// comparison. Chain-Delivery DEL-5 (2026-10-20) names it as the condition for
// exempting the one Ethereum container, so the ban's argument is answered and
// not waived.
//
// ── WHY DECODED, AND WHAT CANONICAL MEANS ───────────────────────────────────
//
// Bytes cannot be compared: the recorder stamps a UUIDv7 recording id, so no two
// runs share a sha256. `ct-print --full` drops that id, and over four offline
// runs on 2026-10-20 (recorder 564ae30, writer 7b8b587) it produced exactly two
// decoded outputs. They differ in ONE way: two storage variables written in the
// same step are interned in a per-process order. So `varname_id` and the order of
// a step's `vars` are 0/1 coin flips, and the `varnames` table is listed in
// interning order.
//
// The canonical form removes exactly that freedom and nothing else: drop every
// `varname_id`, sort each `vars` list by name, and sort the `varnames` table. A
// value, a line, a step, a call or a path that differs still differs. The
// selftest has an arm for each of those, because a canonicaliser that erased
// too much would report every pair equal. That failure is safe-looking,
// and a regeneration check is worthless if it has it.

import { spawnSync } from 'node:child_process';
import { argv, exit } from 'node:process';
import { pathToFileURL } from 'node:url';

/** The decoded document with interning order removed, and nothing else. */
export function canonical(doc) {
  const walk = (node) => {
    if (Array.isArray(node)) return node.map(walk);
    if (node === null || typeof node !== 'object') return node;
    const out = {};
    for (const key of Object.keys(node).sort()) {
      if (key === 'varname_id') continue;
      out[key] = walk(node[key]);
    }
    if (Array.isArray(out.vars)) {
      out.vars = [...out.vars].sort((a, b) =>
        String(a.varname).localeCompare(String(b.varname)));
    }
    return out;
  };
  const c = walk(doc);
  if (Array.isArray(c.varnames)) c.varnames = [...c.varnames].sort();
  return c;
}

/** The first path at which two canonical documents differ, or null. */
export function firstDifference(a, b, path = '$') {
  if (typeof a !== typeof b || Array.isArray(a) !== Array.isArray(b)
      || (a === null) !== (b === null)) return path;
  if (a === null || typeof a !== 'object') return a === b ? null : path;
  if (Array.isArray(a)) {
    if (a.length !== b.length) return `${path}.length (${a.length} vs ${b.length})`;
    for (let i = 0; i < a.length; i++) {
      const d = firstDifference(a[i], b[i], `${path}[${i}]`);
      if (d) return d;
    }
    return null;
  }
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  for (const k of [...keys].sort()) {
    if (!(k in a) || !(k in b)) return `${path}.${k} (present in one only)`;
    const d = firstDifference(a[k], b[k], `${path}.${k}`);
    if (d) return d;
  }
  return null;
}

function decode(ctPrint, file) {
  const r = spawnSync(ctPrint, ['--full', file], { encoding: 'utf8', maxBuffer: 1 << 30 });
  if (r.status !== 0) {
    throw new Error(`${ctPrint} --full ${file} exited ${r.status}: ${(r.stderr || '').trim()}`);
  }
  return JSON.parse(r.stdout);
}

function main() {
  const args = argv.slice(2);
  const i = args.indexOf('--ct-print');
  const ctPrint = i >= 0 ? args[i + 1] : process.env.CT_PRINT;
  const files = args.filter((a, k) => !a.startsWith('--') && (i < 0 || k !== i + 1));
  if (!ctPrint || files.length !== 2) {
    console.error('usage: eth-regen-check.mjs --ct-print <path> <held.ct> <regenerated.ct>');
    return 2;
  }
  let held, regen;
  try {
    [held, regen] = files.map((f) => canonical(decode(ctPrint, f)));
  } catch (e) {
    // NOT A VERDICT: a container the reader refuses says nothing about whether
    // the two record the same execution, so it is not reported as DIFFERENT.
    console.error(`eth-regen-check: ${e.message}`);
    return 2;
  }
  const d = firstDifference(held, regen);
  if (d) {
    console.log(`DIFFERENT: the regenerated container records another execution; first at ${d}`);
    return 1;
  }
  console.log(`SAME: ${files[1]} records the execution ${files[0]} holds, `
              + 'up to the recorder\'s interning order');
  return 0;
}

// Only when run, never when imported: the selftest imports the two functions above.
if (import.meta.url === pathToFileURL(argv[1] ?? '').href) exit(main());
