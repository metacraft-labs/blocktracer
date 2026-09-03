## viewmodel/search_shapes.nim — Search-And-Routing §2's shape detection, and
## the canonical form §13.1 of SEO-And-Crawl-Budget requires before a path is
## computed from a query.
##
## ## Why this is its own module
##
## §2's classification is "run on every keystroke", and it is the one part of
## search that both halves of the product need: `SearchVM` classifies to pick a
## mechanism, and the browser bundle that actually resolves `?q=` on the static
## site (`client/searchboot/`) has to classify the same string the same way. A
## `nim js` bundle cannot pull in `search_vm` — that module reaches the isonim
## signal graph and the Client SDK facade — so the alternative to this file was
## a second copy of the table, in JavaScript, drifting from the first.
##
## Nothing here allocates beyond the result, imports nothing but `strutils`,
## and does no I/O, which is what makes it shareable and what makes §2's
## per-keystroke budget (< 1 ms, §8) affordable.
##
## ## Canonicalisation is separate from classification, deliberately
##
## SEO-And-Crawl-Budget §13.1 lists "Upper/lower-case hash alias" as an alias
## class that must resolve to one canonical encoding, and `docs/data-contract.md`
## D4 fixes what that encoding is in this tree: the shard key is the leading hex
## of the **0x-stripped** hash, and every published object name is lowercase.
## A pasted checksummed or upper-cased hash therefore classifies perfectly and
## then misses on every chain — a false "not on this chain" for an object that
## is right there.
##
## `canonicalQuery` fixes exactly that and nothing more. It does NOT lowercase a
## non-hex query, because Threat-Model §11 requires that "normalization must not
## collapse distinct identifiers into one result" and case is significant in
## base58, base64url and bech32 — the very encodings §2's remaining rows use.

import std/strutils

const ResultSlotId* = "search-result"
  ## The element on `/search` that the answer is written into.
  ##
  ## It lives here, with the classification rules, because it is the other
  ## thing the two halves of search must agree on and neither half can check
  ## the other: `pages/search.nim` renders the element and
  ## `client/searchboot/` writes it. A drifted id renders an empty page and
  ## reports nothing — indistinguishable from the defect this route was already
  ## in. This module is the only one both can import: the page cannot import
  ## the bundle, and the bundle cannot import the page's isonim DSL.

type
  QueryShape* = enum
    ## The syntactic classes that can be resolved with the mechanisms this
    ## deployment has. Deliberately a subset of Search-And-Routing §2's table:
    ## the base58, base64url, bech32, SS58 and name-suffix rows all resolve
    ## through the hash index or the name shards.
    qsEmpty
    qsDecimal
      ## A block number, slot or checkpoint. §3: "numeric search is entirely
      ## local" — it costs no request at all.
    qsHash32
      ## `0x` + 64 hex. Both a plausible transaction hash and a plausible block
      ## hash; both are tried.
    qsAddress20
      ## `0x` + 40 hex.
    qsHexShort
      ## `0x` + 1–63 hex. A Starknet felt: address, class hash or transaction
      ## hash. Tried as all three.
    qsText
      ## Anything else — a name, a symbol, a label. Needs the name shards.

func isHexDigits*(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin HexDigits: return false
  true

func hexBodyOf*(raw: string): string =
  ## The hex body of a `0x`-prefixed query, or "" if this is not one.
  ##
  ## One reader for the prefix rule, so `shapesOf` and `canonicalQuery` cannot
  ## disagree about what counts as a hex identifier.
  let q = raw.strip
  if q.len > 2 and q[0] == '0' and (q[1] == 'x' or q[1] == 'X'):
    let body = q[2 .. ^1]
    if isHexDigits(body): return body
  ""

func canonicalQuery*(raw: string): string =
  ## The form a path may be computed from — SEO-And-Crawl-Budget §13.1's
  ## "one documented canonical encoding", which here (data-contract D4) is
  ## `0x` + lowercase hex.
  ##
  ## Whitespace goes for every query; case goes for hex identifiers ONLY.
  let q = raw.strip
  let body = hexBodyOf(q)
  if body.len == 0: return q
  "0x" & body.toLowerAscii

func shapesOf*(raw: string): set[QueryShape] =
  ## Deterministic syntactic classification. Pure and allocation-light, so §2's
  ## "run on every keystroke" is affordable, and testable with no tree at all.
  let q = raw.strip
  if q.len == 0: return {qsEmpty}
  block decimal:
    for c in q:
      if c notin Digits: break decimal
    result.incl qsDecimal
  let body = hexBodyOf(q)
  if body.len > 0:
    if body.len == 64: result.incl qsHash32
    elif body.len == 40:
      result.incl qsAddress20
      # An address is also a valid short felt on Cairo, and §2 lists both.
      result.incl qsHexShort
    elif body.len < 64: result.incl qsHexShort
  if result.card == 0: result.incl qsText

func isHashLike*(shapes: set[QueryShape]): bool =
  ## The shapes the direct path (§4) can address an object with. One predicate,
  ## because `SearchVM.resolve` and the browser bundle must agree on which
  ## queries cost a request and which cost nothing.
  qsHash32 in shapes or qsHexShort in shapes
