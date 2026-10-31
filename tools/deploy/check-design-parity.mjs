#!/usr/bin/env node
// check-design-parity.mjs — does a SERVED origin carry CodeTracer's design, or
// only this repository's intention to carry it?
//
//   node tools/deploy/check-design-parity.mjs --origin https://blocktracer.org
//   node tools/deploy/check-design-parity.mjs --dir site
//   node tools/deploy/check-design-parity.mjs --origin <url> --json
//
// ## Why this is not `check-assets.mjs` and not `check-freshness.mjs`
//
// Those two already divide the ground between them and neither covers this.
// `check-assets.mjs` asks whether every URL a published page names resolves to
// non-empty bytes — an EXISTENCE claim. `check-freshness.mjs` asks whether the
// bytes are the ones this run produced — an IDENTITY claim. A tree can pass
// both while serving a stylesheet that carries none of CodeTracer's panel
// rules: the file exists, it is the file this commit built, and it is the wrong
// design. That is not hypothetical. Measured on live blocktracer.org:
//
//     /_a/ff9f791dc18a0c25.css      316,960 bytes, fetches, correct identity
//     .component-container           0 occurrences   (dev: 2)
//     .table-column-names            0 occurrences
//     url(../../../public/resources/origin-icons/door.svg)  -> 404
//     a transaction page             7,942 bytes, ZERO <script> tags
//
// Every existence and freshness check passes on that tree. The design is a
// year-old one.
//
// ## THE EXPECTED SELECTORS ARE READ FROM THE REGISTER, NOT LISTED HERE
//
// `client/src/components/ct_css_reach.txt` already divides the port's selectors
// into LIVE ("this can match something a page emits") and INERT ("emitted
// knowing nothing will"). That file is maintained as part of the port, with a
// reason per row, so this check reads its LIVE rows and asserts each one. A
// hardcoded list here would be a second register, and the two would disagree
// the first time somebody ported a component.
//
// The INERT rows are the NEGATIVE SPACE and are deliberately not asserted:
// requiring them in the markup would make the check demand the opposite of what
// the register says is true.
//
// ## What each LIVE kind is asserted about, and why they differ
//
//   class      the stylesheet must carry `.<name>` AND a transaction page must
//              emit it. Both halves: a rule nothing emits is defect 1 of the
//              register's own three, and markup with no rule is the inverse.
//   classpart  the stylesheet must carry it. The markup half is NOT asserted —
//              the register's own rows say these are written by concatenation
//              (`"lm_splitter " & axis`), so the literal is in the exported
//              pages and in no `class = "…"` string; a page-side assertion
//              would be measuring the arrangement a given page happens to have.
//   element    the stylesheet only. Asserting a bare tag in HTML would pass on
//              any page with a table in it, which is not a claim about CodeTracer.
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
// ── THE REGISTER HAS ONE READER AND ONE MATCHER, AND THIS FILE USED TO HAVE
//    A SECOND OF EACH ────────────────────────────────────────────────────────
//
// The header above says a hardcoded list here "would be a second register, and
// the two would disagree". It was right about the danger and wrong about where
// it lived: the list was read from the register, and then read WRONGLY, by a
// nine-line regex of this file's own that dropped the evidence column, and
// compared with `includes()` where the register's grammar is a glob.
//
// Measured against blocktracer.pages.dev on 2026-10-27, over a tree whose own
// gate (`ci/test/ct-css-reachable.sh` -> `tools/ci/check-css-reachable.mjs`)
// reports "PASS — every row of the register holds":
//
//   missing from the stylesheet: ct-input-*, category-image, rr-ticks-*,
//                                gdb-evaluate, border-value-*, context-menu-container
//
// Three wildcards and three IDs, and not one of them absent. `.ct-input-*`
// with a literal asterisk matches nothing by construction, and an `id` row was
// searched as `.category-image` because one ternary built `.` for every kind
// but `element`. The emission arm had the third: 110 of the register's rows
// are declared `bundle`, meaning the hydration bundle writes them, and the arm
// looked only in the page HTML — so every one of them read as never emitted.
//
// So the semantics come from the module that defines them.
import {
  parseRegister, matchesPattern, decodeCharCodeLiterals,
} from "../ci/check-css-reachable.mjs";

const HERE = new URL(".", import.meta.url).pathname;
const REPO = resolve(HERE, "..", "..");
const REGISTER = join(REPO, "client", "src", "components", "ct_css_reach.txt");

const args = (() => {
  const a = process.argv.slice(2);
  const get = (n) => { const i = a.indexOf(`--${n}`); return i >= 0 && i + 1 < a.length ? a[i + 1] : undefined; };
  return { origin: get("origin"), dir: get("dir"), json: a.includes("--json"), txPath: get("tx") };
})();
if (!args.origin === !args.dir) {
  console.error("check-design-parity: exactly one of --origin <url> or --dir <path> is required.");
  process.exit(64);
}

// ── the register ───────────────────────────────────────────────────────────
function liveRows() {
  if (!existsSync(REGISTER)) {
    console.error(`check-design-parity: the register is not at ${REGISTER}.`);
    console.error("  It is the source of the expected selectors; without it this check");
    console.error("  would have to carry a list of its own, which is the thing it avoids.");
    process.exit(64);
  }
  // `parseRegister` is the register's own reader: it enforces the grammar,
  // carries the EVIDENCE column this file needs, and raises by line number on
  // a malformed row rather than silently skipping it the way a regex does.
  return parseRegister(readFileSync(REGISTER, "utf8")).map((r) => ({
    state: r.verdict, kind: r.kind, name: r.pattern, evidence: r.evidence,
  }));
}

// ── the universe a selector can be found in, extracted once ────────────────
//
// A PRESENCE TEST OVER AN EXTRACTED UNIVERSE, NOT A SUBSTRING SEARCH. The
// register's patterns are globs, so a pattern has to be matched against NAMES;
// `includes("." + pattern)` cannot do that and silently fails every row with a
// `*` in it. `classpart` is the exception and stays a substring, because it is
// a fragment of a compound selector by definition — that is what the kind
// means.
const CSS_CLASS_RE = /\.(-?[A-Za-z_][\w-]*)/g;
const CSS_ID_RE = /#(-?[A-Za-z_][\w-]*)/g;
const HTML_CLASS_ATTR_RE = /class\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
const JS_STR_RE = /"((?:[^"\\\n]|\\.)*)"|'((?:[^'\\\n]|\\.)*)'/g;

const namesFrom = (text, re) => {
  const out = new Set();
  for (const m of text.matchAll(re)) out.add(m[1]);
  return out;
};

/** Tokens a bundle could write into a `class` attribute: its string literals,
 *  plus the char-code arrays `nim js` emits some literals as. Without the
 *  second half a text grep reports a class that IS there as absent — the
 *  reason `check-css-reachable.mjs` validates its decoder before trusting it. */
function bundleTokens(js) {
  const out = new Set();
  for (const m of js.matchAll(JS_STR_RE))
    for (const t of (m[1] ?? m[2]).split(/[\s\\]+/)) if (t) out.add(t);
  for (const str of decodeCharCodeLiterals(js))
    for (const t of str.split(/\s+/)) if (t) out.add(t);
  return out;
}

/** Does any name in `universe` satisfy this row? `classpart` asks the raw text
 *  instead, which is why both are passed. */
const satisfied = (row, universe, rawText) =>
  row.kind === "classpart"
    ? rawText.includes(row.name)
    : [...universe].some((n) => matchesPattern(row.name, n));

// ── fetching, the same way from either source ──────────────────────────────
// ── FRESH BYTES, BECAUSE THIS RUNS SECONDS AFTER A PUBLISH ────────────────
//
// `publish-r2.yml` runs this check immediately after the upload, so a cached
// response is the difference between "the publish did not take" and "a cache
// has not expired". Those are not the same finding and this check must not
// report the second as the first.
//
// `cache: "no-store"` covers node's own fetch cache; the two headers ask any
// intermediary not to serve a stored response. Note what this canNOT do: it
// cannot defeat an edge that ignores them. So the report prints the stylesheet
// NAME it read — a content-addressed `/_a/<hash>.css` that still matches the
// previous publish is the tell, and it is visible in the output rather than
// hidden behind a verdict.
const FRESH = {
  redirect: "follow",
  cache: "no-store",
  headers: { "Cache-Control": "no-cache", "Pragma": "no-cache" },
};

// AND A CACHE-BUSTING QUERY, BECAUSE THE HEADERS WERE NOT ENOUGH. Measured on
// 2026-10-13, minutes after a successful publish:
//
//   plain        /_a/ff9f791dc18a0c25.css   ← the PREVIOUS publish's stylesheet
//   ?cb=<now>    /_a/0c49ff0f45fccc3a.css   ← this publish's
//   cf-cache-status: HIT   age: 6618   last-modified: Sun, 04 Oct 2026
//
// Cloudflare served a 110-minute-old `index.html` and ignored the request's
// `Cache-Control: no-cache` — which it is entitled to do; those headers are a
// request to an origin, not an instruction to an edge. The check therefore read
// the old stylesheet and reported four failures against a tree that had just
// been replaced. Exactly the misreading the FRESH comment above warned it could
// not prevent on its own.
//
// A query parameter changes the CACHE KEY, so the edge has to go to the origin.
// R2 ignores query strings when it resolves an object, so the same bytes come
// back — the parameter costs nothing but a miss. It is per-process rather than
// per-request so that one run reads one consistent snapshot of the site.
const CB = `cb=${Date.now()}`;
const bust = (u) => {
  const url = new URL(u);
  url.search = url.search ? `${url.search}&${CB}` : `?${CB}`;
  return url;
};

async function getText(path) {
  if (args.dir) {
    // CLEAN URLS, THE SAME WAY THE SITE SERVES THEM: `/x` is `x/index.html`
    // unless `x` is itself a file. `/` is the root index.
    const rel = path.replace(/^\//, "");
    // isFile(), NOT existsSync(): `/aztec` exists and is a DIRECTORY, and
    // reading it throws EISDIR — which surfaced as a crash rather than as a
    // 404 the first time this mode was exercised.
    const direct = rel === "" ? null : join(args.dir, rel);
    const directIsFile = !!direct && existsSync(direct) && statSync(direct).isFile();
    const f = directIsFile ? direct : join(args.dir, rel, "index.html");
    if (!existsSync(f)) return { ok: false, status: 404, body: "", type: "" };
    return { ok: true, status: 200, body: readFileSync(f, "utf8"),
             type: f.endsWith(".css") ? "text/css" : "text/html" };
  }
  const r = await fetch(bust(new URL(path, args.origin)), FRESH);
  const body = await r.text();
  return { ok: r.ok, status: r.status, body, type: r.headers.get("content-type") ?? "" };
}
async function headStatus(path) {
  if (args.dir) {
    const p = join(args.dir, path.replace(/^\//, ""));
    return { status: existsSync(p) && statSync(p).isFile() ? 200 : 404, type: "" };
  }
  // GET, not HEAD: an origin may answer HEAD differently, and the question
  // here is what a browser loading the stylesheet actually receives.
  const r = await fetch(bust(new URL(path, args.origin)), FRESH);
  await r.arrayBuffer();
  return { status: r.status, type: r.headers.get("content-type") ?? "" };
}

const checks = [];
const ck = (what, ok, detail = "") => { checks.push({ what, ok: !!ok, detail }); };

const rows = liveRows();
const live = rows.filter((r) => r.state === "LIVE");
const inert = rows.filter((r) => r.state === "INERT");
ck(`the register declares LIVE rows to assert — ${live.length} of them, against ${inert.length} INERT`,
   live.length >= 10, `${live.length} LIVE / ${inert.length} INERT`);

// ── the entry document and its stylesheet ──────────────────────────────────
const index = await getText("/");
ck("the origin serves an entry document", index.ok, `HTTP ${index.status}, ${index.body.length} bytes`);
const sheets = [...index.body.matchAll(/href="(\/_a\/[^"]+\.css)"/g)].map((m) => m[1]);
ck("the entry document names exactly one stylesheet under /_a/", sheets.length === 1, sheets.join(", ") || "none");
const cssPath = sheets[0];
const css = cssPath ? await getText(cssPath) : { ok: false, status: 0, body: "", type: "" };
ck(`the stylesheet fetches${cssPath ? ` (${cssPath})` : ""}`, css.ok && css.body.length > 10_000,
   `HTTP ${css.status}, ${css.body.length} bytes, ${css.type}`);

// ── every LIVE selector, in the served stylesheet ──────────────────────────
// THE SIGIL FOLLOWS THE KIND. `id` is `#`, and this line used to build `.` for
// it — which is why three ids that are in the sheet were reported absent.
const cssClasses = namesFrom(css.body, CSS_CLASS_RE);
const cssIds = namesFrom(css.body, CSS_ID_RE);
const missingInCss = live.filter((r) => {
  if (r.kind === "classpart") return !css.body.includes(r.name);
  if (r.kind === "element") return !css.body.includes(r.name);
  return !satisfied(r, r.kind === "id" ? cssIds : cssClasses, css.body);
});
ck(`every LIVE selector the register names has a rule in the SERVED stylesheet — ${live.length} checked`,
   missingInCss.length === 0,
   missingInCss.length ? `missing: ${missingInCss.map((r) => `${r.kind} ${r.name}`).join(", ")}` : "all present");

// ── CONTROL: the search discriminates ──────────────────────────────────────
const FABRICATED = "ct-no-such-selector-7f3a";
ck("THE CONTROL: a fabricated selector is NOT in the stylesheet, so the search above is a search",
   !css.body.includes(FABRICATED));

// ── every url() the stylesheet names ───────────────────────────────────────
const urls = [...new Set([...css.body.matchAll(/url\(\s*["']?([^)"']+)["']?\s*\)/g)].map((m) => m[1]))]
  .filter((u) => !u.startsWith("data:"));
const relative = urls.filter((u) => !u.startsWith("/") && !/^https?:/.test(u));
ck(`no url() in the served stylesheet is RELATIVE — ${urls.length} url(s) examined`,
   relative.length === 0,
   relative.length ? `relative: ${relative.join(", ")}` : "all absolute");
// A relative url() in a sheet served from /_a/ resolves against /_a/, which is
// never where an asset is. This was eight of twelve on production.
const broken = [];
for (const u of urls.filter((u) => u.startsWith("/"))) {
  const { status, type } = await headStatus(u);
  if (status !== 200 || /text\/html/.test(type)) broken.push(`${u} -> ${status}${type ? ` ${type}` : ""}`);
}
ck(`every absolute url() resolves to non-HTML bytes — ${urls.filter((u) => u.startsWith("/")).length} fetched`,
   broken.length === 0, broken.length ? broken.join("; ") : "all resolve");

// ── the transaction pages, which is where the design is actually worn ──────
//
// ONE PAGE IS NOT THE TREE, AND ASSERTING OVER ONE WAS WRONG. The register's
// claim for a LIVE row is "this CAN match something a page emits", not "every
// page emits it", and the difference is load-bearing: `ct-tab` is written by
// `debugger.nim`'s source-tab strip, so a chain recording that publishes no
// source has no tabs and no `ct-tab`. The first version of this check sampled
// one Aztec transaction and reported `ct-tab` missing on a tree that emits it
// correctly — a false negative with the register's own words to refute it.
//
// So the sample spans CHAINS, which is the axis the recordings differ on, and
// the assertion is over the union. Each row reports which page carried it, so
// a row satisfied by exactly one page is visible rather than averaged away.
const CHAINS = ["/aztec", "/aztec-testnet", "/aztec-testnet-frames", "/demo"];
const pages = [];
for (const chain of CHAINS) {
  const idx = await getText(chain);
  if (!idx.ok) continue;
  const hits = [...new Set([...idx.body.matchAll(/href="(\/[^"]*\/tx\/0x[0-9a-f]+)"/g)].map((m) => m[1]))];
  for (const path of hits.slice(0, 2)) {
    const page = await getText(path);
    if (page.ok) pages.push({ chain, path, body: page.body });
  }
}
// FEWER THAN TWO CHAINS IS NOT A PASS. With one chain's pages the union cannot
// cover the kinds, and a green verdict would be a verdict about coverage this
// run did not have.
const chainsSampled = [...new Set(pages.map((p) => p.chain))];
ck(`transaction pages were found on at least two chains — ${pages.length} page(s) across `
   + `${chainsSampled.length} chain(s): ${chainsSampled.join(", ") || "none"}`,
   chainsSampled.length >= 2 && pages.length >= 2);
// HYDRATION IS PART OF THE DESIGN, not a separate concern: without the bundle a
// page is the pre-hydration fallback, which is a correct page and not the IDE.
// Production served 7,942 bytes and zero script tags.
//
// ONLY A SESSION PAGE HAS ANYTHING TO HYDRATE. A transaction with no published
// trace is rendered in the explorer shell (`pageLayout`, `data-register=
// "explorer"`), which deliberately carries no script — layout.nim: "The explorer
// shell has no session to hydrate". Requiring one there was a false negative,
// and on production it was the ONLY failure: run 40977644036 (live 21d6aa9)
// sampled three untraced live Aztec transactions ("Not observable … ingested
// without --replay"), 8,827 bytes each, and failed this row on them while every
// /demo session page carried the bundle. So the assertion is over the pages in
// the debugger shell, and a sample with none of those is refused rather than
// passed: no session page means this run did not look at hydration at all.
const isSession = (p) => /<html[^>]*data-register="debugger"/.test(p.body);
const sessions = pages.filter(isSession);
const unscripted = sessions.filter((p) => !/<script/.test(p.body));
ck(`every sampled SESSION page carries a script — without one it is the pre-hydration `
   + `fallback, not the IDE (${sessions.length} session page(s) of ${pages.length}; `
   + `${pages.length - sessions.length} explorer-shell page(s) have no session to hydrate)`,
   sessions.length > 0 && unscripted.length === 0,
   sessions.length === 0 ? "no sampled page is a session page"
   : unscripted.length ? `no script on: ${unscripted.map((p) => p.path).join(", ")}` : "all scripted");
// DOES THE SAMPLE CONTAIN THE KIND THAT WEARS THE SOURCE TABS? Some LIVE rows
// are only reachable on a page that publishes SOURCE — `ct-tab` is written by
// `debugger.nim`'s `srctab` strip — so a sample with no such page cannot judge
// them, and a FAILED row below would be about this run's coverage rather than
// about the origin. This is reported as its own check so the reader can tell
// which it is: measured on dev, `ct-tab` appears on 4 of 8 pages and
// `empty-overlay` on 6 of 8, while every other LIVE class is on all 8.
const sourceBearing = pages.filter((p) => p.body.includes("srctab"));
ck(`the sample contains a page that publishes SOURCE, without which the rows that only appear `
   + `there cannot be judged — ${sourceBearing.length} of ${pages.length} page(s)`,
   sourceBearing.length > 0,
   sourceBearing.length ? sourceBearing.map((p) => p.path).join(", ") : "none — class-emission results below are bounded by that");
// ── THE BUNDLE IS PART OF THE SAMPLE, BECAUSE 110 ROWS SAY SO ─────────────
//
// The register's fourth column is the EVIDENCE TIER, and `bundle` means the
// hydration bundle writes the class — `check-css-reachable.mjs` calls it "a
// declarable evidence tier, never a default". A `bundle` row is NOT in the
// served HTML and was never going to be: these are the calltrace rows, the
// value tree, the event log and the context menu, which the mounted shared
// views write after hydration. Asking the page for them produced, against a
// tree whose own gate passes, a hundred-row failure list that was entirely an
// artefact of looking in the wrong file.
//
// So the bundles each sampled page references are fetched and read the same
// way the local gate reads them — string literals plus the char-code arrays
// `nim js` emits some literals as.
const scriptSrcs = [...new Set(pages.flatMap((p) =>
  [...p.body.matchAll(/<script[^>]+src="([^"]+)"/g)].map((m) => m[1])))]
  .filter((u) => u.startsWith("/"));
const bundles = [];
for (const src of scriptSrcs) {
  const js = await getText(src);
  if (js.ok && js.body.length > 0) bundles.push({ src, tokens: bundleTokens(js.body) });
}
const bundleUniverse = new Set(bundles.flatMap((b) => [...b.tokens]));
// A `bundle` ROW WITH NO BUNDLE READ IS NOT A PASS. If the scripts could not be
// fetched, the rows that depend on them were not measured, and a verdict taken
// over an empty universe would be the silence this whole file exists to break.
const bundleRows = live.filter((r) => r.kind === "class" && r.evidence === "bundle");
ck(`the bundles the sampled pages reference were read, because ${bundleRows.length} LIVE row(s) `
   + `name the bundle as their evidence — ${bundles.length} of ${scriptSrcs.length} fetched`,
   bundleRows.length === 0 || bundles.length > 0,
   bundles.map((b) => `${b.src} (${b.tokens.size} tokens)`).join(", ")
     || `none fetched of: ${scriptSrcs.join(", ") || "no <script src> on any sampled page"}`);

const classRows = live.filter((r) => r.kind === "class");
const pageUniverses = pages.map((p) => ({
  path: p.path,
  body: p.body,
  classes: new Set([...p.body.matchAll(HTML_CLASS_ATTR_RE)]
    .flatMap((m) => (m[1] ?? m[2]).split(/\s+/)).filter(Boolean)),
}));
const carriedBy = new Map();
for (const r of classRows) {
  const where = pageUniverses.filter((p) => satisfied(r, p.classes, p.body)).map((p) => p.path);
  if (where.length === 0 && r.evidence === "bundle" && satisfied(r, bundleUniverse, ""))
    where.push("<bundle>");
  carriedBy.set(r.name, where);
}
const missingInPages = classRows.filter((r) => carriedBy.get(r.name).length === 0);
ck(`every LIVE class is EMITTED somewhere in the sample — ${classRows.length} checked over `
   + `${pages.length} page(s) and ${bundles.length} bundle(s)`,
   missingInPages.length === 0,
   missingInPages.length
     ? `not emitted anywhere: ${missingInPages.map((r) => r.name).join(", ")}`
     : classRows.map((r) => `${r.name}x${carriedBy.get(r.name).length}`).join(" "));
ck("THE CONTROL: the fabricated selector is not emitted by any sampled page",
   pages.every((p) => !p.body.includes(FABRICATED)));

// ── report ─────────────────────────────────────────────────────────────────
const failed = checks.filter((c) => !c.ok);
if (args.json) {
  console.log(JSON.stringify({ subject: args.origin ?? args.dir, checks, failed: failed.length }, null, 2));
} else {
  console.log(`=== design parity: ${args.origin ?? args.dir} ===`);
  console.log("");
  for (const c of checks) {
    console.log(`  ${c.ok ? "[OK]    " : "[FAILED]"} ${c.what}`);
    if (c.detail) console.log(`             ${c.detail}`);
  }
  console.log("");
  console.log(failed.length === 0
    ? `PASS — ${checks.length} check(s); the served design carries every selector the register calls LIVE`
    : `FAIL — ${failed.length} of ${checks.length} check(s). This is a claim about what the ORIGIN SERVES, `
      + `not about this working tree: a green local build and a red run here means the tree was never published.`);
}
process.exitCode = failed.length === 0 ? 0 : 1;
