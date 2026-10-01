## rehearse/register.nim — the known-findings register, and why a rehearsal
## has one at all.
##
## A gate that reports is worth much less than one that refuses, and the
## rehearsal refuses. But on the day it is written it already has two true
## things to say about `dev`, and a gate that is red from its first commit gets
## turned off in a week. The way out is NOT to soften the gate; it is the shape
## `tools/journeys/known-survivors.json` and `ci/test/ci-coverage.known-dark.txt`
## already use in this repository:
##
##   **THE REGISTER FAILS IN BOTH DIRECTIONS.**
##
##   * a finding that OCCURS and is registered → reported, and does not fail
##   * a finding that occurs and is NOT registered → **fails**, by id
##   * a finding that is registered and does **not** occur → **fails**, by id,
##     demanding the entry be deleted
##
## The third rule is the one that makes this a register and not an exemption
## list. An entry cannot outlive the defect it records: the run that fixes the
## defect is the run that goes red asking for the entry to go. Nobody has to
## remember.
##
## AN ENTRY IS ONLY LEGITIMATE WITH ALL SIX FIELDS, and this module refuses the
## whole register rather than reading around a missing one — the same bar the
## journeys register sets, for the same reason: a register whose entries may be
## partial is a register whose entries stop being read.
##
##   reason    — what the rehearsal found, in its own terms
##   cause     — WHY, from readings and not from inference
##   subject   — what would make it stop happening, concretely enough to build
##   closed_by — who can produce that, and where the work lives
##   evidence  — what was measured, when, on what tree
##   recorded  — the date, so the debt is dated and not merely present

import std/[algorithm, json, os, sequtils, strutils, tables]

const requiredFields* = ["reason", "cause", "subject", "closed_by", "evidence",
                         "recorded"]

type
  RegisterEntry* = object
    id*: string
    reason*: string

  Register* = object
    path*: string
    entries*: OrderedTable[string, RegisterEntry]

  Reconciliation* = object
    excused*: seq[string]       ## occurred and registered
    unregistered*: seq[string]  ## occurred and not registered  → fail
    stale*: seq[string]         ## registered and did not occur → fail
    malformed*: seq[string]     ## entries missing a required field → fail

proc loadRegister*(path: string): Register =
  result.path = path
  result.entries = initOrderedTable[string, RegisterEntry]()
  if path.len == 0 or not fileExists(path): return
  let j = parseJson(readFile(path))
  if not j.hasKey("known_findings"): return
  for id, e in j["known_findings"]:
    result.entries[id] = RegisterEntry(id: id,
      reason: (if e.hasKey("reason"): e["reason"].getStr else: ""))

proc malformedEntries*(path: string): seq[string] =
  if path.len == 0 or not fileExists(path): return
  let j = parseJson(readFile(path))
  if not j.hasKey("known_findings"): return
  for id, e in j["known_findings"]:
    var missing: seq[string] = @[]
    for f in requiredFields:
      if not e.hasKey(f) or e[f].kind != JString or e[f].getStr.strip().len == 0:
        missing.add f
    if missing.len > 0:
      result.add id & " (missing: " & missing.join(", ") & ")"

proc reconcile*(occurred: seq[string], reg: Register, path: string): Reconciliation =
  result.malformed = malformedEntries(path)
  var seen = initTable[string, bool]()
  for id in occurred: seen[id] = true
  for id in occurred:
    if id in reg.entries: result.excused.add id
    else: result.unregistered.add id
  for id, _ in reg.entries:
    if id notin seen: result.stale.add id
  result.excused = result.excused.deduplicate()
  result.unregistered = result.unregistered.deduplicate()
  result.excused.sort(); result.unregistered.sort(); result.stale.sort()

func clean*(r: Reconciliation): bool =
  r.unregistered.len == 0 and r.stale.len == 0 and r.malformed.len == 0
