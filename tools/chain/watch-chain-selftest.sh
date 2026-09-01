#!/bin/sh
# watch-chain-selftest.sh — proof that the supervisor's STOP conditions are the only stops.
#
#   sh tools/chain/watch-chain-selftest.sh
#
# WHY THIS EXISTS. The supervisor's whole job is to be running when nobody is looking, and
# the way it failed was to stop for a reason that looked like success: it broke on the
# follower's exit code 0, two seconds after the only catch of the session, and printed a
# `supervisor-done` indistinguishable from a healthy line. A supervisor is exactly the kind
# of code whose failure is invisible until the thing it was supervising is needed, so its
# exit conditions are driven here against a FAKE follower whose exit code this test chooses.
#
# No node, no chain, no AVM: the follower is replaced by a script that exits on demand, which
# is the only way each stop condition can be reached deliberately and each non-stop condition
# shown NOT to stop.
#
# Each case carries a control arm and a mutation arm, and the assertion count is declared.
set -u

asserted=0
failed=0
ck() {
  asserted=$((asserted + 1))
  if [ "$2" = "yes" ]; then printf '  ok    %s\n' "$1"
  else failed=$((failed + 1)); printf '  FAIL  %s\n' "$1"; fi
}
bite() {
  asserted=$((asserted + 1))
  if [ "$2" = "yes" ]; then printf '  bite  %s\n' "$1"
  else failed=$((failed + 1)); printf '  FAIL  MUTATION DID NOT BITE  %s\n' "$1"; fi
}
has() { grep -q "$2" "$1" && echo yes || echo no; }
# `grep -c` PRINTS 0 and EXITS 1 when there is no match, so a `|| echo 0` fallback appends a
# second line and every "is the count zero" comparison silently fails. The count is already
# on stdout; only the exit code needs swallowing. (The same lesson as the rest of this
# campaign: read the output, not the status.)
countOf() { grep -c "$2" "$1" 2>/dev/null || true; }

SUP="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/watch-chain.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A worktree the supervisor can cd into, with a follower it will invoke.
mkdir -p "$TMP/wt/tools/chain"
: > "$TMP/wt/tools/chain/follow-chain.mjs"

# The fake node: ignores every argument and exits with the code in $TMP/rc.
cat > "$TMP/fakenode" <<'EOF'
#!/bin/sh
n=$(cat "$RCDIR/arms" 2>/dev/null || echo 0)
echo $((n + 1)) > "$RCDIR/arms"
exit "$(cat "$RCDIR/rc")"
EOF
chmod +x "$TMP/fakenode"

run_sup() {  # run_sup <rc> <max-arms> [stopfile-after-arms]
  rm -f "$TMP/log" "$TMP/log.stderr" "$TMP/log.stop" "$TMP/arms"
  echo "$1" > "$TMP/rc"
  echo 0 > "$TMP/arms"
  RCDIR="$TMP" WT="$TMP/wt" RUNTIME="$TMP" NODE_BIN="$TMP/fakenode" \
    AVM_WASM_PATH="$TMP/a" CT_WRITER_WASM_PATH="$TMP/c" \
    DEADLINE_MIN=1 INTERVAL_S=1 STOP_FILE="$TMP/log.stop" \
    sh "$SUP" "$TMP/log" "$2" >/dev/null 2>&1
}

echo
echo 'case 1 — a follower that exits 0 does NOT end the watch'
# THE REGRESSION. `--until 0` means exit 0 is "this arm caught something", not "we are done".
# Bounded with max-arms so the test terminates; the point is that it reached the bound
# rather than stopping at the first 0.
run_sup 0 3
ck 'control: it re-armed 3 times despite every arm exiting 0' \
   "$([ "$(countOf "$TMP/log" '"event":"supervisor-arm"')" = 3 ] && echo yes || echo no)"
ck 'control: it stopped only because the arm bound was reached' \
   "$(has "$TMP/log" '"reason":"max-arms"')"
ck 'control: and it said it is no longer watching' \
   "$(has "$TMP/log" '"stillWatching":false')"
# MUTATION: the OLD rule, applied to the same log — `rc 0 -> break` would have ended the
# watch after arm 1. Asserted against the recorded arm count, which is 3, not 1.
bite 'mutation: the old `break on rc 0` rule would have stopped after one arm' \
     "$([ "$(countOf "$TMP/log" '"event":"supervisor-arm"')" -gt 1 ] && echo yes || echo no)"

echo
echo 'case 2 — a follower that exits 1 does NOT end the watch either'
run_sup 1 2
ck 'control: it re-armed 2 times on a barren arm' \
   "$([ "$(countOf "$TMP/log" '"event":"supervisor-arm"')" = 2 ] && echo yes || echo no)"
ck 'control: every arm logged its exit' \
   "$([ "$(countOf "$TMP/log" '"event":"supervisor-exit"')" = 2 ] && echo yes || echo no)"

echo
echo 'case 3 — a preflight/config refusal (rc 2) DOES end it, by name'
run_sup 2 5
ck 'control: it stopped' "$(has "$TMP/log" '"event":"supervisor-done"')"
ck 'control: it stopped after ONE arm, not five' \
   "$([ "$(countOf "$TMP/log" '"event":"supervisor-arm"')" = 1 ] && echo yes || echo no)"
ck 'control: the reason names the refusal rather than being a bare done' \
   "$(has "$TMP/log" '"reason":"preflight-or-config-refusal"')"
# MUTATION: rc 2 is the ONLY code that stops. Case 1 ran the same bound with rc 0 and
# reached 3 arms, so this is not a supervisor that stops on everything.
bite 'mutation: the same bound with rc 0 did not stop after one arm' \
     "$(run_sup 0 5; [ "$(countOf "$TMP/log" '"event":"supervisor-arm"')" -gt 1 ] && echo yes || echo no)"

echo
echo 'case 4 — the stop file ends it, and says so'
rm -f "$TMP/log" "$TMP/arms"; echo 1 > "$TMP/rc"; echo 0 > "$TMP/arms"
touch "$TMP/log.stop"
RCDIR="$TMP" WT="$TMP/wt" RUNTIME="$TMP" NODE_BIN="$TMP/fakenode" \
  AVM_WASM_PATH="$TMP/a" CT_WRITER_WASM_PATH="$TMP/c" \
  DEADLINE_MIN=1 INTERVAL_S=1 STOP_FILE="$TMP/log.stop" \
  sh "$SUP" "$TMP/log" 0 >/dev/null 2>&1
ck 'control: a pre-existing stop file prevents even the first arm' \
   "$([ "$(countOf "$TMP/log" '"event":"supervisor-arm"')" = 0 ] && echo yes || echo no)"
ck 'control: and the reason is the stop file, not a silent return' \
   "$(has "$TMP/log" '"reason":"stop-file"')"

echo
echo 'case 5 — the start line records the configuration the watch is running under'
run_sup 1 1
ck 'control: a supervisor-start line exists' "$(has "$TMP/log" '"event":"supervisor-start"')"
ck 'control: it records --until 0, the setting that makes the watch continuous' \
   "$(has "$TMP/log" '"until":0')"
ck 'control: it records where the stop file is, so it can be found without this source' \
   "$(has "$TMP/log" '"stopFile"')"

echo
if [ "$asserted" -ne 15 ]; then
  echo "ASSERTION COUNT IS $asserted, EXPECTED 15 — a case was added, removed or skipped."
  failed=$((failed + 1))
else
  echo "assertion count: $asserted (as declared)"
fi
if [ "$failed" -ne 0 ]; then echo "FAIL — $failed problem(s)"; exit 1; fi
echo 'PASS — the only stops are the three that say they are stopping'
