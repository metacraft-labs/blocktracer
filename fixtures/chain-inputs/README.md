# `fixtures/chain-inputs/` — INPUTS, not recordings

Everything under this directory is **data a chain produced**, committed so that a capture
can be re-run without a network. Nothing under it is derived from a capture.

That distinction is the whole reason the directory exists, and it is a policy rather than a
preference. `metacraft-dev-guidelines/policies/repo-requirements.md` §4.3: `*.ct` is
committed in `codetracer-example-recordings` and nowhere else, because a derived artefact
committed beside its producer is a clock. `fixtures/chain-health/readable-container`
measured what that clock costs — the container there was committed, went stale against the
writer, and regenerating it moved `containerBytes` **151,552 → 77,824** across two
container versions and a `meta.dat` schema while **not one checked fact moved**. Derived
bytes churn. The chain does not.

So the rule this directory is on the right side of:

| | committed? | why |
|---|---|---|
| a transaction body, a block header, an account's balance / nonce / code / storage at a finalised height | **yes** | immutable; the chain that produced it cannot change it |
| a CTFS container, a snapshot tree, an instruction listing, a position stream | **no** | derived; produced by the thing that needs them, so they cannot go stale |

## `ethereum-mainnet/<tx>/`

A `tools/chain/eth-rpc-transcript.mjs` transcript: the **entire** JSON-RPC conversation the
Ethereum capture has with an archive endpoint, as one file per distinct `(method, params)`
plus a `manifest.json` that pins every file's sha256.

```
manifest.json                     the ledger: one row per call, with its kind and its sha256
calls/<method>.<hint>.<key>.json  {method, params, kind, http, response} — the answer verbatim
```

Produce the capture from it, with no network at all:

```sh
just eth-capture <recorder-binary> <recorder-commit>
```

Re-record it against a live endpoint (the one command here that needs the network):

```sh
just eth-inputs-record <recorder-binary> <recorder-commit>
```

Check the committed bytes against the manifest:

```sh
just eth-inputs-verify
```

### What each answer is, and how far it can be verified

`tools/chain/eth-rpc-transcript-selftest.mjs` is the gate (30 arms, in `just
chain-selftest`). It verifies the inputs three ways:

1. **Bytes.** Every file's sha256 against `manifest.json`, and `--verify` additionally
   refuses a file under `calls/` that the manifest does not list — an unlisted input is an
   input nothing pins.
2. **Agreement.** The endpoint answered about the captured block three independent times —
   `eth_getBlockByNumber` without bodies, the same with bodies, and `eth_getBlockReceipts`
   — and the three are cross-checked against each other: the same 208 transaction hashes in
   the same order, the same `blockHash` on every receipt, the target transaction at the
   index it claims. A forged answer would have to be forged consistently in all three.
3. **Reproduction.** The capture replayed from these inputs produces the decoded content
   the LIVE capture produced. That one is not in the selftest — it needs the recorder
   binary — and it is what `just eth-capture` does.

**What is NOT verified: cryptographic self-attestation.** The strongest check on a
transaction body is that `keccak256(rlp(body))` equals the hash it is filed under, and on an
`eth_getProof` answer that its Merkle path hashes up to the block's `stateRoot`. Neither is
done, because this repository has no keccak-256 and no RLP, deliberately:
`tools/chain/identifier-encodings.json` carries the standing argument against growing one,
`blocktracer.nimble` declares no third-party dependencies, and `node:crypto`'s `sha3-256` is
a *different* function from keccak-256 (same permutation, different padding), so reaching for
it would produce a check that fails on correct data. Until something here needs keccak for
another reason, the trade is: one recorded conversation, cross-checked three ways.

### The answers that are NOT immutable, and are marked

`manifest.json` gives every call a `kind`, because two of them are not facts about a
finalised block and a reader is owed that distinction rather than left to find it:

- `tip-dependent` (2 calls) — `eth_blockNumber` and `eth_getBlockByNumber ['finalized', …]`.
  They describe the chain's tip. They were true when recorded and are stale now. The
  producer needs an answer, and these are the ones it got; `window.tip` and
  `window.finalized` in the published tree are therefore readings taken at `recordedAt`.
- `endpoint-identity` (2 calls) — `web3_clientVersion` and the blind-proxy control
  `thisMethodDoesNotExist`. These describe the endpoint that was asked, not the chain, so
  re-recording against a different endpoint legitimately changes them.
- `immutable` (468 calls) — everything else: the block, the bodies, the receipts, the
  account state at the fork height, the two `eth_getProof` boundary probes.

One recorded answer is an **error**, and it is load-bearing rather than a defect:
`eth_getAccountInfo` answers `-32601 method is not available`. alloy probes that combined
account read and falls back to `eth_getBalance` + `eth_getTransactionCount` +
`eth_getCode`; the offline replay has to answer the same refusal or the client will not take
the same path. Arm 30 of the selftest holds every recorded refusal to that one class
(`-32601`, a capability the endpoint does not have) and requires that no policy or transport
refusal — a rate limit, a timeout — was ever recorded, because those replay forever.

### Size, stated rather than discovered

| | |
|---|---|
| calls | 472 (473 files, counting `manifest.json`) |
| working-tree bytes | 2,402,791 (2.29 MiB) |
| largest single file | 687,735 B — `eth_getBlockReceipts` for a 208-transaction block |
| repository growth (per-blob zlib) | ~579 KB |
| what it replaces | an 81,920-byte container and a 534,664-byte snapshot tree |

**The inputs are larger than the artefacts they produce.** `eth_getCode` is 1,011,666 of the
2.2 MB across 78 calls, and that is the cost of the declared `replay-preceding` prestate
strategy: reaching index 8 means re-executing indices 0..7, which faults in the code of every
account those eight transactions touch. The full block is another 353,463 B and cannot be
pruned to the nine bodies the replay reads, because the producer enumerates the whole block —
208 rows, traced or not, which is what makes the yield denominator the block.

That is a real cost and the trade is deliberate: 579 KB of repository, once, in exchange for
a capture that runs in 9 seconds offline instead of 3 minutes against a public endpoint, in
CI, in a hermetic `nix build`, and in two years when somebody needs to know whether a change
to the producers moved the result.
