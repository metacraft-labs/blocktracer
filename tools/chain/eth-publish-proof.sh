#!/usr/bin/env bash
# eth-publish-proof.sh — DOES THE ETHEREUM RANGE CAPTURE REACH AN OBJECT STORE THROUGH
# THE PUBLISHER, AND DO THE FOUR PROPERTIES A DEPLOYED FOLLOWER RESTS ON HOLD FOR IT?
#
#   tools/chain/eth-publish-proof.sh [--snapshot .eth-range/tree] [--tree DIR]
#                                    [--work .eth-publish-proof] [--keep]
#
# Normally reached through `just eth-publish-proof`.
#
# ── WHAT THIS ANSWERS, AND WHY IT IS A MEASUREMENT RATHER THAN A FEATURE ──────────────
#
# The ingestion pipeline is follower -> recorder -> snapshot producer -> publisher ->
# bucket. The first three exist for Ethereum (`just eth-range`), the fourth is
# `blocktracer-publish`, and the first question about the fourth was not "what needs
# building" but "does it already accept what the third produces". Measured, on the
# 26157390-26157392 capture: it does, with no change to the publisher, to the object store
# or to the producer — `blocktracer-chain-ingest` turns the `blocktracer/chain-snapshot@2`
# tree into the published layout and `blocktracer-publish` reconciles that against a store.
# This script is that measurement, kept runnable so the next person does not rebuild it
# from nothing (which is why `just byte-identity` is a recipe too).
#
# IT RUNS AGAINST A LOCAL DIRECTORY AND HOLDS NO CREDENTIAL. `LocalObjectStore.putIfAbsent`
# is a genuine `O_CREAT|O_EXCL`, so the single-writer lease it proves is the real one and
# not an advisory stand-in; `putMany` is a per-object write, so the delta it proves is the
# real present-implies-skip decision. What a local directory CANNOT answer is named where
# it comes up: per-object `Content-Encoding` (arm 6) and the CDN's cache headers (arm 8).
# Production buckets are operator-held and §6c deliberately keeps the pointer flip with a
# human (`.github/workflows/publish-r2.yml` is `workflow_dispatch`-only), so nothing here
# asks for a production credential and nothing here should ever be given one.
#
# ── THE ARMS, AND WHY EACH ONE IS A PROPERTY A DAEMON NEEDS ───────────────────────────
#
#   1 COMPOSE    the tree publishes at all, every object of it, pointer flipped.
#   2 IDEMPOTENT the same tree published again uploads ZERO and leaves the store
#                byte-identical. This is what makes a tip-following daemon cheap: a cycle
#                that re-presents a range it already published must cost nothing.
#   3 DELTA      one object removed from the store and exactly that one comes back — the
#                resumable half, for the cycle that was interrupted.
#   4 REFRESH    an object whose BYTES changed under an unchanged key. The default cycle
#                skips it (stated here as the control, because that is the documented and
#                deliberate behaviour of a key-existence strategy) and `--refresh` moves
#                exactly it. A producer fix that reaches an already-published range depends
#                on this, and on nothing else.
#   5 ORDER      §2.2's write order, read out of the KERNEL's rename record rather than out
#                of the publisher's own report, with the pointer flip last. Armed by a
#                mutant: the same log with the flip moved first MUST be refused.
#   6 ENCODING   what this tree's containers say about `Content-Encoding` (CCP-6), and
#                whether the backend in use can carry it.
#   7 LEASE      a second concurrent publisher for the same chain is refused while the
#                first holds the lease, and proceeds once it is released. One daemon per
#                chain is exactly what that lease is for.
#   8 AUDIT      `blocktracer-verify-published`, which is an INDEPENDENT reader: it compares
#                the store against the producer tree (chains, per-class census, byte
#                identity at sampled heights) without asking the publisher anything.
#
# ── THE PINNED AUDIT FINDING, AND WHY IT IS PINNED RATHER THAN SKIPPED ────────────────
#
# Arm 8 expects exactly one finding — PROFILE's `historyFloor` disagreement — and fails on
# any other. That is not a tolerance for this path: the SAME check fails for the committed
# Aztec capture, in the opposite direction (`historyFloor` 67010 over a map beginning at
# 63459, where Ethereum has floor 0 over a map beginning at 26157390). It is a
# producer/auditor disagreement about whether `historyFloor` describes the NODE's reach or
# the PUBLISHED span, it predates this script, and it is not the publisher's. Pinning it by
# name keeps every other finding live; skipping the check would hide the next one.
#
# ── NO ABSTRACTION IS INTRODUCED, AND NONE IS SHARED WITH THE AZTEC PATH ─────────────
#
# This drives three shipping binaries by their documented flags and imports nothing. It
# registers no backend, adds no publisher option and defines no follower interface. ING-7's
# two-consumer rule is deliberately unspent: the one place a seam is wanted is the ingest
# step, and a seam guessed from one consumer is what that rule exists to prevent.

set -u

SNAPSHOT=".eth-range/tree"
TREE=""
WORK=".eth-publish-proof"
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --tree)     TREE="$2"; shift 2 ;;
    --work)     WORK="$2"; shift 2 ;;
    --keep)     KEEP=1; shift ;;
    -h|--help)
      sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root" || exit 2

# ── REFUSE RATHER THAN PASS WHEN THERE IS NOTHING TO MEASURE ────────────────────────────
#
# `just eth-range` needs the network and the recorder binary, so this script's subject may
# simply not exist on a given machine. Exiting 0 then would be the empty-set pass: a proof
# of five properties over no objects. So an absent subject is exit 2, naming how to make
# one.
if [ -z "$TREE" ] && [ ! -f "$SNAPSHOT/snapshot.json" ]; then
  cat >&2 <<EOF
no snapshot tree at '$SNAPSHOT' (expected '$SNAPSHOT/snapshot.json').

This script proves the upload half of the Ethereum ingestion path over a REAL capture, so
it needs one. Produce it with the range capture, which needs an archive endpoint and the
recorder binary:

    just eth-range <recorder-bin> <recorder-commit> --from 26157390 --to 26157392

or point this at a snapshot tree you already have (--snapshot DIR), or at an
already-ingested publish tree (--tree DIR). Exiting 2 rather than 0: a run with no subject
would report five properties proved over nothing.
EOF
  exit 2
fi

for bin in strace nim sha256sum; do
  command -v "$bin" >/dev/null 2>&1 || {
    echo "REFUSING: '$bin' is not on PATH. Arm 5 reads the publisher's write order out of" \
         "the kernel's rename record, so a run without strace would silently drop the one" \
         "arm that cannot be inferred from the publisher's own output." >&2
    exit 2
  }
done

rm -rf "$WORK"
mkdir -p "$WORK/bin"
# ABSOLUTE FROM HERE ON. `strace` records the path the process actually passed to
# `rename`, so a relative `--dest` would put relative paths in the log and every key
# extracted from it would be measured against the wrong root — which arm 5's own checker
# refuses, but arms 3 and 4 would simply find no match and report the wrong object.
WORK="$(cd "$WORK" && pwd)"
BIN="$WORK/bin"

say()  { printf '\n== %s\n' "$*"; }
FAILURES=0
PASSES=0
check() { # check <ok:0|1> <name> [detail]
  if [ "$1" = "0" ]; then PASSES=$((PASSES+1)); printf '  PASS  %s%s\n' "$2" "${3:+  — $3}"
  else FAILURES=$((FAILURES+1)); printf '  FAIL  %s%s\n' "$2" "${3:+  — $3}"; fi
}

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
nim c --hints:off -d:release --path:src -o:"$BIN/check-write-order" \
  tools/dev/check_write_order.nim > "$WORK/build-order.log" 2>&1
rc=$?; [ $rc -eq 0 ] || { echo "order-check build failed (rc=$rc), see $WORK/build-order.log" >&2; exit 2; }
echo "  built: chain-ingest, publish, verify-published, check-write-order"

# ── the publish tree ───────────────────────────────────────────────────────────────────
if [ -z "$TREE" ]; then
  say "ARM 1a — the snapshot producer's output ingests into the published layout"
  TREE="$WORK/tree"
  "$BIN/blocktracer-chain-ingest" --snapshot "$SNAPSHOT" --out "$TREE" > "$WORK/ingest.json" 2>&1
  rc=$?
  check "$rc" "blocktracer-chain-ingest accepts the snapshot tree unchanged" "rc=$rc"
  if [ $rc -ne 0 ]; then
    echo "--- the refusal, verbatim:"; cat "$WORK/ingest.json"
    echo; echo "$FAILURES failure(s): the ingest refused, so there is nothing to publish."
    exit 1
  fi
  sed -n 's/^ *"\(chain\|blocks\|transactions\|withTrace\|windowFrom\|windowTo\)": *\(.*\)$/      \1 \2/p' \
    "$WORK/ingest.json"
else
  say "ARM 1a — SKIPPED: --tree given, publishing an already-ingested tree"
fi

CHAIN="$(ls "$TREE/d" 2>/dev/null | head -1)"
[ -n "$CHAIN" ] || { echo "no chain directory under $TREE/d" >&2; exit 2; }
TREE_OBJECTS=$(find "$TREE" -type f | wc -l)
echo "      chain '$CHAIN', $TREE_OBJECTS object(s) in the tree"

STORE="$WORK/store"
manifest() { # manifest <store> <out> — sha256 of every object, lease excluded
  ( cd "$1" && find . -type f -not -path './_leases/*' -print0 | xargs -0 -r sha256sum ) \
    | sort -k2 > "$2"
}
field() { # field <label> <publisher-output-file>
  sed -n "s/^ *$1 *: *\(.*\)$/\1/p" "$2" | head -1
}
renamed_keys() { # renamed_keys <strace-log> <store-root> — the keys written, sorted
  grep 'rename(' "$1" | awk -F'"' '{print $4}' | sed "s|^$2/||" | sort -u
}
publish() { # publish <log> [extra flags…]
  local log="$1"; shift
  "$BIN/blocktracer-publish" --tree "$TREE" --backend local --dest "$STORE" "$@" \
    > "$log" 2>&1
  return $?
}

# ── ARM 1: COMPOSE ─────────────────────────────────────────────────────────────────────
say "ARM 1 — the publisher accepts the tree and publishes all of it"
publish "$WORK/p1.log" --writer proof-1; rc=$?
check "$rc" "blocktracer-publish exits 0 over the Ethereum tree" "rc=$rc"
if [ $rc -ne 0 ]; then
  echo "--- the refusal, verbatim:"; cat "$WORK/p1.log"
  echo; echo "  checks: $PASSES passed, $FAILURES failed"
  echo "The publisher refused the tree. Every arm below asks about a store this cycle was"
  echo "supposed to fill, so they are not run: their answers would be about nothing."
  exit 1
fi
UP1=$(field "content uploaded" "$WORK/p1.log")
SK1=$(field "content skipped" "$WORK/p1.log")
PT1=$(field "pointers written" "$WORK/p1.log")
FLIP1=$(field "pointer flipped" "$WORK/p1.log")
GEN1=$(field "published generation" "$WORK/p1.log")
STORED=$(find "$STORE" -type f -not -path "$STORE/_leases/*" | wc -l)
check "$([ "$FLIP1" = "true" ] && echo 0 || echo 1)" "the per-chain pointer was flipped" \
  "generation $GEN1"
check "$([ "$SK1" = "0" ] && echo 0 || echo 1)" "nothing pre-existed to skip" "skipped=$SK1"
check "$([ "$((UP1 + PT1))" = "$TREE_OBJECTS" ] && echo 0 || echo 1)" \
  "every object in the tree was accounted for" \
  "uploaded $UP1 + pointers $PT1 = $((UP1+PT1)), tree holds $TREE_OBJECTS"
check "$([ "$STORED" = "$TREE_OBJECTS" ] && echo 0 || echo 1)" \
  "the store holds one object per tree object" "store=$STORED tree=$TREE_OBJECTS"
manifest "$STORE" "$WORK/m-after-1.txt"

# ── ARM 2: IDEMPOTENT ──────────────────────────────────────────────────────────────────
say "ARM 2 — the same tree again uploads ZERO and changes no byte (§2.3)"
strace -f -qq -e trace=rename -o "$WORK/trace-2.log" \
  "$BIN/blocktracer-publish" --tree "$TREE" --backend local --dest "$STORE" \
  --writer proof-2 > "$WORK/p2.log" 2>&1
rc=$?
check "$rc" "the second cycle exits 0" "rc=$rc"
UP2=$(field "content uploaded" "$WORK/p2.log")
SK2=$(field "content skipped" "$WORK/p2.log")
RF2=$(field "content refreshed" "$WORK/p2.log")
check "$([ "$UP2" = "0" ] && echo 0 || echo 1)" "it uploads zero content objects" "uploaded=$UP2"
check "$([ "$RF2" = "0" ] && echo 0 || echo 1)" "and refreshes none" "refreshed=$RF2"
check "$([ "$SK2" = "$UP1" ] && echo 0 || echo 1)" \
  "it skips exactly what the first cycle uploaded" "skipped=$SK2, first uploaded=$UP1"
manifest "$STORE" "$WORK/m-after-2.txt"
diff -q "$WORK/m-after-1.txt" "$WORK/m-after-2.txt" > /dev/null 2>&1
check "$?" "every object in the store is byte-identical to before" \
  "$(wc -l < "$WORK/m-after-2.txt") object(s) compared by sha256"
# ── THE POINTER SET, MEASURED RATHER THAN PATTERN-MATCHED ──────────────────────────────
#
# Arms 3 and 4 have to say WHICH object moved, and the pointers move on every cycle by
# design (§2.1: `stUnconditional`). Recognising them by path shape here would be a second
# copy of `classOf`, in bash, that drifts the day a pointer class is added. This cycle
# uploaded zero and refreshed zero, so everything it wrote IS the pointer set — the
# publisher's own classification, read off a run rather than restated.
renamed_keys "$WORK/trace-2.log" "$STORE" > "$WORK/pointers.txt"
check "$([ "$(wc -l < "$WORK/pointers.txt")" = "$PT1" ] && echo 0 || echo 1)" \
  "the cycle's only writes are the pointers the publisher counted" \
  "$(wc -l < "$WORK/pointers.txt") written, $PT1 reported"

# ── ARM 3: DELTA, the missing object ───────────────────────────────────────────────────
say "ARM 3 — one object missing from the store, and exactly that one comes back"
VICTIM=$(awk '{print $2}' "$WORK/m-after-2.txt" | sed 's|^\./||' \
         | grep "^d/$CHAIN/tx/" | head -1)
if [ -z "$VICTIM" ]; then
  VICTIM=$(awk '{print $2}' "$WORK/m-after-2.txt" | sed 's|^\./||' | grep "^d/$CHAIN/block/" | head -1)
fi
check "$([ -n "$VICTIM" ] && echo 0 || echo 1)" "a content object was found to remove" "$VICTIM"
rm -f "$STORE/$VICTIM"
strace -f -qq -e trace=rename -o "$WORK/trace-3.log" \
  "$BIN/blocktracer-publish" --tree "$TREE" --backend local --dest "$STORE" \
  --writer proof-3 > "$WORK/p3.log" 2>&1
rc=$?
check "$rc" "the delta cycle exits 0" "rc=$rc"
UP3=$(field "content uploaded" "$WORK/p3.log")
check "$([ "$UP3" = "1" ] && echo 0 || echo 1)" "it uploads exactly one content object" "uploaded=$UP3"
# WHICH one, from the kernel's record rather than from the count: a cycle that uploaded one
# object and uploaded the WRONG one reports the same number.
renamed_keys "$WORK/trace-3.log" "$STORE" > "$WORK/moved-3.txt"
MOVED=$(comm -23 "$WORK/moved-3.txt" "$WORK/pointers.txt")
check "$([ "$MOVED" = "$VICTIM" ] && echo 0 || echo 1)" \
  "and it is the one that was removed" "moved: ${MOVED:-<nothing>}"
manifest "$STORE" "$WORK/m-after-3.txt"
diff -q "$WORK/m-after-2.txt" "$WORK/m-after-3.txt" > /dev/null 2>&1
check "$?" "the store is byte-identical to before the removal" ""

# ── ARM 4: REFRESH, the changed bytes under an unchanged key ───────────────────────────
say "ARM 4 — an object whose BYTES moved under an unchanged key"
MUT=$(awk '{print $2}' "$WORK/m-after-3.txt" | sed 's|^\./||' | grep "^d/$CHAIN/block/" | head -1)
check "$([ -n "$MUT" ] && echo 0 || echo 1)" "a content object was found to change" "$MUT"
cp "$TREE/$MUT" "$WORK/mut.bak"          # a copy, never a VCS revert
printf '\n' >> "$TREE/$MUT"              # one byte, still valid JSON
TREE_SHA=$(sha256sum "$TREE/$MUT" | cut -c1-16)
publish "$WORK/p4.log" --writer proof-4; rc=$?
check "$rc" "the DEFAULT cycle exits 0" "rc=$rc"
UP4=$(field "content uploaded" "$WORK/p4.log")
RF4=$(field "content refreshed" "$WORK/p4.log")
STORE_SHA=$(sha256sum "$STORE/$MUT" | cut -c1-16)
# The control, and it is the documented behaviour rather than a defect found here: a
# key-existence strategy is a statement that the key identifies the bytes, so the default
# cycle must not pay to compare them. `--refresh` is the path for the producer fix.
check "$([ "$UP4" = "0" ] && [ "$RF4" = "0" ] && echo 0 || echo 1)" \
  "CONTROL: the default cycle writes nothing (present implies skip)" \
  "uploaded=$UP4 refreshed=$RF4"
check "$([ "$STORE_SHA" != "$TREE_SHA" ] && echo 0 || echo 1)" \
  "CONTROL: so the store still holds the OLD bytes" \
  "store $STORE_SHA, tree $TREE_SHA"
strace -f -qq -e trace=rename -o "$WORK/trace-5.log" \
  "$BIN/blocktracer-publish" --tree "$TREE" --backend local --dest "$STORE" \
  --writer proof-5 --refresh > "$WORK/p5.log" 2>&1
rc=$?
check "$rc" "the --refresh cycle exits 0" "rc=$rc"
UP5=$(field "content uploaded" "$WORK/p5.log")
RF5=$(field "content refreshed" "$WORK/p5.log")
check "$([ "$RF5" = "1" ] && [ "$UP5" = "0" ] && echo 0 || echo 1)" \
  "it refreshes exactly one object and uploads none" "refreshed=$RF5 uploaded=$UP5"
renamed_keys "$WORK/trace-5.log" "$STORE" > "$WORK/moved-5.txt"
MOVED5=$(comm -23 "$WORK/moved-5.txt" "$WORK/pointers.txt")
check "$([ "$MOVED5" = "$MUT" ] && echo 0 || echo 1)" "and it is the one that changed" \
  "moved: ${MOVED5:-<nothing>}"
check "$([ "$(sha256sum "$STORE/$MUT" | cut -c1-16)" = "$TREE_SHA" ] && echo 0 || echo 1)" \
  "the store now holds the tree's bytes" "$TREE_SHA"
cp "$WORK/mut.bak" "$TREE/$MUT"          # restore from the copy
# AND PUBLISH THE RESTORE, because the store now holds bytes the tree no longer has. Arm 8
# compares the store against the tree byte for byte and would report this arm's own residue
# as a published-data defect — which it did, the first time this script ran end to end. The
# second refresh is also the other half of the property: superseding is symmetric, so the
# same cycle that moved the changed object moves it back.
publish "$WORK/p6.log" --writer proof-6 --refresh; rc=$?
check "$rc" "a --refresh cycle restores the original bytes" \
  "rc=$rc, refreshed=$(field "content refreshed" "$WORK/p6.log")"
check "$([ "$(sha256sum "$STORE/$MUT" | cut -c1-16)" = "$(sha256sum "$TREE/$MUT" | cut -c1-16)" ] \
        && echo 0 || echo 1)" \
  "the store and the tree agree again" "$(sha256sum "$TREE/$MUT" | cut -c1-16)"

# ── ARM 5: ORDER, from the kernel ──────────────────────────────────────────────────────
say "ARM 5 — §2.2's write order, and the pointer flip last, read from the kernel"
STORE_ORD="$WORK/store-order"
strace -f -qq -e trace=rename -o "$WORK/trace-order.log" \
  "$BIN/blocktracer-publish" --tree "$TREE" --backend local --dest "$STORE_ORD" \
  --writer proof-order > "$WORK/p-order.log" 2>&1
rc=$?
check "$rc" "a fresh traced publish exits 0" "rc=$rc"
UPO=$(field "content uploaded" "$WORK/p-order.log")
PTO=$(field "pointers written" "$WORK/p-order.log")
"$BIN/check-write-order" "$WORK/trace-order.log" "$STORE_ORD" --expect "$((UPO+PTO))" \
  > "$WORK/order.out" 2>&1
rc=$?
check "$rc" "check_write_order accepts the order the kernel recorded" "rc=$rc"
sed -n 's/^/      /p' "$WORK/order.out"
# THE MUTANT, because an ordering check that has only ever been run on a passing log is
# indistinguishable from one that cannot fail. The same log with the visibility flip moved
# to the FRONT must be refused.
FLIPLINE=$(grep -nF "$STORE_ORD/d/$CHAIN/current.json\"" "$WORK/trace-order.log" \
           | tail -1 | cut -d: -f1)
if [ -n "$FLIPLINE" ]; then
  { sed -n "${FLIPLINE}p" "$WORK/trace-order.log"; sed "${FLIPLINE}d" "$WORK/trace-order.log"; } \
    > "$WORK/trace-mutant.log"
  "$BIN/check-write-order" "$WORK/trace-mutant.log" "$STORE_ORD" --quiet \
    > "$WORK/order-mutant.out" 2>&1
  rc=$?
  check "$([ "$rc" = "1" ] && echo 0 || echo 1)" \
    "MUTANT: the same log with the flip written FIRST is refused" "rc=$rc (want 1)"
else
  check 1 "MUTANT: the flip's rename line was found in the trace" "not found"
fi

# ── ARM 6: ENCODING ───────────────────────────────────────────────────────────────────
say "ARM 6 — what this tree's containers say about Content-Encoding (CCP-6)"
ENCODED=0
CONTAINERS=0
for m in $(find "$TREE/t" -name manifest.json 2>/dev/null | sort); do
  CONTAINERS=$((CONTAINERS+1))
  enc=$(sed -n 's/.*"encoding": *"\([^"]*\)".*/\1/p' "$m" | head -1)
  if [ -n "$enc" ]; then
    ENCODED=$((ENCODED+1))
    echo "      $(dirname "${m#"$TREE/"}") encoding=$enc"
  fi
done
echo "      $CONTAINERS container manifest(s), $ENCODED declaring an encoding"
if [ "$CONTAINERS" = "0" ]; then
  # An empty set satisfies "every container is identity" without being asked, which is the
  # pass this whole script is written not to produce. A range that recorded nothing simply
  # does not answer the encoding question.
  echo "      NOT MEASURED: this tree carries no container, so there is nothing whose"
  echo "      Content-Encoding could be right or wrong. Capture a range that records at"
  echo "      least one transaction to answer arm 6."
else
  # `ingest.nim` writes `container.encoding` / `storedBytes` / `storedHash` only when the
  # encoding is not identity, and `IngestConfig.containerEncoding` has no CLI flag — so a
  # tree produced by `blocktracer-chain-ingest` is identity by construction, every container
  # is stored as its own bytes, and `BulkItem.contentEncoding` is "" for all of them.
  check "$([ "$ENCODED" = "0" ] && echo 0 || echo 1)" \
    "every container is identity, with the member OMITTED rather than written" \
    "$ENCODED of $CONTAINERS declare an encoding"
  # And the backend agrees it could not have carried one: `LocalObjectStore.putMany` refuses
  # a `contentEncoding` outright rather than dropping the header, so arm 1's exit 0 is
  # itself evidence that nothing pre-compressed was handed to it.
  check 0 "the local backend accepted the batch, which it refuses for any encoded object" \
    "LocalObjectStore.putMany raises on a non-empty contentEncoding"
fi
echo "      NOT MEASURED here: per-object Content-Encoding metadata on a real store."
echo "      It is S3ObjectStore.putMany's one-cp-per-encoding partition, and a directory"
echo "      has no per-object metadata to hold the header."

# ── ARM 7: LEASE ──────────────────────────────────────────────────────────────────────
say "ARM 7 — one writer per chain, under genuine concurrency (§2.3)"
STORE_LEASE="$WORK/store-lease"
LOCK="$STORE_LEASE/_leases/$CHAIN.lock"
"$BIN/blocktracer-publish" --tree "$TREE" --backend local --dest "$STORE_LEASE" \
  --writer writer-A > "$WORK/lease-A.log" 2>&1 &
APID=$!
# Busy-wait on A's own lease object: no sleep, and no assumption about how long a cycle
# takes. B is started while A demonstrably holds it.
SPINS=0
while [ ! -f "$LOCK" ]; do
  SPINS=$((SPINS+1))
  kill -0 "$APID" 2>/dev/null || break
done
HOLDER=$(cat "$LOCK" 2>/dev/null | tr -d '\n')
check "$([ "$HOLDER" = "writer-A" ] && echo 0 || echo 1)" \
  "writer A's lease is visible in the store while it publishes" \
  "holder='${HOLDER:-<none>}' after $SPINS spin(s)"
"$BIN/blocktracer-publish" --tree "$TREE" --backend local --dest "$STORE_LEASE" \
  --writer writer-B > "$WORK/lease-B.log" 2>&1
rcB=$?
check "$([ "$rcB" = "1" ] && echo 0 || echo 1)" "writer B is refused while the lease is held" \
  "rc=$rcB (want 1)"
grep -q "locked by another publisher" "$WORK/lease-B.log"
check "$?" "and refused BY NAME" "$(head -1 "$WORK/lease-B.log")"
wait "$APID"; rcA=$?
check "$rcA" "writer A completes" "rc=$rcA"
check "$([ ! -f "$LOCK" ] && echo 0 || echo 1)" "the lease is released when A finishes" \
  "$( [ -f "$LOCK" ] && echo "still held by $(cat "$LOCK")" || echo "lock object absent" )"
"$BIN/blocktracer-publish" --tree "$TREE" --backend local --dest "$STORE_LEASE" \
  --writer writer-B > "$WORK/lease-B2.log" 2>&1
rcB2=$?
check "$rcB2" "writer B then proceeds, and its cycle uploads zero" \
  "rc=$rcB2, uploaded=$(field "content uploaded" "$WORK/lease-B2.log")"

# ── ARM 8: AUDIT, by a reader that asks the publisher nothing ─────────────────────────
say "ARM 8 — the independent read-only audit of the published store"
"$BIN/blocktracer-verify-published" --backend local --dest "$STORE" --tree "$TREE" \
  --allow-unrunnable LEDGER --allow-unrunnable CACHE > "$WORK/audit.out" 2>&1
rcAudit=$?
sed -n 's/^/      /p' "$WORK/audit.out"
# Every finding the audit raised, pinned against the THREE sentences that are expected
# here: the known producer/auditor `historyFloor` disagreement (see the header), and the
# two checks that cannot run against a directory at all — LEDGER, because a hand-run range
# writes no coverage ledger, and CACHE, because cache headers are a property of the CDN.
# Those two are passed `--allow-unrunnable` above, which keeps them VISIBLE in the output
# and on the exit line rather than skipped; their own sentences are matched here so a NEW
# unrunnable arrives as a failure instead of joining them.
UNKNOWN=$(grep -E '^ *! ' "$WORK/audit.out" \
          | grep -v 'historyFloor' \
          | grep -v 'no range ledger given' \
          | grep -v 'serves no response headers' || true)
check "$([ -z "$UNKNOWN" ] && echo 0 || echo 1)" \
  "the audit reports no finding beyond the pinned historyFloor disagreement" \
  "$(printf '%s' "${UNKNOWN:-none}" | head -1)"
if [ "$rcAudit" = "0" ]; then
  echo "      NOTE: the audit is now CLEAN. The pinned historyFloor finding above has been"
  echo "      fixed somewhere — drop the pin in this script's arm 8 and in its header."
fi
for want in REGISTRY POINTER RANGE CENSUS; do
  grep -qE "PASS +$want" "$WORK/audit.out"
  check "$?" "$want passes" ""
done

# ── summary ──────────────────────────────────────────────────────────────────────────
printf '\n== summary\n'
echo "  chain              : $CHAIN"
echo "  tree objects       : $TREE_OBJECTS"
echo "  first cycle        : uploaded $UP1, pointers $PT1, generation $GEN1"
echo "  second cycle       : uploaded $UP2, skipped $SK2"
echo "  checks             : $PASSES passed, $FAILURES failed"
if [ "$KEEP" = "0" ]; then
  rm -rf "$WORK/store" "$WORK/store-order" "$WORK/store-lease"
  echo "  (stores removed; --keep retains them, logs stay under $WORK)"
fi
if [ "$FAILURES" -gt 0 ]; then exit 1; fi
exit 0
