## Chains index (`/chains`) — Page-Descriptions §3.
##
## "A table of every chain in the registry — the honest capability inventory,
## and the page a protocol team lands on from marketing."
##
## §3's closing sentence is the constraint that shapes this file: **"This page
## must be generated from the registry, never hand-maintained, so it cannot
## drift from reality."** So there is no chain name, no VM name, no tier and no
## note written anywhere below. Every cell is read from a published object —
## the registry row for the recorder pin, the sealed generation's summary for
## coverage and counters, the pointer for the head — and a chain the registry
## stops publishing disappears from this page by itself.
##
## ## Two of §3's eight columns have no published source, and say so
##
## §3 asks for eight columns. Six are in the tree. Two are not, and this page
## states that rather than inventing them, because a capability inventory that
## guesses at a capability is the one page in the product where a confident
## wrong answer costs the most:
##
##   * **Debug tier (T0–T2)** — the registry publishes a recorder pin, a profile
##     and a trace schema, which is *what* records the chain. The tier is a
##     grade of that, and Chain-Support-Matrix.md owns it; nothing in
##     `/registry/chains.v{N}.json` carries it. The recorder pin is shown
##     instead, which is the fact the tier is derived from.
##   * **Historical reach** (`archive` / `windowed(7d)` / …) — a retention
##     property of the ingestion, and there is no retention field in the
##     contract yet (Trace-Artifacts.md §9 is where it lands).
##
## Both are named in the page's own footer note, so a reader can tell the
## difference between "BlockTracer does not know" and "this chain does not have
## one" — which is exactly the distinction §14 exists to keep.

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
          text "Every chain in the published registry, with what BlockTracer "
          text "can actually do with it. Generated from the registry, so it "
          text "cannot claim support that is not deployed."

        tdiv(class = "tablewrap group"):
          table(class = "tbl"):
            thead:
              tr:
                th: text "Chain"
                th: text "Recorder"
                th: text "Trace schema"
                th: text "Coverage"
                th(class = "num"): text "Blocks"
                th(class = "num"): text "Transactions"
                th: text "Freshness"
            tbody:
              if rows.len == 0:
                tr:
                  td(class = "empty", colspan = "7"):
                    tdiv(class = "measure"):
                      text "This deployment's registry publishes no chains. "
                      text "A chain appears here when the pipeline publishes "
                      text "its registry row and its first generation."
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
                      td(colspan = "6"):
                        span(class = "badge bad"): text "Unreadable"
                        span(class = "reason"): text row.reason
                    else:
                      td:
                        if row.info.hasRecorder:
                          span(class = "mono"):
                            text row.info.recorderId & " " & row.info.recorderVersion
                        else:
                          span(class = "badge muted"): text "No recorder"
                      td:
                        if row.info.traceSchema.len > 0:
                          span(class = "mono"): text row.info.traceSchema
                        else:
                          span(class = "muted"): text "—"
                      td:
                        span(class = "badge coverage info"):
                          text row.info.coverageMode
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

        tdiv(class = "stub"):
          tdiv(class = "measure"):
            b: text "Two of this table's columns have no published source yet. "
            text "The debug tier is a grade of the recorder pin shown above, "
            text "and it is owned by the chain support matrix rather than by "
            text "the registry; historical reach is a retention property the "
            text "trace-artifact contract does not carry yet. Both arrive as "
            text "registry fields, and this page will read them the way it "
            text "reads every other cell here."
