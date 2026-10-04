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

import std/[unittest, os, json, strutils, algorithm, osproc, sets, tables]

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
    # separately below with the reason. The captures contain none — zero `0x`
    # literals in an identifier position carry an uppercase hex digit, in all five
    # committed captures; `hexIdentifierEncoding` carries the per-capture counts
    # and the definition they are taken under, because "386 in the testnet
    # capture" named neither and two trees here answer to that description.
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
    # AND THE CASE-SIGNIFICANT MEMBERS FOLD THEIR SEGMENT TOO, which is a
    # DIFFERENT statement from folding their identifier — see
    # `shardKey.foldKey`. A shard segment is a DIRECTORY NAME and a `.bin` FILE
    # NAME, and a case-significant one is a single entry on a case-insensitive
    # filesystem: `Ab.bin` and `aB.bin` are one file, the last writer wins at
    # rc 0, and the other shard's entries are gone. What is preserved is the
    # identifier, asserted two arms below.
    for token in ["base58", "base64url", "ss58"]:
      ck shardKeyFor(token, "AbCdEfGh") == "abcd"
      # …and the IDENTIFIER is untouched, in the same iteration, so the fold is
      # attributable to the bucket rather than to the member's key form.
      ck identifierKeyForm(token, "AbCdEfGh") == "AbCdEfGh"

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
    # THE ALPHABET IS THEIR OWN AND THE SEGMENT IS FOLDED — two facts, and the
    # second one is `shardKey.foldKey`: the payload comes from the member's
    # alphabet rather than from hex's, and the resulting FILENAME folds so that
    # two case-differing identifiers cannot name one file. The identifier itself
    # is preserved, which the arm three below asserts on the same strings.
    # base58 (Solana) — whole string is payload.
    ck shardKeyFor("base58", "5KJvsngHeMpm884wtkJNzQGaCErckhHJBGFsvd3VyK5q") == "5kjv"
    # base64url (TON) — `EQ`/`UQ` prefix is payload, not decoration, and the two
    # prefixes still give two DIFFERENT segments: folding case does not merge
    # them, which is what distinguishes a coarser bucket from a lost one.
    ck shardKeyFor("base64url", "EQCcrOCzgnZKgVSNNjjOQhRRsRWaiMEB-4hPl-PtLoL8Mh1x") ==
       "eqcc"
    ck shardKeyFor("base64url", "UQCcrOCzgnZKgVSNNjjOQhRRsRWaiMEB-4hPl-PtLoL8Mh1x") ==
       "uqcc"
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
    ck shardKeyFor("ss58", "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY") == "5grw"
    # decimal — a rule exists even though no sharded kind can be decimal today.
    ck shardKeyFor("decimal", "12345") == "1234"
    ck shardKeyFor("decimal", "7") == "7000"
    # And the pad is the ALPHABET's zero digit, not `0`, which is not a base58 or
    # a bech32 digit at all.
    ck shardKeyFor("base58", "5K") == "5k11"
    ck shardKeyFor("bech32", "addr1q") == "qqqq"
    ck shardKeyFor("base64url", "EQ") == "eqaa"   # folded pad, see below
    # …AND THE PAD ITSELF IS FOLDED, which was measured rather than assumed: the
    # DECLARED pad is `A`, base64's zero digit, so padding a folded payload with
    # the declared spelling gives `eqAA` — a segment that is not closed under
    # case folding, i.e. the very property the fold is for, broken by the last
    # four characters of the name. The declaration is unchanged and the fold is
    # applied to it at the one site that uses it.
    ck identifierEncodingRule("base64url").pad == "A"
    ck shardKeyFor("base64url", "EQ") == shardKeyFor("base64url", "EQ").toLowerAscii
    # CONTROL: a member that does NOT fold keeps its declared pad verbatim, so
    # the line above is attributable to `foldKey` rather than to a pad that was
    # lowercase all along. `bech32`'s `q` is already lowercase, so the control
    # has to be a member whose pad is a DIGIT and whose fold is off — `decimal`.
    ck not identifierEncodingRule("decimal").foldKey
    ck shardKeyFor("decimal", "7") == "7000"

  test "a case-significant identifier keeps its case, and its BUCKET does not":
    # ── THE TWO QUESTIONS, WHICH WERE ONE ASSERTION UNTIL `shardKey.foldKey` ───
    #
    # "Does this string name a different identifier?" and "does this string name
    # a different FILE?" have different answers for base58, base64url and ss58,
    # and conflating them is a data defect in whichever direction it is made.
    # Fold the IDENTIFIER and `So111…112` resolves to an account that does not
    # exist. Leave the BUCKET unfolded and `Ab.bin` and `aB.bin` are one file on
    # a case-insensitive filesystem, at rc 0, with one shard's entries silently
    # gone — §5.0a's false absence.
    const mixed = "5KJvsngHeMpm884wtkJNzQGaCErckhHJBGFsvd3VyK5q"
    const lowered = "5kjvsnghempm884wtkjnzqgacerckhhjbgfsvd3vyk5q"
    # THE IDENTIFIER IS TWO IDENTIFIERS, and every form that names one says so.
    ck identifierKeyForm("base58", mixed) != identifierKeyForm("base58", lowered)
    ck identifierDisplayForm("base58", mixed) == mixed
    ck identifierIndexKey("base58", mixed) != identifierIndexKey("base58", lowered)
    # THE BUCKET IS ONE BUCKET, which is the whole of the fix.
    ck shardKeyFor("base58", mixed) == shardKeyFor("base58", lowered)
    ck hashPrefix("base58", mixed, HashShardPrefixLen) ==
       hashPrefix("base58", lowered, HashShardPrefixLen)
    ck shardKeyFor("base64url", "EQCcrOCz") == "eqcc"
    ck shardKeyFor("base64url", "eqccrocz") == "eqcc"
    # …and the CONTROL, in the same run: hex, which declares `keyForm: lower`,
    # maps its two spellings together at BOTH levels — the identifier as well as
    # the bucket. So the split above is attributable to the two declared fields
    # rather than to one fold applied everywhere, which is what it used to be.
    ck shardKeyFor("hex", "0xABCDEF01") == shardKeyFor("hex", "0xabcdef01")
    ck identifierKeyForm("hex", "0xABCDEF01") == identifierKeyForm("hex", "0xabcdef01")
    ck identifierEncodingRule("base58").foldKey
    ck not identifierEncodingRule("hex").foldKey

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

  test "base58 and base64url: the case survives the KEY and the display form":
    # Case-significant, so the IDENTIFIER is not folded — neither the key nor the
    # display form. The SHARD SEGMENT is, and that is `shardKey.foldKey`: it is a
    # filename rather than an identifier. The arm below asserts both halves on
    # the same strings so neither can be read as the other.
    const solana = "5KJvsngHeMpm884wtkJNzQGaCErckhHJBGFsvd3VyK5q"
    const ton = "EQCcrOCzgnZKgVSNNjjOQhRRsRWaiMEB-4hPl-PtLoL8Mh1x"
    for (token, id) in [("base58", solana), ("base64url", ton),
                        ("ss58", "5GrwvaEF5zXb26Fz9rcQpDWS57CtERHpNehXCPcNoHGKutQY")]:
      ck identifierKeyForm(token, id) == id
      ck identifierDisplayForm(token, id) == id
      # …and the derivation's segment is that payload FOLDED, which is the form
      # a path segment takes. Both statements on one identifier, so the
      # preservation is about the identifier and the fold about the bucket.
      ck shardKeyFor(token, id) == id[0 ..< 4].toLowerAscii
      ck identifierIndexKey(token, id) == id
      # CONTROL — the defect, on the same identifier: the global fold changes it,
      # and changes it into a string that still LOOKS like an identifier. That is
      # the failure this is about — a confident wrong answer, not an error.
      ck globalFold(id) != id
      ck globalFold(id).len == id.len
    # And the corruption is not theoretical at the shard: TON's `EQ`/`UQ`/`kQ`
    # prefix is base64url of the address's real leading bits, so folding it maps
    # two genuinely different addresses onto one shard.
    # AND THE GLOBAL FOLD IS STILL THE DEFECT, MEASURED WHERE IT STILL SHOWS.
    # The segment no longer distinguishes them — that is the point of the fold —
    # so the assertion moves to the level where the two addresses really are two
    # addresses: the key form, the index key and therefore the leaf file name.
    ck shardKeyFor("base64url", ton) == "eqcc"
    ck shardKeyFor("base64url", globalFold(ton)) == "eqcc"
    ck identifierKeyForm("base64url", ton) !=
       identifierKeyForm("base64url", globalFold(ton))
    ck identifierIndexKey("base64url", ton) !=
       identifierIndexKey("base64url", globalFold(ton))

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

  test "the §5 hash index folds by the declared rule, per identifier SHAPE":
    # The index's key encoding used to be a CONSTANT, on the argument that §5's
    # index path carries no chain segment so a client resolving a bare query
    # cannot know which chain's declaration to normalise with. That half is still
    # true; what it missed is that a client does not need the chain. It needs the
    # query's SHAPE, which §2's table supplies from the string alone — so the
    # encoding is a parameter now, and the constant that remains names only the
    # one encoding a FORMAT-1 shard can hold.
    ck HashIndexLegacyEncoding == "hex"
    ck hashPrefix("hex", "0xABCDEF01", 2) == "ab"
    ck hashPrefix("hex", "0xabcdef01", 2) == "ab"
    ck hashPrefix("hex", "abcdef01", 2) == "ab"
    ck hashPrefix("hex", "0XABCDEF01", 2) == "ab"
    # …and it agrees with the derivation about what a payload is, which is what
    # stops the index and the object tree keying one identifier two ways.
    ck hashPrefix("hex", "0xABCDEF01", 4) == shardKeyFor("hex", "0xABCDEF01")
    # …and the same agreement holds for a member whose payload is NOT the whole
    # string, which is where a second implementation would have shown up.
    ck hashPrefix("bech32", "Addr1Qx2fZZ", 4) ==
       shardKeyFor("bech32", "Addr1Qx2fZZ")

  test "a shard NAME can never collide on a case-insensitive filesystem":
    # ── WHAT THIS ARM IS FOR, AND WHY IT MODELS THE FILESYSTEM RATHER THAN USING
    # ONE ───────────────────────────────────────────────────────────────────────
    #
    # `shardKeyFor` names a DIRECTORY and `hashPrefix` names a FILE —
    # `idx/hash/{version}/{prefix}.bin`. With case preserved in the segment, two
    # case-differing base58 identifiers derived `Ab` and `aB`, so `Ab.bin` and
    # `aB.bin` are ONE file on a case-insensitive filesystem: the last writer
    # wins, rc is 0, nothing warns, and the other shard's entries VANISH.
    # Search-And-Routing.md §5.0a makes a prefix miss "a confident claim that
    # NOTHING published begins with those digits", so that loss is a FALSE
    # ABSENCE — a page confidently wrong rather than visibly broken.
    #
    # THE INVARIANT IS ARITHMETIC AND HOLDS ON EVERY FILESYSTEM: the set of
    # shard names the derivation emits is CLOSED UNDER CASE FOLDING, i.e. no two
    # distinct emitted names fold equal. A host cannot then hold two of them as
    # one, whatever its case behaviour, so the arm runs the same everywhere and
    # needs no privileged mount, no FUSE and no image. `tools/chain/
    # shard-name-case-repro.sh` is the out-of-tree DEMONSTRATION on a real
    # case-insensitive filesystem model (a FAT image via mtools — a MODEL of
    # macOS APFS and Windows NTFS at their defaults, NOT those filesystems);
    # measured 2026-09-28, its three arms are positive control 2 files, the
    # pre-fold pair collapsing to one at rc 0 in silence, and the post-fold names
    # coexisting. It is not the gate; this is.
    #
    # THE CONTROL IS THE SECOND HALF AND IT IS LOAD-BEARING. The same model
    # driven over the UNFOLDED derivation — `identifierPayload`, which is exactly
    # what `shardKeyFor` and `hashPrefix` sliced before `shardKey.foldKey` — must
    # LOSE entries. Without it a fold-closure assertion is satisfied by any
    # population that happens to carry no case variation, which is every
    # identifier this tree publishes today.
    var caseSignificant: seq[string]
    for e in IdentifierEncodings:
      if e.caseRule.keyForm == "preserve" and e.shardKey.foldKey:
        caseSignificant.add e.id
    # ANTI-VACUITY: the arm is about the members that preserve case AND fold the
    # bucket, and a population of none would satisfy every assertion below.
    ck caseSignificant.len == 4          # base58, base64, base64url, ss58
    for enc in caseSignificant:
      let rule = identifierEncodingRule(enc)
      # Two identifiers differing ONLY in case, built from the member's own
      # alphabet so both are genuinely writable in it.
      var lower, upper: string
      for c in rule.alphabet:
        if c in {'a' .. 'z'} and toUpperAscii(c) in rule.alphabet:
          lower.add c
          upper.add toUpperAscii(c)
      ck lower.len >= ShardWidth        # enough characters to fill a segment
      let a = lower & upper
      let b = upper & lower
      ck a != b
      # ── THE PROPERTY ──────────────────────────────────────────────────────
      # One directory, one `.bin`, and the two are the same derivation. The
      # DIRECTORY half is asserted only for a pathSafe member, because
      # `shardKeyFor` refuses `base64` outright — its alphabet contains `/` — and
      # the index half is asserted for all four, because `hashPrefix` is where
      # the FILE NAME comes from and that is the site that destroys data.
      ck hashPrefix(enc, a, HashShardPrefixLen) ==
         hashPrefix(enc, b, HashShardPrefixLen)
      ck hashPrefix(enc, a, HashShardPrefixLen) ==
         hashPrefix(enc, a, HashShardPrefixLen).toLowerAscii
      if rule.pathSafe:
        ck shardKeyFor(enc, a) == shardKeyFor(enc, b)
        ck shardKeyFor(enc, a) == shardKeyFor(enc, a).toLowerAscii
      else:
        var refusedShard = false
        try: discard shardKeyFor(enc, a)
        except ValueError: refusedShard = true
        ck refusedShard
      # ── AND NOTHING LOST INFORMATION ──────────────────────────────────────
      # The leaf, the display form and the index ENTRY still carry the
      # case-significant identifier, so the two are two entities in one bucket
      # rather than one entity. A fold applied to the identifier instead of the
      # key is the data defect this scoping exists to avoid.
      ck identifierKeyForm(enc, a) == a
      ck identifierKeyForm(enc, b) == b
      ck identifierDisplayForm(enc, a) == a
      ck identifierIndexKey(enc, a) != identifierIndexKey(enc, b)
      # ── THE CONTROL, IN THE SAME ITERATION ────────────────────────────────
      # The pre-fold derivation is `identifierPayload` sliced, and on this pair
      # it yields two names that fold equal — which a case-insensitive host
      # holds as one. Asserting that it DID is what makes the four assertions
      # above measurements of the fold rather than of the population.
      let preA = identifierPayload(enc, a)[0 ..< HashShardPrefixLen]
      let preB = identifierPayload(enc, b)[0 ..< HashShardPrefixLen]
      ck preA != preB
      ck preA.toLowerAscii == preB.toLowerAscii
      # ── AND A CASE-INSENSITIVE STORE MODELLED, BOTH WAYS ──────────────────
      # Writing both names into a store keyed by the FOLDED name is what a
      # case-insensitive filesystem does. Pre-fold, two shards become one entry
      # and one is destroyed; post-fold, there is only ever one name to write.
      var insensitive = initTable[string, string]()
      insensitive[preA.toLowerAscii] = "entries-of-" & preA
      insensitive[preB.toLowerAscii] = "entries-of-" & preB
      ck insensitive.len == 1                       # ONE file where two were written
      ck insensitive[preA.toLowerAscii] == "entries-of-" & preB   # first one GONE
      var folded = initTable[string, string]()
      for id in [a, b]:
        let n = hashPrefix(enc, id, HashShardPrefixLen)
        folded.mgetOrPut(n.toLowerAscii, "") .add "entry-" & id & ";"
      ck folded.len == 1                            # one shard, by DESIGN
      for id in [a, b]:                             # and both entries are in it
        ck folded[hashPrefix(enc, a, HashShardPrefixLen)].contains(id)

  test "§2's `44 chars` row is a DECODE LENGTH, and the other side is refused by name":
    # ── IT IS A ROUTING DECISION RATHER THAN AN ENCODING ONE ────────────────────
    #
    # `base64` is the one member whose `shardKey.pathSafe` is false, so
    # `indexKeysOf` SKIPS it and a base64 digest derives ZERO index probes. The
    # published route for a 32-byte digest is therefore the base64url spelling of
    # the same bytes — lossless, `+`->`-` and `/`->`_` — and what blocked THAT was
    # not the data but §2: base64url's only row was the 48-character TON ADDRESS,
    # so a 44-character base64url string matched nothing.
    #
    # Two REAL toncenter transaction hashes, measured 2026-09-28, and their
    # re-spellings. Both carry `+`; the second carries `/` as well, so it is
    # unrepresentable as a shard segment under `base64` for the documented reason.
    const TonA = "0EwlvoDba2xuNCUvJaAMHowfgLOQ7m8CAKCdYCJ+94Q="
    const TonB = "2tqqN0+CBur1NDSydm125YOCf+V7GMmhsNs6I/+xn18="
    proc urlOf(s: string): string = s.replace("+", "-").replace("/", "_")
    # THE ROW EXISTS AND IT ROUTES.
    for d in [TonA, TonB]:
      ck identifierEncodingsMatching(urlOf(d)) == @["base64url"]
      ck shardKeyFor("base64url", urlOf(d)).len == ShardWidth
      ck identifierIndexKey("base64url", urlOf(d)) == urlOf(d)
    # CONTROL ONE: the base64 spelling still matches base64 and is still refused
    # at the shard, so the row was ADDED rather than the alphabet widened.
    for d in [TonA, TonB]:
      ck identifierEncodingsMatching(d) == @["base64"]
      ck not identifierEncodingRule("base64").pathSafe
      var raised = false
      try: discard shardKeyFor("base64", d)
      except ValueError as e:
        raised = true
        ck e.msg.contains("cannot be a shard path segment")
      ck raised
    # CONTROL TWO: the 48-character TON ADDRESS row is untouched — the new row is
    # a second row on the same member, not a replacement of the first.
    const TonAddr = "EQCcOxUE0Yc5t2RrNsnwJfN0Aq2KWt4UJx0Fx0Fx0Fx0Fx0F"
    ck TonAddr.len == 48
    ck identifierEncodingsMatching(TonAddr) == @["base64url"]
    ck identifierIndexKey("base64url", TonAddr) == TonAddr
    # ── THE AMBIGUITY, CLOSED ──────────────────────────────────────────────────
    # 44 base64 characters with one `=` are 32 decoded bytes — a digest. 44
    # UNPADDED characters are 33, which is not a digest of anything this tree
    # routes, and the length band alone cannot tell them apart. The row declares
    # the suffix; the client DECLINES the other (0 shapes, 0 probes) and the
    # producer's key path REFUSES it BY NAME.
    let unpadded = urlOf(TonA)[0 ..< 43] & "Q"
    ck unpadded.len == 44
    ck not unpadded.endsWith("=")
    ck identifierEncodingsMatching(unpadded).len == 0
    var refused = false
    try: discard identifierIndexKey("base64url", unpadded)
    except ValueError as e:
      refused = true
      ck e.msg.contains("DECODE LENGTH")
      ck e.msg.contains("44")            # the length that was wrong
      ck e.msg.contains("33")            # what it would have decoded to
      ck e.msg.contains("32-byte digest")
    ck refused
    # CONTROL: the PADDED spelling passes in the same run, so the refusal is
    # about the length and not about base64url.
    ck identifierIndexKey("base64url", urlOf(TonA)) == urlOf(TonA)
    # …and the same refusal reaches the `base64` spelling, because the narrowing
    # is on the ROW and both members carry one.
    var refusedStd = false
    try: discard identifierIndexKey("base64", TonA[0 ..< 43] & "Q")
    except ValueError: refusedStd = true
    ck refusedStd
    ck identifierIndexKey("base64", TonA) == TonA

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

  test "…and so does a BLOCK spelling, which it could not before":
    # THE THIRD ROUTE KIND, WHICH WAS ASYMMETRIC. `blockPath` took no
    # `ChainIdentifierEncoding` and therefore key-formed nothing, on the argument
    # that a block path has no shard segment — which confuses the alphabet question
    # with the CASE question. The object is still NAMED by the identifier, so while
    # this was the case an uppercased identifier reached the transaction object and
    # the address object and 404ed on the block, on the same input, through a
    # published SDK package. Before per-encoding case handling all three were
    # equally case-sensitive, so the asymmetry was CREATED by widening two of them.
    let tree = buildDemo("block-case-read")
    let slug = onlySlug(rawRegistry(tree))
    let opened = openChain(localTree(tree), slug)
    ck opened.outcome == ooOpened
    let store = localTree(tree)
    var blocksChecked = 0
    for path in walkDirRec(tree / "d" / slug / "block", relative = true):
      if not path.endsWith(".json"): continue
      let published = path.splitFile.name
      let shouted = published.toUpperAscii
      ck shouted != published
      let r = blockDetail(store, opened.session, shouted)
      if r.outcome != roFound:
        checkpoint("uppercase block spelling did not resolve: " & shouted)
      ck r.outcome == roFound
      # …and the body answers with what the TREE says, not the spelling asked for.
      ck r.detail.hash == published
      inc blocksChecked
    ck blocksChecked >= 3

    # AND THE THREE KINDS BEHAVE IDENTICALLY, which is the property rather than
    # three separate ones. One identifier, one uppercased spelling, three path
    # builders, and each has to name the object the producer wrote.
    let enc = opened.session.identifierEncoding
    var blockHash = ""
    for path in walkDirRec(tree / "d" / slug / "block", relative = true):
      if path.endsWith(".json"): blockHash = path.splitFile.name
    var txHash = ""
    for path in walkDirRec(tree / "d" / slug / "tx", relative = true):
      if path.endsWith(".json"): txHash = path.splitFile.name
    var addrName = ""
    let gen = opened.session.generation
    for path in walkDirRec(tree / "d" / slug / "g" / gen / "addr", relative = true):
      if path.endsWith(".json"): addrName = path.splitFile.name
    ck blockHash.len > 0
    ck txHash.len > 0
    ck addrName.len > 0
    ck blockPath(slug, blockHash.toUpperAscii, enc) ==
       blockPath(slug, blockHash, enc)
    ck txFactsPath(slug, txHash.toUpperAscii, enc) == txFactsPath(slug, txHash, enc)
    ck addressIndexPath(slug, gen, addrName.toUpperAscii, enc) ==
       addressIndexPath(slug, gen, addrName, enc)
    # …and all three land on a file that is there, which a string equality alone
    # would not establish.
    ck fileExists(tree / blockPath(slug, blockHash.toUpperAscii, enc))
    ck fileExists(tree / txFactsPath(slug, txHash.toUpperAscii, enc))
    ck fileExists(tree / addressIndexPath(slug, gen, addrName.toUpperAscii, enc))
    removeDir tree

  test "THE PRODUCER CANNOT WRITE A PATH THE CLIENT CANNOT RECOMPUTE":
    # ── THE ARM THAT FAILS ON THE PRE-FIX CODE, AND THE DEFECT IT IS ABOUT ────
    #
    # The producers took their shard from `shardKeyFor` — which folds, as of
    # per-encoding case handling — and named the object with the RAW identifier.
    # MEASURED before the fix: ingesting a capture whose `txHash` carries an
    # uppercase hex digit wrote `d/{chain}/tx/0a80/0x0A807E….json` while the
    # client computed `d/{chain}/tx/0a80/0x0a807e….json`. A folded directory
    # holding an unfolded file: a 404, and exactly the state
    # `blocktracer_client/paths.nim`'s header names as the defect.
    #
    # It was unreachable on today's captures — every identifier in every one of
    # them is lowercase — so no behavioural test in this repository could see it,
    # and the byte-identity diff is silent about case BY CONSTRUCTION. That is why
    # this arm CONSTRUCTS the input: a real capture with one identifier
    # uppercased, ingested by the real producer.
    #
    # NOT A MOCK AND NOT A FIXTURE. The subject is the committed mainnet capture —
    # a snapshot nobody in this repository wrote — copied to a temporary directory
    # with the CASE of one identifier changed and nothing else. A capture written
    # for this test would be a producer's input invented by the test; this is the
    # real input with one legal spelling substituted, which is what a chain
    # publishing EIP-55 or a tool that shouted would hand the producer.
    let snap = parseJson(readFile(LiveMainnet / "snapshot.json"))
    ck snap["transactions"].len > 0
    let rawHash = snap["transactions"][0]["txHash"].getStr
    ck rawHash.startsWith("0x")
    ck rawHash == rawHash.toLowerAscii    # the committed corpus, as measured
    # SHOUTED, PAYLOAD ONLY. The `0x` stays lowercase so the only thing that moved
    # is the case of hex digits — `0X` would also exercise the prefix strip and
    # this arm is about the two SEGMENTS agreeing, not about the strip.
    let shouted = "0x" & rawHash[2 .. ^1].toUpperAscii
    ck shouted != rawHash
    ck identifierKeyForm("hex", shouted) == rawHash

    let stage = tmpDir("halffold-in")
    for rel in relFiles(LiveMainnet):
      let dst = stage / rel
      createDir dst.parentDir
      copyFile(LiveMainnet / rel, dst)
    # EVERY OCCURRENCE, not only the transaction row's own `txHash`. A chain that
    # writes its identifiers in this spelling writes them that way wherever it
    # mentions them, and this capture mentions this one TWICE — once on the
    # transaction and once in the block's list. Substituting only the first is a
    # weaker input than a real chain provides, and it is the difference between a
    # tree that validates and one that does not: measured, mutating the row alone
    # gives 0 validator errors because the block still lists the folded spelling.
    let stagedText = readFile(stage / "snapshot.json")
    ck stagedText.count(rawHash) == 2
    writeFile(stage / "snapshot.json", stagedText.replace(rawHash, shouted))

    let tree = tmpDir("halffold-out")
    discard ingestSnapshot(IngestConfig(outDir: tree, snapshotDir: stage))
    let slug = onlySlug(rawRegistry(tree))
    let opened = openChain(localTree(tree), slug)
    ck opened.outcome == ooOpened
    let enc = opened.session.identifierEncoding

    # THE EQUALITY. What the producer WROTE, found by walking the tree, against
    # what the client COMPUTES from the identifier the capture carried. Both are
    # read rather than asserted as literals: a comparison of two calls to one
    # function would pass with the function wrong.
    var written: seq[string]
    for path in walkDirRec(tree / "d" / slug / "tx", relative = true):
      if path.endsWith(".json"):
        written.add "d/" & slug & "/tx/" & path.replace('\\', '/')
    ck written.len > 0
    let computed = txFactsPath(slug, shouted, enc)
    if computed notin written:
      checkpoint("the client computes " & computed &
                 " and the producer wrote none of: " & written.join(", "))
    ck computed in written
    # …and the file is actually there, which is the thing a 404 is about.
    ck fileExists(tree / computed)
    # BOTH SEGMENTS, stated separately, because half-folding is precisely the
    # failure where one of them is right.
    ck computed.contains("/tx/" & shardKeyFor("hex", shouted) & "/")
    ck computed.endsWith("/" & rawHash & ".json")
    ck not computed.contains(shouted)
    # …and the whole SDK read resolves from the spelling the capture carried, not
    # only from the folded one. This is the 404 the defect produced.
    let store = localTree(tree)
    let r = transaction(store, opened.session, shouted)
    if r.outcome != roFound:
      checkpoint("the shouted spelling did not resolve: " & $r.outcome)
    ck r.outcome == roFound
    # ── WHAT THIS ARM DELIBERATELY DOES NOT CLAIM, AND THE RESIDUAL IT PINS ───
    #
    # The producer's PATHS are now recomputable. Its published REFERENCES are a
    # second question and are still the capture's own spelling: the block object's
    # `transactions` list, the height map's block hashes and the `tx` member of the
    # txstate body all carry whatever the capture carried, and
    # `checkIdentifierForms` requires a published reference to be its own KEY form.
    # So a capture carrying a non-key-form identifier produces a tree that the
    # validator REFUSES rather than one that quietly resolves, which is the right
    # failure and not the absence of one.
    #
    # It is not fixed here because it is not the same fix. Normalising a reference
    # means deciding where the producer folds — at the point it reads the capture,
    # which would discard an EIP-55 display form the contract says a body carries,
    # or per site, which is the fourteen-call-sites shape this change just removed. That
    # is an operator decision, and the residual is pinned here so it cannot be
    # mistaken for a passing case.
    let errs = validateTree(tree)
    if errs.len == 0:
      checkpoint("the validator accepted a tree republishing a non-key-form " &
                 "reference; the residual below has been closed and this arm " &
                 "needs rewriting rather than deleting")
    ck errs.len > 0
    var everyErrorIsAReference = true
    var namedTheForm = false
    for e in errs:
      if e.contains("key form"): namedTheForm = true
      if not (e.contains("key form") or e.contains("dangling")):
        everyErrorIsAReference = false
        checkpoint("unexpected validator error: " & e)
    ck everyErrorIsAReference
    ck namedTheForm
    # …and EVERY error names the reference's spelling rather than the object's, so
    # the tree the producer wrote is not among the things being complained about.
    for e in errs: ck e.contains(shouted)
    removeDir stage
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

  test "…FOR ALL THREE KINDS, AND NOT ONLY WHERE THE OBJECT RESOLVES":
    # ── THE ARM THAT FAILS ON THE PRE-FIX VALIDATOR ───────────────────────────
    #
    # `checkIdentifierForms` sat INSIDE `if bd == nil: continue` for blocks and
    # inside `if al == nil: continue` for addresses, while the transaction arm
    # deliberately sat OUTSIDE its guard with a comment arguing that outside is
    # right — "reporting only the dangle would send the reader looking for a
    # missing file". MEASURED with the identical mutation on both sides: a
    # non-key-form TRANSACTION reference gave 4 errors (the dangle AND `whose key
    # form is …`), a non-key-form BLOCK reference gave 1 (the dangle only).
    #
    # So "every published block reference is its own key form" — which is what
    # `blockPath`'s old no-fold reasoning leant on — held only for references that
    # RESOLVE, which is the population least in need of the check.
    #
    # Each kind is mutated in a SEPARATE tree, so a diagnosis cannot be supplied by
    # another kind's mutation, and each requires BOTH errors: the dangle (the object
    # is not where the reference says) and the form (the reference is wrong), which
    # is the pair the transaction arm's comment argues for.
    for kind in ["block", "address", "transaction"]:
      let t = buildDemo("forms-" & kind)
      ck validateTree(t).len == 0
      let slug = onlySlug(rawRegistry(t))
      let gen = parseJson(readFile(t / "d" / slug / "current.json"))["generation"].getStr
      let rootRel = t / "d" / slug / "g" / gen / "root.json"
      var root = parseJson(readFile(rootRel))

      case kind
      of "block":
        # The generation's BLOCK INDEX lists block hashes. Uppercase one: the
        # object it names is at the folded path, so it dangles, and the reference
        # itself is not a key form.
        let biRel = root["maps"]["blocks"][0].getStr
        var bi = parseJson(readFile(t / biRel))
        ck bi["blocks"].len > 0
        var shouted = newJArray()
        shouted.add %bi["blocks"][0].getStr.toUpperAscii
        for i in 1 ..< bi["blocks"].len: shouted.add bi["blocks"][i]
        bi["blocks"] = shouted
        writeFile(t / biRel, bi.pretty & "\n")
      of "address":
        # The sealed root NAMES its address indices by path, and the name segment
        # of that path is the identifier. Uppercase it in the root only — the
        # object stays where the producer put it, so the reference dangles.
        ck root["maps"]["addr"].len > 0
        let was = root["maps"]["addr"][0].getStr
        let parts = was.rsplit('/', 1)
        ck parts.len == 2
        var moved = newJArray()
        moved.add %(parts[0] & "/" &
                    parts[1].splitFile.name.toUpperAscii & ".json")
        for i in 1 ..< root["maps"]["addr"].len: moved.add root["maps"]["addr"][i]
        root["maps"]["addr"] = moved
        writeFile(rootRel, root.pretty & "\n")
      else:
        # The control, in the same run and by the same mechanism: the arm that
        # already worked. Without it, the two above could pass because the walk
        # reports every reference rather than because the guards moved.
        let biRel = root["maps"]["blocks"][0].getStr
        let bi = parseJson(readFile(t / biRel))
        let bh = bi["blocks"][0].getStr
        let bAbs = t / "d" / slug / "block" / (bh & ".json")
        var bd = parseJson(readFile(bAbs))
        ck bd["transactions"].len > 0
        var shouted = newJArray()
        shouted.add %bd["transactions"][0].getStr.toUpperAscii
        for i in 1 ..< bd["transactions"].len: shouted.add bd["transactions"][i]
        bd["transactions"] = shouted
        writeFile(bAbs, bd.pretty & "\n")

      let errs = validateTree(t)
      var namedTheForm, namedTheDangle = false
      for e in errs:
        if e.contains("key form") and e.contains(kind): namedTheForm = true
        if e.contains("dangling") or e.contains("missing object"):
          namedTheDangle = true
      if not namedTheForm:
        checkpoint(kind & ": the validator did not name the reference's form: " &
                   errs.join(" | "))
      ck namedTheForm
      if not namedTheDangle:
        checkpoint(kind & ": the validator did not report the dangle: " &
                   errs.join(" | "))
      ck namedTheDangle
      removeDir t

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
suite "a PRODUCER declares how its chain writes identifiers, and the reader keys by it":

  # ── WHY THIS SUITE EXISTS ────────────────────────────────────────────────
  #
  # `Data-Contract.md` §5.6 recorded this as a BLOCKER: the derivation took the
  # encoding as data, and no producer had a member with which to say which
  # encoding its chain used, so the reader called `hexIdentifierEncoding()`
  # unconditionally for every chain. A Tezos capture carrying canonical
  # base58check operation hashes therefore published them lowercased, at
  # addresses that do not exist on the chain, and the only repair available to
  # that producer was to fold its own identifiers — which makes the run green
  # and the tree wrong.
  #
  # `provenance.identifierEncoding` is the declaration. The suites above measure
  # the VALUE and the registry round trip; this one measures the READER: that it
  # reads the member, keys by what it read, publishes what it keyed with, and
  # refuses the declarations it cannot honour.
  #
  # NO MOCKS. Every tree is built by the real `ingestSnapshot` over a copy of the
  # committed mainnet capture with one member edited, and every path is checked
  # by asking the filesystem whether the object is there.

  proc ingestDeclaring(tag: string, decl: JsonNode): string =
    ## The real producer over a real capture whose provenance declares `decl`
    ## (or nothing, when `decl` is nil). Returns the tree.
    let snapDir = tmpDir(tag & "-snap")
    copyDir(LiveMainnet, snapDir)
    var snap = parseJson(readFile(snapDir / "snapshot.json"))
    if decl == nil:
      if snap["provenance"].hasKey("identifierEncoding"):
        snap["provenance"].delete("identifierEncoding")
    else: snap["provenance"]["identifierEncoding"] = decl
    writeFile(snapDir / "snapshot.json", snap.pretty & "\n")
    result = tmpDir(tag)
    discard ingestSnapshot(IngestConfig(outDir: result, snapshotDir: snapDir))
    removeDir snapDir

  proc refusedBy(tag: string, decl: JsonNode): string =
    ## The message the producer refuses a declaration with, or "" if it did not.
    try:
      let t = ingestDeclaring(tag, decl)
      removeDir t
      ""
    except ValueError as e:
      e.msg

  proc treeBytes(root: string): seq[(string, string)] =
    for p in relFiles(root): result.add (p, readFile(root / p))

  test "a capture that declares nothing is hex, and that is the additive rule":
    # The compatibility case, and it is the one every committed capture is in:
    # none of them carries the member, and the trees they publish are the trees
    # they always published.
    let tree = ingestDeclaring("decl-absent", nil)
    let row = rawRegistry(tree)["chains"][onlySlug(rawRegistry(tree))]
    ck row.hasKey("identifierEncoding")
    ck row["identifierEncoding"]["transaction"].getStr == "hex"
    ck row["identifierEncoding"]["address"].getStr == "hex"
    ck row["identifierEncoding"]["block"].getStr == "hex"
    removeDir tree

  test "…and a capture that DECLARES hex publishes the identical tree, byte for byte":
    # THE BYTE-NEUTRALITY CLAIM, AS A MEASUREMENT RATHER THAN AS A SENTENCE.
    # §5.6 said the member would be additive; this is the reading. The two trees
    # are built by the same producer over the same capture, one with the member
    # and one without, and every published path and every published byte is
    # compared.
    let a = ingestDeclaring("decl-none", nil)
    let b = ingestDeclaring("decl-hex", %*{"block": "hex", "transaction": "hex",
                                           "address": "hex"})
    let ba = treeBytes(a)
    let bb = treeBytes(b)
    # ANTI-VACUITY: two empty trees compare equal perfectly.
    ck ba.len >= 20
    var differing: seq[string]
    for i in 0 ..< max(ba.len, bb.len):
      if i >= ba.len or i >= bb.len or ba[i] != bb[i]:
        differing.add (if i < ba.len: ba[i][0] else: bb[i][0])
    if differing.len > 0:
      checkpoint("differing: " & differing.join(", "))
    ck differing.len == 0
    removeDir a
    removeDir b

  test "a DIFFERENT declaration moves every sharded path, so the reader reads it":
    # The control for the arm above: if the member were ignored, declaring
    # something else would change nothing. `base64url` preserves case and strips
    # no prefix, so the `0x` that hex strips is payload here and every shard
    # segment moves.
    let hexTree = ingestDeclaring("decl-hex2", %*{"block": "hex",
                                                  "transaction": "hex",
                                                  "address": "hex"})
    let b64Tree = ingestDeclaring("decl-b64url", %*{"block": "base64url",
                                                    "transaction": "base64url",
                                                    "address": "base64url"})
    let hexPaths = relFiles(hexTree)
    let b64Paths = relFiles(b64Tree)
    ck hexPaths.len == b64Paths.len          # the same objects…
    ck hexPaths != b64Paths                  # …at different addresses
    # And the addresses are the ones the DECLARATION implies, recomputed here
    # from the declared token rather than from the tree.
    let slug = onlySlug(rawRegistry(b64Tree))
    var checkedTx = 0
    for p in relFiles(hexTree):
      if not (p.startsWith("d/" & slug & "/tx/") and p.endsWith(".json")): continue
      let txHash = p.splitFile.name
      ck fileExists(b64Tree / txFactsPath(slug, txHash,
                    chainIdentifierEncoding({"transaction": "base64url"})))
      ck shardKeyFor("base64url", txHash) == txHash[0 ..< 4]
      ck shardKeyFor("hex", txHash) != shardKeyFor("base64url", txHash)
      inc checkedTx
    ck checkedTx >= 1
    # …and the registry states what the paths were keyed with, which is the whole
    # single-source property: one value published and derived from.
    let row = rawRegistry(b64Tree)["chains"][slug]
    ck row["identifierEncoding"]["transaction"].getStr == "base64url"
    ck row["identifierEncoding"]["address"].getStr == "base64url"
    ck row["identifierEncoding"]["block"].getStr == "base64url"
    removeDir hexTree
    removeDir b64Tree

  test "base64 is DECLARABLE and not shardable, and is refused by name":
    # §5.6's named blocker: the member is in the closed set and its alphabet
    # contains `/`, so about one 44-character digest in eight would publish into
    # a nested directory. The refusal happens before anything is written, names
    # the encoding and the kind, prints BOTH halves of the set, and says what
    # closing it needs.
    ck isIdentifierEncoding("base64")
    ck not isShardableIdentifierEncoding("base64")
    let msg = refusedBy("decl-b64", %*{"block": "hex", "transaction": "base64",
                                       "address": "hex"})
    ck msg.len > 0
    ck msg.contains("S5-IDENTIFIER-ENCODING-SHARDABLE")
    ck msg.contains("'base64'")
    ck msg.contains("transaction")
    ck msg.contains("not legal in one")
    ck msg.contains(shardableIdentifierEncodingList())
    ck msg.contains(unshardableIdentifierEncodingList())
    ck msg.contains("identifier-encodings.json")
    ck msg.contains("Search-And-Routing.md")
    # The whole set is printed, both halves, and they partition it.
    var both = shardableIdentifierEncodingList().split(", ")
    both.add unshardableIdentifierEncodingList().split(", ")
    both.sort()
    ck both == identifierEncodingIds().sorted()
    ck unshardableIdentifierEncodingList() == "base64"

  proc declareAttempt(tag: string, decl: JsonNode):
      tuple[msg: string, tree: string, objects: int] =
    ## The producer's whole answer to one declaration: the message it refused
    ## with (empty when it did not refuse), the tree it wrote into, and HOW MANY
    ## objects are in that tree. The object count is the load-bearing part —
    ## "refused" and "refused before anything was written" are different claims,
    ## and only the second one is worth having.
    let snapDir = tmpDir(tag & "-snap")
    copyDir(LiveMainnet, snapDir)
    var snap = parseJson(readFile(snapDir / "snapshot.json"))
    snap["provenance"]["identifierEncoding"] = decl
    writeFile(snapDir / "snapshot.json", snap.pretty & "\n")
    let tree = tmpDir(tag)
    var msg = ""
    try:
      discard ingestSnapshot(IngestConfig(outDir: tree, snapshotDir: snapDir))
    except CatchableError as e:
      msg = e.msg
    removeDir snapDir
    result = (msg, tree, relFiles(tree).len)

  test "EVERY member of the closed set is decided before a byte is written":
    # ── THE RULE, AND WHY IT IS A RULE RATHER THAN A SNAPSHOT ───────────────
    #
    # A chain publishes under the encoding it DECLARES, and the publisher's
    # answer to a declaration is decided before anything is written. There are
    # exactly two answers and there is no third: either the declaration is
    # REFUSED, by name, and the tree is EMPTY; or it is ACCEPTED and a complete
    # tree is published whose registry row states that member and whose sharded
    # paths derive from it.
    #
    # The middle case is the one this arm exists to forbid — accepted at the top
    # and then failing from inside a path builder, halfway through a tree, with
    # objects already on disk. That is what an unshardable member did before the
    # declaration was checked up front, and a tree half-written under a key
    # layout nothing can recompute is worse than a refusal in exactly the way
    # that matters: the refusal is recoverable and the half-tree is published.
    #
    # ── IT IS ASSERTED OVER THE WHOLE POPULATION, which is what makes it a rule.
    #
    # The members are `identifierEncodingIds()`, read out of the shared closed
    # set at compile time, so a NINTH member added to
    # `tools/chain/identifier-encodings.json` is exercised here the moment it
    # exists. The arms above cover `hex`, `base64url` and `base64` one at a
    # time, and a list of three cannot see a fourth: this is the same shape as
    # a source scan whose subject list is written down, which cannot see a new
    # file in the directory it claims to cover.
    #
    # ── AND THE PARTITION IS THE DATA'S, NOT THIS TEST'S ───────────────────
    #
    # Which half a member falls in is `isShardableIdentifierEncoding` — a
    # question asked of the shared file, not answered here. So this arm says
    # NOTHING about which chains are currently able to publish; that moves as
    # the seam closes, and an arm naming today's blocked set would be a snapshot
    # with an expiry date on it rather than a check. What it says is that the
    # publisher's refusal set is EXACTLY the set the data declares unshardable,
    # in both directions.
    #
    # THE CONTROL IS IN THE SAME RUN, and it is the accepted half. A refusal is
    # only attributable to the declared encoding if some other declaration
    # publishes in the same loop over the same capture — otherwise "it refused"
    # is equally consistent with a producer that cannot publish at all.
    let members = identifierEncodingIds()
    # ANTI-VACUITY: an empty population satisfies every `for` below.
    ck members.len >= 6
    var refused, accepted: seq[string]
    for enc in members:
      let decl = %*{"block": enc, "transaction": enc, "address": enc}
      let got = declareAttempt("closed-" & enc, decl)
      if got.msg.len > 0:
        refused.add enc
        # REFUSED BEFORE ANYTHING WAS WRITTEN, which is the whole claim.
        if got.objects != 0:
          checkpoint("declaring '" & enc & "' refused with " & $got.objects &
                     " object(s) already written: " & got.msg)
        ck got.objects == 0
        # …naming the member and the rule, so the refusal is a diagnosis.
        ck got.msg.contains("'" & enc & "'")
        ck got.msg.contains("S5-IDENTIFIER-ENCODING-SHARDABLE")
      else:
        accepted.add enc
        # PUBLISHED, and the registry says what it was keyed with.
        ck got.objects >= 20
        let reg = rawRegistry(got.tree)
        let slug = onlySlug(reg)
        for kind in [KindBlock, KindTransaction, KindAddress]:
          ck reg["chains"][slug]["identifierEncoding"][kind].getStr == enc
        # …and a sharded object is at the address that declaration implies,
        # recomputed here from the token rather than read back from the tree.
        var found = 0
        for p in relFiles(got.tree):
          if not (p.startsWith("d/" & slug & "/tx/") and p.endsWith(".json")):
            continue
          let txHash = p.splitFile.name
          if fileExists(got.tree / txFactsPath(slug, txHash,
                        chainIdentifierEncoding({"transaction": enc}))):
            inc found
        ck found >= 1
      removeDir got.tree
    refused.sort()
    accepted.sort()
    # ── the two halves are the DATA's halves, in both directions ────────────
    var wantRefused, wantAccepted: seq[string]
    for enc in members:
      if isShardableIdentifierEncoding(enc): wantAccepted.add enc
      else: wantRefused.add enc
    wantRefused.sort()
    wantAccepted.sort()
    if refused != wantRefused or accepted != wantAccepted:
      checkpoint("refused " & refused.join(",") & " (declared unshardable: " &
                 wantRefused.join(",") & "); published " & accepted.join(",") &
                 " (declared shardable: " & wantAccepted.join(",") & ")")
    ck refused == wantRefused
    ck accepted == wantAccepted
    # …and both halves are non-empty, so neither direction is vacuous and the
    # accepted half is the control the refused half is attributable against.
    ck refused.len >= 1
    ck accepted.len >= 1
    # Every member is in exactly one half, which is the partition itself.
    ck refused.len + accepted.len == members.len

  test "a token outside the closed set is refused naming the set, not read as hex":
    let msg = refusedBy("decl-bad-token", %*{"block": "hex",
                                             "transaction": "base32",
                                             "address": "hex"})
    ck msg.contains("S5-IDENTIFIER-ENCODING-CLOSED")
    ck msg.contains("'base32'")
    ck msg.contains(identifierEncodingList())

  test "a kind outside the closed set is refused naming the kinds":
    let msg = refusedBy("decl-bad-kind", %*{"block": "hex", "transaction": "hex",
                                            "address": "hex",
                                            "traceArtifactId": "hex"})
    ck msg.contains("S5-IDENTIFIER-ENCODING-CLOSED")
    ck msg.contains("traceArtifactId")
    ck msg.contains(identifierKindList())

  test "a kind this producer writes a path for may not be omitted":
    # An omitted kind is LEGAL in the contract — Substrate's `blockIndex`
    # transaction identity is the case that forces it — and `encodingFor` raises
    # on one. That raise would arrive from inside a path builder, halfway through
    # a tree. This producer writes all three, so it refuses before it starts.
    for kind in [KindBlock, KindTransaction, KindAddress]:
      var decl = %*{"block": "hex", "transaction": "hex", "address": "hex"}
      decl.delete(kind)
      let msg = refusedBy("decl-omit-" & kind, decl)
      ck msg.contains("S5-IDENTIFIER-ENCODING-CLOSED")
      ck msg.contains("declares no identifier encoding for kind '" & kind & "'")

  test "a declaration of the wrong SHAPE is refused rather than shrugged at":
    let msg = refusedBy("decl-shape", %"hex")
    ck msg.contains("S5-IDENTIFIER-ENCODING-CLOSED")
    ck msg.contains("object of kind -> encoding")

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
    # THREE SWEEPS, AND THEY ARE THREE FACTS. A file may key an identifier
    # without reading a registry row, may read the row without keying anything
    # (the session pins it), and may derive a §5 INDEX key without doing either —
    # that third one arrived when the index stopped being hex-only and started
    # keying per identifier SHAPE, which needs no registry at all. One merged
    # allowlist would let a new consumer of any seam be excused by another's.
    ck bnd{"sweeps"}.len == 3
    ck bnd["sweeps"][0]["id"].getStr == "declaration"
    ck bnd["sweeps"][1]["id"].getStr == "caseRule"
    ck bnd["sweeps"][2]["id"].getStr == "indexKey"
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
          # OVER CODE AND NOT OVER THE WHOLE FILE, for the reason the `pins` below
          # already matched that way — and this half of the equality is why it
          # matters more here than there. Matched over the whole file, the
          # "expected consumer that stopped being one" direction is INERT for any
          # entry whose doc comment still names the token, which was MEASURED at
          # 14 of the 22 expected entries. The proof: reverting
          # `client/src/viewmodel/search_shapes.nim` to its own unconditional
          # `toLowerAscii` leaves nought code occurrences of all three `caseRule`
          # tokens and one in a doc comment, and both halves stayed green — no
          # behavioural test catches it either, because for lowercase hex the
          # revert is byte-equivalent. Deleting the comment's mention as well
          # reddened both, which is what proved the comment was what saved it.
          let src = codeOf(readFile(RepoRoot / rel))
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
    # 8 AND NOT 9: `src/blocktracer_client_paths.nim` left this set when the sweep
    # started matching over CODE. It is two lines of `import`/`export` under a
    # sixty-line header, and its only mention of the member was in that header —
    # so it is DOCUMENTATION of `blocktracer_client/paths.nim`'s signature rather
    # than a second reader of the declaration, and the module it re-exports is in
    # the set. Should it ever grow code that reads the member, the sweep's forward
    # direction reddens on it as an unexpected consumer.
    # …and it is 9 AGAIN, for a different file: `contract/hashshard.nim` joined
    # when the index stopped being hex-only and started reading the shard rule
    # back to reconstruct a format-1 entry's `0x`, which format 1 cannot store.
    # 10 AND NOT 9: `verify/audit.nim` joined 2026-09-29 with the production
    # verifier — it derives sampled object keys from identifiers, so it reads
    # the chain's encoding from the registry row instead of assuming hex.
    ck expectedLen("declaration", "src") == 10
    ck expectedLen("declaration", "client") == 7
    # 3 AND NOT 2: `tools/chain/snapshot-contract-selftest.mjs` joined when §5.6's
    # declaration became reachable. The member is in §5.2b's census now, so the
    # census check names it — and its §15 asserts the SHAPE of the reader's one
    # binding, which is a claim about `ingest.nim`'s source that no behavioural
    # test can make. It derives nothing; it reads a Nim file as text.
    #
    # `tools/ci/hostile-chain-corpus.mjs` joined on 2026-09-29, and it is the
    # first member that names the declaration in order to LEAVE IT ALONE. That
    # generator poisons every snapshot string it does not recognise as
    # structural, and a closed-set enum spelling is not a byte any chain decides
    # — poisoning it only makes `ingest` refuse on the closed-set rule before a
    # page renders, which is how `ci/test/untrusted-text.sh` came to exit 2 with
    # 0 pages scanned, measuring nothing while reporting a failure.
    #
    # The set therefore holds two KINDS of member now: readers that derive
    # behaviour from the declaration, and exempters that name it to avoid
    # corrupting it. The sweep asks who NAMES the member, so both belong — but
    # only the first kind is a consumer, and a future reviewer counting
    # "consumers" from this number would over-count by one.
    ck expectedLen("declaration", "tools") == 3
    ck expectedLen("caseRule", "src") == 6
    ck expectedLen("caseRule", "client") == 3
    ck expectedLen("caseRule", "tools") == 1
    # THE THIRD SWEEP. A file may derive a §5 INDEX key without reading a
    # registry row at all — that is the whole point of keying per identifier
    # SHAPE — so its population is asserted separately from the other two.
    ck expectedLen("indexKey", "src") == 4
    ck expectedLen("indexKey", "client") == 3
    ck expectedLen("indexKey", "tools") == 1
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
    # The binding is an EXPRESSION — `let x = block:` — so there is nowhere to
    # reassign it, and the value it takes comes from the producer's own
    # declaration rather than from a constant in this reader. §5.6 was open
    # precisely because that constant was unconditional.
    ck ingest.contains("let identifierEncoding = block:")
    ck ingest.contains("prov{\"identifierEncoding\"}")
    ck not ingest.contains("var identifierEncoding")
    ck ingest.contains(
      "\"identifierEncoding\": identifierEncoding.identifierEncodingNode()")
    ck not ingest.contains("\"identifierEncoding\": {")
    ck codeOccurrences(ingest, "hexIdentifierEncoding()") == 1

    let gen = readFile(RepoRoot / "src/blocktracer/demo/generator.nim")
    ck gen.contains("identifier_encoding")
    ck gen.contains(
      "\"identifierEncoding\": demoIdentifierEncoding().identifierEncodingNode()")
    ck not gen.contains("\"identifierEncoding\": {")
    ck codeOccurrences(gen, "hexIdentifierEncoding()") == 1

    # ── AND NEITHER TAKES A SHARD KEY OF ITS OWN ────────────────────────────
    #
    # This used to require the opposite — `shardKeyFor(txEncoding, …)` present at
    # least once in each producer — and that requirement WAS the defect. A
    # producer holding a shard key is, by construction, holding one half of a
    # two-segment path whose other half it then writes by hand, and the day
    # `shardKeyFor` began folding per the declared case rule, the twelve SHARDED
    # sites among the fourteen hand-built paths became a FOLDED shard beside a
    # RAW name. (Fourteen and twelve, not nine: seven sites in each producer, of
    # which one per producer is the unsharded block path.) MEASURED on an
    # uppercased `txHash`: the producer wrote
    # `d/{chain}/tx/0a80/0x0A807E….json` while the client computed
    # `d/{chain}/tx/0a80/0x0a807e….json`, a 404 — and every committed identifier
    # being lowercase is the only reason no published byte was ever wrong.
    #
    # So the builders moved into `contract/shards.nim`, which a producer MAY
    # import, and both producers now derive both segments from one expression.
    # `blocktracer_client/paths.nim` re-exports them, so no consumer moved.
    for rel in ["src/blocktracer/chain/ingest.nim",
                "src/blocktracer/demo/generator.nim"]:
      let src = readFile(RepoRoot / rel)
      ck codeOccurrences(src, "shardKeyFor(") == 0
      for builder in ["blockPath(", "txFactsPath(", "txStatePath(",
                      "traceSelectionPath(", "addressIndexPath(",
                      "addressSegmentPath("]:
        ck codeOccurrences(src, builder) >= 1
      # …and no hand-built sharded path is left beside them. These are the six
      # literal prefixes the fourteen removed sites began with.
      for handmade in ["\"d\" / chain / \"tx\"", "\"d\" / chain / \"ts\"",
                       "\"d\" / chain / \"seg\"", "\"d\" / chain / \"block\"",
                       "\"txstate\" /", "\"addr\" /"]:
        ck codeOccurrences(src, handmade) == 0

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
    # 11 AND NOT 8: the hash-index pin grew. `hexToBytes` joined `stripHex` on
    # the ABSENT list, and the private `hexUnits` that replaced it is pinned by
    # COUNT alongside `identifierIndexKey` and `parseHexInt` — because the
    # byte-identity mutant proved a count is exactly what catches a path that
    # slips in FRONT of the refusal rather than behind it.
    ck checkedPins == 11
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
    # THE BAN WAS "NO `toLowerAscii` AT ALL" AND IT IS NOW "NONE THAT IS NOT
    # DECLARED", because `shardKey.foldKey` gave this module one legitimate fold:
    # the PAD. `pad` is declared in the alphabet's own spelling (`A` is base64's
    # zero digit), so a folded payload padded with the declared spelling yields
    # `eqAA` — a name that is not closed under case folding, which is the property
    # the fold exists to establish. The narrower ban is what the original was
    # protecting: an UNCONDITIONAL fold is right for hex and destroys the four
    # case-significant members, so every fold in this module must be reached only
    # through the member's own declaration.
    ck sh.contains("identifierShardPayload(encoding, identifier)")
    ck not codeOf(sh).contains("toUpperAscii")
    let code = codeOf(sh)
    var folds, declaredFolds = 0
    for line in code.splitLines:
      if line.contains("toLowerAscii"):
        inc folds
        if line.contains("rule.foldKey"): inc declaredFolds
    # ANTI-VACUITY: a sweep that found no fold would satisfy the equality below
    # by matching nothing, which is this repository's own first trap.
    ck folds == 1
    ck declaredFolds == folds

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

# 892 -> 894: PRE-EXISTING AND NOT MINE, and the two are named so the next reader
# does not have to re-derive them. `7dbc566` ("Merge dev into agents: reconcile the
# two sides of the renderer pin refactor") added TWO entries to the `expected` sets
# of the `declaration` sweep — `verify/audit.nim` under src/ (9 -> 10) and
# `tools/ci/hostile-chain-corpus.mjs` under tools/ (2 -> 3) — and each `expected`
# entry contributes one `ck fileExists(...)` in the sweep arm. The `expectedLen`
# assertions beside them were bumped; this total was not.
#
# MEASURED BEFORE TOUCHING ANYTHING: a detached worktree at `18b7eec8`, the
# unmodified revision, reports `assertion count is 894, expected 892` — so the
# expectation was stale rather than the code being wrong, and the suite has been
# red on `agents` since that merge. Recorded here because a declared count is only
# evidence if the number and the reason travel together.
expectCount(894)
