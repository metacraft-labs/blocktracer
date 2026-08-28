#!/usr/bin/env node
// VD.0 verification: verify_canary_failure_invalidates_the_baselines
//
//   node tools/capture/require-deterministic.mjs [--out DIR] [--max-age-hours N]
//
// The gate every baseline-comparing check must pass through FIRST. It reads
// the tier-1 verdict written by check-canary.mjs and answers one question:
// may a perceptual comparison against stored baselines be believed?
//
// It refuses in four distinct ways, because collapsing them would produce
// exactly the failure this exists to prevent — a comparison that runs, passes,
// and means nothing:
//
//   * no verdict          — the canary has not run; nothing is known
//   * stale verdict       — the canary ran too long ago to speak for this tree
//   * advisory verdict    — the canary ran outside the pinned container, so it
//                           measured a runner rather than the product
//   * failed verdict      — the harness is not deterministic; every baseline
//                           is worthless until that is fixed
//
// In all four cases the correct downstream behaviour is to report the
// perceptual comparison as UNRELIABLE — not to run it, and not to pass it.

import { readFile } from "node:fs/promises";
import { join, dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");

function parseArgs(argv) {
  const opts = { out: join(REPO_ROOT, "screenshots"), maxAgeHours: 24, json: false, allowAdvisory: false };
  for (let i = 2; i < argv.length; i++) {
    switch (argv[i]) {
      case "--out": opts.out = resolvePath(argv[++i]); break;
      case "--max-age-hours": opts.maxAgeHours = Number(argv[++i]); break;
      case "--allow-advisory": opts.allowAdvisory = true; break;
      case "--json": opts.json = true; break;
      default: throw new Error(`unknown argument: ${argv[i]}`);
    }
  }
  return opts;
}

export async function readVerdict(outDir) {
  const path = join(outDir, "canary", "status.json");
  try {
    return { path, status: JSON.parse(await readFile(path, "utf8")) };
  } catch {
    return { path, status: null };
  }
}

/**
 * @returns {{usable: boolean, reason: string, code: string}}
 */
export function evaluate(status, { maxAgeHours = 24, allowAdvisory = false } = {}) {
  if (!status)
    return {
      usable: false,
      code: "no-verdict",
      reason: "the determinism canary has not run; nothing is known about the harness",
    };
  if (status.deterministic !== true)
    return {
      usable: false,
      code: "canary-failed",
      reason: `the determinism canary FAILED (${(status.mismatches ?? []).length} mismatch(es)); every stored baseline is unreliable`,
    };
  const ageHours = (Date.now() - Date.parse(status.generatedAt)) / 3_600_000;
  if (Number.isFinite(ageHours) && ageHours > maxAgeHours)
    return {
      usable: false,
      code: "stale-verdict",
      reason: `the canary verdict is ${ageHours.toFixed(1)}h old (limit ${maxAgeHours}h); it no longer speaks for this tree`,
    };
  if (status.advisory && !allowAdvisory)
    return {
      usable: false,
      code: "advisory-verdict",
      reason:
        "the canary ran outside the pinned container, so it measured the runner rather than the product; re-run via tools/capture/run-in-container.sh",
    };
  return {
    usable: true,
    code: "ok",
    reason: `canary byte-identical across ${status.runs} runs in ${status.environment?.container ?? "the pinned container"}`,
  };
}

async function main() {
  const opts = parseArgs(process.argv);
  const { path, status } = await readVerdict(opts.out);
  const verdict = evaluate(status, opts);

  if (opts.json) {
    console.log(JSON.stringify({ verdictFile: path, ...verdict, status }, null, 2));
  } else if (verdict.usable) {
    console.log(`tier-1 OK — ${verdict.reason}`);
    console.log(`baselines may be compared.`);
  } else {
    console.log(`BASELINES UNRELIABLE (${verdict.code})`);
    console.log(`  ${verdict.reason}`);
    console.log(`  verdict file: ${path}`);
    console.log("");
    console.log("A perceptual comparison run now would report a result it cannot support.");
    console.log("Report it as unreliable; do not run it and believe it.");
  }
  return verdict.usable ? 0 : 1;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main()
    .then((c) => process.exit(c))
    .catch((e) => {
      console.error(`gate failed: ${e.message}`);
      process.exit(2);
    });
}
