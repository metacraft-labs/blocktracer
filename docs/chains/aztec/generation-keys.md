# Generation-qualified publish keys — design note

**Status: design note, nothing implemented.** Open item (4) from
[`README.md`](README.md). Written because Aztec restarts from genesis on upgrade
(see [`../../AZTEC-NETWORK-GENERATIONS.md`](../../AZTEC-NETWORK-GENERATIONS.md))
and the only way to publish the new chain under the canonical slug today is to
discard the old corpus.

## The finding that makes this cheap: the keys already exist

I expected to propose a new key layout. **The layout is already
generation-addressed.** Measured in `src/blocktracer/chain/ingest.nim`:

```
d/<slug>/current.json              the ONLY mutable object — names a generation
d/<slug>/g/<gen>/root.json         ingest.nim:3721
d/<slug>/g/<gen>/summary.json      ingest.nim:3470
d/<slug>/g/<gen>/height/0.json     ingest.nim:3404
d/<slug>/g/<gen>/blocks/0.json     ingest.nim:3409
registry/chains.v<N>.json          ingest.nim:1678 — per-chain rows
```

`current.json` carries `{chain, generation, traceSelectionVersion, head,
finalized}`. Live right now: `aztec` → `raztec00001`, `aztec-testnet` →
`rtestnet0001`. Generations are immutable and **a superseded one keeps answering**
— `publisher.nim`'s own words about the 2026-10-14 incident: "generation
`raztec00001` still answers 200 — but the pointer stopped naming it."

**So nothing needs a new path.** What is missing is smaller and sharper.

## What is actually missing

**A generation is numbered, not identified.** `raztec00001` means "the first
generation published under the slug `aztec`". It does not say *which deployment's
data it holds*. Two rollups under one slug therefore produce generation 1 and
generation 2 of the same slug, indistinguishable by key, and the only mechanism we
have for the transition is `replace-chain-row` — drop the chain's registry row so
the publisher treats the chain as first go-live and builds a fresh generation over
the old one.

`publisher.nim` states the hazard in the same breath: "every path from here either
resumes that chain or REPLACES it, and it no longer knows which it would be doing."
That sentence is about an unreadable pointer. The same ambiguity exists, silently,
when the pointer is perfectly readable and the *chain underneath it* changed.

Three consequences we have actually hit:

1. **Height stops ordering the data.** Published v5 heads are 102,690 / 99,092;
   live v6 tips were 60,712 / 69,632 — below them. Any "highest block" comparison
   across the boundary picks the dead chain.
2. **Retirement cannot be expressed.** `retired-networks.json` is keyed on the
   slug, so it cannot say "generation 1 is gone, generation 2 is live" about one
   name. That is why reusing the slug forced the file to be emptied of both Aztec
   entries — see `retired_networks.nim`'s header.
3. **The old corpus is discarded rather than kept.** It is still in the bucket and
   still answers; only the pointer forgot it.

## Corroboration: Aztec's own body store is already keyed this way

Observed 2026-11-27 in a running ingest's body-proxy line, which is the strongest
argument available that this design is not an invention:

```
bodies from https://aztec-labs-snapshots.com/testnet/txs/
            aztec-11155111-679261766-0x1f435a7f2da358caf887a470faeee7d5d5f4efba/txs/
```

That path segment is `<network>-<l1ChainId>-<rollupVersion>-<rollupAddress>`.
**Upstream addresses per-deployment data by exactly the triple this note proposes
deriving the generation token from** — and it had to, for the same reason: a
redeployment restarts heights, so a key that is only a network name collides with
itself.

So the proposal is not a new convention. It is making our published keys agree
with how the data's own source already addresses it.

## Proposal

**Bind the generation to the deployment, and key durability on the generation.**

1. **Name generations by identity, not by a counter.** Every capture already
   stamps `provenance.rollupVersion` and `provenance.rollupAddress`. Derive the
   generation token from those (a short hash of the pair), so `raztec00001`
   becomes something like `aztec-g-<8 hex of rollupAddress+rollupVersion>`. A new
   deployment then *cannot* collide with the previous one, and the token says what
   it holds. Keep the existing tokens valid — see migration.
2. **`current.json` gains the identity it points at.** Add
   `rollup: {address, version}` beside `generation`. The pointer then states which
   deployment is current, so a reader — the site, `check-chain-compat`, a human —
   can tell a resumed chain from a replaced one without consulting the registry.
3. **The registry row gains a generation list.** `registry/chains.v<N>.json`'s
   per-chain row carries `generations: [{token, rollup, firstHeight, lastHeight,
   retired?}]`. This is where `replace-chain-row` stops being necessary: opening a
   new generation is an *append*, not a row deletion.
4. **Retirement moves off the slug.** `retired-networks.json` keys on
   `(slug, generation)`, which lets a page say "this execution's chain no longer
   exists" about v5 rows while v6 rows under the same slug stay repairable. This
   is what the file has been trying to express with the wrong key all along.
5. **Refusals keep their teeth.** `snapshot-from-ingest.mjs`'s "two rollups must
   not merge into one chain directory" stays. What changes is the *remedy* it
   suggests: "open a new generation", not "publish under a slug of its own".

## Where each key is read — the work, by site

| reader | file | change |
|---|---|---|
| ingest / publish | `chain/ingest.nim` (`d/<slug>/g/<gen>/…`, `current.json`) | generation token derived from provenance rather than a counter; write `rollup` into `current.json` |
| publisher's resume logic | `publish/publisher.nim` `syncState` | `present: false` is no longer the only "new generation" path — an identity change is a second, *named* one |
| registry | `chain/ingest.nim:1678` + the recorder-pin guard | per-chain `generations` array; `replace-chain-row` retired |
| follow-chain's publish | `tools/chain/follow-chain.mjs`, `snapshot-from-ingest.mjs` | pass the capture's rollup identity through to the publisher instead of only refusing on mismatch |
| durability | `chain/retired_networks.nim`, `tools/chain/retired-networks.json` | key on `(slug, generation)`; the build-time gate against `chain-identity.json` becomes per-generation |
| the site | `client/src/{ssr,reader,viewutil,viewmodel}.nim` | resolve `slug → current.json → generation` as now; **plus** a route that names a generation explicitly, so a v5 permalink keeps working |
| compat check | `tools/chain/check-chain-compat.mjs`, `chain-identity.json` | one entry per generation rather than per chain |

## Migration for the rows already published

The v5 data is **not lost** and needs no rewrite — generations are immutable and
still answer:

1. **Leave `raztec00001` / `rtestnet0001` exactly where they are.** Register them
   in the new `generations` array with their *measured* v5 identity
   (`aztec-testnet`: rollupVersion 1821665230, rollupAddress `0xd73a91bd…`, heights
   1..99,092) and mark them retired — which is the first honest statement about
   them the system has been able to make.
2. **Open v6 as a second generation**, derived from the live identity
   (`679261766` / `0x1f435a7f…`, `2070860440` / `0xe37a2663…`), and flip
   `current.json` to it. No deletion, no `replace-chain-row`.
3. **Keep the numeric tokens working.** The token only has to be unique and
   stable; the existing two are both. Derive *new* tokens from identity and leave
   the old ones as-is rather than rewriting objects nobody can recapture.
4. **A v5 permalink keeps resolving** because the objects are untouched; it needs
   only the generation-explicit route from the table above.

## What it costs, honestly

- **Small:** the key layout, which already exists. No object moves, no re-upload,
  no data loss.
- **Medium:** the registry shape (a data-contract change — `chains.v<N>`'s `N`
  exists for this), the publisher's resume logic gaining a second named path, and
  the site's generation-explicit route.
- **The real cost is `retired-networks.json`'s key.** It is `staticRead` by Nim,
  drives page wording through `absenceKind`, and its current shape is asserted by
  `test_chain_provenance`'s retired-upstream suite plus two cross-registry gates I
  added on 2026-11-26. Changing its key means re-deriving all of that. Worth it:
  it is the change that lets a page tell a dead generation from a live one under
  one name, which is the thing it cannot say today.
- **Not needed for the current blocker.** The service publishes nothing because
  every replay crashes; this design changes nothing about that. It should be
  scheduled *after* traces flow, or it will be built against a corpus of zero rows.

## What I would not do

- **Do not put the generation in the visitor's URL by default.** `/<slug>/tx/<hash>`
  should keep resolving through `current.json`. Only an explicit historical route
  needs the token.
- **Do not renumber or rewrite the existing generations.** They are immutable, they
  answer, and the bodies behind them are pruned — they cannot be recaptured.
- **Do not key on a date or an upgrade name.** `AZUP-3` and "v6" are upstream's
  vocabulary and do not survive a testnet that reset more than once inside one
  upgrade (rc.3 at rollupVersion 3409706519, then 679261766). The rollup identity
  is the only thing that distinguished those.
