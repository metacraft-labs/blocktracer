## viewmodel/artifact_vm.nim
##
## `ArtifactVM` — Front-End-Architecture §3: "Availability filters,
## artifact-id derivation, manifest fetch, range residency and fill progress".
##
## This is the VM that *establishes* §14.1a's replay-availability row for the
## panes. It writes `ReplayAvailability` through the seam
## (`replay_status.nim` → `ReplayDataStore.setReplayAvailability` /
## `CtReplayStatus`), and it also establishes `TraceIntegrity`, because both
## come out of the same manifest fetch.
##
## ## The four things it does, and where each is normative
##
## | Concern | Normative in | Here |
## | --- | --- | --- |
## | Availability filters | Static-Site-Architecture.md §2.3a | `select`, `filterBy` |
## | Artifact-id derivation | Trace-Artifacts.md §2.1 | delegated to the Client SDK, which uses the producer's own `deriveTraceArtifactId` |
## | Manifest fetch | Trace-Artifacts.md §4 | `resolve` / `resolveAll` |
## | Range residency and fill progress | Trace-Artifacts.md §5.1, Front-End-Architecture §4.3 | `RangeResidency` below |
##
## The derivation is deliberately *not* reimplemented here. `resolveExec` calls
## `deriveTraceArtifactId` from `blocktracer/contract/ids` — the same module the
## producer and the conformance validator use — which is what makes "the client
## computes the URL the pipeline wrote to" true by construction rather than by
## two implementations agreeing.
##
## ## Range residency, and what is honestly missing
##
## The range store lives in the replay worker (§4.3's "ONE worker, owning
## everything below"), and **that worker does not exist yet** — it is M12's
## debug route. What exists here is the accounting a page renders from it:
## aligned windows over a container of a known size, how many are resident, and
## what fraction of the container has been filled. It is pure arithmetic over
## `manifest.container.bytes` and `manifest.container.blockSize`, so it is fully
## testable now and needs no worker to be correct; what it needs a worker for is
## someone to call `noteWindowResident`. That input is named as missing rather
## than faked: with no worker, `fillFraction` reads 0.0, which is the true
## answer for a session that has fetched nothing.
##
## The alignment rule is the one §4.3 states and gives a reason for: "Range
## windows are aligned to fixed boundaries so repeat visits request identical
## ranges and can hit that cache." A window index is therefore a byte offset
## divided by the block size, and never a running counter.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./replay_status

type
  RangeResidency* = object
    ## The range store's accounting, as a value a page can render.
    containerBytes*: int
    windowBytes*: int
      ## The aligned window size. From `manifest.container.blockSize` when the
      ## manifest states one, so the client's windows line up with the
      ## container's own block boundaries rather than cutting across them.
    residentWindows*: int
    totalWindows*: int

  ArtifactVM* = ref object of ViewModel
    store*: ObjectStore

    # -- State --
    traces*: Signal[seq[ResolvedTrace]]
      ## Every execution of the current transaction, resolved. A transaction
      ## with several independently-debuggable executions (the Aztec
      ## private/public split) has several, and collapsing them would lose the
      ## one that is debuggable.
    selected*: Signal[int]
      ## Index into `traces`, or -1. Defaults to `bestTrace`.
    residentWindows*: Signal[seq[int]]
      ## Aligned window indices the range store holds. Written by the replay
      ## worker; see the module doc for why nothing writes it yet.

    # -- Derived --
    current*: Memo[ResolvedTrace]
    hasSelection*: Memo[bool]
    availabilityCounts*: Memo[array[TraceResolutionKind, int]]
      ## How many executions are in each state. The input to §2.3a's
      ## availability filters, and the reason a transaction page can say "one
      ## of two executions is debuggable" rather than picking one silently.
    residency*: Memo[RangeResidency]
    fillFraction*: Memo[float]
      ## 0.0 .. 1.0. Zero windows over a zero-byte container is 0.0, not a
      ## division by zero and not 1.0 — "nothing to fetch" and "everything
      ## fetched" are different claims.
    retention*: Memo[ArtifactRetention]
      ## §14.1a, as the wire value the seam writes.
    integrity*: Memo[ArtifactIntegrity]
      ## §14's truncation and divergence rows, likewise.

const DefaultWindowBytes* = 65536
  ## Used when a manifest states no block size. A concrete default rather than
  ## zero, because a zero window size would make `totalWindows` meaningless and
  ## the arithmetic below silently degenerate.

func residencyOf*(r: ResolvedTrace; resident: openArray[int]): RangeResidency =
  ## Pure, so the accounting is testable without a VM or a store.
  let bytes = containerBytes(r)
  var window = DefaultWindowBytes
  if r.hasManifest and r.manifest.container.blockSize > 0:
    window = r.manifest.container.blockSize
  var total = 0
  if bytes > 0:
    total = (bytes + window - 1) div window
  # Only windows that exist are counted. A worker reporting a window past the
  # end of the container is a bug in the worker, and counting it would let
  # `fillFraction` exceed 1.0 and hide it.
  var seen: seq[int]
  for w in resident:
    if w >= 0 and w < total and w notin seen:
      seen.add w
  RangeResidency(containerBytes: bytes, windowBytes: window,
                 residentWindows: seen.len, totalWindows: total)

func fillFractionOf*(res: RangeResidency): float =
  if res.totalWindows <= 0: 0.0
  else: res.residentWindows.float / res.totalWindows.float

proc setTraces*(vm: ArtifactVM; traces: seq[ResolvedTrace]) =
  ## Replace the resolved set and re-select. Residency is cleared: it described
  ## a different container.
  ##
  ## `bestTrace` returns the strongest **debuggable** execution and `-1` when
  ## there is none — a transaction whose only execution is structurally absent,
  ## or whose chain has no recorder pinned. Falling back to index 0 rather than
  ## leaving `-1` is not cosmetic: `current` would otherwise be a default
  ## `ResolvedTrace`, whose `kind` is `trkReady` because that is the first
  ## value of the enum. A page would then read "ready" for a transaction that
  ## can never be replayed, which is the most dangerous possible default and is
  ## precisely the silent-healthy-state failure §14 exists to prevent.
  vm.traces.val = traces
  vm.residentWindows.val = @[]
  let best = bestTrace(traces)
  vm.selected.val =
    if best >= 0: best
    elif traces.len > 0: 0
    else: -1

proc resolveAll*(vm: ArtifactVM; session: ChainSession; v: TransactionView;
                 probeOnDemand = true) =
  ## Resolve every execution of `v` and select the strongest.
  vm.setTraces(resolveTraces(vm.store, session, v, probeOnDemand))

proc select*(vm: ArtifactVM; selector: string): bool =
  ## Choose an execution by the producer's own selector ("public", "private",
  ## "0"). Returns false and changes nothing when there is no such execution,
  ## rather than silently landing on another one.
  for i, t in vm.traces.val:
    if t.selector == selector:
      vm.selected.val = i
      vm.residentWindows.val = @[]
      return true
  false

proc noteWindowResident*(vm: ArtifactVM; window: int) =
  ## Called by the replay worker when an aligned window has been filled.
  if window < 0: return
  var ws = vm.residentWindows.val
  if window notin ws:
    ws.add window
    vm.residentWindows.val = ws

proc createArtifactVM*(store: ObjectStore): ArtifactVM =
  withViewModel proc(dispose: proc()): ArtifactVM =
    let vm = ArtifactVM(
      store: store,
      traces: createSignal(newSeq[ResolvedTrace]()),
      selected: createSignal(-1),
      residentWindows: createSignal(newSeq[int]()),
    )

    vm.hasSelection = createMemo(proc(): bool =
      let i = vm.selected.val
      i >= 0 and i < vm.traces.val.len)

    vm.current = createMemo(proc(): ResolvedTrace =
      let ts = vm.traces.val
      let i = vm.selected.val
      if i >= 0 and i < ts.len: ts[i] else: ResolvedTrace())

    vm.availabilityCounts = createMemo(proc(): array[TraceResolutionKind, int] =
      for t in vm.traces.val:
        inc result[t.kind])

    vm.residency = createMemo(proc(): RangeResidency =
      residencyOf(vm.current.val, vm.residentWindows.val))

    vm.fillFraction = createMemo(proc(): float =
      fillFractionOf(vm.residency.val))

    vm.retention = createMemo(proc(): ArtifactRetention =
      if vm.traces.val.len == 0:
        # No overlay entry was even resolved. `arUnreplayable` rather than an
        # unwritten axis, for `retentionFor`'s reason: an unset axis lands on
        # the store's seeded `raRetained` and reports a healthy replay.
        arUnreplayable
      else: retentionFor(vm.current.val))

    vm.integrity = createMemo(proc(): ArtifactIntegrity =
      if vm.traces.val.len == 0: aiComplete else: integrityFor(vm.current.val))

    vm
