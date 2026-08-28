## viewmodel/chain_registry_vm.nim
##
## `ChainRegistryVM` — Front-End-Architecture §3, row 1: "Loaded registry,
## active chain, coverage mode, history floor".
##
## It is the first VM every surface reads, because it answers the question
## every other answer is conditional on: **is this a chain we publish at all?**
## §14's "Object not found" row is "'Not on this chain' with the chains
## checked", and the chains that were checked are this VM's `chains` — read
## from the signed registry rather than by listing directories, because a
## consumer reading over HTTP has no directory listing.
##
## ## The history floor, and what is honestly missing
##
## §14's row reads: "Transaction below the history floor → Debug absent,
## stating the floor and that prestate does not exist below it", and §14.1's
## `refused` row names `below_history_floor` as a reason the pipeline states
## rather than the client guesses (Pipeline-Architecture.md §705 spells the
## machine-readable token).
##
## **No producer in this repository writes a history floor.** The demo
## generator emits a registry with `recorder`, `profile` and `traceSchema` per
## chain and nothing else; real per-chain floors arrive with M6's ingestion.
## So this VM reads the field **when the registry carries it** and reports
## `fvUnstated` when it does not — which is the honest answer, and is what makes
## `belowHistoryFloor` a row that can be *established* rather than one that can
## only be asserted. A tree without the field cannot produce `fvBelow`, and the
## test suite drives both a tree with the field and a tree without it, so
## neither branch is theoretical.
##
## The shape read is the minimal one the spec's wording implies — a height,
## with an optional reason — and both a bare integer and an object are
## accepted, because a registry field with no normative schema should not be
## made brittle by a consumer guessing one of two spellings.
##
## ## Chains that do not order by height
##
## `TxOrder` is a discriminated union because ordering is not universal: Hedera
## orders by consensus time, Aptos by a global version, Sui by checkpoint, TON
## by logical time. A floor expressed as a height cannot be compared against
## any of those, and `fvNotComparable` says so instead of coercing a `0`.
## Silently answering "above the floor" for a chain whose transactions have no
## height would make the row unreachable on exactly the chains most likely to
## need it.

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./chain_degradation

type
  HistoryFloor* = object
    ## The lowest block a chain's prestate is obtainable for.
    stated*: bool
      ## Whether the registry said anything at all. `false` is not "zero"; it
      ## is "unknown", and the two must not render the same.
    height*: int
    reason*: string
      ## The producer's words, when it supplied any.

  FloorVerdict* = enum
    fvAbove = "above"
      ## At or above the floor — or the chain publishes none, see `fvUnstated`.
    fvBelow = "below"
      ## §14's row. Terminal: prestate does not exist below the floor, so no
      ## generation can succeed, which is why `chain_degradation.nim` ranks it
      ## above `cdRecorderUnavailable`.
    fvUnstated = "unstated"
      ## The registry states no floor for this chain.
    fvNotComparable = "notComparable"
      ## The chain does not order transactions by block height.

  ChainRegistryVM* = ref object of ViewModel
    ## Signals for the registry as loaded, memos for what it implies.
    store*: ObjectStore

    # -- State --
    chains*: Signal[seq[string]]
      ## Every chain the registry publishes, sorted. The list §14's "not on
      ## this chain" row must name.
    registryLoaded*: Signal[bool]
    activeChain*: Signal[string]
    floor*: Signal[HistoryFloor]
      ## The active chain's floor. Reloaded by `selectChain`.
    session*: Signal[ChainSession]
    hasSession*: Signal[bool]
    openOutcome*: Signal[OpenOutcome]
    openReason*: Signal[string]

    # -- Derived --
    knownChain*: Memo[bool]
      ## Whether `activeChain` is one the registry publishes.
    coverageMode*: Memo[string]
      ## `summary.json`'s coverage mode for the pinned generation — "eager",
      ## "selective", "onDemand". Empty when no session is open.
    recorderPinned*: Memo[bool]
      ## Whether a recorder is pinned for this chain. `false` is §14's
      ## "Recorder unavailable for the VM" row at chain granularity: no trace
      ## address can be derived at all (Trace-Artifacts.md §2.1).
    presence*: Memo[ObjectPresence]
      ## The chain slug itself, as the axis `chain_degradation.nim` resolves.

proc readHistoryFloor*(registry: JsonNode; chain: string): HistoryFloor =
  ## Both accepted spellings, or `stated = false`. Exposed so a test can drive
  ## it directly rather than only through a whole tree.
  if registry.isNil or registry.kind != JObject: return
  if not registry.hasKey("chains"): return
  let cs = registry["chains"]
  if cs.kind != JObject or not cs.hasKey(chain): return
  let entry = cs[chain]
  if entry.kind != JObject or not entry.hasKey("historyFloor"): return
  let hf = entry["historyFloor"]
  case hf.kind
  of JInt:
    HistoryFloor(stated: true, height: hf.getInt)
  of JObject:
    if not hf.hasKey("height") or hf["height"].kind != JInt: HistoryFloor()
    else: HistoryFloor(stated: true, height: hf["height"].getInt,
                       reason: hf{"reason"}.getStr)
  else:
    HistoryFloor()

proc loadFloor(vm: ChainRegistryVM; chain: string): HistoryFloor =
  let version =
    if vm.hasSession.val: vm.session.val.contractVersion else: ContractVersion
  let r = vm.store.getJson(registryPath(version))
  if not r.found or r.error.len > 0: return HistoryFloor()
  readHistoryFloor(r.node, chain)

proc loadRegistry*(vm: ChainRegistryVM) =
  ## Read the signed registry once. An unreadable registry leaves `chains`
  ## empty and `registryLoaded` false, which every caller must treat as "we do
  ## not know what we publish" rather than as "we publish nothing" — the
  ## difference `DeliveryMonitor` exists to preserve.
  let cs = chains(vm.store)
  vm.chains.val = cs
  vm.registryLoaded.val = cs.len > 0

proc selectChain*(vm: ChainRegistryVM; chain: string) =
  ## Make `chain` active and pin its generation. §3.3's session: `current.json`
  ## is resolved exactly once here and never consulted again for this session,
  ## so no sequence of reads below can drift across generations.
  vm.activeChain.val = chain
  let opened = openChain(vm.store, chain)
  vm.openOutcome.val = opened.outcome
  case opened.outcome
  of ooOpened:
    vm.session.val = opened.session
    vm.hasSession.val = true
    vm.openReason.val = ""
  else:
    vm.hasSession.val = false
    vm.openReason.val = opened.reason
  vm.floor.val = vm.loadFloor(chain)

proc floorVerdict*(vm: ChainRegistryVM; position: BlockPosition): FloorVerdict =
  ## Where a transaction sits relative to the floor. Takes the position rather
  ## than the whole transaction so the comparison is testable without a tree.
  let f = vm.floor.val
  if not f.stated: return fvUnstated
  if not position.known: return fvNotComparable
  if position.height < f.height: fvBelow else: fvAbove

proc floorVerdictFor*(vm: ChainRegistryVM; v: TransactionView): FloorVerdict =
  ## The same, for a transaction as read.
  vm.floorVerdict(blockPosition(v))

proc createChainRegistryVM*(store: ObjectStore): ChainRegistryVM =
  ## Create the VM inside a reactive root owned by `withViewModel`; dispose via
  ## `vm.dispose()`.
  withViewModel proc(dispose: proc()): ChainRegistryVM =
    let vm = ChainRegistryVM(
      store: store,
      chains: createSignal(newSeq[string]()),
      registryLoaded: createSignal(false),
      activeChain: createSignal(""),
      floor: createSignal(HistoryFloor()),
      session: createSignal(ChainSession()),
      hasSession: createSignal(false),
      openOutcome: createSignal(ooChainNotFound),
      openReason: createSignal(""),
    )

    vm.knownChain = createMemo(proc(): bool =
      let want = vm.activeChain.val
      want.len > 0 and want in vm.chains.val)

    vm.coverageMode = createMemo(proc(): string =
      if vm.hasSession.val: vm.session.val.coverageMode else: "")

    vm.recorderPinned = createMemo(proc(): bool =
      vm.hasSession.val and vm.session.val.hasPin)

    vm.presence = createMemo(proc(): ObjectPresence =
      # A chain that opened is present whatever the registry listed, because
      # the generation pointer is the stronger evidence. A chain that failed to
      # open because its contract version is unsupported, or because its
      # `root.json` did not decode, is `opMalformed` — the tree has this chain
      # and the tree is wrong, and telling a user it is "not on this chain"
      # would be a false statement about the chain rather than about the tree.
      if vm.hasSession.val: opPresent
      else:
        case vm.openOutcome.val
        of ooOpened, ooChainNotFound: opNotOnThisChain
        of ooUnsupportedContract, ooMalformed: opMalformed)

    vm
