#!/usr/bin/env node
// Extract the CodeTracer debugger-panel style baseline from CodeTracer's STYLUS
// SOURCE, so reference parity is computed against what CodeTracer is, not
// transcribed into prose that goes stale.
//
// WHY THIS EXISTS. `codetracer-specs/milestones/BlockTracer-Visual-Design.milestones.org`
// records, under "What the gate cannot currently enforce":
//
//     Reference parity (G4) is recorded, not computed. No script compares a page
//     to a Webflow prototype. gate.mjs checks that the check was performed and
//     recorded with a verdict, a reference and a named human.
//
// READ THE SOURCE, NOT AN INSTALLED BUILD. The first version of this script read
// /Applications/CodeTracer.app, and every number it produced was wrong, because
// that bundle predates the fix below. Taking the baseline from whatever build
// happens to be installed pins a snapshot of unknown age, and a stale reference
// is worse than none: it reports drift when BlockTracer is right.
//
// THE CONCRETE CASE, kept because it is the reason for the rule. The installed
// bundle set `.component-container` in `"FiraCode"` at 14px/24px. `FiraCode` is
// not a family CodeTracer declares — `components/status_bar.styl` records that
// the design system declares exactly four @font-face families (SpaceGrotesk,
// SpaceMono, FiraMono, FontAwesome), that "FiraCode is not one of them, and no
// FiraCode file exists in the tree", and that it was "dead text in 21 places"
// which fell back to Chrome's default PROPORTIONAL SERIF. A baseline taken from
// that build would have told BlockTracer to adopt a bug CodeTracer had already
// fixed. The current source is SpaceGrotesk at relative sizes.
//
//   node tools/design/extract-codetracer-baseline.mjs --ct <codetracer-checkout>
//
// `--ct` defaults to $CODETRACER_SRC, then ../codetracer.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const SELECTORS = {
  ".component-container": "components/shared_widgets.styl",
  ".data-table": "components/data_tables.styl",
  ".table-column-names": "components/welcome_screen.styl",
};

// Only declarations that change how a panel READS. Layout plumbing is excluded:
// BlockTracer's panels live in a different layout engine, and matching flex/
// overflow/width would be cargo-culting rather than parity.
const PROPERTIES = new Set([
  "font-family", "font-size", "line-height", "font-weight", "letter-spacing",
  "color", "background", "background-color", "border-radius", "box-shadow",
]);

function parseArgs(argv) {
  const out = {
    ct: process.env.CODETRACER_SRC || "../codetracer",
    out: "tools/design/codetracer-panel-baseline.json",
  };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--ct") out.ct = argv[++i];
    else if (a === "--out") out.out = argv[++i];
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  return out;
}

// Stylus here is indentation-based: a selector sits at column 0 and its
// declarations are indented under it. A COMMENTED-OUT declaration is skipped
// rather than read — `shared_widgets.styl` carries a commented `box-shadow`
// behind an `// if !IS_EXTENSION`, and reading it would pin a rule that does
// not apply.
function blockFor(styl, selector) {
  const lines = styl.split("\n");
  for (let i = 0; i < lines.length; i += 1) {
    if (lines[i].trimEnd() !== selector) continue;
    const decls = {};
    let depth = null;                        // indent of this block's OWN declarations
    for (let j = i + 1; j < lines.length; j += 1) {
      const raw = lines[j];
      if (raw.trim() === "") continue;
      const indent = raw.length - raw.trimStart().length;
      if (indent === 0) break;               // dedent to column 0: block over
      if (depth === null) depth = indent;
      // STYLUS NESTS, AND A NESTED RULE IS NOT THIS RULE. `.data-table` contains
      // `&:hover` and child selectors whose declarations are indented deeper;
      // reading them as the parent's produced a baseline claiming the table had
      // a hover background and `line-height: 2em`. Only this block's own depth
      // counts, and a selector AT that depth ends it.
      if (indent > depth) continue;          // inside a nested rule
      const line = raw.trim();
      if (line.startsWith("//")) continue;   // commented-out declaration
      const m = /^([a-z-]+)\s*:\s*(.+?)$/.exec(line);
      if (!m) break;                         // a nested selector at our depth
      const [, prop, rawValue] = m;
      if (!PROPERTIES.has(prop)) continue;
      decls[prop] = rawValue.replace(/\s*!important\s*$/, "").trim();
    }
    return decls;
  }
  return null;
}

const args = parseArgs(process.argv);
if (!existsSync(join(args.ct, "src/frontend/styles"))) {
  console.error(`::error::not a CodeTracer checkout: ${args.ct}`);
  console.error("Pass --ct <path> or set CODETRACER_SRC.");
  process.exit(1);
}

let rev = "unknown";
try {
  rev = execFileSync("git", ["-C", args.ct, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
} catch { /* a non-git export is still usable; the rev is provenance, not input */ }

const selectors = {};
const missing = [];
for (const [sel, rel] of Object.entries(SELECTORS)) {
  const path = join(args.ct, "src/frontend/styles", rel);
  if (!existsSync(path)) { missing.push(`${sel} (${rel} absent)`); continue; }
  const decls = blockFor(readFileSync(path, "utf8"), sel);
  if (decls === null) { missing.push(`${sel} (not found in ${rel})`); continue; }
  selectors[sel] = { source: rel, declarations: decls };
}

const baseline = {
  schema: "blocktracer/codetracer-panel-baseline@2",
  reference: "codetracer stylus source (NOT an installed build — see header)",
  codetracerRev: rev,
  extractedProperties: [...PROPERTIES].sort(),
  missingSelectors: missing,
  selectors,
};

writeFileSync(args.out, `${JSON.stringify(baseline, null, 2)}\n`);
console.log(`wrote ${args.out}`);
console.log(`  codetracer rev: ${rev}`);
console.log(`  selectors: ${Object.keys(selectors).length}/${Object.keys(SELECTORS).length}`);
if (missing.length) console.log(`  MISSING: ${missing.join("; ")}`);
for (const [sel, v] of Object.entries(selectors)) {
  console.log(`  ${sel} <- ${v.source}: ${JSON.stringify(v.declarations)}`);
}
