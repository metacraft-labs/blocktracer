# The one recording a current reader can open

This tree exists for a single reason, and it is worth stating plainly before anything
else, because the reason is a defect and not a feature:

**Every other recording in this repository is unreadable by every current reader.** All
52 real containers here declare `meta.dat` schema version 3. Every reader built from a
current checkout of `codetracer-trace-format-nim` accepts `[4, 5]` and refuses 3 **by
name** — a version-3 writer packed a line-only step position as
`prefixSum[path_id] + line` where a current writer packs `prefixSum[path_id] + (line - 1)`,
both land inside the trace's address space, so decoding a version-3 step under the current
rule returns it **one line high** instead of failing. Refusing is the only outcome that
does not silently mis-place every source position.

So a check that compares a container's own measurements against what the row claims about
it had **no subject in this repository**, and a check with no subject is a check nobody
can show fires. `tools/chain/chain-health.mjs` is where those comparisons live and
`tools/chain/chain-health-selftest.mjs` is where they are proved; this tree is the
committed subject both of them need.

## What it is NOT, stated first

- **It is not a chain recording.** No node served it, no transaction produced it, no
  replay driver wrote it. The snapshot around it is a real `blocktracer/chain-snapshot@2`
  document and it conforms, but its chain is named `readable-container` for the same
  reason the conformance template's is named `example-chain`.
- **It is not a re-recording of anything here.** The obvious candidate,
  `fixtures/trace/noir_space_ship/zk_shields.ct`, is real and source-level and is one of
  the 52 the reader refuses. Re-recording it needs `nargo trace`, which is not on this
  host; converting it needs a reader that accepts version 3 and writes version 4, and no
  such reader exists — the only one that could read it refuses it by name.
- **Its source text is a stand-in.** The bundle carries one file per interned path with a
  two-line placeholder body. The bundle's job here is to have the *right keys*, because
  what is checked is whether every path the container interned is present in the bundle;
  the text is not read by any check.
- **It is not byte-reproducible.** Measured: two runs of the generator below over the same
  tree produce the same 151,552 bytes and **different** sha256 (`81b1a3a2…` vs
  `6b86fa7a…`), because the recording id is a time-based uuid. That is why the container
  is vendored rather than generated at test time — the same doctrine
  `tools/chain/derive-instructions.mjs` states for the chain containers.

## How the container was made

In a sibling checkout of `codetracer-trace-format-nim`, inside **its own** devshell — a
plain `nim c` outside it fails on `zstd.h`:

```sh
cd ../codetracer-trace-format-nim
nix develop --command bash -c '
  nim c -d:release --mm:arc -p:src -o:/tmp/genfix tests/generate_ct_print_fixture.nim &&
  /tmp/genfix /tmp/readable.ct'
```

`tests/generate_ct_print_fixture.nim` is that repository's own multi-stream fixture
generator, written for its `ct-print` golden tests. Read at revision `cf132be`. It writes
a small v4 split-stream bundle: 2 interned paths, 2 functions, 10 varnames, 9 types, 10
steps walking both files, one outer call with one nested call, values across the
`ValueRecord` variants, one stdout and one stderr IO event.

The result was copied to `ct/<txHash>.ct` and renamed by the transaction hash, which is
this repository's convention (`snapshot.transactions[].container`, `§5.1`).

## How the two sidecars were made

Both were **read out of the container**, not written beside it:

```sh
../codetracer-trace-format-nim/ct-print --events \
  fixtures/chain-health/readable-container/ct/<txHash>.ct
```

The first line of that output is a header carrying the interned `paths`; every later line
is one event, and `"kind":"step"` lines carry `path_id`, `line` and `path`.

- `positions/<txHash>.json` is the step stream's `(path_id, line, column)` columns, with
  `schema: avm-source-positions/1` and `measuredPostHoc: false`, the same shape
  `tools/chain/derive-positions.mjs` writes.

  **One difference from every other positions sidecar here, and it is deliberate.**
  `derive-positions.mjs` DROPS interned path 0 and re-indexes, because the Aztec replay
  recorder interns a synthetic pseudo-path `/aztec/<txHash>.avm` first and files every
  step it could not place under it. This container interns no pseudo-path: index 0 is
  `/workspace/demo/main.py`, a real file with real steps on it. Dropping it would delete a
  positioned path and shift every remaining index by one — which is exactly the kind of
  value-level disagreement `H-POSITIONS-VALUE-SKEW` exists to catch, so getting it right
  here matters more than matching the other sidecars' shape.

- `sources/<txHash>.json` is one bundle whose `files` keys are exactly the container's
  interned paths, with `language: "python"` — the language the generator's paths and its
  own program name (`ct_print_demo`, `main.py`, `util.py`) state.

## Why the row's numbers are what they are

Every figure in `recording` is the container's own, and each one is the claim a check
compares against:

| `recording` member | container's own count | relation |
|---|---|---|
| `steps` 10 | `counts.steps` 10 | equal |
| `events` 10 | `counts.steps` 10 | equal — measured over the whole committed corpus, 42 of 42 rows carrying both members have `events == steps`, so the producer's `events` is a second copy of its step count |
| `callsOpened` 1 | `counts.calls` 2 | container is claim **+ 1** — the outermost frame is the synthetic top-level one, which `callsOpened` does not count. `src/blocktracer/chain/ingest.nim` refuses a call trace unless `frames == callsOpened + 1`, and `tools/chain/derive-calltrace.mjs` states the same with its two measurements |
| `pathsInterned` 2 | `counts.paths` 2 | equal |
| `stepsPositioned` 10 | 10 steps with a real path and a positive line | equal |

`declaredRung` is **1**, and that is the other thing this tree has that nothing else here
does: rung 1 is source text plus a file map, which every chain-fetched contract in this
repository is structurally denied — an Aztec node serves `ContractClassPublic`, which
carries packed bytecode and no debug symbols, so the ceiling for a chain recording here is
rung 3. This tree is at rung 1 because the writer had the source paths in hand, which is
also why it is the only `sourceLevel: true` row outside the conformance template.

## What depends on this tree

- `tools/chain/chain-health-selftest.mjs` drives the container-versus-claim and the
  source-versus-container checks against it, and asserts the figures above.
- `tools/chain/refusal-selftest.mjs`'s `ALL_COMMITTED_SNAPSHOTS` lists it. That list is
  compared to `git ls-files '*snapshot.json'` for equality, so a committed snapshot tree
  that is not in it turns that suite red — which is the intended cost of adding one.
- `just conformance fixtures/chain-health/readable-container` passes over it, which is
  what makes it a real snapshot tree rather than a fixture shaped like one.
- `tools/chain/byte-identity.sh` does **not** see it: that script's tree list is
  hardcoded, six rows, and this is not one of them. Nothing this tree does can move the
  published-object count.
