## contract/hashshard.nim — the `/idx/**` wire helpers, and the §5 global hash
## index shard codec (Search-And-Routing.md §5).
##
## ## Why this is not in `searchidx.nim`
##
## Same reason `contract/shards.nim` is not in `contract/ids.nim`, arriving a
## second time: `searchidx` hashes name terms with `std/sha1` (§6's
## `hashFunction`), `std/sha1` reaches `std/endians`, and `std/endians` uses
## `copyMem`, which is undefined on the JS backend. `nim js` fails there before
## a line of this repository's own code is considered.
##
## And the browser now needs the §5 codec. `/search?q=` is resolved in a tab —
## a static file server never sees a query string — so the client that "computes
## the shard path directly" and reads "an exact map from hash to (chain, entity
## kind)" is `client/searchboot/`. The alternative was a second decoder for the
## same bytes, written in JavaScript, where no Nim test could read it and where
## a format change would be caught by nothing. `searchidx` imports and
## re-exports everything here, so no existing importer learns that the split
## happened.
##
## Nothing here hashes anything. That is the whole property being preserved:
## §5's shard key is a **leading slice of the hash itself** ("sharded by a
## leading slice of the hash, so the client computes the shard path directly"),
## which is string slicing, while §6's shard key is a hash OF the term ("terms
## are normalised, hashed, and the low bits select a shard"), which is not.

import std/[strutils, algorithm]

# ---------------------------------------------------------------------------
# Little-endian byte helpers. A published shard is a plain byte string.
# ---------------------------------------------------------------------------

proc putU8*(s: var string, v: int) = s.add chr(v and 0xFF)

proc putU16*(s: var string, v: int) =
  s.add chr(v and 0xFF)
  s.add chr((v shr 8) and 0xFF)

proc putU32*(s: var string, v: uint32) =
  s.add chr(int(v and 0xFF))
  s.add chr(int((v shr 8) and 0xFF))
  s.add chr(int((v shr 16) and 0xFF))
  s.add chr(int((v shr 24) and 0xFF))

proc putStr8*(s: var string, v: string) =
  ## A `u8`-length-prefixed byte string (terms, ids, chain names — all short).
  doAssert v.len <= 0xFF, "index field too long for u8 length: " & v
  s.putU8 v.len
  s.add v

type
  Reader* = object
    ## The `/idx/**` byte reader. Public because §6's name codec in
    ## `searchidx` reads the same wire primitives.
    data*: string
    pos*: int
    err*: string

proc u8*(r: var Reader): int =
  if r.pos + 1 > r.data.len: r.err = "truncated (u8)"; return 0
  result = ord(r.data[r.pos]); inc r.pos

proc u16*(r: var Reader): int =
  if r.pos + 2 > r.data.len: r.err = "truncated (u16)"; return 0
  result = ord(r.data[r.pos]) or (ord(r.data[r.pos+1]) shl 8)
  r.pos += 2

proc u32*(r: var Reader): uint32 =
  if r.pos + 4 > r.data.len: r.err = "truncated (u32)"; return 0
  result = uint32(ord(r.data[r.pos])) or (uint32(ord(r.data[r.pos+1])) shl 8) or
           (uint32(ord(r.data[r.pos+2])) shl 16) or (uint32(ord(r.data[r.pos+3])) shl 24)
  r.pos += 4

proc bytes*(r: var Reader, n: int): string =
  if r.pos + n > r.data.len: r.err = "truncated (bytes " & $n & ")"; return ""
  result = r.data[r.pos ..< r.pos + n]; r.pos += n

proc str8*(r: var Reader): string =
  let n = r.u8
  if r.err.len > 0: return ""
  r.bytes(n)

# ===========================================================================
# §5 — the global hash index: `/idx/hash/{version}/{prefix}.bin`.
# An exact map from an entity hash to the (chain, kind) that claim it. A hash that
# appears on several chains (or as several kinds) has one entry per claim (§5.1),
# and the client offers all of them.
# ===========================================================================

const
  HashIndexVersion* = "1"
    ## The `{version}` segment of `/idx/hash/{version}/{prefix}.bin`.
    ##
    ## §5 makes the index "immutable and version-addressed, so shards cache
    ## permanently and a rebuild is a new version rather than an invalidation",
    ## and names no source the client can read it from. `/idx/hash/meta.json`
    ## is that source — see `buildGlobalHashIndex` — and this is the value it
    ## publishes.

  HashShardPrefixLen* = 2
    ## Hex chars of the hash that select a shard: the §5 sharding depth, and
    ## therefore also the SHORTEST PREFIX a client can answer a query about,
    ## since a shorter one selects no shard.
    ##
    ## §5.3 says depth "follows arithmetically from the total entry count
    ## across all chains, and should be recomputed rather than fixed". Two hex
    ## chars is what that arithmetic selects for this corpus by a wide margin —
    ## 256 possible shards over a corpus in the hundreds, with the largest
    ## shard three orders of magnitude under §5.3's 32 KB target — and the
    ## exporter PUBLISHES the resulting largest shard size and warns when the
    ## arithmetic stops selecting this value, so the constant cannot quietly
    ## outlive its justification.
    ##
    ## It is a constant HERE, in one place, and a published FACT in
    ## `/idx/hash/meta.json`. No client hardcodes it: `client/searchboot/`
    ## derives its minimum-prefix rule from the descriptor, so deepening the
    ## index is a producer change that clients follow on their next load.

  hashMagic = "BThx"
  hashFmt = 1
  # kind codes — only these three entity classes are hash-addressable (§2 shapes).
  hkTx* = 1
  hkBlock* = 2
  hkAddress* = 3

type
  HashEntry* = object
    hexHash*: string   ## 0x-stripped, lowercase hex of the entity hash
    chain*: string
    kind*: int         ## hkTx / hkBlock / hkAddress

func kindOfRouteSegment*(seg: string): int =
  ## The `{kind}` segment of `/{chain}/{kind}/{id}` -> a `hk*` code, or 0.
  ##
  ## This and `routeFor` below are ONE definition of the same mapping, read in
  ## both directions, because both directions exist and they must agree. The
  ## exporter PARSES rendered routes into index entries; `client/searchboot/`
  ## BUILDS a route from an index entry it just read. If those two disagreed,
  ## the index would resolve a hash to a URL that renders nothing — a hit that
  ## navigates to a 404, which is the one outcome §5's "a hit is definite"
  ## forbids outright.
  case seg
  of "tx": hkTx
  of "block": hkBlock
  of "address": hkAddress
  else: 0

func routeFor*(chain: string, kind: int, id: string): string =
  ## Where a `(chain, kind, id)` claim from the index lands. The inverse of
  ## `kindOfRouteSegment`, and the reason both are here.
  let seg = case kind
            of hkTx: "tx"
            of hkBlock: "block"
            of hkAddress: "address"
            else: ""
  if seg.len == 0: return ""
  "/" & chain & "/" & seg & "/" & id & "/"

proc hkName*(k: int): string =
  case k
  of hkTx: "tx"
  of hkBlock: "block"
  of hkAddress: "address"
  else: "unknown"

proc stripHex*(h: string): string =
  result = h.toLowerAscii
  if result.startsWith("0x"): result = result[2 .. ^1]

proc hashPrefix*(hexHash: string, prefixLen: int): string =
  ## The shard key: the leading `prefixLen` hex chars (§5, "sharded by a leading
  ## slice of the hash", client computes the shard path directly).
  let h = stripHex(hexHash)
  if h.len <= prefixLen: h else: h[0 ..< prefixLen]

proc hexToBytes*(h: string): string =
  var s = stripHex(h)
  if s.len mod 2 == 1: s = s & "0"
  for i in countup(0, s.len - 2, 2):
    result.add chr(parseHexInt(s[i .. i+1]))

proc bytesToHex*(b: string): string =
  for c in b: result.add toLowerAscii(toHex(ord(c), 2))

proc encodeHashShard*(entries: seq[HashEntry], prefixLen: int): string =
  ## Encode one shard. `entries` must all share the same `prefixLen`-hex prefix
  ## (the caller groups them); they are re-sorted here so output is canonical.
  # Determine a uniform stored hash width (bytes). The demo stores the FULL hash for
  # an exact, collision-free answer; the production builder truncates to the
  # arithmetically-chosen width (§5.3). Width is self-described in the header.
  var hashLen = 0
  for e in entries:
    let n = hexToBytes(e.hexHash).len
    if n > hashLen: hashLen = n
  # Chain dictionary, so each entry costs one byte for its chain (§5.3 sizing).
  var chains: seq[string]
  for e in entries:
    if e.chain notin chains: chains.add e.chain
  chains.sort()
  var idxOf = proc(c: string): int =
    for i, x in chains:
      if x == c: return i
    -1
  var es = entries
  es.sort(proc(a, b: HashEntry): int =
    let ha = hexToBytes(a.hexHash); let hb = hexToBytes(b.hexHash)
    if ha != hb: (if ha < hb: -1 else: 1)
    elif a.chain != b.chain: cmp(a.chain, b.chain)
    else: cmp(a.kind, b.kind))
  result = hashMagic
  result.putU8 hashFmt
  result.putU8 prefixLen
  result.putU8 hashLen
  result.putU8 chains.len
  result.putU32 uint32(es.len)
  for c in chains: result.putStr8 c
  for e in es:
    var hb = hexToBytes(e.hexHash)
    while hb.len < hashLen: hb = hb & '\0'
    result.add hb
    result.putU8 idxOf(e.chain)
    result.putU8 e.kind

proc decodeHashShard*(data: string): tuple[prefixLen, hashLen: int,
                      entries: seq[HashEntry], err: string] =
  var r = Reader(data: data)
  if r.bytes(4) != hashMagic:
    return (0, 0, @[], "bad magic (expected " & hashMagic & ")")
  let fmt = r.u8
  if fmt != hashFmt: return (0, 0, @[], "unsupported hash-index format " & $fmt)
  result.prefixLen = r.u8
  result.hashLen = r.u8
  let chainCnt = r.u8
  let entryCnt = int(r.u32)
  var chains: seq[string]
  for _ in 0 ..< chainCnt: chains.add r.str8
  for _ in 0 ..< entryCnt:
    let hb = r.bytes(result.hashLen)
    let ci = r.u8
    let kind = r.u8
    if r.err.len > 0: break
    if ci < 0 or ci >= chains.len:
      result.err = "chain index out of range"; return
    result.entries.add HashEntry(hexHash: bytesToHex(hb).strip(
      leading = false, trailing = true, chars = {'0'}) , chain: chains[ci], kind: kind)
  # NB: trailing-zero strip above is only cosmetic for lookup; exact match uses bytes.
  if r.err.len > 0: result.err = r.err

proc lookupHash*(data: string, hexHash: string): seq[HashEntry] =
  ## Exact lookup used by the validator's coverage check: does this shard resolve
  ## `hexHash`? Compares stored bytes to the query's bytes at the stored width.
  let dec = decodeHashShard(data)
  if dec.err.len > 0: return @[]
  var want = hexToBytes(hexHash)
  while want.len < dec.hashLen: want = want & '\0'
  want = want[0 ..< dec.hashLen]
  for e in dec.entries:
    var hb = hexToBytes(e.hexHash)
    while hb.len < dec.hashLen: hb = hb & '\0'
    if hb[0 ..< dec.hashLen] == want: result.add e

