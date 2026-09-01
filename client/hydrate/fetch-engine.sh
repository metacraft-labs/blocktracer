#!/usr/bin/env bash
#
# fetch-engine.sh — copy the published replay engine to this site's own origin.
#
#   ./hydrate/fetch-engine.sh <dest-dir> [base-url] [manifest-path]
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

dest="${1:?usage: fetch-engine.sh <dest-dir> [base-url] [manifest-path]}"
base="${2:-https://web-codetracer.pages.dev}"
base="${base%/}"
# WHERE THIS RUN RECORDS WHAT IT ACTUALLY DOWNLOADED.
#
# The engine's bytes come from another repository, so this repo can assert
# nothing about WHICH engine is correct — a version pin here would make an
# unrelated CodeTracer release break this repository's deploy, which is the
# trap the deploy workflow's engine step already refuses to walk into.
#
# What it CAN assert is that the bytes it publishes are the bytes it fetched
# in THIS run. That distinction is the whole point: a NEW engine changes these
# hashes and passes, while a STALE one — a leftover `site/replay-engine` from
# an earlier run, a half-overwritten file, a CDN edge that answered a runner
# with a previous deployment's bytes — does not match and fails.
#
# Empty path = write nothing, which keeps `just hydrate` and every local
# invocation exactly as they were.
manifest="${3:-}"

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

# ── What this run fetched, for check-freshness.mjs to hold the publish to ──
#
# `sha256sum` on the Linux runners, `shasum -a 256` on a macOS workstation.
# Neither is assumed: a checkout with neither writes no manifest and says so,
# rather than emitting a file of empty hashes that would make every comparison
# against it trivially true.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		return 1
	fi
}

if [ -n "${manifest}" ]; then
	if ! sha256_of "${wasm}" >/dev/null 2>&1; then
		echo "fetch-engine.sh: no sha256sum or shasum on PATH; wrote no manifest." >&2
		echo "  check-freshness.mjs will report its vendored check NOT REQUIRED" >&2
		echo "  rather than passing over hashes this script did not compute." >&2
		exit 0
	fi
	mkdir -p "$(dirname "${manifest}")"
	{
		printf '{\n'
		printf '  "origin": "%s",\n' "${base}"
		printf '  "fetchedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf '  "runId": "%s",\n' "${GITHUB_RUN_ID:-local}"
		printf '  "runAttempt": "%s",\n' "${GITHUB_RUN_ATTEMPT:-local}"
		printf '  "files": {\n'
		last=$((${#files[@]} - 1))
		for i in "${!files[@]}"; do
			f="${files[$i]}"
			h="$(sha256_of "${dest}/${f}")"
			sep=","
			[ "${i}" -eq "${last}" ] && sep=""
			printf '    "%s": { "sha256": "%s", "bytes": %s }%s\n' \
				"${f}" "${h}" "$(wc -c <"${dest}/${f}" | tr -d ' ')" "${sep}"
		done
		printf '  }\n'
		printf '}\n'
	} >"${manifest}"
	echo "--- recorded what this run fetched: ${manifest}"
fi
