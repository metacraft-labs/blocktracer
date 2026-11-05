#!/usr/bin/env node
// The self-test for `check-no-stale-neighbours.mjs`.
//
//   node tools/deploy/check-no-stale-neighbours-selftest.mjs
//
// ── THE BAR ───────────────────────────────────────────────────────────────────────────
//
// The gate guards a publish mode this repository has not run yet, so it has nothing to
// catch today and no incident to point at. That makes these arms the ONLY evidence it
// does anything at all — `docs/INCREMENTAL-PUBLISH.md` §5 says the gate must exist before
// the first incremental publish "not after", and a gate landed early with no arms is
// indistinguishable from a comment.
//
// Each arm builds a synthetic published tree, applies ONE mutation, and asserts the
// SENTENCE that names it. Four invert it and require a PASS: the control, a page that
// lives only in the staged bucket, a hash whose last byte is zero, and a stale neighbour
// that sits OUTSIDE the `--routes` set. The last two are the false positives that would
// have got this switched off — the zero one bit the real tree during development, where a
// naive reading reported 13 stale neighbours over 288 clean entries.

import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { encodeHashShard, FMT_HEX_BYTES } from "./lib/hash-shard.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const CHECKER = join(HERE, "check-no-stale-neighbours.mjs");

const CHAIN = "aztec-testnet";
const TX_A = "a".repeat(64);
const TX_B = "b".repeat(64);
const TX_ZERO = `${"c".repeat(63)}0`;   // a hash whose last nibble is a real zero

const write = (root, rel, body) => {
  const p = join(root, rel);
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, body);
};

/** A page that draws links to each of `targets` (bare hex, no 0x). */
const listPage = (chain, targets) =>
  `<!doctype html><html><body><ul>${targets
    .map((h) => `<li><a href="/${chain}/tx/0x${h}">0x${h}</a></li>`)
    .join("")}</ul></body></html>`;

/**
 * Build a tree. `indexed` and `paged` are deliberately separate so an arm can make the
 * index name something the tree does not hold, and vice versa.
 */
function build(root, {
  indexed = [TX_A, TX_B], paged = [TX_A, TX_B], drawn = [TX_A, TX_B],
  pagesIn = root, meta = null, shardBytes = null, chain = CHAIN,
} = {}) {
  const shard = shardBytes ?? encodeHashShard({
    fmt: FMT_HEX_BYTES, chains: [chain],
    entries: indexed.map((h) => ({ hex: h, chainIndex: 0, kind: 1 })),
  });
  write(root, "idx/hash/1/aa.bin", Buffer.from(shard));
  const declared = meta ?? { indexVersion: "1", prefixLen: 2, shardCount: 1,
                             entryCount: indexed.length };
  if (declared !== "omit") write(root, "idx/hash/meta.json", JSON.stringify(declared));
  for (const h of paged) write(pagesIn, `${chain}/tx/0x${h}/index.html`, "<html>tx</html>");
  write(root, `${chain}/txs/index.html`, listPage(chain, drawn));
}

const arms = [
  { name: "control-a-whole-tree-passes", pass: true, setup: (r) => build(r),
    says: /2 index entry\/entries over 1 shard\(s\) resolve.*2 distinct target\(s\)/ },

  { name: "the-index-names-a-page-the-tree-does-not-hold",
    setup: (r) => build(r, { indexed: [TX_A, TX_B], paged: [TX_A], drawn: [TX_A] }),
    says: /index resolves aztec-testnet 0xbbb.* and no root holds a page for it/ },

  { name: "a-list-page-draws-a-row-with-no-page",
    setup: (r) => build(r, { indexed: [TX_A], paged: [TX_A], drawn: [TX_A, TX_B] }),
    says: /aztec-testnet\/txs\/index\.html draws \/aztec-testnet\/tx\/0xbbb.* and no root holds/ },

  { name: "a-hash-ending-in-a-real-zero-still-resolves", pass: true,
    // 13 of the real tree's 288 entries are this shape. A gate taking the stripped
    // identifier alone called them stale; `candidates` is why this passes.
    setup: (r) => build(r, { indexed: [TX_ZERO], paged: [TX_ZERO], drawn: [TX_ZERO] }),
    says: /1 index entry\/entries over 1 shard\(s\) resolve/ },

  { name: "a-page-that-lives-only-in-the-staged-bucket-is-not-missing", pass: true,
    useOrigin: true,
    setup: (r, origin) => { mkdirSync(origin, { recursive: true }); build(r, { pagesIn: origin }); },
    says: /2 distinct target\(s\) drawn by/ },

  // ── rule C: the index against its own declaration ─────────────────────────────────
  { name: "metajson-entryCount-disagreeing-with-the-shards-is-a-failure",
    setup: (r) => build(r, { meta: { indexVersion: "1", shardCount: 1, entryCount: 99 } }),
    says: /declares entryCount 99 and the shards under 1\/ decode to 2/ },

  { name: "metajson-shardCount-disagreeing-is-a-failure",
    setup: (r) => build(r, { meta: { indexVersion: "1", shardCount: 7, entryCount: 2 } }),
    says: /declares shardCount 7 and idx\/hash\/1\/ holds 1 shard file/ },

  { name: "no-metajson-means-the-partial-index-comparison-cannot-be-made",
    setup: (r) => build(r, { meta: "omit" }),
    says: /the one comparison that catches a partial index/ },

  { name: "a-truncated-shard-is-reported-as-truncated",
    setup: (r) => {
      const full = encodeHashShard({ fmt: FMT_HEX_BYTES, chains: [CHAIN],
        entries: [TX_A, TX_B].map((h) => ({ hex: h, chainIndex: 0, kind: 1 })) });
      build(r, { shardBytes: full.subarray(0, full.length - 8) });
    },
    says: /truncated — entry 1 of 2 runs past the end/ },

  // ── the vacuity refusals ──────────────────────────────────────────────────────────
  { name: "no-index-at-all-refuses-rather-than-skipping-rule-A",
    setup: (r) => { build(r); rmSync(join(r, "idx"), { recursive: true }); },
    says: /no idx\/hash\/<version>\/ in this tree, so rule A would check nothing/ },

  { name: "an-index-of-zero-entries-measured-nothing",
    setup: (r) => build(r, { indexed: [], paged: [TX_A], drawn: [TX_A],
                             meta: { indexVersion: "1", shardCount: 1, entryCount: 0 } }),
    says: /decoded to zero entries, so rule A measured nothing/ },

  { name: "pages-that-draw-nothing-measured-nothing",
    setup: (r) => build(r, { drawn: [] }),
    says: /draws an entity link, so rule B measured nothing/ },

  // ── the incremental set ───────────────────────────────────────────────────────────
  { name: "routes-confines-rule-B-to-the-set-that-was-republished", pass: true,
    // THE INCREMENTAL SEMANTICS. A stale neighbour drawn by a page OUTSIDE the set is not
    // this publish's business — §5 states the rule "over the incremental set rather than
    // the whole site" — so this must stay GREEN while the sibling arm below goes red.
    setup: (r) => {
      build(r, { indexed: [TX_A], paged: [TX_A], drawn: [TX_A] });
      write(r, `${CHAIN}/blocks/index.html`, listPage(CHAIN, [TX_B]));
      write(r, "routes.txt", `${CHAIN}/txs/index.html\n`);
    },
    args: (r) => ["--routes", join(r, "routes.txt")],
    says: /1 distinct target\(s\) drawn by 1 page\(s\)/ },

  { name: "...-and-a-stale-neighbour-INSIDE-the-set-is-still-reported",
    setup: (r) => {
      build(r, { indexed: [TX_A], paged: [TX_A], drawn: [TX_A, TX_B] });
      write(r, "routes.txt", `${CHAIN}/txs/index.html\n`);
    },
    args: (r) => ["--routes", join(r, "routes.txt")],
    says: /draws \/aztec-testnet\/tx\/0xbbb/ },

  { name: "a-routes-file-matching-no-page-refuses",
    setup: (r) => { build(r); write(r, "routes.txt", "nowhere/at/all/index.html\n"); },
    args: (r) => ["--routes", join(r, "routes.txt")],
    says: /matched none of the \d+ HTML pages/ },

  { name: "an-empty-routes-file-refuses",
    setup: (r) => { build(r); write(r, "routes.txt", "\n\n"); },
    args: (r) => ["--routes", join(r, "routes.txt")],
    says: /names no routes, so rule B would scan nothing/ },
];

let failures = 0;
for (const arm of arms) {
  const root = mkdtempSync(join(tmpdir(), "staleneigh-"));
  const origin = `${root}-origin`;
  const problems = [];
  try {
    arm.setup(root, origin);
    const args = [CHECKER, "--dir", root,
                  ...(arm.useOrigin ? ["--live-origin", origin] : []),
                  ...(arm.args ? arm.args(root) : [])];
    const r = spawnSync(process.execPath, args, { encoding: "utf8", timeout: 30_000 });
    const out = `${r.stdout}${r.stderr}`;
    const want = arm.pass ? 0 : 1;
    if (r.status !== want) problems.push(`exit ${r.status}, wanted ${want}`);
    if (!arm.says.test(out)) {
      problems.push(`the sentence did not match ${arm.says}`);
      problems.push(`  got: ${out.trim().split("\n").slice(-3).join(" / ").slice(0, 240)}`);
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
    console.log(`  ok    ${arm.name}${arm.pass ? "  (must PASS)" : ""}`);
  }
}
const asserted = arms.length;
if (asserted !== 16) {
  console.log(`  FAIL  this suite declares 16 arms and ran ${asserted}`);
  failures += 1;
}
console.log(failures === 0
  ? `\nall ${asserted} arms decided as written.`
  : `\n${failures} of ${asserted} arms did not decide as written.`);
process.exit(failures === 0 ? 0 : 1);
