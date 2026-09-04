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

  RecorderRef* = object
    ## WHICH RECORDER PRODUCED A CONTAINER. Declared here, above the overlay,
    ## rather than down with the manifest where it used to live, because the
    ## overlay is now one of its two homes and a type cannot be used before it
    ## is declared.
    id*, build*, version*: string

  ExecTrace* = object
    ## One execution's availability within the overlay. Note: still NO
    ## artifactId — the address is DERIVED (§2.1), never carried. What may now
    ## be carried is one of its INPUTS, `recorder`, and the difference is the
    ## whole point: a published id would make the overlay authoritative over
    ## the derivation and end content-addressing, whereas a published input
    ## leaves the derivation exactly where it was and only corrects where one
    ## of its terms is read from.
    selector*: string
    availability*: TraceAvailability
    reason*: string            ## required when availability == absent/unsupported
    bytes*: int                ## >0 when ready/divergent
    reconstructed*: bool       ## orthogonal to availability (§2.3a)
    hasValidation*: bool
    validation*: ValidationSummary
    hasRecorder*: bool
      ## Whether this row names the recorder that produced its container.
    recorder*: RecorderRef
      ## THE RECORDER THAT PRODUCED THIS CONTAINER, when the producer knows it.
      ##
      ## WHY THIS IS PER ROW AND NOT PER CHAIN. `traceArtifactId` commits to
      ## `recorderBuild` on purpose — "changing the recorder must change the URL
      ## so a stale artifact cannot outlive a bug fix" (ids.nim). Reading that
      ## term from a single per-chain pin makes the commitment a lie the moment
      ## a chain carries containers from two recorders: re-pinning the chain
      ## re-derives the address of every container already published under the
      ## old recorder, and attributes bytes to a build that did not produce
      ## them. A chain is a set of transactions observed over time, and the
      ## recorder that observed them is a fact about each observation.
      ##
      ## ABSENT MEANS "USE THE CHAIN PIN", which is what every row published
      ## before this field existed means, and is why adding it re-derives
      ## nothing: a consumer that finds no `recorder` here behaves exactly as it
      ## did, and a producer that names the chain's own pin here derives the
      ## identical id. Both halves are load-bearing for not rewriting the
      ## identity of anything already published.

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
    idx*: JsonNode      ## §2.9 `/idx/**` is "in root" — the search-index descriptor
                        ## for this generation (nil => this generation emits no idx).
    render*: JsonNode   ## the pre-rendered entry-page layer this generation carries
                        ## (nil => data-only tree, no HTML entry pages). Both are
                        ## optional layers the sealed root enumerates alongside `maps`.

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
  ProfileRef* = object
    name*, hash*: string

  ContainerRef* = object
    file*: string
    bytes*: int
    blockSize*: int
    hash*: string

  ExecutionEnding* = enum
    ## HOW THE RECORDING ENDED — which is not how the TRANSACTION ended.
    ##
    ## `Outcome.overall` above is the chain's verdict on the transaction: it
    ## committed, or it reverted, or it committed some parts. This is the
    ## recording's verdict on the execution inside it, and the two are
    ## genuinely independent. A public AVM call whose circuit stops on a
    ## constraint that did not hold can still be a transaction the chain
    ## records as `succeeded`; the demo tour publishes exactly that pair, and
    ## before this field a visitor had no way to tell such a recording from one
    ## that ran to the end. Every badge, every row and every sentence on both
    ## pages was byte-identical.
    ##
    ## Three values and not a bool, because "we do not know" is the common case
    ## and must not read as "it completed".
    eeUnstated = "unstated"
      ## Nothing established where this recording stops. The DEFAULT, which is
      ## why it is first: a producer that says nothing says this, and a manifest
      ## written before the field existed decodes to it. Omitted from the JSON
      ## rather than written, so "unstated" and "absent" cannot become two
      ## different states a reader has to reconcile.
      ##
      ## Every real-chain recording is this today. `chain/ingest.nim` has the
      ## receipt's `revertCode` and deliberately does NOT use it here: that is
      ## the chain's verdict, and spending it on this field would reintroduce
      ## the conflation the field exists to end — as a value that looks
      ## authoritative.
    eeCompleted = "completed"
      ## The execution ran to the program's end.
    eeFailedConstraint = "failedConstraint"
      ## The execution stopped on a constraint that did not hold, and the
      ## recording ends there. There is no step after it.

  ExecutionSummary* = object
    steps*, frames*: int
    truncated*, sourceLevel*: bool
    languages*: seq[string]
    ending*: ExecutionEnding
      ## `truncated` is its nearest neighbour and answers a different question.
      ## A truncated recording is one whose ending is MISSING — the recorder hit
      ## the profile budget — so it cannot also be stating what that ending was.
      ## The two are orthogonal and both are published.

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
  # OMITTED WHEN UNKNOWN, and that is a contract statement rather than a saving
  # of bytes: an absent `recorder` means "this row is addressed by the chain
  # pin", which is what every previously-published row means. Writing an empty
  # object here would turn "not stated" into "stated as nothing".
  if x.hasRecorder:
    result["recorder"] = %*{"id": x.recorder.id, "build": x.recorder.build,
                            "version": x.recorder.version}

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
  if x.idx != nil: result["idx"] = x.idx
  if x.render != nil: result["render"] = x.render

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
  # Written only when it is a statement. `eeUnstated` is the absence of one, and
  # writing it would turn "nobody established this" into a published claim that
  # a reader has to distinguish from a missing key — two spellings of one fact,
  # which is the drift `Outcome.reason`'s `empty => omitted` already avoids.
  # Additive-only (docs/data-contract.md): a consumer that predates the field
  # reads the manifests it always read.
  if x.execution.ending != eeUnstated:
    result["execution"]["ending"] = %($x.execution.ending)
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
