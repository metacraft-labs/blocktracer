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
##                            [--scope full|curated|curatedIfWhole]
##                            [--container-encoding br|identity]
##
## `curatedIfWhole` is what the SITE BUILD runs, and it is accepted here so that
## "why did this capture publish every transaction" is answerable by hand with
## one command instead of by reading a build log. It prints the scope it CHOSE
## plus `scopeFellBack`, so the answer is in the output rather than inferred
## from the counts.

## `--container-encoding` DEFAULTS TO `br`, AND THAT IS NOT THIS CLI'S OWN
## OPINION — it is the shape the site build already publishes.
##
## `IngestConfig.containerEncoding`'s zero value is `ceIdentity`, and its
## comment explains the caution: "reader support ships everywhere before any
## writer emits it … storing compressed bytes is correct only once the delivery
## layer SERVES the `Content-Encoding`". That condition is met now —
## `publisher.encodingOf` sets the object's `Content-Encoding` from the
## manifest, `tools/lib/stored-encoding.mjs` does the same for every local
## server the captures and journeys run against, and `_headers` carries it for
## the static hosts — and `static_export.nim` has been publishing `ceBrotli`
## since. This CLI was left on the zero value, so the two producers of a
## published tree disagreed: MEASURED on `aztec-testnet-frames`, the site build
## writes a container of 54,132 bytes as 3,652 brotli bytes with
## `container.encoding: "br"` in its manifest, and this CLI wrote the same kind
## of object raw with no encoding field.
##
## Both are readable — a raw object with no declared encoding is served raw and
## the engine opens it — so nothing was broken. What was wrong is that the
## operator path and the build path produced DIFFERENT trees for one chain, and
## the operator's was 15x larger over the wire. `identity` stays reachable by
## name for the case the zero value existed for: publishing into a store whose
## delivery layer does not set the header.

import std/[json, os, parseopt]
import blocktracer/chain/ingest
import blocktracer/contract/container_encoding

proc usage() =
  stderr.writeLine """usage:
  blocktracer-chain-ingest --snapshot DIR --out DIR [--generation G]
                           [--scope full|curated|curatedIfWhole]
                           [--container-encoding br|identity]"""

proc main() =
  var
    snapshotDir = ""
    outDir = ""
    generation = ""
    scope = isFull
    encoding = ceBrotli
    pending = ""

  proc assign(k, v: string) =
    case k
    of "snapshot", "s": snapshotDir = v
    of "out", "o": outDir = v
    of "generation", "g": generation = v
    of "container-encoding":
      let parsed = parseContainerEncoding(v)
      if not parsed.ok:
        stderr.writeLine "error: " & parsed.why
        quit 2
      encoding = parsed.enc
    of "scope":
      case v
      of "full": scope = isFull
      of "curated": scope = isCurated
      of "curatedIfWhole": scope = isCuratedIfWhole
      else:
        stderr.writeLine "error: --scope must be 'full', 'curated' or " &
          "'curatedIfWhole', got '" & v & "'"
        quit 2
    else: discard

  const valueFlags = ["snapshot", "s", "out", "o", "generation", "g", "scope",
                      "container-encoding"]
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
                                      generation: generation, scope: scope,
                                      containerEncoding: encoding))
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
    # THE SCOPE THAT WAS APPLIED, which under `curatedIfWhole` is not the one
    # asked for. `scopeFellBack` beside it is what says a choice happened — the
    # two together answer "what did this publish, and was that decided or
    # stated", which one field cannot.
    "scope": (if ing.scope == isFull: "full" else: "curated"),
    "scopeFellBack": ing.scopeFellBack,
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
