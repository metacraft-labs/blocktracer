#!/usr/bin/env bash
# eth-capture.sh — the Ethereum mainnet capture, as ONE command, so that the ONLINE run
# and the OFFLINE run are the same run with a different endpoint.
#
#   tools/chain/eth-capture.sh [--rpc <url>] --recorder <bin> --recorder-commit <sha> \
#     --tx <hash> --out <snapshot-dir> [--work <dir>] [--transcript <dir>] [--source-fetch]
#
# Normally reached through `just eth-inputs-record` (online, writes the committed input
# set) or `just eth-capture` (offline, reads it). Both run it under
# `tools/chain/eth-rpc-transcript.mjs`, which puts its own loopback URL in the child's
# environment; neither contacts a chain directly.
#
# ── WHY THE TWO HALVES ARE IN ONE SCRIPT ──────────────────────────────────────────────
#
# The capture is two programs — `codetracer-evm-recorder trace-onchain` writes the
# container, `tools/chain/produce-eth-snapshot.mjs` turns it into a snapshot tree — and
# BOTH read the same JSON-RPC endpoint. A transcript is only the whole input set if it was
# recorded over the whole conversation, so the recording pass has to span both. Putting the
# sequence in a script means the online and offline passes cannot drift apart: there is one
# definition of what the capture does and the mode is an argument to it.
#
# ── WHY THE WORK DIRECTORY IS RELATIVE AND FIXED ──────────────────────────────────────
#
# The recorder interns the path of the disassembly listing it materialises, and that path
# is `<--out-dir>/sources/<address>/<address>.evmasm` verbatim — relative if `--out-dir`
# was relative. The interned path is IN THE CONTAINER, so the container's bytes depend on
# the string. An absolute `--out-dir` therefore makes the container host-specific: two
# machines with different checkout paths produce different bytes for the same transaction.
# A repo-relative default (`.eth-capture/`, gitignored) makes it host-independent, which is
# what lets the offline run be COMPARED to the online one at all.
#
# It is not byte-identical, and the reason is in the recorder rather than in the inputs.
# Measured over eight offline runs from one transcript: every container has a different
# sha256, because the recorder stamps a UUIDv7 recording id, and the emission order of two
# storage variables within a step flips per process. Decoded through `ct-print --full` those
# eight runs produce exactly TWO outputs, 295,596 bytes each, and the online run's decoded
# output is byte-for-byte one of the two. So the transcript reproduces the live capture up
# to the recorder's own nondeterminism, and no further — which is as far as anything can.
#
# ── WHY SOURCIFY IS OFF BY DEFAULT HERE ───────────────────────────────────────────────
#
# The recorder's source attribution asks Sourcify whether an address has verified source
# and then recompiles it with the solc the contract was verified with. NEITHER input is
# immutable: a contract can be verified tomorrow that is unverified today, and whether the
# recompile succeeds depends on which solc releases the machine happens to have. A capture
# that depended on either would not be reproducible, so this script passes
# `--skip-source-fetch` and the attribution comes from the DISASSEMBLY of the bytecode the
# transcript holds — which is derived from a committed input and nothing else.
#
# Measured, this changes nothing about the capture this was built on. The online run with
# Sourcify ON got a verified answer for USDT (0.4.18+commit.9cf6e910), could not recompile
# it (no solc 0.4.18 on the machine) and fell back to the same 4,901-instruction
# disassembly; the run with Sourcify OFF registers that disassembly directly. Both produce
# the same 81,920-byte container and the same decoded content, and the only trace of the
# difference is one sentence of the recorder's stdout — which
# `produce-eth-snapshot.mjs`'s `parseRecorderLog` does not read (it anchors on status, gas
# used, the captured shape and the entry point, all four unchanged).
# `--source-fetch` turns it back on for an operator who wants to see that ledger.

set -u

# `--rpc` defaults to `$CODETRACER_EVM_RECORDER_RPC_URL`, which
# `tools/chain/eth-rpc-transcript.mjs` sets in the child's environment to its own loopback
# URL. Taking it from the environment rather than from a `{{RPC}}` placeholder is what lets
# the `just` recipes name this script without having to escape a placeholder through
# `just`'s own interpolation — one fewer spelling of the same URL, and the recipes cannot
# get it wrong because they do not say it.
rpc="${CODETRACER_EVM_RECORDER_RPC_URL:-}"
recorder=""
recorder_commit=""
tx=""
out=""
work=".eth-capture"
transcript=""
source_fetch=0
extra=()

while [ $# -gt 0 ]; do
  case "$1" in
    --rpc) rpc="$2"; shift 2 ;;
    --recorder) recorder="$2"; shift 2 ;;
    --recorder-commit) recorder_commit="$2"; shift 2 ;;
    --tx) tx="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --work) work="$2"; shift 2 ;;
    --transcript) transcript="$2"; shift 2 ;;
    --source-fetch) source_fetch=1; shift ;;
    *) extra+=("$1"); shift ;;
  esac
done

fail() { printf 'eth-capture: %s\n' "$1" >&2; exit 2; }

# SC2016 twice in this file, both deliberate: here the single quotes keep the env var's
# NAME in the message (the reader is being told which variable to set, not its value), and
# at the `node -e` below they keep a JavaScript program from being read as shell.
# shellcheck disable=SC2016
[ -n "$rpc" ] || fail '--rpc <url> is required (or $CODETRACER_EVM_RECORDER_RPC_URL)'
[ -n "$recorder" ] || fail '--recorder <path to codetracer-evm-recorder> is required'
[ -n "$recorder_commit" ] || fail '--recorder-commit <sha> is required'
[ -n "$tx" ] || fail '--tx <hash> is required'
[ -n "$out" ] || fail '--out <snapshot dir> is required'
[ -x "$recorder" ] || fail "no executable recorder at $recorder"

capture="$work/capture"
log="$work/run.log"

rm -rf "$work"
mkdir -p "$capture"

printf '── 1/2 record: %s trace-onchain %s\n' "$recorder" "$tx" >&2

# The recorder's own rc, read from the recorder and not from a pipeline. Its output is
# BOTH the operator's progress report and the input `produce-eth-snapshot.mjs` parses, so
# it goes to a file and the file is then shown — a `tee` here would make `$?` the tee's.
source_args=()
if [ "$source_fetch" -eq 0 ]; then
  source_args+=(--skip-source-fetch)
fi

set +e
"$recorder" trace-onchain "$tx" \
  --rpc-url "$rpc" \
  --out-dir "$capture" \
  ${source_args[@]+"${source_args[@]}"} \
  >"$log" 2>&1
recorder_rc=$?
set -e

cat "$log" >&2

if [ "$recorder_rc" -ne 0 ]; then
  printf 'eth-capture: the recorder exited %s; no snapshot will be produced\n' \
    "$recorder_rc" >&2
  exit "$recorder_rc"
fi

printf '── 2/2 produce: tools/chain/produce-eth-snapshot.mjs -> %s\n' "$out" >&2

# THE PUBLISHED PROVENANCE NAMES THE NODE THE DATA CAME FROM, NOT THE PORT THIS RUN USED.
#
# `--rpc` is `http://127.0.0.1:<kernel-assigned port>` whenever the capture runs from a
# transcript, and republishing that as `provenance.endpoint` would be false (the contract:
# "the node this capture was taken against"). Likewise `capturedAt`: the instant this
# capture stopped is the instant the TRANSCRIPT was recorded. Both come out of the
# transcript's own manifest, so neither is typed here.
provenance_args=()
if [ -n "$transcript" ]; then
  [ -f "$transcript/manifest.json" ] || fail "no transcript manifest at $transcript/manifest.json"
  # shellcheck disable=SC2016
  upstream=$(node -e '
    const m = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    if (!m.upstream || !m.recordedAt) {
      process.stderr.write("the transcript manifest carries no upstream/recordedAt\n");
      process.exit(1);
    }
    process.stdout.write(`${m.upstream}\n${m.recordedAt}\n`);
  ' "$transcript/manifest.json")
  node_rc=$?
  [ "$node_rc" -eq 0 ] || fail "cannot read $transcript/manifest.json"
  provenance_args+=(--endpoint-label "$(printf '%s' "$upstream" | sed -n 1p)")
  provenance_args+=(--captured-at "$(printf '%s' "$upstream" | sed -n 2p)")
  printf '   provenance from the transcript: endpoint=%s capturedAt=%s\n' \
    "$(printf '%s' "$upstream" | sed -n 1p)" "$(printf '%s' "$upstream" | sed -n 2p)" >&2
fi

set +e
node tools/chain/produce-eth-snapshot.mjs \
  --tx "$tx" \
  --capture "$capture" \
  --recorder-log "$log" \
  --recorder-commit "$recorder_commit" \
  --rpc-url "$rpc" \
  --out "$out" \
  ${provenance_args[@]+"${provenance_args[@]}"} \
  ${extra[@]+"${extra[@]}"}
producer_rc=$?
set -e

exit "$producer_rc"
