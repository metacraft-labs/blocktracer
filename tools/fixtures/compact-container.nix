{ pkgs, traceFormatNim, nimDeps }:

# The fixture container tools, every one linked against the ONE pinned
# trace-format library (`codetracer-trace-format-nim` in flake.nix), so the
# writer that lays a container out, the step that moves its `meta.dat` and the
# reader that checks it cannot disagree about the format:
#
#   compact-container  changes the storage profile without rewriting any
#                      recorded stream (tools/chain/compact_container.nim);
#   meta-dat-v7        regenerates a `meta.dat` 6 container as 7 and decodes it
#                      in full before writing (tools/chain/meta_dat_v7.nim) —
#                      the step that makes a producer's schema-6 output readable
#                      by the published schema-7 replay engine;
#   ct-print           the reader the fixture recipes and the census use, as
#                      `CT_FIXTURE_PRINT`. It reads `meta.dat` 7 only, which is
#                      what preparation now produces.
pkgs.runCommand "blocktracer-fixture-container-tools" {
  nativeBuildInputs = [ pkgs.nim pkgs.pkg-config pkgs.stdenv.cc ];
  buildInputs = [ pkgs.zstd pkgs.pcre ];
} ''
  mkdir -p $out/bin
  cp ${../chain/compact_container.nim} compact_container.nim
  cp ${../chain/meta_dat_v7.nim} meta_dat_v7.nim
  build() {
    nim c --hints:off -d:release --skipParentCfg --skipUserCfg \
      --nimcache:$TMPDIR/nimcache-$2 \
      --path:${traceFormatNim}/src \
      ${pkgs.lib.concatMapStringsSep " " (path: "--path:${path}") nimDeps} \
      --passC:-I${pkgs.zstd.dev}/include --passL:-L${pkgs.zstd}/lib \
      --passL:-Wl,-rpath,${pkgs.zstd}/lib \
      -o:$out/bin/$2 $1
  }
  build compact_container.nim compact-container
  build meta_dat_v7.nim meta-dat-v7
  # The same build as that repository's own `ct-print` package (its flake's
  # `packages.default`) and as `tools/chain/nix/eth.nix`'s `ctPrint`.
  nim c -d:release --mm:arc --hints:off \
    --nimcache:$TMPDIR/nimcache-ct-print \
    --path:${traceFormatNim}/src \
    ${pkgs.lib.concatMapStringsSep " " (path: "--path:${path}") nimDeps} \
    -o:$out/bin/ct-print ${traceFormatNim}/src/codetracer_ct_print.nim
''
