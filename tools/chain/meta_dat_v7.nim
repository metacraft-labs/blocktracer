## meta_dat_v7.nim — regenerate a `meta.dat` schema-6 container as schema 7.
##
## WHY THIS IS A REGENERATION AND NOT A GUESS. `meta.dat` version 7 changed no
## byte of the header: the version moved only so that a version-6 READER refuses
## a trace whose `events.dat` may carry the `EventLogKind` values 14-23
## (`codetracer-trace-format-spec/internal-files.md` §"Metadata (meta.dat)",
## Version History v7; `codetracer` `src/db-backend/src/ctfs_trace_reader/
## meta_dat.rs`: "v7 — 2026-10: no byte of the header changed"). A version-6
## trace was written against the fourteen-kind table, so it cannot carry those
## values, and the same bytes with the version field set to 7 are a valid
## version-7 trace of the same execution. Nothing else is touched: every other
## member's payload is copied verbatim, and the container is laid out again by
## the pinned trace-format library (`encodeCompactContainer`) under the
## original's whole-file compression.
##
## VERIFIED BEFORE IT IS WRITTEN. Every regenerated container is decoded in
## full by the pinned reader (`openNewTraceFromBytes`, which reads version 6
## containers in both profiles and `meta.dat` 7 only): every path, every step
## with its values, every call, every I/O event and the whole step map, the
## walk `tests/test_version_6_containers_read.nim` uses. A container that does
## not decode is reported and not written.
##
## WHAT IT REFUSES. Anything but a compact (container version 6) image; a
## `meta.dat` that is missing, lacks the `CTMD` magic, or is at a version other
## than 6 (a 7 is reported as already done and left alone); a container that
## carries no events member at all. The result is verified by the caller with
## the pinned reader (`ct-print`), which reads version 7 only.
##
## Usage: meta_dat_v7 [--check] FILE.ct...

import std/[os, strutils]
import results
import codetracer_ctfs/types
import codetracer_ctfs/compact
from codetracer_ctfs/container import readWholeFileCompression
import codetracer_trace_writer/[new_trace_reader, step_map_builder, step_encoding,
  value_stream, call_stream, io_event_stream]

const
  MetaMember = "meta.dat"
  FromVersion = 6'u16
  ToVersion = 7'u16

proc toBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc toStr(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc regenerate(stored: seq[byte]): Result[(seq[byte], string), string] =
  ## The schema-7 container for `stored`, and a one-line account of it.
  if stored.len < 6 or stored[5] != CtfsVersionV6:
    return err("not a version-6 (compact) container")
  let scheme = ? readWholeFileCompression(stored)
  let image = ? reconstructImage(stored)
  var members = ? decodeCompactContainer(image, bodyReconstructed = scheme != wfcNone)
  var meta = -1
  for i, m in members:
    if m.name == MetaMember: meta = i
  if meta < 0:
    return err("no meta.dat member")
  let p = members[meta].payload
  if p.len < 6 or p[0] != byte('C') or p[1] != byte('T') or p[2] != byte('M') or
      p[3] != byte('D'):
    return err("meta.dat has no CTMD magic")
  let version = uint16(p[4]) or (uint16(p[5]) shl 8)
  if version == ToVersion:
    return ok((stored, "already meta.dat 7"))
  if version != FromVersion:
    return err("meta.dat schema " & $version & "; this regenerates 6 only")
  members[meta].payload[4] = byte(ToVersion and 0xff)
  members[meta].payload[5] = byte(ToVersion shr 8)
  let laidOut = ? encodeCompactContainer(members)
  let outBytes = if scheme == wfcNone: laidOut else: ? compressImage(laidOut)
  ok((outBytes, "meta.dat 6 -> 7, " & $members.len & " members, " &
     $stored.len & " -> " & $outBytes.len & " B"))

proc verify(data: seq[byte]): Result[string, string] =
  ## Decode `data` in full with the pinned reader; the counts it read.
  var r = ? openNewTraceFromBytes(data)
  var paths, values, calls, events = 0'u64
  for i in 0'u64 ..< r.pathCount():
    discard ? r.path(i)
    inc paths
  let n = ? r.stepCount()
  for i in 0'u64 ..< n:
    discard ? r.step(i)
    discard ? r.stepAbsoluteGlobalLineIndex(i)
    values += uint64((? r.values(i)).len)
  for k in 0'u64 ..< (? r.callCount()):
    discard ? r.call(k)
    inc calls
  for k in 0'u64 ..< (? r.ioEventCount()):
    discard ? r.ioEvent(k)
    inc events
  # The step map is an optional member; recordings made before the writer
  # emitted it carry none, and its absence is reported rather than refused.
  let scheme = ? readWholeFileCompression(data)
  let names = ? compactMemberNames(? reconstructImage(data),
                                   bodyReconstructed = scheme != wfcNone)
  var stepMap = "no step map"
  if "step-map.ns" in names:
    var m = ? openStepMapIn(data)
    var lines = 0
    for ln in ? m.loadAll():
      if ? m.lookup(ln.pathId, uint64(ln.line)) != ln.steps:
        return err("the step map's lookup disagrees with its own listing")
      inc lines
    stepMap = "step map " & $lines & " lines"
  ok("decoded: " & $paths & " paths, " & $n & " steps, " & $values &
     " values, " & $calls & " calls, " & $events & " events, " & stepMap)

proc main(): int =
  var check = false
  var files: seq[string]
  for a in commandLineParams():
    if a == "--check": check = true
    else: files.add a
  if files.len == 0:
    stderr.writeLine "usage: meta_dat_v7 [--check] FILE.ct..."
    return 2
  for f in files:
    let r = regenerate(toBytes(readFile(f)))
    if r.isErr:
      stderr.writeLine f, ": ", r.error
      result = 1
      continue
    let (bytes, account) = r.get
    let decoded = verify(bytes)
    if decoded.isErr:
      stderr.writeLine f, ": regenerated but does not decode: ", decoded.error
      result = 1
      continue
    echo f, ": ", account, "; ", decoded.get
    if not check and not account.startsWith("already"):
      writeFile(f, toStr(bytes))

when isMainModule:
  quit(main())
