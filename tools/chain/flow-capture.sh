#!/usr/bin/env bash
# flow-capture.sh — one Flow mainnet block, from its committed transcripts to a §5 tree.
#
#   bash tools/chain/flow-capture.sh --recorder <codetracer-flow-recorder> \
#     --helper <cadence-replay-helper> --recorder-commit <sha> \
#     --inputs fixtures/chain-inputs/flow-mainnet/<height> --out <tree> [--work <dir>] \
#     [--only <tx id>]...
#
# The inputs directory holds `block.json` (the helper's `block` listing),
# `floor-probe.json` (its `probe-floor` reading) and one transcript directory per user
# transaction (`--record-inputs`) — or, with `--only`, for the transactions it names.
# A transcript carries the registers its preceding transactions read, because the
# prestate strategy replays them, so one transaction is captured without its
# neighbours' transcripts and the producer publishes those as `not-attempted` rows.
# Without `--only` a missing transcript is refused, so a fixture cannot shrink
# silently. Each transaction is replayed with `--inputs`, so no
# network is used, in a capture directory of its own and with a relative output
# directory, so the container interns `./sources/<location>.cdc` and no path of the
# machine that ran it. Then tools/chain/produce-flow-snapshot.mjs assembles the tree.
set -euo pipefail

recorder=""
helper=""
recorder_commit=""
inputs=""
out=""
work=".flow-capture"
only=()
while [ $# -gt 0 ]; do
  case "$1" in
    --recorder) recorder="$2"; shift 2 ;;
    --helper) helper="$2"; shift 2 ;;
    --recorder-commit) recorder_commit="$2"; shift 2 ;;
    --inputs) inputs="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --only) only+=("$2"); shift 2 ;;
    *) printf 'flow-capture: unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done
fail() { printf 'flow-capture: %s\n' "$1" >&2; exit 2; }
[ -x "$recorder" ] || fail '--recorder <path to codetracer-flow-recorder> is required'
[ -x "$helper" ] || fail '--helper <path to cadence-replay-helper> is required'
[ -n "$recorder_commit" ] || fail '--recorder-commit <sha> is required'
[ -f "$inputs/block.json" ] || fail "no block listing at $inputs/block.json"
[ -f "$inputs/floor-probe.json" ] || fail "no floor probe at $inputs/floor-probe.json"
[ -n "$out" ] || fail '--out <snapshot dir> is required'

abs() { (cd "$1" && pwd); }
inputs_abs=$(abs "$inputs")
recorder_abs=$(cd "$(dirname "$recorder")" && pwd)/$(basename "$recorder")
helper_abs=$(cd "$(dirname "$helper")" && pwd)/$(basename "$helper")
rm -rf "${work:?}"
mkdir -p "$work"
work_abs=$(abs "$work")

capture_args=()
txs=$(node -e '
  const b = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const only = process.argv.slice(2);
  const user = b.transactions.filter((t) => !t.system).map((t) => t.id);
  for (const id of only) {
    if (!user.includes(id)) {
      console.error(`flow-capture: --only ${id} is not a user transaction of the block`);
      process.exit(2);
    }
  }
  for (const id of user) if (only.length === 0 || only.includes(id)) console.log(id);
' "$inputs/block.json" ${only[@]+"${only[@]}"}) || exit 2
for tx in $txs; do
  [ -d "$inputs_abs/$tx" ] || fail "no transcript for $tx under $inputs"
  capture="$work_abs/$tx"
  mkdir -p "$capture"
  printf '── record: %s replay --inputs %s\n' "$(basename "$recorder")" "$tx" >&2
  (cd "$capture" && CADENCE_REPLAY_HELPER_BIN="$helper_abs" "$recorder_abs" replay \
    --tx-hash "$tx" --inputs "$inputs_abs/$tx" --recording-id derive -o .)
  capture_args+=(--capture "$capture")
done

printf '── produce: tools/chain/produce-flow-snapshot.mjs -> %s\n' "$out" >&2
node tools/chain/produce-flow-snapshot.mjs \
  --block "$inputs/block.json" \
  --floor-probe "$inputs/floor-probe.json" \
  --inputs "$inputs" \
  "${capture_args[@]}" \
  --recorder-commit "$recorder_commit" \
  --out "$out"
