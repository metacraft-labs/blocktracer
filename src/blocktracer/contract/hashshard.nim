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
## ## Nothing here decides case — or an alphabet — for itself any more
##
## `stripHex` went first: it folded case unconditionally, for every encoding,
## which is right for hex and destroys base58 and base64url. The fold comes from
## the per-member `case` rule in `tools/chain/identifier-encodings.json` through
## `identifierPayload`.
##
## `hexToBytes` has now gone the same way, and it was the larger of the two. It
## parsed the identifier as HEX PAIRS, so four of the eight members of the closed
## set — base58, base64url, bech32, ss58 — had no representation in this index at
## all, and on anything it could not parse it did not refuse but CRASHED the
## producer through an unhandled `parseHexInt`. What replaced it is
## `identifierIndexKey`, which reads the per-member `alphabet` rule out of the
## same shared file and refuses BY NAME, and a private `hexUnits` that only
## format 1 reaches.
##
## ## The index keys per identifier SHAPE, and that is the decision to read first
##
## §5's index path carries no chain segment, so the client does not know the
## chain. It does know the query's SHAPE — Search-And-Routing §2's table,
## implemented by `shapesOf` in `client/src/viewmodel/search_shapes.nim` — and a
## shape is derivable from the query string alone. So `hashPrefix` takes an
## encoding: the producer passes the one the chain declared, the client passes
## each one its query's shapes imply, and both slice the SAME `identifierPayload`
## the object tree's `shardKeyFor` slices. See `HashIndexLegacyEncoding` for the
## argument this replaced and exactly where it stopped being true.
##
## ## Two published formats, because the bytes are published
##
## `encodeHashShard`/`decodeHashShard` are a wire format on a CDN, so widening
## them is versioned rather than mutated. Format 1 is byte-for-byte what has
## always been written and is still written for a hex-only shard; format 2 adds
## a per-entry encoding tag and stores key forms as characters. They live at
## different `{version}` path segments and are published ALONGSIDE each other
## (Publishing-And-Caching §6.1) — see `HashIndexVersionAll` for why widening
## version 1 in place would have turned an old client's hex lookup into a
## confident false absence, which §5.0a forbids.
##
## Nothing here hashes anything. That is the whole property being preserved:
## §5's shard key is a **leading slice of the hash itself** ("sharded by a
## leading slice of the hash, so the client computes the shard path directly"),
## which is string slicing, while §6's shard key is a hash OF the term ("terms
## are normalised, hashed, and the low bits select a shard"), which is not.

import std/[strutils, algorithm]
import ./identifier_encoding

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
    ## The `{version}` segment of `/idx/hash/{version}/{prefix}.bin` for the
    ## HEX-ONLY index — the one this project has always published, and the one a
    ## client built before this change reads.
    ##
    ## §5 makes the index "immutable and version-addressed, so shards cache
    ## permanently and a rebuild is a new version rather than an invalidation",
    ## and names no source the client can read it from. `/idx/hash/meta.json`
    ## is that source — see `buildGlobalHashIndex` — and this is the value it
    ## publishes.

  HashIndexVersionAll* = "2"
    ## The `{version}` segment of the index that covers EVERY encoding.
    ##
    ## **This is the compatibility window, and the window is a second path
    ## rather than a second meaning for the first one** — Publishing-And-Caching
    ## §6.1: "a breaking change increments the schema version and is published
    ## ALONGSIDE the old version until the release that reads it is fully rolled
    ## out". The `{version}` segment §5 already puts in the path is where that
    ## alongside lives, so no new mechanism was invented for it.
    ##
    ## Why the old version cannot simply be widened in place: an older client
    ## meeting a format byte it does not know returns NO ENTRIES — `hitsFor` in
    ## `client/searchboot/` reads a decode error as an empty shard — and §5.0a
    ## makes that the one thing the index may never do, because "a prefix miss is
    ## a confident claim that NOTHING published begins with those digits". A
    ## widened `/idx/hash/1/` would turn every old client's hex lookup that
    ## happened to share a shard with a base58 entry into a false absence.
    ##
    ## WHY THE OLD VERSION IS STILL COMPLETE FOR THE CLIENT THAT READS IT, which
    ## is what makes the window sound rather than merely ordered. `/idx/hash/1/`
    ## holds the hex entries only, and a client built before this change cannot
    ## ASK about anything else: `shapesOf` classified every non-hex string as
    ## `qsText`, and `isHashLike` is false for `qsText`, so such a query never
    ## reached the index at all — it went to §6's name shards. The v1 index is
    ## therefore exactly as complete as the questions its readers can put to it.
    ##
    ## AND IT IS ONLY PUBLISHED WHEN IT HAS SOMETHING TO SAY. On a deployment
    ## whose chains are all hex — which is every chain this tree publishes today
    ## — v2 would be a re-encoding of v1 at a second path, costing a doubled
    ## object count for no reader. So the producers emit it only when a non-hex
    ## entry exists, which is also what keeps `just byte-identity` at zero.

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

const
  HashFmtHexBytes* = 1
    ## **Format 1 — the bytes this project has always published, unchanged.**
    ##
    ## Each entry stores the DECODED bytes of a `0x`-stripped lowercase hex
    ## identifier, truncated or zero-padded to a self-described width, with no
    ## encoding tag: everything in a format-1 shard is hex by construction.
    ##
    ## It is still WRITTEN, not merely read, and that is the point. A format that
    ## could only be read would not keep `/idx/hash/1/` reproducible, and
    ## "reproducible" is what `just byte-identity` measures: every shard the demo
    ## producer emits is still emitted here, byte for byte, because every
    ## identifier in it is hex.

  HashFmtKeyForm* = 2
    ## **Format 2 — the key form of the identifier, plus the encoding it is
    ## written in.**
    ##
    ## Each entry stores the identifier's KEY FORM as characters, NUL-padded to a
    ## self-described width, followed by an index into a shard-local ENCODING
    ## dictionary — the same trick the chain dictionary already uses, for the
    ## same reason: one byte per entry instead of a repeated token.
    ##
    ## ## Why characters and not decoded bytes, which is the whole decision
    ##
    ## Decoded bytes are the canonical-looking answer and they are wrong here,
    ## because decoding is the one thing the CLIENT cannot do. §5's index path
    ## has no chain segment, so a client resolving a bare query does not know the
    ## chain and therefore does not know the alphabet: a 44-character string is
    ## base58 or base64, and decoding a bech32 string needs its human-readable
    ## part. It would have to try several alphabets and issue a request per
    ## candidate, which is exactly the per-chain fan-out §5's first bullet exists
    ## to replace. Characters in the identifier's own alphabet are derivable from
    ## the query string alone, which is what keeps "two requests to resolve any
    ## hash on any chain" true.
    ##
    ## ## What it costs, measured rather than waved at
    ##
    ## A 64-hex-digit identifier is 32 bytes decoded and 66 characters in key
    ## form (`0x` included), so a format-2 entry is a little over twice a
    ## format-1 entry for the same hash. §5.3 answers that directly — "an exact
    ## map costs roughly an order of magnitude more space than a probabilistic
    ## filter would… storage is the cheap axis here" — and the producers publish
    ## `largestShardBytes`, so the figure the §5.3 arithmetic needs is a
    ## published fact rather than an estimate. Today the cost is zero, because a
    ## hex-only deployment publishes no format-2 shard at all.

  # kind codes — only these three entity classes are hash-addressable (§2 shapes).
  hkTx* = 1
  hkBlock* = 2
  hkAddress* = 3

type
  HashEntry* = object
    ## One `(identifier, chain, kind)` claim, as §5.1's "every `(chain, kind)`
    ## that claims the hash" needs it.
    ##
    ## `identifier` IS THE KEY FORM AND NOT THE PAYLOAD, and the two are
    ## different for two of the eight members. The payload is what the SHARD KEY
    ## is sliced from (`hashPrefix`), because that is where the entropy is — every
    ## Cardano address begins `addr1`, so sharding the raw string would put a
    ## whole chain in one bucket. But an ENTRY has to be able to name a route, and
    ## a payload cannot: drop `addr1` and `/cardano/address/qxy…/` is not a page.
    ## So the entry carries the whole key form and the shard key is DERIVED from
    ## it, which is one derivation rather than two stored fields free to disagree.
    ##
    ## `encoding` is carried per entry rather than per shard because a shard is
    ## selected by a prefix and a prefix is not an alphabet: `ab` is a legal
    ## leading slice of a hex payload AND of a base58 payload, so one shard can
    ## hold both and the reader has to be told which each entry is.
    encoding*: string
    identifier*: string
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

func identifierKindOf*(kind: int): string =
  ## An `hk*` code -> the identifier KIND a registry row declares an encoding
  ## for, as `tools/chain/identifier-encodings.json` names them.
  ##
  ## It is here beside `kindOfRouteSegment` and `routeFor` because it is the
  ## third reading of the same three-member set, and the three must agree. The
  ## route segment is `tx`, the kind id is `transaction`, and they are different
  ## strings for good reasons on both sides — but a builder that indexed a
  ## transaction under the ADDRESS kind's declared encoding would key it in an
  ## alphabet the chain never claimed for it, and nothing downstream could tell.
  ##
  ## A code outside the set returns "", and `encodingFor` refuses that by name
  ## rather than this function inventing a kind.
  case kind
  of hkTx: KindTransaction
  of hkBlock: KindBlock
  of hkAddress: KindAddress
  else: ""

proc hkName*(k: int): string =
  case k
  of hkTx: "tx"
  of hkBlock: "block"
  of hkAddress: "address"
  else: "unknown"

const HashIndexLegacyEncoding* = "hex"
  ## **The one encoding a FORMAT-1 shard can hold**, named rather than assumed.
  ##
  ## Format 1 stores decoded hex pairs and carries no per-entry encoding tag, so
  ## everything in such a shard is hex by construction and the reader has to say
  ## so somewhere. This is that somewhere. It is `Legacy` in the name because the
  ## constant no longer describes the INDEX — it describes one of the index's two
  ## published formats.
  ##
  ## ## What it used to be, and why keying per chain was never the alternative
  ##
  ## This was `HashIndexEncoding`, and it was a constant on an argument that is
  ## still correct as far as it went: §5's index path is
  ## `/idx/hash/{version}/{prefix}.bin` and carries NO CHAIN SEGMENT — which is
  ## what makes "two requests to resolve any hash on any chain" true — so a
  ## client resolving a bare query does not know which chain it will hit and
  ## cannot know which chain's declaration to normalise with. Threading a CHAIN's
  ## encoding in here would produce a shard path only the producer could compute.
  ##
  ## ## What the argument missed: a shape is not a chain
  ##
  ## The client does not know the chain, and it does not have to. It knows the
  ## query's SHAPE, which is derivable from the string alone — that is exactly
  ## what Search-And-Routing §2's shape table is, and `shapesOf` in
  ## `client/src/viewmodel/search_shapes.nim` is its implementation. So the
  ## index keys PER IDENTIFIER SHAPE: `hashPrefix` takes an encoding, the
  ## producer passes the one the chain's registry row declares, and the client
  ## passes each one its query's shapes imply — and FETCHES EVERY DISTINCT
  ## PAYLOAD, because they are not all the same one. This comment used to say
  ## they were; §5.6 and `indexProbesOf` carry the measurement that says
  ## otherwise and the request bound that replaced the claim.

proc hashPrefix*(encoding, identifier: string, prefixLen: int): string =
  ## The shard key: the leading `prefixLen` characters of the identifier's
  ## PAYLOAD, in its own alphabet (§5, "sharded by a leading slice of the hash",
  ## client computes the shard path directly).
  ##
  ## **The same `identifierPayload` the object tree's `shardKeyFor` slices**, so
  ## the index and the object layout cannot disagree about where an identifier's
  ## payload starts or how its case folds. What differs is only the width and the
  ## padding: `shardKeyFor` pads a short payload to `ShardWidth` with the
  ## alphabet's zero digit because a path segment is fixed-width, and this does
  ## not, because a shard shorter than the depth is a shard no query can select
  ## and inventing one would publish an entry nothing reaches.
  ##
  ## FOR `hex` THIS IS BYTE-FOR-BYTE WHAT IT HAS ALWAYS PRODUCED. The encoding
  ## arrived as a parameter where a constant used to be read; the expression it
  ## evaluates is unchanged.
  let h = identifierPayload(encoding, identifier)
  if h.len <= prefixLen: h else: h[0 ..< prefixLen]

proc hexUnits(identifier: string): string =
  ## A hex identifier's payload as DECODED BYTES — format 1's stored unit, and
  ## nothing else's.
  ##
  ## ## This is what `hexToBytes` became, and the difference is the refusal
  ##
  ## `hexToBytes` was public, took any string, and reached `parseHexInt` on it.
  ## On anything that was not hex pairs it raised an UNHANDLED `ValueError` and
  ## the producer DIED: measured, with `hex`'s `stripPrefix` emptied the demo
  ## producer stopped on `parseHexInt: invalid hex integer: 0x` — a stack trace
  ## naming a string function, from which nothing says which identifier, which
  ## chain, or that an encoding was involved at all.
  ##
  ## It is now private, and every path that reaches it has already called
  ## `identifierIndexKey`, which refuses BY NAME anything the `hex` alphabet does
  ## not admit. So the `parseHexInt` below cannot be reached with a non-hex
  ## digit, and the diagnosis a caller gets names the encoding, the identifier,
  ## the offending character and the alphabet instead of a parser.
  ##
  ## "Every path" is load-bearing and was briefly untrue — see the note in
  ## `encodeHashShard`'s format-1 arm, which is where the mutant found it.
  var s = identifierPayload(HashIndexLegacyEncoding, identifier)
  if s.len mod 2 == 1: s = s & "0"
  for i in countup(0, s.len - 2, 2):
    result.add chr(parseHexInt(s[i .. i+1]))

proc bytesToHex*(b: string): string =
  ## Decoded bytes back to lowercase hex — **a renderer for format-1 rows, and
  ## for nothing else.**
  ##
  ## It survived the widening because format 1 survived it. What it must not
  ## become again is the index's idea of what an identifier looks like: a
  ## format-2 row stores characters in its own alphabet and there is nothing here
  ## for it to render.
  for c in b: result.add toLowerAscii(toHex(ord(c), 2))

func shardIsAllHex*(entries: seq[HashEntry]): bool =
  ## Can this shard be written in format 1?
  ##
  ## **The format is chosen by the CONTENT and never by a flag**, which is what
  ## makes the compatibility window mechanical rather than remembered. A shard of
  ## hex entries is format 1, so `/idx/hash/1/` stays reproducible byte for byte;
  ## a shard holding anything else is format 2 and belongs in `/idx/hash/2/`,
  ## which is published alongside it (§6.1). Neither producer decides.
  for e in entries:
    if e.encoding != HashIndexLegacyEncoding: return false
  true

proc encodeHashShard*(entries: seq[HashEntry], prefixLen: int): string =
  ## Encode one shard. `entries` must all share the same `prefixLen` payload
  ## prefix (the caller groups them); they are re-sorted here so output is
  ## canonical — a regeneration must be byte-identical however the caller
  ## happened to order them.
  ##
  ## The format follows the content: `shardIsAllHex` picks format 1, which is
  ## byte-for-byte what this function has always emitted, and anything else picks
  ## format 2. Both are self-described by the `fmt` byte the header already had.
  if entries.shardIsAllHex:
    # ── FORMAT 1, UNCHANGED ──────────────────────────────────────────────────
    #
    # Every expression below is the one that produced the shards now on a CDN
    # (Publishing-And-Caching §6.1). It is not refactored, not shared with the
    # format-2 arm, and not "obviously equivalent to" anything: this is the arm
    # `just byte-identity` holds to zero, and the only way to keep that claim
    # cheap to check is for the code to be readable as the same code.
    # THE REFUSAL RUNS FIRST, ON EVERY ENTRY, BEFORE A BYTE IS PARSED — and this
    # arm is exactly where it was missing. `hexUnits` reaches `parseHexInt`, and
    # for one revision the format-1 arm called it directly while only format 2
    # keyed through `identifierIndexKey`. THE MUTANT CAUGHT IT: with `hex`'s
    # `stripPrefix` emptied, `just byte-identity-mutant` still killed the demo
    # producer with `Error: unhandled exception: invalid hex integer: 0x` — the
    # very message this whole step replaced, arriving from the one path that had
    # been left in front of the parser rather than behind it.
    var hashLen = 0
    for e in entries:
      discard identifierIndexKey(HashIndexLegacyEncoding, e.identifier)
      let n = hexUnits(e.identifier).len
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
      let ha = hexUnits(a.identifier); let hb = hexUnits(b.identifier)
      if ha != hb: (if ha < hb: -1 else: 1)
      elif a.chain != b.chain: cmp(a.chain, b.chain)
      else: cmp(a.kind, b.kind))
    result = hashMagic
    result.putU8 HashFmtHexBytes
    result.putU8 prefixLen
    result.putU8 hashLen
    result.putU8 chains.len
    result.putU32 uint32(es.len)
    for c in chains: result.putStr8 c
    for e in es:
      var hb = hexUnits(e.identifier)
      while hb.len < hashLen: hb = hb & '\0'
      result.add hb
      result.putU8 idxOf(e.chain)
      result.putU8 e.kind
    return

  # ── FORMAT 2 ───────────────────────────────────────────────────────────────
  #
  # The identifier's KEY FORM as characters, NUL-padded to a uniform
  # self-described width, plus an index into an encoding dictionary beside the
  # chain one. NUL is the pad because it is a digit of NO alphabet in the closed
  # set, so a stored value and its padding are distinguishable without knowing
  # which encoding the row is — which the reader does not know until it has read
  # the row's tag.
  var unitLen = 0
  var encodings: seq[string]
  var chains: seq[string]
  for e in entries:
    let k = identifierIndexKey(e.encoding, e.identifier)
    if k.len > unitLen: unitLen = k.len
    if e.encoding notin encodings: encodings.add e.encoding
    if e.chain notin chains: chains.add e.chain
  doAssert unitLen <= 0xFF,
    "hash-index entry too long for a u8 width: " & $unitLen & " characters"
  chains.sort()
  encodings.sort()
  var chainIdx = proc(c: string): int =
    for i, x in chains:
      if x == c: return i
    -1
  var encIdx = proc(c: string): int =
    for i, x in encodings:
      if x == c: return i
    -1
  var es = entries
  es.sort(proc(a, b: HashEntry): int =
    let ka = identifierIndexKey(a.encoding, a.identifier)
    let kb = identifierIndexKey(b.encoding, b.identifier)
    if ka != kb: (if ka < kb: -1 else: 1)
    elif a.encoding != b.encoding: cmp(a.encoding, b.encoding)
    elif a.chain != b.chain: cmp(a.chain, b.chain)
    else: cmp(a.kind, b.kind))
  result = hashMagic
  result.putU8 HashFmtKeyForm
  result.putU8 prefixLen
  result.putU8 unitLen
  result.putU8 chains.len
  result.putU8 encodings.len
  result.putU32 uint32(es.len)
  for c in chains: result.putStr8 c
  for c in encodings: result.putStr8 c
  for e in es:
    var k = identifierIndexKey(e.encoding, e.identifier)
    while k.len < unitLen: k = k & '\0'
    result.add k
    result.putU8 chainIdx(e.chain)
    result.putU8 encIdx(e.encoding)
    result.putU8 e.kind

proc decodeHashShard*(data: string): tuple[fmt, prefixLen, unitLen: int,
                      entries: seq[HashEntry], err: string] =
  ## Read a shard of EITHER published format.
  ##
  ## `fmt` is reported rather than swallowed, because a caller that has to say
  ## what it read — the validator does, and so does the descriptor check — cannot
  ## re-derive it from the entries: a format-2 shard whose rows all happen to be
  ## hex is indistinguishable from a format-1 one once decoded, which is the
  ## point of the tag.
  var r = Reader(data: data)
  if r.bytes(4) != hashMagic:
    return (0, 0, 0, @[], "bad magic (expected " & hashMagic & ")")
  let fmt = r.u8
  if fmt notin [HashFmtHexBytes, HashFmtKeyForm]:
    # §6.1: "a client encountering an unknown major version renders a 'please
    # reload' state rather than misinterpreting". The message is the reader's
    # half of that — it names what arrived and what this build knows, so the
    # caller can say "please reload" with a reason instead of "not found".
    return (fmt, 0, 0, @[],
            "unsupported hash-index format " & $fmt & " (this build reads " &
            $HashFmtHexBytes & " and " & $HashFmtKeyForm & ")")
  result.fmt = fmt
  result.prefixLen = r.u8
  result.unitLen = r.u8
  let chainCnt = r.u8
  let encCnt = if fmt == HashFmtKeyForm: r.u8 else: 0
  let entryCnt = int(r.u32)
  var chains: seq[string]
  for _ in 0 ..< chainCnt: chains.add r.str8
  var encodings: seq[string]
  for _ in 0 ..< encCnt: encodings.add r.str8
  for _ in 0 ..< entryCnt:
    let unit = r.bytes(result.unitLen)
    let ci = r.u8
    let ei = if fmt == HashFmtKeyForm: r.u8 else: 0
    let kind = r.u8
    if r.err.len > 0: break
    if ci < 0 or ci >= chains.len:
      result.err = "chain index out of range"; return
    if fmt == HashFmtKeyForm:
      if ei < 0 or ei >= encodings.len:
        result.err = "encoding index out of range"; return
      result.entries.add HashEntry(
        encoding: encodings[ei],
        # Trailing NULs are padding and nothing else — no alphabet in the closed
        # set contains one — so this strip is exact rather than the cosmetic one
        # the format-1 arm below has to make do with.
        identifier: unit.strip(leading = false, trailing = true, chars = {'\0'}),
        chain: chains[ci], kind: kind)
    else:
      # FORMAT 1 CANNOT STORE THE `0x`, because it stores decoded pairs — so the
      # prefix is reconstructed here rather than left to every caller. It used to
      # be left to every caller, and `client/searchboot/` open-coded `"0x" & …`
      # in three places to put it back; a format-2 row needs none of that and
      # would have been wrong if it got it.
      result.entries.add HashEntry(
        encoding: HashIndexLegacyEncoding,
        identifier: identifierEncodingRule(HashIndexLegacyEncoding).stripPrefix &
          bytesToHex(unit).strip(leading = false, trailing = true, chars = {'0'}),
        chain: chains[ci], kind: kind)
  # NB: the format-1 trailing-zero strip above is cosmetic for lookup; an exact
  # match there compares bytes at the stored width.
  if r.err.len > 0: result.err = r.err

proc entryPayload*(e: HashEntry): string =
  ## An entry's payload — what a query prefix is matched against.
  ##
  ## ONE derivation, applied to the stored key form, so a shard's contents are
  ## matched by the same rule its file name was chosen by. A second expression
  ## here would be a second place for "which shard holds this" and "does this
  ## shard hold it" to disagree, and they would disagree silently: the shard
  ## would be fetched and would answer no.
  identifierPayload(e.encoding, e.identifier)

proc lookupHash*(data, encoding, identifier: string): seq[HashEntry] =
  ## Exact lookup used by the validator's coverage check: does this shard resolve
  ## this identifier?
  ##
  ## Format 1 compares the query's decoded bytes to the stored bytes at the
  ## stored width, which is what it has always done. Format 2 compares key forms
  ## directly, and additionally requires the ENCODING to match — a format-2 shard
  ## can hold a hex payload and a base58 payload that read the same, and calling
  ## those one entity is the collision §5.1 says the builder resolves by carrying
  ## both claims rather than by merging them.
  let dec = decodeHashShard(data)
  if dec.err.len > 0: return @[]
  if dec.fmt == HashFmtKeyForm:
    let want = identifierIndexKey(encoding, identifier)
    for e in dec.entries:
      if e.encoding == encoding and e.identifier == want: result.add e
    return
  if encoding != HashIndexLegacyEncoding: return @[]
  var want = hexUnits(identifier)
  while want.len < dec.unitLen: want = want & '\0'
  want = want[0 ..< dec.unitLen]
  for e in dec.entries:
    var hb = hexUnits(e.identifier)
    while hb.len < dec.unitLen: hb = hb & '\0'
    if hb[0 ..< dec.unitLen] == want: result.add e

