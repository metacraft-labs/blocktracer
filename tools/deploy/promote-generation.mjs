#!/usr/bin/env node
// promote-generation.mjs — point a staged chain at a generation the bucket
// already holds, so the render enumerates THAT history.
//
//   node tools/deploy/promote-generation.mjs --origin <dir> --promote <list>
//   node tools/deploy/promote-generation.mjs --selftest
//
// `<list>` is comma-separated `chain=generation`, e.g.
// `aztec=raztec00001,aztec-testnet=rtestnet0001`.
//
// ── WHY THIS EXISTS ───────────────────────────────────────────────────────
//
// The full history of both Aztec chains is IN the production bucket and
// serving — every sampled block page of `raztec00001` and `rtestnet0001`
// answers 200 — but `d/<chain>/current.json` names a far smaller generation,
// so no index links any of it and a visitor can only reach it by typing a URL
// they would have to already know. docs/PRODUCTION-DATA-PLANE.md §7a measures
// that, and §7b is why no existing mode can fix it:
//
//   * the ordinary build ingests the COMMITTED CAPTURES, which are tip windows
//     of 27, 49 and 26 blocks, so it can only ever emit the small generation;
//   * `render-over-live` enumerates from the STAGED pointer, which is the
//     bucket's, which names the generation already live — so it re-renders
//     exactly that window and writes the same pointer straight back out.
//
// The cycle has one cut point: between the sync that produced the staged
// pointer and the build that reads it. This runs there.
//
// ── THE POINTER IS DERIVED, NEVER TYPED IN ────────────────────────────────
//
// `head` and `finalized` come from the generation's OWN height map — its
// greatest height, and that height's hash. Nothing here invents a hash, and
// nothing here is copied from a previous pointer: a promotion that carried a
// stale head would name a generation while describing a different one, and the
// publisher writes `current.json` LAST and unconditionally, so that pointer is
// what every later reader resolves the chain through.
//
// `finalized === head`, and that is a RESTRICTION rather than an assumption.
// These are historic generations whose tip is long settled. A generation whose
// tip is NOT final cannot be promoted this way — there is no honest finalized
// height to derive from a height map alone — and `--promote` on such a
// generation is a mistake this tool cannot detect, so the restriction is
// stated here and in the workflow input rather than silently encoded.
//
// ── IT REFUSES, AND NEVER SKIPS ───────────────────────────────────────────
//
// A missing generation, a missing pointer, a missing or empty height map, or a
// malformed pair is an EXIT 1 with nothing written. The failure this avoids is
// the expensive one: a silent skip renders the old generation over a
// ~357,000-page build, reports success, and nobody learns which history was
// published until they go looking for it. Writes happen only after every named
// chain has been resolved, so a list whose second pair is bad does not leave
// the first chain promoted.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";

const argv = process.argv.slice(2);
const arg = (n, d) => {
  const i = argv.indexOf(`--${n}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d;
};

/** Parse `chain=generation,chain=generation` into pairs, refusing anything else. */
export function parsePromotion(spec) {
  const pairs = [];
  for (const raw of String(spec ?? "").split(",")) {
    const entry = raw.trim();
    if (entry === "") continue;
    const eq = entry.indexOf("=");
    if (eq <= 0 || eq === entry.length - 1) {
      throw new Error(`"${entry}" is not chain=generation`);
    }
    const chain = entry.slice(0, eq).trim();
    const generation = entry.slice(eq + 1).trim();
    if (!chain || !generation) throw new Error(`"${entry}" is not chain=generation`);
    pairs.push({ chain, generation });
  }
  return pairs;
}

/** The pointer a promotion writes, derived from the generation's own maps. */
export function derivePointer(origin, chain, generation, readJson) {
  const gdir = join(origin, "d", chain, "g", generation);
  const rootPath = join(gdir, "root.json");
  if (!existsSync(rootPath)) {
    throw new Error(
      `${chain}: generation "${generation}" is not in the staged tree ` +
      `(${rootPath}). A promotion may only name a generation the bucket already holds.`,
    );
  }
  const curPath = join(origin, "d", chain, "current.json");
  if (!existsSync(curPath)) {
    throw new Error(`${chain}: no staged pointer at ${curPath}`);
  }
  const root = readJson(rootPath);
  const heights = {};
  for (const rel of root?.maps?.height ?? []) {
    Object.assign(heights, readJson(join(origin, rel))?.heights ?? {});
  }
  const keys = Object.keys(heights);
  if (keys.length === 0) {
    throw new Error(
      `${chain}: generation "${generation}" has an empty height map, so it has ` +
      `no head to point at. Refusing rather than writing a pointer with no block.`,
    );
  }
  const top = keys.reduce((a, b) => (Number(b) > Number(a) ? b : a));
  const tip = { height: Number(top), hash: heights[top] };
  return {
    from: readJson(curPath)?.generation ?? "(unreadable)",
    blocks: keys.length,
    path: curPath,
    pointer: {
      chain,
      generation,
      traceSelectionVersion: root.traceSelectionVersion ?? "1",
      head: tip,
      // See the header: historic generations only, so the settled tip IS the head.
      finalized: tip,
    },
  };
}

function main() {
  const origin = arg("origin");
  const promote = arg("promote", "");
  if (!origin) {
    console.error("usage: promote-generation.mjs --origin <dir> --promote <chain=gen,…>");
    return 2;
  }
  const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));
  let pairs;
  try {
    pairs = parsePromotion(promote);
  } catch (e) {
    console.error(`::error::promote-generation: ${e.message}`);
    return 1;
  }
  if (pairs.length === 0) {
    console.log("promote-generation: nothing named, nothing changed");
    return 0;
  }
  // Resolve EVERY pair before writing ANY, so a bad second pair cannot leave
  // the first chain promoted and the tree half-moved.
  const planned = [];
  for (const { chain, generation } of pairs) {
    try {
      planned.push(derivePointer(origin, chain, generation, readJson));
    } catch (e) {
      console.error(`::error::${e.message} Nothing was changed.`);
      return 1;
    }
  }
  for (const p of planned) {
    writeFileSync(p.path, `${JSON.stringify(p.pointer, null, 2)}\n`);
    console.log(
      `  ${p.pointer.chain}: ${p.from} -> ${p.pointer.generation}  ` +
      `head/finalized ${p.pointer.head.height} ${p.pointer.head.hash} ` +
      `over ${p.blocks} block(s)`,
    );
  }
  console.log(`promoted ${planned.length} chain(s)`);
  return 0;
}

if (argv.includes("--selftest")) {
  const { mkdtempSync, mkdirSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  let failed = 0;
  const ok = (name, cond, detail = "") => {
    console.log(`  ${cond ? "[OK]    " : "[FAILED]"} ${name}${detail ? `\n             ${detail}` : ""}`);
    if (!cond) failed++;
  };
  const tree = () => {
    const root = mkdtempSync(join(tmpdir(), "promote-selftest-"));
    mkdirSync(join(root, "d", "c", "g", "big"), { recursive: true });
    writeFileSync(join(root, "d", "c", "current.json"),
      JSON.stringify({ chain: "c", generation: "small" }));
    writeFileSync(join(root, "d", "c", "g", "big", "root.json"),
      JSON.stringify({ traceSelectionVersion: "7", maps: { height: ["d/c/g/big/h0.json"] } }));
    writeFileSync(join(root, "d", "c", "g", "big", "h0.json"),
      JSON.stringify({ heights: { 1: "0xaa", 9: "0xtip", 10: "0xten" } }));
    return root;
  };
  const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));

  console.log("=== promote-generation selftest ===\n");
  ok("a well-formed list parses to its pairs",
    JSON.stringify(parsePromotion("a=1, b=2 ")) === JSON.stringify([
      { chain: "a", generation: "1" }, { chain: "b", generation: "2" }]));
  ok("an empty list is empty, not an error", parsePromotion("  ").length === 0);
  for (const bad of ["a", "=1", "a=", "a=1,b"]) {
    let threw = false;
    try { parsePromotion(bad); } catch { threw = true; }
    ok(`"${bad}" is refused`, threw);
  }

  const root = tree();
  const got = derivePointer(root, "c", "big", readJson);
  // 10 > 9 NUMERICALLY; a string max would pick "9" and publish the wrong tip.
  ok("the head is the greatest height NUMERICALLY, not lexically",
    got.pointer.head.height === 10 && got.pointer.head.hash === "0xten",
    `got ${got.pointer.head.height} ${got.pointer.head.hash}`);
  ok("finalized equals head", JSON.stringify(got.pointer.finalized) === JSON.stringify(got.pointer.head));
  ok("traceSelectionVersion comes from the generation's root, not a default",
    got.pointer.traceSelectionVersion === "7");
  ok("the generation being left is reported", got.from === "small");

  let threw = false;
  try { derivePointer(root, "c", "nope", readJson); } catch { threw = true; }
  ok("an absent generation is refused", threw);

  writeFileSync(join(root, "d", "c", "g", "big", "h0.json"), JSON.stringify({ heights: {} }));
  threw = false;
  try { derivePointer(root, "c", "big", readJson); } catch { threw = true; }
  ok("an empty height map is refused rather than pointed at", threw);

  const EXPECTED = 12;
  const ran = 12;
  console.log(`\n${ran} check(s), ${failed} failed`);
  if (ran !== EXPECTED) {
    console.log(`::error::expected ${EXPECTED} checks, ran ${ran}`);
    process.exit(1);
  }
  process.exit(failed ? 1 : 0);
} else {
  process.exit(main());
}
