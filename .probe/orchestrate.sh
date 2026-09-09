#!/usr/bin/env bash
# Wait out the penalty box, re-measure what the endpoint will actually sustain,
# then back-fill genesis-to-tip at half that rate.
#
# Everything here is deliberately timid. The endpoint is shared and public, it
# has already refused us for half an hour, and a backfill that gets us banned
# harder is worth less than one that takes longer.
set -uo pipefail
cd "$(dirname "$0")/.."
exec > >(tee -a .probe/orchestrate.log) 2>&1
echo "=== orchestrator start $(date -u +%FT%TZ) ==="

# ── 1. wait for the endpoint to answer, WITHOUT asking it constantly ────────
#
# Polling is not free here. The limiter's own `Retry-After` receded by only
# ~180s over ~19 minutes of wall time while two loops probed every 45-120s,
# which is the signature of a sliding window that every probe re-arms. So:
# sleep out the penalty the endpoint last quoted, in silence, and only then
# ask — and ask at ten-minute intervals, not one.
SILENT=${SILENT_WAIT:-2700}
echo "sleeping ${SILENT}s in silence before touching the endpoint at all"
sleep "$SILENT"
waited=$SILENT
while :; do
  if curl -s -m 20 -X POST https://aztec-testnet.drpc.org \
       -H 'content-type: application/json' \
       -d '{"jsonrpc":"2.0","id":1,"method":"node_getBlockNumber","params":[]}' \
     | grep -F '"result"' > /dev/null; then
    echo "RECOVERED after ${waited}s of waiting ($(date -u +%FT%TZ))"
    break
  fi
  echo "still limited at t+${waited}s; sleeping 600s without asking again"
  sleep 600; waited=$(( waited + 600 ))
  if [ "$waited" -ge 21600 ]; then echo "GAVE UP after 6h still 429"; exit 1; fi
done

# ── 2. re-measure the sustainable rate, gently ──────────────────────────────
echo "--- rate ramp ---"
node .probe/ramp.mjs
RPS=$(cat .probe/chosen-rps 2>/dev/null || echo 2)
echo "chosen rps: $RPS"

# ── 3. the prestate depth probe: cheap, and it decides Part 2 ───────────────
echo "--- prestate depth ---"
node .probe/prestate.mjs || echo "(prestate probe did not complete)"

# ── 4. genesis to tip ───────────────────────────────────────────────────────
TIP=$(curl -s -m 20 -X POST https://aztec-testnet.drpc.org -H 'content-type: application/json' \
      -d '{"jsonrpc":"2.0","id":1,"method":"node_getBlockNumber","params":[]}' \
      | sed 's/.*"result"://; s/}.*//')
echo "tip at backfill start: $TIP"

# ── 3b. is the 50-to-a-request header path IDENTICAL to the proven one? ─────
#
# The batched path is a 50x cut in the thing the endpoint rations, which is the
# difference between a backfill measured in hours and one measured in most of a
# day. It is also unproven. `contentDigest` in the ledger is a sha over the
# range's blocks and transactions ONLY — no timestamps — so fetching one range
# both ways and comparing digests is a real equivalence test, not a smoke test.
echo "--- batch-header equivalence check on 74000..74199 ---"
DIGEST_OF () { node -e '
 const l=require("fs").readFileSync(process.argv[1],"utf8");
 const j=JSON.parse(l); const r=j.ranges[process.argv[2]];
 console.log(r ? r.contentDigest : "MISSING");' "$1" "$2" 2>/dev/null; }
rm -rf .probe/eq-a .probe/eq-b
node tools/chain/ingest-range.mjs --from 74000 --to 74199 --state .probe/eq-a \
  --no-publish --no-merge --rps "$RPS" \
  --ingest-bin ./blocktracer-chain-ingest --publish-bin ./blocktracer-publish >/dev/null 2>&1
rcA=$?
node tools/chain/ingest-range.mjs --from 74000 --to 74199 --state .probe/eq-b \
  --no-publish --no-merge --rps "$RPS" --batch-headers 50 \
  --ingest-bin ./blocktracer-chain-ingest --publish-bin ./blocktracer-publish >/dev/null 2>&1
rcB=$?
A=$(DIGEST_OF .probe/eq-a/coverage.json 000074000-000074199)
B=$(DIGEST_OF .probe/eq-b/coverage.json 000074000-000074199)
echo "  one-at-a-time rc=$rcA digest=$A"
echo "  batched-by-50  rc=$rcB digest=$B"
BATCH_ARGS=""
if [ "$rcA" -eq 0 ] && [ "$rcB" -eq 0 ] && [ -n "$A" ] && [ "$A" = "$B" ]; then
  echo "  EQUIVALENT — backfilling with --batch-headers 50"
  BATCH_ARGS="--batch-headers 50"
else
  echo "  NOT PROVEN EQUIVALENT — backfilling on the one-at-a-time path"
fi

echo "--- backfill 0..$TIP ---"
.probe/backfill.sh 0 "$TIP" 500 "$RPS" "$BATCH_ARGS"
echo "=== orchestrator done $(date -u +%FT%TZ) ==="
