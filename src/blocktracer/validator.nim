## The conformance validator (M5b).
##
## Both producers — the Demo Data Generator (M5c) and the real extractor/recorder
## (M6, M7, M10) — run this in CI. It checks a static tree + trace manifests
## against the single contract version. It reads **raw JSON**, so it validates any
## producer's output without that output having to pass through model.nim's types
## — which is what makes the demo and real trees interchangeable behind the seam.
##
## What it checks (Data-Contract.md §4):
##   - `root.json` / `manifest.json` carry the supported contract version;
##   - the discriminated-union transaction schema (Static-Site-Architecture §2.3);
##   - `availability: absent` handling — a reason, never a failed fetch (§2.3a);
##   - the four-layer split — immutable facts must NOT carry mutable fields (§2.3b);
##   - index and generation-root shape (§2);
##   - manifest fields, container size/hash, and derived `traceArtifactId` (§4, §2.1);
##   - **walkability**: every reference from `current.json` resolves (no dangles).
##
## It performs no cryptographic provenance check — v1 has none
## (Trace-Artifacts.md §8) — and it recomputes container hashes only structurally.

import std/[json, os, strutils, sets, tables]
import ./contract/[model, version, ids, searchidx, entrypage]
import ./chain/refusal_reasons
import ./chain/contract_rules

type
  Validator* = object
    root*: string                 ## filesystem path to the published tree root
    errors*: seq[string]
    visited: HashSet[string]      ## files reached during the walk
    registry: Table[string, JsonNode]  ## chain -> registry entry
    identifierEncodings: Table[string, ChainIdentifierEncoding]
      ## chain -> how that chain DECLARES its identifiers, read out of the tree
      ## under validation. See `encodingFor`.
    # Entities reached during the current generation's walk, so the render layer
    # (entry pages) and the /idx/** search indices can be checked for completeness:
    # every walked entity MUST have a page and MUST be resolvable in the hash index.
    walkedTx: seq[string]
    walkedBlock: seq[string]
    walkedAddr: seq[string]

const
  outcomeOveralls = ["succeeded", "reverted", "partial", "failedWithEffects"]
  availabilities = ["ready", "onDemand", "unsupported", "absent", "divergent"]
  validationStatuses = ["match", "divergent", "unchecked"]

proc err(v: var Validator, ctx, msg: string) =
  v.errors.add ctx & ": " & msg

proc loadJson(v: var Validator, rel: string): JsonNode =
  ## Load a tree-relative file, recording it as reached (walkability).
  let p = v.root / rel
  v.visited.incl rel
  if not fileExists(p):
    v.err(rel, "dangling reference — file does not exist")
    return nil
  try:
    result = parseFile(p)
  except CatchableError as e:
    v.err(rel, "invalid JSON: " & e.msg)
    result = nil

proc need(v: var Validator, n: JsonNode, ctx, field: string): bool =
  if n == nil or n.kind != JObject or field notin n:
    v.err(ctx, "missing required field '" & field & "'")
    return false
  true

proc mustBeOneOf(v: var Validator, n: JsonNode, ctx, field: string,
                 allowed: openArray[string]) =
  if not v.need(n, ctx, field): return
  let got = n[field].getStr
  if got notin allowed:
    v.err(ctx, "field '" & field & "' has value '" & got &
          "' not in {" & allowed.join(", ") & "}")

# ---------------------------------------------------------------------------

proc checkSourceBundles(v: var Validator, mrel, chain: string, m: JsonNode) =
  ## Every bundle a manifest RECOMMENDS must actually be published, and the
  ## `current.json` pointer for that code hash must resolve too
  ## (Source-Resolution.md §5, Trace-Artifacts.md §2.5).
  ##
  ## This edge is load-bearing rather than decorative: the CTFS container carries
  ## no source text, so a manifest naming a bundle that is not there yields a
  ## debugger that steps correctly through code it cannot display.
  if "sourceBundles" notin m: return
  let sb = m["sourceBundles"]
  if sb.kind != JObject: return
  for codeHash, idNode in sb:
    let bundleId = idNode.getStr
    if bundleId.len == 0:
      v.err(mrel, "sourceBundles['" & codeHash & "'] is empty")
      continue
    let dir = "src" / chain / codeHash
    # The pointer must exist and must agree with the id the manifest pinned.
    let curRel = dir / "current.json"
    let cur = v.loadJson(curRel)
    if cur == nil:
      v.err(mrel, "sourceBundles names code hash '" & codeHash &
            "' with no published " & curRel)
      continue
    let bundleRel = cur{"bundle"}.getStr
    if bundleRel.len == 0:
      v.err(curRel, "missing required field 'bundle'")
      continue
    let bundle = v.loadJson(bundleRel)
    if bundle == nil:
      v.err(curRel, "pointer references a missing bundle: " & bundleRel)
      continue
    if bundle{"codeHash"}.getStr != codeHash:
      v.err(bundleRel, "bundle codeHash disagrees with the path it is published at")
    # A bundle with no sources would satisfy every structural check and still be
    # useless, so require at least one source file.
    let srcs = bundle{"sources"}
    if srcs == nil or srcs.kind != JObject or srcs.len == 0:
      v.err(bundleRel, "source bundle carries no sources")
    else:
      for path, entry in srcs:
        if entry{"content"}.getStr.len == 0:
          v.err(bundleRel, "source '" & path & "' has empty content")

proc checkContainerAndManifest(v: var Validator, tid, txHash, chain,
                               execInputId: string, overlayBytes: int,
                               overlayRecorderBuild = "") =
  ## Derived-path check: the artifact must live exactly where the id says, and
  ## its manifest must be internally consistent (Trace-Artifacts §3, §4, §2.1).
  let sh = traceShards(tid)
  let dir = "t" / sh.a / sh.b / tid
  let mrel = dir / "manifest.json"
  let m = v.loadJson(mrel)
  if m == nil: return
  # ── AN UNSUPPORTED VERSION IS A REFUSAL, NOT A FINDING ALONGSIDE OTHERS ─────
  #
  # Data-Contract.md §3.1 rule 1: an unknown version token is refused BY NAME and
  # NOTHING IS READ. This used to record the error and then go on checking every
  # field of the manifest against THIS build's schema — which is precisely the
  # best-effort parse rule 1 forbids, and it produced a report in which the real
  # finding ("this artifact is from another contract version") sat among a dozen
  # consequences of reading it as though it were not.
  #
  # The snapshot half of the seam has always refused; this half did not, and "the
  # version refusal is the same statement in both halves" is the deliverable that
  # noticed. The message now names what it found AND what this build accepts, for
  # the reason §3.1 gives: a refusal that names only what it rejected makes the
  # reader go looking.
  if v.need(m, mrel, "schema"):
    let sv = m["schema"].getInt
    if not contractSupported(sv):
      v.err(mrel, "manifest schema version " & $sv &
            " is unsupported (this build reads " & $ContractVersion &
            "); refused by name rather than read in part — Data-Contract.md §3.1 rule 1")
      return
  if v.need(m, mrel, "traceArtifactId"):
    if m["traceArtifactId"].getStr != tid:
      v.err(mrel, "manifest traceArtifactId does not match its directory " & tid)
  if v.need(m, mrel, "executionInputId"):
    if m["executionInputId"].getStr != execInputId:
      v.err(mrel, "manifest executionInputId disagrees with the transaction facts")
  if v.need(m, mrel, "tx") and m["tx"].getStr != txHash:
    v.err(mrel, "manifest tx does not match the referencing transaction")
  for f in ["recorder", "profile", "container", "execution", "validation",
            "prestateStrategy"]:
    discard v.need(m, mrel, f)
  # ── AND `prestateStrategy` IS CHECKED FOR ITS VALUE, NOT ONLY ITS PRESENCE ──
  #
  # The loop above requires the member. That is all this half of the seam used to
  # do, and Chain-Support-Matrix.md §1.4 said so in as many words: the strategy
  # comes from a CLOSED set of six, "nothing in the tree enforces that today", and
  # an unlisted value published silently. A present-but-unlisted strategy is the
  # shape that matters — §1.4's rule is that such a value is a GAP IN THAT TABLE
  # and its remedy is a row there, never a new string in an artifact — so a
  # validator that only asked whether the field existed could not tell a producer
  # it had invented one.
  #
  # The set is the same data the snapshot reader draws from
  # (`tools/chain/snapshot-contract.json`, read at compile time), so the two
  # halves of the seam cannot come to disagree about what the six are.
  if "prestateStrategy" in m:
    let ps = m["prestateStrategy"].getStr
    if not isPrestateStrategy(ps):
      v.err(mrel, "manifest prestateStrategy '" & ps &
            "' is not one of Chain-Support-Matrix.md §1.4's six (" &
            prestateStrategyList() &
            "). An unlisted strategy is a gap in that table, not a free-text " &
            "field: add a row there saying what it means")
  # THE OVERLAY AND THE MANIFEST MUST NAME THE SAME RECORDER, and this is the
  # `overlayBytes` check one field over: the overlay advertises something about
  # the artifact and the artifact must agree.
  #
  # It is not redundant with the address derivation, which is the tempting
  # reading. The address was derived FROM the overlay's recorder, so a manifest
  # naming a different one is a container filed at an address that describes a
  # build other than the one it says produced it — two answers to "what recorded
  # this", one of which every published URL is derived from. The producer writes
  # both from one binding precisely so they cannot drift; nothing else notices
  # if that ever stops being true.
  if overlayRecorderBuild.len > 0 and "recorder" in m:
    let mb = m["recorder"]{"build"}.getStr
    if mb != overlayRecorderBuild:
      v.err(mrel, "the overlay addresses this trace under recorder build '" &
            overlayRecorderBuild & "' and its manifest says it was produced by '" &
            mb & "'")
  # container: bytes must equal the real file size; hash must match its bytes.
  if "container" in m:
    let c = m["container"]
    let crel = dir / c{"file"}.getStr("trace.ct")
    let cpath = v.root / crel
    v.visited.incl crel
    if not fileExists(cpath):
      v.err(mrel, "container file missing: " & crel)
    else:
      let bytes = readFile(cpath)
      if c{"bytes"}.getInt != bytes.len:
        v.err(mrel, "container.bytes " & $c{"bytes"}.getInt &
              " != actual file size " & $bytes.len)
      let want = contentHashSha1(bytes)
      if c{"hash"}.getStr != want:
        v.err(mrel, "container.hash does not match container bytes")
      # The TraceSelection overlay advertises the container's size so the client
      # can choose a fetch strategy before fetching. If it disagrees with the
      # artifact, the client sizes its fetch against a number that is not the
      # object it is about to request.
      if overlayBytes >= 0 and overlayBytes != bytes.len:
        v.err(mrel, "overlay advertises bytes " & $overlayBytes &
              " but the container is " & $bytes.len & " bytes")
  # Source bundles the manifest recommends must resolve (§2.5).
  v.checkSourceBundles(mrel, chain, m)
  # validation block is not optional decoration (§4).
  if "validation" in m:
    v.mustBeOneOf(m["validation"], mrel & ".validation", "status", validationStatuses)

proc registryFor(v: var Validator, chain: string): JsonNode =
  if chain in v.registry: return v.registry[chain]
  let reg = v.loadJson("registry" / "chains.v" & $ContractVersion & ".json")
  if reg == nil: return nil
  let chains = reg{"chains"}
  if chains == nil or chain notin chains:
    v.err("registry", "no recorder pin for chain '" & chain & "'")
    return nil
  v.registry[chain] = chains[chain]
  chains[chain]

proc encodingFor(v: var Validator, chain: string): ChainIdentifierEncoding =
  ## HOW THE TREE UNDER VALIDATION SAYS IT WRITES ITS IDENTIFIERS.
  ##
  ## Read from the tree's own registry rather than assumed, which is the whole
  ## point of the validator here: it recomputes the shard path the way the
  ## PUBLISHER declared, so a producer that keyed its objects one way and declared
  ## another fails this walk with the object reported missing. A validator that
  ## carried its own opinion of the encoding could not catch that at all — it
  ## would agree with whichever producer shared its opinion.
  ##
  ## Cached per chain in `identifierEncodings` for `registryFor`'s reason: the
  ## walk asks per transaction and per address.
  ##
  ## A registry that could not be read at all yields the compatibility layout, not
  ## a crash: `registryFor` has already recorded the error, and a walk that threw
  ## here would report one failure instead of the list this validator exists to
  ## produce.
  if chain in v.identifierEncodings: return v.identifierEncodings[chain]
  let row = v.registryFor(chain)
  var enc: ChainIdentifierEncoding
  try:
    enc = parseChainIdentifierEncoding(row)
  except ValueError as e:
    v.err("registry", "chain '" & chain & "': " & e.msg)
    enc = parseChainIdentifierEncoding(nil)
  v.identifierEncodings[chain] = enc
  enc

proc checkIdentifierForms(v: var Validator, chain, rel, kind, named: string,
                          carried: string) =
  ## **THE KEY FORM AND THE DISPLAY FORM, CHECKED WHERE THE TREE STATES BOTH.**
  ##
  ## Per-encoding case handling turns one rule into two published facts, and a
  ## rule nothing measures is prose. So this asserts both, per object:
  ##
  ##   1. `named` — the identifier as it appears in the object's PATH — is its
  ##      own key form. A producer that published `0xAbCd….json` under the shard
  ##      `abcd` wrote a file no client can address, because a client folds
  ##      before it derives. This bites on an uppercase hex object name and is
  ##      the arm that would have caught the fold being applied to the shard and
  ##      not to the name.
  ##   2. `carried` — the identifier the object's BODY states — is the SAME
  ##      identifier, i.e. its key form is the name. Differing in case where the
  ##      encoding permits it is legal and is the whole point; differing in
  ##      anything else means the object is about something other than its path.
  ##   3. `carried` is its own display form. For `hex` that is vacuous by
  ##      construction — the rule preserves, so every string is its own display
  ##      form — and it is stated all the same, because for `bech32` and
  ##      `bech32m` it is not: BIP-173 makes a mixed-case string invalid, so a
  ##      published `Addr1Q…` is an address no reader may render. A check that
  ##      is vacuous for the one encoding this tree publishes and biting for the
  ##      four it is gated on is the shape this whole seam is: the point is that
  ##      it is HERE when the first non-hex producer arrives, keyed off the
  ##      declaration rather than off a token somebody remembered to add.
  ##
  ## An empty `carried` means the object states no identifier of its own and
  ## rules 2 and 3 have nothing to be about; the object's own `need` checks are
  ## what report a missing field, and reporting it twice from here would name the
  ## wrong defect.
  let enc = v.encodingFor(chain)
  var key: string
  try:
    key = identifierKeyForm(enc, kind, named)
  except ValueError as e:
    # An omitted kind, or a token outside the closed set. Already reported
    # against the registry by `encodingFor`; naming it once more per object
    # would bury the walk's real findings.
    v.err(rel, "cannot normalise a " & kind & " identifier for this chain: " &
          e.msg)
    return
  if key != named:
    v.err(rel, "the " & kind & " identifier in this object's path is '" & named &
          "', whose key form is '" & key & "'. A sharded path is derived from " &
          "and named by the KEY form, so this object is at an address no " &
          "client computes: it folds before it derives.")
  if carried.len == 0: return
  if identifierKeyForm(enc, kind, carried) != key:
    v.err(rel, "this object is published as " & kind & " '" & named &
          "' and carries '" & carried & "'. Those are two identifiers, not two " &
          "spellings of one: their key forms differ.")
  let shown = identifierDisplayForm(enc, kind, carried)
  if shown != carried:
    v.err(rel, "this object carries the " & kind & " identifier '" & carried &
          "', whose display form is '" & shown & "'. The body carries what a " &
          "page renders, and this encoding's rule says that is not it.")

proc checkExecTrace(v: var Validator, ctx: string, t: JsonNode,
                    chain, txHash: string, execIds: Table[string, string]) =
  v.mustBeOneOf(t, ctx, "availability", availabilities)
  let avail = t{"availability"}.getStr
  # §2.3a: a structurally-unobservable execution is `absent` WITH a reason,
  # never a failed fetch.
  # ING-3: a refusal reason, when the row carries one, must be a member of the
  # closed set — and only an untraced row may carry one at all. Checked here
  # rather than only at ingest because this validator is what stands between a
  # tree and publication: a reason outside the set is a failure of the pipeline,
  # and a tree that carried one would render a refusal the client cannot name.
  let rr = t{"refusalReason"}.getStr
  if rr.len > 0:
    if not isRefusalReason(rr):
      v.err(ctx, "refusalReason '" & rr & "' is not in the closed set (" &
            refusalReasonList() & "). A reason outside the set is a failure of " &
            "the pipeline, not a free-text fallback")
    if avail in ["ready", "divergent"]:
      # The fold in the other direction. A traced execution declined nothing,
      # and a refusal reason on one would be counted as a refusal by every
      # consumer that ranges over them.
      v.err(ctx, "availability '" & avail & "' is traced and must carry no " &
            "refusalReason, but carries '" & rr & "'")
  if avail in ["absent", "unsupported"]:
    if t{"reason"}.getStr.len == 0:
      v.err(ctx, "availability '" & avail & "' must carry a non-empty reason")
    return  # no artifact expected
  if avail == "onDemand":
    return  # artifact may legitimately not exist yet
  if avail in ["ready", "divergent"]:
    # Must resolve to a real, well-formed artifact. Derive its URL exactly as the
    # client would (Trace-Artifacts §2.1): executionInputId + registry pin.
    let sel = t{"selector"}.getStr("")
    let key = if sel.len > 0: sel else: "*"
    var execInputId = ""
    if key in execIds: execInputId = execIds[key]
    elif execIds.len == 1:
      # A single-execution transaction: the overlay's singular `trace` need not
      # name a selector; the one execution is unambiguous.
      for _, vId in execIds: execInputId = vId
    if execInputId.len == 0:
      v.err(ctx, "overlay execution selector '" & sel &
            "' has no matching executionInputId in the transaction facts")
      return
    let reg = v.registryFor(chain)
    if reg == nil: return
    # EXACTLY AS THE CLIENT WOULD: the row's own recorder when it names one, the
    # chain's pin otherwise (blocktracer_client/trace.nim `resolveExec`). Reading
    # the pin unconditionally here would make the validator green on precisely
    # the tree the client cannot open — a chain whose containers came from two
    # recorders — which is the one shape this check exists to grade.
    let rec = if t.hasKey("recorder"): t["recorder"] else: reg{"recorder"}
    let prof = reg{"profile"}
    if rec == nil or rec{"id"}.getStr.len == 0 or rec{"build"}.getStr.len == 0:
      v.err(ctx, "no recorder to derive this trace's address from: the overlay " &
            "row names none and the chain registry pins none")
      return
    let tid = deriveTraceArtifactId(execInputId, rec{"id"}.getStr,
      rec{"build"}.getStr, prof{"hash"}.getStr, reg{"traceSchema"}.getStr)
    # -1 means the overlay did not advertise a size, which is legal; a size that
    # is present must be the truth.
    let overlayBytes = if "bytes" in t: t["bytes"].getInt else: -1
    v.checkContainerAndManifest(tid, txHash, chain, execInputId, overlayBytes,
                                rec{"build"}.getStr)

# ╔══════════════════════════════════════════════════════════════════════════╗
# ║ THE VALIDATOR IS EXEMPT FROM "BUILD EVERY PATH WITH THE PATH BUILDERS",   ║
# ║ AND THE EXEMPTION IS DELIBERATE, NARROW, AND STATED HERE BECAUSE NOTHING  ║
# ║ ELSE IN THIS FILE SAID SO.                                                ║
# ╚══════════════════════════════════════════════════════════════════════════╝
#
# `contract/shards.nim` moved the six path builders down precisely so that no
# caller would ever again pair a FOLDED shard segment with a RAW name segment —
# the half-folded construction that made the producer write
# `d/{chain}/tx/0a80/0x0A807E….json` while the client computed
# `…/0x0a807e….json`, a 404. Every producer and every consumer now calls
# `txFactsPath`, `blockPath` and their siblings.
#
# THIS FILE STILL BUILDS THOSE PATHS BY HAND, on purpose, and the half-folded
# shape is the point rather than an oversight:
#
#   * `checkTransaction` below computes `shardKeyFor(…)` — which FOLDS — beside a
#     RAW `txHash` name segment, and `checkGeneration` open-codes
#     `d/{chain}/block/{raw}.json` while `blockPath` now key-forms.
#   * `txHash` and `bh` are the identifiers a published BLOCK and a published
#     BLOCK INDEX actually listed. The validator's job is to report what the tree
#     SAYS, and folding the reference before resolving it would make a
#     non-key-form reference RESOLVE — the object is there, under its key form —
#     and the tree would validate while carrying a reference no client could
#     follow. The diagnosis would be destroyed by the very normalisation that is
#     correct everywhere else.
#   * MEASURED, and this is what makes it a rule rather than a preference: the
#     identical mutation gives 4 errors on a transaction reference (the dangle
#     plus `whose key form is …`) and 1 on a block reference (the dangle alone) —
#     see `checkGeneration`'s note. Both are errors. Under the builders, both
#     would be silence.
#
# SO THE RULE HERE IS THE INVERSE OF THE RULE ELSEWHERE: a path this file builds
# to CHECK a reference is built from the reference AS WRITTEN, and
# `checkIdentifierForms` is what separately asserts that the reference was in key
# form. A future reader who "fixes" these call sites to use the builders will
# make every one of those assertions unreachable and every test still pass.
#
# WHAT IS NOT EXEMPT: anything this file derives in order to ASK A QUESTION of
# its own rather than to follow a reference. `assertHashResolves` keys the §5
# index through `hashPrefix` and the chain's declared encoding, because there it
# is the client's computation being reproduced, not the tree's claim being
# quoted.

proc checkTransaction(v: var Validator, chain, txHash, gen, tsv: string) =
  v.walkedTx.add txHash
  # Folded shard, RAW name — see the exemption above. Not a bug, and not to be
  # replaced with `txFactsPath`.
  let sh = shardKeyFor(v.encodingFor(chain), KindTransaction, txHash)
  # --- immutable TransactionFacts (§2.3) ---
  let frel = "d" / chain / "tx" / sh / txHash & ".json"
  let f = v.loadJson(frel)
  # ── THE TWO FORMS, CHECKED ON THE REFERENCE AND ON THE BODY ────────────────
  #
  # OUTSIDE the `f != nil` guard on purpose. `txHash` is the identifier a
  # published BLOCK listed, and its form is a fact about that reference whether
  # or not the object it names is there — a block that referenced a transaction
  # by a checksummed spelling would dangle AND be wrong, and reporting only the
  # dangle would send the reader looking for a missing file.
  #
  # It is also what makes this walk's own path construction sound: `frel` is
  # built from the raw `txHash`, so it agrees with `blocktracer_client/paths.nim`
  # — which names the object by its key form — exactly when the reference is
  # already in key form, which is what this asserts.
  #
  # `id` is a union and only its `hash` member is an encoded identifier —
  # Substrate's `blockIndex` is a pair, which is why a kind may be omitted from a
  # declaration at all — so a union of another kind carries nothing for the body
  # half of this check to be about.
  v.checkIdentifierForms(chain, frel, KindTransaction, txHash,
                         (if f != nil and f{"id"}{"kind"}.getStr == "hash":
                            f{"id"}{"hash"}.getStr else: ""))
  var execIds = initTable[string, string]()
  if f != nil:
    for field in ["chain", "id", "order", "outcome", "roles", "cost",
                  "payload", "logs", "codeEdges", "executions", "native"]:
      discard v.need(f, frel, field)
    # discriminated unions must carry their kind
    if "id" in f: discard v.need(f["id"], frel & ".id", "kind")
    if "order" in f: discard v.need(f["order"], frel & ".order", "kind")
    if "outcome" in f:
      v.mustBeOneOf(f["outcome"], frel & ".outcome", "overall", outcomeOveralls)
    # §2.3b: mutable interpretation must NOT be baked into the immutable facts.
    for forbidden in ["canonical", "canonicality", "finality", "trace",
                      "validation"]:
      if forbidden in f:
        v.err(frel, "immutable facts must not carry mutable field '" &
              forbidden & "' (four-layer split, §2.3b)")
    if "executions" in f:
      for e in f["executions"]:
        let sel = e{"selector"}.getStr("")
        let eid = e{"executionInputId"}.getStr
        if eid.len == 0:
          v.err(frel, "execution selector '" & sel & "' missing executionInputId")
        execIds[if sel.len > 0: sel else: "*"] = eid
  # --- GenerationTransactionState (§2.3b) ---
  let strel = "d" / chain / "g" / gen / "txstate" / sh / txHash & ".json"
  let st = v.loadJson(strel)
  if st != nil:
    discard v.need(st, strel, "canonical")
    discard v.need(st, strel, "finality")
  # --- TraceSelection overlay (§2.3a/§2.3b) ---
  let orel = "d" / chain / "ts" / tsv / sh / txHash & ".json"
  let ov = v.loadJson(orel)
  if ov != nil:
    if "executions" in ov:
      for t in ov["executions"]:
        v.checkExecTrace(orel & ".executions[]", t, chain, txHash, execIds)
    elif "trace" in ov:
      v.checkExecTrace(orel & ".trace", ov["trace"], chain, txHash, execIds)
    else:
      v.err(orel, "overlay must carry either 'trace' or 'executions'")

# ---------------------------------------------------------------------------
# Optional render + search-index layers (Static-Site-Architecture §2, §4;
# Search-And-Routing §5, §6). The sealed generation root ENUMERATES whichever of
# these layers a generation carries (§2.9: entry pages are "route" objects, `/idx/**`
# is "in root"). When declared, they must be present and complete: every entity the
# validator walked must have an entry page and must resolve in the hash index. A
# data-only tree (no `render`/`idx` in root) is still contract-valid — the layers are
# additive, `may decline` for old clients (§2.9).
# ---------------------------------------------------------------------------

proc loadBytes(v: var Validator, rel: string): tuple[data: string, ok: bool] =
  let p = v.root / rel
  v.visited.incl rel
  if not fileExists(p):
    v.err(rel, "declared in generation root but missing")
    return ("", false)
  (readFile(p), true)

proc checkEntryPage(v: var Validator, htmlRel, canonicalPath, robots,
                    wantKind, wantId: string): JsonNode =
  ## Shared entry-page conformance: the page exists, carries the right metadata, and
  ## inlines a `#bt-data` island whose JSON identifies the entity (§4.2). Returns the
  ## parsed inlined data (or nil) so the caller can cross-check it against the data
  ## plane — an entry page is a materialised view, never a second source of truth (§3.1).
  let (html, ok) = v.loadBytes(htmlRel)
  if not ok: return nil
  if ("<link rel=\"canonical\" href=\"" & siteBase & canonicalPath & "\">") notin html:
    v.err(htmlRel, "missing/incorrect canonical link for " & canonicalPath)
  if ("<meta name=\"robots\" content=\"" & robots & "\">") notin html:
    v.err(htmlRel, "missing/incorrect robots policy (expected '" & robots & "')")
  let (payload, found) = extractInlineData(html)
  if not found:
    v.err(htmlRel, "no inlined #bt-data island (§4.2)")
    return nil
  # The payload must be intact JSON after unescaping — the escaping of <, >, & must
  # round-trip (a `</script>` breakout would corrupt it here).
  var data: JsonNode
  try: data = parseJson(payload)
  except CatchableError as e:
    v.err(htmlRel, "inlined data is not valid JSON: " & e.msg)
    return nil
  if data{"kind"}.getStr != wantKind:
    v.err(htmlRel, "inlined data.kind '" & data{"kind"}.getStr &
          "' != expected '" & wantKind & "'")
  if wantId.len > 0 and data{wantKind & "Hash"}.getStr("") != wantId and
     data{"address"}.getStr("") != wantId and data{"txHash"}.getStr("") != wantId and
     data{"blockHash"}.getStr("") != wantId:
    v.err(htmlRel, "inlined data does not identify entity " & wantId)
  data

proc checkRenderLayer(v: var Validator, chain: string, root: JsonNode) =
  let render = root{"render"}
  if render == nil: return   # data-only tree — entry pages not required
  # Home (Page-Descriptions §2) — the one page that is index,follow (§5 class I0).
  let homeRel = render{"home"}.getStr("index.html")
  let home = v.checkEntryPage(homeRel, "/", "index,follow", "home", "")
  if home != nil:
    var listed = false
    let chains = home{"chains"}
    if chains != nil:
      for c in chains:
        if c.getStr == chain: listed = true
    if not listed:
      v.err(homeRel, "home page does not list chain '" & chain & "'")
  if not render{"entryPages"}.getBool(false): return
  # Every walked transaction, block and address is an ordinary addressable entity
  # (§5 class N1, noindex,follow) and MUST have a per-entity page inlining its data.
  for tx in v.walkedTx:
    let rel = chain / "tx" / tx / "index.html"
    let d = v.checkEntryPage(rel, "/" & chain & "/tx/" & tx, "noindex,follow", "tx", tx)
    if d != nil:
      let onDisk = v.loadJson("d" / chain / "tx" /
                              shardKeyFor(v.encodingFor(chain), KindTransaction, tx) /
                              tx & ".json")
      if onDisk != nil and d{"facts"} != onDisk:
        v.err(rel, "inlined tx facts differ from the /d data plane (not a view)")
  for bh in v.walkedBlock:
    let rel = chain / "block" / bh / "index.html"
    let d = v.checkEntryPage(rel, "/" & chain & "/block/" & bh, "noindex,follow", "block", bh)
    if d != nil:
      let onDisk = v.loadJson("d" / chain / "block" / bh & ".json")
      if onDisk != nil and d{"block"} != onDisk:
        v.err(rel, "inlined block detail differs from the /d data plane (not a view)")
  for a in v.walkedAddr:
    discard v.checkEntryPage(chain / "address" / a / "index.html",
      "/" & chain & "/address/" & a, "noindex,follow", "address", a)

proc assertHashResolves(v: var Validator, shards: Table[string, string],
                        prefixLen: int, identifier, chain: string, kind: int) =
  ## Is this entity resolvable through the §5 index?
  ##
  ## THE ENCODING COMES FROM THE CHAIN'S OWN DECLARATION, read back out of the
  ## tree under validation — the same value the producer keyed with. A validator
  ## that assumed hex here would pass a base58 chain's tree by looking in a shard
  ## the producer never wrote and reporting the miss as the producer's.
  let encoding = try:
      v.encodingFor(chain).encodingFor(identifierKindOf(kind))
    except ValueError as e:
      v.err("idx/hash", "cannot key " & hkName(kind) & " " & identifier &
            " on chain " & chain & ": " & e.msg)
      return
  let prefix = hashPrefix(encoding, identifier, prefixLen)
  if prefix notin shards:
    v.err("idx/hash", "no shard covers " & hkName(kind) & " " & identifier)
    return
  var hit = false
  for e in lookupHash(shards[prefix], encoding, identifier):
    if e.chain == chain and e.kind == kind: hit = true
  if not hit:
    v.err("idx/hash", "hash index does not resolve " & hkName(kind) & " " &
          identifier & " on chain " & chain)

# ── EVERY ARRAY THIS WALK ITERATES IS TAKEN WITH `getElems` ───────────────────
#
# `for x in node{"k"}` ITERATES A NIL `JsonNode` WHEN THE KEY IS ABSENT, and `items`
# on a nil node does not raise — it SEGFAULTS. So a published tree whose generation
# root carried `maps` but no `maps.height` KILLED this validator rather than being
# walked or reported, and a dead process is the least actionable report there is.
# Reproduced by deleting that one member from a conforming tree: exit 139, no
# finding, no output at all.
#
# `getElems` answers the empty sequence for an absent key, which is also the right
# READING of it: an absent array and an empty one say the same thing here, and both
# are shapes a producer legitimately writes — a generation with no height epochs, a
# chain with no address lists, a block that settled no transaction. A finding would
# be wrong as well as noisy.
#
# It matters more than it did, because this validator is now SHIPPED: the recorder
# conformance kit hands it to people whose trees are malformed by definition, which
# is what they are running it to find out.

proc checkSearchIndices(v: var Validator, chain: string, root: JsonNode) =
  let idx = root{"idx"}
  if idx == nil: return   # no search indices in this generation
  # --- §5 the global hash index ---
  let hi = idx{"hash"}
  if hi == nil:
    v.err("idx", "root.idx missing 'hash' descriptor")
  else:
    let ver = hi{"version"}.getStr("1")
    let prefixLen = hi{"prefixLen"}.getInt(2)
    var shards = initTable[string, string]()
    for pn in hi{"shards"}.getElems:
      let prefix = pn.getStr
      let (data, ok) = v.loadBytes("idx" / "hash" / ver / prefix & ".bin")
      if not ok: continue
      let dec = decodeHashShard(data)
      if dec.err.len > 0:
        v.err("idx/hash/" & ver / prefix & ".bin", "malformed shard: " & dec.err)
        continue
      if dec.prefixLen != prefixLen:
        v.err("idx/hash/" & ver / prefix & ".bin",
              "shard prefixLen " & $dec.prefixLen & " != root's " & $prefixLen)
      shards[prefix] = data
    # Coverage: the index must actually index the demo's dataset (§5).
    for h in v.walkedTx: v.assertHashResolves(shards, prefixLen, h, chain, hkTx)
    for h in v.walkedBlock: v.assertHashResolves(shards, prefixLen, h, chain, hkBlock)
    for h in v.walkedAddr: v.assertHashResolves(shards, prefixLen, h, chain, hkAddress)
  # --- §6 name shards ---
  for mp in idx{"names"}.getElems:
    let meta = v.loadJson(mp.getStr)
    if meta == nil: continue
    for f in ["shardBits", "shardCount", "shards"]: discard v.need(meta, mp.getStr, f)
    let shardBits = meta{"shardBits"}.getInt(0)
    for sp in meta{"shards"}.getElems:
      let (data, ok) = v.loadBytes(sp.getStr)
      if not ok: continue
      let dec = decodeNameShard(data)
      if dec.err.len > 0:
        v.err(sp.getStr, "malformed name shard: " & dec.err); continue
      if dec.shardBits != shardBits:
        v.err(sp.getStr, "shard shardBits disagrees with meta.json")
      for t in dec.terms:
        # Every term must hash into the shard it was placed in (§6 sharding rule).
        if shardOf(t.term, shardBits) != dec.shardNo:
          v.err(sp.getStr, "term '" & t.term & "' does not hash to this shard")
        for p in t.postings:
          if p.kind.len == 0 or p.id.len == 0:
            v.err(sp.getStr, "posting for '" & t.term & "' missing kind/id")
          if p.provenance notin [provCurated, provSelfDeclared]:
            v.err(sp.getStr, "posting for '" & t.term &
                  "' has no valid provenance (§6.2)")

proc checkGeneration(v: var Validator, chain, gen: string) =
  v.walkedTx = @[]; v.walkedBlock = @[]; v.walkedAddr = @[]
  let rrel = "d" / chain / "g" / gen / "root.json"
  let root = v.loadJson(rrel)
  if root == nil: return
  # THE SAME REFUSAL, FOR THE SAME REASON — see the manifest gate above. Walking a
  # generation whose root declares a version this build does not read means loading
  # every map and every object in it against a schema they were not written to, and
  # reporting the resulting noise as findings.
  if v.need(root, rrel, "contractVersion"):
    let cv = root["contractVersion"].getInt
    if not contractSupported(cv):
      v.err(rrel, "unsupported contract version " & $cv &
            " (validator supports " & $ContractVersion &
            "); refused by name rather than read in part — Data-Contract.md §3.1 rule 1")
      return
  let tsv = root{"traceSelectionVersion"}.getStr("1")
  let maps = root{"maps"}
  if maps == nil:
    v.err(rrel, "missing 'maps' — generation root must reference every derived map")
    return
  discard v.loadJson(maps{"summary"}.getStr)
  # height epochs
  for p in maps{"height"}.getElems: discard v.loadJson(p.getStr)
  # block indices -> block details -> transactions
  for p in maps{"blocks"}.getElems:
    let bi = v.loadJson(p.getStr)
    if bi == nil: continue
    for bh in bi{"blocks"}.getElems:
      v.walkedBlock.add bh.getStr
      # Open-coded rather than `blockPath`, which now key-forms — see the
      # exemption block above `checkTransaction`. `bh` is what the block index
      # WROTE, and resolving its key form instead would make a mis-spelled
      # reference resolve and delete the diagnosis.
      let brel = "d" / chain / "block" / bh.getStr & ".json"
      let bd = v.loadJson(brel)
      # ── OUTSIDE THE `bd == nil` GUARD, MIRRORING `checkTransaction` ──────────
      #
      # `bh` is the identifier a published BLOCK INDEX listed, and its form is a
      # fact about that reference whether or not the object it names is there — a
      # generation that referenced a block by a checksummed spelling would dangle
      # AND be wrong, and reporting only the dangle sends the reader looking for a
      # missing file. That argument was made at length on the transaction arm and
      # this arm had it the other way round: MEASURED, the identical mutation gave
      # 4 errors on a transaction reference (dangle plus `whose key form is …`) and
      # 1 on a block reference (dangle only). So "every published block reference
      # is its own key form" held only for references that RESOLVE — which is the
      # arm `blockPath`'s old no-fold reasoning leant on.
      #
      # An absent object carries no body, so rules 2 and 3 have nothing to be
      # about and `carried` is empty, which `checkIdentifierForms` documents.
      v.checkIdentifierForms(chain, brel, KindBlock, bh.getStr,
                             (if bd != nil: bd{"hash"}.getStr else: ""))
      if bd == nil: continue
      for tx in bd{"transactions"}.getElems:
        v.checkTransaction(chain, tx.getStr, gen, tsv)
  # address lists -> segments
  for p in maps{"addr"}.getElems:
    let al = v.loadJson(p.getStr)
    # ── OUTSIDE THE `al == nil` GUARD, FOR THE BLOCK ARM'S REASON ─────────────
    #
    # `p` is the path the generation root REFERENCES, so its name segment is a
    # published reference to an address and its form is a fact about that
    # reference whether or not the object resolves. It was inside both this guard
    # and an `"address" in al` one, so a sealed root naming an address index in a
    # non-key form got the dangle alone.
    #
    # The published path names the key form; the body carries the display form.
    # `p` is the object's OWN path, so the name is read out of the layout rather
    # than recomputed — recomputing it here would compare the derivation to
    # itself.
    v.checkIdentifierForms(chain, p.getStr, KindAddress,
                           p.getStr.splitFile.name,
                           (if al != nil: al{"address"}.getStr else: ""))
    if al == nil: continue
    if "address" in al:
      v.walkedAddr.add al{"address"}.getStr
    for sp in al{"segments"}.getElems: discard v.loadJson(sp.getStr)
  # Optional render + search-index layers the sealed root enumerates (§2.9).
  v.checkRenderLayer(chain, root)
  v.checkSearchIndices(chain, root)

proc validateTree*(root: string): seq[string] =
  ## Validate a published tree rooted at `root`. Returns the list of conformance
  ## errors — empty means the tree conforms to contract version `ContractVersion`.
  var v = Validator(root: root, visited: initHashSet[string]())
  let crel = "d"  # discover chains under /d
  if not dirExists(root / crel):
    return @["no /d data plane found under " & root]
  for chainDir in walkDir(root / crel):
    if chainDir.kind != pcDir: continue
    let chain = extractFilename(chainDir.path)
    let cur = v.loadJson("d" / chain / "current.json")
    if cur == nil: continue
    for field in ["chain", "generation", "head", "finalized"]:
      discard v.need(cur, "d" / chain / "current.json", field)
    let gen = cur{"generation"}.getStr
    if gen.len > 0:
      v.checkGeneration(chain, gen)
  v.errors
