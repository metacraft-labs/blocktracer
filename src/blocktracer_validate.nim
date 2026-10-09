## `blocktracer-validate` — run the conformance validator over a static tree (M5b).
##
## Usage:
##   blocktracer-validate PATH
##
## Exits 0 when the tree conforms to the supported contract version, non-zero with
## a list of conformance errors otherwise. Both the demo generator (M5c) and the
## real pipeline (M7 + M10) run this in CI.

import std/os
import blocktracer/validator
import blocktracer/contract/version

proc main() =
  if paramCount() < 1:
    stderr.writeLine "usage: blocktracer-validate PATH"
    quit 2
  let root = paramStr(1)
  let rep = validateTreeReport(root)
  # ── WHAT WAS NOT LOOKED AT IS PRINTED AS LOUDLY AS WHAT WAS (CCP-6) ────────
  #
  # Printed BEFORE the verdict and on both paths, because a gap reported after an
  # "OK" is a gap nobody reads. It is not an error: its occupant today is the raw
  # container figures behind a pre-compressed object with no `brotli` on PATH, and
  # the remedy is to supply a decoder or to fetch with negotiation — never to
  # change the tree. The object AT REST was still verified exactly.
  if rep.notMeasured.len > 0:
    stderr.writeLine "NOT MEASURED: " & $rep.notMeasured.len &
      " check(s) could not be run. They are not counted as passed:"
    for f in rep.notMeasured:
      stderr.writeLine "  ? " & f.errorLine
  if rep.findings.len == 0:
    echo "OK: tree at " & root & " conforms to contract version " & $ContractVersion
    quit 0
  stderr.writeLine "FAIL: " & $rep.findings.len & " conformance error(s):"
  for f in rep.findings:
    stderr.writeLine "  - " & f.errorLine
  quit 1

main()
