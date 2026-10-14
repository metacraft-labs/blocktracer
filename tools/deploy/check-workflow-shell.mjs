#!/usr/bin/env node
// check-workflow-shell.mjs — does every `bash -c '…'` body in this repository's
// workflows still parse as a shell script?
//
// Usage:
//   node tools/deploy/check-workflow-shell.mjs
//   node tools/deploy/check-workflow-shell.mjs --selftest
//
// ── WHY THIS EXISTS, AND IT IS A DEFECT THIS REPOSITORY SHIPPED ─────────────
//
// `publish-r2.yml` runs several steps as `nix develop .#ci --command bash -euo
// pipefail -c '<body>'`. The body is single-quoted, so ONE APOSTROPHE anywhere
// inside it — including inside a comment — ends the quote early. Everything
// after it becomes arguments to the outer shell, and the inner script is
// truncated at that point.
//
// MEASURED, run 38527745644. A comment reading `the origin's view` was added to
// a read-only diagnostic step. The step printed its first three lines, then:
//
//   -c: line 74: syntax error: unexpected end of file from `if' command on line 63
//
// Nothing caught it before the run:
//
//   * `yaml.safe_load` parses the file fine — the YAML is valid either way.
//   * `bash -n` on the step's WHOLE `run:` script passes, because
//     `bash -c '<truncated>'` is a syntactically valid outer command. The
//     failure is the INNER shell's, at runtime.
//   * the step had been driven over a synthetic tree three times, through an
//     extraction that took the body up to the LAST apostrophe rather than the
//     first — so the harness saw the whole body and the shell did not. The
//     check passed by not reproducing the thing that breaks.
//
// So the check has to extract the body THE WAY THE SHELL DOES — first
// apostrophe wins — and then parse it. That is the only version of this check
// that can fail for the right reason.
//
// ── WHAT IT DOES NOT CLAIM ─────────────────────────────────────────────────
//
// It parses; it does not run. A body that parses can still be wrong. And it
// only looks at `-c '`-quoted bodies: a step whose `run:` is plain shell is
// already covered by the outer shell's own parse, and a body quoted some other
// way is not something this repository writes. If one appears, this check will
// not see it — which is why it PRINTS the number of bodies it found, so a
// change that hides them all reads as zero rather than as green.

import { readFileSync, readdirSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const MARKER = "-c '";

// WHICH INTERPRETER, because `-c '…'` is not only bash. `publish-r2.yml` also
// runs `python3 -c '…'`, whose body has the SAME hazard — one apostrophe closes
// it early — and a different grammar. Parsing a Python body with `bash -n`
// reports a syntax error for every such body, which is a false alarm that would
// make this check useless on the day it mattered. Measured: the first sweep
// reported exactly two findings and both were Python.
const INTERPRETERS = [
  // `[^'"]*` and not `(?:-\S+\s+)*`, because the options in between are not all
  // dash-prefixed: this repository writes `bash -euo pipefail -c '…'`, and a
  // pattern that required a dash on every word matched none of its seven shell
  // bodies and reported them all unclassifiable.
  { re: /(?:^|[\s/])(?:bash|sh|zsh)\s[^'"]*$/, kind: 'shell' },
  { re: /(?:^|[\s/])python3?\s[^'"]*$/, kind: 'python' },
];

function interpreterBefore(run, at) {
  const lead = run.slice(Math.max(0, at - 200), at);
  for (const i of INTERPRETERS) if (i.re.test(lead)) return i.kind;
  return null;
}

/** Every `bash … -c '<body>'` body in one `run:` script, extracted as the shell reads it. */
export function bodiesOf(run) {
  const out = [];
  let i = 0;
  for (;;) {
    const at = run.indexOf(MARKER, i);
    if (at === -1) return out;
    const start = at + MARKER.length;
    // FIRST apostrophe, not last: that is the one that closes the quote.
    const end = run.indexOf("'", start);
    if (end === -1) {
      out.push({
        start,
        body: run.slice(start),
        unterminated: true,
        kind: interpreterBefore(run, at),
      });
      return out;
    }
    out.push({
      start,
      body: run.slice(start, end),
      unterminated: false,
      kind: interpreterBefore(run, at),
    });
    i = end + 1;
  }
}

/** `run:` scripts in a workflow file, without a YAML parser. */
export function runsOf(text) {
  const lines = text.split('\n');
  const runs = [];
  for (let i = 0; i < lines.length; i++) {
    // `- run: |` as well as `run: |`: a step's first key carries the list dash,
    // and a pattern that only matched the second form found ZERO bodies in a
    // fixture written the first way — while the arm that was supposed to prove
    // the extractor works reported [OK], because nothing to check is not a
    // finding. That is this tool's own subject, met in its own selftest.
    const m = /^(\s*)(?:-\s+)?run:\s*\|?\s*$/.exec(lines[i]);
    if (!m) continue;
    const indent = m[0].length - m[0].trimStart().length + (m[0].includes('- ') ? 2 : 0);
    const body = [];
    for (let j = i + 1; j < lines.length; j++) {
      const l = lines[j];
      if (l.trim() !== '' && (l.length - l.trimStart().length) <= indent) break;
      body.push(l);
    }
    // DEDENT, because that is what YAML does to a block scalar and therefore
    // what the runner passes. Keeping the step's indentation made every
    // `python3 -c` body an `IndentationError: unexpected indent` — a finding
    // about this parser rather than about the workflow, and one that would have
    // buried the real ones.
    const pad = Math.min(
      ...body.filter((l) => l.trim() !== '').map((l) => l.length - l.trimStart().length),
    );
    const text = body.map((l) => (l.trim() === '' ? '' : l.slice(pad))).join('\n');
    runs.push({ line: i + 1, text });
  }
  return runs;
}

function parses(body, kind) {
  const dir = mkdtempSync(join(tmpdir(), 'wfshell-'));
  const f = join(dir, kind === 'python' ? 's.py' : 's.sh');
  try {
    writeFileSync(f, body);
    if (kind === 'python') execFileSync('python3', ['-c', 'import sys,ast; ast.parse(open(sys.argv[1]).read())', f], { stdio: 'pipe' });
    else execFileSync('bash', ['-n', f], { stdio: 'pipe' });
    return null;
  } catch (e) {
    return String(e.stderr || e.message).trim().split('\n').slice(-2).join(' | ');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function sweep(dir) {
  let bodies = 0;
  const bad = [];
  const files = readdirSync(dir).filter((f) => f.endsWith('.yml') || f.endsWith('.yaml')).sort();
  for (const f of files) {
    const text = readFileSync(join(dir, f), 'utf8');
    for (const r of runsOf(text)) {
      for (const b of bodiesOf(r.text)) {
        bodies++;
        if (b.unterminated) {
          bad.push({ file: f, line: r.line, why: 'the body is never closed by an apostrophe' });
          continue;
        }
        // AN UNRECOGNISED INTERPRETER IS A FINDING, not a skip. A body this
        // check cannot classify is a body it is not checking, and silently
        // passing it is how a sweep reports green over the one thing it missed.
        if (!b.kind) {
          bad.push({ file: f, line: r.line, why: "the program before `-c '` is not one this check can parse; add it to INTERPRETERS" });
          continue;
        }
        const err = parses(b.body, b.kind);
        if (err) bad.push({ file: f, line: r.line, why: `${b.kind}: ${err}` });
      }
    }
  }
  return { files: files.length, bodies, bad };
}

function selftest() {
  const dir = mkdtempSync(join(tmpdir(), 'wfshell-arena-'));
  const arms = [];
  // EVERY ARM ASSERTS THE BODY COUNT TOO. An arm that only checks the finding
  // count is green when the extractor finds nothing, which is how this
  // selftest first reported three passes over zero bodies.
  const arm = (name, yml, expectBad, expectBodies) => {
    writeFileSync(join(dir, 'w.yml'), yml);
    const r = sweep(dir);
    const got = r.bad.length;
    const ok = (expectBad ? got > 0 : got === 0) && r.bodies === expectBodies;
    arms.push({ name, ok, got, bodies: r.bodies, wantBodies: expectBodies });
  };

  const good = [
    'jobs:', '  j:', '    steps:', '      - run: |',
    '          bash -c \'',
    '            if [ 1 = 1 ]; then',
    '              echo hi',
    '            fi',
    '          \'',
  ].join('\n');

  // The shipped defect, exactly: one apostrophe inside a COMMENT in the body.
  const withApostrophe = good.replace('              echo hi',
    '              # the origin' + "'" + 's view\n              echo hi');

  arm('a clean body parses', good, false, 1);
  // STILL ONE BODY. The extra apostrophe closes the body EARLY, it does not
  // create a second `-c '`, so the count is unchanged and only the body's
  // CONTENT differs — truncated at the comment. Expecting two here was my
  // error and the arm said so.
  arm('an apostrophe in a comment truncates the body and is caught', withApostrophe, true, 1);
  arm('an unterminated body is caught', good.replace("          '", '          # no close'), true, 1);
  // FLUSH WITH THE INVOCATION, which is how this repository writes them — see
  // `publish-r2.yml`'s index-size step. Indenting the Python body deeper than
  // its `-c '` would be an IndentationError in CI too, so a fixture written
  // that way would be testing a mistake nobody makes here.
  const pygood = [
    'jobs:', '  j:', '    steps:', '      - run: |',
    "          python3 -c '",
    '          import json',
    '          print(json.dumps({}))',
    "          '",
  ].join('\n');
  arm('a python body is parsed as python, not as shell', pygood, false, 1);
  arm('a broken python body is caught',
    pygood.replace('          print(json.dumps({}))', '          print(json.dumps({})'), true, 1);
  arm('no run: blocks at all means zero bodies, not green-by-absence',
    'jobs:\n  j:\n    steps:\n      - uses: actions/checkout@v4\n', false, 0);

  rmSync(dir, { recursive: true, force: true });

  console.log('=== check-workflow-shell selftest ===\n');
  let fails = 0;
  for (const a of arms) {
    if (!a.ok) fails++;
    console.log(`  ${a.ok ? '[OK]    ' : '[FAILED]'} ${a.name}  (findings=${a.got}, bodies=${a.bodies} want ${a.wantBodies})`);
  }
  console.log(`\n${fails === 0 ? 'PASS' : 'FAIL'} — ${arms.length - fails} of ${arms.length} arm(s)`);
  return fails === 0 ? 0 : 1;
}

if (process.argv.includes('--selftest')) process.exit(selftest());

const r = sweep(join(ROOT, '.github', 'workflows'));
console.log(`=== workflow shell bodies: ${r.bodies} in ${r.files} file(s) ===\n`);
if (r.bodies === 0) {
  console.error('::error::no `bash -c \'…\'` body was found at all. This repository writes them,');
  console.error('so zero means the extractor stopped matching, not that the risk went away.');
  process.exit(1);
}
for (const b of r.bad) console.log(`  [FAILED] ${b.file} (run: at line ${b.line}) — ${b.why}`);
if (r.bad.length === 0) {
  console.log('  [OK]     every body parses');
  process.exit(0);
}
console.error(`\n::error::${r.bad.length} workflow shell body/bodies do not parse. A single apostrophe`);
console.error('anywhere inside a `-c \'…\'` body — a comment included — closes the quote early and');
console.error('truncates the script, which the YAML parser and an outer `bash -n` both accept.');
process.exit(1);
