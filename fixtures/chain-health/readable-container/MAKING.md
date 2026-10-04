# The one recording a current reader can open — and it is RECORDED, not committed

This tree exists for a single reason, and it is worth stating plainly before anything
else, because the reason is a defect and not a feature:

**Every other recording in this repository is unreadable by every current reader.** The
census, re-measured on **2026-10-04** by reading byte 5 of each file and asking the real
`ct-print` what it found: this repository **tracks 55 `.ct` paths**, of which **52 are
containers** — the other three are the conformance kit's 229-byte ASCII placeholders,
carrying no CTFS magic at all, so they are not containers and no schema version can be read
off them. Of the 52, **42 declare container version 3 and 10 declare version 4, and all 52
declare `meta.dat` schema version 3.** The canonical reader built from
`codetracer-trace-format-nim` reads container version **5** and `meta.dat` schema **6**, and
refuses anything else **by name**.

**A CORRECTION, because the figure this campaign quotes is larger.**
`CTFS-Reader-Revision-Rollout.milestones.org` CRR-4 says "51 of `blocktracer`'s 78 committed
containers are at container version 3 and 26 at version 4, and 77 of the 78 carry `meta.dat`
schema 3". The shape of the finding is right and the population is not: there are **84 `.ct`
paths on disk and 55 of them are tracked**, so a census by `find` counts 29 GENERATED
artefacts — 25 published containers under `client/dist/` (ignored by `client/.gitignore`),
the three `conformance-kit-release/` copies of the template placeholders (ignored by
`.gitignore`), and this tree's own recorded container. The generated copies are copies of
tracked containers, so they do not change the conclusion; they do change the number, and
"committed" is the word the milestone uses.

And the sharper half, which this tree's own history is the proof of: **the field that
decides is the `meta.dat` schema, not the container version.** A version-3 writer packed a
line-only step position as `prefixSum[path_id] + line` where a current writer packs
`prefixSum[path_id] + (line - 1)`; both land inside the trace's address space, so decoding
a schema-3 step under the current rule returns it **one line high** instead of failing.
Refusing is the only outcome that does not silently mis-place every source position.

So a check that compares a container's own measurements against what the row claims about
it had **no subject in this repository**, and a check with no subject is a check nobody
can show fires. `tools/chain/chain-health.mjs` is where those comparisons live and
`tools/chain/chain-health-selftest.mjs` is where they are proved — **31 arms**; this tree
is the subject both of them need.

## WHAT CHANGED ON 2026-10-04, AND IT IS THE WHOLE POINT OF THIS FILE

**The container is no longer committed. It is recorded, at test time, by the test that
needs it.**

`tools/chain/make-readable-container.mjs` produces it from the sibling
`codetracer-trace-format-nim`'s own fixture generator, and
`chain-health-selftest.mjs` runs that before it probes the reader. Run it by hand with:

```sh
node tools/chain/make-readable-container.mjs
```

### Why, measured rather than argued

This tree used to commit a container, and the cost arrived on schedule. It was written on
2026-09-28 at container version 4 / `meta.dat` schema 4. On **2026-10-01** the canonical
writer moved to container version 5 / schema 6. From that moment a freshly built
`ct-print` answered the committed subject with

```
meta.dat: schema version 4 is not supported; this reader reads version 6 only.
Re-record the trace with a current recorder
```

and **all 31 reader-dependent arms stopped running** — silently until `18b7eec8` gave the
harness a third state (`reader-refusing`, distinct from `reader-absent`), and loudly but
still not running after it. A derived artefact committed beside the thing that derives it
is a clock, and that is what went off.

`metacraft-dev-guidelines/policies/repo-requirements.md` §4.3 is the policy and it
predicts exactly this: `*.ct` may be committed in **one** repo,
`codetracer-example-recordings`, and "everywhere else, a test that needs a recording
**records it on the fly**, so it cannot go stale against the recorder that produced it."
§4.3 is explicit that this is NOT a size rule — it measures that a 1 MB ceiling waves
through 19 of 20 committed recordings — because the objection is that the artefact is
**derived**.

**Re-recording would have reset the clock. Recording on the fly stops it.**

### What stays committed, and the line is measured and not asserted

| file | committed? | what it is a fact about |
|---|---|---|
| `ct/<txHash>.ct` | **no** | the WRITER's layout |
| `snapshot.json` | yes | the recording, plus one writer figure (below) |
| `positions/<txHash>.json` | yes | the recording |
| `sources/<txHash>.json` | yes | the recording |
| `MAKING.md` | yes | — |

Measured by regenerating the container at `codetracer-trace-format-nim` `7967c179` and
comparing it to what the committed sidecars already said:

- `positions/<txHash>.json` — the regenerated step stream's `(pathId, line, column)`
  columns are **identical, value by value**: `pathId` `[0,0,0,0,0,0,1,1,1,0]`, `line`
  `[1,2,3,4,5,6,1,2,3,7]`, `column` all `null`. **Zero disagreements.**
- `snapshot.json`'s `recording` — steps 10, events 10, callsOpened 1, pathsInterned 2,
  stepsPositioned 10, and the container's own `calls` 2 = `callsOpened + 1`. **Every one
  unchanged.**
- `sources/<txHash>.json` — the bundle's `files` keys are the container's two interned
  paths. **Unchanged.**

So the writer moved two container versions and a `meta.dat` schema, and **not one fact the
31 arms check moved with it.** That is the separation the policy predicts: the recording is
committable, the container is not.

### THE ONE FIGURE THAT CROSSES THE LINE, STATED RATHER THAN HIDDEN

`snapshot.json`'s **`containerBytes`** is required by `S5-CONTAINER-BYTES` to equal the
file's size on disk, and it is a property of the writer's LAYOUT rather than of the
recording: the same recording is **151,552 bytes** at the old revision and **77,824** at
the current one — a 48.6% change in which no step, no path and no call moved.

It stays committed, and the reason is an accounting one. A generated `snapshot.json` would
leave `git ls-files` and therefore leave `corpusSnapshotDirs()`, the committed reading at
`tools/chain/measurements/chain-health.json`, and `refusal-selftest.mjs`'s snapshot
census — four declared populations moved to avoid carrying one integer. Instead the
materialiser **and** the selftest each compare the recorded container's size against it, so
the residual is a red gate with both figures in the message:

```
the recorded container is N bytes and snapshot.json declares containerBytes 77824.
The writer's LAYOUT moved (no step, path or call did); update that one field and say why.
```

`provenance.recorder.traceSchema` moved with it, `ctfs-v4/meta.dat-v4` ->
`ctfs-v5/meta.dat-v6`, for the same reason and in the same diff.

### The size is reproducible and the bytes are not, and the old file had that backwards

Two runs of the generator at one revision: **77,824 bytes both times**, differing in
exactly **19 bytes at offsets 49,177..49,200** — the time-based uuid inside `meta.dat`'s
recording id, and nothing else.

The previous version of this file gave irreproducibility as the reason the container was
vendored rather than generated at test time ("two runs … produce the same 151,552 bytes and
**different** sha256"). The observation was right and the conclusion was wrong: the
irreproducibility is 19 bytes of uuid, the SIZE is stable, and `snapshot.json` carries no
container hash — only `containerBytes`. There was never anything here that generation
could not satisfy.

### Cost per run, measured

| step | wall |
|---|---|
| the generator binary is fresh: generate + move into place | **0.2 s** |
| it is absent or stale: `nix develop` + `nim c` + generate | **~30 s** |

The BUILD needs the sibling's own devshell — a plain `nim c` fails on `zstd.h`, and
`pkg-config` is not on `PATH` outside it, so `ct_print_binary.nim`'s pkg-config route is not
available from this repository. RUNNING the built binary does not need the shell, which is
what keeps the steady state at 0.2 s.

The cache is dated against the sibling's **whole `src/`**, not against the generator's own
source. Ported from `codetracer-trace-format-nim/tests/ct_print_binary.nim`, whose header
says why: the generator is a thin front end over the writer library, so a binary dated
against one file answers "fresh" for a build that predates a writer change, and the arms
then measure a container no revision in the tree produces.

### Three states, never two

| state | exit | what a caller does |
|---|---|---|
| the sibling is not checked out | 2 | **SKIP**, naming what is missing |
| it is here and would not produce a container | 1 | **FAIL** — a break, not an absence |
| it produced the container | 0 | assert the content |

Exit 2 is the state CI is in: `codetracer-trace-format-nim` is not a dependency of this
repository and is not built here, so the 31 arms do not run there and the suite says so with
a figure on it. That is unchanged by this work — what changed is that on a host which HAS
the sibling, they now run.

## What it is NOT, stated because every line of it still holds

- **It is not a chain recording.** No node served it, no transaction produced it, no
  replay driver wrote it. The snapshot around it is a real `blocktracer/chain-snapshot@2`
  document and it conforms, but its chain is named `readable-container` for the same
  reason the conformance template's is named `example-chain`.
- **There is no blockchain input data here at all**, which is why §4.3's second exception
  (immutable blockchain inputs in a dedicated fixtures repo) does not apply and does not
  need to. The generator's inputs are hard-coded in its own source: two paths, two
  functions, ten varnames, nine types, ten steps, one nested call, values across the
  `ValueRecord` variants, one stdout and one stderr IO event. There is nothing to separate
  because there is no input to commit.
- **It is not a re-recording of anything else here.** The obvious candidate,
  `fixtures/trace/noir_space_ship/zk_shields.ct`, is real and source-level and is one of
  the 52 schema-3 containers the reader refuses. Re-recording it needs `nargo trace`,
  which is not on this host; converting it needs a reader that accepts schema 3 and writes
  schema 6, and no such reader exists — the only one that could read it refuses it by name.
- **Its source text is a stand-in.** The bundle carries one file per interned path with a
  two-line placeholder body. The bundle's job here is to have the *right keys*, because
  what is checked is whether every path the container interned is present in the bundle;
  the text is not read by any check.

## How the container is made

`tools/chain/make-readable-container.mjs` runs, in a sibling checkout of
`codetracer-trace-format-nim` and inside **its own** devshell:

```sh
nim c -d:release --mm:arc -p:src --hints:off --warnings:off \
  -o:/tmp/bt-readable-container/generate_ct_print_fixture \
  tests/generate_ct_print_fixture.nim
```

and then the resulting binary, with the destination path as its one argument.
`tests/generate_ct_print_fixture.nim` is that repository's own multi-stream fixture
generator, written for its `ct-print` golden tests. It writes through
`MultiStreamTraceWriter`, which is why the container follows the writer's current revision
without this repository knowing anything about container layout.

The output is written to `ct/<txHash>.ct.recording` and renamed into place, so a generator
that fails half way through cannot leave a short container behind for the next run's
freshness check to accept.

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

**Neither needed re-deriving when the container was regenerated**, and the table above is
the measurement that says so.

## Why the row's numbers are what they are

Every figure in `recording` is the container's own, and each one is the claim a check
compares against. Re-read out of the regenerated container, 2026-10-04:

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
  source-versus-container checks against it, and asserts the figures above. It calls the
  materialiser itself, so there is no manual step before `just chain-selftest`.
- `tools/chain/refusal-selftest.mjs`'s `ALL_COMMITTED_SNAPSHOTS` lists it. That list is
  compared to `git ls-files '*snapshot.json'` for equality, so a committed snapshot tree
  that is not in it turns that suite red — which is the intended cost of adding one. The
  container leaving `git` does not affect it: `snapshot.json` is still tracked.
- `just conformance fixtures/chain-health/readable-container` passes over it, which is
  what makes it a real snapshot tree rather than a fixture shaped like one. It needs the
  container, so run the materialiser first on a fresh checkout.
- `tools/chain/byte-identity.sh` does **not** see it: that script's tree list is
  hardcoded, six rows, and this is not one of them. Nothing this tree does can move the
  published-object count.
