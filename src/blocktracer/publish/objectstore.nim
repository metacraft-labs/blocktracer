## The object-store backend abstraction for the M8 publisher.
##
## The publisher never touches a filesystem or an S3 client directly; it speaks to
## an `ObjectStore` whose entire surface is key/value with one atomic primitive.
## Two backends implement it:
##
##   * `LocalObjectStore` — a directory on disk. Used by the publisher's tests and
##     by `blocktracer-publish --backend local` for a local `dist/` preview. Its
##     `putIfAbsent` is a genuine `O_EXCL` create, so the per-chain single-writer
##     lease is real, not advisory.
##   * `S3ObjectStore` — a thin wrapper over the `aws` CLI, targeting Cloudflare R2
##     (`--endpoint-url`) or any S3-compatible store. It is the real target for
##     blocktracer.org and is intentionally not exercised in the credential-free
##     test suite; every method is a single `aws` invocation.
##
## The contract each backend upholds:
##   - `exists` / `get` / `put` / `del` are ordinary key operations;
##   - `putIfAbsent` creates the key *iff* it does not already exist, atomically,
##     returning whether this caller won — the lease depends on this being a real
##     compare-and-set, which is why R2's `If-None-Match: *` is used rather than a
##     read-then-write;
##   - `list` enumerates keys under a prefix (used to reconstruct state and to scan).

import std/[os, osproc, strutils, posix, times, streams, hashes]

type
  ObjectStore* = ref object of RootObj

# --- the interface --------------------------------------------------------

method exists*(s: ObjectStore, key: string): bool {.base.} =
  raise newException(CatchableError, "ObjectStore.exists not implemented")

method get*(s: ObjectStore, key: string): tuple[data: string, ok: bool] {.base.} =
  raise newException(CatchableError, "ObjectStore.get not implemented")

method put*(s: ObjectStore, key, data: string) {.base.} =
  raise newException(CatchableError, "ObjectStore.put not implemented")

method putIfAbsent*(s: ObjectStore, key, data: string): bool {.base.} =
  ## Create `key` with `data` only if it does not exist. Returns true iff this
  ## caller created it. MUST be atomic — the single-writer lease relies on it.
  raise newException(CatchableError, "ObjectStore.putIfAbsent not implemented")

method del*(s: ObjectStore, key: string) {.base.} =
  raise newException(CatchableError, "ObjectStore.del not implemented")

method list*(s: ObjectStore, prefix: string): seq[string] {.base.} =
  raise newException(CatchableError, "ObjectStore.list not implemented")

# --- local filesystem backend --------------------------------------------

type
  LocalObjectStore* = ref object of ObjectStore
    root*: string   ## directory the keys are stored under

proc newLocalObjectStore*(root: string): LocalObjectStore =
  createDir root
  LocalObjectStore(root: root)

proc pathOf(s: LocalObjectStore, key: string): string = s.root / key

method exists*(s: LocalObjectStore, key: string): bool =
  fileExists(s.pathOf(key))

method get*(s: LocalObjectStore, key: string): tuple[data: string, ok: bool] =
  let p = s.pathOf(key)
  if not fileExists(p): return ("", false)
  (readFile(p), true)

method put*(s: LocalObjectStore, key, data: string) =
  ## Atomic replace: write a sibling temp then rename over the target, so a reader
  ## never sees a half-written object (matters most for the `current.json` flip).
  let p = s.pathOf(key)
  createDir parentDir(p)
  let tmp = p & ".tmp." & $getpid() & "." & $epochTime().int64
  writeFile(tmp, data)
  moveFile(tmp, p)

method putIfAbsent*(s: LocalObjectStore, key, data: string): bool =
  ## Genuine atomic create via `O_CREAT | O_EXCL`; loses the race → false.
  let p = s.pathOf(key)
  createDir parentDir(p)
  let fd = posix.open(p.cstring, O_CREAT or O_EXCL or O_WRONLY, 0o644)
  if fd < 0:
    return false            # EEXIST (or a real error; treated as "not ours")
  if data.len > 0:
    discard posix.write(fd, data.cstring, data.len)
  discard posix.close(fd)
  true

method del*(s: LocalObjectStore, key: string) =
  let p = s.pathOf(key)
  if fileExists(p): removeFile(p)

method list*(s: LocalObjectStore, prefix: string): seq[string] =
  let base = s.root
  for p in walkDirRec(base):
    let rel = p.relativePath(base)
    if rel.startsWith(prefix): result.add rel

# --- S3 / R2 backend (thin `aws` CLI wrapper) ----------------------------

type
  S3ObjectStore* = ref object of ObjectStore
    bucket*: string
    prefix*: string        ## optional key prefix inside the bucket
    endpoint*: string      ## R2: https://<account>.r2.cloudflarestorage.com ; "" => AWS
    awsBin*: string        ## defaults to "aws"

proc newS3ObjectStore*(bucket: string, prefix = "", endpoint = "",
                       awsBin = "aws"): S3ObjectStore =
  S3ObjectStore(bucket: bucket, prefix: prefix, endpoint: endpoint, awsBin: awsBin)

proc fullKey(s: S3ObjectStore, key: string): string =
  if s.prefix.len > 0: s.prefix.strip(chars = {'/'}) & "/" & key else: key

proc endpointArgs(s: S3ObjectStore): seq[string] =
  if s.endpoint.len > 0: @["--endpoint-url", s.endpoint] else: @[]

proc run(s: S3ObjectStore, args: seq[string], input = ""):
    tuple[output: string, code: int] =
  ## Run `aws <args>` capturing stdout; feed `input` on stdin when given.
  let p = startProcess(s.awsBin, args = args,
                       options = {poUsePath, poStdErrToStdOut})
  if input.len > 0:
    p.inputStream.write(input)
  p.inputStream.close()
  let outp = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (outp, code)

proc runBytes(s: S3ObjectStore, args: seq[string]):
    tuple[output: string, code: int] =
  ## `run`, but stdout is the OBJECT'S BYTES and stderr is kept out of them.
  ##
  ## `run` sets `poStdErrToStdOut` so a failing call's diagnostic lands in the
  ## string a caller can put in an exception. That is right for `put` and
  ## `head-object`, whose stdout nobody keeps, and wrong for `get`, whose stdout
  ## IS the object: any line the CLI writes to stderr on a successful transfer
  ## would be spliced into the middle of a `trace.ct`. The publisher re-reads
  ## exactly those objects to compare them against a manifest's
  ## `container.hash`, so a splice is not a download bug — it is a determinism
  ## incident against a container that is in fact byte-identical, and the
  ## publisher's response to one is to refuse the write.
  let p = startProcess(s.awsBin, args = args, options = {poUsePath})
  p.inputStream.close()
  let outp = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (outp, code)

method exists*(s: S3ObjectStore, key: string): bool =
  let (_, code) = s.run(@["s3api", "head-object", "--bucket", s.bucket,
    "--key", s.fullKey(key)] & s.endpointArgs())
  code == 0

method get*(s: S3ObjectStore, key: string): tuple[data: string, ok: bool] =
  let (outp, code) = s.runBytes(@["s3", "cp",
    "s3://" & s.bucket & "/" & s.fullKey(key), "-"] & s.endpointArgs())
  if code != 0: return ("", false)
  (outp, true)

method put*(s: S3ObjectStore, key, data: string) =
  let (outp, code) = s.run(@["s3", "cp", "-",
    "s3://" & s.bucket & "/" & s.fullKey(key)] & s.endpointArgs(), input = data)
  if code != 0:
    raise newException(CatchableError, "aws s3 cp failed for " & key & ": " & outp)

method putIfAbsent*(s: S3ObjectStore, key, data: string): bool =
  ## R2/S3 conditional create: `put-object --if-none-match '*'` succeeds only when
  ## the key is absent, returning 412 (PreconditionFailed) otherwise — a real
  ## compare-and-set, so the lease is safe across machines.
  ##
  ## ── THE BODY IS A TEMP FILE AND NOT `/dev/stdin`, AND THAT IS THE WHOLE ────
  ##
  ## This used to pipe `data` into `aws s3api put-object --body /dev/stdin`. It
  ## could never succeed. `--body` is a *blob* parameter, and botocore resolves a
  ## blob by opening the path and SEEKING it to size the payload; `/dev/stdin`
  ## attached to a pipe is not seekable, so the CLI fails during argument
  ## parsing — before a request is made — with
  ##
  ##     Error parsing parameter '--body': Blob values must be a path to a file.
  ##
  ## and exits 255. `code == 0` was then false for every call, on every store, in
  ## every state. Measured against a local MinIO on 2026-09-09: an EMPTY bucket,
  ## a fresh key, and `putIfAbsent` returned false — which `publisher.nim` turns
  ## into `chain 'aztec-testnet' is locked by another publisher (lease held)`.
  ## That is the first thing anyone pointing this backend at R2 would have seen,
  ## and the message names the one cause that was not true.
  ##
  ## It was invisible because it is unreachable from the test suite:
  ## `tests/tpublish.nim` drives `LocalObjectStore` only, whose `putIfAbsent` is
  ## a genuine `O_EXCL` and works. The S3 backend's own header says it "is
  ## intentionally not exercised in the credential-free test suite" — true, and
  ## it meant the only conditional-create in the system had never run.
  ##
  ## A 412 IS NOT AN ERROR AND EVERY OTHER FAILURE IS. Collapsing both into
  ## `false` is how a broken client came to read as a contended lease, so the two
  ## are separated here: PreconditionFailed means another writer holds it, and
  ## anything else — a bad credential, a missing bucket, a CLI that rejects the
  ## arguments — raises with the CLI's own words rather than being reported as
  ## contention.
  let tmp = getTempDir() / "bt-put-" & $getpid() & "-" & $epochTime().int64 & "-" &
            $(cast[uint](key.hash) mod 1_000_000'u)
  writeFile(tmp, data)
  defer: removeFile(tmp)
  let (outp, code) = s.run(@["s3api", "put-object", "--bucket", s.bucket,
    "--key", s.fullKey(key), "--if-none-match", "*",
    "--body", tmp] & s.endpointArgs())
  if code == 0: return true
  if "PreconditionFailed" in outp or "412" in outp:
    return false                # another writer created it first — a real CAS loss
  raise newException(CatchableError,
    "aws s3api put-object --if-none-match failed for " & key &
    " (exit " & $code & "): " & outp.strip())

method del*(s: S3ObjectStore, key: string) =
  discard s.run(@["s3api", "delete-object", "--bucket", s.bucket,
    "--key", s.fullKey(key)] & s.endpointArgs())

method list*(s: S3ObjectStore, prefix: string): seq[string] =
  let (outp, code) = s.run(@["s3api", "list-objects-v2", "--bucket", s.bucket,
    "--prefix", s.fullKey(prefix), "--query", "Contents[].Key",
    "--output", "text"] & s.endpointArgs())
  if code != 0: return
  for tok in outp.split({' ', '\t', '\n'}):
    let t = tok.strip()
    if t.len == 0 or t == "None": continue
    if s.prefix.len > 0 and t.startsWith(s.prefix.strip(chars = {'/'}) & "/"):
      result.add t[(s.prefix.strip(chars = {'/'}).len + 1) .. ^1]
    else:
      result.add t
