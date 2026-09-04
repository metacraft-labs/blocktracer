#!/usr/bin/env bash
#
# ci-coverage.sh — every suite this repository has, runs in CI, on the branches
# this repository actually ships from.
#
# WHY THIS EXISTS
# ---------------
# Measured on `dev` on 2026-09-01, before this file:
#
#   * `.github/workflows/ci.yml` triggered on `push: branches: [main]`. `main`
#     exists and is **178 commits behind `dev`**; its tip is
#     "VD.0: visual-design capture harness (pinned container UNVALIDATED)".
#     Work lands on `dev` by direct push. So EVERY job in ci.yml — contract,
#     client-sdk, visual-design, visual-design-canary, viewmodels, debug-route —
#     had not run on the mainline for 178 commits. The only trigger still firing
#     was `pull_request`, and the last recorded run of any of them was on a
#     stale side branch.
#
#   * `client/Justfile`'s `test:` aggregate names SEVEN suites. CI ran TWO.
#     The five that ran nowhere included `test-entry-state` — the suite written
#     to close the `Nargo.toml` defect, whose whole purpose is to stop that
#     defect coming back.
#
#   * `ci/test/flow-layout-vendor.sh` and its self-test were named by no job.
#
# Each of those is the same defect: a gate's SURFACE has a hole, and nothing
# measures the surface. `tools/journeys/` exists because no test stated an
# end-to-end claim; this file exists because no test stated that the tests run.
#
# It is modelled on codetracer's `ci/test/test-lane-coverage.sh`, which reads
# that repository's lane definitions and "fails by name on any test-shaped file
# no lane claims". The rule there is worth repeating here: A LANE DISCOVERS ITS
# FILES, and where a list must stay, a guard reads the list.
#
# WHAT IT CHECKS
#   1. Every target in `client/Justfile`'s `test:` aggregate is run by some job.
#   1b. Every `test-*` recipe is run by SOMETHING — in the aggregate, or named
#      by a CI job. Not "is in the aggregate": `test-selection-detail-selftest`
#      is a ~100-compile mutation sweep that client/Justfile deliberately keeps
#      out of `just test`, for the same reason every `<subject>-test.sh` is its
#      own CI step rather than part of `<subject>.sh`. Deliberately outside the
#      aggregate is fine; run by nothing is not, and that is the distinction.
#   2. Every `ci/test/*.sh` gate is run by some job, OR is recorded in
#      `ci/test/ci-coverage.known-dark.txt` with what it would cost to wire.
#      That register fails in both directions — a listed gate that becomes
#      reachable, or that stops existing, fails by name — so an entry cannot
#      outlive the hole it records. It is not an exemption list.
#   3. ci.yml's push trigger covers every branch `deploy.yml` deploys from —
#      those are the mainlines BY DEFINITION, so the two cannot disagree without
#      a branch being deployed ungated.
#   4. Every branch ci.yml names in its push trigger actually EXISTS. A trigger
#      on a branch nobody uses is indistinguishable, in the YAML, from a trigger
#      that works.
#
# Every check is COUNTED, and every subject list is asserted non-empty before
# anything quantifies over it — a parser that silently matched nothing would
# otherwise report perfect coverage of no suites at all
# (Verification-Harness-Traps.md §4).
#
# Usage:  bash ci/test/ci-coverage.sh
# Its own self-test, which plants each violation in a copy of the real files:
#         bash ci/test/ci-coverage-test.sh

set -uo pipefail

repo_root="${CI_COVERAGE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "${repo_root}" || exit 2

workflow="${repo_root}/.github/workflows/ci.yml"
deploy_workflow="${repo_root}/.github/workflows/deploy.yml"
client_justfile="${repo_root}/client/Justfile"

checks=0
failures=0
note() { printf '  %s\n' "$*"; }
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
}

for f in "${workflow}" "${deploy_workflow}" "${client_justfile}"; do
	if [ ! -f "${f}" ]; then
		echo "missing input: ${f}" >&2
		echo "  This gate cannot run, which is not the same as passing." >&2
		exit 2
	fi
done

echo "=== CI coverage — does every suite run, and on the branches we ship? ==="
echo

# ---------------------------------------------------------------------------
# The three subject lists. Each is DISCOVERED, and each is asserted non-empty
# before it is used.
# ---------------------------------------------------------------------------

# `test:` and its prerequisites, from client/Justfile. Read from the aggregate
# rather than from a list here, so a suite added to `just test` is covered by
# this guard on the next run without anyone editing this file.
client_targets="$(
	awk '/^test:/ { sub(/^test:[[:space:]]*/, ""); print; exit }' "${client_justfile}" |
		tr ' ' '\n' | grep -v '^$' | sort -u
)"
client_count="$(printf '%s\n' "${client_targets}" | grep -c . || true)"

# Every shell gate. `find`, not a list.
shell_gates="$(
	find "${repo_root}/ci/test" -maxdepth 1 -type f -name '*.sh' 2>/dev/null |
		sed "s#^${repo_root}/##" | sort
)"
# This file and its own self-test are excluded: a guard that demanded a job for
# itself before that job existed could never be landed, and the job that runs it
# is asserted separately below.
shell_gates="$(printf '%s\n' "${shell_gates}" | grep -v 'ci/test/ci-coverage' || true)"
shell_count="$(printf '%s\n' "${shell_gates}" | grep -c . || true)"

# Everything ci.yml RUNS, as one blob. Job boundaries do not matter here — the
# question is whether ANY job runs the thing, not which.
#
# COMMENT LINES ARE DROPPED BEFORE ANYTHING IS COUNTED. This file's first draft
# scanned the whole workflow, and its own selftest caught the consequence: the
# doc comment above a step says "`cd client && just test` names seven suites",
# so deleting the step that RUNS the aggregate left the guard green — it was
# reading the prose that describes the step, not the step.
#
# Verification-Harness-Traps.md §4d, twice in one afternoon: the same pattern
# also matched ci.yml's comment about the `main` trigger and made three
# selftest arms silently no-ops. A scanner that reads its subject's own
# documentation is satisfied by anything that documentation says.
#
# `renderer-host-reach-budget.sh` in the sibling repo states the same rule and
# the same reason: "Comment lines are dropped BEFORE counting."
workflow_all="$(grep -vE '^\s*#' "${workflow}")"

echo "Step 0: the subject lists are non-empty"
echo "    A parser that matched nothing reports perfect coverage of nothing."
if [ "${client_count}" -ge 5 ]; then
	ok "client/Justfile's \`test:\` aggregate names ${client_count} suites"
else
	bad "parsed only ${client_count} suite(s) out of client/Justfile's \`test:\` aggregate — the parser is broken, and every per-suite check below would be vacuous"
fi
if [ "${shell_count}" -ge 5 ]; then
	ok "ci/test/ carries ${shell_count} shell gates"
else
	bad "found only ${shell_count} shell gate(s) in ci/test/ — the scan is broken"
fi
if [ "${failures}" -gt 0 ]; then
	echo
	echo "RESULT: FAILED — the subjects could not be read, so nothing was measured"
	exit 1
fi
echo

# ---------------------------------------------------------------------------
echo "Step 1: every suite in \`cd client && just test\` runs in CI"
echo "    Five of seven did not, and one of them was the suite written to keep"
echo "    the Nargo.toml defect from coming back."
# ---------------------------------------------------------------------------

# A job may claim a suite in either of two ways, and both are legitimate:
#
#   * by NAME              `just test-entry-state`
#   * by the AGGREGATE     `just test`, which runs every prerequisite
#
# Recognising the aggregate matters. Running the seven suites as seven named
# steps would put a THIRD list in the tree — the Justfile's, this guard's, and
# the workflow's — and adding a suite to two of three is exactly how the five
# orphans happened. With the aggregate recognised, `just test` is the only place
# a suite is named, and this guard reads that same place.
aggregate_runs=0
if printf '%s' "${workflow_all}" | grep -qE "just[[:space:]]+test([^a-z0-9-]|$)"; then
	aggregate_runs=1
	ok "a CI job runs the \`just test\` aggregate, which covers every prerequisite it names"
fi

uncovered_client=0
while read -r target; do
	[ -n "${target}" ] || continue
	if [ "${aggregate_runs}" -eq 1 ]; then
		ok "client suite '${target}' is covered (via the \`just test\` aggregate)"
	elif printf '%s' "${workflow_all}" | grep -qE "just[[:space:]]+${target}([^a-z0-9-]|$)"; then
		ok "client suite '${target}' is run by a CI job, by name"
	else
		uncovered_client=$((uncovered_client + 1))
		bad "client suite '${target}' is in \`just test\` and NO CI job runs it"
	fi
done <<<"${client_targets}"
echo

# ---------------------------------------------------------------------------
echo "Step 1b: every test-* recipe is RUN by something"
echo "    Recognising the aggregate closes one hole and opens a smaller one: a"
echo "    suite written as a recipe and never added to \`test:\` is run by"
echo "    nothing and named by nothing, so step 1 cannot see it either."
echo "    In the aggregate, or named by a CI job — a recipe deliberately kept"
echo "    OUT of \`just test\` is fine; a recipe nothing runs at all is not."
# ---------------------------------------------------------------------------
declared_recipes="$(
	grep -oE '^test-[a-z0-9-]+:' "${client_justfile}" | sed 's/:$//' | sort -u
)"
recipe_count="$(printf '%s\n' "${declared_recipes}" | grep -c . || true)"
if [ "${recipe_count}" -ge 5 ]; then
	ok "client/Justfile defines ${recipe_count} test-* recipes"
else
	bad "found only ${recipe_count} test-* recipe(s) — the scan is broken and this step is vacuous"
fi

# TWO WAYS FOR A RECIPE TO BE RUN, and the second one is not a loophole.
#
# The rule this step began as — "every test-* recipe is IN the aggregate" — is
# very slightly wrong, and `test-selection-detail-selftest` is the case that
# shows how. It is a MUTATION SWEEP over the suite beside it (79 negations plus
# 17 planted product defects, ~100 Nim compiles), and client/Justfile says in
# its own words why it is not an aggregate member:
#
#     NOT in `just test` — it is ~100 compiles and takes minutes. It is the
#     same relation `ci/test/<subject>-test.sh` has to `ci/test/<subject>.sh`
#
# That relation is one this repository already runs everywhere: every
# `<subject>-test.sh` is a proof-of-bite executed as its OWN CI step, never
# folded into the suite it proves. Forcing this one into `just test` would put
# minutes of mutation sweep into every developer's `just test` and into the
# `debug-route` job, to satisfy a guard — the tail wagging the dog.
#
# So what this step actually wants to know is NOT "is it in the aggregate". It
# is "does anything run it". A recipe in the aggregate is run; a recipe a CI job
# names is run; a recipe in neither is the orphan the step was written for, and
# is still reported. The by-name test is the same one step 1 already applies,
# so this adds no new parsing and no new list.
orphan_recipes=0
by_name=0
while read -r r; do
	[ -n "${r}" ] || continue
	if printf '%s\n' "${client_targets}" | grep -qx -- "${r}"; then
		:
	elif printf '%s' "${workflow_all}" | grep -qE "just[[:space:]]+${r}([^a-z0-9-]|\$)"; then
		# Named by a CI job, deliberately outside the aggregate. Reported
		# rather than passed over in silence: a recipe on this path is one
		# nobody running `just test` will ever execute, and that is worth
		# seeing in the log.
		by_name=$((by_name + 1))
		ok "recipe '${r}' is outside the \`test:\` aggregate BUT a CI job runs it by name"
	else
		orphan_recipes=$((orphan_recipes + 1))
		bad "recipe '${r}' is defined in client/Justfile and is run by NOTHING — not in the \`test:\` aggregate, and named by no CI job"
	fi
done <<<"${declared_recipes}"
if [ "${orphan_recipes}" -eq 0 ]; then
	ok "all ${recipe_count} test-* recipes are run — $((recipe_count - by_name)) via the aggregate, ${by_name} by name in CI"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: every ci/test/*.sh gate runs in CI, or is RECORDED as dark"
echo "    A gate nothing runs is a hole. A gate nothing runs, written down"
echo "    with why, is a known hole — which is a different object, and the"
echo "    register below fails in BOTH directions so it cannot outlive it."
# ---------------------------------------------------------------------------
# THE KNOWN-DARK REGISTER, ported from codetracer's
# `ci/test/shell-gate-coverage.known-dark.txt` rather than reinvented. Its rule,
# in its own words, is why this exists instead of five more workflow steps:
#
#     Wiring them is deliberately NOT done here. Each needs an owner who knows
#     what it costs to run, what it needs on the runner, and whether it passes
#     today — and a guard author quietly adding five unknown jobs to CI would be
#     making five decisions that are not theirs. What is done here is making the
#     number impossible to lose.
#
# IT IS NOT AN EXEMPTION LIST. An entry does not say "this need not run". It
# says "this SHOULD run, nothing runs it, and here is what it would cost". So:
#
#   * listed and dark      -> reported, does not fail. The hole is known.
#   * listed and REACHABLE -> FAILS, by name, demanding the line be deleted, so
#                             an entry cannot outlive the hole it records and
#                             nobody has to remember to clean up after wiring.
#   * listed and ABSENT    -> FAILS. An entry for a file that no longer exists
#                             is a claim about nothing, and it would sit there
#                             silently excusing a name that could come back.
#   * unlisted and dark    -> FAILS, exactly as before.
#
# Basenames, matching codetracer's file, so the two registers read alike.
known_dark_file="${repo_root}/ci/test/ci-coverage.known-dark.txt"
known_dark=""
if [ -f "${known_dark_file}" ]; then
	known_dark="$(sed 's/#.*//' "${known_dark_file}" | tr -d '[:blank:]' | grep -v '^$' || true)"
fi
known_dark_count="$(printf '%s\n' "${known_dark}" | grep -c . || true)"

uncovered_shell=0
recorded_dark=0
register_problems=0
while read -r gate; do
	[ -n "${gate}" ] || continue
	base="$(basename "${gate}")"
	listed=0
	if [ -n "${known_dark}" ] && printf '%s\n' "${known_dark}" | grep -qxF -- "${base}"; then
		listed=1
	fi

	if printf '%s' "${workflow_all}" | grep -qF -- "${gate}"; then
		if [ "${listed}" -eq 1 ]; then
			register_problems=$((register_problems + 1))
			bad "shell gate '${gate}' IS run by a CI job and is still listed in ci/test/ci-coverage.known-dark.txt — delete that line"
		else
			ok "shell gate '${gate}' is run by a CI job"
		fi
	elif [ "${listed}" -eq 1 ]; then
		recorded_dark=$((recorded_dark + 1))
		note "[DARK]   shell gate '${gate}' is run by no CI job, and is RECORDED in ci/test/ci-coverage.known-dark.txt"
	else
		uncovered_shell=$((uncovered_shell + 1))
		bad "shell gate '${gate}' exists and NO CI job runs it"
	fi
done <<<"${shell_gates}"

# Every entry must name a gate that is really there. A register that accrues
# names of deleted files is one that will one day excuse a file that comes back.
while read -r entry; do
	[ -n "${entry}" ] || continue
	if [ ! -f "${repo_root}/ci/test/${entry}" ]; then
		register_problems=$((register_problems + 1))
		bad "ci/test/ci-coverage.known-dark.txt names '${entry}', which does not exist in ci/test/ — delete that line"
	fi
done <<<"${known_dark}"

# ONLY ONE KIND OF DARKNESS IS ALLOWED IN, and this is where that is decided.
#
#   LEGITIMATE — a capability the gate needs genuinely does not exist yet. The
#   entry must NAME it, so the register records what would have to become true
#   for the line to go.
#   NOT LEGITIMATE — the gate could run and nobody wired it. That is an unwired
#   gate, not a dark one, and it does not land.
#
# The two are indistinguishable in a bare list of filenames, which is exactly
# how a register slides from "known holes, with their causes" into "the place
# you put a gate you did not want to think about". Requiring the capability to
# be named is what keeps the first kind first: you cannot write the line without
# stating the thing that is missing, and a stated thing can be checked and
# eventually discharged.
#
# The rule is mechanical rather than social — a convention nobody checks is how
# the second kind gets in. Each entry's preceding comment block must carry a
# `MISSING CAPABILITY:` line; `ci-coverage-test.sh` plants one without and
# requires this to fail.
if [ -n "${known_dark}" ]; then
	while read -r entry_and_cap; do
		[ -n "${entry_and_cap}" ] || continue
		entry="${entry_and_cap%% *}"
		has_cap="${entry_and_cap##* }"
		if [ "${has_cap}" = "yes" ]; then
			ok "known-dark '${entry}' names the capability it is waiting on"
		else
			register_problems=$((register_problems + 1))
			bad "ci/test/ci-coverage.known-dark.txt lists '${entry}' with no 'MISSING CAPABILITY:' line above it — a gate nobody wired is not a dark gate, so either name what is missing or write the job"
		fi
	done < <(
		awk '
			/^[[:space:]]*#/ { if ($0 ~ /MISSING CAPABILITY:/) cap = 1; next }
			/^[[:space:]]*$/ { next }
			{
				sub(/#.*/, ""); gsub(/[[:blank:]]/, "")
				if ($0 != "") print $0, (cap ? "yes" : "no")
				cap = 0
			}
		' "${known_dark_file}"
	)
fi

if [ "${known_dark_count}" -gt 0 ] && [ "${register_problems}" -eq 0 ]; then
	ok "${known_dark_count} gate(s) recorded as known-dark, and each is still dark and still present"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 3: ci.yml gates every branch deploy.yml deploys from"
echo "    Those branches are the mainlines by definition. A branch that is"
echo "    deployed and not gated is the hole this file was written for."
# ---------------------------------------------------------------------------
# The push branch list of a workflow, as a newline-separated set. Read from the
# `on: push: branches: [...]` line in either flow or inline form.
push_branches_of() {
	python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
# PyYAML parses the key `on:` as the boolean True.
on = d.get(True, d.get("on", {})) or {}
push = (on.get("push") or {}) if isinstance(on, dict) else {}
for b in (push.get("branches") or []):
    print(b)
PY
}

ci_branches="$(push_branches_of "${workflow}" 2>/dev/null || true)"
deploy_branches="$(push_branches_of "${deploy_workflow}" 2>/dev/null || true)"
deploy_count="$(printf '%s\n' "${deploy_branches}" | grep -c . || true)"

if [ "${deploy_count}" -ge 1 ]; then
	ok "deploy.yml deploys from ${deploy_count} branch(es): $(printf '%s' "${deploy_branches}" | tr '\n' ' ')"
else
	bad "could not read deploy.yml's push branches — step 3 would be vacuous"
fi

ungated=0
while read -r b; do
	[ -n "${b}" ] || continue
	if printf '%s\n' "${ci_branches}" | grep -qx -- "${b}"; then
		ok "branch '${b}' is deployed AND gated by ci.yml"
	else
		ungated=$((ungated + 1))
		bad "branch '${b}' is DEPLOYED by deploy.yml and NOT gated by ci.yml — every job in ci.yml is dark on it"
	fi
done <<<"${deploy_branches}"
echo

# ---------------------------------------------------------------------------
echo "Step 4: every branch ci.yml names actually exists"
echo "    A trigger on a dead branch looks exactly like a trigger that works."
echo "    ci.yml named \`main\`, which was 178 commits behind dev and unused."
# ---------------------------------------------------------------------------
if ! git -C "${repo_root}" rev-parse --git-dir >/dev/null 2>&1; then
	note "not a git checkout; skipping (this is a SKIP, not a pass)"
else
	dead=0
	live=0
	while read -r b; do
		[ -n "${b}" ] || continue
		if git -C "${repo_root}" show-ref --verify --quiet "refs/remotes/origin/${b}" ||
			git -C "${repo_root}" show-ref --verify --quiet "refs/heads/${b}"; then
			live=$((live + 1))
		else
			dead=$((dead + 1))
			bad "ci.yml triggers on branch '${b}', which does not exist here"
		fi
	done <<<"${ci_branches}"

	# The positive control: if NOTHING resolved, the resolver is broken and the
	# zero above means nothing (Verification-Harness-Traps.md §4a).
	if [ "${live}" -ge 1 ]; then
		ok "${live} of ci.yml's trigger branches resolve, so the resolver works and the count above is a measurement"
	else
		bad "NONE of ci.yml's trigger branches resolve — the resolver is broken, not the workflow"
	fi
fi
echo

# ---------------------------------------------------------------------------
# THE DARK COUNT IS PRINTED HERE, PASS OR FAIL.
#
# The old footer read "client suites: N declared, 0 uncovered" and nothing else,
# and that line is how this gate got misread: it counts AGGREGATE MEMBERS, so it
# says "0 uncovered" while step 1b is failing about a recipe that is not one —
# a true sentence standing next to `RESULT: FAILED` and taken for the verdict.
# A number that cannot express the failure beside it invites exactly that.
echo "${checks} check(s), ${failures} failure(s)"
echo "  client suites: ${client_count} in \`just test\`, ${uncovered_client} uncovered"
echo "                 (${recipe_count} test-* recipes exist; ${by_name} run by CI outside the aggregate)"
echo "  shell gates:   ${shell_count} found,    ${uncovered_shell} uncovered, ${recorded_dark} recorded dark"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
if [ "${recorded_dark}" -gt 0 ]; then
	echo "  Every suite this repository has either runs in CI, on every branch it"
	echo "  deploys, or is one of the ${recorded_dark} recorded in ci/test/ci-coverage.known-dark.txt."
	echo "  THOSE ${recorded_dark} DO NOT RUN ANYWHERE. This gate is green because the hole is"
	echo "  written down with its cost, not because it is closed."
else
	echo "  Every suite this repository has runs in CI, on every branch it deploys."
fi
echo "  NOT claimed: that those suites pass, or that they assert anything useful."
echo "  This gate measures the SURFACE, and nothing else does."
echo "RESULT: OK"
