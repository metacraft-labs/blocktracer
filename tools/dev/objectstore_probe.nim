## Drive every `ObjectStore` method against a REAL S3-compatible endpoint and
## print what each one did.
##
## WHY THIS EXISTS. `objectstore.nim`'s own header says the S3 backend "is
## intentionally not exercised in the credential-free test suite". That sentence
## is true and it was also the whole of the evidence: the publisher's `tpublish`
## suite drives `LocalObjectStore` only, so every S3 method shipped with no
## execution behind it at all. The first time one was run — against a local
## MinIO, no credential, no bucket in anyone's account — `putIfAbsent` returned
## false on an EMPTY bucket and the publisher reported the chain "locked by
## another publisher".
##
## A local endpoint is enough to find that class of defect and is the only kind
## an agent may point at: the shapes being checked (does the CLI accept this
## argument, does a conditional create return 412 the second time, do the bytes
## come back byte-identical) are properties of the client and of the S3 protocol,
## not of Cloudflare.
##
## Usage: objectstore_probe <bucket> <endpoint> [prefix]

import std/[os, strutils, md5, tables, algorithm]
import blocktracer/publish/objectstore

proc main =
  if paramCount() < 2:
    quit "usage: objectstore_probe <bucket> <endpoint> [prefix]"
  let store = newS3ObjectStore(paramStr(1), prefix = (if paramCount() >= 3: paramStr(3) else: ""),
                               endpoint = paramStr(2))
  let k = "probe/obj-a"
  let lease = "probe/lease.lock"
  var failures = 0
  proc check(name: string, got, want: string) =
    let ok = got == want
    if not ok: inc failures
    echo (if ok: "  ok   " else: "  FAIL "), name, "  got=", got, " want=", want

  # A payload with a NUL and a high byte in it: the container objects this store
  # carries are `.ct` binaries, and a backend that only round-trips text would
  # pass a JSON-only probe and corrupt every trace.
  let payload = "line one\n\x00\xffbinary\ntrailing"

  store.del(k)
  store.del(lease)

  check("exists(absent)", $store.exists(k), "false")
  store.put(k, payload)
  check("exists(after put)", $store.exists(k), "true")
  let (got, ok) = store.get(k)
  check("get.ok", $ok, "true")
  check("get.len", $got.len, $payload.len)
  check("get.bytes-identical", $(got == payload), "true")

  check("putIfAbsent(fresh) wins", $store.putIfAbsent(lease, "writer-1\n"), "true")
  check("putIfAbsent(taken) loses", $store.putIfAbsent(lease, "writer-2\n"), "false")
  let (leaseData, leaseOk) = store.get(lease)
  check("lease holder unchanged", (if leaseOk: leaseData.strip() else: "<missing>"), "writer-1")

  let listed = store.list("probe/")
  check("list finds both", $(k in listed and lease in listed), "true")

  # A CONTAINER-SIZED BINARY, because the small case cannot see the hazard that
  # matters. `run` sets `poStdErrToStdOut`, so anything the CLI writes to stderr
  # lands INSIDE the bytes `get` returns; on a 26-byte object the CLI is silent
  # and the round-trip looks clean. The published `/t/**/trace.ct` objects in the
  # committed testnet capture total 4.5 MB, and those are the ones the publisher
  # re-reads to compare against a manifest's `container.hash` — so a corrupting
  # byte here is not a download bug, it is a false determinism incident that
  # refuses to republish a correct container.
  let bigK = "probe/obj-big"
  var big = newStringOfCap(5_000_000)
  for i in 0 ..< 5_000_000: big.add chr(i mod 256)
  store.del(bigK)
  store.put(bigK, big)
  let (gotBig, bigOk) = store.get(bigK)
  check("get.big.ok", $bigOk, "true")
  check("get.big.len", $gotBig.len, $big.len)
  check("get.big.bytes-identical", $(gotBig == big), "true")
  store.del(bigK)

  store.del(k)
  check("exists(after del)", $store.exists(k), "false")

  # ── THE BULK RANKS ────────────────────────────────────────────────────────
  #
  # `listMeta` and `putMany` are what a publish cycle spends its wall clock in
  # once the per-object HEAD-and-PUT is gone, and they are exactly as unexercised
  # by the credential-free suite as `putIfAbsent` was. The properties below are
  # the ones the publisher then relies on, each stated as the thing that breaks
  # if it is false:
  #
  #   * listMeta agrees with list  — else present⇒skip decides differently
  #     depending on which call asked, and the two disagreeing is silent.
  #   * the ETag is the MD5        — else `--refresh` compares a digest of the
  #     bytes against something that is not one. This is the assumption the
  #     publisher CALIBRATES at runtime against its own lease; here it is
  #     checked directly, so a store where it is false is a printed line rather
  #     than a slow refresh nobody explains.
  #   * putMany round-trips bytes  — including a NUL and a high byte, because
  #     these are the same objects `.ct` containers travel as.
  #   * putMany raises on failure  — the pointer flip is gated on it returning.
  let bulkA = "probe/bulk/a.json"
  let bulkB = "probe/bulk/deep/b.bin"
  let bodyA = "{\"a\":1}\n"
  let bodyB = "\x00\xff\x01binary\x00tail"
  let tmpDir = getTempDir() / "bt-probe-bulk"
  removeDir tmpDir
  createDir tmpDir / "bulk" / "deep"
  writeFile(tmpDir / "bulk" / "a.json", bodyA)
  writeFile(tmpDir / "bulk" / "deep" / "b.bin", bodyB)
  store.del(bulkA)
  store.del(bulkB)

  # zero items must not spawn anything or fail
  store.putMany(@[])
  check("putMany(empty) is a no-op", $store.exists(bulkA), "false")

  store.putMany(@[BulkItem(key: bulkA, srcPath: tmpDir / "bulk" / "a.json"),
                  BulkItem(key: bulkB, srcPath: tmpDir / "bulk" / "deep" / "b.bin")])
  check("putMany wrote key 1", $store.exists(bulkA), "true")
  check("putMany wrote key 2", $store.exists(bulkB), "true")
  let (gotA, okA) = store.get(bulkA)
  let (gotB, okB) = store.get(bulkB)
  check("putMany.a bytes-identical", $(okA and gotA == bodyA), "true")
  check("putMany.b bytes-identical (NUL + high byte)", $(okB and gotB == bodyB), "true")

  # listMeta vs list: the SAME key set, or present⇒skip is not one decision.
  var viaList = store.list("probe/bulk/")
  let meta = store.listMeta("probe/bulk/")
  var viaMeta: seq[string] = @[]
  for kk in meta.keys: viaMeta.add kk
  viaList.sort(); viaMeta.sort()
  check("listMeta key set == list key set", $(viaList == viaMeta), "true")
  check("listMeta found both", $viaMeta.len, "2")

  # The ETag/MD5 identity the refresh fast path is calibrated on.
  if meta.hasKey(bulkA):
    check("listMeta.etag is md5(body)", $(meta[bulkA].md5Known and
          meta[bulkA].etag == getMD5(bodyA)), "true")
    check("listMeta.size", $meta[bulkA].size, $bodyA.len)
  else:
    check("listMeta has key a", "false", "true")

  # A batch that cannot be transferred must RAISE. Collapsing it into a silent
  # return is how a pointer comes to advertise content that is not in the store.
  var raised = false
  try:
    let bad = newS3ObjectStore("no-such-bucket-probe-" & $getCurrentProcessId(),
                               endpoint = paramStr(2))
    bad.putMany(@[BulkItem(key: "x/y.json", srcPath: tmpDir / "bulk" / "a.json")])
  except CatchableError:
    raised = true
  check("putMany raises on a failed transfer", $raised, "true")

  store.del(bulkA)
  store.del(bulkB)
  removeDir tmpDir
  store.del(lease)

  echo "failures: ", failures
  quit(if failures == 0: 0 else: 1)

main()
