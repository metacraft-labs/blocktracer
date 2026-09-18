## contract/chain_profile.nim
##
## The registry's per-chain **profile** — three facts about a chain that its
## consumers already ask for and that no producer used to state:
##
##   * how far back its history reaches, and where the boundary is
##     (Chain-Support-Matrix.md §1.3);
##   * which quantity sequences its transactions
##     (Static-Site-Architecture.md §2.3's ordering union);
##   * which instruction set its recordings are written against, so a mnemonic
##     table is SELECTED by identity instead of being unlocked by a string
##     comparison.
##
## Configuration.md §2.1 is the schema and §2.2 the additive rule that makes
## writing them safe: every member here is optional, and a consumer built for a
## registry without them reads one carrying them and answers identically.
##
## ## Why one module for three members
##
## Because two of them are the same fact split in half, and splitting them is
## the whole point. §1.3's reach vocabulary is CATEGORICAL — `archive`,
## `floor(B)`, `windowed(N)`, `version-addressed`, `self-contained`,
## `recent-only` — and exactly two of its six carry a parameter INSIDE the
## token. `historyFloor` is that parameter and nothing else. Published as one
## string a consumer would have to parse `floor(632813)` to use it, and a parsed
## registry value is the drift this module exists to stop. So the token is
## published bare, the number is published as data beside it, and the two are
## checked against each other in one function that every consumer calls
## (`profileConsistency`).
##
## The third member is here rather than in a module of its own because all three
## are read out of the same row by the same readers, and a row parsed in three
## places is three places that can come to disagree about what an absent member
## means.
##
## ## Nothing here raises
##
## Every parse answers with a value, and an input this contract does not accept
## produces a REFUSAL SENTENCE on that value rather than an exception. Two
## consumers need it that way for opposite reasons: the validator wants to
## collect the refusal into its list beside every other finding, and the client's
## view model is on a render path where a throw would take out a page. One
## predicate, two consumers — `validator.nim` reports what
## `chain_registry_vm.nim` displays, and neither restates the rule.
##
## A refusal names what it found, prints THE WHOLE SET, and states the remedy.
## That shape is not decoration: a reader who meets `unknown ordering kind` and
## no set has to go find the set, and the set is the answer.
##
## ## The ordering kind's closed set is `TxOrderKind`, and is not a data file
##
## `chain/refusal_reasons.nim`, `chain/snapshot_format.nim` and
## `contract/identifier_encoding.nim` all read their closed sets out of
## `tools/chain/*.json`, because each of those sets has a JavaScript consumer
## and a set closed in one language and open in the other is not closed. This one
## does not: no tool under `tools/` declares, derives or reads a transaction
## ordering kind, and the set already exists in this repository as the
## discriminated union the client decodes every transaction with
## (`contract/model.TxOrderKind`). A second spelling in a data file would be a
## second place for §2.3's union to drift from itself, which is exactly the
## failure the union exists to prevent. So the set is the enum, the refusal
## message is GENERATED from the enum, and a member added to §2.3's union is a
## member here with nobody remembering to copy it.

import std/[json, strutils]

import ./model

type
  ReachKind* = enum
    ## Chain-Support-Matrix.md §1.3's six, as BARE tokens.
    ##
    ## `floor` and `windowed` are spelled without their parameter on purpose.
    ## §1.3 writes them `floor(B)` and `windowed(N)` and that notation is PROSE:
    ## a registry string `"floor(632813)"` has to be parsed before it can be
    ## compared with anything, and the number is already published, as data, in
    ## `historyFloor`.
    rkArchive = "archive"
    rkFloor = "floor"
    rkWindowed = "windowed"
    rkVersionAddressed = "version-addressed"
    rkSelfContained = "self-contained"
    rkRecentOnly = "recent-only"

  DeclarationState* = enum
    ## Three states, because a row that said nothing and a row that said
    ## something this build does not recognise are different facts and must not
    ## render the same. The first is the compatibility case — a tree published
    ## before the member existed — and the second is a producer this build
    ## cannot read, which a consumer has to treat conservatively.
    dsAbsent = "absent"
    dsDeclared = "declared"
    dsUnrecognised = "unrecognised"

  ChainReach* = object
    state*: DeclarationState
    kind*: ReachKind          ## meaningful only when `state == dsDeclared`
    token*: string            ## what the row actually said, verbatim
    refusal*: string          ## empty unless `state == dsUnrecognised`

  ChainOrdering* = object
    state*: DeclarationState
    kind*: TxOrderKind        ## meaningful only when `state == dsDeclared`
    token*: string
    refusal*: string

  ChainHistoryFloor* = object
    ## The lowest position for which this chain's prestate is obtainable.
    stated*: bool
      ## Whether the row said anything at all. `false` is NOT "zero" — a floor
      ## of zero is a chain reachable to genesis, and "nobody said" is not that.
    height*: int
    reason*: string
      ## The producer's own words. Empty when it supplied none.
    refusal*: string
      ## Non-empty when the member is PRESENT in a shape this contract does not
      ## accept, which is a different fact from absence and must not read as one.

  ChainVmIdentity* = object
    ## Which instruction set this chain's recordings are written against.
    ##
    ## The token is the recording's own (`instructions.json`'s `isa`), carried
    ## up to the chain by a producer that saw every listing it published agree.
    ## It is NOT drawn from a closed set here, and that is deliberate: the set of
    ## instruction sets in the world is open, a producer must be able to state
    ## one this build has never heard of, and the closed thing is the set of
    ## TABLES a consumer holds — where an identity with no table simply yields
    ## opcode numbers, which is already the honest answer.
    stated*: bool
    instructionSet*: string

  ChainProfile* = object
    reach*: ChainReach
    floor*: ChainHistoryFloor
    ordering*: ChainOrdering
    vm*: ChainVmIdentity

const
  ReachMember* = "reach"
  FloorMember* = "historyFloor"
  OrderingMember* = "ordering"
  VmMember* = "vm"
  InstructionSetMember* = "instructionSet"
  KindMember* = "kind"
  HeightMember* = "height"
  ReasonMember* = "reason"

func reachKindList*(): string =
  ## Every member of §1.3's vocabulary, comma-separated, generated from the enum
  ## so a member added there appears here without an edit.
  var parts: seq[string]
  for k in ReachKind: parts.add $k
  parts.join(", ")

func orderingKindList*(): string =
  ## Every member of §2.3's ordering union, generated from the union itself.
  var parts: seq[string]
  for k in TxOrderKind: parts.add $k
  parts.join(", ")

func parameterisedTokenHint(token: string): string =
  ## The one wrong answer worth naming outright, because §1.3's own table is
  ## written in the notation that produces it.
  if "(" in token:
    " §1.3 writes this vocabulary `floor(B)` and `windowed(N)`; that is prose " &
    "notation and never a registry token. Publish the bare token here and the " &
    "number in `" & FloorMember & "`."
  else: ""

func parseReach*(n: JsonNode): ChainReach =
  ## The `reach` member, or `dsAbsent`.
  if n == nil or n.kind == JNull: return ChainReach(state: dsAbsent)
  if n.kind != JString:
    return ChainReach(state: dsUnrecognised, token: $n,
      refusal: "`" & ReachMember & "` must be one bare token from " &
        "Chain-Support-Matrix.md §1.3 (" & reachKindList() & "); this row " &
        "carries a " & $n.kind & " instead")
  let token = n.getStr
  for k in ReachKind:
    if $k == token: return ChainReach(state: dsDeclared, kind: k, token: token)
  ChainReach(state: dsUnrecognised, token: token,
    refusal: "`" & ReachMember & "` is '" & token & "', which is not one of " &
      "Chain-Support-Matrix.md §1.3's six (" & reachKindList() & "). An " &
      "unlisted reach is a gap in that table, not a free-text field: add a row " &
      "there saying what it means." & parameterisedTokenHint(token))

func parseOrdering*(n: JsonNode): ChainOrdering =
  ## The `ordering` member, or `dsAbsent`.
  ##
  ## The shape is `{"kind": "<token>"}` and not a bare string, because that is
  ## how Static-Site-Architecture.md §2.3 writes every one of its unions: the
  ## `kind` is the discriminant and the variant's own fields sit beside it. A
  ## chain that orders by logical time has an account and a counter to state one
  ## day; a bare string would have to grow into an object to say so.
  if n == nil or n.kind == JNull: return ChainOrdering(state: dsAbsent)
  if n.kind != JObject:
    return ChainOrdering(state: dsUnrecognised, token: $n,
      refusal: "`" & OrderingMember & "` must be an object carrying a `" &
        KindMember & "` from Static-Site-Architecture.md §2.3's ordering union " &
        "(" & orderingKindList() & "); this row carries a " & $n.kind)
  let kn = n{KindMember}
  if kn == nil or kn.kind != JString or kn.getStr.len == 0:
    return ChainOrdering(state: dsUnrecognised, token: "",
      refusal: "`" & OrderingMember & "` carries no `" & KindMember & "`. " &
        "Every union in Static-Site-Architecture.md §2.3 carries its own kind, " &
        "so that a consumer meeting an unfamiliar variant can say it does not " &
        "understand this chain instead of guessing. One of: " &
        orderingKindList())
  let token = kn.getStr
  for k in TxOrderKind:
    if $k == token:
      return ChainOrdering(state: dsDeclared, kind: k, token: token)
  ChainOrdering(state: dsUnrecognised, token: token,
    refusal: "`" & OrderingMember & "." & KindMember & "` is '" & token &
      "', which is not one of Static-Site-Architecture.md §2.3's ordering " &
      "union (" & orderingKindList() & "). The union is closed because a " &
      "consumer that met an unknown ordering would have to guess whether a " &
      "height means anything on this chain; adding a member is an amendment to " &
      "§2.3, not a new string in a registry." & parameterisedTokenHint(token))

func parseHistoryFloor*(n: JsonNode): ChainHistoryFloor =
  ## The `historyFloor` member, in the ONE shape this contract accepts.
  ##
  ## ## Why a bare integer is refused rather than accepted
  ##
  ## The consumer used to accept both `42` and `{"height": 42}`, on the reading
  ## that a field with no normative schema should not be made brittle by a
  ## consumer guessing one of two spellings. That was right while nothing wrote
  ## one. It stops being right the moment a producer does: two spellings of one
  ## fact is the drift this whole member was added to remove, and one of them
  ## has to win. The object wins because it is the only one of the two with
  ## anywhere to put the producer's reason — and a floor a page states without
  ## saying why is a refusal a visitor cannot act on.
  ##
  ## Nothing has ever published the bare form (no producer in this repository
  ## wrote a floor at all until it was specified), so no published tree moves.
  ## It is refused BY NAME rather than ignored, because a row that says `42`
  ## has said something and treating it as silence would report the chain as
  ## having no floor while its registry states one.
  if n == nil or n.kind == JNull: return ChainHistoryFloor()
  if n.kind == JInt:
    return ChainHistoryFloor(refusal:
      "`" & FloorMember & "` is a bare integer. The accepted shape is `{\"" &
      HeightMember & "\": N, \"" & ReasonMember & "\": \"…\"}` — one spelling, " &
      "because two spellings of one fact drift, and the object is the one with " &
      "room for the producer's own words (Configuration.md §2.1)")
  if n.kind != JObject:
    return ChainHistoryFloor(refusal:
      "`" & FloorMember & "` must be `{\"" & HeightMember & "\": N, \"" &
      ReasonMember & "\": \"…\"}`; this row carries a " & $n.kind)
  let h = n{HeightMember}
  if h == nil or h.kind != JInt:
    return ChainHistoryFloor(refusal:
      "`" & FloorMember & "` carries no integer `" & HeightMember & "`. A " &
      "floor with no number states a boundary and does not say where it is")
  if h.getInt < 0:
    return ChainHistoryFloor(refusal:
      "`" & FloorMember & "." & HeightMember & "` is " & $h.getInt &
      "; a position below zero is not a position")
  let r = n{ReasonMember}
  ChainHistoryFloor(stated: true, height: h.getInt,
                    reason: (if r != nil and r.kind == JString: r.getStr else: ""))

func parseVmIdentity*(n: JsonNode): ChainVmIdentity =
  ## The `vm` member. An absent member and an empty token are the same answer —
  ## nothing was declared — because an empty instruction-set identity selects no
  ## table either way, and inventing a distinction a consumer cannot act on
  ## would be machinery.
  if n == nil or n.kind != JObject: return ChainVmIdentity()
  let isa = n{InstructionSetMember}
  if isa == nil or isa.kind != JString or isa.getStr.len == 0:
    return ChainVmIdentity()
  ChainVmIdentity(stated: true, instructionSet: isa.getStr)

func parseChainProfile*(row: JsonNode): ChainProfile =
  ## The whole profile out of one registry row. An absent row is an absent
  ## profile, which is the compatibility case and not an error: published data
  ## is immutable and append-only, so a tree written before these members
  ## existed does not roll back with the code (Publishing-And-Caching.md §6.2).
  if row == nil or row.kind != JObject: return
  ChainProfile(
    reach: parseReach(row{ReachMember}),
    floor: parseHistoryFloor(row{FloorMember}),
    ordering: parseOrdering(row{OrderingMember}),
    vm: parseVmIdentity(row{VmMember}))

func refusals*(p: ChainProfile): seq[string] =
  ## Every sentence this row earned, in a fixed order so two runs over one tree
  ## report the same list.
  if p.reach.refusal.len > 0: result.add p.reach.refusal
  if p.floor.refusal.len > 0: result.add p.floor.refusal
  if p.ordering.refusal.len > 0: result.add p.ordering.refusal

func profileConsistency*(p: ChainProfile): string =
  ## **The rule that keeps the kind and its parameter from drifting apart**, and
  ## the reason they are two members rather than one parsed string.
  ##
  ## Exactly two of §1.3's six carry a parameter, so exactly two of them may be
  ## accompanied by a number — and both of them MUST be, because `floor` and
  ## `windowed` without a boundary state that a boundary exists and decline to
  ## say where. Both directions are checked: a number with the wrong kind beside
  ## it is as broken as a kind with no number.
  ##
  ## Nothing is checked when either side is absent. A row that declares no reach
  ## at all is the compatibility case, and a row that declares one this build
  ## does not recognise has already earned its own refusal — reporting a second
  ## one derived from a token we could not read would be inventing a finding.
  const Parameterised = {rkFloor, rkWindowed}
  if p.reach.state != dsDeclared: return ""
  if p.reach.kind in Parameterised and not p.floor.stated:
    if p.floor.refusal.len > 0: return ""   # already reported, once
    return "`" & ReachMember & "` is '" & $p.reach.kind & "', one of the two " &
      "members of Chain-Support-Matrix.md §1.3's vocabulary that carry a " &
      "parameter, and this row states no `" & FloorMember & "`. The boundary " &
      "is the parameter; a kind without it says a boundary exists and declines " &
      "to say where"
  if p.reach.kind notin Parameterised and p.floor.stated:
    return "this row states a `" & FloorMember & "` of " & $p.floor.height &
      " beside a `" & ReachMember & "` of '" & $p.reach.kind & "'. Only '" &
      $rkFloor & "' and '" & $rkWindowed & "' take a boundary; the other four " &
      "of Chain-Support-Matrix.md §1.3's six (" & reachKindList() & ") have " &
      "none to take, so a number here is a fact about a chain that cannot have it"
  ""

# ---------------------------------------------------------------------------
# What a producer writes
# ---------------------------------------------------------------------------

func reachFromWindow*(hasBoundary: bool; boundary, finalized: int): ChainReach =
  ## **Which of §1.3's kinds a capture's own replay window shows this chain to
  ## have** — derived from the capture, never asserted from a name.
  ##
  ## The snapshot states three positions: the node's tip, the node's own
  ## finalized pointer, and the lowest position it could serve prestate for. The
  ## third is the boundary. Which KIND of boundary it is follows from where it
  ## sits:
  ##
  ##   * **It coincides with the finalized pointer.** The node prunes state at
  ##     its own finalized tip, so the boundary moves with the chain and what is
  ##     reachable is a WINDOW, not a fixed point in history. That is
  ##     `windowed`, and it is what every capture in this repository shows —
  ##     measured, five of five, the boundary exactly one above `finalized` in
  ##     each.
  ##   * **It sits somewhere else.** Then it is a position in this chain's
  ##     history that does not track the head — a mechanism changed at a block
  ##     and everything below it is permanently unreachable — which is
  ##     `floor(B)`.
  ##
  ## A capture that states no boundary states no reach. That is the honest
  ## answer and not a default of `archive`: `archive` is a claim that any
  ## historical position is reachable, which is a strong claim about somebody
  ## else's infrastructure and not one a silent window supports.
  if not hasBoundary: return ChainReach(state: dsAbsent)
  let k = if boundary == finalized + 1: rkWindowed else: rkFloor
  ChainReach(state: dsDeclared, kind: k, token: $k)

func chainProfileNode*(p: ChainProfile): JsonNode =
  ## The members of `p` that were stated, as registry row members.
  ##
  ## Only what was stated. An unstated member is OMITTED rather than written
  ## null or zero, because §2.2's additive rule works in both directions: a
  ## consumer must ignore a member it does not know, and a producer must not
  ## publish a member it cannot fill. A `historyFloor` of `0` on a chain nobody
  ## measured would make every transaction on it read as above the floor.
  result = newJObject()
  if p.reach.state == dsDeclared: result[ReachMember] = %($p.reach.kind)
  if p.floor.stated:
    var f = %*{HeightMember: p.floor.height}
    if p.floor.reason.len > 0: f[ReasonMember] = %p.floor.reason
    result[FloorMember] = f
  if p.ordering.state == dsDeclared:
    result[OrderingMember] = %*{KindMember: $p.ordering.kind}
  if p.vm.stated:
    result[VmMember] = %*{InstructionSetMember: p.vm.instructionSet}

proc mergeChainProfile*(row: JsonNode; p: ChainProfile) =
  ## Write `p`'s stated members onto a registry row, in place.
  if row == nil or row.kind != JObject: return
  let node = chainProfileNode(p)
  for k, v in node: row[k] = v
