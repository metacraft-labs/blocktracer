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
