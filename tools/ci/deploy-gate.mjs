#!/usr/bin/env node
// The CI verdict gate that stands in front of a PUBLISHING deploy.
//
//   node tools/ci/deploy-gate.mjs              # poll until a verdict, then exit
//   node tools/ci/deploy-gate.mjs --once       # evaluate the world once, do not wait
//   node tools/ci/deploy-gate.mjs --json       # ... and print the decision as JSON
//
// It collects facts and performs an action. Every JUDGEMENT is in
// `tools/ci/deploy-gate-decide.mjs`, which is pure and offline, and that
// module's header carries the measurements the policy is built on. Read it
// first — in particular for why the required set is two jobs and not nine.
//
// ── The world it reads ─────────────────────────────────────────────────────
//
//   GITHUB_REPOSITORY            owner/repo
//   GH_TOKEN / GITHUB_TOKEN      needs `actions: read`
//   GATE_EVENT                   the DEPLOY run's event ("push" / "pull_request")
//   GATE_BRANCH                  the DEPLOY run's ref_name
//   GATE_SHA                     the commit being deployed
//
//   DEPLOY_GATE_MODE             "enforce" | "advisory" | "off"   (default advisory)
//   DEPLOY_GATE_REQUIRED_JOBS    comma/space list; unset = the default set
//   DEPLOY_GATE_DEADLINE_SECONDS default 1200
//   DEPLOY_GATE_POLL_SECONDS     default 15
//
// ── Why it queries by head_sha and not by "the latest ci run" ──────────────
//
// The whole claim of this gate is "ci passed FOR THIS COMMIT". `dev` takes
// direct pushes from several agents at once — five inside twelve minutes, on
// this repository's own measurement — so "the latest ci run on the branch" is
// routinely a DIFFERENT commit's verdict by the time a deploy asks. Asking
// `?head_sha=` makes the commit the key, and a deploy of a commit that has no
// `ci` run cannot be answered by another commit's green tick.
//
// ── Exit codes ─────────────────────────────────────────────────────────────
//
//   0  publish  — the deploy job may run
//   1  refuse   — enforce mode, ci did not pass for this commit
//   2  the gate itself could not run (no token, no repo, API unreadable)
//
// 2 is separate from 1 on purpose. "The gate says no" and "the gate is
// broken" are different facts, and a workflow that collapses them teaches its
// readers to ignore both. In ADVISORY mode a refusal exits 0 and says loudly
// what it would have done, so that landing this file changes nothing about
// what publishes until an operator sets DEPLOY_GATE_MODE=enforce.

import { appendFileSync } from "node:fs";
import { decideDeployGate, parseMode, parseRequiredJobs } from "./deploy-gate-decide.mjs";

const API = process.env.GITHUB_API_URL || "https://api.github.com";
const CI_WORKFLOW_PATH = ".github/workflows/ci.yml";

const argv = process.argv.slice(2);
const ONCE = argv.includes("--once");
const AS_JSON = argv.includes("--json");

const EXIT_PUBLISH = 0;
const EXIT_REFUSE = 1;
const EXIT_BROKEN = 2;

function fail(msg) {
  console.error(`::error title=Deploy gate could not run::${msg}`);
  process.exit(EXIT_BROKEN);
}

const repo = process.env.GITHUB_REPOSITORY || "";
const token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN || "";
if (!repo.includes("/")) fail("GITHUB_REPOSITORY is not set to owner/repo");
if (!token) fail("no GH_TOKEN / GITHUB_TOKEN — cannot read the ci verdict");

const sha = (process.env.GATE_SHA || "").trim();
if (!/^[0-9a-f]{40}$/i.test(sha)) fail(`GATE_SHA is not a 40-char sha: '${sha}'`);

const mode = parseMode(process.env.DEPLOY_GATE_MODE);
const requiredJobs = parseRequiredJobs(process.env.DEPLOY_GATE_REQUIRED_JOBS);
const deadlineSeconds = intEnv("DEPLOY_GATE_DEADLINE_SECONDS", 1200);
const pollSeconds = Math.max(5, intEnv("DEPLOY_GATE_POLL_SECONDS", 15));

function intEnv(name, dflt) {
  const n = Number.parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(n) && n > 0 ? n : dflt;
}

async function api(path) {
  const res = await fetch(`${API}${path}`, {
    headers: {
      accept: "application/vnd.github+json",
      authorization: `Bearer ${token}`,
      "x-github-api-version": "2022-11-28",
      "user-agent": "blocktracer-deploy-gate",
    },
  });
  if (!res.ok) {
    // A READ FAILURE IS NOT A VERDICT. Anything other than a clean answer
    // exits 2, never 0: a gate that treats "I could not ask" as "it passed"
    // is the gate that passes by not running.
    fail(`GET ${path} -> ${res.status} ${res.statusText}`);
  }
  return res.json();
}

/** Every job of every `ci` run for this commit, unioned. */
async function collect() {
  const runs = await api(
    `/repos/${repo}/actions/runs?head_sha=${sha}&per_page=100`,
  );
  // SAME WORKFLOW, SAME BRANCH. The branch filter is not cosmetic: one commit
  // pushed to dev, staging and live produces three `ci` runs over one tree,
  // and they do not always agree — see the note beside the roll-up in
  // deploy-gate-decide.mjs, which is a real observation on c77a1b0f. The
  // decider filters again on `runBranch` so this cannot be undone here alone.
  const wantBranch = (process.env.GATE_BRANCH || "").trim();
  const ciRuns = (runs.workflow_runs || []).filter(
    (r) => r.path === CI_WORKFLOW_PATH && (!wantBranch || r.head_branch === wantBranch),
  );
  const jobs = [];
  for (const run of ciRuns) {
    let page = 1;
    for (;;) {
      const j = await api(`/repos/${repo}/actions/runs/${run.id}/jobs?per_page=100&page=${page}`);
      for (const row of j.jobs || []) {
        jobs.push({
          name: row.name,
          status: row.status,
          conclusion: row.conclusion,
          runId: run.id,
          runBranch: run.head_branch,
          runnerId: row.runner_id,
        });
      }
      if (!j.jobs || j.jobs.length < 100) break;
      page += 1;
    }
  }
  return { ciRuns, jobs };
}

const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

const startedAt = Date.now();
let decision;
let world;

for (;;) {
  const { ciRuns, jobs } = await collect();
  const waitedSeconds = Math.round((Date.now() - startedAt) / 1000);
  world = {
    mode,
    event: process.env.GATE_EVENT || "",
    branch: process.env.GATE_BRANCH || "",
    headSha: sha,
    requiredJobs,
    jobs,
    ciRunsFound: ciRuns.length,
    waitedSeconds: ONCE ? deadlineSeconds : waitedSeconds,
    deadlineSeconds,
  };
  decision = decideDeployGate(world);

  console.log(
    `[${world.waitedSeconds}s] ${decision.verdict} (${decision.code}): ${decision.reason}`,
  );

  if (decision.action !== "wait") break;
  if (ONCE) break;
  await sleep(pollSeconds);
}

// ── Report ─────────────────────────────────────────────────────────────────

const summary = Object.entries(decision.jobStates || {})
  .map(([k, v]) => `${k}=${v}`)
  .join(", ");

if (AS_JSON) {
  console.log(
    JSON.stringify(
      {
        ...decision,
        mode,
        requiredJobs,
        headSha: sha,
        branch: world.branch,
        event: world.event,
        ciRunsFound: world.ciRunsFound,
      },
      null,
      2,
    ),
  );
}

if (process.env.GITHUB_OUTPUT) {
  appendFileSync(
    process.env.GITHUB_OUTPUT,
    [
      `action=${decision.action}`,
      `verdict=${decision.verdict}`,
      `code=${decision.code}`,
      `publish=${decision.action === "publish"}`,
      `reason=${decision.reason.replace(/[\r\n]+/g, " ")}`,
      `jobs=${summary}`,
      "",
    ].join("\n"),
  );
}

if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    `### Deploy gate — ${decision.verdict.toUpperCase()} (${decision.code}, mode \`${mode}\`)\n\n` +
      `- commit: \`${sha}\`\n- branch: \`${world.branch}\`\n` +
      `- required: ${requiredJobs.map((j) => `\`${j}\``).join(", ")}\n` +
      `- observed: ${summary || "—"}\n- ci runs for this commit: ${world.ciRunsFound}\n\n` +
      `${decision.reason}\n`,
  );
}

if (decision.verdict === "refuse") {
  if (mode === "enforce") {
    // THE TITLE NAMES WHICH REFUSAL IT IS. G3 is the operator's own variable
    // parsing to nothing; every other code is a verdict about the commit.
    // Collapsing the two would send someone to look at ci for a defect that
    // is in a repository setting — the same lesson `ci.yml` records about
    // exit 3 versus exit 1 on gate-selftest.mjs: "a reader must not have to
    // open the log and already know a third code exists".
    const title =
      decision.code === "G3"
        ? "DEPLOY REFUSED — the gate is misconfigured, not the commit"
        : "DEPLOY REFUSED — ci did not pass for this commit";
    console.error(
      `::error title=${title}::${decision.reason}. ` +
        "Nothing was published. This is not a build failure: the deploy did not run. " +
        "Fix ci for this commit and push again, or set the DEPLOY_GATE_MODE repository " +
        "variable to 'off' to publish without a verdict.",
    );
    process.exit(EXIT_REFUSE);
  }
  console.log(
    `::warning title=Deploy gate WOULD HAVE REFUSED (advisory)::${decision.reason}. ` +
      "The deploy is proceeding because DEPLOY_GATE_MODE is not 'enforce'.",
  );
}

process.exit(EXIT_PUBLISH);
