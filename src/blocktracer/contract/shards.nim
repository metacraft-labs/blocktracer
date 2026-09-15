## contract/shards.nim — path sharding
## (Static-Site-Architecture.md §2, Trace-Artifacts.md §3).
##
## Split out of `ids.nim` rather than copied. `ids.nim` derives opaque content
## ids and therefore imports `std/sha1`, which reaches `std/endians` and does
## not compile on the JS backend at all. Sharding needs none of that — it is
## string slicing — and the browser needs it, because `client/searchboot/`
## computes `/d/{chain}/tx/{shard}/{hash}.json` in a tab.
##
## The rule `paths.nim` states about itself applies with more force here: "a
## second `shardKeyFor` would be a second place for the layout to drift". The
## producer, the validator and the browser resolve one definition, and `ids.nim`
## re-exports these so no existing importer has to know the split happened.
##
## ## The encoding is a PARAMETER, and there is no hex-shaped entry point left
##
## There used to be a `hexShard(hashHex)` here, and its name was the whole
## problem: it hard-coded `0x` + hex into the published key layout for every
## chain, while the registry — which knows better, per chain and per kind of
## identifier — was read by nobody. `shardKeyFor(encoding, identifier)` takes the
## encoding as data instead, and the rule each token implies comes from
## `contract/identifier_encoding.nim` over
## `tools/chain/identifier-encodings.json`, so this module holds no table of
## per-encoding behaviour either.
##
## `hexShard` IS GONE RATHER THAN KEPT AS A WRAPPER, deliberately. A wrapper
## would be a working, correctly-named, hex-assuming entry point sitting one
## identifier away from every call site — reachable by habit, by autocomplete and
## by a merge, and impossible to distinguish from a considered choice when found
## in a diff. There is nothing a hex-specific entry point can do that
## `shardKeyFor("hex", …)` cannot, and the latter says which decision was made.
##
## ## What "the encoding reaches here" means, and where it does NOT come from
##
## It comes from one place per caller, and every one of them is the registry:
##
##   * the producers build a `ChainIdentifierEncoding` once, publish it into
##     `chains[<slug>].identifierEncoding`, and hand THE SAME VALUE to this
##     function — so a producer cannot declare one encoding and key another
##   * the validator reads it back out of the tree it is validating
##   * the client reads it at `openChain` and carries it on the session
##   * the browser's search bootstrap reads it out of the registry it already
##     fetches to enumerate chains
##
## What it is never derived from is the identifier string. Guessing `0x` means
## hex is how a client computes a path the producer never wrote.
##
## ## `traceShards` is NOT encoding-parameterised, and must never become so
##
## A trace artifact id is content-addressed by US — `contract/ids.nim` derives it
## from the execution input id and the recorder pin (Trace-Artifacts.md §2.1) —
## so its alphabet is a property of this pipeline and no chain has any say in it.
## The shared file records the same ruling from the other end: `traceArtifactId`
## is deliberately not one of the identifier kinds a registry row may speak about.
## Parameterising this function would invite a chain's declaration to re-address
## our own namespace, which is how a registry edit comes to move every published
## container.

import std/strutils
import ./identifier_encoding
export identifier_encoding

const ShardWidth* = 4
  ## `{h0h1}` / `{a0a1}` — the first two bytes, which for hex is four characters
  ## (Static-Site-Architecture.md §2). Named because the derivation pads to it
  ## and `Search-And-Routing.md` §5.3 says the depth is a published fact rather
  ## than something a client compiles in; this is the *object* tree's width, and
  ## the hash index carries its own in `meta.json`.

func shardKeyFor*(encoding, identifier: string): string =
  ## The shard path segment for one identifier, written in `encoding`.
  ##
  ## The leading `ShardWidth` characters of the identifier's PAYLOAD, in the
  ## identifier's own alphabet, right-padded with that alphabet's zero digit if
  ## the payload is shorter. A non-member token raises
  ## (`identifierEncodingRule`); so does an encoding whose alphabet cannot be a
  ## path segment.
  ##
  ## FOR `hex` THIS IS BYTE-FOR-BYTE WHAT `hexShard` PRODUCED, and it has to be:
  ## every shard path Aztec has published was derived that way and is still on a
  ## CDN (Publishing-And-Caching.md §6.1). Both of that function's quirks are
  ## preserved and both are load-bearing — a `0x` prefix is stripped only if
  ## present, and a payload shorter than four characters is right-padded with `0`
  ## rather than producing a narrower segment, which is what keeps `0x` + 1-63
  ## hex (the Starknet felt row) naming a four-character directory.
  ##
  ## IT NORMALISES PER ENCODING AND NEVER GLOBALLY. The case rule the member
  ## declares is applied first, through `identifierPayload`: `hex` and `bech32`
  ## fold, because two spellings are one identifier there; `base58`, `base64url`
  ## and `ss58` do not, because two spellings are two identifiers. There is no
  ## `toLowerAscii` in this module and there must not be one — a fold written
  ## here would be a fold that is right for hex and destroys four of the eight
  ## members, which is precisely the outcome the rule is data to prevent.
  ##
  ## FOLDING BEFORE SLICING IS WHAT MAKES A KEY RECOMPUTABLE. An EIP-55 address
  ## and its lowercase spelling are one account, and a client that arrived with
  ## either has to compute the one shard the producer wrote. The only hex
  ## identifier whose key this moves relative to the replaced `hexShard` is one
  ## carrying an uppercase digit — of which the committed captures contain none.
  ## `hexIdentifierEncoding` carries that measurement, with the definition it is
  ## taken under and the per-capture counts, so it can be re-run rather than
  ## quoted. The published Aztec layout is therefore unmoved, and that was diffed
  ## rather than argued (`just byte-identity`).
  let rule = identifierEncodingRule(encoding)
  if not rule.pathSafe:
    raise newException(ValueError,
      "identifier encoding '" & encoding & "' cannot be a shard path segment: " &
      "its alphabet contains a character that is not legal in one. A " &
      "derivation that worked for most identifiers and silently nested the " &
      "rest is worse than a refusal, so this refuses. Closing it means " &
      "choosing a path-safe re-encoding, which Search-And-Routing.md §2 and §5 " &
      "do not specify — see the shardKey notes in " &
      "tools/chain/identifier-encodings.json.")
  var h = identifierPayload(encoding, identifier)
  if h.len < ShardWidth: h = h & repeat(rule.pad[0], ShardWidth - h.len)
  h[0 ..< ShardWidth]

func shardKeyFor*(enc: ChainIdentifierEncoding, kind, identifier: string): string =
  ## The same derivation, reached through one chain's declaration — the form
  ## every path site uses, because a path site knows which KIND of identifier it
  ## is placing and the chain's row is what says how that kind is written.
  ##
  ## `encodingFor` raises on a kind this chain omitted, which is the point: a
  ## sharded path for an identifier the registry declined to describe is not a
  ## path that can be recomputed.
  shardKeyFor(enc.encodingFor(kind), identifier)

# ── THE PATHS WHOSE TWO SEGMENTS HAVE TO AGREE ──────────────────────────────
#
# THEY ARE HERE, IN THE CONTRACT, AND NOT ONLY IN THE CLIENT SDK — and the reason
# is a defect that was found by a null mutation result rather than by a test.
#
# `blocktracer_client/paths.nim` held the only path builders in the tree, and it
# is the CLIENT SDK: `src/blocktracer/chain/ingest.nim` and
# `src/blocktracer/demo/generator.nim` are producers, and the SDK is what reads
# what a producer wrote. `ci/test/client-sdk-boundary.sh` puts `demo/` and
# `validator.nim` on the SDK's forbidden list for exactly that reason, and an
# import in the other direction inverts the same relation. So each producer built
# its sharded paths by hand — `"d" / chain / "tx" / shardKeyFor(txEncoding, h) /
# h & ".json"` — and the day `shardKeyFor` started folding per the declared case
# rule, those hand-built paths became HALF-FOLDED: a folded shard segment beside a
# RAW name segment.
#
# MEASURED: ingesting a capture whose `txHash` carries an uppercase hex digit, the
# producer wrote `d/{chain}/tx/0a80/0x0A807E….json` while the client computes
# `d/{chain}/tx/0a80/0x0a807e….json` — a 404, and exactly the state
# `blocktracer_client/paths.nim`'s own header names as the defect ("a directory
# that exists holding a file that does not"). It was unreachable on today's
# captures, because every identifier in every one of them is lowercase, and the
# validator does catch it — but neither of those is the invariant `paths.nim`
# asserted, which was tree-wide.
#
# PATCHING THE CALL SITES WOULD NOT HAVE REMOVED THE POSSIBILITY. There were
# FOURTEEN of them across the two producers, twelve of them sharded and therefore
# half-foldable; they rot (their line numbers moved twice during this change
# alone); and the next producer writes a fifteenth. So the builders moved DOWN to the layer both
# sides already depend on — this module, which is where `shardKeyFor` and
# `identifierKeyForm` both are, and which compiles on the JS backend because
# sharding is string slicing. `blocktracer_client/paths.nim` re-exports them, so
# no consumer changed; the producers now call the same functions the client does,
# and the shard and the name are derived from one expression that cannot disagree.

func txFactsPath*(chain, txHash: string,
                  enc: ChainIdentifierEncoding): string =
  ## The immutable facts (Static-Site-Architecture.md §2.3, §2.3b).
  "d/" & chain & "/tx/" & shardKeyFor(enc, KindTransaction, txHash) & "/" &
    identifierKeyForm(enc, KindTransaction, txHash) & ".json"

func txStatePath*(chain, generation, txHash: string,
                  enc: ChainIdentifierEncoding): string =
  ## Generation-scoped canonicality + finality (§2.3b).
  "d/" & chain & "/g/" & generation & "/txstate/" &
    shardKeyFor(enc, KindTransaction, txHash) & "/" &
    identifierKeyForm(enc, KindTransaction, txHash) & ".json"

func traceSelectionPath*(chain, traceSelectionVersion, txHash: string,
                         enc: ChainIdentifierEncoding): string =
  ## The versioned TraceSelection overlay (§2.3a).
  "d/" & chain & "/ts/" & traceSelectionVersion & "/" &
    shardKeyFor(enc, KindTransaction, txHash) & "/" &
    identifierKeyForm(enc, KindTransaction, txHash) & ".json"

func addressIndexPath*(chain, generation, address: string,
                       enc: ChainIdentifierEncoding): string =
  "d/" & chain & "/g/" & generation & "/addr/" &
    shardKeyFor(enc, KindAddress, address) & "/" &
    identifierKeyForm(enc, KindAddress, address) & ".json"

func addressSegmentPath*(chain, address, segment: string,
                         enc: ChainIdentifierEncoding): string =
  "d/" & chain & "/seg/" & shardKeyFor(enc, KindAddress, address) & "/" &
    identifierKeyForm(enc, KindAddress, address) & "/" & segment & ".json"

func blockPath*(chain, blockHash: string,
                enc: ChainIdentifierEncoding): string =
  ## Content-addressed and generation-independent (§2) — and KEY-FORMED, like
  ## every other identifier this module places in a path.
  ##
  ## IT TOOK NO ENCODING UNTIL NOW, AND THE GAP WAS LIVE. There is no shard
  ## segment here, so for a while there looked to be no alphabet question to
  ## answer — but the CASE question is not the alphabet question. With the other
  ## five builders folding and this one not, `/tx/0xABC…` and `/address/0xABC…`
  ## resolved while `/block/0xABC…` did not, on the same user input, on routes
  ## served by `client/src/ssr.nim` and by a published SDK package. Before
  ## per-encoding case handling all three were equally case-sensitive, so the
  ## asymmetry was created by the widening and not inherited.
  ##
  ## The `block` kind was always in the closed set for exactly this reason: a
  ## chain that numbers its blocks (`decimal`) says something true about them,
  ## and `encodingFor` raises on a chain that declared the kind away rather than
  ## inventing a key for it.
  "d/" & chain & "/block/" &
    identifierKeyForm(enc, KindBlock, blockHash) & ".json"

func traceShards*(tid: string): tuple[a, b: string] =
  ## `/t/{tid[0:2]}/{tid[2:4]}/{tid}/` — Trace-Artifacts.md §3.
  ##
  ## NO ENCODING PARAMETER, ON PURPOSE — see this module's header. `tid` is ours,
  ## content-addressed by `contract/ids.nim`, and widening this would put our own
  ## namespace under a chain's declaration.
  (tid[0 .. 1], tid[2 .. 3])
