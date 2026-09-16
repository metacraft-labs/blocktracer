#!/usr/bin/env node
// ---------------------------------------------------------------------------
// DOES THE RUNNER-LABEL GATE BITE?
//
// `check-runner-labels.mjs` guards a failure mode with NO natural symptom: a
// `runs-on` that matches no runner queues forever instead of going red. A gate
// for an invisible bug is itself easy to get wrong in an invisible way — it can
// pass because it found nothing to look at, or because the thing it looked at
// was not the thing that breaks.
//
// So the arms below are mostly REFUSALS, and two of them are the ones that
// matter most:
//
//   * THE REGRESSION ARM. The real `.github/workflows/ci.yml` from this
//     repository is mutated back to its pre-migration state — every
//     `[self-hosted, linux, x64]` returned to `eph-linux-x64` — and the gate
//     must REFUSE it. That is not a synthetic fixture; it is the exact file
//     that cost a week of deploys, and the gate is shown to reject it and to
//     accept the file as it now stands.
//
//   * THE VACUITY ARM. `checkOnline` over an EMPTY runner list must ABORT, not
//     pass. This repository has been bitten before by a check that reported
//     success over an empty set, and an online runner audit is an especially
//     easy place to do it again: an unauthorised token, a renamed org or a
//     transient 200-with-no-results all produce "nothing to complain about".
//
// Offline, node-only, no network. Run by `ci.yml`'s `deploy-gates` job.
// ---------------------------------------------------------------------------

import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  REPO_ROOT, TAXONOMY_VERSION, RETIRED, NON_ROUTING, GITHUB_HOSTED,
  VOCABULARY, FLEET_CLASSES,
  extractRunsOn, checkSites, checkLabelSet, resolveInputDefault,
  checkOnline, onlineSupersets, fold,
} from "./check-runner-labels.mjs";

let passed = 0;
let pinned = 0;
const arms = [];
const failures = [];

function arm(name, fn) {
  arms.push(name);
  let ok = false;
  let detail = "";
  try {
    const r = fn();
    ok = r === true || r === undefined;
    if (r && r !== true) detail = String(r);
  } catch (e) {
    detail = e.message;
  }
  if (ok) {
    passed++;
    console.log(`  ok    ${name}`);
  } else {
    failures.push(name);
    console.log(`  FAIL  ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

function pin(cond, what) {
  pinned++;
  if (cond) {
    console.log(`  pin   ${what}`);
  } else {
    failures.push(`pin: ${what}`);
    console.log(`  PIN FAILED  ${what}`);
  }
}

// A tiny workflow around one `runs-on`, so each arm is a single mutation.
const wf = (runsOn, extra = "") => `name: t
on: [push]
jobs:
  j:
    runs-on: ${runsOn}
    steps:
      - run: true
${extra}`;

function refuses(runsOn, extra = "", files = new Map()) {
  const text = wf(runsOn, extra);
  const sites = extractRunsOn(text, "t.yml");
  const m = new Map(files);
  m.set("t.yml", text);
  return checkSites(sites, m);
}

console.log("check-runner-labels-selftest");
console.log("");
console.log("-- the shape that actually broke --------------------------------");

arm("the retired class `eph-linux-x64` is REFUSED", () => {
  const f = refuses("eph-linux-x64");
  if (f.length !== 1) return `expected 1 finding, got ${f.length}`;
  if (!/RETIRED/.test(f[0].problems[0])) return "the message does not say it is retired";
  if (!/\[self-hosted, linux, x64\]/.test(f[0].problems[0])) return "the message does not carry the replacement";
  return true;
});

arm("its replacement `[self-hosted, linux, x64]` is ACCEPTED", () =>
  refuses("[self-hosted, linux, x64]").length === 0);

arm("every other retired `eph-*` class is REFUSED too", () => {
  for (const name of RETIRED.keys()) {
    if (refuses(name).length !== 1) return `${name} was not refused`;
  }
  return true;
});

console.log("");
console.log("-- the other ways a runs-on can name nothing --------------------");

arm("a typo'd label is REFUSED (not in the vocabulary)", () => {
  const f = refuses("[self-hosted, linux, x46]");
  return f.length === 1 && /vocabulary/.test(f[0].problems[0]);
});

arm("a bare non-GitHub-hosted scalar is REFUSED", () => {
  const f = refuses("some-runner-name");
  return f.length === 1 && /label ARRAY/.test(f[0].problems[0]);
});

arm("a label array WITHOUT `self-hosted` is REFUSED", () => {
  const f = refuses("[linux, x64]");
  return f.length === 1 && /must include 'self-hosted'/.test(f[0].problems[0]);
});

arm("OVER-REQUESTING is REFUSED: no host carries topology-host AND gpu", () => {
  // Both labels are real and both are served — but never by the same machine,
  // so this queues forever exactly like a typo does. This is the half a
  // vocabulary check alone would miss.
  const f = refuses("[self-hosted, linux, x64, topology-host, gpu]");
  return f.length === 1 && /no runner class in the fleet carries all/.test(f[0].problems[0]);
});

arm("a de-routed label (`nested`) is REFUSED with its reason", () => {
  const f = refuses("[self-hosted, linux, x64, nested]");
  return f.length === 1 && /not a routing label/.test(f[0].problems[0]);
});

arm("the renamed Windows label `nixos-equivalent` is REFUSED for `dev-env-ready`", () => {
  const f = refuses("nixos-equivalent");
  return f.length === 1 && /dev-env-ready/.test(f[0].problems[0]);
});

arm("`ubuntu-latest` is ACCEPTED (documented migration exception)", () =>
  refuses("ubuntu-latest").length === 0);

arm("a typo'd GitHub image `ubuntu-latests` is REFUSED", () =>
  refuses("ubuntu-latests").length === 1);

console.log("");
console.log("-- the reusable-workflow input, which is how the deploy was wired --");

arm("a bare `${{ inputs.runner }}` passthrough is REFUSED as unresolvable", () => {
  const f = refuses("${{ inputs.runner }}");
  return f.length === 1 && /cannot resolve/.test(f[0].problems[0]);
});

arm("`fromJSON(inputs.runner)` with a JSON-array default is ACCEPTED", () => {
  const extra = `
on2:
  workflow_call:
    inputs:
      runner:
        default: '["self-hosted", "linux", "x64"]'
        type: string`;
  return refuses("${{ fromJSON(inputs.runner) }}", extra).length === 0;
});

arm("`fromJSON(inputs.runner)` whose default is the old bare string is REFUSED", () => {
  const extra = `
on2:
  workflow_call:
    inputs:
      runner:
        default: "eph-linux-x64"
        type: string`;
  const f = refuses("${{ fromJSON(inputs.runner) }}", extra);
  return f.length === 1 && /not parseable JSON|not a JSON array/.test(f[0].problems[0]);
});

arm("`fromJSON(inputs.runner)` whose default is a RETIRED class in array form is REFUSED", () => {
  const extra = `
on2:
  workflow_call:
    inputs:
      runner:
        default: '["eph-linux-x64"]'
        type: string`;
  return refuses("${{ fromJSON(inputs.runner) }}", extra).length === 1;
});

console.log("");
console.log("-- parsing: a site this gate cannot see is a site it cannot guard --");

arm("a block-sequence runs-on is parsed as an array", () => {
  const text = `jobs:
  j:
    runs-on:
      - self-hosted
      - linux
      - x64
    steps: []`;
  const sites = extractRunsOn(text, "t.yml");
  return sites.length === 1 && sites[0].kind === "array" && sites[0].labels.length === 3;
});

arm("a `runs-on:` inside a COMMENT is not mistaken for a site", () => {
  const text = `jobs:
  # runs-on: eph-linux-x64   <- prose, not configuration
  j:
    runs-on: ubuntu-latest
    steps: []`;
  const sites = extractRunsOn(text, "t.yml");
  return sites.length === 1 && sites[0].raw === "ubuntu-latest";
});

arm("a trailing comment does not become part of the label", () => {
  const sites = extractRunsOn("    runs-on: ubuntu-latest # why\n", "t.yml");
  return sites.length === 1 && sites[0].labels[0] === "ubuntu-latest";
});

console.log("");
console.log("-- case folding, because GitHub normalises what runners report ----");

arm("lowercase request matches a capitalised advertisement", () => {
  const runners = [{ status: "online", name: "gpu-server-001-mcl-001",
    labels: [{ name: "self-hosted" }, { name: "Linux" }, { name: "X64" }, { name: "nixos" }] }];
  return onlineSupersets(["self-hosted", "linux", "x64"], runners).length === 1;
});

arm("capitalised request matches a lowercase advertisement", () => {
  const runners = [{ status: "online", name: "r",
    labels: [{ name: "self-hosted" }, { name: "linux" }, { name: "x64" }] }];
  return onlineSupersets(["Self-Hosted", "LINUX", "X64"], runners).length === 1;
});

arm("a NON-subset does not match", () => {
  const runners = [{ status: "online", name: "r",
    labels: [{ name: "self-hosted" }, { name: "Linux" }, { name: "X64" }] }];
  return onlineSupersets(["self-hosted", "linux", "x64", "gpu"], runners).length === 0;
});

console.log("");
console.log("-- THE VACUITY ARM: an empty measurement must ABORT, never pass ---");

arm("checkOnline over an EMPTY runner list ABORTS", () => {
  const r = checkOnline([], new Map(), []);
  return r.abort === true && /EMPTY/.test(r.reason);
});

arm("checkOnline over runners that are all OFFLINE ABORTS", () => {
  const r = checkOnline([], new Map(), [
    { status: "offline", name: "a", labels: [{ name: "self-hosted" }] },
    { status: "offline", name: "b", labels: [{ name: "self-hosted" }] },
  ]);
  return r.abort === true && /offline or label-less/.test(r.reason);
});

arm("checkOnline ignores online runners that advertise NO labels", () => {
  // The busy `garm-*` registrations report `labels: []` mid-spawn. Counting
  // them as online evidence would let an empty-set pass wear a non-zero count.
  const r = checkOnline([], new Map(), [
    { status: "online", name: "garm-x", labels: [] },
  ]);
  return r.abort === true;
});

arm("checkOnline with real runners does NOT abort and reports matches", () => {
  const text = wf("[self-hosted, linux, x64]");
  const sites = extractRunsOn(text, "t.yml");
  const runners = [{ status: "online", name: "gpu-server-001-mcl-001",
    labels: [{ name: "self-hosted" }, { name: "Linux" }, { name: "X64" }] }];
  const r = checkOnline(sites, new Map([["t.yml", text]]), runners);
  return r.abort === false && r.results.length === 1 && r.results[0].matches.length === 1;
});

console.log("");
console.log("-- THE REGRESSION ARM: the real file, before and after ------------");

const ciPath = join(REPO_ROOT, ".github", "workflows", "ci.yml");
const ciNow = readFileSync(ciPath, "utf8");
const deployPath = join(REPO_ROOT, ".github", "workflows", "deploy-cloudflare-pages.yml");
const deployNow = readFileSync(deployPath, "utf8");

arm("the repository's ci.yml AS IT STANDS is accepted", () => {
  const sites = extractRunsOn(ciNow, "ci.yml");
  const f = checkSites(sites, new Map([["ci.yml", ciNow]]));
  return f.length === 0 || `refused: ${JSON.stringify(f)}`;
});

arm("the repository's ci.yml MUTATED BACK to `eph-linux-x64` is REFUSED", () => {
  // The exact pre-migration shape, reconstructed from the live file rather
  // than hand-written, so this arm cannot drift away from what shipped.
  const pre = ciNow.replace(/runs-on: \[self-hosted, linux, x64\]/g, "runs-on: eph-linux-x64");
  if (pre === ciNow) return "the mutation changed nothing — the fixture is not exercising the real sites";
  const sites = extractRunsOn(pre, "ci.yml");
  const f = checkSites(sites, new Map([["ci.yml", pre]]));
  if (f.length !== 7) return `expected all 7 migrated sites refused, got ${f.length}`;
  return f.every((x) => /RETIRED/.test(x.problems[0])) || "not every refusal cites the retirement";
});

arm("the deploy workflow's input default AS IT STANDS resolves to a servable set", () => {
  const r = resolveInputDefault(deployNow, "runner");
  if (!r.ok) return r.reason;
  return checkLabelSet(r.labels).length === 0 || `refused: ${checkLabelSet(r.labels)}`;
});

arm("the deploy workflow MUTATED BACK to the bare-string default is REFUSED", () => {
  const pre = deployNow.replace(/default: '\["self-hosted", "linux", "x64"\]'/, 'default: "eph-linux-x64"');
  if (pre === deployNow) return "the mutation changed nothing";
  const sites = extractRunsOn(pre, "d.yml");
  const f = checkSites(sites, new Map([["d.yml", pre]]));
  return f.length === 1;
});

console.log("");
console.log("-- pinned facts ---------------------------------------------------");

pin(TAXONOMY_VERSION === 1, "the mirrored taxonomy is version 1 (bump with the guidelines)");
pin(RETIRED.has("eph-linux-x64"), "`eph-linux-x64` is on the retired list");
pin(!VOCABULARY.has("eph-linux-x64"), "`eph-linux-x64` is NOT in the vocabulary");
pin(VOCABULARY.has("nixos") && VOCABULARY.has("gpu") && VOCABULARY.has("rr-hw-counters"),
    "the persistent-host labels this repo uses are in the vocabulary");
pin(NON_ROUTING.has("nested") && NON_ROUTING.has("docker"),
    "container/nested-VM labels are recorded as non-routing");
pin(GITHUB_HOSTED.has("ubuntu-latest"),
    "`ubuntu-latest` is allowed by exact name — the gates and the watchdog depend on it");
pin(FLEET_CLASSES.some((c) => c.labels.map(fold).includes("topology-host")) &&
    FLEET_CLASSES.some((c) => c.labels.map(fold).includes("gpu")) &&
    !FLEET_CLASSES.some((c) => {
      const s = new Set(c.labels.map(fold));
      return s.has("topology-host") && s.has("gpu");
    }),
    "topology-host and gpu each exist, and no one class has both — the over-request arm is real");
{
  // 12 = the 7 migrated self-hosted jobs + 4 `ubuntu-latest` gate jobs +
  // `chain-follower-linux`. Counted from the file, not remembered. If this
  // number moves, a job was added or removed — reconcile it to the file,
  // never the other way round.
  const sites = extractRunsOn(ciNow, "ci.yml");
  const selfHosted = sites.filter((s) => s.kind === "array").length;
  const hosted = sites.filter((s) => s.kind === "scalar" && GITHUB_HOSTED.has(fold(s.labels[0]))).length;
  pin(sites.length === 12 && selfHosted === 8 && hosted === 4,
      `ci.yml has ${sites.length} runs-on sites (${selfHosted} self-hosted, ${hosted} GitHub-hosted) and every one is parsed`);
}

console.log("");
console.log(`arms: ${passed}/${arms.length} passed, plus ${pinned} pinned assertions`);
if (failures.length) {
  console.log(`check-runner-labels-selftest: FAIL — ${failures.length}: ${failures.join("; ")}`);
  process.exit(1);
}
console.log(
  "check-runner-labels-selftest: PASS — the gate was shown to refuse the exact pre-migration " +
  "ci.yml and deploy input that queued for a week, to refuse over-requesting as well as typos, " +
  "and to ABORT rather than report success over an empty runner list.",
);
