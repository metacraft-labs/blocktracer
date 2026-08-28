## viewmodel/address_vm.nim
##
## `AddressVM` — Front-End-Architecture §3: "Account state, code,
## verified-source status, paged history".
##
## ## What is built, and what is blocked — stated rather than stubbed
##
## | §3's row               | Status | Why |
## | ---------------------- | ------ | --- |
## | Paged history          | built  | `/d/{chain}/g/{gen}/addr/**` → `/d/{chain}/seg/**`, both walked by M5b's validator |
## | Verified-source status | built  | code hashes from the transactions' `codeEdges`, resolved through `SourceBundleVM` |
## | **Account state**      | **blocked** | There is no account object class in the tree. Static-Site-Architecture.md §2's inventory has blocks, transactions, address *segments* and labels, and no `/d/{chain}/account/**`. It arrives with M6's ingestion. |
## | **Code**               | **blocked** | Same: a deployed contract's bytecode has no published object. The `CodeEdge` gives an address its **code hash**, which is what source resolution is keyed on, and that is a different thing from the code. |
##
## The two blocked rows have no signals here at all. A `balance` field seeded
## from nothing would make this VM look finished and would make the first real
## ingestion a breaking change rather than an addition.
##
## ## The segment schema is read defensively, and here is why that is not
## laziness
##
## M5b's contract types cover blocks, transactions, the trace overlay and the
## manifest. Address segments are **path-checked but not shape-checked**: the
## validator walks `maps.addr`, reads `address` and `segments`, and loads each
## segment object without asserting its interior. So there is no
## `decodeAddressSegment` to import, and writing one here would be declaring a
## contract type outside the contract — which is the drift M5b's "one typed
## representation" exists to prevent (Data-Contract.md, Static-Site-Architecture
## §2.9). This VM therefore reads the fields the demo producer writes, tolerates
## their absence, and does not pretend to validate. When the segment gets a
## contract type, this reader should be replaced by it rather than kept beside
## it.

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./chain_degradation
import ./chain_registry_vm
import ./chain_vm

type
  AddressSegment* = object
    ## One block-range page of an address's history.
    path*: string
    fromBlock*: int
    toBlock*: int
    transactions*: seq[string]
    loaded*: bool

  AddressVM* = ref object of ViewModel
    store*: ObjectStore
    registry*: ChainRegistryVM
    chain*: ChainVM

    # -- State --
    address*: Signal[string]
    segmentPaths*: Signal[seq[string]]
      ## In the order the generation's address list gives them.
    segments*: Signal[seq[AddressSegment]]
      ## Only the pages that have been fetched. Paging is explicit: an address
      ## with a long history must not cost every segment on first render, which
      ## is the reason the tree splits them by block range at all.
    indexFound*: Signal[bool]
    loaded*: Signal[bool]
      ## Whether `loadIndex` has run; see `BlockVM.loaded`.
    reason*: Signal[string]

    # -- Derived --
    presence*: Memo[ObjectPresence]
    knownTransactions*: Memo[seq[string]]
      ## Every transaction hash across the loaded segments, newest segment
      ## first. Deduplicated: a transaction that appears in two overlapping
      ## segments is one row.
    loadedSegments*: Memo[int]
    totalSegments*: Memo[int]
    hasMore*: Memo[bool]
    snapshot*: Memo[ChainStateSnapshot]
    degradation*: Memo[ChainDegradation]

proc loadIndex*(vm: AddressVM; address: string) =
  ## Read the generation's segment list for an address. One read; the segments
  ## themselves are not fetched.
  vm.address.val = address
  vm.loaded.val = true
  vm.segments.val = @[]
  vm.segmentPaths.val = @[]
  if not vm.registry.hasSession.val:
    vm.indexFound.val = false
    vm.reason.val = "no chain is open"
    return
  let session = vm.registry.session.val
  let r = vm.store.getJson(
    addressIndexPath(session.chain, session.generation, address))
  if not r.found:
    vm.indexFound.val = false
    vm.reason.val = address & " has no history in generation " & session.generation
    return
  if r.error.len > 0 or r.node.isNil or r.node.kind != JObject:
    vm.indexFound.val = false
    vm.reason.val = if r.error.len > 0: r.error else: "address index is not an object"
    return
  var paths: seq[string]
  if r.node.hasKey("segments") and r.node["segments"].kind == JArray:
    for p in r.node["segments"]:
      if p.kind == JString and p.getStr.len > 0: paths.add p.getStr
  vm.segmentPaths.val = paths
  vm.indexFound.val = true
  vm.reason.val = ""

proc loadNextSegment*(vm: AddressVM): bool =
  ## Fetch the next unloaded segment. Returns false when there is none, so a
  ## "load more" affordance is driven by the answer rather than by a guess.
  let paths = vm.segmentPaths.val
  var segs = vm.segments.val
  if segs.len >= paths.len: return false
  let path = paths[segs.len]
  var seg = AddressSegment(path: path)
  let r = vm.store.getJson(path)
  if r.found and r.error.len == 0 and not r.node.isNil and r.node.kind == JObject:
    seg.loaded = true
    seg.fromBlock = r.node{"fromBlock"}.getInt
    seg.toBlock = r.node{"toBlock"}.getInt
    if r.node.hasKey("transactions") and r.node["transactions"].kind == JArray:
      for t in r.node["transactions"]:
        if t.kind == JString: seg.transactions.add t.getStr
  # An unloadable segment is still appended, with `loaded = false`. Skipping it
  # would make the page silently shorter and make "load more" advance past a
  # gap the user was never told about.
  segs.add seg
  vm.segments.val = segs
  true

proc loadAllSegments*(vm: AddressVM) =
  while vm.loadNextSegment(): discard

proc codeHashesFor*(vm: AddressVM; facts: TransactionFacts): seq[string] =
  ## The code hashes bound to *this* address in one transaction's code edges.
  ##
  ## Filtered by address rather than taking every hash the transaction touched:
  ## an address page's verified-source status is about the code at that
  ## address, and a transaction that also called three other contracts would
  ## otherwise make this address look verified because someone else's is.
  let want = vm.address.val
  for e in facts.codeEdges:
    if e.address == want and e.codeHash.len > 0 and e.codeHash notin result:
      result.add e.codeHash

proc createAddressVM*(store: ObjectStore; registry: ChainRegistryVM;
                      chain: ChainVM): AddressVM =
  withViewModel proc(dispose: proc()): AddressVM =
    let vm = AddressVM(
      store: store, registry: registry, chain: chain,
      address: createSignal(""),
      segmentPaths: createSignal(newSeq[string]()),
      segments: createSignal(newSeq[AddressSegment]()),
      indexFound: createSignal(false),
      loaded: createSignal(false),
      reason: createSignal(""),
    )

    vm.presence = createMemo(proc(): ObjectPresence =
      if not vm.loaded.val or vm.indexFound.val: opPresent
      else: opNotOnThisChain)

    vm.loadedSegments = createMemo(proc(): int =
      for s in vm.segments.val:
        if s.loaded: inc result)

    vm.totalSegments = createMemo(proc(): int = vm.segmentPaths.val.len)

    vm.hasMore = createMemo(proc(): bool =
      vm.segments.val.len < vm.segmentPaths.val.len)

    vm.knownTransactions = createMemo(proc(): seq[string] =
      for s in vm.segments.val:
        for t in s.transactions:
          if t notin result: result.add t)

    vm.snapshot = createMemo(proc(): ChainStateSnapshot =
      var s = initChainStateSnapshot()
      s.reachability = chain.reachability.val
      s.presence = vm.presence.val
      # An address's history is generation-scoped, so a behind-the-tip
      # pipeline genuinely truncates this page — unlike a transaction page,
      # which is complete whatever the pipeline is doing.
      s.freshness = chain.freshness.val
      s)

    vm.degradation = createMemo(proc(): ChainDegradation =
      resolveChainDegradation(vm.snapshot.val, AddressDegradations))

    vm
