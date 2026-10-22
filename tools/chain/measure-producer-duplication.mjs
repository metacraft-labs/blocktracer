#!/usr/bin/env node
// measure-producer-duplication.mjs — how much the per-chain producers duplicate each other,
// as numbers, for Chain-Delivery DEL-6 / DEL-7.
//
// Usage:
//   node tools/chain/measure-producer-duplication.mjs [--json]
//
// DEL-6 writes each new chain's producer as a deliberate DUPLICATE of an existing one, and
// asks for "the duplication MEASURED — which functions are near-copies and how many lines —
// because DEL-7's extraction has to be justified by a number rather than by a feeling". This
// is that number. It reads the tree; it changes nothing.
//
// WHAT IS COUNTED. Each producer is its `produce-<chain>-snapshot.mjs` plus its
// `lib/<chain>-producer-facts.mjs` (Aztec's facts module is `lib/producer-facts.mjs` and its
// producers are range tools, so Aztec is not a subject here). For every pair of chains:
//   * shared lines: code lines (comments and blanks removed, whitespace collapsed) that occur
//     in both, as a multiset intersection, counting only lines of 25 or more characters.
//     Short lines (`}`, `return out;`, `const x = [];`) match by accident and say nothing
//     about a shared design;
//   * shared functions: top-level `function` / `export function` / `const f = (` names
//     declared by both.
// Line identity is a floor on duplication, not a ceiling: two functions that differ only in
// one identifier share no line. So the figure can understate a near-copy and cannot overstate
// one, which is the direction an argument for extraction needs.

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const CHAIN = join(dirname(fileURLToPath(import.meta.url)));
const SUBJECTS = [
  { chain: 'eth', producer: 'produce-eth-snapshot.mjs', facts: 'lib/eth-producer-facts.mjs' },
  { chain: 'flow', producer: 'produce-flow-snapshot.mjs', facts: 'lib/flow-producer-facts.mjs' },
  { chain: 'starknet', producer: 'produce-starknet-snapshot.mjs',
    facts: 'lib/starknet-producer-facts.mjs' },
  { chain: 'sol', producer: 'produce-sol-snapshot.mjs', facts: 'lib/solana-producer-facts.mjs' },
  { chain: 'sui', producer: 'produce-sui-snapshot.mjs', facts: 'lib/sui-producer-facts.mjs' },
];
const MIN_LINE = 25;

/** Code lines of a JS source: comments (line and block) and blanks removed, whitespace
 *  collapsed. String contents are not parsed: a `//` inside a string ends the line early,
 *  which can only remove text and so only lowers a shared count. */
export function codeLines(src) {
  const noBlock = src.replace(/\/\*[\s\S]*?\*\//g, '');
  return noBlock.split('\n')
    .map((l) => l.replace(/(^|[^:])\/\/.*$/, '$1').replace(/\s+/g, ' ').trim())
    .filter((l) => l.length > 0);
}

/** Top-level function names a module declares. */
export function functionNames(src) {
  const out = new Set();
  for (const m of src.matchAll(/^(?:export\s+)?(?:async\s+)?function\s+([A-Za-z0-9_$]+)/gm)) {
    out.add(m[1]);
  }
  for (const m of src.matchAll(/^(?:export\s+)?const\s+([A-Za-z0-9_$]+)\s*=\s*(?:async\s*)?\(/gm)) {
    out.add(m[1]);
  }
  return out;
}

/** Multiset intersection size of two line lists, over lines of at least MIN_LINE chars. */
export function sharedLines(a, b) {
  const count = new Map();
  for (const l of a) if (l.length >= MIN_LINE) count.set(l, (count.get(l) ?? 0) + 1);
  let n = 0;
  for (const l of b) {
    if (l.length < MIN_LINE) continue;
    const c = count.get(l) ?? 0;
    if (c > 0) { n++; count.set(l, c - 1); }
  }
  return n;
}

function load(s) {
  const files = [s.producer, s.facts].map((f) => join(CHAIN, f)).filter(existsSync);
  const src = files.map((f) => readFileSync(f, 'utf8')).join('\n');
  const lines = codeLines(src);
  return { ...s, files, lines, eligible: lines.filter((l) => l.length >= MIN_LINE).length,
           names: functionNames(src) };
}

function main() {
  const subjects = SUBJECTS.map(load).filter((s) => s.files.length > 0);
  const pairs = [];
  for (let i = 0; i < subjects.length; i++) {
    for (let j = i + 1; j < subjects.length; j++) {
      const a = subjects[i];
      const b = subjects[j];
      const shared = sharedLines(a.lines, b.lines);
      const fns = [...a.names].filter((n) => b.names.has(n)).sort();
      pairs.push({ a: a.chain, b: b.chain, sharedLines: shared,
                   ofA: a.eligible, ofB: b.eligible,
                   pctOfSmaller: Math.round(1000 * shared / Math.min(a.eligible, b.eligible)) / 10,
                   sharedFunctions: fns });
    }
  }
  const report = {
    method: `multiset intersection of code lines >= ${MIN_LINE} chars; top-level function names`,
    subjects: subjects.map((s) => ({ chain: s.chain, codeLines: s.lines.length,
                                     eligibleLines: s.eligible, functions: s.names.size })),
    pairs,
  };
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(report, null, 2));
    return;
  }
  console.log(`method: ${report.method}`);
  for (const s of report.subjects) {
    console.log(`  ${s.chain.padEnd(9)} ${String(s.codeLines).padStart(5)} code lines, `
                + `${String(s.eligibleLines).padStart(5)} counted, ${s.functions} functions`);
  }
  console.log('');
  for (const p of pairs) {
    console.log(`  ${`${p.a}–${p.b}`.padEnd(15)} ${String(p.sharedLines).padStart(4)} shared lines `
                + `(${p.pctOfSmaller}% of the smaller)  shared functions: `
                + `${p.sharedFunctions.length ? p.sharedFunctions.join(', ') : '(none)'}`);
  }
}

main();
