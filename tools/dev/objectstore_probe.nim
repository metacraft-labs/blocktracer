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

import std/[os, strutils]
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
  store.del(lease)

  echo "failures: ", failures
  quit(if failures == 0: 0 else: 1)

main()
