## `blocktracer_client_paths` — the Client SDK's **browser-compilable** entry
## point for object-path derivation, and nothing else.
##
## ## Why this exists, and why it is not the facade
##
## The same reason `blocktracer_client_deeplink` exists, arriving through a
## second door. `blocktracer_client` is the package's whole public surface and
## would be the obvious import; it cannot be, because its graph reaches
## `blocktracer/contract/ids`, which hashes with `std/sha1`, which reaches
## `std/endians`, which uses `copyMem` — undefined on the JS backend. `nim js`
## fails at `endians.nim(131)` before a line of this package's own code is
## considered. That is measured, not argued: it is the first error this module's
## consumer hit.
##
## ## Why a browser needs paths at all
##
## `/search?q=` is resolved in the browser. It has to be:
## Static-Site-Architecture puts the whole site behind a static file server, and
## a static file server never sees a query string. So Search-And-Routing §4's
## direct path — "the client computes the object path from the identifier and
## fetches it" — is computed in a tab, and §5.4 makes that the specified
## fallback rather than a degradation ("Search must never fail because an index
## did not load").
##
## Which leaves exactly one question: WHERE does the object live. The answer is
## `paths.nim` and it must not be answered twice. That module's own header
## states the rule — "a second `hexShard` would be a second place for the layout
## to drift, which is the failure Static-Site-Architecture.md §2.9 exists to
## prevent" — and a JavaScript reimplementation of `d/{chain}/tx/{shard}/{hash}.json`
## in `client/searchboot/` would be precisely that second place, in a second
## language, where no Nim test could see it.
##
## The alternative considered and rejected was to have the browser probe the
## RENDERED page `/{chain}/tx/{hash}/` instead of the data object, which needs
## no path derivation. It is worse: the rendered page is a view, the data object
## is the contract, and a search that confirmed a view exists would report a hit
## for any chain whose 404 handling ever changed.
##
## ## What a consumer gets, and what it does not
##
## Every path derivation in `blocktracer_client/paths` — `registryPath`,
## `currentPath`, `blockPath`, `txFactsPath`, and the rest — plus `hexShard` and
## `traceShards`, which `paths` re-exports from `blocktracer/contract/shards`.
##
## It gets no reader, no store and no session. Computing a path is not fetching
## one: the consumer does its own I/O, which in a browser it must, because
## `ObjectStore.fetchProc` is synchronous and a tab's fan-out is not.
##
## Like `blocktracer_client_deeplink` and `blocktracer_client_embed`, this is
## checked by `ci/test/client-sdk-boundary.sh`, which fails if this module's
## closure grows past the JS-safe set it is allowed to be. Widening it is a
## deliberate edit to a guard, not a quiet import.

import blocktracer_client/paths
export paths
