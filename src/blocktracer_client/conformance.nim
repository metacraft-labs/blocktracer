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
import ../blocktracer/contract/container_encoding

type
  ConformanceReport* = object
    chain*: string
    generation*: string
    blocksChecked*: int
    transactionsChecked*: int
    tracesResolved*: int
    tracesReplayable*: int
    errors*: seq[string]
    notMeasured*: seq[string]
      ## ── CHECKS THAT COULD NOT BE RUN, WITH THEIR REASON (CCP-6) ───────────
      ##
      ## Neither an error nor a silence. `CTFS-Reader-Revision-Rollout` CRR-3's
      ## table has three rows and this is the first: the TOOL is absent, so the
      ## remedy is to supply it (or to obtain the object differently) and not to
      ## change the tree. Reporting it as an error would make a host without an
      ## optional decoder declare a conformant tree non-conformant; dropping it
      ## would let a check become optional without anybody being told.
      ##
      ## `ok` is unchanged and still reads only `errors`, so a tree with a named
      ## gap still passes — and `blocktracer-client-conformance` PRINTS the gap.
      ## One occupant today: the raw-container figures behind a pre-compressed
      ## object, where no brotli decoder is on PATH.

proc ok*(r: ConformanceReport): bool = r.errors.len == 0

proc err(r: var ConformanceReport, msg: string) = r.errors.add msg

proc unmeasured(r: var ConformanceReport, msg: string) = r.notMeasured.add msg

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
    #
    # ── AND "SERVED" DEPENDS ON WHO IS ASKING (CCP-6) ─────────────────────────
    #
    # This is the third of the three doors CCP-6 names, and it is the one with
    # the most consumers behind it: the SDK's `store.get` is whatever transport
    # the embedder gave it. A browser's `fetch` NEGOTIATES, so it holds the raw
    # container and the two comparisons below are exactly right. `store.localTree`
    # — which `blocktracer-client-conformance` uses, and which the pre-render pass
    # and this suite use — is a `readFile` and negotiates nothing, so against a
    # pre-compressed object it holds the bytes AT REST.
    #
    # Before this arm the un-negotiated read reported
    #     container declares 77824 bytes, served 1058
    # a format defect that does not exist, in a report whose entire purpose is to
    # tell a recorder team what a consumer could not do.
    let c = store.get(t.containerPath)
    let encParsed = parseContainerEncoding(t.manifest.container.encoding)
    if not c.found:
      r.err v.hash & " execution '" & t.selector & "': container " &
        t.containerPath & " is not published"
    elif not encParsed.ok:
      # §1c: by name, never defaulted to identity.
      r.err v.hash & " execution '" & t.selector & "': " & encParsed.why
    elif encParsed.enc != ceIdentity:
      # ── THE PRE-COMPRESSED OBJECT, AND THIS PACKAGE CANNOT KNOW WHICH
      #    REPRESENTATION ITS TRANSPORT DELIVERED ──────────────────────────────
      #
      # That is the fact the branch is shaped around, and getting it wrong once
      # is what produced this comment. The store's `fetchProc` is the CONSUMER'S:
      # a browser NEGOTIATES and hands over the raw container; `store.localTree`
      # is a `readFile` and hands over the object at rest;
      # `verify/negotiating_store` hands over the raw container again, by running
      # a codec outside this package. All three arrive here as "some bytes", with
      # no header and no parameter saying which.
      #
      # So the decision is made FROM THE BYTES against the manifest's two sets of
      # figures, and the first version of this branch — which assumed the at-rest
      # bytes and compared `storedBytes` first — reported a NEGOTIATED read as a
      # length mismatch, i.e. called a browser's correct fetch a defect.
      if looksLikeContainer(c.body):
        # NEGOTIATED (or decompressed by the consumer's own transport). The raw
        # figures apply and are fully checkable, with no codec in this package.
        if c.body.len != t.manifest.container.bytes:
          r.err v.hash & " execution '" & t.selector & "': container declares " &
            $t.manifest.container.bytes & " bytes and " & $c.body.len &
            " byte(s) arrived as a container. This transport negotiated '" &
            $encParsed.enc & "', so the raw figures are the ones that apply"
        elif contentHashSha1(c.body) != t.manifest.container.hash and
             t.manifest.container.hash.startsWith("sha1:"):
          r.err v.hash & " execution '" & t.selector &
            "': the container bytes do not match the manifest's traceContentHash"
      elif c.body.len == t.manifest.container.storedBytes and
           (t.manifest.container.storedHash.len == 0 or
            t.manifest.container.storedHash == contentHashSha1(c.body)):
        # NOT NEGOTIATED, and the object at rest is verified EXACTLY — by length
        # and by sha1, with no codec. That is the whole purpose of `storedBytes`
        # and `storedHash`: a consumer that cannot decode still reaches a verdict
        # about the bytes in front of it rather than a skip.
        #
        # What is left is the RAW figures, and this package cannot produce them:
        # its boundary bans `osproc` and bans `src/blocktracer/publish/`, so there
        # is no decoder here and there is not meant to be one. Reporting that as
        # an ERROR would declare a conformant tree non-conformant for a reason the
        # tree has no part in; dropping it would let the check become optional
        # silently. So it is the report's third channel, in the consumer's own
        # terms — "install brotli" is wrong advice for a package that may not
        # call one.
        r.unmeasured v.hash & " execution '" & t.selector &
          "': container.bytes (" & $t.manifest.container.bytes & ") and container.hash " &
          "describe the RAW container and were NOT CHECKED — " &
          noDecoderReason("the Client SDK") & ". The object at rest WAS checked: " &
          $c.body.len & " byte(s) against container.storedBytes, and its sha1 against " &
          "container.storedHash"
      else:
        # NEITHER REPRESENTATION, which is a real finding rather than a third
        # state: the bytes are not a container and are not the object the manifest
        # says is at rest, so whatever this transport delivered is described by
        # nothing the producer wrote.
        r.err v.hash & " execution '" & t.selector & "': " & $c.body.len &
          " byte(s) arrived and they are neither the raw container (" &
          $t.manifest.container.bytes & " bytes, which is what a transport " &
          "negotiating '" & $encParsed.enc & "' delivers) nor the object at rest (" &
          $t.manifest.container.storedBytes & " bytes). " &
          unNegotiatedDiagnosis(t.containerPath, encParsed.enc, c.body.len,
                                t.manifest.container.storedBytes,
                                t.manifest.container.bytes)
    elif c.body.len != t.manifest.container.bytes:
      # IDENTITY, and the diagnosis forks on what the bytes ARE. A short read of a
      # container is a format defect; bytes that are not a container at all, under
      # a manifest that declares no encoding, is a different one — and saying
      # which costs one branch.
      if looksLikeContainer(c.body):
        r.err v.hash & " execution '" & t.selector & "': container declares " &
          $t.manifest.container.bytes & " bytes, served " & $c.body.len
      else:
        r.err v.hash & " execution '" & t.selector & "': container declares " &
          $t.manifest.container.bytes & " bytes, served " & $c.body.len &
          ", and those bytes do not begin with the CTFS magic. The manifest declares " &
          "no Content-Encoding, so this is not the un-negotiated-fetch case CCP-6 " &
          "describes; a pre-compressed object would say so in container.encoding"
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
    # THE THIRD CHANNEL IS ROLLED UP TOO, and leaving it out was a real defect for
    # the length of one measurement: the per-chain report carried the NOT MEASURED
    # entries and this aggregate dropped them, so `blocktracer-client-conformance`
    # over a pre-compressed tree printed a clean `OK` with the gap it had just
    # recorded nowhere in sight. That is the exact shape this channel exists to
    # prevent, produced by the aggregation rather than by the check.
    for m in r.notMeasured: all.notMeasured.add m
  all
