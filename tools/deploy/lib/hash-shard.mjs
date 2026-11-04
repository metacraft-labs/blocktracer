// The published hash index's shard format, read in one place.
//
// `src/blocktracer/contract/hashshard.nim` writes it and `decodeHashShard` there reads it;
// `idx/hash/<version>/<prefix>.bin` is where it lands. THERE ARE TWO PUBLISHED FORMATS and
// they differ in the header AND in the per-entry width:
//
//   magic(4) = "BThx"   fmt(1)   prefixLen(1)   unitLen(1)   chainCount(1)
//   encCount(1)         <-- FORMAT 2 ONLY
//   entryCount(u32 LE)
//   chainCount x u8-length-prefixed chain names
//   encCount   x u8-length-prefixed encoding names    <-- FORMAT 2 ONLY
//   entryCount x { unit(unitLen)  chainIndex(1)  encIndex(1) <-- FMT 2 ONLY  kind(1) }
//
//   fmt 1 (HashFmtHexBytes) decoded hex bytes, no encoding tag: hex by construction.
//   fmt 2 (HashFmtKeyForm)  the identifier's KEY FORM as characters, NUL-padded, plus an
//                           index into a shard-local encoding dictionary.
//
// SO `entryCount` IS AT OFFSET 8 IN FORMAT 1 AND AT OFFSET 9 IN FORMAT 2, and an entry is
// one byte wider in format 2. A reader that knows only format 1 does not fail on a
// format-2 shard -- it reads the encoding dictionary as entry data and returns confident
// nonsense, which is why `decodeHashShard` reports `fmt` rather than swallowing it and why
// this refuses an unknown one instead of guessing.
//
// ── WHY A MODULE AND NOT A THIRD COPY ──────────────────────────────────────────────
//
// `tools/journeys/journeys/22-a-remembered-fragment-of-a-hash-finds-it.journey.mjs`
// already carries a reader for this, written inline. It handles FORMAT 1 ONLY: it takes
// `d[7]` as the chain count and `getUint32(8)` as the entry count, both of which are the
// format-1 offsets, and it has no encoding dictionary. On a format-2 shard it would
// mis-parse silently. The index published today is format 1, so the journey is correct
// about what it reads now and wrong about what the writer is able to emit -- `hashshard.nim`
// writes both, selected per shard.
//
// A second hand-rolled reader is how two readers of a single source come to disagree, and
// this repository has the scar: `grep` was used as a presence test on compiled output and
// found nothing, because Nim-JS emits some literals as char-code arrays.
//
// SO THIS IS THE READER, AND THE DUPLICATION IS PINNED RATHER THAN TOLERATED. Journey 22
// has not been moved onto it yet, because a journey needs a served site and the replay
// engine to verify and that is not this change's subject. Instead
// `check-no-stale-neighbours-selftest.mjs` asserts the two readers agree on a committed
// shard, so the copy cannot drift in silence. Moving the journey over is the follow-up
// and it should delete its inline block, not leave both.

export const HASH_MAGIC = "BThx";
export const FMT_HEX_BYTES = 1;
export const FMT_KEY_FORM = 2;
/** What format 1 stores, by construction — `HashIndexLegacyEncoding` in the writer. */
export const LEGACY_ENCODING = "hex";

/**
 * Decode one shard of either published format.
 *
 * Returns `{ error }` rather than throwing, and the two negative answers are KEPT APART
 * because a caller has to tell them apart: `not-a-shard` means this file is not an index,
 * `unsupported-format` means it is one this build cannot read. Collapsing them would turn
 * "please reload" into "not found", which is what §6.1 of the format's own spec forbids.
 *
 * @param {Uint8Array|Buffer} bytes
 */
export function parseHashShard(bytes) {
  const d = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const fail = (error, detail) => ({ error, detail, entries: [], chains: [] });
  if (d.length < 12 || String.fromCharCode(...d.subarray(0, 4)) !== HASH_MAGIC) {
    return fail("not-a-shard", `the first 4 bytes are not ${HASH_MAGIC}`);
  }
  const fmt = d[4];
  if (fmt !== FMT_HEX_BYTES && fmt !== FMT_KEY_FORM) {
    return fail("unsupported-format",
      `format ${fmt}; this reader knows ${FMT_HEX_BYTES} and ${FMT_KEY_FORM}`);
  }
  const prefixLen = d[5];
  const unitLen = d[6];
  const chainCount = d[7];
  // THE ONE OFFSET THAT MOVES. Format 2 inserts the encoding-dictionary count here, so
  // everything after it shifts by a byte.
  let pos = 8;
  const encCount = fmt === FMT_KEY_FORM ? d[pos++] : 0;
  const view = new DataView(d.buffer, d.byteOffset, d.byteLength);
  if (pos + 4 > d.length) return fail("truncated", "the header ends before entryCount");
  const entryCount = view.getUint32(pos, true);
  pos += 4;

  const readStr8 = () => {
    if (pos >= d.length) return null;
    const n = d[pos++];
    if (pos + n > d.length) return null;
    const s = new TextDecoder().decode(d.subarray(pos, pos + n));
    pos += n;
    return s;
  };
  const chains = [];
  for (let i = 0; i < chainCount; i++) {
    const s = readStr8();
    if (s === null) return fail("truncated", "the chain dictionary ends early");
    chains.push(s);
  }
  const encodings = [];
  for (let i = 0; i < encCount; i++) {
    const s = readStr8();
    if (s === null) return fail("truncated", "the encoding dictionary ends early");
    encodings.push(s);
  }

  const width = unitLen + 2 + (fmt === FMT_KEY_FORM ? 1 : 0);
  const entries = [];
  for (let i = 0; i < entryCount; i++) {
    // A SHORT SHARD IS A TRUNCATED SHARD AND IT IS NOT A SMALL ONE. Returning the entries
    // read so far would make a half-written index look like a complete smaller one, which
    // is the exact shape of "green and wrong" the gates over this exist to refuse.
    if (pos + width > d.length) {
      return fail("truncated", `entry ${i} of ${entryCount} runs past the end of the shard`);
    }
    const unit = d.subarray(pos, pos + unitLen);
    pos += unitLen;
    const chainIndex = d[pos++];
    const encIndex = fmt === FMT_KEY_FORM ? d[pos++] : 0;
    const kind = d[pos++];
    if (chainIndex >= chains.length) return fail("bad-entry", "chain index out of range");
    if (fmt === FMT_KEY_FORM && encIndex >= encodings.length) {
      return fail("bad-entry", "encoding index out of range");
    }
    let identifier;
    let candidates = null;
    if (fmt === FMT_KEY_FORM) {
      // Trailing NULs are padding and nothing else — no alphabet in the closed set holds
      // one — so this strip is exact, which the format-1 arm's cannot be.
      let end = unit.length;
      while (end > 0 && unit[end - 1] === 0) end -= 1;
      identifier = new TextDecoder().decode(unit.subarray(0, end));
    } else {
      // FORMAT 1 CANNOT STORE THE `0x`, so the writer's own reconstruction is reproduced:
      // hex of the unit, trailing ZERO CHARACTERS stripped, `0x` put back. The strip is
      // the writer's word for cosmetic — an identifier shorter than `unitLen` was
      // zero-padded and a real trailing zero is indistinguishable from padding. It does
      // not bite a 32-byte transaction hash in a 32-byte unit, where nothing was padded,
      // and a caller comparing SHORTER identifiers must know that.
      const hex = [...unit].map((b) => b.toString(16).padStart(2, "0")).join("");
      identifier = `0x${hex.replace(/0+$/, "")}`;
      // BOTH READINGS ARE KEPT, because format 1 cannot tell them apart and a consumer
      // that picks one is wrong for some fraction of any real index. MEASURED over the
      // 288 entries this repository publishes: 275 resolve to a page under the stripped
      // identifier and the other 13 ONLY under the unstripped hex, because their hash
      // genuinely ends in zero and the writer's strip ate it. Nothing resolved under
      // neither. A gate asserting page existence must accept either; a gate that took
      // `identifier` alone would have reported 13 stale neighbours on a clean tree, which
      // is the false-positive that gets a gate switched off.
      candidates = [identifier, `0x${hex}`];
    }
    entries.push({
      identifier, hex: identifier.replace(/^0x/, ""),
      candidates: candidates ?? [identifier],
      chain: chains[chainIndex], kind,
      encoding: fmt === FMT_KEY_FORM ? encodings[encIndex] : LEGACY_ENCODING,
    });
  }
  return { fmt, prefixLen, unitLen, chains, encodings, entries, error: "" };
}

/**
 * Build a shard of either format. The INVERSE of `parseHashShard`, in the same file for
 * the same reason the reader is: the layout is one piece of knowledge, and a builder that
 * drifted from the reader would make every arm that uses it agree with a format nothing
 * publishes.
 *
 * It exists for the self-tests — `hash-shard-selftest.mjs` and
 * `check-no-stale-neighbours-selftest.mjs` both need real bytes, and reading them out of
 * `client/dist` is not available because that is a build output and not committed.
 *
 * NOT a second writer: `hashshard.nim` is the writer, and `just byte-identity` is what
 * holds its output stable. This only has to round-trip through the reader above.
 *
 * @param {{fmt:number, unitLen?:number, prefixLen?:number, chains:string[],
 *          encodings?:string[],
 *          entries:{hex?:string, key?:string, chainIndex:number, encIndex?:number,
 *                   kind:number}[]}} spec
 */
export function encodeHashShard(spec) {
  const { fmt, unitLen = 32, prefixLen = 2, chains, encodings = [], entries } = spec;
  const b = [...Buffer.from(HASH_MAGIC, "ascii"), fmt & 0xff, prefixLen & 0xff,
             unitLen & 0xff, chains.length & 0xff];
  if (fmt === FMT_KEY_FORM) b.push(encodings.length & 0xff);
  const n = entries.length;
  b.push(n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff);
  const str8 = (s) => { const u = Buffer.from(s, "utf8"); b.push(u.length, ...u); };
  for (const c of chains) str8(c);
  if (fmt === FMT_KEY_FORM) for (const e of encodings) str8(e);
  for (const e of entries) {
    let unit;
    if (fmt === FMT_KEY_FORM) {
      const u = [...Buffer.from(e.key ?? "", "utf8")];
      while (u.length < unitLen) u.push(0);          // NUL padding, which the reader strips
      unit = u.slice(0, unitLen);
    } else {
      // Zero-padded decoded bytes, which is what makes the reader's trailing-zero strip
      // ambiguous — see `candidates` above.
      unit = [...Buffer.from((e.hex ?? "").padEnd(unitLen * 2, "0").slice(0, unitLen * 2), "hex")];
    }
    b.push(...unit, e.chainIndex & 0xff);
    if (fmt === FMT_KEY_FORM) b.push((e.encIndex ?? 0) & 0xff);
    b.push(e.kind & 0xff);
  }
  return new Uint8Array(b);
}

/** `hkTx` / `hkBlock` / `hkAddress` -> the route segment, which is `routeFor`'s own
 *  mapping read in this direction. A kind this does not know returns `null` rather than a
 *  guessed segment, because a wrong segment makes a gate assert a page that was never
 *  supposed to exist. */
export const ROUTE_SEGMENT = { 1: "tx", 2: "block", 3: "address" };
export const routeFor = (chain, kind, id) =>
  ROUTE_SEGMENT[kind] ? `${chain}/${ROUTE_SEGMENT[kind]}/${id}` : null;

/** Every entry across a directory of shards, with each unreadable file NAMED and its
 *  reason kept, rather than skipped. A shard that cannot be read is not an absence of
 *  entries. */
export async function readAllShards(dir, { readdir, readFile, join }) {
  const out = { entries: [], chains: new Set(), shards: 0, unreadable: [], formats: new Set() };
  let names = [];
  try { names = (await readdir(dir)).filter((n) => n.endsWith(".bin")).sort(); }
  catch { return out; }
  for (const n of names) {
    const parsed = parseHashShard(await readFile(join(dir, n)));
    if (parsed.error) { out.unreadable.push({ shard: n, ...parsed }); continue; }
    out.shards += 1;
    out.formats.add(parsed.fmt);
    for (const c of parsed.chains) out.chains.add(c);
    out.entries.push(...parsed.entries);
  }
  return out;
}
