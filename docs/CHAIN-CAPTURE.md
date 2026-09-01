# Capturing real chain data

How the `/aztec` and `/aztec-testnet` snapshots were made, why they are frozen,
and the one constraint that shapes everything downstream of them.

---

## 1. The constraint: chain history cannot be reconstructed

**A replay can only be recorded while the transaction's body is still served.
Once it prunes, that transaction can never be replayed again — by us or by
anyone.** This is not a cost problem or a tooling gap. It is permanent, and it
was established by measurement rather than assumed:

* **`getTxByHash` is a mempool query, not an archive query.** It reads the live
  transaction pool, and on finalization the body is hard-deleted
  (`handleFinalizedL2Blocks` → `deleteFinalizedTxs`). Across every RPC schema
  upstream, exactly four methods return a `Tx` and all four read that same pool.
  `getTxEffect` reads the archive and does *not* prune, which is why a pruned
  transaction stays perfectly visible and stops being replayable.

* **A commercial archive tier does not help.** dRPC is the only commercial
  provider serving Aztec at all, and it already advertises `has_archive: true`
  for both networks at no surcharge — we are *on* the archive tier. It does not
  retain bodies, because bodies are not archival data.

* **L1 is closed too.** Aztec posts EIP-4844 blobs carrying `TxEffect`s only.
  The public calldata and private kernel inputs a replay needs are never
  published; only a hash reaches L1. There is no preimage to recover.

### What this means for the future ingestion layer

The planned ingestion service — the one meant to produce recordings for chain
history — **can only ever be prospective.** It must capture at finalization or
not at all. There is no backfill, no catch-up mode, and no "re-run it over the
last N blocks" recovery: blocks that pass unwatched are gone for replay
purposes, permanently.

Design it as a **continuously running follower** that records inside the
replayable window, not as a batch job over a range. A batch job over history is
not a slow version of the right design; it is a thing that cannot work.

---

## 2. The replayable window is chain-specific

Measured 2026-09-01:

| chain    | block time | window (`tip - finalized`) | wall clock | throughput |
| -------- | ---------- | -------------------------- | ---------- | ---------- |
| mainnet  | ~72 s      | ~26 blocks                 | ~31 min    | ~14 tx/day |
| testnet  | ~21 s      | ~168 blocks                | ~59 min    | ~3,300 tx/day |

Two consequences:

* **Testnet is easy, mainnet is the slow half.** At ~14 transactions a day,
  mainnet arrivals are hours apart and bursty. A long wait there is the expected
  behaviour, not a fault.

  Measured directly during the 2026-09-01 mainnet capture: over **117 minutes
  the follower saw 107 blocks and exactly one carried a transaction** (143
  polls, 1 catch). That is the number that makes a live follower **mandatory
  rather than optional** — combined with §1, a transaction appears about once
  every 36 blocks and is replayable for roughly 26 of them, so anything not
  watching continuously will miss most of the chain permanently. It is also why
  the capture stopped at two mainnet blocks: a third would have been another
  hour or two of waiting for a qualitatively identical single-transaction block.
* **Poll rate is not the lever.** The window is tens of minutes and the poll
  interval is 60 s, so a poller cannot miss an arrival. What a follower needs is
  *runtime* — it has to outlive the drought. See the header of
  `tools/chain/follow-chain.mjs`, which records a 30-second poller that caught
  nothing because it ran for less time than a single inter-arrival gap.

---

## 3. The bar: complete blocks, not transactions

The demo publishes **2–3 complete blocks per network**. A block is *complete*
when **every transaction the chain published in it** has a reproduced replay —
not the first one, not at least one.

This is deliberately stricter than counting replays, and the difference is an
overclaim: three replays spread across three half-covered blocks satisfies "3
captured" while every one of those blocks renders with a transaction that cannot
be opened. `completeBlockCount` in `tools/chain/lib/replay.mjs` therefore ranges
over **the block's own transaction list as the chain published it**, never over
the transactions the capture chose to attempt — a definition that ranged over
our own selection would be satisfied by selecting fewer.

### What "13/13 effects" actually counts

A row's `effects.matched / (matched + mismatched)` is **not** the number of
entries in the block's published effect arrays, and reading it that way will
produce a false alarm. The denominator is the comparison set
`compareToPublishedEffects` builds:

    revertCode                     1
    transactionFee                 1
    publicDataWrites.length        1
    publicDataWrites[i].leafSlot   1 per write
    publicDataWrites[i].value      1 per write
    nullifiers.length              1
    nullifiers[i]                  1 per nullifier

So mainnet 68062 (2 writes, 5 nullifiers) is `1+1+1+4+1+5 = 13`, and 68231
(2 writes, 12 nullifiers) is `1+1+1+4+1+12 = 20`. Both reproduced every
comparison in their set.

**`noteHashes`, `privateLogs`, `publicLogs` and `l2ToL1Msgs` are not compared,**
and that is correct rather than a gap: they are outputs of the private half,
which the AVM does not execute. Summing the raw effect arrays for 68231 gives 27
and invites the conclusion that 7 effects went unchecked; they were never the
AVM's to produce. What the verdict asserts is that the replay re-derived the
public state transition — the same slots, the same values, the same fee, the
same nullifiers — which is the evidence that every value it read on the way was
the value the transaction read.

### The `firstInBlock` filter, and where it would bite

Both capture tools only offer the runtime a transaction that is **first in its
block**, because replaying transaction *k* needs the state left by *k-1* and no
node method serves intra-block intermediate state
(`IntraBlockPredecessorsUnavailable`).

That refusal has never fired in practice — **but only because the selector never
offers it a candidate.** It is untested, not unnecessary. In current windows both
chains run about one transaction per block, so a "full block" is usually one
transaction and the filter costs nothing.

If a candidate block ever holds more than one transaction, `firstInBlock` will
silently drop the rest, and a capture that inferred completeness from what the
filter selected would publish an **incomplete block believing it complete**. This
is why completeness is asserted against `getTxEffect`'s list and never inferred.
`tools/chain/freeze-snapshot.mjs` re-reads every candidate block from the chain
and reports any block it cannot complete as `PARTIAL`, excluded by name.

If a multi-transaction block ever has to be completed, the untested idea is that
the intermediate view may be **composable** even though it is not served: each
predecessor's `publicDataWrites`, nullifiers and note hashes *are* published and
fetchable. Nobody has tried it. Prefer blocks you can complete; if none of the
multi-transaction ones can be completed, say so rather than publishing a partial.

---

## 4. Freezing

Captured once, then frozen. There is no ongoing update after the demo ships.

```sh
node tools/chain/freeze-snapshot.mjs \
  --snapshot client/fixtures/chain/aztec-testnet --min-complete 2 [--check-only]
```

`frozen` is **not a flag a caller sets** — it is a conclusion the tool reaches,
and only by asking the chain again. Four checks, each of which refuses:

1. the block's contents, re-read from the chain (a block that gained a
   transaction is not whole);
2. every transaction in it reproduced (a `PARTIAL` block is named and excluded);
3. every container present, with its byte count equal to the row's
   `containerBytes`;
4. every container carrying the CTFS magic (`C0DE72ACE2`).

Refusing to freeze is the safe outcome. `tools/chain/freeze-snapshot-selftest.mjs`
drives all four refusals against a mock node — 19 counted assertions — because a
gate that has never said no is indistinguishable from no gate.

Once frozen, `ingest.nim` renders the provenance sentence in the **past tense**
and names the blocks it claims are whole. The running-watch phrasing ("was last
extended", "when it was last looked at") is true only while something might
extend the capture and becomes quietly misleading the moment it stops; suite 11
of `client/tests/test_chain_provenance.nim` pins both arms, with a mutation that
removes `frozen` and checks the wording reverts.

---

## 5. Running a capture

```sh
WT=$PWD RUNTIME=…/aztec-avm-runtime NODE_BIN=…/node \
AVM_WASM_PATH=…/avm.wasm CT_WRITER_WASM_PATH=…/aztec_ct_writer.wasm \
UNTIL_COMPLETE=3 DEADLINE_MIN=360 \
  sh tools/chain/watch-chain.sh /path/to/log.jsonl
```

`watch-chain.sh` supervises `follow-chain.mjs` and **re-arms** rather than
spending a budget — a watch that exhausts its arms and a watch that dies with
its session both stop without saying they stopped. With `UNTIL_COMPLETE` set,
the follower returns 0 once the snapshot holds that many complete blocks and the
supervisor logs `capture-target-met`; without it, exit code 0 means only "this
arm caught something" and is *not* a reason to stop. Both readings are pinned in
`tools/chain/watch-chain-selftest.sh`.

The preflight proves the toolchain can replay **before** the watch starts. Two
live mainnet transactions were lost to a bad `--avm` path discovered only at
catch time; a catch is rare and unrepeatable, so everything a watch can check
about itself it checks before it starts watching.
