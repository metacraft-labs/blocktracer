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

---

## 6. `fixtures/chain-artifacts/` — the capture that answers the rung question

### Why a second capture exists at all

The eight transactions frozen into `client/fixtures/chain/` all read
`declaredRung: 3, stepsPositioned: 0` **and carry no `artifacts` key at all.**
That is not a finding about Aztec contracts. Their runtime is `86c36ad`, which
predates off-chain artifact resolution, so nothing in those captures ever asked
whether a contract's sources could be proved. Rung 3 there is an *absence of
measurement*, not a measured ceiling — and the two are only distinguishable
because the key is absent rather than `[]` (§6.3).

> **Check the runtime you point `--runtime` at.** `86c36ad` is not an old tag,
> it is what a sibling `aztec-avm-runtime` checkout that has not been pulled
> still has on `dev` — 64 commits behind its own `origin/dev`, and without
> `replay/src/artifact_resolution.ts`. A capture taken against it produces
> exactly the shape this section is about, silently. `follow-chain.mjs` records
> the runtime commit in `provenance.runtimeCommit`, so which one a snapshot was
> taken with is always answerable after the fact; the preflight cannot check it,
> because a runtime without the resolver replays perfectly well.

That question cannot be answered by re-capturing the eight. **All eight bodies
are pruned**, re-measured on 2026-09-01: `getTxByHash` returns `null` for every
one of them on both networks while `getTxEffect` still answers, which is §1's
constraint arriving. Nothing can restore them, so the freeze is not merely
"preferably kept" — it is irreplaceable, and any capture that answers the
question has to be **additive**.

### 6.1 Asking the old captures the question anyway

`tools/chain/resolve-frozen-artifacts.mjs` asks it without the transaction.
Three facts survive pruning: the committed `.ct` interned every contract address
the execution entered; the node still serves the contract *instance* at that
address; and it still serves the *class* behind it, which is what carries
`artifactHash` and `packedBytecode`. Given those, `resolveContractArtifact` —
imported from the runtime, never restated here — decides as it would have at
capture time. The freeze is opened **read-only**.

```sh
node --experimental-strip-types tools/chain/resolve-frozen-artifacts.mjs \
  --runtime …/aztec-avm-runtime [--snapshot <dir>]… [--json]
```

A runtime without `replay/src/artifact_resolution.ts` is refused **by name**,
because "this runtime cannot resolve" and "it resolved nothing" are the two
readings this whole section exists to keep apart, and an empty run exits 1
saying so rather than letting a vacuous universal pass.

**The result, 2026-09-01, over all 8 frozen transactions and all 8 contracts
they entered: 1 resolves, 7 do not.** The one is testnet
`0x12525d6d…` at block 63670, which executes **FeeJuice at `0x…03`**, class
`0x1f85d8b901a8…`, artifact hash `0x1a57ff2a…` — proved by
`npm:@aztec/protocol-contracts@5.3.0-nightly.20260819`, 32 source files. So that
transaction's `declaredRung: 3` is a fact about *when it was captured* and not
about the contract, it would record at rung 1 today, and it can never be
recorded again. The other seven are genuine: their classes have no
length-matching artifact on npm and Aztecscan answers 404-with-empty-body for
each of their artifact hashes.

**It does not produce a recording and must never be read as one.** A resolution
says an artifact is provably a class's; a rung-1 *recording* additionally needs
the step stream written against that artifact's debug map, which needs the body.
Nothing downstream reads this tool — `ingest.nim` takes `recording.sourceLevel`
out of the snapshot, and this tool writes no snapshot.

### 6.2 The additive capture, and what it measured

`fixtures/chain-artifacts/aztec-testnet/` — a snapshot in the identical format,
taken with runtime `29bd9cf`, which resolves artifacts. It is deliberately
**outside `client/fixtures/chain/`**, the directory `static_export.nim` walks,
for two reasons: its `provenance.chain` is `aztec-testnet` and a second
directory at that slug would have two producers overwriting one chain's blocks
(the hazard `assertSlugAvailable` names); and publishing it is a product
decision about the home page's `canHeadline` exhibit, which `static_export.nim`
says in as many words must be made deliberately *with* a source-level capture
rather than discovered by one appearing in the tree. Reproduce it with the §5
command and `--snapshot fixtures/chain-artifacts/aztec-testnet`; it passes §4's
freeze gate unchanged.

As frozen on 2026-09-01: **8 complete blocks** — 65530, 65519, 65508, 65497,
65489, 65486, 65475, 65464 — out of 144 blocks and 18 transactions watched, all
8 replays reproducing their block's effects, 0 divergent, 0 refused.

**Every one of the 8 carries a real `artifacts` array: 8 of 8, and 8 contract
records in total.** The counts are stated because they are non-zero — a
universal claim over an empty set is vacuous — and each record names the
contract address and its **contract class id**, so verifiability can be checked
against a third party without re-running anything. Two distinct classes:

| class id | address | records |
| --- | --- | --- |
| `0x2b6749411979b61926b6f8836c3a1a28c39e9c0c3fb3322ed6e776f2f02cb6dc` | `0x2a9a1d0e8f19…` | 7 |
| `0x05c0419f2029dadb95fd75fc8fea90382d8d1f43261de91a3691f9db85b44220` | `0x0f826fa58eda…` | 1 |

Both are **unresolved, and measurably so**: each record carries
`candidatesConsidered: 0` with an empty `rejected`, which under
`resolveContractArtifact` means both providers were asked and neither offered a
candidate — a provider that threw would appear as a `provider-error` candidate
and therefore as a rejection, so zero-and-zero cannot be a swallowed network
failure. §6.4's three outside checks agree. Consequently every transaction
records `declaredRung: 3`, `sourceLevel: false`, `stepsPositioned: 0`. **That is
now a measured ceiling rather than an unasked question, which is the entire
difference from §6's opening paragraph.**

### 6.2a Rung 1 is reachable; this capture did not reach it

Stated separately because they are separate claims and only the first is
demonstrated end to end:

* the **resolution** half is demonstrated on this corpus — §6.1's FeeJuice;
* the **recording** half is demonstrated in the runtime's own L5 arms, which
  produce `declaredRung: 1, sourceLevel: true, stepsPositioned: 64/64` over that
  same proved artifact with real Noir positions (`main.nr:203:12`, `avm.nr:85:5`,
  `poseidon2.nr:68:17`);
* **no transaction captured live here has been both.** A live rung-1 recording
  needs a transaction whose first-in-block public execution enters a contract
  whose artifact resolves, and that is a matter of what the chain happens to
  carry inside the replay window.

Do not report "everything is rung 3 on Aztec" from this. The correct sentence is
that these particular contracts have no published artifact, and it is one
FeeJuice-executing transaction inside the window away from being false.

### 6.3 `artifacts` has three states, and two of them used to be one

| value | means |
| --- | --- |
| an array with entries | we looked; here is what each contract answered, rejections included |
| `[]` | we looked; the transaction executed no contract |
| `null` | no resolution was performed — this runtime cannot do one |

`ingest.nim` has always distinguished the third from the second. The capture
side could not hand it the third: both `lib/replay.mjs` and `capture-chain.mjs`
wrote `facts.artifacts ?? []`, which turns "nobody looked" into "looked, nothing
to look at" — in a committed fixture, about a transaction that in fact executed
a contract. Case 10 of `tools/chain/replay-selftest.mjs` pins all three states
and mutates the old rule to show it collapses exactly one of them.

### 6.4 Reading a resolution

A rejection with a reason is a result; a `null` is not, and `candidatesConsidered: 0`
is a third thing again — it means both providers were asked and neither offered
anything to verify. Corroborate it outside the tool before reading it as a fact
about the chain:

* the npm provider offers `@aztec/protocol-contracts`' artifacts, filtered by
  `public_dispatch` byte length. The installed `5.3.0-nightly.20260819` ships
  three, at 22 / 4,574 / 1,947 bytes;
* the Aztecscan provider is keyed by `artifactHash`, and its three answers are
  distinguishable by hand:
  `GET {base}/l2/artifacts/{artifactHash}` → **200** when it holds one, **404
  with an empty body** when it does not, **404 with an Express page** when the
  route has moved. Only the third is a bug in us, and the provider raises on it.
  All three were re-measured on 2026-09-01 against the testnet deployment: a
  `Train` artifact hash answered 200 with 1.5 MB, an unheld hash answered 404
  with 0 bytes, and a bad route answered 404 with 157 bytes;
* and independently of the artifact route, `GET
  {base}/l2/contract-classes/{classId}/versions/1` reports the explorer's own
  view of the class. For both classes this capture's transactions entered it
  answers **200 with `artifactContractName: null`** and an `artifactHash` equal
  to the node's — so the key the resolver asked with was the right key, and the
  explorer's answer is "I know this class and hold no artifact for it" rather
  than "I have never heard of it".

`artifactHash` does **not** commit to `debug_symbols` or `file_map`, so byte
equality of `public_dispatch` against `packedBytecode` proves nothing on its
own. Re-derived live on 2026-09-01 against the **deployed** testnet FeeJuice
(`0x…03`, class `0x1f85d8b901a8…`, artifact hash `0x1a57ff2a…`, 1,947 bytes of
`packedBytecode`), one release at a time so each verdict is about that release:

| release | `public_dispatch` | byte-equal to `packedBytecode` | `debug_symbols` | verdict |
| --- | --- | --- | --- | --- |
| `5.0.0-rc.2` | 1,947 B | **yes** | 2,968 chars | **REFUSED — `artifact-hash-mismatch`** |
| `5.2.0` | 1,947 B | yes | 2,964 chars | **RESOLVES** (32 source files) |

The bytecode is identical and the debug symbols are not, which is what makes
`5.0.0-rc.2` a decoy rather than merely a wrong answer: a resolver that stopped
at byte equality would have produced plausible line numbers out of a different
compilation. That ordering has been reported backwards before — the release that
resolves is **`5.2.0`**.

Because `artifactHash` does not commit to `debug_symbols` or `file_map`, a
resolution reports `corroboration` and the distributors that agree on the debug
digest separately from the proof itself; `single-distributor` is the honest
label for source text only one party attests, and `requireCorroboration` exists
for a caller who will not claim source level over it.
