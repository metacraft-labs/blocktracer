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
echo "=== probe 2b: the same, with stdout through a PIPE ==="
# NOT a duplicate of probe 2, and the difference is the whole point.
#
# `process.stdout` is synchronous only for FILES and TTYs. To a PIPE it is
# asynchronous, and `process.exit()` does not drain it — so a verdict printed
# with `console.log` from a signal handler is written under `> file` and
# DISCARDED under `| tee`, in a CI log collector, or through an agent's shell
# wrapper. Probe 2 redirects, so it cannot see this; the piped runs are the ones
# most likely to need the verdict.
#
# `> >(cat > file)` and not `| cat > file`: stdout is a pipe either way, but a
# process substitution leaves `$!` as NODE's pid. In a pipeline `$!` is the last
# stage, and signalling that would test nothing.
rm -f "$J"
node tools/journeys/selftest.mjs --arm A/no-position-mark > >(cat > "$LOGS/p2b") 2>&1 &
pid=$!
for _ in $(seq 1 600); do
  mutation_applied && break
  kill -0 $pid 2>/dev/null || break
  sleep 0.5
done
mutation_applied
ck "the arm's mutation is on disk — the probe has a subject" $?
kill -TERM $pid
wait $pid 2>/dev/null
sleep 1   # let the `cat` on the other end of the pipe finish writing
grep -q "RESULT: DID NOT RUN — SIGTERM" "$LOGS/p2b"
ck "the verdict survives the pipe" $?
git diff --quiet -- "$MUT"
ck "and the file is back" $?

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
echo "=== probe 5: the SHARDING partitions the arm list, exactly ==="
# CI runs this suite as four shards because one job cannot finish it inside any
# bound worth setting. That trade is only safe if the four shards are a
# PARTITION: every arm in exactly one of them, and their union the whole list.
#
# A sharded sweep that silently drops an arm is strictly worse than the timeout
# it replaced. A timeout is loud — the step goes red and says it was killed. A
# missing arm is silent, and it produces the shape this repository has already
# been fooled by once: a clean-looking summary over a subset wearing the full
# set's name.
#
# `--list-shard` reports the slice THROUGH `shardOf`, the same function `main`
# slices with, so this is a proof about what runs and not about a model of it.
SH=4
rm -f "$LOGS"/shard-*
all="$LOGS/all-arms"
node tools/journeys/selftest.mjs --list-arms | sort > "$all"
n_all=$(grep -c . "$all")

# NON-EMPTY FIRST. Every assertion below quantifies over these lists, and two
# empty files compare equal — a broken lister would otherwise report a perfect
# partition of nothing (Verification-Harness-Traps.md §4).
[ "$n_all" -ge 20 ]
ck "the arm list is readable and non-trivial ($n_all arms)" $?

union="$LOGS/union"
: > "$union"
empty_shard=0
for i in $(seq 1 $SH); do
  node tools/journeys/selftest.mjs --list-shard "$i/$SH" | sort > "$LOGS/shard-$i"
  [ "$(grep -c . "$LOGS/shard-$i")" -gt 0 ] || empty_shard=$((empty_shard + 1))
  cat "$LOGS/shard-$i" >> "$union"
done
[ "$empty_shard" -eq 0 ]
ck "all $SH shards are non-empty (a shard holding nothing is a shard doing nothing)" $?

sort "$union" -o "$union"
diff -q "$all" "$union" >/dev/null
ck "the union of the $SH shards IS the arm list — none missing, none invented" $?

# Disjointness is a SEPARATE claim from the union. A list where one arm appears
# twice and another is absent has the right length and the wrong contents; a
# union compared as a SET would also hide the duplicate. So: compare the
# multiset.
dupes="$(sort "$union" | uniq -d)"
[ -z "$dupes" ]
dupes_rc=$?
# `dupes_rc` on its own line, NOT `ck "...$(...)" $?`. Written that way the `$?`
# is the status of the command substitution INSIDE the message, which runs
# during argument expansion — so the check reported FAILED over a partition
# with no duplicates in it. Caught here because probe 5's other five assertions
# disagreed with it, which is the only reason it was not believed.
ck "no arm is in two shards${dupes:+ (got: $(echo "$dupes" | tr '\n' ' '))}" "$dupes_rc"

[ "$(wc -l < "$union")" -eq "$n_all" ]
ck "the shards' arm COUNT sums to the arm list's ($(wc -l < "$union") vs $n_all)" $?

# A query must not have left a journal or a mutation behind.
[ ! -f "tools/journeys/.selftest-journal.shard-1of$SH.json" ]
ck "listing a shard writes NO journal — a query is not a run" $?

echo ""
echo "=== probe 6: --combine REFUSES a broken partition ==="
# The partition above is a property of today's arm list and stride. The combine
# is what defends it at runtime, after four shards have really run — and a
# defence nobody has watched fail is indistinguishable from no defence. Each
# case below hands `--combine` a set of journals with ONE thing wrong and
# demands it refuse for THAT reason.
#
# Synthetic journals, built from the real shard lists, so no arm is executed.
mkjournals() { # mkjournals <dir-tag> ; writes $SH journals from $LOGS/shard-i
  for i in $(seq 1 $SH); do
    python3 - "$LOGS/shard-$i" "$i" "$SH" "tools/journeys/.selftest-journal.shard-${i}of${SH}.json" <<'PY'
import json, sys
src, i, of, dest = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
ids = [l.strip() for l in open(src) if l.strip()]
json.dump({
    "startedAt": "2026-01-01T00:00:00.000Z",
    "finishedAt": "2026-01-01T00:10:00.000Z",
    "status": "done",
    "planned": len(ids),
    "armFilter": None,
    "shard": {"i": i, "of": of},
    "arms": [{"id": a, "verdict": "killed", "ms": 1000} for a in ids],
    "lastArmStarted": None,
}, open(dest, "w"))
PY
  done
}
cleanup_journals() { rm -f tools/journeys/.selftest-journal.shard-*of${SH}.json; }
trap 'rm -rf "$LOGS"; cleanup_journals' EXIT

# CONTROL. Without a combine that PASSES over an intact partition, every
# refusal below is unattributable — it could be refusing the synthetic journals
# themselves.
mkjournals
node tools/journeys/selftest.mjs --combine $SH > "$LOGS/c0" 2>&1
grep -q "RESULT: OK" "$LOGS/c0"
ck "CONTROL: an intact partition of killed arms combines to OK" $?

# 6a — an arm no shard ran.
mkjournals
victim="$(head -1 "$LOGS/shard-2")"
python3 - "tools/journeys/.selftest-journal.shard-2of${SH}.json" "$victim" <<'PY'
import json, sys
p, victim = sys.argv[1], sys.argv[2]
j = json.load(open(p))
j["arms"] = [a for a in j["arms"] if a["id"] != victim]
json.dump(j, open(p, "w"))
PY
node tools/journeys/selftest.mjs --combine $SH > "$LOGS/c1" 2>&1
grep -q "NOT RUN BY ANY SHARD  $victim" "$LOGS/c1"
ck "6a/a dropped arm is named: NOT RUN BY ANY SHARD" $?
grep -q "RESULT: DID NOT RUN" "$LOGS/c1"
ck "6a/and it is DID NOT RUN, not a pass and not a failure" $?

# 6b — an arm two shards both ran. The count still sums correctly if something
# else went missing, which is why this is checked on its own.
mkjournals
dup="$(head -1 "$LOGS/shard-1")"
python3 - "tools/journeys/.selftest-journal.shard-3of${SH}.json" "$dup" <<'PY'
import json, sys
p, dup = sys.argv[1], sys.argv[2]
j = json.load(open(p))
j["arms"].append({"id": dup, "verdict": "killed", "ms": 1000})
json.dump(j, open(p, "w"))
PY
node tools/journeys/selftest.mjs --combine $SH > "$LOGS/c2" 2>&1
grep -q "RUN BY MORE THAN ONE SHARD  $dup" "$LOGS/c2"
ck "6b/an arm in two shards is named: RUN BY MORE THAN ONE SHARD" $?

# 6c — a stale journal from an older arm list.
mkjournals
python3 - "tools/journeys/.selftest-journal.shard-4of${SH}.json" <<'PY'
import json, sys
p = sys.argv[1]
j = json.load(open(p))
j["arms"].append({"id": "ZZ/an-arm-deleted-last-week", "verdict": "killed", "ms": 1})
json.dump(j, open(p, "w"))
PY
node tools/journeys/selftest.mjs --combine $SH > "$LOGS/c3" 2>&1
grep -q "AN ARM NO LONGER IN THIS FILE  ZZ/an-arm-deleted-last-week" "$LOGS/c3"
ck "6c/an arm from a stale shard is named: AN ARM NO LONGER IN THIS FILE" $?

# 6d — a shard that never ran at all. THE ONE THAT MATTERS MOST: this is what a
# cancelled or timed-out matrix leg looks like, and "3 of 4 shards passed" must
# never read as a verdict about the suite.
mkjournals
rm -f "tools/journeys/.selftest-journal.shard-2of${SH}.json"
node tools/journeys/selftest.mjs --combine $SH > "$LOGS/c4" 2>&1
rc=$?
grep -q "shard 2/$SH: NO JOURNAL" "$LOGS/c4"
ck "6d/a shard that never ran is named, by index" $?
grep -q "RESULT: DID NOT RUN" "$LOGS/c4"
ck "6d/and three passing shards do NOT combine to a pass" $?
[ "$rc" -eq 2 ]
ck "6d/exits 2 (did-not-run), not 0 and not 1 (got $rc)" $?

# 6e — the arms are all present but one SURVIVED. The partition is fine and the
# suite is not: this must be FAILED, distinct from every DID NOT RUN above.
mkjournals
python3 - "tools/journeys/.selftest-journal.shard-1of${SH}.json" <<'PY'
import json, sys
p = sys.argv[1]
j = json.load(open(p))
j["arms"][0]["verdict"] = "survived"
json.dump(j, open(p, "w"))
PY
node tools/journeys/selftest.mjs --combine $SH > "$LOGS/c5" 2>&1
rc=$?
grep -q "RESULT: FAILED" "$LOGS/c5"
ck "6e/an intact partition with a SURVIVOR is FAILED, not DID NOT RUN" $?
[ "$rc" -eq 1 ]
ck "6e/exits 1 (got $rc)" $?
cleanup_journals

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
