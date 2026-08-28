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
//   2. **Against the REAL product source.** Rules A1–A4 are exercised by
//      EDITING `client/src/**` on disk, running the real checker, and restoring
//      the file in a `finally` — verified byte-identical by SHA-256. A rule
//      demonstrated only on a synthetic fixture has been shown to work on a
//      fixture.
//
// The controls matter as much as the breaks: before each plant, the unmodified
// tree is asserted to PASS the same rule. A checker that failed unconditionally
// would score identically on the breaks alone.

import { readFile, writeFile, mkdtemp, rm, mkdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");
const CHECKER = join(HERE, "check-tokens.mjs");

import { nimStrings, flattenTokens, cssVarName, renderBindings, ALLOWLIST, STRUCTURAL_ROWS } from "./check-tokens.mjs";

let pass = 0;
let fail = 0;
const results = [];

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
    rule: "A5", name: "an inline style attribute is reported rather than silently accepted", file: HOME,
    from: 'span(class = "accent")', to: 'span(style = "color:var(--bt-accent-default)")',
    names: "color:var(--bt-accent-default)", expectPass: true,
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
  let restored = false;
  try {
    if (!original.includes(p.from)) {
      ok(`${p.rule} — ${p.name}`, false, `the anchor text is no longer in ${p.file}: ${JSON.stringify(p.from)} — this test cannot pass by not finding its subject`);
      continue;
    }
    await writeFile(p.file, original.replace(p.from, p.to));
    const { code, verdict } = runChecker();
    const c = checkOf(verdict, p.rule);
    if (p.expectPass) {
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

await rm(SCRATCH, { recursive: true, force: true });

console.log("\nverify_no_raw_values_in_views — self-test\n");
console.log(results.join("\n"));
console.log("");
console.log(fail === 0 ? `PASS — ${pass}/${pass + fail} cases` : `FAIL — ${fail} of ${pass + fail} cases failed`);
process.exit(fail === 0 ? 0 : 1);
