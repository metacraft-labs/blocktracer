## The read seam of the Client SDK — the ONE way this package obtains bytes.
##
## Everything the SDK reads goes through a single injected closure whose entire
## input is a **path**. That is not an abstraction for its own sake; it is what
## makes two of this package's properties structural rather than aspirational:
##
##   * **No identity** ([CodeTracer-Identity.md](../../../codetracer-specs/Planned-Features/CodeTracer-Identity.md)
##     §4). There is no header parameter, no credential parameter, no cookie jar
##     and no request-options object. Nothing in this package holds, derives,
##     defaults or forwards an identity: every read it issues is a path and
##     nothing else, and there is no second seam — no global, no environment
##     read, no clock, no process — through which one could be added at a call
##     site instead. `ci/test/client-sdk-boundary.sh` scans the whole graph for
##     the vocabulary and fails the build on a hit.
##
##     The honest limit: the closure is the *consumer's*, so a consumer can of
##     course capture a credential in its own `fetchProc`. That is their
##     transport and their decision. What is structural here is that this
##     package never asks for one, never supplies one, and offers no parameter
##     that would make attaching one look like ordinary use of the SDK.
##   * **No chain RPC** ([Client-SDK.md](../../../codetracer-specs/BlockTracer/Client-SDK.md)
##     §3, exclusions). The SDK never opens a socket itself. It asks for a path
##     under the published tree; whether that is a file, a CDN or a service
##     worker's cache is the consumer's business.
##
## A `404` is not an error. `ObjectResponse.found = false` is a first-class
## outcome, because the read path is full of objects that legitimately may not
## exist yet — an on-demand trace artifact, a source bundle for an unverified
## contract — and turning those into exceptions is precisely how
## `availability: absent` degenerates into "a failed fetch"
## ([Static-Site-Architecture.md](../../../codetracer-specs/BlockTracer/Static-Site-Architecture.md) §2.3a).

import std/[json, os, strutils, tables]

type
  ObjectResponse* = object
    ## The result of one read. `found = false` means the object is not present;
    ## it is data, never an exception.
    found*: bool
    body*: string

  ObjectStore* = object
    ## A published static tree, reachable by path.
    ##
    ## `fetchProc` takes a path and nothing else. See the module doc: the
    ## absence of every other parameter is the point.
    name*: string
    fetchProc*: proc(path: string): ObjectResponse {.closure.}

  ObjectStoreDefect* = object of ValueError
    ## Raised when an `ObjectStore` cannot possibly be read — no `fetchProc`.
    ## A construction error in the consumer's code, distinct from a missing
    ## object, which is `found = false`.

proc newObjectStore*(name: string;
                     fetch: proc(path: string): ObjectResponse {.closure.}): ObjectStore =
  ## Build a store over any transport the consumer already has.
  ObjectStore(name: name, fetchProc: fetch)

proc isValid*(store: ObjectStore): bool =
  not store.fetchProc.isNil

proc normalisePath*(path: string): string =
  ## The canonical spelling of an object path: no leading slash, no `./`, and
  ## no `..` segment. Returns `""` for a path that escapes the tree, which
  ## every caller treats as "not found" rather than reaching outside it.
  var parts: seq[string]
  for seg in path.split('/'):
    case seg
    of "", ".": continue
    of "..": return ""
    else: parts.add seg
  parts.join("/")

proc get*(store: ObjectStore, path: string): ObjectResponse =
  ## Read one object. Never raises for a missing object.
  if not store.isValid:
    raise newException(ObjectStoreDefect,
      "ObjectStore '" & store.name & "' has no fetch procedure")
  let p = normalisePath(path)
  if p.len == 0: return ObjectResponse(found: false)
  store.fetchProc(p)

type
  JsonResponse* = object
    ## A read plus its parse. `error` is non-empty only when the object was
    ## found and did not parse — a malformed object is reported, never thrown
    ## through a consumer's navigation.
    found*: bool
    error*: string
    node*: JsonNode

# ---------------------------------------------------------------------------
# The whole-site-export JSON cache (§ opt-in, and off by default).
# ---------------------------------------------------------------------------
#
# WHAT IT IS FOR, MEASURED. A page render reads a constant NUMBER of objects,
# and `reader.nim`'s `newDataRoot(dir, store)` overload says a test checks
# exactly that — "constant per-page cost … as counts of reads rather than
# asserted in a comment". The count is constant and the test is sound. The cost
# is not, because three of those reads are WHOLE-CHAIN SINGLETONS that grow with
# the chain:
#
#     d/{chain}/g/{gen}/root.json      421 KB at 10k blocks, 6.8 MB at 102k
#     d/{chain}/g/{gen}/height/0.json  819 KB at 10k blocks
#     d/{chain}/g/{gen}/blocks/0.json  740 KB at 10k blocks
#
# `renderBlock` alone reaches the height map twice (`canonicalBlockAt`,
# `nextBlockHash`) and the blocks map once (`hasBlock`). So a render parses
# megabytes of JSON to answer three lookups, and an export over N pages parses
# O(N) of them N times. Measured: 1.85 ms/page at 100 blocks, 3.02 at 1,000,
# 114.54 at 10,000 — the export never finished at 10k in 1,800 s.
#
# The metric hid it. Reads-per-page is the right shape for "renders from
# published files only" and the wrong one for cost, because it counts requests
# and the thing that grows is bytes.
#
# WHAT IT DOES NOT DO, STATED HERE SO THE NEXT READER DOES NOT ASSUME IT. It does
# NOT fix the export's cost curve. Measured at 10,000 blocks: 114.5 ms/page
# before, ~88 ms/page after — about 23%, real and worth having, and nowhere near
# the 1.85-3.02 ms/page the small origins show. The dominant term is elsewhere
# and was still unidentified when this landed. Three mechanisms had been proposed
# and refuted by then (a directory-insert cost, at 0.1% of the per-page time; a
# merely-linear-and-large render; and this parse), each of which fit the measured
# curve. Fitting the curve is not causing it.
#
# WHY IT CACHES THE PARSED NODE AND NOT THE BYTES. The bytes are already cheap —
# the filesystem serves them from page cache. `parseJson` over 6.8 MB is the
# cost, and a store-level byte cache would leave every page paying it.
#
# WHY IT IS OPT-IN AND WHY IT ONLY HOLDS SINGLETONS. A running client must
# resolve `d/{chain}/current.json` once per NAVIGATION — `ssr.nim`'s
# `renderRoute` explains why, and a mutation bite enforces it — so nothing may
# cache across navigations by default. A static export is one moment and may.
# And only the singletons are held: block and transaction objects are read once
# each, so caching them would trade a bounded win for an unbounded resident set
# over a tree measured in gigabytes.
var jsonCache: TableRef[string, JsonResponse] = nil

proc enableSingletonJsonCache*() =
  ## Turn the cache on for THIS PROCESS. A whole-site export calls this; a
  ## client must not.
  jsonCache = newTable[string, JsonResponse]()

func isWholeChainSingleton(path: string): bool =
  ## The objects whose size grows with the chain and which every page re-reads.
  path.contains("/g/") or path.endsWith("/current.json") or
    path.startsWith("registry/")

proc getJson*(store: ObjectStore, path: string): JsonResponse =
  let cacheable = jsonCache != nil and isWholeChainSingleton(path)
  let key = if cacheable: store.name & "\0" & path else: ""
  if cacheable and jsonCache.hasKey(key): return jsonCache[key]
  let r = store.get(path)
  if not r.found: return JsonResponse(found: false)
  try:
    result = JsonResponse(found: true, node: parseJson(r.body))
  except CatchableError as e:
    result = JsonResponse(found: true, error: path & ": " & e.msg)
  if cacheable: jsonCache[key] = result

# ---------------------------------------------------------------------------
# The filesystem implementation.
#
# It is the one the pre-render pass and the conformance suite use: the exporter
# reads the same bytes the browser would download, which is the property
# Static-Site-Architecture.md §4 depends on ("both paths must render
# identically").
# ---------------------------------------------------------------------------

proc localTree*(dir: string): ObjectStore =
  ## A store over a directory holding `d/`, `idx/`, `registry/`, `src/` and `t/`.
  let root = dir
  newObjectStore("local:" & dir, proc(path: string): ObjectResponse =
    let full = root / path
    if fileExists(full):
      ObjectResponse(found: true, body: readFile(full))
    else:
      ObjectResponse(found: false))

# ---------------------------------------------------------------------------
# Observation, for consumers and for tests.
#
# `recordingStore` is how `test_the_client_carries_no_identity` is checked
# without trusting a comment: it wraps any store and keeps every path asked
# for, so a full navigation plus a trace open can be inspected afterwards.
# It lives in the package rather than in the test because a consumer
# embedding this SDK has the same question about their own build.
# ---------------------------------------------------------------------------

type
  RequestLog* = ref object
    ## Every path a wrapped store was asked for, in order.
    paths*: seq[string]

proc newRequestLog*(): RequestLog = RequestLog(paths: @[])

proc count*(log: RequestLog, path: string): int =
  for p in log.paths:
    if p == path: inc result

proc recordingStore*(inner: ObjectStore, log: RequestLog): ObjectStore =
  ## `inner`, with every request appended to `log`.
  newObjectStore("recording:" & inner.name, proc(path: string): ObjectResponse =
    log.paths.add path
    inner.get(path))
