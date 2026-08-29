#!/usr/bin/env bash
#
# fetch-engine.sh — copy the published replay engine to this site's own origin.
#
#   ./hydrate/fetch-engine.sh <dest-dir> [base-url]
#
# CodeTracer-Embed-SDK.md §5.1: "`new Worker(scriptURL)` requires a same-origin
# script. That single rule shapes the package contract, because the obvious
# design — ship everything on npm, let it load from a CDN — cannot work for the
# worker." The wasm may live anywhere (it is fetched with ordinary CORS); the
# worker may not. So the recommended mode is "copy to own origin", and this is
# that copy.
#
# It is NOT part of `just export` and nothing here is committed:
#
#   * It is 18 MB of build output from another repository, and a repository
#     that carried it would be carrying a second copy of an artifact whose
#     first copy is already published and versioned elsewhere.
#   * It reaches the network, and `nix build .#default` is hermetic.
#   * A deploy may legitimately not want it — pointing
#     `-d:replayEngineBase` at an origin that already serves the bundle is the
#     other supported answer, and `replay_engine.nim` exists to express it.
#
# With no engine at the base, hydration constructs a worker that 404s, reports
# it, and leaves the served page standing — which is §7.0's guarantee and is
# also exactly what a visitor sees today.

set -uo pipefail

dest="${1:?usage: fetch-engine.sh <dest-dir> [base-url]}"
base="${2:-https://web-codetracer.pages.dev}"
base="${base%/}"

# The three files the worker actually needs. `worker.js` is an ES module that
# imports `./pkg/db_backend.js` and resolves the wasm against `import.meta.url`
# — which is what makes the worker's own URL the asset base, and why the layout
# under `dest` has to mirror the publisher's rather than being flattened.
files=(
	"worker.js"
	"pkg/db_backend.js"
	"pkg/db_backend_bg.wasm"
)

mkdir -p "${dest}/pkg" || exit 1

echo "=== the replay engine, copied to this origin (§5.1) ==="
echo "  from: ${base}"
echo "  to:   ${dest}"

for f in "${files[@]}"; do
	url="${base}/${f}"
	out="${dest}/${f}"
	if ! curl -fsSL "${url}" -o "${out}"; then
		echo "fetch-engine.sh: could not fetch ${url}" >&2
		echo "  Nothing is left half-copied: an engine directory holding two of" >&2
		echo "  three files would let the worker construct and then fail on an" >&2
		echo "  import, which is a worse failure than not being there at all." >&2
		rm -rf "${dest}"
		exit 1
	fi
	echo "  + ${f} ($(wc -c <"${out}" | tr -d ' ') bytes)"
done

# The wasm is the thing being fetched; a proxy or a captive portal answering
# 200 with an HTML error page would otherwise be copied in as an "engine" and
# fail inside `WebAssembly.compileStreaming`, where the message names neither
# this script nor that page.
wasm="${dest}/pkg/db_backend_bg.wasm"
size="$(wc -c <"${wasm}" | tr -d ' ')"
if [ "${size}" -lt 1000000 ]; then
	echo "fetch-engine.sh: ${wasm} is only ${size} bytes." >&2
	echo "  The published engine is ~18 MB; something answered with a page." >&2
	rm -rf "${dest}"
	exit 1
fi
head -c 4 "${wasm}" | od -An -tx1 | tr -d ' \n' | grep -q '^0061736d' || {
	echo "fetch-engine.sh: ${wasm} does not begin with the wasm magic." >&2
	rm -rf "${dest}"
	exit 1
}
echo "--- the engine is at ${dest} and the wasm is wasm"
