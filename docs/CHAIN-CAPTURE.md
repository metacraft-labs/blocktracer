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

`frozen` does **not** change the prose on the page, and used to. `ingest.nim`
carried three capture tenses — a frozen one naming every block "taken WHOLE", a
running watch that "was last extended", a one-shot scan "at that moment" — each
true of a different snapshot, with a mutation arm pinning the difference. A user
read the result and asked for prose that is "more user friendly and simpler",
with the things "real users are unlikely to care about" removed, and all three
narrated the capture rather than the chain. Suite 11 asserts a frozen and an
unfrozen capture read **identically**, which is where a re-grown branch would
show. The flag still gates what it always gated and is still published in
`summary.json` — it simply no longer picks a tense.

`Captured on <date>` replaced those three tenses and did not survive the next
round either. A user asked the "About this data" section to "just say that the
data is real, but limited to a preliminary export while citing the timespan that
is covered", and a capture date is one END of a watch: it says when the reading
stopped and nothing about what period the data covers. The section is now two
sentences, written by one expression for every snapshot and every ingest scope —

> Blocks and transactions taken from the live network. This is a preliminary
> export covering 1 September 2026.

— with the span read from the timestamps the **blocks** carry, over the blocks
the generation **publishes**. That is the curated window under `isCurated` and
the whole enumerated record under `isFull`, with no branch: the narrowing is a
no-op in the second case. So the sentence and the `Blocks` stat above it are two
views of one set, and neither can go stale against the other.

The alternative — measuring the enumerated record even when a narrower one is
published — shipped for one commit and is the reason this paragraph names the
rule. `/aztec` enumerates 1563 blocks across two days and publishes 170 inside
three and a half hours of the last one; a span quoted from the first set
overstates what a reader can browse nearly tenfold. "Covered" means covered by
what is in front of them.

`capturedAt` is still published verbatim in `summary.json`, along with
`tracesPublished`, `publishedWindow`, `observedBlocks`, `observedTransactions`,
`finalizedAtCapture` and `longestRunWithoutTx` — every number the four
paragraphs this replaced used to narrate.

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

> **The capture path now refuses this, and here is what it was.** `86c36ad` is
> not an old tag: it is what a sibling `aztec-avm-runtime` checkout that has not
> been pulled still has on `dev` — 64 commits behind its own `origin/dev`, and
> without `replay/src/artifact_resolution.ts`. A runtime in that state replays
> *perfectly*: it hydrates, reproduces the block's effects, and writes a
> container that steps. It simply never looks for source. A bad `--avm` path
> refuses loudly; this one succeeds quietly, which is why it cost the corpus a
> year and one permanently unanswerable transaction.
>
> `resolverPresence` (`lib/replay.mjs`) now asks whether the resolver module is
> there, and **both** `follow-chain.mjs` (via the preflight) and
> `capture-chain.mjs` refuse before a single poll. It is a path test and not a
> commit pin, deliberately: a pinned commit goes stale the first time the
> runtime moves and then refuses runtimes that are fine, which is the mistake
> `refusalName` made when it was a suffix allowlist. Case 11 of
> `replay-selftest.mjs` drives both arms against a synthetic stale checkout that
> is complete *except* for that one module — an empty directory would pass a
> rule that merely checked the runtime path existed. `provenance.runtimeCommit`
> still records which runtime a snapshot was taken with, so the question stays
> answerable after the fact as well as before it.

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
  --runtime …/aztec-avm-runtime [--snapshot <dir>]… [--json] [--write]
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

Re-measured 2026-09-03 with runtime `29bd9cf`: **the same 1 of 8**, same
transaction, same distributor. Two independent runs two days apart agreeing is
what makes the seven a finding about those classes rather than about one
afternoon's network.

**It does not produce a recording and must never be read as one.** A resolution
says an artifact is provably a class's; a rung-1 *recording* additionally needs
the step stream written against that artifact's debug map, which needs the body.
`ingest.nim` takes `recording.sourceLevel` out of the snapshot and out of
nothing else, so no output of this tool can raise it.

### 6.1a `--write`, and why the answer is published

Leaving the answer in a terminal meant the corpus knew something the product did
not: every real transaction on the deployed site read **`Not checked`** — the
badge for `scUnchecked`, "somebody replayed it; nobody looked for source" — and
a user reasonably objected to publishing rows whose label means nobody looked.
That is not a finding that nothing is published, and §6.1 shows it is wrong for
one of the eight.

`--write` emits `artifact-resolution.json` **beside** each capture. It is a
sidecar and never the snapshot: the freeze stays read-only, which is the
guarantee above and is unchanged. It carries `measuredAt`, the resolver's own
`runtimeCommit`, and the capture's — the gap between those two commits is the
entire subject of §6 — and one record per transaction the run opened.

`ingest.nim` reads it under three restrictions, each of which is the difference
between reporting a measurement and inventing one:

* **only where the capture recorded nothing.** A real `ct.source-provenance` is
  the measurement taken as the transaction executed; this is an answer about the
  class today. Where both exist the capture wins.
* **never onto `sourceLevel`.** A resolution cannot make a container
  source-level, so it cannot raise the flag or cause a source bundle to be
  written.
* **never anonymously.** Every published entry carries `measuredPostHoc`, and
  the tree records when and by which resolver.

A transaction whose run did not answer for *every* address its container
interned is written `artifacts: null` — the same `null` that means "nobody
looked" — rather than with the addresses that did answer. Publishing the partial
set would shrink the denominator and let a half-answered transaction read as
complete, which is the defect `test_chain_provenance`'s "the numerator and
denominator are the transaction's, not the resolved set's" exists to catch.

**And the badge is not allowed to over-promise.** `Sources available` is true of
the ARTIFACT — provable against the chain's commitment to the class — and says
nothing about whether *this* container positions its steps against it. For every
transaction the site publishes today it does not, because the capture predates
resolution. So `SourceCoverageView.positioned` is read from the tree's own
`sourceLevel`, and `sourcesNote` says which of the two is the case. Without that
sentence the transaction page would read `Sources available` inches from a
source pane reading "Stepping continues at instruction level", and a visitor
would be right to conclude one of them was lying.

### 6.1b The positions, joined from the pcs the container did carry

**The recording is not missing the coordinate.** Every frozen container records a
program counter per step, and `instructions/<tx>.json` republishes it — the `pc`
column. An artifact's `debug_symbols.brillig_locations` is keyed by *exactly that*
AVM byte offset. So the join `pc -> (path, line, column)` is computable from data
that already exists, for a transaction whose body is pruned.

`--write` performs it with the recorder's own `ContractSourceMap.positionFor` —
the same call `recording.ts` makes at capture time, imported rather than restated.

**Measured over the corpus:** testnet `0x12525d6d`, **86 of 108 steps** resolve to
a real Noir position. Steps 35–107 are unbroken source. The positioned steps land
in 11 files; the artifact carries all 32 (270 KB), so the text is there too.

    pc 130 -> fee_juice_contract/src/main.nr:203:12

**The 22 that do not resolve are the ARTIFACT's limit, not the recording's**, and a
new capture cannot improve them: 14 sit below the artifact's mapped range (the
dispatch prologue), and 8 sit inside it but unkeyed — *"compiled procedures are
appended after the main body"*, §2.4 hole 2. A fresh recording of the same contract
walks the same pcs against the same map. **So `sourceLevel: true` — rung 1, every
step positioned — is not reachable for this contract by any capture we can take.**
It needs upstream's transpiler to key the appended procedures.

What is published, per transaction that positions at least one step:

* `positions.json` beside the container — a per-step sidecar in the shape
  `instructions.json` established: parallel `pathId`/`line`/`column` columns,
  `paths` interned once, refused at publish time if any column's length disagrees
  with the recording's step count. Marked `measuredPostHoc` with its moment.
* a source bundle, through the same `writeSourceBundle` a source-level capture
  uses, so the text is reachable from the manifest's `sourceBundles`.

**`execution.sourceLevel` stays FALSE**, and that pair — bundle published, claim
withheld — is the whole design. The capture's own all-or-nothing measurement is
untouched; what is added is text and coordinates for a recording that is *partly*
positioned, a state the corpus previously had no way to express.

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

### 6.2a ~~Rung 1 is reachable; this capture did not reach it~~ — WITHDRAWN

**This section was wrong, and §6.5 replaces it.** Its closing sentence — "it is
one FeeJuice-executing transaction inside the window away from being false" —
was tested directly on 2026-09-02 by capturing exactly that transaction. The
transaction resolved, positioned 86 of its 108 steps against real Noir, and came
out at **rung 2**. Rung 1 is not one transaction away. It is not reachable at
all on this chain, and the reason is structural rather than statistical.

What the section got right, and §6.5 keeps: the resolution half is demonstrated
(§6.1's FeeJuice), and "everything is rung 3 on Aztec" was indeed the wrong
sentence — it is now measurably false.

What it got wrong is the second bullet. The runtime's L5 arms do produce
`declaredRung: 1, sourceLevel: true, stepsPositioned: 64/64` — **over a step
stream built from the artifact's own mapped program counters.**
`run_l5_recording_arms.mjs` takes `mappedPcs.slice(0, 64)`, so 64/64 holds by
construction and cannot fail. The file says so itself: "the step stream here is
synthetic… It is NOT the milestone's evidence that a real chain execution
reaches rung 1." Reading it as the recording half being demonstrated is what
made rung 1 look like a matter of luck.

### 6.5 Rung 1 is structurally unreachable on Aztec, and what was actually blocking the product

Two findings, and they point in opposite directions. The first closes a
milestone; the second retires one that could never have been met.

#### The capture happened, and it is rung 2

A watch armed at 21:00Z on 2026-09-02 caught **`0x20ed5b91…` in testnet block
67011** two minutes later — the first transaction this repository has captured
from a real chain that positions steps against real source.

| | |
| --- | --- |
| contract | **FeeJuice** at `0x…03`, class `0x1f85d8b901a8…` |
| artifact | `npm:@aztec/protocol-contracts@5.3.0-nightly.20260819`, proved against the class's `artifactHash` `0x1a57ff2a…` |
| positions | **86 of 108 executed steps**, at real `(path, line, column)` |
| bundle | 32 Noir files, 283 KB, keyed at the paths the container interned |
| verdict | `declaredRung: 2`, `sourceLevel: false`, effects reproduced, 0 divergent |
| corroboration | `single-distributor` — npm alone attests the debug symbols |

Its body pruned within the hour, re-measured 2026-09-04: `getTxByHash` returns
null. So this container is as irreplaceable as the frozen eight, and §1 applies
to it in full.

#### Why the last 22 steps can never be positioned

The 22 unpositioned steps are **not** a transpiler keying bug, and the rung-2
reason string this capture recorded is misattributed — it blames
`avm-transpiler transpile.rs:489,505`, which is the `MultiScalarMul` path.
That is the transpiler's *only* procedure, FeeJuice's `public_dispatch`
contains no MSM, and it therefore contributed **zero** of the 22.

The real cause is one branch in Noir,
`compiler/noirc_evaluator/src/brillig/brillig_ir/artifact.rs:335-340`:

```rust
pub(crate) fn push_opcode(&mut self, opcode: BrilligOpcode<F>) {
    if !self.call_stack_id.is_root() {
        self.locations.insert(self.index_of_next_opcode(), self.call_stack_id);
    }
    self.byte_code.push(opcode);
}
```

A location is recorded **only** when the call stack is non-root. A procedure
context built by `BrilligContext::new_for_procedure` never has a Noir call
stack, so **compiler-generated code carries no source location by
construction** — there is no Noir line for it to point at, because there is no
Noir behind it. This is not a bug to be fixed upstream; it is what "compiler-
generated" means.

Disassembled against blocktracer's own opcode table, FeeJuice's 1,947-byte
`public_dispatch` is 377 instructions, 314 mapped, **63 unmapped**:

| region | instrs | unmapped | what it is |
| --- | --- | --- | --- |
| prologue `[0,130)` | 17 | **17** | entry point + globals init |
| main body `[130,1785]` | 331 | 17 | block-terminator jumps, constant `SET` runs |
| tail `(1785,1947)` | 29 | **29** | `RevertWithString` ×6, `MemCopy` |

**Every Aztec public transaction enters through `public_dispatch`**, so its
17-instruction prologue alone guarantees ≥17 unpositioned steps on every public
transaction of every contract, forever. `sourceLevel` requires *every* executed
step positioned (`recording.ts:618`), and rung 1 is equivalent to it, so:

> **Rung 1 cannot be recorded from any real Aztec chain transaction.** Not with
> a better contract, not with a longer watch, not with an upstream
> `avm-transpiler` fix. The ladder's top rung asks for something the compiler
> does not emit.

`brillig_procedure_locs` does not rescue it: it is keyed in brillig opcode
indices rather than AVM pcs, covers 14 of the 63, drops five of the six
`RevertWithString` ranges to a `ProcedureId` collision, and yields a *procedure
name* rather than a `(path, line, column)` even so. `avm-transpiler` is
byte-identical at `upstream/next`.

**So do not set rung 1 as a target for chain capture.** The honest target is
rung 2 with high coverage, and the missing concept is a rung meaning "positioned
everywhere source exists" — which needs the transpiler to *partition* the
unpositioned set rather than merely count it.

#### What was actually keeping source off the page

None of the above was what the user hit. **The tree was already publishing the
source and the product was rendering bytecode over it.**

`ingest.nim` published the 32-file bundle and a 108-row `positions.json` beside
the container — and `positions.json` had **no consumer anywhere in the client**.
The one question the debug route could ask was
`manifest.execution.sourceLevel`, the all-or-nothing bit that §6.5 has just
shown is permanently false. So a transaction with 86 real Noir positions
rendered an instruction listing, under a badge reading "Sources available".

Fixed by `demo_session.withSourcePositions`, which reads the per-step stream
directly: real files, the step's real line, a gutter built from the recording's
own visited set, and the coverage carried on the pane so the frame states which
number it is showing. Three rules keep it honest:

* it takes the pane only where `withPublishedSources` did not, so a manifest
  that genuinely claims source level still outranks it;
* it lands the session on a step that **has** a position — the unpositioned ones
  are the dispatch prologue and sit at the front of the stream, so an arithmetic
  mid-point would open on the one region with nothing to show;
* **a post-hoc position stream is admitted only when the capture's own
  `stepsPositioned` agrees with it.** `resolve-frozen-artifacts.mjs` is the only
  producer of per-step coordinates — a live capture publishes the counts and not
  the coordinates — so refusing post-hoc outright would refuse everything. What
  is refused instead is *disagreement*: frozen `0x12525d6d…` says 0 and derives
  86, so it keeps its listing and its "Source not recorded" badge, exactly as
  §6.2b concluded; live `0x20ed5b91…` says 86 and derives 86, so the detail
  behind a number the recording already published is shown.

#### 6.5a And then the pane had to hold BOTH, because one recording is two fidelities

§6.5's fix gave a partly-positioned recording its source back. It did not give it
the other half — the steps source does *not* reach still had no row. That was
true of `0x20ed5b91…` too, whose 22 unpositioned steps are its dispatch prologue;
what made it visible was a capture where the gap is 373 steps in a second
*contract* rather than 22 at the front of one, so no landing rule could step over
it.

`aztec-testnet-frames/0x0a807e4e…` runs **459 steps across two contracts at two
fidelities**: `0x…0003` positions 86 of its 108 steps, and `0x2fcd3dd5…` — steps
108..458 — positions none, because no distributor could prove its artifact.
Unpositioned runs: ticks `0..13`, `27..34`, `108..458`.

**The Code-pane ladder was a contest.** `withPublishedSources` beat
`withSourcePositions` beat `withInstructionListing`, and whichever won held the
pane for the whole session — because `SourceAvailabilityView` is one value and
`documents` is one list. The middle rung won here, so the page was 32 Noir
documents and no listing, and **at 373 of 459 ticks there was no row of any kind
to be stopped at.** The static export escaped by an accident of the middle rung's
own landing rule, which moves the served step to one there is source for and
landed this recording on 107; hydration lands at tick 0 and marked nothing —
224 rows of Noir, no mark, no position head, no note.

**The derivation was refusing the container it should have half-published.**
`derive-instructions.mjs` raised on the first step with a non-zero `path_id`, and
its reasoning was right about those steps: a positioned step spends its `line`
field on the source line, so it has no program counter and one must not be
invented. What does not follow is refusing the whole container — 373 of these
459 steps *do* carry a counter, and they are exactly the steps with no source
line.

What is published now, as **`avm-instructions/2`** (the `pc` column's domain
changed, so it is a version and not a field): one row per step, a real counter at
`path_id == 0` and `-1` at the rest, plus a `counters` count. The op, gas and
context columns were already complete on all 459 (see the frames capture's
`REGISTERS.md`), so only `pc` is sparse. The refusal is **kept** for a container
that positions *every* step: that one has no counters at all, and its per-step
positions are strictly more than a listing.

Everything downstream that does arithmetic on a counter skips the sentinel —
`hexWidth`, `destinationSuffix`, and `explainsProgramCounters`, which matters
most: one sentinel differenced against a real counter is one *mismatch*, and one
mismatch withdraws the opcode names from the whole recording.

**The ladder is now a union for this class.**
`demo_session.withListingBesideSource` appends the listing to a pane that is
already showing source, so one pane holds both kinds of document and every tick
has a row; `renderSource` decides what a document *is* from its path rather than
from the pane's availability; and a `.srcrung` header states which rung the
position is on and rewrites itself when a step crosses the boundary — which is
`Debugger-Integration.md` §5's visible transition and `Source-Resolution.md` §7's
"rather than silent". `session_project.projectEditor` is the hydrated half: when
`positionDocumentIndex` resolves the engine's position to no published document,
it re-decodes the island at the listing and the tick. Row *n* is tick *n*, so
that join is the identity.

Cross-checked at the data plane, and this is the part worth keeping: the
positions sidecar and the instruction listing are derived by two different tools
from the same container, and over all 459 steps they **disagree about zero of
them** — every step carries a `(path, line)` or a counter, never both and never
neither. `client/tests/test_instruction_listing.nim` asserts that partition step
by step, and journey 27 judges the rendered result in a browser.

### 6.6 The Values pane is still empty; the Call Trace is NOT, and the reason it was is a correction worth keeping

Recorded because the obvious reading — "the panes are empty, so the pane
plumbing is broken" — was wrong for both, and the two needed different work by
different owners. Neither blocked the source view above.

**Call Trace: FILLED, and the argument that said it could not be is the lesson.**
The container carries the frames. Measured on `0x20ed5b91…`, and identically on
all 27 committed containers: two `Function` events (`<toplevel>`,
`enqueued-call-0`), two `Call` events — the second carrying the contract address
as its argument — and one `Return`.

This section used to conclude that they were absent from the STATICALLY EXPORTED
page "only because that page has no CTFS reader — the site build is hermetic and
cannot depend on `codetracer-trace-format-nim`", and that the pane's note was
therefore accurate as it stood: *"They are listed once the session is live."*

**That conclusion did not follow from its premises, and it went unchallenged
because it sounded like a fact about the architecture rather than an inference.**
(The six review rounds this section cites elsewhere — vd9-r1 L4/L5/ADV, vd9-r2
L5/ADV — filed the pane's *wording*, not its emptiness. The emptiness was never
contested, which is the point: a sentence asserting an impossibility stops people
looking, and reviewers kept correcting the explanation instead.) The build indeed
does not open a container. But `instructions/<tx>.json` and `positions/<tx>.json`
are also read out of these same containers by that same reader — the read happens
BY HAND, ahead of the build, and the result is committed (`just chain-instructions`).
The pane was empty because nobody had pointed that already-accepted mechanism at
the frames, not because anything prevented it.

**The build's hermeticity was never the issue, and it is worth being exact about
why, because the word is load-bearing elsewhere.** `nix build` really is
sandboxed with no network, and `client/src` really does compile with no debugger
on the Nim path (§1a) — both are true, both are checked, and neither is being
weakened here. What went wrong was reasoning from "the build cannot reach for X"
to "the site may not contain X". This derivation does not run in the build. It
runs by hand and commits a JSON file, which is then an ordinary source input —
exactly like the vendored `.ct` containers sitting beside it, which the build
also does not fetch and does not open.

The repository already draws that line correctly everywhere else. The deploy
workflow adds the replay engine to the staged site by `curl` **after**
`nix build`, and says so in as many words, *because* the build cannot reach the
network. Nothing about that is a compromise of hermeticity; it is what
hermeticity means. §6.6 was the one place that crossed the line.

The rule that IS real is **source-dependency hygiene** — do not put a Nim
library on this repository's dependency graph — which is narrower than
"hermetic" and never reached the frames at all.

**What is there now.** `tools/chain/derive-calltrace.mjs` (`just chain-calltrace`)
writes `calltrace/<tx>.json`; `ingest.nim` publishes it as `calltrace.json` beside
the container; `ssr.withCallFrames` renders the rows. Same standing as
`chain-instructions` in every respect — run by hand, output committed, absent is a
valid tree.

**The disagreement it closed.** `manifest.execution.frames` is written from the
capture's `recording.callsOpened` and was publishing `1` on every transaction
while the pane beside it rendered zero rows. Two producers of one answer,
disagreeing in public, with the prose above explaining the silence rather than
catching it. The derivation and the ingest both now refuse a stream whose frame
count is not `callsOpened + 1` (`<toplevel>` is the synthetic frame holding the
enqueued calls and is not counted by `callsOpened`).

**What remains true, and is kept.** The frames carry NO file and NO line: the
recorder places them on the pseudo-path `/aztec/<tx>.avm`, which is its own
spelling of "no source position". And a live session still lists *more* — it adds
`href`s and the engine's own `CalltraceVM` — so the hydrated path is richer, not
redundant. `hydrate.writePane` only replaces a served pane with one that has
frames, so filling these rows cannot cost a visitor the live answer.

**What this call trace is, and what it stopped being.** For a container written
by a recorder before `aztec-avm-runtime@255a61e` it is two frames deep, both open
before step 0, and one `Return` at the end: an AVM enqueued call is one public
function invocation and that recorder opened no frame per inlined Noir callee, so
a reader should expect a short flat answer — the pane showing two rows is that
answer and not a truncation of a longer one. **Twenty-four of the twenty-five
published aztec-testnet containers are still exactly this**, and both the fold
selftest and `test_noir_frame_folding` draw their control from them.

The twenty-fifth is not. `0x20ed5b91…` now publishes the container the frames
recorder writes for that same execution — forty-six frames, ten deep, thirty-five
distinct functions over eighteen interned paths, with two `vendored-crate` fold
points closing the poseidon2 subtrees. Its per-step AVM registers are zeros and
say so in `client/fixtures/noir-frames/provenance.json`; the execution behind it
is unchanged, which is why `positions/` still reads 108 steps with 86 positioned
and the transaction's `executionInputId` did not move. What DID move is its
`/t/**` address, because `deriveTraceArtifactId` hashes the recorder build — a
new recording by a new build is a new artifact, and the page route is by
transaction hash, so the visitor's URL is unaffected.

**Values: the artifact has no variable table, and this is upstream of us.** The
container carries five `VariableName` events and 541 `Value`s — but the five are
`contractAddress`, `opcode`, `contextId`, `l2Gas`, `daGas`, which are the AVM's
machine columns and not program locals. Naming a local needs the artifact's
variable debug tables, and **the published artifact has none**. Decoded from
`npm:@aztec/protocol-contracts`' FeeJuice `public_dispatch` (`debug_symbols` is
raw-deflate base64, not gzip):

```
debug_info keys: brillig_locations, location_tree, acir_locations,
                 variables, functions, types, brillig_procedure_locs
  variables = {}      ← empty
  functions = {}      ← empty
  types     = {}      ← empty
```

So the source map is fully populated and the variable side is fully absent. This
is the *release* build: Noir emits those tables from its debug instrumentation
(`tooling/noirc_artifacts/src/debug_vars.rs`), and Aztec does not ship contracts
compiled with it.

**Two changes are needed, in this order, and neither is a front-end fix:**

1. **Aztec** would have to publish protocol-contract artifacts compiled with
   variable debug information, so `debug_info.variables` / `.functions` /
   `.types` are non-empty. Until this happens nothing downstream can name a
   local, however good the recorder is — there is no name to read.
2. **The AVM replay recorder** (`aztec-avm-runtime`) would then have to resolve
   those tables against AVM memory at each step and emit one
   `VariableName`/`Value` pair per live local, instead of only its five machine
   columns. That is the same join `positions.json` already does for
   `(path, line)`, one table over.

Until (1), the honest render is the one the pane now gives: the recording's
names are machine state, the artifact resolved, and its variable table is empty.
Do not read the empty Values pane as evidence that source resolution failed —
on this transaction it succeeded.

### 6.2b Can the frozen FeeJuice transaction be upgraded to rung 1 in place?

It was asked properly, because the artifact comes from **npm and not the chain** and the
container is already frozen — so nothing about the pruned body obviously blocks it.
**The answer is no, and the reason is not the mapping.** Recorded here because the
question is a good one and will be asked again.

**The positioning input is all there.** The frozen container's steps carry AVM program
counters (108 steps, 108 distinct pcs, 0–645), and `brillig_locations` is keyed by AVM
byte offset — `avm-transpiler` re-keys it on the way through (`transpile.rs:1803`), which
is `source_map.ts`'s whole finding. Measured against the artifact: **86 of the 108 steps
would position**, at real Noir lines (`main.nr:203:12`, `main.nr:223:44`, inlining depth
2). The 22 that would not are the dispatch prologue — 14 pcs below the map's first key,
130 — plus 8 gaps in range. Nothing was dropped at capture time that only a re-record
could supply.

**The proof half is as strong as §6.4's standard demands**, re-derived against the
*installed nightly* as well as `5.2.0`, since a nightly is where a substitution would
hide. Both give byte-identical answers: `public_dispatch` 1,947 B byte-equal to the
class's `packedBytecode`, `computeArtifactHash` = `0x1a57ff2a…` equal to the class's, and
the class id recomputing to `0x1f85d8b901a8…`. `rungFor` returns rung 1 (map keys
130–1785, inside the 1,947-byte bytecode).

**But the symbols are not tied to the recorded bytecode, and the control proves the tie
cannot be tightened by inspection.** `computeArtifactHash`'s preimage is the
private-function tree root, the utility-function tree root and `sha256(name, outputs)` —
**public function bytecode is not in it, and neither is `debug_symbols` or `file_map`.**
The obvious hope is that pc-alignment discriminates: a map from a different compilation
would misalign with the pcs the AVM really visited. It does not. Run against
`5.0.0-rc.2` — the published decoy the resolver **refuses** on `artifact-hash-mismatch` —
the alignment is *identical*:

| release | observed pcs mapped | map keys that are real pcs | positions at the first 5 steps |
| --- | --- | --- | --- |
| `5.0.0-rc.2` (**refused**) | 86/94 (91.5%) | 86/91 (94.5%) | `main.nr:203`, `223`, `223`, `223`, `223` |
| `5.2.0` (resolves) | 86/94 (91.5%) | 86/91 (94.5%) | identical |
| `5.3.0-nightly` (resolves) | 86/94 (91.5%) | 86/91 (94.5%) | identical |

So alignment shows the map is for *this bytecode*; it cannot show *which compilation's*
symbols you hold. The only thing separating the decoy from the good release is
`artifactHash`, and `artifactHash` does not cover the map. `artifact_resolution.ts` states
that bound; this measurement shows it is tight rather than conservative. Corroboration
here is **single-distributor** — npm only; `5.2.0` and the nightly are two releases of one
distributor, and Aztecscan answers 404 for `0x1a57ff2a…`.

**The blocker is what the object would be.** The mapping is defensible under the runtime's
own policy (rung 1 is permitted at `single-distributor` provided the container says so).
What is not available is the container:

* it would need a **CTFS transcoder** — read the frozen `.ct`, re-emit every event through
  a writer opened at rung 1. `codetracer-trace-format-nim` has both halves, so it is
  buildable, and it would run BY HAND and commit its output, exactly as
  `chain-instructions` and `chain-calltrace` do — so the dependency question is not
  what blocks this. (This bullet used to cite §Justfile `chain-instructions` for the
  claim that such a checkout "cannot be one — the site build is hermetic". That
  overstatement is corrected at both ends; see §6.6. It never load-bore here anyway,
  because the two bullets below are the actual blockers and neither is about
  dependencies.);
* it would be a **second producer of containers**, beside `buildSettledRecording`, which
  is the only thing that has ever written one for this corpus;
* the rung is fixed at `CtWriter` **construction** on purpose — `resolveTracingConfig`
  throws `ColumnAwarenessUnavailable` below rung 1 — because the rung is a property of the
  recording *session*. A post-hoc transcode would have to synthesise `ct.step-producer`,
  `ct.source-provenance` and `ct.source-mapping-ceiling` describing a session that never
  happened, and serve the result at `t/<id>/trace.ct`, which the product means as "the
  transaction, re-executed".

A wrong source mapping is worse than an honest rung 3, and a synthesised recording served
as a recording is the confident-but-wrong artefact this repository refuses everywhere else.
So the container stays rung 3.

**What IS available, and is a separate axis.** `reader.sourceCoverage` folds
`native.replay.artifacts` **and nothing else** — it is orthogonal to
`recording.sourceLevel` and says so. So a retroactive resolution can move the frozen rows
off `scUnchecked` (to `scAll` for the FeeJuice transaction, `scNone` for the other seven)
with no container change and no source-level claim. It needs a sidecar the ingest merges
rather than an edit to the frozen `snapshot.json`, and it introduces `scAll` with
`sourceLevel: false` — a combination the live pipeline never produces and the product has
no copy for. That is a deliberate product decision of the same kind `static_export.nim`
reserves for `canHeadline`, so it is written down here rather than taken unilaterally.

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
