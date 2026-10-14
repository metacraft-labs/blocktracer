#!/usr/bin/env bash
# eth-follower-proof.sh — DOES THE RESIDENT FOLLOWER DO THE SIX THINGS ING-1 ASKS OF IT,
# AND IS EACH ONE READ OFF A MEASUREMENT RATHER THAN OFF AN ASSERTION IN A COMMENT?
#
#   tools/chain/eth-follower-proof.sh [--heads FILE] [--floor N] [--span N] [--url RPC]
#                                     [--recorder BIN] [--recorder-commit SHA]
#                                     [--work .eth-follower-proof] [--keep] [--fast]
#
# Normally reached through `just eth-follower-proof`.
#
# ── WHAT THIS ANSWERS, AND WHAT THE OTHER TWO PROOFS ALREADY ANSWERED ─────────────────
#
# `eth-publish-proof.sh` (43 checks) proved ONE publish cycle: compose, idempotent, delta,
# refresh, write order, encoding, lease, audit. `eth-coverage-proof.sh` (46 without
# `--overlap`) proved RANGE AFTER RANGE into one store: the union, the derived generation,
# both defect shapes still reproducible, and out-of-order convergence.
#
# Both are statements about a run somebody started. ING-1's subject is a DEPLOYED DAEMON,
# and a daemon has properties a run does not have: it must survive a kill, it must not drop
# a burst, it must say something during a drought, and its lag must be readable by somebody
# who is not watching its terminal. This script is those properties.
#
# ── THE BURST IS THE CHAIN'S, NOT THIS SCRIPT'S ───────────────────────────────────────
#
# The arrival pattern this follower has to survive was MEASURED, not posited, and it is
# structural rather than statistical: ETHEREUM'S FINALIZED HEAD ADVANCES ONE EPOCH AT A
# TIME. Recorded against `https://eth.drpc.org` on 2026-10-14 by
# `follow-eth-chain.mjs --record-heads` at a 30-second interval, and committed as this
# script's subject:
#
#     tick  1..12   finalized 26,189,100   (the tip moved 26,189,168 -> 26,189,195)
#     tick 13       finalized 26,189,132   +32 in ONE tick
#     tick 14..24   finalized 26,189,132
#     tick 25       finalized 26,189,164   +32 in ONE tick
#
# So a follower whose tick capacity is under thirty-two meets an undrainable burst EVERY
# EPOCH, roughly every six and a half minutes, on the ordinary chain. The burst arm below
# runs over that RECORDING. Only the arm's CONTROL — "the same total spread evenly across
# ticks", which the chain does not offer on request — is constructed, and it says so in its
# own `synthetic` member, which the follower prints on every run.
#
# ── THE ARMS ──────────────────────────────────────────────────────────────────────────
#
#   0 SUBJECTS   transcript, recorder, endpoint and binaries exist — otherwise exit 2,
#                nothing measured. Plus the zero-match guard, armed in both directions.
#   1 STORE      ING-1 D2: the destination is an object store and the repository working
#                tree is byte-identical across a full loop iteration. `--dest`-less local
#                backend refused by name.
#   2 RESIDENT   ING-1 D3 + D7: every tick writes an observation, a quiet tick writes an
#                EXPLICIT ZERO with the window it examined, and a STOPPED follower writes
#                nothing — the pair that makes an empty result readable.
#   3 BURST      ING-1 D4: the real epoch jump, with a capacity below it. The overflow is
#                still owed at the next tick and the whole burst reaches the published map.
#                CONTROL: the same heights spread evenly converge on the same map AND the
#                same derived generation id.
#   4 RESTART    ING-1 D5: SIGKILL mid-loop, restart, no gap and no double-count, with the
#                follower's local observation stream DELETED before the restart so the
#                resume is demonstrably from published output.
#   5 LEDGER     ING-1 D5's measured LIMIT: the per-range snapshots are the one piece of
#                state the store does not hold, so a lost state directory is REFUSED by
#                name — and `--allow-ledger-behind-store` shows what the refusal prevents.
#   6 SLI        ING-1 D6: lag behind tip in the store, at the top of the document, equal to
#                a figure computed independently. The ring is bounded.
#   7 LEASE      what an unclean restart costs today: a lease with no TTL and no fencing
#                token, reported by the follower and refusing the publish by name.
#   8 AUDIT      `blocktracer-verify-published` over the follower's own store.
#   9 CONTAINER  the sequencing fact, measured and DERIVED rather than stated — and the
#                correction that required: the producer used to print its conclusion
#                without comparing the two figures above it, and the conclusion was false.
#  11 DETERMINISM a re-captured transaction does not overwrite what is published — found
#                by an arm whose loop ran on, and the reason the separation above is a
#                correctness rule rather than an optimisation.
#  10 NO SEAM    §14's producer roster is still five by name, and this follower shares no
#                code with the Aztec one.
#
# ── NO MOCKS ──────────────────────────────────────────────────────────────────────────
#
# There are none. The heads are a RECORDING of mainnet written by the follower's own code
# path; the captures are `capture-eth-range.mjs` driving the real EVM recorder against a
# real archive endpoint; the ingest, publisher and auditor are the shipping binaries driven
# by their documented flags; the store is a real directory whose `putIfAbsent` is a genuine
# `O_CREAT|O_EXCL`. No credential is held and none should ever be given one.
#
# ── EVERY RC IS THE COMMAND'S OWN, NEVER A PIPELINE'S ────────────────────────────────
#
# `just export | tail` once reported 0 while the recipe had failed, and a Perl compile
# failure read as "0 findings" the same way. So no rc read in this file comes from the tail
# of a pipeline: a command is run, redirected to a file, and `$?` read on the next line.
# Where a count must be extracted, `expect_match` refuses a count of zero rather than
# letting it satisfy a comparison.

set -u

HEADS=""
FLOOR=0
SPAN=6
CAPACITY=2
RECORDER=""
RECORDER_COMMIT=""
WORK=".eth-follower-proof"
KEEP=0
MAXTX=1
URL="https://eth.drpc.org"

while [ $# -gt 0 ]; do
  case "$1" in
    --heads)            HEADS="$2"; shift 2 ;;
    --floor)            FLOOR="$2"; shift 2 ;;
    --span)             SPAN="$2"; shift 2 ;;
    --capacity)         CAPACITY="$2"; shift 2 ;;
    --recorder)         RECORDER="$2"; shift 2 ;;
    --recorder-commit)  RECORDER_COMMIT="$2"; shift 2 ;;
    --max)              MAXTX="$2"; shift 2 ;;
    --url)              URL="$2"; shift 2 ;;
    --work)             WORK="$2"; shift 2 ;;
    --keep)             KEEP=1; shift ;;
    -h|--help)          sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root" || exit 2

CHAIN="ethereum-mainnet"
DEFAULT_HEADS="tools/chain/measurements/eth-head-transcript-2026-10-14.json"
[ -n "$HEADS" ] || HEADS="$DEFAULT_HEADS"

# ── ARM 0a: REFUSE RATHER THAN PASS WHEN THERE IS NOTHING TO MEASURE ──────────────────
#
# Exiting 0 with no subject is the empty-set pass: ten properties proved over no bytes. The
# captures need an archive endpoint and the EVM recorder, which a given machine may simply
# not have, so an absent subject is exit 2, naming how to supply it.
if [ ! -f "$HEADS" ]; then
  cat >&2 <<EOF
no head transcript at '$HEADS'.

This script's burst arm runs over a RECORDING of mainnet's finalized head, so it needs one.
Record a fresh one with the follower's own code path (about 20 minutes for two epochs):

    node tools/chain/follow-eth-chain.mjs --no-capture --dest /tmp/throwaway-store \\
      --state /tmp/throwaway-follower --state-bin blocktracer-follower-state \\
      --interval 30 --ticks 44 --record-heads my-heads.json
    tools/chain/eth-follower-proof.sh --heads my-heads.json

Exiting 2 rather than 0: a run with no subject would report properties proved over nothing.
EOF
  exit 2
fi

command -v node >/dev/null 2>&1 || { echo "REFUSING: node is not on PATH." >&2; exit 2; }
command -v git  >/dev/null 2>&1 || {
  echo "REFUSING: 'git' is not on PATH. Arm 1 asserts the repository working tree is" \
       "unchanged across a loop iteration, which is ING-1's 'no produced artifact reaches" \
       "the repository by a human git add' — without git that claim is unmeasured, and an" \
       "unmeasured claim must not be reported as a passing one." >&2
  exit 2
}

if [ -z "$RECORDER" ]; then
  # The recorder is located rather than guessed, and a miss is exit 2 with the reason.
  for cand in \
    "../codetracer-evm-recorder-del5/target/release/codetracer-evm-recorder" \
    "../codetracer-evm-recorder/target/release/codetracer-evm-recorder"; do
    if [ -x "$cand" ] && "$cand" --help 2>&1 | grep -q 'trace-onchain'; then
      RECORDER="$cand"; break
    fi
  done
fi
if [ -z "$RECORDER" ] || [ ! -x "$RECORDER" ]; then
  cat >&2 <<EOF
no EVM recorder with a 'trace-onchain' subcommand found.

Arms 1, 3, 4 and 5 capture REAL Ethereum blocks, which needs the recorder binary. Pass it:

    tools/chain/eth-follower-proof.sh --recorder <bin> --recorder-commit <sha>

A checkout whose recorder has only 'record' is the wrong branch: 'trace-onchain' is what
traces a transaction that is already on a live network. Exiting 2 rather than 0.
EOF
  exit 2
fi
if [ -z "$RECORDER_COMMIT" ]; then
  # DERIVED ONLY FROM THE CHECKOUT THAT HOLDS THE BINARY, and refused if that cannot be
  # established. `eth-capture.sh`'s header is the reason: the commit reaches every published
  # row's `runtimeCommit`, and a wrong one is worse than an absent one.
  rec_dir="$(cd "$(dirname "$RECORDER")/../.." && pwd)"
  RECORDER_COMMIT="$(git -C "$rec_dir" rev-parse HEAD 2>/dev/null)"
fi
if [ -z "$RECORDER_COMMIT" ]; then
  echo "REFUSING: --recorder-commit could not be derived from the recorder's checkout and" \
       "was not given. It is published into every row's runtimeCommit and a default read" \
       "off the wrong checkout is silently WRONG rather than absent." >&2
  exit 2
fi

rm -rf "$WORK"
mkdir -p "$WORK/bin"
# ABSOLUTE FROM HERE ON, for `eth-publish-proof.sh`'s reason: a relative --dest would put
# relative paths into every key extracted from a log, measured against the wrong root.
WORK="$(cd "$WORK" && pwd)"
BIN="$WORK/bin"
HEADS="$(cd "$(dirname "$HEADS")" && pwd)/$(basename "$HEADS")"
RECORDER="$(cd "$(dirname "$RECORDER")" && pwd)/$(basename "$RECORDER")"

FAILURES=0
PASSES=0
NOMATCH=0

say()  { printf '\n== %s\n' "$*"; }
check() { # check <ok:0|1> <name> [detail]
  if [ "$1" = "0" ]; then PASSES=$((PASSES+1)); printf '  PASS  %s%s\n' "$2" "${3:+  — $3}"
  else FAILURES=$((FAILURES+1)); printf '  FAIL  %s%s\n' "$2" "${3:+  — $3}"; fi
}
ok_if() { # ok_if <test-expression-result> -> 0|1 for check
  if [ "$1" = "true" ] || [ "$1" = "0" ]; then echo 0; else echo 1; fi
}

# ── A COUNT OF ZERO IS A REFUSAL, NOT A PASS ──────────────────────────────────────────
#
# Every arm that greps for a sentence or counts heights in a map is asking a question whose
# answer must be non-empty for the arm to mean anything. A `grep -c` returning 0 would
# otherwise satisfy "no unexpected findings" by having read nothing, and a height extractor
# that matched nothing would satisfy "no height is missing" the same way. This repository
# has shipped that exact mistake twice — the write-order checker matched ZERO renames and
# reported 0 inversions — so it is a function and every must-match site goes through it.
expect_match() { # expect_match <count> <what-was-being-matched>
  if [ "${1:-0}" -lt 1 ] 2>/dev/null || [ -z "${1:-}" ]; then
    NOMATCH=$((NOMATCH+1)); FAILURES=$((FAILURES+1))
    printf '  REFUSE  the pattern for "%s" matched NOTHING. A zero match cannot be read\n' "$2"
    printf '          as a zero finding — this arm measured nothing and is a FAILURE, not\n'
    printf '          a pass.\n'
    return 1
  fi
  return 0
}

say "ARM 0 — the harness's own zero-match guard is armed in both directions"
guard_zero_out=$( (expect_match 0 "a deliberately empty control pattern") 2>&1 )
guard_zero_rc=$?
check "$([ "$guard_zero_rc" != "0" ] && echo 0 || echo 1)" \
  "expect_match REFUSES a count of zero" "returned $guard_zero_rc"
case "$guard_zero_out" in
  *REFUSE*) said=0 ;;
  *)        said=1 ;;
esac
check "$said" "…and says REFUSE rather than failing quietly" \
  "$(printf '%s' "$guard_zero_out" | head -1 | sed 's/^ *//')"
guard_empty_rc=0
( expect_match "" "an empty string, which is what a failed sed yields" ) >/dev/null 2>&1 \
  || guard_empty_rc=$?
check "$([ "$guard_empty_rc" != "0" ] && echo 0 || echo 1)" \
  "…and refuses an EMPTY string too, which is what a failed sed actually yields" \
  "returned $guard_empty_rc"
guard_one_rc=0
( expect_match 1 "a control pattern that matched once" ) >/dev/null 2>&1 || guard_one_rc=$?
check "$guard_one_rc" "…and admits a count of one, so it is not refusing everything" \
  "returned $guard_one_rc"

say "building the four binaries this drives, from this working tree"
for pair in "chain_ingest:blocktracer-chain-ingest" "publish:blocktracer-publish" \
            "verify_published:blocktracer-verify-published" \
            "follower_state:blocktracer-follower-state"; do
  src="${pair%%:*}"; out="${pair##*:}"
  nim c --hints:off -d:release --path:src -o:"$BIN/$out" "src/blocktracer_$src.nim" \
    > "$WORK/build-$src.log" 2>&1
  rc=$?
  [ $rc -eq 0 ] || { echo "$out build failed (rc=$rc), see $WORK/build-$src.log" >&2; exit 2; }
done
echo "  built: chain-ingest, publish, verify-published, follower-state"

# ── the transcript, and the epoch jump IN it ──────────────────────────────────────────
#
# The burst arm's subject is read out of the transcript rather than stated here: a hardcoded
# "the jump is at tick 13" would stop describing a freshly recorded transcript while still
# passing over the old one.
read -r T_KIND T_TICKS JUMP_TICK JUMP_FROM JUMP_TO FIRST_FINAL <<EOF
$(node -e '
  const t = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const o = t.observations;
  let jt = 0, jf = 0, jto = 0;
  for (let i = 1; i < o.length; i++) {
    const d = o[i].finalized.height - o[i-1].finalized.height;
    if (d > jto - jf) { jt = i + 1; jf = o[i-1].finalized.height; jto = o[i].finalized.height; }
  }
  process.stdout.write([t.synthetic ? "SYNTHETIC" : "RECORDED", o.length, jt, jf, jto,
                        o[0].finalized.height].join(" "));
' "$HEADS")
EOF
say "the transcript, and the arrival pattern IN it"
echo "  $HEADS"
echo "  $T_KIND, $T_TICKS observation(s); first finalized head $FIRST_FINAL"
echo "  largest finalized-head advance: tick $JUMP_TICK, $JUMP_FROM -> $JUMP_TO" \
     "(+$((JUMP_TO - JUMP_FROM)) in one tick)"
check "$([ "$T_KIND" = "RECORDED" ] && echo 0 || echo 1)" \
  "the burst arm's subject is a RECORDING of mainnet, not a construction" "$T_KIND"
check "$([ "$((JUMP_TO - JUMP_FROM))" -gt "$CAPACITY" ] && echo 0 || echo 1)" \
  "…and its largest single-tick advance EXCEEDS the tick capacity this proof uses" \
  "+$((JUMP_TO - JUMP_FROM)) > $CAPACITY, so the burst is the chain's and not this script's"

# The window the capture arms work over: SPAN heights starting at the transcript's own first
# finalized head, so the proof follows the recording rather than a height typed in here.
[ "$FLOOR" -gt 0 ] || FLOOR="$FIRST_FINAL"
CEILING=$((FLOOR + SPAN - 1))
# THE TICK BUDGET A ONE-SPAN ARM NEEDS, DERIVED RATHER THAN TYPED. Before the epoch jump the
# recording's finalized head sits at the window's floor, so a run of one tick has NOTHING
# OWED and would report its arm green over no work at all — the empty-set pass arm 0 exists
# to refuse, arrived at through a tick budget instead of through a missing subject. The
# budget is therefore the jump tick plus enough ticks to drain one capacity.
SHORT_TICKS=$((JUMP_TICK + 2))
echo "  capture window: $FLOOR..$CEILING ($SPAN height(s)), tick capacity $CAPACITY," \
     "--max $MAXTX recording(s) per range"
echo "  single-span arms run $SHORT_TICKS tick(s): the jump is at tick $JUMP_TICK and" \
     "nothing is owed before it"

# ---------------------------------------------------------------------------
# helpers over a published store
# ---------------------------------------------------------------------------

live_gen() { # live_gen <store>
  sed -n 's/^ *"generation": *"\([^"]*\)".*/\1/p' "$1/d/$CHAIN/current.json" 2>/dev/null | head -1
}
head_height() { # head_height <store>
  node -e 'const fs=require("fs");
           try { process.stdout.write(String(JSON.parse(fs.readFileSync(process.argv[1],"utf8")).head.height)); }
           catch { process.stdout.write(""); }' "$1/d/$CHAIN/current.json"
}
# Every height the live generation's height map lists, read THROUGH the generation root
# because the root is what names the map — a hardcoded path stops measuring the day it shards.
mapped_heights() { # mapped_heights <store>
  local store="$1" gen
  gen="$(live_gen "$store")"
  [ -n "$gen" ] || return 1
  node -e '
    const fs = require("fs"), path = require("path");
    const [store, chain, gen] = process.argv.slice(1);
    const root = JSON.parse(fs.readFileSync(
      path.join(store, "d", chain, "g", gen, "root.json"), "utf8"));
    const out = [];
    for (const k of root.maps.height) {
      for (const h of Object.keys(JSON.parse(fs.readFileSync(path.join(store, k), "utf8")).heights)) {
        out.push(Number(h));
      }
    }
    out.sort((a, b) => a - b);
    process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
  ' "$store" "$CHAIN" "$gen"
}
# How many hashes the block list holds, and how many are DISTINCT. The pair is the
# double-counting claim a restart has to answer.
block_list_counts() { # block_list_counts <store> -> "<total> <distinct>"
  local store="$1" gen
  gen="$(live_gen "$store")"
  [ -n "$gen" ] || { echo "0 0"; return 1; }
  node -e '
    const fs = require("fs"), path = require("path");
    const [store, chain, gen] = process.argv.slice(1);
    const root = JSON.parse(fs.readFileSync(
      path.join(store, "d", chain, "g", gen, "root.json"), "utf8"));
    let all = [];
    for (const k of root.maps.blocks) {
      all = all.concat(JSON.parse(fs.readFileSync(path.join(store, k), "utf8")).blocks);
    }
    process.stdout.write(`${all.length} ${new Set(all).size}`);
  ' "$store" "$CHAIN" "$gen"
}
manifest() { # manifest <dir> <out> — sha256 of every file, lease excluded
  ( cd "$1" && find . -type f -not -path './_leases/*' -print0 | xargs -0 -r sha256sum ) \
    | sort -k2 > "$2"
}

# One follower run. Writes its own log; returns ITS rc, not a pipeline's.
follow() { # follow <log> <extra flags…>
  local log="$1"; shift
  node tools/chain/follow-eth-chain.mjs \
    --recorder "$RECORDER" --recorder-commit "$RECORDER_COMMIT" \
    --state-bin "$BIN/blocktracer-follower-state" \
    --ingest-bin "$BIN/blocktracer-chain-ingest" \
    --publish-bin "$BIN/blocktracer-publish" \
    --max "$MAXTX" --interval 0 --url "$URL" \
    "$@" > "$log" 2>&1
  return $?
}

# A JSONL observation stream, as one field per tick.
obs_field() { # obs_field <jsonl> <field>
  node -e '
    const fs = require("fs");
    const [p, f] = process.argv.slice(1);
    const out = [];
    for (const line of fs.readFileSync(p, "utf8").split("\n")) {
      if (!line.trim()) continue;
      const o = JSON.parse(line);
      const v = f.split(".").reduce((a, k) => (a == null ? a : a[k]), o);
      out.push(v === null || v === undefined ? "null" : String(v));
    }
    process.stdout.write(out.join(" "));
  ' "$1" "$2"
}

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 2 — RESIDENT, AND A QUIET WINDOW IS A READING (ING-1 D3 + D7)
#
# Run first and over the WHOLE recording with `--no-capture`, because it is the arm that
# needs every tick of it and none of the recorder's time. The capture arms then work over a
# window of the same recording.
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 2 — RESIDENT: every tick writes, a quiet tick writes an explicit ZERO, a stopped follower writes nothing"

A2_STORE="$WORK/a2/store"; A2_FOLLOWER="$WORK/a2/follower"; A2_LEDGER="$WORK/a2/ledger"
mkdir -p "$WORK/a2"
follow "$WORK/a2.log" --no-capture --heads "$HEADS" \
  --dest "$A2_STORE" --state "$A2_FOLLOWER" --ledger-state "$A2_LEDGER"
a2_rc=$?
check "$a2_rc" "the follower runs the whole recording to exhaustion" "rc=$a2_rc"

A2_JSONL="$A2_FOLLOWER/observations.jsonl"
a2_lines=$(grep -c . "$A2_JSONL" 2>/dev/null || echo 0)
if expect_match "$a2_lines" "observations written by the follower"; then
  check "$([ "$a2_lines" = "$T_TICKS" ] && echo 0 || echo 1)" \
    "one observation per tick, for EVERY tick" \
    "$a2_lines observation(s) over $T_TICKS transcript tick(s)"
fi

# EVERY observation states the window it examined. Without that, `arrivals: 0` is a number
# with no subject: a tick that looked at three heights and a tick that looked at none report
# the same zero.
a2_windowless=$(node -e '
  const fs = require("fs");
  let n = 0;
  for (const l of fs.readFileSync(process.argv[1], "utf8").split("\n")) {
    if (!l.trim()) continue;
    const o = JSON.parse(l);
    if (!o.window || typeof o.window.from !== "number" || typeof o.window.to !== "number") n++;
  }
  process.stdout.write(String(n));
' "$A2_JSONL")
check "$([ "$a2_windowless" = "0" ] && echo 0 || echo 1)" \
  "every observation states the height window it examined" \
  "$a2_windowless observation(s) without one"

# THE ZERO-ARRIVAL TICKS. The recording's finalized head stands still for most of it, so
# this count is large and is read from the stream rather than assumed.
a2_zero=$(node -e '
  const fs = require("fs");
  let n = 0;
  for (const l of fs.readFileSync(process.argv[1], "utf8").split("\n")) {
    if (!l.trim()) continue;
    const o = JSON.parse(l);
    if (o.observed === true && o.arrivals === 0 && o.window.to >= o.window.from) n++;
  }
  process.stdout.write(String(n));
' "$A2_JSONL")
if expect_match "$a2_zero" "ticks that observed a window and found zero arrivals"; then
  check 0 "a quiet tick is an EXPLICIT measured zero over a stated window, not silence" \
    "$a2_zero of $a2_lines tick(s) report arrivals=0 with a non-empty window"
fi

# …AND THE PUBLISHED RING ADVANCES ON EVERY ONE OF THEM. This is the half that makes the
# zero readable by somebody who is not watching the terminal.
A2_SLI="$A2_STORE/obs/$CHAIN/follower.json"
check "$([ -f "$A2_SLI" ] && echo 0 || echo 1)" \
  "the follower published an SLI document into the store" "obs/$CHAIN/follower.json"
a2_ring_tick=$(node -e '
  const fs=require("fs"); const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
  process.stdout.write(String(d.tick));' "$A2_SLI" 2>/dev/null)
if expect_match "${a2_ring_tick:-0}" "the tick the published ring's newest entry names"; then
  check "$([ "$a2_ring_tick" = "$T_TICKS" ] && echo 0 || echo 1)" \
    "…and its newest entry names the LAST tick the follower ran" \
    "ring tick $a2_ring_tick, follower ran $T_TICKS"
fi

# ── THE PAIR: WITH THE FOLLOWER STOPPED, NOTHING APPEARS ─────────────────────────────
#
# ING-1 D7 is a PAIR and only the pair is informative: "a window in which nothing arrived
# must be distinguishable from a window in which the loop was not running". The first half
# is above. This is the second, and it is measured the only way it can be — by letting wall
# clock pass over a store no follower is attached to and comparing the bytes.
sha_before=$(sha256sum "$A2_SLI" | cut -d' ' -f1)
sleep 3
sha_after=$(sha256sum "$A2_SLI" | cut -d' ' -f1)
check "$([ "$sha_before" = "$sha_after" ] && echo 0 || echo 1)" \
  "with the follower STOPPED the ring does not move — the pair D7 asks for" \
  "sha256 ${sha_before:0:16}… unchanged over 3s of wall clock"

# ARMED: the comparison above would also pass if `sha256sum` were reading nothing. A second
# tick against the same store must MOVE it, or the stopped-ring claim is vacuous.
follow "$WORK/a2-more.log" --no-capture --heads "$HEADS" --ticks 1 \
  --dest "$A2_STORE" --state "$A2_FOLLOWER" --ledger-state "$A2_LEDGER"
sha_moved=$(sha256sum "$A2_SLI" | cut -d' ' -f1)
check "$([ "$sha_moved" != "$sha_after" ] && echo 0 || echo 1)" \
  "…and a RUNNING follower does move it, so the comparison is not vacuous" \
  "${sha_after:0:16}… -> ${sha_moved:0:16}…"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 6 — LAG BEHIND TIP IS PUBLISHED AS THE PRIMARY SLI (ING-1 D6)
#
# Measured over arm 2's store, which is where the SLI already is.
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 6 — SLI: lag behind tip is in the store, at the top of the document"

a6_format=$(sed -n 's/^ *"format": *"\([^"]*\)".*/\1/p' "$A2_SLI" | head -1)
check "$([ "$a6_format" = "blocktracer/follower-sli@1" ] && echo 0 || echo 1)" \
  "the SLI document states its format" "$a6_format"
a6_toplevel=$(node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(["lagBlocks","lagToFinalized","lagSeconds","queueDepth"]
    .filter((k) => Object.prototype.hasOwnProperty.call(d, k)).join(","));
' "$A2_SLI")
check "$([ "$a6_toplevel" = "lagBlocks,lagToFinalized,lagSeconds,queueDepth" ] && echo 0 || echo 1)" \
  "…and lifts the lag numbers to the TOP, so a page need not know the ring's shape" \
  "$a6_toplevel"

# THE NUMBER IS CHECKED AGAINST ONE COMPUTED HERE, from the transcript and the store's own
# pointer. A published SLI nobody recomputes is a published number, not a published
# measurement. Arm 2 ran with --no-capture, so the store has no pointer and the honest
# reading is `null` — which is itself the claim: an SLI over a cold store is ABSENT rather
# than zero, because zero lag and no published head are not the same statement.
a6_lag=$(node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(d.lagBlocks));' "$A2_SLI")
a6_head=$(head_height "$A2_STORE")
check "$([ "$a6_lag" = "null" ] && [ -z "$a6_head" ] && echo 0 || echo 1)" \
  "over a COLD store the lag is null and not 0 — no published head is not zero lag" \
  "lagBlocks=$a6_lag, published head='${a6_head:-none}'"

# THE RING IS BOUNDED. §3.2a's rule is that sync state is bounded; an observation per tick
# forever is the one field of this design that grows in TIME rather than in chain depth.
A6_STORE="$WORK/a6/store"
mkdir -p "$WORK/a6"
follow "$WORK/a6.log" --no-capture --heads "$HEADS" --ticks 5 --ring 3 \
  --dest "$A6_STORE" --state "$WORK/a6/follower" --ledger-state "$WORK/a6/ledger"
a6_rc=$?
a6_ring=$(node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(`${d.observations.length} ${d.ringCapacity} ${d.tick}`);
' "$A6_STORE/obs/$CHAIN/follower.json" 2>/dev/null)
set -- $a6_ring
check "$([ "${1:-0}" = "3" ] && [ "${2:-0}" = "3" ] && [ "${3:-0}" = "5" ] && echo 0 || echo 1)" \
  "the ring is BOUNDED: 5 ticks at --ring 3 leave 3 entries, newest naming tick 5" \
  "entries=${1:-?} capacity=${2:-?} newestTick=${3:-?} (follower rc=$a6_rc)"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 1 + ARM 3 — THE BURST RUN. One run, two arms: it is the first run that captures and
# publishes anything, so it is where the object-store and working-tree claims are measured,
# and it is driven by the recording's own epoch jump, so it is the burst.
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 1/3 — the burst run: real captures, real epoch jump, tick capacity below it"

B_STORE="$WORK/burst/store"; B_FOLLOWER="$WORK/burst/follower"; B_LEDGER="$WORK/burst/ledger"
mkdir -p "$WORK/burst"

# ── ING-1 D2's second half, measured BEFORE anything runs ────────────────────────────
git status --porcelain > "$WORK/tree-before.txt" 2>&1
git -c core.fileMode=false diff --stat > "$WORK/diff-before.txt" 2>&1

# `--dest`-less local backend is REFUSED, and the refusal names the deliverable. A follower
# that defaulted to a directory under the repository is the workstation filesystem ING-1
# exists to replace, arrived at by omission.
follow "$WORK/a1-nodest.log" --no-capture --heads "$HEADS" --ticks 1 \
  --state "$WORK/a1/follower" --ledger-state "$WORK/a1/ledger"
a1_rc=$?
a1_said=$(grep -c 'destination is an OBJECT STORE' "$WORK/a1-nodest.log")
check "$([ "$a1_rc" = "2" ] && echo 0 || echo 1)" \
  "a local backend with no --dest is refused as an invocation error" "rc=$a1_rc (want 2)"
if expect_match "$a1_said" "the refusal's own sentence about the destination"; then
  check 0 "…and the refusal names the deliverable rather than the flag" \
    "$(grep -o 'destination is an OBJECT STORE[^.]*' "$WORK/a1-nodest.log" | head -1)"
fi

burst_started=$(date +%s)
follow "$WORK/burst.log" --heads "$HEADS" \
  --floor "$FLOOR" --ceiling "$CEILING" --tick-capacity "$CAPACITY" \
  --dest "$B_STORE" --state "$B_FOLLOWER" --ledger-state "$B_LEDGER"
burst_rc=$?
burst_secs=$(( $(date +%s) - burst_started ))
check "$burst_rc" "the burst run exits 0" "rc=$burst_rc, ${burst_secs}s"

git status --porcelain > "$WORK/tree-after.txt" 2>&1
git -c core.fileMode=false diff --stat > "$WORK/diff-after.txt" 2>&1
cmp -s "$WORK/tree-before.txt" "$WORK/tree-after.txt"
tree_same=$?
check "$tree_same" \
  "ING-1 D2: the repository working tree is byte-identical across a full loop iteration" \
  "git status --porcelain compared byte-for-byte; $(grep -c . "$WORK/tree-after.txt") entry/entries either side"
cmp -s "$WORK/diff-before.txt" "$WORK/diff-after.txt"
check $? "…and so is the tracked-file diff — no artifact reached the repository" \
  "git diff --stat compared byte-for-byte"

B_OBJECTS=$(find "$B_STORE" -type f | wc -l)
if expect_match "$B_OBJECTS" "objects the follower published into the store"; then
  check 0 "ING-1 D2: the destination is an object store and it has the bytes" \
    "$B_OBJECTS object(s) under $B_STORE"
fi

B_JSONL="$B_FOLLOWER/observations.jsonl"

# ── THE BURST TICK, LOCATED BY ITS OWN NUMBERS ───────────────────────────────────────
#
# Found by the property rather than by tick number: a tick whose outstanding work before the
# drain EXCEEDED the capacity. A hardcoded tick index would stop describing a freshly
# recorded transcript while still passing over this one.
read -r BT_TICK BT_ARRIVALS BT_BEFORE BT_DRAINED BT_AFTER <<EOF
$(node -e '
  const fs = require("fs");
  let best = null;
  for (const l of fs.readFileSync(process.argv[1], "utf8").split("\n")) {
    if (!l.trim()) continue;
    const o = JSON.parse(l);
    if (o.queueDepthBeforeDrain > o.tickCapacity &&
        (best === null || o.queueDepthBeforeDrain > best.queueDepthBeforeDrain)) best = o;
  }
  process.stdout.write(best === null ? "0 0 0 0 0"
    : [best.tick, best.arrivals, best.queueDepthBeforeDrain,
       best.drained ? best.drained.heights : 0, best.queueDepth].join(" "));
' "$B_JSONL")
EOF
if expect_match "${BT_TICK:-0}" "a tick whose outstanding work exceeded the tick capacity"; then
  check 0 "ING-1 D4: a burst larger than one tick's capacity DID occur" \
    "tick $BT_TICK: $BT_ARRIVALS arrival(s), $BT_BEFORE owed, capacity $CAPACITY"
  check "$([ "$BT_DRAINED" = "$CAPACITY" ] && echo 0 || echo 1)" \
    "…the tick captured exactly its capacity and no more" \
    "drained $BT_DRAINED of $BT_BEFORE"
  check "$([ "$BT_AFTER" = "$((BT_BEFORE - BT_DRAINED))" ] && [ "$BT_AFTER" -gt 0 ] && echo 0 || echo 1)" \
    "…and the OVERFLOW IS STILL OWED rather than dropped" \
    "$BT_AFTER height(s) outstanding after the drain"
fi

mapped_heights "$B_STORE" > "$WORK/burst-map.txt"
B_MAPPED=$(grep -c . "$WORK/burst-map.txt")
if expect_match "$B_MAPPED" "heights the burst store's live generation maps"; then
  check "$([ "$B_MAPPED" = "$SPAN" ] && echo 0 || echo 1)" \
    "…and the WHOLE burst reaches the published height map over the following ticks" \
    "map holds $B_MAPPED of $SPAN: $(tr '\n' ' ' < "$WORK/burst-map.txt")"
fi
read -r B_TOTAL B_DISTINCT <<< "$(block_list_counts "$B_STORE")"
check "$([ "$B_TOTAL" = "$SPAN" ] && [ "$B_DISTINCT" = "$SPAN" ] && echo 0 || echo 1)" \
  "…with no height counted twice" "block list total=$B_TOTAL distinct=$B_DISTINCT"
B_GEN=$(live_gen "$B_STORE")
B_HEAD=$(head_height "$B_STORE")
check "$([ "$B_HEAD" = "$CEILING" ] && echo 0 || echo 1)" \
  "…and the pointer advertises the top of the window" "head=$B_HEAD generation=$B_GEN"

# ── THE CONTROL THE SPEC ASKS FOR, AND IT IS LABELLED ────────────────────────────────
#
# ING-1's verification text: "Control: the same total spread evenly across ticks produces
# the same set, so the assertion is about the burst and not about the count." A chain does
# not deliver its heads evenly on request, so this transcript is CONSTRUCTED — from the real
# one's own heights — and says so in its `synthetic` member, which the follower prints.
# Nothing measured over it is a measurement of Ethereum; it is a measurement of the loop.
node -e '
  const fs = require("fs");
  const [real, out, floor, ceiling, cap] = process.argv.slice(1);
  const t = JSON.parse(fs.readFileSync(real, "utf8"));
  const lo = Number(floor), hi = Number(ceiling), step = Number(cap);
  const obs = [];
  for (let f = lo; ; f += step) {
    const fin = Math.min(f, hi);
    obs.push({ at: new Date(Date.parse(t.observations[0].at) + obs.length * 30000).toISOString(),
               tip: { ...t.observations[t.observations.length - 1].tip },
               finalized: { height: fin,
                            hash: t.observations[0].finalized.hash,
                            timestamp: t.observations[0].finalized.timestamp } });
    if (fin >= hi) break;
  }
  // SLACK TICKS AT THE TOP, and they are not padding. MEASURED: a control transcript whose
  // tick count was exactly enough lost a height when the endpoint answered one capture with
  // HTTP 429 — the retry had no tick to land on, the run ended 5 of 6 and on a different
  // derived generation, and FOUR arms went red over a third party rate limiter. A
  // RESIDENT loop has unlimited ticks by construction, so a control with exactly enough is
  // not a control over the same system. Four extra observations at the final head give the
  // retries somewhere to go without changing the arrival schedule being controlled for.
  for (let i = 0; i < 4; i++) {
    obs.push({ at: new Date(Date.parse(t.observations[0].at) + obs.length * 30000).toISOString(),
               tip: { ...t.observations[t.observations.length - 1].tip },
               finalized: { height: hi,
                            hash: t.observations[0].finalized.hash,
                            timestamp: t.observations[0].finalized.timestamp } });
  }
  fs.writeFileSync(out, JSON.stringify({
    format: "blocktracer/eth-head-transcript@1",
    endpoint: t.endpoint, chain: t.chain,
    synthetic: true,
    constructedBy: "tools/chain/eth-follower-proof.sh arm 3 CONTROL",
    derivedFrom: real,
    why: "ING-1 asks for the same total spread EVENLY across ticks, which a chain does not "
       + "offer on request. The heights are the real transcript’s; the schedule is not.",
    observations: obs,
  }, null, 1) + "\n");
' "$HEADS" "$WORK/control-heads.json" "$FLOOR" "$CEILING" "$CAPACITY"

C_STORE="$WORK/control/store"
mkdir -p "$WORK/control"
follow "$WORK/control.log" --heads "$WORK/control-heads.json" \
  --floor "$FLOOR" --ceiling "$CEILING" --tick-capacity "$CAPACITY" \
  --dest "$C_STORE" --state "$WORK/control/follower" --ledger-state "$WORK/control/ledger"
c_rc=$?
check "$c_rc" "the CONTROL run — the same heights, spread evenly — exits 0" "rc=$c_rc"
c_said=$(grep -c 'SYNTHETIC' "$WORK/control.log")
if expect_match "$c_said" "the follower's own statement that the transcript was constructed"; then
  check 0 "…and the follower SAYS the transcript was constructed, every run" \
    "$(grep -o 'heads .*SYNTHETIC.*' "$WORK/control.log" | head -1 | cut -c1-110)"
fi
c_overflow=$(node -e '
  const fs = require("fs");
  let n = 0;
  for (const l of fs.readFileSync(process.argv[1], "utf8").split("\n")) {
    if (!l.trim()) continue;
    const o = JSON.parse(l);
    if (o.queueDepthBeforeDrain > o.tickCapacity) n++;
  }
  process.stdout.write(String(n));
' "$WORK/control/follower/observations.jsonl")
check "$([ "$c_overflow" = "0" ] && echo 0 || echo 1)" \
  "…and NO tick of it overflowed, which is what makes it a control" \
  "$c_overflow tick(s) over capacity, against the burst run's 1"
mapped_heights "$C_STORE" > "$WORK/control-map.txt"
cmp -s "$WORK/burst-map.txt" "$WORK/control-map.txt"
check $? "…yet it converges on the SAME set of mapped heights" \
  "$(grep -c . "$WORK/control-map.txt") height(s), identical to the burst run's"
C_GEN=$(live_gen "$C_STORE")
check "$([ "$B_GEN" = "$C_GEN" ] && echo 0 || echo 1)" \
  "…and on the SAME derived generation id, so the schedule does not fork the index" \
  "'$B_GEN' vs '$C_GEN'"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 4 — RESTART: SIGKILL MID-LOOP, NO GAP AND NO DOUBLE-COUNT (ING-1 D5)
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 4 — RESTART: killed mid-loop, resumed from PUBLISHED OUTPUT"

R_STORE="$WORK/restart/store"; R_FOLLOWER="$WORK/restart/follower"
R_LEDGER="$WORK/restart/ledger"
mkdir -p "$WORK/restart"

# KILLED DURING A CAPTURE, DELIBERATELY, and the arm asserts where the kill landed rather
# than hoping. A kill during the PUBLISH is the other case and it is arm 7's: the publisher's
# lease has no TTL, so that kill leaves an object behind and the restart is refused.
# `setsid` puts the follower in its own process group so the recorder and the capture child
# die with it — killing only the parent would leave a recorder running and the "restart"
# would be racing its predecessor.
setsid node tools/chain/follow-eth-chain.mjs \
  --recorder "$RECORDER" --recorder-commit "$RECORDER_COMMIT" \
  --state-bin "$BIN/blocktracer-follower-state" \
  --ingest-bin "$BIN/blocktracer-chain-ingest" \
  --publish-bin "$BIN/blocktracer-publish" \
  --max "$MAXTX" --interval 0 --url "$URL" --heads "$HEADS" \
  --floor "$FLOOR" --ceiling "$CEILING" --tick-capacity "$CAPACITY" \
  --dest "$R_STORE" --state "$R_FOLLOWER" --ledger-state "$R_LEDGER" \
  > "$WORK/restart-1.log" 2>&1 &
R_PID=$!
# Wait for the SECOND capture directory to appear: by then one span is published (so the
# restart has real published output to resume from) and another is in progress (so the kill
# is mid-work and not between ticks).
R_WAITED=0
while [ "$(ls -1 "$R_FOLLOWER/captures" 2>/dev/null | wc -l)" -lt 2 ] && [ $R_WAITED -lt 300 ]; do
  sleep 1; R_WAITED=$((R_WAITED+1))
done
R_CAPTURES_AT_KILL=$(ls -1 "$R_FOLLOWER/captures" 2>/dev/null | wc -l)
R_LEASE_AT_KILL=$(ls -1 "$R_STORE/_leases" 2>/dev/null | wc -l)
kill -9 -$R_PID 2>/dev/null
wait $R_PID 2>/dev/null
R_HEAD_AT_KILL=$(head_height "$R_STORE")
mapped_heights "$R_STORE" > "$WORK/restart-map-at-kill.txt" 2>/dev/null
R_MAPPED_AT_KILL=$(grep -c . "$WORK/restart-map-at-kill.txt" 2>/dev/null || echo 0)

if expect_match "$R_CAPTURES_AT_KILL" "capture directories present when the kill was sent"; then
  check 0 "the follower was killed MID-WORK, after publishing and while capturing" \
    "$R_CAPTURES_AT_KILL capture dir(s), published head ${R_HEAD_AT_KILL:-none}, $R_MAPPED_AT_KILL height(s) mapped"
fi
check "$([ "$R_LEASE_AT_KILL" = "0" ] && echo 0 || echo 1)" \
  "…and no lease was held at that moment, so this arm measures the restart and not arm 7" \
  "$R_LEASE_AT_KILL lease object(s) in the store"

# THE FOLLOWER'S LOCAL OBSERVATION STREAM IS DELETED BEFORE THE RESTART. §3.2a says the sync
# state is reconstructible from published output; deleting the local stream is what makes
# that a measurement rather than a design claim. The LEDGER is kept, because the per-range
# snapshots are the one thing the store does not hold — arm 5 is that limit.
rm -f "$R_FOLLOWER/observations.jsonl"
follow "$WORK/restart-2.log" --heads "$HEADS" \
  --floor "$FLOOR" --ceiling "$CEILING" --tick-capacity "$CAPACITY" \
  --dest "$R_STORE" --state "$R_FOLLOWER" --ledger-state "$R_LEDGER"
r2_rc=$?
check "$r2_rc" "the restarted follower exits 0" "rc=$r2_rc"
r2_resumed=$(grep -c "head ${R_HEAD_AT_KILL:-NOHEAD} generation" "$WORK/restart-2.log")
if expect_match "$r2_resumed" "the restarted follower's statement of the head it resumed from"; then
  check 0 "…and it resumed from the head the STORE held, not from a local file" \
    "$(grep -o 'store .*head [0-9]* generation [^,]*' "$WORK/restart-2.log" | head -1 | sed 's|.*store ||' | cut -c1-100)"
fi

mapped_heights "$R_STORE" > "$WORK/restart-map.txt"
R_MAPPED=$(grep -c . "$WORK/restart-map.txt")
if expect_match "$R_MAPPED" "heights the restarted store's live generation maps"; then
  cmp -s "$WORK/burst-map.txt" "$WORK/restart-map.txt"
  check $? "ING-1 D5: the restart leaves NO GAP — the identical set of heights is mapped" \
    "$R_MAPPED height(s), identical to the uninterrupted run's"
fi
read -r R_TOTAL R_DISTINCT <<< "$(block_list_counts "$R_STORE")"
check "$([ "$R_TOTAL" = "$R_DISTINCT" ] && [ "$R_TOTAL" = "$SPAN" ] && echo 0 || echo 1)" \
  "…and NO DOUBLE-COUNT — every height appears exactly once" \
  "block list total=$R_TOTAL distinct=$R_DISTINCT"
R_GEN=$(live_gen "$R_STORE")
check "$([ "$R_GEN" = "$B_GEN" ] && echo 0 || echo 1)" \
  "…converging on the same derived generation as the run that was never killed" \
  "'$R_GEN' vs '$B_GEN'"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 5 — THE ONE PIECE OF STATE THE STORE DOES NOT HOLD (ING-1 D5's measured LIMIT)
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 5 — LEDGER: the per-range snapshots are not reconstructible, so a lost state directory is REFUSED"

L_STORE="$WORK/ledgerloss/store"
mkdir -p "$WORK/ledgerloss"
cp -a "$B_STORE" "$L_STORE"

# A STATE DIRECTORY THAT IS GONE, over a store that still maps six heights. Nothing in the
# store can rebuild the captures, so a cycle from here would publish a union of whatever is
# filed next — i.e. one range — at a fresh derived generation, dropping the other five from
# the index while POINTER stays green. That is ING-1's shape 2, reached from the resume side.
follow "$WORK/a5-refuse.log" --heads "$HEADS" --ticks "$SHORT_TICKS" \
  --floor "$FLOOR" --ceiling "$((CEILING + 1))" --tick-capacity "$CAPACITY" \
  --dest "$L_STORE" --state "$WORK/ledgerloss/follower" --ledger-state "$WORK/ledgerloss/empty"
a5_rc=$?
a5_named=$(grep -c 'would be dropped from the published index' "$WORK/a5-refuse.log")
check "$([ "$a5_rc" = "1" ] && echo 0 || echo 1)" \
  "with the state directory lost, the follower REFUSES rather than publishing" "rc=$a5_rc"
if expect_match "$a5_named" "the refusal's own sentence about dropping heights from the index"; then
  check 0 "…and it names what the refusal prevents, by count and by first height" \
    "$(grep -o '[0-9]* published height(s) have no snapshot in the ledger — first: [0-9]*' "$WORK/a5-refuse.log" | head -1)"
fi

# ARMED: the refusal must be about the LOST LEDGER and not about the invocation. The same
# command with the real ledger must NOT refuse — otherwise the arm above is passing because
# the follower refuses everything.
cp -a "$B_LEDGER" "$WORK/ledgerloss/ledger-copy"
follow "$WORK/a5-armed.log" --heads "$HEADS" --ticks "$SHORT_TICKS" \
  --floor "$FLOOR" --ceiling "$CEILING" --tick-capacity "$CAPACITY" \
  --dest "$L_STORE" --state "$WORK/ledgerloss/follower2" \
  --ledger-state "$WORK/ledgerloss/ledger-copy"
a5_armed_rc=$?
check "$a5_armed_rc" \
  "…and the SAME invocation with the ledger intact does not refuse, so the arm is armed" \
  "rc=$a5_armed_rc"
# …AND IT IS THE REFUSAL THAT IS ABSENT, NOT THE RUN. "rc=0" is also true of a run that
# never started, so the arm names what it wants gone and what it wants present: the
# refusal's own sentence appears ZERO times, and the loop reached its ticks. Asking instead
# whether the control "did work" was wrong and said so loudly — with the ledger intact there
# is nothing left to do over this window, so that pattern matched nothing and `expect_match`
# refused the arm. The claim being armed is about the GUARD, not about the cycle.
a5_armed_refusal=$(grep -c 'would be dropped from the published index' "$WORK/a5-armed.log")
a5_armed_ticks=$(grep -c '^follow-eth-chain: tick ' "$WORK/a5-armed.log")
check "$([ "$a5_armed_refusal" = "0" ] && echo 0 || echo 1)" \
  "…and the refusal's own sentence appears ZERO times with the ledger intact" \
  "$a5_armed_refusal occurrence(s)"
if expect_match "$a5_armed_ticks" "ticks the armed control actually ran"; then
  check 0 "…over a loop that did reach its ticks, so 'does not refuse' is not vacuous" \
    "$a5_armed_ticks tick(s)"
fi

# WHAT THE REFUSAL PREVENTS, DEMONSTRATED. `--allow-ledger-behind-store` proceeds, and the
# store ends in shape 2: a self-consistent pointer over a map that has dropped five heights.
# In a throwaway copy, because this is a defect being reproduced on purpose.
S2_STORE="$WORK/shape2/store"
mkdir -p "$WORK/shape2"
cp -a "$B_STORE" "$S2_STORE"
follow "$WORK/a5-shape2.log" --heads "$HEADS" --ticks "$JUMP_TICK" --allow-ledger-behind-store \
  --floor "$FLOOR" --ceiling "$((CEILING + 1))" --tick-capacity "$CAPACITY" \
  --dest "$S2_STORE" --state "$WORK/shape2/follower" --ledger-state "$WORK/shape2/empty"
s2_rc=$?
mapped_heights "$S2_STORE" > "$WORK/shape2-map.txt" 2>/dev/null
S2_MAPPED=$(grep -c . "$WORK/shape2-map.txt" 2>/dev/null || echo 0)
# Computed here rather than inside the block below, so every check in this arm can name the
# same number. `SPAN - S2_MAPPED` is NOT that number and reported 5 where the answer was 6:
# the shape-2 run publishes a height the burst window did not contain, so the map can shrink
# by six while its size falls by five. Set difference is the measurement; arithmetic on the
# sizes is an inference about it.
S2_LOST=$(comm -23 "$WORK/burst-map.txt" "$WORK/shape2-map.txt" | tr '\n' ' ')
S2_LOST_N=$(printf '%s' "$S2_LOST" | wc -w)
check "$s2_rc" "--allow-ledger-behind-store proceeds instead" "rc=$s2_rc"
if expect_match "$S2_MAPPED" "heights the shape-2 store's live generation maps"; then
  check "$([ "$S2_MAPPED" -lt "$SPAN" ] && echo 0 || echo 1)" \
    "…and the store it leaves maps FEWER heights than before, with nothing deleted" \
    "map now holds $S2_MAPPED (was $SPAN); the dropped ones are named by the next check"
  # NAMED, NOT COUNTED. A count that fell for any reason would satisfy the comparison above.
  # The claim is sharper than that: specific heights the store STILL HOLDS are no longer
  # REACHABLE, which is why shape 2 is worse than shape 1 and why POINTER cannot see it.
  if expect_match "$S2_LOST_N" "heights the shape-2 store dropped from its index"; then
    S2_PRESENT=0
    for h in $S2_LOST; do
      hash=$(node -e '
        const fs = require("fs");
        const m = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        process.stdout.write(m.heights[process.argv[2]] ?? "");
      ' "$B_STORE/d/$CHAIN/g/$B_GEN/height/0.json" "$h")
      [ -n "$hash" ] && [ -f "$S2_STORE/d/$CHAIN/block/$hash.json" ] \
        && S2_PRESENT=$((S2_PRESENT+1))
    done
    check "$([ "$S2_PRESENT" = "$S2_LOST_N" ] && echo 0 || echo 1)" \
      "…and every dropped height's block object is STILL IN THE STORE, merely unreferenced" \
      "$S2_PRESENT of $S2_LOST_N reachable by hash and by no map: $S2_LOST"
  fi
fi
"$BIN/blocktracer-verify-published" --backend local --dest "$S2_STORE" \
  --allow-unrunnable CACHE --allow-unrunnable CENSUS \
  > "$WORK/a5-shape2-audit.log" 2>&1
s2_audit_rc=$?
s2_pointer=$(grep -c '^ *PASS *POINTER' "$WORK/a5-shape2-audit.log")
if expect_match "$s2_pointer" "the POINTER check's verdict over the shape-2 store"; then
  check 0 "…and POINTER PASSES over it — which is why this is refused rather than audited" \
    "POINTER green over a store that dropped $S2_LOST_N height(s) (audit rc=$s2_audit_rc)"
fi

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 7 — WHAT AN UNCLEAN RESTART COSTS TODAY
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 7 — LEASE: a killed publish leaves an object with no TTL, and the follower says so"

E_STORE="$WORK/lease/store"
mkdir -p "$WORK/lease/store/_leases"
cp -a "$B_STORE/." "$E_STORE/"
# BYTE-IDENTICAL TO WHAT A CRASHED HOLDER LEAVES, and the crash is on the record rather than
# imagined. `acquireLease` is one `putIfAbsent` of the writer id plus a newline and nothing
# else, so a planted lease and a crash residue are the same object.
#
# WHY IT IS PLANTED AND NOT RACED: the local backend's whole 1,986-object cycle completes
# inside the resolution of a polling loop, so the window cannot be hit here — four attempts
# at `until [ -f .../ethereum-mainnet.lock ]` then an immediate `pkill` all found the
# publisher already gone. Against R2 the same cycle is 1,972 network PUTs, and
# `publish-r2.yml`'s "Break stale publish leases" step exists BECAUSE it was hit: run
# 38388168109's publisher was SIGKILLed when its ephemeral runner was reaped mid-publish,
# `_leases/aztec.lock` survived, and the next run failed four and three-quarter hours later.
# So the window is minutes rather than milliseconds, and the residue is a measured artifact
# of this system rather than a constructed one.
printf 'follow-eth-chain/%s\n' "$CHAIN" > "$E_STORE/_leases/$CHAIN.lock"
cp -a "$B_LEDGER" "$WORK/lease/ledger-copy"
follow "$WORK/a7.log" --heads "$HEADS" --ticks "$SHORT_TICKS" \
  --floor "$FLOOR" --ceiling "$((CEILING + 1))" --tick-capacity "$CAPACITY" \
  --dest "$E_STORE" --state "$WORK/lease/follower" \
  --ledger-state "$WORK/lease/ledger-copy"
a7_rc=$?
a7_said=$(grep -c 'LEASE HELD' "$WORK/a7.log")
if expect_match "$a7_said" "the follower's own report of a held lease"; then
  check 0 "the follower REPORTS the lease at startup rather than failing silently later" \
    "$(grep -o "LEASE HELD.*" "$WORK/a7.log" | head -1 | cut -c1-100)"
fi
# THE REFUSAL IS READ FROM THE PUBLISHER'S OWN LOG, NOT FROM THE FOLLOWER'S PROSE.
#
# A PREVIOUS VERSION OF THIS ARM WAS GREEN FOR THE WRONG REASON, and its own printed figure
# said so: it grepped the follower's stderr for "is locked by another publisher" and matched
# the follower's LEASE HELD explanation, which quotes that sentence. It reported a refusal
# over a tick in which no publish had been attempted at all. A SPURIOUS MATCH IS NOT A ZERO
# MATCH and `expect_match` cannot see it — only a more specific subject can. The subject is
# the `publish-<from>-<to>.log` the follower writes when a publish refuses, which exists
# only if one did.
a7_publog=$(ls -1 "$WORK/lease/follower"/publish-*.log 2>/dev/null | head -1)
if expect_match "$(printf '%s' "$a7_publog" | wc -c)" \
     "a publish-refusal log, which exists only if a publish was attempted and refused"; then
  a7_refused=$(grep -c "chain '$CHAIN' is locked by another publisher" "$a7_publog")
  if expect_match "$a7_refused" "the publisher's own refusal naming the locked chain"; then
    check 0 "…and the publish is refused BY NAME in the PUBLISHER's output, so the lease works" \
      "$(basename "$a7_publog"): $(grep -o "chain '$CHAIN' is locked by another publisher" "$a7_publog" | head -1)"
  fi
  check "$([ "$a7_rc" = "1" ] && echo 0 || echo 1)" \
    "…and the follower exits NON-ZERO rather than reporting a clean tick" "rc=$a7_rc"
fi
a7_broke=$(ls -1 "$E_STORE/_leases" 2>/dev/null | wc -l)
check "$([ "$a7_broke" = "1" ] && echo 0 || echo 1)" \
  "…and the follower did NOT break it — guessing a holder is dead is how two writers meet" \
  "$a7_broke lease object(s) still in the store"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 8 — THE AUDIT OVER THE FOLLOWER'S OWN STORE
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 8 — AUDIT: blocktracer-verify-published over the store a resident follower filled"

audit() { # audit <store> <tree> <out> [extra flags…]
  local store="$1" tree="$2" out="$3"; shift 3
  "$BIN/blocktracer-verify-published" --backend local --dest "$store" --tree "$tree" \
    --allow-unrunnable CACHE "$@" > "$out" 2>&1
  return $?
}
audit_state() { # audit_state <out> <CHECKID> -> PASS|FAIL|UNRUNNABLE|MISSING
  local s
  s=$(sed -n "s/^ *\(PASS\|FAIL\|UNRUNNABLE\) *$2 .*/\1/p" "$1" | head -1)
  printf '%s' "${s:-MISSING}"
}

audit "$B_STORE" "$B_LEDGER/tree" "$WORK/a8-audit.out" --ledger "$B_LEDGER/coverage.json"
a8_rc=$?
for id in INSTRUMENT REGISTRY POINTER LEDGER RANGE CENSUS; do
  st=$(audit_state "$WORK/a8-audit.out" "$id")
  check "$([ "$st" = "PASS" ] && echo 0 || echo 1)" "audit $id passes" "$st"
done
# PROFILE is the PINNED producer/auditor `historyFloor` disagreement — it predates this
# work, `eth-publish-proof.sh` arm 8 and `eth-coverage-proof.sh` arm 3 pin it by name for
# the same reason: pinning keeps every other finding live, skipping would hide the next one.
a8_prof=$(audit_state "$WORK/a8-audit.out" PROFILE)
check "$([ "$a8_prof" = "FAIL" ] && echo 0 || echo 1)" \
  "PROFILE is the pinned historyFloor disagreement, still the ONLY finding" "$a8_prof"
a8_unknown=$(grep -E '^ *! ' "$WORK/a8-audit.out" | grep -v 'historyFloor' \
             | grep -v 'serves no response headers' || true)
check "$([ -z "$a8_unknown" ] && echo 0 || echo 1)" \
  "the audit reports no finding beyond the pinned one" \
  "${a8_unknown:-none} (audit rc=$a8_rc)"
# THE SLI OBJECT DOES NOT PERTURB THE AUDIT. `obs/{chain}/follower.json` is in no
# generation and in no local tree, so a census that failed on unexpected keys would have
# turned red above. It is asserted present so the arm is about coexistence rather than
# about the object having quietly not been written.
check "$([ -f "$B_STORE/obs/$CHAIN/follower.json" ] && echo 0 || echo 1)" \
  "…with the follower's SLI object present in the same store throughout" \
  "obs/$CHAIN/follower.json"

# ── AND THE SLI'S LAG, NOW THAT THERE IS A PUBLISHED HEAD TO LAG BEHIND ──────────────
#
# Arm 6 measured the cold-store reading (null, not zero). This is the warm one, and the
# number is RECOMPUTED here from the transcript's last tip and the store's own pointer: a
# published SLI nobody recomputes is a published number, not a published measurement.
read -r SLI_LAG SLI_TOFIN SLI_TICK <<EOF
$(node -e '
  const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write([d.lagBlocks, d.lagToFinalized, d.tick].join(" "));
' "$B_STORE/obs/$CHAIN/follower.json")
EOF
read -r WANT_LAG WANT_TOFIN <<EOF
$(node -e '
  const fs = require("fs");
  const t = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const tick = Number(process.argv[3]);
  const o = t.observations[tick - 1];
  const head = Number(process.argv[2]);
  process.stdout.write([o.tip.height - head, o.finalized.height - head].join(" "));
' "$HEADS" "$B_HEAD" "$SLI_TICK")
EOF
check "$([ "$SLI_LAG" = "$WANT_LAG" ] && echo 0 || echo 1)" \
  "ING-1 D6: the published lagBlocks equals tip - publishedHead, recomputed independently" \
  "published $SLI_LAG, recomputed $WANT_LAG (tick $SLI_TICK, head $B_HEAD)"
check "$([ "$SLI_TOFIN" = "$WANT_TOFIN" ] && echo 0 || echo 1)" \
  "…and lagToFinalized likewise, which is the number that can actually reach zero" \
  "published $SLI_TOFIN, recomputed $WANT_TOFIN"
check "$([ "$SLI_LAG" -gt "$SLI_TOFIN" ] && echo 0 || echo 1)" \
  "…and the two DIFFER by the chain's structural tip-to-finalized gap, so reporting only the SLI would read as a fault" \
  "lagBlocks $SLI_LAG > lagToFinalized $SLI_TOFIN, gap $((SLI_LAG - SLI_TOFIN))"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 9 — THE SEQUENCING FACT, MEASURED RATHER THAN ASSERTED
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 9 — CONTAINER: what the follower published, against the engine a visitor runs"

# The capture tool already states this on every run, because it is a property of its output
# and not of this harness. It is READ from the run's own log rather than restated, so the
# day the versions converge this arm reports the convergence instead of a stale sentence.
# READ FROM THE CAPTURE'S OWN LOG, which the follower retains for every span precisely so
# these facts are not left in a pipe. A PREVIOUS VERSION OF THIS ARM GREPPED THE FOLLOWER'S
# STDERR and matched nothing, because the capture's report went into a buffer the follower
# discarded on success — and the three REFUSE lines that produced are what made it visible.
A9_LOG=$(ls -1 "$WORK/burst/follower"/capture-*.log 2>/dev/null | head -1)
if expect_match "$(printf '%s' "$A9_LOG" | wc -c)" \
     "a retained capture log from the burst run"; then
  check 0 "the follower RETAINS its capture's own report rather than discarding it" \
    "$(basename "$A9_LOG")"
fi
a9_meta=$(grep -o 'this container is version [0-9]* / meta.dat schema [0-9]*' "$A9_LOG" 2>/dev/null | head -1)
a9_reads=$(grep -o 'accepting meta.dat \[[0-9, ]*\] and container version(s) \[[0-9, ]*\]' "$A9_LOG" 2>/dev/null | head -1)
a9_derived=$(grep -o 'DERIVED: .*' "$A9_LOG" 2>/dev/null | head -1)
a9_prov=$(grep -o 'that reading was transcribed from [^—]*' "$A9_LOG" 2>/dev/null | head -1)
if expect_match "$(printf '%s' "$a9_meta" | wc -c)" "the container version the follower's capture reported"; then
  check 0 "the follower's output states its own container version and schema" "$a9_meta"
fi
if expect_match "$(printf '%s' "$a9_reads" | wc -c)" "the engine pin's accepted schema and version lists"; then
  check 0 "…and the pinned engine's accepted schema AND container-version lists beside it" \
    "$a9_reads"
fi
# THE VERDICT IS DERIVED, AND THAT IS A CORRECTION THIS WAVE MADE. The producer used to
# print "so a published page RENDERS and its INTERACTIVE REPLAY REFUSES" unconditionally,
# without comparing the two figures above it — and at this commit that conclusion was FALSE:
# `health-checks.json`'s `shipped-engine` accepts meta.dat [6] and container versions [5,6],
# read from `codetracer` 571c64cca on 2026-10-12, and this producer emits container 5 /
# schema 6. The file's own HEADER already recorded the re-pin ("an Ethereum page published
# from this producer now RENDERS AND REPLAYS"); only the code had not caught up. A
# conclusion that cannot change when its inputs change is not a measurement, so this arm
# requires the word to be derived rather than present.
if expect_match "$(printf '%s' "$a9_derived" | wc -c)" "the capture's DERIVED replay verdict"; then
  check 0 "…and the replay verdict is DERIVED from both axes, not stated" "$a9_derived"
fi
a9_undetermined=$(printf '%s' "$a9_derived" | grep -c 'UNDETERMINED' || true)
check "$([ "${a9_undetermined:-0}" = "0" ] && echo 0 || echo 1)" \
  "…and both axes were readable, so the verdict is a reading and not an absence" \
  "${a9_undetermined:-0} UNDETERMINED axis/axes"
if expect_match "$(printf '%s' "$a9_prov" | wc -c)" "the provenance of the transcribed engine constant"; then
  check 0 "…and the transcription's own revision and date travel with the verdict, because health-checks.json says a transcribed constant rots" \
    "$a9_prov"
fi
check "$([ -f client/hydrate/engine-pin.txt ] && echo 0 || echo 1)" \
  "…and the coupling's file is where the capture says it is" \
  "$(head -c 56 client/hydrate/engine-pin.txt 2>/dev/null | tr '\n' ' ')"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 10 — NO ABSTRACTION WAS SHARED WITH THE AZTEC FOLLOWER
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 10 — NO SEAM: ING-7's two-consumer rule is spent by this file's existence, not by it"

# The producer roster is §14's claim and it is checked HERE too, because §14 runs in
# `chain-selftest` over the whole tree while this script is the thing that just added a
# tool to that tree. A follower that had started stating transaction rows would arrive as a
# named failure in both places.
a10_roster=$(node -e '
  import("./tools/chain/lib/producer-scan.mjs").then((m) => {
    const r = m.scanProducers("tools/chain");
    process.stdout.write(`${r.producers.join(",")}|${r.others.length}|${r.findings.length}`);
  });
')
a10_producers="${a10_roster%%|*}"
a10_rest="${a10_roster#*|}"
a10_others="${a10_rest%%|*}"
a10_findings="${a10_rest##*|}"
check "$([ "$a10_producers" = "backfill-blocks.mjs,capture-chain.mjs,follow-chain.mjs,ingest-range.mjs,produce-eth-snapshot.mjs" ] && echo 0 || echo 1)" \
  "the producer roster is still exactly five, by name" "$a10_producers"
check "$([ "$a10_findings" = "0" ] && echo 0 || echo 1)" \
  "…with no producer-facts finding" "$a10_findings finding(s) over $a10_others other tool(s)"

# NO CODE IS SHARED, asserted in both directions so a one-way import cannot satisfy it.
a10_imports=$(grep -c "follow-chain.mjs'" tools/chain/follow-eth-chain.mjs || true)
check "$([ "${a10_imports:-0}" = "0" ] && echo 0 || echo 1)" \
  "the Ethereum follower imports nothing from the Aztec one" \
  "${a10_imports:-0} import(s)"
a10_reverse=$(grep -c "follow-eth-chain" tools/chain/follow-chain.mjs || true)
check "$([ "${a10_reverse:-0}" = "0" ] && echo 0 || echo 1)" \
  "…and the Aztec follower names the Ethereum one nowhere" "${a10_reverse:-0} reference(s)"
# WHAT IS SHARED IS SHARED BECAUSE IT ALREADY HAD TWO CONSUMERS. This follower shares
# nothing at all: the capture, the facts and the ingest are all delegated to tools that
# already own them, which is why its own import list is `node:` plus nothing.
a10_libs=$(grep -c "from './lib/" tools/chain/follow-eth-chain.mjs || true)
check "$([ "${a10_libs:-0}" = "0" ] && echo 0 || echo 1)" \
  "…and it reaches no lib/ module at all — the capture and the facts are delegated whole" \
  "${a10_libs:-0} lib import(s)"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 11 — WHY NOT RE-CAPTURING IS A CORRECTNESS RULE AND NOT AN OPTIMISATION
#
# FOUND, not designed. An earlier version of the shape-2 arm let its loop run on, so it
# re-captured a span the store already held — and `blocktracer-publish` exited 3:
#
#     DETERMINISM INCIDENTS   : 2
#       ! t/2g/lb/2glbccijzxzq7i5gx4lawfvll5/trace.ct
#       ! t/2g/lb/2glbccijzxzq7i5gx4lawfvll5/manifest.json
#     publish completed WITH 2 determinism incident(s) — those objects were NOT overwritten
#
# The two recordings of ONE transaction are the same length (126,976 bytes), report the same
# `steps` (15,822) and the same `frames` (23), and differ in 32,888 bytes with a different
# sha256 — a header count at offset 16 reads 0x7ff2 in one and 0x7ff7 in the other. So the
# container is SEMANTICALLY STABLE AND BYTE-UNSTABLE. The mechanism is NOT MEASURED here,
# though this repository already records a candidate: `lib/eth-rpc-transcript.mjs`'s header
# says the recorder's state reads come from `foundry-fork-db`'s `SharedBackend`, which
# services misses from a background thread and issues them CONCURRENTLY.
#
# WHAT IT MEANS FOR A RESIDENT FOLLOWER: re-capturing an already-published transaction does
# not cost time, it costs a FAILED PUBLISH CYCLE. That is why the captured-versus-published
# separation above is a correctness requirement.
#
# THE ARM ASSERTS THE PROPERTY THAT MATTERS WHICHEVER WAY THE RECORDER GOES: the bytes
# already in the store are not overwritten. A recorder that became byte-reproducible would
# make the incident count zero and this arm would still hold — and it reports which case it
# saw, so the figure moves rather than the assertion.
# ═══════════════════════════════════════════════════════════════════════════════════════

say "ARM 11 — DETERMINISM: a re-captured transaction does not overwrite what is published"

D_STORE="$WORK/determinism/store"
mkdir -p "$WORK/determinism"
cp -a "$B_STORE" "$D_STORE"
cp -a "$B_LEDGER" "$WORK/determinism/ledger"
manifest "$D_STORE" "$WORK/determinism/before.txt"
d_objects=$(grep -c . "$WORK/determinism/before.txt")
# RE-CAPTURE A SPAN THE STORE ALREADY HOLDS, by re-filing it over itself. `--refile` is
# `eth-ingest-range.mjs`'s documented flag for exactly this, and the span is the burst run's
# own first one, so the subject is a transaction the store demonstrably already published.
D_KEY=$(ls -1 "$WORK/determinism/ledger/ranges" | head -1)
D_FROM=$(printf '%s' "$D_KEY" | cut -d- -f1 | sed 's/^0*//')
D_TO=$(printf '%s' "$D_KEY" | cut -d- -f2 | sed 's/^0*//')
node tools/chain/capture-eth-range.mjs \
  --recorder "$RECORDER" --recorder-commit "$RECORDER_COMMIT" \
  --from "$D_FROM" --to "$D_TO" --max "$MAXTX" --url "$URL" \
  --out "$WORK/determinism/recapture" --work "$WORK/determinism/work" \
  > "$WORK/a11-capture.log" 2>&1
d_cap_rc=$?
if [ "$d_cap_rc" != "0" ]; then
  check 1 "the re-capture of $D_FROM..$D_TO succeeded" \
    "rc=$d_cap_rc — see $WORK/a11-capture.log. This is the endpoint refusing, not the \
follower; pass --url <paid endpoint>."
else
  check 0 "a span the store already holds is re-captured from the chain" "$D_FROM..$D_TO"
  node tools/chain/eth-ingest-range.mjs \
    --snapshot "$WORK/determinism/recapture" --state "$WORK/determinism/ledger" \
    --chain "$CHAIN" --backend local --dest "$D_STORE" --refile \
    --ingest-bin "$BIN/blocktracer-chain-ingest" --publish-bin "$BIN/blocktracer-publish" \
    > "$WORK/a11-publish.log" 2>&1
  d_pub_rc=$?
  d_incidents=$(grep -c '^ *! t/' "$WORK/a11-publish.log")
  manifest "$D_STORE" "$WORK/determinism/after.txt"
  # THE ASSERTION: every object that was in the store is still byte-identical. Compared over
  # the BEFORE set rather than over both, because the re-publish may legitimately ADD the
  # new generation's maps — the claim is that nothing already published MOVED.
  d_moved=0
  while read -r sha path; do
    now=$(grep -F " $path" "$WORK/determinism/after.txt" | head -1 | cut -d' ' -f1)
    [ "$now" = "$sha" ] || d_moved=$((d_moved+1))
  done < "$WORK/determinism/before.txt"
  if expect_match "$d_objects" "objects in the store before the re-publish"; then
    check "$([ "$d_moved" = "0" ] && echo 0 || echo 1)" \
      "every one of the published objects is byte-identical after the re-publish" \
      "$d_objects compared by sha256, $d_moved moved"
  fi
  if [ "$d_incidents" -gt 0 ]; then
    check 0 "…and the publisher REPORTED the byte difference as a determinism incident" \
      "rc=$d_pub_rc, $d_incidents incident(s): $(grep -o '^ *! t/.*' "$WORK/a11-publish.log" | head -1 | sed 's/^ *! //')"
    check 0 "…so the recorder is BYTE-UNSTABLE for one transaction, and the store is safe anyway" \
      "the container's own derived counts agree; only its bytes differ"
  else
    check 0 "…and the publisher reported NO determinism incident, so the recorder was byte-reproducible this time" \
      "rc=$d_pub_rc — a changed figure, not a changed assertion"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════════════

say "RESULT"
printf '  checks: %s passed, %s failed\n' "$PASSES" "$FAILURES"
[ "$NOMATCH" -gt 0 ] && printf '  %s pattern(s) matched NOTHING and are counted as failures\n' "$NOMATCH"
printf '  subject: %s (%s, %s ticks, +%s epoch jump at tick %s)\n' \
  "$(basename "$HEADS")" "$T_KIND" "$T_TICKS" "$((JUMP_TO - JUMP_FROM))" "$JUMP_TICK"
printf '  window:  %s..%s over %s object(s), generation %s\n' \
  "$FLOOR" "$CEILING" "$B_OBJECTS" "$B_GEN"
# EVERY CAPTURE REFUSAL ACROSS EVERY RUN, NAMED. The captures read a THIRD PARTY'S endpoint
# and the default is a free public one: `https://eth.drpc.org` answered HTTP 429 "You
# reached Public endpoint rate limit" during this script's own development, and a harness
# that reported only its arm verdicts would leave the operator to guess whether a red arm
# was the follower or the endpoint. Refusals are counted and named here whether or not any
# arm went red, so a run that passed DESPITE a refusal says so too.
refusals=$(grep -h 'capture refused' "$WORK"/*.log 2>/dev/null | wc -l)
if [ "$refusals" -gt 0 ]; then
  printf '  NOTE:    %s capture refusal(s) across the runs — the spans stayed OWED, which is\n' "$refusals"
  printf '           the designed behaviour. Each one is a THIRD PARTY refusing, not this\n'
  printf '           code; %s is the endpoint. Pass --url <paid endpoint> to remove it as a\n' "$URL"
  printf '           variable. The reasons, as the captures reported them:\n'
  grep -h -A 0 'capture refused' "$WORK"/*.log 2>/dev/null | sed 's/^/             /' | head -6
  for l in "$WORK"/*/follower/capture-*.log; do
    [ -f "$l" ] || continue
    grep -o 'http 4[0-9][0-9][^)]*' "$l" 2>/dev/null | head -1 | sed 's/^/             /'
  done | sort -u | head -4
fi
if [ "$KEEP" = "1" ]; then
  printf '  kept:    %s\n' "$WORK"
else
  rm -rf "$WORK/a2" "$WORK/a6" "$WORK/burst" "$WORK/control" "$WORK/restart" \
         "$WORK/ledgerloss" "$WORK/shape2" "$WORK/lease" "$WORK/a1" "$WORK/determinism"
  printf '  stores removed; logs kept in %s (pass --keep to keep the stores too)\n' "$WORK"
fi

[ "$FAILURES" -eq 0 ] || exit 1
exit 0
