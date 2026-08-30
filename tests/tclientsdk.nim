## SDK-CONSUMER: the consumer-side conformance suite for @blocktracer/client.
##
## M12a's test suite for the Client SDK (BlockTracer/Client-SDK.md).
##
## Covers the milestone's verification points that are checkable in this
## repository:
##   - test_a_pinned_generation_is_never_mixed
##   - test_the_client_carries_no_identity
##   - test_the_contract_has_a_reference_implementation_at_both_ends
##   - test_conformance_does_not_use_the_reader_as_its_own_oracle
## and the deliverables: contract types imported never redeclared, `absent` as
## data with its reason, deep-link parsing/emission with the content witness and
## its precedence, and source-bundle resolution per code hash.
##
## `test_the_embed_sdk_contains_no_chain_concept` is a shell guard, not a Nim
## test: it constrains a package in another repository and has to run without a
## Nim toolchain in the cheap half of CI. It lives in
## `ci/test/client-sdk-boundary.sh`, with its own self-test in
## `ci/test/client-sdk-boundary-test.sh`.
##
## ## The discipline this file follows
##
## **The reader is never its own oracle.** Ground truth is read INDEPENDENTLY
## with `std/json` from the bytes on disk, never through the package under test,
## and every oracle here is accompanied by a MUTATION BITE that breaks the thing
## it checks and asserts the check fails. A test that only ever passes has not
## been shown to test anything.
##
## The suite imports the SDK **only through its facade** — plus
## `blocktracer/contract/model` deliberately, to assert that the SDK's types ARE
## the contract's rather than a second declaration of them.

import std/[unittest, os, json, strutils, sha1, sequtils, algorithm]

import ../src/blocktracer_client
import ../src/blocktracer/contract/model as contractModel
import ../src/blocktracer/contract/ids as contractIds
import ../src/blocktracer/validator
import ../src/blocktracer/demo/generator

const
  Chain = "aztec"
  FixtureDir = currentSourcePath().parentDir.parentDir / "fixtures" / "trace" /
               "noir_space_ship"
  # The REAL `noir_space_ship` CTFS container recorded by `nargo trace`.
  Fixture = FixtureDir / "zk_shields.ct"
  SourcesDir = FixtureDir / "sources"

proc tmp(name: string): string =
  result = getTempDir() / "blocktracer-clientsdk-test" / name
  removeDir result
  createDir result

proc synthHash(seed, kind: string, n: int): string =
  "0x" & toLowerAscii($secureHash(seed & "|" & kind & "|" & $n))[0 .. 39]

proc writeJsonNl(path: string, node: JsonNode) =
  createDir parentDir(path)
  writeFile(path, node.pretty & "\n")

# ===========================================================================
# The contract types are IMPORTED, never redeclared
#
# If the SDK had declared its own `TraceAvailability`, these would be two
# distinct types and the file would not compile. That is the assertion: it is
# made by the type system, at compile time, and cannot be satisfied by a
# coincidence of field names.
# ===========================================================================

suite "M12a — contract types imported verbatim from M5b, never redeclared":
  test "the SDK's vocabulary IS the contract's, by type identity":
    check contractModel.TraceAvailability is blocktracer_client.TraceAvailability
    check contractModel.OutcomeOverall is blocktracer_client.OutcomeOverall
    check contractModel.Role is blocktracer_client.Role
    check contractModel.Cost is blocktracer_client.Cost
    check contractModel.BlockDetail is blocktracer_client.BlockDetail
    check contractModel.TransactionFacts is blocktracer_client.TransactionFacts
    check contractModel.TraceSelection is blocktracer_client.TraceSelection
    check contractModel.TraceManifest is blocktracer_client.TraceManifest
    check contractModel.ValidationSummary is blocktracer_client.ValidationSummary

  test "a value built with the CONTRACT's constructor is accepted by the SDK":
    # Constructed with `contractModel`'s type, consumed by an SDK proc. This
    # compiles only while there is one type rather than two that look alike.
    let sel = contractModel.TraceSelection(chain: Chain, tx: "0xabc",
      hasSingle: true,
      singleTrace: contractModel.ExecTrace(availability: taReady, bytes: 10))
    let execs = allExecTraces(sel)
    check execs.len == 1
    check execs[0].availability == taReady

  test "decoding is the exact inverse of the contract's own encoding":
    # A round trip through the producer's `toJson` and the consumer's `decode`.
    # The oracle is the producer's encoder, which the decoder shares no code
    # with, so a decoder that silently drops a field fails here.
    let facts = contractModel.TransactionFacts(
      chain: "eth",
      id: TxId(kind: tikHash, hash: "0xdead"),
      order: TxOrder(kind: tokBlockIndex, obBlock: "0xb", obHeight: 7, obIndex: 3),
      outcome: Outcome(overall: ooReverted, reason: "InsufficientBalance()",
                       parts: @[%*{"unit": "call", "outcome": "reverted"}]),
      roles: @[Role(role: "initiator", address: "0x1")],
      cost: @[Cost(name: "gas", used: "21000", limit: "21000", price: "12",
                   unit: "gas", token: "ETH", refundable: false)],
      payloadRaw: "0xa9059cbb", payloadSelector: "0xa9059cbb",
      payloadTarget: "0x3", logs: @[%*{"topic": "0x0"}],
      codeEdges: @[CodeEdge(address: "0x3", codeHash: "0xc0de", boundAt: "0xb")],
      executions: @[Execution(selector: "call", executionInputId: "sha1:1")],
      native: %*{"evm": {"type": 2}})
    check decodeTransactionFacts(facts.toJson).toJson == facts.toJson

    # MUTATION BITE: drop a field from the encoded form and the round trip must
    # stop agreeing (rather than the decoder inventing a default that matches).
    var mangled = facts.toJson
    mangled["roles"] = newJArray()
    check decodeTransactionFacts(mangled).toJson != facts.toJson

# ===========================================================================
# The demo tree, read through the SDK
# ===========================================================================

let demoDir = tmp("demo")
discard generate(DemoConfig(outDir: demoDir, seed: "sdk-seed",
                            traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
let demoStore = localTree(demoDir)

proc openDemo(): ChainSession =
  let o = openChain(demoStore, Chain)
  doAssert o.outcome == ooOpened, "demo tree did not open: " &
    (if o.outcome == ooOpened: "" else: o.reason)
  o.session

suite "M12a — the read path over a published tree":
  let session = openDemo()

  test "the registry is the chain inventory":
    check chains(demoStore) == @[Chain]

  test "opening pins one generation, one overlay version and the recorder":
    check session.generation == "1"
    check session.traceSelectionVersion == "1"
    check session.contractVersion == ContractVersion
    check session.hasPin
    check session.pin.recorder.id.len > 0
    check session.pin.traceSchema.len > 0

  test "blocks come back newest first, from the sealed root's height map":
    let refs = blockRefsNewestFirst(demoStore, session)
    check refs.len == 3
    check refs.mapIt(it.height) == @[102, 101, 100]
    # INDEPENDENT ORACLE: the heights come from the raw height map, read here
    # with std/json rather than through the SDK.
    let raw = parseFile(demoDir / "d" / Chain / "g" / "1" / "height" / "0.json")
    var expected: seq[int]
    for h, _ in raw["heights"]: expected.add parseInt(h)
    check expected.sorted(SortOrder.Descending) == refs.mapIt(it.height)

  test "a chain that is not in the tree is data, not an exception":
    let o = openChain(demoStore, "no-such-chain")
    check o.outcome == ooChainNotFound
    check o.reason.len > 0

  test "an unsupported contract version is refused rather than misread":
    let d = tmp("badversion")
    discard generate(DemoConfig(outDir: d, seed: "v", traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
    let rp = d / "d" / Chain / "g" / "1" / "root.json"
    var root = parseFile(rp)
    root["contractVersion"] = %(ContractVersion + 99)
    writeFile(rp, root.pretty & "\n")
    let o = openChain(localTree(d), Chain)
    check o.outcome == ooUnsupportedContract
    check o.reason.contains($(ContractVersion + 99))

  test "a pointer disagreeing with the sealed root about the overlay version is refused":
    let d = tmp("tsvdrift")
    discard generate(DemoConfig(outDir: d, seed: "v", traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
    let cp = d / "d" / Chain / "current.json"
    var cur = parseFile(cp)
    cur["traceSelectionVersion"] = %"9"
    writeFile(cp, cur.pretty & "\n")
    let o = openChain(localTree(d), Chain)
    check o.outcome == ooMalformed
    check o.reason.contains("traceSelectionVersion")

# ===========================================================================
# availability: absent is DATA WITH ITS REASON, never a failed fetch
# ===========================================================================

suite "M12a — availability is data, and `absent` never becomes a failed fetch":
  let session = openDemo()
  # txB, the Aztec private/public split.
  let splitTx = synthHash("sdk-seed", "tx", 1)

  test "the private half is absent WITH ITS REASON and addresses no artifact":
    let tr = transaction(demoStore, session, splitTx)
    check tr.outcome == roFound
    let traces = resolveTraces(demoStore, session, tr.view)
    check traces.len == 2
    var sawAbsent, sawReady = false
    for t in traces:
      if t.selector == "private":
        sawAbsent = true
        check t.kind == trkAbsent
        check t.availability == taAbsent
        check t.reason.len > 0
        check t.traceArtifactId == ""     # nothing to fetch, so nothing addressed
        check t.containerPath == ""
        check not t.isReplayable
      elif t.selector == "public":
        sawReady = true
        check t.kind == trkReady
        check t.isReplayable
        check t.contentHash.len > 0
    check sawAbsent and sawReady

    # INDEPENDENT ORACLE: the reason is the producer's own string, read here
    # straight off disk.
    let raw = parseFile(demoDir / "d" / Chain / "ts" / "1" /
                        hexShard(splitTx) / splitTx & ".json")
    var rawReason = ""
    for e in raw["executions"]:
      if e["selector"].getStr == "private": rawReason = e["reason"].getStr
    check rawReason.len > 0
    for t in traces:
      if t.selector == "private": check t.reason == rawReason

  test "resolving an unobservable execution issues NO request for a trace":
    let log = newRequestLog()
    let recording = recordingStore(demoStore, log)
    let s = openChain(recording, Chain)
    check s.outcome == ooOpened
    let tr = transaction(recording, s.session, splitTx)
    check tr.outcome == roFound
    let before = log.paths.len
    # Resolve ONLY the private half.
    let priv = resolveTrace(recording, s.session, tr.view, "private")
    check priv.kind == trkAbsent
    check log.paths.len == before      # not one byte was asked for
    # MUTATION BITE: the public half DOES fetch, so the assertion above is not
    # vacuously true of every resolution.
    let pub = resolveTrace(recording, s.session, tr.view, "public")
    check pub.kind == trkReady
    check log.paths.len > before

  test "onDemand still derives an address, and a 404 on it is not an error":
    # txD: published overlay says onDemand and no /t/ artifact exists.
    let onDemandTx = synthHash("sdk-seed", "tx", 3)
    let tr = transaction(demoStore, session, onDemandTx)
    check tr.outcome == roFound
    let t = resolveTrace(demoStore, session, tr.view, "")
    check t.kind == trkOnDemand
    check t.traceArtifactId.len > 0        # the client can GET it and offer generation
    check not t.hasManifest                # 404 — expected, not a failure
    check t.manifestError == ""
    check not fileExists(demoDir / t.manifestPath)

  test "a divergent trace stays replayable and is flagged":
    let divergentTx = synthHash("sdk-seed", "tx", 2)
    let tr = transaction(demoStore, session, divergentTx)
    let t = resolveTrace(demoStore, session, tr.view, "")
    check t.kind == trkDivergent
    check t.isReplayable                   # inspectable, with a banner
    check t.hasValidation
    check t.validation.status == vsDivergent

  test "a reconstructed trace is carried separately from availability":
    let reconstructedTx = synthHash("sdk-seed", "tx", 4)
    let tr = transaction(demoStore, session, reconstructedTx)
    let t = resolveTrace(demoStore, session, tr.view, "")
    check t.kind == trkReady
    check t.reconstructed
    check t.validation.status == vsUnchecked

  test "an `absent` with no reason is refused rather than presented":
    # §2.3a REQUIRES a reason. A consumer that renders a reasonless `absent` is
    # showing the user something indistinguishable from a failed fetch.
    let d = tmp("reasonless")
    discard generate(DemoConfig(outDir: d, seed: "sdk-seed",
                                traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
    let op = d / "d" / Chain / "ts" / "1" / hexShard(splitTx) / splitTx & ".json"
    var ov = parseFile(op)
    for e in ov["executions"]:
      if e["selector"].getStr == "private": e.delete("reason")
    writeFile(op, ov.pretty & "\n")
    let s2 = openChain(localTree(d), Chain)
    let tr = transaction(localTree(d), s2.session, splitTx)
    check tr.outcome == roMalformed
    check tr.reason.contains("without a reason")

  test "the headline availability is the strongest execution, not the first":
    let tr = transaction(demoStore, session, splitTx)
    # The overlay lists `private` (absent) FIRST; the headline must still be
    # `ready`, or the Debug affordance would be disabled on a debuggable
    # transaction.
    check tr.view.execTraces[0].selector == "private"
    check headlineAvailability(tr.view) == taReady
    let traces = resolveTraces(demoStore, session, tr.view)
    check bestTrace(traces) == 1

# ===========================================================================
# test_a_pinned_generation_is_never_mixed
# ===========================================================================

suite "M12a — a pinned generation is never mixed":
  let d = tmp("pinning")
  discard generate(DemoConfig(outDir: d, seed: "pin", traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
  let log = newRequestLog()
  let store = recordingStore(localTree(d), log)

  # Open at generation 1 and hold the session.
  let opened = openChain(store, Chain)
  check opened.outcome == ooOpened
  let pinned = opened.session
  let readsOfPointerAtOpen = log.count(currentPath(Chain))

  # The pipeline publishes generation 2, carrying a new block, and flips the
  # pointer — exactly as it would mid-session.
  discard generate(DemoConfig(outDir: d, seed: "pin", traceFixturePath: Fixture, traceSourcesDir: SourcesDir,
                              generation: "2", extraBlocks: @[103]))

  test "the pointer really did move":
    check pinned.generation == "1"
    check publishedGeneration(store, Chain) == "2"
    check isSuperseded(store, pinned)

  test "the pinned session keeps reading ONE coherent generation":
    let refs = blockRefsNewestFirst(store, pinned)
    check refs.len == 3
    check refs.mapIt(it.height) == @[102, 101, 100]
    check 103 notin refs.mapIt(it.height)
    # Every generation-scoped read this session makes is under g/1.
    for p in log.paths:
      if p.contains("/g/"):
        check p.contains("/g/1/")

  test "the pointer was resolved ONCE, at open, and never again":
    # `publishedGeneration` and `isSuperseded` above are deliberate polls and
    # are counted separately from the navigation.
    let navLog = newRequestLog()
    let navStore = recordingStore(localTree(d), navLog)
    let o = openChain(navStore, Chain)
    check o.outcome == ooOpened
    let s = o.session
    for b in blockRefsNewestFirst(navStore, s):
      let bd = blockDetail(navStore, s, b.hash)
      check bd.outcome == roFound
      for txh in bd.detail.transactions:
        let tr = transaction(navStore, s, txh)
        check tr.outcome == roFound
        discard resolveTraces(navStore, s, tr.view)
    check navLog.count(currentPath(Chain)) == 1
    check readsOfPointerAtOpen == 1

  test "MUTATION BITE: a session opened NOW does see generation 2":
    # Without this the test above would pass for a tree that never advanced.
    let fresh = openChain(store, Chain)
    check fresh.outcome == ooOpened
    check fresh.session.generation == "2"
    let refs = blockRefsNewestFirst(store, fresh.session)
    check refs.len == 4
    check 103 in refs.mapIt(it.height)

  test "adopting is a deliberate transition that returns a NEW session":
    let adopted = adopt(store, pinned)
    check adopted.outcome == ooOpened
    check adopted.session.generation == "2"
    check pinned.generation == "1"    # the caller's session is untouched

# ===========================================================================
# test_the_client_carries_no_identity
# ===========================================================================

suite "M12a — the client carries no identity":
  let log = newRequestLog()
  let store = recordingStore(demoStore, log)

  test "a full navigation and trace open issues only anonymous path reads":
    let o = openChain(store, Chain)
    check o.outcome == ooOpened
    let s = o.session
    var opened = 0
    for b in blockRefsNewestFirst(store, s):
      let bd = blockDetail(store, s, b.hash)
      for txh in bd.detail.transactions:
        let tr = transaction(store, s, txh)
        for t in resolveTraces(store, s, tr.view):
          if t.isReplayable:
            discard store.get(t.containerPath)
            inc opened
    check opened > 0
    check log.paths.len > 20        # a real navigation, not an empty one

    for p in log.paths:
      # A request is a path under the published tree and nothing else. No query
      # string means no token, no visitor id, no cache-buster keyed to a user.
      check '?' notin p
      check '&' notin p
      check '=' notin p
      check '#' notin p
      check not p.startsWith("/")
      check not p.startsWith("http")
      check not p.contains("..")
      for token in ["token", "auth", "user", "session", "key", "id="]:
        check not p.toLowerAscii.contains(token)
      # Everything read is one of the published object classes.
      check p.startsWith("d/") or p.startsWith("t/") or p.startsWith("idx/") or
            p.startsWith("registry/") or p.startsWith("src/")

  test "the read seam cannot carry an identity even if a consumer wanted to":
    # The whole input to a read is a path. There is no header, credential or
    # request-options parameter to smuggle one through, which is why the
    # property above is structural rather than a habit.
    var seen: seq[string]
    let probe = newObjectStore("probe", proc(path: string): ObjectResponse =
      seen.add path
      ObjectResponse(found: false))
    discard probe.get("d/aztec/current.json")
    check seen == @["d/aztec/current.json"]

  test "a path escaping the published tree is refused, not fetched":
    var attempted = 0
    let probe = newObjectStore("probe", proc(path: string): ObjectResponse =
      inc attempted
      ObjectResponse(found: false))
    check not probe.get("../../etc/passwd").found
    check attempted == 0

# ===========================================================================
# Deep links — Debugger-Integration.md §6.0a
# ===========================================================================

suite "M12a — deep-link payload, witness and precedence":
  test "a well-formed link round-trips through emit and parse":
    let link = DeepLink(version: 1, coordinate: "s:12345",
      witness: "9c4d1f2e3a4b",
      anchor: Anchor(kind: akCall, data: "0.2.6"),
      execution: "public", frame: "3", panes: "cse")
    let frag = emitFragment(link)
    check frag.startsWith("#v=1&")
    let r = parseDeepLink(frag)
    check r.errors.len == 0
    check r.link.coordinate == link.coordinate
    check r.link.witness == link.witness
    check r.link.anchor.kind == akCall
    check r.link.anchor.data == "0.2.6"
    check r.link.execution == "public"

  test "a source anchor with slashes and colons survives the round trip":
    let link = DeepLink(version: 1, coordinate: "s:1", witness: "abc",
      anchor: Anchor(kind: akSource, data: "contracts/Vault.sol:42"))
    let r = parseDeepLink(emitFragment(link))
    check r.errors.len == 0
    check r.link.anchor.kind == akSource
    check r.link.anchor.data == "contracts/Vault.sol:42"

  test "`t` without its content witness is rejected":
    let r = parseDeepLink("#v=1&t=s:99")
    check r.errors.anyIt(it.contains("content witness"))

  test "a link carrying an artifact id is rejected (§6: it never carries one)":
    let r = parseDeepLink("#v=1&traceArtifactId=b7qk2m")
    check r.errors.anyIt(it.contains("artifact id"))
    let shared = shareLink(Chain, "0xabc",
      DeepLink(version: 1, coordinate: "s:1", witness: "abc",
               anchor: Anchor(kind: akRevert)))
    check shared.errors.len == 0
    check not shared.url.toLowerAscii.contains("artifact")

  test "Share always requires a recovery anchor (§6.3)":
    let noAnchor = shareLink(Chain, "0xabc",
      DeepLink(version: 1, coordinate: "s:1", witness: "abc"))
    check noAnchor.errors.anyIt(it.contains("recovery anchor"))

  test "an unknown link-schema version is reported, not guessed at":
    let r = parseDeepLink("#v=99&t=s:1&c=abc")
    check r.errors.anyIt(it.contains("unsupported link-schema version"))

  test "an unknown anchor kind is reported":
    let r = parseDeepLink("#v=1&a=teleport:7")
    check r.errors.anyIt(it.contains("unknown anchor kind"))

  test "the witness compares the digest, not the algorithm tag":
    check witnessFor("sha1:9C4D1F2E3A4B5C6D") == "9c4d1f2e3a4b"
    check checkWitness("9c4d1f2e3a4b", "sha1:9c4d1f2e3a4b5c6d") == wvMatches
    check checkWitness("9c4d1f2e3a4b", "blake3:9c4d1f2e3a4b5c6d") == wvMatches
    check checkWitness("9c4d1f2e3a4b", "sha1:0000000000000000") == wvDiffers
    check checkWitness("", "sha1:abc") == wvAbsent
    check checkWitness("abc", "") == wvUnknownArtifact

  # §6.0a's five steps, in order, each with the branch above it made
  # unavailable so the precedence itself is what is under test.
  let link = DeepLink(version: 1, coordinate: "s:12345", witness: "9c4d",
                      anchor: Anchor(kind: akLog, data: "3"))

  test "1. no replayable artifact is terminal and stated":
    let r = resolvePosition(link, PositionInputs(artifactAvailable: false))
    check r.outcome == poNoReplayableArtifact
    check r.visible
    check r.statement.len > 0

  test "2. a matching witness uses `t` exactly, and silently":
    let r = resolvePosition(link, PositionInputs(artifactAvailable: true,
      currentContentHash: "sha1:9c4dbeef"))
    check r.outcome == poExact
    check r.coordinate == "s:12345"
    check not r.visible          # the ONLY branch that is not stated
    check r.statement == ""

  test "3. a differing witness recovers from the anchor, and says so":
    let r = resolvePosition(link, PositionInputs(artifactAvailable: true,
      currentContentHash: "sha1:00000000", anchorResolved: true,
      anchorCoordinate: "s:777"))
    check r.outcome == poRecoveredByAnchor
    check r.coordinate == "s:777"
    check r.visible
    check r.statement.contains("regenerated")

  test "4. an unresolvable anchor falls back to the enclosing frame, plainly":
    let r = resolvePosition(link, PositionInputs(artifactAvailable: true,
      currentContentHash: "sha1:00000000", anchorResolved: false,
      enclosingFrameCoordinate: "s:700"))
    check r.outcome == poNearestEnclosingFrame
    check r.coordinate == "s:700"
    check r.visible
    check r.statement.contains("could not be resolved")

  test "5. otherwise the start of the execution, plainly":
    let bare = DeepLink(version: 1)
    let r = resolvePosition(bare, PositionInputs(artifactAvailable: true,
      currentContentHash: "sha1:abc", executionStartCoordinate: "s:0"))
    check r.outcome == poStartOfExecution
    check r.coordinate == "s:0"
    check r.visible

  test "an older link with no witness is treated as unverifiable, not trusted":
    let old = DeepLink(version: 1, coordinate: "s:12345",
                       anchor: Anchor(kind: akCall, data: "0.1"))
    let r = resolvePosition(old, PositionInputs(artifactAvailable: true,
      currentContentHash: "sha1:9c4dbeef", anchorResolved: true,
      anchorCoordinate: "s:5"))
    check r.outcome == poRecoveredByAnchor      # NOT poExact
    check r.witness == wvAbsent
    check r.visible

  test "the witness does not PIN an artifact — a corrected trace still reaches the reader":
    # The link resolves against whatever is currently recommended; the witness
    # only decides whether the coordinate transfers. A differing witness must
    # still land the reader in the CURRENT trace, never refuse to open it.
    let r = resolvePosition(link, PositionInputs(artifactAvailable: true,
      currentContentHash: "sha1:ffffffff", anchorResolved: true,
      anchorCoordinate: "s:9"))
    check r.outcome != poNoReplayableArtifact
    check r.coordinate == "s:9"

  test "the witness of a real resolved trace matches its manifest":
    let session = openDemo()
    let tx = synthHash("sdk-seed", "tx", 0)
    let tr = transaction(demoStore, session, tx)
    let t = resolveTrace(demoStore, session, tr.view, "")
    check t.isReplayable
    let w = witnessFor(t.contentHash)
    check w.len == DefaultWitnessLength
    check checkWitness(w, t.contentHash) == wvMatches
    # INDEPENDENT ORACLE: the hash off disk, not through the SDK.
    let manifestRaw = parseFile(demoDir / t.manifestPath)
    check checkWitness(w, manifestRaw["container"]["hash"].getStr) == wvMatches
    check checkWitness(w, "sha1:" & repeat("0", 40)) == wvDiffers

# ===========================================================================
# test_the_contract_has_a_reference_implementation_at_both_ends
#
# A SECOND producer — a different chain, different discriminated-union values,
# a different trace schema and published source bundles — written here by hand.
# The SDK reads it through the same code path, with no branch that could tell
# the two apart.
# ===========================================================================

proc buildEvmTree(dir: string): tuple[chain, tx, blk, codeHash, bundleId: string] =
  let chain = "eth"
  let recId = "evm"
  let recVer = "1.0.0"
  let recBuild = recorderBuildHash(recId, recVer)
  let profH = contractIds.profileHash("default")
  let traceSchema = "ctfs/v4"
  writeJsonNl(dir / "registry" / "chains.v1.json", %*{
    "version": ContractVersion,
    "chains": {chain: {
      "recorder": {"id": recId, "build": recBuild, "version": recVer},
      "profile": {"name": "default", "hash": profH},
      "traceSchema": traceSchema}}})
  let tx = "0xdeadbeef" & repeat("0", 56)
  let blk = "0xabc123" & repeat("0", 58)
  let codeHash = "0xc0de" & repeat("1", 36)
  let execId = demoExecutionInputId(chain, tx, "call")
  let facts = contractModel.TransactionFacts(
    chain: chain,
    id: TxId(kind: tikHash, hash: tx),
    order: TxOrder(kind: tokBlockIndex, obBlock: blk, obHeight: 19_000_000,
                   obIndex: 12),
    outcome: Outcome(overall: ooReverted, reason: "InsufficientBalance()", parts: @[]),
    roles: @[Role(role: "initiator", address: "0x1111" & repeat("0", 36)),
             Role(role: "feePayer", address: "0x2222" & repeat("0", 36))],
    cost: @[Cost(name: "gas", used: "21000", limit: "21000", price: "12",
                 unit: "gas", token: "ETH", refundable: false)],
    payloadRaw: "0xa9059cbb", payloadSelector: "0xa9059cbb",
    payloadTarget: "0x3333" & repeat("0", 36), logs: @[],
    codeEdges: @[CodeEdge(address: "0x3333" & repeat("0", 36),
                          codeHash: codeHash, boundAt: blk)],
    executions: @[Execution(selector: "call", executionInputId: execId)],
    native: %*{"evm": {"type": 2}})
  writeJsonNl(dir / "d" / chain / "tx" / hexShard(tx) / tx & ".json", facts.toJson)
  writeJsonNl(dir / "d" / chain / "block" / blk & ".json",
    contractModel.BlockDetail(chain: chain, hash: blk, height: 19_000_000,
      parentHash: "0x00", transactions: @[tx]).toJson)
  writeJsonNl(dir / "d" / chain / "g" / "1" / "txstate" / hexShard(tx) / tx & ".json",
    %*{"chain": chain, "tx": tx, "canonical": true, "finality": "finalized"})
  let ov = contractModel.TraceSelection(chain: chain, tx: tx, hasSingle: true,
    singleTrace: ExecTrace(availability: taReady, bytes: readFile(Fixture).len,
      hasValidation: true,
      validation: ValidationSummary(status: vsMatch, strength: 2)))
  writeJsonNl(dir / "d" / chain / "ts" / "1" / hexShard(tx) / tx & ".json", ov.toJson)

  let tid = deriveTraceArtifactId(execId, recId, recBuild, profH, traceSchema)
  let sh = traceShards(tid)
  let adir = dir / "t" / sh.a / sh.b / tid
  createDir adir
  let bytes = readFile(Fixture)
  writeFile(adir / "trace.ct", bytes)
  # This producer publishes its source bundle too (Source-Resolution.md §5), so
  # the second tree exercises the same manifest -> bundle edge the demo tree does.
  let evmBundle = %*{
    "schema": ContractVersion, "codeHash": codeHash, "chain": chain,
    "match": "full", "provider": "test-fixture", "language": "solidity",
    "compiler": {"name": "solc", "version": "0.8.24", "settings": {}},
    "sources": {"src/Token.sol": {"content":
      "// SPDX-License-Identifier: MIT\npragma solidity ^0.8.24;\n" &
      "contract Token { function transfer(address,uint256) external {} }\n"}},
    "debug": {}}
  let bundleId = contentHashSha1(evmBundle.pretty & "\n")
  # Full hex after the algorithm tag — see the note in demo/generator.nim.
  let bundleRel = "src" / chain / codeHash /
                  bundleId[bundleId.find(':') + 1 .. ^1] & ".json"
  writeJsonNl(dir / bundleRel, evmBundle)
  writeJsonNl(dir / "src" / chain / codeHash / "current.json",
    %*{"chain": chain, "codeHash": codeHash, "sourceBundleId": bundleId,
       "bundle": bundleRel})
  let manifest = contractModel.TraceManifest(schema: ContractVersion,
    traceArtifactId: tid, executionInputId: execId, chain: chain, tx: tx,
    recorder: RecorderRef(id: recId, build: recBuild, version: recVer),
    profile: ProfileRef(name: "default", hash: profH),
    sourceBundles: %*{codeHash: bundleId},
    container: ContainerRef(file: "trace.ct", bytes: bytes.len, blockSize: 4096,
      hash: contentHashSha1(bytes)),
    execution: ExecutionSummary(steps: 100, frames: 5, truncated: false,
      sourceLevel: true, languages: @["solidity"]),
    validation: ValidationSummary(status: vsMatch, strength: 2),
    validationOracle: "receipt-compare", prestateStrategy: "prestate-trace")
  writeJsonNl(adir / "manifest.json", manifest.toJson)

  let summaryRel = "d" / chain / "g" / "1" / "summary.json"
  let heightRel = "d" / chain / "g" / "1" / "height" / "0.json"
  let blocksRel = "d" / chain / "g" / "1" / "blocks" / "0.json"
  let txstateRel = "d" / chain / "g" / "1" / "txstate" / hexShard(tx) / tx & ".json"
  writeJsonNl(dir / summaryRel, %*{"chain": chain, "generation": "1",
    "counters": {"blocks": 1, "transactions": 1}, "coverageMode": "eager",
    "stale": false})
  writeJsonNl(dir / heightRel, %*{"chain": chain, "epoch": 0,
    "heights": {"19000000": blk}})
  writeJsonNl(dir / blocksRel, %*{"chain": chain, "epoch": 0, "blocks": [blk]})
  let root = contractModel.GenerationRoot(contractVersion: ContractVersion,
    chain: chain, generation: "1", traceSelectionVersion: "1",
    summaryPath: summaryRel, heightPaths: @[heightRel],
    blockIndexPaths: @[blocksRel], addrPaths: @[], txstatePaths: @[txstateRel])
  writeJsonNl(dir / "d" / chain / "g" / "1" / "root.json", root.toJson)
  writeJsonNl(dir / "d" / chain / "current.json", %*{"chain": chain,
    "generation": "1", "traceSelectionVersion": "1",
    "head": {"height": 19000000, "hash": blk},
    "finalized": {"height": 19000000, "hash": blk}})
  (chain, tx, blk, codeHash, bundleId)

suite "M12a — one contract, two producers, one consumer":
  let evmDir = tmp("evm")
  let ev = buildEvmTree(evmDir)
  let evmStore = localTree(evmDir)

  test "both trees satisfy M5b's PRODUCER validator":
    for errs in [validateTree(demoDir), validateTree(evmDir)]:
      for e in errs: echo "  ERR ", e
      check errs.len == 0

  test "both trees satisfy the CONSUMER-side conformance suite":
    let a = consumerConformance(demoStore, Chain)
    for e in a.errors: echo "  demo ERR ", e
    check a.ok
    check a.blocksChecked == 3
    # Eight transactions, six of them replayable. Block 100 carries txA plus the
    # three degraded subjects the capture register needs — txF (reverted, trace
    # ready), txG (recording truncated, trace ready) and txH (traceless, the
    # dense metadata page) — so two of the three add a replayable trace and the
    # third does not.
    check a.transactionsChecked == 8
    check a.tracesReplayable == 6

    let b = consumerConformance(evmStore, ev.chain)
    for e in b.errors: echo "  evm ERR ", e
    check b.ok
    check b.blocksChecked == 1
    check b.transactionsChecked == 1
    check b.tracesReplayable == 1

  test "the consumer never learns which producer wrote the tree":
    # The same calls, in the same order, against two trees written by different
    # code with different chain shapes. Nothing below names a producer.
    for (store, chain) in [(demoStore, Chain), (evmStore, ev.chain)]:
      let o = openChain(store, chain)
      check o.outcome == ooOpened
      let s = o.session
      let refs = blockRefsNewestFirst(store, s)
      check refs.len > 0
      let bd = blockDetail(store, s, refs[0].hash)
      check bd.outcome == roFound
      check bd.detail.transactions.len > 0
      let tr = transaction(store, s, bd.detail.transactions[0])
      check tr.outcome == roFound
      check tr.view.facts.executions.len > 0
      let traces = resolveTraces(store, s, tr.view)
      check traces.len > 0
      check bestTrace(traces) >= 0

  test "the outcome vocabulary differs between the two, and both read back verbatim":
    let a = transaction(demoStore, openDemo(), synthHash("sdk-seed", "tx", 0))
    let o = openChain(evmStore, ev.chain)
    let b = transaction(evmStore, o.session, ev.tx)
    check a.view.facts.outcome.overall == ooSucceeded
    check b.view.facts.outcome.overall == ooReverted
    check b.view.facts.outcome.reason == "InsufficientBalance()"

# ===========================================================================
# test_conformance_does_not_use_the_reader_as_its_own_oracle
# ===========================================================================

proc groundTruthErrors(dir, chain, txHash: string, v: TransactionView): seq[string] =
  ## Compare an SDK-produced view against the bytes on disk, parsed here with
  ## `std/json` and NOTHING from the package under test. A reader that drops a
  ## field, mis-parses a union or invents a default fails against this.
  let facts = parseFile(dir / "d" / chain / "tx" / hexShard(txHash) /
                        txHash & ".json")
  if v.facts.chain != facts["chain"].getStr:
    result.add "chain"
  if $v.facts.outcome.overall != facts["outcome"]["overall"].getStr:
    result.add "outcome.overall"
  if v.facts.outcome.reason != facts["outcome"]{"reason"}.getStr:
    result.add "outcome.reason"
  if v.facts.roles.len != facts["roles"].len:
    result.add "roles.len"
  else:
    for i, r in v.facts.roles:
      if r.role != facts["roles"][i]["role"].getStr or
         r.address != facts["roles"][i]["address"].getStr:
        result.add "roles[" & $i & "]"
  if v.facts.cost.len != facts["cost"].len:
    result.add "cost.len"
  if v.facts.executions.len != facts["executions"].len:
    result.add "executions.len"
  else:
    for i, e in v.facts.executions:
      if e.executionInputId != facts["executions"][i]["executionInputId"].getStr:
        result.add "executions[" & $i & "].executionInputId"
  if v.facts.payloadSelector != facts["payload"]{"selector"}.getStr:
    result.add "payload.selector"
  if v.facts.native != facts{"native"}:
    result.add "native"
  if facts["order"]{"kind"}.getStr == "blockIndex":
    let pos = blockPosition(v)
    if not pos.known: result.add "order.kind"
    elif pos.height != facts["order"]["height"].getInt: result.add "order.height"
    elif pos.index != facts["order"]["index"].getInt: result.add "order.index"
    elif pos.blockHash != facts["order"]["block"].getStr: result.add "order.block"

suite "M12a — the conformance suite does not use the reader as its own oracle":
  let session = openDemo()

  test "every demo transaction matches ground truth read independently":
    var checked = 0
    for b in blockRefsNewestFirst(demoStore, session):
      let bd = blockDetail(demoStore, session, b.hash)
      for txh in bd.detail.transactions:
        let tr = transaction(demoStore, session, txh)
        check tr.outcome == roFound
        let errs = groundTruthErrors(demoDir, Chain, txh, tr.view)
        if errs.len > 0: echo "  MISMATCH ", txh, ": ", errs
        check errs.len == 0
        inc checked
    check checked == 8

  test "MUTATION BITE: a reader that drops a field fails against ground truth":
    let txh = synthHash("sdk-seed", "tx", 1)
    let tr = transaction(demoStore, session, txh)
    check groundTruthErrors(demoDir, Chain, txh, tr.view).len == 0
    # Six independent single-field corruptions of what the reader produced.
    # Each must be caught; a comparison that agreed with its own input would
    # catch none.
    var v = tr.view
    v.facts.roles = @[]
    check "roles.len" in groundTruthErrors(demoDir, Chain, txh, v)
    v = tr.view
    v.facts.outcome.reason = ""
    check "outcome.reason" in groundTruthErrors(demoDir, Chain, txh, v)
    v = tr.view
    v.facts.outcome.overall = ooSucceeded
    check "outcome.overall" in groundTruthErrors(demoDir, Chain, txh, v)
    v = tr.view
    v.facts.executions[0].executionInputId = "sha1:wrong"
    check "executions[0].executionInputId" in groundTruthErrors(demoDir, Chain, txh, v)
    v = tr.view
    v.facts.payloadSelector = "0xdeadbeef"
    check "payload.selector" in groundTruthErrors(demoDir, Chain, txh, v)
    v = tr.view
    v.facts.order = TxOrder(kind: tokBlockIndex, obBlock: "0xnope",
                            obHeight: 1, obIndex: 0)
    check groundTruthErrors(demoDir, Chain, txh, v).len > 0

  test "MUTATION BITE: a derived trace address that drifts is caught":
    # Independent oracle 1: the address the client DERIVES against the address
    # the manifest STATES. Repointing the registry's recorder pin changes the
    # derivation and nothing else, so the two must stop agreeing.
    let d = tmp("driftpin")
    discard generate(DemoConfig(outDir: d, seed: "sdk-seed",
                                traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
    check consumerConformance(localTree(d), Chain).ok
    let rp = d / "registry" / "chains.v1.json"
    var reg = parseFile(rp)
    reg["chains"][Chain]["recorder"]["build"] = %"sha1:tampered"
    writeFile(rp, reg.pretty & "\n")
    let after = consumerConformance(localTree(d), Chain)
    check not after.ok
    check after.errors.anyIt(it.contains("derived traceArtifactId") or
                             it.contains("is not published"))

  test "MUTATION BITE: a container whose bytes disagree with its manifest is caught":
    let d = tmp("driftbytes")
    discard generate(DemoConfig(outDir: d, seed: "sdk-seed",
                                traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
    check consumerConformance(localTree(d), Chain).ok
    var container = ""
    for p in walkDirRec(d / "t"):
      if p.endsWith("trace.ct"): container = p; break
    check container.len > 0
    writeFile(container, readFile(container) & "extra")
    let after = consumerConformance(localTree(d), Chain)
    check not after.ok
    check after.errors.anyIt(it.contains("bytes"))

  test "MUTATION BITE: a block and its transactions disagreeing is caught":
    let d = tmp("driftpos")
    discard generate(DemoConfig(outDir: d, seed: "sdk-seed",
                                traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
    check consumerConformance(localTree(d), Chain).ok
    let bh = synthHash("sdk-seed", "block", 101)
    let bp = d / "d" / Chain / "block" / bh & ".json"
    var b = parseFile(bp)
    b["height"] = %999
    writeFile(bp, b.pretty & "\n")
    let after = consumerConformance(localTree(d), Chain)
    check not after.ok
    check after.errors.anyIt(it.contains("height"))

  test "MUTATION BITE: an overlay claiming `ready` with no published trace is caught":
    let d = tmp("driftready")
    discard generate(DemoConfig(outDir: d, seed: "sdk-seed",
                                traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
    let txh = synthHash("sdk-seed", "tx", 0)
    let op = d / "d" / Chain / "ts" / "1" / hexShard(txh) / txh & ".json"
    var ov = parseFile(op)
    ov["trace"]["availability"] = %"ready"
    writeFile(op, ov.pretty & "\n")
    # Remove the artifact the overlay now claims exists.
    for p in walkDirRec(d / "t"):
      if p.endsWith("manifest.json"): removeFile(p)
    let after = consumerConformance(localTree(d), Chain)
    check not after.ok
    check after.errors.anyIt(it.contains("is not published"))

# ===========================================================================
# Source bundles — Source-Resolution.md §5
# ===========================================================================

suite "M12a — source-bundle resolution per code hash":
  let dir = tmp("sources")
  let ev = buildEvmTree(dir)
  let store = localTree(dir)
  let o = openChain(store, ev.chain)
  let session = o.session
  let tr = transaction(store, session, ev.tx)
  let resolved = resolveTrace(store, session, tr.view, "")

  # The recommended bundle (named by the manifest) and an OLDER one the
  # chain-wide pointer still names. Both are published; they must not be
  # confused, because moving a pointer must change what a page displays without
  # changing what a trace is (§2.5).
  let recommendedHash = shortBundleHash(ev.bundleId)
  let olderHash = repeat("cd", 20)
  writeJsonNl(dir / sourceBundlePath(ev.chain, ev.codeHash, recommendedHash), %*{
    "schema": 1, "codeHash": ev.codeHash, "chain": ev.chain, "match": "full",
    "provider": "sourcify", "language": "solidity",
    "compiler": {"name": "solc", "version": "0.8.24"},
    "sources": {"src/Vault.sol": {"content": "contract Vault {}"}},
    "debug": {"abi": []}})
  writeJsonNl(dir / sourceBundlePath(ev.chain, ev.codeHash, olderHash), %*{
    "schema": 1, "codeHash": ev.codeHash, "chain": ev.chain, "match": "partial",
    "provider": "guess", "language": "solidity",
    "sources": {"src/Vault.sol": {"content": "// partial"}}})
  writeJsonNl(dir / sourceBundlePointerPath(ev.chain, ev.codeHash),
    %*{"sourceBundleId": "sha1:" & olderHash})

  test "the transaction's executed code hashes come from its code edges":
    check codeHashes(tr.view.facts) == @[ev.codeHash]

  test "the manifest's recommendation wins over the chain-wide pointer":
    check resolved.hasManifest
    let r = resolveSourceBundle(store, ev.chain, resolved.manifest,
                                resolved.hasManifest, ev.codeHash)
    check r.origin == bsManifest
    check r.sourceBundleId == ev.bundleId
    let b = fetchSourceBundle(store, r)
    check b.outcome == boLoaded
    check b.bundle.match == mqFull
    check b.bundle.provider == "sourcify"

  test "with no manifest, the pointer is followed":
    var noManifest: TraceManifest
    let r = resolveSourceBundle(store, ev.chain, noManifest, false, ev.codeHash)
    check r.origin == bsPointer
    let b = fetchSourceBundle(store, r)
    check b.outcome == boLoaded
    check b.bundle.match == mqPartial      # the older interpretation

  test "an unverified contract is data with a reason, never an error":
    let unknown = "0xfeed" & repeat("9", 36)
    let r = resolveFromPointer(store, ev.chain, unknown)
    check r.origin == bsNone
    check r.reason.len > 0
    let b = fetchSourceBundle(store, r)
    check b.outcome == boNotPublished
    check b.reason.len > 0

  test "a bundle filed under the wrong code hash is refused, not displayed":
    let wrong = "0xbad0" & repeat("7", 36)
    let h = repeat("ef", 20)
    writeJsonNl(dir / sourceBundlePath(ev.chain, wrong, h), %*{
      "schema": 1, "codeHash": ev.codeHash, "chain": ev.chain, "match": "full",
      "sources": {}})
    writeJsonNl(dir / sourceBundlePointerPath(ev.chain, wrong),
      %*{"sourceBundleId": "sha1:" & h})
    let r = resolveFromPointer(store, ev.chain, wrong)
    check r.origin == bsPointer
    let b = fetchSourceBundle(store, r)
    check b.outcome == boMismatched
    check b.reason.contains(ev.codeHash)

  test "the demo tree's bundles resolve to the real Noir source of the trace":
    # The demo tree now publishes source bundles for the `noir_space_ship`
    # program its traces record, so the consumer path can be exercised against
    # real data rather than against absence. Without this the debugger steps
    # through code it cannot display: the CTFS container carries no source text.
    let session = openDemo()
    let tx = synthHash("sdk-seed", "tx", 0)
    let dtr = transaction(demoStore, session, tx)
    let dt = resolveTrace(demoStore, session, dtr.view, "")
    check dt.hasManifest
    var resolved = 0
    for ch in codeHashes(dtr.view.facts):
      let r = resolveSourceBundle(demoStore, Chain, dt.manifest, true, ch)
      # The manifest's own recommendation wins over the chain-wide pointer (§5).
      check r.origin == bsManifest
      let b = fetchSourceBundle(demoStore, r)
      check b.outcome == boLoaded
      check b.bundle.codeHash == ch
      check b.bundle.language == "noir"
      check b.bundle.compilerName == "nargo"
      # The paths the CONTAINER interns must be present, or a step resolves to a
      # file the viewer does not have.
      for path in ["src/main.nr", "src/shield.nr"]:
        check path in b.bundle.sources
        check b.bundle.sources[path]["content"].getStr.len > 0
      # Real spaceship source, not a placeholder.
      check "iterate_asteroids" in b.bundle.sources["src/shield.nr"]["content"].getStr
      inc resolved
    check resolved > 0

  test "an unpublished code hash still reports absence rather than failing":
    # The honest-absence path must survive the arrival of real bundles.
    let session = openDemo()
    let tx = synthHash("sdk-seed", "tx", 0)
    let dtr = transaction(demoStore, session, tx)
    let dt = resolveTrace(demoStore, session, dtr.view, "")
    let unknown = "0xfeed" & repeat("0", 36)
    let r = resolveSourceBundle(demoStore, Chain, dt.manifest, true, unknown)
    check r.origin == bsNone
    check r.reason.len > 0
    let b = fetchSourceBundle(demoStore, r)
    check b.outcome == boNotPublished
    check b.reason.len > 0
