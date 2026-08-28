## viewmodel/replay_status.nim
##
## **The write half of the seam.** M2b's review put it in one sentence:
##
##   "The seam is `ReplayDataStore`'s four setters plus a `CtReplayStatus`
##   backend event: **the layer above writes, the panes read**."
##
## This module is the layer above writing. It turns chain- and delivery-shaped
## facts — a resolved trace artifact, a manifest verdict, a source-bundle
## chain, a host capability probe against a container of a known size — into
## the four axes of the Embed SDK's degraded-state catalogue
## (`viewmodel/store/degraded_state.nim`), in the wire spellings
## `applyReplayStatus` accepts.
##
## The result is that a BlockTracer pane over an SDK ViewModel renders
## `PaneDegradation` values without knowing that chains exist, which is the
## property `CodeTracer-Embed-SDK.md` §3.2 requires and
## `ci/test/sdk-facade-boundary.sh` enforces by name.
##
## ## Why the vocabulary is mirrored here rather than imported
##
## Importing `codetracer_embed` to get `ReplayAvailability` would put the
## debugger on the Nim path of every module that touches a degraded state — the
## whole explorer. `Client-SDK.md` §1 is explicit that "most of what the Client
## SDK does is not debugging", and `ci/test/client-sdk-boundary.sh` makes the
## chain half compiling with no debugger anywhere near it a checked property
## rather than a claim. The Embed SDK's own design already anticipates this:
## `CtReplayStatus` is a **JSON event with string-valued axes**, deliberately,
## so that "a host that only ever learns about capability can send
## `{"capability": "..."}` and nothing else".
##
## So the seam is a wire seam, and this module owns this side of it. The
## spellings below are the wire contract, not a copy of an enum:
## `parseReplayAvailability` and its three siblings are written against
## §14.1a's and §14.2's own table rows rather than against Nim identifiers,
## precisely so the enums can be renamed without breaking a host.
##
## **The spellings are checked against the real parsers, not trusted.**
## `tests/tviewmodelseam.nim` compiles against the pinned Embed SDK
## (`ci/embed-sdk-pin.env`), feeds every value this module can emit through the
## real `applyReplayStatus`, and asserts the axis it lands on. A spelling that
## drifts on either side fails that suite. Nothing here is verified by reading.
##
## ## What is deliberately NOT an axis here
##
## `ResolvedTrace.reconstructed` — a heuristically reconstructed trace
## (Static-Site-Architecture.md §2.3a: "presenting the second as a native
## execution trace is the confident lie") — has no counterpart among the Embed
## SDK's four axes, and inventing one would be adding a chain concept to a
## package that must not have one. It stays on `TraceStatusVM`, where the
## explorer renders it, and is not smuggled into `integrity`.

import std/json

import ./contract_equality   # the facade, plus `==` for its discriminated unions

type
  ArtifactRetention* = enum
    ## The wire spellings of the Embed SDK's `ReplayAvailability`
    ## (Page-Descriptions.md §14.1a's five table rows, in that order).
    ##
    ## `arWindowExpired` and `arUnreplayable` are distinct values and not a
    ## bool for §14.1a's own reason: "'Not now' and 'not ever' are different
    ## states ... Presenting either as the other is the failure this table
    ## exists to prevent."
    arRetained = "retained"
    arWindowedLive = "windowed-live"
    arWindowExpired = "window-expired"
    arNeverGenerated = "never-generated"
    arUnreplayable = "unreplayable"

  ArtifactIntegrity* = enum
    ## The wire spellings of the Embed SDK's `TraceIntegrity` — §14's "Trace
    ## truncated" and "Divergence detected" rows.
    aiComplete = "complete"
    aiTruncated = "truncated"
    aiDivergent = "divergent"

  HostCapability* = enum
    ## The wire spellings of the Embed SDK's `ReplayCapability` — one value per
    ## row of §14.2's failure table, so the cause survives to the pane instead
    ## of collapsing into "it did not work".
    hcCapable = "capable"
    hcWasmCompilationFailed = "wasm-compilation-failed"
    hcInsufficientMemory = "insufficient-memory"
    hcRangeRequestsUnsupported = "range-requests-unsupported"
    hcWorkerUnsupported = "worker-unsupported"

  SourceVerification* = enum
    ## The wire spellings of the Embed SDK's `SourceAvailability` — §14's "No
    ## verified source" row.
    svVerified = "verified"
    svUnverified = "unverified"
    svAbsent = "absent"

  ReplayStatusUpdate* = object
    ## One `CtReplayStatus` body, before serialisation.
    ##
    ## Every axis is optional and an absent axis leaves the store's signal
    ## alone, which is `applyReplayStatus`'s documented behaviour and the
    ## reason a `CapabilityVM` that learns only about the host can write
    ## without claiming anything about the artifact.
    hasRetention*: bool
    retention*: ArtifactRetention
    hasIntegrity*: bool
    integrity*: ArtifactIntegrity
    hasCapability*: bool
    capability*: HostCapability
    hasVerification*: bool
    verification*: SourceVerification

const
  ReplayStatusEventKind* = "CtReplayStatus"
    ## The `CtEventKind` name the Embed SDK's decoder is registered under. Named
    ## here so a host that delivers this body as a backend event rather than
    ## through the setters has one place to read it from.

func toReplayStatusBody*(u: ReplayStatusUpdate): JsonNode =
  ## The `CtReplayStatus` body. Only the axes this update actually learned
  ## about appear, so writing it is never an accidental claim about the other
  ## three.
  result = newJObject()
  if u.hasRetention: result["availability"] = %($u.retention)
  if u.hasIntegrity: result["integrity"] = %($u.integrity)
  if u.hasCapability: result["capability"] = %($u.capability)
  if u.hasVerification: result["sourceAvailability"] = %($u.verification)

func isEmpty*(u: ReplayStatusUpdate): bool =
  ## Whether this update would write nothing. A page that resolved no trace and
  ## probed no host should send nothing rather than an empty object.
  not (u.hasRetention or u.hasIntegrity or u.hasCapability or u.hasVerification)

# ---------------------------------------------------------------------------
# The derivations. Pure functions over Client SDK values, so every one of them
# is testable with no store, no session and no renderer.
# ---------------------------------------------------------------------------

func retentionFor*(r: ResolvedTrace): ArtifactRetention =
  ## §14.1a's five states, from what the published tree says.
  ##
  ## The key derivation is the third branch, and it rests on a normative
  ## simplification: **`Trace-Artifacts.md` §2.9 says a `404` under `/t/` is
  ## unambiguous — it means "not currently present", which is exactly the case
  ## that may become present after a generation or a renewal.** So an overlay
  ## that says `ready` while the manifest is not there is not a producer bug to
  ## be reported as an error; it is §14.1a's "window expired" row, and it is
  ## renewable.
  ##
  ## **`arWindowedLive` is not reachable from the current contract, and that is
  ## recorded rather than papered over.** Retention class is spec'd as a field
  ## of the TraceSelection overlay (Static-Site-Architecture.md §2.3b, "Trace
  ## availability, validation summary, **retention state**"; Trace-Artifacts.md
  ## §2.9's last table row) and M5b's `ExecTrace` does not carry it. Until it
  ## does, a present artifact is reported as `arRetained` — the weaker, true
  ## statement — rather than guessed at. `client/tests/test_chain_viewmodels.nim`
  ## asserts exactly which values are reachable, so the day the field lands the
  ## suite fails until this function is updated.
  case r.kind
  of trkReady, trkDivergent:
    if r.hasManifest: arRetained
    elif r.manifestError.len > 0:
      # Found and unreadable. Not an expiry: a renewal republishes the same
      # deterministic bytes, so offering one would be §14's retry that cannot
      # succeed. Terminal from the reader's position, with the reason on
      # `TraceStatusVM`.
      arUnreplayable
    else: arWindowExpired
  of trkOnDemand:
    # The overlay was written before the artifact existed; the artifact may
    # have been published since. The manifest is the authority, not the
    # overlay, because it is the object that has to exist for a debugger to
    # open.
    if r.hasManifest: arRetained else: arNeverGenerated
  of trkAbsent, trkUnsupported:
    # §2.3a's structural cases: there is no artifact and there never will be
    # one for this execution. `resolveExec` issues zero reads for these, so
    # this is a statement the tree made rather than one a 404 implied.
    arUnreplayable
  of trkNoOverlay, trkNoExecution, trkUnresolvable:
    # Terminal *from the reader's position*: no address can be derived, so
    # there is nothing for a Renew or a Generate to act on.
    #
    # The conservative mapping is deliberate. The alternative — leaving the
    # axis unset — lands on the store's seeded `raRetained`, and
    # `applyReplayStatus`'s own doc names that as the failure to prevent: "a
    # host that starts speaking a spelling this build does not know would
    # otherwise silently report a healthy replay". The specific reason is not
    # lost; `TraceStatusVM` carries it, and the chain-side row
    # (`cdRecorderUnavailable` for `trkUnresolvable`) is what the page renders.
    arUnreplayable

func integrityFor*(r: ResolvedTrace): ArtifactIntegrity =
  ## §14's two integrity rows, with divergence ranked above truncation for
  ## M2b's reason: a short replay is a smaller lie than a wrong one.
  ##
  ## Two sources, in order. The manifest's `validation` is the pipeline's own
  ## verdict on the bytes it published (Trace-Artifacts.md §4); the overlay's
  ## `ExecTrace.validation` is the same verdict summarised one layer up, and is
  ## all a page has before the manifest is fetched. Reading both means the
  ## banner appears on the first render rather than on the second.
  if r.hasManifest and r.manifest.validation.status == vsDivergent:
    return aiDivergent
  if r.kind == trkDivergent:
    return aiDivergent
  if r.hasValidation and r.validation.status == vsDivergent:
    return aiDivergent
  if r.hasManifest and r.manifest.execution.truncated:
    return aiTruncated
  aiComplete

func verificationFor*(bundles: openArray[BundleResult];
                      codeHashCount: int): SourceVerification =
  ## §14's "No verified source" row, from the source-bundle chain.
  ##
  ## Three answers, and the distinction between the last two is the one the
  ## Embed SDK's enum exists to preserve: `svAbsent` means there is nothing for
  ## a supply-sources action to attach to, while `svUnverified` means there is
  ## a code hash and no bundle for it — which is the ordinary case on every
  ## chain and is what §14's "supply-sources action prominent" is about.
  ##
  ## A transaction that executed no contract code at all — a plain value
  ## transfer — has no code hash, and offering to supply sources for it would
  ## be an affordance with no subject.
  ##
  ## `mqPartial` counts as unverified. The Embed SDK documents `savVerified` as
  ## "source is present **and matches the recorded build**", and a partial match
  ## does not; a page that showed a partial match as verified would be claiming
  ## a correspondence the bundle itself declines to claim.
  if codeHashCount == 0: return svAbsent
  for b in bundles:
    if b.outcome != boLoaded: return svUnverified
    if b.bundle.match != mqFull: return svUnverified
  if bundles.len < codeHashCount: return svUnverified
  svVerified

func replayStatusFor*(r: ResolvedTrace; bundles: openArray[BundleResult];
                      codeHashCount: int;
                      capability: HostCapability): ReplayStatusUpdate =
  ## Everything a debug route learns at once, as one body — which is the shape
  ## `CtReplayStatus` was designed for: "a host that knows one of them usually
  ## learns the rest at the same moment (session start, a validation verdict, a
  ## capability probe)".
  ReplayStatusUpdate(
    hasRetention: true, retention: retentionFor(r),
    hasIntegrity: true, integrity: integrityFor(r),
    hasCapability: true, capability: capability,
    hasVerification: true,
    verification: verificationFor(bundles, codeHashCount),
  )
