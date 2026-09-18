## tests/tchainprofile.nim
##
## The registry's per-chain **profile**: `reach` and `historyFloor`
## (Chain-Support-Matrix.md §1.3), `ordering` (Static-Site-Architecture.md
## §2.3's ordering union) and `vm` (the instruction-set identity a mnemonic
## table is selected by). Configuration.md §2.1 is the schema and §2.2 the
## additive rule.
##
## ## Why this is a suite of its own and not three lines somewhere
##
## These four members are the ones the consumers already asked for and no
## producer wrote. A field that is read and never produced has a branch that has
## never run, and the first time it runs is in front of a visitor. So what is
## graded here is the WHOLE round trip — a producer measures, publishes, and a
## reader reads back — over trees the real producers wrote, plus the refusals
## that keep the closed sets closed.
##
## `tests/tidentifierencoding.nim` is the sibling this file is shaped after:
## same producers, same registry, same additive rule, a different member.
## Deliberately not merged with it. That file's subject is one member and it is
## already 1,800 lines; and a suite that grades two unrelated members has no
## honest answer to "which member is this arm about".
##
## ## Nothing here is mocked
##
## Both producers are driven directly (`generate`, `ingestSnapshot`) over
## committed fixtures, the registry is read back as BYTES off disk with
## `std/json` rather than through the module that wrote it, and the validator is
## the shipping one. The only constructed inputs are the malformed rows in the
## refusal suites, which are constructed because no producer can write one —
## that being the point of a refusal.

import std/[unittest, os, json, strutils, algorithm]

import ../src/blocktracer_client
import ../src/blocktracer/contract/chain_profile
import ../src/blocktracer/contract/ids as contractIds
import ../src/blocktracer/contract/model
import ../src/blocktracer/validator
import ../src/blocktracer/demo/generator
import ../src/blocktracer/chain/ingest

const
  RepoRoot = currentSourcePath().parentDir.parentDir
  TraceFixtureDir = RepoRoot / "fixtures" / "trace" / "noir_space_ship"
  TraceFixture = TraceFixtureDir / "zk_shields.ct"
  TraceSources = TraceFixtureDir / "sources"
  LiveMainnet = RepoRoot / "tests" / "fixtures" / "chain-snapshots" /
                "aztec-mainnet-live"
  ListingCapture = RepoRoot / "client" / "fixtures" / "chain" / "aztec-testnet"
  RegistryRel = "registry/chains.v1.json"
  OrderingKindCount = ord(high(TxOrderKind)) - ord(low(TxOrderKind)) + 1
  ReachKindCount = ord(high(ReachKind)) - ord(low(ReachKind)) + 1

# REFUSES RATHER THAN SKIPS. Every subject below is committed, and a run that
# quietly produced no tree would report green having measured nothing.
doAssert fileExists(TraceFixture),
  "fixtures/trace/noir_space_ship/zk_shields.ct is missing; the demo producer " &
  "cannot be driven and a skipped run would be a green that means nothing."
doAssert fileExists(LiveMainnet / "snapshot.json"),
  "tests/fixtures/chain-snapshots/aztec-mainnet-live/snapshot.json is missing; " &
  "the capture with a replay boundary and no instruction listing cannot be " &
  "driven, and half of what this file grades is that the two members are " &
  "independent."
doAssert fileExists(ListingCapture / "snapshot.json"),
  "client/fixtures/chain/aztec-testnet/snapshot.json is missing; the capture " &
  "whose published listings declare an instruction set cannot be driven."

var asserted = 0
template ck(condition: untyped) =
  inc asserted
  check condition
template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

proc tmpDir(tag: string): string =
  result = getTempDir() / ("bt-chainprofile-" & tag & "-" & $getCurrentProcessId())
  removeDir result
  createDir result

proc buildDemo(tag: string): string =
  result = tmpDir(tag)
  discard generate(DemoConfig(outDir: result, seed: "chainprofile",
                              traceFixturePath: TraceFixture,
                              traceSourcesDir: TraceSources))

proc buildIngest(tag, snapshotDir: string): string =
  result = tmpDir(tag)
  discard ingestSnapshot(IngestConfig(outDir: result, snapshotDir: snapshotDir))

proc rawRegistry(tree: string): JsonNode =
  ## The registry as BYTES ON DISK, parsed with `std/json` — never through the
  ## module that wrote it.
  parseJson(readFile(tree / RegistryRel))

proc writeRegistry(tree: string, node: JsonNode) =
  writeFile(tree / RegistryRel, node.pretty & "\n")

proc onlySlug(reg: JsonNode): string =
  var slugs: seq[string]
  for slug, _ in reg["chains"]: slugs.add slug
  slugs.sort()
  doAssert slugs.len == 1, "expected exactly one chain, got " & $slugs
  slugs[0]

proc relFiles(root: string): seq[string] =
  for p in walkDirRec(root, relative = true):
    result.add p.replace('\\', '/')
  result.sort()

proc anyPublishedIsa(tree: string): string =
  ## The instruction set a published listing in this tree declares, read out of
  ## the tree rather than written here. A test that stated the token would be
  ## asserting that the producer agrees with the test.
  for p in walkDirRec(tree):
    if p.endsWith("instructions.json"):
      let isa = parseJson(readFile(p)){"isa"}.getStr
      if isa.len > 0: return isa
  ""

# ───────────────────────────────────────────────────────────────────────────
suite "each declaration is a closed set, and a refusal prints the whole set":
  asserted = 0

  ## The house rule, and it was earned: a reader who meets `unknown ordering
  ## kind` and no set has to go and find the set, and the set is the answer. So
  ## every refusal below names what it found, prints every member, and says what
  ## to do — and each of those three is asserted rather than described.

  test "an ordering kind outside §2.3's union is refused by name":
    let r = parseOrdering(%*{"kind": "sequenceNumber"})
    ck r.state == dsUnrecognised
    ck r.token == "sequenceNumber"
    ck "sequenceNumber" in r.refusal
    for k in TxOrderKind:
      ck $k in r.refusal
    ck "amendment to" in r.refusal          # the remedy: amend §2.3, not the row

  test "an ordering member with no kind at all is refused, and says why a kind":
    let r = parseOrdering(%*{"not-a-kind": 1})
    ck r.state == dsUnrecognised
    ck "carries no `kind`" in r.refusal
    for k in TxOrderKind:
      ck $k in r.refusal

  test "an ordering member of the wrong SHAPE is refused":
    let r = parseOrdering(%"blockIndex")
    ck r.state == dsUnrecognised
    ck "must be an object" in r.refusal

  test "a reach outside §1.3's six is refused by name":
    let r = parseReach(%"eventually-consistent")
    ck r.state == dsUnrecognised
    ck "eventually-consistent" in r.refusal
    for k in ReachKind:
      ck $k in r.refusal
    ck "gap in that table" in r.refusal

  test "§1.3's PROSE notation is refused, with the number's real home named":
    # The one wrong answer worth naming outright, because §1.3's own table is
    # written in the notation that produces it. A registry string
    # `floor(632813)` has to be parsed before it can be compared with anything,
    # and a parsed registry value is exactly the drift the split exists to stop.
    for token in ["floor(632813)", "windowed(41)"]:
      let r = parseReach(%token)
      ck r.state == dsUnrecognised
      ck "prose notation" in r.refusal
      ck "historyFloor" in r.refusal

  test "the floor has ONE spelling, and the other is refused rather than ignored":
    let good = parseHistoryFloor(%*{"height": 42, "reason": "because"})
    ck good.stated
    ck good.height == 42
    ck good.reason == "because"
    ck good.refusal.len == 0
    # A bare integer says something, and treating it as silence would report a
    # chain as having no floor while its registry states one.
    let bare = parseHistoryFloor(%42)
    ck not bare.stated
    ck "bare integer" in bare.refusal
    ck "two spellings" in bare.refusal
    let noHeight = parseHistoryFloor(%*{"reason": "x"})
    ck not noHeight.stated
    ck "no integer `height`" in noHeight.refusal
    let negative = parseHistoryFloor(%*{"height": -1})
    ck not negative.stated
    ck "not a position" in negative.refusal

  test "an absent member is the compatibility case and earns no refusal":
    # Published data is immutable and append-only, so a tree written before
    # these members existed does not roll back with the code. Absence is not an
    # error anywhere in this profile, and none of the four states a sentence.
    let p = parseChainProfile(%*{"recorder": {"id": "x"}})
    ck p.reach.state == dsAbsent
    ck p.ordering.state == dsAbsent
    ck not p.floor.stated
    ck not p.vm.stated
    ck p.refusals.len == 0
    ck profileConsistency(p) == ""
    # …and so is a row that is not there at all.
    let none = parseChainProfile(nil)
    ck none.reach.state == dsAbsent
    ck none.refusals.len == 0

  test "assertion count":
    #   ordering, unrecognised: 4 + one per member of the union
    #   ordering, no kind:      2 + one per member
    #   ordering, wrong shape:  2
    #   reach, unrecognised:    3 + one per member of §1.3's six
    #   reach, prose notation:  3 per token, two tokens
    #   the floor's spellings:  11
    #   absence:                8
    expectCount((4 + OrderingKindCount) + (2 + OrderingKindCount) + 2 +
                (3 + ReachKindCount) + 6 + 11 + 8)

# ───────────────────────────────────────────────────────────────────────────
suite "the reach kind and the floor are one fact split, and the split is enforced":
  asserted = 0

  ## The ruling, made mechanical. §1.3's vocabulary is CATEGORICAL
  ## and exactly two of its six carry a parameter inside the token. The kind is
  ## published bare, the number is published as data beside it, and one
  ## predicate — called by the validator and by the client — checks them against
  ## each other in both directions.

  proc consistencyOf(row: JsonNode): string =
    profileConsistency(parseChainProfile(row))

  test "a parameterised kind WITH its boundary is consistent":
    ck consistencyOf(%*{"reach": "windowed",
                        "historyFloor": {"height": 10}}) == ""
    ck consistencyOf(%*{"reach": "floor",
                        "historyFloor": {"height": 10}}) == ""

  test "an unparameterised kind with NO boundary is consistent":
    for k in [$rkArchive, $rkVersionAddressed, $rkSelfContained, $rkRecentOnly]:
      ck consistencyOf(%*{"reach": k}) == ""

  test "a parameterised kind with no boundary is refused":
    for k in [$rkFloor, $rkWindowed]:
      let msg = consistencyOf(%*{"reach": k})
      ck msg.len > 0
      ck "declines to say where" in msg

  test "a boundary beside a kind that cannot take one is refused":
    for k in [$rkArchive, $rkVersionAddressed, $rkSelfContained, $rkRecentOnly]:
      let msg = consistencyOf(%*{"reach": k, "historyFloor": {"height": 10}})
      ck msg.len > 0
      ck "cannot have it" in msg
      for m in ReachKind:
        ck $m in msg

  test "nothing is derived from a kind this build could not read":
    # A row that declared a reach this build does not recognise has already
    # earned its own refusal; a second one derived from a token we could not
    # read would be inventing a finding.
    ck consistencyOf(%*{"reach": "nonsense",
                        "historyFloor": {"height": 10}}) == ""
    ck consistencyOf(%*{"historyFloor": {"height": 10}}) == ""

  test "assertion count":
    expectCount(2 + 4 + 2 * 2 + 4 * (2 + ReachKindCount) + 2)

# ───────────────────────────────────────────────────────────────────────────
suite "both producers state what they MEASURED, and nothing they did not":
  asserted = 0

  test "the chain ingest publishes the boundary its capture states":
    let tree = buildIngest("ing-floor", LiveMainnet)
    let row = rawRegistry(tree)["chains"][onlySlug(rawRegistry(tree))]
    let win = parseJson(readFile(LiveMainnet / "snapshot.json"))["window"]
    ck row["historyFloor"]["height"].getInt == win["replayableFrom"].getInt
    ck row["historyFloor"]{"reason"}.getStr.len > 0
    # `windowed` because the boundary coincides with the node's own finalized
    # pointer, which moves with the chain. The coincidence is a fact about this
    # capture, so it is asserted here rather than assumed by the producer.
    ck row["reach"].getStr == $rkWindowed
    ck win["replayableFrom"].getInt == win["finalized"].getInt + 1
    # …and the ordering kind is the kind of the rows this run actually wrote.
    ck row["ordering"]["kind"].getStr == $tokBlockIndex
    # THIS CAPTURE PUBLISHES NO INSTRUCTION LISTING, so it declares no
    # instruction set. Absence is the honest answer and is what makes the four
    # members independent rather than one flag with four names.
    ck anyPublishedIsa(tree) == ""
    ck not row.hasKey("vm")
    ck parseChainProfile(row).refusals.len == 0
    ck profileConsistency(parseChainProfile(row)) == ""
    removeDir tree

  test "the chain ingest publishes the instruction set its listings declare":
    let tree = buildIngest("ing-vm", ListingCapture)
    let row = rawRegistry(tree)["chains"][onlySlug(rawRegistry(tree))]
    let published = anyPublishedIsa(tree)
    ck published.len > 0
    ck row["vm"]["instructionSet"].getStr == published
    removeDir tree

  test "CONTROL: a boundary that does NOT track the finalized pointer is a floor, not a window":
    # The kind is DERIVED, so both of its values have to be producible or the
    # derivation is a constant wearing a rule's clothes.
    let snapDir = tmpDir("ing-detached-snap")
    copyDir(LiveMainnet, snapDir / "capture")
    let capture = snapDir / "capture"
    var doc = parseJson(readFile(capture / "snapshot.json"))
    let finalized = doc["window"]["finalized"].getInt
    let detached = finalized - 100
    ck doc["window"]["replayableFrom"].getInt == finalized + 1
    doc["window"]["replayableFrom"] = %detached
    writeFile(capture / "snapshot.json", $doc)
    ck parseJson(readFile(capture / "snapshot.json"))[
         "window"]["replayableFrom"].getInt == detached
    let tree = buildIngest("ing-detached", capture)
    let row = rawRegistry(tree)["chains"][onlySlug(rawRegistry(tree))]
    ck row["reach"].getStr == $rkFloor
    ck row["historyFloor"]["height"].getInt == detached
    ck profileConsistency(parseChainProfile(row)) == ""
    removeDir tree
    removeDir snapDir

  test "CONTROL: a capture with no boundary publishes no floor and no reach":
    let snapDir = tmpDir("ing-noboundary-snap")
    copyDir(LiveMainnet, snapDir / "capture")
    let capture = snapDir / "capture"
    var doc = parseJson(readFile(capture / "snapshot.json"))
    ck doc["window"].hasKey("replayableFrom")
    doc["window"].delete("replayableFrom")
    ck not doc["window"].hasKey("replayableFrom")
    writeFile(capture / "snapshot.json", $doc)
    let tree = buildIngest("ing-noboundary", capture)
    let row = rawRegistry(tree)["chains"][onlySlug(rawRegistry(tree))]
    ck not row.hasKey("historyFloor")
    ck not row.hasKey("reach")
    # …and the member that does not come from the window is unmoved, so the
    # difference between this tree and the one above is the boundary alone.
    ck row["ordering"]["kind"].getStr == $tokBlockIndex
    removeDir tree
    removeDir snapDir

  test "the demo producer declares its ordering kind and states nothing else":
    # It constructs every row it publishes, so it knows how they are ordered. It
    # has no node with a retention window, so there is no boundary to measure —
    # and `archive` would be a claim that any historical position is reachable,
    # which is a strong claim to make about a chain that is generated rather
    # than observed. It publishes no instruction listing either.
    let tree = buildDemo("demo-profile")
    let row = rawRegistry(tree)["chains"][onlySlug(rawRegistry(tree))]
    ck row["ordering"]["kind"].getStr == $DemoOrderingKind
    ck not row.hasKey("reach")
    ck not row.hasKey("historyFloor")
    ck not row.hasKey("vm")
    ck validateTree(tree).len == 0
    removeDir tree

  test "assertion count":
    expectCount(9 + 2 + 5 + 5 + 5)

# ───────────────────────────────────────────────────────────────────────────
suite "a producer that declares one thing and publishes another is caught":
  asserted = 0

  ## The reason the validator reads the row back out of the tree it is
  ## validating rather than carrying its own opinion: a validator with an
  ## opinion agrees with whichever producer shares it.

  proc findingsWith(tree: string, edit: proc(row: JsonNode)): seq[string] =
    var reg = rawRegistry(tree)
    edit(reg["chains"][onlySlug(reg)])
    writeRegistry(tree, reg)
    validateTree(tree)

  test "the green arm: a tree its own producer wrote has no findings":
    # Without this every arm below is consistent with a validator that reports
    # something about everything.
    let tree = buildIngest("val-green", ListingCapture)
    ck validateTree(tree).len == 0
    removeDir tree

  test "an ordering kind the published rows contradict is reported":
    let tree = buildIngest("val-order", LiveMainnet)
    let found = findingsWith(tree, proc(row: JsonNode) =
      row["ordering"] = %*{"kind": $tokCheckpoint})
    ck found.len > 0
    var named = 0
    for f in found:
      if $tokCheckpoint in f and $tokBlockIndex in f: inc named
    ck named > 0
    removeDir tree

  test "an instruction set the published listings contradict is reported":
    let tree = buildIngest("val-isa", ListingCapture)
    let published = anyPublishedIsa(tree)
    ck published.len > 0
    let found = findingsWith(tree, proc(row: JsonNode) =
      row["vm"] = %*{"instructionSet": "not-the-one-the-listings-declare"})
    ck found.len > 0
    var named = 0
    for f in found:
      if "not-the-one-the-listings-declare" in f and published in f: inc named
    ck named > 0
    removeDir tree

  test "a malformed profile is reported by name, with the whole set":
    let tree = buildIngest("val-shapes", LiveMainnet)
    let bareFloor = findingsWith(tree, proc(row: JsonNode) =
      row["historyFloor"] = %42)
    var sawBare = false
    for f in bareFloor:
      if "bare integer" in f: sawBare = true
    ck sawBare
    let tree2 = buildIngest("val-shapes2", LiveMainnet)
    let proseReach = findingsWith(tree2, proc(row: JsonNode) =
      row["reach"] = %"floor(79891)")
    var sawProse = false
    for f in proseReach:
      if "prose notation" in f: sawProse = true
    ck sawProse
    let tree3 = buildIngest("val-shapes3", LiveMainnet)
    let inconsistent = findingsWith(tree3, proc(row: JsonNode) =
      row["reach"] = %($rkArchive))
    var sawInconsistent = false
    for f in inconsistent:
      if "cannot have it" in f: sawInconsistent = true
    ck sawInconsistent
    removeDir tree
    removeDir tree2
    removeDir tree3

  test "assertion count":
    expectCount(1 + 2 + 3 + 3)

# ───────────────────────────────────────────────────────────────────────────
suite "the additive rule: a client built for the current schema reads all four":
  asserted = 0

  ## ## What "a client built for the current schema" is here, and why it is not
  ## a stub
  ##
  ## The readers named below were all written against the registry WITHOUT these
  ## members and have not been touched: `chains`, `decodeRecorderPin`,
  ## `openChain` and the `traceArtifactId` the pin derives. They ARE clients
  ## built for the previous schema. The two registries they are run over are the
  ## real producer's output with the members and the same output with them
  ## deleted, which is byte-for-byte what that producer wrote before this change.
  ##
  ## The CONTROL is the half that makes this a test rather than a tautology: a
  ## client that reads nothing at all passes the equality above. So the same
  ## readers are made to meet a member they ARE built for, three ways, and are
  ## required to move.

  test "every such reader's answer is identical with and without the members":
    let withFields = buildIngest("add-with", ListingCapture)
    let withoutFields = buildIngest("add-without", ListingCapture)
    let slug = onlySlug(rawRegistry(withFields))

    var old = rawRegistry(withoutFields)
    for member in [ReachMember, FloorMember, OrderingMember, VmMember]:
      ck old["chains"][slug].hasKey(member)
      old["chains"][slug].delete(member)
      ck not old["chains"][slug].hasKey(member)
    writeRegistry(withoutFields, old)

    # …and the ONLY difference between the two trees is the registry. Without
    # this the equalities below would only be about that one file.
    ck relFiles(withFields) == relFiles(withoutFields)
    var differing: seq[string]
    for rel in relFiles(withFields):
      if readFile(withFields / rel) != readFile(withoutFields / rel):
        differing.add rel
    ck differing == @[RegistryRel]

    let newStore = localTree(withFields)
    let oldStore = localTree(withoutFields)

    # 1. the chain inventory
    ck chains(newStore) == chains(oldStore)
    ck chains(newStore) == @[slug]

    # 2. the recorder pin
    let newPin = decodeRecorderPin(rawRegistry(withFields), slug)
    let oldPin = decodeRecorderPin(rawRegistry(withoutFields), slug)
    ck newPin.recorder.id == oldPin.recorder.id
    ck newPin.recorder.build == oldPin.recorder.build
    ck newPin.recorder.version == oldPin.recorder.version
    ck newPin.profile.hash == oldPin.profile.hash
    ck newPin.traceSchema == oldPin.traceSchema

    # 3. the address the pin derives — the load-bearing consequence. A member
    #    that could reach `traceArtifactId` would re-address every published
    #    container, which is what the additive rule exists to prevent.
    let newTid = deriveTraceArtifactId("exec-1", newPin.recorder.id,
                                       newPin.recorder.build,
                                       newPin.profile.hash, newPin.traceSchema)
    let oldTid = deriveTraceArtifactId("exec-1", oldPin.recorder.id,
                                       oldPin.recorder.build,
                                       oldPin.profile.hash, oldPin.traceSchema)
    ck newTid == oldTid
    ck newTid.len > 0

    # 4. the whole session open
    let newOpen = openChain(newStore, slug)
    let oldOpen = openChain(oldStore, slug)
    ck newOpen.outcome == oldOpen.outcome
    ck newOpen.outcome == ooOpened
    ck newOpen.session.generation == oldOpen.session.generation
    ck newOpen.session.contractVersion == oldOpen.session.contractVersion
    ck newOpen.session.pin.recorder.build == oldOpen.session.pin.recorder.build
    ck newOpen.session.pin.traceSchema == oldOpen.session.pin.traceSchema

    # 5. and the producer-side validator, which keys into the row directly
    ck validateTree(withFields) == validateTree(withoutFields)
    ck validateTree(withFields).len == 0

    removeDir withFields
    removeDir withoutFields

  test "CONTROL: the same readers DO move on a member they are built for":
    # THE SUBTLE HALF. A client that ignores everything passes the equality
    # above. These three arms use the same readers, the same call and the same
    # row, and require the answer to move — twice by changing a value and once
    # by refusing an absence.
    let tree = buildIngest("ctl-known", ListingCapture)
    let slug = onlySlug(rawRegistry(tree))

    # (a) an OPTIONAL member the reader knows: the decoded pin changes.
    let before = decodeRecorderPin(rawRegistry(tree), slug)
    ck before.recorder.version.len > 0
    var reg = rawRegistry(tree)
    reg["chains"][slug]["recorder"].delete("version")
    writeRegistry(tree, reg)
    let afterOptional = decodeRecorderPin(rawRegistry(tree), slug)
    ck afterOptional.recorder.version.len == 0
    ck afterOptional.recorder.build == before.recorder.build   # attributable

    # (b) a REQUIRED member's value: the published trace ADDRESS moves.
    let beforeTid = deriveTraceArtifactId("exec-1", before.recorder.id,
                                          before.recorder.build,
                                          before.profile.hash,
                                          before.traceSchema)
    reg = rawRegistry(tree)
    reg["chains"][slug]["traceSchema"] = %"ctfs/v99"
    writeRegistry(tree, reg)
    let afterRequired = decodeRecorderPin(rawRegistry(tree), slug)
    ck afterRequired.traceSchema == "ctfs/v99"
    let afterTid = deriveTraceArtifactId("exec-1", afterRequired.recorder.id,
                                         afterRequired.recorder.build,
                                         afterRequired.profile.hash,
                                         afterRequired.traceSchema)
    ck afterTid != beforeTid

    # (c) a REQUIRED member's absence: refused BY NAME. A reader that tolerated
    #     this would be tolerating everything, and its tolerance of the new
    #     members would prove nothing.
    reg = rawRegistry(tree)
    reg["chains"][slug].delete("traceSchema")
    writeRegistry(tree, reg)
    var raised = false
    try:
      discard decodeRecorderPin(rawRegistry(tree), slug)
    except CatchableError as e:
      raised = true
      ck "traceSchema" in e.msg
    ck raised
    removeDir tree

  test "an unknown member is ignored wherever it sits, not only at the row":
    # §2.2's rule is about the registry, not about one nesting depth. These four
    # members arrived at the row; the next one may not.
    let tree = buildIngest("add-unknown", LiveMainnet)
    let slug = onlySlug(rawRegistry(tree))
    let before = decodeRecorderPin(rawRegistry(tree), slug)
    var reg = rawRegistry(tree)
    reg["chains"][slug]["notAFieldAnyBuildKnows"] = %"top"
    reg["chains"][slug]["ordering"]["norThisOne"] = %42
    reg["chains"][slug]["historyFloor"]["norThis"] = %"x"
    writeRegistry(tree, reg)
    let after = decodeRecorderPin(rawRegistry(tree), slug)
    ck after.recorder.build == before.recorder.build
    ck after.traceSchema == before.traceSchema
    # …and the profile itself reads the members it knows and ignores the rest.
    let p = parseChainProfile(rawRegistry(tree)["chains"][slug])
    ck p.ordering.state == dsDeclared
    ck p.floor.stated
    ck p.refusals.len == 0
    ck validateTree(tree).len == 0
    removeDir tree

  test "assertion count":
    #   the identical-answers arm: 8 for the four deletions, 2 for the
    #   one-file difference, and 17 reader equalities
    #   the control: 7
    #   unknown members: 6
    expectCount(8 + 2 + 17 + 7 + 6)
