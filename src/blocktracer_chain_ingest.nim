## `blocktracer-chain-ingest` — the CLI for the REAL-chain producer.
##
## `src/blocktracer/chain/ingest.nim` has had exactly two callers since it was
## written: `client/src/static_export.nim`, which runs it at `isCurated` as one
## step of a whole-site build, and `tools/dev/dump_recorder_provenance.nim`,
## which is a diff harness. Neither can ingest a NAMED RANGE and report what it
## produced, which is what a coverage-by-ranges pipeline is made of — so the
## range operation had no command, and "ingest blocks 74000-74099" was a Nim
## snippet somebody wrote by hand each time.
##
## This is that command and nothing more: it parses flags, calls
## `ingestSnapshot`, and prints the `IngestResult` as JSON so a caller can read
## the numbers instead of scraping a build log. The scope defaults to `isFull`
## — the explorer's answer, every block the capture enumerated — because a range
## operation whose output silently shrank to a curated window would report
## coverage it did not publish.
##
## Usage:
##   blocktracer-chain-ingest --snapshot DIR --out DIR [--generation G]
##                            [--scope full|curated]

import std/[json, os, parseopt]
import blocktracer/chain/ingest

proc usage() =
  stderr.writeLine """usage:
  blocktracer-chain-ingest --snapshot DIR --out DIR [--generation G] [--scope full|curated]"""

proc main() =
  var
    snapshotDir = ""
    outDir = ""
    generation = ""
    scope = isFull
    pending = ""

  proc assign(k, v: string) =
    case k
    of "snapshot", "s": snapshotDir = v
    of "out", "o": outDir = v
    of "generation", "g": generation = v
    of "scope":
      case v
      of "full": scope = isFull
      of "curated": scope = isCurated
      else:
        stderr.writeLine "error: --scope must be 'full' or 'curated', got '" & v & "'"
        quit 2
    else: discard

  const valueFlags = ["snapshot", "s", "out", "o", "generation", "g", "scope"]
  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "help", "h": usage(); return
      else:
        if key in valueFlags:
          if val.len > 0: assign(key, val)
          else: pending = key
        else:
          stderr.writeLine "error: unknown flag --" & key
          quit 2
    of cmdArgument:
      if pending.len > 0: assign(pending, key); pending = ""
    else: discard

  if snapshotDir.len == 0 or outDir.len == 0:
    usage(); quit 2
  if not fileExists(snapshotDir / "snapshot.json"):
    stderr.writeLine "error: no snapshot.json under " & snapshotDir
    quit 2

  createDir outDir
  var ing: IngestResult
  try:
    ing = ingestSnapshot(IngestConfig(outDir: outDir, snapshotDir: snapshotDir,
                                      generation: generation, scope: scope))
  except CatchableError as e:
    # THE REFUSAL IS THE PRODUCT, not an error to swallow: `ingest.nim` raises
    # rather than publishing a half-ingested chain, and a range operation has to
    # be able to record WHICH range was refused and why.
    echo (%*{"ok": false, "snapshot": snapshotDir, "out": outDir,
             "error": e.msg, "errorType": $e.name}).pretty
    quit 1

  echo (%*{
    "ok": true,
    "snapshot": snapshotDir,
    "out": outDir,
    "chain": ing.chain,
    "scope": (if ing.scope == isFull: "full" else: "curated"),
    "blocks": ing.blocks,
    "transactions": ing.transactions,
    "withTrace": ing.withTrace,
    "divergent": ing.divergent,
    "pruned": ing.pruned,
    "containerBytes": ing.containerBytes,
    "observedBlocks": ing.observedBlocks,
    "observedTransactions": ing.observedTransactions,
    "windowFrom": ing.windowFrom,
    "windowTo": ing.windowTo,
  }).pretty

main()
