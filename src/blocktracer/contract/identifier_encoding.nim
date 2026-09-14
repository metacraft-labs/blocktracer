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
## **One site still derives from the string, and it is the last and most
## expensive step.** The hash index (`contract/hashshard.nim`) still PARSES HEX
## PAIRS in `hexToBytes`, so a base58 or bech32 identifier has no representation
## in it at all. It is a published, self-describing wire format, so widening it
## is a migration of every published shard plus a compatibility window. What that
## module no longer does is decide case for itself: its key encoding is the named
## constant `HashIndexEncoding` and its fold comes from the `case` rule here, so
## the remaining assumption is one greppable token rather than a `toLowerAscii`
## nobody could see. It is `hex` because §5's index path carries no chain
## segment — a client resolving a bare query does not yet know which chain it
## will hit — so that index's key rule has to be global in a way a per-chain
## declaration cannot be, and choosing the chain-agnostic canonical form is the
## migration's own decision rather than a fold this step may quietly make.
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

  IdentifierEncoding* = object
    ## One member of the closed set of encodings, as the shared file states it.
    id*: string
    shapeRows*: string
      ## The rows of Search-And-Routing.md §2's shape table this member comes
      ## from. Carried so the set's provenance is checkable by reading, in the
      ## same way `RefusalReason.condition` carries a member's.
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
    if sk{"pathSafe"}.kind != JBool:
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
    if cs{"significant"}.kind != JBool:
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
    seenEncodings.add id
    result.encodings.add IdentifierEncoding(id: id, shapeRows: rows,
      shardKey: ShardKeyRule(stripPrefix: sk{"stripPrefix"}.getStr,
                             payloadAfterLast: sk{"payloadAfterLast"}.getStr,
                             pad: pad,
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
