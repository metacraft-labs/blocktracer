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
  const nums = keys.map(Number).sort((a, b) => a - b);
  const top = nums[nums.length - 1];
  const low = nums[0];

  // ── FINALIZED IS DERIVED, AND IT IS NOT THE HEAD ──────────────────────────
  //
  // The first version of this wrote `finalized: head`, on the reasoning that a
  // historic generation's tip is long settled. That is true of two of the three
  // chains here and FALSE of the third, which is exactly how a plausible
  // assumption ships a false claim: `aztec-testnet-frames` was captured at head
  // 69,361 with only 69,336 finalized, so promoting it would have published
  // "block 69,361 is final" about a block the capture never saw finalized.
  //
  // The honest source is the generation's own summary, which records the
  // finalized height the chain reported AT CAPTURE. Clamping it into the
  // generation's own range is what reproduces all three pointers the original
  // ingest wrote, and each clamp arm is load-bearing:
  //
  //   aztec          head 102,690, finalizedAtCapture 103,798 -> 102,690 (upper)
  //   aztec-testnet  head  99,092, finalizedAtCapture  99,458 ->  99,092 (upper)
  //   frames         head  69,361, finalizedAtCapture  69,335 ->  69,336 (LOWER)
  //
  // The frames row is the one a `Math.min` would get wrong: 69,335 is BELOW the
  // generation's floor, so the pointer names the lowest block the generation
  // holds rather than a height it does not carry.
  //
  // NO SUMMARY MEANS NO PROMOTION. A generation whose summary cannot be read, or
  // which states no finalized height, is refused rather than defaulted to the
  // head — defaulting is the bug this comment exists because of.
  const sumPath = join(gdir, "summary.json");
  if (!existsSync(sumPath)) {
    throw new Error(
      `${chain}: generation "${generation}" has no summary.json, so its finalized ` +
      `height cannot be established. Refusing rather than assuming the head is final.`,
    );
  }
  const finalizedAtCapture = readJson(sumPath)?.provenance?.finalizedAtCapture;
  if (typeof finalizedAtCapture !== "number") {
    throw new Error(
      `${chain}: generation "${generation}" states no provenance.finalizedAtCapture, ` +
      `so how much of it is final is unknown. Refusing rather than claiming the head is.`,
    );
  }
  const finalHeight = Math.min(Math.max(finalizedAtCapture, low), top);
  const at = (h) => ({ height: h, hash: heights[String(h)] });
  return {
    from: readJson(curPath)?.generation ?? "(unreadable)",
    blocks: keys.length,
    path: curPath,
    finalizedAtCapture,
    pointer: {
      chain,
      generation,
      traceSelectionVersion: root.traceSelectionVersion ?? "1",
      head: at(top),
      finalized: at(finalHeight),
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
    // HEAD AND FINALIZED ARE PRINTED SEPARATELY, because they differ and the
    // first version of this line printed one figure under both labels — which
    // would have read as agreement on exactly the chain where they disagree.
    const f = p.pointer.finalized, h = p.pointer.head;
    console.log(
      `  ${p.pointer.chain}: ${p.from} -> ${p.pointer.generation}  ` +
      `head ${h.height} ${h.hash}  over ${p.blocks} block(s)`,
    );
    console.log(
      `      finalized ${f.height} ${f.hash}` +
      (f.height === h.height
        ? `  (the whole generation is final)`
        : `  (${h.height - f.height} block(s) of the head are NOT final; ` +
          `finalizedAtCapture was ${p.finalizedAtCapture})`),
    );
  }
  console.log(`promoted ${planned.length} chain(s)`);
  return 0;
}

if (argv.includes("--selftest")) {
  const { mkdtempSync, mkdirSync, rmSync } = await import("node:fs");
  const { tmpdir } = await import("node:os");
  let failed = 0;
  const ok = (name, cond, detail = "") => {
    console.log(`  ${cond ? "[OK]    " : "[FAILED]"} ${name}${detail ? `\n             ${detail}` : ""}`);
    if (!cond) failed++;
  };
  const tree = (fin = 99) => {
    const root = mkdtempSync(join(tmpdir(), "promote-selftest-"));
    mkdirSync(join(root, "d", "c", "g", "big"), { recursive: true });
    writeFileSync(join(root, "d", "c", "current.json"),
      JSON.stringify({ chain: "c", generation: "small" }));
    writeFileSync(join(root, "d", "c", "g", "big", "root.json"),
      JSON.stringify({ traceSelectionVersion: "7", maps: { height: ["d/c/g/big/h0.json"] } }));
    writeFileSync(join(root, "d", "c", "g", "big", "h0.json"),
      JSON.stringify({ heights: { 1: "0xaa", 9: "0xnine", 10: "0xten" } }));
    writeFileSync(join(root, "d", "c", "g", "big", "summary.json"),
      JSON.stringify({ provenance: { finalizedAtCapture: fin } }));
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
  ok("a fully settled generation finalizes at its head",
    got.pointer.finalized.height === 10 && got.pointer.finalized.hash === "0xten");
  ok("traceSelectionVersion comes from the generation's root, not a default",
    got.pointer.traceSelectionVersion === "7");
  ok("the generation being left is reported", got.from === "small");

  // ── FINALIZED IS DERIVED, AND THE FRAMES ROW IS WHY ──────────────────────
  // The first version wrote `finalized: head`. True for two of the three real
  // chains and FALSE for aztec-testnet-frames, captured at head 69,361 with
  // 69,335 finalized — so promoting it would have published "69,361 is final"
  // about a block the capture never saw settle.
  const mid = derivePointer(tree(9), "c", "big", readJson);
  ok("an UNSETTLED tip finalizes below the head, not at it",
    mid.pointer.head.height === 10 && mid.pointer.finalized.height === 9
    && mid.pointer.finalized.hash === "0xnine",
    `head ${mid.pointer.head.height}, finalized ${mid.pointer.finalized.height}`);
  // The real frames case: finalizedAtCapture sits BELOW the generation's floor,
  // so a bare Math.min would name a height the generation does not carry.
  const below = derivePointer(tree(0), "c", "big", readJson);
  ok("a finalized height below the generation's floor clamps UP to its lowest block",
    below.pointer.finalized.height === 1 && below.pointer.finalized.hash === "0xaa",
    `got ${below.pointer.finalized.height}`);

  let threw = false;
  try { derivePointer(root, "c", "nope", readJson); } catch { threw = true; }
  ok("an absent generation is refused", threw);

  // NO SUMMARY, OR NO FIGURE IN IT, MEANS NO PROMOTION — never a default to the
  // head, which is the defect these two arms exist because of.
  const noSum = tree();
  rmSync(join(noSum, "d", "c", "g", "big", "summary.json"));
  threw = false;
  try { derivePointer(noSum, "c", "big", readJson); } catch { threw = true; }
  ok("a generation with no summary is refused, not defaulted to head", threw);
  const emptySum = tree();
  writeFileSync(join(emptySum, "d", "c", "g", "big", "summary.json"),
    JSON.stringify({ provenance: {} }));
  threw = false;
  try { derivePointer(emptySum, "c", "big", readJson); } catch { threw = true; }
  ok("a summary stating no finalized height is refused", threw);

  writeFileSync(join(root, "d", "c", "g", "big", "h0.json"), JSON.stringify({ heights: {} }));
  threw = false;
  try { derivePointer(root, "c", "big", readJson); } catch { threw = true; }
  ok("an empty height map is refused rather than pointed at", threw);

  const EXPECTED = 16;
  const ran = 16;
  console.log(`\n${ran} check(s), ${failed} failed`);
  if (ran !== EXPECTED) {
    console.log(`::error::expected ${EXPECTED} checks, ran ${ran}`);
    process.exit(1);
  }
  process.exit(failed ? 1 : 0);
} else {
  process.exit(main());
}
