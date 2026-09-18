## chain/contract_rules.nim
##
## The §5 rules this reader enforces, and the path defaults §5.1 states — read out
## of `tools/chain/snapshot-contract.json` at COMPILE time.
##
## ## Why a refusal names a rule
##
## `Data-Contract.md` §5 is the producer's copy of this seam. Until this module the
## reader refused a non-conforming snapshot *where it happened to notice*: a sentence
## about the symptom, with nothing in it that a producer could look up. So a recorder
## author who tripped one had to find the line in `ingest.nim` that raised, read
## around it, and infer which rule they had broken — which is "the reader is the
## specification" arriving through the error message, and the whole point of writing
## the format down is that it stops being true.
##
## Every refusal that enforces a §5 rule now carries that rule's identifier and its
## section. The identifier is not decoration: it is the key a producer greps §5 for,
## and it is what `tools/chain/snapshot-contract-selftest.mjs` matches when it checks
## that every rule §5 states is one this reader cites and every rule this reader
## cites is one §5 states.
##
## ## Why the ids live in a data file rather than in this module
##
## For the reason `refusal_reasons.nim` and `snapshot_format.nim` beside it give: the
## producer side is JavaScript and the reader side is Nim, and a rule table spelled
## twice is two tables. `tools/chain/snapshot-contract.json` is also where the member
## census lives — which member of which container the reader consumes, and whether it
## reads it with `[]` (required) or `{}` (optional) — so the rules and the members
## they are rules about are one document.
##
## A malformed table fails the BUILD rather than producing a citation that names
## nothing: `cite` is evaluated at compile time through the `Rule*` constants below,
## and an id absent from the file stops compilation at the constant that names it.
##
## ## The path defaults
##
## §5.1 says the snapshot tree's paths are named by the row that owns them. Four of
## them carry a DEFAULT for a capture whose row is silent, and those defaults are
## stated here rather than open-coded in the reader — the difference between "the
## contract states where this goes when you do not say" and "the reader happens to
## look there" is the difference between a published format and a habit.

import std/[json, strutils, tables]

const snapshotContractJson = staticRead("../../../tools/chain/snapshot-contract.json")

# ── READING THIS FILE'S ARRAYS AND OBJECTS, WITHOUT THE SHAPE THAT KILLS ───────
#
# `doc{"k"}` answers a NIL `JsonNode` for an absent key, and `for x in <nil>` does
# not raise — `items` dereferences it and the process dies. Every walk below went
# through that shape, and at COMPILE time it means the compiler segfaults with no
# sentence about which member of the contract was missing.
#
# `getElems` alone is not the fix either: it answers the EMPTY sequence, so a
# contract that lost a member would silently produce an empty vocabulary, an empty
# strategy set or an empty census — which is the one input every "must not contain"
# check written over them reports success on. So absence REFUSES here, by name, and
# the walk takes the elements from an accessor that cannot be handed a nil.
#
# This is the nil-access family the ban in `tools/chain/lib/reader-contract.mjs`
# refuses over `src/**/*.nim`: a member reached by the one access form that cannot
# survive its absence.

proc requiredElems(node: JsonNode, what: string): seq[JsonNode] =
  if node == nil or node.kind != JArray:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json states no `" & what & "` array. A half-read " &
      "contract is no contract: an absent member read as an empty one makes every " &
      "check written over it pass by having nothing to look at.")
  node.getElems

proc requiredFields(node: JsonNode, what: string): OrderedTable[string, JsonNode] =
  if node == nil or node.kind != JObject:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json states no `" & what & "` object. A half-read " &
      "contract is no contract: an absent member read as an empty one makes every " &
      "check written over it pass by having nothing to look at.")
  node.getFields

type
  ContractRule* = object
    id*: string
    section*: string
    statement*: string

proc parseRules(): seq[ContractRule] =
  let doc = parseJson(snapshotContractJson)
  if doc{"format"}.getStr != "blocktracer/snapshot-contract@1":
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json declares format '" &
      doc{"format"}.getStr & "' and this module only knows " &
      "blocktracer/snapshot-contract@1. A half-read rule table is no rule table.")
  let rules = doc{"rules"}
  if rules == nil or rules.kind != JObject or rules.len == 0:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json states no `rules`. An empty table would " &
      "let every citation below name nothing, which is the shape of green this " &
      "whole seam exists to refuse.")
  for id, body in rules:
    if id.len == 0 or not id.startsWith("S5-"):
      raise newException(ValueError,
        "tools/chain/snapshot-contract.json: rule id '" & id & "' is not of the " &
        "form S5-… . The id is what a producer greps §5 for, so its shape is " &
        "part of the contract.")
    let section = body{"section"}.getStr
    let statement = body{"statement"}.getStr
    if section.len == 0 or statement.len == 0:
      raise newException(ValueError,
        "tools/chain/snapshot-contract.json: rule '" & id & "' names no section " &
        "or no statement. A citation with no text behind it sends a reader to a " &
        "heading and leaves them there.")
    result.add ContractRule(id: id, section: section, statement: statement)
  # ── AND THE TWO CLOSED SETS BESIDE THE RULES, CHECKED HERE ──────────────────
  #
  # `prestateStrategies` and `chainVocabulary` are read by the same file at the same
  # compile, so their well-formedness belongs in the same pass. They are validated
  # HERE rather than in a `const` of their own because a `const` nothing references
  # can be elided, and a table that is only checked when somebody happens to use it
  # is not checked. `ContractRules` is referenced by every citation below, so this
  # runs on every build of the reader.
  let strategies = doc{"prestateStrategies"}{"tokens"}
  if strategies == nil or strategies.kind != JArray or strategies.len == 0:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json states no `prestateStrategies.tokens`. " &
      "The reader refuses a strategy outside that set by name, and an empty set " &
      "makes the refusal unsatisfiable rather than permissive.")
  for tok in strategies:
    if tok.kind != JString or tok.getStr.len == 0:
      raise newException(ValueError,
        "tools/chain/snapshot-contract.json: `prestateStrategies.tokens` holds a " &
        "value that is not a non-empty string. A blank token would make every " &
        "snapshot's absent strategy a member of the closed set.")
  if doc{"prestateStrategies"}{"source"}.getStr.len == 0:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json: `prestateStrategies` names no `source`. " &
      "The set is a transcription of one section of one document and a transcription " &
      "that does not say what it transcribes cannot be reconciled with it.")
  let vocab = doc{"chainVocabulary"}
  if vocab == nil or vocab{"terms"} == nil or vocab{"terms"}.kind != JArray or
     vocab{"terms"}.len == 0:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json states no `chainVocabulary.terms`. An " &
      "empty vocabulary is a scan that matches nothing, which satisfies every " &
      "\"must not contain\" check written over it.")
  for term in requiredElems(vocab{"terms"}, "chainVocabulary.terms"):
    if term{"term"}.getStr.len == 0 or term{"kind"}.getStr.len == 0:
      raise newException(ValueError,
        "tools/chain/snapshot-contract.json: a `chainVocabulary.terms` entry states " &
        "no `term` or no `kind`. The kind is what says which of §5.3's four " &
        "categories the term belongs to, and a term with no category is a token " &
        "nobody can decide about.")
  if vocab{"scope"} == nil or vocab{"scope"}.kind != JArray or vocab{"scope"}.len == 0:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json: `chainVocabulary` names no `scope`. The " &
      "set of files the ban ranges over is part of the ban; left to a caller's habit " &
      "it is a scan whose subject can shrink without anything going red.")

const ContractRules* = parseRules()

proc parsePrestateStrategies(): seq[string] =
  let doc = parseJson(snapshotContractJson)
  for tok in requiredElems(doc{"prestateStrategies"}{"tokens"},
                           "prestateStrategies.tokens"): result.add tok.getStr

const PrestateStrategies* = parsePrestateStrategies()
  ## Chain-Support-Matrix.md §1.4's closed set, verbatim. The reader draws
  ## `provenance.prestateStrategy` from this and refuses anything else by name.

proc prestateStrategyList*(): string =
  ## The set, for a refusal that names what it would have accepted.
  PrestateStrategies.join(", ")

proc isPrestateStrategy*(s: string): bool =
  s in PrestateStrategies

proc cite*(id: string): string =
  ## The citable prefix for one §5 rule. Compile-time evaluable, so a `const`
  ## binding of an unknown id is a BUILD failure rather than a refusal that names
  ## a rule nobody can look up.
  for r in ContractRules:
    if r.id == id:
      return "[" & r.section & " " & r.id & "] "
  raise newException(ValueError,
    "no such rule '" & id & "' in tools/chain/snapshot-contract.json. A refusal " &
    "may only cite a rule the contract states.")

proc ruleStatement*(id: string): string =
  for r in ContractRules:
    if r.id == id: return r.statement
  ""

proc sectionOf*(id: string): string =
  ## The section of Data-Contract.md a rule id sends a reader to. `cite` carries it
  ## inside the refusal's own prefix; this is the same field for a caller that has
  ## the id and wants to say where to look without re-parsing a message.
  for r in ContractRules:
    if r.id == id: return r.section
  ""

proc contractRuleIds*(): seq[string] =
  for r in ContractRules: result.add r.id

# ── THE CITATIONS, AS CONSTANTS ───────────────────────────────────────────────
#
# Each is `cite(...)` forced through `const`, so the id is checked when this file
# is COMPILED. A refusal that cited a rule by a runtime string could name a rule
# that does not exist, and it would name it only on the day it fired.
const
  RuleSnapshotPresent* = cite("S5-SNAPSHOT-PRESENT")
  RuleFormatUnknown* = cite("S5-FORMAT-UNKNOWN")
  RuleChainNamed* = cite("S5-CHAIN-NAMED")
  RuleChainUnique* = cite("S5-CHAIN-UNIQUE")
  RuleMembersRequired* = cite("S5-MEMBERS-REQUIRED")
  RuleRowMembersRequired* = cite("S5-ROW-MEMBERS-REQUIRED")
  RuleCountsPresent* = cite("S5-COUNTS-PRESENT")
  RuleCountsRows* = cite("S5-COUNTS-ROWS")
  RuleCountsReconcile* = cite("S5-COUNTS-RECONCILE")
  RuleBlocksOrder* = cite("S5-BLOCKS-ORDER")
  RuleContainerBytes* = cite("S5-CONTAINER-BYTES")
  RuleOutcomeClosed* = cite("S5-OUTCOME-CLOSED")
  RuleRecorderLabelUnique* = cite("S5-RECORDER-LABEL-UNIQUE")
  RuleContainerNonEmpty* = cite("S5-CONTAINER-NONEMPTY")
  RuleReasonRequired* = cite("S5-REASON-REQUIRED")
  RuleRefusalReasonRequired* = cite("S5-REFUSALREASON-REQUIRED")
  RuleRefusalReasonClosed* = cite("S5-REFUSALREASON-CLOSED")
  RuleRefusalReasonForbidden* = cite("S5-REFUSALREASON-FORBIDDEN")
  RuleBundleRequired* = cite("S5-BUNDLE-REQUIRED")
  RuleBundleKeyed* = cite("S5-BUNDLE-KEYED")
  RuleBundleNonEmpty* = cite("S5-BUNDLE-NONEMPTY")
  RuleInstructionsAgree* = cite("S5-INSTRUCTIONS-AGREE")
  RulePositionsAgree* = cite("S5-POSITIONS-AGREE")
  RulePositionsColumns* = cite("S5-POSITIONS-COLUMNS")
  RuleCallTraceAgree* = cite("S5-CALLTRACE-AGREE")
  RuleCallTraceFrames* = cite("S5-CALLTRACE-FRAMES")
  RuleCallTraceFoldNonEmpty* = cite("S5-CALLTRACE-FOLD-NONEMPTY")
  RuleCallTraceFoldTally* = cite("S5-CALLTRACE-FOLD-TALLY")
  RuleCallTraceFoldBound* = cite("S5-CALLTRACE-FOLD-BOUND")
  RuleSidecarFormatUnknown* = cite("S5-SIDECAR-FORMAT-UNKNOWN")
  RuleSidecarChain* = cite("S5-SIDECAR-CHAIN")
  RuleRecorderStated* = cite("S5-RECORDER-STATED")
  RulePrestateStated* = cite("S5-PRESTATE-STATED")
  RulePrestateClosed* = cite("S5-PRESTATE-CLOSED")
  RuleCostVector* = cite("S5-COST-VECTOR")
  RuleExecutionsNamed* = cite("S5-EXECUTIONS-NAMED")
  RuleExecutionsOneTraced* = cite("S5-EXECUTIONS-ONE-TRACED")
  RulePositionsSchema* = cite("S5-POSITIONS-SCHEMA")
  RuleIdentifierEncodingClosed* = cite("S5-IDENTIFIER-ENCODING-CLOSED")
  RuleIdentifierEncodingShardable* = cite("S5-IDENTIFIER-ENCODING-SHARDABLE")

# ── THE MEMBERS A READER TAKES BY BRACKET, FROM THE CENSUS ────────────────────
#
# §5.2b records, per member, whether the CONTRACT requires it and whether the
# reader's read is SAFE. A member that is required and taken by `[]` is one whose
# absence raises inside `std/json` — `key not found: hash`, from a stack that names
# neither this module nor the rule it broke. That is "raising where it happens to
# notice" for every one of them, and there are two dozen.
#
# So the census is read here and the check is generated from it, rather than two
# dozen guards being written by hand beside two dozen subscripts. The SUBSCRIPTS
# STAY: they are what the spec-coverage check reads as the statement that the
# member is required, and replacing them with a guarded accessor would move that
# statement into an annotation nobody verifies. What this adds is a pass that runs
# FIRST and refuses by name.
#
# `onRows` carries the one qualification the census needs: four of these members
# are required only of a row that carries a trace. Nested containers are reached
# only when their parent member is present, so a row with no `recording` is
# refused for `recording` and not for six members of it.
type
  BracketRequired* = object
    path*: string      ## dotted, relative to the container: `recording.steps`
    tracedOnly*: bool  ## required only of a row that carries a trace

proc censusRequired(container: string, recurse, bracketOnly: bool): seq[BracketRequired] =
  ## Every member of `container` the census marks required, as dotted paths.
  ##
  ## TWO FILTERS, BECAUSE THE TWO RULES THEY FEED ARE DIFFERENT RULES.
  ##
  ## `bracketOnly` keeps only the members the reader takes by `[]` — the ones
  ## whose absence raises inside `std/json` — and is what the ROW rule needs: a
  ## required-but-safely-read row member is already refused by the rule the census
  ## names in its `enforcedBy`, and adding it here would refuse it twice, from the
  ## wrong rule, ahead of the check written for it.
  ##
  ## `bracketOnly = false` keeps every required member whatever the access form,
  ## and that is what the TOP LEVEL needs, because up there the unguarded subscript
  ## is not the only hazard. `snap{"counts"}` is a safe read whose result is then
  ## used as `counts.kind`, and `kind` on a nil `JsonNode` is a nil dereference —
  ## a segfault, not a `KeyError`. So the top-level population is "what §5.2
  ## requires", not "what the reader happens to read unsafely".
  ##
  ## `recurse` descends into nested containers. The row containers want it, because
  ## `recording.steps` is required of a traced row and reached from the row itself.
  ## The top level does NOT: `window.tip` has its own container, its own pass and
  ## its own rule, and hoisting it up here would move its refusal off
  ## S5-ROW-MEMBERS-REQUIRED and onto S5-MEMBERS-REQUIRED.
  let doc = parseJson(snapshotContractJson)
  let containers = doc{"containers"}
  proc walk(id, prefix: string, tracedOnly: bool, acc: var seq[BracketRequired]) =
    let body = containers{id}
    if body == nil: return
    for m, e in requiredFields(body{"members"}, id & ".members"):
      let isTraced = tracedOnly or e{"onRows"}.getStr == "traced only"
      let dotted = if prefix.len == 0: m else: prefix & "." & m
      if e{"required"}.getBool and (not bracketOnly or e{"access"}.getStr == "required"):
        acc.add BracketRequired(path: dotted, tracedOnly: isTraced)
      let child = id & "." & m
      if recurse and containers{child} != nil: walk(child, dotted, isTraced, acc)
  walk(container, "", false, result)
  if result.len == 0:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json: container '" & container &
      "' has no member the generated check over it would range over. An empty " &
      "population is the one input a coverage check reports success on having " &
      "measured nothing.")

proc bracketRequiredOf(container: string): seq[BracketRequired] =
  censusRequired(container, recurse = true, bracketOnly = true)

const
  SnapshotRequired* = censusRequired("snapshot", recurse = false, bracketOnly = false)
  BlockRequired* = bracketRequiredOf("snapshot.blocks[]")
  TransactionRequired* = bracketRequiredOf("snapshot.transactions[]")
  WindowRequired* = bracketRequiredOf("snapshot.window")

proc missingBracketMember*(node: JsonNode, want: seq[BracketRequired],
                           traced: bool): string =
  ## The first member of `want` this node does not carry, or "".
  for w in want:
    if w.tracedOnly and not traced: continue
    var cur = node
    for seg in w.path.split('.'):
      if cur == nil or cur.kind != JObject: break
      cur = cur{seg}
    if cur == nil: return w.path
  ""

# ── §5.1's PATH DEFAULTS ──────────────────────────────────────────────────────
#
# Read from the same file, so "where does a listing go when the row does not say"
# is answered by the contract and not by this reader's habit.
proc defaultPath(container: string): string =
  let doc = parseJson(snapshotContractJson)
  let c = doc{"containers"}{container}
  if c == nil:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json names no container '" & container & "'")
  let d = c{"defaultPath"}
  if d == nil or d.getStr.len == 0:
    raise newException(ValueError,
      "tools/chain/snapshot-contract.json: container '" & container &
      "' states no `defaultPath`, so a row that names no file could not be " &
      "resolved at all.")
  d.getStr

# There are FIVE, and there is no sixth. A row's `container` has no default: it is
# required of every traced row and taken by an unguarded subscript, so a row that
# names none is refused rather than resolved. `ct` was recorded as its default here
# and in the census, was used by nothing, and had to be hand-exempted from the check
# that every stated default belongs to a container the reader opens — so it is gone
# from both. See the census entry for `container`.
const
  DefaultArtifactResolutionPath* = defaultPath("sidecar:artifact-resolution")
  DefaultInstructionsDir* = defaultPath("sidecar:instructions")
  DefaultPositionsDir* = defaultPath("sidecar:positions")
  DefaultCallTraceDir* = defaultPath("sidecar:calltrace")
  DefaultSourcesDir* = defaultPath("sidecar:sources")
