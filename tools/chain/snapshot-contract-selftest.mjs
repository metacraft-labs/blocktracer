// snapshot-contract-selftest.mjs — does the READER agree with §5, MECHANICALLY?
//
//   node tools/chain/snapshot-contract-selftest.mjs
//
// ── WHAT THIS IS FOR ──────────────────────────────────────────────────────────────────
//
// `Data-Contract.md` §5 is the document a producer for a chain nobody here has run writes
// against. `src/blocktracer/chain/ingest.nim` is the reader that consumes what they write.
// Until this file the only thing holding the two together was that somebody had read both
// and agreed with themselves, and the measured result of that was:
//
//   * §5 named NINE member paths. The reader consumed 117 over 22 containers — so 108
//     were unnamed, across `provenance`, `window`, `blocks[]`, `captures[]`,
//     `transactions[]` and five sidecars, and 19 of them were reached by unguarded
//     bracket access, which RAISES in Nim rather than answering null. Those are the
//     figures of the GAP, measured on 2026-09-17 when it closed; the census has grown
//     since and §1 and §2 below PRINT its current size rather than any comment restating
//     one.
//
//     THE NINE ARE the member paths §5 stated as REQUIREMENTS: §5.2's six-row table
//     (`format`, `provenance`, `window`, `counts`, `blocks`, `transactions`) plus the three
//     its prose makes mandatory (`provenance.chain`, `reason`, `refusalReason`). The reading
//     is stated because §5 admits three: only §5.2's table is six and makes the gap 111;
//     every member §5 mentions at all is twelve, adding `container` as a permission,
//     `counts.accountedFor` as version history and `outcome` as a legacy column header.
//     Every site that derives from this figure — here, `lib/reader-contract.mjs`, the
//     `Justfile` and `ci.yml` — uses the nine-reading, and 108 follows from it alone.
//   * `provenance.l1ChainId` was one of the unnamed, and the real follower's own mainnet
//     capture omitted it. The producer this repository ships wrote a snapshot the reader
//     this repository ships crashed on, and no fixture could see it because all of them
//     carried the member.
//   * In the other direction `counts` was REQUIRED by §5.2 and consumed by nobody, so the
//     tally whose stated purpose is "a partial ingest is detectable" had no detector.
//
// So the consumed set is EXTRACTED from the reader (`lib/reader-contract.mjs`) and compared
// against §5's census (`snapshot-contract.json`) for EQUALITY in both directions. Neither
// side is derived from the other, which is what makes the comparison say anything.
//
// ── THE CONTROL, AND WHY IT IS THE ARM THAT MATTERS ───────────────────────────────────
//
// A checker written from the reader's own output can restate the reader and report green
// forever. §6 therefore MUTATES each side in turn — a member deleted from the census, a
// member deleted from the reader, an access form flipped, a rule citation removed — and
// requires each mutation to be caught, by the arm written for it. A check whose failure
// mode has never been observed is indistinguishable from `return true`.
//
// ── NO MOCKS ──────────────────────────────────────────────────────────────────────────
//
// Per the workspace policy every mock must be justified in the test's header: there are
// none here to justify. The subjects are the repository's own two files, read from disk.
// The mutation arms in §6 are copies of those real files with one edit, which is the
// opposite of a mock: the point is that the thing under test is the shipping artifact.

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { extractReaderContract, flatten, readerShapeViolations, pathDefaultLiterals,
         chainVocabularyLiterals, nilAccessViolations, NIL_ACCESS_SHAPES,
         REQUIRED, OPTIONAL } from './lib/reader-contract.mjs';
import { RECORDER, PRESTATE_STRATEGY, POSITION_LANGUAGE, POSITION_STREAM_SCHEMA,
         costVectorForRow, executionsForRow } from './lib/producer-facts.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const CONTRACT = join(root, 'tools', 'chain', 'snapshot-contract.json');
const READER = join(root, 'src', 'blocktracer', 'chain', 'ingest.nim');
const RULES_NIM = join(root, 'src', 'blocktracer', 'chain', 'contract_rules.nim');

let asserted = 0;
let failed = 0;
function ck(what, cond) {
  asserted++;
  if (!cond) { failed++; console.error(`  FAILED  ${what}`); }
  else console.log(`  ok      ${what}`);
}
function test(name) { console.log(`\n${name}`); }

const contract = JSON.parse(readFileSync(CONTRACT, 'utf8'));
const readerSrc = readFileSync(READER, 'utf8');
const rulesNim = readFileSync(RULES_NIM, 'utf8');

/**
 * §5.1's path defaults, taken from the contract so the walk resolves the reader's
 * constants the way the reader does. A default the contract does not state cannot be
 * substituted, and the path it names then comes back unresolved — which is the report
 * this deliverable wants rather than a silent pass.
 */
const CONST_DEFAULTS = {
  DefaultArtifactResolutionPath: contract.containers['sidecar:artifact-resolution'].defaultPath,
  DefaultInstructionsDir: contract.containers['sidecar:instructions'].defaultPath,
  DefaultPositionsDir: contract.containers['sidecar:positions'].defaultPath,
  DefaultCallTraceDir: contract.containers['sidecar:calltrace'].defaultPath,
  DefaultSourcesDir: contract.containers['sidecar:sources'].defaultPath,
};

const walk = (src) => extractReaderContract(src, 'snapshot.json', 'snapshot', CONST_DEFAULTS);

/** every (container, member) the census names, and every one the reader consumes */
function censusMembers(c) {
  const out = new Map();
  for (const [id, body] of Object.entries(c.containers)) {
    for (const [m, e] of Object.entries(body.members ?? {})) out.set(`${id}.${m}`, { id, m, ...e });
  }
  return out;
}
function readerMembers(consumed) {
  const out = new Map();
  for (const [id, members] of Object.entries(flatten(consumed))) {
    for (const [m, access] of Object.entries(members)) out.set(`${id}.${m}`, { id, m, access });
  }
  return out;
}

/** the whole comparison, as ONE function, so the control arms below call the same rule */
function compare(contractDoc, readerText) {
  const problems = [];
  const { consumed, paths, diagnostics, outsideReads } = walk(readerText);
  const spec = censusMembers(contractDoc);
  const seen = readerMembers(consumed);

  for (const [key, e] of seen) {
    const s = spec.get(key);
    if (!s) { problems.push(`reader-only: ${key} is consumed (${e.access}) and §5 names no such member`); continue; }
    if (s.access !== e.access) problems.push(`access: ${key} — §5 records '${s.access}', the reader uses '${e.access}'`);
    if (s.required === false && e.access === REQUIRED) {
      problems.push(`the l1ChainId shape: ${key} is OPTIONAL to §5 and reached by an unguarded subscript`);
    }
    if (s.required === true && e.access === OPTIONAL && !s.enforcedBy) {
      problems.push(`unenforced: ${key} is required by §5, reached with '{}', and names no rule that refuses its absence`);
    }
    if (s.enforcedBy && !contractDoc.rules[s.enforcedBy]) {
      problems.push(`dangling: ${key} names enforcing rule '${s.enforcedBy}', which §5 does not state`);
    }
  }
  for (const [key, s] of spec) {
    if (seen.has(key)) continue;
    if (s.consumedBy) continue;
    problems.push(`spec-only: §5 names ${key} and no reader path consumes it`);
  }
  for (const d of diagnostics) problems.push(`unresolved: ${d}`);
  return { problems, paths, spec, seen, outsideReads };
}

/**
 * §5.4's boundary, over one walk's path census. `wide` is the axis, so the narrow reading
 * this check used to have is still runnable and its blind spot is demonstrable rather
 * than asserted — §6j runs both over the same planted read.
 */
function producerInternalOffences(paths, internal, wide) {
  const containerIdFor = (name) => 'sidecar:' + name.replace(/\.json$/, '');
  const out = [];
  for (const p of paths) {
    for (const name of internal) {
      if (p.expr.includes(`"${name}"`)) out.push(`${p.line}: ${p.expr} (literal)`);
      else if (wide && p.container && p.container === containerIdFor(name)) {
        out.push(`${p.line}: ${p.expr} -> ${p.container} (named by a variable)`);
      }
    }
  }
  return out;
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§1 the walk resolves the reader whole — an unresolved read makes every count below a floor');
const live = compare(contract, readerSrc);
{
  ck(`the walk reports no unresolved read — ${live.problems.filter((p) => p.startsWith('unresolved')).length}`,
     live.problems.filter((p) => p.startsWith('unresolved')).length === 0);
  // ANTI-VACUITY. An extractor that resolved nothing would agree with an empty census
  // perfectly. The floors are deliberately well under the measured values so an ordinary
  // edit does not redden them, and well over zero so an emptied walk cannot pass.
  ck(`the census names at least 100 members — ${live.spec.size}`, live.spec.size >= 100);
  ck(`the reader consumes at least 100 members — ${live.seen.size}`, live.seen.size >= 100);
  ck(`at least 20 containers are walked — ${new Set([...live.seen.values()].map((e) => e.id)).size}`,
     new Set([...live.seen.values()].map((e) => e.id)).size >= 20);
  ck(`the reader reaches at least 10 members by unguarded subscript — `
     + `${[...live.seen.values()].filter((e) => e.access === REQUIRED).length}`,
     [...live.seen.values()].filter((e) => e.access === REQUIRED).length >= 10);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§2 every member the reader consumes appears in §5, and every member §5 names is consumed');
{
  ck(`the two sets agree, member for member — ${live.problems.length} problem(s)`,
     live.problems.length === 0);
  if (live.problems.length) for (const p of live.problems) console.error(`    ${p}`);
  // Stated as an EQUALITY rather than two containments, because the two directions catch
  // different defects and a check that only reported one would have been green on `counts`.
  ck(`…and it is an equality — ${live.seen.size} consumed vs ${live.spec.size} named`,
     live.seen.size === live.spec.size);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§3 the rules §5 states are the rules the reader cites');
{
  const stated = Object.keys(contract.rules).sort();
  // The reader cites through `contract_rules.nim`'s constants, which are `cite(...)` forced
  // through `const` — so an id that is not in the table stops the BUILD. What this arm adds
  // is the other direction: a rule stated and cited by nobody.
  const citedIds = [...rulesNim.matchAll(/cite\("([^"]+)"\)/g)].map((m) => m[1]);
  const constNames = [...rulesNim.matchAll(/^\s{2}(Rule[A-Za-z]+)\* = cite\("([^"]+)"\)/gm)]
    .map((m) => ({ name: m[1], id: m[2] }));
  ck(`every rule §5 states has a citation constant — ${stated.length} rule(s)`,
     stated.every((id) => citedIds.includes(id)));
  ck(`…and every citation constant names a rule §5 states`,
     citedIds.every((id) => stated.includes(id)));
  ck(`the rule table is not empty and not a stub — ${stated.length} >= 20`, stated.length >= 20);

  // AND THE CONSTANTS ARE USED. A citation constant nothing references is a rule the reader
  // does not actually cite, and the compile-time check cannot see the difference: `cite`
  // succeeds either way. This is what makes "the reader names the rule" a claim about
  // `ingest.nim` rather than about `contract_rules.nim`.
  const unused = constNames.filter(({ name }) => !new RegExp(`\\b${name}\\b`).test(readerSrc));
  ck(`every citation constant is referenced by the reader — ${unused.length} unused`,
     unused.length === 0);
  if (unused.length) console.error(`    ${unused.map((u) => `${u.name} (${u.id})`).join('\n    ')}`);

  // Every rule the reader cites sits in front of a refusal, not beside one.
  const citingRaises = [...readerSrc.matchAll(/raise newException\((?:ValueError|IOError),\s*\n?\s*(Rule[A-Za-z]+)/g)]
    .map((m) => m[1]);
  ck(`every citation is the first thing a refusal says — ${citingRaises.length} refusal(s) cite a rule`,
     citingRaises.length >= 20);
  const namesCited = new Set(citingRaises);
  const declaredButNotRaised = constNames.filter(({ name }) => !namesCited.has(name));
  ck(`…and no rule is cited anywhere but in a refusal — ${declaredButNotRaised.length}`,
     declaredButNotRaised.length === 0);
  if (declaredButNotRaised.length) console.error(`    ${declaredButNotRaised.map((u) => u.name).join(', ')}`);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§4 no path in the snapshot tree is resolved by convention alone');
{
  const byName = live.paths.filter((p) => p.named === 'by-name');
  const byConvention = live.paths.filter((p) => p.named === 'convention');
  const named = live.paths.filter((p) => p.named === 'row-member' || p.named === 'row-member-or-default');
  // §5.1's rule, and the ONE exception it states.
  ck(`exactly one path is read by name — ${byName.map((p) => p.expr).join(', ')}`,
     byName.length === 1 && byName[0].expr === '"snapshot.json"');
  ck(`no path is located by convention alone — ${byConvention.length}`, byConvention.length === 0);
  if (byConvention.length) console.error(`    ${byConvention.map((p) => `${p.line}: ${p.expr}`).join('\n    ')}`);
  ck(`every other path is named by the row or the snapshot that owns it — ${named.length}`,
     named.length === live.paths.length - 1 && named.length >= 5);
  // AND THE NAMING MEMBER IS ONE §5 NAMES. A path named by a member the census does not
  // carry is the convention wearing a variable.
  const unnamed = named.filter((p) => p.member && !live.spec.has(p.member));
  ck(`…and every naming member is one §5 names — ${unnamed.length} unknown`, unnamed.length === 0);
  if (unnamed.length) console.error(`    ${unnamed.map((p) => `${p.line}: ${p.member}`).join('\n    ')}`);
  // Every container the census declares a default for is one the reader actually reaches.
  //
  // THIS ARM CARRIED A HARD-CODED `id === 'container' ||` UNTIL 2026-09-17, which is the
  // only kind of exemption worth nothing: it excused the one default that was unreachable
  // by construction — `transactions[].container` is required of every traced row and taken
  // by an unguarded subscript, so a row that names none is refused, never defaulted — and
  // in excusing it, it hid that. The census no longer states a default for `container`, so
  // the arm has no exception to make, and a default added for a container the reader never
  // opens now fails here instead of being written into the exemption.
  const defaulted = Object.entries(contract.containers).filter(([, b]) => b.defaultPath);
  ck(`every default §5.1 states belongs to a container the reader opens — ${defaulted.length}`,
     defaulted.length >= 5
     && defaulted.every(([id]) => live.paths.some((p) => p.container === id)));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§5 the reader touches no producer-internal state');
{
  // §5.4: cursors, coverage ledgers, range directories and leases are the producer's
  // bookkeeping and no reader path may reach them. The dynamic half of this is the
  // byte-identity arm in `tests/tchainsnapshot.nim`; this is the static half, and it is
  // the half that can name the file a new read would have opened.
  const internal = contract.producerInternal.names;
  ck(`the boundary names at least four kinds of producer bookkeeping — ${internal.length}`,
     internal.length >= 4);
  // THE SWEEP LOOKS AT BOTH THE EXPRESSION AND THE RESOLVED CONTAINER, because the
  // expression alone misses the shape the sidecars are actually written in. A read that
  // reaches its file through a VARIABLE — `var covRel = t{"coverage"}.getStr`, then
  // `if covRel.len == 0: covRel = "coverage.json"`, then `cfg.snapshotDir / covRel` — has
  // an `expr` of just `covRel`, with the producer's filename nowhere in it. The walk does
  // resolve it: `p.container` comes back `sidecar:coverage`. Keying on `expr` alone made
  // this sweep blind to exactly the naming convention §5.1 required of every other
  // sidecar, so the one path shape the reader is supposed to use was the one shape the
  // boundary check could not see.
  const offending = producerInternalOffences(live.paths, internal, true);
  ck(`no snapshot-relative path the reader opens is one of them — ${offending.length}`,
     offending.length === 0);
  if (offending.length) console.error(`    ${offending.join('\n    ')}`);
  // …and the ledger's own token appears nowhere in the reader, which catches a read added
  // through a path expression this walk cannot see.
  ck(`the coverage ledger's format token appears nowhere in the reader`,
     !readerSrc.includes(contract.producerInternal.ledgerFormat));
  // AND THE READS THAT ARE NOT SNAPSHOT-RELATIVE AT ALL, which the path census cannot
  // see by construction: it only classifies `cfg.snapshotDir / …`. A read of the
  // producer's bookkeeping by absolute path, or through a variable the walk resolves to
  // no snapshot path, would be invisible above and is enumerated here instead. The
  // reader has exactly one, and it is a read of the OUTPUT tree — `assertSlugAvailable`
  // asking what this tree already publishes under a slug.
  ck(`the reader parses exactly one file that is not snapshot-relative — `
     + `${live.outsideReads.map((r) => `${r.line}:${r.via}`).join(', ') || 'none'}`,
     live.outsideReads.length === 1 && live.outsideReads[0].via === 'cur');
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§6 the check BITES — each side mutated in turn, each caught by the arm written for it');
{
  // ── 6a. A MEMBER DELETED FROM THE SPEC. This is the control the milestone names: if
  // removing a member from §5 does not fail the check, the check is restating the reader
  // rather than measuring the spec.
  const c1 = JSON.parse(readFileSync(CONTRACT, 'utf8'));
  delete c1.containers['snapshot.provenance'].members.l1ChainId;
  const r1 = compare(c1, readerSrc);
  ck('a member removed from §5 is caught, naming it',
     r1.problems.some((p) => p.startsWith('reader-only') && p.includes('l1ChainId')));

  // The same, on a member reached only through the accessor proc's SIBLING path, so the
  // arm is not resting on one extraction rule.
  const c1b = JSON.parse(readFileSync(CONTRACT, 'utf8'));
  delete c1b.containers['snapshot.transactions[].recording'].members.steps;
  ck('a member removed from §5 deep in a nested container is caught too',
     compare(c1b, readerSrc).problems.some((p) => p.includes('recording.steps')));

  // ── 6b. A MEMBER ADDED TO THE SPEC THAT NOTHING READS. The other direction, which is
  // the one `counts` sat in for as long as §5.2 has existed.
  const c2 = JSON.parse(readFileSync(CONTRACT, 'utf8'));
  c2.containers['snapshot'].members.epoch = { required: true, access: 'optional', holds: 'nothing' };
  ck('a member §5 names and nothing consumes is caught, naming it',
     compare(c2, readerSrc).problems.some((p) => p.startsWith('spec-only') && p.includes('epoch')));

  // ── 6c. THE `l1ChainId` SHAPE ITSELF: an optional member reached by a bracket. This is
  // the defect the whole deliverable came from, so it has its own arm rather than being
  // covered by the access comparison.
  const r3 = compare(contract,
    readerSrc.replace('"l1ChainId": provOrNull("l1ChainId")', '"l1ChainId": prov["l1ChainId"]'));
  ck('an OPTIONAL member reached by an unguarded subscript is caught by name',
     r3.problems.some((p) => p.includes('l1ChainId shape')));

  // ── 6d. A REQUIRED MEMBER WHOSE GUARD IS REMOVED — the access forms disagree.
  const r4 = compare(contract, readerSrc.replace('let caps = snap{"captures"}', 'let caps = snap["captures"]'));
  ck('an access form that moves is caught, naming both sides',
     r4.problems.some((p) => p.startsWith('access') && p.includes('captures')));

  // ── 6e. A MEMBER THE READER STOPS CONSUMING. The direction that catches a reader
  // simplification silently orphaning a member of the published contract.
  const r5 = compare(contract, readerSrc.replace('t{"rootsAnyAgree"}', 'newJNull()'));
  ck('a member the reader stops consuming is caught',
     r5.problems.some((p) => p.startsWith('spec-only') && p.includes('rootsAnyAgree')));

  // ── 6f. A REQUIRED MEMBER READ WITH `{}` AND NO RULE BEHIND IT.
  const c6 = JSON.parse(readFileSync(CONTRACT, 'utf8'));
  delete c6.containers['snapshot'].members.counts.enforcedBy;
  ck('a required member with a safe subscript and no enforcing rule is caught',
     compare(c6, readerSrc).problems.some((p) => p.startsWith('unenforced') && p.includes('counts')));

  // ── 6g. A CITATION THAT NAMES A RULE THE TABLE DOES NOT STATE.
  const c7 = JSON.parse(readFileSync(CONTRACT, 'utf8'));
  c7.containers['snapshot'].members.format.enforcedBy = 'S5-NOT-A-RULE';
  ck('a member citing a rule §5 does not state is caught',
     compare(c7, readerSrc).problems.some((p) => p.startsWith('dangling')));

  // ── 6h. A PATH PUT BACK ON THE CONVENTION. §4's arm, shown refusing.
  const conventional = walk(readerSrc.replace(
    '      var insRel = t{"instructions"}.getStr\n'
    + '      if insRel.len == 0: insRel = DefaultInstructionsDir / (txHash & ".json")\n'
    + '      let insFile = cfg.snapshotDir / insRel\n',
    '      let insFile = cfg.snapshotDir / "instructions" / txHash & ".json"\n'));
  ck('a sidecar returned to a bare conventional path is caught by the path census',
     conventional.paths.some((p) => p.named === 'convention'));

  // ── 6i. AND THE WALK ITSELF, EMPTIED. If `extractReaderContract` is handed a reader it
  // cannot resolve, every containment arm above is vacuously satisfied — so the floors in
  // §1 are shown refusing rather than merely stated.
  const emptied = walk('import std/json\nproc nothing() = discard\n');
  ck('a reader the walk resolves nothing in produces an empty consumed set',
     emptied.consumed.size === 0);
  ck('…and the census then reports every member as spec-only rather than agreeing',
     compare(contract, 'import std/json\nproc nothing() = discard\n')
       .problems.filter((p) => p.startsWith('spec-only')).length === live.spec.size);

  // ── 6j. A PRODUCER-INTERNAL READ NAMED BY A VARIABLE — §5's boundary sweep, and the
  // one arm that has to be run BOTH WAYS, because the point is not that the wide sweep
  // catches it but that the narrow one does not. The planted read is in the exact shape
  // §5.1 requires of a sidecar: the row names the file and a default is the fallback. Its
  // `expr` is the bare variable, so the producer's filename appears nowhere in it.
  const planted = readerSrc.replace(
    '      var srcRel = t{"sourceBundles"}.getStr\n',
    '      var covRel = t{"coverage"}.getStr\n'
    + '      if covRel.len == 0: covRel = "coverage.json"\n'
    + '      let covFile = cfg.snapshotDir / covRel\n'
    + '      let cov = parseJson(readFile(covFile))\n'
    + '      discard cov\n'
    + '      var srcRel = t{"sourceBundles"}.getStr\n');
  const plantedPaths = walk(planted).paths;
  const wide = producerInternalOffences(plantedPaths, contract.producerInternal.names, true);
  const narrow = producerInternalOffences(plantedPaths, contract.producerInternal.names, false);
  ck(`the planted read resolves to the ledger's container — `
     + `${plantedPaths.filter((p) => p.container === 'sidecar:coverage').map((p) => p.expr).join(',') || 'NOT RESOLVED'}`,
     plantedPaths.some((p) => p.container === 'sidecar:coverage'));
  ck(`the WIDE sweep catches it — ${wide.length}`, wide.length === 1);
  ck(`…and the NARROW sweep, which is what this check used to be, MISSES it — ${narrow.length}`,
     narrow.length === 0);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§8 the reader uses no access shape the walk cannot see, and spells no path default');
{
  // WHY A BAN RATHER THAN A MODEL. `lib/reader-contract.mjs` enumerates nine access shapes
  // it resolves WRONG — eight of them by MISSING a member the reader really consumes, which
  // makes the equality check above compare two short lists and agree, and one by INVENTING
  // a member out of a triple-quoted string. None is present in the reader, so §5.2b is
  // complete; nothing held that in place until this section. Modelling the nine would be a
  // Nim front end. Banning them is one rule apiece and turns the same drift red.
  const shapes = readerShapeViolations(readerSrc);
  ck(`the reader uses none of the nine unmodelled shapes — ${shapes.length}`
     + (shapes.length ? `: ${shapes.map((s) => `${s.line} ${s.shape}`).join(', ')}` : ''),
     shapes.length === 0);

  // AND EACH OF THE NINE IS SHOWN FIRING. A lint whose population is zero and whose
  // failure has never been observed is `return true` with a comment on it.
  const PLANTS = [
    ['getOrDefault-by-literal', '  let x = snap.getOrDefault("epoch")'],
    ['two-variable-for', '  for k, v in snap.pairs():\n    discard v["epoch"]'],
    ['json-node-parameter-helper', 'proc helper(n: JsonNode) =\n  discard n["epoch"]'],
    ['element-then-member', '  let x = snap["blocks"][0]["epoch"]'],
    ['template-body', 'template shortcut(n: untyped): untyped =\n  n["epoch"]'],
    ['anonymous-proc', '  let f = proc (n: JsonNode): JsonNode =\n    n["epoch"]'],
    ['subscript-split-across-lines', '  let x = snap[\n    "epoch"]'],
    ['whole-object-to', '  let x = snap.to(Snapshot)'],
    ['triple-quoted-string', '  let doc = """ snap["epoch"] """'],
  ];
  const caught = [];
  for (const [shape, code] of PLANTS) {
    const v = readerShapeViolations(readerSrc + '\n' + code + '\n');
    if (v.some((x) => x.shape === shape)) caught.push(shape);
    else console.error(`    NOT CAUGHT: ${shape} — ${JSON.stringify(code)}`);
  }
  ck(`each of the nine shapes is caught when planted — ${caught.length} of ${PLANTS.length}`,
     caught.length === PLANTS.length);

  // …AND EACH SHAPE IS A SET OF SPELLINGS, WHICH IS THE PART THE NINE PLANTS ABOVE DID NOT
  // HOLD. The nine plants above are nine SPELLINGS, one per shape, and passing them is
  // compatible with a rule that bans punctuation rather than a shape. Measured: a review
  // planted a genuinely new member at a real row site and this whole suite stayed green
  // (rc 0, 117 vs 117) through three spellings of shapes 1 and 8 that all compile and all
  // work — `t.getOrDefault "k"` (command syntax), `getOrDefault(t, "k")` and `to(t, T)`
  // (call syntax) — because `/\.getOrDefault\(\s*"/` and `/\.to\(/` both require a dot AND
  // a parenthesis. So the two shapes that have more than one spelling are asserted per
  // SPELLING. The other seven have one apiece and are covered by the arm above.
  //
  // WHICH OF THE EIGHT ARE REACHABLE, measured rather than assumed, because a ban on a form
  // the compiler rejects is not protection and should not be counted as any. Compiled one
  // file per spelling on Nim 2.2.10 on 2026-09-17: SIX compile — both `dot-paren`, both
  // `dot-command`, both `call-paren`. The two `call-command` forms (`getOrDefault t, "k"`
  // and `to t, T`) do NOT: Nim rejects command syntax in an expression position with
  // `invalid indentation`, and forcing them into a statement gives a type mismatch. They
  // are banned anyway — the rule costs nothing and Nim's parser is not this suite's
  // invariant — but they are belt-and-braces and the reachable set is six.
  const SPELLINGS = [
    ['getOrDefault-by-literal', 'dot-paren',    '  let x = snap.getOrDefault("epoch")'],
    ['getOrDefault-by-literal', 'dot-command',  '  let x = snap.getOrDefault "epoch"'],
    ['getOrDefault-by-literal', 'call-paren',   '  let x = getOrDefault(snap, "epoch")'],
    ['getOrDefault-by-literal', 'call-command', '  let x = getOrDefault snap, "epoch"'],
    ['whole-object-to', 'dot-paren',            '  let x = snap.to(Snapshot)'],
    ['whole-object-to', 'dot-command',          '  let x = snap.to Snapshot'],
    ['whole-object-to', 'call-paren',           '  let x = to(snap, Snapshot)'],
    ['whole-object-to', 'call-command',         '  let x = to snap, Snapshot'],
  ];
  const missedSpelling = SPELLINGS.filter(([shape, , code]) =>
    !readerShapeViolations(readerSrc + '\n' + code + '\n').some((x) => x.shape === shape));
  ck('…and every SPELLING of the two shapes Nim spells more than one way is caught — '
     + `${SPELLINGS.length - missedSpelling.length} of ${SPELLINGS.length}`
     + (missedSpelling.length ? `; missed ${missedSpelling.map((s) => `${s[0]}/${s[1]}`).join(', ')}` : ''),
     missedSpelling.length === 0);

  // …AND THE NARROW RULE, WHICH IS WHAT THESE TWO USED TO BE, MISSES SIX OF THE EIGHT.
  // Without this arm the one above is a green whose subject cannot be shown to have moved:
  // the widening is the work, so the narrow reading has to be here to be seen failing. It
  // catches the two DOT-PAREN spellings and nothing else. Of the SIX spellings that compile
  // it therefore misses four, and three of those four are the ones a review actually
  // planted past it while this suite printed a pass. Same idiom as §6's WIDE/NARROW pair.
  const narrowMisses = (shape, code) => {
    for (const line of (readerSrc + '\n' + code + '\n').split('\n')) {
      if (shape === 'getOrDefault-by-literal' && /\.getOrDefault\(\s*"/.test(line)) return false;
      if (shape === 'whole-object-to' && /\.to\(/.test(line)) return false;
    }
    return true;
  };
  const evadedNarrow = SPELLINGS.filter(([shape, , code]) => narrowMisses(shape, code));
  ck('…and the NARROW rule, which is what these two used to be, misses six of the eight — '
     + `${evadedNarrow.map((s) => `${s[0]}/${s[1]}`).join(', ')}`,
     evadedNarrow.length === 6
     && evadedNarrow.every(([, spelling]) => spelling !== 'dot-paren'));

  // §5.1'S DEFAULTS, AND WHY THE CLAIM NEEDED A CHECK RATHER THAN A SENTENCE. §5.1 says the
  // defaults are single-sourced as data and "the reader spells none of them itself, so a
  // reader that looked somewhere else would fail its own build". That was FALSE when it was
  // written: `ingest.nim` open-coded `srcRel = "sources" / (txHash & ".json")` beside a
  // `DefaultSourcesDir` it never used, and nothing could see it because the literal and the
  // constant resolve to the same path. The sentence is right; the reader was wrong.
  const defaults = Object.entries(contract.containers)
    .filter(([, b]) => b.defaultPath).map(([, b]) => b.defaultPath);
  const spelled = pathDefaultLiterals(readerSrc, defaults);
  ck(`no §5.1 default is spelled as a path literal in the reader — ${spelled.length}`
     + (spelled.length ? `: ${spelled.map((s) => `${s.line} ${s.default}`).join(', ')}` : ''),
     spelled.length === 0);
  ck(`…and the rule ranges over all five defaults — ${defaults.join(', ')}`,
     defaults.length === 5);
  ck('…shown firing: the literal put back is caught, naming it',
     pathDefaultLiterals(readerSrc.replace('srcRel = DefaultSourcesDir /', 'srcRel = "sources" /'),
                         defaults).some((s) => s.default === 'sources'));
  // …and the reader still REFERENCES every one of them, so "spells none of them" is not
  // satisfied by a reader that resolves none of them either.
  const constNamesForDefaults = ['DefaultArtifactResolutionPath', 'DefaultInstructionsDir',
    'DefaultPositionsDir', 'DefaultCallTraceDir', 'DefaultSourcesDir'];
  const unusedDefault = constNamesForDefaults.filter((n) => !readerSrc.includes(n));
  ck(`every default constant is used by the reader — ${unusedDefault.length} unused`,
     unusedDefault.length === 0);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§9 the reader names no chain, and the scan that says so is shown able to fail');
{
  // WHAT THIS HOLDS, AND WHY IT IS NOT COVERED BY THE CENSUS ABOVE. §5.3's six facts are
  // read out of the snapshot now, and §2 would notice if one stopped being read. What §2
  // cannot notice is a SEVENTH arriving — a literal naming a chain, a VM, a fee token or an
  // ecosystem language, written somewhere the census has no member for. One had already
  // arrived exactly that way: `"schema": "avm-source-positions/1"`, a VM name in a
  // published wire token, which no reading of the six would have found.
  //
  // The vocabulary is DATA (`chainVocabulary` in the census) rather than a regex in a
  // script, for the reason the rule ids are: a check may only cite what the contract
  // states. `contract_rules.nim` parses the same block at COMPILE time, so an empty or
  // malformed term list stops the reader's build rather than producing a scan that matches
  // nothing.
  const vocab = contract.chainVocabulary;
  ck(`the ban ranges over a stated set of files — ${vocab.scope.length}`,
     Array.isArray(vocab.scope) && vocab.scope.length >= 5
     && vocab.scope.includes(contract.reader));

  // …AND THE SCOPE CANNOT BE OUTGROWN, WHICH IS THE OTHER DIRECTION AND THE ONE THAT WAS
  // MISSING. The arm above says the stated set cannot SHRINK unnoticed. It said nothing
  // about the reader GROWING past it: a new module under `src/blocktracer/chain/` holding
  // the literal seventh-constant shape was added by a reviewer and this suite reported
  // "5 files, 0 violations" and rc 0 — a clean result about a file it had never opened,
  // which is the same vacuity the scope exists to prevent, one directory over.
  //
  // The reader's own directory is the boundary the ban is about, so it is DERIVED here
  // rather than restated: every `.nim` beside the reader must be in the declared scope,
  // and the failure names the files, because "the scope is incomplete" is not actionable
  // and "chain_facts.nim is not in the ban's scope" is.
  const readerDir = dirname(contract.reader);
  const beside = readdirSync(join(root, readerDir))
    .filter((f) => f.endsWith('.nim')).map((f) => `${readerDir}/${f}`).sort();
  const outOfScope = beside.filter((f) => !vocab.scope.includes(f));
  ck(`…and it covers every .nim beside the reader — ${beside.length} file(s), `
     + `${outOfScope.length} outside the ban`
     + (outOfScope.length ? `: ${outOfScope.join(', ')}` : ''),
     outOfScope.length === 0);
  ck(`the vocabulary is not empty and every term names its category — ${vocab.terms.length} term(s), `
     + `${new Set(vocab.terms.map((t) => t.kind)).size} kind(s)`,
     vocab.terms.length >= 30
     && vocab.terms.every((t) => t.term && t.kind)
     && ['chain', 'vm', 'language', 'token'].every((k) => vocab.terms.some((t) => t.kind === k)));

  let totalViolations = 0, totalComments = 0;
  const offenders = [];
  for (const rel of vocab.scope) {
    const src = readFileSync(join(root, rel), 'utf8');
    const r = chainVocabularyLiterals(src, vocab.terms);
    totalViolations += r.violations.length;
    totalComments += r.commentOccurrences;
    for (const v of r.violations) offenders.push(`${rel}:${v.line} ${v.term} (${v.kind})`);
  }
  ck(`no file in scope names a chain, a VM, a fee token or a language in CODE — ${totalViolations}`,
     totalViolations === 0);
  if (offenders.length) console.error(`    ${offenders.join('\n    ')}`);

  // THE COMMENT HALF IS REPORTED, NOT BANNED, AND THE FIGURE IS MEASURED HERE SO NO PROSE
  // ANYWHERE CARRIES IT. The reader's comments record which chain a decision was measured
  // on and why; a comment cannot reach a published object. Banning them would delete the
  // reasoning and buy nothing. What the arm holds is that the count is NON-ZERO — because
  // a zero here would mean the scan had stopped seeing the file at all, which is exactly
  // how a "must not contain" check goes quietly vacuous.
  ck(`…and the comments that do name one are counted rather than banned — ${totalComments}`,
     totalComments > 0);

  // ── EACH ATTACK, PLANTED, WITH WHAT IT IS STATED TO DO ────────────────────────────
  //
  // "Banned outright" about a regex that is not banned outright is the failure this
  // library has already made once, with three spellings walked past a nine-shape ban that
  // documented itself as covering them. So the scan is ATTACKED here, form by form, and
  // the forms it does NOT catch are asserted to be missed rather than left unmentioned: a
  // residual that is measured is a residual, and one that is only described is a hope.
  const READER_SRC = readerSrc;
  const ATTACKS = [
    ['plain literal',                '  let x = "aztec"',                     true],
    ['adjacent-literal concatenation', '  let x = "azt" & "ec"',              true],
    ['concatenation across lines',   '  let x = "azt" &\n    "ec"',           true],
    ['concatenation past a comment', '  let x = "azt" & # why\n    "ec"',     true],
    // THE TWO FORMS THE SPLICE DID NOT SEE, and they sat INSIDE the class this bullet
    // claims: the first rule required the quotes to touch the `&`, so parentheses walked
    // past it, and it joined only quoted operands, so a named one walked past it too.
    // Both compile, both print `aztec`, and the scan said nothing about either.
    ['parenthesised concatenation',  '  let x = ("azt") & ("ec")',            true],
    ['concatenation with a NAMED operand',
     '  let suffixEc = "ec"\n  let x = "azt" & suffixEc',                     true],
    ['…and with the name on the left',
     '  let prefixAzt = "azt"\n  let x = prefixAzt & "ec"',                   true],
    ['a const alias',                '  const AztecSlug = "aztec"',           true],
    ['a case change',                '  let x = "AZTEC"',                     true],
    ['an identifier, not a string',  '  let aztecFee = 1',                    true],
    ['a camel hump in suffix position', '  let feeInGas = 1',                 true],
    ['a term glued to a camelCase word', '  let gasUsed = 1',                 true],
    ['a hyphenated token',           '  let x = "aztec-avm"',                 true],
    ['a slashed wire token',         '  let x = "avm-source-positions/1"',    true],
    ['a fee unit',                   '  let x = "mana"',                      true],
    ['a fee token',                  '  let x = "FeeJuice"',                  true],
    ['an ecosystem language',        '  let x = "noir"',                      true],
    ['a chain nobody here has run',  '  let x = "solana"',                    true],
    // THE SIX TERMS A REVIEWER MEASURED MISSING. One apiece for the two the absence was
    // concretely wrong about: `wasm` is a VM name and this workspace ships three Wasm
    // recorders, and `ink` is Polkadot's language while `polkavm`, its VM, was already
    // banned — so the pair was half-covered.
    ['a VM this workspace ships three recorders for', '  let x = "wasm"',     true],
    ['the language whose VM was already banned', '  let x = "ink"',           true],
    ['a rollup nobody here has run', '  let x = "zksync"',                    true],
    // The FALSE POSITIVE the camel-hump rule buys, stated as one rather than hidden: an
    // all-caps word whose interior spells a term. Measured at zero over every file in
    // scope (the green arm above), which is why the rule is worth its cost.
    ['all-caps prose whose interior spells a term (a FALSE POSITIVE)',
     '  let x = "THE MANAGER SAID SO"',                                       true],
    // ── AND THE FOUR IT CANNOT SEE ──────────────────────────────────────────────────
    ['a trailing comment (deliberately not a violation)',
     '  discard 1 # aztec is the chain this was measured on',                 false],
    ['a doc comment (deliberately not a violation)',
     '  ## aztec is the chain this was measured on',                          false],
    ['a character escape (RESIDUAL: no text scan reaches it)',
     '  let x = "azt\\x65c"',                                                 false],
    ['a name synthesised from a char (RESIDUAL: same)',
     '  let x = chr(97) & "ztec"',                                            false],
    // THE OTHER HALF OF THE BOUNDARY RULE, planted so the limit is measured rather than
    // only described. The clause that rejects a match followed by a lowercase letter is
    // what lets a correct reader write `manage`, `gasoline` and `suite`; the same clause
    // is why a term with a lowercase tail walks past. There is no version of the rule
    // that has one without the other, so this is a residual and not a bug.
    ['a term with a lowercase tail (RESIDUAL: the manage/gasoline rule, the other way)',
     '  let x = "aztecnet"',                                                  false],
    ['a term inside a longer lowercase word (RESIDUAL: same clause)',
     '  let x = "myaztecchain"',                                              false],
    // AND THE ACCUMULATED FORM. The splice reads one expression because that is where a
    // concatenation's operands sit; spread over two statements they are a program a text
    // scan would have to interpret.
    ['a name accumulated over statements (RESIDUAL: not one expression)',
     '  var s = "azt"\n  s.add "ec"',                                         false],
  ];
  const misbehaved = ATTACKS.filter(([, code, expect]) =>
    (chainVocabularyLiterals(READER_SRC + '\n' + code + '\n', vocab.terms)
      .violations.length > 0) !== expect);
  const caught = ATTACKS.filter(([, , e]) => e).length;
  ck(`each planted form behaves exactly as stated — ${ATTACKS.length - misbehaved.length} of `
     + `${ATTACKS.length} (${caught} caught, ${ATTACKS.length - caught} stated as missed)`
     + (misbehaved.length ? `; ${misbehaved.map((a) => a[0]).join('; ')}` : ''),
     misbehaved.length === 0);
  // Stated separately, because "22 of 29 behave as stated" is satisfied by a scan that
  // catches nothing and a table that expects nothing. The missed count is pinned EXACTLY
  // rather than bounded: a residual that quietly grows is how a ban stops being one.
  ck(`…and the caught half is the majority of the table — ${caught} of ${ATTACKS.length}`,
     caught >= 22 && ATTACKS.length - caught === 7);

  // …AND THE NARROW BOUNDARY RULE, WHICH IS WHAT THIS WAS FIRST WRITTEN AS, MISSES THE
  // IDENTIFIER FORM. Without this arm the green above is a pass whose subject cannot be
  // shown to have moved. The narrow rule is a plain non-alphanumeric boundary on both
  // sides; it catches every quoted form and walks straight past `let aztecFee = 1`, which
  // is the evasion one token wide. Same WIDE/NARROW idiom as §6j and §8.
  const narrowFinds = (code) => {
    for (const { term } of vocab.terms) {
      const re = new RegExp('(?<![A-Za-z0-9])' + term + '(?![A-Za-z0-9])', 'i');
      for (const line of code.split('\n')) if (re.test(line)) return true;
    }
    return false;
  };
  const narrowMissed = ['  let aztecFee = 1', '  let feeInGas = 1', '  let gasUsed = 1']
    .filter((code) => !narrowFinds(code));
  ck(`…and the NARROW boundary rule misses all three camelCase forms — ${narrowMissed.length} of 3`,
     narrowMissed.length === 3
     && narrowFinds('  let x = "aztec"'));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§10 the lift is faithful: the producer states exactly what the reader used to spell');
{
  // WHY THIS EQUALITY IS HERE RATHER THAN NOWHERE. Six values moved out of the reader and
  // into the producer. "Moved" is a claim about two trees and the strong
  // evidence for it is the byte-identity recipe — `just byte-identity <pre-lift-ref>`,
  // which rebuilds both producers and diffs every published object. That recipe cannot run
  // inside a suite, so what runs here is the other half: the values the producer now states
  // are compared against the literals the reader used to spell, written out below.
  //
  // THE LITERALS BELOW ARE THE POINT. They are a second, independent copy — the pre-lift
  // reader's own text, transcribed once — so a change to `producer-facts.mjs` turns this
  // red and has to be made deliberately in two places. That is the opposite of the usual
  // rule against two copies: here the two copies ARE the assertion, because the claim is
  // that one equals the other.
  ck(`the recorder identity is the one the reader spelled — ${RECORDER.id}`,
     RECORDER.id === 'aztec-avm');
  ck(`the trace schema is the one the reader spelled — ${RECORDER.traceSchema}`,
     RECORDER.traceSchema === 'ctfs/v4');
  ck(`the position language is the one the reader spelled — ${POSITION_LANGUAGE}`,
     POSITION_LANGUAGE === 'noir');
  ck(`the position-stream schema token is the one the reader spelled — ${POSITION_STREAM_SCHEMA}`,
     POSITION_STREAM_SCHEMA === 'avm-source-positions/1');
  ck(`the prestate strategy is the one the reader spelled — ${PRESTATE_STRATEGY}`,
     PRESTATE_STRATEGY === 'hydrated-from-node');
  {
    const v = costVectorForRow('0xdeadbeef');
    ck(`the cost vector is the single entry the reader constructed — ${JSON.stringify(v)}`,
       v.length === 1 && v[0].name === 'transactionFee' && v[0].used === '0xdeadbeef'
       && v[0].limit === '' && v[0].price === '' && v[0].unit === 'mana'
       && v[0].token === 'FeeJuice' && v[0].refundable === false);
    // AND AN ABSENT FIGURE IS AN EMPTY ONE, which is what `t{"transactionFee"}.getStr`
    // answered before the lift. A row whose receipt carried no fee published `used: ""`,
    // and it still does — a lift that turned that into `undefined` would drop the member
    // and be refused by the very rule that requires it.
    ck('…and a row with no fee figure states an empty one, as the reader did',
       costVectorForRow(undefined)[0].used === '');
  }
  ck(`the execution partition is the single selector the reader spelled — `
     + `${JSON.stringify(executionsForRow())}`,
     executionsForRow().length === 1 && executionsForRow()[0].selector === 'public'
     && executionsForRow()[0].reason === undefined);
  // …AND THE PRESTATE STRATEGY IS IN THE CLOSED SET IT IS NOW DRAWN FROM. The lift is only
  // faithful if the value it moved is one the new refusal admits; a producer stating a
  // value its own reader refuses is a lift that published nothing.
  ck(`…and it is one of §1.4's six — ${contract.prestateStrategies.tokens.length} token(s)`,
     contract.prestateStrategies.tokens.includes(PRESTATE_STRATEGY)
     && contract.prestateStrategies.tokens.length === 6);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
//  §11 — THE FIXTURE TEMPLATE IS DRIVEN FROM THE CENSUS, SO IT CANNOT QUIETLY FALL BEHIND
// ═══════════════════════════════════════════════════════════════════════════════════════
//
// `conformance-kit/template/` is what a recorder for a chain nobody has run yet copies:
// conforming trees in §5.1's layout, with every required member present and every optional
// one shown both present and absent. A template maintained BESIDE the census is a second
// document, and the failure mode is silent — a member added to §5 that the template never
// exercises leaves a recorder writing against an example that is short of the contract, and
// nothing goes red. So the population is the census itself, and this is the arm that
// reddens.
//
// The two directions are different failures and both are checked:
//   * a census member no template tree exercises — the template has fallen behind §5;
//   * a template member the census does not name — a typo, or a member somebody invented.
//
// WHAT "SHOWN ABSENT" MEANS, STATED RATHER THAN ASSUMED. A member is shown absent when some
// template tree does not carry it at that path: either an instance of its container lacks
// it, or that tree has no instance of the container at all. The second half is not a
// weakening — a tree with no `captures` IS the shape a reader must cope with — and the
// first is recorded separately below, because an instance-level witness is the stronger one
// and the count of them is worth watching.
const TEMPLATE = join(root, 'conformance-kit', 'template');

/** Walk one template tree against the census; per container, the member sets it carries. */
function templateInstances(treeDir, contractDoc) {
  const instances = new Map();   // containerId -> [Set<memberName>]
  const record = (id, node) => {
    if (!instances.has(id)) instances.set(id, []);
    instances.get(id).push(new Set(Object.keys(node)));
  };
  const childId = (id, m) =>
    contractDoc.containers[`${id}.${m}[]`] ? `${id}.${m}[]`
    : contractDoc.containers[`${id}.${m}`] ? `${id}.${m}` : null;
  // §5.1's resolution, read out of the census: the row names the file, and a row that
  // names none resolves to the stated default. A `defaultPath` that is a file is the
  // snapshot's own sidecar; one that is a directory is a row's, keyed by the row's key.
  //
  // A STATED RESIDUAL, because half of this is a SECOND implementation of a rule the
  // reader already implements, and the whole point of the census is that a rule has one
  // place. What was closed: the row KEY is no longer hardcoded here — it is
  // `snapshot.transactions[].rowKey` in the census, so a chain whose rows are keyed by
  // something other than `txHash` moves this walk by moving the contract. What was NOT
  // closed: the resolution RULE itself — named member wins, else the default; a default
  // that is a file is the snapshot's and one that is a directory is a row's — is spelled
  // both here and in `ingest.nim`. It cannot be derived from the data as the data stands,
  // and it lives in the TEST rather than in the shipped kit, so a drift shows up as this
  // suite going red rather than as a recorder being misled. It is a second place for a
  // rule to be wrong, and that is recorded rather than argued away.
  const rowKeyMember = contractDoc.containers['snapshot.transactions[]'].rowKey;
  const sidecarPath = (treeDir, named, defaultPath, rowKey) => {
    if (typeof named === 'string' && named.length > 0) return join(treeDir, named);
    if (!defaultPath) return null;
    return defaultPath.endsWith('.json')
      ? join(treeDir, defaultPath)
      : join(treeDir, defaultPath, `${rowKey}.json`);
  };
  const visit = (id, node, txHash) => {
    if (node === null || typeof node !== 'object' || Array.isArray(node)) return;
    record(id, node);
    const body = contractDoc.containers[id];
    if (!body) return;
    const hash = id === 'snapshot.transactions[]' ? node[rowKeyMember] : txHash;
    for (const [m, v] of Object.entries(node)) {
      const cid = childId(id, m);
      if (cid) {
        if (Array.isArray(v)) { for (const e of v) visit(cid, e, hash); }
        else visit(cid, v, hash);
      }
    }
    // the sidecars this container names, whether by a member of its own or by default
    for (const [sid, sbody] of Object.entries(contractDoc.containers)) {
      if (!sid.startsWith('sidecar:') || !sbody.namedBy) continue;
      const owner = sbody.namedBy.slice(0, sbody.namedBy.lastIndexOf('.'));
      if (owner !== id) continue;
      const member = sbody.namedBy.slice(sbody.namedBy.lastIndexOf('.') + 1);
      const p = sidecarPath(treeDir, node[member], sbody.defaultPath, hash);
      if (p && existsSync(p)) visit(sid, JSON.parse(readFileSync(p, 'utf8')), hash);
    }
  };
  visit('snapshot', JSON.parse(readFileSync(join(treeDir, 'snapshot.json'), 'utf8')), null);
  return instances;
}

/** The whole coverage rule, as ONE function, so the control arms call the same rule. */
function templateCoverage(trees, contractDoc) {
  const perTree = trees.map((t) => templateInstances(t, contractDoc));
  const spec = censusMembers(contractDoc);
  const missing = [];        // a census member no tree exercises
  const neverAbsent = [];    // an optional member no tree shows absent
  const unknown = new Set(); // a template member the census does not name
  let instanceWitnessed = 0;
  let instances = 0;
  for (const per of perTree) {
    for (const [id, sets] of per) {
      instances += sets.length;
      for (const set of sets) {
        for (const m of set) if (!spec.has(`${id}.${m}`)) unknown.add(`${id}.${m}`);
      }
    }
  }
  for (const [key, e] of spec) {
    const { id, m } = e;
    let present = 0, total = 0, treeWithout = 0, lackingInstance = 0;
    for (const per of perTree) {
      const sets = per.get(id) ?? [];
      if (sets.length === 0) { treeWithout++; continue; }
      for (const set of sets) {
        total++;
        if (set.has(m)) present++; else lackingInstance++;
      }
    }
    if (present === 0) { missing.push(`${key} (${total} instance(s) across the template)`); continue; }
    // A member the CONTRACT can require of one row and not another — `container` on a
    // traced row, `refusalReason` on an untraced one — has to be shown both ways too, or
    // the template only ever demonstrates one side of the condition.
    const mayBeAbsent = e.required !== true || Boolean(e.onRows);
    if (lackingInstance > 0) instanceWitnessed++;
    if (mayBeAbsent && lackingInstance === 0 && treeWithout === 0) neverAbsent.push(key);
  }
  return { missing, neverAbsent, unknown: [...unknown], instanceWitnessed, instances,
           census: spec.size };
}

test('§11 the fixture template exercises the whole census, and the check is shown able to fail');
{
  const trees = readdirSync(TEMPLATE)
    .map((n) => join(TEMPLATE, n))
    .filter((p) => statSync(p).isDirectory() && existsSync(join(p, 'snapshot.json')))
    .sort();
  // ANTI-VACUITY FIRST. Every arm below reports a set difference, and a template with no
  // trees in it makes all of them empty — the shape of green a coverage check must not be
  // able to reach.
  ck(`the template ships at least two snapshot trees — ${trees.length}`, trees.length >= 2);
  const cov = templateCoverage(trees, contract);
  ck(`the walk reaches at least 60 container instances — ${cov.instances}`,
     cov.instances >= 60);
  ck(`…over the whole census — ${cov.census} member(s)`, cov.census >= 100);
  ck(`every member §5 names is exercised by the template — ${cov.missing.length} missing`
     + (cov.missing.length ? `: ${cov.missing.slice(0, 6).join('; ')}` : ''),
     cov.missing.length === 0);
  ck(`every member a conforming tree may omit is shown absent — ${cov.neverAbsent.length}`
     + (cov.neverAbsent.length ? `: ${cov.neverAbsent.slice(0, 6).join('; ')}` : ''),
     cov.neverAbsent.length === 0);
  ck(`the template invents no member the census does not name — ${cov.unknown.length}`
     + (cov.unknown.length ? `: ${cov.unknown.slice(0, 6).join('; ')}` : ''),
     cov.unknown.length === 0);
  // The stronger witness, counted rather than assumed: a container instance that carries
  // the member beside one that does not. A template that only ever showed absence by
  // leaving a whole container out would satisfy the arm above and teach a producer
  // nothing about which members of a container it may omit.
  ck(`at least 40 members are shown absent by an INSTANCE that lacks them — `
     + `${cov.instanceWitnessed}`, cov.instanceWitnessed >= 40);

  // ── AND THE README'S FIGURES, BECAUSE IT SHIPS TO PEOPLE WHO CANNOT CHECK THEM ──────
  //
  // `conformance-kit/README.md` is copied into the released artifact and read by recorder
  // teams who have neither this repository nor §5. It tells them which members they may
  // leave out, and it used to tell them that EVERY member appears present in one tree and
  // absent in the other — false of the 52 the contract requires of every container, which
  // appear in both and could not do otherwise. The corrected sentence carries four counts,
  // and a count in an outward-facing document that nothing derives is a count that goes
  // stale in a direction nobody here will notice.
  {
    const readme = readFileSync(join(root, 'conformance-kit', 'README.md'), 'utf8');
    const spec = censusMembers(contract);
    let everywhere = 0, onRows = 0, optional = 0;
    for (const [, e] of spec) {
      if (e.required === true && !e.onRows) everywhere++;
      else if (e.required === true) onRows++;
      else optional++;
    }
    const flat = readme.replace(/\s+/g, ' ');
    const figures = [[spec.size, 'the census size'], [everywhere, 'required everywhere'],
                     [onRows, 'required on some rows'], [optional, 'optional'],
                     [onRows + optional, 'shown both ways']];
    const stale = figures.filter(([n]) => !new RegExp(`\\b${n}\\b`).test(flat));
    ck(`the kit README's census figures are the census's — ${figures.map(([n, w]) => `${n} ${w}`).join(', ')}`
       + (stale.length ? `; NOT IN THE README: ${stale.map(([n, w]) => `${n} (${w})`).join(', ')}` : ''),
       stale.length === 0);
  }

  // ── AND THE CONTROLS, EACH PLANTED IN A COPY, EACH CAUGHT BY THE ARM FOR IT ──────────
  //
  // Planted in memory against a copy of the census, never against the files on disk: the
  // subjects are the shipping template and the shipping census, and a control that edited
  // either would be a test that damages what it measures.
  {
    // 1. a member ARRIVES in §5 and the template does not exercise it
    const grown = JSON.parse(JSON.stringify(contract));
    grown.containers['snapshot.window'].members.blocksAhead =
      { required: true, access: 'required', holds: 'a member the template has never seen' };
    const after = templateCoverage(trees, grown);
    ck('a member added to §5 that the template does not exercise is reported — '
       + `${after.missing.length}`,
       after.missing.length === 1 && after.missing[0].startsWith('snapshot.window.blocksAhead'));
  }
  {
    // 2. a member the template happens to carry EVERYWHERE, made optional
    const forced = JSON.parse(JSON.stringify(contract));
    forced.containers['snapshot.provenance'].members.chain.required = false;
    const after = templateCoverage(trees, forced);
    ck('an optional member the template never shows absent is reported — '
       + `${after.neverAbsent.length}`,
       after.neverAbsent.includes('snapshot.provenance.chain'));
  }
  {
    // 3. a member the census does NOT name, arriving in the template
    const shrunk = JSON.parse(JSON.stringify(contract));
    delete shrunk.containers['snapshot.provenance'].members.label;
    const after = templateCoverage(trees, shrunk);
    ck('a template member the census does not name is reported — '
       + `${after.unknown.length}`,
       after.unknown.includes('snapshot.provenance.label'));
  }
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§12 the members a producer here writes and no reader consumes are RECORDED as such');
{
  // WHY THIS SECTION EXISTS, AND IT IS A DEFECT REPORT RATHER THAN A CATEGORY. §2 above
  // compares the census to the reader for EQUALITY, so a member our producer writes that
  // no reader opens CANNOT be in the census — it would fail the "the census names a member
  // nothing consumes" direction. Until 2026-09-17 that meant such a member was recorded
  // NOWHERE: `counts.captureSessions` is written by `lib/recount.mjs`, read by nothing, and
  // absent from this file entirely, while `refusal-selftest.mjs` required it of every
  // snapshot this repository commits. The first snapshot ever written here from §5 ALONE —
  // the conformance kit's template — therefore failed a rule §5 does not state, which is
  // precisely the "the reader is the specification" failure this census exists to remove.
  //
  // So they are recorded, and the three arms below are what keep the record honest.
  const pi = contract.producerInternal;
  ck(`the census records the producer-internal MEMBERS as well as the paths — `
     + `${pi.memberNames.length}`,
     Array.isArray(pi.memberNames) && pi.memberNames.length >= 1
     && pi.memberNames.every((m) => typeof pi.memberHolds[m] === 'string'
                                    && pi.memberHolds[m].length > 20));

  // 1. NOT IN THE CONSUMED CENSUS. This is the whole reason they cannot be recorded as
  //    ordinary members, so it is asserted rather than assumed — a member that became
  //    consumed must move, not sit here as a stale note.
  const census = censusMembers(contract);
  const alsoCensused = pi.memberNames.filter((m) => census.has(m));
  ck(`…and none of them is in the consumed census, which is why they need their own record `
     + `— ${alsoCensused.length}`, alsoCensused.length === 0);

  // 2. THE NAMED WRITER REALLY WRITES IT. A `writtenBy` nobody checked is the same shape as
  //    the census before §2: two hands writing one list. The leaf name has to appear in the
  //    file that claims to write it.
  const notWritten = pi.memberNames.filter((m) => {
    const by = pi.memberWrittenBy[m];
    if (by === null) return false;           // the convention above: no instance in this tree
    if (!existsSync(join(root, by))) return true;
    return !readFileSync(join(root, by), 'utf8').includes(m.slice(m.lastIndexOf('.') + 1));
  });
  ck(`…and every one with a named writer is spelled in that file — ${notWritten.length}`
     + (notWritten.length ? `: ${notWritten.join(', ')}` : ''), notWritten.length === 0);

  // 3. AND THE READER DOES NOT READ IT. The claim "producer-internal" is about the reader,
  //    so it is measured against the reader, by the same walk §2 uses rather than by a grep.
  const consumedAnyway = pi.memberNames.filter((m) => live.seen.has(m));
  ck(`…and the reader consumes none of them — ${consumedAnyway.length}`,
     consumedAnyway.length === 0);

  // 4. SHOWN ABLE TO FAIL. A member moved INTO the census must be reported by arm 1, or the
  //    record and the census can disagree silently in the one direction that matters.
  const promoted = JSON.parse(JSON.stringify(contract));
  promoted.containers['snapshot.counts'].members.captureSessions =
    { required: false, access: 'optional', holds: 'promoted by a control' };
  const promotedCensus = censusMembers(promoted);
  ck('control: the same member added to the census IS reported as being in both places',
     pi.memberNames.some((m) => promotedCensus.has(m)));
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§13 no optional member in src/ is reached by a form that cannot survive its absence');
{
  // THE FAMILY, AND WHY IT GETS A GATE RATHER THAN A FIFTH FIX. Seven defects across three
  // milestones, one shape: a member this census marks OPTIONAL, reached by the one access
  // form that cannot survive its absence. Two raised (`KeyError`, `IndexDefect`) and three
  // SEGFAULTED — including one in the producer-side validator, which is a binary a recorder
  // team runs, where it printed no finding at all. Every one was found by pointing a fixture
  // at the code, and none of them could have been found by reading it: the committed
  // captures all carry the member, so every arm in the repository ran over trees on which
  // the defect is unreachable. A source-shape ban does not need an input that reaches the
  // line, which is exactly why it is the right instrument here.
  //
  // WHAT IT COVERS AND WHAT IT PROVABLY DOES NOT is stated in the census
  // (`nilAccess.shapes` and `nilAccess.notCovered`) and in `lib/reader-contract.mjs`'s own
  // header, and the misses are PLANTED below rather than described.
  const ban = contract.nilAccess;
  ck(`the ban names its shapes and its misses in the census — `
     + `${Object.keys(ban.shapes).length} shape(s), ${ban.notCovered.length} stated miss(es)`,
     Object.keys(ban.shapes).length === NIL_ACCESS_SHAPES.length
     && NIL_ACCESS_SHAPES.every((s) => typeof ban.shapes[s] === 'string')
     && ban.notCovered.length >= 4);

  // THE SCOPE IS DERIVED FROM THE TREE, NOT LISTED. `chainVocabulary.scope` is a list and
  // was OUTGROWN once — a new module beside the reader was scanned by nothing while the
  // suite reported rc 0. A root plus a walk cannot be outgrown: a file that exists is in.
  const walkNim = (d) => readdirSync(d).flatMap((n) => {
    const p = join(d, n);
    return statSync(p).isDirectory() ? walkNim(p)
         : (n.endsWith(ban.fileSuffix) ? [p] : []);
  });
  const files = walkNim(join(root, ban.scopeRoot)).sort();
  ck(`it ranges over every ${ban.fileSuffix} under ${ban.scopeRoot}/, derived rather than `
     + `listed — ${files.length} file(s)`, files.length >= ban.minFiles);

  const violations = [];
  for (const f of files) {
    for (const v of nilAccessViolations(readFileSync(f, 'utf8'))) {
      violations.push(`${f.slice(root.length)}:${v.line} ${v.shape} ${v.expr}`);
    }
  }
  ck(`no file in scope reaches an optional member unsafely — ${violations.length}`,
     violations.length === 0);
  if (violations.length) console.error(`    ${violations.join('\n    ')}`);

  // …AND THERE IS NO EXEMPTION LIST, which is the arm that says the green above is a
  // property of the code rather than of a list of forgiven lines. The only thing the rule
  // forgives is a nil TEST on the same expression, and that is a rule, not a name.
  ck('…and the ban carries no exemption list — no file, line or symbol is forgiven',
     !('exempt' in ban) && !('allow' in ban) && !('ignore' in ban));

  // ── EACH SHAPE, PLANTED, WITH THE FORM IT IS STATED TO CATCH ────────────────────────
  //
  // A lint whose population is zero and whose failure has never been observed is
  // `return true` with a comment on it. Planted in memory against a copy of the reader's
  // text; the file on disk is never touched.
  const PLANTS = [
    ['nil-iteration',   '  for e in side{"transactions"}:\n    discard e'],
    ['nil-iteration',   '  for m, e in body{"members"}:\n    discard e'],
    ['nil-json-value',  '  let x = %*{\n    "paths": pos{"paths"}}'],
    ['nil-dereference', '  if pos{"paths"}.len == 0: discard'],
    ['nil-dereference', '  if pos{"paths"}.kind != JArray: discard'],
    ['nil-dereference', '  let x = pos{"paths"}[0]'],
  ];
  const missed = PLANTS.filter(([shape, code]) =>
    !nilAccessViolations(`${readerSrc}\n${code}\n`).some((v) => v.shape === shape));
  ck(`each shape is caught when planted — ${PLANTS.length - missed.length} of ${PLANTS.length}`
     + (missed.length ? `; missed ${missed.map((p) => p[0]).join(', ')}` : ''),
     missed.length === 0);

  // THE GUARD RULE IS A RULE AND NOT A HOLE. The admissible form has to be admitted — a ban
  // that fired on `if x{"k"} == nil or x{"k"}.kind != JArray:` would be a ban nobody could
  // satisfy, and the repair it pushes people towards has to be green.
  const GUARDED = [
    '  if vocab{"terms"} == nil or vocab{"terms"}.kind != JArray: discard',
    '  if isNil(vocab{"terms"}) or vocab{"terms"}.len == 0: discard',
    '  if vocab{"terms"} == nil:\n    discard\n  elif vocab{"terms"}.len == 0: discard',
  ];
  const falsePositives = GUARDED.filter((code) =>
    nilAccessViolations(`${readerSrc}\n${code}\n`)
      .some((v) => v.shape === 'nil-dereference'));
  ck(`…and a nil test on the same expression is ADMITTED — ${falsePositives.length} false `
     + 'positive(s) over the three guarded spellings', falsePositives.length === 0);

  // ── AND THE MISSES, PLANTED AND ASSERTED MISSED ─────────────────────────────────────
  //
  // "Banned outright" about a regex that is not banned outright is the failure this library
  // has already made once, with three spellings walked past a nine-shape ban that documented
  // itself as covering them. So the forms this ban does NOT catch are measured here rather
  // than left to be discovered: a residual that is asserted is a residual, one that is only
  // described is a hope. Each of these is in `nilAccess.notCovered`.
  const MISSES = [
    ['a KeyError on an optional member', '  let x = prov["l1ChainId"]'],
    ['an integer index onto a producer sequence', '  let x = execSelectors[tracedAt]'],
    ['a {} result bound to a name first', '  let y = side{"transactions"}\n  for e in y:\n    discard e'],
    ['…and the same, in a %* value position', '  let y = pos{"paths"}\n  let x = %*{"paths": y}'],
  ];
  const caughtAnyway = MISSES.filter(([, code]) =>
    nilAccessViolations(`${readerSrc}\n${code}\n`).length
    > nilAccessViolations(`${readerSrc}\n`).length);
  ck(`…and the four forms it does NOT catch are asserted MISSED, not described — `
     + `${MISSES.length - caughtAnyway.length} of ${MISSES.length} missed`
     + (caughtAnyway.length ? `; unexpectedly caught ${caughtAnyway.map((x) => x[0]).join(', ')}` : ''),
     caughtAnyway.length === 0);
}

// ═══════════════════════════════════════════════════════════════════════════════════════
test('§7 the census is well formed');
{
  ck(`it declares the format this build reads`,
     contract.format === 'blocktracer/snapshot-contract@1');
  ck('it names the spec section it transcribes', /Data-Contract\.md §5/.test(contract.spec));
  ck('it names the reader it is checked against',
     contract.reader === 'src/blocktracer/chain/ingest.nim'
     && existsSync(join(root, contract.reader)));
  const badRule = Object.entries(contract.rules)
    .filter(([id, b]) => !id.startsWith('S5-') || !b.section || !b.statement);
  ck(`every rule carries an id, a section and a statement — ${badRule.length} malformed`,
     badRule.length === 0);
  const badMember = [...censusMembers(contract)]
    .filter(([, e]) => typeof e.required !== 'boolean' || !e.access || !e.holds);
  ck(`every member states required, access and what it holds — ${badMember.length} malformed`,
     badMember.length === 0);
  // A sidecar that carries a version token of its own must say so, and the reader must
  // refuse an unknown one — this is `artifact-resolution.json`, which had a token nothing
  // documented until §5.4 was reconciled.
  const tokened = Object.entries(contract.containers).filter(([, b]) => b.versionToken);
  ck(`every sidecar with its own version token states it — ${tokened.length}`, tokened.length >= 1);
  ck('…and the reader spells that token, so the two cannot drift',
     tokened.every(([, b]) => readerSrc.includes(b.versionToken)));
}

console.error(`\nassertion count: ${asserted} (as declared)`);
if (asserted !== 91) {
  console.error(`snapshot-contract-selftest: asserted ${asserted}, declared 91`);
  process.exit(1);
}
if (failed) {
  console.error(`snapshot-contract-selftest: ${failed} failing assertion(s)`);
  process.exit(1);
}
console.error('PASS — the reader and Data-Contract.md §5 name the same members, '
  + 'the same rules, and the same paths.');
