#!/usr/bin/env bash
#
# layout-model-vendor-test.sh — proof that `layout-model-vendor.sh` DECIDES.
#
# Every one of its two checks is driven against a deliberately-broken copy and
# must fail, and against the real thing and must pass. Without this, "the
# vendored layout model is checked" would be a claim about a script nobody has
# ever seen say no — which is the shape of the checks this project keeps
# finding: a suite green with its binary missing, a tautological containment
# assertion, a lint blind to the literal it was written for.
#
# Needs a CodeTracer checkout ($CODETRACER_SRC or ../codetracer): case 3 is
# about upstream drift and cannot be simulated without an upstream.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
subject="${repo_root}/ci/test/layout-model-vendor.sh"
vendored="${repo_root}/client/src/debugger/layout_model.nim"
manifest="${repo_root}/client/src/debugger/layout_model.vendor.json"

work="$(mktemp -d "${TMPDIR:-/tmp}/layout-vendor-selftest.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

pass=0
fail=0
report() { # name expected_status actual_status
	if [ "$2" -eq "$3" ]; then
		echo "  [OK]     $1"
		pass=$((pass + 1))
	else
		echo "  [FAILED] $1 — expected exit $2, got $3" >&2
		fail=$((fail + 1))
	fi
}

ct=""
if [ -n "${CODETRACER_SRC:-}" ] &&
	[ -e "${CODETRACER_SRC}/src/frontend/headless_app/layout_model.nim" ]; then
	ct="${CODETRACER_SRC}"
elif [ -e "${repo_root}/../codetracer/src/frontend/headless_app/layout_model.nim" ]; then
	ct="$(cd "${repo_root}/../codetracer" && pwd)"
fi
if [ -z "${ct}" ]; then
	echo "layout-model-vendor-test.sh: no CodeTracer checkout; cannot drive the" >&2
	echo "  drift case, and a self-test that silently skips its own subject is" >&2
	echo "  the failure mode this file exists to rule out." >&2
	exit 1
fi

echo "=== layout-model-vendor.sh self-test ==="

# ── 1. The real thing passes ───────────────────────────────────────────────
CODETRACER_SRC="${ct}" "${subject}" --require >"${work}/1.log" 2>&1
report "the unmodified vendored copy passes" 0 $?

# ── 2. An edit to the vendored bytes is caught (check A) ───────────────────
cp "${vendored}" "${work}/tampered.nim"
printf '\n## a helpful local tweak\n' >>"${work}/tampered.nim"
LAYOUT_VENDOR_FILE="${work}/tampered.nim" CODETRACER_SRC="${ct}" \
	"${subject}" --require >"${work}/2.log" 2>&1
report "a local edit to the vendored bytes FAILS check A" 1 $?
grep -q "the vendored bytes changed" "${work}/2.log" ||
	{ echo "  [FAILED] check A failed for the wrong reason" >&2; fail=$((fail + 1)); }

# ── 3. A structural change upstream is caught (check B) ────────────────────
# The vendored file and its manifest are consistent; what moves is UPSTREAM.
# A weight change is the smallest edit that alters what a renderer draws and
# leaves every enum, every title and every pane set identical — so it is
# exactly the drift a byte comparison would catch for the wrong reason and a
# shallow value comparison would miss.
mkdir -p "${work}/fake-ct/src/frontend/headless_app"
sed 's/pane(paneEditor, "Editor", weight = 3.0)/pane(paneEditor, "Editor", weight = 7.0)/' \
	"${ct}/src/frontend/headless_app/layout_model.nim" \
	>"${work}/fake-ct/src/frontend/headless_app/layout_model.nim"
if cmp -s "${ct}/src/frontend/headless_app/layout_model.nim" \
	"${work}/fake-ct/src/frontend/headless_app/layout_model.nim"; then
	echo "  [FAILED] the drift probe changed nothing — the sed no longer matches" >&2
	fail=$((fail + 1))
else
	CODETRACER_SRC="${work}/fake-ct" "${subject}" --require >"${work}/3.log" 2>&1
	report "a changed weight upstream FAILS check B" 1 $?
	grep -q "has DIVERGED from upstream" "${work}/3.log" ||
		{ echo "  [FAILED] check B failed for the wrong reason" >&2; fail=$((fail + 1)); }
fi

# ── 4. A missing upstream is a SKIP without --require, a failure with it ───
# Driven from a COPY of the script in a tree with no `../codetracer` sibling.
# Pointing $CODETRACER_SRC at nothing is not enough: the subject falls back to
# the sibling, and this repository has one — so the case would have passed by
# finding the real upstream, which is the "check that cannot fail" shape again.
mkdir -p "${work}/isolated/ci/test" "${work}/isolated/client/src/debugger"
cp "${subject}" "${work}/isolated/ci/test/"
cp "${vendored}" "${work}/isolated/client/src/debugger/"
cp "${manifest}" "${work}/isolated/client/src/debugger/"
isolated="${work}/isolated/ci/test/layout-model-vendor.sh"
[ -e "${work}/isolated/../codetracer" ] &&
	{ echo "  [FAILED] the isolated tree has a codetracer sibling after all" >&2
	  fail=$((fail + 1)); }

CODETRACER_SRC="" "${isolated}" >"${work}/4.log" 2>&1
report "no upstream and no --require is a distinct exit 3, never a pass" 3 $?
CODETRACER_SRC="" "${isolated}" --require >"${work}/5.log" 2>&1
report "no upstream WITH --require is a failure, not a skip" 1 $?
grep -q "vendored bytes match the manifest" "${work}/4.log" ||
	{ echo "  [FAILED] check A did not run in the isolated tree" >&2; fail=$((fail + 1)); }

echo
if [ "${fail}" -gt 0 ]; then
	echo "FAIL — ${pass} passed, ${fail} failed" >&2
	exit 1
fi
echo "PASS — ${pass}/${pass} cases"
