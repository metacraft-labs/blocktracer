## The debug deep link: payload, precedence, and the content witness.
##
## ```
## /{chain}/tx/{hash}/debug#v=1&t={coordinate}&c={witness}&a={anchor}[&x=…][&f=…][&p=…]
## ```
##
## Normative in
## [Debugger-Integration.md](../../../codetracer-specs/BlockTracer/Debugger-Integration.md)
## §6.0a. Two properties of that section are load-bearing and are enforced here
## rather than left to a caller:
##
##   * **A link never carries an artifact id** (§6). It identifies a transaction
##     and a position in it, not a build of our software. `emit` has no
##     parameter for one, and `parse` rejects a field that looks like one.
##   * **`c` is a witness, not a pin** (§6.0). It does not *select* an artifact;
##     it only answers whether `t` still means what it meant. A corrected trace
##     therefore reaches every reader, and a coordinate is never shown
##     confidently after the container it was taken from was replaced.
##
## Anchor *resolution* is not here. Turning `call:0.2.6` into a coordinate
## requires the trace, which is the layer below (`Client-SDK.md` §1: only at
## the end does this package hand the Embed SDK a source). What is here is the
## **decision** — §6.0a's five-step precedence — which is chain-side policy and
## the thing that produces silent wrongness when it is left implicit.

import std/[strutils, tables]

const
  DeepLinkVersion* = 1
    ## The link-schema version this build emits and understands. §6.0a's `v`
    ## exists so the grammar can change without breaking existing links, so an
    ## unknown version is reported, never guessed at.

type
  AnchorKind* = enum
    ## §6.0a's recovery anchors, in the document's own order — how well each
    ## survives regeneration. The wire spellings are the contract.
    akNone = ""
    akLog = "log"                ## log index n; consensus-recorded
    akStorageWrite = "sw"        ## storage slot + nth write
    akCall = "call"              ## call path, e.g. 0.2.6
    akRevert = "revert"          ## there is one reverting frame
    akSource = "src"             ## source file + line

  Anchor* = object
    kind*: AnchorKind
    data*: string                ## the anchor's payload, verbatim after `kind:`

  DeepLink* = object
    version*: int
    coordinate*: string          ## `t` — a position in the trace container (§6.2)
    witness*: string             ## `c` — a prefix of traceContentHash (§6.0)
    anchor*: Anchor              ## `a`
    execution*: string           ## `x` — sub-execution identity, where applicable
    frame*: string               ## `f`
    panes*: string               ## `p`

  ParseResult* = object
    link*: DeepLink
    errors*: seq[string]
    unknownFields*: seq[string]
      ## Fields the grammar does not name. Kept rather than dropped so a
      ## consumer can say a link came from a newer build instead of silently
      ## ignoring half of it.

proc isValid*(a: Anchor): bool = a.kind != akNone

# ---------------------------------------------------------------------------
# Percent coding. The fragment carries `src:contracts/Vault.sol:42` and call
# paths, so `:` and `/` must survive a round trip.
# ---------------------------------------------------------------------------

const unreserved = {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '-', '.', '_', '~', ':'}

proc encodeValue*(s: string): string =
  for c in s:
    if c in unreserved: result.add c
    else: result.add '%' & toHex(ord(c), 2)

proc decodeValue*(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add chr(parseHexInt(s[i + 1 .. i + 2]))
        i += 3
        continue
      except ValueError: discard
    result.add s[i]
    inc i

# ---------------------------------------------------------------------------
# The content witness
# ---------------------------------------------------------------------------

const DefaultWitnessLength* = 12

proc normaliseHash(contentHash: string): string =
  ## `traceContentHash` is algorithm-tagged (`blake3:…`, `sha1:…`). The witness
  ## compares the digest, not the tag, so a producer that changes hash spelling
  ## does not silently invalidate every existing link's witness — and does not
  ## silently validate one either, because the digests still differ.
  let i = contentHash.find(':')
  let d = if i < 0: contentHash else: contentHash[i + 1 .. ^1]
  d.toLowerAscii

proc witnessFor*(contentHash: string, length = DefaultWitnessLength): string =
  ## The short prefix of `traceContentHash` a Share embeds (§6.0).
  let d = normaliseHash(contentHash)
  if d.len <= length: d else: d[0 ..< length]

type
  WitnessVerdict* = enum
    wvAbsent = "absent"        ## an older link; treated as unverifiable (§6.0)
    wvMatches = "matches"
    wvDiffers = "differs"
    wvUnknownArtifact = "unknownArtifact"
      ## No current content hash to compare against, so the witness proves
      ## nothing. Distinct from `differs`: not knowing is not disagreeing.

proc checkWitness*(witness, currentContentHash: string): WitnessVerdict =
  if witness.len == 0: return wvAbsent
  if currentContentHash.len == 0: return wvUnknownArtifact
  let cur = normaliseHash(currentContentHash)
  let w = witness.toLowerAscii
  if cur.len >= w.len and cur.startsWith(w): wvMatches else: wvDiffers

# ---------------------------------------------------------------------------
# Parse
# ---------------------------------------------------------------------------

proc parseAnchor*(raw: string): tuple[anchor: Anchor, err: string] =
  if raw.len == 0: return (Anchor(kind: akNone), "")
  let i = raw.find(':')
  let kindStr = if i < 0: raw else: raw[0 ..< i]
  let data = if i < 0: "" else: raw[i + 1 .. ^1]
  var k: AnchorKind
  try:
    k = parseEnum[AnchorKind](kindStr)
  except ValueError:
    return (Anchor(kind: akNone), "unknown anchor kind '" & kindStr & "'")
  if k == akNone:
    return (Anchor(kind: akNone), "empty anchor kind")
  if k != akRevert and data.len == 0:
    return (Anchor(kind: akNone),
            "anchor '" & kindStr & "' carries no data")
  (Anchor(kind: k, data: data), "")

proc parseDeepLink*(fragment: string): ParseResult =
  ## Parse the URL fragment. Reports rather than raises: a link is untrusted
  ## input pasted by a person, and a malformed one still names a transaction.
  ##
  ## A leading `?` is accepted as well as a leading `#`, because the payload is
  ## carried in both places and the grammar is the same in both. §6's URL form
  ## puts it in the fragment; Page-Descriptions §8 and Configuration.md's query
  ## table put `t` in the QUERY, which is also what a debug page's
  ## `history.replaceState` writes on every navigation. One parser for one
  ## grammar, and no second spelling of `&`-joined fields to keep in step.
  var f = fragment
  if f.startsWith("#") or f.startsWith("?"): f = f[1 .. ^1]
  result.link.version = 0
  if f.len == 0:
    result.errors.add "empty deep-link fragment"
    return

  var fields = initOrderedTable[string, string]()
  for part in f.split('&'):
    if part.len == 0: continue
    let eq = part.find('=')
    if eq < 0:
      result.errors.add "field '" & part & "' has no value"
      continue
    let k = part[0 ..< eq]
    let v = decodeValue(part[eq + 1 .. ^1])
    if fields.hasKey(k):
      result.errors.add "field '" & k & "' appears more than once"
      continue
    fields[k] = v

  for k, v in fields:
    case k
    of "v":
      try:
        result.link.version = parseInt(v)
      except ValueError:
        result.errors.add "link-schema version '" & v & "' is not a number"
    of "t": result.link.coordinate = v
    of "c": result.link.witness = v
    of "a":
      let (a, err) = parseAnchor(v)
      if err.len > 0: result.errors.add err
      else: result.link.anchor = a
    of "x": result.link.execution = v
    of "f": result.link.frame = v
    of "p": result.link.panes = v
    else:
      result.unknownFields.add k

  if not fields.hasKey("v"):
    result.errors.add "missing required field 'v'"
  elif result.link.version != DeepLinkVersion and result.errors.len == 0:
    result.errors.add "unsupported link-schema version " & $result.link.version
  if result.link.coordinate.len > 0 and result.link.witness.len == 0:
    # §6.0a: `c` is required when `t` is present. Without it the coordinate is
    # unverifiable, and §6.0's table says so: an older link is treated as
    # unverifiable rather than trusted.
    result.errors.add "field 't' is present without its content witness 'c'"
  # §6: "One URL form, and it never carries an artifact id."
  for k in result.unknownFields:
    let lk = k.toLowerAscii
    if lk.contains("artifact") or lk == "tid":
      result.errors.add "field '" & k &
        "' looks like an artifact id; a deep link never carries one (§6)"

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------

proc emitFragment*(link: DeepLink): string =
  ## The fragment, fields in the document's order. No artifact id, ever.
  var parts: seq[string]
  let v = if link.version == 0: DeepLinkVersion else: link.version
  parts.add "v=" & $v
  if link.coordinate.len > 0: parts.add "t=" & encodeValue(link.coordinate)
  if link.witness.len > 0: parts.add "c=" & encodeValue(link.witness)
  if link.anchor.isValid:
    let payload =
      if link.anchor.kind == akRevert and link.anchor.data.len == 0: $link.anchor.kind
      else: $link.anchor.kind & ":" & link.anchor.data
    parts.add "a=" & encodeValue(payload)
  if link.execution.len > 0: parts.add "x=" & encodeValue(link.execution)
  if link.frame.len > 0: parts.add "f=" & encodeValue(link.frame)
  if link.panes.len > 0: parts.add "p=" & encodeValue(link.panes)
  "#" & parts.join("&")

proc debugPath*(chain, txHash: string): string =
  ## The route half of the link. The SDK owns it because the route shape is
  ## chain-aware and the layer below has no chain.
  "/" & chain & "/tx/" & txHash & "/debug"

type
  ShareResult* = object
    url*: string
    errors*: seq[string]

proc shareLink*(chain, txHash: string, link: DeepLink): ShareResult =
  ## Build a shareable URL. **Share always includes a recovery anchor**
  ## (§6.3): the exact coordinate is valid within one container, and capsule
  ## expiry can eventually make exact regeneration impossible, so a link with
  ## no anchor is refused here rather than degrading silently later.
  if not link.anchor.isValid:
    result.errors.add "a shared link must carry a recovery anchor 'a' (§6.0a, §6.3)"
  if link.coordinate.len > 0 and link.witness.len == 0:
    result.errors.add "a shared link with 't' must carry its content witness 'c' (§6.0a)"
  result.url = debugPath(chain, txHash) & emitFragment(link)

# ---------------------------------------------------------------------------
# §6.0a resolution precedence
# ---------------------------------------------------------------------------

type
  PositionInputs* = object
    ## What the layer below reports back. This package decides; the debugger
    ## looks things up. `anchorResolved` and the coordinates come from the
    ## engine, because resolving `call:0.2.6` requires the container.
    artifactAvailable*: bool
      ## Is there a replayable artifact at all? Step 1 of the precedence.
    currentContentHash*: string
      ## `traceContentHash` of the artifact currently recommended — NOT of the
      ## artifact the link was taken from. §6.0: the link resolves to whatever
      ## is currently recommended; the witness only says whether `t` transfers.
    anchorResolved*: bool
    anchorCoordinate*: string
    enclosingFrameCoordinate*: string
    executionStartCoordinate*: string

  PositionOutcome* = enum
    poNoReplayableArtifact = "noReplayableArtifact"  ## 1, terminal
    poExact = "exact"                                ## 2
    poRecoveredByAnchor = "recoveredByAnchor"        ## 3
    poNearestEnclosingFrame = "nearestEnclosingFrame" ## 4
    poStartOfExecution = "startOfExecution"          ## 5

  PositionResolution* = object
    outcome*: PositionOutcome
    coordinate*: string
    witness*: WitnessVerdict
    visible*: bool
      ## §6.0a: "Every branch below (2) is visible." True for every outcome
      ## except `poExact`, and a consumer that ignores it is the silent
      ## wrongness this precedence exists to prevent.
    statement*: string
      ## The plain sentence to show. Written here so every consumer says the
      ## same true thing rather than inventing its own wording.

proc resolvePosition*(link: DeepLink, inputs: PositionInputs): PositionResolution =
  ## §6.0a's five steps, in order.
  if not inputs.artifactAvailable:
    return PositionResolution(outcome: poNoReplayableArtifact, visible: true,
      witness: wvUnknownArtifact,
      statement: "This execution is not replayable, so the linked position " &
        "cannot be shown. The transaction itself is unchanged.")

  let verdict = checkWitness(link.witness, inputs.currentContentHash)
  if verdict == wvMatches and link.coordinate.len > 0:
    return PositionResolution(outcome: poExact, coordinate: link.coordinate,
      witness: verdict, visible: false, statement: "")

  if link.anchor.isValid and inputs.anchorResolved and
     inputs.anchorCoordinate.len > 0:
    let why =
      case verdict
      of wvDiffers: "the trace was regenerated since this link was made"
      of wvAbsent: "this link predates the content witness, so its coordinate could not be verified"
      of wvUnknownArtifact: "the current trace's content hash is unknown, so the coordinate could not be verified"
      of wvMatches: "the link carried no coordinate"
    return PositionResolution(outcome: poRecoveredByAnchor,
      coordinate: inputs.anchorCoordinate, witness: verdict, visible: true,
      statement: "Position recovered from the link's " & $link.anchor.kind &
        " anchor because " & why & ".")

  if link.anchor.isValid and inputs.enclosingFrameCoordinate.len > 0:
    return PositionResolution(outcome: poNearestEnclosingFrame,
      coordinate: inputs.enclosingFrameCoordinate, witness: verdict, visible: true,
      statement: "The link's " & $link.anchor.kind &
        " anchor could not be resolved in this trace, so the nearest " &
        "enclosing frame is shown instead.")

  # Step 5 names WHY the coordinate could not be used, because the four reasons
  # are four different facts about the link and a reader who is about to be
  # moved somewhere else is owed the specific one. "Could not be restored" is
  # true of a regenerated trace and false of an older link, whose coordinate may
  # well still be correct and merely cannot be *checked* — telling that reader
  # the position was lost would be a confident wrong sentence, which is the
  # thing this precedence exists to prevent.
  PositionResolution(outcome: poStartOfExecution,
    coordinate: inputs.executionStartCoordinate, witness: verdict, visible: true,
    statement:
      if link.coordinate.len == 0:
        "This link carried no position, so the execution is shown from its start."
      else:
        case verdict
        of wvDiffers:
          "The trace was regenerated since this link was made, so its position " &
          "no longer means anything here, and the link carries no usable " &
          "anchor — the execution is shown from its start."
        of wvAbsent:
          "This link predates the content witness, so its position could not be " &
          "verified against the current trace, and it carries no usable " &
          "anchor — the execution is shown from its start."
        of wvUnknownArtifact:
          "The current trace's content hash is unknown, so this link's position " &
          "could not be verified, and it carries no usable anchor — the " &
          "execution is shown from its start."
        of wvMatches:
          # Reachable only with a matching witness and an empty `t`, which the
          # branch above already answers — kept total so a verdict added later
          # cannot fall through to a sentence written for another one.
          "This link carried no position, so the execution is shown from its start.")
