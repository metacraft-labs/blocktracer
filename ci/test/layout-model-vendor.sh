#!/usr/bin/env bash
#
# layout-model-vendor.sh — keep the vendored copy of CodeTracer's layout model
# honest.
#
# `client/src/debugger/vendor/frontend/headless_app/layout_model.nim` and the
# `client/src/debugger/vendor/common/contributed_pane_id.nim` it imports are
# byte-verbatim copies of CodeTracer's `src/frontend/headless_app/
# layout_model.nim` and `src/common/contributed_pane_id.nim`;
# `client/src/debugger/vendor/layout_model.vendor.json` records where they came
# from and why they are copies. A copy with no check is a fork nobody has
# noticed yet, so — in exactly the shape `flow-layout-vendor.sh` uses, because
# two conventions for one idea is a second thing to learn:
#
#   A. LOCAL INTEGRITY (always runs, needs nothing but this repository)
#      Both vendored files still hash to the sha256s in the manifest, and the
#      manifest's commit EQUALS `ci/embed-sdk-pin.env`'s CODETRACER_REF. An
#      edit here — a helpful tweak, a merge, a formatter — fails.
#
#   B. STRUCTURAL CONFORMANCE (needs a CodeTracer checkout)
#      A probe imports BOTH copies and compares what a consumer of either one
#      would observe: the serialised `defaultReplayLayout()`, `allPanes`,
#      `visiblePanes`, the pane enum's spellings, `LayoutSchemaVersion` and
#      `validate`'s verdict on a deliberately malformed tree. A structural
#      change upstream fails here rather than leaving BlockTracer arranging
#      panes to a shape no other front-end has.
#
#      Compared by VALUE, not by text. The two files are allowed to differ in
#      prose, and a byte comparison against a moving checkout would fail for a
#      reworded comment, which is how a check gets switched off.
#
# ── WHY PART A NOW CHECKS THE PIN, AND WHY THAT IS THE WHOLE FIX ───────────
#
# Until 2026-09-17 this gate was RED BY CONSTRUCTION, and the cause was a
# category error rather than a defect upstream. Part A pinned the copy to the
# MODULE's own mainline (`eb1776ea`) while part B compared it against whatever
# `$CODETRACER_SRC` was — i.e. the EMBED SDK pin, a different commit by design.
# A gate that pins to one commit and compares against another asks a question
# with no passable answer: every SDK bump reddened it whether or not this
# module had changed, and it is a BLOCKING step of the `viewmodels` job. A
# permanently-red gate is one everybody learns to ignore, which this
# repository's own doctrine says in AGENTS.md §1a about the Noir engine lane.
#
# `flow-layout-vendor.sh` never had that defect because its manifest commit IS
# the pin. This manifest now is too, and the check below is what keeps it that
# way — so a red part B from here on means upstream really changed this module,
# and the remedy is a re-vendor with a diff to read.
#
# ── WHY PART B MIRRORS THE DIRECTORY DEPTH ────────────────────────────────
#
# `layout_model.nim` imports `../../common/contributed_pane_id`. The previous
# probe copied each side into a FLAT directory, which broke that relative
# import — upstream's file then failed to compile with "cannot open file", and
# the gate reported "the conformance probe failed". That compile error MASKED
# the real answer: mounted at its own depth, the probe reports four genuine
# divergences (schema version, `docked`, two new `PaneKind` members, a new
# `validate` field). A probe that cannot build the thing it compares does not
# report agreement or disagreement — it reports nothing, in a voice that sounds
# like disagreement. Both sides are mounted at their own depth below.
#
# Exit codes:
#   0  every check that could run, passed
#   1  a check failed
#   3  no CodeTracer checkout for part B, and --require was not given

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require=0
[ "${1:-}" = "--require" ] && require=1

# Overridable so that `layout-model-vendor-test.sh` can drive this script
# against deliberately-broken copies. Nothing else sets them: a check whose own
# failure path has never been executed is a check nobody has reason to believe.
vendor_dir="${LAYOUT_VENDOR_DIR:-${repo_root}/client/src/debugger/vendor}"
manifest="${LAYOUT_VENDOR_MANIFEST:-${vendor_dir}/layout_model.vendor.json}"

model_rel="frontend/headless_app/layout_model.nim"
pane_rel="common/contributed_pane_id.nim"
model_up="src/frontend/headless_app/layout_model.nim"
pane_up="src/common/contributed_pane_id.nim"

fail() {
	echo "layout-model-vendor.sh: $*" >&2
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

echo "=== the vendored layout model ==="

# ---------------------------------------------------------------------------
# A. Local integrity
# ---------------------------------------------------------------------------

[ -f "${manifest}" ] || fail "the vendor manifest is missing: ${manifest}"

# Read with grep rather than a JSON parser: this script must run on a bare CI
# runner with nothing installed beyond a shell and Nim, and two fields out of a
# small manifest do not justify a dependency. The manifest lists TWO files, so
# the digests are read in document order and matched against the files in the
# same order — and the count is checked, which is what stops a manifest that
# lost an entry from passing by having nothing to compare.
mapfile -t recorded < <(grep -oE '"sha256"[[:space:]]*:[[:space:]]*"[0-9a-f]{64}"' \
	"${manifest}" | grep -oE '[0-9a-f]{64}')
[ "${#recorded[@]}" -eq 2 ] ||
	fail "the manifest records ${#recorded[@]} sha256 entries; expected 2 (${model_rel}, ${pane_rel})"

i=0
for rel in "${model_rel}" "${pane_rel}"; do
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

# The manifest's commit must equal the Embed SDK pin — see the header. This is
# the check that turns part B from unanswerable into a drift detector.
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
		echo "  Part B compares this copy against \$CODETRACER_SRC, which IS the pin." >&2
		echo "  A manifest naming a different commit makes part B unanswerable: it" >&2
		echo "  would redden on every SDK bump whether or not this module moved." >&2
		echo "  Re-vendor from the pinned commit and update the manifest." >&2
		exit 1
	fi
	echo "--- A: manifest commit == Embed SDK pin (${pinned:0:12}…)"
fi

# ---------------------------------------------------------------------------
# B. Structural conformance against a real CodeTracer checkout
# ---------------------------------------------------------------------------

ct=""
if [ -n "${CODETRACER_SRC:-}" ] && [ -e "${CODETRACER_SRC}/${model_up}" ]; then
	ct="${CODETRACER_SRC}"
elif [ -e "${repo_root}/../codetracer/${model_up}" ]; then
	ct="$(cd "${repo_root}/../codetracer" && pwd)"
fi

if [ -z "${ct}" ]; then
	echo "--- B: SKIPPED — no CodeTracer checkout" >&2
	echo "    Looked for ${model_up} under \$CODETRACER_SRC and" >&2
	echo "    ${repo_root}/../codetracer" >&2
	if [ "${require}" -eq 1 ]; then
		echo "layout-model-vendor.sh: --require was given, so this is a failure" >&2
		exit 1
	fi
	exit 3
fi

echo "--- B: comparing against ${ct}"

probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/layout-vendor.XXXXXX")"
trap 'rm -rf "${probe_dir}"' EXIT

# Each side at its OWN depth, so `../../common/contributed_pane_id` resolves
# within that side and neither side can reach the other's copy.
for side in vendored upstream; do
	mkdir -p "${probe_dir}/${side}/frontend/headless_app" \
		"${probe_dir}/${side}/common"
done
cp "${vendor_dir}/${model_rel}" "${probe_dir}/vendored/${model_rel}"
cp "${vendor_dir}/${pane_rel}" "${probe_dir}/vendored/${pane_rel}"
cp "${ct}/${model_up}" "${probe_dir}/upstream/${model_rel}"
cp "${ct}/${pane_up}" "${probe_dir}/upstream/${pane_rel}"

cat >"${probe_dir}/conformance.nim" <<'EOF'
## Both copies, side by side. Every comparison is of a VALUE a consumer of
## either module would observe, so prose may differ and a structural change may
## not.
import std/[json, strutils]
import vendored/frontend/headless_app/layout_model as vend
import upstream/frontend/headless_app/layout_model as up

var problems: seq[string]
proc want(name: string; a, b: string) =
  if a != b:
    problems.add name & ":\n    vendored: " & a & "\n    upstream: " & b

template attempt(body: untyped): string =
  ## A DIVERGENCE MAY BE A RAISE, and an uncaught one ends the probe at the
  ## first comparison that hits it — which is how the gate reported "the
  ## conformance probe failed" (a sentence about a broken script) for what was
  ## actually a moved schema, leaving every comparison after it unrun and the
  ## ones before it collected but never printed. Measured on the self-test's
  ## schema-bump arm: upstream at version 4 refuses the vendored module's
  ## version-3 document with `UnknownVersion`, which is a genuine answer and
  ## must be COMPARED rather than propagated.
  block:
    var r: string
    try:
      r = body
    except CatchableError as e:
      r = "raised " & $e.name & ": " & e.msg
    r

# 1. The default arrangement, serialised. Shape, weights, titles, active tab —
#    and, since the document carries it, the schema version and every key the
#    encoder writes beside the tree.
want("defaultReplayLayout()",
     attempt($vend.saveLayout(vend.defaultReplayLayout())),
     attempt($up.saveLayout(up.defaultReplayLayout())))

# 2. The pane sets a consumer walks, in order.
want("allPanes", attempt($vend.allPanes(vend.defaultReplayLayout())),
                 attempt($up.allPanes(up.defaultReplayLayout())))
want("visiblePanes", attempt($vend.visiblePanes(vend.defaultReplayLayout())),
                     attempt($up.visiblePanes(up.defaultReplayLayout())))

# 3. The enum spellings, which are what a saved layout is written in — and what
#    `components/debugger.paneId` derives every pane's element id from, so a
#    change here moves a deep-link target and a capture-harness selector.
var vendPanes, upPanes: seq[string]
for p in vend.PaneKind: vendPanes.add $p
for p in up.PaneKind: upPanes.add $p
want("PaneKind spellings", vendPanes.join(","), upPanes.join(","))
var vendKinds, upKinds: seq[string]
for k in vend.LayoutNodeKind: vendKinds.add $k
for k in up.LayoutNodeKind: upKinds.add $k
want("LayoutNodeKind spellings", vendKinds.join(","), upKinds.join(","))
want("LayoutSchemaVersion", $vend.LayoutSchemaVersion, $up.LayoutSchemaVersion)

# 4. The validator's verdict on a deliberately malformed tree — the half that
#    would not move if only the constructors were compared.
let vendBad = vend.row([vend.pane(vend.paneEditor), vend.pane(vend.paneEditor)])
let upBad = up.row([up.pane(up.paneEditor), up.pane(up.paneEditor)])
want("validate(duplicate pane)",
     attempt($vend.validate(vendBad)), attempt($up.validate(upBad)))

# 5. A round trip through the serialised form, cross-decoded: what the vendored
#    module writes, the upstream module must read back to the same tree.
want("cross-decoded default",
     attempt($up.saveLayout(up.restoreLayout(
       vend.saveLayout(vend.defaultReplayLayout())))),
     attempt($up.saveLayout(up.defaultReplayLayout())))

# 6. BlockTracer's OWN arrangement, composed here from the same primitives
#    `client/src/debugger/session_layout.nim` uses. Comparison 1 is about a tree
#    this repository never renders; this one is about the tree it does. If these
#    ever disagree, the divergence is not academic — it is the debug route.
let vendBt = vend.row([
  vend.pane(vend.paneEditor, "Code", weight = 3.0),
  vend.column([
    vend.stack([vend.pane(vend.paneCalltrace, "Call Trace"),
                vend.pane(vend.paneEventLog, "Event Log")],
               activeIndex = 0, weight = 3.0),
    vend.pane(vend.paneState, "Values", weight = 2.0)], weight = 2.0)],
  weight = 1.0)
let upBt = up.row([
  up.pane(up.paneEditor, "Code", weight = 3.0),
  up.column([
    up.stack([up.pane(up.paneCalltrace, "Call Trace"),
              up.pane(up.paneEventLog, "Event Log")],
             activeIndex = 0, weight = 3.0),
    up.pane(up.paneState, "Values", weight = 2.0)], weight = 2.0)],
  weight = 1.0)
want("blockTracerReplayLayout(): allPanes",
     attempt($vend.allPanes(vendBt)), attempt($up.allPanes(upBt)))
want("blockTracerReplayLayout(): visiblePanes",
     attempt($vend.visiblePanes(vendBt)), attempt($up.visiblePanes(upBt)))
want("blockTracerReplayLayout(): find(editor).title",
     attempt(vend.find(vendBt, vend.paneEditor).title),
     attempt(up.find(upBt, up.paneEditor).title))
want("blockTracerReplayLayout(): validate",
     attempt($vend.validate(vendBt)), attempt($up.validate(upBt)))
want("blockTracerReplayLayout(): round trip",
     attempt($vend.saveLayout(vend.restoreLayout(vend.saveLayout(vendBt)))),
     attempt($up.saveLayout(up.restoreLayout(up.saveLayout(upBt)))))

# 7. The SECOND vendored file, reached through the first. Without this, part A
#    would be the only thing that ever looked at `contributed_pane_id.nim` — a
#    file covered by a hash and by no behaviour at all. `contributedPaneNode`
#    and the decoder both consult its grammar, so a drift in what an id may
#    contain shows up here as a layout that round-trips differently or a
#    verdict that changes.
#    A malformed id is REFUSED by the decoder rather than dropped, so the
#    outcome being compared is "what each module does", which for half the
#    corpus is raise. Catching and comparing the message is the comparison; an
#    uncaught raise would end the probe early and leave later checks unrun,
#    which is a suite that stops rather than a suite that reports.
const ContributedIds = ["metrics/panel", "ok-1/ok_2", "a.b/c_1",
                        "plugin/", "/surface", "a/b/c", "bad id/x", "editor"]

proc vendOutcome(id: string): string =
  let n = vend.row([vend.contributedPaneNode(id, "Contributed"),
                    vend.pane(vend.paneEditor)])
  try: "ok " & $vend.saveLayout(vend.restoreLayout(vend.saveLayout(n)))
  except CatchableError as e: "refused " & e.msg

proc upOutcome(id: string): string =
  let n = up.row([up.contributedPaneNode(id, "Contributed"),
                  up.pane(up.paneEditor)])
  try: "ok " & $up.saveLayout(up.restoreLayout(up.saveLayout(n)))
  except CatchableError as e: "refused " & e.msg

for id in ContributedIds:
  want("contributed(" & id.escape & ")", vendOutcome(id), upOutcome(id))

# A probe that compared nothing would report agreement. Assert each fixture is
# the shape the comparisons need before believing any of them.
block:
  var accepted, refused = 0
  for id in ContributedIds:
    if vendOutcome(id).startsWith("ok "): accepted.inc else: refused.inc
  doAssert accepted > 0 and refused > 0,
    "the contributed-id corpus is all-good or all-bad — comparison 7 is vacuous"
doAssert vend.validate(vendBad).len > 0, "the malformed probe is not malformed"
doAssert vend.validate(vendBt).len == 0,
  "BlockTracer's own arrangement does not validate — comparison 6 is vacuous"
doAssert vend.allPanes(vendBt).len == 4,
  "the BlockTracer probe placed no panes — comparison 6 is vacuous"
doAssert vend.allPanes(vend.defaultReplayLayout()).len > 0,
  "the default arrangement placed no panes — comparisons 1-2 are vacuous"

if problems.len > 0:
  echo "the vendored layout model has DIVERGED from upstream:"
  for p in problems: echo "  - " & p
  quit 1
echo "layout-model-vendor: vendored and upstream agree on every observable"
EOF

if ! nim c -r --hints:off --warnings:off \
	--path:"${probe_dir}" \
	--nimcache:"${probe_dir}/nimcache" -o:"${probe_dir}/conformance" \
	"${probe_dir}/conformance.nim"; then
	fail "the conformance probe failed"
fi

echo "layout-model-vendor.sh: OK"
