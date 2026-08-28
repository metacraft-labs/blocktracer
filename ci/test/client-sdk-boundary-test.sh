#!/usr/bin/env bash
#
# client-sdk-boundary-test.sh — the guard's own test suite.
#
# A lint nobody has watched fail is a lint that might be passing vacuously.
# Every case below drives ci/test/client-sdk-boundary.sh against a synthetic
# tree carrying ONE deliberate violation and asserts it is rejected, plus the
# clean control that asserts it is not rejected for no reason.
#
# The Embed SDK cases matter most, and are the reason this file exists rather
# than the guard simply being run in CI: the upward half of the boundary — "the
# Embed SDK contains no chain concept" — constrains a package in ANOTHER
# repository. Running the rule against synthetic Embed SDK trees, one clean and
# one carrying `blockNumber`, means M12a's
# `test_the_embed_sdk_contains_no_chain_concept` is exercised on every CI run
# here, whether or not a codetracer checkout is present.
#
# Usage: ci/test/client-sdk-boundary-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/client-sdk-boundary.sh"

pass=0
fail=0
work="$(mktemp -d "${TMPDIR:-/tmp}/client-sdk-boundary-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT

report_pass() {
	pass=$((pass + 1))
	echo "  ok       $1"
}

report_fail() {
	fail=$((fail + 1))
	echo "  FAILED   $1"
	if [ -n "${2:-}" ]; then
		printf '%s\n' "$2" | sed 's/^/               /'
	fi
}

# expect_guard EXPECTED_STATUS NAME ARGS... — run the guard and compare its
# exit status. 0 = accepted, 1 = rejected.
expect_guard() {
	local want="$1" name="$2"
	shift 2
	local out status
	# CODETRACER_SRC is stripped: every case below either supplies its own
	# --embed-root or is not about the Embed SDK, and letting the real one leak
	# in would make each case re-scan the real Embed SDK's graph for nothing.
	out="$(env -u CODETRACER_SRC "${guard}" "$@" 2>&1)"
	status=$?
	if [ "${status}" -eq "${want}" ]; then
		report_pass "${name}"
	else
		report_fail "${name} (expected exit ${want}, got ${status})" "${out}"
	fi
}

# ---------------------------------------------------------------------------
# Synthetic trees
# ---------------------------------------------------------------------------

# make_sdk_tree DIR — a minimal, CLEAN tree with the shape the guard expects:
# a facade, one internal, the embed handoff, and one declared consumer.
make_sdk_tree() {
	local d="$1"
	mkdir -p "${d}/src/blocktracer_client" "${d}/client/src"

	cat >"${d}/src/blocktracer_client.nim" <<'EOF'
import blocktracer_client/store
export store

const
  BlockTracerClientFacadeModule* = "blocktracer_client"
  BlockTracerClientEmbedModule* = "blocktracer_client_embed"
EOF

	cat >"${d}/src/blocktracer_client/store.nim" <<'EOF'
import std/json

type ObjectStore* = object
  name*: string
EOF

	cat >"${d}/src/blocktracer_client_embed.nim" <<'EOF'
import blocktracer_client
export blocktracer_client

import codetracer_embed
export codetracer_embed
EOF

	cat >"${d}/client/src/app.nim" <<'EOF'
## SDK-CONSUMER: the explorer reads chain data through the facade.
import blocktracer_client

proc go*(s: ObjectStore) = discard s
EOF
}

# make_embed_tree DIR — a minimal, CLEAN synthetic Embed SDK: a facade and one
# internal, with no chain concept anywhere.
make_embed_tree() {
	local d="$1"
	mkdir -p "${d}/store"
	cat >"${d}/codetracer_embed.nim" <<'EOF'
import store/types
export types

const CodeTracerEmbedFacadeModule* = "codetracer_embed"
EOF
	cat >"${d}/store/types.nim" <<'EOF'
type
  Step* = object
    index*: int
  BlockSource* = object
    ## A byte block of the container. Nothing to do with a blockchain block.
    name*: string
EOF
}

echo "=== client-sdk-boundary.sh — guard self-test ==="

# ---------------------------------------------------------------------------
# The real repository
# ---------------------------------------------------------------------------

expect_guard 0 "the real repository satisfies its own boundary" --root "${repo_root}"

if [ -n "${CODETRACER_SRC:-}" ] && [ -f "${CODETRACER_SRC}/src/frontend/viewmodel/codetracer_embed.nim" ]; then
	out="$("${guard}" --root "${repo_root}" --require-embed 2>&1)"
	if [ $? -eq 0 ]; then
		report_pass "the real repository passes against the REAL Embed SDK at \$CODETRACER_SRC"
	else
		report_fail "the real repository fails against the REAL Embed SDK at \$CODETRACER_SRC" "${out}"
	fi
else
	echo "  skip     real Embed SDK scan — set CODETRACER_SRC to a codetracer checkout"
	echo "               carrying src/frontend/viewmodel/codetracer_embed.nim"
fi

# ---------------------------------------------------------------------------
# Client SDK side — the control, then one violation at a time
# ---------------------------------------------------------------------------

clean="${work}/clean"
make_sdk_tree "${clean}"
expect_guard 0 "a clean synthetic package is accepted" --root "${clean}"

t="${work}/consumer-reaches-past-facade"
make_sdk_tree "${t}"
cat >"${t}/client/src/app.nim" <<'EOF'
## SDK-CONSUMER: the explorer reads chain data through the facade.
import blocktracer_client
import blocktracer_client/store
EOF
expect_guard 1 "a consumer importing an SDK INTERNAL is rejected" --root "${t}"

t="${work}/sdk-imports-renderer"
make_sdk_tree "${t}"
cat >>"${t}/src/blocktracer_client/store.nim" <<'EOF'
import isonim/dsl/ui
EOF
expect_guard 1 "the SDK importing a RENDERER is rejected" --root "${t}"

t="${work}/sdk-imports-dom"
make_sdk_tree "${t}"
cat >>"${t}/src/blocktracer_client/store.nim" <<'EOF'
import dom
EOF
expect_guard 1 "the SDK importing the DOM is rejected" --root "${t}"

t="${work}/sdk-imports-producer"
make_sdk_tree "${t}"
mkdir -p "${t}/src/blocktracer/demo"
echo 'proc generate*() = discard' >"${t}/src/blocktracer/demo/generator.nim"
cat >>"${t}/src/blocktracer_client/store.nim" <<'EOF'
import blocktracer/demo/generator
EOF
expect_guard 1 "the SDK importing a PRODUCER is rejected" --root "${t}"

t="${work}/sdk-imports-socket"
make_sdk_tree "${t}"
cat >>"${t}/src/blocktracer_client/store.nim" <<'EOF'
import std/httpclient
EOF
expect_guard 1 "the SDK opening a SOCKET is rejected (no chain RPC, no fetching of its own)" --root "${t}"

t="${work}/sdk-imports-embed-directly"
make_sdk_tree "${t}"
cat >>"${t}/src/blocktracer_client/store.nim" <<'EOF'
import codetracer_embed
EOF
expect_guard 1 "the CHAIN HALF importing the Embed SDK is rejected (only the handoff may)" --root "${t}"

t="${work}/sdk-carries-identity"
make_sdk_tree "${t}"
cat >>"${t}/src/blocktracer_client/store.nim" <<'EOF'

proc authenticatedGet*(path, bearer: string): string =
  discard bearer
  path
EOF
expect_guard 1 "an IDENTITY concept anywhere in the SDK graph is rejected" --root "${t}"

t="${work}/identity-in-a-comment"
make_sdk_tree "${t}"
cat >>"${t}/src/blocktracer_client/store.nim" <<'EOF'

# This module sends no cookie and no authorization header: a read carries a
# path and nothing else (CodeTracer-Identity.md §4).
EOF
expect_guard 0 "an identity word in a COMMENT is not a violation (a module may state the rule)" --root "${t}"

t="${work}/facade-renamed"
make_sdk_tree "${t}"
mv "${t}/src/blocktracer_client.nim" "${t}/src/bt_client.nim"
expect_guard 1 "renaming the facade without renaming the constant is rejected" --root "${t}"

t="${work}/facade-constant-drift"
make_sdk_tree "${t}"
sed -i.bak 's/BlockTracerClientEmbedModule\* = "blocktracer_client_embed"/BlockTracerClientEmbedModule* = "something_else"/' \
	"${t}/src/blocktracer_client.nim"
expect_guard 1 "the handoff module's name drifting from the guard's is rejected" --root "${t}"

t="${work}/handoff-reaches-embed-internal"
make_sdk_tree "${t}"
# `import codetracer_embed` is present deliberately, so the ONLY rule that can
# reject this tree is the internal-reach one. Without it the tree would also
# trip "the handoff no longer imports the Embed SDK", and this case would be
# green while the internal-reach rule was disarmed — which is exactly what
# happened before: the case passed with that rule's match list emptied out.
cat >"${t}/src/blocktracer_client_embed.nim" <<'EOF'
import blocktracer_client
import codetracer_embed
import sdk/trace_source
EOF
expect_guard 1 "the handoff reaching PAST the Embed SDK's facade is rejected" --root "${t}"

t="${work}/handoff-drops-the-dependency"
make_sdk_tree "${t}"
cat >"${t}/src/blocktracer_client_embed.nim" <<'EOF'
import blocktracer_client
export blocktracer_client
EOF
expect_guard 1 "the handoff no longer importing the Embed SDK is rejected (the boundary would be about nobody)" --root "${t}"

t="${work}/handoff-missing"
make_sdk_tree "${t}"
rm "${t}/src/blocktracer_client_embed.nim"
expect_guard 1 "a package with no Embed SDK handoff at all is rejected" --root "${t}"

t="${work}/no-declared-consumer"
make_sdk_tree "${t}"
rm "${t}/client/src/app.nim"
expect_guard 1 "a package with NO declared consumer is rejected (the guard would pass vacuously)" --root "${t}"

t="${work}/consumer-by-directory-marker"
make_sdk_tree "${t}"
sed -i.bak '1d' "${t}/client/src/app.nim"
echo "the explorer" >"${t}/client/.sdk-consumer"
expect_guard 0 "a .sdk-consumer directory marker declares a whole tree" --root "${t}"

t="${work}/consumer-by-directory-marker-violating"
make_sdk_tree "${t}"
sed -i.bak '1d' "${t}/client/src/app.nim"
echo "the explorer" >"${t}/client/.sdk-consumer"
echo 'import blocktracer_client/store' >>"${t}/client/src/app.nim"
expect_guard 1 "a directory-declared consumer reaching past the facade is rejected" --root "${t}"

# ---------------------------------------------------------------------------
# Embed SDK side — the upward half of the boundary
# ---------------------------------------------------------------------------

embed_clean="${work}/embed-clean"
make_embed_tree "${embed_clean}"
expect_guard 0 "a clean synthetic Embed SDK is accepted" \
	--root "${clean}" --embed-root "${embed_clean}" --require-embed

t="${work}/embed-blocknumber"
make_embed_tree "${t}"
cat >>"${t}/store/types.nim" <<'EOF'

type ChainStep* = object
  blockNumber*: int
EOF
expect_guard 1 "an Embed SDK that learns what a BLOCK NUMBER is is rejected" \
	--root "${clean}" --embed-root "${t}" --require-embed

t="${work}/embed-txhash"
make_embed_tree "${t}"
cat >>"${t}/codetracer_embed.nim" <<'EOF'

proc openTransaction*(txHash: string) = discard txHash
EOF
expect_guard 1 "an Embed SDK that learns what a TRANSACTION HASH is is rejected" \
	--root "${clean}" --embed-root "${t}" --require-embed

t="${work}/embed-chainid"
make_embed_tree "${t}"
mkdir -p "${t}/store"
cat >>"${t}/store/types.nim" <<'EOF'

const DefaultChainId* = 1
EOF
expect_guard 1 "an Embed SDK that learns what a CHAIN ID is is rejected" \
	--root "${clean}" --embed-root "${t}" --require-embed

t="${work}/embed-imports-client-sdk"
make_embed_tree "${t}"
cat >>"${t}/codetracer_embed.nim" <<'EOF'
import blocktracer_client
EOF
# NOTE: two rules reject this tree, and they cannot be separated. `blocktracer`
# is itself a CHAIN_TOKEN, so any spelling of an import of this package is
# caught by the token scan as well as by the reverse-import rule below it. The
# reverse-import rule is therefore belt-and-braces that improves the MESSAGE
# ("the Embed SDK imports 'blocktracer_client'" rather than "'blocktracer' is a
# chain concept"); the PROPERTY is what this case pins, and it is enforced
# either way.
expect_guard 1 "an Embed SDK that IMPORTS the Client SDK is rejected (the dependency runs one way)" \
	--root "${clean}" --embed-root "${t}" --require-embed

t="${work}/embed-transitive-violation"
make_embed_tree "${t}"
mkdir -p "${t}/backend"
cat >"${t}/backend/wire.nim" <<'EOF'
type Envelope* = object
  transactionIndex*: int
EOF
cat >>"${t}/codetracer_embed.nim" <<'EOF'
import backend/wire
EOF
expect_guard 1 "a chain concept reached TRANSITIVELY, not only in the facade, is rejected" \
	--root "${clean}" --embed-root "${t}" --require-embed

t="${work}/embed-block-word-is-allowed"
make_embed_tree "${t}"
cat >>"${t}/store/types.nim" <<'EOF'

proc readBlock*(source: BlockSource, offset: int): seq[byte] =
  ## A byte block of the CTFS container. `block` alone is not a chain concept.
  discard source
  discard offset
  @[]
EOF
expect_guard 0 "the WORD 'block' alone is not a violation (a CTFS container has byte blocks)" \
	--root "${clean}" --embed-root "${t}" --require-embed

expect_guard 1 "--require-embed with no Embed SDK source at all is rejected" \
	--root "${clean}" --embed-root "${work}/does-not-exist" --require-embed

# ---------------------------------------------------------------------------
# Cross-repository consistency: the two halves must agree on what a chain
# concept IS. Two lists that drift are two boundaries.
# ---------------------------------------------------------------------------

extract_tokens() {
	awk '/^CHAIN_TOKENS=\(/{inside=1; next} inside && /^\)/{exit} inside{
		gsub(/^[ \t]*"/, ""); gsub(/"[ \t]*$/, ""); if ($0 != "") print
	}' "$1"
}

sibling_guard=""
if [ -n "${CODETRACER_SRC:-}" ] && [ -f "${CODETRACER_SRC}/ci/test/sdk-facade-boundary.sh" ]; then
	sibling_guard="${CODETRACER_SRC}/ci/test/sdk-facade-boundary.sh"
elif [ -f "${repo_root}/../codetracer/ci/test/sdk-facade-boundary.sh" ]; then
	sibling_guard="${repo_root}/../codetracer/ci/test/sdk-facade-boundary.sh"
fi

if [ -n "${sibling_guard}" ]; then
	ours="$(extract_tokens "${guard}")"
	theirs="$(extract_tokens "${sibling_guard}")"
	if [ "${ours}" = "${theirs}" ]; then
		report_pass "both halves of the boundary use the same CHAIN_TOKENS list"
	else
		report_fail "the two halves disagree about what a chain concept is" \
			"$(diff <(printf '%s\n' "${theirs}") <(printf '%s\n' "${ours}") || true)"
	fi
else
	echo "  skip     CHAIN_TOKENS cross-check — no codetracer checkout carrying"
	echo "               ci/test/sdk-facade-boundary.sh (set CODETRACER_SRC)"
fi

echo "--- $((pass + fail)) case(s), ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
