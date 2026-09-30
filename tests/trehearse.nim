## Self-test for `blocktracer-rehearse` — does the coverage gate BITE?
##
## A rehearsal that refuses is only worth something if it refuses the right
## things, and a coverage contract is only worth something if it is SATISFIABLE
## — a gate that can never be green gets turned off, and a gate that is always
## green measures nothing. So this suite asserts both ends:
##
##   * a HEALTHY corpus reaches every cell of the contract and produces no
##     finding. Without this the tool would be indistinguishable from one that
##     always refuses.
##   * each DELIBERATELY BROKEN corpus produces the specific finding it should,
##     and only that one.
##
## and, in between, the claim the whole tool rests on:
##
##   * `--mode partial` meets **the same set of cells** as `--mode full` over
##     the same corpus, at a fraction of the objects. That is the sufficiency
##     argument, measured rather than asserted.
##
## The unit blocks at the top cover three bugs that were IN this tool and were
## found by running it against a real 878-object publish tree rather than by
## reading it. Each produced confident, wrong output and no error:
##
##   * `chainOf` read a top-level directory off an entry page, so `about/` was
##     a chain; the drill then reported three false defects about the lease,
##     the resume and the pointer flip.
##   * `generationOf` indexed `d/{chain}/g/{gen}` one segment off, so every key
##     reported generation "" and the generation dimension silently vanished.
##   * `mentions` was a substring test, so a registry that had lost `demo`
##     still "mentioned" it via `demo-rehearsal-b` — the check passed on the
##     one input it was written for.

import std/[algorithm, json, os, sequtils, strutils, tables, unittest]

import ../src/blocktracer/publish/objectstore
import ../src/blocktracer/publish/publisher
import ../src/blocktracer/rehearse/corpus
import ../src/blocktracer/rehearse/coverage
import ../src/blocktracer/rehearse/drill
import ../src/blocktracer/rehearse/register

# ---------------------------------------------------------------------------
# A synthetic corpus: small, and carrying at least one object of every class
# `classOf` can emit, because that is what the contract asks for.
# ---------------------------------------------------------------------------

proc w(dir, key, data: string) =
  createDir parentDir(dir / key)
  writeFile(dir / key, data)

proc buildTree(dir, chain: string, gens: seq[string],
               registryChains: seq[string], extraKeys: seq[string] = @[]) =
  removeDir dir
  createDir dir
  # release assets — the one class the demo generator never emits
  w(dir, "assets/fonts/Test-Regular.woff2", "\x00\x01woff2-bytes")
  w(dir, "assets/hydrate.js", "// hydration bundle\n")
  # The site home — a WHOLE-SITE object, so it names every chain the tree's
  # registry does. An earlier fixture had it name only its own chain, and the
  # drill correctly reported the second tree's publish as losing the first
  # chain from `index.html`. That was the fixture being wrong and the check
  # being right, and it is written this way so the distinction stays visible.
  w(dir, "index.html",
    "<!doctype html><title>BlockTracer</title>" &
    registryChains.mapIt("<a href=\"/" & it & "\">" & it & "</a>").join(""))
  # entry pages
  w(dir, chain & "/tx/0xaa/index.html", "<!doctype html>tx page")
  w(dir, chain & "/block/0xbb/index.html", "<!doctype html>block page")
  # input-addressed trace container + its manifest
  let container = "CTFS\x00container-bytes-for-" & chain
  w(dir, "t/aa/bb/ccddeeff/trace.ct", container)
  w(dir, "t/aa/bb/ccddeeff/manifest.json",
    $(%*{"traceArtifactId": "ccddeeff",
         "container": {"hash": "sha256:deadbeef", "bytes": container.len}}) & "\n")
  # Immutable content. Enough of it that a partial selection is genuinely
  # smaller than the whole — a fixture where `--mode partial` selects every
  # object cannot demonstrate anything about partial selection.
  for i in 1 .. 12:
    let h = "0x" & align($i, 2, '0')
    w(dir, "d/" & chain & "/block/" & h & ".json",
      $(%*{"chain": chain, "height": i, "hash": h}) & "\n")
    w(dir, "d/" & chain & "/tx/" & h & "a.json",
      $(%*{"chain": chain, "hash": h & "a"}) & "\n")
    w(dir, "d/" & chain & "/ts/1/" & h & "a.json", $(%*{"overlay": 1}) & "\n")
  # two segment RANGES, so the cardinality cell is reachable
  w(dir, "d/" & chain & "/seg/aa/0xaaaa/1-1.json", $(%*{"from": 1, "to": 1}) & "\n")
  w(dir, "d/" & chain & "/seg/aa/0xaaaa/2-2.json", $(%*{"from": 2, "to": 2}) & "\n")
  # index shards (two) and the names-index pointer
  w(dir, "idx/hash/1/00.bin", "\x00shard-zero")
  w(dir, "idx/hash/1/01.bin", "\x00shard-one")
  w(dir, "idx/" & chain & "/names/meta.json", $(%*{"version": 1}) & "\n")
  # source bundle + its moving pointer
  w(dir, "src/" & chain & "/0xcode/0xbundle.json", $(%*{"files": []}) & "\n")
  w(dir, "src/" & chain & "/0xcode/current.json", $(%*{"bundle": "0xbundle"}) & "\n")
  # labels — a chain-scoped pointer, outside generations
  w(dir, "d/" & chain & "/labels/0.json", $(%*{"labels": {}}) & "\n")
  # generations
  for g in gens:
    w(dir, "d/" & chain & "/g/" & g & "/height/0.json",
      $(%*{"chain": chain, "epoch": 0, "heights": {"1": "0x01", "2": "0x02"}}) & "\n")
    w(dir, "d/" & chain & "/g/" & g & "/blocks/0.json",
      $(%*{"chain": chain, "epoch": 0, "blocks": ["0x01", "0x02"]}) & "\n")
    w(dir, "d/" & chain & "/g/" & g & "/root.json",
      $(%*{"contractVersion": 1, "chain": chain, "generation": g,
           "maps": {"height": ["d/" & chain & "/g/" & g & "/height/0.json"]}}) & "\n")
  # the visibility pointer, naming the last generation
  w(dir, "d/" & chain & "/current.json",
    $(%*{"chain": chain, "generation": gens[^1],
         "head": {"height": 2, "hash": "0x02"}}) & "\n")
  # the registry
  var chainsNode = newJObject()
  for c in registryChains:
    chainsNode[c] = %*{"recorder": {"id": "test"}, "traceSchema": "ctfs/v4",
                       "identifierEncoding": {"address": "hex", "block": "hex",
                                              "transaction": "hex"}}
  w(dir, "registry/chains.v1.json", $(%*{"version": 1, "chains": chainsNode}) & "\n")
  for k in extraKeys: w(dir, k, "extra\n")

proc scratch(name: string): string =
  result = getTempDir() / "bt-trehearse" / name
  removeDir result
  createDir result

proc runOver(trees: seq[string], name: string, mode = rmPartial,
             derive = true, perBucket = 3): DrillReport =
  var o = defaultDrillOptions()
  o.mode = mode
  o.derive = derive
  o.perBucket = perBucket
  o.workDir = scratch(name & "-work")
  runDrill(trees, o)

func findingIdsOf(r: DrillReport): seq[string] =
  result = r.findings.mapIt(it.id)
  result.sort()
  result = result.deduplicate(isSorted = true)

# ═══ units — the three bugs that were in this tool ═════════════════════════

suite "path reading: a chain is a directory under d/, not a top-level folder":
  test "chainsIn reads d/ and ignores static page directories":
    let keys = @["d/aztec/current.json", "d/aztec-testnet/current.json",
                 "about/index.html", "chains/index.html", "404.html",
                 "aztec/tx/0xaa/index.html"]
    check chainsIn(keys) == @["aztec", "aztec-testnet"]

  test "MUTATION BITE: reading the page directory instead would give four":
    # The defect this replaced, spelled out: the entry-page rule alone cannot
    # tell `aztec/tx/…` from `about/…`, and on the real publish tree it named
    # `about` as the corpus's first chain.
    let keys = @["about/index.html", "chains/index.html", "aztec/tx/0xaa/index.html"]
    var byPageDir: seq[string] = @[]
    for k in keys:
      let d = k.split('/')[0]
      if d notin byPageDir: byPageDir.add d
    check byPageDir.len == 3          # what the old rule saw
    check chainsIn(keys).len == 0     # what the tree actually declares

  test "generationOf indexes d/{chain}/g/{gen}, not one segment over":
    check generationOf("d/demo/g/7/root.json") == "7"
    check generationOf("d/demo/g/7/addr/aa/0xaa.json") == "7"
    check generationOf("d/demo/block/0x01.json") == ""
    check generationOf("idx/hash/1/00.bin") == ""

  test "familyOf splits ocContent into the sub-kinds the selector must see":
    # `classOf` calls all four `ocContent`; a selector bucketed on class alone
    # took three keys from a bucket of 78 and picked no `seg/` object at all.
    check familyOf("d/demo/block/0x01.json") == "block"
    check familyOf("d/demo/seg/aa/0xaa/1-1.json") == "seg"
    check familyOf("d/demo/tx/0xaa.json") == "tx"
    check classOf("d/demo/block/0x01.json") == classOf("d/demo/seg/aa/0xaa/1-1.json")

suite "mentions is a token test, because a substring test cannot see the loss":
  test "a chain named as a JSON key or a path segment is mentioned":
    check mentions("""{"chains":{"demo":{}}}""", "demo")
    check mentions("idx/demo/names/meta.json", "demo")
    check mentions("demo", "demo")

  test "MUTATION BITE: the superstring that defeated the substring version":
    # This is the exact input the first version got wrong: a registry that had
    # LOST `demo` and gained `demo-rehearsal-b` still contained the characters.
    let robbed = """{"chains":{"demo-rehearsal-b":{"recorder":{}}}}"""
    check "demo" in robbed            # the old test said: still there
    check not mentions(robbed, "demo")  # the token test says: gone

  test "real-corpus shape, not only the derived one":
    check not mentions("""{"chains":{"aztec-testnet":{}}}""", "aztec")
    check mentions("""{"chains":{"aztec-testnet":{},"aztec":{}}}""", "aztec")

# ═══ selection ═════════════════════════════════════════════════════════════

suite "partial selection is bounded and keeps what the contract asks about":
  setup:
    let dir = scratch("sel")
    buildTree(dir / "t", "demo", @["1", "2"], @["demo"])
    let all = treeKeys(dir / "t")

  test "every mandatory object survives the selection":
    let sel = selectKeys(all, rmPartial, 1)
    for k in all:
      if classOf(k) == ocCurrent or k.startsWith("registry/") or
         k == "index.html" or (k.startsWith("idx/") and k.endsWith("meta.json")) or
         (k.endsWith("/root.json") and "/g/" in k):
        check k in sel

  test "both segment ranges are selected, at per-bucket 2":
    let sel = selectKeys(all, rmPartial, 2)
    var ranges: seq[string] = @[]
    for k in sel:
      if "/seg/" in k and extractFilename(k) notin ranges:
        ranges.add extractFilename(k)
    check ranges.len >= 2

  test "partial is smaller than full and full is everything":
    check selectKeys(all, rmFull, 3) == all
    check selectKeys(all, rmPartial, 1).len < all.len

# ═══ the register, which must fail in BOTH directions ══════════════════════

suite "the known-findings register is not an exemption list":
  setup:
    let dir = scratch("reg")
    let path = dir / "known.json"
    proc writeRegister(body: JsonNode) =
      writeFile(path, $(%*{"known_findings": body}) & "\n")
    let full = %*{
      "reason": "r", "cause": "c", "subject": "s",
      "closed_by": "cb", "evidence": "e", "recorded": "2026-09-29"}

  test "a registered finding that OCCURS does not fail the run":
    writeRegister(%*{"invariant/x": full})
    let rec = reconcile(@["invariant/x"], loadRegister(path), path)
    check rec.clean()
    check rec.excused == @["invariant/x"]

  test "an UNREGISTERED finding fails":
    writeRegister(%*{})
    let rec = reconcile(@["invariant/x"], loadRegister(path), path)
    check not rec.clean()
    check rec.unregistered == @["invariant/x"]

  test "a registered finding that STOPS occurring fails, demanding deletion":
    writeRegister(%*{"invariant/x": full})
    let rec = reconcile(@[], loadRegister(path), path)
    check not rec.clean()
    check rec.stale == @["invariant/x"]

  test "an entry missing any of the six fields refuses the register":
    for missing in requiredFields:
      var partial = copy(full)
      partial.delete(missing)
      writeRegister(%*{"invariant/x": partial})
      let rec = reconcile(@["invariant/x"], loadRegister(path), path)
      check not rec.clean()
      check rec.malformed.len == 1
      check missing in rec.malformed[0]

  test "the register this repository ships is well-formed":
    let shipped = currentSourcePath().parentDir.parentDir /
                  "tools" / "rehearse" / "known-findings.json"
    check fileExists(shipped)
    check malformedEntries(shipped).len == 0

# ═══ the healthy corpus: the contract is SATISFIABLE ═══════════════════════

suite "a healthy corpus meets every cell and produces no finding":
  setup:
    # Two chains arriving as TWO producer trees, each carrying a registry that
    # names BOTH — which is the shape "ingest every chain into one tree" makes,
    # and the only tree shape that may legitimately rewrite a global object.
    let dir = scratch("healthy")
    buildTree(dir / "a", "alpha", @["1", "2"], @["alpha", "beta"])
    buildTree(dir / "b", "beta", @["1", "2"], @["alpha", "beta"])

  test "full mode: 100% of the contract, zero findings":
    let r = runOver(@[dir / "a", dir / "b"], "healthy-full", rmFull)
    check r.findings.len == 0
    check r.ledger.unmet().len == 0

  test "partial mode meets THE SAME cells, on a fraction of the objects":
    # This is the tool's whole claim. It is checked as a set equality between
    # the two modes, not as a count: two runs can meet the same NUMBER of cells
    # and meet different ones.
    let full = runOver(@[dir / "a", dir / "b"], "same-full", rmFull)
    let part = runOver(@[dir / "a", dir / "b"], "same-part", rmPartial, perBucket = 2)
    var fullMet, partMet: seq[string] = @[]
    for id, c in full.ledger.cells:
      if c.hits > 0: fullMet.add id
    for id, c in part.ledger.cells:
      if c.hits > 0: partMet.add id
    fullMet.sort(); partMet.sort()
    check partMet == fullMet
    check part.findings.len == 0
    check part.objectsSelected < part.objectsConsidered

  test "no derivation was needed — the corpus supplied the shapes itself":
    let r = runOver(@[dir / "a", dir / "b"], "healthy-noderive", rmPartial,
                    derive = false)
    check r.derivations.len == 0
    check r.ledger.unmet().len == 0
    check r.findings.len == 0

# ═══ the broken corpora: each must be REFUSED, by name ═════════════════════

suite "a corpus whose trees each know only their own chain LOSES a chain":
  test "the registry clobber is found from a partial rehearsal":
    let dir = scratch("clobber")
    buildTree(dir / "a", "alpha", @["1", "2"], @["alpha"])   # registry: alpha only
    buildTree(dir / "b", "beta", @["1", "2"], @["beta"])     # registry: beta only
    let r = runOver(@[dir / "a", dir / "b"], "clobber", rmPartial)
    check "invariant/global-pointer-no-chain-loss" in r.findingIdsOf()
    # and it must say WHICH object and WHICH chain, not merely that it failed
    let f = r.findings.filterIt(it.id == "invariant/global-pointer-no-chain-loss")[0]
    check "registry/chains.v1.json" in f.detail
    check "alpha" in f.detail
    # the coverage cell is still MET: the property was measured, and was false.
    check r.ledger.cells[cellId(dimInvariant,
      "global-pointer-no-chain-loss/refuses")].hits > 0

suite "a corpus carrying an object no chain's cycle publishes":
  test "tree minus store is reported, with the shapes":
    let dir = scratch("orphan")
    buildTree(dir / "a", "alpha", @["1", "2"], @["alpha", "beta"],
              extraKeys = @["404.html", "about/index.html"])
    buildTree(dir / "b", "beta", @["1", "2"], @["alpha", "beta"])
    let r = runOver(@[dir / "a", dir / "b"], "orphan", rmFull)
    check "invariant/every-object-is-published" in r.findingIdsOf()
    let f = r.findings.filterIt(it.id == "invariant/every-object-is-published")[0]
    check "404.html" in f.detail

  test "MUTATION BITE: without those two keys the same corpus is clean":
    let dir = scratch("orphan-control")
    buildTree(dir / "a", "alpha", @["1", "2"], @["alpha", "beta"])
    buildTree(dir / "b", "beta", @["1", "2"], @["alpha", "beta"])
    let r = runOver(@[dir / "a", dir / "b"], "orphan-control", rmFull)
    check "invariant/every-object-is-published" notin r.findingIdsOf()

suite "a corpus that emits no object of a class":
  test "an unexercised class is a FAILURE, not a percentage":
    let dir = scratch("noasset")
    buildTree(dir / "a", "alpha", @["1", "2"], @["alpha", "beta"])
    buildTree(dir / "b", "beta", @["1", "2"], @["alpha", "beta"])
    removeDir dir / "a" / "assets"
    removeDir dir / "b" / "assets"
    let r = runOver(@[dir / "a", dir / "b"], "noasset", rmFull)
    check cellId(dimClass, $ocAsset) in r.ledger.findingIds()
    check "ocAsset" in r.ledger.renderUnmet()

suite "--no-derive answers 'is my real corpus sufficient on its own?'":
  test "one chain in one tree cannot prove the cardinality the defect needs":
    let dir = scratch("onechain")
    buildTree(dir / "a", "alpha", @["1"], @["alpha"])
    let r = runOver(@[dir / "a"], "onechain", rmFull, derive = false)
    let miss = r.ledger.findingIds()
    check cellId(dimCardinality, "chains-in-separate-trees") in miss
    check cellId(dimCardinality, "generations") in miss
    check r.derivations.len == 0

  test "with derivation the same corpus reaches those cells, and says so":
    let dir = scratch("onechain-derived")
    buildTree(dir / "a", "alpha", @["1"], @["alpha"])
    let r = runOver(@[dir / "a"], "onechain-derived", rmFull, derive = true)
    let miss = r.ledger.findingIds()
    check cellId(dimCardinality, "chains-in-separate-trees") notin miss
    check cellId(dimCardinality, "generations") notin miss
    check r.derivations.len == 2
    # the provenance must be visible: a cell met by construction and one met by
    # the operator's corpus are different evidence and must not print the same.
    check "rehearsal-b" in
      r.ledger.cells[cellId(dimCardinality, "chains-in-separate-trees")].witness

suite "a store that accepts a write and does not keep it":
  test "the drill reaches the refusing side of the bulk confirmation":
    let dir = scratch("bulk")
    buildTree(dir / "a", "alpha", @["1", "2"], @["alpha", "beta"])
    buildTree(dir / "b", "beta", @["1", "2"], @["alpha", "beta"])
    let r = runOver(@[dir / "a", dir / "b"], "bulk", rmFull)
    let cell = r.ledger.cells[cellId(dimBranch, "bulk-confirm/refused")]
    check cell.hits > 0
    check "refused=true" in cell.witness
    check "scenario/A7" notin r.findingIdsOf()

suite "the drill never writes to the operator's tree":
  test "a tampered object is unlinked first, so the source is untouched":
    let dir = scratch("cow")
    buildTree(dir / "a", "alpha", @["1", "2"], @["alpha", "beta"])
    buildTree(dir / "b", "beta", @["1", "2"], @["alpha", "beta"])
    let ctPath = dir / "a" / "t/aa/bb/ccddeeff/trace.ct"
    let before = readFile(ctPath)
    # A4 tampers with exactly this object, and A5 with a block object.
    let blockPath = dir / "a" / "d/alpha/block/0x01.json"
    let blockBefore = readFile(blockPath)
    discard runOver(@[dir / "a", dir / "b"], "cow", rmFull)
    check readFile(ctPath) == before
    check readFile(blockPath) == blockBefore
