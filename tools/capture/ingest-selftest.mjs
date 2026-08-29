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
 *   node tools/capture/ingest-selftest.mjs
 */

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync, statSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";
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

let dir, pass = 0, fail = 0;

function ingestInto(ledger, files) {
  // `--dry-run` throughout: a self-test that could write the ledger would be
  // the hand-written entry this whole tool exists to prevent.
  const args = [TOOL, "--dry-run"];
  if (ledger) args.push("--ledger", ledger);
  for (const f of files) args.push("--report", f);
  try {
    execFileSync("node", args, { encoding: "utf8", stdio: "pipe" });
    return { ok: true, out: "" };
  } catch (e) {
    return { ok: false, out: (e.stderr || "") + (e.stdout || "") };
  }
}

const ingest = (files) => ingestInto(null, files);

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

    console.log(`\n${fail === 0 ? "PASS" : "FAIL"} — ${pass}/${pass + fail}`);
    return fail === 0 ? 0 : 1;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

process.exit(main());
