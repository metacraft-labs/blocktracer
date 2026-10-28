{ pkgs, traceFormatNim, nimDeps }:

# The existing container conversion tool links the pinned reader/writer library;
# it changes the storage profile without rewriting any recorded stream.
pkgs.runCommand "blocktracer-fixture-container-tools" {
  nativeBuildInputs = [ pkgs.nim pkgs.pkg-config pkgs.stdenv.cc ];
  buildInputs = [ pkgs.zstd ];
} ''
  mkdir -p $out/bin
  cp ${../chain/compact_container.nim} compact_container.nim
  nim c --hints:off -d:release --skipParentCfg --skipUserCfg \
    --nimcache:$TMPDIR/nimcache \
    --path:${traceFormatNim}/src \
    ${pkgs.lib.concatMapStringsSep " " (path: "--path:${path}") nimDeps} \
    --passC:-I${pkgs.zstd.dev}/include --passL:-L${pkgs.zstd}/lib \
    --passL:-Wl,-rpath,${pkgs.zstd}/lib \
    -o:$out/bin/compact-container compact_container.nim
''
