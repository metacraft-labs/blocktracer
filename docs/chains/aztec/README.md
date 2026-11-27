# Aztec ingestion — where it runs, what state it is in, what is left

**Read this first if you are asked to work on Aztec ingestion.** It exists because
on 2026-11-26 an agent spent a day building a GitHub Actions cron to do a job a
deployed NixOS service was already doing, while a comment that agent had written
itself said "the infra unit lists it in `SuccessExitStatus`". Nothing in the repo
said where ingestion ran. Now it does.

Network-specific facts — why the chain restarts from genesis, and what that voids
— are in [`../../AZTEC-NETWORK-GENERATIONS.md`](../../AZTEC-NETWORK-GENERATIONS.md).
Read that too; it is not optional background.

## Where ingestion runs

**Not in this repo and not in CI.** It is a resident systemd service:

| | |
|---|---|
| defined in | `infra`, `services/blocktracer-ingest/default.nix` |
| instantiated by | `infra`, `machines/server/high-mem-server/configuration.nix` — `mcl.blocktracer-ingest.{aztec-mainnet,aztec-testnet}` |
| host | **high-mem-server** |
| follow unit | `blocktracer-ingest-<chain>.service` — `wantedBy=multi-user.target`, `Restart=always`, internal poll `--interval 60`, recycles on `--deadline-min 360` |
| publish unit | `blocktracer-ingest-<chain>-publish.service`, oneshot on a **120 s** `OnUnitInactiveSec` timer |
| metrics | `…-metrics.service` + timer, Prometheus textfile; alert rules in `services/monitoring/rules/mcl-blocktracer-ingest.yml` |
| concurrency | a **per-chain lease** with staleness takeover — two writers must never own a chain |
| bucket | R2 `blocktracer-ingest-prod`, credentials via agenix on the host |
| state | `/build/blocktracer-ingest/<chain>/{snapshots,uploaded}/<chain>` |

**The tool it runs is `tools/chain/follow-chain.mjs`**, with `--interval` and
`--until`. It is *not* `follow-to-tip.mjs`, which does not exist at the deployed
revision. Both share `tools/chain/lib/replay.mjs` and `lib/refusal.mjs`, so a
change to the replay/refusal layer reaches the service and a change to
`follow-to-tip.mjs` does not.

## How a change reaches production — three hops, and they are slow

```
agents  →  dev (promotion PR)  →  live (merge)  →  infra flake bump  →  pull-based deploy
```

`infra`'s input is `blocktracer.url = "github:metacraft-labs/blocktracer/live"` —
it tracks the **live** branch. So **merging to blocktracer `live` is deploying,
not promoting.** As of 2026-11-26, `live` is `80f15c88` and has not moved since
2026-11-03.

The service consumes these flake outputs: `chain-tools`,
`chain-follower-nodejs`, `chain-runtime`, `aztec-ct-writer-wasm`,
`fixture-container-tools`.

## State on 2026-11-26

**The service had been dead for two days and is now running.** Both follow units
crash-looped from 2026-11-24 02:23 on
`mkdir: cannot create directory '<stateDir>/snapshots': Permission denied`.
Cause, in systemd's own words:

> Detected unsafe path transition /build (owned by zahary) →
> /build/blocktracer-ingest (owned by blocktracer) during canonicalization of
> build/blocktracer-ingest/aztec-testnet.

`systemd-tmpfiles` declines a subtree whose ownership transitions from a human to
a service user, so the per-chain dirs never got their declared
`0750 blocktracer blocktracer`. **The control that proves it:** `logDir` is
declared in the same rule list with the same owner and mode and came out correct
— because `/var/log/mcl` has a root-owned parent. I applied the declared
ownership by hand; the durable fix is a PR to infra `live` adding
`ExecStartPre=+ install -d` to all three units.

**Production still serves the retired v5 corpora** — `aztec` head 102,690,
`aztec-testnet` head 99,092 — while live v6 tips were 60,712 / 69,632. It has not
advanced because there is nothing to publish:

```
first live window after the fix:  transactions 16, replayed 0, refused 16,
                                  tracesPublished 0, uploaded/ 0 files
```

**Publish timers are deliberately STOPPED** (operator's instruction: no point
uploading refusal-only data). 0 files were ever uploaded, so production was never
polluted. Re-enable with
`systemctl start blocktracer-ingest-<chain>-publish.timer` once traces exist.

## Why the deployed service still traces NOTHING — `live` pins the PRE-V6 runtime

**Measured 2026-11-27, and this is the whole explanation for production.** After
24 hours of the follower running on high-mem-server, `aztec-testnet`:

```
blocks 4,503   transactions 4,043   refused 3,327   replayed 0   tracesPublished 0
```

Zero. Not the 45.7% a rehearsal measured — **total**. And the cause is a **pin**,
not the AVM crash and not an ABI mismatch:

| | |
|---|---|
| blocktracer `live` = `80f15c88` pins | `aztec-avm-runtime = 238a3a5b9fe9346868cc7fab84a8aa54513287dd` (`flake.nix:147`) |
| what that revision is | the **pre-v6** runtime — on `agents` the same SHA is bound to `aztec-avm-runtime-historical`, kept for the committed v5-era transcripts ONLY |
| and at `live` | there is **no `-historical` sibling**. The v5 runtime *is* the follower's runtime. |
| `agents` binds for the follower | `9e9ba381`, which decodes v6 |

So the deployed follower runs a v5 decoder against a v6 chain and refuses every
transaction **by name, before reaching the AVM at all** — the `field modulus`
family, the same wall
[`../../AZTEC-NETWORK-GENERATIONS.md`](../../AZTEC-NETWORK-GENERATIONS.md) records
for every pre-rename `@aztec/stdlib`. Measured by the crash session;
`~/avm-crash-arch/REPORT.md` §6 on arch.

**Good news for the campaign: the deploy chain is the fix, not more code.** The
three hops above carry a rehearsal measured at **80.4% replay-and-match, 0
divergent**, with the 43 L1→L2 transactions becoming named refusals.

**THE TRAP, recorded because I walked past it twice while holding the fact.**
`238a3a5b` is *correct* as `aztec-avm-runtime-historical` and *catastrophic* as
`aztec-avm-runtime`. One SHA, two roles, distinguished only by which input name it
is bound to — so grepping for the SHA finds it legitimately pinned and concludes
the pin is fine. **Check the input NAME, and check whether `-historical` exists as
a separate input on the revision in front of you.**

## The crash, named and fixed; the revert divergence, named and refused


**What it was.** The exit 139 was a **Node.js/V8 bug**, not the AVM module.
- On node 22.21.1 and later, which includes the follower's 22.23.2, avm.wasm's
  `fd_write` goes through node:wasi's V8 fast API callback.
- uvwasi's allocation inside that callback can start a full GC.
- The GC's stack walk then segfaults in `InnerPointerToCodeCache::GetCacheEntry`.

A 151-byte wasm module with no Aztec code reproduces it on the official node
binaries. The entry is reprobuild-pm `upstream-bugs/node-wasi-fast-call-gc-segfault`:
it is ready to file as a comment on nodejs/node#46777 and not submitted. The old
reproducer, block 69,236's `0x0a0f4e7c…`, still holds: `9e9ba381` exits 139.

**The fix** is aztec-avm-runtime `6c28eb93` (#25), pinned by this repository's
`aztec-avm-runtime` input:
- node-host's loader turns V8 fast API calls off (`--no-turbo-fast-api-calls`)
  before any module is compiled;
- the driver runs under a crash guard. A later signal death prints
  `RuntimeCrashed: … killed by SIGSEGV …`, and `decideOutcome` rule 2a files it
  as `runtime-crashed` with the signal as evidence, just as it files a signal
  Node reports directly.

**Measured: a rehearsal, nothing published.** Two followers ran side by side on
arch over the same live testnet window on 2026-11-26, 17:05–19:07Z. Each was the
production follower exactly as `services/blocktracer-ingest` runs it: node 22.23.2,
`avm-wasm-0f2fb11e`, `--compact-threshold 1073741824`, with a scratch snapshot.
635 transactions were common to both arms, over blocks 70,127–70,819.

| | `9e9ba381` (`agents` before) | `6c28eb93` (this pin) |
|---|---|---|
| replayed and reproduced | 137 | **222** |
| `runtime-crashed` (SIGSEGV) | **124** | **0** |
| divergent | 1 | 43 |
| `runtime-refused`: `ModuleRefusedReplay` (nullifier collision) / `HydrationDidNotConverge` | 8 / 3 | 8 / 3 (the same transactions) |
| pruned / private-only / not-first-in-block | 211 / 116 / 35 | 209 / 116 / 35 |

Of the 124 that crashed before, **81 now reproduce, 42 now diverge**, and 1 was
pruned before the second arm reached it. Of the transactions this pipeline
attempts, 222 of 276 (80.4%) now reproduce, against 137 of 273 (50.2%).

**The revert divergence: an L1→L2 message the replay could not hold.** All 43
divergences above were bridge claims on two contracts (`0x02b76743…`,
`0x201aa740…`): published `revertCode 0`, replayed `1`, effects 1/21. Each one
consumes an L1→L2 message. The AVM's `L1TOL2MSGEXISTS` read the runtime's L1→L2
message tree, which hydration cannot seed (append-only, and the runtime's hint
carries the index but not the message hash). The read answered "absent", the
claim's assert failed, and the replay reverted where the chain did not.

**Now refused by name, not published as traces.** aztec-avm-runtime `abd5aade`
(#26), pinned here, refuses a converged run that read that tree
(`L1ToL2MessageReadUnanswerable`). `lib/refusal.mjs` files it as the eleventh
member, `l1-to-l2-message-unseedable` (repairable), and `decideOutcome` rule 2b
words the row: the transaction consumes an L1→L2 message, the leaf it read, and
that this is not a statement about the transaction.

Re-measured on arch on 2026-11-26. Every attempted row of the rehearsal's
`6c28eb93` arm was re-run through this repository's `replayTransaction` with
`abd5aade`, node 22.23.2 and `avm-wasm-0f2fb11e`, with nothing published:

| attempted rows (276) | `6c28eb93` | `abd5aade` (this pin) |
|---|---|---|
| replayed and reproduced | 222 | 222 (the same transactions) |
| divergent | **43** | **0** |
| `l1-to-l2-message-unseedable` | — | **43** (the same 43) |
| `runtime-refused`: `ModuleRefusedReplay` / `HydrationDidNotConverge` | 8 / 3 | 8 / 3 (the same transactions) |

Replaying them instead needs a source for the message hash. That is upstream
work, drafted and not filed.

## What the deploy will deliver — measured twice, denominators stated

**Independent re-measurement 2026-11-27**, arch, blocktracer `agents` `1ce0f2dd`
(runtime pin `abd5aade`, which *is* PR #26's merge commit, with #25's merge commit
`6c28eb93` an ancestor), 300 blocks of `aztec-testnet` (73,563–73,862), fetch +
replay, `--no-publish`. This is the second independent measurement; the first was
the crash session's.

```
blocks 300   transactions 291   replayed 213   refused 38
private-only 18   not-first-in-block 22   pruned 0   divergent 0
```

**THE HEADLINE IS NOT THE RATE — IT IS THAT EVERY REFUSAL IS NAMED.** Zero
unnamed, against 104 of 105 before the fixes:

| refusal | member | count |
|---|---|---|
| `L1ToL2MessageReadUnanswerable` | `l1-to-l2-message-unseedable` | 24 |
| `HydrationDidNotConverge` | `runtime-refused` | 10 |
| `ModuleRefusedReplay` | `runtime-refused` | 4 |

The ten `HydrationDidNotConverge` are the specific proof of
[#25](https://github.com/metacraft-labs/aztec-avm-runtime/pull/25): the loop now
**reaches its own error** instead of the process dying before it can raise. The
cause was a GC inside `node:wasi`'s `fd_write` fast call — not a stall, not a
round cap, and not an ABI mismatch.

**THE RATE, AND ALWAYS WITH ITS DENOMINATOR**, because the same measurement reads
as two different promises:

| | |
|---|---|
| **73.2%** | 213 / 291 — *all* transactions |
| **84.9%** | 213 / 251 — *replayable candidates*, excluding 18 `private-only` and 22 `not-first-in-block` |

Quote **84.9% of replayable candidates with the exclusions named**: `private-only`
is a property of the chain (no public execution published) and
`not-first-in-block` of the historical-state mechanism (only transaction index 0
ever saw the parent state, and no node method serves the intermediate view).
Neither is a shortfall in this pipeline. A bare "80%" with no denominator is how a
measurement becomes a broken promise.

**STATE THIS EXPECTATION BEFORE GO-LIVE, NOT AFTER:** of those 213 recordings,
**zero** position any source step. All 213 carry an `artifacts` array — the
question is asked every time, 0 absent — 17 distinct addresses were interrogated,
none resolved, and **no protocol contract was entered in that window at all**. So
it is traffic mix, not a regression: FeeJuice frames were 8 of 119 recordings in
an earlier window and 0 of 213 here. **Source-level coverage on the site will be
sparse and intermittent.** Clause two of the campaign goal is satisfied in kind,
not in volume.

### Not yet verified: source rendering on the published site

The one clause-two claim with no evidence behind it is that a *page* on
blocktracer.org renders source where an artifact resolved. `aztec-testnet-frames`
is served (`gen=rframes00001`, head 69,361) and its published summary reports 26
blocks, 8 transactions and **0 refusals of every member** — so all 8 traced, and
that corpus is the right subject. What is missing is the last step: pull a real
transaction id out of the generation's own index (`blocks/0.json` is a list of
BLOCK hashes, so the transaction ids are elsewhere — try `root.json`) and read the
rendered page. Do **not** reconstruct a hash from an abbreviation in a note; I
tried and produced one that does not exist.

## Source-level coverage — satisfied in kind, limited by the chain

Over the same 300 blocks, **read the published `artifacts` array, never container
bytes**, and count **per contract address, not per transaction** (a transaction is
`sourceLevel` only if *every* contract resolved, so one unresolvable third-party
class hides a protocol frame that did):

- all 119 recordings carry an `artifacts` array — the question is always asked
- `0x…0003` **FeeJuice: 8 interrogated, 8 resolved**, `npm:@aztec-labs/protocol-contracts@6.0.0`, `corroboration: corroborated`, distributors `[aztecscan, npm]`, 32 source files
- nine third-party addresses: 56/18/17/17/17/16/16/4/1 interrogated, **0 resolved**
- 8 of 119 recordings position steps, each **79.6%** of its own; 0 fully `sourceLevel`
- 860 of 1,200,259 steps = **0.072%** — a statement about traffic mix, not capability

FeeJuice resolves because **the protocol pins magic addresses across a
redeployment**; every third-party address changed, so their artifacts are void.
Nothing here is a defect in our machinery.

## Open work

| | what | owner |
|---|---|---|
| 1 | ~~the AVM crash~~ **fixed** (aztec-avm-runtime `6c28eb93`). ~~the 43-of-276 revert divergence~~ **refused by name** (`abd5aade`, pinned here, as `l1-to-l2-message-unseedable`). Replaying them needs the L1→L2 message hash (upstream) | runtime |
| 2 | infra PR: `ExecStartPre=+ install -d` on all three units, so no unit depends on tmpfiles traversing a human-owned parent | this lane |
| 3 | relocating `stateDir` off `/build` to a root-owned parent — **the operator's storage call, not a bug fix**; `/build` and `/var/lib` are the same zroot pool, 8.8T free each | operator |
| 4 | the pin bump (3 hops above): blocktracer `agents` carries the fix; next are the agents → dev promotion, dev → live, and then infra's `blocktracer` input | manager → operator |
| 5 | generation-qualified publish keys, so v5 and v6 stop competing for one slug and `replace-chain-row` stops being the only answer | unassigned |
| 6 | re-enable the publish timers once traces exist | this lane |

## Dead ends — do not revive

- **`.github/workflows/chain-follow.yml`** (deleted, `370a589f`). A `*/15` cron
  publishing to the same bucket. It duplicated the leased service and did not take
  the lease, so it was one promotion from being a second unleased writer. Also
  could not meet "seconds or minutes": each tick re-ran `nix build`, re-fetched
  `avm.wasm` and rebuilt the Nim producer first.
- **`follow-to-tip.mjs` changes aimed at that cron** — `--start-at`, the
  absent-vs-lost-ledger exit code. The tool is kept for manual catch-up and dry
  runs; the service does not call it, so changes to it do not reach production.
