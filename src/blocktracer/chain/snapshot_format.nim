## chain/snapshot_format.nim
##
## The reader's half of the snapshot's version policy — Data-Contract.md §5.2.
##
## ## Why this file reads bytes instead of declaring a string
##
## For the reason `refusal_reasons.nim` beside it gives, and the cost here is the
## same shape. The producer's half is `tools/chain/lib/snapshot-format.mjs`; both
## halves read `tools/chain/snapshot-format.json`, this one with `staticRead` at
## COMPILE time, so a token added there is readable here without anybody
## remembering to copy it and a malformed policy fails the BUILD rather than
## producing a gate that waves everything through.
##
## The gate was previously a bare `!=` against a literal in `ingest.nim`, with
## the same literal spelled at four producers, two consumers, one test helper and
## three committed fixtures. What that arrangement cannot express is precisely
## what happened: `refusalReason` became MANDATORY on every untraced row while
## every one of those ten sites went on saying `@1`, so the token named two
## incompatible shapes and nothing in an artifact could say which it was.
##
## ## What `@2` is, and what the reader does with `@1`
##
## `@2` requires `transactions[].refusalReason` on every untraced row. `@1` left
## it optional, and this reader is the one that treated it as optional — which is
## why the bump is not cosmetic and also why `@1` stays readable: the only member
## `@2` adds is one this side already tolerated the absence of.
##
## §3's rule is that a version the reader does not support is refused BY NAME
## rather than misread, and §5.2's that an unknown token is never partially read.
## `@1` is neither unknown nor partially read — it is enumerated in `readable`
## and every member of it is consumed. What changes is that on `@2` the reader
## ENFORCES the member, which is what makes the token a checkable statement about
## the tree rather than a label on it.
##
## ## The outcome partition is here because the gate needs it
##
## "Every untraced row carries a reason" is only checkable against a definition
## of untraced, and the three populations are not interchangeable: a traced row
## must carry NO reason id, an untraced one must carry one, and a chain-absent
## row (Aztec's private half) must carry a SENTENCE and no id at all. The
## producer side reads the same three lists out of the same file.

import std/[json, strutils]

const snapshotFormatJson = staticRead("../../../tools/chain/snapshot-format.json")

type
  SnapshotFormatPolicy* = object
    current*: string             ## the token a producer in this tree writes
    readable*: seq[string]       ## every token this build can read, in order
    mandatoryRefusalReason*: seq[string]
      ## the tokens on which `transactions[].refusalReason` is required
    traced*: seq[string]
    untraced*: seq[string]
    chainAbsent*: seq[string]

proc parseSnapshotFormat(): SnapshotFormatPolicy =
  let doc = parseJson(snapshotFormatJson)
  if doc{"format"}.getStr != "blocktracer/snapshot-format@1":
    raise newException(ValueError,
      "tools/chain/snapshot-format.json declares format '" &
      doc{"format"}.getStr & "', and this module only knows " &
      "blocktracer/snapshot-format@1. A half-read version gate is no gate.")
  result.current = doc{"current"}.getStr
  if result.current.len == 0:
    raise newException(ValueError,
      "tools/chain/snapshot-format.json names no `current` token.")
  for t in doc{"readable"}.getElems:
    let s = t.getStr
    if s.len == 0:
      raise newException(ValueError, "an empty token in `readable`")
    result.readable.add s
  if result.readable.len == 0:
    raise newException(ValueError,
      "tools/chain/snapshot-format.json lists no readable tokens. An empty list " &
      "would refuse every snapshot ever written, including this tree's own.")
  if result.current notin result.readable:
    raise newException(ValueError,
      "tools/chain/snapshot-format.json: `current` is '" & result.current &
      "' and it is not in `readable`. A tree that cannot read what it writes is " &
      "not a version policy.")
  let mandatory = doc{"mandatoryMembers"}
  if mandatory == nil or mandatory.kind != JObject:
    raise newException(ValueError,
      "tools/chain/snapshot-format.json declares no `mandatoryMembers`. Without " &
      "it the tokens differ by nothing a reader can check, which is the state " &
      "this file exists to end.")
  for tok in result.readable:
    let members = mandatory{tok}
    if members == nil or members.kind != JArray:
      raise newException(ValueError,
        "tools/chain/snapshot-format.json: readable token '" & tok &
        "' has no `mandatoryMembers` entry. A token whose requirements are " &
        "unstated is a token whose gate cannot be written — state the empty " &
        "list deliberately.")
    for m in members.getElems:
      if m.getStr == "transactions[].refusalReason":
        result.mandatoryRefusalReason.add tok
  let outcomes = doc{"outcomes"}
  if outcomes == nil or outcomes.kind != JObject:
    raise newException(ValueError,
      "tools/chain/snapshot-format.json declares no `outcomes` partition.")
  for (group, dest) in [("traced", 0), ("untraced", 1), ("chainAbsent", 2)]:
    let arr = outcomes{group}
    if arr == nil or arr.kind != JArray or arr.len == 0:
      raise newException(ValueError,
        "tools/chain/snapshot-format.json: outcome population '" & group &
        "' is missing or empty. An empty population makes every claim over it " &
        "vacuously true, which is the shape of green this whole campaign is about.")
    for o in arr.getElems:
      case dest
      of 0: result.traced.add o.getStr
      of 1: result.untraced.add o.getStr
      else: result.chainAbsent.add o.getStr
  # THE THREE ARE A PARTITION, and an overlap is a build failure rather than a
  # double-count at run time. An outcome in two populations would make
  # `accountedFor` count it twice and would make "every untraced row carries a
  # reason" both required and forbidden of the same row.
  var seen: seq[string]
  for o in result.traced & result.untraced & result.chainAbsent:
    if o in seen:
      raise newException(ValueError,
        "tools/chain/snapshot-format.json: outcome '" & o & "' appears in more " &
        "than one population. The three are a partition.")
    seen.add o

const
  SnapshotFormat* = parseSnapshotFormat()
    ## The version policy, read at compile time from the file the producers read.

proc currentSnapshotFormat*(): string = SnapshotFormat.current

proc isReadableSnapshotFormat*(token: string): bool =
  token in SnapshotFormat.readable

proc readableSnapshotFormatList*(): string =
  ## The tokens, for a refusal message. A refusal that names only what it did not
  ## recognise makes the reader go looking; one that also names what it accepts
  ## makes the fix visible from the failure.
  SnapshotFormat.readable.join(" or ")

proc snapshotRequiresRefusalReason*(token: string): bool =
  ## Does this token require a `refusalReason` on every untraced row?
  ##
  ## THE WHOLE CONTENT OF THE `@1` → `@2` BUMP. On `@1` the reader accepts a row
  ## without one, which is the behaviour that let the pre-ING-3 captures be read;
  ## on `@2` an untraced row without one is refused, naming the row. A version
  ## whose only difference a reader does not act on is a label.
  token in SnapshotFormat.mandatoryRefusalReason

proc isUntracedSnapshotOutcome*(outcome: string): bool =
  outcome in SnapshotFormat.untraced

proc isChainAbsentSnapshotOutcome*(outcome: string): bool =
  outcome in SnapshotFormat.chainAbsent

proc isTracedSnapshotOutcome*(outcome: string): bool =
  outcome in SnapshotFormat.traced
