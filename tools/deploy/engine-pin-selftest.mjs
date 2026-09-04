#!/usr/bin/env node
// Does the engine pin bite?
//
//   node tools/deploy/engine-pin-selftest.mjs
//   just engine-pin-check
//
// ── The defect this gate stands over ───────────────────────────────────────
//
// `client/hydrate/fetch-engine.sh` copies an 18 MB artefact built by ANOTHER
// repository into this one's publish directory. Until 2026-09-05 it fetched
// three fixed paths from the `web-codetracer` Pages project ROOT — which
// always serves that project's CURRENT PRODUCTION DEPLOYMENT — and then
// RECORDED their sha256s into a manifest.
//
// Both halves failed in the same direction. The paths named "the latest
// engine" rather than an engine, so two agents fetching an hour apart on
// 2026-09-04 received `e63dd40a…`/18,117,700 bytes and `22acb8e1…`/18,117,658
// bytes and neither was wrong; and the hash block DOCUMENTED that drift rather
// than preventing it, which is exactly why nobody noticed. A third number,
// `ReplayEngineWasmBytes = 18_281_361` in `client/src/debugger/replay_engine.nim`,
// disagreed with both. Three places believed three different things about one
// artefact.
//
// So this file asserts two separate properties, because they fail separately:
//
//   THE FETCH IS A CHECK, NOT A NOTE.  Arms 1-9 run the real
//   `fetch-engine.sh` against a synthetic origin over `file://` and demand it
//   REFUSE every world in which the bytes are not the pinned ones — a changed
//   wasm, a changed worker, a content-addressed path that 404s because the
//   publisher moved on, a truncated transfer, and four malformed pins. The
//   honest world must still pass, because a gate that reddens on a normal
//   deploy is a gate that gets switched off.
//
//   THE THREE PLACES AGREE.  Arms R1-R5 read the REAL `engine-pin.txt`, the
//   REAL Nim constant and the REAL deploy workflow, and assert they describe
//   one artefact. R3 is the one that was red when this file was written: it
//   reported `ReplayEngineWasmBytes = 18281361` against a pinned wasm of
//   18117658 bytes, naming both numbers.
//
// ── Offline, and deliberately so ───────────────────────────────────────────
//
// Nothing here reaches the network. The synthetic origin is a temp directory
// and `curl` reads it over `file://`, which exercises the same code path as an
// https base. A gate that needs the publisher to be up to prove it can fail is
// a gate that gets skipped — the reason `deploy-gates` exists as a
// GitHub-hosted job in the first place.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdirSync, mkdtempSync, readFileSync, writeFileSync, existsSync, rmSync, readdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const FETCH = join(REPO_ROOT, "client", "hydrate", "fetch-engine.sh");
const REAL_PIN = join(REPO_ROOT, "client", "hydrate", "engine-pin.txt");
const NIM_SOURCE = join(REPO_ROOT, "client", "src", "debugger", "replay_engine.nim");
const DEPLOY_WORKFLOW = join(REPO_ROOT, ".github", "workflows", "deploy-cloudflare-pages.yml");

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

let passed = 0;
const failures = [];
const ok = (name, detail) => { passed++; console.log(`  PASS  ${name}${detail ? ` — ${detail}` : ""}`); };
const bad = (name, why) => { failures.push(name); console.log(`  FAIL  ${name}\n        ${why}`); };

// ───────────────────────────── the synthetic world ─────────────────────────
//
// A wasm over 1 MB carrying the real magic, because `fetch-engine.sh` gives
// two SPECIFIC diagnoses (too small; not wasm) ahead of the hash check and an
// arm aimed at the hash must not be answered by one of those instead.
function makeWasm(fill) {
  const buf = Buffer.alloc(1_200_000, fill);
  buf[0] = 0x00; buf[1] = 0x61; buf[2] = 0x73; buf[3] = 0x6d;
  buf[4] = 0x01; buf[5] = 0x00; buf[6] = 0x00; buf[7] = 0x00;
  return buf;
}

const WORKER = Buffer.from("// synthetic worker.js\nimport './pkg/db_backend.js';\n");
const GLUE = Buffer.from("// synthetic db_backend.js\nexport default 1;\n");
const WASM = makeWasm(0x41);

/** A synthetic origin plus the pin that names it. Content-addressed names are
 *  built the way the publisher builds them: first 16 hex of the sha256. */
function world(root) {
  const origin = join(root, "origin");
  mkdirSync(join(origin, "assets"), { recursive: true });

  const glueName = `assets/db_backend.${sha256(GLUE).slice(0, 16)}.js`;
  const wasmName = `assets/db_backend_bg.${sha256(WASM).slice(0, 16)}.wasm`;

  writeFileSync(join(origin, "worker.js"), WORKER);
  writeFileSync(join(origin, glueName), GLUE);
  writeFileSync(join(origin, wasmName), WASM);

  const pin = join(root, "engine-pin.txt");
  writeFileSync(pin, [
    "# synthetic pin, written by engine-pin-selftest.mjs",
    "# measured     never, these are synthetic bytes",
    "",
    `worker.js               worker.js     ${sha256(WORKER)}  ${WORKER.length}  mutable`,
    `pkg/db_backend.js       ${glueName}   ${sha256(GLUE)}  ${GLUE.length}  immutable`,
    `pkg/db_backend_bg.wasm  ${wasmName}   ${sha256(WASM)}  ${WASM.length}  immutable`,
    "",
  ].join("\n"));

  return { origin, pin, glueName, wasmName };
}

/** Run the real script against a `file://` base. Never throws: the arms are
 *  about the exit code and the message, and a thrown ExecException would hide
 *  both behind a stack. */
function runFetch({ origin, pin, dest }) {
  try {
    const out = execFileSync("bash", [FETCH, dest, `file://${origin}`], {
      env: { ...process.env, REPLAY_ENGINE_PIN: pin },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
    });
    return { code: 0, out, err: "" };
  } catch (e) {
    return { code: e.status ?? -1, out: e.stdout?.toString() ?? "", err: e.stderr?.toString() ?? "" };
  }
}

/** An arm that must REFUSE. Asserts the exit code, that the message names
 *  every phrase the arm was written to see, and that no half-copy survives. */
function mustRefuse(name, { origin, pin, dest }, phrases) {
  const r = runFetch({ origin, pin, dest });
  if (r.code === 0) {
    bad(name, `fetch-engine.sh exited 0 and copied the engine anyway.\n${indent(r.out)}`);
    return;
  }
  const said = `${r.out}\n${r.err}`;
  const missing = phrases.filter((p) => !said.includes(p));
  if (missing.length) {
    bad(name, `refused (exit ${r.code}) but never said ${missing.map((m) => JSON.stringify(m)).join(", ")}.\n` +
      `A refusal a reader cannot act on is half a check.\n${indent(said)}`);
    return;
  }
  if (existsSync(dest) && readdirSync(dest).length > 0) {
    bad(name, `refused, but left ${dest} holding ${readdirSync(dest).join(", ")} — ` +
      `a half-copied engine constructs a worker that fails on an import.`);
    return;
  }
  ok(name, `exit ${r.code}, and the message names it`);
}

const ROOT = mkdtempSync(join(tmpdir(), "engine-pin-selftest-"));
const indent = (s) => (s ?? "").trimEnd().split("\n").map((l) => `        | ${l}`).join("\n");
let arm = 0;
const nextDest = () => join(ROOT, `dest-${++arm}`);

console.log("engine-pin-selftest: does the pin refuse the worlds it exists to refuse?");
console.log("");

// ── 1. the honest world still passes ───────────────────────────────────────
{
  const w = world(mkdtempSync(join(ROOT, "w1-")));
  const dest = nextDest();
  const r = runFetch({ ...w, dest });
  const files = ["worker.js", "pkg/db_backend.js", "pkg/db_backend_bg.wasm"];
  if (r.code !== 0) {
    bad("the pinned engine is copied", `exit ${r.code}\n${indent(`${r.out}\n${r.err}`)}`);
  } else {
    const wrong = files.filter((f) => {
      try { return sha256(readFileSync(join(dest, f))) !== sha256(f === "worker.js" ? WORKER : f.endsWith(".wasm") ? WASM : GLUE); }
      catch { return true; }
    });
    if (wrong.length) bad("the pinned engine is copied", `wrong or missing: ${wrong.join(", ")}`);
    else ok("the pinned engine is copied", "three files, byte-exact, layout preserved");
  }
}

// ── 2. the wasm's bytes changed under a stable name ────────────────────────
{
  const w = world(mkdtempSync(join(ROOT, "w2-")));
  const flipped = Buffer.from(WASM);
  flipped[900_000] ^= 0xff; // same length, same magic, different bytes
  writeFileSync(join(w.origin, w.wasmName), flipped);
  mustRefuse("a changed wasm is refused", { ...w, dest: nextDest() }, [
    "pkg/db_backend_bg.wasm is not the pinned engine",
    sha256(WASM),
    sha256(flipped),
    "engine-pin-update",
  ]);
}

// ── 3. worker.js moved, and it is the file with no content-addressed twin ──
{
  const w = world(mkdtempSync(join(ROOT, "w3-")));
  writeFileSync(join(w.origin, "worker.js"), Buffer.from("// a different worker\n"));
  mustRefuse("a changed worker.js is refused", { ...w, dest: nextDest() }, [
    "worker.js is not the pinned engine",
    "NOT content-addressed",
    "replay-worker",
  ]);
}

// ── 4. the publisher deployed a new engine, so the pinned path is gone ─────
//
// The arm that decides whether the pin is honest about its own cost. A 404 on
// a content-addressed path is the NORMAL consequence of an upstream release,
// and the script must say so and name the remedy rather than reporting a
// network error.
{
  const w = world(mkdtempSync(join(ROOT, "w4-")));
  rmSync(join(w.origin, w.wasmName));
  mustRefuse("an upstream release is named, not mistaken for a network failure",
    { ...w, dest: nextDest() }, [
      "CONTENT-ADDRESSED path",
      "the publisher has deployed",
      "nor the publisher's layout path",
      "engine-pin-update",
    ]);
}

// ── 4b/4c. A BASE THAT SERVES ONLY THE PUBLISHER'S LAYOUT ──────────────────
//
// The content-addressed URL exists on the publisher's origin and nowhere else,
// and this script is legitimately pointed at bases that serve only the three
// legacy paths — `vars.REPLAY_ENGINE_BASE`, and the deployed site's own
// `/replay-engine/`, which is how "is this deploy serving the pinned engine?"
// is asked. So the hashed path falling back to the layout path must WORK when
// the bytes are right, and must still REFUSE when they are not. Without both
// arms the fallback is either a broken feature or a hole in the pin.
{
  const w = world(mkdtempSync(join(ROOT, "w4b-")));
  // A publisher-layout-only origin: no `assets/`, just the three real paths.
  mkdirSync(join(w.origin, "legacy", "pkg"), { recursive: true });
  writeFileSync(join(w.origin, "legacy", "worker.js"), WORKER);
  writeFileSync(join(w.origin, "legacy", "pkg", "db_backend.js"), GLUE);
  writeFileSync(join(w.origin, "legacy", "pkg", "db_backend_bg.wasm"), WASM);
  const dest = nextDest();
  const r = runFetch({ origin: join(w.origin, "legacy"), pin: w.pin, dest });
  if (r.code !== 0) {
    bad("a layout-only origin is served by the fallback", `exit ${r.code}\n${indent(`${r.out}\n${r.err}`)}`);
  } else if (!r.out.includes("fallback")) {
    bad("a layout-only origin is served by the fallback",
      `it passed without saying which path answered — a fetch that silently changes source is the ` +
      `thing this pin exists to stop\n${indent(r.out)}`);
  } else ok("a layout-only origin is served by the fallback", "and the run says which path answered");
}
{
  const w = world(mkdtempSync(join(ROOT, "w4c-")));
  const flipped = Buffer.from(WASM);
  flipped[500_000] ^= 0xff;
  mkdirSync(join(w.origin, "legacy", "pkg"), { recursive: true });
  writeFileSync(join(w.origin, "legacy", "worker.js"), WORKER);
  writeFileSync(join(w.origin, "legacy", "pkg", "db_backend.js"), GLUE);
  writeFileSync(join(w.origin, "legacy", "pkg", "db_backend_bg.wasm"), flipped);
  mustRefuse("the fallback is not a hole — it asserts the same hash",
    { origin: join(w.origin, "legacy"), pin: w.pin, dest: nextDest() },
    ["pkg/db_backend_bg.wasm is not the pinned engine", sha256(WASM), sha256(flipped)]);
}

// ── 5. a captive portal answered with a page ───────────────────────────────
//
// The hash would catch this too. The arm exists because the SPECIFIC diagnosis
// must survive: "expected 22acb8e1…, got 9f2c…" names neither this script nor
// that page, and the size check is what turns it into a sentence.
{
  const w = world(mkdtempSync(join(ROOT, "w5-")));
  const page = Buffer.from("<html>Sign in to continue</html>");
  writeFileSync(join(w.origin, w.wasmName), page);
  mustRefuse("a page served as the wasm is diagnosed as a page",
    { ...w, dest: nextDest() }, [`is only ${page.length} bytes`, "~18 MB", "answered with a page"]);
}

// ── 6-9. a pin that cannot be trusted is not a pin ─────────────────────────
{
  const w = world(mkdtempSync(join(ROOT, "w6-")));
  writeFileSync(w.pin, "worker.js  worker.js  deadbeef  12\n");
  mustRefuse("a sha256 that is not one is refused", { ...w, dest: nextDest() },
    ["expected 5 fields"]);
}
{
  const w = world(mkdtempSync(join(ROOT, "w7-")));
  writeFileSync(w.pin, `worker.js  worker.js  nothexnothexnothexnothexnothexnothexnothexnothexnothexnothexnoth  12  mutable\n`);
  mustRefuse("a malformed hash field is refused", { ...w, dest: nextDest() },
    ["is not a sha256"]);
}
{
  const w = world(mkdtempSync(join(ROOT, "w8-")));
  writeFileSync(w.pin, "# every line a comment\n\n");
  mustRefuse("an empty pin is refused rather than reported as a clean copy",
    { ...w, dest: nextDest() }, ["declares no files"]);
}
{
  const w = world(mkdtempSync(join(ROOT, "w9-")));
  mustRefuse("a missing pin is refused", { ...w, pin: join(ROOT, "nope.txt"), dest: nextDest() },
    ["no engine pin at"]);
}

// ── the repository's own three numbers ─────────────────────────────────────
console.log("");
console.log("  ── and do this repository's three descriptions of the engine agree? ──");

function parsePin(text) {
  const rows = [];
  text.split("\n").forEach((line, i) => {
    if (!line.trim() || line.trimStart().startsWith("#")) return;
    const f = line.trim().split(/\s+/);
    rows.push({ line: i + 1, dest: f[0], src: f[1], sha: f[2], bytes: Number(f[3]), mut: f[4], fields: f.length });
  });
  return rows;
}

const pinText = readFileSync(REAL_PIN, "utf8");
const rows = parsePin(pinText);

// R1 — shape.
{
  const problems = [];
  if (rows.length !== 3) problems.push(`${rows.length} records, expected 3`);
  for (const r of rows) {
    if (r.fields !== 5) problems.push(`${REAL_PIN}:${r.line}: ${r.fields} fields`);
    if (!/^[0-9a-f]{64}$/.test(r.sha ?? "")) problems.push(`${REAL_PIN}:${r.line}: bad sha256`);
    if (!Number.isInteger(r.bytes) || r.bytes <= 0) problems.push(`${REAL_PIN}:${r.line}: bad byte count`);
    if (!["mutable", "immutable"].includes(r.mut)) problems.push(`${REAL_PIN}:${r.line}: bad mutability`);
  }
  if (problems.length) bad("R1 the pin is well formed", problems.join("; "));
  else ok("R1 the pin is well formed", `3 records, ${rows.filter((r) => r.mut === "immutable").length} of them content-addressed`);
}

// R2 — a content-addressed source path is named for its own bytes. Catches a
// pin edited on one side: a bumped hash with a stale URL still fetches the old
// engine, and the fetch would then fail at the far end of a deploy instead of
// here.
{
  const problems = [];
  for (const r of rows.filter((x) => x.mut === "immutable")) {
    const m = /\.([0-9a-f]{16})\.[a-z]+$/.exec(r.src ?? "");
    if (!m) { problems.push(`${r.src} is marked immutable but is not content-addressed`); continue; }
    if (!r.sha.startsWith(m[1])) {
      problems.push(`${r.src} is named for ${m[1]} but the pin declares sha256 ${r.sha.slice(0, 16)}…`);
    }
  }
  if (problems.length) bad("R2 each content-addressed path is named for the bytes pinned under it", problems.join("; "));
  else ok("R2 each content-addressed path is named for the bytes pinned under it");
}

// R3 — THE NUMBER THE PAGE SHOWS A VISITOR.
//
// `ReplayEngineWasmBytes` is rendered through `approxMegabytes` into the
// honest phase line, so it is a claim this product makes to a person. It was
// 18_281_361 against a pinned wasm of 18_117_658 when this file was written,
// and nothing anywhere had ever compared them.
const nimText = readFileSync(NIM_SOURCE, "utf8");
const declaredBytes = (src) => {
  const m = /ReplayEngineWasmBytes\*?\s*=\s*([0-9_]+)/.exec(src);
  return m ? Number(m[1].replace(/_/g, "")) : null;
};
const wasmRow = rows.find((r) => r.dest === "pkg/db_backend_bg.wasm");
{
  const declared = declaredBytes(nimText);
  if (!wasmRow) {
    bad("R3 the constant the page shows equals the pinned wasm", `no pkg/db_backend_bg.wasm record in ${REAL_PIN}`);
  } else if (declared === null) {
    bad("R3 the constant the page shows equals the pinned wasm",
      `ReplayEngineWasmBytes is not readable from ${NIM_SOURCE}`);
  } else if (declared !== wasmRow.bytes) {
    bad("R3 the constant the page shows equals the pinned wasm",
      `ReplayEngineWasmBytes = ${declared}, but ${REAL_PIN} pins ${wasmRow.bytes} bytes ` +
      `(a difference of ${Math.abs(declared - wasmRow.bytes)}). The page tells a visitor a ` +
      `size for an engine it does not ship. Reconcile the constant in ` +
      `client/src/debugger/replay_engine.nim to the pin — not the pin to the constant.`);
  } else {
    ok("R3 the constant the page shows equals the pinned wasm", `${declared} bytes, both places`);
  }
}

// R4 — R3 can go red. Proved here rather than left to the day it matters,
// because a comparison whose two sides are read from the same tree passes
// trivially if the reader silently returns null.
{
  const mutated = nimText.replace(/ReplayEngineWasmBytes\*?\s*=\s*[0-9_]+/, "ReplayEngineWasmBytes* = 1");
  const d = declaredBytes(mutated);
  if (d !== 1) bad("R4 R3's reader actually reads the constant", `read ${d} from a source declaring 1`);
  else if (declaredBytes("nothing here") !== null) bad("R4 R3's reader actually reads the constant", "invented a number for a source with no constant");
  else if (wasmRow && d === wasmRow.bytes) bad("R4 R3's reader actually reads the constant", "the mutation did not change the verdict");
  else ok("R4 R3's reader actually reads the constant", "a mutated source is read as mutated, an absent one as null");
}

// R5 — the pin's destination layout is the one the deploy workflow asserts.
// The workflow greps for three literal paths under `site/replay-engine/`; a
// pin that renamed one would stage an engine the workflow then declares
// missing, at the far end of a build.
{
  const wf = readFileSync(DEPLOY_WORKFLOW, "utf8");
  const missing = rows
    .map((r) => `replay-engine/${r.dest}`)
    .filter((p) => !wf.includes(p));
  if (missing.length) {
    bad("R5 the pinned layout is the one the deploy asserts",
      `${DEPLOY_WORKFLOW} never names ${missing.join(", ")} — the deploy would stage an engine ` +
      `and then report it missing`);
  } else {
    ok("R5 the pinned layout is the one the deploy asserts", `all 3 paths named in the workflow`);
  }
}

rmSync(ROOT, { recursive: true, force: true });

console.log("");
console.log(`arms: ${passed}/${passed + failures.length} passed`);
if (failures.length) {
  console.log(`engine-pin-selftest: FAIL — ${failures.length}: ${failures.join("; ")}`);
  process.exit(1);
}
console.log("engine-pin-selftest: PASS — the fetch refuses every world in which the bytes are not " +
            "the pinned ones, and the pin, the Nim constant and the deploy workflow describe one engine");
