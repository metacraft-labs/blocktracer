## `blocktracer-client-conformance` — run the CONSUMER-side conformance report
## over a published tree.
##
## The seam has two checks and they answer different questions. `blocktracer-validate`
## asks *"is this tree well-formed against the contract?"* — a producer's question,
## and it has had a command since M5b. This one asks *"can a consumer render this
## tree end to end without knowing who wrote it?"* — which is the interchangeability
## claim itself, and until now it was a library proc
## (`blocktracer_client/conformance.nim`) whose only callers were in
## `tests/tclientsdk.nim`. A check nobody outside this repository can run is a check
## that only this repository's producers are held to.
##
## It walks the tree through the SDK's public read path and reports what a consumer
## could not do, with three oracles that are independent of the SDK's own decoding:
## the derived trace address against the manifest's own claim, the container's
## declared length against the bytes served, and a block's transaction list against
## each transaction's own recorded position.
##
## Usage:
##   blocktracer-client-conformance PATH [--chain SLUG]
##
## Exits 0 when the report is clean, 1 when it is not, 2 on a usage error. With no
## `--chain` it reports on every chain the tree's registry publishes.
##
## It reads one directory and reaches no network: the store is
## `blocktracer_client/store.localTree`, whose fetch is a file read.

import std/[os, strutils]
import blocktracer_client/store
import blocktracer_client/conformance

proc usage() =
  stderr.writeLine "usage: blocktracer-client-conformance PATH [--chain SLUG]"

proc main() =
  var root = ""
  var chain = ""
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--chain":
      if i == paramCount():
        stderr.writeLine "error: --chain needs a slug"
        quit 2
      chain = paramStr(i + 1); inc i
    elif a.startsWith("--chain="):
      chain = a["--chain=".len .. ^1]
    elif a == "--help" or a == "-h":
      usage(); quit 0
    elif a.startsWith("-"):
      stderr.writeLine "error: unknown flag " & a
      quit 2
    elif root.len == 0:
      root = a
    else:
      stderr.writeLine "error: more than one path given"
      quit 2
    inc i

  if root.len == 0:
    usage(); quit 2
  # THE MISSING TREE IS REFUSED RATHER THAN REPORTED CLEAN. A consumer report over
  # a directory that is not there has nothing to disagree with, and "no errors" is
  # what an empty walk produces — the shape of green this whole seam exists to
  # refuse.
  if not dirExists(root):
    stderr.writeLine "error: no published tree at " & root
    quit 2

  let s = localTree(root)
  let r = if chain.len > 0: consumerConformance(s, chain)
          else: consumerConformance(s)

  echo "tree: " & root
  echo "chain(s): " & (if r.chain.len > 0: r.chain else: "(none)")
  echo "generation: " & (if r.generation.len > 0: r.generation else: "(none)")
  echo "blocks checked: " & $r.blocksChecked
  echo "transactions checked: " & $r.transactionsChecked
  echo "traces resolved: " & $r.tracesResolved
  echo "traces replayable: " & $r.tracesReplayable

  if r.ok:
    echo "OK: a consumer can render " & root & " end to end"
    quit 0
  stderr.writeLine "FAIL: " & $r.errors.len & " consumer-side conformance error(s):"
  for e in r.errors:
    stderr.writeLine "  - " & e
  quit 1

main()
