#!/usr/bin/env node
//
// classification-selftest.mjs — DEL-7's `test_the_classification_can_be_wrong`.
//
//   node tools/chain/classification-selftest.mjs
//
// Exit codes: 0 every arm and every control held · 1 an arm or a control failed.
//
// ── WHAT THIS ARM IS FOR, IN ITS OWN WORDS ────────────────────────────────────────────
//
// DEL-7: "A component the classification calls network-agnostic, which a third chain then
// had to change, is reported as a FINDING. CONTROL: the arm is driven with a deliberately
// mis-classified component and reports it, so the check can refute the classification and
// not only confirm it."
//
// ING-7's own wording for the same thing: "a component that turns out to need a
// network-specific change is a finding recorded against the classification, not a silent
// edit."
//
// So this file's subject is `ingestion-classification.json`, and its job is to catch the
// classification being WRONG about the tree — in either direction. Every judgement is a
// pure function of the classification document and the code, and every one of them is run
// twice: once on the real pair, and once on a pair mutated to be wrong, where it must
// report. A judgement that has never been seen to fire is not a check.
//
// ── THE FOUR WAYS A CLASSIFICATION CAN BE WRONG, AND ALL FOUR ARE CHECKED ─────────────
//
//   R1  A component called NETWORK-AGNOSTIC that has no shared implementation at all.
//   R2  A component called NETWORK-AGNOSTIC whose consumers pass BEHAVIOURALLY different
//       arguments — a chain that had to change it — with no finding recorded against it.
//       And the mirror: a `behavioural` declaration with no divergence in the code, so the
//       declaration cannot be satisfied by writing a finding nobody earned.
//   R3  A component called NETWORK-SPECIFIC that two chains in fact share.
//   R4  A component called PER-PRESTATE-CLASS whose consumers are not one class. This is
//       the arm that bears on ING-7's prediction, and today it has no subject: the
//       classification declares zero per-class components. The arm therefore asserts the
//       zero AND is driven with a synthetic per-class claim, so the zero is a measurement.
//
// ── WHY THE CLASS MAP IS DERIVED AND NOT TRANSCRIBED ──────────────────────────────────
//
// R4 needs each chain's prestate class, and taking it from the classification document
// would let the document decide its own test. It is read from `PRESTATE_STRATEGY` in each
// `lib/<chain>-producer-facts.mjs` instead, and R0 asserts that the document's `byChain`
// map agrees with that derivation. The CXP-4 ledger's own `strategy` cell for `flow`
// disagrees with the producer, which is recorded as a finding in the document and is NOT
// reconciled here: the ledger feeds CXP-4's verdict and is not this milestone's to edit.

import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = 'tools/chain/classification-selftest.mjs';
const CHAIN = dirname(fileURLToPath(import.meta.url));
const LIB = join(CHAIN, 'lib');
const CLASSIFICATION = join(CHAIN, 'ingestion-classification.json');
const RUNTIME = 'producer-runtime.mjs';

/**
 * This suite's own assertion count, declared so the suite census in
 * `refusal-selftest.mjs` can cross-check it and so an arm cannot disappear silently.
 * Offline and host-independent, so the base IS the total. Five of the arms are one per
 * recorded finding, so adding a finding moves this figure deliberately.
 */
const BASE_ARMS = 24;

let passed = 0;
let failed = 0;
const ck = (what, ok) => {
  if (ok) { passed += 1; console.log(`  ok    ${what}`); } else {
    failed += 1; console.error(`  FAIL  ${what}`);
  }
};
const section = (t) => console.log(`\n${t}`);

// ── reading the tree ──────────────────────────────────────────────────────────────────

const norm = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').split('\n')
  .map((l) => l.replace(/(^|[^:])\/\/.*$/, '$1').replace(/\s+/g, ' ').trim())
  .filter((l) => l.length > 0).join('\n');

/** One chain's two spellings in this tree, folded. See abstraction-consumers-selftest. */
const CHAIN_ALIASES = new Map([['solana', 'sol']]);
const foldChain = (c) => CHAIN_ALIASES.get(c) ?? c;

/** Top-level declarations of a module, by name, as normalised text. */
export function declarations(src) {
  const lines = src.split('\n');
  const out = new Map();
  for (let i = 0; i < lines.length; i++) {
    const m = /^(?:export\s+)?(?:async\s+)?function\s+([A-Za-z0-9_$]+)/.exec(lines[i])
      ?? /^(?:export\s+)?const\s+([A-Za-z0-9_$]+)\s*=\s*(?:async\s*)?\(/.exec(lines[i]);
    if (!m) continue;
    let depth = 0;
    let started = false;
    const body = [];
    for (let j = i; j < lines.length; j++) {
      body.push(lines[j]);
      for (const ch of lines[j]) {
        if (ch === '{' || ch === '(') { depth += 1; started = true; } else
        if (ch === '}' || ch === ')') depth -= 1;
      }
      if (started && depth <= 0) break;
    }
    out.set(m[1], norm(body.join('\n')));
  }
  return out;
}

/** {chain -> {file -> source}} for the producers and the per-chain facts modules. */
function perChainSources() {
  const by = new Map();
  const put = (chain, file, src) => {
    if (!by.has(chain)) by.set(chain, new Map());
    by.get(chain).set(file, src);
  };
  for (const f of readdirSync(CHAIN).sort()) {
    const m = /^produce-([a-z0-9]+)-snapshot\.mjs$/.exec(f);
    if (m) put(foldChain(m[1]), f, readFileSync(join(CHAIN, f), 'utf8'));
  }
  for (const f of readdirSync(LIB).sort()) {
    const m = /^([a-z0-9]+)-producer-facts\.mjs$/.exec(f);
    if (m) put(foldChain(m[1]), `lib/${f}`, readFileSync(join(LIB, f), 'utf8'));
  }
  return by;
}

/** Each chain's `PRESTATE_STRATEGY`, read from its facts module. Aztec's is the
 *  unprefixed `lib/producer-facts.mjs`. */
export function strategiesFromCode() {
  const out = new Map();
  const read = (chain, file) => {
    const m = /^export const PRESTATE_STRATEGY = '([a-z-]+)'/m.exec(
      readFileSync(join(LIB, file), 'utf8'));
    if (m) out.set(chain, m[1]);
  };
  for (const f of readdirSync(LIB).sort()) {
    const m = /^([a-z0-9]+)-producer-facts\.mjs$/.exec(f);
    if (m) read(foldChain(m[1]), f);
  }
  read('aztec', 'producer-facts.mjs');
  return out;
}

/**
 * The argument text each consumer chain passes to `name`, normalised, by chain.
 * Only the FIRST call site per chain is taken: these are helpers each producer calls once
 * through a one-line wrapper, which is what makes a per-chain argument group meaningful.
 */
export function argumentGroups(name, sources) {
  const by = new Map();
  for (const [chain, files] of sources) {
    for (const [, src] of files) {
      const at = src.indexOf(`${name}(`);
      if (at < 0) continue;
      let depth = 0;
      let end = at + name.length;
      for (let i = at + name.length; i < src.length; i++) {
        if (src[i] === '(') depth += 1;
        else if (src[i] === ')') { depth -= 1; if (depth === 0) { end = i + 1; break; } }
      }
      by.set(chain, norm(src.slice(at + name.length, end)));
      break;
    }
  }
  return by;
}

/** Which option keys differ across the argument groups, by key. */
export function divergentOptionKeys(groups) {
  const keysOf = (text) => new Set([...text.matchAll(/([A-Za-z0-9_$]+)\s*:/g)].map((m) => m[1]));
  const valueOf = (text, key) => {
    const m = new RegExp(`\\b${key}\\s*:\\s*([^,}]*)`).exec(text);
    return m ? m[1].trim() : null;
  };
  const all = new Set();
  for (const t of groups.values()) for (const k of keysOf(t)) all.add(k);
  const divergent = new Set();
  for (const k of all) {
    const seen = new Set();
    for (const t of groups.values()) seen.add(valueOf(t, k));
    if (seen.size > 1) divergent.add(k);
  }
  return divergent;
}

// ── THE JUDGEMENT. One function, run on the real pair and on mutated ones. ────────────

export function classificationFindings(doc, tree) {
  const { sources, runtimeExports, strategies } = tree;
  const f = [];
  const findingAgainst = (component) =>
    (doc.findings ?? []).some((x) => x.against === component);

  for (const c of doc.components ?? []) {
    const agnostic = /network-agnostic/.test(c.classification);
    const specific = /^network-specific$/.test(c.classification);
    const perClass = /per-prestate-class/.test(c.classification);

    // R1 — a component called agnostic must HAVE a shared implementation, and every
    // export it names must really be exported.
    if (agnostic) {
      const named = c.extractedAs ?? [];
      if (named.length === 0) {
        f.push(`R1 ${c.component}: classified network-agnostic and names no shared `
               + `implementation (\`extractedAs\`), so nothing is shared`);
      }
      for (const e of named) {
        if (!runtimeExports.has(e)) {
          f.push(`R1 ${c.component}: classified network-agnostic and names \`${e}\`, `
                 + `which lib/${RUNTIME} does not export`);
        }
      }
    }

    // R2 — and if its consumers pass behaviourally different arguments, a chain had to
    // change it, and that must be RECORDED. Both directions are errors.
    if (agnostic && c.parameterVariation) {
      const groups = argumentGroups(c.parameterOf, sources);
      const texts = new Set(groups.values());
      const divergent = [...divergentOptionKeys(groups)].sort();
      const beyondProse = divergent.filter((k) => k !== 'note');
      if (c.parameterVariation === 'uniform' && texts.size > 1) {
        f.push(`R2 ${c.component}: declared \`uniform\` and its consumers pass `
               + `${texts.size} different argument group(s) — ${[...groups].map(
                 ([k, v]) => `${k}: ${v}`).join(' | ')}`);
      }
      if (c.parameterVariation === 'prose-only' && beyondProse.length > 0) {
        f.push(`R2 ${c.component}: declared \`prose-only\` and its consumers diverge on `
               + `{${beyondProse.join(',')}}, which is behaviour and not prose`);
      }
      if (c.parameterVariation === 'behavioural') {
        if (beyondProse.length === 0) {
          f.push(`R2 ${c.component}: declared \`behavioural\` and its consumers diverge on `
                 + `nothing beyond prose, so the declaration claims a network-specific `
                 + `change the code does not show`);
        }
        if (!findingAgainst(c.component)) {
          f.push(`R2 ${c.component}: a component classified network-agnostic needed a `
                 + `network-specific change (consumers diverge on {${beyondProse.join(',')}}) `
                 + `and NO finding is recorded against it — ING-7 requires a finding, not a `
                 + `silent edit`);
        }
      }
    }

    // R3 — a component called network-specific must not in fact be shared.
    if (specific) {
      const name = (c.declarations ?? [])[0];
      const texts = new Map();
      for (const [chain, files] of sources) {
        for (const [, src] of files) {
          const d = declarations(src).get(name);
          if (d !== undefined) {
            if (!texts.has(d)) texts.set(d, []);
            texts.get(d).push(chain);
            break;
          }
        }
      }
      const shared = [...texts.values()].filter((chains) => chains.length > 1);
      if (shared.length > 0) {
        f.push(`R3 ${c.component}: classified network-specific and \`${name}\` is declared `
               + `identically by ${shared.map((x) => `{${x.sort().join(',')}}`).join(' and ')}`);
      }
      for (const e of c.extractedAs ?? []) {
        if (runtimeExports.has(e)) {
          f.push(`R3 ${c.component}: classified network-specific and yet names the shared `
                 + `export \`${e}\``);
        }
      }
    }

    // R4 — a component called per-prestate-class must have one class of consumers.
    if (perClass) {
      const chains = c.consumers ?? [];
      const classes = [...new Set(chains.map((x) => strategies.get(x) ?? 'unknown'))].sort();
      if (classes.length !== 1) {
        f.push(`R4 ${c.component}: classified per-prestate-class and its consumers `
               + `{${chains.join(',')}} span ${classes.length} class(es) `
               + `{${classes.join(',')}} — the axis is not the class for this component`);
      }
    }
  }
  return f;
}

/** R0 — the document's class map against the code's. Separate, because R4 depends on it. */
export function classMapFindings(doc, strategies) {
  const f = [];
  const stated = doc.prestateClassOfEachSubject?.byChain ?? {};
  for (const [chain, want] of Object.entries(stated)) {
    const got = strategies.get(chain);
    if (got === undefined) {
      f.push(`R0 ${chain}: the classification states \`${want}\` and no facts module in the `
             + `tree declares a strategy for it`);
    } else if (got !== want) {
      f.push(`R0 ${chain}: the classification states \`${want}\` and the code declares `
             + `\`${got}\``);
    }
  }
  for (const [chain, got] of strategies) {
    if (!(chain in stated)) {
      f.push(`R0 ${chain}: declares \`${got}\` in code and the classification's class map `
             + `does not name it`);
    }
  }
  return f;
}

// ── the real pair ─────────────────────────────────────────────────────────────────────

const doc = JSON.parse(readFileSync(CLASSIFICATION, 'utf8'));
const sources = perChainSources();
const strategies = strategiesFromCode();
const runtimeSrc = readFileSync(join(LIB, RUNTIME), 'utf8');
const runtimeExports = new Set([
  ...[...runtimeSrc.matchAll(/^export\s+(?:async\s+)?function\s+([A-Za-z0-9_$]+)/gm)]
    .map((m) => m[1]),
  ...[...runtimeSrc.matchAll(/^export\s+const\s+([A-Za-z0-9_$]+)\s*=/gm)].map((m) => m[1]),
]);
const tree = { sources, runtimeExports, strategies };

section('§0 the class map is read from the code, not from the document');
ck(`the tree declares a prestate strategy for ${strategies.size} chain(s): `
   + `${[...strategies].map(([k, v]) => `${k}=${v}`).sort().join(', ')}`,
   strategies.size >= 6);
{
  const r0 = classMapFindings(doc, strategies);
  ck(`the document's class map agrees with the code (${r0.length} finding(s)`
     + `${r0.length ? `: ${r0.join('; ')}` : ''})`, r0.length === 0);
}

section('§0 CONTROL: a class map that disagrees with the code is reported');
{
  const wrong = structuredClone(doc);
  wrong.prestateClassOfEachSubject.byChain.eth = 'version-addressed';
  const r0 = classMapFindings(wrong, strategies);
  ck(`stating eth as \`version-addressed\` is reported (${r0.length}: ${r0.join('; ')})`,
     r0.length === 1 && /R0 eth/.test(r0[0]));
  const missing = structuredClone(doc);
  delete missing.prestateClassOfEachSubject.byChain.sui;
  ck('omitting a chain the code declares is reported too',
     classMapFindings(missing, strategies).some((x) => /R0 sui/.test(x)));
}

section('§1 the classification as written agrees with the tree');
const live = classificationFindings(doc, tree);
ck(`${doc.components.length} component(s) judged, ${live.length} finding(s) against the `
   + `classification${live.length ? `: ${live.join(' // ')}` : ''}`, live.length === 0);
ck('the classification declares at least one `behavioural` component, so R2\'s '
   + 'finding-required branch has a live subject',
   doc.components.some((c) => c.parameterVariation === 'behavioural'));
ck('…and that component has a finding recorded against it',
   doc.components.filter((c) => c.parameterVariation === 'behavioural')
     .every((c) => doc.findings.some((x) => x.against === c.component)));

section('§2 CONTROL: the finding R2 requires can be taken away, and R2 reports it');
{
  // THE CONTROL DEL-7 NAMES, with a REAL subject: container-reader discovery is classified
  // network-agnostic and Flow had to change it. Strip the finding — nothing else — and the
  // same judgement must report the component.
  const stripped = structuredClone(doc);
  const victim = doc.components.find((c) => c.parameterVariation === 'behavioural');
  stripped.findings = doc.findings.filter((x) => x.against !== victim.component);
  ck(`exactly one finding was removed (${doc.findings.length} -> `
     + `${stripped.findings.length})`, stripped.findings.length === doc.findings.length - 1);
  const f = classificationFindings(stripped, tree);
  ck(`R2 reports ${victim.component} with its finding removed (${f.length}: `
     + `${f.join(' // ') || 'none'})`,
     f.some((x) => x.startsWith('R2 ') && x.includes(victim.component)
                   && x.includes('NO finding is recorded')));
  ck('and the live document produced none, so §1\'s green is a measurement',
     live.length === 0 && f.length > 0);
}

section('§3 CONTROL: a `behavioural` declaration the code does not support is reported');
{
  // The mirror of §2: the declaration cannot be satisfied by writing a finding nobody
  // earned, because R2 checks the divergence against the call sites too.
  const flipped = structuredClone(doc);
  const u = flipped.components.find((c) => c.parameterVariation === 'uniform');
  u.parameterVariation = 'behavioural';
  const f = classificationFindings(flipped, tree);
  ck(`declaring ${u.component} \`behavioural\` when its consumers pass one argument group `
     + `is reported (${f.length}: ${f.join(' // ') || 'none'})`,
     f.some((x) => x.startsWith('R2 ') && x.includes(u.component)
                   && x.includes('the code does not show')));

  const demoted = structuredClone(doc);
  const b = demoted.components.find((c) => c.parameterVariation === 'behavioural');
  b.parameterVariation = 'uniform';
  const f2 = classificationFindings(demoted, tree);
  ck(`and demoting ${b.component} to \`uniform\` is reported, so the declaration is checked `
     + `in both directions (${f2.length})`,
     f2.some((x) => x.startsWith('R2 ') && x.includes(b.component)
                    && x.includes('declared `uniform`')));
}

section('§4 CONTROL: a deliberately MIS-CLASSIFIED component is reported');
{
  // (a) a genuinely per-chain component declared network-agnostic.
  const a = structuredClone(doc);
  const cost = a.components.find((c) => c.component === 'the cost vector');
  cost.classification = 'network-agnostic';
  delete cost.extractedAs;
  const fa = classificationFindings(a, tree);
  ck(`calling the cost vector network-agnostic is reported (${fa.length}: `
     + `${fa.join(' // ') || 'none'})`,
     fa.some((x) => x.startsWith('R1 the cost vector')));

  // (b) a genuinely shared component declared network-specific.
  const b = structuredClone(doc);
  const part = b.components.find((c) => c.component === 'the published execution partition');
  part.classification = 'network-specific';
  part.declarations = ['oneExecutionPerTransaction'];
  const fb = classificationFindings(b, tree);
  ck(`calling the shared execution partition network-specific is reported (${fb.length}: `
     + `${fb.join(' // ') || 'none'})`,
     fb.some((x) => x.startsWith('R3 the published execution partition')));

  // (c) THE ARM THAT BEARS ON ING-7'S PREDICTION. A component declared per-prestate-class
  //     whose consumers are not one class. The classification declares ZERO such
  //     components; this is how that zero is shown to be a measurement.
  ck('the classification declares no per-prestate-class component',
     doc.components.every((c) => !/per-prestate-class/.test(c.classification)));
  const c = structuredClone(doc);
  const shared = c.components.find((x) => x.component === 'the published execution partition');
  shared.classification = 'per-prestate-class';
  shared.consumers = ['eth', 'flow', 'starknet', 'sol', 'sui'];
  const fc = classificationFindings(c, tree);
  ck(`declaring the five-chain component per-prestate-class is reported, with the class `
     + `count (${fc.length}: ${fc.join(' // ') || 'none'})`,
     fc.some((x) => x.startsWith('R4 the published execution partition')
                    && /span 3 class\(es\)/.test(x)));
  const only = structuredClone(doc);
  const one = only.components.find((x) => x.component === 'the argv grammar');
  one.classification = 'per-prestate-class';
  one.consumers = ['eth', 'starknet'];
  ck('…and a component whose two consumers ARE one class is NOT reported by R4, so the arm '
     + 'distinguishes rather than always firing',
     !classificationFindings(only, tree).some((x) => x.startsWith('R4 ')));
}

section('§5 every finding names what it is against, and is attributable');
const SUBJECT_KINDS = ['component', 'ledger', 'instrument', 'milestone'];
for (const x of doc.findings) {
  ck(`finding \`${x.id}\` names its subject, its kind and what was measured`,
     typeof x.against === 'string' && x.against.length > 0
     && SUBJECT_KINDS.includes(x.subjectKind)
     && typeof x.whatHappened === 'string' && x.whatHappened.length > 40);
}
/** THE PREDICATE: a `component` finding must name a component that exists. */
export const danglingFindings = (d) => d.findings
  .filter((x) => x.subjectKind === 'component'
                 && !d.components.some((c) => c.component === x.against))
  .map((x) => x.id);
{
  const dangling = danglingFindings(doc);
  ck(`every component finding names a component that exists (${dangling.length} dangling`
     + `${dangling.length ? `: ${dangling.join(', ')}` : ''})`, dangling.length === 0);
  // CONTROL: the same predicate on a document whose component was renamed.
  const renamed = structuredClone(doc);
  const target = doc.findings.find((x) => x.subjectKind === 'component').against;
  renamed.components.find((c) => c.component === target).component = `${target} (renamed)`;
  ck(`renaming \`${target}\` out from under its finding is reported`,
     danglingFindings(renamed).length >= 1);
}

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
console.log(`${HERE}: PASS — ${passed} arm(s) (as declared); the classification was judged against the `
            + `code and every judgement was watched refuting a mis-classification`);
