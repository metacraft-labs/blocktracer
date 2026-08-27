## The conformance validator (M5b).
##
## Both producers — the Demo Data Generator (M5c) and the real extractor/recorder
## (M6, M7, M10) — run this in CI. It checks a static tree + trace manifests
## against the single contract version. It reads **raw JSON**, so it validates any
## producer's output without that output having to pass through model.nim's types
## — which is what makes the demo and real trees interchangeable behind the seam.
##
## What it checks (Data-Contract.md §4):
##   - `root.json` / `manifest.json` carry the supported contract version;
##   - the discriminated-union transaction schema (Static-Site-Architecture §2.3);
##   - `availability: absent` handling — a reason, never a failed fetch (§2.3a);
##   - the four-layer split — immutable facts must NOT carry mutable fields (§2.3b);
##   - index and generation-root shape (§2);
##   - manifest fields, container size/hash, and derived `traceArtifactId` (§4, §2.1);
##   - **walkability**: every reference from `current.json` resolves (no dangles).
##
## It performs no cryptographic provenance check — v1 has none
## (Trace-Artifacts.md §8) — and it recomputes container hashes only structurally.

import std/[json, os, strutils, sets, tables]
import ./contract/[model, version, ids]

type
  Validator* = object
    root*: string                 ## filesystem path to the published tree root
    errors*: seq[string]
    visited: HashSet[string]      ## files reached during the walk
    registry: Table[string, JsonNode]  ## chain -> registry entry

const
  outcomeOveralls = ["succeeded", "reverted", "partial", "failedWithEffects"]
  availabilities = ["ready", "onDemand", "unsupported", "absent", "divergent"]
  validationStatuses = ["match", "divergent", "unchecked"]

proc err(v: var Validator, ctx, msg: string) =
  v.errors.add ctx & ": " & msg

proc loadJson(v: var Validator, rel: string): JsonNode =
  ## Load a tree-relative file, recording it as reached (walkability).
  let p = v.root / rel
  v.visited.incl rel
  if not fileExists(p):
    v.err(rel, "dangling reference — file does not exist")
    return nil
  try:
    result = parseFile(p)
  except CatchableError as e:
    v.err(rel, "invalid JSON: " & e.msg)
    result = nil

proc need(v: var Validator, n: JsonNode, ctx, field: string): bool =
  if n == nil or n.kind != JObject or field notin n:
    v.err(ctx, "missing required field '" & field & "'")
    return false
  true

proc mustBeOneOf(v: var Validator, n: JsonNode, ctx, field: string,
                 allowed: openArray[string]) =
  if not v.need(n, ctx, field): return
  let got = n[field].getStr
  if got notin allowed:
    v.err(ctx, "field '" & field & "' has value '" & got &
          "' not in {" & allowed.join(", ") & "}")

# ---------------------------------------------------------------------------

proc checkContainerAndManifest(v: var Validator, tid, txHash, chain,
                               execInputId: string) =
  ## Derived-path check: the artifact must live exactly where the id says, and
  ## its manifest must be internally consistent (Trace-Artifacts §3, §4, §2.1).
  let sh = traceShards(tid)
  let dir = "t" / sh.a / sh.b / tid
  let mrel = dir / "manifest.json"
  let m = v.loadJson(mrel)
  if m == nil: return
  if v.need(m, mrel, "schema"):
    let sv = m["schema"].getInt
    if not contractSupported(sv):
      v.err(mrel, "manifest schema version " & $sv & " is unsupported")
  if v.need(m, mrel, "traceArtifactId"):
    if m["traceArtifactId"].getStr != tid:
      v.err(mrel, "manifest traceArtifactId does not match its directory " & tid)
  if v.need(m, mrel, "executionInputId"):
    if m["executionInputId"].getStr != execInputId:
      v.err(mrel, "manifest executionInputId disagrees with the transaction facts")
  if v.need(m, mrel, "tx") and m["tx"].getStr != txHash:
    v.err(mrel, "manifest tx does not match the referencing transaction")
  for f in ["recorder", "profile", "container", "execution", "validation",
            "prestateStrategy"]:
    discard v.need(m, mrel, f)
  # container: bytes must equal the real file size; hash must match its bytes.
  if "container" in m:
    let c = m["container"]
    let crel = dir / c{"file"}.getStr("trace.ct")
    let cpath = v.root / crel
    v.visited.incl crel
    if not fileExists(cpath):
      v.err(mrel, "container file missing: " & crel)
    else:
      let bytes = readFile(cpath)
      if c{"bytes"}.getInt != bytes.len:
        v.err(mrel, "container.bytes " & $c{"bytes"}.getInt &
              " != actual file size " & $bytes.len)
      let want = contentHashSha1(bytes)
      if c{"hash"}.getStr != want:
        v.err(mrel, "container.hash does not match container bytes")
  # validation block is not optional decoration (§4).
  if "validation" in m:
    v.mustBeOneOf(m["validation"], mrel & ".validation", "status", validationStatuses)

proc registryFor(v: var Validator, chain: string): JsonNode =
  if chain in v.registry: return v.registry[chain]
  let reg = v.loadJson("registry" / "chains.v" & $ContractVersion & ".json")
  if reg == nil: return nil
  let chains = reg{"chains"}
  if chains == nil or chain notin chains:
    v.err("registry", "no recorder pin for chain '" & chain & "'")
    return nil
  v.registry[chain] = chains[chain]
  chains[chain]

proc checkExecTrace(v: var Validator, ctx: string, t: JsonNode,
                    chain, txHash: string, execIds: Table[string, string]) =
  v.mustBeOneOf(t, ctx, "availability", availabilities)
  let avail = t{"availability"}.getStr
  # §2.3a: a structurally-unobservable execution is `absent` WITH a reason,
  # never a failed fetch.
  if avail in ["absent", "unsupported"]:
    if t{"reason"}.getStr.len == 0:
      v.err(ctx, "availability '" & avail & "' must carry a non-empty reason")
    return  # no artifact expected
  if avail == "onDemand":
    return  # artifact may legitimately not exist yet
  if avail in ["ready", "divergent"]:
    # Must resolve to a real, well-formed artifact. Derive its URL exactly as the
    # client would (Trace-Artifacts §2.1): executionInputId + registry pin.
    let sel = t{"selector"}.getStr("")
    let key = if sel.len > 0: sel else: "*"
    var execInputId = ""
    if key in execIds: execInputId = execIds[key]
    elif execIds.len == 1:
      # A single-execution transaction: the overlay's singular `trace` need not
      # name a selector; the one execution is unambiguous.
      for _, vId in execIds: execInputId = vId
    if execInputId.len == 0:
      v.err(ctx, "overlay execution selector '" & sel &
            "' has no matching executionInputId in the transaction facts")
      return
    let reg = v.registryFor(chain)
    if reg == nil: return
    let rec = reg{"recorder"}
    let prof = reg{"profile"}
    let tid = deriveTraceArtifactId(execInputId, rec{"id"}.getStr,
      rec{"build"}.getStr, prof{"hash"}.getStr, reg{"traceSchema"}.getStr)
    v.checkContainerAndManifest(tid, txHash, chain, execInputId)

proc checkTransaction(v: var Validator, chain, txHash, gen, tsv: string) =
  let sh = hexShard(txHash)
  # --- immutable TransactionFacts (§2.3) ---
  let frel = "d" / chain / "tx" / sh / txHash & ".json"
  let f = v.loadJson(frel)
  var execIds = initTable[string, string]()
  if f != nil:
    for field in ["chain", "id", "order", "outcome", "roles", "cost",
                  "payload", "logs", "codeEdges", "executions", "native"]:
      discard v.need(f, frel, field)
    # discriminated unions must carry their kind
    if "id" in f: discard v.need(f["id"], frel & ".id", "kind")
    if "order" in f: discard v.need(f["order"], frel & ".order", "kind")
    if "outcome" in f:
      v.mustBeOneOf(f["outcome"], frel & ".outcome", "overall", outcomeOveralls)
    # §2.3b: mutable interpretation must NOT be baked into the immutable facts.
    for forbidden in ["canonical", "canonicality", "finality", "trace",
                      "validation"]:
      if forbidden in f:
        v.err(frel, "immutable facts must not carry mutable field '" &
              forbidden & "' (four-layer split, §2.3b)")
    if "executions" in f:
      for e in f["executions"]:
        let sel = e{"selector"}.getStr("")
        let eid = e{"executionInputId"}.getStr
        if eid.len == 0:
          v.err(frel, "execution selector '" & sel & "' missing executionInputId")
        execIds[if sel.len > 0: sel else: "*"] = eid
  # --- GenerationTransactionState (§2.3b) ---
  let strel = "d" / chain / "g" / gen / "txstate" / sh / txHash & ".json"
  let st = v.loadJson(strel)
  if st != nil:
    discard v.need(st, strel, "canonical")
    discard v.need(st, strel, "finality")
  # --- TraceSelection overlay (§2.3a/§2.3b) ---
  let orel = "d" / chain / "ts" / tsv / sh / txHash & ".json"
  let ov = v.loadJson(orel)
  if ov != nil:
    if "executions" in ov:
      for t in ov["executions"]:
        v.checkExecTrace(orel & ".executions[]", t, chain, txHash, execIds)
    elif "trace" in ov:
      v.checkExecTrace(orel & ".trace", ov["trace"], chain, txHash, execIds)
    else:
      v.err(orel, "overlay must carry either 'trace' or 'executions'")

proc checkGeneration(v: var Validator, chain, gen: string) =
  let rrel = "d" / chain / "g" / gen / "root.json"
  let root = v.loadJson(rrel)
  if root == nil: return
  if v.need(root, rrel, "contractVersion"):
    let cv = root["contractVersion"].getInt
    if not contractSupported(cv):
      v.err(rrel, "unsupported contract version " & $cv &
            " (validator supports " & $ContractVersion & ")")
  let tsv = root{"traceSelectionVersion"}.getStr("1")
  let maps = root{"maps"}
  if maps == nil:
    v.err(rrel, "missing 'maps' — generation root must reference every derived map")
    return
  discard v.loadJson(maps{"summary"}.getStr)
  # height epochs
  for p in maps{"height"}: discard v.loadJson(p.getStr)
  # block indices -> block details -> transactions
  for p in maps{"blocks"}:
    let bi = v.loadJson(p.getStr)
    if bi == nil: continue
    for bh in bi{"blocks"}:
      let brel = "d" / chain / "block" / bh.getStr & ".json"
      let bd = v.loadJson(brel)
      if bd == nil: continue
      for tx in bd{"transactions"}:
        v.checkTransaction(chain, tx.getStr, gen, tsv)
  # address lists -> segments
  for p in maps{"addr"}:
    let al = v.loadJson(p.getStr)
    if al == nil: continue
    for sp in al{"segments"}: discard v.loadJson(sp.getStr)

proc validateTree*(root: string): seq[string] =
  ## Validate a published tree rooted at `root`. Returns the list of conformance
  ## errors — empty means the tree conforms to contract version `ContractVersion`.
  var v = Validator(root: root, visited: initHashSet[string]())
  let crel = "d"  # discover chains under /d
  if not dirExists(root / crel):
    return @["no /d data plane found under " & root]
  for chainDir in walkDir(root / crel):
    if chainDir.kind != pcDir: continue
    let chain = extractFilename(chainDir.path)
    let cur = v.loadJson("d" / chain / "current.json")
    if cur == nil: continue
    for field in ["chain", "generation", "head", "finalized"]:
      discard v.need(cur, "d" / chain / "current.json", field)
    let gen = cur{"generation"}.getStr
    if gen.len > 0:
      v.checkGeneration(chain, gen)
  v.errors
