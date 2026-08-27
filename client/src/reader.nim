## Data-plane reader — the seam between the demo tree and the explorer views.
##
## The explorer never invents data: it renders exactly what the `/d/**` object
## tree (Static-Site-Architecture.md §2) contains. That tree is emitted by the
## M5b/M5c demo generator (or, later, the real pipeline) and is the SAME bytes
## the browser downloads — so what this reader parses at build time is what a
## client-side hydration would parse at runtime.
##
## The contract types are IMPORTED, not restated: block details land in the
## canonical `BlockDetail`, and the discriminated-union vocabulary
## (`OutcomeOverall`, `TraceAvailability`, `Role`, `Cost`) is reused verbatim.
## The view structs below (`BlockRow`, `TxRow`, `TxView`) are presentation
## projections over that model — the fields the three M5 views actually show —
## not a second schema. Field names and enum spellings are the contract's.

import std/[os, json, strutils, algorithm]
import blocktracer/contract/model

type
  DataRoot* = object
    ## Root of a static tree: the directory that contains `d/`, `idx/`,
    ## `registry/` and `t/` (i.e. the exporter's `dist/`).
    dir*: string

  ChainInfo* = object
    slug*: string
    generation*: string
    traceSelectionVersion*: string
    headHeight*: int
    headHash*: string
    finalizedHeight*: int
    finalizedHash*: string
    blockCount*: int
    txCount*: int
    coverageMode*: string
    stale*: bool

  BlockRow* = object
    ## One row of the block-list / latest-blocks table.
    hash*: string
    height*: int
    parentHash*: string
    txCount*: int

  ExecView* = object
    ## One execution's trace availability, from the TraceSelection overlay.
    selector*: string          ## "" for a single-execution transaction
    availability*: TraceAvailability
    reason*: string
    bytes*: int
    validationStatus*: string  ## "" when the overlay carries no validation

  TxRow* = object
    ## One row of the shared transactions table (block detail, tx list).
    hash*: string
    height*: int
    index*: int
    fromAddr*: string
    toTarget*: string
    methodSel*: string
    outcome*: OutcomeOverall
    availability*: TraceAvailability   ## the row's headline trace state

  TxView* = object
    ## Everything the transaction-detail view renders.
    chain*, hash*: string
    height*, index*: int
    blockHash*: string
    outcome*: OutcomeOverall
    outcomeReason*: string
    roles*: seq[Role]
    cost*: seq[Cost]
    payloadRaw*, payloadSelector*, payloadTarget*: string
    executions*: seq[ExecView]
    canonical*: bool
    finality*: string
    native*: JsonNode

func newDataRoot*(dir: string): DataRoot = DataRoot(dir: dir)

# ── path helpers (mirror the generator's layout) ───────────────────────────

proc hexShard(hash: string): string =
  ## The two-byte shard directory a hash-addressed object lives under:
  ## `0x27a6c2…` → `27a6` (Static-Site-Architecture.md §2.4).
  let h = if hash.startsWith("0x"): hash[2 .. ^1] else: hash
  if h.len >= 4: h[0 .. 3] else: h

proc readJsonFile(path: string): JsonNode =
  parseJson(readFile(path))

proc dPath(r: DataRoot, parts: varargs[string]): string =
  result = r.dir / "d"
  for p in parts: result = result / p

# ── chains ─────────────────────────────────────────────────────────────────

proc chains*(r: DataRoot): seq[string] =
  ## Chain slugs present in the tree. Prefer the registry (the honest
  ## inventory, Page-Descriptions §3); fall back to scanning `d/`.
  let reg = r.dir / "registry" / "chains.v1.json"
  if fileExists(reg):
    let node = readJsonFile(reg)
    if node.kind == JObject and node.hasKey("chains"):
      let chainsNode = node["chains"]
      case chainsNode.kind
      of JObject:
        # `chains` is a slug-keyed map (the registry's shape).
        for slug, _ in chainsNode: result.add slug
      of JArray:
        for c in chainsNode:
          if c.kind == JObject and c.hasKey("slug"): result.add c["slug"].getStr
          elif c.kind == JString: result.add c.getStr
      else: discard
      if result.len > 0:
        sort(result)
        return
  let dRoot = r.dir / "d"
  if dirExists(dRoot):
    for kind, path in walkDir(dRoot):
      if kind == pcDir: result.add extractFilename(path)
  sort(result)

proc chainInfo*(r: DataRoot, chain: string): ChainInfo =
  ## Head / finality / counters for a chain, from `current.json`, `root.json`
  ## and `summary.json`.
  result.slug = chain
  let cur = readJsonFile(dPath(r, chain, "current.json"))
  result.generation = cur["generation"].getStr
  result.traceSelectionVersion = cur["traceSelectionVersion"].getStr
  result.headHeight = cur["head"]["height"].getInt
  result.headHash = cur["head"]["hash"].getStr
  if cur.hasKey("finalized"):
    result.finalizedHeight = cur["finalized"]["height"].getInt
    result.finalizedHash = cur["finalized"]["hash"].getStr
  let summaryPath = dPath(r, chain, "g", result.generation, "summary.json")
  if fileExists(summaryPath):
    let s = readJsonFile(summaryPath)
    if s.hasKey("counters"):
      result.blockCount = s["counters"]{"blocks"}.getInt
      result.txCount = s["counters"]{"transactions"}.getInt
    result.coverageMode = s{"coverageMode"}.getStr
    result.stale = s{"stale"}.getBool

# ── blocks ───────────────────────────────────────────────────────────────

proc hasBlock*(r: DataRoot, chain, hash: string): bool =
  fileExists(dPath(r, chain, "block", hash & ".json"))

proc hasTx*(r: DataRoot, chain, hash: string): bool =
  fileExists(dPath(r, chain, "tx", hexShard(hash), hash & ".json"))

proc readBlockDetail*(r: DataRoot, chain, hash: string): BlockDetail =
  ## Parse `d/{chain}/block/{hash}.json` into the canonical contract type.
  let n = readJsonFile(dPath(r, chain, "block", hash & ".json"))
  result = BlockDetail(
    chain: n["chain"].getStr,
    hash: n["hash"].getStr,
    height: n["height"].getInt,
    parentHash: n{"parentHash"}.getStr)
  if n.hasKey("transactions"):
    for t in n["transactions"]: result.transactions.add t.getStr

proc blockHashes*(r: DataRoot, chain, generation: string): seq[string] =
  ## The chain's block hashes, newest first, from the generation's block index
  ## (`root.json` → `maps.blocks`).
  let root = readJsonFile(dPath(r, chain, "g", generation, "root.json"))
  var byHeight: seq[tuple[height: int, hash: string]]
  if root.hasKey("maps") and root["maps"].hasKey("blocks"):
    for rel in root["maps"]["blocks"]:
      let idx = readJsonFile(r.dir / rel.getStr)
      if idx.hasKey("blocks"):
        for bh in idx["blocks"]:
          let bd = readBlockDetail(r, chain, bh.getStr)
          byHeight.add (bd.height, bd.hash)
  byHeight.sort(proc(a, b: auto): int = cmp(b.height, a.height))  # descending
  for e in byHeight: result.add e.hash

proc blocks*(r: DataRoot, chain, generation: string): seq[BlockRow] =
  ## Block-list rows, newest first.
  for h in blockHashes(r, chain, generation):
    let bd = readBlockDetail(r, chain, h)
    result.add BlockRow(hash: bd.hash, height: bd.height,
                        parentHash: bd.parentHash, txCount: bd.transactions.len)

# ── transactions ─────────────────────────────────────────────────────────

proc parseAvailability(s: string): TraceAvailability =
  try: parseEnum[TraceAvailability](s)
  except ValueError: taUnsupported

proc headlineAvailability*(execs: seq[ExecView]): TraceAvailability =
  ## The one availability a table row shows for a multi-execution transaction:
  ## the strongest present (ready > divergent > onDemand > absent > unsupported),
  ## so the Debug affordance reflects the best debuggable execution.
  const rank = [taReady, taDivergent, taOnDemand, taAbsent, taUnsupported]
  for want in rank:
    for e in execs:
      if e.availability == want: return want
  taUnsupported

proc readOverlayExecs(r: DataRoot, chain, tsv, hash: string): seq[ExecView] =
  ## The TraceSelection overlay: either a single `trace` or an `executions[]`.
  let path = dPath(r, chain, "ts", tsv, hexShard(hash), hash & ".json")
  if not fileExists(path): return
  let n = readJsonFile(path)
  proc one(e: JsonNode): ExecView =
    result = ExecView(
      selector: e{"selector"}.getStr,
      availability: parseAvailability(e{"availability"}.getStr),
      reason: e{"reason"}.getStr,
      bytes: e{"bytes"}.getInt)
    if e.hasKey("validation"):
      result.validationStatus = e["validation"]{"status"}.getStr
  if n.hasKey("executions"):
    for e in n["executions"]: result.add one(e)
  elif n.hasKey("trace"):
    result.add one(n["trace"])

proc txView*(r: DataRoot, chain, hash: string, info: ChainInfo): TxView =
  ## The full transaction-detail projection: immutable facts + generation-scoped
  ## txstate + the versioned trace overlay, three layers assembled into one view
  ## exactly as the client would at runtime.
  let facts = readJsonFile(dPath(r, chain, "tx", hexShard(hash), hash & ".json"))
  result.chain = facts["chain"].getStr
  result.hash = hash
  if facts.hasKey("order") and facts["order"]{"kind"}.getStr == "blockIndex":
    result.height = facts["order"]{"height"}.getInt
    result.index = facts["order"]{"index"}.getInt
    result.blockHash = facts["order"]{"block"}.getStr
  block:
    let o = facts["outcome"]
    result.outcome =
      try: parseEnum[OutcomeOverall](o["overall"].getStr)
      except ValueError: ooFailedWithEffects
    result.outcomeReason = o{"reason"}.getStr
  if facts.hasKey("roles"):
    for role in facts["roles"]:
      result.roles.add Role(role: role{"role"}.getStr, address: role{"address"}.getStr)
  if facts.hasKey("cost"):
    for c in facts["cost"]:
      result.cost.add Cost(
        name: c{"name"}.getStr, used: c{"used"}.getStr, limit: c{"limit"}.getStr,
        price: c{"price"}.getStr, unit: c{"unit"}.getStr, token: c{"token"}.getStr,
        refundable: c{"refundable"}.getBool)
  if facts.hasKey("payload"):
    result.payloadRaw = facts["payload"]{"raw"}.getStr
    result.payloadSelector = facts["payload"]{"selector"}.getStr
    result.payloadTarget = facts["payload"]{"target"}.getStr
  result.native = facts{"native"}
  result.executions = readOverlayExecs(r, chain, info.traceSelectionVersion, hash)
  # generation-scoped txstate: canonicality + finality
  let stPath = dPath(r, chain, "g", info.generation, "txstate", hexShard(hash), hash & ".json")
  if fileExists(stPath):
    let st = readJsonFile(stPath)
    result.canonical = st{"canonical"}.getBool
    result.finality = st{"finality"}.getStr

proc txRow*(r: DataRoot, chain, hash: string, info: ChainInfo): TxRow =
  ## A single transactions-table row from the same three layers.
  let v = txView(r, chain, hash, info)
  result = TxRow(
    hash: hash, height: v.height, index: v.index,
    outcome: v.outcome, methodSel: v.payloadSelector, toTarget: v.payloadTarget,
    availability: headlineAvailability(v.executions))
  for role in v.roles:
    if role.role in ["feePayer", "signer", "initiator", "sender"]:
      result.fromAddr = role.address
      break
  if result.fromAddr.len == 0 and v.roles.len > 0:
    result.fromAddr = v.roles[0].address
