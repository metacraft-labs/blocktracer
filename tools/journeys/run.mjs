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
import { fileURLToPath, pathToFileURL } from "node:url";
import { dirname, join, resolve } from "node:path";

import { Journey, renderJourney, nameCollisions } from "./lib/harness.mjs";
import { openBrowser, readFacts, visit, UNCAUGHT } from "./lib/probe.mjs";
import { openSite, serveDist } from "./lib/site.mjs";
import { stageEngine, engineIdentity, bundleIdentity } from "./lib/engine.mjs";
import { transactions, landingOf } from "./lib/corpus.mjs";

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
    // `assertions` IS PART OF THE REQUIRED SHAPE, not an optional annotation.
    //
    // A file that omitted it and recorded nothing came out GREEN. `j.total` was
    // 0, `[].every(…)` is true so `j.passed` was true, and the count check read
    // `declared === undefined || declared === j.total` — the undefined branch
    // waved it through. Three vacuous trues in a row, and a journey that
    // asserts nothing reported as a journey that reaches its claim. That is
    // this layer's own signature defect — a check that passes by not running —
    // arriving through its front door, and rule 3 above is written against
    // exactly it one level down.
    //
    // The declared count is what makes a journey falsifiable. It is the number
    // that goes red when an arm silently stops executing, which is the failure
    // `selftest.mjs` exists to find; a journey with no declared count is
    // outside that instrument entirely.
    if (typeof m.assertions !== "number" || !Number.isFinite(m.assertions) || m.assertions < 1) {
      throw Object.assign(
        new Error(
          `${f} is in journeys/ but exports assertions = ${JSON.stringify(m.assertions ?? null)}.\n` +
            `    Every journey must declare how many assertions it makes, and it must be at least 1.\n` +
            `    A journey that declares none cannot be shown to have run: zero assertions is a\n` +
            `    vacuous pass, and it would report GREEN over nothing.\n` +
            `    remedy: export const assertions = <n>;  — kept equal to the number the run reports.`,
        ),
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

/**
 * ARM II — PROVE THE ENGINE CAN OPEN THIS CORPUS, THEN JUDGE THE PRODUCT.
 *
 * Arm I refuses to judge when the BROWSER cannot render. This is the same
 * refusal for the third artefact, and it exists because that artefact is the
 * one nothing in this repository pins: `client/hydrate/fetch-engine.sh` takes
 * whatever the publisher is serving, deliberately, so the engine changes under
 * this suite without a commit.
 *
 * WHAT IT COST TO NOT HAVE THIS. Measured at `8d1efe1a`, one tree, one bundle,
 * one corpus, two engines:
 *
 *   wasm cf79c4bf9854465b…   11 green → 21 green.  Journey 07 GREEN, 2 of 6
 *                            hops classified over 6 values.
 *   wasm 3009b9892fa181cf…   ELEVEN journeys RED, 416 assertions instead of
 *                            488. Journey 07 RED, 0 hops over 0 values.
 *
 * The engine's own answer, asked on the wire, is unambiguous and was in nobody's
 * transcript:
 *
 *   CTFS from_bytes failed for "trace/trace.ct": new-format container
 *   advertises steps.dat but no seekable step stream could be opened;
 *   the container is inconsistent
 *
 * This corpus carries containers in two formats — `C0DE72ACE2 03 0000` (16, the
 * chain captures) and `C0DE72ACE2 04 0001` (25, every Noir recording, which is
 * every recording that publishes SOURCE). The published engine reads the first
 * and rejects the second, so half the corpus has no trace open at all. Eleven
 * journeys then report, in the product's own vocabulary, that panes are empty
 * and values never arrive — which is true, and is not a statement about the
 * product. Two of those eleven are the only journeys that can judge whether a
 * value can be traced to its origin.
 *
 * AND THE PAGE DOES NOT KNOW. `phase=ready`, twenty-four live controls, and a
 * State pane full of the exporter's rows: every settle condition this suite
 * uses is satisfied by a session whose engine never opened its recording. The
 * failed `configurationDone` arrives AFTER a successful one, second, on the
 * wire — so nothing on screen says so and only the worker traffic does.
 *
 * SO IT IS ASKED ON THE WIRE, AND ONE SUBJECT PER FORMAT. A gate that probed a
 * single session would have passed on a chain capture and judged the whole
 * suite anyway, which is this repository's signature defect — "a list cannot
 * notice a chain nobody added it to" — wearing a gate's uniform. The formats
 * are read off the containers the exporter actually wrote, so a corpus that
 * gains a third one is probed on the next run with no edit here.
 *
 * EXIT 2, NOT 1. A red journey is a claim about the product. This is a refusal
 * to make one, and the two must not share an exit code — the whole reason this
 * layer reports three verdicts and not two.
 */
async function engineArm(browser, site) {
  const all = await transactions(site.root);
  const sessions = all.filter((t) => landingOf(t.phase) === "session" && t.hasListing);
  // One subject per RECORDING KIND, selected by filter and never with a `??`:
  // a corpus that has lost a kind must be visible here as a missing probe, not
  // silently covered by whichever kind survived.
  // THREE KINDS AND NOT TWO. "publishes source" and "recorded values on that
  // source" came apart when the first rung-2 chain capture landed — see the
  // "third category" header in `lib/corpus.mjs`. Probing only the two-valued
  // split meant the engine was never opened against the kind of container that
  // now sorts first in the corpus, which is exactly the hole this arm exists to
  // refuse ("a list cannot notice a chain nobody added it to").
  const groups = [
    [
      "recordings with source and values recorded on it",
      sessions.filter((t) => t.hasSource && t.hasRecordedValues),
    ],
    [
      "recordings that display source and recorded no values",
      sessions.filter((t) => t.hasSource && !t.hasRecordedValues),
    ],
    ["recordings that publish no source", sessions.filter((t) => !t.hasSource)],
  ];
  const out = [];
  for (const [label, list] of groups) {
    if (list.length === 0) {
      out.push({ label, subject: null, opened: false, error: "no subject of this kind in the corpus" });
      continue;
    }
    const subject = list[0];
    const live = await visit(browser, site.origin, subject.debugPath, {
      settle: (f) => f.phase === "ready" && f.controlsLive > 0,
    });
    try {
      const answer = await live.page.evaluate(async () => {
        const w = globalThis.__btReplayWorker;
        if (!w) return { opened: false, error: "no replay worker on the page" };
        const s = 990001;
        return await new Promise((resolve) => {
          const onMsg = (e) => {
            let m = e.data;
            if (typeof m === "string") {
              const t = m.trim();
              if (!t.startsWith("{")) return;
              try { m = JSON.parse(t); } catch { return; }
            }
            if (m && m.type === "response" && m.request_seq === s) {
              w.removeEventListener("message", onMsg);
              resolve({ opened: !!m.success, error: String(m.message ?? "") });
            }
          };
          w.addEventListener("message", onMsg);
          setTimeout(() => {
            w.removeEventListener("message", onMsg);
            resolve({ opened: false, error: "the engine did not answer `threads` within 30s" });
          }, 30000);
          // `threads` and not `ct/load-locals`: it is the cheapest request that
          // requires a trace to be OPEN, and its answer does not depend on the
          // position, the language or whether anything is bound — so a failure
          // here is about the container and nothing else.
          w.postMessage({ seq: s, type: "request", command: "threads", arguments: {} });
        });
      });
      out.push({ label, subject: subject.debugPath, ...answer });
    } finally {
      await live.page.close();
    }
  }
  return out;
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
  // THE BUNDLE NAMES ITSELF, for the reason `lib/engine.mjs:bundleIdentity`
  // gives: this runner does not rebuild, so the only honest statement about
  // which bytes were judged is a hash taken here, off the tree about to be
  // served.
  const bundleId = await bundleIdentity(args.dist);
  console.log(
    `  bundle:        ${
      bundleId
        ? `${bundleId.bytes} bytes  sha256 ${bundleId.sha256}`
        : "<no assets/hydrate.js — this tree ships no hydration bundle>"
    }`,
  );
  console.log(
    `  replay engine: ${
      site.engine
        ? `present (staged from ${staged.from})`
        : `ABSENT — stepping journeys will SKIP, and a skip is not a pass.\n                 ${staged.remedy ?? ""}`
    }`,
  );
  // THE ENGINE IS NAMED, NOT JUST COUNTED PRESENT. It is the one artefact this
  // repository does not pin, it changes under the suite, and it has already
  // decided a verdict on its own — see `lib/engine.mjs:engineIdentity`.
  const engineId = site.engine ? await engineIdentity(args.dist) : null;
  if (engineId) {
    for (const [f, id] of Object.entries(engineId)) {
      console.log(
        `                 ${f.padEnd(24)} ${
          id ? `${String(id.bytes).padStart(10)} bytes  ${id.sha256.slice(0, 16)}…` : "<missing>"
        }`,
      );
    }
  }
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
  const report = { artefact: site.root, hydrated: true, engine: site.engine, engineIdentity: engineId, bundleIdentity: bundleId, journeys: [] };

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

    // ---- ARM II --------------------------------------------------------
    if (site.engine) {
      console.log("Arm II: prove the engine can open this corpus, before judging the product");
      const opened = await engineArm(browser, site);
      for (const r of opened) {
        console.log(
          `         ${r.opened ? "[OK]    " : "[REFUSED]"} ${r.label}: ${r.subject ?? "—"}`,
        );
        if (!r.opened) console.log(`                   ${r.error}`);
      }
      report.engineOpensCorpus = opened;
      if (opened.some((r) => !r.opened)) {
        console.error("");
        console.error("  The replay engine staged for this run cannot open part of this corpus.");
        console.error("  Every journey that drives one of those recordings would report empty");
        console.error("  panes and absent values — in the PRODUCT's vocabulary, for a reason");
        console.error("  that is not the product's. Nothing is judged.");
        console.error("");
        console.error("  This is the one artefact this repository does not pin: fetch-engine.sh");
        console.error("  takes what the publisher is serving. So the first question is which");
        console.error("  engine, and the hashes are printed above.");
        console.error("  remedy: stage an engine that reads this corpus");
        console.error("          (node tools/journeys/run.mjs --engine-cache <dir>), or fix the");
        console.error("          container format mismatch upstream. `just journeys-engine`");
        console.error("          re-fetches, and may re-fetch the same broken one.");
        process.exitCode = 2;
        return;
      }
      console.log("");
    }

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
      // NO `declared === undefined ||` SHORT-CIRCUIT. It used to be here, and
      // it made "this journey declared nothing" and "this journey made exactly
      // what it declared" the same green. `discover()` now refuses a file that
      // declares nothing, so `declared` is always a number >= 1; this is the
      // second lock on the same door, so that an undeclared count can never
      // again be read as a satisfied one.
      const countOk = declared === j.total;
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

  // ---- THE UNCAUGHT-ERROR GATE ------------------------------------------
  //
  // A page that threw is a failed page, whatever the journey that loaded it
  // went on to assert about its DOM. This runs over EVERY load the suite made,
  // and it is not something a journey opts into — see `lib/probe.mjs:UNCAUGHT`
  // for why it cannot be, and for the seven-per-load defect that established
  // it.
  //
  // It is deliberately reported per PAGE and not per exception. Seven throws
  // from one broken render is one defect, and a gate that printed a flat total
  // would let a second, unrelated page hide inside a number that was already
  // large. The count is still stated in full — it is what says how bad it is —
  // but the grouping is what says how many things are wrong.
  //
  // NO ALLOWLIST, ON PURPOSE. There is no page in this product that is entitled
  // to throw: §7.0's guarantee is that no state renders less than the
  // pre-hydration page, and an uncaught exception is how that guarantee breaks.
  // Whoever needs an exemption should have to add the mechanism and argue for
  // it in the same commit, rather than find one already built and reach for it.
  const byPage = new Map();
  for (const e of UNCAUGHT) {
    if (!byPage.has(e.path)) byPage.set(e.path, []);
    byPage.get(e.path).push(e);
  }
  report.uncaught = { total: UNCAUGHT.length, pages: byPage.size, errors: UNCAUGHT };
  if (UNCAUGHT.length > 0) {
    console.log("");
    console.log(
      `  [FAILED] ${UNCAUGHT.length} uncaught page error(s) on ${byPage.size} page(s).`,
    );
    console.log(
      `           A load that throws is a failed load. The panes that had not been`,
    );
    console.log(
      `           written when the exception unwound are simply absent, and the`,
    );
    console.log(
      `           statically exported markup underneath them looks identical to a`,
    );
    console.log(`           DOM query — which is why this is gated and not asserted.`);
    for (const [p, es] of byPage) {
      console.log("");
      console.log(`  ── ${p}`);
      console.log(`     ${es.length} uncaught error(s); first:`);
      console.log(`     ${es[0].message}`);
      const stack = es[0].stack || "<no stack on the error object>";
      for (const line of stack.split("\n").slice(0, 12)) {
        console.log(`       ${line}`);
      }
      const others = [...new Set(es.slice(1).map((e) => e.message))];
      if (others.length) {
        console.log(`     other distinct message(s) on this page:`);
        for (const m of others) console.log(`       ${m}`);
      }
    }
    failures += 1;
  }

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

// Run only when invoked directly, so that `discover()` can be exercised on its
// own. Same reason and same shape as `tools/capture/gate.mjs`: a module that
// runs a whole suite on import cannot be tested, and the rule this file now
// enforces — every journey declares at least one assertion — is exactly the
// kind of refusal that must be demonstrated to fire rather than assumed to.
// A run needs an exported site and a browser; the discovery rule does not.
// `pathToFileURL`, not string concatenation with "file://". If the comparison
// were ever to miss — one percent-encoded character in the checkout path is
// enough — `just journeys` would run NOTHING and exit 0. A guard whose failure
// mode is a silent clean sweep is the thing this file was written against, so
// it is built out of the resolver rather than out of string formatting.
export { discover };

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((err) => {
    console.error(String(err && err.message ? err.message : err));
    process.exitCode = err && err.exitCode ? err.exitCode : 1;
  });
}
