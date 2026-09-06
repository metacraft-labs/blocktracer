#!/usr/bin/env bash
#
# untrusted-text-test.sh — the escaping gate's own test suite.
#
# A gate nobody has watched fail is a gate that might be passing vacuously, and
# this one passes on the current tree by design — which is exactly the state in
# which a broken detector is invisible. So every case below hands
# tools/ci/check-untrusted-text.mjs a page carrying ONE deliberate breakout and
# asserts it is rejected, plus a clean control and an empty control.
#
# The cases are not hypothetical shapes. Each is the exact form the payload in
# tools/ci/hostile-chain-corpus.mjs would take if the corresponding half of the
# boundary were removed:
#
#   element      `text` stops calling escapeHtml           → <btprobe>
#   attribute    `escapeAttr` stops escaping `"`           → " btprobe=1 x="
#   URL scheme   an href is built from a chain string      → javascript:…
#   handler      an on* attribute is emitted from data     → onclick="…"
#   raw-text     the JSON island stops escaping `<`        → </script><btprobe>
#   carriers     the hostile corpus stops being rendered   → --min-carriers
#
# The last case is the one that matters most and the one a checker of this shape
# usually lacks: a run over a site the payload never reached is a PASS that
# measured nothing, and it must be a failure instead.
#
# Usage: ci/test/untrusted-text-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${repo_root}/tools/ci/check-untrusted-text.mjs"

pass=0
fail=0
work="$(mktemp -d "${TMPDIR:-/tmp}/untrusted-text-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

report_pass() {
	pass=$((pass + 1))
	echo "  ok   $1"
}
report_fail() {
	fail=$((fail + 1))
	echo "  FAIL $1" >&2
	[ -n "${2:-}" ] && echo "       $2" >&2
}

# expect <name> <expected-rc> <page-body> [extra checker args...]
expect() {
	local name="$1" want="$2" body="$3"
	shift 3
	local dir="${work}/case-${pass}-${fail}-$RANDOM"
	mkdir -p "${dir}"
	printf '%s' "${body}" >"${dir}/index.html"
	local out
	out="$(node "${checker}" "${dir}" --quiet "$@" 2>&1)"
	local rc=$?
	if [ "${rc}" -eq "${want}" ]; then
		report_pass "${name} (rc=${rc})"
	else
		report_fail "${name}: expected rc=${want}, got rc=${rc}" "${out}"
	fi
}

SHELL_HEAD='<!doctype html><html><head><title>t</title></head><body>'
SHELL_TAIL='</body></html>'

echo "== the five breakouts, each of which must be rejected =="

expect "an injected element" 1 \
	"${SHELL_HEAD}<p>name: <btprobe>x</btprobe></p>${SHELL_TAIL}"

expect "an injected attribute" 1 \
	"${SHELL_HEAD}<span title=\"name\" btprobe=\"1\">x</span>${SHELL_TAIL}"

expect "a javascript: URL" 1 \
	"${SHELL_HEAD}<a href=\"javascript:btprobe()\">open</a>${SHELL_TAIL}"

expect "an event-handler attribute" 1 \
	"${SHELL_HEAD}<div onclick=\"btprobe()\">x</div>${SHELL_TAIL}"

expect "a breakout from the JSON island" 1 \
	"${SHELL_HEAD}<script type=\"application/json\" id=\"i\">{\"p\":\"</script><btprobe>\"}</script>${SHELL_TAIL}"

echo "== the controls, which must NOT be rejected =="

# The exact shape the current tree emits: a contract name inside a
# double-quoted attribute, with `"` and `&` escaped and `<` left alone. This is
# what `grep -F '<btprobe>'` reports as a hit and what a correct checker must
# not. If this case ever fails, the gate has started crying wolf and would be
# deleted within a day — see the header of check-untrusted-text.mjs.
expect "a payload correctly escaped in an attribute value" 0 \
	"${SHELL_HEAD}<span title=\"Published by Foo&lt;btprobe&gt;&quot; btprobe=1 x=&quot;javascript:btprobe()&amp;btprobe;\">x</span>${SHELL_TAIL}"

expect "a payload correctly escaped in a text node" 0 \
	"${SHELL_HEAD}<p>Foo&lt;btprobe&gt;\" btprobe=1 x=\"javascript:btprobe()&amp;btprobe;</p>${SHELL_TAIL}"

expect "a payload inside a JSON island with < escaped" 0 \
	"${SHELL_HEAD}<script type=\"application/json\" id=\"i\">{\"p\":\"\\u003cbtprobe\\u003e\"}</script>${SHELL_TAIL}"

echo "== the vacuity floor: a clean site must not pass as if it were measured =="

expect "a site the payload never reached, with a floor" 3 \
	"${SHELL_HEAD}<p>nothing hostile here</p>${SHELL_TAIL}" --min-carriers 1

expect "…and the same site with no floor is simply clean" 0 \
	"${SHELL_HEAD}<p>nothing hostile here</p>${SHELL_TAIL}"

echo
if [ "${fail}" -eq 0 ]; then
	echo "untrusted-text-test.sh: ${pass} passed"
	exit 0
fi
echo "untrusted-text-test.sh: ${pass} passed, ${fail} FAILED" >&2
exit 1
