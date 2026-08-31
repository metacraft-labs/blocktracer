#!/usr/bin/env node
/**
 * ingest-selftest.mjs — proof that `ingest-review.mjs` refuses.
 *
 * The ingest tool exists so that no human hand writes a ledger entry. That is
 * only worth anything if the tool says NO to the entries a hand would write,
 * so every refusal below turns a report that is nearly right into a rejection,
 * and the last case checks the one property the gate cannot check for itself:
 * that all six reviewers of a triple looked at the same bytes.
 *
 * Structured as: a base report that MUST be accepted, then one mutation per
 * rule. If the base stopped being accepted the whole file would still "pass"
 * by refusing everything, so the base case is asserted first and separately.
 *
 * Every case runs against a SYNTHETIC ledger under the test's own temp
 * directory (`--ledger`, plus `--dry-run`), and never against
 * reviews/ledger.json — see `ingestInto` for why, and for the guard that keeps
 * it that way. The suite's verdict is a function of the reports it plants and
 * of the capture on disk, and of nothing else.
 *
 *   node tools/capture/ingest-selftest.mjs
 */

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, statSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "../..");
const TOOL = join(HERE, "ingest-review.mjs");

// A triple whose image really exists, so the base case is about the REPORT
// rather than about a missing capture.
const VIEW = "debugger", SIZE = "wide", THEME = "dark";
const IMAGE = join(ROOT, `screenshots/${VIEW}__${SIZE}__${THEME}.png`);

const base = (over = {}) => ({
  view: VIEW, size: SIZE, theme: THEME, reviewer: "L1",
  expectedElements: "present", missing: [], rating: 7,
  findings: [{
    id: `${VIEW}/${SIZE}/${THEME}/L1/1`,
    severity: "P2", location: "call trace, cost column",
    finding: "The unit repeats on every row.", criterion: "B7",
  }],
  ...over,
});

// The real ledger, named ONLY so this file can prove it never touches it.
const REAL_LEDGER = join(ROOT, "reviews/ledger.json");

let dir, DEFAULT_LEDGER, pass = 0, fail = 0;

/**
 * An empty, well-formed ledger — the fixed starting state every case that does
 * not stage one of its own is run against.
 *
 * `gateScope` and `reviews` are empty deliberately. `ingest-review.mjs` runs
 * its cross-reviewer hash check over the WHOLE ledger and not just the batch
 * in hand, so a ledger with reviews in it decides the outcome of the cases
 * below — which is precisely the coupling this constant removes.
 */
const emptyLedger = (revision) => JSON.stringify({
  ledgerRevision: revision,
  gateScope: [],
  reviews: [],
  resolutions: [],
  referenceParity: [],
  signOffs: [],
}, null, 2) + "\n";

function ingestInto(ledger, files) {
  // EVERY case names its own synthetic ledger — there is no default, and this
  // refusal is the guard that keeps it that way.
  //
  // Until 2026-08-29 the `ingest()` helper below passed `null` here, which let
  // `ingest-review.mjs` fall back to reviews/ledger.json. That made the suite's
  // result a function of the REAL ledger's agreement with the REAL screenshots:
  // the tool's cross-reviewer check reads every review already in the ledger,
  // so any visual change that recaptured `debugger__wide__dark.png` without a
  // re-review turned this file red — 16/18, the base case and the two-reviewer
  // acceptance — while `ingest-review.mjs`, the tool actually under test, was
  // working exactly as specified. A self-test that reddens for a reason outside
  // the thing it tests is a self-test that gets ignored.
  //
  // The cross-reviewer cases below already did the right thing; `--ledger`
  // exists on the tool for exactly this reason. Now every case does.
  //
  // `--dry-run` throughout as well: a self-test that could write a ledger would
  // be the hand-written entry this whole tool exists to prevent. Belt and
  // braces — dry-run stops the WRITE, a synthetic path stops the READ.
  if (!ledger) {
    throw new Error(
      "ingest-selftest: a case was run with no --ledger, which would fall back to " +
      "reviews/ledger.json and couple this suite to the real ledger's state. " +
      "Every case must name a synthetic ledger under the test's temp dir.",
    );
  }
  if (resolve(ledger) === REAL_LEDGER) {
    throw new Error(
      "ingest-selftest: a case named reviews/ledger.json. The suite must not read " +
      "or write the real ledger.",
    );
  }
  const args = [TOOL, "--dry-run", "--ledger", ledger];
  for (const f of files) args.push("--report", f);
  try {
    execFileSync("node", args, { encoding: "utf8", stdio: "pipe" });
    return { ok: true, out: "" };
  } catch (e) {
    return { ok: false, out: (e.stderr || "") + (e.stdout || "") };
  }
}

const ingest = (files) => ingestInto(DEFAULT_LEDGER, files);

/** `null` writes a report with no json block at all — a path no mutated
 *  object can express. */
function run(report) {
  const f = join(dir, `r-${Math.random().toString(36).slice(2)}.md`);
  writeFileSync(f, report === null
    ? "prose only, and no block\n"
    : "prose\n\n```json\n" + JSON.stringify(report, null, 2) + "\n```\n");
  return ingest([f]);
}

function accepts(name, report) {
  const r = run(report);
  if (r.ok) { console.log(`  ✓ ${name}`); pass++; }
  else { console.log(`  ✗ ${name} — refused, and should not have been:\n      ${r.out.trim()}`); fail++; }
}

function refuses(name, report, expect) {
  const r = run(report);
  if (r.ok) { console.log(`  ✗ ${name} — ACCEPTED, and must not have been`); fail++; }
  else if (expect && !r.out.includes(expect)) {
    console.log(`  ✗ ${name} — refused for the wrong reason (wanted ${JSON.stringify(expect)}):\n      ${r.out.trim()}`);
    fail++;
  } else { console.log(`  ✓ ${name}`); pass++; }
}

function main() {
  if (!existsSync(IMAGE)) {
    console.error(`SKIP-PROOF FAILURE — ${IMAGE} does not exist, so the base case could not be` +
      ` distinguished from a refusal. Capture the debugger view first; this self-test refuses` +
      ` to report green over an absent subject.`);
    return 1;
  }
  dir = mkdtempSync(join(tmpdir(), "bt-ingest-selftest-"));
  // The ledger every case that does not stage its own is run against. Empty, so
  // the suite's outcome depends on the REPORT under test and on nothing else.
  DEFAULT_LEDGER = join(dir, "default-ledger.json");
  writeFileSync(DEFAULT_LEDGER, emptyLedger("selftest.0"));
  // Recorded so the run can prove it left the real ledger alone.
  const realBefore = existsSync(REAL_LEDGER) ? readFileSync(REAL_LEDGER) : null;
  try {
    console.log("the base case — a well-formed report is ACCEPTED");
    accepts("a report that is right in every respect", base());

    console.log("\nthe refusals — one per rule");
    refuses("a finding id that names a different reviewer",
      base({ findings: [{ ...base().findings[0], id: `${VIEW}/${SIZE}/${THEME}/L4/1` }] }),
      "does not start with");
    refuses("a finding id that names a different theme",
      base({ findings: [{ ...base().findings[0], id: `${VIEW}/${SIZE}/light/L1/1` }] }),
      "does not start with");
    refuses("a presence FAILURE rated above the §4 cap",
      base({ expectedElements: "missing", missing: ["the current-line indicator"], rating: 9 }),
      "caps it at 4");
    refuses("a presence failure that names nothing missing",
      base({ expectedElements: "missing", missing: [] }), "'missing' names nothing");
    refuses("a 'present' verdict that also names something missing",
      base({ missing: ["something"] }), "but 'missing' names");
    refuses("the adversarial reviewer with more than one finding",
      base({
        reviewer: "ADV", rating: null,
        findings: [
          { id: `${VIEW}/${SIZE}/${THEME}/ADV/1`, severity: "P2", location: "a", finding: "b" },
          { id: `${VIEW}/${SIZE}/${THEME}/ADV/2`, severity: "P2", location: "c", finding: "d" },
        ],
      }), "allows exactly one");
    refuses("a review of a capture that does not exist",
      base({ size: "tablet", findings: [{ ...base().findings[0], id: `${VIEW}/tablet/${THEME}/L1/1` }] }),
      "does not exist");
    refuses("a review naming an image that is not its own triple's",
      base({ image: "screenshots/home__wide__dark.png" }), "is not this triple's image");
    refuses("an unknown reviewer", base({ reviewer: "L9" }), "unknown reviewer");
    refuses("an unknown view", base({ view: "not-a-view" }), "unknown view");
    refuses("a finding with no location",
      base({ findings: [{ id: `${VIEW}/${SIZE}/${THEME}/L1/1`, severity: "P2", finding: "y" }] }),
      "has no location");
    refuses("a finding with a severity that is not a severity",
      base({ findings: [{ ...base().findings[0], severity: "critical" }] }), "expect P1|P2|P3");
    refuses("a report with no json block at all", null, "no ```json block");

    // G2's own property: the six reviewers of a triple must have seen ONE
    // image. The gate cannot establish this — by the time it runs, the capture
    // may have been regenerated any number of times, and every review still
    // looks well-formed. Only ingest sees the bytes.
    //
    console.log("\nthe cross-reviewer check — G2's 'the exact image', on bytes");
    {
      const a = join(dir, "same-a.md"), b = join(dir, "same-b.md");
      writeFileSync(a, "```json\n" + JSON.stringify(base({ reviewer: "L1" })) + "\n```\n");
      writeFileSync(b, "```json\n" + JSON.stringify(base({
        reviewer: "L2", findings: [{ ...base().findings[0], id: `${VIEW}/${SIZE}/${THEME}/L2/1` }],
      })) + "\n```\n");
      const both = ingest([a, b]);
      if (both.ok) { console.log("  ✓ two reviewers of one capture are accepted together"); pass++; }
      else { console.log(`  ✗ two reviewers of one capture were refused:\n      ${both.out.trim()}`); fail++; }
    }
    // …and the REFUSAL that check exists for, which the acceptance above does
    // not exercise. This is the single property the whole tool is for — the
    // gate cannot check it, so if it is not checked here it is not checked at
    // all — and it was the one branch with no case behind it.
    //
    // The mismatch cannot be produced in a single run (every review in one run
    // hashes the same file at the same moment), so it is staged against a
    // synthetic ledger already holding a reviewer whose recorded hash is not
    // the file's — exactly the state a recapture between two ingests leaves.
    {
      const synth = join(dir, "ledger.json");
      writeFileSync(synth, JSON.stringify({
        ledgerRevision: "selftest.1",
        gateScope: [{ view: VIEW, size: SIZE, theme: THEME }],
        reviews: [{
          view: VIEW, size: SIZE, theme: THEME,
          image: `screenshots/${VIEW}__${SIZE}__${THEME}.png`,
          imageSha256: "0".repeat(64),   // a capture that is not the one on disk
          reviewer: "L3", expectedElements: "present", missing: [], rating: 7, findings: [],
        }],
        resolutions: [], referenceParity: [], signOffs: [],
      }, null, 2) + "\n");
      const f = join(dir, "mismatch.md");
      writeFileSync(f, "```json\n" + JSON.stringify(base({ reviewer: "L1" })) + "\n```\n");
      const r = ingestInto(synth, [f]);
      if (!r.ok && r.out.includes("disagree about what they looked at") && r.out.includes("STALE")) {
        console.log("  ✓ a reviewer whose hash is not the file's is refused, and named STALE"); pass++;
      } else if (r.ok) {
        console.log("  ✗ two reviewers over TWO different captures were accepted — the ledger" +
          " would claim six reviewers agreed on bytes only one of them saw"); fail++;
      } else {
        console.log(`  ✗ refused for the wrong reason:\n      ${r.out.trim()}`); fail++;
      }
    }
    // The base case for that path: the same synthetic ledger, with the hash it
    // should have, must be ACCEPTED — or the case above would pass for a tool
    // that refuses every ingest against a non-default ledger.
    {
      const synth = join(dir, "ledger-ok.json");
      writeFileSync(synth, JSON.stringify({
        ledgerRevision: "selftest.1",
        gateScope: [{ view: VIEW, size: SIZE, theme: THEME }],
        reviews: [{
          view: VIEW, size: SIZE, theme: THEME,
          image: `screenshots/${VIEW}__${SIZE}__${THEME}.png`,
          imageSha256: createHash("sha256").update(readFileSync(IMAGE)).digest("hex"),
          reviewer: "L3", expectedElements: "present", missing: [], rating: 7, findings: [],
        }],
        resolutions: [], referenceParity: [], signOffs: [],
      }, null, 2) + "\n");
      const f = join(dir, "match.md");
      writeFileSync(f, "```json\n" + JSON.stringify(base({ reviewer: "L1" })) + "\n```\n");
      const r = ingestInto(synth, [f]);
      if (r.ok) { console.log("  ✓ a reviewer whose hash IS the file's is accepted alongside it"); pass++; }
      else { console.log(`  ✗ a matching hash was refused:\n      ${r.out.trim()}`); fail++; }
    }
    // The hash a review carries is taken from the file AT INGEST TIME, so it
    // is only the reviewer's bytes if nothing recaptured in between — and
    // fix-then-recapture is exactly what happens between rounds. A report
    // older than the capture it names cannot be a report about that capture.
    {
      const f = join(dir, "predates.md");
      writeFileSync(f, "```json\n" + JSON.stringify(base()) + "\n```\n");
      // Backdate the REPORT to before the image was written.
      const old = statSync(IMAGE).mtimeMs - 60_000;
      utimesSync(f, old / 1000, old / 1000);
      const r = ingest([f]);
      if (!r.ok && r.out.includes("captured AFTER this report was written")) {
        console.log("  ✓ a report written BEFORE the capture it names is refused"); pass++;
      } else if (r.ok) {
        console.log("  ✗ a report predating its capture was ACCEPTED — the ledger would" +
          " stamp a fresh capture's hash onto a review of the image it replaced"); fail++;
      } else {
        console.log(`  ✗ refused for the wrong reason:\n      ${r.out.trim()}`); fail++;
      }
    }

    // ── `--verify-round`: every report FILE reached the ledger ─────────────
    //
    // `--verify` walks the LEDGER and asks whether each entry's report is
    // unchanged. It cannot see a report that was never ingested, because there
    // is no entry to iterate over — so a round with a refused report looks
    // complete from that direction while a reviewer's judgement is missing from
    // the evidence the gate decides over. In vd9-r1 that happened: a report was
    // written with its json fence opened and never closed, `ingest` refused it,
    // and nothing downstream would have noticed if the refusal had scrolled by.
    //
    // Each case doctors ONE property of an otherwise-good round and asserts the
    // check says no, with the undoctored round asserted to PASS in the same
    // breath so a check that rejected everything could not satisfy this.
    console.log("\n--verify-round — a report that exists is not a report that counted");
    {
      const roundDir = join(dir, "round");
      mkdirSync(roundDir, { recursive: true });

      // One good report on disk, and a synthetic ledger that names it exactly
      // as `ingest` would: `reportPath` relative to ROOT, `reportSha256` over
      // the bytes.
      const write = (name, report) => {
        const p = join(roundDir, name);
        writeFileSync(p, "prose\n\n```json\n" + JSON.stringify(report, null, 2) + "\n```\n");
        return p;
      };
      const entryFor = (p, report) => ({
        view: report.view, size: report.size, theme: report.theme,
        reviewer: report.reviewer, expectedElements: report.expectedElements,
        image: `screenshots/${report.view}__${report.size}__${report.theme}.png`,
        imageSha256: "0".repeat(64),
        reportPath: relative(ROOT, p),
        reportSha256: createHash("sha256").update(readFileSync(p)).digest("hex"),
        findings: report.findings ?? [], rating: report.rating ?? null, missing: [],
      });
      const ledgerWith = (name, entries) => {
        const p = join(dir, name);
        writeFileSync(p, JSON.stringify({
          ledgerRevision: "selftest.1", gateScope: [], reviews: entries,
          resolutions: [], referenceParity: [], signOffs: [],
        }, null, 2) + "\n");
        return p;
      };
      const verifyRound = (ledger, rd) => {
        try {
          execFileSync("node", [TOOL, "--ledger", ledger, "--verify-round", rd],
            { encoding: "utf8", stdio: "pipe" });
          return { ok: true, out: "" };
        } catch (e) { return { ok: false, out: (e.stderr || "") + (e.stdout || "") }; }
      };
      const decides = (name, ledger, rd, expect) => {
        const r = verifyRound(ledger, rd);
        if (r.ok) { console.log(`  ✗ ${name} — PASSED, and must not have`); fail++; }
        else if (expect && !r.out.includes(expect)) {
          console.log(`  ✗ ${name} — failed for the wrong reason (wanted ${JSON.stringify(expect)}):\n      ${r.out.trim().split("\n").slice(-6).join("\n      ")}`);
          fail++;
        } else { console.log(`  ✓ ${name}`); pass++; }
      };

      const rA = base({ reviewer: "L1", findings: [] });
      const pA = write("good__L1.json", rA);
      const goodLedger = ledgerWith("lg-good.json", [entryFor(pA, rA)]);

      // BASE CASE — must PASS, so nothing below passes by rejecting everything.
      {
        const r = verifyRound(goodLedger, roundDir);
        if (r.ok) { console.log("  ✓ an undoctored round passes (the base case)"); pass++; }
        else { console.log(`  ✗ an undoctored round FAILED:\n      ${r.out.trim().split("\n").slice(-6).join("\n      ")}`); fail++; }
      }

      // 1. A file that does not parse — the vd9-r1 case, an unclosed fence.
      {
        const p = join(roundDir, "truncated__L2.json");
        writeFileSync(p, "prose\n\n```json\n" + JSON.stringify(base({ reviewer: "L2" }), null, 2) + "\n");
        decides("an unparseable report is caught, not skipped", goodLedger, roundDir, "UNPARSEABLE");
        rmSync(p);
      }

      // 2. A parseable report that no ledger entry names — refused at ingest,
      //    or simply never passed to it. This is the one `--verify` is blind to.
      {
        const rB = base({ reviewer: "L3" });
        const pB = write("orphan__L3.json", rB);
        decides("a report that never reached the ledger is caught", goodLedger, roundDir,
          "NEVER REACHED THE LEDGER");
        rmSync(pB);
      }

      // 3. An entry that names the file but carries fewer findings than the
      //    block does — a partially merged entry mistaken for a whole one.
      {
        const rC = base({ reviewer: "L4", findings: [
          { id: `${VIEW}/${SIZE}/${THEME}/L4/1`, severity: "P2", location: "a", finding: "b" },
          { id: `${VIEW}/${SIZE}/${THEME}/L4/2`, severity: "P2", location: "c", finding: "d" },
        ] });
        const pC = write("short__L4.json", rC);
        const e = entryFor(pC, rC);
        e.findings = e.findings.slice(0, 1);
        const shortLedger = ledgerWith("lg-short.json", [entryFor(pA, rA), e]);
        decides("a ledger entry with fewer findings than its report is caught",
          shortLedger, roundDir, "FINDING COUNT DISAGREES");
        rmSync(pC);
      }

      // 3b. A report whose SLOT is held by a later round's file is SUPERSEDED,
      //     not un-ingested, and must not fail. Without this the check goes red
      //     on every completed round the moment the next one re-reviews one of
      //     its triples — `vd9-r1` went clean -> "12 of 42 unaccounted for" for
      //     exactly that reason — and a check that breaks whenever the campaign
      //     progresses is one people learn to skip.
      {
        const rD = base({ reviewer: "L5" });
        const pD = write("older__L5.json", rD);
        // The later round's file must EXIST, because `--verify` runs first and
        // would otherwise report the ledger's report as missing — a real failure
        // for a different reason, which would mask what this case is testing.
        const laterDir = join(dir, "a-later-round");
        mkdirSync(laterDir, { recursive: true });
        const pLater = join(laterDir, "newer__L5.json");
        writeFileSync(pLater, "prose\n\n```json\n" + JSON.stringify(rD, null, 2) + "\n```\n");
        // The ledger's entry for this triple+lens points at that DIFFERENT file,
        // as it would after a later round replaced it.
        const eD = entryFor(pLater, rD);
        const supLedger = ledgerWith("lg-superseded.json", [entryFor(pA, rA), eD]);
        const r = verifyRound(supLedger, roundDir);
        if (r.ok) { console.log("  ✓ a report superseded by a later round passes, and is named as superseded"); pass++; }
        else { console.log(`  ✗ a superseded report FAILED, which would redden every finished round:\n      ${r.out.trim().split("\n").slice(-6).join("\n      ")}`); fail++; }
        rmSync(pD);
      }

      // 4. An empty round directory is NO VERDICT, not a pass — the same rule
      //    `--verify` applies to a ledger with nothing to check.
      {
        const empty = join(dir, "round-empty");
        mkdirSync(empty, { recursive: true });
        decides("an empty round directory is no verdict, not a pass",
          goodLedger, empty, "NO VERDICT");
      }
    }

    // ── The coupling to the real ledger, and the guard that closes it ──────
    //
    // These three are about the SUITE, not about `ingest-review.mjs`. Every
    // case above is only a test of the tool if its outcome is decided by the
    // report it plants; while `ingest()` fell through to reviews/ledger.json,
    // two of them were decided by whether the real ledger happened to agree
    // with the real screenshots, and went red on a recapture the tool had
    // nothing to do with.
    console.log("\nthe suite's own isolation — no case may reach the real ledger");
    {
      const f = join(dir, "isolation.md");
      writeFileSync(f, "```json\n" + JSON.stringify(base()) + "\n```\n");

      // 1. The fallback that produced the coupling is refused outright, so it
      //    cannot be reintroduced by an `ingestInto(null, …)` in a later case.
      let threw = null;
      try { ingestInto(null, [f]); } catch (e) { threw = e.message; }
      if (threw && threw.includes("no --ledger")) {
        console.log("  ✓ a case with no --ledger is refused before it can run"); pass++;
      } else {
        console.log("  ✗ a case with no --ledger was allowed to run — it would fall back to" +
          " reviews/ledger.json and couple the suite to it again"); fail++;
      }

      // 2. …and so is naming the real ledger explicitly, which is the same
      //    coupling written the long way round.
      threw = null;
      try { ingestInto(REAL_LEDGER, [f]); } catch (e) { threw = e.message; }
      if (threw && threw.includes("must not read or write the real ledger")) {
        console.log("  ✓ a case naming reviews/ledger.json is refused before it can run"); pass++;
      } else {
        console.log("  ✗ a case was allowed to name reviews/ledger.json"); fail++;
      }
    }
    // 3. The independent confirmation, on bytes: whatever the cases above did,
    //    the real ledger is exactly as it was. `--dry-run` should already
    //    guarantee this; the point of checking is that it is guaranteed by an
    //    observation rather than by a flag nobody re-reads.
    {
      const after = existsSync(REAL_LEDGER) ? readFileSync(REAL_LEDGER) : null;
      const same = realBefore === null ? after === null : after !== null && after.equals(realBefore);
      if (same) {
        console.log("  ✓ reviews/ledger.json is byte-identical after the run"); pass++;
      } else {
        console.log("  ✗ reviews/ledger.json CHANGED during the self-test — the suite wrote the" +
          " one file ingest-review.mjs exists to be the only writer of"); fail++;
      }
    }

    console.log(`\n${fail === 0 ? "PASS" : "FAIL"} — ${pass}/${pass + fail}`);
    return fail === 0 ? 0 : 1;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

process.exit(main());
