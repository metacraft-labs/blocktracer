#!/bin/sh
# watch-chain.sh — the supervisor for `follow-chain.mjs`.
#
# ── WHY A SUPERVISOR AND NOT JUST THE FOLLOWER ────────────────────────────────────────
#
# The follower already survives the session that started it: it is detached, and it has run
# straight through one. What it does not survive is ITSELF ending — a crash, an OOM, or its
# own `--deadline-min` expiring. And a watch that has stopped looks EXACTLY like a watch that
# is looking and finding nothing. Both report zero catches, and on this chain zero catches is
# the expected reading for hours at a time, so the difference is invisible in the log unless
# something writes it down. Every arming is therefore logged, and so is every exit.
#
# ── WHY IT RE-ARMS RATHER THAN SPENDING A BUDGET ──────────────────────────────────────
#
# THE FIRST VERSION OF THIS SCRIPT ENDED THE WATCH SILENTLY, and it did it two seconds after
# the only successful replay of the session. It held a 12-hour wall-clock budget and passed
# `--until 1`, so the third arm caught 0x00c67f6f at block 68062, exited 0, and the loop
# broke on `[ "$rc" -eq 0 ] && break`. It printed `supervisor-done` and stopped. Mainnet was
# then unwatched, with nothing in the log saying so — the last line of a healthy watch and
# the last line of a finished one were the same line.
#
# That is the same defect the supervisor was written to fix, one level up. A watch that dies
# with its session and a watch that exhausts its arms are both watches that stopped without
# saying they had stopped, and the second is worse for being scheduled: it looks deliberate.
#
# So there is no wall-clock budget. The loop re-arms for as long as the chain is being
# watched, and every way out is loud — each one logs a `supervisor-done` (or, for the
# worktree case, its own reason) before it exits, so the log always says WHY the watch
# stopped. Grep `exit ` in the loop below for the authoritative set; today it is five:
#
#   * the stop file appears        — an operator ended it on purpose                (0)
#   * $MAX_ARMS is reached         — only when explicitly set; unset means unbounded (0)
#   * $WT cannot be entered        — the worktree is gone; re-arming cannot fix it   (1)
#   * the follower exits 2         — a preflight or configuration refusal, which re-arming
#                                    cannot fix and which would otherwise fill the log with
#                                    the same refusal forever                        (2)
#   * the capture TARGET is met    — only with `--until-complete-blocks N` set, where rc 0
#                                    means the snapshot reached N complete blocks; see the
#                                    comment at that exit                            (0)
#
# A NORMAL EXIT IS NOT A REASON TO STOP — WITH ONE NAMED EXCEPTION, THE ONE ABOVE. With
# `--until 0` and no completion target the follower runs its whole deadline and returns 0
# if it caught anything and 1 if it did not, so its exit code says what that arm found, NOT
# whether the watch is over. Breaking on 0 unconditionally is what ended the last one at
# its moment of success. When UNTIL_COMPLETE > 0 the operator has asked for a finish line,
# and rc 0 is that finish line rather than an arm ending.
#
# ── WHY --until 0 ─────────────────────────────────────────────────────────────────────
#
# `--until 1` made the follower stop at its first success. That is right for a tool being
# asked to produce one transaction and wrong for a watch: the snapshot GROWS, a second and
# third transaction are worth more than the first, and the measured arrival rate — roughly
# one first-in-block transaction per 36 blocks, hours apart — means stopping at one throws
# away the rest of the arm for nothing.
#
#   usage: watch-chain.sh <log> [max-arms]
#
#   WT=…            the worktree to run in            (default: this script's repo root)
#   NODE_BIN=…      node 24                            (required)
#   AVM_WASM_PATH=… the --import-memory avm.wasm       (required)
#   CT_WRITER_WASM_PATH=…                              (required)
#   RUNTIME=…       the aztec-avm-runtime checkout     (required)
#   DEADLINE_MIN=…  minutes per arm                    (default 360)
#   INTERVAL_S=…    seconds between polls              (default 60)
#   STOP_FILE=…     touch this to end the watch        (default <log>.stop)
#
#   exit 0  the watch ended for a reason it names (stop file, arm bound, target met)
#   exit 2  the follower refused on preflight or configuration; re-arming cannot fix it
#   exit 3  REFUSED TO START — the stop file was already there. Nothing was watched, and
#           that must not read as a watch that ended. See the branch below.
set -u

LOG="${1:?usage: watch-chain.sh <log> [max-arms]}"
MAX_ARMS="${2:-${MAX_ARMS:-0}}"          # 0 = unbounded

here=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
WT="${WT:-$here}"
RUNTIME="${RUNTIME:?RUNTIME must name an aztec-avm-runtime checkout}"
NODE_BIN="${NODE_BIN:?NODE_BIN must name a node 24 binary}"
AVM="${AVM_WASM_PATH:?AVM_WASM_PATH must name the --import-memory avm.wasm}"
CTW="${CT_WRITER_WASM_PATH:?CT_WRITER_WASM_PATH must name aztec_ct_writer.wasm}"
URL="${URL:-https://aztec.drpc.org}"
CHAIN="${CHAIN:-aztec}"
LABEL="${LABEL:-Real Aztec mainnet data}"
DEADLINE_MIN="${DEADLINE_MIN:-360}"
# The capture target: stop once the snapshot holds this many COMPLETE blocks (every
# transaction the chain published in them replayed). 0 = no target, watch continuously.
UNTIL_COMPLETE="${UNTIL_COMPLETE:-0}"
INTERVAL_S="${INTERVAL_S:-60}"
STOP_FILE="${STOP_FILE:-$LOG.stop}"

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '{"at":"%s",%s}\n' "$(now)" "$1" >> "$LOG"; }

say "\"event\":\"supervisor-start\",\"pid\":$$,\"maxArms\":$MAX_ARMS,\"deadlineMin\":$DEADLINE_MIN,\"stopFile\":\"$STOP_FILE\",\"until\":0,\"untilCompleteBlocks\":$UNTIL_COMPLETE"

ARM=0
while : ; do
  if [ -e "$STOP_FILE" ]; then
    # A STOP FILE THAT WAS ALREADY THERE IS NOT THIS WATCH BEING STOPPED.
    #
    # `STOP_FILE` defaults to `$LOG.stop`, so it OUTLIVES the run that was stopped
    # by it: start a second watch on the same log and the file from the first one
    # is still sitting there. Both cases used to write the same
    # `"reason":"stop-file"` and exit 0, and the only thing separating "we watched
    # the chain for six hours and you stopped us" from "we never looked at the
    # chain at all" was `"arms":0` — a field nobody greps for, on a run that
    # reported success. An entire capture skipped, and the log said done.
    #
    # NOT `rm -f` AT STARTUP, which is the obvious fix and is wrong twice. It
    # deletes an operator's signal: touch the file to stop a running watch, start
    # another watch on the same log before the first notices, and the first never
    # stops. And it would silently convert this into a normal start, which throws
    # away the fact that somebody meant this log to be finished.
    #
    # So nothing is deleted and nothing is guessed. The two cases are TOLD APART,
    # and the one that captured nothing stops reading as success: exit 3, the code
    # `gate-selftest` uses for PRECONDITION ABSENT, because a refusal to start is
    # not a watch that ended.
    if [ "$ARM" -eq 0 ]; then
      stop_at=$(date -r "$STOP_FILE" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)
      say "\"event\":\"supervisor-refused\",\"reason\":\"stop-file-present-at-start\",\"arms\":0,\"stopFile\":\"$STOP_FILE\",\"stopFileWritten\":\"$stop_at\",\"stillWatching\":false"
      {
        printf 'watch-chain.sh: refusing to start — the stop file already exists.\n'
        printf '  %s   (written %s, before this watch began)\n' "$STOP_FILE" "$stop_at"
        printf '  Treating it as this run own stop would exit 0 having captured nothing,\n'
        printf '  which is indistinguishable in the log from a watch that ran and was stopped.\n'
        printf '  remedy: rm %s   (or point STOP_FILE at a path of this run own)\n' "$STOP_FILE"
      } >&2
      exit 3
    fi
    say "\"event\":\"supervisor-done\",\"reason\":\"stop-file\",\"arms\":$ARM,\"stillWatching\":false"
    exit 0
  fi
  if [ "$MAX_ARMS" -gt 0 ] && [ "$ARM" -ge "$MAX_ARMS" ]; then
    # Reached only when a bound was asked for. It is still a STOP, so it is still loud:
    # the log has to distinguish "watching and finding nothing" from "no longer watching".
    say "\"event\":\"supervisor-done\",\"reason\":\"max-arms\",\"arms\":$ARM,\"stillWatching\":false"
    exit 0
  fi

  ARM=$((ARM + 1))
  say "\"event\":\"supervisor-arm\",\"arm\":$ARM"
  cd "$WT" || { say "\"event\":\"supervisor-done\",\"reason\":\"worktree-missing\",\"arms\":$ARM"; exit 1; }

  "$NODE_BIN" tools/chain/follow-chain.mjs \
    --url "$URL" --chain "$CHAIN" --label "$LABEL" \
    --snapshot "$WT/client/fixtures/chain/$CHAIN" \
    --runtime "$RUNTIME" \
    --avm "$AVM" --ct-writer "$CTW" --node "$NODE_BIN" \
    --interval "$INTERVAL_S" --deadline-min "$DEADLINE_MIN" --until 0 \
    --until-complete-blocks "$UNTIL_COMPLETE" \
    --log "$LOG" >> "$LOG.stderr" 2>&1
  rc=$?

  say "\"event\":\"supervisor-exit\",\"arm\":$ARM,\"rc\":$rc"

  # rc 2 is a preflight or configuration refusal. Re-arming cannot fix it, and a loop that
  # retried it would write the same refusal into the log until someone read it.
  if [ "$rc" -eq 2 ]; then
    say "\"event\":\"supervisor-done\",\"reason\":\"preflight-or-config-refusal\",\"arms\":$ARM,\"stillWatching\":false"
    exit 2
  fi

  # WITH A TARGET SET, rc 0 MEANS THE TARGET WAS MET. `--until-complete-blocks N` makes the
  # follower return 0 the moment the snapshot holds N complete blocks, so this is the
  # capture finishing, not an arm ending — and a capture-once run has a finish line by
  # design. Without a target (UNTIL_COMPLETE=0) rc 0 is just "this arm caught something",
  # which is NOT a reason to stop; that conflation is what ended the previous watch two
  # seconds after its only success.
  if [ "$UNTIL_COMPLETE" -gt 0 ] && [ "$rc" -eq 0 ]; then
    say "\"event\":\"supervisor-done\",\"reason\":\"capture-target-met\",\"arms\":$ARM,\"completeBlocksTarget\":$UNTIL_COMPLETE,\"stillWatching\":false"
    exit 0
  fi

  # Otherwise rc 0 and rc 1 both mean "that arm finished" — 0 that it caught something, 1
  # that it did not. NEITHER ends the watch. See the header.
  sleep 5
done
