// The published ledger-version index's shard format, read in one place.
//
// `src/blocktracer/contract/versionidx.nim` writes it (`encodeVersionShard`) and reads it
// (`decodeVersionShard`); `idx/{chain}/version/{indexVersion}/{bucket}.bin` is where it
// lands, beside `idx/{chain}/version/meta.json`. Layout, little-endian:
//
//   magic(4) = "BTvx"   fmt(1) = 1   bucketDigits(1)   entryCount(u32)
//   entryCount x { version (u8-length-prefixed)   identifier (u8-length-prefixed) }
//
// A VERSION IS A DECIMAL STRING HERE AND IS NEVER A NUMBER. An Aptos ledger version is an
// unsigned 64-bit integer and a JavaScript Number is exact only to 2^53, so `Number("9007199254740993")`
// is 9007199254740992: two published versions would read as one, and a bucket computed by
// arithmetic would name a file the exporter never wrote. Every rule below is string work,
// as it is in the Nim module, so this reader is exact over the whole u64 range.

export const VERSION_MAGIC = "BTvx";
export const VERSION_FMT = 1;
const MAX_U64_DECIMAL = "18446744073709551615";

/**
 * The canonical decimal spelling of an unsigned 64-bit version, or "" when `raw` is not
 * one. The Nim `canonicalVersion`, for a value read OUT of a shard: a published version
 * must already be canonical, so a caller compares this with the input rather than using it
 * to repair one.
 */
export function canonicalVersion(raw) {
  const q = String(raw).trim();
  if (q.length === 0 || !/^[0-9]+$/.test(q)) return "";
  const v = q.replace(/^0+(?=.)/, "");
  if (v.length > MAX_U64_DECIMAL.length
      || (v.length === MAX_U64_DECIMAL.length && v > MAX_U64_DECIMAL)) return "";
  return v;
}

/** Numeric order of two canonical versions, without parsing either. */
export const cmpVersion = (a, b) =>
  (a.length !== b.length ? a.length - b.length : (a < b ? -1 : a > b ? 1 : 0));

/** The bucket a canonical version falls in: the version with its last `bucketDigits`
 *  digits removed, or `0` when nothing is left. The Nim `versionBucket`. */
export function versionBucket(version, bucketDigits) {
  if (bucketDigits <= 0) return version;
  return version.length <= bucketDigits ? "0" : version.slice(0, version.length - bucketDigits);
}

/**
 * Decode one shard. Returns `{ error, detail }` rather than throwing, with the same two
 * negative answers the hash-shard reader keeps apart: `not-a-shard` and
 * `unsupported-format` (a newer writer, "please reload"), plus `truncated`.
 *
 * @param {Uint8Array|Buffer} bytes
 */
export function parseVersionShard(bytes) {
  const b = Buffer.from(bytes);
  if (b.length < 4 || b.subarray(0, 4).toString("latin1") !== VERSION_MAGIC) {
    return { error: "not-a-shard", detail: `bad magic (expected ${VERSION_MAGIC})` };
  }
  if (b.length < 10) return { error: "truncated", detail: "the header runs past the end" };
  const fmt = b[4];
  if (fmt !== VERSION_FMT) {
    return { error: "unsupported-format",
             detail: `version-index format ${fmt} (this reader reads ${VERSION_FMT})` };
  }
  const bucketDigits = b[5];
  const n = b.readUInt32LE(6);
  let at = 10;
  const entries = [];
  const str8 = () => {
    if (at + 1 > b.length) return null;
    const len = b[at];
    if (at + 1 + len > b.length) return null;
    const s = b.subarray(at + 1, at + 1 + len).toString("utf8");
    at += 1 + len;
    return s;
  };
  for (let i = 0; i < n; i++) {
    const version = str8();
    const identifier = version === null ? null : str8();
    if (version === null || identifier === null) {
      return { error: "truncated", detail: `entry ${i} of ${n} runs past the end`,
               fmt, bucketDigits, entries };
    }
    entries.push({ version, identifier });
  }
  if (at !== b.length) {
    return { error: "trailing-bytes",
             detail: `${b.length - at} byte(s) after the ${n} declared entries`,
             fmt, bucketDigits, entries };
  }
  return { fmt, bucketDigits, entries };
}

/**
 * Encode one shard — the Nim `encodeVersionShard`, for building test trees. Entries are
 * sorted by version and then identifier, as the writer sorts them.
 *
 * @param {{version:string, identifier:string}[]} entries
 * @param {number} bucketDigits
 */
export function encodeVersionShard(entries, bucketDigits) {
  const es = [...entries].sort((x, y) => cmpVersion(x.version, y.version)
    || (x.identifier < y.identifier ? -1 : x.identifier > y.identifier ? 1 : 0));
  const out = [...Buffer.from(VERSION_MAGIC, "latin1"), VERSION_FMT, bucketDigits & 0xff];
  const n = es.length;
  out.push(n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff);
  const str8 = (s) => { const u = Buffer.from(s, "utf8"); out.push(u.length, ...u); };
  for (const e of es) { str8(e.version); str8(e.identifier); }
  return new Uint8Array(out);
}
