# Why this capture exists beside `aztec-testnet`, and what it proves that the other cannot

This directory publishes `/aztec-testnet-frames`: fifteen blocks of Aztec testnet
(69347–69361) holding five transactions, every one of which opens a container that
steps. One of them — `0x0a807e4e…` in block 69361, caught at 16:44:38Z — is **the first
recording of a real chain transaction this repository has that carries a Noir call tree
AND real per-step AVM registers.**

It is published *beside* `/aztec-testnet` and not in place of it. See "Why a second slug"
below: that was not a preference.

## The claim

`/aztec-testnet` already serves a transaction with a Noir call tree — `0x20ed5b91…`. But
that container is **reconstructed**. It is byte-identical (sha256 `1a3e9abe…`) to
`client/fixtures/noir-frames/`, whose own `provenance.json` says so in its own words,
under `notMeasured.perStepAvmRegisters`:

> contextId, pc, opcode, l2Gas, daGas and contractAddress are written as ZERO. The
> published fixture does not carry them and this tool does not invent them.

So the existing page demonstrates that a Noir call tree *can be built*. It cannot show
that one *comes out of a live recording*, because its registers are zero and its program
counters are reconstructed. This capture can.

## The measurement

Both containers read back **as the site serves them** — `ct-print --full` over the bytes
under `dist/t/**`, not the writer's own report — counting how many written values of each
per-step register are non-zero:

| register | `0x20ed5b91` (reconstructed) | `0x0a807e4e` (live capture) |
|---|---|---|
| `contextId` | 108 values, **0** non-zero | 459 values, **459** non-zero |
| `l2Gas` | 108 values, **0** non-zero | 459 values, **459** non-zero |
| `daGas` | 108 values, **0** non-zero | 459 values, **459** non-zero |
| `opcode` | 108 values, **0** non-zero | 459 values, **359** non-zero |
| `contractAddress` | 108 values, **0** non-zero | 505 values, **505** non-zero |

… over 459 steps against 108, and 2961 events against 799.

**THE 100 ZERO `opcode` VALUES ARE NOT MISSING DATA, AND THE DIFFERENCE MATTERS.** The
container carries 25 distinct opcode values, which is exactly the `distinctOpcodes: 25`
its own snapshot row declares, and `0` is one of them — it occurs 100 times, tied for the
most common. A register that is written on every step and is sometimes 0 is not the same
artefact as a register that is 0 on every step because nothing measured it. The left
column is the second thing; this column is the first.

## What this does NOT claim

* **Not a bigger call tree.** 47 calls / 46 returns / 36 functions here against 46 / 45 /
  35 on the reconstructed one — nearly identical, because it is the same contract pair
  doing the same operation. Anyone comparing this to the `calls 2, returns 1,
  functions 2` ceiling is comparing against the *other* 24 published containers, not
  against the frames one. The frame counts are not the news; the provenance is.
* **Not source-level throughout.** 86 of 459 steps position to source. The other 373 are
  in a contract (`0x2fcd3dd5…`) whose artifact no distributor could prove, so its rung is
  3 and its steps carry no `(path, line)` — the snapshot row says why, at length.
* **Not a claim about the other four transactions here.** They are rung-3 bytecode
  listings with no Noir frames, and their call-trace sidecars say `foldedFrames: 0`
  truthfully — every one of their functions carries a `path_id`, so that zero means
  "nothing qualified" and not "the format cannot say". That distinction is enforced by
  `tools/chain/lib/calltrace_frames.mjs`, which refuses a container that cannot carry the
  field rather than publishing an ambiguous zero.

## Why a second slug, rather than one more row on `/aztec-testnet`

Because adding the row would have **deleted** the page it was meant to sit beside.

A curated build publishes exactly one contiguous run of recordings, delimited by
transactions that carry no trace, chosen source-first and then by recording count
(`src/blocktracer/chain/ingest.nim:378-540`). `0x20ed5b91…` sits in a run of **three**.
Any run containing this capture has **five**, and with the full intervening capture it is
**thirty-three**. Both runs are source-bearing, so the tie falls to count and the older,
smaller run loses. Measured three ways:

| snapshot | window ingest chooses | is `0x20ed5b91` published? |
|---|---|---|
| today | 67010–67018 (3 recordings) | **yes** — block 67011 |
| today + this row appended | 67029–69361 (17 recordings) | **no** |
| the full capture branch | 67427–67546 (33 recordings) | **no** |

Appending the row is worse than merely moving the window: this repository's snapshot stops
at block 67058, so appending a transaction from 69361 **fabricates a 2300-block gap with
no traceless delimiter in it**, and that absence is what merges the two runs. The append
misrepresents the chain as well as dropping the page.

`static_export.nim:287` states the supported alternative in its own words — *"A second
real chain is a directory, not a code change"* — and `assertSlugAvailable` refuses only a
collision between different producers. So this is a directory.

It also earns its own recorder pin honestly: every capture session here ran on runtime
`94e7d4bb`, the frames runtime, where `/aztec-testnet` is pinned to `29bd9cf`. One slug,
one recorder build, which is the invariant `ingest.nim` enforces at its registry.

## Provenance

* Containers and source bundles taken unmodified from `capture/rung1-watch` at
  `8b76bbc`, read out of the git object store. `0x0a807e4e…` is sha256 `25aaec9d…` —
  a different recording from the fixture's `894eb7ac…`, five hours later, a different
  transaction in a different block.
* `calltrace/` by `tools/chain/derive-calltrace.mjs`, `positions/` by
  `derive-positions.mjs`, both read out of the containers with `ct-print`.
* The publish was checked to leave `/aztec-testnet` **byte-identical**: all 43 written
  files, same sha256, 13,004,879 bytes before and after, and its debug page still carries
  81 `ctrow`, 2 `ctfold` and 44 `ctline`.
