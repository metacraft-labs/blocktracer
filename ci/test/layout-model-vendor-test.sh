#!/usr/bin/env bash
#
# layout-model-vendor-test.sh — proof that `layout-model-vendor.sh` DECIDES.
#
# Every one of its checks is driven against a deliberately-broken copy and must
# fail, and against the real thing and must pass. Without this, "the vendored
# layout model is checked" would be a claim about a script nobody has ever seen
# say no — which is the shape of the checks this project keeps finding: a suite
# green with its binary missing, a tautological containment assertion, a lint
# blind to the literal it was written for.
#
# TWO OF THESE CASES EXIST BECAUSE THE GATE WAS RED BY CONSTRUCTION, and
# neither could have been written against the old script. Case 2c is the
# manifest-vs-pin skew that made part B unanswerable and reddened the
# `viewmodels` job on every SDK bump. Case 3c is the SECOND vendored file:
# `contributed_pane_id.nim` used to be reachable by no comparison at all, so a
# drift in it was invisible to everything but a hash.
#
# Needs a CodeTracer checkout ($CODETRACER_SRC or ../codetracer): cases 3a-3c
# are about upstream drift and cannot be simulated without an upstream.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
subject="${repo_root}/ci/test/layout-model-vendor.sh"
vendor_dir="${repo_root}/client/src/debugger/vendor"
manifest="${vendor_dir}/layout_model.vendor.json"

model_rel="frontend/headless_app/layout_model.nim"
pane_rel="common/contributed_pane_id.nim"
model_up="src/frontend/headless_app/layout_model.nim"
pane_up="src/common/contributed_pane_id.nim"

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

# An exit code says a check failed; it does not say WHICH. Every negative case
# below also names the sentence it must have failed on, so a case that goes red
# for an unrelated reason — a missing file, a syntax error — is a MISS rather
# than a pass.
#
# THE NEEDLE HAS TO BE THE ARM'S OWN. Two of them used to be the shared banner
# ("has DIVERGED from upstream") and a bare word ("contributed"), both of which
# another arm's log also satisfies — and an arm whose needle another arm can
# satisfy is not a second arm, it is the first one counted twice. Each needle
# below was checked against every other arm's log and appears in exactly one:
# the injected weight for 3a, `LayoutSchemaVersion` for 3b, the decoder's
# `BadContributedPane` refusal for 3c, and a named file or sentence for 2a-2d.
because() { # logfile needle description
	grep -q "$2" "$1" && return 0
	echo "  [FAILED] $3" >&2
	echo "           expected the log to contain: $2" >&2
	fail=$((fail + 1))
}

# A writable mirror of the real vendor directory, so a case can break one file
# or one manifest field without touching the working tree.
mirror() { # destination
	mkdir -p "$1/$(dirname "${model_rel}")" "$1/$(dirname "${pane_rel}")"
	cp "${vendor_dir}/${model_rel}" "$1/${model_rel}"
	cp "${vendor_dir}/${pane_rel}" "$1/${pane_rel}"
	cp "${manifest}" "$1/layout_model.vendor.json"
	chmod -R u+w "$1"
}

ct=""
if [ -n "${CODETRACER_SRC:-}" ] && [ -e "${CODETRACER_SRC}/${model_up}" ]; then
	ct="${CODETRACER_SRC}"
elif [ -e "${repo_root}/../codetracer/${model_up}" ]; then
	ct="$(cd "${repo_root}/../codetracer" && pwd)"
fi
if [ -z "${ct}" ]; then
	echo "layout-model-vendor-test.sh: no CodeTracer checkout; cannot drive the" >&2
	echo "  drift cases, and a self-test that silently skips its own subject is" >&2
	echo "  the failure mode this file exists to rule out." >&2
	exit 1
fi

echo "=== layout-model-vendor.sh self-test ==="

# ── 1. The real thing passes ───────────────────────────────────────────────
CODETRACER_SRC="${ct}" "${subject}" --require >"${work}/1.log" 2>&1
report "the unmodified vendored copy passes" 0 $?

# ── 2a. An edit to the vendored MODEL is caught (check A) ──────────────────
mirror "${work}/edit"
printf '\n## a helpful local tweak\n' >>"${work}/edit/${model_rel}"
LAYOUT_VENDOR_DIR="${work}/edit" CODETRACER_SRC="${ct}" \
	"${subject}" --require >"${work}/2a.log" 2>&1
report "a local edit to the vendored model FAILS check A" 1 $?
because "${work}/2a.log" "the vendored bytes changed" \
	"check A failed for the wrong reason (model)"
rm -rf "${work}/edit"

# ── 2b. An edit to the SECOND vendored file is caught too ──────────────────
# The manifest lists two files and the digests are matched in document order;
# this is what proves the second entry is compared against the second file
# rather than both entries against the first.
mirror "${work}/edit2"
printf '\n## a helpful local tweak\n' >>"${work}/edit2/${pane_rel}"
LAYOUT_VENDOR_DIR="${work}/edit2" CODETRACER_SRC="${ct}" \
	"${subject}" --require >"${work}/2b.log" 2>&1
report "a local edit to contributed_pane_id FAILS check A" 1 $?
because "${work}/2b.log" "contributed_pane_id.nim" \
	"check A named the wrong file"
rm -rf "${work}/edit2"

# ── 2c. A manifest that lost an entry FAILS rather than checking one ───────
mirror "${work}/short"
python3 - "${work}/short/layout_model.vendor.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["files"] = d["files"][:1]
json.dump(d, open(p, "w"), indent=2)
PY
LAYOUT_VENDOR_DIR="${work}/short" CODETRACER_SRC="${ct}" \
	"${subject}" --require >"${work}/2c.log" 2>&1
report "a manifest missing a file FAILS rather than checking one" 1 $?
because "${work}/2c.log" "expected 2" "the short manifest failed for the wrong reason"
rm -rf "${work}/short"

# ── 2d. A manifest naming a commit other than the Embed SDK pin is caught ──
# THIS IS THE CASE THE GATE EXISTED WITHOUT. Part B compares the copy against
# $CODETRACER_SRC, which is the pin; a manifest pinned elsewhere makes part B
# unanswerable and the `viewmodels` job red on every SDK bump regardless of
# whether this module moved. That was the live state until 2026-09-17.
mirror "${work}/skew"
sed -i.bak 's/"commit": "[0-9a-f]*"/"commit": "0000000000000000000000000000000000000000"/' \
	"${work}/skew/layout_model.vendor.json"
LAYOUT_VENDOR_DIR="${work}/skew" CODETRACER_SRC="${ct}" \
	"${subject}" --require >"${work}/2d.log" 2>&1
report "a manifest commit that is not the SDK pin FAILS" 1 $?
because "${work}/2d.log" "different commits" "the pin-skew case failed for the wrong reason"
rm -rf "${work}/skew"

# ── 3a. A structural change upstream is caught (check B) ───────────────────
# The vendored files and their manifest are consistent; what moves is UPSTREAM.
# A weight change is the smallest edit that alters what a renderer draws and
# leaves every enum, every title and every pane set identical — so it is
# exactly the drift a byte comparison would catch for the wrong reason and a
# shallow value comparison would miss.
fake() { # destination model_source
	mkdir -p "$1/$(dirname "${model_up}")" "$1/$(dirname "${pane_up}")"
	cp "$2" "$1/${model_up}"
	cp "${ct}/${pane_up}" "$1/${pane_up}"
	chmod -R u+w "$1"
}
mkdir -p "${work}/fake-a/$(dirname "${model_up}")"
sed 's/pane(paneEditor, "Editor", weight = 3.0)/pane(paneEditor, "Editor", weight = 7.0)/' \
	"${ct}/${model_up}" >"${work}/weighted.nim"
if cmp -s "${ct}/${model_up}" "${work}/weighted.nim"; then
	echo "  [FAILED] the weight probe changed nothing — the sed no longer matches" >&2
	fail=$((fail + 1))
else
	fake "${work}/fake-a" "${work}/weighted.nim"
	CODETRACER_SRC="${work}/fake-a" "${subject}" --require >"${work}/3a.log" 2>&1
	report "a changed weight upstream FAILS check B" 1 $?
	because "${work}/3a.log" '"title":"Editor","weight":7.0' \
		"check B failed for the wrong reason (weight)"
fi
rm -rf "${work}/fake-a"

# ── 3b. A SCHEMA VERSION bump upstream is caught ───────────────────────────
# This is the divergence class that was invisible for as long as part B could
# not compile the upstream file: the probe reported "the conformance probe
# failed", which reads like a broken script rather than like a moved schema.
sed 's/^  LayoutSchemaVersion\* = 3/  LayoutSchemaVersion* = 4/' \
	"${ct}/${model_up}" >"${work}/versioned.nim"
if cmp -s "${ct}/${model_up}" "${work}/versioned.nim"; then
	echo "  [FAILED] the version probe changed nothing — the sed no longer matches" >&2
	fail=$((fail + 1))
else
	fake "${work}/fake-b" "${work}/versioned.nim"
	CODETRACER_SRC="${work}/fake-b" "${subject}" --require >"${work}/3b.log" 2>&1
	report "a bumped LayoutSchemaVersion upstream FAILS check B" 1 $?
	because "${work}/3b.log" "LayoutSchemaVersion" \
		"check B failed for the wrong reason (schema version)"
fi
rm -rf "${work}/fake-b"

# ── 3c. A drift in the SECOND file is caught by BEHAVIOUR, not only by hash ─
# `contributed_pane_id.nim` decides which qualified ids the decoder accepts.
# Narrowing the charset is a change no comparison of `layout_model.nim`'s own
# types or constructors would notice; comparison 7 of the probe is what sees
# it, and this case is the proof that it does.
mkdir -p "${work}/fake-c/$(dirname "${model_up}")" \
	"${work}/fake-c/$(dirname "${pane_up}")"
cp "${ct}/${model_up}" "${work}/fake-c/${model_up}"
sed "s/c in {'a' \.\. 'z'}/c in {'b' .. 'z'}/" "${ct}/${pane_up}" \
	>"${work}/fake-c/${pane_up}"
chmod -R u+w "${work}/fake-c"
if cmp -s "${ct}/${pane_up}" "${work}/fake-c/${pane_up}"; then
	echo "  [FAILED] the charset probe changed nothing — the sed no longer matches" >&2
	echo "           contributed_pane_id.nim's charset is no longer spelled that way;" >&2
	echo "           re-aim this case rather than deleting it, or the second vendored" >&2
	echo "           file goes back to being hash-only." >&2
	fail=$((fail + 1))
else
	CODETRACER_SRC="${work}/fake-c" "${subject}" --require >"${work}/3c.log" 2>&1
	report "a narrowed contributed-id charset upstream FAILS check B" 1 $?
	because "${work}/3c.log" "BadContributedPane" \
		"check B failed for the wrong reason (contributed id grammar)"
fi
rm -rf "${work}/fake-c"

# ── 4. A missing upstream is a SKIP without --require, a failure with it ───
# Driven from a COPY of the script in a tree with no `../codetracer` sibling.
# Pointing $CODETRACER_SRC at nothing is not enough: the subject falls back to
# the sibling, and this repository has one — so the case would have passed by
# finding the real upstream, which is the "check that cannot fail" shape again.
mkdir -p "${work}/isolated/ci/test"
cp "${subject}" "${work}/isolated/ci/test/"
mirror "${work}/isolated/client/src/debugger/vendor"
cp "${repo_root}/ci/embed-sdk-pin.env" "${work}/isolated/ci/"
isolated="${work}/isolated/ci/test/layout-model-vendor.sh"
[ -e "${work}/isolated/../codetracer" ] &&
	{ echo "  [FAILED] the isolated tree has a codetracer sibling after all" >&2
	  fail=$((fail + 1)); }

CODETRACER_SRC="" "${isolated}" >"${work}/4.log" 2>&1
report "no upstream and no --require is a distinct exit 3, never a pass" 3 $?
CODETRACER_SRC="" "${isolated}" --require >"${work}/5.log" 2>&1
report "no upstream WITH --require is a failure, not a skip" 1 $?
because "${work}/4.log" "matches the manifest" \
	"check A did not run in the isolated tree"

echo
if [ "${fail}" -gt 0 ]; then
	echo "FAIL — ${pass} passed, ${fail} failed" >&2
	exit 1
fi
echo "PASS — ${pass}/${pass} cases"
