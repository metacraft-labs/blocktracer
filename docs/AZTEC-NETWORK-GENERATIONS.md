# Aztec restarts from genesis on upgrade — and what that costs this explorer

**Read this before writing anything that assumes an Aztec chain is one continuous
chain.** It is not. Aztec's upgrade mechanism replaces the rollup contract and
restarts the chain **from genesis**, under the same network name and the same DNS
endpoint. Every assumption that block heights increase forever, that a contract
address means one thing, or that a captured corpus can be extended, is false
across one of these boundaries.

This document exists because the project lost two months to not knowing it, and
then an agent re-derived it from wire evidence a second time instead of reading
it. The upstream facts are cited; our own measurements are marked as ours.

## What upstream says

Aztec `v6.0.0` (release dated **2026-10-22**) is a governance-driven rollup
redeployment — "v6 is the new Aztec rollup deployment proposed in AZUP-3":

- "The new rollup becomes canonical on Mainnet no earlier than **Monday 26
  October 2026, 08:00 UTC**, and Testnet upgrades at the same time."
- The upgrade "comes with a new rollup deployment **from genesis**".
- "**every contract address, account addresses included, differs from v5**", and
  standard contracts are re-pinned.
- **Protocol contracts keep their magic addresses** (`1`, `2`, …).
- A `v6.0.0` node "starts only if the canonical rollup matches" its pinned VK
  root, protocol-contracts hash, genesis archive root, rollup address and rollup
  version. A node binary therefore *implies* a generation.
- For a standby node: "**Use a new, empty data directory.**" Upstream's own
  guidance is that state does not survive the boundary.

The `AZUP-` numbering means this is a standing process, not a one-off. **Assume
it happens again.**

## The identifiers, and ours agree with the release notes

| | rollup address | rollupVersion |
|---|---|---|
| **mainnet v6** (release notes) | `0xE37A2663Cc9c119BA41572C40fAb0bbb23a5402f` | `2070860440` |
| mainnet v6 (our `node_getNodeInfo`, 2026-11-26) | `0xe37a2663cc9c119ba41572c40fab0bbb23a5402f` | `2070860440` |
| testnet v6 (ours, 2026-11-26) | `0x1f435a7f2da358caf887a470faeee7d5d5f4efba` | `679261766` |
| testnet v5 (our frozen capture's provenance) | `0xd73a91bdcf6891c7642f3e460036e1ef2cc23178` | `1821665230` |

**Testnet reset more than once inside the v6 rollout.** Third-party trackers
record a reset on `6.0.0-rc.3` at rollupVersion `3409706519` (2026-10-12), and
testnet now answers `679261766`. So "which v6" is not a single answer either —
only the rollup identity is.

## Five consequences, each tied to something we actually observed

1. **Height does not order the data.** Our published corpora are v5: heads
   **102,690** (mainnet) and **99,092** (testnet). Live v6 tips on 2026-11-26
   were **60,712** and **69,632** — *below* them. Anything that picks "the
   highest block" across a boundary picks the dead chain.

2. **A low height returns a plausible header from the NEW chain**, while a height
   inside the captured range answers `Unknown block` (code 26). This is why the
   break stayed invisible from 2026-09-04 to 2026-11-03: the endpoint answers,
   fluently, about a different chain.

3. **Every third-party artifact mapping is void across the boundary** — upstream
   says every contract address differs. Measured consequence: of 10 distinct
   contract addresses interrogated over 300 live testnet blocks, the nine
   third-party ones resolved **0** artifacts.

4. **FeeJuice resolves because the protocol guarantees it**, not by luck.
   "Protocol contracts keep their magic addresses" is why `0x…0003` was the only
   address of those ten to resolve — 8 of 8 attempts, corroborated by npm and
   Aztecscan. Any source-coverage estimate that does not separate protocol
   contracts from app contracts is measuring the traffic mix, not the capability.

5. **The transaction wire format moved with it.** Every published
   `@aztec/stdlib` refused v6 transactions with "is greater or equal to field
   modulus" until the `@aztec-labs/stdlib` 6.x rename. A decoder pin is therefore
   also generation-scoped.

## What we already have, and the gap

Three mechanisms in this repo exist for this hazard:

- `provenance.rollupVersion` / `rollupAddress` on every capture — the generation
  stamp, already written.
- `tools/chain/chain-identity.json` — what we last verified we can decode, and
  against which deployment. `check-chain-compat.mjs` compares a live node to it
  and refuses on a mismatch.
- `tools/chain/snapshot-from-ingest.mjs` refuses to write a live snapshot into a
  directory whose existing snapshot holds a different rollup: "two rollups must
  not merge into one chain directory."

**The gap is the published slug.** `aztec` and `aztec-testnet` name a *network*,
not a *generation*, so v5 and v6 data compete for one namespace — and the only
way to publish v6 under those slugs today is to discard the v5 corpus
(`replace-chain-row`). That is a lossy answer to a problem that will recur.

`tools/chain/retired-networks.json` is the obituary half, but it is keyed on the
slug too, so it cannot say "this generation is gone, that one is live" about one
name. See `src/blocktracer/chain/retired_networks.nim`'s header for why a reused
slug had to empty it.

## What other projects do (no formal standard found)

A survey of explorers and testnet tooling found **no documented convention**.
The recurring patterns are:

- **Key the dataset by genesis.** Ephemeral-testnet specs treat each reset as a
  new genesis with the prior chain's data, state and ancient database discarded.
- **Re-index from the new genesis** rather than extend (btq-core).
- **Scope storage and URLs by network *and* genesis**, and read genesis time from
  the node rather than hardcoding it (logos-blockchain UI).
- **Offer a per-era cache reset, not a global one.** A logos explorer issue shows
  the failure mode of getting this wrong: a stale index from an older version
  stopped the indexer, and the banner blamed storage instead.
- **Show the active era explicitly in the UI.**

## The direction this points

Make the generation a first-class key rather than a thing the slug has to hide:

1. A chain is `(network, generation)`. The generation is derived from
   `rollupAddress` + `rollupVersion` — both already captured — not from a date or
   a counter someone maintains.
2. Publish under a generation-qualified key, with the bare network name
   resolving to the current generation. A visitor's URL need not change; the
   *storage* key stops colliding.
3. Durability becomes a property of the generation, not the slug — which is what
   `retired-networks.json` has been trying to express with the wrong key all
   along.
4. Keep the refusals. A follower that finds a different rollup under its slug
   must still stop rather than merge; a generation key makes the right next step
   "open the new generation" instead of "discard the old corpus".

Sources: Aztec `v6.0.0` release notes (new rollup deployment, AZUP-3,
canonicalisation timing, address changes, protocol-contract magic addresses, new
empty data directory); third-party reset trackers for the rc.3 rollup version and
the republished standard contracts; ephemeral-testnet specs, btq-core and
logos-blockchain explorer issues for the explorer patterns.
