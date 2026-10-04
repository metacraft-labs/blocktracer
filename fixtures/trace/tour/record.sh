#!/usr/bin/env bash
#
# Re-record the capability tour's containers.
#
# Run this DELIBERATELY, not on every build. `nargo trace` is not
# byte-deterministic: `meta.dat` carries a UUIDv7 recording id minted at close,
# and the embedded `workdir` string is whatever directory the recording ran in.
# The demo tree must be byte-identical for a given seed (CI generates it twice
# and diffs), so the containers are vendored rather than regenerated.
#
# The workdir is pinned to $WORKROOT below so that re-recording changes only
# the recording id, and not also a path that happens to name whoever ran it.
#
# Usage:
#   fixtures/trace/tour/record.sh [program-id ...]     (default: all)
#
# Env:
#   NARGO      path to the `nargo` binary   (default: a sibling
#              ../noir/target/release/nargo if one is built, else the pinned
#              recorder under /nix/store — see PINNED_NARGO below)
#   CT_PRINT   path to `ct-print`, used for the summary   (optional)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKROOT="${WORKROOT:-/tmp/blocktracer-tour-rec}"
# The sibling checkouts, found by walking up rather than by a fixed number of
# `..` — this repository is routinely checked out as a git worktree one level
# deeper than its canonical path, and a hard-coded depth silently misses.
find_sibling() {
  local rel="$1" dir="$HERE"
  while [ "$dir" != "/" ]; do
    if [ -e "$dir/$rel" ]; then echo "$dir/$rel"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

NARGO="${NARGO:-$(find_sibling noir/target/release/nargo || true)}"
CT_PRINT="${CT_PRINT:-$(find_sibling codetracer-trace-format-nim/ct-print || true)}"

# THE PINNED RECORDER IS THE FALLBACK, and that is what makes the pin
# load-bearing rather than documentary. The sibling walk above finds a nargo
# somebody BUILT; the pin names the one this corpus was recorded by. Preferring
# the sibling keeps a developer's own build in charge, and falling back to the
# pin means a host that has the store path — which is every host the corpus was
# recorded on, and CI once it substitutes it — runs these checks instead of
# skipping them. `manifest.json`'s `recorder` block is where this value comes
# from; a bump belongs in both places.
PINNED_NARGO="/nix/store/ps7kg504y4hw4jns6c6ccsy5jfmmq71s-Noir/bin/nargo"
if [ -z "${NARGO:-}" ] || [ ! -x "${NARGO:-}" ]; then
  if [ -x "$PINNED_NARGO" ]; then NARGO="$PINNED_NARGO"; fi
fi

if [ -z "$NARGO" ] || [ ! -x "$NARGO" ]; then
  echo "no nargo found in any parent of $HERE — set NARGO=/path/to/nargo" >&2
  echo "build it with: cargo build -p nargo_cli --bin nargo --release" >&2
  exit 2
fi

# The recorder this corpus is pinned to — a corpus recorded by two tracers is
# two corpora.
#
# THE PIN IS A NIX STORE PATH AND NO LONGER A GIT SHA, and the change is a fix
# rather than a relaxation. The 2026-10 recorder is a Nix build that embeds no
# git hash: `nargo --version` answers `git version hash: false`. The previous
# check was
#
#   sed -n 's/.*git version hash: \([0-9a-f]*\).*/\1/p'
#
# which on that string extracts the two hex characters `fa` out of the word
# `false`. It therefore "worked" on the pinned binary only because that binary
# happened to carry a SHA, and against a Nix build it compared `fa` against a
# 40-character pin and warned BY ACCIDENT — a check that cannot distinguish the
# right binary from any other is not a check. A store path is content-addressed,
# so comparing it identifies the exact bytes that produced this corpus, which a
# branch SHA never did.
#
# `manifest.json`'s `recorder` block carries the derivation and both of its
# sources; `README.md` says what is claimed about the noir commit and what is
# not.
PIN="$PINNED_NARGO"
# Resolve both sides: `$NARGO` may be a symlink into the store, or the store
# path itself. `readlink -f` is not portable to macOS's coreutils-free default,
# so fall back to the literal value when it is unavailable.
canon() { readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"; }
if [ "$(canon "$NARGO")" != "$(canon "$PIN")" ]; then
  echo "WARNING: nargo is $NARGO, the corpus is pinned to" >&2
  echo "           $PIN" >&2
  echo "         Re-recording with a different tracer changes what the tour" >&2
  echo "         demonstrates — the 2026-10 move changed \`calls\`, \`functions\`," >&2
  echo "         \`types\` and \`bytes\` in all nine programs. Update the pin here," >&2
  echo "         in fixtures/trace/tour/manifest.json's \`recorder\` block and in" >&2
  echo "         README.md deliberately, or use the pinned binary." >&2
fi

# THE DEFAULT SET IS READ FROM THE MANIFEST, NOT LISTED HERE.
#
# It used to be a hard-coded list, and the list silently went stale: `limits`
# landed in `d837515` as a full ninth program — `sources/Nargo.toml`, a `src`
# tree and `tour_limits.ct` — and this line was not updated. So "re-record every
# container" re-recorded eight of nine and said nothing, which is precisely what
# README.md's own rule forbids: "One pin for the whole corpus: a corpus recorded
# by two tracers is two corpora." A pin bump run through the old default
# produced exactly that, silently.
#
# `programs` in the manifest IS the recordable set — the same key
# `check-corpus.sh` and the E2E layer's `programsWith` select on — so reading it
# here means the three agree by construction. `python3` rather than `jq` for
# `check-corpus.sh`'s reason: it is already a dependency of this repository's
# tooling and `jq` is not.
programs=("$@")
if [ ${#programs[@]} -eq 0 ]; then
  # Captured into a variable and then split, rather than `mapfile` from a
  # process substitution: `mapfile` is bash 4 and this runs under macOS's
  # bash 3.2 too, and the substitution would also throw away python's exit
  # status — a manifest that failed to parse would read as "no programs".
  program_list="$(python3 - "$HERE/manifest.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
for p in m.get("programs", []):
    print(p["id"])
PY
  )" || { echo "could not read the recordable set from $HERE/manifest.json" >&2; exit 2; }
  while IFS= read -r line; do
    [ -n "$line" ] && programs+=("$line")
  done <<< "$program_list"
  if [ ${#programs[@]} -eq 0 ]; then
    echo "$HERE/manifest.json names no programs; refusing to record nothing" >&2
    exit 2
  fi
  echo "recording all ${#programs[@]} program(s) named by manifest.json: ${programs[*]}"
fi

rc=0
for id in "${programs[@]}"; do
  src="$HERE/$id/sources"
  if [ ! -d "$src" ]; then
    echo "no such program: $id" >&2
    rc=1
    continue
  fi
  pkg="$(sed -n 's/^name *= *"\(.*\)"/\1/p' "$src/Nargo.toml" | head -1)"
  work="$WORKROOT/$id"

  rm -rf "$work"
  # `--out-dir` is created here and not relied on. MEASURED at the 2026-10
  # recorder: it now DOES create a missing `--out-dir` (rc 0, "Saved trace to
  # .../nonexistent"), so the previous reason for this line — the old nargo
  # panicked and SIGABRTed on a missing directory — no longer holds. The
  # `mkdir -p` stays because it costs nothing and keeps this script working
  # against an older binary somebody points NARGO at.
  mkdir -p "$work/out"
  cp -R "$src" "$work/pkg"

  echo "── $id ($pkg)"
  ( cd "$work/pkg" && "$NARGO" trace --out-dir "$work/out" ) || { rc=1; continue; }

  if [ ! -f "$work/out/$pkg.ct" ]; then
    echo "   no container produced" >&2
    rc=1
    continue
  fi
  cp "$work/out/$pkg.ct" "$HERE/$id/$pkg.ct"
  echo "   → $id/$pkg.ct ($(wc -c < "$HERE/$id/$pkg.ct" | tr -d ' ') bytes)"
  if [ -x "$CT_PRINT" ]; then
    "$CT_PRINT" --summary "$HERE/$id/$pkg.ct" | sed -n '/counts:/,$p' | sed 's/^/   /'
  fi
done

exit $rc
