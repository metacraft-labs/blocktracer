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
record.sh                  re-record every container, from a pinned workdir
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

| id | demonstrates | steps | calls | events |
|---|---|---|---|---|
| `values` | every value kind the language has, one line at a time | 34 | 1 | 0 |
| `loops` | a flat loop, nested loops, a `while`, and `break`/`continue` | 863 | 9 | 0 |
| `branches` | arms taken on one visit and not on another | 54 | 8 | 0 |
| `calls` | direct, mutual and tree recursion; one callee, two parents | 657 | 49 | 0 |
| `generics` | one body, many instantiations; one name, many bodies | 99 | 8 | 0 |
| `events` | what the execution said, as distinct from what it held | 124 | 6 | 14 |
| `constraints` | an execution that STOPS on a constraint that cannot hold | 71 | 4 | 4 |
| `mutation` | a binding whose value moves — and one form that is not recorded | 91 | 7 | 0 |

## Why the containers are vendored rather than built

`nargo trace` is **not byte-deterministic**. `meta.dat` carries a UUIDv7
recording id minted when the container closes, and the embedded `workdir`
string is wherever the recording ran. Everything else — every step, call and
value — is identical between runs.

The demo tree must be byte-identical for a given seed (CI generates it twice
and diffs), so a generator that shelled out to `nargo trace` could not satisfy
that. `record.sh` pins the workdir to `/tmp/blocktracer-tour-rec/<id>/pkg` so
that re-recording changes only the recording id, and not also a path that names
whoever ran it.

Re-record deliberately, not on every build, and expect the ids to change.

## The recorder pin

```
nargo 1.0.0-beta.26
noirc 1.0.0-beta.26+906af2f42d6b874cf0f5dde193accb1e39e1bcd3
```

One pin for the whole corpus: a corpus recorded by two tracers is two corpora.
`record.sh` warns if the binary it finds is not at that commit.

## What this recorder cannot do, and what the programs do about it

Four limits were found by writing these programs, not read out of a document.
Each one is either designed around or demonstrated on purpose.

| limit | consequence here |
|---|---|
| The pin predates `6939457ff7` (*embed the compiled source text in the `.ct` container*), so every container reports `source_views: []`. | Source text reaches a reader through the `sources/` tree, which the demo generator publishes as a source bundle. Re-recording with a newer tracer would embed it and move the pin — do that deliberately. |
| A recorded `Field` is truncated to `i64`. | Every program keeps its field values small. `values` demonstrates the related rendering gap: signed integers are recorded as their two's-complement unsigned value, so `-42: i8` reads 214. |
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
- **Value origin.** BlockTracer has no origin-chain surface at all, so there is
  nothing for a program to demonstrate against. See the report accompanying
  this corpus.

## Re-recording

```sh
fixtures/trace/tour/record.sh            # all eight
fixtures/trace/tour/record.sh loops      # one
```

It finds `nargo` and `ct-print` by walking up from this directory to the
sibling checkouts; override with `NARGO=` and `CT_PRINT=`.

Verify a container by hand with:

```sh
ct-print --summary fixtures/trace/tour/loops/tour_loops.ct
ct-print fixtures/trace/tour/constraints/tour_constraints.ct | tail -5
```
