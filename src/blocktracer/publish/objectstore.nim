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
##
## ── THE BULK RANKS, AND WHY THEY ARE A SEPARATE PAIR OF METHODS ────────────
##
## Everything above is per-object, and for the three primitives the storage model
## rests on — the `putIfAbsent` lease, the input-addressed byte compare, and the
## `current.json` flip — per-object is the point, not an accident. For the bulk
## content it is neither: `d/{chain}/block/**`, `d/{chain}/tx/**` and the
## `t/**` containers are immutable at their keys, so the ONLY questions the
## publisher asks of the store about them are "which of these keys exist" and
## "please hold these bytes at these keys". Both were being answered one `aws`
## process at a time.
##
## Measured on this machine against a local MinIO (2026-09-09): a publish of the
## 1693-object testnet tree spent its entire wall clock in process spawn and
## connection setup — the whole tree is 831,705 bytes, an average of 491 bytes an
## object, so there is no bandwidth in the number at all.
##
## `listMeta` and `putMany` are the two bulk answers:
##
##   * `listMeta` replaces N `head-object` round trips with one paginated
##     `list-objects-v2`. It is not merely faster, it is MORE consistent: N HEADs
##     interleaved with N PUTs see N different moments of the store, while one
##     listing is a single point in time — and the publisher takes it under the
##     lease, so no other writer can move the store underneath it.
##
##   * `putMany` stages hardlinks to the source files in a temp directory
##     mirroring the key layout and hands the directory to `aws s3 cp
##     --recursive`. `cp --recursive` and NOT `s3 sync` deliberately: sync brings
##     its own size/mtime comparison, which is not the input-addressed compare
##     the publisher just performed, and layering the two would mean neither is
##     the one that decides. The staging directory contains exactly the objects
##     the publisher decided to write, and `cp --recursive` writes all of them
##     unconditionally.
##
## Both default to the per-object loop on the base type, so `LocalObjectStore` —
## whose per-object path is a `write` syscall and already fast — is unchanged,
## and any future backend is correct before it is quick.
##
## THE BODIES ARE REAL FILES. `putIfAbsent`'s header below records what happened
## the last time a body on this path was not seekable; the staging directory
## keeps `putMany` on the same right side of that.

import std/[os, osproc, strutils, posix, times, streams, hashes, tables]

type
  StoredMeta* = object
    ## What a listing knows about an object without fetching it.
    etag*: string      ## ETag, quotes stripped. "" when the store did not say.
    size*: int64
    md5Known*: bool    ## the ETag is a plain single-part MD5, so it may be
                       ## compared against `getMD5` of local bytes. False for a
                       ## multipart ETag (`<hex>-<parts>`), which is an MD5 of
                       ## MD5s and means nothing to a whole-object compare.

  BulkItem* = object
    ## One object to upload, by the path that already holds its exact bytes —
    ## the publisher reads its tree from disk, so there is nothing to copy.
    key*: string
    srcPath*: string

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

method listMeta*(s: ObjectStore, prefix: string): Table[string, StoredMeta] {.base.} =
  ## One shot: every key under `prefix` with whatever the store can say about it
  ## cheaply. The default is `list` with nothing known, which keeps every caller
  ## correct on a backend that has not specialised it — a store that reports no
  ## ETags simply never takes the hash fast path.
  result = initTable[string, StoredMeta]()
  for k in s.list(prefix):
    result[k] = StoredMeta(etag: "", size: -1, md5Known: false)

method putMany*(s: ObjectStore, items: seq[BulkItem]) {.base.} =
  ## Write every item. MUST be all-or-raise: a caller that gets a return has the
  ## right to treat every key as present, because the next thing it does is flip
  ## a pointer that references them.
  for it in items:
    s.put(it.key, readFile(it.srcPath))

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

proc isPreconditionFailure*(outp: string): bool =
  ## Did an `--if-none-match '*'` PUT fail because ANOTHER WRITER ALREADY HOLDS THE
  ## KEY — as opposed to failing for any of the reasons that are real errors?
  ##
  ## `putIfAbsent` is the only compare-and-set in the system and the whole lease
  ## rests on this answer. A false positive reports an empty bucket, a bad
  ## credential or a rejected argument list as contention, and the publisher then
  ## WAITS for a lease nobody holds; a false negative raises on a legitimate CAS
  ## loss and fails a publish that should simply have yielded.
  ##
  ## ## Why it is anchored and not a substring
  ##
  ## This was `"PreconditionFailed" in outp or "412" in outp`, over a string that is
  ## MERGED stdout+stderr (`run` sets `poStdErrToStdOut`) and therefore carries the
  ## CLI's whole diagnostic, including the `RequestId` / `HostId` pair S3 prints for
  ## every failure. Those are hex, and `412` appears in an arbitrary hex identifier
  ## often enough to be an operational certainty rather than a curiosity — so a
  ## credential or bucket error became "another writer won the race", which is the
  ## exact misdiagnosis this function's own header records having removed once
  ## already for `/dev/stdin`.
  ##
  ## The two spellings matched are the CLI's own:
  ##
  ##   AWS CLI v2   `An error occurred (PreconditionFailed) when calling the
  ##                PutObject operation: At least one of the pre-conditions …`
  ##   status-only  `… HTTP 412 …`, which some S3-compatible stores report instead
  ##
  ## Neither can be produced by a hex identifier, and both are the error CODE
  ## rather than a word that also appears in prose about preconditions.
  "(PreconditionFailed)" in outp or "HTTP 412" in outp

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
  # ── AND THE DISCRIMINATOR MUST NOT BE A BARE SUBSTRING ─────────────────────
  #
  # This read `"PreconditionFailed" in outp or "412" in outp`, and the second half
  # reintroduced the very misdiagnosis the paragraph above removes. `run` sets
  # `poStdErrToStdOut`, so `outp` is merged stdout+stderr — which on a failure is
  # the AWS CLI's whole diagnostic, including the request identifiers it prints for
  # a support ticket. Any `RequestId` or `HostId` containing the three characters
  # `412` — a 1-in-~250 accident per identifier, on a string this store emits for
  # every failure — turns "your credentials are wrong" or "that bucket does not
  # exist" into "another writer won the CAS race", which is the single false signal
  # this function was rewritten to stop producing. A lease that is reported as held
  # is waited for, so the operator sees a hang rather than the error.
  #
  # The CLI's own shapes are matched instead. AWS CLI v2 prints the error code
  # parenthesised — `An error occurred (PreconditionFailed) when calling the
  # PutObject operation: …` — and an S3-compatible store that reports the status
  # numerically writes `HTTP 412`. Both are anchored spellings that cannot be
  # produced by a hex identifier.
  #
  # IT IS A NAMED PROC so it can be driven from `tests/tpublish.nim`. The S3 backend
  # itself is unreachable from the credential-free suite — that is what let the
  # `/dev/stdin` defect live — and this rule is the half of it that is pure. A
  # discriminator only reachable through a network call is a discriminator with no
  # test, which is how the substring got here.
  if isPreconditionFailure(outp):
    return false                # another writer created it first — a real CAS loss
  raise newException(CatchableError,
    "aws s3api put-object --if-none-match failed for " & key &
    " (exit " & $code & "): " & outp.strip())

method del*(s: S3ObjectStore, key: string) =
  discard s.run(@["s3api", "delete-object", "--bucket", s.bucket,
    "--key", s.fullKey(key)] & s.endpointArgs())

proc stripPrefix(s: S3ObjectStore, t: string): string =
  if s.prefix.len > 0 and t.startsWith(s.prefix.strip(chars = {'/'}) & "/"):
    t[(s.prefix.strip(chars = {'/'}).len + 1) .. ^1]
  else:
    t

method list*(s: S3ObjectStore, prefix: string): seq[string] =
  let (outp, code) = s.run(@["s3api", "list-objects-v2", "--bucket", s.bucket,
    "--prefix", s.fullKey(prefix), "--query", "Contents[].Key",
    "--output", "text"] & s.endpointArgs())
  if code != 0: return
  for tok in outp.split({' ', '\t', '\n'}):
    let t = tok.strip()
    if t.len == 0 or t == "None": continue
    result.add s.stripPrefix(t)

method listMeta*(s: S3ObjectStore, prefix: string): Table[string, StoredMeta] =
  ## ONE `list-objects-v2` in place of one `head-object` per key.
  ##
  ## The CLI paginates this call itself and merges the pages before applying
  ## `--query`, so the result is the whole prefix however many thousand keys it
  ## holds, in a single process with a single TLS handshake. `--output text`
  ## emits one tab-separated row per object; S3 keys may not contain a tab or a
  ## newline, so the split is unambiguous.
  ##
  ## An ETag is trusted as an MD5 only when it has no `-<parts>` suffix. A
  ## multipart ETag is an MD5 of the part MD5s and comparing it to the MD5 of the
  ## whole object would report every large object as changed — safe (it can only
  ## over-report a difference, never claim a false match) but pointlessly slow,
  ## so it is marked unknown and the caller falls back to reading the bytes.
  result = initTable[string, StoredMeta]()
  let (outp, code) = s.run(@["s3api", "list-objects-v2", "--bucket", s.bucket,
    "--prefix", s.fullKey(prefix), "--query", "Contents[].[Key,ETag,Size]",
    "--output", "text"] & s.endpointArgs())
  if code != 0: return
  for line in outp.splitLines():
    let ln = line.strip()
    if ln.len == 0 or ln == "None": continue
    let f = ln.split('\t')
    if f.len < 3: continue
    let etag = f[1].strip().strip(chars = {'"'})
    var size: int64 = -1
    try: size = parseBiggestInt(f[2].strip()) except CatchableError: discard
    result[s.stripPrefix(f[0].strip())] =
      StoredMeta(etag: etag, size: size,
                 md5Known: etag.len == 32 and '-' notin etag)

method putMany*(s: S3ObjectStore, items: seq[BulkItem]) =
  ## Stage hardlinks into a directory shaped like the key space, then one
  ## `aws s3 cp --recursive`.
  ##
  ## HARDLINKS, so staging N objects costs N directory entries and copies no
  ## bytes; a cross-device link (the tree and $TMPDIR on different filesystems)
  ## falls back to a copy rather than failing. The staged files are ordinary
  ## seekable files — the hazard `putIfAbsent` documents above cannot recur here.
  ##
  ## `cp --recursive`, NOT `s3 sync`. Sync would re-decide what to transfer using
  ## size and modification time, which is not the comparison the publisher just
  ## made: an object whose bytes changed without changing length, staged fresh
  ## with a new mtime, is a coin flip under sync's rules and a certainty under
  ## cp's. The publisher owns the decision; this method owns only the transfer.
  ##
  ## A NON-ZERO EXIT RAISES. `publishChain` flushes at every rank boundary and
  ## flips `current.json` only after the last flush returns, so a failed batch
  ## propagates out before the pointer can advertise content that is not there.
  if items.len == 0: return
  let stage = getTempDir() / "bt-bulk-" & $getpid() & "-" & $epochTime().int64 & "-" &
              $(cast[uint](items[0].key.hash) mod 1_000_000'u)
  createDir stage
  defer: removeDir stage
  for it in items:
    let dst = stage / it.key
    createDir parentDir(dst)
    try:
      createHardlink(it.srcPath, dst)
    except CatchableError:
      copyFile(it.srcPath, dst)
  let dest = "s3://" & s.bucket & "/" &
    (if s.prefix.len > 0: s.prefix.strip(chars = {'/'}) & "/" else: "")
  let (outp, code) = s.run(@["s3", "cp", stage, dest, "--recursive",
    "--only-show-errors"] & s.endpointArgs())
  if code != 0:
    raise newException(CatchableError,
      "aws s3 cp --recursive failed for " & $items.len & " object(s) (exit " &
      $code & "): " & outp.strip())
