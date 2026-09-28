# Replay toolchain artefacts — the four inputs, by content

Every historic replay needs four inputs that are **not** in this repository, and
for three of them a wrong-but-plausible copy exists on a developer machine. Each
one below is identified by content and by a **distinguishing structural fact**
that a byte count alone would not catch, because the copies differ by kilobytes
and fail in ways that read as unrelated bugs.

Measured 2026-09-28 on darwin-aarch64.

## 1. `avm.wasm` — must be the `--import-memory` build

| | value |
|---|---|
| source | `infra`, `services/blocktracer-ingest/avm-wasm.json` — read it as **`git show origin/live:services/blocktracer-ingest/avm-wasm.json`** |
| url | `https://github.com/metacraft-labs/aztec-avm-runtime/releases/download/avm-wasm-41af520a/avm.wasm` |
| bytes | 1,565,773 |
| sha256 | `41af520a72939affdd9cc1287f8d61a58e216e126a11f7c824cadcc3e4b905a7` |
| **distinguishing fact** | **12 imports, one of which is `env.memory`** |
| preset | `wasm-avm` (`build-wasm-avm`), aztec_packages `ee3c0528`, staged 2026-09-08 |

**The wrong copy** is committed as `vm2wasm/avm.wasm` and is byte-identical in at
least five checkouts (`aztec-avm-runtime`, `bt-historic-replay-runtime`,
`avm-wasm-ci`, `.agent-wt/bt-frame-view-avm`, `scratch-chainhalf/...`):
1,259,737 bytes, sha256 `2ffcf9c00ab1a8c6…`, **11 imports, all functions, no
memory**. The host refuses it by name (`AvmToolchainRegression`), so this one
fails loudly.

Neither repository builds it: barretenberg's CMake calls `FetchContent_Populate`
at configure time, which a nix sandbox has no network for.

## 2. `aztec_ct_writer.wasm` — must export `ct_source_step`

| | value |
|---|---|
| source | `.agent-wt/bt-frame-view-avm/ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm` |
| bytes | 263,217 |
| sha256 | `8c4f36c6ff8cc80bc2c871894356d71dd093253e2d8d8d883564f144e72cde03` |
| **distinguishing fact** | **39 exports, including `ct_source_step`** |

**The wrong copy** is the one `aztec-avm-runtime` builds: 262,709 bytes, sha256
`4791f58c2edd9df6…`, **37 exports, no `ct_source_step`**. It is only 508 bytes
smaller and it **fails late** — the replay runs, hydrates, and dies with
`Error: ct_writer.wasm does not export ct_source_step()`, which reads like a
replay fault rather than a wrong file. `bt-historic-replay-runtime` carries the
symbol in `ct-writer/src/lib.rs` but ships no built wasm.

The difference is load-bearing: `ct_source_step` is the whole difference between
a source-level and a rung-3 capture.

**Verify by parsing the export section, not by grepping.** Nim-JS and wasm both
emit strings in forms a substring search finds or misses for the wrong reasons;
a 39-vs-37 export count is a fact, a `grep` hit is not.

## 3. Node — 24.19.0, or 22

`/nix/store/0n6wnabi4grafrkvnla0ip529rqp6yxp-nodejs-24.19.0/bin/node`.

System node on this laptop is v20.20.1 and **rejects the flag outright**
(`node: bad option: --experimental-wasm-exnref`). Per
`tools/chain/nix/default.nix`, node 22 also accepts it and the `--import-memory`
module runs on 22 *without* the flag, needing it only on 24 — `nodejs_22` is the
pin the devshell and the infra module use.

## 4. The replay runtime checkout — `dfb9ebe`

`metacraft-labs/aztec-avm-runtime` @ `dfb9ebe23246759f87a4503f35da51dfb2485050`,
the commit `tools/chain/measurements/historic-replay-yield.json` records as its
`runtimeCommit`. **Distinguishing fact: it has `replay/src/artifact_resolution.ts`.**
The `aztec-avm-runtime` working checkout is on `dev` (`86c36ad`) and does not.

`npm ci` in `replay/` (545 MB) is required; there is no vendored tree.

---

## The rule these four share

Every one of these was, at some point today, looked for in a **local working
checkout** and found in a wrong version there. The working copies are not the
artefact store. A pinned release with a recorded hash is a source; a file in a
sibling worktree is a guess. Read `git show origin/<mainline>:<path>` rather
than the working tree — the shared checkouts on this machine produced wrong
facts five separate times in one session.

---

# Assembly and publication: three traps, all measured

Recorded here because each one produces a *confident wrong result* rather than an
error, and none is visible from the symptom.

## 1. Publishing chain B erases chain A from the registry

Measured: publishing `aztec` then `aztec-testnet` into one bucket left the store's
registry naming only `aztec-testnet`. All 102,689 of `aztec`'s blocks were still
present and fetchable by hash — and invisible, because the registry is the only
object that lists a chain.

`registry/**` classifies as `ocPointer` → `stUnconditional`, "always (re)write",
and the key carries no chain segment. `ingest.nim` **does** merge a registry and
its own comment names this hazard, but it merges *within one tree*
(`cfg.outDir/registry`). Two chains ingested into two trees each produce a
registry holding one chain, and the second publish overwrites the first. The seam
was right; it was at the wrong level.

**So: ingest every chain into ONE shared tree, then publish that tree.** Verified —
a shared tree yields `chains: aztec, aztec-testnet` and survives publication.

`publishTree` now refuses both shapes before any write (§2.2a):
`assertNoUnknownGlobalPointer` catches a *new* global unconditional key, and
`assertRegistryKeepsKnownChains` catches a registry that drops a chain the store
already holds. Latent members of that class today: `idx/**/meta.json` and
`index.html` / `sitemap.xml` / `robots.txt` — global, unconditional, and already
emitted by the demo generator, though not by a chain producer.

## 2. `--probe-floor` on a re-merge silently does nothing

`mergeSnapshots` takes the union's window from the range with the newest
`provenance.capturedAt` — "the only moment any of it is true of". So passing
`--probe-floor` to a run that *reuses* covered ranges changes no window at all:
the flag is honoured, the probe runs, and the merged snapshot keeps whatever the
newest existing range said. The tree then publishes `reach: windowed` with a
tip-sized `historyFloor` over a genesis-to-tip corpus.

**The fix is to add one new 1-block range at the tip with `--probe-floor`.** It
becomes the newest snapshot and its window wins the merge. Verified: the merged
window moved to `replayableFrom: 1, blocks: 99430`, and the registry row to
`reach: floor, historyFloor.height: 1`.

Do **not** reach for `--refetch` on an existing range to achieve this. Refetching
rewrites that range's snapshot without replaying, so every row in it reverts to
untraced and its containers are left unreferenced.

## 3. Publish-then-prune breaks re-ingest, via the generation maps

The obvious streaming shape — publish a range, delete its `ct/`, advance — does
not work against this ingest, and the reason is two steps away from the symptom:

* `ingest.nim:1792` reads each container with an **unguarded `readFile`**, so a
  snapshot row naming a pruned container aborts the ingest.
* the whole-chain generation maps (`d/{chain}/g/{gen}/**`) are **singletons
  rebuilt from the union of covered ranges on every publish**.

So pruning containers and then publishing another range rebuilds the maps from
whatever survives — the `--no-merge` hole, self-inflicted, and silent: the objects
stay in the store and stop being listed.

Keeping the per-range **snapshots** (121 MB for all of mainnet's metadata) and
pruning only `ct/` preserves the union the maps need, but does not fix the
`readFile`. **Prerequisite for streaming: ingest must tolerate an absent container
whose object is already published.** That is its own piece of work and it is not
optional — it is what stands between "one tree that fits on disk" and "a corpus
that does not".
