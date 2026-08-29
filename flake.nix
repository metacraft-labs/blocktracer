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
      url = "github:metacraft-labs/isonim/2a24d9549543c2a894525f65c4e608f9881b7373";
      flake = false;
    };
    nim-everywhere = {
      url = "github:metacraft-labs/nim-everywhere/b2ce1c6b31743c4351aff4ad835f385f79b70edd";
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
    codetracer = {
      url = "github:metacraft-labs/codetracer/8d1c84a85034a739804914a33f2f55329b5f051a";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, isonim, nim-everywhere, codetracer-design-system, codetracer }:
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
          DESIGN_SYSTEM_SRC = codetracer-design-system;
          # The Embed SDK, for `just hydrate` and for the cross-repo suites
          # (`just debug-panes`, `just sdk-test-embed`, `just viewmodel-seam`),
          # every one of which resolves $CODETRACER_SRC before falling back to
          # a ../codetracer sibling.
          CODETRACER_SRC = codetracer;
        };

        # CI dev shell — the execution environment CI runs project commands in
        # (`nix develop .#ci --command <cmd>`): the build toolchain PLUS wrangler
        # for the Cloudflare Pages deploy. We do NOT preinstall software on the
        # runners; the flake defines the environment, and the deploy command runs
        # inside it (wrangler pinned by flake.lock). Kept minimal on purpose.
        ci = pkgs.mkShell (srcEnv // {
          buildInputs = with pkgs; [ nim nimble just python3 wrangler ];
        });

        # VD.0 — the PINNED CAPTURE ENVIRONMENT. Browser build, fontconfig set
        # and renderer flags fixed, so the tier-1 exact-hash canary measures the
        # product rather than the runner. See tools/capture/capture-env.nix for
        # what is pinned and — just as important — the one thing it cannot pin
        # (darwin's compositor).
        captureEnv = pkgs.callPackage ./tools/capture/capture-env.nix { };
      in {
        # The larger, interactive default shell includes the ci shell (so a local
        # `nix develop` has the exact CI toolchain plus any interactive extras).
        devShells.ci = ci;

        # `nix run .#capture-env -- <command>` runs a command with the pinned
        # browser, fonts and locale in place. No daemon, no VM, no image build.
        packages.capture-env = captureEnv;
        apps.capture-env = {
          type = "app";
          program = "${captureEnv}/bin/vd0-capture-env";
        };

        # An interactive shell in the same environment, PLUS the Nim toolchain,
        # so `just capture` can rebuild client/dist and capture in one place.
        devShells.capture = pkgs.mkShell (srcEnv // {
          buildInputs = [ captureEnv pkgs.nim pkgs.nimble pkgs.just pkgs.nodejs_22 ];
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
          nativeBuildInputs = [ pkgs.nim pkgs.bash ];
          CODETRACER_SRC = codetracer;
          ISONIM_SRC = isonim;
          NIM_EVERYWHERE_SRC = nim-everywhere;
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

            # 2. The site, told where the bundle went.
            nim c -r --mm:orc -d:isServer -d:release \
              -d:hydrationBundle=/assets/hydrate.js \
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
