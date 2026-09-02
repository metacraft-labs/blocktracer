#!/usr/bin/env node
// VD.2 — `verify_no_raw_values_in_views`, plus the Design-System.md §4.1 CI rule.
//
//   node tools/design/check-tokens.mjs                  run every check
//   node tools/design/check-tokens.mjs --require-built  ALSO cross-check the
//                                                       shipped CSS in client/dist
//   node tools/design/check-tokens.mjs --write-bindings regenerate the binding
//                                                       table in the divergence doc
//   node tools/design/check-tokens.mjs --json           machine-readable verdict
//   node tools/design/check-tokens.mjs --explain        what each check decides
//
// ── The claim ──────────────────────────────────────────────────────────────
//
// "No Layer 2 view references a raw colour, raw pixel value or brand
// primitive; only semantic tokens and utility classes."
//
// Layer 2 here is `client/src/components/*.nim` and `client/src/pages/*.nim`
// (Design-System.md §6's Layer-2 explorer views). Layer 0/1 —
// `client/src/design_system/` — is exactly where raw values are ALLOWED to
// exist, because that is the layer whose job is to decide them.
//
// ── Why it cannot be fooled by a comment ───────────────────────────────────
//
// The Nim sources are TOKENISED, not grepped. A `#` comment and a `##` doc
// comment are skipped; the CSS lives in `"""…"""` blocks and the inline
// `style = "…"` attributes live in ordinary string literals, and only those
// are scanned. That matters in both directions: this file's own commentary
// quotes `#efefef` and `49px` while describing the defects VD.2 fixed, and a
// naive grep would either flag the prose or — far worse — a `#` -to-end-of-line
// comment strip would silently swallow `background:#fff` in a CSS line and
// report a clean pass.
//
// ── What VD.3 closed, and why each hole mattered ───────────────────────────
//
// A review round planted eight violations against VD.2's checker. Five were
// caught; three were not, and the first of them was self-defeating:
//
//   1. **CSS system colours were not detected at all.** The lint exists to stop
//      the 1.04:1 primary button recurring. That button was 1.04:1 because it
//      inherited the user agent's `ButtonFace` — and `background:ButtonFace`
//      passed clean, because the detector enumerated twenty DESIGNER colour
//      names and no system colour. The self-test now plants that exact literal
//      BY NAME, and that case must exist for as long as this file does.
//   2. **Hand-built HTML fragments were skipped.** A single-line string was
//      scanned only when it matched `^[a-z-]+\s*:`, so `"<span
//      style=\"color:#ff0000\">"` was never examined.
//   3. **Bare values in attributes were never scanned** — `meta(name =
//      "theme-color", content = "#4f46e5")`.
//
// Every string literal is now classified into one of three scan contexts, and
// the classification is TOTAL: "not scanned" is a decision with a name.
//
// ── Then the fix was attacked, and six more holes were closed ──────────────
//
// The VD.2 lint was written carefully and still had three holes, so this one is
// assumed to have holes too. Every case below PASSED before the line that
// closes it was written, and each is now a plant in the self-test:
//
//   * `background:buttonface` — CSS system colours are ASCII case-insensitive.
//   * `background:\42 uttonFace` — a CSS identifier escape. A browser reads it
//     as `ButtonFace`, so a detector matching literal text is one backslash
//     from being defeated. CSS escapes are decoded before matching.
//   * `"…background:Butt" & "onFace…"` — the value split across a Nim
//     concatenation, including across two `"""` blocks. Runs of `&`-joined
//     literals are scanned as one string as well as separately.
//   * a colour in a presentational attribute of a hand-built fragment.
//   * `@import url(…)`, which pulls in a stylesheet this checker never reads.
//   * a view module in a directory the scan does not enumerate. A1–A7 name two
//     directories, so a `client/src/views/` would be invisible and every rule
//     would report a clean pass over a subset — A0 now fails on it.
//
// ── Then THAT was attacked, and seven more holes were closed ───────────────
//
// A second review round planted evasions against the fix above. Each PASSED
// before the line that closes it, and each is now a plant in the self-test:
//
//   * `background:hwb(200 30% 20%)` and `background:color(srgb …)` — two CSS
//     Color 4 colour FUNCTIONS the detector did not list at all.
//   * `margin-top:100dvh`, `2lh`, `40q`, `20cqw` — every container-query and
//     dynamic-viewport unit. The unit set is now the whole of CSS Values 4.
//   * `@IMPORT url(…)` — CSS at-rule names are ASCII case-insensitive, exactly
//     as the system colours are; the A7 regex was not.
//   * `"\x42uttonFace"` and `"\66uttonFace"` — NIM's own numeric escapes. The
//     CSS identifier escape was closed and the Nim one, one layer down and
//     needing no CSS knowledge, was left open.
//   * `background:menu`, `background:canvas` and five more — seven names were
//     held in the case-SENSITIVE list for a collision that measurement shows
//     they do not have. See SYSTEM_COLOURS_AMBIGUOUS.
//   * a rogue view module spelled `import isonim/[dsl/ui]`, or `from
//     isonim/dsl/ui import nil`, or holding its stylesheet in a single-line
//     string rather than a `"""` block — three ways past A0's scope check.
//   * `"Note: the raw value is in wei"` classified as a CSS DECLARATION LIST,
//     which made A5 report an English sentence as an inline style and made A1
//     match the word "green" in `"Status: green means finalised"`. A false
//     positive is how a lint gets switched off, so it counts as a hole.
//
// ── What is still open, stated rather than hidden ──────────────────────────
//
// Three things, and the first is narrower than VD.3 first claimed:
//
//   1. A value assembled at RUN TIME from non-literal parts has no string
//      literal to match and is out of reach of every rule here. Closing that
//      needs a Nim semantic pass over the render graph, not a larger regex.
//   2. A value routed through a `const` in a module this scan does not read —
//      `client/src/viewutil.nim`, say — is equally invisible, and this one is
//      NOT out of reach: A0 already opens every `.nim` under client/src to ask
//      whether it is a view in the wrong place. Scanning those files' literals
//      as well is a change to the file set A1–A7 iterate, not a semantic pass.
//      It is left open deliberately rather than by omission, because those
//      modules are not Layer 2 and a raw colour in one is a different finding.
//   3. A single-word capitalised label — `text "Menu"`, `text "Orange"` — is
//      indistinguishable at this level from `content = "Menu"`, and FAILS A1.
//      The whole-string rule makes long prose safe and short labels unsafe.
//      Distinguishing them needs the ATTRIBUTE NAME from the code scan, the way
//      A5 reads `style =`; that is a change to what a VALUE string knows about
//      itself, and is a design decision for a review round rather than a regex.
//
// None of the three is an accident this lint exists to catch; 1 and 2 are
// deliberate, obfuscating acts, and 3 fails safe.
//
// ── The allowlist cannot rot ───────────────────────────────────────────────
//
// A few kinds of literal are legitimately unavoidable in CSS (a breakpoint
// cannot read a custom property; `transparent` is the absence of a colour).
// `ALLOWLIST` below is the set — read its length there; this line said "Four"
// over three entries. Each is allowlisted BY PATTERN WITH A REASON, and check A6 fails when an
// allowlist entry stops matching anything — so an exemption written for one
// line cannot quietly become a blanket permission after that line is deleted.

import { readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import {
  classifyCitation,
  indexFindings,
  ledgerHistoryAvailable,
  makeLedgerAtRevision,
} from "./lib/citation-meaning.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");

export const WEB_TOKENS = join(REPO_ROOT, "client", "src", "design_system", "web.tokens.json");
export const DIVERGENCE_DOC = join(REPO_ROOT, "docs", "DESIGN-DIVERGENCES-WEB.md");
const LAYER2_DIRS = [
  join(REPO_ROOT, "client", "src", "components"),
  join(REPO_ROOT, "client", "src", "pages"),
];
const BUILT_HTML = join(REPO_ROOT, "client", "dist", "index.html");

// ── Why D1 asks how OLD the build is before it reads it ────────────────────
//
// D1 and D2 are the only checks that read a BUILD ARTEFACT rather than the
// source. An artefact can be out of date, and a stale one does not report
// "unknown" — it reports the state of an older tree with total confidence, in
// exactly the words a real product defect would use.
//
// That is not hypothetical. `--require-built` once reported
//
//     defined but not shipped: --bt-mark-changed, --bt-syntax-keyword, …
//
// naming all fifteen tokens of the lexical palette, against a `client/dist`
// written NINE MINUTES BEFORE the commit that added them. Every one of those
// tokens was in fact declared six times over on all 61 built pages. The
// message was true about the bytes it read and false about the product, and it
// produced a confidently wrong diagnosis — "the checker must be scanning a
// different stylesheet from the one these ship in" — which sent the reader
// looking for a second stylesheet that does not exist. `siteCss()` builds ONE
// `<style>` payload and both shells inline it, so there was never a second
// path for the tokens to arrive by. The artefact's mtime was the whole answer.
//
// A gate that reports false failures is worse than no gate: it teaches people
// to route around it, and every other number this file prints then inherits
// that distrust. So the freshness of the artefact is now a PRECONDITION of the
// comparison rather than an assumption inside it.
//
// The inputs are every `.nim` under `client/src` plus the token JSON — the
// exporter's whole source. `result/` is deliberately NOT consulted: it is a
// different output tree (`nix build .#default`), and rebuilding it does
// nothing for these two checks. That confusion is half of how the incident
// above happened, so the failure message names the directory it actually read.
//
// WHAT THIS DOES NOT CATCH, stated rather than hidden. The signal is the
// mtime, so it detects a build that is OLDER than its source — which is what
// an un-rerun `just export` leaves behind, and the whole of the incident
// above. It does NOT detect a page whose CONTENT is old but whose timestamp is
// new: copy a stale index.html into place without preserving times, or `touch`
// one, and the artefact lies about its age and the token comparison runs
// against it. Closing that needs the exporter to record a digest of its inputs
// IN the page it writes, so the claim travels with the artefact instead of
// being inferred from the filesystem. That is a change to `static_export.nim`
// rather than to this file, and is left open deliberately: the failure mode it
// would close is a copied artefact, whereas the one that actually bit — and
// that CI and every working tree reproduce — is a build nobody re-ran.
const BUILD_INPUT_ROOT = join(REPO_ROOT, "client", "src");

function staleBuild(builtPath) {
  /** `{ newer, builtAt, inputAt }` when a source is newer than the artefact,
   *  else null. Equal mtimes are FRESH: a build written in the same second as
   *  its last input is the ordinary `just export` case, and treating that as
   *  stale would make the gate cry wolf on every clean run — the exact failure
   *  mode this function exists to prevent. */
  let built;
  try { built = statSync(builtPath); } catch { return null; }
  const newest = newestBuildInput();
  if (newest === null || newest.mtimeMs <= built.mtimeMs) return null;
  const when = (ms) => new Date(ms).toISOString().replace("T", " ").slice(0, 19) + "Z";
  return { newer: newest.path, builtAt: when(built.mtimeMs), inputAt: when(newest.mtimeMs) };
}

function newestBuildInput() {
  /** The most recently modified source the built page is a function of.
   *  Returns `{ path, mtimeMs }`, or null when the tree cannot be read. */
  let newest = null;
  const walk = (dir) => {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of entries) {
      const p = join(dir, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      if (!e.isFile()) continue;
      if (!(e.name.endsWith(".nim") || e.name.endsWith(".json"))) continue;
      let st;
      try { st = statSync(p); } catch { continue; }
      if (newest === null || st.mtimeMs > newest.mtimeMs) newest = { path: p, mtimeMs: st.mtimeMs };
    }
  };
  walk(BUILD_INPUT_ROOT);
  return newest;
}

const BINDINGS_BEGIN = "<!-- BEGIN GENERATED: implemented bindings -->";
const BINDINGS_END = "<!-- END GENERATED: implemented bindings -->";

// ── The allowlist ──────────────────────────────────────────────────────────
// pattern → why it is not a design decision. Every entry MUST match at least
// once (check A6), so a stale exemption is a failure rather than a loophole.

export const ALLOWLIST = [
  {
    id: "media-breakpoint",
    re: /@media\s*\([a-z-]+:\s*\d+px\)/g,
    why: "CSS cannot read a custom property inside a media condition, so a breakpoint is necessarily a literal. It is a layout threshold, not a design value: nothing is coloured, sized or spaced by it.",
  },
  {
    id: "transparent-keyword",
    re: /\btransparent\b/g,
    why: "`transparent` is the ABSENCE of a colour, not a colour. `.btn` uses it for the base border so that every variant class must set a real border-colour token — which is what stops a variant inheriting a user-agent default, the defect that made the primary action 1.04:1.",
  },
  {
    id: "absolute-url",
    re: /\bhttps?:\/\/[^\s"'`)]+/g,
    why: "An absolute URL is a DESTINATION, not a design value: nothing is coloured, sized or spaced by it, and there is no token that could hold it. It is exempted because the classifier cannot otherwise tell one from a CSS declaration — `looksLikeCssDecl` reads `https://codetracer.com` as the property `https` with the value `//codetracer.com`, one 'word', which is the same shape as `color:red`. That misreading made the footer's three provenance links fail A5 as inline styles, so the exemption is what lets this repository say who built it and where its source is. Nothing is lost: the URL is blanked BEFORE the colour and length scans, and no absolute URL is a colour or a length. Whether a URL is a FETCH or a hyperlink is a different rule with a different owner — tests/test_explorer_breadth.externalReferences.",
  },
];

// Rows that record WHERE the web lineage lives rather than what it renders.
// They have no literal binding by nature. Enumerated, never pattern-matched:
// a second structural row has to be added here on purpose, and a structural row
// that acquires a literal fails B2 as misfiled.
export const STRUCTURAL_ROWS = new Set(["D-00"]);

// ── Detectors ──────────────────────────────────────────────────────────────

// ── CSS system colours ─────────────────────────────────────────────────────
//
// THIS IS THE LITERAL THE WHOLE LINT EXISTS TO CATCH. VD.1 measured the primary
// button at 1.04:1 because `.btn` set no `background`, so `<button class="btn
// ghost">` inherited the user agent's `ButtonFace` while its `<a class="btn
// primary">` siblings did not. A detector that enumerates twenty DESIGNER
// colour names and no SYSTEM colour cannot see the value that caused the
// regression it was written to prevent — `background:ButtonFace` passed clean.
//
// Two lists, because CSS system colours are ASCII case-insensitive while ONE of
// them is also a CSS property name that occurs in a value position.
//
// The case-sensitive list is a DELIBERATE WEAKENING — a lowercase spelling of a
// name on it is a colour a browser honours and this checker cannot see — so it
// is held to the names that have EVIDENCE behind them, and no others. VD.3
// originally put eight names here on the reasoning that they are ordinary
// English words. Measured against the real Layer 2 source, seven of the eight
// (`Canvas`, `Field`, `Highlight`, `Mark`, `Menu`, `Scrollbar`, `Window`) match
// NOTHING even case-insensitively: `scrollbar-color` and `--bt-surface-canvas`
// are excluded by the word boundaries already, and no `<mark>` or `.menu` rule
// exists. They bought no false-positive protection and cost seven undetectable
// colours (`background:menu` passed clean), so they are matched
// case-insensitively with the rest.
//
// `Background` is the one name with a real collision, and it is a large one: 42
// case-insensitive matches, of which 37 are the property `background:` and 3 are
// `transition:background …` — a property name in a VALUE position, which no
// lookahead can distinguish from the system colour. It stays case-sensitive on
// its canonical CSS spelling, which is the spelling a stylesheet that means the
// system colour uses and the spelling ordinary CSS never produces.
//
// The residual hole is therefore exactly one name wide and is stated rather than
// hidden: `background:background` is a colour this checker does not see.
export const SYSTEM_COLOURS_COMPOUND = [
  "AccentColorText", "AccentColor", "ActiveBorder", "ActiveCaption", "ActiveText",
  "AppWorkspace", "ButtonBorder", "ButtonFace", "ButtonHighlight", "ButtonShadow",
  "ButtonText", "CanvasText", "Canvas", "CaptionText", "FieldText", "Field",
  "GrayText", "HighlightText", "Highlight", "InactiveBorder",
  "InactiveCaptionText", "InactiveCaption", "InfoBackground", "InfoText",
  "LinkText", "MarkText", "Mark", "MenuText", "Menu", "Scrollbar",
  "SelectedItemText", "SelectedItem", "ThreeDDarkShadow", "ThreeDFace",
  "ThreeDHighlight", "ThreeDLightShadow", "ThreeDShadow", "VisitedText",
  "WindowFrame", "WindowText", "Window",
];
export const SYSTEM_COLOURS_AMBIGUOUS = [
  "Background",
];

const SYSTEM_COLOUR_RE_I = new RegExp(`(?<![\\w-])(?:${SYSTEM_COLOURS_COMPOUND.join("|")})(?![\\w-])`, "gi");
const SYSTEM_COLOUR_RE_S = new RegExp(`(?<![\\w-])(?:${SYSTEM_COLOURS_AMBIGUOUS.join("|")})(?![\\w-])`, "g");

// The CSS named colours a designer actually reaches for. `transparent` is
// handled by the allowlist; `inherit`/`currentColor` are inheritance, not
// colour choices.
const NAMED_COLOUR_RE = /(?<![\w-])(white|black|red|green|blue|grey|gray|silver|navy|teal|olive|maroon|purple|fuchsia|aqua|lime|orange|yellow|pink|brown|cyan|magenta)(?![\w-])/gi;

// The colour FUNCTIONS. This list has to be the whole of CSS Color 4, not the
// familiar half of it: `hwb()` and `color()` are as much a raw colour as
// `rgb()` is, are supported everywhere `oklch()` is, and were both absent —
// `background:hwb(200 30% 20%)` passed clean. `light-dark()` is deliberately
// NOT here: its arguments are colours and are caught on their own, so listing
// it would reject the legitimate `light-dark(var(--a), var(--b))`.
const RAW_COLOUR = [
  { id: "hex", re: /#[0-9a-fA-F]{3,8}\b/g },
  { id: "rgb", re: /\brgba?\s*\(/g },
  { id: "hsl", re: /\bhsla?\s*\(/g },
  { id: "hwb", re: /\bhwba?\s*\(/g },
  { id: "color-function", re: /(?<![\w-])color\s*\(/g },
  { id: "color-mix", re: /\bcolor-mix\s*\(/g },
  { id: "lab-lch-oklch", re: /\bo?k?(lab|lch)\s*\(/g },
  { id: "named-colour", re: NAMED_COLOUR_RE },
  { id: "system-colour", re: SYSTEM_COLOUR_RE_I },
  { id: "system-colour", re: SYSTEM_COLOUR_RE_S },
];

// The subset that cannot occur in English prose, and is therefore safe to look
// for anywhere in a string — including one that is a sentence. A `#4f46e5` or
// an `rgb(` in ANY Layer 2 string is a colour; the word "orange" is not.
const UNAMBIGUOUS_COLOUR = RAW_COLOUR.filter((d) => !["named-colour", "system-colour"].includes(d.id));
const PROSE_RISKY_COLOUR = RAW_COLOUR.filter((d) => ["named-colour", "system-colour"].includes(d.id));

// A length literal: a number followed by a CSS unit. `0` alone is not a design
// value, and unitless numbers (z-index, flex, line-height ratios) are not
// lengths, so neither is matched.
//
// The unit set is the whole of CSS Values 4, not the units that were common when
// the rule was written. `height:100dvh` is an extremely ordinary modern
// declaration and it passed clean, as did `2lh`, `40q`, `20cqw` and every other
// container-query and dynamic-viewport unit: a detector that enumerates units is
// defeated by the next unit CSS ships, so it enumerates all of them. Ordered
// longest-first so the alternation cannot match a proper prefix.
const LENGTH_UNITS = [
  "rem", "rlh", "rex", "rch", "ric", "rcap",
  "svmin", "lvmin", "dvmin", "svmax", "lvmax", "dvmax",
  "vmin", "vmax", "cqmin", "cqmax",
  "svh", "lvh", "dvh", "svw", "lvw", "dvw", "svi", "lvi", "dvi", "svb", "lvb", "dvb",
  "cqw", "cqh", "cqi", "cqb", "cap",
  "px", "em", "ch", "ex", "ic", "lh", "vh", "vw", "vi", "vb",
  "pt", "pc", "cm", "mm", "in", "q",
];
const RAW_LENGTH = new RegExp(
  `(?<![\\w.#-])-?\\d*\\.?\\d+(${LENGTH_UNITS.join("|")})(?![\\w-])`, "g");

const BRAND_PRIMITIVE = [
  { id: "ct-variable", re: /var\(\s*--ct-[a-z0-9-]+\s*\)/g },
  { id: "ct-declaration", re: /--ct-[a-z0-9-]+\s*:/g },
  { id: "dtcg-path", re: /\{colors?\.[a-z0-9.-]+\}/gi },
];

// ── Nim tokenisation: strings in, comments out ─────────────────────────────

/** Nim's escapes, resolved — what the string MEANS, which is what a browser
 *  gets. `\"` is how a hand-built HTML attribute is written.
 *
 *  The NUMERIC escapes matter for the same reason the CSS identifier escape
 *  below does, and they are the easier of the two to reach for: Nim reads
 *  `"\x42uttonFace"` and `"\66uttonFace"` as `ButtonFace`, so a detector that
 *  only strips the backslash sees `x42uttonFace` and passes it. VD.3 closed the
 *  CSS escape (`background:\42 uttonFace`) and left the Nim one open one layer
 *  down, where no CSS knowledge is needed to use it. Both are closed now. */
export function unescapeNim(text) {
  return text.replace(
    /\\(?:x([0-9a-fA-F]{2})|u\{([0-9a-fA-F]{1,6})\}|u([0-9a-fA-F]{4})|(\d{1,3})|(.))/g,
    (m, hex, uBrace, u4, dec, ch) => {
      if (hex !== undefined) return String.fromCharCode(parseInt(hex, 16));
      if (uBrace !== undefined) {
        const cp = parseInt(uBrace, 16);
        return cp <= 0x10ffff ? String.fromCodePoint(cp) : m;
      }
      if (u4 !== undefined) return String.fromCharCode(parseInt(u4, 16));
      // Nim's decimal escape is 1-3 digits and tops out at 255.
      if (dec !== undefined) return Number(dec) <= 255 ? String.fromCharCode(Number(dec)) : m;
      return ch === "n" ? "\n" : ch === "t" ? "\t" : ch === "r" ? "\r" : ch === "\\" ? "\\" : ch;
    });
}

/** The Nim source with every string literal and comment blanked, so a regex
 *  over it sees CODE only. Used by A5: a `style = someVar` attribute has no
 *  string literal for the string scan to find, and is still an inline style. */
export function nimCode(src) {
  const chars = src.split("");
  const blank = (from, to) => {
    for (let k = from; k < to && k < chars.length; k++) if (chars[k] !== "\n") chars[k] = " ";
  };
  // The same walk as nimStrings, blanking instead of collecting.
  let i = 0;
  const n = src.length;
  while (i < n) {
    if (src.startsWith('"""', i)) {
      const end = src.indexOf('"""', i + 3);
      const stop = end === -1 ? n : end;
      blank(i, stop + 3);
      i = stop + 3;
      continue;
    }
    if (src[i] === '"') {
      let j = i + 1;
      while (j < n && src[j] !== '"') { if (src[j] === "\\") j++; j++; }
      blank(i, j + 1);
      i = j + 1;
      continue;
    }
    if (src[i] === "'") {
      let j = i + 1;
      if (src[j] === "\\") j++;
      j++;
      if (src[j] === "'") { blank(i, j + 1); i = j + 1; continue; }
      i++;
      continue;
    }
    if (src[i] === "#") {
      const nl = src.indexOf("\n", i);
      const stop = nl === -1 ? n : nl;
      blank(i, stop);
      i = stop;
      continue;
    }
    i++;
  }
  return chars.join("");
}

/** Every string literal in a Nim source, with its kind and 1-based line. */
export function nimStrings(src) {
  const out = [];
  const lineOf = (i) => src.slice(0, i).split("\n").length;
  let i = 0;
  const n = src.length;
  while (i < n) {
    // Triple-quoted block: the CSS lives here. No escapes inside.
    if (src.startsWith('"""', i)) {
      const end = src.indexOf('"""', i + 3);
      const stop = end === -1 ? n : end;
      const blockText = src.slice(i + 3, stop);
      out.push({ kind: "block", text: blockText, unescaped: blockText, line: lineOf(i), start: i, end: stop + 3 });
      i = stop + 3;
      continue;
    }
    if (src[i] === '"') {
      let j = i + 1;
      while (j < n && src[j] !== '"') {
        if (src[j] === "\\") j++;
        j++;
      }
      const text = src.slice(i + 1, j);
      // `unescaped` is what the string MEANS, which is what a browser sees. A
      // hand-built fragment is written `"<span style=\"color:#f00\">"`, so the
      // attribute a scanner has to reach into is behind a backslash.
      out.push({ kind: "string", text, unescaped: unescapeNim(text), line: lineOf(i), start: i, end: j + 1 });
      i = j + 1;
      continue;
    }
    // A char literal — 'x' or '\n' — never a comment introducer.
    if (src[i] === "'") {
      let j = i + 1;
      if (src[j] === "\\") j++;
      j++;
      if (src[j] === "'") { i = j + 1; continue; }
      i++;
      continue;
    }
    // A comment, only OUTSIDE a string. Both `#` and `##`.
    if (src[i] === "#") {
      const nl = src.indexOf("\n", i);
      i = nl === -1 ? n : nl;
      continue;
    }
    i++;
  }
  return out;
}

/** CSS block comments carry no style; they are removed before scanning. */
const stripCssComments = (css) => css.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "));

/** CSS identifier escapes, resolved. A browser reads `background:\42 uttonFace`
 *  as `background:ButtonFace`, so a detector that matches literal text is one
 *  backslash away from being defeated — this was found by trying to evade the
 *  system-colour fix rather than by reading the spec. The optional trailing
 *  whitespace deliberately excludes `\n`, so decoding never changes how many
 *  newlines precede a match and reported line numbers stay true. */
export const decodeCssEscapes = (css) =>
  css
    .replace(/\\([0-9a-fA-F]{1,6})[ \t\r\f]?/g, (m, h) => {
      const cp = parseInt(h, 16);
      return cp > 0 && cp <= 0x10ffff ? String.fromCodePoint(cp) : m;
    })
    .replace(/\\([^\r\n])/g, "$1");

// ── What KIND of string is this, and therefore what may be looked for in it ──
//
// VD.2 scanned a single-line string only when it matched `^[a-z-]+\s*:`, so a
// hand-built fragment (`"<span style=\"color:#ff0000\">"`) and a bare value in
// an attribute (`meta(name = "theme-color", content = "#4f46e5")`) were never
// examined at all. Both are now classified and scanned. The classification is
// TOTAL — every string lands in exactly one context — so "not scanned" is a
// decision with a name rather than the default.

/** A CSS declaration list: `color:var(--x)`, `--gap: 4px`.
 *
 *  An English sentence opens exactly the same way. `"Note: the raw value is in
 *  wei"` matched this shape and was therefore classified as CSS, with two
 *  consequences that would have got the whole lint switched off: A5 reported the
 *  sentence as an inline style and told the author to "move the declaration into
 *  styles.nim behind a class", and the CSS context matches the prose-risky
 *  colours FREELY, so `"Status: green means finalised"` failed A1 on the word
 *  green. The value side must therefore read as CSS rather than as prose —
 *  either it carries a CSS-significant character, or it is too short to be a
 *  sentence, which is what `background:ButtonFace` and `color:red` are. */
const CSS_DECL_RE = /^\s*(?:--)?[a-z-]+\s*:[^:]/i;
const CSS_VALUEISH_RE = /[#(){};]|\d\s*(?:px|rem|em|%)|\bvar\b|!important/i;
const looksLikeCssDecl = (t) =>
  CSS_DECL_RE.test(t) && (CSS_VALUEISH_RE.test(t) || t.trim().split(/\s+/).length <= 3);
/** Hand-built markup: an open or close tag, or a bare `style=` attribute. */
const HTML_TAG_RE = /<\/?[a-z][a-z0-9]*(?:[\s/>]|$)/i;
const STYLE_ATTR_RE = /(?<![\w-])style\s*=\s*(["'])([\s\S]*?)\1/gi;

export const CTX = { CSS: "css", MARKUP: "markup", VALUE: "value" };

/** Runs of string literals joined by `&`, as ONE synthetic string each.
 *
 *  Splitting a value across a concatenation is the obvious way to walk past a
 *  text-matching detector: `"background:Butt" & "onFace"` is `background:Butt`
 *  (not a colour) followed by `onFace` (not a colour), and a browser renders
 *  ButtonFace. It works across `"""` blocks too. Joining the run and scanning
 *  the join closes the direct case; a value routed through a `const` in another
 *  module is still out of reach, and is stated as such in the header. */
export function nimConcatRuns(src, strings) {
  if (!strings.length) return [];
  const runs = [];
  let run = [strings[0]];
  for (let i = 1; i < strings.length; i++) {
    const between = src.slice(strings[i - 1].end, strings[i].start);
    if (/^\s*&\s*$/.test(between)) run.push(strings[i]);
    else { if (run.length > 1) runs.push(run); run = [strings[i]]; }
  }
  if (run.length > 1) runs.push(run);
  return runs;
}

/** kind + text → scan context. `text` must already be unescaped and allowlisted. */
export function classifyString(kind, text) {
  if (kind === "block") return CTX.CSS;
  const t = text.trim();
  if (HTML_TAG_RE.test(t) || /(?<![\w-])style\s*=\s*["']/i.test(t)) return CTX.MARKUP;
  if (looksLikeCssDecl(t)) return CTX.CSS;
  return CTX.VALUE;
}

/** Apply the allowlist by blanking every allowed match, so what remains is
 *  exactly the un-exempted text. Returns the blanked text plus per-entry hits. */
function applyAllowlist(text, hits) {
  let out = text;
  for (const entry of ALLOWLIST) {
    out = out.replace(new RegExp(entry.re.source, entry.re.flags), (m) => {
      hits.set(entry.id, (hits.get(entry.id) ?? 0) + 1);
      return " ".repeat(m.length);
    });
  }
  return out;
}

// ── The web-lineage token model ────────────────────────────────────────────

/** base.type.h1.size → --bt-type-h1-size (drop 1); theme.light.surface.canvas
 *  → --bt-surface-canvas (drop 2). Identical to `cssVarName` in tokens.nim. */
export function cssVarName(path) {
  const drop = path[0] === "base" ? 1 : 2;
  return "--bt-" + path.slice(drop).join("-");
}

export function flattenTokens(doc) {
  const out = [];
  const walk = (node, path, group) => {
    if (!node || typeof node !== "object") return;
    if ("$value" in node) {
      const v = node.$value;
      const isRef = typeof v === "string" && v.startsWith("{") && v.endsWith("}");
      out.push({
        path: path.join("."),
        cssVar: cssVarName(path),
        group,
        kind: isRef ? "bkToken" : "bkLiteral",
        counterpart: isRef ? v.slice(1, -1) : "",
        value: String(v),
        type: node.$type ?? "",
        divergence: node.$extensions?.["bt.divergence"] ?? "",
        description: node.$description ?? "",
      });
      return;
    }
    for (const k of Object.keys(node)) {
      if (k.startsWith("$")) continue;
      walk(node[k], [...path, k], group);
    }
  };
  walk(doc.base, ["base"], "base");
  for (const t of ["light", "dark"]) walk(doc.theme?.[t], ["theme", t], `theme.${t}`);
  for (const r of ["explorer", "debugger"]) walk(doc.register?.[r], ["register", r], `register.${r}`);
  return out;
}

const px = (v) => {
  const m = /^(-?\d*\.?\d+)px$/.exec(v);
  return m ? Number(m[1]) : null;
};

// ── Checks ─────────────────────────────────────────────────────────────────

async function run(opts) {
  const checks = [];
  const add = (id, title, ok, detail) => checks.push({ id, title, ok, detail });

  const doc = JSON.parse(await readFile(WEB_TOKENS, "utf8"));
  const tokens = flattenTokens(doc);
  const declared = new Set(tokens.map((t) => t.cssVar));

  // Resolve every {ref} against the design system so a rhythm/parity check can
  // compare NUMBERS rather than reference strings.
  const dsDir = process.env.DESIGN_SYSTEM_SRC || join(REPO_ROOT, "..", "codetracer-design-system");
  let resolved = null;
  if (existsSync(join(dsDir, "brand", "brand.json"))) {
    const roots = [];
    for (const rel of ["brand/brand.json", "alias/alias.json", "mapped/mapped.json"]) {
      roots.push(JSON.parse(await readFile(join(dsDir, rel), "utf8")));
    }
    const lookup = (p) => {
      for (const root of roots) {
        let node = root;
        let ok = true;
        for (const seg of p.split(".")) {
          if (!node || typeof node !== "object" || !(seg in node)) { ok = false; break; }
          node = node[seg];
        }
        if (ok) return node;
      }
      return null;
    };
    const deref = (p, seen = []) => {
      if (seen.includes(p)) throw new Error(`cyclic token reference: ${p}`);
      const node = lookup(p);
      if (!node || !("$value" in node)) throw new Error(`unknown design-system token: ${p}`);
      const v = node.$value;
      if (typeof v === "string" && v.startsWith("{") && v.endsWith("}")) return deref(v.slice(1, -1), [...seen, p]);
      return String(v);
    };
    resolved = new Map();
    for (const t of tokens) {
      let value = t.value;
      if (t.kind === "bkToken") value = deref(t.counterpart);
      if (t.type === "dimension" && /^-?\d*\.?\d+$/.test(value)) value += "px";
      // Keyed BOTH ways. `--bt-density-cell-y` exists once per register with a
      // different value in each; a map keyed by name alone silently keeps
      // whichever group was walked last, which is how a register-aware check
      // ends up measuring one register twice.
      resolved.set(t.cssVar, value);
      resolved.set(`${t.group}|${t.cssVar}`, value);
    }
  }

  // ── A1–A4: the Layer 2 scan ─────────────────────────────────────────────
  const files = [];
  for (const dir of LAYER2_DIRS) {
    for (const f of readdirSync(dir).sort()) {
      if (f.endsWith(".nim")) files.push(join(dir, f));
    }
  }
  // A0 also has to answer "is this the WHOLE of Layer 2". The scan enumerates
  // two directories by name, so a view module written anywhere else under
  // client/src is unscanned and the checker reports a clean pass over a subset
  // — found by trying to evade this file's own fix. Any .nim outside the
  // enumerated directories (and outside Layer 0/1, where raw values belong)
  // that renders markup or carries a stylesheet is a Layer 2 view in the wrong
  // place, and fails here rather than being silently out of scope.
  const CLIENT_SRC = join(REPO_ROOT, "client", "src");
  const DESIGN_SYSTEM_DIR = join(CLIENT_SRC, "design_system");
  const walk = (dir) => {
    const out = [];
    for (const e of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const p = join(dir, e.name);
      if (e.isDirectory()) out.push(...walk(p));
      else if (e.name.endsWith(".nim")) out.push(p);
    }
    return out;
  };
  const outOfScopeViews = [];
  if (existsSync(CLIENT_SRC)) {
    for (const f of walk(CLIENT_SRC)) {
      if (files.includes(f) || f.startsWith(DESIGN_SYSTEM_DIR)) continue;
      const src = await readFile(f, "utf8");
      const why = [];
      // Every spelling Nim accepts, not the one spelling VD.3 happened to write.
      // `import isonim/[dsl/ui]` and `from isonim/dsl/ui import nil` are the
      // same import and both walked past a `^import isonim/dsl/ui` anchor.
      if (/^[ \t]*(?:import|from)\s+isonim\b[^\n]*(?:dsl\/ui|ssr\/renderer)/m.test(src)) {
        why.push("imports the isonim view DSL");
      }
      // A stylesheet does not have to be in a `"""` block to be a stylesheet.
      // `const extraCss* = "body{background:ButtonFace}"` is one, and requiring
      // the triple-quoted form made a rogue module invisible for the price of a
      // reformat. A single-line string has to look MORE like CSS than a block
      // does — a braced rule set — so an ordinary `"a: b;"` in a ViewModel is
      // not mistaken for one.
      for (const s of nimStrings(src)) {
        const text = s.kind === "block" ? stripCssComments(s.text) : s.unescaped;
        // The declaration's terminator may be on the NEXT line — `.x{\n
        // color: #ff0000\n}` is a stylesheet, and requiring `;` or `}` on the
        // same line as the value meant a reformat was enough to hide one.
        const isSheet = s.kind === "block"
          ? /[a-z-]+\s*:\s*[^;}]+[;}]/.test(text)
          : /\{[^{}]*[a-z-]+\s*:\s*[^;}]+[;}]/.test(text);
        if (isSheet) {
          why.push(`carries a stylesheet at line ${s.line}`);
          break;
        }
      }
      if (why.length) outOfScopeViews.push({ file: relative(REPO_ROOT, f), line: 1, text: why.join("; ") });
    }
  }

  if (files.length === 0) {
    // Fail closed: an empty file list is "the subject is absent", not a pass.
    add("A0", "Layer 2 sources located", false, `no .nim sources under ${LAYER2_DIRS.map((d) => relative(REPO_ROOT, d)).join(", ")}`);
  } else if (outOfScopeViews.length) {
    add("A0", "Layer 2 sources located", false,
      `${outOfScopeViews.length} view module(s) outside the scanned directories (${LAYER2_DIRS.map((d) => relative(REPO_ROOT, d)).join(", ")}) — ` +
      `A1–A7 would report a clean pass over a subset:\n` +
      outOfScopeViews.map((v) => `        ${v.file}  ${v.text}`).join("\n"));
  } else {
    add("A0", "Layer 2 sources located", true,
      `${files.length} file(s): ${files.map((f) => relative(REPO_ROOT, f)).join(", ")}` +
      `; no view module elsewhere under client/src`);
  }

  const allowHits = new Map();
  const rawColours = [];
  const rawLengths = [];
  const primitives = [];
  const danglingRefs = [];
  const inlineStyles = [];
  const markupFragments = [];
  const usedVars = new Set();
  const scanned = { css: 0, markup: 0, value: 0 };
  let scannedChars = 0;

  for (const file of files) {
    const rel = relative(REPO_ROOT, file);
    const src = await readFile(file, "utf8");

    // A5's source-level half. `span(style = value)` — a variable, a call, a
    // concatenation — has NO string literal for the scan below to classify, and
    // is still an inline style attribute. Read off the code with every string
    // and comment blanked, so this file's own prose cannot trip it.
    // Case-insensitively: Nim identifiers ignore case after the first letter,
    // and `$ident` emits the SOURCE spelling, so `span(sTyLe = …)` renders
    // `<span sTyLe="…">` — which an HTML parser honours, attribute names being
    // case-insensitive.
    const code = nimCode(src);
    for (const m of code.matchAll(/(?<![\w-])style\s*=/gi)) {
      inlineStyles.push({ file: rel, line: code.slice(0, m.index).split("\n").length, kind: "attribute", text: "style = …" });
    }

    const strings = nimStrings(src);
    const bodyOf = (s) => (s.kind === "block" ? stripCssComments(s.text) : s.unescaped);
    const units = [
      ...strings.map((s) => ({ kind: s.kind, line: s.line, raw: bodyOf(s), joined: false })),
      // Every `&`-joined run, scanned AS ONE STRING as well as separately.
      ...nimConcatRuns(src, strings).map((run) => ({
        kind: run.every((s) => s.kind === "block") ? "block" : "string",
        line: run[0].line, raw: run.map(bodyOf).join(""), joined: true,
      })),
    ];

    for (const s of units) {
      const ctx0 = classifyString(s.kind, s.raw);
      // A CSS identifier escape is a hiding place only in a stylesheet or a
      // markup fragment; decoding ordinary prose would be noise.
      const decoded = ctx0 === CTX.VALUE ? s.raw : decodeCssEscapes(s.raw);
      // A joined run re-reads text already counted, so its allowlist hits are
      // thrown away: A6 must report how many times an exemption really fired.
      const body = applyAllowlist(decoded, s.joined ? new Map() : allowHits);
      const ctx = classifyString(s.kind, body);
      if (!s.joined) { scanned[ctx]++; scannedChars += body.length; }

      const lineAt = (idx) => s.line + body.slice(0, idx).split("\n").length - 1;
      const colour = (m, id) => rawColours.push({ file: rel, line: lineAt(m.index), kind: id, text: m[0] });
      const length = (m) => rawLengths.push({ file: rel, line: lineAt(m.index), text: m[0] });

      // `@import` pulls in a stylesheet this checker never reads, so every
      // value in it is outside every rule above. There is no legitimate use in
      // a Layer 2 view: the page's CSS is assembled in layout.nim.
      // Case-insensitively: CSS at-rule names are ASCII case-insensitive exactly
      // as the system colours are, so `@IMPORT url(…)` is honoured by every
      // browser and walked past a case-sensitive `@import`. That is the same
      // defect this file diagnoses for `buttonface` two hundred lines above.
      for (const m of body.matchAll(/@import\b[^;]*/gi)) {
        markupFragments.push({ file: rel, line: lineAt(m.index), kind: "external-stylesheet", text: m[0].trim().slice(0, 100) });
      }

      if (ctx === CTX.MARKUP) {
        markupFragments.push({ file: rel, line: s.line, kind: "hand-built-markup", text: body.trim().slice(0, 100) });
        for (const m of body.matchAll(STYLE_ATTR_RE)) {
          inlineStyles.push({ file: rel, line: lineAt(m.index), kind: "markup", text: m[0].trim() });
        }
      }
      if (ctx === CTX.CSS && s.kind === "string") {
        inlineStyles.push({ file: rel, line: s.line, kind: "declaration", text: body.trim() });
      }

      // Colours. The unambiguous shapes are looked for EVERYWHERE — no English
      // sentence contains `#4f46e5` or `rgb(`. The prose-risky ones (the word
      // "orange", the word `Canvas`) are looked for freely in CSS and in
      // hand-built markup, which are not prose, and in an ordinary string only
      // when the WHOLE string is that colour — which is exactly the shape of
      // `content = "#4f46e5"` and `content = "ButtonFace"`, and is never the
      // shape of `text "Paste a block, tx hash, or address"`.
      for (const d of UNAMBIGUOUS_COLOUR) for (const m of body.matchAll(d.re)) colour(m, d.id);
      if (ctx === CTX.VALUE) {
        const t = body.trim();
        for (const d of PROSE_RISKY_COLOUR) {
          for (const m of t.matchAll(d.re)) if (m[0] === t) colour({ 0: m[0], index: body.indexOf(t) }, d.id);
        }
        for (const m of t.matchAll(RAW_LENGTH)) if (m[0] === t) length({ 0: m[0], index: body.indexOf(t) });
      } else {
        for (const d of PROSE_RISKY_COLOUR) for (const m of body.matchAll(d.re)) colour(m, d.id);
        for (const m of body.matchAll(RAW_LENGTH)) length(m);
      }

      for (const d of BRAND_PRIMITIVE) {
        for (const m of body.matchAll(d.re)) {
          primitives.push({ file: rel, line: lineAt(m.index), kind: d.id, text: m[0] });
        }
      }
      for (const m of body.matchAll(/var\(\s*(--bt-[a-z0-9-]+)/g)) {
        usedVars.add(m[1]);
        if (!declared.has(m[1])) {
          danglingRefs.push({ file: rel, line: lineAt(m.index), text: m[1] });
        }
      }
    }
  }

  // A `&`-joined run is scanned twice on purpose — once member by member, once
  // as the string a browser will actually see — so one violation can be found
  // twice. Report it once.
  const dedupe = (arr) => {
    const seen = new Set();
    return arr.filter((v) => {
      const k = `${v.file}:${v.line}:${v.kind ?? ""}:${v.text}`;
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    });
  };
  for (const arr of [rawColours, rawLengths, primitives, danglingRefs, markupFragments]) {
    const kept = dedupe(arr);
    arr.length = 0;
    arr.push(...kept);
  }

  // One inline style reported once: a `span(style = "color:red")` is seen both
  // as an attribute in the code and as a declaration list in the strings.
  const byPlace = new Map();
  for (const s of inlineStyles) {
    const k = `${s.file}:${s.line}`;
    // Prefer the entry that names the actual declaration over the bare
    // "there is a style= here" one, so the failure text is useful.
    if (!byPlace.has(k) || byPlace.get(k).kind === "attribute") byPlace.set(k, s);
  }
  const inlineStylesUnique = [...byPlace.values()]
    .sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line);

  const fmt = (arr, n = 12) =>
    arr.slice(0, n).map((v) => `        ${v.file}:${v.line}  ${v.text}${v.kind ? `  (${v.kind})` : ""}`).join("\n") +
    (arr.length > n ? `\n        … and ${arr.length - n} more` : "");

  add("A1", "no raw colour in a Layer 2 view", rawColours.length === 0,
    rawColours.length ? `${rawColours.length} raw colour value(s):\n${fmt(rawColours)}` :
      `${scanned.css} CSS-bearing, ${scanned.markup} markup and ${scanned.value} bare-value string(s), ${scannedChars} chars scanned — ` +
      `0 hex, rgb(), hsl(), color-mix(), lab/lch, named colour or CSS SYSTEM colour ` +
      `(${SYSTEM_COLOURS_COMPOUND.length + SYSTEM_COLOURS_AMBIGUOUS.length} of them, ButtonFace among them)`);

  add("A2", "no raw pixel or length value in a Layer 2 view", rawLengths.length === 0,
    rawLengths.length ? `${rawLengths.length} raw length(s):\n${fmt(rawLengths)}` :
      "0 length literals outside the allowlist — every size comes from a --bt-* token");

  add("A3", "no brand primitive in a Layer 2 view", primitives.length === 0,
    primitives.length ? `${primitives.length} brand-primitive reference(s):\n${fmt(primitives)}` :
      "0 references to --ct-* or to a raw DTCG path — the primitive ramp is not emitted, so such a reference is both linted and undefined");

  add("A4", "every semantic token a view references is emitted", danglingRefs.length === 0,
    danglingRefs.length ? `${danglingRefs.length} reference(s) to a --bt-* variable that web.tokens.json does not define:\n${fmt(danglingRefs)}` :
      `${usedVars.size} distinct --bt-* tokens referenced, all declared`);

  // A5: inline style attributes. AGENTS.md tells a contributor not to write one
  // and says "the checker fails on any of them". VD.2's A5 only REPORTED them
  // and passed unconditionally, so the documented rule was not the enforced one.
  // It is now enforced: an inline style is a design decision written where no
  // token layer can see it, and there is nowhere in this product that needs one.
  // Detected three ways, so it cannot be reached around — a `style =` attribute
  // in the code (even one whose value is a variable), a `style="…"` inside a
  // hand-built fragment, and a bare string that is a CSS declaration list.
  add("A5", "no inline style attribute in a Layer 2 view", inlineStylesUnique.length === 0,
    inlineStylesUnique.length === 0 ? "0 inline styles — every view uses a utility class"
      : `${inlineStylesUnique.length} inline style(s) — move the declaration into styles.nim behind a class:\n${fmt(inlineStylesUnique)}`);

  // A6: the allowlist must not rot.
  const stale = ALLOWLIST.filter((e) => !(allowHits.get(e.id) > 0));
  add("A6", "every allowlist entry still matches something", stale.length === 0,
    stale.length ? `${stale.length} stale exemption(s) — delete them rather than leaving a standing permission: ${stale.map((e) => e.id).join(", ")}`
      : ALLOWLIST.map((e) => `${e.id} x${allowHits.get(e.id)}`).join(", "));

  // A7: hand-built HTML. AGENTS.md: "Don't hand-concatenate HTML". It is also
  // what made the whole markup context invisible to VD.2's scan — a string
  // spliced through `raw` is markup the DSL never sees and the token layer
  // never reaches. The fragment is scanned above AND rejected here, so a
  // colour smuggled inside one fails twice rather than not at all.
  add("A7", "no hand-built markup and no external stylesheet in a Layer 2 view", markupFragments.length === 0,
    markupFragments.length === 0 ? "0 hand-built fragments and 0 @import — markup comes from the isonim DSL, and the page's CSS is assembled in layout.nim"
      : `${markupFragments.length} unscannable escape hatch(es) — build markup with the DSL, and put CSS in styles.nim, so attributes and values stay inspectable:\n${fmt(markupFragments)}`);

  // ── B: Design-System.md §4.1 — the divergence rule ──────────────────────
  const literals = tokens.filter((t) => t.kind === "bkLiteral");
  const docText = existsSync(DIVERGENCE_DOC) ? await readFile(DIVERGENCE_DOC, "utf8") : null;
  if (docText === null) {
    add("B1", "every literal binding has a divergence row", false, `${relative(REPO_ROOT, DIVERGENCE_DOC)} does not exist`);
    add("B2", "every divergence row has at least one literal", false, "no divergence document");
  } else {
    const rowIds = new Set([...docText.matchAll(/^\|\s*\*{0,2}(D-\d+)\*{0,2}\s*\|/gm)].map((m) => m[1]));
    const untracked = literals.filter((t) => !t.divergence || !rowIds.has(t.divergence));
    add("B1", "every literal binding has a divergence row", untracked.length === 0,
      untracked.length ? `${untracked.length} untracked literal(s):\n` + untracked.slice(0, 12).map((t) => `        ${t.path} = ${t.value}  → ${t.divergence || "(no bt.divergence)"}`).join("\n")
        : `${literals.length} literal binding(s), every one naming a row in ${relative(REPO_ROOT, DIVERGENCE_DOC)}`);

    const used = new Set(literals.map((t) => t.divergence));
    // A structural row records WHERE the lineage lives, not what it renders, so
    // it has no literal behind it by nature. The set is enumerated rather than
    // pattern-matched, so adding a second one is a deliberate edit here — and
    // a structural row that DOES acquire a literal is misfiled, which fails too.
    const misfiled = [...STRUCTURAL_ROWS].filter((r) => used.has(r));
    const orphanRows = [...rowIds].filter((r) => !used.has(r) && !STRUCTURAL_ROWS.has(r)).sort();
    add("B2", "every divergence row has at least one literal", orphanRows.length === 0 && misfiled.length === 0,
      misfiled.length ? `${misfiled.join(", ")} is declared structural but a literal names it — either the row is a real divergence or the token should not point at it`
        : orphanRows.length ? `${orphanRows.length} row(s) describing a divergence that no longer exists: ${orphanRows.join(", ")}`
        : `${rowIds.size} row(s): ${rowIds.size - STRUCTURAL_ROWS.size} backed by at least one literal, ${STRUCTURAL_ROWS.size} structural (${[...STRUCTURAL_ROWS].join(", ")})`);

    // B3: the generated binding table is current.
    const table = renderBindings(tokens);
    const begin = docText.indexOf(BINDINGS_BEGIN);
    const end = docText.indexOf(BINDINGS_END);
    if (begin === -1 || end === -1) {
      add("B3", "the implemented-binding table is present and current", false,
        `the generated markers are missing from ${relative(REPO_ROOT, DIVERGENCE_DOC)}`);
    } else {
      const current = docText.slice(begin + BINDINGS_BEGIN.length, end).trim();
      const fresh = current === table.trim();
      add("B3", "the implemented-binding table is present and current", fresh,
        fresh ? `${tokens.length} binding(s) listed, matching web.tokens.json`
          : "the table has drifted from web.tokens.json — regenerate with --write-bindings");
    }
  }

  // ── B4: a citation of a review finding resolves ─────────────────────────
  //
  // VD.2's ledger REPLACED VD.1's round and reused the ids. Every `L1/1`,
  // `L2/6` and `L2/7` written into styles.nim and nav.nim against VD.1's ledger
  // therefore still parses and now points at a DIFFERENT finding — a comment
  // that reads as evidence and is not. Worse, `L1/13` never existed in the new
  // ledger at all and nothing said so.
  //
  // The fix is a citation form that names the revision it was written against
  // and an id that must exist in it — a SPECIMEN OF THE FORM, not evidence for
  // any claim made here, so it is re-stamped whenever `ledgerRevision` moves
  // and nothing about this comment's meaning turns on which id it shows:
  //
  //     ledger@2026-08-31.14:tx-detail/wide/light/L1/8
  //
  // A ledger round that replaces its predecessor bumps `ledgerRevision`, so
  // every stale citation goes red in one run rather than rotting silently.
  // Evidence that survives a superseded round is cited by FILE PATH instead
  // (reviews/break-round-debug-affordance.json), and the path must exist.
  {
    const CITE = /ledger@([0-9][\w.-]*):([a-z0-9-]+\/[a-z0-9-]+\/[a-z0-9-]+\/(?:L\d+|ADV)\/\d+)/gi;
    // THE FILE-PATH FORM HAS TO REACH THE FILES THE REPORTS ARE ACTUALLY IN.
    //
    // The block comment above names citation-by-file-path as the mechanism for
    // "evidence that survives a superseded round", and it is the right one: a
    // report file under `reviews/rounds/<round>/` is immutable, so unlike a
    // `ledger@` id it does not change meaning when the next round replaces the
    // reviews on its triple. But this pattern only reached `reviews/*.json` —
    // one directory deep, `.json` only — and every report the campaign has ever
    // written lives at `reviews/rounds/<round>/<view>__<size>__<theme>__<lens>`
    // with a `.json` or (in the vd5 rounds) `.md` extension.
    //
    // The consequence was not hypothetical and was not small: FIVE places in
    // the tree already cite a round report by path — viewutil.nim:194,
    // debugger_css.nim:52, demo_session.nim:491, expectations.mjs:104,
    // check-brief.mjs:129 — and B4 could check none of them. viewutil.nim's
    // says out loud that it is "deliberately NOT cited in the
    // `ledger@revision:id` form" because that form would rot, so the author
    // reached for the stable one and it silently fell outside the checker.
    // Unverified evidence citations sitting in the source is the exact defect
    // B4 exists to catch, and B4 was blind to this whole class of them.
    //
    // This STRENGTHENS the check — every one of those five must now exist —
    // and it gives the stale `ledger@` citations a target form that will not go
    // red again at the next round.
    const PATH_CITE = /(?<![\w/.-])(reviews\/[\w./-]+\.(?:json|md))/g;
    const sources = [
      ...files,
      WEB_TOKENS,
      ...(existsSync(DIVERGENCE_DOC) ? [DIVERGENCE_DOC] : []),
    ];
    // ── B4 NO LONGER ASSERTS REVISION CURRENCY (Q21) ──────────────────────
    //
    // It used to fail any citation whose revision was not the current one. That
    // is a PROXY for "this citation still means what the comment says", and the
    // proxy fired on every citation at every ingest regardless of what the round
    // touched — three consecutive rounds turned the same five tx-detail sites
    // red while re-reviewing debugger triples, and `design-citations` classified
    // all of them SAFE-RESTAMP all three times.
    //
    // B4 now asks the real question, by calling what `citation-evidence.mjs`
    // already computed: is the finding at that id the same finding it was at the
    // cited revision? MEANING-CHANGED fails. SAFE-RESTAMP does not, because
    // there is nothing wrong with it.
    //
    // Strictly stronger, which is the only basis on which this may be done at
    // all: recall is unchanged (a meaning change alters the text), precision
    // improves, and the two cases the old check could not distinguish from
    // ordinary staleness — an id that has left the ledger, and a revision that
    // never existed — now fail on their own terms. See lib/citation-meaning.mjs
    // for the argument in full, and for why a shallow CI checkout falls back to
    // the old proxy rather than inventing a verdict.
    const ledgerPath = join(REPO_ROOT, "reviews", "ledger.json");
    let current = null;
    let revision = null;
    if (existsSync(ledgerPath)) {
      const L = JSON.parse(await readFile(ledgerPath, "utf8"));
      revision = L.ledgerRevision ?? null;
      current = indexFindings(L);
    }
    const history = current ? ledgerHistoryAvailable(REPO_ROOT) : { ok: false, reason: "no ledger" };
    const at = makeLedgerAtRevision(REPO_ROOT);
    const bad = [];
    let cites = 0;
    let restamped = 0;
    let fellBack = 0;
    for (const file of sources) {
      const rel = relative(REPO_ROOT, file);
      const text = await readFile(file, "utf8");
      const lineOf = (i) => text.slice(0, i).split("\n").length;
      for (const m of text.matchAll(CITE)) {
        cites++;
        const where = { file: rel, line: lineOf(m.index) };
        if (!current) {
          bad.push({ ...where, text: `${m[0]} — reviews/ledger.json does not exist` });
          continue;
        }
        const c = classifyCitation({
          citedRevision: m[1], id: m[2], currentRevision: revision, current, at, history,
        });
        switch (c.verdict) {
          case "current":
            break;
          case "SAFE-RESTAMP":
            // Resolves, and still means what it meant. The revision string is
            // out of date and nothing turns on it.
            restamped++;
            break;
          case "MEANING-CHANGED":
            bad.push({ ...where, text:
              `${m[0]} — the finding at that id CHANGED MEANING since the cited revision. ` +
              `Then: ${JSON.stringify(String(c.was.finding).slice(0, 110))}. ` +
              `Now: ${JSON.stringify(String(c.now.finding).slice(0, 110))}. ` +
              `Re-read the comment against the current finding; do NOT simply re-stamp the revision` });
            break;
          case "id-gone-from-current-ledger":
            bad.push({ ...where, text: `${m[0]} — no finding with that id in the ${revision} ledger` });
            break;
          case "id-not-in-cited-revision":
            bad.push({ ...where, text:
              `${m[0]} — revision ${m[1]} exists, and has no finding with that id. ` +
              `This citation has never resolved` });
            break;
          case "cited-revision-not-in-history":
            bad.push({ ...where, text:
              `${m[0]} — revision ${m[1]} is not in this repository's history of reviews/ledger.json, ` +
              `so what the citation pointed at cannot be established` });
            break;
          case "unverifiable-no-history":
            // The CI case. No history, so the meaning cannot be compared and
            // currency is the only signal left — which is what B4 used to do
            // for every citation. Reported as the fallback it is.
            fellBack++;
            if (m[1] !== revision) {
              bad.push({ ...where, text:
                `${m[0]} — cites revision ${m[1]}, the ledger is at ${revision}, and the meaning ` +
                `could not be compared (${c.reason}). Run \`just design-citations\` in a full ` +
                `checkout to see whether this is a safe re-stamp or a changed finding` });
            }
            break;
        }
      }
      for (const m of text.matchAll(PATH_CITE)) {
        cites++;
        if (!existsSync(join(REPO_ROOT, m[1]))) bad.push({ file: rel, line: lineOf(m.index), text: `${m[1]} — cited as evidence, does not exist` });
      }
    }
    const note = [
      `${cites} citation(s) across ${sources.length} source(s)`,
      `ledger revision ${revision}`,
      restamped ? `${restamped} cite an earlier revision and still resolve to the SAME finding (safe)` : null,
      fellBack ? `${fellBack} judged on revision currency alone — ${history.reason}` : null,
    ].filter(Boolean).join("; ");
    add("B4", "every review-finding citation still means what it says", bad.length === 0,
      bad.length ? `${bad.length} citation(s) that do not resolve — a comment that reads as evidence and is not:\n${fmt(bad)}`
        : note);
  }

  // ── C: the token model's own invariants ─────────────────────────────────
  const keySet = (group) => new Set(tokens.filter((t) => t.group === group).map((t) => t.cssVar));
  const diff = (a, b) => [...a].filter((k) => !b.has(k)).sort();

  const lightKeys = keySet("theme.light");
  const darkKeys = keySet("theme.dark");
  const onlyLight = diff(lightKeys, darkKeys);
  const onlyDark = diff(darkKeys, lightKeys);
  add("C1", "light and dark carry identical key sets", onlyLight.length === 0 && onlyDark.length === 0,
    onlyLight.length || onlyDark.length
      ? `light-only: ${onlyLight.join(", ") || "none"}; dark-only: ${onlyDark.join(", ") || "none"} — a theme built by inversion-with-omissions is what VD.7 exists to find, and it must not be creatable here`
      : `${lightKeys.size} colour roles, defined independently in both themes`);

  const expKeys = keySet("register.explorer");
  const dbgKeys = keySet("register.debugger");
  const onlyExp = diff(expKeys, dbgKeys);
  const onlyDbg = diff(dbgKeys, expKeys);
  add("C2", "both registers carry identical density key sets", onlyExp.length === 0 && onlyDbg.length === 0,
    onlyExp.length || onlyDbg.length
      ? `explorer-only: ${onlyExp.join(", ") || "none"}; debugger-only: ${onlyDbg.join(", ") || "none"} — Design-System.md §2 requires one component parametrised by density, not two component sets`
      : `${expKeys.size} density tokens, defined in both registers`);

  // C3 — the rhythm ladder, ranked over the tokens the STYLESHEET ACTUALLY
  // READS.
  //
  // VD.2 ranked `--bt-rhythm-row` as the bottom rung. No rule in styles.nim
  // ever referenced it: the row rung the stylesheet reads is
  // `--bt-density-cell-y`, the register's own cell padding. So C3 passed by
  // measuring a token that was emitted and used nowhere — a check that ranks a
  // value no page can render is not a check. The dead token is gone and the
  // live one takes its place, which also makes the ladder register-aware:
  // the bottom rung is per-register by construction, and BOTH registers are
  // ranked, because a ladder that holds in one and collapses in the other is
  // the two-component-sets failure Design-System.md §2 forbids.
  //
  // WHICH QUANTITY IS RANKED, and why it changed. VD.3 ranked the row PADDING
  // (`cell-y`) against the margins above it, printed the row-to-row GAP that
  // padding produces (2x cell-y) beside the verdict, and did not gate on it.
  // That is overruled here, on evidence rather than on taste:
  //
  //   * A ladder only means something if every rung is the same KIND of
  //     quantity. `cell-y` is a padding; stack, group and section are gaps.
  //     Two paddings meet at every row boundary, so the like-for-like number is
  //     2x cell-y — which VD.3's own comment says, and then does not use. The
  //     gated ratio was a half-quantity against a full one, and the 3.00x it
  //     reported was not a separation.
  //   * It let the founding defect back in. With cell-y at `{scale.450}` = 12px
  //     — an ordinary step of the brand ramp, one token away — the row-to-row
  //     gap is 24px, EXACTLY the 24px stack rung. C3 printed "1.00x under
  //     stack" and PASSED. That is verbatim the VD.1 defect this ladder exists
  //     to prevent: one spacing step doing two jobs, so proximity carries no
  //     grouping information. A check that accepts its own founding defect is
  //     not a check.
  //   * The stated reason for not gating — adjacent rows carry a hairline rule,
  //     so proximity is not the only cue — is true and is not applied anywhere
  //     else in this stylesheet: `.sec-title.next` puts a hairline across the
  //     LARGEST gap in the system. A principle invoked only where the number
  //     failed is not a principle.
  //
  // So the bottom rung is the GAP, and the padding and the row pitch are printed
  // beside it as context. The pitch is printed because it is the number VD.1
  // originally measured (49px) and it is NOT comparable to a gap — a pitch
  // includes the line box — so naming it here stops it being compared again.
  if (!resolved) {
    add("C3", "the rhythm roles are strictly separated", false,
      `the design system is not readable at ${dsDir} (set DESIGN_SYSTEM_SRC), so the rhythm could not be resolved to numbers — this check does not pass by being unable to run`);
  } else {
    const upper = ["--bt-rhythm-stack", "--bt-rhythm-group", "--bt-rhythm-section"];
    const problems = [];
    const lines = [];
    let ok = true;
    const padOf = (reg) => px(resolved.get(`register.${reg}|--bt-density-cell-y`) ?? "");
    for (const reg of ["explorer", "debugger"]) {
      const pad = padOf(reg);
      // The bottom rung: two cell paddings meeting at a hairline. The rung NAME
      // is printed in full, because the self-test reads the names back out of
      // this line and requires every one to be a token styles.nim actually
      // references — the property VD.2's C3 lost.
      const vals = [{ k: `2x --bt-density-cell-y (${reg})`, v: pad === null ? null : pad * 2 },
        ...upper.map((k) => ({ k, v: px(resolved.get(k) ?? "") }))];
      const missing = vals.filter((x) => x.v === null);
      if (missing.length) { ok = false; problems.push(...missing.map((x) => `${x.k} is not a px value`)); continue; }
      for (let i = 1; i < vals.length; i++) {
        const ratio = vals[i].v / vals[i - 1].v;
        if (ratio < 1.75) {
          ok = false;
          problems.push(`${vals[i].k} (${vals[i].v}px) is only ${ratio.toFixed(2)}x ${vals[i - 1].k} (${vals[i - 1].v}px) — below the 1.75x separation, so proximity stops grouping`);
        }
      }
      lines.push(`${reg}: ` + vals.map((x) => `${x.k.replace(/ \(.*\)/, "")}=${x.v}px`).join(" < ") +
        `  (bottom rung is the row-to-row GAP — two ${pad}px cell paddings meeting at a hairline — and is GATED. ` +
        `The row PITCH those rows sit on is larger again because it includes the line box; a pitch is not comparable to a gap and is never ranked against one)`);
    }
    add("C3", "the rhythm roles are strictly separated", ok,
      ok ? lines.join("\n        ") + "\n        each rung >= 1.75x the one below, in BOTH registers; every rung is a token styles.nim reads"
        : problems.join("; "));
  }

  // ── D: the shipped CSS, when there is one AND it is current ─────────────
  const staleness = existsSync(BUILT_HTML) ? staleBuild(BUILT_HTML) : null;
  if (!existsSync(BUILT_HTML)) {
    const detail = `no build at ${relative(REPO_ROOT, BUILT_HTML)} — run \`cd client && just export\` first. ` +
      `Without --require-built this check is REPORTED AS NOT RUN, never as a pass.`;
    if (opts.requireBuilt) add("D1", "the shipped CSS declares exactly the derived token set", false, detail);
    else checks.push({ id: "D1", title: "the shipped CSS declares exactly the derived token set", ok: null, detail });
  } else if (staleness) {
    // The artefact predates its own source. Report THAT, and never a token-set
    // comparison against it: the comparison would be arithmetically correct and
    // tell the reader something false about the product.
    const { newer, builtAt, inputAt } = staleness;
    const detail =
      `the build is STALE — ${relative(REPO_ROOT, BUILT_HTML)} was written ${builtAt}, ` +
      `but ${relative(REPO_ROOT, newer)} changed ${inputAt}. ` +
      `Re-run \`cd client && just export\`, then this check again. ` +
      `(\`nix build .#default\` writes result/, which these checks do NOT read.) ` +
      `The token comparison is SKIPPED rather than run against an old page: it would list ` +
      `tokens as absent that the current build ships perfectly well.`;
    if (opts.requireBuilt) add("D1", "the shipped CSS declares exactly the derived token set", false, detail);
    else checks.push({ id: "D1", title: "the shipped CSS declares exactly the derived token set", ok: null, detail });
  } else {
    const html = await readFile(BUILT_HTML, "utf8");
    const style = /<style>([\s\S]*?)<\/style>/.exec(html);
    if (!style) {
      add("D1", "the shipped CSS declares exactly the derived token set", false, "the built page has no <style> block");
    } else {
      const css = style[1];
      const shipped = new Set([...css.matchAll(/(--bt-[a-z0-9-]+)\s*:/g)].map((m) => m[1]));
      const missing = diff(declared, shipped);
      const extra = diff(shipped, declared);
      const ctLeak = [...css.matchAll(/--ct-[a-z0-9-]+/g)].map((m) => m[0]);
      const ok = missing.length === 0 && extra.length === 0 && ctLeak.length === 0;
      add("D1", "the shipped CSS declares exactly the derived token set", ok,
        ok ? `${shipped.size} --bt-* variables in the shipped page, exactly the set web.tokens.json defines; 0 --ct-* primitives leaked`
          : [
              missing.length ? `defined but not shipped: ${missing.join(", ")}` : "",
              extra.length ? `shipped but not defined: ${extra.join(", ")}` : "",
              ctLeak.length ? `brand primitives leaked into the shipped CSS: ${[...new Set(ctLeak)].join(", ")}` : "",
            ].filter(Boolean).join("; "));

      // D2: both themes and both registers actually reached the page.
      const need = [
        ["a light :root block", /:root\s*\{/],
        ["a prefers-color-scheme: dark block", /@media\s*\(prefers-color-scheme:\s*dark\)/],
        ['a [data-theme="light"] override', /\[data-theme="light"\]/],
        ['a [data-theme="dark"] override', /\[data-theme="dark"\]/],
        ['a [data-register="debugger"] block', /\[data-register="debugger"\]/],
      ];
      const absent = need.filter(([, re]) => !re.test(css)).map(([n]) => n);
      add("D2", "both themes and both registers reach the shipped page", absent.length === 0,
        absent.length ? `missing from the shipped CSS: ${absent.join(", ")}`
          : "light, dark, both explicit overrides and the debugger register are all present");
    }
  }

  return { checks, tokens, literals };
}

// ── The generated binding table ────────────────────────────────────────────

export function renderBindings(tokens) {
  const rows = [
    "| `--bt-*` variable | Binding | Value / brand counterpart | Divergence |",
    "| --- | --- | --- | --- |",
  ];
  const order = ["base", "theme.light", "theme.dark", "register.explorer", "register.debugger"];
  const sorted = [...tokens].sort(
    (a, b) => order.indexOf(a.group) - order.indexOf(b.group) || a.cssVar.localeCompare(b.cssVar),
  );
  let group = null;
  for (const t of sorted) {
    if (t.group !== group) {
      group = t.group;
      rows.push(`| **\`${group}\`** | | | |`);
    }
    rows.push(
      `| \`${t.cssVar}\` | ${t.kind} | ${t.kind === "bkToken" ? `\`{${t.counterpart}}\`` : `\`${t.value}\``} | ${t.divergence ? `[${t.divergence}](#${t.divergence.toLowerCase()})` : "—"} |`,
    );
  }
  return rows.join("\n");
}

// ── main ───────────────────────────────────────────────────────────────────

const EXPLAIN = `
tools/design/check-tokens.mjs — what each check decides
───────────────────────────────────────────────────────

verify_no_raw_values_in_views
  A0  Layer 2 sources were found at all, AND they are all of Layer 2. An empty
      file list FAILS — a check that passes because its subject is absent is
      the failure mode this project has hit three times — and so does a view
      module living anywhere else under client/src, because the scan
      enumerates two directories by name and everything else is invisible
      to it.
  A1  No raw colour — hex, rgb(), hsl(), color-mix(), lab/lch, a CSS named
      colour, or a CSS SYSTEM colour — in client/src/{components,pages}/*.nim.
      The system colours are the point: 'background:ButtonFace' is the literal
      that measured 1.04:1, and a detector of designer colour names alone
      cannot see it.
  A2  No raw length. A number with a CSS unit is a design decision and belongs
      in web.tokens.json. Bare 0 and unitless numbers are not lengths.
  A3  No brand primitive: no var(--ct-*), no --ct-* declaration, no raw DTCG
      path. VD.2 stopped emitting the primitive ramp, so such a reference is
      undefined as well as forbidden.
  A4  Every var(--bt-X) a view uses is defined by web.tokens.json. This is
      what makes A1-A3 constructive rather than merely prohibitive.
  A5  NO inline style attribute. Enforced, not merely reported: a 'style ='
      in the code (even with a non-literal value), a 'style="…"' inside a
      hand-built fragment, and a bare string that is a declaration list.
  A6  Every allowlist entry still matches something. An exemption whose
      subject was deleted is a standing permission and fails here.
  A7  No hand-built HTML fragment and no @import. Markup spliced through
      'raw' is markup the DSL never sees, and it is the context VD.2's scan
      skipped entirely; an @import pulls in a stylesheet this checker never
      reads, putting every value in it outside every rule above.

  What gets scanned, and why nothing is skipped by default: every string
  literal is classified into CSS (a triple-quoted block or a declaration
  list), MARKUP (a hand-built fragment) or VALUE (everything else, including
  an attribute value such as 'content = "#4f46e5"'). Unambiguous colour
  shapes are looked for in all three. The prose-risky ones — the word
  "orange", the word 'Canvas' — are looked for freely in CSS and markup, and
  in a VALUE string only when the whole string IS that colour. CSS identifier
  escapes are decoded first (a browser reads a backslash-42 escape as the
  letter B, so 'ButtonFace' can be written without the letters), and runs of
  '&'-joined literals are scanned as one string as well as separately, so a
  value split across a concatenation is still seen.

Design-System.md §4.1 — the divergence rule
  B1  Every bkLiteral names a row in docs/DESIGN-DIVERGENCES-WEB.md.
  B2  Every row corresponds to at least one literal.
  B3  The generated implemented-binding table matches web.tokens.json.
  B4  Every review-finding citation still MEANS what it says. A ledger round
      that replaces its predecessor reuses the ids, so 'ledger@<revision>:<id>'
      keeps parsing while pointing at a different finding — a comment that reads
      as evidence and is not.
      Decided by comparing the finding at that id AT THE CITED REVISION against
      the finding there now. A changed finding fails; an id that has left the
      ledger fails; a revision not in this repository's history fails. A citation
      of a superseded revision whose finding is unchanged PASSES: it needs
      re-stamping at most, and failing it once per ingest regardless of subject
      is what taught bulk re-stamping (QUEUED-DECISIONS Q21).
      Needs git history. Where there is none — a shallow CI checkout — it falls
      back to revision currency and says that it did.

The token model's own invariants
  C1  theme.light and theme.dark carry identical key sets.
  C2  register.explorer and register.debugger carry identical key sets.
  C3  2x cell-y < stack < group < section, each at least 1.75x the one below,
      in BOTH registers. The bottom rung is the row-to-row GAP — two
      --bt-density-cell-y paddings meeting at a hairline — because every other
      rung is a gap and a ladder of mixed quantities ranks nothing. Ranking the
      padding instead let cell-y reach 12px, at which the row gap EQUALS the
      stack rung and C3 passed; that is the VD.1 defect the ladder exists to
      prevent. The row PITCH is never ranked: it includes the line box.
      The --bt-rhythm-row this replaced was emitted and referenced by no rule.
      Resolved to NUMBERS through the design system; if the design system is
      unreadable this check FAILS rather than skipping.

The shipped page
  D1  client/dist declares exactly the derived --bt-* set, and no --ct-*.
  D2  Both themes and both registers reach the shipped CSS.
      Without a build, D1/D2 report NOT RUN. --require-built makes that a
      failure, and \`just design-check\` passes it.
      A build OLDER than any client/src input is reported as STALE and the
      token comparison is skipped: run against an out-of-date page it would
      name tokens 'defined but not shipped' that the current build ships,
      which is a false failure and worse than no check at all.
      Note these two read client/dist, written by \`cd client && just export\`.
      They do NOT read result/, so \`nix build .#default\` will not refresh them.
`;

async function main(argv) {
  if (argv.includes("--explain")) { console.log(EXPLAIN); return 0; }

  if (argv.includes("--write-bindings")) {
    const doc = JSON.parse(await readFile(WEB_TOKENS, "utf8"));
    const table = renderBindings(flattenTokens(doc));
    const text = await readFile(DIVERGENCE_DOC, "utf8");
    const begin = text.indexOf(BINDINGS_BEGIN);
    const end = text.indexOf(BINDINGS_END);
    if (begin === -1 || end === -1) {
      console.error(`missing ${BINDINGS_BEGIN} / ${BINDINGS_END} markers in ${DIVERGENCE_DOC}`);
      return 2;
    }
    const next = text.slice(0, begin + BINDINGS_BEGIN.length) + "\n\n" + table + "\n\n" + text.slice(end);
    await writeFile(DIVERGENCE_DOC, next);
    console.log(`wrote ${table.split("\n").length - 2} binding row(s) into ${relative(REPO_ROOT, DIVERGENCE_DOC)}`);
    return 0;
  }

  const opts = { requireBuilt: argv.includes("--require-built") };
  const { checks, tokens, literals } = await run(opts);
  const failed = checks.filter((c) => c.ok === false);
  const notRun = checks.filter((c) => c.ok === null);
  const ok = failed.length === 0;

  if (argv.includes("--json")) {
    console.log(JSON.stringify({ check: "verify_no_raw_values_in_views", ok, checks, tokenCount: tokens.length, literalCount: literals.length }, null, 2));
    return ok ? 0 : 1;
  }

  console.log(`tokens:    ${tokens.length} --bt-* bindings (${tokens.length - literals.length} bkToken, ${literals.length} bkLiteral)`);
  console.log(`source:    ${relative(REPO_ROOT, WEB_TOKENS)}\n`);
  for (const c of checks) {
    const mark = c.ok === null ? "·" : c.ok ? "✓" : "✗";
    console.log(`  ${mark} ${c.id}  ${c.title}`);
    console.log(`        ${c.detail}`);
  }
  console.log("");
  if (notRun.length) console.log(`${notRun.length} check(s) NOT RUN (reported, never counted as passes): ${notRun.map((c) => c.id).join(", ")}\n`);
  console.log(ok ? `PASS — ${checks.filter((c) => c.ok === true).length}/${checks.filter((c) => c.ok !== null).length} checks`
                 : `FAIL — ${failed.length} check(s) failed: ${failed.map((c) => c.id).join(", ")}`);
  return ok ? 0 : 1;
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2))
    .then((c) => process.exit(c))
    .catch((e) => { console.error(`check-tokens failed: ${e.stack ?? e.message}`); process.exit(2); });
}
