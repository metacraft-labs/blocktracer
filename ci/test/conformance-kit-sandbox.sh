#!/usr/bin/env bash
#
# conformance-kit-sandbox.sh — the recorder conformance kit reaches a verdict with
# no Nim toolchain, no repository checkout and no network.
#
# ── WHY THIS IS A SCRIPT AND NOT A SENTENCE ───────────────────────────────────
#
# "It needs no network" is the easiest claim in this repository to satisfy
# vacuously: a check that passes because the code never tried to reach the network
# proves nothing about whether it could. The same is true of the other two. So all
# three absences are made OBSERVABLE, each with a probe that is expected to FAIL
# inside the sandbox and a control outside it that is expected to succeed:
#
#   * no network   — a TCP connect to a public address. `Network is unreachable`
#                    inside; connected outside.
#   * no toolchain — `command -v` for nim, nimble, gcc, cc, node and git. All
#                    unresolvable inside; nim resolvable outside.
#   * no checkout  — the repository path is a tmpfs inside, so it is EMPTY. The
#                    artifact itself is copied out of the repository first, so the
#                    run has no path back into it at all.
#
# Only then is the kit run, over a template that was copied out with it.
#
# ── AND THE FOURTH ABSENCE, ADDED 2026-09-17: NO SPECIFICATION EITHER ─────────
#
# The three above are about the machine. This one is about the documents, and it
# was the gap a recorder team actually fell into: the README named three files
# that the release does not ship and told a recipient to look a rule id up "in the
# blocktracer repository". Arm 6 takes a real refusal, reads the rule id the kit
# printed, and resolves it against the contract the release carries — in the
# sandbox, where there is no checkout to fall back on.
#
# ── AND THE CONTROL THAT MAKES A GREEN MEAN SOMETHING ─────────────────────────
#
# The last arm runs the same command with the fixture removed. A harness that
# reported success there would be reporting the absence of work, so that arm
# requires a MISSING-FIXTURE refusal rather than a pass.
#
# Usage: ci/test/conformance-kit-sandbox.sh [RELEASE_DIR]
#
# RELEASE_DIR defaults to `conformance-kit-release`, which `just
# conformance-kit-release` stages. Building it needs the toolchain — the kit is
# built BY US and shipped; what a recorder team must not need is the toolchain.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release="${1:-${repo_root}/conformance-kit-release}"

pass=0
fail=0
report_pass() { pass=$((pass + 1)); echo "  ok       $1"; }
report_fail() {
	fail=$((fail + 1))
	echo "  FAILED   $1"
	[ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/               /'
}

if [ ! -x "${release}/bin/blocktracer-conformance" ]; then
	echo "conformance-kit-sandbox: no released artifact at ${release}" >&2
	echo "  build it first:  just conformance-kit-release" >&2
	echo "  REFUSING rather than skipping: an arm with no subject is a green that" >&2
	echo "  means nothing, and every claim below is about that artifact." >&2
	exit 2
fi

command -v bwrap >/dev/null 2>&1 || {
	echo "conformance-kit-sandbox: bwrap is not on PATH, so the three absences" >&2
	echo "  cannot be CONSTRUCTED and asserting them would be a claim rather than" >&2
	echo "  a measurement. REFUSING rather than skipping." >&2
	exit 2
}

# ── THE SANDBOX AND ITS CONTROL MUST RUN THE SAME SHELL ───────────────────────
#
# This was `/bin/sh` inside and `bash -c` outside, and the network probe is
# `/dev/tcp/HOST/PORT` — a BASH feature that no POSIX shell has. Here `/bin/sh`
# IS bash, so the pair discriminated and the arm meant what it said. On a host
# where `/bin/sh` is dash the probe would fail with `Bad file descriptor`, the
# arm would report "the network is unreachable" for a reason that has nothing to
# do with the network, and the control — which spells `bash` explicitly — would
# still pass. Two arms, two shells, and the vacuity invisible in both.
#
# So the shell is resolved ONCE, by name, and used on both sides. An absolute
# path, because the sandbox's PATH holds the kit's own bin and nothing else.
sandbox_shell="$(command -v bash 2>/dev/null || true)"
[ -x "${sandbox_shell}" ] || {
	echo "conformance-kit-sandbox: no bash on PATH. The network probe is" >&2
	echo "  /dev/tcp, which is a bash feature, and running it under another" >&2
	echo "  shell would fail for the wrong reason and read as a pass." >&2
	echo "  REFUSING rather than skipping." >&2
	exit 2
}

# ── the artifact leaves the checkout ──────────────────────────────────────────
work="$(mktemp -d "${TMPDIR:-/tmp}/bt-conformance-sandbox.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
cp -r "${release}" "${work}/kit"
kit="${work}/kit"

# A run inside the sandbox: no network, the repository replaced by an empty
# tmpfs, and a PATH holding nothing but the kit's own bin.
in_sandbox() {
	bwrap --dev-bind / / \
		--tmpfs "${repo_root}" \
		--unshare-net \
		--clearenv \
		--setenv PATH "${kit}/bin" \
		--setenv HOME "${work}" \
		--setenv TMPDIR "${work}/tmp" \
		-- "${sandbox_shell}" -c "$1"
}
mkdir -p "${work}/tmp"

echo "conformance-kit-sandbox: ${kit}"
echo

# ── 1. the network is genuinely gone, and that is visible ─────────────────────
probe="$(in_sandbox 'exec 3<>/dev/tcp/1.1.1.1/443' 2>&1)"
rc=$?
if [ "${rc}" -ne 0 ]; then
	report_pass "inside the sandbox a TCP connect FAILS (rc ${rc})"
else
	report_fail "inside the sandbox a TCP connect succeeded — the network is not isolated"
fi
# …AND IT FAILED FOR THE RIGHT REASON. A non-zero rc is also what a shell that
# cannot parse `/dev/tcp` returns, and what a probe that could not start returns.
# The kernel's own sentence is what says the failure is the ABSENCE OF A NETWORK.
if printf '%s' "${probe}" | grep -qi 'network is unreachable'; then
	report_pass "…and it fails as an UNREACHABLE NETWORK, not as a shell that could not run the probe"
else
	report_fail "the connect failed, but not with 'Network is unreachable'" "${probe}"
fi
# …and the control, outside it, so the arm above is not passing because nothing
# in this environment can reach the network anyway.
timeout 10 "${sandbox_shell}" -c 'exec 3<>/dev/tcp/1.1.1.1/443' >/dev/null 2>&1
rc=$?
if [ "${rc}" -eq 0 ]; then
	report_pass "CONTROL: outside the sandbox the same connect SUCCEEDS"
else
	report_fail "CONTROL: the connect fails outside the sandbox too (rc ${rc})" \
		"the no-network arm above is therefore vacuous on this host"
fi

# ── 2. no toolchain ───────────────────────────────────────────────────────────
found="$(in_sandbox 'for t in nim nimble gcc cc node git; do command -v "$t" 2>/dev/null; done' 2>/dev/null)"
if [ -z "${found}" ]; then
	report_pass "inside the sandbox none of nim/nimble/gcc/cc/node/git resolves"
else
	report_fail "a toolchain is reachable inside the sandbox" "${found}"
fi
if command -v nim >/dev/null 2>&1; then
	report_pass "CONTROL: outside the sandbox nim resolves ($(command -v nim))"
else
	report_fail "CONTROL: nim does not resolve outside the sandbox either" \
		"the no-toolchain arm above is therefore vacuous on this host"
fi

# ── 3. no checkout ────────────────────────────────────────────────────────────
# COUNTED WITH SHELL BUILT-INS AND GLOBBING, because `ls` and `wc` are not on the
# sandbox's PATH — it holds the kit's own bin and nothing else. The first attempt
# used them, and the count came back as the EMPTY STRING rather than as zero: an
# arm that cannot run reads exactly like one that measured nothing.
entries="$(in_sandbox "n=0
for f in '${repo_root}'/* '${repo_root}'/.[!.]* '${repo_root}'/..?*; do
  [ -e \"\$f\" ] || continue
  n=\$((n + 1))
done
echo \"\$n\"" 2>/dev/null | tr -d ' ')"
if [ "${entries}" = "0" ]; then
	report_pass "inside the sandbox ${repo_root} is EMPTY"
elif [ -z "${entries}" ]; then
	report_fail "the count came back EMPTY, so nothing was measured" \
		"a blank is not a zero — the probe could not run in the sandbox"
else
	report_fail "the checkout is still visible inside the sandbox (${entries} entries)"
fi
outside="$(ls -A "${repo_root}" 2>/dev/null | wc -l | tr -d ' ')"
if [ "${outside}" != "0" ]; then
	report_pass "CONTROL: outside the sandbox it holds ${outside} entries"
else
	report_fail "CONTROL: the checkout looks empty outside the sandbox too"
fi

# ── 4. and now the kit, in there, over every tree the template ships ──────────
trees="$(ls -1 "${kit}/template")"
[ -n "${trees}" ] || report_fail "the released artifact ships no template tree"
for tree in ${trees}; do
	out="$(in_sandbox "blocktracer-conformance --snapshot '${kit}/template/${tree}'" 2>&1)"
	rc=$?
	if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -q 'VERDICT: this tree conforms'; then
		report_pass "the kit reaches a verdict on template/${tree} (rc 0)"
	else
		report_fail "template/${tree} did not reach a conforming verdict (rc ${rc})" "${out}"
	fi
done

# The other two commands are the kit's second and third checks with their own
# front doors, and a recorder team may run either on its own. Both are exercised
# here over the tree the first one published, in the same sandbox.
out="$(in_sandbox "blocktracer-conformance --snapshot '${kit}/template/complete' --out '${work}/tmp/pub' --keep \
	&& blocktracer-validate '${work}/tmp/pub' \
	&& blocktracer-client-conformance '${work}/tmp/pub'" 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ]; then
	report_pass "blocktracer-validate and blocktracer-client-conformance both run there too (rc 0)"
else
	report_fail "the two single-purpose commands did not both succeed (rc ${rc})" "${out}"
fi

# ── 5. A RELATIVE SUBJECT, WHICH IS THE COMMONEST SPELLING THERE IS ───────────
#
# `--snapshot ./dir` broke the PATH half of every refusal and nothing could see
# it, because every other arm in this repository passes an absolute path and an
# absolute path is already in normal form. Nim's `/` normalises as it joins, so
# the reader's message named `dir/snapshot.json` while the command compared it
# against the `./dir` the user typed — and the report said *"(this refusal names
# no file in the tree under test)"* over a message that named it.
#
# The subject is a directory holding an EMPTY JSON OBJECT: valid JSON, no
# `format`, refused by `S5-FORMAT-UNKNOWN` naming the file. Written with a shell
# redirection so this arm needs no tool the rest of the script does not have.
mkdir -p "${work}/rel/broken"
printf '{}\n' > "${work}/rel/broken/snapshot.json"
rel_out="$(in_sandbox "cd '${work}/rel' && blocktracer-conformance --snapshot ./broken" 2>&1)"
abs_out="$(in_sandbox "blocktracer-conformance --snapshot '${work}/rel/broken'" 2>&1)"
rel_path="$(printf '%s\n' "${rel_out}" | grep -m1 '^  path: ' || true)"
abs_path="$(printf '%s\n' "${abs_out}" | grep -m1 '^  path: ' || true)"
if [ -n "${rel_path}" ] && [ "${rel_path}" = "${abs_path}" ]; then
	report_pass "a RELATIVE subject names the same file an absolute one does (${rel_path# *path: })"
else
	report_fail "the same tree named relatively and absolutely reports two different paths" \
		"relative: ${rel_path}
absolute: ${abs_path}"
fi
if printf '%s' "${rel_path}" | grep -q 'snapshot.json' &&
	! printf '%s' "${rel_path}" | grep -q 'names no file'; then
	report_pass "…and that path is a FILE in the tree under test, not the no-path sentence"
else
	report_fail "a relative subject produced no usable path" "${rel_out}"
fi

# ── 6. THE CONTRACT TRAVELS WITH THE ARTIFACT, AND IS RESOLVABLE IN THERE ─────
#
# The README told a recipient that a rule id could be looked up in
# `tools/chain/snapshot-contract.json` "in the blocktracer repository" — the one
# thing this kit exists so that they do not have. "Compiled into the binary" is
# true and is not the same as travelling with you: somebody holding
# `S5-COUNTS-ROWS` and a tarball had no file to resolve it against, and
# `prestateStrategy`'s closed set lived in a spec document the release omits.
#
# SO THE ARM IS A RESOLUTION AND NOT A FILE LISTING. It takes a real refusal
# inside the sandbox, reads the rule id the kit itself printed, and requires that
# id to be found in the shipped contract file — which is the thing a recipient
# actually does. A `[ -f ... ]` check would pass over four empty files.
for f in snapshot-contract.json snapshot-format.json refusal-reasons.json identifier-encodings.json; do
	if [ -s "${kit}/contract/${f}" ]; then
		report_pass "the release carries contract/${f} ($(wc -c <"${kit}/contract/${f}") bytes)"
	else
		report_fail "the release does not carry a non-empty contract/${f}" \
			"a recipient holding a rule id, a format token, a refusalReason or an identifier-encoding token has nothing to resolve it against"
	fi
done
cited="$(printf '%s\n' "${rel_out}" | grep -m1 '^  rule: ' | sed 's/^  rule: //' | cut -d' ' -f1)"
if [ -n "${cited}" ] && [ "${cited#(}" = "${cited}" ]; then
	report_pass "the refusal in arm 5 cited a rule id (${cited})"
else
	report_fail "the refusal in arm 5 cited no rule id, so the resolution below has no subject" \
		"${rel_out}"
fi
# READ WITH A SHELL BUILT-IN, because the sandbox's PATH holds the kit's own bin
# and nothing else — `grep` is not in there, and a probe that cannot run reads
# exactly like one that measured nothing (§32's family, and arm 3 above hit the
# same thing with `ls` and `wc` and says so). `$(<file)` and `[[ == *…* ]]` are
# both bash built-ins, and `sandbox_shell` is resolved bash by construction.
if [ -n "${cited}" ] && in_sandbox "
  doc=\"\$(<'${kit}/contract/snapshot-contract.json')\"
  [ -n \"\$doc\" ] || exit 3
  [[ \"\$doc\" == *'\"${cited}\"'* ]]"; then
	report_pass "…and that id RESOLVES in the shipped contract, inside the sandbox, with no checkout"
else
	report_fail "the id the kit printed cannot be resolved against the contract it ships" \
		"cited: ${cited}"
fi

# ── 7. THE CONTROL: no fixture is not a pass ──────────────────────────────────
out="$(in_sandbox "blocktracer-conformance --snapshot '${kit}/template/not-a-tree'" 2>&1)"
rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -q 'no snapshot tree at'; then
	report_pass "CONTROL: with the fixture removed it reports a MISSING FIXTURE (rc ${rc})"
else
	report_fail "CONTROL: a missing fixture did not produce a missing-fixture report (rc ${rc})" "${out}"
fi

echo
echo "conformance-kit-sandbox: $((pass + fail)) check(s), ${fail} failing"
[ "${fail}" -eq 0 ] || exit 1
[ "${pass}" -ge 19 ] || {
	echo "conformance-kit-sandbox: only ${pass} arm(s) ran; at least 19 are expected." >&2
	echo "  A suite that lost its arms reports zero failures, which is the shape of" >&2
	echo "  green this file exists to refuse." >&2
	exit 1
}
echo "PASS — the kit reaches a verdict with no toolchain, no checkout and no network."
