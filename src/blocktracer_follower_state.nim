## `blocktracer-follower-state` — THE RESIDENT FOLLOWER'S ONLY MEMORY, AND IT LIVES IN THE
## STORE.
##
## Pipeline-Architecture §3.2a: the tip loop's sync state is *bounded* and *a cache, not a
## system of record* — "every field is reconstructible from published output: `head` and the
## displaced-height list come from `current.json` and the generation root, `recentWindow`
## from the height maps, and `pendingRanges` from a scan for missing heights."
##
## That sentence is a specification of a program and nothing implemented it. `publisher.nim`
## already reconstructs the HEAD (`readSyncState`, and this tool calls exactly that rather
## than parsing `current.json` a second time — a second spelling of a published key is how
## a reader goes stale the day the publisher moves it). The other two fields had no reader
## at all, so a follower had nowhere to resume from but its own local directory, which is
## the thing §3.2a says must not be authoritative.
##
## ── WHY THIS IS NIM AND NOT PART OF THE FOLLOWER ─────────────────────────────────────
##
## The follower is `tools/chain/follow-eth-chain.mjs`, in JavaScript, like every other tool
## in this chain's capture path. It must reach R2 in production and a directory in every
## proof, and `ObjectStore` is the abstraction that already spans those two with one
## `putIfAbsent` that is a genuine `O_CREAT|O_EXCL` locally and a genuine
## `If-None-Match: *` against S3. A JavaScript follower that spoke S3 itself would be a
## SECOND S3 client in this repository, needing credentials of its own to be tested at all
## — so the follower holds none, and reaches the store only through this tool and through
## `blocktracer-publish`, both of which take `--backend`.
##
## ── THE TWO SUBCOMMANDS ──────────────────────────────────────────────────────────────
##
##   resume    reconstruct §3.2a's sync state from published output ALONE and print it as
##             JSON. Reads `current.json` through `readSyncState`, then the generation ROOT
##             — which NAMES its height maps — and then those maps. Reading the root rather
##             than guessing `g/{gen}/height/0.json` is the discipline
##             `eth-coverage-proof.sh:mapped_heights` already follows: the map shards the
##             day a chain is big enough, and a hardcoded path stops measuring then without
##             saying so.
##
##   observe   put one tick's observation into the store, at the head of a BOUNDED ring.
##             Lag behind tip is Chain-Data-Ingestion §6's primary SLI and "the number a
##             chain page surfaces as staleness", so it belongs in the store the page reads
##             rather than in a log on the host. The ring is bounded for §3.2a's reason:
##             an object per tick, forever, is the one field of this design that could grow.
##
## ── A ZERO-ARRIVAL TICK IS A WRITE, AND THAT IS THE POINT ────────────────────────────
##
## ING-1: "a window in which nothing arrived must be distinguishable from a window in which
## the loop was not running". Those two are indistinguishable in any design where a quiet
## tick writes nothing — which is every design that reports arrivals instead of
## observations. So `observe` is called on EVERY tick, the ring's newest entry carries the
## height window the tick looked at, and the follower being stopped is visible as a ring
## whose newest entry does not advance.
##
## ── WHAT THIS DOES NOT DO ────────────────────────────────────────────────────────────
##
## It does not publish content, flip a pointer, take the per-chain lease or touch anything
## under `d/` or `src/`. The publish path is `blocktracer-publish`, unchanged, and the
## human-gated pointer flip of Deployment-And-Operations §6c stays where it is. The one key
## this tool writes is `obs/{chain}/follower.json`, which no published generation references
## and which `classOf` therefore files as site-level — the audit's CENSUS compares the
## store's per-class counts against a local tree and fails on a SHORTFALL, so an operational
## key the tree does not contain cannot turn it red.
##
## Usage:
##   blocktracer-follower-state resume  --chain C --backend local --dest DIR [--floor N]
##                                      [--ceiling N]
##   blocktracer-follower-state resume  --chain C --backend s3 --bucket B [--endpoint U]
##                                      [--prefix P]
##   blocktracer-follower-state observe --chain C --backend … --observation FILE [--ring 64]

import std/[os, json, parseopt, strutils, algorithm, tables, times]
import blocktracer/publish/objectstore
import blocktracer/publish/publisher

const
  ## The ring's format, versioned like every other published shape in this repository.
  SliFormat = "blocktracer/follower-sli@1"
  ## How many ticks the published ring keeps. §3.2a's boundedness rule, applied to the one
  ## field of this design that is otherwise unbounded in time rather than in chain depth.
  DefaultRing = 64

proc usage() =
  stderr.writeLine """usage:
  blocktracer-follower-state resume  --chain C --backend local --dest DIR [--floor N] [--ceiling N]
  blocktracer-follower-state observe --chain C --backend local --dest DIR --observation FILE [--ring N]
  (--backend s3 --bucket B [--endpoint U] [--prefix P] in place of --dest)"""

proc currentKeyOf(chain: string): string = "d" / chain / "current.json"
proc genRootKeyOf(chain, gen: string): string = "d" / chain / "g" / gen / "root.json"
proc sliKeyOf(chain: string): string = "obs" / chain / "follower.json"
## The per-chain single-writer lease `publisher.nim` takes and releases. Spelled here
## because `resume` REPORTS it — see the `lease` member of the resume document and the
## comment there on why a resident daemon has to be told about it.
proc leaseKeyOf(chain: string): string = "_leases" / chain & ".lock"

type
  MappedChain = object
    ## Everything the published generation says about which heights are REACHABLE.
    ##
    ## "Present in the store" and "listed by the live generation" are different claims and
    ## the difference is the whole of ING-1's shape-2 defect: a store can hold every block
    ## object of a range, fetchable by hash, while no height map names any of them. A
    ## follower that resumed from object presence would conclude a dropped range was
    ## finished work. This reads the MAPS, i.e. what a reader can reach.
    ok: bool                       ## the root and every map it names were read
    why: string                    ## if not ok, the reason, for the follower to print
    heights: OrderedTable[int, string]   ## height -> block hash, i.e. §3.2a's recentWindow
    shards: int                    ## how many height maps the root named

proc readMapped(store: ObjectStore, chain, gen: string): MappedChain =
  result = MappedChain(ok: false, heights: initOrderedTable[int, string]())
  if gen.len == 0:
    result.why = "the pointer names no generation"
    return
  let (rootData, rootOk) = store.get(genRootKeyOf(chain, gen))
  if not rootOk:
    result.why = "the generation root " & genRootKeyOf(chain, gen) & " is not in the store, " &
      "so the pointer names a generation whose maps cannot be read"
    return
  var root: JsonNode
  try: root = parseJson(rootData)
  except CatchableError as e:
    result.why = "the generation root is not JSON: " & e.msg
    return
  let maps = root{"maps"}{"height"}
  if maps == nil or maps.kind != JArray:
    result.why = "the generation root names no height maps"
    return
  result.shards = maps.len
  for shard in maps:
    let key = shard.getStr
    let (mapData, mapOk) = store.get(key)
    if not mapOk:
      # A NAMED MAP THAT IS NOT THERE IS A REFUSAL, NOT A SMALLER ANSWER. Treating it as
      # "those heights are not covered" would make the follower re-capture work that is
      # published, and the re-capture would then publish a union missing the shard's
      # heights — the defect, reached from the resume side.
      result.why = "the generation root names height map '" & key &
        "' and it is not in the store"
      result.heights.clear()
      return
    try:
      for h, hash in parseJson(mapData){"heights"}.pairs:
        result.heights[parseInt(h)] = hash.getStr
    except CatchableError as e:
      result.why = "height map '" & key & "' is not readable: " & e.msg
      result.heights.clear()
      return
  result.ok = true

proc resumeJson(store: ObjectStore, chain: string, floorArg, ceilingArg: int): JsonNode =
  ## §3.2a's table, every field read from published output.
  let sync = readSyncState(store, chain)
  var generation = ""
  var headHeight = 0
  var headHash = ""
  var finalizedHeight = 0
  if sync.present:
    generation = sync.generation
    headHeight = sync.headHeight
    headHash = sync.headHash
    # `finalized` sits beside `head` in the same pointer. `readSyncState` does not lift it,
    # and this tool reads the pointer a second time rather than widening a published type
    # that two other programs depend on.
    let (cur, curOk) = store.get(currentKeyOf(chain))
    if curOk:
      try: finalizedHeight = parseJson(cur){"finalized"}{"height"}.getInt
      except CatchableError: discard

  let mapped = readMapped(store, chain, generation)
  var heights: seq[int]
  for h in mapped.heights.keys: heights.add h
  heights.sort()

  # ── pendingRanges: "a scan for missing heights" ────────────────────────────
  #
  # The floor is the one number this cannot derive, and it is a POLICY rather than a fact:
  # how far back a follower is responsible for is an operator's decision, and ING-4's
  # backfill is what reaches the rest. So it is stated, and when it is not stated the
  # answer says so rather than inventing genesis.
  let lowest = if heights.len > 0: heights[0] else: 0
  let highest = if heights.len > 0: heights[^1] else: 0
  let scanFrom = if floorArg > 0: floorArg
                 elif heights.len > 0: lowest
                 else: 0
  let scanTo = if ceilingArg > 0: ceilingArg
               elif heights.len > 0: highest
               else: 0
  var pending = newJArray()
  var pendingHeights = 0
  if scanFrom > 0 and scanTo >= scanFrom:
    var runLo = -1
    for h in scanFrom .. scanTo:
      let have = mapped.heights.hasKey(h)
      if not have and runLo < 0: runLo = h
      elif have and runLo >= 0:
        pending.add %*{"from": runLo, "to": h - 1}
        pendingHeights += h - runLo
        runLo = -1
    if runLo >= 0:
      pending.add %*{"from": runLo, "to": scanTo}
      pendingHeights += scanTo - runLo + 1

  # ── THE LEASE, REPORTED RATHER THAN BROKEN ────────────────────────────────
  #
  # `acquireLease` is `putIfAbsent` and `releaseLease` runs in a `finally`; there is no TTL,
  # no fencing token and no owner-liveness test, and `publisher.nim` says so in as many
  # words: "a stale lease is a manual/operational concern, deliberately not auto-broken
  # here to keep single-writer honest." That is the right call for a tool somebody runs.
  #
  # For a RESIDENT daemon it has a consequence the publisher cannot know about: the window
  # between acquire and release is the whole content upload — 1,972 objects for a
  # three-block range, i.e. 1,972 network PUTs against R2 — and a process killed anywhere
  # inside it leaves the lease behind. Every subsequent cycle is then refused by name,
  # forever, until an operator deletes one object. A follower that printed nothing about
  # this would look like a loop that had stopped working for no reason.
  #
  # IT HAS HAPPENED. `publish-r2.yml`'s "Break stale publish leases" step records the
  # incident: run 38388168109's publisher was SIGKILLed when its ephemeral runner was reaped
  # mid-publish, the lock survived, and the next run failed four and three-quarter hours
  # later. That step is the remedy and it is a default-off `workflow_dispatch` input — a
  # HUMAN — because, as it says, a `--break-lease` flag on the binary "would undo that
  # decision for every caller".
  #
  # So it is READ AND REPORTED here, and NOT broken: breaking a lease whose holder might be
  # alive is how two writers end up in one chain's generation, which is the one thing the
  # lease exists to prevent. The remedy is an operator's, and ING-1's report says what the
  # publisher would need for it not to be.
  let (leaseData, leaseHeld) = store.get(leaseKeyOf(chain))

  result = %*{
    "tool": "blocktracer-follower-state",
    "subcommand": "resume",
    "chain": chain,
    "lease": {
      "key": leaseKeyOf(chain),
      "held": leaseHeld,
      "writer": (if leaseHeld: leaseData.strip() else: ""),
    },
    # §3.2a `head` — through the publisher's own reader, not a second parse.
    "head": {
      "present": sync.present,
      "generation": generation,
      "height": headHeight,
      "hash": headHash,
    },
    # §3.2a `finalized` — as the pointer last stated it, which is what the published view
    # claims rather than what the chain says now. The follower asks the node for the latter.
    "finalized": {"height": finalizedHeight},
    # §3.2a `recentWindow` — height -> hash, read from the maps the generation root names.
    # Bounded by how much the live generation maps, which is the published chain depth.
    "recentWindow": {
      "readable": mapped.ok,
      "why": mapped.why,
      "shards": mapped.shards,
      "count": heights.len,
      "lowest": lowest,
      "highest": highest,
      "contiguous": heights.len > 0 and heights.len == highest - lowest + 1,
    },
    "mappedHeights": heights,
    # §3.2a `pendingRanges` — the scan for missing heights, over the stated span.
    "pendingRanges": pending,
    "pendingHeights": pendingHeights,
    "scan": {"from": scanFrom, "to": scanTo,
             "floorStated": floorArg > 0, "ceilingStated": ceilingArg > 0},
  }

proc observe(store: ObjectStore, chain, observationFile: string, ring: int): int =
  ## Prepend one tick's observation to the published ring. Returns the new ring length.
  if not fileExists(observationFile):
    raise newException(IOError, "no observation at " & observationFile)
  let tick = parseJson(readFile(observationFile))

  var entries = newJArray()
  let (old, oldOk) = store.get(sliKeyOf(chain))
  if oldOk:
    try:
      let prev = parseJson(old)
      let prevObservations = prev{"observations"}
      if prevObservations != nil and prevObservations.kind == JArray:
        for e in prevObservations: entries.add e
    except CatchableError:
      # A RING THAT CANNOT BE PARSED IS REPLACED, NOT EXTENDED, and the replacement says so.
      # Refusing instead would stop a resident loop over a corrupted operational object that
      # nothing reads for correctness; silently extending it would hide the corruption.
      entries = newJArray()
      entries.add %*{"note": "the previous ring was unreadable and was discarded"}
  var kept = newJArray()
  kept.add tick
  var n = 1
  for e in entries:
    if n >= ring: break
    kept.add e
    inc n

  # The SLI is lifted to the top of the document, because §6 calls lag "the primary SLI for
  # this stage and the number a chain page surfaces as staleness" — a page should not have
  # to know the ring's shape to read it.
  #
  # LIFTED THROUGH `orNull`, AND NOT BY `tick{…}` DIRECTLY. `{}` yields a nil `JsonNode` for
  # a member that is not there, and a nil node inside a `%*` tree is a crash at `pretty`
  # rather than an absent member — so an observation written by a future tick that does not
  # state `lagSeconds` would take the resident loop down. `src/`'s §13 ban names that shape
  # (`nil-json-value`) and caught exactly this, here, before it ran.
  let orNull = proc (n: JsonNode): JsonNode =
    if n == nil: newJNull() else: n
  let doc = %*{
    "format": SliFormat,
    "chain": chain,
    "updatedAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "lagBlocks": orNull(tick{"lagBlocks"}),
    "lagSeconds": orNull(tick{"lagSeconds"}),
    "lagToFinalized": orNull(tick{"lagToFinalized"}),
    "queueDepth": orNull(tick{"queueDepth"}),
    "tick": orNull(tick{"tick"}),
    "observedAt": orNull(tick{"at"}),
    "ringCapacity": ring,
    "observations": kept,
  }
  store.put(sliKeyOf(chain), pretty(doc) & "\n")
  result = kept.len

proc main() =
  var
    sub = ""
    chain = ""
    backend = "local"
    dest = ""
    bucket = ""
    endpoint = ""
    prefix = ""
    observationFile = ""
    ring = DefaultRing
    floorArg = 0
    ceilingArg = 0
    pending = ""

  proc assign(k, v: string) =
    case k
    of "chain", "c": chain = v
    of "backend", "b": backend = v
    of "dest", "d": dest = v
    of "bucket": bucket = v
    of "endpoint": endpoint = v
    of "prefix": prefix = v
    of "observation": observationFile = v
    of "ring": ring = parseInt(v)
    of "floor": floorArg = parseInt(v)
    of "ceiling": ceilingArg = parseInt(v)
    else: discard
  const valueFlags = ["chain", "c", "backend", "b", "dest", "d", "bucket", "endpoint",
                      "prefix", "observation", "ring", "floor", "ceiling"]

  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": usage(); return
      else:
        if key in valueFlags:
          if val.len > 0: assign(key, val)
          else: pending = key
        else:
          stderr.writeLine "error: unknown flag '--" & key & "'"
          usage(); quit 2
    of cmdArgument:
      if pending.len > 0: assign(pending, key); pending = ""
      elif sub.len == 0: sub = key
      else:
        stderr.writeLine "error: unexpected argument '" & key & "'"; quit 2
    else: discard

  if sub.len == 0:
    stderr.writeLine "error: a subcommand is required"; usage(); quit 2
  if chain.len == 0:
    stderr.writeLine "error: --chain C is required"; quit 2
  if ring < 1:
    stderr.writeLine "error: --ring must be at least 1"; quit 2

  var store: ObjectStore
  case backend
  of "local":
    if dest.len == 0:
      stderr.writeLine "error: local backend needs --dest DIR"; quit 2
    store = newLocalObjectStore(dest)
  of "s3", "r2":
    if bucket.len == 0:
      stderr.writeLine "error: s3 backend needs --bucket NAME"; quit 2
    store = newS3ObjectStore(bucket, prefix = prefix, endpoint = endpoint)
  else:
    stderr.writeLine "error: unknown --backend '" & backend & "'"; quit 2

  case sub
  of "resume":
    echo pretty(resumeJson(store, chain, floorArg, ceilingArg))
  of "observe":
    if observationFile.len == 0:
      stderr.writeLine "error: observe needs --observation FILE"; quit 2
    try:
      let n = observe(store, chain, observationFile, ring)
      echo "observed: ", sliKeyOf(chain), " now holds ", n, " of ", ring, " tick(s)"
    except CatchableError as e:
      stderr.writeLine "error: " & e.msg; quit 1
  else:
    stderr.writeLine "error: unknown subcommand '" & sub & "'"; usage(); quit 2

when isMainModule:
  main()
