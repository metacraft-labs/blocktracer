## `blocktracer-verify-published` — is all the data actually on the published
## instance?
##
## A read-only audit of a LIVE tree: the CDN, the bucket behind it, or a local
## store directory. It answers in a bounded number of requests — the design and
## the sampling argument are in `blocktracer/verify/audit.nim`'s header, which is
## where they belong because that is where they are implemented.
##
## Usage:
##   blocktracer-verify-published --url https://blocktracer.org [options]
##   blocktracer-verify-published --backend s3 --bucket NAME [--endpoint URL] [--prefix P]
##   blocktracer-verify-published --backend local --dest DIR
##
## Expectations (the audit compares the instance against something OUTSIDE it):
##   --tree DIR         a producer tree: its registry names the expected chains,
##                      its per-class counts are the census expectation, and any
##                      sampled object it also holds is compared BYTE FOR BYTE
##   --expect-chain C   repeatable; overrides the tree's chain list
##   --ledger FILE      the range ledger `tools/chain/ingest-range.mjs` writes
##                      (its --state DIR holds `coverage.json`). This is what
##                      makes the whole-range check exhaustive instead of sampled.
##
## Sampling:
##   --samples N        interior heights probed per chain (default 400). The run
##                      prints the omission rate this detects at 99% confidence.
##
## Tolerances and escapes — each one VISIBLE in the output and on the exit line:
##   --tolerance PCT    census shortfall allowed per class (default 0)
##   --skip ID          do not run this check at all
##   --allow-unrunnable ID   a check that cannot run here does not fail the run
##
## Exit: 0 clean · 1 a finding · 2 usage · 3 the instrument voided the run.
##
## IT NEVER WRITES. It holds a `verify/source.Source`, which has no write
## operation, and `ci/test/verify-published-readonly.sh` refuses one being added.
## Running it against production repeatedly is safe by construction, not by care.

import std/[os, parseopt, strutils, strformat]

import blocktracer/verify/[source, audit]

proc usage() =
  stderr.writeLine """usage:
  blocktracer-verify-published --url URL            [expectations] [options]
  blocktracer-verify-published --backend s3 --bucket NAME [--endpoint URL] [--prefix P]
  blocktracer-verify-published --backend local --dest DIR

expectations:
  --tree DIR              producer tree: chains, per-class counts, byte identity
  --expect-chain C        repeatable
  --ledger FILE           range ledger (coverage.json) — makes the range check exhaustive

options:
  --samples N             interior heights per chain (default 400)
  --tolerance PCT         census shortfall allowed per class (default 0)
  --skip ID               do not run check ID
  --allow-unrunnable ID   ID may report UNRUNNABLE without failing the run
  --json                  machine-readable report on stdout

checks: INSTRUMENT REGISTRY POINTER PROFILE LEDGER RANGE CENSUS CACHE"""

proc main() =
  var
    url = ""
    backend = ""
    dest = ""
    bucket = ""
    endpoint = ""
    prefix = ""
    asJson = false
    opts = defaultAuditOptions()

  var pending = ""
  proc assign(k, v: string) =
    case k
    of "url": url = v
    of "backend", "b": backend = v
    of "dest", "d": dest = v
    of "bucket": bucket = v
    of "endpoint": endpoint = v
    of "prefix": prefix = v
    of "tree", "t": opts.treeDir = v
    of "ledger": opts.ledgerPath = v
    of "expect-chain": opts.expectChains.add v
    of "skip": opts.skip.add v
    of "allow-unrunnable": opts.allowUnrunnable.add v
    of "samples":
      try: opts.samples = parseInt(v)
      except CatchableError: (stderr.writeLine "error: --samples wants an integer"; quit 2)
    of "tolerance":
      try: opts.tolerancePct = parseFloat(v)
      except CatchableError: (stderr.writeLine "error: --tolerance wants a number"; quit 2)
    else: discard
  const valueFlags = ["url", "backend", "b", "dest", "d", "bucket", "endpoint",
                      "prefix", "tree", "t", "ledger", "expect-chain", "skip",
                      "allow-unrunnable", "samples", "tolerance"]

  var p = initOptParser()
  for kind, key, val in p.getopt():
    case kind
    of cmdLongOption, cmdShortOption:
      case key
      of "json": asJson = true
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
    else: discard

  for id in opts.skip & opts.allowUnrunnable:
    if id notin AllChecks:
      stderr.writeLine "error: '" & id & "' is not a check. One of: " &
        AllChecks.join(" ")
      quit 2

  if backend.len == 0: backend = if url.len > 0: "http" else: ""
  var src: Source
  case backend
  of "http":
    if url.len == 0: (stderr.writeLine "error: --url is required"; quit 2)
    src = newHttpSource(url)
  of "s3", "r2":
    if bucket.len == 0: (stderr.writeLine "error: s3 backend needs --bucket"; quit 2)
    src = newS3Source(bucket, prefix, endpoint)
  of "local":
    if dest.len == 0: (stderr.writeLine "error: local backend needs --dest DIR"; quit 2)
    if not dirExists(dest):
      stderr.writeLine "error: --dest '" & dest & "' is not a directory"
      quit 2
    src = newLocalSource(dest)
  else:
    stderr.writeLine "error: say where to look — --url, or --backend s3|local"
    usage(); quit 2

  if opts.treeDir.len > 0 and not dirExists(opts.treeDir):
    stderr.writeLine "error: --tree '" & opts.treeDir & "' is not a directory"
    quit 2

  let rep = runAudit(src, opts)
  let code = exitCodeFor(rep, opts)

  if asJson:
    echo "{"
    echo "  \"format\": \"blocktracer/published-verification@1\","
    echo "  \"target\": \"", src.describe(), "\","
    echo &"  \"samples\": {opts.samples},"
    echo &"  \"detectionPower\": {rep.detectionPower:.6f},"
    echo "  \"instrumentVoid\": ", (if rep.instrumentVoid: "true" else: "false"), ","
    echo "  \"checks\": ["
    for i, c in rep.checks:
      echo "    {\"id\": \"", c.id, "\", \"state\": \"", $c.state,
           "\", \"findings\": ", $c.findings.len, "}",
           (if i < rep.checks.high: "," else: "")
    echo "  ],"
    echo &"  \"exit\": {code}"
    echo "}"
  else:
    echo "blocktracer-verify-published — ", src.describe()
    echo ""
    for c in rep.checks:
      echo align($c.state, 10), "  ", c.id, " — ", c.title
      for n in c.notes: echo "              · ", n
      for f in c.findings: echo "              ! ", f
    echo ""
    echo &"sampling: {opts.samples} interior height(s) per chain ⇒ detects a " &
         &"uniform omission rate of {rep.detectionPower * 100:.2f}% or more at " &
         "99% confidence."
    echo "          Range boundaries, the floor and the tip are taken " &
         "exhaustively, not sampled, and the LEDGER check compares the whole " &
         "range with no fetching at all."
    if opts.skip.len > 0:
      echo "SKIPPED (by request, not by evidence): ", opts.skip.join(" ")
    if opts.allowUnrunnable.len > 0:
      echo "UNRUNNABLE ALLOWED (by request): ", opts.allowUnrunnable.join(" ")

  if rep.instrumentVoid:
    stderr.writeLine "VOID: this host answers for paths it does not hold, so " &
      "nothing else this run could have measured would mean anything."
  quit code

main()
