#!/usr/bin/env node
// VD.1 — the three verifications, end to end.
//
//   node tools/capture/review-selftest.mjs
//
// | VD.1 verification                        | Proved by |
// | ---------------------------------------- | --------- |
// | verify_brief_has_expectation_block_per_view | check-brief.mjs, plus a NEGATIVE control: a view whose block is removed must make the check fail |
// | verify_deliberate_break_is_detected      | break-check.mjs --grade over the recorded round, which grades the six reviewers' own ledger blocks |
// | verify_gate_definition_is_machine_checkable | gate-selftest.mjs (every condition independently blocks) plus a real run over reviews/ledger.json |
//
// The negative controls are the point. A checker that passes is not evidence;
// a checker that passes AND fails for the right reason is.

import { readFile, writeFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { BREAKS } from "./break-check.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const BRIEF = join(REPO_ROOT, "tools", "visual-review-brief.md");
const ROUNDS_DIR = join(REPO_ROOT, "reviews");
const LEDGER = join(REPO_ROOT, "reviews", "ledger.json");

const results = [];
function check(name, ok, detail = "") {
  results.push({ name, ok, detail });
  console.log(`  ${ok ? "✓" : "✗"} ${name}${detail ? `\n        ${detail}` : ""}`);
}

const node = (args, opts = {}) =>
  spawnSync("node", args, { cwd: REPO_ROOT, encoding: "utf8", ...opts });

async function main() {
  console.log("verify_brief_has_expectation_block_per_view\n");

  let r = node([join(HERE, "check-brief.mjs"), "--json"]);
  let j = null;
  try { j = JSON.parse(r.stdout); } catch { /* */ }
  check(
    "positive — every named view has an expected-elements block",
    r.status === 0 && j?.ok === true && j.viewsWithoutBlock.length === 0,
    j ? `${j.blocksInBrief}/${j.namedViews} blocks` : `exit ${r.status}`,
  );

  // NEGATIVE CONTROL: delete one view's block from the brief on disk and
  // confirm the check fails naming that view. Restored in `finally`.
  const original = await readFile(BRIEF, "utf8");
  try {
    const victim = "### View: `block-detail`";
    const start = original.indexOf(victim);
    const nextHeading = original.indexOf("### View: `", start + victim.length);
    if (start < 0 || nextHeading < 0) throw new Error("could not locate a block to remove");
    await writeFile(BRIEF, original.slice(0, start) + original.slice(nextHeading));

    r = node([join(HERE, "check-brief.mjs"), "--json"]);
    try { j = JSON.parse(r.stdout); } catch { j = null; }
    check(
      "negative — a view WITHOUT a block fails the check",
      r.status === 1 && j?.ok === false && j.viewsWithoutBlock.includes("block-detail"),
      j ? `viewsWithoutBlock = [${j.viewsWithoutBlock.join(", ")}]` : `exit ${r.status}, unparseable output`,
    );
  } finally {
    await writeFile(BRIEF, original);
  }

  r = node([join(HERE, "check-brief.mjs"), "--json"]);
  try { j = JSON.parse(r.stdout); } catch { j = null; }
  check("the brief was restored after the negative control", r.status === 0 && j?.ok === true);

  console.log("\nverify_deliberate_break_is_detected\n");

  const rounds = existsSync(ROUNDS_DIR)
    ? (await readdir(ROUNDS_DIR)).filter((f) => /^break-round-.*\.json$/.test(f)).sort()
    : [];

  check(
    "a recorded break round exists for every break in the catalogue",
    rounds.length >= Object.keys(BREAKS).length,
    `${rounds.length} recorded round(s) for ${Object.keys(BREAKS).length} break(s): ${Object.keys(BREAKS).join(", ")}`,
  );

  for (const f of rounds) {
    r = node([join(HERE, "break-check.mjs"), "--grade", join(ROUNDS_DIR, f)]);
    const lines = r.stdout.trim().split("\n");
    check(
      `${f} — every reviewer reported the removed element missing first, at P1, rating <= 4`,
      r.status === 0,
      lines[lines.length - 1] ?? r.stderr.trim(),
    );
  }

  console.log("\nverify_gate_definition_is_machine_checkable\n");

  r = node([join(HERE, "gate-selftest.mjs")]);
  const last = r.stdout.trim().split("\n").pop();
  check("every gate condition independently blocks (gate-selftest)", r.status === 0, last ?? "");

  if (!existsSync(LEDGER)) {
    check("the real ledger is gated", false, `no ledger at ${LEDGER}`);
  } else {
    r = node([join(HERE, "gate.mjs"), "--json"]);
    let g = null;
    try { g = JSON.parse(r.stdout); } catch { /* */ }
    // The real ledger is NOT expected to pass — no view has been taken to the
    // gate yet. What is asserted is that the gate produced a decision over it,
    // per target, per condition, rather than erroring or abstaining.
    const decided =
      g !== null &&
      Array.isArray(g.results) &&
      g.results.length > 0 &&
      g.results.every((t) => t.conditions.length === 5 && t.conditions.every((c) => typeof c.ok === "boolean"));
    check(
      "the real ledger yields a per-condition decision for every target",
      decided,
      g ? `${g.passing}/${g.scope} passing; verdict ok=${g.ok}` : `exit ${r.status}`,
    );
    check(
      "the gate reports the tier-1 precondition as NOT enforced rather than assuming it",
      g?.tier1?.enforced === false && typeof g?.tier1?.why === "string" && g.tier1.why.length > 40,
      g?.tier1?.condition ?? "",
    );
  }

  const failed = results.filter((x) => !x.ok);
  console.log(
    `\n${failed.length ? "FAIL" : "PASS"} — ${results.length - failed.length}/${results.length} VD.1 checks`,
  );
  return failed.length ? 1 : 0;
}

main()
  .then((c) => process.exit(c))
  .catch((e) => {
    console.error(`review-selftest failed: ${e.message}`);
    process.exit(2);
  });
