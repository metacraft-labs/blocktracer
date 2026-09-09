#!/usr/bin/env bash
# Probe once a minute until the endpoint serves again; record the recovery time.
start=$(date +%s)
for i in $(seq 1 60); do
  body=$(curl -s -m 20 -X POST https://aztec-testnet.drpc.org -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"node_getBlockNumber","params":[]}')
  now=$(date +%s); el=$(( now - start ))
  if printf '%s' "$body" | grep -F '"result"' > /dev/null; then
    echo "RECOVERED after ${el}s of probing: $body"; exit 0
  fi
  echo "t+${el}s still limited: $(printf '%s' "$body" | head -c 120)"
  sleep 60
done
echo "NOT RECOVERED after 60 minutes"
