#!/usr/bin/env bash
#
# build.sh — compile the hydration bundle.
#
# `nim js` over client/hydrate/hydrate.nim WITH the CodeTracer Embed SDK on the
# Nim path, producing client/hydrate/hydrate.js. This is the only compilation
# in this repository that links a debugger; `client/src` stays reachable from a
# build that has none, which is the layering AGENTS.md §1a describes.
#
# Sources resolve in the same order and by the same markers as
# ci/test/debug-panes-test.sh, deliberately: two ways of finding one tree is
# how the tree the bundle is built against and the tree the suites run against
# come to differ. The pinned commit is in ci/embed-sdk-pin.env.
#
# Exit codes:
#   0  the bundle was built
#   1  it failed to build
#   3  the Embed SDK source was not found (and --require was not given)
#
# Exit 3 is not a soft failure to paper over — it is the state
# `replay_engine.HydrationBundle` exists for. A build without the Embed SDK
# produces no bundle, `static_export.nim` is then compiled without
# -d:hydrationBundle, no page carries a <script>, and the site is exactly the
# one this route has always served. Page-Descriptions §7.0: "No state renders
# less than the pre-hydration page."

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
here="${repo_root}/client/hydrate"
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
	echo "hydrate/build.sh: no CodeTracer Embed SDK found." >&2
	echo "  The pinned commit CI uses is in ci/embed-sdk-pin.env." >&2
	echo "  Without it there is no hydration bundle, and the site builds and" >&2
	echo "  serves exactly as it does today (replay_engine.HydrationBundle)." >&2
	if [ "${require}" -eq 1 ]; then exit 1; fi
	exit 3
fi

# The adapter this bundle is built ON. A checkout that predates it would fail
# with a Nim "cannot open file" naming an internal module, which is a worse
# sentence than this one — and the pin DID point at such a commit until
# hydration landed, so this is a mistake with a precedent rather than a
# hypothetical.
if [ ! -f "${ct}/src/frontend/viewmodel/backend/worker_backend.nim" ]; then
	echo "hydrate/build.sh: that Embed SDK has no WorkerBackendService." >&2
	echo "  ${ct}/src/frontend/viewmodel/backend/worker_backend.nim is missing." >&2
	echo "  Hydration drives the replay worker through it; a checkout without" >&2
	echo "  it cannot build this bundle. Move CODETRACER_REF forward." >&2
	exit 1
fi

isonim="$(find_src ISONIM_SRC isonim src/isonim/core/signals.nim)"
neverywhere="$(find_src NIM_EVERYWHERE_SRC nim-everywhere src)"

echo "=== the hydration bundle ==="
echo "  Embed SDK:      ${ct}"
echo "  IsoNim:         ${isonim:-<not found>}"
echo "  nim-everywhere: ${neverywhere:-<not found>}"

paths=(
	"--path:${ct}/src/frontend/viewmodel"
	"--path:${ct}/src/frontend"
	"--path:${ct}/src"
	"--path:${repo_root}/client/src"
	# The repository's own `src`, for `blocktracer_client_deeplink` — the
	# Client SDK's browser-compilable entry point. §6.0a's grammar and its
	# five-step precedence live there and are what `hydrate.nim` resolves an
	# incoming link with; the FACADE cannot be on this path, because its graph
	# reaches `std/sha1` and `nim js` cannot compile `std/endians`.
	# `ci/test/client-sdk-boundary.sh` is what keeps that entry point narrow
	# enough for this build to be possible.
	"--path:${repo_root}/src"
)
[ -n "${isonim}" ] && paths+=("--path:${isonim}/src")
[ -n "${neverywhere}" ] && paths+=("--path:${neverywhere}/src")

# isonim's Tailwind bridge `staticRead`s a build/tailwind-styles.json that a
# source-only checkout does not have. On the C target it guards that with a
# compile-time fileExists; on the JS target it cannot, and the read is a hard
# error. The override points it at an empty object — this site uses semantic
# --bt-* tokens and no Tailwind class at all, so an empty style map is not a
# stand-in for something missing, it is the accurate one.
nim js \
	--hints:off \
	-d:release \
	-d:nimOldCaseObjects \
	-d:tailwindStylesPathOverride="${here}/tailwind-styles.json" \
	--nimcache:"${here}/nimcache" \
	"${paths[@]}" \
	-o:"${here}/hydrate.js" \
	"${here}/hydrate.nim" || exit 1

bytes="$(wc -c <"${here}/hydrate.js" | tr -d ' ')"
echo "--- built client/hydrate/hydrate.js (${bytes} bytes)"

# A bundle that compiled but lost its entry point would install cleanly, run
# nothing, and look exactly like a browser that cannot hydrate — the one
# failure this repository's honesty rules are least able to see. So the two
# things that must be in the output are checked in the output.
for needle in "__btReplayWorker" "querySelector"; do
	grep -q "${needle}" "${here}/hydrate.js" || {
		echo "hydrate/build.sh: the built bundle contains no '${needle}'." >&2
		echo "  It compiled to something that cannot reach the worker or the" >&2
		echo "  document, which would present as a page that silently does not" >&2
		echo "  hydrate." >&2
		exit 1
	}
done
echo "--- the bundle reaches both the document and the worker"

# THE POSITION MARK IS IN THE BUNDLE, and it is checked HERE because it cannot
# be checked anywhere else.
#
# `just export` and `flake.nix` build the same route from the same renderers and
# ship different artefacts: the first ships zero JavaScript, the second defers
# this bundle, and hydration re-renders every pane through `renderPanes`. A fix
# to the source renderer that never reached this file would be green in every
# suite, visible in every capture, and absent from the page a visitor loads —
# which this campaign has already shipped once.
#
# The needles are CHAR-CODE ARRAYS because that is how `nim js` emits a static
# string literal — a Nim string is bytes, so `<div class="` is
# `[60,100,105,118,32,99,108,97,115,115,61,34]` and the class name arrives as
# `escapeAttr([115,114,99,112,111,115])`. Grepping this file for `srcpos` finds
# NOTHING: the only readable text in it is what passes through
# `makeNimstrLit`. A check written the obvious way would report the mark
# missing from a bundle that has it, and the next person would loosen the check
# instead of reading it.
#
# COUNTED, and the count asserted, because the first draft of this check was
# not and could not fail. `▶` was spelled `9654` — its code POINT — which
# matches four incidental digit runs in a minified bundle and would have been
# green over a bundle that drew no position at all. The glyph is three UTF-8
# bytes, `226,150,182`, and it legitimately appears three times: the stepping
# toolbar's Step-forward button, the head, and the gutter column. Only the
# third is a bare assignment (`= [226,150,182];`, the `if ln.current` arm), so
# that is what is counted — a substring check would have been answered by the
# button, which has been on this page since M8a.
#
#   srcposlabel      the head's sentence — 1, and it exists nowhere else
#   aria-current     the row state and the head's — 2, and no more
#   = [▶];           the gutter's position column — 1, distinct from the button
declare -a marks=(
	"115,114,99,112,111,115,108,97,98,101,108:1:the position head (.srcposlabel)"
	"97,114,105,97,45,99,117,114,114,101,110,116:2:the current-row state (aria-current)"
	"= \[226,150,182\];:1:the gutter's position column (.p)"
)
for mark in "${marks[@]}"; do
	codes="${mark%%:*}"
	rest="${mark#*:}"
	want="${rest%%:*}"
	what="${rest#*:}"
	got="$(grep -o "${codes}" "${here}/hydrate.js" | wc -l | tr -d ' ')"
	[ "${got}" = "${want}" ] || {
		echo "hydrate/build.sh: the built bundle draws ${what} ${got} time(s), expected ${want}." >&2
		echo "  The static export would still show it, so a loss here presents as" >&2
		echo "  a debugger that has a cursor until the engine loads and then does" >&2
		echo "  not. The needle is a char-code array, not text: see the note." >&2
		exit 1
	}
done
echo "--- the bundle draws the session's position on both of the pane's outputs"
