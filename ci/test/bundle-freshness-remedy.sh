#!/usr/bin/env bash
# bundle-freshness-remedy.sh — the remedy the freshness gate prints must clear
# the condition the freshness gate reports.
#
#   bash ci/test/bundle-freshness-remedy.sh
#   bash ci/test/bundle-freshness-remedy-test.sh     # and the proof it bites
#
# ── What this is about ─────────────────────────────────────────────────────
#
# `client/src/static_export.nim`'s `requireFreshBundle` refuses to publish a
# bundle older than the newest `.nim` under the directories it was built from,
# and prints a remedy: "Build it first (cd client && just search-bundle)". That
# gate is right, and it is the good kind of gate — it closes the case an
# existence test cannot see, where a bundle compiled from last week's source is
# copied into the site under the current name.
#
# Its EVIDENCE was wrong. It reads the built file's mtime as "when this bundle
# was built", and `nim js -o:X` does not rewrite X when the emitted bytes are
# unchanged. So for any source edit that does not change the bundle — a
# comment, a reordering, or a byte-identical rewrite — running the remedy
# produces the same bytes, leaves the same mtime, and the gate fires again. A
# gate whose own remedy cannot clear it is not a gate, it is a wall.
#
# MEASURED, on the pinned Nim 2.2.10: `client/hydrate/hydrate.js` was set to
# 2020-01-01, `client/hydrate/build.sh --require` ran to completion (rc 0,
# 1,965,013 bytes, all three sources at the pins), and the mtime was still
# 2020-01-01 afterwards.
#
# THE COST WAS SIX RED CI JOBS. `tools/journeys/selftest.mjs` mutates a
# `client/src/*.nim` and then writes the ORIGINAL BYTES BACK — the
# byte-identical rewrite above, twice per arm, by design. On 779c702 the first
# arm of every shard hit this, the exporter `quit 2`'d after it had already
# rewritten `dist/` and before it installed the three `assets/*.js`, and every
# arm behind it read "no single assertion matched that name on the unmutated
# tree" off a site with no bundles in it. Shard 1: 18 arms, 0 killed, 0
# survived, 18 never ran. The same mechanism took the `journeys` job's own
# verdict self-test from 7 probes passing to 9 assertions failing.
#
# ── What is asserted, and why in this shape ────────────────────────────────
#
# THE DISCRIMINATING CONDITION IS THAT THE BUNDLE'S BYTES DO NOT CHANGE. A
# rebuild that emits DIFFERENT bytes moves the mtime by itself and would pass
# this gate on an unfixed tree — so the sha256 is asserted EQUAL across the
# remedy, and a run in which it moved reports that it proved nothing rather
# than passing. Verification-Harness-Traps.md §4: a probe with no subject is
# not a pass.
#
# The subject is a byte-identical rewrite of a real file under `client/src`,
# which is the exact operation the journey harness performs, and the file is
# left byte-for-byte as it was found (asserted, at the end).
#
# The hydration bundle takes the same `touch` for the same reason and is NOT
# driven here: `hydrate/build.sh` needs the pinned CodeTracer Embed SDK, IsoNim
# and nim-everywhere on the Nim path, which is a browser-capable Nix shell and
# about a minute of `nim js`. The two bundles below are plain `nim js` over this
# repository's own two source paths (AGENTS.md §1a), they go through the
# identical `requireFreshBundle` over an identical `client/src` entry, and they
# are the cheapest place the mechanism is expressible. `hydrate/build.sh`'s
# stamp is exercised by every job that builds the bundle.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$REPO"

# PLANTED BY `bundle-freshness-remedy-test.sh`, and by nothing else. After the
# remedy has run, each bundle's mtime is rewound to what it was before it —
# which is precisely the state an unstamped `nim js` leaves — so the assertions
# below are made to face the defect they were written for. See that file.
UNSTAMP="${BUNDLE_FRESHNESS_PROBE_UNSTAMP:-0}"

pass=0
fail=0
ck() { # ck "<claim>" <rc>
	if [ "$2" -eq 0 ]; then
		echo "  [OK]     $1"
		pass=$((pass + 1))
	else
		echo "  [FAILED] $1"
		fail=$((fail + 1))
	fi
}

# `[ a -nt b ]` AND NOT A PARSED `stat`. The two `stat`s spell this
# differently (GNU `-c`, BSD `-f`), and both of them hand back a fixed-point
# number of 19 significant digits that no shell arithmetic and no `sort -g`
# compares without losing the low end of it — which is the end that matters,
# because a build and the source rewrite before it are comfortably inside one
# second. `-nt` is the kernel's own comparison at full timespec resolution,
# it is POSIX, and it needs no parsing at all.
newer_or_equal() { # newer_or_equal <a> <b>  — is mtime(a) >= mtime(b)?
	! [ "$2" -nt "$1" ]
}
sha_of() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
	else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# The file the journey harness itself rewrites, so this gate is about the real
# case and not an analogue of it.
SRC="client/src/components/debugger.nim"

# The two bundles, and the recipe that is the remedy for each. `installSearchBundle`
# and `installSettingsBundle` in `client/src/static_export.nim` name these paths.
BUNDLES=(
	"client/searchboot/search.js:search-bundle"
	"client/settingsboot/settings.js:settings-bundle"
)

if ! git diff --quiet -- "$SRC"; then
	echo "  $SRC has uncommitted changes. This gate rewrites it with its own"
	echo "  bytes and asserts at the end that it is unchanged; over a dirty file"
	echo "  that assertion would mean nothing. Commit or stash it first."
	echo "RESULT: DID NOT RUN"
	exit 2
fi
SRC_BEFORE="$(sha_of "$SRC")"

echo "=== the bundles are built, so there is something to call stale ==="
if ! (cd client && just search-bundle settings-bundle) >/tmp/bfr-build1.$$ 2>&1; then
	tail -20 /tmp/bfr-build1.$$
	rm -f /tmp/bfr-build1.$$
	echo "  the bundles do not build at all, so nothing below could be measured."
	echo "RESULT: DID NOT RUN"
	exit 2
fi
rm -f /tmp/bfr-build1.$$
for entry in "${BUNDLES[@]}"; do
	built="${entry%%:*}"
	[ -f "$built" ]
	ck "$built was built" $?
done

echo ""
echo "=== a byte-identical rewrite of $SRC — the harness's restore ==="
# `cp` through a temporary and back: the bytes are the file's own, the mtime is
# now. This is `writeFile(arm.file, original)` in selftest.mjs, spelled in shell.
tmp="$(mktemp)"
cp "$SRC" "$tmp" && cp "$tmp" "$SRC"
rm -f "$tmp"
[ "$(sha_of "$SRC")" = "$SRC_BEFORE" ]
ck "the rewrite changed no bytes — this is a restore, not an edit" $?

# THE PROBE MUST HAVE A SUBJECT. If the source is not newer than the bundles,
# the gate below is not stale to begin with and every assertion after it would
# pass over nothing.
subject=0
for entry in "${BUNDLES[@]}"; do
	built="${entry%%:*}"
	newer_or_equal "$SRC" "$built" || subject=$((subject + 1))
done
[ "$subject" -eq 0 ]
ck "both bundles are now OLDER than the source — requireFreshBundle would refuse" $?

declare -a before_sha
for i in "${!BUNDLES[@]}"; do
	built="${BUNDLES[$i]%%:*}"
	before_sha[$i]="$(sha_of "$built")"
done

echo ""
echo "=== the remedy the gate prints: cd client && just <bundle> ==="
if ! (cd client && just search-bundle settings-bundle) >/tmp/bfr-build2.$$ 2>&1; then
	tail -20 /tmp/bfr-build2.$$
	rm -f /tmp/bfr-build2.$$
	echo "  the remedy itself failed."
	echo "RESULT: DID NOT RUN"
	exit 2
fi
rm -f /tmp/bfr-build2.$$

if [ "$UNSTAMP" = "1" ]; then
	echo "  !!! BUNDLE_FRESHNESS_PROBE_UNSTAMP=1 — each bundle's mtime is being"
	echo "      rewound to its pre-remedy value, which is the state an unstamped"
	echo "      \`nim js\` leaves. The assertions below must now REFUSE."
	for i in "${!BUNDLES[@]}"; do
		built="${BUNDLES[$i]%%:*}"
		# Strictly BACK, not merely equal to the source: `newer_or_equal` is a
		# `>=`, so a rewind to the source's own mtime would still pass and the
		# plant would prove nothing.
		touch -t 202001010000 "$built"
	done
fi

for i in "${!BUNDLES[@]}"; do
	built="${BUNDLES[$i]%%:*}"
	now_sha="$(sha_of "$built")"

	# The whole discrimination. If this moved, the rebuild changed the bundle,
	# the mtime moved for a reason that has nothing to do with the fix, and the
	# assertion after it would be green on an unfixed tree.
	[ "$now_sha" = "${before_sha[$i]}" ]
	ck "$built rebuilt to the SAME bytes — the case the gate's evidence gets wrong" $?

	newer_or_equal "$built" "$SRC"
	ck "and the remedy still cleared the staleness: $built is not older than $SRC" $?
done

echo ""
[ "$(sha_of "$SRC")" = "$SRC_BEFORE" ]
ck "$SRC is byte-for-byte as it was found" $?

echo ""
echo "$((pass + fail)) assertion(s): $pass passed, $fail failed"
if [ "$fail" -eq 0 ]; then
	echo "  Rebuilding a bundle clears the staleness the exporter reports about it,"
	echo "  even when the rebuild emits the same bytes."
	echo "RESULT: OK"
else
	echo "RESULT: FAILED"
	exit 1
fi
