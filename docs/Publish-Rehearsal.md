# The publish rehearsal — coverage, not volume

`blocktracer-rehearse` answers one question before a deploy: **would publishing
this tree to an object store work, in every way it can fail?**

`blocktracer-validate` asks whether a tree is well formed.
`blocktracer-client-conformance` asks whether a consumer can read it. Neither
asks the question above, because it is a property of the tree *and the store
together*, and until now it was answered by publishing the whole thing and
watching.

## Why the whole thing does not scale, and why "smaller" is not the fix

Aztec is the first chain and a small one. A dress rehearsal of the tree a large
chain produces is not something anybody runs before a deploy, and a rehearsal
nobody runs defends nothing.

The obvious answer — run a smaller one — fails for a reason that was **measured
on 2026-09-28** rather than argued:

| rehearsal | objects | verdict |
| --------- | ------- | ------- |
| demo tree | 290 | passed |
| full tree, both chains | 460,589 | **found a data-loss defect** |

The difference was not the 460,299 objects. It was that the small one had **one
chain**, and one chain cannot overwrite another chain's registry row. The defect
needed **cardinality ≥ 2**. No amount of scale on one chain would ever have
reached it, and no amount of scale on one chain ever will.

So the flag that matters is not how big. It is **what is covered**.

## The coverage contract

`src/blocktracer/rehearse/coverage.nim` holds it, with the property each cell
defends. Everything derivable is derived, because a hand-written list is a
second source of truth that goes stale exactly when a new case is added.

| dimension | cells | derived from |
| --------- | ----- | ------------ |
| `class` | one per object class | iterating `publisher.ObjClass` — a class added to `classOf` becomes a required cell with nobody remembering |
| `strategy` | one per upload strategy | iterating `publisher.Strategy` |
| `cardinality` | 5 | every singleton a second instance could clobber: two chains **in separate trees**, two chains in the store, two generations, two index shards, two address ranges |
| `branch` | 12 | **both sides** of every conditional on the publish path |
| `invariant` | 6 | the whole-system properties, each in **both directions** |

**An unexercised cell is a failure, not a percentage.** The report is a table of
what was exercised *and the witness that exercised it*, because `97% covered` is
a claim about a denominator nobody has seen and
`class/ocTraceContainer  A4: t/bu/mz/…/trace.ct` is a claim somebody can check.

### Both sides of every conditional

`lease` acquired / refused · `key-existence` miss / hit · `content-hash` equal /
differing (a determinism incident, §2.8a) · `refresh` unchanged / superseded ·
`flip` halted / completed · `bulk-confirm` satisfied / refused.

A conditional exercised on one side only is a conditional whose other side has
never run in this configuration, which is where an impedance mismatch lives.

### Both directions of every invariant

`global-pointer-no-chain-loss` is required to **refuse** a single-chain tree over
a two-chain store *and* to **accept** a legitimate whole-site tree. The second
half is the one nobody writes, and it is the more expensive failure: a guard that
refuses the good path stops the pipeline, and did so twice on 2026-09-28.

### The invariants are stated over outcomes, not over procedure names

The contract deliberately does not name `assertRegistryKeepsKnownChains` or
`assertNoUnknownGlobalPointer`. Those are one implementation of one of these
invariants, they are **not on `dev`** at the time of writing, and a contract that
named them would measure nothing on a tree published by anything else. What must
be true is a property of the *store* after a sequence of publishes: no global
object may stop naming a chain the store still holds data for. A publisher that
refuses such a tree satisfies it; one that merges correctly satisfies it; one
that writes and loses a row does not.

## Partial selection

`--mode partial` buckets the corpus by the things the publish path branches on —
`(class, family, chain, generation)` — and takes a fixed number from each,
**spread** across that bucket's keys sorted by their last path element, so the
two extremes are always in. For `seg/` the last element is the block range, so
this guarantees the lowest and the highest range are both selected.

The bucket set is `O(classes × families × chains × generations)`, which does not
grow with the chain, and the per-bucket count is a constant. A partial tree is
therefore **bounded**, independently of whether the chain has 74 thousand blocks
or 74 million.

Never sampled and always taken: `current.json` (it *is* the flip),
`registry/**`, the site-root pointers, `idx/**/meta.json`, and each generation's
`root.json`. There are `O(chains + generations + index shards)` of them and they
are the objects whose write order is load-bearing.

A partial tree is deliberately **not referentially closed** — a generation root
names maps that were sampled away. That is correct here: the publisher never
dereferences an object it uploads, so a dangling reference cannot change any
decision it makes. A consumer reading such a tree would break, which is a
different tool's question about a different artefact.

## Derivations

Two cardinality cells cannot be satisfied by a corpus that does not already have
the shape. `--derive` (default on) constructs them and **labels them as
constructed** in the witness column, so a cell met by a construction never reads
like one met by the operator's own corpus:

* **a second chain, in a separate tree**, re-keyed from the first, with a
  registry naming only itself — which is exactly the input that lost data.
* **a second generation**, copied, with `current.json` moved onto it.

`--derive none` turns them off. That is how an operator asks *is my real corpus
sufficient on its own?* and gets a refusal naming exactly what it lacks.

**What the chain derivation cannot construct, stated rather than hidden:**
`idx/hash/{version}/**` is built over every chain at once, and the derivation
can move keys but cannot rebuild a binary index, so it copies those shards
byte-for-byte. The invariant is therefore **vacuous over `idx/hash/**` when the
second chain is derived**. It is not vacuous over the registry, which the
derivation does reduce to one chain, and that is the object the measured defect
was in. A corpus of two real trees (`--tree a --tree b`) makes the whole
invariant non-vacuous.

## Measured evidence

All on `origin/dev` 81e1886, 2026-09-29.

**The claim that partial suffices**, checked as a *set equality* between modes
rather than a count — two runs can meet the same number of cells and meet
different ones (`tests/trehearse.nim`, "partial mode meets THE SAME cells").

**A 106-object partial rehearsal (12%) of the real 878-object publish tree**
(`client/dist`) met **36/36** cells and found **two defects**:

1. `invariant/global-pointer-no-chain-loss` — the 2026-09-28 registry clobber,
   still live on `dev`. Also reproduced from a **54-object** partial rehearsal of
   the 310-object demo tree. The full-scale run that first found it used 460,589
   objects.

2. `invariant/every-object-is-published` — **8 objects of the publish tree are
   uploaded by nothing**, with exit code 0 and no warning. Confirmed
   independently by subtracting a `blocktracer-publish --backend local` store
   from the tree:

   ```
   404.html
   about/index.html
   chains/index.html
   replay-engine/pkg/db_backend_bg.wasm
   replay-engine/pkg/db_backend.js
   replay-engine/worker.js
   search/index.html
   settings/index.html
   ```

   `publishChain`'s `belongs` predicate admits a key for a chain if it is under
   `d/{chain}/`, `src/{chain}/`, `{chain}/`, or in the chain-agnostic set —
   `t/`, `idx/`, `assets/`, `registry/`, and the three site-root names
   `index.html`, `sitemap.xml`, `robots.txt`. A static page outside those is
   admitted for **no** chain. Note what is in that list: `/replay-engine/*`,
   whose absence from the publish tree is *the first of the two production
   breakages `tools/deploy/check-assets.mjs` was written about*. Serving the
   site from the object store would reintroduce it.

### What partial finds, and what it does not — measured, not assumed

Run in **both** modes over the same 878-object tree:

| | objects | cells met | registry clobber | unpublished objects |
| --- | --- | --- | --- | --- |
| `--mode partial` | 106 (12%) | 36/36 | found | **7 of 8** named |
| `--mode full` | 878 (100%), 3.7 s | 36/36 | found | **8 of 8** named |

Partial found the *defect* and enumerated seven of the eight objects; full
enumerated all eight. That is the honest shape of the claim and the reason both
modes exist: **partial is sufficient to decide whether to ship, and full is what
you run to get the list.** A partial rehearsal that reported "7 objects" as if it
were the total would be worse than no rehearsal, so the finding says "7 object(s)
in the corpus", counted over what was rehearsed, and the selection percentage is
printed directly above it.

**Deliberately broken corpora it refuses**, each asserted by name in
`tests/trehearse.nim`: two trees whose registries each name only their own chain;
a tree carrying an object no cycle publishes; a corpus emitting no object of a
class; a one-chain corpus under `--derive none`. Each paired with a control that
is clean, so the refusal is not vacuous.

## The known-findings register

`tools/rehearse/known-findings.json`, modelled on
`tools/journeys/known-survivors.json`. **It fails in both directions**: a listed
finding that occurs is reported and does not fail; one that is not listed fails;
and a listed finding that **stops** occurring fails, demanding the entry be
deleted. An entry cannot outlive the defect it records — the run that fixes the
defect is the run that goes red asking for the entry to go.

An entry is only legitimate with all six fields (`reason`, `cause`, `subject`,
`closed_by`, `evidence`, `recorded`); the register is refused otherwise rather
than read around.

The register is tied to a **corpus** — every entry is about the tree
`just rehearse` runs over. `just rehearse-tree` takes no register for that
reason: an entry is evidence about a specific measurement, not a global list of
things that are allowed to be wrong.

## Commands

```
just rehearse                                   # the gate: demo corpus + register
just rehearse full                              # same corpus, every object
just rehearse-tree --tree client/dist           # the bytes about to ship
just rehearse-tree --tree a --tree b --mode full --no-derive
just rehearse-selftest                          # does the gate bite?
```

Exit `0` met and clean · `1` coverage not met or a finding · `2` usage.

It reaches no network, takes no credential, and cannot be aimed at production:
every store it writes to is a directory it created under `--work`. Trees are
materialised as hardlink farms and the objects a drill tampers with are unlinked
before they are written, so the operator's tree is never modified — asserted in
`tests/trehearse.nim`, "the drill never writes to the operator's tree".

Whether a **published** tree is complete is a different question about a
different artefact.
