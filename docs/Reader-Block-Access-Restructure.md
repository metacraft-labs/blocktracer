# Owed: the reader's block-access surface should be indexed, not scanned

**Status:** measured, designed, not started. Written up so it is scheduled on its
merits rather than rediscovered.

## What is wrong

Every block-access helper in `client/src/reader.nim` is a linear walk over a
materialised list of the generation's blocks:

| helper | call sites | what it does |
|---|---|---|
| `blockRefsNewestFirst` | 12 | builds and sorts a `seq[BlockRef]` of every block |
| `blockHashes` | 8 | walks that list to collect hashes |
| `highestIndexedHeight` | 4 | walks that list to find a maximum |
| `canonicalBlockAt` | — | walked that list to match one height (now indexed) |

`blockHashes` and `highestIndexedHeight` are themselves scans built on the first,
so the cost compounds. A page render reaches several of them.

**This is correct for the consumer it was written for.** A client renders one
page and walks the chain once; the list is the simplest thing that works and the
header's claim — "ordering a chain's blocks costs O(epochs) *reads* instead of
O(blocks)" — is true, because reads were the cost that mattered *there*. An
exporter renders 288,046 pages and pays the walk every time. Same code, same
correctness, different consumer: the locality class in
`Replay-Toolchain-Artifacts.md`.

## What has been done, and why it is not enough

Three fixes landed, each measured, each honest about its limit:

| change | 1,000 | 10,000 | 50,000 |
|---|---|---|---|
| original | 3.02 ms/page | ~110 | did not finish |
| `HashSet` for the dedup (removed 1.05 T comparisons) | 0.82 | 3.93 | — |
| per-generation list memo | 0.84 | 1.15 | 4.18 |
| per-generation height index | **0.48** | **0.74** | **2.64** |

Subtracting the ~0.45 ms floor, the growing term is **0.03 → 0.29 → 2.19**. The
constant has come down roughly 37% and **the shape has not changed**. Each fix
removed one scan and left the others.

**Patching the next call site will do the same again.** That is the argument for
stopping: three more increments that each look like progress is how this becomes
unfixable.

## The shape of the fix

Prepare the index **once per generation** and have the whole family read it,
instead of each helper walking the list:

* one structure per `(store, chain, generation)` carrying the height→hash map,
  the hash set, and the max height — everything the four helpers derive today;
* the helpers become lookups against it;
* it is built where the generation is pinned, so its lifetime is the pin's, and
  a new generation is a new structure rather than an invalidation.

Soundness is the same argument the existing memos use: a generation root is
**sealed**, so nothing derived from it can change while it is current, and a
reorg publishes a new generation and therefore misses by construction.

**It must stay bounded and gated**, like `enableBlockRefMemo` and
`enableHeightIndexMemo` — 64 entries and a refusal that names what to do instead
of raising the bound. Four defects of this class shipped with accurate prose and
nothing that refused; prose is not the defence.

## What it is worth

Roughly **5–6 ms/page** at mainnet's 102,690 blocks on the current extrapolation,
against a floor near 0.45. For a 288,046-page export that is the difference
between about 25 minutes and a few minutes — and, more importantly, it removes a
term that grows with every block the chain adds.

It is **not** a blocker. The export is workable today. This is a quality and
future-scaling change, and it should be scheduled as one.
