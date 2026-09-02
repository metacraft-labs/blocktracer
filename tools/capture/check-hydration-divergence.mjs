#!/usr/bin/env node
// VD.11 verification: verify_corpus_names_the_build_it_photographs
//                 and verify_hydration_adds_no_class_the_page_cannot_draw
//
//   node tools/capture/check-hydration-divergence.mjs [--write] [--json]
//
// ── Why this exists ────────────────────────────────────────────────────────
//
// THE ARTEFACT THIS CAMPAIGN PHOTOGRAPHS IS NOT THE ARTEFACT THE VISITOR LOADS.
//
// `client/dist` — what `cd client && just export` writes, and what every ready
// view that is not `hydrated: true` is captured from (`just check-coverage`
// prints the split; this line used to say "41 of the 49 ready views") — contains
// zero `.js`. `flake.nix`'s
// `packages.default`, which IS the deployed site, runs the same exporter with
// `-d:hydrationBundle=/assets/hydrate.js`, and `components/layout.debugLayout`
// emits that `<script>` on every debugger-shell route: every `debugger*` view,
// and every transaction whose trace is published. `pageLayout` emits none, so
// the explorer's other routes are the same bytes either way.
//
// That gap is not hypothetical and it has already produced two defects in the
// review record, one of them shipped:
//
//   * vd10-r2's `Supply sources` fix shipped a reason string that said "this
//     route ships no client script". True of the photographed build, FALSE of
//     the served one. A commit made to stop a control claiming what it could
//     not support misattributed its own cause.
//   * the same round's adversarial reviewer nearly filed a P1 on the engine
//     loading state before noticing that `hydrate.nim` rewrites that text on
//     the deployable build, so the state in the corpus is a capture-build
//     artefact rather than a page defect.
//
// Both are the same error, and neither is a reviewer's fault: nothing a
// reviewer reads has ever said which build the image in front of them is of.
// The brief's per-view table already carries a **Captured from** row for the
// `hydrated: true` views. The gap is that the OTHER arm said nothing, so
// the honest default reading — "this photograph is the product" — was wrong on
// exactly the views the campaign spends most of its rounds on.
//
// ── What is measured, and what deliberately is not ─────────────────────────
//
// The divergence has two halves and only one of them is knowable here.
//
//   * PRE-ENGINE. `hydrate.hydrate()` runs `upgradeCopyAffordances` first and
//     unconditionally — no worker, no wasm, no engine — then `announceLanding`.
//     Every visitor gets this, on every browser, whatever the engine does.
//     Fully determined by two artefacts this repository builds, so it is
//     measured here, exactly.
//   * POST-ENGINE. What the live session then paints. It depends on the 18 MB
//     replay wasm this repository deliberately does not vendor, and the harness
//     refuses to stand in for an engine that SUCCEEDS (`views.mjs`: "a stub
//     that pretended to step would file a fabricated session under the name of
//     a real one"). So it is NOT measured, and the divergence reported below is
//     a LOWER BOUND. Assertion H1's sentence says so, in the brief, where a
//     reviewer will read it.
//
// ── The assertions ─────────────────────────────────────────────────────────
//
//   H1. THE CORPUS NAMES THE BUILD IT PHOTOGRAPHS. For every ready view
//       captured from the plain tree, decide from the built trees — not from a
//       list — whether the route it photographs carries the hydration bundle on
//       the deployable build. The answer is committed to
//       `tools/capture/hydration-divergence.json`, `render-brief.mjs` renders
//       it into every affected view's block, and this assertion fails when the
//       committed answer and the built trees disagree. A view that starts
//       serving a session, or stops, moves its own brief row.
//
//       NOT RUN without both trees, and never passed: a check that cannot see
//       the hydrated build knows nothing, and `just capture ""` builds it.
//
//   H2. HYDRATION ADDS NO CLASS THE PAGE CANNOT DRAW. Every class literal the
//       BUILT bundle adds (`classList.add("…")` in `client/hydrate/hydrate.js`,
//       which is the shipped artefact rather than its source) must have at
//       least one rule in the stylesheet those pages inline, or be listed in
//       `UNSTYLED_BY_DESIGN` with the reason it needs none.
//
//       This is the assertion the campaign structurally could not make. A class
//       that only ever exists on the served build is invisible to every capture
//       and to every reviewer, so a control the bundle promises and the
//       stylesheet cannot draw survives every check in the pipeline. It is the
//       affordance-that-lies defect with a build boundary hiding it, and this
//       repository removes affordances for exactly that reason.
//
//       Runs against the bundle and the built stylesheet, so it needs a build
//       too — but only `just hydrate` plus `just export`, not a capture.

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join, dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

import { VIEWS } from "./views.mjs";
import { buildEntityIndex } from "./lib/entities.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const DIST = join(REPO_ROOT, "client", "dist");
const DIST_HYDRATED = join(REPO_ROOT, "client", "dist-hydrated");
const BUNDLE = join(REPO_ROOT, "client", "hydrate", "hydrate.js");
export const MAP_PATH = join(HERE, "hydration-divergence.json");

/** The `<script>` `layout.hydrationScriptTag()` emits. Matched on the URL
 *  rather than on the whole tag so an attribute-order change in the SSR
 *  codegen does not read as "the bundle stopped shipping". */
const BUNDLE_URL = "/assets/hydrate.js";

/** Classes the bundle adds that the stylesheet is right not to have a rule for.
 *
 *  EMPTY, and it should be hard to add to. Every name here is a claim that a
 *  class the shipped bundle puts on a visitor's page needs no rule to draw it,
 *  and that claim is exactly the one this assertion exists to stop being made
 *  by accident. `off` — the only other literal the bundle adds — is NOT here
 *  because it does not need to be: it is `dcbtn`'s disabled state and
 *  `debugger_css.nim` already draws it.
 *
 *  In particular this is not the place to silence `.copybtn`, `.copied` and
 *  `.copyfailed`. See QUEUED-DECISIONS Q23: they are undrawn because of a
 *  defect, not because they were meant to be. */
const UNSTYLED_BY_DESIGN = new Map([]);

// ── The trees ──────────────────────────────────────────────────────────────

function readTreeFile(root, route, expectHttpStatus = 200) {
  // `serveDist`'s resolution, minus the parts a route never uses: strip the
  // query and the fragment (a static tree serves one file per path, which is
  // §6.0a's whole problem), then try the path and then its index.html.
  //
  // A view that declares a 404 is resolved to `404.html`, exactly as the
  // capture server resolves it. `not-found` points at an address the tree does
  // not publish ON PURPOSE, and reporting that as "unresolved" would be this
  // check calling the corpus's one deliberate miss a fault.
  const clean = route.split(/[?#]/)[0].replace(/\/+$/, "");
  const candidates =
    expectHttpStatus === 404
      ? [join(root, "404.html")]
      : [join(root, clean, "index.html"), join(root, clean), join(root, clean + ".html")];
  for (const c of candidates) {
    try {
      if (statSync(c).isFile()) return { path: c, body: readFileSync(c, "utf8") };
    } catch {
      /* next */
    }
  }
  return null;
}

/** The stylesheet the pages inline, taken from a BUILT page rather than from
 *  the Nim source: what matters is the bytes that reach the browser, and
 *  `styles.nim` + `debugger_css.nim` are concatenated by `layout.nim` at
 *  export time. Any built page carries the whole sheet. */
function inlinedStylesheet(root) {
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) stack.push(p);
      else if (e.name === "index.html") {
        const html = readFileSync(p, "utf8");
        const m = html.match(/<style>([\s\S]*?)<\/style>/);
        if (m) return { css: m[1], from: p };
      }
    }
  }
  return null;
}

/** Class literals the SHIPPED bundle adds to the document.
 *
 *  Read out of `hydrate.js` and not out of `hydrate.nim`, because the bundle is
 *  the artefact served and the question is what it does to a visitor's page.
 *  `nim js` emits `classList.add("copybtn")` verbatim for a literal; a computed
 *  argument (`classList.add(Temporary1)`, which is `bindCopy`'s
 *  succeeded/failed ternary) is reported separately, since a name this scan
 *  cannot see is a name the stylesheet cannot be checked against. */
export function classesAddedByBundle(js) {
  const literals = new Set();
  let computed = 0;
  for (const m of js.matchAll(/classList\.add\(\s*("([^"\\]*)"|'([^'\\]*)')\s*\)/g)) {
    literals.add(m[2] ?? m[3]);
  }
  for (const _ of js.matchAll(/classList\.add\(\s*(?!["'])/g)) computed++;
  return { literals: [...literals].sort(), computed };
}

/** Class literals a COMPUTED `classList.add` can reach, recovered from the Nim
 *  source's string literals in the same expression.
 *
 *  Deliberately narrow: it looks only for the one construct the bundle uses —
 *  `classList.add(if …: "a".cstring else: "b".cstring)` — because a scan that
 *  guessed would report classes the bundle cannot add and teach its reader to
 *  ignore it. Everything it cannot recover is COUNTED and reported, never
 *  silently dropped. */
export function classesAddedByTernary(nim) {
  const found = new Set();
  for (const m of nim.matchAll(
    /classList\.add\(\s*if[^)]*?"([^"]+)"\.cstring\s+else:\s*"([^"]+)"\.cstring\s*\)/g,
  )) {
    found.add(m[1]);
    found.add(m[2]);
  }
  return [...found].sort();
}

/** Does the built stylesheet have a RULE for this class — not merely the
 *  characters somewhere in a comment? `.copied` appears twice in the shipped
 *  sheet, both times as the English word inside a comment, and a substring
 *  search would have called that styled. */
export function stylesheetDrawsClass(css, cls) {
  const stripped = css.replace(/\/\*[\s\S]*?\*\//g, "");
  return new RegExp(`\\.${cls.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?![\\w-])`).test(stripped);
}

// ── H1 ─────────────────────────────────────────────────────────────────────

function measureRoutes() {
  if (!existsSync(DIST)) return { ok: false, reason: `no plain build at ${DIST}` };
  if (!existsSync(DIST_HYDRATED)) {
    return {
      ok: false,
      reason:
        `no hydrated build at ${DIST_HYDRATED} — this check compares the two ` +
        `trees, so with one of them missing it knows nothing. \`just capture ""\` ` +
        `builds both`,
    };
  }
  const index = buildEntityIndex(DIST);
  const rows = [];
  const unresolved = [];
  for (const v of VIEWS) {
    if (v.status !== "ready") continue;
    let route;
    try {
      route = typeof v.route === "function" ? v.route(index) : v.route;
    } catch (e) {
      unresolved.push({ id: v.id, reason: e.message });
      continue;
    }
    const served = readTreeFile(DIST_HYDRATED, route, v.expectHttpStatus ?? 200);
    if (!served) {
      unresolved.push({ id: v.id, reason: `no file in the hydrated tree for ${route}` });
      continue;
    }
    rows.push({
      id: v.id,
      route,
      capturedFrom: v.hydrated ? "hydrated" : "plain",
      shipsBundle: served.body.includes(BUNDLE_URL),
    });
  }
  rows.sort((a, b) => a.id.localeCompare(b.id));
  return { ok: true, rows, unresolved };
}

/** The map, in the shape `render-brief.mjs` reads. */
export function buildMap(rows) {
  return {
    _comment:
      "Generated by tools/capture/check-hydration-divergence.mjs. Which ready " +
      "views photograph a route that carries the hydration bundle on the " +
      "DEPLOYED build (flake.nix packages.default), and are therefore captures " +
      "of a build no visitor is served. Regenerate with " +
      "`just capture-hydration-divergence-write`; `just capture-hydration-divergence` " +
      "fails when this file and the built trees disagree.",
    bundleUrl: BUNDLE_URL,
    views: Object.fromEntries(
      rows.map((r) => [r.id, { route: r.route, capturedFrom: r.capturedFrom, shipsBundle: r.shipsBundle }]),
    ),
  };
}

export function readMap() {
  if (!existsSync(MAP_PATH)) return null;
  return JSON.parse(readFileSync(MAP_PATH, "utf8"));
}

// The SENTENCES this measurement produces live in `lib/provenance.mjs`, with
// the hydrated arm's, because both renderers need both sets and a second copy
// of either is how they would drift. This module decides WHICH one applies.

// ── Run ────────────────────────────────────────────────────────────────────

function main(argv) {
  const write = argv.includes("--write");
  const asJson = argv.includes("--json");
  const out = [];
  const failures = [];
  let notRun = 0;

  // H1
  const measured = measureRoutes();
  let h1 = null;
  if (!measured.ok) {
    notRun++;
    out.push(`~ H1  NOT RUN — ${measured.reason}`);
  } else {
    const diverging = measured.rows.filter((r) => r.capturedFrom === "plain" && r.shipsBundle);
    const same = measured.rows.filter((r) => r.capturedFrom === "plain" && !r.shipsBundle);
    const hydratedArm = measured.rows.filter((r) => r.capturedFrom === "hydrated");
    h1 = { diverging, same, hydratedArm };
    const fresh = buildMap(measured.rows);
    if (write) {
      writeFileSync(MAP_PATH, JSON.stringify(fresh, null, 2) + "\n");
      out.push(`  wrote ${MAP_PATH}`);
    }
    const committed = readMap();
    if (!committed) {
      failures.push(
        `H1: no committed map at ${MAP_PATH} — run ` +
          `\`just capture-hydration-divergence-write\`, and read the diff before committing it`,
      );
    } else if (JSON.stringify(committed.views) !== JSON.stringify(fresh.views)) {
      const ids = new Set([...Object.keys(committed.views), ...Object.keys(fresh.views)]);
      const changed = [...ids].filter(
        (id) =>
          JSON.stringify(committed.views[id] ?? null) !== JSON.stringify(fresh.views[id] ?? null),
      );
      failures.push(
        `H1: the committed divergence map disagrees with the built trees on ` +
          `${changed.length} view(s): ${changed.slice(0, 8).join(", ")}` +
          (changed.length > 8 ? ", …" : "") +
          ` — a view that started or stopped serving a session moves its own brief row`,
      );
    } else {
      out.push(
        `✓ H1  ${measured.rows.length} ready view(s) resolved: ` +
          `${diverging.length} captured from the plain build on a route that SHIPS the bundle, ` +
          `${same.length} whose bytes are the same on both builds, ` +
          `${hydratedArm.length} on the hydrated arm`,
      );
    }
    for (const u of measured.unresolved) out.push(`  ! unresolved: ${u.id} — ${u.reason}`);
    if (diverging.length) {
      out.push(`  the ${diverging.length} views whose image is not the page a visitor loads:`);
      for (const r of diverging) out.push(`    ${r.id.padEnd(36)} ${r.route}`);
    }
  }

  // H2
  if (!existsSync(BUNDLE)) {
    notRun++;
    out.push(
      `~ H2  NOT RUN — no built bundle at ${BUNDLE} (\`cd client && just hydrate\`)`,
    );
  } else {
    const sheet = inlinedStylesheet(existsSync(DIST_HYDRATED) ? DIST_HYDRATED : DIST);
    if (!sheet) {
      notRun++;
      out.push("~ H2  NOT RUN — no built page to read the inlined stylesheet from");
    } else {
      const js = readFileSync(BUNDLE, "utf8");
      const { literals, computed } = classesAddedByBundle(js);
      const ternary = classesAddedByTernary(
        readFileSync(join(REPO_ROOT, "client", "hydrate", "hydrate.nim"), "utf8"),
      );
      const all = [...new Set([...literals, ...ternary])].sort();
      const undrawn = all.filter(
        (c) => !stylesheetDrawsClass(sheet.css, c) && !UNSTYLED_BY_DESIGN.has(c),
      );
      if (undrawn.length) {
        failures.push(
          `H2: the hydration bundle adds ${undrawn.length} class(es) the shipped ` +
            `stylesheet has no rule for: ${undrawn.map((c) => "." + c).join(", ")}. ` +
            `These exist only on the build a visitor loads, so no capture and no ` +
            `reviewer can see them. Draw them, or list them in UNSTYLED_BY_DESIGN ` +
            `with the reason they need no rule`,
        );
      } else {
        out.push(
          `✓ H2  ${all.length} class(es) added by the bundle, every one drawn by the ` +
            `stylesheet at ${sheet.from.slice(REPO_ROOT.length + 1)}`,
        );
      }
      // Always reported when there are any. A class name this scan cannot read
      // is a class the stylesheet cannot be checked against, so the number of
      // them is the honest measure of how much H2 does NOT cover — and a silent
      // zero-coverage scan that prints a tick is the failure this whole file is
      // about.
      if (computed) {
        out.push(
          `  · ${computed} computed classList.add call(s) in the bundle; ` +
            `${ternary.length} name(s) recovered from the source's ternaries ` +
            `(${ternary.map((c) => "." + c).join(", ") || "none"})`,
        );
      }
    }
  }

  if (asJson) {
    console.log(
      JSON.stringify(
        { ok: failures.length === 0, notRun, failures, h1: h1 && { diverging: h1.diverging } },
        null,
        2,
      ),
    );
  } else {
    for (const line of out) console.log(line);
    for (const f of failures) console.log(`✗ ${f}`);
    console.log("");
    if (failures.length) console.log(`HYDRATION DIVERGENCE: FAILED (${failures.length})`);
    else if (notRun) console.log(`HYDRATION DIVERGENCE: NO VERDICT (${notRun} assertion(s) not run)`);
    else console.log("HYDRATION DIVERGENCE: PASS");
  }
  return failures.length ? 1 : 0;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  process.exit(main(process.argv.slice(2)));
}
