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

import std/[unittest, os, json, strutils, sequtils, algorithm, sha1]

import ../src/blocktracer/chain/ingest
import ../src/blocktracer/chain/snapshot_format
import ../src/blocktracer/chain/contract_rules
import ../src/blocktracer/validator
# `shardKeyFor` — the overlay's object path is derived the way the contract derives it,
# WITH THE ENCODING NAMED (`"hex"`), which is what these trees declare, rather than a
# shard layout written out here. A test that spelled the shard itself would pass while
# the producer keyed somewhere else.
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
  ## Write a constructed snapshot, with §5.2's tally DERIVED from the rows beside
  ## it rather than written out at each site.
  ##
  ## `counts` is required and the reader now checks it against those rows
  ## (`S5-COUNTS-ROWS`, `S5-COUNTS-RECONCILE`) — a tally that is not recomputed is
  ## a tally that survives the rows it described, which is the detector reading
  ## clean on the one condition it detects. Deriving it here is the same rule
  ## `tools/chain/lib/recount.mjs` applies on the producer side; a fixture that
  ## needs a WRONG tally states one explicitly after calling this.
  createDir dir
  var d = doc
  if d{"counts"} == nil or d["counts"].len == 0:
    var counts = %*{"blocks": d{"blocks"}.len, "transactions": d{"transactions"}.len}
    if d{"format"}.getStr == "blocktracer/chain-snapshot@2":
      counts["accountedFor"] = %d{"transactions"}.len
    d["counts"] = counts
  writeFile(dir / "snapshot.json", pretty(d, 1))

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
                                       shardKeyFor("hex", "0xaa") / "0xaa.json"))
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
                                       shardKeyFor("hex", "0xaa") / "0xaa.json"))
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

# ═══════════════════════════════════════════════════════════════════════════════
#  A REFUSAL NAMES THE RULE IN §5 IT ENFORCES — one snapshot per rule, and the
#  same snapshot repaired.
# ═══════════════════════════════════════════════════════════════════════════════
#
# WHY EVERY RULE GETS ITS OWN SUBJECT. The reader used to refuse a non-conforming
# snapshot wherever it happened to notice: a sentence about the symptom, with
# nothing in it a producer could look up. `Data-Contract.md` §5's rules now carry
# identifiers (`tools/chain/snapshot-contract.json`), the reader cites them, and
# what makes that a property of the TREE rather than of a comment is one subject
# per rule, each violating exactly that rule and no other.
#
# AND THE REPAIRED CONTROL, WHICH IS THE HALF THAT MAKES IT AN ATTRIBUTION. A
# fixture can be refused for being malformed in general — a missing directory, a
# temp path, a truncated file — and the refusal would still name whichever rule
# the reader reached first. So each case is staged TWICE from the same pristine
# capture: once with its single violation, which must be refused CITING ITS OWN
# RULE, and once without it, which must ingest. The difference between the two is
# one edit, so the citation is attributable to that edit.
#
# THE SUBJECT IS A REAL COMMITTED CAPTURE, not a constructed one. `aztec-testnet-
# frames` is 26 blocks, 8 transactions, six containers, and it carries all four
# row-named sidecar kinds — instruction listings, position streams, call traces
# and a source bundle — so the §5.4 rules have real bytes to be violated in
# rather than a literal written by whoever was thinking about the rule.
#
# NO MOCKS. Everything below drives the real `ingestSnapshot` over a real capture
# on a real temporary directory; the only synthesis is the single edit each case
# makes, which is the subject.

let framesCapture = currentSourcePath().parentDir.parentDir /
                    "client" / "fixtures" / "chain" / "aztec-testnet-frames"

doAssert fileExists(framesCapture / "snapshot.json"),
  "client/fixtures/chain/aztec-testnet-frames is missing; every rule case below " &
  "would have no subject, so this refuses rather than skips"

proc copyCapture(dest: string) =
  removeDir dest
  createDir dest
  for kind, path in walkDir(framesCapture):
    let name = path.extractFilename
    if kind == pcDir: copyDir(path, dest / name)
    elif kind == pcFile: copyFile(path, dest / name)

proc firstOutcome(doc: JsonNode, want: string): JsonNode =
  for t in doc["transactions"]:
    if t["outcome"].getStr == want: return t
  nil

const PositionedTx =
  "0x0a807e4e9909fc66ceeb52e4192406077a06ce378ab9e00717555fbd41b50592"
  ## The one row in this capture with a position stream and a source bundle, so
  ## the §5.4 source and position rules have a subject that reaches them.

proc violate(id, dir: string) =
  ## Apply EXACTLY ONE violation of rule `id` to a pristine copy of the capture.
  let sp = dir / "snapshot.json"
  var doc = parseJson(readFile(sp))
  var wrote = true
  case id
  of "S5-SNAPSHOT-PRESENT":
    removeFile sp
    wrote = false
  of "S5-FORMAT-UNKNOWN":
    doc["format"] = %"blocktracer/chain-snapshot@3"
  of "S5-CHAIN-NAMED":
    doc["provenance"].delete("chain")
  of "S5-CHAIN-UNIQUE":
    wrote = false                      # staged in the output tree, not the input
  of "S5-MEMBERS-REQUIRED":
    doc.delete("window")
  of "S5-ROW-MEMBERS-REQUIRED":
    # A required member INSIDE a row, which used to fail as `std/json`'s own
    # `key not found: hash` from a stack naming neither the reader nor the rule.
    doc["blocks"][0].delete("hash")
  of "S5-COUNTS-PRESENT":
    doc["counts"] = newJArray()
  of "S5-COUNTS-ROWS":
    doc["counts"]["transactions"] = %(doc["transactions"].len + 1)
  of "S5-COUNTS-RECONCILE":
    doc["counts"]["accountedFor"] = %(doc["transactions"].len + 1)
  of "S5-RECORDER-LABEL-UNIQUE":
    doc["provenance"]["runtimeCommit"] = %"0123456789aaaaaa"
    firstOutcome(doc, "replayed")["recordedBy"] = %"0123456789bbbbbb"
  of "S5-CONTAINER-NONEMPTY":
    writeFile(dir / firstOutcome(doc, "replayed")["container"].getStr, "")
    wrote = false
  of "S5-REASON-REQUIRED":
    firstOutcome(doc, "private-only").delete("reason")
  of "S5-REFUSALREASON-REQUIRED":
    # An UNTRACED row with no member, which is the whole content of the `@1`→`@2`
    # bump. This capture has none of its own, so one chain-absent row is moved
    # into the untraced population and nothing else is touched.
    firstOutcome(doc, "private-only")["outcome"] = %"pruned"
  of "S5-REFUSALREASON-CLOSED":
    let row = firstOutcome(doc, "private-only")
    row["outcome"] = %"pruned"
    row["refusalReason"] = %"the-body-was-eaten-by-a-dog"
  of "S5-REFUSALREASON-FORBIDDEN":
    firstOutcome(doc, "private-only")["refusalReason"] = %"body-unavailable"
  of "S5-BUNDLE-REQUIRED":
    # THE BUNDLE FILE IS EMPTIED RATHER THAN DELETED, and the difference is the
    # rule's own reachability. Deleting it does NOT reach this refusal: the arm is
    # entered by a CLAIM (the capture measured source level, or a tool computed
    # coordinates) or by a MEASUREMENT (the recording positioned steps AND a bundle
    # is there), and this capture's positioned row measures `sourceLevel: false` —
    # so with the file gone the reader correctly publishes an instruction-level page
    # and refuses nothing. Measured: removing the file produces no refusal at all.
    # A bundle that is PRESENT and carries nothing is the violation §5.4 names.
    let p = dir / "sources" / (PositionedTx & ".json")
    var b = parseJson(readFile(p))
    b["bundles"] = newJArray()
    writeFile(p, $b)
    wrote = false
  of "S5-BUNDLE-KEYED":
    let p = dir / "sources" / (PositionedTx & ".json")
    var b = parseJson(readFile(p))
    b["bundles"][0].delete("codeHash")
    writeFile(p, $b)
    wrote = false
  of "S5-BUNDLE-NONEMPTY":
    let p = dir / "sources" / (PositionedTx & ".json")
    var b = parseJson(readFile(p))
    b["bundles"][0]["files"] = newJObject()
    writeFile(p, $b)
    wrote = false
  of "S5-INSTRUCTIONS-AGREE":
    let p = dir / "instructions" / (PositionedTx & ".json")
    var n = parseJson(readFile(p))
    n["steps"] = %(n["steps"].getInt - 1)
    writeFile(p, $n)
    wrote = false
  of "S5-POSITIONS-AGREE":
    let p = dir / "positions" / (PositionedTx & ".json")
    var n = parseJson(readFile(p))
    n["steps"] = %(n["steps"].getInt - 1)
    writeFile(p, $n)
    wrote = false
  of "S5-POSITIONS-COLUMNS":
    let p = dir / "positions" / (PositionedTx & ".json")
    var n = parseJson(readFile(p))
    var shorter = newJArray()
    for i in 1 ..< n["line"].len: shorter.add n["line"][i]
    n["line"] = shorter
    writeFile(p, $n)
    wrote = false
  of "S5-CALLTRACE-AGREE":
    let p = dir / "calltrace" / (PositionedTx & ".json")
    var n = parseJson(readFile(p))
    n["frames"] = %(n["frames"].getInt + 1)
    writeFile(p, $n)
    wrote = false
  of "S5-CALLTRACE-FRAMES":
    # `frames` still equals `callsOpened + 1`, so the rule above is satisfied and
    # this one is the only one broken: the stream declares frames it does not carry.
    let p = dir / "calltrace" / (PositionedTx & ".json")
    var n = parseJson(readFile(p))
    var shorter = newJArray()
    for i in 1 ..< n["frame"].len: shorter.add n["frame"][i]
    n["frame"] = shorter
    writeFile(p, $n)
    wrote = false
  of "S5-CALLTRACE-FOLD-NONEMPTY":
    let p = dir / "calltrace" / (PositionedTx & ".json")
    var n = parseJson(readFile(p))
    n["frame"][0]["foldedBy"] = %"a rule that closed an empty subtree"
    writeFile(p, $n)
    wrote = false
  of "S5-CALLTRACE-FOLD-TALLY":
    let p = dir / "calltrace" / (PositionedTx & ".json")
    var n = parseJson(readFile(p))
    n["foldedFrames"] = %0
    writeFile(p, $n)
    wrote = false
  of "S5-CALLTRACE-FOLD-BOUND":
    # The tally stays TRUE of the rows — only the bound is broken, so the rule
    # above cannot be the one that fires.
    let p = dir / "calltrace" / (PositionedTx & ".json")
    var n = parseJson(readFile(p))
    var steps = 0
    for f in n["frame"]:
      if f{"foldedBy"}.getStr("").len == 0: continue
      f["hiddenSteps"] = %5000
      steps += 5000
    n["foldedSteps"] = %steps
    writeFile(p, $n)
    wrote = false
  of "S5-SIDECAR-FORMAT-UNKNOWN":
    writeFile(dir / "artifact-resolution.json", $(%*{
      "format": "blocktracer/artifact-resolution@9",
      "chain": "aztec-testnet-frames", "transactions": []}))
    wrote = false
  of "S5-SIDECAR-CHAIN":
    writeFile(dir / "artifact-resolution.json", $(%*{
      "format": "blocktracer/artifact-resolution@1",
      "chain": "some-other-chain", "transactions": []}))
    wrote = false
  else:
    doAssert false, "no violation is written for rule " & id
  if wrote: writeFile(sp, pretty(doc, 1))

proc prepareTree(id, outDir: string) =
  ## The one rule whose violation lives in the OUTPUT tree rather than the input:
  ## a slug this tree already publishes under another producer's kind.
  if id != "S5-CHAIN-UNIQUE": return
  let gen = outDir / "d" / "aztec-testnet-frames" / "g" / "1"
  createDir gen
  writeFile(outDir / "d" / "aztec-testnet-frames" / "current.json",
            $(%*{"chain": "aztec-testnet-frames", "generation": "1"}))
  writeFile(gen / "summary.json", $(%*{"provenance": {"kind": "demo"}}))

const RuleCases = [
  "S5-SNAPSHOT-PRESENT", "S5-FORMAT-UNKNOWN", "S5-CHAIN-NAMED", "S5-CHAIN-UNIQUE",
  "S5-MEMBERS-REQUIRED", "S5-ROW-MEMBERS-REQUIRED", "S5-COUNTS-PRESENT", "S5-COUNTS-ROWS", "S5-COUNTS-RECONCILE",
  "S5-RECORDER-LABEL-UNIQUE", "S5-CONTAINER-NONEMPTY", "S5-REASON-REQUIRED",
  "S5-REFUSALREASON-REQUIRED", "S5-REFUSALREASON-CLOSED", "S5-REFUSALREASON-FORBIDDEN",
  "S5-BUNDLE-REQUIRED", "S5-BUNDLE-KEYED", "S5-BUNDLE-NONEMPTY",
  "S5-INSTRUCTIONS-AGREE", "S5-POSITIONS-AGREE", "S5-POSITIONS-COLUMNS",
  "S5-CALLTRACE-AGREE", "S5-CALLTRACE-FRAMES", "S5-CALLTRACE-FOLD-NONEMPTY",
  "S5-CALLTRACE-FOLD-TALLY", "S5-CALLTRACE-FOLD-BOUND",
  "S5-SIDECAR-FORMAT-UNKNOWN", "S5-SIDECAR-CHAIN",
]

suite "a refusal names the §5 rule it enforces, and the repaired snapshot ingests":
  asserted = 0

  test "the case list is the rule table — no rule is stated without a subject":
    # THE POPULATION, ASSERTED AS AN EQUALITY. A list of cases maintained beside a
    # table of rules is two documents; a rule added to the table and not here would
    # be a rule with no subject, and every claim about it below would be vacuous.
    let stated = contractRuleIds()
    var missing, extra: seq[string]
    for id in stated:
      if id notin RuleCases: missing.add id
    for id in RuleCases:
      if id notin stated: extra.add id
    if missing.len > 0: checkpoint("rules with no case: " & missing.join(", "))
    if extra.len > 0: checkpoint("cases naming no rule: " & extra.join(", "))
    ck missing.len == 0
    ck extra.len == 0
    ck stated.len == RuleCases.len
    ck stated.len >= 28

  test "each violation is refused CITING ITS OWN RULE, and the repair ingests":
    for id in RuleCases:
      let want = cite(id)
      # ── the violation ─────────────────────────────────────────────────────
      let badIn = tempOut("rule-in-" & id.toLowerAscii)
      let badOut = tempOut("rule-out-" & id.toLowerAscii)
      copyCapture(badIn)
      violate(id, badIn)
      prepareTree(id, badOut)
      var said = ""
      try:
        discard ingestSnapshot(IngestConfig(outDir: badOut, snapshotDir: badIn,
                                            generation: "1", scope: isFull))
      except CatchableError as e:
        said = e.msg
      if want notin said:
        checkpoint(id & ": expected a refusal citing " & want & ", got: " &
                   (if said.len == 0: "(no refusal at all)" else: said))
      ck want in said
      removeDir badIn
      removeDir badOut

      # ── the same snapshot, repaired ───────────────────────────────────────
      # One edit is the whole difference between this and the case above, so the
      # citation is attributable to the rule rather than to the fixture.
      let okIn = tempOut("rule-ok-in-" & id.toLowerAscii)
      let okOut = tempOut("rule-ok-out-" & id.toLowerAscii)
      copyCapture(okIn)
      var published = false
      var why = ""
      try:
        discard ingestSnapshot(IngestConfig(outDir: okOut, snapshotDir: okIn,
                                            generation: "1", scope: isFull))
        published = true
      except CatchableError as e:
        why = e.msg
      if not published: checkpoint(id & ": the repaired snapshot did not ingest: " & why)
      ck published
      removeDir okIn
      removeDir okOut

  test "a citation is a lookup, not decoration — the id resolves to §5's own sentence":
    for id in RuleCases:
      ck ruleStatement(id).len > 0
    # …and the prefix carries the section a reader opens, not only the id.
    ck cite("S5-FORMAT-UNKNOWN").startsWith("[§5.2 S5-FORMAT-UNKNOWN]")
    ck cite("S5-BUNDLE-REQUIRED").startsWith("[§5.4 S5-BUNDLE-REQUIRED]")
    ck cite("S5-REFUSALREASON-REQUIRED").startsWith("[§5.2a S5-REFUSALREASON-REQUIRED]")

  expectCount(91)

# ═══════════════════════════════════════════════════════════════════════════════
#  THE VERSION REFUSAL IS THE SAME STATEMENT IN BOTH HALVES OF THE CONTRACT
# ═══════════════════════════════════════════════════════════════════════════════
#
# §3.1 rule 1 governs BOTH halves of this seam and was implemented in only one of
# them. The producer half — `snapshot.json`'s `format` token — has always refused
# an unknown token by name and written nothing. The published half did not: the
# validator recorded "unsupported contract version N" as ONE FINDING and then
# went on walking the generation, checking every object in it against a schema
# they were not written to. That is the best-effort parse rule 1 forbids, wearing
# a report.
#
# So both halves are driven here, over the same capture, with the same two
# claims: the refusal NAMES what it found and what the build accepts, and NOTHING
# BEYOND IT IS READ OR WRITTEN. Each has the control rule 1 needs — the same
# subject at a supported version doing its whole job — because a reader that
# refused everything would satisfy the first half of every arm.
#
# NO MOCKS: the real `ingestSnapshot` and the real `validateTree`, over a real
# committed capture and the tree it produces.

suite "an unknown version is refused by name in both halves, and nothing is read":
  asserted = 0

  test "the producer half: a `@3` token is refused by name and writes NO object":
    let dir = tempOut("v3-in")
    defer: removeDir dir
    copyCapture(dir)
    var doc = parseJson(readFile(dir / "snapshot.json"))
    doc["format"] = %"blocktracer/chain-snapshot@3"
    writeFile(dir / "snapshot.json", pretty(doc, 1))

    let outDir = tempOut("v3-out")
    defer: removeDir outDir
    var said = ""
    try:
      discard ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: dir,
                                          generation: "1", scope: isFull))
    except ValueError as e:
      said = e.msg
    ck said.len > 0
    ck "blocktracer/chain-snapshot@3" in said            # what it found
    ck "blocktracer/chain-snapshot@1" in said            # …and what it accepts
    ck "blocktracer/chain-snapshot@2" in said
    ck cite("S5-FORMAT-UNKNOWN") in said                 # …and the rule
    # NOT ONE OBJECT. "Refused rather than partially read" is a claim about the
    # tree, so it is counted against the tree rather than inferred from the raise.
    var written = 0
    for _ in walkDirRec(outDir): inc written
    ck written == 0

  test "…and the CONTROL: the same capture at a supported token writes its whole generation":
    # Without this the arm above is satisfied by a reader that refuses everything.
    let dir = tempOut("v2-in")
    defer: removeDir dir
    copyCapture(dir)
    let outDir = tempOut("v2-out")
    defer: removeDir outDir
    let ing = ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: dir,
                                          generation: "1", scope: isFull))
    ck ing.chain == "aztec-testnet-frames"
    ck ing.blocks == 26
    ck ing.transactions == 8
    ck ing.withTrace == 6
    # MEASURED, not guessed: this capture publishes 83 objects, and the figure is
    # stated as an equality so a producer change that silently published fewer
    # would fail here rather than passing a floor.
    var written = 0
    for _ in walkDirRec(outDir): inc written
    ck written == 83
    # The whole generation, not a fragment of one.
    let g = outDir / "d" / "aztec-testnet-frames" / "g" / "1"
    ck fileExists(g / "root.json")
    ck fileExists(g / "summary.json")
    ck fileExists(g / "height" / "0.json")
    ck fileExists(g / "blocks" / "0.json")
    ck fileExists(outDir / "d" / "aztec-testnet-frames" / "current.json")
    ck fileExists(outDir / "registry" / "chains.v1.json")

  test "the published half: an unsupported contractVersion is refused and the generation is NOT walked":
    let dir = tempOut("pub-in")
    defer: removeDir dir
    copyCapture(dir)
    let outDir = tempOut("pub-out")
    defer: removeDir outDir
    discard ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: dir,
                                        generation: "1", scope: isFull))
    let rp = outDir / "d" / "aztec-testnet-frames" / "g" / "1" / "root.json"
    let genPrefix = "d/aztec-testnet-frames/g/1/"

    # ── A SECOND DEFECT, PLANTED INSIDE THE GENERATION, AS THE POSITIVE CONTROL ──
    #
    # "No other finding names a path under this generation" is satisfied by a
    # validator that walks nothing at all, and also by one pointed at the wrong
    # directory. So the tree is given a defect the walk can only find by GOING IN —
    # the generation's summary object removed, which `checkGeneration` loads from
    # `root.json`'s own `maps` — and that finding is required to appear while the
    # version is supported. The same tree with the version moved must then report the
    # version and NOT that finding: the walk stopped before it could look.
    removeFile(outDir / "d" / "aztec-testnet-frames" / "g" / "1" / "summary.json")
    let before = validateTree(outDir)
    var beforeInGen: seq[string]
    for e in before:
      if genPrefix in e: beforeInGen.add e
    if beforeInGen.len == 0:
      checkpoint("the planted defect produced no finding under " & genPrefix &
                 "; every claim below would be vacuous. errors: " & before.join(" | "))
    ck beforeInGen.len > 0
    ck anyIt(beforeInGen, "summary.json" in it)

    var root = parseJson(readFile(rp))
    root["contractVersion"] = %99
    writeFile(rp, root.pretty & "\n")
    let after = validateTree(outDir)

    var refusal = ""
    var otherInGen: seq[string]
    for e in after:
      if "unsupported contract version" in e: refusal = e
      elif genPrefix in e: otherInGen.add e
    ck refusal.len > 0
    ck "99" in refusal                                   # what it found
    ck "validator supports 1" in refusal                 # …and what it accepts
    ck "§3.1 rule 1" in refusal                          # …and the rule
    # NOTHING ELSE IN THAT GENERATION WAS READ — including the defect the walk DID
    # find one line up. This is the published half's equivalent of "no object
    # written", and it is the half the validator did not have: it used to record the
    # version error and keep walking.
    if otherInGen.len > 0: checkpoint("still walked: " & otherInGen.join(" | "))
    ck otherInGen.len == 0

  expectCount(24)

# ═══════════════════════════════════════════════════════════════════════════════
#  PRODUCER-INTERNAL STATE IS OUTSIDE THE CONTRACT
# ═══════════════════════════════════════════════════════════════════════════════
#
# §5.4: "A producer's own bookkeeping — cursors, coverage ledgers, range
# directories, leases — is outside this contract. It is how a producer arranges to
# produce a snapshot, not part of one, and the reader must never learn to read it."
#
# THE CLAIM IS ABOUT BEHAVIOUR, SO IT IS MEASURED AS BEHAVIOUR. The static half is
# in `tools/chain/snapshot-contract-selftest.mjs` §5, which sweeps every
# snapshot-relative path the reader resolves and requires none of them to be one of
# these names. That is necessary and not sufficient: it cannot see a read built
# from an expression the walk does not resolve. So the same claim is made here
# against the tree: a full ingest with the bookkeeping PRESENT and a full ingest
# with it ABSENT must produce byte-identical output.
#
# AND THE CONTROL IS THE HALF THAT MAKES IT SAY ANYTHING. "The output does not
# change when files are removed" is also true of a reader that reads nothing at
# all, and of a comparison that is looking at the wrong directory. So the same run
# with the SNAPSHOT'S OWN sidecars removed must DIFFER — which is what
# distinguishes "reads nothing outside the snapshot" from "reads nothing".
#
# WHAT IS PLANTED IS WHAT `ingest-range.mjs` ACTUALLY WRITES: a
# `blocktracer/coverage-ledger@1` at `coverage.json` and a per-range directory
# under `ranges/`, plus a cursor and a lease. The names come from
# `tools/chain/snapshot-contract.json`'s `producerInternal` block, so the two
# halves of this check range over one list rather than two.
#
# NO MOCKS. The subject is the real `ingestSnapshot` over a real committed
# capture; the planted bookkeeping is real producer output in shape and is the
# thing the reader must ignore.

proc treeDigest(dir: string): seq[string] =
  ## `<relative path>\t<length>\t<content hash>` per object, sorted. A path that
  ## MOVED and an object whose BYTES moved both show up, which a count cannot say.
  for path in walkDirRec(dir):
    let bytes = readFile(path)
    result.add path.relativePath(dir) & "\t" & $bytes.len & "\t" & $secureHash(bytes)
  result.sort()

proc plantProducerState(dir: string) =
  ## The bookkeeping `tools/chain/ingest-range.mjs` leaves beside a capture.
  writeFile(dir / "coverage.json", $(%*{
    "format": "blocktracer/coverage-ledger@1",
    "chain": "aztec-testnet-frames",
    "liveGeneration": "1",
    "lastPublishedCodeVersion": {"commit": "0123456789abcdef"},
    "ranges": {
      "000000100-000000199": {
        "from": 100, "to": 199, "blocks": 100,
        "codeVersion": {"commit": "0123456789abcdef"},
        "ingestedAt": "2026-09-01T00:00:00.000Z",
        "publishedAt": "2026-09-01T00:05:00.000Z",
        "visibleInGeneration": "1"}}}))
  createDir(dir / "ranges" / "000000100-000000199")
  # A range's own snapshot — the refreshable unit, and a whole second snapshot
  # sitting inside the directory the reader is pointed at. If any reader path
  # walked directories rather than reading rows, this is what it would find.
  writeFile(dir / "ranges" / "000000100-000000199" / "snapshot.json", $(%*{
    "format": "blocktracer/chain-snapshot@2",
    "provenance": {"kind": "live-capture", "chain": "aztec-testnet-frames"},
    "window": {"tip": 199, "finalized": 190, "blocks": 9},
    "counts": {"blocks": 0, "transactions": 0, "accountedFor": 0},
    "blocks": [], "transactions": []}))
  createDir(dir / "ranges" / "000000100-000000199" / "ct")
  writeFile(dir / "ranges" / "000000100-000000199" / "ct" / "0xdead.ct", "not a container")
  writeFile(dir / "cursor.json", $(%*{"height": 199, "at": "2026-09-01T00:00:00.000Z"}))
  writeFile(dir / "lease", "held-by 12345 until 2026-09-01T00:30:00.000Z\n")

suite "no reader path touches the producer's own bookkeeping":
  asserted = 0

  test "a full ingest is byte-identical with the coverage ledger and ranges present":
    let withState = tempOut("pi-with")
    defer: removeDir withState
    let without = tempOut("pi-without")
    defer: removeDir without
    copyCapture(withState)
    copyCapture(without)
    plantProducerState(withState)

    # ANTI-VACUITY: the planting must have planted something, and the two inputs
    # must actually differ. A comparison between two identical inputs is a
    # comparison about nothing.
    ck fileExists(withState / "coverage.json")
    ck dirExists(withState / "ranges" / "000000100-000000199")
    ck fileExists(withState / "cursor.json")
    ck fileExists(withState / "lease")
    ck treeDigest(withState) != treeDigest(without)
    ck treeDigest(withState).len == treeDigest(without).len + 5

    let outWith = tempOut("pi-with-out")
    defer: removeDir outWith
    let outWithout = tempOut("pi-without-out")
    defer: removeDir outWithout
    let a = ingestSnapshot(IngestConfig(outDir: outWith, snapshotDir: withState,
                                        generation: "1", scope: isFull))
    let b = ingestSnapshot(IngestConfig(outDir: outWithout, snapshotDir: without,
                                        generation: "1", scope: isFull))
    ck a.blocks == b.blocks
    ck a.transactions == b.transactions
    ck a.withTrace == b.withTrace

    let da = treeDigest(outWith)
    let db = treeDigest(outWithout)
    # THE MEASUREMENT. Stated as an equality over the object set bound to its
    # content, not as a count: two objects swapping contents have the same count.
    ck da.len == 83
    ck db.len == 83
    var differing = 0
    for line in da:
      if line notin db: inc differing
    for line in db:
      if line notin da: inc differing
    if differing > 0:
      checkpoint("differing: " & $differing & " of " & $da.len)
    ck differing == 0

  test "…and the CONTROL: the snapshot's OWN sidecars removed makes it differ":
    # Without this the arm above is satisfied by a reader that reads nothing, and
    # by a comparison pointed at the wrong directory.
    let full = tempOut("pi-ctl-full")
    defer: removeDir full
    let stripped = tempOut("pi-ctl-stripped")
    defer: removeDir stripped
    copyCapture(full)
    copyCapture(stripped)
    # Both sidecars whose ABSENCE is a valid snapshot — §5.4 says so of the
    # instruction listing, and the call trace follows its shape. The source bundle
    # and the position stream are deliberately left in place: removing the bundle
    # under a positioned recording is a REFUSAL (S5-BUNDLE-REQUIRED), and a run
    # that raised would prove nothing about what it reads.
    removeDir(stripped / "instructions")
    removeDir(stripped / "calltrace")
    ck dirExists(full / "instructions")
    ck not dirExists(stripped / "instructions")

    let outFull = tempOut("pi-ctl-full-out")
    defer: removeDir outFull
    let outStripped = tempOut("pi-ctl-stripped-out")
    defer: removeDir outStripped
    discard ingestSnapshot(IngestConfig(outDir: outFull, snapshotDir: full,
                                        generation: "1", scope: isFull))
    discard ingestSnapshot(IngestConfig(outDir: outStripped, snapshotDir: stripped,
                                        generation: "1", scope: isFull))
    let df = treeDigest(outFull)
    let ds = treeDigest(outStripped)
    var differing = 0
    for line in df:
      if line notin ds: inc differing
    for line in ds:
      if line notin df: inc differing
    # MEASURED: six containers, each losing its `instructions.json` and its
    # `calltrace.json`, is twelve objects — and they are LOST rather than moved, so
    # twelve differing lines and not twenty-four.
    checkpoint("control differing: " & $differing)
    ck differing == 12
    ck df.len == ds.len + 12

  expectCount(16)
