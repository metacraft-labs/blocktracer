// producer-scan.mjs — WHICH TOOLS WRITE A PUBLISHED TRANSACTION ROW, AND DO THEY ALL
// STATE THE LIFTED FACTS THROUGH `producer-facts.mjs`?
//
// ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────────────────
//
// Six facts were lifted out of the reader and into `lib/producer-facts.mjs` so a second
// chain's producer could supply them as data. The lift reached the reader, the committed
// captures and THREE of the four tools that write a row. `ingest-range.mjs` was the
// fourth: it stated a row's `transactionFee` and stopped, so every row it wrote carried no
// `cost` and no `executions` and its provenance named no `recorder` and no
// `prestateStrategy`. Measured consequence — `ingest.nim` refuses the whole range by name
// (`[§5.2b S5-ROW-MEMBERS-REQUIRED] … carries no 'cost'`), exit 1, **zero objects
// written**. A freshly fetched range could not be published at all until it had been run
// through `migrate-chain-facts.mjs` first.
//
// Nothing said so. The three that were converted and the one that was not are four files
// in one directory, and the only thing that distinguished them was that somebody had
// edited three of them. That is the gap this module closes: the producers are DERIVED from
// the directory by what their source does, and each derived producer is then required to
// reach the lifted facts through the one module.
//
// ── HOW THE SUBJECT LIST IS BUILT, AND WHY IT IS NOT A LIST ───────────────────────────
//
// `Verification-Harness-Traps.md` §35: a source scan is only as wide as its subject list,
// and a hardcoded subject list cannot see a new file in the directory it claims to cover.
// So the subject list here is not written down — it is computed:
//
//   1. `readdirSync` the tools directory for `*.mjs`. That is the universe.
//   2. A file is a PRODUCER if its code (comments stripped) contains an object literal
//      with a `firstInBlock:` member. That member is the published row's own marker:
//      `Data-Contract.md` §5.2b lists it on `transactions[]`, the reader consumes it, and
//      no tool has a reason to write one except when building a row.
//   3. Everything else is reported as a NON-producer, by name, so the partition is
//      visible rather than implied.
//
// A new tool that writes rows is therefore covered on the day it is added, without anyone
// remembering to add it. The caller additionally compares the derived set against a
// declared roster, which is what makes a new producer arrive as a NAMED failure rather
// than as a silently larger green number.
//
// §35's second rule — ARM THE ENUMERATION — applies to `enumerateTools`: a lister that
// matches nothing satisfies "every producer states the facts" by leaving no producer to
// disagree. `scanProducers` therefore reports the sizes it worked over and the caller
// asserts them, and the selftest's control arm narrows the extension filter to `.mj` and
// requires the case to go red.
//
// ── THE RESIDUAL, STATED WHERE THE SCAN IS ────────────────────────────────────────────
//
// A source scan catches the tool that builds a row by hand. It cannot catch a tool that
// builds one through a helper it wrote itself under another name — the marker would be in
// the helper, the helper would be scanned, and the scan would be satisfied by the helper
// calling the module. That is the correct outcome for a SHARED helper and the wrong one
// for a private re-implementation, and nothing here distinguishes them. What makes the
// re-implementation expensive is that `producer-facts.mjs` is the only place the values
// are written down, so a second spelling has to restate them — and rule R4 below is the
// scan for exactly that restatement.
//
// ── NO MOCKS ──────────────────────────────────────────────────────────────────────────
//
// There are none to justify: every subject is a shipping file in this repository, read
// from disk. The selftest's control arms are copies of those real files with one edit,
// which is the opposite of a mock.

import { readdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

/** the Aztec producers' facts module — the first of them, and still the default subject */
export const FACTS_MODULE = './lib/producer-facts.mjs';

/**
 * THE SUFFIX THAT MAKES A FILE IN `lib/` A PRODUCER'S FACTS MODULE.
 *
 * ── WHY THIS IS A SET AND NOT ONE MODULE (2026-10-08) ─────────────────────────────────
 *
 * R1 used to be "every producer imports `./lib/producer-facts.mjs`", and that was right
 * while every producer in this directory captured one chain. Chain-Delivery DEL-5 added a
 * second: `produce-eth-snapshot.mjs`, Ethereum mainnet, whose recorder id is not
 * `aztec-avm`, whose trace schema is not `ctfs/v4`, whose prestate strategy is not
 * `hydrated-from-node` and whose cost vector has TWO dimensions rather than one. Under the
 * old rule that producer could only go green by importing the Aztec facts and therefore by
 * declaring itself an Aztec recorder — the rule would have REQUIRED a false statement, in
 * the one member census the reader refuses a snapshot over.
 *
 * `producer-facts.mjs`'s own header already said what to do instead, before this file
 * existed: "a second chain's recorder is a separate tool with a file like this one of its
 * own". So the rule is now that a producer reaches its facts through A facts module, and
 * the set of them is DERIVED from `lib/` by this suffix rather than written down — the same
 * argument the subject list itself rests on (§35: a hardcoded list cannot see a new file in
 * the directory it claims to cover). Nothing selects between the modules and nothing
 * imports two; there is no interface, no registry and no dispatch. The duplication is the
 * mechanism, and DEL-7 is the milestone allowed to extract a seam from it once there are
 * two real consumers to measure one against.
 *
 * THE ENUMERATION IS ARMED, for §35's second rule: `scanProducers` returns the set it
 * worked over, and an empty set would make R1 fire for every producer rather than for
 * none — loud, not silent — which the caller asserts.
 */
export const FACTS_MODULE_SUFFIX = 'producer-facts.mjs';

/**
 * Every per-producer facts module in `<dir>/lib`, as the specifier a producer would import
 * it by, sorted.
 *
 * @param {string} dir  the tools directory
 * @param {(d:string)=>string[]} list  `readdirSync` — a PARAMETER so a control arm can
 *                                     narrow it and watch R1 fire for every producer
 * @returns {string[]}
 */
export function factsModules(dir, list = (d) => readdirSync(d)) {
  return list(join(dir, 'lib'))
    .filter((f) => f.endsWith(FACTS_MODULE_SUFFIX))
    .sort()
    .map((f) => `./lib/${f}`);
}

/**
 * The member that marks an object literal as a published transaction row.
 * §5.2b names it on `transactions[]`; the reader consumes it.
 */
export const ROW_MARKER = 'firstInBlock';

/**
 * The member that marks an object literal as a snapshot's `provenance`, built from
 * scratch rather than carried forward from a snapshot already on disk.
 */
export const PROVENANCE_MARKER = "kind: 'live-capture'";

/**
 * THE LIFTED VALUES, as source spellings. A producer that contains one of these in its
 * CODE has restated a fact instead of importing it, which is the drift this campaign has
 * watched happen four times.
 *
 * Only values whose spelling is unambiguous are listed. `noir` and `mana` are deliberately
 * ABSENT: both are ordinary words in this tree's paths and identifiers, so a scan for them
 * reports where they were written rather than whether they were restated, and a rule with
 * a false-positive rate is a rule people learn to edit around.
 *
 * MATCHED AS A WHOLE QUOTED LITERAL, never as a substring. Measured on the first run of
 * this scan: a substring match reported all three of `capture-chain`, `follow-chain` and
 * `ingest-range` for `aztec-avm`, and in every case the text was
 * `--runtime <path-to-aztec-avm-runtime>` inside a usage message — the CLI's own flag
 * documentation, which restates nothing. "Restated" means the source writes the VALUE, so
 * that is what the rule matches.
 *
 * THE SET COVERS EVERY FACTS MODULE, not just the first one. DEL-5's Ethereum values are
 * below the Aztec ones, chosen by the same filter: `evm` is deliberately ABSENT for exactly
 * the reason `noir` and `mana` are — it is an ordinary word in this tree's paths, flags and
 * usage messages, so a scan for it would report where it was written rather than whether it
 * was restated. The rest are unambiguous tokens that occur nowhere except as the value.
 */
export const RESTATED_VALUES = Object.freeze([
  'aztec-avm', 'ctfs/v4', 'hydrated-from-node', 'avm-source-positions/1', 'FeeJuice',
  'ethereum-evm', 'ctfs/v5', 'replay-preceding', 'evm-disassembly',
  'evm-disassembly-positions/1', 'evm-instructions/1', 'evm-call-frames/1',
]);

/**
 * Comments out, string BODIES out of the brace skeleton.
 *
 * Two views over one pass, character-for-character aligned with the source so an offset in
 * either names the same place in the other:
 *
 *   `code`     — comments replaced by spaces, string contents kept. What the content rules
 *                read, because `kind: 'live-capture'` is a content rule about a string.
 *   `skeleton` — the same, plus string and template contents replaced by spaces. What the
 *                brace matcher walks, so a `{` inside a string or a regex cannot move the
 *                nesting depth.
 *
 * @param {string} src
 * @returns {{code:string, skeleton:string}}
 */
export function views(src) {
  const code = [];
  const skel = [];
  const push = (c, s) => { code.push(c); skel.push(s); };
  let i = 0;
  const n = src.length;
  const blank = (c) => (c === '\n' ? '\n' : ' ');
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === '/' && d === '/') {                       // line comment
      while (i < n && src[i] !== '\n') { push(blank(src[i]), blank(src[i])); i++; }
      continue;
    }
    if (c === '/' && d === '*') {                       // block comment
      const end = src.indexOf('*/', i + 2);
      const stop = end === -1 ? n : end + 2;
      while (i < stop) { push(blank(src[i]), blank(src[i])); i++; }
      continue;
    }
    if (c === "'" || c === '"' || c === '`') {          // string / template
      push(c, c); i++;
      while (i < n) {
        const q = src[i];
        if (q === '\\') { push(q, blank(q)); i++;
                          if (i < n) { push(src[i], blank(src[i])); i++; } continue; }
        if (q === c) { push(q, q); i++; break; }
        push(q, blank(q)); i++;
      }
      continue;
    }
    push(c, c); i++;
  }
  return { code: code.join(''), skeleton: skel.join('') };
}

/**
 * The object literal enclosing `at`, as a source range.
 *
 * Walks left over `skeleton` to the unmatched `{`, then right to its partner. Returns
 * `null` when the braces do not balance, which the caller reports rather than swallows —
 * an unbalanced skeleton means the stripper met something it does not model, and a scan
 * that silently returns "no findings" in that case is the failure mode §4 is about.
 *
 * @param {string} skeleton
 * @param {number} at
 * @returns {{from:number, to:number}|null}
 */
export function enclosingLiteral(skeleton, at) {
  let depth = 0;
  let from = -1;
  for (let i = at; i >= 0; i--) {
    const c = skeleton[i];
    if (c === '}') depth++;
    else if (c === '{') { if (depth === 0) { from = i; break; } depth--; }
  }
  if (from === -1) return null;
  depth = 0;
  for (let i = from; i < skeleton.length; i++) {
    const c = skeleton[i];
    if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return { from, to: i + 1 }; }
  }
  return null;
}

/** every index at which `needle` occurs in `hay` */
function indicesOf(hay, needle) {
  const out = [];
  let i = hay.indexOf(needle);
  while (i !== -1) { out.push(i); i = hay.indexOf(needle, i + 1); }
  return out;
}

/** the 1-based line of a character offset */
export function lineAt(src, offset) {
  let n = 1;
  for (let k = 0; k < offset && k < src.length; k++) if (src[k] === '\n') n++;
  return n;
}

/**
 * Every `*.mjs` directly in `dir`, sorted, excluding the suite files that TEST the
 * producers rather than being one. The exclusion is by name suffix and is returned
 * separately so it is reported rather than silently applied.
 *
 * @param {string} dir
 * @param {string} ext  the extension filter — a PARAMETER so the selftest's vacuity arm
 *                      can narrow it and watch the case go red (§35's second rule)
 * @returns {{tools:string[], suites:string[]}}
 */
export function enumerateTools(dir, ext = '.mjs') {
  const all = readdirSync(dir).filter((f) => f.endsWith(ext)).sort();
  return {
    tools: all.filter((f) => !f.endsWith(`-selftest${ext}`)),
    suites: all.filter((f) => f.endsWith(`-selftest${ext}`)),
  };
}

/**
 * THE WHOLE RULE, as one function, so the selftest's control arms call exactly what its
 * green arm calls (§30). Findings are returned rather than printed.
 *
 * @param {string} dir   the tools directory
 * @param {(name:string)=>string} read  source text by file name — a PARAMETER so a control
 *                                      arm can substitute a mutated copy of one real file
 *                                      without writing to the repository
 * @param {string} ext
 * @param {string[]} facts  the per-producer facts modules R1 ranges over — a PARAMETER for
 *                          the same reason `ext` is one, so a control arm can empty it and
 *                          watch R1 fire for every producer instead of for none
 * @returns {{producers:string[], others:string[], suites:string[], rows:number,
 *            provenances:number, facts:string[],
 *            findings:{file:string, rule:string, line:number, what:string}[]}}
 */
export function scanProducers(dir, read = (f) => readFileSync(join(dir, f), 'utf8'),
                              ext = '.mjs', facts = factsModules(dir)) {
  const { tools, suites } = enumerateTools(dir, ext);
  const producers = [];
  const others = [];
  const findings = [];
  let rows = 0;
  let provenances = 0;

  for (const f of tools) {
    const src = read(f);
    const { code, skeleton } = views(src);
    // A ROW LITERAL IS `firstInBlock:` INSIDE A LITERAL THAT ALSO KEYS `txHash:`, and the
    // second half is not decoration. `ingest-range.mjs` reports a run by counting the rows
    // that are first in their block, so its SUMMARY object carries a `firstInBlock:` member
    // too — `firstInBlock: snap.transactions.filter(…).length`. The first version of this
    // scan called that a transaction row and required a cost vector on it. A published row
    // is keyed by its transaction hash; a tally is not.
    const marks = indicesOf(code, `${ROW_MARKER}:`).filter((at) => {
      const span = enclosingLiteral(skeleton, at);
      return span !== null && code.slice(span.from, span.to).includes('txHash:');
    });
    if (marks.length === 0) { others.push(f); continue; }
    producers.push(f);

    // R1 — the facts are reached through a facts module of this producer's own.
    if (!facts.some((m) => code.includes(m))) {
      findings.push({ file: f, rule: 'R1', line: 1,
                      what: `writes a transaction row and imports none of the facts `
                          + `modules in lib/ (${facts.length === 0 ? 'there are none'
                                               : facts.join(', ')})` });
    }

    // R2 — every row literal states the cost vector and the execution partition, by call.
    for (const at of marks) {
      rows++;
      const span = enclosingLiteral(skeleton, at);
      if (span === null) {
        findings.push({ file: f, rule: 'R2', line: lineAt(src, at),
                        what: `a ${ROW_MARKER} member with no enclosing object literal — `
                            + `the brace skeleton did not balance, so this file was not scanned` });
        continue;
      }
      const body = code.slice(span.from, span.to);
      for (const [member, call] of [['cost', 'costVectorForRow('],
                                    ['executions', 'executionsForRow(']]) {
        if (!body.includes(`${member}: ${call}`)) {
          findings.push({ file: f, rule: 'R2', line: lineAt(src, at),
                          what: `a transaction row states no \`${member}: ${call}…)\`` });
        }
      }
    }

    // R3 — every provenance built from scratch names the recorder and the prestate strategy.
    for (const at of indicesOf(code, PROVENANCE_MARKER)) {
      provenances++;
      const span = enclosingLiteral(skeleton, at);
      if (span === null) {
        findings.push({ file: f, rule: 'R3', line: lineAt(src, at),
                        what: 'a provenance literal with no enclosing object literal' });
        continue;
      }
      const body = code.slice(span.from, span.to);
      for (const [member, from] of [['recorder', '{ ...RECORDER }'],
                                    ['prestateStrategy', 'PRESTATE_STRATEGY']]) {
        if (!body.includes(`${member}: ${from}`)) {
          findings.push({ file: f, rule: 'R3', line: lineAt(src, at),
                          what: `a live-capture provenance states no \`${member}: ${from}\`` });
        }
      }
    }

    // R4 — and none of them restates a lifted value instead of importing it.
    for (const v of RESTATED_VALUES) {
      for (const q of ["'", '"', '`']) {
        for (const at of indicesOf(code, `${q}${v}${q}`)) {
          findings.push({ file: f, rule: 'R4', line: lineAt(src, at),
                          what: `restates the lifted value ${JSON.stringify(v)} — `
                              + `${FACTS_MODULE} is where it is written down` });
        }
      }
    }
  }

  findings.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1
                           : a.rule < b.rule ? -1 : a.rule > b.rule ? 1 : a.line - b.line));
  return { producers, others, suites, rows, provenances, facts, findings };
}
