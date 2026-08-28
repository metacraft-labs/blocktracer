#!/usr/bin/env node
// BlockTracer visual-design capture harness (VD.0).
//
//   node tools/capture/capture.mjs                       full regeneration
//   node tools/capture/capture.mjs --view tx-detail      one view, all sizes/themes
//   node tools/capture/capture.mjs --view home --size wide --theme dark
//   node tools/capture/capture.mjs --size mobile         one viewport, every view
//   node tools/capture/capture.mjs --canary              the determinism canary only
//   node tools/capture/capture.mjs --list                print the view list, capture nothing
//
// Full regeneration — no --view, --size, --theme or --canary filter — CLEANS
// the output directory first, so a renamed or deleted view leaves no stale
// image behind. A targeted run never cleans; it overwrites only what it
// targets, and `--prune` removes orphans without a full recapture.

import { mkdir, rm, readdir, writeFile, readFile, stat } from "node:fs/promises";
import { existsSync } from "node:fs";
import { join, dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";

import { chromium } from "playwright";

import {
  VIEWS,
  VIEWS_BY_ID,
  SIZES,
  ALL_SIZES,
  THEMES,
  CANARY,
  FROZEN_TIME,
  sizesFor,
  themesFor,
  imageName,
} from "./views.mjs";
import { buildEntityIndex } from "./lib/entities.mjs";
import { serveDist } from "./lib/server.mjs";
import {
  CHROMIUM_ARGS,
  contextOptions,
  prepareContext,
  settlePage,
  SETTLE_BUDGET_MS,
} from "./lib/determinism.mjs";
import { describePinnedEnv } from "./lib/pinned-env.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const DEFAULT_DIST = join(REPO_ROOT, "client", "dist");
const DEFAULT_OUT = join(REPO_ROOT, "screenshots");

// ── CLI ────────────────────────────────────────────────────────────────────

function parseArgs(argv) {
  const opts = {
    views: [],
    sizes: [],
    themes: [],
    canary: false,
    list: false,
    build: true,
    prune: false,
    includePending: false,
    json: false,
    out: DEFAULT_OUT,
    dist: DEFAULT_DIST,
    manifest: null,
  };
  const multi = (v) => String(v).split(",").map((s) => s.trim()).filter(Boolean);
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    const next = () => argv[++i];
    switch (a) {
      case "--view": opts.views.push(...multi(next())); break;
      case "--size": opts.sizes.push(...multi(next())); break;
      case "--theme": opts.themes.push(...multi(next())); break;
      case "--canary": opts.canary = true; break;
      case "--list": opts.list = true; break;
      case "--build": opts.build = true; break;
      case "--no-build": opts.build = false; break;
      case "--prune": opts.prune = true; break;
      case "--include-pending": opts.includePending = true; break;
      case "--json": opts.json = true; break;
      case "--out": opts.out = resolvePath(next()); break;
      case "--dist": opts.dist = resolvePath(next()); break;
      case "--manifest": opts.manifest = resolvePath(next()); break;
      case "-h":
      case "--help": opts.help = true; break;
      default:
        throw new Error(`unknown argument: ${a}`);
    }
  }
  opts.manifest ??= join(opts.out, "manifest.json");
  return opts;
}

const HELP = `
BlockTracer capture harness (VD.0)

  --view <id[,id]>      capture only these named views
  --size <name[,name]>  capture only these viewports (${ALL_SIZES.join(", ")})
  --theme <name[,name]> capture only these themes (${THEMES.join(", ")})
  --canary              capture only the determinism canary set
  --include-pending     also capture views whose route the client does not serve yet
  --list                print the view list and exit
  --no-build            do not re-run the static exporter first
  --prune               delete images that no longer correspond to a view
  --out <dir>           output directory (default: screenshots/)
  --dist <dir>          built site to serve (default: client/dist)
  --manifest <file>     manifest path (default: <out>/manifest.json)
  --json                machine-readable summary on stdout

Full regeneration is the un-filtered invocation, and it cleans <out> first.
`;

// ── The build step ─────────────────────────────────────────────────────────

function runExporter(distDir) {
  const clientDir = join(REPO_ROOT, "client");
  const r = spawnSync(
    "nim",
    ["c", "-r", "--mm:orc", "-d:isServer", "-d:release", "--hints:off", "src/static_export.nim"],
    { cwd: clientDir, encoding: "utf8" },
  );
  if (r.error || r.status !== 0) {
    const why = r.error ? r.error.message : (r.stderr || "").trim().split("\n").slice(-5).join("\n");
    if (existsSync(distDir)) {
      console.warn(`! static exporter did not run (${why})\n! capturing the existing ${distDir} instead`);
      return false;
    }
    throw new Error(`static exporter failed and there is no existing dist to fall back to:\n${why}`);
  }
  return true;
}

// ── Target selection ───────────────────────────────────────────────────────

function selectTargets(opts) {
  let views = VIEWS;
  let fromCanary = null;

  if (opts.canary) {
    fromCanary = CANARY;
  }

  if (opts.views.length) {
    const unknown = opts.views.filter((id) => !VIEWS_BY_ID.has(id));
    if (unknown.length) throw new Error(`unknown view(s): ${unknown.join(", ")}`);
    views = views.filter((v) => opts.views.includes(v.id));
  }

  const targets = [];
  if (fromCanary) {
    for (const c of fromCanary) {
      const view = VIEWS_BY_ID.get(c.view);
      if (!view) throw new Error(`canary names an unknown view: ${c.view}`);
      if (opts.views.length && !opts.views.includes(view.id)) continue;
      if (opts.sizes.length && !opts.sizes.includes(c.size)) continue;
      if (opts.themes.length && !opts.themes.includes(c.theme)) continue;
      targets.push({ view, size: c.size, theme: c.theme, renderingPath: c.renderingPath });
    }
  } else {
    for (const view of views) {
      for (const size of sizesFor(view)) {
        if (opts.sizes.length && !opts.sizes.includes(size)) continue;
        for (const theme of themesFor(view)) {
          if (opts.themes.length && !opts.themes.includes(theme)) continue;
          targets.push({ view, size, theme });
        }
      }
    }
  }
  return targets;
}

const isFullRegen = (opts) =>
  !opts.canary && opts.views.length === 0 && opts.sizes.length === 0 && opts.themes.length === 0;

// ── Digests ────────────────────────────────────────────────────────────────

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

async function digestTree(dir) {
  // A single digest over the served bytes, so "the fixture changed" is
  // distinguishable from "the renderer changed" when a hash moves.
  const files = [];
  async function walk(d, prefix) {
    for (const e of (await readdir(d, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name))) {
      const p = join(d, e.name);
      const rel = prefix ? `${prefix}/${e.name}` : e.name;
      if (e.isDirectory()) await walk(p, rel);
      else if (e.isFile()) files.push([rel, await readFile(p)]);
    }
  }
  await walk(dir, "");
  const h = createHash("sha256");
  for (const [rel, buf] of files) h.update(rel).update("\0").update(sha256(buf)).update("\n");
  return { digest: h.digest("hex"), fileCount: files.length };
}

// ── Capture ────────────────────────────────────────────────────────────────

async function captureOne(browser, { view, size, theme }, ctx) {
  const sizeSpec = SIZES[size];
  if (!sizeSpec) throw new Error(`unknown size: ${size}`);

  const context = await browser.newContext(contextOptions({ size: sizeSpec, theme }));
  try {
    await prepareContext(context, { theme });
    const page = await context.newPage();

    const path = typeof view.route === "function" ? view.route(ctx.index) : view.route;
    const url = ctx.origin + path;

    const response = await page.goto(url, { waitUntil: "commit", timeout: 30000 });
    const httpStatus = response ? response.status() : null;
    const expected = view.expectHttpStatus ?? 200;
    if (httpStatus !== expected) {
      return {
        ok: false,
        reason: `HTTP ${httpStatus} at ${path} (expected ${expected})`,
        url: path,
      };
    }

    if (view.offline) {
      await settlePage(page);
      await context.setOffline(true);
      await page.reload({ waitUntil: "commit", timeout: 30000 }).catch(() => {});
    }

    await settlePage(page);
    if (view.setup) await view.setup(page, ctx);

    const file = imageName(view.id, size, theme);
    const outPath = join(ctx.outDir, file);

    const shotOptions = {
      path: outPath,
      animations: "disabled",
      caret: "hide",
      scale: "css",
      type: "png",
    };

    if (view.clip) {
      const locator = page.locator(view.clip).first();
      if ((await locator.count()) === 0) {
        return { ok: false, reason: `clip selector not present: ${view.clip}`, url: path };
      }
      await locator.screenshot(shotOptions);
    } else {
      await page.screenshot({ ...shotOptions, fullPage: view.fullPage !== false });
    }

    const bytes = await readFile(outPath);
    return {
      ok: true,
      file,
      url: path,
      sha256: sha256(bytes),
      bytes: bytes.length,
    };
  } finally {
    await context.close();
  }
}

// ── main ───────────────────────────────────────────────────────────────────

async function main() {
  const opts = parseArgs(process.argv);
  if (opts.help) {
    console.log(HELP);
    return 0;
  }

  if (opts.list) {
    const ready = VIEWS.filter((v) => v.status === "ready");
    const pending = VIEWS.filter((v) => v.status !== "ready");
    console.log(`named views: ${VIEWS.length}  (ready ${ready.length}, pending ${pending.length})`);
    console.log(`viewports:   ${ALL_SIZES.join(", ")}`);
    console.log(`themes:      ${THEMES.join(", ")}`);
    for (const v of VIEWS) {
      const sz = sizesFor(v).join("/");
      const th = themesFor(v).join("/");
      const n = sizesFor(v).length * themesFor(v).length;
      console.log(
        `  ${v.status === "ready" ? "[ready]  " : "[pending]"} ${v.id.padEnd(34)} ${String(n).padStart(2)} img  ${sz} x ${th}` +
          (v.status === "ready" ? "" : `\n              ↳ ${v.pendingReason}`),
      );
    }
    console.log(`\ncanary (${CANARY.length} images):`);
    for (const c of CANARY) {
      const v = VIEWS_BY_ID.get(c.view);
      console.log(
        `  ${imageName(c.view, c.size, c.theme).padEnd(48)} ${c.renderingPath}` +
          (v && v.status !== "ready" ? "   [VIEW PENDING — path not covered]" : ""),
      );
    }
    return 0;
  }

  const fullRegen = isFullRegen(opts);

  // 1. Fixed fixture data — rebuild the tree the capture is taken over.
  let built = false;
  if (opts.build) built = runExporter(opts.dist);
  if (!existsSync(opts.dist)) {
    throw new Error(`no built site at ${opts.dist} (run the exporter, or pass --dist)`);
  }
  const fixture = await digestTree(opts.dist);

  // 2. Resolve the entity-backed routes.
  const index = buildEntityIndex(opts.dist);

  // 3. Targets.
  const allTargets = selectTargets(opts);
  const targets = opts.includePending
    ? allTargets
    : allTargets.filter((t) => t.view.status === "ready");
  const skippedPending = allTargets.filter((t) => t.view.status !== "ready");

  // 4. Cleanup on full regeneration.
  if (fullRegen) {
    await rm(opts.out, { recursive: true, force: true });
  }
  await mkdir(opts.out, { recursive: true });

  // 5. Serve and capture.
  const server = await serveDist(opts.dist);
  const browser = await chromium.launch({ args: CHROMIUM_ARGS, chromiumSandbox: false });
  const ctx = { origin: server.origin, index, outDir: opts.out };

  const results = [];
  const failures = [];
  try {
    for (const t of targets) {
      const started = Date.now();
      let r;
      try {
        r = await captureOne(browser, t, ctx);
      } catch (e) {
        r = { ok: false, reason: e.message };
      }
      const entry = {
        view: t.view.id,
        size: t.size,
        theme: t.theme,
        register: t.view.register,
        status: t.view.status,
        ...r,
        ms: Date.now() - started,
      };
      results.push(entry);
      if (!r.ok) failures.push(entry);
      if (!opts.json) {
        console.log(
          r.ok
            ? `  ✓ ${entry.file.padEnd(52)} ${String(entry.bytes).padStart(8)} B  ${r.sha256.slice(0, 12)}`
            : `  ✗ ${imageName(t.view.id, t.size, t.theme).padEnd(52)} ${r.reason}`,
        );
      }
    }
  } finally {
    await browser.close();
    await server.close();
  }

  // 6. Prune orphans on request (full regeneration already cleaned).
  let pruned = [];
  if (opts.prune && !fullRegen) {
    const { staleImages } = await findStale(opts.out);
    for (const f of staleImages) {
      await rm(join(opts.out, f), { force: true });
      pruned.push(f);
    }
  }

  // 7. Manifest — the record of what the images were produced by.
  const manifest = {
    tool: "blocktracer/tools/capture",
    milestone: "VD.0",
    generatedAt: new Date().toISOString(),
    mode: opts.canary ? "canary" : fullRegen ? "full-regeneration" : "targeted",
    fullRegeneration: fullRegen,
    filters: { views: opts.views, sizes: opts.sizes, themes: opts.themes },
    fixture: {
      dist: opts.dist,
      rebuilt: built,
      treeDigest: fixture.digest,
      fileCount: fixture.fileCount,
    },
    determinism: {
      frozenClock: FROZEN_TIME.toISOString(),
      settleBudgetMs: SETTLE_BUDGET_MS,
      reducedMotion: "reduce",
      timezone: "UTC",
      locale: "en-US",
      deviceScaleFactor: 1,
      chromiumArgs: CHROMIUM_ARGS,
    },
    environment: await describeEnvironment(),
    viewports: SIZES,
    themes: THEMES,
    counts: {
      namedViews: VIEWS.length,
      readyViews: VIEWS.filter((v) => v.status === "ready").length,
      pendingViews: VIEWS.filter((v) => v.status !== "ready").length,
      captured: results.filter((r) => r.ok).length,
      failed: failures.length,
      skippedPending: skippedPending.length,
      pruned: pruned.length,
    },
    // The theme axis, reported rather than assumed. Light and dark are
    // captured independently — separate contexts, separate files — but a pair
    // that comes out byte-identical means the product does not yet vary with
    // the theme, and that is a finding, not a success. VD.2 lands the colour
    // roles and VD.7 gates parity; until then this number should be small and
    // visibly so.
    themeAxis: themeAxisSummary(results),
    pruned,
    skippedPending: skippedPending.map((t) => ({
      view: t.view.id,
      size: t.size,
      theme: t.theme,
      reason: t.view.pendingReason,
    })),
    images: results,
  };
  await writeFile(opts.manifest, JSON.stringify(manifest, null, 2) + "\n");

  if (opts.json) {
    console.log(JSON.stringify(manifest, null, 2));
  } else {
    console.log("");
    console.log(`mode:      ${manifest.mode}`);
    console.log(`captured:  ${manifest.counts.captured} image(s) -> ${opts.out}`);
    if (skippedPending.length) {
      const views = [...new Set(skippedPending.map((t) => t.view.id))];
      console.log(
        `pending:   ${skippedPending.length} image(s) across ${views.length} view(s) not captured — the client does not serve them yet`,
      );
      console.log(`           (run with --include-pending to capture them anyway)`);
    }
    if (pruned.length) console.log(`pruned:    ${pruned.length} stale image(s)`);
    console.log(`manifest:  ${opts.manifest}`);
    if (failures.length) {
      console.log(`\nFAILED ${failures.length}:`);
      for (const f of failures) console.log(`  ${f.view} @ ${f.size}/${f.theme}: ${f.reason}`);
    }
  }

  return failures.length ? 1 : 0;
}

function themeAxisSummary(results) {
  const pairs = new Map();
  for (const r of results) {
    if (!r.ok) continue;
    const key = `${r.view}__${r.size}`;
    if (!pairs.has(key)) pairs.set(key, {});
    pairs.get(key)[r.theme] = r.sha256;
  }
  const complete = [...pairs.entries()].filter(([, v]) => v.light && v.dark);
  const identical = complete.filter(([, v]) => v.light === v.dark).map(([k]) => k);
  return {
    pairs: complete.length,
    differing: complete.length - identical.length,
    identical: identical.length,
    identicalPairs: identical,
    note:
      identical.length > 0
        ? "identical light/dark pairs mean the product does not yet vary with the theme; the design-system bridge emits a dark-only token set (client/src/design_system/tokens.nim). VD.2 resolves the colour roles, VD.7 gates parity."
        : null,
  };
}

async function describeEnvironment() {
  let playwrightVersion = "unknown";
  try {
    const pkg = JSON.parse(
      await readFile(join(HERE, "node_modules", "playwright", "package.json"), "utf8"),
    );
    playwrightVersion = pkg.version;
  } catch {
    try {
      const pkg = JSON.parse(
        await readFile(join(REPO_ROOT, "node_modules", "playwright", "package.json"), "utf8"),
      );
      playwrightVersion = pkg.version;
    } catch { /* leave unknown */ }
  }
  return {
    // These four are what a pinned container fixes. A hash compared across two
    // runs that differ in any of them is comparing runners, not products.
    playwright: playwrightVersion,
    node: process.version,
    platform: process.platform,
    arch: process.arch,
    // The retired container path's variables. Nothing sets them any more; they
    // are still recorded so a manifest produced by an older checkout, or by a
    // caller still exporting them, stays readable — and lib/pinned-env.mjs
    // reports the claim as unverifiable rather than honouring it.
    container: process.env.VD0_CONTAINER_IMAGE ?? null,
    containerDigest: process.env.VD0_CONTAINER_DIGEST ?? null,
    inContainer: process.env.VD0_IN_CONTAINER === "1",
    // VD.0's pinned capture environment (tools/capture/capture-env.nix). The
    // id is a content hash over every pinned input — browser bundle, font set,
    // renderer-flag file, node, system — so a manifest says which environment
    // its images came out of, and two manifests with different ids are not
    // comparable image-for-image.
    pinnedEnv: describePinnedEnv(),
  };
}

/** Images in `outDir` that no longer correspond to a named view/size/theme. */
export async function findStale(outDir) {
  const { parseImageName } = await import("./views.mjs");
  const wanted = new Set();
  for (const v of VIEWS) {
    for (const s of sizesFor(v)) for (const t of themesFor(v)) wanted.add(imageName(v.id, s, t));
  }
  let present = [];
  try {
    present = (await readdir(outDir)).filter((f) => f.endsWith(".png"));
  } catch {
    return { staleImages: [], present: [] };
  }
  const staleImages = present.filter((f) => {
    if (wanted.has(f)) return false;
    const parsed = parseImageName(f);
    return parsed === null || !VIEWS_BY_ID.has(parsed.viewId) || !wanted.has(f);
  });
  return { staleImages, present };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main()
    .then((code) => process.exit(code))
    .catch((e) => {
      console.error(`\ncapture failed: ${e.message}`);
      process.exit(2);
    });
}

export { main, selectTargets, isFullRegen };
