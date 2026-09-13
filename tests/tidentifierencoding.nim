## The registry's per-chain identifier-encoding declaration — Configuration.md
## §2.1 (the schema) and §2.2 (the additive rule).
##
## ## What this suite is about, and the one thing it is not about
##
## An identifier's encoding is now stated as DATA in the published registry
## (`chains[<slug>].identifierEncoding`) rather than being inferred from the
## string. **Nothing reads it.** Shard derivation, the hash index, the client's
## local path recomputation and the capture tooling all still derive from the
## string, and the assumption they share is `0x` + hex; widening them is separate
## work whose last step rewrites a published wire format.
##
## So the property under test here is NOT that something consumes the field. It
## is the opposite, and it is the one §2.2 requires: a client built against the
## schema **without** this member reads a registry carrying it and behaves
## identically. Suite 4 measures that, and — because an equality that cannot fail
## is not evidence — it measures three controls in the same run, each a change to
## a member the same reader IS built for, each of which changes or refuses.
##
## Suite 5 states the boundary mechanically: the field is written at two sites and
## read at none, over `src/` swept, nine named consumer-side files, and `client/`
## and `tools/` swept behind a population floor. Those arms are expected to go RED
## when a consumer is wired in, which is correct. The person adding the consumer
## should move the site out of the boundary deliberately, not discover afterwards
## that nothing noticed.
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

import std/[unittest, os, json, strutils, algorithm]

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
suite "the field is declared at two sites and read at none":

  # ── WHY A SOURCE SCAN IS THE ONLY WAY TO ASSERT THIS ──────────────────────
  #
  # "Nothing reads it" is a claim about the whole tree, and no behavioural test
  # can establish it: a reader that read the member and happened to agree with
  # the old answer today would pass every arm above. The boundary is the
  # deliverable here — the declaration lands alone precisely so the risky part
  # lands alone later — so it is asserted as what it is.
  #
  # THESE ARMS ARE EXPECTED TO GO RED WHEN A CONSUMER IS WIRED IN. That is them
  # working. Whoever adds the consumer moves its file out of the boundary
  # deliberately, having read this comment, rather than finding out afterwards
  # that nothing had been watching it.
  #
  # THE SCAN IS BOTH NAMED AND SWEPT, because neither alone is enough. `src/` and
  # the named list catch the sites the widening is going to reach and fail loudly
  # if one of them stops existing; the sweep over `client/` and `tools/` catches
  # the ones nobody thought to name. Naming alone was measured leaking: a consumer
  # planted one file over from a named file passed every arm here. Sweeping alone
  # is an empty-set green, so the sweep carries a population floor.

  const Member = "identifierEncoding"

  test "the writers are the two registry producers and nothing else":
    var writers: seq[string]
    for rel in relFiles(RepoRoot / "src"):
      if not rel.endsWith(".nim"): continue
      if readFile(RepoRoot / "src" / rel).contains(Member):
        writers.add "src/" & rel
    writers.sort()
    ck writers == @["src/blocktracer/chain/ingest.nim",
                    "src/blocktracer/contract/identifier_encoding.nim",
                    "src/blocktracer/demo/generator.nim"]

  test "no consumer-side surface mentions it":
    # The four derivation sites the widening will have to reach, plus the client
    # and the capture tooling. Each is named rather than swept, so a directory
    # that stopped existing cannot silently empty the check.
    for rel in ["src/blocktracer/contract/shards.nim",
                "src/blocktracer/contract/hashshard.nim",
                "src/blocktracer_client/paths.nim",
                "src/blocktracer_client/decode.nim",
                "src/blocktracer_client/session.nim",
                "client/src/viewmodel/chain_registry_vm.nim",
                "client/searchboot/searchboot.nim",
                "tools/capture/lib/entities.mjs",
                "tools/dev/dump_recorder_provenance.nim"]:
      ck fileExists(RepoRoot / rel)
      ck not readFile(RepoRoot / rel).contains(Member)

  test "…and no file under client/ or tools/ does either, SWEPT rather than named":
    # The named list above is deliberate — a named file that stops existing fails
    # loudly instead of emptying the check — but naming is not exhaustive, and the
    # gap was MEASURED rather than imagined: a consumer planted in
    # `client/src/viewmodel/chain_vm.nim`, next door to the named
    # `chain_registry_vm.nim`, and one in `tools/capture/lib/provenance.mjs`, next
    # door to the named `entities.mjs`, both landed with every other arm in this
    # file green and with the JavaScript selftest still printing "nothing reads the
    # declaration yet". `src/` was already swept by the arm above; these two trees
    # were not, and they hold the client and the capture tooling — which are two of
    # the four derivation sites the widening has to reach.
    #
    # WITH A FLOOR ON WHAT WAS VISITED, PER DIRECTORY. An exhaustive scan whose
    # expected answer is "no file" is satisfied perfectly by scanning no files, so
    # the population is asserted as well; per directory, so an emptied sweep of one
    # cannot hide behind the other. That is the whole difference between this arm
    # and the empty-set green it would otherwise be.
    #
    # ONE FILE MAY NAME THE MEMBER, and it is asserted to be exactly that one: the
    # JavaScript half's selftest, whose own job is to check that nothing reads it.
    const
      Allowed = ["tools/chain/identifier-encoding-selftest.mjs"]
      SourceExt = [".nim", ".mjs", ".js", ".ts", ".sh"]
    var reading: seq[string]
    for (top, floor) in [("client", 80), ("tools", 100)]:
      var scanned = 0
      for rel in relFiles(RepoRoot / top):
        if rel.splitFile.ext notin SourceExt: continue
        # Generated and vendored trees are not this repository's source.
        if rel.contains("node_modules/") or rel.contains("dist/") or
           rel.contains("nimcache/"): continue
        inc scanned
        let path = top & "/" & rel
        if path in Allowed: continue
        if readFile(RepoRoot / path).contains(Member):
          reading.add path
      if scanned < floor:
        checkpoint(top & "/: swept " & $scanned & " source file(s), floor " & $floor &
                   " — an emptied sweep is not a green")
      ck scanned >= floor
    if reading.len > 0:
      checkpoint("these files read " & Member & ": " & reading.join(", "))
    ck reading.len == 0
    # …and the single allowance is real, so it is not quietly widening the arm.
    for rel in Allowed:
      ck fileExists(RepoRoot / rel)
      ck readFile(RepoRoot / rel).contains(Member)

  test "the producers reach the set through the shared reader, not a literal":
    # A producer spelling the tokens itself would be a second closed set, and the
    # second one is always the one that goes stale. Both write the member as a
    # CALL; neither contains an inline object of tokens.
    for rel in ["src/blocktracer/chain/ingest.nim",
                "src/blocktracer/demo/generator.nim"]:
      let src = readFile(RepoRoot / rel)
      ck src.contains("identifier_encoding")
      ck src.contains("\"identifierEncoding\": hexIdentifierEncoding()")
      ck not src.contains("\"identifierEncoding\": {")

expectCount(160)
