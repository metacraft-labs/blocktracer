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
import { existsSync, mkdirSync, renameSync, rmSync } from "node:fs";
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
import { engineScenario, describeScenarios } from "./lib/engine-stubs.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const DEFAULT_DIST = join(REPO_ROOT, "client", "dist");
const DEFAULT_OUT = join(REPO_ROOT, "screenshots");

// ── The hydrated build, and why it is a SECOND tree ────────────────────────
//
// `runExporter` below compiles `static_export.nim` with no `-d:hydrationBundle`
// on purpose, and that has to stay true: it is what makes the 38 ready views a
// capture of the page this site serves — no script, panes rendered from
// published data, stepping controls visibly inert. Flipping the flag globally
// would move every debugger image in the corpus and would file a live session
// under the names of the pre-hydration ones.
//
// But two families of user-visible sentence exist ONLY under hydration: §6.0a's
// landing notice (the payload is in the query, and a static route serves one
// file per path, so no exported page can carry it) and the three engine-failure
// sentences (`markUnavailable` is only reachable from the bundle). Neither had
// ever been rendered by anything.
//
// So there are two trees, built from one exporter and one fixture, and a view
// declares which it belongs to. `client/dist` stays exactly what it was —
// which also keeps `tools/design/check-tokens.mjs`'s D1, which reads
// `client/dist/index.html`, reading the shipped build.
const DEFAULT_DIST_HYDRATED = join(REPO_ROOT, "client", "dist-hydrated");

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
    distHydrated: DEFAULT_DIST_HYDRATED,
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
      case "--dist-hydrated": opts.distHydrated = resolvePath(next()); break;
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
  --dist-hydrated <dir> the hydrated build the hydration-only views are served
                        from (default: client/dist-hydrated)
  --manifest <file>     manifest path (default: <out>/manifest.json)
  --json                machine-readable summary on stdout

Full regeneration is the un-filtered invocation, and it cleans <out> first.
`;

// ── The build step ─────────────────────────────────────────────────────────

function runExporter(distDir) {
  const clientDir = join(REPO_ROOT, "client");
  const r = spawnSync(
    "nim",
    // NO DEFINE, and that is now the point: the capture tree and the deployed tree are
    // the SAME tree. The synthetic fixture used to be a capture-only inclusion, which
    // meant thirty graded views were photographs of pages no visitor could reach. It is
    // published again (`static_export.nim` step 1b — it is the site's only source-level
    // recording and the home page's exhibit needs one), so the harness compiles with the
    // deployed defaults and every graded image is of a page that exists.
    ["c", "-r", "--mm:orc", "-d:isServer", "-d:release",
     "--hints:off", "src/static_export.nim"],
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

/**
 * Build the hydrated tree at `outRoot`: the bundle first, then an export that
 * names it.
 *
 * The order is `client/Justfile`'s and is the substance of it — the bundle is
 * built FIRST and only then is the exporter told a URL for it, so a page can
 * never carry a `<script>` for a file that was not produced
 * (`installHydrationBundle` re-checks that and fails the build).
 *
 * `static_export.nim`'s output directory is the constant `dist` resolved
 * against the PROCESS's working directory, while everything it reads — the
 * trace fixture, the fonts, the built bundle — is resolved from
 * `currentSourcePath`. So the tree is produced by running the same exporter
 * from a different cwd and moving the result, rather than by teaching the
 * exporter a second output path that only this harness would ever pass.
 *
 * Returns `{ ok: true }`, or `{ ok: false, reason }` — never throws. A checkout
 * with no CodeTracer Embed SDK on its Nim path cannot build the bundle
 * (`hydrate/build.sh` exits 3, which is `replay_engine.HydrationBundle`'s
 * documented state, not a fault), and that must degrade to "these views were
 * not captured, and here is why" rather than to no corpus at all.
 */
function runHydratedExporter(outRoot) {
  const clientDir = join(REPO_ROOT, "client");
  const buildDir = join(clientDir, ".hydrated-build");

  const bundle = spawnSync(join(clientDir, "hydrate", "build.sh"), [], {
    cwd: REPO_ROOT,
    encoding: "utf8",
  });
  if (bundle.error) return { ok: false, reason: `hydrate/build.sh: ${bundle.error.message}` };
  if (bundle.status === 3) {
    return {
      ok: false,
      reason:
        "no CodeTracer Embed SDK on the Nim path, so there is no hydration " +
        "bundle to export (hydrate/build.sh exit 3; the pinned commit is in " +
        "ci/embed-sdk-pin.env, and $CODETRACER_SRC or a ../codetracer sibling " +
        "satisfies it — the repository's own devShell sets it)",
    };
  }
  if (bundle.status !== 0) {
    const why = (bundle.stderr || bundle.stdout || "").trim().split("\n").slice(-4).join("\n");
    return { ok: false, reason: `hydrate/build.sh failed:\n${why}` };
  }

  rmSync(buildDir, { recursive: true, force: true });
  mkdirSync(buildDir, { recursive: true });
  const r = spawnSync(
    "nim",
    [
      "c", "-r", "--mm:orc", "-d:isServer", "-d:release", "--hints:off",
      // A NO-OP, KEPT ONLY UNTIL SOMEONE DELETES IT, and the comment that used to
      // stand here — "Same reason as `runExporter`: the eight hydrated views are all
      // fixture-driven" — was wrong twice over. `runExporter` passes NO define and
      // its own comment says that is the point; and `static_export.nim` publishes the
      // synthetic chain under `when not defined(noDemoChain)`, so nothing reads
      // `publishDemoChain` anywhere in the tree. See the note in `check-coverage.mjs`
      // beside the chain-mismatch detection, which records the same flip.
      "-d:publishDemoChain",
      "-d:hydrationBundle=/assets/hydrate.js",
      `--nimcache:${join(clientDir, "nimcache-hydrated")}`,
      `-o:${join(buildDir, "static_export_hydrated")}`,
      join(clientDir, "src", "static_export.nim"),
    ],
    { cwd: buildDir, encoding: "utf8" },
  );
  if (r.error || r.status !== 0) {
    const why = r.error ? r.error.message : (r.stderr || "").trim().split("\n").slice(-5).join("\n");
    return { ok: false, reason: `hydrated static export failed:\n${why}` };
  }
  const produced = join(buildDir, "dist");
  if (!existsSync(produced)) {
    return { ok: false, reason: `hydrated exporter wrote no tree at ${produced}` };
  }
  rmSync(outRoot, { recursive: true, force: true });
  renameSync(produced, outRoot);
  rmSync(buildDir, { recursive: true, force: true });
  return { ok: true };
}

/** Both trees must be built from ONE fixture, or a view's subject is not the
 *  transaction its name claims. Cheap, targeted, and about the thing that would
 *  actually go wrong: a stale `dist-hydrated` left behind by `--no-build`. */
function assertSameFixture(plain, hydrated) {
  const key = (ix) =>
    JSON.stringify({ chain: ix.primaryChain, txs: ix.chain().txs.map((t) => t.hash) });
  if (key(plain) !== key(hydrated)) {
    throw new Error(
      "the plain and hydrated trees were built from different fixtures — the " +
        "hydration-only views would be captured against different transactions " +
        "from the ones their names resolve. Rebuild both (drop --no-build).",
    );
  }
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

/** The chain a captured route belongs to, or `null` for a site-level page.
 *
 *  The first path segment, checked against the registry rather than assumed:
 *  `/chains`, `/about` and `/settings` are site-level and have a first segment
 *  too, and calling one of those a chain would put a phantom into the manifest
 *  that assertion F would then compare against nothing. */
export const chainOfPath = (path, index) => {
  const first = String(path ?? "").split("?")[0].split("/").filter(Boolean)[0];
  return first && index.chains.includes(first) ? first : null;
};

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

  // Which tree, and — for a hydrated view — what answers at the engine's path.
  // `originFor` throws only for a scenario name no stub implements; a hydrated
  // build that could not be produced is reported as a per-image reason so the
  // rest of the corpus still captures.
  let origin;
  try {
    origin = ctx.originFor(view);
  } catch (e) {
    return { ok: false, reason: e.message, url: null };
  }

  const context = await browser.newContext(contextOptions({ size: sizeSpec, theme }));
  try {
    await prepareContext(context, { theme });
    const page = await context.newPage();

    const path = typeof view.route === "function" ? view.route(ctx.index) : view.route;
    const url = origin + path;

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
    // WHOSE DATA this image is of, recorded at capture time.
    //
    // `url` alone already pins it, and `check-coverage`'s assertion F compares
    // exactly that. These two are carried beside it so a drift failure can say
    // what actually changed — "captured from a synthetic chain, now resolves to
    // a real one" is a different problem from "same chain, different
    // transaction", and a reader of the failure should not have to work out
    // which by reading two URLs character by character.
    const capturedChain = chainOfPath(path, ctx.index);
    return {
      ok: true,
      file,
      url: path,
      chain: capturedChain,
      provenanceKind:
        capturedChain ? (ctx.index.byChain[capturedChain]?.provenanceKind ?? null) : null,
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
          (v.hydrated ? `  [hydrated · engine: ${v.engine}]` : "") +
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

  // 3a. The hydrated tree, if anything targeted needs one. Built only on
  //     demand: it costs a `nim js` of the whole Embed SDK, and 63 of the 79
  //     views do not want it.
  const wantsHydrated = allTargets.some((t) => t.view.status === "ready" && t.view.hydrated);
  let hydratedBuild = { ok: false, reason: "not requested by any target view" };
  let hydratedFixture = null;
  if (wantsHydrated) {
    if (opts.build) {
      hydratedBuild = runHydratedExporter(opts.distHydrated);
      if (!hydratedBuild.ok) console.warn(`! no hydrated build: ${hydratedBuild.reason}`);
    } else if (existsSync(opts.distHydrated)) {
      hydratedBuild = { ok: true, reused: true };
    } else {
      hydratedBuild = {
        ok: false,
        reason: `--no-build was given and there is no hydrated tree at ${opts.distHydrated}`,
      };
      console.warn(`! no hydrated build: ${hydratedBuild.reason}`);
    }
    if (hydratedBuild.ok) {
      assertSameFixture(index, buildEntityIndex(opts.distHydrated));
      hydratedFixture = await digestTree(opts.distHydrated);
    }
  }
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
  //
  // One server per (tree, engine scenario), created on demand. The plain tree
  // needs one; each hydrated view names the scenario its image is OF, and two
  // views that name the same one share a server.
  const servers = { plain: await serveDist(opts.dist) };
  const enginesUsed = new Set();
  const originFor = (view) => {
    if (!view.hydrated) return servers.plain.origin;
    if (!hydratedBuild.ok) {
      throw new Error(`hydration-only view, and no hydrated build: ${hydratedBuild.reason}`);
    }
    const scenario = engineScenario(view.engine);
    const key = `hydrated:${scenario.id}`;
    if (!servers[key]) {
      throw new Error(`internal: no server for ${key}`);
    }
    enginesUsed.add(scenario.id);
    return servers[key].origin;
  };
  if (hydratedBuild.ok) {
    for (const id of new Set(
      allTargets.filter((t) => t.view.hydrated).map((t) => t.view.engine),
    )) {
      const scenario = engineScenario(id);
      servers[`hydrated:${scenario.id}`] = await serveDist(opts.distHydrated, {
        overlay: scenario.overlay,
      });
    }
  }

  const browser = await chromium.launch({ args: CHROMIUM_ARGS, chromiumSandbox: false });
  const ctx = { origin: servers.plain.origin, originFor, index, outDir: opts.out };

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
        // Which tree and which engine produced this image. Recorded per image,
        // not per run: an engine-failure image whose provenance is not on the
        // record is one a reader has to take on trust.
        tree: t.view.hydrated ? "hydrated" : "static",
        engine: t.view.hydrated ? t.view.engine : null,
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
    for (const s of Object.values(servers)) await s.close();
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
      // The second tree, and what it is FOR. Present only when a targeted view
      // needed it, and carrying its own digest: the two trees are built from
      // one fixture and one exporter and differ by the hydration bundle alone,
      // so two digests that move independently is a finding.
      hydrated: {
        dist: opts.distHydrated,
        built: hydratedBuild.ok,
        reused: hydratedBuild.reused ?? false,
        reason: hydratedBuild.ok ? null : hydratedBuild.reason,
        treeDigest: hydratedFixture?.digest ?? null,
        fileCount: hydratedFixture?.fileCount ?? null,
        why:
          "-d:hydrationBundle=/assets/hydrate.js. §6.0a's landing notice and " +
          "the three engine-failure sentences are rendered by the bundle and " +
          "by nothing else; the static tree above is unchanged and is what " +
          "every other view is captured from.",
      },
    },
    // The stand-in engines. NOT files in either tree — the capture server
    // answers `/replay-engine/worker.js` with these, one scenario per view, so
    // the pages themselves stay byte-for-byte what the exporter wrote. See
    // tools/capture/lib/engine-stubs.mjs.
    engineScenarios: describeScenarios(),
    engineScenariosUsed: [...enginesUsed].sort(),
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
    if (wantsHydrated) {
      console.log(
        hydratedBuild.ok
          ? `hydrated:  ${opts.distHydrated} — engine scenarios: ${[...enginesUsed].sort().join(", ") || "none"}`
          : `hydrated:  NOT BUILT — ${hydratedBuild.reason}`,
      );
    }
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
        ? "identical light/dark pairs mean the two captures produced the same bytes, and THE CAUSE IS NOT ESTABLISHED — investigate rather than filing it as known. This note used to name one: 'the design-system bridge emits a dark-only token set'. It does not. `client/src/design_system/tokens.nim` builds `:root{base + explorer + LIGHT}` and then emits [data-theme=\"light\"] and [data-theme=\"dark\"] overrides in both directions, and `client/tests/test_static_export.nim` asserts both themes exist and differ. An identical pair is therefore evidence about the capture path or the theme switch, not about the token layer."
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
