## `blocktracer-conformance` — the recorder conformance kit's one command.
##
## A recorder for a chain nobody has run yet needs to answer one question: *does the
## tree I just wrote validate?* Before this command there were two checks in the tree
## and neither could answer it. Both read a **published** tree —
## `blocktracer/validator.validateTree` walks `d/<chain>/current.json`, and
## `blocktracer_client/conformance.consumerConformance` reads the same layout through
## the SDK — while what a recorder writes is a
## `blocktracer/chain-snapshot@…` tree (Data-Contract.md §5.1). The step between the
## two is `chain/ingest.ingestSnapshot`, so the snapshot half of the answer existed
## only as a side effect of a whole-site build.
##
## ## THREE CHECKS, AND NOT ONE RULE IS RESTATED HERE
##
##   1. **snapshot -> verdict.** `ingestSnapshot` over the tree. It is the reader
##      itself, so §5's rules are enforced by the code the published site runs, not
##      by a copy. The rule ids and the §5 sections it cites come from
##      `tools/chain/snapshot-contract.json` through `contract_rules`, which is also
##      where `Data-Contract.md` §5.2b and §5.2c are rendered from — so a refusal
##      cannot name a rule the contract does not state, and this command cannot
##      print one either.
##   2. **published -> verdict, producer side.** `validateTree`, the same call
##      `blocktracer-validate` has wrapped since M5b.
##   3. **published -> verdict, consumer side.** `consumerConformance`, the same call
##      `blocktracer-client-conformance` wraps.
##
## The published tree checks 2 and 3 read is the one check 1 produced. That is what
## makes this a wrapper rather than a third implementation: there is no schema
## knowledge in this file at all, and the only thing it adds is the temporary
## directory the three checks are chained through.
##
## ## WHAT A FAILURE SAYS
##
## `Invalid tree` is not a report a recorder team can act on, so every refusal is
## reported as a **rule id** and an **offending path**. Neither is invented here:
##
##   * the rule id is read back out of the refusal's own citation prefix, matched
##     against `contractRuleIds()` — the set the contract states — so an unmatched
##     citation is reported as one rather than guessed at;
##   * the path is the file the refusal names. This command enumerates nothing and
##     maps nothing: it scans the refusal for a path under the tree it was given (or
##     under the directory it published into) and reports the longest. A refusal
##     that names no such file is reported as naming none, which is a defect in that
##     refusal and is visible here rather than silently rendered as a blank.
##
## Usage:
##   blocktracer-conformance --snapshot DIR [--out DIR] [--generation G] [--keep]
##
## Exits 0 when all three checks are clean, 1 when any refuses, 2 on a usage error
## or a missing snapshot tree.
##
## It reaches no network and needs no checkout: the contract is compiled into this
## binary (`contract_rules` reads the census with `staticRead`), and every path it
## opens is under the snapshot directory it was given or the directory it publishes
## into.

import std/[os, strutils]
import blocktracer/chain/ingest
import blocktracer/chain/contract_rules
import blocktracer/validator
import blocktracer/contract/version
import blocktracer_client/store
import blocktracer_client/conformance

proc usage() =
  stderr.writeLine """usage:
  blocktracer-conformance --snapshot DIR [--out DIR] [--generation G] [--keep]"""

proc citedRule(msg: string): string =
  ## The rule this refusal cites, or "". The set is the contract's, so a message
  ## that cited something else would be reported as citing nothing rather than
  ## having its own text promoted to a rule id.
  for id in contractRuleIds():
    if "[" in msg and (" " & id & "]") in msg: return id
  ""

proc namedPath(msg, snapshotDir, outDir: string): string =
  ## The longest path under `snapshotDir` or `outDir` that this refusal names.
  ##
  ## SCOPED TO THE TWO TREES ON PURPOSE. A refusal also names files that are part of
  ## the CONTRACT rather than of the subject — `tools/chain/snapshot-contract.json`,
  ## `tools/chain/migrate-refusal-reasons.mjs` — and a rule of the form "the longest
  ## token that exists on disk" would report one of those to a producer whose defect
  ## is in their own tree, whenever the command happened to be run from a checkout.
  ## A path this command reports is a path in the tree under test, always.
  var best = ""
  for raw in msg.splitWhitespace():
    var tok = raw.strip(chars = {'.', ',', ';', ':', ')', '(', '\'', '`', '"'})
    if tok.len == 0 or '/' notin tok: continue
    let underTree =
      tok.startsWith(snapshotDir) or tok.startsWith(outDir) or
      fileExists(snapshotDir / tok) or fileExists(outDir / tok)
    if underTree and tok.len > best.len: best = tok
  best

proc report(kind, msg, snapshotDir, outDir: string, knownPath = "",
            citesRules = true) =
  ## `knownPath` is a path the CALLER already holds, and it outranks the scan.
  ##
  ## THE SCAN IS A LAST RESORT AND WAS ONCE THE ONLY RESORT. It looks for a token
  ## in the sentence that exists on disk, which is the one thing a DANGLING
  ## REFERENCE — "this file is referenced and is not there" — can never satisfy.
  ## That is the commonest finding check 2 produces, so the commonest
  ## producer-side failure reported no path at all. Check 2's findings now arrive
  ## structured (`validator.ValidationFinding`) and hand their own path in here.
  ## Check 1's refusals are strings raised by the reader and still go through the
  ## scan, which is sound for them: a rule refusal names a file the reader has
  ## just opened.
  let rule = citedRule(msg)
  let path = if knownPath.len > 0: knownPath
             else: namedPath(msg, snapshotDir, outDir)
  stderr.writeLine kind & ":"
  stderr.writeLine "  rule: " &
    (if rule.len > 0: rule & " (" & sectionOf(rule) & ")"
     elif citesRules: "(this refusal cites no rule the contract states, which is " &
       "a defect in the refusal rather than in your tree)"
     else: "(this check enforces the PUBLISHED-tree contract, whose rules §5.2c " &
       "does not state — Data-Contract.md §5.5 says which check names what)")
  stderr.writeLine "  path: " &
    (if path.len > 0: path
     else: "(this refusal names no file in the tree under test)")
  stderr.writeLine "  said: " & msg

proc main() =
  var
    snapshotDir = ""
    outDir = ""
    generation = "1"
    keep = false
    pending = ""

  proc assign(k, v: string) =
    case k
    of "snapshot", "s": snapshotDir = v
    of "out", "o": outDir = v
    of "generation", "g": generation = v
    else: discard

  const valueFlags = ["snapshot", "s", "out", "o", "generation", "g"]
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a.startsWith("--") or (a.startsWith("-") and a.len == 2):
      var key = a.strip(leading = true, trailing = false, chars = {'-'})
      var val = ""
      if '=' in key:
        let j = key.find('=')
        val = key[j + 1 .. ^1]
        key = key[0 ..< j]
      case key
      of "help", "h": usage(); quit 0
      of "keep": keep = true
      else:
        if key notin valueFlags:
          stderr.writeLine "error: unknown flag " & a
          quit 2
        if val.len > 0: assign(key, val) else: pending = key
    else:
      if pending.len > 0: assign(pending, a); pending = ""
      else:
        stderr.writeLine "error: unexpected argument " & a
        quit 2
    inc i

  if snapshotDir.len == 0:
    usage(); quit 2

  # ── THE SUBJECT IS NORMALISED AT PARSE, AND THAT IS A DEFECT REPAIR ─────────
  #
  # `--snapshot ./dir` is the commonest spelling on a command line and it broke the
  # path half of every refusal. Nim's `/` NORMALISES as it joins, so `./dir` /
  # `snapshot.json` is `dir/snapshot.json` — the reader's refusals name that, while
  # `namedPath` below compared against the unnormalised `./dir` the user typed, and
  # `startsWith` therefore failed on the file the message had just named. The
  # command reported *"(this refusal names no file in the tree under test)"* over a
  # message whose text names it: rc 1, the rule right, the path blank.
  #
  # Nothing caught it because every arm in this repository passes an ABSOLUTE path,
  # and an absolute path is already in normal form. Normalising here makes the two
  # spellings one subject before anything downstream can disagree about it, and the
  # printed header says which tree was read rather than which characters were typed.
  snapshotDir = absolutePath(normalizedPath(snapshotDir))
  if outDir.len > 0: outDir = absolutePath(normalizedPath(outDir))

  # ── THE MISSING FIXTURE IS A FAILURE, NOT A CLEAN RUN ───────────────────────
  #
  # Every check below reports what it found wrong, so a run over a tree that is not
  # there finds nothing wrong and would print a verdict a recorder team would read
  # as a pass. That is the one input a conformance harness must not be quiet about,
  # and it is refused here, before the first check, by name.
  if not dirExists(snapshotDir):
    stderr.writeLine "error: no snapshot tree at " & snapshotDir &
      " — a conformance run with no fixture is not a pass"
    quit 2
  if not fileExists(snapshotDir / "snapshot.json"):
    stderr.writeLine "error: " & snapshotDir & " holds no snapshot.json" &
      " — Data-Contract.md §5.1: that one file is read by name, and a directory" &
      " without it is not a snapshot tree"
    quit 2

  # ── WHERE THE PUBLISHED TREE GOES ───────────────────────────────────────────
  #
  # Checks 2 and 3 walk whatever is in this directory, so it has to hold exactly
  # what check 1 published and nothing else — a stale tree beside it would be
  # judged as part of this run, and a slug it already carries is refused by
  # `S5-CHAIN-UNIQUE` for a reason that has nothing to do with the snapshot.
  #
  # THE DIRECTORY WE CHOSE IS CLEARED; A DIRECTORY THE CALLER NAMED IS NOT. A
  # command that silently deletes a path handed to it on the command line is one
  # mistyped flag away from being the worst thing in this kit, so a non-empty
  # `--out` is refused by name instead.
  var published = outDir
  var temporary = false
  if published.len == 0:
    published = getTempDir() / "blocktracer-conformance-" & $getCurrentProcessId()
    temporary = true
    removeDir published
  elif dirExists(published):
    for _ in walkDir(published):
      stderr.writeLine "error: " & published & " is not empty. Checks 2 and 3 walk" &
        " whatever is in it, so this run would judge somebody else's tree as well" &
        " as yours. Name an empty or absent directory, or omit --out and a" &
        " temporary one is used."
      quit 2
  createDir published

  echo "snapshot:  " & snapshotDir
  echo "published: " & published
  echo "contract:  " & $ContractVersion
  echo ""
  # ── WHAT THE THREE PHASES CHECK, BEFORE ANY OF THEM RUNS ────────────────────
  #
  # `[1/3] snapshot OK` followed by `[2/3] producer REFUSED` is the worst
  # ordering a producer can be given, and it was given without explanation: the
  # first line reads as a verdict on the tree that was written, so a green one
  # followed by twenty-four failures reads as the tool changing its mind. It is
  # not. Check 1 is the only one that reads the snapshot at all; checks 2 and 3
  # read the tree check 1 PUBLISHED, so a green [1/3] means "this snapshot could
  # be ingested", never "this snapshot is conforming".
  #
  # The count going UP as errors are fixed has the same cause and is equally
  # alarming without this: check 1 stops at its FIRST refusal, because it is the
  # reader and a reader that carried on would be reading a tree it had already
  # refused. Checks 2 and 3 collect ALL of their findings. So a tree that was
  # failing at [1/3] with one message and now fails at [2/3] with twenty-four has
  # got FURTHER, and the twenty-four were always there.
  echo "  [1/3] snapshot   your tree, through the reader — Data-Contract.md §5."
  echo "                   Stops at the FIRST refusal and names the §5.2c rule."
  echo "  [2/3] producer   the tree [1/3] published, against the published-tree"
  echo "                   contract. Collects EVERY finding; names paths, not §5 rules."
  echo "  [3/3] consumer   the same published tree, read end to end through the"
  echo "                   client SDK. Collects every finding."
  echo "  A green [1/3] is not a green tree: it means the snapshot was INGESTIBLE."
  echo "  A count that rises as you fix things means you reached a later phase."
  echo ""

  var failed = false

  # ── 1. snapshot -> verdict ──────────────────────────────────────────────────
  var ing: IngestResult
  try:
    ing = ingestSnapshot(IngestConfig(outDir: published, snapshotDir: snapshotDir,
                                      generation: generation, scope: isFull))
    echo "[1/3] snapshot   OK  chain=" & ing.chain & " blocks=" & $ing.blocks &
      " transactions=" & $ing.transactions & " traced=" & $ing.withTrace &
      " divergent=" & $ing.divergent
  except CatchableError as e:
    echo "[1/3] snapshot   REFUSED"
    report("REFUSED (Data-Contract.md §5)", e.msg, snapshotDir, published)
    failed = true

  if not failed:
    # ── 2. published -> verdict, producer side ────────────────────────────────
    let errs = validateTreeFindings(published)
    if errs.len == 0:
      echo "[2/3] producer   OK  " & published & " conforms to contract version " &
        $ContractVersion
    else:
      echo "[2/3] producer   REFUSED  " & $errs.len & " conformance error(s)"
      for e in errs:
        # THE PATH COMES FROM THE FINDING, NOT FROM A SCAN OF ITS SENTENCE. Every
        # one of these carries the tree-relative path it is about as a field, and
        # the file is `findingFile` of it — which is what makes a DANGLING
        # reference name a path, the one case the scan structurally cannot.
        let p = e.findingFile
        report("PRODUCER-SIDE", e.errorLine, snapshotDir, published,
               knownPath = (if p.len == 0: ""
                            elif p.isAbsolute: p
                            else: published / p),
               citesRules = false)
      failed = true

    # ── 3. published -> verdict, consumer side ────────────────────────────────
    let r = consumerConformance(localTree(published))
    if r.ok:
      echo "[3/3] consumer   OK  blocks=" & $r.blocksChecked &
        " transactions=" & $r.transactionsChecked &
        " traces=" & $r.tracesResolved & " replayable=" & $r.tracesReplayable
    else:
      echo "[3/3] consumer   REFUSED  " & $r.errors.len & " conformance error(s)"
      for e in r.errors:
        report("CONSUMER-SIDE", e, snapshotDir, published, citesRules = false)
      failed = true

  if temporary and not keep: removeDir published

  echo ""
  if failed:
    echo "VERDICT: this tree does NOT conform."
    quit 1
  echo "VERDICT: this tree conforms — it ingests, it validates, and a consumer can read it."
  quit 0

main()
