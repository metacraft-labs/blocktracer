#!/usr/bin/env node
// VD.0 self-test — runs the milestone's four verifications end to end.
//
//   node tools/capture/selftest.mjs               # host run (canary is advisory)
//   nix run .#capture-env -- node tools/capture/selftest.mjs
//                                                 # pinned environment; a tier-1
//                                                 # verdict on Linux, still
//                                                 # advisory on darwin
//
//   verify_capture_covers_named_view_list
//   verify_canary_capture_is_byte_identical
//   verify_canary_failure_invalidates_the_baselines
//   verify_full_regen_removes_stale_images
//
// Everything runs against a throwaway output directory so a self-test never
// disturbs the working screenshot set.

import { mkdtemp, rm, writeFile, readFile, readdir, mkdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

import { VIEWS, imageName } from "./views.mjs";
import { evaluate } from "./require-deterministic.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");

const results = [];
function record(name, ok, detail) {
  results.push({ name, ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}`);
  if (detail) for (const line of String(detail).split("\n")) console.log(`        ${line}`);
}

function run(script, args, { allowFailure = true } = {}) {
  const r = spawnSync(process.execPath, [join(HERE, script), ...args], { encoding: "utf8" });
  if (!allowFailure && r.status !== 0) {
    throw new Error(`${script} exited ${r.status}\n${r.stdout}${r.stderr}`);
  }
  return { code: r.status, out: (r.stdout ?? "") + (r.stderr ?? "") };
}

async function main() {
  const out = await mkdtemp(join(tmpdir(), "vd0-selftest-"));
  const distArgs = ["--dist", join(REPO_ROOT, "client", "dist")];
  console.log(`self-test output: ${out}\n`);

  try {
    // ── 1. A full regeneration, which is also the fixture for tests 2 and 4 ──
    const regen = run("capture.mjs", ["--out", out, ...distArgs]);
    if (regen.code !== 0) {
      record("capture (full regeneration)", false, regen.out.trim().split("\n").slice(-8).join("\n"));
      return 1;
    }
    const manifest = JSON.parse(await readFile(join(out, "manifest.json"), "utf8"));
    record(
      "capture (full regeneration)",
      manifest.counts.failed === 0 && manifest.counts.captured > 0,
      `${manifest.counts.captured} image(s), ${manifest.counts.pendingViews} view(s) pending`,
    );

    // ── verify_capture_covers_named_view_list ──────────────────────────────
    const cov = run("check-coverage.mjs", ["--out", out]);
    record(
      "verify_capture_covers_named_view_list",
      cov.code === 0,
      cov.code === 0 ? null : cov.out.trim(),
    );

    // ── verify_full_regen_removes_stale_images ────────────────────────────
    // Simulate a rename: an image under a view name the list no longer has.
    const staleName = "home--renamed-away__wide__light.png";
    await writeFile(join(out, staleName), await readFile(join(out, imageName("home", "wide", "light"))));
    const covStale = run("check-coverage.mjs", ["--out", out]);
    const detected = covStale.code !== 0 && covStale.out.includes(staleName);

    const regen2 = run("capture.mjs", ["--out", out, ...distArgs, "--no-build"]);
    const gone = !existsSync(join(out, staleName));
    const covAfter = run("check-coverage.mjs", ["--out", out]);
    record(
      "verify_full_regen_removes_stale_images",
      detected && gone && regen2.code === 0 && covAfter.code === 0,
      [
        `stale image detected by the coverage check: ${detected}`,
        `removed by a full regeneration: ${gone}`,
        `coverage clean afterwards: ${covAfter.code === 0}`,
      ].join("\n"),
    );

    // A targeted run must NOT clean, or an agent iterating on one view would
    // silently destroy the rest of the set.
    const before = (await readdir(out)).filter((f) => f.endsWith(".png")).length;
    run("capture.mjs", ["--out", out, ...distArgs, "--no-build", "--view", "home", "--size", "wide"]);
    const after = (await readdir(out)).filter((f) => f.endsWith(".png")).length;
    record(
      "targeted capture does not clean the output directory",
      before === after && before > 0,
      `${before} image(s) before, ${after} after`,
    );

    // ── verify_canary_capture_is_byte_identical ───────────────────────────
    const canary = run("check-canary.mjs", ["--out", out, ...distArgs, "--no-build"]);
    const status = JSON.parse(await readFile(join(out, "canary", "status.json"), "utf8"));
    record(
      "verify_canary_capture_is_byte_identical",
      canary.code === 0 && status.deterministic === true,
      [
        `${status.imagesPerRun} image(s) x ${status.runs} runs, byte-identical: ${status.deterministic}`,
        status.advisory
          ? `ADVISORY — not a tier-1 verdict: ${(status.advisoryReasons ?? ["(no reason recorded)"]).join(" / ")}`
          : `pinned environment: ${status.environment.pinned?.kind} ${status.environment.pinned?.id ?? ""}`,
        status.renderingPaths.uncovered.length
          ? `rendering paths not covered: ${status.renderingPaths.uncovered.map((p) => p.path).join("; ")}`
          : "every canary rendering path covered",
      ].join("\n"),
    );

    // ── verify_canary_failure_invalidates_the_baselines ───────────────────
    // The gate must refuse in five distinct ways. Collapsing any of them into
    // "pass" is the failure mode this verification exists to catch.
    const now = new Date().toISOString();

    // What check-canary.mjs writes on a genuine tier-1 pass. Everything below
    // is this, with exactly one field spoiled, so each case isolates one
    // condition instead of failing for several reasons at once.
    const coherent = (over = {}) => ({
      deterministic: true,
      advisory: false,
      baselinesUsable: true,
      generatedAt: now,
      runs: 2,
      environment: {
        platform: "linux",
        arch: "x64",
        pinned: { kind: "nix", verified: true, tier1Capable: true, id: "deadbeef", problems: [] },
      },
      ...over,
    });

    const cases = [
      [null, "no-verdict", "no canary has run"],
      [
        { ...coherent(), deterministic: false, baselinesUsable: false, mismatches: [{ file: "x" }] },
        "canary-failed",
        "the canary failed",
      ],
      [
        { ...coherent(), generatedAt: new Date(Date.now() - 72 * 3600_000).toISOString() },
        "stale-verdict",
        "the verdict is too old",
      ],
      [
        { deterministic: true, generatedAt: now, advisory: true, baselinesUsable: false, runs: 2 },
        "advisory-verdict",
        "the canary ran outside the pinned capture environment",
      ],
      // The four incoherent shapes. Each is what a HAND-EDITED verdict looks
      // like: a green field with nothing behind it. A reviewer fabricated
      // exactly the first of these against VD.1's gate, so it is a case here
      // rather than a hope.
      [
        { deterministic: true, advisory: false, baselinesUsable: true, generatedAt: now, runs: 2 },
        "incoherent-verdict",
        "a fabricated non-advisory verdict with no environment.pinned record",
      ],
      [
        { ...coherent(), environment: { container: "pinned" } },
        "incoherent-verdict",
        "a non-advisory verdict whose environment names no pinned record",
      ],
      [
        {
          ...coherent(),
          environment: {
            pinned: { kind: "nix", verified: true, tier1Capable: false, id: "x", problems: [] },
          },
        },
        "incoherent-verdict",
        "a non-advisory verdict over an environment that is not tier-1 capable",
      ],
      [
        {
          ...coherent(),
          environment: {
            pinned: {
              kind: "nix",
              verified: false,
              tier1Capable: true,
              id: "x",
              problems: ["FONTCONFIG_FILE does not match"],
            },
          },
        },
        "incoherent-verdict",
        "a non-advisory verdict over an environment with unresolved problems",
      ],
      [{ ...coherent(), baselinesUsable: false }, "incoherent-verdict", "baselinesUsable disagrees with its own inputs"],
      // The darwin caveat, end to end. Every input is pinned and verified and
      // the capture IS byte-identical — and it is still refused, because the
      // compositor is not something a derivation can fix.
      [
        {
          deterministic: true,
          advisory: true,
          baselinesUsable: false,
          generatedAt: now,
          runs: 2,
          advisoryReasons: ["darwin rasterises through the host compositor"],
          environment: {
            platform: "darwin",
            arch: "arm64",
            pinned: { kind: "nix", verified: true, tier1Capable: false, id: "deadbeef", problems: [] },
          },
        },
        "advisory-verdict",
        "a VERIFIED pinned environment on darwin is still not a tier-1 verdict",
      ],
      // And the one shape that IS accepted.
      [coherent(), "ok", "a coherent pinned-Nix verdict on linux is accepted"],
    ];
    const gateProblems = [];
    for (const [st, expectedCode, label] of cases) {
      const v = evaluate(st, { maxAgeHours: 24 });
      const wantUsable = expectedCode === "ok";
      if (v.code !== expectedCode || v.usable !== wantUsable)
        gateProblems.push(`${label}: expected ${expectedCode}/${wantUsable}, got ${v.code}/${v.usable}`);
    }

    // And end to end, through the real CLI, with a failed verdict on disk.
    const gateDir = join(out, "gate-fixture");
    await mkdir(join(gateDir, "canary"), { recursive: true });
    await writeFile(
      join(gateDir, "canary", "status.json"),
      JSON.stringify({
        deterministic: false,
        advisory: false,
        generatedAt: now,
        runs: 2,
        mismatches: [{ file: "home__wide__light.png", hashes: ["a", "b"] }],
      }),
    );
    const gate = run("require-deterministic.mjs", ["--out", gateDir]);
    if (gate.code === 0) gateProblems.push("the CLI gate accepted a FAILED canary verdict");
    if (!gate.out.includes("BASELINES UNRELIABLE"))
      gateProblems.push("the CLI gate did not report the baselines as unreliable");

    record(
      "verify_canary_failure_invalidates_the_baselines",
      gateProblems.length === 0,
      gateProblems.length
        ? gateProblems.join("\n")
        : `refuses on: no verdict, failed canary, stale verdict, advisory verdict, a VERIFIED pinned environment on darwin, and ${cases.filter(([, c]) => c === "incoherent-verdict").length} incoherent (hand-edited) shapes; accepts a coherent pinned-Nix verdict on linux`,
    );

    // ── Theme axis is captured independently ──────────────────────────────
    const byPair = new Map();
    for (const img of manifest.images.filter((i) => i.ok)) {
      const key = `${img.view}__${img.size}`;
      if (!byPair.has(key)) byPair.set(key, {});
      byPair.get(key)[img.theme] = img.sha256;
    }
    const pairs = [...byPair.entries()].filter(([, v]) => v.light && v.dark);
    const differing = pairs.filter(([, v]) => v.light !== v.dark);
    record(
      "theme axis produces an independent image per theme",
      pairs.length > 0 && pairs.every(([, v]) => v.light && v.dark),
      `${pairs.length} light/dark pair(s); ${differing.length} differ in pixels, ` +
        `${pairs.length - differing.length} identical (the client's token layer is dark-only until VD.2)`,
    );

    // ── Named view list shape ─────────────────────────────────────────────
    record(
      "named view list is complete and every pending view states why",
      VIEWS.every((v) => v.status === "ready" || v.pendingReason),
      `${VIEWS.length} named views: ${VIEWS.filter((v) => v.status === "ready").length} ready, ` +
        `${VIEWS.filter((v) => v.status !== "ready").length} pending`,
    );
  } finally {
    if (!process.env.VD0_KEEP_SELFTEST) await rm(out, { recursive: true, force: true });
  }

  const failed = results.filter((r) => !r.ok);
  console.log("");
  console.log(`${results.length - failed.length}/${results.length} checks passed`);
  return failed.length ? 1 : 0;
}

main()
  .then((c) => process.exit(c))
  .catch((e) => {
    console.error(`self-test failed: ${e.message}`);
    process.exit(2);
  });
