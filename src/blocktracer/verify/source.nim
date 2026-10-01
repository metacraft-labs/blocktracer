## verify/source.nim — a **read-only** handle on a published instance.
##
## The publisher speaks to an `ObjectStore`, whose surface is deliberately
## read-write: `put`, `del`, `putIfAbsent`, `putMany`. The verifier must never
## reach any of them. It runs against **production**, repeatedly, on an
## operator's say-so and eventually on a schedule, and the one property that
## makes that safe is not care — it is that the code has nothing to write with.
##
## So this is a SEPARATE TYPE and not a flag on the other one. A `Source`
## exposes three operations and no fourth exists:
##
##   * `fetch(key)`   — the bytes, the status, and the response headers;
##   * `canList`      — whether this backend can enumerate keys at all;
##   * `listSizes(p)` — key → size for a prefix, when it can.
##
## `S3Source` does hold an `S3ObjectStore` privately, because re-implementing
## the `aws` plumbing would be a second copy of the one thing in this repository
## that has already shipped a defect nobody could see (`putIfAbsent` and
## `/dev/stdin`). It calls exactly two of its methods, both read-only, and the
## boundary is held by `ci/test/verify-published-readonly.sh`, which refuses any
## write-method name anywhere under `src/blocktracer/verify/` or in the CLI. A
## lexical gate is what this repository already uses for the Client SDK's
## boundary, for the same reason: a rule that depends on someone remembering it
## is not a boundary.
##
## ## Three backends, because "the published instance" is three things
##
##   * `LocalSource`  — a directory. What the test suite drives, and what an
##     operator uses on a store written by `blocktracer-publish --backend local`.
##   * `S3Source`     — R2 or any S3-compatible endpoint. Can list, so the
##     census check is available.
##   * `HttpSource`   — the CDN, which is the only backend that can answer the
##     question the cache check asks, and the only one that CANNOT list.
##
## ## Why `HttpSource` shells out to `curl`
##
## `std/httpclient` over TLS needs `-d:ssl` and a dynamically-resolved libssl,
## which is exactly the kind of build-environment dependency that makes a tool
## work on the machine that wrote it. `curl` is present everywhere this runs,
## handles TLS, redirects and HTTP/2, and prints response headers in a shape
## that is trivially parsed. The publisher's own backend shells out to `aws` for
## the same reason, so this is the established seam and not a new one.
##
## A REDIRECT IS FOLLOWED AND RECORDED. `-L` is passed and only the FINAL
## response's headers are kept, because a CDN that 301s `/x` to `/x/` and then
## serves it has served it. `finalUrl` carries where the bytes actually came
## from, so a host that redirects every miss to the home page is visible as a
## redirect rather than as a mysterious 200 — and `INSTRUMENT` checks exactly
## that before any other check is allowed to mean anything.

import std/[os, osproc, strutils, tables, streams, hashes]

import ../publish/objectstore

type
  Fetched* = object
    ## One response. `present` is NOT `status == 200`: a local directory has no
    ## status at all, and an S3 `get` reports success or failure rather than a
    ## code. `status` is 0 where the backend has none.
    present*: bool
    status*: int
    body*: string
    headers*: Table[string, string]   ## lower-cased names; "" on non-HTTP
    finalUrl*: string                 ## where the bytes came from, after redirects
    error*: string                    ## non-empty when the backend itself failed

  Source* = ref object of RootObj
    ## A read-only handle. There is no `put` on this type or any subtype, and
    ## `ci/test/verify-published-readonly.sh` refuses one being added.

method describe*(s: Source): string {.base.} = "unknown source"

method fetch*(s: Source, key: string): Fetched {.base.} =
  raise newException(CatchableError, "Source.fetch not implemented")

method canList*(s: Source): bool {.base.} = false

method listSizes*(s: Source, prefix: string): Table[string, int64] {.base.} =
  ## key → size, for every key under `prefix`. Only meaningful when `canList`.
  raise newException(CatchableError, "Source.listSizes not implemented")

method supportsHeaders*(s: Source): bool {.base.} = false
  ## Whether `fetch` populates `headers`. Only HTTP does, and the cache check
  ## reports itself UNRUNNABLE rather than passing on a backend that does not —
  ## a header contract is a property of the CDN, and a directory has no CDN.

# ---------------------------------------------------------------------------
# Local directory
# ---------------------------------------------------------------------------

type
  LocalSource* = ref object of Source
    root*: string

proc newLocalSource*(root: string): LocalSource = LocalSource(root: root)

method describe*(s: LocalSource): string = "local directory " & s.root

method fetch*(s: LocalSource, key: string): Fetched =
  let p = s.root / key
  if not fileExists(p):
    return Fetched(present: false, status: 0, finalUrl: p)
  Fetched(present: true, status: 0, body: readFile(p), finalUrl: p)

method canList*(s: LocalSource): bool = true

method listSizes*(s: LocalSource, prefix: string): Table[string, int64] =
  result = initTable[string, int64]()
  if not dirExists(s.root): return
  for p in walkDirRec(s.root):
    let rel = p.relativePath(s.root).replace('\\', '/')
    if rel.startsWith(prefix): result[rel] = getFileSize(p)

# ---------------------------------------------------------------------------
# S3 / R2
# ---------------------------------------------------------------------------

type
  S3Source* = ref object of Source
    store: S3ObjectStore        ## PRIVATE. Only `get` and `listMeta` are called.
    label: string

proc newS3Source*(bucket, prefix, endpoint: string): S3Source =
  S3Source(store: newS3ObjectStore(bucket, prefix = prefix, endpoint = endpoint),
           label: "s3://" & bucket & "/" & prefix &
                  (if endpoint.len > 0: " @ " & endpoint else: ""))

method describe*(s: S3Source): string = s.label

method fetch*(s: S3Source, key: string): Fetched =
  let (data, ok) = s.store.get(key)
  if not ok: return Fetched(present: false, status: 0, finalUrl: key)
  Fetched(present: true, status: 0, body: data, finalUrl: key)

method canList*(s: S3Source): bool = true

method listSizes*(s: S3Source, prefix: string): Table[string, int64] =
  result = initTable[string, int64]()
  for k, m in s.store.listMeta(prefix):
    result[k] = m.size

# ---------------------------------------------------------------------------
# HTTP / CDN
# ---------------------------------------------------------------------------

type
  HttpSource* = ref object of Source
    base*: string          ## e.g. https://blocktracer.org  (no trailing slash)
    curlBin*: string
    timeoutSecs*: int

proc newHttpSource*(base: string, curlBin = "curl", timeoutSecs = 30): HttpSource =
  ## REFUSES AT CONSTRUCTION IF `curl` IS NOT THERE, rather than turning every
  ## fetch into an error. Without this, a missing `curl` reports as "the control
  ## key is absent, the registry is absent, every object is absent" — which is
  ## indistinguishable in the output from an empty bucket, and is the single
  ## most misleading thing this tool could say.
  if findExe(curlBin).len == 0:
    raise newException(OSError,
      "the HTTP backend needs `" & curlBin & "` on PATH and cannot find it. " &
      "Every fetch would fail and the report would read as an empty tree. " &
      "(verify/source.nim's header says why the transport is curl and not " &
      "`std/httpclient`.)")
  HttpSource(base: base.strip(trailing = true, chars = {'/'}),
             curlBin: curlBin, timeoutSecs: timeoutSecs)

method describe*(s: HttpSource): string = s.base

method supportsHeaders*(s: HttpSource): bool = true

proc runCurl(s: HttpSource, args: seq[string]): tuple[output: string, code: int] =
  let p = startProcess(s.curlBin, args = args, options = {poUsePath})
  p.inputStream.close()
  let outp = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (outp, code)

proc parseHeaders*(raw: string): Fetched =
  ## EXPORTED FOR `tests/tverifypublished.nim`. The redirect-chain rule below is
  ## the one piece of this backend that can be got wrong on a real CDN and never
  ## noticed on a local one, so it is driven directly by the suite over canned
  ## responses rather than only through a live fetch.
  ## `curl -sS -L -D -` prints one header block per response in the redirect
  ## chain. Only the LAST block is the response that served the bytes, which is
  ## the one every check is about — so the scan finds the last `HTTP/` status
  ## line rather than the first, which would stop at the first hop.
  result.headers = initTable[string, string]()
  var lastStatusAt = -1
  let lines = raw.splitLines()
  for i, ln in lines:
    if ln.startsWith("HTTP/"): lastStatusAt = i
  if lastStatusAt < 0:
    return Fetched(present: false, status: 0,
                   headers: initTable[string, string](),
                   error: "no HTTP status line in response")
  let statusLine = lines[lastStatusAt].splitWhitespace()
  if statusLine.len >= 2:
    try: result.status = parseInt(statusLine[1]) except CatchableError: discard
  var idx = lastStatusAt + 1
  while idx < lines.len and lines[idx].strip().len > 0:
    let c = lines[idx].find(':')
    if c > 0:
      result.headers[lines[idx][0 ..< c].strip().toLowerAscii] =
        lines[idx][c + 1 .. ^1].strip()
    inc idx
  result.present = result.status >= 200 and result.status < 300

method fetch*(s: HttpSource, key: string): Fetched =
  ## THE BODY GOES TO A FILE AND NOT THROUGH STDOUT WITH THE HEADERS.
  ##
  ## Splitting one stream into "headers, blank line, body" means reconstructing
  ## the body from split lines, and rejoining them loses the distinction between
  ## `\n` and `\r\n` and mangles any byte that is not text. The verifier's whole
  ## claim is **identity** — a sha256 of what the store served, compared against
  ## a sha256 of what the producer wrote — so a transport that can alter one byte
  ## is a transport that can turn a correct object into a finding. `-o` writes
  ## the bytes; `-D -` prints the headers; nothing has to be unspliced.
  let url = s.base & "/" & key
  let tmp = getTempDir() / "bt-verify-" & $getCurrentProcessId() & "-" &
            $(cast[uint](key.hash) mod 1_000_000'u)
  defer: (if fileExists(tmp): removeFile(tmp))
  let (outp, code) = s.runCurl(@["-sS", "-L", "-D", "-", "-o", tmp,
                                 "--max-time", $s.timeoutSecs, url])
  if code != 0:
    return Fetched(present: false, status: 0, finalUrl: url,
                   headers: initTable[string, string](),
                   error: "curl exit " & $code & ": " & outp.strip())
  result = parseHeaders(outp)
  result.finalUrl = url
  if result.present and fileExists(tmp):
    result.body = readFile(tmp)
