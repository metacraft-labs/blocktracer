#!/usr/bin/env node
// Negative controls for the PINNED CAPTURE ENVIRONMENT detection (VD.0).
//
//   node tools/capture/env-selftest.mjs
//
// lib/pinned-env.mjs decides whether the determinism canary may report a
// TIER-1 verdict. A detector that answers "yes" too easily is worse than no
// detector, because it converts an honest advisory into a green check nobody
// re-examines — so every way of claiming the environment WITHOUT being in it
// has a case here.
//
// Runs on bare Node: no browser, no built site, no /nix/store required. The
// cases are synthetic environments, which is the only way to exercise the
// broken ones — you cannot ask a correct wrapper to lie.
//
// It also asserts the positive: a fully-formed Linux claim IS accepted. A
// selftest that only ever expects refusal passes just as well when the
// detector refuses unconditionally, and that failure has already been made
// once in this campaign.

import { describePinnedEnv } from "./lib/pinned-env.mjs";
import { existsSync, readdirSync, statSync, writeFileSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const results = [];
function check(name, ok, detail) {
  results.push({ name, ok });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}`);
  if (detail) for (const l of String(detail).split("\n")) console.log(`        ${l}`);
}

// The positive control needs store paths that REALLY EXIST, so that the
// "is it on disk" half of the verification is exercised against something that
// is, and so that each negative case below isolates ONE problem instead of
// trailing two irrelevant "does not exist" ones.
//
// Preference order: the environment we are actually running inside (the best
// possible fixture — the real wrapper's own paths), then any two entries of the
// local store.
const STORE = "/nix/store";

// The "Chromium" the fixture claims would launch has to be a file that REALLY
// EXISTS inside the browsers fixture. pinned-env.mjs now checks that, because
// Playwright computes `executablePath()` from PLAYWRIGHT_BROWSERS_PATH without
// touching the disk — so a fixture pointing at a path that is merely
// well-formed would let the positive control assert something no real run can
// produce, and would make the existence check untested.
function anyRealFileUnder(dir, depth = 4) {
  let found = null;
  const walk = (d, left) => {
    if (found || left < 0) return;
    let entries;
    try {
      entries = readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (found) return;
      const p = join(d, e.name);
      try {
        if (e.isFile()) {
          statSync(p);
          found = p;
          return;
        }
        if (e.isDirectory()) walk(p, left - 1);
      } catch {
        /* unreadable; keep looking */
      }
    }
  };
  walk(dir, depth);
  return found;
}

function realStorePaths() {
  const amb = process.env;
  const build = (browsers, fonts, source) => {
    const chromium = anyRealFileUnder(browsers);
    return chromium ? { browsers, fonts, chromium, source } : null;
  };
  if (
    amb.VD0_BROWSERS_PATH?.startsWith(`${STORE}/`) &&
    existsSync(amb.VD0_BROWSERS_PATH) &&
    amb.VD0_FONTS_CONF?.startsWith(`${STORE}/`) &&
    existsSync(amb.VD0_FONTS_CONF)
  ) {
    const s = build(amb.VD0_BROWSERS_PATH, amb.VD0_FONTS_CONF, "the ambient pinned environment");
    if (s) return s;
  }
  try {
    const entries = readdirSync(STORE).filter(
      (e) => !e.startsWith(".") && !e.endsWith(".drv") && !e.endsWith(".lock"),
    );
    // The browsers fixture must be a DIRECTORY with a real file inside it.
    for (const a of entries) {
      const browsers = `${STORE}/${a}`;
      let isDir = false;
      try {
        isDir = statSync(browsers).isDirectory();
      } catch {
        continue;
      }
      if (!isDir) continue;
      const fonts = entries.map((e) => `${STORE}/${e}`).find((p) => p !== browsers);
      const s = fonts && build(browsers, fonts, "arbitrary existing store paths");
      if (s) return s;
    }
  } catch {
    /* no store */
  }
  return null;
}

const store = realStorePaths();

const FIXTURE_ENV_ID = "ef2138af4397";

/**
 * A manifest on disk that AGREES with the fixture, so the identity cross-check
 * has something real to agree with. Written to a temp dir rather than faked in
 * memory, because the check reads a file and the point is to exercise it.
 */
function writeManifest(over = {}) {
  const dir = mkdtempSync(join(tmpdir(), "vd0-env-selftest-"));
  const path = join(dir, "vd0-capture-env.json");
  writeFileSync(
    path,
    JSON.stringify({
      schema: "vd0-capture-env/1",
      id: FIXTURE_ENV_ID,
      browsers: store.browsers,
      fontsConf: store.fonts,
      playwright: pinnedVersion(),
      ...over,
    }),
  );
  return path;
}

const MANIFEST = writeManifest();
/** A manifest whose recorded browsers path is NOT the one being exported. */
const DRIFTED_MANIFEST = writeManifest({ browsers: `${STORE}/0000-a-different-bundle` });

/** A complete, internally consistent `nix` claim. */
function goodEnv(over = {}) {
  const browsers = store.browsers;
  const fonts = store.fonts;
  return {
    VD0_PINNED_ENV: "nix",
    VD0_ENV_ID: FIXTURE_ENV_ID,
    VD0_ENV_MANIFEST: MANIFEST,
    VD0_BROWSERS_PATH: browsers,
    PLAYWRIGHT_BROWSERS_PATH: browsers,
    VD0_FONTS_CONF: fonts,
    FONTCONFIG_FILE: fonts,
    VD0_PLAYWRIGHT_VERSION: pinnedVersion(),
    ...over,
  };
}

// Not a skip. This self-test's whole subject is "are these /nix/store paths
// the ones that will really be used", and without a store there is nothing to
// answer that against — so it fails loudly rather than reporting a green run
// that checked nothing.
if (!store) {
  console.log("FAIL  the pinned-environment controls need a Nix store");
  console.log(`        no usable paths under ${STORE}. This self-test verifies claims ABOUT`);
  console.log("        store paths, so without a store every case would pass vacuously.");
  console.log("        Run it on a machine with Nix, or inside `nix run .#capture-env --`.");
  process.exit(1);
}
console.log(`fixtures: ${store.source}`);
console.log(`  browsers  ${store.browsers}`);
console.log(`  fontsConf ${store.fonts}`);
console.log(`  chromium  ${store.chromium}`);
console.log("");

function pinnedVersion() {
  // The version tools/capture/package.json pins; using it keeps the positive
  // case honest on any checkout instead of hard-coding a number that rots.
  return describePinnedEnv({ env: {}, platform: "linux" }).details.playwrightPinned;
}

// A real file when the fixture's own bundle is being claimed, so the positive
// control passes the existence check for the right reason; a computed path
// otherwise, which is what the cases spoiling the bundle want.
const chromiumIn = (env) =>
  env.VD0_BROWSERS_PATH === store.browsers
    ? store.chromium
    : `${env.VD0_BROWSERS_PATH}/chromium-1228/chrome-linux/chrome`;

function ev(env, platform = "linux", chromiumExecutablePath = undefined) {
  return describePinnedEnv({ env, platform, chromiumExecutablePath });
}

// ── The positive control ────────────────────────────────────────────────────
// Without this, every case below is satisfied by a detector that always says
// no. It needs the npm package installed to check the version agreement, so it
// reports honestly rather than passing when its subject is absent.
{
  const env = goodEnv();
  const e = ev(env, "linux", chromiumIn(env));
  const havePlaywright = e.details.playwrightResolved !== null;
  if (!havePlaywright) {
    check(
      "POSITIVE CONTROL: a complete Linux claim is accepted",
      false,
      "the `playwright` npm package is not installed, so the positive control cannot run.\n" +
        "This is a FAILURE, not a skip: without it every case below would also pass\n" +
        "against a detector that refuses unconditionally. Run `just capture-setup`.",
    );
  } else {
    check(
      "POSITIVE CONTROL: a complete Linux claim is accepted",
      e.tier1Capable === true && e.verified === true && e.problems.length === 0,
      `tier1Capable=${e.tier1Capable} verified=${e.verified} problems=${JSON.stringify(e.problems)}`,
    );
  }
}

// ── The platform caveat ─────────────────────────────────────────────────────
{
  const env = goodEnv();
  const e = ev(env, "darwin", chromiumIn(env));
  check(
    "the SAME complete claim on darwin is verified but NOT tier-1 capable",
    e.verified === true && e.tier1Capable === false && e.why.some((w) => /compositor/i.test(w)),
    `verified=${e.verified} tier1Capable=${e.tier1Capable}\n${e.why.join("\n")}`,
  );
}

// ── Every way of claiming without being in it ───────────────────────────────

const negatives = [
  [
    "a bare host claims nothing",
    {},
    (e) => e.kind === null && e.pinned === false && e.tier1Capable === false,
  ],
  [
    "the bare assertion: VD0_PINNED_ENV=nix and nothing else",
    { VD0_PINNED_ENV: "nix" },
    (e) => e.tier1Capable === false && e.problems.length >= 3,
  ],
  [
    "the retired container variable no longer promotes anything",
    { VD0_IN_CONTAINER: "1", VD0_CONTAINER_IMAGE: "blocktracer-vd0-capture:pw1.62.1" },
    (e) => e.kind === "container" && e.tier1Capable === false && e.problems.length === 1,
  ],
  [
    "a browsers path outside the store",
    goodEnv({ VD0_BROWSERS_PATH: "/opt/browsers", PLAYWRIGHT_BROWSERS_PATH: "/opt/browsers" }),
    (e) => e.tier1Capable === false && e.problems.some((p) => /not a \/nix\/store path/.test(p)),
  ],
  // Each of the next seven spoils exactly ONE field of an otherwise complete
  // claim, and the expected problem count is 1. That is the assertion worth
  // making: a detector that refuses for some other reason, or refuses
  // everything, does not satisfy it.
  [
    "PLAYWRIGHT_BROWSERS_PATH silently pointing elsewhere than the claim",
    goodEnv({ PLAYWRIGHT_BROWSERS_PATH: "/home/ci/.cache/ms-playwright" }),
    (e) =>
      e.tier1Capable === false &&
      e.problems.length === 1 &&
      /PLAYWRIGHT_BROWSERS_PATH .* does not match/.test(e.problems[0]),
  ],
  [
    "FONTCONFIG_FILE unset, so the host font config wins",
    goodEnv({ FONTCONFIG_FILE: undefined }),
    (e) =>
      e.tier1Capable === false &&
      e.problems.length === 1 &&
      /FONTCONFIG_FILE .* does not match/.test(e.problems[0]),
  ],
  [
    "FONTCONFIG_FILE pointing at the host's /etc/fonts",
    goodEnv({ FONTCONFIG_FILE: "/etc/fonts/fonts.conf" }),
    (e) =>
      e.tier1Capable === false &&
      e.problems.length === 1 &&
      /FONTCONFIG_FILE .* does not match/.test(e.problems[0]),
  ],
  [
    "no VD0_ENV_ID — a pinned environment with no recorded identity",
    goodEnv({ VD0_ENV_ID: undefined }),
    (e) =>
      e.tier1Capable === false && e.problems.length === 1 && /VD0_ENV_ID is unset/.test(e.problems[0]),
  ],
  [
    "playwright SKEW: the npm package is not the one the browser bundle is for",
    goodEnv({ VD0_PLAYWRIGHT_VERSION: "9.99.9" }),
    (e) =>
      e.tier1Capable === false && e.problems.length === 1 && /playwright skew/.test(e.problems[0]),
  ],
  [
    "the Chromium that would launch is a host binary, not the pinned one",
    goodEnv(),
    (e) => e.tier1Capable === false && e.problems.length === 1 && /not in the store/.test(e.problems[0]),
    "/usr/bin/chromium",
  ],
  [
    "the Chromium that would launch is in the store but not in the PINNED bundle",
    goodEnv(),
    (e) =>
      e.tier1Capable === false &&
      e.problems.length === 1 &&
      /not inside the pinned bundle/.test(e.problems[0]),
    `${STORE}/9999999999999999999999999999999-some-other-browsers/chromium-1/chrome`,
  ],
  // ── Found while reviewing, and not previously covered ────────────────────
  [
    // `startsWith(browsers)` accepts a SIBLING derivation whose name merely
    // begins with the pinned one's. Containment needs the separator.
    "a sibling store path whose name only BEGINS with the pinned bundle's",
    goodEnv(),
    (e) =>
      e.tier1Capable === false &&
      e.problems.length === 1 &&
      /not inside the pinned bundle/.test(e.problems[0]),
    `${store.browsers}-EVIL/chromium-1228/chrome-linux/chrome`,
  ],
  [
    // Playwright builds `executablePath()` from PLAYWRIGHT_BROWSERS_PATH by
    // string concatenation and never stats it. Without an existence check the
    // whole containment block is a tautology in a real run.
    "the Chromium path is inside the bundle but no such file exists",
    goodEnv(),
    (e) =>
      e.tier1Capable === false &&
      e.problems.length === 1 &&
      /does not exist/.test(e.problems[0]),
    `${store.browsers}/chromium-0000-not-a-real-build/chrome`,
  ],
  [
    // An id with nothing behind it is the same bare assertion
    // VD0_IN_CONTAINER=1 was, one level up.
    "VD0_ENV_ID present but no manifest backs it",
    goodEnv({ VD0_ENV_MANIFEST: undefined }),
    (e) =>
      e.tier1Capable === false &&
      e.problems.length === 1 &&
      /VD0_ENV_MANIFEST is unset/.test(e.problems[0]),
  ],
  [
    // A wrapper whose exported paths have drifted from the manifest whose id
    // it is still advertising: two different environments, one recorded id.
    "the manifest records a different bundle than the one exported",
    goodEnv({ VD0_ENV_MANIFEST: DRIFTED_MANIFEST }),
    (e) =>
      e.tier1Capable === false &&
      e.problems.length === 1 &&
      /manifest disagrees with the exported environment/.test(e.problems[0]),
  ],
];

for (const [name, env, predicate, chromium] of negatives) {
  const e = ev(env, "linux", chromium ?? (env.VD0_BROWSERS_PATH ? chromiumIn(env) : undefined));
  check(name, predicate(e), `tier1Capable=${e.tier1Capable} problems=${JSON.stringify(e.problems, null, 2)}`);
}

const failed = results.filter((r) => !r.ok);
console.log("");
console.log(`${results.length - failed.length}/${results.length} pinned-environment control(s) hold`);
if (failed.length) {
  console.log("");
  console.log("FAILED:");
  for (const f of failed) console.log(`  ${f.name}`);
}
process.exit(failed.length ? 1 : 0);
