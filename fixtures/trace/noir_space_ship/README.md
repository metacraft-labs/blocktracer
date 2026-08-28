# `noir_space_ship` — the real demo trace

`zk_shields.ct` is a **real CTFS container produced by `nargo trace`** from the
`noir_space_ship` test program. It is not a stand-in, and it is not hand-written.
It replaced the earlier `fixtures/trace/minimal_trace.ct` stand-in (the `factorial`
fixture), which is deleted.

The container is named `zk_shields.ct` because the Noir package's `name` is
`zk_shields`; the *program directory* is `noir_space_ship`. Same program.

## Provenance

| | |
|---|---|
| Program | `codetracer/test-programs/noir_space_ship` (package `zk_shields`) |
| Recorder | `nargo trace`, Noir tracer fork branch `codetracer` |
| Version | `nargo 1.0.0-beta.26`, `noirc 1.0.0-beta.26+906af2f42d6b874cf0f5dde193accb1e39e1bcd3` |
| Container | CTFS `.ct`, 147456 bytes (144 KiB) |
| Recording workdir | `/tmp/blocktracer-fixture-rec/noir_space_ship` |

Commit `906af2f42d` ("fix(debug): record compound assignments and while/loop
bodies") matters for *this* program specifically: `shield.nr` drives its whole
simulation through `remaining_shield -= damage` and `remaining_shield +=
regeneration` inside a `for` loop. Before that fix those writes were silently not
recorded, so a trace taken from an older tracer would step through the loop with
the shield value frozen. This container records 29 distinct `remaining_shield`
transitions, so the fix is observable in the bytes.

## What the trace contains

Verified with `ct-print` (`codetracer-trace-format-nim`):

```
steps: 1315   calls: 80    values: 1315   io_events: 70
paths: 3      functions: 6 types: 8       varnames: 22
```

- **Max call depth 3** — `main` → `iterate_asteroids` → `calculate_damage` →
  `calculate_remaining_shield_pct`.
- **All 22 variables are observed**, 1234 of the 1315 steps carry variable state.
- **70 stdout events**, ending with `shields will not hold as expected`.
- Steps are **column-aware** (`has_column_aware_steps`), so column breakpoints and
  column motions work.

This is enough to demonstrate stepping, variable inspection, the call tree and
flow/omniscience on a real execution.

## Sources are NOT in the container

`ct-print --full` reports `source_views: []`. The container interns *path names*
(`src/main.nr`, `src/shield.nr`, `std/lib.nr`) and line/column positions, but it
carries **no source text**. A viewer given only `trace.ct` can step and show
variables but cannot show code.

That is why `sources/` is vendored alongside, and why the generator publishes a
`sources.json` next to each `trace.ct` (Trace-Artifacts.md §3: *"optional: source
bundle reference or inline sources"*). The demo needs the source text to be a demo.

## Reproducing

```sh
mkdir -p /tmp/blocktracer-fixture-rec
cp -R <codetracer>/test-programs/noir_space_ship /tmp/blocktracer-fixture-rec/
mkdir -p /tmp/blocktracer-fixture-rec/out          # REQUIRED — see below
cd /tmp/blocktracer-fixture-rec/noir_space_ship
nargo trace --out-dir /tmp/blocktracer-fixture-rec/out
```

`nargo trace` writes nothing into the package directory, so the source tree stays
clean and can be a read-only checkout.

**Two tracer caveats found while recording this fixture (2026-08-28):**

1. **`--out-dir` must already exist.** `nargo trace` does not create it and does not
   fail gracefully — it panics and aborts:

   ```
   Error: trace writer failed to begin writing CTFS container: failed to create
   streaming CTFS container at .../out/zk_shields.ct: failed to open streaming file
   Location: tooling/tracer/src/tracer_glue.rs:45
   fatal runtime error: failed to initiate panic, error 5, aborting
   SIGABRT: Abnormal termination.
   ```

   The `mkdir -p` above is load-bearing.

2. **`nargo trace` output is NOT byte-deterministic.** Two runs of the same program
   at the same commit differ in exactly 20 bytes: a **UUIDv7 recording id** in the
   `CTMD` (meta.dat) block. Everything else — the whole trace body, all 1315 steps
   and 80 calls — is byte-identical. The embedded `workdir` string also varies with
   where you ran it.

   ```
   run 1: 01a04a28-2135-708a-8e92-e2369bcb64e2
   run 2: 01a04a28-4433-73a1-80a6-5f712e7a6077
   ```

   **This is why the container is vendored rather than regenerated at build time.**
   M5c requires byte-identical `.ct` containers for a given seed; a generator that
   shelled out to `nargo trace` could not satisfy that. Checking the bytes in makes
   the demo tree a usable regression fixture. Re-record deliberately, not on every
   build, and expect the recording id to change when you do.
