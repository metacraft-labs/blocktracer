## components/reach.nim
##
## **The chain landing page's capability-and-limitation statement**, in plain
## language, read from the chain's own registry row.
##
## Chain-Support-Matrix.md §4 item 4 makes this a condition of listing a chain
## at all — "a chain landing page exists stating the debug tier, historical
## reach, and known limitations in plain language" — and §5 step 8 repeats it as
## a step of adding one. Until this module there was no surface in the product
## that stated any of the three: `/chains` carries a table of counts and
## `/{chain}` carried head, finalized, two ledger tables and the producer's
## prose about what it watched.
##
## ## What this states, and what it deliberately does not
##
## It states **historical reach** and **the instruction set recordings are
## written against**, because those are published, per chain, as data:
## `reach`, `historyFloor` and `vm.instructionSet` on the registry row
## (Configuration.md §2.1, from §1.3's vocabulary). Everything here is a
## rendering of those three members and of nothing else.
##
## IT DOES NOT STATE A DEBUG TIER, and that is the one omission worth writing
## down because §4 item 4 asks for one. Chain-Support-Matrix.md §1.2 is explicit
## that "tier is per transaction, not per chain: the same chain yields T2 for a
## verified contract and T1 for an unverified one, frequently within a single
## transaction" — so a chain-wide tier is not a fact about a chain, and the
## published tree carries no chain-wide tally of what its recordings reached
## either. `tools/capture/expectations.mjs` already records the anti-requirement
## this would walk into: "a debug tier badge or a historical-reach value
## INVENTED from the recorder pin. This is the one page in the product where a
## confident wrong answer costs the most, and a plausible T1 badge with no
## source behind it is exactly that." A reach READ FROM THE REGISTRY is not that
## badge; a tier derived from the pin would be.
##
## So the tier half of §4 item 4 stays open, and it is open as a PUBLISHING gap
## rather than as a page gap: it needs the ingest to publish how many of a
## chain's recordings resolved source and how many stayed at instruction level,
## which is a measurement it already makes per transaction
## (`execution.sourceLevel`) and does not aggregate.
##
## ## Why the prose is a pure function and the markup is three lines
##
## Every sentence below is a claim about a real chain that a visitor acts on —
## "debuggable back to block N" is a statement somebody will trust before
## spending an hour. So the sentence selection is a `func` over the profile,
## with no store, no render and no markup in it, and the test drives it with a
## constructed `ChainProfile` for each of §1.3's six tokens plus both
## non-declared states. A sentence that can only be reached by building a tree
## is a sentence nobody writes an arm for.

import std/strutils

# `isonim/ssr/escape` is imported for the ATTRIBUTE escaper the `ui` DSL expands
# to, exactly as every other component in this directory imports it. It is not
# referenced by name here and must not be removed as unused: `ui`'s generated
# code calls `escapeAttr`, so dropping this line fails the build inside the
# macro expansion with an `undeclared identifier` pointing at isonim's own
# source rather than at this file.
import isonim/ssr/escape
import isonim/dsl/ui
import blocktracer_client

type
  ReachStatement* = object
    ## The rendered sentences, separated so a test can assert each one and so
    ## the page is not the thing that decides which to show.
    lead*: string
      ## What reach means here, and what it costs a visitor. Always non-empty:
      ## every state of the declaration has an honest sentence, including the
      ## two that declare nothing.
    note*: string
      ## The producer's own words about the boundary, verbatim, or empty. Kept
      ## separate because it is a QUOTATION and must not be welded into a
      ## sentence this module composed — the two have different authors and a
      ## reader is entitled to see which is which.
    isa*: string
      ## The instruction-set sentence, or empty when the row declares none.

const
  ReachHeading* = "How far back this chain can be debugged"
    ## Exported so the test and the visual-review brief name the same string.

  WhyStateIsNeeded = "Stepping a transaction means re-executing it, and that " &
    "needs the state the chain was in just before it ran. "
    ## The one clause every DECLARED reach shares. It is the premise the whole
    ## section rests on and a visitor does not arrive holding it: without it,
    ## "prestate is obtainable above block N" is a sentence about an internal
    ## noun.

  BelowTheFloor = "THAT IS A LIMIT ON WHAT CAN BE RECORDED, not on what is " &
    "published here. A transaction already recorded carries its own execution " &
    "and steps from it for good; the boundary says that a transaction below it " &
    "cannot be recorded NOW, because the state a replay would have to start " &
    "from no longer exists anywhere to be fetched."
    ## ── THE CLAUSE THAT HAD TO BE CORRECTED BEFORE IT SHIPPED ─────────────
    ##
    ## The first draft read "a transaction below that point is still published
    ## here and still readable; what it cannot do is step". It was written, the
    ## page was built, and `/aztec` refuted it on sight: that chain publishes
    ## blocks 68,062 to 68,231 and declares a floor at 70,157, so EVERY
    ## transaction it publishes is below its own floor — and each one carries a
    ## container and a working Debug button two sections further down the same
    ## page. The sentence would have contradicted the controls beside it.
    ##
    ## The product already models it correctly and the prose had simply not
    ## caught up: `FloorVerdict.fvBelow` is documented as "prestate does not
    ## exist below the floor, so no GENERATION can succeed". The floor governs
    ## whether a NEW recording can be made, not whether an existing one plays.
    ## A capture taken while a block was still inside the window keeps working
    ## for as long as it is published, which is the whole reason this product
    ## records rather than replays on demand.

func floorPhrase(f: ChainHistoryFloor): string =
  ## "block 67,010 and above", or the honest alternative when the row states no
  ## position. `stated == false` is NOT height zero — a floor of zero is a chain
  ## reachable to genesis, and this is the one place the difference is spent.
  if f.stated: "block " & $f.height & " and above"
  else: "a boundary this chain's registry row does not state the position of"

func reachLead(p: ChainProfile): string =
  ## One sentence per state of the declaration, and the two non-declared states
  ## get their own rather than sharing a default.
  ##
  ## THE UNRECOGNISED CASE IS NOT THE ABSENT CASE. A row that said nothing was
  ## published before the member existed; a row that said something this build
  ## cannot read is a producer this build cannot read, and a consumer has to
  ## treat it conservatively and say which it met. Rendering them as one
  ## sentence would make a format skew indistinguishable from an old tree.
  case p.reach.state
  of dsAbsent:
    "This chain's registry row states no historical reach, so this page claims " &
    "none. Whether a particular transaction has a recording is stated on that " &
    "transaction's own page, which is a fact about that transaction rather " &
    "than a promise about the chain."
  of dsUnrecognised:
    "This chain declares a historical reach this build does not recognise (" &
    p.reach.token & "), so this page states none rather than guessing at it. " &
    "Whether a particular transaction has a recording is stated on that " &
    "transaction's own page."
  of dsDeclared:
    case p.reach.kind
    of rkArchive:
      WhyStateIsNeeded & "On this chain that state is obtainable for any " &
      "historical block, so there is no block below which a published " &
      "transaction stops being steppable."
    of rkFloor:
      if p.floor.stated and p.floor.height == 0:
        WhyStateIsNeeded & "On this chain it was obtainable at every block " &
        "this capture probed, down to block 0 — so no transaction published " &
        "here sits below the boundary. The registry records a floor rather " &
        "than full archive reach because a floor is what was MEASURED: the " &
        "probe reached genesis and found state, which is a lower bound on the " &
        "reach and not a promise about every block in between."
      else:
        WhyStateIsNeeded & "On this chain it is obtainable at " &
        floorPhrase(p.floor) & ", and not below. " & BelowTheFloor
    of rkWindowed:
      WhyStateIsNeeded & "On this chain it is kept for a moving window and was " &
      "obtainable at " & floorPhrase(p.floor) & " when this generation was " &
      "captured. " & BelowTheFloor &
      " And the boundary MOVES UP as the chain advances, so what can be " &
      "recorded shrinks from below while what is already published does not."
    of rkVersionAddressed:
      WhyStateIsNeeded & "On this chain that state is addressed by version " &
      "rather than by block, so how far back a transaction can be stepped is " &
      "not a height and this page does not state one. The transaction's own " &
      "page states whether it was recorded."
    of rkSelfContained:
      WhyStateIsNeeded & "On this chain a transaction carries the state it " &
      "reads with it, so stepping one needs nothing still held by a node: a " &
      "transaction is steppable whenever its own payload is published, " &
      "however old it is."
    of rkRecentOnly:
      WhyStateIsNeeded & "On this chain it is kept only for recent blocks, at " &
      floorPhrase(p.floor) & ". " & BelowTheFloor

func reachStatement*(p: ChainProfile): ReachStatement =
  ## The whole statement, from the registry row and from nothing else.
  ##
  ## `note` is carried only when the row supplied one AND the reach is
  ## declared: the producer's note is about the boundary, and quoting a note
  ## about a boundary under a sentence that says there is no stated boundary
  ## would make the page contradict itself in two paragraphs.
  ReachStatement(
    lead: reachLead(p),
    note:
      (if p.reach.state == dsDeclared and p.floor.reason.len > 0:
         p.floor.reason else: ""),
    isa:
      (if p.vm.stated and p.vm.instructionSet.len > 0:
         "Recordings on this chain are written against the " &
         p.vm.instructionSet & " instruction set. Where a contract's source " &
         "cannot be resolved, that is the granularity a step is reported at — " &
         "each transaction's page states which of the two it got."
       else: ""))

proc reachSection*(p: ChainProfile): string =
  ## The section, for the chain landing page. Rendered unconditionally: there is
  ## no state of the declaration for which the honest answer is silence, and a
  ## section that disappeared when a chain declared nothing would make the
  ## weakest chains the ones that say least about themselves.
  let st = reachStatement(p)
  ui:
    tdiv:
      h2(class = "sec-title next"): text ReachHeading
      p(class = "lead measure"): text st.lead
      if st.note.len > 0:
        # THE PRODUCER'S WORDS, MARKED AS A QUOTATION. `historyFloor.reason` is
        # written by whatever produced the capture and is the only statement in
        # this section this repository did not compose; presenting it as more of
        # the same prose would attribute it here.
        p(class = "muted measure"):
          text "How that boundary was established, in the pipeline's own words: “"
          text st.note.strip()
          text "”"
      if st.isa.len > 0:
        p(class = "muted measure"): text st.isa
