## Per-chain data origin — the seam that lets one environment render another's
## data, and lets ONE chain come from somewhere else.
##
## ## What is being decided, and why it is not a code-sharing question
##
## The operator's requirement is a sentence about the DEFAULT: "we'll typically
## show the production data while using only different software to display it."
## So the thing to build is not "staging gets a copy of the store" — that is the
## transitional case — but a resolution order in which showing production's data
## costs no configuration and a chain production does not carry is the exception
## that costs one line.
##
## Three resolution steps (`reader.storeFor`), and this suite drives each:
##
##   1. the chain's own override      — `withChainOrigin(chain, store)`
##   2. the deployment's data origin  — `withDataOrigin(store)`
##   3. the application origin        — no configuration at all
##
## ## Why every assertion here counts READS rather than reading a field
##
## `storeFor` returning the right store is not the property. The property is
## that every byte of a chain's page came from that store — the facts, the
## height map, the block, the trace, the source bundle — because a projection
## that resolved the origin once and then reached for `r.store` on the next
## line would satisfy a field assertion and serve one origin's transaction
## under another origin's generation. So each store here is wrapped in a
## `recordingStore` and the suite asserts on the PATHS each one was asked for,
## including the paths it was NOT asked for.
##
## ## The registry asymmetry, which is the containment property
##
## The registry is read from the APPLICATION origin and never from a per-chain
## one. That is what stops an environment acquiring a chain by being pointed at
## a tree that has one — and `a chain absent from the registry is not served`
## measures it. It also measures the thing that is easy to assume and is FALSE:
## the data of an unlisted chain is still fetchable BY PATH out of a shared
## store. Hiding a chain behind a registry omission is a linking control, not an
## access control, which is the reason a staging-only chain belongs in a
## separate store rather than in production's with no registry row.

import std/[unittest, json, strutils, tables]

import ../src/ssr
import ../src/reader

# ── synthetic trees, built from closures ───────────────────────────────────
#
# Not fixtures on disk: the question here is which STORE answered, and a
# directory would add a filesystem to a test about routing. Each tree is the
# minimum an `openChain` + a block walk needs, and the generation string is
# different per tree so "which origin served this chain" is observable in the
# rendered value and not only in a log.

type Tree = object
  objects: TableRef[string, string]

proc newTree(): Tree =
  Tree(objects: newTable[string, string]())

proc put(t: Tree, path: string, node: JsonNode) =
  t.objects[path] = $node

proc addChain(t: Tree, chain, generation, blockHash: string) =
  ## One chain, one generation, one block — enough to open, walk and render.
  t.put("d/" & chain & "/current.json", %*{
    "generation": generation,
    "traceSelectionVersion": "ts1",
    "head": {"height": 1, "hash": blockHash}})
  t.put("d/" & chain & "/g/" & generation & "/root.json", %*{
    "contractVersion": 1,
    "chain": chain,
    "generation": generation,
    "traceSelectionVersion": "ts1",
    "maps": {
      "summary": "d/" & chain & "/g/" & generation & "/summary.json",
      "height": ["d/" & chain & "/g/" & generation & "/height/0.json"],
      "addr": []}})
  t.put("d/" & chain & "/g/" & generation & "/summary.json", %*{
    "coverageMode": "selective",
    "stale": false,
    "counters": {"blocks": 1, "transactions": 0},
    "provenance": {"kind": "live-capture", "label": generation,
                   "detail": "synthesised for test_chain_origins"}})
  t.put("d/" & chain & "/g/" & generation & "/height/0.json", %*{
    "heights": {"1": blockHash}})
  t.put("d/" & chain & "/block/" & blockHash & ".json", %*{
    "chain": chain, "hash": blockHash, "height": 1,
    "parentHash": "", "transactions": []})

proc registryOf(t: Tree, chains: openArray[string]) =
  ## The signed inventory, listing exactly `chains`. The SDK reads it at
  ## `registry/chains.v1.json` and takes the chain set from its `chains` keys.
  var rows = newJObject()
  for c in chains:
    rows[c] = %*{
      "recorder": {"id": "test-recorder", "build": "blake3:0000", "version": "0"},
      "profile": {"name": "default", "hash": "blake3:1111"},
      "traceSchema": "1"}
  t.put("registry/chains.v1.json", %*{"schema": 1, "version": 1, "chains": rows})

proc store(t: Tree, name: string): ObjectStore =
  let objects = t.objects
  newObjectStore(name, proc(path: string): ObjectResponse =
    if objects.hasKey(path): ObjectResponse(found: true, body: objects[path])
    else: ObjectResponse(found: false))

proc watched(t: Tree, name: string): (ObjectStore, RequestLog) =
  let log = newRequestLog()
  (recordingStore(t.store(name), log), log)

proc touched(log: RequestLog, fragment: string): int =
  for p in log.paths:
    if fragment in p: inc result

# ---------------------------------------------------------------------------
suite "per-chain data origin — the default costs nothing":
# ---------------------------------------------------------------------------

  # ONE STORE, TWO CHAINS, NOTHING CONFIGURED — the shape of every build that
  # exists today, asserted to be unchanged by the seam that was added for the
  # builds that do not exist yet.
  let tree = newTree()
  tree.registryOf(["aztec", "aztec-testnet"])
  tree.addChain("aztec", "g-only", "0xaa")
  tree.addChain("aztec-testnet", "g-only-2", "0xbb")
  let (only, onlyLog) = tree.watched("the-one-origin")
  let root = newDataRoot("", only)

  test "no chain is configured, and every chain resolves to the one origin":
    check root.origins.len == 0
    check root.originName("aztec") == only.name
    check root.originName("aztec-testnet") == only.name
    # A chain nobody has ever heard of resolves too — the fallback is total,
    # so a chain added to the registry tomorrow needs no origin decision.
    check root.originName("a-chain-added-next-week") == only.name

  test "the registry, the pages and the walks all read from it":
    check chains(root) == @["aztec", "aztec-testnet"]
    for slug in chains(root):
      let info = chainInfo(root, slug)
      check info.store.name == only.name
      check blockHashes(root, info).len == 1
      check blocksFrom(root, info, -1).rows.len == 1
    check onlyLog.touched("d/aztec/") > 0
    check onlyLog.touched("d/aztec-testnet/") > 0
    check onlyLog.touched("registry/") > 0

  test "the generation each chain reports is the one this tree published":
    check chainInfo(root, "aztec").generation == "g-only"
    check chainInfo(root, "aztec-testnet").generation == "g-only-2"

# ---------------------------------------------------------------------------
suite "per-chain data origin — staging shows production, except for one chain":
# ---------------------------------------------------------------------------

  # THE OPERATOR'S ACTUAL DEPLOYMENT, as three stores:
  #
  #   app        the staging build. Its registry lists BOTH chains, because
  #              staging is the environment that shows both. It publishes no
  #              `/d/**` at all — the data is somebody else's.
  #   prodData   production's published tree: `aztec`, and only `aztec`.
  #   stgData    the staging-only store: `solo`, the chain production does not
  #              carry and must not acquire.
  let app = newTree()
  app.registryOf(["aztec", "solo"])

  let prod = newTree()
  prod.addChain("aztec", "g-prod-77", "0xaa")

  let stg = newTree()
  stg.addChain("solo", "g-staging-3", "0xcc")

  let (appStore, appLog) = app.watched("app:staging-build")
  let (prodStore, prodLog) = prod.watched("data:production")
  let (stgStore, stgLog) = stg.watched("data:staging")

  let staging = newDataRoot("", appStore)
    .withDataOrigin(prodStore)
    .withChainOrigin("solo", stgStore)

  test "the resolution order is override, then data origin, then application":
    check staging.originName("aztec") == prodStore.name
    check staging.originName("solo") == stgStore.name
    # And the application origin is still the one that answers for the
    # inventory, which is the only reason `solo` is visible here at all.
    check chains(staging) == @["aztec", "solo"]
    check appLog.touched("registry/") > 0

  test "each chain renders the generation ITS origin published":
    check chainInfo(staging, "aztec").generation == "g-prod-77"
    check chainInfo(staging, "solo").generation == "g-staging-3"

  test "exactly one chain went elsewhere — measured as reads, not as a field":
    for slug in chains(staging):
      let info = chainInfo(staging, slug)
      check blockHashes(staging, info).len == 1
      check blocksFrom(staging, info, -1).rows.len == 1
    # The production store was asked about production's chain and NOTHING about
    # the staging-only one. This is the assertion that would fail if any read
    # below `chainInfo` reached for the root's default instead of the chain's
    # pinned store.
    check prodLog.touched("d/aztec/") > 0
    check prodLog.touched("solo") == 0
    check stgLog.touched("d/solo/") > 0
    check stgLog.touched("aztec") == 0
    # And the application origin served the registry and no chain data — the
    # staging build ships software, not a tree.
    check appLog.touched("d/") == 0

  test "MUTATION BITE: drop the override and the staging-only chain fails to open":
    # Without `withChainOrigin`, `solo` resolves to the production data origin,
    # which does not carry it — and the reader RAISES rather than rendering a
    # chain page over a tree that has no such chain. A `DataPlaneError` at build
    # time is the intended failure: an environment that lists a chain nobody's
    # origin serves is a misconfiguration, and it is louder here than on a page.
    let unwired = newDataRoot("", appStore).withDataOrigin(prodStore)
    check unwired.originName("solo") == prodStore.name
    expect DataPlaneError:
      discard chainInfo(unwired, "solo")
    # …while the chain that IS carried opens exactly as before, so the bite is
    # about the override and not about the tree being broken.
    check chainInfo(unwired, "aztec").generation == "g-prod-77"

  test "an override replaces rather than shadows, so the list stays an enumeration":
    let other = newTree()
    other.addChain("solo", "g-third", "0xdd")
    let rewired = staging.withChainOrigin("solo", other.store("data:third"))
    check rewired.origins.len == 1
    check rewired.originName("solo") == "data:third"
    check chainInfo(rewired, "solo").generation == "g-third"

# ---------------------------------------------------------------------------
suite "per-chain data origin — a chain absent from the registry is not served":
# ---------------------------------------------------------------------------

  # PRODUCTION, POINTED AT A STORE THAT ALSO HOLDS A STAGING-ONLY CHAIN. This
  # is the arrangement the "just leave it out of production's registry" answer
  # would produce, and the point of this suite is that it is only half an
  # answer.
  let prodApp = newTree()
  prodApp.registryOf(["aztec"])          # production lists Aztec and nothing else

  let shared = newTree()
  shared.addChain("aztec", "g-prod-77", "0xaa")
  shared.addChain("solo", "g-staging-3", "0xcc")   # …in the SAME store

  let sharedStore = shared.store("data:shared-bucket")
  let production = newDataRoot("", prodApp.store("app:production"))
    .withDataOrigin(sharedStore)

  test "the inventory omits it":
    check chains(production) == @["aztec"]

  test "its routes 404 rather than rendering":
    let (status, body, _) = renderRoute(production, "/solo")
    check status == 404
    check "solo" notin body
    # The chain production DOES list is unaffected, so the 404 is about the
    # slug and not about the dispatcher being broken.
    check renderRoute(production, "/aztec")[0] == 200

  test "no enumerated route names it":
    for route in staticRoutes(production):
      check not route.startsWith("/solo")

  test "AND ITS DATA IS STILL FETCHABLE BY PATH — which is why a registry omission is not containment":
    # The load-bearing negative result. Nothing the application does can make a
    # published object unreachable: `/d/solo/current.json` is a URL under the
    # same origin, and a registry that does not mention `solo` withholds the
    # LINK, not the bytes.
    #
    # So "production simply won't list it" is a presentation decision, and the
    # containment decision is a STORAGE one: a chain production must not carry
    # goes in a different store, which is exactly what `withChainOrigin` above
    # expresses and what this check exists to keep from being forgotten.
    check sharedStore.get("d/solo/current.json").found
    check sharedStore.get("d/solo/block/0xcc.json").found
    # Whereas a store that never held it cannot serve it, registry or no
    # registry — the property a separate origin actually buys.
    let separate = newTree()
    separate.addChain("aztec", "g-prod-77", "0xaa")
    check not separate.store("data:aztec-only").get("d/solo/current.json").found
