#!/usr/bin/env bash
#
# noir-engine-dap-test.sh — the self-test for ci/test/noir-engine-dap.sh.
#
# Every rule that suite enforces is driven against a deliberately broken input,
# and each arm asserts that **the check written for it** is the one that goes
# red. A kill by a different assertion is a MISS, not a kill: it means the arm
# proved something other than what it claims, and the check it was written for
# has still never been seen to say no.
#
# That is the whole design. `Silent-Self-Pass-Audit` and
# `Verification-Harness-Traps.md` are both about assertions that cannot fail;
# the only way to know an assertion can is to make it.
#
# Two kinds of arm:
#
#   * SUITE arms  — `$BT_ENGINE_DAP_MUTATION` perturbs the request the suite
#                   sends (or, for the oracle arms, the oracle it reads), and
#                   the named check must redden.
#   * RUNNER arms — a missing or bogus input, and the runner must FAIL rather
#                   than skip. A suite that goes green because its subject is
#                   absent is the failure mode this repository has found five
#                   of.
#
# Usage:  ci/test/noir-engine-dap-test.sh [arm ...]
# With no arguments, every arm runs.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1
SUITE="${REPO_ROOT}/ci/test/noir-engine-dap.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

passes=0
misses=0
armsRun=0

pass() { passes=$((passes + 1)); echo "  [KILL] $*"; }
miss() { misses=$((misses + 1)); echo "  [MISS] $*"; }

# --- a SUITE arm ------------------------------------------------------------
# $1 mutation id, $2 the check id that MUST redden, $3 how many checks the arm
# is entitled to redden IN TOTAL, $4 a one-line description.
#
# The count is not slack — it is the arm's own claim, and it is asserted.
# A mutation that removes an ARTEFACT legitimately reddens every check about
# that artefact: `flowMode: 2` is refused, so there is no flow window, so the
# six checks that read one all go red together. Writing "1" for that arm and
# calling the other five a miss would have been wrong; leaving the count
# unasserted would have let a mutation that broke the whole session pass as a
# surgical one. So the arm declares the number and the number is checked, which
# is Traps §4b applied to the self-test rather than to the suite.
suite_arm() {
	local mutation="$1" expected="$2" expectedCount="$3" what="$4"
	armsRun=$((armsRun + 1))
	local log="${WORK}/${mutation}.log"
	BT_ENGINE_DAP_MUTATION="${mutation}" "${SUITE}" >"${log}" 2>&1
	local rc=$?

	# The baseline already fails several checks against today's engine, so an
	# arm cannot be judged by the exit code — it is judged by WHICH checks
	# moved. `baseline.failed` is captured once, before any arm runs.
	local now
	now="$(grep -E '^\s+- §' "${log}" | sed 's/^ *- //' || true)"
	local newly
	newly="$(comm -13 <(sort "${WORK}/baseline.failed") <(printf '%s\n' "${now}" | sort) | grep -c . || true)"

	if printf '%s\n' "${now}" | grep -q "^${expected}"; then
		if grep -q "^${expected}" "${WORK}/baseline.failed"; then
			miss "${mutation}: ${expected} was ALREADY red at baseline — this arm proves nothing"
		elif [ "${newly}" -eq "${expectedCount}" ]; then
			pass "${mutation}: ${expected} (+$((newly - 1)) downstream, as declared) — ${what}"
		else
			miss "${mutation}: ${expected} went red, but ${newly} checks moved and the arm declared ${expectedCount}"
			comm -13 <(sort "${WORK}/baseline.failed") <(printf '%s\n' "${now}" | sort) \
				| sed 's/^/           newly-red: /'
		fi
	else
		miss "${mutation}: ${expected} stayed GREEN under a mutation written to break it (rc ${rc})"
	fi
}

# --- a RUNNER arm -----------------------------------------------------------
# $1 name, $2 the message the runner must print, $3.. the environment to set.
runner_arm() {
	local name="$1" needle="$2"; shift 2
	armsRun=$((armsRun + 1))
	local log="${WORK}/runner-${name}.log"
	env "$@" "${SUITE}" >"${log}" 2>&1
	local rc=$?
	if [ "${rc}" -eq 0 ]; then
		miss "${name}: the runner exited 0 with a broken input — it SKIPPED"
	elif grep -qF "${needle}" "${log}"; then
		pass "${name}: refused and named it (rc ${rc})"
	else
		miss "${name}: failed (rc ${rc}) but never said '${needle}'"
		tail -5 "${log}" | sed 's/^/           /'
	fi
}

echo "=== noir-engine-dap self-test: every rule, driven against a broken input ==="
echo ""
echo "  capturing the baseline (which checks are red against today's engine) ..."
"${SUITE}" >"${WORK}/baseline.log" 2>&1
BASE_RC=$?
# `- §` and not `- `: the summary prints TWO bulleted lists, failed checks
# and unanswered commands, and matching both counted the hang twice.
grep -E '^\s+- §' "${WORK}/baseline.log" | sed 's/^ *- //' | sort >"${WORK}/baseline.failed"
BASE_CHECKS="$(grep -oE '^noir-engine-dap: [0-9]+ checks' "${WORK}/baseline.log" | grep -oE '[0-9]+' || echo 0)"
echo "  baseline: rc ${BASE_RC}, ${BASE_CHECKS} checks, $(grep -c . "${WORK}/baseline.failed") red"

# Traps §4b: a per-check assertion count is a fingerprint. If the baseline did
# not run its full set, no arm below means anything, because a mutation that
# "kills" a check that never ran is not a kill.
if [ "${BASE_CHECKS}" -lt 1 ]; then
	echo "FAIL: the baseline produced no check count at all — nothing below can be judged." >&2
	tail -20 "${WORK}/baseline.log" >&2
	exit 1
fi
echo ""

ARMS=("$@")
if [ "${#ARMS[@]}" -eq 0 ]; then
	ARMS=(expect-observed oracle-truncated flow-mode-out-of-range reverse-unprefixed
	      no-engine-dir no-engine-fetch no-container stub-wasm)
fi

# --- the control arm --------------------------------------------------------
# Every OTHER arm proves a green check can go red. This one proves the red ones
# can go green, which is the control a suite whose deliverable is failures
# actually needs: an assertion that is stuck red is satisfied trivially by
# "break it and watch it redden" and is measuring nothing.
#
# `§4c` is expected to STAY red, and that is the point of naming it: it is red
# because a request goes unanswered, and no expectation can be lowered to make
# an absent response present.
control_arm() {
	armsRun=$((armsRun + 1))
	local log="${WORK}/expect-observed.log"
	BT_ENGINE_DAP_MUTATION=expect-observed "${SUITE}" >"${log}" 2>&1
	local still
	still="$(grep -E '^\s+- §' "${log}" | sed 's/^ *- //' | grep -v '^§4c' | grep -c . || true)"
	local checks
	checks="$(grep -oE '^noir-engine-dap: [0-9]+ checks' "${log}" | grep -oE '[0-9]+' || echo 0)"
	if [ "${checks}" != "${BASE_CHECKS}" ]; then
		miss "expect-observed: made ${checks} checks, baseline made ${BASE_CHECKS} — a check stopped existing"
	elif [ "${still}" -eq 0 ]; then
		pass "expect-observed: every red check goes GREEN on the engine's own values — none is stuck red"
	else
		miss "expect-observed: ${still} check(s) stayed red on the engine's OWN reported values"
		grep -E '^\s+- §' "${log}" | grep -v '§4c' | sed 's/^/           still-red: /'
	fi
	# The negative half of the same arm, and it must be asserted rather than
	# assumed: a hang is not an expectation that can be relaxed.
	if grep -qE '^\s+- §4c' "${log}"; then
		pass "expect-observed: §4c stays red — an unanswered request is not a wrong value"
	else
		miss "expect-observed: §4c went green, so it was never about a missing response"
	fi
	armsRun=$((armsRun + 1))
}

for arm in "${ARMS[@]}"; do
	case "${arm}" in
	expect-observed)
		control_arm ;;
	oracle-truncated)
		# Traps §4b's exact shape: the loop ranges over one row fewer while the
		# claim stays 82. A count that moves demands an explanation, and §0 is
		# the check that demands it.
		suite_arm oracle-truncated "§0" 1 \
			"one oracle row silently dropped — the COUNT catches it, not the content" ;;
	flow-mode-out-of-range)
		# dialect §4's Status: the engine still accepts the legacy ordinal
		# inbound but REJECTS an out-of-range one instead of defaulting. `2` is
		# out of range for a two-member FlowMode.
		# Six, and each is a check that reads the window the refusal prevented:
		# §6a (accepted), §6b (window arrives), §6c (loop and steps), §6d
		# (expr names), §6e (resolved values), §6i (the stale twin, which
		# cannot be "smaller than" a good window that does not exist).
		suite_arm flow-mode-out-of-range "§6a" 6 \
			"flowMode 2 — an out-of-range ordinal must be refused, not defaulted" ;;
	reverse-unprefixed)
		# dialect §9: `reverseStepIn` is refused BY NAME and `ct/reverseStepIn`
		# is the extension. Sending the former where the latter belongs must
		# break the check that says the extension is dispatched.
		suite_arm reverse-unprefixed "§9b" 1 \
			"the un-prefixed spelling sent where the ct/ extension belongs" ;;
	no-engine-dir)
		# An explicitly named engine directory that is not one. The runner must
		# say WHICH file is missing — "the engine is broken" sends a reader to
		# the wrong repository.
		runner_arm no-engine-dir "is incomplete" \
			REPLAY_ENGINE_DIR="${WORK}/does-not-exist" ;;
	no-engine-fetch)
		# No directory named and none on disk: the runner falls back to
		# fetching the published engine, and that fetch fails. Distinct from
		# the arm above because it is a distinct code path with a distinct
		# message, and it is the path a fresh checkout actually takes.
		runner_arm no-engine-fetch "could not fetch the replay engine" \
			REPLAY_ENGINE_DIR="" \
			BT_REPLAY_ENGINE_DEST="${WORK}/fetch-here" \
			REPLAY_ENGINE_BASE="https://127.0.0.1:1/nothing" ;;
	no-container)
		runner_arm no-container "the Noir container is missing" \
			BT_NOIR_TRACE="${WORK}/not-a-trace.ct" ;;
	stub-wasm)
		# A proxy or captive portal answering 200 with an HTML page is the
		# realistic version of this, and it fails inside
		# WebAssembly.compileStreaming where the message names neither the
		# script nor the page.
		mkdir -p "${WORK}/stub/pkg"
		: >"${WORK}/stub/worker.js"
		: >"${WORK}/stub/pkg/db_backend.js"
		printf '<!doctype html><title>404</title>' >"${WORK}/stub/pkg/db_backend_bg.wasm"
		runner_arm stub-wasm "not an engine" REPLAY_ENGINE_DIR="${WORK}/stub" ;;
	*)
		echo "  unknown arm: ${arm}" >&2; misses=$((misses + 1)) ;;
	esac
done

echo ""
echo "noir-engine-dap self-test: ${armsRun} arms, ${passes} killed, ${misses} missed"
[ "${misses}" -eq 0 ] || exit 1
exit 0
