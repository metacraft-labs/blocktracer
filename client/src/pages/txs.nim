## Recent transactions (`/{chain}/txs`) — Page-Descriptions §6.
##
## The page whose entire content is the shared `<TransactionsTable>`. Its
## columns, its Debug-first ordering and its reverted-row treatment all live in
## `components/tables.nim`, which is the point of §6: "so its behaviour is
## defined once".
##
## What this page adds around that table is the cursor (§2.2) and an honest
## account of the two behaviours §6 asks for that need script and do not have it
## yet — the column picker and sorting reverted rows to the top. Both are stated
## once, here, on the surface that owns them, rather than as a caveat under
## every table in the product.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/tables
import ../components/pager
import ../components/degraded

proc txsPage*(chain: string, info: ChainInfo, page: TxPage,
              degradation: ChainDegradation, notice: DegradationNotice): string =
  let where =
    if page.rows.len == 0: ""
    elif page.fromHeight == page.toHeight: "Block " & $page.toHeight
    else: "Blocks " & $page.toHeight & " down to " & $page.fromHeight
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          a(href = chainUrl(chain)): text chain
          span(class = "sep"): text "/"
          span: text "transactions"
        tdiv(class = "eyebrow"): text "Transactions"
        h1(class = "h1"): text chain & " transactions"
        p(class = "lead"):
          # TWO CLAUSES, JUDGED SEPARATELY.
          #
          # "Newest first" is kept: a sort order is not visible from the rows
          # themselves and a reader needs it. "walking backwards by block" is
          # the same fact again in the pager's vocabulary, and adds nothing a
          # reader can use.
          #
          # "Debug is the first column of every row, BECAUSE arriving at a
          # transaction with a published trace means arriving in its execution"
          # is the page arguing for its own layout. It is a good sentence in a
          # design document, where someone is deciding whether the column
          # belongs there; on the page the column is simply there and visible,
          # and no visitor needs persuading of its position. What they can use
          # is what the column DOES, so that is what it now says.
          text "Newest first. Open Debug on any transaction with a recorded "
          text "trace to step through its execution."

        raw degraded.notice(degradation, notice)

        tdiv(class = "group"):
          raw txTable(chain, page.rows,
            "No transactions in this range. The chain's blocks are published " &
            "and this range of them carried none; the block list walks " &
            "further back.")
        raw pager(Pager(
          summary: where,
          newestHref: (if page.toHeight >= 0 and
                          page.toHeight < info.headHeight: txsUrl(chain)
                       else: ""),
          olderHref: (if page.hasMore: txsFromUrl(chain, page.nextFrom)
                      else: "")))

        # THE STUB NOTE IS GONE. It read: "Two of this table's behaviours need
        # script and this deployment ships none. §6 asks for a column picker for
        # family-specific extras and for reverted rows to be sortable to the
        # top. … Both arrive with hydration."
        #
        # It published a spec section number — a literal "§6" — to visitors, and
        # the rest was a roadmap note: which behaviours are unbuilt, why, and
        # when they arrive. A reader of a transaction list has no use for any of
        # it. There is no control on this page that fails to work and no cell
        # left blank by the absence, so nothing here needs explaining; the note
        # answered a question only someone maintaining this table would ask.
        # What §6 asks for is tracked where requirements are tracked.
