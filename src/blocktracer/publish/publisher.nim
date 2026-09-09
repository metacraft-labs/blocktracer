## The resumable, incremental delta publisher (M8).
##
## It takes a **generated tree** (one generation from the demo generator, or the
## real pipeline's processing output — the two are interchangeable behind the M5b
## contract) and reconciles it against an `ObjectStore` so that only what is missing
## is uploaded, in an order that never lets a visible reference dangle, and the
## per-chain pointer flips last. It implements, from
## `codetracer-specs/BlockTracer/Publishing-And-Caching.md`:
##
##   §2.1 **Delta** — three upload strategies, one per object class:
##        * content-addressed (blocks, tx facts, overlays, segments, generation
##          maps, index shards, assets, entry pages) → "already there" is a pure
##          **key-existence** check; present ⇒ skip.
##        * input-addressed (`/t/**` trace container + manifest) → key existence is
##          *not* enough (Trace-Artifacts §2.8); the stored bytes / `traceContentHash`
##          are compared, and a mismatch is a **determinism incident**, never a
##          silent skip.
##        * pointer objects (`current.json`, `labels`, `registry`, the names index
##          pointer, the site home) → rewritten **unconditionally** every cycle.
##
##   §2.2 **Ordering** — content before references, the generation root before the
##        pointer: containers → manifests → block/tx/overlay/segment data → index
##        shards → generation maps → `g/{gen}/root.json` (seals) → `current.json`
##        (the visibility flip). Encoded as a per-class rank; additions are uploaded
##        in rank order and `current.json` is always last.
##
##   §2.3 **Atomicity & idempotency** — a cycle interrupted before the pointer flip
##        leaves only unreferenced content (harmless; the next run completes it), and
##        re-running a cycle uploads **zero** content objects.
##
##   §2.3 **Lease** — cycles are strictly ordered per chain; a single-writer lease
##        (an atomic `putIfAbsent`) refuses a second concurrent publisher.
##
##   Pipeline-Architecture §3.2a **Resumable sync state** — the publisher keeps no
##   cross-run system of record. `head`/`generation` are reconstructed from the
##   published `current.json`, so a killed-and-restarted run re-diffs against the
##   store and resumes with no gap and no double-upload.

import std/[json, os, strutils, algorithm, sequtils, tables, md5]

import ./objectstore

# ---------------------------------------------------------------------------
# Object classification (§2.1) and ordering rank (§2.2).
# ---------------------------------------------------------------------------

type
  ObjClass* = enum
    ocAsset            ## content-hashed release asset / font
    ocEntryPage        ## pre-rendered per-entity HTML (immutable for a fixed entity)
    ocTraceContainer   ## /t/**/trace.ct — input-addressed
    ocTraceManifest    ## /t/**/manifest.json — input-addressed
    ocContent          ## immutable data content (block/tx/ts/seg)
    ocIndexShard       ## /idx/** version-addressed shard (immutable at its path)
    ocSourceBundle     ## /src/{chain}/{codeHash}/{bundleHash}.json — immutable
                       ## content-addressed source bundle (Source-Resolution §5).
                       ## Its `current.json` sibling is a POINTER, not this class.
    ocGenMap           ## d/{chain}/g/{gen}/** except root.json
    ocGenRoot          ## d/{chain}/g/{gen}/root.json — seals the generation
    ocPointer          ## ◆ names-index pointer, labels, registry, site home
    ocCurrent          ## d/{chain}/current.json — THE per-chain visibility flip

  Strategy* = enum
    stKeyExistence     ## present ⇒ skip
    stContentHash      ## present ⇒ compare bytes/hash; mismatch ⇒ incident
    stUnconditional    ## always (re)write — a pointer

func classOf*(key: string): ObjClass =
  ## Classify a tree-relative key purely by path shape. The producer never tags an
  ## object; the layout is the contract.
  let k = key.replace('\\', '/')
  if k.endsWith("/current.json") and k.startsWith("d/"):
    return ocCurrent
  if k.startsWith("t/"):
    if k.endsWith("/trace.ct"): return ocTraceContainer
    if k.endsWith("/manifest.json"): return ocTraceManifest
    return ocContent
  if k.startsWith("d/"):
    if "/g/" in k:
      if k.endsWith("/root.json"): return ocGenRoot
      return ocGenMap
    if "/labels/" in k: return ocPointer
    if "/block/" in k or "/tx/" in k or "/ts/" in k or "/seg/" in k:
      return ocContent
    return ocContent
  if k.startsWith("idx/"):
    if k.endsWith("meta.json"): return ocPointer   # the names-index pointer
    return ocIndexShard
  if k.startsWith("src/"):
    # Source bundles: the bundle object is immutable and content-addressed, while
    # `current.json` is the one thing that moves when a better interpretation of
    # the same code lands (Source-Resolution.md §5). Overwriting a bundle in place
    # would be a correctness bug, so it must never get the pointer's
    # write-unconditionally strategy.
    if k.endsWith("/current.json"): return ocPointer
    return ocSourceBundle
  if k.startsWith("registry/"):
    return ocPointer                               # version-tagged, short-TTL pointer
  if k.startsWith("assets/") or k.startsWith("_a/"):
    return ocAsset
  if k == "index.html" or k == "sitemap.xml" or k == "robots.txt":
    return ocPointer                               # site home / release pointers
  if k.endsWith(".html"):
    return ocEntryPage
  # Anything unrecognised is treated as immutable content: safe (skip-if-present),
  # never silently overwritten.
  ocContent

func strategyOf*(cls: ObjClass): Strategy =
  case cls
  of ocTraceContainer, ocTraceManifest: stContentHash
  of ocPointer, ocCurrent: stUnconditional
  else: stKeyExistence

func rankOf*(cls: ObjClass): int =
  ## Upload order (§2.2). Lower first; `ocCurrent` is always last.
  case cls
  of ocAsset: 0
  of ocSourceBundle: 5        # a bundle exists before any manifest recommends it
  of ocTraceContainer: 10     # container before its manifest
  of ocTraceManifest: 11      # manifest before the tx data that claims the trace
  of ocContent: 20            # block/tx/overlay/segment data
  of ocIndexShard: 24
  of ocGenMap: 30             # height/blocks/addr/txstate/summary
  of ocGenRoot: 40            # seals the generation
  of ocEntryPage: 45
  of ocPointer: 90            # non-visibility pointers (names meta, labels, home)
  of ocCurrent: 100           # the visibility flip — last, always

# ---------------------------------------------------------------------------
# Sync state (Pipeline-Architecture §3.2a) — reconstructed, never held.
# ---------------------------------------------------------------------------

type
  SyncState* = object
    present*: bool          ## a published `current.json` was found
    generation*: string     ## last published generation
    headHeight*: int
    headHash*: string

proc readSyncState*(store: ObjectStore, chain: string): SyncState =
  ## Rebuild the per-chain sync head from published output alone. This is the whole
  ## of the publisher's "memory": there is no local system of record, so a fresh
  ## process resumes exactly where the store says the last one left off.
  let (data, ok) = store.get("d" / chain / "current.json")
  if not ok: return SyncState(present: false)
  try:
    let j = parseJson(data)
    SyncState(present: true, generation: j{"generation"}.getStr,
      headHeight: j{"head"}{"height"}.getInt,
      headHash: j{"head"}{"hash"}.getStr)
  except CatchableError:
    SyncState(present: false)

# ---------------------------------------------------------------------------
# The publish result — the audit trail the milestone's proofs assert against.
# ---------------------------------------------------------------------------

type
  PublishResult* = object
    chain*: string
    resumedFrom*: SyncState        ## what the store said on entry
    publishedGeneration*: string   ## generation `current.json` names on exit
    contentUploaded*: seq[string]  ## immutable/input-addressed objects newly written
    contentSkipped*: seq[string]   ## already present ⇒ not rewritten
    contentRefreshed*: seq[string] ## present with DIFFERENT bytes and rewritten (§refresh)
    pointersWritten*: seq[string]  ## ◆ objects rewritten unconditionally
    determinismIncidents*: seq[string]  ## input-addressed key present with different bytes
    pointerFlipped*: bool          ## did `current.json` get (re)written this run
    haltedBeforePointer*: bool     ## crash simulated before the visibility flip

  PublishError* = object of CatchableError

  PublishOptions* = object
    chain*: string             ## "" ⇒ discover chains under d/
    writer*: string            ## lease owner id
    takeLease*: bool           ## acquire the per-chain single-writer lease
    haltBeforePointer*: bool   ## simulate a crash after content, before the flip
    maxContentUploads*: int    ## >0 ⇒ stop after N content puts (mid-cycle crash)
    refreshContent*: bool      ## see below — re-read and supersede changed bytes

  ## ── `refreshContent`, and why "present ⇒ skip" is not enough on its own ────
  ##
  ## §2.1's key-existence strategy is exactly right for the property it is
  ## defending: these objects are addressed by an identity that does not depend
  ## on the producer, so a re-run must not pay to re-upload them, and a cycle
  ## re-run must upload ZERO. That is a performance contract and a correctness
  ## one, and the default is unchanged.
  ##
  ## It is not the whole story, because "content-addressed" is doing two jobs at
  ## this layer and only one of them is true. `/t/**` really is addressed by its
  ## own bytes — a differing container at the same key is a determinism incident
  ## and is refused, which is what `stContentHash` is for. But
  ## `d/{chain}/block/{blockHash}.json` is addressed by the BLOCK's hash while
  ## its bytes are a *rendering* of that block by this producer at this version.
  ## Fix a field in `ingest.nim` and the key does not move, so under
  ## key-existence alone the corrected object can never reach a store that
  ## already holds the wrong one. Not "is republished late" — never.
  ##
  ## An incremental-coverage pipeline is built on the opposite promise: a range
  ## can be uploaded now and REFRESHED later if a defect is found in what
  ## produced it. `refreshContent` is that path. It compares the stored bytes
  ## against what the tree now says and rewrites on a difference, reporting them
  ## separately from first-time uploads so "how much of the store did this run
  ## supersede" is a number rather than an inference.
  ##
  ## It deliberately does NOT extend to `stContentHash`. A `/t/**` container
  ## whose bytes moved under a fixed input is a non-deterministic recorder, and
  ## quietly overwriting it is the one thing §2.8a exists to prevent.

proc defaultOptions*(): PublishOptions =
  PublishOptions(chain: "", writer: "publisher-" & $getCurrentProcessId(),
                 takeLease: true, haltBeforePointer: false, maxContentUploads: 0,
                 refreshContent: false)

# ---------------------------------------------------------------------------
# Lease (§2.3): one writer per chain, enforced by an atomic putIfAbsent.
# Kept under a reserved `_leases/` prefix, outside the browser-visible namespace.
# ---------------------------------------------------------------------------

const leasePrefix = "_leases"

proc leaseKey(chain: string): string = leasePrefix / chain & ".lock"

proc acquireLease*(store: ObjectStore, chain, writer: string): bool =
  store.putIfAbsent(leaseKey(chain), writer & "\n")

proc releaseLease*(store: ObjectStore, chain, writer: string) =
  ## Only the holder releases (best-effort; a stale lease is a manual/operational
  ## concern, deliberately not auto-broken here to keep single-writer honest).
  let (data, ok) = store.get(leaseKey(chain))
  if ok and data.strip() == writer:
    store.del(leaseKey(chain))

# ---------------------------------------------------------------------------
# Tree enumeration.
# ---------------------------------------------------------------------------

proc enumerateTree(treeDir: string): seq[string] =
  ## All tree-relative keys, excluding the lease namespace and temp files.
  for p in walkDirRec(treeDir):
    let rel = p.relativePath(treeDir).replace('\\', '/')
    if rel.startsWith(leasePrefix & "/"): continue
    if ".tmp." in rel: continue
    result.add rel
  result.sort()

proc traceContentHash(manifestJson: string): string =
  ## The stored container hash the input-addressed skip compares against
  ## (Publishing-And-Caching §2.1 / Pipeline-Architecture §3.6).
  try: parseJson(manifestJson){"container"}{"hash"}.getStr
  except CatchableError: ""

# ---------------------------------------------------------------------------
# The publishing cycle for one chain.
# ---------------------------------------------------------------------------

proc publishChain*(store: ObjectStore, treeDir, chain: string,
                   opts: PublishOptions): PublishResult =
  result.chain = chain
  result.resumedFrom = readSyncState(store, chain)

  # Order the additions by rank; `current.json` is separated out so it is written
  # strictly last, and only after everything it could reference is in place.
  var keys = enumerateTree(treeDir)
  # Only keys belonging to this chain, plus the chain-agnostic layers (assets,
  # global hash index, registry, site home) that the tree also carries.
  proc belongs(k: string): bool =
    if k.startsWith("d/"): return k.startsWith("d/" & chain & "/")
    # Source bundles are filed per chain under /src/{chain}/ (Source-Resolution
    # §5). Without this, a manifest's `sourceBundles` recommendation is published
    # while the bundle it names never is, and the debugger steps through code it
    # cannot display.
    if k.startsWith("src/"): return k.startsWith("src/" & chain & "/")
    if k.startsWith(chain & "/"): return true          # this chain's entry pages
    if k.startsWith("t/") or k.startsWith("idx/") or k.startsWith("assets/") or
       k.startsWith("registry/") or k == "index.html" or k == "sitemap.xml" or
       k == "robots.txt": return true
    # another chain's entry pages / data → not ours
    false
  keys = keys.filterIt(belongs(it))

  keys.sort(proc(a, b: string): int =
    let ra = rankOf(classOf(a))
    let rb = rankOf(classOf(b))
    if ra != rb: cmp(ra, rb) else: cmp(a, b))

  var contentPuts = 0
  var currentKey = ""
  var halted = false

  # ── ONE LISTING INSTEAD OF ONE `head-object` PER KEY ──────────────────────
  #
  # The present⇒skip decision is unchanged; only how the store is asked is. A
  # single `list-objects-v2` answers "which of these keys exist" for the whole
  # prefix, and it answers it BETTER than a HEAD per key: N interleaved HEADs
  # observe N different moments of the store, this observes one. It is taken
  # here, inside the cycle, which is after `publishTree` has the lease — so the
  # one writer permitted to move this chain is the one holding the snapshot.
  let stored = store.listMeta("")

  # ── IS THIS STORE'S ETag AN MD5 OF THE OBJECT? ────────────────────────────
  #
  # `--refresh` has to answer "do the stored bytes differ from the tree's", and
  # a listing already carries an ETag which for an ordinary single-part PUT is
  # exactly that MD5 — so the answer is usually free. It is not free to ASSUME:
  # a store using SSE-KMS returns an ETag that is not a digest of the object at
  # all, and is a 32-hex string indistinguishable from one that is.
  #
  # So it is measured rather than assumed, at zero cost, against the one object
  # in the store whose exact bytes this process knows: the lease it just wrote.
  # If the ETag of the lease is the MD5 of the lease, ETags here are MD5s.
  #
  # The failure is one-sided either way, which is why this is safe before it is
  # fast: a mismatched ETag can only make `--refresh` re-upload something that
  # did not need it. It can never report a changed object as unchanged, because
  # that would take an MD5 collision with the tree's own bytes.
  var etagsAreMd5 = false
  if opts.takeLease:
    let lk = leaseKey(chain)
    if stored.hasKey(lk) and stored[lk].md5Known:
      etagsAreMd5 = stored[lk].etag == getMD5(opts.writer & "\n")

  # ── THE BULK BATCH, FLUSHED AT EVERY RANK BOUNDARY ────────────────────────
  #
  # §2.2's ordering is a rank order: nothing of rank r+1 may exist in the store
  # before everything of rank r does, which is what stops a manifest naming a
  # container that is not there and a generation root sealing maps that are not.
  # Batching WITHIN a rank cannot violate that; batching ACROSS one would. So
  # the batch is flushed whenever the rank changes — at most one bulk transfer
  # per class, and the phases stay in the order they were written in.
  var batch: seq[BulkItem] = @[]
  var batchRank = -1
  var confirmed: seq[string] = @[]   # every key handed to `putMany` this cycle

  proc flush() =
    if batch.len == 0: return
    store.putMany(batch)             # raises on a partial or failed transfer
    for it in batch: confirmed.add it.key
    batch.setLen 0

  for key in keys:
    let cls = classOf(key)
    if cls == ocCurrent:
      currentKey = key           # deferred to the very end
      continue
    let srcPath = treeDir / key
    if not fileExists(srcPath): continue

    let rank = rankOf(cls)
    if rank != batchRank:
      flush()
      batchRank = rank

    # Queueing an upload (`batch.add` + `inc contentPuts`, below) never reads the
    # bytes into this process: `putMany` transfers from the tree file itself, so
    # a skipped object now costs no local I/O either.
    case strategyOf(cls)
    of stKeyExistence:
      if stored.hasKey(key):
        if opts.refreshContent:
          let data = readFile(srcPath)
          let m = stored[key]
          let same =
            if etagsAreMd5 and m.md5Known:
              m.etag == getMD5(data)
            else:
              let (sd, sok) = store.get(key)
              sok and sd == data
          if same:
            result.contentSkipped.add key
          else:
            # A refresh is a WRITE and is counted against the upload budget, so a
            # `maxContentUploads` crash drill stops in the same place whether the
            # objects it is stopping among are new or superseded.
            if opts.maxContentUploads > 0 and contentPuts >= opts.maxContentUploads:
              halted = true; break
            batch.add BulkItem(key: key, srcPath: srcPath)
            inc contentPuts
            result.contentRefreshed.add key
        else:
          result.contentSkipped.add key
      else:
        if opts.maxContentUploads > 0 and contentPuts >= opts.maxContentUploads:
          halted = true; break
        batch.add BulkItem(key: key, srcPath: srcPath)
        inc contentPuts
        result.contentUploaded.add key
    of stContentHash:
      # DELIBERATELY STILL A READ PER OBJECT. This is the determinism check, not
      # a skip optimisation: `/t/**` is addressed by the input that produced it,
      # so equal-key-different-bytes is an incident to be raised and never a
      # write to be made. Answering it from a listing's ETag would replace the
      # comparison with a digest of it, and the object whose bytes are in
      # question is the last one to take on faith. These are also the rarest
      # objects in a cycle — the historic ranges published on 2026-09-09 contain
      # none at all — so the per-object cost buys the property at no scale.
      if stored.hasKey(key):
        let data = readFile(srcPath)
        let (sd, sok) = store.get(key)
        let same =
          if cls == ocTraceManifest:
            sok and traceContentHash(sd) == traceContentHash(data)
          else:
            sok and sd == data
        if same:
          result.contentSkipped.add key
        else:
          # Input-addressed identity matched but the bytes did not: a
          # non-deterministic producer. Do NOT overwrite; record and alarm (§2.8a).
          result.determinismIncidents.add key
      else:
        if opts.maxContentUploads > 0 and contentPuts >= opts.maxContentUploads:
          halted = true; break
        batch.add BulkItem(key: key, srcPath: srcPath)
        inc contentPuts
        result.contentUploaded.add key
    of stUnconditional:
      # A pointer — rewritten every cycle, idempotently, and one at a time. There
      # are a handful of these against thousands of content objects, and they are
      # the objects whose write order is load-bearing.
      flush()
      store.put(key, readFile(srcPath))
      result.pointersWritten.add key

  flush()

  if halted:
    result.haltedBeforePointer = true
    result.publishedGeneration = result.resumedFrom.generation
    return

  # ── FAILURE ATOMICITY: THE POINTER FOLLOWS THE OBJECTS, NOT THE INTENT ────
  #
  # A bulk transfer moves many objects under one exit code, so "it returned" has
  # to be turned back into "each of these keys is in the store" before anything
  # references them. One listing does that for the whole cycle. Without it the
  # flip would be advertising a generation on the strength of a process's exit
  # status — which is the shape of the defect that put a pointer at head 74399
  # over a height map that stopped at 74099.
  if confirmed.len > 0:
    let after = store.listMeta("")
    var bad: seq[string] = @[]
    for k in confirmed:
      let src = treeDir / k
      if not after.hasKey(k):
        bad.add k & " (absent)"
      elif after[k].size >= 0 and after[k].size != getFileSize(src):
        # A short object is the shape a truncated transfer takes, and it is
        # invisible to a presence check.
        bad.add k & " (size " & $after[k].size & " != " & $getFileSize(src) & ")"
      elif etagsAreMd5 and after[k].md5Known and
           after[k].etag != getMD5(readFile(src)):
        bad.add k & " (content digest differs)"
      if bad.len >= 5: break        # the first few name the failure; the count is the story
    if bad.len > 0:
      raise newException(PublishError,
        "refusing to flip the pointer: " & $confirmed.len &
        " object(s) were uploaded in bulk and the store does not confirm all of " &
        "them — " & bad.join("; "))

  if opts.haltBeforePointer:
    # Crash simulated after all content is in place but before the visibility flip.
    # The store now holds unreferenced content (safe, §2.3) and `current.json`
    # still names the previous generation.
    result.haltedBeforePointer = true
    result.publishedGeneration = result.resumedFrom.generation
    return

  # Step 12: the visibility flip. Everything it can reference is already present.
  if currentKey.len > 0:
    store.put(currentKey, readFile(treeDir / currentKey))
    result.pointersWritten.add currentKey
    result.pointerFlipped = true

  result.publishedGeneration = readSyncState(store, chain).generation

proc discoverChains(treeDir: string): seq[string] {.used.} =
  let d = treeDir / "d"
  if not dirExists(d): return
  for entry in walkDir(d):
    if entry.kind == pcDir: result.add extractFilename(entry.path)
  result.sort()

proc publishTree*(store: ObjectStore, treeDir: string,
                  opts = defaultOptions()): seq[PublishResult] =
  ## Publish every chain found in `treeDir` (or just `opts.chain`). Each chain is a
  ## strictly-ordered cycle under its own single-writer lease; different chains are
  ## independent (§2.3).
  var chains =
    if opts.chain.len > 0: @[opts.chain] else: discoverChains(treeDir)
  if chains.len == 0:
    raise newException(PublishError, "no chains found under " & treeDir / "d")
  for chain in chains:
    if opts.takeLease and not acquireLease(store, chain, opts.writer):
      raise newException(PublishError,
        "chain '" & chain & "' is locked by another publisher (lease held)")
    try:
      result.add publishChain(store, treeDir, chain, opts)
    finally:
      if opts.takeLease: releaseLease(store, chain, opts.writer)
