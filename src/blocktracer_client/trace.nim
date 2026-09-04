## Transaction → trace artifact. The resolution this package exists for.
##
## `traceArtifactId = H(executionInputId, recorderBuild, profile, traceSchema)`
## ([Trace-Artifacts.md](../../../codetracer-specs/BlockTracer/Trace-Artifacts.md)
## §2.1) — derived by the client, never stored and never looked up. The
## derivation itself is **imported from `blocktracer/contract/ids`**, the same
## module the producer and the conformance validator use, which is what makes
## "the client computes the URL the pipeline wrote to" true by construction
## rather than by two implementations agreeing.
##
## The whole point of this module is the shape of its result:
##
## > **`availability: absent` is data with a reason, never a failed fetch**
## > ([Static-Site-Architecture.md](../../../codetracer-specs/BlockTracer/Static-Site-Architecture.md)
## > §2.3a).
##
## So `resolve` returns a value for every case, issues **no request at all**
## for `absent` and `unsupported` — there is nothing to fetch, and probing
## would turn a structural fact into a network outcome — and treats a `404`
## on an `onDemand` artifact as the expected answer rather than an error.

import ./store
import ./paths
import ./decode
import ./session
import ./entities
import ../blocktracer/contract/ids

type
  TraceResolutionKind* = enum
    trkReady = "ready"
      ## Published. The container is at `containerPath`.
    trkDivergent = "divergent"
      ## Published, and the recorder's differential oracle disagreed with the
      ## chain. It stays inspectable and is presented with a banner (FR-9).
    trkOnDemand = "onDemand"
      ## Not published yet. The address is still derivable, so a consumer can
      ## `GET` it and offer generation on 404 (§2.3a).
    trkAbsent = "absent"
      ## The chain's execution model offers no call structure to trace. There
      ## is no artifact and there never will be one for this execution.
    trkUnsupported = "unsupported"
      ## No recorder exists for this VM.
    trkNoOverlay = "noOverlay"
      ## The tree carries no TraceSelection entry for this transaction. NOT the
      ## same as `absent`: the tree has said nothing, rather than said no.
    trkNoExecution = "noExecution"
      ## The overlay names a selector the immutable facts do not, so no
      ## `executionInputId` exists to derive an address from.
    trkUnresolvable = "unresolvable"
      ## The address cannot be derived — no recorder pin in the registry for
      ## this chain, or facts with no `executionInputId`.

  ResolvedTrace* = object
    ## One execution's trace, resolved as far as the published tree allows.
    ##
    ## `availability` is the contract enum, carried verbatim when the overlay
    ## had one, so a consumer can render the producer's own vocabulary rather
    ## than this module's summary of it.
    selector*: string
    kind*: TraceResolutionKind
    hasAvailability*: bool
    availability*: TraceAvailability
    reason*: string
      ## Why, in the producer's words for `absent`/`unsupported` (§2.3a
      ## requires one), and in this module's for the structural cases.
    reconstructed*: bool
      ## Orthogonal to availability: a trace can be `ready` AND heuristically
      ## reconstructed, and presenting the second as a native execution trace
      ## is the confident lie §2.3a exists to prevent.
    declaredBytes*: int
      ## The overlay's byte hint, for a size affordance before any fetch.
    hasValidation*: bool
    validation*: ValidationSummary
    executionInputId*: string
    traceArtifactId*: string
    manifestPath*: string
    containerPath*: string
    instructionsPath*: string
      ## Where this recording's per-step program counters would be published.
      ## Derived alongside `containerPath` and never probed here — a resolution
      ## must not fetch an object nobody asked for, and the one surface that
      ## renders a listing is the one that should pay for finding out whether
      ## there is one.
    positionsPath*: string
      ## Where this recording's per-step SOURCE positions would be published —
      ## the rung above `instructionsPath`, derived and not probed for the same
      ## reason. See `tracePositionsPath` for why it is a sibling object rather
      ## than a manifest field, and why it is not `execution.sourceLevel`.
    calltracePath*: string
      ## Where this recording's CALL FRAMES would be published. Derived and not
      ## probed, like the two above.
      ##
      ## Orthogonal to both of them rather than another rung of the same ladder:
      ## `instructions` and `positions` are per-STEP streams and answer "where
      ## is this step", while this answers "what called what", which a recording
      ## can carry at any rung. Measured on the committed corpus: 26 containers
      ## at rung 3 and one at rung 2, and all 27 name their frames — so the two
      ## questions really are independent, rather than independent in principle
      ## and correlated in this data.
    hasManifest*: bool
    manifest*: TraceManifest
    manifestError*: string

proc isReplayable*(r: ResolvedTrace): bool =
  ## Whether a container exists to open. `divergent` counts: the trace remains
  ## inspectable and is shown with a banner, which is not the same as absent.
  r.kind in {trkReady, trkDivergent} and r.hasManifest

proc contentHash*(r: ResolvedTrace): string =
  ## `traceContentHash` — the hash of the generated container bytes
  ## (Trace-Artifacts.md §2.8). Empty until the manifest is in hand, because
  ## the address proves the inputs and nothing about the bytes.
  if r.hasManifest: r.manifest.container.hash else: ""

proc kindFor(a: TraceAvailability): TraceResolutionKind =
  case a
  of taReady: trkReady
  of taDivergent: trkDivergent
  of taOnDemand: trkOnDemand
  of taAbsent: trkAbsent
  of taUnsupported: trkUnsupported

proc executionInputIdFor(v: TransactionView, e: ExecTrace,
                         overlayCount: int): string =
  ## Pair an overlay entry with the immutable facts' execution.
  ##
  ## Both overlay shapes are contract-valid (§2.3a): a single-execution
  ## transaction emits `trace` with no selector, while a transaction with
  ## several emits `executions[]` with one. So a single unselectored overlay
  ## entry corresponds to the transaction's one execution, and anything else
  ## matches by selector. Guessing past that would mean addressing an artifact
  ## for an execution the facts never described.
  if e.selector.len == 0 and overlayCount == 1 and v.facts.executions.len == 1:
    return v.facts.executions[0].executionInputId
  for x in v.facts.executions:
    if x.selector == e.selector: return x.executionInputId
  ""

proc fetchManifest(store: ObjectStore, r: var ResolvedTrace) =
  let m = store.getJson(r.manifestPath)
  if not m.found: return
  if m.error.len > 0:
    r.manifestError = m.error
    return
  try:
    r.manifest = decodeTraceManifest(m.node)
    r.hasManifest = true
    r.containerPath = traceContainerPath(r.traceArtifactId, r.manifest.container.file)
  except ContractDecodeError as e:
    r.manifestError = e.msg

proc resolveExec*(store: ObjectStore, session: ChainSession,
                  v: TransactionView, e: ExecTrace, overlayCount: int,
                  probeOnDemand = true): ResolvedTrace =
  ## Resolve one execution. Never raises; never fetches for `absent` or
  ## `unsupported`.
  result.selector = e.selector
  result.hasAvailability = true
  result.availability = e.availability
  result.reason = e.reason
  result.reconstructed = e.reconstructed
  result.declaredBytes = e.bytes
  result.hasValidation = e.hasValidation
  result.validation = e.validation
  result.kind = kindFor(e.availability)

  if result.kind in {trkAbsent, trkUnsupported}:
    # Terminal, and deliberately silent: no address is derived and no object is
    # requested, so this can never present as a failed fetch (§2.3a).
    return

  result.executionInputId = executionInputIdFor(v, e, overlayCount)
  if result.executionInputId.len == 0:
    result.kind = trkNoExecution
    result.reason = "the overlay names execution '" & e.selector &
      "' but the immutable facts carry no executionInputId for it"
    return

  if not session.hasPin:
    result.kind = trkUnresolvable
    result.reason = "no recorder pinned for chain '" & session.chain &
      "' in " & registryPath(session.contractVersion) &
      "; the trace address cannot be derived (Trace-Artifacts.md §2.1)"
    return

  result.traceArtifactId = deriveTraceArtifactId(
    result.executionInputId, session.pin.recorder.id, session.pin.recorder.build,
    session.pin.profile.hash, session.pin.traceSchema)
  result.manifestPath = traceManifestPath(result.traceArtifactId)
  result.containerPath = traceContainerPath(result.traceArtifactId, "")
  result.instructionsPath = traceInstructionsPath(result.traceArtifactId)
  result.positionsPath = tracePositionsPath(result.traceArtifactId)
  result.calltracePath = traceCalltracePath(result.traceArtifactId)

  if result.kind == trkOnDemand and not probeOnDemand:
    return
  fetchManifest(store, result)

proc resolveTraces*(store: ObjectStore, session: ChainSession,
                    v: TransactionView, probeOnDemand = true): seq[ResolvedTrace] =
  ## Every execution of a transaction, resolved.
  let execs = v.execTraces
  if execs.len == 0:
    return @[ResolvedTrace(kind: trkNoOverlay,
      reason: "no TraceSelection entry at overlay version '" &
        session.traceSelectionVersion & "' for " & v.hash)]
  for e in execs:
    result.add resolveExec(store, session, v, e, execs.len, probeOnDemand)

proc resolveTrace*(store: ObjectStore, session: ChainSession,
                   v: TransactionView, selector: string,
                   probeOnDemand = true): ResolvedTrace =
  ## One execution by selector. `""` selects the sole execution of a
  ## single-execution transaction.
  let execs = v.execTraces
  if execs.len == 0:
    return ResolvedTrace(kind: trkNoOverlay,
      reason: "no TraceSelection entry at overlay version '" &
        session.traceSelectionVersion & "' for " & v.hash)
  if selector.len == 0 and execs.len == 1:
    return resolveExec(store, session, v, execs[0], execs.len, probeOnDemand)
  for e in execs:
    if e.selector == selector:
      return resolveExec(store, session, v, e, execs.len, probeOnDemand)
  ResolvedTrace(selector: selector, kind: trkNoExecution,
    reason: "transaction " & v.hash & " has no execution '" & selector & "'")

proc bestTrace*(traces: seq[ResolvedTrace]): int =
  ## Index of the execution a Debug affordance should open, or -1. The order is
  ## the strongest first, so a transaction whose private half is absent and
  ## whose public half is ready opens the public half.
  const rank = [trkReady, trkDivergent, trkOnDemand]
  for want in rank:
    for i, t in traces:
      if t.kind == want: return i
  -1

proc containerBytes*(r: ResolvedTrace): int =
  ## The container's true length, from the manifest, falling back to the
  ## overlay's hint. Zero when neither is known — never a guess.
  if r.hasManifest: r.manifest.container.bytes else: r.declaredBytes

proc describe*(r: ResolvedTrace): string =
  ## A one-line, log-safe summary. Carries no identity and no URL query.
  var s = $r.kind
  if r.selector.len > 0: s = r.selector & ":" & s
  if r.traceArtifactId.len > 0: s &= " " & r.traceArtifactId
  if r.reason.len > 0: s &= " (" & r.reason & ")"
  s
