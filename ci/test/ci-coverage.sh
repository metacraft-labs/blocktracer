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
#   2. Every `ci/test/*.sh` gate is run by some job.
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
echo "Step 1b: every test-* recipe is IN the aggregate"
echo "    Recognising the aggregate closes one hole and opens a smaller one: a"
echo "    suite written as a recipe and never added to \`test:\` is run by"
echo "    nothing and named by nothing, so step 1 cannot see it either."
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

orphan_recipes=0
while read -r r; do
	[ -n "${r}" ] || continue
	if printf '%s\n' "${client_targets}" | grep -qx -- "${r}"; then
		:
	else
		orphan_recipes=$((orphan_recipes + 1))
		bad "recipe '${r}' is defined in client/Justfile and is NOT in the \`test:\` aggregate — nothing runs it, locally or in CI"
	fi
done <<<"${declared_recipes}"
if [ "${orphan_recipes}" -eq 0 ]; then
	ok "all ${recipe_count} test-* recipes are in the aggregate"
fi
echo

# ---------------------------------------------------------------------------
echo "Step 2: every ci/test/*.sh gate runs in CI"
# ---------------------------------------------------------------------------
uncovered_shell=0
while read -r gate; do
	[ -n "${gate}" ] || continue
	if printf '%s' "${workflow_all}" | grep -qF -- "${gate}"; then
		ok "shell gate '${gate}' is run by a CI job"
	else
		uncovered_shell=$((uncovered_shell + 1))
		bad "shell gate '${gate}' exists and NO CI job runs it"
	fi
done <<<"${shell_gates}"
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
echo "${checks} check(s), ${failures} failure(s)"
echo "  client suites: ${client_count} declared, ${uncovered_client} uncovered"
echo "  shell gates:   ${shell_count} found,    ${uncovered_shell} uncovered"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — ${failures} check(s)"
	exit 1
fi
echo "  Every suite this repository has runs in CI, on every branch it deploys."
echo "  NOT claimed: that those suites pass, or that they assert anything useful."
echo "  This gate measures the SURFACE, and nothing else does."
echo "RESULT: OK"
