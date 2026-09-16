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
## Nothing here allocates beyond the result and does no I/O, which is what makes
## it shareable and what makes §2's per-keystroke budget (< 1 ms, §8)
## affordable. It imports `strutils` and `contract/identifier_encoding`, and the
## second one is not free reach: it is where the CASE RULE lives, and this module
## used to open-code that rule as a `toLowerAscii` of its own. It costs nothing
## in the one bundle that matters — `client/searchboot/` already reaches
## `identifier_encoding` through `paths.nim`, because it recomputes the
## producer's shard path in a tab — and the alternative was the second copy of a
## per-encoding rule that this whole seam exists to remove.
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

import std/[strutils, algorithm]
import ../../../src/blocktracer/contract/identifier_encoding

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
    ## deployment has.
    ##
    ## IT WAS DELIBERATELY A SUBSET OF §2's TABLE — the hex rows only — and it is
    ## not any more. The base58, base64url, bech32, bech32m and SS58 rows all
    ## landed as `qsEncodedId` when the §5 index stopped being hex-only, because
    ## a row this enum declines to recognise is a row whose identifiers the index
    ## holds and search cannot reach: a false absence under §5.0a. What is still
    ## outside it is the name-suffix row (`*.eth`, `*.sol`, …), which resolves
    ## through §6's name shards and is `qsText` here.
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
    qsEncodedId
      ## **Matches one or more NON-HEX rows of §2's table** — base58, base64,
      ## base64url, bech32, bech32m or SS58. Which ones is
      ## `identifierEncodingsMatching`'s answer, not this enum's.
      ##
      ## ONE MEMBER AND NOT SIX, DELIBERATELY. Six would be a second copy of the
      ## encoding set, in a Nim enum, in the client — which is the exact shape of
      ## duplication this whole seam exists to remove, and the shared file's own
      ## header says why a set closed in one language and open in another is not
      ## closed. The enum's job is to say WHICH MECHANISM resolves a query, and
      ## every one of those six rows resolves the same way: through the §5 hash
      ## index. NOT NECESSARILY AT THE SAME SHARD — that was this comment's claim
      ## and it is false; see `indexProbesOf`, which returns one probe per
      ## distinct payload precisely because a query can be admissible under two
      ## rows whose payloads differ. The mechanism is still one, which is what
      ## the enum is about. The encodings themselves are data and are read as
      ## data.
    qsText
      ## Anything else — a name, a symbol, a label. Needs the name shards.

func isAllDigits*(s: string): bool =
  if s.len == 0: return false
  for c in s:
    if c notin Digits: return false
  true

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
  # A BARE ALL-DIGIT STRING IS A NUMBER, NOT INFERRED HEX — and this is a
  # budget, not a preference. §3: "numeric search is entirely local"; §8 gives
  # it "< 1 ms, ZERO REQUESTS". Inferring hex from `18000000` made a block
  # number cost one index fetch, or six probes without an index, and
  # `test_chain_viewmodels`' "local inference costs no request at all" went red
  # the moment bare hex was accepted — which is the budget defending itself.
  #
  # Nothing is lost that the user cannot ask for: a hex identifier whose digits
  # are ALL decimal still resolves with an explicit `0x`, and for a 64-character
  # hash the odds of that are about one in ten thousand billion.
  if q.len >= BareHexFloor and isHexDigits(q) and not isAllDigits(q): return q
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
  ##
  ## THE FOLD IS THE DECLARED ONE AND NOT A `toLowerAscii` OF THIS MODULE'S OWN.
  ## `identifierKeyForm("hex", …)` reads the case rule out of
  ## `tools/chain/identifier-encodings.json`, which is the same rule the
  ## producer's shard derivation and the §5 index key read — so "the form the
  ## published index and the published object names are keyed by" is a fact this
  ## function shares with the code that produces them rather than a claim it
  ## makes about them. It is spelled `hex` here, explicitly, because this
  ## function is reached from `shapesOf`'s hex branch and from nowhere else: the
  ## module's header says why a query of another encoding must not be folded at
  ## all, and naming the token is what makes that restriction visible instead of
  ## implied by which branch happens to call it.
  identifierKeyForm("hex", hexBodyOf(raw))

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
  ##
  ## **THIS IS NOW LOAD-BEARING FOR INDEX KEY DERIVATION AND NOT ONLY FOR SEARCH
  ## UX**, which is a change in what a defect here costs. It used to decide which
  ## mechanism ran; it now also decides whether a query reaches the §5 index at
  ## all, and `indexKeysOf` below derives the shard key from the same table. A
  ## row this function declines to recognise is a row whose identifiers are
  ## unreachable by search even though the producer indexed them — a false
  ## absence rather than a missing feature, which is what §5.0a forbids. It is
  ## swept by `tools/chain/identifier-encoding-selftest.mjs` for that reason.
  ##
  ## AND IT STILL FITS §2's PER-KEYSTROKE BUDGET, measured rather than assumed,
  ## because reading a shared table on every keystroke is exactly the kind of
  ## thing that quietly does not. `-d:release`, 2026-09-15, on a contended box:
  ## `identifierEncodingsMatching` is **8.7 µs** a call (20,000 in 0.174 s),
  ## `identifierPayload` **1.0 µs** and `identifierKeyForm` **0.5 µs**. §8 budgets
  ## classification at "< 1 ms, zero requests"; this is two orders under it, and
  ## the non-hex branch is only reached when the hex reader has already declined.
  let q = raw.strip
  if q.len == 0: return {qsEmpty}
  if isAllDigits(q): result.incl qsDecimal
  let body = hexBodyOf(q)
  if body.len > 0:
    if body.len == 64: result.incl qsHash32
    elif body.len == 40:
      result.incl qsAddress20
      # An address is also a valid short felt on Cairo, and §2 lists both.
      result.incl qsHexShort
    elif body.len < 64: result.incl qsHexShort
  else:
    # THE NON-HEX ROWS, READ FROM THE SHARED TABLE RATHER THAN SPELLED HERE.
    #
    # Guarded by the hex branch having declined, and that guard is not an
    # optimisation: `hexBodyOf` implements a MEASURED extension of §2 — a bare
    # hash with no `0x` is accepted above `BareHexFloor`, and a bare all-digit
    # string is refused so §3's zero-request local inference survives — and none
    # of that is expressible in the shared file's length-and-alphabet rule. So
    # hex keeps the implementation that carries its own evidence, the shared
    # table is consulted for the rows that have none of those subtleties, and
    # `tests/tcontract.nim` pins that the two agree about every `0x` query.
    if identifierEncodingsMatching(q).len > 0: result.incl qsEncodedId
  if result.card == 0: result.incl qsText

type
  IndexProbe* = tuple[encoding, identifier, payload: string,
                      encodings: seq[string]]
    ## One §5 index lookup a query implies — which is one REQUEST and, separately,
    ## a SET of encodings that request's bytes must be scanned under.
    ##
    ## `payload` is the PAYLOAD the shard path is sliced from, carried rather than
    ## recomputed because it is the field the probe is deduplicated by (see
    ## `indexProbesOf`). `encoding` and `identifier` are the REPRESENTATIVE pair
    ## the shard path is derived from.
    ##
    ## **`encoding` IS FOR SHARD DERIVATION AND `encodings` IS FOR THE SCAN, and
    ## conflating them is the defect this field exists to close.** The probe used
    ## to carry `encoding` alone, and the scan filtered on it — so when two
    ## admitted encodings shared a payload, dedup kept the FIRST by JSON
    ## declaration order and an entry a producer had published under the
    ## discarded one was excluded from the very shard the client fetched. That is
    ## a false ABSENCE, and §5.0a forbids it in the same terms it forbids the
    ## false presence the encoding filter was added for.
    ##
    ## Deriving the shard from the representative is sound where scanning with it
    ## is not, and the asymmetry is not an accident: `hashPrefix` SLICES the
    ## payload and does not pad (`shardKeyFor` pads; this does not), so every
    ## member of `encodings` yields the same shard at every published depth by
    ## construction — while `hitsFor` compares the entry's encoding for equality,
    ## where any member may be the one the producer declared.
    ##
    ## `encodings` IS SORTED, which is what makes the probe independent of the
    ## order of a JSON array. `identifierEncodingsMatching` returns members in
    ## `encodings[]`'s declaration order; a reachability rule may not depend on
    ## that, so the set is normalised before it leaves this function.
    ##
    ## **KNOWN INCOMPLETE, AND DELIBERATELY SO FOR NOW: THERE IS NO
    ## `identifiers: seq[string]`.** `encodings` is a set because dedup must
    ## collapse the REQUEST without collapsing what the request is said to be
    ## about; `identifier` is still a scalar, so the same collapse still discards
    ## the OTHER spellings of the query. Where two readings share a payload and
    ## differ in identifier, the probe keeps one and nothing downstream can tell
    ## that a second existed.
    ##
    ## One consumer is already affected and is documented rather than fixed:
    ## `shownFor` in `client/searchboot/searchboot.nim` decides "do the readings
    ## agree" by comparing probe identifiers, so for 42 swept queries it reports
    ## agreement that is not there and shows a canonical form for a query typed
    ## another way. Its docstring carries the measurement and the reason the
    ## RENDERING is a design question rather than a defect.
    ##
    ## The field is not added here because nothing would read it yet and an unused
    ## field is a claim without a consumer. It is named because this milestone has
    ## produced three consumers of this one missing distinction — which shard is
    ## fetched, what it is scanned under, what the visitor is told — and the next
    ## one should widen the probe rather than rediscover the collapse.

func indexKeysOf*(raw: string): seq[tuple[encoding, identifier: string]] =
  ## **Every §5 index key a query implies** — the client's half of the
  ## derivation, computed from the query string with no tree, no registry and no
  ## request.
  ##
  ## §5's index path carries no chain segment, so the client cannot key by the
  ## chain. It keys by SHAPE, and this returns every (encoding, identifier) pair
  ## the shapes admit. `hashPrefix` turns one into a shard path; the producer
  ## reached the same shard from the chain's declared encoding.
  ##
  ## **THIS IS A SET TO BE CONSUMED WHOLE, NOT A LIST TO PICK FROM**, and that
  ## sentence is here because the opposite was written and shipped. The client
  ## took `keys[0]` under the comment "the first key is enough, and that is a
  ## checked property rather than a hope" — the property being that every member
  ## a query matches yields the same payload, so any one of them selects the
  ## right shard. **It is false, measured over the table as declared**, and
  ## `indexProbesOf` below is the consumption rule that does not need it. Use
  ## that one. This function is the raw derivation and is public for the sweep in
  ## `tests/tcontract.nim`, which is what turned the property from an assertion
  ## about six literals into a census.
  ##
  ## A MEMBER WHOSE ALPHABET CANNOT BE A PATH SEGMENT IS SKIPPED RATHER THAN
  ## RAISED ON. `base64` contains `/`, so it has no shard and the producer never
  ## wrote one — but a 44-character query matches base64 AND base58, and letting
  ## base64 raise would drop a Solana address's perfectly good candidate on
  ## account of an ambiguity the spec itself declares. §2: "all matches are
  ## carried forward"; the ones that cannot be keyed are simply not keys.
  ##
  ## The hex arm is spelled rather than derived, for `shapesOf`'s reason: a bare
  ## hash without `0x` is this module's measured extension, and the canonical
  ## form a hex path is computed from is `canonicalHash`'s, not the shared
  ## table's.
  ##
  ## **THE HEX ARM ADDS A KEY; IT NO LONGER RETURNS ONE.** It was `return @[…]`,
  ## and that early return was a false absence of its own — a third family,
  ## found by the sweep below rather than reported, and NOT a property of §2's
  ## table at all. `hexBodyOf` accepts a BARE hex string, and the hex digits are
  ## a subset of base58's and SS58's alphabets: `A`×46 is 46 uppercase hex
  ## digits *and* a well-formed SS58 account inside SS58's 46–48 band. hex folds
  ## case and SS58 preserves it, so the payloads are `aaaa…` and `AAAA…` and the
  ## shards are `aaaa` and `AAAA` — and the early return dropped the second one
  ## before `indexProbesOf` could ever see it. Measured over the sweep: 42
  ## (candidate, encoding) pairs unreachable, in three shapes — `hex`×`ss58` at
  ## 46–48, `hex`×`base58` at 43–44, and `hex`×`base58` at 44 where `base64`
  ## matches too and is skipped for its `/`.
  ##
  ## `hex` is skipped in the loop when the arm has already fired, because the
  ## shared table would name it a second time with a different spelling of the
  ## same identifier (`0xab…` against `ab…`). Their payloads are equal, so
  ## `indexProbesOf` would have deduplicated them anyway — the guard is here so
  ## that this function's own output does not contain a row that means nothing.
  let q = raw.strip
  if q.len == 0: return
  let hex = canonicalHash(q)
  if hex.len > 0: result.add (encoding: "hex", identifier: hex)
  for enc in identifierEncodingsMatching(q):
    if enc == "hex" and hex.len > 0: continue
    if not identifierEncodingRule(enc).pathSafe: continue
    result.add (encoding: enc, identifier: identifierKeyForm(enc, q))

func indexProbesOf*(raw: string): seq[IndexProbe] =
  ## **Every DISTINCT §5 lookup a query implies** — one probe per distinct
  ## payload, which is one probe per shard, which is one request.
  ##
  ## ## Why this exists: `keys[0]` was not a safe consumption rule
  ##
  ## `indexKeysOf` returns every key the query's shapes admit, and the client
  ## used to take the first on the stated ground that "every member a single
  ## query matches yields the SAME payload, so they all select the same shard".
  ## Two things were wrong with that, and they are different in kind.
  ##
  ## **It is false.** Swept over the closed set as declared — every row's length
  ## band, every alphabet — **462 of 53,935** candidates yield TWO distinct shards
  ## through THIS function, and **420** yield two distinct payloads through the
  ## table's matches alone.
  ##
  ## THE TWO DEFINITIONS, because the gap between them is a population this change
  ## created rather than a disagreement about one number. The shared population is
  ## `sweepCandidates()` in `tests/tcontract.nim` (every member's declared prefixes
  ## × every character of that member's own alphabet × every length up to
  ## `widestPayload + longestPrefix + 2`, plus four deterministic mixed fills per
  ## prefix, deduplicated) — **53,935** strings on the table as declared. On it:
  ##
  ## * **420** — the distinct `identifierPayload`s over a candidate's `pathSafe`
  ##   MATCHES (`identifierEncodingsMatching`) number more than one. This is the
  ##   TABLE's census, and it is silent about bare hex by construction:
  ##   `identifierEncodingsMatching` does not return `hex` for a string with no
  ##   `0x`, because §2's hex rows carry the prefix. It is the figure printed by
  ##   `just test`'s `tcontract` arm "§5.5's old claim is FALSE", and the one the
  ##   sweep header at `tests/tcontract.nim`'s "THE SWEEP" cites.
  ## * **462** — `indexProbesOf` yields more than one distinct shard. This is the
  ##   CLIENT's census, so it is the one the claim above is about, and it is what
  ##   "yield two distinct shards" has to mean in a docstring on this function. It
  ##   is printed by the `tcontract` arm "the ambiguity census, by family and by
  ##   cost", and it is the `2` column of §5.3's histogram
  ##   `{0: 35,357, 1: 18,116, 2: 462}`. Distinct PAYLOADS and distinct SHARDS
  ##   coincide at 462 over this population — measured, not assumed: `hashPrefix`
  ##   slices, so two distinct payloads could in principle share a shard prefix —
  ##   AT EITHER WIDTH, and the two widths are different constants: §5's hash index
  ##   shards on `HashShardPrefixLen` (**2**), while the `addr`/`qqqq` pair in the
  ##   worked example below is `ShardWidth` (**4**), the trace-shard width. A
  ##   collision is likelier at the narrower one, so both were swept: **0**
  ##   candidates hold more distinct payloads than distinct shards at width 4, and
  ##   **0** at width 2.
  ##
  ## The difference is exactly **42**: `hex`×`base58` 24 and `hex`×`ss58` 18, the
  ## bare-hex family that became reachable in this very change when the hex arm of
  ## `indexKeysOf` went from `return` to `add`. Before that a bare-hex-shaped
  ## candidate returned `hex` ALONE and could not yield a second shard at all,
  ## which is why the two definitions used to coincide and why stating only one of
  ## them silently stopped being safe here.
  ##
  ## **THESE 42 ARE NOT THE 42 `shownFor`'s DEFERRAL NOTE NAMES. The two sets are
  ## DISJOINT — measured overlap 0 — and necessarily so.** An earlier revision of
  ## this paragraph called them "those same 42", which is wrong and misleads the
  ## next wave in the worst direction: it suggests one fix closes both. The
  ## bare-hex candidates whose readings disagree number **84**, and the split is by
  ## how many DISTINCT PAYLOADS the disagreeing readings carry:
  ## * **42 with two distinct payloads.** Dedup cannot collapse them, two probes
  ##   survive, two shards are yielded — which is exactly what makes them the
  ##   462 − 420 gap, and so these are the 42 THIS docstring is about. Because two
  ##   probes survive and their identifiers differ, `shownFor` hands the query back
  ##   AS TYPED for all 42: on this half the rendering is already correct.
  ## * **42 with one shared payload.** Dedup collapses the two readings into a
  ##   single probe, so one shard is yielded and they are NOT in the gap above —
  ##   and that collapse is precisely why `shownFor` sees one identifier and
  ##   silently canonicalises a query typed another way. Those are its 42.
  ##
  ## The exclusion is structural, not incidental: a query is in this set only if
  ## two probes survive, and `shownFor` returns a canonical form only if one does,
  ## so no query can be in both. Both halves split 24/18 across `hex`×`base58` and
  ## `hex`×`ss58`, which is why the two figures look like one figure and why the
  ## old wording read plausibly. ONE root cause — the hex arm becoming reachable —
  ## and TWO symptoms over two disjoint populations. Widening the probe closes the
  ## OTHER half; it has nothing to do on this one.
  ##
  ## `addr1` followed by 38 `q`s is 43 characters, which is inside `base58`'s
  ## 43–44 band and written entirely in base58's alphabet, and it carries
  ## `bech32`'s `addr1` prefix with a 38-character data part. Both members are
  ## `pathSafe`, so neither is skipped: the two payloads are the whole string and
  ## the part after the last `1`, and the two shards are `addr` and `qqqq`. A
  ## producer that declared `bech32` wrote `qqqq`; a client that took the first
  ## key asked `addr` and reported the identifier absent. That is the false
  ## absence §5.0a forbids. The overlap is `bech32`×`base58` (**240** witnesses)
  ## AND `bech32`×`ss58` (**180**), which is the same mechanism at a second pair
  ## of bands — SS58's 46–48 against `addr1`/`stake1` data parts of 40–43.
  ##
  ## AND THAT CENSUS IS THE GENERATOR'S, NOT THE TABLE'S. Two further overlap
  ## families exist and are outside the population above, because it fills a
  ## member's prefix only from that member's own alphabet and never varies case:
  ## `base58`×`bech32m` (124) and `bech32m`×`ss58` (93), both reached only through
  ## a case-varied hrp — `FUEL1…` is writable in base58, which excludes `l` and
  ## accepts `L`. They are measured by the cross-alphabet arm in
  ## `tests/tcontract.nim`, over 223,670 candidates.
  ##
  ## **And it was not safe even where it held.** `identifierEncodingsMatching`
  ## returns members in the shared file's DECLARATION ORDER, so "the first key"
  ## is a fact about the order of a JSON array. Reordering `encodings[]` — an
  ## edit with no semantic content, which no build and no test would have
  ## objected to — changes which encoding the client keys a query by. A
  ## consumption rule may not depend on that, whatever the table currently says.
  ##
  ## ## What it costs, stated rather than implied
  ##
  ## §5's first bullet is "two requests to resolve any hash on any chain", and
  ## this spends a third on an AMBIGUOUS query: one index shard per distinct
  ## payload, then one data object. Measured over the sweep, the number of
  ## distinct payloads for one query is **at most 2** over the table as declared,
  ## so the worst case is three requests and the common case is unchanged — 0 of
  ## the 9 realistically-shaped identifiers in `tests/tcontract.nim` is ambiguous,
  ## and no identifier this tree currently publishes is. `tests/tcontract.nim`
  ## pins the bound and reports the census, so §5.3's arithmetic stays
  ## re-derivable by a reader rather than remembered.
  ##
  ## **THE BOUND IS MEASURED OVER TWO POPULATIONS, BECAUSE OVER THE FIRST ONE IT
  ## WAS TRUE BY CONSTRUCTION.** `sweepCandidates` fills a candidate carrying one
  ## member's prefix only from THAT member's own alphabet, and never varies case.
  ## bech32's alphabet is all-lowercase, so every bech32-matching candidate it can
  ## emit is all-lowercase, `hex`'s fold is a no-op on it, and a string whose hex,
  ## base58-family and bech32 readings are three DIFFERENT payloads is outside the
  ## population entirely — the generator could not have found a third payload
  ## whatever the table said. A second arm takes the cross product (every declared
  ## prefix × every declared alphabet × four case variants, 223,670 candidates) and
  ## re-measures **2** there. It is not a vacuous population: it reaches 22,976
  ## bech32-matching strings that are not all-lowercase, and two overlap families
  ## the first generator cannot emit at all — `base58`×`bech32m` and
  ## `bech32m`×`ss58`, both needing a case-varied hrp, since base58 excludes `l`
  ## and accepts `L`.
  ##
  ## One additive row would move it, which is what makes the arm worth its runtime:
  ## a `bc1` hrp is spellable in hex (`b`, `c`, `1` are hex digits), so `BC1` + 40
  ## characters folds to `bc1…` under hex, preserves as `BC1…` under base58 and
  ## slices to the part after the last `1` under bech32 — three payloads, four
  ## requests. Executed with the row temporarily added: the cross arm reports 3 and
  ## the own-alphabet arm still reports 2.
  ##
  ## ## Deduplicated by PAYLOAD FOR THE REQUEST — AND NOT FOR THE SCAN
  ##
  ## `hashPrefix` slices the payload and does not pad — `shardKeyFor` pads, this
  ## does not — so two keys with the same payload name the same shard at every
  ## published depth and the same `minPrefixLen` verdict. Deduplicating by the
  ## encoding instead would have kept `base58` and `base64url` probes of one
  ## 48-character string as two requests for one file.
  ##
  ## **BUT THE DISCARDED KEYS' ENCODINGS ARE KEPT, AND DROPPING THEM WAS A FALSE
  ## ABSENCE OF THE SAME CLASS AS `keys[0]`.** This function used to collapse a
  ## payload group to its FIRST member and return that member's encoding alone;
  ## `hitsFor` then filtered the fetched shard on it. So an entry a producer had
  ## published under one of the discarded encodings was excluded from the very
  ## shard the client had just fetched — nothing was missing from the request,
  ## and the answer was still "absent". Measured, before the fix, over the table
  ## as declared: `a`×43 matches `base58`, whose payload equals folded `hex`'s, so
  ## the group collapsed to `hex` and a `base58` producer's entry returned 0 hits;
  ## `a`×46 the same against `ss58`; `EQ` + `A`×46 matches `base64url` AND `ss58`
  ## with one payload, so an `ss58` producer's entry returned 0 hits. 216
  ## witnesses in the sweep: `base64url`+`ss58` in one family and `hex`+`base58`
  ## and `hex`+`ss58` in the other two.
  ##
  ## And it was `keys[0]` in its second respect too, not merely in its first: the
  ## surviving member was the first in the JSON array's DECLARATION ORDER, so
  ## reordering `encodings[]` — semantically empty — moved which producer was
  ## findable. `keys[0]` had not been removed; it had been moved out of "which
  ## shard is fetched" and into "which encoding the shard is scanned under". The
  ## set below is SORTED so that no caller can inherit that dependence again.
  var groups: seq[IndexProbe] = @[]
  for k in indexKeysOf(raw):
    let payload = identifierPayload(k.encoding, k.identifier)
    var at = -1
    for i, r in groups:
      if r.payload == payload: at = i; break
    if at < 0:
      groups.add (encoding: k.encoding, identifier: k.identifier,
                  payload: payload, encodings: @[k.encoding])
    elif k.encoding notin groups[at].encodings:
      groups[at].encodings.add k.encoding
  for g in groups.mitems:
    g.encodings.sort()
  groups

func isHashLike*(shapes: set[QueryShape]): bool =
  ## The shapes the direct path (§4) can address an object with. One predicate,
  ## because `SearchVM.resolve` and the browser bundle must agree on which
  ## queries cost a request and which cost nothing.
  ##
  ## `qsEncodedId` joined it when the index stopped being hex-only. Before that
  ## a base58 or bech32 query was `qsText` and went to §6's name shards, which is
  ## why the hex-only index was never incomplete for the clients that read it —
  ## see `HashIndexVersionAll` in `contract/hashshard.nim`, where that fact is
  ## what makes the compatibility window sound.
  qsHash32 in shapes or qsHexShort in shapes or qsEncodedId in shapes
