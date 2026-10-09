#!/usr/bin/env node
// Extract the CodeTracer debugger-panel style baseline from a CodeTracer BUILT
// FROM SOURCE at a known commit, so reference parity is computed against what
// CodeTracer is rather than transcribed into prose that goes stale.
//
// WHY THIS EXISTS. `codetracer-specs/milestones/BlockTracer-Visual-Design.milestones.org`
// records, under "What the gate cannot currently enforce":
//
//     Reference parity (G4) is recorded, not computed. No script compares a page
//     to a Webflow prototype. gate.mjs checks that the check was performed and
//     recorded with a verdict, a reference and a named human.
//
// BUILD THE REFERENCE; DO NOT READ AN INSTALLED ONE, AND DO NOT PARSE STYLUS.
// This script has been wrong twice, and both ways are worth remembering:
//
//   1. It first read /Applications/CodeTracer.app. Every number was wrong: that
//      bundle predated a fix and set `.component-container` in "FiraCode", a
//      family CodeTracer does not declare — `components/status_bar.styl` records
//      it as "dead text in 21 places" that fell back to Chrome's default
//      PROPORTIONAL SERIF. A baseline from an installed build pins a snapshot of
//      unknown age, and a stale reference is worse than none: it reports drift
//      when the consumer is right.
//
//   2. It then parsed the Stylus SOURCE. The values were right, but getting them
//      cost a hand-written parser for an indentation-sensitive language, which
//      promptly flattened nested rules — `.data-table` acquired a hover
//      background and a line-height belonging to a child — and it left design
//      tokens UNRESOLVED, recording `colors-ui-text-primary-body` where the
//      product renders `#f3f3f3`.
//
// So: build CodeTracer and read the CSS its own toolchain emitted. No parser for
// a language this repository does not otherwise speak, and tokens already
// resolved to the values a browser will see.
//
//   nix build .#packages.<system>.codetracer-electron   # in a codetracer checkout
//   node tools/design/extract-codetracer-baseline.mjs --built <result> --rev <sha>
//
// `codetracer-electron` and not `.#default`: the default package pulls in the
// BPF monitor, whose `libbpf` is Linux-only, so it refuses to evaluate on
// darwin. The Electron app itself builds on both.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const SELECTORS = [".component-container", ".data-table", ".table-column-names"];

// Only declarations that change how a panel READS. Layout plumbing (flex,
// overflow, width/height, min-height) is excluded deliberately: BlockTracer's
// panes live in a different layout engine, and matching those would be
// cargo-culting rather than parity.
const PROPERTIES = new Set([
  "font-family", "font-size", "line-height", "font-weight", "letter-spacing",
  "color", "background", "background-color", "border-radius", "box-shadow",
]);

function parseArgs(argv) {
  const out = { built: "", rev: "", out: "tools/design/codetracer-panel-baseline.json" };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--built") out.built = argv[++i];
    else if (a === "--rev") out.rev = argv[++i];
    else if (a === "--out") out.out = argv[++i];
    else { console.error(`unknown argument: ${a}`); process.exit(2); }
  }
  return out;
}

// THE SELECTOR MUST STAND ALONE. An earlier version of the comparison matched
// `.data-table` inside `.something .data-table {` and read a descendant rule's
// declarations as the base rule's, which reported four properties missing that
// were there all along. So the match is anchored to a line start.
function blockFor(css, selector) {
  const lines = css.split("\n");
  const head = new RegExp(`^${selector.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*\\{`);
  for (let i = 0; i < lines.length; i += 1) {
    if (!head.test(lines[i])) continue;
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
    return decls;
  }
  return null;
}

const args = parseArgs(process.argv);
if (!args.built) {
  console.error("::error::--built <path> is required (a built codetracer-electron result).");
  process.exit(2);
}
const cssPath = join(args.built, "styles/default_dark_theme.css");
if (!existsSync(cssPath)) {
  console.error(`::error::no compiled theme at ${cssPath}`);
  console.error("Build it first: nix build .#packages.<system>.codetracer-electron");
  process.exit(1);
}

const css = readFileSync(cssPath, "utf8");

// A GUARD, because the failure this script already had was silent. `FiraCode` is
// not a family CodeTracer declares; a build that still mentions it is older than
// the fix, and a baseline taken from it would demand a bug.
const firaCode = (css.match(/FiraCode/g) || []).length;
if (firaCode > 0) {
  console.error(`::error::this build mentions FiraCode ${firaCode}x, so it predates the fix.`);
  console.error("Build a newer CodeTracer; see this file's header.");
  process.exit(1);
}

const selectors = {};
const missing = [];
for (const sel of SELECTORS) {
  const decls = blockFor(css, sel);
  if (decls === null) { missing.push(sel); continue; }
  selectors[sel] = decls;
}

const baseline = {
  schema: "blocktracer/codetracer-panel-baseline@3",
  reference: "codetracer-electron, BUILT from source (not an installed bundle, not parsed Stylus)",
  codetracerRev: args.rev || "unrecorded",
  compiledFrom: "styles/default_dark_theme.css",
  extractedProperties: [...PROPERTIES].sort(),
  missingSelectors: missing,
  selectors,
};

writeFileSync(args.out, `${JSON.stringify(baseline, null, 2)}\n`);
console.log(`wrote ${args.out}`);
console.log(`  rev: ${baseline.codetracerRev}`);
console.log(`  FiraCode in build: ${firaCode} (must be 0)`);
console.log(`  selectors: ${Object.keys(selectors).length}/${SELECTORS.length}`);
if (missing.length) console.log(`  MISSING: ${missing.join(", ")}`);
for (const [sel, d] of Object.entries(selectors)) {
  console.log(`  ${sel}: ${JSON.stringify(d)}`);
}
