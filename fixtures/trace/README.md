# Trace fixtures

## `minimal_trace.ct` — a STAND-IN container

This is a copy of the canonical CTFS fixture from
`codetracer-trace-format-spec/fixtures/minimal_trace.ct` (a small, real,
split-binary + seekable-Zstd `.ct` produced by the Nim `TraceWriter`).

**It is a stand-in, not a real BlockTracer artifact.** The M5c milestone calls for
real `noir_space_ship` traces produced by `nargo trace` in the `noir` fork's
`tooling/tracer`. `nargo` was **not available** in the environment where this slice
was built, so the demo generator reuses this fixture as the `trace.ct` body of
every published (`ready` / `divergent`) execution.

What this does and does not affect:

- **Contract conformance is unaffected.** The container is opaque to the data
  contract; the manifest's `container.bytes` and `container.hash` describe these
  exact bytes, so the artifact validates.
- **The trace content is not the spaceship program.** It is the `factorial` fixture
  trace. Do not read anything into the executed program until real `nargo trace`
  output replaces it.

### Producing the real trace later

```
cd codetracer/test-programs/noir_space_ship
nargo trace --out-dir=<dir>          # writes a real .ct
```

Then point the generator at it:

```
blocktracer-demo-gen --trace-fixture=<dir>/<trace>.ct
```

and adjust the per-execution `recorder` / `execution` metadata in
`src/blocktracer/demo/generator.nim` (`writeArtifact`) to match the real recorder
build and step/frame counts.
