## `blocktracer_client_embed` — the handoff to the CodeTracer Embed SDK.
##
## **This is the only module in the repository that imports `codetracer_embed`,
## and the dependency runs one way: Client SDK → Embed SDK, never the reverse**
## ([Client-SDK.md](../../codetracer-specs/BlockTracer/Client-SDK.md) §1.1).
## `ci/test/client-sdk-boundary.sh` enforces both halves of that sentence.
##
## ## Why this is a separate module and not part of the facade
##
## Client-SDK.md §5 leaves open whether the two layers should ship as one
## package or two: "one package with the chain half tree-shakeable is
## friendlier; two make the layering unavoidable. The second is more honest and
## slightly less convenient." This repository answers *two modules*, for a
## concrete reason rather than a preference:
##
##   * Everything in `blocktracer_client` — reading the published tree,
##     resolving a transaction, deep links, source bundles — is chain work that
##     needs no debugger. The explorer's pre-render pass and every conformance
##     test compile it with no Embed SDK on the path at all, which is a
##     mechanical demonstration that the chain half does not depend on the
##     debugger half.
##   * A consumer that *does* want to open a trace imports this module, and
##     then needs the Embed SDK. The layering is unavoidable because the import
##     is unavoidable, not because a comment says so.
##
## ## What it does
##
## One conversion, in the direction the boundary allows: a `ResolvedTrace` —
## which knows about chains, transactions and generations — becomes a
## `TraceSource`, which knows about none of them. After this call the Embed SDK
## is holding a URL and a container, exactly as it would for a `.ct` from
## someone's own CI, which is what lets Noir Studio consume that layer without
## inheriting a chain concept (Client-SDK.md §2).
##
## ## Building against it
##
## The Embed SDK lives in the `codetracer` repository
## (`src/frontend/viewmodel/codetracer_embed.nim`). Put it on the Nim path:
##
## ```
## nim c --path:$CODETRACER_SRC/src/frontend/viewmodel \
##       --path:$CODETRACER_SRC/src/frontend \
##       --path:$CODETRACER_SRC/src \
##       --path:$ISONIM_SRC/src …
## ```
##
## `just sdk-test-embed` does exactly that; `ci/test/client-sdk-boundary.sh`
## scans the same tree for the reverse violation.

import std/[json, strutils]

import blocktracer_client
export blocktracer_client

# The Embed SDK, through its facade and nothing else. Importing
# `viewmodel/sdk/trace_source` directly would pin an SDK internal as public
# ABI, which is what CodeTracer-Embed-SDK.md §7's stability contract exists to
# prevent — and what that package's own `sdk-facade-boundary.sh` fails on.
import codetracer_embed
export codetracer_embed

type
  TraceSourceOutcome* = enum
    tsoReady = "ready"
      ## A container exists and `source` addresses it.
    tsoNotReplayable = "notReplayable"
      ## There is nothing to open, and `reason` says why in the producer's own
      ## words for `absent` / `unsupported` (Static-Site-Architecture.md §2.3a).
      ## This is data — the caller shows the transaction — never an exception.

  TraceSourceResult* = object
    case outcome*: TraceSourceOutcome
    of tsoReady:
      source*: TraceSource
      contentHash*: string
        ## `traceContentHash` of the container this source addresses, for the
        ## deep-link content witness (Debugger-Integration.md §6.0).
      divergent*: bool
        ## The recorder's differential oracle disagreed with the chain. The
        ## trace remains inspectable and MUST be presented with a banner
        ## (Trace-Artifacts.md §4); it is not a reason to withhold it.
      reconstructed*: bool
        ## Heuristically reconstructed rather than natively recorded. Carried
        ## through because presenting the second as the first is the confident
        ## lie this product exists to avoid (§2.3a).
    of tsoNotReplayable:
      reason*: string

proc joinUrl(base, path: string): string =
  if base.len == 0: return path
  if base.endsWith("/"): base & path else: base & "/" & path

proc toTraceSource*(resolved: ResolvedTrace, baseUrl: string): TraceSourceResult =
  ## Turn a resolved trace into something the Embed SDK accepts.
  ##
  ## `baseUrl` is the consumer's origin for the published tree. The SDK does
  ## not pick it and does not have a default: choosing an endpoint is the
  ## consumer's business (CodeTracer-Embed-SDK.md §3.2, "network policy,
  ## endpoints, auth" are not in the SDK), and a default would be this package
  ## quietly deciding where a third party's bytes come from.
  if not resolved.isReplayable:
    let why =
      if resolved.reason.len > 0: resolved.reason
      else: "no replayable artifact (" & $resolved.kind & ")"
    return TraceSourceResult(outcome: tsoNotReplayable, reason: why)
  TraceSourceResult(outcome: tsoReady,
    source: httpRangeTrace(joinUrl(baseUrl, resolved.containerPath)),
    contentHash: resolved.contentHash,
    divergent: resolved.kind == trkDivergent,
    reconstructed: resolved.reconstructed)

proc toTraceSource*(resolved: ResolvedTrace, bytes: seq[byte]): TraceSourceResult =
  ## The offline handoff: a container already in memory — a downloaded export,
  ## or a test fixture. Works with no network at all
  ## (CodeTracer-Embed-SDK.md §8).
  if bytes.len == 0:
    return TraceSourceResult(outcome: tsoNotReplayable,
      reason: "the container is empty")
  TraceSourceResult(outcome: tsoReady, source: bytesTrace(bytes),
    contentHash: resolved.contentHash,
    divergent: resolved.kind == trkDivergent,
    reconstructed: resolved.reconstructed)

proc launchArgs*(r: TraceSourceResult): JsonNode =
  ## The DAP `launch` arguments for a ready source, in the Embed SDK's own wire
  ## form. Produced by the Embed SDK, not restated here.
  if r.outcome != tsoReady: newJObject() else: r.source.toLaunchArgs

proc witnessFor*(r: TraceSourceResult): string =
  ## The deep-link content witness for the container this source addresses
  ## (Debugger-Integration.md §6.0a, field `c`).
  if r.outcome != tsoReady: "" else: witnessFor(r.contentHash)

proc openPosition*(link: DeepLink, r: TraceSourceResult,
                   anchorResolved: bool, anchorCoordinate: string,
                   enclosingFrameCoordinate = "",
                   executionStartCoordinate = ""): PositionResolution =
  ## §6.0a's precedence, with step 1 and the witness supplied by the resolution
  ## above. The anchor lookup itself belongs to the debugger — it needs the
  ## container — so its result is an input rather than something this package
  ## pretends to know.
  resolvePosition(link, PositionInputs(
    artifactAvailable: r.outcome == tsoReady,
    currentContentHash: (if r.outcome == tsoReady: r.contentHash else: ""),
    anchorResolved: anchorResolved,
    anchorCoordinate: anchorCoordinate,
    enclosingFrameCoordinate: enclosingFrameCoordinate,
    executionStartCoordinate: executionStartCoordinate))
