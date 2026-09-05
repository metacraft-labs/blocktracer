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

# ---------------------------------------------------------------------------
# WHICH BYTES THIS BUNDLE IS BUILT AGAINST, AND A REFUSAL TO GUESS
# ---------------------------------------------------------------------------
#
# `find_src` falls back to a sibling checkout when its environment variable is
# unset, for ALL THREE of the sources this bundle compiles against, and until
# this check existed it did so SILENTLY. That made every verdict measured
# against the bundle unreproducible: the siblings are working checkouts other
# people are on, at whatever branch and commit they happen to be.
#
# MEASURED, on 2026-09-02, from ONE unchanged commit of this repository
# (`b53b76b`), three builds differing only in which trees were resolved:
#
#   A  flake inputs, all three pinned      1,453,850 bytes  c7d9bdd084bb514b…
#   B  Embed SDK pinned, IsoNim and
#      nim-everywhere from siblings        1,398,000 bytes  2f7c5d54b37fb196…
#   C  all three from siblings             1,367,706 bytes  45e1d2d883b2c652…
#
# A AND B USE THE SAME EMBED SDK REVISION AND `src/frontend` IS BYTE-IDENTICAL
# BETWEEN THEM — `diff -rq` reports no difference — yet the bundles differ by
# 55,850 bytes. That is the finding worth keeping: pinning the Embed SDK alone
# is NOT enough, because IsoNim and nim-everywhere are on the Nim path too and
# were 18 and 12 commits off their own pins in the same file. A check that
# verified only `CODETRACER_SRC` would have printed a reassuring "revision
# matches the pin" over build B and been wrong about the bytes.
#
# On a bundle built this way, journey 13 was RED twice in a row,
# deterministically, with a clean tree and no mutation anywhere — the source
# pane never scrolled and the position never moved down the box — and GREEN
# against the pinned build with byte-identical numbers. Two agents could run one
# journey on one commit and honestly reach opposite verdicts, with nothing in
# either transcript to tell them apart.
#
# `ci/embed-sdk-pin.env` already states the rule this script was breaking, in
# its own words: "validate against the PIN, not against whatever a sibling
# `../codetracer` happens to be sitting on", and "a green build here has to be
# able to name the bytes it was green against". It pins all three. So all three
# are now READ from it and verified, and a tree that is not the pin is refused.
#
# IDENTITY COMES FROM WHEREVER IT IS ACTUALLY GUARANTEED:
#
#   * a NIX STORE PATH — `flake.nix` sets these from flake inputs, and
#     `packages.default` and every CI job build that way. A store path has no
#     git metadata, so its revision is the flake's; for the Embed SDK the flake
#     names it with an explicit `rev=` and that is checked against the pin
#     below, an equality previously asserted only in a COMMENT in
#     `.github/workflows/ci.yml` ("required to be equal and are") and enforced
#     by nothing.
#   * a GIT CHECKOUT — its revision is `HEAD`, and its `src/` must be clean,
#     because a revision does not name the bytes if the bytes were edited after
#     it.
#
# A SIBLING AT EXACTLY THE PIN IS ACCEPTED, and that is not a loophole: the test
# is identity, not provenance. If that sibling later moves, the next build fails
# loudly instead of quietly measuring something else.
#
# `CODETRACER_ALLOW_UNPINNED=1` overrides, because moving the pins forward is a
# real workflow that `ci/embed-sdk-pin.env` documents under "HOW TO MOVE IT". It
# is deliberately not a flag: it must be typed into the environment, and it
# prints a banner naming what was used instead.

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
	else printf 'unavailable'; fi
}

pin_file="${repo_root}/ci/embed-sdk-pin.env"
pin_of() {
	sed -n "s/^$1=\([0-9a-f]\{40\}\).*/\1/p" "${pin_file}" 2>/dev/null | head -1
}

pin_ct="$(pin_of CODETRACER_REF)"
pin_isonim="$(pin_of ISONIM_REF)"
pin_ne="$(pin_of NIM_EVERYWHERE_REF)"
if [ -z "${pin_ct}" ] || [ -z "${pin_isonim}" ] || [ -z "${pin_ne}" ]; then
	echo "hydrate/build.sh: could not read all three refs from ${pin_file}." >&2
	echo "  That file is the one place naming the bytes this repository is built" >&2
	echo "  against. Without it this script cannot say what it built, and a" >&2
	echo "  verdict with no artefact identity beside it is unfalsifiable." >&2
	exit 1
fi

# The flake input and the pin are ONE fact in two files. CI's own comment says
# they "are required to be equal"; nothing made them so until here.
flake_rev="$(sed -n 's/.*github\.com\/metacraft-labs\/codetracer.*rev=\([0-9a-f]\{40\}\).*/\1/p' \
	"${repo_root}/flake.nix" 2>/dev/null | head -1)"
if [ -n "${flake_rev}" ] && [ "${flake_rev}" != "${pin_ct}" ]; then
	echo "hydrate/build.sh: flake.nix and ci/embed-sdk-pin.env name different Embed SDKs." >&2
	echo "  flake.nix codetracer rev : ${flake_rev}" >&2
	echo "  ci/embed-sdk-pin.env     : ${pin_ct}" >&2
	echo "  The bundle CI ships and the SDK CI's suites run against would be two" >&2
	echo "  different trees. Move both, or neither." >&2
	exit 1
fi

isonim="$(find_src ISONIM_SRC isonim src/isonim/core/signals.nim)"
neverywhere="$(find_src NIM_EVERYWHERE_SRC nim-everywhere src)"

# Per source: how it was resolved, what revision it is, and whether that is the
# pin. Reported for all three whatever the verdict, because the transcript has
# to name the bytes even on a green run.
unpinned_reasons=""
describe_and_check() {
	local label="$1" path="$2" pin="$3" envvar="$4"
	local how rev dirty
	if [ -z "${path}" ]; then
		printf '  %-15s %s\n' "${label}:" "<not found>"
		return
	fi
	if [ -n "${!envvar:-}" ] && [ "${path}" = "${!envvar}" ]; then
		how="\$${envvar}"
	else
		how="sibling (\$${envvar} unset)"
	fi
	dirty=0
	case "${path}" in
	/nix/store/*)
		rev="${pin}"
		how="${how}, nix store — revision is the flake's pin"
		;;
	*)
		rev="$(git -C "${path}" rev-parse HEAD 2>/dev/null)"
		[ -n "${rev}" ] && dirty="$(git -C "${path}" status --porcelain -- src 2>/dev/null | wc -l | tr -d ' ')"
		;;
	esac
	printf '  %-15s %s\n' "${label}:" "${path}"
	printf '  %-15s %s\n' "" "${how}"
	printf '  %-15s %s\n' "" "rev ${rev:-<unknown>}  pin ${pin}$(
		if [ -z "${rev}" ]; then echo "  <<< CANNOT BE IDENTIFIED"
		elif [ "${rev}" != "${pin}" ]; then echo "  <<< NOT THE PIN"
		elif [ "${dirty}" != "0" ]; then echo "  <<< ${dirty} EDITED FILE(S) UNDER src/"
		else echo "  ok"; fi)"
	if [ -z "${rev}" ]; then
		unpinned_reasons="${unpinned_reasons}
    ${label}: revision cannot be determined (${path})"
	elif [ "${rev}" != "${pin}" ]; then
		unpinned_reasons="${unpinned_reasons}
    ${label}: at ${rev}, pin is ${pin}"
	elif [ "${dirty}" != "0" ]; then
		unpinned_reasons="${unpinned_reasons}
    ${label}: at the pin but ${dirty} uncommitted file(s) under src/"
	fi
}

echo "=== the hydration bundle ==="
describe_and_check "Embed SDK" "${ct}" "${pin_ct}" CODETRACER_SRC
describe_and_check "IsoNim" "${isonim}" "${pin_isonim}" ISONIM_SRC
describe_and_check "nim-everywhere" "${neverywhere}" "${pin_ne}" NIM_EVERYWHERE_SRC

if [ -n "${unpinned_reasons}" ]; then
	if [ "${CODETRACER_ALLOW_UNPINNED:-0}" = "1" ]; then
		echo ""
		echo "  !!! UNPINNED BUILD — CODETRACER_ALLOW_UNPINNED=1 !!!${unpinned_reasons}"
		echo "  The bundle below is NOT the artefact CI builds. Any verdict measured"
		echo "  against it names these bytes and no others; do not carry it between"
		echo "  agents or into a ledger without saying so."
		echo ""
	else
		# The stale bundle GOES. A LEFTOVER hydrate.js from an earlier run would
		# be installed by the exporter as though this build had produced it,
		# which is the stale-artefact bug this check exists to end, one layer
		# down.
		rm -f "${here}/hydrate.js"
		echo "hydrate/build.sh: refusing to build against sources that are not the pin." >&2
		echo "${unpinned_reasons}" >&2
		echo "" >&2
		echo "  This is not pedantry about a version. The siblings are working" >&2
		echo "  checkouts other people are on, and building against whatever they sit" >&2
		echo "  on made verdicts here unreproducible. From ONE unchanged commit of" >&2
		echo "  this repository, three builds differing only in which trees resolved:" >&2
		echo "    all three pinned                       1,453,850 bytes" >&2
		echo "    Embed SDK pinned, other two siblings   1,398,000 bytes" >&2
		echo "    all three siblings                     1,367,706 bytes" >&2
		echo "  The first two use the SAME Embed SDK revision and a byte-identical" >&2
		echo "  src/frontend. A journey was deterministically RED on one of these and" >&2
		echo "  GREEN on the pinned build, with a clean tree and no mutation." >&2
		echo "" >&2
		echo "  remedy — inside the flake, nothing: nix develop / nix build set all" >&2
		echo "  three for you, and that is what CI does. Outside it, worktrees of the" >&2
		echo "  pins, which nobody else will move:" >&2
		echo "    git -C <codetracer>     worktree add /tmp/ct-pin --detach ${pin_ct}" >&2
		echo "    git -C <isonim>         worktree add /tmp/isonim-pin --detach ${pin_isonim}" >&2
		echo "    git -C <nim-everywhere> worktree add /tmp/ne-pin --detach ${pin_ne}" >&2
		echo "    export CODETRACER_SRC=/tmp/ct-pin ISONIM_SRC=/tmp/isonim-pin NIM_EVERYWHERE_SRC=/tmp/ne-pin" >&2
		echo "" >&2
		echo "  to build against something else ON PURPOSE (moving the pins forward):" >&2
		echo "    CODETRACER_ALLOW_UNPINNED=1 ..." >&2
		echo "  Any stale client/hydrate/hydrate.js has been REMOVED, so nothing" >&2
		echo "  downstream can install a bundle this run did not produce." >&2
		exit 1
	fi
fi

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

# THE BUILD STAMPS ITS OWN OUTPUT, AND WITHOUT THIS LINE THE FRESHNESS GATE
# DOWNSTREAM REPORTS A BUNDLE THAT WAS JUST BUILT AS STALE.
#
# `nim js -o:X` does not rewrite X when the emitted bytes are unchanged, so X
# keeps whatever mtime it had — MEASURED, on this repository's pinned Nim
# 2.2.10: hydrate.js was set to 2020-01-01, `build.sh --require` was run to
# completion (rc 0, 1,965,013 bytes, all three sources at the pins), and the
# mtime was still 2020-01-01 afterwards.
#
# `static_export.nim`'s `requireFreshBundle` reads that mtime as "when this
# bundle was built" and refuses to publish a bundle older than the newest
# `.nim` under client/hydrate, client/src and src. Its premise is therefore
# false for any source edit that does not change the emitted bundle — a
# comment, a reordering, or a byte-identical rewrite — and the remedy it prints,
# `cd client && just hydrate`, CANNOT CLEAR THE CONDITION IT REPORTS. Running
# it produces the same bytes and leaves the same mtime, so the gate fires again,
# forever, on a tree that is not stale.
#
# That is not hypothetical. It is what put `journeys` and all four
# `journeys-bite` shards red on 779c702: `tools/journeys/selftest.mjs` writes a
# mutation into a `client/src/*.nim` and writes the original bytes back
# afterwards, which is exactly the byte-identical rewrite above.
#
# So the mtime is made to mean what the gate reads it as: the moment a build
# last produced this file from this source. The gate is unchanged and still
# refuses a bundle nobody rebuilt — that case leaves the old mtime because this
# line never runs.
touch "${here}/hydrate.js"

bytes="$(wc -c <"${here}/hydrate.js" | tr -d ' ')"
digest="$(sha256_of "${here}/hydrate.js")"

# THE ARTEFACT NAMES ITSELF. A verdict measured against a bundle, with no
# identity for that bundle beside it, cannot be checked by anyone who was not
# there — it is the stale-artefact problem and the wrong-SDK problem in the same
# sentence. `dev` was once green while the deployed origin served an
# `assets/hydrate.js` 6,441 bytes older than it, and the two defects that fixed
# reproduced verbatim on the served one; a size and a digest in the transcript
# are what make "which bundle was that?" answerable afterwards rather than a
# reconstruction.
echo "--- built client/hydrate/hydrate.js"
echo "      bytes:   ${bytes}"
echo "      sha256:  ${digest}"
echo "      sources: $([ -n "${unpinned_reasons}" ] \
	&& echo "UNPINNED — see the banner above; this is not the artefact CI builds" \
	|| echo "all three at the pins in ci/embed-sdk-pin.env")"

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
# toolbar's Step-forward button, the head, and the gutter column.
#
# THE GLYPH IS NO LONGER HOW THE GUTTER COLUMN IS FOUND. The needle used to be
# `= [226,150,182];` — the bare assignment `nim js` emits for the `if
# ln.current: "▶" else: " "` expression — and that expression is gone: the cell
# is now written as two whole branches, because the current row's `.p` carries
# `tabindex="-1"` and `autofocus`, which is what opens the pane AT the position
# on a page with no script (see `source_document.nim` for why there is no longer
# a window doing that job). The assignment form vanished and this check went red
# over a bundle that draws the column correctly — which is the check working, and
# is why it is rewritten rather than loosened.
#
# The replacement is the cell's `aria-label` copy. It is a static literal that
# exists in exactly one place in the source, it is unambiguous in the bundle
# (the glyph is not), and it names the thing being checked.
#
#   srcposlabel      the head's sentence — 1, and it exists nowhere else
#   aria-current     the row state and the head's — 2, and no more
#   the session…line the gutter's position column (.p) — 1
#   autofocus        the attribute NAME and its value, on that same cell — 2.
#                    It is what opens the pane at the position with no script,
#                    and the served page and the hydrated pane have to be the
#                    same markup, so it has to be in both renderers.
declare -a marks=(
	"115,114,99,112,111,115,108,97,98,101,108:1:the position head (.srcposlabel)"
	"97,114,105,97,45,99,117,114,114,101,110,116:2:the current-row state (aria-current)"
	"116,104,101,32,115,101,115,115,105,111,110,32,105,115,32,115,116,111,112,112,101,100,32,111,110,32,108,105,110,101,32:1:the gutter's position column (.p)"
	"97,117,116,111,102,111,99,117,115:2:the position cell's autofocus"
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
