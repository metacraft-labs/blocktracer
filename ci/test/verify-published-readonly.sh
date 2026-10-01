#!/usr/bin/env bash
#
# verify-published-readonly.sh — `blocktracer-verify-published` cannot write.
#
# WHY THIS EXISTS
# ---------------
# The verifier is the one tool in this repository that is MEANT to be pointed at
# production, repeatedly, and eventually on a schedule. `DEPLOY.md` §3 and
# Deployment-And-Operations.md §6c are explicit that agents never hold
# production credentials — but the operator who runs this does, because the S3
# backend needs one to read a private bucket. So the credential in the process
# is a read-write credential, and the only thing standing between it and a
# production object is this code.
#
# "We were careful" is not that thing. `verify/source.nim` exposes `fetch`,
# `canList` and `listSizes` and no fourth operation, which is the structural
# half; `tests/tverifypublished.nim` asserts `not compiles(s.put(…))`, which
# pins the type. This is the lexical half, and it is the one that catches the
# case those two do not: `S3Source` privately HOLDS an `S3ObjectStore`, whose
# `put`, `del`, `putIfAbsent` and `putMany` are all one field access away.
# Holding it is deliberate — re-implementing the `aws` plumbing would be a
# second copy of the one thing here that has already shipped a defect nobody
# could see — and the cost of that decision is paid here.
#
# It is modelled on `ci/test/client-sdk-boundary.sh`, which enforces the Client
# SDK's import boundary lexically for the same reason and says so: a rule that
# depends on someone remembering it is not a boundary.
#
# WHAT IT CHECKS
#   Every file under `src/blocktracer/verify/` plus `src/blocktracer_verify_published.nim`
#   is scanned for a call to any ObjectStore write method. A match fails BY NAME
#   with the file and line.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   It does not parse Nim. A method name inside a STRING or a COMMENT matches,
#   and those are frequent here because the headers explain precisely which
#   methods are not called. So the scan strips `##`/`#` comments and string
#   literals before matching — and `verify-published-readonly-test.sh` plants a
#   real call to prove the strip did not also remove the code.
#
# Offline, toolchain-free, reads files and writes nothing.
set -euo pipefail

root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

subjects=()
while IFS= read -r f; do subjects+=("$f"); done < <(
  find "$root/src/blocktracer/verify" -name '*.nim' -type f 2>/dev/null | sort
)
[ -f "$root/src/blocktracer_verify_published.nim" ] &&
  subjects+=("$root/src/blocktracer_verify_published.nim")

# THE SUBJECT LIST IS ASSERTED NON-EMPTY BEFORE ANYTHING QUANTIFIES OVER IT.
# A find that matched nothing would report "0 violations" and read as a pass,
# which is the shape `ci-coverage.sh` names as the failure it exists to stop.
if [ "${#subjects[@]}" -lt 2 ]; then
  echo "verify-published-readonly: found ${#subjects[@]} subject file(s) under $root."
  echo "  Expected at least the verify/ modules and the CLI. A scan with no"
  echo "  subjects reports no violations and means nothing."
  exit 1
fi

# The write surface of `publish/objectstore.nim`, named here rather than derived,
# because deriving it from that file would make this guard pass the moment
# somebody renamed a method there.
writes=(put putIfAbsent putMany del)

violations=0
scanned=0
for f in "${subjects[@]}"; do
  scanned=$((scanned + 1))
  # Strip: full-line comments, trailing comments, and double-quoted strings.
  # `perl` and not `sed`: BSD sed has no non-greedy match and this needs one.
  stripped="$(perl -pe 's/"(\\.|[^"\\])*"/""/g; s/#.*$//' "$f")"
  for m in "${writes[@]}"; do
    hits="$(printf '%s\n' "$stripped" | grep -n "\\.${m}(" || true)"
    if [ -n "$hits" ]; then
      echo "REFUSED  ${f#"$root"/}"
      echo "$hits" | while IFS= read -r h; do echo "    .$m( at line ${h%%:*}"; done
      echo "    The verifier runs against production with a credential that can"
      echo "    write. It must reach no write method, including through the"
      echo "    S3ObjectStore that S3Source holds privately. If this object"
      echo "    genuinely needs writing, it does not belong in this tool."
      violations=$((violations + 1))
    fi
  done
done

echo "verify-published-readonly: scanned $scanned file(s) for ${#writes[@]} write method(s)"
if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations write call(s) reachable from the production verifier."
  exit 1
fi
echo "OK: no write method is called from the production verifier."
