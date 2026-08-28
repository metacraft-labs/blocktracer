#!/usr/bin/env node
// VD.0 verification: verify_capture_covers_named_view_list
//                and verify_full_regen_removes_stale_images
//
//   node tools/capture/check-coverage.mjs [--out DIR] [--json]
//
// Four assertions, in the order a failure is most useful:
//
//   A. INVENTORY COVERAGE — every page in Page-Descriptions and every state in
//      its degraded-state catalogue is named by at least one view. This is the
//      "covering every page and every state" half of the deliverable, and it
//      holds whether or not anything has been captured yet.
//
//   B. VIEW LIST INTEGRITY — every view names a real inventory entry, every id
//      is unique, and every pending view states why it is pending.
//
//   C. IMAGE COVERAGE — every READY view produced an image at every one of its
//      viewports in every one of its themes.
//
//   D. NO STALE IMAGES — every image on disk corresponds to a list entry. This
//      is the check that catches a renamed or deleted view whose old file was
//      left behind, so it is also the assertion behind
//      verify_full_regen_removes_stale_images.
//
// Pending views — those whose route the client does not serve yet — are
// REPORTED, with counts and reasons, and do not fail C. The alternative is
// either to drop them from the list (losing the coverage guarantee A gives) or
// to capture them against a 404 (producing an image a reviewer would mistake
// for a styled page). Neither is better than saying so.

import { readdir, readFile } from "node:fs/promises";
import { join, dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

import {
  VIEWS,
  VIEWS_BY_ID,
  sizesFor,
  themesFor,
  imageName,
  parseImageName,
  SIZES,
  THEMES,
  CANARY,
} from "./views.mjs";
import { INVENTORY, INVENTORY_IDS, SPEC_SOURCE, PAGES, DEGRADED_STATES } from "./spec-inventory.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const DEFAULT_OUT = join(REPO_ROOT, "screenshots");

function parseArgs(argv) {
  const opts = { out: DEFAULT_OUT, json: false };
  for (let i = 2; i < argv.length; i++) {
    if (argv[i] === "--out") opts.out = resolvePath(argv[++i]);
    else if (argv[i] === "--json") opts.json = true;
    else throw new Error(`unknown argument: ${argv[i]}`);
  }
  return opts;
}

async function main() {
  const opts = parseArgs(process.argv);
  const problems = [];
  const report = { spec: SPEC_SOURCE, out: opts.out };

  // ── B. View list integrity ───────────────────────────────────────────────
  const seen = new Set();
  for (const v of VIEWS) {
    if (seen.has(v.id)) problems.push(`B: duplicate view id "${v.id}"`);
    seen.add(v.id);
    if (!Array.isArray(v.covers) || v.covers.length === 0)
      problems.push(`B: view "${v.id}" covers nothing`);
    for (const c of v.covers ?? [])
      if (!INVENTORY_IDS.has(c))
        problems.push(`B: view "${v.id}" covers unknown inventory entry "${c}"`);
    if (v.status !== "ready" && !v.pendingReason)
      problems.push(`B: view "${v.id}" is pending without a stated reason`);
    for (const s of sizesFor(v))
      if (!SIZES[s]) problems.push(`B: view "${v.id}" names unknown viewport "${s}"`);
    for (const t of themesFor(v))
      if (!THEMES.includes(t)) problems.push(`B: view "${v.id}" names unknown theme "${t}"`);
  }
  for (const c of CANARY) {
    if (!VIEWS_BY_ID.has(c.view)) problems.push(`B: canary names unknown view "${c.view}"`);
    if (!SIZES[c.size]) problems.push(`B: canary names unknown viewport "${c.size}"`);
    if (!THEMES.includes(c.theme)) problems.push(`B: canary names unknown theme "${c.theme}"`);
  }

  // ── A. Inventory coverage ────────────────────────────────────────────────
  const coveredBy = new Map();
  for (const v of VIEWS) for (const c of v.covers ?? []) {
    if (!coveredBy.has(c)) coveredBy.set(c, []);
    coveredBy.get(c).push(v.id);
  }
  const uncovered = INVENTORY.filter((e) => !coveredBy.has(e.id));
  for (const e of uncovered)
    problems.push(`A: no named view covers ${e.anchor} "${e.id}"${e.label ? ` — ${e.label}` : ""}`);
  report.inventory = {
    total: INVENTORY.length,
    pages: PAGES.length,
    degradedStates: DEGRADED_STATES.length,
    covered: INVENTORY.length - uncovered.length,
    uncovered: uncovered.map((e) => e.id),
  };

  // ── C/D. Image coverage and stale images ─────────────────────────────────
  let present = [];
  let outDirExists = true;
  try {
    present = (await readdir(opts.out)).filter((f) => f.endsWith(".png"));
  } catch {
    outDirExists = false;
  }
  const presentSet = new Set(present);

  const expectedReady = [];
  const expectedPending = [];
  for (const v of VIEWS) {
    for (const s of sizesFor(v)) for (const t of themesFor(v)) {
      (v.status === "ready" ? expectedReady : expectedPending).push(imageName(v.id, s, t));
    }
  }
  const knownNames = new Set([...expectedReady, ...expectedPending]);

  const missing = outDirExists ? expectedReady.filter((f) => !presentSet.has(f)) : expectedReady;
  if (!outDirExists) {
    problems.push(`C: no capture output at ${opts.out} — run capture.mjs first`);
  } else {
    for (const f of missing) problems.push(`C: ready view produced no image: ${f}`);
  }

  const stale = present.filter((f) => !knownNames.has(f));
  for (const f of stale) {
    const parsed = parseImageName(f);
    const why = parsed
      ? VIEWS_BY_ID.has(parsed.viewId)
        ? `view "${parsed.viewId}" does not declare ${parsed.size}/${parsed.theme}`
        : `no view named "${parsed.viewId}"`
      : `filename does not match <view>__<size>__<theme>.png`;
    problems.push(`D: stale image ${f} — ${why}`);
  }

  const pendingViews = VIEWS.filter((v) => v.status !== "ready");
  report.views = {
    total: VIEWS.length,
    ready: VIEWS.length - pendingViews.length,
    pending: pendingViews.length,
    expectedReadyImages: expectedReady.length,
    expectedPendingImages: expectedPending.length,
    presentImages: present.length,
    missing,
    stale,
    pendingReasons: pendingViews.map((v) => ({ view: v.id, reason: v.pendingReason, covers: v.covers })),
  };
  report.problems = problems;
  report.ok = problems.length === 0;

  if (opts.json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.log(`spec source:      ${SPEC_SOURCE.document} (last updated ${SPEC_SOURCE.lastUpdated})`);
    console.log(`inventory:        ${report.inventory.covered}/${report.inventory.total} entries covered by a named view`);
    console.log(`                  (${PAGES.length} pages + ${DEGRADED_STATES.length} degraded states)`);
    console.log(`named views:      ${report.views.total} (${report.views.ready} ready, ${report.views.pending} pending)`);
    console.log(`viewports:        ${Object.keys(SIZES).join(", ")}`);
    console.log(`themes:           ${THEMES.join(", ")}`);
    console.log(`expected images:  ${expectedReady.length} for ready views (+${expectedPending.length} blocked on pending routes)`);
    console.log(`present images:   ${present.length}`);
    console.log("");
    if (pendingViews.length) {
      console.log(`PENDING (${pendingViews.length} views, ${expectedPending.length} images) — named, not yet capturable:`);
      for (const v of pendingViews) console.log(`  ${v.id.padEnd(34)} ${v.pendingReason}`);
      console.log("");
    }
    if (problems.length) {
      console.log(`FAIL — ${problems.length} problem(s):`);
      for (const p of problems) console.log(`  ${p}`);
    } else {
      console.log("PASS — verify_capture_covers_named_view_list");
      console.log("PASS — no stale images (verify_full_regen_removes_stale_images)");
    }
  }
  return problems.length ? 1 : 0;
}

main()
  .then((c) => process.exit(c))
  .catch((e) => {
    console.error(`coverage check failed: ${e.message}`);
    process.exit(2);
  });
