## SDK-CONSUMER: §6.0a's landing — where a shared link puts the session, and
## what the visitor is told about it.
##
## ## The division of labour, and why it is this one
##
## `Debugger-Integration.md` §6.0a states a five-step precedence and
## `blocktracer_client/deeplink.nim` implements it, saying of itself:
##
## > Anchor *resolution* is not here. Turning `call:0.2.6` into a coordinate
## > requires the trace, which is the layer below. What is here is the
## > **decision** — §6.0a's five-step precedence — which is chain-side policy
## > and the thing that produces silent wrongness when it is left implicit.
##
## This module is the other half: the **lookup**. It resolves an anchor against
## the rows the session already has — the call trace and the event log — and
## hands the answer back as `PositionInputs`, then renders nothing and decides
## nothing. The sentence a visitor reads is written in the SDK, once, so the
## static export, the hydration bundle and any future consumer say the same true
## thing rather than three similar ones.
##
## ## Why the rows are a legitimate place to resolve an anchor
##
## §6.0a's anchor kinds are all properties of the *transaction*, not of a
## container: a log index, a storage slot and its nth write, a call path, the
## reverting frame, a source line. Every one of those is what the Event Log and
## the Call Trace are indexes of — "the same execution indexed two ways" (§3) —
## and each row already carries the coordinate it starts at. So resolving
## `log:3` is finding the fourth event row, which is a real lookup in the
## current trace and not an approximation of one.
##
## What this module deliberately does NOT do is ask the engine. A DAP round trip
## per anchor would put the resolution after the first paint, and §6.3 requires
## it *before* one: "a shared link opens **at** the position rather than at the
## start with a visible jump".
##
## ## Hermetic
##
## Pure functions over `session_view`'s pane types plus the SDK's browser entry
## point. No DOM, no engine, no clock — which is what lets
## `client/tests/test_debug_route.nim` drive all five branches with no browser
## and no debugger on the Nim path.

import std/strutils

import blocktracer_client_deeplink
import ./session_view

# Re-exported whole, so a consumer of the LANDING also has the grammar it
# landed by: `parseDeepLink` to read a URL back, `checkWitness` to say what a
# witness proved, `PositionOutcome`'s spellings. Two imports for one subject
# would be two places to remember which half a symbol is in.
export blocktracer_client_deeplink

# ---------------------------------------------------------------------------
# The anchors the session's own rows carry
# ---------------------------------------------------------------------------

func callPath*(frames: seq[CallFrame]; i: int): string =
  ## Frame `i`'s call path — §6.0a's `call` anchor data, e.g. `0.2.6`.
  ##
  ## Derived from depth and call order, which is the only structure a rendered
  ## call trace has, and derived the same way for every producer so a path
  ## written by the static export and a path resolved from a live session are
  ## the same string. Each segment is the frame's index among its siblings at
  ## that depth under the same parent.
  var counters: seq[int]   ## the next sibling index at each depth
  var pathAt: seq[string]  ## the path of the last frame seen at each depth
  for k in 0 .. i:
    let d = max(0, frames[k].depth)
    while counters.len <= d: counters.add 0
    while pathAt.len <= d: pathAt.add ""
    # Entering a shallower or equal depth ends every deeper run, so their
    # sibling counters restart. Without this a second `calculate_damage` at
    # depth 2 would number its callee `1` under a parent that has one callee.
    for deeper in d + 1 ..< counters.len: counters[deeper] = 0
    let seg = $counters[d]
    inc counters[d]
    # A pane may be showing a WINDOW of a deep trace, whose first row is not
    # depth 0. Its parents are not on screen, so there is no prefix to join to
    # and the path starts here rather than at `.0` — a leading dot would be a
    # path naming a root that is not in this list.
    pathAt[d] = (if d == 0 or pathAt[d - 1].len == 0: seg
                 else: pathAt[d - 1] & "." & seg)
    if k == i: result = pathAt[d]

proc withCallAnchors*(p: var CallTracePane) =
  ## Give every frame its `call:` anchor.
  ##
  ## A `proc` over the pane rather than a field each producer fills in its own
  ## way: the path is a function of the frame list and nothing else, so two
  ## producers computing it is two chances to number a sibling differently — and
  ## a wrong call path is a link that lands in a real frame that is not the one
  ## it named, which is the failure mode with no visible symptom.
  for i in 0 ..< p.frames.len:
    p.frames[i].anchor = "call:" & callPath(p.frames, i)

proc withEventAnchors*(p: var EventLogPane) =
  ## Give every event row the §6.0a anchor its KIND supports, and give the
  ## others none.
  ##
  ## `log` and `sw` are the two kinds §6.0a calls consensus-recorded — "every
  ## correct trace agrees" — and `revert` is the one it says needs no data
  ## because there is one reverting frame. A `call` row and an `output` row get
  ## `""`: a call's position is named by the call trace's `call:` path, and a
  ## program's stdout is not consensus-recorded at all, so inventing an
  ## `output:7` anchor would be inventing a stability claim no chain makes.
  var logs = 0
  var writes: seq[tuple[slot: string, n: int]]
  for i in 0 ..< p.rows.len:
    case p.rows[i].kind
    of evEvent:
      p.rows[i].anchor = "log:" & $logs
      inc logs
    of evStorageWrite:
      var n = 0
      for k in 0 ..< writes.len:
        if writes[k].slot == p.rows[i].label:
          inc writes[k].n
          n = writes[k].n
      if n == 0: writes.add (p.rows[i].label, 0)
      p.rows[i].anchor = "sw:" & p.rows[i].label & "#" & $n
    of evRevert:
      p.rows[i].anchor = "revert"
    of evCall, evOutput:
      p.rows[i].anchor = ""

# ---------------------------------------------------------------------------
# Resolving an incoming anchor against them
# ---------------------------------------------------------------------------

func anchorWire*(a: Anchor): string =
  ## The anchor as a row carries it. `revert` alone, everything else
  ## `kind:data`.
  if a.kind == akNone: ""
  elif a.kind == akRevert and a.data.len == 0: $a.kind
  else: $a.kind & ":" & a.data

func sourceFileOf(data: string): string =
  ## `src:contracts/Vault.sol:42`'s file half. The line is the last
  ## colon-separated segment, and a path may itself contain a colon on no
  ## platform this serves, so splitting from the right is exact.
  let i = data.rfind(':')
  if i <= 0: data else: data[0 ..< i]

proc resolveAnchor*(a: Anchor; ct: CallTracePane; ev: EventLogPane):
    tuple[exact: int, exactFound: bool, enclosing: int, enclosingFound: bool] =
  ## Look one anchor up in the current trace's rows.
  ##
  ## Two answers, because §6.0a needs two: the coordinate the anchor names
  ## (step 3), and the coordinate of the frame that *would contain* it when it
  ## names nothing (step 4). The second is not a guess dressed as the first —
  ## it is a different, weaker claim, and the precedence says so out loud in a
  ## different sentence.
  if a.kind == akNone: return
  let wire = anchorWire(a)

  # Exact: a row whose own anchor is this one. One mechanism for all five
  # kinds, because every producer stamps its rows through `withCallAnchors` /
  # `withEventAnchors` — so "the anchor a share emits" and "the anchor a link
  # resolves against" are the same string by construction.
  for r in ev.rows:
    if r.anchor.len > 0 and r.anchor == wire:
      return (r.step, true, 0, false)
  for f in ct.frames:
    if f.anchor.len > 0 and f.anchor == wire:
      return (f.step, true, 0, false)

  # Enclosing, per kind. Only the two structural kinds have one:
  case a.kind
  of akCall:
    # The longest PREFIX of the call path that is a frame. `0.2.6` in a trace
    # that no longer makes that sixth call still has a `0.2`, and that frame
    # genuinely encloses where the link pointed.
    var path = a.data
    while true:
      let cut = path.rfind('.')
      if cut <= 0: break
      path = path[0 ..< cut]
      for f in ct.frames:
        if f.anchor == "call:" & path:
          return (0, false, f.step, true)
  of akSource:
    # A source line the trace no longer visits, in a file it still runs: the
    # first frame of that file encloses it. Matched against the frame's module
    # string, which is where the static producer puts the path, and against the
    # frame's own `src:` anchor if a producer ever emits one.
    let file = sourceFileOf(a.data)
    if file.len > 0:
      for f in ct.frames:
        if f.module.contains(file) or f.anchor.startsWith("src:" & file & ":"):
          return (0, false, f.step, true)
  of akLog, akStorageWrite, akRevert, akNone:
    # Nothing encloses a log index that does not exist. Saying "the nearest
    # enclosing frame" of an event this trace never emitted would be naming a
    # frame chosen by position in a list, which is an arbitrary landing wearing
    # a reason. Step 5 — the start, stated — is the honest answer.
    discard

func startCoordinate*(ct: CallTracePane; ev: EventLogPane): int =
  ## Where "the start of the execution" is, for step 5.
  ##
  ## The entry frame, which is the depth-0 row a call trace always has; the
  ## first event otherwise, for a session that has an event log and no frames.
  ## `0` when it has neither — a session with no rows at all, which is §7.0's
  ## no-frame state and has no position to offer.
  for f in ct.frames:
    if f.depth <= 0: return f.step
  if ct.frames.len > 0: return ct.frames[0].step
  if ev.rows.len > 0: return ev.rows[0].step
  0

# ---------------------------------------------------------------------------
# The landing
# ---------------------------------------------------------------------------

type
  LinkLanding* = object
    ## What a URL asked for, what it got, and what to say about it.
    asked*: bool
      ## Whether the URL carried a link payload at all. `false` is an ordinary
      ## visit, which is NOT step 5: there is no link, so there is nothing to
      ## recover from and nothing to announce. Conflating the two would put a
      ## sentence about a failed deep link on every plain page view.
    coordinate*: int
    notice*: PositionNotice
    parseErrors*: seq[string]
      ## What the grammar rejected, kept so a caller can distinguish a link
      ## this build does not understand from one it disagreed with.

func coordinateOf(s: string): int =
  ## `t` as a step number. §6.2 calls `t` a coordinate in the container and this
  ## product's containers number their steps, so a non-numeric coordinate is one
  ## this build cannot use — `0`, which every caller treats as "no position".
  try: (if s.len == 0: 0 else: parseInt(s.strip)) except CatchableError: 0

proc resolveLanding*(payload: string;
                     artifactAvailable: bool;
                     currentContentHash: string;
                     calltrace: CallTracePane;
                     eventLog: EventLogPane): LinkLanding =
  ## §6.0a end to end, for one URL: parse, look the anchor up, decide, and carry
  ## back the sentence.
  ##
  ## `payload` is the URL's query or fragment, with or without its leading `?`
  ## or `#`; the SDK's parser takes either. An empty one — a visitor who typed
  ## the address, or followed a link with no position in it — returns
  ## `asked = false` and nothing else, which is the only outcome that renders
  ## no notice besides an exact hit.
  var raw = payload
  if raw.startsWith("?") or raw.startsWith("#"): raw = raw[1 .. ^1]
  if raw.strip.len == 0: return

  let parsed = parseDeepLink(raw)
  let link = parsed.link
  # A payload with no position and no anchor is not a deep link — it is a query
  # string that happens to exist (a tracking parameter, a pasted fragment). The
  # page has nothing to resolve and must not claim it failed to.
  if link.coordinate.len == 0 and not link.anchor.isValid: return

  result.asked = true
  result.parseErrors = parsed.errors

  let found = resolveAnchor(link.anchor, calltrace, eventLog)
  let decision = resolvePosition(link, PositionInputs(
    artifactAvailable: artifactAvailable,
    currentContentHash: currentContentHash,
    anchorResolved: found.exactFound,
    anchorCoordinate: (if found.exactFound: $found.exact else: ""),
    enclosingFrameCoordinate: (if found.enclosingFound: $found.enclosing else: ""),
    executionStartCoordinate: $startCoordinate(calltrace, eventLog)))

  result.coordinate = coordinateOf(decision.coordinate)
  result.notice = PositionNotice(outcome: $decision.outcome,
                                 statement: decision.statement)
  # §6.0a: "Every branch below (2) is visible." The SDK decides which those are
  # and writes the sentence; this restates the invariant as an assertion so a
  # future branch that forgot its sentence fails here rather than landing a
  # reader silently in the wrong place.
  doAssert (decision.outcome == poExact) or decision.statement.len > 0,
    "§6.0a: outcome '" & $decision.outcome & "' is visible and carries no statement"

# ---------------------------------------------------------------------------
# Emitting — the other direction, kept beside the reading of it
# ---------------------------------------------------------------------------

proc positionQuery*(contentHash: string; step: int; anchor: string): string =
  ## The `?…` a debug URL carries for one position: `v`, `t`, `c`, and `a` where
  ## the position has one.
  ##
  ## Takes the artifact's `traceContentHash` rather than a witness, so
  ## `witnessFor`'s truncation happens in one place and no caller can emit a `c`
  ## of its own length. A tree that published no container hash emits no `c`,
  ## which a reader's client then resolves as §6.0's "Absent → treated as
  ## unverifiable" — the honest reading, and the only one available: a `c` we
  ## cannot compute must not be invented, and a `t` withheld to avoid an
  ## unverifiable link would lose the position FR-5 requires the URL to carry.
  ##
  ## In the QUERY and not the fragment, for this route, because the fragment is
  ## already spoken for — the source pane's per-line ids and the pane stack's
  ## `:target` tabs both live there, and the served page has no script to
  ## arbitrate. §6's URL form puts the payload in the fragment; §8 and
  ## Configuration.md's query table put `t` in the query, the page has always
  ## written the second, and the SDK's parser takes both. What matters to §6.0a
  ## is that `t` never travels without `c`, and this is the one place either is
  ## written.
  var link = DeepLink(version: DeepLinkVersion,
                      witness: (if contentHash.len > 0: witnessFor(contentHash)
                                else: ""))
  if step > 0: link.coordinate = $step
  if anchor.len > 0:
    let (a, err) = parseAnchor(anchor)
    if err.len == 0: link.anchor = a
  # `emitFragment` writes the grammar and prefixes `#`; the fields are the same
  # either way, so the one character is swapped rather than the grammar being
  # written twice.
  "?" & emitFragment(link)[1 .. ^1]
