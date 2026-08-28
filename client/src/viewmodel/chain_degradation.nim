## viewmodel/chain_degradation.nim
##
## The chain- and delivery-shaped half of the degraded-state catalogue, as
## enums.
##
## `BlockTracer/Page-Descriptions.md` §14 ends with the rule this module
## exists to make true:
##
##   "Every row above is a **value of an enum on a ViewModel**, not a branch
##   in a view, which is what makes each of them testable without a browser."
##
## and `BlockTracer/Front-End-Architecture.md` §3 repeats it as a design rule:
## "anything a page *decides* lives in a memo, and every degraded state from
## Page-Descriptions.md §14 is a value of an enum on some ViewModel — not an
## `if` in a view."
##
## ## This is the other half of a split that already exists
##
## M2b put the six §14 rows that reach a *debugger pane* in the CodeTracer
## Embed SDK (`viewmodel/store/degraded_state.nim`), and named the other seven
## in its header table rather than merely omitting them, because "we forgot"
## and "that belongs one layer up" look identical in a file that only lists
## what it owns. This module is those seven. 7 + 6 = 13, with no row dropped
## and none counted twice:
##
## | §14 row                             | Modelled in                                     |
## | ----------------------------------- | ----------------------------------------------- |
## | **Pipeline behind the chain tip**   | **here** — `cdPipelineBehindTip`, `ChainVM`      |
## | **Object not found**                | **here** — `cdObjectNotFound`, `SearchVM`        |
## | **Trace awaiting generation**       | **here** — `cdTraceAwaitingGeneration`, `GenerationJobVM` |
## | Replay window expired               | Embed SDK — `raWindowExpired`; established by `ArtifactVM` |
## | Permanently unreplayable            | Embed SDK — `raUnreplayable`; established by `ArtifactVM`  |
## | Browser cannot run the debugger     | Embed SDK — `ReplayCapability`; established by `CapabilityVM` |
## | **Recorder unavailable for the VM** | **here** — `cdRecorderUnavailable`, `TraceStatusVM` |
## | **Transaction below the history floor** | **here** — `cdBelowHistoryFloor`, `ChainRegistryVM` |
## | Trace truncated                     | Embed SDK — `tiTruncated`; established by `ArtifactVM` |
## | Divergence detected                 | Embed SDK — `tiDivergent`; established by `DivergenceVM` |
## | No verified source                  | Embed SDK — `savUnverified`; established by `SourceBundleVM` |
## | **Reorganised away**                | **here** — `cdReorganisedAway`, `ChainVM`        |
## | **CDN unreachable**                 | **here** — `cdCdnUnreachable`, `ChainVM`         |
##
## **"Modelled in" is not "owned by", and reading it as ownership is the trap
## M2b's review named.** Six of the Embed SDK's rows are values a *pane*
## renders a treatment for; the ViewModels in the right-hand column above
## *establish* those values from inputs that are chain- or delivery-shaped — a
## manifest verdict, a retention class, a provider chain, a capability probe
## against a container of a known size. Neither layer is redundant. The seam
## between them is `ReplayDataStore`'s four setters plus the `CtReplayStatus`
## backend event: **the layer above writes, the panes read**, and
## `viewmodel/replay_status.nim` is this package's side of that write.
##
## ## Why one enum and a sensitivity set, rather than one enum per page
##
## Exactly M2b's reason, and it is §14's own opening sentence: "so each has one
## canonical treatment rather than being reinvented per page". Five per-page
## enums would be five places to re-decide what "behind the tip" means, and the
## precedence between two simultaneous conditions would be re-derived in each
## one — which is the "branch in a view" failure mode moved up a layer.
##
## Instead: one `ChainDegradation`, one fixed precedence
## (`resolveChainDegradation`), and each surface declares as data the subset of
## rows it renders.
##
## ## Why `cdCdnUnreachable` is here and not "the service worker's"
##
## §14's canonical treatment for that row is a service-worker behaviour ("serves
## the shell and anything previously viewed"), and M2b's table pointed at the
## service worker rather than at a ViewModel. But the *condition* still has to
## be established and rendered, and a page that cannot tell "this object is not
## published" from "this object could not be fetched" will report the second as
## the first — which is the worst available answer, because it presents a
## transport failure as evidence of absence. So the condition is a value here,
## established by `ChainVM` from the outcome of the one poll every page already
## makes, and it outranks `cdObjectNotFound` in the precedence below for exactly
## that reason. Front-End-Architecture §3's table names no `DeliveryVM` and this
## module does not invent one.
##
## This module imports nothing. It is pure data and two total functions over
## it, so it compiles on both the C and the JS target — which matters here
## because BlockTracer ships the JS backend.

type
  PipelineFreshness* = enum
    ## §14's "Pipeline behind the chain tip" row: "Staleness notice from the
    ## chain summary, naming how far behind; published pages unaffected."
    ##
    ## Established by `ChainVM` from the pinned session's head (which
    ## `current.json` carries — Static-Site-Architecture.md §3.3) against the
    ## highest block the sealed generation actually indexed, plus
    ## `summary.json`'s own `stale` flag. §5 of that document is explicit that
    ## a consumer "surfaces staleness from `summary.json` rather than inferring
    ## it", so the published flag wins and the height delta is what names *how
    ## far*.
    pfCurrent
      ## The generation has indexed everything the pointer claims.
    pfBehindTip
      ## The pipeline is behind. Published pages are unaffected; only newer
      ## blocks are missing.

  ObjectPresence* = enum
    ## §14's "Object not found" row: "'Not on this chain' with the chains
    ## checked, not a blank page."
    ##
    ## The plural matters and is why this is not a bool: the answer a user
    ## needs is which chains were searched, so `SearchVM` carries the list
    ## alongside this value.
    opPresent
    opNotOnThisChain
      ## Every chain the registry publishes was resolved and none carried it.
    opMalformed
      ## The object was found and did not parse. Distinct from
      ## `opNotOnThisChain` because the entity exists and the tree is wrong —
      ## telling a user their transaction is "not on this chain" when the
      ## producer wrote bad bytes is a false statement about the chain.

  Canonicality* = enum
    ## §14's "Reorganised away" row: "Page switches to a reorg explanation,
    ## with the new location if the transaction was re-included."
    ##
    ## Three values, not two, because "gone" and "moved" need different pages
    ## and collapsing them produces a dead end where a link exists.
    ccCanonical
    ccReorganisedAway
      ## The generation's transaction state says this transaction is not
      ## canonical, and no re-inclusion is known.
    ccReIncluded
      ## Not canonical at the position the page was built for, but canonical
      ## somewhere else. The page states the new location.

  TraceProvenance* = enum
    ## Three of §14's rows, as one axis, because they are mutually exclusive
    ## answers to one question — *why can this transaction not be debugged
    ## right now?* — and modelling them as three independent flags would admit
    ## states ("awaiting generation AND below the history floor") that cannot
    ## occur and would then need a precedence of their own.
    tpAvailable
      ## Either a trace is resolvable, or the reason it is not is one the
      ## *Embed SDK's* axes carry (absent, unsupported-by-structure, expired).
    tpAwaitingGeneration
      ## §14: "A job with observable phases — §14.1." The address is derivable
      ## and the object is not published yet. `GenerationJobVM` carries the
      ## phase.
    tpRecorderUnavailable
      ## §14: "Debug absent with the recorder's status and a link to its spec."
      ## No recorder is pinned for this chain in the registry, so no trace
      ## address can be derived at all (Trace-Artifacts.md §2.1) — or the
      ## overlay said `unsupported` in the producer's own words.
    tpBelowHistoryFloor
      ## §14: "Debug absent, stating the floor and that prestate does not
      ## exist below it." A structural refusal, not a failure — §14.1's
      ## `refused` row names this case by name.

  DeliveryReachability* = enum
    ## §14's "CDN unreachable" row. See this module's header for why the
    ## condition is modelled here even though the *treatment* is the service
    ## worker's.
    drReachable
    drCdnUnreachable
      ## A read failed at the transport rather than returning a 404. Nothing
      ## on this page can be trusted to be absent.

  ChainDegradation* = enum
    ## The single value a page hands its view, so the view renders a treatment
    ## rather than deciding on one.
    ##
    ## Seven of the eight values are §14 rows; `cdNone` is the ordinary case.
    ## Every §14 row this package models is here, and nothing that does not
    ## reach a page is (see the table in this module's header).
    cdNone
    cdCdnUnreachable          ## §14 — the service worker serves what it has
    cdObjectNotFound          ## §14 — "not on this chain", with the chains checked
    cdReorganisedAway         ## §14 — a reorg explanation, with the new location
    cdBelowHistoryFloor       ## §14 — debug absent, stating the floor
    cdRecorderUnavailable     ## §14 — debug absent, with the recorder's status
    cdTraceAwaitingGeneration ## §14 / §14.1 — a job with observable phases
    cdPipelineBehindTip       ## §14 — a staleness notice; published pages unaffected

  ChainStateSnapshot* = object
    ## The five independent axes, read together. A snapshot rather than five
    ## arguments so `resolveChainDegradation` cannot be called with four of
    ## them by accident, and so a page memo makes one read of each signal per
    ## evaluation.
    freshness*: PipelineFreshness
    presence*: ObjectPresence
    canonicality*: Canonicality
    provenance*: TraceProvenance
    reachability*: DeliveryReachability

const
  # The order `resolveChainDegradation` tests conditions in, most severe first.
  # Stated as data so a test can assert the ordering directly instead of
  # inferring it from the function's control flow — M2b's precedent, and the
  # reason its precedence is checkable at all.
  #
  # The ordering rule, stated once so each position can be justified against it
  # rather than by taste: A STATE THAT MAKES THE PAGE'S OTHER CLAIMS
  # UNTRUSTWORTHY OUTRANKS ONE THAT MAKES THE PAGE INCOMPLETE, WHICH OUTRANKS
  # ONE THAT MAKES ONLY THE DEBUGGER UNAVAILABLE, WHICH OUTRANKS ONE THAT
  # AFFECTS NOTHING ALREADY PUBLISHED.
  #
  #   cdCdnUnreachable          Nothing was read, so nothing is known. A 404
  #                             caused by an unreachable origin is not evidence
  #                             of absence, and reporting it as
  #                             `cdObjectNotFound` would be the page asserting
  #                             something false about the chain. That is why it
  #                             outranks a missing object rather than being a
  #                             peer of it.
  #   cdObjectNotFound          There is no entity here at all. Everything
  #                             below assumes one.
  #   cdReorganisedAway         The entity exists but is no longer part of the
  #                             canonical chain, which changes what every fact
  #                             on the page means. Outranks the three
  #                             debuggability rows because "this transaction is
  #                             not in the chain" has to be said before "and
  #                             its trace is still generating".
  #   cdBelowHistoryFloor       Terminal: prestate does not exist below the
  #                             floor, so no generation can ever succeed. §14's
  #                             "never a retry that cannot succeed" is why the
  #                             two terminal rows sort above the one that can.
  #   cdRecorderUnavailable     Terminal for this VM as the tree stands. Ranked
  #                             below the history floor because a recorder can
  #                             arrive while a floor cannot move down.
  #   cdTraceAwaitingGeneration "Not now" rather than "not ever" — the weakest
  #                             of the three debuggability rows, and the only
  #                             one with an action.
  #   cdPipelineBehindTip       §14: "published pages unaffected". The page in
  #                             front of the user is complete and correct; only
  #                             newer entities are missing. Anything else here
  #                             is a stronger statement about *this* page.
  ChainDegradationPrecedence*: array[7, ChainDegradation] = [
    cdCdnUnreachable,
    cdObjectNotFound,
    cdReorganisedAway,
    cdBelowHistoryFloor,
    cdRecorderUnavailable,
    cdTraceAwaitingGeneration,
    cdPipelineBehindTip,
  ]

  # ---------------------------------------------------------------------------
  # Per-surface sensitivity sets.
  #
  # A surface that is not sensitive to a condition resolves to `cdNone` for it
  # rather than to a weaker value, which is the point of the set: a chain
  # overview page is not "degraded" because one transaction's recorder is
  # missing, and saying it is would train users to ignore the notice that
  # matters.
  # ---------------------------------------------------------------------------

  # §4 of Page-Descriptions: the head ticks from `current.json` and the
  # staleness notice comes from `summary.json`. This is the surface §14
  # names for the staleness row, and the only one that renders a chain slug
  # the registry may not publish.
  ChainOverviewDegradations*: set[ChainDegradation] = {
    cdCdnUnreachable,
    cdObjectNotFound,
    cdPipelineBehindTip,
  }

  # §5. A block list walks backwards from head, so it shows how far behind
  # the pipeline is; a block detail can be reorganised away. Neither renders
  # a trace, so none of the three debuggability rows belong here.
  BlockDegradations*: set[ChainDegradation] = {
    cdCdnUnreachable,
    cdObjectNotFound,
    cdReorganisedAway,
    cdPipelineBehindTip,
  }

  # §6. The surface that owns the Debug affordance, and therefore the only
  # explorer surface that renders all three debuggability rows.
  #
  # `cdPipelineBehindTip` is deliberately absent: §14 says published pages
  # are unaffected, and a transaction page is a published page. A staleness
  # notice on it would be noise about something else.
  TransactionDegradations*: set[ChainDegradation] = {
    cdCdnUnreachable,
    cdObjectNotFound,
    cdReorganisedAway,
    cdBelowHistoryFloor,
    cdRecorderUnavailable,
    cdTraceAwaitingGeneration,
  }

  # §7. Paged history is generation-scoped, so a behind-the-tip pipeline
  # genuinely truncates what this page shows — unlike a transaction page —
  # and a listed transaction can have been reorganised away.
  AddressDegradations*: set[ChainDegradation] = {
    cdCdnUnreachable,
    cdObjectNotFound,
    cdReorganisedAway,
    cdPipelineBehindTip,
  }

  # §3 / §14's "not on this chain, with the chains checked". The surface
  # whose entire failure mode is this one row, and the one place where
  # confusing an unreachable origin with an absent object would be most
  # damaging.
  SearchDegradations*: set[ChainDegradation] = {
    cdCdnUnreachable,
    cdObjectNotFound,
  }

  # The debug route (Debugger-Integration.md §2). Everything that can stop a
  # debugger from opening, plus the two that mean the page's subject is not
  # what the link claimed.
  #
  # The rows *inside* an open debugger — truncation, divergence, the
  # capability ladder, an expired window — are not here: they are the Embed
  # SDK's `PaneDegradation`, written through `replay_status.nim`. This set
  # is what prevents the route from opening at all.
  DebugRouteDegradations*: set[ChainDegradation] = {
    cdCdnUnreachable,
    cdObjectNotFound,
    cdReorganisedAway,
    cdBelowHistoryFloor,
    cdRecorderUnavailable,
    cdTraceAwaitingGeneration,
  }

  # Every surface's sensitivity set, so a test can assert that the union
  # covers every §14 row this package models — the check that catches an
  # eighth row being added to `ChainDegradation` and then rendered by
  # nobody. M2b's `AllPaneDegradations` is the same guard one layer down,
  # and it is the one that made a silently-unrendered row impossible there.
  AllSurfaceDegradations*: array[6, set[ChainDegradation]] = [
    ChainOverviewDegradations,
    BlockDegradations,
    TransactionDegradations,
    AddressDegradations,
    SearchDegradations,
    DebugRouteDegradations,
  ]

const
  # The three debuggability rows are one axis, so two ViewModels can both have
  # an opinion about it — `TraceStatusVM` from what the published tree said,
  # `GenerationJobVM` from what the pipeline decided about a request. Ranking
  # them needs an order, and the order must be the SAME one
  # `ChainDegradationPrecedence` uses, or a page could resolve to a row that is
  # not the most severe one holding.
  #
  # Stated once, here, next to the precedence it must agree with, and asserted
  # against it in the suite rather than eyeballed.
  TraceProvenancePrecedence*: array[3, TraceProvenance] = [
    tpBelowHistoryFloor,
    tpRecorderUnavailable,
    tpAwaitingGeneration,
  ]

func strongerProvenance*(a, b: TraceProvenance): TraceProvenance =
  ## The more severe of two opinions about why a transaction cannot be
  ## debugged. `tpAvailable` is the absence of an opinion, so it loses to
  ## everything.
  ##
  ## The failure this prevents is concrete: a transaction below the history
  ## floor whose overlay is `onDemand` has a job VM saying "awaiting
  ## generation" and a trace-status VM saying "below the floor". Taking the
  ## first would put a Generate button on a transaction no recorder can ever
  ## record — §14's retry that cannot succeed, arriving through a merge rather
  ## than through a branch.
  for candidate in TraceProvenancePrecedence:
    if a == candidate or b == candidate: return candidate
  tpAvailable

func initChainStateSnapshot*(): ChainStateSnapshot =
  ## The undegraded snapshot — a present, canonical object on a current
  ## pipeline behind a reachable origin, whose trace is resolvable. Named
  ## rather than relying on Nim's zero-initialisation so that reordering an
  ## enum cannot silently change the default.
  ChainStateSnapshot(
    freshness: pfCurrent,
    presence: opPresent,
    canonicality: ccCanonical,
    provenance: tpAvailable,
    reachability: drReachable,
  )

func chainDegradationPresent*(snapshot: ChainStateSnapshot;
                              degradation: ChainDegradation): bool =
  ## Whether `degradation` holds in `snapshot`, ignoring precedence and
  ## ignoring which surface is asking. Exposed because a page sometimes needs
  ## "is the pipeline also behind?" alongside the single value it resolved to —
  ## a reorg explanation on a stale chain is still on a stale chain.
  case degradation
  of cdNone:
    snapshot.freshness == pfCurrent and
      snapshot.presence == opPresent and
      snapshot.canonicality == ccCanonical and
      snapshot.provenance == tpAvailable and
      snapshot.reachability == drReachable
  of cdCdnUnreachable:
    snapshot.reachability == drCdnUnreachable
  of cdObjectNotFound:
    # Both non-present values. They are one *page* row because the treatment is
    # identical — "we looked, and this is not something we can show you" — while
    # the wording differs and the page reads `ObjectPresence`, which still
    # carries both.
    snapshot.presence != opPresent
  of cdReorganisedAway:
    # `ccReIncluded` is a degradation too: the page the user opened is not
    # about the position they linked to, and saying nothing would be a silent
    # landing elsewhere. The *action* differs (a link to the new location) and
    # the page reads `Canonicality` for it.
    snapshot.canonicality != ccCanonical
  of cdBelowHistoryFloor:
    snapshot.provenance == tpBelowHistoryFloor
  of cdRecorderUnavailable:
    snapshot.provenance == tpRecorderUnavailable
  of cdTraceAwaitingGeneration:
    snapshot.provenance == tpAwaitingGeneration
  of cdPipelineBehindTip:
    snapshot.freshness == pfBehindTip

func resolveChainDegradation*(snapshot: ChainStateSnapshot;
                              sensitivity: set[ChainDegradation]): ChainDegradation =
  ## The one decision site. Walks `ChainDegradationPrecedence` and returns the
  ## first degradation that both holds in `snapshot` and is one this surface
  ## renders; `cdNone` when none does.
  for candidate in ChainDegradationPrecedence:
    if candidate in sensitivity and snapshot.chainDegradationPresent(candidate):
      return candidate
  cdNone
