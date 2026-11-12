## tests/test_solana_staging.nim — Solana's three staging properties, over the
## REAL Solana tree.
##
## Recorder-Solana CXP-SOL-6 names three verifications that were checked by hand
## on staging on 2026-10-22 and had no automated arm:
##
##   * `test_base58_identifiers_survive_with_case_intact` — a signature and an
##     address resolve through a locally recomputed shard path and through the
##     route, and the same identifiers lowercased do not;
##   * `test_outside_the_cleared_range_the_button_refuses` — a transaction below
##     the published floor offers no trace, while one inside it has its page;
##   * `test_solana_is_absent_from_productions_surfaces` — Solana is on staging's
##     inventory, routes, sitemap and search scope, and on none of production's.
##
## ## The tree is produced here, not committed
##
## It is `produce-sol-snapshot.mjs`, the program `tools/chain/nix/sol.nix` builds
## the published tree with, over the same committed capture
## (`fixtures/chain-inputs/solana-mainnet/`), including the address-history
## sidecar that capture carries. Then it is ingested by the real ingest. No
## recorder is built here, so the window's 13 replayed rows arrive as
## `no-container-written` refusals and no trace is published: the same shape
## `tidentifierencoding`'s Solana arm grades. That is this file's LIMIT, stated
## rather than left to be noticed. The control for the floor is an in-window
## transaction that HAS a page, not one that steps. That 13 of them step and
## match is graded by `nix build .#sol-capture-tree`, which replays the
## committed bundles through the recorder.
##
## ## Production's composition is rebuilt, not assumed
##
## `packages.default` exports `client/fixtures/chain/*`, and `site-staging` is
## the same build with `produced-captures` copied in beside them
## (`flake.nix`). So "production" below is every committed fixture chain
## ingested the way `static_export.nim` ingests them, and "staging" is the same
## plus the produced Solana snapshot. Each omission arm first requires the
## surface to name a chain production DOES carry: an empty surface omits every
## chain, which is how an omission check passes about nothing
## (`test_chain_origins.nim` states the same rule).
##
## It REFUSES RATHER THAN SKIPS when node or the producer is unavailable, for
## the reason `tidentifierencoding.nim` gives: a measurement that silently did
## not happen is the self-pass the testing policy bans.

import std/[unittest, os, json, strutils, osproc, algorithm]

import ../src/ssr
import ../src/reader
import blocktracer/chain/ingest
import blocktracer/contract/shards
import blocktracer/contract/version

const
  Chain = "solana-mainnet"
  PublishedSlot = "459262601"   ## the one slot `tools/chain/nix/sol.nix` publishes

let
  clientRoot = currentSourcePath().parentDir.parentDir
  repoRoot = clientRoot.parentDir
  solanaInputs = repoRoot / "fixtures" / "chain-inputs" / Chain /
                 "459262600-459262602"
  chainFixtures = clientRoot / "fixtures" / "chain"
  scratch = getTempDir() / ("bt-solstaging-" & $getCurrentProcessId())

var asserted = 0
template ck(c: untyped) =
  inc asserted
  check c

proc run(cmd, what: string) =
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0,
    what & " failed (exit " & $code & "): " & output &
    " — exit 127 is node missing from PATH, which in this repository means " &
    "the devshell was not entered."

proc produceSolana(): string =
  ## The real producer over the committed capture, into `scratch`.
  let capture = scratch / "capture"
  result = scratch / "snapshot"
  run("cd " & quoteShell(repoRoot) & " && node tools/chain/sol-fixture.mjs " &
      "unpack --fixture " & quoteShell(solanaInputs) & " --out " &
      quoteShell(capture), "unpacking the committed Solana window")
  doAssert dirExists(capture / "history"),
    "the committed capture carries no address-history sidecar, so the floor " &
    "suite would grade a tree with nothing below its floor"
  # Provenance only; read from the lock that pins the recorder, as
  # tidentifierencoding does, so it cannot go stale.
  let rev = parseJson(readFile(repoRoot / "flake.lock")){"nodes"}{
    "codetracer-solana-recorder"}{"locked"}{"rev"}.getStr
  doAssert rev.len == 40, "flake.lock does not pin codetracer-solana-recorder"
  let ctPrint =
    if getEnv("CT_PRINT").len > 0: " --ct-print " & quoteShell(getEnv("CT_PRINT"))
    else: ""
  run("cd " & quoteShell(repoRoot) & " && node tools/chain/produce-sol-snapshot.mjs " &
      "--capture " & quoteShell(capture) & ctPrint & " --recorder-commit " & rev &
      " --from " & PublishedSlot & " --to " & PublishedSlot & " --out " &
      quoteShell(result), "the real Solana producer")

proc committedFixtures(): seq[string] =
  ## Every snapshot `static_export.nim` would ingest, in its order.
  for kind, path in walkDir(chainFixtures):
    if kind == pcDir and fileExists(path / "snapshot.json"):
      result.add path
  result.sort()

proc ingestAll(outDir: string, snapshots: seq[string]) =
  ## The export's call, scope and order (`static_export.exportSite`).
  createDir outDir
  for s in snapshots:
    discard ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: s,
                                        scope: isCuratedIfWhole))

proc registryChains(tree: string): seq[string] =
  let reg = parseJson(readFile(tree / "registry" /
                               ("chains.v" & $ContractVersion & ".json")))
  for slug, _ in reg["chains"]: result.add slug
  result.sort()

doAssert scratch.lastPathPart.startsWith("bt-solstaging-")
removeDir scratch
createDir scratch

let
  solSnapshotDir = produceSolana()
  snap = parseJson(readFile(solSnapshotDir / "snapshot.json"))
  stagingTree = scratch / "staging"
  productionTree = scratch / "production"
  production = committedFixtures()

doAssert production.len > 0,
  "no committed fixture chain under " & chainFixtures & " — production would " &
  "be an empty site, and every omission below would hold vacuously"
ingestAll(productionTree, production)
ingestAll(stagingTree, production & @[solSnapshotDir])

let
  staging = newDataRoot(stagingTree)
  prod = newDataRoot(productionTree)
  floorAt = snap["window"]["replayableFrom"].getInt

# ── the subjects, chosen from the SNAPSHOT and not from the tree ───────────
#
# A test that asked the reader which identifiers exist would agree with itself
# about a tree it had misread.
var signature = ""
for t in snap["transactions"]:
  let h = t["txHash"].getStr
  if h.toLowerAscii != h:
    signature = h
    break
var historyAddr = ""
var below: seq[JsonNode]
for a in snap{"addressHistory"}:
  if a["entries"].len > 0 and a["address"].getStr.toLowerAscii != a["address"].getStr:
    historyAddr = a["address"].getStr
    for e in a["entries"]: below.add e
    break
var inWindow: seq[string]
for t in snap["transactions"]:
  if historyAddr.len > 0 and historyAddr in $t:
    inWindow.add t["txHash"].getStr

suite "the subjects exist, so no arm below grades an empty set":
  test "a mixed-case signature, an address with history below the floor, and its in-window rows":
    ck signature.len > 0
    ck historyAddr.len > 0
    ck below.len > 0
    ck inWindow.len > 0

# ───────────────────────────────────────────────────────────────────────────
suite "base58 identifiers keep their case through the shard path and the route":
  # The shard DIRECTORY is case-folded and the NAME is not
  # (`tidentifierencoding`'s "a case-significant identifier keeps its case, and
  # its BUCKET does not"). So the lowercased name lands in the SAME directory,
  # and its absence there is attributable to the name alone.
  test "a signature's object sits at the recomputed path under its own case":
    let lowered = signature.toLowerAscii
    let shard = shardKeyFor("base58", signature)
    ck shard == shardKeyFor("base58", lowered)
    let objectPath = stagingTree / "d" / Chain / "tx" / shard / (signature & ".json")
    ck fileExists(objectPath)
    ck parseJson(readFile(objectPath))["id"]["hash"].getStr == signature
    ck not fileExists(stagingTree / "d" / Chain / "tx" / shard / (lowered & ".json"))

  test "the signature's route renders, and its lowercased form is not found":
    let page = renderRoute(staging, "/" & Chain & "/tx/" & signature & "/")
    ck page.status == 200
    ck signature in page.body
    ck renderRoute(staging, "/" & Chain & "/tx/" & signature.toLowerAscii & "/").status == 404

  test "an address's route renders, and its lowercased form is not found":
    let page = renderRoute(staging, "/" & Chain & "/address/" & historyAddr & "/")
    ck page.status == 200
    ck historyAddr in page.body
    ck renderRoute(staging, "/" & Chain & "/address/" &
                   historyAddr.toLowerAscii & "/").status == 404

# ───────────────────────────────────────────────────────────────────────────
suite "below the floor a transaction is listed and offers no trace":
  # On Solana a transaction below the floor reaches a reader in exactly one
  # place: an address's chain history (`getSignaturesForAddress`), which the
  # producer fetched BELOW the window and the ingest publishes as the address's
  # oldest segment. The window itself starts at the floor, so no published row
  # is below it.
  let info = chainInfo(staging, Chain)
  let listed = addressSegmentPaths(staging, info, historyAddr)
  let oldest = readAddressSegment(info, listed.paths[^1])
  let newest = readAddressSegment(info, listed.paths[0])
  let oldestId = listed.paths[^1].lastPathPart.changeFileExt("")
  let newestId = listed.paths[0].lastPathPart.changeFileExt("")

  test "the floor on the registry row is the window's own replay boundary":
    let row = parseJson(readFile(stagingTree / "registry" /
      ("chains.v" & $ContractVersion & ".json")))["chains"][Chain]
    ck row["historyFloor"]["height"].getInt == floorAt
    ck $PublishedSlot == $floorAt

  test "every history entry is below the floor, and none is a row of the window":
    ck oldest.transactions.len == 0
    ck oldest.untraced.len == below.len
    var allBelow = true
    for e in oldest.untraced:
      if e.blockNumber >= floorAt or e.txHash in inWindow: allBelow = false
    ck allBelow

  test "the history lists each entry and links none of them, saying why":
    let body = renderAddress(staging, Chain, historyAddr, oldestId)
    var listedAll, linkedAny = true
    linkedAny = false
    for e in oldest.untraced:
      if e.txHash notin body: listedAll = false
      if ("/tx/" & e.txHash) in body: linkedAny = true
    ck listedAll
    ck not linkedAny
    ck "were not replayed here, so none of them opens a trace" in body
    # …and no page exists for one to land on.
    ck renderRoute(staging, "/" & Chain & "/tx/" & oldest.untraced[0].txHash &
                   "/").status == 404

  test "CONTROL: the same address's in-window rows link to pages that exist":
    let body = renderAddress(staging, Chain, historyAddr, newestId)
    ck newest.transactions.len > 0
    var linkedAll, pagesExist = true
    for h in newest.transactions:
      if ("/tx/" & h) notin body: linkedAll = false
      if renderRoute(staging, "/" & Chain & "/tx/" & h & "/").status != 200:
        pagesExist = false
    ck linkedAll
    ck pagesExist

# ───────────────────────────────────────────────────────────────────────────
suite "Solana is on staging's surfaces and on none of production's":
  let prodChains = registryChains(productionTree)
  let control = prodChains[0]

  test "the registries: production carries a chain, and not this one":
    ck prodChains.len > 0
    ck Chain notin prodChains
    ck Chain in registryChains(stagingTree)
    ck control in registryChains(stagingTree)

  test "the inventory":
    let p = renderRoute(prod, "/chains").body
    let s = renderRoute(staging, "/chains").body
    ck control in p and Chain notin p
    ck control in s and Chain in s

  test "the route enumeration and the chain's own page":
    proc names(rs: seq[string], slug: string): bool =
      for r in rs:
        if r.startsWith("/" & slug & "/") or r == "/" & slug: return true
    let p = staticRoutes(prod)
    let s = staticRoutes(staging)
    ck names(p, control) and not names(p, Chain)
    ck names(s, control) and names(s, Chain)
    ck renderRoute(prod, "/" & Chain & "/").status == 404
    ck renderRoute(staging, "/" & Chain & "/").status == 200

  test "the sitemap":
    proc names(rs: seq[string], slug: string): bool =
      for r in rs:
        if ("/" & slug & "/") in r or r.endsWith("/" & slug): return true
    let p = sitemapRoutes(prod)
    let s = sitemapRoutes(staging)
    ck names(p, control) and not names(p, Chain)
    ck names(s, control) and names(s, Chain)

  test "search's chain scope":
    let p = renderRoute(prod, "/search").body
    let s = renderRoute(staging, "/search").body
    ck control in p and Chain notin p
    ck control in s and Chain in s

  test "assertion count":
    # Counted by reading the arms, term by term:
    #    4 — the subjects
    #    4 + 3 + 3 — the signature's path, its route, the address's route
    #    2 + 3 + 4 + 3 — the floor, the entries, the listing, the control
    #    4 + 2 + 4 + 2 + 2 — registries, inventory, routes, sitemap, search
    check asserted == 4 + (4 + 3 + 3) + (2 + 3 + 4 + 3) + (4 + 2 + 4 + 2 + 2)

removeDir scratch
