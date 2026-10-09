#!/usr/bin/env node
//
// check-css-reachable.mjs — the MARKUP half of the reachability gate.
//
// WHY THIS EXISTS
// ---------------
// `client/src/components/ct_components_css.nim` compiles eight vendored
// CodeTracer stylesheets into the CSS this site serves. `Dropped` in that
// module records the rules the port does NOT emit, each with a reason, and
// `client/tests/test_ct_components_css.nim` asserts every reported drop is
// deliberate. THE CONVERSE HAD NO CHECK: nothing asserted that a rule which was
// KEPT can actually match anything. A rule could be vendored, transpiled,
// scoped, served and matched by nothing, and the only evidence either way was
// that somebody had once looked.
//
// Three defects came out of that gap, all measured, two of them reported to the
// owner as fixed when they were not:
//
//   1. `.component-container`, CodeTracer's panel surface, was served while
//      `grep -c component-container` over `components/debugger.nim` and
//      `pages/debug.nim` was 0.
//   2. the nine vendored CodeTracer icons had their `url()`s fixed from 404s to
//      200s, and a rendered probe then proved all nine RULES work with injected
//      markup and that ZERO of the nine selectors is emitted anywhere.
//   3. `.separate-bar` and `.dropdown-list` were each given a colour binding
//      while matching zero elements.
//
// `client/src/components/ct_css_reach.txt` is the register that answers the
// converse, and its own header is the argument for every decision in it. THIS
// FILE AND THE NIM SUITE READ THE SAME BYTES, and the split is deliberate:
//
//   * the Nim suite asserts the register is TOTAL — every class, `[class*=]`
//     substring, id and element the port's selectors name is covered by exactly
//     one row. That is a property of the compiled stylesheet, needs no build,
//     and runs in seconds.
//
//   * this file asserts the register is TRUE — every LIVE row is emitted by the
//     exported site, and no INERT row is. That needs the artefact.
//
// Neither is the gate alone. The first says the register accounts for
// everything; the second says it is not lying. The claim the three defects
// needed is their composition, and this file deliberately does not parse the
// stylesheet at all — the inventory has ONE implementation, in Nim, because two
// would be the divergence the port exists to prevent.
//
// WHAT COUNTS AS EMITTED
// ----------------------
// Two sources, and both are syntactically class values:
//
//   A. a token of a `class="…"` attribute in one of the exported pages;
//   B. a token of a `class = "…"` literal, or a `classList.add/remove/toggle`
//      argument, in a `.nim` file under `client/`.
//
// B is what covers a class the renderer writes on a branch the ~348-page demo
// corpus never takes. A is what covers a class no literal spells, because it
// arrives through a helper — `lm_vertical` is exactly that case and is found
// only in A.
//
// A THIRD SOURCE IS MEASURED AND DELIBERATELY NOT COUNTED. Every shipped JS
// bundle is read, with the char-code arrays Nim-JS emits some string literals
// as decoded, and THE DECODER IS VALIDATED IN THREE TIERS so that a null from
// it is a measurement rather than a failed grep — see `validateDecoder`. The
// run prints which tiers it was able to ask, because a validation that passes
// by being skipped is the same silence one level up.
//
// It is not counted as liveness because a JS string literal is not a class
// value, and the measurement says what counting it would have cost: `active`,
// `checkbox`, `hidden`, `open` and `selector` are all port classes AND all
// present as ordinary words in `hydrate.js`, and not one of them is a class
// this site writes. That is the hole big enough to swallow defect 3, so the
// bundle is corroboration and a declarable evidence tier (`LIVE <kind> <name>
// bundle`), never a default.
//
// WHAT IS OUT OF SCOPE is listed in the register's header, with a reason for
// each: pseudo-classes and pseudo-elements, classes inside `:not()`,
// non-`class` attribute selectors, `[data-register="debugger"]` itself, and a
// declaration the browser discards. The last one has a live instance named
// there, and neither half of this gate catches it.
//
// Exit codes:
//   0  every row holds
//   1  a row does not: a LIVE row nothing emits, or an INERT row something does
//   2  the inputs are not there (no register, no pages)
//   3  nothing was measured — a floor refused the run

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

// ── the register ───────────────────────────────────────────────────────────
//
// The SAME parse the Nim module performs, and the two agree on one thing that
// is easy to get wrong: a reason block applies to EVERY row of the consecutive
// run above it, because upstream's vocabulary comes in families whose reason is
// one sentence for all of them.

const ITEM_KINDS = new Set(["class", "classpart", "id", "element"]);

export function parseRegister(text) {
  const rows = [];
  let runStart = -1;
  let reasonSeen = false;
  let lineNo = 0;
  for (const raw of text.split("\n")) {
    lineNo++;
    if (raw.length === 0 || raw.startsWith("#")) continue;
    if (raw[0] === " " || raw[0] === "\t") {
      const piece = raw.trim();
      if (runStart >= 0 && piece && !piece.startsWith("#")) {
        for (let i = runStart; i < rows.length; i++)
          rows[i].reason = rows[i].reason ? rows[i].reason + " " + piece : piece;
        reasonSeen = true;
      }
      continue;
    }
    const parts = raw.trim().split(/\s+/);
    if (parts.length < 3)
      throw new Error(`ct_css_reach.txt:${lineNo}: a row needs VERDICT KIND PATTERN`);
    const [verdict, kind, pattern, evidence] = parts;
    if (verdict !== "LIVE" && verdict !== "INERT")
      throw new Error(`ct_css_reach.txt:${lineNo}: verdict is LIVE or INERT, not ${verdict}`);
    if (!ITEM_KINDS.has(kind))
      throw new Error(`ct_css_reach.txt:${lineNo}: unknown kind ${kind}`);
    if (runStart < 0 || reasonSeen) { runStart = rows.length; reasonSeen = false; }
    rows.push({ verdict, kind, pattern, evidence: evidence ?? "", reason: "", line: lineNo });
  }
  return rows;
}

/** `*` is the only metacharacter, and the same semantics the Nim half uses:
 *  a glob, never a substring search, so a row cannot quietly cover more than
 *  its reason describes. */
export function matchesPattern(pattern, name) {
  if (!pattern.includes("*")) return pattern === name;
  const re = new RegExp(
    "^" + pattern.split("*").map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*") + "$",
  );
  return re.test(name);
}

// ── the markup ─────────────────────────────────────────────────────────────

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

const CLASS_ATTR_RE = /class\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
const ID_ATTR_RE = /\sid\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
const TAG_RE = /<([a-zA-Z][\w-]*)/g;

/** Source A: what the exported pages actually carry. */
export function readPages(files) {
  const classes = new Set(), ids = new Set(), elements = new Set();
  let pages = 0;
  for (const f of files) {
    if (!f.endsWith(".html")) continue;
    pages++;
    const h = readFileSync(f, "utf8");
    for (const m of h.matchAll(CLASS_ATTR_RE))
      for (const t of (m[1] ?? m[2]).split(/\s+/)) if (t) classes.add(t);
    for (const m of h.matchAll(ID_ATTR_RE)) ids.add(m[1] ?? m[2]);
    for (const m of h.matchAll(TAG_RE)) elements.add(m[1].toLowerCase());
  }
  return { pages, classes, ids, elements };
}

// Source B. Restricted to the two syntactic forms that ARE class values, and
// restricted on purpose: a bare string-literal scan of this repository's `.nim`
// files would "find" `.lm_header .lm_tab .lm_close_tab` in `Dropped`'s own keys
// and `.ct-origin-icon-sigma` in the comment above the icon table — i.e. it
// would match exactly the rules the register is about, out of the prose that
// explains why they are inert.
const NIM_CLASS_RE = /\bclass\s*=\s*"([^"]*)"/g;
const NIM_CLASSLIST_RE = /\bclassList\.(?:add|remove|toggle|contains)\s*\(?\s*"([^"]*)"/g;
const NIM_ID_RE = /\bid\s*=\s*"([^"]*)"/g;

/** Which `.nim` files are markup producers. The stylesheet modules and the
 *  design-system layer are excluded because they are about the CSS, not
 *  emitters of markup, and the tests because a test may spell a selector to
 *  assert it is absent. Excluding too much makes this gate REDDER, never
 *  greener, which is the safe direction for an exclusion list. */
function isMarkupSource(path) {
  if (!path.endsWith(".nim")) return false;
  if (path.includes("/vendor/") || path.includes("/nimcache/")) return false;
  if (/_css\.nim$/.test(path)) return false;
  if (path.includes("/design_system/")) return false;
  if (path.includes("/tests/")) return false;
  return true;
}

export function readNimSources(clientDir) {
  const classes = new Set(), ids = new Set();
  let scanned = 0;
  for (const f of walkFiles(clientDir)) {
    if (!isMarkupSource(f)) continue;
    scanned++;
    const src = readFileSync(f, "utf8");
    for (const m of src.matchAll(NIM_CLASS_RE))
      for (const t of m[1].split(/\s+/)) if (t) classes.add(t);
    for (const m of src.matchAll(NIM_CLASSLIST_RE))
      for (const t of m[1].split(/\s+/)) if (t) classes.add(t);
    for (const m of src.matchAll(NIM_ID_RE)) if (m[1]) ids.add(m[1]);
  }
  return { scanned, classes, ids };
}

// Source C, measured and not counted. `nim js` emits some string literals as
// arrays of character codes, so a text grep of a bundle reports a class that is
// present as absent. The run of 3-or-more printable codes is the shape; a run
// containing anything outside 9..126 is not a string and is skipped.
const CHARCODE_RE = /\[((?:\s*\d{1,3}\s*,){2,}\s*\d{1,3}\s*)\]/g;
const JS_STR_RE = /"((?:[^"\\\n]|\\.)*)"|'((?:[^'\\\n]|\\.)*)'/g;

export function decodeCharCodeLiterals(js) {
  const out = [];
  for (const m of js.matchAll(CHARCODE_RE)) {
    const nums = m[1].split(",").map((s) => Number.parseInt(s.trim(), 10));
    if (nums.some((n) => !Number.isFinite(n) || n < 9 || n > 126)) continue;
    out.push(String.fromCharCode(...nums));
  }
  return out;
}

export function readBundles(files) {
  const bundles = [];
  const raw = new Set(), decoded = new Set();
  for (const f of files) {
    if (!f.endsWith(".js")) continue;
    const js = readFileSync(f, "utf8");
    const r = new Set(), d = new Set();
    for (const m of js.matchAll(JS_STR_RE))
      for (const t of (m[1] ?? m[2]).split(/[\s\\]+/)) if (t) r.add(t);
    for (const s of decodeCharCodeLiterals(js))
      for (const t of s.split(/\s+/)) if (t) d.add(t);
    bundles.push({ path: f, bytes: statSync(f).size, raw: r, decoded: d });
    for (const t of r) raw.add(t);
    for (const t of d) decoded.add(t);
  }
  return { bundles, raw, decoded };
}

/** The decoder's own proof, in three tiers, because a bundle null that nobody
 *  validated is not a measurement — it is the failed grep the whole gate is
 *  written against.
 *
 *  TIER 1 is synthetic and ALWAYS RUNS, whatever is in the tree: a literal this
 *  function builds, present only as character codes, has to come back out. A
 *  decoder that had stopped working — a changed `nim js` emission shape, a
 *  tightened regex — would fail here on a bare checkout, with no build.
 *
 *  TIER 2 runs over whatever bundles the tree has: decoding must ADD
 *  information (some decoded token is not in that bundle's text) and the text
 *  scan must still be alive (some decoded token is also in its text). Those two
 *  together are what make a "not found" from either half meaningful.
 *
 *  TIER 3 is the measured pair, and it runs only where it was measured: in
 *  `hydrate.js`, `copyable` is carried ONLY as character codes and `identifier`
 *  is carried both ways. A tree with no hydration bundle cannot be asked, and
 *  saying so is better than a check that passes because it was skipped — which
 *  is why the summary prints which tiers ran. */
export const DECODER_PROBE = "ct-decoder-probe-token";

export function validateDecoder({ bundles }) {
  const problems = [];
  const ran = [];

  // Tier 1 — synthetic, unconditional.
  const codes = [...DECODER_PROBE].map((c) => c.charCodeAt(0)).join(",");
  const synthetic = decodeCharCodeLiterals(`var x = [${codes}];`);
  if (!synthetic.includes(DECODER_PROBE))
    problems.push("the char-code decoder cannot decode a literal built for it — " +
                  "`nim js`'s emission shape has moved, or the pattern has; " +
                  "every bundle answer below is unmeasured until this holds");
  else ran.push("synthetic");

  if (bundles.length === 0) return { problems, ran, skipped: ["bundles", "hydrate.js"] };

  // Tier 2 — over this tree's bundles.
  const addsInfo = bundles.some((b) => [...b.decoded].some((t) => !b.raw.has(t)));
  const textAlive = bundles.some((b) => [...b.decoded].some((t) => b.raw.has(t)));
  if (!addsInfo)
    problems.push("no bundle carries a token as character codes that it does not also " +
                  "carry as text — the decoding is adding nothing, so it is not covering " +
                  "the case it exists for");
  if (!textAlive)
    problems.push("no bundle carries a token BOTH as text and as character codes — " +
                  "one of the two scans has stopped running");
  if (addsInfo && textAlive) ran.push("bundles");

  // Tier 3 — the measured pair, where it was measured.
  const hydrate = bundles.find((b) => b.path.endsWith("hydrate.js"));
  if (!hydrate) return { problems, ran, skipped: ["hydrate.js"] };
  if (!(hydrate.decoded.has("copyable") && !hydrate.raw.has("copyable")))
    problems.push("hydrate.js no longer carries `copyable` as character codes and only as " +
                  "character codes — the literal this decoder was validated against");
  if (!(hydrate.decoded.has("identifier") && hydrate.raw.has("identifier")))
    problems.push("hydrate.js no longer carries `identifier` both as text and as character " +
                  "codes — the control for the validation above");
  if (problems.length === 0) ran.push("hydrate.js");
  return { problems, ran, skipped: [] };
}

// ── the run ────────────────────────────────────────────────────────────────

export function run({ dir, clientDir, registerPath, minPages, minMarkupClasses }) {
  const out = { failures: [], notes: [], stats: {} };

  const register = parseRegister(readFileSync(registerPath, "utf8"));
  out.stats.rows = register.length;
  out.stats.live = register.filter((r) => r.verdict === "LIVE").length;
  out.stats.inert = register.filter((r) => r.verdict === "INERT").length;

  const files = walkFiles(dir);
  const pages = readPages(files);
  const nim = readNimSources(clientDir);
  const bundles = readBundles(files);

  out.stats.pages = pages.pages;
  out.stats.pageClasses = pages.classes.size;
  out.stats.nimFiles = nim.scanned;
  out.stats.nimClasses = nim.classes.size;
  out.stats.bundles = bundles.bundles.length;
  out.stats.bundleTokensRaw = bundles.raw.size;
  out.stats.bundleTokensDecoded = bundles.decoded.size;

  // VACUITY, BEFORE ANY CLAIM. An extractor that silently matched nothing
  // would make every INERT row trivially true and would turn the gate green on
  // the exact tree it exists to redden. The floors are what refuse that, and
  // they are set where no honest export can reach them: this tree produces 349
  // pages and 342 page classes.
  if (pages.pages < minPages) {
    out.failures.push(
      `VACUOUS: ${pages.pages} exported pages under ${dir}, floor is ${minPages}. ` +
      `Nothing below is a measurement.`);
    return out;
  }
  const markupClasses = new Set([...pages.classes, ...nim.classes]);
  if (markupClasses.size < minMarkupClasses) {
    out.failures.push(
      `VACUOUS: ${markupClasses.size} distinct classes in the markup ` +
      `(${pages.classes.size} from pages, ${nim.classes.size} from sources), ` +
      `floor is ${minMarkupClasses}. Every INERT row would pass by default.`);
    return out;
  }
  out.stats.markupClasses = markupClasses.size;

  const decoder = validateDecoder(bundles);
  for (const p of decoder.problems) out.failures.push(`DECODER: ${p}`);
  out.stats.decoderRan = decoder.ran;
  out.stats.decoderSkipped = decoder.skipped;

  const markupIds = new Set([...pages.ids, ...nim.ids]);
  const bundleTokens = new Set([...bundles.raw, ...bundles.decoded]);

  /** Does the markup emit something this row covers? Returns the matching
   *  names and which source each came from, so a failure names the evidence
   *  rather than only the verdict. */
  const hits = (row) => {
    const found = [];
    const addIf = (name, where) => { found.push(`${name} (${where})`); };
    switch (row.kind) {
      case "class":
        for (const c of pages.classes) if (matchesPattern(row.pattern, c)) addIf(c, "page");
        for (const c of nim.classes)
          if (matchesPattern(row.pattern, c) && !pages.classes.has(c)) addIf(c, "source");
        break;
      case "classpart":
        // A `[class*="S"]` matches a class attribute containing S anywhere, so
        // the question is substring containment over the emitted classes — not
        // a glob over them. The pattern itself may still be a glob.
        for (const c of markupClasses) {
          const sub = row.pattern.replace(/\*/g, "");
          if (c.includes(sub)) { addIf(c, pages.classes.has(c) ? "page" : "source"); break; }
        }
        break;
      case "id":
        for (const i of pages.ids) if (matchesPattern(row.pattern, i)) { addIf(i, "page"); break; }
        for (const i of nim.ids) if (matchesPattern(row.pattern, i)) { addIf(i, "source"); break; }
        break;
      case "element":
        for (const e of pages.elements) if (matchesPattern(row.pattern, e)) addIf(e, "page");
        break;
    }
    return found;
  };

  /** The bundle's answer for a row, which is reported and — unless the row
   *  names `bundle` as its evidence — never decides anything. */
  const bundleHit = (row) => {
    for (const t of bundleTokens) if (matchesPattern(row.pattern, t)) return t;
    return null;
  };

  let liveHeld = 0, inertHeld = 0;
  const excusedByBundle = [];
  for (const row of register) {
    const found = hits(row);
    if (row.verdict === "LIVE") {
      if (row.evidence === "bundle") {
        const b = bundleHit(row);
        if (b === null)
          out.failures.push(
            `ct_css_reach.txt:${row.line}  LIVE ${row.kind} ${row.pattern} — declared live ` +
            `on BUNDLE evidence and no bundle token matches it, encoded or not`);
        else { liveHeld++; out.notes.push(`bundle-evidence row holds: ${row.pattern} -> ${b}`); }
        continue;
      }
      if (found.length === 0) {
        const b = bundleHit(row);
        out.failures.push(
          `ct_css_reach.txt:${row.line}  LIVE ${row.kind} ${row.pattern} — NOTHING EMITS IT. ` +
          `Not in any of the ${pages.pages} exported pages and not in any \`class = "…"\` ` +
          `literal under client/.` +
          (b ? ` (A bundle string literal \`${b}\` matches, which is NOT class evidence — ` +
               `see the register's header.)` : ""));
      } else liveHeld++;
      continue;
    }
    // INERT. The stale-excuse direction, and the one that would have caught a
    // "fixed" report: a row that says nothing matches, when something now
    // does, is a reason that has stopped being true.
    if (found.length > 0) {
      out.failures.push(
        `ct_css_reach.txt:${row.line}  INERT ${row.kind} ${row.pattern} — IT IS LIVE NOW: ` +
        `${found.slice(0, 4).join(", ")}${found.length > 4 ? `, +${found.length - 4} more` : ""}. ` +
        `Move the row to LIVE; its reason has stopped being true.`);
    } else {
      inertHeld++;
      const b = bundleHit(row);
      if (b !== null) excusedByBundle.push(`${row.pattern} <- ${b}`);
    }
  }
  out.stats.liveHeld = liveHeld;
  out.stats.inertHeld = inertHeld;
  out.stats.wouldBeExcusedByBundle = excusedByBundle;
  return out;
}

// ── main ───────────────────────────────────────────────────────────────────

function main(argv) {
  const args = argv.slice(2);
  let dir = null, clientDir = null, registerPath = null;
  let minPages = 100, minMarkupClasses = 150;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--client") clientDir = args[++i];
    else if (a === "--register") registerPath = args[++i];
    else if (a === "--min-pages") minPages = Number.parseInt(args[++i], 10);
    else if (a === "--min-markup-classes") minMarkupClasses = Number.parseInt(args[++i], 10);
    else if (!a.startsWith("--")) dir = a;
    else { console.error(`check-css-reachable.mjs: unknown option ${a}`); return 2; }
  }
  if (!dir) {
    console.error("usage: check-css-reachable.mjs <exported-dir> [--client <dir>] " +
                  "[--register <file>] [--min-pages N] [--min-markup-classes N]");
    return 2;
  }
  dir = resolve(dir);
  clientDir = resolve(clientDir ?? join(dir, "..", "src", ".."));
  registerPath = resolve(registerPath ??
    join(clientDir, "src", "components", "ct_css_reach.txt"));

  for (const [what, p] of [["the exported tree", dir], ["the client tree", clientDir],
                           ["the register", registerPath]]) {
    try { statSync(p); } catch {
      console.error(`check-css-reachable.mjs: ${what} is not there: ${p}`);
      return 2;
    }
  }

  let res;
  try { res = run({ dir, clientDir, registerPath, minPages, minMarkupClasses }); }
  catch (e) { console.error(`check-css-reachable.mjs: ${e.message}`); return 2; }

  const s = res.stats;
  console.log("== the reachability register, against the exported site ==");
  console.log(`   register           ${s.rows} rows (${s.live} LIVE, ${s.inert} INERT)`);
  if (s.pages !== undefined)
    console.log(`   exported pages     ${s.pages}, carrying ${s.pageClasses} distinct classes`);
  if (s.nimFiles !== undefined)
    console.log(`   nim markup sources ${s.nimFiles} files, ${s.nimClasses} distinct class literals`);
  if (s.markupClasses !== undefined)
    console.log(`   markup universe    ${s.markupClasses} distinct classes (pages + sources)`);
  if (s.bundles !== undefined)
    console.log(`   js bundles         ${s.bundles}: ${s.bundleTokensRaw} raw tokens, ` +
                `${s.bundleTokensDecoded} char-code-decoded tokens (measured, NOT counted)`);
  if (s.decoderRan !== undefined)
    console.log(`   decoder validated  ${s.decoderRan.join(", ") || "NOTHING"}` +
                (s.decoderSkipped?.length ? `   (not asked: ${s.decoderSkipped.join(", ")})` : ""));
  if (s.liveHeld !== undefined)
    console.log(`   verdicts held      ${s.liveHeld} LIVE, ${s.inertHeld} INERT`);
  if (s.wouldBeExcusedByBundle?.length)
    console.log(`   rows a bundle token would have excused, had it counted: ` +
                `${s.wouldBeExcusedByBundle.length}\n     ` +
                s.wouldBeExcusedByBundle.join("\n     "));

  if (res.failures.length === 0) {
    if (s.liveHeld === 0 || s.inertHeld === 0) {
      console.error("\ncheck-css-reachable.mjs: NOTHING WAS MEASURED — " +
        `${s.liveHeld} live rows and ${s.inertHeld} inert rows held, and a run that ` +
        "proves one side only is not this gate.");
      return 3;
    }
    console.log("\ncheck-css-reachable.mjs: PASS — every row of the register holds.");
    return 0;
  }
  console.error(`\ncheck-css-reachable.mjs: ${res.failures.length} FAILURE(S)`);
  for (const f of res.failures) console.error("  " + f);
  return 1;
}

if (import.meta.url === `file://${process.argv[1]}`) process.exit(main(process.argv));
