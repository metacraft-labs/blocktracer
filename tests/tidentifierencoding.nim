## The registry's per-chain identifier-encoding declaration — Configuration.md
## §2.1 (the schema) and §2.2 (the additive rule).
##
## ## What this suite is about
##
## An identifier's encoding is stated as DATA in the published registry
## (`chains[<slug>].identifierEncoding`) rather than being inferred from the
## string, and **shard-path derivation reads it, and so does case handling**:
## `contract/shards.nim` takes the token as a parameter, the producers hand it the
## value they publish, and the validator and the client read it back out of the
## row; the per-encoding `case` rule beside it is what every site that KEYS an
## identifier now folds by, in place of the one unconditional `toLowerAscii` the
## hash index used to apply to all eight members.
##
## ONE site still derives from the string, deliberately: the §5 hash index's
## hex-pair parser. That is a published wire format, so it is a migration plus a
## compatibility window and lands alone. The capture tooling no longer derives at
## all — it enumerates the shard directories the producer wrote.
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
## Suite 5 is the derivation. Suite 6 is CASE, per encoding: the key form folded
## where a fold is a normalisation, the display form preserved where a fold would
## destroy a checksum, uniformity where BIP-173 requires it, and — in the same run
## — the defect's own rule applied to the same identifiers and shown to corrupt
## them, so the assertions are evidence rather than an inert comparison.
##
## The last suite states the boundary mechanically, as an EQUALITY between an
## enumerated set of files and a swept one, behind population floors, over two
## sweeps: who reads the registry member and who reads the case rule. The RULE it
## sweeps with is `tools/chain/identifier-encoding-boundary.json`, read by both
## this suite and its JavaScript half, because it used to be spelled out in both
## and compared to nothing. Its last test RUNS that half and requires the two
## swept populations to be identical, which is the check a shared rule cannot
## make.
##
## ## NO MOCKS. TWO STAND-INS, BOTH JUSTIFIED HERE
##
## Per the workspace policy every mock must be justified in the file's header.
## There are no mocks: the registries under test are written by the REAL producers
## — `generate` and `ingestSnapshot` — onto a real temporary directory, and the
## readers under test are the real SDK, the real decoder and the real validator.
## Ground truth is read back INDEPENDENTLY with `std/json` from the bytes on disk
## rather than through the module that wrote them, so the writer is never its own
## oracle. The committed mainnet capture is the ingest producer's subject for the
## reason `tchainsnapshot.nim` gives: it is a snapshot nobody in this repository
## wrote.
##
## Two functions are defined in this file and are neither mocks nor stubs; both
## are REFERENCE IMPLEMENTATIONS that an equivalence claim needs, and nothing
## under test calls either of them:
##
##   * `oldHexShard` — the literal three lines `contract/shards.nim` held before
##     the derivation was parameterised, copied verbatim, so "the published hex
##     layout is unchanged" is measured against the old ALGORITHM rather than
##     against a remembered description of it.
##   * `globalFold` — the defect: `stripHex`'s `h.toLowerAscii`, one
##     normalisation for every identifier of every encoding. It is the CONTROL
##     the per-encoding arms are graded against, so that "the case survived" is
##     shown to be a property of the declared rule rather than of a derivation
##     that happens to fold nothing.
##
## The whole-tree half of the byte-identity claim is measured elsewhere, by
## publishing every committed capture before and after and diffing every object
## path and byte.

import std/[unittest, os, json, strutils, algorithm, osproc, sets]

import ../src/blocktracer_client
import ../src/blocktracer_client/paths
import ../src/blocktracer/contract/identifier_encoding
import ../src/blocktracer/contract/hashshard
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

  test "for hex it is the algorithm it replaced, on every identifier ever published":
    # A corpus that reaches both quirks and both lengths the captures contain.
    # EVERY MEMBER IS LOWERCASE, and that is the point rather than an oversight:
    # the equality is against the algorithm `hexShard` was, and the ONE input on
    # which the two now differ is an uppercase hex digit, which is asserted
    # separately below with the reason. The captures contain none — 386 distinct
    # `0x`-hex literals in the testnet capture, 990 in the mainnet one, zero
    # uppercase in either — so this corpus is the population that was published.
    let corpus = @[
      "0x0000000000000000000000000000000000000000000000000000000000000000",
      "0x2b0f32c62a6d5b0a4e6a0b3c1d8e9f70112233445566778899aabbccddeeff00",
      "0xdeadbeef", "0xdead", "0xdea", "0xd", "0x", "",
      "deadbeefcafe",                       # no prefix at all
      "0x0000dead",                         # leading zeroes are not special
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

  test "THE ONE DIFFERENCE FROM THE REPLACED ALGORITHM: hex folds for its key":
    # `hexShard` and the derivation that first replaced it normalised NOTHING, so
    # an uppercase hex identifier keyed under an uppercase shard. That is wrong
    # for hex and the reason is EIP-55: `0xAB…` and `0xab…` are ONE account, so
    # they have to name one object, and a client that arrives with either
    # spelling has to compute the shard the producer wrote. Per-encoding case
    # handling is what makes that true, and this is where it is visible.
    ck shardKeyFor("hex", "0xABcd1234") == "abcd"
    ck oldHexShard("0xABcd1234") == "ABcd"
    ck shardKeyFor("hex", "0xABcd1234") != oldHexShard("0xABcd1234")
    # Both spellings of one account key together, which is the property.
    ck shardKeyFor("hex", "0xABcd1234") == shardKeyFor("hex", "0xabcd1234")
    # …and the prefix is recognised however it was written, because the fold
    # happens BEFORE the strip. `0X` is the same account announced by a tool that
    # shouted; keying its `0X` as payload would put it in a shard of its own.
    ck shardKeyFor("hex", "0XABcd1234") == "abcd"
    ck oldHexShard("0XABcd1234") == "0XAB"
    # NO OTHER MEMBER MOVED. The fold is per encoding, so the four
    # case-significant members are exactly where they were.
    for token in ["base58", "base64url", "ss58"]:
      ck shardKeyFor(token, "AbCdEfGh") == "AbCd"

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
    # Lowercasing is right for a hex key and DESTROYS base58 and base64url, so
    # the fold is PER ENCODING: these members declare `keyForm: preserve` and the
    # derivation honours it. Two spellings are two identifiers here, and a
    # derivation that mapped them together would resolve one of them to the
    # other's object.
    ck shardKeyFor("base58", "5KJvsngHeMpm884wtkJNzQGaCErckhHJBGFsvd3VyK5q") !=
       shardKeyFor("base58", "5kjvsnghempm884wtkjnzqgacerckhhjbgfsvd3vyk5q")
    ck shardKeyFor("base64url", "EQCcrOCz") == "EQCc"
    ck shardKeyFor("base64url", "eqccrocz") == "eqcc"
    # …and the CONTROL, in the same run: hex, which declares `keyForm: lower`,
    # maps its two spellings together. So "the case survived" is attributable to
    # the declared rule rather than to the derivation folding nothing at all,
    # which is what it used to do.
    ck shardKeyFor("hex", "0xABCDEF01") == shardKeyFor("hex", "0xabcdef01")

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
suite "case handling is stated per encoding, not applied globally":

  # ── THE MILESTONE'S `test_normalisation_is_per_encoding_not_global` ────────
  #
  # One normalisation applied to every encoding is the silently-wrong outcome
  # this suite exists to prevent, and it was the state of the tree: the hash
  # index's `stripHex` did `h.toLowerAscii` unconditionally, for every
  # identifier of every encoding. That is right for hex and WRONG for four of
  # the six blocked chains — base58 and base64url are case-significant, so a
  # fold names a different identifier; bech32 requires a UNIFORM case rather
  # than an arbitrary one; and an EIP-55 hex address carries its checksum IN ITS
  # CASE, so its display form and its key form are two different strings.
  #
  # THE CONTROL IS IN THE SAME RUN, and it is what makes these assertions
  # evidence: the defect's own rule — one global lowercase — is applied to the
  # same identifiers and shown to corrupt them. An equality that cannot fail is
  # not a measurement.
  #
  # NO MOCKS. Every subject is either a literal identifier of the shape
  # Search-And-Routing.md §2's table gives for that chain, or a real tree built
  # by the real producer.

  func globalFold(id: string): string = id.toLowerAscii
    ## THE DEFECT, RESTATED AS A CONTROL. This is `stripHex`'s fold, minus the
    ## prefix strip: one `toLowerAscii` for every identifier of every encoding.
    ## It is not a mock of anything — nothing under test calls it — it is the
    ## previous behaviour, kept so the arms below can show what it did.

  test "every member declares a case rule, and the two cross-field rules hold":
    # The build already refuses a member without one; this refuses it
    # behaviourally too, and states the invariants over the REAL set rather than
    # over an example.
    var folding, preserving: seq[string]
    for token in identifierEncodingIds():
      let rule = identifierCaseRule(token)
      ck rule.keyForm in ["lower", "preserve"]
      ck rule.displayForm in ["preserve", "key"]
      # A fold on a case-significant alphabet is not a normalisation.
      if rule.significant: ck rule.keyForm == "preserve"
      # "the display form is the key form" beside a key form that preserves
      # states nothing.
      if rule.displayForm == "key": ck rule.keyForm != "preserve"
      if rule.keyForm == "lower": folding.add token else: preserving.add token
    # SPELLED OUT RATHER THAN COUNTED: a count stays green when the folding
    # member is a different one, and WHICH members fold is the whole claim.
    ck folding == @["hex", "bech32", "bech32m"]
    ck preserving == @["base58", "base64", "base64url", "ss58", "decimal"]
    # The four that are case-significant are exactly the four a global fold
    # would have destroyed.
    var significant: seq[string]
    for token in identifierEncodingIds():
      if identifierCaseRule(token).significant: significant.add token
    ck significant == @["base58", "base64", "base64url", "ss58"]

  test "hex: the key form is folded and the EIP-55 display form is preserved":
    # The two forms of ONE address, which is what the split exists for. The
    # subject is a real EIP-55 spelling: the checksum lives in which letters are
    # upper and which are lower, so the string below is not merely
    # mixed-case — it is the only spelling that carries the checksum.
    const eip55 = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
    ck identifierKeyForm("hex", eip55) == "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
    ck identifierDisplayForm("hex", eip55) == eip55
    # THE TWO ARE DIFFERENT STRINGS, stated outright, because a rule under which
    # they were equal would be the global fold with extra steps.
    ck identifierKeyForm("hex", eip55) != identifierDisplayForm("hex", eip55)
    # …and the display form still carries the checksum, i.e. it is not all one
    # case. That is the property a fold destroys, and the only one this tree
    # claims: it carries the checksum unharmed rather than validating it.
    let shown = identifierDisplayForm("hex", eip55)
    ck shown != shown.toLowerAscii
    ck shown != shown.toUpperAscii
    # CONTROL — the defect: the global fold produces the KEY form for the display
    # form too, so the checksum is gone and a reader who could have caught a
    # mistyped address no longer can.
    ck globalFold(eip55) == identifierKeyForm("hex", eip55)
    ck globalFold(eip55) != identifierDisplayForm("hex", eip55)
    # The key form is idempotent, which every call site relies on: a path segment
    # that is already a key form must survive being normalised again.
    ck identifierKeyForm("hex", identifierKeyForm("hex", eip55)) ==
       identifierKeyForm("hex", eip55)

  test "base58 and base64url: the case survives derivation and keying":
    # Case-significant, so NOTHING is folded — neither the key nor the display.
    const solana = "5KJvsngHeMpm884wtkJNzQGaCErckhHJBGFsvd3VyK5q"
    const ton = "EQCcrOCzgnZKgVSNNjjOQhRRsRWaiMEB-4hPl-PtLoL8Mh1x"
    for (token, id) in [("base58", solana), ("base64url", ton),
                        ("ss58", "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY")]:
      ck identifierKeyForm(token, id) == id
      ck identifierDisplayForm(token, id) == id
      # …through the derivation as well, which is the form a path segment takes.
      ck shardKeyFor(token, id) == id[0 ..< 4]
      # CONTROL — the defect, on the same identifier: the global fold changes it,
      # and changes it into a string that still LOOKS like an identifier. That is
      # the failure this is about — a confident wrong answer, not an error.
      ck globalFold(id) != id
      ck globalFold(id).len == id.len
    # And the corruption is not theoretical at the shard: TON's `EQ`/`UQ`/`kQ`
    # prefix is base64url of the address's real leading bits, so folding it maps
    # two genuinely different addresses onto one shard.
    ck shardKeyFor("base64url", ton) == "EQCc"
    ck shardKeyFor("base64url", globalFold(ton)) == "eqcc"
    ck shardKeyFor("base64url", ton) != shardKeyFor("base64url", globalFold(ton))

  test "bech32 and bech32m: the identifier comes out UNIFORM, not arbitrary":
    # BIP-173 allows all-lowercase or all-uppercase and makes a MIXED-case string
    # INVALID, so the two uniform spellings are one address and a fold is a real
    # normalisation. Lowercase is the canonical one.
    const lower = "addr1qx2fxv2umyhttkxyxp8x0dlpdt3k6cwng5pxj3jcacq5z"
    const upper = "ADDR1QX2FXV2UMYHTTKXYXP8X0DLPDT3K6CWNG5PXJ3JCACQ5Z"
    const mixed = "Addr1Qx2fXv2umYhttkxyxp8x0dlpdt3k6cwng5pxj3jcacq5z"
    for id in [lower, upper, mixed]:
      let key = identifierKeyForm("bech32", id)
      # UNIFORM is the claim, and it is asserted as uniformity rather than as a
      # literal: a key that merely equalled the lowercase constant would also
      # pass if the rule were "return this string I happen to know".
      ck key == key.toLowerAscii
      ck key == lower
      # The display form is the key form here, because there is no third,
      # mixed spelling worth preserving — it would not be an address.
      ck identifierDisplayForm("bech32", id) == key
      ck identifierDisplayForm("bech32m", id) == identifierKeyForm("bech32m", id)
    # All three spellings therefore name ONE shard, which is the consequence.
    ck shardKeyFor("bech32", lower) == "qx2f"
    ck shardKeyFor("bech32", upper) == "qx2f"
    ck shardKeyFor("bech32", mixed) == "qx2f"
    # CONTROL: the payload rule alone would not have done it. Sharding the raw
    # uppercase string without the fold gives a different bucket per spelling.
    ck upper[upper.rfind("1") + 1 ..< upper.rfind("1") + 5] != "qx2f"

  test "decimal has no letters, and says `preserve` rather than pretending":
    # A member whose rule was `lower` on the grounds that folding digits changes
    # nothing would be a member that quietly acquired a fold the day its alphabet
    # was widened.
    ck identifierCaseRule("decimal").keyForm == "preserve"
    ck not identifierCaseRule("decimal").significant
    ck identifierKeyForm("decimal", "1234567") == "1234567"
    ck identifierDisplayForm("decimal", "1234567") == "1234567"

  test "a token outside the closed set refuses rather than folding by default":
    # The whole point, in the third direction. A normaliser that met an unknown
    # token and shrugged into `toLowerAscii` would be the global fold restored at
    # the one place nobody would look.
    for bogus in ["base32", "Hex", "HEX", "0x", "", "hex "]:
      for op in 0 .. 2:
        var raised = false
        try:
          case op
          of 0: discard identifierKeyForm(bogus, "0xdeadbeef")
          of 1: discard identifierDisplayForm(bogus, "0xdeadbeef")
          else: discard identifierCaseRule(bogus)
        except ValueError as e:
          raised = true
          ck e.msg.contains("not an identifier encoding")
        ck raised

  test "the payload is the case rule, the prefix strip and the separator, in order":
    # `identifierPayload` is the one place those three steps are composed, and
    # the ORDER is load-bearing: folding first is what lets a `0X`-prefixed hex
    # identifier have its prefix recognised instead of keyed as payload.
    ck identifierPayload("hex", "0XABcd1234") == "abcd1234"
    ck identifierPayload("hex", "0xabcd1234") == "abcd1234"
    ck identifierPayload("hex", "abcd1234") == "abcd1234"
    ck identifierPayload("base58", "5KJvsng") == "5KJvsng"
    ck identifierPayload("bech32", "Addr1Qx2f") == "qx2f"
    ck identifierPayload("bech32m", "fuel1q9k7") == "q9k7"

  test "the §5 hash index folds by the declared rule, under a NAMED encoding":
    # The index's key encoding is a constant rather than a parameter, and the
    # reason is in the module: §5's index path carries no chain segment, so a
    # client resolving a bare query cannot know which chain's declaration to
    # normalise with. What changed is that the fold is no longer the module's
    # own: it comes from the same `case` rule the derivation reads.
    ck HashIndexEncoding == "hex"
    ck hashPrefix("0xABCDEF01", 2) == "ab"
    ck hashPrefix("0xabcdef01", 2) == "ab"
    ck hashPrefix("abcdef01", 2) == "ab"
    ck hashPrefix("0XABCDEF01", 2) == "ab"
    # …and it agrees with the derivation about what a payload is, which is what
    # stops the index and the object tree keying one identifier two ways.
    ck hashPrefix("0xABCDEF01", 4) == shardKeyFor("hex", "0xABCDEF01")

  test "BOTH segments of a sharded path are the key form":
    # The shard and the object NAME. A builder that folded one and not the other
    # would produce a directory that exists holding a file that does not, and
    # that is the failure this pair of calls prevents.
    let enc = hexIdentifierEncoding()
    const eip55 = "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed"
    const folded = "0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"
    for p in [txFactsPath("c", eip55, enc),
              txStatePath("c", "1", eip55, enc),
              traceSelectionPath("c", "1", eip55, enc),
              addressIndexPath("c", "1", eip55, enc),
              addressSegmentPath("c", eip55, "90-90", enc)]:
      ck not p.contains("5aAeb")
      ck p.contains(folded)
    # …and either spelling of the one account builds the one path.
    ck txFactsPath("c", eip55, enc) == txFactsPath("c", folded, enc)
    ck addressIndexPath("c", "1", eip55, enc) ==
       addressIndexPath("c", "1", folded, enc)
    # CONTROL: a case-significant encoding does NOT collapse them, so the
    # equality above is the hex rule rather than the builder folding everything.
    let b58 = chainIdentifierEncoding({"transaction": "base58",
                                       "address": "base58", "block": "base58"})
    ck txFactsPath("c", "AbCdEfGh", b58) != txFactsPath("c", "abcdefgh", b58)

  test "an EIP-55 spelling reaches the object a real producer published":
    # THE END-TO-END FORM, through the real producer and the real SDK read. The
    # tree is built by the demo generator, whose synthetic addresses are `0x` + 40
    # lowercase hex; the identifiers are then asked for in a spelling nobody
    # published — every letter uppercased — and the reader has to find them.
    #
    # Before this step it could not: the shard came from an unfolded slice, so
    # `0xCBCC…` asked for `/tx/CBCC/` and got a 404 on a chain that has the
    # object at `/tx/cbcc/`.
    let tree = buildDemo("eip55-read")
    let slug = onlySlug(rawRegistry(tree))
    let opened = openChain(localTree(tree), slug)
    ck opened.outcome == ooOpened
    let store = localTree(tree)
    var checked = 0
    for path in walkDirRec(tree / "d" / slug / "tx", relative = true):
      if not path.endsWith(".json"): continue
      let published = path.splitFile.name
      # The spelling nobody published: same account, shouted.
      let shouted = published.toUpperAscii
      ck shouted != published
      let r = transaction(store, opened.session, shouted)
      if r.outcome != roFound:
        checkpoint("uppercase spelling did not resolve: " & shouted)
      ck r.outcome == roFound
      # …and what comes back is the DISPLAY form the producer published, not the
      # spelling that was asked for. The reader resolves by key and answers with
      # what the tree says.
      ck r.view.hash == published
      inc checked
    # A FLOOR, because a walk that found no transaction would satisfy the loop
    # above perfectly.
    ck checked >= 4
    removeDir tree

  test "the validator refuses a REFERENCE written in a form that is not the key":
    # The two forms are only a rule if something checks them, and this is the
    # direction that bites: a producer that referenced a transaction by its
    # CHECKSUMMED spelling would publish a tree whose block says one thing and
    # whose object tree is keyed by another. `checkIdentifierForms` reads the
    # identifier the block LISTS — a published body — and requires it to be the
    # key form.
    let tree = buildDemo("forms-reference")
    ck validateTree(tree).len == 0
    let slug = onlySlug(rawRegistry(tree))
    var blockRel = ""
    for path in walkDirRec(tree / "d" / slug / "block", relative = true):
      if path.endsWith(".json"): blockRel = path
    ck blockRel.len > 0
    let blockAbs = tree / "d" / slug / "block" / blockRel
    var bd = parseJson(readFile(blockAbs))
    ck bd["transactions"].len > 0
    let was = bd["transactions"][0].getStr
    var shouted = newJArray()
    shouted.add %was.toUpperAscii
    for i in 1 ..< bd["transactions"].len: shouted.add bd["transactions"][i]
    bd["transactions"] = shouted
    writeFile(blockAbs, bd.pretty & "\n")
    let errs = validateTree(tree)
    var namedTheForm = false
    for e in errs:
      if e.contains("key form"): namedTheForm = true
    if not namedTheForm:
      checkpoint("the validator did not notice the reference's form: " & $errs)
    ck namedTheForm
    removeDir tree

  test "…and a body whose identifier is not the object's identifier":
    # The other direction. Differing in CASE where the encoding permits it is
    # legal and is the whole point of the two forms; differing in a digit is a
    # different account, and an object about a different account than its path
    # is a tree that would render one transaction's facts under another's URL.
    let t2 = buildDemo("forms-body")
    let slug2 = onlySlug(rawRegistry(t2))
    var factsRel = ""
    for path in walkDirRec(t2 / "d" / slug2 / "tx", relative = true):
      if path.endsWith(".json"): factsRel = path
    ck factsRel.len > 0
    let factsAbs = t2 / "d" / slug2 / "tx" / factsRel
    var facts = parseJson(readFile(factsAbs))
    let was = facts["id"]["hash"].getStr
    ck was.len > 0
    facts["id"]["hash"] = %(was[0 ..< was.len - 1] &
                            (if was[^1] == 'a': "b" else: "a"))
    writeFile(factsAbs, facts.pretty & "\n")
    let bodyErrs = validateTree(t2)
    var namedTheBody = false
    for e in bodyErrs:
      if e.contains("Those are two identifiers"): namedTheBody = true
    if not namedTheBody:
      checkpoint("the validator did not notice the body's identifier: " & $bodyErrs)
    ck namedTheBody
    # CONTROL, IN THE SAME RUN: a body differing only in CASE where the encoding
    # folds is NOT an error, which is what makes the arm above about identity
    # rather than about string equality. `hex` folds, so the checksummed spelling
    # of the same account is a legal display form.
    var facts2 = parseJson(readFile(factsAbs))
    facts2["id"]["hash"] = %was.toUpperAscii
    writeFile(factsAbs, facts2.pretty & "\n")
    var stillAnIdentityError = false
    for e in validateTree(t2):
      if e.contains("Those are two identifiers"): stillAnIdentityError = true
    ck not stillAnIdentityError
    removeDir t2

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
suite "the boundary: who knows about each half of the seam":

  # ── WHY A SOURCE SCAN IS THE ONLY WAY TO ASSERT THIS ──────────────────────
  #
  # "Exactly these files know about the member" is a claim about the whole tree,
  # and no behavioural test can establish it: a consumer that read the member and
  # happened to agree with the old answer today would pass every arm above. The
  # boundary IS the deliverable — the step that reaches the published hash index
  # has to land alone, with a compatibility window — so it is asserted as what it
  # is.
  #
  # ── AND THE RULE IT SWEEPS WITH IS NO LONGER SPELLED HERE ─────────────────
  #
  # It was spelled here AND in `tools/chain/identifier-encoding-selftest.mjs`:
  # the extensions, the pruned directories, the allowlists and both floors,
  # twice, compared to nothing. The two halves agreed because two
  # independently-maintained copies happened to match, and one divergence
  # (`redist/`) had already been found and fixed by hand. The rule is now
  # `tools/chain/identifier-encoding-boundary.json`, which both halves read.
  #
  # A SHARED RULE IS NOT ENOUGH, AND THE `redist/` CASE IS WHY. That was not a
  # disagreement about the rule — both halves already agreed `dist/` is pruned —
  # it was a disagreement about what `dist/` MEANS, in two sweep implementations
  # in two languages. So the last test below runs the JavaScript half with
  # `--emit-population` and requires the two swept file lists to be identical.
  # That compares the IMPLEMENTATIONS, which is the check a shared rule cannot
  # make.
  #
  # ── AND THE SITES THAT STILL DERIVE FROM THE STRING ───────────────────────
  #
  # `pins` in that file states what is still hex-shaped and what must no longer
  # be there, as counts over CODE rather than over comments — counted over
  # comments, a paragraph explaining a defect reads as the defect. The `absent`
  # half is the residual this step closed: before it, both halves counted only
  # `startsWith("0x")` in the capture tooling, so the three `slice(2, 6)`
  # derivations in the same file were invisible to both.

  const
    BoundaryFile = RepoRoot / "tools" / "chain" /
                   "identifier-encoding-boundary.json"
    BoundaryFormat = "blocktracer/identifier-encoding-boundary@1"

  let bnd = block:
    doAssert fileExists(BoundaryFile),
      "tools/chain/identifier-encoding-boundary.json is missing. Both halves of " &
      "the boundary read it; a suite that shrugged and swept with a rule of its " &
      "own would be the second copy this file exists to remove."
    parseJson(readFile(BoundaryFile))

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
    ## Whether a swept path counts as this repository's source, by the SHARED
    ## rule.
    ##
    ## THE DIRECTORY PRUNE IS SEGMENT-ANCHORED, and that is what makes it the same
    ## rule the JavaScript half applies rather than merely the same list of names.
    ## A bare `rel.contains("dist/")` also matches `redist/`, `subdist/` and every
    ## other directory whose name happens to END in `dist` — while the JS half
    ## prunes by exact directory NAME and tests its paths for `/dist/`, so it does
    ## not. MEASURED: a single `client/src/redist/x.mjs` put the two populations at
    ## 102 here and 103 there, and two halves that disagree about WHICH FILES they
    ## swept cannot be compared. Anchoring both ends of each segment closes it in
    ## the direction that keeps genuine source in the population — and the last
    ## test in this suite is what would now catch the next one of these.
    var isSource = false
    for e in bnd["sourceExtensions"]:
      if rel.splitFile.ext == e.getStr: isSource = true
    if not isSource: return false
    let anchored = "/" & rel
    for d in bnd["skipDirectories"]:
      if anchored.contains("/" & d.getStr & "/"): return false
    (top & "/" & rel) in inRepo

  proc sweptSource(top: string): seq[string] =
    for rel in relFiles(RepoRoot / top):
      if isRepoSource(top, rel): result.add top & "/" & rel
    result.sort()

  proc codeOf(src: string): string =
    ## Code lines only, in either language's comment syntax. COUNTED OVER CODE AND
    ## NOT OVER COMMENTS, because a paragraph explaining a defect reads as the
    ## defect: this suite's own pins name `slice(2, 6)` and `stripHex` in prose.
    for line in src.splitLines:
      let t = line.strip
      if t.startsWith("#") or t.startsWith("//") or t.startsWith("*") or
         t.startsWith("/*"): continue
      result.add line
      result.add "\n"

  test "the boundary rule is one file, and this half reads THAT file":
    ck bnd{"format"}.getStr == BoundaryFormat
    # It has to SAY something: an empty extension list sweeps nothing and an
    # empty sweep list asserts nothing, and both would be green.
    ck bnd{"sourceExtensions"}.len > 0
    ck bnd{"skipDirectories"}.len > 0
    ck bnd{"floors"}.len == 3
    # TWO SWEEPS, AND THEY ARE TWO FACTS. A file may key an identifier without
    # reading a registry row (the §5 index does, under a named global encoding)
    # and may read the row without keying anything (the session pins it). One
    # merged allowlist would let a new consumer of either seam be excused by the
    # other's list.
    ck bnd{"sweeps"}.len == 2
    ck bnd["sweeps"][0]["id"].getStr == "declaration"
    ck bnd["sweeps"][1]["id"].getStr == "caseRule"
    # …and the JavaScript half reads the same file, by path.
    ck readFile(RepoRoot / "tools/chain/identifier-encoding-selftest.mjs").contains(
      "identifier-encoding-boundary.json")

  test "under src/, client/ and tools/, an equality behind population floors":
    # NAMING ALONE WAS MEASURED LEAKING, which is why the equality is against a
    # sweep: a consumer planted in `client/src/viewmodel/chain_vm.nim`, next door
    # to a named file, once landed with every arm in this file green. And SWEEPING
    # ALONE is an empty-set green, which is why the population is asserted too —
    # per directory, so an emptied sweep of one cannot hide behind the other.
    for f in bnd["floors"]:
      let top = f["top"].getStr
      let floor = f["floor"].getInt
      let swept = sweptSource(top)
      if swept.len < floor:
        checkpoint(top & "/: swept " & $swept.len & " source file(s), floor " &
                   $floor & " — an emptied sweep is not a green")
      ck swept.len >= floor
      for w in bnd["sweeps"]:
        var tokens: seq[string]
        for t in w["tokens"]: tokens.add t.getStr
        var want: seq[string]
        for row in w["expected"]{top}: want.add row["path"].getStr
        want.sort()
        var found: seq[string]
        for rel in swept:
          let src = readFile(RepoRoot / rel)
          for t in tokens:
            if src.contains(t): found.add rel; break
        # AN EQUALITY, NOT A SUBSET. An unexpected consumer fails it in one
        # direction and an expected consumer that stopped being one fails it in
        # the other.
        if found != want:
          checkpoint(top & "/ " & w["id"].getStr & " swept: " & found.join(", "))
          checkpoint(top & "/ " & w["id"].getStr & " expected: " & want.join(", "))
        ck found == want
        # Named as well as swept, so a file that STOPS EXISTING fails loudly
        # instead of silently leaving the expected set.
        for rel in want: ck fileExists(RepoRoot / rel)
    # THE SIZES, so the expected sets cannot drift upward one entry at a time
    # with the equalities quietly edited to match. A number is a thing a reviewer
    # sees move.
    proc expectedLen(id, top: string): int =
      for w in bnd["sweeps"]:
        if w["id"].getStr == id: return w["expected"]{top}.len
      -1
    ck expectedLen("declaration", "src") == 9
    ck expectedLen("declaration", "client") == 4
    ck expectedLen("declaration", "tools") == 1
    ck expectedLen("caseRule", "src") == 6
    ck expectedLen("caseRule", "client") == 1
    ck expectedLen("caseRule", "tools") == 1
    # EVERY expected entry carries the REASON it is one. An allowlist whose
    # entries say nothing is a list nobody reviews.
    var unexplained: seq[string]
    for w in bnd["sweeps"]:
      for top, rows in w["expected"]:
        for row in rows:
          if row{"why"}.getStr.len == 0: unexplained.add row{"path"}.getStr
    ck unexplained.len == 0

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

  test "THE STRING-DERIVING SITES ARE PINNED, present AND absent":
    # The seam is nearly closed, and a boundary check that only watched the closed
    # half would report it shut. Each pin names a needle, a count over CODE and
    # the reason it is pinned; the day one moves, this arm goes red and whoever
    # moved it reads that reason.
    var checkedPins = 0
    for pin in bnd["pins"]:
      let file = pin["file"].getStr
      let code = codeOf(readFile(RepoRoot / file))
      for row in pin["present"]:
        let needle = row["needle"].getStr
        let want = row["count"].getInt
        let got = code.count(needle)
        if got != want:
          checkpoint(file & ": `" & needle & "` appears " & $got &
                     " time(s) in code, pinned at " & $want & " — " &
                     row["why"].getStr)
        ck got == want
        inc checkedPins
      for row in pin["absent"]:
        let needle = row["needle"].getStr
        let got = code.count(needle)
        if got != 0:
          checkpoint(file & ": `" & needle & "` is back, " & $got &
                     " time(s) in code — " & row["why"].getStr)
        ck got == 0
        inc checkedPins
    # ANTI-VACUITY: a `pins` array that parsed to nothing would make both loops
    # above run zero times and report success having measured nothing.
    ck bnd["pins"].len == 2
    ck checkedPins == 8
    # AND EVERY PIN SAYS WHY, for the reason the allowlist entries do.
    var unexplained: seq[string]
    for pin in bnd["pins"]:
      for half in ["present", "absent"]:
        for row in pin[half]:
          if row{"why"}.getStr.len == 0: unexplained.add row["needle"].getStr
    ck unexplained.len == 0

  test "and the derivation itself holds no table of its own":
    # `shards.nim` reads the per-encoding rule from the shared file through
    # `identifierEncodingRule`. If it grew a `case` over the tokens instead, the
    # set would be closed in the data and re-opened in the derivation.
    let sh = readFile(RepoRoot / "src/blocktracer/contract/shards.nim")
    ck sh.contains("identifierEncodingRule(encoding)")
    for token in identifierEncodingIds():
      if token == "hex": continue   # named in prose, as the published layout
      ck not sh.contains("\"" & token & "\"")
    # …and it folds through the shared rule rather than with a fold of its own.
    # A `toLowerAscii` written here would be right for hex and would destroy the
    # four case-significant members.
    ck sh.contains("identifierPayload(encoding, identifier)")
    ck not codeOf(sh).contains("toLowerAscii")
    ck not codeOf(sh).contains("toUpperAscii")

  test "THE TWO HALVES SWEPT THE SAME FILES, not merely by the same rule":
    # ── THE CHECK A SHARED RULE CANNOT MAKE ──────────────────────────────────
    #
    # The one divergence this pair has had was not about the rule. Both halves
    # agreed `dist/` is pruned and disagreed about what `dist/` MEANS: an
    # unanchored `contains("dist/")` here also matched `redist/`, so a single
    # `client/src/redist/x.mjs` put the populations at 102 and 103. It was found
    # by hand. Moving the words into a shared file would not have caught it,
    # because both implementations would have read the same words and still
    # applied them differently.
    #
    # So the JavaScript half is RUN, with `--emit-population`, and the two swept
    # file lists are compared as sets, per top-level directory. Its own output
    # goes to stderr, so stdout carries nothing but the JSON.
    #
    # IT REFUSES RATHER THAN SKIPS if node is not there. A comparison that
    # quietly did not happen is the silent self-pass the testing policy bans, and
    # this suite already shells out to git for its population.
    let cmd = "cd " & quoteShell(RepoRoot) & " && node " &
              "tools/chain/identifier-encoding-selftest.mjs --emit-population"
    let (outp, code) = execCmdEx(cmd)
    if code != 0:
      checkpoint("the JavaScript half could not be run (exit " & $code & "): " &
                 outp & " — exit 127 is node missing from PATH, which in this " &
                 "repository means the devshell was not entered; either way the " &
                 "populations were not compared and that is a failure, not a skip")
    ck code == 0
    let theirs = parseJson(outp)
    var comparedTops = 0
    for f in bnd["floors"]:
      let top = f["top"].getStr
      var ours = sweptSource(top)
      var them: seq[string]
      for x in theirs{top}: them.add x.getStr
      them.sort()
      if ours != them:
        var onlyOurs, onlyTheirs: seq[string]
        for x in ours:
          if x notin them: onlyOurs.add x
        for x in them:
          if x notin ours: onlyTheirs.add x
        checkpoint(top & "/: the two halves swept different files. Only Nim: " &
                   onlyOurs.join(", ") & " | only JavaScript: " &
                   onlyTheirs.join(", "))
      ck ours == them
      # ANTI-VACUITY: an emitted population that was missing a directory
      # entirely would compare two empty lists and pass.
      ck them.len >= f["floor"].getInt
      inc comparedTops
    ck comparedTops == 3

expectCount(564)
