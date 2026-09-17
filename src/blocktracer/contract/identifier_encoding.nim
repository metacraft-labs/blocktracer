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
## **Case handling reads it too, and is no longer global.** `identifierKeyForm`,
## `identifierPayload` and `identifierDisplayForm` below answer over the shared
## file's `case` rule, so the four behaviours that rule distinguishes — hex
## folded for its key with its EIP-55 display form preserved, base58 and
## base64url untouched because they are case-significant, bech32 and bech32m made
## uniform, decimal left alone because it has no letters — are stated per member
## in one place and applied at every site that keys an identifier. The sites are
## the shard derivation, the object-name segment of every sharded path
## (`blocktracer_client/paths.nim`), the §5 hash index's shard key
## (`contract/hashshard.nim`) and the client's query canonicalisation
## (`client/src/viewmodel/search_shapes.nim`); `src/blocktracer/validator.nim`
## checks that a published tree states both forms where it says it does.
##
## `hashshard.nim`'s `stripHex` — a single unconditional `toLowerAscii` applied
## to every identifier of every encoding, plus a `0x` strip — IS GONE rather than
## kept as a wrapper, for the reason `hexShard` was: a correctly-named
## hex-assuming entry point one identifier away from every call site is reachable
## by habit and is indistinguishable from a considered choice in a diff.
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
## **The last site that derived from the string was the hash index, and it no
## longer does.** `contract/hashshard.nim` held a `hexToBytes` that PARSED HEX
## PAIRS, so a base58 or bech32 identifier had no representation in the index at
## all, and on anything it could not parse it raised an unhandled `parseHexInt`
## that killed the producer. `identifierIndexKey` below replaced it: it reads the
## per-member `alphabet` rule and REFUSES BY NAME.
##
## **That index keys per identifier SHAPE, not per chain, and the reason is the
## path.** §5's index path carries no chain segment — which is what makes "two
## requests to resolve any hash on any chain" true — so a client resolving a bare
## query does not know which chain it will hit and cannot read that chain's
## declaration. It does know the query's SHAPE, which is Search-And-Routing §2's
## table and is derivable from the string alone; `identifierEncodingsMatching`
## below is that derivation, over the shared file's `shapes` rule. The producer
## keys with the encoding its chain declared, the client keys with each encoding
## its query's shapes imply, and the two meet because both slice the same
## `identifierPayload`. The stored bytes are a published wire format, so widening
## them was VERSIONED rather than mutated (Publishing-And-Caching.md §6.1, and
## Search-And-Routing.md §5.5).
##
## **The capture tooling no longer derives anything.** `entities.mjs` used to
## open-code this module's hex rule outright, at three sites (`t.hash.slice(2,
## 6)`, `address.slice(2, 6)`, `hash.slice(2, 6)`), to build
## `/d/{chain}/tx/{shard}/`, `/d/{chain}/ts/{tsv}/{shard}/` and
## `/d/{chain}/g/{gen}/addr/{shard}/` — a second place deciding the published
## layout, in another language, stricter than the function it duplicated (an
## unconditional slice, so neither the strip-only-if-present quirk nor the
## right-padding). It now ENUMERATES the published shard directories and indexes
## what it finds by file name, so it reads the layout the producer wrote instead
## of recomputing it. That needs no JavaScript reader of the shared set and
## leaves no second derivation to drift. Its two remaining `startsWith("0x")`
## filters over published directory entries are enumeration and genuinely do
## follow the index; both boundary halves now pin the ABSENCE of a derivation
## there as well as the count of those filters, so a fourth `slice(2, 6)` cannot
## appear unnoticed.
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
    alphabet*: string
      ## Every character an identifier of this member may be written in, IN KEY
      ## FORM — so `hex` lists only the lowercase digits, because the case rule
      ## folds before the alphabet is consulted.
      ##
      ## It is data for the reason every other field here is data: the §5 hash
      ## index has to REFUSE an identifier it cannot key, by name, and the
      ## alternative was a table of per-alphabet character sets inside
      ## `contract/hashshard.nim` — a second place deciding what an identifier
      ## of a given encoding may look like. `identifierIndexKey` is the one
      ## consumer.
    pathSafe*: bool

  IdentifierCaseRule* = object
    ## What one encoding implies for CASE — read from the shared file, never
    ## spelled here, and a different question from where the payload starts.
    ##
    ## `significant` says whether two identifiers differing only in case are
    ## DIFFERENT identifiers; `keyForm` says what normalisation produces the form
    ## an identifier is keyed by (`lower` or `preserve`); `displayForm` says what
    ## is rendered and carried in a published object's body (`preserve`, which is
    ## what saves an EIP-55 checksum, or `key`, which is what bech32's
    ## uniform-case requirement means). The shared file's `case` header says why
    ## each member answers the way it does.
    significant*: bool
    keyForm*: string
    displayForm*: string

  IdentifierShapeRule* = object
    ## One row of Search-And-Routing.md §2's shape table, machine-readable — how
    ## a member is recognised from a QUERY STRING ALONE.
    ##
    ## It is data, and in this file rather than in the client, because §5's index
    ## path carries no chain segment: a client resolving a bare query cannot use
    ## the per-chain declaration to key it, so the index keys per SHAPE, and
    ## recognition stopped being search UX and became a derivation site. Every
    ## other derivation site in this seam reads its rule from the shared file.
    row*: string
      ## The §2 row this is, quoted, so the set is reviewable against the spec.
    prefixes*: seq[string]
      ## Literal prefixes the identifier must carry, or empty for none.
    minPayload*, maxPayload*: int
      ## The payload length range, in characters of this member's own alphabet.

  IdentifierEncoding* = object
    ## One member of the closed set of encodings, as the shared file states it.
    id*: string
    shapeRows*: string
      ## The rows of Search-And-Routing.md §2's shape table this member comes
      ## from. Carried so the set's provenance is checkable by reading, in the
      ## same way `RefusalReason.condition` carries a member's.
    shapes*: seq[IdentifierShapeRule]
      ## The same rows, machine-readable. May be EMPTY, and `decimal`'s is: a
      ## bare number is answered by §3's local inference at zero requests, so
      ## recognising it as an index key would cost a fetch for an answer that
      ## needs none. Empty is a statement, not an omission.
    shardKey*: ShardKeyRule
    caseRule*: IdentifierCaseRule

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
    # EVERY MEMBER MUST DECLARE ITS ALPHABET, and the absence fails the BUILD for
    # the reason the pad's does. The index REFUSES an identifier it cannot key —
    # that refusal is the whole of the `hexToBytes` crash's replacement — and a
    # member with no alphabet is a member every identifier is writable in, which
    # turns the refusal into a no-op that reports nothing.
    let alphabet = sk{"alphabet"}.getStr
    if alphabet.len == 0:
      raise newException(ValueError,
        "identifier encoding '" & id & "' declares no alphabet. The §5 hash " &
        "index refuses an identifier that is not writable in its declared " &
        "alphabet, by name; a member with an empty alphabet would admit every " &
        "string and the refusal would never fire.")
    var seenChar: set[char]
    for c in alphabet:
      if c in seenChar:
        raise newException(ValueError,
          "identifier encoding '" & id & "' lists '" & $c & "' twice in its " &
          "alphabet. A repeated digit is an alphabet whose size is not its " &
          "cardinality, and every membership check would still pass while the " &
          "file said two things about one character.")
      seenChar.incl c
    # THE PAD MUST BE A DIGIT OF THE ALPHABET IT PADS. The per-encoding pad
    # exists because `0` is not a digit of base58, of bech32 or of base64 — a pad
    # outside the alphabet names a shard directory that no identifier could ever
    # produce, which is exactly the defect the field was added to fix, and
    # nothing checked that the fix held.
    if pad[0] notin seenChar:
      raise newException(ValueError,
        "identifier encoding '" & id & "' pads with '" & pad & "', which is " &
        "not a digit of its own alphabet (" & alphabet & "). A pad outside the " &
        "alphabet right-pads a short identifier into a shard name that no " &
        "identifier of this encoding could produce, which is the defect the " &
        "per-encoding pad was added to prevent.")
    # `== nil` FIRST: `{}` answers a nil node for an absent key and `.kind` on one
    # is a segfault, so without the short-circuit the refusal below could never be
    # reached by the very input it is written about.
    if sk{"pathSafe"} == nil or sk{"pathSafe"}.kind != JBool:
      raise newException(ValueError,
        "identifier encoding '" & id & "' does not say whether it is " &
        "pathSafe. Absent is not false: a member that forgot to answer would " &
        "be refused at every shard site as if its alphabet contained a " &
        "separator, and one that defaulted to true would publish a path " &
        "segment with a `/` in it.")
    # EVERY MEMBER MUST ALSO CARRY A CASE RULE, and the absence fails the BUILD
    # for the same reason the shard rule's does. One normalisation applied to
    # every encoding is the defect this rule exists to remove, so a member that
    # answered the question for shard payloads and not for case would be a token
    # the fold could only handle by guessing — which is the global fold again,
    # wearing a per-member set as a hat.
    let cs = e{"case"}
    if cs == nil or cs.kind != JObject:
      raise newException(ValueError,
        "identifier encoding '" & id & "' carries no case rule. Lowercasing is " &
        "the right key for hex and DESTROYS base58 and base64url, which are " &
        "case-significant; bech32 requires a uniform case rather than an " &
        "arbitrary one; and an EIP-55 hex address carries its checksum in its " &
        "case. A member that does not say which of those it is cannot be keyed.")
    if cs{"significant"} == nil or cs{"significant"}.kind != JBool:
      raise newException(ValueError,
        "identifier encoding '" & id & "' does not say whether its case is " &
        "SIGNIFICANT. Absent is not false: a member that forgot to answer would " &
        "be folded as if two spellings were one identifier, which for base58 or " &
        "base64url does not normalise an identifier — it names a different one.")
    let keyForm = cs{"keyForm"}.getStr
    if keyForm notin ["lower", "preserve"]:
      raise newException(ValueError,
        "identifier encoding '" & id & "' declares keyForm '" & keyForm &
        "', and the forms are: lower, preserve. `lower` folds an identifier " &
        "into the form it is KEYED by; `preserve` says folding it would change " &
        "which identifier it is. A token outside that pair is a normalisation " &
        "nothing in this tree implements.")
    let displayForm = cs{"displayForm"}.getStr
    if displayForm notin ["preserve", "key"]:
      raise newException(ValueError,
        "identifier encoding '" & id & "' declares displayForm '" & displayForm &
        "', and the forms are: preserve, key. `preserve` keeps the string the " &
        "chain gave us, which is what saves an EIP-55 checksum; `key` says the " &
        "display form IS the key form, which is what bech32's uniform-case " &
        "requirement means.")
    # ── THE TWO CROSS-FIELD RULES, WHICH ARE THE POINT OF SPLITTING THE FIELDS ─
    #
    # Each field is answerable on its own and the PAIR is what can be wrong, so
    # the pair is what is checked. Without these, `{significant: true, keyForm:
    # "lower"}` would be a member declaring that case carries identity and then
    # folding it away — the exact defect this rule exists to remove, stated in
    # the very file that removes it.
    if cs{"significant"}.getBool and keyForm != "preserve":
      raise newException(ValueError,
        "identifier encoding '" & id & "' says its case is significant and " &
        "then declares keyForm '" & keyForm & "'. A fold on a case-significant " &
        "alphabet is not a normalisation: it does not map two spellings of one " &
        "identifier together, it maps one identifier onto a different one that " &
        "probably does not exist. A significant member's key form is its own.")
    if displayForm == "key" and keyForm == "preserve":
      raise newException(ValueError,
        "identifier encoding '" & id & "' declares displayForm 'key' beside a " &
        "keyForm of 'preserve', which states nothing: the key form IS the " &
        "identifier, so 'the display form is the key form' and 'the display " &
        "form is preserved' are the same sentence. `key` is for a member whose " &
        "display form is FOLDED — bech32, where a mixed-case string is not an " &
        "address at all — and a rule that reads as a decision while making none " &
        "is worse than the absent one the arm above refuses.")
    # EVERY MEMBER MUST CARRY A `shapes` LIST, and an ABSENT one is not an empty
    # one. Absent means nobody answered; empty means "this member is not
    # recognised from a bare string", which is `decimal`'s deliberate answer and
    # is a different fact. A reader that treated the two alike would let a member
    # silently drop out of the client's index-key derivation.
    let shp = e{"shapes"}
    if shp == nil or shp.kind != JArray:
      raise newException(ValueError,
        "identifier encoding '" & id & "' carries no shapes list. Every member " &
        "has to say how it is recognised from a query string alone, because " &
        "Search-And-Routing.md §5's index has no chain segment and therefore " &
        "keys per SHAPE. An EMPTY list is a legal answer — `decimal` gives it, " &
        "since a number is resolved by §3's local inference at zero requests — " &
        "but an absent one is nobody having answered.")
    var shapes: seq[IdentifierShapeRule]
    for s in shp.getElems:
      let row = s{"row"}.getStr
      if row.len == 0:
        raise newException(ValueError,
          "identifier encoding '" & id & "' declares a shape with no `row`. " &
          "Every shape quotes the row of §2's table it implements, for the " &
          "reason every member names its `shapeRows`: it is what makes the set " &
          "reviewable against the spec rather than merely finite.")
      let lo = s{"minPayload"}.getInt
      let hi = s{"maxPayload"}.getInt
      if lo <= 0 or hi < lo:
        raise newException(ValueError,
          "identifier encoding '" & id & "' declares a shape with payload " &
          "range " & $lo & ".." & $hi & ", which admits nothing or admits an " &
          "empty payload. A shape that matches no string is a row of §2 this " &
          "build cannot recognise, and one that matches the empty string would " &
          "key every query at once.")
      var prefixes: seq[string]
      for pfx in s{"prefixes"}.getElems:
        let v = pfx.getStr
        if v.len == 0:
          raise newException(ValueError,
            "identifier encoding '" & id & "' declares an empty prefix in a " &
            "shape. An empty prefix matches everything, which is what an empty " &
            "PREFIX LIST already says — spelling it as a member instead makes " &
            "a rule that reads as a restriction while imposing none.")
        prefixes.add v
      shapes.add IdentifierShapeRule(row: row, prefixes: prefixes,
                                     minPayload: lo, maxPayload: hi)
    seenEncodings.add id
    result.encodings.add IdentifierEncoding(id: id, shapeRows: rows,
      shapes: shapes,
      shardKey: ShardKeyRule(stripPrefix: sk{"stripPrefix"}.getStr,
                             payloadAfterLast: sk{"payloadAfterLast"}.getStr,
                             pad: pad,
                             alphabet: alphabet,
                             pathSafe: sk{"pathSafe"}.getBool),
      caseRule: IdentifierCaseRule(significant: cs{"significant"}.getBool,
                                   keyForm: keyForm,
                                   displayForm: displayForm))
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
  MaxDistinctPayloadsPerQuery* = 2
    ## **The most distinct payloads any one query can imply over the table as
    ## DECLARED — which is the most index shards a single search can cost.**
    ##
    ## One probe per distinct payload, one request per probe, so this is
    ## Search-And-Routing §5.3's request arithmetic in one number: an ambiguous
    ## query costs this many index shards plus the data object, and every other
    ## query costs one plus the data object.
    ##
    ## **IT IS A MEASURED PROPERTY OF THE TABLE, NOT A STRUCTURAL LAW, AND THAT IS
    ## WHY IT IS DECLARED HERE RATHER THAN COMPUTED.** Computing it from
    ## `IdentifierEncodings` would make every assertion about it vacuous — a
    ## measurement compared against itself. Declared, it is a claim the sweeps in
    ## `tests/tcontract.nim` falsify or confirm, and adding a row to the shared
    ## file moves exactly one number here and one sentence in §5.3.
    ##
    ## THE BOUND IS EMPIRICAL, demonstrated rather than asserted: add a `bc1` row
    ## to `bech32` — Bitcoin segwit, a live prospect, whose human-readable part is
    ## spellable in hex because `b`, `c` and `1` are all hex digits — and
    ## `BC1` + `2`×40 implies THREE distinct payloads (hex folds it, base58
    ## preserves it, bech32 takes the part after the last `1`). Measured with the
    ## row temporarily added: the cross-alphabet sweep reports 3 while the
    ## own-alphabet generator still reports 2, because that generator fills a
    ## prefix only from its own encoding's alphabet and never varies case.
    ##
    ## So a `bc1` row is not a table edit: it is this constant, §5.3's sentence,
    ## and the family censuses that cite it — which is the whole reason the number
    ## has a name instead of being a `2` written at each site.

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

func identifierCaseRule*(encoding: string): IdentifierCaseRule =
  ## The CASE rule a token implies, from the shared file.
  ##
  ## A non-member raises, for `identifierEncodingRule`'s reason and with more
  ## force: falling back to hex here means folding a case-significant identifier
  ## into one that does not exist, and the failure would arrive as a 404 on a
  ## path the producer never wrote rather than as a refusal naming the token.
  for e in IdentifierEncodings:
    if e.id == encoding: return e.caseRule
  raise newException(ValueError,
    "'" & encoding & "' is not an identifier encoding, so there is no case " &
    "rule for it. The encodings are: " & identifierEncodingList() &
    ". Case handling is stated per member in " &
    "tools/chain/identifier-encodings.json; one normalisation applied to all of " &
    "them is the outcome that rule exists to prevent.")

func identifierKeyForm*(encoding, identifier: string): string =
  ## **The form an identifier is KEYED by**, per its encoding's declared rule.
  ##
  ## This is the one normalisation this tree performs on a chain's identifier,
  ## and it is a normalisation rather than a fold: `hex` and `bech32` lower,
  ## because two spellings are one identifier there; `base58`, `base64`,
  ## `base64url` and `ss58` preserve, because two spellings are two identifiers;
  ## `decimal` preserves because it has no letters. It touches nothing else — no
  ## prefix strip, no re-encoding — so it is idempotent and safe to apply to a
  ## value that is already a key form, which several call sites rely on.
  ##
  ## WHERE THE RESULT IS PUBLISHED: every path segment and every index key.
  ## `/d/{chain}/tx/{shard}/{id}.json` — both segments — the §5 shard file name,
  ## and the route `/{chain}/{kind}/{id}/`. One identifier names one object,
  ## whichever spelling a caller arrived with.
  let rule = identifierCaseRule(encoding)
  case rule.keyForm
  of "lower": identifier.toLowerAscii
  of "preserve": identifier
  else:
    # Unreachable: `parseIdentifierEncodings` refuses any other token at compile
    # time. Stated rather than defaulted, because a `case` whose fallthrough
    # silently preserved would turn a future member's unimplemented form into
    # "no normalisation" — which for hex is the bug this function replaced.
    raise newException(ValueError,
      "identifier encoding '" & encoding & "' declares keyForm '" &
      rule.keyForm & "', which the reader admitted and this function does not " &
      "implement. The two have to be widened together.")

func identifierDisplayForm*(encoding, identifier: string): string =
  ## **The form an identifier is SHOWN in**, per its encoding's declared rule —
  ## and, where they differ, deliberately not the key form.
  ##
  ## For `hex` this PRESERVES, and that is the whole reason the two forms are
  ## separate: an EIP-55 address carries its checksum in the case of its letters,
  ## so the display form and the key form of one address are two different
  ## strings and a fold applied to both loses the checksum a reader could have
  ## checked a mistyped address against. For `bech32` and `bech32m` it folds,
  ## because BIP-173 makes a MIXED-case string invalid outright: there is no
  ## third, mixed spelling worth preserving — it would not be an address.
  ##
  ## WHERE THE RESULT IS PUBLISHED: the identifier a published object carries in
  ## its BODY (`id.hash` on transaction facts, `address` on an address index,
  ## `hash` on a block), and therefore what a page renders. `validator.nim`
  ## checks both statements against every tree it validates.
  let rule = identifierCaseRule(encoding)
  case rule.displayForm
  of "preserve": identifier
  of "key": identifierKeyForm(encoding, identifier)
  else:
    raise newException(ValueError,
      "identifier encoding '" & encoding & "' declares displayForm '" &
      rule.displayForm & "', which the reader admitted and this function does " &
      "not implement. The two have to be widened together.")

func identifierPayload*(encoding, identifier: string): string =
  ## The identifier's PAYLOAD in its own alphabet, in key form: the declared case
  ## rule applied, the declared prefix stripped IF PRESENT, and everything up to
  ## and including the declared separator's last occurrence removed.
  ##
  ## The one place those three steps are composed, and the order is load-bearing:
  ## case first, so that a `0X`-prefixed hex identifier — the same account,
  ## written by a tool that shouted — has its prefix recognised and stripped
  ## rather than carried into the shard key as payload.
  ##
  ## `contract/shards.nim` pads and slices this; `contract/hashshard.nim` reads
  ## it for the §5 shard key and for the hex-pair parser that is the index's
  ## remaining hex assumption. Both used to do the three steps themselves, and
  ## the hash index's copy folded case for every encoding because it could not
  ## see one.
  let rule = identifierEncodingRule(encoding)
  result = identifierKeyForm(encoding, identifier)
  if rule.stripPrefix.len > 0 and result.startsWith(rule.stripPrefix):
    result = result[rule.stripPrefix.len .. ^1]
  if rule.payloadAfterLast.len > 0:
    let i = result.rfind(rule.payloadAfterLast)
    if i >= 0: result = result[i + rule.payloadAfterLast.len .. ^1]

func matchesShape(rule: IdentifierShapeRule, enc: IdentifierEncoding,
                  identifier, payload: string): bool =
  ## Does one §2 row admit this string? Prefix, then payload length, then
  ## alphabet — in that order, because the prefix is what tells the later two
  ## which part of the string is payload at all.
  if rule.prefixes.len > 0:
    var carried = false
    for p in rule.prefixes:
      if identifier.startsWith(p): carried = true; break
    if not carried: return false
  if payload.len < rule.minPayload or payload.len > rule.maxPayload:
    return false
  for c in payload:
    if c notin enc.shardKey.alphabet: return false
  true

func identifierEncodingsMatching*(identifier: string): seq[string] =
  ## **Every encoding a bare query string could be written in** — the client's
  ## half of the §5 index key, derived from the string ALONE.
  ##
  ## ## Why this exists, and why it is not `parseChainIdentifierEncoding`
  ##
  ## §5's index path is `/idx/hash/{version}/{prefix}.bin` and carries NO CHAIN
  ## SEGMENT — that is precisely what makes "two requests to resolve any hash on
  ## any chain" true. A client resolving a bare query therefore does not yet know
  ## which chain it will hit and cannot read that chain's declaration. What it
  ## can do is read the query's SHAPE, which is what §2's table is for, and that
  ## is derivable from the string with no tree, no registry and no request.
  ##
  ## The PRODUCER keys by the chain's declared encoding; the CLIENT keys by each
  ## shape its query matches. They meet because both slice the same
  ## `identifierPayload`, so the shard the producer wrote is a shard the client
  ## computes.
  ##
  ## ## Several matches are normal and §2 says so
  ##
  ## "A single input may match several shapes; all matches are carried forward."
  ## A 44-character base58 string is also a valid base64 string and §2 lists
  ## both. Where those readings share a payload they share a shard and cost one
  ## request; **WHERE THEY DO NOT, THEY ARE TWO SHARDS**, and the caller has to
  ## fetch both. This comment used to say they always shared one — "a property of
  ## the current table rather than a theorem" — and it was false of the table it
  ## was describing: `addr1` + 38 `q`s is admissible as base58 (whole string) and
  ## as bech32 (after the last `1`). `indexProbesOf` is the consumption rule that
  ## does not need the claim; Search-And-Routing §5.6 carries the census.
  ##
  ## Members are returned in the shared file's order, deduplicated, and a member
  ## with no shapes (`decimal`) is never returned: a number is §3's local
  ## inference at zero requests, not an index lookup.
  ##
  ## **THE ORDER IS A FACT ABOUT A JSON ARRAY AND CARRIES NO PRECEDENCE.** It is
  ## stable so that output is deterministic, and that is all it is for. A caller
  ## that treats the first element as the answer has made the shared file's sort
  ## order load-bearing, which is the second half of the defect §5.6 records.
  if identifier.len == 0: return
  for e in IdentifierEncodings:
    if e.shapes.len == 0: continue
    let payload = identifierPayload(e.id, identifier)
    if payload.len == 0: continue
    # A DECLARED SEPARATOR THAT IS ABSENT IS NOT A MATCH. Without this,
    # `identifierPayload` returns the whole string when the separator does not
    # occur, and any all-data-charset string would match bech32 — keying it in a
    # shard no correctly-formed address of that chain is in.
    if e.shardKey.payloadAfterLast.len > 0 and
       not identifierKeyForm(e.id, identifier).contains(e.shardKey.payloadAfterLast):
      continue
    for rule in e.shapes:
      if rule.matchesShape(e, identifierKeyForm(e.id, identifier), payload):
        result.add e.id
        break

func identifierIndexKey*(encoding, identifier: string): string =
  ## **The form the §5 hash index STORES and keys an identifier by** — its key
  ## form, checked against its declared alphabet, or a REFUSAL THAT NAMES THE
  ## PROBLEM.
  ##
  ## ## Why this exists at all, and what it replaced
  ##
  ## `contract/hashshard.nim` used to hold a `hexToBytes` that parsed the
  ## identifier as HEX PAIRS with `parseHexInt`. Two things were wrong with it
  ## and they are different in kind. It could not represent a base58 or bech32
  ## identifier at all — there are no hex pairs in `addr1qxy…` — so four of the
  ## eight members of the closed set had no entry in the global index. And on
  ## anything it could not parse it did not refuse: `parseHexInt` raises an
  ## UNHANDLED `ValueError`, so the producer DIED. Measured: with `hex`'s
  ## `stripPrefix` emptied, the demo producer stopped on
  ## `parseHexInt: invalid hex integer: 0x` — a stack trace naming a string
  ## function, from which nothing says which identifier, which chain, which
  ## encoding, or that an encoding was even involved.
  ##
  ## **So the replacement refuses BY NAME.** It says the encoding token, the
  ## identifier, the offending character and its position, and the alphabet that
  ## admits characters — which is the difference between a crash a reader has to
  ## reproduce under a debugger and a message that contains its own diagnosis.
  ##
  ## ## Why it returns the KEY FORM and not the payload
  ##
  ## The index keys by the payload — that is `hashPrefix`'s job, and it is the
  ## shard key. But a shard ENTRY has to be able to name a route, and the payload
  ## cannot: `bech32`'s payload begins after the last `1`, so `addr1qxy…`'s
  ## payload is `qxy…` and the human-readable part is GONE. An entry storing only
  ## the payload would resolve a Cardano address to `/cardano/address/qxy…/`,
  ## which is not an address and not a page. So the entry stores the whole key
  ## form and the SHARD KEY is derived from it, which is one derivation rather
  ## than two stored fields that could disagree.
  ##
  ## ## What it does not do
  ##
  ## It does not validate a checksum — not EIP-55's, not bech32's, not SS58's
  ## blake2b. The shared file's closing section says why that is deliberately out
  ## of scope: it needs hash functions `contract/` does not have and the JS
  ## backend would have to grow. The claim here is the weaker, checkable one —
  ## that every character is a digit of the alphabet the chain declared — which
  ## is exactly enough to key an identifier and to refuse one that cannot be.
  let rule = identifierEncodingRule(encoding)
  result = identifierKeyForm(encoding, identifier)
  if result.len == 0:
    raise newException(ValueError,
      "an empty identifier cannot be keyed in the §5 hash index (encoding '" &
      encoding & "'). An empty key would shard to the pad character and claim " &
      "a route with no identifier in it, which is a hit that navigates nowhere.")
  # ── WHAT THE ALPHABET DESCRIBES IS THE PAYLOAD, AND ONLY THE PAYLOAD ────────
  #
  # Not the whole identifier, and the difference is `bech32`. A bech32 string is
  # `<hrp>1<data>` and the declared alphabet is BIP-173's DATA charset, which
  # excludes `1` precisely so the separator is unambiguous — so checking the
  # whole of `addr1qxy…` against it would refuse every valid Cardano address at
  # its own separator. `hex`'s `0x` is the same shape of problem one step
  # smaller. Both are already answered by the two fields that say where the
  # payload begins, so the check runs on what they return.
  let payload = identifierPayload(encoding, identifier)
  # A DECLARED SEPARATOR THAT IS ABSENT IS A REFUSAL AND NOT A WHOLE-STRING
  # PAYLOAD. `identifierPayload` leaves the string alone when the separator does
  # not occur, which is right for a slice and wrong for a key: `addrqxy…` would
  # then key as if the hrp were data, land in a different shard from every other
  # address on its chain, and resolve to nothing.
  if rule.payloadAfterLast.len > 0 and not result.contains(rule.payloadAfterLast):
    raise newException(ValueError,
      "'" & identifier & "' carries no '" & rule.payloadAfterLast &
      "' separator, and identifier encoding '" & encoding & "' places its " &
      "payload after the last one. Keying the whole string instead would put " &
      "it in a different shard from every correctly-formed identifier on its " &
      "chain, and resolve to nothing; refusing says so.")
  if payload.len == 0:
    raise newException(ValueError,
      "'" & identifier & "' has an empty payload under identifier encoding '" &
      encoding & "', so there is nothing for the §5 hash index to key it by.")
  for i, c in payload:
    if c notin rule.alphabet:
      raise newException(ValueError,
        "'" & identifier & "' is not writable in identifier encoding '" &
        encoding & "': character '" & $c & "' at position " & $i &
        " of its payload ('" & payload & "') is not one of that encoding's " &
        "digits (" & rule.alphabet & "). The §5 hash index refuses it rather " &
        "than storing a key nothing can recompute — an entry keyed from a " &
        "string the alphabet does not admit is a hit that navigates to a 404, " &
        "which is the one outcome Search-And-Routing.md §5 forbids outright. " &
        "If the identifier is right, the chain's registry row declares the " &
        "wrong encoding for its kind.")

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

func identifierKeyForm*(d: ChainIdentifierEncoding, kind, identifier: string):
    string =
  ## The key form reached through one chain's declaration — the form every path
  ## site uses, because a path site knows which KIND of identifier it is placing
  ## and the chain's row is what says how that kind is written.
  ##
  ## `encodingFor` raises on a kind this chain omitted, which is the point: a
  ## normalised key for an identifier the registry declined to describe is a key
  ## nobody can recompute.
  identifierKeyForm(d.encodingFor(kind), identifier)

func identifierDisplayForm*(d: ChainIdentifierEncoding,
                            kind, identifier: string): string =
  ## The display form reached through one chain's declaration. Same rule as
  ## above: the kind selects the token and the token selects the rule.
  identifierDisplayForm(d.encodingFor(kind), identifier)

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
  ## MEASURED, NOT ASSUMED — and THE DEFINITION IS PART OF THE MEASUREMENT,
  ## because two different trees in this repository are called "the testnet
  ## capture" and they differ by a factor of twenty-three. A count quoted without
  ## its definition is a number that reproduces for whoever wrote it and for
  ## nobody else; this one was quoted as "386 in the testnet capture" and a review
  ## re-derived 9,000 from the other tree and recorded it as irreproducible.
  ##
  ## THE DEFINITION: distinct literals matching `0x[0-9a-fA-F]+`, over every file
  ## in the named directory. Under it, and re-derivable per directory:
  ##
  ##   * `fixtures/chain-artifacts/aztec-testnet/` (the artifact capture, 17
  ##     files) — **386**
  ##   * `tests/fixtures/chain-snapshots/aztec-mainnet-live/` — **990**
  ##   * `client/fixtures/chain/aztec/` — **8,006**
  ##   * `client/fixtures/chain/aztec-testnet/` — **9,071** (its `snapshot.json`
  ##     alone is 9,000, which is the figure the review re-derived)
  ##   * `client/fixtures/chain/aztec-testnet-frames/` — **201**
  ##
  ## THE LOAD-BEARING HALF REPRODUCES EVERYWHERE and is what the `hex` declaration
  ## rests on: in all five, **zero** `0x` literals in an identifier position carry
  ## an uppercase hex digit. The only uppercase `0x` literals in the corpus at all
  ## are three copies of `0xFFFFFFFF` inside published Noir SOURCE TEXT — a
  ## numeric literal in a program, not an identifier, and not a path segment.
  ##
  ## Exactly two lengths occur among the identifiers and both are hex: 66 (`0x` +
  ## 64, the field elements, which is every identifier of the three declared kinds)
  ## and 42 (`0x` + 40 — `coinbase` and `rollupAddress`, which are L1 addresses
  ## carried as block metadata and are not path segments, so no kind declares
  ## them). The demo generator's synthetic addresses are `0x` + 40 lowercase hex
  ## (`synthAddr`).
  ##
  ## So for the kinds this declaration speaks about there is no EIP-55 checksum
  ## riding in the case — they are field elements, not 20-byte accounts — and the
  ## display-form-versus-key-form split that per-encoding case handling makes is a
  ## no-op on this chain: `identifierKeyForm` and `identifierDisplayForm` return
  ## the same string for every identifier either producer publishes, which is why
  ## the whole step landed with the published layout diffed byte-for-byte. Note that the argument is about the field
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
