# tools/chain/nix/sui.nix — Sui mainnet's containers, PRODUCED in the build.
#
# The route eth.nix and flow.nix take (Chain-Delivery DEL-5, route 3), written again for
# Sui rather than shared: DEL-6/DEL-7 extract a seam only from producers that already
# worked without one. The writer and ct-print derivations are the same expressions as
# flow.nix's, repeated rather than imported for that reason.
#
# WHAT RUNS IN THE SANDBOX. Per committed window, `tools/chain/capture-sui-range.mjs
# --transcript` serves that window's GraphQL transcript (fixtures/chain-inputs/sui-mainnet/<window>) on
# loopback and points everything at it: its own checkpoint and effects reads, and
# `sui replay --trace --node <loopback>`, which re-executes each transaction from exactly
# the object versions it consumed. A request the transcript does not hold fails the build.
# Recording ids are derived from each transaction (`--recording-id derive`) and the clock
# readings pinned (`--fixed-time`), so the tree is byte-identical build to build; the
# container exists only in the store, and nothing is committed for
# `ban-added-ct-recordings` to object to.
#
# THE PINS (flake.nix states the revisions):
#
#   * `codetracer-move-recorder`: the recorder, at the revision that derives recording ids.
#   * `flow-trace-format`: its Cargo path dependencies — `3fada0b`, exactly the revision
#     the recorder's own `repro.lock` names (sol.nix takes the same input for the same
#     reason).
#   * `codetracer-trace-format-nim`: the writer at `7b8b587`, the last revision that writes
#     `meta.dat` 6, shared with eth.nix and flow.nix, because the engine the site pins reads
#     6 only.
#   * `sui`: the official MystenLabs release binary, built with the `tracing` feature that
#     `sui replay --trace` needs, at the version the transcript was recorded with (1.81.1).
#     nix-blockchain-development packages `sui` for Linux only and at 1.68.1, which predates
#     mainnet's current protocol, so the release archive is fetched instead.
{ lib, stdenv, runCommand, fetchurl, rustPlatform, autoPatchelfHook, pkg-config
, openssl, zstd, pcre, nim, nodejs, bash, zlib
, recorderSrc, recorderRev, suiTraceFormatSrc, writerSrc, writerNimDeps
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
  recorderTree = runCommand "move-recorder-src" { } ''
    mkdir -p $out
    cp -r ${recorderSrc} $out/codetracer-move-recorder
    cp -r ${suiTraceFormatSrc} $out/codetracer-trace-format
    chmod -R u+w $out
  '';

  moveRecorder = rustPlatform.buildRustPackage {
    pname = "codetracer-move-recorder";
    version = "0.1.0-${builtins.substring 0 7 recorderRev}";
    src = recorderTree;
    sourceRoot = "move-recorder-src/codetracer-move-recorder";
    cargoLock.lockFile = recorderSrc + "/Cargo.lock";
    cargoBuildFlags = [ "--bin" "codetracer-move-recorder" ];
    CODETRACER_TRACE_WRITER_NIM_PREBUILT = writerFfi;
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ zstd ];
    # The recorder's suite runs in its own repository and needs `sui` and `ct-print`.
    doCheck = false;
  };

  # The official release archive. Its `sui` is built with `tracing`; on Linux it is a
  # dynamically linked ELF, patched to the store's loader and libraries.
  suiVersion = "1.81.1";
  suiArchive = {
    x86_64-linux = { asset = "ubuntu-x86_64"; sha256 = "1m5m65w3qrgkhl6cd31swmy4b6l1axn279q87yyf4nnzvq7r28fr"; };
    aarch64-linux = { asset = "ubuntu-aarch64"; sha256 = "10qmllab2v5a55j4zhq441kh4dakb3jxixgjs76mb7xg2y298bac"; };
    aarch64-darwin = { asset = "macos-arm64"; sha256 = "0z6c4lj5jh2dwq1bcxmpak4zrprb9qa1lby24w3q5114hsa21l6c"; };
  }.${stdenv.hostPlatform.system} or (throw "sui.nix: no sui ${suiVersion} release for ${stdenv.hostPlatform.system}");
  sui = stdenv.mkDerivation {
    pname = "sui";
    version = suiVersion;
    src = fetchurl {
      url = "https://github.com/MystenLabs/sui/releases/download/mainnet-v${suiVersion}/sui-mainnet-v${suiVersion}-${suiArchive.asset}.tgz";
      inherit (suiArchive) sha256;
    };
    sourceRoot = ".";
    nativeBuildInputs = lib.optionals stdenv.isLinux [ autoPatchelfHook ];
    buildInputs = lib.optionals stdenv.isLinux [ stdenv.cc.cc.lib openssl zlib ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      runHook preInstall
      install -Dm755 sui $out/bin/sui
      runHook postInstall
    '';
  };

  # The committed windows, each a GraphQL transcript under fixtures/chain-inputs/sui-mainnet.
  # 28,845,372..28,845,373 straddles the traced floor (protocol 36 below, refused; 38
  # above, traced); 336,000,001 is the modern era. A chain's history is published as the
  # UNION of its ranges (tools/chain/merge-sui-windows.mjs), as ingest-range.mjs does.
  windows = [
    { from = 28845372; to = 28845373; dir = "28845372-28845373"; }
    { from = 336000001; to = 336000001; dir = "336000001"; }
  ];

  captureSrc = lib.fileset.toSource {
    root = blocktracerRoot;
    fileset = lib.fileset.unions ([ (blocktracerRoot + "/tools/chain") ]
      ++ map (w: blocktracerRoot + "/fixtures/chain-inputs/sui-mainnet/${w.dir}") windows);
  };

  # `capture-sui-range.mjs --transcript` for ONE window, inside the sandbox, with no
  # network. Each window is its own derivation, so one window's inputs changing rebuilds
  # that window and the union, never the others.
  captureWindow = w: stdenv.mkDerivation {
    name = "sui-mainnet-capture-${toString w.from}-${toString w.to}";
    src = captureSrc;
    nativeBuildInputs = [ nodejs bash ];
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      node tools/chain/capture-sui-range.mjs \
        --transcript fixtures/chain-inputs/sui-mainnet/${w.dir} \
        --from ${toString w.from} --to ${toString w.to} --max 1000 \
        --fixed-time 2026-10-22T00:00:00.000Z \
        --recorder ${moveRecorder}/bin/codetracer-move-recorder \
        --recorder-commit ${recorderRev} \
        --positions-reader ${moveRecorder}/bin/codetracer-move-recorder \
        --sui ${sui}/bin/sui \
        --ct-print ${ctPrint}/bin/ct-print \
        --work $TMPDIR/work --out $TMPDIR/tree
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -r $TMPDIR/tree $out
      test -s $out/snapshot.json
      runHook postInstall
    '';
  };
  windowTrees = map captureWindow windows;

  # `just sui-capture`: the union of the windows, as one §5 snapshot tree.
  suiCaptureTree = stdenv.mkDerivation {
    name = "sui-mainnet-capture";
    src = captureSrc;
    nativeBuildInputs = [ nodejs ];
    buildPhase = ''
      runHook preBuild
      node tools/chain/merge-sui-windows.mjs \
        ${lib.concatMapStringsSep " " (t: "--tree ${t}") windowTrees} \
        --out $TMPDIR/tree
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
  inherit moveRecorder sui suiCaptureTree ctPrint;
}
