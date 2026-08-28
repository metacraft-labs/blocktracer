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
// ── The allowlist cannot rot ───────────────────────────────────────────────
//
// Four kinds of literal are legitimately unavoidable in CSS (a breakpoint
// cannot read a custom property; `transparent` is the absence of a colour).
// Each is allowlisted BY PATTERN WITH A REASON, and check A6 fails when an
// allowlist entry stops matching anything — so an exemption written for one
// line cannot quietly become a blanket permission after that line is deleted.

import { readFile, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { readdirSync } from "node:fs";
import { dirname, join, relative, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolvePath(HERE, "..", "..");

export const WEB_TOKENS = join(REPO_ROOT, "client", "src", "design_system", "web.tokens.json");
export const DIVERGENCE_DOC = join(REPO_ROOT, "docs", "DESIGN-DIVERGENCES-WEB.md");
const LAYER2_DIRS = [
  join(REPO_ROOT, "client", "src", "components"),
  join(REPO_ROOT, "client", "src", "pages"),
];
const BUILT_HTML = join(REPO_ROOT, "client", "dist", "index.html");

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
];

// Rows that record WHERE the web lineage lives rather than what it renders.
// They have no literal binding by nature. Enumerated, never pattern-matched:
// a second structural row has to be added here on purpose, and a structural row
// that acquires a literal fails B2 as misfiled.
export const STRUCTURAL_ROWS = new Set(["D-00"]);

// ── Detectors ──────────────────────────────────────────────────────────────

const RAW_COLOUR = [
  { id: "hex", re: /#[0-9a-fA-F]{3,8}\b/g },
  { id: "rgb", re: /\brgba?\s*\(/g },
  { id: "hsl", re: /\bhsla?\s*\(/g },
  { id: "color-mix", re: /\bcolor-mix\s*\(/g },
  { id: "lab-lch-oklch", re: /\bo?k?(lab|lch)\s*\(/g },
  {
    id: "named-colour",
    // The CSS named colours a designer actually reaches for. `transparent` is
    // handled by the allowlist; `inherit`/`currentColor` are inheritance, not
    // colour choices.
    re: /(?<![\w-])(white|black|red|green|blue|grey|gray|silver|navy|teal|olive|maroon|purple|fuchsia|aqua|lime|orange|yellow|pink|brown|cyan|magenta)(?![\w-])/gi,
  },
];

// A length literal: a number followed by a CSS unit. `0` alone is not a design
// value, and unitless numbers (z-index, flex, line-height ratios) are not
// lengths, so neither is matched.
const RAW_LENGTH = /(?<![\w.#-])-?\d*\.?\d+(px|rem|em|ch|ex|vh|vw|vmin|vmax|pt|pc|cm|mm|in)(?![\w-])/g;

const BRAND_PRIMITIVE = [
  { id: "ct-variable", re: /var\(\s*--ct-[a-z0-9-]+\s*\)/g },
  { id: "ct-declaration", re: /--ct-[a-z0-9-]+\s*:/g },
  { id: "dtcg-path", re: /\{colors?\.[a-z0-9.-]+\}/gi },
];

// ── Nim tokenisation: strings in, comments out ─────────────────────────────

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
      out.push({ kind: "block", text: src.slice(i + 3, stop), line: lineOf(i) });
      i = stop + 3;
      continue;
    }
    if (src[i] === '"') {
      let j = i + 1;
      while (j < n && src[j] !== '"') {
        if (src[j] === "\\") j++;
        j++;
      }
      out.push({ kind: "string", text: src.slice(i + 1, j), line: lineOf(i) });
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
      resolved.set(t.cssVar, value);
    }
  }

  // ── A1–A4: the Layer 2 scan ─────────────────────────────────────────────
  const files = [];
  for (const dir of LAYER2_DIRS) {
    for (const f of readdirSync(dir).sort()) {
      if (f.endsWith(".nim")) files.push(join(dir, f));
    }
  }
  if (files.length === 0) {
    // Fail closed: an empty file list is "the subject is absent", not a pass.
    add("A0", "Layer 2 sources located", false, `no .nim sources under ${LAYER2_DIRS.map((d) => relative(REPO_ROOT, d)).join(", ")}`);
  } else {
    add("A0", "Layer 2 sources located", true, `${files.length} file(s): ${files.map((f) => relative(REPO_ROOT, f)).join(", ")}`);
  }

  const allowHits = new Map();
  const rawColours = [];
  const rawLengths = [];
  const primitives = [];
  const danglingRefs = [];
  const inlineStyles = [];
  const usedVars = new Set();
  let scannedBlocks = 0;
  let scannedChars = 0;

  for (const file of files) {
    const rel = relative(REPO_ROOT, file);
    const src = await readFile(file, "utf8");
    for (const s of nimStrings(src)) {
      // A CSS-bearing string is either a `"""…"""` block (the stylesheet) or a
      // single-line string that looks like inline CSS (`prop:value`).
      const isBlock = s.kind === "block";
      const looksInline = !isBlock && /^[a-z-]+\s*:[^:]/i.test(s.text.trim());
      if (!isBlock && !looksInline) continue;
      if (looksInline) inlineStyles.push({ file: rel, line: s.line, text: s.text.trim() });
      scannedBlocks++;

      const body = applyAllowlist(stripCssComments(s.text), allowHits);
      scannedChars += body.length;

      for (const d of RAW_COLOUR) {
        for (const m of body.matchAll(d.re)) {
          rawColours.push({ file: rel, line: s.line + body.slice(0, m.index).split("\n").length - 1, kind: d.id, text: m[0] });
        }
      }
      for (const m of body.matchAll(RAW_LENGTH)) {
        rawLengths.push({ file: rel, line: s.line + body.slice(0, m.index).split("\n").length - 1, text: m[0] });
      }
      for (const d of BRAND_PRIMITIVE) {
        for (const m of body.matchAll(d.re)) {
          primitives.push({ file: rel, line: s.line + body.slice(0, m.index).split("\n").length - 1, kind: d.id, text: m[0] });
        }
      }
      for (const m of body.matchAll(/var\(\s*(--bt-[a-z0-9-]+)/g)) {
        usedVars.add(m[1]);
        if (!declared.has(m[1])) {
          danglingRefs.push({ file: rel, line: s.line + body.slice(0, m.index).split("\n").length - 1, text: m[1] });
        }
      }
    }
  }

  const fmt = (arr, n = 12) =>
    arr.slice(0, n).map((v) => `        ${v.file}:${v.line}  ${v.text}${v.kind ? `  (${v.kind})` : ""}`).join("\n") +
    (arr.length > n ? `\n        … and ${arr.length - n} more` : "");

  add("A1", "no raw colour in a Layer 2 view", rawColours.length === 0,
    rawColours.length ? `${rawColours.length} raw colour value(s):\n${fmt(rawColours)}` :
      `${scannedBlocks} CSS-bearing string(s), ${scannedChars} chars scanned — 0 hex, rgb(), hsl(), color-mix() or named colour`);

  add("A2", "no raw pixel or length value in a Layer 2 view", rawLengths.length === 0,
    rawLengths.length ? `${rawLengths.length} raw length(s):\n${fmt(rawLengths)}` :
      "0 length literals outside the allowlist — every size comes from a --bt-* token");

  add("A3", "no brand primitive in a Layer 2 view", primitives.length === 0,
    primitives.length ? `${primitives.length} brand-primitive reference(s):\n${fmt(primitives)}` :
      "0 references to --ct-* or to a raw DTCG path — the primitive ramp is not emitted, so such a reference is both linted and undefined");

  add("A4", "every semantic token a view references is emitted", danglingRefs.length === 0,
    danglingRefs.length ? `${danglingRefs.length} reference(s) to a --bt-* variable that web.tokens.json does not define:\n${fmt(danglingRefs)}` :
      `${usedVars.size} distinct --bt-* tokens referenced, all declared`);

  // A5: inline style attributes. Not banned outright — a genuinely dynamic
  // value has nowhere else to live — but each must be token-only, which the
  // scan above already enforced, and there should be none in a foundations
  // pass. Reported so a growth in them is visible.
  add("A5", "inline style attributes carry tokens only", true,
    inlineStyles.length === 0 ? "0 inline style strings — every view uses a utility class"
      : `${inlineStyles.length} inline style string(s), all token-only (A1–A4 scanned them):\n${fmt(inlineStyles)}`);

  // A6: the allowlist must not rot.
  const stale = ALLOWLIST.filter((e) => !(allowHits.get(e.id) > 0));
  add("A6", "every allowlist entry still matches something", stale.length === 0,
    stale.length ? `${stale.length} stale exemption(s) — delete them rather than leaving a standing permission: ${stale.map((e) => e.id).join(", ")}`
      : ALLOWLIST.map((e) => `${e.id} x${allowHits.get(e.id)}`).join(", "));

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

  if (!resolved) {
    add("C3", "the rhythm roles are strictly separated", false,
      `the design system is not readable at ${dsDir} (set DESIGN_SYSTEM_SRC), so the rhythm could not be resolved to numbers — this check does not pass by being unable to run`);
  } else {
    const order = ["--bt-rhythm-row", "--bt-rhythm-stack", "--bt-rhythm-group", "--bt-rhythm-section"];
    const vals = order.map((k) => ({ k, v: px(resolved.get(k) ?? "") }));
    const missing = vals.filter((x) => x.v === null);
    let ok = missing.length === 0;
    const problems = missing.map((x) => `${x.k} is not a px value`);
    if (ok) {
      for (let i = 1; i < vals.length; i++) {
        const ratio = vals[i].v / vals[i - 1].v;
        if (ratio < 1.75) {
          ok = false;
          problems.push(`${vals[i].k} (${vals[i].v}px) is only ${ratio.toFixed(2)}x ${vals[i - 1].k} (${vals[i - 1].v}px) — below the 1.75x separation, so proximity stops grouping`);
        }
      }
    }
    add("C3", "the rhythm roles are strictly separated", ok,
      ok ? vals.map((x) => `${x.k.replace("--bt-rhythm-", "")}=${x.v}px`).join(" < ") + "  (each >= 1.75x the one below)"
        : problems.join("; "));
  }

  // ── D: the shipped CSS, when there is one ───────────────────────────────
  if (!existsSync(BUILT_HTML)) {
    const detail = `no build at ${relative(REPO_ROOT, BUILT_HTML)} — run \`cd client && just export\` first. ` +
      `Without --require-built this check is REPORTED AS NOT RUN, never as a pass.`;
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
  A0  Layer 2 sources were found at all. An empty file list FAILS: a check
      that passes because its subject is absent is the failure mode this
      project has hit three times.
  A1  No raw colour — hex, rgb(), hsl(), color-mix(), lab/lch, or a CSS named
      colour — in client/src/{components,pages}/*.nim.
  A2  No raw length. A number with a CSS unit is a design decision and belongs
      in web.tokens.json. Bare 0 and unitless numbers are not lengths.
  A3  No brand primitive: no var(--ct-*), no --ct-* declaration, no raw DTCG
      path. VD.2 stopped emitting the primitive ramp, so such a reference is
      undefined as well as forbidden.
  A4  Every var(--bt-X) a view uses is defined by web.tokens.json. This is
      what makes A1-A3 constructive rather than merely prohibitive.
  A5  Inline style attributes are reported and scanned by A1-A4.
  A6  Every allowlist entry still matches something. An exemption whose
      subject was deleted is a standing permission and fails here.

Design-System.md §4.1 — the divergence rule
  B1  Every bkLiteral names a row in docs/DESIGN-DIVERGENCES-WEB.md.
  B2  Every row corresponds to at least one literal.
  B3  The generated implemented-binding table matches web.tokens.json.

The token model's own invariants
  C1  theme.light and theme.dark carry identical key sets.
  C2  register.explorer and register.debugger carry identical key sets.
  C3  rhythm row < stack < group < section, each at least 1.75x the one below.
      Resolved to NUMBERS through the design system; if the design system is
      unreadable this check FAILS rather than skipping.

The shipped page
  D1  client/dist declares exactly the derived --bt-* set, and no --ct-*.
  D2  Both themes and both registers reach the shipped CSS.
      Without a build, D1/D2 report NOT RUN. --require-built makes that a
      failure, and \`just design-check\` passes it.
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
