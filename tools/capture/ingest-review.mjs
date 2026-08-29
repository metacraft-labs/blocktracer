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
import { join, resolve, dirname } from "node:path";
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

function main(argv) {
  const reports = [];
  const scope = [];
  let revision = null;
  let dryRun = false;
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
      default: refuse(`unknown argument: ${argv[i]}`);
    }
  }
  if (!reports.length) refuse("no reports given (--report <file> or --dir <dir>)");

  const ledger = JSON.parse(readFileSync(ledgerPath, "utf8"));
  ledger.reviews ??= [];
  ledger.gateScope ??= [];

  const incoming = [];
  for (const path of reports) incoming.push(check(blockFrom(path), path));

  // Merge: one entry per {view,size,theme,reviewer}; a re-ingest replaces.
  let added = 0, replaced = 0;
  for (const r of incoming) {
    const i = ledger.reviews.findIndex(
      (x) => x.view === r.view && x.size === r.size && x.theme === r.theme && x.reviewer === r.reviewer);
    if (i >= 0) { ledger.reviews[i] = r; replaced++; } else { ledger.reviews.push(r); added++; }
  }

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
