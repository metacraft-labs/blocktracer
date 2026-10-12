#!/usr/bin/env node
// engine-opens-selftest.mjs — does `engine-opens.mjs` DECIDE?
//
// The tool it tests is about to carry two numbers in CI, and a tool that
// reports "10 opened, 45 refused" by construction rather than by measurement
// would be the shape this repository has been bitten by most: a gate that is
// green because it cannot be red.
//
// So every arm here is a BITE. Each one puts the tool in a world where it must
// answer differently, and fails if the answer does not change.
//
// TWO CONFIGURATIONS, NAMED, because one half needs the engine. With a staged
// engine every arm runs. Without one, the arms that need a verdict from the
// engine report NOT MEASURED with the remedy — they are not counted as passed,
// and the figure for the configuration that ran is checked exactly. A skip
// folded into a pass is how a dark suite looks green.
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync, existsSync, copyFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const HERE = new URL(".", import.meta.url).pathname;
const REPO = resolve(HERE, "..", "..");
const TOOL = join(HERE, "engine-opens.mjs");
const ENGINE = process.env.ENGINE_DIR ?? join(REPO, "client", ".replay-engine-cache");
const HAVE_ENGINE = existsSync(join(ENGINE, "pkg", "db_backend.js"))
                 && existsSync(join(ENGINE, "pkg", "db_backend_bg.wasm"));

const tmp = mkdtempSync(join(tmpdir(), "engine-opens-selftest-"));
let failures = [];
let asserted = 0;
let notMeasured = [];

// THE TWO STREAMS ARE KEPT APART. `out` is everything, for the arms that look
// for a sentence; `stdout` is stdout alone, for the arm that parses JSON. The
// first version of this helper concatenated them, and its `--json` arm then
// failed against a tool that was already correct — the engine's `INFO` lines
// come back on stderr by design and would have been prepended to the document.
const run = (args) => {
  const r = spawnSync(process.execPath, [TOOL, ...args], { encoding: "utf8" });
  return { status: r.status, stdout: r.stdout ?? "", stderr: r.stderr ?? "",
           out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
};
const bite = (what, ok) => {
  asserted++;
  if (ok) { console.log(`  bite  ${what}`); return; }
  console.log(`  BITE DID NOT LAND  ${what}`);
  failures.push(what);
};

console.log("=== engine-opens-selftest — does the tool decide? ===");
console.log("");

// ── the arms that need no engine ───────────────────────────────────────────
console.log("Arms that judge the tool's own refusals (no engine needed)");
{
  const r = run(["--corpus"]);
  bite("no --engine is a usage error (64), not a run that measured nothing",
       r.status === 64 && /--engine <dir> is required/.test(r.out));
}
{
  const r = run(["--engine", join(tmp, "nowhere"), "--corpus"]);
  bite("an --engine directory with no glue is named, with the remedy — not treated as an engine that refuses everything",
       r.status === 64 && /is not there/.test(r.out) && /fetch-engine\.sh/.test(r.out));
}
// A staged directory holding the right NAMES but not an engine: the world a
// stale or half-filled --engine-cache produces. It is also the only --engine
// value these arms can use that does not depend on a real engine being staged,
// which is why it is built once here and reused.
const FAKE = join(tmp, "fake-engine");
mkdirSync(join(FAKE, "pkg"), { recursive: true });
writeFileSync(join(FAKE, "pkg", "db_backend.js"), "export const initSync = () => {};\n");
writeFileSync(join(FAKE, "pkg", "db_backend_bg.wasm"), "not wasm");
{
  const r = run(["--engine", FAKE, join(REPO, "fixtures/trace/tour/values/tour_values.ct")]);
  bite("a directory with the right file NAMES and the wrong bytes fails loudly rather than reporting every container refused",
       r.status !== 0 && !/0 opened, 1 refused/.test(r.out));
}
{
  // THE ORDER OF THE TOOL'S OWN CHECKS IS PART OF THE CLAIM. This arm asks for
  // the "no subjects" refusal, so it must pass an --engine that clears the
  // file checks — otherwise it measures the earlier refusal instead and passes
  // for the wrong reason on a host with no engine staged. It failed exactly
  // that way first.
  const r = run(["--engine", FAKE]);
  bite("no subjects is a usage error, not '0 opened, 0 refused' — a tool that measured nothing must not print a clean table",
       r.status === 64 && /no subjects/.test(r.out));
}
console.log("");

// ── the arms that need the engine ──────────────────────────────────────────
console.log("Arms that need a verdict from the engine");
if (!HAVE_ENGINE) {
  const why = `no engine staged at ${ENGINE}`;
  for (const what of [
    "a container the engine opens is reported OPENED, with both version axes",
    "a container the engine refuses is reported REFUSED",
    "the two populations are told apart in one run, so the tool is not answering from one subject",
    "a wrong --expect-opened FAILS with exit 1 and names both numbers",
    "a wrong --expect-refused FAILS too, separately",
    "--json carries the engine's own sha256, so a figure can be traced to the bytes that produced it",
  ]) notMeasured.push(`${what} (${why})`);
  console.log(`  NOT MEASURED — ${why}`);
  console.log("  remedy: ./client/hydrate/fetch-engine.sh client/.replay-engine-cache");
  console.log("          or ENGINE_DIR=<dir> to point at one already staged.");
} else {
  const OPENABLE = join(REPO, "fixtures/trace/tour/values/tour_values.ct");
  const REFUSED = join(REPO, "client/fixtures/chain/aztec-testnet/ct/0x009fb0c0fc8ef1d2ea15322e0f9b57b3d40bd5e3cbecb91a307d2ae9fb6ef53a.ct");
  {
    const r = run(["--engine", ENGINE, OPENABLE]);
    bite("a container the engine opens is reported OPENED, with both version axes",
         r.status === 0 && /OPENED\s+container=5 meta\.dat=6/.test(r.out));
  }
  {
    const r = run(["--engine", ENGINE, REFUSED]);
    bite("a container the engine refuses is reported REFUSED",
         r.status === 0 && /REFUSED\s+container=3 meta\.dat=3/.test(r.out));
  }
  {
    // THE DISCRIMINATION ARM. Both subjects in one run: if the tool answered
    // from the first container, or shared one VFS directory between subjects,
    // the two would agree here and this is the only arm that would notice.
    const r = run(["--engine", ENGINE, OPENABLE, REFUSED]);
    bite("the two populations are told apart in one run, so the tool is not answering from one subject",
         r.status === 0 && /1 opened, 1 refused, of 2/.test(r.out));
  }
  {
    const r = run(["--engine", ENGINE, OPENABLE, "--expect-opened", "0"]);
    bite("a wrong --expect-opened FAILS with exit 1 and names both numbers",
         r.status === 1 && /is 1, expected 0/.test(r.out));
  }
  {
    const r = run(["--engine", ENGINE, OPENABLE, "--expect-refused", "7"]);
    bite("a wrong --expect-refused FAILS too, separately",
         r.status === 1 && /it refuses is 0, expected 7/.test(r.out));
  }
  {
    const r = run(["--engine", ENGINE, OPENABLE, "--json"]);
    let j = null;
    try { j = JSON.parse(r.stdout); } catch { /* reported by the assertion */ }
    bite("--json carries the engine's own sha256, so a figure can be traced to the bytes that produced it",
         !!j && /^[0-9a-f]{64}$/.test(j.engine?.sha256 ?? "") && j.totals?.opened === 1);
  }
}
console.log("");

const CONFIG = HAVE_ENGINE ? "engine-present" : "engine-absent";
const EXPECTED = HAVE_ENGINE ? 10 : 4;
console.log(`configuration: ${CONFIG}`);
if (asserted !== EXPECTED) {
  console.log(`ASSERTION COUNT IS ${asserted}, EXPECTED ${EXPECTED} for this configuration — an arm was`);
  console.log("added, removed or skipped. Reconcile the number to the arms, and say which in the commit.");
  failures.push(`assertion count ${asserted} != ${EXPECTED}`);
}
for (const n of notMeasured) console.log(`NOT MEASURED: ${n}`);
if (failures.length > 0) {
  console.log(`\nFAIL — ${failures.length} problem(s)`);
  process.exitCode = 1;
} else {
  console.log(`\nPASS — ${asserted} arm(s) bit${notMeasured.length ? `, ${notMeasured.length} NOT MEASURED (not counted as passed)` : ""}`);
}
