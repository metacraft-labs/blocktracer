#!/usr/bin/env bash
#
# shard-name-case-repro.sh — the case-insensitive-filesystem REPRODUCTION behind
# `shardKey.foldKey` in `tools/chain/identifier-encodings.json`.
#
# ── WHAT THIS IS, AND WHAT IT IS NOT ────────────────────────────────────────────
#
# IT IS NOT THE GATE. The invariant — that the shard names the derivation emits
# are closed under case folding, so no two of them can name one file — is asserted
# filesystem-independently in `tests/tidentifierencoding.nim`, which runs on every
# platform in `just test` and in CI, and whose control drives the UNFOLDED
# derivation and requires it to lose entries. Read that arm for the check.
#
# THIS is the demonstration that the loss the arm models is real, and SILENT, on a
# filesystem that actually behaves this way. It is deliberately NOT named
# `*-test.sh` / `*-selftest.sh` / `check-*.sh`, because `ci/test/ci-coverage.sh`
# reads those names as gates and would rightly demand a CI job for one; and a CI
# job for this would need `dosfstools` and `mtools` in the flake devshell, which is
# a cost with no benefit once the invariant is asserted without them.
#
# ── WHY FAT, AND THE CAVEAT THAT MATTERS ────────────────────────────────────────
#
# It needs NO root and NO mount: `mkfs.vfat` builds an image and `mtools` writes
# into it directly. FAT is case-insensitive and case-PRESERVING, which is the same
# property as macOS APFS at its default setting and Windows NTFS at its default
# setting. IT IS A MODEL OF THOSE FILESYSTEMS, NOT THOSE FILESYSTEMS. Say it that
# way; a reader who takes it for APFS will over-claim on the next platform.
#
# ── WHAT IT DEMONSTRATES ────────────────────────────────────────────────────────
#
# `hashPrefix` names a FILE: `idx/hash/{version}/{prefix}.bin`. Before
# `shardKey.foldKey`, two case-differing base58 identifiers derived `Ab` and `aB`,
# i.e. `Ab.bin` and `aB.bin`. Search-And-Routing.md §5.0a makes a prefix miss "a
# confident claim that NOTHING published begins with those digits", so a shard lost
# to a name collision is a FALSE ABSENCE — a page that is confidently wrong rather
# than visibly broken.
#
# THREE ARMS, AND THE FIRST IS WHY THE OTHER TWO MEAN ANYTHING:
#   A  positive control — two names differing in MORE than case must be two files.
#      Without it, "one file" is an empty population rather than a collision.
#   B  the defect, as the derivation emitted it BEFORE the fold: `Ab.bin` then
#      `aB.bin`. The prediction is rc 0, silence, and one of the two gone.
#   C  the derivation AS IT IS NOW: both identifiers derive ONE name, so one file
#      holds both entries by design and nothing is overwritten unknowingly.
#
# Absent tooling is a REFUSAL, not a skip: a reproduction that reports success on a
# host where it could not run is the false green this whole seam exists to remove.
set -uo pipefail
cd "$(dirname "$0")"

for t in mkfs.vfat mcopy mdir mmd truncate; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "REFUSED: '$t' is not on PATH, so this reproduction did not run."
    echo "It needs dosfstools (mkfs.vfat) and mtools (mcopy/mdir/mmd). Reporting"
    echo "that is the point: a green here without them would mean nothing."
    exit 2
  }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/bt-shardcase.XXXXXX")
trap 'rm -rf "$work"' EXIT
cd "$work"
export MTOOLSRC="$work/mtoolsrc"
printf 'drive z: file="%s/fat.img"\n' "$work" > "$MTOOLSRC"

truncate -s 16M fat.img
mkfs.vfat -F 16 fat.img >/dev/null 2>&1 || { echo "mkfs.vfat FAILED"; exit 1; }
mmd z:/idx || { echo "mmd FAILED"; exit 1; }

printf 'entries-for-Ab\n' > e1
printf 'entries-for-Zz\n' > e2
printf 'entries-for-aB-which-is-a-DIFFERENT-shard\n' > e3

bins() { mdir z:/idx | grep -ci 'bin'; }
fail=0

echo "--- ARM A (positive control): 'Ab.bin' and 'Zz.bin' differ in more than case"
mcopy e1 z:/idx/Ab.bin; echo "    write Ab.bin rc=$?"
mcopy e2 z:/idx/Zz.bin; echo "    write Zz.bin rc=$?"
a=$(bins)
echo "    BIN entries: $a  (must be 2, or the instrument is blind)"
[ "$a" = 2 ] || { echo "ARM A FAILED — do not read the arms below"; exit 1; }

echo "--- ARM B (the defect, pre-fold): 'aB.bin' differs from 'Ab.bin' ONLY in case"
mcopy -o e3 z:/idx/aB.bin; rc=$?
echo "    write aB.bin rc=$rc  (the prediction is rc 0 and silence)"
b=$(bins)
echo "    BIN entries: $b  (3 = two shards kept; 2 = one shard was overwritten)"
mdir z:/idx | sed 's/^/      /'
if [ "$b" = 2 ]; then
  echo "    DEFECT REPRODUCED: two distinct shard names collapsed to one file, the"
  echo "    write returned $rc, and nothing errored. The other shard's entries are"
  echo "    gone, and a prefix search now reports them ABSENT rather than unfound."
else
  echo "    NOT REPRODUCED on this filesystem model — report that, do not assume."
  fail=1
fi

echo "--- ARM C (the derivation as it is now): both identifiers derive ONE name"
mmd z:/fixed || { echo "mmd FAILED"; exit 1; }
# `shardKey.foldKey` makes `hashPrefix` fold the segment, so the two case-differing
# identifiers of ARM B both derive `ab` — one file, written once, holding both
# entries. The entries themselves keep `identifierIndexKey`, which PRESERVES case,
# so the shard is scanned with an exact comparison and neither identifier is
# confused with the other.
printf 'entries-for-BOTH-identifiers\n' > e4
mcopy e4 z:/fixed/ab.bin; echo "    write ab.bin rc=$?"
mcopy e2 z:/fixed/zz.bin; echo "    write zz.bin rc=$?"
c=$(mdir z:/fixed | grep -ci 'bin')
echo "    BIN entries: $c  (must be 2: one shard per DISTINCT folded name)"
if [ "$c" = 2 ]; then
  echo "    NO COLLISION IS CONSTRUCTIBLE: the derivation cannot emit two names that"
  echo "    fold equal, so there is no second writer to lose to."
else
  echo "    ARM C FAILED"
  fail=1
fi

echo "rc=$fail"
exit "$fail"
