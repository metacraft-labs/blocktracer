#!/usr/bin/env bash
# byte-identity.sh — is the PUBLISHED KEY LAYOUT unchanged?
#
#   tools/chain/byte-identity.sh --ref <git-ref> [--mutant] [--seed S] [--work DIR]
#
# Normally reached through `just byte-identity <ref>` / `just byte-identity-mutant <ref>`.
#
# ── WHY THIS IS A RECIPE AND NOT A PROCEDURE ──────────────────────────────────────────
#
# It is the only evidence for the seam's central claim — "every shard path this project
# has published is still addressable" (Publishing-And-Caching.md §6.1, §6.2) — and no test
# can make it: the claim is about two BUILDS of the producers, and a test compiled from one
# tree can only see one of them. So it was an operator procedure, and every reviewer
# re-invented it from nothing (two trees, six captures, sha256 manifests, mutant controls).
# The last one said rebuilding it consumed most of the review. A measurement that has to be
# reconstructed before it can be repeated is a measurement nobody repeats.
#
# ── WHAT IT DOES ──────────────────────────────────────────────────────────────────────
#
#   1. materialises `<ref>` — the BEFORE side — with `git archive`, so nothing is checked
#      out, no worktree is registered and the working tree is never touched;
#   2. builds both producers from it, and both producers from the WORKING TREE;
#   3. runs each pair over the SAME INPUT BYTES — the capture directories are read from
#      this repository by absolute path, by both builds, so "the same input" is the same
#      file rather than two copies of it;
#   4. manifests every published object as `<sha256>  <relative path>`, sorted, so a path
#      that MOVED and a path whose BYTES moved both show up in the diff;
#   5. reports, per tree and in total, the object count and the differing-line count.
#
# A DIFFERING LINE IS NOT AN OBJECT, and the recipe reports lines because that is what
# `diff` can be held to without the recipe interpreting it. An object whose PATH moved
# contributes two lines — the old path leaves and the new one arrives — and so does one
# whose BYTES moved; only a tree one side could not publish contributes one line per
# object. Zero is zero either way, which is the number this exists to establish.
#
# ── AND THE MUTANT MODE, WHICH IS NOT OPTIONAL EVIDENCE ───────────────────────────────
#
# A diff that always reports zero is the failure mode here, and this diff reported zero on
# every run it has ever had. `--mutant` builds a THIRD pair from a copy of the working tree
# with one field of `tools/chain/identifier-encodings.json` changed — `hex`'s `stripPrefix`,
# emptied — and requires the differing-line count to be NON-ZERO. That field is the payload
# composition every shard key is derived through, so emptying it re-keys most of the corpus.
#
# THE MUTANT IS DELIBERATELY NOT THE `case` RULE, and the reason is worth knowing before
# reading a zero as reassurance: every identifier in every committed capture is already
# lowercase, so NO mutation of the case rule can move a byte. Measured, a mutant of
# `identifierKeyForm` moves NOTHING at all. The byte diff is live for the payload
# composition and SILENT ABOUT CASE BY CONSTRUCTION — which is why the evidence for case
# handling is `tests/tidentifierencoding.nim` and two compile-time refusals, not this.
#
# The mutant tree is a COPY (tracked plus untracked-and-not-ignored, via git), so a mutation
# never reaches the repository and an interrupted run cannot leave it modified.
#
# ── WHAT IT IS NOT ────────────────────────────────────────────────────────────────────
#
# It never contacts a chain. Both producers read committed captures off disk; the live
# follower is not built and not run. `blocktracer-follow-chain` would start a real mainnet
# run and write into `client/fixtures/chain/`, which is what this is comparing.

set -u

REF=""
MUTANT=0
SEED="byte-identity"
WORK="${BYTE_IDENTITY_WORK:-/build/byte-identity}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ref)    REF="${2:-}"; shift 2 ;;
    --mutant) MUTANT=1; shift ;;
    --seed)   SEED="${2:-}"; shift 2 ;;
    --work)   WORK="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,6p' "$0"; exit 0 ;;
    *)
      echo "byte-identity: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$REF" ]; then
  echo "byte-identity: --ref <git-ref> is required. It is the BEFORE side: the commit whose" >&2
  echo "  producers are rebuilt and compared against the working tree. There is no default," >&2
  echo "  because a default of HEAD would compare the working tree to itself whenever the" >&2
  echo "  change under review was already committed, and report zero for that reason." >&2
  exit 2
fi

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO" || exit 9

if ! git -C "$REPO" rev-parse --verify --quiet "$REF^{commit}" > /dev/null; then
  echo "byte-identity: '$REF' is not a commit in $REPO" >&2
  exit 2
fi
BEFORE_SHA="$(git -C "$REPO" rev-parse --short "$REF^{commit}")"

# ── the six trees, and why there are six rather than five ────────────────────────────
#
# Five captures, and `aztec` twice: `--scope full` and `--scope curated` publish DIFFERENT
# object sets from one snapshot, and the curated one is what the deployed site serves. A
# comparison over the full scope alone would leave the published layout of the deployed
# tree unmeasured.
TREES="
aztec-full:ingest:client/fixtures/chain/aztec:full
aztec-curated:ingest:client/fixtures/chain/aztec:curated
aztec-testnet:ingest:client/fixtures/chain/aztec-testnet:full
aztec-testnet-frames:ingest:client/fixtures/chain/aztec-testnet-frames:full
aztec-mainnet-live:ingest:tests/fixtures/chain-snapshots/aztec-mainnet-live:full
demo:demo::
"

LOG="$WORK/log"
mkdir -p "$LOG" || exit 9

say() { echo "$*"; }
step() { say ""; say "── $* ─────────────────────────────────────────"; }

# ── materialise a source tree for one side ───────────────────────────────────────────
#
# BEFORE comes from `git archive`, which writes the ref's content without checking anything
# out and without registering a worktree — the working tree is not touched and cannot be
# left on another branch by an interrupted run.
#
# AFTER and MUTANT come from `git ls-files` plus untracked-and-not-ignored, which is the
# same population `ci/test/client-sdk-boundary.sh` and the boundary sweeps use: it is the
# working tree as it stands, including a fix that has been written and not yet committed,
# which is exactly when this comparison is wanted.
materialise() {
  local side="$1"
  local dst="$WORK/src-$side"
  rm -rf "$dst" && mkdir -p "$dst" || return 9
  if [ "$side" = before ]; then
    git -C "$REPO" archive --format=tar "$REF" > "$WORK/before.tar" 2> "$LOG/archive.err"
    rc=$?; [ $rc -ne 0 ] && { say "git archive failed (rc=$rc): $(cat "$LOG/archive.err")"; return $rc; }
    tar -x -f "$WORK/before.tar" -C "$dst" 2> "$LOG/archive-untar.err"
    rc=$?; [ $rc -ne 0 ] && { say "untar failed (rc=$rc)"; return $rc; }
  else
    { git -C "$REPO" ls-files -z; git -C "$REPO" ls-files -z -o --exclude-standard; } \
      > "$WORK/$side.filelist" 2> "$LOG/$side-ls.err"
    rc=$?; [ $rc -ne 0 ] && { say "git ls-files failed (rc=$rc)"; return $rc; }
    tar -c -C "$REPO" -f "$WORK/$side.tar" --null -T "$WORK/$side.filelist" \
      2> "$LOG/$side-tar.err"
    rc=$?; [ $rc -ne 0 ] && { say "tar failed (rc=$rc): $(cat "$LOG/$side-tar.err")"; return $rc; }
    tar -x -f "$WORK/$side.tar" -C "$dst" 2> "$LOG/$side-untar.err"
    rc=$?; [ $rc -ne 0 ] && { say "untar failed (rc=$rc)"; return $rc; }
  fi
  say "  $side: source tree at $dst"
  return 0
}

# THE MUTATION, applied to the COPY. One field, named in the message, so a reader of the
# output knows what was broken and why that breaks a shard key.
mutate() {
  local f="$WORK/src-mutant/tools/chain/identifier-encodings.json"
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
i = s.index('"id": "hex"')
j = s.index('"stripPrefix": "0x"', i)
old = '"stripPrefix": "0x"'
s = s[:j] + '"stripPrefix": ""' + s[j + len(old):]
open(p, 'w').write(s)
print("mutated hex stripPrefix: \"0x\" -> \"\"")
PY
  return $?
}

build() {
  local side="$1"
  local src="$WORK/src-$side"
  local bin="$WORK/bin-$side"
  rm -rf "$bin" && mkdir -p "$bin" || return 9
  local target
  for target in blocktracer_chain_ingest blocktracer_demo_gen; do
    ( cd "$src" && nim c --hints:off -d:release -o:"$bin/$target" "src/$target.nim" ) \
      > "$LOG/$side-build-$target.log" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
      say "  $side: BUILD FAILED for $target (rc=$rc) — see $LOG/$side-build-$target.log"
      tail -5 "$LOG/$side-build-$target.log"
      return $rc
    fi
  done
  say "  $side: both producers built"
  return 0
}

# ── publish every tree and manifest it ───────────────────────────────────────────────
#
# `sha256sum` over `find | sort`, relative to the tree root, so the manifest is one line
# per object and a MOVED path and CHANGED bytes are both a differing line. `LC_ALL=C` so
# the sort order is the same on every machine and two manifests are comparable at all.
REFUSED_TREES=""
REFUSED_COUNT=0
publish() {
  local side="$1"
  local bin="$WORK/bin-$side"
  local out="$WORK/out-$side"
  local tolerate="${2:-no}"
  rm -rf "$out" && mkdir -p "$out" || return 9
  REFUSED_TREES=""
  REFUSED_COUNT=0
  local row name kind snap scope
  for row in $TREES; do
    name="$(echo "$row" | cut -d: -f1)"
    kind="$(echo "$row" | cut -d: -f2)"
    snap="$(echo "$row" | cut -d: -f3)"
    scope="$(echo "$row" | cut -d: -f4)"
    if [ "$kind" = ingest ]; then
      "$bin/blocktracer_chain_ingest" --snapshot "$REPO/$snap" --out "$out/$name" \
        --scope "$scope" > "$LOG/$side-$name.log" 2>&1
    else
      "$bin/blocktracer_demo_gen" --out:"$out/$name" --seed:"$SEED" \
        > "$LOG/$side-$name.log" 2>&1
    fi
    rc=$?
    if [ $rc -ne 0 ]; then
      if [ "$tolerate" = refusal-is-a-signal ]; then
        # A MUTANT THAT CANNOT PUBLISH AT ALL IS THE STRONGEST LIVENESS SIGNAL
        # THERE IS, and it is a real outcome rather than a harness failure: with
        # `hex`'s prefix strip emptied, the demo producer's hash index reaches
        # `parseHexInt` on a payload that still carries `0x` and REFUSES. A wrong
        # shard rule therefore does not publish quietly. It is counted rather
        # than swallowed, and the run says which trees refused.
        say "  $side/$name: REFUSED (rc=$rc) — $(grep -m1 'Error:' "$LOG/$side-$name.log")"
        REFUSED_TREES="$REFUSED_TREES $name"
        REFUSED_COUNT=$((REFUSED_COUNT + 1))
        : > "$WORK/manifest-$side-$name.txt"
        continue
      fi
      say "  $side/$name: PRODUCER FAILED (rc=$rc) — see $LOG/$side-$name.log"
      tail -5 "$LOG/$side-$name.log"
      return $rc
    fi
    ( cd "$out/$name" && LC_ALL=C find . -type f | LC_ALL=C sort | tr '\n' '\0' \
        | xargs -0 sha256sum ) > "$WORK/manifest-$side-$name.txt" \
        2> "$LOG/$side-manifest-$name.err"
    rc=$?
    if [ $rc -ne 0 ]; then
      say "  $side/$name: MANIFEST FAILED (rc=$rc)"
      return $rc
    fi
  done
  return 0
}

# ── the comparison ───────────────────────────────────────────────────────────────────
#
# Reports the object count AND the differing-line count, per tree and in total, because
# either alone can be read the wrong way: zero differing lines over zero objects is the
# vacuous green this whole recipe is guarding against, so the count is printed beside it
# and a tree that published nothing is a FAILURE rather than a match.
TOTAL_OBJECTS=0
TOTAL_DIFF=0
EMPTY_TREES=0
IGNORE_EMPTY_B=no
compare() {
  local a="$1"
  local b="$2"
  TOTAL_OBJECTS=0; TOTAL_DIFF=0; EMPTY_TREES=0
  local row name objs objs_b diff
  printf '  %-24s %10s %10s %16s\n' tree objects "objects($b)" "differing lines"
  for row in $TREES; do
    name="$(echo "$row" | cut -d: -f1)"
    objs=$(wc -l < "$WORK/manifest-$a-$name.txt")
    objs_b=$(wc -l < "$WORK/manifest-$b-$name.txt")
    diff=$(LC_ALL=C diff "$WORK/manifest-$a-$name.txt" "$WORK/manifest-$b-$name.txt" \
             | grep -c '^[<>]')
    printf '  %-24s %10d %10d %16d\n' "$name" "$objs" "$objs_b" "$diff"
    TOTAL_OBJECTS=$((TOTAL_OBJECTS + objs))
    TOTAL_DIFF=$((TOTAL_DIFF + diff))
    [ "$objs" -eq 0 ] && EMPTY_TREES=$((EMPTY_TREES + 1))
    if [ "$objs_b" -eq 0 ] && [ "$IGNORE_EMPTY_B" != yes ]; then
      EMPTY_TREES=$((EMPTY_TREES + 1))
    fi
  done
  printf '  %-24s %10d %10s %16d\n' TOTAL "$TOTAL_OBJECTS" '' "$TOTAL_DIFF"
}

say "byte-identity: before = $REF ($BEFORE_SHA), after = the working tree"
say "               demo seed = $SEED, work dir = $WORK"

step "materialising both sides"
materialise before || exit $?
materialise after  || exit $?

step "building the producers"
build before || exit $?
build after  || exit $?

step "publishing every committed capture, both sides"
publish before || exit $?
publish after  || exit $?

step "BEFORE vs AFTER"
compare before after
BASE_OBJECTS=$TOTAL_OBJECTS
BASE_DIFF=$TOTAL_DIFF
BASE_EMPTY=$EMPTY_TREES

if [ "$BASE_EMPTY" -ne 0 ]; then
  say ""
  say "FAIL — $BASE_EMPTY tree(s) published NOTHING. Zero differing lines over zero"
  say "       objects is not evidence of anything, which is the whole reason the count"
  say "       is printed beside the diff."
  exit 1
fi

if [ "$MUTANT" -eq 1 ]; then
  step "the mutant control — proving the comparison is live"
  materialise mutant || exit $?
  mutate || exit $?
  build mutant || exit $?
  publish mutant refusal-is-a-signal || exit $?
  MUT_REFUSED=$REFUSED_COUNT
  MUT_REFUSED_TREES="$REFUSED_TREES"
  step "AFTER vs MUTANT"
  IGNORE_EMPTY_B=yes
  compare after mutant
  MUT_DIFF=$TOTAL_DIFF
  IGNORE_EMPTY_B=no
  say ""
  say "  mutant trees that REFUSED to publish at all: $MUT_REFUSED ($MUT_REFUSED_TREES)"
  if [ "$MUT_DIFF" -eq 0 ] && [ "$MUT_REFUSED" -eq 0 ]; then
    say "FAIL — the mutant moved NOTHING and refused nothing. hex's stripPrefix is the"
    say "       payload composition every shard key is derived through, so emptying it"
    say "       must either re-key most of the corpus or stop the producer. A diff that"
    say "       can see neither cannot see anything, and the zero above means the"
    say "       comparison is broken rather than that the layout is unchanged."
    exit 1
  fi
  say "MUTANT IS LIVE — $MUT_DIFF differing line(s) of $BASE_OBJECTS objects, plus"
  say "       $MUT_REFUSED tree(s) the mutant could not publish at all, when ONE field of"
  say "       the shard rule moves. The zero above is therefore a measurement."
fi

say ""
if [ "$BASE_DIFF" -eq 0 ]; then
  say "PASS — $BASE_OBJECTS objects across $(echo "$TREES" | grep -c .) trees, 0 differing"
  say "       manifest lines. Every path and every byte the producers publish is what"
  say "       $BEFORE_SHA published (Publishing-And-Caching.md §6.1, §6.2)."
  exit 0
fi
say "DIFFERS — $BASE_DIFF differing manifest line(s) of $BASE_OBJECTS objects. The"
say "       published key layout MOVED relative to $BEFORE_SHA. Per-tree counts are"
say "       above and the manifests are $WORK/manifest-{before,after}-<tree>.txt;"
say "       \`diff\` them to see which paths."
exit 1
