## Chains index (`/chains`) — Page-Descriptions §3.
##
## "A table of every chain in the registry — the honest capability inventory,
## and the page a protocol team lands on from marketing."
##
## §3's closing sentence is the constraint that shapes this file: **"This page
## must be generated from the registry, never hand-maintained, so it cannot
## drift from reality."** So there is no chain name, no VM name, no tier and no
## note written anywhere below. Every cell is read from a published object —
## the sealed generation's summary for the provenance and the counters, the
## pointer for the head — and a chain the registry stops publishing disappears
## from this page by itself.
##
## ## WHAT THIS TABLE IS FOR, AND WHY IT HOLDS FIVE COLUMNS AND NOT EIGHT
##
## A reader arrives here to answer three questions: is my chain here, is its
## data real, and how much of it is there. Those are the columns.
##
## It used to carry three more — the recorder pin, the trace schema and the
## coverage mode — and they were removed because they are not a visitor's
## questions. They are how this deployment is wired, and a reader who wants
## them is one click away: `pages/chain.nim` renders all three in the chain's
## own facts list, with room to say what each one means, which a table cell
## does not have. Nothing was lost by dropping them; they moved to the page
## where they can be explained.
##
## The **Data** column is the one that was added, and it is the one this page
## was previously missing altogether. The site footer used to promise that
## "each chain states on its own pages whether its data is synthetic or
## captured from a network" — an instruction to go and look somewhere else,
## published on the one page that enumerates the chains and did not say it. It
## says it now, in the producer's own label, through the same
## `provenanceTone` the home strip and every transaction page use, so the three
## surfaces that rank and label these chains all read one source.
##
## Two columns §3 asks for are still not in the tree — a debug tier owned by
## Chain-Support-Matrix.md, and a historical-reach field Trace-Artifacts.md §9
## has not landed. They are absent rather than guessed at, and the page no
## longer publishes a note to the reader about which internal document owns
## them: that is a fact about this repository's roadmap and it belongs here, in
## the source, not on a page a visitor reads.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/provenance

proc chainsPage*(rows: seq[ChainRow]): string =
  ## The rows arrive in `chains()`'s registry order — lexicographic — and are
  ## re-ordered here by the SAME rule the home strip uses, because these are the
  ## two surfaces that enumerate this product's chains and they were disagreeing
  ## about which one leads. See `provenance.captureFirst`.
  ##
  ## Ordered in the view rather than in `chainRows`: which chain a reader is
  ## offered first is a presentation decision, and `reader.nim` is the data seam.
  let rows = captureFirst(rows, proc(r: ChainRow): string {.noSideEffect.} = r.info.provenanceKind)
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          span: text "chains"
        tdiv(class = "eyebrow"): text "Capability inventory"
        h1(class = "h1"): text "Supported chains"
        p(class = "lead"):
          text "Every chain BlockTracer publishes. Open one to browse its "
          text "blocks and transactions, and to step through any transaction "
          text "that has a recorded trace."

        tdiv(class = "tablewrap group"):
          table(class = "tbl"):
            thead:
              tr:
                th: text "Chain"
                th: text "Data"
                th(class = "num"): text "Blocks"
                th(class = "num"): text "Transactions"
                th: text "Freshness"
            tbody:
              if rows.len == 0:
                tr:
                  td(class = "empty", colspan = "5"):
                    tdiv(class = "measure"):
                      # Over 60 characters and ending in a full stop, which
                      # `test_explorer_breadth`'s "nothing renders as an empty
                      # list" sweep requires of every empty cell in the corpus —
                      # the rule that stops an empty table from being a blank
                      # box. The old text cleared it by explaining the publishing
                      # pipeline; this clears it by telling the reader what the
                      # emptiness means for them.
                      text "No chains are published here yet, so there is "
                      text "nothing to browse or debug."
              else:
                for row in rows:
                  tr:
                    td:
                      a(class = "addr", href = chainUrl(row.slug)):
                        text row.slug
                    if not row.opened:
                      # A chain the registry publishes whose pointer will not
                      # resolve is a REAL row of a capability inventory, not a
                      # row to skip. Skipping it would make the page claim the
                      # registry lists one fewer chain than it does.
                      td(colspan = "4"):
                        span(class = "badge bad"): text "Unreadable"
                        span(class = "reason"): text row.reason
                    else:
                      # WHAT THE DATA IS, in the producer's own label and the
                      # same tone every other surface gives it. Not derived from
                      # the slug, for `provenance.provenanceBanner`'s reason: a
                      # name is not a claim about where data came from.
                      td:
                        if hasProvenance(row.info):
                          span(class = "badge " &
                                       provenanceTone(row.info.provenanceKind)):
                            text row.info.provenanceLabel
                        else:
                          span(class = "muted"): text "—"
                      td(class = "num"): text $row.info.blockCount
                      td(class = "num"): text $row.info.txCount
                      td:
                        if row.info.stale:
                          span(class = "badge warn"): text "Behind tip"
                        else:
                          span(class = "badge ok"): text "At tip"
                        span(class = "reason"):
                          text "head " & $row.info.headHeight &
                               " · finalized " & $row.info.finalizedHeight
