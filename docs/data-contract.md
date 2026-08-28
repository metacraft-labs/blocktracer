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
- the **optional render + `/idx/**` layers** the generation root enumerates: when
  `root.render` is present, every walked entity has an HTML entry page whose inlined
  `#bt-data` matches the `/d` data plane and whose robots policy is correct; when
  `root.idx` is present, every walked hash resolves in the global hash index and the
  name shards decode, place their terms correctly and carry provenance (§ D4–D6).

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
- **On-demand trace generation.** `availability: onDemand` is emitted and the
  client can compute the artifact URL, but nothing here records a trace in
  response to a request.
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

## `/idx/**` and entry-page decisions (M5c completion, 2026-08-27)

M5c was accepted `in-progress` precisely because the `/idx/**` search indices and the
pre-rendered HTML entry pages were missing. They are now built. The spec fixes their
*logical content*, sharding keys and URL structure but does not pin every byte or
field; the readings below are the most defensible ones and are cited. The on-wire
formats live in one place each — `src/blocktracer/contract/searchidx.nim` (the two
`.bin` codecs) and `src/blocktracer/contract/entrypage.nim` (the inlined-data island)
— so producer and validator cannot drift (§2.9).

### D4 — The global hash index `/idx/hash/{version}/{prefix}.bin`

**Decision.** A binary shard per occupied hash prefix. The shard key is the leading
`prefixLen` hex chars of the 0x-stripped hash (`prefixLen = 2` for the demo). Each
shard is a self-describing little-endian structure: magic `BThx`, format byte,
`prefixLen`, stored-hash width, a per-shard chain dictionary, then entries sorted by
hash bytes, each `[hash][chainIdx u8][kind u8]` with `kind ∈ {tx, block, address}`. A
hash claimed by several `(chain, kind)` pairs gets one entry each. The demo stores the
**full** hash for an exact, collision-free answer; the production builder truncates to
the arithmetically-chosen width. The index `version` is `"1"`, independent of the
contract version.

**Spec basis.** Search-And-Routing §5: the path `/idx/hash/{version}/{prefix}.bin`,
"sharded by a leading slice of the hash," "an **exact map** from hash to `(chain,
entity kind)`," "immutable and version-addressed," and §5.1's per-`(chain, kind)`
collision entries are all encoded directly. §5.3's "~8 bytes an entry — a truncated
hash plus a chain and kind" motivates the chain dictionary (one byte per entry for the
chain) and is why truncation is a builder policy, not a contract fact — so storing the
full hash in the demo is a conformant, stricter choice. The spec says shard depth
"should be recomputed rather than fixed" (§5.3); `prefixLen` is therefore **recorded
in the generation root** (see D6) rather than hard-coded into the path, which is the
one point §5 leaves implicit and which a client must know to compute the shard path.

### D5 — Name shards `/idx/{chain}/names/{shard}.bin` + `meta.json`

**Decision.** `meta.json` (JSON, as the §2 path table shows) records `indexVersion`,
`chain`, `hashFunction` (`sha1-low32`), `shardBits`, `shardCount`, `entryCount`,
`termCount` and the shard path list. A term is normalised (lowercased, whitespace
collapsed) and its hash's low `shardBits` bits select the shard (`shardBits = 1` for
the demo → two shards). A shard `.bin` (magic `BTnx`) maps each term to postings of
`(kind, id, displayName, provenance, weight)`. The demo's corpus is a small **curated
label set** it also publishes at `/d/{chain}/labels/0.json`, plus the chain's own
route — because the demo has no verified-contract pipeline to draw names from.

**Spec basis.** Search-And-Routing §6: the two paths, "`meta.json` — shard count, hash
function, entry count," "terms are normalised, hashed, and the low bits select a
shard," and "each shard maps term → postings of `(kind, id, displayName, weight)`" are
encoded verbatim. §6 lists exactly what is indexed — "verified contract names, token
names and symbols, curated labels … and the site's own routes" and **not**
transactions/blocks/addresses without names — which is why the corpus is labels + the
chain route, not the entities (those are resolved by §3–§5). §6.2 requires "every name
carries its provenance" and "curated labels outrank self-declared names," so each
posting carries `provenance` and the weight reflects it (the §8 `curatedProvenance`
term). The exact byte layout is unspecified; the simple self-describing encoding here
is a faithful demo stand-in for the packed production format, swappable behind the
`searchidx.nim` seam.

### D6 — Entry pages, and the root's enumeration of the render + idx layers

**Decision.** Each entity gets a pre-rendered HTML file at its route
(`/{chain}/tx/{txHash}/index.html`, `…/block/{blockHash}/…`, `…/address/{address}/…`,
and `/index.html` for home). Every page carries `<title>`, `<meta description>`,
`<link rel="canonical">`, a `<meta robots>` policy, a semantic `<main>` summary, and
the entity's data **inlined** in a `<script type="application/json" id="bt-data">`
island with `<`, `>`, `&` escaped. Ordinary entities are `noindex,follow` (class N1);
the home page is `index,follow` (class I0). The sealed generation root **enumerates
these optional layers**: `root.render` (present ⇒ entry pages required and complete)
and `root.idx` (present ⇒ the search indices required, with `hash.prefixLen`/`version`
and the `names` meta path). A tree that omits both is still a valid data plane.

**Spec basis.** Static-Site-Architecture §2 fixes the routes
(`/{chain}/tx/{txHash}` etc. — "entry page — metadata + inlined data") and §3.1/§4 the
"one request to first paint … the entity's data is inlined into its own entry page …
a materialised view of one of them, not a second source of truth." Rendering-And-
Delivery §4.2 fixes the page's contents (the metadata block and the escaped
`#bt-data` island); the validator's "inlined data == /d object" check enforces the
"materialised view, not a second source of truth" property directly. SEO-And-Crawl-
Budget §5 fixes the robots classes: N1 "ordinary transactions, blocks and addresses →
`noindex,follow`," I0 "home, docs, chains → `index,follow`" — and note that `noindex`
"governs `<meta robots>`, not whether the page exists," which is why every N1 entity is
still fully pre-rendered. Enumerating the layers in the root follows the §2.9 registry,
where `/idx/**` is marked "in root" and entry pages are `release`-class route objects;
making the root name them is the additive, defensible way to let one sealed object
describe a whole generation's layers, consistent with D3's `maps` reasoning. The
`index.html` clean-URL convention (a directory index per route) is the standard static-
host mapping of the extensionless spec routes and is future-compatible with the
`/{chain}/tx/{hash}/debug` sub-route (Page-Descriptions §1).

### D7 — Real `noir_space_ship` traces: vendored, with source published separately

**Decision.** The demo generator packages a **real CTFS container recorded by
`nargo trace`** from `codetracer/test-programs/noir_space_ship` (Noir tracer fork
`codetracer` @ `906af2f42d`, nargo `1.0.0-beta.26`). It is **checked into the
repository** at `fixtures/trace/noir_space_ship/zk_shields.ct` and copied verbatim
into every published `ready`/`divergent` artifact, rather than recorded at
generation time. The Noir sources are published as content-addressed **source
bundles** at `/src/{chain}/{codeHash}/{bundleHash}.json` with a `current.json`
pointer, and each manifest's `sourceBundles` names the bundle it recommends.

**Why vendored rather than regenerated.** `nargo trace` is **not byte-deterministic**:
two runs of the same program at the same commit differ in exactly 20 bytes, a UUIDv7
recording id stamped into the container's `CTMD` (meta.dat) block. The rest of the
container — the whole trace body, all 1315 steps and 80 calls — is byte-identical,
and the embedded `workdir` string additionally varies with where the recorder ran.
M5c requires that the same seed produce byte-identical `.ct` containers so the demo
tree is a usable regression fixture, and a generator that shelled out to `nargo trace`
could not satisfy that. Checking the bytes in is what makes the requirement
achievable; re-recording is a deliberate act, documented in
`fixtures/trace/noir_space_ship/README.md`.

**Why source is a separate object.** `ct-print --full` reports `source_views: []`
for this container: CTFS interns *path names* and line/column positions but carries
**no source text**. A viewer given only `trace.ct` can step and show variables but
cannot show code — which would pass every manifest check and still fail as a demo.
Trace-Artifacts §2.5 and Source-Resolution §5 already specify the right shape
(source referenced, not embedded; one bundle per code hash, immutable, with a moving
`current.json` pointer), so the generator publishes that rather than inlining source
into the artifact directory. The bundle's `sources` keys are exactly the paths the
container interns (`src/main.nr`, `src/shield.nr`), which is what lets a step's
position resolve to a line of code. `std/lib.nr` is the Noir standard library and is
legitimately absent.

**Bundle filenames carry the full hash.** The object is named
`{sourceBundleId with only its algorithm tag stripped}.json`. A consumer reaching a
bundle through a manifest's `sourceBundles` has no pointer to read and must
reconstruct the path from the id alone; `blocktracer_client/paths.nim`'s
`shortBundleHash` therefore strips the `sha1:`/`blake3:` tag **and nothing else**.
Truncating the hash in the filename would publish a bundle that only the
`current.json` route could ever find.

**What the packaged trace contains** (`ct-print --summary`): 1315 steps, 80 calls,
1315 values, 70 IO events, 3 paths, 6 functions, 8 types, 22 varnames; maximum call
depth 3; 147456 bytes (144 KiB). Commit `906af2f42d` ("record compound assignments
and while/loop bodies") is load-bearing for this program: `shield.nr` drives its
simulation through `remaining_shield -= damage` inside a `for` loop, and the
container records 29 distinct `remaining_shield` transitions, so the fix is
observable in the bytes rather than merely claimed.
