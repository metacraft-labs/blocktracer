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
// naive reading reported 13 stale neighbours over 288 clean entries. (Nine require a PASS
// now: the identifier-shape arms added on 2026-11-07, and the ledger-version index's
// control, joined those four.)

import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { encodeHashShard, FMT_HEX_BYTES, FMT_KEY_FORM, LEGACY_ENCODING } from "./lib/hash-shard.mjs";
import { encodeVersionShard, versionBucket } from "./lib/version-shard.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const CHECKER = join(HERE, "check-no-stale-neighbours.mjs");

const CHAIN = "aztec-testnet";
const TX_A = "a".repeat(64);
const TX_B = "b".repeat(64);
const TX_ZERO = `${"c".repeat(63)}0`;   // a hash whose last nibble is a real zero
const TX_C = "d".repeat(64);            // in the v2 index only, as a non-hex encoding is

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
  pagesIn = root, meta = null, shardBytes = null, chain = CHAIN, v2 = null,
} = {}) {
  const shard = shardBytes ?? encodeHashShard({
    fmt: FMT_HEX_BYTES, chains: [chain],
    entries: indexed.map((h) => ({ hex: h, chainIndex: 0, kind: 1 })),
  });
  write(root, "idx/hash/1/aa.bin", Buffer.from(shard));

  // THE SECOND FORMAT, WHICH THIS SUITE HAD NO FIXTURE FOR UNTIL 2026-11-07 — and that
  // absence is the whole reason the per-version bug shipped. A real two-version publish
  // does NOT hold the same entries in both: `client/src/static_export.nim` fills v1 from
  // `hexEntries` and v2 from `entries`, every encoding, so v2 is a SUPERSET. An arm whose
  // two versions agreed on their counts would exercise the loop and still never compare a
  // v1 declaration against v2 shards, which is the comparison that was wrong.
  const v2indexed = v2 ? (v2.indexed ?? indexed) : null;
  if (v2) {
    const v2shard = encodeHashShard({
      fmt: FMT_KEY_FORM, unitLen: 66, prefixLen: 2, chains: [chain],
      encodings: [LEGACY_ENCODING],
      entries: v2indexed.map((h) => ({ key: `0x${h}`, chainIndex: 0, encIndex: 0, kind: 1 })),
    });
    write(root, "idx/hash/2/aa.bin", Buffer.from(v2shard));
  }

  const declared = meta ?? (v2
    // Shaped as the writer shapes it: the top-level fields describe v1, and `versions`
    // appears ONLY when there is a second version, carrying each version's own counts.
    ? { indexVersion: "1", prefixLen: 2, shardCount: 1, entryCount: indexed.length,
        preferredVersion: "2",
        versions: [
          { version: "1", format: 1, prefixLen: 2, shardCount: 1,
            entryCount: indexed.length },
          { version: "2", format: 2, prefixLen: 2, shardCount: 1,
            entryCount: v2indexed.length },
        ] }
    : { indexVersion: "1", prefixLen: 2, shardCount: 1, entryCount: indexed.length });
  if (declared !== "omit") write(root, "idx/hash/meta.json", JSON.stringify(declared));
  for (const h of paged) write(pagesIn, `${chain}/tx/0x${h}/index.html`, "<html>tx</html>");
  write(root, `${chain}/txs/index.html`, listPage(chain, drawn));
}

// ── THE LEDGER-VERSION INDEX, ONE FIXTURE PER SHAPE A VERSION ACTUALLY TAKES ───────────
//
// The campaign session's lesson, applied before the bug rather than after it: both
// hash-index defects of 2026-11-07 shipped because every fixture was a full-width hash. A
// version's shapes are its LENGTH and where it sits against a bucket edge, so the corpus is
// one of each: a one-digit version (bucket `0`), the two sides of the first bucket edge
// (9999 | 10000), two neighbours sharing a bucket (the published Aptos window's first two),
// two versions above 2^53 that a Number would read as ONE, and the u64 maximum.
const APT = "aptos-mainnet";
const DIGITS = 4;
const VERSIONS = ["7", "9999", "10000", "7881330395", "7881330396",
                  "9007199254740992", "9007199254740993", "18446744073709551615"];
/** A distinct full-width Aptos hash per version, as the route names it. */
const hashOf = (v) => `0x${[...v.padStart(64, "0")].map((c) => "abcdef0123"[Number(c)]).join("")}`;

/**
 * Add `idx/aptos-mainnet/version/` to a tree `build` made. `entries` defaults to every
 * shape above, each in the bucket `versionBucket` names, unless an entry says `bucket`.
 * `paged` is which versions get a transaction page; `meta` replaces the descriptor the
 * writer would publish (or `"omit"`); `digitsIn` is the bucket width written INTO shards.
 */
function versionIndex(root, {
  entries = VERSIONS.map((v) => ({ version: v, identifier: hashOf(v) })),
  paged = VERSIONS, meta = null, digitsIn = DIGITS, truncate = "",
} = {}) {
  const byBucket = new Map();
  for (const e of entries) {
    const b = e.bucket ?? versionBucket(e.version, DIGITS);
    if (!byBucket.has(b)) byBucket.set(b, []);
    byBucket.get(b).push({ version: e.version, identifier: e.identifier });
  }
  for (const [b, es] of byBucket) {
    let bytes = encodeVersionShard(es, digitsIn);
    if (b === truncate) bytes = bytes.subarray(0, bytes.length - 5);
    write(root, `idx/${APT}/version/1/${b}.bin`, Buffer.from(bytes));
  }
  const declared = meta ?? {
    indexVersion: "1", format: 1, ordering: "globalVersion", bucketDigits: DIGITS,
    shardCount: byBucket.size, entryCount: entries.length, shards: [...byBucket.keys()],
  };
  if (declared !== "omit") write(root, `idx/${APT}/version/meta.json`, JSON.stringify(declared));
  for (const v of paged) write(root, `${APT}/tx/${hashOf(v)}/index.html`, "<html>tx</html>");
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

  // ── the kind-3 shape that produced 22 false stale neighbours on the real tree ──────
  // bt-move-f0, 2026-11-07: every one was an address whose last hex digit is 0, published
  // and paged correctly, reported stale because the reader offered no whole-byte reading
  // at the address's true width. An address is 20 bytes in a 32-byte unit, so it is
  // ZERO-PADDED — a shape no arm in this suite carried.
  { name: "a-padded-address-ending-in-a-zero-nibble-resolves", pass: true,
    setup: (r) => {
      const ADDR = `${"e7".repeat(19)}40`;          // 20 bytes, last byte 0x40
      const sh = encodeHashShard({ fmt: FMT_HEX_BYTES, chains: [CHAIN],
        entries: [{ hex: ADDR, chainIndex: 0, kind: 3 }] });
      write(r, "idx/hash/1/aa.bin", Buffer.from(sh));
      write(r, "idx/hash/meta.json", JSON.stringify(
        { indexVersion: "1", prefixLen: 2, shardCount: 1, entryCount: 1 }));
      write(r, `${CHAIN}/address/0x${ADDR}/index.html`, "<html>addr</html>");
      // rule B needs a page that draws an entity link, or it refuses for vacuity
      write(r, `${CHAIN}/tx/0x${TX_A}/index.html`, "<html>tx</html>");
      write(r, `${CHAIN}/txs/index.html`, listPage(CHAIN, [TX_A]));
    },
    says: /1 index entry\/entries over 1 shard\(s\) resolve/ },

  // ── the 18 odd-length reports of 2026-11-07 ───────────────────────────────────────
  // These resolved under the ORIGINAL two-element set and were regressed by the
  // whole-byte-only set that replaced it, so they are the arms that keep the third set
  // honest in both directions.
  { name: "an-odd-length-starknet-felt-resolves", pass: true,
    setup: (r) => {
      // 63 hex chars: a felt written without its leading zero nibble, as Starknet does.
      const FELT = "295683d081359be8f7b3d2f7384d2e2c56bf683c14543cfb5b1f6729849c79d";
      const sh = encodeHashShard({ fmt: FMT_HEX_BYTES, chains: ["starknet-mainnet"],
        entries: [{ hex: FELT, chainIndex: 0, kind: 1 }] });
      write(r, "idx/hash/1/aa.bin", Buffer.from(sh));
      write(r, "idx/hash/meta.json", JSON.stringify(
        { indexVersion: "1", prefixLen: 2, shardCount: 1, entryCount: 1 }));
      write(r, `starknet-mainnet/tx/0x${FELT}/index.html`, "<html>tx</html>");
      write(r, "starknet-mainnet/txs/index.html",
        `<!doctype html><html><body><a href="/starknet-mainnet/tx/0x${FELT}">x</a></body></html>`);
    },
    says: /1 index entry\/entries over 1 shard\(s\) resolve/ },

  { name: "a-one-digit-aptos-framework-address-resolves", pass: true,
    setup: (r) => {
      const sh = encodeHashShard({ fmt: FMT_HEX_BYTES, chains: ["aptos-mainnet"],
        entries: [{ hex: "1", chainIndex: 0, kind: 3 }] });
      write(r, "idx/hash/1/aa.bin", Buffer.from(sh));
      write(r, "idx/hash/meta.json", JSON.stringify(
        { indexVersion: "1", prefixLen: 2, shardCount: 1, entryCount: 1 }));
      write(r, "aptos-mainnet/address/0x1/index.html", "<html>addr</html>");
      // rule B needs a drawn entity link or it refuses for vacuity
      write(r, `aptos-mainnet/tx/0x${TX_A}/index.html`, "<html>tx</html>");
      write(r, "aptos-mainnet/txs/index.html", listPage("aptos-mainnet", [TX_A]));
    },
    says: /1 index entry\/entries over 1 shard\(s\) resolve/ },

  // ── rule C across TWO index versions ──────────────────────────────────────────────
  // Reported by bt-move-f0 on 2026-11-07: the gate reddened on every tree publishing a
  // second-format index, including trees built before their Aptos work. The cause was
  // that `metaPath` was computed inside the per-version loop but did not depend on the
  // version, so v1's declared counts were compared against v2's shards. v2 is a superset,
  // so that comparison could not pass.
  { name: "a-two-version-index-passes", pass: true,
    setup: (r) => build(r, { indexed: [TX_A, TX_B], paged: [TX_A, TX_B, TX_C],
                             drawn: [TX_A, TX_B], v2: { indexed: [TX_A, TX_B, TX_C] } }),
    says: /index 2: 1 shard\(s\), 3 entry\/entries/ },

  // THE ARM THAT STOPS THE FIX BEING A SKIP. A "fix" that simply ignored any version the
  // top-level fields do not describe would turn the arm above green while checking v2
  // against nothing at all — the same silent pass rule C exists to refuse. This one fails
  // unless the v2 declaration is really read and really compared.
  { name: "metajson-v2-entryCount-disagreeing-with-the-v2-shards-is-a-failure",
    setup: (r) => build(r, {
      indexed: [TX_A, TX_B], paged: [TX_A, TX_B, TX_C], drawn: [TX_A, TX_B],
      v2: { indexed: [TX_A, TX_B, TX_C] },
      meta: { indexVersion: "1", prefixLen: 2, shardCount: 1, entryCount: 2,
              preferredVersion: "2",
              versions: [
                { version: "1", format: 1, prefixLen: 2, shardCount: 1, entryCount: 2 },
                { version: "2", format: 2, prefixLen: 2, shardCount: 1, entryCount: 99 },
              ] },
    }),
    says: /versions\[2\] declares entryCount 99 and the shards under 2\/ decode to 3/ },

  // A served index with no declaration is the hole the lookup could otherwise open: it
  // must be NAMED, not skipped.
  { name: "a-version-directory-metajson-describes-is-not-silently-skipped",
    setup: (r) => {
      build(r, { indexed: [TX_A, TX_B], paged: [TX_A, TX_B, TX_C], drawn: [TX_A, TX_B],
                 v2: { indexed: [TX_A, TX_B, TX_C] } });
      // a third version appears in the tree that meta.json says nothing about
      const third = encodeHashShard({ fmt: FMT_HEX_BYTES, chains: [CHAIN],
        entries: [{ hex: TX_A, chainIndex: 0, kind: 1 }] });
      write(r, "idx/hash/3/aa.bin", Buffer.from(third));
    },
    says: /idx\/hash\/3\/ is served and idx\/hash\/meta\.json declares no version 3/ },

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

  // ── the ledger-version index (rule A and rule C over `idx/{chain}/version/`) ─────────
  { name: "a-version-index-of-every-shape-resolves", pass: true,
    // Five buckets, eight versions, and NO duplicate reported for the two above 2^53 —
    // which a reader comparing Numbers would have merged.
    setup: (r) => { build(r); versionIndex(r); },
    says: /version index aptos-mainnet 1: 5 bucket\(s\), 8 version\(s\), 7\.\.18446744073709551615[\s\S]*8 ledger version\(s\) over 5 bucket\(s\) of 1 chain\(s\) resolve/ },

  { name: "a-version-whose-transaction-page-is-missing",
    setup: (r) => { build(r); versionIndex(r, { paged: VERSIONS.filter((v) => v !== "7881330396") }); },
    says: /version index resolves aptos-mainnet 7881330396 to 0x\w+ and no root holds a page/ },

  { name: "a-version-above-2^53-is-named-exactly-when-its-page-is-missing",
    // Named by its own digits: a reader that went through a Number would report
    // 9007199254740992 here, which IS paged, and send the operator to the wrong row.
    setup: (r) => { build(r); versionIndex(r, { paged: VERSIONS.filter((v) => v !== "9007199254740993") }); },
    says: /version index resolves aptos-mainnet 9007199254740993 to 0x\w+ and no root/ },

  { name: "a-one-digit-version-whose-page-is-missing",
    setup: (r) => { build(r); versionIndex(r, { paged: VERSIONS.filter((v) => v !== "7") }); },
    says: /version index resolves aptos-mainnet 7 to 0x\w+ and no root holds a page/ },

  { name: "a-version-filed-on-the-wrong-side-of-a-bucket-edge",
    // 10000 is the first version of bucket 1. Written into bucket 0's file, a query for
    // it reads 1.bin and never finds it.
    setup: (r) => {
      build(r);
      versionIndex(r, { entries: VERSIONS.map((v) => ({ version: v, identifier: hashOf(v),
        ...(v === "10000" ? { bucket: "0" } : {}) })) });
    },
    says: /0\.bin holds version 10000, which falls in bucket 1/ },

  { name: "a-version-twice-in-one-bucket-is-a-duplicate",
    // The control for the 2^53 arm above: the duplicate check is live, so that arm's
    // silence is a measurement and not an absence.
    setup: (r) => {
      build(r);
      versionIndex(r, { entries: [...VERSIONS, "7881330395"].map((v, i) => ({ version: v,
        identifier: i === VERSIONS.length ? hashOf("1") : hashOf(v) })) });
    },
    says: /version 7881330395 of aptos-mainnet is in the index twice/ },

  { name: "version-metajson-entryCount-disagreeing-with-the-shards-is-a-failure",
    setup: (r) => {
      build(r);
      versionIndex(r, { meta: { indexVersion: "1", bucketDigits: DIGITS, shardCount: 5,
        entryCount: 99, shards: ["0", "1", "788133", "900719925474", "1844674407370955"] } });
    },
    says: /version\/meta\.json declares entryCount 99 and the shards under 1\/ decode to 8/ },

  { name: "version-metajson-listing-a-bucket-that-is-not-on-disk",
    setup: (r) => {
      build(r);
      versionIndex(r, { meta: { indexVersion: "1", bucketDigits: DIGITS, shardCount: 5,
        entryCount: 8,
        shards: ["0", "1", "42", "788133", "900719925474", "1844674407370955"] } });
    },
    says: /lists bucket 42 and idx\/aptos-mainnet\/version\/1\/ holds no 42\.bin/ },

  { name: "a-version-bucket-on-disk-that-metajson-does-not-list",
    setup: (r) => {
      build(r);
      versionIndex(r, { meta: { indexVersion: "1", bucketDigits: DIGITS, shardCount: 5,
        entryCount: 8, shards: ["0", "788133", "900719925474", "1844674407370955"] } });
    },
    says: /1\/1\.bin is served and idx\/aptos-mainnet\/version\/meta\.json does not list bucket 1/ },

  { name: "a-version-shard-written-at-another-bucket-width",
    setup: (r) => { build(r); versionIndex(r, { digitsIn: 3 }); },
    says: /was written with bucketDigits 3 and idx\/aptos-mainnet\/version\/meta\.json declares 4/ },

  { name: "a-non-canonical-version-is-unreachable",
    setup: (r) => {
      build(r);
      versionIndex(r, { entries: VERSIONS.map((v) => ({ version: v === "7" ? "007" : v,
        identifier: hashOf(v), bucket: versionBucket(v, DIGITS) })) });
    },
    says: /holds version "007", which is not a canonical u64 decimal/ },

  { name: "a-truncated-version-shard-is-reported-as-truncated",
    setup: (r) => { build(r); versionIndex(r, { truncate: "788133" }); },
    says: /788133\.bin: truncated — entry 1 of 2 runs past the end/ },

  { name: "a-version-index-with-no-metajson-cannot-be-checked",
    setup: (r) => { build(r); versionIndex(r, { meta: "omit" }); },
    says: /version\/meta\.json is missing or unreadable, so the version index of aptos-mainnet/ },

  { name: "a-second-version-index-directory-metajson-does-not-describe",
    setup: (r) => {
      build(r); versionIndex(r);
      write(r, `idx/${APT}/version/2/0.bin`,
        Buffer.from(encodeVersionShard([{ version: "7", identifier: hashOf("7") }], DIGITS)));
    },
    says: /idx\/aptos-mainnet\/version\/2\/ is served and .* declares indexVersion 1/ },

  { name: "a-version-index-of-zero-entries-measured-nothing",
    setup: (r) => { build(r); versionIndex(r, { entries: [], paged: [] }); },
    says: /version index of aptos-mainnet decoded to zero entries/ },
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
if (asserted !== 37) {
  console.log(`  FAIL  this suite declares 37 arms and ran ${asserted}`);
  failures += 1;
}
console.log(failures === 0
  ? `\nall ${asserted} arms decided as written.`
  : `\n${failures} of ${asserted} arms did not decide as written.`);
process.exit(failures === 0 ? 0 : 1);
