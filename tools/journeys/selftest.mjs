// selftest.mjs — proof that the journeys BITE.
//
//   node tools/journeys/selftest.mjs
//   just journeys-selftest
//
// A journey that cannot fail is not a test, and this repository already knows
// it: every `ci/test/<subject>.sh` here has a `<subject>-test.sh` beside it that
// plants deliberate violations in real source and proves the check reports them.
// `tools/design/check-tokens-selftest.mjs` does the same, "by planting each
// violation in the real source and restoring it byte-identically". This is that
// file for the journey layer.
//
// HOW AN ARM WORKS
// ----------------
// One arm = one MUTATION in real product source, chosen to break exactly one
// spec claim, plus the NAME of the assertion that must go red. The arm:
//
//   1. records the assertion's verdict on the unmutated tree (it must be GREEN
//      — a mutation that "reddens" something already red proves nothing);
//   2. applies the mutation and rebuilds the exporter;
//   3. reruns that journey alone and demands the NAMED assertion is now RED;
//   4. restores the file byte-for-byte and rebuilds, and demands the assertion
//      is GREEN again.
//
// Step 4 is not tidiness. Without it a mutation that failed to apply, or a
// rebuild that silently reused a stale `dist/`, is indistinguishable from a
// mutation that was killed.
//
// THREE VERDICTS, NEVER TWO
// -------------------------
// Verification-Harness-Traps.md §1a: "A mutation harness needs three verdicts,
// not two. Killed, survived, and NEVER RAN — and the third is the one a
// rc-based harness silently folds into the first." A mutation that does not
// compile has demonstrated nothing about the journey, and is reported as
// DID-NOT-BUILD rather than as a kill. So the verdict is taken from the parsed
// per-assertion records, never from an exit code: `node run.mjs` exits non-zero
// for a red journey, for a browser that would not start and for a syntax error
// in this file, all the same number.
//
// THE ASSERTION IS NAMED, NOT COUNTED
// -----------------------------------
// An arm passes only if the assertion WRITTEN FOR IT flipped. "The journey went
// red" is satisfied by a mutation that broke some other assertion — a mutation
// that removes the source pane reddens the position check too, and would score
// a kill it did not earn.

import { readFile, writeFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

const run = promisify(execFile);
const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");
const CLIENT = join(REPO, "client");
const REPORT = join(HERE, ".selftest-report.json");

/**
 * The arms.
 *
 * `find` must occur EXACTLY ONCE in the file — asserted before the edit. A
 * mutation applied twice, or to a line that moved, is a different experiment
 * from the one described here, and a `replaceAll` would hide that.
 */
const ARMS = [
  {
    id: "A/no-position-mark",
    why:
      "Remove the class that marks the execution position. This is the shape of the" +
      " defect a user reported as 'no current-line indicator': the listing renders," +
      " the session knows where it is, and nothing on screen says so.",
    file: join(CLIENT, "src", "components", "debugger.nim"),
    find: `(if ln.current: " cur" else: "") &`,
    replace: `(if false: " cur" else: "") &`,
    journey: "served-frame-marks-the-position",
    assertion: "SERVED: exactly one line carries the position mark",
  },
  {
    id: "B/opens-on-the-manifest",
    why:
      "Force the source pane onto the first document instead of the one the session" +
      " is positioned in. This is the mechanism of the `Nargo.toml` defect, stated in" +
      " the fix's own comment: 'left activeIndex at 0 — which after the sort is" +
      " whatever path sorts first, typically Nargo.toml — while currentLine kept a" +
      " line number belonging to a different file.' 115 debug-route cases could not" +
      " see it because their fixture supplied the position they then asserted back.",
    file: join(CLIENT, "src", "debugger", "demo_session.nim"),
    find: `    focus(pane, posPath, posLine)`,
    replace: `    focus(pane, docs[0].path, posLine)`,
    journey: "served-frame-marks-the-position",
    assertion: "SERVED: the file on screen is the file the position is in",
  },
  {
    id: "C/phase-renamed",
    why:
      "Rename a SessionPhase's published string. §7.0's table is a claim about" +
      " availability, and the page publishes a phase; the mapping between them is" +
      " the one place the two vocabularies meet. A renamed phase must fail there, by" +
      " name, rather than quietly reclassifying 48 of 62 pages into no row at all.",
    file: join(CLIENT, "src", "debugger", "session_view.nim"),
    find: `    spUnavailable = "unavailable"`,
    replace: `    spUnavailable = "no-trace-possible"`,
    journey: "availability-decides-the-landing",
    assertion: "every transaction's phase is one §7.0 names",
  },
  {
    id: "D/a-link-to-the-primary-action",
    why:
      "Label a control on the session page 'Debug'. Page-Descriptions.md §7.0 names" +
      " this exact regression as rule 1's anti-goal — 'a button that opens the" +
      " debugger is a link to the primary action, not the primary action' — and" +
      " records that it 'survived a review with this section open'.",
    file: join(CLIENT, "src", "pages", "debug.nim"),
    find: `        text "← " & s.chain`,
    replace: `        text "Debug"`,
    journey: "tx-page-is-the-session",
    assertion: "no page offers to open a debugger",
  },
];

const log = (s = "") => console.log(s);

async function rebuild() {
  // The exporter only. `hydrate.js` is unaffected by every mutation above — all
  // four are in `client/src`, which the hydration bundle compiles against but
  // whose SSR output is what changes — so rebuilding it per arm would cost
  // minutes and prove nothing. If a future arm touches `client/hydrate/`, it
  // must say so and rebuild it.
  try {
    await run(
      "nim",
      [
        "c",
        "-r",
        "--mm:orc",
        "-d:isServer",
        "-d:release",
        "-d:hydrationBundle=/assets/hydrate.js",
        "--hints:off",
        "src/static_export.nim",
      ],
      { cwd: CLIENT, maxBuffer: 64 * 1024 * 1024 },
    );
    return { built: true };
  } catch (err) {
    return { built: false, log: String(err.stderr ?? err.stdout ?? err).slice(-1500) };
  }
}

/** Run one journey and return its per-assertion records. Never an exit code. */
async function verdictFor(journey, assertion) {
  try {
    await run("node", [join(HERE, "run.mjs"), "--only", journey, "--json", REPORT], {
      cwd: REPO,
      maxBuffer: 64 * 1024 * 1024,
    });
  } catch {
    /* a red journey exits 1; the verdict comes from the report, not from this */
  }
  const report = JSON.parse(await readFile(REPORT, "utf8").catch(() => "{}"));
  const j = (report.journeys ?? []).find((x) => x.id === journey);
  if (!j || !j.records) return { found: false };
  const hits = j.records.filter((r) => r.what.includes(assertion));
  if (hits.length !== 1) return { found: false, ambiguous: hits.length };
  return { found: true, ok: hits[0].ok, detail: hits[0].detail };
}

async function main() {
  log("=== journey selftest — do the journeys bite? ===");
  log("    One mutation per arm, in real product source, each aimed at ONE");
  log("    assertion. An arm passes only if THAT assertion flips, and only if");
  log("    it was green before and is green again after.");
  log("");

  const base = await rebuild();
  if (!base.built) {
    log("the unmutated tree does not build; nothing below would mean anything");
    log(base.log);
    process.exitCode = 2;
    return;
  }

  let killed = 0;
  let survived = 0;
  let neverRan = 0;

  for (const arm of ARMS) {
    log(`--- ${arm.id}`);
    log(`    ${arm.why}`);
    log(`    target: ${arm.journey} :: "${arm.assertion}"`);

    const original = await readFile(arm.file, "utf8");
    const occurrences = original.split(arm.find).length - 1;
    if (occurrences !== 1) {
      log(`    NEVER RAN — the mutation site occurs ${occurrences} times, expected exactly 1`);
      log(`               (the source moved; this arm is describing a file that no longer exists)`);
      neverRan += 1;
      log("");
      continue;
    }

    // 1. before
    const before = await verdictFor(arm.journey, arm.assertion);
    if (!before.found) {
      log(`    NEVER RAN — no single assertion matched that name on the unmutated tree`);
      neverRan += 1;
      log("");
      continue;
    }
    if (!before.ok) {
      log(`    NEVER RAN — the assertion is ALREADY RED before the mutation`);
      log(`               (${before.detail})`);
      log(`               A mutation cannot demonstrate anything about an assertion that`);
      log(`               was not green to begin with.`);
      neverRan += 1;
      log("");
      continue;
    }
    log(`    before:  GREEN`);

    // 2. mutate
    await writeFile(arm.file, original.split(arm.find).join(arm.replace));
    let verdict;
    try {
      const built = await rebuild();
      if (!built.built) {
        log(`    NEVER RAN — the mutated tree did not compile, so nothing was measured`);
        log(`               ${built.log.split("\n").slice(-3).join(" / ")}`);
        verdict = "never";
      } else {
        const after = await verdictFor(arm.journey, arm.assertion);
        if (!after.found) {
          log(`    NEVER RAN — the assertion vanished from the mutated run`);
          verdict = "never";
        } else if (after.ok) {
          log(`    SURVIVED — the assertion is still GREEN with the defect in place.`);
          log(`               ${after.detail}`);
          verdict = "survived";
        } else {
          log(`    KILLED   — ${after.detail}`);
          verdict = "killed";
        }
      }
    } finally {
      // 3. restore, byte-for-byte, whatever happened above
      await writeFile(arm.file, original);
    }

    // 4. and prove the restore took
    const restored = await rebuild();
    const back = restored.built ? await verdictFor(arm.journey, arm.assertion) : { found: false };
    if (!back.found || !back.ok) {
      log(`    NEVER RAN — the assertion did not come back green after restoring, so the`);
      log(`               red above cannot be attributed to the mutation`);
      verdict = "never";
    } else {
      log(`    after:   GREEN again`);
    }

    if (verdict === "killed") killed += 1;
    else if (verdict === "survived") survived += 1;
    else neverRan += 1;
    log("");
  }

  log(`${ARMS.length} arm(s): ${killed} killed, ${survived} survived, ${neverRan} never ran`);
  if (killed !== ARMS.length) {
    log("RESULT: FAILED — every arm must be killed by the assertion written for it");
    process.exitCode = 1;
    return;
  }
  log("  Each journey reddens on the defect it exists to catch, and only then.");
  log("RESULT: OK");
}

main().catch((e) => {
  console.error(String(e && e.stack ? e.stack : e));
  process.exitCode = 1;
});
