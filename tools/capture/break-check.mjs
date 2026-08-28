#!/usr/bin/env node
// VD.1 — `verify_deliberate_break_is_detected`.
//
//   node tools/capture/break-check.mjs --list
//   node tools/capture/break-check.mjs --break debug-affordance
//   node tools/capture/break-check.mjs --break debug-affordance --keep
//   node tools/capture/break-check.mjs --grade reviews/break-round-debug-affordance.json
//
// "With a required element removed from a view, the review reports it as
// missing first and rates at or below 4."
//
// This script does the MECHANICAL half and nothing else: it removes a required
// element from the product's source, rebuilds, captures the affected view into
// a scratch directory, restores the source, and prints the review prompts. The
// review itself is performed by sub-agents that are NOT told a break was
// applied — telling them would test their obedience rather than the brief.
//
// The restore is in a `finally`, so an interrupted or failing run cannot leave
// the working tree holding a deliberately broken product.
//
// Why a real break against a real page, rather than an assertion: the check
// being made is "is the expected-elements block specific enough that a reviewer
// notices this element is gone". That is a property of the prose in the block,
// and the only way to measure it is to remove the element and read what a
// reviewer that has never seen the unbroken page says.

import { readFile, writeFile, mkdir, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join, relative, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { imageName } from "./views.mjs";
import { resolveExpectation } from "./expectations.mjs";
import { lensPrompt, ALL_LENSES } from "./review-prompt.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const BREAK_OUT = join(REPO_ROOT, "screenshots", "break");

// ── The break catalogue ────────────────────────────────────────────────────
//
// Each break removes ONE required element named in that view's expectation
// block. `expects` records which `mustShow` item the reviewers ought to name;
// it is the answer key, and it is deliberately not shown to them.

export const BREAKS = {
  "debug-affordance": {
    view: "tx-detail",
    size: "wide",
    theme: "light",
    file: "client/src/pages/tx.nim",
    // Delete the whole Debug affordance card: the button, its availability
    // badge, the note explaining the state, and the per-execution list.
    removeBetween: [
      "# ── Debug affordance (follows trace.availability) ─────",
      "# ── Overview grid ─────────────────────────────────────",
    ],
    description:
      "Remove the Debug affordance from the transaction page — the button, its availability badge and its explanatory note.",
    why:
      "Page-Descriptions rule 1: 'the debug affordance is the primary action wherever a transaction appears'. It is the first `mustShow` item of the `tx-detail` block and the single most load-bearing element in the product.",
    expects: {
      mustShowItemIndex: 0,
      keywords: ["debug", "primary action", "primary button"],
      maxRating: 4,
    },
  },

  "overview-grid": {
    view: "tx-detail",
    size: "wide",
    theme: "light",
    file: "client/src/pages/tx.nim",
    removeBetween: [
      "# ── Overview grid ─────────────────────────────────────",
      "# ── Decoded input ─────────────────────────────────────",
    ],
    description:
      "Remove the overview grid from the transaction page — block, canonicality, finality, roles and cost.",
    why:
      "§7.2.2. A second, structurally different break: a whole labelled data region rather than a single control, to check the block does not only work for the one element it names first.",
    expects: {
      mustShowItemIndex: 2,
      keywords: ["overview", "grid", "from", "value", "fee", "nonce"],
      maxRating: 4,
    },
  },
};

// ── Mechanics ──────────────────────────────────────────────────────────────

function removeRegion(source, [startMarker, endMarker]) {
  const lines = source.split("\n");
  const start = lines.findIndex((l) => l.includes(startMarker));
  if (start < 0) throw new Error(`start marker not found: ${startMarker}`);
  const end = lines.findIndex((l, i) => i > start && l.includes(endMarker));
  if (end < 0) throw new Error(`end marker not found after start: ${endMarker}`);
  const removed = lines.slice(start, end);
  return {
    text: [...lines.slice(0, start), ...lines.slice(end)].join("\n"),
    removedLines: removed.length,
    removed: removed.join("\n"),
  };
}

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { cwd: REPO_ROOT, encoding: "utf8", stdio: "pipe", ...opts });
  return { status: r.status, out: (r.stdout ?? "") + (r.stderr ?? ""), error: r.error };
}

async function applyBreak(name, { keep = false } = {}) {
  const spec = BREAKS[name];
  if (!spec) throw new Error(`unknown break '${name}' (have: ${Object.keys(BREAKS).join(", ")})`);

  const filePath = join(REPO_ROOT, spec.file);
  const original = await readFile(filePath, "utf8");
  const outDir = join(BREAK_OUT, name);
  const file = imageName(spec.view, spec.size, spec.theme);
  const image = join(outDir, file);

  let captureLog = "";
  let captureStatus = null;

  try {
    const { text, removedLines, removed } = removeRegion(original, spec.removeBetween);
    await writeFile(filePath, text);
    console.log(`applied break '${name}': removed ${removedLines} line(s) from ${spec.file}`);
    console.log("--- removed ---");
    console.log(removed.split("\n").map((l) => `  | ${l}`).join("\n"));
    console.log("---------------\n");

    await mkdir(outDir, { recursive: true });
    await rm(image, { force: true });

    // Targeted capture with an explicit --out, so the main screenshots/ set is
    // untouched and a broken image can never be mistaken for a good one.
    const r = run("node", [
      "tools/capture/capture.mjs",
      "--view", spec.view,
      "--size", spec.size,
      "--theme", spec.theme,
      "--out", outDir,
    ]);
    captureLog = r.out;
    captureStatus = r.status;
    console.log(captureLog.trim());
  } finally {
    if (keep) {
      console.log(`\n! --keep: ${spec.file} LEFT BROKEN. restore with: git checkout -- ${spec.file}`);
    } else {
      await writeFile(filePath, original);
      console.log(`\nrestored ${spec.file}`);
    }
  }

  const ok = captureStatus === 0 && existsSync(image);
  return { spec, name, image, ok, captureStatus, captureLog };
}

function printPrompts({ spec, image }) {
  const rel = relative(REPO_ROOT, image);
  console.log("\n" + "═".repeat(76));
  console.log("REVIEW PROMPTS — hand each to a separate disposable sub-agent.");
  console.log("DO NOT tell the reviewers that anything was removed. The prompts below");
  console.log("are byte-identical to a normal review round; that is the point.");
  console.log("═".repeat(76));
  for (const lens of ALL_LENSES) {
    console.log(`\n──────── ${lens} ────────\n`);
    console.log(
      lensPrompt({ lens, viewId: spec.view, size: spec.size, theme: spec.theme, imagePath: rel }),
    );
  }
}

function printAnswerKey({ name, spec }) {
  const e = resolveExpectation(spec.view);
  const item = e.mustShow[spec.expects.mustShowItemIndex];
  console.log("\n" + "═".repeat(76));
  console.log(`ANSWER KEY for '${name}' — for grading only. Never shown to a reviewer.`);
  console.log("═".repeat(76));
  console.log(`removed:      ${spec.description}`);
  console.log(`why it counts: ${spec.why}`);
  console.log(`the mustShow item that should be reported missing:`);
  console.log(`  "${item}"`);
  console.log(`\nPASS requires, from EVERY reviewer:`);
  console.log(`  1. \`expectedElements\` is NOT "present"`);
  console.log(`  2. the missing element is the FIRST finding`);
  console.log(`  3. the finding is severity P1`);
  console.log(`  4. rating <= ${spec.expects.maxRating}`);
  console.log(`\nA reviewer that rates this above ${spec.expects.maxRating}, or that leads with an`);
  console.log(`aesthetic observation, means the expectation block is too vague — fix the`);
  console.log(`block in tools/capture/expectations.mjs, not the reviewer.`);
}

// ── Grading a recorded break round ─────────────────────────────────────────
//
// The reviews are performed by sub-agents, so the round's outcome has to be
// recorded to be re-checkable. `--grade <file>` reads the six reviewers'
// ledger blocks back and decides the verification, rather than the outcome
// being asserted in prose by whoever ran it.

export function gradeRound(round) {
  const spec = BREAKS[round.break];
  if (!spec) throw new Error(`recorded round names an unknown break '${round.break}'`);
  const e = resolveExpectation(spec.view);
  const target = e.mustShow[spec.expects.mustShowItemIndex];
  const kw = spec.expects.keywords.map((k) => k.toLowerCase());

  const rows = [];
  for (const r of round.reviews) {
    const checks = [];
    const add = (id, ok, detail) => checks.push({ id, ok, detail });

    add(
      "verdict",
      r.expectedElements !== "present",
      `expectedElements = '${r.expectedElements}'`,
    );

    // "reports it as missing FIRST" — the removed element must head the
    // `missing` list, not appear somewhere down it.
    const first = (r.missing ?? [])[0] ?? "";
    const firstMentions = kw.some((k) => first.toLowerCase().includes(k));
    add("missing-first", firstMentions, `first missing item: "${first.slice(0, 90)}${first.length > 90 ? "…" : ""}"`);

    // ...and the first FINDING must be the same thing, at P1.
    const f0 = (r.findings ?? [])[0];
    add(
      "finding-first-P1",
      !!f0 && f0.severity === "P1" && kw.some((k) => `${f0.finding} ${f0.location}`.toLowerCase().includes(k)),
      f0 ? `${f0.severity} — ${f0.location}` : "no findings recorded",
    );

    add(
      "rating",
      typeof r.rating === "number" && r.rating <= spec.expects.maxRating,
      `rating = ${r.rating} (must be <= ${spec.expects.maxRating})`,
    );

    rows.push({ reviewer: r.reviewer, pass: checks.every((c) => c.ok), checks });
  }

  // The control round: the SAME prompt against the unbroken capture must find
  // the element. Without it, "the reviewers said it was missing" is not
  // evidence that the block detects the break — a block strict enough to fail
  // every capture would score identically.
  const control = (round.control ?? []).map((r) => {
    const found = JSON.stringify(r).toLowerCase();
    const locates = kw.some((k) => found.includes(k));
    return {
      reviewer: r.reviewer,
      // The control passes when the reviewer LOCATES the element on the page —
      // whether it judged it well-rendered is a different question and not
      // this verification's business.
      pass: locates && r.locatedElement === true,
      detail: r.controlNote ?? "",
    };
  });

  return {
    break: round.break,
    view: spec.view,
    image: round.image,
    element: target,
    reviewers: rows,
    control,
    reviewersPassing: rows.filter((r) => r.pass).length,
    reviewersTotal: rows.length,
    controlPassing: control.filter((c) => c.pass).length,
    controlTotal: control.length,
    ok:
      rows.length > 0 &&
      rows.every((r) => r.pass) &&
      control.length > 0 &&
      control.every((c) => c.pass),
  };
}

async function grade(path) {
  const round = JSON.parse(await readFile(path, "utf8"));
  const g = gradeRound(round);
  console.log(`verify_deliberate_break_is_detected — break '${g.break}' on view '${g.view}'`);
  console.log(`broken image: ${g.image}`);
  console.log(`\nelement removed (mustShow item):\n  "${g.element}"\n`);
  for (const r of g.reviewers) {
    console.log(`  ${r.pass ? "✓" : "✗"} ${r.reviewer}`);
    for (const c of r.checks) console.log(`      ${c.ok ? "✓" : "✗"} ${c.id.padEnd(16)} ${c.detail}`);
  }
  console.log(`\ncontrol round — the same prompts against the UNBROKEN capture:`);
  for (const c of g.control) {
    console.log(`  ${c.pass ? "✓" : "✗"} ${c.reviewer}  ${c.detail}`);
  }
  console.log(
    `\n${g.ok ? "PASS" : "FAIL"} — ${g.reviewersPassing}/${g.reviewersTotal} reviewers detected the break; ` +
      `${g.controlPassing}/${g.controlTotal} control reviewers located the element when it was present.`,
  );
  return g.ok ? 0 : 1;
}

// ── CLI ────────────────────────────────────────────────────────────────────

async function main(argv) {
  const gi = argv.indexOf("--grade");
  if (gi >= 0) return grade(resolvePath(argv[gi + 1]));

  if (argv.includes("--list") || argv.length === 0) {
    console.log("deliberate breaks (VD.1 verify_deliberate_break_is_detected):\n");
    for (const [name, s] of Object.entries(BREAKS)) {
      console.log(`  ${name}`);
      console.log(`    view:   ${s.view} @ ${s.size}/${s.theme}`);
      console.log(`    file:   ${s.file}`);
      console.log(`    breaks: ${s.description}`);
      console.log(`    why:    ${s.why}\n`);
    }
    console.log("run:  node tools/capture/break-check.mjs --break <name>");
    return 0;
  }

  const i = argv.indexOf("--break");
  if (i < 0) throw new Error("--break <name> is required (or --list)");
  const name = argv[i + 1];
  const keep = argv.includes("--keep");

  const result = await applyBreak(name, { keep });
  if (!result.ok) {
    console.error(`\nFAILED to capture the broken view (exit ${result.captureStatus}).`);
    return 2;
  }
  printPrompts(result);
  printAnswerKey(result);
  console.log(`\nbroken image: ${relative(REPO_ROOT, result.image)}`);
  return 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2))
    .then((c) => process.exit(c))
    .catch((err) => {
      console.error(`break-check failed: ${err.message}`);
      process.exit(2);
    });
}

export { applyBreak, removeRegion };
