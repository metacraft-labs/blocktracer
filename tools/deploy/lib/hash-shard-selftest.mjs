#!/usr/bin/env node
// The self-test for `lib/hash-shard.mjs`.
//
//   node tools/deploy/lib/hash-shard-selftest.mjs
//
// ── WHY A FORMAT READER NEEDS ARMS ─────────────────────────────────────────────────────
//
// `hashshard.nim` writes TWO formats and tags each shard with which. A reader that knows
// only format 1 does not fail on a format-2 shard: it takes the encoding-dictionary count
// as part of the entry count's offset and returns confident nonsense. So the arms that
// matter most here are not "does it parse" but "does it tell the formats apart, and does
// it REFUSE what it cannot read instead of guessing".
//
// Journey 22 USED TO carry a second, inline, format-1-only reader, and two arms here
// pinned that duplication by requiring the two to agree on format 1 and disagree on
// format 2. The journey now imports this module — the migration was verified
// behaviour-preserving over the 288 published entries, same hex, chain, kind and chain
// set — so those arms have been replaced by the invariant they existed to protect:
// nothing outside this module and the Nim producer names the format's magic.
//
// Every shard below is built here, byte by byte, from the layout in the module's header.
// Nothing reads `client/dist`, which is a build output and not committed.

import { parseHashShard, encodeHashShard, routeFor, FMT_HEX_BYTES, FMT_KEY_FORM }
  from "./hash-shard.mjs";
import { dirname, resolve as resolvePath } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const HERE = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

// The builder is `encodeHashShard` in the module beside the reader: the layout is one
// piece of knowledge, and a builder that drifted from the reader would make every arm
// below agree with a format nothing publishes.
const shard = encodeHashShard;

/** Journey 22's reader, transcribed verbatim from its inline block — format-1 offsets,
 *  no encoding dictionary. Present so the two can be compared, not to be used. */
function journeyReader(bytes) {
  const d = bytes;
  if (String.fromCharCode(...d.subarray(0, 4)) !== "BThx") return null;
  const hashLen = d[6];
  const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
  const count = view.getUint32(8, true);
  let pos = 12;
  const names = [];
  for (let i = 0; i < d[7]; i++) {
    const n = d[pos++];
    names.push(new TextDecoder().decode(d.subarray(pos, pos + n)));
    pos += n;
  }
  const out = [];
  for (let i = 0; i < count; i++) {
    const hex = [...d.subarray(pos, pos + hashLen)].map((x) => x.toString(16).padStart(2, "0")).join("");
    pos += hashLen;
    out.push({ hex, chain: names[d[pos++]], kind: d[pos++] });
  }
  return out;
}

const A = "aa".repeat(32);
const ENDS_IN_ZERO = `${"bb".repeat(31)}b0`;

const arms = [
  ["format-1-parses-and-identifiers-carry-the-0x", () => {
    const s = shard({ fmt: FMT_HEX_BYTES, chains: ["demo", "aztec"],
                      entries: [{ hex: A, chainIndex: 0, kind: 1 },
                                { hex: "cc".repeat(32), chainIndex: 1, kind: 2 }] });
    const r = parseHashShard(s);
    return r.error === ""
        && r.fmt === FMT_HEX_BYTES
        && r.entries.length === 2
        && r.entries[0].identifier === `0x${A}`
        && r.entries[0].chain === "demo" && r.entries[0].kind === 1
        && r.entries[1].chain === "aztec" && r.entries[1].encoding === "hex";
  }],

  ["format-1-keeps-BOTH-readings-of-a-hash-ending-in-zero", () => {
    const s = shard({ fmt: FMT_HEX_BYTES, chains: ["demo"],
                      entries: [{ hex: ENDS_IN_ZERO, chainIndex: 0, kind: 1 }] });
    const e = parseHashShard(s).entries[0];
    // The strip is lossy and the format cannot say whether that zero was padding, so both
    // readings travel. 13 of this repository's 288 published entries need the second.
    return e.candidates.length === 2
        && e.candidates[0] === `0x${ENDS_IN_ZERO.replace(/0+$/, "")}`
        && e.candidates[1] === `0x${ENDS_IN_ZERO}`;
  }],

  ["format-2-parses-its-key-form-and-its-encoding-dictionary", () => {
    const s = shard({ fmt: FMT_KEY_FORM, unitLen: 16, chains: ["cardano"],
                      encodings: ["hex", "bech32"],
                      entries: [{ key: "addr1qxy", chainIndex: 0, encIndex: 1, kind: 3 }] });
    const r = parseHashShard(s);
    // The NUL strip is EXACT here — no alphabet in the closed set holds a NUL — so unlike
    // format 1 there is one reading and `candidates` is that one.
    return r.error === "" && r.fmt === FMT_KEY_FORM
        && r.entries[0].identifier === "addr1qxy"
        && r.entries[0].encoding === "bech32"
        && r.entries[0].candidates.length === 1
        && r.encodings.join(",") === "hex,bech32";
  }],

  ["this-module-is-the-only-reader-of-the-format", () => {
    // WHAT THE TWO ARMS HERE USED TO DO. Journey 22 carried a second, inline,
    // format-1-only reader, and those arms required the two to agree on format 1 and
    // disagree on format 2 — pinning a duplication rather than removing it. The journey
    // now imports this module (verified behaviour-preserving over the 288 published
    // entries: same hex, same chain, same kind, same chain set), so the duplication is
    // gone and the arms that bounded it would now be testing a transcription inside this
    // file. This is their successor: the invariant they were protecting, asserted
    // directly.
    //
    // The magic is the tell. A file that hand-rolls this layout has to name "BThx" to
    // recognise it, so a new decoder cannot appear without tripping this.
    const { execFileSync } = require("node:child_process");
    const root = resolvePath(HERE, "..", "..", "..");
    let hits = [];
    try {
      hits = execFileSync("git", ["grep", "-l", "BThx", "--", "tools", "client", "src"],
                          { cwd: root, encoding: "utf8" }).trim().split("\n").filter(Boolean);
    } catch (e) {
      // `git grep` exits 1 on no match, which cannot be right — this file names it.
      return false;
    }
    const allowed = new Set([
      "tools/deploy/lib/hash-shard.mjs",            // the reader and the writer
      "tools/deploy/lib/hash-shard-selftest.mjs",   // this file, which names it above
      "src/blocktracer/contract/hashshard.nim",     // the producer, which owns the format
    ]);
    const strays = hits.filter((h) => !allowed.has(h));
    if (strays.length) console.log(`        stray reader(s): ${strays.join(", ")}`);
    return strays.length === 0 && hits.length >= 2;
  }],

  ["an-unknown-format-is-refused-BY-NAME-not-as-a-non-shard", () => {
    const s = shard({ fmt: 7, chains: ["demo"], entries: [{ hex: A, chainIndex: 0, kind: 1 }] });
    const r = parseHashShard(s);
    // Two different negative answers. Collapsing them turns "please reload" into "not
    // found", which the format's own §6.1 forbids.
    return r.error === "unsupported-format" && /format 7/.test(r.detail);
  }],

  ["bytes-that-are-not-a-shard-say-so", () => {
    const r = parseHashShard(new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]));
    return r.error === "not-a-shard";
  }],

  ["a-truncated-shard-is-truncated-and-not-a-small-one", () => {
    const s = shard({ fmt: FMT_HEX_BYTES, chains: ["demo"],
                      entries: [{ hex: A, chainIndex: 0, kind: 1 },
                                { hex: "cc".repeat(32), chainIndex: 0, kind: 1 }] });
    const r = parseHashShard(s.subarray(0, s.length - 10));
    // A half-written index must not read as a complete smaller one — that is the exact
    // shape of green-and-wrong the gates over this exist to refuse.
    return r.error === "truncated" && /entry 1 of 2/.test(r.detail) && r.entries.length === 0;
  }],

  ["a-chain-index-past-the-dictionary-is-refused", () => {
    const s = shard({ fmt: FMT_HEX_BYTES, chains: ["demo"],
                      entries: [{ hex: A, chainIndex: 4, kind: 1 }] });
    return parseHashShard(s).error === "bad-entry";
  }],

  ["an-encoding-index-past-the-dictionary-is-refused", () => {
    const s = shard({ fmt: FMT_KEY_FORM, unitLen: 8, chains: ["demo"], encodings: ["hex"],
                      entries: [{ key: "abc", chainIndex: 0, encIndex: 3, kind: 1 }] });
    return parseHashShard(s).error === "bad-entry";
  }],

  ["routeFor-maps-the-three-kinds-and-refuses-a-fourth", () => {
    return routeFor("demo", 1, "0xab") === "demo/tx/0xab"
        && routeFor("demo", 2, "0xab") === "demo/block/0xab"
        && routeFor("demo", 3, "0xab") === "demo/address/0xab"
        // A guessed segment would make a gate assert a page that was never meant to exist.
        && routeFor("demo", 9, "0xab") === null;
  }],
];

let failures = 0;
for (const [name, fn] of arms) {
  let ok = false, why = "";
  try { ok = fn() === true; } catch (e) { why = ` (threw: ${e.message})`; }
  if (ok) console.log(`  ok    ${name}`);
  else { failures += 1; console.log(`  FAIL  ${name}${why}`); }
}
const asserted = arms.length;
if (asserted !== 10) {
  console.log(`  FAIL  this suite declares 10 arms and ran ${asserted}`);
  failures += 1;
}
console.log(failures === 0
  ? `\nall ${asserted} arms decided as written.`
  : `\n${failures} of ${asserted} arms did not decide as written.`);
process.exit(failures === 0 ? 0 : 1);
