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
// `tools/journeys/journeys/22-a-remembered-fragment-of-a-hash-finds-it.journey.mjs`
// carries a second, inline reader for this format, format-1 only. Arm
// `the-journeys-inline-reader-agrees-on-format-1` runs that reader's exact offsets beside
// this module's and requires them to agree, and
// `...-and-would-mis-parse-format-2` requires them to DISAGREE on a format-2 shard —
// which is the measurement that says the duplication is real and bounded rather than
// harmless. Moving the journey onto this module is the follow-up; until then these two
// arms are what stops the copy drifting in silence.
//
// Every shard below is built here, byte by byte, from the layout in the module's header.
// Nothing reads `client/dist`, which is a build output and not committed.

import { parseHashShard, routeFor, FMT_HEX_BYTES, FMT_KEY_FORM } from "./hash-shard.mjs";

const u8 = (n) => [n & 0xff];
const u32le = (n) => [n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff];
const str8 = (s) => [s.length, ...[...Buffer.from(s, "utf8")]];
const hexBytes = (hex) => [...Buffer.from(hex, "hex")];

/** Build a shard of either format from the layout the module documents. */
function shard({ fmt, unitLen = 32, prefixLen = 2, chains, encodings = [], entries }) {
  const b = [...Buffer.from("BThx", "ascii"), ...u8(fmt), ...u8(prefixLen), ...u8(unitLen),
             ...u8(chains.length)];
  if (fmt === FMT_KEY_FORM) b.push(...u8(encodings.length));
  b.push(...u32le(entries.length));
  for (const c of chains) b.push(...str8(c));
  if (fmt === FMT_KEY_FORM) for (const e of encodings) b.push(...str8(e));
  for (const e of entries) {
    const unit = fmt === FMT_KEY_FORM
      ? [...Buffer.from(e.key, "utf8"), ...new Array(Math.max(0, unitLen - e.key.length)).fill(0)]
      : hexBytes(e.hex.padEnd(unitLen * 2, "0"));
    b.push(...unit.slice(0, unitLen), ...u8(e.chainIndex));
    if (fmt === FMT_KEY_FORM) b.push(...u8(e.encIndex ?? 0));
    b.push(...u8(e.kind));
  }
  return new Uint8Array(b);
}

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

  ["the-journeys-inline-reader-agrees-on-format-1", () => {
    const s = shard({ fmt: FMT_HEX_BYTES, chains: ["demo", "aztec"],
                      entries: [{ hex: A, chainIndex: 0, kind: 1 },
                                { hex: "cc".repeat(32), chainIndex: 1, kind: 2 }] });
    const mine = parseHashShard(s).entries;
    const theirs = journeyReader(s);
    return theirs.length === mine.length
        && theirs.every((t, i) => t.chain === mine[i].chain && t.kind === mine[i].kind);
  }],

  ["...-and-would-mis-parse-format-2", () => {
    const s = shard({ fmt: FMT_KEY_FORM, unitLen: 16, chains: ["cardano"],
                      encodings: ["hex", "bech32"],
                      entries: [{ key: "addr1qxy", chainIndex: 0, encIndex: 1, kind: 3 }] });
    const mine = parseHashShard(s);
    let theirs = null;
    try { theirs = journeyReader(s); } catch { theirs = "threw"; }
    // THE POINT OF THE ARM: this module reads it, and the format-1 reader does not agree.
    // If this ever starts passing by both being right, the journey has been moved over and
    // this arm plus its sibling should go with the inline block.
    const theyGotItRight = Array.isArray(theirs) && theirs.length === 1
      && theirs[0].chain === "cardano" && theirs[0].kind === 3;
    return mine.error === "" && mine.entries[0].identifier === "addr1qxy" && !theyGotItRight;
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
if (asserted !== 11) {
  console.log(`  FAIL  this suite declares 11 arms and ran ${asserted}`);
  failures += 1;
}
console.log(failures === 0
  ? `\nall ${asserted} arms decided as written.`
  : `\n${failures} of ${asserted} arms did not decide as written.`);
process.exit(failures === 0 ? 0 : 1);
