#!/usr/bin/env bash
#
# ci-coverage-test.sh — does ci-coverage.sh bite?
#
# The repository convention: every `ci/test/<subject>.sh` has a
# `<subject>-test.sh` beside it that plants deliberate violations and proves the
# check reports them. `client-sdk-boundary-test.sh` builds "synthetic trees with
# deliberate violations"; `check-tokens-selftest.mjs` plants "each violation in
# the real source and restores it byte-identically".
#
# This one works on a COPY of the real tree rather than mutating it, because the
# subject is a set of workflow and Justfile files that other agents are editing
# concurrently — a mutate-and-restore here would race them. The copy carries the
# real files, so an arm that stops applying is caught by its `before` control
# exactly as `tools/journeys/selftest.mjs`'s arms are.
#
# ONE ARM PER RULE THE GUARD ENFORCES, plus the control that the unmutated tree
# is green — without which "the mutation made it red" is not a statement about
# the mutation.
#
# THE COUNT IS NOT WRITTEN DOWN HERE. It said "four" while five arms ran, and
# then would have said "four" while nine did: a sentence describing a check does
# not get corrected when the check does. The banner and the footer below count
# what actually executed instead.
#
# Most arms demand a RED and are driven by `arm`. Arm 2b is the exception and is
# spelled out longhand: the known-dark register is supposed to keep the run
# GREEN while still naming the hole, so its assertion is "green AND the gate is
# still named", which is not a shape `arm` can express.
#
# Usage:  bash ci/test/ci-coverage-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/ci-coverage.sh"

checks=0
failures=0
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# A copy carrying only what the guard reads, plus the git metadata step 4 needs.
stage() {
	local dest="$1"
	rm -rf "${dest}"
	mkdir -p "${dest}/.github/workflows" "${dest}/client" "${dest}/ci/test"
	cp "${repo_root}/.github/workflows/ci.yml" "${dest}/.github/workflows/"
	cp "${repo_root}/.github/workflows/deploy.yml" "${dest}/.github/workflows/"
	cp "${repo_root}/client/Justfile" "${dest}/client/"
	cp "${repo_root}"/ci/test/*.sh "${dest}/ci/test/"
	# The known-dark register. Without this the staged tree has no register at
	# all, the two recorded Noir gates read as plain orphans, and the CONTROL
	# below would be red — which would disable every arm in this file.
	cp "${repo_root}/ci/test/ci-coverage.known-dark.txt" "${dest}/ci/test/" 2>/dev/null || true
	# A real git dir, so step 4 resolves branches rather than skipping. The
	# branches are created to match what the workflows name, so the BASELINE is
	# green and arm 4 has something to take away.
	git -C "${dest}" init -q 2>/dev/null
	git -C "${dest}" config user.email t@t && git -C "${dest}" config user.name t
	git -C "${dest}" add -A >/dev/null 2>&1
	git -C "${dest}" commit -qm base >/dev/null 2>&1
	local b
	while read -r b; do
		[ -n "${b}" ] || continue
		git -C "${dest}" branch -f "${b}" >/dev/null 2>&1
	done < <(python3 - "${dest}/.github/workflows/ci.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get("on", {})) or {}
for b in ((on.get("push") or {}).get("branches") or []): print(b)
PY
	)
}

run_guard() {
	CI_COVERAGE_ROOT="$1" bash "${guard}" 2>&1
}

# Edit the first NON-COMMENT line matching a pattern.
#
# The first draft of arms 1, 3 and 4 used a bare `re.sub` over the whole file and
# all three silently did nothing: the pattern `branches:\s*\[[^\]]*\]` matched
# ci.yml's own DOC COMMENT — the sentence explaining that the trigger used to
# read `branches: [main]` — and rewrote it to itself. The arms then reported
# SURVIVED against a file they had not changed.
#
# That is Verification-Harness-Traps.md §4d exactly ("a scan pattern that matches
# the module's own doc comment is satisfied by prose"), walked into by the
# selftest of a gate written about scanners. It is caught here rather than
# shipped because every arm asserts its own mutation applied before measuring —
# which is the rule §1a states, and the reason `arm()` fails on a mutation
# function returning non-zero.
edit_line() {
	python3 - "$@" <<'PY'
import sys, re
path, pattern, repl = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).readlines()
for i, ln in enumerate(lines):
    if ln.lstrip().startswith("#"):
        continue
    new = re.sub(pattern, repl, ln)
    if new != ln:
        lines[i] = new
        open(path, "w").writelines(lines)
        sys.exit(0)
sys.exit(1)   # nothing changed: the arm must fail, not measure
PY
}

# Delete the first non-comment line matching, and the step name above it.
delete_step() {
	python3 - "$@" <<'PY'
import sys, re
path, pattern = sys.argv[1], sys.argv[2]
lines = open(path).readlines()
for i, ln in enumerate(lines):
    if ln.lstrip().startswith("#"):
        continue
    if re.search(pattern, ln):
        # Walk back to the `- name:` that owns this run line, and forward to the
        # next step, so the YAML stays valid.
        start = i
        while start > 0 and not lines[start].lstrip().startswith("- name:"):
            start -= 1
        end = i + 1
        while end < len(lines) and not lines[end].lstrip().startswith("- name:"):
            end += 1
        del lines[start:end]
        open(path, "w").writelines(lines)
        sys.exit(0)
sys.exit(1)
PY
}

echo "=== ci-coverage selftest — every arm aimed at one rule ==="
echo

# ---------------------------------------------------------------------------
# THE CONTROL. Without a green baseline, every red below is unattributable.
# ---------------------------------------------------------------------------
stage "${work}/base"
base_out="$(run_guard "${work}/base")"
if printf '%s' "${base_out}" | grep -q 'RESULT: OK'; then
	ok "CONTROL: the real tree is green, so a red below is caused by the mutation"
else
	bad "CONTROL: the real tree is ALREADY RED — no arm below can demonstrate anything"
	printf '%s\n' "${base_out}" | grep -E '^\s+\[FAILED\]' | sed 's/^/           /'
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED"
	exit 1
fi
echo

arm() {
	local name="$1" expect="$2"
	shift 2
	stage "${work}/arm"
	# The mutation is applied by the caller's function body, against ${work}/arm.
	"$@" || {
		bad "${name}: the mutation could not be applied"
		return
	}
	local out
	out="$(run_guard "${work}/arm")"
	if printf '%s' "${out}" | grep -q 'RESULT: OK'; then
		bad "${name}: SURVIVED — the guard is still green with the defect in place"
		return
	fi
	if printf '%s' "${out}" | grep -qF -- "${expect}"; then
		ok "${name}: killed — \"$(printf '%s' "${out}" | grep -oF -- "${expect}" | head -1)\""
	else
		bad "${name}: went red, but not for its own reason (expected to see: ${expect})"
		printf '%s\n' "${out}" | grep -E '^\s+\[FAILED\]' | head -3 | sed 's/^/           /'
	fi
}

# ARM 1 — a client suite that no job runs. This is the state that was LIVE:
# ci.yml ran `just test-debug-route` and `just test-export` by name and never the
# aggregate, so the other five suites were dark. The mutation takes the aggregate
# back out.
mutate_orphan_suite() {
	delete_step "${work}/arm/.github/workflows/ci.yml" "just test'" || return 1
	# The mutation must actually have removed it, or the arm measures nothing.
	! grep -qE "just[[:space:]]+test'" "${work}/arm/.github/workflows/ci.yml"
}
arm "1/a suite no job runs" "and NO CI job runs it" mutate_orphan_suite

# ARM 1b — a test-* recipe that exists but is not in the aggregate. Recognising
# the aggregate closes arm 1's hole and opens this one; both are checked.
mutate_recipe_outside_aggregate() {
	printf '\ntest-a-recipe-outside-the-aggregate:\n    echo hi\n' \
		>>"${work}/arm/client/Justfile"
}
arm "1b/a recipe outside the aggregate" "is run by NOTHING" mutate_recipe_outside_aggregate

# ARM 1c — THE EXEMPTION PATH, PROVED FROM THE OTHER SIDE.
#
# Step 1b accepts a recipe that is outside `just test` when a CI job names it,
# because `test-selection-detail-selftest` is deliberately outside the aggregate
# (client/Justfile says why: ~100 compiles) and is run by its own step. An
# acceptance nobody has seen fail is indistinguishable from a hole: if the step
# that names it were deleted, the guard must NOTICE, or the exemption is just a
# way of not checking.
#
# So: leave the recipe exactly where it is and take the CI step away. `edit_line`
# rather than `delete_step`, because this step is the last of its job and
# deleting through to the next `- name:` would take the following job's header
# with it — mutating a second thing, which is the arm measuring something it did
# not aim at.
mutate_unname_the_selftest_step() {
	edit_line "${work}/arm/.github/workflows/ci.yml" \
		'just test-selection-detail-selftest' 'just test-a-recipe-that-is-not-this-one' || return 1
	# The mutation must have applied, and the recipe must still be declared —
	# otherwise this arm is measuring a Justfile change it did not make.
	! grep -q 'just test-selection-detail-selftest' "${work}/arm/.github/workflows/ci.yml" &&
		grep -q '^test-selection-detail-selftest:' "${work}/arm/client/Justfile"
}
arm "1c/the by-name exemption, with the CI step taken away" \
	"'test-selection-detail-selftest' is defined in client/Justfile and is run by NOTHING" \
	mutate_unname_the_selftest_step

# ARM 2 — a shell gate in ci/test/ that no job runs.
mutate_orphan_gate() {
	printf '#!/usr/bin/env bash\nexit 0\n' >"${work}/arm/ci/test/a-gate-nobody-runs.sh"
}
arm "2/orphaned shell gate" "a-gate-nobody-runs.sh' exists and NO CI job runs it" mutate_orphan_gate

# ── THE KNOWN-DARK REGISTER, DRIVEN IN BOTH DIRECTIONS ──────────────────────
#
# The register is the one part of this guard that can turn a failure into a
# pass, so it is the part most worth attacking. Three arms, because it has three
# ways to be wrong, and only the first is the one it was written for.

# ARM 2b — the register must not become a blanket exemption. Listing a gate is
# supposed to record a KNOWN hole, not silence the check; if an entry could be
# added for anything, step 2 would be a formality. This plants the orphan of arm
# 2 AND lists it, and demands the guard still reports it as dark by name — a
# `[DARK]` note rather than a silent [OK].
mutate_listed_orphan_is_still_reported() {
	printf '#!/usr/bin/env bash\nexit 0\n' >"${work}/arm/ci/test/a-gate-nobody-runs.sh"
	printf '\na-gate-nobody-runs.sh\n' >>"${work}/arm/ci/test/ci-coverage.known-dark.txt"
	grep -q 'a-gate-nobody-runs.sh' "${work}/arm/ci/test/ci-coverage.known-dark.txt"
}
# This one is EXPECTED TO PASS the guard — the hole is recorded — so it cannot
# use `arm`, which demands a red. The assertion is that the dark gate is still
# NAMED in the output, and that the run is green.
stage "${work}/arm"
mutate_listed_orphan_is_still_reported >/dev/null || bad "2b: the mutation could not be applied"
out2b="$(run_guard "${work}/arm")"
if printf '%s' "${out2b}" | grep -q 'RESULT: OK' &&
	printf '%s' "${out2b}" | grep -qF "[DARK]   shell gate 'ci/test/a-gate-nobody-runs.sh'"; then
	ok "2b/a recorded dark gate: green, and still reported by name as DARK"
elif printf '%s' "${out2b}" | grep -q 'RESULT: OK'; then
	bad "2b: the register silenced the gate instead of recording it — no [DARK] line names it"
else
	bad "2b: a gate recorded in the register still failed the run — the register does nothing"
fi

# ARM 3b — THE DIRECTION THAT MAKES THE REGISTER SAFE TO HAVE. An entry that
# outlives its hole is worse than no entry: it sits there excusing a gate that
# is now wired, and the next gate to go dark under that name is excused too.
# So a listed gate that BECOMES REACHABLE must fail, by name, demanding the line
# go. Here: list a gate that a CI job already runs.
mutate_stale_register_entry() {
	printf '\nflow-layout-vendor.sh\n' >>"${work}/arm/ci/test/ci-coverage.known-dark.txt"
}
arm "3b/an entry that outlived its hole" \
	"IS run by a CI job and is still listed in ci/test/ci-coverage.known-dark.txt — delete that line" \
	mutate_stale_register_entry

# ARM 3c — an entry naming a gate that does not exist. A register that accrues
# dead names is one that will one day silently excuse a file coming back under
# a name somebody deleted years earlier.
mutate_register_names_a_ghost() {
	printf '\na-gate-that-was-deleted.sh\n' >>"${work}/arm/ci/test/ci-coverage.known-dark.txt"
}
arm "3c/an entry naming a gate that is gone" \
	"which does not exist in ci/test/ — delete that line" \
	mutate_register_names_a_ghost

# ARM 3 — a branch that is deployed and not gated. THIS IS THE DEFECT THAT WAS
# LIVE: ci.yml triggered on `main` while dev/staging/live were deployed.
mutate_ungated_branch() {
	# Put the trigger back the way it was found on 2026-09-01.
	edit_line "${work}/arm/.github/workflows/ci.yml" \
		'branches:[ ]*\[[^]]*\]' 'branches: [main]'
}
arm "3/a deployed branch nothing gates" "is DEPLOYED by deploy.yml and NOT gated" mutate_ungated_branch

# ARM 4 — a trigger naming a branch that does not exist.
mutate_dead_branch() {
	edit_line "${work}/arm/.github/workflows/ci.yml" \
		'(branches:[ ]*\[)([^]]*)(\])' '\1\2, a-branch-that-never-existed\3'
}
arm "4/a trigger on a dead branch" "which does not exist here" mutate_dead_branch

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — every arm must be killed by the rule written for it"
	exit 1
fi
echo "  The guard reports each of the $((checks - 1)) planted holes, and only then."
echo "RESULT: OK"
