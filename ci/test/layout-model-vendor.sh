#!/usr/bin/env bash
#
# layout-model-vendor.sh — keep the vendored copy of CodeTracer's layout model
# honest.
#
# `client/src/debugger/layout_model.nim` is a verbatim copy of CodeTracer's
# `src/frontend/headless_app/layout_model.nim`; `layout_model.vendor.json`
# beside it records where it came from and why it is a copy rather than an
# import. A copy with no check is a fork nobody has noticed yet, so:
#
#   A. LOCAL INTEGRITY (always runs, needs nothing but this repository)
#      The vendored bytes still hash to the sha256 in the manifest. An edit
#      here — a helpful tweak, a merge, a formatter — fails.
#
#   B. STRUCTURAL CONFORMANCE (needs a CodeTracer checkout)
#      A probe imports BOTH modules and compares what a consumer of either one
#      would observe: the serialised `defaultReplayLayout()`, `allPanes`,
#      `visiblePanes`, the pane enum's spellings, and `validate`'s verdict on a
#      deliberately malformed tree. A structural change upstream fails here
#      rather than leaving BlockTracer arranging panes to a shape no other
#      front-end has.
#
#      Compared by VALUE, not by text. The two files are allowed to differ in
#      prose and in the NAME of the five-pane constant — at the Embed SDK pin
#      it is `BlockTracerPanes` and on upstream mainline it is
#      `ReplayCorePanes` — and neither difference changes a layout. A byte
#      comparison against a moving checkout would fail for a renamed comment,
#      which is how a check gets switched off.
#
# Exit codes:
#   0  every check that could run, passed
#   1  a check failed
#   3  no CodeTracer checkout for part B, and --require was not given

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require=0
[ "${1:-}" = "--require" ] && require=1

# The two paths are overridable so that `layout-model-vendor-test.sh` can drive
# this script against deliberately-broken copies. Nothing else sets them: a
# check whose own failure path has never been executed is a check nobody has
# reason to believe.
vendored="${LAYOUT_VENDOR_FILE:-${repo_root}/client/src/debugger/layout_model.nim}"
manifest="${LAYOUT_VENDOR_MANIFEST:-${repo_root}/client/src/debugger/layout_model.vendor.json}"

fail() { echo "layout-model-vendor.sh: $*" >&2; exit 1; }

echo "=== the vendored layout model ==="

# ---------------------------------------------------------------------------
# A. Local integrity
# ---------------------------------------------------------------------------

[ -f "${vendored}" ] || fail "the vendored module is missing: ${vendored}"
[ -f "${manifest}" ] || fail "the vendor manifest is missing: ${manifest}"

# Read with grep rather than a JSON parser: this script must run on a bare CI
# runner with nothing installed beyond a shell and Nim, and one field out of a
# four-line manifest does not justify a dependency.
recorded="$(grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' "${manifest}" |
	grep -oE '[0-9a-f]{64}')"
[ -n "${recorded}" ] || fail "the manifest records no sha256"

# `sha256sum` on Linux, `shasum -a 256` on darwin. Not interchangeable names,
# and a missing one must be a failure rather than an empty digest that compares
# unequal for the wrong reason.
if command -v sha256sum >/dev/null 2>&1; then
	actual="$(sha256sum "${vendored}" | cut -d' ' -f1)"
elif command -v shasum >/dev/null 2>&1; then
	actual="$(shasum -a 256 "${vendored}" | cut -d' ' -f1)"
else
	fail "neither sha256sum nor shasum is available; cannot verify the copy"
fi
if [ "${actual}" != "${recorded}" ]; then
	echo "--- A: the vendored bytes changed" >&2
	echo "    recorded: ${recorded}" >&2
	echo "    actual:   ${actual}" >&2
	echo "  A vendored copy is not a place to make edits. Change it upstream," >&2
	echo "  re-vendor, and update ${manifest#"${repo_root}/"}." >&2
	exit 1
fi
echo "--- A: vendored bytes match the manifest (${recorded:0:12}…)"

# ---------------------------------------------------------------------------
# B. Structural conformance against a real CodeTracer checkout
# ---------------------------------------------------------------------------

ct=""
if [ -n "${CODETRACER_SRC:-}" ] &&
	[ -e "${CODETRACER_SRC}/src/frontend/headless_app/layout_model.nim" ]; then
	ct="${CODETRACER_SRC}"
elif [ -e "${repo_root}/../codetracer/src/frontend/headless_app/layout_model.nim" ]; then
	ct="$(cd "${repo_root}/../codetracer" && pwd)"
fi

if [ -z "${ct}" ]; then
	echo "--- B: SKIPPED — no CodeTracer checkout" >&2
	echo "    Looked for src/frontend/headless_app/layout_model.nim under" >&2
	echo "    \$CODETRACER_SRC and ${repo_root}/../codetracer" >&2
	if [ "${require}" -eq 1 ]; then
		echo "layout-model-vendor.sh: --require was given, so this is a failure" >&2
		exit 1
	fi
	exit 3
fi

echo "--- B: comparing against ${ct}"

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/layout-vendor.XXXXXX")"
trap 'rm -rf "${probe_dir}"' EXIT

cat >"${probe_dir}/conformance.nim" <<EOF
## Both modules, side by side. Every comparison is of a VALUE a consumer of
## either module would observe, so prose and constant NAMES may differ and a
## structural change may not.
import std/[json, strutils]
import vendored/layout_model as vend
import upstream/layout_model as up

var problems: seq[string]
proc want(name: string; a, b: string) =
  if a != b:
    problems.add name & ":\n    vendored: " & a & "\n    upstream: " & b

# 1. The default arrangement, serialised. Shape, weights, titles, active tab.
want("defaultReplayLayout()", \$vend.saveLayout(vend.defaultReplayLayout()),
                              \$up.saveLayout(up.defaultReplayLayout()))

# 2. The pane sets a consumer walks, in order.
want("allPanes", \$vend.allPanes(vend.defaultReplayLayout()),
                 \$up.allPanes(up.defaultReplayLayout()))
want("visiblePanes", \$vend.visiblePanes(vend.defaultReplayLayout()),
                     \$up.visiblePanes(up.defaultReplayLayout()))

# 3. The enum spellings, which are what a saved layout is written in.
var vendPanes, upPanes: seq[string]
for p in vend.PaneKind: vendPanes.add \$p
for p in up.PaneKind: upPanes.add \$p
want("PaneKind spellings", vendPanes.join(","), upPanes.join(","))
var vendKinds, upKinds: seq[string]
for k in vend.LayoutNodeKind: vendKinds.add \$k
for k in up.LayoutNodeKind: upKinds.add \$k
want("LayoutNodeKind spellings", vendKinds.join(","), upKinds.join(","))
want("LayoutSchemaVersion", \$vend.LayoutSchemaVersion, \$up.LayoutSchemaVersion)

# 4. The validator's verdict on a deliberately malformed tree — the half that
#    would not move if only the constructors were compared.
let vendBad = vend.row([vend.pane(vend.paneEditor), vend.pane(vend.paneEditor)])
let upBad = up.row([up.pane(up.paneEditor), up.pane(up.paneEditor)])
want("validate(duplicate pane)", \$vend.validate(vendBad), \$up.validate(upBad))
doAssert vend.validate(vendBad).len > 0, "the malformed probe is not malformed"

# 5. A round trip through the serialised form, cross-decoded: what the vendored
#    module writes, the upstream module must read back to the same tree.
let crossed = up.restoreLayout(vend.saveLayout(vend.defaultReplayLayout()))
want("cross-decoded default", \$up.saveLayout(crossed),
                              \$up.saveLayout(up.defaultReplayLayout()))

if problems.len > 0:
  echo "the vendored layout model has DIVERGED from upstream:"
  for p in problems: echo "  - " & p
  quit 1
echo "layout-model-vendor: vendored and upstream agree on every observable"
EOF

mkdir -p "${probe_dir}/vendored" "${probe_dir}/upstream"
cp "${vendored}" "${probe_dir}/vendored/layout_model.nim"
cp "${ct}/src/frontend/headless_app/layout_model.nim" \
	"${probe_dir}/upstream/layout_model.nim"

if ! nim c -r --hints:off --warnings:off \
	--nimcache:"${probe_dir}/nimcache" -o:"${probe_dir}/conformance" \
	"${probe_dir}/conformance.nim"; then
	fail "the conformance probe failed"
fi
