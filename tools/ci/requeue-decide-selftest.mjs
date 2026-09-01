#!/usr/bin/env node
// The self-test for `tools/ci/requeue-decide.mjs`.
//
//   node tools/ci/requeue-decide-selftest.mjs
//
// ── The bar ────────────────────────────────────────────────────────────────
//
// This watchdog spends a scarce shared runner pool WITHOUT a human in the
// loop, and it can publish. So the interesting assertions here are not that it
// retries — they are the four worlds in which it must REFUSE to, each of which
// is a way an unattended retry loop does damage:
//
//   * a genuine build failure (arm 2) — retrying burns the pool and hides the
//     defect behind N identical red runs.
//   * a supersede (arm 6) — retrying rebuilds an older commit and publishes it
//     over a newer one, i.e. rolls production back, silently, on a green run.
//   * an unreadable branch tip (arm 7) — acting on a fact we failed to read is
//     how arm 6 happens by accident.
//   * an exhausted bound (arm 8) — the loop must terminate, loudly.
//
// Every arm asserts the DECISION CODE, not just the action, because "skip" is
// reached by seven different routes and an arm that only checked the action
// would let any one of them stand in for the rule written for it.

import {
  decideRequeue,
  DEFAULT_MAX_ATTEMPTS,
  RETRYABLE,
  DEPLOY_BRANCHES,
} from "./requeue-decide.mjs";

const TIP = "39344fa322059d4c8c88be30e571c33c59f891cc";
const OLD = "52d8748dba5937f7981a93cc6b2f46619a82829d";

// A deploy that was starved at the tip: the base world every arm mutates.
const base = Object.freeze({
  conclusion: "cancelled",
  event: "push",
  branch: "live",
  headSha: TIP,
  branchTipSha: TIP,
  runAttempt: 1,
  maxAttempts: DEFAULT_MAX_ATTEMPTS,
  disabled: false,
});

const arms = [
  {
    name: "the control — starved at the tip, first attempt, is re-enqueued",
    why: "without this every refusal below is meaningless: a decider that " +
         "refused unconditionally would score identically on the refusals alone",
    world: {},
    want: { action: "requeue", code: "D8" },
  },
  {
    name: "a GENUINE FAILURE is never re-enqueued",
    why: "the constraint. `failure` is the repository's own content failing to " +
         "build; retrying burns the pool and hides the defect",
    world: { conclusion: "failure" },
    want: { action: "skip", code: "D2" },
  },
  {
    name: "a genuine failure is refused even at attempt 1 at the tip",
    why: "D2 must be reached BEFORE the bound and before the supersede guard — " +
         "otherwise a failure on a fresh tip would fall through to D8",
    world: { conclusion: "failure", runAttempt: 1, headSha: TIP, branchTipSha: TIP },
    want: { action: "skip", code: "D2" },
  },
  {
    name: "a successful deploy is left alone",
    world: { conclusion: "success" },
    want: { action: "skip", code: "D1" },
  },
  {
    name: "a pull_request preview is not the publish path",
    world: { event: "pull_request", branch: "feat/whatever" },
    want: { action: "skip", code: "D3" },
  },
  {
    name: "a SUPERSEDED cancel is never re-enqueued",
    why: "run 33492060086 exactly: dev@52d8748 cancelled at 09:34:37Z by the " +
         "push of 39344fa. Re-running it would publish 52d8748 over 39344fa",
    world: { branch: "dev", headSha: OLD, branchTipSha: TIP },
    want: { action: "skip", code: "D6" },
  },
  {
    name: "an unreadable branch tip is refused rather than guessed",
    why: "acting on a fact we failed to read is how a supersede happens by accident",
    world: { branchTipSha: "" },
    want: { action: "skip", code: "D6b" },
  },
  {
    name: "the bound terminates the loop, loudly",
    why: "escalate, not skip — a deploy starved five times wants a human, and a " +
         "watchdog that quietly gave up would look identical to one still trying",
    world: { runAttempt: DEFAULT_MAX_ATTEMPTS },
    want: { action: "escalate", code: "D7" },
  },
  {
    name: "one attempt below the bound still retries",
    why: "an off-by-one here either wastes a retry or spends one too many",
    world: { runAttempt: DEFAULT_MAX_ATTEMPTS - 1 },
    want: { action: "requeue", code: "D8" },
  },
  {
    name: "the kill switch wins over everything",
    why: "the one case indistinguishable from starvation is a human cancelling " +
         "the tip's deploy on purpose; they must be able to win in one click",
    world: { disabled: true },
    want: { action: "skip", code: "D0" },
  },
  {
    name: "a timed-out deploy is NOT treated as infrastructure",
    why: "it was running, not starved; re-running a hang costs a full runner " +
         "slot to reproduce the hang",
    world: { conclusion: "timed_out" },
    want: { action: "skip", code: "D5" },
  },
  {
    name: "an outcome this file has never heard of is left alone",
    why: "the retryable set is a closed allowlist, not 'anything but success'",
    world: { conclusion: "action_required" },
    want: { action: "skip", code: "D5" },
  },
  {
    name: "a non-publishing branch is left alone",
    world: { branch: "chain/mainnet-follower" },
    want: { action: "skip", code: "D4" },
  },
  {
    name: "startup_failure at the tip is infrastructure, and is re-enqueued",
    why: "a runner that died before the first step never saw the repository's code",
    world: { conclusion: "startup_failure" },
    want: { action: "requeue", code: "D8" },
  },
];

let passed = 0;
const failures = [];

console.log("requeue-decide-selftest");
console.log("");

for (const arm of arms) {
  const world = { ...base, ...arm.world };
  const got = decideRequeue(world);
  const ok = got.action === arm.want.action && got.code === arm.want.code;
  if (ok) {
    passed++;
    console.log(`  PASS  ${arm.name}`);
    console.log(`          -> ${got.action} (${got.code}): ${got.reason}`);
  } else {
    failures.push(arm.name);
    console.log(`  FAIL  ${arm.name}`);
    console.log(`          wanted ${arm.want.action} (${arm.want.code}), ` +
                `got ${got.action} (${got.code}): ${got.reason}`);
  }
  if (arm.why) console.log(`          why: ${arm.why}`);
}

console.log("");

// Pinned assertions on the shape of the policy itself, since the arms above
// would all still pass if `failure` were quietly added to the retryable set
// and a D2 rule removed.
let pinned = 0;
const pin = (cond, label) => {
  if (cond) { pinned++; console.log(`  PASS  ${label}`); }
  else { failures.push(label); console.log(`  FAIL  ${label}`); }
};

pin(!RETRYABLE.includes("failure"),
    "'failure' is not in the retryable allowlist");
pin(!RETRYABLE.includes("timed_out"),
    "'timed_out' is not in the retryable allowlist");
pin(RETRYABLE.length === 2,
    `the retryable allowlist is exactly [${RETRYABLE.join(", ")}] and nothing else`);
pin(DEPLOY_BRANCHES.length === 3 && DEPLOY_BRANCHES.includes("live"),
    `the publishing branches are exactly [${DEPLOY_BRANCHES.join(", ")}]`);
pin(DEFAULT_MAX_ATTEMPTS >= 2 && DEFAULT_MAX_ATTEMPTS <= 10,
    `the bound is ${DEFAULT_MAX_ATTEMPTS}: more than one retry, and finite`);

// The loop provably terminates: from any attempt, repeated requeues reach
// escalate in a bounded number of steps. Asserted rather than argued, because
// "it cannot loop forever" is the property the pool depends on.
{
  let attempt = 1;
  let steps = 0;
  let last = null;
  while (steps < 100) {
    last = decideRequeue({ ...base, runAttempt: attempt });
    if (last.action !== "requeue") break;
    attempt++;
    steps++;
  }
  pin(last && last.action === "escalate" && steps < 100,
      `repeated starvation terminates at escalate after ${steps} requeue(s), never loops`);
}

console.log("");
console.log(`arms: ${passed}/${arms.length} passed, plus ${pinned} pinned assertions`);
if (failures.length) {
  console.log(`requeue-decide-selftest: FAIL — ${failures.length}: ${failures.join("; ")}`);
  process.exit(1);
}
console.log(
  "requeue-decide-selftest: PASS — the four worlds it must refuse to retry were " +
  "each shown to be refused by the rule written for them, and the loop was shown to terminate",
);
