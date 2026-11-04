#!/usr/bin/env node
// Does `publish-r2.yml`'s publish step hand the publisher the flags the inputs asked for?
//
//   node tools/deploy/check-publish-flags.mjs
//
// ── WHY, AND IT IS A DEFECT THIS REPOSITORY SHIPPED ───────────────────────────────────
//
// The `chain` input was added in 23addfb and its `REFRESH`/`CHAIN_ARG` assembly sat BELOW
// the `dry-run` branch, so the local-backend invocation ran with neither `--chain` nor
// `--refresh` whatever the inputs said. A dry run of a one-chain publish exercised the
// every-chain path and printed "N objects would be written" for a publish nobody had
// asked for. Fixed in 2ccbd0d by hoisting the assembly — and NOTHING OFFLINE EXERCISED
// EITHER STATE, before or after. A workflow step is the one place in this repository
// where a defect costs a whole publish to discover.
//
// ── IT EXECUTES THE DECISION, IT DOES NOT READ IT ─────────────────────────────────────
//
// A static check over the YAML would assert that `$CHAIN_ARG` appears on the right line,
// which a comment could satisfy. So this extracts the step's flag-assembly FRAGMENT,
// substitutes the `${{ inputs.* }}` expressions GitHub would substitute, and RUNS it
// under bash with `blocktracer-publish` stubbed to record its argv. What is asserted is
// the argv the publisher would actually have received.
//
// The fragment is bounded by anchors rather than line numbers, and a missing anchor is a
// REFUSAL rather than a skip: the step being restructured is exactly when this must speak
// up, and a check that silently matched nothing would go quiet at that moment.

import { readFileSync, mkdtempSync, writeFileSync, mkdirSync, rmSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

// `--workflow <path>` exists so the mutation proof below can point this at a copy whose
// assembly has been moved back below the dry-run branch. A gate that cannot be aimed at a
// known-bad input is a gate whose redness nobody has seen.
const WORKFLOW = process.argv.includes("--workflow")
  ? process.argv[process.argv.indexOf("--workflow") + 1]
  : ".github/workflows/publish-r2.yml";

/** The step's whole `run:` body, dedented, without parsing YAML — the block scalar's
 *  indentation is uniform and `js-yaml` is not a dependency of this repository's gates. */
export function publishStepBody(text) {
  const lines = text.split("\n");
  const i = lines.findIndex((l) => /^\s*- name: Publish$/.test(l));
  if (i < 0) return { error: "no `- name: Publish` step in the workflow" };
  const runIdx = lines.findIndex((l, k) => k > i && /^\s*run: \|/.test(l));
  if (runIdx < 0) return { error: "the Publish step has no `run: |` block" };
  const indent = lines[runIdx + 1].match(/^\s*/)[0].length;
  const out = [];
  for (let k = runIdx + 1; k < lines.length; k++) {
    const l = lines[k];
    if (l.trim() === "") { out.push(""); continue; }
    if (l.match(/^\s*/)[0].length < indent) break;
    out.push(l.slice(indent));
  }
  return { body: out.join("\n") };
}

/** From `REFRESH=""` through the end of the dry-run branch: the decision under test. */
export function flagFragment(body) {
  const start = body.indexOf('REFRESH=""');
  if (start < 0) return { error: 'the body no longer contains `REFRESH=""`' };
  const marker = 'if [ "${{ inputs.dry-run }}" = "true" ]; then';
  const dry = body.indexOf(marker, start);
  if (dry < 0) return { error: "the dry-run branch is not below the flag assembly — " +
    "which is the defect 2ccbd0d fixed, so this is a refusal and not a parse failure" };
  // To the end of the branch: `exit 0` is its last statement, and the `fi` after it
  // closes the branch. (Two further bindings stood here, computed while this was being
  // written and read by nothing — found by auditing my own files for exactly that, after
  // three such values turned out to be the night's actual defects.)
  const tail = body.indexOf("exit 0", dry);
  if (tail < 0) return { error: "the dry-run branch has no `exit 0`" };
  const fiAfter = body.indexOf("fi", tail);
  return { fragment: body.slice(start, fiAfter + 2) };
}

/** Substitute the expressions GitHub would. An expression this does not know is a
 *  REFUSAL: a silently-empty input would make every assertion below vacuous. */
export function render(fragment, inputs) {
  const unknown = [];
  const out = fragment.replace(/\$\{\{\s*inputs\.([a-z-]+)\s*\}\}/g, (_, name) => {
    if (!(name in inputs)) { unknown.push(name); return ""; }
    return String(inputs[name]);
  });
  return unknown.length ? { error: `the fragment names inputs this check does not set: ${[...new Set(unknown)].join(", ")}` }
                        : { rendered: out };
}

export function runFragment(rendered, { chainsInTree = ["demo"] } = {}) {
  const dir = mkdtempSync(join(tmpdir(), "pubflags-"));
  try {
    for (const c of chainsInTree) mkdirSync(join(dir, "site", "d", c), { recursive: true });
    mkdirSync(join(dir, "bin"), { recursive: true });
    const rec = join(dir, "argv.txt");
    // The stub records argv and nothing else. `nix develop … --command X …` is stubbed too,
    // so the fragment's own `nix` wrapper does not need the store.
    for (const name of ["blocktracer-publish", "nix"]) {
      const p = join(dir, "bin", name);
      writeFileSync(p, `#!/bin/sh\nprintf '%s\\n' "${name} $*" >> ${JSON.stringify(rec)}\nexit 0\n`);
      chmodSync(p, 0o755);
    }
    // `./blocktracer-publish` is called by path, so the stub goes there as well.
    writeFileSync(join(dir, "blocktracer-publish"),
      `#!/bin/sh\nprintf '%s\\n' "blocktracer-publish $*" >> ${JSON.stringify(rec)}\nexit 0\n`);
    chmodSync(join(dir, "blocktracer-publish"), 0o755);
    const script = join(dir, "frag.sh");
    writeFileSync(script, `set -uo pipefail\nRUNNER_TEMP=${JSON.stringify(join(dir, "tmp"))}\nmkdir -p "$RUNNER_TEMP"\n${rendered}\n`);
    const r = spawnSync("bash", [script], {
      cwd: dir, encoding: "utf8", timeout: 20_000,
      env: { ...process.env, PATH: `${join(dir, "bin")}:${process.env.PATH}` },
    });
    let argv = "";
    try { argv = readFileSync(rec, "utf8"); } catch { argv = ""; }
    return { status: r.status, out: `${r.stdout}${r.stderr}`, argv };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

const CASES = [
  { name: "a dry run of ONE chain rehearses that chain",
    inputs: { "render-over-live": "false", refresh: "false", chain: "demo", "dry-run": "true" },
    want: [/blocktracer-publish .*--backend local/, /--chain demo/] },
  { name: "a dry run with --refresh rehearses the refresh",
    inputs: { "render-over-live": "false", refresh: "true", chain: "", "dry-run": "true" },
    want: [/--backend local/, /--refresh/] },
  { name: "a dry run of every chain names no chain",
    inputs: { "render-over-live": "false", refresh: "false", chain: "", "dry-run": "true" },
    want: [/--backend local/], notWant: [/--chain/] },
  { name: "render-over-live implies --refresh even when refresh is false",
    inputs: { "render-over-live": "true", refresh: "false", chain: "", "dry-run": "true" },
    want: [/--refresh/] },
  { name: "a chain that is not in the tree is REFUSED, in a dry run too",
    inputs: { "render-over-live": "false", refresh: "false", chain: "nosuch", "dry-run": "true" },
    wantStatus: 1, want: [], notWant: [/blocktracer-publish/],
    says: /chain 'nosuch' is not in this tree/ },
];

export function main() {
  let text;
  try { text = readFileSync(WORKFLOW, "utf8"); }
  catch (e) { console.log(`::error::${WORKFLOW} is unreadable: ${e.message}`); return 1; }
  const step = publishStepBody(text);
  if (step.error) { console.log(`::error::${step.error}`); return 1; }
  const frag = flagFragment(step.body);
  if (frag.error) { console.log(`::error::${frag.error}`); return 1; }

  let failures = 0;
  for (const c of CASES) {
    const r = render(frag.fragment, c.inputs);
    if (r.error) { console.log(`  FAIL  ${c.name}\n        ${r.error}`); failures += 1; continue; }
    const got = runFragment(r.rendered);
    const problems = [];
    const wantStatus = c.wantStatus ?? 0;
    if (got.status !== wantStatus) problems.push(`exit ${got.status}, wanted ${wantStatus}`);
    for (const re of c.want ?? []) if (!re.test(got.argv)) problems.push(`argv did not match ${re}`);
    for (const re of c.notWant ?? []) if (re.test(got.argv)) problems.push(`argv matched ${re} and should not`);
    if (c.says && !c.says.test(got.out)) problems.push(`output did not match ${c.says}`);
    if (problems.length) {
      failures += 1;
      console.log(`  FAIL  ${c.name}`);
      for (const p of problems) console.log(`        ${p}`);
      console.log(`        argv: ${got.argv.trim().replace(/\n/g, " | ") || "(nothing recorded)"}`);
    } else {
      console.log(`  ok    ${c.name}`);
    }
  }
  const asserted = CASES.length;
  if (asserted !== 5) { console.log(`  FAIL  this check declares 5 cases and ran ${asserted}`); failures += 1; }
  console.log(failures === 0
    ? `\nthe publish step hands the publisher the flags the inputs ask for — ${asserted} case(s)`
    : `\n${failures} of ${asserted} case(s) did not decide as written.`);
  return failures === 0 ? 0 : 1;
}

if (import.meta.url === `file://${process.argv[1]}`) process.exit(main());
