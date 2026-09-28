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
	echo "${dir}"
}

echo "=== ct-styles-vendor.sh, driven through its failure paths ==="

# 1. THE CONTROL. An untouched copy passes part A and skips part B.
run_case "an untouched copy passes part A" 3 \
	"stylesheet(s) match their manifest digests" "$(fresh control)"

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
d="$(fresh short-manifest)"
python3 - "${d}/ct_styles.vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
m = json.load(open(p))
m["files"] = m["files"][:-1]
json.dump(m, open(p, "w"), indent=2)
PY
run_case "a manifest that lost an entry fails" 1 \
	"the manifest records 5 sha256 entries" "${d}"

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
