#!/usr/bin/env bash
# Does `devshell-exporter-deps.sh` bite?
#
# A gate whose failure path has never run is a gate nobody has reason to
# believe, and this one is cheap to disbelieve: it would pass an empty shell
# list, a list where nothing provides `nim`, and a substring match loose enough
# that `nim` finds `nimble`. All three are arms below.
#
# THE CONTROL IS THE REAL FLAKE. The arms drive the gate's own rule over
# synthetic shell lists by asking for a tool that is genuinely absent, which is
# how a defect is injected here without editing `flake.nix` — editing it would
# make a red arm indistinguishable from a broken checkout.
set -euo pipefail
cd "$(dirname "$0")/../.."
G=ci/test/devshell-exporter-deps.sh

pass=0; fail=0
ck() { # name expected-exit actual-exit [grep-for] [output]
  if [ "$2" = "$3" ] && { [ -z "${4:-}" ] || printf '%s' "${5:-}" | grep -qF "$4"; }; then
    echo "  ok    $1"; pass=$((pass+1))
  else
    echo "  FAIL  $1 (wanted exit $2, got $3${4:+; wanted \"$4\"})"
    printf '%s\n' "${5:-}" | sed 's/^/          /' | head -12
    fail=$((fail+1))
  fi
}

# 1 — THE CONTROL. The real shells, the real rule.
out="$("$G" 2>&1)"; rc=$?
ck "control: the flake's own shells pass the real rule" 0 "$rc" "RESULT: PASS" "$out"

# 2 — THE DEFECT, REPRODUCED. A tool no shell carries must be reported, by
#     shell name, as a FAILURE and not as "nothing to check".
out="$("$G" definitely-not-a-package nim 2>&1)" && rc=0 || rc=$?
ck "a tool NO shell carries is a failure"               1 "$rc" "RESULT: FAILED" "$out"
ck "…and it names the shells, not just a count"         1 "$rc" "capture"        "$out"

# 3 — NO SUBJECT IS NOT A PASS. If nothing implies the rule, the gate has
#     measured nothing and must say so with its own exit code — the failure
#     mode this whole file exists to prevent is a green tick over an empty set.
out="$("$G" brotli definitely-not-a-package 2>&1)" && rc=0 || rc=$?
ck "an implication with no subject is DID NOT RUN, not PASS" 2 "$rc" "RESULT: DID NOT RUN" "$out"

# 4 — AND THE DID-NOT-RUN EXIT IS 2, NOT 1. A gate that could not look and a
#     gate that found something must not share an exit code; CI maps 2 to
#     "DID NOT RUN" and 1 to a finding.
ck "…and that exit is 2, which CI reads as DID NOT RUN"  2 "$rc" ""              "$out"

# 5 — THE SKIP IS VISIBLE. A shell excluded from the rule must say so, or an
#     exclusion is indistinguishable from a check. `awscli` is in `ci` and
#     `default` and not in `capture`, so it is the one implication this flake
#     can demonstrate a partition with.
out="$("$G" brotli awscli 2>&1)" && rc=0 || rc=$?
ck "a shell outside the implication prints SKIP"         0 "$rc" "SKIP  capture"  "$out"
ck "…and the shells inside it are still checked"         0 "$rc" "ok    ci "      "$out"

# 6 — THE MATCH IS A SUBSTRING, AND THAT IS STATED RATHER THAN ASSUMED. The
#     realised name of the Nim compiler here is `arm64-apple-darwin-nim-wrapper`,
#     so an equality test would find no `nim` in any shell and the gate would
#     report DID NOT RUN forever. A substring is what makes the rule have a
#     subject at all; it is sound here because every name in this flake
#     containing "nim" (`…-nim-wrapper`, `nimble`) IS the Nim toolchain.
out="$("$G" brotli nim-wrapper 2>&1)" && rc=0 || rc=$?
ck "the exact wrapper name is a subject, not a miss"     0 "$rc" "RESULT: PASS"  "$out"

echo
echo "$((pass+fail)) arm(s): $pass passed, $fail failed"
[ "$fail" -eq 0 ] || { echo "RESULT: FAILED"; exit 1; }
echo "RESULT: PASS"
