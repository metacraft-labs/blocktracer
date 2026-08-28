#!/usr/bin/env node
// VD.0 verification: verify_canary_capture_is_byte_identical
//
//   node tools/capture/check-canary.mjs [--runs 2] [--out DIR] [--json]
//
// Tier 1 of the four-tier hierarchy in visual-design-iteration.md. Its job is
// NOT to detect regressions — it answers one question: *is the capture harness
// still deterministic?* If it is not, every tier-2 baseline is quietly
// worthless, so this runs first and its failure invalidates the rest.
//
// Three constraints, all of them load-bearing:
//
//   1. A PINNED CONTAINER. Browser build, fonts and renderer flags fixed. An
//      exact-hash check across heterogeneous runners measures the runner, not
//      the product. Run this via tools/capture/run-in-container.sh. Run
//      directly on a host it still works, but the verdict it writes is marked
//      `advisory` and `require-deterministic.mjs` will not accept it as a
//      tier-1 pass.
//
//   2. A HANDFUL OF VIEWS, covering the distinct rendering paths — dense text,
//      a data table, a chart, one dark-theme view — and not the full corpus.
//      Exact comparison over hundreds of images eventually flakes somewhere,
//      and the response to a flaky mandatory gate is to switch it off.
//
//   3. BYTE-IDENTICAL IS THE ASSERTION. At this scope, anything less exact is
//      not answering the question.
//
// The verdict is written to <out>/canary/status.json, and that file — not this
// process's exit code — is what a later perceptual comparison must consult
// before it believes its own baselines.

import { mkdir, rm, readdir, readFile, writeFile } from "node:fs/promises";
import { join, dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";

import { CANARY, VIEWS_BY_ID, imageName } from "./views.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const DEFAULT_OUT = join(REPO_ROOT, "screenshots");

function parseArgs(argv) {
  const opts = { out: DEFAULT_OUT, runs: 2, json: false, dist: null, build: true };
  for (let i = 2; i < argv.length; i++) {
    switch (argv[i]) {
      case "--out": opts.out = resolvePath(argv[++i]); break;
      case "--dist": opts.dist = resolvePath(argv[++i]); break;
      case "--runs": opts.runs = Number(argv[++i]); break;
      case "--no-build": opts.build = false; break;
      case "--json": opts.json = true; break;
      default: throw new Error(`unknown argument: ${argv[i]}`);
    }
  }
  if (!Number.isInteger(opts.runs) || opts.runs < 2)
    throw new Error(`--runs must be an integer >= 2`);
  return opts;
}

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

async function hashDir(dir) {
  const out = new Map();
  for (const f of (await readdir(dir)).filter((f) => f.endsWith(".png")).sort()) {
    out.set(f, sha256(await readFile(join(dir, f))));
  }
  return out;
}

function runCapture(outDir, { dist, build }) {
  const args = [join(HERE, "capture.mjs"), "--canary", "--out", outDir];
  if (dist) args.push("--dist", dist);
  if (!build) args.push("--no-build");
  const r = spawnSync(process.execPath, args, { encoding: "utf8" });
  if (r.status !== 0) {
    throw new Error(
      `canary capture exited ${r.status}\n${(r.stdout ?? "") + (r.stderr ?? "")}`,
    );
  }
  return r.stdout ?? "";
}

async function main() {
  const opts = parseArgs(process.argv);
  const inContainer = process.env.VD0_IN_CONTAINER === "1";
  const canaryRoot = join(opts.out, "canary");

  // Rendering-path coverage: a canary entry whose view is pending is a
  // rendering path this check does NOT cover, and saying so is the point.
  const uncoveredPaths = CANARY.filter((c) => VIEWS_BY_ID.get(c.view)?.status !== "ready");
  const activePaths = CANARY.filter((c) => VIEWS_BY_ID.get(c.view)?.status === "ready");

  await rm(canaryRoot, { recursive: true, force: true });
  await mkdir(canaryRoot, { recursive: true });

  // Build ONCE, before the first run. Both runs then capture over identical
  // bytes; rebuilding between them would be testing the exporter, not the
  // renderer, and would confound the two failure modes.
  const runDirs = [];
  for (let i = 1; i <= opts.runs; i++) {
    const dir = join(canaryRoot, `run-${i}`);
    await mkdir(dir, { recursive: true });
    if (!opts.json) console.log(`run ${i}/${opts.runs} …`);
    const out = runCapture(dir, { dist: opts.dist, build: opts.build && i === 1 });
    if (!opts.json) process.stdout.write(out.split("\n").filter((l) => l.startsWith("  ")).join("\n") + "\n");
    runDirs.push(dir);
  }

  const hashes = [];
  for (const dir of runDirs) hashes.push(await hashDir(dir));

  const baseline = hashes[0];
  const files = [...baseline.keys()];
  const comparisons = [];
  const mismatches = [];

  if (files.length === 0) {
    mismatches.push({ file: "(none)", reason: "the canary captured no images at all" });
  }

  for (const file of files) {
    const perRun = hashes.map((h) => h.get(file) ?? null);
    const identical = perRun.every((h) => h !== null && h === perRun[0]);
    comparisons.push({ file, identical, hashes: perRun });
    if (!identical) mismatches.push({ file, hashes: perRun });
  }
  // A file that appeared only in a later run is a mismatch too.
  for (let i = 1; i < hashes.length; i++) {
    for (const file of hashes[i].keys()) {
      if (!baseline.has(file))
        mismatches.push({ file, reason: `present in run ${i + 1} but not in run 1` });
    }
  }

  const deterministic = mismatches.length === 0 && files.length > 0;

  const status = {
    check: "verify_canary_capture_is_byte_identical",
    milestone: "VD.0",
    tier: 1,
    generatedAt: new Date().toISOString(),
    deterministic,
    // A host run is not a tier-1 verdict. It is useful while iterating and it
    // catches gross nondeterminism early, but the pinned container is what
    // makes the assertion mean "the product", so an advisory verdict must not
    // be accepted as a tier-1 pass.
    advisory: !inContainer,
    environment: {
      inContainer,
      container: process.env.VD0_CONTAINER_IMAGE ?? null,
      containerDigest: process.env.VD0_CONTAINER_DIGEST ?? null,
      node: process.version,
      platform: process.platform,
      arch: process.arch,
    },
    runs: opts.runs,
    imagesPerRun: files.length,
    comparisons,
    mismatches,
    renderingPaths: {
      covered: activePaths.map((c) => ({
        path: c.renderingPath,
        image: imageName(c.view, c.size, c.theme),
      })),
      uncovered: uncoveredPaths.map((c) => ({
        path: c.renderingPath,
        view: c.view,
        reason: VIEWS_BY_ID.get(c.view)?.pendingReason ?? "view not in the list",
      })),
    },
    // Consumed by require-deterministic.mjs, and by VD.11's perceptual
    // comparison, which must report itself unreliable rather than run and be
    // believed when this is false.
    baselinesUsable: deterministic && inContainer,
  };
  await writeFile(join(canaryRoot, "status.json"), JSON.stringify(status, null, 2) + "\n");

  if (opts.json) {
    console.log(JSON.stringify(status, null, 2));
  } else {
    console.log("");
    console.log(`canary set:       ${CANARY.length} {view, size, theme} triple(s)`);
    console.log(`captured:         ${files.length} image(s) per run, ${opts.runs} runs`);
    console.log(`pinned container: ${inContainer ? (process.env.VD0_CONTAINER_IMAGE ?? "yes") : "NO — this verdict is ADVISORY"}`);
    if (uncoveredPaths.length) {
      console.log(`\nrendering paths NOT covered (${uncoveredPaths.length}):`);
      for (const c of uncoveredPaths) console.log(`  ${c.renderingPath}  ← view "${c.view}" is pending`);
    }
    console.log("");
    for (const c of comparisons) {
      console.log(`  ${c.identical ? "=" : "≠"} ${c.file.padEnd(52)} ${c.hashes[0]?.slice(0, 16) ?? "-"}`);
    }
    console.log("");
    if (deterministic) {
      console.log(
        inContainer
          ? "PASS — verify_canary_capture_is_byte_identical (pinned container)"
          : "PASS (ADVISORY) — byte-identical on this host; not a tier-1 verdict without the pinned container",
      );
    } else {
      console.log(`FAIL — the capture harness is NOT deterministic (${mismatches.length} mismatch(es)):`);
      for (const m of mismatches) console.log(`  ${m.file}: ${m.reason ?? m.hashes.join(" vs ")}`);
      console.log("");
      console.log("Every tier-2 perceptual baseline is now unreliable. Do not raise a");
      console.log("threshold to make this green — investigate what stopped being fixed.");
    }
    console.log(`\nverdict: ${join(canaryRoot, "status.json")}`);
  }

  return deterministic ? 0 : 1;
}

main()
  .then((c) => process.exit(c))
  .catch((e) => {
    console.error(`canary check failed: ${e.message}`);
    process.exit(2);
  });
