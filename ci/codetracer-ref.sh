#!/usr/bin/env bash
#
# codetracer-ref.sh — print the CodeTracer commit this repository is built and
# checked against: the organisation's CodeTracer pin, `pins/codetracer.json` in
# metacraft-labs/metacraft-github-actions, as `flake.lock` locks that input.
#
# This repository stores no CodeTracer revision of its own (see the
# `metacraft-github-actions` input in flake.nix). The scripts that compare
# against the revision — the three vendor gates under `ci/test/` and
# `client/hydrate/build.sh` — ask this script rather than reading a file.
#
# Resolution:
#
#   1. `$CODETRACER_REF`, when set. Every dev shell and `packages.default` set
#      it from the pin beside `$CODETRACER_SRC`, so inside the flake (which is
#      where CI runs every gate) the answer is the pin those shells were built
#      from, with no second evaluation. The self-tests set it to drive the
#      "the pin moved and nobody re-vendored" path.
#      The value is NOT cross-checked against the flake, so it is only as good
#      as whoever set it. `nix develop` and `nix build` set it from the
#      derivation and override any ambient value (checked 2026-11-24: an
#      exported a3986b0de1 printed as the pin inside `nix develop .#ci`), and
#      no workflow sets it, so in CI it is the pin. Outside a dev shell an
#      exported value is believed: unset it to ask the flake instead.
#      `client/hydrate/build.sh` refuses a store-path `$CODETRACER_SRC` that
#      arrives without it, rather than labelling that tree with the pin.
#   2. Otherwise `nix eval` of the flake's `lib.codetracerPin.rev`, with
#      `--no-update-lock-file`: the answer is the revision the COMMITTED lock
#      names, and a lock that does not carry the input is an error rather than
#      a silent re-lock. It fetches the pin set only, not CodeTracer.
#
# Prints the 40-hex revision on stdout. Exits 1, saying why, when it cannot.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -n "${CODETRACER_REF:-}" ]; then
	ref="${CODETRACER_REF}"
	from="\$CODETRACER_REF"
else
	if ! command -v nix >/dev/null 2>&1; then
		echo "codetracer-ref.sh: \$CODETRACER_REF is unset and nix is not on PATH." >&2
		echo "  The CodeTracer revision is the organisation's pin, read through this" >&2
		echo "  flake. Run inside \`nix develop\` (which sets \$CODETRACER_REF), or put" >&2
		echo "  nix on PATH." >&2
		exit 1
	fi
	err="$(mktemp "${TMPDIR:-/tmp}/codetracer-ref.XXXXXX")"
	trap 'rm -f "${err}"' EXIT
	if ! ref="$(nix eval --raw --no-update-lock-file \
		"${repo_root}#lib.codetracerPin.rev" 2>"${err}")"; then
		echo "codetracer-ref.sh: could not evaluate the CodeTracer pin from ${repo_root}/flake.nix:" >&2
		sed 's/^/    /' "${err}" >&2
		exit 1
	fi
	from="flake.lock's metacraft-github-actions pin set"
fi

if ! [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
	echo "codetracer-ref.sh: ${from} gave \`${ref}\`, not a 40-hex commit id." >&2
	exit 1
fi
printf '%s\n' "${ref}"
