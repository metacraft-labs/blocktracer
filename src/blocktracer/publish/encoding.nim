## publish/encoding.nim — the brotli CODEC, and nothing else.
##
## The policy, the closed set, the magic test and every diagnosis live in
## `contract/container_encoding.nim`, which is PURE. This module is the half that needs a
## process, and the split is forced rather than tidy: `ci/test/client-sdk-boundary.sh`
## bans `osproc` from the Client SDK's graph ("spawns processes — an embeddable library
## cannot") and bans everything under `src/blocktracer/publish/` from it as well ("the
## publisher — writing of any kind is excluded"). So `blocktracer-client-conformance`
## cannot reach this module, by construction, and must not: see that module's header for
## why that is the right answer and what `storedBytes` / `storedHash` are for.
##
## ## Why the codec is a subprocess
##
## There is no brotli binding in Nim in this repository, and adding one would put a C
## dependency into three released binaries a recorder team must be able to run without a
## toolchain. So this shells out to `brotli`, the same way `objectstore.nim` shells out to
## `aws` and `verify/source.nim` to `curl`, and the devshell DECLARES it rather than
## inheriting whatever a runner happens to have on `PATH`.
##
## An absent `brotli` is a NAMED absence, never a silent identity pass: `encodeContainer`
## refuses to publish rather than storing raw bytes under a header that claims otherwise,
## and `decodeContainer` returns the reason so its caller can report NOT MEASURED.

import std/[os, osproc, strutils, times, hashes, streams]
import ../contract/container_encoding

export container_encoding

const
  BrotliQuality* = 11
    ## Maximum. These objects are written once and fetched many times, and every measured
    ## figure the compressor was chosen on is `-q 11` — so anything else would make the
    ## published bytes a different measurement from the one that decided.

proc brotliPath*(): string =
  ## Where `brotli` is, or `""`. Resolved per call rather than cached, because a caller may
  ## be handed a `PATH` that changed between its checks and a stale "absent" would turn a
  ## runnable check into a permanent NOT MEASURED.
  findExe("brotli")

func brotliAbsentReason*(): string =
  "`brotli` is not on PATH, so these bytes could not be decoded. Either put it on PATH " &
  "(the devshell declares it) or obtain the object with encoding negotiation " &
  "(`curl --compressed`, or any browser), which yields the container itself"

proc tmpName(tag, seed: string): string =
  getTempDir() / "bt-enc-" & tag & "-" & $getCurrentProcessId() & "-" &
    $epochTime().int64 & "-" & $(cast[uint](seed.hash) mod 1_000_000'u)

proc runBrotli(args: seq[string]): tuple[output: string, code: int] =
  ## stdout and stderr merged, which is right here: neither direction writes bytes to
  ## stdout — both write to a FILE — so the only thing a caller wants from the process is
  ## its diagnostic. That is the distinction `objectstore.nim` draws between its `run` and
  ## its `runBytes`, and this module only ever needs the first.
  let bin = brotliPath()
  if bin.len == 0: return ("", -1)
  let p = startProcess(bin, args = args, options = {poUsePath, poStdErrToStdOut})
  p.inputStream.close()
  let outp = p.outputStream.readAll()
  let code = p.waitForExit()
  p.close()
  (outp, code)

proc encodeContainer*(bytes: string, enc: ContainerEncoding):
    tuple[data: string, ok: bool, why: string] =
  ## Raw container bytes -> the bytes to STORE.
  ##
  ## Through temp FILES and not a pipe. The reason is recorded next door in
  ## `objectstore.nim`'s `putIfAbsent`: a blob handed to a tool through a non-seekable
  ## `/dev/stdin` fails during argument parsing, before a request is made, and the failure
  ## reads like something else entirely. `brotli`'s stdin mode does work — but a megabyte
  ## through a pipe needs the child's stdin and stdout pumped concurrently or it deadlocks,
  ## and a file is one line.
  if enc == ceIdentity: return (bytes, true, "")
  if brotliPath().len == 0:
    return ("", false,
            "cannot store a container with Content-Encoding '" & $enc & "': " &
            brotliAbsentReason())
  let src = tmpName("enc", bytes)
  let dst = src & "." & $enc
  try:
    writeFile(src, bytes)
    let (outp, code) = runBrotli(@["-q", $BrotliQuality, "-f", "-o", dst, src])
    if code != 0 or not fileExists(dst):
      return ("", false, "brotli -q " & $BrotliQuality & " exited " & $code & ": " & outp.strip)
    (readFile(dst), true, "")
  finally:
    removeFile(src)
    removeFile(dst)

proc decodeContainer*(stored: string, enc: ContainerEncoding):
    tuple[data: string, ok: bool, why: string] =
  ## The bytes at rest -> the raw container: what a negotiating consumer would have
  ## received, and what the format reader parses.
  if enc == ceIdentity: return (stored, true, "")
  if brotliPath().len == 0:
    return ("", false, brotliAbsentReason())
  let src = tmpName("dec", stored)
  let dst = src & ".raw"
  try:
    writeFile(src, stored)
    let (outp, code) = runBrotli(@["-d", "-f", "-o", dst, src])
    if code != 0 or not fileExists(dst):
      return ("", false, "brotli -d exited " & $code & ": " & outp.strip)
    (readFile(dst), true, "")
  finally:
    removeFile(src)
    removeFile(dst)
