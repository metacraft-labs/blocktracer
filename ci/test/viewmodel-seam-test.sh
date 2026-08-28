#!/usr/bin/env bash
#
# viewmodel-seam-test.sh — compile and run tests/tviewmodelseam.nim against the
# REAL CodeTracer Embed SDK.
#
# WHY THIS EXISTS
# ---------------
# BlockTracer's own ViewModels (Front-End-Architecture.md §3) establish §14's
# degraded states from chain- and delivery-shaped inputs, and write them to the
# debugger's panes through the seam M2b's review names: "ReplayDataStore's four
# setters plus a CtReplayStatus backend event — the layer above writes, the
# panes read".
#
# That seam is a WIRE contract: string-valued axes on a JSON event, deliberately,
# because the Embed SDK contains no chain concept and the two layers therefore
# cannot share an enum. A wire contract between two repositories drifts silently
# unless something compiles both halves and runs one against the other. This is
# that something.
#
# It is the ViewModel-layer sibling of ci/test/embed-handoff-test.sh, and the
# split is the same one: client/tests/test_chain_viewmodels.nim tests the layer
# with NO debugger on the Nim path at all, and this file tests the seam with
# one. Merging them would destroy the demonstration.
#
# Sources are resolved in this order, first hit wins:
#   1. $CODETRACER_SRC / $ISONIM_SRC / $NIM_EVERYWHERE_SRC   (nix develop, CI)
#   2. sibling checkouts ../codetracer, ../isonim, ../nim-everywhere
#
# The pinned commits CI uses are in ci/embed-sdk-pin.env.
#
# Exit codes:
#   0  the seam suite passed
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
	echo "viewmodel-seam-test.sh: no CodeTracer Embed SDK found." >&2
	echo "  Looked for src/frontend/viewmodel/codetracer_embed.nim under" >&2
	echo "  \$CODETRACER_SRC and ${repo_root}/../codetracer" >&2
	echo "  The pinned commit CI uses is in ci/embed-sdk-pin.env." >&2
	if [ "${require}" -eq 1 ]; then exit 1; fi
	exit 3
fi

isonim="$(find_src ISONIM_SRC isonim src/isonim/core/signals.nim)"
neverywhere="$(find_src NIM_EVERYWHERE_SRC nim-everywhere src)"

echo "=== BlockTracer ViewModels -> Embed SDK degraded-state seam ==="
echo "  Embed SDK:      ${ct}"
echo "  IsoNim:         ${isonim:-<not found>}"
echo "  nim-everywhere: ${neverywhere:-<not found>}"

paths=(
	"--path:${ct}/src/frontend/viewmodel"
	"--path:${ct}/src/frontend"
	"--path:${ct}/src"
	"--path:${repo_root}/client/src"
	"--path:${repo_root}/src"
)
[ -n "${isonim}" ] && paths+=("--path:${isonim}/src")
[ -n "${neverywhere}" ] && paths+=("--path:${neverywhere}/src")

echo "--- the ViewModel layer writes four axes the panes read"
nim c -r --hints:off --mm:orc -d:nimOldCaseObjects "${paths[@]}" \
	"${repo_root}/tests/tviewmodelseam.nim"
