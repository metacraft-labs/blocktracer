## Did the publisher write the store in §2.2's order — observed from the KERNEL?
##
## `Publishing-And-Caching.md` §2.2 orders a publishing cycle by object class:
## containers before manifests, data before index shards, maps before the
## generation root, and `d/{chain}/current.json` — the per-chain visibility flip
## — strictly last, so no reference a reader can follow is ever published before
## the object it points at.
##
## WHY THIS IS NOT ASSERTED FROM THE PUBLISHER'S OWN OUTPUT. `PublishResult`
## reports how many objects of each disposition a cycle had, in no order at all;
## `publisher.nim` carries a comment that says the flip is last and a `rankOf`
## that says in what order the rest go. Both are the claim, neither is evidence
## of it. A batch flushed at the wrong boundary, a pointer written one `flush()`
## too early, or a future refactor that moves the `currentKey` write up would
## leave every count in that report unchanged.
##
## So the subject here is the SYSCALL RECORD. Drive the publisher under
##
##     strace -f -qq -e trace=rename -o LOG  blocktracer-publish --backend local …
##
## and every object that reached the store appears exactly once, in the order the
## kernel performed it, because `LocalObjectStore.put` is a write-to-temp plus a
## `rename` over the target (which is also what makes the flip atomic for a
## concurrent reader). This program reads that log and checks the order against
## `publisher.nim`'s OWN `classOf`/`rankOf` — imported, not restated, so a class
## added there is checked here with nobody copying a table.
##
## THE ENUMERATION IS ARMED, and that is not decoration: the first run of this
## check matched ZERO renames (a path prefix was being stripped of its leading
## `/`) and reported "0 inversions, pointer is last" — a clean pass over an empty
## set, which is the shape of mistake `Verification-Harness-Traps.md` §35 names.
## A log that yields no write into the store is therefore a REFUSAL, and
## `--expect N` makes the stronger statement available: the kernel's count of
## renames into the store must equal the publisher's own tally of objects it says
## it wrote (`content uploaded` + `content refreshed` + `pointers written`). Two
## independent records of one cycle, compared.
##
## Usage:
##   check_write_order <strace-log> <store-root> [--expect N] [--quiet]
##
## Exit: 0 the order holds · 1 it does not · 2 the log says nothing to check.

import std/[os, strutils, tables]
import blocktracer/publish/publisher

proc main =
  if paramCount() < 2:
    stderr.writeLine "usage: check_write_order <strace-log> <store-root> " &
      "[--expect N] [--quiet]"
    quit 2
  let logPath = paramStr(1)
  # `strip` defaults to stripping BOTH ends; an absolute path stripped of its
  # leading '/' matches nothing and every check below then passes vacuously.
  # That is the defect this file's header records, so the leading end is pinned.
  let storeRoot = paramStr(2).absolutePath.strip(leading = false, trailing = true,
                                                 chars = {'/'})
  var expect = -1
  var quiet = false
  var i = 3
  while i <= paramCount():
    case paramStr(i)
    of "--expect":
      inc i
      if i > paramCount(): quit("--expect needs a number", 2)
      expect = parseInt(paramStr(i))
    of "--quiet": quiet = true
    else: quit("unknown argument '" & paramStr(i) & "'", 2)
    inc i

  if not fileExists(logPath):
    stderr.writeLine "no such log: " & logPath
    quit 2

  # One rename line per object published: rename("<tmp>", "<dst>") = 0. The
  # destination is the store path, so the key is what follows the store root.
  var order: seq[string] = @[]
  for line in lines(logPath):
    if "rename(" notin line: continue
    if not line.strip().endsWith("= 0"): continue   # a failed rename wrote nothing
    let parts = line.split('"')
    if parts.len < 4: continue
    let dst = parts[3]
    if not dst.startsWith(storeRoot & "/"): continue
    order.add dst[(storeRoot.len + 1) .. ^1]

  echo "store root  : ", storeRoot
  echo "log         : ", logPath
  echo "writes seen : ", order.len

  if order.len == 0:
    stderr.writeLine "REFUSING: the log records no rename into " & storeRoot &
      ", so there is no write order to check. Every assertion below would pass " &
      "over the empty set. Either the publish wrote nothing, the store root is " &
      "not the one the publish used, or the trace did not cover the child process " &
      "(`strace -f`)."
    quit 2

  var failures = 0
  proc check(name: string, ok: bool, detail = "") =
    if not ok: inc failures
    echo (if ok: "  PASS  " else: "  FAIL  "), name,
      (if detail.len > 0: "  — " & detail else: "")

  # 1. The two records of one cycle agree on how many objects moved.
  if expect >= 0:
    check("the kernel's write count equals the publisher's own tally",
      order.len == expect, "kernel " & $order.len & ", publisher " & $expect)

  # 2. Rank order: nothing of a lower rank is written after a higher one, which
  #    is what keeps a manifest from naming a container that is not there yet.
  var inversions = 0
  var firstInversion = ""
  for k in 1 ..< order.len:
    let ra = rankOf(classOf(order[k-1]))
    let rb = rankOf(classOf(order[k]))
    if rb < ra:
      inc inversions
      if firstInversion.len == 0:
        firstInversion = order[k-1] & " (rank " & $ra & ") then " &
          order[k] & " (rank " & $rb & ")"
  check("§2.2 rank order holds across every write", inversions == 0,
    (if inversions == 0: $order.len & " write(s), 0 inversion(s)"
     else: $inversions & " inversion(s), first: " & firstInversion))

  # 3. The per-chain pointer is the LAST write of the cycle, and it is the only
  #    object of its class — a second `ocCurrent` would mean two chains' flips
  #    interleaved inside one cycle.
  var currents: seq[int] = @[]
  for idx, k in order:
    if classOf(k) == ocCurrent: currents.add idx
  check("exactly one visibility flip in the cycle", currents.len == 1,
    $currents.len & " ocCurrent write(s)")
  if currents.len >= 1:
    check("the visibility flip is the final write",
      currents[^1] == order.len - 1,
      "last write is " & order[^1] & " (" & $classOf(order[^1]) & ")")

  # 4. No key written twice: a cycle that rewrote an object it had already put
  #    would make "uploaded" and "skipped" counts unreadable.
  var seen = initCountTable[string]()
  for k in order: seen.inc k
  var dup: seq[string] = @[]
  for k, n in seen:
    if n > 1: dup.add k & " ×" & $n
  check("every key written at most once", dup.len == 0,
    (if dup.len == 0: "" else: dup[0 ..< min(3, dup.len)].join(", ")))

  if not quiet:
    echo "phases, in the order the kernel performed them:"
    var r = -1
    var n = 0
    var firstKey = ""
    proc emit() =
      if n > 0:
        echo "  rank ", align($r, 3), "  ", alignLeft($classOf(firstKey), 17),
          align($n, 6), " object(s)   e.g. ", firstKey
    for k in order:
      let kr = rankOf(classOf(k))
      if kr != r:
        emit()
        r = kr; n = 1; firstKey = k
      else:
        inc n
    emit()

  if failures > 0:
    stderr.writeLine $failures & " ordering check(s) FAILED"
    quit 1
  echo "write order holds"

main()
