## contract/identifier_encoding.nim
##
## The registry's per-chain identifier-encoding DECLARATION — Configuration.md
## §2.1 (the schema) and §2.2 (the additive rule).
##
## ## What this module is, and the one thing it is not
##
## It builds and validates `chains[<slug>].identifierEncoding`, the registry
## member that says which encoding a chain writes its identifiers in. Both
## registry producers write it through here:
##
##   * `src/blocktracer/chain/ingest.nim` — the real chains
##   * `src/blocktracer/demo/generator.nim` — the synthetic one
##
## **It is not read by anything.** Shard derivation (`contract/shards.nim`), the
## hash index (`contract/hashshard.nim`), the client's local path recomputation
## (`blocktracer_client/paths.nim`) and the capture tooling
## (`tools/capture/lib/entities.mjs`) all still derive from the string, and
## widening them is separate work — the last of it rewrites a published wire
## format and needs a compatibility window, so it has to land alone.
##
## The declaration lands first deliberately. Before a non-hex chain publishes the
## key layout is a decision; afterwards it is a migration of every published
## shard, index and URL. So the property this module has to have is not that
## something consumes it — it is that a consumer built against the schema WITHOUT
## this member reads a registry carrying it and behaves identically. Every
## in-repo registry reader reads named members out of the row and ignores the
## rest, which is what makes that true by construction rather than by promise;
## `tests/tidentifierencoding.nim` measures it anyway, with a control.
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
  IdentifierEncoding* = object
    ## One member of the closed set of encodings, as the shared file states it.
    id*: string
    shapeRows*: string
      ## The rows of Search-And-Routing.md §2's shape table this member comes
      ## from. Carried so the set's provenance is checkable by reading, in the
      ## same way `RefusalReason.condition` carries a member's.

  IdentifierKind* = object
    ## One member of the closed set of identifier kinds a declaration may speak
    ## about.
    id*: string
    pathSites*: string
      ## Where an identifier of this kind becomes a path segment.

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
    seenEncodings.add id
    result.encodings.add IdentifierEncoding(id: id, shapeRows: rows)
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

proc identifierEncodingIds*(): seq[string] =
  ## Every encoding id, in file order.
  for e in IdentifierEncodings: result.add e.id

proc identifierKindIds*(): seq[string] =
  ## Every kind id, in file order.
  for k in IdentifierKinds: result.add k.id

proc isIdentifierEncoding*(id: string): bool =
  ## Is this a member of the closed set of encodings?
  for e in IdentifierEncodings:
    if e.id == id: return true
  false

proc isIdentifierKind*(id: string): bool =
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

proc identifierEncodingNode*(byKind: openArray[(string, string)]): JsonNode =
  ## The `identifierEncoding` member for one chain's registry row: a JSON object
  ## mapping identifier kind to encoding token.
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
  result = newJObject()
  for kind in sorted:
    for (k, encoding) in byKind:
      if k == kind:
        result[kind] = %encoding
        break

proc hexIdentifierEncoding*(): JsonNode =
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
  ## A FRESH NODE PER CALL, not a `const`. A `JsonNode` is a ref, and both
  ## producers assign the result into a registry they then mutate and write; one
  ## shared node would be two trees pointing at one object.
  var pairs: seq[(string, string)]
  for k in IdentifierKinds: pairs.add (k.id, "hex")
  identifierEncodingNode(pairs)
