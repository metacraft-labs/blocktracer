## M8 — publisher conformance suite (local backend, no credentials).
##
## Proves the incremental publishing contract from
## `codetracer-specs/BlockTracer/Publishing-And-Caching.md`:
##
##   * §2.1/§2.2 incremental delta + ordering — generation 1 publishes fully and is
##     crawlable; generation 2 (a new block) uploads ONLY the delta and flips the
##     pointer; generation-1 immutable content is skipped, not rewritten.
##   * §2.3 idempotency — a second publish of the same generation uploads zero
##     content objects.
##   * Pipeline-Architecture §3.2a resumability — a run killed before the pointer
##     flip, and a run killed mid-content, both resume from published output with no
##     gap and no double-upload; sync state is reconstructed, never held.
##   * §2.3 single-writer lease — a second concurrent publisher is refused.
##   * §2.1 determinism incident — an input-addressed key present with different
##     bytes is reported and never silently overwritten.
##
## Each block also carries a MUTATION-BITE check: a deliberate perturbation that
## makes the very assertion above fail, proving the assertion is not vacuous.

import std/[unittest, os, strutils, sha1, sequtils, sets]
import ../src/blocktracer/validator
import ../src/blocktracer/demo/generator
import ../src/blocktracer/publish/objectstore
import ../src/blocktracer/publish/publisher

# The synthetic demo tree's slug. It is no longer `aztec`: that slug is the Aztec
# MAINNET's, served at blocktracer.org/aztec, and the fixture moved off it.
const DemoChain = "demo"

# The REAL `noir_space_ship` trace: a CTFS container recorded by `nargo trace`
# (see fixtures/trace/noir_space_ship/README.md), plus the Noir sources the
# generator publishes as content-addressed source bundles.
const fixtureDir = currentSourcePath().parentDir.parentDir / "fixtures" / "trace" / "noir_space_ship"
const fixture = fixtureDir / "zk_shields.ct"
const sourcesDir = fixtureDir / "sources"

proc synthHash(seed, kind: string, n: int): string =
  "0x" & toLowerAscii($secureHash(seed & "|" & kind & "|" & $n))[0 .. 39]

proc tmp(name: string): string =
  result = getTempDir() / "blocktracer-publish-test" / name
  removeDir result
  createDir result

proc genGen1(dir, seed: string) =
  discard generate(DemoConfig(outDir: dir, seed: seed, traceFixturePath: fixture, traceSourcesDir: sourcesDir))

proc genGen2(dir, seed: string) =
  ## Generation 2 = generation 1 + block 103 (one new public tx with a ready trace).
  discard generate(DemoConfig(outDir: dir, seed: seed, traceFixturePath: fixture, traceSourcesDir: sourcesDir,
    generation: "2", extraBlocks: @[103]))

proc findTraceCt(storeDir: string): string =
  for p in walkDirRec(storeDir / "t"):
    if p.endsWith("trace.ct"): return p
  ""

const seed = "publish-seed"

# ---------------------------------------------------------------------------

suite "M8 — generation 1 publishes fully and is crawlable":
  let tree1 = tmp("g1-tree")
  let dest = tmp("g1-store")
  genGen1(tree1, seed)
  let store = newLocalObjectStore(dest)
  let res = publishTree(store, tree1, defaultOptions())

  test "one chain, resumed from nothing, pointer flipped to generation 1":
    check res.len == 1
    check res[0].chain == DemoChain
    check res[0].resumedFrom.present == false
    check res[0].publishedGeneration == "1"
    check res[0].pointerFlipped

  test "everything was uploaded; nothing pre-existed to skip":
    check res[0].contentUploaded.len > 0
    check res[0].contentSkipped.len == 0
    check res[0].determinismIncidents.len == 0

  test "the published store validates against the contract (walkable, no dangles)":
    let errs = validateTree(dest)
    if errs.len > 0:
      for e in errs: echo "  ERR ", e
    check errs.len == 0

  test "MUTATION BITE: dropping a published block detail makes the store dangle":
    # If the publisher had failed to upload content, the walk would dangle here.
    let d2 = tmp("g1-bite-store")
    let s2 = newLocalObjectStore(d2)
    discard publishTree(s2, tree1, defaultOptions())
    var someBlock = ""
    for p in walkDirRec(d2 / "d" / DemoChain / "block"):
      if p.endsWith(".json"): someBlock = p; break
    removeFile(someBlock)
    check validateTree(d2).len > 0

suite "M8 — idempotency: re-publishing a generation uploads zero content":
  let tree1 = tmp("idem-tree")
  let dest = tmp("idem-store")
  genGen1(tree1, seed)
  let store = newLocalObjectStore(dest)
  let first = publishTree(store, tree1, defaultOptions())[0]

  test "the second identical publish uploads zero content objects (§2.3)":
    let second = publishTree(store, tree1, defaultOptions())[0]
    check second.contentUploaded.len == 0
    check second.contentSkipped.len == first.contentUploaded.len
    check second.determinismIncidents.len == 0
    # The pointer is still rewritten unconditionally (idempotent rewrite).
    check ("d/" & DemoChain & "/current.json") in second.pointersWritten
    check second.pointerFlipped

  test "MUTATION BITE: a single missing object makes the idempotent re-run upload it":
    # Delete one already-published content object; the 'zero content' invariant must
    # now be violated by exactly one — proving the assertion above is not vacuous.
    let d2 = tmp("idem-bite-store")
    let s2 = newLocalObjectStore(d2)
    discard publishTree(s2, tree1, defaultOptions())
    var oneTx = ""
    for p in walkDirRec(d2 / "d" / DemoChain / "tx"):
      if p.endsWith(".json"): oneTx = p; break
    removeFile(oneTx)
    let redo = publishTree(s2, tree1, defaultOptions())[0]
    check redo.contentUploaded.len == 1

suite "M8 — incremental delta: generation 2 uploads only the new block":
  let tree1 = tmp("delta-tree1")
  let tree2 = tmp("delta-tree2")
  let dest = tmp("delta-store")
  genGen1(tree1, seed)
  genGen2(tree2, seed)
  let store = newLocalObjectStore(dest)
  let g1 = publishTree(store, tree1, defaultOptions())[0]
  let g2 = publishTree(store, tree2, defaultOptions())[0]

  test "generation 2 resumes from generation 1 and flips the pointer forward":
    check g2.resumedFrom.present
    check g2.resumedFrom.generation == "1"
    check g2.publishedGeneration == "2"
    check g2.pointerFlipped

  test "only the delta is uploaded; generation-1 content is skipped, not rewritten":
    check g2.contentUploaded.len > 0
    check g2.contentUploaded.len < g1.contentUploaded.len   # a genuine delta
    check g2.contentSkipped.len > 0                         # gen-1 objects skipped
    # The new sealed generation root IS in the delta; no generation-1 map is.
    check ("d/" & DemoChain & "/g/2/root.json") in g2.contentUploaded
    check not g2.contentUploaded.anyIt(it.startsWith(("d/" & DemoChain & "/g/1/")))

  test "the delta contains exactly the new block's data and its one new trace":
    let b103 = synthHash(seed, "block", 103)
    check (("d/" & DemoChain & "/block/") & b103 & ".json") in g2.contentUploaded
    # one new ready trace ⇒ its container + manifest (2 input-addressed objects)
    check g2.contentUploaded.filterIt(it.startsWith("t/")).len == 2

  test "the store validates at generation 2, generation 1 content still present":
    let errs = validateTree(dest)
    if errs.len > 0:
      for e in errs: echo "  ERR ", e
    check errs.len == 0
    check fileExists(dest / "d" / DemoChain / "g" / "1" / "root.json")  # not deleted
    check fileExists(dest / "d" / DemoChain / "g" / "2" / "root.json")

  test "re-publishing generation 2 uploads zero content (idempotent delta)":
    let again = publishTree(store, tree2, defaultOptions())[0]
    check again.contentUploaded.len == 0
    check again.pointerFlipped

  test "MUTATION BITE: publishing gen 2 into an EMPTY store uploads far more":
    # The small delta above is meaningful only because gen 1 was already present.
    # Against a fresh store, gen 2 must upload a full tree, not a delta.
    let d2 = tmp("delta-bite-store")
    let s2 = newLocalObjectStore(d2)
    let full = publishTree(s2, tree2, defaultOptions())[0]
    # A fresh store uploads the whole tree — at least double the incremental delta.
    check full.contentUploaded.len >= g2.contentUploaded.len * 2

suite "M8 — resumability: killed before the pointer flip":
  let tree1 = tmp("resume-tree1")
  let tree2 = tmp("resume-tree2")
  let dest = tmp("resume-store")
  genGen1(tree1, seed)
  genGen2(tree2, seed)
  let store = newLocalObjectStore(dest)
  discard publishTree(store, tree1, defaultOptions())

  test "a run halted before the flip leaves content in place but not yet visible":
    var opts = defaultOptions()
    opts.haltBeforePointer = true
    let halted = publishTree(store, tree2, opts)[0]
    check halted.haltedBeforePointer
    check halted.pointerFlipped == false
    check halted.contentUploaded.len > 0
    # Reconstructed from published output: the pointer still names generation 1.
    check readSyncState(store, DemoChain).generation == "1"
    # Extra unreferenced content is harmless — the store is still crawlable at gen 1.
    check validateTree(dest).len == 0

  test "the restarted run reconstructs state and completes with zero content re-upload":
    # A brand-new publisher process (no in-memory state) resumes purely from the store.
    let resumed = publishTree(store, tree2, defaultOptions())[0]
    check resumed.resumedFrom.generation == "1"   # read from the store, not memory
    check resumed.contentUploaded.len == 0         # no double-upload
    check resumed.pointerFlipped
    check resumed.publishedGeneration == "2"
    check validateTree(dest).len == 0

  test "MUTATION BITE: without the halted run's uploads, the resume DOES upload content":
    # Proves the 'zero on resume' assertion depends on the halted run's content being
    # real. Drop one object the halted run wrote; the resume must now re-upload it.
    let d2 = tmp("resume-bite-store")
    let s2 = newLocalObjectStore(d2)
    discard publishTree(s2, tree1, defaultOptions())
    var opts = defaultOptions()
    opts.haltBeforePointer = true
    discard publishTree(s2, tree2, opts)
    removeFile(d2 / "d" / DemoChain / "g" / "2" / "root.json")
    let resumed = publishTree(s2, tree2, defaultOptions())[0]
    check resumed.contentUploaded.len == 1

suite "M8 — resumability: killed mid-content, no gap or double-count":
  let tree1 = tmp("mid-tree1")
  let tree2 = tmp("mid-tree2")
  let dest = tmp("mid-store")
  genGen1(tree1, seed)
  genGen2(tree2, seed)
  let store = newLocalObjectStore(dest)
  discard publishTree(store, tree1, defaultOptions())

  test "a mid-content crash uploads a bounded prefix and does not flip the pointer":
    var opts = defaultOptions()
    opts.maxContentUploads = 3
    let crash = publishTree(store, tree2, opts)[0]
    check crash.contentUploaded.len == 3
    check crash.haltedBeforePointer
    check crash.pointerFlipped == false
    check readSyncState(store, DemoChain).generation == "1"

  test "the restart uploads exactly the remainder — union is complete and disjoint":
    # Compute the full delta from a clean run against a separate gen-1 store.
    let refDest = tmp("mid-ref-store")
    let refStore = newLocalObjectStore(refDest)
    discard publishTree(refStore, tree1, defaultOptions())
    let full = publishTree(refStore, tree2, defaultOptions())[0]

    # The mid-crash store already holds 3 of them; the restart uploads the rest.
    var opts = defaultOptions()
    opts.maxContentUploads = 3
    let d2 = tmp("mid-store-2")
    let s2 = newLocalObjectStore(d2)
    discard publishTree(s2, tree1, defaultOptions())
    let crash = publishTree(s2, tree2, opts)[0]
    let rest = publishTree(s2, tree2, defaultOptions())[0]

    let union = toHashSet(crash.contentUploaded & rest.contentUploaded)
    check crash.contentUploaded.len == 3
    check rest.pointerFlipped
    # No object uploaded twice, and the union equals the full delta — no gap.
    check (toHashSet(crash.contentUploaded) * toHashSet(rest.contentUploaded)).len == 0
    check union == toHashSet(full.contentUploaded)
    check validateTree(d2).len == 0

suite "M8 — single-writer lease per chain":
  let tree1 = tmp("lease-tree")
  let dest = tmp("lease-store")
  genGen1(tree1, seed)
  let store = newLocalObjectStore(dest)

  test "a second publisher is refused while the lease is held":
    check acquireLease(store, DemoChain, "writer-1")
    var opts = defaultOptions()
    opts.writer = "writer-2"
    expect PublishError:
      discard publishTree(store, tree1, opts)

  test "after release, the lease can be re-acquired and publishing proceeds":
    releaseLease(store, DemoChain, "writer-1")
    check acquireLease(store, DemoChain, "writer-2")
    releaseLease(store, DemoChain, "writer-2")
    let res = publishTree(store, tree1, defaultOptions())[0]
    check res.pointerFlipped

  test "MUTATION BITE: a non-atomic 'lease' would let both writers in":
    # putIfAbsent is a real atomic create: the second acquire must fail. A plain
    # exists-then-put would return true here — this asserts it does not.
    let d2 = tmp("lease-bite-store")
    let s2 = newLocalObjectStore(d2)
    check acquireLease(s2, DemoChain, "w1")
    check acquireLease(s2, DemoChain, "w2") == false

suite "M8 — determinism incident on input-addressed objects":
  let tree1 = tmp("det-tree")
  let dest = tmp("det-store")
  genGen1(tree1, seed)
  let store = newLocalObjectStore(dest)
  discard publishTree(store, tree1, defaultOptions())

  test "a stored trace container with different bytes is an incident, never overwritten":
    let ct = findTraceCt(dest)
    check ct.len > 0
    writeFile(ct, "TAMPERED-BYTES-not-the-real-container")   # nondeterministic producer
    let res = publishTree(store, tree1, defaultOptions())[0]
    # The path exists (input-addressed identity matches) but the bytes differ.
    check res.determinismIncidents.len >= 1
    check res.determinismIncidents.anyIt(it.endsWith("/trace.ct"))
    # NOT overwritten — the publisher refuses to serve whichever bytes arrived first.
    check readFile(ct) == "TAMPERED-BYTES-not-the-real-container"
    check not res.contentUploaded.anyIt(it.endsWith("/trace.ct"))

  test "MUTATION BITE: identical bytes are NOT an incident (skip, not alarm)":
    # Re-publish over a clean store: the same container bytes must skip silently.
    let d2 = tmp("det-bite-store")
    let s2 = newLocalObjectStore(d2)
    discard publishTree(s2, tree1, defaultOptions())
    let res = publishTree(s2, tree1, defaultOptions())[0]
    check res.determinismIncidents.len == 0

suite "M8 — refresh: a corrected content object supersedes the published one":
  ## THE PROPERTY AN INCREMENTAL-COVERAGE PIPELINE IS BUILT ON, and the one the
  ## suite above does not reach. Every other case here asks whether a re-run
  ## uploads NOTHING; this one asks what happens when it should upload something
  ## because the producer changed its mind about bytes it already published.
  ##
  ## `d/{chain}/block/{hash}.json` is keyed by the block's hash and filled with
  ## this producer's rendering of that block. Fix a field and the key does not
  ## move, so key-existence — which is the whole of the default strategy — skips
  ## it forever. That is not a slow refresh, it is no refresh: the store keeps
  ## the wrong object for the life of the chain.
  let tree1 = tmp("refresh-tree")
  let dest = tmp("refresh-store")
  genGen1(tree1, seed)
  let store = newLocalObjectStore(dest)
  discard publishTree(store, tree1, defaultOptions())

  proc aBlockKey(): string =
    for p in walkDirRec(tree1 / "d" / DemoChain / "block"):
      if p.endsWith(".json"): return p.relativePath(tree1).replace('\\', '/')
    ""

  let key = aBlockKey()
  let corrected = "{\"corrected\": true}"

  test "the default cycle SKIPS a changed content object — the defect, stated":
    check key.len > 0
    let before = store.get(key)
    check before.ok
    writeFile(tree1 / key, corrected)          # a producer fix, same key
    let res = publishTree(store, tree1, defaultOptions())[0]
    check key in res.contentSkipped
    check res.contentRefreshed.len == 0
    # And the consumer still reads the OLD bytes. This is the assertion the
    # whole option exists for.
    let after = store.get(key)
    check after.ok
    check after.data == before.data
    check after.data != corrected

  test "with --refresh the same run supersedes it, and a consumer sees the new bytes":
    var opts = defaultOptions()
    opts.refreshContent = true
    let res = publishTree(store, tree1, opts)[0]
    check key in res.contentRefreshed
    check key notin res.contentSkipped
    let after = store.get(key)
    check after.ok
    check after.data == corrected

  test "a refresh over an UNCHANGED tree still uploads and refreshes nothing":
    # The cost of the option must be a GET per object, not a PUT per object:
    # a refresh that rewrote everything would make idempotence conditional on
    # which flag was passed.
    var opts = defaultOptions()
    opts.refreshContent = true
    let res = publishTree(store, tree1, opts)[0]
    check res.contentRefreshed.len == 0
    check res.contentUploaded.len == 0
    check res.contentSkipped.len > 0

  test "MUTATION BITE: --refresh does NOT overwrite a divergent trace container":
    # §2.8a is untouched by this: an input-addressed container whose bytes moved
    # under a fixed input is a non-deterministic recorder, and the refresh path
    # must not become a way to launder one into the store.
    let ct = findTraceCt(dest)
    check ct.len > 0
    let published = readFile(ct)
    for p in walkDirRec(tree1 / "t"):
      if p.endsWith("trace.ct"): writeFile(p, "TAMPERED-BY-A-NONDETERMINISTIC-RECORDER")
    var opts = defaultOptions()
    opts.refreshContent = true
    let res = publishTree(store, tree1, opts)[0]
    check res.determinismIncidents.anyIt(it.endsWith("/trace.ct"))
    check not res.contentRefreshed.anyIt(it.endsWith("/trace.ct"))
    check readFile(ct) == published

# ───────────────────────────────────────────────────────────────────────────
# THE ONE COMPARE-AND-SET IN THE SYSTEM, AND THE ONLY PART OF IT THAT IS PURE.
#
# `S3ObjectStore.putIfAbsent` is the whole of the single-writer lease across
# machines, and it is unreachable from this suite by design: the suite is
# credential-free and drives `LocalObjectStore`, whose `putIfAbsent` is a real
# `O_EXCL`. That is exactly how the `--body /dev/stdin` defect lived — the only
# conditional-create in the system had never run, and it returned false on every
# call, on every store, in every state, which `publisher.nim` reported as
# "locked by another publisher (lease held)" over an EMPTY bucket.
#
# The fix for that split a 412 from every other failure, and then the
# discriminator reintroduced the same misdiagnosis class one line down: it was
# `"PreconditionFailed" in outp or "412" in outp`, over a string that is MERGED
# stdout+stderr (`run` sets `poStdErrToStdOut`) and therefore carries the AWS
# CLI's whole diagnostic, including the hex `RequestId` / `HostId` pair S3 prints
# for every failure. `412` in an arbitrary hex identifier is an operational
# certainty rather than a curiosity, so a credential error, a missing bucket or a
# rejected argument list became "another writer won the CAS race" — and a lease
# reported as held is WAITED FOR, so the operator sees a hang instead of the
# error.
#
# NO MOCKS HERE, and none needed: the discriminator is a pure function of the
# CLI's output, so the real function is driven over real CLI output strings.
# Extracting it was the point — a rule only reachable through a network call is a
# rule with no test, which is how the substring got in.
suite "putIfAbsent tells a CAS loss from an error it must not swallow":
  # The real shapes. AWS CLI v2 prints the error code parenthesised; the
  # identifiers are what the substring test tripped over.
  const casLoss = """
An error occurred (PreconditionFailed) when calling the PutObject operation: At least one of the pre-conditions you specified did not hold
"""
  const casLossNumeric = "upload failed: HTTP 412 precondition failed\n"

  test "a real precondition failure IS a CAS loss":
    check isPreconditionFailure(casLoss)
    check isPreconditionFailure(casLossNumeric)

  test "a credential error whose RequestId happens to contain 412 is NOT":
    # This is the arm the old rule failed. The identifiers below are the shape
    # `aws s3api` prints on every failure; the `412` inside them is the accident.
    const badCreds = """
An error occurred (InvalidAccessKeyId) when calling the PutObject operation: The AWS Access Key Id you provided does not exist in our records
RequestId: 9F41236A412C0E11
HostId: b7a412ee9f3c1d
"""
    check not isPreconditionFailure(badCreds)

  test "…and neither is a missing bucket, or a rejected argument list":
    const noBucket = """
An error occurred (NoSuchBucket) when calling the PutObject operation: The specified bucket does not exist
RequestId: 00412AB9CD
"""
    const badArgs = """
Error parsing parameter '--body': Blob values must be a path to a file. Request id 412f00d
"""
    check not isPreconditionFailure(noBucket)
    check not isPreconditionFailure(badArgs)

  test "MUTATION BITE: the bare-substring rule this replaces calls all three a CAS loss":
    # The pairing that makes the arms above evidence rather than assertions: the
    # OLD rule, spelled out, over the same three inputs. If it did not misfire on
    # them the arms above would be testing nothing.
    proc oldRule(outp: string): bool =
      "PreconditionFailed" in outp or "412" in outp
    const badCreds = """
An error occurred (InvalidAccessKeyId) when calling the PutObject operation
RequestId: 9F41236A412C0E11
"""
    const noBucket = "An error occurred (NoSuchBucket)\nRequestId: 00412AB9CD\n"
    const badArgs = "Error parsing parameter '--body'. Request id 412f00d\n"
    check oldRule(badCreds) and oldRule(noBucket) and oldRule(badArgs)
    check not isPreconditionFailure(badCreds)
    check not isPreconditionFailure(noBucket)
    check not isPreconditionFailure(badArgs)
    # And it must still ACCEPT what it should: a gate that refused every 412
    # would trade a false lease for a false error, which is the other direction
    # of the same defect.
    check oldRule(casLoss) and isPreconditionFailure(casLoss)

  test "the word alone, in prose, is not the error CODE":
    # The parenthesised form is the CLI's own; a message that merely mentions
    # preconditions is not a precondition failure. This is why the match is
    # anchored rather than a word search.
    check not isPreconditionFailure(
      "the PreconditionFailed response is documented at https://example.invalid\n")
