## The origin chain, read on the seam this repository owns.
##
## ## Why a decorator, again
##
## `OriginChainVM.onShowOrigin` builds the `ct/originChain` request and then
## does this with the future:
##
##     discard vm.store.backend.send("ct/originChain", args)
##
## — the same shape as `ReplayDataStore.requestLocals`, and the same
## consequence: the VM issues the request and nothing reads the answer, so
## `activeChain` stays `none` for the life of the session. `applyChainResponse`
## exists for a caller that has the decoded chain, and in the pinned SDK the
## only such caller is the desktop app's `ui/state.nim`.
##
## So the reply is picked up where `live_locals` and `live_navigation` pick
## theirs up: on the `BackendService` the store is built on, which every
## request the ViewModels issue passes through. One request, one reply, one
## writer, no pin bump — the arrangement the ledger entry already describes for
## the locals.
##
## ## The event, too
##
## The engine also emits `ct/updated-origin-chain` unprompted (measured: four
## of them arrive during an ordinary stepping session before anything asks for
## a chain). It carries the same body shape as the response, so it is decoded
## by the same function and applied through the same `applyChainResponse` —
## with `requestId = -1`, which that proc documents as "apply regardless of
## which request this answers", because an unsolicited event answers none.
##
## ## What counts as an origin worth offering
##
## `classifiedOriginOf` is the one place that decides, and it requires all
## three of the things the engine gets wrong together:
##
##   * a terminator that is not `unknownSource`,
##   * a non-zero confidence,
##   * a terminator expression with something in it.
##
## The engine answers `success: true` either way. Before the source reached it
## every summary in every session was `terminatorKind: "unknownSource"`,
## `confidence: 0` — so a check that asked "did the call succeed" or "is there
## a summary" would pass on all of them, and put a control on every row that
## could only ever answer "unknown". That is the false pass this module is
## written around.

import std/[json, options, tables]

import isonim/core/async_compat
import codetracer_embed

# ---------------------------------------------------------------------------
# What the State pane may offer
# ---------------------------------------------------------------------------

func classifiedOriginOf*(summary: OriginSummary): string =
  ## The terminator expression when this summary is a real classification, and
  ## the empty string when it is not.
  ##
  ## The empty string is the answer for the two states that are NOT failures
  ## and must not be dressed as one:
  ##
  ##   * `unknownSource` with `confidence: 0` — the engine could not attribute
  ##     the value. Every value of every recording that published no source is
  ##     in this state, permanently and correctly.
  ##   * a placeholder awaiting a `ct/originSummary` fill — there is a chain,
  ##     but this reply does not carry it yet.
  ##
  ## Both mean "do not offer a control", and they mean it for different
  ## reasons, which is why the caller gets a string rather than a bool: the
  ## string is what the control would SAY, so a control can only be rendered
  ## where there is something to say.
  if summary.isPlaceholder: return ""
  if summary.terminatorKind == tkwUnknownSource: return ""
  if summary.confidence <= 0.0: return ""
  summary.terminatorExpr

func classifiedCount*(summaries: openArray[(string, OriginSummary)]): int =
  ## How many of these summaries are real classifications.
  ##
  ## Exists so the count can be ASSERTED rather than inferred from the number
  ## of rows or the number of successful replies, which are the two numbers
  ## that stay high while this one is zero.
  for (_, s) in summaries:
    if classifiedOriginOf(s).len > 0: inc result

# ---------------------------------------------------------------------------
# The feed
# ---------------------------------------------------------------------------

type
  OriginFeed* = ref object
    ## One session's `ct/originChain` traffic.
    ##
    ## A `ref` for the reason `LocalsFeed` is one: the decorated
    ## `BackendService` closes over it and it outlives every request.
    chain*: OriginChainVM
      ## Assigned by `openLiveSession` once the VM exists. The VM is built ON
      ## the decorated service, so the decoration cannot be handed the VM at
      ## construction time; this is where that knot is tied, in one place,
      ## exactly as `LocalsFeed.store` and `NavigationFeed.eventLog` are.
    chainsApplied*: int
      ## How many chains have been written into the VM. Read by the tests to
      ## tell "the reply was routed" from "the reply was successful", which
      ## were previously the same observation.

proc applyChain*(feed: OriginFeed; body: JsonNode; requestId: int) =
  ## One `ct/originChain` body, into the VM.
  if feed.isNil or feed.chain.isNil: return
  if body.isNil or body.kind != JObject: return
  feed.chain.applyChainResponse(parseOriginChain(body), requestId)
  inc feed.chainsApplied

const
  OriginChainCommand* = "ct/originChain"
  UpdatedOriginChainEvent* = "ct/updated-origin-chain"
    ## The engine's unprompted push. Measured against the published engine:
    ## four arrive during an ordinary stepping session, before anything has
    ## asked for a chain.

proc handleEvent*(feed: OriginFeed; event: JsonNode) =
  ## One backend event. Everything that is not the one this module is named
  ## for is ignored — as in `live_navigation`, this is not a place to grow a
  ## second protocol layer.
  if feed == nil or event == nil or event.kind != JObject: return
  let name = event{"event"}.getStr("")
  if name != UpdatedOriginChainEvent: return
  let body = if event.hasKey("body"): event["body"] else: nil
  # `-1`, because an unsolicited event answers no request and comparing it
  # against `latestRequestId` would discard every one of them.
  feed.applyChain(body, -1)

proc withLiveOrigin*(inner: BackendService; feed: OriginFeed): BackendService =
  ## `inner`, with the `ct/originChain` reply read on its way back and the
  ## `ct/updated-origin-chain` event read on its way in.
  ##
  ## Both halves, because the chain arrives BOTH ways and a consumer that took
  ## only one would work until the engine changed its mind about which. The
  ## response is the answer to `onShowOrigin`; the event is the engine
  ## volunteering a chain it recomputed.
  ##
  ## Every other command passes through untouched, for the reason
  ## `withLiveLocals` gives: a decorator that inspected more than the one
  ## command it is named for would be a second protocol layer growing on a
  ## seam that exists to avoid one.
  if inner != nil and inner.onEventProc != nil:
    inner.onEvent(proc(event: JsonNode) = feed.handleEvent(event))
  BackendService(
    sendProc: proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
      let fut = inner.send(command, args)
      if command == OriginChainCommand:
        fut.onComplete(
          onSuccess = proc(response: JsonNode) =
            # `-1`: this decorator does not know the VM's request id — the VM
            # allocated it inside `onShowOrigin` and kept it. Applying rather
            # than comparing is right here because the decorator only ever
            # sees the reply to a request that WAS issued.
            if not response.isNil and response.kind == JObject and
               response{"success"}.getBool(true):
              feed.applyChain(response{"body"}, -1),
          onError = proc(message: string) = discard)
      fut,
    onEventProc: inner.onEventProc,
    disconnectProc: inner.disconnectProc)
