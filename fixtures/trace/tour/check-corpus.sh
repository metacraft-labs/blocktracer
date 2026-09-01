#!/usr/bin/env bash
#
# The corpus's two sets, checked against what the toolchain actually does.
#
#   recordable  (`programs`)          — the capability tour. Each produces a
#                                       recording BlockTracer serves. Some carry
#                                       a `knownFailures` entry: a thing the
#                                       recording SHOULD show and does not.
#   toolchain   (`toolchainPrograms`) — programs that exercise the toolchain and
#                                       cannot produce a servable recording.
#                                       Three pin language rules; two pin
#                                       recorder gaps that are ours to close.
#
# ── THE KNOWN-FAILURE RULE, AND WHY IT IS SHAPED THIS WAY ───────────────────
#
# Nothing here asserts the broken behaviour. An entry states the CORRECT
# expectation in `shouldBe`, and what it pins with `match` is the CURRENT wrong
# behaviour — so the two are never confused, and a reader of the manifest sees
# what ought to happen rather than being taught that absence is right.
#
# IT DECIDES IN BOTH DIRECTIONS, which is the whole point and is the same rule
# `tools/journeys/run.mjs` states for the journeys ledger:
#
#   * still matching  → KNOWN-FAILURE, reported in full, does NOT fail the run.
#   * no longer matching → NOW PASSING, and the run FAILS, naming the defect and
#     telling you to move the program into the tour and delete the entry.
#
# A one-directional ledger is how a suite comes to describe a product that no
# longer exists, and it is what would let a fix land without anyone removing the
# entry that says the defect is still open.
#
# `--selftest` proves both directions decide. The journeys ledger has no such
# arm; this one does, because a mechanism whose failure path nobody has seen is
# a mechanism nobody should trust.
#
# Usage:
#   fixtures/trace/tour/check-corpus.sh [id ...]
#   fixtures/trace/tour/check-corpus.sh --selftest
#
# Env: NARGO, CT_PRINT — found by walking up to the sibling checkouts.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${MANIFEST:-$HERE/manifest.json}"

find_sibling() {
  local rel="$1" dir="$HERE"
  while [ "$dir" != "/" ]; do
    if [ -e "$dir/$rel" ]; then echo "$dir/$rel"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}
NARGO="${NARGO:-$(find_sibling noir/target/release/nargo || true)}"
CT_PRINT="${CT_PRINT:-$(find_sibling codetracer-trace-format-nim/ct-print || true)}"

if [ -z "$NARGO" ] || [ ! -x "$NARGO" ]; then
  echo "no nargo found in any parent of $HERE — set NARGO=/path/to/nargo" >&2
  exit 2
fi

WORKROOT="${WORKROOT:-/tmp/blocktracer-corpus-check}"

# ── the two readers ────────────────────────────────────────────────────────
# `python3` rather than `jq`: it is already a dependency of this repository's
# tooling and `jq` is not.

read_toolchain() {
  python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for p in m.get("toolchainPrograms", []):
    e = p["expect"]
    print("\t".join([p["id"], p["sources"], e["stage"], e["outcome"], e["match"],
                     e.get("owner",""), e.get("defect",""),
                     "1" if e.get("knownFailure") else "0",
                     " ".join(p.get("nargoFlags", []))]))
PY
}

read_recordable_known_failures() {
  python3 - "$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for p in m.get("programs", []):
    for kf in p.get("knownFailures", []):
        c = kf.get("check", {})
        if c.get("stage") != "recording":
            continue
        print("\t".join([p["id"], p["container"], kf["defect"], kf.get("owner",""),
                         c.get("absentRe",""), c.get("presentRe","")]))
PY
}

want=("$@")
selected() {
  [ ${#want[@]} -eq 0 ] && return 0
  local id="$1"; for w in "${want[@]}"; do [ "$w" = "$id" ] && return 0; done; return 1
}

pass=0; fail=0; known=0; regressed=0

report_known() {   # id defect owner
  echo "  KNOWN-FAILURE  $1 — $2 ($3) still open"
  known=$((known+1))
}
report_now_passing() { # id defect owner detail
  echo "  *** NOW PASSING  $1 — $2 ($3) appears FIXED." >&2
  echo "      The toolchain no longer does what this entry pins. Update the" >&2
  echo "      corpus, delete the entry, and close the defect in" >&2
  echo "      docs/NOIR-RECORDER-DEFECTS.md." >&2
  [ -n "${4:-}" ] && sed 's/^/        /' <<<"$4" | tail -12 >&2
  regressed=$((regressed+1))
}

# ── set 1: the toolchain programs ──────────────────────────────────────────

run_toolchain() {
  while IFS=$'\t' read -r id sources stage outcome match owner defect kf flags; do
    selected "$id" || continue
    work="$WORKROOT/$id"
    rm -rf "$work"; mkdir -p "$work/out"
    cp -R "$HERE/$sources" "$work/pkg"

    case "$stage" in
      compile|record) cmd=(trace --out-dir "$work/out") ;;
      execute)        cmd=(execute) ;;
      # `help-lacks` pins the ABSENCE of something — a flag `nargo trace` does
      # not have and should. Its own stage rather than a negated match, so that
      # `hit` keeps ONE meaning everywhere: "the world is still as this entry
      # describes it".
      help-lacks)     cmd=(trace --help) ;;
      *) echo "  ??             $id: unknown stage '$stage'" >&2; fail=$((fail+1)); continue ;;
    esac
    # shellcheck disable=SC2206
    [ -n "$flags" ] && cmd+=($flags)

    output="$( cd "$work/pkg" && "$NARGO" "${cmd[@]}" 2>&1 )"
    status=$?

    hit=1
    if [ "$stage" = "help-lacks" ]; then
      grep -qF -- "$match" <<<"$output" && hit=0
    else
      grep -qF -- "$match" <<<"$output" || hit=0
      if [ "$outcome" = "ok" ]; then
        [ $status -eq 0 ] || hit=0
      else
        [ $status -ne 0 ] || hit=0
      fi
    fi

    if [ "$kf" = "1" ]; then
      if [ $hit -eq 1 ]; then report_known "$id" "$defect" "$owner"
      else report_now_passing "$id" "$defect" "$owner" "$output"; fi
    elif [ $hit -eq 1 ]; then
      echo "  ok             $id — $stage/$outcome pinned"
      pass=$((pass+1))
    else
      echo "  FAIL           $id — expected $stage/$outcome matching:" >&2
      echo "                   $match" >&2
      sed 's/^/                   /' <<<"$output" | tail -12 >&2
      fail=$((fail+1))
    fi
  done < <(read_toolchain)
}

# ── set 2: known failures visible in a RECORDING ───────────────────────────
#
# These read the vendored container rather than re-recording it, so the check is
# over the bytes the demo chain actually publishes. Needs `ct-print`, which is
# not a build dependency of this repository — without it the checks are reported
# as NOT RUN rather than skipped silently, because a known-failure register that
# quietly checks nothing is worse than none.

run_recording() {
  local any=0
  while IFS=$'\t' read -r id container defect owner absent present; do
    selected "$id" || continue
    any=1
    if [ -z "$CT_PRINT" ] || [ ! -x "$CT_PRINT" ]; then
      echo "  NOT RUN        $id — $defect needs ct-print; set CT_PRINT=" >&2
      fail=$((fail+1)); continue
    fi
    out="$("$CT_PRINT" "$HERE/$container" 2>&1)"
    hit=1
    # Regexes, not fixed strings: the detector has to name the VARIABLE as
    # well as the value, or an unrelated program taking the same number would
    # report a defect fixed that is not.
    [ -n "$absent"  ] && { grep -qE -- "$absent"  <<<"$out" && hit=0; }
    [ -n "$present" ] && { grep -qE -- "$present" <<<"$out" || hit=0; }
    if [ $hit -eq 1 ]; then report_known "$id" "$defect" "$owner"
    else report_now_passing "$id" "$defect" "$owner" ""; fi
  done < <(read_recordable_known_failures)
  return $any
}

# ── the self-test: prove both directions decide ────────────────────────────

selftest() {
  echo "self-test — the known-failure mechanism must decide in BOTH directions"
  local tmp rc=0
  tmp="$(mktemp -d)"

  # Arm 1: an entry whose `match` can never hold. The mechanism must call it
  # NOW PASSING and the run must fail. Without this arm a ledger that silenced
  # everything would look identical to one that decides.
  python3 - "$MANIFEST" "$tmp/m1.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for p in m.get("toolchainPrograms", []):
    if p["id"] == "enums":
        p["expect"]["match"] = "a sentence no compiler will ever emit"
json.dump(m, open(sys.argv[2], "w"))
PY
  if MANIFEST="$tmp/m1.json" "$0" enums >"$tmp/o1" 2>&1; then
    echo "  SURVIVED  arm 1: a known failure that stopped holding did NOT fail the run" >&2
    rc=1
  elif grep -q "NOW PASSING" "$tmp/o1"; then
    echo "  ok        arm 1: a known failure that stops holding reports NOW PASSING and fails"
  else
    echo "  SURVIVED  arm 1: the run failed, but not with NOW PASSING" >&2
    sed 's/^/            /' "$tmp/o1" >&2; rc=1
  fi

  # Arm 2: the same entry with `knownFailure` cleared. The same observation must
  # now be an ordinary PASS — so the flag is what decides, not the observation.
  python3 - "$MANIFEST" "$tmp/m2.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for p in m.get("toolchainPrograms", []):
    if p["id"] == "enums":
        p["expect"]["knownFailure"] = False
json.dump(m, open(sys.argv[2], "w"))
PY
  if MANIFEST="$tmp/m2.json" "$0" enums >"$tmp/o2" 2>&1 && grep -q "^  ok  " "$tmp/o2"; then
    echo "  ok        arm 2: the same observation without the flag is an ordinary pass"
  else
    echo "  SURVIVED  arm 2: clearing knownFailure did not turn it into a pass" >&2
    sed 's/^/            /' "$tmp/o2" >&2; rc=1
  fi

  # Arm 3: the base case. The real manifest must PASS, or the two arms above
  # would be satisfied by a script that fails on everything.
  if "$0" >"$tmp/o3" 2>&1; then
    echo "  ok        arm 3: the real corpus passes, so the arms above are not vacuous"
  else
    echo "  SURVIVED  arm 3: the real corpus does not pass" >&2
    sed 's/^/            /' "$tmp/o3" >&2; rc=1
  fi

  rm -rf "$tmp"
  [ $rc -eq 0 ] && echo "self-test: PASS" || echo "self-test: FAILED" >&2
  return $rc
}

if [ "${1:-}" = "--selftest" ]; then selftest; exit $?; fi

rm -rf "$WORKROOT"; mkdir -p "$WORKROOT"
run_toolchain
run_recording || true

echo
echo "corpus: $pass pinned, $known known failure(s) still open, $fail unexpected, $regressed newly passing"
if [ $regressed -gt 0 ]; then
  echo "A newly-passing known failure FAILS this run deliberately: it is good news" >&2
  echo "that must not be able to go unnoticed." >&2
fi
[ $fail -eq 0 ] && [ $regressed -eq 0 ]
