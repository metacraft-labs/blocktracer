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
pins, the recorder binaries, the writer and AVM modules, and generation
configuration. Output hashes detect modified or truncated files. `--force`
records every subject again; `--check` fails if preparation is needed.

The development shell supplies `CT_FIXTURE_PRINT` for these schema-6 recordings.
Authoring recipes select that reader locally; it does not replace the current
reader paired with independently generated schema-7 health-check subjects.

The policy check inspects the complete Git index, including old paths and
directory recordings. An additions-only commit hook cannot detect an old
recording that has remained in the repository for years.
