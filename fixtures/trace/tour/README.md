# The Noir corpus — the capability tour, and the toolchain set beside it

Each directory here is one small Noir package. Nine of them carry the CTFS
container `nargo trace` recorded from them and make up the **capability tour**;
five more, under `toolchain/`, cannot produce a recording and are tests all the
same. `manifest.json` beside them says what each one
demonstrates and what its recording must contain.

This corpus replaces the arrangement where the `demo` chain served the single
`noir_space_ship` recording behind every transaction. That was a *fixture* —
something for tests and captures to render — and it made the demo chain a
worse answer to "what can this debugger show me?" than one program with a
loop in it.

## Why the corpus exists three times over

It has three consumers and one reason to stay correct.

1. **BlockTracer's `demo` chain.** One transaction per program, each carrying
   its own container bytes and its own published source bundle, so a visitor
   browsing by capability opens the program that demonstrates it.
2. **The shared CodeTracer ViewModels**, headless, on both backends. The
   expectations in `manifest.json` are written from the SOURCE — "`triangular(6)`
   sums 0..5, so `acc` takes the sequence 0, 0, 1, 3, 6, 10, 15" — not read back
   out of the recording. A test can therefore state what it expects without
   borrowing the answer from the fixture it is checking, which is the defect a
   corpus of real recordings exists to remove.
3. **Desktop CodeTracer's GUI.** The same containers open there.

## Two sets, and why the split matters

`manifest.json` carries **two** lists, and a consumer selects one:

| set | key | what it is |
|---|---|---|
| **recordable** | `programs` | produces a recording BlockTracer publishes and serves. This is the capability tour, and it is the set the E2E layer selects. |
| **toolchain** | `toolchainPrograms` | exercises the Noir toolchain and **cannot** produce a servable recording — it fails to compile, or the recorder cannot represent it. Still tests, and still the reason the tour is written the way it is. |

Three of the toolchain programs pin **language rules** the tour had to work
around (`Field` has no `Ord`; a signed integer cannot be cast straight to
`Field`; a format string interpolates bindings, not expressions). Two pin
**recorder gaps that are ours to close**, and each names the defect that owns it
in [`docs/NOIR-RECORDER-DEFECTS.md`](../../../docs/NOIR-RECORDER-DEFECTS.md).

Note `constraints` is deliberately in the RECORDABLE set: a constraint failure
at run time produces a real recording that stops at the assertion, which is the
case a zero-knowledge debugger exists for. Only programs that cannot produce a
servable recording at all belong in the other set.

## Layout

```
manifest.json              the two sets: what each program demonstrates, and what its recording must contain
record.sh                  re-record every container manifest.json names, from a pinned workdir
check-corpus.sh            both sets, checked against what the toolchain actually does (+ --selftest)
<id>/<package>.ct          the recording — VENDORED, see below
<id>/sources/              the package: Nargo.toml, Prover.toml, src/**.nr
toolchain/<id>/sources/    the non-recordable set — no container, by definition
```

## Known failures — never assert the broken behaviour

Where the recorder does something wrong, the corpus states what SHOULD happen
and marks it a **known failure** attributed to its defect id. It does not assert
the wrong behaviour: a test asserting "the `&mut` write is not recorded" would
teach the next reader that absence is correct, and would go red the day somebody
fixed it.

`check-corpus.sh` decides in **both directions** — the same rule
`tools/journeys/run.mjs` states for the journeys ledger:

* still failing → `KNOWN-FAILURE`, reported in full, does **not** fail the run;
* **starts passing** → `NOW PASSING`, and the run **fails**, naming the defect
  and telling you to move the program into the tour and delete the entry.

`check-corpus.sh --selftest` proves both arms decide, plus a base case so
neither is vacuous. (The journeys ledger has no such arm; this one does.)

## The recordable set — the tour

**`manifest.json` is the authority for this table**, not the other way round:
the rows are transcribed from `programs[]` and the three numbers from each
program's `trace` object. Two of them had already gone stale here — `limits` was
missing from the table entirely, and `mutation`'s counts read 91/7/0 against the
manifest's 118/8/0 — so read the manifest when they matter.

`calls` counts the `<toplevel>` frame the 2026-10 writer wraps every recording
in, because the manifest's `trace` block is a verbatim `ct-print --summary`
reading and that is what the reader reports. The program's own call count is one
lower, and the `(n−1)` column says so rather than leaving the reader to subtract.

| id | demonstrates | steps | calls | own calls | events |
|---|---|---|---|---|---|
| `values` | every value kind the language has, one line at a time | 34 | 2 | 1 | 0 |
| `loops` | a flat loop, nested loops, a `while`, and `break`/`continue` | 863 | 10 | 9 | 0 |
| `branches` | arms taken on one visit and not on another | 54 | 9 | 8 | 0 |
| `calls` | direct, mutual and tree recursion; one callee, two parents | 657 | 50 | 49 | 0 |
| `generics` | one body, many instantiations; one name, many bodies | 99 | 9 | 8 | 0 |
| `events` | what the execution said, as distinct from what it held | 124 | 7 | 6 | 14 |
| `constraints` | an execution that STOPS on a constraint that cannot hold | 71 | 5 | 4 | 4 |
| `limits` | the EDGES of a type — saturating, wrapping and shifting arithmetic | 101 | 6 | 5 | 0 |
| `mutation` | a binding whose value moves — and one form that is not recorded | 118 | 9 | 8 | 0 |

**`steps` and `events` did not move when the corpus was re-recorded at the
2026-10 recorder, and neither did `paths` or `varnames`.** What moved was
`calls`/`functions` (the `<toplevel>` frame above), `types` (the writer stopped
interning unnamed placeholder entries; no type NAME was lost) and `bytes` (the
writer's layout). Nine programs, and not one checked fact among them moved —
which is the same separation `codetracer-specs`' `CTFS-Reader-Revision-Rollout`
CRR-4 measured independently on a different recording.

## Why the containers are vendored rather than built

`nargo trace` is **not byte-deterministic**. `meta.dat` carries a UUIDv7
recording id minted when the container closes, and the embedded `workdir`
string is wherever the recording ran. Everything else — every step, call and
value — is identical between runs.

**RE-MEASURED at the 2026-10 recorder rather than carried over**, because this
is the whole reason the containers are committed and a figure taken against a
retired recorder would not support it: two runs of `values` at the same producer
produce two 77,824-byte containers that differ in **22 bytes**.

The demo tree must be byte-identical for a given seed (CI generates it twice
and diffs), so a generator that shelled out to `nargo trace` could not satisfy
that. `record.sh` pins the workdir to `/tmp/blocktracer-tour-rec/<id>/pkg` so
that re-recording changes only the recording id, and not also a path that names
whoever ran it.

Re-record deliberately, not on every build, and expect the ids to change.

**AND THIS IS WHY THESE NINE ARE NOT MOVED TO ON-THE-FLY RECORDING.**
`metacraft-dev-guidelines/policies/repo-requirements.md` §4.3 says a test that
needs a recording should record it on the fly, and that is the route
`fixtures/chain-health/readable-container` took. It is refused here by the 22
bytes above: a non-deterministic producer cannot feed a tree that CI regenerates
and diffs. The policy's objection is that a committed recording goes stale
against its recorder; the answer taken here is the other one §4.3 leaves open —
the recorder is named exactly, its re-record command is committed, and the
corpus is re-recorded when the recorder moves. This is that re-recording.

## The recorder pin

```
nargo 1.0.0-beta.26
noirc 1.0.0-beta.26+unknown           ← the binary self-reports `git version hash: false`
/nix/store/ps7kg504y4hw4jns6c6ccsy5jfmmq71s-Noir   ← THE PIN
```

One pin for the whole corpus: a corpus recorded by two tracers is two corpora.
`record.sh` warns if the binary it finds is not the pinned one.

**THE PIN IS A STORE PATH RATHER THAN A COMMIT, AND THAT IS NOT A WEAKENING.**
This recorder is a Nix build and embeds no git hash — `nargo --version` answers
`git version hash: false`, which `record.sh`'s old SHA check could not even
parse (it extracted the two hex characters `fa` out of the word `false` and
warned by accident). A content-addressed store path identifies the exact bytes
that produced this corpus, which a branch SHA does not. The derivation names its
inputs, and `manifest.json`'s `recorder` block carries all of them:

| what | where |
|---|---|
| derivation | `/nix/store/k72k7g9g4yjlzkl5fmx3qx7z41axspya-Noir.drv` |
| noir source | `/nix/store/c8xl12ywhj1g6761y7sljs2lx2j64ifl-source` |
| writer source | `/nix/store/vr9mll4gqpjsxnmfqqz0yffbxjz9jvif-source` (`codetracer-trace-format-nim`, the `b8db98c` 2026-10 revision) |
| trace-format rev | `1eae5894ce97001f4b013e50767cc2243a1ed47f` (2026-10-02), from the noir source's own `Cargo.toml` |

**What IS claimed and what is not.** The writer source's
`src/codetracer_trace_writer/meta_dat.nim` is byte-identical to the tip of the
`codetracer-trace-format-nim` checkout whose `ct-print` reads these containers,
so the producer and the reader are the same revision — that is measured, not
inferred. The exact noir COMMIT is **not** claimed: the source's `Cargo.toml`
matches noir@`875ee4855112` (*feat(tracer): record traces in the 2026-10 CTFS
format*) and its `Cargo.lock` does not match that commit or any other one
searched, so naming a SHA would be a guess and the store path is named instead.

**Why the corpus moved off the previous pin.** At `906af2f42d` every container
was at container version 4 / `meta.dat` schema 3, and the current reader refused
all nine:

```
Error: meta.dat present but corrupt: meta.dat: schema version 3 is not supported;
this reader reads version 6 only. Re-record the trace with a current recorder
```

That refusal is not a deprecation: schema 3 packed line-only step positions one
line HIGHER than schema 4 on, both land inside the trace's own address space,
and nothing else in the container tells them apart — so a reader that answered a
schema-3 container would place every step one line high and report success. No
gate widening could have reached these bytes. Re-recording was the only route,
and it is the one `ctfs-container.md` §2 prescribes.

## What this recorder cannot do, and what the programs do about it

The limits below were found by writing these programs, not read out of a
document. Each one is either designed around or demonstrated on purpose. (This
line said "Four" over a five-row table; count the rows, not the sentence.)

| limit | consequence here |
|---|---|
| ~~The pin predates `6939457ff7`, so every container reports `source_views: []`.~~ **No longer true.** The 2026-10 recorder EMBEDS the compiled source text: `values` reports `source_views: [{"view_name": "src/main.nr", "content_len": 3117}]`. | The `sources/` tree beside each container is KEPT and is still what the demo generator publishes as the source bundle, and what the ViewModels read. Removing it was not part of moving the pin and is separate work. |
| A recorded `Field` is truncated to `i64`. **NOT RE-MEASURED.** This was taken against the previous pin, and the 2026-10 recorder's noir source already contains `8804acd69d0` (*fix(tracer): an integer too wide for i64 is recorded, not truncated or fatal*), so it is likely stale. No program here exercises it, so re-recording could not decide it either way. | Every program keeps its field values small. `values` demonstrates the related rendering gap, and that one WAS re-measured and still holds: signed integers are recorded as their two's-complement unsigned value, so `-42: i8` reads 214 and `-100_000: i32` reads 4294867296. |
| `enum` values reach an unimplemented case in the value marshaller and abort the recording. | No program uses `enum`. |
| User-defined `#[oracle(...)]` calls have no resolver under `nargo trace`, and an oracle body is never instrumented. | No program uses one. **This is a gap in the tour**, not a gap in the language — see below. |
| Writes through a `&mut` parameter are not captured: the caller's binding never moves, and inside the callee the reference records with no dereferenced value. | `mutation` demonstrates this on purpose, last and labelled, with an assertion proving the circuit did the work the recording does not show. Every other program avoids the form. |

## What is not here

Named so a partial tour is not mistaken for a complete one:

- **Oracles**, for the reason above. Demonstrating one needs either a resolver
  flag on `nargo trace` or a `std::test` mock harness, and neither is a
  recording this corpus can currently make.
- **`comptime` and metaprogramming.** Comptime evaluation happens before the
  execution the tracer records, so there is nothing to step through; a program
  demonstrating it would demonstrate the compiler, not the debugger.
- **Closures and higher-order functions.** The recorder renders a function
  value as the opaque text `fn`, with no body and no captured environment, so a
  program built around them would show a pane full of `fn`.
- **`std::hash`, `std::embedded_curve_ops` and the other cryptographic
  primitives.** Their inputs and outputs are full-width field elements, which
  the `i64` truncation above renders as noise.
- **Value origin.** This entry read "BlockTracer has no origin-chain surface at
  all, so there is nothing for a program to demonstrate against." **That is no
  longer true** — `client/hydrate/session_project.nim` builds the
  `OriginChainVM`, `client/src/components/debugger.nim` renders the `.storigin`
  control and `client/hydrate/live_origin.nim` reads the reply back — so a
  program COULD now be written against it, and none has been. What the report
  accompanying this corpus still describes correctly is the fidelity limit: the
  classifier splits the right-hand side of a source assignment, so it has
  nothing to work with on a recording that published no source.

## Re-recording

```sh
fixtures/trace/tour/record.sh            # every program manifest.json names
fixtures/trace/tour/record.sh loops      # one
```

It finds `nargo` and `ct-print` by walking up from this directory to the
sibling checkouts; override with `NARGO=` and `CT_PRINT=`.

Verify a container by hand with:

```sh
ct-print --summary fixtures/trace/tour/loops/tour_loops.ct
ct-print fixtures/trace/tour/constraints/tour_constraints.ct | tail -5
```
