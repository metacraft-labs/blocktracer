## Source bundles, per code hash.
##
## [Source-Resolution.md](../../../codetracer-specs/BlockTracer/Source-Resolution.md)
## §5. Two objects, and the split is the whole design:
##
## ```
## /src/{chain}/{codeHash}/{bundleHash}.json     immutable — the bundle itself
## /src/{chain}/{codeHash}/current.json          ◆ pointer to the best bundle so far
## ```
##
## Keyed by **code hash, not address**, so every deployment of the same
## contract shares one bundle — which is what makes a popular router or token
## implementation cost one fetch rather than one per transaction.
##
## Two things this module deliberately does not do:
##
##   * **It never contacts a verification service.** The pipeline resolves,
##     validates and publishes bundles (§5), so the browser inherits none of a
##     provider's CORS, auth, SSRF or availability problems. This module reads
##     two published files.
##   * **It never treats "no source" as an error.** An unverified contract is
##     the normal case on every chain, and Static-Site-Architecture.md §6 says
##     what happens: the page renders raw values with a "not yet decoded" note
##     and upgrades in place when a bundle appears.
##
## Precedence, and why: the **manifest's recommendation wins**. Trace-Artifacts
## §4 says `sourceBundles` "names the recommended interpretation per code hash
## — the interpretation the page should use", and §2.5 that moving the pointer
## changes what a page displays without regenerating anything. So a trace view
## uses what its manifest recommends and a page with no trace falls back to the
## chain-wide pointer.

import std/json
import ./store
import ./paths
import ./decode

type
  BundleSource* = enum
    bsManifest = "manifest"      ## recommended by the trace manifest (§4)
    bsPointer = "pointer"        ## `current.json`, the best bundle so far (§5)
    bsNone = "none"

  SourceBundleRef* = object
    ## Where a code hash's source lives, before fetching it.
    codeHash*: string
    chain*: string
    origin*: BundleSource
    sourceBundleId*: string
    path*: string
    reason*: string              ## why there is none, when `origin == bsNone`

  MatchQuality* = enum
    mqUnknown = "unknown"
    mqPartial = "partial"
    mqFull = "full"

  SourceBundle* = object
    ## The bundle object of §5. `sources` and `debug` are carried as raw JSON:
    ## their inner shape is the compiler's, it differs per language, and
    ## restating it here would be a second schema for bytes this package only
    ## forwards.
    schema*: int
    codeHash*: string
    chain*: string
    match*: MatchQuality
    provider*: string
    language*: string
    compilerName*: string
    compilerVersion*: string
    sources*: JsonNode
    debug*: JsonNode

  BundleOutcome* = enum
    boLoaded = "loaded"
    boNotPublished = "notPublished"
    boMalformed = "malformed"
    boMismatched = "mismatched"
      ## The bundle names a different code hash than the one asked for. A
      ## bundle whose bytecode does not match the deployed code is discarded
      ## (Source-Resolution.md §4, M13's `test_mismatched_source_bundle_is_rejected`);
      ## the consumer-side half of that is refusing to *display* one.

  BundleResult* = object
    reference*: SourceBundleRef
    case outcome*: BundleOutcome
    of boLoaded: bundle*: SourceBundle
    else: reason*: string

proc manifestRecommendation*(manifest: TraceManifest, codeHash: string): string =
  ## The `sourceBundleId` the manifest recommends for a code hash, or "".
  if manifest.sourceBundles.isNil or manifest.sourceBundles.kind != JObject:
    return ""
  if not manifest.sourceBundles.hasKey(codeHash): return ""
  let v = manifest.sourceBundles[codeHash]
  if v.kind != JString: "" else: v.getStr

proc resolveFromManifest*(chain: string, manifest: TraceManifest,
                          codeHash: string): SourceBundleRef =
  let id = manifestRecommendation(manifest, codeHash)
  if id.len == 0:
    return SourceBundleRef(codeHash: codeHash, chain: chain, origin: bsNone,
      reason: "the trace manifest recommends no source bundle for this code hash")
  SourceBundleRef(codeHash: codeHash, chain: chain, origin: bsManifest,
    sourceBundleId: id,
    path: sourceBundlePath(chain, codeHash, shortBundleHash(id)))

proc resolveFromPointer*(store: ObjectStore, chain, codeHash: string): SourceBundleRef =
  ## Follow `/src/{chain}/{codeHash}/current.json`. A missing pointer is the
  ## ordinary "not verified yet" case, reported with its reason.
  let p = sourceBundlePointerPath(chain, codeHash)
  let r = store.getJson(p)
  if not r.found:
    return SourceBundleRef(codeHash: codeHash, chain: chain, origin: bsNone,
      reason: "no source bundle published for this code hash")
  if r.error.len > 0:
    return SourceBundleRef(codeHash: codeHash, chain: chain, origin: bsNone,
      reason: r.error)
  let n = r.node
  if n.kind != JObject:
    return SourceBundleRef(codeHash: codeHash, chain: chain, origin: bsNone,
      reason: p & ": pointer is not an object")
  # The pointer may name the bundle by id or by its object path; both are in
  # use across producers and neither is worth a contract change to unify.
  let id = n{"sourceBundleId"}.getStr
  var path = n{"bundle"}.getStr
  if path.len == 0 and id.len > 0:
    path = sourceBundlePath(chain, codeHash, shortBundleHash(id))
  if path.len == 0:
    return SourceBundleRef(codeHash: codeHash, chain: chain, origin: bsNone,
      reason: p & ": pointer names neither 'sourceBundleId' nor 'bundle'")
  SourceBundleRef(codeHash: codeHash, chain: chain, origin: bsPointer,
    sourceBundleId: id, path: normalisePath(path))

proc resolveSourceBundle*(store: ObjectStore, chain: string,
                          manifest: TraceManifest, hasManifest: bool,
                          codeHash: string): SourceBundleRef =
  ## Manifest recommendation first, then the chain-wide pointer (see the module
  ## doc for why that order).
  if hasManifest:
    let m = resolveFromManifest(chain, manifest, codeHash)
    if m.origin == bsManifest: return m
  resolveFromPointer(store, chain, codeHash)

proc decodeSourceBundle*(n: JsonNode): SourceBundle =
  result.schema = n{"schema"}.getInt
  result.codeHash = n{"codeHash"}.getStr
  result.chain = n{"chain"}.getStr
  result.provider = n{"provider"}.getStr
  result.language = n{"language"}.getStr
  result.match =
    case n{"match"}.getStr
    of "full": mqFull
    of "partial": mqPartial
    else: mqUnknown
  if n.hasKey("compiler"):
    result.compilerName = n["compiler"]{"name"}.getStr
    result.compilerVersion = n["compiler"]{"version"}.getStr
  result.sources = if n.hasKey("sources"): n["sources"] else: newJObject()
  result.debug = if n.hasKey("debug"): n["debug"] else: newJObject()

proc fetchSourceBundle*(store: ObjectStore, r: SourceBundleRef): BundleResult =
  ## Fetch and check one bundle. The code-hash check is the point: an immutable
  ## bundle object is content-addressed by its own bytes, so a bundle sitting
  ## under the wrong code hash means the tree is wrong and displaying it would
  ## attribute source to code that never ran.
  if r.origin == bsNone:
    return BundleResult(reference: r, outcome: boNotPublished,
      reason: (if r.reason.len > 0: r.reason else: "no bundle reference"))
  let res = store.getJson(r.path)
  if not res.found:
    return BundleResult(reference: r, outcome: boNotPublished,
      reason: r.path & " is not published")
  if res.error.len > 0:
    return BundleResult(reference: r, outcome: boMalformed, reason: res.error)
  if res.node.kind != JObject:
    return BundleResult(reference: r, outcome: boMalformed,
      reason: r.path & ": bundle is not an object")
  let b = decodeSourceBundle(res.node)
  if b.codeHash.len > 0 and r.codeHash.len > 0 and b.codeHash != r.codeHash:
    return BundleResult(reference: r, outcome: boMismatched,
      reason: r.path & " declares codeHash " & b.codeHash & ", not " & r.codeHash)
  BundleResult(reference: r, outcome: boLoaded, bundle: b)

proc codeHashes*(facts: TransactionFacts): seq[string] =
  ## Every executed code hash a transaction touched, from its versioned code
  ## edges (§2.1a: keyed by code hash, never a column). Deduplicated, because a
  ## transaction touching one contract twice needs its source fetched once —
  ## which is the caching property §5 is built around.
  for e in facts.codeEdges:
    if e.codeHash.len > 0 and e.codeHash notin result:
      result.add e.codeHash
