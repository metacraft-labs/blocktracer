#!/usr/bin/env node
// Decide whether a PUBLISHING deploy may proceed for a given commit.
//
// This module is a pure function. It performs no I/O, talks to no API and
// knows nothing about GitHub beyond the shape of the facts it is handed;
// `tools/ci/deploy-gate.mjs` collects those facts and
// `.github/workflows/deploy.yml` acts on the answer. Everything that could be
// wrong about the POLICY is therefore testable offline, which is what
// `tools/ci/deploy-gate-selftest.mjs` does.
//
// ── What was true before this existed ──────────────────────────────────────
//
// `deploy.yml` triggered on `push: [live, staging, dev]` and `pull_request`
// and contained no `workflow_run`, no `needs:`, no `check_run` and no
// `conclusion`. It is, by its own header, "the ONLY thing that publishes any
// BlockTracer host, blocktracer.org included". So a push to `live` published
// whether `ci` had passed, failed, or not yet started. The only thing standing
// between a red commit and blocktracer.org was that a person happened to be
// the one pushing. That stops being true the moment an automated ingestion
// process is producing commits, which is why this was written now.
//
// ── WHICH JOBS BLOCK PUBLISHING, AND WHY IT IS NOT ALL OF THEM ─────────────
//
// Measured on 2026-09-06 over the last 12 `push` runs of `ci` on `dev`
// (run ids 33979638206 … 34018128849), per JOB and not per run:
//
//     ci-coverage      12 / 12 success
//     deploy-gates     12 / 12 success
//     visual-design    12 / 12 success
//     ---------------------------------------------------------------
//     contract          4 success,  8 cancelled
//     client-sdk        4 success,  8 cancelled
//     viewmodels        4 success,  8 cancelled
//     debug-route       2 success,  1 failure, 9 cancelled
//     visual-design-canary  2 success, 3 failure, 7 cancelled
//     journeys          0 success,  4 failure, 8 cancelled
//     journeys-combine  0 success, 12 failure
//
// The RUN conclusion over those same 12 was 0 success / 5 failure /
// 7 cancelled. A gate that demanded `ci` be green would therefore have
// refused every single deploy from the moment it was switched on — including
// every deploy to `live`. That is not a gate, it is an outage with a
// justification attached, and it would be switched off within a day; the
// staleness it was written to prevent would then ship with it nominally in
// place. (`ci.yml` makes this exact argument twice about its own gates: "a
// gate that reddens on a normal deploy is a gate that gets switched off".)
//
// ── AND WHY `visual-design` IS NOT IN THE SET, THOUGH TWELVE RUNS SAID YES ──
//
// Twelve runs is not enough history to set a floor on. Widened to the last
// 102 `ci` runs across all branches (2026-09-04T03:42Z … 2026-09-06T17:19Z),
// per job:
//
//     ci-coverage     101 success,  1 failure
//     deploy-gates    101 success,  1 cancelled
//     visual-design    74 success, 28 failure
//
// `visual-design`'s 28 reds are not scattered. They are TWO CONTIGUOUS
// STREAKS on 2026-09-04 — 8 runs from 03:42:41Z to 08:11:16Z, and 20 runs
// from 09:27:21Z to 15:26:09Z — spanning `dev`, `staging` AND `live`. Had
// this gate been armed with `visual-design` required, publishing to
// blocktracer.org would have been stopped for ten and a half hours of that
// day by a token-lint regression. That is the precise failure mode this gate
// is not allowed to have, and the twelve-run window would have hidden it: by
// 2026-09-05 the job was green again and looked like a safe requirement.
//
// So the floor is `ci-coverage` + `deploy-gates`: the two jobs with a single
// non-success between them in 102 runs, and neither of those a content
// regression (one eviction, one genuine ci-coverage failure that this gate
// exists to catch). `visual-design` remains a job that must be read; it is
// simply not a job that is allowed to stop blocktracer.org from updating.
// Raising the floor is a repository variable away — see the end of this
// header.
//
// The two jobs in `DEFAULT_REQUIRED_JOBS` reach a verdict on essentially
// every run, and the reason is structural rather than lucky:
//
//   * BOTH RUN ON `ubuntu-latest`. Six of the nine jobs need `eph-linux-x64`, a
//     small ephemeral pool shared across the org, and `ci.yml`'s own header
//     records what that costs: a run is routinely evicted by the next push
//     before it has placed a single job on a runner. GitHub-hosted jobs start
//     immediately, so they reach a verdict inside the window where the
//     eph-pool jobs are still pending. Measured start-to-finish on four of
//     those runs: ci-coverage 13-15s, deploy-gates 98-111s (visual-design,
//     for reference, 25-30s). The gate therefore costs about two minutes of
//     publishing latency, not the 66-92 minutes ONE `journeys` shard costs.
//
//   * A CANCELLED RUN DOES NOT ERASE A FINISHED JOB. When a newer push evicts
//     the run, the jobs that had already completed keep their own
//     `success` conclusion; only the pending ones become `cancelled`. This
//     gate reads PER-JOB conclusions for exactly that reason. Run 34016257662
//     is the case in point: run conclusion `cancelled`, and inside it
//     ci-coverage / deploy-gates / visual-design all `success` while the six
//     eph-pool jobs are `cancelled` with `runner_id: 0` — they never started.
//
//   * WHAT THEY CHECK IS THE PUBLISH PATH. `deploy-gates` is the job that
//     proves the deploy's own asset, freshness and engine-pin gates can go
//     red — it is named for this; `ci-coverage` proves every suite runs on
//     every branch that ships, which is the check that fails when a robot
//     lands a commit that quietly removes a lane. Neither needs the Nix
//     runner, by deliberate design recorded in `ci.yml`: "a gate that needs
//     the Nix runner to prove it can fail is a gate that gets skipped when
//     the runner is busy". The same sentence is the reason they can be
//     required here.
//
// WHAT THIS SUBSET DOES NOT DO, stated plainly rather than left to be
// discovered: it would NOT have stopped 779c7029 publishing to `live` on
// 2026-09-05, whose `journeys` and `visual-design-canary` were both red. It
// WOULD have stopped c77a1b0f from publishing to `staging` on 2026-09-04,
// whose `ci-coverage` failed. The gate is a floor, not a ceiling, and the
// floor is set where the measurements say a gate can actually stand. The set
// is a repository variable (`DEPLOY_GATE_REQUIRED_JOBS`) precisely so that
// raising the floor — adding `contract` once the pool stops evicting it — is
// an operator decision and not a code change.

/** Branches whose deploy PUBLISHES. Must match `deploy.yml`'s push trigger. */
export const PUBLISH_BRANCHES = Object.freeze(["live", "staging", "dev"]);

/**
 * See the header for the 102-run measurement this list comes from, and for
 * why `visual-design` — 12/12 green on the recent window, 74/102 over the
 * wider one, with a ten-and-a-half-hour red streak across all three
 * publishing branches — is deliberately NOT in it.
 *
 * `deploy-gate-selftest.mjs` asserts that every name here is a real job key
 * in `.github/workflows/ci.yml`. A required job that does not exist would
 * make this gate refuse every deploy forever, and a rename is the ordinary
 * way that happens.
 */
export const DEFAULT_REQUIRED_JOBS = Object.freeze(["ci-coverage", "deploy-gates"]);

/**
 * Conclusions that are a verdict of "this job did not pass". Deliberately a
 * closed DENY list is NOT used here — anything that is not `success` is a
 * refusal, because the question this gate asks is "did it pass", and an
 * outcome nobody anticipated is not a pass. That is the opposite of
 * `requeue-decide.mjs`'s closed allowlist, and for the opposite reason: there,
 * an unknown outcome must not cause an ACTION; here, an unknown outcome must
 * not cause a PUBLISH.
 */
const PASS = "success";

/**
 * @typedef {{name: string, status?: string, conclusion?: string|null, runId?: number|string}} JobRow
 *
 * @param {object} w
 * @param {"enforce"|"advisory"|"off"} w.mode
 * @param {string} w.event            GitHub event name of the DEPLOY run
 * @param {string} w.branch           ref_name of the deploy run
 * @param {string} w.headSha
 * @param {string[]} w.requiredJobs
 * @param {JobRow[]} w.jobs           every job of every `ci` run for headSha
 * @param {number} w.ciRunsFound
 * @param {number} w.waitedSeconds
 * @param {number} w.deadlineSeconds
 * @returns {{verdict:"publish"|"refuse"|"wait", action:"publish"|"refuse"|"wait",
 *           code:string, reason:string, wouldRefuse:boolean, jobStates:object}}
 */
export function decideDeployGate(w) {
  const {
    mode = "advisory",
    event = "",
    branch = "",
    headSha = "",
    requiredJobs = [],
    jobs = [],
    ciRunsFound = 0,
    waitedSeconds = 0,
    deadlineSeconds = 1200,
  } = w;

  const out = (verdict, code, reason, jobStates = {}) => {
    // ADVISORY IS THE DEFAULT AND THAT IS THE POINT. Landing this file must
    // not change what publishes. In advisory mode the gate still collects the
    // facts, still decides, and still says out loud what it would have done —
    // so the operator can watch real verdicts accumulate against real pushes
    // before arming it. Arming is one repository variable, and disarming is
    // the same variable, with no commit and no deploy either way.
    let action = verdict;
    let wouldRefuse = verdict === "refuse";
    if (mode !== "enforce" && verdict === "refuse") action = "publish";
    return { verdict, action, code, reason, wouldRefuse, jobStates };
  };

  // G0 — off. Not the same as advisory: `off` does not even wait, so it is the
  // switch to reach for if this gate is ever the thing standing between a
  // rollback and production.
  if (mode === "off") {
    return out("publish", "G0", "gate is off (DEPLOY_GATE_MODE=off)");
  }

  // G1 — a pull_request deploy is a PREVIEW to the dev project, not a publish.
  // `deploy.yml`'s header describes one project per environment and PRs landing
  // as native previews on `blocktracer-dev`; nothing a preview does is visible
  // to a visitor of blocktracer.org, and gating previews would take away the
  // fastest feedback the repository has. Previews are explicitly out of scope.
  if (event !== "push") {
    return out("publish", "G1", `event '${event || "<none>"}' is a preview, not a publish`);
  }

  // G2 — a push to a branch that does not publish. `deploy.yml` only triggers
  // on the three, so this is defence in depth rather than a live case.
  if (!PUBLISH_BRANCHES.includes(branch)) {
    return out("publish", "G2", `branch '${branch || "<none>"}' does not publish`);
  }

  // G3 — A GATE THAT REQUIRES NOTHING IS NOT A GATE. The required set comes
  // from a repository variable so the operator can raise the floor without a
  // commit; the same mechanism can empty it by typo — `DEPLOY_GATE_REQUIRED_JOBS=""`
  // or a stray comma — and an empty set would make every subsequent check
  // vacuously true and every deploy "gated". This repository has already been
  // bitten by a check that passed because its universe was empty
  // (`ci-coverage.sh`'s "a parser that matched nothing reports perfect
  // coverage of nothing"). Refuse instead.
  const required = requiredJobs.filter((n) => typeof n === "string" && n.trim() !== "");
  if (required.length === 0) {
    return out(
      "refuse",
      "G3",
      "the required-job set is EMPTY — refusing rather than passing vacuously; " +
        "set DEPLOY_GATE_REQUIRED_JOBS to a non-empty list or DEPLOY_GATE_MODE=off",
    );
  }

  const overdue = waitedSeconds >= deadlineSeconds;

  // G4 — no `ci` run exists for this commit at all.
  if (ciRunsFound === 0) {
    if (!overdue) {
      return out("wait", "G4w", `no 'ci' run for ${short(headSha)} yet (${waitedSeconds}s waited)`);
    }
    return out(
      "refuse",
      "G4",
      `no 'ci' run exists for ${short(headSha)} after ${waitedSeconds}s — ` +
        "a commit nothing tested is not a commit that passed",
    );
  }

  // ── The per-job roll-up ───────────────────────────────────────────────────
  //
  // THE UNION ACROSS RUNS OF THE SAME BRANCH, BEST OUTCOME WINS. A commit can
  // have more than one `ci` run on one branch: the push run, plus any
  // `workflow_dispatch` run from `ci-coverage-clock.yml` or from a hand-forced
  // verdict. `ci.yml` documents that dispatch lane as EXISTING to produce a
  // verdict pushes cannot evict, so treating a green dispatch run as no
  // verdict — or letting a push run that was cancelled at second three
  // outvote it — would refuse to read the answer this repository built a
  // second lane to obtain.
  //
  // AND STRICTLY THE SAME BRANCH, WHICH THE FIRST DRAFT OF THIS FILE GOT
  // WRONG. It unioned every `ci` run for the sha regardless of branch, and the
  // first probe against real data caught it: c77a1b0f was pushed to `dev`,
  // `staging` and `live` inside 90 seconds, producing three `ci` runs over one
  // identical tree, and `ci-coverage` was `failure` on the staging run
  // (33921246632, 21:28:34-47Z) while `success` on the dev and live runs
  // (33921132640, 33921253095, same minute). The cross-branch union therefore
  // reported PUBLISH for the staging deploy of a commit whose staging ci had
  // just gone red — a gate laundering another branch's green over this
  // branch's red, which is precisely the "measured the wrong artefact" failure
  // this gate is supposed to be the answer to. The verdict that gates a
  // publish to a branch is the verdict produced ON that branch.
  const scoped = jobs.filter(
    (j) => j && (j.runBranch === undefined || j.runBranch === null || j.runBranch === branch),
  );
  const jobStates = {};
  for (const name of required) {
    const rows = scoped.filter((j) => j.name === name);
    if (rows.some((j) => j.conclusion === PASS)) {
      jobStates[name] = "success";
    } else if (rows.some((j) => j.conclusion)) {
      // Report the most recent non-success conclusion we saw.
      const bad = rows.filter((j) => j.conclusion).pop();
      jobStates[name] = bad.conclusion;
    } else if (rows.length > 0) {
      jobStates[name] = rows.some((j) => j.status === "in_progress") ? "in_progress" : "queued";
    } else {
      jobStates[name] = "absent";
    }
  }

  const failed = required.filter(
    (n) => jobStates[n] !== "success" && jobStates[n] !== "absent" &&
      jobStates[n] !== "queued" && jobStates[n] !== "in_progress",
  );

  // G5 — a required job reached a verdict and it was not `success`. Refused
  // immediately: there is nothing to wait for, and every second spent waiting
  // is a second the operator spends looking at a pending deploy.
  if (failed.length > 0) {
    return out(
      "refuse",
      "G5",
      `ci did not pass for ${short(headSha)}: ` +
        failed.map((n) => `${n}=${jobStates[n]}`).join(", "),
      jobStates,
    );
  }

  const absent = required.filter((n) => jobStates[n] === "absent");
  const pending = required.filter(
    (n) => jobStates[n] === "queued" || jobStates[n] === "in_progress",
  );

  // G6 — A REQUIRED JOB THAT DOES NOT EXIST IS A REFUSAL, NOT A PASS. This is
  // the vacuity guard, and it is the single most likely way this gate rots:
  // rename `deploy-gates` in `ci.yml` and a gate written as "no required job
  // failed" would go green forever over a job that no longer runs. The
  // selftest additionally asserts that every name in DEFAULT_REQUIRED_JOBS is
  // a real job key in `ci.yml`, so the rename is caught in `ci` rather than
  // discovered here at deploy time.
  if (absent.length > 0) {
    if (!overdue) {
      return out(
        "wait",
        "G6w",
        `not yet reported by any 'ci' run: ${absent.join(", ")} (${waitedSeconds}s waited)`,
        jobStates,
      );
    }
    return out(
      "refuse",
      "G6",
      `required job(s) absent from every 'ci' run for ${short(headSha)} after ` +
        `${waitedSeconds}s: ${absent.join(", ")} — a job that did not run did not pass`,
      jobStates,
    );
  }

  // G7 — still running. Wait, up to the deadline, then refuse: an unfinished
  // check is not a passed check, and failing closed here is cheap because the
  // measured time for all three jobs is under two minutes against a default
  // deadline of twenty.
  if (pending.length > 0) {
    if (!overdue) {
      return out(
        "wait",
        "G7w",
        `waiting on ${pending.map((n) => `${n}=${jobStates[n]}`).join(", ")} (${waitedSeconds}s)`,
        jobStates,
      );
    }
    return out(
      "refuse",
      "G7",
      `timed out after ${waitedSeconds}s with ${pending.join(", ")} unfinished — ` +
        "an unfinished check is not a passed check",
      jobStates,
    );
  }

  // G8 — every required job passed for this exact commit.
  return out(
    "publish",
    "G8",
    `ci passed for ${short(headSha)}: ${required.join(", ")}`,
    jobStates,
  );
}

/** Parse a repository-variable job list. Commas and/or whitespace. */
export function parseRequiredJobs(raw) {
  if (raw === undefined || raw === null) return [...DEFAULT_REQUIRED_JOBS];
  const trimmed = String(raw).trim();
  // An UNSET repository variable arrives in the environment as the empty
  // string — GitHub gives no way to tell "not set" from "set to nothing" —
  // so empty must mean the default set, or landing this file with the
  // variable absent would refuse every deploy under G3. What G3 catches is
  // the set that was WRITTEN and parses to nothing: `,`, `;`, `- none -`
  // reduced to separators. That is a typo, not an absence.
  if (trimmed === "") return [...DEFAULT_REQUIRED_JOBS];
  return trimmed
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter((s) => s !== "");
}

export function parseMode(raw) {
  const v = String(raw ?? "").trim().toLowerCase();
  if (v === "enforce") return "enforce";
  if (v === "off") return "off";
  // Anything else, INCLUDING UNSET AND INCLUDING A TYPO, is advisory. A
  // misspelled mode must never be the thing that stops publishing.
  return "advisory";
}

function short(sha) {
  return typeof sha === "string" && sha.length >= 7 ? sha.slice(0, 7) : String(sha || "<none>");
}
