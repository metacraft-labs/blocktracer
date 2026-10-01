#!/usr/bin/env node
// cache-policy-drift.mjs — does `tools/verify/cache-policy.json` still describe
// the sections it says it was transcribed from?
//
//   node tools/verify/cache-policy-drift.mjs [--specs DIR] [--ref REF]
//
// WHY THIS EXISTS
// ---------------
// `blocktracer-verify-published` checks a live instance's `Cache-Control`
// headers against `tools/verify/cache-policy.json`. That file is a TRANSCRIPTION
// of two sections in another repository — Static-Site-Architecture.md §2.9,
// which is normative, and Publishing-And-Caching.md §4, which says of itself
// that it is generated from §2.9 and stale wherever the two disagree.
//
// A transcription with no way back to its source is a set of numbers. So the
// file records the specs commit and the sha256 of each section's exact text,
// and this recomputes both. A section that changed is not necessarily a
// contract change — a typo fix moves the digest too — so the output is "these
// sections moved, go and read them", not an automatic verdict.
//
// IT REFUSES RATHER THAN PASSES WHEN IT CANNOT LOOK.
// `.github/workflows/ci.yml` does not check out `codetracer-specs`, and the
// Justfile records the same limitation for `snapshot-contract-tables`. A guard
// that quietly exits 0 when its subject is absent is the empty-set pass this
// repository has paid for before: it looks like it ran. Absent checkout ⇒ exit
// 2 with the path it looked for. That is why this is an operator command
// (`just cache-policy-drift`) and not a CI step, and why the CI step that DOES
// exist is the offline half — that the file parses, that its rows are ordered
// specific-before-general, and that every row is reachable — which
// `tests/tverifypublished.nim` asserts.
//
// Reads two git objects and one file. Writes nothing.
import { readFileSync, existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const policyPath = join(here, 'cache-policy.json');

const argv = process.argv.slice(2);
const flag = (n, d = null) => {
  const i = argv.indexOf(n);
  return i < 0 ? d : argv[i + 1];
};

const policy = JSON.parse(readFileSync(policyPath, 'utf8'));
const src = policy.source;

// The checkout to read. A sibling `codetracer-specs` is the layout every other
// tool here assumes, and $CODETRACER_SPECS overrides it.
const specsDir = flag('--specs')
  ?? process.env.CODETRACER_SPECS
  ?? join(here, '..', '..', '..', 'codetracer-specs');
const ref = flag('--ref') ?? `origin/${src.branch ?? 'latest'}`;

if (!existsSync(join(specsDir, '.git'))) {
  console.error(`cache-policy-drift: no codetracer-specs checkout at ${specsDir}\n`
    + `  This guard cannot report on a source it cannot read, and exiting 0 here\n`
    + `  would be indistinguishable from having checked. Pass --specs DIR or set\n`
    + `  CODETRACER_SPECS.`);
  process.exit(2);
}

const show = (path) => {
  try {
    return execFileSync('git', ['-C', specsDir, 'show', `${ref}:${path}`],
      { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  } catch (e) {
    console.error(`cache-policy-drift: cannot read ${ref}:${path} from ${specsDir}`);
    process.exit(2);
  }
};

// The slice is defined the same way the transcription defined it: from the
// heading line up to, but not including, the next named heading. Stated here in
// code so the digest can be recomputed by anyone, which is the whole point of
// publishing one.
const slice = (text, from, until) => {
  const lines = text.split('\n');
  const a = lines.findIndex((l) => l === from);
  if (a < 0) return null;
  const rest = lines.slice(a);
  const b = rest.findIndex((l, i) => i > 0 && l === until);
  return (b < 0 ? rest : rest.slice(0, b)).join('\n') + '\n';
};

let moved = 0, missing = 0;
console.log(`specs   : ${specsDir}  @ ${ref}`);
console.log(`recorded: commit ${src.commit}, transcribed ${src.transcribedOn}`);
console.log('');

for (const s of src.sections) {
  const text = show(s.path);
  const body = slice(text, s.section, s.endsBefore);
  if (body == null) {
    console.log(`MISSING  ${s.path}  ${JSON.stringify(s.section)} — the heading this`
      + ' transcription names is no longer in the document');
    missing += 1;
    continue;
  }
  const got = createHash('sha256').update(body, 'utf8').digest('hex');
  const ok = got === s.sha256;
  if (!ok) moved += 1;
  console.log(`${ok ? 'SAME    ' : 'MOVED   '} ${s.path}  ${s.section}`
    + `${s.normative ? '  [NORMATIVE]' : ''}`);
  if (!ok) {
    console.log(`         recorded ${s.sha256}`);
    console.log(`         now      ${got}`);
  }
}

console.log('');
if (missing > 0) {
  console.log(`FAIL: ${missing} section heading(s) no longer exist. The transcription`
    + ' is pointing at text that is gone.');
  process.exit(1);
}
if (moved > 0) {
  console.log(`FAIL: ${moved} section(s) moved since transcription. Re-read them`
    + ' against tools/verify/cache-policy.json, apply whatever actually changed,'
    + ' and update `source.commit`, `source.transcribedOn` and the `sha256`s.'
    + '\n  A moved digest is not by itself a contract change — a typo fix moves it'
    + ' too — so this asks for a reading, not for a number to be pasted over.');
  process.exit(1);
}
console.log('OK: every transcribed section is byte-identical to its recorded digest.');
