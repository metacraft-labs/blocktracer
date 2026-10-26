# What blocktracer.org actually serves, measured

Everything here was read from the live apex over HTTPS on **2026-10-27** with a
cache-busting query, because an edge can ignore a no-cache request. Every
number is a fetched byte count or a field out of a fetched object; nothing in
this file is inferred from the repository.

The apex is served from the **`blocktracer` R2 bucket**, which only
`publish-r2.yml` writes. A Cloudflare Pages deploy of `live` updates
`blocktracer.pages.dev` and does not touch blocktracer.org —
`deploy-cloudflare-pages.yml`'s header says the opposite and is wrong.

## 1. The pointer each chain serves

| chain | generation | head | finalized |
|---|---|---|---|
| `aztec` | `1` | 68,231 | 68,231 |
| `aztec-testnet` | `1` | 63,675 | 63,675 |
| `aztec-testnet-frames` | `1` | 69,361 | 69,347 |
| `demo` | *(fixture)* | — | — |

## 2. The generation each pointer names, against the one it stopped naming

Both generations are still in the bucket and both answer 200. Only the
`current.json` pointer moved.

| chain | generation | blocks | transactions | traces published | window | scope |
|---|---|---|---|---|---|---|
| `aztec` | **`1`** *(served)* | 170 | 2 | **2** | 68,062–68,231 | curated |
| `aztec` | `raztec00001` | **102,690** | **60,846** | 0 | 1–102,690 | full |
| `aztec-testnet` | **`1`** *(served)* | 34 | 6 | 6 | 63,642–63,675 | curated |
| `aztec-testnet` | `rtestnet0001` | **99,092** | **25,421** | **18,087** | 1–99,092 | full |
| `aztec-testnet-frames` | **`1`** *(served)* | 15 | 5 | 5 | 69,347–69,361 | curated |

`aztec-testnet-frames` has no second generation; generation `1` is all there
has ever been for it.

The size difference is visible without reading a counter:
`d/aztec/g/raztec00001/height/0.json` is **8,514,911 bytes** and
`d/aztec/g/1/height/0.json` is **14,166 bytes**.

## 3. How the pointer moved, and why nothing noticed

Run 38524448139 on 2026-10-14 logged `resumed-from generation: (none)` for
chains that plainly had a generation, built a fresh generation `1`, and flipped
the pointer to it.

`readSyncState` could not tell three causes apart — the key is absent, the read
failed, the bytes did not parse — and reported all three as `present: false`,
which `publishChain` reads as "first go-live". `publish/objectstore.nim`'s
`FetchOutcome` now gives them three names and `readSyncState` raises for the
two that are not absence; `tests/tpublish.nim`'s last suite is the regression,
mutation bite included.

`assertRegistryKeepsKnownChains` did not see it because it compares chain
NAMES, never pointer contents, and all four names survived.

## 4. Restoring the old generation is not a straight win, and for one chain it is a loss

The obvious repair — point `current.json` back at the old generation — is
only obviously right for one of the two chains that has one.

* **`aztec-testnet`: `rtestnet0001` is better on every axis.** 99,092 blocks
  against 34, 25,421 transactions against 6, and 18,087 published traces
  against 6. There is no axis on which the served generation wins.

* **`aztec`: it is a trade, and the current generation holds the debuggable
  half.** `raztec00001` carries 102,690 blocks and 60,846 transactions and
  **zero** published traces — its refusal ledger is `not-first-in-block`
  36,237 plus `not-attempted` 24,609, accounting for all 60,846. Generation
  `1` carries 170 blocks and the only two traced transactions this chain has
  ever published. Flipping back would restore the history and remove the
  debugger.

So the repair that is actually wanted is a generation that is the UNION:
the full block range with the traces carried over. That is an ingest, not a
pointer write, and it is not something `publish-r2.yml` can do — that workflow
pins the live pointer rather than choosing one (`Pin the live chain pointers`,
and the comment above it records measuring this exact regression in the other
direction).

Whether `rtestnet0001`'s 18,087 containers are in the compact-CTFS/brotli
encoding this repository now publishes is NOT established here. They were
captured 2026-09-28, before that encoding landed, so the question has to be
asked of a container rather than assumed either way.

## 5. The served data plane is this repository's own fixture tree

Measured by hashing `client/dist` against the apex, after an ordinary export:

* `d/<chain>/current.json` — **byte-identical** for `aztec`, `aztec-testnet`,
  `aztec-testnet-frames` and `demo`.
* `d/<chain>/g/1/root.json`, `.../height/0.json`, `.../blocks/0.json` —
  byte-identical for all three Aztec chains.
* `d/<chain>/g/1/summary.json` — differs by exactly one additive field,
  `"tracesAtSourceLevel": 0`, which the tree emits and the bucket predates.
* `idx/hash/meta.json` — 87 shards / 288 entries on both sides.
* `registry/chains.v1.json` — the same four chain names on both sides.

**This is why a publish of this tree does not need `render-over-live`.** That
mode exists to render pages against a live data plane the build does not carry;
here the build carries it byte for byte. Staging it costs 460,813 objects —
3.2 hours in run 40312450881, which then died in `t/` and discarded all of it —
to render over data the build already has.

What the publish DOES need is `refresh: true`. Entry pages are `ocEntryPage`,
whose strategy is `stKeyExistence`: the bucket already holds every
`<chain>/tx/<hash>/index.html` key, so without `--refresh` the publisher skips
all of them and only the shared site objects move. Run 38995672069 is the
worked example — green, and every debug page still serving the old bytes.

This equivalence is a property of the moment, not a rule. It holds only while
the pointer names a generation this repository's fixtures produce. Re-measure
§5 before leaning on it again.
