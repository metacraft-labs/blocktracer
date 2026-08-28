#!/usr/bin/env bash
#
# embed-handoff-test.sh — compile and run tests/tembedhandoff.nim against the
# REAL CodeTracer Embed SDK.
#
# This is the only test in the repository that needs the sibling package, and
# that is the point: the chain half of the Client SDK is tested by
# `tests/tclientsdk.nim` with no debugger on the Nim path at all, and the
# handoff is tested here with one. The split is the layering
# (BlockTracer/Client-SDK.md §5).
#
# Sources are resolved in this order, first hit wins:
#   1. $CODETRACER_SRC / $ISONIM_SRC / $NIM_EVERYWHERE_SRC   (nix develop, CI)
#   2. sibling checkouts ../codetracer, ../isonim, ../nim-everywhere
#
# The pinned commits CI uses are in ci/embed-sdk-pin.env.
#
# Exit codes:
#   0  the handoff suite passed
#   1  it failed
#   3  the Embed SDK source was not found (and --require was not given)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require=0
[ "${1:-}" = "--require" ] && require=1

find_src() {
	local envvar="$1" sibling="$2" marker="$3"
	local fromenv="${!envvar:-}"
	if [ -n "${fromenv}" ] && [ -e "${fromenv}/${marker}" ]; then
		printf '%s' "${fromenv}"
		return 0
	fi
	if [ -e "${repo_root}/../${sibling}/${marker}" ]; then
		(cd "${repo_root}/../${sibling}" && pwd)
		return 0
	fi
	return 1
}

ct="$(find_src CODETRACER_SRC codetracer src/frontend/viewmodel/codetracer_embed.nim)"
if [ -z "${ct}" ]; then
	echo "embed-handoff-test.sh: no CodeTracer Embed SDK found." >&2
	echo "  Looked for src/frontend/viewmodel/codetracer_embed.nim under" >&2
	echo "  \$CODETRACER_SRC and ${repo_root}/../codetracer" >&2
	echo "  The pinned commit CI uses is in ci/embed-sdk-pin.env." >&2
	if [ "${require}" -eq 1 ]; then exit 1; fi
	exit 3
fi

isonim="$(find_src ISONIM_SRC isonim src/isonim/core/signals.nim)"
neverywhere="$(find_src NIM_EVERYWHERE_SRC nim-everywhere src)"

echo "=== Client SDK -> Embed SDK handoff ==="
echo "  Embed SDK:      ${ct}"
echo "  IsoNim:         ${isonim:-<not found>}"
echo "  nim-everywhere: ${neverywhere:-<not found>}"

embed_paths=(
	"--path:${ct}/src/frontend/viewmodel"
	"--path:${ct}/src/frontend"
	"--path:${ct}/src"
)
[ -n "${isonim}" ] && embed_paths+=("--path:${isonim}/src")
[ -n "${neverywhere}" ] && embed_paths+=("--path:${neverywhere}/src")

# ---------------------------------------------------------------------------
# Step 1: the LOWER layer builds on its own.
#
# The Embed SDK is compiled with NOTHING from this repository on the Nim path.
# That is the property M12a's `test_noir_studio_builds_without_the_client_sdk`
# is really about — a second consumer needs the whole lower layer and none of
# the chain layer — checked here as far as this repository honestly can: Noir
# Studio itself is not in this workspace, so what is verified is that the layer
# it would link does not need the Client SDK, not that Noir Studio builds.
# ---------------------------------------------------------------------------

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/embed-standalone.XXXXXX")"
trap 'rm -rf "${probe_dir}"' EXIT
cat >"${probe_dir}/embedonly.nim" <<'EOF'
## The Embed SDK, with no chain layer anywhere near it.
import std/json
import codetracer_embed

let source = httpRangeTrace("https://example.invalid/t/ab/cd/xyz/trace.ct")
doAssert source.isValid
source.validate()
doAssert source.toLaunchArgs["traceSource"]["kind"].getStr == "http-range"
doAssert CodeTracerEmbedFacadeModule == "codetracer_embed"
echo "embed-sdk-standalone: ok"
EOF

echo "--- the Embed SDK compiles and runs with no Client SDK on the path"
if ! nim c -r --hints:off --warnings:off -d:nimOldCaseObjects \
	"${embed_paths[@]}" \
	--nimcache:"${probe_dir}/nimcache" -o:"${probe_dir}/embedonly" \
	"${probe_dir}/embedonly.nim"; then
	echo "embed-handoff-test.sh: the Embed SDK does not build standalone" >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: the handoff itself.
# ---------------------------------------------------------------------------

echo "--- the Client SDK hands it a TraceSource"
nim c -r --hints:off -d:nimOldCaseObjects "${embed_paths[@]}" \
	"${repo_root}/tests/tembedhandoff.nim"
