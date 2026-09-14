## contract/identifier_encoding.nim
##
## The registry's per-chain identifier-encoding DECLARATION — Configuration.md
## §2.1 (the schema) and §2.2 (the additive rule).
##
## ## What this module is, and what reads it
##
## It builds, validates, reads back and *answers questions about*
## `chains[<slug>].identifierEncoding`, the registry member that says which
## encoding a chain writes its identifiers in. Both registry producers write it
## through here:
##
##   * `src/blocktracer/chain/ingest.nim` — the real chains
##   * `src/blocktracer/demo/generator.nim` — the synthetic one
##
## **Shard-path derivation reads it.** `contract/shards.nim` takes the encoding
## as a parameter — `shardKeyFor(encoding, identifier)` — and gets the rule each
## token implies from `identifierEncodingRule` below, which is this module's read
## of the shared file. `blocktracer_client/paths.nim` re-exports that one
## function, so the producer, the validator and the browser derive one way.
##
## THERE IS EXACTLY ONE PLACE THAT DECIDES WHICH ENCODING APPLIES, and it is not
## this module: it is the registry row. A producer builds a
## `ChainIdentifierEncoding` once, publishes it *and* derives with it, so it
## cannot declare one thing and key another; the validator and the client read
## the same value back out of the published row. This module's job is to make the
## token mean something — the *set* of tokens and the *rule* per token both come
## from `tools/chain/identifier-encodings.json`, so it holds no table of its own
## either.
##
## **Two sites still derive from the string, and both are later steps.** The hash
## index (`contract/hashshard.nim`) parses hex pairs and lowercases
## unconditionally; it is a published, self-describing wire format, so widening
## it is a migration of every published shard plus a compatibility window. The
## capture tooling (`tools/capture/lib/entities.mjs`) filters published directory
## entries on a literal `0x`; it enumerates the tree the index keys, so it
## follows the index rather than the derivation.
##
## THAT IS THE ARGUMENT FOR THE TWO FILTERS AND NOT FOR THE WHOLE OF THAT FILE.
## `entities.mjs` ALSO open-codes this module's hex rule outright, at three sites
## (`t.hash.slice(2, 6)`, `address.slice(2, 6)`, `hash.slice(2, 6)`), to build
## `/d/{chain}/tx/{shard}/`, `/d/{chain}/ts/{tsv}/{shard}/` and
## `/d/{chain}/g/{gen}/addr/{shard}/`. Those DERIVE rather than enumerate, so the
## "it follows the index" defence does not cover them: by the rule this seam is
## sequenced on, a site that derives a path belongs with the derivation. They are
## also stricter than the function they duplicate — an unconditional slice, so
## neither the strip-only-if-present quirk nor the right-padding — and they are
## correct today only because every chain this tree publishes declares `hex`.
## Neither boundary arm pins them: both count `startsWith("0x")`, so a fourth
## `slice(2, 6)` would be invisible to both halves. Closing it means giving the
## tooling a path helper to call or a JavaScript reader of the shared set; until
## then this paragraph is the only thing that knows.
##
## The declaration landed before the derivation deliberately, and the derivation
## before the index for the same reason. Before a non-hex chain publishes the key
## layout is a decision; afterwards it is a migration of every published shard,
## index and URL. A consumer built against the schema WITHOUT this member must
## still read a registry carrying it and behave identically
## (`tests/tidentifierencoding.nim` measures that, with three controls) — and the
## converse now matters too: a tree published WITHOUT the member must still be
## readable, which is what `declaredOrLegacy` is for and the only thing it is for.
##
## ## Why the set is read from bytes instead of declared as an enum here
##
## For the reason `chain/refusal_reasons.nim` and `chain/snapshot_format.nim`
## give. Both registry producers are Nim, so an enum would close the set for
## them; it would not close it for the capture tooling, which is JavaScript and
## is one of the derivation sites that has to agree with them. A set closed in
## one language and open in the other is not closed.
##
## So the members live in `tools/chain/identifier-encodings.json`, read here with
## `staticRead` at COMPILE time. A member added there is a member here with
## nobody remembering to copy it, and a file that is missing, malformed or of a
## format this module does not know fails the BUILD rather than producing a
## producer that writes whatever it likes.
##
## ## Why the value is per kind
##
## Because one token per chain is measurably too narrow. Search-And-Routing.md
## §2 gives TON base64url addresses with base64 transaction hashes, Fuel bech32m
## addresses with hex transaction hashes, and Sui base64 digests — chains whose
## identifiers differ BY KIND, and either TON or Fuel alone settles it. That Sui's
## ADDRESSES are hex is the Move charter's statement rather than §2's: §2's hex row
## is labelled for a transaction or block hash and gives Move no address row. The
## shared file cites it accordingly, because reading an address claim out of a row
## labelled for hashes is the amendment-by-inference it refuses elsewhere. Solana,
## whose addresses and signatures are both base58, is the counter-example that
## shows a token would have sufficed for some chains and not for these. The shared
## file's header carries the full reasoning and the citations.

import std/[json, strutils, algorithm]

const identifierEncodingsJson =
  staticRead("../../../tools/chain/identifier-encodings.json")

const IdentifierEncodingsFormat* = "blocktracer/identifier-encodings@1"
  ## The format token this module knows. Named rather than inlined so the
  ## JavaScript side's selftest can read it out of this source and check that the
  ## two halves agree about which shape of the shared file they are reading.

type
  ShardKeyRule* = object
    ## What one encoding implies for a shard path segment — read from the shared
    ## file, never spelled here. `contract/shards.nim` is the only consumer.
    ##
    ## Four fields, and the shared file's `shardKey` header says why each exists.
    ## Briefly: a shard segment is the leading `ShardWidth` characters of the
    ## identifier's PAYLOAD in the identifier's own alphabet, so the rule has to
    ## say where the payload starts (`stripPrefix`, `payloadAfterLast`), what to
    ## pad a short one with (`pad` — the alphabet's zero digit, which is not `0`
    ## for base58, bech32 or base64), and whether the alphabet can legally appear
    ## in a path segment at all (`pathSafe` — false for `base64`, whose alphabet
    ## contains `/`).
    stripPrefix*: string
    payloadAfterLast*: string
    pad*: string
    pathSafe*: bool

  IdentifierEncoding* = object
    ## One member of the closed set of encodings, as the shared file states it.
    id*: string
    shapeRows*: string
      ## The rows of Search-And-Routing.md §2's shape table this member comes
      ## from. Carried so the set's provenance is checkable by reading, in the
      ## same way `RefusalReason.condition` carries a member's.
    shardKey*: ShardKeyRule

  IdentifierKind* = object
    ## One member of the closed set of identifier kinds a declaration may speak
    ## about.
    id*: string
    pathSites*: string
      ## Where an identifier of this kind becomes a path segment.

  ChainIdentifierEncoding* = object
    ## ONE CHAIN'S declaration, as a value rather than as JSON — the thing a
    ## producer builds once and both publishes and derives with, and the thing a
    ## client and the validator read back out of the published row.
    ##
    ## `seq` of pairs rather than a `Table` for `refusal_reasons.nim`'s reason
    ## (three members is a linear scan nobody will measure) and for one more:
    ## the pairs are kept SORTED, which is what makes the published member
    ## byte-stable across a regeneration however the caller ordered its arguments.
    byKind*: seq[(string, string)]
    declared*: bool
      ## Whether a registry row actually carried the member. False means the row
      ## predates it, in which case `byKind` holds the §6.1 compatibility
      ## fallback — see `parseChainIdentifierEncoding` and `declaredOrLegacy`.
      ## Carried rather than inferred so that "this tree declares hex" and "this
      ## tree is old and we are assuming hex" are two distinguishable facts; a
      ## consumer that could not tell them apart would report the assumption as
      ## the chain's own statement.

proc parseIdentifierEncodings(): tuple[kinds: seq[IdentifierKind],
                                       encodings: seq[IdentifierEncoding]] =
  ## Reads the shared file at compile time, in file order.
  ##
  ## `seq`s of objects rather than `Table`s, for the reason
  ## `refusal_reasons.nim` gives: a `const Table` cannot be indexed at run time
  ## in Nim, and eight members is a linear scan nobody will ever measure.
  let doc = parseJson(identifierEncodingsJson)
  if doc{"format"}.getStr != IdentifierEncodingsFormat:
    raise newException(ValueError,
      "tools/chain/identifier-encodings.json declares format '" &
      doc{"format"}.getStr & "', and this module only knows " &
      IdentifierEncodingsFormat & ". A half-read closed set is an open one.")

  var seenKinds: seq[string]
  for k in doc{"kinds"}.getElems:
    let id = k{"id"}.getStr
    if id.len == 0:
      raise newException(ValueError, "an identifier kind with no id")
    if id in seenKinds:
      raise newException(ValueError,
        "identifier kind '" & id & "' is declared twice. A set with a repeated " &
        "member is a set whose size is not its cardinality, and every 'is this " &
        "a member' check would still pass while the file said two things.")
    if id != id.toLowerAscii or id.contains(' '):
      raise newException(ValueError,
        "identifier kind '" & id & "' is not a bare lowercase token. It is a " &
        "JSON object key in a published artifact, so it has to be writable " &
        "without quoting rules mattering.")
    seenKinds.add id
    result.kinds.add IdentifierKind(id: id, pathSites: k{"pathSites"}.getStr)
  if result.kinds.len == 0:
    raise newException(ValueError,
      "tools/chain/identifier-encodings.json defines no identifier kinds. A " &
      "declaration would then have nothing it could legally say, so every " &
      "'the declared kinds are members' check would be vacuously true.")

  var seenEncodings: seq[string]
  for e in doc{"encodings"}.getElems:
    let id = e{"id"}.getStr
    if id.len == 0:
      raise newException(ValueError, "an identifier encoding with no id")
    if id in seenEncodings:
      raise newException(ValueError,
        "identifier encoding '" & id & "' is declared twice, so the file states " &
        "two things about one member and a membership check cannot tell which.")
    if id != id.toLowerAscii or id.contains(' '):
      raise newException(ValueError,
        "identifier encoding '" & id & "' is not a bare lowercase token. It is " &
        "published verbatim as a registry value, and a value that has to be " &
        "normalised before it can be compared is the drift a closed set exists " &
        "to stop.")
    let rows = e{"shapeRows"}.getStr
    if rows.len == 0:
      raise newException(ValueError,
        "identifier encoding '" & id & "' names no row of the shape table. " &
        "Every member says where it comes from; that is what makes the set " &
        "reviewable against Search-And-Routing.md §2 rather than merely finite.")
    # EVERY MEMBER MUST CARRY A SHARD RULE, and the absence fails the BUILD. A
    # member without one would be a token a producer could declare and a chain
    # could publish under, which the derivation would then meet for the first
    # time at run time with nothing to do — the "closed set with a hole in it"
    # the arms below already refuse in the other direction.
    let sk = e{"shardKey"}
    if sk == nil or sk.kind != JObject:
      raise newException(ValueError,
        "identifier encoding '" & id & "' carries no shardKey rule. Every " &
        "member has to say what it implies for a path segment, because " &
        "contract/shards.nim derives from THIS FILE rather than from a table " &
        "of its own — a member with no rule is a token the derivation cannot " &
        "honour.")
    let pad = sk{"pad"}.getStr
    if pad.len != 1:
      raise newException(ValueError,
        "identifier encoding '" & id & "' declares a pad of '" & pad &
        "', and a pad is exactly one character: the alphabet's zero digit. It " &
        "right-pads an identifier shorter than a shard segment, so a pad of " &
        "none could not widen one and a pad of several would overshoot.")
    if sk{"pathSafe"}.kind != JBool:
      raise newException(ValueError,
        "identifier encoding '" & id & "' does not say whether it is " &
        "pathSafe. Absent is not false: a member that forgot to answer would " &
        "be refused at every shard site as if its alphabet contained a " &
        "separator, and one that defaulted to true would publish a path " &
        "segment with a `/` in it.")
    seenEncodings.add id
    result.encodings.add IdentifierEncoding(id: id, shapeRows: rows,
      shardKey: ShardKeyRule(stripPrefix: sk{"stripPrefix"}.getStr,
                             payloadAfterLast: sk{"payloadAfterLast"}.getStr,
                             pad: pad,
                             pathSafe: sk{"pathSafe"}.getBool))
  if result.encodings.len == 0:
    raise newException(ValueError,
      "tools/chain/identifier-encodings.json defines no encodings. An empty " &
      "closed set would make every 'the declared encoding is a member' check " &
      "vacuously false and every 'no encoding is outside the set' check " &
      "vacuously true.")

const
  parsed = parseIdentifierEncodings()
  IdentifierKinds* = parsed.kinds
    ## The closed set of kinds, in the order the shared file lists it.
  IdentifierEncodings* = parsed.encodings
    ## The closed set of encodings, in the order the shared file lists it.

const
  KindTransaction* = "transaction"
  KindAddress* = "address"
  KindBlock* = "block"
    ## The three kinds, named so a path site can say WHICH kind of identifier it
    ## is building a segment from. A path function has to name its kind — the
    ## point of the per-kind declaration is that a chain may write its addresses
    ## and its transaction hashes differently — and a bare string literal at
    ## every site would be three dozen places to misspell one.
    ##
    ## These are names for members of the set, not a second copy of it: the
    ## `static` block below fails the BUILD if the shared file stops declaring
    ## one of them, so renaming a kind in the data cannot leave a path site
    ## pointing at a kind that no longer exists.

  LegacyUndeclaredEncoding* = "hex"
    ## What a registry row that carries NO `identifierEncoding` at all derives
    ## with — see `declaredOrLegacy`, which is the only place this is applied.

proc identifierEncodingIds*(): seq[string] =
  ## Every encoding id, in file order.
  for e in IdentifierEncodings: result.add e.id

proc identifierKindIds*(): seq[string] =
  ## Every kind id, in file order.
  for k in IdentifierKinds: result.add k.id

func isIdentifierEncoding*(id: string): bool =
  ## Is this a member of the closed set of encodings?
  for e in IdentifierEncodings:
    if e.id == id: return true
  false

func isIdentifierKind*(id: string): bool =
  ## Is this a member of the closed set of kinds?
  for k in IdentifierKinds:
    if k.id == id: return true
  false

proc identifierEncodingList*(): string =
  ## The encoding members, for a failure message. A refusal that names only what
  ## it did not recognise makes the reader go looking; one that also names what
  ## it knows makes the fix visible from the failure.
  identifierEncodingIds().join(", ")

proc identifierKindList*(): string =
  ## The kind members, for a failure message.
  identifierKindIds().join(", ")

static:
  # THE THREE NAMED KINDS ARE MEMBERS, ASSERTED AT COMPILE TIME. Without this the
  # constants above would be a second, silently-diverging copy of the kind set:
  # renaming `address` in the shared file would leave `addressIndexPath` asking
  # for a kind no row can declare, and the failure would arrive at run time in a
  # producer rather than here.
  doAssert isIdentifierKind(KindTransaction)
  doAssert isIdentifierKind(KindAddress)
  doAssert isIdentifierKind(KindBlock)
  # …and the legacy fallback names a real member, for the same reason.
  doAssert isIdentifierEncoding(LegacyUndeclaredEncoding)

func identifierEncodingRule*(encoding: string): ShardKeyRule =
  ## The shard-path rule a token implies, from the shared file.
  ##
  ## **A non-member raises**, and that is the property the derivation needs: a
  ## token this build does not know must not fall back to hex, because falling
  ## back to hex is exactly the assumption the encoding is data to remove. The
  ## refusal names the set, so the fix is visible from the failure.
  for e in IdentifierEncodings:
    if e.id == encoding: return e.shardKey
  raise newException(ValueError,
    "'" & encoding & "' is not an identifier encoding, so there is no shard " &
    "rule for it. The encodings are: " & identifierEncodingList() &
    ". Adding one is an amendment to Search-And-Routing.md §2's shape table " &
    "and belongs in tools/chain/identifier-encodings.json with the row it " &
    "comes from and the shardKey rule it implies.")

func declaredOrLegacy*(token: string): string =
  ## The encoding to derive with, given what a registry row declared.
  ##
  ## **The ONE place in this tree that turns an absence into a token**, and the
  ## reason it is one place is that it is a compatibility rule rather than a
  ## derivation: a tree published before `identifierEncoding` existed was
  ## published by a producer that keyed `0x` + hex, and every one of its shard
  ## paths is still on a CDN (Publishing-And-Caching.md §6.1). So an EMPTY token
  ## means "this row predates the declaration" and resolves to
  ## `LegacyUndeclaredEncoding`.
  ##
  ## AN EMPTY TOKEN IS NOT THE SAME AS AN OMITTED KIND, and callers must not
  ## conflate them. A row that declares `{address: "ss58"}` and is asked for its
  ## transaction encoding has said something — that it cannot describe one — and
  ## `encodingFor` raises on it. Only a row with no member at all reaches here.
  ##
  ## A token that is present and not a member still raises: the compatibility
  ## window is for absence, not for garbage.
  if token.len == 0: return LegacyUndeclaredEncoding
  if isIdentifierEncoding(token): return token
  raise newException(ValueError,
    "the registry declares identifier encoding '" & token & "', which is not a " &
    "member of the closed set (" & identifierEncodingList() & "). A tree " &
    "declaring a token this build does not know is refused rather than read as " &
    "hex: guessing here is how a client computes a path the producer never wrote.")

func sortedDeclaration(byKind: openArray[(string, string)]):
    seq[(string, string)] =
  ## The validated, sorted per-kind pairs of one declaration.
  ##
  ## **A kind or an encoding outside the closed set raises.** Carrying it would
  ## make the set open at its last hop — the published artifact — which is the
  ## one place a closed set has to hold, because that is where a consumer reads
  ## it and where nothing can be taken back. The producers cannot reach a
  ## non-member through the helpers below, and this is what makes that a property
  ## of the module rather than of their current call sites.
  ##
  ## KEYS ARE SORTED, so a regeneration is byte-identical however the caller
  ## happened to order its pairs. Both producers publish trees that are compared
  ## byte-for-byte across runs, and a member whose key order followed an argument
  ## list would be a diff that meant nothing.
  ##
  ## An omitted kind is legal and is not a default — see the shared file on
  ## Substrate's `blockIndex` identity, which no member of the encoding set can
  ## honestly describe.
  ##
  ## IT TOUCHES NO `JsonNode`, and that is measured rather than tidy. The
  ## validating path is reached from the browser — `client/searchboot/` builds a
  ## declaration from the registry it fetched — and routing it through
  ## `newJObject` made `std/json`'s runtime live in a `nim js` bundle whose own
  ## header brags about being 40 KB rather than 1.3 MB. It cost **78 KB** of the
  ## search bundle (90,276 bytes to 168,618) to build a three-entry object and
  ## read it straight back. `identifierEncodingNode` still exists for the
  ## producers, who publish bytes and are not in a browser.
  if byKind.len == 0:
    raise newException(ValueError,
      "an identifierEncoding declaration with no kinds at all. Omitting a kind " &
      "says the chain does not identify it by an encoded string; omitting all " &
      "of them says nothing, and a member that says nothing is worse than an " &
      "absent one because a reader cannot tell it from a producer that tried.")
  var kinds: seq[string]
  for (kind, encoding) in byKind:
    if not isIdentifierKind(kind):
      raise newException(ValueError,
        "'" & kind & "' is not an identifier kind. The kinds are: " &
        identifierKindList() & ". They are the chain-supplied identifiers that " &
        "become path segments; a trace artifact id or a code hash is ours and " &
        "is deliberately not one of them.")
    if not isIdentifierEncoding(encoding):
      raise newException(ValueError,
        "'" & encoding & "' is not an identifier encoding, so it may not be " &
        "declared for kind '" & kind & "'. The encodings are: " &
        identifierEncodingList() & ". Adding one is an amendment to " &
        "Search-And-Routing.md §2's shape table and belongs in " &
        "tools/chain/identifier-encodings.json with the row it comes from.")
    if kind in kinds:
      raise newException(ValueError,
        "kind '" & kind & "' is declared twice in one identifierEncoding, so " &
        "the row states two encodings for one kind of identifier.")
    kinds.add kind
  var sorted = @kinds
  sorted.sort()
  for kind in sorted:
    for (k, encoding) in byKind:
      if k == kind:
        result.add (kind, encoding)
        break

func chainIdentifierEncoding*(byKind: openArray[(string, string)]):
    ChainIdentifierEncoding =
  ## One chain's declaration as a VALUE, validated on the way in.
  ##
  ## This is the shape a producer builds ONCE and then both publishes (through
  ## `identifierEncodingNode`) and derives with (through `encodingFor`, which
  ## `contract/shards.nim` consumes). That is the whole single-source argument of
  ## the derivation step: a producer physically cannot declare `hex` in the
  ## registry and key a path some other way, because the same value does both
  ## jobs.
  ##
  ## Validation and key order are `sortedDeclaration`'s, which is also what the
  ## published member is built from — so a value and the bytes it publishes cannot
  ## disagree about either.
  result.declared = true
  result.byKind = sortedDeclaration(byKind)

proc identifierEncodingNode*(d: ChainIdentifierEncoding): JsonNode =
  ## The registry member for this declaration — the bytes a producer publishes.
  ##
  ## A FRESH NODE PER CALL. A `JsonNode` is a ref and both producers assign the
  ## result into a registry they then mutate and write, so a shared node would be
  ## two trees pointing at one object.
  result = newJObject()
  for (kind, encoding) in d.byKind: result[kind] = %encoding

proc identifierEncodingNode*(byKind: openArray[(string, string)]): JsonNode =
  ## The member built straight from pairs — the same thing, for a caller that has
  ## no reason to hold the value. Validated and key-sorted, because it is
  ## `chainIdentifierEncoding` followed by the overload above.
  identifierEncodingNode(chainIdentifierEncoding(byKind))

func encodingFor*(d: ChainIdentifierEncoding, kind: string): string =
  ## The token this chain declared for one kind of identifier.
  ##
  ## **An OMITTED kind raises, naming it.** Omission is a statement — the shared
  ## file's example is Substrate, whose transaction identity is a `{block,
  ## index}` pair that no member of the encoding set can honestly describe — so a
  ## site that asks for a sharded path segment for a kind the chain said it
  ## cannot describe is a producer bug. Defaulting to hex there is precisely the
  ## silent wrong answer this seam exists to remove: it would publish a key under
  ## an assumption the registry had explicitly declined to make.
  ##
  ## A declaration that was never read at all (`declared == false` with no pairs)
  ## raises with a different message, because the remedy is different: that is a
  ## value somebody default-constructed rather than a chain that omitted a kind.
  if not isIdentifierKind(kind):
    raise newException(ValueError,
      "'" & kind & "' is not an identifier kind. The kinds are: " &
      identifierKindList() & ".")
  for (k, encoding) in d.byKind:
    if k == kind: return encoding
  if d.byKind.len == 0:
    raise newException(ValueError,
      "this ChainIdentifierEncoding carries no declaration at all, so it " &
      "cannot say how '" & kind & "' is encoded. It was default-constructed " &
      "rather than read: a session comes from `openChain`, a producer's from " &
      "`hexIdentifierEncoding` or `chainIdentifierEncoding`, and a registry " &
      "row's from `parseChainIdentifierEncoding`. Deriving hex here would be a " &
      "second place deciding the encoding.")
  # The declared kinds, joined by hand rather than with `$`. Stringifying a
  # `seq[(string, string)]` reaches `collectionToString`, which this module has
  # measured into a browser bundle — see `sortedDeclaration` on the same subject.
  var declaredKinds: string
  for (k, _) in d.byKind:
    if declaredKinds.len > 0: declaredKinds.add ", "
    declaredKinds.add k
  raise newException(ValueError,
    "this chain's registry row declares no encoding for kind '" & kind &
    "' (it declares: " & declaredKinds & "). An omitted kind says the chain does " &
    "not identify it by an encoded string — Substrate's `blockIndex` " &
    "transaction identity is the case that forces it — so there is no path " &
    "segment to derive and hex-by-default would invent one.")

proc parseChainIdentifierEncoding*(row: JsonNode): ChainIdentifierEncoding =
  ## One chain's declaration, read back out of a published registry row.
  ##
  ## THE READER SIDE OF THE SINGLE SOURCE. The validator and the client both come
  ## through here, so neither holds an opinion about a chain's encoding: they read
  ## the row the producer wrote.
  ##
  ## **A row with no member at all is the compatibility case**, not an error: it
  ## is a tree published before the member existed, whose shard paths are hex and
  ## are still on a CDN (Publishing-And-Caching.md §6.1). Every kind resolves
  ## through `declaredOrLegacy`, the one function that turns that absence into a
  ## token, and `declared` is left false so a consumer can tell the two apart.
  ##
  ## A member that is present but not an object, or that declares a kind or token
  ## outside the closed set, RAISES. The compatibility window is for absence.
  let decl = if row == nil: nil else: row{"identifierEncoding"}
  if decl == nil or decl.kind == JNull:
    result.declared = false
    for k in IdentifierKinds:
      result.byKind.add (k.id, declaredOrLegacy(""))
    return
  if decl.kind != JObject:
    raise newException(ValueError,
      "chains[…].identifierEncoding is a " & $decl.kind & " and the schema " &
      "makes it an object of kind -> encoding (Configuration.md §2.1). A " &
      "reader that shrugged at the wrong shape would derive keys from whatever " &
      "it found.")
  var kinds: seq[string]
  for kind, value in decl:
    if not isIdentifierKind(kind):
      raise newException(ValueError,
        "chains[…].identifierEncoding declares '" & kind & "', which is not an " &
        "identifier kind. The kinds are: " & identifierKindList() & ".")
    if value.kind != JString:
      raise newException(ValueError,
        "chains[…].identifierEncoding['" & kind & "'] is a " & $value.kind &
        " and an encoding token is a string.")
    kinds.add kind
  kinds.sort()
  result.declared = true
  for kind in kinds:
    result.byKind.add (kind, declaredOrLegacy(decl[kind].getStr))

proc hexIdentifierEncoding*(): ChainIdentifierEncoding =
  ## Every kind in the closed set declared `hex` — the declaration that is true
  ## of every chain this tree publishes, and the only one either producer writes
  ## today.
  ##
  ## MEASURED, NOT ASSUMED, and the measurement is stated so it can be re-run.
  ## Every `0x`-hex literal in both committed Aztec captures is LOWERCASE:
  ## `fixtures/chain-artifacts/aztec-testnet/` carries 386 distinct ones and
  ## `tests/fixtures/chain-snapshots/aztec-mainnet-live/` 990, with **zero**
  ## uppercase hex digits in either — transaction hashes, block hashes, contract
  ## addresses, contract class ids and artifact hashes alike. Exactly two lengths
  ## occur and both are hex: 66 (`0x` + 64, the field elements, which is every
  ## identifier of the three declared kinds) and 42 (`0x` + 40 — `coinbase` and
  ## `rollupAddress`, which are L1 addresses carried as block metadata and are not
  ## path segments, so no kind declares them). The demo generator's synthetic
  ## addresses are `0x` + 40 lowercase hex (`synthAddr`).
  ##
  ## So for the kinds this declaration speaks about there is no EIP-55 checksum
  ## riding in the case — they are field elements, not 20-byte accounts — and the
  ## display-form-versus-key-form split that per-encoding case handling has to deal
  ## with does not arise on this chain. Note that the argument is about the field
  ## elements and does not extend to the two L1 addresses above, which are ordinary
  ## Ethereum addresses that merely happen to be all-lowercase here; they are
  ## outside the kinds, which is why that does not matter.
  ##
  ## IT RETURNS A VALUE AND NOT A REGISTRY MEMBER, which is the change the
  ## derivation step needed: a producer calls this once, hands
  ## `identifierEncodingNode` the result to publish, and hands `shardKeyFor` the
  ## same result to derive with. Two calls in one producer would be two decisions.
  var pairs: seq[(string, string)]
  for k in IdentifierKinds: pairs.add (k.id, "hex")
  chainIdentifierEncoding(pairs)
