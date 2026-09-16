## The browser's half of search, tested without a browser —
## [Search-And-Routing.md](../../../codetracer-specs/BlockTracer/Search-And-Routing.md)
## §4 (the direct path), §5 (the index and its two requests) and §5.4 (the
## fallback), over `client/searchboot/searchboot.nim`.
##
## ## Why this file exists, and the gap it closes
##
## `searchboot.nim`'s own header says the seam it draws is honest because "a test
## can read that list without a browser": `candidatesFor` returns the requests a
## search would make as DATA, and the JavaScript boundary can only fetch what Nim
## produced. **Nothing read it.** The module had no test of any kind — the only
## things that touched it were the bundle-freshness gate, which checks that
## `search.js` is newer than its sources, and the SDK boundary lint, which checks
## which modules it may import. Neither runs a single one of its rules.
##
## That mattered the moment object-path derivation stopped assuming `0x` + hex.
## §5's promise is *"two requests to resolve any hash on any chain"*, and it is only
## true if the client recomputes the SAME path the producer wrote. A derivation the
## producer can do and the browser cannot is not a derivation — so the browser's
## recomputation needs a test that fails when it drifts, and this is it.
##
## ## NO MOCKS, and there are none to justify
##
## Per the workspace policy every mock must be justified in the test file's header.
## There are none. Every function under test is pure: `parseChainRefs` over the
## exact string the module's own JavaScript boundary emits, and `candidatesFor`
## over the result. The object paths are compared against `txFactsPath` and
## `blockPath` — the real contract derivations, the same ones the producer and the
## validator call — rather than against strings written out here, because a test
## spelling the layout itself would pass while the layout drifted.
##
## What is NOT tested here is the DOM and the fetching, which is the other side of
## the module's stated split and needs a browser.

import std/[unittest, strutils]

import ../searchboot/searchboot
import blocktracer_client_paths
# §2's classification and the browser-side index-key derivation, which became
# the same module when the index started keying per identifier shape.
import ../src/viewmodel/search_shapes
# The §5 CODEC, so a shard can be built here rather than fetched: the
# false-presence arm needs a real format-1 shard with a real hex entry in it, and
# `searchboot` imports `hashshard` without re-exporting it.
import blocktracer/contract/hashshard

const
  Hash = "0x2b0f32c62a6d5b0a4e6a0b3c1d8e9f70112233445566778899aabbccddeeff00"
    ## `0x` + exactly 64 hex, so `shapesOf` classifies it as hash-like — §2's row
    ## for a transaction or block hash.
  Slug = "aztec"

var asserted = 0
template ck(condition: untyped) =
  inc asserted
  check condition

suite "the registry's encoding reaches the browser's derivation":

  test "a slug with a declared encoding parses into a chain reference":
    let refs = parseChainRefs("aztec:hex,solana:base58")
    ck refs.len == 2
    ck refs[0].slug == "aztec"
    ck refs[0].encoding.declared
    ck refs[0].encoding.encodingFor(KindTransaction) == "hex"
    ck refs[1].slug == "solana"
    ck refs[1].encoding.encodingFor(KindTransaction) == "base58"
    # A ROW WITH ONE `:` DECLARES ONE KIND. The packed shape is
    # `slug:txEncoding:blockEncoding`, and a row that stops after the transaction
    # token is a registry that declared no block encoding — the §6.1 case for that
    # kind alone, not for the row.
    ck refs[0].encoding.encodingFor(KindBlock) == LegacyUndeclaredEncoding
    ck refs[1].encoding.encodingFor(KindBlock) == "hex"
    # …and a row that declares BOTH is read as both, per kind, which is what makes
    # the block path follow the declaration rather than the transaction's.
    let both = parseChainRefs("ton:base64:decimal")
    ck both.len == 1
    ck both[0].encoding.encodingFor(KindTransaction) == "base64"
    ck both[0].encoding.encodingFor(KindBlock) == "decimal"

  test "a slug with NO encoding is the §6.1 compatibility case, not a bad row":
    # An OLD registry is exactly the input that produces this, and refusing to
    # search a tree because it predates a member would break §5.4's "search must
    # never fail because an index did not load".
    for packed in ["aztec", "aztec:"]:
      let refs = parseChainRefs(packed)
      ck refs.len == 1
      ck refs[0].slug == "aztec"
      ck refs[0].encoding.encodingFor(KindTransaction) == LegacyUndeclaredEncoding
      ck refs[0].encoding.encodingFor(KindTransaction) == "hex"

  test "a token this build does not know DROPS the chain rather than guessing":
    # The alternative is to probe a path derived from an assumption, which produces
    # a confident 404 about a chain whose objects are somewhere else. The dropped
    # chain is visible in the rendered "chains checked" list, which §14 requires a
    # miss to name.
    let refs = parseChainRefs("aztec:hex,future:base32,solana:base58")
    ck refs.len == 2
    var slugs: seq[string]
    for r in refs: slugs.add r.slug
    ck slugs == @["aztec", "solana"]
    ck "future" notin slugs

  test "an empty packed list yields nothing, and a slug-less row is skipped":
    ck parseChainRefs("").len == 0
    ck parseChainRefs(":hex").len == 0
    ck parseChainRefs(",,").len == 0

suite "the browser recomputes the producer's object path, per encoding":

  test "for hex, the transaction candidate is the contract's own derivation":
    let refs = parseChainRefs(Slug & ":hex")
    let cs = candidatesFor(Hash, refs)
    # One transaction candidate and one block candidate per chain — §2's "a 64-hex
    # string is both a plausible transaction hash and a plausible block hash, and
    # both are resolved concurrently".
    ck cs.len == 2
    ck cs[0].kind == "transaction"
    ck cs[1].kind == "block"
    # COMPARED AGAINST THE REAL DERIVATION, not against a string written here.
    ck cs[0].objectPath ==
       "/" & txFactsPath(Slug, Hash, refs[0].encoding)
    ck cs[1].objectPath == "/" & blockPath(Slug, Hash, refs[0].encoding)
    # …and the shard is in it, which is the part that could silently go missing.
    ck cs[0].objectPath.contains("/tx/" & shardKeyFor("hex", Hash) & "/")

  test "for base58 it is a DIFFERENT path, and the difference is the shard":
    let hexRefs = parseChainRefs(Slug & ":hex")
    let b58Refs = parseChainRefs(Slug & ":base58")
    let hexPath = candidatesFor(Hash, hexRefs)[0].objectPath
    let b58Path = candidatesFor(Hash, b58Refs)[0].objectPath
    ck hexPath != b58Path
    # base58 has no `0x` to strip, so the `0x` is payload — which is exactly the
    # assumption the encoding was made data to remove.
    ck b58Path.contains("/tx/0x2b/")
    ck hexPath.contains("/tx/2b0f/")
    ck b58Path == "/" & txFactsPath(Slug, Hash, b58Refs[0].encoding)

  test "an unshardable encoding yields no transaction candidate, only a block":
    # `base64`'s alphabet contains `/`, which ends a path segment, so there is no
    # honest transaction path to probe. The BLOCK candidate still stands, because a
    # block path is content-addressed and has no shard in it — dropping both would
    # have made the chain invisible for a reason that applies to one of them.
    let refs = parseChainRefs(Slug & ":base64")
    let cs = candidatesFor(Hash, refs)
    ck cs.len == 1
    ck cs[0].kind == "block"
    ck cs[0].objectPath == "/" & blockPath(Slug, Hash, refs[0].encoding)
    # …and the block encoding this row resolves to is the §6.1 fallback rather
    # than `base64`: the packed row declared a transaction token and no block
    # token, and each kind resolves on its own.
    ck refs[0].encoding.encodingFor(KindBlock) == "hex"

  test "every chain in the fan-out uses ITS OWN declaration":
    # The failure this catches is one encoding leaking across the fan-out, which is
    # what a module-level variable or a default argument would have produced.
    let refs = parseChainRefs("aztec:hex,solana:base58")
    let cs = candidatesFor(Hash, refs)
    ck cs.len == 4
    var byChain: seq[(string, string)]
    for c in cs:
      if c.kind == "transaction": byChain.add (c.chain, c.objectPath)
    ck byChain.len == 2
    ck byChain[0][1].contains("/aztec/tx/2b0f/")
    ck byChain[1][1].contains("/solana/tx/0x2b/")

  test "BOTH object paths key-form the identifier, and the block one is new":
    # `blockPath` took no `ChainIdentifierEncoding` and therefore key-formed
    # nothing, on the argument that a block path has no shard segment. That
    # confused the alphabet question with the CASE question: the object is still
    # NAMED by the identifier. While that was so, a query in a spelling the
    # producer did not publish produced a transaction candidate that resolved and
    # a block candidate that could not, on the same input — and one of the
    # affected surfaces is a published SDK package.
    #
    # In production the query arrives already canonicalised (`canonicalHash`), so
    # this is the direction that matters: a caller that has not canonicalised, or
    # a chain whose declaration makes the fold a real one, gets the same answer.
    let refs = parseChainRefs(Slug & ":hex:hex")
    let shouted = "0x" & Hash[2 .. ^1].toUpperAscii
    ck shouted != Hash
    let lower = candidatesFor(Hash, refs)
    let upper = candidatesFor(shouted, refs)
    ck lower.len == 2
    ck upper.len == 2
    # BOTH KINDS THE SAME — this module builds two paths, not three; the address
    # kind is the explorer's. One identifier, two spellings, one object path each,
    # which is the property rather than two separate ones.
    for i in 0 ..< 2:
      ck upper[i].kind == lower[i].kind
      ck upper[i].objectPath == lower[i].objectPath
      ck not upper[i].objectPath.contains(shouted)
    # …and the ROUTE still carries the caller's spelling, which is deliberate: the
    # object path is what has to be recomputable, and a route is a human URL.
    ck upper[1].route.contains(shouted)

  test "a non-hash query produces no candidates at all":
    # §2's remaining rows resolve by other mechanisms, and §14's rule is that "we
    # cannot look this up yet" must never render as "it does not exist". No
    # candidate is the correct answer; a guessed path would be the wrong one.
    let refs = parseChainRefs(Slug & ":hex")
    ck candidatesFor("68231", refs).len == 0
    ck candidatesFor("some name", refs).len == 0

  test "the route a candidate lands on is NOT sharded":
    # The object path is sharded and the human URL is not: §2.9's layout applies to
    # `/d/**`, and a route that leaked a shard segment would be a URL nobody can
    # type. Worth an arm because both strings are built in the same function.
    let refs = parseChainRefs(Slug & ":hex")
    let cs = candidatesFor(Hash, refs)
    ck cs.len == 2
    # The route's segment is the ROUTE's vocabulary (`tx`) rather than the
    # candidate's kind (`transaction`), which is its own small trap: the two strings
    # are built in one function and it is easy to reuse the wrong one.
    ck cs[0].route == "/" & Slug & "/tx/" & Hash & "/"
    ck cs[1].route == "/" & Slug & "/block/" & Hash & "/"
    for c in cs:
      ck not c.route.contains("/" & shardKeyFor("hex", Hash) & "/")
      ck c.route.startsWith("/" & Slug & "/")

suite "the index path still works, and is unchanged by the encoding":

  test "the shard depth is read from the published descriptor, never assumed":
    # §5.3: "more chains or more history means a deeper prefix". A client that
    # compiled one in would compute wrong shard paths the first time the index
    # deepened and report every hash absent while doing it.
    let m = parseMeta("7|4|2b0f,0000")
    ck m.version == "7"
    ck m.prefixLen == 4
    ck m.minPrefixLen == 4
    # `shardFor` now takes the ENCODING and the IDENTIFIER rather than a
    # pre-sliced payload, because it derives through `hashPrefix` — the
    # producer's own function — instead of slicing here. It held its own slice
    # for one revision and the boundary sweep caught it as a second derivation
    # of the published layout.
    ck m.shardFor("hex", "0x2b0f32c6") == "2b0f"
    ck m.shardFor("hex", "2b0f32c6") == "2b0f"          # the `0x` is optional
    ck m.shardFor("hex", "0x2B0F32C6") == "2b0f"        # …and case folds
    ck m.shardIsPublished("2b0f")
    ck not m.shardIsPublished("dead")
    # A zero depth is §5.4's trigger — "no index" — and not an error.
    ck parseMeta("").prefixLen == 0
    ck parseMeta("7|0|x").prefixLen == 0

  test "the hash index's DEPTH is published, and is NOT the object tree's shard width":
    # Recorded rather than assumed, because the two are four characters wide today
    # and look alike. The index's depth is published per build; the object tree's
    # is the contract's `ShardWidth`. They were also, for a while, two different
    # ALPHABETS — the index was hex-only — and they no longer are: both slice the
    # same `identifierPayload`, and only the width and the padding differ.
    ck ShardWidth == 4
    let m = parseMeta("7|3|2b0")
    ck m.prefixLen == 3
    ck m.prefixLen != ShardWidth

  test "ON THE JS BACKEND A TAB ACTUALLY RUNS: a non-hex query reaches a shard":
    # §5's promise is "a derivation the producer can do and the browser cannot is
    # not done", so the browser's backend is where it has to be graded. The three
    # arms below are the three non-hex rows a chartered chain uses.
    let m = parseMeta("2|2|9W,qx,5G")
    # base58 (a Solana address): the whole string is payload, case PRESERVED.
    ck m.shardFor("base58", "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM") == "9W"
    # bech32 (a Cardano address): the payload begins after the LAST `1`, which is
    # what stops every address on the chain landing in one bucket.
    ck m.shardFor("bech32", "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jhsydzer") == "qx"
    # ss58 (a Substrate account): base58's rules, its own length band.
    ck m.shardFor("ss58", "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY") == "5G"
    # …and every one of those shards is one the descriptor published, so the
    # client would fetch rather than report a definite absence.
    for sh in ["9W", "qx", "5G"]: ck m.shardIsPublished(sh)

  test "…and the client derives WHICH encoding from the query string alone":
    # No registry, no chain, no request — which is the whole of why the index can
    # key per shape at all. `indexProbesOf` is the browser-side derivation.
    ck indexProbesOf("9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM").len == 1
    ck indexProbesOf("0x" & Hash[2 .. ^1]).len == 1
    ck indexProbesOf("0x" & Hash[2 .. ^1])[0].encoding == "hex"
    # A bare number is NOT an index key: §3 resolves it locally at zero requests.
    ck indexProbesOf("68231").len == 0

  test "AN AMBIGUOUS QUERY PLANS TWO FETCHES — the false absence, at the seam":
    # THE DEFECT THIS ARM CLOSES. `addr1` + 38 `q`s is 43 characters: inside
    # base58's 43–44 band, written entirely in base58's alphabet, and carrying
    # bech32's `addr1` human-readable part. Both members are `pathSafe`, so
    # neither is skipped, and the two payloads are the whole string and the part
    # after the last `1` — shards `addr` and `qqqq`.
    #
    # A Cardano producer wrote `qqqq`. The client took the first key, asked
    # `addr`, and rendered "no published entity begins with…" — a false absence
    # under §5.0a, about an object that is right there.
    #
    # It is asserted on `indexPlanFor`, which is the REQUEST LIST, because that
    # is what the defect was about: not which encodings were recognised, but
    # which files were fetched.
    const Ambiguous = "addr1" & "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"   # 43
    ck Ambiguous.len == 43
    let probes = indexProbesOf(Ambiguous)
    ck probes.len == 2
    # Both shards published, so both are fetched.
    let m = parseMeta("2|4|addr,qqqq")
    let plan = m.indexPlanFor(probes)
    ck plan.requests.len == 2
    ck plan.requests[0].path == "/idx/hash/2/addr.bin"
    ck plan.requests[1].path == "/idx/hash/2/qqqq.bin"
    ck plan.tooShort == 0
    ck plan.unpublished == 0
    # ONE SHARD UNPUBLISHED IS NOT AN ABSENCE. The pre-fix client reported a
    # definite "nothing begins with that" the moment ITS one shard was missing;
    # the other reading's shard still has to be looked in.
    let partial = parseMeta("2|4|qqqq").indexPlanFor(probes)
    ck partial.requests.len == 1
    ck partial.requests[0].shard == "qqqq"
    ck partial.unpublished == 1
    # …and with NEITHER published, it is an absence, at zero further requests.
    ck parseMeta("2|4|zzzz").indexPlanFor(probes).requests.len == 0
    ck parseMeta("2|4|zzzz").indexPlanFor(probes).unpublished == 2
    # The visitor is shown the query AS TYPED, because the two readings are two
    # different identifiers and naming either one would be `keys[0]` in the
    # rendering.
    ck shownFor(Ambiguous, probes) == Ambiguous
    ck shownFor("  " & Hash & "  ", indexProbesOf(Hash)) == Hash

  test "two distinct payloads in ONE shard cost one fetch, not two":
    # The plan is grouped by SHARD, not by probe: two payloads that happen to
    # share a shard are one file and are scanned with both. Deduplicating by
    # probe instead would have doubled a request and the hit list with it.
    #
    # THE WITNESS IS CONSTRUCTED SO THE TWO READINGS SHARE A PREFIX. `addr1` +
    # `ad` + 36 `q`s is 43 characters: read as base58 the payload is the whole
    # string (`addr1ad…`), read as bech32 it is the part after the last `1`
    # (`adqqq…`) — and both begin `ad`, so at a depth of 2 they are ONE shard and
    # at a depth of 4 they are two (`addr` against `adqq`). That is not a
    # curiosity: §5.3 says the depth moves, so the request count of a given query
    # is a function of the PUBLISHED depth and not of the query alone.
    const Shared = "addr1ad" & "qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"   # 43
    ck Shared.len == 43
    let two = indexProbesOf(Shared)
    ck two.len == 2
    ck two[0].payload != two[1].payload
    let depth2 = parseMeta("2|2|ad").indexPlanFor(two)
    ck depth2.requests.len == 1                    # one file…
    ck depth2.requests[0].readings.len == 2        # …scanned with both readings
    ck depth2.requests[0].shard == "ad"
    let depth4 = parseMeta("2|4|addr,adqq").indexPlanFor(two)
    ck depth4.requests.len == 2                    # the same query, deeper index
    # …and a query whose readings agree is one request with one reading, which is
    # every unambiguous query and therefore §5's common case.
    let one = parseMeta("2|2|2b").indexPlanFor(indexProbesOf(Hash))
    ck one.requests.len == 1
    ck one.requests[0].readings.len == 1

  test "A HIT OF ANOTHER ENCODING IS NOT A HIT — the false PRESENCE that navigated":
    # bech32's data charset and hex's digits share fourteen characters
    # (`0 2 3 4 5 6 7 8 9 a c d e f`; bech32 excludes `1` and `b`), so a bech32
    # payload drawn from that intersection is ALSO a well-formed hex payload.
    # `hitsFor` compared payload characters and nothing else, so a §5.0a fragment
    # of a Cardano address returned an Aztec TRANSACTION — one hit, and one hit
    # navigates. Measured before the fix and reproduced here.
    const HexTx = "0xaccede" & "ab".repeat(29)     # a hex tx, payload `accede…`
    ck HexTx.len == 66
    let shard = encodeHashShard(@[HashEntry(encoding: "hex", identifier: HexTx,
                                            chain: "aztec", kind: hkTx)], 2)
    # The fragment: `addr1` + a 6-character data part, bech32's declared minimum.
    let frag = indexProbesOf("addr1accede")
    ck frag.len == 1
    ck frag[0].encoding == "bech32"
    ck frag[0].payload == "accede"
    # Same shard as the hex entry — which is WHY the scan reached it at all.
    ck parseMeta("1|2|ac").shardFor(frag[0].encoding, frag[0].identifier) == "ac"
    # THE CONTROL: the payload really does match, so the filter is what excludes
    # it rather than the comparison failing for some other reason.
    ck hitsFor(shard, "hex", frag[0].payload).len == 1
    # …and read as bech32 it is not an answer.
    ck hitsFor(shard, frag[0].encoding, frag[0].payload).len == 0
    # The hex query for the same object still resolves, so the filter costs the
    # hex path nothing — including a FORMAT-1 shard, whose decoder supplies the
    # encoding the entries were stored under.
    ck shardIsAllHex(@[HashEntry(encoding: "hex", identifier: HexTx,
                                 chain: "aztec", kind: hkTx)])
    ck hitsFor(shard, "hex", "accede").len == 1
    # The WHOLE payload, spelled out rather than taken from `identifierPayload` —
    # a test that asks the derivation what it produced and then checks it against
    # that is an inert comparison, and naming the function here would also widen
    # the identifier-encoding boundary's consumer population for no reason.
    ck hitsFor(shard, "hex", "accede" & "ab".repeat(29)).len == 1

  test "a probe below the shard depth is not looked in, and says so":
    # §5.0a's fourth outcome, now per probe. A query that is too short in EVERY
    # reading is "nothing was checked"; one that is answerable in any reading is
    # fetched in that one.
    let shallow = indexProbesOf("0xab")
    ck shallow.len == 1
    let plan = parseMeta("1|4|abcd").indexPlanFor(shallow)
    ck plan.requests.len == 0
    ck plan.tooShort == 1
    ck plan.unpublished == 0
    ck plan.longestPayload == 2

  test "§5.4's fallback can spell a NON-HEX query, which `canonicalHash` cannot":
    # "Search must never fail because an index did not load." The degraded path
    # computes an object path, so it needs a KEY FORM — and `canonicalHash` is
    # hex-only and returns "" for every other encoding. Handing THAT to the
    # fallback would have rendered nothing and reported nothing, which is the
    # false silence §5.4 exists to forbid, newly reachable the moment a base58
    # query started reaching the index at all.
    const Sol = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
    ck canonicalHash(Sol) == ""                        # the old value: empty
    ck indexProbesOf(Sol).len == 1                     # unambiguous: one spelling
    ck indexProbesOf(Sol)[0].identifier == Sol         # the value the fallback gets
    # …and with it, the fallback actually enumerates candidates.
    let chains = parseChainRefs("solana:base58:base58")
    ck candidatesFor(indexProbesOf(Sol)[0].identifier, chains).len > 0
    ck candidatesFor(canonicalHash(Sol), chains).len == 0   # the control

  test "PRODUCER DECLARES X, CLIENT SCANS WITH Y — the round trip nothing did":
    # **EVERY OTHER `hitsFor` ASSERTION IN THIS FILE HANDS IT A HAND-WRITTEN
    # ENCODING.** That is right for the false-presence arm above, whose whole point
    # is to name one encoding and watch the others be excluded — but it means no
    # arm ever walked the actual path: a PRODUCER publishes an identifier under the
    # encoding ITS CHAIN DECLARED, and a CLIENT that does not know the chain
    # derives its own plan from the query string and scans what it fetched. The
    # encoding on the two sides is chosen by two different parties, and every
    # assertion here chose it once.
    #
    # That gap is exactly where the false absence lived. `indexProbesOf`
    # deduplicates by payload — one payload is one shard is one request — and it
    # used to keep only the FIRST encoding of each payload group, in the
    # declaration order of `encodings[]`. So a producer that had declared one of
    # the discarded members was excluded from the very shard the client had already
    # fetched, and no assertion in this file could see it, because every one of
    # them supplied the encoding the filter was about to compare against.
    #
    # THE IDENTIFIERS ARE SPELLED, NOT DERIVED. Asking `identifierKeyForm` what it
    # produced and then checking the result against that is an inert comparison —
    # the file's own stated rule, from the arm above — and these three key forms are
    # literals anyway: base58, base64url and SS58 all preserve case.
    proc hitsEndToEnd(q, producerEncoding, published, producerShard: string): int =
      ## The whole path in one place: publish, then resolve from `q` alone.
      ##
      ## `producerShard` IS PASSED IN RATHER THAN DERIVED, for two reasons. It is
      ## the honest form of the assertion — the caller states which directory the
      ## producer wrote and the client has to arrive there without being told the
      ## chain, where asking `hashPrefix` and then comparing against its own answer
      ## would assert nothing. And naming `hashPrefix` here would widen the
      ## identifier-encoding boundary sweep's indexKey consumer population, which
      ## pins an exact file set; the arm above declines to name `identifierPayload`
      ## for the same two reasons.
      let shard = encodeHashShard(@[HashEntry(encoding: producerEncoding,
                                             identifier: published,
                                             chain: "demo", kind: hkTx)], 4)
      let meta = parseMeta("2|4|" & producerShard)
      for req in meta.indexPlanFor(indexProbesOf(q)).requests:
        for r in req.readings:
          result += hitsFor(shard, r.encodings, r.payload).len

    const
      A43 = "a".repeat(43)          # 43 lowercase hex digits AND a base58 address
      A46 = "a".repeat(46)          # 46 of them, inside SS58's 46–48 band
      Ton = "EQ" & "A".repeat(46)   # 48, matching base64url AND ss58
    ck A43.len == 43
    ck A46.len == 46
    ck Ton.len == 48

    # ── THE THREE WITNESSES. Each returned 0 before the fix. ────────────────────
    # `a`×43 folds to itself under hex and is preserved by base58, so the two
    # payloads are equal and the group collapsed to whichever came first — `hex`.
    ck hitsEndToEnd(A43, "base58", A43, "aaaa") == 1
    # …and the other member of the SAME group is still reachable, which is what
    # makes this a widening rather than a swap.
    ck hitsEndToEnd(A43, "hex", A43, "aaaa") == 1
    # `a`×46 against SS58's band, the same mechanism.
    ck hitsEndToEnd(A46, "ss58", A46, "aaaa") == 1
    ck hitsEndToEnd(A46, "hex", A46, "aaaa") == 1
    # And the family that needs no hex at all: `base64url` and `ss58` both match a
    # 48-character `EQ…` string and both preserve case, so one payload, one shard,
    # two admissible producers. `base64url` was findable before the fix because it
    # is declared first; `ss58` was not. Both are now, and the ASYMMETRY was the
    # tell that this was declaration order and not a missing feature.
    ck hitsEndToEnd(Ton, "base64url", Ton, "EQAA") == 1
    ck hitsEndToEnd(Ton, "ss58", Ton, "EQAA") == 1

    # ── THE CONTROL, so the widening did not simply stop filtering. ─────────────
    # A producer declaring `base58` for the 48-character TON string keys the same
    # shard — `E`, `Q` and `A` are all in base58's alphabet — but 48 is outside
    # base58's 43–44 and 87–88 bands, so the query does NOT admit base58 and the
    # entry is not an answer. The shard is reached and the entry is excluded: that
    # is the false-presence filter still doing its job at the same payload.
    ck hitsEndToEnd(Ton, "base58", Ton, "EQAA") == 0
    # …and the reason it is a real control rather than a miss for some other
    # reason: the payload really does match, as the single-encoding spelling shows.
    let b58Shard = encodeHashShard(@[HashEntry(encoding: "base58",
                                               identifier: Ton, chain: "demo",
                                               kind: hkTx)], 4)
    ck hitsFor(b58Shard, "base58", Ton).len == 1
    ck hitsFor(b58Shard, @["base64url", "ss58"], Ton).len == 0

    # ── AND THE RESULT DOES NOT DEPEND ON THE ORDER OF A JSON ARRAY. ────────────
    # The probe's encoding SET is sorted, so it is the same set whichever order
    # `encodings[]` declares its members in — which is the property `keys[0]` did
    # not have, and the one a consumption rule may not be without. Asserted as the
    # sorted value rather than by reordering the table, because the table is a
    # compile-time input and a test cannot re-read it.
    let tonProbes = indexProbesOf(Ton)
    ck tonProbes.len == 1
    ck tonProbes[0].encodings == @["base64url", "ss58"]
    let a43Probes = indexProbesOf(A43)
    ck a43Probes.len == 1
    ck a43Probes[0].encodings == @["base58", "hex"]
    let a46Probes = indexProbesOf(A46)
    ck a46Probes.len == 1
    ck a46Probes[0].encodings == @["hex", "ss58"]

echo "assertion count: ", asserted
doAssert asserted == 146,
  "assertion count is " & $asserted & ", expected 146 — a case was added or removed."
