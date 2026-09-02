# Noir recorder defects — the register

Defects found by writing the capability tour's programs
(`fixtures/trace/tour/`). Each one is **triaged to the layer that owns it**,
because the two layers have different fixes and different lead times:

| Layer | What it is | Where a fix goes |
|---|---|---|
| **ours** | the CodeTracer tracer we added to the Noir fork — `tooling/tracer/`, `tooling/tracer_wasm/`, `tooling/nargo_cli/src/cli/trace_cmd.rs`. **None of these paths exist in `upstream/master`.** | our fork, directly |
| **engine** | CodeTracer's replay engine — `src/db-backend/`, and specifically its `wasm32` build, which is what a browser session runs. | the `codetracer` repo |
| **upstream** | Noir's own debug instrumentation — `compiler/noirc_frontend/src/debug/`, `compiler/noirc_printable_type/`, `tooling/noirc_artifacts/src/debug_vars.rs`, `tooling/debugger/src/foreign_calls.rs`. Born in `c58d69141b` (2024-02-05), **two years before our fork point**, and used by `nargo debug`. | an upstream PR, or a carried patch we own forever |

The fork point is `git merge-base HEAD upstream/master` = `3d3a1ce788`; the first
CodeTracer commit is `84f4b4d885` (2024-05-30). Every verdict below is settled by
`git cat-file -e upstream/master:<path>` and `git log -L`/`-S` on the exact lines,
not by which directory a file happens to sit in.

**These are defects, not design.** Where a program in the corpus demonstrates
one, it demonstrates it as a **known failure** that states the CORRECT
expectation — never by asserting the wrong behaviour. See
[the known-failure rule](#the-known-failure-rule) below.

---

## The register

| id | defect | owner | severity | corpus subject |
|---|---|---|---|---|
| **NR-01** | A recorded `Field` is narrowed to `i64` — silently wrong below 2^127, a panic above it | **ours** | **critical** | none — every tour program keeps its field values small |
| **NR-02** | `enum` values abort the recording with `todo!()` | **ours** | major | `toolchain/enums` |
| **NR-03a** | `nargo trace` has no `--oracle-resolver` / `--oracle-file`, so no oracle program can be recorded | **ours** | major | `toolchain/oracles` |
| **NR-03b** | The debug instrumenter skips `#[oracle]` bodies, so an oracle call has no frame | **upstream** | minor | `toolchain/oracles` |
| **NR-04** | Writes through a `&mut` parameter are not captured at all | **upstream** | major | `tour/mutation` |
| **NR-05** | In the BROWSER engine, source text is unreachable, so every value-origin query answers `UnknownSource` at confidence 0.0 | **engine** (CodeTracer's db-backend) | major | none yet — it bounds what BlockTracer's shipped origin surface can answer |

---

### NR-01 — a recorded `Field` is narrowed to `i64`. Owner: **ours**

`tooling/tracer/src/tracer_glue.rs:154`

```rust
ValueRecord::Int { i: field_value.to_i128() as i64, type_id }
```

Same narrowing at `:168` (`UnsignedInteger`), `:180` (`SignedInteger`), `:189`
(`Boolean`).

**Two regimes, both observed:**

| input | recorded | what happened |
|---|---|---|
| `18446744073709551616` (2^64) | `x: 0`, and `x + 1` as `1` | fits `i128`, does not fit `i64` — `as i64` wraps, **silently** |
| `2^127`, or any 160-bit value | *no recording at all* | `FieldElement::to_i128` panics `field element too large for i128` (`acvm-repo/acir_field/src/field_element.rs:445`) and the process SIGABRTs |
| `p - 1` (the BN254 modulus minus one) | `x: -1` | the signed interpretation, which is right here by luck |

This is the most severe of the five and it is entirely ours. A `Field` is the
language's native scalar; the trace format already has the right sink —
`ValueRecord::BigInt { b: Vec<u8>, negative: bool, type_id }` — and it is unused.
Any hash output, any curve coordinate, any commitment either records as a wrong
number or takes the whole recording down.

**Reproducer**
```sh
# silently wrong
printf 'x = "18446744073709551616"\n' > Prover.toml && nargo trace --out-dir out
# panic
printf 'x = "170141183460469231731687303715884105728"\n' > Prover.toml && nargo trace --out-dir out
```
over `unconstrained fn main(x: Field) -> pub Field { let y = x + 1; y }`.

**Evidence of ownership** — `git log -S 'ValueRecord::Int { i: field_value.to_i128() as i64'`
→ `240a7241a1`, `aefcc8424a`, `a1a503942f`, all ours; the file is absent from
`upstream/master`.

**Consequence for the corpus:** this is why `tour/values` keeps every field value
small and demonstrates the *related* signed-rendering behaviour instead, and why
the corpus has no `std::hash` program. Fixing NR-01 is the precondition for a
cryptography beat in the tour.

---

### NR-02 — `enum` values abort the recording. Owner: **ours**

`tooling/tracer/src/tracer_glue.rs:294` and `:394`

```rust
todo!("Tracing support for enums is not yet implemented")
```

Upstream's decoder is **complete**: `compiler/noirc_printable_type/src/lib.rs:470`
fully decodes an enum into `PrintableValue::Enum { tag, elements }`. Our
marshaller then hits an unimplemented arm and panics. The trace format has the
target representation already — `ValueRecord::Variant { discriminator, contents,
type_id }` — so the mapping is direct.

Two details worth keeping:

* `enum` and `match` are **unstable**; without `-Zenums` nothing compiles, so
  "enums abort the recording" is only true once the feature is enabled.
* The panic happens **after** the streaming container is opened, so a truncated
  `.ct` is left on disk. A caller treating the file's existence as success would
  publish a corrupt recording.

**Reproducer** — `fixtures/trace/tour/toolchain/enums`, `nargo trace -Zenums`.

**Evidence** — `git log -S 'Tracing support for enums is not yet implemented'`
→ `4e32eaca52`; file absent upstream.

---

### NR-03a — `nargo trace` cannot resolve oracles. Owner: **ours**

`tooling/nargo_cli/src/cli/trace_cmd.rs:35` declares no oracle flags, and
`tooling/tracer/src/lib.rs:105` hardcodes the resolver away:

```rust
let foreign_call_executor = Box::new(DefaultDebugForeignCallExecutor::from_artifact(
    writer,
    None,            // <-- resolver_url
    debug_artifact,
    None,
    String::new(),
));
```

Every sibling command has the flag — `execute_cmd.rs:45`, `debug_cmd.rs:72`,
`test_cmd.rs:85`, `fuzz_cmd.rs:73`, `dap_cmd.rs:208`. `trace` is the sole
omission, and the RPC machinery is compiled in (feature unification through
`noir_debugger`), merely never handed a URL.

**And the failure is misreported.** `nargo execute` says
`No handler could be found for foreign call 'get_hint'`. `nargo trace` exits
**zero**, writes a container, and its only error entry reads `Failed assertion` —
sending a reader to look for a constraint that never failed. A missing flag is
discoverable; a recording that misattributes its own ending is not.

**Reproducer** — `fixtures/trace/tour/toolchain/oracles`.

---

### NR-03b — the instrumenter skips `#[oracle]` bodies. Owner: **upstream**

`compiler/noirc_frontend/src/debug/mod.rs:103`, `DebugInstrumenter::walk_fn`:

```rust
if let Some((func, _)) = &func.attributes.function {
    match func.kind {
        FunctionAttributeKind::Foreign(_)
        | FunctionAttributeKind::Builtin(_)
        | FunctionAttributeKind::Oracle(_) => return,
```

An early return before `build_debug_call_stmt("enter", …)`, so no frame, no
parameter values. Present verbatim in `upstream/master` at its line 104; `git
log -L 102,116` names Giráldez, Tom French and Vezenov — **no fork authors**.

Defensible upstream: an oracle function is a declaration, and upstream later made
a body an error (`96fb819343`). Inadequate for our fidelity goal, but not ours to
call a bug. Fixing NR-03a alone still leaves the oracle frame invisible; the call
site and the returned value would be visible, which is most of the value.

---

### NR-04 — writes through a `&mut` parameter are lost. Owner: **upstream**

**The user's hypothesis was right.** `DebugInstrumenter` predates our fork by two
years and is `nargo debug`'s. Three independent upstream causes stack:

**(a) The instrumenter emits nothing for `*x = …`.**
`compiler/noirc_frontend/src/debug/mod.rs:425`:

```rust
ast::LValue::Dereference(_lv, location) => {
    // TODO: this is a dummy statement for now, but we should
    // somehow track the dereference and update the pointed to
    // variable
    ast::Statement { kind: ast::StatementKind::Expression(uint_expr(0, *location)), location }
}
```

A literal `0` in place of the oracle call. Present in `upstream/master` at line
336. The nested `Dereference => unimplemented![]` at `:466` is the same gap for
`(*p).f = v`.

**(b) Even if it were emitted, the two halves cannot meet.** The instrumenter's
stub is `#[oracle(__debug_dereference_assign)]` (`mod.rs:764`); the debugger
dispatches on the string `"__debug_deref_assign"`
(`tooling/debugger/src/foreign_calls.rs:33`). `dereference` vs `deref` — **dead
code on both sides of a broken handshake, and the mismatch is upstream's too.**
This is the single most reportable detail here: it is a one-word fix that nobody
can have tested.

**(c) The handler is a stub anyway.**
`tooling/noirc_artifacts/src/debug_vars.rs:147`:

```rust
pub fn assign_deref(&mut self, _var_id: DebugVarId, _values: &[F]) { unimplemented![] }
```

That file has **zero diff** against upstream.

**Why the callee's reference reads `kind: None`** — a separate upstream cause:
`compiler/noirc_printable_type/src/lib.rs:458` decodes `PrintableType::Reference`
by consuming and **discarding** the fields, returning `PrintableValue::Other`
(also zero-diff vs upstream). Our layer then does the only sane thing with it —
`tracer_glue.rs:143` early-returns `ValueRecord::None` (`70e0507b16`, "gracefully
handle references with unknown dereferenced values"). Note this early return
shadows our own `PrintableType::Reference` arm at `:273`, which would build a
proper `ValueRecord::Reference` and can never be reached.

**Why the caller's binding never moves** — `walk_expr`'s `Call`/`MethodCall` arms
(`mod.rs:517`) only recurse into arguments; passing `&mut q` emits no re-record
of `q` after the call. Upstream verbatim, `// TODO: push a stack frame or
something here?` included.

**Our 417-line diff to `mod.rs` does not touch any of this** — it is additive
hardening (turning `_ => {}` catch-alls into exhaustive matches, plus the
compound-assignment and loop-body fixes in `906af2f42d`).

**Reproducer already in tree** — `test_programs/trace/reference_basic/src/main.nr`;
add `*w = 7;` and watch the write vanish. Also `fixtures/trace/tour/mutation`,
whose last section exists for this.

**A full fix needs all four**: instrumenter emission (a), the oracle-name
reconciliation (b), a real `assign_deref` (c), and a `PrintableValue` that
carries reference contents. That is an upstream PR, not a patch.

---

### NR-05 — the browser engine cannot reach source, so value origin is degenerate. Owner: **engine**

This is the defect that decides whether BlockTracer can have a value-origin
surface at all, so it is registered here even though it is neither ours nor
upstream Noir's.

**The good news first, because it was not a given.** The origin-chain handler IS
in the wasm build and IS dispatched in the browser:

* `src/db-backend/src/lib.rs` declares `origin_query`, `omniscient_origin`,
  `emulator_origin` and `recreator_origin` **unconditionally** — no
  `not(target_arch = "wasm32")` anywhere near them.
* `dap_server.rs:2946` (`handle_message_browser`) delegates to `handle_request`
  (`:2048`, not cfg-gated), whose table at `:2085` carries `"ct/originChain"`
  and at `:2090` `"ct/originSummary"`.
* The wasm clock traps that used to break this path were fixed as a class —
  `src/db-backend/src/wall_clock.rs` is now the crate's only clock, guarded by
  `tests/wall_clock_sweep_test.rs`. The Embed SDK pin's own `dap_dialect.md`
  records it: row `3-D3 | ct/originChain traps | engine | fixed (wall_clock)`.

**The defect.** A `nargo trace` CTFS container routes to
`MaterializedReplaySession` (spec §6.1, "Path B") — `dap_server.rs:1592` →
`dap_handler.rs:494`. Path B infers hops by classifying the SOURCE LINE of each
write. In the browser it never gets one:

* `expr_loader.rs:2045` reads source with `fs::read_to_string`, which is
  `Unsupported` on `wasm32-unknown-unknown`. `ExprLoader` has no `crate::vfs`
  path at all.
* The bundled-source fallback needs `meta_dat_sources_root`, computed at
  `dap_handler.rs:3348` from a `.is_dir()` probe that is `false` on wasm.
* `Handler::load_bundled_sources` (`dap_handler.rs:3371`) has exactly one
  caller, `dap_server.rs:457` — the **native** `setup()`. `setup_from_vfs`, the
  browser path, never calls it.

So `db.rs:3339` fires and the response is a **successful** DAP reply carrying one
hop of kind `Unknown`, `confidence: 0.0`,
`classification_provenance: "built-in: source unavailable"`, terminator
`UnknownSource`.

**And the bytes are right there.** The Noir tracer registers source views into
the container (`noir/tooling/tracer/src/sink.rs:92`). Nothing in the browser path
reads them.

**Why this blocks the product surface.** BlockTracer's home page and its
`<meta name="description">` both promise a visitor can *"trace any value to its
origin"* (`client/src/pages/home.nim`, `client/src/ssr.nim`). `OriginChainVM` and
`origin_chain_types` are exported from the Embed SDK facade
(`codetracer_embed.nim`).

**THE CONTROL SHIPS. This paragraph used to argue against building it.** It said
no control anywhere offers the query, that `LiveSession` "builds six ViewModels
and not that one", and that wiring it "would ship a control that answers
'unknown source' on every value of every transaction… worse than the absence".
All three are out of date: `client/hydrate/session_project.nim:266` constructs
`originChain: createOriginChainVM(store)` among seven, and
`client/src/components/debugger.nim:1271` renders the control
(`button(class="storigin", data-action="origin")`).

So NR-05 is no longer a reason not to wire the surface; it is a statement about
what the wired surface can answer. What NR-05 still governs is the QUALITY of
the answer in the browser engine — where source text is unreachable, the query
resolves to `UnknownSource` at confidence 0.0. Do not cite this section as an
argument for absence.

**The fix, and its size.** Roughly 60–100 lines in the engine, localised:
either extract bundled sources into `crate::vfs` from `setup_from_vfs` instead of
`std::env::temp_dir()`, or give `ExprLoader::file_source_code`
(`expr_loader.rs:2041`) a VFS-first branch and push `srcviews.dat` views into the
VFS at the paths `expr_loader::bundled_source_path` derives. Path B itself needs
no change — it is pure `Db`/reader logic.

Two things to do alongside it: **there is no browser/wasm origin test at all**
(the ~24 `origin_*` tests and the 6 wasm tests do not intersect), and the
recorder-side alternative — emitting `originmeta.tc` + `source_exprs.tc` from
`nargo trace` — would make the browser path source-independent and raise native
quality too.

**On a rung-3 chain trace it stays degenerate regardless.** BlockTracer's Aztec
data has no source and no variable names, so there is no `variableName` to query
with; the honest answers there are error 6101 / terminator `unknownVariable`.
A value-origin surface is therefore a **demo-chain and future-source-level-chain**
capability, not a universal one, and whatever gets built must say so per rung
rather than offering the same control everywhere.

---

## The known-failure rule

**Never assert the broken behaviour.** A test asserting "the `&mut` write is not
recorded" teaches the next maintainer that absence is correct, and it goes red
when somebody *fixes* the bug — exactly backwards.

Every defect above is instead carried as a **known failure** that states the
correct expectation, is attributed to its `NR-` id, does not fail the suite while
the defect stands, and **fails loudly the moment it starts passing** — because
that is the signal to close the defect and move the program into the tour.

| where | what carries it |
|---|---|
| the manifest | `fixtures/trace/tour/manifest.json` — `programs[].knownFailures` for a recording that omits something it should show, and `toolchainPrograms[].expect.knownFailure` for a program the toolchain cannot record at all |
| the checker | `fixtures/trace/tour/check-corpus.sh` — reads both, and `--selftest` proves it decides in BOTH directions |

There is currently **no Nim carrier**. This table used to name
`client/tests/known_failures.nim` with a `knownFailure(id, defect, owner)` helper
and a `fixtures/trace/tour/check-toolchain.sh`; neither file exists in this tree
and no Nim file carries a known failure. If a Nim-side defect needs one, it has
to be built, not looked up.

`check-corpus.sh` reports `NOW PASSING` and exits non-zero when the world stops
matching an entry. Good news that cannot go unnoticed.

## Reporting upstream

NR-03b and NR-04 belong to `noir-lang/noir`. NR-04(b) — the
`__debug_dereference_assign` / `__debug_deref_assign` mismatch — is the strongest
single report: two files that can never agree, on both sides, in `master`.
Neither has been filed yet; this register is the material for filing them.
