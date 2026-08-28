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

import std/[json, os, strutils]

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

proc getJson*(store: ObjectStore, path: string): JsonResponse =
  let r = store.get(path)
  if not r.found: return JsonResponse(found: false)
  try:
    JsonResponse(found: true, node: parseJson(r.body))
  except CatchableError as e:
    JsonResponse(found: true, error: path & ": " & e.msg)

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
