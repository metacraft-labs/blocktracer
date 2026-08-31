## The provenance banner — which data a visitor is actually looking at.
##
## WHY THIS EXISTS, AND WHY IT IS ON EVERY PAGE RATHER THAN ON ONE. This tree
## publishes three chains from two producers: a synthetic demo generated from a
## fixed seed, and real captures taken from Aztec testnet and mainnet nodes.
## The count is deliberately not load-bearing anywhere below — the banner reads
## whatever the generation published and says so, so a fourth chain needs no
## edit here. They render
## through the same views, the same reader and the same debugger, because a
## second chain is DATA rather than a second explorer — which is the right design
## and which also means nothing about a page's shape tells a reader which one
## they have. A synthetic hash looks exactly like a real one. The debugger opens
## on both, with panes in the same places.
##
## So the marker goes on the page the reader is on. A badge that appeared only on
## a marketing page, or only on `/chains`, would be absent from every page where
## someone could actually be misled.
##
## AND IT IS READ FROM THE TREE, NOT FROM THE SLUG. `summary.json` carries a
## `provenance` block and both producers write one. Keying the banner off the
## chain's name would be a guess that survives exactly until someone renames a
## chain, at which point the page would confidently mislabel its own data —
## which is the failure mode this product treats as the one it cannot ship.
##
## The tone vocabulary and the markup are `components/degraded.notice`'s, reused
## deliberately: this is the same kind of object — a standing statement about the
## data below it, quoting the producer's own words rather than paraphrasing them.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader

func isLiveCapture*(kind: string): bool =
  ## The one kind that names data taken off a network.
  ##
  ## A predicate rather than a bare comparison at each call site, because the
  ## string is a wire value published by the producer and two places that spell
  ## it independently can come to disagree about it. `provenanceTone` below and
  ## the home strip's ordering both ask this question, and they must get the
  ## same answer for the same tree.
  kind == "live-capture"

func provenanceTone*(kind: string): string =
  ## `live-capture` is the only kind that earns the affirmative tone. Anything
  ## else — including a kind this build has never heard of — is reported
  ## neutrally rather than being presented as real chain data, because the
  ## dangerous error here has a direction: calling synthetic data real is worse
  ## than declining to vouch for real data.
  if isLiveCapture(kind): "ok" else: "info"

proc provenanceBanner*(info: ChainInfo): string =
  ## The banner for one chain, or `""` when the generation published none.
  ##
  ## An empty string is the honest answer to "this tree does not say", and is
  ## deliberately not a default of "synthetic": a consumer that assumed one would
  ## be inventing a claim on behalf of a producer that made none. Site-level
  ## pages pass no banner for the same reason — they show no chain's data.
  if info.provenanceKind.len == 0 or info.provenanceLabel.len == 0:
    return ""
  let tone = provenanceTone(info.provenanceKind)
  ui:
    tdiv(class = "notice " & tone, `data-provenance` = info.provenanceKind):
      tdiv(class = "noticehead"):
        span(class = "badge " & tone): text info.provenanceLabel
        span(class = "identifier"): text info.slug
      if info.provenanceDetail.len > 0:
        # The producer's own words, quoted rather than folded into a sentence
        # this module wrote — the rule `degraded.notice` already states for the
        # §14 treatments, and it applies at least as strongly here: the capture
        # knows the endpoint, the moment and the block range, and a view that
        # paraphrased them would be able to go stale against the data.
        p(class = "reason measure"): text info.provenanceDetail
