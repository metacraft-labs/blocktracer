#!/usr/bin/env node
// Decide whether a finished `Deploy` run should be re-enqueued.
//
//   node tools/ci/requeue-decide.mjs            # reads the world from env, prints a decision
//   node tools/ci/requeue-decide.mjs --json     # ... as JSON
//
// ── Why this exists ────────────────────────────────────────────────────────
//
// `eph-linux-x64` is a small ephemeral pool shared across the org, and this
// repository's deploys sit behind it. Runs queue for tens of minutes, and a
// deploy that never reaches a runner is indistinguishable, from the outside,
// from one that was never asked for: production keeps serving the previous
// commit and nothing is red. The observed cost is a person re-clicking
// "Re-run" until a deploy happens to land.
//
// This module is the judgement in that re-clicking, written down. The
// workflow around it (`.github/workflows/deploy-requeue.yml`) supplies the
// facts and performs the action; every decision is made here, so it can be
// tested without GitHub.
//
// ── The two rules that matter more than the feature ────────────────────────
//
// D2. A GENUINE FAILURE IS NEVER RE-ENQUEUED. A retry loop over a real build
//     error burns the pool that is already the bottleneck, and buries the
//     defect under N identical red runs. `failure` means the repository's own
//     content did not build or did not deploy; that is a fact to report, not a
//     condition to retry. Only infrastructure outcomes are retried, and the
//     retryable set is a closed allowlist rather than "anything that is not
//     success" — an outcome this file has never heard of is left alone.
//
// D6. A CANCEL THAT WAS A SUPERSEDE IS NEVER RE-ENQUEUED. `deploy.yml` sets
//     `concurrency: cancel-in-progress: true`, so the ORDINARY way a deploy
//     ends here is that a newer push to the same branch cancelled it — run
//     33492060086 (dev@52d8748) was cancelled at 09:34:37Z by the push of
//     39344fa two seconds earlier. Re-running that run would rebuild the OLD
//     commit and publish it over the newer one: an auto-retry that silently
//     rolls production back. So a cancelled run is retried only while its
//     head_sha is still the tip of its branch. If the tip has moved, the newer
//     run is the one that matters and this one is correctly dead.
//
// ── The bound ──────────────────────────────────────────────────────────────
//
// `run_attempt` is GitHub's own per-run counter and it increments on every
// re-run, so it is a durable bound that needs no state of ours and cannot be
// lost or double-counted if two watchdog invocations race. At
// `maxAttempts` the watchdog stops and escalates loudly rather than quietly
// giving up, because a deploy that has been starved five times is no longer a
// queue blip and wants a human.

export const RETRYABLE = Object.freeze(["cancelled", "startup_failure"]);

// Branches that publish. A PR preview being starved costs a preview; this
// watchdog is for the ones where staleness is visible to a user.
export const DEPLOY_BRANCHES = Object.freeze(["live", "staging", "dev"]);

export const DEFAULT_MAX_ATTEMPTS = 5;

/**
 * @param {object} w  the world
 * @returns {{action: "requeue"|"skip"|"escalate", code: string, reason: string}}
 */
export function decideRequeue(w) {
  const {
    conclusion,
    event,
    branch,
    headSha,
    branchTipSha,
    runAttempt,
    maxAttempts = DEFAULT_MAX_ATTEMPTS,
    disabled = false,
  } = w;

  // D0 — the kill switch. A repo variable turns this off without a commit,
  // which matters because the one case this watchdog cannot distinguish is a
  // human deliberately cancelling a deploy of the current tip: to the API that
  // looks exactly like starvation. If someone is fighting the watchdog, they
  // must be able to win in one click.
  if (disabled) {
    return { action: "skip", code: "D0", reason: "disabled by DEPLOY_REQUEUE_DISABLED" };
  }

  // D1 — nothing to do for a deploy that worked.
  if (conclusion === "success") {
    return { action: "skip", code: "D1", reason: "deploy succeeded" };
  }

  // D2 — the rule that must not be softened. See the header.
  if (conclusion === "failure") {
    return {
      action: "skip",
      code: "D2",
      reason:
        "genuine build/deploy failure — never auto-retried; the repository's " +
        "own content is what failed, and a retry would hide it",
    };
  }

  // D3 — pull_request runs are previews, not the publish path.
  if (event !== "push") {
    return { action: "skip", code: "D3", reason: `event is '${event}', not a push` };
  }

  // D4 — only the publishing branches.
  if (!DEPLOY_BRANCHES.includes(branch)) {
    return { action: "skip", code: "D4", reason: `branch '${branch}' does not publish` };
  }

  // D5 — closed allowlist. `timed_out` is deliberately NOT here: a deploy that
  // exhausted its time limit was running, not starved, and re-running a hang
  // costs a full runner slot to reproduce a hang. `action_required`,
  // `neutral`, `skipped`, `stale` are likewise left alone.
  if (!RETRYABLE.includes(conclusion)) {
    return {
      action: "skip",
      code: "D5",
      reason: `conclusion '${conclusion}' is not an infrastructure outcome`,
    };
  }

  // D6 — the supersede guard. See the header. An unknown tip is treated as
  // "do not touch": acting on a fact we failed to read is how an auto-retry
  // rolls production back.
  if (!branchTipSha) {
    return {
      action: "skip",
      code: "D6b",
      reason: "could not read the branch tip; refusing to requeue on an unverified world",
    };
  }
  if (headSha !== branchTipSha) {
    return {
      action: "skip",
      code: "D6",
      reason:
        `superseded — run is ${short(headSha)} but '${branch}' is now ` +
        `${short(branchTipSha)}; the newer run is the one that matters`,
    };
  }

  // D7 — the bound.
  if (runAttempt >= maxAttempts) {
    return {
      action: "escalate",
      code: "D7",
      reason:
        `exhausted ${maxAttempts} attempts and is still '${conclusion}' at the ` +
        `branch tip — this is no longer a queue blip`,
    };
  }

  // D8 — starved at the tip, within the bound: re-enqueue.
  return {
    action: "requeue",
    code: "D8",
    reason:
      `'${conclusion}' at the branch tip on attempt ${runAttempt} of ` +
      `${maxAttempts} — re-enqueueing the same commit`,
  };
}

function short(sha) {
  return typeof sha === "string" && sha.length >= 7 ? sha.slice(0, 7) : String(sha);
}

// ── CLI ────────────────────────────────────────────────────────────────────

function worldFromEnv(env) {
  const max = Number.parseInt(env.MAX_ATTEMPTS ?? "", 10);
  return {
    conclusion: env.RUN_CONCLUSION || "",
    event: env.RUN_EVENT || "",
    branch: env.RUN_BRANCH || "",
    headSha: env.RUN_HEAD_SHA || "",
    branchTipSha: env.BRANCH_TIP_SHA || "",
    runAttempt: Number.parseInt(env.RUN_ATTEMPT ?? "1", 10) || 1,
    maxAttempts: Number.isFinite(max) && max > 0 ? max : DEFAULT_MAX_ATTEMPTS,
    disabled: /^(1|true|yes)$/i.test(env.DEPLOY_REQUEUE_DISABLED || ""),
  };
}

const isMain =
  process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;

if (isMain) {
  const world = worldFromEnv(process.env);
  const d = decideRequeue(world);
  if (process.argv.includes("--json")) {
    console.log(JSON.stringify({ ...d, world }));
  } else {
    console.log(`${d.action} (${d.code}): ${d.reason}`);
  }
  // Emit for the workflow to branch on.
  if (process.env.GITHUB_OUTPUT) {
    const { appendFileSync } = await import("node:fs");
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      `action=${d.action}\ncode=${d.code}\nreason=${d.reason.replace(/\n/g, " ")}\n`,
    );
  }
}
