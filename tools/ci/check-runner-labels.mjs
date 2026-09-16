#!/usr/bin/env node
// ---------------------------------------------------------------------------
// DOES EVERY `runs-on` IN THIS REPOSITORY NAME SOMETHING THAT CAN ACTUALLY RUN?
//
// THE FAILURE THIS EXISTS FOR, and why nothing else caught it for a week.
//
// A `runs-on` that matches no runner DOES NOT FAIL THE JOB. It queues. Forever.
// The run stays yellow, no check goes red, no notification fires, and the only
// symptom is downstream and mute: the site keeps serving an older commit.
//
// That is not hypothetical. `eph-linux-x64` stopped being served on 2026-09-14
// — the last job in this repository to get a runner for it started at
// 23:46:22Z that day — and the `Deploy` run for `a145e685` sat queued from
// 2026-09-15T10:03Z with no runner and no error. `blocktracer-dev.pages.dev`
// served `d09416eb` (2026-09-09) throughout. Five merged PRs' worth of work was
// never deployed anywhere, and every dashboard in the repository was green,
// because "queued" is not "failed" and nothing was asking the question this
// file asks.
//
// WHY THE OBVIOUS CHECK IS THE WRONG ONE. The natural implementation is "sweep
// the org's online runners, fail if a label is unclaimed".
// `infra/docs/CI-Runner-Fleet-Status.md` §2 explicitly names that sweep as a
// FALSE-ALARM GENERATOR, and it is right: the capability pools are
// SCALE-TO-ZERO, so an idle class legitimately shows zero online runners as its
// normal resting state. A guard built on that sweep would have screamed about
// `eph-macos-arm64` (which served a job 20 minutes before this was written)
// while saying nothing useful, and it would have passed `eph-linux-x64` happily
// on any day the pool happened to be mid-job.
//
// So the GATING check here is OFFLINE and does not ask the fleet what is awake.
// It asks two questions that are true regardless of scale-to-zero:
//
//   1. Is every label in the taxonomy's VOCABULARY? An invented or retired
//      label — `eph-linux-x64`, a typo, a withdrawn alias — can never be served
//      by anything, idle or not.
//   2. Is the requested set a SUBSET of at least one runner CLASS the fleet
//      actually defines? This is the over-request half, and it is the same bug
//      from the other side: `[self-hosted, linux, x64, topology-host, gpu]`
//      names five real labels and no single host carries all five, so it queues
//      forever exactly like a typo does.
//
// The `--online` mode adds live corroboration for an operator with a token. It
// is NOT the gate, for the scale-to-zero reason above, and it ABORTS rather
// than passing when the API returns nothing — see `checkOnline`.
//
// Offline, node-only, no dependencies, and it runs on `ubuntu-latest` in
// `ci.yml`'s `deploy-gates` job: a guard that needs the runner pool to prove
// the runner pool is misconfigured is a guard that cannot report the outage it
// was written for.
// ---------------------------------------------------------------------------

import { readFileSync, readdirSync } from "node:fs";
import { resolve, dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = resolve(HERE, "..", "..");

// ---------------------------------------------------------------------------
// THE TAXONOMY. Source: `metacraft-dev-guidelines`
// `policies/ci-workflow-standards.md` §"Capability-label taxonomy (versioned)",
// taxonomy version 1. Keep this in lock-step with that document; it is mirrored
// rather than fetched so the gate stays offline and cannot be broken by a
// network blip.
// ---------------------------------------------------------------------------

export const TAXONOMY_VERSION = 1;

// Manifest-derived: proven by a host's signed `/v1/manifest`.
const MANIFEST_DERIVED = [
  "self-hosted",
  "linux", "windows", "macos",
  "x64", "arm64",
  "x86-64-v2", "x86-64-v3", "x86-64-v4",
  "gpu",
  "rr-hw-counters",
  "incus", "libvirt", "hyperv", "tart",
];

// Policy / attested: provisioning facts the hardware manifest cannot prove.
// `org:<name>` is handled by prefix, not by membership.
const POLICY_ATTESTED = [
  "ephemeral",
  "dev-env-ready",
  "benchmark",
  "benchmark-isolated",
  // Persistent-host labels from the guidelines' "Canonical runner labels"
  // table. They are not manifest-derived capabilities but they are the
  // documented way to target the persistent NixOS / Darwin fleet.
  "nixos",
  "bare-metal",
  "topology-host",
  "darwin", "nix-darwin", "aarch64-darwin",
];

export const VOCABULARY = new Set([...MANIFEST_DERIVED, ...POLICY_ATTESTED]);

// Labels that USED to route and must never appear again. Each carries the
// replacement, so the error message is a fix and not just a complaint.
export const RETIRED = new Map([
  ["eph-linux-x64", "[self-hosted, linux, x64]"],
  ["eph-linux-x64-nested", "[self-hosted, linux, x64]"],
  ["eph-linux-x64-g1", "[self-hosted, linux, x64]"],
  ["eph-linux-x64-g2", "[self-hosted, linux, x64]"],
  ["eph-linux-x64-gpu", "[self-hosted, linux, x64, gpu]"],
  ["eph-linux-x64-gpu-2", "[self-hosted, linux, x64, gpu]"],
  ["eph-linux-arm64", "[self-hosted, linux, arm64]"],
  ["eph-macos-arm64", "[self-hosted, macos, arm64]"],
  ["eph-win-x64", "[self-hosted, windows, x64]"],
  ["eph-win-x64-release", "[self-hosted, windows, x64]"],
  ["eph-win-arm64", "[self-hosted, windows, arm64]"],
  // Renamed 2026-08-19; both names are still advertised, but new and edited
  // workflows must use `dev-env-ready` so the old one can be withdrawn.
  ["nixos-equivalent", "dev-env-ready"],
]);

// Explicitly NOT routing labels. The guidelines removed these once every runner
// image gained universal container + nested-VM support: asking for them narrows
// the pool and buys nothing, and under the old draft they DID route, so a
// copy-pasted workflow can still carry them.
export const NON_ROUTING = new Map([
  ["docker", "every runner can run containers; drop the label"],
  ["podman", "every runner can run containers; drop the label"],
  ["nested", "every runner can boot nested VMs; drop the label"],
  ["x86-64-v1", "every x86-64 host has it, so it carries no routing value"],
]);

// GitHub-hosted runners. A narrow, documented migration exception in the
// guidelines — permitted, but only by exact name, so a typo'd `ubuntu-latests`
// is caught rather than treated as a self-hosted label.
export const GITHUB_HOSTED = new Set([
  "ubuntu-latest", "ubuntu-24.04", "ubuntu-22.04",
  "macos-latest", "macos-15", "macos-14",
  "windows-latest", "windows-2025", "windows-2022",
]);

// ---------------------------------------------------------------------------
// THE FLEET'S CLASSES. What label sets an actual host can carry.
//
// This is the offline stand-in for "does a capable host exist", and it is what
// makes the over-request half checkable without the API. Sources, which agree:
// the guidelines' "Canonical runner labels" table, and the label sets observed
// on the live org runner list on 2026-09-16.
//
// A `runs-on` set is servable iff it is a SUBSET of at least one class here.
// ---------------------------------------------------------------------------

export const FLEET_CLASSES = [
  {
    name: "persistent NixOS GPU hosts (gpu-server-001, gpu-server-002)",
    labels: ["self-hosted", "linux", "x64", "nixos", "bare-metal",
             "x86-64-v2", "x86-64-v3", "rr-hw-counters", "gpu",
             "benchmark", "benchmark-isolated"],
  },
  {
    name: "persistent NixOS high-mem host (high-mem-server)",
    labels: ["self-hosted", "linux", "x64", "nixos", "bare-metal",
             "x86-64-v2", "topology-host"],
  },
  {
    name: "persistent Darwin hosts (m3)",
    labels: ["self-hosted", "macos", "arm64", "darwin", "nix-darwin",
             "aarch64-darwin", "benchmark"],
  },
  {
    name: "persistent Windows hosts (win-ci-vm-001, win-ci-bare-001)",
    labels: ["self-hosted", "windows", "x64", "dev-env-ready"],
  },
  {
    name: "ephemeral Linux x64 capability pool (GARM, scale-to-zero)",
    labels: ["self-hosted", "linux", "x64", "x86-64-v2", "x86-64-v3",
             "ephemeral", "dev-env-ready", "incus", "libvirt",
             "gpu", "rr-hw-counters"],
  },
  {
    name: "ephemeral Linux arm64 capability pool (GARM, scale-to-zero)",
    labels: ["self-hosted", "linux", "arm64", "ephemeral", "dev-env-ready",
             "incus", "libvirt"],
  },
  {
    name: "ephemeral Windows x64 capability pool (GARM, scale-to-zero)",
    labels: ["self-hosted", "windows", "x64", "ephemeral", "dev-env-ready",
             "libvirt"],
  },
  {
    name: "ephemeral macOS arm64 pool (tart, scale-to-zero)",
    labels: ["self-hosted", "macos", "arm64", "darwin", "aarch64-darwin",
             "ephemeral", "tart"],
  },
];

// ---------------------------------------------------------------------------
// Label comparison is CASE-INSENSITIVE, and that is not a guess.
//
// GitHub normalises the OS/arch labels a runner reports (`Linux`, `X64`,
// `Windows`, `macOS`, `ARM64`) while the guidelines and every workflow spell
// them lowercase. Measured proof that the two match: on 2026-09-14T13:46:02Z
// `metacraft-labs/codetracer-ruby-recorder` ran a job whose required labels
// were `[self-hosted, linux, x64]` on `gpu-server-002-mcl-004`, whose
// advertised set is `self-hosted,Linux,X64,nixos,…`. Lowercase request,
// capitalised advertisement, job placed.
// ---------------------------------------------------------------------------
export const fold = (s) => String(s).trim().toLowerCase();

// ---------------------------------------------------------------------------
// EXTRACTING `runs-on`
//
// Deliberately a small targeted parser and not a YAML library: these gates are
// node-only with no dependencies on purpose (see `ci.yml`'s `deploy-gates`), so
// they can run on a GitHub-hosted runner without provisioning Nix first.
//
// Handles the three shapes that occur, and REFUSES anything it cannot classify
// rather than skipping it — a `runs-on` this parser silently ignored would
// reproduce the exact invisibility the file exists to end.
// ---------------------------------------------------------------------------

export function extractRunsOn(text, file = "<memory>") {
  const lines = text.split("\n");
  const sites = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Skip comment lines so prose mentioning `runs-on:` is not parsed as one.
    if (/^\s*#/.test(line)) continue;
    const m = line.match(/^(\s*)runs-on:(.*)$/);
    if (!m) continue;

    const indent = m[1].length;
    let raw = m[2].replace(/\s+#.*$/, "").trim();

    // Block sequence:  runs-on:\n  - self-hosted\n  - linux
    if (raw === "") {
      const items = [];
      for (let j = i + 1; j < lines.length; j++) {
        const l = lines[j];
        if (/^\s*$/.test(l)) continue;
        if (/^\s*#/.test(l)) continue;
        const im = l.match(/^(\s*)-\s*(.+?)\s*$/);
        if (!im || im[1].length <= indent) break;
        items.push(im[2].replace(/^["']|["']$/g, ""));
      }
      sites.push({ file, line: i + 1, kind: "array", labels: items, raw: "(block sequence)" });
      continue;
    }

    sites.push({ file, line: i + 1, raw, ...classifyRunsOn(raw) });
  }

  return sites;
}

function classifyRunsOn(raw) {
  // Flow array: [a, b, c]
  if (raw.startsWith("[")) {
    const inner = raw.slice(1, raw.lastIndexOf("]"));
    const labels = inner.split(",")
      .map((s) => s.trim().replace(/^["']|["']$/g, ""))
      .filter((s) => s.length > 0);
    return { kind: "array", labels };
  }

  // An expression.
  if (raw.includes("${{")) {
    const expr = raw.replace(/^\$\{\{\s*/, "").replace(/\s*\}\}$/, "").trim();

    // `fromJSON('["a","b"]')` — a literal we can resolve here.
    const lit = expr.match(/^fromJSON\(\s*'(.*)'\s*\)$/) || expr.match(/^fromJSON\(\s*"(.*)"\s*\)$/);
    if (lit) {
      try {
        const parsed = JSON.parse(lit[1]);
        if (Array.isArray(parsed)) return { kind: "array", labels: parsed.map(String) };
      } catch { /* fall through to unresolved */ }
      return { kind: "bad-expression", detail: `fromJSON of a literal that is not a JSON array: ${lit[1]}` };
    }

    // `fromJSON(inputs.runner)` — resolvable from the input's declared default.
    const viaInput = expr.match(/^fromJSON\(\s*inputs\.([A-Za-z0-9_-]+)\s*\)$/);
    if (viaInput) return { kind: "input-json", input: viaInput[1] };

    // Anything else, including the bare `${{ inputs.runner }}` that carried a
    // plain string and started all this.
    return { kind: "bad-expression", detail: expr };
  }

  // A bare scalar. This is the retired-class shape.
  return { kind: "scalar", labels: [raw.replace(/^["']|["']$/g, "")] };
}

// Resolve `fromJSON(inputs.X)` against the `default:` declared for input X in
// the SAME file. A reusable workflow's default is what every caller that does
// not override it actually gets — `deploy.yml` overrides nothing, so the
// default is the live value and must be checked.
export function resolveInputDefault(text, inputName) {
  const re = new RegExp(`^(\\s*)${inputName}:\\s*$`, "m");
  const m = text.match(re);
  if (!m) return { ok: false, reason: `no input named '${inputName}' is declared in this file` };
  const start = text.indexOf(m[0]);
  const indent = m[1].length;
  const rest = text.slice(start + m[0].length).split("\n");

  for (const line of rest) {
    if (/^\s*$/.test(line)) continue;
    const cur = line.match(/^(\s*)\S/);
    if (!cur || cur[1].length <= indent) break; // left the input's block
    const d = line.match(/^\s*default:\s*(.+?)\s*$/);
    if (!d) continue;
    let v = d[1];
    // Strip one layer of surrounding quotes.
    if ((v.startsWith("'") && v.endsWith("'")) || (v.startsWith('"') && v.endsWith('"'))) {
      v = v.slice(1, -1);
    }
    try {
      const parsed = JSON.parse(v);
      if (Array.isArray(parsed)) return { ok: true, labels: parsed.map(String) };
      return { ok: false, reason: `default is not a JSON array: ${d[1]}` };
    } catch {
      return { ok: false, reason: `default is not parseable JSON: ${d[1]} — a bare label string here is the bug this gate exists for` };
    }
  }
  return { ok: false, reason: `input '${inputName}' declares no default` };
}

// ---------------------------------------------------------------------------
// THE RULES
// ---------------------------------------------------------------------------

export function checkLabelSet(labels) {
  const problems = [];
  const folded = labels.map(fold);

  if (labels.length === 0) {
    problems.push("empty label set");
    return problems;
  }

  for (const l of folded) {
    if (RETIRED.has(l)) {
      problems.push(
        `'${l}' is a RETIRED runner class, not a label any runner still advertises. ` +
        `Use ${RETIRED.get(l)}. A runs-on that matches nothing does not fail — it queues forever.`,
      );
      continue;
    }
    if (NON_ROUTING.has(l)) {
      problems.push(`'${l}' is not a routing label — ${NON_ROUTING.get(l)}`);
      continue;
    }
    if (l.startsWith("org:")) continue; // prefix-namespaced, always allowed
    if (!VOCABULARY.has(l)) {
      problems.push(
        `'${l}' is not in the capability-label vocabulary (taxonomy v${TAXONOMY_VERSION}). ` +
        `If it is a new capability, add it in infra and in the guidelines first.`,
      );
    }
  }

  if (problems.length) return problems;

  if (!folded.includes("self-hosted")) {
    problems.push(
      "a self-hosted label array must include 'self-hosted' — without it GitHub " +
      "will look for a GitHub-hosted image by that name",
    );
  }

  // The over-request half: does any single class carry all of these?
  const servable = FLEET_CLASSES.filter((c) => {
    const have = new Set(c.labels.map(fold));
    return folded.every((l) => l.startsWith("org:") || have.has(l));
  });
  if (servable.length === 0) {
    problems.push(
      `no runner class in the fleet carries all of [${labels.join(", ")}]. ` +
      `Every label is real, but no single host has the whole set, so this queues forever. ` +
      `Request the minimum the job actually needs.`,
    );
  }

  return problems;
}

export function checkSites(sites, fileTexts = new Map()) {
  const findings = [];

  for (const s of sites) {
    const where = `${s.file}:${s.line}`;

    if (s.kind === "scalar") {
      const one = fold(s.labels[0]);
      if (GITHUB_HOSTED.has(one)) continue; // documented migration exception
      if (RETIRED.has(one)) {
        findings.push({ where, raw: s.raw, problems: [
          `'${one}' is a RETIRED runner class. Use ${RETIRED.get(one)}. ` +
          `It is served by nothing, and a runs-on that matches nothing queues forever without going red.`,
        ] });
        continue;
      }
      findings.push({ where, raw: s.raw, problems: [
        `bare scalar '${s.raw}' is neither a known GitHub-hosted image nor a label array. ` +
        `Self-hosted runners are targeted by a label ARRAY, e.g. [self-hosted, linux, x64].`,
      ] });
      continue;
    }

    if (s.kind === "array") {
      const problems = checkLabelSet(s.labels);
      if (problems.length) findings.push({ where, raw: s.raw, problems });
      continue;
    }

    if (s.kind === "input-json") {
      const text = fileTexts.get(s.file);
      if (text === undefined) {
        findings.push({ where, raw: s.raw, problems: [
          `cannot resolve inputs.${s.input}: source of ${s.file} not available to the checker`,
        ] });
        continue;
      }
      const r = resolveInputDefault(text, s.input);
      if (!r.ok) {
        findings.push({ where, raw: s.raw, problems: [
          `fromJSON(inputs.${s.input}) could not be proven servable — ${r.reason}`,
        ] });
        continue;
      }
      const problems = checkLabelSet(r.labels);
      if (problems.length) findings.push({ where, raw: `${s.raw} -> default [${r.labels.join(", ")}]`, problems });
      continue;
    }

    findings.push({ where, raw: s.raw, problems: [
      `runs-on is an expression this gate cannot resolve (${s.detail}). ` +
      `A label set that cannot be read cannot be checked, and an unservable one queues forever. ` +
      `Use a literal array, or fromJSON() of an input whose default is a JSON array.`,
    ] });
  }

  return findings;
}

// ---------------------------------------------------------------------------
// LIVE CORROBORATION (`--online`)
//
// NOT the gate — see this file's header for why an online sweep cannot tell a
// scale-to-zero pool from a dead one. What it IS good for: catching drift
// between `FLEET_CLASSES` above and the fleet as it actually is, which is the
// one thing the offline check cannot do.
//
// It ABORTS (exit 2) when the API yields nothing. A check that "passes" over an
// empty set has measured nothing and reported success, which is the failure
// mode this whole file is about, one level up.
// ---------------------------------------------------------------------------

export function onlineSupersets(labels, runners) {
  const folded = labels.map(fold);
  return runners.filter((r) => {
    const have = new Set((r.labels || []).map((l) => fold(l.name ?? l)));
    return folded.every((l) => l.startsWith("org:") || have.has(l));
  });
}

export async function fetchOrgRunners(org, token) {
  const out = [];
  for (let page = 1; page <= 20; page++) {
    const res = await fetch(
      `https://api.github.com/orgs/${org}/actions/runners?per_page=100&page=${page}`,
      {
        headers: {
          Accept: "application/vnd.github+json",
          "X-GitHub-Api-Version": "2022-11-28",
          Authorization: `Bearer ${token}`,
        },
      },
    );
    if (!res.ok) {
      throw new Error(`GET /orgs/${org}/actions/runners returned HTTP ${res.status}`);
    }
    const body = await res.json();
    const runners = body.runners || [];
    out.push(...runners);
    if (runners.length < 100) break;
  }
  return out;
}

export function checkOnline(sites, fileTexts, runners) {
  // ABORT, never pass, over an empty measurement.
  if (!Array.isArray(runners) || runners.length === 0) {
    return { abort: true, reason: "the org runner list came back EMPTY; this check measured nothing and refuses to report success" };
  }
  const online = runners.filter((r) => r.status === "online" && (r.labels || []).length > 0);
  if (online.length === 0) {
    return { abort: true, reason: `all ${runners.length} registered runners are offline or label-less; nothing to check against` };
  }

  const results = [];
  for (const s of sites) {
    let labels = null;
    if (s.kind === "array") labels = s.labels;
    else if (s.kind === "input-json") {
      const r = resolveInputDefault(fileTexts.get(s.file) ?? "", s.input);
      if (r.ok) labels = r.labels;
    } else if (s.kind === "scalar" && GITHUB_HOSTED.has(fold(s.labels[0]))) {
      continue;
    }
    if (!labels) continue;
    const matches = onlineSupersets(labels, online);
    results.push({ where: `${s.file}:${s.line}`, labels, matches: matches.map((m) => m.name) });
  }
  return { abort: false, online: online.length, results };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

export function workflowFiles(root = REPO_ROOT) {
  const dir = join(root, ".github", "workflows");
  return readdirSync(dir)
    .filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"))
    .sort()
    .map((f) => join(dir, f));
}

async function main() {
  const wantOnline = process.argv.includes("--online");
  const files = workflowFiles();
  const fileTexts = new Map();
  const sites = [];

  for (const f of files) {
    const rel = `.github/workflows/${basename(f)}`;
    const text = readFileSync(f, "utf8");
    fileTexts.set(rel, text);
    sites.push(...extractRunsOn(text, rel));
  }

  console.log(`check-runner-labels: taxonomy v${TAXONOMY_VERSION}, ${sites.length} runs-on site(s) across ${files.length} workflow file(s)`);
  console.log("");

  const findings = checkSites(sites, fileTexts);

  for (const s of sites) {
    const bad = findings.find((f) => f.where === `${s.file}:${s.line}`);
    const mark = bad ? "REFUSED" : "ok     ";
    console.log(`  ${mark}  ${s.file}:${s.line}  ${s.raw}`);
  }

  if (findings.length) {
    console.log("");
    for (const f of findings) {
      console.log(`REFUSED ${f.where}  ${f.raw}`);
      for (const p of f.problems) console.log(`        - ${p}`);
    }
    console.log("");
    console.log(`check-runner-labels: FAIL — ${findings.length} runs-on site(s) name something no runner can serve.`);
    console.log("A job with such a runs-on does not go red. It queues until someone notices the deploy is stale.");
    process.exit(1);
  }

  console.log("");
  console.log(`check-runner-labels: PASS — every runs-on resolves to a real, servable capability set (offline check).`);

  if (wantOnline) {
    const token = process.env.RUNNER_AUDIT_TOKEN || process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
    if (!token) {
      console.log("");
      console.log("--online: NO TOKEN (set RUNNER_AUDIT_TOKEN or GH_TOKEN). Refusing to report an unmeasured pass.");
      process.exit(2);
    }
    let runners;
    try {
      runners = await fetchOrgRunners(process.env.RUNNER_AUDIT_ORG || "metacraft-labs", token);
    } catch (e) {
      console.log("");
      console.log(`--online: ABORT — ${e.message}`);
      process.exit(2);
    }
    const r = checkOnline(sites, fileTexts, runners);
    if (r.abort) {
      console.log("");
      console.log(`--online: ABORT — ${r.reason}`);
      process.exit(2);
    }
    console.log("");
    console.log(`--online: ${r.online} online labelled runner(s) in the org`);
    let unresolved = 0;
    for (const res of r.results) {
      if (res.matches.length === 0) {
        unresolved++;
        console.log(`  NO ONLINE MATCH  ${res.where}  [${res.labels.join(", ")}]`);
      } else {
        console.log(`  ${String(res.matches.length).padStart(2)} online  ${res.where}  [${res.labels.join(", ")}]  e.g. ${res.matches[0]}`);
      }
    }
    if (unresolved) {
      console.log("");
      console.log(`--online: ${unresolved} label set(s) have no ONLINE superset right now.`);
      console.log("This is a WARNING, not a verdict: the capability pools are scale-to-zero, so an idle");
      console.log("class legitimately shows nothing online (infra/docs/CI-Runner-Fleet-Status.md §2).");
      console.log("Judge by whether jobs for that set are STARTING, not by who is awake.");
    }
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  await main();
}
