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
//   * §5 named NINE member paths. The reader consumes 117 over 22 containers — so 108
//     were unnamed, across `provenance`, `window`, `blocks[]`, `captures[]`,
//     `transactions[]` and five sidecars, and 19 of them were reached by unguarded
//     bracket access, which RAISES in Nim rather than answering null.
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

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { extractReaderContract, flatten, readerShapeViolations, pathDefaultLiterals,
         REQUIRED, OPTIONAL } from './lib/reader-contract.mjs';

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
if (asserted !== 51) {
  console.error(`snapshot-contract-selftest: asserted ${asserted}, declared 51`);
  process.exit(1);
}
if (failed) {
  console.error(`snapshot-contract-selftest: ${failed} failing assertion(s)`);
  process.exit(1);
}
console.error('PASS — the reader and Data-Contract.md §5 name the same members, '
  + 'the same rules, and the same paths.');
