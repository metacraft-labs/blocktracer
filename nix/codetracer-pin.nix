# The CodeTracer Embed SDK source this repository is built and checked against,
# read from the organisation's single CodeTracer pin.
#
# `pins` is the parsed pin set of metacraft-labs/metacraft-github-actions
# (`pins/codetracer.json`, read through that repository's flake output `pins`).
# BlockTracer keeps no CodeTracer revision of its own: not in `flake.nix`, not
# in `ci/embed-sdk-pin.env`. `ci/codetracer-ref.sh` prints the revision for
# the scripts that compare against it.
#
# The fetch is by the pin's `rev` AND `narHash`, so it is locked and evaluates
# in pure mode. It is a source tree only and CodeTracer's flake is never
# evaluated: every consumer here reads `src/` or `ci/` from it (see the
# `metacraft-github-actions` input in flake.nix). A `github:` fetch carries no
# submodules, which is what this repository needs and what the old input stated
# with `submodules=0`: codetracer's `libs/tree-sitter-nim` submodule is private
# and this repository's CI cannot read it.
pins: let
  fail = msg: throw "blocktracer codetracer pin: ${msg}";
  pin = pins.codetracer or (fail "the pin set has no `codetracer` entry");
  valid =
    if pin.schema or null != 1
    then fail "pins/codetracer.json has schema ${toString (pin.schema or "<none>")}; this reader understands schema 1 only"
    else if pin.tool or null != "codetracer"
    then fail "pins/codetracer.json names tool `${toString (pin.tool or "<none>")}`, expected `codetracer`"
    else if builtins.match "[0-9a-f]{40}" (pin.rev or "") == null
    then fail "pins/codetracer.json `rev` is `${toString (pin.rev or "<none>")}`, not a 40-hex commit id"
    else if !(pin ? narHash)
    then fail "pins/codetracer.json carries no `narHash`, so the fetch would not be locked"
    else pin;
in {
  inherit (valid) owner repo rev narHash;
  src = builtins.fetchTree {
    type = "github";
    inherit (valid) owner repo rev narHash;
  };
}
