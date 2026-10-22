# tools/chain/nix/sol.nix — Solana mainnet's containers, PRODUCED in the build.
#
# The route eth.nix and flow.nix take (Chain-Delivery DEL-5 route 3, DEL-6), written again
# for Solana rather than shared, for the reason flow.nix gives: DEL-7 extracts a seam from
# producers that already work, so each repeats the writer and ct-print expressions.
#
# WHAT RUNS IN THE SANDBOX. A Solana capture is a live forward-chained capture: it read
# account states the RPC no longer serves, so it cannot be repeated. What is repeated is
# every traced transaction's REPLAY: `tools/chain/sol-capture.mjs` unpacks the committed
# inputs under fixtures/chain-inputs/solana-mainnet/<window> (the window's enumeration, the
# live verdict lines, and one content-addressed replay bundle per traced transaction),
# runs each bundle through `codetracer-solana-recorder replay-bundle` (LiteSVM over Agave
# 4.3's runtime and SBF VM), requires each verdict to equal the live one, and produces the
# §5 tree. The containers exist only in the store; the recorder derives each recording id
# and records relative paths, so two builds are byte-identical (and identical to what the
# live capture wrote — measured over the committed window, 60 of 60).
#
# IN `produced-captures` AS `solana-mainnet` since 2026-10-22. Until then its prestate
# token, `forward-capture`, was outside Chain-Support-Matrix.md §1.4's set and the reader
# refused the tree (`S5-PRESTATE-CLOSED`); the operator added the row that day, and nothing
# here had to change.
#
# THE PINS (flake.nix states the revisions):
#
#   * `codetracer-solana-recorder`: the recorder at the revision that writes the replay
#     bundles and derived recording ids the committed inputs were captured with.
#   * `flow-trace-format`: the recorder's Cargo path dependencies. Its revision (3fada0b)
#     is exactly the one the Solana recorder's own `repro.lock` names, so the input is
#     shared with chain three rather than declared twice.
#   * `codetracer-trace-format-nim`: the writer at `7b8b587`, the last revision that writes
#     `meta.dat` 6, shared with eth.nix and flow.nix because the engine the site pins reads
#     6 only.
{ lib, stdenv, runCommand, rustPlatform, pkg-config, capnproto, openssl, zstd, pcre, nim
, nodejs
, recorderSrc, recorderRev, solTraceFormatSrc, writerSrc, writerNimDeps
, blocktracerRoot }:

let
  nimDepFlags = lib.concatMapStringsSep " " (p: "--path:${p}") writerNimDeps;

  # As flow.nix: the writer's C FFI archive, through the writer's own `build_ffi.nims`.
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

  # As flow.nix: `ct-print` at the writer's revision, so it reads what the writer wrote.
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
  recorderTree = runCommand "solana-recorder-src" { } ''
    mkdir -p $out
    cp -r ${recorderSrc} $out/codetracer-solana-recorder
    cp -r ${solTraceFormatSrc} $out/codetracer-trace-format
    chmod -R u+w $out
  '';

  solanaRecorder = rustPlatform.buildRustPackage {
    pname = "codetracer-solana-recorder";
    version = "0.1.0-${builtins.substring 0 7 recorderRev}";
    src = recorderTree;
    sourceRoot = "solana-recorder-src/codetracer-solana-recorder";
    cargoLock.lockFile = recorderSrc + "/Cargo.lock";
    cargoBuildFlags = [ "--bin" "codetracer-solana-recorder" ];
    CODETRACER_TRACE_WRITER_NIM_PREBUILT = writerFfi;
    # A dependency turns on openssl-sys's vendored build, which needs perl to compile
    # OpenSSL from source; link the openssl in buildInputs instead.
    OPENSSL_NO_VENDOR = 1;
    nativeBuildInputs = [ pkg-config capnproto ];
    buildInputs = [ openssl zstd ];
    # The recorder's suite (including its pinned mainnet replay fixtures) runs in its own CI.
    doCheck = false;
  };

  # The one window the committed inputs describe.
  window = "459262600-459262602";
  inputs = "fixtures/chain-inputs/solana-mainnet/${window}";

  captureSrc = lib.fileset.toSource {
    root = blocktracerRoot;
    fileset = lib.fileset.unions [
      (blocktracerRoot + "/tools/chain")
      (blocktracerRoot + "/${inputs}")
    ];
  };

  solCaptureTree = stdenv.mkDerivation {
    name = "solana-mainnet-capture";
    src = captureSrc;
    nativeBuildInputs = [ nodejs ];
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      node tools/chain/sol-capture.mjs \
        --recorder ${solanaRecorder}/bin/codetracer-solana-recorder \
        --recorder-commit ${recorderRev} \
        --ct-print ${ctPrint}/bin/ct-print \
        --fixture ${inputs} --out $TMPDIR/tree --work $TMPDIR/work
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
  inherit solanaRecorder solCaptureTree ctPrint;
}
