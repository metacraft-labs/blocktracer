## The single, versioned Data-Contract identifier (M5b).
##
## This id is carried by the static tree in `root.json` (field `contractVersion`)
## and by every trace `manifest.json` (field `schema`). A producer states the
## version it emits; the site-generator and the conformance validator refuse a
## version they do not support rather than misreading it.
##
## Governed by the additive-only schema rule
## (codetracer-specs/BlockTracer/Publishing-And-Caching.md §6.1): a bump is only
## permitted for additive changes; a breaking change is a new major that the
## validator refuses.
##
## See codetracer-specs/BlockTracer/Data-Contract.md §3.

const
  ContractVersion* = 1
    ## The integer contract version. Emitted as `root.json.contractVersion` and
    ## `manifest.json.schema`.

  ContractTag* = "blocktracer/contract/v1"
    ## Human-readable domain tag for the contract, used for logs and diagnostics.

  ArtifactSchemaVersion* = 1
    ## `artifactSchemaVersion` input to `traceArtifactId` derivation
    ## (Trace-Artifacts.md §2.1). Kept separate from `ContractVersion` because
    ## the trace-id derivation is a distinct, narrower schema.
