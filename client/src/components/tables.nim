## The two shared explorer tables: the blocks table and the transactions table.
##
## The `<TransactionsTable>` is defined once here and reused by block detail and
## the block list (Page-Descriptions §6) so its columns and behaviour live in a
## single place. Both render from the reader's row projections — no data is
## synthesised in the view.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil

proc blocksTable*(chain: string, rows: seq[BlockRow]): string =
  ui:
    tdiv(class = "tablewrap"):
      table(class = "tbl"):
        thead:
          tr:
            th: text "Height"
            th: text "Block hash"
            th: text "Txs"
            th: text "Parent"
        tbody:
          if rows.len == 0:
            tr:
              td: text ""
          else:
            for b in rows:
              tr:
                td(class = "num"): text $b.height
                td(class = "hash"):
                  a(href = blockUrl(chain, b.hash)):
                    text truncHash(b.hash)
                td(class = "num"): text $b.txCount
                td(class = "hash"):
                  a(href = blockUrl(chain, b.parentHash)):
                    text truncHash(b.parentHash)

proc availabilityBadge*(a: TraceAvailability): string =
  ui:
    span(class = "badge " & availabilityClass(a)):
      text availabilityLabel(a)

proc outcomeBadge*(o: OutcomeOverall): string =
  ui:
    span(class = "badge " & outcomeClass(o)):
      text outcomeLabel(o)

proc txTable*(chain: string, rows: seq[TxRow]): string =
  ui:
    tdiv(class = "tablewrap"):
      table(class = "tbl"):
        thead:
          tr:
            th: text "Trace"
            th: text "Tx hash"
            th: text "Block"
            th: text "From"
            th: text "To / target"
            th: text "Method"
            th: text "Status"
        tbody:
          if rows.len == 0:
            tr:
              td(class = "empty"): text "No transactions."
          else:
            for t in rows:
              tr:
                td: raw availabilityBadge(t.availability)
                td(class = "hash"):
                  a(href = txUrl(chain, t.hash)):
                    text truncHash(t.hash)
                td(class = "num"): text $t.height & ":" & $t.index
                td:
                  if t.fromAddr.len > 0:
                    span(class = "mono"): text truncHash(t.fromAddr)
                  else:
                    span(class = "muted"): text "—"
                td:
                  if t.toTarget.len > 0:
                    span(class = "mono"): text truncHash(t.toTarget)
                  else:
                    span(class = "muted"): text "—"
                td:
                  if t.methodSel.len > 0:
                    code: text t.methodSel
                  else:
                    span(class = "muted"): text "—"
                td: raw outcomeBadge(t.outcome)
