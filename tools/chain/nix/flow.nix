# tools/chain/nix/flow.nix — Flow mainnet's containers, PRODUCED in the build.
#
# The same route eth.nix takes for Ethereum (Chain-Delivery DEL-5, route 3), written
# again for Flow rather than shared with it: DEL-6 asks for the third chain's producer to
# DUPLICATE the second's, so that DEL-7 extracts a seam from two that already worked. The
# writer and ct-print derivations below are the same expressions as eth.nix's, and so
# the same derivations; they are repeated, not imported, for that reason.
#
# WHAT RUNS IN THE SANDBOX. The Flow recorder's `replay` drives `cadence-replay-helper`,
# which is the network's FVM (flow-go v0.51.1, the release mainnet's access node reports)
# re-executing a transaction against the register state its block started from. Here it
# reads that state from the committed transcript under fixtures/chain-inputs/flow-mainnet
# (`--inputs`, no network), so the container exists only in the store and there is no
# committed recording for `ban-added-ct-recordings` to object to.
#
# THE PINS (flake.nix states the revisions):
#
#   * `codetracer-flow-recorder`: the recorder and its helper, at the revision whose
#     transcript format the committed inputs are in.
#   * `flow-trace-format`: the recorder's Cargo path dependencies, at the revision the
#     recorder's own `repro.lock` names.
#   * `codetracer-trace-format-nim`: the writer at `7b8b587`, the last revision that
#     writes `meta.dat` 6 — shared with eth.nix through flake.nix, because the engine the
#     site pins reads 6 only. The recorder's own lock names a newer writer.
{ lib, stdenv, runCommand, rustPlatform, buildGoModule, go_1_26, pkg-config, capnproto
, openssl, zstd, pcre, nim, nodejs, bash
, recorderSrc, recorderRev, flowTraceFormatSrc, writerSrc, writerNimDeps
, blocktracerRoot }:

let
  nimDepFlags = lib.concatMapStringsSep " " (p: "--path:${p}") writerNimDeps;

  # As eth.nix: the writer's C FFI archive, through the writer's own `build_ffi.nims`.
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

  # As eth.nix: `ct-print` at the writer's revision, so it reads what the writer wrote.
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

  # The recorder resolves `../codetracer-trace-format/<crate>` from its own directory.
  recorderTree = runCommand "flow-recorder-src" { } ''
    mkdir -p $out
    cp -r ${recorderSrc} $out/codetracer-flow-recorder
    cp -r ${flowTraceFormatSrc} $out/codetracer-trace-format
    chmod -R u+w $out
  '';

  flowRecorder = rustPlatform.buildRustPackage {
    pname = "codetracer-flow-recorder";
    version = "0.1.0-${builtins.substring 0 7 recorderRev}";
    src = recorderTree;
    sourceRoot = "flow-recorder-src/codetracer-flow-recorder";
    cargoLock.lockFile = recorderSrc + "/Cargo.lock";
    cargoBuildFlags = [ "--bin" "codetracer-flow-recorder" ];
    CODETRACER_TRACE_WRITER_NIM_PREBUILT = writerFfi;
    nativeBuildInputs = [ pkg-config capnproto ];
    buildInputs = [ openssl zstd ];
    # The recorder's suite runs in its own CI.
    doCheck = false;
  };

  # The recorder repository's own `.#cadence-replay-helper`, built here from the same
  # source so this flake does not take that flake's lock. It needs Go 1.26 (flow-go
  # v0.51.1), and onflow/crypto compiles blst from C sources `go mod vendor` would drop.
  replayHelper = (buildGoModule.override { go = go_1_26; }) {
    pname = "cadence-replay-helper";
    version = "0.1.0-${builtins.substring 0 7 recorderRev}";
    src = recorderSrc + "/go-replay-helper";
    proxyVendor = true;
    vendorHash = "sha256-GRCucoCX20ujvkfXrCUvTrZcaoaB+R5tUhQ0BzUyqbY=";
    env.GOTOOLCHAIN = "local";
    # PORTABLE BLST. onflow/crypto's cgo init traps with SIGILL when the CPU lacks an
    # instruction its BLST build assumed (ADX/BMI2), and says to rebuild with this flag.
    # The deploy runners are a mixed pool: PR #78's preview deploy (run 39699235392,
    # runner mcl-004) died in `flow_crypto_cgo_init` with exit 132 while #77 built the same
    # derivation on 2026-10-20. Portable BLST selects its code path at run time.
    env.CGO_CFLAGS = "-O2 -D__BLST_PORTABLE__";
    postInstall = ''
      mv $out/bin/go-replay-helper $out/bin/cadence-replay-helper
    '';
  };

  # The one block the committed inputs describe.
  block = "168391034";
  inputs = "fixtures/chain-inputs/flow-mainnet/${block}";

  captureSrc = lib.fileset.toSource {
    root = blocktracerRoot;
    fileset = lib.fileset.unions [
      (blocktracerRoot + "/tools/chain")
      (blocktracerRoot + "/${inputs}")
      (blocktracerRoot + "/client/hydrate/engine-pin.txt")
    ];
  };

  # `just flow-capture`, inside the sandbox, with no network: the helper reads every
  # input from the transcripts. The output is a §5 snapshot tree.
  flowCaptureTree = stdenv.mkDerivation {
    name = "flow-mainnet-capture";
    src = captureSrc;
    nativeBuildInputs = [ nodejs bash ];
    CT_PRINT = "${ctPrint}/bin/ct-print";
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      bash tools/chain/flow-capture.sh \
        --recorder ${flowRecorder}/bin/codetracer-flow-recorder \
        --helper ${replayHelper}/bin/cadence-replay-helper \
        --recorder-commit ${recorderRev} \
        --inputs ${inputs} --out $TMPDIR/tree --work $TMPDIR/work
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
  inherit flowRecorder replayHelper flowCaptureTree ctPrint;
}
