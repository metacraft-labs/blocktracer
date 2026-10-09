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
| Program | `fixtures/trace/noir_space_ship/sources` (package `zk_shields`), vendored from `codetracer/test-programs/noir_space_ship` |
| Recorder | `nargo trace`, from a Nix build |
| Version | `nargo 1.0.0-beta.26`, `noirc 1.0.0-beta.26+unknown` — the binary self-reports `git version hash: false` |
| Recorder pin | `/nix/store/ps7kg504y4hw4jns6c6ccsy5jfmmq71s-Noir` |
| Container | CTFS `.ct`, **container version 5 / `meta.dat` schema 6**, 102400 bytes (100 KiB) |
| Recording workdir | `/tmp/blocktracer-fixture-rec/noir_space_ship` |

**RE-RECORDED at the 2026-10 trace-format revision, and the reason is that
nothing current could read the previous bytes.** The former container was at
container version 4 / `meta.dat` schema 3 and `ct-print` refused it:
`meta.dat: schema version 3 is not supported; this reader reads version 6 only`.
That refusal is a correctness refusal and not a deprecation — schema 3 packed
line-only step positions one line HIGHER than schema 4 on, and nothing else in
the container distinguishes them, so a reader that answered would place every
step one line high and report success. No gate widening reaches it; re-recording
is the route `ctfs-container.md` §2 prescribes. The recorder's provenance (its
derivation and both of its sources, including the `codetracer-trace-format-nim`
revision) is in `fixtures/trace/tour/README.md` under "The recorder pin" — the
two corpora are recorded by the same binary, which is the point of naming it.

`shield.nr` drives its whole simulation through `remaining_shield -= damage` and
`remaining_shield += regeneration` inside a `for` loop, and an older tracer
silently did not record those writes — a trace from one would step through the
loop with the shield value frozen. **Re-measured in these bytes:** 1105
observations of `remaining_shield`, 21 distinct values, **28 adjacent
transitions** (so 29 writes of a new value counting the first). The previous
reading said "29 distinct transitions" without stating which of those it
counted; the three figures are given here so the next reader does not have to
guess.

## What the trace contains

Verified with `ct-print` (`codetracer-trace-format-nim`), verbatim:

```
steps: 1315   calls: 81    values: 1315   io_events: 70
paths: 3      functions: 7 types: 6       varnames: 22
```

- **`calls` and `functions` each read one higher than the program's own count**,
  because the 2026-10 writer wraps every recording in a synthetic `<toplevel>`
  frame at depth 0 whose only child is `main`. Measured: the function table is
  `["<toplevel>", "main", "iterate_asteroids", "calculate_damage",
  "calculate_remaining_shield_pct", "calculate_shield_regeneration",
  "status_report"]` — the six program functions the previous reading counted,
  plus the frame. `src/blocktracer/demo/generator.nim`'s `traceFrames` carries
  the reader's 81, as its own comment requires.
- **`types` fell 8 → 6** (`["None", "Field", "Array<8, ..>", "u32", "()",
  "Bool"]`). The same drop happened in all nine tour programs and there it was
  measurable as the writer no longer interning unnamed `type_N` placeholder
  entries; no type NAME was lost.
- **Max call depth 3 for the program** — `main` → `iterate_asteroids` →
  `calculate_damage` → `calculate_remaining_shield_pct`. `ct-print` reports a
  maximum `depth` of 4, which is that chain under the `<toplevel>` frame.
- **All 22 variables are observed**, 1234 of the 1315 steps carry variable state
  — both re-measured and both unmoved.
- **70 stdout events**, ending with `shields will not hold as expected` — the
  last `io` event's text, re-measured and unmoved.
- Steps are **column-aware** (`has_column_aware_steps`), so column breakpoints and
  column motions work. NOT RE-MEASURED at this revision.

`steps`, `values`, `io_events`, `paths` and `varnames` are unchanged by the
re-recording. What moved is `calls`/`functions` (the frame), `types` (the
writer's interning) and the byte size (the writer's layout) — the same
separation the tour's nine programs show, and the one
`codetracer-specs`' `CTFS-Reader-Revision-Rollout` CRR-4 measured independently
on a third recording.

This is enough to demonstrate stepping, variable inspection, the call tree and
flow/omniscience on a real execution.

## Sources ARE in the container now, and `sources/` stays anyway

`ct-print --full` reports **three** populated `source_views` — `std/lib.nr`
(4392 bytes), `src/main.nr` (1610) and `src/shield.nr` (2823). The previous
recorder predated noir@`6939457ff7` (*embed the compiled source text in the
`.ct` container*) and reported `source_views: []`; this one embeds the text.

`sources/` is **kept** regardless, and so is the generator's `sources.json`
(Trace-Artifacts.md §3: *"optional: source bundle reference or inline sources"*).
Nothing was changed to read the embedded views instead, and teaching the
generator and the viewer to prefer them is separate work, not a consequence of
re-recording. Removing `sources/` on the strength of the embedded text without
first moving those readers would break the demo.

## Reproducing

```sh
NARGO=/nix/store/ps7kg504y4hw4jns6c6ccsy5jfmmq71s-Noir/bin/nargo   # THE PIN
mkdir -p /tmp/blocktracer-fixture-rec/out          # REQUIRED — see below
cp -R fixtures/trace/noir_space_ship/sources /tmp/blocktracer-fixture-rec/noir_space_ship
cd /tmp/blocktracer-fixture-rec/noir_space_ship
"$NARGO" trace --out-dir /tmp/blocktracer-fixture-rec/out
cp /tmp/blocktracer-fixture-rec/out/zk_shields.ct \
   <blocktracer>/fixtures/trace/noir_space_ship/zk_shields.ct
```

The sources are copied from **this directory's own `sources/`**, not from a
`codetracer` checkout. That is where they are vendored, it is what the recorded
`workdir` names, and it is what makes this reproducible without a sibling repo.

`nargo trace` writes nothing into the package directory, so the source tree stays
clean and can be a read-only checkout.

**Two tracer caveats found while recording this fixture (2026-08-28):**

1. ~~**`--out-dir` must already exist.**~~ **NO LONGER TRUE at the 2026-10
   recorder** — measured: pointed at a missing `--out-dir` it answers rc 0 and
   `Saved trace to .../nonexistent`. The `mkdir -p` above is kept because it
   costs nothing and keeps the command working against an older binary. What
   the old recorder did, for the record: it did not create the directory and did
   not fail gracefully — it panicked and aborted:

   ```
   Error: trace writer failed to begin writing CTFS container: failed to create
   streaming CTFS container at .../out/zk_shields.ct: failed to open streaming file
   Location: tooling/tracer/src/tracer_glue.rs:45
   fatal runtime error: failed to initiate panic, error 5, aborting
   SIGABRT: Abnormal termination.
   ```

   The `mkdir -p` above was load-bearing then and is belt-and-braces now.

2. **`nargo trace` output is NOT byte-deterministic.** **RE-MEASURED at the
   2026-10 recorder**, because this is the whole reason the container is
   committed and a figure from a retired recorder would not support it: two runs
   of the same program at the same binary produce two 102400-byte containers
   that differ in **22 bytes** — a **UUIDv7 recording id** in the `CTMD`
   (meta.dat) block. Everything else — the whole trace body, all 1315 steps and
   81 calls — is byte-identical. The embedded `workdir` string also varies with
   where you ran it, which is why the command above pins it.

   ```
   run 1: 01a107a4-e18b-7509-aed5-51fb66475d2f
   run 2: 01a107a4-e639-7b48-b6ed-0f434c673ec9
   ```

   **This is why the container is vendored rather than regenerated at build time.**
   M5c requires byte-identical `.ct` containers for a given seed; a generator that
   shelled out to `nargo trace` could not satisfy that. Checking the bytes in makes
   the demo tree a usable regression fixture. Re-record deliberately, not on every
   build, and expect the recording id to change when you do.
