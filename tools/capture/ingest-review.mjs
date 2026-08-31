#!/usr/bin/env node
/**
 * ingest-review.mjs — reviewer reports → `reviews/ledger.json`.
 *
 * The ledger is what `gate.mjs` decides over, so the one thing that must never
 * happen to it is a hand-written entry. VD.1's review defeated the old
 * determinism gate exactly that way — by writing a plausible verdict by hand —
 * and the lesson generalises: a file that IS the evidence cannot also be a
 * file anybody edits by hand.
 *
 * So reviews arrive here and nowhere else. Each reviewer writes a report
 * containing the ```json block the brief's §10 Part 2 defines; this tool
 * parses those blocks, checks them, and merges them. It does not invent a
 * field, it does not repair one, and it refuses a report it cannot verify
 * rather than filing a weaker version of it.
 *
 * ## What it checks that the gate cannot
 *
 * The gate validates the ledger's SHAPE. It has no way to know whether the six
 * reviewers of a triple were looking at the same pixels, because by the time it
 * runs, the images may have been recaptured any number of times. G2 says
 * "L1..L5 and ADV have all reviewed the exact image" — "exact" is a claim about
 * bytes, and only ingest is in a position to establish it.
 *
 *   * `--image` must EXIST, and its sha256 is recorded on the review.
 *   * Every review of one {view,size,theme} must carry the SAME sha256. A
 *     reviewer who read a stale capture is refused, not averaged in.
 *   * A re-ingest after a recapture REPLACES that reviewer's entry, and the
 *     mismatch check then rejects the ones that were not re-run — which is
 *     what makes "re-review after a fix" a thing the tooling enforces rather
 *     than a thing the operator remembers.
 *
 * ## What it deliberately does not do
 *
 * It never writes `resolutions`, `referenceParity` or `signOffs`. Those are
 * decisions, not observations: a resolution is an engineer's claim about a
 * change, and parity and sign-off require a named human by definition (brief
 * §11 — "Not an agent"). A tool that could write them would be a tool that
 * could pass the gate on its own.
 *
 * Usage:
 *   node tools/capture/ingest-review.mjs --report <file> [--report <file> …]
 *   node tools/capture/ingest-review.mjs --dir <directory of reports>
 *     [--gate-scope view/size/theme]   add a triple to gateScope
 *     [--revision <id>]                set the ledger revision explicitly
 *     [--ledger <path>]                the ledger to merge into (default
 *                                      reviews/ledger.json). `gate.mjs` takes
 *                                      the same flag; the self-test needs it,
 *                                      because the cross-reviewer refusal can
 *                                      only be provoked against a ledger that
 *                                      ALREADY holds a differing hash, and a
 *                                      self-test may not write the real one.
 *     [--dry-run]                      report, write nothing
 */

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join, resolve, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { VIEWS_BY_ID, SIZES, THEMES, imageName } from "./views.mjs";
import { ALL_LENSES } from "./review-prompt.mjs";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const LEDGER = join(ROOT, "reviews/ledger.json");

const SEVERITIES = ["P1", "P2", "P3"];
const EXPECTED = ["present", "missing", "replaced", "forbidden-present"];

class Refused extends Error {}
const refuse = (msg) => {
  throw new Refused(msg);
};

/** The ```json block of a report, or a refusal naming the file. */
function blockFrom(path) {
  const text = readFileSync(path, "utf8");
  // The LAST fenced json block: a reviewer may quote the schema before
  // filling it in, and the filled-in one is the report.
  const blocks = [...text.matchAll(/```json\s*\n([\s\S]*?)\n```/g)].map((m) => m[1]);
  if (!blocks.length) refuse(`${path}: no \`\`\`json block — a report without one is not a report`);
  const raw = blocks[blocks.length - 1];
  try {
    return JSON.parse(raw);
  } catch (e) {
    refuse(`${path}: the json block does not parse (${e.message})`);
  }
}

function sha256(path) {
  return createHash("sha256").update(readFileSync(path)).digest("hex");
}

/**
 * Everything about one review that can be decided without the ledger.
 * Deliberately strict: a report that is nearly right is refused, because the
 * failure mode being defended against is a plausible-looking entry.
 */
function check(r, path) {
  const at = `${path}`;
  for (const k of ["view", "size", "theme", "reviewer", "expectedElements"]) {
    if (r[k] === undefined) refuse(`${at}: missing '${k}'`);
  }
  if (!VIEWS_BY_ID.has(r.view)) refuse(`${at}: unknown view '${r.view}'`);
  if (!SIZES[r.size]) refuse(`${at}: unknown size '${r.size}'`);
  if (!THEMES.includes(r.theme)) refuse(`${at}: unknown theme '${r.theme}'`);
  if (!ALL_LENSES.includes(r.reviewer)) refuse(`${at}: unknown reviewer '${r.reviewer}'`);
  if (!EXPECTED.includes(r.expectedElements)) {
    refuse(`${at}: expectedElements '${r.expectedElements}' is not one of ${EXPECTED.join("|")}`);
  }

  // The image the reviewer was told to look at, derived rather than trusted:
  // a report naming some other file is a report about some other page.
  const expectImage = `screenshots/${imageName(r.view, r.size, r.theme)}`;
  if (r.image && r.image !== expectImage) {
    refuse(`${at}: image '${r.image}' is not this triple's image (${expectImage})`);
  }
  const abs = join(ROOT, expectImage);
  if (!existsSync(abs)) refuse(`${at}: ${expectImage} does not exist — nothing was reviewed`);

  // The capture must be OLDER than the report. The hash below is taken from
  // the file as it is now, which is only the file the reviewer saw if nothing
  // recaptured it in between — and a fix-then-recapture cycle is exactly what
  // this campaign does between rounds. Without this check the tool would
  // cheerfully stamp a fresh capture's hash onto a review of the image it
  // replaced, and the ledger would claim six reviewers agreed on bytes that
  // only one of them ever saw.
  const imageAt = statSync(abs).mtimeMs;
  const reportAt = statSync(path).mtimeMs;
  if (imageAt > reportAt) {
    refuse(`${at}: ${expectImage} was captured AFTER this report was written ` +
      `(image ${new Date(imageAt).toISOString()}, report ${new Date(reportAt).toISOString()}) — ` +
      `the reviewer cannot have seen these bytes. Re-run the reviewer against the current capture.`);
  }

  // The brief's §4 rule, enforced here as well as at the gate so a bad report
  // never lands rather than landing and failing later.
  if (r.expectedElements !== "present") {
    if (!Array.isArray(r.missing) || !r.missing.length) {
      refuse(`${at}: expectedElements='${r.expectedElements}' but 'missing' names nothing`);
    }
    if (typeof r.rating === "number" && r.rating > 4) {
      refuse(`${at}: expectedElements='${r.expectedElements}' but rating is ${r.rating} (§4 caps it at 4)`);
    }
  } else if (Array.isArray(r.missing) && r.missing.length) {
    refuse(`${at}: expectedElements='present' but 'missing' names ${r.missing.length} item(s)`);
  }

  const findings = r.findings ?? [];
  if (r.reviewer === "ADV" && findings.length > 1) {
    refuse(`${at}: the adversarial reviewer reported ${findings.length} findings; §8 allows exactly one`);
  }
  const prefix = `${r.view}/${r.size}/${r.theme}/${r.reviewer}/`;
  for (const f of findings) {
    if (!f.id) refuse(`${at}: a finding has no id`);
    // The id encodes who found what, where. An id that does not match its own
    // review is an id that cannot be traced back, and the divergence doc's B4
    // check cites these by string.
    if (!f.id.startsWith(prefix)) {
      refuse(`${at}: finding id '${f.id}' does not start with '${prefix}'`);
    }
    if (!SEVERITIES.includes(f.severity)) {
      refuse(`${at}: finding '${f.id}' has severity '${f.severity}' (expect P1|P2|P3)`);
    }
    if (!f.location) refuse(`${at}: finding '${f.id}' has no location`);
    if (!f.finding) refuse(`${at}: finding '${f.id}' has no prose`);
  }

  return {
    view: r.view,
    size: r.size,
    theme: r.theme,
    image: expectImage,
    imageSha256: sha256(abs),
    // THE REPORT'S OWN HASH, and the path it was ingested from.
    //
    // `imageSha256` establishes that six reviewers looked at the same pixels;
    // nothing established that the ledger entry still matches the report it
    // claims to have been built from. That gap is not hypothetical: a reviewer
    // agent that stalled and was relaunched finished 68 minutes later and
    // rewrote its round file AFTER the ingest had run, leaving a committed
    // ledger entry and a round file on disk that disagreed — and every check in
    // the pipeline stayed green, because `gate.mjs` re-hashes the IMAGE and
    // ingest had already finished. The round README's rule that a ledger entry
    // no report accounts for is a defect had no way to notice its own converse.
    //
    // `--verify` below re-hashes these and says so.
    reportPath: relative(ROOT, path),
    reportSha256: sha256(path),
    reviewer: r.reviewer,
    expectedElements: r.expectedElements,
    missing: r.missing ?? [],
    rating: r.rating ?? null,
    findings: findings.map((f) => ({
      id: f.id,
      severity: f.severity,
      location: f.location,
      finding: f.finding,
      ...(f.criterion ? { criterion: f.criterion } : {}),
    })),
  };
}

/**
 * Every report FILE in a round directory reached the ledger, and still parses.
 *
 * `verify` below walks the LEDGER and asks whether each entry's report is
 * unchanged. That direction cannot see the converse, and the converse is a real
 * failure that has now happened: a report that was never ingested leaves no
 * ledger entry, so there is nothing for `verify` to iterate over and the round
 * looks complete at 41 files and 41 verified rows while one reviewer's judgement
 * is absent from the evidence the gate decides over.
 *
 * That is exactly the shape the round README already forbids in the other
 * direction — "a ledger entry that no report accounts for is a defect" — and it
 * is the same mistake as counting files instead of parses, which is how "6/6
 * because all six files existed" got past a completeness check while one writer
 * was still running.
 *
 * It is not hypothetical. In vd9-r1 `debugger/laptop/dark/L2` was written with
 * its fenced json block opened and never closed. `ingest` refused it, correctly
 * and loudly — but a refusal is a line on a terminal, and if it had scrolled
 * past, every remaining check in the pipeline would have been green over a
 * six-lens triple carrying five lenses.
 *
 * So this asserts three things per file, and the middle one is the point:
 *
 *   1. the report PARSES — a closing fence and valid JSON;
 *   2. a ledger entry names it by `reportPath`, so it actually reached the
 *      evidence rather than merely existing beside it;
 *   3. the entry's finding count equals the block's, so a partially-merged
 *      entry is not mistaken for a whole one.
 */
function verifyRound(ledgerPath, roundDir) {
  const ledger = JSON.parse(readFileSync(ledgerPath, "utf8"));
  const byPath = new Map();
  // Also indexed by the TRIPLE+LENS a report is for, so a file whose slot in the
  // ledger is held by a LATER round can be told apart from one nobody ingested.
  // Without that distinction this check cries wolf on every completed round the
  // moment the next one lands — `vd9-r1` went from clean to "12 of 42
  // unaccounted for" purely because `vd9-r2` re-reviewed two of its triples —
  // and a check that is wrong whenever the campaign makes progress is one people
  // learn to skip. That is a worse failure than the one it was written to catch.
  const bySlot = new Map();
  for (const r of ledger.reviews ?? []) {
    if (r.reportPath) byPath.set(r.reportPath, r);
    bySlot.set(`${r.view}/${r.size}/${r.theme}/${r.reviewer}`, r);
  }

  const files = readdirSync(roundDir)
    .filter((f) => f.endsWith(".md") || f.endsWith(".json"))
    .sort();

  const unparseable = [], notIngested = [], countMismatch = [], superseded = [];
  let ok = 0;
  for (const f of files) {
    const abs = join(roundDir, f);
    const rel = relative(ROOT, abs);
    let block = null;
    try {
      block = blockFrom(abs);
    } catch (e) {
      unparseable.push(`${rel}\n      ${e.message.replace(`${abs}: `, "")}`);
      continue;
    }
    const entry = byPath.get(rel);
    if (!entry) {
      const slot = `${block.view}/${block.size}/${block.theme}/${block.reviewer}`;
      const holder = bySlot.get(slot);
      if (holder && holder.reportPath && holder.reportPath !== rel) {
        // The slot is held by a different file, and WHICH WAY ROUND decides
        // whether this is fine. If the holder is NEWER, this file is a previous
        // round's report that has since been re-reviewed — the pipeline working,
        // because the archive is immutable and the ledger holds only the current
        // round. If the holder is OLDER, this file is a newer report that has
        // not been ingested yet, which is precisely the gap this check exists to
        // find and must fail.
        //
        // Decided on mtime rather than on the round directory's name: `vd9-r1` <
        // `vd9-r2` happens to sort correctly today and is a naming convention,
        // not a guarantee, and this check is the one thing standing between a
        // silently-dropped review and a green pipeline. It should not rest on a
        // filename.
        const holderAbs = join(ROOT, holder.reportPath);
        let holderNewer = false;
        try {
          holderNewer = statSync(holderAbs).mtimeMs >= statSync(abs).mtimeMs;
        } catch {
          // The holder's file is gone; `--verify` reports that as MISSING and it
          // is not this assertion's to double-report. Treat the slot as unheld.
        }
        if (holderNewer) {
          superseded.push(`${rel}\n      -> ${holder.reportPath}`);
          continue;
        }
        notIngested.push(
          `${rel}\n      parses as ${slot}, and is NEWER than the report the ` +
          `ledger holds for that slot (${holder.reportPath}) — so this review ` +
          `has not been ingested, not superseded`);
        continue;
      }
      notIngested.push(
        `${rel}\n      parses as ${slot}, but no ledger entry names it` +
        (holder ? ` and nothing holds that slot` : ``));
      continue;
    }
    const nBlock = (block.findings ?? []).length;
    const nEntry = (entry.findings ?? []).length;
    if (nBlock !== nEntry) {
      countMismatch.push(`${rel}\n      block has ${nBlock} finding(s), ledger entry has ${nEntry}`);
      continue;
    }
    ok++;
  }

  console.log(`round:         ${relative(ROOT, roundDir)}`);
  console.log(`report files:  ${files.length}`);
  console.log(`in the ledger: ${ok}`);
  if (superseded.length) {
    console.log(`superseded:    ${superseded.length} (ingested, then re-reviewed by a later round)`);
    for (const s of superseded) console.log(`  - ${s}`);
  }
  if (unparseable.length) {
    console.log(`\nUNPARSEABLE (${unparseable.length}) — a file that is not a report:`);
    for (const u of unparseable) console.log(`  - ${u}`);
  }
  if (notIngested.length) {
    console.log(`\nNEVER REACHED THE LEDGER (${notIngested.length}):`);
    for (const n of notIngested) console.log(`  - ${n}`);
    console.log(`\nThese reviewers' judgement is not in the evidence the gate decides over.`);
    console.log(`Ingest them, or say in the round record why they are excluded — do not`);
    console.log(`leave a round that looks complete on disk and is not complete in the ledger.`);
  }
  if (countMismatch.length) {
    console.log(`\nFINDING COUNT DISAGREES (${countMismatch.length}):`);
    for (const c of countMismatch) console.log(`  - ${c}`);
  }
  const bad = unparseable.length + notIngested.length + countMismatch.length;
  if (bad) {
    console.log(`\nFAIL — ${bad} of ${files.length} report file(s) are not accounted for`);
    return 1;
  }
  // Same rule as `verify`: a clean scan of nothing is not a pass.
  if (files.length === 0) {
    console.log(`\nNO VERDICT — no report files in ${relative(ROOT, roundDir)}, so there is`);
    console.log(`no claim to check.`);
    return 1;
  }
  console.log(
    `\nPASS — all ${files.length} report file(s) parse and are accounted for` +
    (superseded.length ? ` (${ok} current, ${superseded.length} superseded)` : ``));
  return 0;
}

function verify(ledgerPath) {
  // Does every ledger entry still match the report it was built from?
  //
  // Three verdicts, not two — a missing report and a CHANGED report are
  // different defects and only one of them is someone overwriting evidence.
  // A pre-`reportSha256` entry is a third: it cannot be checked and must not be
  // reported as clean, for the reason `gate.mjs` refuses to invent a G2 verdict
  // for a review that carries no image hash.
  const ledger = JSON.parse(readFileSync(ledgerPath, "utf8"));
  const rows = ledger.reviews ?? [];
  let checked = 0, unverifiable = 0;
  const missing = [], changed = [];
  for (const r of rows) {
    if (!r.reportSha256 || !r.reportPath) { unverifiable++; continue; }
    const abs = join(ROOT, r.reportPath);
    if (!existsSync(abs)) { missing.push(`${r.view}/${r.size}/${r.theme}/${r.reviewer} -> ${r.reportPath}`); continue; }
    checked++;
    const now = sha256(abs);
    if (now !== r.reportSha256) {
      changed.push(`${r.view}/${r.size}/${r.theme}/${r.reviewer} -> ${r.reportPath}\n      ingested ${r.reportSha256.slice(0, 12)}  on disk ${now.slice(0, 12)}`);
    }
  }
  console.log(`ledger:        ${ledgerPath}`);
  console.log(`revision:      ${ledger.ledgerRevision}`);
  console.log(`reviews:       ${rows.length}`);
  console.log(`verified:      ${checked}`);
  if (unverifiable) {
    console.log(`unverifiable:  ${unverifiable} (ingested before report hashing; NOT a pass)`);
  }
  if (missing.length) {
    console.log(`\nREPORT FILE MISSING (${missing.length}):`);
    for (const m of missing) console.log(`  - ${m}`);
  }
  if (changed.length) {
    console.log(`\nREPORT CHANGED SINCE INGEST (${changed.length}):`);
    for (const c of changed) console.log(`  - ${c}`);
    console.log(`\nThe ledger and the round file disagree. The ledger entry is what the`);
    console.log(`gate decided over; the file is what the tree says it decided over. Restore`);
    console.log(`the file, or re-ingest so the two agree — do not leave them disagreeing.`);
  }
  // A CLEAN SCAN OF NOTHING IS NOT A PASS. The first version of this printed
  // `PASS — 0 report(s) still hash to what was ingested` over a ledger in which
  // every entry predated report hashing — universal quantification over an
  // empty set, which is the cheapest false green there is
  // (Verification-Harness-Traps §4). The count is asserted, not the emptiness
  // of the failure lists.
  const clean = missing.length === 0 && changed.length === 0;
  if (!clean) {
    console.log(`\nFAIL — ${missing.length} missing, ${changed.length} changed`);
    return 1;
  }
  if (checked === 0) {
    console.log(`\nNO VERDICT — nothing in this ledger carries a report hash, so`);
    console.log(`there is no claim to check. Re-ingest the round to record them.`);
    return 1;
  }
  if (unverifiable) {
    console.log(`\nPARTIAL — ${checked} report(s) verified, ${unverifiable} unverifiable.`);
    console.log(`The unverifiable ones are not clean; they are unexamined.`);
    return 1;
  }
  console.log(`\nPASS — all ${checked} report(s) still hash to what was ingested`);
  return 0;
}

function main(argv) {
  const reports = [];
  const scope = [];
  let revision = null;
  let dryRun = false;
  let verifyOnly = false;
  let verifyRoundDir = null;
  let ledgerPath = LEDGER;
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "--ledger": ledgerPath = resolve(argv[++i]); break;
      case "--report": reports.push(resolve(argv[++i])); break;
      case "--dir": {
        const d = resolve(argv[++i]);
        for (const f of readdirSync(d).sort()) {
          if (f.endsWith(".md") || f.endsWith(".json")) reports.push(join(d, f));
        }
        break;
      }
      case "--gate-scope": scope.push(argv[++i]); break;
      case "--revision": revision = argv[++i]; break;
      case "--dry-run": dryRun = true; break;
      case "--verify": verifyOnly = true; break;
      case "--verify-round": verifyOnly = true; verifyRoundDir = resolve(argv[++i]); break;
      default: refuse(`unknown argument: ${argv[i]}`);
    }
  }
  if (verifyOnly) {
    const a = verify(ledgerPath);
    if (verifyRoundDir === null) return a;
    console.log("");
    // BOTH directions are reported, and the exit code is the worse of the two.
    // They answer different questions — "does the ledger still match its
    // reports" and "did every report reach the ledger" — and a run that passed
    // one while failing the other would be the more dangerous of the pair
    // silently, which is the whole reason the second one exists.
    const b = verifyRound(ledgerPath, verifyRoundDir);
    return a || b;
  }
  if (!reports.length) refuse("no reports given (--report <file> or --dir <dir>)");

  const ledger = JSON.parse(readFileSync(ledgerPath, "utf8"));
  ledger.reviews ??= [];
  ledger.gateScope ??= [];

  const incoming = [];
  for (const path of reports) incoming.push(check(blockFrom(path), path));

  // The finding ids that exist BEFORE this merge, so the orphaning this run
  // causes can be told apart from orphaning that was already there.
  const idsBefore = new Set();
  for (const r of ledger.reviews) for (const f of r.findings ?? []) idsBefore.add(f.id);

  // Merge: one entry per {view,size,theme,reviewer}; a re-ingest replaces.
  let added = 0, replaced = 0;
  for (const r of incoming) {
    const i = ledger.reviews.findIndex(
      (x) => x.view === r.view && x.size === r.size && x.theme === r.theme && x.reviewer === r.reviewer);
    if (i >= 0) { ledger.reviews[i] = r; replaced++; } else { ledger.reviews.push(r); added++; }
  }

  // ── Resolutions this ingest just orphaned ────────────────────────────────
  //
  // REPORTED, never rewritten. This file does not write `resolutions` — see the
  // header — and that rule holds in the deleting direction too: an ingest that
  // could silently drop an engineer's claim about a change is an ingest that
  // could erase the record of why something was closed. Pruning them is a
  // decision, so it stays with the operator; noticing them is an observation,
  // and that is this file's job.
  //
  // The gap this closes is one of TIMING rather than of detection. `gate.mjs`
  // already fails closed on an orphan, but only when someone next runs it, and
  // by then the round that caused it is several commits back. A round that
  // REPLACES a triple's reviews renumbers that triple's findings, so every
  // resolution against the old numbering stops naming anything — and the moment
  // that happens is exactly here, where the operator can still remember which
  // round did it and re-derive rather than guess.
  //
  // It is the `design-citations` argument applied to resolutions: an id that
  // survives a round bump and a MEANING that survives one are different things,
  // and a resolution left pointing at a renumbered finding would read as
  // evidence that a finding was dealt with when it names a different finding
  // entirely.
  const idsAfter = new Set();
  for (const r of ledger.reviews) for (const f of r.findings ?? []) idsAfter.add(f.id);
  const orphanedNow = (ledger.resolutions ?? []).filter(
    (r) => idsBefore.has(r.findingId) && !idsAfter.has(r.findingId));
  const orphanedBefore = (ledger.resolutions ?? []).filter((r) => !idsBefore.has(r.findingId));

  // G2's "the exact image", established on bytes. Checked over the WHOLE
  // ledger, not just this batch, so a reviewer left behind by a recapture is
  // caught even when this run did not touch them.
  const byTriple = new Map();
  for (const r of ledger.reviews) {
    if (!r.imageSha256) continue;   // pre-ingest entries carry no hash
    const k = `${r.view}/${r.size}/${r.theme}`;
    (byTriple.get(k) ?? byTriple.set(k, []).get(k)).push(r);
  }
  const stale = [];
  for (const [k, rs] of byTriple) {
    const hashes = new Set(rs.map((r) => r.imageSha256));
    if (hashes.size > 1) {
      const current = sha256(join(ROOT, rs[0].image));
      stale.push(`${k}: ${rs.length} reviews over ${hashes.size} different captures — ` +
        rs.map((r) => `${r.reviewer}@${r.imageSha256.slice(0, 12)}${r.imageSha256 === current ? "" : " (STALE)"}`).join(", "));
    }
  }
  if (stale.length) {
    refuse("reviews of one triple disagree about what they looked at:\n  " + stale.join("\n  ") +
      "\nG2 requires the SAME image. Re-run the reviewers whose hash is stale.");
  }

  for (const t of scope) {
    const [view, size, theme] = t.split("/");
    if (!VIEWS_BY_ID.has(view) || !SIZES[size] || !THEMES.includes(theme)) {
      refuse(`--gate-scope '${t}' is not a view/size/theme triple`);
    }
    if (!ledger.gateScope.some((x) => x.view === view && x.size === size && x.theme === theme)) {
      ledger.gateScope.push({ view, size, theme });
    }
  }

  // The revision is what a sign-off names, so it moves whenever the evidence
  // moves. Same-day ingests get a serial rather than colliding.
  if (revision) ledger.ledgerRevision = revision;
  else {
    const day = new Date().toISOString().slice(0, 10);
    const prev = String(ledger.ledgerRevision ?? "");
    const n = prev.startsWith(day) ? (parseInt(prev.split(".")[1] ?? "0", 10) || 0) + 1 : 1;
    ledger.ledgerRevision = `${day}.${n}`;
  }

  if (dryRun) {
    console.log(`DRY RUN — ${added} new, ${replaced} replaced; revision would be ${ledger.ledgerRevision}`);
    return 0;
  }
  writeFileSync(ledgerPath, JSON.stringify(ledger, null, 2) + "\n");
  console.log(`ingested ${incoming.length} report(s): ${added} new, ${replaced} replaced`);
  console.log(`ledger revision -> ${ledger.ledgerRevision}`);
  console.log(`reviews now: ${ledger.reviews.length}; gateScope: ${ledger.gateScope.length} triple(s)`);
  for (const [k, rs] of byTriple) {
    console.log(`  ${k}: ${rs.length}/${ALL_LENSES.length} lenses @ ${rs[0].imageSha256.slice(0, 12)}`);
  }
  if (orphanedNow.length) {
    console.log("");
    console.log(
      `${orphanedNow.length} resolution(s) NO LONGER NAME A FINDING — this ingest ` +
      `renumbered the triple they belonged to:`);
    for (const r of orphanedNow) {
      console.log(`  ${r.findingId}  [${r.status}]`);
    }
    console.log(
      `  They are left exactly as they were: this tool does not write ` +
      `resolutions, in either direction.`);
    console.log(
      `  Re-derive each against the NEW finding text and re-record it, or drop ` +
      `it deliberately. Do not re-point it at the same id — a replaced round ` +
      `keeps the ids and changes what they mean, so that would resolve a ` +
      `finding it was never about. \`just review-gate\` fails closed until then.`);
  }
  if (orphanedBefore.length) {
    console.log("");
    console.log(
      `${orphanedBefore.length} resolution(s) were ALREADY orphaned before this ` +
      `run — an earlier round renumbered them and they were never re-derived:`);
    for (const r of orphanedBefore) console.log(`  ${r.findingId}  [${r.status}]`);
  }
  return 0;
}

try {
  process.exit(main(process.argv.slice(2)));
} catch (e) {
  if (e instanceof Refused) {
    console.error(`REFUSED — ${e.message}`);
    process.exit(1);
  }
  throw e;
}
