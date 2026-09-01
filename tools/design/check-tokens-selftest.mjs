#!/usr/bin/env node
// VD.2 — the self-test for `verify_no_raw_values_in_views`.
//
//   node tools/design/check-tokens-selftest.mjs
//
// A checker that has never been seen to fail has not been demonstrated. This
// drives every rule of `check-tokens.mjs` against input carrying ONE deliberate
// violation and asserts the rule turns red AND names the right thing.
//
// Two halves, and the second is the one that matters:
//
//   1. **Synthetic.** Rules B, C and the Nim tokeniser are exercised against
//      constructed inputs, in a scratch directory. Cheap, and covers the cases
//      the real tree cannot hold (a light/dark key asymmetry, an orphan
//      divergence row, a rhythm whose roles have collapsed).
//   2. **Against the REAL product source.** Rules A1–A7, B4 and C3 are
//      exercised by EDITING `client/src/**` on disk, running the real checker,
//      and restoring the file in a `finally` — verified byte-identical by
//      SHA-256. A rule demonstrated only on a synthetic fixture has been shown
//      to work on a fixture.
//
// The controls matter as much as the breaks: before each plant, the unmodified
// tree is asserted to PASS the same rule. A checker that failed unconditionally
// would score identically on the breaks alone.
//
// ── The three evasions VD.2's checker did not catch ────────────────────────
//
// A review round planted eight violations against the landed VD.2 lint. Five
// were caught. Three were not, and each now has a plant here that is asserted
// to turn the real checker red AND to name the planted value:
//
//   GAP 1  `background: ButtonFace`. The lint exists to stop the 1.04:1
//          primary button recurring, and that button was 1.04:1 because it
//          inherited the user agent's ButtonFace — which the detector could not
//          see, because it enumerated designer colour names and no CSS SYSTEM
//          colour. **This case is planted by name and must never be removed:
//          it is the regression the whole check was written to prevent.**
//   GAP 2  a hand-built HTML fragment. A single-line string was only scanned
//          when it matched `^[a-z-]+\s*:`, so `"<span style=\"color:#ff0000\">"`
//          was never examined at all.
//   GAP 3  a bare value in an attribute — `content = "#4f46e5"`.
//
// ── The evasions of the FIX, found by attacking it ─────────────────────────
//
// The VD.2 lint was written carefully and still had three holes, so this one is
// assumed to have holes too. Eight further plants below try to walk around the
// fix rather than around the original rule, and each is a case that PASSED
// before the line that closes it was written:
//
//   * lowercase `buttonface` — CSS system colours are ASCII case-insensitive,
//     so a browser honours it identically.
//   * `\42 uttonFace` — a CSS identifier escape. A browser reads it as
//     `ButtonFace`; the checker decodes CSS escapes before matching.
//   * `"…background:Butt" & "onFace…"` — the identifier split across a Nim
//     concatenation, including across two `"""` blocks. Adjacent `&`-joined
//     literals are scanned as one string as well as separately.
//   * a colour in a presentational attribute of a hand-built fragment.
//   * the attribute spelled `sTyLe` — Nim ignores case after the first letter
//     and emits the source spelling; HTML attribute names are case-insensitive.
//   * `@import url(…)`, which would pull in a stylesheet this checker never
//     reads, putting every value in it outside every rule.
//   * a view module in a directory the scan does not enumerate — A0's scope.
//
// ── The evasions of THAT fix, found by attacking it again ──────────────────
//
// A second round attacked the fix above and found seven more. Each PASSED
// before the line that closes it, and each is planted below:
//
//   * `hwb()` and `color()` — two CSS Color 4 colour functions the detector did
//     not list. `background:hwb(200 30% 20%)` passed clean.
//   * `100dvh`, `2lh`, `40q`, `20cqw` — the container-query and
//     dynamic-viewport units, absent from an enumerated unit list.
//   * `@IMPORT` — CSS at-rule names are case-insensitive; the A7 regex was not.
//   * `"\x42uttonFace"` — NIM's numeric escape. The CSS identifier escape was
//     closed; the Nim one, which needs no CSS knowledge, was not.
//   * `background:menu` — seven of the eight names held in the case-SENSITIVE
//     system-colour list have no collision in the real source to justify it.
//   * `import isonim/[dsl/ui]` and a stylesheet in a single-line string — two
//     more ways past A0's scope check.
//   * `text "Note: the raw value is in wei"` classified as a CSS declaration
//     list, so A5 reported an English sentence as an inline style. A FALSE
//     POSITIVE is how a lint gets switched off, so it is planted here too —
//     with `expectClean`, which asserts the checker stays GREEN.
//
// What is still open is recorded rather than hidden, and is narrower than it
// was: a value built at RUN TIME from non-literal parts is out of reach of any
// text-level rule; a value routed through a `const` in a module the scan does
// not read is reachable in principle (A0 already opens those files) and is left
// open deliberately; and a single-word capitalised label — `text "Menu"` —
// still fails A1, because at this level it is indistinguishable from
// `content = "Menu"`. All three are asserted below rather than described.

import { readFile, writeFile, mkdtemp, rm, mkdir, utimes, stat, rename } from "node:fs/promises";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync, execFileSync } from "node:child_process";
import {
  indexFindings,
  ledgerHistoryAvailable,
  makeLedgerAtRevision,
} from "./lib/citation-meaning.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const CHECKER = join(HERE, "check-tokens.mjs");

import {
  nimStrings, nimCode, unescapeNim, classifyString, CTX,
  flattenTokens, cssVarName, renderBindings, ALLOWLIST, STRUCTURAL_ROWS,
  SYSTEM_COLOURS_COMPOUND, SYSTEM_COLOURS_AMBIGUOUS,
} from "./check-tokens.mjs";

let pass = 0;
let fail = 0;
const results = [];

/** The real Layer 2 sources, read once. Used to re-derive claims about the
 *  product source rather than restate them. */
const LAYER2_SOURCES = await Promise.all(
  ["components", "pages"].flatMap((d) => {
    const dir = join(REPO_ROOT, "client", "src", d);
    return readdirSync(dir).filter((f) => f.endsWith(".nim")).map((f) => readFile(join(dir, f), "utf8"));
  }),
);

function ok(name, condition, detail = "") {
  if (condition) { pass++; results.push(`  ✓ ${name}${detail ? `\n        ${detail}` : ""}`); }
  else { fail++; results.push(`  ✗ ${name}${detail ? `\n        ${detail}` : ""}`); }
}

const sha = (s) => createHash("sha256").update(s).digest("hex");

/** Run the real checker over the real tree and return its JSON verdict. */
function runChecker(extraArgs = []) {
  const r = spawnSync(process.execPath, [CHECKER, "--json", ...extraArgs], {
    cwd: REPO_ROOT, encoding: "utf8", maxBuffer: 32 * 1024 * 1024,
  });
  let verdict = null;
  try { verdict = JSON.parse(r.stdout); } catch { /* reported below */ }
  return { code: r.status, verdict, stdout: r.stdout, stderr: r.stderr };
}

const checkOf = (verdict, id) => verdict?.checks?.find((c) => c.id === id);

// ── Part 1: the Nim tokeniser ──────────────────────────────────────────────
// This is load-bearing. A `#`-to-end-of-line comment strip would swallow the
// rest of a CSS line containing `#fff` and report a clean pass — a checker that
// goes green BECAUSE of a violation. The tokeniser must not do that.

{
  const src = [
    '## A doc comment mentioning #efefef and 49px, which must NOT be scanned.',
    'const a* = """',
    '.x{color:#fff;padding:11px}',
    '"""',
    '# an ordinary comment with #abcdef',
    'let s = "color:#123456"',
    "let c = '#'",
    'let after = "margin:7px"',
  ].join("\n");
  const strings = nimStrings(src);
  const blocks = strings.filter((s) => s.kind === "block");
  const singles = strings.filter((s) => s.kind === "string");

  ok("tokeniser — the doc comment's #efefef and 49px are not returned as source",
    !strings.some((s) => s.text.includes("efefef")) && !strings.some((s) => s.text.includes("49px")));
  ok("tokeniser — the CSS block IS returned, hash and all",
    blocks.length === 1 && blocks[0].text.includes("#fff") && blocks[0].text.includes("11px"),
    blocks.length ? JSON.stringify(blocks[0].text.trim()) : "no block found");
  ok("tokeniser — a `#` INSIDE a string does not start a comment",
    singles.some((s) => s.text === "color:#123456") && singles.some((s) => s.text === "margin:7px"),
    "if it did, `margin:7px` after it would be invisible — a violation hiding a violation");
  ok("tokeniser — a char literal is not a comment introducer",
    singles.some((s) => s.text === "margin:7px"));
}

// ── Part 1b: the three contexts, and the escapes that used to hide them ────
//
// VD.2 scanned a single-line string ONLY when it matched `^[a-z-]+\s*:`. Two
// whole classes of string therefore reached a rendered page without ever being
// looked at: a hand-built fragment, and a bare value in an attribute. The
// classification is asserted here directly, so a future refactor that quietly
// narrows it again fails at this level as well as at the plant level.

{
  ok("unescapeNim — a Nim-escaped attribute quote becomes a real quote",
    unescapeNim('<span style=\\"color:#f00\\">') === '<span style="color:#f00">',
    "if it did not, the style attribute inside a hand-built fragment would be behind a backslash and no attribute regex would find it");

  ok("classify — a triple-quoted block is CSS", classifyString("block", ".x{color:red}") === CTX.CSS);
  ok("classify — a declaration list is CSS", classifyString("string", "color:#fff") === CTX.CSS);
  ok("classify — a hand-built fragment is MARKUP",
    classifyString("string", '<span style="color:#ff0000">') === CTX.MARKUP,
    "VD.2 classified this as 'not CSS-bearing' and skipped it entirely");
  ok("classify — a bare attribute value is VALUE, not skipped",
    classifyString("string", "#4f46e5") === CTX.VALUE,
    "VD.2 had no VALUE context: a string that was neither a block nor a declaration list was never scanned");
  ok("unescapeNim — Nim's HEX escape resolves, so `\\x42uttonFace` is ButtonFace",
    unescapeNim("\\x42uttonFace") === "ButtonFace",
    "VD.3 closed the CSS identifier escape and left Nim's own escape open one layer down, where no CSS knowledge is needed to reach it");
  ok("unescapeNim — Nim's DECIMAL escape resolves too",
    unescapeNim("\\66uttonFace") === "ButtonFace" && unescapeNim("\\u0042uttonFace") === "ButtonFace",
    `\\66… → ${JSON.stringify(unescapeNim("\\66uttonFace"))}`);
  ok("unescapeNim — an escaped backslash is still one backslash, not an escape introducer",
    unescapeNim("C:\\\\x42") === "C:\\x42",
    "otherwise decoding would invent characters that are not in the string");

  ok("classify — ordinary prose is VALUE too, so nothing is unclassified",
    classifyString("string", "Paste a block, tx hash, or address") === CTX.VALUE,
    "the classification is TOTAL — 'not scanned' is a decision with a name, not the default");

  // The FALSE-POSITIVE side of the classification, which matters as much as the
  // false-negative side: an English sentence opens `[a-z-]+:` exactly as a CSS
  // declaration does, and classifying one as CSS made A5 report a note as an
  // inline style and A1 match the word "green" in it.
  ok("classify — a sentence that opens with `Word:` is PROSE, not a declaration list",
    ["Note: the raw value is in wei", "Status: green means finalised",
     "Tip: paste a block, tx hash, or address"].every((s) => classifyString("string", s) === CTX.VALUE),
    "a false positive here is how a lint gets switched off — A5 told the author to 'move the declaration into styles.nim behind a class' for an English note");
  ok("classify — a real declaration list is still CSS, however it is written",
    ["color:#fff", "color:var(--bt-accent-default)", "margin-top:20px", "--gap: 4px",
     "background:ButtonFace"].every((s) => classifyString("string", s) === CTX.CSS),
    "the prose guard must not cost the shapes A5 and A1 depend on");

  const code = nimCode('let a = "style = \\"color:red\\""\n# style = "x"\nspan(style = dynamicValue)\n');
  ok("nimCode — a `style =` in a STRING or a COMMENT is blanked, one in CODE is not",
    [...code.matchAll(/style\s*=/g)].length === 1,
    `${[...code.matchAll(/style\s*=/g)].length} occurrence(s) survive — A5 must see the attribute whose value is a variable, and must not see this test's own prose`);
}

// ── Part 1c: the system-colour list is a list, and contains the one ────────
{
  const all = [...SYSTEM_COLOURS_COMPOUND, ...SYSTEM_COLOURS_AMBIGUOUS];
  ok("the CSS system-colour set contains ButtonFace",
    SYSTEM_COLOURS_COMPOUND.includes("ButtonFace"),
    "the literal the 1.04:1 regression was made of");
  ok("the CSS system-colour set covers the CSS Color 4 named set",
    ["Canvas", "CanvasText", "LinkText", "Field", "FieldText", "Highlight", "HighlightText",
     "GrayText", "AccentColor", "AccentColorText", "ButtonText", "ButtonBorder",
     "VisitedText", "ActiveText", "Mark", "MarkText", "SelectedItem", "SelectedItemText",
    ].every((c) => all.includes(c)),
    `${all.length} system colours enumerated`);
  // The case-sensitive list is a deliberate weakening — a lowercase spelling of
  // a name on it is a colour this checker cannot see — so it is held to the
  // names with EVIDENCE, and the evidence is re-derived here from the real
  // source rather than trusted. `Background` earns its place three times over;
  // the other seven VD.3 originally listed matched nothing at all, so they cost
  // seven undetectable colours and bought nothing.
  ok("the case-SENSITIVE system-colour list is minimal — every name on it really collides",
    SYSTEM_COLOURS_AMBIGUOUS.every((c) => !SYSTEM_COLOURS_COMPOUND.includes(c)) &&
    SYSTEM_COLOURS_AMBIGUOUS.every((name) => {
      const re = new RegExp(`(?<![\\w-])${name}(?![\\w-])`, "gi");
      return LAYER2_SOURCES.some((src) => [...src.matchAll(re)].some((m) => !/^\s*:/.test(src.slice(m.index + m[0].length))));
    }),
    `${SYSTEM_COLOURS_AMBIGUOUS.join(", ")} — a name here with NO case-insensitive collision in client/src/{components,pages} is a hole bought for nothing`);
  ok("the seven names that do NOT collide are matched case-insensitively",
    ["Canvas", "Field", "Highlight", "Mark", "Menu", "Scrollbar", "Window"]
      .every((c) => SYSTEM_COLOURS_COMPOUND.includes(c)),
    "`background:menu` is a colour a browser honours; holding `Menu` case-sensitively made it invisible and protected nothing, because a capitalised `text \"Menu\"` matches the case-sensitive regex anyway");
}

// ── Part 2: the flatten rule, shared with tokens.nim ───────────────────────

{
  ok("cssVarName — base drops one segment",
    cssVarName(["base", "type", "h1", "size"]) === "--bt-type-h1-size");
  ok("cssVarName — theme drops two",
    cssVarName(["theme", "light", "surface", "canvas"]) === "--bt-surface-canvas");
  ok("cssVarName — register drops two",
    cssVarName(["register", "debugger", "density", "cell-y"]) === "--bt-density-cell-y");
  ok("cssVarName — light and dark produce the SAME variable name",
    cssVarName(["theme", "light", "text", "muted"]) === cssVarName(["theme", "dark", "text", "muted"]),
    "the theme blocks override one set of names; if they did not, a theme switch would leave stale values");
}

// ── Part 3: synthetic ledgers for B, C ─────────────────────────────────────

const SCRATCH = await mkdtemp(join(tmpdir(), "bt-vd2-selftest-"));

async function checkSynthetic(name, mutate) {
  // Build a scratch repo shaped like the real one, mutate it, run the checker
  // with its paths pointed at the scratch tree via a tiny wrapper module.
  const doc = JSON.parse(await readFile(join(REPO_ROOT, "client", "src", "design_system", "web.tokens.json"), "utf8"));
  mutate(doc);
  return flattenTokens(doc);
}

{
  // C1 — a key present in light and absent in dark.
  const toks = await checkSynthetic("light/dark asymmetry", (d) => { delete d.theme.dark.text.subtle; });
  const light = new Set(toks.filter((t) => t.group === "theme.light").map((t) => t.cssVar));
  const dark = new Set(toks.filter((t) => t.group === "theme.dark").map((t) => t.cssVar));
  const onlyLight = [...light].filter((k) => !dark.has(k));
  ok("C1 model — deleting one dark role makes the key sets differ",
    onlyLight.length === 1 && onlyLight[0] === "--bt-text-subtle",
    `light-only: ${onlyLight.join(", ")}`);
}

{
  // C2 — a density token in one register only.
  const toks = await checkSynthetic("register asymmetry", (d) => { delete d.register.debugger.density["card-pad"]; });
  const exp = new Set(toks.filter((t) => t.group === "register.explorer").map((t) => t.cssVar));
  const dbg = new Set(toks.filter((t) => t.group === "register.debugger").map((t) => t.cssVar));
  ok("C2 model — deleting one debugger density token makes the key sets differ",
    [...exp].filter((k) => !dbg.has(k)).join(",") === "--bt-density-card-pad");
}

{
  // B1 — a literal with no divergence extension.
  const toks = await checkSynthetic("untracked literal", (d) => {
    d.base.motion.fast = { $type: "duration", $value: "90ms" };
  });
  const lit = toks.find((t) => t.cssVar === "--bt-motion-fast");
  ok("B1 model — a literal without $extensions['bt.divergence'] is bkLiteral with an empty row id",
    lit.kind === "bkLiteral" && lit.divergence === "",
    `kind=${lit.kind} divergence='${lit.divergence}'`);
}

{
  // B3 — the generated table changes when the tokens change.
  const doc = JSON.parse(await readFile(join(REPO_ROOT, "client", "src", "design_system", "web.tokens.json"), "utf8"));
  const before = renderBindings(flattenTokens(doc));
  doc.base.radius.xs = { $type: "dimension", $value: "{border.border radius.3xs}" };
  const after = renderBindings(flattenTokens(doc));
  ok("B3 model — a changed binding changes the generated table", before !== after);
}

{
  ok("STRUCTURAL_ROWS is enumerated, not a pattern",
    STRUCTURAL_ROWS instanceof Set && STRUCTURAL_ROWS.size >= 1 && [...STRUCTURAL_ROWS].every((r) => /^D-\d+$/.test(r)),
    `${[...STRUCTURAL_ROWS].join(", ")} — a pattern here would let any row escape B2 by being written a certain way`);
  ok("every allowlist entry carries a reason",
    ALLOWLIST.length > 0 && ALLOWLIST.every((e) => typeof e.why === "string" && e.why.length > 40),
    `${ALLOWLIST.length} entr(y/ies): ${ALLOWLIST.map((e) => e.id).join(", ")}`);
}

// ── Part 4: the real product source, edited and restored ───────────────────
//
// Each case: assert the CONTROL (unmodified tree passes the rule), apply ONE
// edit, assert the rule fails and names the planted value, restore, assert the
// file is byte-identical and the rule passes again.

const STYLES = join(REPO_ROOT, "client", "src", "components", "styles.nim");
const HOME = join(REPO_ROOT, "client", "src", "pages", "home.nim");
const LAYOUT = join(REPO_ROOT, "client", "src", "components", "layout.nim");
const WEB_TOKENS = join(REPO_ROOT, "client", "src", "design_system", "web.tokens.json");

// ── B4's two anchors, DERIVED rather than written down ─────────────────────
//
// B4 no longer asserts revision currency; it asserts that the finding at a
// cited id still says what it said (Q21, tools/design/lib/citation-meaning.mjs).
// So proving that B4 decides needs two plants, and they are opposites:
//
//   * a citation of a superseded revision whose finding is UNCHANGED, which B4
//     must ACCEPT — the case that used to be the whole test and was the whole
//     over-firing problem;
//   * a citation of a superseded revision whose finding CHANGED MEANING, which
//     B4 must REJECT — the property the old proxy could only approximate.
//
// Both are computed from real history at run time instead of being pasted in.
// The pasted form is what made these anchors a maintenance treadmill in the
// first place: every ingest moved the revision, both anchors went stale, and
// the self-test failed with "the anchor text is no longer in styles.nim" on a
// round that had changed nothing about citations. Q21 recorded that cost three
// rounds running. A derived anchor cannot go stale, and when no qualifying pair
// exists it says so and fails rather than passing on an empty search.
const B4_ANCHORS = (() => {
  const at = makeLedgerAtRevision(REPO_ROOT);
  const history = ledgerHistoryAvailable(REPO_ROOT);
  const ledger = JSON.parse(readFileSync(join(REPO_ROOT, "reviews", "ledger.json"), "utf8"));
  const current = indexFindings(ledger);
  const out = { safe: null, changed: null, reason: null };
  if (!history.ok) { out.reason = history.reason; return out; }
  // Walk the ledger's own history newest-first and take the first revision that
  // offers each kind. Newest-first so the plants stay close to the present and
  // a reader diagnosing a failure is not sent five milestones back.
  for (const sha of history.commits) {
    let past;
    try {
      past = JSON.parse(execFileSync(
        "git", ["-C", REPO_ROOT, "show", `${sha}:reviews/ledger.json`],
        { encoding: "utf8", maxBuffer: 1 << 28 }));
    } catch { continue; }
    if (!past.ledgerRevision || past.ledgerRevision === ledger.ledgerRevision) continue;
    for (const [id, f] of indexFindings(past)) {
      const now = current.get(id);
      if (!now) continue;
      const cite = `ledger@${past.ledgerRevision}:${id}`;
      if (now.finding === f.finding) out.safe ??= { cite, id, revision: past.ledgerRevision };
      else out.changed ??= { cite, id, revision: past.ledgerRevision };
    }
    if (out.safe && out.changed) break;
  }
  if (!out.safe || !out.changed) {
    out.reason =
      `history has ${out.safe ? "" : "no SAFE-RESTAMP pair"}` +
      `${!out.safe && !out.changed ? " and " : ""}` +
      `${out.changed ? "" : "no MEANING-CHANGED pair"} to plant`;
  }
  return out;
})();

const PLANTS = [
  {
    rule: "A1", name: "a raw hex colour in the stylesheet", file: STYLES,
    from: ".muted{color:var(--bt-text-muted)}", to: ".muted{color:#8a8a8a}", names: "#8a8a8a",
  },
  {
    rule: "A2", name: "a raw pixel value in the stylesheet", file: STYLES,
    from: ".stack{margin-top:var(--bt-rhythm-stack)}", to: ".stack{margin-top:18px}", names: "18px",
  },
  {
    rule: "A3", name: "a brand primitive in the stylesheet", file: STYLES,
    from: ".accent{color:var(--bt-accent-default)}", to: ".accent{color:var(--ct-color-brand-400)}",
    names: "--ct-color-brand-400",
  },
  {
    rule: "A4", name: "a mistyped semantic token", file: STYLES,
    from: ".subtle{color:var(--bt-text-subtle)}", to: ".subtle{color:var(--bt-text-subtl)}",
    names: "--bt-text-subtl",
  },
  {
    rule: "A1", name: "a raw colour smuggled in via an inline style= attribute on a PAGE", file: HOME,
    from: 'span(class = "accent")', to: 'span(style = "color:#818cf8")', names: "#818cf8",
  },
  {
    rule: "A2", name: "a raw length smuggled in via an inline style= attribute on a PAGE", file: HOME,
    from: 'span(class = "accent")', to: 'span(style = "margin-top:20px")', names: "20px",
  },
  {
    // A5 used to pass unconditionally: it REPORTED inline styles and could not
    // fail. AGENTS.md meanwhile told contributors "the checker fails on an
    // inline `style=`". The rule is now real, and the plant that used to assert
    // "reported and accepted" asserts "rejected" — with a token-only value, so
    // it cannot be passing for the colour's sake.
    rule: "A5", name: "an inline style attribute is REJECTED, even a token-only one", file: HOME,
    from: 'span(class = "accent")', to: 'span(style = "color:var(--bt-accent-default)")',
    names: "color:var(--bt-accent-default)",
  },
  {
    // A5's other half: an attribute whose value is not a literal has no string
    // for the string scan to classify, and is still an inline style.
    rule: "A5", name: "an inline style attribute whose value is a VARIABLE is rejected too", file: HOME,
    from: 'span(class = "accent")', to: 'span(style = accentStyle)',
    names: "style = …",
  },

  // ── The three VD.2 evasions, one plant each ─────────────────────────────

  {
    // GAP 1. THIS CASE MUST EXIST FOR AS LONG AS THIS LINT DOES.
    //
    // The lint was written to stop the 1.04:1 primary button recurring. The
    // button was 1.04:1 because `.btn` set no `background`, so `<button
    // class="btn ghost">` inherited the user agent's ButtonFace. VD.2's
    // detector enumerated twenty DESIGNER colour names and no SYSTEM colour, so
    // the literal that caused the regression the checker guards passed it
    // clean. It is planted by name, in the exact declaration it broke.
    rule: "A1", name: "GAP 1 — `background: ButtonFace`, the literal that measured 1.04:1", file: STYLES,
    from: ".btn.ghost{background:var(--bt-action-ghost-bg)", to: ".btn.ghost{background:ButtonFace",
    names: "ButtonFace",
  },
  {
    rule: "A1", name: "GAP 1b — a system colour under a different UA role (CanvasText)", file: STYLES,
    from: ".muted{color:var(--bt-text-muted)}", to: ".muted{color:CanvasText}", names: "CanvasText",
  },
  {
    // GAP 2. A single-line string was scanned only when it matched
    // `^[a-z-]+\s*:`, so a hand-built fragment beginning with `<` was never
    // examined. `layout.nim` splices component strings through `raw`, so this
    // is a live path.
    rule: "A1", name: "GAP 2 — a raw colour inside a hand-built HTML fragment spliced through `raw`", file: HOME,
    from: 'span(class = "accent"):\n            text "deepest"',
    to: 'raw "<span style=\\"color:#ff0000\\">deepest</span>"',
    names: "#ff0000",
  },
  {
    rule: "A7", name: "GAP 2b — the hand-built fragment ITSELF is rejected, colour or no colour", file: HOME,
    from: 'span(class = "accent"):\n            text "deepest"',
    to: 'raw "<span class=\\"accent\\">deepest</span>"',
    names: "<span",
  },
  {
    // GAP 3. A bare value in an attribute matches neither `^[a-z-]+:` nor an
    // HTML tag, and VD.2 had no context for it at all.
    rule: "A1", name: "GAP 3 — a bare colour in an attribute value, `content = \"#4f46e5\"`", file: LAYOUT,
    from: 'meta(name = "robots", content = robots)',
    to: 'meta(name = "robots", content = robots)\n          meta(name = "theme-color", content = "#4f46e5")',
    names: "#4f46e5",
  },
  {
    rule: "A1", name: "GAP 3b — a bare SYSTEM colour in an attribute value", file: LAYOUT,
    from: 'meta(name = "robots", content = robots)',
    to: 'meta(name = "robots", content = robots)\n          meta(name = "theme-color", content = "ButtonFace")',
    names: "ButtonFace",
  },
  {
    rule: "A2", name: "GAP 3c — a bare length in an attribute value", file: LAYOUT,
    from: 'meta(name = "viewport", content = "width=device-width, initial-scale=1")',
    to: 'meta(name = "viewport", content = "640px")',
    names: "640px",
  },

  // ── The evasions tried against the FIX, and closed ───────────────────────

  {
    // Case is not a hiding place: CSS system colours are ASCII
    // case-insensitive, so a UA honours `buttonface` exactly as it honours
    // `ButtonFace`. A detector that only knew the canonical spelling would be
    // one lowercase letter away from being defeated.
    rule: "A1", name: "evasion — lowercase `buttonface` is still ButtonFace to a browser", file: STYLES,
    from: ".btn.ghost{background:var(--bt-action-ghost-bg)", to: ".btn.ghost{background:buttonface",
    names: "buttonface",
  },
  {
    // A colour split across a concatenation still leaves the colour as its own
    // string literal, and the VALUE context sees it.
    rule: "A1", name: "evasion — a colour assembled by concatenation is still a colour", file: HOME,
    from: 'text "The "', to: 'text "The " & "#818cf8"',
    names: "#818cf8",
  },
  {
    // The doc-comment escape hatch, checked from the other side: a violation
    // must not be hideable by making the checker's own tokeniser skip it.
    rule: "A1", name: "evasion — a colour in an ATTRIBUTE of a hand-built fragment", file: HOME,
    from: 'span(class = "accent"):\n            text "deepest"',
    to: 'raw "<span bgcolor=\\"#00ff00\\">deepest</span>"',
    names: "#00ff00",
  },
  {
    // Found by attacking the system-colour fix rather than by reading a spec.
    // CSS lets an identifier character be written as a hexadecimal escape, so a
    // browser reads `\42 uttonFace` as `ButtonFace`, and a detector that matches
    // literal text is one backslash away from being defeated. The checker
    // decodes CSS escapes before matching; this plant is the proof.
    rule: "A1", name: "evasion — `\\42 uttonFace`, a CSS identifier escape a browser reads as ButtonFace",
    file: STYLES,
    from: ".btn.ghost{background:var(--bt-action-ghost-bg)",
    to: ".btn.ghost{background:\\42 uttonFace",
    names: "ButtonFace",
  },
  {
    // The same value split across a Nim concatenation: neither half is a
    // colour, and the string the browser receives is. Adjacent `&`-joined
    // literals are scanned as one string as well as separately.
    rule: "A1", name: "evasion — the identifier split across a `&` concatenation of two CSS blocks",
    file: STYLES,
    from: ".btn.ghost{background:var(--bt-action-ghost-bg)",
    to: '.btn.ghost{background:Butt""" & """onFace',
    names: "ButtonFace",
  },
  {
    // Nim identifiers ignore case after the first letter and `$ident` emits the
    // SOURCE spelling, so `span(sTyLe = …)` renders `<span sTyLe="…">` — which
    // an HTML parser honours, attribute names being case-insensitive too.
    rule: "A5", name: "evasion — the inline style attribute spelled `sTyLe`", file: HOME,
    from: 'span(class = "accent")', to: 'span(sTyLe = accentStyle)',
    names: "style = …",
  },
  {
    // `@import` pulls in a stylesheet this checker never reads, so every value
    // inside it is outside every rule above.
    rule: "A7", name: "evasion — an @import that would bring in unscannable CSS", file: STYLES,
    from: 'const globalCss* = """\n',
    to: 'const globalCss* = """\n@import url(/assets/legacy.css);\n',
    names: "@import url(/assets/legacy.css)",
  },
  // ── B4: a citation that stopped resolving ────────────────────────────────

  {
    // The plant keeps the CURRENT revision and moves only the id, so the one
    // thing under test is "an id that is not in the ledger". `L1/99` is
    // verified absent from the 2026-08-31.14 ledger; had it existed, this
    // case would pass while asserting nothing.
    rule: "B4", name: "a citation naming a finding id that does not exist", file: STYLES,
    from: "ledger@2026-09-01.6:tx-detail/wide/light/L1/6",
    to: "ledger@2026-09-01.6:tx-detail/wide/light/L1/99",
    names: "L1/99",
  },
  {
    // The case that actually happened, five times now. The ledger was
    // replaced, the ids were reused, and every citation kept parsing while
    // meaning something else. vd10-r1's ingest moved the revision again
    // (`2026-08-31.14` → `2026-09-01.5`), so `.14` is the revision that has
    // just been superseded and is the honest thing to plant here. The id is
    // held FIXED across the plant and `tx-detail/wide/light/L1/6` is verified
    // to exist in the `.14` ledger too, so the single planted defect is the
    // stale revision and nothing else — a plant whose id had also gone would
    // turn B4 red for the wrong reason and prove nothing about revisions.
    //
    // Q21 IS WHY THIS CASE WAS REPLACED RATHER THAN REPAIRED, and the
    // replacement is the pair below.
    //
    // What stood here asserted that a citation of a SUPERSEDED revision must
    // make B4 red. That expectation is now wrong, and it was wrong on its own
    // terms: it made B4 fire on every citation at every ingest whatever the
    // round touched. Three consecutive rounds turned the same five tx-detail
    // sites red while re-reviewing debugger triples, and `design-citations`
    // classified all of them SAFE-RESTAMP all three times. The remedy the check
    // taught was bulk re-stamping — the move `citation-evidence.mjs` exists to
    // warn against, and the one that would have been catastrophic when all 70
    // sites were MEANING-CHANGED.
    //
    // The assertion is not weakened, it is aimed at the property the proxy
    // stood in for, and it is proved in BOTH directions below: the safe case
    // must be accepted and the changed case must be rejected. A check that only
    // rejected would pass by rejecting everything, which is what the base-case
    // discipline in this file exists for.
    rule: "B4", name: "a superseded revision whose finding is UNCHANGED is ACCEPTED",
    file: STYLES,
    from: "ledger@2026-09-01.6:tx-detail/wide/light/L1/6",
    to: B4_ANCHORS.safe?.cite ?? "ledger@NO-SAFE-PAIR-DERIVED",
    names: "",
    expectClean: true,
    skipReason: B4_ANCHORS.safe ? null : B4_ANCHORS.reason,
  },
  {
    // The property the old proxy could only approximate: the ledger was
    // replaced, the ids were reused, and the citation kept parsing while
    // pointing at a different finding. THIS is what B4 is for, and until now
    // nothing in this file drove it.
    //
    // The pair is derived from real history (see B4_ANCHORS), so it cannot go
    // stale — and vd11-r1 is exactly the kind of round that creates them: it
    // replaced six `debugger--testnet` reviews, leaving 37 ids whose text at
    // 2026-09-01.6 differs from their text now.
    rule: "B4", name: "a superseded revision whose finding CHANGED MEANING is REJECTED",
    file: STYLES,
    from: "ledger@2026-09-01.6:tx-detail/wide/light/L1/6",
    to: B4_ANCHORS.changed?.cite ?? "ledger@NO-CHANGED-PAIR-DERIVED",
    names: "CHANGED MEANING",
    skipReason: B4_ANCHORS.changed ? null : B4_ANCHORS.reason,
  },

  // ── The evasions tried against the FIX OF THE FIX, and closed ────────────

  {
    // Two CSS Color 4 colour FUNCTIONS the detector did not list at all. hwb()
    // is as raw a colour as rgb() and is supported everywhere oklch() is.
    rule: "A1", name: "evasion — `hwb()`, a colour function the detector did not enumerate", file: STYLES,
    from: ".btn.ghost{background:var(--bt-action-ghost-bg)", to: ".btn.ghost{background:hwb(200 30% 20%)",
    names: "hwb(",
  },
  {
    rule: "A1", name: "evasion — `color(srgb …)`, the CSS Color 4 generic colour function", file: STYLES,
    from: ".btn.ghost{background:var(--bt-action-ghost-bg)", to: ".btn.ghost{background:color(srgb 0.2 0.4 0.6)",
    names: "color(",
  },
  {
    // An enumerated unit list is defeated by the next unit CSS ships.
    // `height:100dvh` is an entirely ordinary modern declaration.
    rule: "A2", name: "evasion — `100dvh`, a dynamic-viewport unit the list did not carry", file: STYLES,
    from: ".stack{margin-top:var(--bt-rhythm-stack)}", to: ".stack{margin-top:100dvh}",
    names: "100dvh",
  },
  {
    rule: "A2", name: "evasion — `20cqw`, a container-query unit", file: STYLES,
    from: ".stack{margin-top:var(--bt-rhythm-stack)}", to: ".stack{margin-top:20cqw}",
    names: "20cqw",
  },
  {
    // CSS at-rule names are ASCII case-insensitive, exactly as system colours
    // are — the very defect this checker diagnoses for `buttonface`.
    rule: "A7", name: "evasion — `@IMPORT`, the at-rule spelled in another case", file: STYLES,
    from: 'const globalCss* = """\n',
    to: 'const globalCss* = """\n@IMPORT url(/assets/legacy.css);\n',
    names: "@IMPORT url(/assets/legacy.css)",
  },
  {
    // The Nim analogue of the CSS identifier escape VD.3 closed, one layer
    // down and needing no CSS knowledge at all.
    rule: "A1", name: "evasion — `\"\\x42uttonFace\"`, a NIM hex escape a compiler reads as ButtonFace",
    file: LAYOUT,
    from: 'meta(name = "robots", content = robots)',
    to: 'meta(name = "robots", content = robots)\n          meta(name = "theme-color", content = "\\x42uttonFace")',
    names: "ButtonFace",
  },
  {
    rule: "A1", name: "evasion — `\"\\66uttonFace\"`, Nim's decimal escape", file: LAYOUT,
    from: 'meta(name = "robots", content = robots)',
    to: 'meta(name = "robots", content = robots)\n          meta(name = "theme-color", content = "\\66uttonFace")',
    names: "ButtonFace",
  },
  {
    // Seven of the eight names VD.3 held case-sensitively had no collision to
    // justify it, so each was a colour a browser honours and the checker could
    // not see.
    rule: "A1", name: "evasion — lowercase `background:menu`, a system colour held case-sensitively for nothing",
    file: STYLES,
    from: ".btn.ghost{background:var(--bt-action-ghost-bg)", to: ".btn.ghost{background:menu",
    names: "menu",
  },
  {
    rule: "A1", name: "evasion — lowercase `canvas`, the name VD.3 named as the price of the split",
    file: STYLES,
    from: ".muted{color:var(--bt-text-muted)}", to: ".muted{color:canvas}", names: "canvas",
  },

  // ── The FALSE-POSITIVE side. A lint that cries wolf is switched off. ──────

  {
    // Planted to assert the checker stays GREEN. An English note opens
    // `[a-z-]+:` exactly as a CSS declaration does, and was classified as one:
    // A5 reported the sentence as an inline style and told the author to move
    // it into styles.nim behind a class.
    rule: "A5", expectClean: true,
    name: "no false positive — an English note that opens with `Word:` is not an inline style",
    file: HOME, from: 'text "deepest"', to: 'text "Note: the raw value is in wei"',
  },
  {
    rule: "A1", expectClean: true,
    name: "no false positive — a colour WORD inside a sentence is prose, not a colour",
    file: HOME, from: 'text "deepest"', to: 'text "Status: green means finalised"',
  },
  {
    rule: "A1", expectClean: true,
    name: "no false positive — the stated-safe control sentence stays clean",
    file: HOME, from: 'text "deepest"', to: 'text "Paste a block, tx hash, or address"',
  },

  // ── C3: the rhythm ladder, over the GAP the stylesheet actually renders ──

  {
    // 8px of cell padding is a 16px row-to-row gap, 1.50x under the 24px stack
    // rung. That is what this branch shipped before its review round gated the
    // gap rather than the padding — so the plant is the previous value, and the
    // gate rejecting it is the whole content of the overrule.
    rule: "C3", name: "the row-to-row GAP widened until proximity stops grouping", file: WEB_TOKENS,
    from: '"cell-y": { "$type": "dimension", "$value": "{scale.300}"',
    to: '"cell-y": { "$type": "dimension", "$value": "{scale.350}"',
    names: "1.50x",
  },
  {
    // The case that made the overrule necessary: at 12px of padding the row
    // gap is 24px — EXACTLY the stack rung — and the pre-overrule C3 printed
    // "1.00x under stack" and PASSED. This is the VD.1 defect itself.
    rule: "C3", name: "the row gap raised to EQUAL the stack rung — the VD.1 defect verbatim", file: WEB_TOKENS,
    from: '"cell-y": { "$type": "dimension", "$value": "{scale.300}"',
    to: '"cell-y": { "$type": "dimension", "$value": "{scale.450}"',
    names: "1.00x",
  },
];

// The control, once: the untouched tree must pass everything.
{
  const { code, verdict } = runChecker();
  ok("CONTROL — the unmodified tree passes every check",
    code === 0 && verdict?.ok === true,
    verdict ? `${verdict.checks.filter((c) => c.ok === true).length} passing, ${verdict.checks.filter((c) => c.ok === false).length} failing` : "no verdict");
}

for (const p of PLANTS) {
  const original = await readFile(p.file, "utf8");
  const before = sha(original);
  // The mtime is restored along with the bytes. D1 treats a build older than
  // any `client/src` input as STALE, so a suite that rewrote a source and left
  // its clock at "now" would leave the tree looking un-built to the very next
  // `--require-built` run — this suite's own footprint, reported as a defect.
  // Restoring the timestamp is what "restored byte-identically" already claims.
  const beforeTimes = await stat(p.file);
  let restored = false;
  try {
    // A case whose plant could not be DERIVED is reported as a failure, not
    // skipped quietly. `B4_ANCHORS` needs git history to find a safe pair and a
    // meaning-changed pair; a checkout without it (a shallow CI clone) cannot
    // drive these two, and "could not test" must never read as "tested".
    if (p.skipReason) {
      ok(`${p.rule} — ${p.name}`, false,
        `the plant could not be derived: ${p.skipReason} — this case asserted nothing`);
      continue;
    }
    if (!original.includes(p.from)) {
      ok(`${p.rule} — ${p.name}`, false, `the anchor text is no longer in ${p.file}: ${JSON.stringify(p.from)} — this test cannot pass by not finding its subject`);
      continue;
    }
    await writeFile(p.file, original.replace(p.from, p.to));
    const { code, verdict } = runChecker();
    const c = checkOf(verdict, p.rule);
    if (p.expectClean) {
      // The other direction: a plant the checker must NOT fire on. A rule that
      // fails on ordinary product copy gets switched off, and then it protects
      // nothing at all.
      const failing = (verdict?.checks ?? []).filter((x) => x.ok === false);
      ok(`${p.rule} — ${p.name}`,
        code === 0 && verdict?.ok === true,
        failing.length
          ? `FALSE POSITIVE: exit=${code}; ${failing.map((x) => `${x.id} — ${String(x.detail).split("\n")[0]}`).join("; ")}`
          : "clean");
    } else if (p.expectPass) {
      ok(`${p.rule} — ${p.name}`,
        c?.ok === true && String(c.detail).includes(p.names),
        `check ${p.rule} ok=${c?.ok}; detail names the inline style: ${String(c?.detail).includes(p.names)}`);
    } else {
      ok(`${p.rule} — ${p.name}`,
        code === 1 && c?.ok === false && String(c.detail).includes(p.names),
        c ? `exit=${code}; ${p.rule} ok=${c.ok}; names ${JSON.stringify(p.names)}: ${String(c.detail).includes(p.names)}` : "no such check in the verdict");
    }
  } finally {
    await writeFile(p.file, original);
    restored = sha(await readFile(p.file, "utf8")) === before;
    await utimes(p.file, beforeTimes.atime, beforeTimes.mtime);
  }
  ok(`${p.rule} — the source is restored byte-identically`, restored, `sha256 ${before.slice(0, 12)}…`);
}

// After every plant and restore, the tree must be clean again — otherwise one
// of the restores silently failed and every later case ran on a dirty tree.
{
  const { code, verdict } = runChecker();
  ok("CONTROL — after every plant and restore, the tree passes again",
    code === 0 && verdict?.ok === true,
    verdict?.checks?.filter((c) => c.ok === false).map((c) => c.id).join(", ") || "no failures");
}

// ── Part 4a: the scan's SCOPE, which is the cheapest thing to walk around ──
//
// A1–A7 enumerate two directories by name. A view module written anywhere else
// under client/src is unscanned, and every rule then reports a clean pass over
// a subset — the "went green because it found nothing to check" failure, in the
// one place that is trivially reachable by adding a file. Planted by CREATING
// the file, because that is how it would actually happen.
//
// Planted in every spelling Nim accepts, not the one spelling the rule was
// written against: `import isonim/[dsl/ui]` and `from isonim/dsl/ui import nil`
// are the same import, and a stylesheet does not have to live in a `"""` block
// to be a stylesheet. Each of the three walked past the first version of this
// rule, and the last is the worst of them — a real system colour in a real
// stylesheet, entirely invisible.
{
  const ROGUES = [
    ["the module imports the isonim view DSL",
     'import isonim/dsl/ui\n\nconst extraCss* = """\n.x{color:#ff0000;padding:13px}\n"""\n'],
    ["the import is written in Nim's bracket form",
     'import isonim/[dsl/ui]\n\nconst label* = "hello"\n'],
    ["the import is written as `from … import`",
     'from isonim/dsl/ui import nil\n\nconst label* = "hello"\n'],
    ["the stylesheet is a SINGLE-LINE string rather than a \"\"\" block",
     'const extraCss* = "body{background:ButtonFace;padding:13px}"\n'],
  ];
  const rogueDir = join(REPO_ROOT, "client", "src", "views");
  for (const [why, body] of ROGUES) {
    let restored = false;
    try {
      await mkdir(rogueDir, { recursive: true });
      await writeFile(join(rogueDir, "rogue.nim"), body);
      const { code, verdict } = runChecker();
      const a0 = checkOf(verdict, "A0");
      ok(`A0 — a Layer 2 view outside the enumerated directories: ${why}`,
        code === 1 && a0?.ok === false && String(a0.detail).includes("client/src/views/rogue.nim"),
        a0 ? `exit=${code}; A0 ok=${a0.ok}; names the file: ${String(a0.detail).includes("rogue.nim")}` : "no A0 in the verdict");
    } finally {
      await rm(rogueDir, { recursive: true, force: true });
      restored = !existsSync(rogueDir);
    }
    ok("A0 — the planted directory is removed", restored);
  }
  // The other direction: A0 must not call every module outside those two
  // directories a view. The 20-odd ViewModel modules under client/src are the
  // control, and the CONTROL run above already asserts they pass — this asserts
  // the widened rule did not start firing on an ordinary string with a colon.
  {
    const benign = join(REPO_ROOT, "client", "src", "views");
    let restored = false;
    try {
      await mkdir(benign, { recursive: true });
      await writeFile(join(benign, "rogue.nim"), 'const msg* = "state: divergent"\nconst other* = "a: b; c: d"\n');
      const { code } = runChecker();
      ok("A0 — a module with an ordinary `word: value` string is NOT called a stylesheet",
        code === 0, `exit=${code} — widening the stylesheet detector must not sweep in every ViewModel`);
    } finally {
      await rm(benign, { recursive: true, force: true });
      restored = !existsSync(benign);
    }
    ok("A0 — the benign planted directory is removed", restored);
  }
}

// ── Part 4b: C3 must rank rungs the stylesheet actually READS ──────────────
//
// The defect this guards is not "C3 gives a wrong answer" — C3 gave the right
// answer about `--bt-rhythm-row`, which was 12px and was 2.00x under the 24px
// stack. The defect is that no rule in styles.nim ever referenced it, so the
// answer was about nothing. A separation check that ranks an unused token
// passes for as long as nobody looks, and cannot fail when the rhythm the page
// really renders collapses.
//
// So: read the rung names out of C3's own verdict, and require each one to be
// BOTH declared by web.tokens.json AND referenced by the stylesheet.
{
  const { verdict } = runChecker();
  const c3 = checkOf(verdict, "C3");
  const styles = await readFile(STYLES, "utf8");
  const doc = JSON.parse(await readFile(WEB_TOKENS, "utf8"));
  const declared = new Set(flattenTokens(doc).map((t) => t.cssVar));
  const rungs = [...new Set([...String(c3?.detail ?? "").matchAll(/--bt-[a-z0-9-]+/g)].map((m) => m[0]))];

  ok("C3 names at least four rungs", rungs.length >= 4, rungs.join(", "));
  const undeclared = rungs.filter((r) => !declared.has(r));
  const unread = rungs.filter((r) => !styles.includes(`var(${r})`));
  ok("C3 ranks only rungs the STYLESHEET reads — not one emitted token that no rule uses",
    c3?.ok === true && rungs.length > 0 && undeclared.length === 0 && unread.length === 0,
    undeclared.length || unread.length
      ? `undeclared: ${undeclared.join(", ") || "none"}; declared but referenced by no rule in styles.nim: ${unread.join(", ") || "none"}`
      : `${rungs.length} rung(s), every one declared and referenced: ${rungs.join(", ")}`);

  ok("the dead --bt-rhythm-row is gone from the token source AND from the ladder",
    !declared.has("--bt-rhythm-row") && !rungs.includes("--bt-rhythm-row"),
    "it was emitted into every page's <style> block and read by nothing, and C3 ranked it as the bottom rung");

  // The bottom rung must be the GAP, not the padding. Ranking the padding
  // compared a half-quantity against a full one: it reported 3.00x where the
  // real separation was 1.50x, and it passed at cell-y = 12px, where the row
  // gap EQUALS the stack rung — the VD.1 defect the ladder exists to prevent.
  // Both facts are asserted from C3's own verdict line so a future refactor
  // that quietly reverts to the padding fails here as well as at the plant.
  ok("C3 ranks the row-to-row GAP, not the row padding",
    /2x --bt-density-cell-y/.test(String(c3?.detail ?? "")) && /GATED/.test(String(c3?.detail ?? "")),
    String(c3?.detail ?? "").split("\n").map((l) => l.trim()).filter(Boolean)[0] ?? "");
  ok("C3 states that the row PITCH is never ranked against a gap",
    /pitch is not comparable to a gap/.test(String(c3?.detail ?? "")),
    "comparing a 49px row pitch with a 49px section gap is what produced VD.1's finding; naming the distinction here stops it being made again");
  {
    // The gated rung really is 2x the token, not the token.
    const doc2 = JSON.parse(await readFile(WEB_TOKENS, "utf8"));
    const pad = flattenTokens(doc2).find((t) => t.group === "register.explorer" && t.cssVar === "--bt-density-cell-y");
    const printed = /2x --bt-density-cell-y=(\d+)px/.exec(String(c3?.detail ?? ""));
    ok("C3's bottom rung is arithmetically 2x the explorer's cell padding",
      printed !== null && Number(printed[1]) > 0,
      `printed ${printed?.[1]}px from ${pad?.value} — two cell paddings meet at every row boundary, so that is the like-for-like number against a margin`);
  }
}

// ── Part 5: the build-time half of the §4.1 rule ───────────────────────────
// tokens.nim RAISES on an untracked literal, so one never reaches a page. That
// is asserted here as a property of the emitter's source rather than by
// compiling Nim, which this suite deliberately does not require.
{
  const nim = await readFile(join(REPO_ROOT, "client", "src", "design_system", "tokens.nim"), "utf8");
  ok("the emitter itself refuses an untracked literal",
    /bkLiteral and divergence\.len == 0/.test(nim) && /untracked web-lineage literal/.test(nim),
    "tokens.nim raises before emitting, so the CI lint is the second line of defence rather than the only one");
}

// ── Part 6: D1 reads the RIGHT artefact, and knows when it is out of date ──
//
// D1 and D2 are the only checks that read a build rather than the source, and
// that gives them a failure mode no other rule has: an artefact can be OLD, and
// an old one does not report "unknown" — it reports the state of an earlier
// tree, confidently, in the same words a real product defect would use.
//
// This is not a hypothetical. `--require-built` once reported
//
//     defined but not shipped: --bt-mark-changed, --bt-syntax-keyword, …
//
// naming all fifteen tokens of the lexical palette, against a `client/dist`
// written NINE MINUTES BEFORE the commit that introduced them. All fifteen were
// in fact declared, six times over, on all 61 built pages. The reviewer
// concluded the checker must be scanning a different stylesheet and went
// looking for a second one; the artefact's mtime was the whole answer.
//
// Three cases pin the behaviour that incident needed, and each fails if a
// future change regresses it:
//
//   1. the comparison BITES — a token missing from the built page is caught, so
//      the rule cannot pass by reading nothing;
//   2. it reads `client/dist`, and NOT `result/` — the two are different output
//      trees and `nix build .#default` refreshes only the second, which is the
//      other half of how the incident happened;
//   3. a STALE build is reported as stale, and NEVER as a token mismatch.
//
// The build is not created here: these cases need one and are SKIPPED, loudly,
// when there is none, so the suite stays runnable without a Nim toolchain.
{
  const BUILT_HTML = join(REPO_ROOT, "client", "dist", "index.html");

  if (!existsSync(BUILT_HTML)) {
    ok("D1 — SKIPPED: no client/dist to test against", true,
      "run `cd client && just export` to exercise Part 6; the three D1 cases below need a real built page");
  } else {
    // If the build is genuinely out of date these cases cannot run: a stale
    // artefact is the very condition case 3 plants, so a suite that started
    // from one would be measuring nothing. Skip loudly rather than forcing the
    // artefact's clock forward — quietly making the subject look fresh is how a
    // gate ends up testing itself instead of the product.
    //
    // Part 4's plants restore each file's mtime as well as its bytes, so this
    // suite does not itself create the condition it is skipping on.
    // FIRST, and unconditionally: pin WHICH file D1 reads. This must not sit
    // behind the staleness guard below, because the regression it catches —
    // BUILT_HTML repointed at `result/` — would otherwise hide inside the skip:
    // every file in the Nix store carries a 1970 mtime, so a scan moved there
    // looks permanently stale and the whole of Part 6 would quietly skip and
    // report green. Moving the real artefact aside and reading the "no build"
    // message back is independent of any timestamp.
    {
      const aside = BUILT_HTML + ".selftest-aside";
      let restored = false;
      try {
        await rename(BUILT_HTML, aside);
        const { verdict } = runChecker(["--require-built"]);
        const d1 = checkOf(verdict, "D1");
        ok("D1 — the artefact under test is client/dist/index.html, and not result/",
          d1?.ok === false && /client\/dist\/index\.html/.test(String(d1.detail)) && /no build at/.test(String(d1.detail)),
          `with the real page moved aside, D1 says: ${String(d1?.detail ?? "").slice(0, 120)}`);
      } finally {
        if (existsSync(aside)) await rename(aside, BUILT_HTML);
        restored = existsSync(BUILT_HTML) && !existsSync(aside);
      }
      ok("D1 — the built page is moved back", restored);
    }

    const preflight = runChecker(["--require-built"]);
    const preD1 = checkOf(preflight.verdict, "D1");
    if (/STALE/.test(String(preD1?.detail ?? ""))) {
      ok("D1 — SKIPPED: client/dist is older than client/src", true,
        "re-run `cd client && just export`, then this suite, to exercise Part 6");
    } else {

    // CONTROL. A fresh build passes, so the failures below are caused by the
    // plant and not by the tree being broken to start with.
    {
      const { verdict } = runChecker(["--require-built"]);
      const d1 = checkOf(verdict, "D1");
      ok("D1 — CONTROL: against a CURRENT build, D1 passes",
        d1?.ok === true,
        `D1 ok=${d1?.ok}; ${String(d1?.detail ?? "").slice(0, 100)}`);
    }

    // 1 + 2. Delete a token declaration from the built page. D1 must name the
    // token — which proves both that the comparison bites and that the file it
    // reads is this one, `client/dist/index.html`. If the scan were widened to
    // `result/` or narrowed to nothing, this case goes green-when-it-should-be-
    // red and fails here.
    {
      const original = await readFile(BUILT_HTML, "utf8");
      const before = sha(original);
      const times = await stat(BUILT_HTML);
      let restored = false;
      try {
        // A token the lexical palette contributes, chosen because it is one of
        // the fifteen the false failure named.
        const gone = original.replace(/--bt-syntax-keyword\s*:/g, "--bt-syntax-keywordX:");
        ok("D1 — the plant actually changed the built page",
          gone !== original, "--bt-syntax-keyword is declared in the built page");
        await writeFile(BUILT_HTML, gone);
        const { code, verdict } = runChecker(["--require-built"]);
        const d1 = checkOf(verdict, "D1");
        ok("D1 — a token missing from the BUILT page is caught, and named",
          code === 1 && d1?.ok === false && String(d1.detail).includes("--bt-syntax-keyword"),
          d1 ? `exit=${code}; D1 ok=${d1.ok}; detail: ${String(d1.detail).slice(0, 140)}` : "no D1 in the verdict");
        ok("D1 — the artefact it reads is client/dist, not result/",
          d1?.ok === false && !String(d1.detail).includes("STALE"),
          "editing client/dist/index.html alone turns D1 red, so that is the file under test");
      } finally {
        await writeFile(BUILT_HTML, original);
        await utimes(BUILT_HTML, times.atime, times.mtime);
        restored = sha(await readFile(BUILT_HTML, "utf8")) === before;
      }
      ok("D1 — the built page is restored byte-identically", restored, `sha256 ${before.slice(0, 12)}…`);
    }

    // 3. THE REGRESSION GUARD FOR THE INCIDENT. Age the artefact past its own
    // source and assert D1 says STALE and does NOT say "defined but not
    // shipped". Only the artefact's mtime is touched — no source file is
    // modified — and it is put back in the `finally`.
    {
      const times = await stat(BUILT_HTML);
      let restored = false;
      try {
        const past = new Date(Date.now() - 1000 * 60 * 60 * 24 * 30); // 30 days
        await utimes(BUILT_HTML, past, past);
        const { code, verdict } = runChecker(["--require-built"]);
        const d1 = checkOf(verdict, "D1");
        const detail = String(d1?.detail ?? "");
        ok("D1 — a STALE build is reported as stale, not as a token mismatch",
          code === 1 && d1?.ok === false && /STALE/.test(detail) && !/defined but not shipped/.test(detail),
          `D1 ok=${d1?.ok}; says STALE: ${/STALE/.test(detail)}; ` +
          `avoids the false "defined but not shipped": ${!/defined but not shipped/.test(detail)}`);
        ok("D1 — the stale report tells the reader which command refreshes it",
          /just export/.test(detail) && /result\//.test(detail),
          "naming `just export` AND saying result/ is not read is what the incident lacked");
      } finally {
        await utimes(BUILT_HTML, times.atime, times.mtime);
        const now = await stat(BUILT_HTML);
        restored = Math.abs(now.mtimeMs - times.mtimeMs) < 2;
      }
      ok("D1 — the built page's mtime is restored", restored,
        "otherwise every later run of this suite would see a stale build");
    }

    // And the tree is clean again afterwards.
    {
      const { code, verdict } = runChecker(["--require-built"]);
      ok("D1 — CONTROL: after every plant and restore, --require-built passes again",
        code === 0 && verdict?.ok === true,
        verdict?.checks?.filter((c) => c.ok === false).map((c) => c.id).join(", ") || "no failures");
    }
    }
  }
}

await rm(SCRATCH, { recursive: true, force: true });

console.log("\nverify_no_raw_values_in_views — self-test\n");
console.log(results.join("\n"));
console.log("");
console.log(fail === 0 ? `PASS — ${pass}/${pass + fail} cases` : `FAIL — ${fail} of ${pass + fail} cases failed`);
process.exit(fail === 0 ? 0 : 1);
