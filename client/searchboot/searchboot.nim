## searchboot.nim — the half of search that has to be in a browser.
##
##     nim js -d:release -o:searchboot/search.js searchboot/searchboot.nim
##
## ## What was broken, and why nothing caught it
##
## The home page, the nav and `/search` all render a real `<form action="/search"
## method="get">`. Submitting it navigates to `/search/?q=…` and that page
## renders — so every layer reported success, and the feature did nothing. A
## static file server cannot read `?q=`, `pageLayout` ships no `<script>` by
## design, and `createSearchVM` had exactly one caller in the repository: a unit
## test. `SearchVM` is a correct, spec-derived implementation of
## Search-And-Routing §2–§4 that was never once constructed by the product.
##
## This module is the missing caller. It is the smallest thing that closes the
## chain: `?q=` in, a rendered answer out.
##
## ## It is a SEPARATE bundle from `client/hydrate/`, deliberately
##
## `hydrate.js` is 1.3 MB and links the CodeTracer Embed SDK, because it drives
## a replay session. Search needs none of that, and AGENTS.md §1a's property —
## everything outside `client/hydrate/` compiles with no debugger on the Nim
## path — is worth more than one fewer build step. Putting search in the
## debugger bundle would also have made every `/search` visit pay for a
## debugger, and made this module's gate depend on the Embed SDK being
## available to run at all.
##
## ## The mechanism it implements is §5.4's, and that is not a shortcut
##
## Search-And-Routing §5 wants two requests via `/idx/hash/{version}/{prefix}.bin`.
## That index IS published in this tree, and it is unreadable from here:
## `search_vm.nim`'s module doc records why (the `@blocktracer/client` facade
## exports no index reader, and reaching `blocktracer/contract/searchidx`
## directly is what `ci/test/client-sdk-boundary.sh` exists to prevent).
##
## §5.4 answers exactly this situation, and answers it as policy rather than as
## a degradation:
##
##   > If the index is unavailable or a version is stale, the client falls back
##   > to probing configured chains directly. Slower and noisier, never wrong.
##   > **Search must never fail because an index did not load.**
##
## So the fan-out below is the specified behaviour for a client that cannot read
## the index, not an approximation of the behaviour that would be. With three
## published chains it costs six conditional requests and resolves a hash on any
## of them.
##
## ## The split with `SearchVM`
##
## Every RULE is Nim, and every rule is the same code the VM uses:
## `canonicalHash` and `shapesOf` come from `viewmodel/search_shapes`, and the
## object paths from `blocktracer_client_paths` — the module whose whole purpose
## is that the layout lives in one place. What is JavaScript here is I/O and the
## DOM, because `ObjectStore.fetchProc` is synchronous and §4's fan-out has to be
## concurrent in a tab.
##
## `candidatesFor` below is therefore the honest seam: Nim decides what would be
## requested and where each answer lands, and returns it as data. A test can read
## that list without a browser, and the browser cannot invent a path Nim did not
## produce.

import std/strutils

import viewmodel/search_shapes
import blocktracer_client_paths
import blocktracer/contract/hashshard

type
  IndexMeta* = object
    ## `/idx/hash/meta.json`, as the browser needs it.
    ##
    ## `prefixLen` is read, never assumed. §5.3 requires shard depth to be
    ## recomputed as the corpus grows — "more chains or more history means a
    ## deeper prefix" — so a client that compiled in a depth would compute
    ## wrong shard paths the first time the index deepened, and would report
    ## every hash as absent while doing it.
    version*: string
    prefixLen*: int
    shards*: seq[string]
      ## Every OCCUPIED prefix. A query whose shard is not in this list is
      ## answered with zero further requests, and answered definitively: §5's
      ## index is exact, so an absent shard is an absent object rather than an
      ## unknown one.

  IndexHit* = object
    chain*: string
    kind*: int
    identifier*: string
      ## The identifier AS PUBLISHED, in key form — the route's id segment. It
      ## was `hexHash` and carried no `0x`, which every consumer then put back.
    route*: string

func parseMeta*(packed: string): IndexMeta =
  ## `version|prefixLen|shard,shard,…` from the JS boundary, or a zero
  ## `prefixLen` meaning "no index" — which is §5.4's trigger, not an error.
  let parts = packed.split('|')
  if parts.len != 3: return
  var n = 0
  try: n = parseInt(parts[1])
  except ValueError: return
  if n <= 0: return
  result.version = parts[0]
  result.prefixLen = n
  for s in parts[2].split(','):
    if s.len > 0: result.shards.add s

func bytesFromHex*(hex: string): string =
  ## The shard's bytes, from the hex the boundary hands over. "" on anything
  ## malformed, which the caller reads as "the index did not load" (§5.4).
  if hex.len == 0 or hex.len mod 2 == 1: return ""
  for i in countup(0, hex.len - 2, 2):
    try: result.add chr(parseHexInt(hex[i .. i + 1]))
    except ValueError: return ""

func minPrefixLen*(m: IndexMeta): int =
  ## The shortest query this index can answer, which is its shard depth: a
  ## shorter prefix selects no shard, so there is nothing to fetch.
  ##
  ## Derived, and surfaced to the reader rather than swallowed. A query below
  ## it is NOT a miss, and rendering it as one would be the false-absence
  ## defect this route has already shipped once.
  m.prefixLen

func shardFor*(m: IndexMeta; encoding, identifier: string): string =
  ## The shard a query falls in — §5's "the client computes the shard path
  ## directly". "" when the query is too short to select one.
  ##
  ## **THROUGH `hashPrefix`, WHICH IS THE PRODUCER'S OWN DERIVATION**, rather
  ## than slicing here. It sliced here for one revision and the boundary sweep
  ## caught it: this module held `payload[0 ..< m.prefixLen]` while the exporter
  ## held `identifierPayload(enc, id)[0 ..< prefixLen]`, which are the same
  ## expression written twice — and the second one is the whole thing
  ## `contract/shards.nim`'s header calls "a second place for the layout to
  ## drift". The two would have agreed until the day one of them learned
  ## something about an alphabet the other did not.
  ##
  ## What stays HERE is the only part that is the client's own question: a query
  ## shorter than the published depth selects no shard at all, and §5.0a makes
  ## that a distinct outcome from a miss — "say the minimum, and say it was not
  ## attempted".
  if identifierPayload(encoding, identifier).len < m.prefixLen: ""
  else: hashPrefix(encoding, identifier, m.prefixLen)

func shardIsPublished*(m: IndexMeta; shard: string): bool =
  for s in m.shards:
    if s == shard: return true
  false

type
  ShardRequest* = object
    ## One index fetch a lookup will make: the shard, the path it is at, and
    ## every payload the query implies INSIDE it.
    ##
    ## `readings` is a seq because two distinct probes can share a shard — two
    ## payloads, one file — and scanning the fetched bytes with both costs
    ## nothing while fetching twice would cost a request and a duplicated hit
    ## list. It carries the ENCODINGS beside each payload because `hitsFor`
    ## compares both: a payload-only match returns objects of another encoding as
    ## answers to this query, which is a false presence that navigates.
    ##
    ## **`encodings` IS A SET AND NOT ONE ENCODING, and the singular was a false
    ## ABSENCE.** A payload is reachable under every encoding the query's shape
    ## admits for it, and `indexProbesOf` collapses those into ONE request
    ## deliberately — one payload is one shard. Scanning the bytes under only one
    ## member of the set excluded a producer that had declared any of the others,
    ## from a file the client had already fetched. Every member is scanned; the
    ## cost is a comparison per entry per member and not a request.
    shard*, path*: string
    readings*: seq[tuple[encodings: seq[string], payload: string]]

  IndexPlan* = object
    ## **EVERY REQUEST A LOOKUP WILL MAKE, COMPUTED BEFORE ANY IS MADE** — so
    ## "which requests does a search issue" is answerable without issuing one.
    ## That is `candidatesFor`'s stated virtue for §5.4's fallback, and the index
    ## arm had no equivalent while it made exactly one request and therefore had
    ## nothing to plan. It makes one PER DISTINCT PAYLOAD now (see
    ## `indexProbesOf`), so the count is a thing §5's request arithmetic has to
    ## be able to state and a test has to be able to read.
    requests*: seq[ShardRequest]
    tooShort*: int
      ## Probes whose payload is below the published shard depth. §5.0a's fourth
      ## outcome: nothing was looked in, which is not a miss.
    unpublished*: int
      ## Probes whose shard was never written. §5's index is exact over every
      ## published chain, so this IS an answer — at zero further requests.
    longestPayload*: int
      ## The most favourable payload length the query yields, for the "you typed
      ## N" half of the too-short message.

func indexPlanFor*(m: IndexMeta; probes: seq[IndexProbe]): IndexPlan =
  ## The plan, from the descriptor and the probes. Pure: no fetch, no DOM.
  for p in probes:
    if p.payload.len > result.longestPayload:
      result.longestPayload = p.payload.len
    if p.payload.len < m.minPrefixLen:
      inc result.tooShort
      continue
    let shard = m.shardFor(p.encoding, p.identifier)
    if not m.shardIsPublished(shard):
      inc result.unpublished
      continue
    var at = -1
    for i, r in result.requests:
      if r.shard == shard: at = i; break
    let reading = (encodings: p.encodings, payload: p.payload)
    if at < 0:
      result.requests.add ShardRequest(
        shard: shard,
        path: "/idx/hash/" & m.version & "/" & shard & ".bin",
        readings: @[reading])
    elif reading notin result.requests[at].readings:
      result.requests[at].readings.add reading

func shownFor*(raw: string; probes: seq[IndexProbe]): string =
  ## What the visitor is shown their query back as.
  ##
  ## One identifier when every PROBE agrees on it, which is every unambiguous
  ## query — hex (with its `0x` restored), base58, bech32 with its
  ## human-readable part intact, SS58. The query AS TYPED when the probes do not
  ## agree, because an ambiguous string has no single canonical spelling and
  ## choosing one would be `keys[0]` again, moved into the rendering: `addr1qqq…`
  ## read as base58 and read as bech32 are two different identifiers, and showing
  ## either one as "the" identifier tells the visitor something the deployment
  ## does not know.
  ##
  ## ## The agreement is over PROBES, not over READINGS — and for 42 queries those are not the same question
  ##
  ## Read the paragraph above as a claim about READINGS and it is false, so it is
  ## deliberately not written that way. `indexProbesOf` deduplicates by PAYLOAD,
  ## and two readings with different identifiers can share one payload — so they
  ## collapse into a single probe, this loop finds one identifier, "every probe
  ## agrees" is satisfied, and the disagreement is never visible to the check.
  ##
  ## Measured over `sweepCandidates()`'s 53,935 strings: **42** queries where the
  ## readings disagree and this function nevertheless returns a canonical form
  ## rather than the query as typed — `hex`×`base58` 24 and `hex`×`ss58` 18.
  ##
  ## **THESE ARE NOT THE 42 `indexProbesOf`'s DOCSTRING ACCOUNTS FOR, AND THE TWO
  ## SETS ARE DISJOINT — measured overlap 0.** An earlier revision of this note
  ## called them "those same 42". They are two halves of ONE 84-strong population —
  ## the bare-hex queries whose readings disagree — split by how many DISTINCT
  ## PAYLOADS those readings carry:
  ## * **two distinct payloads**: dedup cannot collapse them, two probes survive,
  ##   two shards are yielded. Those are `indexProbesOf`'s 42, the 462 − 420 gap.
  ##   For every one of them the loop below sees two differing identifiers and
  ##   returns the query as typed, which is the right answer — they are not this
  ##   defect and never were.
  ## * **one shared payload**: dedup collapses the two readings into a single
  ##   probe, the loop sees one identifier, and a canonical form is shown for a
  ##   query typed another way. Those are the 42 THIS note is about.
  ##
  ## The exclusion is structural rather than incidental: this function returns a
  ## canonical form only when ONE probe survives, and a query is in the other 42
  ## only when TWO do. Both halves happen to split 24/18 over the same two
  ## families, which is why "the same 42" read plausibly and was still wrong.
  ## Widening the probe, as described below, moves THIS half; it has nothing to do
  ## on the other, which needs no fix.
  ##
  ## A WORKED MEMBER OF THIS HALF, the one-payload one:
  ## `shownFor(repeat("a", 43), indexProbesOf(repeat("a", 43)))` returns `0xaaa…`
  ## — the hex spelling — to someone who typed a
  ## well-formed 43-character base58 address: `a`×43 matches `base58`, whose
  ## payload equals folded `hex`'s, so the group collapses to `hex` and the hex
  ## spelling is what gets shown.
  ##
  ## ## WHY THE RENDERING IS NOT CHANGED HERE
  ##
  ## Because which of the two is right is a DESIGN question and not a defect with
  ## one correct answer: showing `0xaaa…` asserts a reading the deployment has not
  ## established, showing the query as typed drops the `0x` restoration that every
  ## genuinely-unambiguous hex query depends on, and showing both needs a shape
  ## for "two identifiers" that the visitor-facing layer does not currently have.
  ## Deferring it is the right call; asserting it away was not.
  ##
  ## ## WHAT CLOSES IT: `IndexProbe` IS ONE FIELD SHORT
  ##
  ## The probe carries `payload` and the full `encodings` SET but a single
  ## `identifier`, and that asymmetry is the whole root cause. The closing shape
  ## is `identifiers: seq[string]`, for exactly the reason `encodings` became a
  ## seq: dedup must collapse the REQUEST without collapsing what the request is
  ## then said to be about. With it, this function asks "do the identifiers
  ## disagree" directly instead of inferring it from probe count.
  ##
  ## This milestone has now produced THREE consumers of that one missing field, in
  ## three waves — which shard is fetched (`keys[0]`), what the fetched bytes are
  ## scanned under (`encoding` vs `encodings`), and what the visitor is told (this
  ## function). Two were closed by widening the probe. Naming the third here, in
  ## the shape that closes it, is so the next wave widens the probe rather than
  ## discovering a fourth instance of the same collapse.
  if probes.len == 0: return raw.strip
  for p in probes:
    if p.identifier != probes[0].identifier: return raw.strip
  probes[0].identifier

func hitsFor*(shardBytes: string; encodings: seq[string];
              payload: string): seq[IndexHit] =
  ## Every entry in a decoded shard whose PAYLOAD begins with `payload` AND whose
  ## encoding is one of `encodings`.
  ##
  ## THIS IS THE WHOLE OF PREFIX SEARCH, and it is four lines because §5's
  ## shard is already the right shape for it: "sharded by a leading slice of
  ## the hash" means every hash sharing a prefix is in one file, and "an exact
  ## map from hash to (chain, entity kind)" means the keys are there to scan.
  ##
  ## Be clear about what this is, though: Search-And-Routing does NOT specify
  ## prefix search. §7's suggestion table is explicit in the other direction —
  ## "Hash, chain pinned | No suggestion" and "Hash, no chain | No suggestion;
  ## resolves on submit via the index" — so this EXTENDS the spec rather than
  ## implementing it. What it does not do is bend the spec's guarantees: an
  ## exact query still resolves exactly, and a prefix answer is presented as
  ## candidates rather than as a resolution.
  ## MATCHED ON THE PAYLOAD AND NOT ON THE STORED STRING, which is what makes
  ## a bech32 fragment work at all: `addr1qxy…`'s payload is `qxy…`, the shard
  ## was chosen from that, and matching the stored key form would compare a
  ## fragment against a human-readable part it does not contain.
  ##
  ## AND THE ROUTE IS THE STORED IDENTIFIER, not `"0x" & …`. That prefix used to
  ## be re-added here, in a module that could not see an encoding; a format-2
  ## entry carries its whole key form and a format-1 entry has the `0x` put back
  ## by the decoder, so both arrive ready to be a route segment.
  ##
  ## ## AND THE ENTRY'S ENCODING MUST BE ONE THE QUERY ADMITS. That is what
  ## `encodings` is for, and without it this function returned objects of an
  ## INADMISSIBLE encoding as answers to the query — a false PRESENCE, and one
  ## that navigates.
  ##
  ## **IT IS A SET, AND THE SINGULAR WAS A FALSE ABSENCE OF THE SAME CLASS.** The
  ## parameter was one string, and the probe supplying it had been deduplicated by
  ## payload — so where two encodings shared a payload, the caller passed whichever
  ## one came first in `encodings[]` and this function excluded the other. That is
  ## the whole of the second defect: the filter was right to compare the encoding
  ## and wrong about how many there were to compare against.
  ##
  ## Measured, on a shard holding one Aztec hex transaction
  ## `0xaccedeabab…`: the §5.0a fragment query `addr1accede` classifies as bech32
  ## (`addr1` + a 6-character data part, which is bech32's declared minimum),
  ## its payload is `accede`, its shard is `ac` — the hex entry's shard — and the
  ## scan returned **that transaction, as the single hit**. A single hit
  ## NAVIGATES, so a visitor looking for a Cardano address landed on an Aztec
  ## transaction page with no indication that the two readings were different.
  ##
  ## It is reachable rather than theoretical because the alphabets overlap:
  ## bech32's data charset and hex's digits share fourteen characters —
  ## `0 2 3 4 5 6 7 8 9 a c d e f`, bech32 excluding `1` and `b` — so any bech32
  ## payload drawn from that intersection is also a well-formed hex payload, and
  ## a payload-only comparison cannot tell them apart. Comparing the encoding
  ## costs one field that every format-2 entry already carries and that the
  ## format-1 decoder supplies as `hex`.
  ##
  ## IT COSTS NO REACHABILITY ONLY BECAUSE `encodings` IS THE WHOLE ADMITTED SET,
  ## and the previous wording of this paragraph asserted the conclusion while the
  ## premise was false. It read "a probe's encoding is one the query's shape
  ## admits" — but the probe carried the FIRST admitted encoding, the rest having
  ## been dropped by payload dedup before this function could see them, so the
  ## filter excluded encodings the query did admit. With the full set the argument
  ## holds as stated: a producer's encoding is the one its chain declared, and
  ## where that is outside this set the identifier was never admissible under the
  ## client's classification in the first place — §5.0a's separate "a row
  ## `shapesOf` declines to recognise" condition, which this filter does not
  ## create. That is now a CHECKED property rather than a claimed one: the
  ## (shard, encoding) invariant in `tests/tcontract.nim` fails if any admitted
  ## (shard, encoding) pair is unreachable by the probe set.
  let dec = decodeHashShard(shardBytes)
  if dec.err.len > 0: return
  for e in dec.entries:
    if e.encoding in encodings and e.entryPayload.startsWith(payload):
      result.add IndexHit(chain: e.chain, kind: e.kind, identifier: e.identifier,
                          route: routeFor(e.chain, e.kind, e.identifier))

func hitsFor*(shardBytes, encoding, payload: string): seq[IndexHit] =
  ## One-encoding spelling of the above, for a caller that has exactly one — the
  ## §5.0a control assertions in `client/tests/test_searchboot.nim`, which name a
  ## single encoding on purpose to pin that the filter excludes the others.
  ##
  ## NOT FOR THE SCAN PATH. `indexPlanFor`'s readings carry the admitted SET, and
  ## a scan that reaches for this overload is reintroducing the false absence.
  hitsFor(shardBytes, @[encoding], payload)

func encodeHits(hs: seq[IndexHit]): string =
  result = "["
  for i, h in hs:
    if i > 0: result.add ","
    result.add "{\"chain\":\"" & h.chain & "\",\"kind\":\"" & hkName(h.kind) &
      "\",\"hash\":\"" & h.identifier & "\",\"route\":\"" & h.route & "\"}"
  result.add "]"

type
  Candidate* = object
    ## One (chain, meaning) pair the direct path would try: the object to read,
    ## and the route to land on if it is there.
    chain*, kind*, objectPath*, route*: string

  ChainRef* = object
    ## One published chain, as the browser needs it: its slug and how it writes
    ## its identifiers.
    ##
    ## THE ENCODING IS READ FROM THE REGISTRY, not assumed, and this is the
    ## reason the type exists. Search-And-Routing.md §5's promise — "two requests
    ## to resolve any hash on any chain" — is only true if the client recomputes
    ## the SAME object path the producer wrote. Before the registry carried the
    ## encoding the browser had no way to do that for a chain that was not hex,
    ## so a derivation the producer could do and the browser could not would have
    ## left §5 false for every non-hex chain while every test passed.
    ##
    ## `registryChains` below reads it out of the same registry fetch that
    ## enumerates the chains, so it costs no additional request.
    slug*: string
    encoding*: ChainIdentifierEncoding

func chainRef*(slug, txEncodingToken, blockEncodingToken: string): ChainRef =
  ## One chain's reference, from the slug and the tokens the registry declared for
  ## its TRANSACTION and BLOCK identifiers.
  ##
  ## An empty token is the §6.1 compatibility case — a registry published before
  ## the member existed — and `declaredOrLegacy` is the one function in the tree
  ## that decides what that means. It is NOT decided at the JavaScript boundary
  ## below: that boundary carries bytes, and every rule about them is Nim's, which
  ## is this module's own stated split.
  ##
  ## BOTH KINDS ARE CARRIED, AND THE BLOCK ONE IS THE LATE ARRIVAL. It was left
  ## out on the argument that only the transaction path is sharded here, which
  ## confused the alphabet question with the CASE question: `blockPath` has no
  ## shard segment and its object is still NAMED by the identifier's key form, so
  ## it needs the declaration too. While it did not have one, a query typed in a
  ## spelling the producer did not publish produced a transaction candidate that
  ## resolved and a block candidate that could not. The address kind is still
  ## absent because this module builds no address path at all.
  ChainRef(slug: slug,
           encoding: chainIdentifierEncoding(
             {KindTransaction: declaredOrLegacy(txEncodingToken),
              KindBlock: declaredOrLegacy(blockEncodingToken)}))

func parseChainRefs*(packed: string): seq[ChainRef] =
  ## `slug:txEncoding:blockEncoding,…` from the JS boundary.
  ##
  ## A row with no `:` is a slug whose registry entry declared no encoding, and a
  ## row with one is a registry that declared a transaction encoding and no block
  ## one. Both are the compatibility case rather than a malformed row — an OLD
  ## registry is exactly the input that produces them, and refusing to search a
  ## tree because it predates a member would break §5.4's "search must never
  ## fail". Each MISSING field resolves on its own through `declaredOrLegacy`, so
  ## a row that declares one kind and not the other is read as exactly that.
  for row in packed.split(','):
    if row.len == 0: continue
    let i = row.find(':')
    if i < 0: result.add chainRef(row, "", "")
    else:
      let slug = row[0 ..< i]
      if slug.len == 0: continue
      let rest = row[i + 1 .. ^1]
      let j = rest.find(':')
      let txToken = if j < 0: rest else: rest[0 ..< j]
      let blockToken = if j < 0: "" else: rest[j + 1 .. ^1]
      # A token the registry declared that this build does not know is NOT read
      # as hex — `declaredOrLegacy` raises on it — so the chain is dropped from
      # the fan-out rather than probed at a path we would be guessing. Dropping
      # it is visible in the rendered "chains covered" list, which §14 requires
      # a miss to name; guessing would have produced a confident 404.
      try: result.add chainRef(slug, txToken, blockToken)
      except ValueError: discard

func candidatesFor*(canonical: string; chains: openArray[ChainRef]):
    seq[Candidate] =
  ## §4's direct path, enumerated. One entry per candidate MEANING per chain —
  ## §2's "a 64-hex string is both a plausible transaction hash and a plausible
  ## block hash, and both are resolved concurrently; exactly one answers".
  ##
  ## Pure, and that is the point: the browser fetches this list and nothing else,
  ## so "which requests does a search make" is answerable without running one.
  ##
  ## BOTH PATHS ARE RECOMPUTED WITH THE CHAIN'S OWN ENCODING, through the same
  ## `txFactsPath` and `blockPath` the producer and the validator use. A chain
  ## whose declared TRANSACTION encoding cannot be a shard path segment —
  ## `base64`, whose alphabet contains `/` — yields no transaction candidate
  ## rather than a wrong one, and its block candidate still stands, because a
  ## block path has no shard in it.
  ##
  ## THE BLOCK ARM IS GUARDED TOO, and the two guards are separate for that
  ## reason. `blockPath` cannot fail on a path-safety question, having no shard,
  ## but it can fail on an OMITTED kind: `encodingFor` raises rather than
  ## inventing a key for a kind a chain declared it cannot describe, and this
  ## function takes any `ChainRef` — `ChainRef.encoding` is public, so a caller
  ## may hand it a declaration that names only the transaction kind. One `try`
  ## around both would have dropped a resolvable transaction candidate because
  ## the block kind was missing.
  ##
  ## A PACKED ROW CANNOT REACH IT, AND THE DISTINCTION IS `declaredOrLegacy`'s
  ## OWN. An ABSENT block token is the §6.1 compatibility case and resolves to
  ## `LegacyUndeclaredEncoding`; an OMITTED KIND is a chain saying it cannot
  ## describe one, and the two are not the same thing. `parseChainRefs` builds
  ## every `ChainRef` through `chainRef`, which names BOTH kinds, so through the
  ## boundary this guard is defensive rather than live — which is why
  ## `test_searchboot` asserts that a row stopping after the transaction token
  ## still YIELDS a block candidate, at the fallback encoding, rather than
  ## asserting that it drops one.
  if not isHashLike(shapesOf(canonical)): return
  for c in chains:
    try:
      result.add Candidate(
        chain: c.slug, kind: "transaction",
        objectPath: "/" & txFactsPath(c.slug, canonical, c.encoding),
        route: "/" & c.slug & "/tx/" & canonical & "/")
    except ValueError: discard
    try:
      result.add Candidate(
        chain: c.slug, kind: "block",
        objectPath: "/" & blockPath(c.slug, canonical, c.encoding),
        route: "/" & c.slug & "/block/" & canonical & "/")
    except ValueError: discard

func encodeCandidates(cs: seq[Candidate]): string =
  ## The candidate list as JSON, for the one `importjs` boundary below.
  ##
  ## Hand-built rather than `std/json`: every field here is a slug or a path
  ## this module computed from hex, so there is nothing to escape, and pulling
  ## the JSON module into a `nim js` bundle for four flat strings would be the
  ## larger risk.
  result = "["
  for i, c in cs:
    if i > 0: result.add ","
    result.add "{\"chain\":\"" & c.chain & "\",\"kind\":\"" & c.kind &
      "\",\"objectPath\":\"" & c.objectPath & "\",\"route\":\"" & c.route & "\"}"
  result.add "]"

# ---------------------------------------------------------------------------
# The JavaScript boundary: I/O and the DOM, and no rules.
# ---------------------------------------------------------------------------

proc rawQuery(): cstring {.importjs: """
(function(){
  try { return new URLSearchParams(window.location.search).get('q') || ''; }
  catch (e) { return ''; }
})()""".}

proc registryChains(path: cstring; cb: proc(slugs: cstring)) {.importjs: """
(function(path, cb){
  // Static-Site-Architecture §2.9: the registry names every published chain,
  // and its path carries the contract version. Read it rather than trusting
  // the chain cards already in the DOM: those are a rendering of this file,
  // and a search that silently skipped a chain would still print a confident
  // "chains checked" list naming it.
  //
  // `slug:txEncoding:blockEncoding,…` — the slug AND the encodings the row
  // declares for the two kinds of identifier this module builds a path for
  // (Configuration.md §2.1). The transaction path is sharded, so it depends on
  // the alphabet; the block path is not sharded and its object is still NAMED by
  // the identifier's key form, so it depends on the declared case rule. Reading
  // both here costs no extra request: this fetch was already happening.
  //
  // THIS BOUNDARY DECIDES NOTHING. An absent member is passed on as an empty
  // token and `parseChainRefs` resolves what that means, per kind; a present one
  // is passed on verbatim, unvalidated, because the closed set lives on the Nim
  // side. That is this module's standing split — the boundary carries bytes, the
  // rules are Nim — and it is what keeps the browser from holding a second
  // opinion about which encodings exist.
  fetch(path, { credentials: 'omit' })
    .then(function(r){ return r.ok ? r.json() : null; })
    .then(function(j){
      var out = [];
      if (j && j.chains) {
        for (var k in j.chains) {
          var row = j.chains[k];
          var decl = (row && row.identifierEncoding) ? row.identifierEncoding : null;
          var tok = function(kind){
            return (decl && typeof decl[kind] === 'string') ? decl[kind] : '';
          };
          out.push(k + ':' + tok('transaction') + ':' + tok('block'));
        }
      }
      cb(out.join(','));
    })
    .catch(function(){ cb(''); });
})(#, #)""".}

proc indexMeta(path: cstring; cb: proc(packed: cstring)) {.importjs: """
(function(path, cb){
  // `version|prefixLen|shard,shard,…`, or "" when the index is unreadable.
  // Packed rather than handed over as an object because the RULES are Nim: this
  // boundary carries bytes, and every decision about them is made on the other
  // side of it.
  fetch(path, { credentials: 'omit' })
    .then(function(r){ return r.ok ? r.json() : null; })
    .then(function(j){
      if (!j || !j.prefixLen) { cb(''); return; }
      // PREFER THE WIDEST VERSION THIS DESCRIPTOR OFFERS, and fall back to the
      // top-level fields when it offers only one.
      //
      // `versions` and `preferredVersion` are §6.1 ADDITIVE fields: a descriptor
      // that carries neither is a hex-only index, and the top-level
      // `indexVersion`/`prefixLen`/`shards` are exactly what they have always
      // been. A client built before those fields existed ignores them and reads
      // the hex index, which is the whole compatibility window — see
      // `HashIndexVersionAll` in `contract/hashshard.nim`.
      //
      // The CHOICE is here and the RULES are Nim's, which is this module's
      // split: this picks one of several published descriptors and hands its
      // three fields over; nothing about a shard, a prefix or an encoding is
      // decided on this side.
      var v = null;
      if (j.preferredVersion && Array.isArray(j.versions)) {
        for (var i = 0; i < j.versions.length; i++) {
          if (j.versions[i] && j.versions[i].version === j.preferredVersion) {
            v = j.versions[i]; break;
          }
        }
      }
      if (v && v.prefixLen) {
        cb([v.version, v.prefixLen, (v.shards || []).join(',')].join('|'));
        return;
      }
      cb([j.indexVersion || '1', j.prefixLen, (j.shards || []).join(',')].join('|'));
    })
    .catch(function(){ cb(''); });
})(#, #)""".}

proc fetchShardHex(path: cstring; cb: proc(hex: cstring)) {.importjs: """
(function(path, cb){
  // The shard as HEX, not as a binary string.
  //
  // The decoder is Nim (`decodeHashShard`), so the bytes have to cross this
  // boundary, and a latin1 JS string would have made that crossing depend on
  // how the JS backend represents `string` — a thing that is true today and is
  // nobody's documented contract. Hex is unambiguous in both directions and
  // costs a doubling of an artefact the exporter reports as 372 bytes at its
  // largest.
  fetch(path, { credentials: 'omit' })
    .then(function(r){ return r.ok ? r.arrayBuffer() : null; })
    .then(function(b){
      if (!b) { cb(''); return; }
      var u = new Uint8Array(b), s = '';
      for (var i = 0; i < u.length; i++) s += ('0' + u[i].toString(16)).slice(-2);
      cb(s);
    })
    .catch(function(){ cb(''); });
})(#, #)""".}

proc renderHits(slotId, hitsJson, query: cstring) {.importjs: """
(function(slotId, hits, q){
  var slot = document.getElementById(slotId);
  if (!slot) return;
  function esc(s){
    return String(s).replace(/[&<>"]/g, function(c){
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;' }[c];
    });
  }
  function short(h){ return h.length > 20 ? h.slice(0,10) + '…' + h.slice(-6) : h; }
  function LABEL_OF(k){
    return { tx: 'transaction', block: 'block', address: 'address' }[k] || k;
  }

  if (hits.length === 1) {
    // Page-Descriptions §11, first bullet: "Unambiguous input navigates
    // immediately, without an intermediate results page." The index is exact,
    // so this is a navigation to an object the index just confirmed — §5's
    // "the subsequent data fetch is guaranteed to succeed".
    //
    // ONE MATCH NAVIGATES, WHETHER OR NOT THE QUERY WAS A WHOLE HASH. This
    // condition read `hits.length === 1 && navigate`, where `navigate` meant
    // "the query was a full-length identifier" — so a fragment matching
    // exactly one published object rendered a one-item list and made the
    // visitor click it.
    //
    // The two readings of "unambiguous" are the whole of the disagreement. It
    // can be a property of the INPUT'S FORM — a 64-hex string is an
    // identifier, a fragment is not — or a property of the RESULT: how many
    // things did this turn out to name? The form reading is defensible from
    // §2, which classifies inputs, and it is the one this file shipped with.
    //
    // It is the wrong one for the person typing. A fragment that matches
    // exactly one object is unambiguous in every sense they can perceive:
    // they asked a question, it has one answer, and a list of one is a
    // interstitial asking them to confirm a fact the page already knows. The
    // result reading is also the one that keeps §11's own promise, since the
    // promise is about not showing "an intermediate results page" and a
    // one-item list is precisely that.
    //
    // WHAT FOLLOWS FROM IT, stated so it is never filed as a bug: the SAME
    // QUERY CAN CHANGE BEHAVIOUR AS THE CORPUS GROWS. A fragment matching one
    // object today navigates; when a second object with that prefix is
    // published it will offer two candidates instead. That is inherent to
    // resolving against live data rather than a defect, it is the honest
    // outcome in both states, and collisions on a fragment of useful length
    // are rare enough that nobody should design around them.
    slot.innerHTML =
      '<div class="stub group" data-search-state="resolved">' +
      '<div class="measure">Resolved <span class="mono">' + esc(q) +
      '</span> to a ' + esc(LABEL_OF(hits[0].kind)) + ' on ' +
      esc(hits[0].chain) +
      '. <a class="addr" data-search-hit href="' + esc(hits[0].route) +
      '">Open it</a>.</div></div>';
    window.location.replace(hits[0].route);
    return;
  }

  // §11: "Ambiguous input shows grouped candidates (transaction · block ·
  // address · name), keyboard-navigable, with the active chain's results first
  // and other configured chains below." Grouped BY KIND here, in §11's own
  // order; there is no active chain on /search, so chains keep the registry's
  // order within a group rather than being ranked by a rule nobody stated.
  //
  // THE KEYS ARE THE WIRE'S, NOT THE PROSE'S. `hkName` emits `tx`/`block`/
  // `address`; §11 writes the groups as "transaction · block · address". The
  // first version of this list used §11's words as lookup keys, so the
  // transaction group matched nothing and EVERY TRANSACTION WAS DROPPED from
  // the candidates — a list that rendered, looked right, and silently omitted
  // the one entity kind this whole feature exists to find. Caught by reading a
  // multi-hit result, not by any type: both sides are strings.
  var order = ['tx', 'block', 'address'];
  var groups = {};
  hits.forEach(function(h){ (groups[h.kind] = groups[h.kind] || []).push(h); });
  var html = '';
  order.forEach(function(kind){
    var g = groups[kind];
    if (!g || !g.length) return;
    html += '<h3 class="sec-title next">' + esc(LABEL_OF(kind)) +
            (g.length > 1 ? 's' : '') + '</h3><ul class="hitlist">' +
      g.map(function(h){
        return '<li><a class="addr" data-search-hit href="' + esc(h.route) +
               '"><span class="mono">' + esc(short(h.hash)) + '</span> · ' +
               esc(h.chain) + '</a></li>';
      }).join('') + '</ul>';
  });
  // Reached only with TWO OR MORE hits: one navigates, above. The singular
  // wording that used to live here is gone rather than kept "just in case" —
  // an unreachable branch is a second answer to a question that now has one,
  // and the next reader would have to prove it was dead.
  slot.innerHTML =
    '<div class="stub group" data-search-state="candidates">' +
    '<div class="measure">' + hits.length +
    ' published entities begin with <span class="mono">' + esc(q) +
    '</span>. Every one is real; pick one.</div>' + html + '</div>';
})(#, JSON.parse(#), #)""".}

proc runCandidates(slotId, candidatesJson, canonical: cstring) {.importjs: """
(function(slotId, cands, q){
  var slot = document.getElementById(slotId);
  if (!slot) return;

  function esc(s){
    return String(s).replace(/[&<>"]/g, function(c){
      return { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;' }[c];
    });
  }

  // Every candidate is probed concurrently — §2's "both are resolved
  // concurrently; exactly one answers". A candidate that 404s is an answer,
  // not an error: §4 computes the path and the read decides.
  var probes = cands.map(function(c){
    return fetch(c.objectPath, { credentials: 'omit' })
      .then(function(r){ return r.ok ? c : null; })
      .catch(function(){ return null; });
  });

  Promise.all(probes).then(function(settled){
    var hits = settled.filter(function(c){ return c !== null; });
    var checked = [];
    cands.forEach(function(c){
      if (checked.indexOf(c.chain) < 0) checked.push(c.chain);
    });

    if (hits.length === 1) {
      // Page-Descriptions §11, first bullet: "Unambiguous input navigates
      // immediately, without an intermediate results page." The object was
      // just read, so this is a navigation to something known to be there —
      // never a guess. The slot is written FIRST so the answer exists as
      // rendered markup even if the navigation is blocked or slow.
      slot.innerHTML =
        '<div class="stub group" data-search-state="resolved">' +
        '<div class="measure">Resolved <span class="mono">' + esc(q) +
        '</span> to a ' + esc(hits[0].kind) + ' on ' + esc(hits[0].chain) +
        '. <a class="addr" data-search-hit href="' + esc(hits[0].route) +
        '">Open it</a>.</div></div>';
      window.location.replace(hits[0].route);
      return;
    }

    if (hits.length > 1) {
      // §11: "Ambiguous input shows grouped candidates". Two chains claiming
      // one hash is exactly the §5.1 collision case, and guessing between them
      // is the one thing that must not happen.
      var rows = hits.map(function(c){
        return '<li><a class="addr" data-search-hit href="' + esc(c.route) +
               '">' + esc(c.chain) + ' · ' + esc(c.kind) + '</a></li>';
      }).join('');
      slot.innerHTML =
        '<div class="stub group" data-search-state="ambiguous">' +
        '<div class="measure">More than one chain holds <span class="mono">' +
        esc(q) + '</span>. Both are real; pick one.</div><ul>' + rows +
        '</ul></div>';
      return;
    }

    // §8: "Not-found messaging names what was tried, because a miss is usually
    // a scoping problem rather than an absence." Page-Descriptions §14 states
    // the same row as a hard requirement: "'Not on this chain' with the chains
    // checked, not a blank page."
    slot.innerHTML =
      '<div class="stub group" data-search-state="notfound">' +
      '<div class="measure">No result for <span class="mono">' + esc(q) +
      '</span>. Checked the published object path on ' +
      esc(checked.join(' · ')) +
      ' — no transaction and no block at the computed address. ' +
      'If this is from a chain BlockTracer does not cover yet, it will not ' +
      'be here.</div></div>';
  });
})(#, JSON.parse(#), #)""".}

proc fillQuery(q: cstring) {.importjs: """
(function(q){
  // Put the query back in the box. The form is a plain GET, so the server
  // renders `/search/` with an EMPTY input no matter what was asked for — a
  // visitor who mistyped a hash could not see what they had typed, on the one
  // page whose entire job is to answer it.
  //
  // It is also what makes the non-collapse rule observable: the value is set
  // from the raw query, so a normalisation that corrupted a case-carrying
  // identifier would be visible on screen rather than only in a fetch nobody
  // watches.
  var boxes = document.querySelectorAll('input[name="q"]');
  for (var i = 0; i < boxes.length; i++) boxes[i].value = q;
})(#)""".}

proc renderNoQuery(slotId, state, message: cstring) {.importjs: """
(function(slotId, state, msg){
  var slot = document.getElementById(slotId);
  if (!slot) return;
  slot.innerHTML = '<div class="stub group" data-search-state="' + state +
    '"><div class="measure">' + msg + '</div></div>';
})(#, #, #)""".}

proc directPathFallback(ids: seq[string]; shown: string;
                        chains: seq[ChainRef]) =
  ## §5.4, unchanged and still here on purpose: "If the index is unavailable or
  ## a version is stale, the client falls back to probing configured chains
  ## directly. Slower and noisier, never wrong. **Search must never fail
  ## because an index did not load.**"
  ##
  ## It resolves EXACT hashes only, and that is inherent rather than a gap: a
  ## probe is a lookup of one computed path, so there is no such thing as
  ## probing for a prefix. A build with no index therefore keeps exact search
  ## and loses prefix search, which is the correct degradation — the one thing
  ## it must not do is answer a prefix query with "not found".
  ##
  ## **IT TAKES EVERY SPELLING THE QUERY IMPLIES, NOT ONE.** It took one, and
  ## that was the index arm's `keys[0]` defect wearing the fallback's clothes: an
  ## ambiguous string is two identifiers — `addr1qqq…` read as base58 keeps its
  ## case, read as bech32 it is folded — and probing only the first would have
  ## made the degraded path narrower than the indexed one. Candidates are unioned
  ## by object path, so a query whose spellings coincide costs exactly what it
  ## used to.
  var cs: seq[Candidate] = @[]
  for id in ids:
    for c in candidatesFor(id, chains):
      var dup = false
      for e in cs:
        if e.objectPath == c.objectPath: dup = true; break
      if not dup: cs.add c
  runCandidates(cstring(ResultSlotId), cstring(encodeCandidates(cs)),
                cstring(shown))

proc boot(chainsCsv, packedMeta: cstring) =
  let raw = $rawQuery()
  fillQuery(cstring(raw))
  if raw.strip.len == 0:
    # No query is not a miss. The page's own directory of mechanisms and names
    # is the answer here, and overwriting it with "no results" would be the
    # blank page §14 forbids.
    return

  # The RAW query classifies; only the hash branch canonicalises. See
  # `canonicalHash`: doing it the other way round rewrites a block height into
  # a hex string and loses §3's zero-request answer.
  let shapes = shapesOf(raw)
  let canonical = canonicalHash(raw)
  let meta = parseMeta($packedMeta)

  if not isHashLike(shapes):
    # §2's remaining rows — decimal, base58, bech32, plain text — resolve
    # through local inference over live head pointers, the hash index or the
    # name shards. Saying so is not the same as saying "not found", and
    # `SearchVM.mechanism` reports `smUnsupportedShape` for precisely this
    # reason: "we cannot look this up yet" must never render as "it does not
    # exist".
    # THREE DIFFERENT REASONS, THREE DIFFERENT SENTENCES. They were one, and
    # it told a visitor searching block 68231 that their query was "too short",
    # which is false — it is five digits, well over the bare-hex floor. It was
    # rejected for being a NUMBER, and a message that names the wrong cause
    # sends the reader to fix the wrong thing.
    let q = raw.strip
    let why =
      if isAllDigits(q):
        "Read as a block number rather than a hash. §3's local inference " &
        "resolves a height from live head pointers, which this page does " &
        "not hold. To search it as a hex identifier instead, write it with " &
        "a <span class=\"mono\">0x</span>. "
      elif isHexDigits(q):
        "Too short to read as a hash. Without a <span class=\"mono\">0x" &
        "</span> prefix, a hex string is only taken for an identifier at " &
        $BareHexFloor & " digits or more, because shorter ones are usually " &
        "words. Add the prefix to search it anyway. "
      else:
        "This deployment resolves an identifier by computing its object " &
        "path, which needs a hash — with or without the <span class=" &
        "\"mono\">0x</span>. "
    renderNoQuery(cstring(ResultSlotId), "unsupported",
      cstring(why & "Names resolve through the index shards below, which " &
              "this deployment does not read from the browser yet. Nothing " &
              "was looked in — which is not the same as nothing being there."))
    return

  # The registry rows, slug AND declared transaction encoding — see `parseChainRefs`.
  let chains = parseChainRefs($chainsCsv)

  # ── THE INDEX KEYS, DERIVED FROM THE QUERY ALONE ────────────────────────────
  #
  # §5's index path has no chain segment, so this is the whole of the client's
  # derivation: `indexProbesOf` returns every DISTINCT (encoding, identifier,
  # payload) the query's SHAPE admits, and each payload is a shard key. It used
  # to be `canonicalHexBody(raw)` — one hex body, no encoding — which is why a
  # base58 or bech32 query never reached this line at all.
  #
  # EVERY PROBE IS FETCHED. THE FIRST ONE WAS NOT ENOUGH AND WAS NEVER SAFE.
  # This line took `keys[0]` under the claim that every member a single query
  # matches yields the same payload, so any one of them selects the right shard.
  # That claim is FALSE over the table as declared — `addr1` + 38 `q`s is a
  # 43-character string in base58's band, written in base58's alphabet, carrying
  # bech32's `addr1` prefix; both members are `pathSafe`, the payloads are the
  # whole string and the part after the last `1`, and the shards are `addr` and
  # `qqqq`. A producer that declared bech32 wrote `qqqq`, so the first key
  # reported an identifier that is right there as absent. §5.0a forbids exactly
  # that. `indexProbesOf`'s header carries the measurement and the second,
  # independent reason the rule was unsafe even where it held: `keys[0]` is a
  # fact about the ORDER of a JSON array.
  #
  # What it costs is a third request on an ambiguous query — never more than
  # three over the table as declared, and never more than two on any identifier
  # this tree publishes. §5's own bullet is restated to say so.
  let probes = indexProbesOf(raw)
  if probes.len == 0:
    # `isHashLike` said this query has a shape the index can address, and the
    # key derivation then produced nothing. The only way that happens today is a
    # member whose alphabet cannot be a path segment (`base64`, which contains
    # `/`), matched with nothing else — so say that, rather than "not found".
    renderNoQuery(cstring(ResultSlotId), "unsupported",
      cstring("That looks like an identifier this deployment cannot address: " &
              "its encoding has no shard path, so nothing was looked in. That " &
              "is not the same as nothing being there."))
    return
  # WHAT THE VISITOR IS SHOWN IS THE IDENTIFIER, NOT THE PAYLOAD. These two are
  # the same string for base58 and differ for hex (`0x`) and bech32 (the
  # human-readable part), and the messages below used to rebuild the hex case by
  # hand — `"0x" & body` — which would have shown a Cardano address back to its
  # owner with `addr1` missing. `shownFor` says what an AMBIGUOUS query is shown
  # as, which is the query itself.
  let shown = shownFor(raw, probes)
  # ── §5.4's FALLBACK HAS TO BE ABLE TO SPELL THE QUERY TOO ───────────────────
  #
  # "If the index is unavailable or a version is stale, the client falls back to
  # probing configured chains directly… **Search must never fail because an index
  # did not load.**" The fallback computes an object path, so it needs the KEY
  # FORM — and it was being handed `canonical`, which is `canonicalHash`'s
  # hex-only answer and is EMPTY for every non-hex query. So the moment a base58
  # query started reaching the index at all, its degraded path would have
  # rendered nothing while reporting nothing: the exact false-silence §5.4 exists
  # to forbid, newly reachable and introduced by this change.
  #
  # For a hex query this IS `canonical` — `indexKeysOf` returns
  # `canonicalHash(q)` on that branch — so nothing about the hex path moves. For
  # an ambiguous one it is EVERY spelling, for `directPathFallback`'s reason.
  var resolvable: seq[string] = @[]
  for p in probes:
    if p.identifier notin resolvable: resolvable.add p.identifier

  # §14 requires a miss to name what was tried. A query that is ALSO a decimal
  # was resolved only as hex, and saying "no result" without saying that would
  # be a false absence claim about a block height nobody looked for: `68231` is
  # a real aztec height and a valid hex string at the same time, and §3's local
  # inference — the mechanism that would answer it — needs live head pointers
  # this page does not hold.
  # §14: "'Not on this chain' WITH THE CHAINS CHECKED", and §8 renders it by
  # naming them. The index answers for every chain at once, which is a stronger
  # statement than a per-chain probe makes — but "every chain this deployment
  # publishes" is only checkable by a reader who is told which those are, so the
  # list is stated rather than alluded to.
  var covered = ""
  for i, c in chains:
    if i > 0: covered.add " · "
    covered.add c.slug
  let coveredNote =
    if covered.len > 0: " Chains covered: " & covered & "."
    else: ""

  let decimalNote =
    if qsDecimal in shapes:
      " This was not looked up as a block number: §3's local inference needs " &
      "live head pointers, which this page does not hold."
    else: ""

  # ---- §5: the index first -------------------------------------------------
  if meta.prefixLen > 0:
    # THE WHOLE REQUEST LIST, COMPUTED BEFORE ANY REQUEST IS MADE. One fetch per
    # distinct shard the query's probes select — one for every unambiguous query
    # and two for the ambiguous ones `indexProbesOf` documents.
    let plan = indexPlanFor(meta, probes)

    if plan.requests.len == 0:
      # THE ORDER OF THESE TWO BRANCHES IS THE §5.0a RULE, NOT A PREFERENCE.
      # "Nothing was looked in" outranks "nothing is there": if ANY reading of
      # the query was too short to select a shard, the deployment has not looked
      # everywhere it could, and a definite-absence claim would be false about
      # the reading it skipped. So `tooShort` is tested first, and `notfound` is
      # reached only when EVERY probe's shard was definitively never written.
      #
      # The mixed case is unreachable at today's depth and is handled anyway: two
      # probes require a query admissible under two rows, which needs 43
      # characters or more, so both payloads are at least 37 — far above a
      # `prefixLen` of 2. It is written this way because the depth moves (§5.3)
      # and the wrong order would become reachable silently.
      if plan.tooShort > 0:
        # NOT a miss, and the difference is the whole point. Nothing was looked
        # in, because a prefix shorter than the shard depth selects no shard.
        # Rendering this as "no result" would be a false absence claim about
        # every object that does begin with it — the defect this route already
        # shipped once, at a different layer.
        #
        # The number comes from the published descriptor, so it stays right when
        # §5.3's arithmetic deepens the index. "You typed N" is the LONGEST
        # payload the query yields, because that is the reading closest to being
        # answerable and quoting a shorter one would understate what the visitor
        # has.
        renderNoQuery(cstring(ResultSlotId), "tooshort",
          cstring("Too short to look up. The published index is sharded on " &
                  "the first <b>" & $meta.minPrefixLen & "</b> characters of " &
                  "an identifier's payload, so a search needs at least that " &
                  "many — you typed " & $plan.longestPayload & ". Nothing was " &
                  "checked, which is not the same as nothing being there."))
        return
      # Zero further requests, and a DEFINITE answer: §5's index is exact over
      # every published chain, so a prefix whose shard was never written is a
      # prefix nothing begins with. EVERY probe has to have said so to get here —
      # one unpublished shard out of two is not an absence, it is the other shard
      # still being worth fetching, which is `plan.requests` being non-empty and
      # this branch not being reached at all.
      renderNoQuery(cstring(ResultSlotId), "notfound",
        cstring("No published entity begins with <span class=\"mono\">" &
                shown & "</span>. The hash index covers every chain this " &
                "deployment publishes, and has no shard for that prefix — " &
                "so this is an answer, not a gap." & coveredNote & decimalNote))
      return

    # ── THE FAN-OUT ───────────────────────────────────────────────────────────
    #
    # `pending` is the arrival counter and `finish` runs once, when the last
    # shard is in. It is a COUNTER rather than a chain of nested callbacks
    # because the requests are independent — §5's shards share no state — and
    # serialising them would have turned the one extra request an ambiguous
    # query costs into an extra ROUND TRIP, which is the axis §5.2 says matters.
    var pending = plan.requests.len
    var hits: seq[IndexHit] = @[]
    var failed = 0

    proc finish() =
      if hits.len > 0:
        # ONE MATCH NAVIGATES; TWO OR MORE DISAMBIGUATE. Whether the query was a
        # whole hash or a fragment does not enter into it — see `renderHits` for
        # why the count, not the form, is what "unambiguous" means here. A hit is
        # definite, so it is rendered even if a sibling shard failed to arrive.
        renderHits(cstring(ResultSlotId), cstring(encodeHits(hits)),
                   cstring(shown))
        return
      if failed > 0:
        # §5.4: "Search must never fail because an index did not load." A shard
        # the descriptor named did not arrive and nothing was found in the ones
        # that did, so the emptiness is not attributable to the index — fall back
        # to probing. Slower and noisier, never wrong.
        directPathFallback(resolvable, shown, chains)
        return
      renderNoQuery(cstring(ResultSlotId), "notfound",
        cstring("No result for <span class=\"mono\">" & shown &
                "</span>. Checked " & $plan.requests.len & " hash index " &
                (if plan.requests.len == 1: "shard" else: "shards") &
                " for that prefix, which cover every chain this deployment " &
                "publishes. If this is from a chain BlockTracer does not " &
                "cover yet, it will not be here." & coveredNote & decimalNote))

    proc fire(req: ShardRequest) =
      fetchShardHex(cstring(req.path), proc(hex: cstring) =
        let bytes = bytesFromHex($hex)
        if bytes.len == 0:
          inc failed
        else:
          for reading in req.readings:
            for h in hitsFor(bytes, reading.encodings, reading.payload):
              var dup = false
              for e in hits:
                if e.route == h.route: dup = true; break
              if not dup: hits.add h
        dec pending
        if pending == 0: finish())

    for req in plan.requests:
      fire(req)
    return

  # ---- §5.4: no index; probe the chains directly ---------------------------
  if chains.len == 0:
    renderNoQuery(cstring(ResultSlotId), "degraded",
      cstring("Neither the hash index nor the chain registry could be read, " &
              "so nothing was checked. That is a different answer from " &
              "“not found”."))
    return
  directPathFallback(resolvable, shown, chains)

when isMainModule:
  registryChains(cstring("/" & registryPath()),
                 proc(slugs: cstring) =
    indexMeta(cstring("/idx/hash/meta.json"),
              proc(packed: cstring) = boot(slugs, packed)))
