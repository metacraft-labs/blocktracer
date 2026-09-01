## The consumer half of the Data Contract: JSON → the **M5b types**.
##
## `blocktracer/contract/model.nim` defines the types and their `toJson`
## (the producer half). This module is the exact inverse, and it is the reason
## [Client-SDK.md](../../../codetracer-specs/BlockTracer/Client-SDK.md) §4 can
## call this package "the contract's consumer-side reference implementation":
## M5b's validator checks that a *producer* emitted conformant bytes; this
## checks that those bytes read back into the same typed model, on the far side
## of the seam.
##
## **Nothing is redeclared.** Every type below is `model`'s. A second
## consumer-side schema is the drift Static-Site-Architecture.md §2.9 exists to
## prevent, and it is asserted mechanically: `ci/test/client-sdk-boundary.sh`
## fails the build if this package declares a type named like a contract type.
##
## Decoding is strict where the contract is strict and lenient where it is
## explicitly optional. A missing discriminant, an unknown enum spelling or a
## wrong JSON kind raises `ContractDecodeError`, because misreading a
## discriminated union is exactly the "confident wrong answer" the union shape
## exists to prevent (Static-Site-Architecture.md §2.3). Callers turn that into
## data — see `session.nim` and `entities.nim`; it never reaches a consumer as
## an exception.

import std/[json, strutils]
import ../blocktracer/contract/model
import ../blocktracer/contract/version

export model, version

type
  ContractDecodeError* = object of ValueError
    ## The bytes are not a conformant object of the class asked for.

proc fail(what: string) {.noreturn.} =
  raise newException(ContractDecodeError, what)

proc req(n: JsonNode, key, what: string): JsonNode =
  if n.isNil or n.kind != JObject or not n.hasKey(key):
    fail(what & ": missing required field '" & key & "'")
  n[key]

proc reqStr(n: JsonNode, key, what: string): string =
  let v = req(n, key, what)
  if v.kind != JString: fail(what & ": field '" & key & "' is not a string")
  v.getStr

proc reqInt(n: JsonNode, key, what: string): int =
  let v = req(n, key, what)
  if v.kind != JInt: fail(what & ": field '" & key & "' is not an integer")
  v.getInt

proc optStr(n: JsonNode, key: string): string =
  if n.isNil or n.kind != JObject or not n.hasKey(key): ""
  elif n[key].kind != JString: ""
  else: n[key].getStr

proc optInt(n: JsonNode, key: string): int =
  if n.isNil or n.kind != JObject or not n.hasKey(key): 0
  elif n[key].kind != JInt: 0
  else: n[key].getInt

proc optBool(n: JsonNode, key: string): bool =
  if n.isNil or n.kind != JObject or not n.hasKey(key): false
  elif n[key].kind != JBool: false
  else: n[key].getBool

proc enumOf[T: enum](s, what: string): T =
  ## Enum spellings are the contract's own (`model.nim` declares them as the
  ## enum's string values), so an unknown spelling is a contract violation and
  ## not something to guess at.
  try: parseEnum[T](s)
  except ValueError: fail(what & ": unknown value '" & s & "'")

# ---------------------------------------------------------------------------
# §2.3 Transaction facts
# ---------------------------------------------------------------------------

proc decodeTxId*(n: JsonNode): TxId =
  const what = "TxId"
  let kind = enumOf[TxIdKind](reqStr(n, "kind", what), what & ".kind")
  case kind
  of tikHash: TxId(kind: kind, hash: reqStr(n, "hash", what))
  of tikBlockIndex:
    TxId(kind: kind, biBlock: reqStr(n, "block", what),
         biIndex: reqInt(n, "index", what))
  of tikVersion:
    TxId(kind: kind, vVersion: reqStr(n, "version", what),
         vHash: reqStr(n, "hash", what))
  of tikAccountLt:
    TxId(kind: kind, alAccount: reqStr(n, "account", what),
         alLt: reqStr(n, "lt", what), alHash: reqStr(n, "hash", what))

proc decodeTxOrder*(n: JsonNode): TxOrder =
  const what = "TxOrder"
  let kind = enumOf[TxOrderKind](reqStr(n, "kind", what), what & ".kind")
  case kind
  of tokBlockIndex:
    TxOrder(kind: kind, obBlock: reqStr(n, "block", what),
            obHeight: reqInt(n, "height", what), obIndex: reqInt(n, "index", what))
  of tokConsensusTime: TxOrder(kind: kind, ctTime: reqStr(n, "time", what))
  of tokGlobalVersion: TxOrder(kind: kind, gvVersion: reqStr(n, "version", what))
  of tokCheckpoint: TxOrder(kind: kind, cpSeq: reqStr(n, "seq", what))
  of tokLogicalTime:
    TxOrder(kind: kind, ltAccount: reqStr(n, "account", what),
            ltLt: reqStr(n, "lt", what))

proc decodeOutcome*(n: JsonNode): Outcome =
  const what = "Outcome"
  result.overall = enumOf[OutcomeOverall](reqStr(n, "overall", what),
                                          what & ".overall")
  result.reason = optStr(n, "reason")
  if n.hasKey("parts") and n["parts"].kind == JArray:
    for p in n["parts"]: result.parts.add p

proc decodeRole*(n: JsonNode): Role =
  Role(role: reqStr(n, "role", "Role"), address: reqStr(n, "address", "Role"))

proc decodeCost*(n: JsonNode): Cost =
  Cost(name: reqStr(n, "name", "Cost"), used: optStr(n, "used"),
       limit: optStr(n, "limit"), price: optStr(n, "price"),
       unit: optStr(n, "unit"), token: optStr(n, "token"),
       refundable: optBool(n, "refundable"))

proc decodeCodeEdge*(n: JsonNode): CodeEdge =
  CodeEdge(address: reqStr(n, "address", "CodeEdge"),
           codeHash: reqStr(n, "codeHash", "CodeEdge"),
           boundAt: optStr(n, "boundAt"))

proc decodeExecution*(n: JsonNode): Execution =
  ## `executionInputId` is required: it is the input from which the client
  ## derives the trace URL with no lookup (Static-Site-Architecture.md §2.3b),
  ## so an execution without one is not resolvable and saying so here is better
  ## than an empty artifact id travelling downstream.
  Execution(selector: optStr(n, "selector"),
            executionInputId: reqStr(n, "executionInputId", "Execution"))

proc decodeTransactionFacts*(n: JsonNode): TransactionFacts =
  const what = "TransactionFacts"
  result.chain = reqStr(n, "chain", what)
  result.id = decodeTxId(req(n, "id", what))
  result.order = decodeTxOrder(req(n, "order", what))
  result.outcome = decodeOutcome(req(n, "outcome", what))
  if n.hasKey("roles"):
    for r in n["roles"]: result.roles.add decodeRole(r)
  if n.hasKey("cost"):
    for c in n["cost"]: result.cost.add decodeCost(c)
  if n.hasKey("payload"):
    let p = n["payload"]
    result.payloadRaw = optStr(p, "raw")
    result.payloadSelector = optStr(p, "selector")
    result.payloadTarget = optStr(p, "target")
  if n.hasKey("logs") and n["logs"].kind == JArray:
    for l in n["logs"]: result.logs.add l
  if n.hasKey("codeEdges"):
    for e in n["codeEdges"]: result.codeEdges.add decodeCodeEdge(e)
  if n.hasKey("executions"):
    for e in n["executions"]: result.executions.add decodeExecution(e)
  result.native = if n.hasKey("native"): n["native"] else: newJNull()

# ---------------------------------------------------------------------------
# §2.3a TraceSelection overlay
# ---------------------------------------------------------------------------

proc decodeValidationSummary*(n: JsonNode): ValidationSummary =
  ValidationSummary(
    status: enumOf[ValidationStatus](reqStr(n, "status", "ValidationSummary"),
                                     "ValidationSummary.status"),
    strength: optInt(n, "strength"))

proc decodeExecTrace*(n: JsonNode): ExecTrace =
  const what = "ExecTrace"
  result.selector = optStr(n, "selector")
  result.availability = enumOf[TraceAvailability](
    reqStr(n, "availability", what), what & ".availability")
  result.reason = optStr(n, "reason")
  result.bytes = optInt(n, "bytes")
  result.reconstructed = optBool(n, "reconstructed")
  if n.hasKey("validation"):
    result.hasValidation = true
    result.validation = decodeValidationSummary(n["validation"])
  # §2.3a: a reason is REQUIRED when the execution is not observable. The
  # producer-side validator enforces it; the consumer refuses to present an
  # unexplained `absent`, because "absent with no reason" is indistinguishable
  # from a failed fetch, which is the exact confusion §2.3a forbids.
  if result.availability in {taAbsent, taUnsupported} and result.reason.len == 0:
    fail(what & ": availability '" & $result.availability &
      "' without a reason (Static-Site-Architecture.md §2.3a)")

proc decodeTraceSelection*(n: JsonNode): TraceSelection =
  const what = "TraceSelection"
  result.chain = reqStr(n, "chain", what)
  result.tx = reqStr(n, "tx", what)
  if n.hasKey("executions"):
    if n["executions"].kind != JArray: fail(what & ": 'executions' is not an array")
    for e in n["executions"]: result.executions.add decodeExecTrace(e)
  elif n.hasKey("trace"):
    result.hasSingle = true
    result.singleTrace = decodeExecTrace(n["trace"])
  else:
    fail(what & ": neither 'executions' nor 'trace' is present")

proc allExecTraces*(sel: TraceSelection): seq[ExecTrace] =
  ## The overlay's executions, whichever of the two contract-valid shapes it
  ## used. Both shapes are valid (§2.3a), so a consumer should never have to
  ## branch on which one a producer chose.
  if sel.executions.len > 0: sel.executions
  elif sel.hasSingle: @[sel.singleTrace]
  else: @[]

# ---------------------------------------------------------------------------
# §2 Generation root and block detail
# ---------------------------------------------------------------------------

proc strSeq(n: JsonNode): seq[string] =
  if n.isNil or n.kind != JArray: return
  for x in n:
    if x.kind == JString: result.add x.getStr

proc decodeGenerationRoot*(n: JsonNode): GenerationRoot =
  const what = "GenerationRoot"
  result.contractVersion = reqInt(n, "contractVersion", what)
  result.chain = reqStr(n, "chain", what)
  result.generation = reqStr(n, "generation", what)
  result.traceSelectionVersion = reqStr(n, "traceSelectionVersion", what)
  let maps = req(n, "maps", what)
  result.summaryPath = optStr(maps, "summary")
  result.heightPaths = strSeq(maps{"height"})
  result.blockIndexPaths = strSeq(maps{"blocks"})
  result.addrPaths = strSeq(maps{"addr"})
  result.txstatePaths = strSeq(maps{"txstate"})
  if n.hasKey("idx"): result.idx = n["idx"]
  if n.hasKey("render"): result.render = n["render"]

proc decodeBlockDetail*(n: JsonNode): BlockDetail =
  const what = "BlockDetail"
  result.chain = reqStr(n, "chain", what)
  result.hash = reqStr(n, "hash", what)
  result.height = reqInt(n, "height", what)
  result.parentHash = optStr(n, "parentHash")
  if n.hasKey("transactions"):
    result.transactions = strSeq(n["transactions"])

# ---------------------------------------------------------------------------
# Trace manifest — Trace-Artifacts.md §4
# ---------------------------------------------------------------------------

proc decodeTraceManifest*(n: JsonNode): TraceManifest =
  const what = "TraceManifest"
  result.schema = reqInt(n, "schema", what)
  result.traceArtifactId = reqStr(n, "traceArtifactId", what)
  result.executionInputId = reqStr(n, "executionInputId", what)
  result.chain = reqStr(n, "chain", what)
  result.tx = reqStr(n, "tx", what)
  let rec = req(n, "recorder", what)
  result.recorder = RecorderRef(id: reqStr(rec, "id", what & ".recorder"),
                                build: reqStr(rec, "build", what & ".recorder"),
                                version: optStr(rec, "version"))
  let prof = req(n, "profile", what)
  result.profile = ProfileRef(name: optStr(prof, "name"),
                              hash: reqStr(prof, "hash", what & ".profile"))
  result.sourceBundles =
    if n.hasKey("sourceBundles") and n["sourceBundles"].kind == JObject:
      n["sourceBundles"]
    else:
      newJObject()
  let c = req(n, "container", what)
  result.container = ContainerRef(
    file: optStr(c, "file"), bytes: reqInt(c, "bytes", what & ".container"),
    blockSize: optInt(c, "blockSize"),
    hash: reqStr(c, "hash", what & ".container"))
  let e = req(n, "execution", what)
  result.execution = ExecutionSummary(
    steps: optInt(e, "steps"), frames: optInt(e, "frames"),
    truncated: optBool(e, "truncated"), sourceLevel: optBool(e, "sourceLevel"),
    languages: strSeq(e{"languages"}),
    # ABSENT IS `eeUnstated`, and a PRESENT spelling this consumer does not know
    # is refused rather than folded into it. Those are two different facts: the
    # first is a producer that made no claim about where the recording stops,
    # the second is one that made a claim in a vocabulary this build cannot
    # read — and quietly reporting the second as "nothing is known" is how a
    # page comes to say a failed execution ran to the end. Same rule as every
    # other enum here (`enumOf` fails), and the same rule §2.3a applies to an
    # unreadable availability.
    ending:
      if e.hasKey("ending"):
        enumOf[ExecutionEnding](reqStr(e, "ending", what & ".execution"),
                                what & ".execution.ending")
      else: eeUnstated)
  let v = req(n, "validation", what)
  result.validation = decodeValidationSummary(v)
  result.validationOracle = optStr(v, "oracle")
  result.prestateStrategy = optStr(n, "prestateStrategy")

# ---------------------------------------------------------------------------
# Chain registry — the recorder pin the trace URL is derived from (§2.3b)
# ---------------------------------------------------------------------------

type
  RecorderPin* = object
    ## One chain's row of `/registry/chains.v{N}.json`: everything except
    ## `executionInputId` that `traceArtifactId` is derived from
    ## (Trace-Artifacts.md §2.1).
    chain*: string
    recorder*: RecorderRef
    profile*: ProfileRef
    traceSchema*: string

proc decodeRecorderPin*(registry: JsonNode, chain: string): RecorderPin =
  const what = "chain registry"
  let chains = req(registry, "chains", what)
  if chains.kind != JObject or not chains.hasKey(chain):
    fail(what & ": no entry for chain '" & chain & "'")
  let row = chains[chain]
  let rec = req(row, "recorder", what)
  let prof = req(row, "profile", what)
  RecorderPin(
    chain: chain,
    recorder: RecorderRef(id: reqStr(rec, "id", what),
                          build: reqStr(rec, "build", what),
                          version: optStr(rec, "version")),
    profile: ProfileRef(name: optStr(prof, "name"),
                        hash: reqStr(prof, "hash", what)),
    traceSchema: reqStr(row, "traceSchema", what))
