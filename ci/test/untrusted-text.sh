#!/usr/bin/env bash
#
# untrusted-text.sh — export the site over a HOSTILE chain corpus and assert
# that no chain-controlled byte becomes markup.
#
# WHY THIS EXISTS
# ---------------
# The explorer renders strings a chain, a node or an artifact distributor
# decides the bytes of: contract names (a source bundle's `origin`), revert
# reasons, refusal detail, rung explanations, source FILE PATHS and the source
# text itself. M9a and M5 specify an `UntrustedText` type and a safe-URL type as
# the typed boundary for exactly these; neither exists, and `git grep
# UntrustedText` over all 822 tracked files returns nothing.
#
# WHAT WAS MEASURED BEFORE THIS FILE WAS WRITTEN, because the absence of a type
# is not the absence of escaping and the difference decides whether this is an
# emergency:
#
#   * There is exactly ONE HTML producer. `components/layout.nim` renders every
#     page through isonim's `ui:` DSL, and `isonim/dsl/ui.nim` wraps every
#     `text` node in `escapeHtml` (ui.nim:611) and every attribute value in
#     `escapeAttr` (ui.nim:647, 652) at COMPILE TIME. There is no code path
#     through the DSL that emits an unescaped value.
#   * `raw` is the one bypass, and all 100-odd call sites take the string
#     another `ui:` block already rendered — composition, not interpolation.
#     The two hand-built markup strings in the client are `<!doctype html>` and
#     the sitemap's XML envelope, and the JSON island escapes `<` itself
#     (`debugger/source_island.nim:134`).
#   * Driven with a poisoned corpus, the payload reached 30 pages and was
#     escaped on every one of them.
#
# So the finding is NOT a live defect. It is that NOTHING KEEPS IT TRUE: the
# boundary is an unnamed property of one macro plus a discipline about `raw`,
# and the 49th `raw` — or the first `& someChainString &` — reintroduces the
# hole silently. This gate is that missing enforcement, and it is deliberately
# an assertion about the RENDERED BYTES rather than a lint over the source,
# because a lint over the source is a second thing to keep in step with the
# renderer and this is the artefact a visitor actually receives.
#
# HOW IT RUNS
# -----------
#   1. derive a hostile chain corpus from a real capture (tools/ci/hostile-chain-corpus.mjs)
#   2. stage it under client/fixtures/chain/ so the exporter ingests it
#   3. compile and run src/static_export.nim into a scratch dist/
#   4. tokenise every page and assert the payload never became markup, with a
#      minimum-carriers floor so a corpus that failed to render cannot pass
#
# The staged corpus is removed by an EXIT trap. It is written under a
# `.hostile-` prefix and is gitignored, so an interrupted run leaves nothing a
# commit could pick up.
#
# Exit codes:
#   0  the boundary held
#   1  a chain-controlled byte became markup
#   2  the export did not build or run
#   3  nothing was measured

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
corpus_src="${repo_root}/client/fixtures/chain/aztec-testnet-frames"
staged="${repo_root}/client/fixtures/chain/.hostile-gate"
slug="hostile-gate"

# The floor. The hostile chain publishes 15 blocks and 5 transactions, so its
# chain page, block list, transaction list, 15 block pages and 5 transaction
# pages all carry chain-controlled strings. Twenty is comfortably under what a
# healthy run produces (30 measured) and comfortably over zero, which is the
# number this floor exists to refuse.
min_carriers=20

if [ ! -d "${corpus_src}" ]; then
	echo "untrusted-text.sh: no capture to derive a hostile corpus from" >&2
	echo "  looked for ${corpus_src}" >&2
	exit 3
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/untrusted-text.XXXXXX")"
cleanup() { rm -rf "${staged}" "${work}"; }
trap cleanup EXIT

echo "== deriving the hostile corpus =="
node "${repo_root}/tools/ci/hostile-chain-corpus.mjs" \
	"${corpus_src}" "${staged}" "${slug}" || exit 2

echo "== exporting the site over it =="
# No -d:searchBundle / -d:settingsBundle: those defines make the exporter
# REQUIRE built bundles, and this gate asks about the rendered HTML, which is
# the same bytes either way. Compiled into the scratch dir so a concurrent
# `just export` is untouched.
(
	cd "${repo_root}/client" &&
		nim c --mm:orc -d:isServer -d:release --hints:off \
			--nimcache:"${work}/nimcache" \
			-o:"${work}/static_export" src/static_export.nim
) >"${work}/build.log" 2>&1 || {
	echo "untrusted-text.sh: the exporter did not build" >&2
	tail -30 "${work}/build.log" >&2
	exit 2
}

(cd "${work}" && "${work}/static_export") >"${work}/export.log" 2>&1 || {
	echo "untrusted-text.sh: the export did not run" >&2
	tail -30 "${work}/export.log" >&2
	exit 2
}
grep -F -- "/${slug}" "${work}/export.log" || {
	echo "untrusted-text.sh: the hostile chain was not ingested" >&2
	cat "${work}/export.log" >&2
	exit 3
}

echo "== asserting the boundary held =="
node "${repo_root}/tools/ci/check-untrusted-text.mjs" \
	"${work}/dist" --min-carriers "${min_carriers}"
rc=$?
if [ "${rc}" -eq 0 ]; then
	echo "untrusted-text.sh: PASS"
else
	echo "untrusted-text.sh: FAIL (rc=${rc})" >&2
fi
exit "${rc}"
