## Provenance — which data a visitor is actually looking at.
##
## WHY THE MARKER EXISTS AT ALL. This tree publishes three chains from two
## producers: a synthetic demo generated from a fixed seed, and real captures
## taken from Aztec testnet and mainnet nodes. The count is deliberately not
## load-bearing anywhere below — every proc here reads whatever the generation
## published, so a fourth chain needs no edit. They render through the same
## views, the same reader and the same debugger, because a second chain is DATA
## rather than a second explorer — which is the right design and which also
## means nothing about a page's SHAPE tells a reader which one they have. A
## synthetic hash looks exactly like a real one. The debugger opens on both,
## with panes in the same places.
##
## So the marker goes on the page the reader is on. A badge that appeared only
## on a marketing page, or only on `/chains`, would be absent from every page
## where someone could actually be misled.
##
## AND IT IS READ FROM THE TREE, NOT FROM THE SLUG. `summary.json` carries a
## `provenance` block and both producers write one. Keying it off the chain's
## name would be a guess that survives exactly until someone renames a chain, at
## which point the page would confidently mislabel its own data — which is the
## failure mode this product treats as the one it cannot ship.
##
## ## A BAND IS AN INTERRUPTION, SO IT IS RESERVED FOR AN ABNORMAL STATE
## ## (revised 2026-08-31)
##
## Until now every one of these was a full-width `.notice` band on all 813
## chain-scoped pages, in both registers. That was wrong in the ordinary case
## and the review round measured the cost: in the debugger register the band
## spends about 190px of a 1080px viewport — roughly 17% — to set a ~600px
## measure, and both adversarial reviewers of that round, on both themes,
## independently named it the single weakest element of the page. The rows it
## takes come out of the panes, which are the register's scarcest resource.
##
## The rule now: **a band means something is not normal here.** Everything else
## is metadata, and metadata goes where the page already keeps metadata.
##
##   * `live-capture` — ORDINARY. Real chain data is what this product is for,
##     and interrupting a page to announce that it is working as intended is
##     the interruption with the worst ratio of rows to information. It becomes
##     a FIELD: a row in the transaction info panel where the page has one, and
##     a compact chip beside the breadcrumb where it does not.
##   * everything else, including `synthetic` and any kind this build has never
##     heard of — ABNORMAL, and it keeps the band. "The hashes in front of you
##     exist on no network" is exactly the class of fact a band is for: a reader
##     who misses it can draw a conclusion that is entirely false, which is not
##     true of missing "this data is real". The asymmetry is deliberate and is
##     the same one `provenanceTone` already encodes — calling synthetic data
##     real is worse than declining to vouch for real data — so the louder
##     treatment goes to the direction that costs more when it is missed.
##
## The marker is NOT removed from any page. Every page that carried a band still
## carries a marker; what changed is that the ordinary case stopped interrupting
## to deliver it. That distinction is what keeps the `site-chrome` and
## `debugger-shell` expectations satisfiable rather than deleted: a reader must
## still be able to tell real from synthetic on the page they are on, and it is
## still graded as content.
##
## The tone vocabulary and the band markup are `components/degraded.notice`'s,
## reused deliberately: a band here is now the same kind of object it is there —
## a statement that something about the data below is not the ordinary case,
## quoting the producer's own words rather than paraphrasing them.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../debugger/session_view

func isLiveCapture*(kind: string): bool =
  ## The one kind that names data taken off a network.
  ##
  ## A predicate rather than a bare comparison at each call site, because the
  ## string is a wire value published by the producer and two places that spell
  ## it independently can come to disagree about it. `provenanceTone` below and
  ## the home strip's ordering both ask this question, and they must get the
  ## same answer for the same tree.
  kind == "live-capture"

func captureFirst*[T](items: seq[T];
                      kindOf: proc(item: T): string {.noSideEffect.}): seq[T] =
  ## Captured chains first, then everything else, stable within each group.
  ##
  ## THE ORDER IS ONE RULE WITH TWO CALL SITES, not two orderings that happen to
  ## agree. `pages/home.stripOrder` states why the rule exists: until it was
  ## written the strip's order was `chains()`'s registry order — lexicographic —
  ## so the synthetic demo chain led because `aztec` sorts before
  ## `aztec-mainnet`, and the first thing a first-time visitor was offered was
  ## three blocks of data that exists on no network. Nothing decided that; the
  ## alphabet did.
  ##
  ## `/chains` listed the same three chains and was NOT changed with it, so the
  ## two surfaces that enumerate this product's chains disagreed about which one
  ## comes first — the home page demoting the synthetic chain and the capability
  ## inventory still promoting it. A visitor who followed "Supported chains"
  ## from the home page got the opposite ranking one click later.
  ##
  ## Keyed off the published provenance rather than the slug, for the reason
  ## `provenanceBanner` refuses to key off the slug: a name is not a claim about
  ## where data came from, and an ordering that reads one would silently re-rank
  ## the moment a chain is renamed.
  for it in items:
    if isLiveCapture(kindOf(it)): result.add it
  for it in items:
    if not isLiveCapture(kindOf(it)): result.add it

func provenanceTone*(kind: string): string =
  ## `live-capture` is the only kind that earns the affirmative tone. Anything
  ## else — including a kind this build has never heard of — is reported
  ## neutrally rather than being presented as real chain data, because the
  ## dangerous error here has a direction: calling synthetic data real is worse
  ## than declining to vouch for real data.
  if isLiveCapture(kind): "ok" else: "info"

func hasProvenance*(info: ChainInfo): bool =
  ## Whether the generation published a claim at all.
  ##
  ## BOTH halves are required, and that is the guard the whole module rests on:
  ## a kind with no label cannot be rendered as a badge, and a label with no kind
  ## cannot be toned. Either alone would make a page state something a producer
  ## never said. Every producer below returns nothing when this is false, and
  ## `""` is the honest answer to "this tree does not say" — deliberately not a
  ## default of "synthetic", because a consumer that assumed one would be
  ## inventing a claim on behalf of a producer that made none. Site-level pages
  ## pass no chain here for the same reason: they show no chain's data.
  info.provenanceKind.len > 0 and info.provenanceLabel.len > 0

func isAbnormal*(info: ChainInfo): bool =
  ## Whether this provenance earns a BAND rather than a field.
  ##
  ## Abnormal is "anything that is not real chain data", which is the same
  ## direction `provenanceTone` leans and for the same reason: a kind this build
  ## has never heard of is treated as abnormal, so a new producer's data is
  ## interrupted-for rather than quietly presented as real. The failure that
  ## costs more is the one that gets the louder treatment.
  hasProvenance(info) and not isLiveCapture(info.provenanceKind)

proc provenanceBanner*(info: ChainInfo): string =
  ## The band, for an ABNORMAL provenance only. `""` for real chain data and for
  ## a tree that published nothing — see the module header for why the ordinary
  ## case stopped interrupting the page to announce itself.
  if not isAbnormal(info): return ""
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

proc provenanceChip*(info: ChainInfo): string =
  ## The FIELD form, for a page whose provenance is ordinary and which has no
  ## metadata surface of its own to carry a row — a block list, a block, an
  ## address, a contract's code, a chain overview.
  ##
  ## Rendered beside the breadcrumb rather than above the content, because that
  ## is where the page already says which chain a reader is on: the chip
  ## qualifies the slug that is right next to it instead of opening a band to
  ## repeat it. It carries the same badge, the same tone and the same label the
  ## band carried, so nothing a reviewer graded as content has been downgraded
  ## to decoration — only the interruption is gone.
  ##
  ## `data-provenance` is on the chip for the reason it was on the band: it is
  ## how the corpus checks and the provenance tests find the marker without
  ## depending on its wording. Every marker this module emits carries it, so a
  ## page with a provenance has exactly one and a page without has none.
  ##
  ## The producer's DETAIL is deliberately not here. It is three sentences about
  ## an endpoint, a moment and a block range, and a chip is not where three
  ## sentences go; the transaction pages that can hold it render it in their
  ## metadata surface via `provenanceRow`, and the chain overview — the page
  ## whose subject IS the capture — keeps the full account in its own facts.
  if not hasProvenance(info) or isAbnormal(info): return ""
  ui:
    span(class = "provchip", `data-provenance` = info.provenanceKind):
      span(class = "badge " & provenanceTone(info.provenanceKind)):
        text info.provenanceLabel

func provenanceRow*(info: ChainInfo): seq[MetaRow] =
  ## The FIELD form for a page that HAS a metadata surface: one `MetaRow`, which
  ## `viewutil.txMetadataRows` appends so the explorer's overview grid and the
  ## debugger's transaction pane both get it from the one source §7.1 requires.
  ##
  ## A seq of nought-or-one rather than a `MetaRow` and a separate emptiness
  ## test, so the caller cannot forget the guard: a tree that published no
  ## provenance contributes no row, and there is no shape in which this returns
  ## a row with an empty label for a caller to render as a blank fact.
  ##
  ## It is emitted for EVERY kind, including the abnormal ones that also get a
  ## band. That is not duplication in the sense the band rule objects to: the
  ## band interrupts the page and the row is one line among the transaction's
  ## other facts, and a reader checking "is this real?" while reading the fee
  ## and the block should not have to scroll back up to the band to find out.
  ##
  ## `note` carries the producer's own sentences, quoted rather than folded into
  ## prose this module wrote — the rule `degraded.notice` states for the §14
  ## treatments, and it applies at least as strongly here: the capture knows the
  ## endpoint, the moment and the block range, and a view that paraphrased them
  ## could go stale against the data.
  if not hasProvenance(info): return @[]
  @[MetaRow(label: "Data", value: info.provenanceLabel,
            badge: provenanceTone(info.provenanceKind),
            dataProvenance: info.provenanceKind,
            note: info.provenanceDetail)]

proc provenanceMarker*(info: ChainInfo): string =
  ## What a page in the EXPLORER register puts in its provenance slot: the band
  ## when the provenance is abnormal, the chip when it is ordinary, nothing when
  ## the tree published none. Exactly one of the two is ever non-empty.
  ##
  ## One proc rather than two calls at nine call sites, for the reason
  ## `costAmount` exists: a caller that wrote `banner(info) & chip(info)` would
  ## be spelling the either/or a ninth time, and the ninth spelling is where the
  ## two come to disagree.
  ##
  ## THE DEBUGGER REGISTER DOES NOT CALL THIS, and that is the whole of why the
  ## band left that shell. `debugLayout` drops the nav and the footer, so the
  ## band was the only provenance marker there was — but it is also the register
  ## where a full-width strip is most expensive, spending ~190px of a 1080px
  ## viewport out of the panes. What that register has instead is a metadata
  ## pane that §7.1 puts on the page in EVERY state, including the states where
  ## no session can open, so `provenanceRow` reaches every debug page
  ## unconditionally and reaches it beside the transaction's other facts —
  ## which is where a reader asking "is any of this real?" is already looking.
  ## The explorer's list and detail pages have no such surface, which is why
  ## they still need a marker of their own.
  if isAbnormal(info): provenanceBanner(info) else: provenanceChip(info)
