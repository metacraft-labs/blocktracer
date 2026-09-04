#!/usr/bin/env bash
#
# journeys-refusal-exit-code-test.sh — contract suite for the guard next door.
#
# THE GUARD IT TESTS IS STATIC ON PURPOSE, AND THAT IS EXACTLY WHY IT NEEDS
# THIS. A scanner is the easiest kind of check to write so that it can never
# fail: point it at a pattern nothing matches and it reports a clean sweep
# forever. Both directions are therefore arms here — a module-scope `throw` must
# be FOUND, and the ordinary throws that fill this codebase must NOT be, because
# a guard that flags every `throw` would be switched off within a day.
#
# ARM 2b IS THE ONE THAT EARNED ITS PLACE. The guard next door was first written
# to flag a module-scope `throw`, and it reported RESULT: OK against the very
# commit whose defect it exists for — the real shape was a module-scope `try`
# rethrowing from its `catch`, which is at depth 1. An arm built from the actual
# historical defect, rather than from a description of it, is what caught that.
#
# Run: bash ci/test/journeys-refusal-exit-code-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/journeys-refusal-exit-code.sh"

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

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

stage() {
	rm -rf "${work}/t"
	mkdir -p "${work}/t/tools/journeys/lib"
	# A module shaped like the real ones: refusals, but all inside functions.
	cat >"${work}/t/tools/journeys/run.mjs" <<'JS'
import { openSite } from "./lib/site.mjs";
async function main() {
  const site = await openSite("dist");
  if (!site) {
    const e = new Error("no site");
    e.exitCode = 2;
    throw e;
  }
}
main().catch((e) => process.exit(e.exitCode ?? 1));
JS
	cat >"${work}/t/tools/journeys/lib/site.mjs" <<'JS'
export async function openSite(dist) {
  if (!dist) {
    const e = new Error("PROVENANCE REFUSED");
    e.exitCode = 2;
    throw e;
  }
  return { dist };
}
JS
}

run_guard() { bash "${guard}" --root "${work}/t" 2>&1; }

echo "=== journeys refusal exit code — contract ==="
echo

# --- CONTROL ---------------------------------------------------------------
stage
out="$(run_guard)"
rc=$?
if [ "${rc}" -eq 0 ] && grep -q 'RESULT: OK' <<<"${out}"; then
	ok "CONTROL: throws inside functions are not flagged — the guard is not a blanket"
else
	bad "CONTROL: a clean synthetic tree is already red; no arm below means anything"
	printf '%s\n' "${out}" | grep FAILED | head -3 | sed 's/^/           /'
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED"
	exit 1
fi

if grep -q 'scanned 2 module(s)' <<<"${out}"; then
	ok "CONTROL: the scan found both modules — it is not reporting a clean sweep of nothing"
else
	bad "CONTROL: the scan did not find 2 modules; every arm below would be vacuous"
	printf '%s\n' "${out}" | grep scanned | sed 's/^/           /'
fi
echo

arm() {
	local name="$1" expect="$2"
	shift 2
	stage
	"$@"
	local out rc
	out="$(run_guard)"
	rc=$?
	if [ "${rc}" -eq 0 ]; then
		bad "${name}: SURVIVED — the guard is still green with the defect in place"
		return
	fi
	if grep -qF -- "${expect}" <<<"${out}"; then
		ok "${name}: killed"
	else
		bad "${name}: went red, but not for its own reason (wanted: ${expect})"
		printf '%s\n' "${out}" | grep FAILED | head -2 | sed 's/^/           /'
	fi
}

# ARM 1 — THE DEFECT ITSELF, in the shape it actually had. `lib/probe.mjs`
# threw at module scope with `exitCode = 2` set, and node exited 1 anyway.
m_module_scope() {
	cat >>"${work}/t/tools/journeys/lib/site.mjs" <<'JS'

const e = new Error("playwright is not installed");
e.exitCode = 2;
throw e;
JS
}
arm "1/a throw at module scope is found" "throw\` at module scope" m_module_scope

# ARM 2 — INDENTED, BUT STILL MODULE SCOPE. A `grep '^throw'` would miss this,
# which is the reason the scan counts braces instead of anchoring to column 0.
m_indented_top_level() {
	cat >>"${work}/t/tools/journeys/lib/site.mjs" <<'JS'

if (!process.env.CT_OK)
    throw new Error("indented, but nothing encloses it");
JS
}
arm "2/an INDENTED module-scope throw is still module scope" \
	"throw\` at module scope" m_indented_top_level

# ARM 2b — THE SHAPE THE REAL DEFECT ACTUALLY HAD, and the one the first draft
# of this guard missed. `lib/probe.mjs` resolved playwright inside a
# MODULE-SCOPE `try`, and rethrew from the `catch`. The throw is at depth 1, so
# a depth-zero throw test says nothing; the `try` is what runs on import.
m_module_scope_try() {
	cat >>"${work}/t/tools/journeys/lib/site.mjs" <<'JS'

let dep;
try {
  dep = require("playwright");
} catch (err) {
  const e = new Error("playwright is not installed");
  e.exitCode = 2;
  throw e;
}
JS
}
arm "2b/a module-scope try whose catch rethrows is found" \
	"\`try\` at module scope" m_module_scope_try

# ARM 2c — TOP-LEVEL AWAIT. Same evaluation window, no throw anywhere.
m_top_level_await() {
	cat >>"${work}/t/tools/journeys/lib/site.mjs" <<'JS'

const mod = await import("node:fs");
JS
}
arm "2c/a top-level await runs on import too" \
	"top-level \`await\`" m_top_level_await

# --- FALSE-POSITIVE ARMS ---------------------------------------------------
# These must leave the guard GREEN. A scanner that cannot tell code from text is
# worse than no scanner: it produces findings nobody can act on, and it is the
# `refs_in` prose trap in a new costume.
must_stay_green() {
	local name="$1"
	shift
	stage
	"$@"
	local out rc
	out="$(run_guard)"
	rc=$?
	if [ "${rc}" -eq 0 ]; then
		ok "${name}"
	else
		bad "${name} — the guard flagged something that is not a module-scope throw"
		printf '%s\n' "${out}" | grep FAILED | head -2 | sed 's/^/           /'
	fi
}

m_throw_in_string() {
	cat >>"${work}/t/tools/journeys/lib/site.mjs" <<'JS'

export const advice = "do not throw at module scope";
export const tmpl = `a throw inside a template literal { with braces }`;
JS
}
must_stay_green "3/the word throw inside a string is not code" m_throw_in_string

m_throw_in_comment() {
	cat >>"${work}/t/tools/journeys/lib/site.mjs" <<'JS'

// throw at module scope would lose the exit code
/* throw here too { and this brace must not shift the depth } */
JS
}
must_stay_green "4/the word throw inside a comment is not code" m_throw_in_comment

m_throw_in_nested() {
	cat >>"${work}/t/tools/journeys/lib/site.mjs" <<'JS'

export const check = (v) => {
  [1, 2].forEach((n) => {
    if (n === v) { throw new Error("deep inside three bodies"); }
  });
};
JS
}
must_stay_green "5/a throw nested in an arrow inside a callback is fine" m_throw_in_nested

m_property_named_throw() {
	cat >>"${work}/t/tools/journeys/lib/site.mjs" <<'JS'

export const handlers = { rethrow: 1 };
export const q = handlers.rethrow;
JS
}
must_stay_green "6/an identifier merely CONTAINING throw is not the keyword" m_property_named_throw

# ARM 7 — NON-VACUITY. A scan that finds no modules must not report success:
# that is the failure mode this whole repository is auditing, and a static
# scanner is the likeliest place for it.
stage
rm -f "${work}/t/tools/journeys/run.mjs" "${work}/t/tools/journeys/lib/site.mjs"
out="$(run_guard)"
if grep -q 'scanned 0 module(s)' <<<"${out}" && grep -q 'RESULT: OK' <<<"${out}"; then
	bad "7/an empty scan reports a clean sweep of nothing"
	printf '%s\n' "${out}" | grep scanned | sed 's/^/           /'
else
	ok "7/an empty scan does not report a clean sweep (or reports the count honestly)"
fi

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — every arm must be killed by the rule written for it"
	exit 1
fi
echo "  Import-time work is found — try, await and throw at module scope, however"
echo "  indented — and ordinary code is not: throws in functions, in strings, in"
echo "  comments, in nested bodies, and identifiers that merely contain the word."
echo "RESULT: OK"
