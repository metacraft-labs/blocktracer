#!/usr/bin/env node
// The self-test for `tools/deploy/check-recordings-named.mjs`.
//
//   node tools/deploy/check-recordings-named-selftest.mjs
//
// ── The bar ────────────────────────────────────────────────────────────────
//
// The gate this exercises exists because run 41420602459 shipped a site in
// which every Aztec transaction served an empty `data-trace`, and every
// post-check passed. A gate written in response to a silent green is worth
// precisely what it can be shown to do, so each arm below asserts THREE
// things, the same bar `check-assets-selftest.mjs` sets:
//
//   1. the tree WITHOUT the mutation passes — per-arm, because an arm that
//      stages containers elsewhere has a different clean state;
//   2. the tree WITH the mutation fails;
//   3. the SENTENCE names the mutation. Exit code alone would let the
//      vacuous-pass refusal stand in for the incident's own arm.
//
// Arms `self-contained`, `staged-origin` and `divergent-named-resolves` invert
// it: they assert the gate stays GREEN on input a careless implementation would
// flag. On a `render-over-live` publish the containers are the live bucket's
// and the tree holds none of them — a gate that refused that would be switched
// off within a day, and the incident would recur with it nominally in place.
//
// ── The divergent arms ─────────────────────────────────────────────────────
//
// `divergent-named-{resolves,absent}` are here because the author of the Aptos
// producer asked for them: their tree has two divergent rows and two replayed
// ones, and a divergent row is not `availability: "ready"`, so rule R1 never
// looks at it. R2 is what covers it, and these two arms are the only place the
// distinction is pinned — the first says a divergent row may legitimately offer
// its bytes, the second says it may not offer bytes nobody holds. Without the
// second, `check-assets.mjs` A1's deliberate silence about container
// references when `--require-traces` is absent (its arms 6c/6d) would leave
// that case checked by nothing at all.

// MEASURED ON TWO REAL TREES, not only on the fixtures below, because the
// divergent arms would otherwise be synthetic-only and a reader would be right
// to discount them. This repository's built tree: 26 ready over 4 chains, 28
// named containers, 28 resolved, 2 named by a divergent row; and with one
// page's `data-trace` blanked, that transaction named and exit 1. The Aptos
// producer's tree, run by its author over ten chains: 70 ready, 74 named, all
// 74 resolved, 4 named by a divergent row — of which aptos-mainnet contributes
// 2 ready and 4 named, so its two divergent Decibel bulk orders are covered by
// R2 and by nothing else here, on a real chain rather than a fixture. 96 ready
// rows and 102 named containers between the two, every one resolved, and both
// sets of per-chain counts matched what each of us expected before looking.
//
// THAT APTOS HALF IS HISTORY. It was measured with the CLI built on aptos-node
// v1.49.6. Built on v1.49.8 (fork branch codetracer/value-tracing-aptos-node-v1.49.8),
// the two Decibel bulk orders replay and match the chain, event root hash
// included. A capture with that CLI has no divergent Aptos row, so R2 is covered
// on a real chain only by the other chains in this measurement, and here by the
// fixtures below.

import { mkdirSync, mkdtempSync, rmSync, writeFileSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const HERE = dirname(fileURLToPath(import.meta.url));
const CHECKER = join(HERE, "check-recordings-named.mjs");

const write = (root, rel, body) => {
  const p = join(root, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, body);
};

// A fixture chain: `rows` is [tx, availability, validationStatus|null, dataTrace].
// `dataTrace` of null omits the attribute; "" is the incident's empty value.
function build(root, { chain = "aztec", version = "7", rows, containersIn = root }) {
  write(root, `d/${chain}/current.json`, JSON.stringify({ traceSelectionVersion: version, generation: "g1" }));
  for (const [tx, availability, validation, dataTrace] of rows) {
    const shard = tx.slice(2, 6);
    const overlay = { tx, trace: { availability, ...(validation ? { validation: { status: validation } } : {}) } };
    write(root, `d/${chain}/ts/${version}/${shard}/${tx}.json`, JSON.stringify(overlay));
    const attr = dataTrace === null ? "" : ` data-trace="${dataTrace}"`;
    write(root, `${chain}/tx/${tx}/debug/index.html`,
      `<!doctype html><html><body><div data-register="debugger"${attr}></div></body></html>`);
    if (dataTrace) write(containersIn, dataTrace, "CTTRACE\x00");
  }
}

const READY = (tx, ref) => [tx, "ready", "match", ref];
const base = (root, over = {}) => build(root, {
  rows: [
    READY("0xaa01aaaaaaaa", "t/aa/01/r1/trace.ct"),
    READY("0xbb02bbbbbbbb", "t/bb/02/r2/trace.ct"),
  ],
  ...over,
});

const arms = [
  { name: "self-contained", stays: true, setup: (root) => base(root),
    expectOut: /2 ready over 1 chain\(s\); 2 named container\(s\), 2 resolved/ },

  { name: "staged-origin", stays: true,
    // The render-over-live shape: the tree carries pages and overlays, the
    // staged copy of the live bucket carries the containers.
    setup: (root, origin) => { mkdirSync(origin, { recursive: true }); base(root, { containersIn: origin }); },
    useOrigin: true, expectOut: /2 named container\(s\), 2 resolved in the tree or the staged bucket/ },

  { name: "neither-root-holds-them", setup: (root) => base(root),
    useOrigin: true,
    mutate: (root, origin) => { rmSync(join(root, "t"), { recursive: true }); mkdirSync(origin, { recursive: true }); },
    expectFail: /page names t\/aa\/01\/r1\/trace\.ct and no root holds it/ },

  { name: "the-incident-empty-data-trace", setup: (root) => base(root),
    mutate: (root) => write(root, "aztec/tx/0xaa01aaaaaaaa/debug/index.html",
      `<!doctype html><html><body><div data-register="debugger" data-trace=""></div></body></html>`),
    expectFail: /overlay says ready, page declines the engine \(empty data-trace\)/ },

  { name: "no-data-trace-attribute-at-all", setup: (root) => base(root),
    mutate: (root) => write(root, "aztec/tx/0xaa01aaaaaaaa/debug/index.html",
      `<!doctype html><html><body><div data-register="debugger"></div></body></html>`),
    expectFail: /page carries no data-trace attribute at all/ },

  { name: "ready-row-with-no-debug-page", setup: (root) => base(root),
    mutate: (root) => rmSync(join(root, "aztec/tx/0xaa01aaaaaaaa"), { recursive: true }),
    expectFail: /overlay says ready and there is no debug page/ },

  // ── the Aptos author's case, both halves ────────────────────────────────
  { name: "divergent-named-resolves", stays: true,
    setup: (root) => build(root, { rows: [
      READY("0xaa01aaaaaaaa", "t/aa/01/r1/trace.ct"),
      ["0xcc03cccccccc", "replayed", "divergent", "t/cc/03/r3/trace.ct"],
    ] }),
    expectOut: /1 named by a DIVERGENT row, reported and not refused/ },

  { name: "divergent-named-absent", setup: (root) => build(root, { rows: [
      READY("0xaa01aaaaaaaa", "t/aa/01/r1/trace.ct"),
      ["0xcc03cccccccc", "replayed", "divergent", "t/cc/03/r3/trace.ct"],
    ] }),
    mutate: (root) => rmSync(join(root, "t/cc"), { recursive: true }),
    expectFail: /0xcc03cccccccc: page names t\/cc\/03\/r3\/trace\.ct and no root holds it/ },

  // ── the vacuous-pass direction ──────────────────────────────────────────
  { name: "nothing-is-ready", setup: (root) => base(root),
    mutate: (root) => build(root, { rows: [
      ["0xaa01aaaaaaaa", "pending", null, ""],
      ["0xbb02bbbbbbbb", "pending", null, ""],
    ] }),
    expectFail: /no transaction in any chain has a ready TraceSelection entry, so this check measured nothing/ },

  { name: "pointer-names-a-version-that-is-not-there", setup: (root) => base(root),
    mutate: (root) => renameSync(join(root, "d/aztec/ts/7"), join(root, "d/aztec/ts/8")),
    expectFail: /measured nothing/ },

  { name: "no-chain-published-a-pointer", setup: (root) => base(root),
    mutate: (root) => rmSync(join(root, "d/aztec"), { recursive: true }),
    expectFail: /no chain published a current\.json/ },
];

const runChecker = (root, origin, useOrigin) => {
  const args = [CHECKER, "--dir", root, ...(useOrigin ? ["--live-origin", origin] : [])];
  const r = spawnSync(process.execPath, args, { encoding: "utf8" });
  return { code: r.status, out: `${r.stdout}${r.stderr}` };
};

let failures = 0;
for (const arm of arms) {
  const root = mkdtempSync(join(tmpdir(), "btrecnamed-"));
  const origin = join(root, "..", `${root.split("/").pop()}-origin`);
  const problems = [];
  try {
    arm.setup(root, origin);

    // (1) the per-arm control.
    const clean = runChecker(root, origin, arm.useOrigin);
    if (clean.code !== 0) problems.push(`clean tree did not pass (exit ${clean.code}) — every verdict below is meaningless`);
    if (arm.expectOut && !arm.expectOut.test(clean.out)) problems.push(`clean output did not match ${arm.expectOut}`);

    if (arm.mutate) {
      arm.mutate(root, origin);
      // (2) and (3).
      const dirty = runChecker(root, origin, arm.useOrigin);
      if (dirty.code === 0) problems.push("mutated tree PASSED — the gate does not see this");
      if (arm.expectFail && !arm.expectFail.test(dirty.out)) {
        problems.push(`failed for the wrong reason; wanted ${arm.expectFail}`);
        problems.push(`  got: ${dirty.out.trim().split("\n").slice(-4).join(" / ")}`);
      }
    } else if (!arm.stays) {
      problems.push("arm declares no mutation and is not a stays-green arm");
    }
  } catch (e) {
    problems.push(`threw: ${e.message}`);
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(origin, { recursive: true, force: true });
  }
  if (problems.length) {
    failures += 1;
    console.log(`  FAIL  ${arm.name}`);
    for (const p of problems) console.log(`        ${p}`);
  } else {
    console.log(`  ok    ${arm.name}${arm.stays ? "  (stays green)" : ""}`);
  }
}

console.log(failures === 0
  ? `\nall ${arms.length} arms decided as written.`
  : `\n${failures} of ${arms.length} arms did not decide as written.`);
process.exit(failures === 0 ? 0 : 1);
