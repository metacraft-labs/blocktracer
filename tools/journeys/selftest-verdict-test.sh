#!/usr/bin/env bash
# selftest-verdict-test.sh — proof that the journey selftest SAYS when it did
# not run.
#
#   bash tools/journeys/selftest-verdict-test.sh
#   just journeys-selftest-verdict
#
# The same relation `ci/test/<subject>-test.sh` has to `ci/test/<subject>.sh`:
# plant the violation for real and prove it is reported. Here the "violation" is
# a way of ENDING — the suite dying without a verdict — and the claim under test
# is that each way of ending now names itself.
#
# WHY THIS EXISTS
# ---------------
# `selftest.mjs` has been observed dying part-way through its arm list with no
# `RESULT` line at all, and a stall producing no verdict reads to a human
# exactly like a suite nobody bothered to run. That is the worse member of the
# family: a suite that never completes cannot tell you which of its arms are
# dead, which is the one question it exists to answer.
#
# The fix is three mechanisms (see `selftest.mjs`, "DID NOT RUN AND FAILED MUST
# NOT LOOK THE SAME"). Machinery that reports an ending is only exercised by an
# ending, so nothing about it is covered by an ordinary run — which is precisely
# how it could rot without anyone noticing. Each probe below produces a real
# ending of the shape it names.
#
# EVERY PROBE POLLS THE ARTEFACT, NEVER THE CLOCK. A fixed `sleep` before the
# signal races the build: send it too early and the arm has not mutated anything
# yet, and the probe proves the restore works on a file nobody touched. The
# loops below wait for the mutation to appear ON DISK, and probe 2 asserts it
# was there before signalling — the subject of the experiment, checked rather
# than assumed.
#
# Uses `--arm A/no-position-mark`, the cheapest arm: its journey does not judge
# the hydrated artefact, so no bundle is rebuilt.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

J="tools/journeys/.selftest-journal.json"
MUT="client/src/components/debugger.nim"
NEEDLE='(if ln.current: " cur" else: "") &'   # `A/no-position-mark`'s `find`
LOGS="$(mktemp -d)"
trap 'rm -rf "$LOGS"' EXIT

pass=0
fail=0
ck() { # ck "<claim>" <rc>
  if [ "$2" -eq 0 ]; then
    echo "  [OK]     $1"
    pass=$((pass + 1))
  else
    echo "  [FAILED] $1"
    fail=$((fail + 1))
  fi
}
# Has the arm's mutation reached the file? The `find` string is ABSENT when it
# has. Stated as a function because getting this polarity backwards turns "the
# probe had no subject" into a pass.
mutation_applied() { ! grep -qF "$NEEDLE" "$MUT"; }

# A dirty subject file would make every restore check meaningless.
if ! git diff --quiet -- "$MUT"; then
  echo "  $MUT has uncommitted changes; the restore checks below could not mean"
  echo "  anything. Commit or stash it first."
  echo "RESULT: DID NOT RUN"
  exit 2
fi

echo "=== probe 1: an unmatched --arm judges nothing, and says so ==="
rm -f "$J"
node tools/journeys/selftest.mjs --arm zzz-no-such-arm > "$LOGS/p1" 2>&1
grep -q "RESULT: DID NOT RUN — no arm's id contains zzz-no-such-arm" "$LOGS/p1"
ck "prints DID NOT RUN, not FAILED — nothing was judged" $?
grep -q '"status": "did-not-run"' "$J"
ck "and the journal agrees" $?

echo ""
echo "=== probe 2: SIGTERM mid-arm — a verdict, and the mutation put back ==="
# The incident this is written from: a selftest process killed at a shell
# timeout left `K/the-served-values-stand` applied in a worktree, because the
# restore is a `finally` and a `finally` does not run when a process is
# signalled. Everything after it measured a defective tree.
rm -f "$J"
node tools/journeys/selftest.mjs --arm A/no-position-mark > "$LOGS/p2" 2>&1 &
pid=$!
for _ in $(seq 1 600); do
  mutation_applied && break
  kill -0 $pid 2>/dev/null || break
  sleep 0.5
done
mutation_applied
ck "the arm's mutation is on disk — the probe has a subject" $?
kill -TERM $pid
wait $pid
rc=$?
grep -q "RESULT: DID NOT RUN — SIGTERM" "$LOGS/p2"
ck "SIGTERM prints a DID NOT RUN verdict" $?
grep -q "A/no-position-mark" "$LOGS/p2"
ck "and names the arm it was running" $?
[ "$rc" -eq 2 ]
ck "exits 2 — not 0, and not the 1 a red run uses (got $rc)" $?
grep -q "restored the mutated file" "$LOGS/p2"
ck "says it restored the file" $?
git diff --quiet -- "$MUT"
ck "and the file really is back, byte-for-byte" $?
grep -q '"status": "did-not-run"' "$J"
ck "and the journal agrees" $?

echo ""
echo "=== probe 3: the NEXT run reports the unfinished one ==="
# SIGKILL: no handler runs, nothing is printed, and the only evidence is what
# was already on disk. This is the ending that is indistinguishable, from the
# log alone, from nobody having run the suite.
rm -f "$J"
node tools/journeys/selftest.mjs --arm A/no-position-mark > "$LOGS/p3a" 2>&1 &
pid=$!
for _ in $(seq 1 600); do
  [ -f "$J" ] && grep -q '"lastArmStarted": "A/no-position-mark"' "$J" && break
  kill -0 $pid 2>/dev/null || break
  sleep 0.5
done
kill -KILL $pid
wait $pid 2>/dev/null
! grep -q "RESULT" "$LOGS/p3a"
ck "a SIGKILLed run prints NO verdict — the state being detected" $?
grep -q '"status": "running"' "$J"
ck "but leaves a journal saying it was still running" $?
git checkout -- "$MUT"     # the kill left the mutation behind, by construction
node tools/journeys/selftest.mjs --arm zzz-no-such-arm > "$LOGS/p3b" 2>&1
grep -q "the PREVIOUS run did not finish" "$LOGS/p3b"
ck "the next run reports it" $?
grep -q "A/no-position-mark" "$LOGS/p3b"
ck "and names the arm it stopped in" $?
grep -q "It printed no verdict, so it judged nothing" "$LOGS/p3b"
ck "and says that is neither a pass nor a failure" $?

echo ""
echo "=== probe 4: a throw prints a verdict, not just a stack ==="
# Observed for real: `playwright is not installed`, thrown out of
# `judgesHydratedArtefact` before any arm ran. The top-level catch printed the
# stack and no `RESULT` line — a log that stops, over a run that judged nothing.
rm -f "$J"
if [ -d tools/capture/node_modules ]; then
  mv tools/capture/node_modules tools/capture/node_modules.hidden
  node tools/journeys/selftest.mjs --arm A/no-position-mark > "$LOGS/p4" 2>&1
  rc=$?
  mv tools/capture/node_modules.hidden tools/capture/node_modules
  grep -q "RESULT: DID NOT RUN — the run threw" "$LOGS/p4"
  ck "a throw prints a DID NOT RUN verdict" $?
  grep -q "playwright is not installed" "$LOGS/p4"
  ck "with the cause still visible above it" $?
  [ "$rc" -eq 2 ]
  ck "exits 2, not 1 (got $rc)" $?
else
  echo "  SKIPPED — no tools/capture/node_modules to hide (run: just capture-setup)"
  echo "  A SKIP IS NOT A PASS."
  fail=$((fail + 1))
fi

echo ""
echo "$((pass + fail)) probe(s): $pass passed, $fail failed"
if ! git diff --quiet -- "$MUT"; then
  echo "  $MUT IS STILL MUTATED after this script — that is a defect in this script."
  fail=$((fail + 1))
fi
if [ "$fail" -eq 0 ]; then
  echo "  Each way this suite can end without finishing now names itself."
  echo "RESULT: OK"
else
  echo "RESULT: FAILED"
  exit 1
fi
