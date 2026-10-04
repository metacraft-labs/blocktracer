## The transport encoding of a published container — CCP-6, end to end.
##
## ## What is under test, and why it is its own suite
##
## `CTFS-Compact-Profile.milestones.org` CCP-6 settles how a BlockTracer archive is
## served: the stored object holds the COMPRESSED bytes and carries a
## `Content-Encoding`, the browser decompresses before any application code runs, and the
## header the loader then reads truthfully declares raw. Compression is a property of the
## TRANSPORT and the format reader never learns of it.
##
## CCP-6 also names, in advance, the one cost that has: **a consumer that obtains bytes
## without negotiating an encoding receives the compressed bytes**, and the three
## conformance kits in this repository all obtain bytes by a FILE READ, which negotiates
## nothing. Handed the object at rest, each of them used to report
##
##     container declares 188416 bytes, served 18671
##
## a format defect that does not exist. The milestone's words: "a kit that silently
## accepted compressed bytes as a malformed container would report a format defect that
## does not exist", and the DISTINCT diagnosis is the deliverable rather than a nicety.
##
## So the subject of this suite is a seam that crosses five modules — the pure policy
## (`contract/container_encoding`), the codec (`publish/encoding`), the publication
## (`chain/ingest`), the producer-side kit (`validator`) and the consumer-side kit
## (`blocktracer_client/conformance`) — and the property that matters is a RELATION
## between them. A per-module suite would have each half agreeing with its own idea of
## what the other does, which is the shape the campaign that produced this spent two
## weeks undoing with three byte figures that had become one.
##
## ## NO MOCKS, and the one synthetic thing is named
##
## Per the workspace policy every mock must be justified in the header. There are none:
## the codec is the real `brotli`, the publication is the real `ingestSnapshot`, and both
## kits are the real `validateTreeReport` and `consumerConformance` over a real directory.
##
## WHAT IS SYNTHETIC IS THE CONTAINER'S CONTENTS, and that is deliberate rather than a
## shortcut. Nothing in this seam parses a container: every check here reads its first
## five bytes, its length and its sha1, and those are exactly the three things a
## pre-compressed object changes. A real recording would make the suite depend on a
## sibling checkout that CI does not have — `fixtures/chain-health/readable-container`'s
## container is recorded at test time by `make-readable-container.mjs` and is absent
## wherever `codetracer-trace-format-nim` is — and would buy nothing this seam can use.
## The bytes ARE compressible rather than random, because an incompressible payload would
## make the at-rest figure larger than the raw one and the three-figure relation below
## would be asserting the wrong direction.
##
## ## THE PATH IS MANIPULATED IN TWO ARMS, ON PURPOSE
##
## `brotli` absent is not a hypothetical: it is the state of any host outside this
## repository's devshell, and both kits must degrade to a NAMED gap there rather than to a
## pass or to a false finding. The only honest way to drive it is to take the decoder off
## `PATH` for the duration of one arm, which those arms do and restore afterwards.

import std/[unittest, os, json, strutils]

import ../src/blocktracer/chain/ingest
import ../src/blocktracer/chain/contract_rules
import ../src/blocktracer/contract/ids
import ../src/blocktracer/contract/container_encoding
import ../src/blocktracer/publish/encoding
import ../src/blocktracer/publish/objectstore
import ../src/blocktracer/validator
import ../src/blocktracer_client/store
import ../src/blocktracer_client/conformance

let subjectTree = currentSourcePath().parentDir.parentDir /
  "fixtures" / "chain-health" / "readable-container"

doAssert fileExists(subjectTree / "snapshot.json"),
  "fixtures/chain-health/readable-container/snapshot.json is missing. This suite REFUSES " &
  "rather than skips: it needs a conformant snapshot DOCUMENT (not its container, which " &
  "it writes itself), and a skipped run is a green that means nothing."

var asserted = 0
template ck(condition: untyped) =
  inc asserted
  check condition
template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

proc tempDir(tag: string): string =
  result = getTempDir() / ("bt-enc-test-" & tag & "-" & $getCurrentProcessId())
  removeDir result
  createDir result

proc syntheticContainer(payloadLen: int): string =
  ## A CTFS-magic object whose bytes are compressible.
  ##
  ## See the header: nothing in this seam parses a container, and the payload is
  ## repetitive so the at-rest figure is genuinely smaller than the raw one. A random
  ## payload would grow under brotli and the three-figure relation would be asserted in
  ## the wrong direction — which is a thing a test can do to itself and then pass.
  result = CtfsMagic
  result.add "\x05\x00\x00"          # a plausible version byte and padding
  for i in 0 ..< payloadLen:
    result.add chr(ord('a') + (i mod 7))

proc makeSnapshotTree(tag: string, payloadLen = 40_000): string =
  ## The committed snapshot DOCUMENT and sidecars, with a container this suite wrote.
  ##
  ## The document is copied rather than constructed because it is a conformant
  ## `blocktracer/chain-snapshot@2` tree that `just conformance` passes over, and
  ## constructing one here would be a second opinion about §5 kept in a test file. Only
  ## `containerBytes` moves, because it is a measurement of the file and the file is new.
  result = tempDir(tag)
  for kind, path in walkDir(subjectTree):
    let name = extractFilename(path)
    if name == "ct": continue
    if kind == pcDir: copyDir(path, result / name)
    else: copyFile(path, result / name)
  var snap = parseJson(readFile(result / "snapshot.json"))
  let rel = snap["transactions"][0]["container"].getStr
  let ct = syntheticContainer(payloadLen)
  createDir(result / rel.parentDir)
  writeFile(result / rel, ct)
  snap["transactions"][0]["containerBytes"] = %ct.len
  writeFile(result / "snapshot.json", snap.pretty & "\n")

proc publish(snapshotDir: string, enc: ContainerEncoding): string =
  result = tempDir("pub-" & $enc)
  discard ingestSnapshot(IngestConfig(
    outDir: result, snapshotDir: snapshotDir, generation: "1", scope: isFull,
    containerEncoding: enc))

proc theOneContainer(tree: string): string =
  ## The single `t/**/trace.ct` the subject publishes. Asserted to be single by the
  ## caller rather than assumed here: a walk that found two would make every figure
  ## below "one of them".
  for p in walkDirRec(tree):
    if p.endsWith("trace.ct"): return p
  ""

proc theOneManifest(tree: string): JsonNode =
  for p in walkDirRec(tree):
    if p.endsWith("manifest.json"): return parseJson(readFile(p))
  nil

template withoutBrotli(body: untyped) =
  ## Run `body` with `brotli` off `PATH`, then restore.
  ##
  ## `findExe` resolves per call (see `brotliPath`), which is what makes this possible at
  ## all — a cached lookup would have made the absence untestable from inside a process.
  let savedPath = getEnv("PATH")
  putEnv("PATH", "")
  try:
    body
  finally:
    putEnv("PATH", savedPath)

suite "the closed set, and an unknown encoding is refused rather than defaulted":
  test "every member parses to itself, and the set has exactly two members":
    # PINNED AT TWO, so a member added without a codec fails here. The campaign this
    # comes from enumerated a scheme set bounded by what could be IMPLEMENTED for
    # exactly this reason (CCP-1 finding 2), and an enumerated member with no
    # implementation is the declared-but-unimplemented defect CCP-8 exists to prevent.
    var members = 0
    for e in ContainerEncoding:
      inc members
      let p = parseContainerEncoding($e)
      ck p.ok
      ck p.enc == e
    ck members == 2

  test "the spellings are the HTTP tokens and not names of our own":
    # They go into object metadata, so a second spelling of one state would be the
    # `max_shards` defect with a header on it.
    ck $ceIdentity == "identity"
    ck $ceBrotli == "br"

  test "an unknown encoding is refused BY NAME and never read as identity":
    # §1c's rule. The permissive-default parser is a defect this workspace has met four
    # times, and here it is the most expensive form: compressed bytes read as a
    # container, which is the one failure mode that does not announce itself.
    for bad in ["gzip", "deflate", "zstd", "xz", "BR", "br ", "identity "]:
      let p = parseContainerEncoding(bad)
      ck not p.ok
      ck bad in p.why                      # by NAME
      ck "not one this build implements" in p.why
      ck "identity" in p.why               # and it says what it refused to do instead

  test "the EMPTY string is identity, and that is not a fallback":
    # The field's PRESENCE is what records that compression happened, so its absence can
    # only mean it did not. Distinguished from the unknown case above in both directions.
    let p = parseContainerEncoding("")
    ck p.ok
    ck p.enc == ceIdentity
    ck p.why.len == 0

suite "the codec, and brotli has no magic number":
  test "a container round-trips byte-exactly through brotli":
    let raw = syntheticContainer(40_000)
    let enc = encodeContainer(raw, ceBrotli)
    ck enc.ok
    ck enc.data.len < raw.len
    let dec = decodeContainer(enc.data, ceBrotli)
    ck dec.ok
    ck dec.data == raw                     # byte-exact, not equivalent
    ck dec.data.len == raw.len

  test "identity is a no-op in both directions and copies nothing":
    let raw = syntheticContainer(100)
    ck encodeContainer(raw, ceIdentity).data == raw
    ck decodeContainer(raw, ceIdentity).data == raw

  test "the ENCODED bytes carry no signature, which is why the manifest must say so":
    # MEASURED HERE rather than asserted in prose. gzip has `1f 8b`, zstd `28 b5 2f fd`,
    # xz `fd 37 7a 58 5a 00`; brotli has nothing. This is the whole argument for
    # `container.encoding` being on the manifest: over a file read there is no
    # `Content-Encoding` header, so an absent CTFS magic is the only evidence the bytes
    # carry and it is evidence for nothing in particular.
    let a = encodeContainer(syntheticContainer(40_000), ceBrotli)
    let b = encodeContainer(syntheticContainer(9_000), ceBrotli)
    ck a.ok and b.ok
    ck not looksLikeContainer(a.data)
    ck not looksLikeContainer(b.data)
    # Two different inputs, two different leading bytes — so there is no prefix a
    # detector could key on.
    ck a.data[0 .. 1] != b.data[0 .. 1]

  test "looksLikeContainer is about the first five bytes and nothing else":
    ck looksLikeContainer(CtfsMagic & "anything at all")
    ck not looksLikeContainer("")
    ck not looksLikeContainer(CtfsMagic[0 .. 3])        # one byte short
    ck not looksLikeContainer("\xc0\xde\x72\xac\xe3")   # one bit wrong

  test "with no brotli on PATH, encoding REFUSES rather than storing raw bytes":
    # The dangerous alternative is silently storing identity bytes under a manifest that
    # claims an encoding, which is the one state no consumer can parse and none can
    # diagnose. CONTROL: identity still works with no PATH at all, because it runs no
    # process — otherwise this arm would be measuring the empty PATH.
    withoutBrotli:
      let r = encodeContainer(syntheticContainer(1_000), ceBrotli)
      ck not r.ok
      ck "not on PATH" in r.why
      ck "br" in r.why
      ck encodeContainer("abc", ceIdentity).ok

suite "publication: identity is unchanged, and br is compressed at rest":
  setup:
    let snap = makeSnapshotTree("snap")

  test "under identity the manifest carries NO encoding fields at all":
    # THE BYTE-IDENTITY PROPERTY, and it is what keeps every committed published-tree
    # figure in this repository unmoved by CCP-6. M5c requires a regenerated tree to be
    # byte-identical; three fields written as `"identity"`, `0`, `""` would be three
    # copies of facts already on the row and would move every manifest in the corpus.
    let m = theOneManifest(publish(snap, ceIdentity))
    ck m != nil
    ck not m["container"].hasKey("encoding")
    ck not m["container"].hasKey("storedBytes")
    ck not m["container"].hasKey("storedHash")

  test "under identity the published object IS the snapshot's container":
    let tree = publish(snap, ceIdentity)
    let obj = theOneContainer(tree)
    ck obj.len > 0
    let snapDoc = parseJson(readFile(snap / "snapshot.json"))
    let snapCt = readFile(snap / snapDoc["transactions"][0]["container"].getStr)
    ck readFile(obj) == snapCt
    ck looksLikeContainer(readFile(obj))

  test "under br the object at rest is NOT a container, and the manifest says so":
    let tree = publish(snap, ceBrotli)
    let stored = readFile(theOneContainer(tree))
    let m = theOneManifest(tree)
    ck not looksLikeContainer(stored)
    ck m["container"]["encoding"].getStr == "br"
    ck m["container"]["storedBytes"].getInt == stored.len
    ck m["container"]["storedHash"].getStr == contentHashSha1(stored)

  test "THE THREE FIGURES ARE THREE FIGURES, and the relation is asserted":
    # Conflating "at rest", "on the wire" and "as the loader sees it" is how a 10x and a
    # 21% came to be conflated in the campaign that produced this milestone, so the
    # relation is checked rather than described:
    #   at rest        == the object's own length == container.storedBytes
    #   as the loader  == the decompressed length == container.bytes == the snapshot's own
    #   on the wire    == at rest, because the stored object is what crosses the wire
    let tree = publish(snap, ceBrotli)
    let stored = readFile(theOneContainer(tree))
    let m = theOneManifest(tree)
    let raw = decodeContainer(stored, ceBrotli)
    ck raw.ok
    let atRest = stored.len
    let asLoaderSeesIt = raw.data.len
    ck atRest == m["container"]["storedBytes"].getInt
    ck asLoaderSeesIt == m["container"]["bytes"].getInt
    ck atRest < asLoaderSeesIt                      # the point of doing it at all
    # AND THE LOADER'S BYTES ARE THE CONTAINER, not merely the right length: the
    # header it reads truthfully declares raw because it IS the raw container.
    ck looksLikeContainer(raw.data)
    ck raw.data == readFile(theOneContainer(publish(snap, ceIdentity)))

  test "container.bytes and container.hash keep describing the RAW container":
    # A negotiating consumer — every browser — compares against exactly these and never
    # learns an encoding was involved. If their meaning moved, every existing consumer
    # would break while every figure still looked self-consistent.
    let idTree = publish(snap, ceIdentity)
    let brTree = publish(snap, ceBrotli)
    let a = theOneManifest(idTree)["container"]
    let b = theOneManifest(brTree)["container"]
    ck a["bytes"] == b["bytes"]
    ck a["hash"] == b["hash"]

suite "the snapshot door: an already-encoded container is refused, conditionally":
  test "with publication set to br, a pre-encoded snapshot container is REFUSED by rule":
    # Without this the length check agrees — `containerBytes` is measured against the
    # same file — and the publication compresses it a SECOND time, writing a manifest
    # that describes the inner stream as the raw container. Nothing downstream could tell.
    let snap = makeSnapshotTree("preenc")
    let doc0 = parseJson(readFile(snap / "snapshot.json"))
    let rel = doc0["transactions"][0]["container"].getStr
    let enc = encodeContainer(readFile(snap / rel), ceBrotli)
    ck enc.ok
    writeFile(snap / rel, enc.data)
    var doc = parseJson(readFile(snap / "snapshot.json"))
    doc["transactions"][0]["containerBytes"] = %enc.data.len
    writeFile(snap / "snapshot.json", doc.pretty & "\n")
    var said = ""
    try:
      discard publish(snap, ceBrotli)
    except CatchableError as e:
      said = e.msg
    ck said.len > 0
    ck "S5-CONTAINER-NOT-PREENCODED" in said
    ck "pre-compression is a publication step" in said

  test "CONTROL: the same tree under identity ingests, so the rule is CONDITIONAL":
    # This control is the arm, not decoration. The first version of the check demanded
    # the CTFS magic unconditionally, and `conformance-kit/template/complete/ct/*.ct`
    # are 229-byte ASCII placeholders with no magic at all — so `just conformance` with
    # no argument, the kit checking itself, would have been refused by a rule invented
    # for a hazard that does not exist under identity.
    let snap = makeSnapshotTree("preenc-id")
    let doc0 = parseJson(readFile(snap / "snapshot.json"))
    let rel = doc0["transactions"][0]["container"].getStr
    writeFile(snap / rel, "not a container at all, just text")
    var doc = parseJson(readFile(snap / "snapshot.json"))
    doc["transactions"][0]["containerBytes"] = %"not a container at all, just text".len
    writeFile(snap / "snapshot.json", doc.pretty & "\n")
    var failed = false
    try: discard publish(snap, ceIdentity)
    except CatchableError: failed = true
    ck not failed

suite "the producer-side kit reads a pre-compressed archive, and diagnoses the other case":
  setup:
    let snap = makeSnapshotTree("prod")
    let brTree = publish(snap, ceBrotli)
    let idTree = publish(snap, ceIdentity)

  test "with a decoder, the pre-compressed tree CONFORMS with nothing unmeasured":
    let rep = validateTreeReport(brTree)
    ck rep.findings.len == 0
    ck rep.notMeasured.len == 0

  test "CONTROL: the identity tree conforms too, so the first arm is not a tautology":
    let rep = validateTreeReport(idTree)
    ck rep.findings.len == 0
    ck rep.notMeasured.len == 0

  test "with NO decoder it is NOT MEASURED, by name, and never a finding":
    # CRR-3's first row: the TOOL is absent, so the remedy is to supply it or to fetch
    # differently — not to change the tree. Reporting it as a finding would declare a
    # conformant tree non-conformant for a reason the tree has no part in.
    withoutBrotli:
      let rep = validateTreeReport(brTree)
      ck rep.findings.len == 0
      ck rep.notMeasured.len == 1
      let said = rep.notMeasured[0].message
      ck "PRE-COMPRESSED" in said
      ck "'br'" in said
      ck "not on PATH" in said
      # THE DIAGNOSIS IS DISTINCT, AND THE BAN IS ON THE OLD SENTENCE RATHER THAN ON A
      # WORD. CCP-6's deliverable is that the kit must not report "malformed container";
      # what it used to report was a LENGTH COMPARISON —
      #     container declares 188416 bytes, served 18671
      # — so that shape is what is forbidden here. Banning the WORD "malformed" is what
      # the first version of this arm did, and it went red on the text it was written to
      # require: the diagnosis says "must not be read as a malformed one", disclaiming
      # the reading explicitly, which is the most useful sentence in it. The expectation
      # was stale, not the code.
      ck "container declares" notin said
      ck "bytes, served" notin said
      ck "must not be read as a malformed one" in said
      ck "truncated" notin said
      ck "Re-recording it would change nothing" in said
      # Both figures, labelled, so the at-rest number cannot be read as a short container.
      ck "byte(s) at rest" in said
      ck "as a loader" in said
      # AND IT SAYS WHAT WAS STILL CHECKED, because a gap with no scope reads as a shrug.
      ck "NOT CHECKED" in said

  test "CONTROL: with no decoder the IDENTITY tree reports no gap at all":
    # Otherwise the arm above could be passing because an empty PATH breaks everything.
    withoutBrotli:
      let rep = validateTreeReport(idTree)
      ck rep.findings.len == 0
      ck rep.notMeasured.len == 0

  test "the MIRROR defect is a finding: the manifest claims br and the object is raw":
    # Invisible without an arm for it — the bytes parse, every raw length matches, and
    # the only thing wrong is a field. What it costs is a consumer that negotiates,
    # receives identity bytes under a header claiming otherwise, and fails in its
    # transport layer with nothing pointing here.
    let mirror = tempDir("mirror")
    copyDir(brTree, mirror)
    for p in walkDirRec(mirror):
      if p.endsWith("trace.ct"):
        let rawCt = readFile(theOneContainer(idTree))
        writeFile(p, rawCt)
        for q in walkDirRec(mirror):
          if q.endsWith("manifest.json"):
            var m = parseJson(readFile(q))
            m["container"]["storedBytes"] = %rawCt.len
            m["container"]["storedHash"] = %contentHashSha1(rawCt)
            writeFile(q, m.pretty & "\n")
    let rep = validateTreeReport(mirror)
    ck rep.findings.len >= 1
    var found = false
    for f in rep.findings:
      if "publication defect" in f.message: found = true
    ck found

  test "a storedBytes that disagrees names the OBJECT AT REST, not the container":
    let skewed = tempDir("skew")
    copyDir(brTree, skewed)
    for q in walkDirRec(skewed):
      if q.endsWith("manifest.json"):
        var m = parseJson(readFile(q))
        m["container"]["storedBytes"] = %(m["container"]["storedBytes"].getInt + 1)
        writeFile(q, m.pretty & "\n")
    let rep = validateTreeReport(skewed)
    ck rep.findings.len >= 1
    var said = ""
    for f in rep.findings:
      if "storedBytes" in f.message: said = f.message
    ck said.len > 0
    ck "OBJECT AT REST" in said
    ck "raw container a loader sees" in said

suite "the consumer-side kit, which CANNOT decode and must say so":
  setup:
    let snap = makeSnapshotTree("cons")
    let brTree = publish(snap, ceBrotli)
    let idTree = publish(snap, ceIdentity)

  test "a pre-compressed tree is ACCEPTED, with the raw figures reported unmeasured":
    # The Client SDK's boundary bans `osproc` by name (`ci/test/client-sdk-boundary.sh`,
    # "spawns processes — an embeddable library cannot") and bans
    # `src/blocktracer/publish/` outright, so there is no decoder here and there is not
    # meant to be one. That is not a gap: `storedBytes`/`storedHash` exist so this kit
    # verifies the object AT REST exactly and reaches a verdict rather than a skip.
    let r = consumerConformance(localTree(brTree))
    ck r.ok
    ck r.tracesReplayable == 1
    ck r.notMeasured.len == 1
    let said = r.notMeasured[0]
    ck "RAW container" in said
    ck "holds no decompressor and cannot acquire one" in said
    ck "encoding negotiation" in said
    ck "The object at rest WAS checked" in said
    # The old misdiagnosis was a length comparison; that SHAPE is what must not appear.
    ck "container declares" notin said
    ck "bytes, served" notin said

  test "CONTROL: the identity tree reports NO unmeasured check":
    let r = consumerConformance(localTree(idTree))
    ck r.ok
    ck r.notMeasured.len == 0

  test "the aggregate report rolls the third channel up, which it once did not":
    # A REGRESSION ARM FOR A MEASURED DEFECT. The per-chain report carried the NOT
    # MEASURED entry and the all-chains aggregate dropped it, so
    # `blocktracer-client-conformance` over a pre-compressed tree printed a clean OK
    # with the gap it had just recorded nowhere in sight — the exact shape the channel
    # exists to prevent, produced by the aggregation rather than by the check.
    let one = consumerConformance(localTree(brTree), "readable-container")
    let all = consumerConformance(localTree(brTree))
    ck one.notMeasured.len == 1
    ck all.notMeasured.len == one.notMeasured.len

  test "an un-negotiated read of a tree that declares NOTHING is told apart":
    # The undiagnosable case, said honestly. Compressed bytes under a manifest with no
    # `encoding` cannot be identified from the bytes — brotli has no magic — so the kit
    # says what distinguishes the two cases instead of guessing.
    let bare = tempDir("bare")
    copyDir(brTree, bare)
    for q in walkDirRec(bare):
      if q.endsWith("manifest.json"):
        var m = parseJson(readFile(q))
        m["container"].delete("encoding")
        m["container"].delete("storedBytes")
        m["container"].delete("storedHash")
        writeFile(q, m.pretty & "\n")
    let r = consumerConformance(localTree(bare))
    ck not r.ok
    var said = ""
    for e in r.errors:
      if "CTFS magic" in e: said = e
    ck said.len > 0
    ck "a pre-compressed object would say so in container.encoding" in said

suite "the object store: a local directory cannot carry object metadata":
  test "putMany REFUSES an encoded item, naming the _headers remedy":
    # The base implementation would have written the compressed bytes and dropped the
    # header, producing the one state that is worse than either choice: compressed at
    # rest, advertised as identity. The refusal names what WOULD carry it rather than
    # quietly storing the bytes raw, which would be this backend deciding a policy its
    # caller set.
    let d = tempDir("local")
    let src = d / "src.bin"
    writeFile(src, syntheticContainer(100))
    let s = newLocalObjectStore(d / "store")
    var said = ""
    try:
      s.putMany(@[BulkItem(key: "t/aa/bb/cc/trace.ct", srcPath: src,
                           contentEncoding: "br")])
    except CatchableError as e:
      said = e.msg
    ck said.len > 0
    ck "no per-object metadata" in said
    ck "_headers" in said
    ck "DEL-1b" in said

  test "CONTROL: an UNENCODED item is written, so the refusal is about the encoding":
    let d = tempDir("local2")
    let src = d / "src.bin"
    writeFile(src, "hello")
    let s = newLocalObjectStore(d / "store")
    s.putMany(@[BulkItem(key: "t/aa/bb/cc/trace.ct", srcPath: src)])
    let got = s.get("t/aa/bb/cc/trace.ct")
    ck got.ok
    ck got.data == "hello"

suite "the suite counted itself":
  test "assertion count":
    expectCount(128)
