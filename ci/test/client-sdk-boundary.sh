#!/usr/bin/env bash
#
# client-sdk-boundary.sh — enforce the BlockTracer Client SDK's boundary, BY
# NAME, in both directions.
#
# WHY THIS EXISTS
# ---------------
# BlockTracer/Client-SDK.md §1.1: "Enforcement is a **bidirectional import
# lint** (M12a), not a review convention, for the same reason BlockTracer
# already lints its facade boundary: a rule that depends on someone remembering
# it is not a boundary."
#
# This is the chain-side half. The debugger-side half lives in the codetracer
# repository (`ci/test/sdk-facade-boundary.sh`), where the package it
# constrains lives. The two are deliberately not one script: each guards the
# package in its own repository, and neither can be disarmed by editing the
# other.
#
# THE THREE DIRECTIONS
# --------------------
#
#   DOWNWARD   The Client SDK may import the Embed SDK — but only through the
#              Embed SDK's facade (`codetracer_embed`), and only from ONE
#              module (`src/blocktracer_client_embed.nim`). Everything else in
#              the package must compile with no debugger anywhere near it,
#              which is what makes "most of what the Client SDK does is not
#              debugging" (Client-SDK.md §1) a checkable property rather than a
#              claim.
#
#   UPWARD     The Embed SDK must contain NO CHAIN CONCEPT — no transaction, no
#              block, no chain id, no generation, and no import of this package
#              (CodeTracer-Embed-SDK.md §3.2, last row; Client-SDK.md §1.1).
#              This is the direction that will actually be tested by events,
#              because BlockTracer is that SDK's first consumer and a chain
#              concept added "just for BlockTracer" always looks local and
#              reasonable. Noir Studio is the second consumer that needs the
#              whole lower layer and none of this one, which is what makes this
#              a boundary rather than a guess (Client-SDK.md §2).
#
#   OUTWARD    A consumer must reach this package only through its facade
#              (`src/blocktracer_client.nim`). Reaching into
#              `src/blocktracer_client/session` directly pins an internal as
#              public ABI, and the stability contract — "internal refactors
#              that do not change the facade are not breaking changes" —
#              becomes false the moment one consumer does it.
#
# HOW A CONSUMER IS DECLARED
# --------------------------
# Nothing is a consumer by accident. A file opts in in one of two spellings,
# both committed and both visible in review — the same two spellings
# codetracer's sdk-facade-boundary.sh uses, because a second convention for the
# same idea is a second thing to learn:
#
#   a. a header comment within the file's first ${MARKER_SCAN_LINES} lines:
#
#          ## SDK-CONSUMER: <reason>
#
#   b. a `.sdk-consumer` file in the file's directory or any ancestor up to the
#      repo root, whose contents are the reason. This is for a whole tree of
#      consumer code — the explorer's pages and components — where marking each
#      file would be noise.
#
# WHY LEXICAL, AND WHAT THAT COSTS
# --------------------------------
# The import graph is computed by reading `import` / `from` / `include`
# statements, not by asking the Nim compiler. That keeps the guard in the
# cheap, always-runnable half of CI (pure bash + awk, no toolchain, about a
# second). The cost is that resolution mimics Nim's rather than being Nim's:
# the importing file's own directory first, then the search roots below. If the
# two ever disagree, the resolver is what is wrong, not the rule.
#
# Usage:
#   ci/test/client-sdk-boundary.sh
#   ci/test/client-sdk-boundary.sh --root DIR          # drive a synthetic tree
#   ci/test/client-sdk-boundary.sh --embed-root DIR    # where codetracer's
#                                                      # viewmodel/ lives
#   ci/test/client-sdk-boundary.sh --require-embed     # absence of the Embed
#                                                      # SDK source is a failure
#   ci/test/client-sdk-boundary.sh --list-graph        # print the SDK's graph
#
# `--root` and `--embed-root` exist so ci/test/client-sdk-boundary-test.sh can
# drive every check against synthetic trees, including deliberate violations.

set -uo pipefail

# Answers from normpath / resolve_module, which write to globals rather than
# printing — see the comment above normpath.
NORMPATH_RESULT=""
RESOLVED_MODULE=""

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The facade — the one module a consumer may import.
FACADE_REL="src/blocktracer_client.nim"
FACADE_MODULE="blocktracer_client"

# The package's internals. Everything under here is private.
SDK_SUBTREE="src/blocktracer_client"

# The single module allowed to import the Embed SDK, and the Embed SDK's own
# facade module name. Both are asserted to appear in the facade's constants, so
# renaming a file without renaming the constant (or vice versa) is caught
# rather than silently disarming this guard.
EMBED_HANDOFF_REL="src/blocktracer_client_embed.nim"
EMBED_HANDOFF_MODULE="blocktracer_client_embed"
EMBED_FACADE_MODULE="codetracer_embed"

# Where an unqualified module spec is looked up, after the importing file's own
# directory. Mirrors client/nim.cfg and the repo's own layout.
SEARCH_ROOTS=("src" "client/src" ".")

# How far into a file the `## SDK-CONSUMER:` header marker may appear.
MARKER_SCAN_LINES=40

# Modules the Client SDK's own graph must not contain, as POSIX ERE over the
# module spec (for anything outside the repo) or the repo-relative path (for
# anything inside it), each with the reason a reader needs.
FORBIDDEN_PATTERNS=(
	"(^|/)isonim/(ui|dsl|renderers|web|components|theming|layout|editor|native|ssr|ssr_nginx|accessibility)(/|$);an IsoNim rendering module — the SDK renders nothing (Client-SDK.md §3, inherited from CodeTracer-Embed-SDK.md §3.2)"
	"(^|/)karax(/|$)|(^|/)kdom(\.nim)?$|(^|/)vdom(\.nim)?$|(^|/)dom(\.nim)?$;a renderer or the DOM — the SDK renders nothing"
	"^client/;the explorer — the SDK is what the explorer consumes, not the other way round"
	"^src/blocktracer/demo/;the demo data GENERATOR. This package reads published files and must contain no producer-specific branch; importing one is how 'the front end never learns which producer wrote the tree' (Data-Contract.md §4) stops being true"
	"^src/blocktracer/publish/;the publisher — writing of any kind is excluded (Client-SDK.md §3)"
	"^src/blocktracer/validator\.nim$;the PRODUCER-side conformance validator. The consumer-side suite is blocktracer_client/conformance.nim and must not borrow the producer's oracle"
	"(^|/)(httpclient|asyncdispatch|asynchttpserver|net|nativesockets)(\.nim)?$;a socket. This package reads published files through an injected path->bytes closure; chain RPC of any kind is excluded (Client-SDK.md §3) and so is opening a connection itself"
	"(^|/)osproc(\.nim)?$;spawns processes — an embeddable library cannot"
	"(^|/)${EMBED_FACADE_MODULE}(\.nim)?$;the Embed SDK. The chain half of this package must compile with no debugger on the path at all; the handoff belongs in ${EMBED_HANDOFF_REL} and nowhere else (Client-SDK.md §5)"
)

# Identity. CodeTracer-Identity.md §4: the read path carries no identity, and
# M12a's deliverable is "no identity anywhere in this package".
#
# Matched case-insensitively as substrings, comments excluded — a comment has
# no behaviour, and this package's modules must be able to SAY that they carry
# no identity without tripping the guard that checks it. See token_hits below
# for why substring and not whole word.
#
# `session` is deliberately NOT a token: `ChainSession` is the generation pin
# (Static-Site-Architecture.md §3.3) and has nothing to do with a login. What
# is banned is unambiguous: nothing in a static-file reader has a reason to say
# `setCookie`.
IDENTITY_TOKENS=(
	"cookie"
	"setcookie"
	"set_cookie"
	"authorization"
	"authenticate"
	"bearer"
	"credentials"
	"withcredentials"
	"apikey"
	"api_key"
	"oauth"
	"jwt"
	"sessiontoken"
	"session_token"
	"accesstoken"
	"access_token"
	"refreshtoken"
	"userid"
	"user_id"
	"telemetry"
	"analytics"
	"sendbeacon"
	"fingerprint"
)

# Chain concepts, banned from the EMBED SDK's graph. Copied deliberately
# verbatim from codetracer's ci/test/sdk-facade-boundary.sh so the two halves
# of one boundary cannot drift into disagreeing about what a chain concept is;
# ci/test/client-sdk-boundary-test.sh asserts the two lists are identical when
# that repository is available.
#
# Three deliberate exclusions, because a lint that cries wolf gets switched off:
# bare `chain` (Value Origin Tracking has chains of causes), bare `block` (a
# CTFS container has byte blocks, and `BlockSource` is the Embed SDK's own
# name for its custom trace-source escape hatch) and bare `generation`
# (`sourceGeneration` is recompilation identity).
#
# `blocktracer` is in the list, which is also how the reverse import direction
# is enforced: the Embed SDK cannot name this package at all.
CHAIN_TOKENS=(
	"chainid"
	"chain_id"
	"chaingeneration"
	"chain_generation"
	"blocknumber"
	"block_number"
	"blockhash"
	"block_hash"
	"blockheight"
	"block_height"
	"blocktimestamp"
	"blockexplorer"
	"blocktracer"
	"txhash"
	"tx_hash"
	"transactionhash"
	"transaction_hash"
	"transactionindex"
	"transaction_index"
	"transactionreceipt"
)

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
embed_root=""
require_embed=0
list_graph=0
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		shift
		root="$1"
		;;
	--embed-root)
		shift
		embed_root="$1"
		;;
	--require-embed) require_embed=1 ;;
	--list-graph) list_graph=1 ;;
	*)
		echo "client-sdk-boundary.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
	shift
done
cd "${root}" || exit 2
root="$PWD"

# ---------------------------------------------------------------------------
# Reporting — every check runs and reports; the status is decided at the end,
# so one run tells a contributor everything that is wrong rather than the first
# thing.
# ---------------------------------------------------------------------------

failures=0
checks_run=0
skipped=0

check_ok() {
	checks_run=$((checks_run + 1))
	echo "  OK        $1"
}

check_failed() {
	checks_run=$((checks_run + 1))
	failures=$((failures + 1))
	echo "  VIOLATION $1"
}

check_skipped() {
	skipped=$((skipped + 1))
	echo "  SKIP      $1"
}

violation_detail() {
	echo "              $1"
}

# ---------------------------------------------------------------------------
# Nim import extraction
#
# Emits one module spec per line for a file. Handles the forms this repo
# actually uses:
#
#   import a                     import a, b            import a/b
#   import a/[b, c]              from a/b import c      include a
#   import a as b                import a except c
#   indented imports inside `when defined(js):`
#   bracket lists split over several lines
# ---------------------------------------------------------------------------

nim_imports() {
	[ -f "$1" ] || return 0
	awk '
	function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
	function count(s, ch,   n, i) {
		n = 0
		for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++
		return n
	}
	function emit_spec(spec) {
		spec = trim(spec)
		sub(/[ \t]+as[ \t]+.*$/, "", spec)
		spec = trim(spec)
		if (spec != "") print spec
	}
	function emit_list(body,   depth, i, ch, item, pre, inner, n, parts, j) {
		depth = 0; item = ""
		body = body ","
		for (i = 1; i <= length(body); i++) {
			ch = substr(body, i, 1)
			if (ch == "[") depth++
			else if (ch == "]") depth--
			if (ch == "," && depth == 0) {
				item = trim(item)
				if (item != "") {
					if (item ~ /\[.*\]$/) {
						pre = item; sub(/\[.*$/, "", pre); pre = trim(pre)
						sub(/\/$/, "", pre); pre = trim(pre)
						inner = item; sub(/^[^[]*\[/, "", inner); sub(/\][^]]*$/, "", inner)
						n = split(inner, parts, ",")
						for (j = 1; j <= n; j++) {
							if (trim(parts[j]) != "") emit_spec(pre "/" trim(parts[j]))
						}
					} else {
						emit_spec(item)
					}
				}
				item = ""
			} else {
				item = item ch
			}
		}
	}
	function flush(stmt,   p) {
		if (stmt ~ /^from[ \t]/) {
			sub(/^from[ \t]+/, "", stmt)
			p = index(stmt, " import ")
			if (p > 0) stmt = substr(stmt, 1, p - 1)
		} else {
			sub(/^import[ \t]+/, "", stmt)
			sub(/^include[ \t]+/, "", stmt)
		}
		sub(/[ \t]+except[ \t]+.*$/, "", stmt)
		emit_list(stmt)
	}
	{
		line = $0
		h = index(line, "#")
		if (h > 0) line = substr(line, 1, h - 1)
		t = trim(line)
		if (collecting == 0) {
			if (t ~ /^import[ \t]/ || t ~ /^from[ \t]/ || t ~ /^include[ \t]/ ||
			    t == "import" || t == "include") {
				buf = t
				collecting = 1
			} else {
				next
			}
		} else {
			if (t == "") next
			buf = buf " " t
		}
		if (buf ~ /^(import|from|include)$/) next
		if (count(buf, "[") == count(buf, "]") && buf !~ /,$/ && buf !~ /\[$/) {
			flush(buf)
			collecting = 0
			buf = ""
		}
	}
	END { if (collecting == 1) flush(buf) }
	' "$1"
}

# normpath PATH — collapse `.` and `..` textually, into the global
# NORMPATH_RESULT. No filesystem access, so it works for paths that do not
# exist yet (which is what the synthetic-tree tests need).
#
# It answers through a global rather than by printing, and so does
# resolve_module below, because the graph walk calls them thousands of times
# and a command substitution is a fork each. Doing it the tidy way made this
# guard take twelve seconds on the real Embed SDK graph; this way it takes
# under two, which is the difference between a lint that runs on every commit
# and one someone eventually moves to nightly.
normpath() {
	local p="$1" part last n
	local out=()
	local IFS='/'
	for part in $p; do
		case "${part}" in
		"" | ".") continue ;;
		"..")
			n="${#out[@]}"
			last=""
			[ "${n}" -gt 0 ] && last="${out[$((n - 1))]}"
			if [ "${n}" -gt 0 ] && [ "${last}" != ".." ]; then
				out=(${out[@]+"${out[@]:0:$((n - 1))}"})
			else
				out+=("..")
			fi
			;;
		*) out+=("${part}") ;;
		esac
	done
	NORMPATH_RESULT="${out[*]:-}"
}

# resolve_module SPEC IMPORTER_PATH — sets RESOLVED_MODULE to the path the spec
# resolves to inside the tree being scanned, or "" when it is external (stdlib,
# isonim, a sibling package).
resolve_module() {
	local spec="$1" importer="$2"
	RESOLVED_MODULE=""
	case "${spec}" in
	std/* | system | macros | unittest) return 0 ;;
	esac
	local dir candidate
	dir="${importer%/*}"
	[ "${dir}" = "${importer}" ] && dir="."
	normpath "${dir}/${spec}.nim"
	candidate="${NORMPATH_RESULT}"
	if [ -f "${candidate}" ]; then
		RESOLVED_MODULE="${candidate}"
		return 0
	fi
	case "${spec}" in
	./* | ../*) return 0 ;;
	esac
	local r
	for r in "${SEARCH_ROOTS[@]}"; do
		normpath "${r}/${spec}.nim"
		candidate="${NORMPATH_RESULT}"
		if [ -f "${candidate}" ]; then
			RESOLVED_MODULE="${candidate}"
			return 0
		fi
	done
	return 0
}

# closure_of FILE — every file reachable from FILE by imports, one per line,
# including FILE itself.
closure_of() {
	local start="$1"
	local queue=("${start}")
	# A delimited string rather than an associative array: this has to run under
	# the bash 3.2 that ships with macOS, where `declare -A` does not exist.
	local seen="|${start}|"
	local cur spec resolved
	while [ "${#queue[@]}" -gt 0 ]; do
		cur="${queue[0]}"
		queue=(${queue[@]+"${queue[@]:1}"})
		printf '%s\n' "${cur}"
		while read -r spec; do
			[ -n "${spec}" ] || continue
			resolve_module "${spec}" "${cur}"
			resolved="${RESOLVED_MODULE}"
			[ -n "${resolved}" ] || continue
			case "${seen}" in
			*"|${resolved}|"*) ;;
			*)
				seen="${seen}${resolved}|"
				queue+=("${resolved}")
				;;
			esac
		done < <(nim_imports "${cur}")
	done
}

# external_specs_of FILES... — module specs reached from a set of files that do
# not resolve inside the tree being scanned. These are what a forbidden-module
# rule has to match for `karax`, `isonim/ui` and friends.
external_specs_of() {
	local f spec
	for f in "$@"; do
		while read -r spec; do
			[ -n "${spec}" ] || continue
			resolve_module "${spec}" "${f}"
			if [ -z "${RESOLVED_MODULE}" ]; then
				printf '%s\n' "${spec}"
			fi
		done < <(nim_imports "${f}")
	done | sort -u
}

# token_hits TOKEN FILES... — case-insensitive SUBSTRING matches outside comment
# lines. Comments are excluded because a comment has no behaviour, and these
# modules must be able to cite the rule that constrains them without tripping
# the guard that checks it.
#
# Substring rather than whole-word, deliberately, and this is the one place
# this guard is stricter than codetracer's sibling half. A whole-word rule
# misses `DefaultChainId` and `parentBlockHash`: the banned token sits inside a
# larger identifier, which is exactly how a chain concept actually arrives —
# nobody adds a field called `chainid`. The tokens in both lists are compound
# spellings already (`blocknumber`, `txhash`), so the false-positive risk is
# small, and it is measured rather than assumed: substring-scanning every one
# of the 191 `.nim` files under the Embed SDK's `src/frontend/viewmodel` at the
# pinned commit, for every token in either list, produces ZERO non-comment
# hits. Re-measured at `codetracer` `dev` 813510ad — after M2b added its
# degraded-state model and two suites, which grew the facade's own closure from
# 32 modules to 33 — and still zero. If a future measurement is not zero, the
# answer is a more specific token, not a looser match: a whole-word rule misses
# `DefaultChainId`, and `ci/test/client-sdk-boundary-test.sh` has a case that
# goes red the moment this becomes `grep -w`. The LIST is identical in both
# halves — what is banned is one
# thing; how thoroughly it is found is not something the two can disagree
# about, because a stricter search cannot admit anything the looser one
# rejects.
token_hits() {
	local token="$1"
	shift
	grep -rniF "${token}" "$@" 2>/dev/null |
		awk -F: '{ rest = $0; sub(/^[^:]*:[0-9]+:/, "", rest); if (rest !~ /^[ \t]*#/) print }' |
		head -20
}

# ---------------------------------------------------------------------------
# File enumeration
#
# git when the tree is a repository (so vendored trees and build output stay
# out), a plain find otherwise — which is what the synthetic-tree tests need.
# ---------------------------------------------------------------------------

all_nim_files() {
	if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		{
			git ls-files '*.nim' 2>/dev/null
			git ls-files --others --exclude-standard '*.nim' 2>/dev/null
		} | sort -u
	else
		find . -name '*.nim' -not -path './.git/*' 2>/dev/null | sed 's|^\./||' | sort -u
	fi
}

consumer_files() {
	local list header_hits marker d
	list="$(mktemp)"
	all_nim_files >"${list}"
	{
		if [ -s "${list}" ]; then
			header_hits="$(tr '\n' '\0' <"${list}" |
				xargs -0 grep -lE '^[[:space:]]*##[[:space:]]*SDK-CONSUMER:' 2>/dev/null)"
			while read -r f; do
				[ -n "${f}" ] || continue
				if head -n "${MARKER_SCAN_LINES}" "${f}" 2>/dev/null |
					grep -qE '^[[:space:]]*##[[:space:]]*SDK-CONSUMER:'; then
					printf '%s\n' "${f}"
				fi
			done <<<"${header_hits}"
		fi
		while read -r marker; do
			[ -n "${marker}" ] || continue
			d="$(dirname "${marker}")"
			if [ "${d}" = "." ]; then
				cat "${list}"
			else
				grep -E "^${d}/" "${list}" || true
			fi
		done < <(find . -name .sdk-consumer -not -path './.git/*' 2>/dev/null | sed 's|^\./||')
	} | sort -u
	rm -f "${list}"
}

# ---------------------------------------------------------------------------
# Check 1: the facade exists and knows its own name
# ---------------------------------------------------------------------------

if [ "${list_graph}" -eq 1 ]; then
	graph=()
	while IFS= read -r line; do graph+=("${line}"); done < <(closure_of "${FACADE_REL}" | sort -u)
	printf '%s\n' ${graph[@]+"${graph[@]}"}
	external_specs_of ${graph[@]+"${graph[@]}"} | sed 's/^/external: /'
	exit 0
fi

echo "=== Client SDK boundary (BlockTracer/Client-SDK.md §1.1, M12a) ==="

facade_ok=0
if [ ! -f "${FACADE_REL}" ]; then
	check_failed "facade-present"
	violation_detail "${FACADE_REL} does not exist — the package has no public surface"
elif ! grep -q "BlockTracerClientFacadeModule\* = \"${FACADE_MODULE}\"" "${FACADE_REL}"; then
	check_failed "facade-present"
	violation_detail "${FACADE_REL} does not declare BlockTracerClientFacadeModule* = \"${FACADE_MODULE}\";"
	violation_detail "the facade file and the name this guard enforces have drifted apart"
elif ! grep -q "BlockTracerClientEmbedModule\* = \"${EMBED_HANDOFF_MODULE}\"" "${FACADE_REL}"; then
	check_failed "facade-present"
	violation_detail "${FACADE_REL} does not declare BlockTracerClientEmbedModule* = \"${EMBED_HANDOFF_MODULE}\";"
	violation_detail "the handoff module's name and the name this guard enforces have drifted apart"
else
	check_ok "facade-present"
	facade_ok=1
fi

# ---------------------------------------------------------------------------
# Checks 2 and 3: the Client SDK's own graph
# ---------------------------------------------------------------------------

if [ "${facade_ok}" -eq 1 ]; then
	sdk_closure=()
	while IFS= read -r line; do sdk_closure+=("${line}"); done < <(closure_of "${FACADE_REL}" | sort -u)
	sdk_externals=()
	while IFS= read -r line; do sdk_externals+=("${line}"); done < <(external_specs_of ${sdk_closure[@]+"${sdk_closure[@]}"})

	echo "  (SDK graph: ${#sdk_closure[@]} repo modules, ${#sdk_externals[@]} external specs)"

	forbidden_violations=0
	for entry in "${FORBIDDEN_PATTERNS[@]}"; do
		pattern="${entry%%;*}"
		reason="${entry#*;}"
		for item in ${sdk_closure[@]+"${sdk_closure[@]}"} ${sdk_externals[@]+"${sdk_externals[@]}"}; do
			if printf '%s' "${item}" | grep -qE "${pattern}"; then
				forbidden_violations=$((forbidden_violations + 1))
				violation_detail "${item} — ${reason}"
			fi
		done
	done
	if [ "${forbidden_violations}" -eq 0 ]; then
		check_ok "sdk-graph-reads-only (no renderer, no producer, no socket, no debugger)"
	else
		check_failed "sdk-graph-reads-only: ${forbidden_violations} forbidden module(s) reachable from the facade"
	fi

	identity_violations=0
	for token in "${IDENTITY_TOKENS[@]}"; do
		while read -r hit; do
			[ -n "${hit}" ] || continue
			identity_violations=$((identity_violations + 1))
			violation_detail "${hit}"
			violation_detail "  '${token}' is an identity concept; the read path carries none"
			violation_detail "  (CodeTracer-Identity.md §4). Embedding this package must not make"
			violation_detail "  reading attributable."
		done < <(token_hits "${token}" ${sdk_closure[@]+"${sdk_closure[@]}"})
	done
	if [ "${identity_violations}" -eq 0 ]; then
		check_ok "sdk-graph-no-identity (CodeTracer-Identity.md §4)"
	else
		check_failed "sdk-graph-no-identity: ${identity_violations} identity reference(s) in the SDK graph"
	fi
fi

# ---------------------------------------------------------------------------
# Check 4: the handoff module reaches the Embed SDK only through its facade
# ---------------------------------------------------------------------------

if [ ! -f "${EMBED_HANDOFF_REL}" ]; then
	check_failed "embed-handoff-present"
	violation_detail "${EMBED_HANDOFF_REL} does not exist — nothing hands the Embed SDK a TraceSource,"
	violation_detail "which is M12a's central deliverable (Client-SDK.md §1)"
else
	handoff_violations=0
	saw_embed_facade=0
	while read -r spec; do
		[ -n "${spec}" ] || continue
		if [ "${spec}" = "${EMBED_FACADE_MODULE}" ]; then
			saw_embed_facade=1
			continue
		fi
		# Anything that looks like it comes from inside the Embed SDK's own
		# subtree is a reach past its facade. CodeTracer-Embed-SDK.md §7:
		# anything not exported from `codetracer_embed` is private.
		case "${spec}" in
		viewmodel/* | */viewmodel/* | sdk/trace_source | sdk/debugger_session | \
			store/types | store/replay_data_store | store/request_tracker | \
			backend/* | viewmodels/* | app/app_vm | session_vm | headless_session)
			handoff_violations=$((handoff_violations + 1))
			violation_detail "${EMBED_HANDOFF_REL} imports '${spec}'"
			violation_detail "  That is an Embed SDK internal. Import only '${EMBED_FACADE_MODULE}'."
			violation_detail "  (CodeTracer-Embed-SDK.md §7: anything not exported from the facade is private,"
			violation_detail "  and an internal refactor that does not change it is not a breaking change.)"
			;;
		esac
	done < <(nim_imports "${EMBED_HANDOFF_REL}")
	if [ "${saw_embed_facade}" -eq 0 ]; then
		handoff_violations=$((handoff_violations + 1))
		violation_detail "${EMBED_HANDOFF_REL} does not import '${EMBED_FACADE_MODULE}'"
		violation_detail "  This module exists to depend on the Embed SDK. If it stops doing so,"
		violation_detail "  the downward half of the boundary is being asserted about nobody."
	fi
	if [ "${handoff_violations}" -eq 0 ]; then
		check_ok "embed-handoff-facade-only: ${EMBED_HANDOFF_REL} imports '${EMBED_FACADE_MODULE}' and no internal"
	else
		check_failed "embed-handoff-facade-only: ${handoff_violations} violation(s)"
	fi
fi

# ---------------------------------------------------------------------------
# Check 5: declared consumers reach this package only through the facade
# ---------------------------------------------------------------------------

consumers=()
while IFS= read -r line; do consumers+=("${line}"); done < <(consumer_files)

consumer_violations=0
for c in ${consumers[@]+"${consumers[@]}"}; do
	while read -r spec; do
		[ -n "${spec}" ] || continue
		resolve_module "${spec}" "${c}"
		resolved="${RESOLVED_MODULE}"
		[ -n "${resolved}" ] || continue
		case "${resolved}" in
		"${SDK_SUBTREE}"/*) ;;
		*) continue ;;
		esac
		consumer_violations=$((consumer_violations + 1))
		violation_detail "${c} imports '${spec}' -> ${resolved}"
		violation_detail "  That is a Client SDK internal. A consumer may import only"
		violation_detail "  '${FACADE_MODULE}' (or '${EMBED_HANDOFF_MODULE}' to open a trace)."
	done < <(nim_imports "${c}")
done

if [ "${#consumers[@]}" -eq 0 ]; then
	check_failed "consumer-declared: no file declares itself an SDK consumer"
	violation_detail "This guard would pass vacuously. At least the explorer and the"
	violation_detail "consumer-side conformance suite must be declared consumers, or the"
	violation_detail "outward half of the boundary is being asserted about nobody."
elif [ "${consumer_violations}" -eq 0 ]; then
	check_ok "consumer-facade-only: ${#consumers[@]} declared consumer file(s), no reach past the facade"
else
	check_failed "consumer-facade-only: ${consumer_violations} import(s) past the facade"
fi

# ---------------------------------------------------------------------------
# Check 6: the Embed SDK contains no chain concept, and never names this package
#
# The upward half. Run against the real codetracer checkout when one is
# reachable; ci/test/client-sdk-boundary-test.sh runs the same code against
# synthetic Embed SDK trees — one clean, one carrying a deliberate violation —
# so the RULE is exercised on every CI run whether or not the sibling repo is.
# ---------------------------------------------------------------------------

if [ -z "${embed_root}" ]; then
	if [ -n "${CODETRACER_SRC:-}" ] && [ -d "${CODETRACER_SRC}/src/frontend/viewmodel" ]; then
		embed_root="${CODETRACER_SRC}/src/frontend/viewmodel"
	elif [ -d "${root}/../codetracer/src/frontend/viewmodel" ]; then
		embed_root="${root}/../codetracer/src/frontend/viewmodel"
	fi
fi

scan_embed_graph() {
	local dir="$1"
	local saved_pwd="${PWD}"
	local saved_roots=("${SEARCH_ROOTS[@]}")
	cd "${dir}" || return 2
	SEARCH_ROOTS=("." ".." "../..")

	if [ ! -f "${EMBED_FACADE_MODULE}.nim" ]; then
		cd "${saved_pwd}" || true
		SEARCH_ROOTS=("${saved_roots[@]}")
		return 3
	fi

	local graph=() externals=() line
	while IFS= read -r line; do graph+=("${line}"); done < <(closure_of "${EMBED_FACADE_MODULE}.nim" | sort -u)
	while IFS= read -r line; do externals+=("${line}"); done < <(external_specs_of ${graph[@]+"${graph[@]}"})
	echo "  (Embed SDK graph: ${#graph[@]} modules, ${#externals[@]} external specs, at ${dir})"

	local violations=0 token hit spec
	for token in "${CHAIN_TOKENS[@]}"; do
		while read -r hit; do
			[ -n "${hit}" ] || continue
			violations=$((violations + 1))
			violation_detail "${hit}"
			violation_detail "  '${token}' is a chain concept; CodeTracer-Embed-SDK.md §3.2's last row"
			violation_detail "  bans it from that package. Resolving a chain's data to a trace"
			violation_detail "  belongs one layer up, in this one (Client-SDK.md §1.1)."
		done < <(token_hits "${token}" ${graph[@]+"${graph[@]}"})
	done
	# The reverse import direction, stated separately from the token scan so the
	# message names the actual failure rather than a word.
	for spec in ${externals[@]+"${externals[@]}"}; do
		case "${spec}" in
		blocktracer_client | blocktracer_client/* | blocktracer_client_embed | blocktracer/*)
			violations=$((violations + 1))
			violation_detail "the Embed SDK imports '${spec}'"
			violation_detail "  The dependency runs Client SDK -> Embed SDK and NEVER the reverse"
			violation_detail "  (Client-SDK.md §1.1)."
			;;
		esac
	done

	cd "${saved_pwd}" || true
	SEARCH_ROOTS=("${saved_roots[@]}")
	[ "${violations}" -eq 0 ]
}

if [ -n "${embed_root}" ] && [ -d "${embed_root}" ]; then
	if scan_embed_graph "${embed_root}"; then
		check_ok "embed-graph-no-chain-concept (CodeTracer-Embed-SDK.md §3.2, last row)"
	else
		rc=$?
		if [ "${rc}" -eq 3 ]; then
			# The directory exists but carries no facade — typically a sibling
			# codetracer checkout sitting on a branch that predates the Embed
			# SDK. That the facade EXISTS is codetracer's own guard to make;
			# this one has nothing to scan, and saying so is more honest than
			# failing a BlockTracer build for the state of another checkout.
			if [ "${require_embed}" -eq 1 ]; then
				check_failed "embed-graph-no-chain-concept: ${embed_root}/${EMBED_FACADE_MODULE}.nim not found"
				violation_detail "--require-embed was given and the directory carries no Embed SDK facade."
			else
				check_skipped "embed-graph-no-chain-concept — ${embed_root} carries no ${EMBED_FACADE_MODULE}.nim"
				echo "              The RULE is still exercised: ci/test/client-sdk-boundary-test.sh runs it"
				echo "              against synthetic Embed SDK trees, one of which violates it deliberately."
			fi
		else
			check_failed "embed-graph-no-chain-concept: chain reference(s) in the Embed SDK graph"
		fi
	fi
elif [ "${require_embed}" -eq 1 ]; then
	check_failed "embed-graph-no-chain-concept: no Embed SDK source"
	violation_detail "--require-embed was given but neither --embed-root, \$CODETRACER_SRC nor"
	violation_detail "../codetracer/src/frontend/viewmodel is present."
else
	check_skipped "embed-graph-no-chain-concept — no Embed SDK source (set CODETRACER_SRC or pass --embed-root)"
	echo "              The RULE is still exercised: ci/test/client-sdk-boundary-test.sh runs it"
	echo "              against synthetic Embed SDK trees, one of which violates it deliberately."
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

echo "--- ${checks_run} check(s), ${failures} failing, ${skipped} skipped"
if [ "${failures}" -gt 0 ]; then
	exit 1
fi
exit 0
