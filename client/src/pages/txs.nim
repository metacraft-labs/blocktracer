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
          text "Newest first, walking backwards by block. Debug is the first "
          text "column of every row, because arriving at a transaction with a "
          text "published trace means arriving in its execution."

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

        tdiv(class = "stub"):
          tdiv(class = "measure"):
            b: text "Two of this table's behaviours need script and this "
            b: text "deployment ships none. "
            text "§6 asks for a column picker for family-specific extras and "
            text "for reverted rows to be sortable to the top. Reverted rows "
            text "are already visually distinct, which is the half that works "
            text "without script; re-ordering and choosing columns are the "
            text "half that does not, and a control that cannot act is one "
            text "this product does not ship. Both arrive with hydration."
