#!/usr/bin/env node
// Extract the CodeTracer debugger-panel style baseline from a BUILT CodeTracer,
// so reference parity is COMPUTED from the thing we are matching rather than
// transcribed into prose that goes stale.
//
// WHY THIS EXISTS. `codetracer-specs/milestones/BlockTracer-Visual-Design.milestones.org`
// records, under "What the gate cannot currently enforce":
//
//     Reference parity (G4) is recorded, not computed. No script compares a page
//     to a Webflow prototype. gate.mjs checks that the check was performed and
//     recorded with a verdict, a reference and a named human.
//
// That is the hole this closes for the DEBUGGER register. It does not photograph
// anything: it reads the compiled stylesheet the application actually renders with
// and writes down the declarations that define a panel's texture.
//
// WHY THE APP AND NOT THE DESIGN SYSTEM. BlockTracer already consumes
// `codetracer-design-system` as a pinned flake input, and follows it faithfully —
// the token set names Space Mono. The application does not: it renders panels in
// FiraCode, with inlined Stylus values and ZERO CSS custom properties. So a build
// can satisfy every token check and still not look like CodeTracer, which is
// exactly what happened. The app is the reference because the app is what a user
// compares against.
//
//   node tools/design/extract-codetracer-baseline.mjs [--css <path>] [--out <path>]
//
// Default --css is the macOS app bundle; pass --css for a Linux build or a checkout's
// generated stylesheet.

import { readFileSync, writeFileSync, existsSync } from "node:fs";

const DEFAULT_CSS =
  "/Applications/CodeTracer.app/Contents/MacOS/frontend/styles/default_dark_theme_electron.css";

// The selectors that define a panel's texture. Each is a frame a BlockTracer
// debugger surface has an equivalent of; a selector absent from the reference is
// reported rather than skipped, because a renamed selector upstream must not look
// like "no drift".
const SELECTORS = [
  ".component-container",
  ".component-wrapper",
  ".data-table",
  ".table-column-names",
  ".panel",
];

// Only declarations that change how a panel READS. Layout plumbing (display,
// flex, overflow, width/height) is deliberately excluded: BlockTracer's panels
// live in a different layout engine and matching those would be cargo-culting.
const PROPERTIES = new Set([
  "font-family",
  "font-size",
  "line-height",
  "font-weight",
  "letter-spacing",
  "color",
  "background",
  "background-color",
  "border-radius",
  "box-shadow",
]);

function parseArgs(argv) {
  const out = { css: DEFAULT_CSS, out: "tools/design/codetracer-panel-baseline.json" };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--css") out.css = argv[++i];
    else if (a === "--out") out.out = argv[++i];
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  return out;
}

// A deliberately small reader: the stylesheet is generated Stylus, one
// declaration per line, so a brace-matched block scan is enough and a CSS parser
// dependency is not. If upstream ever minifies it, `blockFor` returns null and
// the caller reports a MISSING selector rather than silently emitting {}.
function blockFor(css, selector) {
  const lines = css.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    const head = lines[i].trim();
    if (head !== `${selector} {` && head !== `${selector}{`) continue;
    const decls = {};
    for (let j = i + 1; j < lines.length; j += 1) {
      const line = lines[j].trim();
      if (line.startsWith("}")) return decls;
      const m = /^([a-z-]+)\s*:\s*(.+?);?$/.exec(line.replace(/\/\*.*?\*\//g, "").trim());
      if (!m) continue;
      const [, prop, rawValue] = m;
      if (!PROPERTIES.has(prop)) continue;
      decls[prop] = rawValue.replace(/\s*!important\s*$/, "").replace(/;$/, "").trim();
    }
    return decls; // unterminated block: return what was read
  }
  return null;
}

const args = parseArgs(process.argv);
if (!existsSync(args.css)) {
  console.error(`::error::reference stylesheet not found: ${args.css}`);
  console.error("Pass --css <path> to a built CodeTracer's default_dark_theme_electron.css.");
  process.exit(1);
}

const css = readFileSync(args.css, "utf8");
const selectors = {};
const missing = [];
for (const sel of SELECTORS) {
  const decls = blockFor(css, sel);
  if (decls === null) { missing.push(sel); continue; }
  selectors[sel] = decls;
}

const baseline = {
  schema: "blocktracer/codetracer-panel-baseline@1",
  source: args.css,
  extractedProperties: [...PROPERTIES].sort(),
  missingSelectors: missing,
  selectors,
};

writeFileSync(args.out, `${JSON.stringify(baseline, null, 2)}\n`);
console.log(`wrote ${args.out}`);
console.log(`  selectors captured: ${Object.keys(selectors).length}/${SELECTORS.length}`);
if (missing.length) console.log(`  MISSING (renamed upstream?): ${missing.join(", ")}`);
for (const [sel, decls] of Object.entries(selectors)) {
  console.log(`  ${sel}: ${Object.keys(decls).length} declaration(s)`);
}
