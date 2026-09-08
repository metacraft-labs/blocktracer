# tools/chain/nix — the chain follower, packaged.
#
# ═══════════════════════════════════════════════════════════════════════════════
# WHAT THIS IS FOR
# ═══════════════════════════════════════════════════════════════════════════════
#
# `tools/chain/follow-chain.mjs` has only ever run by hand, on a workstation, out
# of a git worktree, against three artefacts a developer happened to have built.
# `metacraft-labs/infra`'s `services/blocktracer-ingest` wants to run it as a
# resident systemd unit, and declares the shape it needs as four `nullOr` options
# that fail at EVAL time naming whichever is missing:
#
#     mcl.blocktracer-ingest.blocktracerSrc        tools/chain/follow-chain.mjs + tools/chain/lib
#     mcl.blocktracer-ingest.runtime.src           an aztec-avm-runtime with replay/tools/…
#     mcl.blocktracer-ingest.runtime.avmWasm       avm.wasm, --import-memory build
#     mcl.blocktracer-ingest.runtime.ctWriterWasm  aztec_ct_writer.wasm
#     mcl.blocktracer-ingest.nodePackage           the node BOTH halves run on
#
# The outputs here are shaped to be dropped straight into those options — that is
# the interface, and it is not changed here.
#
# ═══════════════════════════════════════════════════════════════════════════════
# THE NODE VERSION, WHICH WAS THE REASON TO LOOK AT ANY OF THIS — AND MEASURED
# ═══════════════════════════════════════════════════════════════════════════════
#
# The claim carried into the infra module is that the follower needs node ≥ 24
# "because the driver runs with `--experimental-wasm-exnref`", while blocktracer's
# devshell pins `nodejs_22` — so the follower had, by construction, never run
# inside the devshell it is developed in. That divergence is the defect shape this
# repository has already paid for once.
#
# It was measured rather than reasoned about, on 2026-09-07, on darwin-aarch64,
# with `nodejs_22` (22.20.0) and `nodejs_24` (24.11.1) from this flake's nixpkgs:
#
#   1. `--experimental-wasm-exnref` is ACCEPTED BY BOTH. Node 22 does not reject
#      the flag; the premise that the flag is what forces 24 is simply false.
#   2. The `--import-memory` `avm.wasm` COMPILES ON NODE 22 WITHOUT THE FLAG AT
#      ALL, and needs it on node 24 (which fails with
#      `invalid value type 'exn', enable with --experimental-wasm-exnref`).
#      The flag is a requirement of the NEWER V8, not of the older one.
#   3. `preflightToolchain`'s real probe — `node-host/src/loader.ts`'s
#      `compileAvm` — returns `PREFLIGHT_OK 13` on both.
#   4. THE WHOLE REPLAY, on both: `replay/tools/replay_settled_transaction.mjs`
#      --fixture replay/fixtures/testnet_replay_tx.json, a real settled testnet
#      transaction played back offline, produced on each of 22 and 24
#          verdict {"reproduced":true,"matched":23,"mismatched":0}
#          345 steps, revertCode 0, 188416-byte container
#      and the two `.ct` containers are BYTE-IDENTICAL —
#      sha256 6aa2e60432364688cb2d3442c1c8d80917222050a8abfdde0a17c096220f301e.
#
# So node ≥ 24 is not a requirement of the replay path, and `nodejs` here is the
# devshell's `nodejs_22`: ONE pin, used by the devshell, by this package, and —
# via `packages.chain-follower-nodejs` — by the infra module's `nodePackage`, so
# the three cannot drift apart again.
#
# WHAT WOULD JUSTIFY MOVING IT, stated so a future bump is deliberate: the
# runtime's `node-host/package.json` DECLARES `"engines": {"node": ">=24.0.0"}`.
# Nothing enforces that declaration on this path (node-host has no dependencies
# and is never `npm install`ed here) and the measurement above contradicts it for
# everything the follower does — but it is the runtime's own statement of intent,
# and if node-host ever reaches for a 24-only API this pin is where that lands.
# Change it in one place, and record what needed it.
#
# ═══════════════════════════════════════════════════════════════════════════════
# THE ONE INPUT THAT IS NOT PINNED HERE, AND WHY THAT IS SAID RATHER THAN HIDDEN
# ═══════════════════════════════════════════════════════════════════════════════
#
# `avmWasm` defaults to `null`, and a `null` means the wrapper requires `--avm` on
# the command line — exactly as the infra module supplies it from
# `cfg.runtime.avmWasm`. It is NOT vendored as a prebuilt blob, because a binary
# nobody can rebuild is worse than an absent one.
#
# It is absent for a stated reason and not an unexamined one. `avm.wasm` is a
# barretenberg build: aztec-packages @ 233d8e099336c1773b89e939100af047ed9c4f71
# (`pins.json`'s `cpp` anchor) with THIRTEEN patches applied — four from
# `codetracer-specs/upstream-bugs`, nine from `aztec-avm-runtime` itself —
# configured with the `wasm-avm` CMake preset against wasi-sdk 33. Every one of
# those inputs is pinned and fetchable, so this is buildable in principle. Two
# things stop it being built here:
#
#   * barretenberg's CMake calls `FetchContent_Populate` at CONFIGURE time
#     (httplib, and the libdeflate/nlohmann_json pair the closure names), which a
#     nix sandbox has no network for. Prefetching each and passing
#     `FETCHCONTENT_SOURCE_DIR_<name>` + `FETCHCONTENT_FULLY_DISCONNECTED=ON` is
#     the known shape of the fix; it is work, not a trick.
#   * `verification/lib_avm_wasm.sh` asserts 8 GB of free work space before it
#     starts, and the machine this was packaged on had 14 GB free with a 12 GB
#     floor. A build that would have to be abandoned halfway is not evidence.
#
# Until that derivation exists, `runtime.avmWasm` stays an operator-supplied path
# and this file says so instead of pretending otherwise.
#
# ═══════════════════════════════════════════════════════════════════════════════
# BUILT ON THE PLATFORM IT DEPLOYS TO — 2026-09-08
# ═══════════════════════════════════════════════════════════════════════════════
#
# Everything above was measured on aarch64-darwin. The systemd unit runs on
# x86_64-linux, and until this date not one of these four derivations had ever
# been BUILT there. They EVALUATED there, which is a statement about this
# expression and not about the compiler, the npm cache or the linker — and no
# job in any of `.github/workflows/`'s five files named a single one of these
# outputs, so nothing would have reported it if they had stopped building.
#
# `ci.yml`'s `chain-follower-linux` job is what closed that. All four built
# COLD, from source, on a bare-metal NixOS runner: 115 derivations, with
# `aztec-ct-writer`'s release profile in 32 s and the whole job in 2 min 2 s
# (run 34229795600, gpu-server-002-mcl-003). The green verdict is run
# 34230315685 on a sibling runner sharing that host's store, in 32 s — which is
# also the measurement that says what this gate costs to keep.
#
# WHAT THE LINUX BUILD SHOWED THAT THE DARWIN ONE COULD NOT:
#
#   * THE FIXED-OUTPUT npm HASH IS NOT A DARWIN HASH — and the reason it is not
#     is worth writing down, because the obvious check for it is wrong.
#     `replay/node_modules` carries 19 native prebuilds and they are
#     deliberately NOT all Linux: 8 ELF64-x86-64, 3 ELF64-aarch64, 3 ELF32-arm,
#     3 Mach-O and 2 Windows PE. `@aztec/bb.js` ships four platforms inside one
#     package and `leveldown` ships nine; a Mach-O sitting beside an ELF is
#     those packages working as designed, and a gate that refused on its
#     presence — the first version of this one did, and failed — would be
#     unpassable everywhere. The question is which object node SELECTS. On
#     linux-x64 that is `bb.js/build/amd64-linux/nodejs_module.node` and
#     `leveldown/prebuilds/linux-x64/node.napi.glibc.node`; both are
#     ELF64-x86-64, and all three `@aztec` packages the replay driver declares
#     import successfully under this `nodejs`. So a hash computed on darwin
#     yields a working Linux tree. That was an open question; it is now a
#     measured one.
#   * `aztec_ct_writer.wasm`, linked by the Linux `lld` this file names rather
#     than a rustup toolchain's, is 268,136 bytes with 39 exports and 0 imports
#     and compiles under the packaged node.
#   * The wrapper's argument passthrough — the `set --` defect recorded at the
#     wrapper below, which built perfectly and dropped every argument — is
#     asserted on Linux by two probes that differ only in the message they are
#     required to produce, because exit code alone cannot tell them apart.
#
# `avm.wasm` is unchanged by any of this. It is still `null`, still
# operator-supplied, and still for the reasons in the section above; nothing
# here replays, on Linux or anywhere else.
{
  lib,
  stdenv,
  stdenvNoCC,
  nodejs,
  git,
  coreutils,
  fetchNpmDeps,
  npmHooks,
  rustPlatform,
  capnproto,
  lld,
  writeShellApplication,

  # Sources, all pinned by the flake's lock.
  blocktracerSrc,
  avmRuntimeSrc,
  avmRuntimeRev,
  traceFormatSrc,
  traceFormatRev,

  # The one input this repository cannot yet build. See the header.
  avmWasm ? null,
}:

let
  # ── The chain tooling itself ────────────────────────────────────────────────
  #
  # `tools/chain` and nothing else: the follower, its `lib/`, and the sibling
  # tools it shares that library with. No npm dependencies — the tooling imports
  # only `node:` builtins and its own modules, which is why a plain source
  # derivation is a complete answer here and is not one for the runtime below.
  chainTools = stdenvNoCC.mkDerivation {
    pname = "blocktracer-chain-tools";
    version = "0";
    src = blocktracerSrc;

    dontBuild = true;
    dontConfigure = true;

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/tools"
      cp -r tools/chain "$out/tools/chain"
      # The module names this exact path; assert it rather than assume the copy.
      test -f "$out/tools/chain/follow-chain.mjs"
      test -f "$out/tools/chain/lib/replay.mjs"
      runHook postInstall
    '';

    meta = {
      description = "BlockTracer's Aztec chain tooling (follow-chain.mjs and its library)";
    };
  };

  # ── The replay runtime ──────────────────────────────────────────────────────
  #
  # A FIFTH INPUT THE MODULE'S INTERFACE DOES NOT NAME, and it is the one that
  # would have turned "it builds" into "it crashes on first catch":
  # `replay/tools/replay_settled_transaction.mjs` imports `@aztec/foundation`,
  # `@aztec/stdlib` and `@aztec/protocol-contracts`, so a bare source export of
  # `aztec-avm-runtime` cannot replay anything. The live workstation follower has
  # 545 MB of `replay/node_modules` beside it, installed by hand and invisible in
  # the option that points at the checkout.
  #
  # So this derivation IS the checkout plus that install, done offline from the
  # committed `package-lock.json`. `--omit=dev` on purpose: the single devDep is
  # `@aztec/noir-protocol-circuits-types` (92 MB), which exists for a pin
  # re-derivation check and which nothing the follower runs imports.
  avmRuntime = stdenv.mkDerivation (finalAttrs: {
    pname = "aztec-avm-runtime-replay";
    version = builtins.substring 0 10 avmRuntimeRev;
    src = avmRuntimeSrc;

    nativeBuildInputs = [
      nodejs
      nodejs.python
      npmHooks.npmConfigHook
    ];

    # Only the two lock-bearing files, not the whole checkout: a fetcher whose
    # input hash moved every time an unrelated source file changed would refetch
    # 300 MB of registry tarballs for a comment edit.
    npmDeps = fetchNpmDeps {
      name = "${finalAttrs.pname}-npm-deps";
      src = stdenvNoCC.mkDerivation {
        name = "aztec-avm-runtime-replay-lock";
        dontUnpack = true;
        installPhase = ''
          mkdir -p "$out"
          cp ${avmRuntimeSrc}/replay/package.json ${avmRuntimeSrc}/replay/package-lock.json "$out/"
        '';
      };
      hash = "sha256-LL2KQXpO0qBLiGK5yeiISoHyLdNJnANHFOYDwUf5I1A=";
    };
    npmRoot = "replay";

    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      ( cd replay && npm ci --omit=dev --offline --no-audit --no-fund --ignore-scripts )
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r . "$out/"

      # WHAT THE FOLLOWER ASKS OF A RUNTIME, asserted here so a layout change is a
      # build failure rather than a refusal hours into a watch.
      test -f "$out/replay/tools/replay_settled_transaction.mjs"
      test -f "$out/node-host/src/loader.ts"          # preflightToolchain's probe
      test -f "$out/replay/src/artifact_resolution.ts" # resolverPresence's gate
      test -d "$out/replay/node_modules/@aztec/stdlib"

      # ── PROVENANCE WITHOUT A .git ────────────────────────────────────────────
      #
      # follow-chain.mjs stamps `provenance.runtimeCommit` from `git rev-parse HEAD`
      # run inside the runtime. A store path has no `.git`, and `run()` does not
      # throw on a non-zero exit — so the packaged follower would have recorded an
      # EMPTY runtime commit and every capture would have claimed no recorder
      # version, silently. The revision is known at build time; write it where the
      # follower's fallback reads it.
      printf '%s\n' ${lib.escapeShellArg avmRuntimeRev} > "$out/.runtime-commit"
      runHook postInstall
    '';

    dontFixup = true;

    meta = {
      description = "aztec-avm-runtime's replay driver with its npm dependencies installed offline";
    };
  });

  # ── The trace-container writer ──────────────────────────────────────────────
  #
  # `verification/build_ct_writer_wasm.sh` materialises `codetracer-trace-format`
  # at `pins.json`'s `trace_format` anchor into `ct-writer/build-wasm-deps/ctf`
  # and builds `--target wasm32-unknown-unknown`. The same thing, with the anchor
  # coming from the flake lock instead of a `git archive` out of a sibling
  # checkout — which is the whole difference between "works here" and "builds
  # anywhere".
  #
  # The extracted tree keeps its own `[workspace]` root, deliberately: the script
  # records that our crate must stay OUTSIDE that workspace while its path
  # dependencies are members of it, and one checkout reached by three paths is
  # what stops two copies of `codetracer_trace_types` becoming two distinct types.
  ctWriterWasm = rustPlatform.buildRustPackage {
    pname = "aztec-ct-writer-wasm";
    version = "0.0.0";

    src = stdenvNoCC.mkDerivation {
      name = "aztec-ct-writer-src";
      dontUnpack = true;
      installPhase = ''
        mkdir -p "$out"
        cp -r ${avmRuntimeSrc}/ct-writer/. "$out/"
        chmod -R u+w "$out"
        mkdir -p "$out/build-wasm-deps/ctf"
        cp -r ${traceFormatSrc}/. "$out/build-wasm-deps/ctf/"
        chmod -R u+w "$out"
        printf '%s\n' ${lib.escapeShellArg traceFormatRev} > "$out/build-wasm-deps/materialised-at"
      '';
    };

    cargoLock.lockFile = "${avmRuntimeSrc}/ct-writer/Cargo.lock";
    postPatch = ''
      cp ${avmRuntimeSrc}/ct-writer/Cargo.lock Cargo.lock
    '';

    # `capnp` is a HARD build-time dependency whose absence does not say so: the
    # build dies inside codetracer_trace_format_capnp's build script four crates
    # deep, which reads like a broken branch. The upstream script says the same.
    #
    # `lld` is the wasm32 target's linker. Every crate in the graph compiles
    # without it and the failure lands on the LAST step, as `linker `lld` not
    # found` — several minutes of green output and then nothing to link with.
    # The workstation build gets it from the rustup toolchain, which is exactly
    # the ambient dependency this package exists to remove.
    nativeBuildInputs = [ capnproto lld ];

    # THE BUILD PHASE IS WRITTEN OUT RATHER THAN CONFIGURED, and the reason is a
    # measured failure. `cargoBuildHook` always passes the HOST target, so adding
    # `--target wasm32-unknown-unknown` to `cargoBuildFlags` asks cargo for TWO
    # targets at once. That builds the whole graph for darwin as well — `ring`,
    # `zstd-sys` — and unifies features across both, which is how `uuid` acquired
    # a randomness feature it does not have in a wasm-only build and failed with
    # `to use uuid on wasm32-unknown-unknown, specify a source of randomness`.
    # The upstream script builds one target and so does this.
    buildPhase = ''
      runHook preBuild
      cargo build --release --offline --target wasm32-unknown-unknown -j "$NIX_BUILD_CORES"
      runHook postBuild
    '';

    doCheck = false; # the crate's tests are native; wasm32 has no test harness

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/lib"
      cp target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm "$out/lib/"
      runHook postInstall
    '';

    meta = {
      description = "aztec_ct_writer.wasm — the .ct container writer, built for wasm32";
    };
  };

  ctWriterWasmFile = "${ctWriterWasm}/lib/aztec_ct_writer.wasm";

  # ── The follower ────────────────────────────────────────────────────────────
  #
  # Every path here is a store path. `runtimeInputs` puts `git` and `coreutils` on
  # PATH because the follower shells out to `git rev-parse` for provenance — the
  # unit's PATH is not a developer's, which is the whole point of packaging it.
  #
  # NOT A `command -v node` WRAPPER. `--node` is passed the SAME interpreter this
  # script is executed by, so the follower and the replay driver it spawns cannot
  # be two different runtimes; a wrapper that found whatever node was on PATH
  # would reproduce the defect this package exists to remove.
  follower = writeShellApplication {
    name = "blocktracer-follow-chain";
    runtimeInputs = [ nodejs git coreutils ];
    # `set --` RATHER THAN AN INTERPOLATED CONTINUATION LINE. The first version of
    # this wrapper put `${"\${lib.optionalString …}"}` on its own backslash-continued
    # line; with `avmWasm = null` that line went empty, the continuation swallowed
    # the newline, and `"$@"` became a SEPARATE COMMAND — so every argument the
    # caller passed was silently dropped and the tool refused for a missing `--avm`
    # it had in fact been given. It built perfectly and failed on first use, which
    # is the exact defect a packaging task is supposed to remove.
    text = ''
      ${lib.optionalString (avmWasm != null) ''set -- --avm ${avmWasm} "$@"''}
      exec ${nodejs}/bin/node ${chainTools}/tools/chain/follow-chain.mjs \
        --runtime ${avmRuntime} \
        --ct-writer ${ctWriterWasmFile} \
        --node ${nodejs}/bin/node \
        "$@"
    '';
  };

in
{
  inherit chainTools avmRuntime ctWriterWasm follower;
  nodePackage = nodejs;
}
