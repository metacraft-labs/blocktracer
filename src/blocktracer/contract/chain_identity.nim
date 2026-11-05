## contract/chain_identity.nim
##
## The registry's per-chain **identity** — what a chain IS, as a visitor and a
## wallet name it: its CAIP-2 id, its display name, its family, its native
## currency, its nominal block time and how its blocks become final.
##
## Configuration.md §2.1 specified these six members from the start and nothing
## wrote them; Chain-Support-Matrix.md §5's checklist makes them the first item
## of adding a chain. They are written now, by the route `vm` took: the PRODUCER
## declares them (`provenance.identity`, Data-Contract.md §5.3), the ingest
## carries them onto the registry row, and every reader parses the row with the
## one function below. The reader states no fact about a chain on a producer's
## behalf, and that includes its name.
##
## ## Each member is optional, and each is checked on its own
##
## §2.2's additive rule, applied per member: a producer that can state the CAIP-2
## id and not the block time publishes the one and omits the other, and a
## consumer meeting a row without either answers exactly as it did before they
## existed. A member PRESENT in a shape this contract does not accept is a
## different fact from an absent one, so it earns a refusal sentence and is not
## read — the `chain_profile` arrangement, for its reason.
##
## ## Nothing here raises
##
## For `chain_profile`'s reason: the validator collects refusals into a list,
## the client's view model is on a render path, and the ingest — which must
## refuse a malformed declaration outright — raises from the list itself.
##
## ## The finality rule is a closed set, and is a data file
##
## A producer declares it in JavaScript and three readers parse it here, so the
## set lives in `tools/chain/finality-rules.json`, read with `staticRead` — the
## arrangement `identifier_encoding` and `refusal_reasons` have, for the reason
## their headers give. The family is OPEN, for `vm`'s reason: the set of chain
## families is open and a consumer only needs the token to name one.

import std/[json, strutils]

const finalityRulesJson = staticRead("../../../tools/chain/finality-rules.json")

const FinalityRulesFormat* = "blocktracer/finality-rules@1"

type
  FinalityRule* = object
    ## One member of the closed set, exactly as the shared file states it.
    id*: string
    label*: string   ## the sentence a chain page states
    means*: string   ## the definition a producer picks a member by

  ChainIdentity* = object
    ## The members a row stated in an accepted shape. A string member is empty
    ## and a number is zero when the row did not state it; `blockTimeMs` of zero
    ## is therefore "unstated" and never a claim, because no chain has one.
    caip2*: string
    name*: string
    family*: string
    currencySymbol*: string
    currencyDecimals*: int
    currencyStated*: bool
      ## `decimals` of 0 is a legal currency, so the pair carries its own flag.
    blockTimeMs*: int
    finalityRule*: string
    refusals*: seq[string]
      ## One sentence per member present in a shape this contract refuses.

const
  Caip2Member* = "caip2"
  NameMember* = "name"
  FamilyMember* = "family"
  NativeCurrencyMember* = "nativeCurrency"
  BlockTimeMember* = "blockTimeMs"
  FinalityMember* = "finality"
  SymbolMember* = "symbol"
  DecimalsMember* = "decimals"
  RuleMember* = "rule"
  IdentityMembers* = [Caip2Member, NameMember, FamilyMember,
                      NativeCurrencyMember, BlockTimeMember, FinalityMember]

proc parseFinalityRules(): seq[FinalityRule] =
  let doc = parseJson(finalityRulesJson)
  if doc{"format"}.getStr != FinalityRulesFormat:
    raise newException(ValueError,
      "tools/chain/finality-rules.json declares format '" & doc{"format"}.getStr &
      "', and this module only knows " & FinalityRulesFormat &
      ". A half-read closed set is an open one.")
  for r in doc{"rules"}.getElems:
    let id = r{"id"}.getStr
    let label = r{"label"}.getStr
    let means = r{"means"}.getStr
    if id.len == 0 or label.len == 0 or means.len == 0:
      raise newException(ValueError,
        "tools/chain/finality-rules.json has a member missing its id, label or " &
        "means. Every member says what it is called, what a page says and what " &
        "it means; that is what makes the set reviewable rather than merely finite.")
    result.add FinalityRule(id: id, label: label, means: means)
  if result.len == 0:
    raise newException(ValueError,
      "tools/chain/finality-rules.json defines no rules. An empty closed set " &
      "would refuse every declaration.")

const FinalityRules* = parseFinalityRules()

func finalityRuleList*(): string =
  ## Every member id, comma-separated, in file order.
  var parts: seq[string]
  for r in FinalityRules: parts.add r.id
  parts.join(", ")

func finalityLabel*(id: string): string =
  ## The page sentence for `id`, or `""` for a token outside the set.
  for r in FinalityRules:
    if r.id == id: return r.label
  ""

func isCaip2*(s: string): bool =
  ## CAIP-2's grammar: `namespace:reference`, namespace `[-a-z0-9]{3,8}`,
  ## reference `[-_a-zA-Z0-9]{1,32}`.
  let i = s.find(':')
  if i < 0: return false
  let ns = s[0 ..< i]
  let rf = s[i + 1 .. ^1]
  if ns.len < 3 or ns.len > 8 or rf.len < 1 or rf.len > 32: return false
  for c in ns:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  for c in rf:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: return false
  true

func isFamilyToken(s: string): bool =
  if s.len == 0 or s[0] notin {'a'..'z', '0'..'9'}: return false
  for c in s:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  true

func parseChainIdentity*(n: JsonNode): ChainIdentity =
  ## The identity members of `n`, which is a registry ROW or a snapshot's
  ## `provenance.identity` — the same members in the same shapes, so one parse
  ## serves the declaration and the row it becomes, and they cannot be read two
  ## ways. Anything that is not an object states nothing.
  if n == nil or n.kind != JObject: return
  let c = n{Caip2Member}
  if c != nil:
    if c.kind == JString and isCaip2(c.getStr): result.caip2 = c.getStr
    else:
      result.refusals.add "`" & Caip2Member & "` is " & $c & ", which is not a " &
        "CAIP-2 chain id (`namespace:reference`, e.g. `eip155:1`, `sui:mainnet`). " &
        "A chain id a wallet cannot parse identifies nothing"
  let nm = n{NameMember}
  if nm != nil:
    if nm.kind == JString and nm.getStr.strip.len > 0: result.name = nm.getStr.strip
    else:
      result.refusals.add "`" & NameMember & "` must be a non-empty string; this " &
        "row carries " & $nm
  let f = n{FamilyMember}
  if f != nil:
    if f.kind == JString and isFamilyToken(f.getStr): result.family = f.getStr
    else:
      result.refusals.add "`" & FamilyMember & "` is " & $f & ". A family is one " &
        "lowercase token (`evm`, `move`, `svm`), because a consumer compares it"
  let cur = n{NativeCurrencyMember}
  if cur != nil:
    let sym = cur{SymbolMember}
    let dec = cur{DecimalsMember}
    if cur.kind == JObject and sym != nil and sym.kind == JString and
        sym.getStr.strip.len > 0 and dec != nil and dec.kind == JInt and
        dec.getInt in 0 .. 255:
      result.currencySymbol = sym.getStr.strip
      result.currencyDecimals = dec.getInt
      result.currencyStated = true
    else:
      result.refusals.add "`" & NativeCurrencyMember & "` must be `{\"" &
        SymbolMember & "\": \"…\", \"" & DecimalsMember & "\": N}` with N in " &
        "0..255; this row carries " & $cur & ". A symbol without its decimals " &
        "cannot scale an amount, so the pair is stated together or not at all"
  let bt = n{BlockTimeMember}
  if bt != nil:
    if bt.kind == JInt and bt.getInt > 0: result.blockTimeMs = bt.getInt
    else:
      result.refusals.add "`" & BlockTimeMember & "` must be a positive integer " &
        "number of milliseconds; this row carries " & $bt
  let fin = n{FinalityMember}
  if fin != nil:
    let r = fin{RuleMember}
    if fin.kind == JObject and r != nil and r.kind == JString and
        finalityLabel(r.getStr).len > 0:
      result.finalityRule = r.getStr
    else:
      let said = if fin.kind == JObject and r != nil: $r else: $fin
      result.refusals.add "`" & FinalityMember & "." & RuleMember & "` is " & said &
        ", which is not one of tools/chain/finality-rules.json's members (" &
        finalityRuleList() & "). A chain whose blocks become final some other " &
        "way is a gap in that table: add a member saying what it means"

func stated*(id: ChainIdentity): bool =
  ## Whether the row stated any identity member in an accepted shape.
  id.caip2.len > 0 or id.name.len > 0 or id.family.len > 0 or
    id.currencyStated or id.blockTimeMs > 0 or id.finalityRule.len > 0

func chainIdentityNode*(id: ChainIdentity): JsonNode =
  ## The stated members as registry row members — only what was stated, for
  ## `chainProfileNode`'s reason.
  result = newJObject()
  if id.caip2.len > 0: result[Caip2Member] = %id.caip2
  if id.name.len > 0: result[NameMember] = %id.name
  if id.family.len > 0: result[FamilyMember] = %id.family
  if id.currencyStated:
    result[NativeCurrencyMember] = %*{SymbolMember: id.currencySymbol,
                                      DecimalsMember: id.currencyDecimals}
  if id.blockTimeMs > 0: result[BlockTimeMember] = %id.blockTimeMs
  if id.finalityRule.len > 0:
    result[FinalityMember] = %*{RuleMember: id.finalityRule}
