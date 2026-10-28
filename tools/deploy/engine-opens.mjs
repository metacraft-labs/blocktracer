#!/usr/bin/env node
// engine-opens.mjs — ask the PINNED replay engine, on its own bytes, which of
// this repository's containers it can actually open.
//
// ## Why this exists, when three other things already describe the engine
//
// `engine-pin.txt` says WHICH engine. `health-checks.json`'s `shipped-engine`
// entry says what version sets it accepts, and said so by grepping needles out
// of the wasm and reading version constants out of a checkout. Both are
// inferences about behaviour from evidence that is not behaviour, and the
// register says so in its own words: "THE SOURCE READING IS NOT THE PROVENANCE
// THAT MATTERS HERE".
//
// This asks the engine. `db_backend.js` exports `vfs_write_file` and
// `load_trace_from_vfs` — the same pair `client/hydrate/worker.js` uses — so a
// container can be pushed into the in-memory VFS and the engine asked to parse
// it, in node, with no browser, no DAP round trip and no page. The answer is a
// boolean the engine returned.
//
// `tools/journeys/run.mjs`'s Arm II already asks this question the thorough
// way: in a real browser, over the worker protocol, one subject per recording
// KIND. That arm stays the authority, because it proves the engine opens a
// recording the PRODUCT assembled. This is the cheap complement — every
// container rather than one per kind, in a second rather than a browser
// session — and its job is to tell you WHICH containers, which is the thing
// Arm II's refusal does not print.
//
// ## Usage
//
//     ./client/hydrate/fetch-engine.sh /tmp/engine      # stage the PINNED engine
//     node tools/deploy/engine-opens.mjs --engine /tmp/engine <file.ct> ...
//     node tools/deploy/engine-opens.mjs --engine /tmp/engine --corpus
//
// `--corpus` reads the complete generated fixture inventory. `--json` prints the table as data.
// `--expect-opened N` / `--expect-refused N` make the figures assertions, so a
// corpus that silently stops being readable is a red run rather than a diff in
// a log nobody reads.
//
// ## The argument is tried both ways, and that is not belt-and-braces
//
// `load_trace_from_vfs`'s own doc comment says it takes "the virtual path of
// the `.ct` container (or a prefix containing one)". The prefix form answers
// `no CTFS (.ct) container found in VFS` for a container that is right there —
// measured, on a container the file form opens. A probe that passed only the
// folder would report every container refused, which reads exactly like a
// format verdict and is not one. So both forms are tried and the one that
// answered is printed.
import { readFileSync, existsSync } from "node:fs";
import { basename, join, resolve, relative } from "node:path";
import { validateManifest, prepareRecordings } from '../fixtures/prepare-recordings.mjs';

const HERE = new URL(".", import.meta.url).pathname;
const REPO = resolve(HERE, "..", "..");

function parseArgs(argv) {
  const out = { engine: null, corpus: false, json: false, files: [], expectOpened: null, expectRefused: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--engine") out.engine = argv[++i];
    else if (a === "--corpus") out.corpus = true;
    else if (a === "--json") out.json = true;
    else if (a === "--expect-opened") out.expectOpened = Number(argv[++i]);
    else if (a === "--expect-refused") out.expectRefused = Number(argv[++i]);
    else if (a.startsWith("--")) { console.error(`engine-opens: unknown option ${a}`); process.exit(64); }
    else out.files.push(a);
  }
  return out;
}

function fixtureCorpus(dir) {
  const manifest = JSON.parse(readFileSync(join(dir, 'tools/fixtures/recordings.json'), 'utf8'));
  validateManifest(manifest, dir);
  return manifest.recordings.map((row) => join(dir, row.output));
}

// The two version axes, read off the bytes rather than taken from a name. They
// are INDEPENDENT — `engine-pin.txt` carries the incident that taught this —
// so both are printed for every subject, and a container with no CTFS magic is
// reported as such instead of being given a version of 0.
const CTFS_MAGIC = Buffer.from("c0de72ace2", "hex");
function versionsOf(bytes) {
  const isCtfs = bytes.length > 5 && bytes.subarray(0, 5).equals(CTFS_MAGIC);
  const container = isCtfs ? bytes[5] : null;
  const j = bytes.indexOf(Buffer.from("CTMD"));
  const metaDat = j >= 0 && j + 6 <= bytes.length ? bytes.readUInt16LE(j + 4) : null;
  // Byte 16 is the PROFILE byte, and only in a version-6 header (24 bytes).
  // In version 5 that offset is body, so reading it there would invent a field.
  const profile = container === 6 && bytes.length > 16 ? bytes[16] : null;
  return { container, metaDat, profile };
}

const args = parseArgs(process.argv.slice(2));
if (!args.engine) {
  console.error("engine-opens: --engine <dir> is required — the directory `fetch-engine.sh`");
  console.error("              staged, holding pkg/db_backend.js and pkg/db_backend_bg.wasm.");
  console.error("              It must be the PINNED engine; this tool does not fetch, so that");
  console.error("              what it measures cannot drift from what the deploy ships.");
  process.exit(64);
}
const glue = join(resolve(args.engine), "pkg", "db_backend.js");
const wasmPath = join(resolve(args.engine), "pkg", "db_backend_bg.wasm");
for (const p of [glue, wasmPath]) {
  if (!existsSync(p)) {
    console.error(`engine-opens: ${p} is not there.`);
    console.error("              Stage the engine first: ./client/hydrate/fetch-engine.sh <dir>");
    process.exit(64);
  }
}

if (args.corpus) prepareRecordings({ log: (message) => console.error(message) });
const subjects = args.corpus ? fixtureCorpus(REPO) : args.files.map((f) => resolve(f));
if (subjects.length === 0) {
  console.error("engine-opens: no subjects — pass container paths or --corpus");
  process.exit(64);
}

// THE ENGINE LOGS TO STDOUT, AND THAT MAKES `--json` UNPARSEABLE UNLESS IT IS
// MOVED. wasm-bindgen routes Rust's `log` through `console.log`, so loading one
// container emits a dozen `INFO src/...` lines onto the same stream this tool's
// report goes to. Measured: `--json | python3 -c json.load` failed at "line 1
// column 1" with a perfectly correct document further down. The selftest's
// `--json` arm is what found it.
//
// So `console.log` is pointed at stderr for the engine's whole lifetime. The
// chatter is KEPT rather than silenced — it says things worth reading, e.g.
// "column-aware container — global_position_index decoder built from 1 of 1
// paths' Layout A line tables" — it just stops being mixed into the answer.
// `emit` below is the saved real one, and it is the only thing that writes to
// stdout.
const emit = console.log.bind(console);
// THREE METHODS, NOT ONE. The engine's `INFO` lines arrive through
// `console.info` and its debug lines through `console.debug`; in node both of
// those write to STDOUT, so swapping `console.log` alone left `--json`
// unparseable in exactly the way it was before — measured, after the first
// attempt at this fix. `warn` and `error` already go to stderr and are left
// alone, so the engine's own diagnoses keep their severity.
for (const m of ["log", "info", "debug"]) {
  console[m] = (...a) => console.error(...a);
}

const { initSync, vfs_write_file, vfs_file_exists, load_trace_from_vfs } =
  await import(`file://${glue}`);
const wasmBytes = readFileSync(wasmPath);
initSync({ module: wasmBytes });

const engineSha = (await import("node:crypto")).createHash("sha256").update(wasmBytes).digest("hex");
const rows = [];
for (const [i, f] of subjects.entries()) {
  const bytes = readFileSync(f);
  const v = versionsOf(bytes);
  // One VFS directory per subject, so a previous successful load cannot answer
  // for this one. A shared directory would make the first openable container
  // look like a whole readable corpus.
  const dir = `/engine-opens-${i}`;
  const vpath = `${dir}/${basename(f)}`;
  vfs_write_file(vpath, bytes);
  if (!vfs_file_exists(vpath)) {
    rows.push({ file: relative(REPO, f), ...v, bytes: bytes.length, opened: false, via: null,
                error: "the VFS did not take the bytes — this is the probe failing, not the engine refusing" });
    continue;
  }
  let opened = false, via = null, error = "";
  for (const [how, arg] of [["file", vpath], ["dir", dir]]) {
    try { if (load_trace_from_vfs(arg)) { opened = true; via = how; break; } }
    catch (e) { error = String((e && e.message) || e); }
  }
  rows.push({ file: relative(REPO, f), ...v, bytes: bytes.length, opened, via, error });
}

const opened = rows.filter((r) => r.opened).length;
const refused = rows.length - opened;

if (args.json) {
  emit(JSON.stringify({ engine: { dir: resolve(args.engine), sha256: engineSha, bytes: wasmBytes.length },
                               totals: { subjects: rows.length, opened, refused }, rows }, null, 2));
} else {
  emit("=== which containers does the PINNED engine open? ===");
  emit(`  engine: ${wasmBytes.length} bytes, sha256 ${engineSha.slice(0, 16)}…`);
  emit(`          staged at ${resolve(args.engine)}`);
  emit("");
  for (const r of rows) {
    emit(`  ${r.opened ? "OPENED  " : "REFUSED "} container=${r.container ?? "none"}` +
      ` meta.dat=${r.metaDat ?? "none"}${r.profile === null ? "" : ` profile=${r.profile}`}` +
      `  ${String(r.bytes).padStart(9)} B  ${r.file}`);
  }
  emit("");
  // GROUPED BY THE PAIR, because the pair is what decides. A total alone has
  // twice been read as "the engine is broken" or "the corpus is broken" when
  // the truth was a version skew between two named sets.
  const byPair = new Map();
  for (const r of rows) {
    const k = `container ${r.container ?? "none"} / meta.dat ${r.metaDat ?? "none"}`;
    const g = byPair.get(k) ?? { opened: 0, refused: 0 };
    r.opened ? g.opened++ : g.refused++;
    byPair.set(k, g);
  }
  for (const [k, g] of [...byPair.entries()].sort()) {
    emit(`  ${k.padEnd(34)} ${String(g.opened).padStart(3)} opened, ${String(g.refused).padStart(3)} refused`);
  }
  emit(`\n  ${opened} opened, ${refused} refused, of ${rows.length}`);
}

let bad = 0;
const expect = (want, got, what) => {
  if (want === null) return;
  if (want === got) { emit(`  [OK]     ${what} is ${got}, as expected`); return; }
  emit(`  [FAILED] ${what} is ${got}, expected ${want}`);
  bad++;
};
expect(args.expectOpened, opened, "the number of containers the pinned engine opens");
expect(args.expectRefused, refused, "the number it refuses");
if (bad > 0) {
  emit("");
  emit("  A figure moved. That is a finding either way and never a number to edit:");
  emit("  the engine was re-pinned, or the corpus gained or lost containers, or a");
  emit("  container was re-encoded. Say which in the commit that changes the number.");
}
process.exitCode = bad > 0 ? 1 : 0;
