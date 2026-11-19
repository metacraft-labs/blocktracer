# tools/chain/nix/aptos.nix — Aptos mainnet's containers, PRODUCED in the build.
#
# The route sui.nix takes, written again for Aptos rather than shared (DEL-6/DEL-7 extract
# a seam only from producers that already worked without one). The writer and ct-print
# derivations are the same expressions as sui.nix's, so they are the same store paths.
#
# IN `produced-captures` ON x86_64-LINUX, AND IN THE `journeys-aptos` CI JOB, since the
# operator decided so on 2026-11-12. The fork's `aptos` CLI takes about an hour to build
# cold, and that cost is accepted on every deploy and CI run without a cached copy. Build
# it by name: `nix build .#aptos-capture-tree`.
#
# WHAT RUNS IN THE SANDBOX. `tools/chain/capture-aptos-range.mjs --transcript` serves the
# committed REST transcript (fixtures/chain-inputs/aptos-mainnet/1158421321-1158421323) on
# loopback and points everything at it: its own ledger and block reads, and `aptos move
# replay --trace` through `codetracer-move-recorder aptos-replay`, which reads every state
# value at the version before the transaction. A request the transcript does not hold
# fails the build. Recording ids are derived from each transaction and the clock is pinned,
# so the tree is byte-identical build to build. It is the same invocation as
# `just aptos-capture`, with every tool taken from the store.
#
# THE SOURCE IS RESOLVED IN THE SANDBOX TOO. For every module a transaction entered, the
# capture reads the package registry its account published at the version before the
# transaction (`0x1::code::PackageRegistry`, from the same transcript) and compiles the
# published source with the same `aptos` CLI (`tools/chain/lib/aptos-source.mjs`); a module
# whose compiled bytes equal the chain's is recorded on that source. Compiling needs no
# network: every dependency is another package of the same registries, laid out locally.
#
# THE PINS (flake.nix states the revisions):
#
#   * `aptos-core`: metacraft-labs/aptos-core, branch
#     `codetracer/value-tracing-aptos-node-v1.49.8`, at 988a7e9288 — the value tracer on
#     mainnet's aptos-node v1.49.8. Only its `aptos` CLI is built.
#   * the Rust toolchain: 1.94.1, the one the fork's `rust-toolchain.toml` names, from
#     rust-overlay. nixpkgs' rustc is newer, and the window was recorded with 1.94.1.
#   * `codetracer-move-recorder-aptos`: the recorder at a revision with the Aptos path
#     (`aptos-replay`) that steps a module on its published source when it is proved against
#     its bytes (`fed70f3`). It is a separate input from Sui's `codetracer-move-recorder`, so
#     Sui's produced tree does not move.
#   * `aptos-trace-format`: the recorder's Cargo path dependencies, at the revision that
#     recorder revision's own `repro.lock` names.
#   * `codetracer-trace-format-nim`: the writer, shared with sui.nix.
#
# THE TARGET CPU. aptos-core's `.cargo/config.toml` builds x86_64 with
# `-C target-cpu=x86-64-v3` and `-march=x86-64-v3`, which needs AVX2. high-mem-server is a
# Sandy Bridge Xeon without it, so a binary built that way dies there with SIGILL. The flags
# below are the config's own, minus the CPU level (RUSTFLAGS replaces
# `target.<triple>.rustflags`, and an exported CFLAGS_<triple> wins over `[env]`), which is
# how the CLI that recorded the window was built. The result is generic x86-64 code, so it also runs on
# an x86-64-v3 CI runner; it is only slower there. Measured: the four containers it records
# are byte-identical to the ones a CLI built outside Nix records. `-mpclmul` stays, because RocksDB's build
# needs it.
{ lib, stdenv, stdenvNoCC, runCommand, makeRustPlatform, cacert, git, llvmPackages, pkg-config, protobuf, cmake
, perl, openssl, systemd, zlib, elfutils, postgresql, zstd, pcre, nim, nodejs, bash, curl
, rustToolchain
, aptosCoreSrc, aptosCoreRev
, recorderSrc, recorderRev, aptosTraceFormatSrc, writerSrc, writerNimDeps
, blocktracerRoot }:

let
  nimDepFlags = lib.concatMapStringsSep " " (p: "--path:${p}") writerNimDeps;

  # As sui.nix: the writer's C FFI archive, through the writer's own `build_ffi.nims`.
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

  # As sui.nix: `ct-print` at the writer's revision, so it reads what the writer wrote.
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
  recorderTree = runCommand "move-recorder-aptos-src" { } ''
    mkdir -p $out
    cp -r ${recorderSrc} $out/codetracer-move-recorder
    cp -r ${aptosTraceFormatSrc} $out/codetracer-trace-format
    chmod -R u+w $out
  '';

  moveRecorder = (makeRustPlatform { rustc = rustToolchain; cargo = rustToolchain; }).buildRustPackage {
    pname = "codetracer-move-recorder";
    version = "0.1.0-${builtins.substring 0 7 recorderRev}";
    src = recorderTree;
    sourceRoot = "move-recorder-aptos-src/codetracer-move-recorder";
    cargoLock.lockFile = recorderSrc + "/Cargo.lock";
    cargoBuildFlags = [ "--bin" "codetracer-move-recorder" ];
    CODETRACER_TRACE_WRITER_NIM_PREBUILT = writerFfi;
    nativeBuildInputs = [ pkg-config ];
    buildInputs = [ zstd ];
    # The recorder's suite runs in its own repository and needs `aptos` and `ct-print`.
    doCheck = false;
  };

  # The workspace's crates, vendored by cargo itself, as one fixed-output derivation.
  #
  # NOT nixpkgs' `cargoLock` or `cargoHash`. Both find each git dependency's crates by
  # running `cargo metadata` inside its checkout, and the `algebra` fork's root is a
  # virtual manifest with a `[lints]` table, which cargo refuses to parse that way ("this
  # virtual manifest specifies a `lints` section"). `cargo vendor` loads a git dependency
  # the way a build does, which accepts it. The config it prints names the vendor
  # directory by its store path, so that path is replaced by a placeholder: a
  # fixed-output derivation may not refer to itself.
  aptosVendor = stdenvNoCC.mkDerivation {
    name = "aptos-${builtins.substring 0 10 aptosCoreRev}-cargo-vendor";
    src = aptosCoreSrc;
    nativeBuildInputs = [ rustToolchain cacert git ];
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      export CARGO_HOME=$TMPDIR/cargo-home
      mkdir -p $out/.cargo
      cargo vendor --locked --versioned-dirs $out/vendor > $out/.cargo/config.toml
      substituteInPlace $out/.cargo/config.toml --replace-fail "$out/vendor" "@vendor@"
      runHook postBuild
    '';
    dontInstall = true;
    dontFixup = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-tuQ7uIFlATd8WzaDWeYnrYO00ST/094GR1p1CrrraWw=";
  };

  # The fork's `aptos` CLI, and nothing else of the workspace.
  #
  # A plain derivation running cargo, not `buildRustPackage`, because the vendor
  # directory above is cargo's own layout rather than the one nixpkgs' hooks expect.
  # The compiler is clang throughout: the workspace's `.cargo/config.toml` names `clang`
  # as the x86_64 linker, and RUSTFLAGS asks it for lld.
  aptosCli = llvmPackages.stdenv.mkDerivation {
    pname = "aptos";
    version = "1.49.8-codetracer-${builtins.substring 0 10 aptosCoreRev}";
    src = aptosCoreSrc;

    # `llvmPackages.bintools` and not `llvmPackages.lld`: the first is the WRAPPED
    # `ld.lld` that `-fuse-ld=lld` finds on PATH. The bare one links with no RUNPATH and
    # the wrong loader, so the binary finds neither libssl nor libstdc++ at run time.
    nativeBuildInputs = [ rustToolchain pkg-config protobuf cmake perl llvmPackages.bintools ];
    # `stdenv.cc.cc.lib` is libstdc++: RocksDB and the other C++ crates link it, and
    # clang's stdenv does not put it on the RUNPATH by itself, so without it the binary
    # builds and then cannot start.
    buildInputs = [ openssl systemd zlib llvmPackages.libclang.lib elfutils postgresql.lib
                    stdenv.cc.cc.lib ];
    # cmake is here for the crates whose build scripts call it, not to configure this tree.
    dontUseCmakeConfigure = true;
    LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";
    PROTOC = "${protobuf}/bin/protoc";

    # `.cargo/config.toml`'s x86_64 rustflags with `-C target-cpu=x86-64-v3` taken out, and
    # its C flags with `-march=x86-64-v3` taken out. See the header.
    RUSTFLAGS = "--cfg tokio_unstable -C link-arg=-fuse-ld=lld -C force-frame-pointers=yes -C force-unwind-tables=yes";
    CFLAGS_x86_64_unknown_linux_gnu = "-mpclmul";
    CXXFLAGS_x86_64_unknown_linux_gnu = "-mpclmul";
    # Debug info in a 300 MB binary is not used by anything here.
    CARGO_PROFILE_RELEASE_DEBUG = "false";

    configurePhase = ''
      runHook preConfigure
      export CARGO_HOME=$TMPDIR/cargo-home
      mkdir -p $CARGO_HOME
      sed "s|@vendor@|${aptosVendor}/vendor|g" ${aptosVendor}/.cargo/config.toml \
        > $CARGO_HOME/config.toml
      runHook postConfigure
    '';
    buildPhase = ''
      runHook preBuild
      cargo build --release --offline --locked -j $NIX_BUILD_CORES -p aptos --bin aptos
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 target/release/aptos $out/bin/aptos
      runHook postInstall
    '';
    doCheck = false;
    passthru.vendor = aptosVendor;

    meta.platforms = [ "x86_64-linux" ];
  };

  captureWindow = { from = 1158421321; to = 1158421323; dir = "1158421321-1158421323"; };

  captureSrc = lib.fileset.toSource {
    root = blocktracerRoot;
    fileset = lib.fileset.unions [
      (blocktracerRoot + "/tools/chain")
      (blocktracerRoot + "/fixtures/chain-inputs/aptos-mainnet/${captureWindow.dir}")
    ];
  };

  # `just aptos-capture`, inside the sandbox, with no network.
  aptosCaptureTree = stdenv.mkDerivation {
    name = "aptos-mainnet-capture";
    src = captureSrc;
    # `curl`: the recorder's `aptos-replay` fetches each entered module over REST with it
    # (from the loopback transcript server here, so still no network).
    nativeBuildInputs = [ nodejs bash curl ];
    buildPhase = ''
      runHook preBuild
      export HOME=$TMPDIR
      node tools/chain/capture-aptos-range.mjs \
        --transcript fixtures/chain-inputs/aptos-mainnet/${captureWindow.dir} \
        --from ${toString captureWindow.from} --to ${toString captureWindow.to} --max 1000 \
        --fixed-time 2026-11-03T00:00:00.000Z \
        --recorder ${moveRecorder}/bin/codetracer-move-recorder \
        --recorder-commit ${recorderRev} \
        --positions-reader ${moveRecorder}/bin/codetracer-move-recorder \
        --aptos ${aptosCli}/bin/aptos \
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
    meta.platforms = [ "x86_64-linux" ];
  };
in {
  inherit aptosCli aptosVendor moveRecorder ctPrint aptosCaptureTree;
}
