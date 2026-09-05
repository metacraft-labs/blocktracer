#!/usr/bin/env bash
# bundle-freshness-remedy-test.sh — does that gate bite?
#
#   bash ci/test/bundle-freshness-remedy-test.sh
#
# The relation every `ci/test/<subject>-test.sh` has to its `<subject>.sh`:
# plant the violation for real and demand it is reported, by name.
#
# The violation here is the state the tree was in before `client/Justfile` and
# `client/hydrate/build.sh` stamped their outputs: `nim js` rebuilt the bundle,
# emitted identical bytes, and left the file's mtime where it was — so the
# bundle is still older than the source it was just built from, and
# `requireFreshBundle` goes on refusing a tree nobody can fix by doing what it
# says.
#
# It is planted by REWINDING the mtime after the remedy has genuinely run,
# rather than by editing the recipes out from under the gate. That keeps the
# subject a real build with real bytes — everything about the run is the true
# thing except the one stamp the fix adds, which is exactly the difference under
# test.
#
# WHAT MAKES THIS MORE THAN A TAUTOLOGY. The gate's assertions could be written
# so that they can only say yes — comparing a bundle against itself, or reading
# a whole-second mtime in which the edit and the build compare equal. Both
# shapes would be green over the defect. This file is the evidence they are not:
# it puts the defect in front of them and requires the specific claim to fail
# and the run to exit 1.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

pass=0
fail=0
ck() {
	if [ "$2" -eq 0 ]; then
		echo "  [OK]     $1"
		pass=$((pass + 1))
	else
		echo "  [FAILED] $1"
		fail=$((fail + 1))
	fi
}

echo "=== the gate, over an intact tree — the CONTROL ==="
# Without this, every refusal below is unattributable: a gate that refuses
# everything would produce the same transcript.
bash ci/test/bundle-freshness-remedy.sh >"$LOG" 2>&1
rc=$?
[ "$rc" -eq 0 ]
ck "an intact tree passes (exit $rc)" $?
grep -q "RESULT: OK" "$LOG"
ck "and says RESULT: OK" $?

echo ""
echo "=== the same tree with the stamp defeated ==="
BUNDLE_FRESHNESS_PROBE_UNSTAMP=1 bash ci/test/bundle-freshness-remedy.sh >"$LOG" 2>&1
rc=$?
[ "$rc" -eq 1 ]
ck "the gate FAILS (exit $rc, and 1 is a verdict — 2 would be a refusal to make one)" $?
grep -q "RESULT: FAILED" "$LOG"
ck "and says RESULT: FAILED" $?

# BY NAME, AND FOR THE RIGHT REASON. A gate that failed here because it could
# no longer find its subject would exit 1 too, and would be worthless.
grep -q "\[FAILED\] and the remedy still cleared the staleness: client/searchboot/search.js" "$LOG"
ck "it names the search bundle, on the staleness claim" $?
grep -q "\[FAILED\] and the remedy still cleared the staleness: client/settingsboot/settings.js" "$LOG"
ck "it names the settings bundle, on the staleness claim" $?

# AND ONLY THAT CLAIM. The bytes-unchanged assertion, the probe-has-a-subject
# assertion and the file-restored assertion must all still be green: if the
# rewind had disturbed them, the failure above would not be attributable to the
# missing stamp.
# `bytes_rc` on its own line and NOT `ck "..." $?` around a negated grep: the
# `$?` in an argument list is the status of whatever ran last during argument
# expansion, which is the trap `selftest-verdict-test.sh` records having been
# caught by, in this same directory, on this same idiom.
if grep -q "\[FAILED\] client/searchboot/search.js rebuilt to the SAME bytes" "$LOG"; then
	bytes_rc=1
else
	bytes_rc=0
fi
ck "the bytes-unchanged claim did NOT fail — the rewind touched only the mtime" "$bytes_rc"
grep -q "\[OK\]     both bundles are now OLDER than the source" "$LOG"
ck "the probe still had a subject" $?
grep -q "\[OK\]     client/src/components/debugger.nim is byte-for-byte as it was found" "$LOG"
ck "and it still left the source file alone" $?

echo ""
echo "=== the tree is left as it was found ==="
# The rewind above set two gitignored build outputs to 2020. Put them back, so
# a later `just export` in this checkout is not refused by the very gate this
# pair is about.
touch client/searchboot/search.js client/settingsboot/settings.js
# SCOPED to the one tracked file this pair writes to. A bare `git diff --quiet`
# would report the caller's own uncommitted work as this proof's damage, which
# is a false accusation and, worse, one that makes the check useless on the only
# trees anybody runs it on.
git diff --quiet -- client/src/components/debugger.nim
ck "the one tracked file this proof writes to is unmodified" $?

echo ""
echo "$((pass + fail)) assertion(s): $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
	echo "  The freshness-remedy gate reports a bundle whose rebuild did not stamp it."
	echo "RESULT: OK"
else
	echo "RESULT: FAILED"
	exit 1
fi
