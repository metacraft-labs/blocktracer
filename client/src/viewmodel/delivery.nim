## viewmodel/delivery.nim
##
## The one place a transport failure is told apart from a missing object.
##
## §14's "CDN unreachable" row has a service-worker treatment, and
## Front-End-Architecture §3's table names no `DeliveryVM` — so this is
## deliberately **not** a ViewModel. It is a small reactive monitor that
## `ChainVM` owns and reads, because the condition still has to be *established*
## somewhere and the alternative is worse than an extra file.
##
## ## The bug this exists to prevent
##
## The Client SDK's read seam collapses both cases into one value on purpose:
## `ObjectResponse.found = false`, documented as "a `404` is not an error"
## because "the read path is full of objects that legitimately may not exist
## yet". That is right for the SDK — a package that reads published files must
## not turn an absent on-demand artifact into an exception — and it means the
## SDK cannot answer *why* an object was not returned. Only the consumer's own
## `fetchProc` knows whether the origin answered.
##
## If nobody makes that distinction, every transport failure renders as
## §14's "Object not found" row: **"not on this chain", listing chains that
## were never actually reached.** That is a page telling a user something false
## about the chain, which is why `cdCdnUnreachable` outranks `cdObjectNotFound`
## in `chain_degradation.nim`'s precedence.
##
## ## The shape
##
## `deliveryStore` wraps a transport that reports `TransportOutcome` and hands
## back an ordinary `ObjectStore`, so every Client SDK call — `openChain`,
## `transaction`, `resolveTraces` — is unchanged and unaware. The monitor
## observes from the side.

import isonim/core/[signals, computation]

import ./contract_equality   # the facade, plus `==` for its discriminated unions

type
  TransportOutcome* = enum
    ## What the consumer's transport actually did.
    toOk = "ok"
      ## The origin answered with the object.
    toMissing = "missing"
      ## The origin answered, and said there is no such object. A `404` under
      ## `/t/` is this (Trace-Artifacts.md §2.9) and it is data, not a failure.
    toUnreachable = "unreachable"
      ## The origin did not answer: DNS, TLS, a dead socket, an offline tab, a
      ## `5xx`. Nothing may be concluded about whether the object exists.

  TransportResult* = object
    outcome*: TransportOutcome
    body*: string

  DeliveryMonitor* = ref object
    ## Reactive state about the transport itself. Not a `ViewModel`: it owns no
    ## reactive root and is created inside whichever VM reads it.
    reachable*: Signal[bool]
    consecutiveFailures*: Signal[int]
    lastUnreachablePath*: Signal[string]
    totalReads*: Signal[int]
    unreachableAfter*: int
      ## How many consecutive transport failures before the origin is declared
      ## unreachable. Not a signal: it is configuration, fixed for the monitor's
      ## life, and making it reactive would invite it changing mid-page.

proc newDeliveryMonitor*(unreachableAfter = 1): DeliveryMonitor =
  ## `unreachableAfter` defaults to 1 because a single unanswered read is
  ## already enough to make "not on this chain" a false statement, and §14's
  ## treatment is a fallback (the service worker serves what it has) rather
  ## than a blank page — so declaring it early costs nothing and declaring it
  ## late costs a lie.
  DeliveryMonitor(
    reachable: createSignal(true),
    consecutiveFailures: createSignal(0),
    lastUnreachablePath: createSignal(""),
    totalReads: createSignal(0),
    unreachableAfter: max(1, unreachableAfter),
  )

proc noteRead*(m: DeliveryMonitor; path: string; outcome: TransportOutcome) =
  ## Record one read. `toMissing` is a *success* of the transport and clears the
  ## failure run: the origin answered.
  m.totalReads.val = m.totalReads.val + 1
  case outcome
  of toOk, toMissing:
    m.consecutiveFailures.val = 0
    m.reachable.val = true
  of toUnreachable:
    let n = m.consecutiveFailures.val + 1
    m.consecutiveFailures.val = n
    m.lastUnreachablePath.val = path
    if n >= m.unreachableAfter:
      m.reachable.val = false

proc deliveryStore*(name: string; m: DeliveryMonitor;
                    fetch: proc(path: string): TransportResult {.closure.}): ObjectStore =
  ## An `ObjectStore` over a transport that distinguishes the two cases, with
  ## the distinction routed to `m` and erased from the SDK's view — which is
  ## what lets every Client SDK call stay unchanged.
  ##
  ## An unreachable read is reported to the SDK as `found = false`, because
  ## there is no third value in `ObjectResponse` and inventing one would mean
  ## changing the SDK to carry a delivery concept. The information is not lost;
  ## it moved to the monitor, and `ChainVM.reachability` is what a page reads.
  newObjectStore(name, proc(path: string): ObjectResponse =
    let r = fetch(path)
    m.noteRead(path, r.outcome)
    case r.outcome
    of toOk: ObjectResponse(found: true, body: r.body)
    of toMissing, toUnreachable: ObjectResponse(found: false))

proc reachabilityMemo*(m: DeliveryMonitor): Memo[bool] =
  ## `reachable`, as a memo, so a VM's snapshot memo has one uniform kind of
  ## dependency to read.
  createMemo(proc(): bool = m.reachable.val)
