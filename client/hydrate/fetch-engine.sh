#!/usr/bin/env bash
#
# fetch-engine.sh — copy the PINNED replay engine to this site's own origin.
#
#   ./hydrate/fetch-engine.sh <dest-dir> [base-url] [manifest-path]
#
# CodeTracer-Embed-SDK.md §5.1: "`new Worker(scriptURL)` requires a same-origin
# script. That single rule shapes the package contract, because the obvious
# design — ship everything on npm, let it load from a CDN — cannot work for the
# worker." The wasm may live anywhere (it is fetched with ordinary CORS); the
# worker may not. So the recommended mode is "copy to own origin", and this is
# that copy.
#
# It is NOT part of `just export` and nothing here is committed:
#
#   * It is 18 MB of build output from another repository, and a repository
#     that carried it would be carrying a second copy of an artifact whose
#     first copy is already published and versioned elsewhere.
#   * It reaches the network, and `nix build .#default` is hermetic.
#   * A deploy may legitimately not want it — pointing
#     `-d:replayEngineBase` at an origin that already serves the bundle is the
#     other supported answer, and `replay_engine.nim` exists to express it.
#
# With no engine at the base, hydration constructs a worker that 404s, reports
# it, and leaves the served page standing — which is §7.0's guarantee and is
# also exactly what a visitor sees today.
#
# ── WHAT CHANGED, AND WHY THE HEADER USED TO SAY THE OPPOSITE ──────────────
#
# This script used to fetch three fixed paths from the project ROOT and then
# RECORD their sha256s into a manifest. Both halves were wrong in the same way.
#
#   * A Pages project's root serves its CURRENT PRODUCTION DEPLOYMENT, so the
#     three paths named "the latest engine", not an engine. Two agents an hour
#     apart on 2026-09-04 received `e63dd40a…`/18,117,700 and
#     `22acb8e1…`/18,117,658 bytes. Neither was wrong. Nothing had claimed they
#     should agree, and two like-for-like comparisons were lost to it.
#
#   * The sha256 block DOCUMENTED the drift instead of preventing it. A hash
#     computed after the fact and written to a file nobody compares is a
#     record, not a check — which is precisely why the drift went unnoticed for
#     as long as the block existed.
#
# The old header argued that "a version pin here would make an unrelated
# CodeTracer release break this repository's deploy". That was true of a
# VERSION pin and it is not true of a CONTENT pin against a content-addressed
# URL: `engine-pin.txt` names bytes, the publisher serves those bytes under a
# name derived from them, and an unrelated release adds new names rather than
# changing what the pinned ones return. What an unrelated release does cost is
# one commit, when this repository decides to move — and the deploy workflow
# already accepts the strictly larger version of that cost in writing ("an
# engine fix now needs a BlockTracer redeploy").
#
# See `engine-pin.txt` for the pin itself and for `just engine-pin-update`.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dest="${1:?usage: fetch-engine.sh <dest-dir> [base-url] [manifest-path]}"
base="${2:-https://web-codetracer.pages.dev}"
base="${base%/}"
# WHERE THIS RUN RECORDS WHAT IT ACTUALLY DOWNLOADED.
#
# Still written, and still only a record — but it is no longer the only thing
# standing between this deploy and a silently different engine, because the pin
# below now ASSERTS the same bytes before this file is written. Its remaining
# job is the one `check-freshness.mjs` gives it: proving that the bytes STAGED
# for upload are the bytes this run fetched, which is a different claim from
# "the bytes this run fetched are the pinned ones" and catches a different
# defect (a leftover directory, a half-overwritten file, a copy step that went
# wrong between here and `wrangler`).
#
# Empty path = write nothing, which keeps `just hydrate` and every local
# invocation exactly as they were.
manifest="${3:-}"

# The pin. Overridable so the selftest can point at a synthetic one; there is
# deliberately NO value of this variable that means "do not check".
pin="${REPLAY_ENGINE_PIN:-${here}/engine-pin.txt}"

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		return 1
	fi
}

bytes_of() { wc -c <"$1" | tr -d ' '; }

if [ ! -r "${pin}" ]; then
	echo "fetch-engine.sh: no engine pin at ${pin}" >&2
	echo "  This script fetches an artefact built by another repository from an" >&2
	echo "  origin that always serves its latest deployment. Without the pin it" >&2
	echo "  cannot tell one engine from another, which is the state this file" >&2
	echo "  was written to end. Nothing was fetched." >&2
	exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
	# NOT a soft skip. The old code let a checkout with neither tool write no
	# manifest and continue, which was defensible when the hashes were a note.
	# It is not defensible now: continuing would copy an unverified 18 MB
	# binary into a publish directory under the name of a pinned one.
	echo "fetch-engine.sh: neither sha256sum nor shasum is on PATH." >&2
	echo "  The pin cannot be checked, so the engine is not fetched. An engine" >&2
	echo "  copied without checking it is exactly what ${pin} exists to prevent." >&2
	exit 1
fi

# ── read the pin ───────────────────────────────────────────────────────────
#
# Parsed into four parallel arrays rather than re-read per file, so a malformed
# record is refused BEFORE anything is downloaded. A script that fetched two of
# three files and then rejected the third would leave the half-copy the
# error path below goes out of its way to avoid.
dests=()
srcs=()
shas=()
sizes=()
muts=()
lineno=0
while IFS= read -r line || [ -n "${line}" ]; do
	lineno=$((lineno + 1))
	case "${line}" in
	'#'* | '') continue ;;
	esac
	# shellcheck disable=SC2086
	set -- ${line}
	if [ "$#" -ne 5 ]; then
		echo "fetch-engine.sh: ${pin}:${lineno}: expected 5 fields, got $#" >&2
		echo "  <dest-path> <source-path> <sha256> <bytes> <mutable|immutable>" >&2
		exit 1
	fi
	if ! printf '%s' "$3" | grep -qE '^[0-9a-f]{64}$'; then
		echo "fetch-engine.sh: ${pin}:${lineno}: '$3' is not a sha256" >&2
		exit 1
	fi
	if ! printf '%s' "$4" | grep -qE '^[0-9]+$'; then
		echo "fetch-engine.sh: ${pin}:${lineno}: '$4' is not a byte count" >&2
		exit 1
	fi
	case "$5" in
	mutable | immutable) ;;
	*)
		echo "fetch-engine.sh: ${pin}:${lineno}: '$5' is not mutable|immutable" >&2
		exit 1
		;;
	esac
	dests+=("$1")
	srcs+=("$2")
	shas+=("$3")
	sizes+=("$4")
	muts+=("$5")
done <"${pin}"

if [ "${#dests[@]}" -eq 0 ]; then
	echo "fetch-engine.sh: ${pin} declares no files." >&2
	echo "  An empty pin would let this script report success having copied" >&2
	echo "  nothing, and the deploy would publish a directory with no engine" >&2
	echo "  in it under a green check." >&2
	exit 1
fi

mkdir -p "${dest}" || exit 1

echo "=== the replay engine, copied to this origin (§5.1) ==="
echo "  from: ${base}"
echo "  to:   ${dest}"
echo "  pin:  ${pin} (${#dests[@]} files)"

fail() {
	echo "$@" >&2
	echo "  Nothing is left half-copied: an engine directory holding two of" >&2
	echo "  three files would let the worker construct and then fail on an" >&2
	echo "  import, which is a worse failure than not being there at all." >&2
	rm -rf "${dest}"
	exit 1
}

for i in "${!dests[@]}"; do
	d="${dests[$i]}"
	url="${base}/${srcs[$i]}"
	out="${dest}/${d}"
	mkdir -p "$(dirname "${out}")" || exit 1

	if ! curl -fsSL "${url}" -o "${out}"; then
		if [ "${muts[$i]}" = "immutable" ]; then
			echo "fetch-engine.sh: could not fetch ${url}" >&2
			echo "" >&2
			echo "  This is a CONTENT-ADDRESSED path, so a 404 here does not mean the" >&2
			echo "  network failed — it most likely means the publisher has deployed a" >&2
			echo "  NEW engine and this pin now names bytes that are no longer served." >&2
			echo "  That is the pin working: this repository will not silently take a" >&2
			echo "  different engine than the one it was measured against." >&2
			echo "" >&2
			echo "  remedy: just engine-pin-update   (re-pins, prints the diff to review" >&2
			echo "                                    and commit)" >&2
			fail "  pinned path: ${srcs[$i]}"
		fi
		fail "fetch-engine.sh: could not fetch ${url}"
	fi

	got_bytes="$(bytes_of "${out}")"

	# The specific diagnoses first. A proxy or a captive portal answering 200
	# with an HTML error page would otherwise be reported only as a hash
	# mismatch, and "expected 22acb8e1…, got 9f2c…" names neither this script
	# nor that page.
	case "${d}" in
	*.wasm)
		if [ "${got_bytes}" -lt 1000000 ]; then
			fail "fetch-engine.sh: ${out} is only ${got_bytes} bytes; the published engine is ~18 MB, so something answered with a page."
		fi
		if ! head -c 4 "${out}" | od -An -tx1 | tr -d ' \n' | grep -q '^0061736d'; then
			fail "fetch-engine.sh: ${out} does not begin with the wasm magic."
		fi
		;;
	esac

	got_sha="$(sha256_of "${out}")"
	if [ "${got_sha}" != "${shas[$i]}" ] || [ "${got_bytes}" != "${sizes[$i]}" ]; then
		echo "fetch-engine.sh: ${d} is not the pinned engine." >&2
		echo "    url:      ${url}" >&2
		echo "    expected: ${shas[$i]}  ${sizes[$i]} bytes" >&2
		echo "    got:      ${got_sha}  ${got_bytes} bytes" >&2
		echo "" >&2
		if [ "${muts[$i]}" = "mutable" ]; then
			echo "  ${srcs[$i]} is NOT content-addressed upstream — this sha256 is the" >&2
			echo "  only thing pinning it, and it has moved. Before re-pinning, check" >&2
			echo "  that the new file is still the engine's own worker and not the" >&2
			echo "  Studio's replay-worker, which is a different file." >&2
		else
			echo "  ${srcs[$i]} IS content-addressed upstream, so this should be" >&2
			echo "  impossible over a clean fetch. Suspect a proxy, a cache serving a" >&2
			echo "  different object under this name, or a truncated transfer." >&2
		fi
		echo "" >&2
		echo "  remedy: just engine-pin-update   (re-pins, prints the diff to review" >&2
		echo "                                    and commit)" >&2
		fail "  pinned path: ${srcs[$i]}"
	fi

	echo "  + ${d} (${got_bytes} bytes, sha256 ${got_sha:0:16}…, ${muts[$i]} at ${srcs[$i]})"
done

echo "--- the engine at ${dest} is the pinned one, asserted file by file"

# ── What this run fetched, for check-freshness.mjs to hold the publish to ──
#
# Identical to the pinned figures by construction now — the loop above refused
# to get here otherwise — which is the point: this file records the STAGING
# claim, and `check-freshness.mjs` compares it against what actually reaches
# `site/` and then against what the origin serves.
if [ -n "${manifest}" ]; then
	mkdir -p "$(dirname "${manifest}")"
	{
		printf '{\n'
		printf '  "origin": "%s",\n' "${base}"
		printf '  "pin": "%s",\n' "${pin}"
		printf '  "fetchedAt": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf '  "runId": "%s",\n' "${GITHUB_RUN_ID:-local}"
		printf '  "runAttempt": "%s",\n' "${GITHUB_RUN_ATTEMPT:-local}"
		printf '  "files": {\n'
		last=$((${#dests[@]} - 1))
		for i in "${!dests[@]}"; do
			d="${dests[$i]}"
			sep=","
			[ "${i}" -eq "${last}" ] && sep=""
			printf '    "%s": { "sha256": "%s", "bytes": %s }%s\n' \
				"${d}" "$(sha256_of "${dest}/${d}")" "$(bytes_of "${dest}/${d}")" "${sep}"
		done
		printf '  }\n'
		printf '}\n'
	} >"${manifest}"
	echo "--- recorded what this run fetched: ${manifest}"
fi
