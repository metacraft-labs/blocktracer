## The §14 degraded-state treatments, rendered from a resolved enum value.
##
## Page-Descriptions §14 ends with the rule this component exists to satisfy on
## the SSR side:
##
##   "Every row above is a **value of an enum on a ViewModel**, not a branch in
##   a view, which is what makes each of them testable without a browser."
##
## `viewmodel/chain_degradation.nim` already models the seven chain-shaped rows,
## their precedence, and each surface's sensitivity set — as data. What was
## missing was a renderer, so every explorer page that wanted to say "this is
## not here and this is why" was inventing its own sentence in its own markup.
## That is the branch-in-a-view failure one layer over: five pages, five
## spellings of "not on this chain", and no way to check that any of them said
## what §14 requires.
##
## So there is exactly one `case` over `ChainDegradation` in the explorer, and
## it is below. Two consequences follow, and both are the point:
##
##   * **A row added to the enum is a compile error here**, not an unstyled
##     nothing. `notice` is total over the enum with no `else`.
##   * **A page cannot resolve a degradation it does not render.** Pages call
##     `resolveChainDegradation(snapshot, <that surface's set>)`, so a chain
##     overview cannot come to show a transaction-shaped notice, and the
##     sensitivity sets stay the single statement of which surface says what.
##
## ## Why `cdNone` renders nothing rather than being unrepresentable
##
## Because every caller has the undegraded case, and making it unrepresentable
## would push an `if` back into every page — the exact thing this module
## removes. `notice` returns `""` for it, and the pages `raw` that, which is
## nothing.
##
## ## What this module does NOT own
##
## The six §14 rows that reach a *debugger pane* — truncation, divergence, the
## capability ladder, an expired window — belong to the Embed SDK's
## `PaneDegradation` and are written through `viewmodel/replay_status.nim`.
## This is the explorer register's half, and the split is the one
## `chain_degradation.nim`'s header table records.

import std/strutils
import isonim/ssr/escape
import isonim/dsl/ui
import ../viewmodel/chain_degradation

export ChainDegradation, ChainStateSnapshot, initChainStateSnapshot,
       resolveChainDegradation, chainDegradationPresent,
       PipelineFreshness, ObjectPresence, Canonicality, TraceProvenance,
       DeliveryReachability,
       ChainOverviewDegradations, BlockDegradations, TransactionDegradations,
       AddressDegradations, SearchDegradations, DebugRouteDegradations

type
  DegradationNotice* = object
    ## Everything a treatment needs that the enum value itself does not carry.
    ##
    ## The fields are what §14's own sentences ask for — "with the chains
    ## checked", "naming how far behind", "with the new location if the
    ## transaction was re-included", "with the recorder's status" — so a
    ## treatment that omits one is visible as an empty field rather than as a
    ## shorter sentence nobody notices.
    subject*: string
      ## What the page is about: an address, a hash, a chain slug. Rendered
      ## verbatim, so it is the visitor's own input where there was one.
    chainsChecked*: seq[string]
      ## §14's "not on this chain" row: the chains that were actually resolved.
      ## Not the registry's list — a chain whose pointer could not be read was
      ## not checked, and listing it would claim a search that did not happen
      ## (`viewmodel/search_vm.nim` makes the same distinction upstream).
    detail*: string
      ## The producer's own words, where the tree published any. Never
      ## paraphrased into the sentence around it.
    behindBy*: int
      ## How many blocks the pipeline is behind the pointer's tip.
    actionHref*, actionLabel*: string
      ## Offered only where §14 licenses an action. A terminal row that carried
      ## one would be "a retry that cannot succeed".

func noticeTitle*(d: ChainDegradation): string =
  ## The heading each row is announced under. Total over the enum.
  case d
  of cdNone: ""
  of cdCdnUnreachable: "This page could not reach the data"
  of cdObjectNotFound: "Not on this chain"
  of cdReorganisedAway: "Reorganised out of the canonical chain"
  of cdBelowHistoryFloor: "Below this chain's history floor"
  of cdRecorderUnavailable: "No recorder for this VM"
  of cdTraceAwaitingGeneration: "The trace is being generated"
  of cdPipelineBehindTip: "The pipeline is behind the chain tip"

func noticeTone*(d: ChainDegradation): string =
  ## The status vocabulary each row is painted in, so colour never carries the
  ## meaning alone and never contradicts the words beside it.
  case d
  of cdNone: ""
  of cdCdnUnreachable, cdObjectNotFound: "bad"
  of cdReorganisedAway: "bad"
  of cdBelowHistoryFloor, cdRecorderUnavailable: "muted"
  of cdTraceAwaitingGeneration: "info"
  of cdPipelineBehindTip: "warn"

proc noticeBody(d: ChainDegradation, n: DegradationNotice): string =
  ## The sentence. One per row, each a restatement of §14's canonical treatment
  ## and of nothing else.
  case d
  of cdNone: ""
  of cdCdnUnreachable:
    "A read failed at the transport rather than returning a 404, so nothing " &
    "on this page can be trusted to be absent. What is shown was served from " &
    "what had already been fetched."
  of cdObjectNotFound:
    "Nothing at this address exists in the published tree. " &
    (if n.chainsChecked.len > 0:
       "Chains checked: " & n.chainsChecked.join(" · ") & "."
     else:
       "No chain was reached, so this is not evidence of absence.")
  of cdReorganisedAway:
    "This entity is no longer part of the canonical chain at the generation " &
    "this page pinned. Its data is unchanged and still correct; what changed " &
    "is which chain references it."
  of cdBelowHistoryFloor:
    "Prestate does not exist below this chain's history floor, so no trace " &
    "can ever be produced for it. This is terminal, not a wait."
  of cdRecorderUnavailable:
    "No recorder is pinned for this chain's VM, so no trace address can be " &
    "derived at all. Debugging arrives here when the recorder does."
  of cdTraceAwaitingGeneration:
    "A trace for this transaction is derivable and has not been published " &
    "yet. Generation is a job with named phases, not a spinner."
  of cdPipelineBehindTip:
    "Everything already published is complete and correct; only newer blocks " &
    "are missing. " &
    (if n.behindBy > 0:
       "This generation is " & $n.behindBy & " block(s) behind the tip the " &
       "chain pointer reports."
     else:
       "The chain summary reports this generation as behind the tip.")

proc notice*(d: ChainDegradation, n: DegradationNotice): string =
  ## One §14 row, as the explorer register renders it. `""` for `cdNone`.
  if d == cdNone: return ""
  let title = noticeTitle(d)
  let body = noticeBody(d, n)
  ui:
    tdiv(class = "notice " & noticeTone(d), `data-degradation` = $d):
      tdiv(class = "noticehead"):
        span(class = "badge " & noticeTone(d)): text title
        if n.subject.len > 0:
          span(class = "identifier"): text n.subject
      p(class = "measure"): text body
      if n.detail.len > 0:
        # The producer's own words, quoted rather than folded into the
        # sentence above: a reason the pipeline wrote is evidence, and
        # rewriting it in the view would make it prose.
        p(class = "reason measure"): text n.detail
      if n.actionHref.len > 0 and n.actionLabel.len > 0:
        p(class = "stack"):
          a(class = "btn ghost", href = n.actionHref): text n.actionLabel
