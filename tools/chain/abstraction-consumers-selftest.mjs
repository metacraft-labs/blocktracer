#!/usr/bin/env node
//
// abstraction-consumers-selftest.mjs — DEL-7's `test_every_abstraction_has_two_consumers`.
//
//   node tools/chain/abstraction-consumers-selftest.mjs
//
// Exit codes: 0 every arm and every control held · 1 an arm or a control failed.
//
// ── WHAT IT ASSERTS, AND IT IS ASSERTED AGAINST THE CODE ───────────────────────────────
//
// ING-7's inherited rule: "No abstraction introduced before it has two consumers. A seam
// justified by one network is a guess; the second consumer is what makes it a boundary."
// DEL-7 sharpens it: "An abstraction with one consumer is refused by this milestone, not
// deferred by it."
//
// So every binding `lib/producer-runtime.mjs` exports is counted here by reading the
// producers' and facts modules' OWN IMPORT STATEMENTS, never the design document and never
// the comment beside the export. `tools/chain/ingestion-classification.json` states the
// same lists and is checked AGAINST this derivation rather than trusted (arm 4), so the
// data file cannot drift away from the tree without a red.
//
// ── EVERY ARM HAS A CONTROL AND EVERY CONTROL RE-EVALUATES THE REAL PREDICATE ──────────
//
// A control that merely confirms a deleted string is gone is a tautology. Each control
// below therefore mutates a copy of the subject and runs THE SAME JUDGEMENT over it,
// requiring the judgement to be FALSE there:
//
//   arm 1  removing one consumer's import drops that binding's consumer count by exactly
//          one, and takes a two-consumer binding below the floor, where the judgement
//          reports it. So "two" is counted and not claimed.
//   arm 2  the no-dispatch judgement is applied to a synthetic module that DOES dispatch on
//          a chain and must report it, and to one that does not and must stay silent.
//   arm 3  the shared exit-code path is driven with a source refusal and must answer 1, so
//          the arm that observes 2 on a configuration refusal is not reading a constant.
//   arm 4  the classification file is mutated to claim a consumer the code does not have,
//          and the agreement judgement must report it.

import { execFile } from 'node:child_process';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';

const run = promisify(execFile);
const HERE = 'tools/chain/abstraction-consumers-selftest.mjs';
const CHAIN = dirname(fileURLToPath(import.meta.url));
const MODULE_PATH = join(CHAIN, 'lib', 'producer-runtime.mjs');
const CLASSIFICATION = join(CHAIN, 'ingestion-classification.json');
const MODULE_BASENAME = 'producer-runtime.mjs';

/** The floor ING-7 sets. Not a parameter: two is the rule. */
const CONSUMER_FLOOR = 2;

/**
 * This suite's own assertion count, declared so the suite census in
 * `refusal-selftest.mjs` can cross-check it and so an arm cannot disappear silently.
 * Offline and host-independent — no container reader, no network — so the base IS the
 * total.
 */
const BASE_ARMS = 33;

let passed = 0;
let failed = 0;
const ck = (what, ok) => {
  if (ok) { passed += 1; console.log(`  ok    ${what}`); } else {
    failed += 1; console.error(`  FAIL  ${what}`);
  }
};
const section = (t) => console.log(`\n${t}`);

// ── the judgements, each a pure function of source text ────────────────────────────────

/** The bindings a module source exports, by name. */
export function exportedBindings(src) {
  const out = new Set();
  for (const m of src.matchAll(/^export\s+(?:async\s+)?function\s+([A-Za-z0-9_$]+)/gm)) {
    out.add(m[1]);
  }
  for (const m of src.matchAll(/^export\s+const\s+([A-Za-z0-9_$]+)\s*=/gm)) out.add(m[1]);
  return out;
}

/**
 * Which of `names` this file imports from `producer-runtime.mjs`, local alias ignored.
 *
 * Both spellings count, because the facts modules use the second: a plain
 * `import { a, b as c } from './producer-runtime.mjs'` and a re-export
 * `export { a as b } from './producer-runtime.mjs'`.
 */
export function bindingsTakenFrom(src, moduleBasename) {
  const taken = new Set();
  const re = new RegExp(
    String.raw`(?:import|export)\s*\{([^}]*)\}\s*from\s*['"][^'"]*` + moduleBasename + String.raw`['"]`,
    'gs');
  for (const m of src.matchAll(re)) {
    for (const piece of m[1].split(',')) {
      const name = piece.trim().split(/\s+as\s+/)[0].trim();
      if (name) taken.add(name);
    }
  }
  return taken;
}

/**
 * One chain's two spellings in this tree, folded to one.
 *
 * `produce-sol-snapshot.mjs` and `lib/solana-producer-facts.mjs` are the SAME CHAIN under
 * two names, and that is not cosmetic here: left unfolded, a binding imported by both
 * files would be credited with two consumers for one network, which is exactly the hole
 * ING-7's rule exists to close. The fold is asserted below (§1) rather than assumed.
 */
const CHAIN_ALIASES = new Map([['solana', 'sol']]);

/**
 * The chain a consumer file speaks for, or null if it is not a per-chain file.
 *
 * A CONSUMER IS A CHAIN AND NOT A FILE, which is the whole content of ING-7's rule: two
 * files of one chain importing a binding is one consumer, and counting files would let a
 * single network manufacture a second consumer by splitting a module.
 */
export function chainOf(file) {
  let m = /^produce-([a-z0-9]+)-snapshot\.mjs$/.exec(file);
  if (!m) m = /^([a-z0-9]+)-producer-facts\.mjs$/.exec(file);
  if (!m) return null;
  return CHAIN_ALIASES.get(m[1]) ?? m[1];
}

/** Every per-chain consumer file in the tree, as {file, chain, src}. */
function consumerFiles(overrides = new Map()) {
  const out = [];
  const read = (p, rel) => (overrides.has(rel) ? overrides.get(rel) : readFileSync(p, 'utf8'));
  for (const f of readdirSync(CHAIN).sort()) {
    const chain = chainOf(f);
    if (chain !== null) out.push({ file: f, chain, src: read(join(CHAIN, f), f) });
  }
  const libDir = join(CHAIN, 'lib');
  for (const f of readdirSync(libDir).sort()) {
    const chain = chainOf(f);
    if (chain !== null) {
      out.push({ file: `lib/${f}`, chain, src: read(join(libDir, f), `lib/${f}`) });
    }
  }
  return out;
}

/** {binding -> sorted array of consumer chains}, derived from import statements. */
export function consumersByBinding(bindings, files) {
  const by = new Map([...bindings].map((b) => [b, new Set()]));
  for (const { chain, src } of files) {
    for (const name of bindingsTakenFrom(src, MODULE_BASENAME)) {
      if (by.has(name)) by.get(name).add(chain);
    }
  }
  return new Map([...by].map(([b, s]) => [b, [...s].sort()]));
}

/** Bindings below the floor, as findings. THE PREDICATE, re-used by every control. */
export function underfedBindings(bindings, files) {
  const by = consumersByBinding(bindings, files);
  const findings = [];
  for (const [b, chains] of by) {
    if (chains.length < CONSUMER_FLOOR) {
      findings.push(`${b}: ${chains.length} consumer chain(s) {${chains.join(',')}} `
                    + `against a floor of ${CONSUMER_FLOOR}`);
    }
  }
  return { by, findings };
}

/**
 * Dispatch shapes in a module source. ING-7's rule counts three: a conditional on a chain,
 * a registry keyed on a chain or a prestate strategy, and a second implementation selected
 * at run time. This is the JavaScript counterpart of `check-prestate-ledger.pl`'s R9, which
 * judges NIM source under `src/blocktracer/chain/` and so cannot see this file at all.
 */
export function dispatchFindings(name, src) {
  const f = [];
  const lines = src.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i].replace(/^\s*(\/\/.*|\*.*)$/, '');       // a comment is not code
    const n = i + 1;
    if (/\bswitch\s*\(\s*[A-Za-z0-9_$.]*(chain|slug|strategy)/i.test(l)) {
      f.push(`${name}:${n} switch on a chain or a strategy`);
    }
    if (/['"](?:ethereum-mainnet|starknet-mainnet|flow-mainnet|solana-mainnet|aztec(?:-testnet)?|sui)['"]/
      .test(l)) {
      f.push(`${name}:${n} a chain slug literal`);
    }
    if (/\b(?:replay-preceding|version-addressed|forward-capture|hydrated-from-node|self-contained)\b['"]?\s*:/
      .test(l)) {
      f.push(`${name}:${n} a table keyed on a prestate strategy token`);
    }
  }
  return f;
}

// ── arm 1. every export is reached by two chains ───────────────────────────────────────

const moduleSrc = readFileSync(MODULE_PATH, 'utf8');
const bindings = exportedBindings(moduleSrc);
const files = consumerFiles();

section(`§1 every export of lib/${MODULE_BASENAME} is reached by ${CONSUMER_FLOOR} chains`);
ck(`the module exports at least one binding (${bindings.size} found: `
   + `${[...bindings].sort().join(', ')})`, bindings.size > 0);
const chainsSeen = [...new Set(files.map((x) => x.chain))].sort();
ck(`the tree holds per-chain consumer files (${files.length} file(s) over `
   + `${chainsSeen.length} chain(s): ${chainsSeen.join(', ')})`, files.length >= 5);
ck("the two spellings of Solana fold to one chain, so one network cannot supply two "
   + `consumers (${chainsSeen.length} chain(s) from ${files.length} files)`,
   chainsSeen.includes('sol') && !chainsSeen.includes('solana'));
ck('and the fold is a real one: both files exist',
   files.some((x) => x.file === 'produce-sol-snapshot.mjs')
   && files.some((x) => x.file === 'lib/solana-producer-facts.mjs'));

const live = underfedBindings(bindings, files);
for (const [b, chains] of live.by) {
  ck(`${b} — ${chains.length} consumer chain(s): ${chains.join(', ')}`,
     chains.length >= CONSUMER_FLOOR);
}
ck('no export is below the floor', live.findings.length === 0);
if (live.findings.length > 0) for (const f of live.findings) console.error(`        ${f}`);

section('§1 CONTROL: removing one consumer turns the SAME judgement red');
{
  // The binding with the FEWEST consumers is the one a removal can take below the floor,
  // so it is the one the control uses. Its import is deleted from an in-memory copy of one
  // real consumer file and `underfedBindings` — the same function arm 1 ran — is re-run.
  const [thinnest, thinChains] = [...live.by].sort((a, b) => a[1].length - b[1].length)[0];
  const victimChain = thinChains[0];
  const victim = files.find((x) => x.chain === victimChain
                                   && bindingsTakenFrom(x.src, MODULE_BASENAME).has(thinnest));
  ck(`a real consumer file to mutate was found for ${thinnest} (${victim?.file})`,
     victim !== undefined);
  const stripped = victim.src.replace(
    new RegExp(String.raw`(\{[^}]*?)\b` + thinnest + String.raw`\b(\s+as\s+[A-Za-z0-9_$]+)?,?\s*`, 's'),
    '$1');
  ck('the mutation changed the file', stripped !== victim.src);
  const mutatedFiles = files.map((x) => (x.file === victim.file ? { ...x, src: stripped } : x));
  const after = underfedBindings(bindings, mutatedFiles);
  const beforeN = live.by.get(thinnest).length;
  const afterN = after.by.get(thinnest).length;
  ck(`${thinnest}'s consumer count fell ${beforeN} -> ${afterN} when one consumer's import `
     + `was removed, so the count tracks the code`, afterN === beforeN - 1);
  ck(`and the judgement REPORTS it (${after.findings.length} finding(s): `
     + `${after.findings.join('; ') || 'none'})`,
     after.findings.some((f) => f.startsWith(`${thinnest}:`)));
  ck('the live tree, by contrast, produced no finding — so the green above is a measurement',
     live.findings.length === 0 && after.findings.length > 0);
}

// ── arm 2. the module introduces no dispatch ───────────────────────────────────────────

section('§2 the shared module is not a dispatch site');
{
  const real = dispatchFindings(MODULE_BASENAME, moduleSrc);
  ck(`no dispatch shape in lib/${MODULE_BASENAME} (${real.length} finding(s)`
     + `${real.length ? `: ${real.join('; ')}` : ''})`, real.length === 0);
}

section('§2 CONTROL: the same judgement fires on a module that DOES dispatch');
{
  const positive = [
    "const READER = { 'replay-preceding': replayPreceding, 'version-addressed': versioned };",
    'function pick(chain) {',
    "  switch (chain.slug) {",
    "    case 'ethereum-mainnet': return READER['replay-preceding'];",
    '  }',
    '}',
  ].join('\n');
  const negative = [
    '// one procedure, no dispatch: this is what the shared module looks like today',
    'export function containerVersion(file) { return readFileSync(file)[5]; }',
  ].join('\n');
  const pos = dispatchFindings('SYNTHETIC-POSITIVE', positive);
  const neg = dispatchFindings('SYNTHETIC-NEGATIVE', negative);
  ck(`the synthetic dispatching module produces findings (${pos.length}: ${pos.join('; ')})`,
     pos.length >= 3);
  ck(`the synthetic dispatch-free module produces none (${neg.length})`, neg.length === 0);
}

// ── arm 3. the shared exit-code path, observed on the real producers ───────────────────

section('§3 all five producers exit through the shared refusal path');
const producers = files.filter((x) => /^produce-/.test(x.file)).map((x) => x.file);
ck(`five producers found (${producers.length})`, producers.length === 5);
for (const p of producers) {
  // No arguments is a CONFIGURATION refusal on every one of them, and the shared
  // `dieOperational` maps that to 2. Read from the child's own status, not from a pipe.
  let code = null;
  try {
    await run(process.execPath, [join(CHAIN, p)], { cwd: dirname(CHAIN) });
    code = 0;
  } catch (e) {
    code = e.code ?? null;
  }
  ck(`${p} with no arguments exits 2 (got ${code})`, code === 2);
}

section('§3 CONTROL: the same path answers 1 on a source refusal, so 2 is not a constant');
{
  const probe = [
    `import { SOURCE_REFUSAL, refuseOperation, dieOperational } from `
    + `'${join(CHAIN, 'lib', MODULE_BASENAME)}';`,
    `dieOperational('control', refuseOperation(SOURCE_REFUSAL, 'a source would not answer'));`,
  ].join('\n');
  let code = null;
  try {
    await run(process.execPath, ['--input-type=module', '-e', probe]);
    code = 0;
  } catch (e) { code = e.code ?? null; }
  ck(`a source refusal through the shared path exits 1 (got ${code})`, code === 1);
  const probe2 = [
    `import { CONFIG_REFUSAL, refuseOperation, dieOperational } from `
    + `'${join(CHAIN, 'lib', MODULE_BASENAME)}';`,
    `dieOperational('control', refuseOperation(CONFIG_REFUSAL, 'this invocation is wrong'));`,
  ].join('\n');
  let code2 = null;
  try {
    await run(process.execPath, ['--input-type=module', '-e', probe2]);
    code2 = 0;
  } catch (e) { code2 = e.code ?? null; }
  ck(`and a configuration refusal exits 2 (got ${code2}), so the two are distinguished`,
     code2 === 2);
}

// ── arm 4. the classification file agrees with the code ────────────────────────────────

/** THE PREDICATE: where a stated consumer list and the code-derived one disagree. */
export function statedVersusDerived(stated, derived) {
  const out = [];
  for (const a of stated) {
    const got = derived.get(a.export);
    if (got === undefined) {
      out.push(`${a.export}: the classification names it and the module does not export it`);
      continue;
    }
    const want = [...a.consumers].sort().join(',');
    if (want !== got.join(',')) {
      out.push(`${a.export}: the classification states {${want}} and the code gives `
               + `{${got.join(',')}}`);
    }
  }
  for (const [b, chains] of derived) {
    if (!stated.some((a) => a.export === b)) {
      out.push(`${b}: exported with ${chains.length} consumer(s) and named by no `
               + `classification entry`);
    }
  }
  return out;
}

section('§4 ingestion-classification.json states the consumers the code has');
const doc = JSON.parse(readFileSync(CLASSIFICATION, 'utf8'));
{
  const d = statedVersusDerived(doc.abstractions, live.by);
  ck(`every stated consumer list matches the derivation (${d.length} disagreement(s)`
     + `${d.length ? `: ${d.join('; ')}` : ''})`, d.length === 0);
}

section('§4 CONTROL: a claimed consumer the code does not have is reported');
{
  const fabricated = doc.abstractions.map((a, i) => (i === 0
    ? { ...a, consumers: [...a.consumers, 'a-chain-that-does-not-exist'] } : a));
  const d = statedVersusDerived(fabricated, live.by);
  ck(`claiming one extra consumer on ${doc.abstractions[0].export} is reported `
     + `(${d.length} disagreement(s))`, d.length === 1);
  const dropped = doc.abstractions.slice(1);
  const d2 = statedVersusDerived(dropped, live.by);
  ck(`and dropping an entry for a real export is reported too (${d2.length})`, d2.length === 1);
}

// ── verdict ────────────────────────────────────────────────────────────────────────────

console.log('');
if (passed + failed !== BASE_ARMS) {
  console.error(`${HERE}: ${passed + failed} arm(s) ran and ${BASE_ARMS} are declared — an `
                + `arm that vanishes is not a pass`);
  process.exit(1);
}
if (failed > 0) {
  console.error(`${HERE}: ${failed} failure(s), ${passed} pass(es)`);
  process.exit(1);
}
console.log(`${HERE}: PASS — ${passed} arm(s) (as declared), every abstraction counted from `
            + `the code and every control watched failing`);
