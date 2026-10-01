#!/usr/bin/env bash
#
# verify-published-readonly-test.sh — does the read-only guard BITE?
#
# `verify-published-readonly.sh` strips comments and string literals before
# matching, and the files it scans are full of prose naming the exact methods it
# looks for. A strip that was one character too greedy would remove the CODE as
# well and the guard would pass over anything. So this plants a real call in a
# copy of the tree and requires a refusal — once per write method, and once for
# a call sitting on a line that ALSO carries a comment, which is the shape the
# trailing-comment strip could eat.
#
# It also checks the other direction: an unmodified copy must PASS, so a guard
# that simply always failed would not be mistaken for one that works.
#
# Writes only into a temp directory it removes.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$root/ci/test/verify-published-readonly.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/src/blocktracer/verify"
cp "$root"/src/blocktracer/verify/*.nim "$work/src/blocktracer/verify/"
cp "$root/src/blocktracer_verify_published.nim" "$work/src/"

fails=0
expect() { # expect <want-exit> <label>
  local want="$1" label="$2" got=0
  bash "$guard" "$work" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  ok    $label (exit $got)"
  else
    echo "  FAIL  $label — wanted exit $want, got $got"
    fails=$((fails + 1))
  fi
}

restore() {
  cp "$root"/src/blocktracer/verify/*.nim "$work/src/blocktracer/verify/"
  cp "$root/src/blocktracer_verify_published.nim" "$work/src/"
}

echo "control:"
expect 0 "an unmodified copy passes"

target="$work/src/blocktracer/verify/source.nim"
for m in put putIfAbsent putMany del; do
  restore
  printf '\nproc leak*(s: S3Source, k, v: string) =\n  s.store.%s(k, v)\n' "$m" >> "$target"
  expect 1 "a planted .$m( is refused"
done

# The line that would survive an over-greedy trailing-comment strip.
restore
printf '\nproc leak2*(s: S3Source, k, v: string) =\n  s.store.put(k, v)  # a comment after the call\n' >> "$target"
expect 1 "a planted call with a trailing comment is refused"

# And the direction the strip exists FOR: prose naming a method is not a call.
restore
printf '\n## This module never calls .put( or .del( or .putMany(.\nconst note* = "do not .putIfAbsent( here"\n' >> "$target"
expect 0 "prose and string literals naming a write method are NOT a violation"

# An empty subject tree must refuse rather than report zero violations.
empty="$(mktemp -d)"
mkdir -p "$empty/src/blocktracer/verify"
got=0
bash "$guard" "$empty" >/dev/null 2>&1 || got=$?
if [ "$got" -eq 1 ]; then
  echo "  ok    an empty subject tree refuses rather than passing (exit 1)"
else
  echo "  FAIL  an empty subject tree returned $got — a scan with no subjects must not pass"
  fails=$((fails + 1))
fi
rm -rf "$empty"

echo ""
if [ "$fails" -gt 0 ]; then
  echo "FAIL: $fails case(s) — the guard does not bite as claimed."
  exit 1
fi
echo "OK: the read-only guard refuses every planted write and accepts prose."
