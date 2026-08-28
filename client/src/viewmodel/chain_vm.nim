## viewmodel/chain_vm.nim
##
## `ChainVM` — Front-End-Architecture §3, row 2: "Head-pointer polling, recent
## blocks and transactions, finality state, staleness".
##
## It establishes three of §14's seven chain-shaped rows:
##
## | §14 row                       | Established from                                |
## | ----------------------------- | ----------------------------------------------- |
## | Pipeline behind the chain tip | `summary.json`'s `stale`, and the pinned head against the highest block the generation indexed |
## | Reorganised away              | the generation's transaction-state layer         |
## | CDN unreachable               | `DeliveryMonitor`, from the transport of the poll |
##
## ## Staleness is surfaced, not inferred — and then it is also measured
##
## Static-Site-Architecture.md §5 is explicit that a consumer "surfaces
## staleness from `summary.json` rather than inferring it". So the published
## flag is authoritative: if the producer says stale, the page says stale, and
## no arithmetic here can talk it out of that.
##
## But §14's treatment is "a staleness notice **naming how far behind**", and
## `summary.json` carries a flag rather than a distance. The distance is the
## pinned head — which `current.json` carries as "the canonical tip" (§3.3) —
## against the highest block the sealed generation actually indexed. Publishing
## the flag and computing the distance are therefore complementary rather than
## a second inference: a positive distance with the flag clear is *also*
## staleness, and reporting it is what stops a stalled pipeline that forgot to
## set its own flag from rendering as healthy.
##
## ## Polling is the consumer's, not this VM's
##
## §3.3: "Polling is adapted to the chain's block time, suspended when the tab
## is hidden, and resumed on visibility change." All three of those are host
## facts — a block time from the registry, a `visibilitychange` event, a timer —
## and a ViewModel that owned a timer would not be headless. So `poll()` is an
## action proc the shell calls, and the VM owns the *state* polling produces:
## whether a newer generation exists, and whether the origin answered.
##
## Adopting a new generation is likewise an explicit action (`adopt`), never a
## side effect of polling — §3.3's "adopting it is a deliberate transition
## rather than a silent swap underneath a rendered view".

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./chain_degradation
import ./chain_registry_vm
import ./delivery

type
  ChainVM* = ref object of ViewModel
    store*: ObjectStore
    registry*: ChainRegistryVM
      ## Read directly. §2 of Front-End-Architecture is the point: "a `Memo` in
      ## `TransactionVM` can read a `Signal` in `DebugControlsVM` with no
      ## bridge, no serialisation and no message passing" — the same holds
      ## between two BlockTracer VMs, and `freshness` below is that memo.
    monitor*: DeliveryMonitor

    # -- State --
    indexedBlocks*: Signal[seq[BlockRef]]
      ## The generation's blocks, newest first. Loaded by `loadBlocks`.
    supersededBy*: Signal[string]
      ## A generation newer than the pinned one, if the last `poll` saw one.
      ## Empty otherwise. The page shows an "update available" affordance; it
      ## does not swap underneath the reader.

    # -- Derived --
    head*: Memo[BlockRef]
      ## The canonical tip, from the pinned `current.json`.
    indexedHead*: Memo[BlockRef]
      ## The highest block this generation actually indexed.
    blocksBehind*: Memo[int]
      ## §14: "naming how far behind". Never negative — an indexed height above
      ## the pointer's is a producer inconsistency, not a negative lag.
    freshness*: Memo[PipelineFreshness]
    reachability*: Memo[DeliveryReachability]
    finalizedHeight*: Memo[int]
    hasFinality*: Memo[bool]

proc loadBlocks*(vm: ChainVM) =
  ## Read the generation's height maps. O(epochs) reads, not O(blocks): the
  ## height map is one object per epoch and states the height, which is the
  ## property `blockRefsNewestFirst` exists for.
  if not vm.registry.hasSession.val:
    vm.indexedBlocks.val = @[]
    return
  vm.indexedBlocks.val = blockRefsNewestFirst(vm.store, vm.registry.session.val)

proc poll*(vm: ChainVM) =
  ## One poll of the one mutable object per chain. Called by the shell on its
  ## own cadence; see the module doc for why the timer is not here.
  if not vm.registry.hasSession.val:
    return
  let session = vm.registry.session.val
  let published = publishedGeneration(vm.store, session.chain)
  # An empty answer is either an unreachable origin or a chain that vanished
  # from the tree. Neither is evidence that the pinned generation was
  # superseded, so the affordance is not offered on silence.
  vm.supersededBy.val =
    if published.len > 0 and published != session.generation: published
    else: ""

proc adopt*(vm: ChainVM): OpenOutcome =
  ## §3.3's deliberate transition. Re-pins the registry VM's session to the
  ## newly-published generation and reloads what was generation-scoped.
  if not vm.registry.hasSession.val: return ooChainNotFound
  let chain = vm.registry.session.val.chain
  vm.registry.selectChain(chain)
  vm.supersededBy.val = ""
  vm.loadBlocks()
  vm.registry.openOutcome.val

type
  ReorgState* = object
    ## Everything §14's "Reorganised away" row needs to render: the verdict,
    ## and the new location when there is one.
    canonicality*: Canonicality
    known*: bool
      ## Whether the pinned generation carries a transaction-state object at
      ## all. `false` means the generation has not indexed this transaction —
      ## ordinary on a lagging pipeline — and is **not** a reorg. Fabricating
      ## one from silence would make a stale page look like a rewritten chain.
    reIncludedIn*: string
      ## The block hash the transaction was re-included in, when the producer
      ## stated one.
    finality*: string

proc readReIncludedIn*(vm: ChainVM; txHash: string): string =
  ## The re-inclusion location, read from the generation's transaction-state
  ## object.
  ##
  ## **An action proc, deliberately, and it must never be called from a memo.**
  ## A read goes through `DeliveryMonitor`, which writes signals; a memo that
  ## issued one would write a signal it also depends on and re-enter itself
  ## forever. That is not a quirk of this reader — it is layer discipline
  ## (Front-End-Architecture §2.1: a ViewModel's derivations are memos and its
  ## loading is effects), and here the discipline has teeth: breaking it does
  ## not produce a subtle staleness bug, it produces an immediate stack
  ## overflow. `TransactionVM.load` calls this and stores the answer in a
  ## signal, which is what `reorgStateOf` then reads.
  ##
  ## Static-Site-Architecture.md §2.3b puts "orphan/**re-inclusion state**" in
  ## the `GenerationTransactionState` layer, and the Client SDK's
  ## `TransactionView` decodes only `canonical` and `finality` from it. **No
  ## producer in this repository writes a re-inclusion field**, and the spec
  ## states no key name for it, so this reads the two plausible spellings and
  ## reports nothing when neither is present. That keeps §14's "with the new
  ## location if the transaction was re-included" reachable without pretending
  ## the field exists: a tree that does not carry it yields
  ## `ccReorganisedAway`, which is the correct weaker answer.
  if not vm.registry.hasSession.val: return ""
  let session = vm.registry.session.val
  let r = vm.store.getJson(
    txStatePath(session.chain, session.generation, txHash))
  if not r.found or r.error.len > 0 or r.node.isNil: return ""
  if r.node.kind != JObject: return ""
  for key in ["reIncludedIn", "reincludedIn"]:
    if r.node.hasKey(key) and r.node[key].kind == JString:
      return r.node[key].getStr
  ""

func reorgStateOf*(v: TransactionView; reIncludedIn: string): ReorgState =
  ## The canonicality of one transaction at the pinned generation. Pure: the
  ## re-inclusion location is passed in, having been read by `readReIncludedIn`
  ## during a load — see that proc for why the read cannot be here.
  result.finality = v.finality
  result.known = v.hasState
  if not v.hasState or v.canonical:
    result.canonicality = ccCanonical
    return
  result.reIncludedIn = reIncludedIn
  result.canonicality =
    if reIncludedIn.len > 0: ccReIncluded else: ccReorganisedAway

proc createChainVM*(store: ObjectStore; registry: ChainRegistryVM;
                    monitor: DeliveryMonitor): ChainVM =
  ## Create the VM inside a reactive root owned by `withViewModel`.
  ##
  ## `monitor` is passed in rather than created here because it wraps the
  ## *store* — every VM sharing a store shares its reachability, and a second
  ## monitor would be a second opinion about one origin.
  withViewModel proc(dispose: proc()): ChainVM =
    let vm = ChainVM(
      store: store,
      registry: registry,
      monitor: monitor,
      indexedBlocks: createSignal(newSeq[BlockRef]()),
      supersededBy: createSignal(""),
    )

    vm.head = createMemo(proc(): BlockRef =
      if registry.hasSession.val: registry.session.val.head else: BlockRef())

    vm.indexedHead = createMemo(proc(): BlockRef =
      let blocks = vm.indexedBlocks.val
      if blocks.len > 0: blocks[0] else: BlockRef())

    vm.blocksBehind = createMemo(proc(): int =
      if not registry.hasSession.val: return 0
      let blocks = vm.indexedBlocks.val
      # No blocks loaded is not "infinitely behind": it is "we have not asked".
      if blocks.len == 0: return 0
      let lag = registry.session.val.head.height - blocks[0].height
      if lag > 0: lag else: 0)

    vm.freshness = createMemo(proc(): PipelineFreshness =
      if not registry.hasSession.val: return pfCurrent
      # The published flag first — §5's "surfaces staleness from summary.json
      # rather than inferring it" — then the measured distance, which catches
      # a stalled pipeline whose flag was never set.
      if registry.session.val.stale: return pfBehindTip
      let blocks = vm.indexedBlocks.val
      if blocks.len == 0: return pfCurrent
      if registry.session.val.head.height > blocks[0].height: pfBehindTip
      else: pfCurrent)

    vm.reachability = createMemo(proc(): DeliveryReachability =
      if monitor.reachable.val: drReachable else: drCdnUnreachable)

    vm.finalizedHeight = createMemo(proc(): int =
      if registry.hasSession.val and registry.session.val.hasFinalized:
        registry.session.val.finalized.height
      else: 0)

    vm.hasFinality = createMemo(proc(): bool =
      registry.hasSession.val and registry.session.val.hasFinalized)

    vm
