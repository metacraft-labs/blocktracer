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
  let errs = validateTree(root)
  if errs.len == 0:
    echo "OK: tree at " & root & " conforms to contract version " & $ContractVersion
    quit 0
  stderr.writeLine "FAIL: " & $errs.len & " conformance error(s):"
  for e in errs:
    stderr.writeLine "  - " & e
  quit 1

main()
