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
## `canonicalHash` fixes exactly that and nothing more. It does NOT lowercase a
## non-hex query, because Threat-Model §11 requires that "normalization must not
## collapse distinct identifiers into one result" and case is significant in
## base58, base64url and bech32 — the very encodings §2's remaining rows use.
## **That limit is deliberate and must not be widened.** Blanket-lowercasing
## every query would silently corrupt a TON address (base64url), a Solana
## signature (base58) and a Cardano address (bech32), and it would corrupt them
## into strings that still LOOK like identifiers — the failure would be a
## confident wrong answer, not an error.
##
## ## `0x` is a declaration; bare hex is an inference
##
## §2's table names only the `0x`-prefixed forms, so accepting a bare hash is an
## extension of the spec rather than a reading of it. It is worth making,
## because the prefix is punctuation the user did not choose — a hash copied
## from a log line, a CSV column or another explorer's table arrives without it,
## and refusing those was the difference between "search is broken" and "search
## works" for anyone not pasting from an explorer URL. Measured before this
## change, on a hydrated build of 37afe34: `0x…`, `0X…`, mixed case and
## surrounding whitespace all resolved; the same hash with the prefix removed
## reported `unsupported` and went nowhere.
##
## But the two forms do not carry the same evidence, and `hexBodyOf` treats them
## differently on exactly one axis — length. With `0x`, the user has SAID the
## string is hex, so §2's ranges are honoured as written, down to a one-digit
## Cairo felt. Without it, the string is hex only by inference, and "cafe",
## "dead", "beef", "add" and "decade" are all valid hex and all far more likely
## to be words. `BareHexFloor` is where the inference starts being worth making.
## Both forms keep every other shape they match: a bare all-digit string is
## still a block number, because §2 is explicit that "a single input may match
## several shapes; all matches are carried forward".

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

const BareHexFloor* = 4
  ## How many hex digits an UNPREFIXED string needs before it is read as a hex
  ## identifier at all. Nothing to do with shard depth — see `search_index` for
  ## that, which is derived from the published descriptor and is not a constant.
  ##
  ## This is the "is that even an identifier" floor, and it applies only where
  ## the user did not write `0x`. Three hex digits of English are common
  ## ("add", "fed", "ace", "bad"); four already are not, and every real
  ## identifier a user pastes is far longer. A `0x` prefix bypasses it entirely,
  ## because there the user has declared the intent and §2's one-digit Cairo
  ## felt is a legitimate query.

func hexBodyOf*(raw: string): string =
  ## The hex body of a hex query — with `0x`/`0X`, or bare — or "" if this is
  ## not one.
  ##
  ## One reader for the whole rule, so `shapesOf` and `canonicalHash` cannot
  ## disagree about what counts as a hex identifier. The asymmetry between the
  ## prefixed and bare forms is the module doc's: a prefix is a declaration, a
  ## bare string is an inference, and only the inference needs a floor.
  let q = raw.strip
  if q.len == 0: return ""
  if q.len > 2 and q[0] == '0' and (q[1] == 'x' or q[1] == 'X'):
    let body = q[2 .. ^1]
    if isHexDigits(body): return body
    # `0x` followed by non-hex is not a bare hex string that happens to start
    # "0x" — it is a malformed identifier, and falling through to the bare
    # branch would silently reinterpret the prefix as two more digits.
    return ""
  if q.len >= BareHexFloor and isHexDigits(q): return q
  ""

func canonicalHexBody*(raw: string): string =
  ## The hex digits of a query, lowercased and with any `0x` removed — the form
  ## the published index and the published object names are keyed by
  ## (data-contract D4).
  ##
  ## This exists because `hexBodyOf` does NOT lowercase, and the difference bit
  ## immediately: the shard scan matched the raw body against index keys that
  ## are all lowercase, so `0xABC…` and a bare uppercase hash resolved before
  ## the index landed and stopped resolving after it. Every caller that touches
  ## index bytes or object paths wants this one, so it is the one with the
  ## obvious name, and `hexBodyOf` is left as the syntactic reader it is.
  hexBodyOf(raw).toLowerAscii

func canonicalHash*(raw: string): string =
  ## The form a path may be computed from — SEO-And-Crawl-Budget §13.1's "one
  ## documented canonical encoding", which here (data-contract D4) is `0x` +
  ## lowercase hex — or "" when the query is not a hex identifier.
  ##
  ## Returning "" rather than the input is what keeps the DECIMAL path intact,
  ## and that is a real hazard rather than a stylistic choice. The previous
  ## version returned the stripped query unchanged for a non-hex input, and
  ## callers did `shapesOf(canonicalQuery(q))`. Once bare hex is accepted, `q`
  ## and `canonicalHash(q)` no longer classify the same: `68231` is a block
  ## height AND a hex string, and canonicalising first would have rewritten it
  ## to `0x68231` and lost the height — turning §3's zero-request local
  ## inference into six 404s. So callers now classify the RAW query and
  ## canonicalise only the branch that computes an object path.
  let body = canonicalHexBody(raw)
  if body.len == 0: return ""
  "0x" & body

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
