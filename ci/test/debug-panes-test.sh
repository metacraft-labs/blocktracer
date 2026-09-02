#!/usr/bin/env bash
#
# debug-panes-test.sh — compile and run tests/tdebugpanes.nim against the REAL
# CodeTracer Embed SDK.
#
# The debug route's panes render a `DebugSessionView`. `client/tests/
# test_debug_route.nim` proves the route serves one built from published data,
# with no debugger on the Nim path at all. This is the other half: the same
# pane renderers, over a `DebugSessionView` projected from the Embed SDK's own
# five ViewModels, driven through `MockBackendService`.
#
# The split is the layering, exactly as it is for `embed-handoff-test.sh`:
# merging the two suites would destroy the demonstration that the explorer
# builds without a debugger.
#
# Two things are checked before the suite runs, because both are claims the
# suite itself cannot make about its own source:
#
#   1. FACADE ONLY. Every `import` reaching the CodeTracer side is
#      `codetracer_embed`. M8a: "The debugger panes reach CodeTracer only
#      through the Embed SDK facade; no direct import of an internal module
#      passes review or the import lint."
#   2. THE PANE RENDERERS ARE THE ROUTE'S. The suite imports
#      `client/src/components/debugger`, the module `client/src/pages/debug.nim`
#      renders with. A second copy of the renderers would make this suite green
#      about code nobody serves.
#
# Sources are resolved in this order, first hit wins:
#   1. $CODETRACER_SRC / $ISONIM_SRC / $NIM_EVERYWHERE_SRC   (nix develop, CI)
#   2. sibling checkouts ../codetracer, ../isonim, ../nim-everywhere
#
# The pinned commits CI uses are in ci/embed-sdk-pin.env.
#
# Exit codes:
#   0  the suite passed
#   1  it failed
#   3  the Embed SDK source was not found (and --require was not given)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require=0
[ "${1:-}" = "--require" ] && require=1

suite_rel="tests/tdebugpanes.nim"
suite="${repo_root}/${suite_rel}"
renderers_rel="client/src/components/debugger.nim"

# ---------------------------------------------------------------------------
# Static claims about the suite's own source
# ---------------------------------------------------------------------------

[ -f "${suite}" ] || {
	echo "debug-panes-test.sh: ${suite_rel} does not exist" >&2
	exit 1
}
[ -f "${repo_root}/${renderers_rel}" ] || {
	echo "debug-panes-test.sh: ${renderers_rel} does not exist — the suite would" >&2
	echo "  be rendering panes the route does not have" >&2
	exit 1
}

echo "=== the debug panes over the real Embed SDK ==="

# 1. Facade only. `codetracer_embed` is allowed; anything that looks like the
#    Embed SDK's interior is not.
internal=0
while read -r spec; do
	[ -n "${spec}" ] || continue
	case "${spec}" in
	codetracer_embed) continue ;;
	viewmodel/* | */viewmodel/* | viewmodels/* | store/* | backend/* | \
		sdk/* | session_vm | headless_session | app/*)
		echo "debug-panes-test.sh: ${suite_rel} imports Embed SDK internal '${spec}'" >&2
		echo "  Import only 'codetracer_embed' (CodeTracer-Embed-SDK.md §7)." >&2
		internal=$((internal + 1))
		;;
	esac
done < <(grep -hoE '^[[:space:]]*import[[:space:]]+[^#]+' "${suite}" |
	sed -E 's/^[[:space:]]*import[[:space:]]+//' | tr ',' '\n' |
	sed -E 's/[[:space:]]*(as[[:space:]]+[A-Za-z_][A-Za-z0-9_]*)?[[:space:]]*$//' |
	grep -v '^std/')
[ "${internal}" -eq 0 ] || exit 1

if ! grep -q '^import codetracer_embed$' "${suite}"; then
	echo "debug-panes-test.sh: ${suite_rel} does not import 'codetracer_embed'." >&2
	echo "  This suite exists to render panes over the REAL Embed SDK. If it" >&2
	echo "  stops linking one, it is asserting about nobody." >&2
	exit 1
fi
echo "--- facade only: ${suite_rel} imports codetracer_embed and no internal"

# 2. The renderers under test are the ones the route uses.
if ! grep -q 'client/src/components/debugger' "${suite}"; then
	echo "debug-panes-test.sh: ${suite_rel} does not import the route's own pane" >&2
	echo "  renderers (${renderers_rel}). A private copy would make this suite" >&2
	echo "  green about code nobody serves." >&2
	exit 1
fi
if ! grep -q 'components/debugger' "${repo_root}/client/src/pages/debug.nim"; then
	echo "debug-panes-test.sh: client/src/pages/debug.nim no longer renders through" >&2
	echo "  ${renderers_rel} — the suite and the route have parted company." >&2
	exit 1
fi
echo "--- same renderers: the suite and client/src/pages/debug.nim share ${renderers_rel}"

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

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
	echo "debug-panes-test.sh: no CodeTracer Embed SDK found." >&2
	echo "  The pinned commit CI uses is in ci/embed-sdk-pin.env." >&2
	if [ "${require}" -eq 1 ]; then exit 1; fi
	exit 3
fi

isonim="$(find_src ISONIM_SRC isonim src/isonim/core/signals.nim)"
neverywhere="$(find_src NIM_EVERYWHERE_SRC nim-everywhere src)"

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

# `-d:codetracerSrc` is the SAME `${ct}` the --path flags above are built from,
# handed to the suite so it can read the Embed SDK's own captured
# `ct/updated-flow` window. One resolver: a suite that found the checkout its
# own way could compile against one tree and read fixtures from another, which
# is a green run about two different versions of the wire format.
echo "--- the five ViewModels drive the five panes"
nim c -r --hints:off -d:nimOldCaseObjects "-d:codetracerSrc=${ct}" \
	"${paths[@]}" "${suite}"
