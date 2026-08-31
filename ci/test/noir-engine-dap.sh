#!/usr/bin/env bash
#
# noir-engine-dap.sh — CodeTracer's Noir DAP tests, run against the engine
# BlockTracer actually ships, over the container BlockTracer actually vendors.
#
# The subject is `tests/e2e/noir_engine_dap.nim`: a `nim js -d:nodejs` build of
# the Embed SDK's OWN `WorkerBackendService` — the adapter `client/hydrate/`
# drives in production — talking to the published `wasm32` replay engine inside
# a Node worker, over `fixtures/trace/noir_space_ship/zk_shields.ct`.
#
# ## Three inputs, and none of them is optional
#
#   1. the Embed SDK        — $CODETRACER_SRC, else a ../codetracer sibling.
#                             Same two markers `client/hydrate/build.sh` uses,
#                             because two ways of finding one tree is how the
#                             tree the bundle is built against and the tree the
#                             suite runs against come to differ.
#   2. the replay engine    — $REPLAY_ENGINE_DIR, else client/dist/replay-engine
#                             (what `cd client && just replay-engine` writes),
#                             else fetched with hydrate/fetch-engine.sh.
#   3. the container        — vendored, in this repository.
#
# **There is no skip path.** A suite that goes green because its subject is
# absent is worse than no suite (`ci/test/worker-backend-wasm-e2e.sh` in the
# codetracer repo states the same rule and this follows it).
#
# ## Exit codes
#
#   0    every check passed
#   1    a check failed, or an input is missing
#   124  the engine never answered a request — a HANG.
#
# 124 is not decoration. Verification-Harness-Traps.md §1: a hang arm is one
# whose recorded rc is 124, and every other non-zero code is a die-before-summary
# arm wearing a hang's label. The Nim suite installs a watchdog that exits 124
# and this script preserves it, so a dropped DAP request — the failure dialect
# §1 cost a day to find — is reported as the thing it is.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "=== the Noir DAP port: CodeTracer's tests over BlockTracer's engine seam ==="

# --- 1. the Embed SDK -------------------------------------------------------
find_src() {
	local envvar="$1" sibling="$2" marker="$3"
	local fromenv="${!envvar:-}"
	if [ -n "${fromenv}" ] && [ -e "${fromenv}/${marker}" ]; then
		printf '%s' "${fromenv}"; return 0
	fi
	if [ -e "${REPO_ROOT}/../${sibling}/${marker}" ]; then
		(cd "${REPO_ROOT}/../${sibling}" && pwd); return 0
	fi
	return 1
}

CT="$(find_src CODETRACER_SRC codetracer src/frontend/viewmodel/codetracer_embed.nim)"
[ -n "${CT}" ] || fail "no CodeTracer Embed SDK found.
  Set \$CODETRACER_SRC or keep a ../codetracer checkout.
  The pinned commit is in ci/embed-sdk-pin.env."
[ -f "${CT}/src/frontend/viewmodel/backend/worker_backend.nim" ] || \
	fail "that Embed SDK has no WorkerBackendService:
  ${CT}/src/frontend/viewmodel/backend/worker_backend.nim is missing.
  This suite drives the replay worker through it. Move CODETRACER_REF forward."

ISONIM="$(find_src ISONIM_SRC isonim src/isonim/core/signals.nim)"
NEVERYWHERE="$(find_src NIM_EVERYWHERE_SRC nim-everywhere src)"

# The Node host that supplies the browser globals Node lacks (`self`,
# `DedicatedWorkerGlobalScope`, `fetch` over `file:`) and then imports the
# production `worker.js` unmodified. Resolved from the Embed SDK's own tree
# rather than vendored here: it is the engine repository's shim for the engine
# repository's worker, and a copy in this tree would be a second thing to keep
# in step with a file nobody here owns.
HOST_SRC="${CT}/src/db-backend/wasm-testing/node-host/worker_host.mjs"
[ -f "${HOST_SRC}" ] || fail "the engine's Node worker host is missing:
  ${HOST_SRC}
  It ships in the codetracer repository beside the wasm-testing worker."

# --- 2. the engine ----------------------------------------------------------
ENGINE="${REPLAY_ENGINE_DIR:-}"
if [ -z "${ENGINE}" ] && [ -f "${REPO_ROOT}/client/dist/replay-engine/worker.js" ]; then
	ENGINE="${REPO_ROOT}/client/dist/replay-engine"
fi
if [ -z "${ENGINE}" ]; then
	# `BT_REPLAY_ENGINE_DEST` exists for the self-test, which drives the FETCH
	# path deliberately and must not be able to delete a real engine while
	# doing it — `fetch-engine.sh` removes the destination on failure, by
	# design, so a half-copied engine is never left behind.
	ENGINE="${BT_REPLAY_ENGINE_DEST:-${REPO_ROOT}/client/dist/replay-engine}"
	echo "  no engine on disk — fetching the published one (§5.1's own copy step)"
	"${REPO_ROOT}/client/hydrate/fetch-engine.sh" "${ENGINE}" \
		"${REPLAY_ENGINE_BASE:-https://blocktracer.org/replay-engine}" \
		|| fail "could not fetch the replay engine.
  Set \$REPLAY_ENGINE_DIR to a directory holding worker.js and pkg/, or
  \$REPLAY_ENGINE_BASE to an origin that serves them."
fi

for required in "${ENGINE}/worker.js" "${ENGINE}/pkg/db_backend.js" \
                "${ENGINE}/pkg/db_backend_bg.wasm"; do
	[ -f "${required}" ] || fail "the engine at ${ENGINE} is incomplete: ${required} is missing"
done

# Traps §4's rule applied to an artifact rather than to a grep: a proxy or a
# captive portal answering 200 with an HTML page would otherwise be run as an
# "engine" and fail inside WebAssembly.compileStreaming, where the message
# names neither this script nor that page.
WASM_BYTES="$(wc -c <"${ENGINE}/pkg/db_backend_bg.wasm" | tr -d ' ')"
[ "${WASM_BYTES}" -gt 1000000 ] || \
	fail "${ENGINE}/pkg/db_backend_bg.wasm is only ${WASM_BYTES} bytes — not an engine"

# --- 3. the container -------------------------------------------------------
TRACE="${BT_NOIR_TRACE:-${REPO_ROOT}/fixtures/trace/noir_space_ship/zk_shields.ct}"
[ -f "${TRACE}" ] || fail "the Noir container is missing: ${TRACE}"

command -v node >/dev/null 2>&1 || fail "node is not on PATH"
command -v nim  >/dev/null 2>&1 || fail "nim is not on PATH (run inside the dev shell)"

echo "  Embed SDK: ${CT}"
echo "  engine:    ${ENGINE} (wasm ${WASM_BYTES} bytes)"
echo "  container: ${TRACE} ($(wc -c <"${TRACE}" | tr -d ' ') bytes)"

# The host has to sit beside the worker: it does `import('../worker.js')`, and
# that relative import is what makes the worker's own URL the asset base — the
# same property `engine_transport.startWorker`'s `type: 'module'` relies on.
mkdir -p "${ENGINE}/node-host" || exit 1
cp "${HOST_SRC}" "${ENGINE}/node-host/worker_host.mjs" || exit 1
HOST="${ENGINE}/node-host/worker_host.mjs"

OUT="${BT_NIM_CACHE_ROOT:-/tmp/bt-nim-cache}/noir-engine-dap"
mkdir -p "${OUT}"

PATHS=(
	"--path:${CT}/src/frontend/viewmodel"
	"--path:${CT}/src/frontend"
	"--path:${CT}/src"
)
[ -n "${ISONIM}" ]      && PATHS+=("--path:${ISONIM}/src")
[ -n "${NEVERYWHERE}" ] && PATHS+=("--path:${NEVERYWHERE}/src")

echo "  compiling tests/e2e/noir_engine_dap.nim ..."
nim js -d:nodejs --hints:off --warnings:off \
	-d:nimOldCaseObjects \
	--nimcache:"${OUT}/nimcache" \
	"${PATHS[@]}" \
	-o:"${OUT}/noir_engine_dap.js" \
	"${REPO_ROOT}/tests/e2e/noir_engine_dap.nim" \
	|| fail "could not compile tests/e2e/noir_engine_dap.nim"

echo "  running ..."
echo ""
# The engine logs at INFO to stderr and is extremely chatty (the browser's
# expression loader takes its Err arm on every step, because there is no
# filesystem). Kept OUT of the transcript by default and available with
# BT_ENGINE_LOG=1, because a transcript nobody reads is a transcript that hides
# the one line that matters (Traps §3: log both directions of a boundary you do
# not own — so it is one variable away, not deleted).
if [ "${BT_ENGINE_LOG:-0}" = "1" ]; then
	node "${OUT}/noir_engine_dap.js" "${HOST}" "${TRACE}" 2>&1
	status=$?
else
	# The engine logs on STDOUT, not stderr, so a `2>/dev/null` filters nothing
	# — measured, after a run whose transcript was 12,000 lines of
	# `expr loader load file error`. Filtered by PREFIX rather than dropped, and
	# `${PIPESTATUS[0]}` is what preserves 124 through the pipe.
	node "${OUT}/noir_engine_dap.js" "${HOST}" "${TRACE}" 2>&1 \
		| grep -Ev '^(INFO|DEBUG|WARN|ERROR|TRACE) src/|^wasm worker started$|^using deprecated parameters|^\(node:[0-9]+\)|^Reparsing as ES module|^To eliminate this warning|^\(Use `node'
	status="${PIPESTATUS[0]}"
fi

echo ""
case "${status}" in
	0)   echo "=== noir-engine-dap OK ===" ;;
	124) echo "=== noir-engine-dap HUNG (rc 124) — a request the engine never answered ===" >&2 ;;
	*)   echo "=== noir-engine-dap FAILED (rc ${status}) ===" >&2 ;;
esac
exit "${status}"
