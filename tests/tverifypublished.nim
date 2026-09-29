## `blocktracer-verify-published` — the suite, and the trees it must refuse.
##
## The tool's claim is that it finds a tree that is incomplete or incoherent
## WITHOUT reading it all. A suite that only drove a healthy tree would measure
## the first half of that and none of the second, so every block here is a pair:
## a healthy store the check passes, and **a deliberately broken one it refuses
## by name**. A check that cannot be made to fail is a check that is not
## measuring anything, which is the failure mode this repository has paid for
## more than once.
##
## The breakages are not invented. Each is a defect this system has actually
## produced, or the exact shape of one:
##
##   B1  an object missing from the middle of the range        (a lost delta)
##   B2  `current.json` advertising a head the map does not
##       contain — THE POINTER LIES AND THE DATA IS RIGHT      (twice, by two routes)
##   B3  `historyFloor` disagreeing with the published data    (the same, from the registry)
##   B4  a host that answers 200 for every path                (a Pages SPA fallback)
##   B5  an entire object class never published                (invisible to sampling)
##   B6  a ledger range the published map never received       (a backfill that did not run)
##   B7  a registry missing a chain the expectation names      (2026-09-28's data loss)
##   B8  the right key holding the WRONG block                 (presence is not identity)
##   B9  a cache header that contradicts §2.9                  (a 404 under /t/ that caches)
##
## Nothing here reaches a network except the in-process HTTP fixture on
## 127.0.0.1, and nothing writes outside `$TMPDIR`.

import std/[unittest, os, json, strutils, tables, sequtils, net]

import ../src/blocktracer/verify/[source, audit, cachepolicy]
import ../src/blocktracer/publish/[objectstore, publisher]
import ../src/blocktracer/demo/generator

const fixtureDir = currentSourcePath().parentDir.parentDir / "fixtures" / "trace" / "noir_space_ship"
const fixture = fixtureDir / "zk_shields.ct"
const sourcesDir = fixtureDir / "sources"
const DemoChain = "demo"

proc tmp(name: string): string =
  result = getTempDir() / "bt-verify-test" / name
  removeDir result
  createDir result

# ---------------------------------------------------------------------------
# One healthy tree + store, built once and COPIED per case.
#
# Copied and not shared: every case mutates, and a suite whose cases can see
# each other's mutations reports the order they ran in rather than what each one
# measured.
# ---------------------------------------------------------------------------

let baseTree = tmp("tree")
discard generate(DemoConfig(outDir: baseTree, seed: "verify",
                            traceFixturePath: fixture, traceSourcesDir: sourcesDir))
let baseStore = tmp("store")
block:
  let st = newLocalObjectStore(baseStore)
  discard publishTree(st, baseTree, PublishOptions(chain: "", writer: "suite",
    takeLease: false))

let ledgerPath = tmp("ledger") / "coverage.json"
block:
  # The heights the demo generator actually publishes, as two ranges — so the
  # boundary sampler has real seams to test and the LEDGER check has a served
  # set to compare. Read out of the published map rather than typed, because a
  # ledger typed against a generator that changes is a fixture that silently
  # stops describing the tree.
  let root = parseJson(readFile(baseStore / "d" / DemoChain / "g" / "1" / "root.json"))
  var heights: seq[int]
  for p in root{"maps"}{"height"}:
    let hm = parseJson(readFile(baseStore / p.getStr))
    for k, _ in hm{"heights"}.pairs: heights.add parseInt(k)
  doAssert heights.len > 0, "the fixture tree published no heights"
  var lo = heights[0]
  var hi = heights[0]
  for h in heights:
    if h < lo: lo = h
    if h > hi: hi = h
  var ranges = newJObject()
  ranges[$lo & "-" & $lo] = %*{"from": lo, "to": lo,
    "fetch": {"requested": 1, "served": 1, "notServed": []}}
  var excluded = newJArray()
  var served = 0
  for h in (lo + 1) .. hi:
    if h in heights: inc served else: excluded.add %h
  ranges[$(lo + 1) & "-" & $hi] = %*{"from": lo + 1, "to": hi,
    "fetch": {"requested": hi - lo, "served": served, "notServed": excluded}}
  createDir ledgerPath.parentDir
  writeFile(ledgerPath, $(%*{"format": "blocktracer/range-ledger@1",
                             "chain": DemoChain, "ranges": ranges}))

proc copyStore(name: string): string =
  result = tmp(name)
  copyDir(baseStore, result)

proc opts(tree = baseTree, ledger = ledgerPath, samples = 50): AuditOptions =
  result = defaultAuditOptions()
  result.treeDir = tree
  result.ledgerPath = ledger
  result.samples = samples
  result.allowUnrunnable = @[CheckCache]

proc stateOf(rep: AuditReport, id: string): CheckState =
  for c in rep.checks:
    if c.id == id: return c.state
  raise newException(ValueError, "no check '" & id & "' in the report")

proc findingsOf(rep: AuditReport, id: string): string =
  for c in rep.checks:
    if c.id == id: return c.findings.join(" | ")
  ""

proc auditDir(dir: string, o: AuditOptions): AuditReport =
  runAudit(newLocalSource(dir), o)

# ---------------------------------------------------------------------------

suite "the healthy tree":
  test "every check that can run, passes":
    let rep = auditDir(baseStore, opts())
    for c in rep.checks:
      if c.id == CheckCache:
        check c.state == csUnrunnable      # no CDN behind a directory
      else:
        check c.state == csPass
    check exitCodeFor(rep, opts()) == 0

  test "MUTATION BITE — an unrunnable check that was NOT allowed fails the run":
    # The property under test is that `exitCodeFor` refuses an unanswered
    # question. Without this, "all checks passed" could be printed by a run that
    # asked three of eight.
    var o = opts()
    o.allowUnrunnable = @[]
    check exitCodeFor(auditDir(baseStore, o), o) == 1

  test "the report states its own detection power, and it is the documented formula":
    let rep = auditDir(baseStore, opts(samples = 400))
    check abs(rep.detectionPower - detectionPower(400)) < 1e-12
    # 400 samples ⇒ ~1.14%. Pinned as a range rather than a constant so the
    # assertion is about the arithmetic and not about a transcribed digit.
    check rep.detectionPower > 0.011 and rep.detectionPower < 0.012

suite "B1 — an object missing from the middle of the range":
  test "RANGE refuses, and names the height and the key":
    let dir = copyStore("b1")
    # The block at the LOWEST height: a boundary sample, which is the half of
    # the plan that is exhaustive rather than probabilistic.
    let root = parseJson(readFile(dir / "d" / DemoChain / "g" / "1" / "root.json"))
    var lowest = high(int)
    var lowestHash = ""
    for p in root{"maps"}{"height"}:
      let hm = parseJson(readFile(dir / p.getStr))
      for k, v in hm{"heights"}.pairs:
        if parseInt(k) < lowest: lowest = parseInt(k); lowestHash = v.getStr
    let victim = dir / "d" / DemoChain / "block" / (lowestHash & ".json")
    check fileExists(victim)
    removeFile victim

    let rep = auditDir(dir, opts())
    check rep.stateOf(CheckRange) == csFail
    check "NOT SERVED" in rep.findingsOf(CheckRange)
    check $lowest in rep.findingsOf(CheckRange)
    check exitCodeFor(rep, opts()) == 1

  test "MUTATION BITE — the same store with the object restored passes":
    check auditDir(baseStore, opts()).stateOf(CheckRange) == csPass

suite "B2 — the pointer lies and the data is right":
  test "POINTER refuses a head the height map does not contain":
    let dir = copyStore("b2")
    let cp = dir / "d" / DemoChain / "current.json"
    var cur = parseJson(readFile(cp))
    let realHead = cur{"head"}{"height"}.getInt
    cur{"head"}["height"] = %(realHead + 300)
    writeFile(cp, $cur)

    let rep = auditDir(dir, opts())
    check rep.stateOf(CheckPointer) == csFail
    let f = rep.findingsOf(CheckPointer)
    check "does not contain it" in f
    check $(realHead + 300) in f
    # It names HOW FAR the pointer is ahead, which is the number an operator
    # acts on: this is the 74399-over-74099 shape.
    check "height(s) of data that the generation it names does not map" in f

  test "POINTER refuses the same height carrying a different block":
    # Presence is not identity. The height IS in the map here; what moved is
    # which block the pointer says is at it.
    let dir = copyStore("b2b")
    let cp = dir / "d" / DemoChain / "current.json"
    var cur = parseJson(readFile(cp))
    cur{"head"}["hash"] = %"0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    writeFile(cp, $cur)
    let rep = auditDir(dir, opts())
    check rep.stateOf(CheckPointer) == csFail
    check "Same height, different block." in rep.findingsOf(CheckPointer)

  test "MUTATION BITE — the untouched pointer passes":
    check auditDir(baseStore, opts()).stateOf(CheckPointer) == csPass

suite "B3 — historyFloor disagrees with the published data":
  test "PROFILE refuses a floor below the lowest published height":
    let dir = copyStore("b3")
    let rp = dir / "registry" / "chains.v1.json"
    var reg = parseJson(readFile(rp))
    reg{"chains"}{DemoChain}["reach"] = %"floor"
    reg{"chains"}{DemoChain}["historyFloor"] = %*{"height": 1,
      "reason": "a floor nobody measured"}
    writeFile(rp, $reg)

    let rep = auditDir(dir, opts())
    check rep.stateOf(CheckProfile) == csFail
    let f = rep.findingsOf(CheckProfile)
    check "historyFloor" in f
    check "claims history that is not published" in f

  test "PROFILE refuses `archive` over a map that does not start at genesis":
    let dir = copyStore("b3b")
    let rp = dir / "registry" / "chains.v1.json"
    var reg = parseJson(readFile(rp))
    reg{"chains"}{DemoChain}["reach"] = %"archive"
    writeFile(rp, $reg)
    let rep = auditDir(dir, opts())
    check rep.stateOf(CheckProfile) == csFail
    check "rather than at genesis" in rep.findingsOf(CheckProfile)

  test "PROFILE accepts a floor that agrees with the data":
    # The direction a guard is usually NOT tested in, and the one that has
    # blocked a legitimate publish twice this week.
    let dir = copyStore("b3c")
    let root = parseJson(readFile(dir / "d" / DemoChain / "g" / "1" / "root.json"))
    var lowest = high(int)
    for p in root{"maps"}{"height"}:
      let hm = parseJson(readFile(dir / p.getStr))
      for k, _ in hm{"heights"}.pairs:
        if parseInt(k) < lowest: lowest = parseInt(k)
    let rp = dir / "registry" / "chains.v1.json"
    var reg = parseJson(readFile(rp))
    reg{"chains"}{DemoChain}["reach"] = %"floor"
    reg{"chains"}{DemoChain}["historyFloor"] = %*{"height": lowest,
      "reason": "measured against the published map"}
    writeFile(rp, $reg)
    var o = opts()
    o.treeDir = ""      # the local tree still says nothing; the DATA is the check
    let rep = auditDir(dir, o)
    check rep.stateOf(CheckProfile) == csPass
    check "agrees with the height map's lowest height" in
      rep.checks.filterIt(it.id == CheckProfile)[0].notes.join(" ")

suite "B5 — an entire object class never published":
  test "CENSUS refuses, and RANGE does not — which is why the census exists":
    let dir = copyStore("b5")
    removeDir(dir / "t")
    let rep = auditDir(dir, opts())
    check rep.stateOf(CheckCensus) == csFail
    let f = rep.findingsOf(CheckCensus)
    check "ocTraceContainer" in f
    check "no height names an object of this class" in f
    # THE HONEST HALF: the sampled check is blind to this, and says so by passing.
    check rep.stateOf(CheckRange) == csPass

  test "a tolerance is visible and bounded, not a way to pass":
    let dir = copyStore("b5b")
    removeDir(dir / "t")
    var o = opts()
    o.tolerancePct = 100.0     # even allowing 100% of each class to vanish…
    let rep = auditDir(dir, o)
    check rep.stateOf(CheckCensus) == csPass   # …is a decision the operator made
    var o2 = opts()
    o2.tolerancePct = 50.0
    check auditDir(dir, o2).stateOf(CheckCensus) == csFail

suite "B6 — a ledger range the published map never received":
  test "LEDGER refuses, exhaustively, with no extra fetching":
    let dir = copyStore("b6")
    var led = parseJson(readFile(ledgerPath))
    # A range the node served and the publish never carried — a backfill that
    # ran and whose output went nowhere.
    led{"ranges"}["9000-9007"] = %*{"from": 9000, "to": 9007,
      "fetch": {"requested": 8, "served": 8, "notServed": []}}
    let lp = tmp("b6-ledger") / "coverage.json"
    createDir lp.parentDir
    writeFile(lp, $led)

    let rep = auditDir(dir, opts(ledger = lp))
    check rep.stateOf(CheckLedger) == csFail
    let f = rep.findingsOf(CheckLedger)
    check "were ingested and are not in the map" in f
    check "9000" in f
    check "This is the whole range, not a sample." in f

  test "a ledger that contradicts its own served count is reported":
    var led = parseJson(readFile(ledgerPath))
    led{"ranges"}{"9000-9007"} = %*{"from": 9000, "to": 9007,
      "fetch": {"requested": 8, "served": 3, "notServed": []}}
    let lp = tmp("b6b-ledger") / "coverage.json"
    createDir lp.parentDir
    writeFile(lp, $led)
    let rep = auditDir(copyStore("b6b"), opts(ledger = lp))
    check "the ledger contradicts itself" in rep.findingsOf(CheckLedger)

  test "MUTATION BITE — the matching ledger passes":
    check auditDir(baseStore, opts()).stateOf(CheckLedger) == csPass

suite "B7 — a registry that lost a chain":
  test "REGISTRY refuses when the expectation names a chain the registry omits":
    # This is 2026-09-28's data loss seen from the OTHER END: the store holds
    # both chains' objects and the registry lists one, so a verifier pointed at
    # production is the thing that notices.
    var o = opts()
    o.expectChains = @[DemoChain, "another-chain"]
    let rep = auditDir(baseStore, o)
    check rep.stateOf(CheckRegistry) == csFail
    let f = rep.findingsOf(CheckRegistry)
    check "another-chain" in f
    check "the only object that lists a chain" in f

  test "an unexpected EXTRA chain is reported and does not fail":
    var o = opts()
    o.expectChains = @[]
    o.treeDir = baseTree     # the tree's registry lists exactly `demo`
    check auditDir(baseStore, o).stateOf(CheckRegistry) == csPass

  test "no expectation at all is UNRUNNABLE, not a pass":
    var o = opts()
    o.treeDir = ""
    o.expectChains = @[]
    let rep = auditDir(baseStore, o)
    check rep.stateOf(CheckRegistry) == csUnrunnable
    check "outside the thing being checked" in rep.findingsOf(CheckRegistry)

suite "B8 — the right key holding the wrong block":
  test "RANGE refuses on identity, where a presence check would pass":
    let dir = copyStore("b8")
    let root = parseJson(readFile(dir / "d" / DemoChain / "g" / "1" / "root.json"))
    var hs: seq[(int, string)]
    for p in root{"maps"}{"height"}:
      let hm = parseJson(readFile(dir / p.getStr))
      for k, v in hm{"heights"}.pairs: hs.add (parseInt(k), v.getStr)
    doAssert hs.len >= 2
    # Swap two blocks' BODIES. Every key still exists, every response is a 200,
    # every byte count is plausible — and the map and the objects now disagree
    # about which block is where.
    let a = dir / "d" / DemoChain / "block" / (hs[0][1] & ".json")
    let b = dir / "d" / DemoChain / "block" / (hs[1][1] & ".json")
    let (ba, bb) = (readFile(a), readFile(b))
    writeFile(a, bb)
    writeFile(b, ba)

    var o = opts()
    o.treeDir = ""      # no local tree: the ONLY evidence is the object's own claim
    let rep = auditDir(dir, o)
    check rep.stateOf(CheckRange) == csFail
    check "calls itself" in rep.findingsOf(CheckRange)

  test "and the byte comparison catches it too when a local tree is given":
    let dir = copyStore("b8b")
    let root = parseJson(readFile(dir / "d" / DemoChain / "g" / "1" / "root.json"))
    var first = ""
    for p in root{"maps"}{"height"}:
      let hm = parseJson(readFile(dir / p.getStr))
      for _, v in hm{"heights"}.pairs:
        if first.len == 0: first = v.getStr
    let victim = dir / "d" / DemoChain / "block" / (first & ".json")
    var j = parseJson(readFile(victim))
    j["__tampered"] = %true          # same hash, same height, different bytes
    writeFile(victim, $j)
    let rep = auditDir(dir, opts())
    check rep.stateOf(CheckRange) == csFail
    check "DIFFERENT BYTES" in rep.findingsOf(CheckRange)

# ---------------------------------------------------------------------------
# The HTTP fixture: the only backend that can answer the cache question, and
# the only one that can impersonate a catch-all host.
# ---------------------------------------------------------------------------

type ServerMode = enum smNormal, smCatchAll, smBadTrace404

proc headerFor(key: string): string =
  ## What a correctly configured zone would send, derived from the same data
  ## file the checker reads — so the fixture cannot drift from the contract by
  ## being written against a different copy of it. A fixture that hard-codes the
  ## headers it expects to be told are correct proves only that two constants in
  ## one file agree.
  let p = loadCachePolicy()
  let row = p.rowFor(key, false)
  if row.id.len == 0: return "public, max-age=300"
  var parts: seq[string] = @["public"]
  for d in row.expect:
    if d.hasValue: parts.add d.name & "=" & d.value
    else: parts.add d.name
  parts.join(", ")

# ── THE FIXTURE IS A THREAD WITH A BLOCKING SOCKET, AND NOT `asynchttpserver` ──
#
# The async server needs its event loop driven, and the body of each test makes
# SYNCHRONOUS requests (the verifier shells out to `curl`, which is the whole
# point — it is the real transport). Scheduling the server with `asyncCheck` and
# then blocking in the test means the loop never runs and the first request
# hangs forever. Measured: the suite reached B8 and stopped.
#
# A thread with a plain accept loop has none of that coupling: it blocks in
# `accept` while the test blocks in `curl`, which is exactly the shape of a real
# client and a real server. HTTP/1.0 with `Connection: close` keeps the parsing
# to one request per connection.

type FixtureArgs = tuple[root: string, mode: int, port: int]

const ShutdownPath = "/__fixture_shutdown__"

proc fixtureThread(a: FixtureArgs) {.thread.} =
  let mode = ServerMode(a.mode)
  var listener = newSocket()
  listener.setSockOpt(OptReuseAddr, true)
  listener.bindAddr(Port(a.port), "127.0.0.1")
  listener.listen()
  while true:
    var client: Socket
    listener.accept(client)
    var line = ""
    try: client.readLine(line)
    except CatchableError: (client.close(); continue)
    # Drain the rest of the request head.
    while true:
      var h = ""
      try: client.readLine(h) except CatchableError: break
      if h.len == 0 or h == "\r\n": break
    var path = ""
    let parts = line.split(' ')
    if parts.len >= 2: path = parts[1]
    if path == ShutdownPath:
      client.send("HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok")
      client.close()
      break
    let key = path.strip(leading = true, chars = {'/'})
    let file = a.root / key
    proc reply(status, cc, body: string) =
      client.send("HTTP/1.0 " & status & "\r\nCache-Control: " & cc &
                  "\r\nContent-Length: " & $body.len & "\r\n" &
                  "Connection: close\r\n\r\n" & body)
    if fileExists(file):
      reply("200 OK", headerFor(key), readFile(file))
    elif mode == smCatchAll:
      # Cloudflare Pages' SPA fallback, exactly: 200 and the home page for any
      # path the project does not hold.
      reply("200 OK", "public, max-age=60", readFile(a.root / "index.html"))
    elif key.startsWith("t/"):
      reply("404 Not Found",
            (if mode == smBadTrace404: "public, max-age=180" else: "no-store"),
            "not found")
    else:
      reply("404 Not Found", "public, max-age=300", "not found")
    client.close()
  listener.close()

proc mkArgs(root: string, mode: ServerMode, port: int): FixtureArgs =
  ## Built in a proc and not inline in the template: a named-tuple literal
  ## written inside a template takes the CALLER's identifiers as its field
  ## names, which is a type error the first time the template is used with
  ## anything but the parameter names.
  (root: root, mode: mode.int, port: port)

proc freePort(): int =
  ## An OS-assigned port. A fixed one is a suite that fails on a machine where
  ## something else got there first, and that failure looks like the tool.
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = s.getLocalAddr()[1].int
  s.close()

template withServer(root: string, mode: ServerMode, base, body: untyped) =
  block:
    let port = freePort()
    var th: Thread[FixtureArgs]
    createThread(th, fixtureThread, mkArgs(root, mode, port))
    let base {.inject.} = "http://127.0.0.1:" & $port
    try:
      body
    finally:
      discard execShellCmd("curl -s -o /dev/null --max-time 5 " & base &
                           ShutdownPath)
      joinThread(th)

suite "B4 — a host that answers for paths it does not hold":
  test "INSTRUMENT voids the run, and nothing after it is reported as passing":
    withServer(baseStore, smCatchAll, base):
      let rep = runAudit(newHttpSource(base), opts())
      check rep.instrumentVoid
      check rep.stateOf(CheckInstrument) == csFail
      check "SERVED" in rep.findingsOf(CheckInstrument)
      check "no later \"present\" in this run is evidence of anything" in
        rep.findingsOf(CheckInstrument)
      # The run STOPS. A report that went on to print seven passes over a
      # catch-all host is the outcome this check exists to prevent.
      check rep.checks.len == 1
      check exitCodeFor(rep, opts()) == 3

  test "MUTATION BITE — the same server without the fallback passes the instrument":
    withServer(baseStore, smNormal, base):
      let rep = runAudit(newHttpSource(base), opts())
      check not rep.instrumentVoid
      check rep.stateOf(CheckInstrument) == csPass

suite "B9 — cache headers":
  test "a correctly configured zone passes every probed class":
    withServer(baseStore, smNormal, base):
      var o = opts()
      o.allowUnrunnable = @[CheckCensus]    # no listing over HTTP, by design
      let rep = runAudit(newHttpSource(base), o)
      check rep.stateOf(CheckCache) == csPass

  test "a cached 404 under /t/ is refused — Cloudflare's default IS the defect":
    withServer(baseStore, smBadTrace404, base):
      var o = opts()
      o.allowUnrunnable = @[CheckCensus]
      let rep = runAudit(newHttpSource(base), o)
      check rep.stateOf(CheckCache) == csFail
      let f = rep.findingsOf(CheckCache)
      check "trace-404" in f
      check "`no-store` is missing" in f

  test "CENSUS over HTTP is UNRUNNABLE and says why — it is not a pass":
    withServer(baseStore, smNormal, base):
      var o = opts()
      o.allowUnrunnable = @[]
      let rep = runAudit(newHttpSource(base), o)
      check rep.stateOf(CheckCensus) == csUnrunnable
      check "cannot enumerate keys" in rep.findingsOf(CheckCensus)
      check exitCodeFor(rep, o) == 1

suite "the cache policy data file":
  test "every orderSanity pin resolves to the row it names":
    # ORDER IS DATA. `d/*/current.json` before `d/**`, `src/*/*/current.json`
    # before `src/**`. A mis-ordered file does not error — it asserts a year of
    # immutability on the one hot mutable object per chain.
    let p = loadCachePolicy()
    check p.orderSanity.len > 0
    for (key, wantRow) in p.orderSanity:
      check p.rowFor(key, false).id == wantRow

  test "every row is reachable by at least one key":
    # A row no key can match is a rule that can never fire, and it would read
    # in review as coverage.
    let p = loadCachePolicy()
    var reached: seq[string]
    for (key, _) in p.orderSanity: reached.add p.rowFor(key, false).id
    for r in p.rows:
      check r.id in reached

  test "both 404 rows are distinguished by path":
    let p = loadCachePolicy()
    check p.rowFor("t/aa/bb/cc/manifest.json", true).id == "trace-404"
    check p.rowFor("d/demo/block/0x1.json", true).id == "other-404"

  test "a directive is matched by value, not by the header string":
    let p = loadCachePolicy()
    # Same policy, different spelling and order: must pass.
    check p.check("d/demo/current.json", false,
      "stale-while-revalidate=60, s-maxage=5, max-age=0, public").problems.len == 0
    # A plausible-looking header that is wrong in one number: must fail.
    let bad = p.check("d/demo/current.json", false,
      "public, max-age=0, s-maxage=30, stale-while-revalidate=60")
    check bad.problems.len == 1
    check "`s-maxage` is 30 and must be 5" in bad.problems[0]
    # `immutable` on the one mutable object per chain.
    check p.check("d/demo/current.json", false,
      "public, max-age=0, s-maxage=5, stale-while-revalidate=60, immutable")
        .problems.join(" ").contains("forbids it")

suite "the HTTP transport":
  test "only the FINAL response in a redirect chain is read":
    # A CDN that 301s and then serves has served. Reading the first block would
    # take the redirect's headers as the object's — and a 301 carries neither
    # the cache policy nor the bytes.
    let raw = "HTTP/1.1 301 Moved Permanently\r\nLocation: /x/\r\n" &
              "cache-control: max-age=99\r\n\r\n" &
              "HTTP/2 200 \r\ncache-control: public, max-age=31536000, immutable\r\n" &
              "content-type: application/json\r\n\r\n"
    let f = parseHeaders(raw)
    check f.status == 200
    check f.present
    check f.headers["cache-control"] == "public, max-age=31536000, immutable"

  test "a response with no status line is an error, not an empty success":
    let f = parseHeaders("garbage\r\n\r\n")
    check not f.present
    check "no HTTP status line" in f.error

suite "read-only by construction":
  test "a Source offers no way to write":
    # The compile-time half of `ci/test/verify-published-readonly.sh`. If a
    # write method were ever added to the Source hierarchy, this file is where
    # somebody would have to come to make the suite green again.
    let s: Source = newLocalSource(baseStore)
    check s.canList()
    check not compiles(s.put("k", "v"))
    check not compiles(s.del("k"))
    check not compiles(s.putIfAbsent("k", "v"))
    check not compiles(s.putMany(@[]))
