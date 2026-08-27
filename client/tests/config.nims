# Hermetic-build support for the test target (mirrors src/config.nims).
#
# Nim reads a `config.nims` only from the project directory of the module being
# compiled (here: tests/), never from a sibling directory — so the src/config.nims
# ISONIM_SRC / NIM_EVERYWHERE_SRC search-path wiring is NOT applied when compiling
# tests/test_static_export.nim. Repeat it here so the test builds without adjacent
# ../../isonim / ../../nim-everywhere checkouts. The client nim.cfg (read as a
# parent config) still supplies the sibling + blocktracer-`src` fallback paths for
# local dev; when ISONIM_SRC / NIM_EVERYWHERE_SRC are set (nix develop / CI) those
# pinned flake-input store paths take over.

let isonimSrc = getEnv("ISONIM_SRC")
if isonimSrc.len > 0:
  switch("path", isonimSrc & "/src")

let nimEverywhereSrc = getEnv("NIM_EVERYWHERE_SRC")
if nimEverywhereSrc.len > 0:
  switch("path", nimEverywhereSrc & "/src")
