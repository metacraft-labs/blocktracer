## The registry's per-chain identifier-encoding declaration — Configuration.md
## §2.1 (the schema) and §2.2 (the additive rule).
##
## ## What this suite is about
##
## An identifier's encoding is stated as DATA in the published registry
## (`chains[<slug>].identifierEncoding`) rather than being inferred from the
## string, and **shard-path derivation reads it**: `contract/shards.nim` takes the
## token as a parameter, the producers hand it the value they publish, and the
## validator and the client read it back out of the row.
##
## Two sites still derive from the string and are deliberately later steps — the
## hash index (a published wire format, so a migration) and the capture tooling
## (which enumerates the tree the index keys, so it follows the index).
##
## Suites 1–3 are the closed set, the refusals and the producers' round trip.
##
## Suite 4 is §2.2's additive rule, which did not stop mattering when a consumer
## arrived: a client built against the schema **without** the member must still
## read a registry carrying it and behave identically. Because an equality that
## cannot fail is not evidence, it measures three controls in the same run, each a
## change to a member the same reader IS built for, each of which changes or
## refuses.
##
## Suite 5 states the boundary mechanically, as an EQUALITY between an enumerated
## set of files and a swept one, behind the same population floors as before. It
## used to assert that nothing read the member; that form went red when the
## derivation landed, which is what it was for, and it was replaced rather than
## widened. It also asserts that the two string-deriving sites are UNCHANGED, so
## that a check watching the closed half of the seam cannot report the open half
## as closed.
##
## ## NO MOCKS, and there are none to justify
##
## Per the workspace policy every mock must be justified in the file's header.
## There are none. The registries under test are written by the REAL producers —
## `generate` and `ingestSnapshot` — onto a real temporary directory, and the
## readers under test are the real SDK, the real decoder and the real validator.
## Ground truth is read back INDEPENDENTLY with `std/json` from the bytes on disk
## rather than through the module that wrote them, so the writer is never its own
## oracle. The committed mainnet capture is the ingest producer's subject for the
## reason `tchainsnapshot.nim` gives: it is a snapshot nobody in this repository
## wrote.

import std/[unittest, os, json, strutils, algorithm, osproc, sets]

import ../src/blocktracer_client
import ../src/blocktracer/contract/identifier_encoding
import ../src/blocktracer/contract/ids as contractIds
import ../src/blocktracer/validator
import ../src/blocktracer/demo/generator
import ../src/blocktracer/chain/ingest

const
  RepoRoot = currentSourcePath().parentDir.parentDir
  SharedSetFile = RepoRoot / "tools" / "chain" / "identifier-encodings.json"
  TraceFixtureDir = RepoRoot / "fixtures" / "trace" / "noir_space_ship"
  TraceFixture = TraceFixtureDir / "zk_shields.ct"
  TraceSources = TraceFixtureDir / "sources"
  LiveMainnet = RepoRoot / "tests" / "fixtures" / "chain-snapshots" /
                "aztec-mainnet-live"
  RegistryRel = "registry/chains.v1.json"

# THIS SUITE REFUSES RATHER THAN SKIPS. Both subjects are committed, and a run
# that quietly produced no registry would report green having measured nothing —
# which is exactly the silent self-pass the testing policy bans.
doAssert fileExists(TraceFixture),
  "fixtures/trace/noir_space_ship/zk_shields.ct is missing; the demo producer " &
  "cannot be driven and a skipped run would be a green that means nothing."
doAssert fileExists(LiveMainnet / "snapshot.json"),
  "tests/fixtures/chain-snapshots/aztec-mainnet-live/snapshot.json is missing; " &
  "the ingest producer cannot be driven and a skipped run would be a green " &
  "that means nothing."
doAssert fileExists(SharedSetFile),
  "tools/chain/identifier-encodings.json is missing. It is `staticRead` at " &
  "compile time, so this cannot happen without the build having failed first — " &
  "if it does, the file was deleted after the binary was built."

var asserted = 0
template ck(condition: untyped) =
  inc asserted
  check condition
template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

proc tmpDir(tag: string): string =
  result = getTempDir() / ("bt-identenc-" & tag & "-" & $getCurrentProcessId())
  removeDir result
  createDir result

proc buildDemo(tag: string, seed = "identenc"): string =
  result = tmpDir(tag)
  discard generate(DemoConfig(outDir: result, seed: seed,
                              traceFixturePath: TraceFixture,
                              traceSourcesDir: TraceSources))

proc buildIngest(tag: string): string =
  result = tmpDir(tag)
  discard ingestSnapshot(IngestConfig(outDir: result, snapshotDir: LiveMainnet))

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

# ───────────────────────────────────────────────────────────────────────────
suite "the encoding vocabulary is a closed set with one source":

  test "the members are the shape table's, and the module is not its own oracle":
    # INDEPENDENT ORACLE: the shared file read here with `std/json`, compared
    # against what the compile-time reader made of it. If the two disagree the
    # `staticRead` is reading something other than this file.
    let doc = parseJson(readFile(SharedSetFile))
    ck doc["format"].getStr == IdentifierEncodingsFormat
    var fileEncodings: seq[string]
    for e in doc["encodings"]: fileEncodings.add e["id"].getStr
    var fileKinds: seq[string]
    for k in doc["kinds"]: fileKinds.add k["id"].getStr
    ck identifierEncodingIds() == fileEncodings
    ck identifierKindIds() == fileKinds

    # Every encoding named by a row of Search-And-Routing.md §2's shape table is
    # a member. Spelled out rather than counted, because a count would stay green
    # if a member were replaced by a different one.
    for want in ["hex", "base58", "base64", "base64url", "bech32", "bech32m",
                 "ss58", "decimal"]:
      ck isIdentifierEncoding(want)

    # The three kinds are the chain-supplied identifiers that become path
    # segments in `blocktracer_client/paths.nim`. `traceArtifactId`, `codeHash`
    # and `bundleHash` are ours and are deliberately not kinds.
    ck identifierKindIds().sorted() == @["address", "block", "transaction"]
    ck not isIdentifierKind("trace")
    ck not isIdentifierKind("traceArtifactId")
    ck not isIdentifierKind("codeHash")

  test "membership is exact, not approximate":
    # A non-member is a non-member however plausible it looks, and membership is
    # CASE-EXACT because the token is published verbatim as a registry value: a
    # value that has to be normalised before it can be compared is the drift a
    # closed set exists to stop.
    ck not isIdentifierEncoding("base32")
    ck not isIdentifierEncoding("Hex")
    ck not isIdentifierEncoding("HEX")
    ck not isIdentifierEncoding("hex ")
    ck not isIdentifierEncoding("")
    ck not isIdentifierEncoding("0x")

  test "every member names the row of the shape table it comes from":
    # What makes the set reviewable against the spec rather than merely finite.
    for e in IdentifierEncodings:
      ck e.shapeRows.len > 0
    for k in IdentifierKinds:
      ck k.pathSites.len > 0

  test "the failure messages name the sets, so a refusal is a diagnosis":
    ck identifierEncodingList().contains("hex")
    ck identifierEncodingList().contains("ss58")
    ck identifierKindList().contains("transaction")

# ───────────────────────────────────────────────────────────────────────────
suite "a declaration outside the closed set is refused, not carried":

  test "an encoding the set does not contain raises, naming the set":
    var raised = false
    try:
      discard identifierEncodingNode({"transaction": "base32"})
    except ValueError as e:
      raised = true
      ck e.msg.contains("base32")
      ck e.msg.contains("not an identifier encoding")
      # The members, so the fix is visible from the failure.
      ck e.msg.contains("base58")
    ck raised

  test "a kind the set does not contain raises, naming the kinds":
    var raised = false
    try:
      discard identifierEncodingNode({"traceArtifactId": "hex"})
    except ValueError as e:
      raised = true
      ck e.msg.contains("traceArtifactId")
      ck e.msg.contains("not an identifier kind")
      ck e.msg.contains("transaction")
    ck raised

  test "an empty declaration raises: saying nothing is worse than absence":
    var nothing: seq[(string, string)]
    var raised = false
    try:
      discard identifierEncodingNode(nothing)
    except ValueError:
      raised = true
    ck raised

  test "one kind declared twice raises":
    var raised = false
    try:
      discard identifierEncodingNode({"transaction": "hex",
                                      "transaction": "base58"})
    except ValueError as e:
      raised = true
      ck e.msg.contains("twice")
    ck raised

  test "an omitted kind is legal, because some chains cannot honestly fill it":
    # Substrate's transaction identity is `{ kind: "blockIndex" }` — a pair, not
    # an encoded string — so no member of the encoding set describes it and
    # omitting the kind says so. Inventing a token for it would not.
    let partial = identifierEncodingNode({"address": "ss58"})
    ck partial.kind == JObject
    ck partial.len == 1
    ck partial["address"].getStr == "ss58"
    ck not partial.hasKey("transaction")

  test "keys are sorted, so a regeneration cannot depend on argument order":
    let a = identifierEncodingNode({"transaction": "base64", "address": "hex",
                                    "block": "decimal"})
    let b = identifierEncodingNode({"block": "decimal", "transaction": "base64",
                                    "address": "hex"})
    ck $a == $b
    var keys: seq[string]
    for k, _ in a: keys.add k
    ck keys == @["address", "block", "transaction"]
    # …and the per-kind values did not get shuffled along with the keys. A sort
    # that reordered the pairs rather than the members would pass the check above
    # and publish Sui's digest encoding on its addresses.
    ck a["transaction"].getStr == "base64"
    ck a["address"].getStr == "hex"
    ck a["block"].getStr == "decimal"

  test "every member of the set is actually writable as a declaration":
    # The set is only closed usefully if each member can be declared. A member
    # the builder rejects would be a set with a hole in it.
    for id in identifierEncodingIds():
      let n = identifierEncodingNode({"transaction": id})
      ck n["transaction"].getStr == id

# ───────────────────────────────────────────────────────────────────────────
suite "both registry producers declare it, drawn from that set":

  test "the demo generator writes it for the chain it publishes":
    let tree = buildDemo("gen")
    let reg = rawRegistry(tree)
    let slug = onlySlug(reg)
    let row = reg["chains"][slug]
    ck row.hasKey("identifierEncoding")
    let decl = row["identifierEncoding"]
    ck decl.kind == JObject
    # Every kind in the closed set is declared for this chain, and every value is
    # a member. Both halves matter: a row declaring nothing would satisfy the
    # second alone.
    var declaredKinds: seq[string]
    for kind, value in decl:
      declaredKinds.add kind
      ck isIdentifierKind(kind)
      ck isIdentifierEncoding(value.getStr)
    ck declaredKinds.sorted() == identifierKindIds().sorted()
    # MEASURED for this chain: `synthAddr` emits `0x` + 40 lowercase hex and
    # every synthetic hash here is the same shape.
    ck decl["transaction"].getStr == "hex"
    ck decl["address"].getStr == "hex"
    ck decl["block"].getStr == "hex"
    removeDir tree

  test "the chain ingest producer writes it over a capture nobody here wrote":
    let tree = buildIngest("ing")
    let reg = rawRegistry(tree)
    let slug = onlySlug(reg)
    let row = reg["chains"][slug]
    ck row.hasKey("identifierEncoding")
    let decl = row["identifierEncoding"]
    var declaredKinds: seq[string]
    for kind, value in decl:
      declaredKinds.add kind
      ck isIdentifierKind(kind)
      ck isIdentifierEncoding(value.getStr)
    ck declaredKinds.sorted() == identifierKindIds().sorted()
    # MEASURED, not assumed: every identifier in this chain's committed captures
    # is `0x` + 64 LOWERCASE hex — field elements, so there is no EIP-55
    # checksum carried in their case either.
    ck decl["transaction"].getStr == "hex"
    ck decl["address"].getStr == "hex"
    ck decl["block"].getStr == "hex"
    removeDir tree

  test "the declaration is byte-stable across a regeneration":
    # The producers publish trees that are compared byte-for-byte across runs. A
    # member whose key order followed a caller's argument list would turn every
    # regeneration into a diff.
    let a = buildDemo("stable-a", seed = "same")
    let b = buildDemo("stable-b", seed = "same")
    ck readFile(a / RegistryRel) == readFile(b / RegistryRel)
    ck readFile(a / RegistryRel).contains("identifierEncoding")
    removeDir a
    removeDir b

  test "the tree still validates against the contract with the member present":
    let tree = buildDemo("validate")
    ck validateTree(tree).len == 0
    removeDir tree

# ───────────────────────────────────────────────────────────────────────────
suite "the additive rule: an older client reads it and behaves identically":

  # ── WHAT "AN OLDER CLIENT" IS HERE, AND WHY IT IS NOT A STUB ───────────────
  #
  # The readers in this repository were all written against the schema WITHOUT
  # this member — they are, exactly, clients built for the previous schema. So
  # the older client is the real reader, and the two registries it is run over
  # are the real producer's output with and without the member. Nothing is
  # simulated: what is constructed is the OLD registry, by deleting the new
  # member from the new one, which is byte-for-byte what the producer wrote
  # before this change.

  test "every reader's answer is identical with and without the member":
    let withField = buildDemo("add-with")
    let withoutField = buildDemo("add-without")
    let slug = onlySlug(rawRegistry(withField))

    # The old-schema registry: the same tree, with the one new member removed.
    var old = rawRegistry(withoutField)
    ck old["chains"][slug].hasKey("identifierEncoding")
    old["chains"][slug].delete("identifierEncoding")
    ck not old["chains"][slug].hasKey("identifierEncoding")
    writeRegistry(withoutField, old)

    # …and the ONLY difference between the two trees is that member. This is the
    # "nothing else moved" half of the claim, and without it the equalities below
    # would only be about the registry.
    ck relFiles(withField) == relFiles(withoutField)
    var differing: seq[string]
    for rel in relFiles(withField):
      if readFile(withField / rel) != readFile(withoutField / rel):
        differing.add rel
    ck differing == @[RegistryRel]

    let newStore = localTree(withField)
    let oldStore = localTree(withoutField)

    # 1. The chain inventory — `session.nim`'s `chains`, which enumerates the
    #    `chains` object's keys.
    ck chains(newStore) == chains(oldStore)
    ck chains(newStore) == @[slug]

    # 2. The recorder pin — `decode.nim`'s `decodeRecorderPin`, the reader that
    #    §2.2 names as honouring the rule by construction.
    let newPin = decodeRecorderPin(rawRegistry(withField), slug)
    let oldPin = decodeRecorderPin(rawRegistry(withoutField), slug)
    ck newPin.recorder.id == oldPin.recorder.id
    ck newPin.recorder.build == oldPin.recorder.build
    ck newPin.recorder.version == oldPin.recorder.version
    ck newPin.profile.name == oldPin.profile.name
    ck newPin.profile.hash == oldPin.profile.hash
    ck newPin.traceSchema == oldPin.traceSchema

    # 3. The address the pin derives — the load-bearing consequence. If the
    #    member could reach `traceArtifactId` it would re-address every published
    #    container, which is the failure mode the additive rule exists to
    #    prevent. `executionInputId` is fixed so the two derivations differ in
    #    nothing but the registry they came from.
    let newTid = deriveTraceArtifactId("exec-1", newPin.recorder.id,
                                       newPin.recorder.build,
                                       newPin.profile.hash, newPin.traceSchema)
    let oldTid = deriveTraceArtifactId("exec-1", oldPin.recorder.id,
                                       oldPin.recorder.build,
                                       oldPin.profile.hash, oldPin.traceSchema)
    ck newTid == oldTid
    ck newTid.len > 0

    # 4. The whole session open — `openChain`, which pins the generation, the
    #    overlay version, the contract version and the recorder in one call.
    let newOpen = openChain(newStore, slug)
    let oldOpen = openChain(oldStore, slug)
    ck newOpen.outcome == oldOpen.outcome
    ck newOpen.outcome == ooOpened
    ck newOpen.session.generation == oldOpen.session.generation
    ck newOpen.session.traceSelectionVersion ==
       oldOpen.session.traceSelectionVersion
    ck newOpen.session.contractVersion == oldOpen.session.contractVersion
    ck newOpen.session.hasPin == oldOpen.session.hasPin
    ck newOpen.session.pin.recorder.build == oldOpen.session.pin.recorder.build
    ck newOpen.session.pin.traceSchema == oldOpen.session.pin.traceSchema

    # 5. The producer-side conformance validator, which keys into the row
    #    directly (`chain notin chains`, then `chains[chain]`).
    ck validateTree(withField) == validateTree(withoutField)
    ck validateTree(withField).len == 0

    removeDir withField
    removeDir withoutField

  test "CONTROL: the same reader does change when an optional member it knows moves":
    # Without this the equalities above are consistent with a comparison that
    # cannot fail. `recorder.version` is optional to the SAME reader, read by the
    # SAME call, out of the SAME row — so removing it exercises exactly the
    # machinery the new member was just shown not to disturb.
    let tree = buildDemo("ctl-optional")
    let slug = onlySlug(rawRegistry(tree))
    let before = decodeRecorderPin(rawRegistry(tree), slug)
    ck before.recorder.version.len > 0

    var reg = rawRegistry(tree)
    reg["chains"][slug]["recorder"].delete("version")
    writeRegistry(tree, reg)
    let after = decodeRecorderPin(rawRegistry(tree), slug)
    ck after.recorder.version != before.recorder.version
    ck after.recorder.version.len == 0
    # …and the members it did not touch are unmoved, so the difference is
    # attributable rather than merely present.
    ck after.recorder.build == before.recorder.build
    ck after.traceSchema == before.traceSchema
    removeDir tree

  test "CONTROL: a required member's VALUE reaches the published trace address":
    # The strongest form of the control: not "the reader notices", but "the
    # reader's answer moves the addresses of published containers". This is what
    # an unknown member must never be able to do.
    let tree = buildDemo("ctl-required")
    let slug = onlySlug(rawRegistry(tree))
    let before = decodeRecorderPin(rawRegistry(tree), slug)
    let beforeTid = deriveTraceArtifactId("exec-1", before.recorder.id,
                                          before.recorder.build,
                                          before.profile.hash,
                                          before.traceSchema)
    var reg = rawRegistry(tree)
    reg["chains"][slug]["traceSchema"] = %"ctfs/v99"
    writeRegistry(tree, reg)
    let after = decodeRecorderPin(rawRegistry(tree), slug)
    ck after.traceSchema == "ctfs/v99"
    let afterTid = deriveTraceArtifactId("exec-1", after.recorder.id,
                                         after.recorder.build,
                                         after.profile.hash, after.traceSchema)
    ck afterTid != beforeTid
    removeDir tree

  test "CONTROL: a required member's ABSENCE is refused by name":
    # The third direction. A reader that tolerated a missing required member
    # would also be a reader whose "identical behaviour" over an unknown one
    # proved nothing, because it would be tolerating everything.
    let tree = buildDemo("ctl-missing")
    let slug = onlySlug(rawRegistry(tree))
    var reg = rawRegistry(tree)
    reg["chains"][slug].delete("traceSchema")
    writeRegistry(tree, reg)
    var raised = false
    try:
      discard decodeRecorderPin(rawRegistry(tree), slug)
    except CatchableError as e:
      raised = true
      ck e.msg.contains("traceSchema")
    ck raised
    removeDir tree

  test "an unknown member is ignored wherever it sits, not only at the row":
    # §2.2's rule is about the registry, not about one nesting depth. A reader
    # that enumerated a sub-object's keys would break on a member added beside
    # `recorder.id` even though the row-level check passed, so both depths are
    # driven with a member no build in this tree knows anything about.
    let tree = buildDemo("add-unknown")
    let slug = onlySlug(rawRegistry(tree))
    let before = decodeRecorderPin(rawRegistry(tree), slug)
    let beforeChains = chains(localTree(tree))
    var reg = rawRegistry(tree)
    reg["chains"][slug]["notAFieldAnyBuildKnows"] = %"top"
    reg["chains"][slug]["recorder"]["alsoNotAField"] = %"nested"
    reg["chains"][slug]["profile"]["norThisOne"] = %42
    writeRegistry(tree, reg)
    let after = decodeRecorderPin(rawRegistry(tree), slug)
    ck after.recorder.id == before.recorder.id
    ck after.recorder.build == before.recorder.build
    ck after.recorder.version == before.recorder.version
    ck after.profile.name == before.profile.name
    ck after.profile.hash == before.profile.hash
    ck after.traceSchema == before.traceSchema
    ck chains(localTree(tree)) == beforeChains
    ck validateTree(tree).len == 0
    removeDir tree

# ───────────────────────────────────────────────────────────────────────────
suite "shard derivation takes the encoding as data":

  # ── THE PUBLISHED HEX LAYOUT IS THE ACCEPTANCE CRITERION ──────────────────
  #
  # `shardKeyFor("hex", …)` has to be byte-for-byte what the function it replaced
  # produced, because every shard path Aztec has published was derived that way
  # and is still addressable (Publishing-And-Caching.md §6.1). The replaced
  # function is restated here as an ORACLE — the literal three lines it was — so
  # the equality is against the old algorithm rather than against a remembered
  # description of it.
  #
  # JUSTIFYING THE ORACLE, since the workspace policy asks about stand-ins: this
  # is not a mock of anything. It is the previous implementation, copied verbatim
  # from `contract/shards.nim` as it stood at the parent commit, used as the
  # reference an equivalence claim needs. Nothing under test calls it, and the
  # whole-tree half of the same claim is measured elsewhere by publishing the
  # Aztec captures before and after and diffing every object path and byte.

  func oldHexShard(hashHex: string): string =
    var h = hashHex
    if h.startsWith("0x"): h = h[2 .. ^1]
    if h.len < 4: h = h & repeat('0', 4 - h.len)
    h[0 .. 3]

  test "for hex it is exactly the algorithm it replaced, quirks included":
    # A corpus that reaches both quirks and both lengths the captures contain.
    let corpus = @[
      "0x0000000000000000000000000000000000000000000000000000000000000000",
      "0x2b0f32c62a6d5b0a4e6a0b3c1d8e9f70112233445566778899aabbccddeeff00",
      "0xdeadbeef", "0xdead", "0xdea", "0xd", "0x", "",
      "deadbeefcafe",                       # no prefix at all
      "0x0000dead",                         # leading zeroes are not special
      "0xABCDEF0123",                       # uppercase is NOT normalised here
      "0x1", "0x12", "0x123", "0x1234"]     # every length below and at the width
    for id in corpus:
      ck shardKeyFor("hex", id) == oldHexShard(id)
    # …and the two quirks stated as their own assertions, so a reader can see
    # WHICH properties the equality above is carrying.
    ck shardKeyFor("hex", "0xdeadbeef") == "dead"      # the `0x` is stripped
    ck shardKeyFor("hex", "deadbeef") == "dead"        # …only if present
    ck shardKeyFor("hex", "0xd") == "d000"             # right-padded to 4
    ck shardKeyFor("hex", "0x") == "0000"
    ck shardKeyFor("hex", "").len == 4
    # NOTHING IS LOWERCASED. Per-encoding case handling is a separate step, and
    # this derivation must not pre-empt it: an EIP-55 address's checksum lives in
    # its case, and base58 and base64url are case-significant outright.
    ck shardKeyFor("hex", "0xABcd1234") == "ABcd"

  test "every member of the closed set has a rule and derives one":
    # A member with no rule would be a token a producer could declare and a chain
    # could publish under, meeting the derivation for the first time in
    # production. The build already refuses one; this refuses it behaviourally
    # too, and covers the pathSafe member set in the same sweep.
    var derived, refused: seq[string]
    for token in identifierEncodingIds():
      let rule = identifierEncodingRule(token)
      ck rule.pad.len == 1
      try:
        let key = shardKeyFor(token, "0123456789abcdef")
        ck key.len == ShardWidth
        ck rule.pathSafe
        derived.add token
      except ValueError:
        ck not rule.pathSafe
        refused.add token
    # SPELLED OUT RATHER THAN COUNTED: a count stays green when the unshardable
    # member is a different one. `base64`'s alphabet contains `/`, which ends a
    # path segment, so it is declarable and not shardable — recorded rather than
    # closed, because choosing the path-safe re-encoding is not this repository's
    # decision to make.
    ck refused == @["base64"]
    ck derived.len == identifierEncodingIds().len - 1

  test "a token outside the closed set refuses rather than falling back to hex":
    # The whole point. A derivation that met an unknown token and shrugged into
    # hex would be the assumption this seam removed, reintroduced at the one place
    # it cannot be seen.
    for bogus in ["base32", "Hex", "HEX", "0x", "", "hex "]:
      var raised = false
      try: discard shardKeyFor(bogus, "0xdeadbeef")
      except ValueError as e:
        raised = true
        ck e.msg.contains("not an identifier encoding")
      ck raised

  test "the non-hex encodings shard on their own alphabet, not on hex's":
    # base58 (Solana) — whole string is payload, case preserved.
    ck shardKeyFor("base58", "5KJvsngHeMpm884wtkJNzQGaCErckhHJBGFsvd3VyK5q") == "5KJv"
    # base64url (TON) — `EQ`/`UQ` prefix is payload, not decoration.
    ck shardKeyFor("base64url", "EQCcrOCzgnZKgVSNNjjOQhRRsRWaiMEB-4hPl-PtLoL8Mh1x") ==
       "EQCc"
    ck shardKeyFor("base64url", "UQCcrOCzgnZKgVSNNjjOQhRRsRWaiMEB-4hPl-PtLoL8Mh1x") ==
       "UQCc"
    # bech32 / bech32m — the payload begins after the LAST `1`, so a whole chain
    # does not land in one bucket. THIS IS THE ARM THAT WOULD CATCH THE OBVIOUS
    # WRONG ANSWER: sharding the raw string gives `addr` and `fuel` for every
    # address on those chains.
    ck shardKeyFor("bech32", "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jcacq5z") ==
       "qx2f"
    ck shardKeyFor("bech32m", "fuel1q9k7yfcp4hmrmj3xkqnwvlvmv6sfdqe2lgvkujgcwvn") ==
       "q9k7"
    ck not shardKeyFor("bech32", "addr1qx2fxv2umyhttkxyxp8").startsWith("addr")
    ck not shardKeyFor("bech32m", "fuel1q9k7yfcp4hmrmj3xkqn").startsWith("fuel")
    # ss58 (Substrate) — base58 alphabet, whole string is payload.
    ck shardKeyFor("ss58", "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY") == "5Grw"
    # decimal — a rule exists even though no sharded kind can be decimal today.
    ck shardKeyFor("decimal", "12345") == "1234"
    ck shardKeyFor("decimal", "7") == "7000"
    # And the pad is the ALPHABET's zero digit, not `0`, which is not a base58 or
    # a bech32 digit at all.
    ck shardKeyFor("base58", "5K") == "5K11"
    ck shardKeyFor("bech32", "addr1q") == "qqqq"
    ck shardKeyFor("base64url", "EQ") == "EQAA"

  test "a case-significant identifier keeps its case through derivation":
    # Lowercasing is right for a hex key and DESTROYS base58 and base64url. The
    # derivation slices and pads and normalises nothing, which is why it could
    # land before per-encoding case handling did.
    ck shardKeyFor("base58", "5KJvsngHeMpm884wtkJNzQGaCErckhHJBGFsvd3VyK5q") !=
       shardKeyFor("base58", "5kjvsnghempm884wtkjnzqgacerckhhjbgfsvd3vyk5q")
    ck shardKeyFor("base64url", "EQCcrOCz") == "EQCc"
    ck shardKeyFor("base64url", "eqccrocz") == "eqcc"

  test "traceShards is NOT encoding-parameterised, and the set says why":
    # A trace artifact id is content-addressed by THIS pipeline, so no chain's
    # declaration may re-address it. The shared file states the same ruling from
    # the other end: `traceArtifactId` is deliberately not an identifier kind.
    ck not isIdentifierKind("traceArtifactId")
    ck not isIdentifierKind("codeHash")
    ck not isIdentifierKind("bundleHash")
    let tid = "abcd1234ef"
    let sh = traceShards(tid)
    ck sh.a == "ab"
    ck sh.b == "cd"
    # The signature carries no encoding, which is what stops a caller passing one.
    ck readFile(RepoRoot / "src/blocktracer/contract/shards.nim").contains(
      "func traceShards*(tid: string): tuple[a, b: string]")

  test "an omitted kind refuses; an absent declaration is the §6.1 fallback":
    # TWO DIFFERENT ABSENCES WITH TWO DIFFERENT ANSWERS, and conflating them is
    # the defect this arm exists to catch.
    #
    # A row that declares `{address: ss58}` has SAID something about its
    # transactions — that it cannot describe them as an encoded string, which is
    # Substrate's `blockIndex` case — so asking for a transaction shard refuses.
    let partial = chainIdentifierEncoding({"address": "ss58"})
    ck partial.declared
    ck partial.encodingFor(KindAddress) == "ss58"
    var raised = false
    try: discard partial.encodingFor(KindTransaction)
    except ValueError as e:
      raised = true
      ck e.msg.contains("transaction")
    ck raised

    # A row with NO member at all is a tree published before the member existed,
    # and its shard paths are hex and still addressable. That resolves, and says
    # it was not declared.
    let legacy = parseChainIdentifierEncoding(parseJson("""{"traceSchema":"x"}"""))
    ck not legacy.declared
    ck legacy.encodingFor(KindTransaction) == "hex"
    ck legacy.encodingFor(KindAddress) == "hex"
    ck LegacyUndeclaredEncoding == "hex"
    # …and a declared row says so, which is what makes the two distinguishable.
    let declared = parseChainIdentifierEncoding(
      parseJson("""{"identifierEncoding":{"transaction":"hex"}}"""))
    ck declared.declared
    ck declared.encodingFor(KindTransaction) == "hex"

    # A member that is PRESENT and wrong is refused rather than read as hex: the
    # compatibility window is for absence, not for garbage.
    for bad in ["""{"identifierEncoding":{"transaction":"base32"}}""",
                """{"identifierEncoding":{"traceArtifactId":"hex"}}""",
                """{"identifierEncoding":"hex"}""",
                """{"identifierEncoding":{"transaction":7}}"""]:
      var refused = false
      try: discard parseChainIdentifierEncoding(parseJson(bad))
      except ValueError: refused = true
      ck refused

# ───────────────────────────────────────────────────────────────────────────
suite "the encoding has exactly one source: the registry row":

  # The milestone's `test_the_encoding_has_exactly_one_source` and
  # `test_non_hex_identifiers_round_trip_through_the_shard_path`, measured
  # together because they are the same measurement from two directions: the
  # PRODUCER's path and the CLIENT's recomputation of it have to move together
  # when the declaration moves, and to agree when it does not.
  #
  # NO MOCKS. The producer is the real demo generator over a real temporary tree;
  # the client is the real `openChain` + the real `paths.nim`, reading the real
  # registry bytes off disk.

  test "the client recomputes the producer's path, for hex, from the tree":
    let tree = buildDemo("onesource-hex")
    let slug = onlySlug(rawRegistry(tree))
    let opened = openChain(localTree(tree), slug)
    ck opened.outcome == ooOpened
    ck opened.session.identifierEncoding.declared
    ck opened.session.identifierEncoding.encodingFor(KindTransaction) == "hex"

    # Every transaction the producer published, recomputed by the client and
    # required to EXIST. A path that resolves is the only evidence that matters:
    # comparing two strings both derived from one function would pass if the
    # function were wrong.
    var checked = 0
    for path in walkDirRec(tree / "d" / slug / "tx", relative = true):
      if not path.endsWith(".json"): continue
      let txHash = path.splitFile.name
      let rel = txFactsPath(slug, txHash, opened.session.identifierEncoding)
      ck fileExists(tree / rel)
      inc checked
    # A FLOOR, because a walk that found no transaction would satisfy the loop
    # above perfectly.
    ck checked >= 4
    removeDir tree

  test "…and the derivation follows the declaration when the declaration moves":
    # The control the milestone asks for: with the registry's declared encoding
    # ALTERED, the client computes a different path — so the derivation is
    # genuinely reading the row rather than agreeing with it by coincidence.
    let tree = buildDemo("onesource-moved")
    let slug = onlySlug(rawRegistry(tree))
    let before = openChain(localTree(tree), slug)
    ck before.outcome == ooOpened

    var txHash = ""
    for path in walkDirRec(tree / "d" / slug / "tx", relative = true):
      if path.endsWith(".json"): txHash = path.splitFile.name
    ck txHash.len > 0
    let beforePath = txFactsPath(slug, txHash, before.session.identifierEncoding)
    ck fileExists(tree / beforePath)

    # `base58` over the same `0x`-prefixed string keys differently for a reason
    # that is the whole seam: base58 has no `0x` to strip, so the `0x` is payload.
    var reg = rawRegistry(tree)
    reg["chains"][slug]["identifierEncoding"]["transaction"] = %"base58"
    writeRegistry(tree, reg)
    let after = openChain(localTree(tree), slug)
    ck after.outcome == ooOpened
    ck after.session.identifierEncoding.encodingFor(KindTransaction) == "base58"
    let afterPath = txFactsPath(slug, txHash, after.session.identifierEncoding)
    ck afterPath != beforePath
    ck shardKeyFor("base58", txHash) == txHash[0 ..< 4]
    # …and the object is NOT there, which is the point: a client that read the
    # declaration honestly asks for the path the declaration implies, and a
    # producer that declared one thing and keyed another is caught by exactly this.
    ck not fileExists(tree / afterPath)
    removeDir tree

  test "a non-hex chain round-trips: producer derives, client recomputes":
    # THE NON-HEX END TO END. The tree is built by the real producer and then its
    # registry is re-declared as base58 and its sharded objects MOVED to the paths
    # that declaration implies — which is exactly what a base58 producer would
    # have written. The client then reads the registry and finds every one of them
    # without being told anything.
    #
    # Moving the objects rather than adding a base58 chain to the generator is
    # deliberate: a second synthetic chain would be a producer written for this
    # test, and the thing under test is whether the CLIENT's recomputation follows
    # the declaration. The identifiers are the real ones the producer minted.
    let tree = buildDemo("roundtrip-b58")
    let slug = onlySlug(rawRegistry(tree))
    var reg = rawRegistry(tree)
    reg["chains"][slug]["identifierEncoding"]["transaction"] = %"base58"
    reg["chains"][slug]["identifierEncoding"]["address"] = %"base58"
    writeRegistry(tree, reg)

    let opened = openChain(localTree(tree), slug)
    ck opened.outcome == ooOpened
    let enc = opened.session.identifierEncoding
    ck enc.encodingFor(KindTransaction) == "base58"
    ck enc.encodingFor(KindAddress) == "base58"

    # Re-shard the transaction facts the way a base58 producer would have.
    var moved = 0
    var hashes: seq[string]
    for path in walkDirRec(tree / "d" / slug / "tx", relative = true):
      if path.endsWith(".json"): hashes.add path.splitFile.name
    ck hashes.len >= 4
    for h in hashes:
      let old = tree / "d" / slug / "tx" / shardKeyFor("hex", h) / (h & ".json")
      let want = tree / txFactsPath(slug, h, enc)
      ck fileExists(old)
      ck old != want
      createDir want.parentDir
      moveFile(old, want)
      inc moved
    ck moved == hashes.len

    # THE CLIENT'S OWN RECOMPUTATION, through the real SDK read rather than
    # through a path comparison: `transaction` builds the path from the session
    # and fetches it.
    let store = localTree(tree)
    for h in hashes:
      let r = transaction(store, opened.session, h)
      if r.outcome != roFound:
        checkpoint("base58 round trip failed for " & h & ": " & $r.outcome)
      ck r.outcome == roFound
      ck r.view.hash == h
    # CONTROL: the hex derivation of the same identifiers now resolves to
    # nothing, so the successes above are attributable to the declaration rather
    # than to both layouts happening to exist.
    var hexStillThere = 0
    for h in hashes:
      if fileExists(tree / "d" / slug / "tx" / shardKeyFor("hex", h) /
                    (h & ".json")): inc hexStillThere
    ck hexStillThere == 0
    removeDir tree

  test "the validator reads the tree's declaration, not its own opinion":
    # A validator holding an opinion about the encoding could not catch a producer
    # that declared one thing and keyed another: it would agree with whichever of
    # them shared its opinion. So the registry is re-declared WITHOUT moving the
    # objects, and the walk must now report the transaction objects missing.
    let tree = buildDemo("validator-reads")
    ck validateTree(tree).len == 0
    let slug = onlySlug(rawRegistry(tree))
    var reg = rawRegistry(tree)
    reg["chains"][slug]["identifierEncoding"]["transaction"] = %"base58"
    writeRegistry(tree, reg)
    let errs = validateTree(tree)
    if errs.len == 0:
      checkpoint("the validator did not notice the re-declared encoding")
    ck errs.len > 0
    var namedADanglingTx = false
    for e in errs:
      if e.contains("/tx/") and e.contains("dangling"): namedADanglingTx = true
    ck namedADanglingTx
    removeDir tree

# ───────────────────────────────────────────────────────────────────────────
suite "the boundary: who names the member, and who still derives from the string":

  # ── WHY A SOURCE SCAN IS THE ONLY WAY TO ASSERT THIS ──────────────────────
  #
  # "Exactly these files know about the member" is a claim about the whole tree,
  # and no behavioural test can establish it: a consumer that read the member and
  # happened to agree with the old answer today would pass every arm above. The
  # boundary IS the deliverable — the step that reaches the published hash index
  # has to land alone, with a compatibility window — so it is asserted as what it
  # is.
  #
  # ── WHAT THESE ARMS USED TO SAY, AND WHY THEY SAY SOMETHING ELSE NOW ──────
  #
  # They used to assert that NOTHING read `identifierEncoding`, which was true
  # while only the declaration had landed. Shard-path derivation now reads it, so
  # that form went red, which is what it was for. It has been REPLACED rather than
  # deleted, and replaced with an EQUALITY rather than a widened allowlist:
  #
  #   * every file that names the member is enumerated, with the reason it does
  #   * the enumeration is compared for EQUALITY against a sweep, so an
  #     unexpected consumer fails AND so does an expected one that stopped
  #   * the sweep keeps its per-directory population floors, so an emptied scan
  #     is still not a green
  #   * the size of each expected set is asserted, so it cannot drift upward one
  #     entry at a time
  #
  # An allowlist that grew whenever something new appeared in it would be a list
  # nobody checks. This one cannot grow without the number beside it changing.
  #
  # ── AND THE TWO SITES THAT STILL DERIVE FROM THE STRING ───────────────────
  #
  # The hash index and the capture tooling. Those are asserted to be UNCHANGED —
  # still hex-shaped — because they are later steps and because a check that only
  # watched the closed half of the seam would report the open half as closed. They
  # are expected to go red in their turn.

  const
    Member = "identifierEncoding"
    SourceExt = [".nim", ".mjs", ".js", ".ts", ".sh"]

    SrcExpected = [
      # The two registry PRODUCERS, which write the member…
      "src/blocktracer/chain/ingest.nim",
      "src/blocktracer/demo/generator.nim",
      # …the module that builds, validates and reads it, over the closed set…
      "src/blocktracer/contract/identifier_encoding.nim",
      # …the ONE derivation, which takes the token as a parameter…
      "src/blocktracer/contract/shards.nim",
      # …the path builders, which name the kind each segment comes from…
      "src/blocktracer_client/paths.nim",
      # …the SDK facade's own documentation of that signature…
      "src/blocktracer_client_paths.nim",
      # …the session, which pins the chain's declaration like the generation…
      "src/blocktracer_client/session.nim",
      # …the entity reader, which hands the session's declaration to the paths…
      "src/blocktracer_client/entities.nim",
      # …and the validator, which reads the declaration out of the tree it is
      # validating rather than holding an opinion of its own.
      "src/blocktracer/validator.nim"]

    ClientExpected = [
      # The browser's search bootstrap, which reads the member out of the registry
      # response it already fetches — Search-And-Routing.md §5's "two requests"
      # is only true if the client recomputes the producer's path.
      "client/searchboot/searchboot.nim",
      # The explorer's reader and the two view models that build a sharded path.
      "client/src/reader.nim",
      "client/src/viewmodel/address_vm.nim",
      "client/src/viewmodel/chain_vm.nim"]

    ToolsExpected = [
      # The JavaScript half's selftest, and still nothing else: the capture
      # tooling follows the hash index, not the derivation.
      "tools/chain/identifier-encoding-selftest.mjs"]

  let inRepo = block:
    ## The population is GIT'S ANSWER, not a heuristic over filenames.
    ##
    ## This used to prune generated output by a same-stem rule — a `.js` beside a
    ## `.nim` of the same name is `nim js` output — which was measured against the
    ## case it hit (`client/tests/test_searchboot.js`) and walks straight past a
    ## bundle whose output is not named after its source. `client/Justfile`'s
    ## `search-bundle` compiles `searchboot/searchboot.nim` to
    ## `searchboot/search.js`: different stem, so `search.js` was swept as source
    ## and FAILED THIS SUITE — and therefore `just test` — for anybody who had
    ## built the bundle, while a clean checkout and CI never saw it because the
    ## file is gitignored (`.gitignore:73`). A gate that is green where it is
    ## checked and red where it is used is worse than one that is merely wrong.
    ##
    ## `.gitignore` is where "this is generated" is already written down, and it is
    ## kept current by whoever adds the recipe. Tracked PLUS
    ## untracked-and-not-ignored is the right population: the second half is what
    ## catches a consumer that has been written and not yet committed, which is
    ## when catching it is most useful. `ci/test/client-sdk-boundary.sh` derives
    ## its population the same way and for the same reason.
    var s = initHashSet[string]()
    for args in [@["ls-files"], @["ls-files", "--others", "--exclude-standard"]]:
      let (outp, code) = execCmdEx("git -C " & quoteShell(RepoRoot) & " " &
                                   args.join(" "))
      doAssert code == 0,
        "git " & args.join(" ") & " failed in " & RepoRoot & " (exit " & $code &
        "): " & outp & " — this suite's population is git's answer, and a sweep " &
        "that cannot be enumerated must refuse rather than report an empty one."
      for line in outp.splitLines:
        if line.len > 0: s.incl line
    s

  proc isRepoSource(top, rel: string): bool =
    ## Whether a swept path counts as this repository's source.
    ##
    ## THE DIRECTORY PRUNE IS SEGMENT-ANCHORED, and that is what makes it the same
    ## rule the JavaScript half applies rather than merely the same list of names.
    ## A bare `rel.contains("dist/")` also matches `redist/`, `subdist/` and every
    ## other directory whose name happens to END in `dist` — while the JS half
    ## prunes by exact directory NAME (`SKIP_DIR.includes(e.name)`) and tests its
    ## paths for `/dist/`, so it does not. MEASURED: a single
    ## `client/src/redist/x.mjs` put the two populations at 102 here and 103
    ## there, and two halves that disagree about WHICH FILES they swept cannot be
    ## compared — the whole point of the identical rule is that a disagreement
    ## between them is a real disagreement. Anchoring both ends of each segment
    ## closes it in the direction that keeps genuine source in the population.
    if rel.splitFile.ext notin SourceExt: return false
    let anchored = "/" & rel
    if anchored.contains("/node_modules/") or anchored.contains("/dist/") or
       anchored.contains("/nimcache/"): return false
    (top & "/" & rel) in inRepo

  proc namingFilesUnder(top: string): seq[string] =
    ## Every source file under `top` that names the member, swept.
    for rel in relFiles(RepoRoot / top):
      if not isRepoSource(top, rel): continue
      if readFile(RepoRoot / top / rel).contains(Member):
        result.add top & "/" & rel
    result.sort()

  proc sweptCount(top: string): int =
    for rel in relFiles(RepoRoot / top):
      if isRepoSource(top, rel): inc result

  test "under src/, exactly the enumerated producers and consumers name it":
    let found = namingFilesUnder("src")
    var want = @SrcExpected
    want.sort()
    if found != want:
      checkpoint("swept: " & found.join(", "))
      checkpoint("expected: " & want.join(", "))
    ck found == want
    # THE SIZE, so the list cannot grow an entry at a time with the equality
    # above quietly updated to match. A number in the test is a number a reviewer
    # sees move.
    ck SrcExpected.len == 9
    for rel in SrcExpected: ck fileExists(RepoRoot / rel)

  test "under client/ and tools/, the same equality behind population floors":
    # NAMING ALONE WAS MEASURED LEAKING, which is why the equality is against a
    # sweep: a consumer planted in `client/src/viewmodel/chain_vm.nim`, next door
    # to a named file, once landed with every arm in this file green. And SWEEPING
    # ALONE is an empty-set green, which is why the population is asserted too —
    # per directory, so an emptied sweep of one cannot hide behind the other.
    for (top, expected, floor) in [("client", @ClientExpected, 80),
                                   ("tools", @ToolsExpected, 100)]:
      let scanned = sweptCount(top)
      if scanned < floor:
        checkpoint(top & "/: swept " & $scanned & " source file(s), floor " &
                   $floor & " — an emptied sweep is not a green")
      ck scanned >= floor
      let found = namingFilesUnder(top)
      var want = expected
      want.sort()
      if found != want:
        checkpoint(top & "/ swept: " & found.join(", "))
        checkpoint(top & "/ expected: " & want.join(", "))
      ck found == want
    ck ClientExpected.len == 4
    ck ToolsExpected.len == 1
    for rel in @ClientExpected & @ToolsExpected: ck fileExists(RepoRoot / rel)

  test "the producers publish the value they derive with, not a second one":
    # A producer that called the declaration helper twice — once to publish and
    # once to key — would be two decisions that could drift, and the drift would
    # be invisible: the tree would validate against itself. Each producer names
    # the declaration ONCE as the thing it publishes, and derives from a variable
    # or a function rather than from a second call.
    #
    # And neither spells the tokens itself: an inline object of tokens would be a
    # second closed set, and the second one is always the one that goes stale.
    # COUNTED OVER CODE AND NOT OVER COMMENTS. Both producers explain the
    # one-decision rule in prose beside it, and a naive text count of
    # `hexIdentifierEncoding()` therefore counts the explanation as a second
    # decision — which would make the arm fail for saying the right thing.
    proc codeOccurrences(src, needle: string): int =
      for line in src.splitLines:
        if line.strip.startsWith("#"): continue
        result += line.count(needle)

    let ingest = readFile(RepoRoot / "src/blocktracer/chain/ingest.nim")
    ck ingest.contains("identifier_encoding")
    ck ingest.contains("let identifierEncoding = hexIdentifierEncoding()")
    ck ingest.contains(
      "\"identifierEncoding\": identifierEncoding.identifierEncodingNode()")
    ck not ingest.contains("\"identifierEncoding\": {")
    ck codeOccurrences(ingest, "hexIdentifierEncoding()") == 1
    # …and it derives from the variable, never from a fresh call.
    ck codeOccurrences(ingest, "shardKeyFor(txEncoding,") >= 1
    ck codeOccurrences(ingest, "shardKeyFor(addrEncoding,") >= 1

    let gen = readFile(RepoRoot / "src/blocktracer/demo/generator.nim")
    ck gen.contains("identifier_encoding")
    ck gen.contains(
      "\"identifierEncoding\": demoIdentifierEncoding().identifierEncodingNode()")
    ck not gen.contains("\"identifierEncoding\": {")
    ck codeOccurrences(gen, "hexIdentifierEncoding()") == 1
    ck codeOccurrences(gen, "shardKeyFor(txEncoding,") >= 1
    ck codeOccurrences(gen, "shardKeyFor(addrEncoding,") >= 1

  test "THE STRING-DERIVING SITES ARE STILL THERE, and are the ones named":
    # The seam is half closed, and a boundary check that only watched the closed
    # half would report it shut. These two are asserted to be UNCHANGED so that
    # the day either one is widened, this arm goes red and its comment is read.
    #
    # The hash index: `hexToBytes` parses hex pairs, so a base58 or bech32
    # identifier has no representation in it at all, and `stripHex` lowercases
    # unconditionally, which destroys the case-significant encodings. It is a
    # PUBLISHED self-describing wire format, so widening it is a migration of
    # every published shard plus a compatibility window
    # (Publishing-And-Caching.md §6.1, §6.2).
    let hashshard = readFile(RepoRoot / "src/blocktracer/contract/hashshard.nim")
    ck not hashshard.contains(Member)
    ck hashshard.contains("parseHexInt")
    ck hashshard.contains("toLowerAscii")

    # The capture tooling: two literal `0x` filters over published directory
    # entries. It enumerates the tree the hash index keys, so it follows the
    # index rather than the derivation — a filter widened ahead of the index
    # would enumerate entities the index cannot key.
    let entities = readFile(RepoRoot / "tools/capture/lib/entities.mjs")
    ck not entities.contains(Member)
    ck entities.count("startsWith(\"0x\")") == 2

  test "and the derivation itself holds no table of its own":
    # `shards.nim` reads the per-encoding rule from the shared file through
    # `identifierEncodingRule`. If it grew a `case` over the tokens instead, the
    # set would be closed in the data and re-opened in the derivation.
    let sh = readFile(RepoRoot / "src/blocktracer/contract/shards.nim")
    ck sh.contains("identifierEncodingRule(encoding)")
    for token in identifierEncodingIds():
      if token == "hex": continue   # named in prose, as the published layout
      ck not sh.contains("\"" & token & "\"")

expectCount(343)
