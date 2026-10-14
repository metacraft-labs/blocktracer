## compact_container — convert a CTFS container to the compact profile in place.
##
##   compact_container --threshold N [--check] <file.ct> ...
##
## `--threshold` is §1e's ceiling in RAW bytes and is REQUIRED. A default would
## be a publishing policy nobody chose, hidden in a tool.
##
## ── WHY THIS IS A CONVERSION AND NOT A RE-RECORD ──────────────────────────
##
## `ctfs-container.md` §1e's compact profile is a property of the CONTAINER, not
## of the recording: §1f says a compact container carries the full container's
## members under the same names with every zstd frame replaced by its content.
## `codetracer_trace_writer/compact_profile.selectProfile` is that conversion,
## and it is the conforming one — `collectFullProfileMembers` reads members
## VERBATIM and is not.
##
## So a container that a recorder already wrote can be moved to the compact
## profile without the recorder, the node or the network. That matters here
## because the containers the published site carries are `nargo trace`
## recordings vendored under `fixtures/trace/`, copied verbatim into the demo
## tree by `demo/generator.nim` — the only thing between them and a compact
## published corpus is this conversion.
##
## ── NOT APPLICABLE IS NOT A REFUSAL ───────────────────────────────────────
##
## The tracked corpus holds three things this conversion has nothing to say
## about: containers already at version 6, containers at version 3, and the
## conformance kit's 229-byte ASCII placeholders, which carry no CTFS magic ON
## PURPOSE. Reporting those as refusals made the whole corpus exit non-zero —
## 43 of 55 paths — and a gate that is red over its own normal population is a
## gate nobody can read.
##
## So they are N/A, and REFUSED is kept for the thing that is actually wrong: a
## version-5 container the conversion could not convert. The conversion itself
## refuses an `events.log` member, because copying a seekable-zstd stream's
## frames would break §1e's raw-member property; and a converted result whose
## header is not container 6 profile 1 is refused rather than written.
##
## Version 3 is N/A rather than a failure for a reason worth stating: the
## conversion reads a member directory this writer's own layout defines, and v3
## is a different layout — measured, the reader finds `calls.dat` and then
## "record extends past end of chunk". Those containers need a RE-RECORD
## (`tools/chain/rerecord-snapshot.mjs`), which is a different operation with a
## different input, not a harder version of this one.
##
## ── COMPACT IS NOT SMALLER, AND THAT IS THE POINT OF THE THRESHOLD ────────
##
## §1f stores members INFLATED, so a container whose per-member zstd was
## effective is LARGER compact than full. Measured over this repository's ten
## `nargo trace` containers: nine shrink, several by 8x
## (`tour_branches` 77,824 -> 9,057), and `zk_shields` grows 102,400 -> 732,258.
##
## That is why §1e has a threshold at all, and why this tool applies the rule
## rather than forcing the profile: `selectProfile` returns compact when the raw
## member total is BELOW the threshold and full otherwise. The tool then asserts
## that the bytes it got carry the profile the rule selected — a tool that passed
## a number and hoped would silently leave a container full.

import std/[os, strutils]
import codetracer_ctfs/types
import codetracer_trace_writer/compact_profile

proc headerOf(b: string): tuple[magic: string, version: int, profile: int] =
  if b.len < 6: return ("", -1, -1)
  var m = ""
  for i in 0 ..< 5: m.add toHex(ord(b[i]), 2).toLowerAscii
  let v = ord(b[5])
  let p = if v == int(CtfsVersionV6) and b.len > 16: ord(b[16]) else: -1
  (m, v, p)

const Magic = "c0de72ace2"

proc main(): int =
  var files: seq[string]
  var checkOnly = false
  var threshold = uint64(0)
  var haveThreshold = false
  var args = commandLineParams()
  var i = 0
  while i < args.len:
    let a = args[i]
    if a == "--check": checkOnly = true
    elif a == "--threshold":
      inc i
      if i >= args.len:
        stderr.writeLine "compact_container: --threshold needs a value"
        return 2
      try: threshold = parseBiggestUInt(args[i]).uint64
      except ValueError:
        stderr.writeLine "compact_container: --threshold must be a non-negative integer"
        return 2
      haveThreshold = true
    elif a.startsWith("--"):
      stderr.writeLine "compact_container: unknown option " & a
      return 2
    else: files.add a
    inc i
  if files.len == 0 or not haveThreshold:
    stderr.writeLine "usage: compact_container --threshold N [--check] <file.ct> ..."
    stderr.writeLine "  --threshold is §1e's ceiling in RAW bytes and has no default:"
    stderr.writeLine "  a default would be a publishing policy nobody chose."
    return 2

  var converted, already, refused, leftFull, na = 0
  for f in files:
    if not fileExists(f):
      echo "  [REFUSED] ", f, " — no such file"
      refused.inc
      continue
    let full = readFile(f)
    let (magic, version, profile) = headerOf(full)
    if magic != Magic:
      echo "  [N/A]     ", f, " — not a CTFS container (magic ", magic, ")"
      na.inc
      continue
    if version == int(CtfsVersionV6):
      echo "  [ALREADY] ", f, "  ", full.len, " B, container 6 profile ", profile
      already.inc
      continue
    if version != int(CtfsVersion):
      echo "  [N/A]     ", f, " — container ", version,
        "; this conversion reads the version-", int(CtfsVersion),
        " member directory. A re-record is the operation for this one."
      na.inc
      continue

    var bytes = newSeq[byte](full.len)
    for i, c in full: bytes[i] = byte(c)
    let sel = selectProfile(bytes, threshold)
    if sel.isErr:
      echo "  [REFUSED] ", f, " — ", sel.error
      refused.inc
      continue
    let (prof, outBytes, raw) = sel.get
    if prof != cpCompact:
      # §1e's rule, applied: the raw members do not fit under the threshold, so
      # this container stays FULL. Not a refusal — the rule deciding.
      echo "  [FULL]    ", f, "  ", full.len, " B container ", version,
        "  — raw members ", raw, " B is not below the threshold ", threshold
      leftFull.inc
      continue
    var outStr = newString(outBytes.len)
    for i, b in outBytes: outStr[i] = char(b)
    let (_, v2, p2) = headerOf(outStr)
    if v2 != int(CtfsVersionV6) or p2 != 1:
      echo "  [REFUSED] ", f, " — the converted bytes are container ", v2,
        " profile ", p2, ", not container 6 profile 1"
      refused.inc
      continue
    echo "  [OK]      ", f, "  ", full.len, " B container ", version,
      "  ->  ", outStr.len, " B container 6 profile 1  (raw members ", raw, " B)"
    if not checkOnly: writeFile(f, outStr)
    converted.inc

  echo ""
  echo "compact ", converted, ", left full by §1e ", leftFull,
    ", already compact ", already, ", not applicable ", na,
    ", refused ", refused
  if checkOnly and converted > 0:
    echo "(--check: nothing was written)"
  if refused > 0: 1 else: 0

when isMainModule:
  quit(main())
