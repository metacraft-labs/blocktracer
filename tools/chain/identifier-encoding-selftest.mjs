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
// Search-And-Routing.md §2's shape table). `src/blocktracer/contract/identifier_encoding.nim`
// reads it with `staticRead` at compile time, so the Nim half fails the BUILD if the file
// is missing, malformed, or of a format it does not know.
//
// The JavaScript half has no such backstop, and that asymmetry is the whole reason this
// file is here. The set is data rather than a Nim enum because the capture tooling — which
// filters published directory entries on a literal `0x` — is JavaScript and is one of the
// sites that has to agree with the producers the moment anything consumes the declaration.
// A shared file whose JavaScript side nothing ever opens is a shared file that will drift
// on the JavaScript side undetected, and the drift would not surface until the consumer
// arrives. So the JavaScript read happens NOW, as a test.
//
// It is a TEST AND NOT A CONSUMER, deliberately. Nothing in the shipped tooling reads
// `chains[<slug>].identifierEncoding`; the declaration lands on its own so that the part
// which changes published bytes — the hash index is a self-describing wire format — lands
// on its own later, with a compatibility window (Publishing-And-Caching.md §6.1, §6.2).
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

import { readFileSync, readdirSync } from 'node:fs';
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
  return out;
}
const clone = () => JSON.parse(raw);

test('the shared file satisfies the rules both halves hold it to');
{
  const p = problems(doc);
  ck(`the real document has no structural problem — [${p.join(', ')}]`, p.length === 0);
  ck(`it declares the format token — ${doc.format}`, doc.format === FORMAT);
  ck('the `_comment` header names the spec sections the members come from',
     JSON.stringify(doc._comment).includes('Search-And-Routing.md §2')
     && JSON.stringify(doc._comment).includes('Configuration.md §2.1'));
  // The header has to SAY that nothing reads the member, because the standing defect in
  // this corpus is documentation claiming a consumption that does not exist.
  ck('…and states, in as many words, that no consumer reads the declaration',
     /NO CONSUMER READS/.test(JSON.stringify(doc._comment)));
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
  const inlined = doc.encodings.map((e) => e.id)
    .filter((id) => new RegExp(`"${id}"`).test(nimSrc) && id !== 'hex');
  ck(`the Nim reader inlines no encoding token of its own — [${inlined.join(', ')}]`,
     inlined.length === 0);
  // `hex` is the ONE exception and it is not a second copy of the set: it is the
  // declaration the producers write, which has to name a member to name anything.
  ck('…and its one `hex` literal is the declaration helper, not a set',
     /pairs\.add \(k\.id, "hex"\)/.test(nimSrc));
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
  ck('paths.nim shards a transaction hash', /hexShard\(txHash\)/.test(paths));
  ck('paths.nim shards an address', /hexShard\(address\)/.test(paths));
  ck('paths.nim builds a block path from a block hash',
     /proc blockPath\*\(chain, blockHash: string\)/.test(paths));
  // And it shards a trace artifact id by a DIFFERENT function, which is why that one is
  // not a kind: it is not a chain's identifier and is not derived from a chain's.
  ck('…and a trace artifact id is sharded by `traceShards`, not by the chain\'s encoding',
     /traceShards\(traceArtifactId\)/.test(paths));
}

test('the declaration is written at two sites and read at none');
{
  // The Nim suite asserts this over `src/`. Here it is asserted over the JavaScript and
  // client surfaces, which are exactly the ones the widening will have to reach.
  const MEMBER = 'identifierEncoding';
  for (const rel of ['tools/capture/lib/entities.mjs',
                     'tools/chain/lib/refusal.mjs',
                     'tools/chain/lib/snapshot-format.mjs',
                     'client/searchboot/searchboot.nim',
                     'client/src/viewmodel/chain_registry_vm.nim']) {
    const src = readFileSync(join(REPO, rel), 'utf8');
    ck(`${rel} does not read the declaration`, !src.includes(MEMBER));
  }

  // ── AND THE SAME CLAIM, SWEPT, BECAUSE THIS SUITE'S VERDICT LINE MAKES IT ──────────
  //
  // The five names above are a sample, and this file's final sentence is a universal:
  // "nothing reads the declaration yet". A named sample cannot carry a universal, and
  // that gap was MEASURED rather than imagined — consumers planted one file over from
  // two of the names above (`client/src/viewmodel/chain_vm.nim` beside
  // `chain_registry_vm.nim`, `tools/capture/lib/provenance.mjs` beside `entities.mjs`)
  // left every arm here green while the suite printed that sentence.
  //
  // The Nim suite gained a floored sweep for that. THIS ONE NEEDS ITS OWN, because the
  // two are in different recipes: the Nim suite is in `just test`, which takes ~37
  // minutes, and this suite is in `just chain-selftest`, which is the fast gate people
  // actually run — so the fast gate was the one printing the universal with nothing
  // behind it. The rule, the extensions and the floors below are deliberately the same
  // as `tests/tidentifierencoding.nim`'s, so the two halves sweep the same population
  // and a disagreement between them is a real disagreement and not a definition.
  //
  // WITH A FLOOR, PER DIRECTORY. A scan whose expected answer is "no file" is satisfied
  // perfectly by scanning no files, so the population is asserted too — per directory,
  // so an emptied sweep of one cannot hide behind the other.
  const ALLOWED = ['tools/chain/identifier-encoding-selftest.mjs'];
  const SOURCE_EXT = ['.nim', '.mjs', '.js', '.ts', '.sh'];
  // Generated and vendored trees are not this repository's source. Pruned by
  // directory rather than filtered by path so a `tools/capture/node_modules`
  // that somebody has installed costs nothing here; the SET OF COUNTED FILES is
  // the same either way, which is what the floors and the violation list read.
  const SKIP_DIR = ['node_modules', 'dist', 'nimcache'];
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
  const reading = [];
  for (const [top, floor] of [['client', 80], ['tools', 100]]) {
    let scanned = 0;
    for (const path of walk(top)) {
      if (!SOURCE_EXT.some((x) => path.endsWith(x))) continue;
      // Generated and vendored trees are not this repository's source.
      if (path.includes('/node_modules/') || path.includes('/dist/')
          || path.includes('/nimcache/')) continue;
      scanned++;
      if (ALLOWED.includes(path)) continue;
      if (readFileSync(join(REPO, path), 'utf8').includes(MEMBER)) reading.push(path);
    }
    ck(`${top}/: swept ${scanned} source file(s), floor ${floor} — an emptied sweep is `
       + `not a green`, scanned >= floor);
  }
  ck(`…and no file under client/ or tools/ reads the declaration, SWEPT rather than `
     + `named${reading.length ? ` — ${reading.join(', ')}` : ''}`, reading.length === 0);
  // The allowance is a hole in the sweep, so its SIZE is asserted and not only its
  // members: a second entry would exempt a real consumer with every arm here green.
  ck('exactly one file is allowed to name the member, and it is this suite',
     ALLOWED.length === 1 && ALLOWED[0] === 'tools/chain/identifier-encoding-selftest.mjs');
  // The capture tooling's `0x` filter is still there and unchanged. Naming it here is what
  // makes the boundary legible: this is the site the declaration exists to feed, and it
  // has deliberately not been fed yet.
  const entities = readFileSync(join(REPO, 'tools/capture/lib/entities.mjs'), 'utf8');
  const zeroX = (entities.match(/startsWith\("0x"\)/g) || []).length;
  ck(`the capture tooling still filters on a literal \`0x\` at ${zeroX} site(s), `
     + 'unchanged by this step', zeroX === 2);
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

  d = clone(); d.encodings.push({ id: 'hex', shapeRows: 'a second hex' });
  bite('a duplicated encoding member is refused — a set that states two things about one '
       + 'member cannot answer a membership question', only(d, 'encodings-duplicate'));

  d = clone(); d.kinds.push({ id: 'address', pathSites: 'a second address' });
  bite('a duplicated kind is refused', only(d, 'kinds-duplicate'));

  d = clone(); d.encodings.push({ id: 'Base32', shapeRows: 'invented' });
  bite('a member that is not a bare lowercase token is refused, because it is published '
       + 'verbatim as a registry value', only(d, 'encodings-not-a-token'));

  d = clone(); d.kinds.push({ id: 'block hash', pathSites: 'invented' });
  bite('a kind with whitespace is refused, because it is a published object KEY',
       only(d, 'kinds-not-a-token'));

  d = clone(); d.encodings.push({ id: 'base32' });
  bite('a member naming no row of the shape table is refused — that is what makes the set '
       + 'reviewable against the spec rather than merely finite',
       only(d, 'encodings-no-provenance'));

  d = clone(); d.kinds.push({ id: 'checkpoint' });
  bite('a kind naming no path site is refused', only(d, 'kinds-no-provenance'));

  d = clone(); d.encodings.push({ id: '', shapeRows: 'nameless' });
  bite('a member with no id is refused', only(d, 'encodings-no-id'));

  // AND THE CONTROL FOR THE MUTATION MACHINERY ITSELF: a deep copy that is NOT mutated
  // must still be clean. Without this, a `clone()` that silently returned a broken
  // document would make all ten arms above pass for the wrong reason.
  bite('control: an unmutated deep copy has no problem, so the arms above are about the '
       + 'mutation and not about the copy', problems(clone()).length === 0);
}

console.error('');
if (asserted !== 50) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 50 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('PASS — both halves read one closed set, and nothing reads the declaration yet');
