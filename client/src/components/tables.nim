## The two shared explorer tables: the blocks table and the transactions table.
##
## The `<TransactionsTable>` is defined once here and reused by the chain
## overview, the block detail, the recent-transactions list and the address page
## (Page-Descriptions §6), so its columns and behaviour live in a single place.
## Both render from the reader's row projections — no data is synthesised in the
## view.
##
## ## Rule 1, as markup
##
## "The debug affordance is the primary action wherever a transaction appears.
## Not a menu item, not an icon at the end of a row that scrolls out of view."
##
## §6 makes that a column position: **Debug, first column, always visible.** It
## is the first `<th>` and the first `<td>` of every row, and it is the only
## control in the table, so nothing can outrank it.
##
## Where it POINTS is §7.0's doing. A `ready` or `divergent` transaction's own
## URL *is* its session, so the action links there — not to `/debug`, which is
## the same session behind a deep link and is `noindex` for that reason. An
## `onDemand` transaction's URL carries the metadata and the generate action.
## An `absent` or `unsupported` one gets **no control at all**, not even a
## disabled one: §6 says "absent with a stated reason", and a greyed button
## still occupies the position of the primary action and still invites the click
## it will refuse. `viewutil.offersDebugAction` is the one place that decides.
##
## ## Rule 2, as markup
##
## "Nothing renders as an empty list. Either data, or a statement of why not and
## what would fix it." Both tables take the statement as a parameter rather than
## defaulting to one, because *why* a table is empty is knowledge the page has
## and the component does not: "this block carried no transactions" and "this
## address's newest segment did not resolve" are different facts and deserve
## different sentences. The previous default — the two words "No transactions."
## — was the empty list the rule forbids, with a full stop after it.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil

proc emptyRow(colspan, note: string): string =
  ui:
    tr:
      td(class = "empty", colspan = colspan):
        tdiv(class = "measure"): text note

proc blocksTable*(chain: string, info: ChainInfo, rows: seq[BlockRow],
                  emptyNote: string): string =
  ui:
    tdiv(class = "tablewrap"):
      table(class = "tbl"):
        thead:
          tr:
            # A numeric column's HEADER is right-aligned too, so the header and
            # the digits below it share an edge (rubric A6).
            th(class = "num"): text "Height"
            th: text "Block hash"
            th(class = "num"): text "Txs"
            th: text "Finality"
            th: text "Parent"
        tbody:
          if rows.len == 0:
            raw emptyRow("5", emptyNote)
          else:
            for b in rows:
              tr:
                td(class = "num"):
                  a(href = blockUrl(chain, b.hash)): text $b.height
                td(class = "hash"):
                  a(href = blockUrl(chain, b.hash)):
                    text truncHash(b.hash)
                td(class = "num"): text $b.txCount
                td:
                  let f = blockFinality(info, b.height)
                  span(class = "badge " & finalityClass(f)):
                    text sentenceCase(f)
                td(class = "hash"):
                  # The oldest block a generation holds has a parent this tree
                  # does not index. It is a real block of a real chain, and a
                  # link to a page that was never written is worse than no
                  # link: the identifier is still shown, in full, and the
                  # absence of the link is the statement.
                  if b.parentIndexed:
                    a(href = blockUrl(chain, b.parentHash)):
                      text truncHash(b.parentHash)
                  else:
                    span(class = "mono muted",
                         title = "below this generation's floor"):
                      text truncHash(b.parentHash)

proc availabilityBadge*(a: TraceAvailability): string =
  ui:
    span(class = "badge " & availabilityClass(a)):
      text availabilityState(a)

proc outcomeBadge*(o: OutcomeOverall): string =
  ui:
    span(class = "badge " & outcomeClass(o)):
      text outcomeLabel(o)

proc debugCell*(chain: string, row: TxRow): string =
  ## §6 column 1. An action where the trace licenses one, a stated reason where
  ## it does not — and never a control that cannot succeed.
  ##
  ## The branch is OUTSIDE the `ui` block, and that is load-bearing rather than
  ## stylistic. `ui:` renders a top-level `nnkIfStmt` as nothing at all — the
  ## SSR codegen returns nil for a node that is not a call, and the proc then
  ## returns the empty string. Written the other way round this proc compiled,
  ## ran, and emitted `<td class="act"></td>` for every row in the product: the
  ## primary action, silently absent, with no error anywhere. `test_explorer_
  ## breadth`'s "every row carries its Debug affordance" is the check that
  ## caught it and the check that keeps it caught.
  if offersDebugAction(row.availability):
    ui:
      a(class = debugActionClass(row.availability), href = txUrl(chain, row.hash)):
        text availabilityLabel(row.availability)
  else:
    ui:
      span(class = "badge muted", title = availabilityNote(row.availability)):
        text availabilityState(row.availability)

proc addressCell(chain, address: string): string =
  if address.len > 0:
    ui:
      a(class = "addr", href = addressUrl(chain, address)):
        text truncHash(address)
  else:
    # §2.3: "some chains have no sender at all". An em dash is the honest
    # rendering of a role this chain family does not have — it is not a
    # missing value.
    ui:
      span(class = "muted"): text "—"

proc txTable*(chain: string, rows: seq[TxRow], emptyNote: string): string =
  ui:
    tdiv(class = "tablewrap"):
      table(class = "tbl txtbl"):
        thead:
          tr:
            th(class = "act"): text "Debug"
            th: text "Tx hash"
            th(class = "num"): text "Block"
            th: text "From"
            th: text "To / target"
            th: text "Method"
            th(class = "num"): text "Fee"
            th: text "Status"
        tbody:
          if rows.len == 0:
            raw emptyRow("8", emptyNote)
          else:
            for t in rows:
              # §6: "Reverted transactions are visually distinct." They are the
              # population this product exists for, so the row carries a class
              # of its own rather than relying on the status badge at the far
              # right of a horizontally scrolling table.
              let rowClass =
                case t.outcome
                of ooReverted, ooFailedWithEffects: "reverted"
                of ooPartial: "partial"
                of ooSucceeded: ""
              tr(class = rowClass):
                td(class = "act", `data-label` = "Debug"): raw debugCell(chain, t)
                td(class = "hash", `data-label` = "Tx hash"):
                  a(href = txUrl(chain, t.hash)):
                    text truncHash(t.hash)
                td(class = "num", `data-label` = "Block"):
                  if t.blockHash.len > 0:
                    a(href = blockUrl(chain, t.blockHash)):
                      text $t.height & ":" & $t.index
                  else:
                    # §2.3's `order` is a union: not every chain family orders
                    # by block and index, and one that does not gets no link
                    # rather than a fabricated height.
                    text $t.height & ":" & $t.index
                td(`data-label` = "From"): raw addressCell(chain, t.fromAddr)
                td(`data-label` = "To / target"): raw addressCell(chain, t.toTarget)
                td(`data-label` = "Method"):
                  if t.methodSel.len > 0:
                    span(class = "mono"): text t.methodSel
                  else:
                    span(class = "muted"): text "—"
                td(class = "num", `data-label` = "Fee"):
                  if t.cost.len > 0:
                    text feeLabel(t.cost)
                  else:
                    span(class = "muted"): text "—"
                td(`data-label` = "Status"):
                  raw outcomeBadge(t.outcome)
                  if t.outcomeReason.len > 0:
                    # §6 column 10: "with the revert reason inline when
                    # decodable". Inline, beside the status, and not behind a
                    # hover — the reason is why the row is worth opening.
                    span(class = "reason"): text t.outcomeReason
