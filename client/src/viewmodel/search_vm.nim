## viewmodel/search_vm.nim
##
## `SearchVM` — Front-End-Architecture §3: "Shape detection, path resolution,
## static-index queries, result grouping and ranking".
##
## It establishes §14's "Object not found" row, and the row's whole content is
## in the second half of its sentence: **"'Not on this chain' with the chains
## checked, not a blank page."** So `chainsChecked` is a first-class output, not
## a debugging aid — a page that says "not found" without naming what it looked
## in is the blank page §14 forbids.
##
## ## Four mechanisms; two are built here, two are blocked at the facade
##
## Search-And-Routing.md §1 gives four, "in ascending order of cost":
##
## | Mechanism | Requests | Status |
## | --- | --- | --- |
## | Local inference (§3) | none | **built** — `numericCandidates`, from the head pointers the explorer already polls |
## | Direct path (§4) | 1 | **built** — `resolve`, over every chain the registry publishes |
## | **Hash index (§5)** | 2 | **blocked** — `/idx/hash/{version}/{prefix}.bin` is a binary shard format, and `@blocktracer/client`'s facade exports no index reader |
## | **Name shards (§6)** | 1–2 | **blocked** — same |
##
## The two blocked rows are blocked on a decision that is *already open* rather
## than on an oversight: Client-SDK.md §5 asks "how much of search belongs
## here? Navigating published indices does. Ranking, suggestions and query
## parsing may be product decisions belonging to the consumer". Until that is
## answered, reaching `blocktracer/contract/searchidx` directly from here would
## pin a Client SDK internal as public ABI, which is exactly what
## `ci/test/client-sdk-boundary.sh`'s OUTWARD direction exists to prevent. So
## this VM does not do it, and `mechanism` reports `smUnsupportedShape` for an
## input only those two could resolve rather than silently returning nothing.
##
## ## Ambiguity is normal and is carried, not collapsed
##
## §2: "A single input may match several shapes; all matches are carried
## forward ... A 64-hex string is both a plausible transaction hash and a
## plausible block hash, and both are resolved concurrently; exactly one
## answers." `shapesOf` therefore returns a set, `resolve` tries every
## (chain, shape) pair, and `results` can hold more than one — which is also
## what makes the "chains checked" list truthful rather than a restatement of
## the registry.
##
## ## Where this VM runs, and where it does not
##
## Classification and canonicalisation now live in `search_shapes`, and this
## module re-exports them, because the static site resolves `?q=` in the
## browser and a `nim js` bundle cannot import this one — the isonim signal
## graph and the Client SDK facade do not cross. `client/searchboot/` is that
## bundle; it shares §2's table with this VM rather than restating it.
##
## The split is a real one and worth naming: `resolve` below is SYNCHRONOUS,
## because `ObjectStore.fetchProc` is. On a page that is a browser tab, the
## §4 fan-out has to be concurrent promises, which this type cannot express.
## So the browser performs the I/O and this VM states the rules — and both
## call the same `shapesOf`, `canonicalHash` and path derivation, which is
## the part that must never drift.

import std/strutils

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./chain_degradation
import ./chain_registry_vm
import ./chain_vm
import ./search_shapes

export search_shapes   # `QueryShape`, `shapesOf`, `canonicalHash`

type
  SearchMechanism* = enum
    smNone = "none"
    smLocalInference = "localInference"   ## §3 — zero requests
    smDirectPath = "directPath"           ## §4 — one request per candidate
    smUnsupportedShape = "unsupportedShape"
      ## The input's only route is the hash index or the name shards. Reported
      ## as its own value so "we cannot look this up yet" never renders as "it
      ## does not exist".

  ResultKind* = enum
    rkTransaction = "transaction"
    rkBlock = "block"
    rkBlockHeight = "blockHeight"

  SearchResult* = object
    kind*: ResultKind
    chain*: string
    id*: string
      ## The hash, or the height as text.
    path*: string
      ## The route to navigate to.

  SearchVM* = ref object of ViewModel
    store*: ObjectStore
    registry*: ChainRegistryVM
    chain*: ChainVM

    # -- State --
    query*: Signal[string]
    results*: Signal[seq[SearchResult]]
    chainsChecked*: Signal[seq[string]]
      ## §14's row, literally. Every chain a `resolve` actually reached — not
      ## the registry's list, because a chain whose session failed to open was
      ## not checked and saying otherwise would be a false statement.
    resolved*: Signal[bool]
      ## Whether a `resolve` has run for the current query. Distinguishes "no
      ## results" from "not asked yet", which otherwise render the same.

    # -- Derived --
    shapes*: Memo[set[QueryShape]]
    mechanism*: Memo[SearchMechanism]
    presence*: Memo[ObjectPresence]
    snapshot*: Memo[ChainStateSnapshot]
    degradation*: Memo[ChainDegradation]

proc numericCandidates*(vm: SearchVM; height: int): seq[SearchResult] =
  ## §3's local inference: "suggestions for every chain whose head exceeds it
  ## ... **without issuing a single** request".
  ##
  ## Only the open chain's head is held today, because this VM holds one
  ## `ChainVM`. That is a real limit of the composition and not of the
  ## mechanism, and it is why the loop below is over one head rather than over
  ## a registry of them: a multi-chain head cache is a shell concern that
  ## arrives with the multi-chain shell.
  if not vm.registry.hasSession.val: return
  let session = vm.registry.session.val
  if height < 0 or height > session.head.height: return
  for b in vm.chain.indexedBlocks.val:
    if b.height == height:
      result.add SearchResult(kind: rkBlock, chain: session.chain, id: b.hash,
                              path: "/" & session.chain & "/block/" & b.hash)
      return
  # The height is within the chain but the generation has not indexed it. A
  # candidate, not a result: the route is right and the object may not be there
  # yet, which is exactly the behind-the-tip case.
  result.add SearchResult(kind: rkBlockHeight, chain: session.chain,
                          id: $height, path: "/" & session.chain & "/blocks")

proc resolveOn(vm: SearchVM; session: ChainSession; q: string;
               shapes: set[QueryShape]; found: var seq[SearchResult]) =
  ## §4's direct path, on one chain. One read per candidate meaning, and no
  ## read at all for a shape that cannot address an object.
  if isHashLike(shapes):
    let tx = transaction(vm.store, session, q)
    if tx.outcome == roFound:
      found.add SearchResult(kind: rkTransaction, chain: session.chain, id: q,
                             path: "/" & session.chain & "/tx/" & q)
    let blk = blockDetail(vm.store, session, q)
    if blk.outcome == roFound:
      found.add SearchResult(kind: rkBlock, chain: session.chain, id: q,
                             path: "/" & session.chain & "/block/" & q)

proc resolve*(vm: SearchVM) =
  ## Resolve the current query across every chain the registry publishes.
  ##
  ## The session for each chain is opened here rather than reusing the active
  ## one, because a search is explicitly cross-chain: §14's row is about the
  ## chains that were *checked*, and checking a chain means pinning its
  ## generation and reading in it.
  ## CLASSIFY THE RAW QUERY, CANONICALISE ONLY THE PATH. The two steps used to
  ## be one — `shapesOf(canonicalQuery(q))` — and that was safe only while the
  ## canonical form was reachable from `0x`-prefixed input alone. It is not any
  ## more: `68231` is both a block height and a valid hex string, and
  ## canonicalising first would rewrite it to `0x68231` and lose §3's
  ## zero-request local inference to six 404s. §2 is explicit that "a single
  ## input may match several shapes; all matches are carried forward", and
  ## carrying them means not destroying one of them before classification.
  ##
  ## The hash branch still canonicalises (§13.1 of SEO-And-Crawl-Budget) before
  ## any path is computed: `0xABC…`, `0xabc…` and a bare `abc…` are the same
  ## object, and the published tree names it in lowercase with the prefix.
  ## Resolving the raw string missed every chain and then reported "not on this
  ## chain" — an absence claim about an object that was there.
  let raw = vm.query.val.strip
  var found: seq[SearchResult]
  var checked: seq[string]
  vm.resolved.val = true

  let shapes = shapesOf(raw)
  if qsDecimal in shapes:
    for r in vm.numericCandidates(parseInt(raw)):
      found.add r
    # Local inference issues no request, so no chain was "checked" by it. The
    # list stays honest even when the answer came for free.

  if isHashLike(shapes):
    let q = canonicalHash(raw)
    for slug in vm.registry.chains.val:
      let opened = openChain(vm.store, slug)
      if opened.outcome != ooOpened:
        # Not checked. A chain whose pointer could not be read was not
        # searched, and listing it would claim a search that did not happen.
        continue
      checked.add slug
      vm.resolveOn(opened.session, q, shapes, found)

  vm.results.val = found
  vm.chainsChecked.val = checked

proc setQuery*(vm: SearchVM; q: string) =
  vm.query.val = q
  vm.results.val = @[]
  vm.chainsChecked.val = @[]
  vm.resolved.val = false

proc createSearchVM*(store: ObjectStore; registry: ChainRegistryVM;
                     chain: ChainVM): SearchVM =
  withViewModel proc(dispose: proc()): SearchVM =
    let vm = SearchVM(
      store: store, registry: registry, chain: chain,
      query: createSignal(""),
      results: createSignal(newSeq[SearchResult]()),
      chainsChecked: createSignal(newSeq[string]()),
      resolved: createSignal(false),
    )

    vm.shapes = createMemo(proc(): set[QueryShape] = shapesOf(vm.query.val))

    vm.mechanism = createMemo(proc(): SearchMechanism =
      let s = vm.shapes.val
      if qsEmpty in s: smNone
      elif qsDecimal in s: smLocalInference
      elif qsHash32 in s or qsHexShort in s or qsAddress20 in s: smDirectPath
      else: smUnsupportedShape)

    vm.presence = createMemo(proc(): ObjectPresence =
      if not vm.resolved.val: opPresent
      elif vm.results.val.len > 0: opPresent
      # An input only the blocked mechanisms could resolve is NOT "not on this
      # chain": nothing was looked in. Reporting absence for it would be the
      # false statement this VM's whole not-found story is built to avoid.
      elif vm.mechanism.val == smUnsupportedShape: opPresent
      else: opNotOnThisChain)

    vm.snapshot = createMemo(proc(): ChainStateSnapshot =
      var s = initChainStateSnapshot()
      s.reachability = chain.reachability.val
      s.presence = vm.presence.val
      s)

    vm.degradation = createMemo(proc(): ChainDegradation =
      resolveChainDegradation(vm.snapshot.val, SearchDegradations))

    vm
