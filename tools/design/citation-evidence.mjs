#!/usr/bin/env node
//
// What each `ledger@<revision>:<id>` citation in the source ACTUALLY points at,
// then and now.
//
// `check-tokens.mjs` B4 answers one question — does this citation resolve
// against the current ledger — and a revision bump turns every stale one red at
// once, which is what it is for. What it cannot say is the thing that decides
// how to fix them: whether the finding at that id still MEANS what the comment
// citing it says it means.
//
// That distinction is the whole hazard. A round that REPLACES reviews on a
// triple leaves the ids intact and the meanings different, so re-stamping the
// revision would make 58 comments resolve to findings they were never written
// about — and B4 would pass over every one, because it checks that the id
// exists, not that it still names the same finding. That is the vacuous-pass
// shape Verification-Harness-Traps §4 is about, arriving through a bulk edit.
//
// So this prints, per citation: the finding as it stood at the cited revision,
// and the finding at that id now. A human (or an agent) decides per site:
//
//   * the two say the same thing        -> re-stamp the revision
//   * they do not, and a current finding says it -> re-point to that id
//   * they do not, and none does        -> cite the ROUND FILE, which is
//                                          immutable, or drop the citation
//
// Usage:
//   node tools/design/citation-evidence.mjs              # every stale citation
//   node tools/design/citation-evidence.mjs --file <p>   # one source file
//   node tools/design/citation-evidence.mjs --json

import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const LEDGER = join(ROOT, "reviews", "ledger.json");

// The same pattern B4 uses, so this reads exactly the set B4 rejects.
const CITE = /ledger@([0-9][\w.-]*):([a-z0-9-]+\/[a-z0-9-]+\/[a-z0-9-]+\/(?:L\d+|ADV)\/\d+)/gi;

const walk = (dir, out = []) => {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.name === "node_modules" || e.name === ".git") continue;
    if (e.isDirectory()) walk(p, out);
    else if (/\.(nim|json|mjs|md)$/.test(e.name)) out.push(p);
  }
  return out;
};

/** The ledger as it stood at a revision, found by walking git history. */
const ledgerAtRevision = (() => {
  const cache = new Map();
  return (rev) => {
    if (cache.has(rev)) return cache.get(rev);
    let found = null;
    try {
      const shas = execFileSync(
        "git", ["-C", ROOT, "log", "--format=%H", "--", "reviews/ledger.json"],
        { encoding: "utf8", maxBuffer: 1 << 28 },
      ).trim().split("\n").filter(Boolean);
      for (const sha of shas) {
        try {
          const blob = execFileSync(
            "git", ["-C", ROOT, "show", `${sha}:reviews/ledger.json`],
            { encoding: "utf8", maxBuffer: 1 << 28 },
          );
          const L = JSON.parse(blob);
          if (L.ledgerRevision === rev) { found = L; break; }
        } catch { /* a commit where the file did not parse or exist */ }
      }
    } catch { /* not a git tree */ }
    cache.set(rev, found);
    return found;
  };
})();

const indexFindings = (L) => {
  const m = new Map();
  if (!L) return m;
  for (const r of L.reviews ?? []) {
    for (const f of r.findings ?? []) m.set(f.id, { ...f, reviewer: r.reviewer });
  }
  return m;
};

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const onlyFile = args.includes("--file") ? args[args.indexOf("--file") + 1] : null;

const ledger = JSON.parse(readFileSync(LEDGER, "utf8"));
const current = indexFindings(ledger);
const revision = ledger.ledgerRevision;

const sources = onlyFile
  ? [join(ROOT, onlyFile)]
  : [...walk(join(ROOT, "client", "src")), ...walk(join(ROOT, "tools")),
     ...walk(join(ROOT, "docs"))];

const rows = [];
for (const file of sources) {
  if (!existsSync(file) || statSync(file).isDirectory()) continue;
  const text = readFileSync(file, "utf8");
  for (const m of text.matchAll(CITE)) {
    if (m[1] === revision) continue;           // resolves; not our subject
    const line = text.slice(0, m.index).split("\n").length;
    const wasLedger = ledgerAtRevision(m[1]);
    const was = indexFindings(wasLedger).get(m[2]);
    const now = current.get(m[2]);
    const same = was && now && was.finding === now.finding;
    rows.push({
      file: relative(ROOT, file), line, citedRevision: m[1], id: m[2],
      verdict: !was ? "cited-revision-not-in-history"
        : !now ? "id-gone-from-current-ledger"
        : same ? "SAFE-RESTAMP" : "MEANING-CHANGED",
      was: was ? { severity: was.severity, finding: was.finding } : null,
      now: now ? { severity: now.severity, finding: now.finding } : null,
    });
  }
}

if (asJson) { console.log(JSON.stringify({ revision, rows }, null, 1)); process.exit(0); }

const tally = {};
for (const r of rows) tally[r.verdict] = (tally[r.verdict] ?? 0) + 1;
console.log(`current ledger revision: ${revision}`);
console.log(`stale citations:         ${rows.length}`);
for (const [k, v] of Object.entries(tally).sort()) console.log(`  ${String(v).padStart(4)}  ${k}`);
console.log();
for (const r of rows) {
  console.log(`── ${r.file}:${r.line}`);
  console.log(`   ledger@${r.citedRevision}:${r.id}   ${r.verdict}`);
  if (r.was) console.log(`   WAS ${r.was.severity}: ${r.was.finding.slice(0, 150)}`);
  if (r.now) console.log(`   NOW ${r.now.severity}: ${r.now.finding.slice(0, 150)}`);
  console.log();
}
// A scan that found nothing is not a clean tree — it is a scan that did not
// reach one. Say which.
if (rows.length === 0) {
  console.log(current.size > 0
    ? "no stale citations — every one resolves against the current revision"
    : "NO VERDICT — the ledger carries no findings, so nothing could be checked");
  process.exit(current.size > 0 ? 0 : 1);
}
process.exit(0);
