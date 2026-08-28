## Generation pinning — the object that makes a mixed generation impossible.
##
## `/d/{chain}/current.json` is the one mutable object per chain
## ([Static-Site-Architecture.md](../../../codetracer-specs/BlockTracer/Static-Site-Architecture.md)
## §3.3). A session resolves it **once** and carries the generation it saw.
## Every generation-scoped read takes a `ChainSession` and derives its
## generation from that one field, so no sequence of calls against this API can
## drift from one generation to another: the pointer is not consulted again,
## and there is no per-read generation parameter to pass a different value to.
## §3.3 puts it plainly: "A session pins the generation it resolved… adopting
## [a new one] is a deliberate transition rather than a silent swap underneath a
## rendered view", and `adopt` is that deliberate transition — it returns a
## **new** session rather than mutating this one.
##
## What this is NOT: `ChainSession` is a plain value with public fields, so a
## consumer that assigns `session.generation = "…"` between reads will get a
## mixed read, and so will one that hands `txStatePath` a generation of its own
## and calls `ObjectStore.get` directly. Neither is prevented by a type. The
## property the tests pin (`tests/tclientsdk.nim`,
## "a pinned generation is never mixed") is the reachable one and the one that
## matters in practice: mixing cannot happen *by navigating*, which is how it
## happens by accident — a pointer re-read on the far side of a click, a cached
## `current.json`, a second component resolving the chain again. Making the
## fields unassignable would cost every consumer the ability to construct a
## session for a test, and would still not stop the path-building route.
##
## The registry's recorder pin is resolved once here too, for the same reason:
## `traceArtifactId` is derived from it (Trace-Artifacts.md §2.1), so a pin that
## moved mid-session would silently change which artifact a page addressed.

import std/[algorithm, json]
import ./store
import ./paths
import ./decode

type
  BlockRef* = object
    height*: int
    hash*: string

  ChainSession* = object
    ## An immutable, coherent view of one chain at one generation.
    chain*: string
    generation*: string
    traceSelectionVersion*: string
    contractVersion*: int
    head*: BlockRef
    finalized*: BlockRef
    hasFinalized*: bool
    root*: GenerationRoot
    pin*: RecorderPin
    hasPin*: bool
    coverageMode*: string
    stale*: bool
    blockCount*: int
    txCount*: int

  OpenOutcome* = enum
    ooOpened = "opened"
    ooChainNotFound = "chainNotFound"
      ## No `current.json` for this chain in this tree.
    ooUnsupportedContract = "unsupportedContract"
      ## The generation declares a contract version this build does not
      ## support. Data-Contract.md §3: refuse rather than misread.
    ooMalformed = "malformed"

  OpenResult* = object
    ## Opening is data, not an exception: a tree that does not carry a chain,
    ## or carries one under a contract version this build cannot read, is a
    ## thing a consumer renders rather than a thing that throws through it.
    case outcome*: OpenOutcome
    of ooOpened:
      session*: ChainSession
    else:
      reason*: string

proc openFailed(o: OpenOutcome, reason: string): OpenResult =
  case o
  of ooChainNotFound: OpenResult(outcome: ooChainNotFound, reason: reason)
  of ooUnsupportedContract: OpenResult(outcome: ooUnsupportedContract, reason: reason)
  of ooMalformed: OpenResult(outcome: ooMalformed, reason: reason)
  of ooOpened: OpenResult(outcome: ooMalformed, reason: reason)

proc readBlockRef(n: JsonNode): BlockRef =
  if n.isNil or n.kind != JObject: return
  BlockRef(height: (if n.hasKey("height") and n["height"].kind == JInt:
                      n["height"].getInt else: 0),
           hash: (if n.hasKey("hash") and n["hash"].kind == JString:
                    n["hash"].getStr else: ""))

proc chains*(store: ObjectStore): seq[string] =
  ## The chains this tree publishes, from the signed registry — the honest
  ## inventory. A tree with no registry publishes no chains; the SDK does not
  ## guess by listing directories, because a consumer reading over HTTP has no
  ## directory listing and an SDK whose answer depends on the transport is not
  ## one answer.
  let r = store.getJson(registryPath())
  if not r.found or r.error.len > 0 or r.node.isNil: return
  if r.node.kind != JObject or not r.node.hasKey("chains"): return
  let cs = r.node["chains"]
  if cs.kind != JObject: return
  for slug, _ in cs: result.add slug
  result.sort()

proc openChain*(store: ObjectStore, chain: string): OpenResult =
  ## Resolve `current.json` once and pin everything derived from it.
  let cur = store.getJson(currentPath(chain))
  if not cur.found:
    return openFailed(ooChainNotFound,
      "no " & currentPath(chain) & " in " & store.name)
  if cur.error.len > 0:
    return openFailed(ooMalformed, cur.error)

  var s = ChainSession(chain: chain)
  let c = cur.node
  if c.kind != JObject or not c.hasKey("generation") or
     not c.hasKey("traceSelectionVersion"):
    return openFailed(ooMalformed,
      currentPath(chain) & ": missing 'generation' or 'traceSelectionVersion'")
  s.generation = c["generation"].getStr
  s.traceSelectionVersion = c["traceSelectionVersion"].getStr
  s.head = readBlockRef(c{"head"})
  if c.hasKey("finalized"):
    s.hasFinalized = true
    s.finalized = readBlockRef(c["finalized"])

  let rootRes = store.getJson(generationRootPath(chain, s.generation))
  if not rootRes.found:
    return openFailed(ooMalformed,
      "generation " & s.generation & " has no root.json")
  if rootRes.error.len > 0:
    return openFailed(ooMalformed, rootRes.error)
  try:
    s.root = decodeGenerationRoot(rootRes.node)
  except ContractDecodeError as e:
    return openFailed(ooMalformed, e.msg)
  s.contractVersion = s.root.contractVersion
  if not contractSupported(s.contractVersion):
    return openFailed(ooUnsupportedContract,
      "root.json declares contractVersion " & $s.contractVersion &
      "; this build supports " & $ContractVersion &
      " (Data-Contract.md §3: refuse rather than misread)")
  # The pointer and the sealed root must agree about which overlay version this
  # generation is read with. They are written by the same producer at the same
  # time, so a disagreement is a producer bug, and adopting either one silently
  # would mean reading a transaction's availability from an overlay the
  # generation never sealed.
  if s.root.traceSelectionVersion != s.traceSelectionVersion:
    return openFailed(ooMalformed,
      "current.json pins traceSelectionVersion '" & s.traceSelectionVersion &
      "' but generation " & s.generation & " sealed '" &
      s.root.traceSelectionVersion & "'")

  if s.root.summaryPath.len > 0:
    let sum = store.getJson(s.root.summaryPath)
    if sum.found and sum.error.len == 0 and sum.node.kind == JObject:
      s.coverageMode = sum.node{"coverageMode"}.getStr
      s.stale = sum.node{"stale"}.getBool
      if sum.node.hasKey("counters"):
        s.blockCount = sum.node["counters"]{"blocks"}.getInt
        s.txCount = sum.node["counters"]{"transactions"}.getInt

  let reg = store.getJson(registryPath(s.contractVersion))
  if reg.found and reg.error.len == 0:
    try:
      s.pin = decodeRecorderPin(reg.node, chain)
      s.hasPin = true
    except ContractDecodeError:
      # A tree may legitimately publish data with no recorder pinned for a
      # chain yet (no recorder exists for that VM). That is `unsupported`
      # availability at the overlay, not a broken session.
      s.hasPin = false

  OpenResult(outcome: ooOpened, session: s)

proc publishedGeneration*(store: ObjectStore, chain: string): string =
  ## The generation the tree currently points at — one read of the ONE mutable
  ## object, and the only place in this package that touches it after a session
  ## is open. A consumer polls this (§3.3) and decides whether to `adopt`.
  let cur = store.getJson(currentPath(chain))
  if not cur.found or cur.error.len > 0 or cur.node.isNil: return ""
  if cur.node.kind != JObject or not cur.node.hasKey("generation"): return ""
  cur.node["generation"].getStr

proc isSuperseded*(store: ObjectStore, session: ChainSession): bool =
  ## Whether a newer generation has been published since this session pinned.
  let g = publishedGeneration(store, session.chain)
  g.len > 0 and g != session.generation

proc adopt*(store: ObjectStore, session: ChainSession): OpenResult =
  ## The deliberate transition of §3.3. Returns a NEW session; the caller's
  ## existing one keeps reading the generation it pinned, so a rendered view is
  ## never swapped underneath.
  openChain(store, session.chain)
