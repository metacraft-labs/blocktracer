{
  description = "BlockTracer — static block explorer. The IsoNim client (M5 skeleton) renders the demo data tree into a browsable explorer, built on the codetracer-design-system token set.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # isonim framework + nim-everywhere as pinned, source-only flake inputs, so a
    # public-repo / CI build is hermetic and does NOT depend on sibling
    # ../isonim and ../nim-everywhere checkouts. Both are Nim source trees,
    # consumed via the Nim search path (not as flakes) -> flake = false. Pins are
    # latest-mainline (default `dev` branch) SHAs, matching the sibling isonim
    # static sites (reprobuild-web-site / codetracer-web-site), recorded in the
    # isonim-sites registry.
    isonim = {
      url = "github:metacraft-labs/isonim/d2193dc4935039f5faa0836e0a26eed9e15f1a72";
      flake = false;
    };
    nim-everywhere = {
      url = "github:metacraft-labs/nim-everywhere/95977e85e3aa9f3d8f54ecb42fdc9505ac3d3107";
      flake = false;
    };
    # The Embed SDK's editor core reads IsoNim-TUI's width tables
    # (`editor/selection.nim`), so the hydration bundle needs it. Pinned with
    # isonim and nim-everywhere to the revisions codetracer's own `repro.lock`
    # names at `ci/embed-sdk-pin.env`'s CODETRACER_REF — the same three values
    # that file records, so the bundle nix builds is the one the pin names.
    isonim-tui = {
      url = "github:metacraft-labs/isonim-tui/594398d5962a911f89f18d77cc1794404858283d";
      flake = false;
    };

    # The canonical Metacraft design system — the DTCG token source of truth
    # (brand/alias/mapped JSON + vendored brand fonts). Consumed as JSON at
    # runtime by client/src/design_system/tokens.nim via DESIGN_SYSTEM_SRC, so a
    # hermetic build does not need a ../codetracer-design-system sibling.
    codetracer-design-system = {
      url = "github:metacraft-labs/codetracer-design-system/dfb1de1b0d86576beb9e9c6d1cf03c5438d1fa95";
      flake = false;
    };

    # The CodeTracer Embed SDK — needed by ONE compilation in this repository,
    # `client/hydrate/hydrate.nim`, the `nim js` bundle the debug route defers.
    # Everything else still builds with no debugger on the Nim path at all;
    # that is the layering (AGENTS.md §1a) and adding this input does not
    # change it, because nothing under `client/src` imports it.
    #
    # The revision MUST equal `ci/embed-sdk-pin.env`'s `CODETRACER_REF` — that
    # file is the one place naming the bytes this repository is built and
    # checked against, and a flake input that drifted from it would mean the
    # bundle CI ships and the Embed SDK CI's suites run against are two
    # different trees. `client/hydrate/build.sh` resolves `$CODETRACER_SRC`,
    # which `packages.default` sets from here.
    #
    # ── `submodules=0`, STATED, AND WHY IT CANNOT BE 1 ─────────────────────
    #
    # 5d1e44a set `submodules=1` to stop the lock's narHash and CI's resolved
    # narHash disagreeing. It settled that disagreement and introduced a worse
    # one: codetracer's `.gitmodules` carries `libs/tree-sitter-nim`, whose URL
    # is https://github.com/metacraft-labs/tree-sitter-nim.git, and THAT REPO
    # IS PRIVATE (`gh api repos/metacraft-labs/tree-sitter-nim` ->
    # `"private": true`). blocktracer is a PUBLIC repository whose CI
    # authenticates with `secrets.GITHUB_TOKEN`, which is scoped to this
    # repository and cannot read another repo's private contents. GitHub
    # answers such a fetch with 404, so every job that evaluated this input
    # died with the same four lines:
    #
    #   remote: Repository not found.
    #   fatal: repository '.../metacraft-labs/tree-sitter-nim.git/' not found
    #   error: Failed to fetch git repository '.../tree-sitter-nim.git'
    #   … while evaluating attribute 'CODETRACER_SRC' of derivation 'blocktracer-site'
    #
    # That is not a deploy bug even though the deploy is where it was noticed:
    # `deploy`, `journeys`, `debug-route`, `viewmodels`, `client-sdk` and
    # `contract` all failed identically on runs 34761732474 and 34778372790,
    # because they all evaluate `.#default`.
    #
    # WHY IT LOOKED GREEN FOR TWO WEEKS. It was never buildable from cold. The
    # deploys that succeeded on 2026-08-31 ran on a NixOS runner image with a
    # warm shared store — their logs say "Nix is already installed: nix (Nix)
    # 2.32.8", print no git fetch at all, and go straight to "this derivation
    # will be built", because the input's store path was already there. The
    # 2026-09-13 runs land on a machine that says "Nix is not installed, will
    # install it" and then fetches every input for real. Same runner group
    # name, same `eph-linux-x64` label, different machine — so a green run from
    # before the cutover is not evidence that this input could be fetched.
    # A workstation whose git credentials DO reach the private repo hides it
    # the same way, which is why it survived a local `nix build` at 5d1e44a.
    #
    # NOTHING HERE NEEDS THE SUBMODULES. Every consumer of `$CODETRACER_SRC` in
    # this repository reads `src/frontend/...`, `src/` or `ci/` from it —
    # `client/hydrate/build.sh` puts exactly `src/frontend/viewmodel`,
    # `src/frontend` and `src` on the Nim path — and not one path under
    # `libs/`. So the submodules were fetched for nothing and cost the whole
    # repository its ability to build. Measured: the site built from this
    # input with and without them differs in ONE file of 932, `hydrate.js`,
    # identical in length, differing only where Nim mangles the input's store
    # path into its symbol names.
    #
    # The `0` is spelled out rather than left to the default for the same
    # reason 5d1e44a wanted a `1`: the variant must be STATED, so the lock and
    # any fetcher compute one tree by construction and not by whichever
    # default a nix version happens to hold.
    #
    # ── IF YOU RE-LOCK THIS INPUT, DO IT WITH A COLD FETCHER CACHE ──────────
    #
    # `nix` memoises rev -> narHash in `~/.cache/nix/fetcher-cache-v*.sqlite`,
    # and because this input is pinned by rev it is treated as immutable, so
    # `--refresh` does NOT recompute it. A machine that once fetched this rev
    # under different fetcher options keeps answering with the old hash
    # forever. MEASURED on the workstation that produced 334204a..5d1e44a:
    #
    #   pristine cache, nix 2.25.2   sha256-ce3EtVQdz6vqLgSDKrm/NWZTL8Nz…
    #   pristine cache, nix 2.35.2   sha256-ce3EtVQdz6vqLgSDKrm/NWZTL8Nz…  (same)
    #   that machine's live cache    sha256-Ia/JuLW+qTestHjWmxdWPn4/T9/4…
    #   empty gitv3 + only that
    #     machine's sqlite copied in sha256-Ia/JuLW+qTestHjWmxdWPn4/T9/4…
    #
    # The last line is the proof: with no git objects present at all the stale
    # answer still comes back, so it is the memo and not the repository. CI
    # deletes `gitv3` and `fetcher-cache-v*.sqlite` before every job, which is
    # why the lock recorded on that workstation could never match CI's. Re-lock
    # with `XDG_CACHE_HOME=$(mktemp -d) nix flake lock --update-input codetracer`
    # and the two agree.
    codetracer = {
      # KEEP IN LOCK-STEP with `ci/embed-sdk-pin.env`'s `CODETRACER_REF`, which
      # carries the reason this value moved and the four gates it survived.
      url = "git+https://github.com/metacraft-labs/codetracer?ref=refs/heads/agents&rev=0d1325584b9e7c77d13bbb766077e3418395fe94&submodules=0";
      flake = false;
    };

    # ── The chain follower's two out-of-repo source inputs ──────────────────
    #
    # `tools/chain/follow-chain.mjs` is the only thing in this repository that
    # needs anything from outside it at RUN time: an `aztec-avm-runtime` to
    # replay with, and the `codetracer-trace-format` revision its `.ct` writer
    # is built against. Both were, until now, sibling checkouts a developer
    # happened to have — which is why the follower had never run anywhere but
    # one workstation. Pinned here so `nix build .#chain-follower` is the whole
    # answer. See tools/chain/nix/default.nix for what each is used for, and
    # for the ONE input (avm.wasm) that is still not built here and why.
    #
    # `flake = false`: both are consumed as source trees, not as flakes. The
    # runtime's own flake exposes only a wasi-sdk, which nothing here needs.
    # MOVED 75d1592a -> f972b415 ON 2026-10-14, AND THE MOVE IS THE DELIVERABLE.
    # At 75d1592a the `ct-writer` crate had no `[features]` block, no `build.rs`
    # and no `trace_format_nim_writer` anchor: there was ONE writer, the pure
    # Rust Path A, built against a `codetracer-trace-format` whose
    # `codetracer_ctfs/src/header.rs` declares `VERSION = 3` and whose
    # `meta_dat.rs` declares `META_DAT_VERSION = 3`, and which carries no file
    # matching "compact" at all.
    #
    # So `ctWriterWasm` below produced — measured 2026-10-14, by
    # `WebAssembly.Module.exports` on the module this flake builds — 38 ABI
    # functions plus `memory`, 0 imports, and NO
    # `ct_writer_set_compact_threshold`. Every container this repository has
    # ever published was written by a writer with no compact lever to pull, which
    # is the whole reason `ctfs-container.md` §1e's compact profile is unused
    # here rather than any decision about it.
    #
    # THE ANCHOR SET MOVED ON `agents` AND THIS BRANCH'S HOLD YIELDED TO IT.
    # This branch pinned the runtime at aeb67e6d and read `trace_format` /
    # `trace_format_nim` out of THAT revision's `pins.json` (3fada0b0 /
    # 051efd22b0). `agents` advanced the runtime to 75d1592a, whose `pins.json`
    # anchors `trace_format` at 592fa42c, and advanced the other two inputs
    # with it; `flake.lock` names that newer trio throughout. A merge cannot
    # hold half of an anchor set, and the mainline's advance is a decision
    # rather than drift, so all three follow it here. The paragraph below is
    # kept because WHY these are anchored together has not changed.
    #
    # Checked before following, because the one thing this must not do is
    # publish containers the deployed engine refuses: `7b8b587c`'s
    # `src/codetracer_trace_writer/meta_dat.nim` emits `MetaDatVersion = 6`,
    # and `client/hydrate/engine-pin.txt`'s engine accepts `meta.dat` [6].
    # Inside the ceiling.
    #
    # ONE THING IS LEFT FLAGGED RATHER THAN CHANGED: 75d1592a's `pins.json`
    # anchors `trace_format_nim` at baea0740 and `agents` pins 7b8b587c, so
    # that pair does not agree the way the aeb67e6d set did. Both are inside
    # the engine's ceiling, it is the Flow/EVM work's area and not this
    # branch's, and reverting it here would break those chains to satisfy a
    # comment this branch wrote. Raised with that work rather than resolved by
    # a merge.
    #
    # aeb67e6d was `agents` after CCP-6 (the lever reachable from
    # `replay/tools/replay_settled_transaction.mjs` as `--compact-threshold`) and
    # CCP-7 (the two hooks that let a nix sandbox build Path B at all — see
    # `ctWriterWasm`). The default feature there is `path-b`, the NIM writer,
    # which is a USER DECISION taken on measurement and recorded in
    # `ct-writer/Cargo.toml`: Path A linked `ruzstd`, which returns 4,194,304
    # bytes of wrong data where C libzstd refuses a frame corrupted under a
    # content checksum, and Path A has no in-memory reader. Building Path A to
    # avoid Path B's toolchain would reverse that decision silently, so this
    # builds what the runtime ships.
    aztec-avm-runtime = {
      url = "github:metacraft-labs/aztec-avm-runtime/75d1592a3d1ab4dc795e04d931c9f268b4973835";
      flake = false;
    };

    # `pins.json`'s `trace_format` anchor in the runtime revision above. It is
    # NOT a free choice: the ct-writer's three path dependencies must all come
    # from one checkout at that anchor, or two copies of `codetracer_trace_types`
    # become two distinct types that will not unify.
    codetracer-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/592fa42cbfd759cf13398180798daaf856eb7e9d";
      flake = false;
    };

    # ── THE WRITER ITSELF, which was never an input and had to become one ────
    #
    # `pins.json`'s `trace_format_nim_writer` anchor in the runtime revision
    # above. A THIRD anchor appeared there on 2026-10-08 and this flake had no
    # row for it, which is exactly why the paragraph above about
    # `codetracer-trace-format` stopped being the answer: under `path-b` the Nim
    # tree is the writer and the Rust one only supplies the path dependencies
    # the lockfile names.
    #
    # `ct-writer/build.rs` materialises it out of a git OBJECT STORE, which a
    # sandbox does not have. CCP-7 added `CT_TRACE_FORMAT_NIM_SRC` plus
    # `CT_TRACE_FORMAT_NIM_SRC_REV` for exactly this: a plain tree, with the
    # revision DECLARED and checked against `pins.json` rather than trusted,
    # because a tree cannot prove its own provenance. `traceFormatNimRev` below
    # is that declaration, and a mismatch is refused by the build script.
    #
    # HELD AT 051efd22b0 AND NOT FOLLOWED TO `agents`, deliberately and in the
    # unusual direction. At 051efd22b0 the writer emits container 5
    # (`CtfsVersion`), container 6 under the compact profile
    # (`compact.nim` stamps `image[5] = CtfsVersionV6`) and `meta.dat` 6
    # (`MetaDatVersion* = 6`), and the engine pinned at
    # `client/hydrate/engine-pin.txt` accepts container {5,6} and `meta.dat`
    # [6] — both profiles land inside it. That repository's `agents` HEAD is at
    # `MetaDatVersion* = 7`, which the deployed engine REFUSES: advancing this
    # pin would produce containers this site's own reader cannot open.
    # (The input itself is declared once, further down, beside the chain-two
    # pins that share it. The paragraph above belongs with THIS explanation and
    # is kept here because it is about why the revision is chosen at all.)

    # ── THE WRITER'S OWN NIM DEPENDENCIES ───────────────────────────────────
    #
    # `codetracer_trace_format.nimble` requires `stew` and `results`, and `stew`
    # transitively requires `unittest2`. `ct-writer/build.rs` passes exactly one
    # `-p:` — the writer's own `src` — so until CCP-7 those three were resolved
    # from whatever the building machine happened to have. In a sandbox it has
    # none, and the build died at `cannot open file: results` with the compiler
    # unable to say whose dependency it was.
    #
    # THE REVISIONS ARE NOT A FREE CHOICE EITHER. They are the ones
    # `codetracer-trace-format-nim`'s OWN `flake.lock` pins at the revision
    # above, read out of it rather than picked: that repository's flake declares
    # the same three inputs and describes the `--path:` list built from them as
    # what makes the `requires` importable "from a bare `nim c` (the package
    # build below, and the FFI static lib the Rust sibling's build.rs
    # compiles)". So this is that list, reconstructed here because the input is
    # consumed as a source tree and its outputs are not available.
    #
    # Moving the writer pin above means re-reading these three out of its lock.
    nim-stew = {
      url = "github:status-im/nim-stew/1a5d0b99209f50ff055d9b5216849ba0365f8cf5";
      flake = false;
    };
    nim-results = {
      url = "github:arnetheduck/nim-results/b319652e98a198fa881ca70a76754c2dd6f09804";
      flake = false;
    };
    nim-unittest2 = {
      url = "github:status-im/nim-unittest2/92e1c13dcfb6d7e4ea6fb624fe9cc31e3dc76813";
      flake = false;
    };

    # ── Chain two: the Ethereum recorder and the writer it links ──────────────
    # tools/chain/nix/eth.nix says why each pin is where it is. The writer is the
    # last revision that writes `meta.dat` 6, because the engine this site pins
    # reads 6 only. Move it with client/hydrate/engine-pin.txt, never ahead of it.
    codetracer-evm-recorder = {
      url = "github:metacraft-labs/codetracer-evm-recorder/43d55adb1af32d275a406d63ee7a8dcd11bf2b64";
      flake = false;
    };
    evm-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/c8e57b1f21b1c4e82db5e14ab70fd16ecf217ce0";
      flake = false;
    };
    # A SOURCE input, not its flake: that flake's toolchain input brings ~100 lock
    # nodes (nixos-modules, home-manager, ethereum-nix, …) to build one archive and
    # one binary. eth.nix runs the same two builds, through the writer's own
    # `build_ffi.nims`, against its three Nim dependencies at the revisions the
    # writer's flake.lock records at this pin.
    # THE CEILING ON THIS PIN IS `meta.dat` 6, AND IT IS NOT A STYLE RULE.
    # The engine pinned at `client/hydrate/engine-pin.txt` accepts container
    # {5,6} and `meta.dat` [6]. This repository's HEAD emits
    # `MetaDatVersion* = 7`, which that engine REFUSES — advancing to it would
    # publish containers this site's own reader cannot open.
    #
    # Two branches pinned this input independently and a merge brought both
    # spellings into one file, which Nix refuses as a duplicate attribute —
    # that is how the pair was noticed rather than one silently winning. The
    # revisions were then compared at the only place that decides it:
    #
    #     051efd22b0  src/codetracer_trace_writer/meta_dat.nim  MetaDatVersion = 6
    #     7b8b587c72  src/codetracer_trace_writer/meta_dat.nim  MetaDatVersion = 6
    #
    # Both are inside the ceiling, so the newer one is taken and the lock
    # already names it. The ceiling itself stays written down, because the
    # thing it guards against is one commit away on that repository's mainline.
    codetracer-trace-format-nim = {
      url = "github:metacraft-labs/codetracer-trace-format-nim/7b8b587c72ec31f6825ae124ab89ad7954f6dca7";
      flake = false;
    };
    # ── Chain three: the Flow recorder and its trace-format siblings ──────────
    # tools/chain/nix/flow.nix says why each pin is where it is. The writer is
    # the `codetracer-trace-format-nim` input above, shared with chain two.
    codetracer-flow-recorder = {
      url = "github:metacraft-labs/codetracer-flow-recorder/04a05d33653da6809a1e1372e4c564d7fd462e3c";
      flake = false;
    };
    flow-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/3fada0b03c3d1a0cbc7c35f278aa639028d702c5";
      flake = false;
    };
    # ── Solana: the SBF recorder (tools/chain/nix/sol.nix says why) ────────────
    # Its trace-format path dependencies are `flow-trace-format` above, whose
    # revision is exactly the one this recorder's repro.lock names.
    codetracer-solana-recorder = {
      url = "github:metacraft-labs/codetracer-solana-recorder/0a1950220964d8c8793b43fa6c4ec1fb9bed35ef";
      flake = false;
    };
    # ── Sui: the Move recorder (tools/chain/nix/sui.nix says why) ─────────────
    # Its trace-format path dependencies are `flow-trace-format` above, whose
    # revision is exactly the one this recorder's repro.lock names.
    codetracer-move-recorder = {
      url = "github:metacraft-labs/codetracer-move-recorder/6f27c33004012eb9d57bfa9f649a0486697ccf83";
      flake = false;
    };
    # ── Starknet: the Cairo recorder (and the transcript it commits) ──────────
    # tools/chain/nix/starknet.nix says why each pin is where it is. The writer is
    # the `codetracer-trace-format-nim` input above, shared with chains two and three.
    codetracer-cairo-recorder = {
      url = "github:metacraft-labs/codetracer-cairo-recorder/d13bba54f5e75ae10d8b04503623d20af47e71fb";
      flake = false;
    };
    cairo-trace-format = {
      url = "github:metacraft-labs/codetracer-trace-format/3fada0b03c3d1a0cbc7c35f278aa639028d702c5";
      flake = false;
    };
    # (`nim-stew`, `nim-results` and `nim-unittest2` are declared once, above,
    # with the note on where their revisions are read from. Both branches added
    # them at the SAME three revisions; the duplicate copy that stood here was
    # removed rather than either set being re-pinned.)
  };

  outputs = { self, nixpkgs, flake-utils, isonim, nim-everywhere, isonim-tui, codetracer-design-system, codetracer
            , aztec-avm-runtime, codetracer-trace-format
            , codetracer-evm-recorder, evm-trace-format, codetracer-trace-format-nim
            , codetracer-flow-recorder, flow-trace-format
            , codetracer-solana-recorder
            , codetracer-move-recorder
            , codetracer-cairo-recorder, cairo-trace-format
            , nim-stew, nim-results, nim-unittest2 }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # isonim + nim-everywhere + the design system from the pinned flake
        # inputs. client/src/config.nims adds isonim + nim-everywhere (+ "/src")
        # to the Nim search path; tokens.nim reads the design system from
        # DESIGN_SYSTEM_SRC. So a build is hermetic inside `nix develop` without
        # any sibling checkout. Shared by every dev shell below (mkShell turns
        # these into env vars).
        srcEnv = {
          ISONIM_SRC = isonim;
          NIM_EVERYWHERE_SRC = nim-everywhere;
          ISONIM_TUI_SRC = isonim-tui;
          DESIGN_SYSTEM_SRC = codetracer-design-system;
          # The Embed SDK, for `just hydrate` and for the cross-repo suites
          # (`just debug-panes`, `just sdk-test-embed`, `just viewmodel-seam`),
          # every one of which resolves $CODETRACER_SRC before falling back to
          # a ../codetracer sibling.
          CODETRACER_SRC = codetracer;

          # ── THE CTFS WRITER'S NIM SOURCE, FOR TOOLS THAT LINK IT ──────────
          #
          # `tools/chain/compact_container.nim` imports `codetracer_ctfs` and
          # `codetracer_trace_writer` to apply `ctfs-container.md` §1e. Those
          # are not vendored here and not on any default Nim path, so without
          # these a recipe that builds it fails with `cannot open file:
          # codetracer_ctfs/types` — measured, on the first run of
          # `just ct-compact-check`.
          #
          # The REVISION is the one `ctWriterWasm` builds the shipped writer
          # from, so a tool that converts a container and the writer that
          # produces one cannot drift apart: both read this input.
          CT_TRACE_FORMAT_NIM_SRC = codetracer-trace-format-nim;
          # Its `.nimble` requires, in the order that repository's own flake
          # lists them. Colon-joined because that is the shape
          # `ct-writer/build.rs` reads, and the same string serves both.
          CT_NIM_EXTRA_PATHS =
            builtins.concatStringsSep ":" [ nim-stew nim-results nim-unittest2 ];
        };

        # CI dev shell — the execution environment CI runs project commands in
        # (`nix develop .#ci --command <cmd>`): the build toolchain PLUS wrangler
        # for the Cloudflare Pages deploy. We do NOT preinstall software on the
        # runners; the flake defines the environment, and the deploy command runs
        # inside it (wrangler pinned by flake.lock). Kept minimal on purpose.
        ci = pkgs.mkShell (srcEnv // {
          # `nodejs` is here because the DEPLOY runs a node guard over the bytes
          # it is about to upload (`tools/deploy/check-assets.mjs`): every
          # same-origin asset a published page names must resolve to a non-empty
          # file, and a publish carrying traces must have some page name one.
          # That check has to run in the deploy job, on the staged tree, which is
          # this shell — the Nim suites and the design gate grade the RENDERED
          # MARKUP and cannot see the file tree beside it.
          # `followerNodejs` and NOT a second `pkgs.nodejs_22` spelling: the
          # devshell node and the node the chain follower runs on are now one
          # pin, so they cannot drift apart again.
          #
          # `python3` CARRIES pyyaml, and that is not a convenience. Steps 3, 4
          # and 5 of `ci/test/ci-coverage.sh` parse the workflow YAML with
          # `python3 -c "import yaml"`, and they are written to REFUSE rather
          # than to skip when the parse cannot happen — "could not read
          # deploy.yml's push branches — step 3 would be vacuous" is a FAILURE,
          # because an instrument that could not be read is not an instrument
          # that said yes. That is the right behaviour and it is also why the
          # gate could not reach a verdict in this shell: `pkgs.python3` has no
          # pyyaml, while the `ubuntu-latest` runner that job uses has it
          # preinstalled. So the gate was green in CI and structurally red
          # locally, for a reason that had nothing to do with its subject — and
          # local testing is the operative gate here. The environments now agree.
          #
          # `bubblewrap` is here for the same reason, one gate over:
          # `ci/test/conformance-kit-sandbox.sh` proves the recorder conformance
          # kit reaches a verdict with no toolchain, no checkout and no network,
          # and it CONSTRUCTS all three absences rather than asserting them —
          # an empty tmpfs over the checkout, a network namespace with only
          # loopback, and a PATH holding nothing but the kit's own bin. Absent
          # `bwrap` it REFUSES rather than skipping, because a claim about three
          # absences that were never made is not a measurement. Pinned here so
          # the gate does not depend on a registry fetch at run time.
          #
          # It is LINUX-ONLY, and the guard below is not a convenience. The
          # three absences the gate constructs are namespaces, which darwin
          # does not have, so nixpkgs marks `bubblewrap` unsupported there and
          # REFUSES TO EVALUATE it. Unguarded, that refusal is not confined to
          # the gate: it is an evaluation error in `devShells.ci`, and
          # `devShells.default` takes `inputsFrom = [ ci ]`, so BOTH shells
          # stop instantiating and no macOS checkout can open either one.
          # Measured on 2026-09-30 against `origin/dev`: a package one gate
          # needs had taken the whole shell down on one platform. The gate
          # itself is unaffected — it runs on linux in CI, and on darwin it
          # refuses for absent `bwrap`, which is the honest answer, not a skip.
          buildInputs = (with pkgs; [
            nim
            nimble
            just
            (python3.withPackages (ps: [ ps.pyyaml ]))
            wrangler
            # `blocktracer-verify-published`'s HTTP backend shells out to curl
            # (verify/source.nim's header says why: TLS through `std/httpclient`
            # needs `-d:ssl` and a dynamically-resolved libssl, which is how a
            # tool comes to work only on the machine that built it). Its suite
            # drives that backend against an in-process fixture, so the suite
            # needs curl too — DECLARED rather than inherited from whatever the
            # runner happens to have on PATH.
            curl
            # `publish/encoding.nim` shells out to `brotli` for the one thing it
            # does: pre-compressing a published container so the object at rest
            # carries its own `Content-Encoding` and the browser's transparent
            # decompression is the only decompressor in the path (CCP-6). There
            # is no brotli binding in Nim here, and adding a C dependency would
            # put one into three released kit binaries a recorder team must be
            # able to run without a toolchain — so it is a subprocess, the same
            # way `aws` and `curl` above are.
            #
            # DECLARED rather than inherited, for the reason the curl entry
            # gives: a tool resolved from whatever a runner happens to carry is
            # a gate that measures the runner. Its ABSENCE is handled rather
            # than assumed — `encodeContainer` refuses to publish and
            # `decodeContainer` reports NOT MEASURED with the reason — so a host
            # without it degrades to a named gap and never to a silent pass.
            brotli
            # `aws`, which the brotli entry above already says is declared here
            # "the same way `aws` and `curl` above are" — and it WAS NOT. The
            # sentence described an entry nobody had added, and the gap surfaced
            # as `aws: command not found` with exit 127 in `publish-r2.yml`'s
            # "Stage the live bucket's data plane" on run 38269686081, after
            # four correct R2 credentials had already been handed to the step.
            # A credential check that passes and then cannot run the tool is the
            # worst-shaped failure available: it reads as a secrets problem.
            #
            # Two consumers, both subprocesses rather than SDK calls:
            # `publish/objectstore.nim`'s `S3ObjectStore.putMany` (`aws s3 cp
            # --recursive`, one call per Content-Encoding — see
            # `contract/container_encoding.nim`) and `publish-r2.yml`'s own
            # `aws s3 sync` of the live bucket's `d/ idx/ t/ src/` prefixes.
            awscli2
            # `ci/test/verify-published-readonly.sh:74` strips double-quoted
            # strings with `perl -pe` and says why in its own comment: "`perl`
            # and not `sed`: BSD sed has no non-greedy match and this needs
            # one." It was invoked bare, which worked on darwin — where
            # `/usr/bin/perl` leaks through — and failed on the NixOS runners
            # with `perl: command not found`. Publish run 38366603048 died
            # there, AFTER a successful publish, so the publish was reported as
            # a failed run.
            #
            # Third tool in this file with the same story: `curl` and `brotli`
            # are declared a few lines up for it, `awscli2` was declared above
            # after the same 127, and `cmp` was routed through this shell for
            # the same reason in the pointer-pin step. The pattern is "a tool a
            # script reaches for is a tool this file must name".
            perl
          ] ++ lib.optionals stdenv.hostPlatform.isLinux [
            bubblewrap
          ]) ++ [ followerNodejs ];
        });

        # VD.0 — the PINNED CAPTURE ENVIRONMENT. Browser build, fontconfig set
        # and renderer flags fixed, so the tier-1 exact-hash canary measures the
        # product rather than the runner. See tools/capture/capture-env.nix for
        # what is pinned and — just as important — the one thing it cannot pin
        # (darwin's compositor).
        captureEnv = pkgs.callPackage ./tools/capture/capture-env.nix { };

        # ── The chain follower ────────────────────────────────────────────
        #
        # ONE `nodejs` binding, used by the devshells below, by the follower
        # package, and — through `packages.chain-follower-nodejs` — by the
        # infra module's `nodePackage` option. The whole reason this exists as
        # a binding rather than three occurrences of `pkgs.nodejs_22` is that
        # the follower's runtime node and the devshell's node had disagreed,
        # unnoticed, for the entire life of the tool. tools/chain/nix records
        # the measurement that settled which version is right.
        followerNodejs = pkgs.nodejs_22;

        chain = pkgs.callPackage ./tools/chain/nix {
          nodejs = followerNodejs;
          blocktracerSrc = ./.;
          avmRuntimeSrc = aztec-avm-runtime;
          avmRuntimeRev = aztec-avm-runtime.rev;
          traceFormatSrc = codetracer-trace-format;
          traceFormatRev = codetracer-trace-format.rev;
          traceFormatNimSrc = codetracer-trace-format-nim;
          traceFormatNimRev = codetracer-trace-format-nim.rev;
          traceFormatNimDeps = [ nim-stew nim-results nim-unittest2 ];
        };

        eth = pkgs.callPackage ./tools/chain/nix/eth.nix {
          nodejs = followerNodejs;
          recorderSrc = codetracer-evm-recorder;
          recorderRev = codetracer-evm-recorder.rev;
          evmTraceFormatSrc = evm-trace-format;
          writerSrc = codetracer-trace-format-nim;
          writerNimDeps = [ nim-stew nim-results nim-unittest2 ];
          blocktracerRoot = ./.;
        };

        flow = pkgs.callPackage ./tools/chain/nix/flow.nix {
          nodejs = followerNodejs;
          recorderSrc = codetracer-flow-recorder;
          recorderRev = codetracer-flow-recorder.rev;
          flowTraceFormatSrc = flow-trace-format;
          writerSrc = codetracer-trace-format-nim;
          writerNimDeps = [ nim-stew nim-results nim-unittest2 ];
          blocktracerRoot = ./.;
        };

        sol = pkgs.callPackage ./tools/chain/nix/sol.nix {
          nodejs = followerNodejs;
          recorderSrc = codetracer-solana-recorder;
          recorderRev = codetracer-solana-recorder.rev;
          solTraceFormatSrc = flow-trace-format;
          writerSrc = codetracer-trace-format-nim;
          writerNimDeps = [ nim-stew nim-results nim-unittest2 ];
          blocktracerRoot = ./.;
        };

        sui = pkgs.callPackage ./tools/chain/nix/sui.nix {
          nodejs = followerNodejs;
          recorderSrc = codetracer-move-recorder;
          recorderRev = codetracer-move-recorder.rev;
          suiTraceFormatSrc = flow-trace-format;
          writerSrc = codetracer-trace-format-nim;
          writerNimDeps = [ nim-stew nim-results nim-unittest2 ];
          blocktracerRoot = ./.;
        };

        starknet = pkgs.callPackage ./tools/chain/nix/starknet.nix {
          nodejs = followerNodejs;
          recorderSrc = codetracer-cairo-recorder;
          recorderRev = codetracer-cairo-recorder.rev;
          cairoTraceFormatSrc = cairo-trace-format;
          writerSrc = codetracer-trace-format-nim;
          writerNimDeps = [ nim-stew nim-results nim-unittest2 ];
          blocktracerRoot = ./.;
        };
      in {
        # The larger, interactive default shell includes the ci shell (so a local
        # `nix develop` has the exact CI toolchain plus any interactive extras).
        devShells.ci = ci;

        # `nix run .#capture-env -- <command>` runs a command with the pinned
        # browser, fonts and locale in place. No daemon, no VM, no image build.
        packages.capture-env = captureEnv;

        # ── The chain follower, and the pieces the infra module asks for ──
        #
        # `services/blocktracer-ingest` (metacraft-labs/infra) takes four paths
        # and a node package. These outputs are those, so a host reads:
        #
        #   mcl.blocktracer-ingest = {
        #     blocktracerSrc        = bt.packages.${system}.chain-tools;
        #     runtime.src           = bt.packages.${system}.chain-runtime;
        #     runtime.ctWriterWasm  = bt.packages.${system}.aztec-ct-writer-wasm
        #                             + "/lib/aztec_ct_writer.wasm";
        #     runtime.avmWasm       = …;   # see tools/chain/nix — still not built here
        #     nodePackage           = bt.packages.${system}.chain-follower-nodejs;
        #   };
        #
        # `chain-follower` is the same composition as a runnable command, for a
        # person who wants to watch a chain without a NixOS host:
        #
        #   nix run .#chain-follower -- --avm /path/to/avm.wasm --url … --dry-run
        # ── Chain two, produced rather than committed (Chain-Delivery DEL-5, route 3) ──
        packages.evm-recorder = eth.evmRecorder;
        packages.eth-capture-tree = eth.ethCaptureTree;

        # ── Chain three, produced the same way (Chain-Delivery DEL-6) ──
        packages.flow-recorder = flow.flowRecorder;
        packages.cadence-replay-helper = flow.replayHelper;
        packages.flow-capture-tree = flow.flowCaptureTree;
        packages.flow-ct-print = flow.ctPrint;

        # ── Solana, produced the same way (Recorder-Solana CXP-SOL-6) ──
        # In produced-captures as `solana-mainnet` since 2026-10-22, when §1.4 gained the
        # `forward-capture` row. See tools/chain/nix/sol.nix.
        packages.solana-recorder = sol.solanaRecorder;
        packages.sol-capture-tree = sol.solCaptureTree;

        # ── Sui mainnet, produced the same way (Recorder-Move CXP-MOVE-6) ──────────
        # In produced-captures as `sui-mainnet`: byte-reproducible (`nix build --rebuild`
        # rc 0) from the committed GraphQL transcript. See tools/chain/nix/sui.nix.
        packages.move-recorder = sui.moveRecorder;
        packages.sui = sui.sui;
        packages.sui-capture-tree = sui.suiCaptureTree;
        packages.sui-ct-print = sui.ctPrint;

        # ── Starknet mainnet, produced the same way (Recorder-Cairo CXP-CAIRO-6) ──
        packages.cairo-onchain-recorder = starknet.onchainRecorder;
        packages.starknet-capture-tree = starknet.starknetCaptureTree;
        packages.starknet-ct-print = starknet.ctPrint;

        # The site with the STAGING-ONLY chains added: `default` plus the Ethereum,
        # Flow, Solana, Starknet and Sui trees, placed where the exporter already looks for a live-chain capture.
        # deploy.yml builds this for every deploy except `live`, so `live` (the
        # production Pages project) keeps `default` and carries no chain the
        # operator has not cleared for production; Chain-Expansion's environment
        # target is that only Aztec goes there. `postPatch` and not `preBuild`,
        # because `default`'s custom buildPhase never runs the preBuild hook.
        packages.site-staging = self.packages.${system}.default.overrideAttrs (old: {
          name = "blocktracer-site-staging";
          postPatch = (old.postPatch or "") + ''
            cp -r ${self.packages.${system}.produced-captures}/. client/fixtures/chain/
            chmod -R u+w client/fixtures/chain
          '';
        });

        # Every chain capture the build PRODUCES rather than commits, one directory
        # per chain slug. site-staging copies it into the fixtures; the deploy hands
        # it to `check-freshness.mjs record --produced`, so F4 holds each published
        # container to this output. That is sound only because each producer here
        # is byte-reproducible. A real copy rather than a linkFarm, because the
        # checker's walk does not follow symlinks.
        packages.produced-captures = pkgs.runCommand "blocktracer-produced-captures" { } ''
          mkdir -p $out
          cp -r ${eth.ethCaptureTree} $out/ethereum-mainnet
          cp -r ${flow.flowCaptureTree} $out/flow-mainnet
          cp -r ${sol.solCaptureTree} $out/solana-mainnet
          cp -r ${starknet.starknetCaptureTree} $out/starknet-mainnet
          cp -r ${sui.suiCaptureTree} $out/sui-mainnet
        '';

        packages.chain-tools = chain.chainTools;
        packages.chain-runtime = chain.avmRuntime;
        packages.aztec-ct-writer-wasm = chain.ctWriterWasm;
        packages.chain-follower = chain.follower;
        packages.chain-follower-nodejs = chain.nodePackage;

        apps.chain-follower = {
          type = "app";
          program = "${chain.follower}/bin/blocktracer-follow-chain";
        };
        apps.capture-env = {
          type = "app";
          program = "${captureEnv}/bin/vd0-capture-env";
        };

        # An interactive shell in the same environment, PLUS the Nim toolchain,
        # so `just capture` can rebuild client/dist and capture in one place.
        #
        # `python3` IS HERE FOR THE REASON IT IS IN `.#ci` ABOVE, one gate over,
        # and the failure was the same shape: a gate that REFUSES rather than
        # skips, run in a shell that could not give it what it needs.
        # `tools/journeys/selftest-verdict-test.sh` — CI's "Does it say when it
        # did NOT run — and does the sharding partition?" step, run as
        # `nix develop .#capture --command vd0-capture-env bash …` — builds the
        # synthetic shard journals that probe 6 hands to `--combine` with one
        # thing wrong in each, and it builds them with a `python3` heredoc at
        # five sites. The runner has no `python3` on its ambient PATH and this
        # shell did not supply one, so every one of those sites printed
        # `python3: command not found`, the journals were never written, and
        # probes 6b, 6c and 6e failed against journals that did not exist.
        #
        # THAT IS NOT A FAILURE OF THE THING BEING MEASURED. Probe 6 exists
        # because "a defence nobody has watched fail is indistinguishable from
        # no defence", and for the whole time this has been red it has been
        # exactly that: 6 of 36 probes reporting on a file the shell could not
        # create. The step is also the `journeys` job's FIRST gate, so its exit
        # 1 skipped both remaining steps — "Stage the deploy artefact" and "The
        # journeys, over the deployed artefact". The journeys themselves have
        # not run on `dev` since; the job's red X has been about a missing
        # interpreter, not about the product.
        #
        # No pyyaml here — these five sites use `json` from the standard
        # library and nothing else. It does not touch the capture pin: `envId`
        # is `captureEnv`'s own, and this is the devshell around it.
        #
        # `brotli` BECAUSE THIS SHELL RUNS THE EXPORTER. `check-canary.mjs`
        # builds and runs `client/src/static_export`, which since CCP-6 stores
        # every container pre-compressed, and `publish/encoding.nim` shells out
        # to the `brotli` binary to do it. Without it on PATH the exporter does
        # not degrade — it REFUSES, by design:
        #
        #   cannot publish the container for 0x00c67f6f…: cannot store a
        #   container with Content-Encoding 'br': `brotli` is not on PATH
        #
        # and the canary reported `capture failed: static exporter failed`
        # (run 38643115341). `devShells.ci` has carried brotli since CCP-6 and
        # this one was missed, which is the whole class of defect a second
        # shell with its own package list produces: the dependency was declared
        # where the author was looking.
        devShells.capture = pkgs.mkShell (srcEnv // {
          buildInputs = [ captureEnv pkgs.nim pkgs.nimble pkgs.just followerNodejs pkgs.python3
                          pkgs.brotli ];
          shellHook = ''
            echo "blocktracer VD.0 pinned capture environment"
            echo "  vd0-capture-env --print-pin                       — what is pinned, and its id"
            echo "  vd0-capture-env node tools/capture/check-canary.mjs --no-build"
            echo ""
            echo "On darwin this environment still rasterises through the host"
            echo "compositor, so the canary verdict stays ADVISORY. Linux is where"
            echo "a tier-1 verdict is producible."
          '';
        });

        devShells.default = pkgs.mkShell (srcEnv // {
          inputsFrom = [ ci ];
          shellHook = ''
            echo "blocktracer dev shell (includes .#ci)"
            echo "  (cd client && just export)  — render the explorer over the demo data tree -> client/dist/"
            echo "  (cd client && just test)    — static-export round-trip test"
            echo "  (cd client && just preview) — export, then serve dist/ on :8080"
            echo "  nix build .#default          — build the full deployable site -> result/"
            echo "  wrangler …                   — Cloudflare Pages deploy (CI uses .#ci)"
            echo ""
            echo "isonim + nim-everywhere from pinned flake inputs (ISONIM_SRC / NIM_EVERYWHERE_SRC);"
            echo "design-system tokens from DESIGN_SYSTEM_SRC — no sibling checkout required."
          '';
        });

        # Static-site build: the IsoNim client rendered over the demo data tree.
        # Hermetic — isonim + nim-everywhere + the design system all come from the
        # pinned flake inputs above. `src = ./.` is the whole repo, so the client
        # can import the in-repo data contract + demo generator and read the trace
        # fixture without any sibling checkout.
        packages.default = pkgs.stdenv.mkDerivation {
          name = "blocktracer-site";
          src = ./.;
          # `brotli` BECAUSE THE CONTAINERS ARE STORED PRE-COMPRESSED.
          # `static_export.nim`'s `PublishedEncoding` is `ceBrotli` and
          # `publish/encoding.nim` shells out to this binary — an absent one is
          # a NAMED refusal there and never a silent identity pass, so without
          # it this derivation fails loudly rather than publishing raw bytes
          # with no `Content-Encoding`.
          nativeBuildInputs = [ pkgs.nim pkgs.bash pkgs.brotli ];
          CODETRACER_SRC = codetracer;
          ISONIM_SRC = isonim;
          NIM_EVERYWHERE_SRC = nim-everywhere;
          ISONIM_TUI_SRC = isonim-tui;
          DESIGN_SYSTEM_SRC = codetracer-design-system;
          buildPhase = ''
            export HOME=$TMPDIR
            cd client

            # 1. The hydration bundle FIRST, because step 2 declares its URL
            #    and `installHydrationBundle` refuses to finish if that URL
            #    names a file that was not produced. A page must never carry a
            #    <script> for something that does not exist: its controls would
            #    sit inert forever, saying they are waiting for an engine
            #    nothing will ever ask for.
            bash ./hydrate/build.sh --require

            # 1b. The SEARCH bundle, for the same reason and with the same
            #     refusal downstream (`installSearchBundle`). Plain `nim js`
            #     over this repo's own sources — no Embed SDK, no debugger on
            #     the Nim path. `/search` is the one route that cannot be
            #     server-rendered, because a static file server never sees
            #     `?q=`; without this step the deploy ships a search form that
            #     submits to a page which cannot read what it was given.
            nim js --hints:off -d:release \
              --path:src --path:../src \
              --nimcache:searchboot/nimcache \
              -o:searchboot/search.js searchboot/searchboot.nim

            # 1b. The settings bundle, on the same terms and for the same
            #     reason at a different address: `/settings` serves a preset
            #     chooser `hidden`, and this is the compilation that unhides it
            #     and makes it store anything. Without this step the deploy
            #     ships a settings page with no visible control — which is the
            #     page that was deleted from this address, rebuilt by accident.
            nim js --hints:off -d:release \
              --path:src --path:../src \
              --nimcache:settingsboot/nimcache \
              -o:settingsboot/settings.js settingsboot/settingsboot.nim

            # 2. The site, told where all three bundles went.
            nim c -r --mm:orc -d:isServer -d:release \
              -d:hydrationBundle=/assets/hydrate.js \
              -d:searchBundle=/assets/search.js \
              -d:settingsBundle=/assets/settings.js \
              src/static_export.nim
          '';
          installPhase = ''
            mkdir -p $out
            cp -r dist/* $out/
          '';
        };
      }
    );
}
