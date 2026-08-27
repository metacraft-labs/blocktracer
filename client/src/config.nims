# Hermetic-build support (public-repo gate).
#
# nim.cfg pins sibling ../../isonim/src and ../../nim-everywhere/src checkouts for
# the local dev workflow. For a public repo / CI those adjacent checkouts do not
# exist, so isonim + nim-everywhere are provided instead as pinned Nix flake
# inputs (see ../flake.nix). The flake devShell and the `packages.default` build
# export ISONIM_SRC / NIM_EVERYWHERE_SRC pointing at those store paths; when set,
# they are added to the Nim search path here (nim.cfg cannot expand env vars).
#
# Result: `nix build` and `nix develop -c just export` build the site
# hermetically, without assuming sibling checkouts, while a plain `just export`
# in a sibling-checkout dev tree keeps working via the nim.cfg fallback.
#
# The codetracer-design-system is located separately at RUNTIME (via
# DESIGN_SYSTEM_SRC, also exported by ../flake.nix) by src/design_system/tokens.nim.

let isonimSrc = getEnv("ISONIM_SRC")
if isonimSrc.len > 0:
  switch("path", isonimSrc & "/src")

let nimEverywhereSrc = getEnv("NIM_EVERYWHERE_SRC")
if nimEverywhereSrc.len > 0:
  switch("path", nimEverywhereSrc & "/src")
