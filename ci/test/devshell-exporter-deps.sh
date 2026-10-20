#!/usr/bin/env bash
# Every dev shell that can RUN the exporter must carry what the exporter needs.
#
# ── THE INCIDENT ────────────────────────────────────────────────────────────
#
# Since CCP-6 `client/src/static_export` stores every container
# pre-compressed, and `publish/encoding.nim` shells out to the `brotli` binary
# to do it. `devShells.ci` was given `brotli` in that change; `devShells.capture`
# was not, and nothing noticed until a full canary capture had run:
#
#   capture failed: static exporter failed …
#   cannot publish the container for 0x00c67f6f…: cannot store a container with
#   Content-Encoding 'br': `brotli` is not on PATH
#
# (run 38643115341). The exporter does not degrade without brotli — it REFUSES,
# which is right, and is why the cost of the omission is a red job rather than
# a silently identity-encoded tree. But the feedback was a multi-minute browser
# capture for a missing 1 MB binary.
#
# ── THE RULE, AND WHY IT IS THIS ONE ───────────────────────────────────────
#
# `nim` implies `brotli`. A shell that provides `nim` can build and run the
# exporter — that is what every one of these shells is for — and the exporter
# refuses without brotli. The implication is checked over the REALISED inputs
# of each shell, not over the text of `flake.nix`, so `inputsFrom` and any
# other indirection are followed the way nix follows them. Grepping the file
# would have passed `devShells.default`, which names neither package and has
# both.
set -euo pipefail

cd "$(dirname "$0")/../.."

want_tool="${1:-brotli}"
implied_by="${2:-nim}"

read -r -d '' EXPR <<'NIX' || true
let f = builtins.getFlake (toString ./.);
    sys = builtins.currentSystem;
    namesOf = d: map (p: p.pname or p.name or "?")
                     ((d.buildInputs or []) ++ (d.nativeBuildInputs or []));
in builtins.mapAttrs (_: d: namesOf d) f.devShells.${sys}
NIX

# ── THE TWO STREAMS ARE CAPTURED SEPARATELY, AND THE PAYLOAD IS ASSERTED ───
#
# This read `json="$(nix eval … 2>&1)"` and tested only the EXIT CODE. nix
# writes warnings to stderr and exits 0, so `2>&1` folded them into the value
# and the guard passed them through as JSON.
#
# MEASURED on run 39352321787: the runners' nix began emitting `warning:
# unknown setting 'build-provenance-tags'`, `$json` became that sentence
# followed by the object, and the gate died with a python traceback —
# `json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)` —
# and exit 1. Exit 1 is "the dev shells are wrong". Nothing had been measured
# at all, and the job that reads this gate reported a product defect.
#
# So: stderr to its own file, and the payload tested for CONTENT and not only
# for a status. A nix that exits 0 and prints nothing, or prints something that
# is not an object, is a gate that DID NOT RUN — exit 2, with whatever nix said
# on stderr quoted underneath, which is the only evidence there is.
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
if ! json="$(nix eval --impure --json --expr "$EXPR" 2>"$err")"; then
  echo "COULD NOT EVALUATE the dev shells — this gate measured nothing."
  sed 's/^/    /' "$err"
  echo "RESULT: DID NOT RUN"
  exit 2
fi
case "${json#"${json%%[![:space:]]*}"}" in
  '{'*) : ;;
  *)
    echo "nix exited 0 and did not print a dev-shell object — this gate measured nothing."
    echo "    stdout (first 200 bytes): ${json:0:200}"
    echo "    stderr:"
    sed 's/^/        /' "$err"
    echo "RESULT: DID NOT RUN"
    exit 2
    ;;
esac

printf '%s' "$json" | WANT="$want_tool" IMPLIED="$implied_by" python3 -c '
import json, os, sys
want, implied = os.environ["WANT"], os.environ["IMPLIED"]
shells = json.load(sys.stdin)
if not shells:
    print("no dev shells for this system — nothing to check, and that is not a pass")
    print("RESULT: DID NOT RUN"); sys.exit(2)
bad, checked = [], 0
for name, inputs in sorted(shells.items()):
    has = lambda w: any(w in (x or "") for x in inputs)
    if not has(implied):
        print("  SKIP  %-10s no %s — outside this rule" % (name, implied))
        continue
    checked += 1
    if has(want):
        print("  ok    %-10s %s and %s (%d inputs)" % (name, implied, want, len(inputs)))
    else:
        print("  FAIL  %-10s has %s and NOT %s (%d inputs)" % (name, implied, want, len(inputs)))
        bad.append(name)
if checked == 0:
    print("no shell provides %s — the implication has no subject" % implied)
    print("RESULT: DID NOT RUN"); sys.exit(2)
if bad:
    print()
    print("::error::%d dev shell(s) can run the exporter and lack `%s`: %s. "
          "The exporter REFUSES rather than degrading, so this is a red job wherever "
          "that shell is used." % (len(bad), want, ", ".join(bad)))
    print("RESULT: FAILED"); sys.exit(1)
print("RESULT: PASS — %d shell(s) provide %s, and all of them provide %s" % (checked, implied, want))
'
