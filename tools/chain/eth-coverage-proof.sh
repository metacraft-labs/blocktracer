#!/usr/bin/env bash
# eth-coverage-proof.sh — DOES PUBLISHING RANGE AFTER RANGE INTO ONE STORE KEEP EVERY
# HEIGHT LISTED, AND IS THE DEFECT IT USED TO HAVE STILL DEMONSTRABLE?
#
#   tools/chain/eth-coverage-proof.sh [--a .eth-range/tree] [--b .eth-range/tree-interrupt]
#                                     [--overlap DIR] [--work .eth-coverage-proof] [--keep]
#
# Normally reached through `just eth-coverage-proof`.
#
# ── WHAT THIS ANSWERS ─────────────────────────────────────────────────────────────────
#
# `eth-publish-proof.sh` proved the upload of ONE range: compose, idempotent, delta,
# refresh, order, encoding, lease, audit. Every one of those is a statement about a single
# cycle. A deployed follower publishes range after range into one store, and that
# COMPOSITION was never measured. It was, and it lost coverage silently — see arm 1.
#
# This script is that measurement plus its fix, kept runnable, with the defect still
# reachable on demand. `tools/chain/ingest-range.mjs --no-merge` is the precedent: a fix
# that can still demonstrate the bug is worth more than one that cannot, because an arm
# that cannot fail is indistinguishable from an arm that is not checking.
#
# ── THERE ARE TWO DEFECT SHAPES AND THEY DIFFER IN DETECTABILITY ──────────────────────
#
# This is the finding worth more than the fix, so it is an arm of its own.
#
#   SHAPE 1 — SAME GENERATION, SINGLETONS COLLIDE (arm 1). Publish range A then range B at
#   generation "1". `d/{chain}/g/{gen}/**` is `ocGenMap` / `ocGenRoot`, i.e.
#   `stKeyExistence` — present implies skip — so B's height map, block list, summary and
#   root are all DECLINED as already-present, while `current.json` is `stUnconditional` and
#   moves the head anyway. `verify-published` catches this: POINTER fails, because the
#   pointer leads its own height map.
#
#   SHAPE 2 — FRESH GENERATION, PER-RANGE MAP (arm 2). Give each range its own generation
#   id but still ingest only that range's snapshot. The maps are written (the key is new),
#   and they are self-consistent: the pointer names a head its map contains. **POINTER
#   PASSES.** The store has quietly dropped every earlier range from the index — the block
#   objects are all still there, fetchable by hash, listed nowhere.
#
# Shape 2 is the worse one, and before this campaign it was UNDETECTABLE. The only check
# that sees it is LEDGER, which compares the ledger's served heights against the published
# map exhaustively — and LEDGER is UNRUNNABLE without a coverage ledger, which this chain
# had none of. A detector that cannot run is indistinguishable from a detector that passes.
# So the coverage ledger is not merely the fix's bookkeeping: it is what makes the existing
# audit able to see the quieter half of the defect at all. Arm 2 is the arm that documents
# that hole, by reproducing shape 2 and showing POINTER green over it.
#
# ── THE ARMS ──────────────────────────────────────────────────────────────────────────
#
#   0 SUBJECTS   the captures and binaries exist — otherwise exit 2, nothing measured.
#   1 SHAPE 1    reproduced: 4 objects skipped, named; POINTER fails by name; the unlisted
#                heights are listed.
#   2 SHAPE 2    reproduced: POINTER **passes** over a map missing half the chain, and
#                LEDGER is the only check that fails. The detector hole, measured.
#   3 FIX A->B   the union at a derived generation: 6 heights mapped, POINTER passes,
#                LEDGER runs and passes, CENSUS agrees, the pointer is written LAST.
#   4 FIX B->A   out of order converges to the SAME generation id and the same map.
#   5 OVERLAP    26157392-94 after 26157390-92 and 26157393-95: deduped by height, not
#                double-counted, and the overlap is reported rather than hidden.
#   6 IDEMPOTENT re-filing a range already covered uploads ZERO and moves no byte.
#
# ── NO MOCKS ──────────────────────────────────────────────────────────────────────────
#
# There are none. The subjects are real `capture-eth-range.mjs` captures of Ethereum
# mainnet, the ingest, publisher and auditor are the shipping binaries driven by their
# documented flags, and the store is a real directory whose `putIfAbsent` is a genuine
# `O_CREAT|O_EXCL`. No credential is held and none should ever be given one: `--backend
# local` is the whole of it.
#
# ── EVERY RC IS THE COMMAND'S OWN, NEVER A PIPELINE'S ────────────────────────────────
#
# `just export | tail` once reported 0 while the recipe had failed. So no rc read in this
# file comes from the tail of a pipeline: a command is run, redirected to a file, and `$?`
# read on the next line. Where a count must be extracted, `expect_match` refuses a count of
# zero rather than letting it satisfy a comparison — the write-order checker in this
# repository once matched ZERO renames and cheerfully reported 0 inversions.

set -u

A=".eth-range/tree"
B=".eth-range/tree-interrupt"
OVERLAP=""
WORK=".eth-coverage-proof"
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --a)       A="$2"; shift 2 ;;
    --b)       B="$2"; shift 2 ;;
    --overlap) OVERLAP="$2"; shift 2 ;;
    --work)    WORK="$2"; shift 2 ;;
    --keep)    KEEP=1; shift ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root" || exit 2

CHAIN="ethereum-mainnet"

# ── ARM 0: REFUSE RATHER THAN PASS WHEN THERE IS NOTHING TO MEASURE ────────────────────
#
# The captures need the network and the EVM recorder, so this script's subjects may simply
# not exist on a given machine. Exiting 0 then would be the empty-set pass: seven properties
# proved over no objects. An absent subject is exit 2, naming how to make one.
for d in "$A" "$B"; do
  if [ ! -f "$d/snapshot.json" ]; then
    cat >&2 <<EOF
no snapshot tree at '$d' (expected '$d/snapshot.json').

This script proves that publishing range after range keeps every height listed, over REAL
captures, so it needs two adjacent ones. Produce them with the range capture, which needs
an archive endpoint and the recorder binary:

    just eth-range <recorder-bin> <recorder-commit> --from 26157390 --to 26157392
    mv .eth-range/tree .eth-range/tree-A
    just eth-range <recorder-bin> <recorder-commit> --from 26157393 --to 26157395
    tools/chain/eth-coverage-proof.sh --a .eth-range/tree-A --b .eth-range/tree

Exiting 2 rather than 0: a run with no subject would report properties proved over nothing.
EOF
    exit 2
  fi
done

command -v node >/dev/null 2>&1 || { echo "REFUSING: node is not on PATH." >&2; exit 2; }
command -v strace >/dev/null 2>&1 || {
  echo "REFUSING: 'strace' is not on PATH. Arm 3 reads the publisher's write order out of" \
       "the kernel's rename record, so a run without strace would silently drop the one" \
       "claim that cannot be inferred from the publisher's own output." >&2
  exit 2
}

rm -rf "$WORK"
mkdir -p "$WORK/bin"
# ABSOLUTE FROM HERE ON, for the reason `eth-publish-proof.sh` records: `strace` logs the
# path the process actually passed to `rename`, so a relative `--dest` would put relative
# paths in the log and every key extracted from it would be measured against the wrong root.
WORK="$(cd "$WORK" && pwd)"
BIN="$WORK/bin"
A="$(cd "$A" && pwd)"
B="$(cd "$B" && pwd)"
[ -n "$OVERLAP" ] && OVERLAP="$(cd "$OVERLAP" && pwd)"

FAILURES=0
PASSES=0
NOMATCH=0

say()  { printf '\n== %s\n' "$*"; }
check() { # check <ok:0|1> <name> [detail]
  if [ "$1" = "0" ]; then PASSES=$((PASSES+1)); printf '  PASS  %s%s\n' "$2" "${3:+  — $3}"
  else FAILURES=$((FAILURES+1)); printf '  FAIL  %s%s\n' "$2" "${3:+  — $3}"; fi
}

# ── A COUNT OF ZERO IS A REFUSAL, NOT A PASS ──────────────────────────────────────────
#
# Every arm below that greps for a sentence, or counts heights in a map, is asking a
# question whose answer must be non-empty for the arm to mean anything. A `grep -c` that
# returns 0 would otherwise satisfy "no unexpected findings" by having read nothing, and a
# height extractor that matched nothing would satisfy "no height is missing" the same way.
# This repository has shipped that exact mistake twice, so it is a function and every
# must-match site goes through it.
expect_match() { # expect_match <count> <what-was-being-matched>
  if [ "${1:-0}" -lt 1 ] 2>/dev/null || [ -z "${1:-}" ]; then
    NOMATCH=$((NOMATCH+1)); FAILURES=$((FAILURES+1))
    printf '  REFUSE  the pattern for "%s" matched NOTHING. A zero match cannot be read\n' "$2"
    printf '          as a zero finding — this arm measured nothing and is a FAILURE, not\n'
    printf '          a pass.\n'
    return 1
  fi
  return 0
}

# ── ARM 0b: THE GUARD IS ARMED, BECAUSE AN UNARMED GUARD IS A NO-OP ───────────────────
#
# `expect_match` is the only thing standing between this script and the failure mode its
# header names: a pattern that matches nothing satisfying the assertion it guards. If that
# function were ever edited into a no-op — a stray `return 0`, an inverted test — every arm
# below would stay green and the script would be measuring nothing. That is not a
# hypothetical in this repository: the write-order checker matched ZERO renames and
# cheerfully reported 0 inversions, and `just export | tail` reported 0 over a failed
# recipe.
#
# So the guard is exercised before it is relied on, in both directions, in a SUBSHELL so
# the control's own bookkeeping does not land in the run's counters.
say "ARM 0 — the harness's own zero-match guard is armed in both directions"
guard_zero_out=$( (expect_match 0 "a deliberately empty control pattern") 2>&1 )
guard_zero_rc=$?
check "$([ "$guard_zero_rc" != "0" ] && echo 0 || echo 1)" \
  "expect_match REFUSES a count of zero" "returned $guard_zero_rc"
case "$guard_zero_out" in
  *REFUSE*) said=0 ;;
  *)        said=1 ;;
esac
check "$said" "…and says REFUSE rather than failing quietly" \
  "$(printf '%s' "$guard_zero_out" | head -1 | sed 's/^ *//')"
guard_empty_rc=0
( expect_match "" "an empty string, which is what a failed sed yields" ) >/dev/null 2>&1 \
  || guard_empty_rc=$?
check "$([ "$guard_empty_rc" != "0" ] && echo 0 || echo 1)" \
  "…and refuses an EMPTY string too, which is what a failed sed actually yields" \
  "returned $guard_empty_rc"
guard_one_rc=0
( expect_match 1 "a control pattern that matched once" ) >/dev/null 2>&1 || guard_one_rc=$?
check "$guard_one_rc" "…and admits a count of one, so it is not refusing everything" \
  "returned $guard_one_rc"

say "building the three binaries this drives, from this working tree"
nim c --hints:off -d:release --path:src -o:"$BIN/blocktracer-chain-ingest" \
  src/blocktracer_chain_ingest.nim > "$WORK/build-ingest.log" 2>&1
rc=$?; [ $rc -eq 0 ] || { echo "ingest build failed (rc=$rc), see $WORK/build-ingest.log" >&2; exit 2; }
nim c --hints:off -d:release --path:src -o:"$BIN/blocktracer-publish" \
  src/blocktracer_publish.nim > "$WORK/build-publish.log" 2>&1
rc=$?; [ $rc -eq 0 ] || { echo "publish build failed (rc=$rc), see $WORK/build-publish.log" >&2; exit 2; }
nim c --hints:off -d:release --path:src -o:"$BIN/blocktracer-verify-published" \
  src/blocktracer_verify_published.nim > "$WORK/build-verify.log" 2>&1
rc=$?; [ $rc -eq 0 ] || { echo "verify build failed (rc=$rc), see $WORK/build-verify.log" >&2; exit 2; }
echo "  built: chain-ingest, publish, verify-published"

# ---------------------------------------------------------------------------
# helpers over a published store
# ---------------------------------------------------------------------------

# The live generation, read from the pointer the clients read.
live_gen() { # live_gen <store>
  sed -n 's/^ *"generation": *"\([^"]*\)".*/\1/p' "$1/d/$CHAIN/current.json" | head -1
}
head_height() { # head_height <store>
  node -e 'const j=require("fs").readFileSync(process.argv[1],"utf8");
           process.stdout.write(String(JSON.parse(j).head.height))' \
    "$1/d/$CHAIN/current.json"
}
# Every height the live generation's height map lists, one per line, ascending. Read
# through the generation ROOT rather than by guessing the path, because the root is what
# names the map and a hardcoded path would stop measuring the day the map shards.
mapped_heights() { # mapped_heights <store>
  local store="$1" gen
  gen="$(live_gen "$store")"
  [ -n "$gen" ] || return 1
  node -e '
    const fs = require("fs"), path = require("path");
    const [store, chain, gen] = process.argv.slice(1);
    const root = JSON.parse(fs.readFileSync(
      path.join(store, "d", chain, "g", gen, "root.json"), "utf8"));
    const out = [];
    for (const k of root.maps.height) {
      const m = JSON.parse(fs.readFileSync(path.join(store, k), "utf8"));
      for (const h of Object.keys(m.heights)) out.push(Number(h));
    }
    out.sort((a, b) => a - b);
    process.stdout.write(out.join("\n") + (out.length ? "\n" : ""));
  ' "$store" "$CHAIN" "$gen"
}
# How many hashes the live generation's block list holds, and how many are DISTINCT. The
# pair is the double-counting claim: a union that appended instead of deduping would show
# them apart.
block_list_counts() { # block_list_counts <store>  ->  "<total> <distinct>"
  local store="$1" gen
  gen="$(live_gen "$store")"
  node -e '
    const fs = require("fs"), path = require("path");
    const [store, chain, gen] = process.argv.slice(1);
    const root = JSON.parse(fs.readFileSync(
      path.join(store, "d", chain, "g", gen, "root.json"), "utf8"));
    let all = [];
    for (const k of root.maps.blocks) {
      all = all.concat(JSON.parse(fs.readFileSync(path.join(store, k), "utf8")).blocks);
    }
    process.stdout.write(`${all.length} ${new Set(all).size}`);
  ' "$store" "$CHAIN" "$gen"
}
manifest() { # manifest <store> <out> — sha256 of every object, lease excluded
  ( cd "$1" && find . -type f -not -path './_leases/*' -print0 | xargs -0 -r sha256sum ) \
    | sort -k2 > "$2"
}

# One `eth-ingest-range.mjs` run. Writes its own log; returns ITS rc, not a pipeline's.
ingest() { # ingest <state> <store> <snapshot> <log> [extra flags…]
  local state="$1" store="$2" snap="$3" log="$4"; shift 4
  node tools/chain/eth-ingest-range.mjs \
    --snapshot "$snap" --state "$state" --dest "$store" \
    --ingest-bin "$BIN/blocktracer-chain-ingest" \
    --publish-bin "$BIN/blocktracer-publish" \
    "$@" > "$log" 2>&1
  return $?
}
field() { # field <label> <log> — a line the publisher printed, via the tool's own echo
  sed -n "s/^.*$1 *\([0-9][0-9]*\).*$/\1/p" "$2" | head -1
}
audit() { # audit <store> <tree> <out> [extra flags…]
  local store="$1" tree="$2" out="$3"; shift 3
  "$BIN/blocktracer-verify-published" --backend local --dest "$store" --tree "$tree" \
    --allow-unrunnable CACHE "$@" > "$out" 2>&1
  return $?
}
# Did a named check pass / fail? Read off the audit's own report lines.
audit_state() { # audit_state <out> <CHECKID>  -> PASS|FAIL|UNRUNNABLE|MISSING
  local s
  s=$(sed -n "s/^ *\(PASS\|FAIL\|UNRUNNABLE\) *$2 .*/\1/p" "$1" | head -1)
  printf '%s' "${s:-MISSING}"
}

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 1 — SHAPE 1: the same generation, and the four singletons that collide
# ═══════════════════════════════════════════════════════════════════════════════════════
say "ARM 1 — SHAPE 1 REPRODUCED: two ranges at one generation, four objects skipped"
S1="$WORK/shape1"; mkdir -p "$S1"
ingest "$S1/state" "$S1/store" "$A" "$S1/a.log" --no-merge --generation 1
rc1a=$?
ingest "$S1/state" "$S1/store" "$B" "$S1/b.log" --no-merge --generation 1
rc1b=$?
check "$rc1a" "cycle A exits 0" "rc=$rc1a"
check "$rc1b" "cycle B exits 0 — nothing fails, which is the defect" "rc=$rc1b"

SK=$(field "skipped" "$S1/b.log")
expect_match "${SK:-0}" "the publisher's 'content skipped' figure in cycle B" && \
check "$([ "$SK" = "4" ] && echo 0 || echo 1)" \
  "cycle B skipped exactly 4 content objects" "skipped=$SK"

# WHICH four, computed by intersecting the two ingested trees rather than pattern-matched
# against a path shape. A `grep '/g/1/'` here would be a second copy of `classOf` in bash.
TA="$S1/state-a-tree"; TB="$S1/state-b-tree"
# Both trees are rebuilt from the filed ranges so both are on disk at once; the live
# `state/tree` only ever holds the most recent.
"$BIN/blocktracer-chain-ingest" --snapshot "$S1/state/ranges/026157390-026157392" \
  --out "$TA" --generation 1 > "$S1/re-ingest-a.log" 2>&1
rcA=$?
"$BIN/blocktracer-chain-ingest" --snapshot "$S1/state/ranges/026157393-026157395" \
  --out "$TB" --generation 1 > "$S1/re-ingest-b.log" 2>&1
rcB=$?
if [ $rcA -eq 0 ] && [ $rcB -eq 0 ]; then
  comm -12 <(cd "$TA" && find . -type f | sed 's|^\./||' | sort) \
           <(cd "$TB" && find . -type f | sed 's|^\./||' | sort) > "$S1/collide.txt"
  : > "$S1/collide-differ.txt"
  while read -r k; do
    if ! cmp -s "$TA/$k" "$TB/$k"; then printf '%s\n' "$k" >> "$S1/collide-differ.txt"; fi
  done < "$S1/collide.txt"
  NGEN=$(grep -c "^d/$CHAIN/g/1/" "$S1/collide-differ.txt")
  expect_match "${NGEN:-0}" "generation objects that collide AND differ between the two trees" && \
  check "$([ "$NGEN" = "4" ] && echo 0 || echo 1)" \
    "exactly 4 generation objects collide with different bytes" "$NGEN found"
  printf '        the colliding generation objects, computed not guessed:\n'
  sed -n "s|^d/$CHAIN/g/1/|          d/$CHAIN/g/1/|p" "$S1/collide-differ.txt"
else
  check 1 "the two ranges re-ingest for the collision comparison" "rc=$rcA/$rcB"
fi

# THE DETECTOR, BY NAME
audit "$S1/store" "$TB" "$S1/audit.out" --allow-unrunnable LEDGER
rcAudit1=$?
check "$([ "$rcAudit1" != "0" ] && echo 0 || echo 1)" \
  "blocktracer-verify-published FAILS over the store" "rc=$rcAudit1"
check "$([ "$(audit_state "$S1/audit.out" POINTER)" = "FAIL" ] && echo 0 || echo 1)" \
  "it is POINTER that fails" "POINTER=$(audit_state "$S1/audit.out" POINTER)"
NAMED=$(grep -c "advertising 3 height(s) of data that the generation it names does not map" \
        "$S1/audit.out")
expect_match "${NAMED:-0}" "the detector's own sentence about the unlisted heights" && \
check 0 "the detector names the defect in its own words" "$(
  sed -n 's/^ *! chain .*advertises head height \([0-9]*\).*map.s highest is \([0-9]*\).*/head \1, map stops at \2/p' \
    "$S1/audit.out" | head -1)"
printf '        verbatim:\n'
sed -n 's/^ *! \(chain .*does not map\.\)$/          \1/p' "$S1/audit.out"

# …and the unlisted heights, listed.
mapped_heights "$S1/store" > "$S1/mapped.txt"
NM=$(wc -l < "$S1/mapped.txt")
expect_match "${NM:-0}" "heights in the live generation's height map" && {
  HH=$(head_height "$S1/store")
  UNLISTED=""
  for h in 26157390 26157391 26157392 26157393 26157394 26157395; do
    grep -qx "$h" "$S1/mapped.txt" || UNLISTED="$UNLISTED $h"
  done
  NU=$(printf '%s' "$UNLISTED" | wc -w)
  check "$([ "$NU" = "3" ] && echo 0 || echo 1)" \
    "3 of the 6 captured heights are unlisted while the pointer advertises the newest" \
    "head=$HH, map holds $NM ($(tr '\n' ' ' < "$S1/mapped.txt")), unlisted:$UNLISTED"
}

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 2 — SHAPE 2: the quiet one. POINTER passes. Only LEDGER sees it.
# ═══════════════════════════════════════════════════════════════════════════════════════
say "ARM 2 — SHAPE 2 REPRODUCED: a fresh generation per range, and POINTER goes GREEN"
S2="$WORK/shape2"; mkdir -p "$S2"
ingest "$S2/state" "$S2/store" "$A" "$S2/a.log" --no-merge
rc2a=$?
ingest "$S2/state" "$S2/store" "$B" "$S2/b.log" --no-merge
rc2b=$?
check "$rc2a" "cycle A exits 0" "rc=$rc2a"
check "$rc2b" "cycle B exits 0" "rc=$rc2b"

mapped_heights "$S2/store" > "$S2/mapped.txt"
NM2=$(wc -l < "$S2/mapped.txt")
expect_match "${NM2:-0}" "heights in the live generation's height map" && \
check "$([ "$NM2" = "3" ] && echo 0 || echo 1)" \
  "the live generation maps only the NEWEST range's 3 heights" \
  "map holds $NM2: $(tr '\n' ' ' < "$S2/mapped.txt")"

# Range A's block objects are still in the store — present, fetchable, listed nowhere.
# That is what makes this shape quiet: nothing is missing, only unreferenced.
AHASH=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1]+"/snapshot.json","utf8"));
                 const b=s.blocks.find(x=>x.number===26157390); process.stdout.write(b?b.hash:"")' "$A")
expect_match "$([ -n "$AHASH" ] && echo 1 || echo 0)" "range A's block 26157390 hash in its snapshot" && {
  if [ -f "$S2/store/d/$CHAIN/block/$AHASH.json" ]; then present=0; else present=1; fi
  check "$present" "range A's block object IS still in the store, just unlisted" \
    "d/$CHAIN/block/${AHASH:0:14}….json present, height 26157390 in no map"
}

# THE HOLE: the audit without a ledger passes POINTER over this.
audit "$S2/store" "$S2/state/tree" "$S2/audit-noledger.out" --allow-unrunnable LEDGER
rc2n=$?
P2=$(audit_state "$S2/audit-noledger.out" POINTER)
check "$([ "$P2" = "PASS" ] && echo 0 || echo 1)" \
  "POINTER PASSES over a store that has dropped half the chain — the detector hole" \
  "POINTER=$P2 (the pointer agrees with its own map; the map is simply short)"
L2n=$(audit_state "$S2/audit-noledger.out" LEDGER)
check "$([ "$L2n" = "UNRUNNABLE" ] && echo 0 || echo 1)" \
  "and the only check that could see it is UNRUNNABLE without a ledger" "LEDGER=$L2n"

# …and WITH the ledger this tool writes, the same store is caught.
audit "$S2/store" "$S2/state/tree" "$S2/audit-ledger.out" --ledger "$S2/state/coverage.json"
rc2l=$?
L2=$(audit_state "$S2/audit-ledger.out" LEDGER)
check "$([ "$L2" = "FAIL" ] && echo 0 || echo 1)" \
  "given the coverage ledger, LEDGER catches shape 2 exhaustively" "LEDGER=$L2"
NAMED2=$(grep -c "height(s) were ingested and are not in the map" "$S2/audit-ledger.out")
expect_match "${NAMED2:-0}" "the LEDGER check's own sentence about ingested-but-unmapped heights" && \
check 0 "and names which heights, over the whole range rather than a sample" ""
printf '        verbatim:\n'
sed -n 's/^ *! \(chain .*not a sample\.\)$/          \1/p' "$S2/audit-ledger.out"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 3 — THE FIX, A then B
# ═══════════════════════════════════════════════════════════════════════════════════════
say "ARM 3 — THE FIX: the union over the ledger, at a generation derived from its content"
F="$WORK/fix"; mkdir -p "$F"
ingest "$F/state" "$F/store" "$A" "$F/a.log"
rc3a=$?
check "$rc3a" "cycle A exits 0" "rc=$rc3a"
GEN_A=$(live_gen "$F/store")

# The second cycle under strace, so arm 3's write-order claim is read out of the KERNEL's
# rename record rather than out of the publisher's own report.
node tools/chain/eth-ingest-range.mjs \
  --snapshot "$B" --state "$F/state" --dest "$F/store" \
  --ingest-bin "$BIN/blocktracer-chain-ingest" \
  --publish-bin "$BIN/blocktracer-publish" --no-publish > "$F/b-ingest.log" 2>&1
rc3i=$?
check "$rc3i" "cycle B files and ingests the union" "rc=$rc3i"
strace -f -qq -e trace=rename -o "$F/trace.log" \
  "$BIN/blocktracer-publish" --tree "$F/state/tree" --backend local --dest "$F/store" \
  --writer coverage-proof-3 > "$F/b-publish.log" 2>&1
rc3p=$?
check "$rc3p" "cycle B publishes the union" "rc=$rc3p"

GEN_B=$(live_gen "$F/store")
check "$([ -n "$GEN_B" ] && [ "$GEN_B" != "$GEN_A" ] && echo 0 || echo 1)" \
  "new content got a NEW generation id, derived from what it contains" \
  "A published '$GEN_A', B published '$GEN_B'"

mapped_heights "$F/store" > "$F/mapped.txt"
NM3=$(wc -l < "$F/mapped.txt")
expect_match "${NM3:-0}" "heights in the live generation's height map" && {
  MISSING=""
  for h in 26157390 26157391 26157392 26157393 26157394 26157395; do
    grep -qx "$h" "$F/mapped.txt" || MISSING="$MISSING $h"
  done
  check "$([ "$NM3" = "6" ] && [ -z "$MISSING" ] && echo 0 || echo 1)" \
    "the height map holds all SIX captured heights" \
    "map holds $NM3: $(tr '\n' ' ' < "$F/mapped.txt")${MISSING:+, MISSING:$MISSING}"
}
HH3=$(head_height "$F/store")
check "$([ "$HH3" = "26157395" ] && echo 0 || echo 1)" \
  "and the pointer advertises a head the map contains" "head=$HH3"

read -r BT BD <<<"$(block_list_counts "$F/store")"
expect_match "${BT:-0}" "hashes in the live generation's block list" && \
check "$([ "$BT" = "6" ] && [ "$BD" = "6" ] && echo 0 || echo 1)" \
  "the block list holds 6 hashes and 6 distinct ones" "total=$BT distinct=$BD"

# THE POINTER IS WRITTEN LAST, out of the kernel's record. The store root has to be
# stripped so the keys compare against the right root.
grep 'rename(' "$F/trace.log" | awk -F'"' '{print $4}' | sed "s|^$F/store/||" > "$F/writes.txt"
NW=$(wc -l < "$F/writes.txt")
expect_match "${NW:-0}" "rename() calls in the publisher's strace log" && {
  LAST=$(tail -1 "$F/writes.txt")
  check "$([ "$LAST" = "d/$CHAIN/current.json" ] && echo 0 || echo 1)" \
    "the LAST write of the cycle is the per-chain pointer" "$NW write(s), last = $LAST"
  # Armed by a mutant: the same log with the flip moved first MUST be refused, so a
  # checker that always answers "last" cannot pass this.
  { printf '%s\n' "d/$CHAIN/current.json"; grep -vx "d/$CHAIN/current.json" "$F/writes.txt"; } \
    > "$F/writes-mutant.txt"
  MLAST=$(tail -1 "$F/writes-mutant.txt")
  check "$([ "$MLAST" != "d/$CHAIN/current.json" ] && echo 0 || echo 1)" \
    "…and the mutant log with the flip moved FIRST is refused" "mutant's last = $MLAST"
}

# THE AUDIT: every check it passed before, plus the one it failed, plus LEDGER now runnable.
audit "$F/store" "$F/state/tree" "$F/audit.out" --ledger "$F/state/coverage.json"
rc3v=$?
for id in INSTRUMENT REGISTRY POINTER LEDGER RANGE CENSUS; do
  st=$(audit_state "$F/audit.out" "$id")
  check "$([ "$st" = "PASS" ] && echo 0 || echo 1)" "audit $id passes" "$st"
done
# PROFILE is the PINNED producer/auditor `historyFloor` disagreement. It predates this
# work, it fails identically for the committed Aztec capture in the opposite direction, and
# `eth-publish-proof.sh` arm 8 pins it by name for the same reason: pinning keeps every
# other finding live, skipping would hide the next one.
PROF=$(audit_state "$F/audit.out" PROFILE)
check "$([ "$PROF" = "FAIL" ] && echo 0 || echo 1)" \
  "PROFILE is the pinned historyFloor disagreement, still the ONLY finding" "$PROF"
UNKNOWN=$(grep -E '^ *! ' "$F/audit.out" | grep -v 'historyFloor' \
          | grep -v 'serves no response headers' || true)
check "$([ -z "$UNKNOWN" ] && echo 0 || echo 1)" \
  "the audit reports no finding beyond the pinned one" \
  "$(printf '%s' "${UNKNOWN:-none}" | head -1)"

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 4 — OUT OF ORDER: B then A
# ═══════════════════════════════════════════════════════════════════════════════════════
say "ARM 4 — OUT OF ORDER: a daemon does not always get B after A"
R="$WORK/rev"; mkdir -p "$R"
ingest "$R/state" "$R/store" "$B" "$R/b.log"
rc4b=$?
ingest "$R/state" "$R/store" "$A" "$R/a.log"
rc4a=$?
check "$rc4b" "cycle B (the LATER range, first) exits 0" "rc=$rc4b"
check "$rc4a" "cycle A (the EARLIER range, second) exits 0" "rc=$rc4a"

mapped_heights "$R/store" > "$R/mapped.txt"
NM4=$(wc -l < "$R/mapped.txt")
expect_match "${NM4:-0}" "heights in the live generation's height map" && \
check "$([ "$NM4" = "6" ] && echo 0 || echo 1)" \
  "the height map still holds all six heights" "map holds $NM4"
GEN_R=$(live_gen "$R/store")
# THE GENERATION ID IS ORDER-INDEPENDENT, which is what makes the derivation a function of
# the COVERED SET rather than of the publish history. Two daemons that saw the same ranges
# in different orders converge on one generation and therefore on one set of map objects.
check "$([ "$GEN_R" = "$GEN_B" ] && echo 0 || echo 1)" \
  "B->A converges on the SAME generation id as A->B" "'$GEN_R' vs '$GEN_B'"
diff -q <(sort "$R/mapped.txt") <(sort "$F/mapped.txt") > /dev/null 2>&1
check "$?" "…and on the same set of mapped heights" ""

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 5 — OVERLAP
# ═══════════════════════════════════════════════════════════════════════════════════════
say "ARM 5 — OVERLAP: a range that re-covers heights already covered"
if [ -z "$OVERLAP" ]; then
  echo "  SKIPPED — no --overlap <dir> given. This arm needs a third capture that"
  echo "  overlaps the first two (26157392-26157394). It is a SKIP and not a pass:"
  echo "  nothing about overlap is claimed by this run."
  OVERLAP_SKIPPED=1
else
  OVERLAP_SKIPPED=0
  O="$WORK/overlap"; mkdir -p "$O"
  ingest "$O/state" "$O/store" "$A" "$O/a.log"; rc5a=$?
  ingest "$O/state" "$O/store" "$B" "$O/b.log"; rc5b=$?
  ingest "$O/state" "$O/store" "$OVERLAP" "$O/o.log"; rc5o=$?
  check "$rc5a" "cycle A exits 0" "rc=$rc5a"
  check "$rc5b" "cycle B exits 0" "rc=$rc5b"
  # OVERLAP IS MERGED, NOT REFUSED. The union keys blocks by number and transactions by
  # hash, so a height named by two ranges contributes one block and one row set. That makes
  # overlap idempotent by construction rather than by a check — see the tool's header.
  check "$rc5o" "the OVERLAPPING range is accepted, not refused" "rc=$rc5o"

  mapped_heights "$O/store" > "$O/mapped.txt"
  NM5=$(wc -l < "$O/mapped.txt")
  expect_match "${NM5:-0}" "heights in the live generation's height map" && {
    MISSING5=""
    for h in 26157390 26157391 26157392 26157393 26157394 26157395; do
      grep -qx "$h" "$O/mapped.txt" || MISSING5="$MISSING5 $h"
    done
    DUP=$(sort "$O/mapped.txt" | uniq -d | wc -l)
    check "$([ "$NM5" = "6" ] && [ -z "$MISSING5" ] && [ "$DUP" = "0" ] && echo 0 || echo 1)" \
      "6 distinct heights: nothing dropped and nothing double-counted" \
      "map holds $NM5, duplicates=$DUP${MISSING5:+, MISSING:$MISSING5}"
  }
  read -r BT5 BD5 <<<"$(block_list_counts "$O/store")"
  expect_match "${BT5:-0}" "hashes in the live generation's block list" && \
  check "$([ "$BT5" = "6" ] && [ "$BD5" = "6" ] && echo 0 || echo 1)" \
    "the block list is 6 and 6 distinct, not 9" "total=$BT5 distinct=$BD5"

  # The overlap is REPORTED rather than hidden: the ledger states the summed and the
  # distinct height counts, and their difference is what overlap means.
  OV=$(node -e 'const l=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
                process.stdout.write(String(l.coverage.overlapping))' "$O/state/coverage.json")
  check "$([ "$OV" = "3" ] && echo 0 || echo 1)" \
    "the ledger reports the overlap by name rather than averaging it away" \
    "coverage.overlapping=$OV (3 heights covered twice)"
  # …and the independent contiguity reader, which exists to report exactly this.
  #
  # ── THIS GREP IS ANCHORED, AND THE FIRST VERSION OF IT WAS NOT ─────────────────────
  #
  # It was `grep -i 'overlap'` over the whole output, and it PASSED for the wrong reason:
  # the first line of that output is the ledger PATH, and this script's own work directory
  # is called `overlap/`. So the arm matched its own filename and would have reported the
  # overlap named even if the reader had said nothing about it. `expect_match` cannot catch
  # that — a spurious match is not a zero match — so the fix is to anchor on the reader's
  # own label and to require the spans it found, which no path can satisfy.
  node tools/chain/coverage-contiguity.mjs "$O/state/coverage.json" > "$O/contiguity.out" 2>&1
  rc5c=$?
  OVLINE=$(sed -n 's/^overlaps between ranges: *//p' "$O/contiguity.out" | head -1)
  NOV=$(printf '%s' "$OVLINE" | sed -n 's/^\([0-9][0-9]*\).*/\1/p')
  expect_match "${NOV:-0}" "coverage-contiguity.mjs's 'overlaps between ranges:' label" && {
    # It reports 2 ADJACENCY overlaps — [26157392,26157392] and [26157393,26157394] — for 3
    # overlapping heights, because it walks consecutive PAIRS of ranges while the ledger's
    # `overlapping` counts HEIGHTS. Two true statements about one fact, and both are
    # asserted so neither can drift into standing for the other.
    HASSPANS=$(grep -c '26157392,26157392' "$O/contiguity.out")
    expect_match "${HASSPANS:-0}" "the overlapping span coverage-contiguity.mjs computed" && \
    check "$([ "$NOV" = "2" ] && echo 0 || echo 1)" \
      "coverage-contiguity.mjs names the overlap independently" \
      "overlaps between ranges: $OVLINE"
    # It exits NON-zero on an overlap, by design: it answers "does this tile with no gap
    # AND no overlap", and the answer here is legitimately no. Asserted so that an exit 0
    # — which would mean it stopped seeing the overlap — is a failure.
    check "$([ "$rc5c" != "0" ] && echo 0 || echo 1)" \
      "…and exits non-zero, because an overlap is not a clean tiling" "rc=$rc5c"
  }
  # The figures the reader sums out of `fetch`, which are 0 unless the ledger states them
  # where it looks. Measured: it printed `blocks: 0` over a ledger holding nine.
  CBLK=$(sed -n 's/^blocks *: *\([0-9][0-9]*\).*/\1/p' "$O/contiguity.out" | head -1)
  expect_match "${CBLK:-0}" "coverage-contiguity.mjs's summed 'blocks' figure" && \
  check "$([ "$CBLK" = "9" ] && echo 0 || echo 1)" \
    "the ledger states its per-range figures where that reader sums them" \
    "blocks=$CBLK across 3 ranges of 3 (the multiset, pre-dedup)"

  audit "$O/store" "$O/state/tree" "$O/audit.out" --ledger "$O/state/coverage.json"
  rc5v=$?
  for id in POINTER LEDGER RANGE CENSUS; do
    st=$(audit_state "$O/audit.out" "$id")
    check "$([ "$st" = "PASS" ] && echo 0 || echo 1)" "audit $id passes over the overlap" "$st"
  done
fi

# ═══════════════════════════════════════════════════════════════════════════════════════
# ARM 6 — IDEMPOTENCE
# ═══════════════════════════════════════════════════════════════════════════════════════
say "ARM 6 — RE-PUBLISH: a cycle that re-presents what it already has costs nothing"
manifest "$F/store" "$WORK/m-before.txt"
GEN_BEFORE=$(live_gen "$F/store")
ingest "$F/state" "$F/store" "$B" "$F/again.log"
rc6=$?
check "$rc6" "re-filing a range the ledger already covers exits 0" "rc=$rc6"
UP6=$(field "uploaded" "$F/again.log")
expect_match "$([ -n "${UP6:-}" ] && echo 1 || echo 0)" "the publisher's 'uploaded' figure" && \
check "$([ "$UP6" = "0" ] && echo 0 || echo 1)" "it uploads ZERO content objects" "uploaded=$UP6"
GEN_AFTER=$(live_gen "$F/store")
# THE DERIVED GENERATION IS WHAT MAKES THIS HOLD. A counter would bump here and re-upload
# the whole index layer for an unchanged chain; a digest of the covered content changes
# exactly when the covered content changes.
check "$([ "$GEN_AFTER" = "$GEN_BEFORE" ] && echo 0 || echo 1)" \
  "the generation id does NOT move for unchanged content" "'$GEN_BEFORE' -> '$GEN_AFTER'"
manifest "$F/store" "$WORK/m-after.txt"
diff -q "$WORK/m-before.txt" "$WORK/m-after.txt" > /dev/null 2>&1
check "$?" "every object in the store is byte-identical to before" \
  "$(wc -l < "$WORK/m-after.txt") object(s) compared by sha256"

# ═══════════════════════════════════════════════════════════════════════════════════════
say "RESULT"
printf '  checks: %s passed, %s failed' "$PASSES" "$FAILURES"
[ "$NOMATCH" -gt 0 ] && printf ' (of which %s were ZERO-MATCH refusals)' "$NOMATCH"
printf '\n'
[ "${OVERLAP_SKIPPED:-0}" = "1" ] && printf '  ARM 5 (overlap) was SKIPPED — pass --overlap <dir> to claim it.\n'
if [ "$KEEP" = "1" ]; then printf '  work kept at %s\n' "$WORK"; else rm -rf "$WORK"; fi
[ "$FAILURES" = "0" ] || exit 1
exit 0
