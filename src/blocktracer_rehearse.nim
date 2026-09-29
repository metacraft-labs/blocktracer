## `blocktracer-rehearse` — a publish rehearsal whose **sufficiency is
## measured**, not assumed from its size.
##
## ## The problem it exists for
##
## Rehearsing the whole corpus does not scale. Aztec is the first chain and is
## a small one; a full dress rehearsal of the tree that will exist for a large
## chain is not something anybody will run before a deploy, and a rehearsal
## nobody runs defends nothing. The obvious answer — "run a smaller one" —
## fails for a reason that was measured on 2026-09-28 rather than argued: a
## **290-object** rehearsal passed, and a **460,589-object** one then found a
## data-loss defect. The difference was not the 460,299 objects. It was that
## the small one had **one chain**, and one chain cannot overwrite another
## chain's registry row. The defect needed **cardinality ≥ 2**. No amount of
## scale on one chain would ever have reached it.
##
## So the flag that matters is not how big. It is **what is covered**:
##
##     blocktracer-rehearse --tree DIR --mode partial
##     blocktracer-rehearse --tree DIR --mode full
##
## and BOTH of them are checked against the same coverage contract, and both of
## them can fail it. A `--mode full` rehearsal of a one-chain corpus fails on
## `cardinality/chains-in-separate-trees` exactly as the partial one does,
## which is the whole claim this tool makes: **a partial rehearsal that meets
## the contract is better evidence than a full one that does not.**
##
## ## What the contract contains
##
## `rehearse/coverage.nim` holds it, with the property each cell defends. In
## outline: every object class `publisher.classOf` can emit (generated from the
## enum, so a new class becomes a required cell with nobody remembering);
## every upload strategy; cardinality ≥ 2 wherever a singleton could be
## clobbered; **both sides** of every conditional on the publish path; and the
## whole-system invariants in **both directions** — accepting a legitimate tree
## as well as refusing an illegitimate one.
##
## An unexercised cell is a **failure**, not a percentage. The report is a
## table of what was exercised and the witness that exercised it, because
## "97% covered" is a claim about a denominator nobody has seen and
## `class/ocTraceContainer  A4: t/bu/mz/…/trace.ct` is a claim somebody can go
## and check.
##
## ## What it does NOT do
##
## It does not reach a network, it takes no credential, and it cannot be aimed
## at production: every store it writes to is a directory it created under
## `--work`. Whether a PUBLISHED tree is complete is a different question asked
## of a different artefact, and `blocktracer-verify-published` asks it.
##
## ## Usage
##
##   blocktracer-rehearse --tree DIR [--tree DIR ...] [--mode partial|full]
##                        [--per-bucket N] [--work DIR] [--keep]
##                        [--no-derive] [--known-findings PATH] [--json PATH]
##
##   --tree DIR         a producer tree. Repeat it: two chains arriving as two
##                      trees is the shape the registry defect needs, and a
##                      corpus that has it does not need the derivation.
##   --mode             partial (default) | full
##   --per-bucket N     partial only: how many keys to take from each
##                      (class, chain, generation) bucket, spread across it so
##                      the first and last are always in. Default 3.
##   --no-derive        do not construct the shapes the corpus lacks. This is
##                      how you ask "is my real corpus sufficient on its own?"
##                      and get a refusal naming exactly what it is missing.
##   --known-findings   a register of findings that are known-live, which fails
##                      in BOTH directions (see rehearse/register.nim).
##   --json PATH        machine-readable result beside the human one.
##
## Exit: 0 met and clean · 1 coverage not met, or a finding · 2 usage.

import std/[json, os, parseopt, strutils, tables, times]

import blocktracer/rehearse/coverage
import blocktracer/rehearse/corpus
import blocktracer/rehearse/drill
import blocktracer/rehearse/register

proc usage() =
  stderr.writeLine """usage:
  blocktracer-rehearse --tree DIR [--tree DIR ...] [--mode partial|full]
                       [--per-bucket N] [--work DIR] [--keep] [--no-derive]
                       [--known-findings PATH] [--json PATH]"""

proc main() =
  var
    trees: seq[string] = @[]
    opts = defaultDrillOptions()
    keep = false
    knownPath = ""
    jsonPath = ""

  var pending = ""
  const valueFlags = ["tree", "mode", "per-bucket", "work", "known-findings",
                      "json"]
  proc assign(k, v: string) =
    case k
    of "tree": trees.add v
    of "mode":
      case v
      of "partial": opts.mode = rmPartial
      of "full": opts.mode = rmFull
      else:
        stderr.writeLine "error: --mode must be 'partial' or 'full', not '" & v & "'"
        quit 2
    of "per-bucket": opts.perBucket = parseInt(v)
    of "work": opts.workDir = v
    of "known-findings": knownPath = v
    of "json": jsonPath = v
    else: discard

  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "keep": keep = true
      of "no-derive": opts.derive = false
      of "help", "h": usage(); return
      else:
        if key in valueFlags:
          if val.len > 0: assign(key, val)
          else: pending = key
        else:
          stderr.writeLine "error: unknown flag --" & key
          usage(); quit 2
    of cmdArgument:
      if pending.len > 0: assign(pending, key); pending = ""
      else:
        stderr.writeLine "error: unexpected argument '" & key & "'"
        usage(); quit 2
    else: discard

  if trees.len == 0:
    stderr.writeLine "error: at least one --tree DIR is required"
    usage(); quit 2
  for t in trees:
    if not dirExists(t):
      stderr.writeLine "error: --tree '" & t & "' is not a directory"
      quit 2
  if opts.perBucket < 1:
    stderr.writeLine "error: --per-bucket must be at least 1"
    quit 2

  var madeWork = false
  if opts.workDir.len == 0:
    opts.workDir = getTempDir() / "bt-rehearse-" & $getCurrentProcessId()
    madeWork = true

  echo "blocktracer-rehearse — mode ", $opts.mode
  echo "  corpus      : ", trees.len, " tree(s)"
  for t in trees: echo "                ", t
  echo "  work        : ", opts.workDir
  echo ""

  let report = runDrill(trees, opts)

  if report.derivations.len > 0:
    echo "DERIVATIONS — shapes the corpus could not supply, constructed by the drill:"
    for d in report.derivations:
      echo "  + ", d.what
      echo "      ", d.why
    echo ""

  echo "SELECTION"
  echo "  objects in corpus   : ", report.objectsConsidered
  echo "  objects rehearsed   : ", report.objectsSelected,
       (if report.objectsConsidered > 0:
          "  (" & $(report.objectsSelected * 100 div report.objectsConsidered) & "%)"
        else: "")
  echo ""
  echo "SCENARIOS"
  for s in report.scenariosRun: echo "  · ", s
  echo ""
  echo "COVERAGE — what was exercised, and by what"
  echo report.ledger.renderTable()
  echo "  met ", report.ledger.met(), " / ", report.ledger.cells.len, " cells"

  # Unexercised cells and wrong outcomes are both findings; they are kept
  # distinct by their id prefix, because "nobody measured this" and "this is
  # broken" send the next reader to different places.
  var occurred: seq[string] = @[]
  for id in report.ledger.findingIds(): occurred.add "coverage/" & id
  for f in report.findings: occurred.add f.id

  if report.ledger.unmet().len > 0:
    stdout.write report.ledger.renderUnmet()

  if report.findings.len > 0:
    echo "\nFINDINGS — " & $report.findings.len & " thing(s) the rehearsal found WRONG:\n"
    for f in report.findings:
      echo "  ✗ [", f.id, "] ", f.title
      for line in f.detail.splitLines(): echo "      ", line
      echo ""

  let reg = loadRegister(knownPath)
  let rec = reconcile(occurred, reg, knownPath)

  if knownPath.len > 0:
    echo "REGISTER — ", knownPath
    if rec.excused.len > 0:
      echo "  known-live, not failing this run:"
      for id in rec.excused: echo "    · ", id
    if rec.stale.len > 0:
      echo "  REGISTERED AND DID NOT OCCUR — delete these entries:"
      for id in rec.stale: echo "    ! ", id
    if rec.malformed.len > 0:
      echo "  MALFORMED ENTRIES — every entry needs all six fields:"
      for m in rec.malformed: echo "    ! ", m
    if rec.unregistered.len > 0:
      echo "  NOT REGISTERED:"
      for id in rec.unregistered: echo "    ! ", id
    echo ""

  if jsonPath.len > 0:
    var cells = newJArray()
    for id, c in report.ledger.cells:
      cells.add %*{"id": id, "hits": c.hits, "witness": c.witness}
    var fs = newJArray()
    for f in report.findings:
      fs.add %*{"id": f.id, "title": f.title, "detail": f.detail}
    writeFile(jsonPath, (%*{
      "mode": $opts.mode,
      "generatedAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
      "trees": %trees,
      "objectsConsidered": report.objectsConsidered,
      "objectsSelected": report.objectsSelected,
      "scenarios": %report.scenariosRun,
      "cells": cells,
      "findings": fs,
      "occurred": %occurred,
      "register": %*{"excused": %rec.excused, "unregistered": %rec.unregistered,
                     "stale": %rec.stale, "malformed": %rec.malformed}
    }).pretty & "\n")

  if not keep and madeWork:
    removeDir opts.workDir
  elif keep:
    echo "work kept at ", opts.workDir

  let ok =
    if knownPath.len > 0: rec.clean()
    else: occurred.len == 0
  if ok:
    # The number stated is the one that was MEASURED, and the excused findings
    # are named in the same line rather than rounded away. "36 cells exercised"
    # over a run that exercised 35 and excused one is the shape of sentence a
    # register exists to stop producing.
    echo "REHEARSAL SUFFICIENT — ", report.ledger.met(), " of ",
         report.ledger.cells.len, " contract cells exercised",
         (if rec.excused.len > 0:
            ", " & $rec.excused.len & " known finding(s) excused by the register (" &
            rec.excused.join(", ") & ")"
          else: ", no finding"), "."
    quit 0
  else:
    stderr.writeLine "\nREHEARSAL INSUFFICIENT — " &
      $(if knownPath.len > 0: rec.unregistered.len + rec.stale.len + rec.malformed.len
        else: occurred.len) &
      " unexcused finding(s). A rehearsal is trusted because nothing is " &
      "untouched and nothing it touched was wrong; this one cannot claim either."
    quit 1

main()
