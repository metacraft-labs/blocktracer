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
- **The `/idx/**` search indices and the richly pre-rendered HTML entry pages**
  (`/{chain}/tx/…`, `/block/…`, `/address/…`). This slice emits the `/d/**` data
  plane, the generation-scoped derived maps (`height`, `blocks`, `addr`) that the
  crawler walks, and `/t/**`, but **not** the `/idx/{chain}/names/**` and
  `/idx/hash/**` search shards (their binary format is Search-And-Routing §5, real
  work of M7/M9) nor the HTML entry pages (the render layer, M5/M9). The contract
  validator does not require `/idx/**`, so the demo tree is still contract-conformant
  and fully walkable from `current.json`; these remain open M5c deliverables.
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

## Resolved contract decisions (M5b/M5c review, 2026-08-27)

The three points the implementation had flagged were adjudicated against the spec
during the M5b/M5c review. All three resolve in favour of the shapes this slice
already emits; they are recorded here as decisions with citations, not open guesses.

### D1 — Multi-execution overlay: one per-`txHash` file, singular `trace` *or* `executions[]`

**Decision.** The TraceSelection overlay is one file per transaction,
`/d/{chain}/ts/{v}/{h0h1}/{txHash}.json`. A single-execution transaction carries a
singular `trace` object; a transaction with several independently-debuggable
executions (the Aztec private/public split) carries an `executions[]` array whose
elements name their `selector`. The sub-execution selector lives in the **identifier**
(it is folded into `executionInputId`, Trace-Artifacts §2.0), **not** in the overlay
path.

**Spec basis.** The overlay path is fixed as per-`txHash` by Static-Site-Architecture
§2.3b and the Object-Class Registry §2.9 — both enumerate
`/d/{chain}/ts/{v}/{h0h1}/{txHash}.json`, with no per-selector path — so the
alternative `…/{txHash}/{selector}.json` is **rejected**: it would contradict the
normative path table. Trace-Artifacts §6 shows the singular `trace` object as the
overlay's contents for the ordinary case; Trace-Artifacts §2.2 says a transaction with
several independently-debuggable executions has an identifier that "includes the
sub-execution selector and the transaction page **lists the executions**." The
`executions[]` array inside the one per-`txHash` file is the direct encoding of "lists
the executions"; the singular `trace` is the direct encoding of §6. Supporting both is
therefore required by the spec, not a hedge — a validator accepting only one shape
would reject one of the two normative examples.

### D2 — `executionInputId` placement: immutable facts, nested under `executions[]`

**Decision.** `executionInputId` lives in the immutable `TransactionFacts`, nested per
execution as `executions[].executionInputId`.

**Spec basis.** Static-Site-Architecture §2.3b is explicit: "`executionInputId` is a
pure function of consensus data and belongs in the immutable facts," and its derivation
box lists it as coming "from TransactionFacts, immutable." Trace-Artifacts §2.1
concurs: "a transaction's data object carries it." Nesting it *under* `executions[]`
(rather than one top-level field) is not merely defensible but **necessary**: a
transaction with several executions (Aztec private/public) has one `executionInputId`
per execution, which a single top-level field could not represent. §2.2's "lists the
executions" confirms the per-execution granularity.

### D3 — `root.json` field names (`maps`, `traceSelectionVersion`)

**Decision.** The generation root nests its derived-map references under a `maps`
object (`summary`, `height`, `blocks`, `addr`, `txstate`), alongside
`contractVersion`, `chain`, `generation` and `traceSelectionVersion`.

**Spec basis / limits.** The spec fixes the root's *role* — "snapshot root: every
derived map below" (Static-Site-Architecture §2, path table) — and names the concept
`traceSelectionVersion` carries: "the generation root records the TraceSelection
version it was sealed against" (§2.3b). It does **not** pin the root object's exact
JSON field names. `traceSelectionVersion` is taken verbatim from that §2.3b sentence;
`maps` is a container for "every derived map below," chosen so a crawler reaches the
whole generation from one object. This is the most defensible reading of a genuinely
silent point; if the real pipeline (M7) needs different names, that is an additive
contract change under the Publishing-And-Caching §6.1 rule, not a re-interpretation.
