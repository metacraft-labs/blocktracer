#!/usr/bin/env bash
# starknet-capture.sh — the Starknet mainnet capture, as ONE command: one block recorded
# in StarkWare's own executor from a committed RPC transcript, then turned into a §5
# snapshot tree. No network is used or needed.
#
#   tools/chain/starknet-capture.sh --recorder <codetracer-cairo-onchain> \
#     --recorder-commit <sha> --transcript <dir> --out <snapshot-dir> \
#     [--work <dir>] [--ct-print <path>]
#
# THE TRANSCRIPT IS THE WHOLE INPUT SET. `codetracer-cairo-onchain trace-block
# --transcript-out` writes every RPC answer a run used — the block, its receipts and
# traces, the parent-block state the prefetch returned, every class, the floor probe —
# and `--transcript-in` serves exactly those back and refuses any request it does not
# hold. The producer then reads only the capture directory. So this run's inputs are the
# transcript and the two binaries, and nothing else.
#
# THE TREE IS BYTE-REPRODUCIBLE, which is what `packages.produced-captures` requires (F4
# holds a published container to the one the build produced): the recorder derives the
# container's recording id from the block and the transaction and interns listings
# relative to the capture directory, and this script hands the producer the TRANSCRIPT'S
# own recording time and endpoint, rather than the clock and the loopback this run used.
#
# Exit status: the first failing program's.

set -euo pipefail

transcripts=(); recorder=""; commit=""; transcript=""; out=""; work=".starknet-capture/capture"; ctprint=""; sources=""
while [ $# -gt 0 ]; do
  case "$1" in
    --recorder) recorder="$2"; shift 2 ;;
    --recorder-commit) commit="$2"; shift 2 ;;
    # Repeatable: one committed transcript per block. The FIRST is the one the floor
    # probe runs on (one capture of a run must carry it). `DIR@0xTX` records only that
    # transaction of the block; the block is still replayed whole, and the others are
    # published as replayed and not recorded.
    --transcript) transcripts+=("$2"); transcript="${transcripts[0]}"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --ct-print) ctprint="$2"; shift 2 ;;
    --class-sources) sources="$2"; shift 2 ;;
    *) echo "starknet-capture.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done
for v in recorder commit transcript out; do
  if [ -z "${!v}" ]; then echo "starknet-capture.sh: --${v/commit/recorder-commit} is required" >&2; exit 2; fi
done

# Per transcript: the block, the recording time and the endpoint, read out of the
# transcript itself. The tree is stamped with the NEWEST recording time, and every
# transcript must name the same endpoint — one tree is one source's reading.
rm -rf "$work" "$out"
mkdir -p "$work"
captures=(); recorded_at=""; endpoint=""; i=0
for spec in "${transcripts[@]}"; do
  tr="${spec%@*}"; only=""
  [ "$tr" != "$spec" ] && only="${spec##*@}"
  read -r block at ep < <(node -e '
    const t = JSON.parse(require("fs").readFileSync(process.argv[1] + "/index.json", "utf8"));
    const k = Object.keys(t.answers).find((x) => x.startsWith("starknet_getBlockWithReceipts "));
    if (!k) { console.error("the transcript holds no starknet_getBlockWithReceipts answer"); process.exit(1); }
    const block = JSON.parse(k.slice(k.indexOf(" ") + 1))[0].block_number;
    if (!t.recordedAtUnix) { console.error("the transcript states no recordedAtUnix"); process.exit(1); }
    console.log(block, new Date(t.recordedAtUnix * 1000).toISOString(), t.endpoint);
  ' "$tr")
  if [ -n "$endpoint" ] && [ "$ep" != "$endpoint" ]; then
    echo "starknet-capture.sh: $tr was recorded from $ep, the others from $endpoint" >&2; exit 2
  fi
  endpoint="$ep"
  if [[ -z "$recorded_at" || "$at" > "$recorded_at" ]]; then recorded_at="$at"; fi
  # `--class-sources`: `bind-class` bindings of class builds proved against the chain. The
  # recorder re-checks each against the class that ran before it uses one, and the
  # report says which were applied and which refused.
  "$recorder" trace-block "$block" --transcript-in "$tr" -o "$work/b$block" \
    $([ "$i" -eq 0 ] && echo --probe-floor) ${sources:+--class-sources "$sources"} \
    ${only:+--tx "$only"}
  captures+=(--capture "$work/b$block"); i=$((i + 1))
done
node tools/chain/produce-starknet-snapshot.mjs "${captures[@]}" \
  --recorder-commit "$commit" --out "$out" \
  --captured-at "$recorded_at" --endpoint-label "$endpoint" \
  ${ctprint:+--ct-print "$ctprint"}
