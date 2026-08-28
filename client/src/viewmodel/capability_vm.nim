## viewmodel/capability_vm.nim
##
## `CapabilityVM` — Front-End-Architecture §3: "Which replay capabilities this
## browser actually has, and the fallback rung in force — §14.2".
##
## ## Why this exists when the Embed SDK already has `CapabilityRung`
##
## M2b's review named this exact question and answered it: "deleting
## `CapabilityVM` because 'the SDK already has `CapabilityRung`' would be the
## wrong conclusion". The SDK's enum is what a *pane* renders. This VM
## *establishes* which value that is, and the establishing needs two things the
## Embed SDK does not have and must not grow:
##
##   1. **The probe.** §14.2's "Detected" column is four host facts —
##      `compileStreaming` throwing, a worker constructor failing, an allocation
##      budget exceeded, a `200` where a `206` was requested. They are the
##      host's, and BlockTracer is the host.
##   2. **The container's size.** §14.2's range-requests row does not fall
##      straight to the ladder: it says "memory-only whole-file path **if the
##      trace fits**, else the ladder". Whether it fits is a question about a
##      published artifact of a known byte length, which is chain-shaped — the
##      length comes from the trace manifest — and is why this decision cannot
##      live one layer down.
##
## ## The ceiling is a refusal, not a preference
##
## Front-End-Architecture §9.5's last row is unusually blunt: a whole-container
## fallback above the size ceiling must be **refused**, because "loading a
## complete trace to work around a missing capability is the fallback the threat
## model prohibits — it turns a capability gap into an unbounded allocation".
## So `wholeFileFits` is a gate, not a hint, and above the ceiling this VM
## reports `hcRangeRequestsUnsupported` and lets the ladder do its job.
##
## The ceiling's *value* is a policy this VM holds as configuration. No spec
## section states a number, and inventing one as a constant in a shared module
## would make a local product decision look normative.
##
## ## The rung ladder is checked against the Embed SDK's, not assumed equal
##
## For the four failure values, `fallbackRung` below must agree with M2b's
## `capabilityRung`, or the explorer's chrome and the debugger's pane would
## offer a user two different next steps. `tests/tviewmodelseam.nim` compiles
## against the pinned Embed SDK and asserts the agreement value by value.
## `frMemoryOnlyWholeFile` is the one rung with no SDK counterpart, and
## correctly so: it is a *delivery* decision about how bytes reach the engine,
## made before the engine is handed anything, and M12's own deliverable list
## spells the ladder as "memory-only cache, trace download, open-in-desktop,
## static call/event summary".

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import blocktracer_client
import ./replay_status

type
  HostProbe* = object
    ## §14.2's failure table as four independent host facts, in the spelling of
    ## its "Detected" column. Four booleans rather than one enum because a
    ## browser can fail several at once and the probe should not have to decide
    ## which to report — that ordering is `capabilityOf`'s job, stated once.
    wasmCompiles*: bool
      ## `compileStreaming` succeeded.
    workerSupported*: bool
      ## Feature detection at session start.
    rangeRequestsHonoured*: bool
      ## A `206` came back where a `206` was requested. A `200` is §14.2's
      ## hostile intermediary (Trace-Artifacts.md §5.3).
    memorySufficient*: bool
      ## No allocation failure and the budget was not exceeded.

  FallbackRung* = enum
    ## §14.2's ladder, "in order, stopping at the first that works", plus the
    ## memory-only rung M12's deliverable list names ahead of it.
    frFullDebugger = "fullDebugger"
      ## Not a rung — the engine runs over range requests.
    frMemoryOnlyWholeFile = "memoryOnlyWholeFile"
      ## §14.2: "memory-only whole-file path if the trace fits". The engine
      ## still runs; only the transport changed.
    frTraceDownload = "traceDownload"
      ## §14.2 rung 1: "the container is self-contained and the user keeps
      ## something useful."
    frOpenInDesktop = "openInDesktop"
      ## §14.2 rung 2: "the one path that always works."
    frStaticSummary = "staticSummary"
      ## §14.2 rung 3: a call and event summary with no replay engine at all.
      ## "The floor is a useful page, not an apology."

  CapabilityVM* = ref object of ViewModel
    # -- State --
    probe*: Signal[HostProbe]
    containerBytes*: Signal[int]
      ## The current artifact's container length, from `containerBytes(trace)`.
      ## Zero means "not known yet", which is not the same as "empty" and is
      ## why `wholeFileFits` is false for it: refusing to promise a whole-file
      ## load for a container of unknown size is the safe direction.
    wholeContainerCeiling*: Signal[int]

    # -- Derived --
    wholeFileFits*: Memo[bool]
    capability*: Memo[HostCapability]
      ## The value the seam writes.
    rung*: Memo[FallbackRung]
    engineRuns*: Memo[bool]
      ## Whether a debugger opens at all, on either transport. The gate a
      ## Debug affordance reads, so a button that cannot succeed is never
      ## offered — §14's rule, applied one layer above where M2b applied it.
    downloadOffered*: Memo[bool]
    desktopOffered*: Memo[bool]
    staticSummaryOnly*: Memo[bool]

const
  DefaultWholeContainerCeilingBytes* = 32 * 1024 * 1024
    ## The default ceiling for §9.5's whole-container fallback. A product
    ## policy, not a spec constant — see the module doc. Exposed as a default
    ## for a signal rather than used directly, so a deployment can lower it
    ## without a code change and a test can drive both sides of it.

func capableProbe*(): HostProbe =
  ## A host that meets every requirement. Named rather than relying on
  ## zero-initialisation, which for a record of booleans would mean *no*
  ## capability and would make the undegraded case the awkward one to write.
  HostProbe(wasmCompiles: true, workerSupported: true,
            rangeRequestsHonoured: true, memorySufficient: true)

func capabilityOf*(probe: HostProbe; wholeFileFits: bool): HostCapability =
  ## §14.2's four failures, in the one order that makes each report the cause
  ## rather than a symptom of it.
  ##
  ## Worker support first: the WASM engine lives *in* the worker, so with no
  ## worker there is nothing for `compileStreaming` to have failed at, and
  ## reporting a compilation failure would name the wrong cause. Memory next,
  ## because §14.2's response to it is to terminate the worker — a decision
  ## that outranks how bytes were going to be transported. Ranges last, and
  ## only after the whole-file escape hatch has been considered.
  if not probe.workerSupported: return hcWorkerUnsupported
  if not probe.wasmCompiles: return hcWasmCompilationFailed
  if not probe.memorySufficient: return hcInsufficientMemory
  if not probe.rangeRequestsHonoured:
    # §14.2: "memory-only whole-file path if the trace fits, else the ladder".
    # When it fits the engine genuinely runs, so the honest report to the pane
    # is `capable` — reporting the broken ranges would put a pane into a
    # fallback while the debugger beside it is stepping.
    return if wholeFileFits: hcCapable else: hcRangeRequestsUnsupported
  hcCapable

func fallbackRung*(capability: HostCapability;
                   rangeRequestsHonoured: bool): FallbackRung =
  ## The rung in force. For the four failure values this must agree with the
  ## Embed SDK's `capabilityRung`; see the module doc for where that is checked.
  case capability
  of hcCapable:
    if rangeRequestsHonoured: frFullDebugger else: frMemoryOnlyWholeFile
  of hcRangeRequestsUnsupported: frTraceDownload
  of hcWasmCompilationFailed, hcWorkerUnsupported: frOpenInDesktop
  of hcInsufficientMemory: frStaticSummary

proc setProbe*(vm: CapabilityVM; probe: HostProbe) =
  vm.probe.val = probe

proc noteWasmCompilationFailed*(vm: CapabilityVM) =
  var p = vm.probe.val
  p.wasmCompiles = false
  vm.probe.val = p

proc noteWorkerUnsupported*(vm: CapabilityVM) =
  var p = vm.probe.val
  p.workerSupported = false
  vm.probe.val = p

proc noteInsufficientMemory*(vm: CapabilityVM) =
  ## §14.2: the worker is terminated. Reported as a probe result rather than as
  ## an exception, because the page survives and has to render the rung.
  var p = vm.probe.val
  p.memorySufficient = false
  vm.probe.val = p

proc noteRangeRequestsBroken*(vm: CapabilityVM) =
  ## A `200` where a `206` was requested — §14.2's hostile intermediary.
  var p = vm.probe.val
  p.rangeRequestsHonoured = false
  vm.probe.val = p

proc setArtifact*(vm: CapabilityVM; r: ResolvedTrace) =
  vm.containerBytes.val = containerBytes(r)

proc createCapabilityVM*(ceiling = DefaultWholeContainerCeilingBytes): CapabilityVM =
  withViewModel proc(dispose: proc()): CapabilityVM =
    let vm = CapabilityVM(
      probe: createSignal(capableProbe()),
      containerBytes: createSignal(0),
      wholeContainerCeiling: createSignal(ceiling),
    )

    vm.wholeFileFits = createMemo(proc(): bool =
      let bytes = vm.containerBytes.val
      bytes > 0 and bytes <= vm.wholeContainerCeiling.val)

    vm.capability = createMemo(proc(): HostCapability =
      capabilityOf(vm.probe.val, vm.wholeFileFits.val))

    vm.rung = createMemo(proc(): FallbackRung =
      fallbackRung(vm.capability.val, vm.probe.val.rangeRequestsHonoured))

    vm.engineRuns = createMemo(proc(): bool =
      vm.rung.val in {frFullDebugger, frMemoryOnlyWholeFile})

    vm.downloadOffered = createMemo(proc(): bool =
      vm.rung.val == frTraceDownload)

    vm.desktopOffered = createMemo(proc(): bool =
      # The desktop rung is reachable from below as well as at it: §14.2 calls
      # it "the one path that always works", so a page on the static-summary
      # floor still offers it. Only a running engine does not.
      vm.rung.val in {frOpenInDesktop, frStaticSummary})

    vm.staticSummaryOnly = createMemo(proc(): bool =
      vm.rung.val == frStaticSummary)

    vm
