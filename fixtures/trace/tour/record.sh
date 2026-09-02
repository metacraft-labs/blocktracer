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
#   NARGO      path to the `nargo` binary   (default: ../noir/target/release/nargo)
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

if [ -z "$NARGO" ] || [ ! -x "$NARGO" ]; then
  echo "no nargo found in any parent of $HERE — set NARGO=/path/to/nargo" >&2
  echo "build it with: cargo build -p nargo_cli --bin nargo --release" >&2
  exit 2
fi

# The recorder this corpus is pinned to. Every container in the tour, and the
# `tracerCommit` the demo generator publishes in each source bundle, name this
# one commit — a corpus recorded by two tracers is two corpora.
PIN="906af2f42d6b874cf0f5dde193accb1e39e1bcd3"
have="$("$NARGO" --version 2>/dev/null | sed -n 's/.*git version hash: \([0-9a-f]*\).*/\1/p')"
if [ "$have" != "$PIN" ]; then
  echo "WARNING: nargo is at ${have:-unknown}, the corpus is pinned to $PIN." >&2
  echo "         Re-recording with a different tracer changes what the tour" >&2
  echo "         demonstrates. Update the pin here and in fixtures/trace/tour/" >&2
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
  # `--out-dir` must already exist: the pinned nargo predates the commit that
  # creates it, and does not fail gracefully — it panics and SIGABRTs.
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
