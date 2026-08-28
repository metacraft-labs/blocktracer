## viewmodel/generation_job_vm.nim
##
## `GenerationJobVM` — Front-End-Architecture §3: "The on-demand job state
## machine — accepted/queued/recording/validating/publishing/ready/refused/
## failed/timedOut, cancellability, retryability, estimate, and whether the
## result is retained or windowed (Page-Descriptions.md §14.1)".
##
## §14.1's opening line is the requirement: "Polling a URL until a file appears
## is a transport mechanism, not a user experience."
##
## ## What is here and what is blocked
##
## The **state machine** is here, complete, with every rule §14.1 states made
## structural rather than described:
##
##   * `refused` is not `failed`. They are separate values with separate
##     reasons, because "collapsing them produces a retry button that can never
##     succeed".
##   * `retryable` is carried, never computed. §14.1: "`retryable` is stated by
##     the pipeline, not guessed by the client." `canRetry` reads the flag the
##     job carried and no heuristic of this VM's.
##   * Cancellable only before work starts. `accepted` and `queued` cancel and
##     release quota; from `recording` on, "the compute is spent and
##     cancellation would only hide it", so `cancel` refuses.
##   * Phase, not percentage. There is no `progress` field and there will not
##     be one: "a percentage across a recorder run would be invented". What is
##     exposed is the named phase, the elapsed time, and a coarse estimate that
##     is explicitly labelled as one.
##   * Say what the user is getting. `resultRetention` carries whether the
##     result is retained or windowed, "before the request, and again on
##     completion".
##
## **The transport is blocked, and is named rather than stubbed.** There is no
## `/enqueue` service in this repository, no job endpoint and no client for one;
## Static-Site-Architecture.md §6 lists "`/enqueue` unavailable" as a failure
## mode of a service that arrives with the pipeline's on-demand path. So this VM
## has no `submit()` that opens a connection — the Client SDK excludes
## networking of its own by design — and instead exposes `request`, `applyJob`
## and `noteFailure`, which the shell drives from whatever transport it has.
## Every state below is reachable through those, which is what the suite walks.
##
## The one input this VM *does* derive itself is the entry condition: a
## `trkOnDemand` trace with no published manifest is §14's "Trace awaiting
## generation" row before any job exists, and `startedFromTrace` is how a page
## gets from a resolved trace to `jsIdle` with a Generate affordance rather than
## to an error.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import blocktracer_client
import ./chain_degradation

type
  JobState* = enum
    ## §14.1's table, in its order, plus `jsIdle` for "no request has been
    ## made", which the table does not list because it is not a job state — but
    ## a page needs it, and folding it into `jsRefused` would show a reason
    ## where there is none.
    jsIdle = "idle"
    jsAccepted = "accepted"      ## taken; quota consumed. Cancellable
    jsQueued = "queued"          ## waiting for a worker; position known. Cancellable
    jsRecording = "recording"    ## the recorder is executing the transaction
    jsValidating = "validating"  ## the recorder is checking its own output
    jsPublishing = "publishing"  ## artifact is being written and made visible
    jsReady = "ready"            ## done; the debugger opens
    jsRefused = "refused"        ## will not be attempted — read why
    jsFailed = "failed"          ## attempted and did not succeed
    jsTimedOut = "timedOut"      ## exceeded the job budget

  RefusalReason* = enum
    ## §14.1's `refused` row names three, and Pipeline-Architecture.md's
    ## machine-readable tokens are the spelling — "a client cannot parse
    ## prose": `chain_unsupported`, `tx_not_published`, `below_history_floor`.
    rrNone = "none"
    rrOutOfQuota = "out_of_quota"
    rrChainUnsupported = "chain_unsupported"
    rrBelowHistoryFloor = "below_history_floor"
    rrTxNotPublished = "tx_not_published"
    rrOther = "other"

  ResultRetention* = enum
    ## §14.1's last rule: "state whether the resulting trace is retained or
    ## windowed, and for how long. A user who bookmarks a link deserves to know
    ## it may need regenerating later."
    rtUnstated = "unstated"
    rtRetained = "retained"
    rtWindowed = "windowed"

  JobUpdate* = object
    ## One observation of the job, as the transport reports it. A record rather
    ## than nine setters, so a state and the fields that explain it can never be
    ## applied half-way.
    state*: JobState
    queuePosition*: int
    retryable*: bool
      ## Stated by the pipeline. Never derived here — see the module doc.
    refusalReason*: RefusalReason
    message*: string
    retention*: ResultRetention
    retentionSeconds*: int
      ## How long a windowed result is kept. Zero when unstated.

  GenerationJobVM* = ref object of ViewModel
    # -- State --
    state*: Signal[JobState]
    queuePosition*: Signal[int]
    retryable*: Signal[bool]
    refusalReason*: Signal[RefusalReason]
    message*: Signal[string]
    resultRetention*: Signal[ResultRetention]
    retentionSeconds*: Signal[int]
    elapsedSeconds*: Signal[int]
      ## Advanced by the shell's clock. A signal rather than a timer inside the
      ## VM, for the reason §6 gives for `TestClock` existing at all: a
      ## ViewModel that read wall time would not be deterministic to test.
    estimateSeconds*: Signal[int]
      ## §14.1's "coarse estimate derived from this chain's recent
      ## generations", supplied by whoever knows those. Zero means none was
      ## supplied, and `hasEstimate` is what a view reads so an absent estimate
      ## never renders as "0s remaining".
    cancelRequested*: Signal[bool]
    generationPending*: Signal[bool]
      ## Whether a generation is *wanted* — a `trkOnDemand` trace with no
      ## published manifest — as distinct from one being in flight.
      ##
      ## Without this, `jsIdle` would be ambiguous: it is the state of a page
      ## that never needed a trace **and** the state of a page whose trace has
      ## not been requested yet, and collapsing them would put §14's "Trace
      ## awaiting generation" row on every transaction in the explorer. Seeded
      ## by `startedFromTrace`, which is the only place that knows which.

    # -- Derived --
    inFlight*: Memo[bool]
    cancellable*: Memo[bool]
    canRetry*: Memo[bool]
    terminal*: Memo[bool]
    hasEstimate*: Memo[bool]
    phaseLabel*: Memo[string]
      ## The named phase, never a percentage.
    provenance*: Memo[TraceProvenance]
      ## The axis `chain_degradation.nim` resolves: this VM's contribution to
      ## §14's "Trace awaiting generation" row.

const
  CancellableStates* = {jsAccepted, jsQueued}
    ## §14.1: "Cancellable before work starts." Stated as data so the rule is
    ## assertable directly rather than read out of `cancel`'s control flow.

  InFlightStates* = {jsAccepted, jsQueued, jsRecording, jsValidating,
                     jsPublishing}

  TerminalStates* = {jsReady, jsRefused, jsFailed, jsTimedOut}

  RetryableStates* = {jsFailed, jsTimedOut}
    ## §14.1's "User can" column offers Retry on exactly these two, and
    ## deliberately not on `refused` — "one means we will not do this and here
    ## is why; the other means we tried".

func initJobUpdate*(state: JobState): JobUpdate =
  JobUpdate(state: state, refusalReason: rrNone, retention: rtUnstated)

proc applyJob*(vm: GenerationJobVM; u: JobUpdate) =
  ## Apply one observation. Every field moves together; see `JobUpdate`.
  vm.state.val = u.state
  vm.queuePosition.val = u.queuePosition
  vm.retryable.val = u.retryable
  vm.refusalReason.val = u.refusalReason
  vm.message.val = u.message
  if u.retention != rtUnstated:
    vm.resultRetention.val = u.retention
    vm.retentionSeconds.val = u.retentionSeconds
  if u.state notin InFlightStates:
    vm.cancelRequested.val = false

proc request*(vm: GenerationJobVM) =
  ## The user asked. Moves to `accepted` — §14.1: "The request was taken; quota
  ## consumed." The transport that actually enqueues is the shell's; see the
  ## module doc.
  vm.applyJob(initJobUpdate(jsAccepted))
  vm.elapsedSeconds.val = 0

proc cancel*(vm: GenerationJobVM): bool =
  ## Cancel, if §14.1 allows it at this state. Returns whether it was accepted,
  ## so a view can tell "cancelled" from "too late" without re-deriving the
  ## rule.
  if vm.state.val notin CancellableStates: return false
  vm.cancelRequested.val = true
  vm.applyJob(initJobUpdate(jsIdle))
  true

proc retry*(vm: GenerationJobVM): bool =
  ## Retry, only where the pipeline said it is retryable. Returns whether it was
  ## accepted — the two ways it is refused (a non-retryable failure, and
  ## `jsRefused`) are exactly the button §14.1 says must not exist.
  if vm.state.val notin RetryableStates: return false
  if not vm.retryable.val: return false
  vm.request()
  true

proc tick*(vm: GenerationJobVM; seconds = 1) =
  ## Advance elapsed time. Driven by the shell's clock so tests are
  ## deterministic.
  if vm.state.val in InFlightStates:
    vm.elapsedSeconds.val = vm.elapsedSeconds.val + seconds

proc startedFromTrace*(vm: GenerationJobVM; r: ResolvedTrace) =
  ## Seed the VM from a resolved trace, before any job exists.
  ##
  ## `trkOnDemand` with no manifest is §14's "Trace awaiting generation" row in
  ## its pre-request form: the address is derivable, the object is not there,
  ## and the honest state is `jsIdle` with a Generate affordance. A published
  ## artifact is `jsReady`, which is what lets one memo drive both "the
  ## debugger opens" and "the job finished".
  if r.kind == trkOnDemand and not r.hasManifest:
    vm.generationPending.val = true
    vm.applyJob(initJobUpdate(jsIdle))
  elif r.kind == trkOnDemand and r.hasManifest:
    # The overlay was written before the artifact existed and the artifact has
    # since been published. The manifest is the authority — a page that read
    # only the overlay would offer to generate a trace it is already holding.
    vm.generationPending.val = false
    vm.applyJob(initJobUpdate(jsReady))
  elif r.isReplayable:
    vm.generationPending.val = false
    vm.applyJob(initJobUpdate(jsReady))
  elif r.kind in {trkAbsent, trkUnsupported}:
    vm.generationPending.val = false
    var u = initJobUpdate(jsRefused)
    u.refusalReason = rrChainUnsupported
    u.message = r.reason
    vm.applyJob(u)
  else:
    vm.generationPending.val = false
    vm.applyJob(initJobUpdate(jsIdle))

proc createGenerationJobVM*(): GenerationJobVM =
  withViewModel proc(dispose: proc()): GenerationJobVM =
    let vm = GenerationJobVM(
      state: createSignal(jsIdle),
      queuePosition: createSignal(0),
      retryable: createSignal(false),
      refusalReason: createSignal(rrNone),
      message: createSignal(""),
      resultRetention: createSignal(rtUnstated),
      retentionSeconds: createSignal(0),
      elapsedSeconds: createSignal(0),
      estimateSeconds: createSignal(0),
      cancelRequested: createSignal(false),
      generationPending: createSignal(false),
    )

    vm.inFlight = createMemo(proc(): bool = vm.state.val in InFlightStates)
    vm.cancellable = createMemo(proc(): bool = vm.state.val in CancellableStates)
    vm.terminal = createMemo(proc(): bool = vm.state.val in TerminalStates)
    vm.hasEstimate = createMemo(proc(): bool = vm.estimateSeconds.val > 0)

    vm.canRetry = createMemo(proc(): bool =
      vm.state.val in RetryableStates and vm.retryable.val)

    vm.phaseLabel = createMemo(proc(): string =
      case vm.state.val
      of jsIdle: ""
      of jsAccepted: "Accepted"
      of jsQueued: "Queued"
      of jsRecording: "Recording"
      of jsValidating: "Validating"
      of jsPublishing: "Publishing"
      of jsReady: "Ready"
      of jsRefused: "Refused"
      of jsFailed: "Failed"
      of jsTimedOut: "Timed out")

    vm.provenance = createMemo(proc(): TraceProvenance =
      case vm.state.val
      of jsReady: tpAvailable
      of jsRefused:
        # A refusal names its own row where §14 has one. `below_history_floor`
        # is a §14 row in its own right and must not be flattened into "a job
        # was refused", or the page would offer a retry against a floor.
        case vm.refusalReason.val
        of rrBelowHistoryFloor: tpBelowHistoryFloor
        of rrChainUnsupported: tpRecorderUnavailable
        else: tpAwaitingGeneration
      of jsIdle:
        # See `generationPending`: an idle VM on a page that never needed a
        # trace is not degraded, and saying it is would put §14's row on every
        # transaction in the explorer.
        if vm.generationPending.val: tpAwaitingGeneration else: tpAvailable
      of jsAccepted, jsQueued, jsRecording, jsValidating,
         jsPublishing, jsFailed, jsTimedOut:
        tpAwaitingGeneration)

    vm
