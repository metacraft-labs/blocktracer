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
# CI runs this suite as eight shards because one job cannot finish it inside any
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
# THIS NUMBER TRACKS `ci.yml`'s MATRIX, and a proof taken over a different
# partition than the one CI runs is a proof about nothing CI does. It moved 4 ->
# 8 with the matrix; if the matrix moves again, this moves with it.
SH=8
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
# THE SYNTHETIC WORLD MUST BE A WORLD THIS REPOSITORY COULD BE IN, and the
# arm ledger is what makes "every arm killed" stop being one.
#
# This wrote every arm as `killed`, which was an intact partition until
# `arm-ledger.json` gained its first entry — at which point the control below
# started FAILING, correctly, with `THE REASON HAS EVAPORATED`: a world where
# a ledgered arm is killed is a world whose entry must be deleted, and the
# combine says so. The fixture was encoding "no arm is ledgered", a fact that
# goes stale the moment one is, and a stale fixture in the file that proves the
# refusals is exactly the rot this script exists against.
#
# So the ledger is READ and each ledgered arm is written as the SURVIVAL its
# entry records, detail included. The control then asserts what it means to:
# that a partition consistent with the tree combines to OK.
mkjournals() { # mkjournals <dir-tag> ; writes $SH journals from $LOGS/shard-i
  for i in $(seq 1 $SH); do
    python3 - "$LOGS/shard-$i" "$i" "$SH" "tools/journeys/.selftest-journal.shard-${i}of${SH}.json" \
             "tools/journeys/arm-ledger.json" <<'PY'
import json, os, sys
src, i, of, dest, ledger_path = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], sys.argv[5]
ids = [l.strip() for l in open(src) if l.strip()]
ledger = {}
if os.path.exists(ledger_path):
    ledger = json.load(open(ledger_path)).get("known_survivors", {}) or {}
arms = []
for a in ids:
    e = ledger.get(a)
    if e:
        arms.append({"id": a, "verdict": "survived", "detail": e["detail"], "seconds": 1})
    else:
        arms.append({"id": a, "verdict": "killed", "detail": None, "seconds": 1})
json.dump({
    "startedAt": "2026-01-01T00:00:00.000Z",
    "finishedAt": "2026-01-01T00:10:00.000Z",
    "status": "done",
    "planned": len(ids),
    "armFilter": None,
    "shard": {"i": i, "of": of},
    "arms": arms,
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
# DERIVED FROM $SH, not written out. It said "three" while $SH was 4 and would
# have gone on saying "three" at 8 — a sentence describing a check does not get
# corrected when the check does.
ck "6d/and the other $((SH - 1)) passing shards do NOT combine to a pass" $?
[ "$rc" -eq 2 ]
ck "6d/exits 2 (did-not-run), not 0 and not 1 (got $rc)" $?

# 6e — the arms are all present but one SURVIVED. The partition is fine and the
# suite is not: this must be FAILED, distinct from every DID NOT RUN above.
mkjournals
python3 - "tools/journeys/.selftest-journal.shard-1of${SH}.json" <<'PY'
import json, sys
p = sys.argv[1]
j = json.load(open(p))
# THE FIRST *KILLED* ARM, not `arms[0]`. A ledgered arm is already written as a
# survival by `mkjournals`, so turning `arms[0]` into one would be a no-op that
# asserted FAILED over a world the ledger legitimises — the probe passing or
# failing on which arm happened to sort first.
victim = next(a for a in j["arms"] if a["verdict"] == "killed")
victim["verdict"] = "survived"
victim["detail"] = "a survival no entry in arm-ledger.json describes"
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
echo "=== probe 7: the arm ledger fails in BOTH directions ==="
# A LEDGER IS A MECHANISM FOR LEGITIMISING A RED, so a ledger nobody has watched
# fail is worse than no ledger: it is a green whose backing is unexamined. Every
# direction the entry can be wrong in is produced here, for real, and each is
# demanded by name.
#
# NOTHING IN THE REPOSITORY IS TOUCHED BY THIS PROBE. `selftest.mjs` resolves
# both the journal and `arm-ledger.json` relative to its own directory, so a
# COPY of the one file in a temp directory gives the probe its own ledger and
# its own journals — and the real `arm-ledger.json` cannot be left replaced by a
# process that dies mid-probe, which is the failure this whole script is about.
# `--combine` reads journals and the ledger and executes NO arm, so the four
# directions cost milliseconds rather than a sweep.
LJ="$LOGS/ledgerdir"
mkdir -p "$LJ"
cp tools/journeys/selftest.mjs "$LJ/selftest.mjs"
LLED="$LJ/arm-ledger.json"

node "$LJ/selftest.mjs" --list-arms | sort > "$LOGS/l-all"
LN=$(grep -c . "$LOGS/l-all")
[ "$LN" -ge 20 ]
ck "7/the copy sees the same arm list ($LN arms)" $?

# ONE journal holding every arm — `--combine 1`. The partition proof above is a
# separate claim and is not re-made here; what is under test is the ledger.
mkledgerjournal() { # mkledgerjournal <victim-id> <verdict> <detail>
  python3 - "$LOGS/l-all" "$LJ/.selftest-journal.shard-1of1.json" "$1" "$2" "$3" <<'PY'
import json, sys
src, dest, victim, verdict, detail = sys.argv[1:6]
ids = [l.strip() for l in open(src) if l.strip()]
arms = [{"id": a, "journey": "j", "verdict": "killed", "seconds": 1, "detail": None}
        for a in ids]
for a in arms:
    if a["id"] == victim:
        a["verdict"] = verdict
        a["detail"] = detail if detail else None
json.dump({
    "startedAt": "2026-01-01T00:00:00.000Z",
    "finishedAt": "2026-01-01T00:10:00.000Z",
    "status": "done", "planned": len(ids), "armFilter": None,
    "shard": {"i": 1, "of": 1}, "arms": arms, "lastArmStarted": None,
}, open(dest, "w"))
PY
}
# An entry with every required field filled, for whichever arm is named.
mkentry() { # mkentry <arm-id> <detail> [journey-override] [assertion-override]
  python3 - "$LLED" "$1" "$2" "${3:-}" "${4:-}" "$LOGS/l-desc" <<'PY'
import json, sys
dest, arm_id, detail, j_over, a_over, desc = sys.argv[1:7]
d = json.load(open(desc))
json.dump({"known_survivors": {arm_id: {
    "verdict": "survived",
    "journey": j_over or d["journey"],
    "assertion": a_over or d["assertion"],
    "detail": detail,
    "why_it_survives": (
        "SYNTHETIC ENTRY, written by selftest-verdict-test.sh probe 7 and never "
        "present in the repository. It exists to make the ledger's own machinery "
        "fail in each of its four directions, which is the only way to know the "
        "machinery is there at all."),
    "killed_by": (
        "Nothing — this entry describes no real survival and is deleted with the "
        "temporary directory it lives in."),
    "measured": "never; synthetic",
}}}, open(dest, "w"))
PY
}

VICTIM="$(head -1 "$LOGS/l-all")"
node "$LJ/selftest.mjs" --describe-arm "$VICTIM" > "$LOGS/l-desc"
DETAIL="counted 4, the claim says 4"

# 7a CONTROL — an intact all-killed journal with NO ledger combines to OK.
# Without it every red below is unattributable: it could be the synthetic
# journal being refused rather than the ledger speaking.
rm -f "$LLED"
mkledgerjournal "$VICTIM" killed ""
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l0" 2>&1
rc=$?
grep -q "RESULT: OK" "$LOGS/l0" && [ "$rc" -eq 0 ]
ck "7a/CONTROL: all killed, no ledger — OK (got $rc)" $?
grep -q "population: $LN arm(s) in this file · $LN exercised · $LN killed · 0 survived · 0 never ran · 0 ledgered" "$LOGS/l0"
ck "7a/and the POPULATION is stated, not just the verdict" $?

# 7b RED — the same survivor, with NO ledger. This is the state the ledger was
# built for, and it must still be a failure when no entry claims it.
mkledgerjournal "$VICTIM" survived "$DETAIL"
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l1" 2>&1
rc=$?
grep -q "RESULT: FAILED" "$LOGS/l1" && [ "$rc" -eq 1 ]
ck "7b/RED: an unledgered survivor FAILS (got $rc)" $?
grep -q "SURVIVED   $VICTIM" "$LOGS/l1"
ck "7b/and is named" $?

# 7c GREEN — the same journal, with an entry recording that same detail. The
# arm is still counted and still printed; what changes is the exit code.
mkentry "$VICTIM" "$DETAIL"
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l2" 2>&1
rc=$?
grep -q "RESULT: OK" "$LOGS/l2" && [ "$rc" -eq 0 ]
ck "7c/GREEN: an entry suppresses the exit code for that survivor (got $rc)" $?
grep -q "APPLIED        $VICTIM" "$LOGS/l2"
ck "7c/and says so, by arm name" $?
grep -q "1 LEDGERED (arm-ledger.json)" "$LOGS/l2"
ck "7c/and the RESULT line itself carries the ledgered count" $?
grep -q "population: $LN arm(s) in this file · $LN exercised · $((LN - 1)) killed · 0 survived · 0 never ran · 1 ledgered" "$LOGS/l2"
ck "7c/and the population reconciles: the survivor is counted, not dropped" $?

# 7d RED — THE OTHER DIRECTION, and the reason an entry is allowed to exist. The
# entry stands and the arm is now KILLED: whatever it said stands in the way is
# no longer standing there, so the entry has outlived its reason and the run
# must demand its deletion rather than pass quietly.
mkledgerjournal "$VICTIM" killed "counted 0, the claim says 4"
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l3" 2>&1
rc=$?
grep -q "RESULT: FAILED" "$LOGS/l3" && [ "$rc" -eq 1 ]
ck "7d/RED: a LEDGERED arm that is KILLED fails the run (got $rc)" $?
grep -q "THE REASON HAS EVAPORATED  $VICTIM" "$LOGS/l3"
ck "7d/and names the entry to delete" $?

# 7e RED — the entry legitimises a SURVIVAL. A never-ran is the absence of a
# measurement, and an entry that absorbed one would certify a dead arm.
mkledgerjournal "$VICTIM" never ""
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l4" 2>&1
rc=$?
grep -q "RESULT: FAILED" "$LOGS/l4" && [ "$rc" -eq 1 ]
ck "7e/RED: a LEDGERED arm that NEVER RAN fails (got $rc)" $?
grep -q "THE ENTRY DOES NOT COVER THIS  $VICTIM" "$LOGS/l4"
ck "7e/and says the entry does not cover it" $?

# 7f RED — it still survives, but not in the way that was diagnosed. A survival
# whose numbers moved is a survival nobody has looked at.
mkledgerjournal "$VICTIM" survived "counted 9, the claim says 4"
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l5" 2>&1
rc=$?
grep -q "RESULT: FAILED" "$LOGS/l5" && [ "$rc" -eq 1 ]
ck "7f/RED: a survival with a DIFFERENT detail is not covered (got $rc)" $?
grep -q "THE SURVIVAL MOVED  $VICTIM" "$LOGS/l5"
ck "7f/and both details are printed side by side" $?

# 7g REFUSAL — the entry names an arm this file does not have. Exit 2 and not 1:
# a ledger that does not describe these arms cannot be consulted about them, and
# that is "this gate did not run", not a verdict about the arms.
mkledgerjournal "$VICTIM" killed ""
python3 - "$LLED" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
(k, v), = d["known_survivors"].items()
d["known_survivors"] = {"ZZ/an-arm-that-was-deleted": v}
json.dump(d, open(p, "w"))
PY
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l6" 2>&1
rc=$?
grep -q "RESULT: DID NOT RUN" "$LOGS/l6" && [ "$rc" -eq 2 ]
ck "7g/REFUSAL: an entry for an arm that does not exist — exit 2 (got $rc)" $?

# 7h REFUSAL — the arm was RE-AIMED under the entry. The diagnosis was written
# about a different assertion, so it says nothing about this one.
mkentry "$VICTIM" "$DETAIL" "" "an assertion this arm does not target"
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l7" 2>&1
rc=$?
grep -q "RESULT: DID NOT RUN" "$LOGS/l7" && [ "$rc" -eq 2 ]
ck "7h/REFUSAL: the arm was re-aimed under the entry — exit 2 (got $rc)" $?
grep -q "Re-aiming an arm invalidates the diagnosis" "$LOGS/l7"
ck "7h/and says why" $?

# 7i REFUSAL — a blank field, and a shrug. Adding an entry must cost more than
# fixing the arm; a diagnosis nobody wrote is not one.
mkentry "$VICTIM" "$DETAIL"
python3 - "$LLED" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for v in d["known_survivors"].values():
    v["killed_by"] = ""
json.dump(d, open(p, "w"))
PY
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l8" 2>&1
rc=$?
grep -q "RESULT: DID NOT RUN" "$LOGS/l8" && [ "$rc" -eq 2 ]
ck "7i/REFUSAL: a blank required field — exit 2 (got $rc)" $?
mkentry "$VICTIM" "$DETAIL"
python3 - "$LLED" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for v in d["known_survivors"].values():
    v["why_it_survives"] = "it just does"
json.dump(d, open(p, "w"))
PY
node "$LJ/selftest.mjs" --combine 1 > "$LOGS/l9" 2>&1
rc=$?
grep -q "RESULT: DID NOT RUN" "$LOGS/l9" && [ "$rc" -eq 2 ]
ck "7i/REFUSAL: a shrug where the diagnosis goes — exit 2 (got $rc)" $?
grep -q "is a shrug" "$LOGS/l9"
ck "7i/and says so" $?

# 7j — the REAL ledger in the repository is about the arms this file has. The
# probes above prove the machinery; this proves the tree is in a state the
# machinery accepts, which is the half a synthetic fixture can never cover.
node tools/journeys/selftest.mjs --check-ledger > "$LOGS/l10" 2>&1
rc=$?
[ "$rc" -eq 0 ]
ck "7j/the repository's own arm-ledger.json describes these arms (got $rc)" $?

echo ""
echo "$((pass + fail)) probe(s): $pass passed, $fail failed"
if ! git diff --quiet -- "$MUT"; then
  echo "  $MUT IS STILL MUTATED after this script — that is a defect in this script."
  fail=$((fail + 1))
fi
if ! git diff --quiet -- tools/journeys/arm-ledger.json 2>/dev/null; then
  echo "  tools/journeys/arm-ledger.json WAS MODIFIED by this script — probe 7 is"
  echo "  supposed to work entirely inside a temporary copy. That is a defect here."
  fail=$((fail + 1))
fi
if [ "$fail" -eq 0 ]; then
  echo "  Each way this suite can end without finishing now names itself."
  echo "RESULT: OK"
else
  echo "RESULT: FAILED"
  exit 1
fi
