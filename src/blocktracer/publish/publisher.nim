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

import std/[json, os, strutils, algorithm, sequtils]

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

proc defaultOptions*(): PublishOptions =
  PublishOptions(chain: "", writer: "publisher-" & $getCurrentProcessId(),
                 takeLease: true, haltBeforePointer: false, maxContentUploads: 0)

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

  for key in keys:
    let cls = classOf(key)
    if cls == ocCurrent:
      currentKey = key           # deferred to the very end
      continue
    let (data, ok) = (block:
      let p = treeDir / key
      if fileExists(p): (readFile(p), true) else: ("", false))
    if not ok: continue

    case strategyOf(cls)
    of stKeyExistence:
      if store.exists(key):
        result.contentSkipped.add key
      else:
        if opts.maxContentUploads > 0 and contentPuts >= opts.maxContentUploads:
          halted = true; break
        store.put(key, data)
        result.contentUploaded.add key
        inc contentPuts
    of stContentHash:
      if store.exists(key):
        let (stored, sok) = store.get(key)
        let same =
          if cls == ocTraceManifest:
            sok and traceContentHash(stored) == traceContentHash(data)
          else:
            sok and stored == data
        if same:
          result.contentSkipped.add key
        else:
          # Input-addressed identity matched but the bytes did not: a
          # non-deterministic producer. Do NOT overwrite; record and alarm (§2.8a).
          result.determinismIncidents.add key
      else:
        if opts.maxContentUploads > 0 and contentPuts >= opts.maxContentUploads:
          halted = true; break
        store.put(key, data)
        result.contentUploaded.add key
        inc contentPuts
    of stUnconditional:
      # A pointer — rewritten every cycle, idempotently.
      store.put(key, data)
      result.pointersWritten.add key

  if halted:
    result.haltedBeforePointer = true
    result.publishedGeneration = result.resumedFrom.generation
    return

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
