## The consumer-side conformance suite — the other end of M5b's seam.
##
## M5b delivers a validator that **producers** run over a tree they wrote. This
## walks the same tree through the SDK's public read path and reports what a
## *consumer* could not do with it, which is what makes
## [Data-Contract.md](../../../codetracer-specs/BlockTracer/Data-Contract.md)
## §4's interchangeability claim — the front end never learns which producer
## wrote the tree — testable rather than asserted
## ([Client-SDK.md](../../../codetracer-specs/BlockTracer/Client-SDK.md) §4).
##
## **The reader is never its own oracle.** Every check below compares two
## things that were produced independently, so a bug in this package's decoding
## cannot make the check agree with it:
##
##   * the `traceArtifactId` this package DERIVES from `executionInputId` plus
##     the registry pin, against the id the manifest STATES for itself. These
##     have no common code path — one is `deriveTraceArtifactId`, the other is
##     bytes the producer wrote — so a derivation that drifts is caught here
##     rather than by both ends agreeing (Trace-Artifacts.md §2.1);
##   * the container's declared byte length, against the bytes actually served;
##   * a block's transaction list, against each transaction's own recorded
##     position in that block.
##
## It contains no producer-specific branch and names no producer. That is the
## property, not a coincidence: `ci/test/client-sdk-boundary.sh` fails the
## build if this package imports one.

import std/strutils
import ./store
import ./paths
import ./session
import ./entities
import ./trace
import ../blocktracer/contract/ids

type
  ConformanceReport* = object
    chain*: string
    generation*: string
    blocksChecked*: int
    transactionsChecked*: int
    tracesResolved*: int
    tracesReplayable*: int
    errors*: seq[string]

proc ok*(r: ConformanceReport): bool = r.errors.len == 0

proc err(r: var ConformanceReport, msg: string) = r.errors.add msg

proc checkTrace(store: ObjectStore, session: ChainSession,
                v: TransactionView, t: ResolvedTrace, r: var ConformanceReport) =
  inc r.tracesResolved
  case t.kind
  of trkAbsent, trkUnsupported:
    # §2.3a: a reason is required, and there must be nothing to fetch. The
    # decoder already refuses a reasonless one; assert it here too, because
    # this is the property the whole "never a failed fetch" promise rests on.
    if t.reason.len == 0:
      r.err v.hash & " execution '" & t.selector & "': availability '" &
        $t.availability & "' with no reason (Static-Site-Architecture.md §2.3a)"
    if t.traceArtifactId.len > 0:
      r.err v.hash & " execution '" & t.selector &
        "': an unobservable execution must not derive an artifact address"
  of trkNoOverlay:
    r.err v.hash & ": " & t.reason
  of trkNoExecution, trkUnresolvable:
    r.err v.hash & " execution '" & t.selector & "': " & t.reason
  of trkOnDemand:
    if t.traceArtifactId.len == 0:
      r.err v.hash & " execution '" & t.selector &
        "': onDemand must still derive an address so a client can GET it (§2.3a)"
  of trkReady, trkDivergent:
    if not t.hasManifest:
      r.err v.hash & " execution '" & t.selector & "': availability '" &
        $t.availability & "' but " & t.manifestPath & " is not published" &
        (if t.manifestError.len > 0: " (" & t.manifestError & ")" else: "") &
        " — publishing order guarantees the trace exists before the overlay claims it (§2.3a)"
      return
    inc r.tracesReplayable
    # INDEPENDENT ORACLE 1: derived address vs the manifest's own claim.
    if t.manifest.traceArtifactId != t.traceArtifactId:
      r.err v.hash & " execution '" & t.selector & "': derived traceArtifactId " &
        t.traceArtifactId & " but the manifest states " & t.manifest.traceArtifactId &
        " (Trace-Artifacts.md §2.1: the client computes the address, it is not stored)"
    if t.manifest.executionInputId != t.executionInputId:
      r.err v.hash & " execution '" & t.selector &
        "': the manifest's executionInputId disagrees with the transaction facts"
    if t.manifest.tx != v.hash:
      r.err v.hash & " execution '" & t.selector &
        "': the manifest claims transaction " & t.manifest.tx
    if t.manifest.schema != session.contractVersion:
      r.err v.hash & " execution '" & t.selector & "': manifest schema " &
        $t.manifest.schema & " under a generation at contract version " &
        $session.contractVersion
    # INDEPENDENT ORACLE 2: declared length vs bytes actually served.
    let c = store.get(t.containerPath)
    if not c.found:
      r.err v.hash & " execution '" & t.selector & "': container " &
        t.containerPath & " is not published"
    elif c.body.len != t.manifest.container.bytes:
      r.err v.hash & " execution '" & t.selector & "': container declares " &
        $t.manifest.container.bytes & " bytes, served " & $c.body.len
    elif contentHashSha1(c.body) != t.manifest.container.hash and
         t.manifest.container.hash.startsWith("sha1:"):
      # Only checkable when the producer used the algorithm this build can
      # recompute. A `blake3:` hash is carried forward untouched rather than
      # guessed at — see `ids.nim`'s demo stand-in note.
      r.err v.hash & " execution '" & t.selector &
        "': container bytes do not match the manifest's traceContentHash"

proc consumerConformance*(store: ObjectStore, chain: string): ConformanceReport =
  ## Walk one chain of a published tree the way a consumer does, and report
  ## everything a consumer could not do. An empty `errors` means this package
  ## can render the chain end to end without knowing who produced it.
  result.chain = chain
  let opened = openChain(store, chain)
  case opened.outcome
  of ooOpened: discard
  else:
    result.err chain & ": " & opened.reason
    return
  let session = opened.session
  result.generation = session.generation

  if not session.hasPin:
    result.err chain & ": no recorder pinned in " &
      registryPath(session.contractVersion) &
      "; no trace address can be derived (Trace-Artifacts.md §2.1)"

  let blocks = blockRefsNewestFirst(store, session)
  if blocks.len == 0:
    result.err chain & ": the sealed root's height map lists no blocks"

  var lastHeight = high(int)
  for b in blocks:
    inc result.blocksChecked
    if b.height > lastHeight:
      result.err chain & ": the height map is not ordered"
    lastHeight = b.height
    let bd = blockDetail(store, session, b.hash)
    case bd.outcome
    of roFound: discard
    else:
      result.err chain & " block " & b.hash & ": " & bd.reason
      continue
    if bd.detail.height != b.height:
      result.err chain & " block " & b.hash & ": the height map says " &
        $b.height & ", the block says " & $bd.detail.height
    if bd.detail.chain != chain:
      result.err chain & " block " & b.hash & ": block claims chain '" &
        bd.detail.chain & "'"

    for txHash in bd.detail.transactions:
      inc result.transactionsChecked
      let tr = transaction(store, session, txHash)
      case tr.outcome
      of roFound: discard
      else:
        result.err chain & " tx " & txHash & ": " & tr.reason
        continue
      let v = tr.view
      # INDEPENDENT ORACLE 3: the block lists the transaction; the transaction
      # records its own position. Two objects written separately must agree.
      let pos = blockPosition(v)
      if pos.known and pos.blockHash != b.hash:
        result.err chain & " tx " & txHash & ": listed in block " & b.hash &
          " but records block " & pos.blockHash
      if pos.known and pos.height != b.height:
        result.err chain & " tx " & txHash & ": records height " & $pos.height &
          " in a block at height " & $b.height
      if v.facts.chain != chain:
        result.err chain & " tx " & txHash & ": facts claim chain '" &
          v.facts.chain & "'"
      if v.hasSelection and v.selection.tx != txHash:
        result.err chain & " tx " & txHash & ": the overlay is for " & v.selection.tx
      if not v.hasState:
        result.err chain & " tx " & txHash &
          ": generation " & session.generation & " publishes no txstate for it"
      for t in resolveTraces(store, session, v):
        checkTrace(store, session, v, t, result)

proc consumerConformance*(store: ObjectStore): ConformanceReport =
  ## Every chain the tree's registry publishes.
  var all = ConformanceReport()
  let cs = chains(store)
  if cs.len == 0:
    all.err "the tree's registry publishes no chains"
    return all
  for c in cs:
    let r = consumerConformance(store, c)
    all.chain = if all.chain.len == 0: r.chain else: all.chain & "," & r.chain
    all.generation = if all.generation.len == 0: r.generation else: all.generation
    all.blocksChecked += r.blocksChecked
    all.transactionsChecked += r.transactionsChecked
    all.tracesResolved += r.tracesResolved
    all.tracesReplayable += r.tracesReplayable
    for e in r.errors: all.errors.add e
  all
