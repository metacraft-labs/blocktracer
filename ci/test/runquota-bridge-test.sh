#!/usr/bin/env bash
#
# runquota-bridge-test.sh — three sessions on one host, each running `just
# test`, share ONE RunQuota budget, and the high-priority session is served
# first.
#
# WHY IT EXISTS. `just test` compiles and runs a couple of dozen Nim suites.
# Three agent sessions, or three checkouts, on one host each assume they own
# every core, so together they oversubscribe it. The Justfiles route those
# commands through `{{rq}}` (`runquota.just`: `runquota run --` when RunQuota
# is installed) so that each one takes a lease from the host budget and runs at
# the width it was granted. This is the gate that says the routing is real: it
# is what fails when somebody drops `{{rq}}` from a recipe, and nothing else
# in the tree would notice, because every suite still passes without it.
#
# WHAT IS REAL.
#   * the real `just` runs the REAL `Justfile`, `client/Justfile` and
#     `runquota.just` of this repository (copied into three staged checkouts);
#   * a REAL `runquotad` on a private socket in a scratch directory, with a
#     small budget (2 CPU slots), and the REAL `runquota run` bridge;
#   * peak concurrency is MEASURED BY SAMPLING /proc every 30 ms for the whole
#     run (counting live stub processes), not read back from anyone's log.
#
# WHAT IS MOCKED, AND WHY. `nim` and `node` are STUB executables placed first
# on PATH, and `ci/test/client-sdk-boundary*.sh` are stubbed to exit 0 in the
# staged checkouts. The real `just test` is hours of compilation (one suite
# alone is ~37 minutes) and needs the full dev shell, so running it three times
# over to measure scheduling would measure the compiler. The property under
# test is which commands the Justfiles hand to the bridge and that the bridge
# bounds them; the stub `nim` stands in for "a process that holds one
# compile/test slot for 0.5 s" and logs the argv and RUNQUOTA_RUN_WIDTH it was
# started with. It never forks (a forked child would show up twice in the
# sampler), which is why it waits with a timed `read` on a FIFO instead of
# `sleep`.
#
# THE FALSIFYING MUTATION is built in: `--mutate-drop-bridge` strips `{{rq}} `
# from the staged Justfiles. The run must then FAIL (three sessions run at
# once, over the budget). That is the arm that shows the measurement can
# fail; `--mutate-drop-bridge` exits 0 only when it did fail, so it is a gate
# in its own right.
#
# Run: bash ci/test/runquota-bridge-test.sh [--require] [--mutate-drop-bridge]
#
# Exit codes:
#   0  every check passed (with --mutate-drop-bridge: the mutated run failed,
#      as it must)
#   1  a check failed (with --mutate-drop-bridge: the mutated run PASSED,
#      which means the test cannot tell a bridged Justfile from an unbridged one)
#   3  not run: no `runquota` with the `run` verb plus `runquotad`, or no
#      /proc (and --require was not given; with --require this is exit 1)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
require=0
mutate=0
for arg in "$@"; do
	case "${arg}" in
	--require) require=1 ;;
	--mutate-drop-bridge) mutate=1 ;;
	*)
		echo "unknown argument: ${arg}" >&2
		exit 2
		;;
	esac
done

not_run() {
	echo "NOT RUN: $*" >&2
	if [ "${require}" -eq 1 ]; then exit 1; fi
	exit 3
}

# Budget in whole CPU slots, and how long one stub "suite" holds its slot.
budget_slots=2
stub_seconds=0.5
# The whole test is bounded; a hung daemon or a lost grant must fail it, not
# hang the runner.
deadline_seconds=300

[ -d /proc/self ] || not_run "no /proc: the sampler needs a Linux /proc"
command -v just >/dev/null 2>&1 || not_run "no just on PATH"
rq_cli="$(command -v runquota 2>/dev/null || true)"
[ -n "${RUNQUOTA_BIN_DIR:-}" ] && rq_cli="${RUNQUOTA_BIN_DIR}/runquota"
[ -x "${rq_cli}" ] || not_run "no runquota on PATH (or in RUNQUOTA_BIN_DIR)"
rq_dir="$(dirname "${rq_cli}")"
rqd="${rq_dir}/runquotad"
[ -x "${rqd}" ] || not_run "no runquotad beside ${rq_cli}"
# A runquota that predates `run` prints its usage and exits 0 for it.
if ! "${rq_cli}" run --adapter list 2>/dev/null | grep -q '^adapters'; then
	not_run "${rq_cli} has no \`run\` verb"
fi

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

work="$(mktemp -d "${TMPDIR:-/tmp}/btrq.XXXXXX")"
daemon_pid=""
sampler_pid=""
cleanup() {
	# Only processes this script started.
	if [ -n "${sampler_pid}" ]; then kill "${sampler_pid}" 2>/dev/null || true; fi
	if [ -n "${daemon_pid}" ]; then
		kill "${daemon_pid}" 2>/dev/null || true
		wait "${daemon_pid}" 2>/dev/null || true
	fi
	rm -rf "${work:?}"
}
trap cleanup EXIT

# --- the stub toolchain ------------------------------------------------------
stubs="${work}/stubs"
mkdir -p "${stubs}"
mkfifo "${stubs}/hold"
log="${work}/stub.log"
: >"${log}"
cat >"${stubs}/nim" <<'STUB'
#!/usr/bin/env bash
# Stub `nim`: holds one slot for BTRQ_STUB_SECONDS. No fork, so exactly one
# process per invocation is visible to the sampler.
case "${1:-}" in --version) echo "Nim Compiler stub"; exit 0 ;; esac
here="$(cd "${BASH_SOURCE[0]%/*}" && pwd)"
printf 'start %s %s width=%s argv=%s\n' "${EPOCHREALTIME}" "${RUNQUOTA_SESSION:-}" \
	"${RUNQUOTA_RUN_WIDTH:--}" "$*" >>"${BTRQ_LOG}"
read -r -t "${BTRQ_STUB_SECONDS}" -u 9 9<>"${here}/hold"
printf 'end %s %s\n' "${EPOCHREALTIME}" "${RUNQUOTA_SESSION:-}" >>"${BTRQ_LOG}"
STUB
printf '#!/bin/sh\nexit 0\n' >"${stubs}/node"
chmod +x "${stubs}/nim" "${stubs}/node"

# --- three staged checkouts of this repository's Justfiles -------------------
stage() {
	local dir="$1"
	mkdir -p "${dir}/client" "${dir}/ci/test"
	cp "${repo_root}/Justfile" "${repo_root}/runquota.just" "${dir}/"
	cp "${repo_root}/client/Justfile" "${dir}/client/"
	printf '#!/bin/sh\nexit 0\n' >"${dir}/ci/test/client-sdk-boundary.sh"
	cp "${dir}/ci/test/client-sdk-boundary.sh" "${dir}/ci/test/client-sdk-boundary-test.sh"
	chmod +x "${dir}/ci/test/"*.sh
	if [ "${mutate}" -eq 1 ]; then
		# The falsifying mutation: no bridge in any recipe.
		sed -i 's/{{rq}} //' "${dir}/Justfile" "${dir}/client/Justfile"
	fi
}
for s in a b hi; do stage "${work}/co-${s}"; done

# --- a private daemon with a small budget ------------------------------------
sock="${work}/d.sock"
export RUNQUOTA_SOCKET="${sock}"
export RUNQUOTA_ENDPOINT_SCOPE=private
unset RUNQUOTA_USER_ENDPOINT_DIR RUNQUOTA_ENDPOINT_GROUP RUNQUOTA_ENDPOINT_OWNER_UID \
	RUNQUOTA_EXIT_WITH_PARENT RUNQUOTA_EXIT_WITH_PARENT_PID LISTEN_PID LISTEN_FDS \
	LISTEN_FDNAMES RUNQUOTA_PARENT_LEASE RQ
"${rqd}" --socket "${sock}" --host-config "${work}/host.toml" \
	--host-identity-file "${work}/host-id" --estimate-db "${work}/est.sqlite" \
	--no-write-stats --ambient-sample-interval-millis 0 \
	--memory-pressure-source unavailable --cpu-milli $((budget_slots * 1000)) \
	>"${work}/daemon.log" 2>&1 &
daemon_pid=$!
up=0
for _ in $(seq 1 100); do
	if "${rq_cli}" status >/dev/null 2>&1; then
		up=1
		break
	fi
	sleep 0.1
done
if [ "${up}" -ne 1 ]; then
	echo "the private daemon did not answer on ${sock}:" >&2
	cat "${work}/daemon.log" >&2
	exit 1
fi

echo "=== three \`just test\` sessions on one ${budget_slots}-slot budget ==="
echo "    runquota: ${rq_cli}  ($("${rq_cli}" --version 2>&1 | head -1))"
[ "${mutate}" -eq 1 ] && echo "    MUTATION: {{rq}} removed from the staged Justfiles"
echo

# --- the sampler: live stub processes, 30 ms, for the whole run --------------
# The stub is recognised by its script path in /proc/<pid>/cmdline. The pattern
# is written with a bracket so the sampler's own `grep` command line does not
# match it.
stub_pat="${stubs%?}[${stubs: -1}]/nim"
peak_file="${work}/peak"
stop_file="${work}/stop"
(
	peak=0
	while [ ! -e "${stop_file}" ]; do
		n="$(grep -l -a -E -- "${stub_pat}" /proc/[0-9]*/cmdline 2>/dev/null | wc -l)"
		if [ "${n}" -gt "${peak}" ]; then
			peak="${n}"
			echo "${peak}" >"${peak_file}"
		fi
		sleep 0.03
	done
) &
sampler_pid=$!
echo 0 >"${peak_file}"

run_session() { # name priority
	local name="$1" prio="$2"
	(
		cd "${work}/co-${name}" || exit 99
		export BTRQ_LOG="${log}" BTRQ_STUB_SECONDS="${stub_seconds}"
		export PATH="${stubs}:${rq_dir}:${PATH}"
		export RUNQUOTA_SESSION="bt-${name}" RUNQUOTA_SESSION_PRIORITY="${prio}"
		timeout "${deadline_seconds}" just test >"${work}/out-${name}.txt" 2>&1
		echo "$?" >"${work}/rc-${name}"
		echo "${EPOCHREALTIME}" >"${work}/done-${name}"
	) &
}

# Two normal sessions first. The high-priority one starts once both are under
# way (the second has started its first suite), so that it contends with
# sessions that are already running and queued. Bounded at 30 s.
run_session a normal
sleep 0.3
run_session b normal
waited=0
while [ "${waited}" -lt 300 ]; do
	grep -q '^start .* bt-b ' "${log}" && break
	sleep 0.1
	waited=$((waited + 1))
done
run_session hi high
wait_start="${SECONDS}"
for s in a b hi; do
	while [ ! -e "${work}/done-${s}" ]; do
		if [ $((SECONDS - wait_start)) -gt "${deadline_seconds}" ]; then break; fi
		sleep 0.2
	done
done
: >"${stop_file}"
wait "${sampler_pid}" 2>/dev/null || true
sampler_pid=""

# --- the checks ----------------------------------------------------------------
peak="$(cat "${peak_file}")"
runs="$(grep -c '^start ' "${log}" || true)"
echo "    stub runs: ${runs}, sampled peak concurrency: ${peak}, budget: ${budget_slots}"
echo

for s in a b hi; do
	rc="$(cat "${work}/rc-${s}" 2>/dev/null || echo missing)"
	if [ "${rc}" = "0" ]; then
		ok "session ${s}: \`just test\` exited 0"
	else
		bad "session ${s}: \`just test\` exited ${rc}; last lines:"
		tail -n 8 "${work}/out-${s}.txt" | sed 's/^/             /'
	fi
done

per_session_a="$(grep -c '^start .* bt-a ' "${log}" || true)"
per_session_b="$(grep -c '^start .* bt-b ' "${log}" || true)"
per_session_hi="$(grep -c '^start .* bt-hi ' "${log}" || true)"
if [ "${per_session_a}" -ge 20 ] && [ "${per_session_a}" -eq "${per_session_b}" ] &&
	[ "${per_session_a}" -eq "${per_session_hi}" ]; then
	ok "each session ran the same ${per_session_a} suites (nothing was skipped)"
else
	bad "suite counts differ or are too small: a=${per_session_a} b=${per_session_b} hi=${per_session_hi}"
fi

if [ "${peak}" -ge 1 ] && [ "${peak}" -le "${budget_slots}" ]; then
	ok "sampled peak ${peak} <= budget ${budget_slots}"
else
	bad "sampled peak ${peak} is outside 1..${budget_slots} (the budget)"
fi

unbridged="$(grep '^start ' "${log}" | grep -vc ' width=[1-9]' || true)"
if [ "${unbridged}" -eq 0 ] && [ "${runs}" -gt 0 ]; then
	ok "every suite ran under a lease (RUNQUOTA_RUN_WIDTH set)"
else
	bad "${unbridged} of ${runs} suites ran with no lease: a recipe is not routed through {{rq}}"
fi

too_wide="$(grep '^start ' "${log}" | sed -n 's/.* width=\([0-9]*\) .*/\1/p' | awk -v b="${budget_slots}" '$1 > b' | wc -l)"
if [ "${too_wide}" -eq 0 ]; then
	ok "no grant was wider than the budget"
else
	bad "${too_wide} grants were wider than the ${budget_slots}-slot budget"
fi

if grep '^start ' "${log}" | grep -q -- '--parallelBuild:[0-9]'; then
	ok "the nim adapter passed the grant to the compiler (--parallelBuild)"
else
	bad "no --parallelBuild:N reached the compiler"
fi

# Priority. When a slot frees, the daemon grants it to the best request that is
# QUEUED at that moment. A session's next command is only queued a few
# milliseconds after its previous one ends, so a high-priority session does not
# get back-to-back grants: it gets the next free slot whenever it is waiting.
# So once the high-priority session has started its first suite, no more than
# ONE suite of the other sessions may start before its next one (two in a row
# would mean a request of the high session waited through two grants, being
# served after normal requests), and it must finish first.
order="$(grep '^start ' "${log}" | sed -n 's/^start [0-9.]* bt-\([a-z]*\) .*/\1/p' | tr '\n' ' ')"
overtaken="$(printf '%s\n' "${order}" | awk '
	{ for (i = 1; i <= NF; i++) {
		if ($i == "hi") { seen = 1; run = 0; last = i }
		else if (seen) { run++; if (run > 1) bad_after[i] = 1 }
	} }
	END { n = 0; for (i in bad_after) if (i < last) n++; print n }')"
if [ -n "${order}" ] && [ "${order}" != "${order#*hi}" ] && [ "${overtaken}" -eq 0 ]; then
	ok "the high-priority session was never passed over twice in a row once it was queued"
else
	bad "the high-priority session was served behind normal requests (${overtaken} times)"
	echo "             start order: ${order}"
fi
done_hi="$(cat "${work}/done-hi" 2>/dev/null || echo 0)"
done_a="$(cat "${work}/done-a" 2>/dev/null || echo 0)"
done_b="$(cat "${work}/done-b" 2>/dev/null || echo 0)"
if awk -v h="${done_hi}" -v a="${done_a}" -v b="${done_b}" 'BEGIN { exit !(h > 0 && h < a && h < b) }'; then
	ok "the high-priority session finished before both normal sessions"
else
	bad "the high-priority session did not finish first (hi=${done_hi} a=${done_a} b=${done_b})"
fi

echo
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK (${checks} checks)"
	result=0
else
	echo "RESULT: FAILED (${failures} of ${checks} checks)"
	result=1
fi
if [ "${mutate}" -eq 1 ]; then
	if [ "${result}" -ne 0 ]; then
		echo "MUTATION KILLED: the unbridged Justfiles failed the test, as they must"
		exit 0
	fi
	echo "MUTATION SURVIVED: the unbridged Justfiles passed; this test cannot see the bridge"
	exit 1
fi
exit "${result}"
