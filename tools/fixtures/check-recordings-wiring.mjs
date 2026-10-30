#!/usr/bin/env node
// Every workflow job that builds or runs something reading the generated
// recordings must first materialise them.
//
// WHY THIS EXISTS. 647283f made all 55 `.ct` fixtures generated rather than
// tracked and wired `prepare-recordings` into the Justfile recipes. Jobs that
// drive `nim c -r` or `static_export` directly bypass those recipes, and the
// gap was then found three separate times, each by a red run rather than by a
// check:
//
//   1. `client-sdk`, `viewmodels`, `visual-design-canary` — `cannot open
//      .../zk_shields.ct`.
//   2. `journeys-bite` x8 — invisible until then, because it `needs: journeys`
//      and `journeys` was red for an unrelated reason, so every shard was
//      SKIPPED rather than failing.
//   3. `publish-r2.yml` — found only after a production run had staged 460k
//      objects and promoted three generations, then died on the same `open`.
//
// Each fix chased the jobs that were red instead of asking which jobs bypass
// the recipes. This asks that question, over every workflow, every time.
//
// WHAT COUNTS AS MATERIALISING: `nix build .#fixture-recordings`, or any
// `just` recipe, since the Justfile's recipes declare `prepare-recordings` as
// a dependency. A job that does neither but runs a working-tree build of
// something that opens `client/fixtures/**` or `fixtures/trace/**` is a
// finding.
import { readFileSync, readdirSync } from 'node:fs';
import { join, dirname, basename } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');
const WF = join(ROOT, '.github/workflows');

// Commands that build or run something which opens the recordings from the
// WORKING TREE. `nix build .#default` is NOT one: it builds in a derivation
// that has the recordings as an input.
const READS_TREE = [
  /\bnim\s+c\s+-r\b/,
  /\bsrc\/static_export\b/,
  /\bstatic_export\.nim\b/,
];
const MATERIALISES = [
  /nix build[^\n]*\.#fixture-recordings/,
  /\bjust\s+[a-z]/,          // any just recipe: the Justfile declares the dep
  /prepare-recordings/,
];

/** The `run:` bodies of one job, without a YAML parser. */
export function jobsOf(text) {
  const lines = text.split('\n');
  const jobs = [];
  let cur = null;
  let inRun = false;
  let runIndent = 0;
  for (const line of lines) {
    const m = /^  ([A-Za-z0-9_-]+):\s*$/.exec(line);
    if (m) { cur = { name: m[1], run: '' }; jobs.push(cur); inRun = false; continue; }
    if (!cur) continue;
    const r = /^(\s*)(?:-\s+)?run:\s*(\|[-+]?)?\s*(.*)$/.exec(line);
    if (r) {
      inRun = true; runIndent = r[1].length;
      if (r[3]) cur.run += r[3] + '\n';
      continue;
    }
    if (inRun) {
      if (line.trim() === '') { cur.run += '\n'; continue; }
      const ind = line.length - line.trimStart().length;
      if (ind > runIndent) { cur.run += line.trim() + '\n'; continue; }
      inRun = false;
    }
  }
  return jobs;
}

export function sweep(dir) {
  const bad = [];
  let checked = 0;
  for (const f of readdirSync(dir).filter((n) => n.endsWith('.yml')).sort()) {
    const text = readFileSync(join(dir, f), 'utf8');
    for (const job of jobsOf(text)) {
      const body = job.run;
      if (!READS_TREE.some((re) => re.test(body))) continue;
      checked++;
      if (MATERIALISES.some((re) => re.test(body))) continue;
      bad.push({ file: f, job: job.name });
    }
  }
  return { checked, bad };
}

function selftest() {
  const arms = [];
  const arm = (name, ok) => arms.push({ name, ok });
  const wrap = (body) =>
    `jobs:\n  j:\n    steps:\n      - run: |\n${body.split('\n').map((l) => '          ' + l).join('\n')}\n`;

  const reads = 'nix develop .#ci --command nim c -r tests/t.nim';
  arm('a job that reads the tree and does NOT materialise is a finding',
    jobsOf(wrap(reads)).length === 1 &&
    READS_TREE.some((r) => r.test(jobsOf(wrap(reads))[0].run)) &&
    !MATERIALISES.some((r) => r.test(jobsOf(wrap(reads))[0].run)));

  const withNix = `nix build .#fixture-recordings --out-link x\n${reads}`;
  arm('…and materialising with `nix build .#fixture-recordings` clears it',
    MATERIALISES.some((r) => r.test(jobsOf(wrap(withNix))[0].run)));

  const withJust = `just prepare-recordings\n${reads}`;
  arm('…and a `just` recipe clears it too',
    MATERIALISES.some((r) => r.test(jobsOf(wrap(withJust))[0].run)));

  arm('a job that does not read the tree is not examined',
    !READS_TREE.some((r) => r.test(jobsOf(wrap('echo hello'))[0].run)));

  // `nix build .#default` builds in a derivation that HAS the recordings.
  arm('`nix build .#default` alone is not a reader',
    !READS_TREE.some((r) => r.test(jobsOf(wrap('nix build .#default'))[0].run)));

  console.log('=== check-recordings-wiring selftest ===\n');
  let fails = 0;
  for (const a of arms) {
    if (!a.ok) fails++;
    console.log(`  ${a.ok ? '[OK]    ' : '[FAILED]'} ${a.name}`);
  }
  console.log(`\n${fails === 0 ? 'PASS' : 'FAIL'} — ${arms.length - fails} of ${arms.length} arm(s)`);
  return fails === 0 ? 0 : 1;
}

// A MAIN GUARD, so the module can be imported by a test without sweeping the
// real tree and calling `process.exit` before the test's own code runs —
// which is exactly what happened the first time this gate's bite was checked.
const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isMain && process.argv.includes('--selftest')) process.exit(selftest());
if (!isMain) { /* imported: expose jobsOf/sweep and do nothing else */ }
else {

const r = sweep(WF);
console.log(`=== recordings wiring: ${r.checked} job(s) build or run from the working tree ===\n`);
if (r.checked === 0) {
  console.error('::error::no job was found to read the tree at all. This repository has several,');
  console.error('so zero means the matcher stopped matching, not that the risk went away.');
  process.exit(1);
}
for (const b of r.bad) {
  console.log(`  [FAILED] ${b.file}  job \`${b.job}\` builds from the working tree but never materialises the recordings`);
}
if (r.bad.length === 0) {
  console.log('  [OK]     every one of them materialises the recordings first');
  process.exit(0);
}
console.error(`\n::error::${r.bad.length} job(s) will die on \`cannot open .../*.ct\`. Add, before the build:`);
console.error('  nix build .#fixture-recordings --out-link "$RUNNER_TEMP/fixture-recordings"');
console.error('  cp -r "$RUNNER_TEMP/fixture-recordings"/. .');
process.exit(1);

}
