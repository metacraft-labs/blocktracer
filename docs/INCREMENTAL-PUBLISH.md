# Publishing a new block shortly after it appears

**Status:** a measurement and a design, not an implementation. Nothing in this
file is built. It exists because the operator's goal — "traces from new blocks
are published shortly after they appear on the network" — is reachable up to
object storage today and NOT reachable to the website, and the reason is one
number rather than a vague slowness.

## 1. Where the time actually goes

`infra`'s `services/blocktracer-ingest` already answers the capture half: a
resident follower polls every 60 s and a publisher drains captures to the ingest
bucket every 120 s. So a trace reaches OBJECT STORAGE about two minutes after it
is recorded.

Reaching `blocktracer.org` costs a whole-site publish. Measured on run
41601883265 (the 2026-11-03 dry run, same phases as the real one):

| phase | time |
|---|---|
| stage the live data plane (`d` `idx` `t` `src` `registry`, 497,339 objects) | 79 min |
| **enumerate routes** (385,845 of them) | **993 s — 16.5 min** |
| render those routes | ~99 min |
| upload with `--refresh` (386,502 objects, one `aws` process per object) | hours |

The render is **18 ms a page**. That is the number that matters: for ten new
transactions the pages that change render in under a second. **Nothing about
rendering is slow.** What is slow is enumerating 385,845 routes and re-rendering
all of them to produce the sixty that moved, and then re-reading every object in
the bucket to notice that only sixty changed.

So an incremental publish is not an optimisation of the render. It is the
question: *which routes does a new block invalidate, and can that set be
computed without walking the chain?*

## 2. Why the answer is yes, and what makes it yes

**The list pages are keyed by a block-height cursor and take blocks whole.**
`reader.txsFrom(root, info, fromHeight, size)` walks `blockRefsNewestFirst` from
`fromHeight` downward and stops at `TxPageSize = 25`, whose own comment says why
the cursor is a block number: "splitting a block across two pages would make the
cursor — a block number — ambiguous about which half it meant".

That is the property the whole design rests on. A page whose cursor is height H
is defined by the blocks at H and below, and those are immutable once settled.
**Appending a block at the tip therefore changes no existing list page.** It adds
a new head page and leaves every older one byte-identical. Contrast an
offset-paginated list, where inserting at the head shifts every page and the
invalidation set is the whole site — in which case this design would be
impossible and the honest answer would be "re-render everything".

## 3. The invalidation set for one new block

Derived from the route kinds the exporter names (`home, chains, chain, blocks,
block, txs, tx, debug, address, code, search, about`):

| route | why it changes |
|---|---|
| `/{chain}/tx/{hash}` and `/{chain}/tx/{hash}/debug` | new |
| `/{chain}/block/{hash}` | new |
| `/{chain}/txs` and `/{chain}/blocks` — **head page only** | the head cursor moves; older cursors do not |
| `/{chain}/address/{addr}` for each address the block touches | the newest segment grows |
| `/{chain}` and `/` | head height and counts |
| `idx/hash/**` shards for the new hashes | new entries |
| `d/{chain}/current.json` | the pointer, written last |

Everything else in the 385,845 is unchanged by construction, and that is a claim
a check can enforce rather than a hope — see §5.

## 4. What this does not solve

* **Reorgs.** Every statement above assumes a settled block. A displaced block
  invalidates pages below the tip, which is ING-2's problem and is not solved
  here. The safe interim rule is to publish incrementally only at or below the
  finalized tip, and to fall back to a full pass when the node reports a
  divergence.
* **The `--refresh` cost.** An incremental publish should not need `--refresh` at
  all: the new keys do not exist, so `stKeyExistence` uploads them and skips
  nothing that matters. `--refresh` exists for the case where bytes changed under
  an existing key, which is the whole-site re-render case. Dropping it is what
  removes the hours.
* **The 79-minute stage.** An incremental publish still has to read enough of the
  live data plane to render the pages it is changing. Staging `d/` whole is
  460,813 objects; staging only the chain and shards involved is the obvious
  narrowing and is unmeasured.

## 5. The check that has to come with it

This repository has been bitten twice this month by a publish that was green and
wrong, so the design is not complete without the gate that would catch its
failure mode.

The failure mode of an incremental publish is a **stale neighbour**: a list page
or an index shard that names a transaction whose page was not written, or a page
that names a container that was never uploaded. The second half already has a
gate as of 2026-11-03 — `publish-r2`'s "every published recording is named by its
own page", which resolves each named container against the tree or the staged
bucket. The first half does not, and the shape it needs is the mirror of it:

> every hash the index resolves, and every row a list page draws, has a page in
> this tree or in the bucket

stated over the incremental set rather than the whole site, and refusing to pass
over an empty set — the rule `tools/journeys/README.md` spells out as "a test
whose subject can be empty passes vacuously".

## 6. The sequence this implies

1. Narrow the staging to the chain being published (unmeasured, probably the
   largest single win after the enumeration).
2. Teach the exporter to render a named route set instead of enumerating one,
   taking the set from the follower's observation records — which already carry
   the transaction hashes and the three block tags.
3. Add the stale-neighbour gate of §5 before the first incremental publish, not
   after.
4. Keep the whole-site pass as the thing that runs on a design change, a
   reorg, or a `--refresh`, because that is what it is good at.
