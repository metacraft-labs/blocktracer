# tools/chain/nix/eth.nix — chain two's container, PRODUCED in the build instead of committed.
#
# Chain-Delivery DEL-5 priced three routes for getting `ethereum-mainnet` onto staging,
# whose site is a Pages build of the git tree. Route 1 commits the 81,920-byte container
# and needs an exemption from `ban-added-ct-recordings`. This file is route 3. The
# recorder is a pinned derivation, the capture is a derivation over the committed
# JSON-RPC transcript, and the container exists only in the store, so there is no
# committed recording for the ban to object to and nothing to go stale.
#
# THREE PINS, AND WHY EACH IS WHERE IT IS (flake.nix states the revisions):
#
#   * `codetracer-evm-recorder`: the recorder the 2026-10-20 measurements were taken with.
#   * `evm-trace-format`: its Cargo path dependencies, at the revision the recorder's
#     own `repro.lock` names. This is NOT the `codetracer-trace-format` input the Aztec
#     ct-writer uses: that one is anchored to the runtime's pins, and the two must not
#     be forced into one checkout.
#   * `codetracer-trace-format-nim`: the writer, at `e15374866`, which writes `meta.dat`
#     7 — what the engine this site pins reads since 2026-10-28, and no other version.
#     It was `7b8b587` (= `20ba929^`, the last revision that writes 6) while the pinned
#     engine read 6 only. Move this pin with `client/hydrate/engine-pin.txt` and never
#     ahead of it.
#
# THE LOCKFILE IS OURS. The recorder repository gitignores `Cargo.lock`, so a pinned
# build has to bring one. `evm-recorder.Cargo.lock` was produced by `cargo build` over
# exactly the source layout below (recorder beside its trace-format sibling).
{ lib, stdenv, runCommand, rustPlatform, pkg-config, capnproto, openssl, zstd, pcre
, nim, nodejs, bash, cacert
, recorderSrc, recorderRev, evmTraceFormatSrc, writerSrc, writerNimDeps
, blocktracerRoot }:

let
  nimDepFlags = lib.concatMapStringsSep " " (p: "--path:${p}") writerNimDeps;

  # The writer's C FFI archive and headers, built by the writer's own
  # `build_ffi.nims` exactly as its flake's `trace-writer-ffi` package builds it,
  # so the flags cannot drift from every other producer of the archive.
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

  # `ct-print`, at the same writer revision: the producer reopens the container
  # through it, so it must read exactly the schema the writer wrote.
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

  # The recorder resolves `../codetracer-trace-format/<crate>` from its own directory,
  # so the two trees are laid out side by side exactly as in a workspace checkout.
  recorderTree = runCommand "evm-recorder-src" { } ''
    mkdir -p $out
    cp -r ${recorderSrc} $out/codetracer-evm-recorder
    cp -r ${evmTraceFormatSrc} $out/codetracer-trace-format
    chmod -R u+w $out
    cp ${./evm-recorder.Cargo.lock} $out/codetracer-evm-recorder/Cargo.lock
  '';

  evmRecorder = rustPlatform.buildRustPackage {
    pname = "codetracer-evm-recorder";
    version = "0.1.0-${builtins.substring 0 7 recorderRev}";
    src = recorderTree;
    sourceRoot = "evm-recorder-src/codetracer-evm-recorder";
    cargoLock.lockFile = ./evm-recorder.Cargo.lock;
    cargoBuildFlags = [ "--bin" "codetracer-evm-recorder" ];
    # The writer's `build.rs` links this archive instead of compiling the Nim sources,
    # so no Nim toolchain enters the Rust build and the writer revision is the pin's.
    CODETRACER_TRACE_WRITER_NIM_PREBUILT = writerFfi;
    nativeBuildInputs = [ pkg-config capnproto ];
    buildInputs = [ openssl zstd ];
    # The recorder's suite runs in its own CI and needs solc, anvil and a network.
    doCheck = false;
  };

  # The one transaction the committed input set describes. Justfile's ETH_CAPTURE_TX.
  tx = "0xf6998cac9f5d2843729743b866bdc4b09bd119774bbec5e56f69f8819f2b71aa";

  # What the capture reads, and nothing else, so an unrelated edit does not re-run it.
  captureSrc = lib.fileset.toSource {
    root = blocktracerRoot;
    fileset = lib.fileset.unions [
      (blocktracerRoot + "/tools/chain")
      (blocktracerRoot + "/fixtures/chain-inputs/ethereum-mainnet/${tx}")
      (blocktracerRoot + "/client/hydrate/engine-pin.txt")
    ];
  };

  # `just eth-capture`, inside the sandbox: the transcript is served on loopback and the
  # replay endpoint has no upstream to fall through to, so no network is used or needed.
  # The output is a §5 snapshot tree. It is NOT bit-reproducible (the recorder stamps a
  # UUIDv7 recording id); `just eth-regen-check` is how two such trees are compared.
  ethCaptureTree = stdenv.mkDerivation {
    name = "ethereum-mainnet-capture";
    src = captureSrc;
    nativeBuildInputs = [ nodejs bash ];
    CT_PRINT = "${ctPrint}/bin/ct-print";
    # reqwest refuses to construct a client with no CA store, even though every call
    # here goes to loopback over plain HTTP.
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      node tools/chain/eth-rpc-transcript.mjs \
        --replay --transcript fixtures/chain-inputs/ethereum-mainnet/${tx} -- \
        bash tools/chain/eth-capture.sh \
          --recorder ${evmRecorder}/bin/codetracer-evm-recorder \
          --recorder-commit ${recorderRev} \
          --tx ${tx} --out $TMPDIR/tree --work $TMPDIR/work \
          --transcript fixtures/chain-inputs/ethereum-mainnet/${tx}
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -r $TMPDIR/tree $out
      test -s $out/ct/${tx}.ct
      runHook postInstall
    '';
  };
in {
  inherit evmRecorder ethCaptureTree ctPrint;
}
