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
## | Ledger-version index | 2 | **built** — `resolveVersionOn`, on the chains whose registry row declares `ordering.kind: globalVersion` and no other |
##
## The ledger-version index (`/idx/{chain}/version/`, `contract/versionidx.nim`)
## is the one index read here, and it is read with the codec the exporter wrote
## it with and `client/searchboot/` reads it with — this module holds no second
## copy of the shard format, the bucket rule or the version spelling. It is
## scoped by the registry's declaration (`ChainRegistryVM.versionOrderedChains`):
## a number on a deployment with no version-ordered chain makes no index request
## at all, exactly as before, and means only what §3 makes it mean.
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
# The ledger-version index's codec — the exporter's and the `/search` page's.
from ../../../src/blocktracer/contract/versionidx import canonicalVersion,
  versionBucket, versionMetaPath, versionShardPath, decodeVersionShard

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
    versionUnchecked*: Signal[seq[string]]
      ## Version-ordered chains whose ledger-version index a `resolve` set out
      ## to read and could not — the descriptor, or the bucket it names, did not
      ## load or did not decode. NOT checked, so not in `chainsChecked`, and not
      ## a miss: an answer with no result and a chain here is not reported as
      ## "not on this chain" (`presence`), as `/search` reports it "not checked".
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

func spellingsOn(keys: seq[tuple[encoding, identifier: string]];
                 session: ChainSession; kind: string): seq[string] =
  ## The query's spellings a chain can hold as an identifier of `kind`: the keys
  ## whose encoding is the one the chain's registry row declares for that kind.
  ##
  ## `/search` reaches a Sui digest because its index entries are filtered by the
  ## encoding the producer wrote them under; this is the same filter applied to
  ## the direct path. It used to be one spelling for every chain —
  ## `canonicalHash`, which is hex-only and is "" for a base58 digest — so the
  ## view model asked every chain for an empty identifier and reported a Sui
  ## transaction that is published as not on any chain. A chain whose declaration
  ## omits the kind gets no spelling: `encodingFor` refuses to invent one.
  var token = ""
  try: token = session.identifierEncoding.encodingFor(kind)
  except ValueError: return
  for k in keys:
    if k.encoding == token and k.identifier notin result:
      result.add k.identifier

proc resolveOn(vm: SearchVM; session: ChainSession;
               keys: seq[tuple[encoding, identifier: string]];
               found: var seq[SearchResult]) =
  ## §4's direct path, on one chain. One read per candidate meaning the chain's
  ## declared encodings admit, and no read for a spelling it cannot hold.
  for id in spellingsOn(keys, session, KindTransaction):
    let tx = transaction(vm.store, session, id)
    if tx.outcome == roFound:
      found.add SearchResult(kind: rkTransaction, chain: session.chain, id: id,
                             path: "/" & session.chain & "/tx/" & id)
  for id in spellingsOn(keys, session, KindBlock):
    let blk = blockDetail(vm.store, session, id)
    if blk.outcome == roFound:
      found.add SearchResult(kind: rkBlock, chain: session.chain, id: id,
                             path: "/" & session.chain & "/block/" & id)

proc resolveVersionOn(vm: SearchVM; chain, version: string;
                      found: var seq[SearchResult]): bool =
  ## A decimal query as a ledger version, on one version-ordered chain: the
  ## descriptor, then the one bucket it lists for `version` — two requests, as
  ## `/search` spends. `version` is canonical (`canonicalVersion`). Returns
  ## whether the chain was CHECKED: `false` means its index could not be read,
  ## which is not "the version is not there".
  ##
  ## Exact, never a prefix: an entry answers only at precisely `version`. A hit
  ## routes to the transaction's own page, which is named by its HASH — the
  ## version is how it was found, not where it lives.
  let meta = vm.store.getJson(versionMetaPath(chain))
  if not meta.found or meta.error.len > 0 or meta.node.isNil or
     meta.node.kind != JObject:
    return false
  # The bucket width is PUBLISHED, never compiled in (`VersionBucketDigits` is
  # the exporter's choice, not this reader's).
  let digits = meta.node{"bucketDigits"}.getInt(0)
  let indexVersion = meta.node{"indexVersion"}.getStr("")
  if digits <= 0 or indexVersion.len == 0: return false
  let bucket = versionBucket(version, digits)
  var listed = false
  let shards = meta.node{"shards"}
  if not shards.isNil and shards.kind == JArray:
    for s in shards:
      if s.kind == JString and s.getStr == bucket: listed = true
  # A bucket the index never wrote is a definite miss at no further request:
  # the index is exact over the chain's published transactions.
  if not listed: return true
  let shard = vm.store.get(versionShardPath(chain, indexVersion, bucket))
  if not shard.found: return false
  # Decoded first, so a shard this build cannot read is "not checked" and not
  # an empty answer (`lookupVersion`'s note).
  let dec = decodeVersionShard(shard.body)
  if dec.err.len > 0: return false
  for e in dec.entries:
    if e.version == version:
      found.add SearchResult(kind: rkTransaction, chain: chain, id: e.identifier,
                             path: "/" & chain & "/tx/" & e.identifier)
  true

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
    # A HEIGHT IS AN `int`, AND A DECIMAL STRING CAN NAME A NUMBER NO HEIGHT
    # REACHES. `parseInt` raised on anything above int64 — a 20-digit number, or
    # an Aptos ledger version near the top of u64 — and the exception took the
    # whole resolve with it. Such a number is above every chain's head, so as a
    # height it is a candidate on no chain: the answer is "not on this chain",
    # reached the same way a height above the head reaches it. Its reading as a
    # ledger version, below, is a string and is unaffected.
    var height = -1
    try: height = parseInt(raw)
    except ValueError: height = -1
    if height >= 0:
      for r in vm.numericCandidates(height):
        found.add r
    # Local inference issues no request, so no chain was "checked" by it. The
    # list stays honest even when the answer came for free.

  # A NUMBER IS ALSO A LEDGER VERSION, on the chains ordered by one and on no
  # other. Both readings are carried (§2): the height above, from the head this
  # VM holds, and the version here, from the chain's version index. A
  # deployment with no version-ordered chain never enters the loop, so a number
  # there costs exactly the zero requests it always cost. A decimal string is
  # never hash-like (bare hex refuses all-digit strings), so this cannot shadow
  # a hash reading; the guard says so rather than relying on it.
  var unchecked: seq[string]
  if qsDecimal in shapes and not isHashLike(shapes):
    let version = canonicalVersion(raw)
    if version.len > 0:
      for slug in vm.registry.versionOrderedChains.val:
        if vm.resolveVersionOn(slug, version, found): checked.add slug
        else: unchecked.add slug

  if isHashLike(shapes):
    # EVERY SPELLING THE QUERY ADMITS, each tried only on the chains that write
    # identifiers that way (`spellingsOn`). For a hex query on a hex chain that
    # is `canonicalHash(raw)` and nothing else, as before.
    let keys = indexKeysOf(raw)
    for slug in vm.registry.chains.val:
      let opened = openChain(vm.store, slug)
      if opened.outcome != ooOpened:
        # Not checked. A chain whose pointer could not be read was not
        # searched, and listing it would claim a search that did not happen.
        continue
      checked.add slug
      vm.resolveOn(opened.session, keys, found)

  vm.results.val = found
  vm.chainsChecked.val = checked
  vm.versionUnchecked.val = unchecked

proc setQuery*(vm: SearchVM; q: string) =
  vm.query.val = q
  vm.results.val = @[]
  vm.chainsChecked.val = @[]
  vm.versionUnchecked.val = @[]
  vm.resolved.val = false

proc createSearchVM*(store: ObjectStore; registry: ChainRegistryVM;
                     chain: ChainVM): SearchVM =
  withViewModel proc(dispose: proc()): SearchVM =
    let vm = SearchVM(
      store: store, registry: registry, chain: chain,
      query: createSignal(""),
      results: createSignal(newSeq[SearchResult]()),
      chainsChecked: createSignal(newSeq[string]()),
      versionUnchecked: createSignal(newSeq[string]()),
      resolved: createSignal(false),
    )

    vm.shapes = createMemo(proc(): set[QueryShape] = shapesOf(vm.query.val))

    vm.mechanism = createMemo(proc(): SearchMechanism =
      let s = vm.shapes.val
      if qsEmpty in s: smNone
      elif qsDecimal in s: smLocalInference
      # `qsEncodedId` too: a base58 or bech32 identifier is resolved on the
      # direct path of every chain that declares that encoding (`spellingsOn`).
      elif isHashLike(s) or qsAddress20 in s: smDirectPath
      else: smUnsupportedShape)

    vm.presence = createMemo(proc(): ObjectPresence =
      if not vm.resolved.val: opPresent
      elif vm.results.val.len > 0: opPresent
      # An input only the blocked mechanisms could resolve is NOT "not on this
      # chain": nothing was looked in. Reporting absence for it would be the
      # false statement this VM's whole not-found story is built to avoid.
      elif vm.mechanism.val == smUnsupportedShape: opPresent
      # A version index that could not be read was not looked in either: the
      # chain was not checked, and "not on this chain" would be a claim about
      # it. Only ever non-empty on a deployment with a version-ordered chain.
      elif vm.versionUnchecked.val.len > 0: opPresent
      else: opNotOnThisChain)

    vm.snapshot = createMemo(proc(): ChainStateSnapshot =
      var s = initChainStateSnapshot()
      s.reachability = chain.reachability.val
      s.presence = vm.presence.val
      s)

    vm.degradation = createMemo(proc(): ChainDegradation =
      resolveChainDegradation(vm.snapshot.val, SearchDegradations))

    vm
