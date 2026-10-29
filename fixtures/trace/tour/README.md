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
record.sh                  regenerate Noir fixtures through the canonical preparer
check-corpus.sh            both sets, checked against what the toolchain actually does (+ --selftest)
<id>/<package>.ct          the generated recording — ignored by Git
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

## Generated recordings and determinism

The containers are ignored outputs. Tests and the site build prepare them from
these committed source programs and prover inputs with
`tools/fixtures/prepare-recordings.mjs`. The compatible recorder accepts a
supplied UUIDv7 bound to each row, its sorted source/prover inputs and the
actual recorder/compactor binaries, plus a logical working directory. Separate
invocations produce identical bytes regardless of workspace root or producer
selection. Its default behavior still mints fresh recording identifiers.

The demo generator consumes those prepared bytes. Its artifact identity binds
the declared producer graph, invocation and platform, so a producer change
cannot overwrite another producer's immutable recording address. Each program's
execution identity also binds its sorted relative source paths and original
Nargo/prover input bytes, so an input change receives a new artifact address.

## The recorder pin

`manifest.json` declares the complete producer role. The package is maintained
by the Noir repository at `b048e84842cc3ba55568ba7b4354a0c73709c9cc` and builds
compiler `875ee4855112922d4526c5f3e97448386dfc76f6`, Rust trace format
`1eae5894ce97001f4b013e50767cc2243a1ed47f`, and Nim writer
`051efd22b00ec3b88676fb07755a65c5a4ca8fde`. Its identity-option and deterministic debug-binding-order backports are
hashed individually and together in the manifest. It preserves the historical schema-6 writer ABI while
the main recorder continues to follow its current format dependencies.

The recorder writes CTFS version 6, compact profile 1, and meta.dat schema 6.
Since 2026-10-28 the pinned replay engine reads meta.dat schema 7 only, so
preparation regenerates each container at schema 7 (the version field and
nothing else, verified by a full decode; `tools/fixtures/README.md`), and the
prepared containers are CTFS version 6, compact profile 1, meta.dat schema 7. Older recorded UUID and store
path measurements explain the former committed corpus; they are not the
identity of this generated producer.

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

Inside the development shell:

```sh
fixtures/trace/tour/record.sh
```

This delegates to the canonical preparer and regenerates the complete Noir
fixture population, including `noir_space_ship`. The development shell supplies
`NARGO` and the compatible container compactor. A missing producer fails
explicitly; no machine-specific store-path fallback is used.
