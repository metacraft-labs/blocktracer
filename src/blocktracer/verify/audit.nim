## verify/audit.nim — is all the data actually on the published instance?
##
## `blocktracer-validate` answers "is this TREE well-formed" about a directory
## on the machine that produced it. `blocktracer-client-conformance` answers
## "can a consumer read this tree". Neither of them has ever been pointed at
## production, and neither could be: both walk every object, and the tree they
## would have to walk is 882,639 objects.
##
## This answers a different question — **is what the producer intended actually
## served, and does the tree cohere** — against a live instance, in a bounded
## number of requests, read-only.
##
## ════════════════════════════════════════════════════════════════════════════
##  THE SAMPLING ARGUMENT
## ════════════════════════════════════════════════════════════════════════════
##
## Sampling is the interesting part, so it is stated before the checks, and what
## it CANNOT do is stated with it.
##
## The published tree is not an unstructured pile. It has an **index** — the
## generation root and the height map — that is O(1) objects and names every
## height the generation claims. So the audit is in three layers, and only the
## third is sampled:
##
##   1. **POINTERS, exhaustively.** The registry, each chain's `current.json`,
##      each generation root. A handful of objects, all fetched. Every one of
##      them is a claim, and a claim is cheap to check and expensive to get
##      wrong: both of the two `reach`/`historyFloor` incidents were a POINTER
##      that lied over data that was correct.
##
##   2. **THE LEDGER AGAINST THE MAP, exhaustively and with no fetching at all.**
##      `tools/chain/ingest-range.mjs` writes a range ledger recording, per
##      range, which heights the node SERVED. The published height map records
##      which heights the generation NAMES. Those are two independently-produced
##      descriptions of the same set, and comparing them is set identity over the
##      entire range for the cost of **two objects**. A backfill range that never
##      ran, a range published to the wrong generation, an off-by-one at a seam —
##      all of those are differences between these two sets, and none of them
##      needs a sample. This is the check that makes the whole audit affordable:
##      the expensive question is answered by arithmetic, not by traffic.
##
##   3. **THE MAP AGAINST THE STORE, sampled.** What layer 2 cannot see is an
##      object the map names and the store does not hold — the delta publisher
##      having skipped, truncated or lost it. That is per-object, so it is the
##      one place sampling is used, and it is sampled in two halves:
##
##      **Deterministic.** The floor, the tip, and **both sides of every range
##      boundary in the ledger**. Real omissions are not uniform — they follow
##      range boundaries, because a range is the unit of work that runs or does
##      not. There are O(ranges) of these, not O(heights), so they are taken
##      EXHAUSTIVELY and are not a sample at all.
##
##      **Probabilistic.** N further heights spread evenly over the span, to
##      cover the failure that has no structure. With N independent samples, a
##      uniform omission rate `p` escapes every one of them with probability
##      `(1-p)^N`, so at 99% confidence the run detects any rate at or above
##
##            p* = 1 - 0.01^(1/N)
##
##      `detectionPower` computes exactly that and **the run prints it**, so the
##      output states the strength of its own evidence rather than leaving a
##      reader to assume it. The default N is 400: p* ≈ 1.14%, which on the
##      138,287-object baseline is about 1,500 objects — the smallest loss that
##      is still a *systematic* loss rather than a handful. Raising N is linear
##      in requests and the flag is there; 400 is a default, not a claim about
##      what is enough for every tree.
##
##      Spread evenly and not at random, deliberately. A random sample is not
##      reproducible, so a failing run cannot be re-run to confirm, and two runs
##      of the same tree are not comparable. An even spread over the sorted
##      heights has the same detection power against a uniform loss and is the
##      same set every time.
##
## **WHAT SAMPLING CANNOT CATCH, and what covers it instead.** A wholesale
## omission that the map also does not know about — an entire object CLASS never
## published, `t/**` or `idx/**` or `src/**` — is invisible to a height sample,
## because no height names it. That is what `CENSUS` is for: one paginated
## listing, classified by `publisher.nim`'s own `classOf`, compared against the
## same count taken over a local tree. Enumerating KEYS in one listing is not the
## same cost as fetching 882,639 OBJECTS, and the distinction is the whole reason
## the census is affordable while a full read is not.
##
## **AND A CHECK THAT COULD NOT RUN IS NOT A PASS.** Every check reports one of
## four states, and `unrunnable` is a FAILURE unless the operator named it on the
## command line. A census cannot run over HTTP (no listing); a cache check cannot
## run over a directory (no CDN). Silently treating either as satisfied is how a
## report comes to say "all checks passed" about a run that asked three
## questions.
##
## ════════════════════════════════════════════════════════════════════════════
##  READ-ONLY
## ════════════════════════════════════════════════════════════════════════════
##
## Nothing here writes, takes a lease, or calls `putIfAbsent`. It cannot: it
## holds a `Source` (verify/source.nim), which has no write operation, and
## `ci/test/verify-published-readonly.sh` refuses one being added.
##
## ════════════════════════════════════════════════════════════════════════════
##  CHAIN-AGNOSTIC
## ════════════════════════════════════════════════════════════════════════════
##
## No chain name, chain count or key shape is written down here. The chains come
## from the published registry (or from `--expect-chain`); the key layout comes
## from each chain's own declared `identifierEncoding` through
## `contract/shards.nim`, which is the same function the producer keyed with; the
## history boundary comes from that chain's `reach` and `historyFloor` through
## `contract/chain_profile.nim`. Aztec is the first chain this runs against and
## nothing here knows that.

import std/[json, math, os, algorithm, strutils, tables, md5, sets]

import ../contract/[version, shards, identifier_encoding, chain_profile]
import ../publish/publisher   # classOf / ObjClass — the publish-side taxonomy
import ./source
import ./cachepolicy

type
  CheckState* = enum
    csPass = "PASS"
    csFail = "FAIL"
    csUnrunnable = "UNRUNNABLE"
    csSkipped = "SKIPPED"

  CheckResult* = object
    id*: string
    title*: string
    state*: CheckState
    findings*: seq[string]   ## why it failed, specifically
    notes*: seq[string]      ## what it measured, on a pass

  AuditOptions* = object
    expectChains*: seq[string]
    treeDir*: string          ## local producer tree: the census + byte-identity expectation
    ledgerPath*: string       ## tools/chain/ingest-range.mjs range ledger
    samples*: int
    tolerancePct*: float
    skip*: seq[string]            ## checks the operator switched off, visibly
    allowUnrunnable*: seq[string] ## checks allowed to report UNRUNNABLE without failing
    maxReported*: int             ## cap on findings listed per check

  AuditReport* = object
    checks*: seq[CheckResult]
    instrumentVoid*: bool     ## the instrument itself is untrustworthy; nothing else means anything
    detectionPower*: float

const
  CheckInstrument* = "INSTRUMENT"
  CheckRegistry* = "REGISTRY"
  CheckPointer* = "POINTER"
  CheckProfile* = "PROFILE"
  CheckLedger* = "LEDGER"
  CheckRange* = "RANGE"
  CheckCensus* = "CENSUS"
  CheckCache* = "CACHE"

  AllChecks* = [CheckInstrument, CheckRegistry, CheckPointer, CheckProfile,
                CheckLedger, CheckRange, CheckCensus, CheckCache]

proc defaultAuditOptions*(): AuditOptions =
  AuditOptions(samples: 400, tolerancePct: 0.0, maxReported: 10)

func detectionPower*(n: int): float =
  ## The smallest uniform omission rate this many samples detects at 99%
  ## confidence: `1 - 0.01^(1/n)`. Stated as a function so the number printed
  ## and the number argued in the header cannot drift.
  if n <= 0: return 1.0
  1.0 - pow(0.01, 1.0 / float(n))

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc add(r: var CheckResult, f: string, cap: int) =
  if r.findings.len < cap: r.findings.add f
  elif r.findings.len == cap: r.findings.add "… (further findings suppressed)"

proc seal(r: var CheckResult) =
  if r.state == csPass and r.findings.len > 0: r.state = csFail

proc tryJson(f: Fetched): tuple[node: JsonNode, err: string] =
  if not f.present:
    return (nil, "absent" & (if f.error.len > 0: " (" & f.error & ")" else: "") &
                 (if f.status > 0: " [HTTP " & $f.status & "]" else: ""))
  try: (parseJson(f.body), "")
  except CatchableError as e: (nil, "unparseable JSON: " & e.msg)

proc registryKey(): string = "registry" / "chains.v" & $ContractVersion & ".json"
proc currentKey(chain: string): string = "d" / chain / "current.json"
proc genRootKey(chain, gen: string): string = "d" / chain / "g" / gen / "root.json"

# ---------------------------------------------------------------------------
# INSTRUMENT — does a 200 mean anything on this host?
# ---------------------------------------------------------------------------

proc checkInstrument(src: Source, opts: AuditOptions): CheckResult =
  ## RUNS FIRST AND VOIDS THE RUN, because every other check's evidence is a
  ## fetch that came back, and on a host that serves one page for every path a
  ## fetch always comes back.
  ##
  ## Cloudflare Pages does exactly this for a SPA: a request for a path it does
  ## not hold is answered with `index.html` and a 200. Pointed at such a host,
  ## an audit built on "it returned, so it is there" reports a complete tree
  ## over an empty bucket. Two properties are established before anything else
  ## is allowed to mean something:
  ##
  ##   1. A **deliberately-absent control** is absent. The key is constructed to
  ##      be one no producer can emit — it is under `d/` with a chain segment
  ##      that is not a chain and a name that is not an identifier — so its
  ##      absence is a fact about the host and never about the data.
  ##   2. Two **distinct present objects differ**. A host that returns the same
  ##      bytes for two different real keys is a catch-all even if the control
  ##      happens to 404, and comparing the bodies is the only thing that sees
  ##      it. This is identity, not a status code and not a count.
  result = CheckResult(id: CheckInstrument,
    title: "a 200 from this host means the object is there", state: csPass)

  let control = "d/__blocktracer_verify_control__/block/" &
                "0x0000000000000000000000000000000000000000000000000000000000000000.json"
  let c = src.fetch(control)
  if c.present:
    result.add("the deliberately-absent control key `" & control & "` was SERVED (" &
      (if c.status > 0: "HTTP " & $c.status else: "present") & ", " & $c.body.len &
      " bytes, from " & c.finalUrl & "). This host answers for paths it does not " &
      "hold — a Cloudflare Pages SPA fallback does exactly this — so no later " &
      "\"present\" in this run is evidence of anything. The audit is VOID, not failed.",
      opts.maxReported)
    result.state = csFail
    return
  result.notes.add "control key absent" &
    (if c.status > 0: " (HTTP " & $c.status & ")" else: "")

  # Two distinct real objects, chosen from the objects every published tree has:
  # the registry, and the first chain's current.json. They are fetched by the
  # callers too; fetching them twice costs two requests and keeps this check
  # self-contained, which matters because it is the one check whose failure
  # invalidates the others.
  let reg = src.fetch(registryKey())
  if not reg.present:
    result.state = csUnrunnable
    result.findings.add "cannot establish that two distinct objects differ: the " &
      "registry `" & registryKey() & "` is not served, so this run has only one " &
      "known-present object to compare"
    return
  let (regJson, regErr) = tryJson(reg)
  # BOUND ONCE, not subscripted twice. The guard below and the loop beneath it
  # must be about the SAME object: `regJson{"chains"}` written twice is two
  # evaluations, and a reader has to prove they agree before trusting the guard.
  # It also keeps the loop off an optional member, which is what the §13 ban
  # asks for — that ban carries no exemption list, deliberately, so the answer
  # is to bind rather than to forgive the line.
  let regChains = if regJson == nil: nil else: regJson{"chains"}
  if regErr.len > 0 or regJson == nil or regChains == nil:
    result.state = csUnrunnable
    result.findings.add "the registry is served but " &
      (if regErr.len > 0: regErr else: "carries no `chains`") &
      ", so no second known-present object can be named"
    return
  var firstChain = ""
  for name, _ in regChains.pairs:
    if firstChain.len == 0 or name < firstChain: firstChain = name
  if firstChain.len == 0:
    result.state = csUnrunnable
    result.findings.add "the registry lists no chains, so no second known-present " &
      "object can be named"
    return
  let cur = src.fetch(currentKey(firstChain))
  if not cur.present:
    result.add("`" & currentKey(firstChain) & "` is not served, although the " &
      "registry lists chain '" & firstChain & "'", opts.maxReported)
    result.state = csFail
    return
  if cur.body == reg.body:
    result.add("`" & registryKey() & "` and `" & currentKey(firstChain) &
      "` returned BYTE-IDENTICAL responses (" & $cur.body.len & " bytes, MD5 " &
      getMD5(cur.body) & "). Two different keys served the same bytes: this host " &
      "is a catch-all and the control key merely happened to miss it. The audit is VOID.",
      opts.maxReported)
    result.state = csFail
    return
  result.notes.add "two distinct keys returned distinct bytes (registry MD5 " &
    getMD5(reg.body)[0 .. 7] & "…, current.json MD5 " & getMD5(cur.body)[0 .. 7] & "…)"
  seal(result)

# ---------------------------------------------------------------------------
# Expectations taken from a local producer tree
# ---------------------------------------------------------------------------

type
  LocalExpectation = object
    have: bool
    chains: seq[string]
    registry: JsonNode
    classCounts: Table[ObjClass, int]
    keys: HashSet[string]

proc readLocalExpectation(treeDir: string): LocalExpectation =
  result.classCounts = initTable[ObjClass, int]()
  result.keys = initHashSet[string]()
  if treeDir.len == 0 or not dirExists(treeDir): return
  result.have = true
  for p in walkDirRec(treeDir):
    let rel = p.relativePath(treeDir).replace('\\', '/')
    if rel.startsWith("_leases/") or ".tmp." in rel: continue
    result.keys.incl rel
    let c = classOf(rel)
    result.classCounts[c] = result.classCounts.getOrDefault(c) + 1
  let rp = treeDir / registryKey()
  if fileExists(rp):
    try:
      result.registry = parseJson(readFile(rp))
      let ch = result.registry{"chains"}
      if ch != nil:
        for name, _ in ch.pairs: result.chains.add name
        result.chains.sort()
    except CatchableError: discard

# ---------------------------------------------------------------------------
# REGISTRY — the chains that should be listed, are
# ---------------------------------------------------------------------------

proc checkRegistry(src: Source, opts: AuditOptions, local: LocalExpectation):
    tuple[res: CheckResult, chains: seq[string], rows: Table[string, JsonNode]] =
  ## THE REGISTRY IS THE ONLY OBJECT THAT LISTS A CHAIN. A chain missing from it
  ## is a chain whose every object is present in the store and reachable by
  ## nobody — which is not a hypothetical: it is the shape of the data-loss
  ## defect a two-chain publish reproduced on 2026-09-28, where the second
  ## chain's single-chain tree overwrote the first chain's row.
  var r = CheckResult(id: CheckRegistry,
    title: "the registry lists the expected chains", state: csPass)
  var rows = initTable[string, JsonNode]()
  var found: seq[string]

  let f = src.fetch(registryKey())
  let (j, err) = tryJson(f)
  if err.len > 0 or j == nil:
    r.add("`" & registryKey() & "`: " & err, opts.maxReported)
    r.state = csFail
    return (r, found, rows)
  let chains = j{"chains"}
  if chains == nil or chains.kind != JObject:
    r.add("`" & registryKey() & "` carries no `chains` object", opts.maxReported)
    r.state = csFail
    return (r, found, rows)
  for name, row in chains.pairs:
    found.add name
    rows[name] = row
  found.sort()

  var expected = opts.expectChains
  if expected.len == 0 and local.have: expected = local.chains
  if expected.len == 0:
    r.notes.add "no expectation given (neither --expect-chain nor a --tree " &
      "registry), so this reports what is listed rather than checking it: " &
      found.join(", ")
    r.state = csUnrunnable
    r.findings.add "nothing said which chains SHOULD be listed. `" &
      $found.len & "` chain(s) are — but a registry that lost a row lists a " &
      "coherent set too, which is exactly why the expectation has to come from " &
      "outside the thing being checked. Pass --expect-chain or --tree."
    return (r, found, rows)

  expected.sort()
  for want in expected:
    if want notin found:
      r.add("chain '" & want & "' is expected and the published registry does " &
        "NOT list it. Its objects may well be in the store; the registry is the " &
        "only object that lists a chain, so nothing can reach them.", opts.maxReported)
  for got in found:
    if got notin expected:
      r.notes.add "registry additionally lists '" & got &
        "', which the expectation did not name (reported, not failed: a new " &
        "chain is a legitimate addition)"
  if r.findings.len == 0:
    r.notes.add "expected " & $expected.len & " chain(s), all listed: " & expected.join(", ")
  seal(r)
  (r, found, rows)

# ---------------------------------------------------------------------------
# POINTER — current.json names the expected generation and head
# ---------------------------------------------------------------------------

type
  ChainState = object
    ok: bool
    generation: string
    headHeight: int
    headHash: string
    encoding: ChainIdentifierEncoding
    profile: ChainProfile
    heights: Table[int, string]     ## height → block hash, from the published map
    heightsOk: bool
    mapObjects: seq[string]

proc checkPointer(src: Source, opts: AuditOptions, chains: seq[string],
                  rows: Table[string, JsonNode], local: LocalExpectation):
    tuple[res: CheckResult, states: Table[string, ChainState]] =
  var r = CheckResult(id: CheckPointer,
    title: "each chain's current.json names a generation whose root is sealed and " &
           "a head the height map contains", state: csPass)
  var states = initTable[string, ChainState]()

  for chain in chains:
    var st = ChainState(heights: initTable[int, string]())
    if rows.hasKey(chain):
      try: st.encoding = parseChainIdentifierEncoding(rows[chain])
      except CatchableError as e:
        r.add("chain '" & chain & "': its registry row's `identifierEncoding` " &
          "cannot be read (" & e.msg & "), so no key on this chain can be " &
          "recomputed", opts.maxReported)
        states[chain] = st
        continue
      st.profile = parseChainProfile(rows[chain])

    let cf = src.fetch(currentKey(chain))
    let (cj, cerr) = tryJson(cf)
    if cerr.len > 0 or cj == nil:
      r.add("chain '" & chain & "': `" & currentKey(chain) & "`: " & cerr,
            opts.maxReported)
      states[chain] = st
      continue
    st.generation = cj{"generation"}.getStr
    st.headHeight = cj{"head"}{"height"}.getInt(-1)
    st.headHash = cj{"head"}{"hash"}.getStr
    if st.generation.len == 0:
      r.add("chain '" & chain & "': `current.json` names no generation",
            opts.maxReported)
      states[chain] = st
      continue

    # The expectation, when a local tree was given: the SAME generation and head.
    if local.have:
      let lp = local.keys.contains(currentKey(chain))
      if lp:
        try:
          let lj = parseJson(readFile(opts.treeDir / currentKey(chain)))
          let wantGen = lj{"generation"}.getStr
          let wantH = lj{"head"}{"height"}.getInt(-1)
          let wantHash = lj{"head"}{"hash"}.getStr
          if wantGen.len > 0 and wantGen != st.generation:
            r.add("chain '" & chain & "': published generation is '" & st.generation &
              "' and the local tree publishes '" & wantGen & "'", opts.maxReported)
          if wantH >= 0 and wantH != st.headHeight:
            r.add("chain '" & chain & "': published head height is " & $st.headHeight &
              " and the local tree's is " & $wantH, opts.maxReported)
          if wantHash.len > 0 and wantHash != st.headHash:
            r.add("chain '" & chain & "': published head hash is " & st.headHash &
              " and the local tree's is " & wantHash, opts.maxReported)
        except CatchableError: discard

    # The generation root, which seals the generation and names the height map.
    let rf = src.fetch(genRootKey(chain, st.generation))
    let (rj, rerr) = tryJson(rf)
    if rerr.len > 0 or rj == nil:
      r.add("chain '" & chain & "': `current.json` names generation '" &
        st.generation & "' and its root `" & genRootKey(chain, st.generation) &
        "` " & rerr & ". The pointer advertises a generation that is not sealed.",
        opts.maxReported)
      states[chain] = st
      continue
    let rootGen = rj{"generation"}.getStr
    if rootGen.len > 0 and rootGen != st.generation:
      r.add("chain '" & chain & "': the root at generation '" & st.generation &
        "' calls itself generation '" & rootGen & "'", opts.maxReported)

    let hmaps = rj{"maps"}{"height"}
    if hmaps == nil or hmaps.kind != JArray or hmaps.len == 0:
      r.add("chain '" & chain & "': generation root '" & st.generation &
        "' names no height map, so no height on this chain can be resolved",
        opts.maxReported)
      states[chain] = st
      continue

    var loaded = 0
    for p in hmaps:
      let key = p.getStr
      if key.len == 0: continue
      st.mapObjects.add key
      let hf = src.fetch(key)
      let (hj, herr) = tryJson(hf)
      if herr.len > 0 or hj == nil:
        r.add("chain '" & chain & "': the generation root names height map `" &
          key & "` and it " & herr, opts.maxReported)
        continue
      let hs = hj{"heights"}
      if hs == nil or hs.kind != JObject: continue
      for k, v in hs.pairs:
        try: st.heights[parseInt(k)] = v.getStr
        except CatchableError: discard
      inc loaded
    st.heightsOk = loaded == st.mapObjects.len and st.heights.len > 0

    if st.heightsOk:
      # ── THE POINTER LIES / THE DATA IS RIGHT ──────────────────────────────
      # A head the map does not contain is the exact shape of the defect that
      # put a pointer at height 74399 over a map that stopped at 74099. It is
      # checked by IDENTITY — the hash the pointer names against the hash the
      # map names at that height — because "the height is in the map" alone
      # would pass a pointer that names the right height and the wrong block.
      if st.headHeight < 0:
        r.add("chain '" & chain & "': `current.json` states no head height",
              opts.maxReported)
      elif not st.heights.hasKey(st.headHeight):
        var mx = low(int)
        for h in st.heights.keys: (if h > mx: mx = h)
        r.add("chain '" & chain & "': `current.json` advertises head height " &
          $st.headHeight & " and generation '" & st.generation & "'s height map " &
          "does not contain it — the map's highest is " & $mx & ". The pointer is " &
          "advertising " & $(st.headHeight - mx) & " height(s) of data that the " &
          "generation it names does not map.", opts.maxReported)
      elif st.headHash.len > 0 and st.heights[st.headHeight] != st.headHash:
        r.add("chain '" & chain & "': at head height " & $st.headHeight &
          " the pointer names block " & st.headHash & " and the height map names " &
          st.heights[st.headHeight] & ". Same height, different block.",
          opts.maxReported)
      else:
        var mx = low(int)
        for h in st.heights.keys: (if h > mx: mx = h)
        if mx > st.headHeight:
          r.add("chain '" & chain & "': the height map reaches " & $mx &
            " and `current.json` advertises only " & $st.headHeight &
            ". Data is published and not visible.", opts.maxReported)
      st.ok = true
    states[chain] = st

  if r.findings.len == 0 and chains.len > 0:
    for chain in chains:
      if states.hasKey(chain) and states[chain].heightsOk:
        r.notes.add "chain '" & chain & "': generation " & states[chain].generation &
          ", head " & $states[chain].headHeight & ", height map holds " &
          $states[chain].heights.len & " height(s) across " &
          $states[chain].mapObjects.len & " map object(s)"
  seal(r)
  (r, states)

# ---------------------------------------------------------------------------
# PROFILE — reach and historyFloor, against the intent AND against the data
# ---------------------------------------------------------------------------

proc checkProfile(opts: AuditOptions, chains: seq[string],
                  rows: Table[string, JsonNode], states: Table[string, ChainState],
                  local: LocalExpectation): CheckResult =
  ## THIS HAS BEEN WRONG TWICE, BY DIFFERENT ROUTES, AND BOTH TIMES THE DATA WAS
  ## RIGHT AND THE POINTER LIED. So the declaration is checked against two
  ## independent things, and disagreeing with either is a finding:
  ##
  ##   * the LOCAL expectation — what the producer meant to publish;
  ##   * the PUBLISHED DATA — the lowest height the generation's own map holds.
  ##
  ## The second is the one that matters, because it needs nothing from the
  ## machine that did the publish. A `historyFloor` of B on a chain whose map
  ## starts at B+900 is a false statement about somebody's ability to debug a
  ## transaction, and it is visible from the published tree alone.
  result = CheckResult(id: CheckProfile,
    title: "reach and historyFloor say what the data shows", state: csPass)
  var checkedAny = false

  for chain in chains:
    if not rows.hasKey(chain): continue
    let p = parseChainProfile(rows[chain])

    for refusal in p.refusals():
      result.add("chain '" & chain & "': " & refusal, opts.maxReported)
    let inconsistent = profileConsistency(p)
    if inconsistent.len > 0:
      result.add("chain '" & chain & "': " & inconsistent, opts.maxReported)

    # Against the local expectation.
    if local.have and local.registry != nil:
      let lrow = local.registry{"chains"}{chain}
      if lrow != nil:
        let lp = parseChainProfile(lrow)
        if lp.reach.state == dsDeclared and p.reach.state == dsDeclared and
           lp.reach.kind != p.reach.kind:
          result.add("chain '" & chain & "': published `reach` is '" & $p.reach.kind &
            "' and the producer's tree declares '" & $lp.reach.kind & "'",
            opts.maxReported)
        if lp.reach.state == dsDeclared and p.reach.state != dsDeclared:
          result.add("chain '" & chain & "': the producer's tree declares `reach` '" &
            $lp.reach.kind & "' and the published registry declares none",
            opts.maxReported)
        if lp.floor.stated and p.floor.stated and lp.floor.height != p.floor.height:
          result.add("chain '" & chain & "': published `historyFloor` is " &
            $p.floor.height & " and the producer's tree states " & $lp.floor.height,
            opts.maxReported)
        if lp.floor.stated and not p.floor.stated:
          result.add("chain '" & chain & "': the producer's tree states a " &
            "`historyFloor` of " & $lp.floor.height &
            " and the published registry states none", opts.maxReported)

    # Against the published data — the half that needs nothing but the tree.
    if states.hasKey(chain) and states[chain].heightsOk:
      checkedAny = true
      var lo = high(int)
      for h in states[chain].heights.keys: (if h < lo: lo = h)
      if p.floor.stated:
        if p.floor.height != lo:
          result.add("chain '" & chain & "': the registry states `historyFloor` " &
            $p.floor.height & " and the published generation's height map begins at " &
            $lo & " — a gap of " & $abs(lo - p.floor.height) & " height(s). " &
            (if lo > p.floor.height:
               "The registry claims history that is not published: a client trusting " &
               "it will request a prestate below the lowest height the tree maps."
             else:
               "The tree publishes history below the floor it declares, so the " &
               "declaration is hiding data that is in fact served."), opts.maxReported)
        else:
          result.notes.add "chain '" & chain & "': historyFloor " & $p.floor.height &
            " agrees with the height map's lowest height"
      if p.reach.state == dsDeclared and p.reach.kind == rkArchive and lo > 0:
        result.add("chain '" & chain & "': `reach` is 'archive', which claims any " &
          "historical position is reachable, and the published height map begins at " &
          $lo & " rather than at genesis", opts.maxReported)
      if p.reach.state == dsDeclared and p.reach.kind in {rkFloor, rkWindowed} and
         not p.floor.stated:
        discard   # already reported by profileConsistency; not reported twice
      if p.reach.state == dsAbsent and p.floor.stated:
        discard   # profileConsistency does not fire on an absent reach; the floor
                  # was still checked against the data above, which is the claim

  if not checkedAny and result.findings.len == 0:
    result.state = csUnrunnable
    result.findings.add "no chain offered both a readable registry row and a " &
      "readable height map, so `reach` and `historyFloor` could not be checked " &
      "against the data. A profile checked only against the producer's own tree " &
      "is two copies of one claim."
    return
  if result.findings.len == 0 and result.notes.len == 0:
    result.notes.add "no chain declares `reach` or `historyFloor`; nothing to " &
      "contradict (an absent member is the compatibility case, Configuration.md §2.2)"
  seal(result)

# ---------------------------------------------------------------------------
# The range ledger
# ---------------------------------------------------------------------------

type
  LedgerRange = object
    key: string
    fromH, toH: int
    served: HashSet[int]
    notServed: HashSet[int]
    hasServed: bool
    countMismatch: string

  Ledger = object
    have: bool
    ranges: seq[LedgerRange]
    chain: string

proc readLedger(path: string): Ledger =
  ## THE SHAPE IS THE ONE `ingest-range.mjs` WRITES, read the way
  ## `coverage-contiguity.mjs` reads it — `ranges[k].fetch.notServed` is the
  ## list, and `ranges[k].fetch.served` is a COUNT and not a list.
  ##
  ## So the served SET is reconstructed as `[from..to]` minus `notServed`, which
  ## is what the ledger means and what the existing reader assumes. The count is
  ## then checked against the reconstruction rather than ignored: a ledger whose
  ## `served` number disagrees with its own range and exclusions is describing
  ## something other than what it appears to, and quietly preferring one of the
  ## two is how a coverage claim comes to rest on the half nobody looked at.
  ##
  ## A flat `notServed` / a literal `served` ARRAY are both accepted, because
  ## the test fixtures and any future writer may state the set directly, and a
  ## reader that only understands one spelling of the same fact is a reader that
  ## will be wrong about the other.
  if path.len == 0 or not fileExists(path): return
  var j: JsonNode
  try: j = parseJson(readFile(path))
  except CatchableError: return
  result.have = true
  result.chain = j{"chain"}.getStr
  let rs = j{"ranges"}
  if rs == nil or rs.kind != JObject: return
  for k, v in rs.pairs:
    var r = LedgerRange(key: k, fromH: v{"from"}.getInt(-1), toH: v{"to"}.getInt(-1),
                        served: initHashSet[int](), notServed: initHashSet[int]())
    let fetchNode = if v{"fetch"} != nil: v{"fetch"} else: v
    let ns = fetchNode{"notServed"}
    if ns != nil and ns.kind == JArray:
      for h in ns: r.notServed.incl h.getInt
    let sv = fetchNode{"served"}
    if sv != nil and sv.kind == JArray:
      r.hasServed = true
      for h in sv: r.served.incl h.getInt
    elif r.fromH >= 0 and r.toH >= r.fromH:
      r.hasServed = true
      for h in r.fromH .. r.toH:
        if h notin r.notServed: r.served.incl h
      if sv != nil and sv.kind == JInt and sv.getInt != r.served.len:
        r.countMismatch = "range '" & k & "' records served=" & $sv.getInt &
          " and its own [" & $r.fromH & ".." & $r.toH & "] minus " &
          $r.notServed.len & " excluded height(s) is " & $r.served.len
    result.ranges.add r
  result.ranges.sort(proc(a, b: LedgerRange): int = cmp(a.fromH, b.fromH))

# ---------------------------------------------------------------------------
# LEDGER — the ledger's served set against the published map, exhaustively
# ---------------------------------------------------------------------------

proc checkLedger(opts: AuditOptions, ledger: Ledger, chains: seq[string],
                 states: Table[string, ChainState]): CheckResult =
  result = CheckResult(id: CheckLedger,
    title: "every height the ledger says was served is in the published height map",
    state: csPass)
  if not ledger.have:
    result.state = csUnrunnable
    result.findings.add "no range ledger given (--ledger). Without it the only " &
      "statement about the WHOLE range is a sample, and the cheapest exhaustive " &
      "check in this audit — two objects, no traffic, every height — does not run."
    return

  var target = ledger.chain
  if target.len == 0 or target notin chains:
    if chains.len == 1: target = chains[0]
    else:
      result.state = csUnrunnable
      result.findings.add "the ledger names chain '" & ledger.chain &
        "', which is not among the published chains (" & chains.join(", ") &
        "), and more than one chain is published, so it cannot be matched by " &
        "elimination"
      return
  if not states.hasKey(target) or not states[target].heightsOk:
    result.state = csUnrunnable
    result.findings.add "chain '" & target & "' has no readable height map, so " &
      "the ledger cannot be compared against it"
    return

  let hs = states[target].heights
  var servedTotal = 0
  var missing: seq[int]
  var extraCount = 0
  var servedAll = initHashSet[int]()
  for r in ledger.ranges:
    if r.countMismatch.len > 0:
      result.add("the ledger contradicts itself: " & r.countMismatch &
        ". The served SET this check compares against is the reconstruction, so " &
        "a disagreement here means the comparison is being made against a set " &
        "the ledger's own count does not describe.", opts.maxReported)
    for h in r.served:
      inc servedTotal
      servedAll.incl h
      if not hs.hasKey(h): missing.add h
  missing.sort()
  for h in hs.keys:
    if h notin servedAll: inc extraCount

  if missing.len > 0:
    var sample: seq[string]
    for h in missing[0 .. min(missing.high, 9)]: sample.add $h
    result.add("chain '" & target & "': the ledger records " & $servedTotal &
      " height(s) as SERVED by the node and the published generation's height map " &
      "contains " & $(servedTotal - missing.len) & " of them. " & $missing.len &
      " height(s) were ingested and are not in the map — first: " &
      sample.join(", ") & (if missing.len > 10: ", …" else: "") &
      ". This is the whole range, not a sample.", opts.maxReported)
  if extraCount > 0:
    result.notes.add "the map holds " & $extraCount & " height(s) the ledger does " &
      "not record as served (reported, not failed: a ledger covering part of a " &
      "longer history is legitimate)"
  if missing.len == 0:
    result.notes.add "chain '" & target & "': all " & $servedTotal &
      " ledger-served height(s) are present in the height map — exhaustive, " &
      "computed from 2 objects"
  seal(result)

# ---------------------------------------------------------------------------
# RANGE — the map against the store, by identity, at chosen and spread heights
# ---------------------------------------------------------------------------

proc samplePlan(heights: seq[int], ledger: Ledger, n: int): tuple[
    boundary: seq[int], spread: seq[int]] =
  ## The deterministic half and the probabilistic half, kept separate so the
  ## report can say which one found a defect — they answer different questions.
  if heights.len == 0: return
  var want = initHashSet[int]()
  let present = toHashSet(heights)

  want.incl heights[0]                  # the floor
  want.incl heights[^1]                 # the tip
  for r in ledger.ranges:
    # Both sides of every boundary. A height outside the map is not fetched —
    # its absence is layer 2's business, not this one's — so each candidate is
    # filtered through what the map actually holds.
    for h in [r.fromH - 1, r.fromH, r.toH, r.toH + 1]:
      if h in present: want.incl h
  for h in want: result.boundary.add h
  result.boundary.sort()

  if n > 0 and heights.len > result.boundary.len:
    # Evenly spread over the SORTED heights, so two runs over one tree pick the
    # same set and a failure can be re-run. `i * (len-1) / (n-1)` lands on both
    # ends; the ends are already boundary samples, so duplicates are dropped.
    let m = min(n, heights.len)
    for i in 0 ..< m:
      let idx = if m == 1: 0 else: int((int64(i) * int64(heights.len - 1)) div int64(m - 1))
      let h = heights[idx]
      if h notin want:
        want.incl h
        result.spread.add h
    result.spread.sort()

type
  ProbeOutcome = object
    finding: string     ## empty when the object matched by identity
    byteChecked: bool

proc probeHeight(src: Source, opts: AuditOptions, chain: string, st: ChainState,
                 h: int, why: string, local: LocalExpectation): ProbeOutcome =
  ## One height, resolved through the map and checked by IDENTITY.
  ##
  ## A top-level proc and not a closure, deliberately: it is the only place in
  ## this module that decides whether an object "is there", and a reader should
  ## be able to see every way it can answer no without unwinding a loop.
  let want = st.heights[h]
  var key: string
  try:
    key = blockPath(chain, want, st.encoding)
  except CatchableError as e:
    return ProbeOutcome(finding: "chain '" & chain & "': cannot build the key " &
      "for the block at height " & $h & " from this chain's declared " &
      "identifierEncoding: " & e.msg)
  let f = src.fetch(key)
  if not f.present:
    return ProbeOutcome(finding: "chain '" & chain & "': height " & $h & " (" &
      why & ") — the height map names block " & want & " and `" & key &
      "` is NOT SERVED" & (if f.status > 0: " (HTTP " & $f.status & ")" else: "") &
      (if f.error.len > 0: " [" & f.error & "]" else: ""))
  var j: JsonNode
  try: j = parseJson(f.body)
  except CatchableError as e:
    return ProbeOutcome(finding: "chain '" & chain & "': height " & $h & " (" &
      why & ") — `" & key & "` is served and is not JSON: " & e.msg)
  # IDENTITY, not a status and not a length. The object has to agree with the
  # map about which block it is and where it sits. A count of objects served
  # would be consistent with the map and the store describing two different
  # chains; a hash is not.
  let gotHash = j{"hash"}.getStr
  let gotHeight = j{"height"}.getInt(low(int))
  if gotHash.len > 0 and gotHash != want:
    return ProbeOutcome(finding: "chain '" & chain & "': at height " & $h & " (" &
      why & ") the map names block " & want & " and the object at `" & key &
      "` calls itself " & gotHash)
  if gotHeight != low(int) and gotHeight != h:
    return ProbeOutcome(finding: "chain '" & chain & "': the map places block " &
      want & " at height " & $h & " (" & why & ") and the object says it is at " &
      "height " & $gotHeight)
  if local.have and local.keys.contains(key):
    let lb = readFile(opts.treeDir / key)
    if getMD5(lb) != getMD5(f.body):
      return ProbeOutcome(finding: "chain '" & chain & "': height " & $h & " (" &
        why & ") — `" & key & "` is served with DIFFERENT BYTES from the " &
        "producer's tree (served MD5 " & getMD5(f.body) & ", local MD5 " &
        getMD5(lb) & ")")
    return ProbeOutcome(byteChecked: true)
  ProbeOutcome()

proc checkRange(src: Source, opts: AuditOptions, chains: seq[string],
                states: Table[string, ChainState], ledger: Ledger,
                local: LocalExpectation): CheckResult =
  result = CheckResult(id: CheckRange,
    title: "sampled heights resolve to objects whose own identity matches the map",
    state: csPass)
  var ranAny = false

  for chain in chains:
    if not states.hasKey(chain) or not states[chain].heightsOk: continue
    let st = states[chain]
    var heights: seq[int]
    for h in st.heights.keys: heights.add h
    heights.sort()
    let plan = samplePlan(heights, ledger, opts.samples)
    if plan.boundary.len + plan.spread.len == 0: continue
    ranAny = true

    var matched = 0
    var byteChecked = 0
    for (hs, why) in [(plan.boundary, "boundary"), (plan.spread, "spread")]:
      for h in hs:
        let o = probeHeight(src, opts, chain, st, h, why, local)
        if o.finding.len > 0: result.add(o.finding, opts.maxReported)
        else:
          inc matched
          if o.byteChecked: inc byteChecked

    result.notes.add "chain '" & chain & "': " & $plan.boundary.len &
      " boundary height(s) (floor, tip, both sides of every ledger range) and " &
      $plan.spread.len & " spread height(s) probed; " & $matched & " matched by " &
      "identity" & (if byteChecked > 0: ", " & $byteChecked &
      " of them byte-identical to the producer's tree" else: "")

  if not ranAny:
    result.state = csUnrunnable
    result.findings.add "no chain offered a readable height map, so no height " &
      "could be resolved to an object"
    return
  seal(result)

# ---------------------------------------------------------------------------
# CENSUS — counts by class, against a local tree, within tolerance
# ---------------------------------------------------------------------------

proc checkCensus(src: Source, opts: AuditOptions, local: LocalExpectation): CheckResult =
  ## WHAT SAMPLING CANNOT SEE. A height sample can only find objects a height
  ## names. An entire class never published — `t/**`, `idx/**`, `src/**`, the
  ## entry pages — is named by no height and is invisible to every other check
  ## here.
  ##
  ## ONE LISTING IS NOT 882,639 FETCHES. `list-objects-v2` returns a thousand
  ## keys per call and the publisher already takes exactly this listing on every
  ## cycle. Classifying its keys with `publisher.nim`'s own `classOf` — rather
  ## than a second taxonomy written here — means the census counts the classes
  ## the publisher WRITES, so a class that stopped being written is named by the
  ## same word in both places.
  result = CheckResult(id: CheckCensus,
    title: "object counts by class are within tolerance of the local tree", state: csPass)
  if not src.canList():
    result.state = csUnrunnable
    result.findings.add "this backend cannot enumerate keys (" & src.describe() &
      "), so a wholesale class omission cannot be detected. Over HTTP there is " &
      "no listing; run the census against the bucket (--backend s3) as well as " &
      "the CDN, or allow this check to be unrunnable with --allow-unrunnable CENSUS."
    return
  if not local.have:
    result.state = csUnrunnable
    result.findings.add "no local tree given (--tree), so there is no expectation " &
      "to compare the store's per-class counts against. A census with no " &
      "expectation is a list of numbers."
    return

  var storeCounts = initTable[ObjClass, int]()
  var total = 0
  for k, _ in src.listSizes(""):
    if k.startsWith("_leases/"): continue
    let c = classOf(k)
    storeCounts[c] = storeCounts.getOrDefault(c) + 1
    inc total

  var lines: seq[string]
  for c in ObjClass:
    let want = local.classCounts.getOrDefault(c)
    let got = storeCounts.getOrDefault(c)
    if want == 0 and got == 0: continue
    let allowed = max(0, int(float(want) * opts.tolerancePct / 100.0))
    let short = want - got
    lines.add "  " & align($c, 18) & "  local " & align($want, 8) & "  store " &
      align($got, 8) & (if short != 0: "  Δ " & $(-short) else: "")
    if short > allowed:
      result.add("class " & $c & ": the local tree holds " & $want &
        " object(s) and the store holds " & $got & " — " & $short & " missing" &
        (if allowed > 0: " (tolerance allows " & $allowed & ")" else: "") &
        ". A height sample cannot see this: no height names an object of this class.",
        opts.maxReported)
  result.notes.add "store holds " & $total & " object(s); per class:"
  for l in lines: result.notes.add l
  seal(result)

# ---------------------------------------------------------------------------
# CACHE — the headers §2.9 makes normative
# ---------------------------------------------------------------------------

proc checkCache(src: Source, opts: AuditOptions, chains: seq[string],
                states: Table[string, ChainState]): CheckResult =
  result = CheckResult(id: CheckCache,
    title: "cache headers match the object-class registry", state: csPass)
  if not src.supportsHeaders():
    result.state = csUnrunnable
    result.findings.add "this backend serves no response headers (" &
      src.describe() & "). The cache contract is a property of the CDN, so it " &
      "can only be checked over HTTP — point this at the site, or allow it to " &
      "be unrunnable with --allow-unrunnable CACHE."
    return

  let policy = loadCachePolicy()
  var probes: seq[tuple[key: string, absent: bool]]
  probes.add (registryKey(), false)
  for chain in chains:
    probes.add (currentKey(chain), false)
    if states.hasKey(chain) and states[chain].heightsOk:
      probes.add (genRootKey(chain, states[chain].generation), false)
      var lo = high(int)
      for h in states[chain].heights.keys: (if h < lo: lo = h)
      if states[chain].heights.hasKey(lo):
        try:
          probes.add (blockPath(chain, states[chain].heights[lo],
                                states[chain].encoding), false)
        except CatchableError: discard
  # The 404 whose policy is a correctness rule rather than a tuning one.
  probes.add ("t/00/00/0000000000000000000000000000000000000000/manifest.json", true)

  for (key, wantAbsent) in probes:
    let f = src.fetch(key)
    if wantAbsent and f.present:
      result.add("`" & key & "` was expected to be ABSENT and was served (HTTP " &
        $f.status & "); its cache policy cannot be checked", opts.maxReported)
      continue
    if not wantAbsent and not f.present:
      result.add("`" & key & "` is not served, so its cache policy cannot be " &
        "checked" & (if f.status > 0: " (HTTP " & $f.status & ")" else: ""),
        opts.maxReported)
      continue
    let cc = f.headers.getOrDefault("cache-control")
    let verdict = policy.check(key, wantAbsent, cc)
    if verdict.rowId.len == 0:
      result.add("`" & key & "`: no row in " & CachePolicyFormat &
        " matches this key, so the contract says nothing about it and this run " &
        "cannot tell a correct header from a wrong one", opts.maxReported)
      continue
    if verdict.problems.len > 0:
      for p in verdict.problems:
        result.add("`" & key & "` [" & verdict.rowId & "]: " & p &
          " — served `Cache-Control: " & (if cc.len > 0: cc else: "(absent)") & "`",
          opts.maxReported)
    else:
      result.notes.add (if wantAbsent: "404 " else: "") & key & " [" &
        verdict.rowId & "] ok: " & cc
  seal(result)

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

proc asSkipped(r: CheckResult): CheckResult =
  CheckResult(id: r.id, title: r.title, state: csSkipped,
              notes: @["switched off with --skip " & r.id])

proc runAudit*(src: Source, opts: AuditOptions): AuditReport =
  var rep = AuditReport(detectionPower: detectionPower(opts.samples))
  let local = readLocalExpectation(opts.treeDir)
  let ledger = readLedger(opts.ledgerPath)

  template record(r: CheckResult) =
    block:
      let rr = r
      rep.checks.add (if rr.id in opts.skip: asSkipped(rr) else: rr)

  if CheckInstrument in opts.skip:
    # Allowed, and said out loud on the exit line: an operator who knows the host
    # cannot do a catch-all may switch it off, and the report must not then read
    # as though the instrument was verified.
    rep.checks.add asSkipped(CheckResult(id: CheckInstrument,
      title: "a 200 from this host means the object is there"))
  else:
    let inst = checkInstrument(src, opts)
    rep.checks.add inst
    if inst.state == csFail:
      rep.instrumentVoid = true
      return rep

  let (regRes, chains, rows) = checkRegistry(src, opts, local)
  record(regRes)

  let (ptrRes, states) = checkPointer(src, opts, chains, rows, local)
  record(ptrRes)
  record(checkProfile(opts, chains, rows, states, local))
  record(checkLedger(opts, ledger, chains, states))
  record(checkRange(src, opts, chains, states, ledger, local))
  record(checkCensus(src, opts, local))
  record(checkCache(src, opts, chains, states))
  rep

func exitCodeFor*(rep: AuditReport, opts: AuditOptions): int =
  ## 0 clean · 1 a finding · 3 the instrument voided the run.
  ## An UNRUNNABLE check is a finding unless the operator named it.
  if rep.instrumentVoid: return 3
  for c in rep.checks:
    if c.state == csFail: return 1
    if c.state == csUnrunnable and c.id notin opts.allowUnrunnable: return 1
  0
