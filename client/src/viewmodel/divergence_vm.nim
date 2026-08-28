## viewmodel/divergence_vm.nim
##
## `DivergenceVM` — Front-End-Architecture §3: "Validation result and its
## presentation state — banner, detail, comparison".
##
## §14's row: "Divergence detected → Non-dismissible banner above the debugger,
## with the specific mismatch." Two words in that sentence are requirements
## this VM has to make true rather than describe:
##
##   * **Non-dismissible.** There is no `dismiss` action proc on this VM, and
##     that absence is the enforcement. A banner a view can hide is a banner
##     that will be hidden; §14 puts the rule at this layer for the same reason
##     it puts every other degraded state here.
##   * **The specific mismatch.** A banner reading "validation failed" is the
##     generic error §14 exists to prevent, so `detail` is only ever the
##     pipeline's own verdict, and `hasDetail` says plainly when the tree gave
##     none.
##
## ## Why the validation summary has a `strength` and what may be done with it
##
## M5b's `ValidationSummary` carries `status` plus `strength`, and the contract
## comments that `strength` is "the only field the UI interprets (ordered
## rank)". So this VM exposes it as an ordered rank and does **not** map it to
## words: the vocabulary for a rank belongs to whoever set it, and inventing
## "weak"/"strong" labels here would be this layer asserting a scale the
## producer never published.
##
## ## Two verdicts, and which wins
##
## A divergence can be stated in the overlay (`ExecTrace.validation`, available
## before any fetch) and in the manifest (`TraceManifest.validation`, the
## pipeline's verdict on the bytes it actually published). The manifest wins
## when present, because it is the verdict about the container the debugger is
## about to open; the overlay is what lets the banner render on the first paint
## instead of the second.
##
## `vsUnchecked` is deliberately not a divergence. §14's banner is for a
## mismatch that was found, and showing it for a trace nobody validated would
## make the banner mean two different things — after which it means neither.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ./contract_equality   # the facade, plus `==` for its discriminated unions
import ./replay_status

type
  DivergenceSource* = enum
    ## Which layer stated the verdict this VM is presenting.
    dsNone = "none"
    dsOverlay = "overlay"       ## `ExecTrace.validation` — pre-fetch
    dsManifest = "manifest"     ## `TraceManifest.validation` — post-fetch
    dsAvailability = "availability"
      ## The overlay's `availability: divergent` with no validation summary
      ## attached. The producer said it diverged and gave no detail; §14 still
      ## requires the banner, and `hasDetail` is what says the detail is
      ## missing rather than inventing one.

  DivergenceVM* = ref object of ViewModel
    # -- State --
    trace*: Signal[ResolvedTrace]
    hasTrace*: Signal[bool]
    comparisonOpen*: Signal[bool]
      ## Whether the detail/comparison disclosure is expanded. Presentation
      ## state, which §3's row explicitly assigns to this VM — but note it
      ## gates the *detail*, never the banner.

    # -- Derived --
    detected*: Memo[bool]
      ## Whether the banner is shown. There is no path to `false` other than
      ## the tree saying so; see the module doc.
    source*: Memo[DivergenceSource]
    status*: Memo[ValidationStatus]
    strength*: Memo[int]
    hasDetail*: Memo[bool]
    oracle*: Memo[string]
      ## The manifest's `validationOracle` — which differential oracle
      ## disagreed. Empty before the manifest is in hand.
    integrity*: Memo[ArtifactIntegrity]
      ## The value this VM contributes to the seam. Truncation is not this VM's
      ## to state, so it never emits `aiTruncated`; `ArtifactVM` owns that and
      ## `replay_status.integrityFor` is where the two are ranked.

proc setTrace*(vm: DivergenceVM; r: ResolvedTrace) =
  vm.trace.val = r
  vm.hasTrace.val = true
  # A new trace is a new verdict; an expanded comparison from the previous one
  # would be showing the wrong mismatch.
  vm.comparisonOpen.val = false

proc toggleComparison*(vm: DivergenceVM) =
  vm.comparisonOpen.val = not vm.comparisonOpen.val

proc createDivergenceVM*(): DivergenceVM =
  withViewModel proc(dispose: proc()): DivergenceVM =
    let vm = DivergenceVM(
      trace: createSignal(ResolvedTrace()),
      hasTrace: createSignal(false),
      comparisonOpen: createSignal(false),
    )

    vm.source = createMemo(proc(): DivergenceSource =
      if not vm.hasTrace.val: return dsNone
      let t = vm.trace.val
      if t.hasManifest and t.manifest.validation.status != vsUnchecked:
        return dsManifest
      if t.hasValidation and t.validation.status != vsUnchecked:
        return dsOverlay
      if t.kind == trkDivergent: return dsAvailability
      dsNone)

    vm.status = createMemo(proc(): ValidationStatus =
      case vm.source.val
      of dsManifest: vm.trace.val.manifest.validation.status
      of dsOverlay: vm.trace.val.validation.status
      of dsAvailability: vsDivergent
      of dsNone: vsUnchecked)

    vm.detected = createMemo(proc(): bool =
      vm.status.val == vsDivergent)

    vm.strength = createMemo(proc(): int =
      case vm.source.val
      of dsManifest: vm.trace.val.manifest.validation.strength
      of dsOverlay: vm.trace.val.validation.strength
      of dsAvailability, dsNone: 0)

    vm.hasDetail = createMemo(proc(): bool =
      vm.source.val in {dsManifest, dsOverlay})

    vm.oracle = createMemo(proc(): string =
      if vm.hasTrace.val and vm.trace.val.hasManifest:
        vm.trace.val.manifest.validationOracle
      else: "")

    vm.integrity = createMemo(proc(): ArtifactIntegrity =
      if vm.detected.val: aiDivergent else: aiComplete)

    vm
