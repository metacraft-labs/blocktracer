## chain/refusal_reasons.nim
##
## The publisher's half of ING-3's closed set of refusal reasons.
##
## ## Why this file reads bytes instead of declaring an enum
##
## The producer's half is `tools/chain/lib/refusal.mjs`. If this file declared
## its own `enum` the set would be closed in two places, which is the same as
## being closed in neither: the first condition added on the JavaScript side
## would reach a snapshot, this side would not recognise it, and the failure
## would land at ingest time on a capture that cannot be retaken. A capture is
## unrepeatable — a body prunes about thirty minutes after it lands — so a
## disagreement between the two halves costs transactions, not a retry.
##
## So both halves read `tools/chain/refusal-reasons.json`. This one reads it
## with `staticRead` at COMPILE time, which buys two things an enum would not:
##
##   * a member added there is a member here with nobody remembering to copy it;
##   * a file that is missing, malformed, or has changed format fails the BUILD
##     rather than producing a validator that waves everything through. A
##     validator that silently stopped validating is the defect this whole
##     milestone is about, one layer down.
##
## ## What this file deliberately does NOT carry
##
## The mapping from producer conditions to reasons, and from the replay
## runtime's eighty-four error classes to reasons, stays on the producer side.
## The publisher never sees a condition or a runtime class — by the time a row
## reaches here it carries a finished reason id, and the only question left is
## whether that id is a member.
##
## ## `absent` is not a member, and this file asserts it
##
## Trace-Artifacts.md §6 reserves `absent` for an execution the chain never
## published — the Aztec private half. Every member here is a statement about
## this pipeline: we could have traced it and did not. `staticAssert`-style
## check below fails the build if the two ever merge.

import std/[json, strutils]

const refusalReasonsJson = staticRead("../../../tools/chain/refusal-reasons.json")

type
  RefusalReason* = object
    ## One member of the closed set, exactly as the shared file states it.
    id*: string
    durability*: string   ## `permanent` or `repairable`
    condition*: string    ## what produces it, in words

proc parseRefusalReasons(): seq[RefusalReason] =
  ## Reads the shared registry at compile time, in file order.
  ##
  ## A `seq` of objects rather than a `Table`: a `const Table` cannot be indexed
  ## at run time in Nim, and building one lazily would put the registry behind
  ## an initialisation nobody can see. Seven members is a linear scan nobody
  ## will ever measure.
  let doc = parseJson(refusalReasonsJson)
  if doc{"format"}.getStr != "blocktracer/refusal-reasons@1":
    raise newException(ValueError,
      "tools/chain/refusal-reasons.json declares format '" &
      doc{"format"}.getStr & "', and this module only knows " &
      "blocktracer/refusal-reasons@1. A half-read closed set is an open one.")
  for r in doc{"reasons"}.getElems:
    let id = r{"id"}.getStr
    if id.len == 0:
      raise newException(ValueError, "a refusal reason with no id")
    if id == "absent":
      raise newException(ValueError,
        "tools/chain/refusal-reasons.json has gained a member named 'absent'. " &
        "Trace-Artifacts.md §6 reserves that word for an execution the chain " &
        "never published, which is a statement about the chain; every refusal " &
        "reason is a statement about this pipeline. They must not render as " &
        "one sentence.")
    let d = r{"durability"}.getStr
    if d != "permanent" and d != "repairable":
      raise newException(ValueError,
        "refusal reason '" & id & "' has durability '" & d &
        "', which is neither permanent nor repairable. A page grades its own " &
        "durability claim against this field.")
    let c = r{"condition"}.getStr
    if c.len == 0:
      raise newException(ValueError,
        "refusal reason '" & id & "' states no condition. Every member says " &
        "what produces it; that is what makes the set reviewable rather than " &
        "merely finite.")
    result.add RefusalReason(id: id, durability: d, condition: c)
  if result.len == 0:
    raise newException(ValueError,
      "tools/chain/refusal-reasons.json defines no reasons. An empty closed " &
      "set would make every 'the reason is a member' check vacuously false " &
      "and every 'no reason is outside the set' check vacuously true.")

const
  RefusalReasons* = parseRefusalReasons()
    ## The closed set, in the order the shared file lists it. Counts are
    ## published in that order so two summaries line up in a diff.

proc refusalReasonIds*(): seq[string] =
  ## Every member id, in file order.
  for r in RefusalReasons: result.add r.id

proc isRefusalReason*(id: string): bool =
  ## Is this id a member of the closed set? The one question the publisher asks.
  for r in RefusalReasons:
    if r.id == id: return true
  false

proc refusalReasonDurability*(id: string): string =
  ## `permanent` or `repairable`, or `""` for a non-member. Load-bearing: a page
  ## must not assert "a permanent answer rather than a failed fetch" over a
  ## repairable cause, and this is where that claim is decided.
  for r in RefusalReasons:
    if r.id == id: return r.durability
  ""

proc refusalReasonList*(): string =
  ## The members, for a failure message. A refusal that names only what it did
  ## not recognise makes the reader go looking; one that also names what it
  ## knows makes the fix visible from the failure.
  refusalReasonIds().join(", ")
