# Fixture recordings

`prepare-recordings.mjs` produces the `.ct` files used by tests and the demo
site. Their original programs and immutable chain inputs stay in Git; the
resulting containers are ignored. Run preparation through the development
shell, which supplies the pinned producers.

`recordings.json` lists the original 55 output paths. Preparation compares that
set with the chain snapshots, the tour manifest and the conformance template.
Missing inputs, missing tools, a failed producer or a changed replay outcome
fail preparation. They do not skip a test or replace a historical transaction
with another one.

The producer roles are distinct:

* Noir fixtures execute their committed source and prover inputs with the
  compatible fixture recorder. A supplied UUIDv7 binds the per-row configuration,
  sorted program/input digests and actual recorder/compactor binary hashes.
  Together with a logical working directory, it makes separate recording
  invocations reproducible across workspace roots and producer selection.
* Aztec fixtures execute the original transaction against captured historical
  RPC responses using the replay runtime's offline fixture mode. The upstream
  client validates each response, including the discovered state witnesses.
  The Noir frame fixture is the same real transaction replay as its copy in
  the testnet capture. Its former reconstructed container was replaced by a
  real replay; preparation preserves that actual recording.
* The conformance template generates its three labeled ASCII placeholders.
  They exercise copying and hashing, and are never presented as recordings.

The prepared files are cached under their original paths, with fingerprints
in `.fixture-recordings/`. The cache binds inputs, runtime source and dependency
pins, the recorder binaries, the writer and AVM modules, the `meta.dat`
regeneration binary, and generation configuration. Output hashes detect modified or truncated files. `--force`
records every subject again; `--check` fails if preparation is needed.

Both producers write `meta.dat` schema 6, and the replay engine pinned in
`client/hydrate/engine-pin.txt` reads schema 7 only. So after each producer,
preparation runs `CT_META_DAT_V7` (`tools/chain/meta_dat_v7.nim`), which moves
the version field to 7 and nothing else, and writes the result only if its v7
reader decodes every path, step, value, call and event. Byte counts do not
change. Then every prepared container, recorded or cached, must be inside the
`shipped-engine` sets in `tools/chain/health-checks.json`; one that is not fails
preparation by file name. The development shell supplies `CT_FIXTURE_PRINT`, a
`ct-print` that reads these schema-7 recordings, built with the regeneration
tool from the same `codetracer-trace-format-nim` revision.

The policy check inspects the complete Git index, including old paths and
directory recordings. An additions-only commit hook cannot detect an old
recording that has remained in the repository for years.
