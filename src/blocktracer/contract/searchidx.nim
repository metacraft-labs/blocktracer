## The `/idx/**` search-index on-wire formats (Search-And-Routing.md §5, §6).
##
## These are the two static, immutable, version-addressed index artifacts the
## Search-and-Routing spec defines. Both are **binary** (`.bin`), as the path table
## in Static-Site-Architecture.md §2 and Search-And-Routing §5–§6 require — so this
## module is the ONE place their byte layout is defined, and both the producer (the
## demo generator, M5c; the real pipeline, M7/M9) and the conformance validator
## encode/decode through it. That keeps the format a single source of truth, exactly
## as the Object-Class Registry (§2.9) intends.
##
## Why a concrete layout at all: the spec fixes the *logical* content and the sharding
## key but does not pin the exact bytes (§5.3 even says shard depth "should be
## recomputed rather than fixed"). This module chooses the most defensible faithful
## encoding for the demo's small dataset and documents it in docs/data-contract.md
## (decisions D4/D5). It is deliberately simple and self-describing rather than the
## heavily-packed production format — the logical content is identical, so swapping in
## a packed encoder later is a producer change behind this seam, not a contract change.
##
## Determinism (M5c): encoding is a pure function of its input; entries and terms are
## emitted in a fixed sort order, so the same dataset yields byte-identical shards.

import std/[strutils, algorithm, sha1]

# ---------------------------------------------------------------------------
# Little-endian byte helpers. A published shard is a plain byte string.
# ---------------------------------------------------------------------------

proc putU8(s: var string, v: int) = s.add chr(v and 0xFF)

proc putU16(s: var string, v: int) =
  s.add chr(v and 0xFF)
  s.add chr((v shr 8) and 0xFF)

proc putU32(s: var string, v: uint32) =
  s.add chr(int(v and 0xFF))
  s.add chr(int((v shr 8) and 0xFF))
  s.add chr(int((v shr 16) and 0xFF))
  s.add chr(int((v shr 24) and 0xFF))

proc putStr8(s: var string, v: string) =
  ## A `u8`-length-prefixed byte string (terms, ids, chain names — all short).
  doAssert v.len <= 0xFF, "index field too long for u8 length: " & v
  s.putU8 v.len
  s.add v

type
  Reader = object
    data: string
    pos: int
    err: string

proc u8(r: var Reader): int =
  if r.pos + 1 > r.data.len: r.err = "truncated (u8)"; return 0
  result = ord(r.data[r.pos]); inc r.pos

proc u16(r: var Reader): int =
  if r.pos + 2 > r.data.len: r.err = "truncated (u16)"; return 0
  result = ord(r.data[r.pos]) or (ord(r.data[r.pos+1]) shl 8)
  r.pos += 2

proc u32(r: var Reader): uint32 =
  if r.pos + 4 > r.data.len: r.err = "truncated (u32)"; return 0
  result = uint32(ord(r.data[r.pos])) or (uint32(ord(r.data[r.pos+1])) shl 8) or
           (uint32(ord(r.data[r.pos+2])) shl 16) or (uint32(ord(r.data[r.pos+3])) shl 24)
  r.pos += 4

proc bytes(r: var Reader, n: int): string =
  if r.pos + n > r.data.len: r.err = "truncated (bytes " & $n & ")"; return ""
  result = r.data[r.pos ..< r.pos + n]; r.pos += n

proc str8(r: var Reader): string =
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

proc hkName*(k: int): string =
  case k
  of hkTx: "tx"
  of hkBlock: "block"
  of hkAddress: "address"
  else: "unknown"

proc stripHex(h: string): string =
  result = h.toLowerAscii
  if result.startsWith("0x"): result = result[2 .. ^1]

proc hashPrefix*(hexHash: string, prefixLen: int): string =
  ## The shard key: the leading `prefixLen` hex chars (§5, "sharded by a leading
  ## slice of the hash", client computes the shard path directly).
  let h = stripHex(hexHash)
  if h.len <= prefixLen: h else: h[0 ..< prefixLen]

proc hexToBytes(h: string): string =
  var s = stripHex(h)
  if s.len mod 2 == 1: s = s & "0"
  for i in countup(0, s.len - 2, 2):
    result.add chr(parseHexInt(s[i .. i+1]))

proc bytesToHex(b: string): string =
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

# ===========================================================================
# §6 — name shards: `/idx/{chain}/names/{shard}.bin` (+ meta.json alongside).
# The only genuine text search in v1: verified contract/token names, symbols and
# curated labels, plus the site's own routes. Each shard maps a normalised term to
# postings of (kind, id, displayName, weight) — with provenance (§6.2), because the
# corpus is adversarial and curated names must outrank self-declared ones.
# ===========================================================================

const
  nameMagic = "BTnx"
  nameFmt = 1
  provCurated* = "curated"
  provSelfDeclared* = "self-declared"

type
  Posting* = object
    kind*: string        ## "token" | "contract" | "chain" | "route" | "label" | …
    id*: string          ## the address / slug / route the posting resolves to
    displayName*: string
    provenance*: string  ## provCurated / provSelfDeclared (§6.2)
    weight*: int         ## ranking input (§8)

  NameTerm* = object
    term*: string        ## normalised search term
    postings*: seq[Posting]

proc normTerm*(s: string): string =
  ## Terms are normalised before hashing (§6): lowercased, trimmed, internal runs
  ## of whitespace collapsed to a single space.
  var parts: seq[string]
  for w in s.toLowerAscii.splitWhitespace: parts.add w
  parts.join(" ")

proc termHash32*(term: string): uint32 =
  ## The index hash function: SHA-1 of the normalised term, low 32 bits. Recorded in
  ## meta.json as `hashFunction` so a reader uses the same one.
  let h = toLowerAscii($secureHash(normTerm(term)))
  uint32(parseHexInt(h[0 .. 7]))

proc shardOf*(term: string, shardBits: int): int =
  ## Low `shardBits` bits of the term hash select the shard (§6), so a query fetches
  ## only the shard its term hashes to.
  if shardBits <= 0: return 0
  int(termHash32(term) and uint32((1 shl shardBits) - 1))

proc encodeNameShard*(shardNo, shardBits: int, terms: seq[NameTerm]): string =
  var ts = terms
  ts.sort(proc(a, b: NameTerm): int =
    let ha = termHash32(a.term); let hb = termHash32(b.term)
    if ha != hb: (if ha < hb: -1 else: 1) else: cmp(a.term, b.term))
  result = nameMagic
  result.putU8 nameFmt
  result.putU8 shardBits
  result.putU8 shardNo
  result.putU32 uint32(ts.len)
  for t in ts:
    result.putU32 termHash32(t.term)
    result.putStr8 t.term
    result.putU16 t.postings.len
    for p in t.postings:
      result.putStr8 p.kind
      result.putStr8 p.id
      result.putStr8 p.displayName
      result.putStr8 p.provenance
      result.putU16 p.weight

proc decodeNameShard*(data: string): tuple[shardNo, shardBits: int,
                      terms: seq[NameTerm], err: string] =
  var r = Reader(data: data)
  if r.bytes(4) != nameMagic:
    return (0, 0, @[], "bad magic (expected " & nameMagic & ")")
  let fmt = r.u8
  if fmt != nameFmt: return (0, 0, @[], "unsupported name-index format " & $fmt)
  result.shardBits = r.u8
  result.shardNo = r.u8
  let termCnt = int(r.u32)
  for _ in 0 ..< termCnt:
    discard r.u32                       # stored term hash (exact-confirm aid)
    var t = NameTerm(term: r.str8)
    let postingCnt = r.u16
    for _ in 0 ..< postingCnt:
      var p: Posting
      p.kind = r.str8
      p.id = r.str8
      p.displayName = r.str8
      p.provenance = r.str8
      p.weight = r.u16
      t.postings.add p
    if r.err.len > 0: break
    result.terms.add t
  if r.err.len > 0: result.err = r.err
