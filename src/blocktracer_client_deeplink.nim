## `blocktracer_client_deeplink` — the Client SDK's **browser-compilable**
## entry point: §6.0a's link grammar and its resolution precedence, and nothing
## else.
##
## ## Why this exists, and why it is not the facade
##
## `blocktracer_client` is the package's whole public surface and would be the
## obvious import here. It cannot be: its graph reaches
## `blocktracer/contract/ids`, which hashes with `std/sha1`, which reaches
## `std/endians`, which uses `copyMem` — undefined on the JS backend. `nim js`
## fails at `endians.nim(131)` before a line of this package's own code is
## considered. That is not a bug to route around; the artifact-id derivation
## genuinely needs a hash, and a browser genuinely cannot compute this one
## ([Trace-Artifacts.md](../../codetracer-specs/BlockTracer/Trace-Artifacts.md)
## §2.1 says the browser cannot recompute `executionInputId` at all).
##
## But the *deep link* is the one part of this package a browser must have.
## `client/hydrate/` is the surface that reads a shared URL and decides where
## the session lands, and §6.0a's precedence is exactly the decision that
## produces silent wrongness when it is left implicit. The alternatives were
## both worse than a second entry point:
##
##   * **Reimplement the precedence in the client.** Two producers of the rule
##     that decides where a shared link lands, drifting the moment either
##     changes — and the drift would be invisible, because both would land
##     *somewhere*.
##   * **Vendor a copy.** A copy with a hash manifest is what
##     `client/src/debugger/layout_model.nim` does for a type it cannot import
##     across a repository boundary. There is no repository boundary here; the
##     module is three directories away and compiles fine.
##
## So: a named second entry point, in the same standing as
## `blocktracer_client_embed` — which exists for the mirror-image reason, that
## exactly one module may reach the Embed SDK. Both are named in the facade's
## own constants and both are checked by `ci/test/client-sdk-boundary.sh`,
## which fails if this module reaches any SDK internal other than `deeplink`.
## Widening it is therefore a deliberate edit to a guard, not a quiet import.
##
## ## What a consumer gets, and what it does not
##
## `parseDeepLink` / `emitFragment` / `shareLink` (the grammar), `witnessFor` /
## `checkWitness` (§6.0's content witness), and `resolvePosition` (§6.0a's
## five-step precedence, including the sentence each visible branch shows).
##
## It does **not** resolve an anchor. Turning `call:0.2.6` into a coordinate
## requires the trace, which `deeplink.nim`'s own header puts one layer down —
## the consumer looks that up and hands the answer back as `PositionInputs`.
## In BlockTracer that consumer is
## `client/src/debugger/deeplink_landing.nim`, which resolves anchors against
## the call-trace and event-log rows the session already carries.

import blocktracer_client/deeplink
export deeplink
