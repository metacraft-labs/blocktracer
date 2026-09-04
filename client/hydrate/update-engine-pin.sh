#!/usr/bin/env bash
#
# update-engine-pin.sh — move `engine-pin.txt` to the engine the publisher is
# serving NOW, and print the diff for a human to review and commit.
#
#   ./hydrate/update-engine-pin.sh [base-url] [pin-path]
#   just engine-pin-update
#
# ── Why this is a separate script and not a flag on the fetch ──────────────
#
# `fetch-engine.sh` has no "just take whatever is there" mode, on purpose. A
# pin that a fetch can update is a pin that CI updates on every run, which is
# the unpinned state wearing a file. Re-pinning is a decision — this repository
# choosing to move to a new engine — and a decision leaves a commit.
#
# So this script writes ONLY `engine-pin.txt`. It does not stage an engine, it
# does not touch `site/`, and a deploy that has not had the resulting diff
# committed still fails at the fetch, which is what makes the pin worth having.
#
# ── How the new names are found ────────────────────────────────────────────
#
# Not by guessing `<name>.<hash>.<ext>` from a hash we computed. The publisher
# records its content-addressed names in the deployment's own entry document
# (see `deploy-web-codetracer.yml`: assets are published as
# `<name>.<16 hex of sha256>.<ext>` and "the entry document's descriptor is
# where the URLs are, because a name derived from the bytes cannot be a
# constant anything compiles in"). This reads them from there, then fetches
# them and checks that the name's hex really is a prefix of the bytes' sha256 —
# so a descriptor that is stale relative to the tree it describes is caught
# here rather than pinned.
#
# `worker.js` has no content-addressed twin and is read from the root path.
# `assets/replay-worker.<hash>.js` is deliberately NOT used: it is the Studio's
# own host for the engine, a different file with different imports.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

base="${1:-https://web-codetracer.pages.dev}"
base="${base%/}"
pin="${2:-${here}/engine-pin.txt}"

if [ ! -r "${pin}" ]; then
	echo "update-engine-pin.sh: no pin at ${pin}" >&2
	exit 1
fi

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		echo "update-engine-pin.sh: neither sha256sum nor shasum on PATH" >&2
		exit 1
	fi
}

tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "${tmp}"' EXIT

echo "=== re-pinning against ${base}"

if ! curl -fsSL "${base}/" -o "${tmp}/index.html"; then
	echo "update-engine-pin.sh: could not read the descriptor at ${base}/" >&2
	exit 1
fi

find_asset() {
	# $1 = basename stem, $2 = extension
	grep -oE "/assets/$1\.[0-9a-f]{16}\.$2" "${tmp}/index.html" | head -1 | sed 's,^/,,'
}

js_src="$(find_asset db_backend js)"
wasm_src="$(find_asset db_backend_bg wasm)"

if [ -z "${js_src}" ] || [ -z "${wasm_src}" ]; then
	echo "update-engine-pin.sh: the descriptor at ${base}/ names no content-addressed" >&2
	echo "  db_backend.js and/or db_backend_bg.wasm. Either the publisher changed its" >&2
	echo "  asset naming, or ${base}/ is not the web-codetracer deployment." >&2
	echo "  Refusing to re-pin to the mutable /pkg/ paths, which would produce a pin" >&2
	echo "  that pins nothing but a hash and re-breaks on the publisher's next deploy." >&2
	exit 1
fi

# dest-path : source-path : mutability
records=(
	"worker.js|worker.js|mutable"
	"pkg/db_backend.js|${js_src}|immutable"
	"pkg/db_backend_bg.wasm|${wasm_src}|immutable"
)

new_lines=()
for rec in "${records[@]}"; do
	IFS='|' read -r d s m <<<"${rec}"
	out="${tmp}/$(printf '%s' "${d}" | tr '/' '_')"
	if ! curl -fsSL "${base}/${s}" -o "${out}"; then
		echo "update-engine-pin.sh: could not fetch ${base}/${s}" >&2
		exit 1
	fi
	sha="$(sha256_of "${out}")"
	bytes="$(wc -c <"${out}" | tr -d ' ')"

	if [ "${m}" = "immutable" ]; then
		want="$(printf '%s' "${s}" | grep -oE '[0-9a-f]{16}' | tail -1)"
		if [ "${sha:0:16}" != "${want}" ]; then
			echo "update-engine-pin.sh: ${s} is named for ${want} but hashes to ${sha:0:16}…" >&2
			echo "  The publisher's content-addressed name does not describe its bytes." >&2
			echo "  Pinning that would pin a name whose meaning is already broken." >&2
			exit 1
		fi
	fi

	new_lines+=("$(printf '%-22s  %-42s  %s  %-8s  %s' "${d}" "${s}" "${sha}" "${bytes}" "${m}")")
	echo "  ${d}: ${bytes} bytes, sha256 ${sha:0:16}… (${m}, ${s})"
done

# Rewrite: every comment/blank line of the existing pin is kept verbatim up to
# the first record, and the records are replaced wholesale. The header is where
# the reasoning lives and must survive a re-pin; the `measured` provenance line
# is the one comment that is rewritten, because a stale date on fresh numbers
# is worse than no date.
today="$(date -u +%Y-%m-%d)"
{
	while IFS= read -r line || [ -n "${line}" ]; do
		case "${line}" in
		'#'* | '') ;;
		*) break ;;
		esac
		case "${line}" in
		'# measured '*)
			printf '# measured     %s, against the production deployment of that day\n' "${today}"
			;;
		*) printf '%s\n' "${line}" ;;
		esac
	done <"${pin}"
	for l in "${new_lines[@]}"; do printf '%s\n' "${l}"; done
} >"${tmp}/pin.new"

if cmp -s "${pin}" "${tmp}/pin.new"; then
	echo ""
	echo "--- the pin already names what ${base} is serving. Nothing to commit."
	exit 0
fi

cp "${tmp}/pin.new" "${pin}" || exit 1

echo ""
echo "--- rewrote ${pin}. REVIEW AND COMMIT THIS DIFF:"
echo ""
git -C "${here}" --no-pager diff -- "${pin}" 2>/dev/null || diff -u "${tmp}/pin.old" "${pin}"
echo ""
echo "  Then reconcile the constant the page shows a visitor:"
echo "    client/src/debugger/replay_engine.nim's ReplayEngineWasmBytes must equal"
echo "    the wasm's byte count above. tools/deploy/engine-pin-selftest.mjs asserts it."
