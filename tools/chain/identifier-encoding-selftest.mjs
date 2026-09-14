#!/usr/bin/env node
// identifier-encoding-selftest.mjs — the JavaScript half of the registry's
// identifier-encoding declaration, and the proof that the two halves agree.
//
//   node tools/chain/identifier-encoding-selftest.mjs
//
// ── WHY THIS EXISTS, GIVEN THAT NO JAVASCRIPT READS THE DECLARATION YET ────────────────
//
// `tools/chain/identifier-encodings.json` is the closed set of encodings a chain's
// identifiers may be declared in (Configuration.md §2.1, §2.2; the members come from
// Search-And-Routing.md §2's shape table) AND, per member, the `shardKey` rule that member
// implies for a path segment. `src/blocktracer/contract/identifier_encoding.nim` reads it
// with `staticRead` at compile time, so the Nim half fails the BUILD if the file is
// missing, malformed, of a format it does not know, or carries a member with no rule.
//
// The JavaScript half has no such backstop, and that asymmetry is the whole reason this
// file is here. The set is data rather than a Nim enum because the capture tooling — which
// filters published directory entries on a literal `0x` — is JavaScript and is one of the
// sites that has to agree with the producers. A shared file whose JavaScript side nothing
// ever opens is a shared file that will drift on the JavaScript side undetected, and the
// drift would not surface until the consumer arrives. So the JavaScript read happens NOW,
// as a test.
//
// It is a TEST AND NOT A CONSUMER, still, and the reason has narrowed rather than gone
// away. Shard derivation now reads `chains[<slug>].identifierEncoding` — but derivation is
// Nim, compiled to both C and the JS backend from one source, so the JavaScript tooling has
// not had to grow a reader. The one JavaScript site that will is the capture tooling, and it
// enumerates the tree the HASH INDEX keys rather than the tree the derivation writes, so it
// follows the index: a filter widened ahead of the index would enumerate entities the index
// cannot key. The index is a published self-describing wire format, so it is a migration
// plus a compatibility window (Publishing-And-Caching.md §6.1, §6.2) and lands on its own.
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
const NIM_READER = join(REPO, 'src', 'blocktracer', 'contract', 'identifier_encoding.nim');

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
  return out;
}
const clone = () => JSON.parse(raw);
/** A well-formed shardKey, so a mutation that adds a ROW tests one rule and not two. */
const validRule = () => ({ stripPrefix: '', payloadAfterLast: '', pad: 'x', pathSafe: true });

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
  ck('…and names the two sites that still derive from the string',
     header.includes('hashshard.nim') && header.includes('entities.mjs'));
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
  const paths = readFileSync(join(REPO, 'src', 'blocktracer_client', 'paths.nim'), 'utf8');
  ck('paths.nim shards a transaction hash under the `transaction` kind',
     /shardKeyFor\(enc, KindTransaction, txHash\)/.test(paths));
  ck('paths.nim shards an address under the `address` kind',
     /shardKeyFor\(enc, KindAddress, address\)/.test(paths));
  ck('paths.nim builds a block path from a block hash',
     /proc blockPath\*\(chain, blockHash: string\)/.test(paths));
  // …and it takes the chain's declaration rather than assuming one. A DEFAULT ARGUMENT is
  // what this arm is really watching for: with one, every call site that was not updated
  // would keep deciding the encoding for itself, silently and correctly-looking.
  ck('…and every sharded builder takes the chain\'s encoding, with no default',
     (paths.match(/enc: ChainIdentifierEncoding\)/g) || []).length === 5
     && !/enc: ChainIdentifierEncoding = /.test(paths));
  // And it shards a trace artifact id by a DIFFERENT function, which is why that one is
  // not a kind: it is not a chain's identifier and is not derived from a chain's.
  ck('…and a trace artifact id is sharded by `traceShards`, not by the chain\'s encoding',
     /traceShards\(traceArtifactId\)/.test(paths));
  ck('…whose signature carries no encoding at all, so no caller can pass one',
     /func traceShards\*\(tid: string\): tuple\[a, b: string\]/.test(shardsSrcForKinds()));
}

/** `shards.nim`, read once for the arm above. */
function shardsSrcForKinds() {
  return readFileSync(join(REPO, 'src', 'blocktracer', 'contract', 'shards.nim'), 'utf8');
}

test('exactly the expected consumers name the declaration');
{
  // ── WHAT THIS ARM USED TO SAY, AND WHY IT SAYS SOMETHING ELSE ──────────────────────
  //
  // It asserted that NOTHING read `chains[<slug>].identifierEncoding`, which was true
  // while only the declaration had landed. Shard derivation now reads it, so that form
  // went red — which is what it was for — and it has been REPLACED rather than deleted,
  // and replaced with an EQUALITY rather than a widened allowlist:
  //
  //   * every file that names the member is enumerated, with the reason it does
  //   * the enumeration is compared for EQUALITY against a sweep, so an unexpected
  //     consumer fails AND so does an expected one that stopped being one
  //   * the per-directory population floors stay, so an emptied scan is not a green
  //   * the size of each expected set is asserted, so it cannot drift upward one entry
  //     at a time with the equality quietly edited to match
  //
  // An allowlist that grew whenever something new turned up in it would be a list nobody
  // checks. This one cannot grow without a number beside it moving.
  //
  // ── WHY THE SWEEP, AND NOT ONLY THE NAMES ──────────────────────────────────────────
  //
  // Because naming was MEASURED leaking. Consumers planted one file over from two named
  // files (`client/src/viewmodel/chain_vm.nim` beside `chain_registry_vm.nim`,
  // `tools/capture/lib/provenance.mjs` beside `entities.mjs`) once left every arm here
  // green while this suite printed a universal claim.
  //
  // AND WHY THIS SUITE HAS ITS OWN, when `tests/tidentifierencoding.nim` sweeps the same
  // population: the two are in different recipes. The Nim suite is in `just test`, which
  // takes ~37 minutes; this one is in `just chain-selftest`, the fast gate people actually
  // run. The rule, the extensions and the floors are deliberately identical, so a
  // disagreement between the two halves is a real disagreement and not a definition.
  const MEMBER = 'identifierEncoding';
  const CLIENT_EXPECTED = [
    // The browser's search bootstrap, which reads the member out of the registry response
    // it already fetches — Search-And-Routing.md §5's "two requests to resolve any hash on
    // any chain" is only true if the client recomputes the producer's own path.
    'client/searchboot/searchboot.nim',
    // The explorer's reader and the two view models that build a sharded path.
    'client/src/reader.nim',
    'client/src/viewmodel/address_vm.nim',
    'client/src/viewmodel/chain_vm.nim',
  ];
  const TOOLS_EXPECTED = [
    // This suite, and still nothing else: the capture tooling follows the hash index.
    'tools/chain/identifier-encoding-selftest.mjs',
  ];
  // Named as well as swept, so a file that STOPS EXISTING fails loudly instead of
  // silently leaving the expected set.
  for (const rel of [...CLIENT_EXPECTED, ...TOOLS_EXPECTED]) {
    ck(`${rel} exists`, existsSync(join(REPO, rel)));
  }
  // …and the surfaces that must still NOT name it, named rather than swept for the same
  // reason. `chain_registry_vm.nim` sits beside two files that do read it and does not,
  // which is the interesting case: it renders the registry's chain list and has no path to
  // derive.
  for (const rel of ['tools/capture/lib/entities.mjs',
                     'tools/chain/lib/refusal.mjs',
                     'tools/chain/lib/snapshot-format.mjs',
                     'client/src/viewmodel/chain_registry_vm.nim']) {
    const src = readFileSync(join(REPO, rel), 'utf8');
    ck(`${rel} does not name the declaration`, !src.includes(MEMBER));
  }
  const SOURCE_EXT = ['.nim', '.mjs', '.js', '.ts', '.sh'];
  // Generated and vendored trees are not this repository's source. Pruned by
  // directory rather than filtered by path so a `tools/capture/node_modules`
  // that somebody has installed costs nothing here; the SET OF COUNTED FILES is
  // the same either way, which is what the floors and the violation list read.
  const SKIP_DIR = ['node_modules', 'dist', 'nimcache'];
  // AND NEITHER IS A `nim js` OUTPUT SITTING NEXT TO ITS OWN SOURCE. `nim js`
  // writes `foo.js` beside `foo.nim` unless told otherwise, and `.js` is on the
  // list above — so a JS-backend test recipe perturbs both the population count
  // and the equality below with a file that is a build artifact. This was
  // MEASURED rather than anticipated: `client/tests/test_searchboot.js` reddened
  // the client equality on the first run of the recipe that produces it.
  //
  // THAT WAS FIRST FIXED WITH A SAME-STEM RULE — a `.js` beside a `.nim` of the
  // same name is the compiler's output — AND THE SAME-STEM RULE IS GONE. It is
  // described here only so the next reader does not reinvent it, and the way it
  // failed is the reason the population is now git's answer rather than a
  // heuristic. It was measured against the one case it hit
  // (`test_searchboot.js` beside `test_searchboot.nim`) and a bundle whose
  // output is not named after its source walks straight past it:
  // `client/Justfile`'s `search-bundle` compiles `searchboot/searchboot.nim` to
  // `searchboot/search.js`, different stem, so `search.js` was swept as source and
  // reddened the client equality for anyone who had ever built the bundle. It is
  // gitignored (`.gitignore:73`), so a clean checkout and CI never saw it: a gate
  // green where it is checked and red where it is used, which is the shape that
  // teaches people to ignore an arm.
  //
  // Git already knows what is generated, because `.gitignore` is where that fact
  // is written down and kept current by whoever adds the recipe. Tracked files
  // PLUS untracked-and-not-ignored is the population — the second half matters, or
  // a consumer written and not yet committed would not be caught, which is exactly
  // when catching it is most useful. This is the shape `ci/test/client-sdk-boundary.sh`
  // already uses for the same reason.
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
      if (SKIP_DIR.includes(e.name)) continue;
      const child = `${rel}/${e.name}`;
      if (e.isDirectory()) out.push(...walk(child));
      else if (e.isFile()) out.push(child);
    }
    return out;
  };
  for (const [top, expected, floor] of [['client', CLIENT_EXPECTED, 80],
                                        ['tools', TOOLS_EXPECTED, 100]]) {
    let scanned = 0;
    const naming = [];
    for (const path of walk(top)) {
      if (!SOURCE_EXT.some((x) => path.endsWith(x))) continue;
      // Generated and vendored trees are not this repository's source.
      if (path.includes('/node_modules/') || path.includes('/dist/')
          || path.includes('/nimcache/')) continue;
      if (!inRepo.has(path)) continue;
      scanned++;
      if (readFileSync(join(REPO, path), 'utf8').includes(MEMBER)) naming.push(path);
    }
    ck(`${top}/: swept ${scanned} source file(s), floor ${floor} — an emptied sweep is `
       + `not a green`, scanned >= floor);
    naming.sort();
    const want = [...expected].sort();
    // AN EQUALITY, NOT A SUBSET. An unexpected consumer fails it in one direction and an
    // expected consumer that stopped being one fails it in the other, and the message
    // prints both sides so the reader does not have to guess which happened.
    ck(`${top}/: the files naming the member are exactly the expected ones — swept `
       + `[${naming.join(', ')}] vs expected [${want.join(', ')}]`,
       naming.length === want.length && naming.every((p, i) => p === want[i]));
  }
  // THE SIZES, so the expected sets cannot drift upward one entry at a time with the
  // equalities quietly edited to match. A number is a thing a reviewer sees move.
  ck('four files under client/ are expected to name it', CLIENT_EXPECTED.length === 4);
  ck('one file under tools/ is expected to, and it is this suite',
     TOOLS_EXPECTED.length === 1
     && TOOLS_EXPECTED[0] === 'tools/chain/identifier-encoding-selftest.mjs');

  // ── AND THE HALF OF THE SEAM THAT IS STILL OPEN ──────────────────────────────────────
  //
  // A boundary check that only watched the closed half would report the seam shut. These
  // two arms assert the string-deriving sites are UNCHANGED, and they are expected to go red
  // in their turn — at which point whoever widened one reads this comment.
  //
  // The capture tooling's two literal `0x` filters over published directory entries. It is
  // derivation-ADJACENT, which is why landing it here was a real option; it is deferred
  // because what it enumerates is the tree the HASH INDEX keys, not the tree the derivation
  // writes. A filter widened ahead of the index would enumerate a non-hex chain's entities
  // and then fail to key them, which is a worse state than not seeing them.
  const entities = readFileSync(join(REPO, 'tools/capture/lib/entities.mjs'), 'utf8');
  const zeroX = (entities.match(/startsWith\("0x"\)/g) || []).length;
  ck(`the capture tooling still filters on a literal \`0x\` at ${zeroX} site(s), `
     + 'unchanged by this step, because it follows the hash index', zeroX === 2);
  // The hash index itself: hex pairs parsed, case folded unconditionally. Published wire
  // format, so a migration plus a compatibility window.
  const hashshard = readFileSync(
    join(REPO, 'src/blocktracer/contract/hashshard.nim'), 'utf8');
  ck('the hash index still parses hex pairs and folds case unconditionally',
     !hashshard.includes(MEMBER) && /parseHexInt/.test(hashshard)
     && /toLowerAscii/.test(hashshard));
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

  d = clone(); d.encodings.push({ id: 'hex', shapeRows: 'a second hex', shardKey: validRule() });
  bite('a duplicated encoding member is refused — a set that states two things about one '
       + 'member cannot answer a membership question', only(d, 'encodings-duplicate'));

  d = clone(); d.kinds.push({ id: 'address', pathSites: 'a second address' });
  bite('a duplicated kind is refused', only(d, 'kinds-duplicate'));

  d = clone(); d.encodings.push({ id: 'Base32', shapeRows: 'invented', shardKey: validRule() });
  bite('a member that is not a bare lowercase token is refused, because it is published '
       + 'verbatim as a registry value', only(d, 'encodings-not-a-token'));

  d = clone(); d.kinds.push({ id: 'block hash', pathSites: 'invented' });
  bite('a kind with whitespace is refused, because it is a published object KEY',
       only(d, 'kinds-not-a-token'));

  d = clone(); d.encodings.push({ id: 'base32', shardKey: validRule() });
  bite('a member naming no row of the shape table is refused — that is what makes the set '
       + 'reviewable against the spec rather than merely finite',
       only(d, 'encodings-no-provenance'));

  d = clone(); d.kinds.push({ id: 'checkpoint' });
  bite('a kind naming no path site is refused', only(d, 'kinds-no-provenance'));

  d = clone(); d.encodings.push({ id: '', shapeRows: 'nameless', shardKey: validRule() });
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

  // AND THE CONTROL FOR THE MUTATION MACHINERY ITSELF: a deep copy that is NOT mutated
  // must still be clean. Without this, a `clone()` that silently returned a broken
  // document would make all ten arms above pass for the wrong reason.
  bite('control: an unmutated deep copy has no problem, so the arms above are about the '
       + 'mutation and not about the copy', problems(clone()).length === 0);
}

console.error('');
if (asserted !== 74) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 74 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('PASS — both halves read one closed set; shard derivation reads the '
                + 'declaration and exactly the expected consumers name it');
