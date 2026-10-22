#!/usr/bin/env bash
#
# ct-styles-vendor-test.sh — drive `ct-styles-vendor.sh` through every way it
# can say no, and one way it must say yes.
#
# A check whose failure path has never been executed is a check nobody has
# reason to believe. This is the same argument `layout-model-vendor-test.sh`
# makes for its own gate, and the same shape: copy the real vendor tree into a
# scratch directory, break it one way at a time, and assert the gate's exit
# code AND the sentence it prints — a gate that fails for the wrong reason is
# a gate that will pass for the wrong reason next time.
#
# Exit codes: 0 every case behaved, 1 one did not.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
gate="${repo_root}/ci/test/ct-styles-vendor.sh"
real_vendor="${repo_root}/client/src/debugger/vendor"

work="$(mktemp -d "${TMPDIR:-/tmp}/ct-styles-vendor-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

fails=0
cases=0

# Part A only: no CodeTracer checkout is visible to these runs, so the gate
# reaches part B, finds nothing and exits 3 — which is the PASS code for the
# cases below that expect part A to be happy. The cases that expect a part A
# failure exit 1 before ever reaching it.
run_case() {
	local name="$1" want_code="$2" want_text="$3" dir="$4"
	cases=$((cases + 1))
	local out
	out="$(CT_STYLES_VENDOR_DIR="${dir}" \
		CT_STYLES_VENDOR_MANIFEST="${dir}/ct_styles.vendor.json" \
		CT_STYLES_PIN_FILE="${CASE_PIN_FILE:-${repo_root}/ci/embed-sdk-pin.env}" \
		CODETRACER_SRC="${work}/no-such-checkout" \
		CT_STYLES_CT_FALLBACK="${work}/no-such-checkout" \
		"${gate}" 2>&1)"
	local code=$?
	if [ "${code}" -ne "${want_code}" ]; then
		echo "FAIL ${name}: exit ${code}, expected ${want_code}"
		echo "${out}" | sed 's/^/     /'
		fails=$((fails + 1))
		return
	fi
	if [ -n "${want_text}" ] && ! grep -F -- "${want_text}" <<<"${out}" >/dev/null; then
		echo "FAIL ${name}: exit code was right but the message was not"
		echo "     expected to contain: ${want_text}"
		echo "${out}" | sed 's/^/     /'
		fails=$((fails + 1))
		return
	fi
	echo "ok   ${name}"
}

fresh() {
	local dir="${work}/$1"
	rm -rf "${dir}"
	mkdir -p "${dir}"
	cp "${real_vendor}/ct_styles.vendor.json" "${dir}/"
	mkdir -p "${dir}/frontend/styles/components"
	cp "${real_vendor}"/frontend/styles/components/*.styl \
		"${dir}/frontend/styles/components/"
	# THE SET IS NOT ONLY STYLESHEETS ANY MORE, and a fixture that omitted the
	# ninth file made every case below fail for the WRONG reason: the gate
	# reported `debug_control_marks.nim` missing and exited before reaching the
	# edited copy, the moved pin or the lost manifest entry each case plants.
	# Three cases went red together and none of them was about its own subject.
	mkdir -p "${dir}/frontend/viewmodel/views"
	cp "${real_vendor}"/frontend/viewmodel/views/*.nim \
		"${dir}/frontend/viewmodel/views/"
	echo "${dir}"
}

echo "=== ct-styles-vendor.sh, driven through its failure paths ==="

# 1. THE CONTROL. An untouched copy passes part A and skips part B.
#
# The expected text is `file(s)` and not `stylesheet(s)`: the set gained
# `debug_control_marks.nim`, the gate's own lines were reworded to match, and
# THIS CASE IS WHAT NOTICED — it asserts the sentence the gate prints, so a
# gate whose wording drifts from its subject fails here rather than going on
# describing a set it no longer has.
run_case "an untouched copy passes part A" 3 \
	"file(s) match their manifest digests" "$(fresh control)"

# 2. An edit to a copy — the defect the whole gate exists for.
d="$(fresh edited)"
printf '\n.lm_tab{color:red}\n' >>"${d}/frontend/styles/components/golden_layout.styl"
run_case "an edited copy fails, by name" 1 \
	"golden_layout.styl does not match the manifest" "${d}"

# 3. A copy deleted outright.
d="$(fresh deleted)"
rm "${d}/frontend/styles/components/input.styl"
run_case "a missing copy fails" 1 "the vendored stylesheet is missing" "${d}"

# 4. A manifest that lost an entry. This is the case a naive gate passes by
#    having nothing to compare, which is why the count is checked.
#
# THE EXPECTED NUMBER IS DERIVED, NOT WRITTEN. It used to read "5 sha256
# entries", which was the answer when six stylesheets were vendored. Eight are
# vendored now, so the perturbation produces seven and this arm failed with
# "exit code was right but the message was not" -- the gate biting correctly
# and the test disagreeing about the wording. It had been red since the seventh
# stylesheet landed and nobody saw it: `debug-route` failed at an earlier step,
# so this suite never ran.
#
# A hard-coded count here is a second place the manifest's size is recorded,
# and the manifest is the first. Counting it is what keeps there being one.
d="$(fresh short-manifest)"
python3 - "${d}/ct_styles.vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m["files"] = m["files"][:-1]
json.dump(m, open(p, "w"), indent=2)
PY
# Counted rather than written down: a number typed here went stale the first
# time the vendored set grew. Counted off `${d}` — the copy the block above
# just truncated — rather than off the real manifest minus one, so the
# expectation is read from the artefact the case actually produced and the
# `- 1` cannot drift away from the `[:-1]`.
short_count="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["files"]))' "${d}/ct_styles.vendor.json")"
run_case "a manifest that lost an entry fails" 1 \
	"the manifest records ${short_count} sha256 entries" "${d}"

# 5. A manifest whose entries are in a different order. The digests would
#    otherwise be matched against the wrong files.
d="$(fresh reordered)"
python3 - "${d}/ct_styles.vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m["files"][0], m["files"][1] = m["files"][1], m["files"][0]
json.dump(m, open(p, "w"), indent=2)
PY
run_case "a reordered manifest fails, before any digest is compared" 1 \
	"manifest entry 1 is" "${d}"

# 6. The pin moved and nobody re-vendored — the failure mode that made the
#    sibling layout-model gate red by construction for weeks.
d="$(fresh pin-moved)"
printf 'CODETRACER_REF=%s\n' "0000000000000000000000000000000000000000" \
	>"${work}/moved-pin.env"
CASE_PIN_FILE="${work}/moved-pin.env" run_case \
	"a pin that moved without a re-vendor fails, by name" 1 \
	"name different commits" "${d}"

# 7. --require turns a missing checkout from a skip into a failure, so CI
#    cannot go green on a part B that never ran.
cases=$((cases + 1))
out="$(CT_STYLES_VENDOR_DIR="$(fresh require)" \
	CT_STYLES_VENDOR_MANIFEST="${work}/require/ct_styles.vendor.json" \
	CODETRACER_SRC="${work}/no-such-checkout" \
	CT_STYLES_CT_FALLBACK="${work}/no-such-checkout" \
	"${gate}" --require 2>&1)"
if [ $? -eq 1 ] && grep -F -- "--require was given" <<<"${out}" >/dev/null; then
	echo "ok   --require makes a skipped part B a failure"
else
	echo "FAIL --require did not turn the skip into a failure"
	fails=$((fails + 1))
fi

echo "=== ${cases} case(s), ${fails} failing"
[ "${fails}" -eq 0 ]
