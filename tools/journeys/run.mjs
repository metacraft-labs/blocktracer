// run.mjs — the journey conformance layer.
//
// Each journey is a sentence from the spec. It is judged by loading the artefact
// a visitor loads, in a real browser, and asserting what is on the screen.
//
//   bash:  node tools/journeys/run.mjs [--dist DIR] [--only ID] [--json FILE]
//   just:  just journeys
//
// WHY THIS LAYER EXISTS
// ---------------------
// Four user-visible defects passed every gate in this repository, and each was
// invisible for the same reason: every test states one component's contract and
// none states an end-to-end claim. The clearest case is in the sibling repo — a
// suite literally named `test_every_entry_form_reaches_the_application` proves
// every URL form CLASSIFIES, while the function that would consult the
// classifier at run time has zero callers. Nothing noticed, because no test
// asserted that a visitor at a URL gets anything.
//
// So a journey here may not assert a component's contract. It asserts what a
// visitor sees, and it fails whichever layer broke.
//
// THE FOUR RULES, AND WHERE EACH ONE CAME FROM
// --------------------------------------------
// 1. DRIVE THE ARTEFACT A VISITOR LOADS. `just export` ships zero JS;
//    `flake.nix packages.default` — what CI deploys — ships the hydration
//    bundle, and on the debug route the two DISAGREE. `lib/site.mjs` refuses a
//    tree that is not the deployed shape, with exit 2.
//
// 2. ASSERT THE ARTEFACT, NEVER A CHAIN OF SUCCESSES. A DAP server once
//    answered `success: true` to four requests over a session with no trace
//    open. Journey 03 is written against the local form of this: a step that
//    advances the URL and moves nothing on the screen.
//
// 3. A TEST WHOSE SUBJECT CAN BE EMPTY PASSES VACUOUSLY. `assertion F` once
//    printed PASS over 4 images of a 304-image corpus. `Journey.subjects()` is
//    the required first call of anything that quantifies, and counts are
//    asserted with `countIs` wherever membership is knowable.
//
// 4. DO NOT BUILD ON FIXTURES THAT SUPPLY THE ANSWER. 115 debug-route cases
//    survived a defect because the fixture set the position they verified. No
//    journey below names a file, a line or a step as an expected value; every
//    expectation is a relation between two things the page reports.
//
// ARM I — PROVE THE INSTRUMENT, THEN JUDGE THE SUBJECT
// ----------------------------------------------------
// Before any product page is loaded, the same server, the same browser and the
// same probe are pointed at two hand-written fixtures: one with a sentence in
// it, one empty. If the first does not render its characters, this process
// cannot tell a blank product from a blank browser, and it exits 2 without
// judging anything. That is not a hypothetical: the sibling repo's mount gate
// blocked a deploy over a byte-perfect page because the runner's Chromium had
// no fonts and laid out every string with zero glyphs.
//
// DISCOVERY, NOT A LIST
// ---------------------
// `journeys/*.journey.mjs` is a glob. This repository's signature defect is a
// gate whose surface has a hole exactly the shape of the newest file — four Nim
// suites and two shell checks are, at the time of writing, green in `just test`
// and executed by no CI job at all. A layer added to fix that must not have the
// same hole, so nothing here lists a journey by name, and `MIN_JOURNEYS` makes
// an empty glob a failure instead of a clean sweep.

import { readdir, writeFile, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join, resolve } from "node:path";

import { Journey, renderJourney, nameCollisions } from "./lib/harness.mjs";
import { openBrowser, readFacts } from "./lib/probe.mjs";
import { openSite, serveDist } from "./lib/site.mjs";
import { stageEngine } from "./lib/engine.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");

// A floor, not a target. An empty `journeys/` directory would otherwise report
// "0 journeys, 0 failures" and exit 0 — the vacuous pass this whole layer is
// written against, arriving through its own front door.
const MIN_JOURNEYS = 4;

// The instrument fixture's sentence, and its length. Asserted rather than
// measured from the file, so a fixture edited to be empty fails Arm I instead
// of quietly lowering the bar.
const INSTRUMENT_MIN_CHARS = 40;

function parseArgs(argv) {
  const a = {
    dist: join(REPO, "client", "dist"),
    // The engine cache is a sibling of the site tree, never inside it — the
    // exporter removes `dist/`, and `nix build`'s output is read-only. See
    // lib/engine.mjs.
    engineCache: join(REPO, "client", ".replay-engine-cache"),
    only: null,
    json: null,
  };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--dist") a.dist = resolve(argv[++i]);
    else if (argv[i] === "--engine-cache") a.engineCache = resolve(argv[++i]);
    else if (argv[i] === "--only") a.only = argv[++i];
    else if (argv[i] === "--json") a.json = resolve(argv[++i]);
  }
  return a;
}

/**
 * The ledger of journeys known to be RED, with the reason and the work that
 * closes each.
 *
 * IT FAILS IN BOTH DIRECTIONS. A ledgered journey that goes GREEN fails the
 * run, exactly as an un-ledgered journey that goes RED does. A one-directional
 * ledger is how a suite comes to describe a product that no longer exists — the
 * same rule `renderer-pane-parity.sh` and `noir-studio-signed-out.sh` state for
 * their budgets — and, here specifically, it is what would let a fix land
 * without anyone removing the entry that says the defect is still open.
 */
async function loadLedger() {
  const raw = await readFile(join(HERE, "ledger.json"), "utf8").catch(() => "{}");
  const parsed = JSON.parse(raw);
  return parsed.known_red ?? {};
}

/**
 * REFUSE A SUBJECT CHOSEN WITH A FALLBACK.
 *
 * This is a lint and not a journey because the defect it names is not visible
 * in any verdict. Six files in this directory selected their subject as
 *
 *     list.find((t) => !t.real) ?? list[0]
 *
 * which PREFERS a synthetic fixture and, with 15 synthetic sessions in the
 * corpus, could never reach its own `??` arm. Every one of them was GREEN
 * throughout, over a subject nobody had chosen — journeys 03 and 09 were found
 * one at a time, from two visitor reports about real captures, and 07, 02, 06
 * and this pattern's last occurrence were found only by looking for the SHAPE.
 * Three occurrences is a pattern; a pattern that costs nothing to refuse
 * mechanically should not be found a seventh time by someone reading carefully.
 *
 * WHY `??` IS THE THING REFUSED. It makes "no subject of this kind was
 * available" and "a subject of this kind passed" the same green. The correct
 * form is two lists selected by filter, each asserted non-empty with its count
 * printed, both driven — so a corpus that loses one kind of recording is a RED,
 * which is what it is: the journey can no longer judge the claim it makes.
 *
 * Comments are stripped first, deliberately: five of those files now QUOTE the
 * defect in their headers to explain what was removed, and a lint that could
 * not tell an explanation from an instance would force the explanations out.
 *
 * AND IT MATCHES THE CLOSING PAREN, NOT A REGEX OVER THE CALL. The first
 * spelling of this check was `/\.find\([^;]*?\)\s*\?\?/`, and it failed journey
 * 09 on its first run over
 *
 *     .find((r) => (r.getAttribute("data-step") ?? "") !== "" && …)
 *
 * — a `??` INSIDE the predicate, defaulting an absent attribute to the empty
 * string, which is not a subject fallback and is correct. A gate that cries
 * wolf gets switched off, and then it is not there for the real one
 * (README.md, "Rendered, not present"). So the parens are counted: the `??`
 * has to follow the find call's own closing bracket. `list.find(…)?.text ?? x`
 * is not flagged either — that defaults a FIELD of the found item, and the
 * subject has already been chosen without a fallback by then.
 */
function refuseSubjectFallback(file, source) {
  const code = source
    .replace(/\/\*[\s\S]*?\*\//g, " ")
    .replace(/(^|[^:])\/\/[^\n]*/g, "$1 ")
    .replace(/\s+/g, " ");
  for (let i = code.indexOf(".find("); i !== -1; i = code.indexOf(".find(", i + 1)) {
    let depth = 0;
    let end = -1;
    for (let k = i + ".find".length; k < code.length; k++) {
      if (code[k] === "(") depth += 1;
      else if (code[k] === ")") {
        depth -= 1;
        if (depth === 0) {
          end = k;
          break;
        }
      }
    }
    if (end === -1) continue; // unbalanced — a parse problem, not this lint's
    if (!/^\s*\?\?/.test(code.slice(end + 1))) continue;
    throw Object.assign(
      new Error(
        `${file} selects a subject with a fallback:\n` +
          `      ${code.slice(i, Math.min(end + 20, code.length))}\n` +
          `    A \`??\` between two subject kinds makes "none of this kind was available" and\n` +
          `    "one of this kind passed" the same green — it is how six journeys came to judge\n` +
          `    only the demo chain. Select each kind by filter, assert each list non-empty with\n` +
          `    \`j.atLeast(list.length, 1, "SUBJECTS: …")\`, and drive both.`,
      ),
      { exitCode: 2 },
    );
  }
}

async function discover() {
  const dir = join(HERE, "journeys");
  const files = (await readdir(dir)).filter((f) => f.endsWith(".journey.mjs")).sort();
  const mods = [];
  for (const f of files) {
    refuseSubjectFallback(f, await readFile(join(dir, f), "utf8"));
    const m = await import(join(dir, f));
    if (!m.id || !m.claim || !m.run) {
      throw Object.assign(
        new Error(`${f} is in journeys/ but exports no { id, claim, run } — it would never run`),
        { exitCode: 2 },
      );
    }
    mods.push({ file: f, ...m });
  }
  return mods;
}

/** Arm I. Same server, same browser, same probe — over bytes we wrote. */
async function instrumentArm(browser) {
  const srv = await serveDist(join(HERE, "fixtures"));
  const results = {};
  try {
    for (const [name, file] of [
      ["visible", "/instrument-visible.html"],
      ["blank", "/instrument-blank.html"],
    ]) {
      const page = await browser.newPage();
      await page.goto(srv.origin + file, { waitUntil: "load", timeout: 20000 });
      results[name] = (await readFacts(page)).visibleText;
      await page.close();
    }
  } finally {
    await srv.close();
  }
  return results;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  console.log("=== BlockTracer journey conformance ===");
  console.log("    Each journey is a sentence from the spec, judged by loading");
  console.log("    the artefact a visitor loads and asserting what is on screen.");
  console.log("");

  // Re-stage the engine BEFORE deciding whether there is one. `static_export`
  // removes `dist/` and writes it again, so an export taken after a fetch
  // silently un-does the fetch — see lib/engine.mjs.
  const staged = await stageEngine(args.dist, args.engineCache);

  const site = await openSite(args.dist, REPO);
  console.log(`  artefact:      ${site.root}`);
  console.log(`  build:         HYDRATED — the shape flake.nix packages.default deploys`);
  console.log(
    `  replay engine: ${
      site.engine
        ? `present (staged from ${staged.from})`
        : `ABSENT — stepping journeys will SKIP, and a skip is not a pass.\n                 ${staged.remedy ?? ""}`
    }`,
  );
  console.log(`  origin:        ${site.origin}`);
  console.log("");

  // The browser is opened INSIDE the try, and both handles are closed in the
  // finally even when one of them was never created. A run that failed before
  // the browser existed used to leave the static server listening, and node
  // stayed alive with its verdict already printed — a gate that reports FAILED
  // and then hangs the job is indistinguishable, to a CI timeout, from a gate
  // that hung before deciding anything.
  let browser = null;
  let failures = 0;
  let checks = 0;
  const report = { artefact: site.root, hydrated: true, engine: site.engine, journeys: [] };

  try {
    browser = await openBrowser();

    // ---- ARM I ---------------------------------------------------------
    console.log("Arm I: prove the instrument, before judging the subject");
    const inst = await instrumentArm(browser);
    console.log(`         a fixture with a sentence rendered ${inst.visible} characters`);
    console.log(`         an empty fixture rendered ${inst.blank}`);
    if (!(inst.visible >= INSTRUMENT_MIN_CHARS) || inst.blank !== 0) {
      console.error("");
      console.error("  This browser cannot lay out text, or the probe is not reading what is");
      console.error("  rendered. Every journey below would measure a blank page and could not");
      console.error("  tell it from a blank product. Nothing is judged.");
      console.error("  remedy: run inside the project shell (direnv exec <worktree> ...), which");
      console.error("          supplies fontconfig and the pinned browser.");
      process.exitCode = 2;
      return;
    }
    console.log("  [OK]     the instrument distinguishes a rendered page from a blank one");
    console.log("");

    // ---- discovery -----------------------------------------------------
    const ledger = await loadLedger();
    const all = await discover();
    if (all.length < MIN_JOURNEYS) {
      console.error(
        `  journeys/ yielded ${all.length} journeys, fewer than the ${MIN_JOURNEYS} this layer` +
          ` declares. An empty glob reports a clean sweep; this is that check.`,
      );
      process.exitCode = 2;
      return;
    }
    const selected = args.only ? all.filter((m) => m.id === args.only) : all;
    if (args.only && selected.length === 0) {
      console.error(`  --only ${args.only} matched no journey`);
      process.exitCode = 2;
      return;
    }
    console.log(`Discovered ${all.length} journeys in journeys/ (running ${selected.length})`);
    console.log("");

    // ---- the journeys --------------------------------------------------
    for (const mod of selected) {
      if (mod.needsEngine && !site.engine) {
        console.log(`  SKIP   ${mod.id}`);
        console.log(`         "${mod.claim}"`);
        console.log(
          `         needs /replay-engine/, which is not in this tree. A session that` +
            ` cannot start cannot step, and passing here would be a claim about nothing.`,
        );
        console.log(`         remedy: cd client && ./hydrate/fetch-engine.sh dist/replay-engine`);
        console.log("");
        report.journeys.push({ id: mod.id, verdict: "skipped", reason: "no replay engine" });
        failures += 1; // a skip is not a pass. See the verdict block.
        continue;
      }

      const j = new Journey(mod.id, mod.claim, mod.spec ?? "(no spec cited)");
      try {
        await mod.run({ browser, site, j });
      } catch (err) {
        j.expect(false, "the journey threw", String(err && err.stack ? err.stack : err));
      }

      const declared = mod.assertions;
      const countOk = declared === undefined || declared === j.total;
      // A name collision is a FAILURE of the journey and not a note about it:
      // it disarms every mutation arm aimed at the shorter text, and a journey
      // whose arms cannot run is a journey nothing has demonstrated to bite.
      // Folded in beside the declared-count check because it is the same kind
      // of defect — the run looks correct and the machinery underneath it is
      // silently not running.
      const namesOk = nameCollisions(j).length === 0;
      const green = j.passed && countOk && namesOk;
      const ledgered = Object.prototype.hasOwnProperty.call(ledger, mod.id);

      console.log(renderJourney(j, declared));
      checks += j.total;

      if (ledgered) {
        const entry = ledger[mod.id];
        if (green) {
          console.log(
            `         [FAILED] this journey is in ledger.json as known-red and it is GREEN.` +
              ` The defect is fixed; remove the entry. (${entry.reason})`,
          );
          failures += 1;
          // `records` on THIS branch too. It was the one verdict that omitted
          // them, and `selftest.mjs` — which finds its arm's assertion by name
          // in the report — reported NEVER RAN for two arms whose journeys had
          // simply become ledgered-and-green. A verdict that carries less
          // evidence than its neighbours is a verdict that reads as a different
          // failure than it is.
          report.journeys.push({
            id: mod.id,
            verdict: "ledgered-but-green",
            assertions: j.total,
            declared: declared ?? null,
            records: j.records,
          });
        } else {
          console.log(`         LEDGERED RED — ${entry.reason}`);
          console.log(`                        closed by: ${entry.closed_by}`);
          report.journeys.push({
            id: mod.id,
            verdict: "ledgered-red",
            assertions: j.total,
            declared: declared ?? null,
            records: j.records,
          });
        }
      } else if (!green) {
        failures += 1;
        report.journeys.push({
          id: mod.id,
          verdict: "red",
          assertions: j.total,
          declared: declared ?? null,
          // EVERY record, not only the failures. `selftest.mjs` asks whether a
          // mutation flipped the ASSERTION WRITTEN FOR IT, which needs the
          // greens too — a mutation that reddens a journey by breaking some
          // other assertion has not demonstrated anything about the one it
          // claims to cover.
          records: j.records,
        });
      } else {
        report.journeys.push({
          id: mod.id,
          verdict: "green",
          assertions: j.total,
          declared: declared ?? null,
          records: j.records,
        });
      }
      console.log("");
    }
  } finally {
    if (browser) await browser.close().catch(() => {});
    await site.close().catch(() => {});
  }

  // ---- the verdict says WHICH fact the number is ------------------------
  const green = report.journeys.filter((r) => r.verdict === "green").length;
  const red = report.journeys.filter((r) => r.verdict === "red").length;
  const ledgeredRed = report.journeys.filter((r) => r.verdict === "ledgered-red").length;
  const skipped = report.journeys.filter((r) => r.verdict === "skipped").length;

  console.log(`${checks} assertion(s) across ${report.journeys.length} journey(s)`);
  console.log(
    `  ${green} green, ${red} red, ${ledgeredRed} ledgered red, ${skipped} skipped`,
  );
  if (args.json) await writeFile(args.json, JSON.stringify(report, null, 2));

  if (failures > 0) {
    console.log("RESULT: FAILED");
    process.exitCode = 1;
    return;
  }
  console.log("  Every journey not in the ledger reaches its claim on the artefact CI");
  console.log("  deploys. What is NOT claimed: nothing here drives a deployed hostname,");
  console.log("  and nothing here judges the codetracer product — see tools/journeys/README.md.");
  console.log("RESULT: OK");
}

main().catch((err) => {
  console.error(String(err && err.message ? err.message : err));
  process.exitCode = err && err.exitCode ? err.exitCode : 1;
});
