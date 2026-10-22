# tools/chain/nix/starknet.nix — Starknet mainnet's capture, PRODUCED in the build instead
# of committed.
#
# The route `eth.nix` (Chain-Delivery DEL-5, route 3) and `flow.nix` (DEL-6) took, for a
# third VM family: the recorder is a pinned derivation, the capture is a derivation over a
# committed RPC transcript, and the container exists only in the store — so there is no
# committed recording for `ban-added-ct-recordings` to object to and nothing to go stale.
# A concrete duplicate of those two files, not a widening of either: DEL-7 is the
# milestone allowed to extract a seam from them.
#
# THE RECORDER RUNS STARKWARE'S OWN EXECUTOR. `codetracer-cairo-recorder`'s `onchain/` is
# a separate Cargo package that builds blockifier (the sequencer's transaction executor,
# crates.io 0.20.0-rc.1) with a small observer patched in (`onchain/blockifier-patch/`),
# so cairo-vm's own trace — one step per executed instruction — is what gets recorded.
# The crate is fetched by the sha256 the recorder repository records
# (`onchain/blockifier-patch/CHECKSUMS`) and patched here by that repository's own
# `apply.py`, exactly as its `vendor-blockifier.sh` does outside Nix. Its cairo-lang
# 2.19.x needs rustc >= 1.94; this flake's nixpkgs carries 1.97.1.
#
# THE PINS, AND WHY EACH IS WHERE IT IS (flake.nix states the revisions):
#
#   * `codetracer-cairo-recorder`: the recorder, AND the transcript — the capture's whole
#     input set is the recorder repository's own offline test fixture
#     (`onchain/tests/fixtures/mainnet-16664301`), recorded by that revision's
#     `trace-block --transcript-out --probe-floor`. Reading it from the recorder input
#     rather than copying it here keeps the transcript and the recorder that can replay
#     it one pin: a recorder that asks a different question than the transcript holds is
#     refused by name, never served a guess.
#   * `cairo-trace-format`: the recorder's Cargo path dependencies, at the revision its
#     own `repro.lock` names (3fada0b — the same revision `flow-trace-format` pins, kept as
#     a separate input on purpose).
#   * `codetracer-trace-format-nim`: the writer, SHARED with chains two and three, at the
#     last revision that writes `meta.dat` 6 — what the engine this site pins reads.
{ lib, stdenv, runCommand, rustPlatform, fetchurl, python3, pkg-config, capnproto, openssl
, zstd, pcre, nim, nodejs, bash
, recorderSrc, recorderRev, cairoTraceFormatSrc, writerSrc, writerNimDeps
, blocktracerRoot }:

let
  nimDepFlags = lib.concatMapStringsSep " " (p: "--path:${p}") writerNimDeps;

  # The writer's C FFI archive, built by the writer's own `build_ffi.nims` — the same
  # derivation eth.nix and flow.nix build (same source, same flags, one store path).
  writerFfi = stdenv.mkDerivation {
    pname = "codetracer-trace-writer-ffi";
    version = "0.1.0";
    src = writerSrc;
    nativeBuildInputs = [ nim ];
    buildInputs = [ zstd ];
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      nim e --hints:off build_ffi.nims --nimcache:$TMPDIR/nimcache \
        --out:$PWD/libcodetracer_trace_writer.a -- --hints:off ${nimDepFlags}
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib $out/include
      cp libcodetracer_trace_writer.a $out/lib/
      cp include/*.h $out/include/
      runHook postInstall
    '';
  };

  # `ct-print` at the writer's revision: the producer reads the container back through it.
  ctPrint = stdenv.mkDerivation {
    pname = "codetracer-ct-print";
    version = "0.1.0";
    src = writerSrc;
    nativeBuildInputs = [ nim pkg-config ];
    buildInputs = [ zstd pcre ];
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      nim c -d:release --mm:arc --hints:off --nimcache:$TMPDIR/nimcache \
        -p:src ${nimDepFlags} -o:ct-print src/codetracer_ct_print.nim
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp ct-print $out/bin/ct-print
      runHook postInstall
    '';
  };

  # StarkWare's executor, exactly the release the recorder's Cargo.lock names, fetched by
  # the checksum the recorder records for it.
  blockifierVersion = "0.20.0-rc.1";
  blockifierCrate = fetchurl {
    name = "blockifier-${blockifierVersion}.tar.gz";
    url = "https://static.crates.io/crates/blockifier/blockifier-${blockifierVersion}.crate";
    sha256 = "c9649a9fde95e5049e69ab2c873a4b391839cd75d33cdc3534d37df239afb0f5";
  };

  # The recorder resolves `../../codetracer-trace-format/<crate>` from `onchain/`, and
  # `[patch.crates-io]` points blockifier at `onchain/vendor/blockifier` — so the trees are
  # laid out as in a workspace checkout, and the vendored executor is produced the way
  # `vendor-blockifier.sh` produces it: the release, plus the recorder's own `apply.py`,
  # which refuses unless every patch site matches exactly once.
  recorderTree = runCommand "cairo-recorder-src" { nativeBuildInputs = [ python3 ]; } ''
    mkdir -p $out
    cp -r ${recorderSrc} $out/codetracer-cairo-recorder
    cp -r ${cairoTraceFormatSrc} $out/codetracer-trace-format
    chmod -R u+w $out
    mkdir -p $TMPDIR/crate $out/codetracer-cairo-recorder/onchain/vendor
    tar -xzf ${blockifierCrate} -C $TMPDIR/crate
    mv $TMPDIR/crate/blockifier-${blockifierVersion} \
      $out/codetracer-cairo-recorder/onchain/vendor/blockifier
    python3 $out/codetracer-cairo-recorder/onchain/blockifier-patch/apply.py \
      $out/codetracer-cairo-recorder/onchain/vendor/blockifier
  '';

  onchainRecorder = rustPlatform.buildRustPackage {
    pname = "codetracer-cairo-onchain";
    version = "0.1.0-${builtins.substring 0 7 recorderRev}";
    src = recorderTree;
    sourceRoot = "cairo-recorder-src/codetracer-cairo-recorder/onchain";
    cargoLock.lockFile = recorderSrc + "/onchain/Cargo.lock";
    cargoBuildFlags = [ "--bin" "codetracer-cairo-onchain" ];
    # The writer's `build.rs` links this archive instead of compiling the Nim sources,
    # so no Nim toolchain enters the Rust build and the writer revision is the pin's.
    CODETRACER_TRACE_WRITER_NIM_PREBUILT = writerFfi;
    nativeBuildInputs = [ pkg-config capnproto ];
    buildInputs = [ openssl zstd ];
    # The offline suite (`just onchain-test`) runs in the recorder repository.
    doCheck = false;
  };

  # The committed input set, read from the recorder input — see the header.
  transcript = recorderSrc + "/onchain/tests/fixtures/mainnet-16664301";

  # What the capture reads from this repository, and nothing else.
  captureSrc = lib.fileset.toSource {
    root = blocktracerRoot;
    fileset = lib.fileset.unions [
      (blocktracerRoot + "/tools/chain")
      (blocktracerRoot + "/client/hydrate/engine-pin.txt")
    ];
  };

  # `just starknet-capture`, inside the sandbox: the recorder serves every RPC answer from
  # the transcript and refuses any it does not hold, so no network is used or needed. The
  # output is a §5 snapshot tree, BYTE-REPRODUCIBLE: the container's recording id is
  # derived from the block and the transaction, its listings are interned relative to the
  # capture directory, and the producer is handed the transcript's own recording time.
  starknetCaptureTree = stdenv.mkDerivation {
    name = "starknet-mainnet-capture";
    src = captureSrc;
    nativeBuildInputs = [ nodejs bash ];
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      bash tools/chain/starknet-capture.sh \
        --recorder ${onchainRecorder}/bin/codetracer-cairo-onchain \
        --recorder-commit ${recorderRev} \
        --transcript ${transcript} \
        --ct-print ${ctPrint}/bin/ct-print \
        --out $TMPDIR/tree --work $TMPDIR/work
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -r $TMPDIR/tree $out
      test -s $out/snapshot.json
      runHook postInstall
    '';
  };
in {
  inherit onchainRecorder starknetCaptureTree ctPrint;
}
