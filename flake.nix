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
      url = "github:metacraft-labs/isonim/03f8349784b2642ba5b49101f1a04b454b3476f3";
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
  };

  outputs = { self, nixpkgs, flake-utils, isonim, nim-everywhere, codetracer-design-system }:
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
        };

        # CI dev shell — the execution environment CI runs project commands in
        # (`nix develop .#ci --command <cmd>`): the build toolchain PLUS wrangler
        # for the Cloudflare Pages deploy. We do NOT preinstall software on the
        # runners; the flake defines the environment, and the deploy command runs
        # inside it (wrangler pinned by flake.lock). Kept minimal on purpose.
        ci = pkgs.mkShell (srcEnv // {
          buildInputs = with pkgs; [ nim nimble just python3 wrangler ];
        });
      in {
        # The larger, interactive default shell includes the ci shell (so a local
        # `nix develop` has the exact CI toolchain plus any interactive extras).
        devShells.ci = ci;
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
          nativeBuildInputs = [ pkgs.nim ];
          ISONIM_SRC = isonim;
          NIM_EVERYWHERE_SRC = nim-everywhere;
          DESIGN_SYSTEM_SRC = codetracer-design-system;
          buildPhase = ''
            export HOME=$TMPDIR
            cd client
            nim c -r --mm:orc -d:isServer -d:release src/static_export.nim
          '';
          installPhase = ''
            mkdir -p $out
            cp -r dist/* $out/
          '';
        };
      }
    );
}
