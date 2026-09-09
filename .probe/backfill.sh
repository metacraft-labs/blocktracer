#!/usr/bin/env bash
# Genesis-to-tip backfill, chunked so a failure costs one chunk.
#
#   .probe/backfill.sh FROM TO CHUNK RPS
#
# Each chunk is its own `ingest-range` run with `--no-publish --no-merge`, so
# the ledger records it the moment it is fetched and a re-run of the whole
# script skips everything already covered. Exit 3 from a chunk means the
# endpoint throttled us and NOTHING was written for that range — the chunk is
# retried with a longer pause, and the ledger stays honest either way.
set -uo pipefail
FROM=${1:?from}; TO=${2:?to}; CHUNK=${3:-1000}; RPS=${4:-8}; EXTRA=${5:-}
cd "$(dirname "$0")/.."
LOG=.probe/backfill.log
: > "$LOG"
ok=0; failed=0; skipped=0
start=$(date +%s)
n=$FROM
while [ "$n" -le "$TO" ]; do
  end=$(( n + CHUNK - 1 )); [ "$end" -gt "$TO" ] && end=$TO
  attempt=0
  while :; do
    attempt=$(( attempt + 1 ))
    t0=$(date +%s)
    # shellcheck disable=SC2086  # EXTRA is deliberately word-split (may be empty)
    node tools/chain/ingest-range.mjs --from "$n" --to "$end" \
      --ingest-bin ./blocktracer-chain-ingest --publish-bin ./blocktracer-publish \
      --no-publish --no-merge --rps "$RPS" $EXTRA >> "$LOG" 2>&1
    rc=$?
    t1=$(date +%s)
    if [ "$rc" -eq 0 ]; then
      ok=$(( ok + 1 ))
      echo "CHUNK $n-$end ok in $(( t1 - t0 ))s (attempt $attempt)"
      break
    elif [ "$rc" -eq 3 ]; then
      if [ "$attempt" -ge 6 ]; then
        failed=$(( failed + 1 ))
        echo "CHUNK $n-$end THROTTLED OUT after $attempt attempts — left uncovered"
        break
      fi
      # The endpoint states its own penalty in `Retry-After`; ask it rather than
      # guessing, and add a small margin. Falls back to a ramp if absent.
      back=$(curl -s -m 20 -D - -o /dev/null -X POST https://aztec-testnet.drpc.org \
               -H 'content-type: application/json' \
               -d '{"jsonrpc":"2.0","id":1,"method":"node_getBlockNumber","params":[]}' \
             2>/dev/null | tr -d '\r' | awk 'tolower($1)=="retry-after:"{print $2}')
      case "$back" in ''|*[!0-9]*) back=$(( attempt * 120 )) ;; *) back=$(( back + 15 )) ;; esac
      [ "$back" -gt 3600 ] && back=3600
      echo "CHUNK $n-$end throttled (attempt $attempt), sleeping ${back}s"
      sleep "$back"
    else
      failed=$(( failed + 1 ))
      echo "CHUNK $n-$end FAILED rc=$rc — see $LOG"
      break
    fi
  done
  n=$(( end + 1 ))
done
echo "DONE chunks_ok=$ok failed=$failed elapsed=$(( $(date +%s) - start ))s"
