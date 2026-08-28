## viewmodel/block_vm.nim
##
## `BlockVM` — Front-End-Architecture §3: "One block, its transactions,
## navigation to siblings".
##
## ## Why a block read does not consult the pinned generation
##
## Block details are content-addressed and generation-independent
## (Static-Site-Architecture.md §2), so `blockDetail` does not touch the
## generation at all — and a reorg therefore does not invalidate a block page
## (§3.4). What a reorg does invalidate is the **height → hash** mapping, which
## is the epoch file, which is generation-scoped. So sibling navigation is
## generation-scoped and the detail is not, and this VM keeps that distinction
## rather than presenting one freshness for the page.
##
## That is why `previous`/`next` come from `ChainVM.indexedBlocks` — the sealed
## generation's own height map — and not from `parentHash`. Walking parents
## would follow the chain the *block* remembers, which after a reorg is not the
## chain the generation indexed, and the two disagreeing is exactly the state a
## user needs to be told about rather than navigated through.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./chain_degradation
import ./chain_registry_vm
import ./chain_vm

type
  BlockVM* = ref object of ViewModel
    store*: ObjectStore
    registry*: ChainRegistryVM
    chain*: ChainVM

    # -- State --
    hash*: Signal[string]
    detail*: Signal[BlockDetail]
    outcome*: Signal[ReadOutcome]
    reason*: Signal[string]
    loaded*: Signal[bool]
      ## Whether `load` has run. "Not asked yet" and "not found" are different
      ## states and must not render the same — the same distinction
      ## `SearchVM.resolved` makes, for the same reason: a page that has not
      ## looked has no business saying an entity is not on this chain.

    # -- Derived --
    found*: Memo[bool]
    presence*: Memo[ObjectPresence]
    txHashes*: Memo[seq[string]]
    txCount*: Memo[int]
    previousSibling*: Memo[BlockRef]
    nextSibling*: Memo[BlockRef]
    atHead*: Memo[bool]
    atGenesis*: Memo[bool]
      ## True at the lowest block the generation indexed, which is not
      ## necessarily height 0: a selective or history-floored chain has a
      ## genuine floor, and calling the lowest indexed block "genesis" would
      ## be a claim about the chain rather than about the index. The name is
      ## §5.2's ("disabled at genesis and head") and the meaning is stated
      ## here so the two do not quietly diverge.
    inGeneration*: Memo[bool]
      ## Whether the pinned generation's height map contains this block. A
      ## block detail that reads fine while the generation does not list it is
      ## a reorg, and this is how the page notices without a second read.
    snapshot*: Memo[ChainStateSnapshot]
    degradation*: Memo[ChainDegradation]

proc load*(vm: BlockVM; blockHash: string) =
  vm.hash.val = blockHash
  vm.loaded.val = true
  if not vm.registry.hasSession.val:
    vm.outcome.val = roNotFound
    vm.reason.val = "no chain is open"
    vm.detail.val = BlockDetail()
    return
  let r = blockDetail(vm.store, vm.registry.session.val, blockHash)
  vm.outcome.val = r.outcome
  case r.outcome
  of roFound:
    vm.detail.val = r.detail
    vm.reason.val = ""
  else:
    vm.detail.val = BlockDetail()
    vm.reason.val = r.reason

proc createBlockVM*(store: ObjectStore; registry: ChainRegistryVM;
                    chain: ChainVM): BlockVM =
  withViewModel proc(dispose: proc()): BlockVM =
    let vm = BlockVM(
      store: store, registry: registry, chain: chain,
      hash: createSignal(""),
      detail: createSignal(BlockDetail()),
      outcome: createSignal(roNotFound),
      reason: createSignal(""),
      loaded: createSignal(false),
    )

    vm.found = createMemo(proc(): bool =
      vm.loaded.val and vm.outcome.val == roFound)

    vm.presence = createMemo(proc(): ObjectPresence =
      if not vm.loaded.val: opPresent
      else:
        case vm.outcome.val
        of roFound: opPresent
        of roNotFound: opNotOnThisChain
        of roMalformed: opMalformed)

    vm.txHashes = createMemo(proc(): seq[string] =
      if vm.outcome.val != roFound: @[] else: vm.detail.val.transactions)

    vm.txCount = createMemo(proc(): int = vm.txHashes.val.len)

    vm.inGeneration = createMemo(proc(): bool =
      let want = vm.hash.val
      if want.len == 0: return false
      for b in chain.indexedBlocks.val:
        if b.hash == want: return true
      false)

    # `indexedBlocks` is newest-first, so the *next* block is the entry before
    # this one and the *previous* is the entry after. Written out rather than
    # indexed cleverly, because getting this backwards produces navigation
    # that works and goes the wrong way.
    vm.previousSibling = createMemo(proc(): BlockRef =
      let blocks = chain.indexedBlocks.val
      let want = vm.hash.val
      for i, b in blocks:
        if b.hash == want:
          return if i + 1 < blocks.len: blocks[i + 1] else: BlockRef()
      BlockRef())

    vm.nextSibling = createMemo(proc(): BlockRef =
      let blocks = chain.indexedBlocks.val
      let want = vm.hash.val
      for i, b in blocks:
        if b.hash == want:
          return if i > 0: blocks[i - 1] else: BlockRef()
      BlockRef())

    vm.atHead = createMemo(proc(): bool =
      vm.inGeneration.val and vm.nextSibling.val.hash.len == 0)

    vm.atGenesis = createMemo(proc(): bool =
      vm.inGeneration.val and vm.previousSibling.val.hash.len == 0)

    vm.snapshot = createMemo(proc(): ChainStateSnapshot =
      var s = initChainStateSnapshot()
      s.reachability = chain.reachability.val
      s.presence = vm.presence.val
      s.freshness = chain.freshness.val
      # A block that reads but is not in the generation's height map was
      # rewritten out of the chain. There is no re-inclusion notion for a
      # block — a reorged block is not "the same block elsewhere" — so this is
      # `ccReorganisedAway` and never `ccReIncluded`.
      s.canonicality =
        if vm.found.val and chain.indexedBlocks.val.len > 0 and
           not vm.inGeneration.val: ccReorganisedAway
        else: ccCanonical
      s)

    vm.degradation = createMemo(proc(): ChainDegradation =
      resolveChainDegradation(vm.snapshot.val, BlockDegradations))

    vm
