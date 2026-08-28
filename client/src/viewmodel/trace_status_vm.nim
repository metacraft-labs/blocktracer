## viewmodel/trace_status_vm.nim
##
## `TraceStatusVM` — Front-End-Architecture §3: "Whether a trace is published,
## unsupported or divergent".
##
## It establishes two of §14's seven chain-shaped rows and contributes to a
## third:
##
## | §14 row                             | From                                              |
## | ----------------------------------- | ------------------------------------------------- |
## | Recorder unavailable for the VM     | `trkUnsupported`, or `trkUnresolvable` (no recorder pinned in the registry) |
## | Trace awaiting generation           | `trkOnDemand` with no published manifest          |
## | Transaction below the history floor | deferred to `ChainRegistryVM`, which owns the floor |
##
## ## Two distinct ways a recorder can be unavailable
##
## §14's row is one line — "Debug absent with the recorder's status and a link
## to its spec" — and the tree can say it in two structurally different places,
## which this VM keeps apart because they need different links:
##
##   * The **overlay** says `unsupported` for this execution, with the
##     producer's own reason (Static-Site-Architecture.md §2.3a requires one).
##     That is a per-execution statement.
##   * The **registry** pins no recorder for the chain, so no `traceArtifactId`
##     can be derived at all (Trace-Artifacts.md §2.1). That is a per-chain
##     statement, and it is `trkUnresolvable`.
##
## Both resolve to `tpRecorderUnavailable`, and `recorderUnavailableScope` says
## which, so a page can link to a recorder's spec in the first case and to the
## chain's support row in the second rather than guessing.
##
## ## `reconstructed` lives here, and deliberately nowhere else
##
## `ResolvedTrace.reconstructed` is orthogonal to availability: a trace can be
## `ready` **and** heuristically reconstructed, and Static-Site-Architecture.md
## §2.3a calls presenting the second as a native execution trace "the confident
## lie". The Embed SDK's four axes have no value for it and must not grow one —
## it is a chain concept. So it is surfaced here, as `reconstructed`, and
## `replay_status.nim` deliberately does not fold it into `integrity`.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./chain_degradation
import ./chain_registry_vm

type
  RecorderScope* = enum
    ## Which layer said the recorder is unavailable — see the module doc.
    rsNone = "none"
    rsExecution = "execution"   ## the overlay, for this execution
    rsChain = "chain"           ## the registry, for the whole chain

  TraceStatusVM* = ref object of ViewModel
    registry*: ChainRegistryVM

    # -- State --
    trace*: Signal[ResolvedTrace]
    hasTrace*: Signal[bool]
    floorVerdict*: Signal[FloorVerdict]
      ## Written by the page from `ChainRegistryVM.floorVerdictFor`. Kept as a
      ## signal rather than recomputed here because the floor is the registry
      ## VM's to own and a second derivation would be a second place to
      ## disagree about it.

    # -- Derived --
    published*: Memo[bool]
      ## A container exists to open, right now.
    reconstructed*: Memo[bool]
    divergent*: Memo[bool]
    recorderUnavailableScope*: Memo[RecorderScope]
    provenance*: Memo[TraceProvenance]
      ## The axis `chain_degradation.nim` resolves. Three of §14's rows.
    reason*: Memo[string]
      ## The producer's words where it supplied any, this package's otherwise.
      ## Never empty when `provenance != tpAvailable`: §14 requires every one
      ## of these rows to state why, and a blank reason is the failure mode
      ## that turns a specific refusal into a generic error.

proc setTrace*(vm: TraceStatusVM; r: ResolvedTrace) =
  vm.trace.val = r
  vm.hasTrace.val = true

proc clearTrace*(vm: TraceStatusVM) =
  vm.trace.val = ResolvedTrace()
  vm.hasTrace.val = false

proc createTraceStatusVM*(registry: ChainRegistryVM): TraceStatusVM =
  withViewModel proc(dispose: proc()): TraceStatusVM =
    let vm = TraceStatusVM(
      registry: registry,
      trace: createSignal(ResolvedTrace()),
      hasTrace: createSignal(false),
      floorVerdict: createSignal(fvUnstated),
    )

    vm.published = createMemo(proc(): bool =
      vm.hasTrace.val and vm.trace.val.isReplayable)

    vm.reconstructed = createMemo(proc(): bool =
      vm.hasTrace.val and vm.trace.val.reconstructed)

    vm.divergent = createMemo(proc(): bool =
      if not vm.hasTrace.val: return false
      let t = vm.trace.val
      t.kind == trkDivergent or
        (t.hasValidation and t.validation.status == vsDivergent) or
        (t.hasManifest and t.manifest.validation.status == vsDivergent))

    vm.recorderUnavailableScope = createMemo(proc(): RecorderScope =
      if not vm.hasTrace.val: return rsNone
      case vm.trace.val.kind
      of trkUnsupported: rsExecution
      of trkUnresolvable: rsChain
      else: rsNone)

    vm.provenance = createMemo(proc(): TraceProvenance =
      # The floor is checked first. It is the only one of the three that is a
      # statement about the *transaction* rather than about the artifact, and
      # a transaction below the floor cannot have a trace generated for it at
      # all — so reporting "awaiting generation" for one would be §14's retry
      # that cannot succeed.
      if vm.floorVerdict.val == fvBelow: return tpBelowHistoryFloor
      if not vm.hasTrace.val: return tpAvailable
      case vm.trace.val.kind
      of trkUnsupported, trkUnresolvable: tpRecorderUnavailable
      of trkOnDemand:
        if vm.trace.val.hasManifest: tpAvailable else: tpAwaitingGeneration
      of trkReady, trkDivergent, trkAbsent, trkNoOverlay, trkNoExecution:
        # `trkAbsent` is NOT a chain-shaped row: §14's structurally-absent case
        # is carried by the Embed SDK's `raUnreplayable`, written through
        # `replay_status.nim`, and duplicating it here would be the double
        # count M2b's 7/6 split exists to prevent.
        tpAvailable)

    vm.reason = createMemo(proc(): string =
      if vm.floorVerdict.val == fvBelow:
        let f = vm.registry.floor.val
        let stated =
          "this transaction is below the chain's history floor at block " &
          $f.height & "; prestate does not exist below it, so no recording " &
          "can be made of it"
        return if f.reason.len > 0: stated & " (" & f.reason & ")" else: stated
      if not vm.hasTrace.val: return ""
      let t = vm.trace.val
      if t.reason.len > 0: return t.reason
      case t.kind
      of trkUnsupported:
        "no recorder exists for this chain's virtual machine"
      of trkUnresolvable:
        "no recorder is pinned for this chain in the registry, so no trace " &
        "address can be derived"
      of trkOnDemand:
        if t.hasManifest: "" else: "no trace has been generated for this execution yet"
      else: "")

    vm
