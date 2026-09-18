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
## ## The history floor
##
## §14's row reads: "Transaction below the history floor → Debug absent,
## stating the floor and that prestate does not exist below it", and §14.1's
## `refused` row names `below_history_floor` as a reason the pipeline states
## rather than the client guesses (Pipeline-Architecture.md §705 spells the
## machine-readable token).
##
## **The chain ingest now writes one, measured from the capture's own replay
## window**, so `fvBelow` is reachable from a produced tree and not only from a
## fixture. This VM reads the field when the registry carries it and reports
## `fvUnstated` when it does not — the honest answer, and what makes
## `belowHistoryFloor` a row that can be *established* rather than one that can
## only be asserted. A tree without the field cannot produce `fvBelow`, and both
## trees are driven: a produced one carrying a measured floor, and the same
## capture with the boundary removed.
##
## ONE SPELLING IS ACCEPTED, and it used to be two. `contract/chain_profile.nim`
## states why the object won and why a bare integer is refused by name rather
## than ignored; this VM does not restate the rule, it calls it.
##
## ## Chains that do not order by height, and who says so
##
## `TxOrder` is a discriminated union because ordering is not universal: Hedera
## orders by consensus time, Aptos by a global version, Sui by checkpoint, TON
## by logical time. A floor expressed as a height cannot be compared against any
## of those, and `fvNotComparable` says so instead of coercing a `0`.
##
## **The kind is the CHAIN's declaration, not an inference from the row in
## hand.** It used to be the latter — `blockPosition` reports `known: false` for
## any order that is not `blockIndex`, and this VM concluded from that one row
## that the chain does not order by height. That answers correctly and for the
## wrong reason, and the wrong reason shows up twice: a row this client failed
## to decode reads as a chain with no heights, and a chain that genuinely has no
## heights cannot be told apart from a tree with one odd row in it. The registry
## states the chain's ordering kind now (Configuration.md §2.1, from
## Static-Site-Architecture.md §2.3's union), and a declaration this build does
## not recognise is **also** not comparable — the conservative direction, because
## "we cannot read how this chain is ordered" is not "it is ordered by height".

import std/json

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./chain_degradation

type
  HistoryFloor* = ChainHistoryFloor
    ## The lowest position a chain's prestate is obtainable for.
    ##
    ## An ALIAS and not a second declaration, which it used to be. This VM held
    ## its own three-field copy of the contract's floor, and a milestone whose
    ## subject is "two spellings of one fact drift" should not leave a second
    ## spelling of the floor in the consumer that reads it. `stated` is not
    ## "zero" — it is "unknown", and the two must not render the same — and the
    ## shape rule that produces it lives in `contract/chain_profile.nim`, which
    ## is also what the producer-side validator reports findings from.

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
    profile*: Signal[ChainProfile]
      ## Everything else the active chain's row declares about itself — its
      ## reach, its ordering kind and its instruction-set identity. Reloaded by
      ## `selectChain` beside the floor, from the same row and the same read.
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
    instructionSet*: Memo[string]
      ## The instruction-set identity this chain declares its recordings are
      ## written against, or `""`. It is what a consumer holding mnemonic tables
      ## SELECTS one with, and it is available here — before any recording is
      ## opened — which is the whole reason the identity is on the chain's row
      ## and not only in each listing. Selecting a table still names nothing: the
      ## table has to predict the recording's own program counters, which is
      ## `instruction_listing.nim`'s check and is unchanged.

proc registryRow(registry: JsonNode; chain: string): JsonNode =
  ## This chain's row, or `nil`. One navigation, shared by everything below, so
  ## the profile and the floor are read out of the same object rather than by
  ## two walks that could disagree about which row they found.
  if registry.isNil or registry.kind != JObject: return nil
  if not registry.hasKey("chains"): return nil
  let cs = registry["chains"]
  if cs.kind != JObject or not cs.hasKey(chain): return nil
  let entry = cs[chain]
  if entry.kind != JObject: return nil
  entry

proc readChainProfile*(registry: JsonNode; chain: string): ChainProfile =
  ## The whole declaration. Exposed so a test can drive it directly rather than
  ## only through a whole tree.
  parseChainProfile(registryRow(registry, chain))

proc readHistoryFloor*(registry: JsonNode; chain: string): HistoryFloor =
  ## The accepted spelling, or `stated = false`.
  ##
  ## The shape rule is `contract/chain_profile.parseHistoryFloor`'s and is not
  ## restated here — this is the same predicate the producer-side validator
  ## reports findings from, so the client and the validator cannot come to
  ## disagree about what a registry says. A member present in a shape the
  ## contract refuses reads as unstated HERE and as a finding THERE, which is
  ## the right division: a page renders what it can and a validator names what
  ## is wrong.
  parseHistoryFloor(registryRow(registry, chain){FloorMember})

proc loadProfile(vm: ChainRegistryVM; chain: string): ChainProfile =
  let version =
    if vm.hasSession.val: vm.session.val.contractVersion else: ContractVersion
  let r = vm.store.getJson(registryPath(version))
  if not r.found or r.error.len > 0: return
  readChainProfile(r.node, chain)

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
  let p = vm.loadProfile(chain)
  vm.profile.val = p
  vm.floor.val = p.floor

proc orderedByHeight*(vm: ChainRegistryVM): bool =
  ## Whether a HEIGHT is a quantity this chain can be compared on at all.
  ##
  ## Three cases and only one of them is `true`, which is the whole content of
  ## this function:
  ##
  ##   * the chain declares `blockIndex` — heights sequence it, compare;
  ##   * the chain declares any other member of §2.3's union — it is sequenced
  ##     by something else and a height means nothing on it;
  ##   * the chain declares nothing this build recognises, or nothing at all —
  ##     also not comparable. An undeclared ordering is the compatibility case
  ##     and an unrecognised one is a producer this build cannot read, and
  ##     neither is evidence that heights apply.
  ##
  ## The third case is the one worth stating: treating silence as `blockIndex`
  ## would make the default a claim, and the claim would be made loudest on
  ## exactly the chains that do not order by height, because those are the ones
  ## whose producers have not been written yet.
  vm.profile.val.ordering.state == dsDeclared and
    vm.profile.val.ordering.kind == tokBlockIndex

proc floorVerdict*(vm: ChainRegistryVM; position: BlockPosition): FloorVerdict =
  ## Where a transaction sits relative to the floor. Takes the position rather
  ## than the whole transaction so the comparison is testable without a tree.
  ##
  ## THE COMPARABILITY TEST COMES FIRST AND COMES FROM THE CHAIN. A registry
  ## that states a height floor for a chain sequenced by consensus time has
  ## stated two things that cannot be put beside each other, and the answer is
  ## `fvNotComparable` however this particular row happens to be shaped —
  ## including when the row carries a perfectly good height, which is the case
  ## an inference from the row would get wrong.
  let f = vm.floor.val
  if not f.stated: return fvUnstated
  if not vm.orderedByHeight: return fvNotComparable
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
      profile: createSignal(ChainProfile()),
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

    vm.instructionSet = createMemo(proc(): string =
      if vm.profile.val.vm.stated: vm.profile.val.vm.instructionSet else: "")

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
