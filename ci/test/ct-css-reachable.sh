#!/usr/bin/env bash
#
# ct-css-reachable.sh — export the site and assert that every selector the
# CodeTracer CSS port emits is either matched by markup this site produces or
# declared INERT with a reason.
#
# WHY THIS EXISTS
# ---------------
# `client/src/components/ct_components_css.nim` compiles eight vendored
# CodeTracer stylesheets into the CSS this site serves. `Dropped` in that module
# records the rules the port does NOT emit, each with a reason, and
# `client/tests/test_ct_components_css.nim` asserts every reported drop is
# deliberate. THE CONVERSE HAD NO CHECK: nothing asserted that a rule which was
# KEPT can actually match anything.
#
# Three defects came out of that gap, and two of them were reported to the owner
# as fixed when they were not:
#
#   1. `.component-container` — CodeTracer's panel surface, vendored, scoped and
#      served while `grep -c component-container` over `components/debugger.nim`
#      and `pages/debug.nim` was 0.
#   2. the nine vendored CodeTracer icons — their `url()`s were fixed from a path
#      this site never published to the published copies, and a rendered probe
#      then proved that all nine RULES work with injected markup and that ZERO
#      of their selectors is emitted anywhere.
#   3. `.separate-bar` and `.dropdown-list` — each given a colour binding while
#      matching zero elements.
#
# WHAT THE GATE IS, AND WHY IT IS TWO HALVES
# ------------------------------------------
# `client/src/components/ct_css_reach.txt` is the register that answers the
# converse: one row per class, `[class*=]` substring, id and element the port's
# selectors name, each row either LIVE or INERT and each carrying its reason.
# Its own header is the argument for every decision in it.
#
#   * `cd client && just test-ct-components-css` asserts the register is TOTAL —
#     every item the port emits is covered by exactly one row, and every row
#     covers something. That needs no build and runs in seconds, so a re-vendor
#     that introduces an unclassified selector fails there first.
#
#   * THIS gate asserts the register is TRUE — every LIVE row is emitted by the
#     exported site, and no INERT row is. That needs the artefact, which is why
#     it is a shell gate and not a unit test.
#
# Neither half is the gate alone, and that is the point: the first says the
# register accounts for everything, the second says it is not lying.
#
# HOW IT RUNS
# -----------
#   1. compile and run the real exporter into a scratch dist/ (~348 pages over
#      the committed demo data tree, NOT the ~104k-page full export)
#   2. run `tools/ci/check-css-reachable.mjs` over it, with the repository's
#      `client/` tree for the source half of the markup scan
#
# Compiled into a scratch directory so a concurrent `just export` is untouched,
# in exactly the shape `untrusted-text.sh` uses and for the same reason.
#
# TWO BUNDLES, NOT THREE, AND THAT IS A DELIBERATE LINE.
#
# `-d:hydrationBundle` makes the exporter REQUIRE a built hydration bundle, and
# that bundle is the one compilation in this repository that links a debugger
# (AGENTS.md §1a). A gate that needed it could not run in the `debug-route` job
# at all, which is the job that already renders the site with no debugger on the
# Nim path. So this builds the two bundles that need no Embed SDK — the search
# and settings boots — and exports with those.
#
# THAT IS ENOUGH FOR THE DECODER TO BE VALIDATED RATHER THAN SKIPPED, which is
# the whole reason to build any bundle here. `check-css-reachable.mjs` validates
# its char-code decoder in three tiers: a synthetic literal (always), a real
# bundle carrying some token encoded-but-not-as-text and some token both ways
# (needs a bundle, any bundle), and the measured `hydrate.js` pair (needs that
# bundle). The run prints which tiers it asked, so a tier that did not run reads
# as not-run rather than as passed.
#
# No verdict in the register depends on a bundle: the bundle half is measured
# and deliberately NOT counted as liveness, for the reason the register's header
# gives at length. To see the third tier filled, run it by hand over a hydrated
# export:
#
#     cd client && just export-hydrated
#     node tools/ci/check-css-reachable.mjs client/dist --client client
#
# Exit codes:
#   0  every row of the register holds
#   1  a row does not — a LIVE row nothing emits, or an INERT row something does
#   2  the export did not build or run
#   3  nothing was measured (a vacuity floor refused the run)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
register="${repo_root}/client/src/components/ct_css_reach.txt"

# Ask git, not the filesystem: this repository is developed on a
# case-insensitive filesystem and checked on runners that are not.
if ! git -C "${repo_root}" ls-files --error-unmatch \
	client/src/components/ct_css_reach.txt >/dev/null 2>&1; then
	echo "ct-css-reachable.sh: the register is not a tracked file" >&2
	echo "  expected client/src/components/ct_css_reach.txt" >&2
	exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-css-reachable.XXXXXX")"
cleanup() { rm -rf "${work}"; }
trap cleanup EXIT

echo "== building the two Embed-SDK-free bundles =="
# `nim js` into their usual places, because `installSearchBundle` /
# `installSettingsBundle` read them from there and re-check their freshness
# against `client/src`. Both outputs are gitignored.
(
	cd "${repo_root}/client" &&
		nim js --hints:off -d:release --path:src --path:../src \
			--nimcache:"${work}/searchcache" \
			-o:searchboot/search.js searchboot/searchboot.nim &&
		touch searchboot/search.js &&
		nim js --hints:off -d:release --path:src --path:../src \
			--nimcache:"${work}/settingscache" \
			-o:settingsboot/settings.js settingsboot/settingsboot.nim &&
		touch settingsboot/settings.js
) >"${work}/bundles.log" 2>&1 || {
	echo "ct-css-reachable.sh: a bundle did not build" >&2
	tail -30 "${work}/bundles.log" >&2
	exit 2
}

echo "== exporting the site =="
(
	cd "${repo_root}/client" &&
		nim c --mm:orc -d:isServer -d:release --hints:off \
			-d:searchBundle=/assets/search.js \
			-d:settingsBundle=/assets/settings.js \
			--nimcache:"${work}/nimcache" \
			-o:"${work}/static_export" src/static_export.nim
) >"${work}/build.log" 2>&1 || {
	echo "ct-css-reachable.sh: the exporter did not build" >&2
	tail -30 "${work}/build.log" >&2
	exit 2
}

(cd "${work}" && "${work}/static_export") >"${work}/export.log" 2>&1 || {
	echo "ct-css-reachable.sh: the export did not run" >&2
	tail -30 "${work}/export.log" >&2
	exit 2
}

# VERIFY BY ARTEFACT, NOT BY EXIT CODE. A build in this repository has exited 0
# while having failed, and an export that produced no pages would send every
# INERT row of the register green.
if [ ! -d "${work}/dist" ]; then
	echo "ct-css-reachable.sh: the export produced no dist/" >&2
	tail -30 "${work}/export.log" >&2
	exit 2
fi
for bundle in search settings; do
	if [ ! -s "${work}/dist/assets/${bundle}.js" ]; then
		echo "ct-css-reachable.sh: the export shipped no ${bundle}.js" >&2
		echo "  without a bundle the decoder validation is skipped rather than run" >&2
		exit 2
	fi
done

echo "== asserting the register against it =="
node "${repo_root}/tools/ci/check-css-reachable.mjs" \
	"${work}/dist" \
	--client "${repo_root}/client" \
	--register "${register}"
rc=$?
if [ "${rc}" -eq 0 ]; then
	echo "ct-css-reachable.sh: PASS"
else
	echo "ct-css-reachable.sh: FAIL (rc=${rc})" >&2
fi
exit "${rc}"
