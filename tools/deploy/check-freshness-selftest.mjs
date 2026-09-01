#!/usr/bin/env node
// The self-test for `tools/deploy/check-freshness.mjs`.
//
//   node tools/deploy/check-freshness-selftest.mjs
//
// ── The bar ────────────────────────────────────────────────────────────────
//
// EVERY CHECK MUST BE SHOWN TO DECIDE, and shown to decide on ITS OWN case.
// This gate exists because a green deploy was read as proof that the published
// bytes were current, and it was not proof of that — so a green verdict from
// the gate itself is worth exactly what it can be demonstrated to be, and
// nothing more.
//
// Each arm builds a synthetic WORLD — a repository with fixtures, a build
// output, a staged publish tree, and a record of what the engine fetch
// downloaded — runs the real `record` step over it, applies ONE mutation, runs
// the real `verify` step, and asserts:
//
//   1. the world WITHOUT the mutation PASSES. Without this control every
//      failure below is meaningless: a checker that failed unconditionally
//      would score identically on the breaks alone. The control is per-arm,
//      because an arm that adds a second container has a different clean state
//      from the base world and it is THAT state which must be green.
//   2. the world WITH the mutation FAILS, on a non-zero exit.
//   3. the check that goes red is THE ONE WRITTEN FOR THAT MUTATION, matched
//      on the check id. Exit code alone would let F0 stand in for F1's work.
//   4. where it matters, that the OTHER checks stay green — a mutation caught
//      by two checks has not shown either of them to be the one that works.
//
// ── The arms that assert a PASS are not filler ─────────────────────────────
//
// Three arms change the world and require the gate to STAY GREEN. They are the
// judgement calls this file encodes, and each of them is a deploy that must
// not break:
//
//   * a NEW replay engine (arm 6). The engine is another repository's build.
//     A gate that reddened on a legitimate CodeTracer release would be
//     switched off within a week, and the deploy workflow's own engine step
//     declined to assert anything for exactly that reason. F3 must catch a
//     STALE engine and wave a NEW one through, and the only way to know it
//     does is to hand it a new one.
//   * a NEW capture (arm 9). Freezing applies to what was frozen. Adding a
//     container is not changing one.
//   * an engine that drifted a few KB (arm 11). F5 asserts the sentence the
//     page shows a visitor, not the constant behind it.
//
// They are `setup`, not mutations: their clean state IS the state under test,
// so the control and the assertion are the same run, and the arm passes only
// if the gate is green over a legitimately-changed world.
//
// ── The arm that is the whole point ────────────────────────────────────────
//
// Arm 2 is the incident, reduced to a fixture: the manifest is recorded from a
// build, and the tree that is about to be uploaded carries the PREVIOUS
// build's bundle under the same name, at a plausible size, referenced by a
// page that resolves. Every check in `check-assets.mjs` is green on that tree.
// F1 is not.

import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

import { approxMegabytes, declaredEngineBytes } from "./check-freshness.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const CHECKER = join(HERE, "check-freshness.mjs");

const sha256 = (b) => createHash("sha256").update(b).digest("hex");

// ── The synthetic world ────────────────────────────────────────────────────
//
// Sizes are ~1.6 MB rather than the real 18 MB so the arms run in seconds. The
// only place absolute size matters is F5, which compares RENDERED megabytes,
// and 1_600_000 renders "2 MB" exactly as 18_284_951 renders "18 MB" — the
// arithmetic under test is scale-free. Arm 12 pins the real numbers separately.
const WASM_BYTES = 1_600_000;
const DECLARED = 1_590_000;          // renders "2 MB", same as WASM_BYTES
const wasmBody = (tag) => "\0asm\x01\0\0\0" + tag.padEnd(WASM_BYTES - 8, "x");

const CONTAINER = "t/mk/kx/mkkxsjcmx6uk3l5d76rg2gie3n/trace.ct";
const FIXTURE = "fixtures/trace/tour/loops/tour_loops.ct";
const CT_BODY = "CTFMT0\0the frozen capture\n";

const DEBUG_SHELL = "aztec/tx/0xabc123/debug/index.html";

const baseWorld = () => ({
  // Committed captures, the source of truth for the FROZEN class.
  fixtures: { [FIXTURE]: CT_BODY },
  // `nix build .#default` output — the BUILT class, and what "this commit
  // builds" means.
  built: {
    "index.html": `<!doctype html><html><body><a href="/aztec">chain</a></body></html>`,
    "assets/hydrate.js": "/* bundle built from THIS commit */\n" + "y".repeat(4096),
    [DEBUG_SHELL]:
      `<!doctype html><html><body>` +
      `<div class="dbg" data-replay-engine="/replay-engine/" data-trace="/${CONTAINER}"></div>` +
      `<script src="/assets/hydrate.js" defer></script></body></html>`,
    [CONTAINER]: CT_BODY,
  },
  // What `fetch-engine.sh` copied to this origin — the VENDORED class.
  engine: {
    "worker.js": "export const worker = 1\n",
    "pkg/db_backend.js": "export const db = 1\n",
    "pkg/db_backend_bg.wasm": wasmBody("ENGINE-A"),
  },
  declared: DECLARED,
  // Engine files that are STAGED but that `fetch-engine.sh` did not record.
  // The only way to express "the engine directory holds something this run's
  // fetch did not put there", which is what a leftover from a previous run on
  // a reused workspace looks like.
  unfetchedEngine: {},
});

/** Lay a world out on disk: a repo root with fixtures + the Nim source, a
 *  `built/` tree, and a `staged/` tree that is `built/` plus the engine —
 *  which is exactly what `cp -rL result site && fetch-engine.sh` produces. */
function materialise(world) {
  const root = mkdtempSync(join(tmpdir(), "check-freshness-selftest-"));
  const put = (p, body) => {
    const target = join(root, p);
    mkdirSync(dirname(target), { recursive: true });
    writeFileSync(target, body);
  };

  for (const [rel, body] of Object.entries(world.fixtures)) put(join("repo", rel), body);
  put(join("repo", "client", "src", "debugger", "replay_engine.nim"),
      `const ReplayEngineWasmBytes* = ${String(world.declared).replace(/\B(?=(\d{3})+(?!\d))/g, "_")}\n`);

  for (const [rel, body] of Object.entries(world.built)) {
    put(join("built", rel), body);
    put(join("staged", rel), body);
  }
  for (const [rel, body] of Object.entries(world.engine)) {
    put(join("staged", "replay-engine", rel), body);
  }
  for (const [rel, body] of Object.entries(world.unfetchedEngine ?? {})) {
    put(join("staged", "replay-engine", rel), body);
  }

  // The fetch manifest `fetch-engine.sh` writes. Recorded from the SAME bytes
  // that were staged, because that is what "this run fetched it" means.
  const files = {};
  for (const [rel, body] of Object.entries(world.engine)) {
    files[rel] = { sha256: sha256(Buffer.from(body, "binary")), bytes: Buffer.byteLength(body, "binary") };
  }
  put("engine-fetch.json", JSON.stringify({
    origin: "https://web-codetracer.pages.dev",
    fetchedAt: "2026-09-01T07:34:41Z",
    runId: "selftest",
    runAttempt: "1",
    files,
  }, null, 2));

  return root;
}

const paths = (root) => ({
  repo: join(root, "repo"),
  built: join(root, "built"),
  staged: join(root, "staged"),
  fetch: join(root, "engine-fetch.json"),
  manifest: join(root, "freshness.json"),
});

/** Run the real checker as a subprocess.
 *
 *  ASYNCHRONOUSLY, and that is not a style preference. The origin arms serve
 *  `staged/` from an HTTP server in THIS process while the checker fetches
 *  from it in a child. `spawnSync` blocks this process's event loop, so the
 *  server can never answer and the arm deadlocks rather than failing — which
 *  is what the first draft did, and a check that hangs reports nothing at all.
 *
 *  A subprocess rather than an import, for the reason check-assets-selftest
 *  gives: the exit code is half of what CI reads, and an in-process call
 *  cannot observe it. */
function runNode(args) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, args, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    child.stdout.on("data", (d) => { out += d; });
    child.stderr.on("data", (d) => { out += d; });
    child.on("close", (code) => resolve({ code, out }));
  });
}

function doRecord(root) {
  const p = paths(root);
  return runNode([CHECKER, "record",
    "--built", p.built, "--staged", p.staged,
    "--engine-fetch", p.fetch, "--repo-root", p.repo, "--out", p.manifest]);
}

async function doVerify(root, extra) {
  const p = paths(root);
  const r = await runNode([CHECKER, "verify", "--manifest", p.manifest, ...extra]);
  const verdicts = new Map();
  for (const m of r.out.matchAll(/^ {2}(F\d\w*)\s+(PASS|FAIL|NOT REQUIRED)  /gm)) verdicts.set(m[1], m[2]);
  const overall = /^check-freshness: PASS/m.test(r.out) ? "PASS"
    : /^check-freshness: FAIL/m.test(r.out) ? "FAIL" : "(no verdict line)";
  return { ...r, verdicts, overall };
}

/** Serve a directory over HTTP, for the arms that verify against an origin.
 *
 *  `Connection: close` and `closeAllConnections()` are not tidiness: the
 *  checker fetches with undici, which keeps the socket alive, and a plain
 *  `server.close()` then waits for a connection that will never be released.
 *  The first draft of this file hung here rather than failing, which is its own
 *  small lesson about a check that cannot report. */
async function withOrigin(dir, fn) {
  const server = createServer((req, res) => {
    const rel = decodeURIComponent(req.url.split("?")[0]).replace(/^\/+/, "");
    const p = join(dir, rel);
    res.setHeader("Connection", "close");
    if (!p.startsWith(dir) || !existsSync(p)) { res.statusCode = 404; return res.end("no"); }
    res.statusCode = 200;
    res.end(readFileSync(p));
  });
  server.keepAliveTimeout = 1;
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  try {
    return await fn(`http://127.0.0.1:${server.address().port}`);
  } finally {
    server.closeAllConnections?.();
    await new Promise((r) => server.close(r));
  }
}

// ── The arms ───────────────────────────────────────────────────────────────
//
// setup         CLEAN additions this arm needs. The control runs on this, and
//               it must PASS. Separated from the mutations below because an
//               arm whose setup is its mutation has no control — the first
//               draft of this file made exactly that mistake and three arms
//               reported "control did not pass", which is the harness catching
//               its own author.
// mutateWorld   the single defect, applied BEFORE the manifest is recorded —
//               the shape a defect in the BUILD or the FIXTURES takes.
// mutateStaged  the single defect, applied AFTER the manifest is recorded —
//               the shape a defect in the PUBLISH takes, which is this file's
//               subject. Receives the laid-out root.
// expect        the check id that must go red. Absent → the arm asserts a PASS.
// also          per-check verdicts the decisive run must ALSO show.
// origin        run verify against an HTTP origin serving `staged/` instead of
//               against the directory.

const arms = [
  {
    name: "1  control — a clean world passes every check",
    also: { F0: "PASS", F1: "PASS", F2: "PASS", F3: "PASS", F4: "PASS", F5: "PASS" },
  },

  {
    // ── THE INCIDENT, AS A FIXTURE ──────────────────────────────────────────
    // The manifest is recorded from this commit's build. The tree about to be
    // uploaded carries the PREVIOUS build's bundle: same name, plausible size,
    // referenced by a page whose reference resolves. check-assets.mjs is green
    // on this tree in every one of A1–A5. F1 is the only thing that is not.
    name: "2  F1 — the staged bundle is a PREVIOUS build's, under the right name",
    mutateStaged: (root) => {
      writeFileSync(join(root, "staged", "assets", "hydrate.js"),
        "/* bundle built from an EARLIER commit */\n" + "y".repeat(3900));
    },
    expect: "F1",
    // F2 must stay green: the file is accounted for, it is simply the wrong
    // bytes. "Unaccounted" and "stale" are different defects and must not
    // collapse into one finding.
    also: { F2: "PASS", F3: "PASS", F4: "PASS" },
  },
  {
    name: "3  F1 — a built artefact is ABSENT from the staged tree",
    mutateStaged: (root) => rmSync(join(root, "staged", "assets", "hydrate.js")),
    expect: "F1",
  },

  {
    name: "4  F2 — the staged tree carries a file no step in this deploy produced",
    mutateStaged: (root) => {
      writeFileSync(join(root, "staged", "assets", "hydrate.js.orig"),
        "/* a leftover from a previous run on a dirty workspace */\n");
    },
    expect: "F2",
    // The leftover is not one of the manifest's artefacts, so F1 cannot see it
    // — that asymmetry is why F2 exists as a separate check.
    also: { F1: "PASS", F3: "PASS" },
  },

  {
    // A STALE engine: the staged bytes are not the bytes this run fetched.
    // This is the engine half of the reported divergence, made assertable.
    name: "5  F3 — the staged engine is NOT the bytes this run fetched (stale)",
    mutateStaged: (root) => {
      writeFileSync(join(root, "staged", "replay-engine", "pkg", "db_backend_bg.wasm"),
        wasmBody("ENGINE-OLD"), "binary");
    },
    expect: "F3",
    also: { F1: "PASS", F2: "PASS" },
  },
  {
    // ── THE JUDGEMENT ARM ───────────────────────────────────────────────────
    // A NEW engine: different bytes AND a fetch manifest that records them,
    // which is what an unrelated CodeTracer release actually looks like. The
    // gate must stay GREEN. A version pin here would redden, and the deploy
    // workflow's engine step was right to refuse one.
    name: "6  F3 — a NEW engine from upstream passes (no opinion about version)",
    setup: (w) => { w.engine["pkg/db_backend_bg.wasm"] = wasmBody("ENGINE-B-NEWER"); return w; },
    also: { F3: "PASS", F5: "PASS" },
  },
  {
    // The engine directory holding a file this run's fetch did not put there.
    // Staged BEFORE the manifest is recorded, so it is a recorded vendored
    // artefact — which is what makes this F3's count assertion rather than
    // F2's unaccounted-file one. Both fire, and the arm says so: a mutation
    // caught only by its neighbour has not shown F3's count to do anything.
    name: "7  F3 — the engine holds a file this run's fetch did not produce",
    mutateWorld: (w) => { w.unfetchedEngine["pkg/leftover.js"] = "export const old = 1\n"; return w; },
    expect: "F3",
    // F2 stays green precisely BECAUSE the leftover was staged before the
    // manifest was recorded: it is an accounted-for artefact that the fetch
    // did not produce, which only F3 can say.
    also: { F1: "PASS", F2: "PASS", F4: "PASS" },
  },

  {
    name: "8  F4 — a published container is NOT the capture that was frozen",
    mutateWorld: (w) => { w.built[CONTAINER] = "CTFMT0\0a DIFFERENT recording\n"; return w; },
    expect: "F4",
    // The changed container is still exactly what the build produced, so F1 is
    // green: this is a defect only the immutability rule can see.
    also: { F1: "PASS", F2: "PASS", F3: "PASS" },
  },
  {
    // Freezing applies to what was frozen. A new capture is a new file, and
    // the gate must not demand a manifest edit for one.
    name: "9  F4 — a NEW capture, committed as a fixture, passes",
    setup: (w) => {
      const body = "CTFMT0\0a second frozen capture\n";
      w.fixtures["client/fixtures/chain/aztec/ct/0xfeed.ct"] = body;
      w.built["t/aa/bb/aabbsecondcapture0000000000/trace.ct"] = body;
      return w;
    },
    also: { F4: "PASS" },
  },
  {
    // The fixture roots exist and the tree publishes no container. F4 must
    // report NOT REQUIRED rather than either verdict: there is nothing for an
    // immutability rule to be true of, and a green tick there would sit next
    // to the class in the very deploy that lost it. A3 owns that half.
    name: "9b F4 — a publish with no containers is NOT REQUIRED, never a pass",
    setup: (w) => { delete w.built[CONTAINER]; return w; },
    also: { F4: "NOT REQUIRED" },
  },
  {
    // And the failure that shape must NOT swallow: containers are published
    // and the fixture roots yield nothing to hold them to.
    name: "9c F4 — containers are published and no committed capture exists",
    mutateWorld: (w) => { w.fixtures = {}; return w; },
    expect: "F4",
  },

  {
    name: "10 F5 — the page shows a visitor a megabyte figure that is not true",
    mutateWorld: (w) => { w.declared = 2_600_000; return w; },   // "3 MB" vs "2 MB"
    expect: "F5",
    also: { F1: "PASS", F3: "PASS" },
  },
  {
    // The tolerance the deploy workflow's comment asked for, made explicit: a
    // few KB of upstream drift changes no rendered text and must not fail.
    name: "11 F5 — a few KB of engine drift changes no rendered text and passes",
    setup: (w) => { w.declared = DECLARED - 9_000; return w; },
    also: { F5: "PASS" },
  },

  {
    name: "12 F0 — the manifest records no hydration bundle at all",
    mutateWorld: (w) => { delete w.built["assets/hydrate.js"]; return w; },
    expect: "F0",
  },
  {
    // F0's other half: a manifest whose declared counts disagree with what it
    // contains cannot be the standard anything else is held to.
    name: "12b F0 — the manifest's own counts disagree with its artefact list",
    mutateStaged: (root) => {
      const p = join(root, "freshness.json");
      const m = JSON.parse(readFileSync(p, "utf8"));
      m.counts.built += 7;
      writeFileSync(p, JSON.stringify(m, null, 2));
    },
    expect: "F0",
  },

  {
    // Post-deploy, and the check nothing in this repository performed before:
    // the upload reported success and the origin serves a previous build.
    name: "13 F6 — the ORIGIN serves a bundle this run did not publish",
    origin: true,
    mutateStaged: (root) => {
      writeFileSync(join(root, "staged", "assets", "hydrate.js"),
        "/* what the origin actually serves: an EARLIER build */\n" + "y".repeat(3900));
    },
    expect: "F6",
    also: { F6b: "PASS" },
  },
  {
    name: "14 F6 — the origin does not serve a critical artefact at all",
    origin: true,
    mutateStaged: (root) => rmSync(join(root, "staged", "replay-engine", "pkg", "db_backend_bg.wasm")),
    expect: "F6",
  },
  {
    name: "15 F6 — control: an origin serving exactly what was published passes",
    origin: true,
    also: { F6: "PASS", F6b: "PASS" },
  },
  {
    // F6 over a critical set that lost the bundle is "all N match", green, and
    // about nothing. F6b is what makes F6's count mean something.
    name: "16 F6b — the critical set no longer names the hydration bundle",
    origin: true,
    mutateStaged: (root) => {
      const p = join(root, "freshness.json");
      const m = JSON.parse(readFileSync(p, "utf8"));
      m.critical = m.critical.filter((r) => r !== "assets/hydrate.js");
      writeFileSync(p, JSON.stringify(m, null, 2));
    },
    expect: "F6b",
    // The remaining entries still match, so F6 is green — which is precisely
    // the green verdict about nothing that F6b exists to refuse.
    also: { F6: "PASS" },
  },
];

// ── Drive them ─────────────────────────────────────────────────────────────

let passed = 0;
const failures = [];
const indent = (t) => t.trimEnd().split("\n").map((l) => `          | ${l}`).join("\n");

for (const arm of arms) {
  const problems = [];
  // The arm's CLEAN state: its setup, and nothing else. The mutations are
  // applied on top of this, never folded into it — that separation is what
  // makes the control a control.
  const cleanWorld = () => (arm.setup ?? ((w) => w))(baseWorld()) ?? baseWorld();

  /** @param mutateWorld before `record`; @param mutateStaged after it. */
  const runOnce = async (mutateWorld, mutateStaged) => {
    const world = mutateWorld ? (mutateWorld(cleanWorld()) ?? cleanWorld()) : cleanWorld();
    const root = materialise(world);
    try {
      const rec = await doRecord(root);
      if (rec.code !== 0) return { fatal: `record failed (exit ${rec.code})\n${indent(rec.out)}` };
      if (mutateStaged) mutateStaged(root);
      if (arm.origin) {
        return await withOrigin(join(root, "staged"), (url) => doVerify(root, ["--origin", url]));
      }
      return await doVerify(root, ["--dir", join(root, "staged")]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  };

  // The control: this arm's own clean state, with neither mutation.
  const clean = await runOnce(null, null);
  if (clean.fatal) {
    problems.push(`control could not run: ${clean.fatal}`);
  } else if (clean.code !== 0 || clean.overall !== "PASS") {
    problems.push(
      `control did not pass (exit ${clean.code}, verdict ${clean.overall}); ` +
      `every assertion below would be meaningless\n${indent(clean.out)}`);
  }

  // The decisive run: the control itself for a pass-arm, the mutated world for
  // a fail-arm. `also` is asserted on whichever of the two the arm is about.
  let decisive = clean;
  if (arm.expect) {
    if (!arm.mutateWorld && !arm.mutateStaged) {
      problems.push(`arm expects ${arm.expect} to fail but defines no mutation`);
    } else {
      decisive = await runOnce(arm.mutateWorld, arm.mutateStaged);
      if (decisive.fatal) {
        problems.push(`mutated run could not run: ${decisive.fatal}`);
      } else {
        if (decisive.code === 0 || decisive.overall !== "FAIL") {
          problems.push(
            `mutation did not turn the gate red (exit ${decisive.code}, ` +
            `verdict ${decisive.overall})\n${indent(decisive.out)}`);
        }
        const got = decisive.verdicts.get(arm.expect);
        if (got !== "FAIL") {
          problems.push(
            `${arm.expect} was "${got ?? "(not reported)"}", expected FAIL — the check written ` +
            `for this mutation is not the one that decided\n${indent(decisive.out)}`);
        }
      }
    }
  }

  if (!decisive.fatal) {
    for (const [id, want] of Object.entries(arm.also ?? {})) {
      const v = decisive.verdicts.get(id);
      if (v !== want) {
        problems.push(`${id} was "${v ?? "(not reported)"}", expected ${want}\n${indent(decisive.out)}`);
      }
    }
  }

  if (problems.length === 0) {
    passed++;
    console.log(`  PASS  ${arm.name}`);
  } else {
    failures.push(arm.name);
    console.log(`  FAIL  ${arm.name}`);
    for (const p of problems) console.log(`        ${p}`);
  }
}

// ── The mirror, pinned to the numbers this repository has actually shipped ──
//
// `approxMegabytes` is reimplemented in JS because this file cannot run Nim,
// and a mirror without a test is two implementations waiting to disagree.
// These four numbers are real: the constant in replay_engine.nim, the engine
// blocktracer.org served on 2026-09-01, the engine web-codetracer published
// that morning, and the older build the constant replaced.
const mirror = [
  [18_281_361, "18 MB", "ReplayEngineWasmBytes, as committed"],
  [18_284_951, "18 MB", "the engine blocktracer.org served on 2026-09-01"],
  [18_285_036, "18 MB", "the engine web-codetracer published at 08:27:55Z that day"],
  [18_094_114, "18 MB", "the build the constant replaced"],
  [2_600_000, "3 MB", "rounds up"],
  [1_600_000, "2 MB", "rounds up"],
  [1_400_000, "1 MB", "rounds down"],
];
let mirrorOk = 0;
for (const [bytes, want, why] of mirror) {
  const got = approxMegabytes(bytes);
  if (got === want) { mirrorOk++; continue; }
  failures.push(`approxMegabytes(${bytes})`);
  console.log(`  FAIL  approxMegabytes(${bytes}) = "${got}", expected "${want}" — ${why}`);
}
if (mirrorOk === mirror.length) {
  console.log(`  PASS  approxMegabytes mirrors the Nim, on ${mirror.length} pinned values ` +
              `(three of them the real engine sizes this incident turned on)`);
}

// And the reader that finds the constant, since F5 is worth nothing if it
// silently reads `null` out of a source whose spelling moved.
const parsed = declaredEngineBytes("const ReplayEngineWasmBytes* = 18_281_361\n");
if (parsed !== 18_281_361) {
  failures.push("declaredEngineBytes");
  console.log(`  FAIL  declaredEngineBytes read ${parsed}, expected 18281361 — F5 would report ` +
              `NOT REQUIRED over a source it simply failed to parse`);
} else if (declaredEngineBytes("nothing here") !== null) {
  failures.push("declaredEngineBytes");
  console.log(`  FAIL  declaredEngineBytes invented a number for a source with no constant`);
} else {
  console.log(`  PASS  declaredEngineBytes reads the constant, and returns null rather than a ` +
              `number when it is absent`);
}

console.log("");
console.log(`arms: ${passed}/${arms.length} passed, plus ${mirror.length + 2} pinned assertions`);
if (failures.length) {
  console.log(`check-freshness-selftest: FAIL — ${failures.length}: ${failures.join("; ")}`);
  process.exit(1);
}
console.log("check-freshness-selftest: PASS — every check in check-freshness.mjs was shown to decide, " +
            "and the three deploys that must NOT break were shown to stay green");
