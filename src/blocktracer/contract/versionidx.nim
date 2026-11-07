## contract/versionidx.nim — the ledger-version index, `/idx/{chain}/version/…`.
##
## ## What it answers
##
## On a chain whose registry row declares `ordering.kind: globalVersion` (Aptos), a
## transaction has two identities: its hash, which names its page, and its ledger version,
## which is the number a visitor reads off another explorer. Static-Site-Architecture.md
## §2.3 gives such a row `id: {kind: "version", version, hash}`, and the ingest publishes
## it that way. The object tree is keyed by hash, so a version cannot be turned into a path
## by computation: Search-And-Routing §3's "its path is a pure function of the number" holds
## for a block height and not for a version. This index is the lookup that closes that gap:
## an exact map from a published version to the hash of the transaction at it.
##
## ## Why a new index and not a widening of §5's
##
## Search-And-Routing §5's hash index is a published wire format, and
## Publishing-And-Caching §6 makes a change to it a migration: a new `{version}` segment,
## published alongside the old one. Putting versions into it would also need a target
## (the hash) that its entries have no field for, and it would send every decimal query on
## every deployment to a global shard. So the version index is a separate artefact that
## changes nothing already published:
##
##   * it is PER CHAIN, at `/idx/{chain}/version/`, beside §6's `/idx/{chain}/names/`.
##     A number means different things on different chains, and only a chain whose
##     registry declares `globalVersion` publishes one. A decimal query on a deployment
##     with no such chain makes no request, as it did before;
##   * its descriptor, `meta.json`, publishes the bucket width, so a client never compiles
##     one in (the rule §5.0a states for §5's shard depth);
##   * its shards are RANGE buckets: a version's bucket is the version with its last
##     `bucketDigits` digits removed, so consecutive versions share a file and the client
##     computes the path from the query string alone.
##
## ## A version is a decimal STRING here, never a number
##
## A ledger version is an unsigned 64-bit integer, and the browser bundle that reads this
## index is compiled by `nim js`, where an integer above 2^53 is not exact. The ingest
## already refuses anything but the canonical decimal spelling (`S5-VERSION-STATED`), so
## this module keeps it as text: comparison is by length and then by character, and the
## bucket is a slice.
##
## JS-safe on purpose: it imports nothing that reaches `std/sha1`, so `client/searchboot/`
## can import it beside `hashshard`.

import std/[strutils, algorithm]
import ./hashshard   # the `/idx/**` wire helpers: `Reader`, `putU8`, `putU32`, `putStr8`
import ./model       # `tokGlobalVersion`, the registry's token for this ordering

const
  VersionIndexVersion* = "1"
    ## The `{indexVersion}` segment of `/idx/{chain}/version/{indexVersion}/{bucket}.bin`.
    ## A change to the shard bytes publishes a new segment beside this one
    ## (Publishing-And-Caching §6.1), as §5's index does.

  VersionBucketDigits* = 4
    ## How many trailing digits a bucket spans: 10^4 versions per shard. A FACT the
    ## exporter publishes in `meta.json`, so a client follows a change on its next load.
    ##
    ## Sized by §5.3's arithmetic. An entry is a version (up to 20 characters) and a hash
    ## key form (66 characters for Aptos) with two length bytes, so about 90 bytes. A full
    ## bucket of 10^4 entries would be about 900 KB, but a published window holds the
    ## transactions BlockTracer traced, not every version: the 2026-11 window holds 4 in
    ## one bucket. The exporter publishes `largestShardBytes`, so the figure that should
    ## move this constant is visible.

  VersionIndexFormat* = 1
    ## The shard format byte. See `encodeVersionShard`.

  GlobalVersionOrdering* = $tokGlobalVersion
    ## The registry's `ordering.kind` token that makes a chain publish this index, and that
    ## makes a client consult it. Read from the ordering union itself, not spelled again.

  versionMagic = "BTvx"
  MaxU64Decimal = "18446744073709551615"

type
  VersionEntry* = object
    ## One published transaction, by version.
    version*: string
      ## The canonical decimal spelling (`canonicalVersion`).
    identifier*: string
      ## The transaction's hash as its route names it: `/{chain}/tx/{identifier}/`.

func canonicalVersion*(raw: string): string =
  ## The canonical decimal spelling of an unsigned 64-bit version, or "" when `raw` is not
  ## one: surrounding whitespace removed, leading zeros removed (`0` stays `0`), at most
  ## 20 digits and not above 2^64 − 1. Pure string work, so it is exact on the JS backend.
  ##
  ## Leading zeros are dropped rather than refused because `007` and `7` name one number;
  ## the ingest refuses them in a PUBLISHED row because there two spellings would be two
  ## ids, and a query is not a published row.
  let q = raw.strip
  if q.len == 0: return ""
  for c in q:
    if c notin Digits: return ""
  var i = 0
  while i < q.len - 1 and q[i] == '0': inc i
  result = q[i .. ^1]
  if result.len > MaxU64Decimal.len or
     (result.len == MaxU64Decimal.len and result > MaxU64Decimal):
    return ""

func cmpVersion*(a, b: string): int =
  ## Numeric order of two canonical decimal versions, without parsing either.
  if a.len != b.len: cmp(a.len, b.len) else: cmp(a, b)

func versionBucket*(version: string; bucketDigits: int): string =
  ## The range bucket a canonical version falls in: the version with its last
  ## `bucketDigits` digits removed, or `0` when nothing is left.
  if bucketDigits <= 0: return version
  if version.len <= bucketDigits: "0" else: version[0 ..< version.len - bucketDigits]

func versionIndexDir*(chain: string): string =
  ## `idx/{chain}/version` — relative, like the object paths in `contract/shards`.
  "idx/" & chain & "/version"

func versionMetaPath*(chain: string): string =
  versionIndexDir(chain) & "/meta.json"

func versionShardPath*(chain, indexVersion, bucket: string): string =
  versionIndexDir(chain) & "/" & indexVersion & "/" & bucket & ".bin"

proc encodeVersionShard*(entries: seq[VersionEntry]; bucketDigits: int): string =
  ## One bucket's shard. Entries are sorted here, by version and then by identifier, so the
  ## bytes are a pure function of the set.
  ##
  ## Layout, little-endian, the same primitives as §5's shards:
  ##
  ##   magic(4) = "BTvx"   fmt(1) = 1   bucketDigits(1)   entryCount(u32)
  ##   entryCount × { version (u8-length-prefixed)   identifier (u8-length-prefixed) }
  var es = entries
  es.sort(proc(a, b: VersionEntry): int =
    let c = cmpVersion(a.version, b.version)
    if c != 0: c else: cmp(a.identifier, b.identifier))
  result = versionMagic
  result.putU8 VersionIndexFormat
  result.putU8 bucketDigits
  result.putU32 uint32(es.len)
  for e in es:
    result.putStr8 e.version
    result.putStr8 e.identifier

proc decodeVersionShard*(data: string): tuple[fmt, bucketDigits: int,
                         entries: seq[VersionEntry], err: string] =
  ## Read a shard. An unknown format is reported by number, so a caller can say "please
  ## reload" rather than "not found" (Publishing-And-Caching §6.1).
  var r = Reader(data: data)
  if r.bytes(4) != versionMagic:
    return (0, 0, @[], "bad magic (expected " & versionMagic & ")")
  let fmt = r.u8
  if fmt != VersionIndexFormat:
    return (fmt, 0, @[], "unsupported version-index format " & $fmt &
            " (this build reads " & $VersionIndexFormat & ")")
  result.fmt = fmt
  result.bucketDigits = r.u8
  let n = int(r.u32)
  for _ in 0 ..< n:
    let v = r.str8
    let id = r.str8
    if r.err.len > 0: break
    result.entries.add VersionEntry(version: v, identifier: id)
  if r.err.len > 0: result.err = r.err

proc lookupVersion*(data, version: string): seq[VersionEntry] =
  ## Every entry in a shard at exactly `version` (already canonical). Empty on a shard that
  ## does not decode; the caller tells "not there" from "not readable" by decoding first.
  let dec = decodeVersionShard(data)
  if dec.err.len > 0: return
  for e in dec.entries:
    if e.version == version: result.add e
