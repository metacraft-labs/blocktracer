#!/usr/bin/env node
// Does the freshness question get asked, and does it decide?
//
//   node tools/capture/build-freshness-selftest.mjs
//   just build-freshness-selftest
//
// ── The defect this stands over ────────────────────────────────────────────
//
// EXISTENCE CHECKED AS FRESHNESS. A guard tests that a path is there —
// `existsSync(dist)`, `fileExists(built)`, `[ -x $binary ]` — and the decision
// made on the answer is "these are the bytes this source produces". Those are
// different sentences. Every artefact this repository builds is written IN
// PLACE into a gitignored directory that nothing cleans, so the gap is not
// theoretical: `.github/workflows/ci.yml` records a run that "fell back to
// capturing whatever was already in client/dist", and every image in it was a
// true photograph of the wrong build.
//
// The tell is almost always in the guard's own words. Each of these sites
// carried a remedy — "build it first", "run without --no-build first", "`just
// capture \"\"` builds both" — that names EXACTLY the condition an existence
// test cannot detect, because once the thing has been built once the test is
// true forever.
//
// `lib/build-freshness.mjs` answers the question. This file asserts two things
// about it, and they fail separately:
//
//   PART 1  THE ANSWER IS RIGHT. Nine arms over synthetic trees, including the
//           three not-fresh answers that are NOT "stale" and must never be
//           reported as if they were — a Nix store path's epoch mtimes, an
//           empty source walk, a tree holding none of the artefacts. A gate
//           that cried wolf on the ordinary hermetic build would be switched
//           off, and then it would not be there for the real case.
//
//   PART 2  THE QUESTION IS ASKED, at every site that decides to reuse,
//           publish or photograph a built artefact. This is the part that rots:
//           a fix lands, the mechanism recurs in a new file, and nothing
//           notices. Each site is named with the guard that used to stand alone
//           there, and each has a NEGATIVE FIXTURE — the pre-fix text,
//           verbatim — so the detector is shown to answer "no" as well as
//           "yes". A coverage check that can only say yes is a list.
//
// ── What Part 2 does NOT prove, stated rather than hidden ──────────────────
//
// It reads source text. It proves the freshness call is present in the block
// that used to decide on existence alone; it does not prove that call's result
// is acted on. Part 1 proves the function decides. The join between them —
// this exact call, on this exact path, changing this exact branch — is checked
// by reading the diff, and by the arms in `capture.mjs`'s own selftest for the
// two sites that have one. Where a site could be driven end-to-end cheaply it
// would be better; `check-coverage.mjs` and `check-hydration-divergence.mjs`
// hard-code `client/dist`, so they cannot be pointed at a synthetic tree
// without a change whose only purpose is this test.

import { execFileSync } from "node:child_process";
import {
  mkdirSync, mkdtempSync, writeFileSync, utimesSync, rmSync, readFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

import { staleness, newestBuildInput, oldestBuiltArtefact, MTIME_FLOOR_MS } from "./lib/build-freshness.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");

let passed = 0;
const failures = [];
const ok = (n, d) => { passed++; console.log(`  PASS  ${n}${d ? ` — ${d}` : ""}`); };
const bad = (n, w) => { failures.push(n); console.log(`  FAIL  ${n}\n        ${w}`); };

const ROOT = mkdtempSync(join(tmpdir(), "build-freshness-selftest-"));
const SEC = 1000;

/** A synthetic pair: a source tree and a built tree, with mtimes we choose. */
function world({ sourceAt, builtAt, artefacts = ["index.html", "assets/hydrate.js"], sources = ["src/a.nim"] }) {
  const w = mkdtempSync(join(ROOT, "w-"));
  const repo = join(w, "repo");
  const built = join(w, "dist");
  for (const rel of sources) {
    const p = join(repo, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, "# source\n");
    if (sourceAt !== undefined) utimesSync(p, sourceAt / SEC, sourceAt / SEC);
  }
  for (const rel of artefacts) {
    const p = join(built, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, "built\n");
    if (builtAt !== undefined) utimesSync(p, builtAt / SEC, builtAt / SEC);
  }
  return { repo, built };
}

const T2020 = Date.UTC(2020, 0, 1);
const T2021 = Date.UTC(2021, 0, 1);

console.log("build-freshness-selftest");
console.log("");
console.log("  ── PART 1: does the freshness question DECIDE? ──");

// 1. A build newer than every source is fresh.
{
  const w = world({ sourceAt: T2020, builtAt: T2021 });
  const s = staleness(w.built, w.repo);
  if (s !== null) bad("a build newer than its sources is fresh", `reported ${s.why}: ${s.message}`);
  else ok("a build newer than its sources is fresh");
}

// 2. A source touched after the build is stale, and the message names both.
{
  const w = world({ sourceAt: T2021, builtAt: T2020 });
  const s = staleness(w.built, w.repo);
  if (s === null) bad("a source touched after the build is stale", "reported fresh");
  else if (s.why !== "stale") bad("a source touched after the build is stale", `reported ${s.why}`);
  else if (!s.message.includes("a.nim") || !s.message.includes("index.html")) {
    bad("a source touched after the build is stale",
      `refused, but the message names neither side: ${s.message}`);
  } else ok("a source touched after the build is stale", "and the message names both files and both times");
}

// 3. EQUAL MTIMES ARE FRESH — the ordinary clean build, and the arm that keeps
//    this gate switched on.
{
  const w = world({ sourceAt: T2021, builtAt: T2021 });
  const s = staleness(w.built, w.repo);
  if (s !== null) bad("a build written in the same second as its last input is fresh", `reported ${s.why}`);
  else ok("a build written in the same second as its last input is fresh");
}

// 4. THE PARTIAL REBUILD. `just export` after `just export-hydrated` leaves a
//    fresh index.html beside a stale assets/hydrate.js, and taking the NEWEST
//    artefact would call that tree current.
{
  const w = world({ sourceAt: T2020, builtAt: T2021 });
  utimesSync(join(w.built, "assets", "hydrate.js"), Date.UTC(2019, 0, 1) / SEC, Date.UTC(2019, 0, 1) / SEC);
  utimesSync(join(w.repo, "src", "a.nim"), T2020 / SEC, T2020 / SEC);
  const s = staleness(w.built, w.repo);
  if (s === null || s.why !== "stale") {
    bad("a partially rebuilt tree is stale", `reported ${s === null ? "fresh" : s.why} — the oldest artefact is the question`);
  } else if (!s.message.includes("hydrate.js")) {
    bad("a partially rebuilt tree is stale", `named ${s.built.path}, not the stale half`);
  } else ok("a partially rebuilt tree is stale", "the OLDEST artefact decides, not the newest");
}

// 5-7. The three answers that are not "stale". Each must be distinguishable,
//      because a caller that printed "stale" for any of them would be lying in
//      the alarming direction.
{
  const w = world({ sourceAt: T2020, builtAt: T2021, artefacts: ["something-else.txt"] });
  const s = staleness(w.built, w.repo);
  if (s?.why !== "no-artefacts") bad("a tree holding none of the artefacts says so", `reported ${s?.why ?? "fresh"}`);
  else ok("a tree holding none of the artefacts says so", `why: "${s.why}"`);
}
{
  // Nix writes every store file with mtime 1. An mtime read there is ABSENT,
  // not old, and `nix build .#default` is a normal thing to point a checker at.
  const w = world({ sourceAt: T2021, builtAt: 1000 });
  const s = staleness(w.built, w.repo);
  if (s?.why !== "no-mtime") {
    bad("a Nix store path is not called stale", `reported ${s?.why ?? "fresh"} — an epoch mtime carries no information`);
  } else ok("a Nix store path is not called stale", `why: "${s.why}", floor ${new Date(MTIME_FLOOR_MS).toISOString().slice(0, 10)}`);
}
{
  const w = world({ sourceAt: T2020, builtAt: T2021, sources: ["src/not-a-source.txt"] });
  const s = staleness(w.built, w.repo);
  if (s?.why !== "no-inputs") bad("an empty source walk says so", `reported ${s?.why ?? "fresh"}`);
  else ok("an empty source walk says so", `why: "${s.why}"`);
}

// 8. OUTPUT IS NOT AN INPUT. `hydrate.js`, `search.js` and `settings.js` live
//    inside the source roots. A walk that counted them would compare a build
//    against itself and could never report stale — the gate would be a mirror.
{
  const w = world({ sourceAt: T2020, builtAt: T2020, sources: ["src/a.nim"] });
  const bundle = join(w.repo, "src", "hydrate.js");
  writeFileSync(bundle, "// output\n");
  utimesSync(bundle, T2021 / SEC, T2021 / SEC);
  const newest = newestBuildInput(w.repo, [["src"]]);
  if (newest === null) bad("a built .js inside a source root is not counted as a source", "found no inputs at all");
  else if (newest.path.endsWith(".js")) {
    bad("a built .js inside a source root is not counted as a source",
      `newest input is ${newest.path} — the gate would compare the build against itself`);
  } else ok("a built .js inside a source root is not counted as a source", `newest is ${newest.path.split("/").pop()}`);
}

// 9. `nimcache` is skipped: it is scratch, it is full of `.nim`, and it is
//    rewritten by every build.
{
  const w = world({ sourceAt: T2020, builtAt: T2020 });
  const scratch = join(w.repo, "src", "nimcache", "x.nim");
  mkdirSync(dirname(scratch), { recursive: true });
  writeFileSync(scratch, "# scratch\n");
  utimesSync(scratch, T2021 / SEC, T2021 / SEC);
  const s = staleness(w.built, w.repo, { roots: [["src"]] });
  if (s !== null) bad("compiler scratch does not make a tree stale", `reported ${s.why}: ${s.message}`);
  else ok("compiler scratch does not make a tree stale");
}

// ── PART 2 ─────────────────────────────────────────────────────────────────
console.log("");
console.log("  ── PART 2: is the question ASKED where the decision is made? ──");

/** Does the block beginning at `anchor` call a freshness function within
 *  `window` lines? The window is generous on purpose: the point is whether the
 *  question is asked in that decision at all, not where exactly. */
const ASKS = /\bstaleness\s*\(|\brequireFreshBundle\s*\(|\bidentityOf\s*\(/;
function asksFreshness(text, anchor, window = 45) {
  const lines = text.split("\n");
  const at = lines.findIndex((l) => l.includes(anchor));
  if (at === -1) return { found: false };
  return { found: true, asks: ASKS.test(lines.slice(Math.max(0, at - window), at + window).join("\n")) };
}

/** Every place that decides whether an already-built artefact may be reused,
 *  published or photographed. Adding a site here is how the next one gets
 *  covered; removing one needs a reason in the commit message. */
const SITES = [
  {
    file: "tools/capture/capture.mjs",
    anchor: "no built site at ${opts.dist}",
    decides: "whether --no-build may photograph client/dist — the tree ALL ~85 graded views come from",
  },
  {
    file: "tools/capture/capture.mjs",
    anchor: "static exporter did not run",
    decides: "whether a FAILED export may be photographed from whatever dist was already there",
  },
  {
    file: "tools/capture/capture.mjs",
    anchor: "`ok: true` IS THE STRONGEST VERDICT",
    decides: "whether --no-build may reuse dist-hydrated for the ~32 live-session views",
  },
  {
    file: "tools/capture/check-hydration-divergence.mjs",
    anchor: "no hydrated build at ${DIST_HYDRATED}",
    decides: "whether H1 may compare two built trees — and write the answer to a COMMITTED json",
  },
  {
    file: "tools/capture/check-hydration-divergence.mjs",
    anchor: "no built bundle at ${BUNDLE}",
    decides: "whether H2 may assert over class literals read out of the built bundle",
  },
  {
    file: "tools/capture/check-coverage.mjs",
    anchor: "no built data plane at ${distDir}",
    decides: "whether assertion E may grade corpus coverage against the built chain registry",
  },
  {
    file: "tools/journeys/lib/engine.mjs",
    // The DECISION, not the declaration. Anchored on `stageEngine` itself
    // rather than on `CACHE_DIRNAME` near the top of the file: `identityOf` is
    // declared at module scope, so a loose anchor would have found its
    // definition and passed over a `stageEngine` that had gone back to
    // `existsSync(dest)`. An anchor that matches a definition instead of a use
    // is the coverage check making the same mistake as the code it grades.
    anchor: "export async function stageEngine(",
    decides: "whether an engine already at the destination counts as staged",
    window: 10,
  },
  {
    file: "client/src/static_export.nim",
    anchor: 'stderr.writeLine "hydration bundle not built: "',
    decides: "whether hydrate.js may be copied into the published site",
    window: 12,
  },
  {
    file: "client/src/static_export.nim",
    anchor: 'stderr.writeLine "search bundle not built: "',
    decides: "whether search.js may be copied into the published site",
    window: 12,
  },
  {
    file: "client/src/static_export.nim",
    anchor: 'stderr.writeLine "settings bundle not built: "',
    decides: "whether settings.js may be copied into the published site",
    window: 12,
  },
];

{
  const silent = [];
  const gone = [];
  for (const s of SITES) {
    const text = readFileSync(join(REPO_ROOT, s.file), "utf8");
    const r = asksFreshness(text, s.anchor, s.window);
    if (!r.found) gone.push(`${s.file}: anchor ${JSON.stringify(s.anchor)} is no longer in the file`);
    else if (!r.asks) silent.push(`${s.file}: decides ${s.decides} — and asks only whether the path exists`);
  }
  if (gone.length) {
    bad("every reuse decision asks whether the artefact is of this source",
      `${gone.length} anchor(s) moved, so this check is measuring nothing:\n        ` + gone.join("\n        ") +
      `\n        Re-anchor them. An anchor that silently stops matching is how a coverage check becomes a list.`);
  } else if (silent.length) {
    bad("every reuse decision asks whether the artefact is of this source",
      `${silent.length} site(s) decide on existence alone:\n        ` + silent.join("\n        "));
  } else {
    ok("every reuse decision asks whether the artefact is of this source", `${SITES.length} sites`);
  }
}

// THE DETECTOR CAN SAY NO. Verbatim pre-fix text from four of the sites above.
// Without this, a detector whose regex silently stopped matching would report
// perfect coverage forever — the same failure the sites themselves have.
{
  const NEGATIVE = [
    ["capture.mjs, before the --no-build dist fix",
      'no built site at ${opts.dist}',
      `  if (opts.build) built = runExporter(opts.dist);\n` +
      `  if (!existsSync(opts.dist)) {\n` +
      `    throw new Error(\`no built site at \${opts.dist} (run the exporter, or pass --dist)\`);\n` +
      `  }\n  const fixture = await digestTree(opts.dist);\n`],
    ["check-hydration-divergence.mjs, before the H1 fix",
      "no hydrated build at ${DIST_HYDRATED}",
      `function measureRoutes() {\n` +
      `  if (!existsSync(DIST)) return { ok: false, reason: \`no plain build at \${DIST}\` };\n` +
      `  if (!existsSync(DIST_HYDRATED)) {\n` +
      `    return { ok: false, reason: \`no hydrated build at \${DIST_HYDRATED}\` };\n  }\n` +
      `  const index = buildEntityIndex(DIST);\n`],
    ["check-coverage.mjs, before the E fix",
      "no built data plane at ${distDir}",
      `  if (!existsSync(join(distDir, "registry", "chains.v1.json"))) {\n` +
      `    report.chains = { status: "not-run", reason: \`no built data plane at \${distDir}\` };\n` +
      `  } else {\n    const ix = buildEntityIndex(distDir);\n`],
    ["static_export.nim, before the bundle fix",
      'stderr.writeLine "hydration bundle not built: "',
      `  if not fileExists(built):\n` +
      `    stderr.writeLine "hydration bundle not built: " & built\n` +
      `    stderr.writeLine "  Build it first (cd client && just hydrate) or drop the define."\n` +
      `    quit 2\n  let dest = OutputDir / HydrationBundle.strip(chars = {'/'})\n`],
  ];
  const missed = [];
  for (const [name, anchor, text] of NEGATIVE) {
    const r = asksFreshness(text, anchor, 12);
    if (!r.found) missed.push(`${name}: the fixture's own anchor did not match — the fixture is wrong, not the code`);
    else if (r.asks) missed.push(`${name}: called existence-only text "fresh-checked"`);
  }
  if (missed.length) {
    bad("the detector answers NO on the pre-fix text", missed.join("; ") +
      " — a coverage check that can only say yes proves nothing");
  } else {
    ok("the detector answers NO on the pre-fix text", `${NEGATIVE.length} verbatim pre-fix fixtures, all reported silent`);
  }
}

// AND THE LIBRARY IS NOT DEAD CODE. `oldestBuiltArtefact` is the one function
// whose behaviour differs from the obvious implementation, so it is exercised
// directly rather than only through `staleness`.
{
  const w = world({ sourceAt: T2020, builtAt: T2021 });
  utimesSync(join(w.built, "assets", "hydrate.js"), T2020 / SEC, T2020 / SEC);
  const o = oldestBuiltArtefact(w.built);
  if (!o || !o.path.endsWith("hydrate.js")) bad("oldestBuiltArtefact takes the oldest", `got ${o?.path ?? "null"}`);
  else ok("oldestBuiltArtefact takes the oldest");
}

rmSync(ROOT, { recursive: true, force: true });

console.log("");
console.log(`arms: ${passed}/${passed + failures.length} passed`);
if (failures.length) {
  console.log(`build-freshness-selftest: FAIL — ${failures.length}: ${failures.join("; ")}`);
  process.exit(1);
}
console.log("build-freshness-selftest: PASS — the freshness question decides, including on the three " +
            "worlds where it must NOT say \"stale\", and every reuse decision in the tree asks it");
