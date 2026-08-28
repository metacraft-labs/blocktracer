## viewmodel/transaction_vm.nim
##
## `TransactionVM` — Front-End-Architecture §3: "One transaction: normalised
## model, native payload, decoded input, logs, derived sections".
##
## The surface that renders the most of §14's chain-shaped rows — six of the
## seven are in `TransactionDegradations` — and therefore the one where the
## composition matters most: `degradation` below is a single memo reading
## signals in four other ViewModels, with no bridge and no message passing,
## which is Front-End-Architecture §2's central structural claim.
##
## ## The three layers stay three layers
##
## `TransactionView` keeps facts, generation state and the trace overlay as
## separate fields rather than flattening them, and this VM does not flatten
## them either. Static-Site-Architecture.md §2.3 gives the reason: "which layer
## a fact came from is what tells a consumer whether it can change — a
## flattened `finality` next to a `hash` invites caching the pair, and a pointer
## object cached across a navigation is the classic explorer bug".
##
## ## Ordering is asked about, never assumed
##
## `orderLabel` is the chain's own coordinate spelled the chain's own way, and
## `position.known` is false for the chains that have no height. Nothing here
## fabricates a block number for Hedera, Aptos, Sui or TON — which is also what
## makes `ChainRegistryVM`'s `fvNotComparable` reachable rather than dead.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./chain_degradation
import ./chain_registry_vm
import ./chain_vm
import ./trace_status_vm
import ./generation_job_vm

type
  TransactionVM* = ref object of ViewModel
    store*: ObjectStore
    registry*: ChainRegistryVM
    chain*: ChainVM
    traceStatus*: TraceStatusVM
    job*: GenerationJobVM

    # -- State --
    hash*: Signal[string]
    view*: Signal[TransactionView]
    outcome*: Signal[ReadOutcome]
    reason*: Signal[string]
    loaded*: Signal[bool]
      ## Whether `load` has run. "Not asked yet" and "not found" are different
      ## states; see `BlockVM.loaded`.
    reIncludedIn*: Signal[string]
      ## Read once during `load`, never from a memo — see
      ## `ChainVM.readReIncludedIn` for why a memo that issued a read would
      ## re-enter itself forever.

    # -- Derived --
    found*: Memo[bool]
    presence*: Memo[ObjectPresence]
    reorg*: Memo[ReorgState]
    position*: Memo[BlockPosition]
    orderLabel*: Memo[string]
    primaryRole*: Memo[Role]
    headlineAvailability*: Memo[TraceAvailability]
    codeHashes*: Memo[seq[string]]
    snapshot*: Memo[ChainStateSnapshot]
      ## The five axes, read together — one read of each dependency per
      ## evaluation, which is why this is one memo and not five arguments at
      ## every call site.
    degradation*: Memo[ChainDegradation]
      ## `TransactionDegradations`, resolved. The single value a view renders a
      ## treatment for.

proc load*(vm: TransactionVM; txHash: string) =
  ## Read the three layers at the pinned generation.
  vm.hash.val = txHash
  vm.loaded.val = true
  vm.reIncludedIn.val = ""
  if not vm.registry.hasSession.val:
    vm.outcome.val = roNotFound
    vm.reason.val = "no chain is open"
    vm.view.val = TransactionView()
    return
  let r = transaction(vm.store, vm.registry.session.val, txHash)
  vm.outcome.val = r.outcome
  case r.outcome
  of roFound:
    vm.view.val = r.view
    vm.reason.val = ""
    # One extra read, and only for the transactions that need it: a canonical
    # transaction has no re-inclusion to look for.
    if r.view.hasState and not r.view.canonical:
      vm.reIncludedIn.val = vm.chain.readReIncludedIn(txHash)
  else:
    vm.view.val = TransactionView()
    vm.reason.val = r.reason

proc createTransactionVM*(store: ObjectStore; registry: ChainRegistryVM;
                          chain: ChainVM; traceStatus: TraceStatusVM;
                          job: GenerationJobVM): TransactionVM =
  withViewModel proc(dispose: proc()): TransactionVM =
    let vm = TransactionVM(
      store: store, registry: registry, chain: chain,
      traceStatus: traceStatus, job: job,
      hash: createSignal(""),
      view: createSignal(TransactionView()),
      outcome: createSignal(roNotFound),
      reason: createSignal(""),
      reIncludedIn: createSignal(""),
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

    vm.reorg = createMemo(proc(): ReorgState =
      if vm.outcome.val != roFound: ReorgState(canonicality: ccCanonical)
      else: reorgStateOf(vm.view.val, vm.reIncludedIn.val))

    vm.position = createMemo(proc(): BlockPosition =
      if vm.outcome.val != roFound: BlockPosition()
      else: blockPosition(vm.view.val))

    vm.orderLabel = createMemo(proc(): string =
      if vm.outcome.val != roFound: "" else: orderLabel(vm.view.val))

    vm.primaryRole = createMemo(proc(): Role =
      if vm.outcome.val != roFound: Role() else: primaryRole(vm.view.val))

    vm.headlineAvailability = createMemo(proc(): TraceAvailability =
      if vm.outcome.val != roFound: taUnsupported
      else: headlineAvailability(vm.view.val))

    vm.codeHashes = createMemo(proc(): seq[string] =
      if vm.outcome.val != roFound: @[]
      else: codeHashes(vm.view.val.facts))

    vm.snapshot = createMemo(proc(): ChainStateSnapshot =
      # The one place the five axes are assembled for this surface. Each comes
      # from the VM that established it; none is re-derived here, which is what
      # keeps "one canonical treatment" true across surfaces.
      var s = initChainStateSnapshot()
      s.reachability = chain.reachability.val
      s.presence = vm.presence.val
      s.canonicality = vm.reorg.val.canonicality
      # A transaction page is a published page, so §14's staleness row does not
      # apply to it (see `TransactionDegradations`). The axis is still read
      # honestly rather than pinned to `pfCurrent`, so a surface that IS
      # sensitive gets the truth from the same snapshot.
      s.freshness = chain.freshness.val
      # Provenance has two contributors — `TraceStatusVM` from what the
      # published tree said, `GenerationJobVM` from what the pipeline decided
      # about a request — and they are ranked by severity, not by whichever
      # spoke last. See `strongerProvenance` for the concrete failure that
      # "the job wins" would produce.
      s.provenance = strongerProvenance(job.provenance.val,
                                        traceStatus.provenance.val)
      s)

    vm.degradation = createMemo(proc(): ChainDegradation =
      resolveChainDegradation(vm.snapshot.val, TransactionDegradations))

    vm
