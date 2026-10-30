#!/usr/bin/env bash
# Regenerate the original Noir fixture population through its pinned producer.
# Source programs and prover inputs are committed; containers remain ignored.
set -euo pipefail
if [ "$#" -ne 0 ]; then
  echo "usage: fixtures/trace/tour/record.sh (records the complete pinned Noir fixture population)" >&2
  exit 2
fi
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
exec node "$repo/tools/fixtures/prepare-recordings.mjs" --producer noir --force
