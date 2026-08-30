#!/usr/bin/env bash
#
# flow-layout-vendor-test.sh — proof that `flow-layout-vendor.sh` DECIDES.
#
# Every check it makes is driven against a deliberately-broken copy and must
# fail, and against the real thing and must pass. Without this, "the vendored
# omniscience layout is checked" would be a claim about a script nobody has ever
# seen say no — the shape of check this project keeps finding: a suite green
# with its binary missing, a tautological containment assertion, a mutation bite
# still reporting a bite it no longer took.
#
# Needs a CodeTracer checkout ($CODETRACER_SRC or ../codetracer): case 3 is
# about upstream drift and cannot be simulated without an upstream.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
subject="${repo_root}/ci/test/flow-layout-vendor.sh"
vendor_dir="${repo_root}/client/src/debugger/vendor"
layout_rel="frontend/viewmodel/viewmodels/flow_layout.nim"
math_rel="frontend/ui/flow_loop_math.nim"
layout_up="src/frontend/viewmodel/viewmodels/flow_layout.nim"

work="$(mktemp -d "${TMPDIR:-/tmp}/flow-vendor-selftest.XXXXXX")"
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
because() { # log pattern description
	grep -q "$2" "$1" ||
		{
			echo "  [FAILED] $3" >&2
			fail=$((fail + 1))
		}
}

ct=""
if [ -n "${CODETRACER_SRC:-}" ] && [ -e "${CODETRACER_SRC}/${layout_up}" ]; then
	ct="${CODETRACER_SRC}"
elif [ -e "${repo_root}/../codetracer/${layout_up}" ]; then
	ct="$(cd "${repo_root}/../codetracer" && pwd)"
fi
if [ -z "${ct}" ]; then
	echo "flow-layout-vendor-test.sh: no CodeTracer checkout; cannot drive the" >&2
	echo "  drift case, and a self-test that silently skips its own subject is" >&2
	echo "  the failure mode this file exists to rule out." >&2
	exit 1
fi

mirror() { # dest — a working copy of the vendor directory
	mkdir -p "$1/frontend/viewmodel/viewmodels" "$1/frontend/ui"
	cp "${vendor_dir}/${layout_rel}" "$1/${layout_rel}"
	cp "${vendor_dir}/${math_rel}" "$1/${math_rel}"
	cp "${vendor_dir}/flow_layout.vendor.json" "$1/flow_layout.vendor.json"
}

echo "=== flow-layout-vendor.sh self-test ==="

# ── 1. The real thing passes ───────────────────────────────────────────────
CODETRACER_SRC="${ct}" "${subject}" --require >"${work}/1.log" 2>&1
report "the unmodified vendored copies pass" 0 $?

# ── 2. An edit to EITHER vendored file is caught (check A) ─────────────────
# Both, separately: a manifest that only ever compared the first file would pass
# case 2a and is exactly what a two-file check gets wrong.
for target in "${layout_rel}" "${math_rel}"; do
	mirror "${work}/edit"
	printf '\n## a helpful local tweak\n' >>"${work}/edit/${target}"
	FLOW_VENDOR_DIR="${work}/edit" CODETRACER_SRC="${ct}" \
		"${subject}" --require >"${work}/2.log" 2>&1
	report "a local edit to ${target##*/} FAILS check A" 1 $?
	because "${work}/2.log" "the vendored bytes changed" \
		"check A failed for the wrong reason on ${target##*/}"
	rm -rf "${work}/edit"
done

# ── 2b. A manifest that lost an entry is caught, not silently believed ─────
mirror "${work}/short"
python3 - "${work}/short/flow_layout.vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["files"] = d["files"][:1]
json.dump(d, open(p, "w"), indent=2)
PY
FLOW_VENDOR_DIR="${work}/short" CODETRACER_SRC="${ct}" \
	"${subject}" --require >"${work}/2b.log" 2>&1
report "a manifest missing a file FAILS rather than checking one" 1 $?
because "${work}/2b.log" "expected 2" "the short manifest failed for the wrong reason"
rm -rf "${work}/short"

# ── 2c. A manifest naming a commit other than the Embed SDK pin is caught ──
# These files are inside the tree the pin names, and `client/hydrate/` compiles
# against that tree, so two commits would be two versions of one arithmetic
# laying out one page.
mirror "${work}/skew"
sed -i.bak 's/"commit": "[0-9a-f]*"/"commit": "0000000000000000000000000000000000000000"/' \
	"${work}/skew/flow_layout.vendor.json"
FLOW_VENDOR_DIR="${work}/skew" CODETRACER_SRC="${ct}" \
	"${subject}" --require >"${work}/2c.log" 2>&1
report "a manifest commit that is not the SDK pin FAILS" 1 $?
because "${work}/2c.log" "different commits" "the pin-skew case failed for the wrong reason"
rm -rf "${work}/skew"

# ── 3. A behaviour change upstream is caught (check B) ─────────────────────
# `MinExpressionChars` is the smallest edit that moves a NUMBER a renderer
# draws — a legend heading's character budget — while leaving every type, every
# proc name and every signature identical. A byte comparison would catch it for
# the wrong reason; a comparison of types alone would miss it entirely.
mkdir -p "${work}/fake-ct/src/frontend/viewmodel/viewmodels" \
	"${work}/fake-ct/src/frontend/ui"
sed 's/MinExpressionChars\* = 3/MinExpressionChars* = 5/' \
	"${ct}/${layout_up}" >"${work}/fake-ct/${layout_up}"
cp "${ct}/src/frontend/ui/flow_loop_math.nim" \
	"${work}/fake-ct/src/frontend/ui/flow_loop_math.nim"
if cmp -s "${ct}/${layout_up}" "${work}/fake-ct/${layout_up}"; then
	echo "  [FAILED] the drift probe changed nothing — the sed no longer matches" >&2
	fail=$((fail + 1))
else
	CODETRACER_SRC="${work}/fake-ct" "${subject}" --require >"${work}/3.log" 2>&1
	report "a changed legend budget upstream FAILS check B" 1 $?
	because "${work}/3.log" "has DIVERGED from upstream" \
		"check B failed for the wrong reason"
fi

# ── 3b. A change in the LOOP ARITHMETIC is caught too ──────────────────────
# `flow_loop_math` is the second vendored file and the one whose answers decide
# which pass a reader is looking at (#593). A check that only compiled it would
# not notice.
mkdir -p "${work}/fake-ct2/src/frontend/viewmodel/viewmodels" \
	"${work}/fake-ct2/src/frontend/ui"
cp "${ct}/${layout_up}" "${work}/fake-ct2/${layout_up}"
sed 's/  const$/  const/; s/FirstIteration = 0/FirstIteration = 1/' \
	"${ct}/src/frontend/ui/flow_loop_math.nim" \
	>"${work}/fake-ct2/src/frontend/ui/flow_loop_math.nim"
if cmp -s "${ct}/src/frontend/ui/flow_loop_math.nim" \
	"${work}/fake-ct2/src/frontend/ui/flow_loop_math.nim"; then
	echo "  [FAILED] the loop-math drift probe changed nothing" >&2
	fail=$((fail + 1))
else
	CODETRACER_SRC="${work}/fake-ct2" "${subject}" --require >"${work}/3b.log" 2>&1
	report "a changed first-iteration index upstream FAILS check B" 1 $?
	because "${work}/3b.log" "has DIVERGED from upstream" \
		"the loop-math drift case failed for the wrong reason"
fi

# ── 4. A missing upstream is a SKIP without --require, a failure with it ───
# Driven from a COPY of the script in a tree with no `../codetracer` sibling.
# Pointing $CODETRACER_SRC at nothing is not enough: the subject falls back to
# the sibling and this repository has one, so the case would pass by finding the
# real upstream — the "check that cannot fail" shape again.
mkdir -p "${work}/isolated/ci/test" "${work}/isolated/client/src/debugger"
cp "${subject}" "${work}/isolated/ci/test/"
mirror "${work}/isolated/client/src/debugger/vendor"
cp "${repo_root}/ci/embed-sdk-pin.env" "${work}/isolated/ci/"
isolated="${work}/isolated/ci/test/flow-layout-vendor.sh"
[ -e "${work}/isolated/../codetracer" ] &&
	{
		echo "  [FAILED] the isolated tree has a codetracer sibling after all" >&2
		fail=$((fail + 1))
	}

CODETRACER_SRC="" "${isolated}" >"${work}/4.log" 2>&1
report "no upstream and no --require is a distinct exit 3, never a pass" 3 $?
CODETRACER_SRC="" "${isolated}" --require >"${work}/5.log" 2>&1
report "no upstream WITH --require is a failure, not a skip" 1 $?
because "${work}/4.log" "matches the manifest" "check A did not run in the isolated tree"

echo
if [ "${fail}" -gt 0 ]; then
	echo "FAIL — ${pass} passed, ${fail} failed" >&2
	exit 1
fi
echo "PASS — ${pass}/${pass} cases"
