#!/usr/bin/env node
// VD.0 verification: verify_capture_covers_named_view_list,
//                    verify_full_regen_removes_stale_images
//                and verify_corpus_subject_drift_is_detected
//
//   node tools/capture/check-coverage.mjs [--out DIR] [--json]
//
// Six assertions, in the order a failure is most useful:
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
//   E. CHAIN COVERAGE — every chain the BUILT TREE publishes, and every
//      provenance kind it publishes, is the subject of a ready view. Unlike A
//      this is derived from the registry rather than from a list in this
//      repository, because A is a by-name list and a by-name list is exactly
//      what failed: three chains shipped, all 280 images were of one of them,
//      and A said 67/67. NOT RUN without a build, never passed.
//
//   F. CORPUS SUBJECT DRIFT — every image THE MANIFEST RECORDS was captured
//      against the subject its view resolves to NOW. It walks
//      `manifest.images`, not the directory: an image on disk with no manifest
//      row is invisible here, and is D's business rather than F's.
//      E's content-shaped twin, and it exists
//      because E cannot see this: E re-resolves the VIEW LIST against the tree
//      and is satisfied when every chain has a view pointing at it. It says
//      nothing about the PNGs, so a corpus photographed before a chain was
//      renamed stays green under A, C, D and E together while every image in it
//      is of a chain at a URL the site no longer serves.
//
//      That is not hypothetical. Moving the real Aztec mainnet onto `/aztec`
//      and the synthetic tree to `/demo` moves 232 fixture-driven images and
//      both mainnet ones, changes no view NAME, and leaves the file list
//      byte-for-byte the answer D expects. The only signal was a person
//      remembering.
//
//      The manifest records the URL each image was actually captured at, so the
//      check is a comparison rather than a new kind of evidence: resolve every
//      ready view's route again and require the answer to equal what was
//      recorded. It therefore also catches a subject re-pointing WITHIN a chain
//      — `firstTracelessTx` returning a different transaction after a reseed or
//      a fixture change — which is the same defect one scope smaller.
//
//      NOT RUN without a manifest or without a build, never passed: a check
//      that goes green because it could not find the corpus is the failure this
//      assertion is about.
//
// Pending views — those whose route the client does not serve yet — are
// REPORTED, with counts and reasons, and do not fail C. The alternative is
// either to drop them from the list (losing the coverage guarantee A gives) or
// to capture them against a 404 (producing an image a reviewer would mistake
// for a styled page). Neither is better than saying so.

import { readdir, readFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

import { buildEntityIndex } from "./lib/entities.mjs";

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
import {
  INVENTORY,
  INVENTORY_IDS,
  SPEC_SOURCE,
  PAGES,
  DEGRADED_STATES,
  readSpecLastUpdated,
} from "./spec-inventory.mjs";

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

  // ── E. CHAIN COVERAGE ────────────────────────────────────────────────────
  //
  // Every chain the tree publishes, and every distinct provenance KIND it
  // publishes, is the subject of at least one READY view.
  //
  // This assertion is derived from the built data plane rather than from a list
  // in this file, and that is the whole point of it. A by-name list is what A
  // already is, and A is what failed: the tree gained `aztec-testnet` and
  // `aztec-mainnet`, every named view kept resolving through
  // `chains.sort()[0]`, and the 2026-08-31 corpus contained 232 images of the
  // synthetic chain and none of either real one — while A reported 67/67,
  // because there was no per-chain entry for it to find missing. A list cannot
  // notice a chain nobody added it to. The registry can.
  //
  // Read from the same `dist/` the capture ran against, so a chain that exists
  // only in someone's intention does not count. With no build present this is
  // NOT RUN rather than passing, for the reason C refuses to pass on a missing
  // output directory: a check that goes green for lack of anything to inspect
  // is worse than one that says it could not look.
  report.chains = { status: "not-run" };
  report.subjects = { status: "not-run", reason: "assertion E did not run, so there was no resolved tree to compare the corpus against" };
  const distDir = resolvePath(REPO_ROOT, "client", "dist");
  if (!existsSync(join(distDir, "registry", "chains.v1.json"))) {
    report.chains = { status: "not-run", reason: `no built data plane at ${distDir}` };
  } else {
    const ix = buildEntityIndex(distDir);
    const readyViews = VIEWS.filter((v) => v.status === "ready");
    const subjectChains = new Set();
    const unresolved = [];
    for (const v of readyViews) {
      let url;
      try {
        url = typeof v.route === "function" ? v.route(ix) : v.route;
      } catch (e) {
        unresolved.push(`${v.id}: ${e.message}`);
        continue;
      }
      const first = String(url ?? "").split("?")[0].split("/").filter(Boolean)[0];
      if (first && ix.chains.includes(first)) subjectChains.add(first);
    }
    for (const u of unresolved) problems.push(`E: ready view route did not resolve — ${u}`);

    const uncoveredChains = ix.chains.filter((c) => !subjectChains.has(c));
    for (const c of uncoveredChains) {
      problems.push(
        `E: no ready view is captured from chain "${c}" ` +
        `(provenance: ${ix.byChain[c].provenanceKind || "none published"}) — ` +
        `every image would be of another chain while this one shipped ungraded`);
    }

    const kinds = ix.provenanceKinds();
    const coveredKinds = new Set(
      [...subjectChains].map((c) => ix.byChain[c].provenanceKind).filter(Boolean));
    const uncoveredKinds = kinds.filter((k) => !coveredKinds.has(k));
    for (const k of uncoveredKinds) {
      problems.push(
        `E: no ready view is captured from a chain whose provenance is "${k}" — ` +
        `the "${k}" provenance treatment has no subject in the corpus`);
    }

    report.chains = {
      status: "checked",
      published: ix.chains,
      subjects: [...subjectChains].sort(),
      uncovered: uncoveredChains,
      provenanceKinds: kinds,
      uncoveredProvenanceKinds: uncoveredKinds,
    };

    // ── F. CORPUS SUBJECT DRIFT ────────────────────────────────────────────
    //
    // Every image on disk, against the subject its view resolves to now.
    //
    // The comparison is on the URL and not on the chain slug alone. A slug
    // comparison would catch the rename this assertion was written for and
    // miss the smaller version of the same defect — the same chain, a
    // different transaction — and those are one failure, not two: in both, a
    // PNG is a photograph of something the named view no longer points at.
    const manifestPath = join(opts.out, "manifest.json");
    if (!existsSync(manifestPath)) {
      report.subjects = {
        status: "not-run",
        reason:
          `no manifest at ${manifestPath} — the URL each image was captured ` +
          `at is what this assertion compares, and nothing else records it`,
      };
    } else {
      let manifest = null;
      try {
        manifest = JSON.parse(await readFile(manifestPath, "utf8"));
      } catch (e) {
        problems.push(`F: manifest at ${manifestPath} is unreadable — ${e.message}`);
      }
      if (manifest) {
        // Resolve each ready view ONCE. A view resolving to several images
        // (its sizes and themes) must not resolve its route once per image:
        // that would be the same answer computed 308 times, and a route with
        // any nondeterminism in it would then disagree with ITSELF and be
        // reported as drift on some images and not others.
        const resolvedNow = new Map();
        for (const v of VIEWS.filter((x) => x.status === "ready")) {
          try {
            resolvedNow.set(v.id, typeof v.route === "function" ? v.route(ix) : v.route);
          } catch {
            // Already reported by E as an unresolved route. Recording it as
            // drift as well would be one fault counted twice, and the E
            // message is the more useful of the two.
            resolvedNow.set(v.id, null);
          }
        }

        // ── IS THIS DIST EVEN THE TREE THE CORPUS WAS CAPTURED AGAINST? ────
        //
        // F re-resolves every ready view against `client/dist` and compares, so
        // it assumes dist is the tree the capture was taken against. When those
        // two trees publish different CHAINS, every view resolving through the
        // primary chain re-resolves somewhere else and F reports drift that is
        // an artefact of the build rather than a fact about the corpus.
        //
        // That is not hypothetical. It happened once at scale: 72 images
        // reported as drifted from `/demo` to `/aztec`, an alarming and
        // entirely false result about a corpus that was perfectly correct,
        // produced by rebuilding dist between a capture and a check. A check
        // that cries wolf whenever someone runs the project's own export recipe
        // teaches people to disbelieve it, and F is the assertion that exists
        // because nobody could see a stale corpus. So a chain mismatch is
        // detected and NAMED before the comparison rather than expressed as
        // drift: if the corpus was photographed against a chain this dist does
        // not publish, the dist is the wrong tree and F cannot decide anything.
        //
        // THE CAUSE THAT PRODUCED IT NO LONGER EXISTS, and this comment used to
        // say otherwise. It said "capture builds with `-d:publishDemoChain`,
        // which the DEPLOY build deliberately omits", and sent the reader at a
        // rebuild command carrying that flag. The default has since flipped:
        // `static_export.nim` now publishes the synthetic chain under `when not
        // defined(noDemoChain)`, so the graded tree and the deployed tree are
        // the same tree, `just export` produces the capture shape, and the flag
        // still spelled in `capture.mjs` is a no-op. The whole class of
        // stale-corpus risk that motivated this block is gone with it.
        //
        // The DETECTION stays, and stays exactly as it is, for two reasons. It
        // is keyed on the chains the manifest actually recorded against the
        // chains this dist actually publishes, so it never depended on the flag
        // and catches a mismatch arising from any cause — including the next
        // re-scope of the published set, which is a live source of them. And an
        // assertion that reads a BUILD rather than the source of truth has this
        // shape whatever the build flags are; E reads the same dist. What is
        // corrected below is only the diagnosis, because a correct check
        // carrying a false explanation sends its one reader at a command that
        // cannot help.
        const capturedChains = new Set(
          (manifest.images ?? [])
            .filter((i) => i && i.ok === true && i.chain)
            .map((i) => i.chain));
        const absentChains = [...capturedChains].filter((c) => !ix.chains.includes(c));
        if (absentChains.length) {
          problems.push(
            `F: this dist does not publish ${absentChains.map((c) => `"${c}"`).join(", ")}, ` +
            `but ${(manifest.images ?? []).filter((i) => i && i.chain && absentChains.includes(i.chain)).length} ` +
            `image(s) in the corpus were captured from it — so this dist is NOT the tree ` +
            `the corpus was captured against and F cannot compare them. Since the synthetic ` +
            `chain became the default (\`when not defined(noDemoChain)\`), a plain rebuild ` +
            `produces the capture shape, so the likely causes are a build that set ` +
            `\`-d:noDemoChain\`, or a corpus older than a re-scope of the published set. ` +
            `Rebuild, then re-capture if the corpus is the stale half:\n` +
            `       cd client && just export        # then, if the chains still disagree:\n` +
            `       just capture ""`);
          report.subjects = {
            status: "not-run",
            reason:
              `dist is missing ${absentChains.join(", ")}, which the corpus was captured ` +
              `from — wrong tree, so no comparison was attempted`,
          };
        } else {

        const drifted = [];
        const unrecorded = [];
        for (const img of manifest.images ?? []) {
          if (!img || img.ok !== true) continue;
          const view = VIEWS_BY_ID.get(img.view);
          if (!view || view.status !== "ready") continue;
          if (typeof img.url !== "string" || img.url.length === 0) {
            unrecorded.push(img.file ?? `${img.view}__${img.size}__${img.theme}`);
            continue;
          }
          const now = resolvedNow.get(img.view);
          if (now === null || now === undefined) continue;
          if (now !== img.url) {
            drifted.push({
              file: img.file,
              view: img.view,
              capturedAt: img.url,
              resolvesTo: now,
              capturedChain: img.chain ?? null,
              resolvesToChain:
                String(now).split("?")[0].split("/").filter(Boolean)[0] ?? null,
            });
          }
        }

        // An image whose URL was never recorded cannot be compared, and
        // "cannot be compared" is not "agrees". Reported as a problem so a
        // corpus predating this field is re-captured rather than trusted.
        for (const f of unrecorded) {
          problems.push(
            `F: ${f} records no capture URL, so what it is a photograph of ` +
            `cannot be established — re-capture it`);
        }
        for (const d of drifted) {
          const chainMoved =
            d.capturedChain && d.resolvesToChain && d.capturedChain !== d.resolvesToChain;
          problems.push(
            `F: ${d.file} is a photograph of ${d.capturedAt}, but ${d.view} now ` +
            `resolves to ${d.resolvesTo}` +
            (chainMoved
              ? ` — the CHAIN moved (${d.capturedChain} → ${d.resolvesToChain}), so ` +
                `every image of it is of a URL this site no longer serves`
              : ` — same chain, different subject`) +
            `; the view name did not change, so nothing else reports this`);
        }

        // ── THE MANIFEST IS NOT THE CORPUS, AND A TARGETED CAPTURE PROVES IT ─
        //
        // F walks `manifest.images`, and `capture.mjs` REPLACES the manifest on
        // every run — including a targeted one. So after
        //
        //     just capture "--view debugger--copy-affordance"
        //
        // the manifest holds 4 entries, 304 PNGs are on disk, and F compared
        // four of them and printed PASS. The count was in the output and the
        // count was the only signal.
        //
        // That is this assertion's own defect, one layer down. F exists because
        // "a corpus photographed before a chain was renamed stays green under
        // A, C, D and E together while every image in it is of a chain at a URL
        // the site no longer serves — the only signal was a person
        // remembering." A targeted capture puts F itself in exactly that
        // position: 300 images unexamined, nothing red, and a reader who has to
        // remember what the number should have been.
        //
        // Not fixed by MERGING the targeted run into the previous manifest. The
        // manifest's `fixture`, `determinism` and `environment` fields describe
        // ONE run; a merged file would describe several while claiming to
        // describe one, which is a worse lie than a short one. The honest move
        // is the one the rest of this file already makes: say what was not
        // covered, and refuse to call a partial comparison a pass.
        const accountedFor = new Set(
          (manifest.images ?? []).filter((i) => i && i.file).map((i) => i.file));
        const unaccounted = present.filter((f) => !accountedFor.has(f));

        report.subjects = {
          status: unaccounted.length ? "partial" : "checked",
          compared: (manifest.images ?? []).filter((i) => i && i.ok === true).length,
          onDisk: present.length,
          unaccounted: unaccounted.length,
          drifted: drifted.length,
          unrecorded: unrecorded.length,
          detail: drifted,
        };
        }
      }
    }
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
    // The recorded revision, CHECKED against the document rather than restated.
    // See spec-inventory.mjs on why this comparison exists and why the constant
    // is not simply bumped when it disagrees.
    const live = await readSpecLastUpdated(REPO_ROOT);
    const drift =
      live.lastUpdated === null
        ? `NOT CHECKED — no codetracer-specs checkout at ${live.path} (set $CODETRACER_SPECS_SRC)`
        : live.lastUpdated === SPEC_SOURCE.lastUpdated
          ? "matches the document"
          : `DRIFTED — the document now reads ${live.lastUpdated}; this inventory has not been ` +
            `re-read against it (${live.path})`;
    console.log(`spec source:      ${SPEC_SOURCE.document}`);
    console.log(`                  transcribed from revision ${SPEC_SOURCE.lastUpdated} — ${drift}`);
    console.log(`inventory:        ${report.inventory.covered}/${report.inventory.total} entries covered by a named view`);
    console.log(`                  (${PAGES.length} pages + ${DEGRADED_STATES.length} degraded states)`);
    console.log(`named views:      ${report.views.total} (${report.views.ready} ready, ${report.views.pending} pending)`);
    console.log(`viewports:        ${Object.keys(SIZES).join(", ")}`);
    console.log(`themes:           ${THEMES.join(", ")}`);
    console.log(`expected images:  ${expectedReady.length} for ready views (+${expectedPending.length} blocked on pending routes)`);
    console.log(`present images:   ${present.length}`);
    if (report.chains.status === "checked") {
      console.log(`chains published: ${report.chains.published.join(", ")}`);
      console.log(`chains captured:  ${report.chains.subjects.join(", ") || "(none)"}`);
      console.log(`provenance kinds: ${report.chains.provenanceKinds.join(", ") || "(none published)"}`);
    } else {
      console.log(`chain coverage:   NOT RUN — ${report.chains.reason}`);
    }
    if (report.subjects.status === "checked") {
      console.log(
        `corpus subjects:  ${report.subjects.compared} image(s) compared against the ` +
        `route their view resolves to now; ${report.subjects.drifted} drifted`);
    } else if (report.subjects.status === "partial") {
      console.log(
        `corpus subjects:  PARTIAL — ${report.subjects.compared} of ` +
        `${report.subjects.onDisk} image(s) compared; ${report.subjects.drifted} drifted. ` +
        `${report.subjects.unaccounted} image(s) on disk are in no manifest entry, so ` +
        `nothing is known about what they are photographs of`);
    } else {
      console.log(`corpus subjects:  NOT RUN — ${report.subjects.reason}`);
    }
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
      if (report.chains.status === "checked") {
        console.log(
          `PASS — every published chain and provenance kind has a ready view ` +
          `(${report.chains.published.length} chain(s), ` +
          `${report.chains.provenanceKinds.length} kind(s))`);
      }
      if (report.subjects.status === "checked") {
        console.log(
          `PASS — every image is a photograph of the subject its view still ` +
          `resolves to (${report.subjects.compared} compared)`);
      } else if (report.subjects.status === "partial") {
        // NOT a PASS line, deliberately. `capture.mjs` replaces the manifest on
        // every run, so a targeted capture leaves one that accounts for a
        // handful of a corpus of hundreds — and F walking it would otherwise
        // print PASS having examined those few. "Compared what it could" is not
        // "every image", and this assertion's whole reason for existing is that
        // nobody could see a stale corpus.
        console.log(
          `NO VERDICT — F compared ${report.subjects.compared} of ` +
          `${report.subjects.onDisk} image(s) and found ${report.subjects.drifted} drifted, ` +
          `but ${report.subjects.unaccounted} image(s) on disk are in no manifest entry. ` +
          `The manifest is from a TARGETED capture and describes only that run. ` +
          `Run \`just capture ""\` for a corpus-wide verdict`);
      }
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
