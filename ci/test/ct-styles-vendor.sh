#!/usr/bin/env bash
#
# ct-styles-vendor.sh — keep the vendored copies of CodeTracer's component
# stylesheets honest.
#
# `client/src/debugger/vendor/frontend/styles/components/*.styl` are
# byte-verbatim copies of six files from CodeTracer's own
# `src/frontend/styles/components/`, and `../ct_styles.vendor.json` records
# where they came from and why they are copies. They are the rules that DRAW a
# CodeTracer window — the tab strip, the connectors, the panel surface, the
# splitters, the buttons, the inputs, the rows, the empty states, the alerts —
# and `client/src/design_system/ct_styl.nim` compiles them into the stylesheet
# this site serves. A copy with no check is a fork nobody has noticed yet, so —
# in exactly the shape `flow-layout-vendor.sh` and `layout-model-vendor.sh`
# use, because three conventions for one idea is two extra things to learn:
#
#   A. LOCAL INTEGRITY (always runs, needs nothing but this repository)
#      All six files still hash to the sha256s in the manifest, and the
#      manifest's commit EQUALS `ci/embed-sdk-pin.env`'s CODETRACER_REF. An
#      edit here — a helpful tweak, a merge, a formatter — fails.
#
#   B. BYTE CONFORMANCE (needs a CodeTracer checkout)
#      Each file is compared byte for byte with its upstream path.
#
# ── WHY PART B IS A BYTE COMPARISON AND THE OTHER TWO GATES' IS NOT ────────
#
# The two Nim manifests compare by VALUE and say so at length: their files are
# allowed to differ in prose, and a byte comparison against a moving checkout
# would fail for a reworded comment, which is how a check gets switched off.
#
# Neither half of that reasoning holds for a stylesheet. There is no
# "observable" to compare short of the compiled CSS, and the comparison here is
# not against a moving checkout — it is against THE PIN, which is a fixed
# commit this repository names. A byte comparison against a fixed commit has no
# false positive: it is red exactly when somebody edited the copy or moved the
# pin without re-vendoring, and both of those are the thing to catch.
#
# Prose is not inert here either, which is the second reason. `ct_styl.nim`
# strips comments, but a comment is where upstream records WHY a rule is the
# way it is, and the port's whole claim is that a rule in the shipped CSS can
# be traced to an upstream rule. A copy whose comments have drifted still
# compiles to the same bytes and has stopped being traceable.
#
# ── WHY THE COMMIT IS THE EMBED SDK PIN ───────────────────────────────────
#
# Same reason `flow-layout-vendor.sh` gives for its own, and the reason
# `layout-model-vendor.sh`'s header records at length as a defect it once had:
# a manifest pinned to one commit while part B compares against another asks a
# question with no passable answer, and reddens on every SDK bump whether or
# not the files moved. Part A asserts the equality, so moving the pin without
# re-vendoring fails BY NAME rather than failing part B for a reason that is
# not about these files at all.
#
# Exit codes:
#   0  every check that could run, passed
#   1  a check failed
#   3  no CodeTracer checkout for part B, and --require was not given

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require=0
[ "${1:-}" = "--require" ] && require=1

# Overridable so that `ct-styles-vendor-test.sh` can drive this script against
# deliberately-broken copies. Nothing else sets them: a check whose own failure
# path has never been executed is a check nobody has reason to believe.
vendor_dir="${CT_STYLES_VENDOR_DIR:-${repo_root}/client/src/debugger/vendor}"
manifest="${CT_STYLES_VENDOR_MANIFEST:-${vendor_dir}/ct_styles.vendor.json}"
pin_file="${CT_STYLES_PIN_FILE:-${repo_root}/ci/embed-sdk-pin.env}"
# The sibling-checkout fallback, overridable for the same reason as the rest:
# `ct-styles-vendor-test.sh` has to be able to drive the no-checkout branch,
# and on a developer machine a real `../codetracer` is exactly what makes that
# branch unreachable.
ct_fallback="${CT_STYLES_CT_FALLBACK:-${repo_root}/../codetracer}"

# The eight, in `codetracer.styl`'s own import order — which is the order
# `ct_components_css.nim` compiles them in, and therefore the cascade the
# shipped page has. Listed here as well so a file added to the port without
# being added to the manifest fails the count below.
rels=(
	"frontend/styles/components/button.styl"
	"frontend/styles/components/input.styl"
	"frontend/styles/components/tab.styl"
	"frontend/styles/components/notifications.styl"
	"frontend/styles/components/shared_widgets.styl"
	"frontend/styles/components/data_tables.styl"
	"frontend/styles/components/golden_layout.styl"
	"frontend/styles/components/empty_states.styl"
)

fail() {
	echo "ct-styles-vendor.sh: $*" >&2
	exit 1
}

digest() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		fail "neither sha256sum nor shasum is available; cannot verify the copy"
	fi
}

echo "=== the vendored CodeTracer component stylesheets ==="

# ---------------------------------------------------------------------------
# A. Local integrity
# ---------------------------------------------------------------------------

[ -f "${manifest}" ] || fail "the vendor manifest is missing: ${manifest}"

# Read with grep rather than a JSON parser, for the reason the sibling gates
# give: this must run on a bare CI runner with nothing installed beyond a shell
# and Nim. The manifest lists the files in the same order as `rels` above, and
# the COUNT is checked — which is what stops a manifest that lost an entry from
# passing by having nothing to compare.
mapfile -t recorded < <(grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' \
	"${manifest}" | grep -oE '[0-9a-f]{64}')
[ "${#recorded[@]}" -eq "${#rels[@]}" ] ||
	fail "the manifest records ${#recorded[@]} sha256 entries; expected ${#rels[@]}"

# …and that the manifest names them in the order this script expects, so the
# digests below are matched against the right files. A manifest that listed the
# same six in a different order would otherwise compare each against another's
# hash and fail with six confusing messages instead of one clear one.
mapfile -t recorded_locals < <(grep -oE '"local"[[:space:]]*:[[:space:]]*"[^"]+"' \
	"${manifest}" | sed -E 's/.*"local"[[:space:]]*:[[:space:]]*"([^"]+)"/\1/')
i=0
for rel in "${rels[@]}"; do
	[ "${recorded_locals[$i]}" = "${rel}" ] ||
		fail "manifest entry $((i + 1)) is '${recorded_locals[$i]}'; expected '${rel}'"
	i=$((i + 1))
done

i=0
for rel in "${rels[@]}"; do
	file="${vendor_dir}/${rel}"
	[ -f "${file}" ] || fail "the vendored stylesheet is missing: ${file}"
	have="$(digest "${file}")"
	want="${recorded[$i]}"
	if [ "${have}" != "${want}" ]; then
		echo "--- A: ${rel} does not match the manifest" >&2
		echo "    recorded: ${want}" >&2
		echo "    on disk:  ${have}" >&2
		echo "  This file is a verbatim copy of CodeTracer's. Editing it here" >&2
		echo "  forks the two products' chrome silently — which is the exact" >&2
		echo "  divergence the port exists to end. Change it upstream and" >&2
		echo "  re-vendor, or drop the rule in ct_components_css.nim's" >&2
		echo "  \`Dropped\` table, where the reason is recorded." >&2
		exit 1
	fi
	i=$((i + 1))
done
echo "--- A: ${#rels[@]} stylesheet(s) match their manifest digests"

pinned=""
if [ -f "${pin_file}" ]; then
	pinned="$(grep -oE '^CODETRACER_REF=[0-9a-f]+' "${pin_file}" | cut -d= -f2)"
fi
vendored_commit="$(grep -oE '"commit"[[:space:]]*:[[:space:]]*"[0-9a-f]+"' \
	"${manifest}" | grep -oE '[0-9a-f]{7,}')"
[ -n "${vendored_commit}" ] || fail "the manifest records no commit"
[ -n "${pinned}" ] || fail "no CODETRACER_REF in ${pin_file}"
if [ "${pinned}" != "${vendored_commit}" ]; then
	echo "--- A: the vendor manifest and the Embed SDK pin name different commits" >&2
	echo "    ci/embed-sdk-pin.env: ${pinned}" >&2
	echo "    vendor manifest:      ${vendored_commit}" >&2
	echo "  One commit, so the version the handoff compiles against and the" >&2
	echo "  version the chrome is drawn from can never be two different" >&2
	echo "  things. Moving the pin means re-vendoring these files in the" >&2
	echo "  same commit." >&2
	exit 1
fi
echo "--- A: manifest commit == Embed SDK pin (${pinned:0:12}…)"

# ---------------------------------------------------------------------------
# B. Byte conformance against a real CodeTracer checkout
# ---------------------------------------------------------------------------

# golden_layout.styl is the probe: it is the file whose absence means the
# checkout is not a CodeTracer tree at all.
probe_up="src/frontend/styles/components/golden_layout.styl"

ct=""
if [ -n "${CODETRACER_SRC:-}" ] && [ -e "${CODETRACER_SRC}/${probe_up}" ]; then
	ct="${CODETRACER_SRC}"
elif [ -e "${ct_fallback}/${probe_up}" ]; then
	ct="$(cd "${ct_fallback}" && pwd)"
fi

if [ -z "${ct}" ]; then
	echo "--- B: SKIPPED — no CodeTracer checkout" >&2
	echo "    Looked for ${probe_up} under \$CODETRACER_SRC and" >&2
	echo "    ${ct_fallback}" >&2
	if [ "${require}" -eq 1 ]; then
		echo "ct-styles-vendor.sh: --require was given, so this is a failure" >&2
		exit 1
	fi
	exit 3
fi

# THE CHECKOUT IS RESOLVED TO THE PIN, not read at whatever it is sitting on.
# `$CODETRACER_SRC` is a working tree and part B is a byte comparison, so a
# sibling checkout on another branch would report six divergences that are
# nothing to do with this repository. If the tree is a git repository that has
# the pinned commit, the comparison is against that commit's bytes; otherwise
# it is against the tree, and the message says which was used.
compare_src="working tree"
tmp=""
if git -C "${ct}" cat-file -e "${pinned}^{commit}" 2>/dev/null; then
	tmp="$(mktemp -d "${TMPDIR:-/tmp}/ct-styles-vendor.XXXXXX")"
	trap 'rm -rf "${tmp}"' EXIT
	compare_src="commit ${pinned:0:12}…"
fi

echo "--- B: comparing against ${ct} (${compare_src})"

failed=0
for rel in "${rels[@]}"; do
	up="src/${rel}"
	if [ -n "${tmp}" ]; then
		mkdir -p "$(dirname "${tmp}/${rel}")"
		if ! git -C "${ct}" show "${pinned}:${up}" >"${tmp}/${rel}" 2>/dev/null; then
			echo "    ${rel}: not present at the pinned commit" >&2
			failed=1
			continue
		fi
		other="${tmp}/${rel}"
	else
		other="${ct}/${up}"
		[ -f "${other}" ] || {
			echo "    ${rel}: not present upstream" >&2
			failed=1
			continue
		}
	fi
	if ! diff -q "${vendor_dir}/${rel}" "${other}" >/dev/null; then
		echo "    ${rel}: DIFFERS from upstream" >&2
		diff -u "${vendor_dir}/${rel}" "${other}" | head -40 >&2
		failed=1
	fi
done

if [ "${failed}" -ne 0 ]; then
	echo "--- B: the copies and upstream disagree" >&2
	echo "  Upstream moved, or somebody edited a copy. Re-vendor from the" >&2
	echo "  pinned commit and read the diff: a change to golden_layout.styl" >&2
	echo "  is a change to how both products' tab bars look." >&2
	exit 1
fi
echo "--- B: ${#rels[@]} stylesheet(s) are byte-identical to upstream"
echo "=== the vendored CodeTracer component stylesheets: OK"
