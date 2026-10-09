#!/usr/bin/env bash
#
# ct-css-reachable-test.sh — the reachability gate's own proof of bite.
#
# `ci/test/ct-css-reachable.sh` passes on the current tree by design, which is
# exactly the state in which a broken detector is invisible. Worse than
# invisible, here: the gate exists because three defects reached the owner as
# "ported" / "fixed" on the strength of an assertion nobody had checked the
# converse of, and a gate for that class of mistake which has never been watched
# to fail would be a fourth instance of it.
#
# So every case below hands `tools/ci/check-css-reachable.mjs` a synthetic
# markup tree plus a synthetic register and asserts the arm WRITTEN for that
# mutation is the one that goes red. The three mutations the defect class calls
# for are arms 1, 2 and 3, and each has a CONTROL beside it, because an arm that
# cannot be green is not a detector:
#
#   1  un-drop a rule that matches nothing       a LIVE row nothing emits   -> 1
#   1c control: that same row, with the markup   LIVE and emitted           -> 0
#   2  remove a class the markup used to carry   LIVE row goes unmatched    -> 1
#   2c control: the class still there            unchanged                  -> 0
#   3  an INERT row that has come alive          the stale-excuse direction -> 1
#   3c control: INERT and still inert            unchanged                  -> 0
#
# and then the ways this gate could pass while measuring nothing, which is the
# failure mode a checker of this shape actually has:
#
#   4  an export with too few pages              vacuity floor              -> 1
#   5  a markup universe below the floor          vacuity floor             -> 1
#   6  a register with no LIVE rows               one-sided run             -> 3
#   7  a register with no INERT rows              one-sided run             -> 3
#   8  a malformed register row                   parse, not silence        -> 2
#   9  an unknown kind                            parse, not silence        -> 2
#  10  a bundle token does NOT excuse a LIVE row  the hole left closed      -> 1
#  11  …and DOES satisfy one declared `bundle`    the tier is real          -> 0
#  12  a glob row covers its family, not its      `ct-origin-*` must not
#      lookalikes                                 cover `x-ct-origin-y`     -> 1
#
# Arm 10 is the one to read if you read one. `active`, `checkbox`, `hidden`,
# `open` and `selector` are all classes the port names AND all present as
# ordinary words in `hydrate.js`; counting a bundle string literal as liveness
# would have excused all five, and two of them sit in the same family as
# `.dropdown-list`, which is defect 3. This arm is what keeps that closed.
#
# Usage: ci/test/ct-css-reachable-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checker="${repo_root}/tools/ci/check-css-reachable.mjs"

pass=0
fail=0
work="$(mktemp -d "${TMPDIR:-/tmp}/ct-css-reachable-test.XXXXXX")"
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

case_no=0

# A synthetic markup tree. `pages <n>` pages, each carrying `classes`, plus a
# `.nim` source carrying `nimclasses`, plus a bundle whose `encoded` token is
# written ONLY as character codes (so the decoder has something to find that the
# text scan cannot) and whose `bothways` token is written both ways.
#
#   build_tree <dir> <pages> "<page classes>" "<nim classes>" "<bundle words>"
build_tree() {
	local dir="$1" pages="$2" classes="$3" nimclasses="$4" words="$5"
	mkdir -p "${dir}/site/assets" "${dir}/client/src/components"
	local i=0
	while [ "${i}" -lt "${pages}" ]; do
		printf '<!doctype html><html class="%s"><body><button id="b%s">x</button></body></html>' \
			"${classes}" "${i}" >"${dir}/site/page-${i}.html"
		i=$((i + 1))
	done
	# The source half of the markup scan. Not a `_css.nim` name and not under
	# `tests/`, because those are excluded on purpose.
	{
		printf 'proc r*(): string =\n'
		printf '  tdiv(class = "%s"):\n    text "x"\n' "${nimclasses}"
	} >"${dir}/client/src/components/probe_markup.nim"
	# The bundle. `ctprobeencoded` appears only as char codes; `ctprobeboth`
	# appears as text AND as char codes; everything in <words> appears as text.
	{
		printf 'var a = [99,116,112,114,111,98,101,101,110,99,111,100,101,100];\n'
		printf 'var b = [99,116,112,114,111,98,101,98,111,116,104];\n'
		printf 'var c = "ctprobeboth";\n'
		printf 'var d = "%s";\n' "${words}"
	} >"${dir}/site/assets/probe.js"
}

# expect <name> <expected-rc> <tree-dir> <register-text> [extra args...]
expect() {
	local name="$1" want="$2" dir="$3" register="$4"
	shift 4
	printf '%s\n' "${register}" >"${dir}/register.txt"
	local out rc
	out="$(node "${checker}" "${dir}/site" --client "${dir}/client" \
		--register "${dir}/register.txt" "$@" 2>&1)"
	rc=$?
	case_no=$((case_no + 1))
	if [ "${rc}" -eq "${want}" ]; then
		report_pass "${name} (rc=${rc})"
	else
		report_fail "${name} (want rc=${want}, got ${rc})" "$(printf '%s' "${out}" | tail -4 | tr '\n' ' ')"
	fi
}

# The floors every arm but 4 and 5 runs under. As low as they go, because these
# trees are synthetic and a handful of classes is the point of them; the real
# gate's floors are its defaults (100 pages, 150 classes) and arms 4 and 5 are
# what prove a floor refuses a run at all.
FLOORS=(--min-pages 5 --min-markup-classes 1)

echo "== the three mutations the defect class calls for =="

# ── 1. un-drop a rule that matches nothing ────────────────────────────────
# The shape of defect 2: a rule is kept (not `Dropped`), so its class becomes a
# register item, and nothing emits it. Declaring it LIVE — which is what a
# "ported" report amounts to — has to be red.
t="${work}/t1"
build_tree "${t}" 10 "lm_tab lm_title component-container" "lm_tab lm_title component-container" "noise"
expect "1  a LIVE row nothing emits is RED (the un-dropped rule)" 1 "${t}" \
	"LIVE class lm_tab
    the tab strip, emitted by the stack renderer and present in the tree
LIVE class ct-origin-icon-sigma
    un-dropped and declared live, which is the mutation: nothing emits it
INERT class dropdown-list
    opens from script, so nothing on a static route can match it" \
	"${FLOORS[@]}"

expect "1c CONTROL: the same register without that row is GREEN" 0 "${t}" \
	"LIVE class lm_tab
    the tab strip, emitted by the stack renderer and present in the tree
LIVE class component-container
    the panel surface, which defect 1 was about and which the tree carries
INERT class ct-origin-icon-sigma
    nothing emits the origin badge, which is the honest classification" \
	"${FLOORS[@]}"

# ── 2. remove a class from markup that a kept rule needs ──────────────────
# The shape of defect 1, run backwards: `.component-container` is LIVE today
# because five pane bodies wear it. Take it off the markup and the row has to go
# red, in BOTH sources — a tree that still has the literal would hide it.
t="${work}/t2"
build_tree "${t}" 10 "lm_tab lm_title" "lm_tab lm_title" "noise"
expect "2  a LIVE row whose class left the markup is RED" 1 "${t}" \
	"LIVE class component-container
    the panel surface the five pane bodies wear — removed from this tree
INERT class dropdown-list
    opens from script, so nothing on a static route can match it" \
	"${FLOORS[@]}"

t="${work}/t2c"
build_tree "${t}" 10 "lm_tab lm_title component-container" "lm_tab" "noise"
expect "2c CONTROL: put it back in the PAGES only and it is GREEN" 0 "${t}" \
	"LIVE class component-container
    the panel surface, carried by the pages and by no source literal at all,
    which is the case lm_vertical is in on the real tree and must count
INERT class dropdown-list
    opens from script, so nothing on a static route can match it" \
	"${FLOORS[@]}"

# ── 3. an INERT row that has come alive ───────────────────────────────────
# THE DIRECTION THAT WOULD HAVE CAUGHT A "FIXED" REPORT. A reason that says
# nothing matches is a reason that stops being true the moment something does,
# and a register whose rows can rot is not evidence.
t="${work}/t3"
build_tree "${t}" 10 "lm_tab ct-origin-badge" "lm_tab" "noise"
expect "3  an INERT row something now emits is RED (the stale excuse)" 1 "${t}" \
	"LIVE class lm_tab
    the tab strip, emitted by the stack renderer and present in the tree
INERT class ct-origin-*
    no seven-way badge markup exists, so nothing can match these" \
	"${FLOORS[@]}"

t="${work}/t3c"
build_tree "${t}" 10 "lm_tab" "lm_tab" "noise"
expect "3c CONTROL: the same row over a tree that does NOT emit it is GREEN" 0 "${t}" \
	"LIVE class lm_tab
    the tab strip, emitted by the stack renderer and present in the tree
INERT class ct-origin-*
    no seven-way badge markup exists, so nothing can match these" \
	"${FLOORS[@]}"

echo "== the ways this gate could pass while measuring nothing =="

# ── 4/5. the vacuity floors ───────────────────────────────────────────────
# An export that produced almost nothing sends EVERY inert row green. That is
# the pass this gate must refuse, and it is the same floor `test_static_export`
# and `untrusted-text.sh` each carry for their own measurement.
t="${work}/t4"
build_tree "${t}" 2 "lm_tab component-container" "lm_tab" "noise"
expect "4  too few exported pages is RED, not a green run" 1 "${t}" \
	"LIVE class lm_tab
    the tab strip, emitted by the stack renderer and present in the tree
INERT class ct-origin-*
    no badge markup exists, so nothing can match these" \
	--min-pages 5 --min-markup-classes 2

t="${work}/t5"
build_tree "${t}" 10 "a" "b" "noise"
expect "5  a markup universe under the floor is RED" 1 "${t}" \
	"LIVE class a
    one class, which is not a site and must not be read as one
INERT class ct-origin-*
    no badge markup exists, so nothing can match these" \
	--min-pages 5 --min-markup-classes 50

# ── 6/7. a one-sided run ──────────────────────────────────────────────────
# A register with no LIVE rows proves nothing is claimed; one with no INERT rows
# proves nothing is excused. Either is half a gate and neither may exit 0.
t="${work}/t6"
build_tree "${t}" 10 "lm_tab component-container" "lm_tab" "noise"
expect "6  a register with no LIVE row exits 3 — nothing was claimed" 3 "${t}" \
	"INERT class ct-origin-*
    no badge markup exists, so nothing can match these
INERT class dropdown-list
    opens from script, so nothing on a static route can match it" \
	"${FLOORS[@]}"

expect "7  a register with no INERT row exits 3 — nothing was excused" 3 "${t}" \
	"LIVE class lm_tab
    the tab strip, emitted by the stack renderer and present in the tree
LIVE class component-container
    the panel surface, which the tree carries" \
	"${FLOORS[@]}"

# ── 8/9. the register is parsed, not skimmed ──────────────────────────────
# A row this file cannot read must be an error. A parser that skipped what it
# did not understand would turn a typo into a silently unclassified selector,
# which is the whole defect one layer down.
expect "8  a malformed row is an error (rc=2), never a skip" 2 "${t}" \
	"LIVE class
    a row with no pattern at all" \
	"${FLOORS[@]}"

expect "9  an unknown kind is an error (rc=2), never a skip" 2 "${t}" \
	"LIVE selektor lm_tab
    a kind this register does not have" \
	"${FLOORS[@]}"

# ── 10/11. the bundle tier, both ways ─────────────────────────────────────
# A bundle string literal is not a class value. `ctprobeencoded` is in the
# synthetic bundle ONLY as character codes — so the decoder finds it, which is
# the capability the brief asked for — and it STILL must not satisfy a LIVE row
# that did not declare `bundle` as its evidence.
t="${work}/t10"
build_tree "${t}" 10 "lm_tab component-container" "lm_tab" "noise"
expect "10 a bundle token does NOT excuse an ordinary LIVE row" 1 "${t}" \
	"LIVE class ctprobeencoded
    declared live with no evidence tier, while only the bundle carries it
INERT class ct-origin-*
    no badge markup exists, so nothing can match these" \
	"${FLOORS[@]}"

expect "11 …and DOES satisfy a row that declares \`bundle\` (and the decoder found it)" 0 "${t}" \
	"LIVE class ctprobeencoded bundle
    carried by the bundle as character codes only, declared as such — which
    is what makes the decoder's reach a measurement rather than a claim
LIVE class lm_tab
    the tab strip, emitted by the stack renderer and present in the tree
INERT class ct-origin-*
    no badge markup exists, so nothing can match these" \
	"${FLOORS[@]}"

# ── 12. the glob is a glob ────────────────────────────────────────────────
# A row that covered more than its reason describes would be an excuse with the
# wrong scope. `ct-origin-*` must not reach `x-ct-origin-y`, so a tree emitting
# the lookalike must NOT redden the row — and a LIVE row for the lookalike must
# still be satisfied by it.
t="${work}/t12"
build_tree "${t}" 10 "lm_tab x-ct-origin-y" "lm_tab" "noise"
expect "12 a glob row is not a substring search (the lookalike does not redden it)" 0 "${t}" \
	"LIVE class x-ct-origin-y
    the lookalike, which the tree does emit
INERT class ct-origin-*
    the family, which the tree does not emit — and the lookalike is not in it" \
	"${FLOORS[@]}"

echo
echo "ct-css-reachable-test.sh: ${pass} passed, ${fail} failed, ${case_no} cases"
[ "${fail}" -eq 0 ] || exit 1
exit 0
