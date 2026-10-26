#!/usr/bin/env node
// check-design-parity-selftest.mjs — does the parity check DECIDE?
//
// Every arm builds a synthetic published tree in a temp directory, runs the
// real checker over it with `--dir`, and fails if the verdict does not change.
// A tree is used rather than a mocked origin because `--dir` and `--origin`
// share every assertion — only `getText` differs — so a tree exercises the
// decisions and needs no network.
//
// THE BASELINE IS BUILT FROM THE REGISTER, not from a list here. It carries a
// rule and an emission for every LIVE row `ct_css_reach.txt` declares, so the
// baseline passes for the same reason a real tree does, and an arm that breaks
// one row breaks exactly one.
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve, dirname } from "node:path";

const HERE = new URL(".", import.meta.url).pathname;
const REPO = resolve(HERE, "..", "..");
const TOOL = join(HERE, "check-design-parity.mjs");
const REGISTER = join(REPO, "client", "src", "components", "ct_css_reach.txt");

// THE EVIDENCE COLUMN IS READ, BECAUSE THE BASELINE HAS TO MIRROR A REAL TREE.
// A row's fourth token is its evidence tier; `bundle` means the hydration
// bundle writes the class and the served HTML does not carry it. A baseline
// that put every class in the page's `class` attribute was not a published
// tree, it was a tree shaped like the checker's old mistake — and it passed
// for the same reason the checker's old emission arm failed on production.
const live = [];
for (const line of readFileSync(REGISTER, "utf8").split("\n")) {
  const m = /^LIVE\s+(class|classpart|element|id)\s+(\S+)(?:\s+(\S+))?/.exec(line);
  if (m) live.push({ kind: m[1], name: m[2], evidence: m[3] ?? "" });
}

// `*` IS A GLOB IN THE REGISTER, SO THE BASELINE WRITES SOMETHING IT MATCHES.
// The previous baseline wrote the pattern verbatim — `.ct-input-*` — which is
// not a selector any tree contains and not a class any page emits. It passed
// only because the checker searched for the asterisk too.
const expand = (pattern) => pattern.replace(/\*/g, "selftest");
const BUNDLE_PATH = "/assets/hydrate.js";

const CSS_NAME = "/_a/aaaabbbbccccdddd.css";
const write = (root, path, body) => {
  const f = join(root, path.replace(/^\//, ""));
  mkdirSync(dirname(f), { recursive: true });
  writeFileSync(f, body);
};

/**
 * A tree that passes, with `mutate` applied to its parts first.
 *
 * The two transaction pages are on DIFFERENT chains and only one carries
 * `srctab`, which mirrors the real tree: the sample has to span chains for the
 * union to cover the kinds, and the source-bearing kind has to be present or
 * the class-emission arm is coverage-bound rather than wrong.
 */
function tree(mutate = (p) => p) {
  const root = mkdtempSync(join(tmpdir(), "parity-"));
  const classRows = live.filter((r) => r.kind === "class");
  // THE SIGIL FOLLOWS THE KIND, the same way the checker's does: an `id` row
  // is `#name` in a stylesheet and was written `.name` here, so three ids that
  // a real sheet carries were satisfied by a selector no sheet contains.
  const sigil = (r) => (r.kind === "element" ? "" : r.kind === "id" ? "#" : ".");
  const parts = {
    cssName: CSS_NAME,
    css: live.map((r) => `${sigil(r)}${expand(r.name)}{color:#fff}`).join("\n")
       + `\n.pad{background:url(/assets/ct-icons/x.svg)}\n`
       + "/* padding to clear the size floor */\n" + "/*".padEnd(12_000, "x") + "*/\n",
    icon: "<svg/>",
    pageScript: `<script src="${BUNDLE_PATH}"></script>`,
    pageClasses: classRows.filter((r) => r.evidence !== "bundle").map((r) => expand(r.name)).join(" "),
    // The bundle's half of the universe. A string literal per class, which is
    // what `nim js` emits for most of them; the char-code form the checker also
    // decodes is upstream's, not something a synthetic tree needs to imitate.
    bundleClasses: classRows.filter((r) => r.evidence === "bundle").map((r) => expand(r.name)),
    bundlePath: BUNDLE_PATH,
    withSrctab: true,
    chains: ["aztec", "aztec-testnet"],
  };
  const p = mutate(parts);
  write(root, "index.html", `<html><head><link href="${p.cssName}" rel="stylesheet"></head><body>i</body></html>`);
  write(root, p.cssName, p.css);
  // A NULL icon means "do not write the file", which is the 404 arm. Writing
  // `null` would throw inside the harness and report as a bite that did not land.
  if (typeof p.icon === "string") write(root, "/assets/ct-icons/x.svg", p.icon);
  // A NULL bundlePath means "do not write the bundle", which is the arm for a
  // script the origin does not serve.
  if (typeof p.bundlePath === "string")
    write(root, p.bundlePath,
      "export const marks = [" + p.bundleClasses.map((c) => JSON.stringify(c)).join(",") + "];\n");
  p.chains.forEach((chain, i) => {
    const tx = `/${chain}/tx/0x${String(i + 1).repeat(8)}`;
    write(root, `/${chain}/index.html`, `<html><body><a href="${tx}">tx</a></body></html>`);
    write(root, `${tx}/index.html`,
      `<html><head>${p.pageScript}</head><body class="${p.pageClasses}">`
      + `${i === 0 && p.withSrctab ? '<a class="srctab ct-tab">s</a>' : ""}</body></html>`);
  });
  return root;
}

const run = (root) => {
  const r = spawnSync(process.execPath, [TOOL, "--dir", root], { encoding: "utf8" });
  return { status: r.status, out: `${r.stdout ?? ""}${r.stderr ?? ""}` };
};

let asserted = 0;
const failures = [];
const bite = (what, ok) => {
  asserted++;
  if (ok) { console.log(`  bite  ${what}`); return; }
  console.log(`  BITE DID NOT LAND  ${what}`);
  failures.push(what);
};

console.log("=== check-design-parity-selftest — does it decide? ===");
console.log("");
console.log(`the register declares ${live.length} LIVE row(s); the baseline tree satisfies all of them`);
console.log("");

// THE BASELINE. Without this every arm below could be passing because the
// checker refuses every tree.
{
  const root = tree();
  const r = run(root);
  bite("a tree that carries every LIVE row PASSES — the control for every arm below",
       r.status === 0 && /^PASS/m.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
// One defect per arm, each the real one measured on production 2026-10-12.
{
  const root = tree((p) => ({ ...p, css: p.css.replace(/\.component-container\{[^}]*\}\n?/, "") }));
  const r = run(root);
  bite("a stylesheet missing ONE LIVE rule fails, and names the row (production's defect 1)",
       r.status === 1 && /component-container/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  const root = tree((p) => ({ ...p,
    css: p.css.replace("url(/assets/ct-icons/x.svg)", "url(../../../public/resources/origin-icons/door.svg)") }));
  const r = run(root);
  bite("a RELATIVE url() fails, and quotes it (production's defect 2: eight of twelve)",
       r.status === 1 && /public\/resources\/origin-icons\/door\.svg/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  const root = tree((p) => ({ ...p, icon: null }));
  // The icon file is written only when `icon` is a string; a null leaves the
  // url() pointing at nothing, which is the 404 half rather than the relative half.
  const r = run(root);
  bite("an absolute url() that 404s fails, separately from the relative arm",
       r.status === 1 && /-> 404/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  const root = tree((p) => ({ ...p, pageScript: "" }));
  const r = run(root);
  bite("a transaction page with NO script fails (production's defect 3: 7,942 bytes, zero tags)",
       r.status === 1 && /pre-hydration fallback/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  const root = tree((p) => ({ ...p, pageClasses: p.pageClasses.replace("component-container", "") }));
  const r = run(root);
  bite("a page that does not EMIT a LIVE class fails even though the rule is served — the register's own defect 1",
       r.status === 1 && /not emitted anywhere: component-container/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  const root = tree((p) => ({ ...p, withSrctab: false }));
  const r = run(root);
  bite("a sample with NO source-bearing page says so, so a class-emission result is not read as a verdict",
       /the sample contains a page that publishes SOURCE/.test(r.out)
       && /0 of 2 page\(s\)/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  const root = tree((p) => ({ ...p, chains: ["aztec"] }));
  const r = run(root);
  bite("ONE chain is refused rather than judged — a union over one chain cannot cover the kinds",
       r.status === 1 && /at least two chains/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  const root = tree((p) => ({ ...p, cssName: "/_a/one.css", css: p.css + "\n" }));
  // Two sheets named, which is the shape a half-migrated tree has.
  write(root, "index.html",
    '<html><head><link href="/_a/one.css" rel="stylesheet">'
    + '<link href="/_a/two.css" rel="stylesheet"></head><body>i</body></html>');
  const r = run(root);
  bite("two stylesheets under /_a/ is refused, not silently read as the first",
       r.status === 1 && /exactly one stylesheet/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  // THE BUNDLE TIER BITES TOO. 105 LIVE rows name the bundle as their evidence
  // and the page HTML never carries them, so if the bundle half of the search
  // were dropped the checker would go green on a tree whose hydration bundle
  // writes none of CodeTracer's views.
  const root = tree((p) => ({ ...p,
    bundleClasses: p.bundleClasses.filter((c) => c !== "calltrace-row") }));
  const r = run(root);
  bite("a class the BUNDLE is the evidence for, missing from the bundle, fails and names it",
       r.status === 1 && /not emitted anywhere: calltrace-row/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  // AND A BUNDLE THAT CANNOT BE READ IS NOT A PASS. With no bundle the rows
  // that depend on it were not measured, and a verdict over an empty universe
  // is the silence this tool exists to break.
  const root = tree((p) => ({ ...p, bundlePath: null }));
  const r = run(root);
  bite("a referenced bundle the origin does not serve is refused, not read as an empty universe",
       r.status === 1 && /name the bundle as their evidence/.test(r.out));
  rmSync(root, { recursive: true, force: true });
}
{
  const r = spawnSync(process.execPath, [TOOL], { encoding: "utf8" });
  bite("neither --origin nor --dir is a usage error (64), not a run that measured nothing",
       r.status === 64 && /exactly one of/.test(`${r.stdout}${r.stderr}`));
}
{
  const r = spawnSync(process.execPath, [TOOL, "--dir", join(tmpdir(), "parity-does-not-exist-7f3a")],
                      { encoding: "utf8" });
  bite("a directory that is not a published tree fails rather than passing on absence",
       r.status === 1 && /entry document/.test(`${r.stdout}${r.stderr}`));
}

console.log("");
const EXPECTED = 13;
if (asserted !== EXPECTED) {
  console.log(`ASSERTION COUNT IS ${asserted}, EXPECTED ${EXPECTED} — an arm was added, removed or skipped.`);
  failures.push("assertion count");
}
console.log(failures.length === 0
  ? `PASS — ${asserted} arm(s) bit`
  : `FAIL — ${failures.length} problem(s)`);
process.exitCode = failures.length === 0 ? 0 : 1;
