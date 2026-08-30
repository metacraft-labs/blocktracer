## `blocktracer_client` — the BlockTracer **Client SDK** facade.
##
## **This module is the package's entire public surface.** Everything a
## consumer may use is re-exported here; anything not re-exported is private
## and may change without a version bump. `ci/test/client-sdk-boundary.sh`
## fails the build when a declared consumer reaches past it, which is the
## enforcement [Client-SDK.md](../../codetracer-specs/BlockTracer/Client-SDK.md)
## §1.1 asks for — "a rule that depends on someone remembering it is not a
## boundary".
##
## ## The layer this is
##
## | Layer | Answers | Knows about |
## | --- | --- | --- |
## | CodeTracer Embed SDK | *Give me a debugger over this trace* | `.ct` containers, sessions, ViewModels, stepping |
## | **This one** | *Give me this chain's data, and the trace for any transaction in it* | The published static tree, and how to resolve it |
##
## **The Client SDK depends on the Embed SDK. Never the reverse**
## (Client-SDK.md §1.1). The Embed SDK contains no chain concept, because Noir
## Studio consumes it and has no chain at all — a boundary with a real consumer
## on each side rather than a guess (§2).
##
## The dependency lives in exactly ONE module: `blocktracer_client_embed`,
## which imports `codetracer_embed` and converts a `ResolvedTrace` into the
## Embed SDK's `TraceSource`. Everything else here — reading the tree,
## resolving identifiers, navigating indices, deep links, source bundles — is
## chain work that needs no debugger, which is also §1's point: "most of what
## the Client SDK does is not debugging".
##
## ## Usage
##
## ```nim
## import blocktracer_client
##
## let store = localTree("dist")                 # or any path -> bytes closure
## let opened = openChain(store, "aztec")
## if opened.outcome == ooOpened:
##   let session = opened.session                # the generation is now PINNED
##   let tx = transaction(store, session, txHash)
##   if tx.outcome == roFound:
##     for t in resolveTraces(store, session, tx.view):
##       echo t.describe                         # ready / absent-with-reason / …
## ```
##
## ## What is deliberately not here
##
## | Withheld | Why |
## | --- | --- |
## | Chain RPC of any kind | This package reads *published files*; reaching a node is the pipeline's job on the far side of the seam (Pipeline-Architecture.md §3.1a) |
## | Writing of any kind | The read path is static and the one write surface is the pipeline's (Client-SDK.md §3) |
## | Any identity | The read path stays anonymous (CodeTracer-Identity.md §4). `ObjectStore.fetchProc` takes a path and nothing else, so a read *cannot* carry one |
## | Rendering, layout, CSS | Inherited from the layer below (CodeTracer-Embed-SDK.md §3.2) |
## | Ranking, suggestions, query parsing | Product decisions belonging to the consumer (Client-SDK.md §5) |
##
## ## Contract types are imported, never redeclared
##
## `OutcomeOverall`, `TraceAvailability`, `Role`, `Cost`, `BlockDetail`,
## `TransactionFacts`, `TraceSelection`, `TraceManifest` and the rest are M5b's,
## re-exported from `blocktracer/contract/model` verbatim. A consumer needs one
## import to get both the reader and the vocabulary it speaks, and there is no
## second schema to drift (Static-Site-Architecture.md §2.9).

# The contract's public types carry `JsonNode` (a transaction's chain-native
# payload, a manifest's `sourceBundles`), so a consumer cannot use this facade
# without `std/json`. Re-exported so one import is genuinely enough.
import std/json
export json

import blocktracer_client/store
export store

import blocktracer_client/paths
export paths

import blocktracer_client/decode
export decode

import blocktracer_client/session
export session

import blocktracer_client/entities
export entities

import blocktracer_client/trace
export trace

import blocktracer_client/deeplink
export deeplink

import blocktracer_client/sources
export sources

import blocktracer_client/conformance
export conformance

const
  BlockTracerClientFacadeModule* = "blocktracer_client"
    ## The one module name a consumer may import from this package. The import
    ## lint reads it from here rather than hardcoding a string, so renaming the
    ## facade cannot silently disarm the guard.

  BlockTracerClientEmbedModule* = "blocktracer_client_embed"
    ## The one module that may import the Embed SDK. Named here so the lint can
    ## assert the dependency direction in both directions from one place:
    ## everything else in this package must be usable — and compilable — with
    ## no debugger anywhere near it.

  BlockTracerClientDeepLinkModule* = "blocktracer_client_deeplink"
    ## The one module a **browser** build may import instead of this facade.
    ##
    ## This facade's graph reaches `std/sha1` (through
    ## `blocktracer/contract/ids`, which derives `traceArtifactId`), and
    ## `std/sha1` does not compile on the JS backend — `std/endians` uses
    ## `copyMem`. So a `nim js` consumer cannot have the facade at all, and the
    ## part of this package it actually needs, §6.0a's deep-link grammar and
    ## resolution precedence, needs nothing but `std/strutils` and `std/tables`.
    ##
    ## Named here for the same reason the embed handoff is: the lint reads both
    ## names from this file, so renaming either module without renaming its
    ## constant is caught rather than silently disarming a guard. The guard
    ## additionally asserts that this entry point reaches **only**
    ## `blocktracer_client/deeplink` — widening the browser-visible surface is a
    ## deliberate edit to `ci/test/client-sdk-boundary.sh`, not a quiet import.
