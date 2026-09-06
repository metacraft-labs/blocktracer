#!/usr/bin/env node
// Does the deploy gate REFUSE? — the proof-of-bite for `deploy-gate-decide.mjs`.
//
//   node tools/ci/deploy-gate-decide-selftest.mjs
//
// A gate that has only ever been seen to pass has not been demonstrated. This
// repository has already shipped a gate whose own selftest was dead code
// (`check-assets-selftest.mjs`, 322 lines, referenced by nothing), and the
// gate this file tests is one that can stop ALL publishing when it is wrong.
// So every arm below is a world in which the answer is fixed in advance, and
// the majority of them are refusals.
//
// Three of the arms are not about the decision function at all. §D reads
// `.github/workflows/ci.yml` and `.github/workflows/deploy.yml` and asserts
// that the gate is actually WIRED IN FRONT OF the deploy and that every job
// it requires exists. Those are the two ways this gate rots into a formality:
//
//   * a required job is renamed in ci.yml, and the gate then refuses every
//     deploy forever (G6) — or, in a naive "no required job failed"
//     implementation, passes every deploy forever;
//   * the `needs:` is dropped from deploy.yml and the gate keeps reporting
//     verdicts beside a deploy that no longer consults it.
//
// Neither is visible from inside the decision function, and both read as
// perfectly healthy in the checks UI.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import {
  decideDeployGate,
  parseMode,
  parseRequiredJobs,
  DEFAULT_REQUIRED_JOBS,
  PUBLISH_BRANCHES,
} from "./deploy-gate-decide.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

let ran = 0;
let failed = 0;

function check(label, cond, detail = "") {
  ran += 1;
  if (cond) {
    console.log(`  ok   ${label}`);
  } else {
    failed += 1;
    console.log(`  FAIL ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

/** A world with everything green, which each arm then breaks in ONE way. */
function world(over = {}) {
  return {
    mode: "enforce",
    event: "push",
    branch: "live",
    headSha: "0123456789abcdef0123456789abcdef01234567",
    requiredJobs: ["ci-coverage", "deploy-gates"],
    jobs: [
      { name: "ci-coverage", status: "completed", conclusion: "success", runId: 1 },
      { name: "deploy-gates", status: "completed", conclusion: "success", runId: 1 },
      { name: "journeys", status: "completed", conclusion: "failure", runId: 1 },
    ],
    ciRunsFound: 1,
    waitedSeconds: 0,
    deadlineSeconds: 1200,
    ...over,
  };
}

// ── §A The control, and the refusals ───────────────────────────────────────

console.log("\n§A  the decision");

{
  const d = decideDeployGate(world());
  check("A1  all required jobs green -> publish", d.verdict === "publish" && d.code === "G8", JSON.stringify(d));
}

{
  // THE CONTROL THAT MAKES THE SUBSET HONEST. `journeys` is red in every world
  // above, deliberately. If someone widens the required set to the whole of
  // `ci`, A1 goes red here rather than silently stopping every deploy in
  // production — which is the measured outcome of requiring the eph-pool jobs
  // (0 successful `ci` runs in the last 12 on `dev`).
  const d = decideDeployGate(world());
  check(
    "A2  a job OUTSIDE the required set being red does not block",
    d.verdict === "publish",
    JSON.stringify(d),
  );
}

for (const bad of ["failure", "cancelled", "timed_out", "action_required", "stale", "neutral", "skipped"]) {
  const d = decideDeployGate(
    world({
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: bad, runId: 1 },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 1 },
      ],
    }),
  );
  check(
    `A3  a required job concluding '${bad}' -> refuse`,
    d.verdict === "refuse" && d.code === "G5" && d.reason.includes("ci-coverage"),
    JSON.stringify(d),
  );
}

{
  // NOT "anything not in a known-bad list". The question is "did it pass",
  // and an outcome GitHub has not invented yet is not a pass.
  const d = decideDeployGate(
    world({
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: "some_future_conclusion", runId: 1 },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 1 },
      ],
    }),
  );
  check("A4  an unrecognised conclusion -> refuse, not publish", d.verdict === "refuse", JSON.stringify(d));
}

{
  const d = decideDeployGate(
    world({
      jobs: [{ name: "ci-coverage", status: "completed", conclusion: "success", runId: 1 }],
      waitedSeconds: 1200,
    }),
  );
  check(
    "A5  a required job ABSENT from every ci run -> refuse (G6), not pass",
    d.verdict === "refuse" && d.code === "G6" && d.reason.includes("deploy-gates"),
    JSON.stringify(d),
  );
}

{
  const d = decideDeployGate(world({ ciRunsFound: 0, jobs: [], waitedSeconds: 1200 }));
  check(
    "A6  NO ci run at all for the commit -> refuse (G4)",
    d.verdict === "refuse" && d.code === "G4",
    JSON.stringify(d),
  );
}

{
  const d = decideDeployGate(
    world({
      jobs: [
        { name: "ci-coverage", status: "in_progress", conclusion: null, runId: 1 },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 1 },
      ],
      waitedSeconds: 1200,
    }),
  );
  check(
    "A7  a required job still running at the deadline -> refuse (G7)",
    d.verdict === "refuse" && d.code === "G7",
    JSON.stringify(d),
  );
}

{
  // A GATE THAT REQUIRES NOTHING IS NOT A GATE. Reachable by a typo in the
  // repository variable.
  const d = decideDeployGate(world({ requiredJobs: [] }));
  check(
    "A8  an EMPTY required set -> refuse (G3), not a vacuous pass",
    d.verdict === "refuse" && d.code === "G3",
    JSON.stringify(d),
  );
}

{
  const d = decideDeployGate(world({ requiredJobs: ["", "   "] }));
  check("A9  a required set of blanks -> refuse (G3)", d.verdict === "refuse" && d.code === "G3");
}

// ── §B The waits, and the two things that must NOT be gated ────────────────

console.log("\n§B  waiting, and what is out of scope");

{
  const d = decideDeployGate(
    world({
      jobs: [
        { name: "ci-coverage", status: "queued", conclusion: null, runId: 1 },
        { name: "deploy-gates", status: "queued", conclusion: null, runId: 1 },
      ],
      waitedSeconds: 30,
    }),
  );
  check("B1  required jobs queued, inside the deadline -> wait", d.verdict === "wait" && d.code === "G7w");
}

{
  const d = decideDeployGate(world({ ciRunsFound: 0, jobs: [], waitedSeconds: 30 }));
  check("B2  ci run not created yet, inside the deadline -> wait", d.verdict === "wait" && d.code === "G4w");
}

{
  // A KNOWN FAILURE IS NOT WAITED OUT. There is nothing left to learn.
  const d = decideDeployGate(
    world({
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: "failure", runId: 1 },
        { name: "deploy-gates", status: "queued", conclusion: null, runId: 1 },
      ],
      waitedSeconds: 0,
    }),
  );
  check("B3  a failure short-circuits the wait -> refuse immediately", d.verdict === "refuse" && d.code === "G5");
}

{
  // PR PREVIEWS MUST KEEP WORKING. `deploy.yml` sends every PR to the
  // blocktracer-dev project as a native preview; nothing a preview does is
  // visible to a visitor. This arm gives the gate a WORLD IN WHICH CI FAILED
  // and requires it to publish anyway, so a future tightening cannot take
  // previews away by accident.
  const d = decideDeployGate(
    world({
      event: "pull_request",
      branch: "some-feature",
      jobs: [{ name: "ci-coverage", status: "completed", conclusion: "failure", runId: 1 }],
    }),
  );
  check("B4  a pull_request preview is never gated -> publish (G1)", d.verdict === "publish" && d.code === "G1");
}

{
  const d = decideDeployGate(
    world({
      branch: "not-a-publishing-branch",
      jobs: [{ name: "ci-coverage", status: "completed", conclusion: "failure", runId: 1 }],
    }),
  );
  check("B5  a push to a non-publishing branch -> publish (G2)", d.verdict === "publish" && d.code === "G2");
}

for (const b of PUBLISH_BRANCHES) {
  const d = decideDeployGate(
    world({
      branch: b,
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: "failure", runId: 1 },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 1 },
      ],
    }),
  );
  check(`B6  a push to '${b}' IS gated -> refuse`, d.verdict === "refuse" && d.code === "G5");
}

// ── §C The union across runs, and the modes ────────────────────────────────

console.log("\n§C  several ci runs for one commit, and the modes");

{
  // `ci.yml` maintains a `workflow_dispatch` lane precisely so a verdict can
  // be produced that no push is able to evict. A green dispatch run IS the
  // commit's verdict, and a push run cancelled at second three must not
  // outvote it. Both runs are on the SAME branch.
  const d = decideDeployGate(
    world({
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: "cancelled", runId: 1, runBranch: "live" },
        { name: "deploy-gates", status: "completed", conclusion: "cancelled", runId: 1, runBranch: "live" },
        { name: "ci-coverage", status: "completed", conclusion: "success", runId: 2, runBranch: "live" },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 2, runBranch: "live" },
      ],
      ciRunsFound: 2,
    }),
  );
  check("C1  cancelled in the push run, green in the same-branch dispatch run -> publish", d.verdict === "publish", JSON.stringify(d));
}

{
  // C1b — THE ARM THAT COST A DRAFT. The first version of this gate unioned
  // every `ci` run for the sha regardless of branch. Real data, c77a1b0f
  // pushed to dev/staging/live inside 90 seconds: `ci-coverage` was `failure`
  // on the staging run and `success` on the dev and live runs over one
  // identical tree. The cross-branch union reported PUBLISH for the staging
  // deploy of a commit whose staging ci had just gone red. The verdict that
  // gates a publish to a branch is the verdict produced ON that branch.
  const d = decideDeployGate(
    world({
      branch: "staging",
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: "failure", runId: 33921246632, runBranch: "staging" },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 33921246632, runBranch: "staging" },
        { name: "ci-coverage", status: "completed", conclusion: "success", runId: 33921132640, runBranch: "dev" },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 33921132640, runBranch: "dev" },
        { name: "ci-coverage", status: "completed", conclusion: "success", runId: 33921253095, runBranch: "live" },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 33921253095, runBranch: "live" },
      ],
      ciRunsFound: 1,
    }),
  );
  check(
    "C1b another branch's green over the same tree does NOT rescue this branch's red",
    d.verdict === "refuse" && d.code === "G5" && d.reason.includes("ci-coverage=failure"),
    JSON.stringify(d),
  );
}

{
  // The mirror of C1b: a green on THIS branch is not spoiled by a red on
  // another. Otherwise the fix for C1b would have traded one wrong answer for
  // the opposite wrong answer.
  const d = decideDeployGate(
    world({
      branch: "dev",
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: "success", runId: 1, runBranch: "dev" },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 1, runBranch: "dev" },
        { name: "ci-coverage", status: "completed", conclusion: "failure", runId: 2, runBranch: "staging" },
      ],
      ciRunsFound: 1,
    }),
  );
  check("C1c another branch's red does not block this branch's green", d.verdict === "publish", JSON.stringify(d));
}

{
  const d = decideDeployGate(
    world({
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: "failure", runId: 1 },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 1 },
        { name: "ci-coverage", status: "in_progress", conclusion: null, runId: 2 },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 2 },
      ],
      ciRunsFound: 2,
      waitedSeconds: 0,
    }),
  );
  check(
    "C2  failed in one run and unfinished in the other -> refuse (no run says it passed)",
    d.verdict === "refuse" && d.code === "G5",
    JSON.stringify(d),
  );
}

{
  const d = decideDeployGate(
    world({
      mode: "advisory",
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: "failure", runId: 1 },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 1 },
      ],
    }),
  );
  check(
    "C3  advisory: the verdict is still REFUSE but the action is publish",
    d.verdict === "refuse" && d.action === "publish" && d.wouldRefuse === true,
    JSON.stringify(d),
  );
}

{
  const d = decideDeployGate(
    world({
      mode: "enforce",
      jobs: [
        { name: "ci-coverage", status: "completed", conclusion: "failure", runId: 1 },
        { name: "deploy-gates", status: "completed", conclusion: "success", runId: 1 },
      ],
    }),
  );
  check("C4  enforce: the action is refuse", d.action === "refuse" && d.wouldRefuse === true);
}

{
  const d = decideDeployGate(
    world({
      mode: "off",
      ciRunsFound: 0,
      jobs: [],
      waitedSeconds: 1200,
    }),
  );
  check("C5  off: publishes without even waiting (G0)", d.action === "publish" && d.code === "G0");
}

check("C6  an unset mode is advisory, not enforce", parseMode(undefined) === "advisory");
check("C7  a MISSPELLED mode is advisory, not enforce", parseMode("enfroce") === "advisory");
check("C8  'enforce' is enforce", parseMode(" Enforce ") === "enforce");
check(
  "C9  an unset required list is the default set (an absent repo variable is empty string)",
  JSON.stringify(parseRequiredJobs("")) === JSON.stringify([...DEFAULT_REQUIRED_JOBS]) &&
    JSON.stringify(parseRequiredJobs(undefined)) === JSON.stringify([...DEFAULT_REQUIRED_JOBS]),
);
check(
  "C10 a written list that parses to nothing stays empty, so G3 can refuse it",
  parseRequiredJobs(",  ,").length === 0,
);
check(
  "C11 a written list is parsed on commas and whitespace",
  JSON.stringify(parseRequiredJobs("ci-coverage, deploy-gates  contract")) ===
    JSON.stringify(["ci-coverage", "deploy-gates", "contract"]),
);

// ── §D The gate is wired in, and it requires jobs that exist ───────────────

console.log("\n§D  the workflows themselves");

const ciYml = readFileSync(resolve(repoRoot, ".github/workflows/ci.yml"), "utf8");
const deployYml = readFileSync(resolve(repoRoot, ".github/workflows/deploy.yml"), "utf8");

// Comment lines are dropped BEFORE anything is counted — `ci-coverage.sh`
// states the rule and the reason: a scanner that reads its subject's own
// documentation is satisfied by anything that documentation says, and this
// file's subject is heavily commented.
const deployCode = deployYml.split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");
const ciCode = ciYml.split("\n").filter((l) => !/^\s*#/.test(l)).join("\n");

// From the `jobs:` line onwards only. Without the slice, `push:`,
// `pull_request:` and `workflow_dispatch:` in the `on:` block are also
// two-space keys and would join the job list — a required job could then be
// "found" in the trigger block. That is the wrong-universe failure this
// repository names in ci-coverage.sh, in miniature.
const jobsAt = ciCode.search(/^jobs:$/m);
const ciJobKeys =
  jobsAt < 0
    ? []
    : [...ciCode.slice(jobsAt).matchAll(/^ {2}([A-Za-z0-9_-]+):$/gm)].map((m) => m[1]);
check("D0  ci.yml's job list parsed (control — an empty list would pass D1 vacuously)", ciJobKeys.length >= 8, `parsed ${ciJobKeys.length}`);

for (const name of DEFAULT_REQUIRED_JOBS) {
  check(
    `D1  required job '${name}' is a real job in ci.yml`,
    ciJobKeys.includes(name),
    `ci.yml jobs: ${ciJobKeys.join(", ")}`,
  );
}

check(
  "D2  deploy.yml has a ci-verdict job",
  /^ {2}ci-verdict:$/m.test(deployCode),
  "the gate must exist in the workflow that publishes",
);

check(
  "D3  the publishing job DEPENDS on the gate — needs: ci-verdict",
  /needs:\s*(\[\s*)?ci-verdict/.test(deployCode),
  "without `needs:` the gate reports a verdict beside a deploy that ignores it",
);

check(
  "D4  the publishing job is CONDITIONAL on the gate's answer",
  /needs\.ci-verdict\.outputs\.publish/.test(deployCode),
  "`needs:` alone would let a skipped/advisory gate imply consent",
);

check(
  "D5  the gate job runs on a GitHub-hosted runner",
  /ci-verdict:[\s\S]{0,400}?runs-on:\s*ubuntu-latest/.test(deployCode),
  "a gate queued behind eph-linux-x64 is starved exactly when the deploy is",
);

check(
  "D6  ci.yml runs THIS selftest",
  /deploy-gate-decide-selftest\.mjs/.test(ciCode),
  "a proof-of-bite that no job runs is the defect this repository keeps finding",
);

check(
  "D7  deploy.yml still deploys on push to every publishing branch",
  PUBLISH_BRANCHES.every((b) => new RegExp(`branches:.*${b}`).test(deployCode)),
);

check(
  "D8  deploy.yml still triggers on pull_request (previews are preserved)",
  /^\s*pull_request:\s*$/m.test(deployCode),
);

// ── verdict ────────────────────────────────────────────────────────────────

console.log(`\n${ran} assertion(s), ${failed} failed`);
if (ran < 40) {
  console.error(
    `::error::only ${ran} assertions ran — this suite is meant to be ~50; a short tally is a finding`,
  );
  process.exit(1);
}
process.exit(failed === 0 ? 0 : 1);
