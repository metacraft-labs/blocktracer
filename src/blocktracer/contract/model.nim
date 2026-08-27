## The Data Contract as concrete, typed Nim structs (M5b).
##
## This module is the **normative in-repo representation** of the static-tree and
## trace-manifest object schemas. Nim object variants are the natural encoding of
## the spec's discriminated unions (Static-Site-Architecture.md §2.3), so the
## "flatten a natively-meaningful fact and you fail here" property is enforced by
## the type system rather than by prose.
##
## Why Nim types (and not a second JSON Schema): the Object-Class Registry
## (Static-Site-Architecture.md §2.9) exists precisely because *restatements
## drift*. A second machine schema would be a second source of truth to keep in
## sync. The house language is Nim (isonim, codetracer-nim, the recorders), both
## producers are Nim, so a single typed representation with an independent
## structural validator (validator.nim) is the pragmatic choice: the validator can
## check ANY producer's raw JSON — it does not require the bytes to have passed
## through these types — which is what proves the contract "names no producer".
##
## Authoritative sections: Static-Site-Architecture.md §2, §2.3, §2.3a, §2.3b,
## §2.9; Trace-Artifacts.md §3, §4; Data-Contract.md.

import std/json
import ./version

# ---------------------------------------------------------------------------
# §2.3 Transaction facts — the normalised model. Every field that can differ
# across chain families is a discriminated union carrying its own `kind`, so an
# unfamiliar variant renders the native payload honestly instead of guessing.
# ---------------------------------------------------------------------------

type
  TxIdKind* = enum
    tikHash = "hash"                ## EVM, Aztec, Aptos, Fuel, Cairo
    tikBlockIndex = "blockIndex"    ## Substrate
    tikVersion = "version"          ## Aptos (global version)
    tikAccountLt = "accountLt"      ## TON

  TxId* = object
    case kind*: TxIdKind
    of tikHash: hash*: string
    of tikBlockIndex:
      biBlock*: string
      biIndex*: int
    of tikVersion:
      vVersion*: string
      vHash*: string
    of tikAccountLt:
      alAccount*, alLt*, alHash*: string

  TxOrderKind* = enum
    tokBlockIndex = "blockIndex"
    tokConsensusTime = "consensusTime"  ## Hedera
    tokGlobalVersion = "globalVersion"  ## Aptos
    tokCheckpoint = "checkpoint"        ## Sui
    tokLogicalTime = "logicalTime"      ## TON

  TxOrder* = object
    case kind*: TxOrderKind
    of tokBlockIndex:
      obBlock*: string
      obHeight*: int
      obIndex*: int
    of tokConsensusTime: ctTime*: string
    of tokGlobalVersion: gvVersion*: string
    of tokCheckpoint: cpSeq*: string
    of tokLogicalTime:
      ltAccount*, ltLt*: string

  OutcomeOverall* = enum
    ooSucceeded = "succeeded"
    ooReverted = "reverted"
    ooPartial = "partial"                 ## atomicity is not universal
    ooFailedWithEffects = "failedWithEffects"

  Outcome* = object
    ## A tree, not a boolean: `parts` are independently-committing units
    ## (NEAR receipts, TON branches, Aztec private/public commit units).
    overall*: OutcomeOverall
    reason*: string           ## empty => omitted
    parts*: seq[JsonNode]

  Role* = object
    ## signer, payer and initiator are distinct; some chains have no sender.
    role*: string
    address*: string

  Cost* = object
    ## Cost is a vector, never a scalar.
    name*, used*, limit*, price*, unit*, token*: string
    refundable*: bool

  CodeEdge* = object
    ## Versioned edge keyed by code hash, never a column
    ## (Static-Site-Architecture.md §2.1a).
    address*, codeHash*, boundAt*: string

  Execution* = object
    ## One independently-debuggable execution inside a transaction
    ## (Trace-Artifacts.md §2.2). `executionInputId` is a pure function of
    ## consensus data, hence lives in the IMMUTABLE facts
    ## (Static-Site-Architecture.md §2.3b) — the input from which the client
    ## derives the trace URL with no lookup.
    selector*: string           ## e.g. "public", "private", "0"
    executionInputId*: string

  TransactionFacts* = object
    ## `/d/{chain}/tx/{h0h1}/{txHash}.json` — immutable, permanent (§2.3, §2.3b).
    ## Deliberately excludes canonicality, finality, trace availability and
    ## validation: those change after publication and live in other layers.
    chain*: string
    id*: TxId
    order*: TxOrder
    outcome*: Outcome
    roles*: seq[Role]
    cost*: seq[Cost]
    payloadRaw*, payloadSelector*, payloadTarget*: string
    logs*: seq[JsonNode]
    codeEdges*: seq[CodeEdge]
    executions*: seq[Execution]
    native*: JsonNode           ## chain-native payload, verbatim

# ---------------------------------------------------------------------------
# §2.3a / §2.3b TraceSelection overlay — the versioned, per-transaction layer.
# ---------------------------------------------------------------------------

type
  TraceAvailability* = enum
    taReady = "ready"             ## published; button loads it directly
    taOnDemand = "onDemand"       ## compute URL, GET, 404 => offer generation
    taUnsupported = "unsupported" ## no recorder for this VM
    taAbsent = "absent"           ## structurally unobservable — Aztec private
    taDivergent = "divergent"     ## trace exists but verdict disagreed

  ValidationStatus* = enum
    vsMatch = "match"
    vsDivergent = "divergent"
    vsUnchecked = "unchecked"

  ValidationSummary* = object
    status*: ValidationStatus
    strength*: int             ## the only field the UI interprets (ordered rank)

  ExecTrace* = object
    ## One execution's availability within the overlay. Note: NO artifactId — it
    ## is derived from `executionInputId` + the registry recorder pin (§2.3b).
    selector*: string
    availability*: TraceAvailability
    reason*: string            ## required when availability == absent/unsupported
    bytes*: int                ## >0 when ready/divergent
    reconstructed*: bool       ## orthogonal to availability (§2.3a)
    hasValidation*: bool
    validation*: ValidationSummary

  TraceSelection* = object
    ## `/d/{chain}/ts/{v}/{h0h1}/{txHash}.json` — versioned overlay.
    ## Single-execution transactions emit `singleTrace`; a transaction with
    ## several independently-debuggable executions (the Aztec private/public
    ## split) emits `executions`. Both shapes are contract-valid.
    chain*: string
    tx*: string
    executions*: seq[ExecTrace]   ## empty => use singleTrace
    hasSingle*: bool
    singleTrace*: ExecTrace

# ---------------------------------------------------------------------------
# §2 Generation root and block detail.
# ---------------------------------------------------------------------------

type
  GenerationRoot* = object
    ## `/d/{chain}/g/{gen}/root.json` — the sealed, immutable snapshot root.
    ## Carries the single contract version and every derived map below it, so a
    ## crawler can walk the whole generation from here.
    contractVersion*: int
    chain*: string
    generation*: string
    traceSelectionVersion*: string
    summaryPath*: string
    heightPaths*: seq[string]
    blockIndexPaths*: seq[string]
    addrPaths*: seq[string]
    txstatePaths*: seq[string]

  BlockDetail* = object
    ## `/d/{chain}/block/{blockHash}.json` — content-addressed, generation-independent.
    chain*: string
    hash*: string
    height*: int
    parentHash*: string
    transactions*: seq[string]   ## txHashes, in block order

# ---------------------------------------------------------------------------
# Trace manifest — Trace-Artifacts.md §4. Carries NO observational fields, so
# regeneration is byte-identical.
# ---------------------------------------------------------------------------

type
  RecorderRef* = object
    id*, build*, version*: string

  ProfileRef* = object
    name*, hash*: string

  ContainerRef* = object
    file*: string
    bytes*: int
    blockSize*: int
    hash*: string

  ExecutionSummary* = object
    steps*, frames*: int
    truncated*, sourceLevel*: bool
    languages*: seq[string]

  TraceManifest* = object
    ## `/t/{t0t1}/{t2t3}/{traceArtifactId}/manifest.json`.
    schema*: int               ## == ContractVersion
    traceArtifactId*: string
    executionInputId*: string
    chain*: string
    tx*: string
    recorder*: RecorderRef
    profile*: ProfileRef
    sourceBundles*: JsonNode   ## codeHash -> sourceBundleId
    container*: ContainerRef
    execution*: ExecutionSummary
    validation*: ValidationSummary
    validationOracle*: string
    prestateStrategy*: string

# ===========================================================================
# Serialisation. Field order is fixed and no timestamps are emitted, so output
# is byte-identical across runs at the same seed (M5c determinism requirement).
# ===========================================================================

proc toJson*(x: TxId): JsonNode =
  result = newJObject()
  result["kind"] = %($x.kind)
  case x.kind
  of tikHash: result["hash"] = %x.hash
  of tikBlockIndex:
    result["block"] = %x.biBlock
    result["index"] = %x.biIndex
  of tikVersion:
    result["version"] = %x.vVersion
    result["hash"] = %x.vHash
  of tikAccountLt:
    result["account"] = %x.alAccount
    result["lt"] = %x.alLt
    result["hash"] = %x.alHash

proc toJson*(x: TxOrder): JsonNode =
  result = newJObject()
  result["kind"] = %($x.kind)
  case x.kind
  of tokBlockIndex:
    result["block"] = %x.obBlock
    result["height"] = %x.obHeight
    result["index"] = %x.obIndex
  of tokConsensusTime: result["time"] = %x.ctTime
  of tokGlobalVersion: result["version"] = %x.gvVersion
  of tokCheckpoint: result["seq"] = %x.cpSeq
  of tokLogicalTime:
    result["account"] = %x.ltAccount
    result["lt"] = %x.ltLt

proc toJson*(x: Outcome): JsonNode =
  result = newJObject()
  result["overall"] = %($x.overall)
  if x.reason.len > 0: result["reason"] = %x.reason
  result["parts"] = %x.parts

proc toJson*(x: Role): JsonNode =
  %*{"role": x.role, "address": x.address}

proc toJson*(x: Cost): JsonNode =
  %*{"name": x.name, "used": x.used, "limit": x.limit, "price": x.price,
     "unit": x.unit, "token": x.token, "refundable": x.refundable}

proc toJson*(x: CodeEdge): JsonNode =
  %*{"address": x.address, "codeHash": x.codeHash, "boundAt": x.boundAt}

proc toJson*(x: Execution): JsonNode =
  %*{"selector": x.selector, "executionInputId": x.executionInputId}

proc toJson*(x: TransactionFacts): JsonNode =
  result = newJObject()
  result["chain"] = %x.chain
  result["id"] = x.id.toJson
  result["order"] = x.order.toJson
  result["outcome"] = x.outcome.toJson
  var roles = newJArray()
  for r in x.roles: roles.add r.toJson
  result["roles"] = roles
  var cost = newJArray()
  for c in x.cost: cost.add c.toJson
  result["cost"] = cost
  result["payload"] = %*{"raw": x.payloadRaw, "selector": x.payloadSelector,
                         "target": x.payloadTarget}
  result["logs"] = %x.logs
  var edges = newJArray()
  for e in x.codeEdges: edges.add e.toJson
  result["codeEdges"] = edges
  var execs = newJArray()
  for e in x.executions: execs.add e.toJson
  result["executions"] = execs
  result["native"] = x.native

proc toJson*(x: ValidationSummary): JsonNode =
  %*{"status": $x.status, "strength": x.strength}

proc toJson*(x: ExecTrace): JsonNode =
  result = newJObject()
  if x.selector.len > 0: result["selector"] = %x.selector
  result["availability"] = %($x.availability)
  if x.reason.len > 0: result["reason"] = %x.reason
  if x.bytes > 0: result["bytes"] = %x.bytes
  if x.reconstructed: result["reconstructed"] = %true
  if x.hasValidation: result["validation"] = x.validation.toJson

proc toJson*(x: TraceSelection): JsonNode =
  result = newJObject()
  result["chain"] = %x.chain
  result["tx"] = %x.tx
  if x.executions.len > 0:
    var arr = newJArray()
    for e in x.executions: arr.add e.toJson
    result["executions"] = arr
  elif x.hasSingle:
    result["trace"] = x.singleTrace.toJson

proc toJson*(x: GenerationRoot): JsonNode =
  result = newJObject()
  result["contractVersion"] = %x.contractVersion
  result["chain"] = %x.chain
  result["generation"] = %x.generation
  result["traceSelectionVersion"] = %x.traceSelectionVersion
  var maps = newJObject()
  maps["summary"] = %x.summaryPath
  maps["height"] = %x.heightPaths
  maps["blocks"] = %x.blockIndexPaths
  maps["addr"] = %x.addrPaths
  maps["txstate"] = %x.txstatePaths
  result["maps"] = maps

proc toJson*(x: BlockDetail): JsonNode =
  %*{"chain": x.chain, "hash": x.hash, "height": x.height,
     "parentHash": x.parentHash, "transactions": x.transactions}

proc toJson*(x: TraceManifest): JsonNode =
  result = newJObject()
  result["schema"] = %x.schema
  result["traceArtifactId"] = %x.traceArtifactId
  result["executionInputId"] = %x.executionInputId
  result["chain"] = %x.chain
  result["tx"] = %x.tx
  result["recorder"] = %*{"id": x.recorder.id, "build": x.recorder.build,
                          "version": x.recorder.version}
  result["profile"] = %*{"name": x.profile.name, "hash": x.profile.hash}
  result["sourceBundles"] = x.sourceBundles
  result["container"] = %*{"file": x.container.file, "bytes": x.container.bytes,
                           "blockSize": x.container.blockSize,
                           "hash": x.container.hash}
  result["execution"] = %*{"steps": x.execution.steps,
                           "frames": x.execution.frames,
                           "truncated": x.execution.truncated,
                           "sourceLevel": x.execution.sourceLevel,
                           "languages": x.execution.languages}
  result["validation"] = %*{"status": $x.validation.status,
                            "oracle": x.validationOracle,
                            "strength": x.validation.strength,
                            "notes": newJArray(),
                            "divergences": newJArray()}
  result["prestateStrategy"] = %x.prestateStrategy

proc contractSupported*(version: int): bool =
  ## The validator/site-generator refuse a version they do not support rather
  ## than misreading it (Data-Contract.md §3).
  version == ContractVersion
