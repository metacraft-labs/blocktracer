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

proc sourcesBadge*(v: SourceCoverageView): string =
  ## The qualifier on §6 column 1's action: whether the session it opens can
  ## show source, and for how much of the transaction.
  ##
  ## ## Why it lives IN the Debug cell and is not a column of its own
  ##
  ## §6's table is ten numbered columns and none of them is this one, so a
  ## column here would be an extension to a specified table — and it would have
  ## to go last, after `Status`, which on a horizontally scrolling table is the
  ## position §6 opens by warning about ("not an icon at the end of a row that
  ## scrolls out of view"). Column 1 is the one column §6 guarantees is always
  ## visible, and this badge is a statement ABOUT the control in it: "Debug" and
  ## "Debug, but three of its four contracts step without source" are different
  ## promises and the second must not be discoverable only by taking the first.
  ##
  ## It is a `span`, not a control. §6's "it is the only control in the table,
  ## so nothing can outrank it" is preserved exactly: the action is still the
  ## only thing in the table a visitor can click.
  ##
  ## ## `data-sources`, so a check finds it by attribute and not by copy
  ##
  ## The same reason `MetaRow.dataProvenance` gives for itself: "the label is
  ## COPY … keying them on the string would make a copy edit silently delete the
  ## guarantee". The journey and the breadth suite both read this attribute, so
  ## the words above can be rewritten without any check going quiet.
  let count = sourcesCount(v)
  ui:
    span(class = "badge srcbadge " & sourcesClass(v.state),
         `data-sources` = $v.state, title = sourcesNote(v)):
      text sourcesState(v.state)
      if count.len > 0:
        # Resolved-over-executed, inside the badge, because the ratio IS the
        # state for a partial transaction and a badge that said only "partial"
        # would leave a visitor to open the session to find out how partial.
        #
        # NO LITERAL SPACE BEFORE IT, and the gap is a token on the container
        # instead. The badge is a flex box, and a flex box strips leading and
        # trailing whitespace from every item it lays out — so `" " & count`
        # rendered `Sources partial2/3`, which is how a ratio comes to read as
        # part of the word before it.
        span(class = "mono"): text count

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
                td(class = "act", `data-label` = "Debug"):
                  raw debugCell(chain, t)
                  # The qualifier, under the action rather than beside it: the
                  # action is what a visitor came for and the badge is what
                  # they get when they take it, so the reading order is the
                  # order of the decision.
                  #
                  # NO WRAPPER ELEMENT, and that is deliberate rather than
                  # terse. A `<div>` around both would have changed the DOM of
                  # every row in the tree including the ones this feature has
                  # nothing to say about — 42 pages of the synthetic chain
                  # render this table and none of them will ever show a badge,
                  # and the visual campaign would have had to re-capture all of
                  # them to prove that nothing moved. The badge lays itself out
                  # (`.srcbadge`), so a row with no state to report emits
                  # exactly the bytes it emitted before.
                  #
                  # `sourcesStated` and not
                  # `if t.sources.state != scUnrecorded` — the condition
                  # belongs to the state, not to this table, and the metadata
                  # rows ask the identical question.
                  if sourcesStated(t.sources.state):
                    raw sourcesBadge(t.sources)
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
