# The BlockTracer Data Contract — in-repo representation (M5b)

This document records **how** this repository encodes the versioned data contract
and **why**. The authoritative *definitions* live in `codetracer-specs`; this file
does not restate them, per the milestone-hygiene rule that a milestone references
specs rather than acts as one.

- Static-tree schema: `codetracer-specs/BlockTracer/Static-Site-Architecture.md`
  §2 (object tree), §2.3 (the normative transaction schema), §2.3a (trace
  availability), §2.3b (the four-layer split), §2.9 (the Object-Class Registry).
- Trace-manifest schema: `codetracer-specs/BlockTracer/Trace-Artifacts.md`
  §3 (layout), §4 (manifest).
- The seam itself: `codetracer-specs/BlockTracer/Data-Contract.md`.

## The single contract version

One identifier, `ContractVersion = 1` (`src/blocktracer/contract/version.nim`),
governed by the additive-only schema rule. It is carried by:

- the static tree in **`root.json`** → field `contractVersion`, and
- every trace **`manifest.json`** → field `schema`.

The validator and (eventually) the site-generator **refuse** a version they do not
support rather than misreading it. `ArtifactSchemaVersion` is a separate, narrower
version that feeds only the `traceArtifactId` derivation (Trace-Artifacts §2.1).

## The representation chosen: typed Nim structs + an independent validator

We encode the contract as **concrete Nim object types**
(`src/blocktracer/contract/model.nim`), and separately ship a **structural
conformance validator** (`src/blocktracer/validator.nim`) that checks raw JSON.

Why this, and not (say) JSON Schema alongside the types:

1. **One source of truth.** The Object-Class Registry (Static-Site-Architecture
   §2.9) exists precisely because *restatements drift*. A second machine schema
   would be a second source of truth to keep in lock-step. Nim object **variants**
   are the natural, exact encoding of the spec's discriminated unions — "flatten a
   natively-meaningful fact and you fail here" becomes a type error.
2. **House language.** The ecosystem is Nim (isonim, codetracer-nim, the
   recorders); both the demo producer (M5c) and the real producer (M6/M7/M10) are
   Nim. A typed representation is directly reusable by both.
3. **Producer-independence is provable.** The validator reads **raw JSON**, so it
   does not require a tree to have passed through these types. The test suite
   validates BOTH a demo-generated Aztec tree AND a hand-built EVM tree with
   different discriminated-union values through the same validator with no
   producer-specific branch — which is the whole of what "the contract names no
   producer" means.

The trade-off: consumers in other languages do not get a ready-made JSON Schema.
If a non-Nim consumer appears, generating JSON Schema *from* these types (one
direction, one source) is the additive way to add it without a second truth.

## What the validator checks

`validateTree(root)` walks from each chain's `current.json` and asserts:

- `root.json` / `manifest.json` carry the supported contract version;
- the discriminated-union transaction schema — every union carries its `kind`
  (§2.3);
- `availability: absent` / `unsupported` carry a **reason**, never a failed fetch
  (§2.3a);
- the **four-layer split** — immutable `TransactionFacts` must NOT carry
  `trace` / `validation` / `finality` / `canonical` (§2.3b);
- generation-root and index shape (§2);
- manifest fields, `container.bytes` == real file size, `container.hash` matches
  the bytes, and the **derived** `traceArtifactId` matches the artifact's path
  (§4, §2.1);
- **walkability** — every reference reachable from `current.json` resolves; a
  dangling reference is an error.

The `traceArtifactId` is *derived* (not stored in the overlay), exactly as the
browser derives it: `H(executionInputId ‖ recorder pin ‖ profile ‖ traceSchema)`.
`executionInputId` comes from the immutable facts (`executions[].executionInputId`)
and the recorder pin from `/registry/chains.v1.json` — so the validator finds each
artifact with **no lookup**, the same property the client relies on.

## Deliberately NOT built in this slice

These are later milestones. They are left as clean gaps, not stubs that pretend to
work:

- **The IsoNim explorer UI / browser replay** (M5, M9, M0, M1). Nothing here
  renders a page or opens a trace in a browser.
- **The publisher / CDN delivery** (M8). The generator writes a *local* tree that
  is a valid publishing input (`current.json`, sealed generation root, immutable
  objects); it does not upload, compute deltas, or set cache headers.
- **Real ingestion and real replay** (M6, M7, M10). The demo generator is a *fake*
  extractor/trace-gen behind the same seam.
- **Real `nargo trace` output.** See `fixtures/trace/README.md` — the `.ct`
  containers are a labelled stand-in because `nargo` was unavailable.
- **BLAKE3 identity.** The demo derivation uses SHA-1 (Nim stdlib has no BLAKE3)
  and tags its ids honestly (`sha1:…`). The contract treats ids as opaque, so
  swapping in BLAKE3 behind `contract/ids.nim` is a producer change, not a
  contract change.

## Open questions (flagged for review)

- **Multi-execution overlay shape.** The spec's §6 shows a *singular* `trace`
  object in the TraceSelection overlay, but Trace-Artifacts §2.2 says a transaction
  with several independently-debuggable executions "lists the executions". This
  slice emits a singular `trace` for single-execution transactions and an
  `executions[]` array (keyed by `selector`) for the Aztec private/public split.
  Both are accepted by the validator. **Is `executions[]` the intended encoding, or
  should the overlay path itself carry the sub-execution selector
  (`…/{txHash}/{selector}.json`)?** The `traceArtifactId` derivation already takes a
  selector-scoped `executionInputId`, so either works; the overlay shape is the
  open choice.
- **`executionInputId` placement.** §2.3's sample JSON does not show it, but §2.3b
  / §2.1 say it belongs in the immutable facts. This slice puts it under
  `executions[].executionInputId`. Confirm that is the field the real extractor
  will populate.
- **`root.json` extra fields.** The spec names `root.json` as "the snapshot root:
  every derived map below" without pinning its exact field names. This slice uses a
  `maps` object of relative paths plus `contractVersion` / `traceSelectionVersion`.
  The names are a proposal.
