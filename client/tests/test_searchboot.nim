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
    ck cs[1].objectPath == "/" & blockPath(Slug, Hash)
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
    ck cs[0].objectPath == "/" & blockPath(Slug, Hash)

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
    ck m.shardFor("2b0f32c6") == "2b0f"
    ck m.shardIsPublished("2b0f")
    ck not m.shardIsPublished("dead")
    # A zero depth is §5.4's trigger — "no index" — and not an error.
    ck parseMeta("").prefixLen == 0
    ck parseMeta("7|0|x").prefixLen == 0

  test "the hash index keys on hex and is NOT the object tree's shard":
    # Recorded rather than assumed, because the two are four characters wide today
    # and look alike. The index's depth is published per build; the object tree's is
    # the contract's `ShardWidth`. Widening the index to a non-hex alphabet is a
    # separate, published-wire-format change.
    ck ShardWidth == 4
    let m = parseMeta("7|3|2b0")
    ck m.prefixLen == 3
    ck m.prefixLen != ShardWidth

echo "assertion count: ", asserted
doAssert asserted == 57,
  "assertion count is " & $asserted & ", expected 57 — a case was added or removed."
