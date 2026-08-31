#!/usr/bin/env node
// Deploy gate — every same-origin asset a published page NAMES must exist in the
// bytes being uploaded, and every asset class that is supposed to be named must
// actually be named by something.
//
//   node tools/deploy/check-assets.mjs                        check client/dist
//   node tools/deploy/check-assets.mjs --dir <publishDir>     check another tree
//   node tools/deploy/check-assets.mjs --require-traces       a publish that
//                                                            claims to carry
//                                                            traces must prove it
//
// ── Why this file exists ───────────────────────────────────────────────────
//
// In a single day this repository shipped two green builds that were broken in
// production, and both breakages were the SAME SHAPE: a published HTML page
// named a same-origin URL that the publish directory did not contain. Nothing in
// CI reads the uploaded bytes, so nothing could see it.
//
//   1. Every page carried `data-replay-engine="/replay-engine/"` and built a
//      Worker from that URL. `/replay-engine/*` was 404 for every visitor,
//      because nothing in the pipeline had ever run `fetch-engine.sh` and the
//      directory simply was not in the publish tree. Every test passed: the
//      attribute was emitted correctly, and the attribute was all the tests
//      looked at.
//   2. `hydrate.js` was built and copied into place at 96 KB, and NO PAGE
//      REFERENCED IT. The bundle shipped, the byte count looked healthy, and
//      every debugger session was a still frame because no `<script src>` ever
//      pulled it in.
//
// Those two are mirror images, and that is the whole design of this file. A
// guard that only asks "does every reference resolve?" is green on failure 2 —
// zero references to hydrate.js is zero UNRESOLVED references to hydrate.js.
// A guard that only asks "is every file referenced?" is green on failure 1 and
// noisy about every font and icon besides. So both directions are checked, and
// the second direction is checked only for the asset CLASSES that are known to
// be pointless when unreferenced (the hydration bundle, the trace containers).
//
// ── It reads the bytes about to be uploaded, and nothing else ──────────────
//
// This checker opens the PUBLISH DIRECTORY. Not `client/src`, not `result/`.
// That is not fastidiousness: both incidents above are invisible from the source
// tree, because in both cases the source was right and the copy step was wrong.
// `result/` is a different output tree (`nix build .#default`) and rebuilding it
// changes nothing here — confusing the two has already produced one confidently
// wrong diagnosis in this repo's history, so the summary always names the exact
// directory it read.
//
// ── What "resolves" means, and why it is not just `existsSync` ─────────────
//
// The publish tree is served by a static host, so a URL and a path are not the
// same thing. `href="/aztec"` is served from `/aztec/index.html`; `href="/t/…/"`
// is a directory whose CONTENTS are the asset. A guard that demanded a regular
// file at the literal path would report several hundred failures against a
// perfectly good publish, and a guard that reports false failures is worse than
// no guard — it teaches people to route around it, and every other number this
// file prints then inherits that distrust. So resolution mirrors what a static
// host actually serves, and every resolution mode is NAMED in the output.
//
// ── What this does NOT catch, stated rather than hidden ────────────────────
//
//   * A URL assembled at RUN TIME in JavaScript from parts (`"/t/" + id +
//     "/trace.ct"`) has no attribute in the HTML for this to read. That is why
//     the exporter is expected to hand such URLs to script through a DATA
//     ATTRIBUTE — which is exactly what `data-replay-engine` and `data-trace`
//     are, and why they are scanned here alongside `src` and `href`.
//   * `url(…)` inside a `<style>` block or a `style=` attribute is not scanned.
//     Nothing in this product loads an asset that way today (the design lint
//     forbids inline styles outright), and adding it would need a CSS parse
//     rather than a larger regex.
//   * `srcset` (a comma-separated candidate list) is not scanned; this product
//     emits none. If one appears, it will be silently unchecked, which is why
//     the summary prints the attribute names it DID scan.
//   * An asset that exists, is non-empty, and is CORRUPT is out of reach of any
//     filesystem-level rule. Size > 0 is the strongest claim bytes on disk can
//     support without knowing each format.

import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, normalize, relative, resolve as resolvePath, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const DEFAULT_DIR = join(REPO_ROOT, "client", "dist");

// The hydration bundle's URL is a build-time `-d:hydrationBundle=` define, and
// `client/Justfile` sets it to this. It is written here as a literal on purpose:
// this file reads the PUBLISHED BYTES, and the published bytes are where that
// define ended up. Reading the Justfile instead would make the guard agree with
// the build configuration rather than with the deployment.
const HYDRATION_BUNDLE_URL = "/assets/hydrate.js";

// The attributes through which this product hands a same-origin URL to script.
// `src`/`href` are the HTML ones; the rest are how the exporter passes a URL
// that only JavaScript will fetch — and failure 1 above lived in exactly such an
// attribute, invisible to any check that scanned `src`/`href` alone.
//
// `data-trace` is the spelling `components/debugger.nim` emits today; the
// `data-trace-container` / `data-trace-manifest` / `data-hydration-bundle`
// spellings are accepted alongside it so that a rename of the attribute cannot
// silently drop the reference out of this scan's sight. An attribute name that
// matches nothing costs nothing here — but an emitted one that is NOT listed is
// a hole, which is why the summary prints how many hits each name got.
const URL_ATTRS = [
  "src",
  "href",
  "data-replay-engine",
  "data-hydration-bundle",
  "data-trace-container",
  "data-trace-manifest",
  "data-trace",
];

const ATTR_RE = new RegExp(
  `(?:^|[\\s"'])(${URL_ATTRS.join("|")})\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'=<>\`]+))`,
  "gi",
);

// A trace container as the routes spell it: `/t/<a>/<b>/<id>/trace.ct`. Matched
// loosely on the `/t/` prefix and the `.ct` extension so that a change to the
// sharding depth does not quietly empty this class out.
const TRACE_CONTAINER_RE = /^\/t\/.+\.ct$/;

// ── Reference extraction ───────────────────────────────────────────────────

/** The handful of HTML entities that can legally appear inside an attribute
 *  value. `&amp;` is the one that matters — a query string with two parameters
 *  is written `?a=1&amp;b=2`, and the query is stripped before resolution
 *  anyway, but decoding first keeps the reported URL the one the browser sees. */
export function decodeEntities(text) {
  return text
    .replace(/&(?:amp|#38|#x26);/gi, "&")
    .replace(/&(?:lt|#60|#x3c);/gi, "<")
    .replace(/&(?:gt|#62|#x3e);/gi, ">")
    .replace(/&(?:quot|#34|#x22);/gi, '"')
    .replace(/&(?:apos|#39|#x27);/gi, "'");
}

/** Every `attr="value"` hit for the URL-bearing attributes, in document order. */
export function extractRefs(html) {
  const out = [];
  for (const m of html.matchAll(ATTR_RE)) {
    const raw = m[2] ?? m[3] ?? m[4] ?? "";
    out.push({ attr: m[1].toLowerCase(), raw });
  }
  return out;
}

/** What KIND of reference is this, and therefore is it ours to resolve?
 *
 *  The classification is TOTAL — every value lands in exactly one kind — so
 *  "not checked" is a decision with a name and a count in the summary, rather
 *  than the default that swallowed failure 1. */
export function classifyRef(raw) {
  const v = decodeEntities(String(raw)).trim();
  if (v === "") return { kind: "empty" };
  // `#top` — a fragment on the current page names no asset.
  if (v.startsWith("#")) return { kind: "fragment" };
  // `//cdn.example.com/x.js` — protocol-relative, so off-origin.
  if (v.startsWith("//")) return { kind: "external" };
  // `https:`, `mailto:`, `tel:`, `data:`, `javascript:` — a scheme means the
  // browser does not resolve it against this origin, so neither does this file.
  // (A Windows-style `C:\…` cannot occur in emitted HTML and is not special-cased.)
  const scheme = /^([a-z][a-z0-9+.-]*):/i.exec(v);
  if (scheme) return { kind: "external", scheme: scheme[1].toLowerCase() };
  // Anything not rooted at `/` is document-relative. This product emits absolute
  // URLs throughout, so a relative one is unexpected rather than wrong; it is
  // counted and reported rather than resolved, because resolving it correctly
  // needs the referring page's directory and there is nothing here to test that
  // against.
  if (!v.startsWith("/")) return { kind: "relative", url: v };
  // Strip the fragment first, then the query: `/a?b#c` and `/a#b?c` both name
  // the asset `/a`. A `?v=2` cache-buster is the ordinary case and must never
  // produce a failure.
  const path = v.split("#")[0].split("?")[0];
  return { kind: "same-origin", url: v, path: path === "" ? "/" : path };
}

const statOf = (p) => { try { return statSync(p); } catch { return null; } };

/** A same-origin URL path → what the static host would serve for it.
 *
 *  status is one of:
 *    ok       — the host serves non-empty bytes; `how` names the resolution mode
 *    missing  — nothing is there (A1)
 *    empty    — it is there and it is empty; `want` says file (A2) or directory (A1)
 *    escapes  — the path climbs out of the publish root, so it can never resolve (A1) */
export function resolveRef(dir, urlPath) {
  // Percent-escapes are part of the URL, not of the filename. Decode, but never
  // let a malformed escape throw — a bad reference must be REPORTED, not crash
  // the gate.
  let rel;
  try { rel = decodeURIComponent(urlPath); } catch { rel = urlPath; }
  rel = rel.replace(/^\/+/, "");
  const target = normalize(join(dir, rel));
  if (target !== dir && !target.startsWith(dir + sep)) {
    return { status: "escapes", target };
  }

  const st = statOf(target);

  // A trailing slash names a DIRECTORY, and the asset is its contents —
  // `/replay-engine/` is the engine's whole payload, and failure 1 was that
  // directory being absent. "Exists but empty" is as broken as absent, and is
  // reported as an A1 failure rather than an A2 one: A2's subject is a
  // zero-byte FILE, which is what a `cp` that ran out of space leaves behind.
  if (urlPath.endsWith("/")) {
    if (!st || !st.isDirectory()) return { status: "missing", target, want: "directory" };
    const kids = readdirSync(target);
    if (kids.length === 0) return { status: "empty", target, want: "directory" };
    return { status: "ok", target, how: `directory (${kids.length} entries)` };
  }

  if (st && st.isFile()) {
    return st.size > 0
      ? { status: "ok", target, how: `file (${st.size} bytes)` }
      : { status: "empty", target, want: "file" };
  }

  // A clean URL: `href="/aztec"` with a directory at that path is served from
  // its index document. Requiring a regular file here would fail every internal
  // link this site emits, which is how a real guard becomes a disabled guard.
  if (st && st.isDirectory()) {
    const idx = join(target, "index.html");
    const ist = statOf(idx);
    if (ist && ist.isFile()) {
      return ist.size > 0
        ? { status: "ok", target: idx, how: "directory index" }
        : { status: "empty", target: idx, want: "file" };
    }
    return { status: "missing", target: idx, want: "directory index" };
  }

  // Extensionless mapping: some static hosts serve `/about` from `/about.html`.
  const asHtml = target + ".html";
  const hst = statOf(asHtml);
  if (hst && hst.isFile()) {
    return hst.size > 0
      ? { status: "ok", target: asHtml, how: "extensionless .html" }
      : { status: "empty", target: asHtml, want: "file" };
  }

  return { status: "missing", target, want: "file" };
}

// ── The publish tree ───────────────────────────────────────────────────────

export function walkFiles(dir) {
  const out = [];
  let entries;
  try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return out; }
  for (const e of [...entries].sort((a, b) => a.name.localeCompare(b.name))) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...walkFiles(p));
    else if (e.isFile()) out.push(p);
  }
  return out;
}

// ── The checks ─────────────────────────────────────────────────────────────

export function run({ dir, requireTraces }) {
  const checks = [];
  /** ok === true PASS, false FAIL, null NOT REQUIRED (never counted as a pass). */
  const add = (id, title, ok, detail) => checks.push({ id, title, ok, detail });

  const rel = (p) => relative(dir, p) || ".";
  const files = walkFiles(dir);
  const pages = files.filter((f) => f.toLowerCase().endsWith(".html"));

  // ── A5 first, because it decides whether the rest MEAN anything ──────────
  //
  // A1 over an empty directory is a vacuous pass: zero references, zero
  // unresolved references, green. That is the failure mode this whole file
  // exists to close, so the emptiness of the subject is itself a check.
  const dirStat = statOf(dir);
  const indexStat = statOf(join(dir, "index.html"));
  const hasIndex = !!indexStat && indexStat.isFile() && indexStat.size > 0;
  if (!dirStat || !dirStat.isDirectory()) {
    add("A5", "the publish directory exists, is not empty, and has an index.html", false,
      `${dir} is not a directory — there is nothing to publish and nothing to check`);
  } else if (files.length === 0) {
    add("A5", "the publish directory exists, is not empty, and has an index.html", false,
      `${dir} contains no files — every other check below would pass vacuously over it`);
  } else if (!hasIndex) {
    add("A5", "the publish directory exists, is not empty, and has an index.html", false,
      `${files.length} file(s) but no non-empty index.html at the root of ${dir} — ` +
      `the site's entry point is what a visitor gets first, and its absence is a broken publish`);
  } else {
    add("A5", "the publish directory exists, is not empty, and has an index.html", true,
      `${files.length} file(s), ${pages.length} .html page(s), index.html ${indexStat.size} bytes`);
  }

  // ── Scan every page ──────────────────────────────────────────────────────
  const kinds = { "same-origin": 0, external: 0, relative: 0, fragment: 0, empty: 0 };
  const attrHits = new Map(URL_ATTRS.map((a) => [a, 0]));
  const missing = [];      // A1
  const emptyDirs = [];    // A1 — named directory exists but has nothing in it
  const escaping = [];     // A1 — the reference climbs out of the publish root
  const zeroByte = [];     // A2
  const relatives = [];    // reported, not failed
  const distinct = new Map();          // resolved target → first reference
  const containerRefs = [];            // A3 — `/t/**/*.ct` named by a page
  const bundleRefs = [];               // A4 — pages naming the hydration bundle

  for (const page of pages) {
    let html;
    try { html = readFileSync(page, "utf8"); } catch { continue; }
    for (const { attr, raw } of extractRefs(html)) {
      attrHits.set(attr, attrHits.get(attr) + 1);
      const c = classifyRef(raw);
      kinds[c.kind]++;
      if (c.kind === "relative") { relatives.push({ page: rel(page), attr, url: c.url }); continue; }
      if (c.kind !== "same-origin") continue;

      const r = resolveRef(dir, c.path);
      const where = { page: rel(page), attr, url: c.url, path: c.path };
      if (r.status === "ok") {
        if (!distinct.has(r.target)) distinct.set(r.target, where);
      } else if (r.status === "missing") {
        missing.push({ ...where, want: r.want, target: rel(r.target) });
      } else if (r.status === "escapes") {
        escaping.push({ ...where, target: r.target });
      } else if (r.status === "empty" && r.want === "directory") {
        emptyDirs.push({ ...where, target: rel(r.target) });
      } else {
        zeroByte.push({ ...where, target: rel(r.target) });
      }

      if (TRACE_CONTAINER_RE.test(c.path)) containerRefs.push(where);
      if (c.path === HYDRATION_BUNDLE_URL) bundleRefs.push(where);
    }
  }

  const fmt = (arr, render, n = 15) =>
    arr.slice(0, n).map((v) => `        ${render(v)}`).join("\n") +
    (arr.length > n ? `\n        … and ${arr.length - n} more` : "");
  const refLine = (v) => `${v.page}  ${v.attr}="${v.url}"  → ${v.target ?? v.path}`;

  // ── A1 — every same-origin reference resolves to something non-empty ─────
  const a1 = [
    ...missing.map((v) => ({ ...v, why: `no ${v.want}` })),
    ...emptyDirs.map((v) => ({ ...v, why: "directory is empty" })),
    ...escaping.map((v) => ({ ...v, why: "path climbs out of the publish root" })),
  ];
  add("A1", "every same-origin asset reference resolves", a1.length === 0,
    a1.length
      ? `${a1.length} unresolved reference(s) — each is a 404 for every visitor:\n` +
        fmt(a1, (v) => `${refLine(v)}  (${v.why})`)
      : `${kinds["same-origin"]} same-origin reference(s) across ${pages.length} page(s) all resolve; ` +
        `${distinct.size} distinct asset(s)`);

  // ── A2 — an asset that exists and is zero bytes ──────────────────────────
  //
  // Counted apart from A1 on purpose. A missing file is a build that never ran;
  // a zero-byte file is a build whose COPY ran and failed — a `cp` out of disk
  // space, an interrupted upload — and it is the one that looks healthiest in a
  // file listing. The two have different causes and different fixes, so they get
  // different names.
  add("A2", "no published page names a zero-byte asset", zeroByte.length === 0,
    zeroByte.length
      ? `${zeroByte.length} reference(s) to a file that exists and is EMPTY — ` +
        `the copy step ran and produced nothing:\n` + fmt(zeroByte, refLine)
      : `0 of ${distinct.size} referenced asset(s) are zero bytes`);

  // ── A3 — the trace-container class is not vacuous ────────────────────────
  //
  // A publish that claims to carry real traces and names none of them is
  // failure 2's shape applied to the debugger's data: the containers ship, no
  // page points at one, and every session is empty. Both halves are required —
  // at least one page must NAME a container, and every container present must
  // have bytes in it. The second half deliberately overlaps A2 for the named
  // containers, because it also covers the ones no page names.
  const traceRoot = join(dir, "t");
  const ctFiles = walkFiles(traceRoot).filter((f) => f.endsWith(".ct"));
  const emptyCt = ctFiles.filter((f) => (statOf(f)?.size ?? 0) === 0);
  if (!requireTraces) {
    add("A3", "the trace-container class is not vacuous", null,
      `not required (pass --require-traces to enforce) — ` +
      `${containerRefs.length} container reference(s), ${ctFiles.length} .ct file(s) present, ` +
      `${emptyCt.length} of them empty`);
  } else if (containerRefs.length === 0) {
    add("A3", "the trace-container class is not vacuous", false,
      `--require-traces was passed and NO published page references any /t/**/*.ct container ` +
      `(${ctFiles.length} .ct file(s) are present in the tree). A publish claiming to carry real ` +
      `traces must have some page name one; containers nothing points at are dead weight and every ` +
      `debugger session opens empty.`);
  } else if (emptyCt.length > 0) {
    add("A3", "the trace-container class is not vacuous", false,
      `${emptyCt.length} of ${ctFiles.length} .ct file(s) under ${rel(traceRoot)}/ are ZERO BYTES:\n` +
      fmt(emptyCt, (f) => rel(f)));
  } else {
    add("A3", "the trace-container class is not vacuous", true,
      `${containerRefs.length} container reference(s) from ` +
      `${new Set(containerRefs.map((v) => v.page)).size} page(s); ` +
      `all ${ctFiles.length} .ct file(s) under ${rel(traceRoot)}/ are non-empty`);
  }

  // ── A4 — the debug shell names its bundle when it has one ────────────────
  //
  // THIS IS FAILURE 2, EXACTLY. 96 KB of hydrate.js shipped and no `<script
  // src>` named it. Note the requirement is keyed on the file being PRESENT
  // rather than on it being present and non-empty: an empty bundle nothing names
  // is just as dead, and when a page does name it, A2 owns its emptiness.
  //
  // The build legitimately produces no bundle when the Embed SDK is absent
  // (`HydrationBundle` is an empty strdefine, and layout.nim then emits no
  // script tag at all), so an absent file PASSES with a note. The opposite
  // mistake — a page naming a bundle that was never built — is already an A1
  // failure, so the two directions are both covered without either being able
  // to mask the other.
  const bundlePath = join(dir, HYDRATION_BUNDLE_URL.replace(/^\/+/, ""));
  const bundleStat = statOf(bundlePath);
  if (!bundleStat || !bundleStat.isFile()) {
    add("A4", "the hydration bundle is referenced when it is shipped", true,
      `no ${HYDRATION_BUNDLE_URL} in the publish tree — this build ships no hydration bundle, ` +
      `which is legitimate (the Embed SDK was absent). ${bundleRefs.length} page(s) reference it; ` +
      `were that non-zero, A1 would be failing on it.`);
  } else if (bundleRefs.length === 0) {
    add("A4", "the hydration bundle is referenced when it is shipped", false,
      `${HYDRATION_BUNDLE_URL} is published (${bundleStat.size} bytes) and NO page references it. ` +
      `The bundle ships, nothing loads it, and every debugger session is a still frame — ` +
      `this is the exact defect this check was written for. Check that layout.nim emitted the ` +
      `<script src> (i.e. that -d:hydrationBundle was set for the export that produced these bytes).`);
  } else {
    add("A4", "the hydration bundle is referenced when it is shipped", true,
      `${HYDRATION_BUNDLE_URL} (${bundleStat.size} bytes) referenced by ` +
      `${new Set(bundleRefs.map((v) => v.page)).size} page(s)`);
  }

  return {
    checks,
    stats: {
      dir, files: files.length, pages: pages.length, kinds, attrHits,
      distinct: distinct.size, relatives, containerRefs: containerRefs.length,
      ctFiles: ctFiles.length,
    },
  };
}

// ── main ───────────────────────────────────────────────────────────────────

export function parseArgs(argv) {
  let dir = null;
  let requireTraces = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dir") {
      dir = argv[++i];
      if (dir === undefined) throw new Error("--dir needs a path");
    } else if (a.startsWith("--dir=")) {
      dir = a.slice("--dir=".length);
    } else if (a === "--require-traces") {
      requireTraces = true;
    } else {
      throw new Error(`unknown argument: ${a}\nusage: check-assets.mjs [--dir <publishDir>] [--require-traces]`);
    }
  }
  return {
    dir: dir === null ? DEFAULT_DIR : resolvePath(process.cwd(), dir),
    requireTraces,
  };
}

function main(argv) {
  const opts = parseArgs(argv);
  const { checks, stats } = run(opts);
  const failed = checks.filter((c) => c.ok === false);
  const notRun = checks.filter((c) => c.ok === null);
  const ok = failed.length === 0;

  console.log(`publish dir:  ${stats.dir}`);
  console.log(`              (the bytes about to be uploaded — not client/src, not result/)`);
  console.log(`scanned:      ${stats.pages} .html page(s) of ${stats.files} file(s); ` +
              `${stats.kinds["same-origin"]} same-origin reference(s), ` +
              `${stats.distinct} distinct asset(s)`);
  console.log(`not resolved: ${stats.kinds.external} external, ${stats.kinds.fragment} fragment-only, ` +
              `${stats.kinds.empty} empty, ${stats.kinds.relative} document-relative` +
              (stats.relatives.length
                ? ` (e.g. ${stats.relatives[0].page} ${stats.relatives[0].attr}="${stats.relatives[0].url}")`
                : ""));
  console.log(`attributes:   ${[...stats.attrHits].map(([a, n]) => `${a} x${n}`).join(", ")}`);
  console.log("");

  for (const c of checks) {
    const verdict = c.ok === null ? "NOT REQUIRED" : c.ok ? "PASS" : "FAIL";
    console.log(`  ${c.id}  ${verdict}  ${c.title}`);
    console.log(`        ${c.detail}`);
  }
  console.log("");
  if (notRun.length) {
    console.log(`${notRun.length} check(s) NOT REQUIRED and therefore never counted as passes: ` +
                `${notRun.map((c) => c.id).join(", ")}`);
  }
  console.log(ok
    ? `check-assets: PASS — ${checks.filter((c) => c.ok === true).length}/${checks.filter((c) => c.ok !== null).length} checks`
    : `check-assets: FAIL — ${failed.length} check(s) failed: ${failed.map((c) => c.id).join(", ")}`);
  return ok ? 0 : 1;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    process.exit(main(process.argv.slice(2)));
  } catch (e) {
    console.error(`check-assets failed: ${e.stack ?? e.message}`);
    process.exit(2);
  }
}
