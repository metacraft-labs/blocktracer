## rehearse/drill.nim — the scenario matrix: the sequence of publishes that
## turns a corpus into evidence, and the invariants checked over the store
## after each one.
##
## ## A scenario is a pair, not a run
##
## Every scenario here exists to reach ONE SIDE of one conditional, and almost
## all of them come in pairs, because a conditional exercised on one side only
## is a conditional whose other side has never run. The pairs are the reason
## the matrix is longer than "publish it and see":
##
##   A1/A2   key-existence missed, then hit (and the re-run uploads zero)
##   A1/A3   the lease acquired, then refused to a second writer
##   A2/A4   an input-addressed object equal, then DIFFERING — an incident
##   A5      `--refresh` finding a stored object unchanged, and superseded
##   A6      the flip halted, then completed on resume
##   A1/A7   the bulk confirmation satisfied, then REFUSED by a store that
##           accepted a write and did not keep it
##   B1/B2   a global object defended against a single-chain tree, and a
##           legitimate whole-site tree still ACCEPTED
##
## The last pair is the one that cost a day. `B1` alone is the check everybody
## writes after losing data; `B2` is the check nobody writes, and a guard that
## refuses the good path stops the pipeline just as dead as one that permits
## the bad path — it did so twice on 2026-09-28.
##
## ## A cell is "exercised" whether the property held or not
##
## Coverage and correctness are kept apart on purpose. A scenario that RAN
## records its cell even when the property it measured turned out to be false;
## the falsehood is reported separately, as a finding. Conflating them would
## make a defect look like a coverage hole and send the next reader to widen
## the rehearsal when what they should do is fix the publisher.
##
## ## Everything happens in scratch, on hardlinks
##
## The operator's tree is never written to. Trees are materialised as hardlink
## farms and the handful of objects a drill has to tamper with are unlinked
## first (`corpus.writeKey`). Stores are fresh directories under the work dir.
## Nothing in this module can reach a network, and nothing in it takes a
## production credential: a drill that could run against production is a drill
## that will.

import std/[algorithm, json, os, sequtils, strutils, tables]

import ../publish/objectstore
import ../publish/publisher
import ./corpus
import ./coverage

type
  Finding* = object
    ## Something that is WRONG, as opposed to something that was not measured.
    id*: string
    title*: string
    detail*: string

  DrillReport* = object
    ledger*: CoverageLedger
    findings*: seq[Finding]
    derivations*: seq[Derivation]
    scenariosRun*: seq[string]
    objectsConsidered*: int
    objectsSelected*: int

  DroppingStore = ref object of LocalObjectStore
    ## A store that ACCEPTS a write and does not keep it — the one failure a
    ## bulk transfer's exit code cannot see. It is the deliberately broken
    ## store the `bulk-confirm/refused` cell is measured against, and it is a
    ## faithful model: `putMany` on a real backend moves many objects under one
    ## process exit, so "it returned" and "each of these keys is in the store"
    ## are genuinely different claims.
    dropKey: string

method put(s: DroppingStore, key, data: string) =
  if key == s.dropKey: return           # silently accepted, silently lost
  procCall put(LocalObjectStore(s), key, data)

proc fail(r: var DrillReport, id, title, detail: string) =
  r.findings.add Finding(id: id, title: title, detail: detail)

# ---------------------------------------------------------------------------

proc firstKeyOfClass(t: Tree, cls: ObjClass, chain = ""): string =
  for k in t.keys:
    if classOf(k) != cls: continue
    if chain.len > 0 and chainOf(k) != chain: continue
    return k
  ""

proc globalSnapshot(store: ObjectStore): Table[string, string] =
  ## The global objects under UNCONDITIONAL rewrite, and only those.
  ##
  ## An object can only lose a chain if something rewrites it, and the only
  ## strategy that rewrites is `stUnconditional`. A global object under
  ## `stKeyExistence` is skipped when present, so a second chain's publish
  ## cannot touch it however global its key is. Restricting the snapshot this
  ## way is not an optimisation for its own sake: it keeps the snapshot O(the
  ## pointers) rather than O(the tree), so this scenario costs the same on a
  ## 882,639-object store as on a 290-object one.
  result = initTable[string, string]()
  for k in store.list(""):
    if k.startsWith("_leases/"): continue
    if not isGlobal(k): continue
    if strategyOf(classOf(k)) != stUnconditional: continue
    let (d, ok) = store.get(k)
    if ok: result[k] = d

proc chainsWithDataIn(store: ObjectStore): seq[string] =
  for k in store.list(""):
    if classOf(k) == ocCurrent:
      let c = chainOf(k)
      if c.len > 0 and c notin result: result.add c
  result.sort()

func isSlugChar(c: char): bool =
  c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-'}

func mentions*(blob, chain: string): bool =
  ## Does a global object still NAME this chain?
  ##
  ## Deliberately a textual test over the object's bytes rather than a
  ## schema-aware one, because the property has to hold for every global object
  ## at once — the registry, the hash index, the site home, and whatever a
  ## producer adds next year — and a schema-aware test would only hold for the
  ## objects somebody remembered to teach it.
  ##
  ## IT IS A TOKEN TEST AND NOT A SUBSTRING TEST, and the difference is not
  ## theoretical: the first version of this function was `chain in blob`, and
  ## the drill's own derived chain is named after the original (`demo` →
  ## `demo-rehearsal-b`). Every registry that had LOST `demo` still contained
  ## the characters `demo`, so the check passed on a store that had just been
  ## robbed. It reported the defect as absent on the one input it was written
  ## for. Real corpora have the same shape — `aztec` and `aztec-testnet` — so
  ## this is the ordinary case and not a quirk of the derivation.
  ##
  ## A token is an occurrence with no slug character on either side. A false
  ## positive can still only make the check more permissive, never less, and
  ## the check's job is to catch a chain DISAPPEARING.
  if chain.len == 0: return false
  var i = 0
  while true:
    let at = blob.find(chain, start = i)
    if at < 0: return false
    let beforeOk = at == 0 or not isSlugChar(blob[at - 1])
    let afterAt = at + chain.len
    let afterOk = afterAt >= blob.len or not isSlugChar(blob[afterAt])
    if beforeOk and afterOk: return true
    i = at + 1

# ---------------------------------------------------------------------------
# The matrix.
# ---------------------------------------------------------------------------

type DrillOptions* = object
  mode*: Mode
  perBucket*: int
  workDir*: string
  derive*: bool
  writer*: string

proc defaultDrillOptions*(): DrillOptions =
  DrillOptions(mode: rmPartial, perBucket: 3, workDir: "", derive: true,
               writer: "rehearsal")

proc runDrill*(treeDirs: seq[string], opts: DrillOptions): DrillReport =
  result.ledger = contractLedger()
  let work = opts.workDir
  createDir work

  # ── materialise the corpus ────────────────────────────────────────────────
  var trees: seq[Tree] = @[]
  for i, src in treeDirs:
    let all = treeKeys(src)
    result.objectsConsidered += all.len
    let sel = selectKeys(all, opts.mode, opts.perBucket)
    result.objectsSelected += sel.len
    trees.add materialise(src, work / ("tree" & $i), "T" & $i, sel)
  if trees.len == 0:
    result.fail("corpus/empty", "no producer tree given",
      "A rehearsal needs at least one `--tree DIR`.")
    return
  let t0 = trees[0]
  let c0chains = t0.chainsOf()
  if c0chains.len == 0:
    result.fail("corpus/no-chain", "the first tree declares no chain",
      "No key under `d/{chain}/` was found in " & t0.dir & ".")
    return
  let c0 = c0chains[0]

  # ── the derivations, when the corpus cannot supply the shape ─────────────
  #
  # A second chain arriving in a SEPARATE tree, and a second generation. Both
  # are announced, and both are named in the witness column of the cells they
  # satisfy, so a cell met by construction never reads like one met by the
  # operator's own corpus.
  var chainB = ""
  var treeB: Tree
  var haveSeparateChainTrees = false
  block secondChain:
    # already in the corpus? two trees whose chain sets differ is the real thing.
    for i in 0 ..< trees.len:
      for j in 0 ..< trees.len:
        if i == j: continue
        for c in trees[j].chainsOf():
          if c notin trees[i].chainsOf():
            chainB = c
            treeB = trees[j]
            haveSeparateChainTrees = true
            break secondChain
    if opts.derive:
      chainB = c0 & "-rehearsal-b"
      treeB = deriveChainTree(t0, work / "treeB", c0, chainB)
      haveSeparateChainTrees = true
      result.derivations.add Derivation(what: "chain '" & chainB & "'",
        why: "the corpus holds one chain in one tree, and the registry defect " &
             "needs two chains arriving as two trees. Re-keyed from '" & c0 & "'.")

  var genB = ""
  var treeG: Tree
  var haveTwoGenerations = false
  block secondGen:
    let gens = t0.generationsOf(c0)
    if gens.len >= 2:
      haveTwoGenerations = true
      genB = gens[^1]
      treeG = t0
      break secondGen
    if opts.derive and gens.len == 1:
      let g = gens[0]
      genB =
        try: $(parseInt(g) + 1)
        except ValueError: g & "-b"
      treeG = deriveGenerationTree(t0, work / "treeG", c0, g, genB)
      haveTwoGenerations = true
      result.derivations.add Derivation(what: "generation '" & genB & "' of '" & c0 & "'",
        why: "the corpus holds one generation, which cannot show that a sealed " &
             "generation survives the next one's flip. Copied from '" & g & "'.")

  # ── cardinality, measured off the corpus rather than assumed ─────────────
  if haveSeparateChainTrees:
    result.ledger.record(dimCardinality, "chains-in-separate-trees",
      "trees '" & t0.label & "' (" & c0 & ") and '" & treeB.label & "' (" & chainB & ")")
  if haveTwoGenerations:
    result.ledger.record(dimCardinality, "generations",
      c0 & " generations incl. '" & genB & "'")
  block shards:
    var seen: seq[string] = @[]
    for t in trees:
      for s in t.indexShardsOf():
        if s notin seen: seen.add s
    if seen.len >= 2:
      result.ledger.record(dimCardinality, "index-shards",
        $seen.len & " distinct: " & seen[0] & ", " & seen[1] & ", …")
  block ranges:
    var seen: seq[string] = @[]
    for t in trees:
      for r in t.addressRangesOf():
        if r notin seen: seen.add r
    if seen.len >= 2:
      result.ledger.record(dimCardinality, "address-ranges",
        $seen.len & " distinct: " & seen[0] & ", " & seen[1] & ", …")

  # ══ A. the ordinary cycle, on one store ═══════════════════════════════════
  let storeA = newLocalObjectStore(work / "storeA")
  var optsA = defaultOptions()
  optsA.writer = opts.writer

  # A1 — fresh publish.
  result.scenariosRun.add "A1 fresh publish"
  var a1: seq[PublishResult]
  try:
    a1 = publishTree(storeA, t0.dir, optsA)
  except PublishError as e:
    result.fail("scenario/A1", "a fresh publish of a legitimate tree was refused", e.msg)
    return
  var a1Uploaded = 0
  for r in a1:
    a1Uploaded += r.contentUploaded.len
    result.ledger.recordKeys(r.contentUploaded, "A1")
    result.ledger.recordKeys(r.pointersWritten, "A1")
    if r.contentUploaded.len > 0:
      result.ledger.record(dimBranch, "key-existence/miss", "A1: " & r.contentUploaded[0])
    if r.pointerFlipped:
      result.ledger.record(dimBranch, "flip/completed", "A1: " & r.chain)
      result.ledger.record(dimBranch, "bulk-confirm/satisfied",
        "A1: " & $r.contentUploaded.len & " object(s) confirmed before the flip")
    else:
      result.fail("scenario/A1", "a fresh publish did not flip the pointer",
        "chain " & r.chain & ": `current.json` was not written, so nothing " &
        "published in this cycle is visible to any reader.")
  result.ledger.record(dimBranch, "lease/acquired", "A1: " & c0)
  if a1Uploaded == 0:
    result.fail("scenario/A1", "a fresh publish uploaded nothing",
      "The store was empty and the tree is not. Either the tree carries no " &
      "object this publisher recognises, or the store is reporting keys it " &
      "does not hold.")

  # A2 — re-publish. Idempotency is the claim; zero is the number.
  result.scenariosRun.add "A2 re-publish (idempotency)"
  let a2 = publishTree(storeA, t0.dir, optsA)
  var a2Uploaded, a2Skipped = 0
  for r in a2:
    a2Uploaded += r.contentUploaded.len
    a2Skipped += r.contentSkipped.len
    if r.contentSkipped.len > 0:
      result.ledger.record(dimBranch, "key-existence/hit", "A2: " & r.contentSkipped[0])
    for k in r.contentSkipped:
      if classOf(k) in {ocTraceContainer, ocTraceManifest}:
        result.ledger.record(dimBranch, "content-hash/equal", "A2: " & k)
        break
  result.ledger.record(dimInvariant, "idempotent-recycle/holds",
    "A2: " & $a2Uploaded & " uploaded, " & $a2Skipped & " skipped")

  # A2b — the subtraction nothing else performs: tree minus store.
  block published:
    var inStore = initTable[string, bool]()
    for k in storeA.list(""): inStore[k] = true
    var orphans: seq[string] = @[]
    for k in t0.keys:
      if k notin inStore: orphans.add k
    result.ledger.record(dimInvariant, "every-object-is-published/holds",
      "A2b: " & $(t0.keys.len - orphans.len) & " of " & $t0.keys.len &
      " corpus objects are in the store")
    if orphans.len > 0:
      var families: OrderedTable[string, int]
      for k in orphans: families.mgetOrPut(familyOf(k) & "|" & k.split('/')[0], 0).inc
      var lines: seq[string] = @[]
      for f, n in families: lines.add "    " & f & "  ×" & $n
      result.fail("invariant/every-object-is-published",
        $orphans.len & " object(s) in the corpus are published by no chain's cycle",
        "These keys exist in the producer's tree and are in no store after a " &
        "complete cycle over every chain it declares. By shape:\n" &
        lines.join("\n") & "\n" &
        "  Examples: " & orphans[0 ..< min(4, orphans.len)].join(", ") & "\n" &
        "  `publishChain`'s `belongs` predicate admits a key for a chain if it " &
        "is under `d/{chain}/`, `src/{chain}/`, `{chain}/` (entry pages), or in " &
        "the chain-agnostic set — `t/`, `idx/`, `assets/`, `registry/`, and the " &
        "three site-root names `index.html`, `sitemap.xml`, `robots.txt`. A " &
        "static page outside those, such as `404.html` or `about/index.html`, " &
        "is admitted for no chain and is therefore uploaded by nothing. There " &
        "is no error and no warning: the producer wrote the file, the publisher " &
        "returned success, and the object is not on the site.")

  if a2Uploaded != 0:
    result.fail("scenario/A2", "a re-run of a completed cycle uploaded objects",
      $a2Uploaded & " content object(s) were rewritten on a second pass over " &
      "an unchanged tree. §2.3 says a re-run uploads zero; an object rewritten " &
      "here is an object whose identity is not what its key says it is.")

  # A3 — the lease, from the losing side.
  result.scenariosRun.add "A3 lease refused to a second writer"
  if acquireLease(storeA, c0, "rehearsal-other-writer"):
    var refused = false
    var msg = ""
    try:
      discard publishTree(storeA, t0.dir, optsA)
    except PublishError as e:
      refused = true
      msg = e.msg
    result.ledger.record(dimBranch, "lease/refused", "A3: " & msg)
    if not refused:
      result.fail("scenario/A3", "a second publisher was NOT refused while the lease was held",
        "`putIfAbsent` is the only compare-and-set in the system and the " &
        "single-writer guarantee rests on it. A publish that proceeds with " &
        "another writer's lease in place can interleave two cycles on one chain.")
    releaseLease(storeA, c0, "rehearsal-other-writer")
  else:
    result.fail("scenario/A3", "the lease could not be taken out of band",
      "`acquireLease` returned false on a store whose lease was just released.")

  # A4 — an input-addressed object whose bytes moved: an incident, never a write.
  let ctKey = firstKeyOfClass(t0, ocTraceContainer)
  if ctKey.len > 0:
    result.scenariosRun.add "A4 determinism incident"
    let original = t0.readKey(ctKey)
    let (storedBefore, _) = storeA.get(ctKey)
    t0.writeKey(ctKey, original & "\x00rehearsal-tamper")
    let a4 = publishTree(storeA, t0.dir, optsA)
    var incidents: seq[string] = @[]
    for r in a4: incidents.add r.determinismIncidents
    result.ledger.record(dimBranch, "content-hash/differs",
      "A4: " & ctKey & " → " & $incidents.len & " incident(s)")
    if ctKey notin incidents:
      result.fail("scenario/A4", "a differing input-addressed object was not reported",
        ctKey & " was republished with different bytes at the same key and no " &
        "determinism incident was raised. Trace-Artifacts §2.8a: an " &
        "input-addressed object whose bytes moved under a fixed input is a " &
        "non-deterministic producer.")
    let (storedAfter, okAfter) = storeA.get(ctKey)
    if not okAfter or storedAfter != storedBefore:
      result.fail("scenario/A4", "a differing input-addressed object was OVERWRITTEN",
        ctKey & " no longer holds the bytes it held before the tampered " &
        "publish. Silently superseding a `/t/**` container is the one thing " &
        "§2.8a exists to prevent — the stored container is the one a manifest's " &
        "`container.hash` was computed over.")
    t0.writeKey(ctKey, original)

  # A5 — `--refresh`, both sides.
  let blockKey = firstKeyOfClass(t0, ocContent, c0)
  if blockKey.len > 0:
    result.scenariosRun.add "A5 refresh: unchanged and superseded"
    let original = t0.readKey(blockKey)
    let tampered = original & "\n{\"rehearsalRefreshMarker\":true}\n"
    t0.writeKey(blockKey, tampered)
    var optsR = optsA
    optsR.refreshContent = true
    let a5 = publishTree(storeA, t0.dir, optsR)
    var refreshed: seq[string] = @[]
    var unchanged = 0
    for r in a5:
      refreshed.add r.contentRefreshed
      unchanged += r.contentSkipped.len
    if unchanged > 0:
      result.ledger.record(dimBranch, "refresh/unchanged",
        "A5: " & $unchanged & " object(s) compared equal and were skipped")
    result.ledger.record(dimBranch, "refresh/superseded",
      "A5: " & blockKey & " → " & $refreshed.len & " superseded")
    if blockKey notin refreshed:
      result.fail("scenario/A5", "`--refresh` did not supersede a changed object",
        blockKey & "'s bytes differ from the store's and it was not rewritten. " &
        "Without this path a producer fix never reaches a store that already " &
        "holds the wrong object, because the key did not move.")
    else:
      let (now, ok) = storeA.get(blockKey)
      if not ok or now != tampered:
        result.fail("scenario/A5", "`--refresh` reported a supersede that did not land",
          blockKey & " is listed in `contentRefreshed` and the store does not " &
          "hold the tree's bytes. The report and the store disagree, and the " &
          "store is the one readers see.")
    # heal: put the real bytes back and refresh them into the store, so later
    # scenarios are not reading a tampered object.
    t0.writeKey(blockKey, original)
    discard publishTree(storeA, t0.dir, optsR)

  # A6 — the flip halted, then completed, on a store of its own.
  result.scenariosRun.add "A6 halt before the flip, then resume"
  let storeB = newLocalObjectStore(work / "storeB")
  var optsH = defaultOptions()
  optsH.writer = opts.writer
  optsH.haltBeforePointer = true
  let a6 = publishTree(storeB, t0.dir, optsH)
  var halted = false
  for r in a6:
    if r.haltedBeforePointer: halted = true
  result.ledger.record(dimBranch, "flip/halted", "A6: halted=" & $halted)
  let curKey = "d/" & c0 & "/current.json"
  if not halted:
    result.fail("scenario/A6", "`--halt-before-pointer` did not halt",
      "The drill asked for a crash after content and before the visibility " &
      "flip, and the cycle ran to completion.")
  if storeB.exists(curKey):
    result.fail("scenario/A6", "a halted cycle still flipped the pointer",
      curKey & " exists after a cycle that halted before the flip. §2.3's " &
      "atomicity is that an interrupted cycle leaves only unreferenced content.")
  let a6b = publishTree(storeB, t0.dir, optsA)
  var resumedOk = false
  for r in a6b:
    if r.chain == c0 and r.pointerFlipped: resumedOk = true
  result.ledger.record(dimInvariant, "resume-without-gap/holds",
    "A6: resumed and flipped=" & $resumedOk)
  if not resumedOk:
    result.fail("scenario/A6", "a killed cycle did not resume",
      "Re-running after a halt did not reach the visibility flip. " &
      "Pipeline-Architecture §3.2a: the publisher keeps no cross-run state, so " &
      "a restarted run must re-diff against the store and finish the cycle.")
  else:
    let wantGen = parseJson(t0.readKey(curKey)){"generation"}.getStr
    let (got, gotOk) = storeB.get(curKey)
    let gotGen = if gotOk: parseJson(got){"generation"}.getStr else: ""
    if gotGen != wantGen:
      result.fail("scenario/A6", "the resumed pointer names the wrong generation",
        "tree says '" & wantGen & "', store says '" & gotGen & "'.")

  # A7 — a store that accepts a write and does not keep it.
  result.scenariosRun.add "A7 bulk confirmation refuses an unconfirmed key"
  let dropKey = block:
    var k = ""
    for key in t0.keys:
      if strategyOf(classOf(key)) == stKeyExistence and chainOf(key) == c0:
        k = key; break
    k
  if dropKey.len > 0:
    createDir work / "storeC"
    let storeC = DroppingStore(root: work / "storeC", dropKey: dropKey)
    var refused = false
    var msg = ""
    try:
      discard publishTree(storeC, t0.dir, optsA)
    except PublishError as e:
      refused = true; msg = e.msg
    except CatchableError as e:
      refused = true; msg = e.msg
    result.ledger.record(dimBranch, "bulk-confirm/refused",
      "A7: dropped " & dropKey & " → refused=" & $refused)
    if not refused:
      result.fail("scenario/A7", "the pointer flipped over an object the store does not hold",
        "The store silently discarded " & dropKey & " and the cycle flipped " &
        "`current.json` anyway. A bulk transfer moves many objects under one " &
        "exit code; if the flip is gated on the exit code rather than on the " &
        "store, a generation is advertised over content that is not there.")
    elif storeC.exists(curKey):
      result.fail("scenario/A7", "the flip was refused and the pointer moved anyway",
        curKey & " exists in a store whose publish raised.")

  # ══ B. more than one chain ════════════════════════════════════════════════
  if haveSeparateChainTrees:
    result.scenariosRun.add "B1 a single-chain tree over a store holding another chain"
    let storeD = newLocalObjectStore(work / "storeD")
    discard publishTree(storeD, t0.dir, optsA)
    let before = globalSnapshot(storeD)
    var bRefused = false
    var bMsg = ""
    try:
      discard publishTree(storeD, treeB.dir, optsA)
    except PublishError as e:
      bRefused = true; bMsg = e.msg
    let after = globalSnapshot(storeD)
    let held = chainsWithDataIn(storeD)
    result.ledger.record(dimCardinality, "chains-in-store",
      "B1: store holds " & held.join(", "))
    result.ledger.record(dimInvariant, "global-pointer-no-chain-loss/refuses",
      "B1: " & (if bRefused: "publish refused — " & bMsg else:
                "publish accepted; " & $after.len & " global object(s) re-checked"))
    if not bRefused:
      var lost: seq[string] = @[]
      for k, blobBefore in before:
        if k notin after: continue
        if mentions(blobBefore, c0) and not mentions(after[k], c0):
          lost.add k
      if lost.len > 0:
        result.fail("invariant/global-pointer-no-chain-loss",
          "a global object stopped naming a chain the store still holds",
          "After publishing the single-chain tree for '" & chainB & "', these " &
          "GLOBAL (chain-less) objects no longer name '" & c0 & "', whose data " &
          "is still in the store:\n    " & lost.join("\n    ") & "\n" &
          "  Those objects are the only thing that lists a chain, so '" & c0 &
          "' is now present and invisible to every reader — the objects are " &
          "there, fetchable by hash, and nothing points at them.\n" &
          "  This is not a property of the DATA and no amount of scale on one " &
          "chain can exhibit it: the key carries no chain segment, so both " &
          "chains write it, and the second write wins. Ingest every chain into " &
          "ONE tree so the merge happens before publication, or refuse a tree " &
          "whose registry drops a chain the store already holds.")

    # B2 — and the accepting direction, which is the half nobody writes.
    result.scenariosRun.add "B2 a legitimate whole-site tree is still accepted"
    let merged = work / "treeMerged"
    removeDir merged
    createDir merged
    var mergedKeys: seq[string] = @[]
    for k in treeB.keys:
      createDir parentDir(merged / k)
      copyFile(treeB.dir / k, merged / k)
      mergedKeys.add k
    for k in t0.keys:
      if k in mergedKeys and isGlobal(k): continue    # keep one copy of a shared global
      createDir parentDir(merged / k)
      copyFile(t0.dir / k, merged / k)
      if k notin mergedKeys: mergedKeys.add k
    mergedKeys.sort()
    var mergedTree = Tree(dir: merged, label: "merged", keys: mergedKeys)
    # a registry that knows BOTH chains — which is what "ingest into one tree"
    # produces, and the only tree shape that can legitimately rewrite a global.
    let regKey = mergedTree.registryKeyOf()
    if regKey.len > 0:
      var j = parseJson(readFile(t0.dir / regKey))
      let jb = parseJson(readFile(treeB.dir / regKey))
      if j.hasKey("chains") and jb.hasKey("chains"):
        for name, row in jb["chains"]:
          j["chains"][name] = row
      mergedTree.writeKey(regKey, j.pretty & "\n")
    var b2Refused = false
    var b2Msg = ""
    try:
      discard publishTree(storeD, merged, optsA)
    except PublishError as e:
      b2Refused = true; b2Msg = e.msg
    result.ledger.record(dimInvariant, "global-pointer-no-chain-loss/accepts",
      "B2: merged tree naming " & $mergedTree.chainsOf().len & " chain(s) → " &
      (if b2Refused: "REFUSED" else: "accepted"))
    if b2Refused:
      result.fail("invariant/global-pointer-no-chain-loss-accepts",
        "a legitimate whole-site tree was refused",
        "The tree published here knows every chain the store holds and its " &
        "registry names all of them — it is exactly the tree the remedy for " &
        "B1 tells an operator to build. It was refused with:\n    " & b2Msg &
        "\n  A guard proven only in the refusing direction is half-tested, and " &
        "this is the expensive half: it stops the pipeline on the good path.")
    else:
      let finalGlobals = globalSnapshot(storeD)
      var stillLost: seq[string] = @[]
      for k, blob in finalGlobals:
        for c in chainsWithDataIn(storeD):
          if not mentions(blob, c) and k.startsWith("registry/"):
            stillLost.add k & " (does not name " & c & ")"
      if stillLost.len > 0:
        result.fail("invariant/global-pointer-no-chain-loss",
          "the whole-site tree published and a registry still omits a chain",
          stillLost.join("\n    "))

  # ══ C. two generations ════════════════════════════════════════════════════
  if haveTwoGenerations:
    result.scenariosRun.add "C1 a second generation over the first"
    let storeE = newLocalObjectStore(work / "storeE")
    discard publishTree(storeE, t0.dir, optsA)
    let oldGens = t0.generationsOf(c0)
    let oldGen = if oldGens.len > 0: oldGens[0] else: ""
    let sealKey = "d/" & c0 & "/g/" & oldGen & "/root.json"
    let (sealBefore, sealOk) = storeE.get(sealKey)
    discard publishTree(storeE, treeG.dir, optsA)
    let (sealAfter, sealOkAfter) = storeE.get(sealKey)
    if sealOk and (not sealOkAfter or sealAfter != sealBefore):
      result.fail("scenario/C1", "a sealed generation did not survive the next flip",
        sealKey & " changed or disappeared when generation '" & genB & "' was " &
        "published. §2.9 lists `/d/{chain}/g/{gen}/**` as immutable and cached " &
        "for a year: a client holding the old bytes would be right to.")
    let (cur, curOk) = storeE.get(curKey)
    let nowGen = if curOk: parseJson(cur){"generation"}.getStr else: ""
    if nowGen != genB:
      result.fail("scenario/C1", "the pointer did not move to the new generation",
        "expected '" & genB & "', `current.json` says '" & nowGen & "'.")

  result
