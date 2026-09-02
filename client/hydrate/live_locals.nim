## SDK-CONSUMER: the `ct/load-locals` reply, parsed and written into the store.
##
## ## The defect this module is
##
## `StateVM`'s auto-load effect (`state_vm.nim:575-580`) issues
## `store.requestLocals(dbg.rrTicks, ...)` on every debugger move, so a hydrated
## session asks the engine for its locals at every position it reaches. The
## request goes out. The reply is thrown away:
##
##     proc onComplete(fut: BackendFuture[JsonNode];
##                     onSuccess: proc(); onError: proc()) =
##       ## Convenience wrapper around `async_compat.onComplete` that DISCARDS
##       ## the result value and error message ...
##
## — `replay_data_store.nim:75-82`, and `requestLocals` (:628-681) uses it. Its
## own `onSuccess` sets `loadingState` and `loadedForRRTicks` and nothing else,
## under a comment that says "The actual JSON→Variable parsing will be added
## when the locals panel is converted". The only writer of
## `store.locals.locals` is `updateLocals` (:788), and nothing in a browser
## calls it. So `StateVM.currentVariables` is empty for the life of every
## hydrated session and the visitor keeps reading the STATICALLY EXPORTED State
## pane — the values of the frame the page was served at — however far they
## step. That is the failure this project cannot ship: a confident wrong answer,
## rendered identically to a right one.
##
## The store is behind `ci/embed-sdk-pin.env`, so its `onComplete` wrapper is
## not this repository's to change. Both ends of the wire are present and
## correct — the engine answers `ct/load-locals` (`db-backend/dap_handler.rs
## :955-1001`) and the store exports `updateLocals` — and what is missing is the
## middle. This module is the middle, on the one seam this repository owns.
##
## ## Why a decorated `BackendService` and not a second request
##
## The obvious fix is for `hydrate.nim` to send its own `ct/load-locals` beside
## the ViewModel's and parse that one. It would work and it would be the "two
## producers of one fact" arrangement this route has already been bitten by
## twice (`renderPanes`' `data-step` comment, `session_project.projectCalltrace`'s
## content hash): two requests per stop against a 50 ms navigation budget, two
## replies that can disagree, and a store whose `loadingState` is written by
## whichever lands last.
##
## `openLiveSession` constructs the `BackendService` the store is built on, so
## the ViewModel's OWN request passes through here on its way out and its OWN
## reply passes back through on the way in. One request, one reply, one writer.
## `async_compat.onComplete` attaches an additional handler rather than
## replacing one (`.then` on JS, `addCallback` on the native backends), so the
## store's bookkeeping still runs — after ours, which is the order that leaves
## `loadingState` idle and `loadedForRRTicks` set once the variables are in.
##
## ## Why the pane's state lives here and not in the store
##
## `store.locals.loadingState` and `store.locals.loadedForRRTicks` look like the
## natural place to keep "is what the pane shows current". They are not usable
## for it: the store's own discarded-reply handler sets both to "loaded, idle"
## on every reply INCLUDING one this module could not read, so a pane keyed on
## them would report a successful load of nothing. `LocalsFeed` is therefore
## this consumer's own account of what it asked for, what came back and what it
## made of it — and `projectState` reads it rather than guessing.

import std/[json, strutils]

import isonim/core/async_compat
import codetracer_embed

const
  LoadLocalsCommand* = "ct/load-locals"
    ## The command whose reply this module exists to read. Spelled here and
    ## compared against what the STORE sends, so a rename upstream shows up as
    ## a pane that never leaves `lpUnasked` rather than as a silent revert to
    ## the defect.

  ReadingNote* = "Reading the values at this position…"
    ## What the pane says between a move and its answer. A sentence about the
    ## CURRENT position, not the previous one's values.

  NoValuesNote* = "The engine reports no values at this position."
    ## A true empty frame. `renderPanes`' latch already argues this case: "a
    ## step to a frame with no locals is a true empty Values pane, and freezing
    ## the previous frame's values there would be the worse lie."

  RefusedNotePrefix* = "The replay engine did not answer with values here: "
  UnreadableNote* = "The replay engine's answer carried no values this page " &
    "could read."
  TimedOutNote* = "The replay engine did not answer with values for this " &
    "position."

  LocalsDeadlineMs* = 8000
    ## How long a position may wait for its values before the pane says it did
    ## not get them. §8 forbids an indeterminate wait, and a pane that says
    ## "Reading…" for as long as the tab is open is a spinner with a name. The
    ## engine is known to drop requests silently in some handshake orders
    ## (`backend/dap_dialect.md` §1), so this is a state that occurs rather
    ## than one guarded against in principle.

# ---------------------------------------------------------------------------
# The wire: CodeTracer's `Value`
# ---------------------------------------------------------------------------
#
# `ct/load-locals` answers `{"locals": [Variable]}` where `Variable` is
# `{expression, value, address, originSummary?}` (`db-backend/src/task.rs:44`,
# `:343`) and `value` is `db-backend/src/value.rs`'s `Value`: serde
# `rename_all = "camelCase"`, `default`, and a FLAT tagged layout — `kind`
# selects which of `i`/`f`/`b`/`c`/`text`/`cText`/`r`/`msg`/`elements` carries
# the data, with the type in `typ`.
#
# `kind` IS AN ORDINAL, not a name: `TypeKind` derives `Serialize_repr` over
# `#[repr(u8)]` (`libs/ct-dap-client/src/types/values.rs:1-43`, "TypeKind enum
# matching codetracer_trace_types"). The ordinals below are read off that
# declaration and cross-checked, position for position, against CodeTracer's
# own Nim copy of the same enum
# (`src/common/common_types/language_features/type.nim:3-38`, where index 6 is
# spelled `Instance` and everything else is spelled identically). Two
# independently maintained mirrors of one wire enum agreeing is the evidence
# these numbers rest on.
#
# THE PINNED SDK'S OWN COMMENT ON THIS IS WRONG, and it is the obvious thing to
# copy: `headless_session.nim:475-477` lists "7 = Int, 8 = Float, 3 = String,
# 4 = CString, 5 = Bool, 6 = Struct, 9 = Seq, 10 = Char, 11 = Tuple, 30 = None"
# and its `extractValueText` switches on exactly those. Int, Float, Struct and
# None are right and the rest are off: 3 is OrderedSet, 4 is Array, 5 is
# Varargs, 9 is String, 10 is CString, 11 is Char. That parser renders a Noir
# `Field` correctly and every string, bool, char, array and tuple as the empty
# string — which is the same shape of defect as the one this module fixes,
# one layer down, and the reason these ordinals are derived here rather than
# borrowed.

const
  tkSeq = 0
  tkSet = 1
  tkHashSet = 2
  tkOrderedSet = 3
  tkArray = 4
  tkVarargs = 5
  tkStruct = 6          ## `Instance` in the Nim copy
  tkInt = 7
  tkFloat = 8
  tkString = 9
  tkCString = 10
  tkChar = 11
  tkBool = 12
  tkRef = 14
  tkRaw = 16
  tkPointer = 23
  tkError = 24
  tkTuple = 27
  tkVariant = 28
  tkNone = 30
  tkNonExpanded = 31
  tkSlice = 33

  ValueDepthLimit = 8
    ## Compound values nest, and `requestLocals` asks the engine for seven
    ## levels. A recursion guard rather than a display decision: `Recursion`
    ## exists in the enum because a value graph can contain a cycle.

func isSequenceKind(kind: int): bool =
  kind in [tkSeq, tkSet, tkHashSet, tkOrderedSet, tkArray, tkVarargs, tkSlice]

proc valueText*(node: JsonNode; depth: int = ValueDepthLimit): string =
  ## One CodeTracer `Value` as the one line the State pane has room for.
  ##
  ## Mirrors `textReprDefault`
  ## (`src/common/common_types/utils/text_representation.nim:260`) — quoted
  ## strings, `'c'` for a char, `[a, b]` for a sequence, `(a, b)` for a tuple,
  ## `{label: value}` for a struct — because that is what a CodeTracer user
  ## reads in the desktop app and two spellings of one value across two
  ## consumers of one engine would be a difference with no cause. It is
  ## MIRRORED and not imported: `text_representation.nim` lives inside
  ## `common_types`, an *included* module that exists twice with incompatible
  ## `langstring` bindings, which is the same reason `state_vm.nim` refuses to
  ## import it and normalises at its host boundary instead.
  if node.isNil or node.kind != JObject: return ""
  if depth <= 0: return "…"

  let kind = node{"kind"}.getInt(-1)

  proc labelsOf(): seq[string] =
    let typ = node{"typ"}
    if typ == nil or typ.kind != JObject: return
    let labels = typ{"labels"}
    if labels == nil or labels.kind != JArray: return
    for label in labels: result.add label.getStr("")

  proc childrenText(open, close: string; labelled: bool): string =
    let elements = node{"elements"}
    if elements == nil or elements.kind != JArray: return open & close
    let labels = if labelled: labelsOf() else: @[]
    var parts: seq[string]
    for i in 0 ..< elements.len:
      let text = valueText(elements[i], depth - 1)
      if i < labels.len and labels[i].len > 0:
        parts.add labels[i] & ": " & text
      else:
        parts.add text
    open & parts.join(", ") & close

  case kind
  of tkInt: node{"i"}.getStr("")
  of tkFloat: node{"f"}.getStr("")
  of tkBool: (if node{"b"}.getBool(false): "true" else: "false")
  of tkString: "\"" & node{"text"}.getStr("") & "\""
  of tkCString: "\"" & node{"cText"}.getStr("") & "\""
  of tkChar: "'" & node{"c"}.getStr("") & "'"
  of tkRaw: node{"r"}.getStr("")
  of tkError: "<error: " & node{"msg"}.getStr("") & ">"
  of tkNone: "none"
  of tkNonExpanded: "…"
  of tkStruct: childrenText("{", "}", labelled = true)
  of tkTuple: childrenText("(", ")", labelled = false)
  of tkVariant:
    # `to_ct_value` puts the discriminator in `activeVariant` and the payload
    # in `activeVariantValue` (`db.rs:526-534`). A variant whose payload is
    # `None` is the whole value, which is what a fieldless enum case is.
    let name = node{"activeVariant"}.getStr("")
    let payload = node{"activeVariantValue"}
    if payload == nil or payload.kind != JObject or
       payload{"kind"}.getInt(-1) == tkNone:
      name
    else:
      name & "(" & valueText(payload, depth - 1) & ")"
  of tkRef, tkPointer:
    # `Reference` becomes a `Pointer` carrying both the address and the
    # dereferenced value (`db.rs:536-550`). The value is what a reader wants;
    # the address is what is left when there is none.
    let deref = node{"refValue"}
    if deref != nil and deref.kind == JObject: valueText(deref, depth - 1)
    else: node{"address"}.getStr("")
  else:
    if isSequenceKind(kind): childrenText("[", "]", labelled = false)
    else:
      # A kind this build has never seen from this engine. Not empty and not a
      # guess: the payload fields that carry data in every other arm, in the
      # order the engine fills them, so an unhandled kind reads as a value
      # rather than as a variable that is not there.
      for field in ["i", "f", "text", "cText", "r", "msg"]:
        let raw = node{field}.getStr("")
        if raw.len > 0: return raw
      ""

proc variablesOf*(body: JsonNode): seq[Variable] =
  ## `CtLoadLocalsResponseBody` → the store's `Variable`s.
  ##
  ## `expression` is the name (`task.rs:343-356`); it is the display name the
  ## engine already resolved through the rename list and the sourcemap
  ## (`dap_handler.rs:988`), so it is taken as-is rather than re-derived.
  ##
  ## Children are NOT parsed. `Variable` is recursive and `projectState` draws
  ## a flat row per variable, so a parsed child would be data nothing renders —
  ## and a compound's contents are already in its own row's text. The nested
  ## rows arrive with the affordance that expands them, not before it.
  if body.isNil or body.kind != JObject: return
  let locals = body{"locals"}
  if locals == nil or locals.kind != JArray: return
  for local in locals:
    if local.kind != JObject: continue
    let value = local{"value"}
    var typeName = ""
    if value != nil and value.kind == JObject:
      let typ = value{"typ"}
      if typ != nil and typ.kind == JObject:
        typeName = typ{"langType"}.getStr("")
    result.add makeVariable(
      name = local{"expression"}.getStr(""),
      value = valueText(value),
      typeName = typeName)

proc originSummariesOf*(body: JsonNode): seq[(string, OriginSummary)] =
  ## The `originSummary` each local carries, keyed by the local's name.
  ##
  ## THE FIELD WAS ALWAYS THERE AND WAS ALWAYS DROPPED. `variablesOf` above
  ## reads `expression`, `value` and `typ.langType` and nothing else, so the
  ## summary — which `task.rs:44` puts on every `Variable` and which the engine
  ## fills for every local it can attribute — went into the parser and did not
  ## come out. Measured against the published engine: 6 of 6 locals carry one.
  ##
  ## Parsed here rather than in `variablesOf` because it goes somewhere else:
  ## `Variable` is the store's row type and has no room for it, while
  ## `StateVM.originSummaries` is the signal the row renderer reads. One reply,
  ## two readers, and neither has to know about the other.
  if body.isNil or body.kind != JObject: return
  let locals = body{"locals"}
  if locals == nil or locals.kind != JArray: return
  for local in locals:
    if local.kind != JObject: continue
    let name = local{"expression"}.getStr("")
    if name.len == 0: continue
    let summary = local{"originSummary"}
    if summary == nil or summary.kind != JObject: continue
    result.add (name, parseOriginSummary(summary))

# ---------------------------------------------------------------------------
# The feed
# ---------------------------------------------------------------------------

type
  LocalsPhase* = enum
    ## What this session knows about the values at the position it is at.
    lpUnasked       ## no `ct/load-locals` has been issued for any position yet
    lpPending       ## asked for `forTicks`, no answer yet
    lpLive          ## `forTicks`' values are in the store
    lpUnavailable   ## `forTicks` was asked and the answer cannot be shown

  ValueDiff* = enum
    ## How one value at this position relates to the same name at the position
    ## the session CAME FROM.
    ##
    ## ## "Changed" is not directional, and the enum is why
    ##
    ## A time-travel session moves both ways, and every motion — step in, step
    ## over, step out, continue, and each of their reverses — is a move from one
    ## position to another. So "changed" here means *differs from the position
    ## you came from*, full stop. It is deliberately NOT "increased" or
    ## "decreased" and not "written at this step": a backward step reverses the
    ## sense of any directional reading, so a red/green encoding would be
    ## actively misleading on exactly half the motions the product offers. The
    ## renderer colours changed-vs-unchanged and nothing else.
    ##
    ## ## Why "appeared" is not "changed"
    ##
    ## A name that was not in scope at the previous position has no previous
    ## value to differ from. Calling that "changed" would invite the reader to
    ## look for a before-value that never existed — and it is the common case on
    ## a step INTO a function, where every local of the new frame is new. It
    ## reads as its own thing.
    dvUnchanged     ## the same name held the same value at the previous position
    dvChanged       ## the same name held a DIFFERENT value at the previous position
    dvAppeared      ## the name was not in scope at the previous position

  PriorValue* = tuple[name, value: string]
    ## One row of the baseline: what the previous position called it and what it
    ## said. The type is not `Variable` because the diff reads exactly these two
    ## fields, and a baseline that carried more would invite a comparison on
    ## something the pane does not show.

  LocalsFeed* = ref object
    ## One session's `ct/load-locals` traffic, and the state the State pane is
    ## drawn from.
    ##
    ## A `ref` because the decorated `BackendService` closes over it and it
    ## outlives every individual request.
    store*: ReplayDataStore
      ## Assigned by `openLiveSession` once the store exists. The store is
      ## built ON the decorated service, so the decoration cannot be given the
      ## store at construction time; this is where that knot is tied, in one
      ## place, rather than by threading a lookup through every send.
    state*: StateVM
      ## Where the per-local `originSummary` goes. Assigned by
      ## `openLiveSession` after the ViewModels exist, for the same reason
      ## `NavigationFeed.eventLog` is: the VM is built on the store which is
      ## built on this decoration, so it cannot exist before the decoration
      ## does. Nil-checked at every use, because a session that never built
      ## one is `tests/tdebugpanes.nim`'s and must keep working.
    sourcePublished*: bool
      ## Whether this recording published source at all.
      ##
      ## Load-bearing, and NOT the same question as "did any value get
      ## classified". A recording with no source cannot have an origin chain
      ## over any of its values — every chain capture this explorer publishes
      ## is in that state — and the pane must say so once rather than render
      ## nothing and let the absence read as a defect. A recording that DID
      ## publish source and still classified nothing is a different situation
      ## and gets no such sentence.
    phase*: LocalsPhase
    forTicks*: uint64
      ## The position `phase` is a statement about. Compared against the
      ## session's current position by `projectState`, so an answer for a
      ## position the session has already left is not shown as if it were
      ## current.
    epoch*: int
      ## Which request `phase` is about. The position alone is not enough to
      ## identify one: a session that steps away and back asks about the same
      ## `rrTicks` twice, and the FIRST request's deadline would otherwise
      ## expire onto the second request's pending state and report a timeout
      ## for an answer that was still on its way.
    reason*: string
      ## Why `lpUnavailable`, in the words the pane uses.
    hasLive*: bool
    liveTicks*: uint64
      ## The position whose values a COMPLETED reply put in the store, and
      ## whether there has been one.
      ##
      ## Separate from `phase`/`forTicks`, which are about the request that is
      ## currently outstanding, because those two answer "what did I last ask
      ## about" and this answers "what do I actually know". They come apart
      ## whenever a second request is issued for a position whose values are
      ## already in, and keeping them as one field is what made the Values pane
      ## flicker — see `noteFor`.
    baseline*: seq[PriorValue]
    baselineTicks*: uint64
    baselineValid*: bool
      ## The values at the position the session came from, for the diff.
      ##
      ## `baselineValid` is the whole safety of the feature. It is true only
      ## when this feed actually HELD the values of the position the current
      ## move started from — not merely "the last values it ever held". A
      ## session that steps A → B → C while B's request is refused knows nothing
      ## about what B→C changed, and marking C's values against A's would be a
      ## confident wrong answer about a motion that never happened. When it is
      ## false the pane marks nothing, which is the honest reading of "this
      ## cannot be known" and is indistinguishable, correctly, from a motion
      ## that changed nothing.
    onApplied*: proc()
      ## The host's re-render, called once per settled reply. `applyStop`
      ## writes the position, the URL and the panes in one call; this is the
      ## same discipline for the half that cannot be synchronous — the store
      ## and the panes are left consistent by one call rather than by two
      ## facts updated in parallel.
    scheduleTimeout*: proc(ms: int; action: proc())
      ## Injected by the host (`afterMs`). Absent — under `nim c`, in the
      ## headless suites — there is no deadline and a pending position simply
      ## stays pending, which is correct for a driver that answers or does not.

proc settle(feed: LocalsFeed; epoch: int; phase: LocalsPhase; reason = "") =
  ## One request, ended. Every exit from a request goes through here so that
  ## "the phase moved" and "the host was told" cannot come apart.
  ##
  ## An answer to a request the session has moved past is dropped: two
  ## requests can be in flight across a fast pair of steps, and the older one
  ## resolving second would otherwise overwrite the newer one's values with
  ## the previous frame's — the exact staleness this module exists to remove,
  ## reintroduced by a race.
  if epoch != feed.epoch or feed.phase != lpPending: return
  feed.phase = phase
  feed.reason = reason
  if feed.onApplied != nil: feed.onApplied()

proc apply*(feed: LocalsFeed; epoch: int; response: JsonNode) =
  ## A `ct/load-locals` response, into the store.
  if epoch != feed.epoch or feed.phase != lpPending: return
  if response.isNil or response.kind != JObject:
    feed.settle(epoch, lpUnavailable, UnreadableNote)
    return
  if not response{"success"}.getBool(true):
    let message = response{"message"}.getStr("")
    feed.settle(epoch, lpUnavailable, RefusedNotePrefix &
      (if message.len > 0: message else: "no reason given") & ".")
    return
  let body = response{"body"}
  if body == nil or body.kind != JObject or body{"locals"} == nil:
    feed.settle(epoch, lpUnavailable, UnreadableNote)
    return
  # The store first, the phase second, the host third — so the one re-render
  # `settle` triggers reads a store that already holds this position's values.
  if feed.store != nil:
    feed.store.updateLocals(variablesOf(body))
  # The summaries go to the StateVM and not to the store, because the store's
  # `Variable` has nowhere to put them and `StateVM.originSummaries` is what
  # the row renderer reads. BULK-replaced rather than merged: they belong to
  # THIS position, and a summary left over from the previous one would put a
  # control on a row whose value is no longer the value it described.
  if feed.state != nil:
    feed.state.updateOriginSummaries(originSummariesOf(body))
  # WHAT THIS SESSION KNOWS, as opposed to what it last asked. Written here and
  # only here, on the one path that has put a position's values in the store.
  feed.hasLive = true
  feed.liveTicks = feed.forTicks
  feed.settle(epoch, lpLive)

proc refuse*(feed: LocalsFeed; epoch: int; message: string) =
  ## The request failed rather than answered.
  feed.settle(epoch, lpUnavailable, RefusedNotePrefix &
    (if message.len > 0: message else: "no reason given") & ".")

proc currentValues(feed: LocalsFeed): seq[PriorValue] =
  ## What the pane is showing right now, reduced to the two fields the diff
  ## compares. Read off the StateVM's own memo — the thing `projectState`
  ## renders — rather than off the store, so the baseline is by construction
  ## the values a visitor actually just had on screen.
  if feed.state == nil: return
  for v in feed.state.currentVariables.val:
    result.add (name: v.name, value: v.value)

proc awaiting(feed: LocalsFeed; ticks: uint64): int =
  ## A request has gone out for `ticks`. Returns its epoch.
  ##
  ## The store's own values are NOT cleared here. They are the previous
  ## position's and they are about to be replaced; `projectState` refuses to
  ## show them while `phase` is `lpPending`, which keeps "what the store holds"
  ## and "what the pane may say" as one decision in one place instead of a
  ## clearing that some other reader could race.
  ##
  ## ## THE BASELINE IS CAPTURED HERE, AND ONLY ON A MOVE
  ##
  ## A time-travel debugger needs no extra recording to say what a motion
  ## changed: the prior position is still queryable. But it does need to know
  ## WHICH position it came from, and this is the one moment that is knowable
  ## without asking anything — the request for the new position is going out
  ## while `forTicks` still names the old one and `phase` still says whether its
  ## answer ever arrived.
  ##
  ## Guarded on the position actually differing, because a second request for
  ## the position the session is already at is not a move. Without that guard
  ## the baseline would be overwritten with the current position's own values
  ## between the two replies, and every row would report itself unchanged.
  if ticks != feed.forTicks:
    feed.baselineValid = feed.hasLive and feed.liveTicks == feed.forTicks
    feed.baselineTicks = feed.forTicks
    feed.baseline = if feed.baselineValid: feed.currentValues() else: @[]
  inc feed.epoch
  feed.phase = lpPending
  feed.forTicks = ticks
  feed.reason = ""
  result = feed.epoch
  if feed.scheduleTimeout != nil:
    let deadline = feed.epoch
    feed.scheduleTimeout(LocalsDeadlineMs, proc() =
      feed.settle(deadline, lpUnavailable, TimedOutNote))

proc withLiveLocals*(inner: BackendService; feed: LocalsFeed): BackendService =
  ## `inner`, with the `ct/load-locals` reply read on its way back.
  ##
  ## Every other command is passed through untouched — this is not a place to
  ## grow a second protocol layer, and a decorator that inspected more than the
  ## one command it is named for would be one.
  BackendService(
    sendProc: proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
      let fut = inner.send(command, args)
      if command == LoadLocalsCommand:
        # The position the STORE asked about, from the arguments it built,
        # rather than from the session's current position — they are the same
        # today and a request that outlived a move would make them differ, and
        # this is the one that the answer is about.
        let ticks = uint64(max(0, args{"rrTicks"}.getBiggestInt(0)))
        let epoch = feed.awaiting(ticks)
        fut.onComplete(
          onSuccess = proc(response: JsonNode) = feed.apply(epoch, response),
          onError = proc(message: string) = feed.refuse(epoch, message))
      fut,
    onEventProc: inner.onEventProc,
    disconnectProc: inner.disconnectProc)

proc adopt*(feed: LocalsFeed; ticks: uint64) =
  ## Declare that the store's current locals ARE this position's.
  ##
  ## For drivers that write the store directly instead of answering a request —
  ## `tests/tdebugpanes.nim` mirrors a backend response through
  ## `store.updateLocals`, which is the bridge the SDK documents for exactly
  ## that. Without this the suite would drive a session whose pane is
  ## permanently `lpUnasked`, which is not the state it is asserting about.
  feed.phase = lpLive
  feed.forTicks = ticks
  feed.hasLive = true
  feed.liveTicks = ticks
  feed.reason = ""

proc knows(feed: LocalsFeed; ticks: uint64): bool =
  ## Whether a COMPLETED reply put this exact position's values in the store.
  feed.hasLive and feed.liveTicks == ticks

proc diffFor*(feed: LocalsFeed; name, value: string): ValueDiff =
  ## How this row relates to the position the session came from.
  ##
  ## Answered lazily, per row, rather than materialised into a table when the
  ## reply lands. There is no second copy of the verdict to fall out of step
  ## with the values, and a frame's locals are a handful of rows, so the linear
  ## scan is not worth removing.
  ##
  ## `dvUnchanged` when the baseline is not valid. That is not a fallback that
  ## hides an error: "I cannot know what this motion changed" and "this motion
  ## changed nothing" both mean the pane must not mark the row, and marking it
  ## on a guess is the one outcome that would make the feature worse than not
  ## having it.
  if feed == nil or not feed.baselineValid: return dvUnchanged
  for prior in feed.baseline:
    if prior.name == name:
      return if prior.value == value: dvUnchanged else: dvChanged
  dvAppeared

proc noteFor*(feed: LocalsFeed; ticks: uint64; values: int): string =
  ## The sentence the State pane shows instead of values, or `""` when the
  ## values it has are this position's.
  ##
  ## THE SERVED FRAME IS NEVER THE ANSWER. Every branch that does not have a
  ## COMPLETED reply for this exact position produces a sentence, and a pane
  ## with a sentence in it is a pane `renderPanes` will write — so the
  ## statically exported values are replaced the first time a live session takes
  ## a position, whether or not the engine answered. Values from the frame the
  ## page was served at, presented as the values where the visitor now stands,
  ## is the confident wrong answer this route exists to not give.
  ##
  ## ## THE FLICKER: `phase` IS NOT THE QUESTION THIS PROC ASKS
  ##
  ## Every branch used to key off `phase`, so a request going out threw the pane
  ## back to "Reading the values at this position…" — including a request for
  ## the position the pane was ALREADY showing verified values for. `StateVM`'s
  ## auto-load effect issues more than one `ct/load-locals` per move, and the
  ## measured result on the published engine was the Values pane oscillating
  ## values → sentence → values *within a single step*, on every step. That is
  ## the flicker a visitor reported.
  ##
  ## The question is not "is a request outstanding" but "do I hold this
  ## position's values", and `knows` is that question. A second request for a
  ## position whose reply already landed cannot make those values less true, so
  ## the pane keeps showing them while it is in flight. The guarantee above is
  ## untouched, because `knows` requires a completed reply for THIS position:
  ## the served frame can never satisfy it, and neither can the previous
  ## position's values.
  if feed == nil: return ReadingNote
  if feed.knows(ticks):
    return if values == 0: NoValuesNote else: ""
  case feed.phase
  of lpUnasked, lpPending, lpLive: ReadingNote
  of lpUnavailable:
    if feed.forTicks == ticks: feed.reason else: ReadingNote
