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
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [ nim nimble just python3 ];

          # Provide isonim + nim-everywhere from the pinned flake inputs.
          # client/src/config.nims adds these (+ "/src") to the Nim search path;
          # tokens.nim reads the design system from DESIGN_SYSTEM_SRC. So, from
          # the client dir, `just export` / `just test` build hermetically inside
          # `nix develop` without any sibling checkout.
          ISONIM_SRC = isonim;
          NIM_EVERYWHERE_SRC = nim-everywhere;
          DESIGN_SYSTEM_SRC = codetracer-design-system;

          shellHook = ''
            echo "blocktracer dev shell"
            echo "  (cd client && just export)  — render the explorer over the demo data tree -> client/dist/"
            echo "  (cd client && just test)    — static-export round-trip test"
            echo "  (cd client && just preview) — export, then serve dist/ on :8080"
            echo ""
            echo "isonim + nim-everywhere from pinned flake inputs (ISONIM_SRC / NIM_EVERYWHERE_SRC);"
            echo "design-system tokens from DESIGN_SYSTEM_SRC — no sibling checkout required."
          '';
        };

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
