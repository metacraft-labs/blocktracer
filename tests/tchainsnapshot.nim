## The reader's side of the snapshot seam: what it accepts, what it refuses, and
## what it must not crash on.
##
## ## Why this suite exists and why it is a separate one
##
## Every other test of `ingestSnapshot` in this tree drives a snapshot that was
## written BY THIS TREE — the committed testnet captures, or a `%*` literal in
## `client/tests/test_chain_provenance.nim`. That is the right way to test what
## the reader does with a conforming tree, and it is structurally unable to catch
## the thing that actually broke: a snapshot the REAL producer wrote against a
## DIFFERENT NODE, whose `provenance` therefore has a different set of members.
##
## Measured 2026-09-11. `blocktracer-follow-chain` was run against Aztec MAINNET
## (`https://aztec.drpc.org`, node 5.2.0) and produced a snapshot whose
## `provenance` carries `kind`, `chain`, `label`, `endpoint`, `firstCapturedAt`,
## `capturedAt`, `nodeVersion` and `runtimeCommit` — and **no `l1ChainId`**. The
## reader read four provenance members by unguarded `prov["…"]`, which raises
## `KeyError` in Nim's `std/json` rather than returning null, so:
##
##     blocktracer-chain-ingest --snapshot … --out …
##     { "ok": false, "error": "key not found: l1ChainId",
##       "errorType": "KeyError" }   exit 1
##
## Both committed testnet fixtures carry `l1ChainId: 11155111` and all eight
## sites in `test_chain_provenance.nim` hand-write it, so the whole suite and the
## whole corpus were blind to it. The producer side was blind too, and for a
## reason worth stating: it DOES write the key — `l1ChainId: nodeInfo.l1ChainId`
## — and `JSON.stringify` DROPS a key whose value is `undefined`. In the same
## object literal `rollupAddress` carried `?? ''` and the three beside it did
## not, so it is a node-response asymmetry and not a network one.
##
## ## NO MOCKS, and that is the point rather than a preference
##
## Per the workspace policy every mock must be justified in the header: there are
## none here to justify. The subject is `ingestSnapshot` itself, driven over a
## snapshot no test wrote, onto a real temporary directory, with the real
## `std/json` parser and the real registry. A mock provenance object would have
## been written by whoever was thinking about the reader, which is exactly the
## population of shapes the defect was not in. The fixture is committed
## BYTE-IDENTICAL to what the follower produced — 403 blocks, 9 transactions, 0
## traces, 0 captures, `blocktracer/chain-snapshot@1`, no `refusalReason`
## anywhere — because a reduction is a thing somebody chose and the value of this
## input is that nobody chose it.
##
## It doubles as the `@1` compatibility subject. It is a genuine pre-ING-3
## capture: its nine untraced rows carry no `refusalReason` at all, so it is the
## evidence that `blocktracer/chain-snapshot@1` is still READ rather than merely
## listed, and that the reader's `@2` enforcement does not reach back over it.

import std/[unittest, os, json, strutils]

import ../src/blocktracer/chain/ingest
import ../src/blocktracer/chain/snapshot_format
# `hexShard` — the overlay's object path is derived the way the contract derives it,
# rather than a shard layout written out here. The tree already owns one spelling of it.
import ../src/blocktracer/contract/ids

let
  fixtureRoot = currentSourcePath().parentDir / "fixtures" / "chain-snapshots"
  liveMainnet = fixtureRoot / "aztec-mainnet-live"

doAssert fileExists(liveMainnet / "snapshot.json"),
  "tests/fixtures/chain-snapshots/aztec-mainnet-live/snapshot.json is missing. This suite " &
  "REFUSES rather than skips: its whole subject is a shape no other fixture in this tree " &
  "has, so a skipped run is a green that means nothing."

var asserted = 0
template ck(condition: untyped) =
  inc asserted
  check condition
template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

proc tempOut(tag: string): string =
  result = getTempDir() / ("bt-chainsnap-" & tag & "-" & $getCurrentProcessId())
  removeDir result
  createDir result

proc writeSnapshot(dir: string, doc: JsonNode) =
  createDir dir
  writeFile(dir / "snapshot.json", pretty(doc, 1))

# ───────────────────────────────────────────────────────────────────────────
suite "the live mainnet capture the reader used to raise KeyError on":
  asserted = 0

  test "the fixture really is the shape the defect needed — otherwise this is vacuous":
    let snap = parseJson(readFile(liveMainnet / "snapshot.json"))
    let prov = snap["provenance"]
    # THE THREE PROPERTIES THAT MAKE IT THE SUBJECT. If a later edit supplies
    # `l1ChainId`, the reproduction below stops reproducing anything and this
    # arm says so instead of passing quietly.
    ck "l1ChainId" notin prov
    ck "nodeVersion" in prov          # so the arm is about ONE absent member
    ck snap["format"].getStr == "blocktracer/chain-snapshot@1"
    ck snap["provenance"]["chain"].getStr == "aztec-mainnet"
    ck snap["blocks"].len == 403
    ck snap["transactions"].len == 9
    # A genuine pre-ING-3 capture: not one untraced row carries a member.
    var withReason = 0
    for t in snap["transactions"]:
      if t{"refusalReason"}.getStr.len > 0: inc withReason
    ck withReason == 0

  test "ingestSnapshot no longer raises on it, and publishes the whole capture":
    let outDir = tempOut("mainnet")
    defer: removeDir outDir
    # NOT `expect nothing` — the raise this replaces was a `KeyError` from inside
    # `std/json`, and a bare `try` that swallowed it would make the arm pass on a
    # reader that still crashed differently. The result is asserted instead.
    let ing = ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: liveMainnet,
                                          generation: "1", scope: isFull))
    ck ing.chain == "aztec-mainnet"
    ck ing.blocks == 403
    ck ing.transactions == 9
    ck ing.withTrace == 0
    ck ing.pruned == 9
    ck fileExists(outDir / "d" / "aztec-mainnet" / "g" / "1" / "summary.json")

  test "the absent member is published as null, not invented and not dropped":
    let outDir = tempOut("mainnet-summary")
    defer: removeDir outDir
    discard ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: liveMainnet,
                                        generation: "1", scope: isFull))
    let summary = parseJson(readFile(
      outDir / "d" / "aztec-mainnet" / "g" / "1" / "summary.json"))
    let prov = summary["provenance"]
    # A NULL AND NOT AN ABSENCE. `prov{key}` returns a nil `JsonNode` for a
    # missing key and `std/json`'s `toUgly` dereferences it without a nil check,
    # so the naive fix trades a KeyError for a segfault. An explicit null says
    # "the capture did not record it"; a vanished key says nothing at all.
    ck "l1ChainId" in prov
    ck prov["l1ChainId"].kind == JNull
    # …and the three beside it, which the capture DID record, travel through.
    ck prov["nodeVersion"].getStr == "5.2.0"
    ck prov["endpoint"].getStr == "https://aztec.drpc.org"
    ck prov["capturedAt"].getStr.len > 0

  expectCount(18)

# ───────────────────────────────────────────────────────────────────────────
suite "the format token is a gate, and it says which shape it is gating":
  asserted = 0

  test "the policy both languages read":
    ck currentSnapshotFormat() == "blocktracer/chain-snapshot@2"
    ck isReadableSnapshotFormat("blocktracer/chain-snapshot@1")
    ck isReadableSnapshotFormat("blocktracer/chain-snapshot@2")
    ck not isReadableSnapshotFormat("blocktracer/chain-snapshot@3")
    ck not isReadableSnapshotFormat("")
    # THE WHOLE CONTENT OF THE BUMP. ING-3 made `refusalReason` mandatory on
    # every untraced row — `auditRefusals` refuses a snapshot without it, in the
    # write path of every producer — while the token stayed `@1` and this reader
    # went on treating the member as optional. So the two halves of the seam
    # disagreed about whether the field was required and the artifact's own
    # version token said nothing either way.
    ck snapshotRequiresRefusalReason("blocktracer/chain-snapshot@2")
    ck not snapshotRequiresRefusalReason("blocktracer/chain-snapshot@1")
    # The three populations, which the mandatory-member gate ranges over.
    ck isUntracedSnapshotOutcome("pruned")
    ck isUntracedSnapshotOutcome("not-attempted")
    ck isChainAbsentSnapshotOutcome("private-only")
    ck not isUntracedSnapshotOutcome("private-only")
    ck isTracedSnapshotOutcome("replayed")
    ck not isUntracedSnapshotOutcome("replayed")

  test "an unknown token is refused BY NAME and nothing is read":
    # §3: "the site-generator and the conformance validator refuse a version they
    # do not support rather than misreading it." §5.2: refused by name "rather
    # than attempting a partial read".
    let dir = tempOut("bad-format")
    defer: removeDir dir
    writeSnapshot(dir, %*{
      "format": "blocktracer/chain-snapshot@99",
      "provenance": {"kind": "live-capture", "chain": "aztec-testnet"},
      "window": {"tip": 10, "finalized": 5, "blocks": 5},
      "counts": {}, "blocks": [], "transactions": [],
    })
    let outDir = tempOut("bad-format-out")
    defer: removeDir outDir
    var said = ""
    try:
      discard ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: dir,
                                          generation: "1", scope: isFull))
    except ValueError as e:
      said = e.msg
    ck said.len > 0
    ck "blocktracer/chain-snapshot@99" in said        # named
    ck "blocktracer/chain-snapshot@2" in said         # and what IS accepted
    ck "migrate-refusal-reasons" in said              # and the way forward
    # NOTHING WAS WRITTEN. "Refused rather than partially read" is a claim about
    # the tree, so it is checked against the tree.
    ck not dirExists(outDir / "d")

  test "`@2` REQUIRES the member on an untraced row, and `@1` does not":
    # The same rows under the two tokens. This is the difference the bump names,
    # and asserting it in both directions is what stops the token being a label:
    # a reader that accepted both identically would leave `@1` meaning two things
    # exactly as before.
    proc snapWith(format: string): JsonNode =
      %*{
        "format": format,
        "provenance": {"kind": "live-capture", "chain": "aztec-testnet",
                       "label": "t", "endpoint": "http://x", "capturedAt": "2026-09-12",
                       "nodeVersion": "5.2.0", "runtimeCommit": "deadbeefdeadbeef"},
        "window": {"tip": 12, "finalized": 10, "replayableFrom": 11,
                   "replayableTo": 12, "blocks": 2},
        "counts": {},
        "blocks": [
          {"number": 11, "hash": "0xb11", "time": 1788000000, "transactions": ["0xaa"],
           "archiveRoot": "0xa11", "parentArchiveRoot": "0xa10"},
        ],
        "transactions": [
          # UNTRACED AND CARRYING NO `refusalReason`. Exactly the shape every
          # pre-ING-3 capture has, and exactly what `@2` forbids.
          {"txHash": "0xaa", "blockNumber": 11, "txIndexInBlock": 0, "revertCode": 0,
           "transactionFee": "0x1", "bodyRetained": false, "effectVisible": true,
           "firstInBlock": true, "outcome": "pruned",
           "reason": "The node no longer serves this transaction's body."},
        ],
      }

    # `@1`: read, and read WHOLE. The member is optional there, which is the
    # behaviour that let the pre-ING-3 corpus be published at all.
    block:
      let dir = tempOut("v1-ok")
      defer: removeDir dir
      let outDir = tempOut("v1-ok-out")
      defer: removeDir outDir
      writeSnapshot(dir, snapWith("blocktracer/chain-snapshot@1"))
      let ing = ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: dir,
                                            generation: "1", scope: isFull))
      ck ing.transactions == 1
      ck ing.pruned == 1
      # READ WHOLE, not skipped: the row reached the published tree with its own
      # sentence. §5.2 forbids a partial read, and "we accepted the token and
      # dropped the rows" would be one.
      let overlay = parseJson(readFile(outDir / "d" / "aztec-testnet" / "ts" / "1" /
                                       hexShard("0xaa") / "0xaa.json"))
      ck overlay["trace"]["availability"].getStr == "absent"
      ck "no longer serves" in overlay["trace"]["reason"].getStr
      ck overlay["trace"]{"refusalReason"}.getStr.len == 0

    # `@2`: the same rows are REFUSED, naming the row and the requirement.
    block:
      let dir = tempOut("v2-bad")
      defer: removeDir dir
      let outDir = tempOut("v2-bad-out")
      defer: removeDir outDir
      writeSnapshot(dir, snapWith("blocktracer/chain-snapshot@2"))
      var said = ""
      try:
        discard ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: dir,
                                            generation: "1", scope: isFull))
      except ValueError as e:
        said = e.msg
      ck said.len > 0
      ck "carries no refusalReason" in said
      ck "blocktracer/chain-snapshot@2" in said
      ck "migrate-refusal-reasons" in said

    # AND `@2` ACCEPTS THE SAME ROWS WITH THE MEMBER, which is the control. A
    # gate that refused everything would satisfy the arm above and be useless.
    block:
      let dir = tempOut("v2-ok")
      defer: removeDir dir
      let outDir = tempOut("v2-ok-out")
      defer: removeDir outDir
      let doc = snapWith("blocktracer/chain-snapshot@2")
      doc["transactions"][0]["refusalReason"] = %"body-unavailable"
      writeSnapshot(dir, doc)
      let ing = ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: dir,
                                            generation: "1", scope: isFull))
      ck ing.transactions == 1
      ck ing.pruned == 1
      let summary = parseJson(readFile(
        outDir / "d" / "aztec-testnet" / "g" / "1" / "summary.json"))
      ck summary["refusals"]["byReason"]["body-unavailable"].getInt == 1

    # …and a CHAIN-ABSENT row must carry no member on `@2` either, which is the
    # other half of the asymmetry: the closed set is a set of things WE did.
    block:
      let dir = tempOut("v2-private")
      defer: removeDir dir
      let outDir = tempOut("v2-private-out")
      defer: removeDir outDir
      let doc = snapWith("blocktracer/chain-snapshot@2")
      doc["transactions"][0]["outcome"] = %"private-only"
      doc["transactions"][0]["reason"] =
        %"This transaction has no public execution to trace."
      writeSnapshot(dir, doc)
      let ing = ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: dir,
                                            generation: "1", scope: isFull))
      ck ing.transactions == 1
      let overlay = parseJson(readFile(outDir / "d" / "aztec-testnet" / "ts" / "1" /
                                       hexShard("0xaa") / "0xaa.json"))
      ck overlay["trace"]["availability"].getStr == "absent"
      ck overlay["trace"]{"refusalReason"}.getStr.len == 0

  expectCount(33)

# ───────────────────────────────────────────────────────────────────────────
suite "the committed captures declare the token whose members they carry":
  asserted = 0

  test "every capture under client/fixtures/chain/ is @2 and meets @2":
    let chainFixtures = currentSourcePath().parentDir.parentDir /
                        "client" / "fixtures" / "chain"
    var checked = 0
    for kind, path in walkDir(chainFixtures):
      if kind != pcDir: continue
      let p = path / "snapshot.json"
      if not fileExists(p): continue
      inc checked
      let snap = parseJson(readFile(p))
      let fmt = snap["format"].getStr
      ck isReadableSnapshotFormat(fmt)
      ck fmt == currentSnapshotFormat()
      # AND IT MEETS WHAT IT CLAIMS. A tree that claimed `@2` while carrying a
      # row `@2` forbids would be the same ambiguity `@1` had, one version on.
      var missing = 0
      var absentWithId = 0
      for t in snap["transactions"]:
        let outcome = t{"outcome"}.getStr
        if isUntracedSnapshotOutcome(outcome) and t{"refusalReason"}.getStr.len == 0:
          inc missing
        if isChainAbsentSnapshotOutcome(outcome) and "refusalReason" in t:
          inc absentWithId
      ck missing == 0
      ck absentWithId == 0
      # `counts.accountedFor` is the figure that has to equal `transactions`:
      # the four outcome lines are not a partition and never were.
      ck snap["counts"]["accountedFor"].getInt == snap["transactions"].len
    ck checked == 3

  expectCount(16)
