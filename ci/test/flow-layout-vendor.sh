#!/usr/bin/env bash
#
# flow-layout-vendor.sh — keep the vendored copy of CodeTracer's Omniscience
# layout arithmetic honest.
#
# `client/src/debugger/vendor/frontend/**` holds byte-verbatim copies of
# CodeTracer's `src/frontend/viewmodel/viewmodels/flow_layout.nim` and the
# `src/frontend/ui/flow_loop_math.nim` it imports;
# `client/src/debugger/vendor/flow_layout.vendor.json` records where they came
# from and why they are copies. A copy with no check is a fork nobody has
# noticed yet, so — exactly as `layout-model-vendor.sh` does for the layout
# model:
#
#   A. LOCAL INTEGRITY (always runs, needs nothing but this repository)
#      Both vendored files still hash to the sha256s in the manifest. An edit
#      here — a helpful tweak, a merge, a formatter — fails.
#
#   B. STRUCTURAL CONFORMANCE (needs a CodeTracer checkout)
#      A probe imports BOTH copies of both modules and compares what a consumer
#      of either would observe over the SAME inputs: `computeFlowLayout` on a
#      loop window, `assignExpressionColumns`, `orderExpressionsByColumn`,
#      `resolveFlowValueModeForText`, `sourceIndentLevel`,
#      `tokenizeSourceExpressions`, `computeLoopColumnPlan` and
#      `activeIterationForTicks`. A change upstream fails here rather than
#      leaving BlockTracer placing labels to an arithmetic nobody else uses.
#
#      Compared by VALUE, not by text, for the same reason the layout model is:
#      the two files are allowed to differ in prose, and a byte comparison
#      against a moving checkout fails for a reworded comment, which is how a
#      check gets switched off.
#
# WHY THIS MATTERS MORE THAN A NORMAL VENDOR CHECK. The static export and the
# hydration bundle place labels with the SAME arithmetic — the export through
# this copy, the bundle through this copy as well — and the whole claim of the
# debug route is that a hydrated frame and a served frame at one position are
# the same markup. A copy that had drifted from upstream would not break that;
# what it would break is the other claim, that the value beside an expression
# is the value CodeTracer would put there.
#
# Exit codes:
#   0  every check that could run, passed
#   1  a check failed
#   3  no CodeTracer checkout for part B, and --require was not given

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require=0
[ "${1:-}" = "--require" ] && require=1

# Overridable so that `flow-layout-vendor-test.sh` can drive this script against
# deliberately-broken copies. Nothing else sets them: a check whose own failure
# path has never been executed is a check nobody has reason to believe.
vendor_dir="${FLOW_VENDOR_DIR:-${repo_root}/client/src/debugger/vendor}"
manifest="${FLOW_VENDOR_MANIFEST:-${vendor_dir}/flow_layout.vendor.json}"

layout_rel="frontend/viewmodel/viewmodels/flow_layout.nim"
math_rel="frontend/ui/flow_loop_math.nim"
layout_up="src/frontend/viewmodel/viewmodels/flow_layout.nim"
math_up="src/frontend/ui/flow_loop_math.nim"

fail() {
	echo "flow-layout-vendor.sh: $*" >&2
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

echo "=== the vendored omniscience layout ==="

# ---------------------------------------------------------------------------
# A. Local integrity
# ---------------------------------------------------------------------------

[ -f "${manifest}" ] || fail "the vendor manifest is missing: ${manifest}"

# Read with grep rather than a JSON parser, as the layout-model check does: this
# must run on a bare CI runner with nothing installed beyond a shell and Nim.
# The manifest lists TWO files, so the digests are read in document order and
# matched against the files in the same order — and the count is checked, which
# is what stops a manifest that lost an entry from passing by having nothing to
# compare.
mapfile -t recorded < <(grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' \
	"${manifest}" | grep -oE '[0-9a-f]{64}')
[ "${#recorded[@]}" -eq 2 ] ||
	fail "the manifest records ${#recorded[@]} sha256 entries; expected 2 (${layout_rel}, ${math_rel})"

i=0
for rel in "${layout_rel}" "${math_rel}"; do
	file="${vendor_dir}/${rel}"
	[ -f "${file}" ] || fail "the vendored module is missing: ${file}"
	actual="$(digest "${file}")"
	if [ "${actual}" != "${recorded[$i]}" ]; then
		echo "--- A: the vendored bytes changed — ${rel}" >&2
		echo "    recorded: ${recorded[$i]}" >&2
		echo "    actual:   ${actual}" >&2
		echo "  A vendored copy is not a place to make edits. Change it upstream," >&2
		echo "  re-vendor, and update ${manifest#"${repo_root}/"}." >&2
		exit 1
	fi
	echo "--- A: ${rel} matches the manifest (${actual:0:12}…)"
	i=$((i + 1))
done

# The manifest's commit must equal the Embed SDK pin. These two files are inside
# `src/frontend/viewmodel/`, which IS the tree the pin names, and
# `client/hydrate/` compiles against that tree — so a manifest naming a
# different commit would mean the served page and the hydrated page were laid
# out by two versions of one module.
pin_file="${repo_root}/ci/embed-sdk-pin.env"
if [ -f "${pin_file}" ]; then
	pinned="$(grep -oE '^CODETRACER_REF=[0-9a-f]+' "${pin_file}" | cut -d= -f2)"
	vendored_commit="$(grep -oE '"commit"[[:space:]]*:[[:space:]]*"[0-9a-f]+"' \
		"${manifest}" | grep -oE '[0-9a-f]{7,}')"
	if [ -n "${pinned}" ] && [ -n "${vendored_commit}" ] &&
		[ "${pinned}" != "${vendored_commit}" ]; then
		echo "--- A: the vendor manifest and the Embed SDK pin name different commits" >&2
		echo "    ci/embed-sdk-pin.env: ${pinned}" >&2
		echo "    vendor manifest:      ${vendored_commit}" >&2
		echo "  These two files live in the tree the pin names, and the hydration" >&2
		echo "  bundle compiles against that tree. Two commits means two versions" >&2
		echo "  of one arithmetic laying out one page." >&2
		exit 1
	fi
	echo "--- A: manifest commit == Embed SDK pin (${pinned:0:12}…)"
fi

# ---------------------------------------------------------------------------
# B. Structural conformance against a real CodeTracer checkout
# ---------------------------------------------------------------------------

ct=""
if [ -n "${CODETRACER_SRC:-}" ] && [ -e "${CODETRACER_SRC}/${layout_up}" ]; then
	ct="${CODETRACER_SRC}"
elif [ -e "${repo_root}/../codetracer/${layout_up}" ]; then
	ct="$(cd "${repo_root}/../codetracer" && pwd)"
fi

if [ -z "${ct}" ]; then
	echo "--- B: SKIPPED — no CodeTracer checkout" >&2
	echo "    Looked for ${layout_up} under \$CODETRACER_SRC and" >&2
	echo "    ${repo_root}/../codetracer" >&2
	if [ "${require}" -eq 1 ]; then
		echo "flow-layout-vendor.sh: --require was given, so this is a failure" >&2
		exit 1
	fi
	exit 3
fi

echo "--- B: comparing against ${ct}"

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/flow-layout-vendor.XXXXXX")"
trap 'rm -rf "${probe_dir}"' EXIT

for side in vendored upstream; do
	mkdir -p "${probe_dir}/${side}/frontend/viewmodel/viewmodels" \
		"${probe_dir}/${side}/frontend/ui"
done
cp "${vendor_dir}/${layout_rel}" "${probe_dir}/vendored/${layout_rel}"
cp "${vendor_dir}/${math_rel}" "${probe_dir}/vendored/${math_rel}"
cp "${ct}/${layout_up}" "${probe_dir}/upstream/${layout_rel}"
cp "${ct}/${math_up}" "${probe_dir}/upstream/${math_rel}"

cat >"${probe_dir}/conformance.nim" <<'EOF'
## Both copies, side by side, over identical inputs.
##
## Every comparison is of a VALUE a consumer would observe. Prose may differ and
## an answer may not — which is the whole point of vendoring a COMPUTATION: the
## thing that must not drift is where a label goes, not how it is described.
##
## The window below is the shape BlockTracer actually renders: a loop whose body
## writes one variable through a compound assignment, two passes recorded, and a
## line whose expression is absent from the source so the fallback path is
## exercised rather than assumed.
import std/strutils
import vendored/frontend/viewmodel/viewmodels/flow_layout as vend
import upstream/frontend/viewmodel/viewmodels/flow_layout as up

var problems: seq[string]
proc want(name: string; a, b: string) =
  if a != b:
    problems.add name & ":\n    vendored: " & a & "\n    upstream: " & b

const Source = @[
  "fn f(total: int) {",
  "    for i in 0..2 {",
  "        total -= i;",
  "    }",
  "}"]

proc vendWindow(): vend.FlowLayoutWindow =
  var loop = vend.FlowLayoutLoop(
    first: 2, last: 4, registeredLine: 2,
    rrTicksForIterations: @[10, 20],
    stepCounts: @[0, 1, 2, 3],
    iterationSteps: @[@[(line: 2, stepCount: 0), (line: 3, stepCount: 1)],
                      @[(line: 2, stepCount: 2), (line: 3, stepCount: 3)]])
  vend.FlowLayoutWindow(
    sourceLines: Source, tabSize: 4,
    loops: @[vend.FlowLayoutLoop(), loop],
    steps: @[
      vend.FlowLayoutStep(stepCount: 0, line: 2, loopIndex: 1, iteration: 0,
        rrTicks: 10, exprOrder: @["i"],
        beforeValues: @[], afterValues: @[vend.FlowValueText(expression: "i", text: "0")]),
      vend.FlowLayoutStep(stepCount: 1, line: 3, loopIndex: 1, iteration: 0,
        rrTicks: 12, exprOrder: @["total", "i", "carry"],
        beforeValues: @[vend.FlowValueText(expression: "total", text: "7"),
                        vend.FlowValueText(expression: "i", text: "0"),
                        vend.FlowValueText(expression: "carry", text: "1")],
        afterValues: @[vend.FlowValueText(expression: "total", text: "7"),
                       vend.FlowValueText(expression: "carry", text: "1")]),
      vend.FlowLayoutStep(stepCount: 2, line: 2, loopIndex: 1, iteration: 1,
        rrTicks: 20, exprOrder: @["i"],
        beforeValues: @[], afterValues: @[vend.FlowValueText(expression: "i", text: "1")]),
      vend.FlowLayoutStep(stepCount: 3, line: 3, loopIndex: 1, iteration: 1,
        rrTicks: 22, exprOrder: @["total", "i", "carry"],
        beforeValues: @[vend.FlowValueText(expression: "total", text: "7"),
                        vend.FlowValueText(expression: "i", text: "1"),
                        vend.FlowValueText(expression: "carry", text: "1")],
        afterValues: @[vend.FlowValueText(expression: "total", text: "6"),
                       vend.FlowValueText(expression: "carry", text: "1")])])

proc upWindow(): up.FlowLayoutWindow =
  var loop = up.FlowLayoutLoop(
    first: 2, last: 4, registeredLine: 2,
    rrTicksForIterations: @[10, 20],
    stepCounts: @[0, 1, 2, 3],
    iterationSteps: @[@[(line: 2, stepCount: 0), (line: 3, stepCount: 1)],
                      @[(line: 2, stepCount: 2), (line: 3, stepCount: 3)]])
  up.FlowLayoutWindow(
    sourceLines: Source, tabSize: 4,
    loops: @[up.FlowLayoutLoop(), loop],
    steps: @[
      up.FlowLayoutStep(stepCount: 0, line: 2, loopIndex: 1, iteration: 0,
        rrTicks: 10, exprOrder: @["i"],
        beforeValues: @[], afterValues: @[up.FlowValueText(expression: "i", text: "0")]),
      up.FlowLayoutStep(stepCount: 1, line: 3, loopIndex: 1, iteration: 0,
        rrTicks: 12, exprOrder: @["total", "i", "carry"],
        beforeValues: @[up.FlowValueText(expression: "total", text: "7"),
                        up.FlowValueText(expression: "i", text: "0"),
                        up.FlowValueText(expression: "carry", text: "1")],
        afterValues: @[up.FlowValueText(expression: "total", text: "7"),
                       up.FlowValueText(expression: "carry", text: "1")]),
      up.FlowLayoutStep(stepCount: 2, line: 2, loopIndex: 1, iteration: 1,
        rrTicks: 20, exprOrder: @["i"],
        beforeValues: @[], afterValues: @[up.FlowValueText(expression: "i", text: "1")]),
      up.FlowLayoutStep(stepCount: 3, line: 3, loopIndex: 1, iteration: 1,
        rrTicks: 22, exprOrder: @["total", "i", "carry"],
        beforeValues: @[up.FlowValueText(expression: "total", text: "7"),
                        up.FlowValueText(expression: "i", text: "1"),
                        up.FlowValueText(expression: "carry", text: "1")],
        afterValues: @[up.FlowValueText(expression: "total", text: "6"),
                       up.FlowValueText(expression: "carry", text: "1")])])

# 1. THE COMPOSED ANSWER. Every label, at every line, in both selectable passes
#    — which is the whole of what a renderer consumes.
for iteration in 0 .. 1:
  let v = vend.computeFlowLayout(vendWindow(), 12,
            @[(loopIndex: 1, iteration: iteration)])
  let u = up.computeFlowLayout(upWindow(), 12,
            @[(loopIndex: 1, iteration: iteration)])
  want("computeFlowLayout(pass " & $iteration & ")", $v, $u)

# 2. The pass the DEBUGGER is in, derived from a tick inside a body rather than
#    on a header — the case issue #593 got wrong.
for ticks in [0, 10, 15, 20, 99]:
  want("activeIteration(" & $ticks & ")",
       $vend.activeIteration(vendWindow().loops[1], ticks),
       $up.activeIteration(upWindow().loops[1], ticks))

# 3. Placement, ordering and the fallback, on their own. `carry` is not in the
#    source line, so this is the path that decides whether a value that was
#    recorded is shown somewhere or pointed at the wrong offset.
let vendCols = vend.assignExpressionColumns(
  Source[2], @["total", "i", "carry"], @["total", "i", "carry"], @["total"])
let upCols = up.assignExpressionColumns(
  Source[2], @["total", "i", "carry"], @["total", "i", "carry"], @["total"])
want("assignExpressionColumns", $vendCols, $upCols)
want("orderExpressionsByColumn",
     $vend.orderExpressionsByColumn(vendCols, ascending = true),
     $up.orderExpressionsByColumn(upCols, ascending = true))
want("findExpressionColumn(sum in sums)",
     $vend.findExpressionColumn("let sums = sum + 1", "sum"),
     $up.findExpressionColumn("let sums = sum + 1", "sum"))

# 4. Which of the three renderings a pair of values makes.
for (b, a, hb, ha) in [("10", "20", true, true), ("10", "10", true, true),
                       ("", "230", false, true), ("10", "", true, false)]:
  want("resolveFlowValueModeForText(" & b & "," & a & ")",
       $vend.resolveFlowValueModeForText(b, a, hb, ha),
       $up.resolveFlowValueModeForText(b, a, hb, ha))

# 5. Indentation, including the tab-stop arithmetic and the blank-line rule.
for text in ["", "    x", "\tx", "  \tx", "        x", "   "]:
  want("sourceIndentLevel(" & text.escape & ")",
       $vend.sourceIndentLevel(text), $up.sourceIndentLevel(text))

# 6. The legend/parallel-column plan — the arithmetic the DESKTOP cannot reach
#    (`Omniscience-Flow.md`'s recorded defect: its only writers were dead code).
#    Comparing it here is what keeps the two agreeing about a computation only
#    one of them currently draws.
want("computeLoopColumnPlan",
     $vend.computeLoopColumnPlan(vendWindow(), 1),
     $up.computeLoopColumnPlan(upWindow(), 1))

# 7. Source tokenisation, through a language profile.
let vendLang = vend.nimFlowTokenLanguage(@["let", "for", "fn"])
let upLang = up.nimFlowTokenLanguage(@["let", "for", "fn"])
for line in Source:
  want("tokenizeSourceExpressions(" & line.escape & ")",
       $vend.tokenizeSourceExpressions(line, vendLang),
       $up.tokenizeSourceExpressions(line, upLang))

# A probe that compared nothing would report agreement. Assert the fixture is
# the shape the comparisons need before believing any of them.
doAssert vend.computeFlowLayout(vendWindow(), 12).lines.len >= 2,
  "the probe window produced no lines — the comparisons above are vacuous"
doAssert vend.computeLoopColumnPlan(vendWindow(), 1).positions.len > 0,
  "the probe window produced no column plan — comparison 6 is vacuous"
block:
  var sawFallback = false
  for entry in vendCols:
    if not entry.found: sawFallback = true
  doAssert sawFallback,
    "no expression took the fallback path — comparison 3 is vacuous"

if problems.len > 0:
  echo "the vendored omniscience layout has DIVERGED from upstream:"
  for p in problems: echo "  - " & p
  quit 1
echo "flow-layout-vendor: vendored and upstream agree on every observable"
EOF

if ! nim c -r --hints:off --warnings:off \
	--path:"${probe_dir}" \
	--nimcache:"${probe_dir}/nimcache" -o:"${probe_dir}/conformance" \
	"${probe_dir}/conformance.nim"; then
	fail "the conformance probe failed"
fi

echo "flow-layout-vendor.sh: OK"
