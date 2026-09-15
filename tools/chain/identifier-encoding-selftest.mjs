#!/usr/bin/env node
// identifier-encoding-selftest.mjs — the JavaScript half of the registry's
// identifier-encoding declaration, and the proof that the two halves agree.
//
//   node tools/chain/identifier-encoding-selftest.mjs
//
// ── WHY THIS EXISTS, GIVEN THAT NO JAVASCRIPT READS THE DECLARATION ───────────────────
//
// `tools/chain/identifier-encodings.json` is the closed set of encodings a chain's
// identifiers may be declared in (Configuration.md §2.1, §2.2; the members come from
// Search-And-Routing.md §2's shape table) AND, per member, the two rules that declaration
// implies: `shardKey`, where a path segment's payload starts, and `case`, how case is
// handled. `src/blocktracer/contract/identifier_encoding.nim` reads it with `staticRead` at
// compile time, so the Nim half fails the BUILD if the file is missing, malformed, of a
// format it does not know, or carries a member missing either rule.
//
// The JavaScript half has no such backstop, and that asymmetry is the whole reason this
// file is here. A shared file whose JavaScript side nothing ever opens is a shared file that
// will drift on the JavaScript side undetected, and the drift would not surface until a
// consumer arrives. So the JavaScript read happens NOW, as a test.
//
// It is a TEST AND NOT A CONSUMER, and that is now a settled state rather than a pending
// one. Derivation and case handling are Nim, compiled to both C and the JS backend from one
// source, so the browser needs no JavaScript reader. The capture tooling was the one site
// that looked like it would need one — it open-coded the hex shard rule at three sites —
// and it does not: it ENUMERATES the published shard directories instead of recomputing
// them, which needs no reader of this set at all. What is left is the §5 hash index's
// hex-pair parser, which is Nim, is a published self-describing wire format, and is a
// migration plus a compatibility window (Publishing-And-Caching.md §6.1, §6.2).
//
// ── AND THE BOUNDARY RULE, WHICH WAS ALSO WRITTEN TWICE ───────────────────────────────
//
// The extensions, the pruned directories, the floors and the allowlists this file's
// boundary arms sweep with were spelled out here AND in `tests/tidentifierencoding.nim`,
// and nothing compared the copies — they agreed because two independently-maintained lists
// happened to. They now live in `tools/chain/identifier-encoding-boundary.json`, which both
// halves read, and this file additionally answers `--emit-population` so the Nim half can
// require the two SWEPT POPULATIONS to be identical. See that file's header for why a
// shared rule alone would not have caught the one divergence this pair has had.
//
// ── WHAT IT CHECKS THAT THE NIM SUITE CANNOT ──────────────────────────────────────────
//
// `tests/tidentifierencoding.nim` owns everything behavioural: the producers' round trip,
// the closed-set refusal, and §2.2's additive rule with its controls. What it cannot do is
// check that the OTHER language's view of the shared file is the same one — a Nim suite
// comparing the Nim reader to the file it was compiled from is a closed loop. So this file
// parses the shared file with JavaScript's own parser and checks the Nim source's
// expectations against it as text.
//
// ── EVERY VALIDATION ARM HAS A MUTATION THAT REDDENS IT ────────────────────────────────
//
// Verification-Harness-Traps §4: a check never observed refusing is indistinguishable from
// `return true`. The structural rules are a pure function of the parsed document, so each
// one is driven over the real document (expecting silence) AND over a deep copy mutated in
// exactly one way (expecting that rule and no other).
//
// OFFLINE AND TOOLCHAIN-FREE — plain node reading files in this repository, no network, no
// Nim, no temporary state — which is what qualifies it for `chain-selftest`.

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, '..', '..');
const SHARED = join(HERE, 'identifier-encodings.json');
const BOUNDARY = join(HERE, 'identifier-encoding-boundary.json');
const NIM_READER = join(REPO, 'src', 'blocktracer', 'contract', 'identifier_encoding.nim');
const BOUNDARY_FORMAT = 'blocktracer/identifier-encoding-boundary@1';

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
const test = (name) => console.error(`\n${name}`);

const raw = readFileSync(SHARED, 'utf8');
const doc = JSON.parse(raw);
const nimSrc = readFileSync(NIM_READER, 'utf8');
const bnd = JSON.parse(readFileSync(BOUNDARY, 'utf8'));

// ── THE BOUNDARY SWEEP, HOISTED, BECAUSE THE NIM HALF ASKS FOR ITS ANSWER ─────────────
//
// The rule — extensions, pruned directories, floors, allowlists, pins — is
// `tools/chain/identifier-encoding-boundary.json`, read by both halves, because it used to
// be spelled out twice and compared to nothing. See that file's header.
//
// AND A SHARED RULE IS NOT ENOUGH. The one divergence this pair has actually had was not a
// disagreement about the rule: both halves already agreed that `dist/` is pruned and
// disagreed about what `dist/` MEANS, in their own sweep code, in two languages — an
// unanchored `contains("dist/")` on the Nim side also matched `redist/`, putting the two
// populations at 102 and 103. Moving the words into a shared file would not have caught it.
//
// So `--emit-population` prints THIS half's swept file list, per top-level directory, as
// JSON on STDOUT — the suite's own output is stderr, so stdout is clean — and
// `tests/tidentifierencoding.nim` runs it and requires the two lists to be identical as
// sets. That compares the two IMPLEMENTATIONS rather than the two configurations.
const gitLines = (args) => {
  const r = spawnSync('git', ['-C', REPO, ...args], { encoding: 'utf8' });
  if (r.status !== 0) {
    throw new Error(`git ${args.join(' ')} failed (${r.status}): ${r.stderr}`);
  }
  return r.stdout.split('\n').filter((l) => l.length > 0);
};
const inRepo = new Set([...gitLines(['ls-files']),
                        ...gitLines(['ls-files', '--others', '--exclude-standard'])]);
const walk = (rel) => {
  const out = [];
  for (const e of readdirSync(join(REPO, rel), { withFileTypes: true })) {
    if (bnd.skipDirectories.includes(e.name)) continue;
    const child = `${rel}/${e.name}`;
    if (e.isDirectory()) out.push(...walk(child));
    else if (e.isFile()) out.push(child);
  }
  return out;
};
/** Every path under `top` that counts as this repository's source. */
const sweptSource = (top) => {
  const out = [];
  for (const path of walk(top)) {
    if (!bnd.sourceExtensions.some((x) => path.endsWith(x))) continue;
    // Generated and vendored trees are not this repository's source. Anchored at BOTH ends
    // of the segment, or `redist/` matches `dist/` — see the boundary file's header.
    if (bnd.skipDirectories.some((d) => path.includes(`/${d}/`))) continue;
    if (!inRepo.has(path)) continue;
    out.push(path);
  }
  out.sort();
  return out;
};
/** Code lines only, in either language's comment syntax. COUNTED OVER CODE AND NOT OVER
 *  COMMENTS, because a paragraph explaining a defect reads as the defect: this file's own
 *  pins name `slice(2, 6)` and `stripHex` in prose. */
const codeOf = (src) => src.split('\n')
  .filter((l) => {
    const t = l.trim();
    return !(t.startsWith('#') || t.startsWith('//') || t.startsWith('*')
             || t.startsWith('/*'));
  }).join('\n');
const occurrences = (hay, needle) => hay.split(needle).length - 1;

if (process.argv.includes('--emit-population')) {
  const pop = {};
  for (const { top } of bnd.floors) pop[top] = sweptSource(top);
  process.stdout.write(JSON.stringify(pop));
  process.exit(0);
}

// ── The structural rules, as a pure function so a mutation can be run through them ────
//
// These are the SAME rules `parseIdentifierEncodings` raises on, restated here because
// the point is that both languages hold the file to them. A rule enforced on one side
// only is a rule the other side can violate.
const FORMAT = 'blocktracer/identifier-encodings@1';
function problems(d) {
  const out = [];
  if (d?.format !== FORMAT) out.push('format');
  for (const [field, label] of [['kinds', 'kinds'], ['encodings', 'encodings']]) {
    const rows = d?.[field];
    if (!Array.isArray(rows) || rows.length === 0) { out.push(`${label}-empty`); continue; }
    const seen = new Set();
    for (const row of rows) {
      const id = row?.id;
      if (typeof id !== 'string' || id.length === 0) { out.push(`${label}-no-id`); continue; }
      if (seen.has(id)) out.push(`${label}-duplicate`);
      seen.add(id);
      // A bare lowercase token: it is published verbatim — as an object KEY for a kind
      // and as a VALUE for an encoding — and a token that has to be normalised before it
      // can be compared is the drift a closed set exists to stop.
      if (id !== id.toLowerCase() || /\s/.test(id)) out.push(`${label}-not-a-token`);
    }
    const provenance = field === 'kinds' ? 'pathSites' : 'shapeRows';
    for (const row of rows) {
      if (typeof row?.[provenance] !== 'string' || row[provenance].length === 0) {
        out.push(`${label}-no-provenance`);
      }
    }
  }
  // ── THE SHARD RULE, WHICH IS WHAT MAKES A MEMBER MEAN SOMETHING ─────────────────────
  //
  // `src/blocktracer/contract/shards.nim` derives every sharded path segment from these
  // four fields rather than from a table of its own, so a member with no rule is a token a
  // producer could declare and a chain could publish under that the derivation cannot
  // honour. The Nim side fails the BUILD on each of these; they are restated here for the
  // reason the rules above are — a rule enforced on one side only is a rule the other side
  // can violate.
  for (const row of Array.isArray(d?.encodings) ? d.encodings : []) {
    const sk = row?.shardKey;
    if (sk === null || typeof sk !== 'object' || Array.isArray(sk)) {
      out.push('encodings-no-shardkey');
      continue;
    }
    // A pad is exactly one character: the ALPHABET's zero digit. It right-pads an
    // identifier shorter than a shard segment, so none could not widen one and several
    // would overshoot. It is per encoding because `0` is not a digit of base58, of bech32
    // or of base64 — padding with a character the alphabet does not contain would name a
    // shard no identifier could produce.
    if (typeof sk.pad !== 'string' || sk.pad.length !== 1) out.push('encodings-bad-pad');
    // ABSENT IS NOT FALSE. A member that forgot to answer would be refused at every shard
    // site as if its alphabet contained a separator; one that defaulted to true would
    // publish a path segment with a `/` in it.
    if (typeof sk.pathSafe !== 'boolean') out.push('encodings-no-pathsafe');
    for (const f of ['stripPrefix', 'payloadAfterLast']) {
      if (typeof sk[f] !== 'string') out.push('encodings-bad-payload-rule');
    }
  }
  // ── THE CASE RULE, WHICH IS A DIFFERENT QUESTION FROM WHERE THE PAYLOAD STARTS ───────
  //
  // One normalisation applied to every encoding is the silently-wrong outcome this rule
  // exists to prevent: lowercasing is the right KEY for hex and DESTROYS base58 and
  // base64url, which are case-significant; bech32 requires a UNIFORM case rather than an
  // arbitrary one; and an EIP-55 hex address carries its checksum IN ITS CASE, so its
  // display form and its key form are two different strings. The Nim side fails the BUILD
  // on each of these; they are restated here because a rule enforced on one side only is a
  // rule the other side can violate.
  for (const row of Array.isArray(d?.encodings) ? d.encodings : []) {
    const cs = row?.case;
    if (cs === null || typeof cs !== 'object' || Array.isArray(cs)) {
      out.push('encodings-no-case');
      continue;
    }
    // ABSENT IS NOT FALSE, for `significant`'s own reason: a member that forgot to answer
    // would be folded as if two spellings were one identifier, which for base58 does not
    // normalise an identifier — it names a different one.
    if (typeof cs.significant !== 'boolean') out.push('encodings-no-significance');
    if (!['lower', 'preserve'].includes(cs.keyForm)) out.push('encodings-bad-keyform');
    if (!['preserve', 'key'].includes(cs.displayForm)) out.push('encodings-bad-displayform');
    // THE TWO CROSS-FIELD RULES, which are the point of splitting the fields. Each field is
    // answerable on its own; the PAIR is what can be wrong.
    if (cs.significant === true && cs.keyForm !== 'preserve') {
      // A fold on a case-significant alphabet is not a normalisation.
      out.push('encodings-folds-a-significant-alphabet');
    }
    if (cs.displayForm === 'key' && cs.keyForm === 'preserve') {
      // "the display form is the key form" beside a key form that preserves says nothing.
      out.push('encodings-vacuous-displayform');
    }
  }
  return out;
}
const clone = () => JSON.parse(raw);
/** A well-formed shardKey, so a mutation that adds a ROW tests one rule and not two. */
const validRule = () => ({ stripPrefix: '', payloadAfterLast: '', pad: 'x', pathSafe: true });
/** …and a well-formed `case`, for the same reason: a row added to test the SHAPE of the set
 *  must not also be missing a case rule, or the mutation would report two problems and the
 *  `only()` comparison below could not say which rule refused. */
const validCase = () => ({ significant: false, keyForm: 'preserve', displayForm: 'preserve' });

test('the shared file satisfies the rules both halves hold it to');
{
  const p = problems(doc);
  ck(`the real document has no structural problem — [${p.join(', ')}]`, p.length === 0);
  ck(`it declares the format token — ${doc.format}`, doc.format === FORMAT);
  ck('the `_comment` header names the spec sections the members come from',
     JSON.stringify(doc._comment).includes('Search-And-Routing.md §2')
     && JSON.stringify(doc._comment).includes('Configuration.md §2.1'));
  // The header has to say WHAT READS THE MEMBER and WHAT STILL DOES NOT, because the
  // standing defect in this corpus is documentation claiming a consumption that does not
  // exist — and, now that a consumer has arrived, its mirror image: a header still saying
  // "nobody reads this" a release after somebody did.
  const header = JSON.stringify(doc._comment);
  ck('…and states that shard derivation reads the declaration',
     /SHARD DERIVATION READS/.test(header));
  ck('…and names the site that still derives from the string AND the one that stopped',
     header.includes('hashshard.nim') && header.includes('entities.mjs'));
  // THE CASE RULE HAS TO BE IN THE HEADER TOO, and with the EIP-55 reason: a header that
  // described the shard rule and left the case rule to be inferred from eight `case`
  // objects would be the state this step replaced, one file over.
  ck('…and states the case rule, with the display form it exists for',
     /`case`/.test(header) && /EIP-55/.test(header)
     && /keyForm/.test(header) && /displayForm/.test(header));
  ck('…and states the shard-rule contract the four `shardKey` fields implement',
     /stripPrefix/.test(header) && /payloadAfterLast/.test(header)
     && /pathSafe/.test(header));
}

test('the Nim half and the JavaScript half agree about the file they read');
{
  // The token, read out of the Nim source rather than assumed. If the two ever diverge
  // the Nim side fails its own build — but only after somebody rebuilds it, and the
  // producer that would have been rebuilt may not be the one that changed the file.
  const m = /IdentifierEncodingsFormat\* = "([^"]+)"/.exec(nimSrc);
  ck('the Nim reader names its expected format token in one place', m !== null);
  ck(`…and it is the token this file declares — ${m ? m[1] : '(unparsed)'}`,
     m !== null && m[1] === doc.format);
  ck('the Nim reader reads THIS file, by path, at compile time',
     /staticRead\("\.\.\/\.\.\/\.\.\/tools\/chain\/identifier-encodings\.json"\)/.test(nimSrc));
  // AND IT DOES NOT SPELL THE MEMBERS ITSELF. A reader carrying its own copy of the set
  // would make the shared file decoration.
  //
  // OVER CODE AND NOT OVER COMMENTS. The module explains the omitted-kind rule with a
  // `{address: "ss58"}` example in its own prose, and a check that counted that as a second
  // copy of the set would fail the module for documenting itself. Comments have no
  // behaviour; a token in one cannot make the derivation disagree with this file.
  const nimCode = nimSrc.split('\n').filter((l) => !l.trim().startsWith('#')).join('\n');
  const inlined = doc.encodings.map((e) => e.id)
    .filter((id) => new RegExp(`"${id}"`).test(nimCode) && id !== 'hex');
  ck(`the Nim reader inlines no encoding token of its own — [${inlined.join(', ')}]`,
     inlined.length === 0);
  // `hex` is the ONE exception and it is not a second copy of the set: it is the
  // declaration the producers write, which has to name a member to name anything.
  ck('…and its one `hex` literal is the declaration helper, not a set',
     /pairs\.add \(k\.id, "hex"\)/.test(nimSrc));
  // AND IT READS THE SHARD RULE FROM THIS FILE RATHER THAN ANSWERING FOR IT. The four field
  // names have to appear in the reader, because a reader that ignored one would leave that
  // field decoration while the derivation used a default nobody wrote down.
  for (const f of ['stripPrefix', 'payloadAfterLast', 'pad', 'pathSafe']) {
    ck(`the Nim reader reads \`shardKey.${f}\``,
       new RegExp(`sk\\{"${f}"\\}`).test(nimSrc));
  }

  // ── AND THE DERIVATION HOLDS NO TABLE OF ITS OWN ─────────────────────────────────────
  //
  // `shards.nim` is the module the whole set exists to feed. If it grew a `case` over the
  // tokens the set would be closed in this file and re-opened one module over, which is the
  // exact failure the data-not-an-enum decision was made to avoid.
  const shardsSrc = readFileSync(
    join(REPO, 'src', 'blocktracer', 'contract', 'shards.nim'), 'utf8');
  const shardsCode = shardsSrc.split('\n')
    .filter((l) => !l.trim().startsWith('#')).join('\n');
  ck('shards.nim gets each member\'s rule from this file',
     /identifierEncodingRule\(encoding\)/.test(shardsCode));
  const shardsInlined = doc.encodings.map((e) => e.id)
    .filter((id) => new RegExp(`"${id}"`).test(shardsCode));
  ck(`…and spells no token of the set itself — [${shardsInlined.join(', ')}]`,
     shardsInlined.length === 0);
  // A non-member must REFUSE rather than fall back to hex, which is the assumption the
  // member exists to remove; the refusal is what makes that checkable by reading.
  ck('…and refuses a shard key for an encoding whose alphabet is not path-safe',
     /if not rule\.pathSafe:/.test(shardsCode));

  // ── AND THE CASE RULE IS READ FROM THIS FILE TOO, RATHER THAN FOLDED IN NIM ──────────
  //
  // The defect this step removed was ONE unconditional `toLowerAscii`, applied to every
  // identifier of every encoding. A reader that admitted the three `case` fields and then
  // folded anyway would leave them decoration while the behaviour stayed global, so the
  // field names have to appear in the reader AND the fold has to be absent from the two
  // modules that key identifiers.
  for (const f of ['significant', 'keyForm', 'displayForm']) {
    ck(`the Nim reader reads \`case.${f}\``, new RegExp(`cs\\{"${f}"\\}`).test(nimSrc));
  }
  // The two cross-field rules, which are what stop a member declaring that case carries
  // identity and then folding it away.
  ck('…and refuses a member that folds a case-significant alphabet',
     /cs\{"significant"\}\.getBool and keyForm != "preserve"/.test(nimSrc));
  ck('…and refuses a displayForm of `key` beside a keyForm that preserves',
     /displayForm == "key" and keyForm == "preserve"/.test(nimSrc));
  // THE DERIVATION FOLDS THROUGH THE RULE AND NOWHERE ELSE. `shards.nim` has no
  // `toLowerAscii` of its own: a fold written there would be right for hex and would
  // destroy four of the eight members.
  ck('shards.nim folds per encoding, through the shared rule',
     /identifierPayload\(encoding, identifier\)/.test(shardsCode));
  ck('…and holds no fold of its own',
     !/toLowerAscii/.test(shardsCode) && !/toUpperAscii/.test(shardsCode));
}

test('the members are the shape table\'s rows, each naming the row it came from');
{
  const ids = doc.encodings.map((e) => e.id);
  // Spelled out rather than counted: a count stays green when a member is REPLACED.
  for (const want of ['hex', 'base58', 'base64', 'base64url', 'bech32', 'bech32m',
                      'ss58', 'decimal']) {
    ck(`\`${want}\` is a member`, ids.includes(want));
  }
  ck(`and there are no others — [${ids.join(', ')}]`, ids.length === 8);
  // `base64` and `base64url` are SEPARATE members and must stay separate: TON's address
  // is base64url and its transaction hash is base64, on one chain, so collapsing them
  // would make that chain undeclarable.
  ck('`base64` and `base64url` are distinct members', ids.includes('base64')
     && ids.includes('base64url') && ids.indexOf('base64') !== ids.indexOf('base64url'));
  // Same for bech32 and bech32m: Cardano is bech32, Fuel is bech32m, and the checksum
  // constants differ, so an address valid under one is invalid under the other.
  ck('`bech32` and `bech32m` are distinct members', ids.includes('bech32')
     && ids.includes('bech32m'));

  const kinds = doc.kinds.map((k) => k.id);
  ck(`the kinds are the three chain-supplied path segments — [${kinds.join(', ')}]`,
     kinds.length === 3 && ['address', 'block', 'transaction']
       .every((k) => kinds.includes(k)));
  // Ours are deliberately absent: a trace artifact id and a code hash are derived by this
  // pipeline, so no chain can contradict them and no chain should declare them.
  for (const ours of ['traceartifactid', 'codehash', 'bundlehash', 'trace']) {
    ck(`\`${ours}\` is not a kind`, !kinds.includes(ours));
  }
}

test('the kinds are the ones that actually become path segments');
{
  // The kind set is only defensible if it matches the module that builds every path this
  // package reads. Read that module rather than restating its conclusion.
  //
  // THAT MODULE IS `contract/shards.nim` AND NO LONGER `blocktracer_client/paths.nim`.
  // The identifier-keyed builders moved down into the contract because the PRODUCERS
  // could not reach them in the client SDK and were therefore building their sharded
  // paths by hand — which, once `shardKeyFor` folded, wrote a folded shard beside a raw
  // name. `paths.nim` re-exports them, and this arm checks the re-export too, because a
  // builder that existed and was not exported would be a builder the browser cannot call.
  const shards = shardsSrcForKinds();
  const paths = readFileSync(join(REPO, 'src', 'blocktracer_client', 'paths.nim'), 'utf8');
  ck('shards.nim shards a transaction hash under the `transaction` kind',
     /shardKeyFor\(enc, KindTransaction, txHash\)/.test(shards));
  ck('shards.nim shards an address under the `address` kind',
     /shardKeyFor\(enc, KindAddress, address\)/.test(shards));
  ck('shards.nim builds a block path, and it KEY-FORMS its identifier',
     /func blockPath\*\(chain, blockHash: string,/.test(shards)
     && /identifierKeyForm\(enc, KindBlock, blockHash\)/.test(shards));
  // …and every one of them takes the chain's declaration rather than assuming one. A
  // DEFAULT ARGUMENT is what this arm is really watching for: with one, every call site
  // that was not updated would keep deciding the encoding for itself, silently and
  // correctly-looking. SIX AND NOT FIVE since `blockPath` joined them: it has no shard
  // segment, and the case question is not the alphabet question.
  ck('…and all six builders take the chain\'s encoding, with no default',
     (shards.match(/enc: ChainIdentifierEncoding\)/g) || []).length === 6
     && !/enc: ChainIdentifierEncoding = /.test(shards));
  ck('…and the client SDK re-exports them rather than restating them',
     /^export blockPath, txFactsPath, txStatePath, traceSelectionPath,$/m.test(paths)
     && !/^func txFactsPath\*/m.test(paths) && !/^proc txFactsPath\*/m.test(paths));
  // And it shards a trace artifact id by a DIFFERENT function, which is why that one is
  // not a kind: it is not a chain's identifier and is not derived from a chain's.
  ck('…and a trace artifact id is sharded by `traceShards`, not by the chain\'s encoding',
     /traceShards\(traceArtifactId\)/.test(paths));
  ck('…whose signature carries no encoding at all, so no caller can pass one',
     /func traceShards\*\(tid: string\): tuple\[a, b: string\]/.test(shards));
}

/** `shards.nim`, read once for the arm above. */
function shardsSrcForKinds() {
  return readFileSync(join(REPO, 'src', 'blocktracer', 'contract', 'shards.nim'), 'utf8');
}

test('the producers build their paths with those builders, not by hand');
{
  // ── THE DEFECT THIS ARM EXISTS FOR, AND WHY IT IS IN THE FAST GATE ──────────────────
  //
  // Both producers used to build every sharded path by hand — `"d" / chain / "tx" /
  // shardKeyFor(txEncoding, h) / h & ".json"` — because the builders lived in the client
  // SDK, which is what READS what a producer wrote. The day `shardKeyFor` began folding
  // per the declared case rule, those fourteen hand-built paths — twelve of them sharded
  // — became HALF-FOLDED: a folded shard segment beside a RAW name segment. MEASURED on an uppercased `txHash`, the producer
  // wrote `d/{chain}/tx/0a80/0x0A807E….json` and the client computed
  // `.../0x0a807e….json` — a 404.
  //
  // It was found by a NULL MUTATION RESULT (no case mutation moved a published byte,
  // because every committed identifier is lowercase) rather than by any check, which is
  // why it gets one here as well as in `tests/tidentifierencoding.nim`: this is the gate
  // people run, and a producer is where a wrong published path comes from.
  //
  // Counted over CODE, for the reason the pins are: both producers explain the rule in
  // prose beside it, and a text count would read the explanation as the defect.
  for (const rel of ['src/blocktracer/chain/ingest.nim',
                     'src/blocktracer/demo/generator.nim']) {
    const code = codeOf(readFileSync(join(REPO, rel), 'utf8'));
    ck(`${rel} names the declaration once and derives every path from it`,
       occurrences(code, 'let identifierEncoding = ') === 1);
    // NO SHARD KEY IS TAKEN DIRECTLY. `shardKeyFor` in a producer is, by construction,
    // one half of a two-segment path whose other half is written by hand.
    ck(`${rel} takes no shard key of its own`,
       occurrences(code, 'shardKeyFor(') === 0);
    // …and it builds the paths through the contract's builders, which derive both
    // segments from one expression.
    for (const builder of ['blockPath(', 'txFactsPath(', 'txStatePath(',
                           'traceSelectionPath(', 'addressIndexPath(',
                           'addressSegmentPath(']) {
      ck(`${rel} builds ${builder}…) through the shared builder`,
         occurrences(code, builder) >= 1);
    }
  }
}

test('the boundary rule is one file, and both halves are held to it');
{
  // ── WHY THE RULE IS DATA AND NOT SPELLED HERE ───────────────────────────────────────
  //
  // It used to be spelled here AND in `tests/tidentifierencoding.nim`: the extensions, the
  // pruned directories, the allowlists and both floors, twice, compared to nothing. The two
  // halves agreed only because two independently-maintained copies happened to match — and
  // one divergence (`redist/`) had already been found and fixed by hand. So the rule moved
  // to `tools/chain/identifier-encoding-boundary.json` and both halves read it, for the
  // reason the encoding set itself is data.
  ck(`the boundary rule declares the format token this half knows — ${bnd.format}`,
     bnd.format === BOUNDARY_FORMAT);
  ck('…and the Nim half reads the SAME file, by path',
     readFileSync(join(REPO, 'tests/tidentifierencoding.nim'), 'utf8')
       .includes('identifier-encoding-boundary.json'));
  // The rule has to SAY something: an empty extension list sweeps nothing and an empty
  // sweep list asserts nothing, and both would be green.
  ck(`the rule names the source extensions — [${bnd.sourceExtensions.join(', ')}]`,
     Array.isArray(bnd.sourceExtensions) && bnd.sourceExtensions.length > 0);
  ck(`…the directories that are not this repository's source — `
     + `[${bnd.skipDirectories.join(', ')}]`,
     Array.isArray(bnd.skipDirectories) && bnd.skipDirectories.length > 0);
  ck(`…a population floor per top-level directory — `
     + `[${bnd.floors.map((f) => `${f.top}>=${f.floor}`).join(', ')}]`,
     Array.isArray(bnd.floors) && bnd.floors.length === 3
     && bnd.floors.every((f) => typeof f.top === 'string' && Number.isInteger(f.floor)
                                && f.floor > 0));
  // TWO SWEEPS, AND THEY ARE TWO FACTS. A file may key an identifier without reading a
  // registry row (the §5 hash index does, under a named global encoding) and may read the
  // row without keying anything (the session pins it). One merged allowlist would let a new
  // consumer of either seam be excused by the other's list.
  ck(`…and two sweeps, the declaration and the case rule — `
     + `[${bnd.sweeps.map((w) => w.id).join(', ')}]`,
     bnd.sweeps.length === 2 && bnd.sweeps[0].id === 'declaration'
     && bnd.sweeps[1].id === 'caseRule');
  // EVERY expected entry carries the REASON it is one. An allowlist whose entries say
  // nothing is a list nobody reviews.
  const unexplained = [];
  for (const w of bnd.sweeps) {
    for (const top of Object.keys(w.expected)) {
      for (const row of w.expected[top]) {
        if (typeof row.path !== 'string' || typeof row.why !== 'string'
            || row.why.length === 0) unexplained.push(`${w.id}:${row.path}`);
      }
    }
  }
  ck(`every expected consumer says why it is one — ${unexplained.length} unexplained`,
     unexplained.length === 0);
}

test('exactly the expected files know about each half of the seam');
{
  // ── WHY THE SWEEP, AND NOT ONLY THE NAMES ──────────────────────────────────────────
  //
  // Because naming was MEASURED leaking. Consumers planted one file over from two named
  // files (`client/src/viewmodel/chain_vm.nim` beside `chain_registry_vm.nim`,
  // `tools/capture/lib/provenance.mjs` beside `entities.mjs`) once left every arm here
  // green while this suite printed a universal claim.
  //
  // AND WHY THIS SUITE HAS ONE when `tests/tidentifierencoding.nim` sweeps the same
  // population: the two are in different recipes. The Nim suite is in `just test`, which
  // takes ~37 minutes; this one is in `just chain-selftest`, the fast gate people actually
  // run. The rule is now ONE FILE both read, so a disagreement between the halves is a real
  // disagreement and not a definition — and the Nim half additionally compares the two
  // swept populations, which is the check a shared rule cannot make.
  const counts = {};
  for (const { top, floor } of bnd.floors) {
    const swept = sweptSource(top);
    counts[top] = swept.length;
    ck(`${top}/: swept ${swept.length} source file(s), floor ${floor} — an emptied sweep is `
       + `not a green`, swept.length >= floor);
    for (const w of bnd.sweeps) {
      const want = (w.expected[top] ?? []).map((r) => r.path).sort();
      // OVER CODE AND NOT OVER THE WHOLE FILE. Matched over the whole file, this
      // equality's REVERSE direction — "an expected consumer that stopped being one" —
      // is inert for any entry whose doc comment still names the token, which was
      // MEASURED at 14 of the 22 expected entries. Proof: reverting
      // `client/src/viewmodel/search_shapes.nim` to its own unconditional `toLowerAscii`
      // left nought code occurrences of all three `caseRule` tokens and one in a doc
      // comment, and both halves stayed green; deleting the comment's mention too
      // reddened both. `codeOf` is the same filter the pins have always used.
      const naming = swept.filter((path) => {
        const src = codeOf(readFileSync(join(REPO, path), 'utf8'));
        return w.tokens.some((t) => src.includes(t));
      });
      // AN EQUALITY, NOT A SUBSET. An unexpected consumer fails it in one direction and an
      // expected consumer that stopped being one fails it in the other, and the message
      // prints both sides so the reader does not have to guess which happened.
      ck(`${top}/ ${w.id}: the files naming [${w.tokens.join(', ')}] are exactly the `
         + `expected ones — swept [${naming.join(', ')}] vs expected [${want.join(', ')}]`,
         naming.length === want.length && naming.every((x, i) => x === want[i]));
    }
  }
  // Named as well as swept, so a file that STOPS EXISTING fails loudly instead of silently
  // leaving the expected set.
  const missing = [];
  for (const w of bnd.sweeps) {
    for (const top of Object.keys(w.expected)) {
      for (const row of w.expected[top]) {
        if (!existsSync(join(REPO, row.path))) missing.push(row.path);
      }
    }
  }
  ck(`every expected consumer exists — ${missing.length} missing`, missing.length === 0);
  // The SIZES of the two expected sets, spelled out rather than derived, for the reason
  // above: these are the numbers a diff shows moving.
  const sizeOf = (id) => bnd.sweeps.find((w) => w.id === id).expected;
  // EIGHT AND NOT NINE: `src/blocktracer_client_paths.nim` left this set when the sweep
  // started matching over CODE. Two lines of `import`/`export` under a sixty-line header,
  // whose only mention of the member was in that header — documentation of
  // `blocktracer_client/paths.nim`'s signature, not a second reader of the declaration,
  // and the module it re-exports is in the set.
  ck('eight files under src/ read the declaration', sizeOf('declaration').src.length === 8);
  ck('four under client/, and one under tools/ — this suite',
     sizeOf('declaration').client.length === 4
     && sizeOf('declaration').tools.length === 1);
  ck('six files under src/ read the case rule', sizeOf('caseRule').src.length === 6);
  ck('one under client/ — the query canonicaliser — and one under tools/',
     sizeOf('caseRule').client.length === 1 && sizeOf('caseRule').tools.length === 1);
}

test('the string-deriving sites are pinned, including the one that had no pin');
{
  // ── THE HALF OF THE SEAM THAT IS STILL OPEN, AND THE HALF THAT WAS INVISIBLE ────────
  //
  // A boundary check that only watched the closed half would report the seam shut. These
  // pins assert what is still hex-shaped AND what must no longer be there, and they are
  // expected to go red in their turn — at which point whoever moved one reads the reason
  // recorded beside it in the boundary file.
  //
  // THE `absent` HALF IS THE RESIDUAL THIS STEP CLOSED. Before it, both halves counted only
  // `startsWith("0x")` in the capture tooling — so the three `slice(2, 6)` derivations in
  // the same file, and a fourth added beside them, were invisible to both.
  for (const pin of bnd.pins) {
    const src = readFileSync(join(REPO, pin.file), 'utf8');
    const code = codeOf(src);
    for (const { needle, count } of pin.present) {
      const n = occurrences(code, needle);
      ck(`${pin.file}: \`${needle}\` appears ${n} time(s) in CODE, pinned at ${count}`,
         n === count);
    }
    for (const { needle } of pin.absent) {
      const n = occurrences(code, needle);
      ck(`${pin.file}: \`${needle}\` is gone from CODE — ${n} occurrence(s)`, n === 0);
    }
  }
  // AND THE PINS THEMSELVES SAY WHY, for the reason the allowlist entries do.
  const unexplained = [];
  for (const pin of bnd.pins) {
    for (const row of [...pin.present, ...pin.absent]) {
      if (typeof row.why !== 'string' || row.why.length === 0) {
        unexplained.push(`${pin.file}:${row.needle}`);
      }
    }
  }
  ck(`every pin says why it is one — ${unexplained.length} unexplained`,
     unexplained.length === 0);
  // ANTI-VACUITY: a `pins` array that parsed to nothing would make both loops above run
  // zero times and report success having measured nothing.
  ck(`two files are pinned and both have present AND absent needles — `
     + `[${bnd.pins.map((p) => p.file).join(', ')}]`,
     bnd.pins.length === 2
     && bnd.pins.every((p) => p.present.length > 0 && p.absent.length > 0));
}

test('MUTATIONS: each structural rule refuses on its own');
{
  const only = (d, want) => {
    const p = problems(d);
    return p.length === 1 && p[0] === want;
  };
  let d = clone(); d.format = 'blocktracer/identifier-encodings@99';
  bite('a format token this build does not know is refused', only(d, 'format'));

  d = clone(); d.encodings = [];
  bite('an empty encoding set is refused — otherwise every "the declared encoding is a '
       + 'member" check is vacuously false and every "no encoding is outside the set" '
       + 'check vacuously true', only(d, 'encodings-empty'));

  d = clone(); d.kinds = [];
  bite('an empty kind set is refused', only(d, 'kinds-empty'));

  d = clone(); d.encodings.push({ id: 'hex', shapeRows: 'a second hex', shardKey: validRule(), case: validCase() });
  bite('a duplicated encoding member is refused — a set that states two things about one '
       + 'member cannot answer a membership question', only(d, 'encodings-duplicate'));

  d = clone(); d.kinds.push({ id: 'address', pathSites: 'a second address' });
  bite('a duplicated kind is refused', only(d, 'kinds-duplicate'));

  d = clone(); d.encodings.push({ id: 'Base32', shapeRows: 'invented', shardKey: validRule(), case: validCase() });
  bite('a member that is not a bare lowercase token is refused, because it is published '
       + 'verbatim as a registry value', only(d, 'encodings-not-a-token'));

  d = clone(); d.kinds.push({ id: 'block hash', pathSites: 'invented' });
  bite('a kind with whitespace is refused, because it is a published object KEY',
       only(d, 'kinds-not-a-token'));

  d = clone(); d.encodings.push({ id: 'base32', shardKey: validRule(), case: validCase() });
  bite('a member naming no row of the shape table is refused — that is what makes the set '
       + 'reviewable against the spec rather than merely finite',
       only(d, 'encodings-no-provenance'));

  d = clone(); d.kinds.push({ id: 'checkpoint' });
  bite('a kind naming no path site is refused', only(d, 'kinds-no-provenance'));

  d = clone(); d.encodings.push({ id: '', shapeRows: 'nameless', shardKey: validRule(), case: validCase() });
  bite('a member with no id is refused', only(d, 'encodings-no-id'));

  // ── AND THE SHARD RULE'S OWN ARMS ───────────────────────────────────────────────────
  //
  // The rule is what makes a member mean something to the derivation, so each of its four
  // fields gets a mutation. Without these the fields would be four strings nobody held to
  // anything, and a member whose rule was quietly dropped would still pass every arm above.
  d = clone(); delete d.encodings[0].shardKey;
  bite('a member with no shardKey rule is refused — it would be a token the derivation '
       + 'cannot honour', only(d, 'encodings-no-shardkey'));

  d = clone(); d.encodings[0].shardKey.pad = '';
  bite('a pad of no characters is refused: it could not widen a short identifier',
       only(d, 'encodings-bad-pad'));

  d = clone(); d.encodings[0].shardKey.pad = '00';
  bite('a pad of several characters is refused: it would overshoot the shard width',
       only(d, 'encodings-bad-pad'));

  d = clone(); delete d.encodings[0].shardKey.pathSafe;
  bite('a member that does not say whether it is pathSafe is refused — absent is not '
       + 'false, and a default either way is wrong in a different direction',
       only(d, 'encodings-no-pathsafe'));

  d = clone(); d.encodings[0].shardKey.stripPrefix = 12;
  bite('a non-string stripPrefix is refused', only(d, 'encodings-bad-payload-rule'));

  d = clone(); delete d.encodings[0].shardKey.payloadAfterLast;
  bite('an absent payloadAfterLast is refused rather than read as "no separator" — the '
       + 'field says the separator is empty, and a silent default cannot be reviewed',
       only(d, 'encodings-bad-payload-rule'));

  // ── AND THE CASE RULE'S OWN ARMS ────────────────────────────────────────────────────
  //
  // Six, because the rule has three fields and two CROSS-FIELD constraints, and the
  // cross-field ones are where the defect this step removed would reappear: a member
  // declaring that its case carries identity and then folding it away.
  d = clone(); delete d.encodings[0].case;
  bite('a member with no case rule is refused — lowercasing is the right key for hex and '
       + 'destroys base58, and a member that does not say which it is cannot be keyed',
       only(d, 'encodings-no-case'));

  d = clone(); delete d.encodings[0].case.significant;
  bite('a member that does not say whether its case is SIGNIFICANT is refused — absent is '
       + 'not false, and false is a fold', only(d, 'encodings-no-significance'));

  d = clone(); d.encodings[0].case.keyForm = 'upper';
  bite('a keyForm outside {lower, preserve} is refused: it is a normalisation nothing in '
       + 'this tree implements', only(d, 'encodings-bad-keyform'));

  d = clone(); d.encodings[0].case.displayForm = 'raw';
  bite('a displayForm outside {preserve, key} is refused',
       only(d, 'encodings-bad-displayform'));

  d = clone(); d.encodings[1].case.keyForm = 'lower';
  bite('a CASE-SIGNIFICANT member that folds is refused — base58 lowercased is not a '
       + 'normalised address, it is a different address that does not exist',
       only(d, 'encodings-folds-a-significant-alphabet'));

  d = clone(); d.encodings[1].case.displayForm = 'key';
  bite('`displayForm: key` beside a keyForm that preserves is refused as a statement that '
       + 'says nothing — a rule that reads as a decision while making none is worse than '
       + 'an absent one', only(d, 'encodings-vacuous-displayform'));

  // AND THE CONTROL FOR THE MUTATION MACHINERY ITSELF: a deep copy that is NOT mutated
  // must still be clean. Without this, a `clone()` that silently returned a broken
  // document would make all ten arms above pass for the wrong reason.
  bite('control: an unmutated deep copy has no problem, so the arms above are about the '
       + 'mutation and not about the copy', problems(clone()).length === 0);
}

console.error('');
if (asserted !== 119) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 119 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('PASS — both halves read one closed set and one boundary rule; shard '
                + 'derivation and case handling read the declaration, exactly the expected '
                + 'consumers name each half, and the string-deriving sites are pinned');
