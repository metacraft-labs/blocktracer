## rehearse/corpus.nim — what a rehearsal is run OVER: producer trees, the
## partial selection that keeps one small without making it blind, and the two
## derivations that construct a situation the corpus cannot supply.
##
## ## Partial selection, and why it is bucketed rather than sampled
##
## `--mode partial` has to answer one question: which subset of a tree can
## exhibit every failure the whole tree can? Uniform sampling cannot answer it
## — a 1% sample of a tree whose `ocAsset` objects are 0.01% of the total misses
## that class about nine times in ten, and misses it SILENTLY, which is the
## property that makes a small rehearsal worthless rather than merely small.
##
## So the selection is **bucketed by the things the publish path branches on**
## — `(class, chain, generation)` — and takes a fixed number from each bucket,
## spread across that bucket's sorted keys so the first and the last are always
## in. The bucket set is O(classes × chains × generations), which does not grow
## with the chain; the per-bucket count is a constant. A partial tree is
## therefore **bounded**, and bounded in a way that is independent of whether
## the chain has 74 thousand blocks or 74 million.
##
## Some objects are never sampled and always taken: `current.json` (it IS the
## flip), `registry/**` (it is the only thing that lists a chain), the site-root
## pointers, `idx/**/meta.json`, and each generation's `root.json`. There are
## O(chains + generations + index shards) of them, they are the objects whose
## write ORDER is load-bearing, and sampling the one object a whole cycle is
## ordered around would be a strange economy.
##
## ## A partial tree is deliberately NOT referentially closed
##
## `d/{chain}/g/{gen}/root.json` lists every map it seals, and a partial tree
## keeps the root while dropping most of the maps — so the root names objects
## that are not there. That is correct for this tool and worth saying plainly:
## the publisher never dereferences an object it uploads, so a dangling
## reference cannot change any decision it makes. What such a tree WOULD break
## is a consumer reading it, which is a different tool's question
## (`blocktracer-client-conformance`) asked of a different artefact (a whole
## tree). Mixing the two would produce a rehearsal that is neither.
##
## ## The derivations
##
## Two cardinality cells cannot be satisfied by a corpus that does not already
## have the shape, and the shapes are exactly the ones that hid the 2026-09-28
## defect:
##
##   * **a second chain, in a SEPARATE tree.** The registry bug needs two
##     producer trees each carrying a registry that names only its own chain.
##     `deriveChainTree` builds the second by re-keying a copy.
##   * **a second generation.** `deriveGenerationTree` copies a generation to a
##     new number and moves `current.json` onto it.
##
## Both are DERIVATIONS and are labelled as such in the coverage report's
## witness column, because a cell satisfied by a construction and a cell
## satisfied by the operator's real corpus are different evidence and must not
## print the same. `--derive none` turns them off, which is how an operator asks
## "is my real corpus sufficient on its own?" — and gets a refusal naming
## exactly what it lacks.
##
## Neither derivation is a claim about data. A derived chain's block objects
## still say `"chain": "<the original>"` inside, and that is fine and left
## alone: the publish path is addressed by KEYS, the derivation moves keys, and
## rewriting bodies would be inventing a chain rather than constructing a
## publish situation.
##
## ## What the chain derivation CANNOT construct, stated rather than hidden
##
## `idx/hash/{version}/**` is the global hash index, built by
## `buildGlobalHashIndex` over **every chain at once**. A genuine second
## producer tree would carry a hash index computed over its own chain only, at
## the SAME keys — so publishing it would overwrite the first chain's index
## entries, which is the registry defect again in a second object. The
## derivation cannot construct that: it can move keys, and it cannot rebuild a
## binary index. It therefore copies those shards byte-for-byte, and the
## `global-pointer-no-chain-loss` invariant is **vacuous over `idx/hash/**`
## when the second chain is derived** — identical bytes cannot lose anything.
##
## It is not vacuous over the registry, which the derivation DOES reduce to one
## chain, and that is the object the measured defect was in. A corpus of two
## real trees (`--tree A --tree B`) makes the whole invariant non-vacuous, which
## is the reason `--tree` is repeatable and the reason the report distinguishes
## a cell met by the corpus from one met by a derivation.

import std/[algorithm, json, os, sequtils, strutils, tables]

import ../publish/publisher

type
  Mode* = enum
    rmPartial = "partial"
    rmFull = "full"

  Tree* = object
    ## A materialised producer tree in the rehearsal's scratch area. Every file
    ## is a hardlink to the operator's tree until something writes to it, so
    ## materialising a 460k-object tree costs directory entries and no bytes,
    ## and the operator's tree can never be modified by a drill.
    dir*: string
    label*: string
    keys*: seq[string]

  Derivation* = object
    what*: string
    why*: string

const siteRootKeys = ["index.html", "sitemap.xml", "robots.txt", "404.html"]

proc treeKeys*(dir: string): seq[string] =
  ## Tree-relative keys, sorted, excluding the publisher's lease namespace and
  ## the temp files an interrupted write leaves behind.
  for p in walkDirRec(dir):
    let rel = p.relativePath(dir).replace('\\', '/')
    if rel.startsWith("_leases/"): continue
    if ".tmp." in rel: continue
    result.add rel
  result.sort()

func chainOf*(key: string): string =
  ## Which chain a key belongs to, or "" for a key no single chain owns.
  ##
  ## ONLY `d/{chain}/…` AND `src/{chain}/…` NAME A CHAIN HERE, and the reason
  ## is a measured one. The first version of this function also read a
  ## top-level directory off an entry page — `{chain}/tx/…/index.html` — which
  ## is the layout, and which is ALSO the layout of `about/index.html`,
  ## `chains/index.html` and every other static page the site carries. Run
  ## against the real 878-object publish tree, the drill picked `about` as the
  ## corpus's first chain and then produced three confident findings about the
  ## lease, the resume and the pointer flip, all of them false, all of them
  ## downstream of that one word. A chain is a thing with data under `d/`;
  ## everything else is a directory that happens to be at the top level.
  let parts = key.split('/')
  if parts.len >= 2 and parts[0] == "d": return parts[1]
  if parts.len >= 2 and parts[0] == "src": return parts[1]
  ""

func chainsIn*(keys: openArray[string]): seq[string] =
  ## The chains a corpus declares, by the same rule `publisher.discoverChains`
  ## uses: a directory under `d/`. Asking the tree rather than inferring from a
  ## page's URL is the difference between three chains and eight.
  for k in keys:
    let parts = k.split('/')
    if parts.len >= 3 and parts[0] == "d" and parts[1] notin result:
      result.add parts[1]
  result.sort()

func generationOf*(key: string): string =
  ## `d/{chain}/g/{gen}/…` → `{gen}`. The indices are 0=d, 1=chain, 2=g, 3=gen;
  ## they were off by one in the first version of this file and the effect was
  ## silent and total — every key reported generation "", so the whole corpus
  ## fell into one bucket per class and `cardinality/generations` could never
  ## be satisfied by a real corpus. It is written out here because an off-by-one
  ## in a path index produces no error, only a coverage dimension that quietly
  ## stops existing.
  let parts = key.split('/')
  if parts.len >= 5 and parts[0] == "d" and parts[2] == "g": return parts[3]
  ""

func familyOf*(key: string): string =
  ## The layout's own sub-kind, one level below the class.
  ##
  ## `classOf` deliberately lumps `block/`, `tx/`, `ts/` and `seg/` into
  ## `ocContent` — they share an upload strategy, which is all the publisher
  ## needs to know. A SELECTOR needs more: bucketing by class alone put all
  ## four in one bucket, and a three-key sample of that bucket picked no `seg/`
  ## object at all, so `cardinality/address-ranges` went unmet on a corpus that
  ## carries 36 of them. The bucket must be as fine as the contract's questions.
  ##
  ## Read off the layout rather than listed, so a producer that starts emitting
  ## a new sub-kind gets its own bucket without an edit here.
  let parts = key.split('/')
  if parts.len >= 3 and parts[0] == "d":
    if parts[2] == "g": return "g/" & (if parts.len >= 6: parts[4] else: "root")
    return parts[2]
  if parts.len >= 2 and parts[0] == "idx": return "idx/" & parts[1]
  if parts.len >= 2 and parts[0] in ["src", "t", "assets", "_a", "registry"]:
    return parts[0]
  if parts.len >= 2 and key.endsWith(".html"): return "page/" & parts[1]
  ""

func isGlobal*(key: string): bool = chainOf(key).len == 0

func isMandatory(key: string): bool =
  ## Never sampled away. See the header.
  if classOf(key) == ocCurrent: return true
  if key.startsWith("registry/"): return true
  if key in siteRootKeys: return true
  if key.startsWith("idx/") and key.endsWith("meta.json"): return true
  if key.endsWith("/root.json") and "/g/" in key: return true
  false

func spread(n, k: int): seq[int] =
  ## `k` indices spread over `0 ..< n`, first and last always included. Spread
  ## and not random: a rehearsal that selects differently every run is a
  ## rehearsal whose green is not reproducible, and a failure nobody can
  ## re-observe is a failure nobody fixes.
  if n <= 0: return
  if k >= n:
    return toSeq(0 ..< n)
  if k <= 1: return @[0]
  var seen: seq[int] = @[]
  for i in 0 ..< k:
    let idx = (i * (n - 1)) div (k - 1)
    if seen.len == 0 or seen[^1] != idx: seen.add idx
  seen

proc selectKeys*(all: seq[string], mode: Mode, perBucket: int): seq[string] =
  ## The whole of `--mode`. `full` is every key; `partial` is the bucketed
  ## selection. Both go through the same coverage contract afterwards, and
  ## **full can fail it too** — a full rehearsal of a one-chain corpus is blind
  ## in exactly the place the 290-object one was, and 460,589 objects do not
  ## make it less blind.
  if mode == rmFull: return all
  var buckets = initOrderedTable[string, seq[string]]()
  for k in all:
    if isMandatory(k):
      result.add k
      continue
    let b = $classOf(k) & "|" & familyOf(k) & "|" & chainOf(k) & "|" & generationOf(k)
    buckets.mgetOrPut(b, @[]).add k
  for _, bucket in buckets:
    # Sorted by LAST PATH ELEMENT before spreading, so the two extremes taken
    # are extremes of the thing that varies within the bucket. For `seg/` the
    # last element is the block range (`90-90.json`), so this guarantees the
    # lowest and the highest range are both selected — which is precisely the
    # `cardinality/address-ranges` question. For a bucket whose last element is
    # a hash it changes nothing, so it costs nothing where it does not help.
    var keys = bucket
    keys.sort(proc(a, b: string): int =
      let fa = extractFilename(a)
      let fb = extractFilename(b)
      if fa != fb: cmp(fa, fb) else: cmp(a, b))
    for i in spread(keys.len, perBucket):
      result.add keys[i]
  result.sort()
  result = result.deduplicate(isSorted = true)

proc linkAs(srcDir, dstDir, srcKey, dstKey: string) =
  let src = srcDir / srcKey
  let dst = dstDir / dstKey
  createDir parentDir(dst)
  if fileExists(dst): removeFile(dst)
  try:
    createHardlink(src, dst)
  except CatchableError:
    copyFile(src, dst)

proc linkInto(srcDir, dstDir, key: string) = linkAs(srcDir, dstDir, key, key)

proc materialise*(srcDir, dstDir, label: string, keys: seq[string]): Tree =
  ## Hardlink `keys` from the operator's tree into a scratch tree.
  removeDir dstDir
  createDir dstDir
  for k in keys: linkInto(srcDir, dstDir, k)
  Tree(dir: dstDir, label: label, keys: keys)

proc writeKey*(t: Tree, key, data: string) =
  ## Copy-on-write. The target is a HARDLINK to the operator's file, so writing
  ## through it would corrupt their tree; the link is broken first. This is the
  ## one place a drill can reach the operator's data, so it is the one place
  ## that unlinks before it writes rather than opening for truncation.
  let p = t.dir / key
  if fileExists(p): removeFile(p)
  createDir parentDir(p)
  writeFile(p, data)

proc readKey*(t: Tree, key: string): string = readFile(t.dir / key)

proc chainsOf*(t: Tree): seq[string] = chainsIn(t.keys)

proc generationsOf*(t: Tree, chain: string): seq[string] =
  for k in t.keys:
    if chainOf(k) == chain:
      let g = generationOf(k)
      if g.len > 0 and g notin result: result.add g
  result.sort()

proc indexShardsOf*(t: Tree): seq[string] =
  for k in t.keys:
    if classOf(k) == ocIndexShard and k notin result: result.add k

proc addressRangesOf*(t: Tree): seq[string] =
  ## `d/{chain}/seg/{shard}/{address}/{from}-{to}.json` — the RANGE component,
  ## which is what is distinct between two segments of one address. Read off
  ## the last path element so nothing here assumes the shard depth any
  ## particular chain's encoding produces.
  for k in t.keys:
    if not k.contains("/seg/"): continue
    let r = extractFilename(k)
    if r notin result: result.add r
  result.sort()

proc registryKeyOf*(t: Tree): string =
  ## Whatever `registry/chains.v*.json` the tree carries. The contract version
  ## lives in the filename and this module holds no constant for it, so the
  ## tree is asked rather than told.
  for k in t.keys:
    if k.startsWith("registry/chains.v") and k.endsWith(".json"): return k
  ""

# ---------------------------------------------------------------------------
# The derivations.
# ---------------------------------------------------------------------------

proc deriveChainTree*(src: Tree, dstDir, oldChain, newChain: string): Tree =
  ## A SECOND producer tree, holding the same data re-keyed onto `newChain`,
  ## with a registry that names only `newChain`.
  ##
  ## That last clause is the whole point and is not an oversight: two chains
  ## ingested into two trees each produce a registry holding one chain, and
  ## that is the input that lost data. A derivation that helpfully merged the
  ## registry would construct the situation the defect is absent from.
  removeDir dstDir
  createDir dstDir
  var keys: seq[string] = @[]
  for k in src.keys:
    var nk = k
    if k.startsWith("d/" & oldChain & "/"): nk = "d/" & newChain & k[(2 + oldChain.len) .. ^1]
    elif k.startsWith("src/" & oldChain & "/"): nk = "src/" & newChain & k[(4 + oldChain.len) .. ^1]
    elif k.startsWith("idx/" & oldChain & "/"): nk = "idx/" & newChain & k[(4 + oldChain.len) .. ^1]
    elif k.startsWith(oldChain & "/"): nk = newChain & k[oldChain.len .. ^1]
    # Linked STRAIGHT to the new key rather than linked-then-moved, so the
    # derived tree never holds a directory belonging to the original chain —
    # a husk under `d/{oldChain}/` would make this tree look like a two-chain
    # tree to `discoverChains`, which is the exact opposite of what it is for.
    linkAs(src.dir, dstDir, k, nk)
    keys.add nk
  keys.sort()
  result = Tree(dir: dstDir, label: src.label & "→" & newChain, keys: keys)

  # `current.json` must name the chain it now sits under, or the publisher
  # resumes a sync state against a slug the store does not have.
  let cur = "d/" & newChain & "/current.json"
  if fileExists(dstDir / cur):
    var j = parseJson(readFile(dstDir / cur))
    j["chain"] = %newChain
    result.writeKey(cur, j.pretty & "\n")

  # a registry holding exactly one chain: the derived one.
  let reg = result.registryKeyOf()
  if reg.len > 0:
    var j = parseJson(readFile(dstDir / reg))
    if j.hasKey("chains") and j["chains"].hasKey(oldChain):
      let row = j["chains"][oldChain]
      j["chains"] = newJObject()
      j["chains"][newChain] = row
      result.writeKey(reg, j.pretty & "\n")

proc deriveGenerationTree*(src: Tree, dstDir, chain, oldGen, newGen: string): Tree =
  ## A tree whose chain has advanced one generation: `g/{oldGen}` is kept (a
  ## sealed generation is immutable and must survive), `g/{newGen}` is its copy,
  ## and `current.json` names the new one.
  removeDir dstDir
  createDir dstDir
  let oldPrefix = "d/" & chain & "/g/" & oldGen & "/"
  let newPrefix = "d/" & chain & "/g/" & newGen & "/"
  var keys: seq[string] = @[]
  for k in src.keys:
    linkInto(src.dir, dstDir, k)
    keys.add k
    if k.startsWith(oldPrefix):
      let nk = newPrefix & k[oldPrefix.len .. ^1]
      linkAs(src.dir, dstDir, k, nk)
      keys.add nk
  keys.sort()
  result = Tree(dir: dstDir, label: src.label & "@g" & newGen, keys: keys)

  # The generation root names its own generation; a copy that still says the
  # old number is a root that seals somebody else's maps.
  let root = newPrefix & "root.json"
  if fileExists(dstDir / root):
    var j = parseJson(readFile(dstDir / root))
    j["generation"] = %newGen
    if j.hasKey("maps"):
      # rewrite the map paths so the root points into its own generation
      proc remap(n: JsonNode): JsonNode =
        case n.kind
        of JString: %n.getStr.replace(oldPrefix, newPrefix)
        of JArray:
          let a = newJArray()
          for e in n: a.add remap(e)
          a
        of JObject:
          let o = newJObject()
          for k2, v in n: o[k2] = remap(v)
          o
        else: n
      j["maps"] = remap(j["maps"])
    result.writeKey(root, j.pretty & "\n")

  let cur = "d/" & chain & "/current.json"
  if fileExists(dstDir / cur):
    var j = parseJson(readFile(dstDir / cur))
    j["generation"] = %newGen
    result.writeKey(cur, j.pretty & "\n")
