## Transaction detail (`/{chain}/tx/{hash}`) — Page-Descriptions §7, for the
## availability rows that do NOT open a session.
##
## ## What this page is, and what it is not
##
## §7.0's table has three rows and this page is two of them:
##
##   | `ready`, `divergent` | **The debugging interface**, with the transaction
##                            metadata rendered around it (§7.1) |
##   | `onDemand`           | The metadata, and the generate action |
##   | `absent`,
##     `unsupported`       | The metadata, with the reason stated. **No
##                            debugger, and no pretence of one** |
##
## The first row is `pages/debug.nim`, rendered at this route by
## `ssr.renderTx`: "The debug affordance is the primary action wherever a
## transaction appears — and a button that opens the debugger is a link to the
## primary action, not the primary action." A transaction with a published
## trace therefore never renders this page, and there is deliberately no branch
## here that would let it: a `Debug` button living on this surface is exactly
## the waiting room §7.0 forbids, and removing the branch is what stops it
## growing back.
##
## The remaining two rows are what this page serves. They have no session, so
## there is nothing for a debugger to hydrate over and the metadata IS the
## page.
##
## ## Rendered strictly from the data plane
##
## The three data-plane layers (immutable facts + txstate + the trace overlay);
## nothing is computed in the page. The overview grid and the decoded input
## come from `viewutil.txMetadataRows` / `txPayloadRows`, which are also what
## the session's metadata pane renders — §7.1's "rendered in two places … from
## one source, and the two cannot be allowed to diverge".

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../debugger/session_view

proc metaGrid(rows: seq[MetaRow]): string =
  ## One `<dl>` of §7.2 facts, presented the explorer way. It knows how to
  ## present a row; it does not know which rows a transaction has, so it cannot
  ## grow a fact the metadata pane lacks — and the pane cannot grow one this
  ## page lacks.
  ui:
    dl(class = "dl"):
      for r in rows:
        dt: text r.label
        dd:
          if r.href.len > 0:
            a(href = r.href, class = "identifier"): text r.value
          elif r.badge.len > 0:
            span(class = "badge " & r.badge): text r.value
          elif r.identifier:
            span(class = "identifier"): text r.value
          else:
            text r.value
          if r.suffix.len > 0:
            span(class = "muted"): text " " & r.suffix

proc txPage*(chain: string, v: TxView): string =
  let headline = v.headline
  # §7.0's first row does not render here, and cannot be made to.
  #
  # A `Debug` button on this page is "a link to the primary action, not the
  # primary action", and the way to keep it from growing back is to make the
  # state that would need one unrenderable rather than to rely on a caller
  # choosing correctly. `ssr.renderTx` routes `ready` and `divergent` to
  # `pages/debug.nim`; a routing change that stopped doing so fails the static
  # export instead of quietly reinstating the waiting room — the same
  # treatment `components/debugger.weightClass` gives a layout it cannot draw.
  if headline in {taReady, taDivergent}:
    raise newException(ValueError,
      "transaction " & v.hash & " has a " & $headline & " trace, so §7.0 " &
      "lands it in the debugging interface; ssr.renderTx must render " &
      "pages/debug.debugPage for it, not the metadata page")

  # §7.2 sections 5 and 6 come from the trace, so what they say depends on
  # whether one can ever exist. "They appear here once this transaction has a
  # recorded trace" is true on the on-demand row and is a promise the product
  # cannot keep on the other two: an execution that publishes no call
  # structure, and a VM with no recorder, are terminal in different ways.
  # §14.1a: "'Not now' and 'not ever' are different states. … Presenting
  # either as the other is the failure this table exists to prevent."
  let traceSectionNote =
    case headline
    of taOnDemand:
      "come from the execution trace. They appear here once this transaction " &
      "has a recorded trace."
    of taAbsent:
      "come from the execution trace. This execution publishes no call " &
      "structure, so there is none to record — this section is empty " &
      "permanently, not yet."
    else:
      "come from the execution trace. No recorder exists for this VM yet, so " &
      "no trace can be produced and this section stays empty until one does."
  let native = txNativePayload(v)
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          a(href = chainUrl(chain)): text chain
          span(class = "sep"): text "/"
          span: text "tx"
          span(class = "sep"): text "/"
          span: text truncHash(v.hash)

        # ── Hero ──────────────────────────────────────────────
        tdiv(class = "eyebrow"): text "Transaction"
        tdiv(class = "titlerow"):
          h1(class = "h1 identifier"): text truncHash(v.hash)
          span(class = "badge lg " & outcomeClass(v.outcome)):
            text outcomeLabel(v.outcome)
        p(class = "identifier lead tight"):
          text v.hash
        if v.outcomeReason.len > 0:
          p(class = "muted stack"):
            text outcomeReasonLabel(v.outcome) & ": " & v.outcomeReason

        # ── The trace's state, and the only action it licenses ─
        #
        # §7.0: `onDemand` gets "the metadata, and the generate action";
        # `absent` and `unsupported` get "the metadata, with the reason stated.
        # No debugger, and no pretence of one."
        #
        # So the second pair has NO control at all — not even a disabled one.
        # A greyed `Not observable` button is still a button: it occupies the
        # position of the primary action and invites the click it will refuse,
        # which is the pretence the row rules out. The state is a badge and the
        # reason is a sentence, and neither pretends to be actionable.
        tdiv(class = "debugcard group"):
          tdiv(class = "row"):
            if headline == taOnDemand:
              button(class = "btn primary"): text availabilityLabel(headline)
            span(class = "badge coverage " & availabilityClass(headline)):
              text availabilityState(headline)
          p(class = "note"): text availabilityNote(headline)
          # Page-Descriptions §7.2 puts this line BESIDE the Debug action that
          # requests it. VD.2's round 2 measured it ~1000px below the button, in
          # a different section: proximity was grouping the explanation with the
          # wrong thing. Rounds 1-4 are not recorded in reviews/ledger.json, so
          # that measurement has no citable id; the round-5 findings on the same
          # separation are ledger@2026-08-29.2:tx-detail/wide/light/L2/3 and
          # ledger@2026-08-29.2:tx-detail/wide/light/L5/6.
          #
          # It belongs to the ON-DEMAND row only. §7.2 attaches it to "the
          # Debug button that requests it" — it is the sentence that converts,
          # and it converts because a trace can still be had. Beside a
          # transaction whose execution has no call structure, or a VM with no
          # recorder, the same words describe a section that will never fill.
          if headline == taOnDemand:
            p(class = "note spec"):
              text "Internal calls and state changes come from the execution trace."
          # The PRODUCER's own words for this execution, where the tree
          # published any — quoted beneath the enum's sentence rather than
          # folded into it, which is the rule `components/degraded
          # .DegradationNotice.detail` already states for the explorer's §14
          # treatments: "a reason the pipeline wrote is evidence, and rewriting
          # it in the view would make it prose."
          #
          # It was being dropped. `Trace-Artifacts` requires a reason on every
          # `absent` and `unsupported` execution and `blocktracer_client
          # /decode.nim` refuses an overlay without one, but this page rendered
          # `e.reason` only inside the `executions.len > 1` list — so a
          # single-execution transaction, which is every one of them except the
          # Aztec split, showed the generic enum sentence and threw the specific
          # one away. VD.6 captured the two terminal states for the first time
          # and that is what the images showed: two pages whose only difference
          # was the generic sentence, over published reasons that named a
          # private kernel and an AVM revision respectively.
          #
          # This is the line that makes the state ACTIONABLE where it can be.
          # "No recorder exists for this VM yet" tells a visitor nothing they
          # can do anything with; "ran under AVM revision v0.34, and the pinned
          # recorder set covers v0.41 and later" tells them what question to
          # ask. §14's row for that state asks for the recorder's status to be
          # reachable, and this is the half of it the published tree can supply.
          if v.executions.len == 1 and v.executions[0].reason.len > 0:
            p(class = "note reason"): text v.executions[0].reason
          if v.executions.len > 1:
            ul(class = "execlist"):
              for e in v.executions:
                li:
                  span(class = "sel"): text (if e.selector.len > 0: e.selector else: "execution")
                  span(class = "badge " & availabilityClass(e.availability)):
                    text availabilityLabel(e.availability)
                  if e.reason.len > 0:
                    span(class = "reason"): text e.reason

        # ── Overview grid ─────────────────────────────────────
        h2(class = "sec-title next"): text "Overview"
        raw metaGrid(txMetadataRows(chain, v))

        # ── §7.2's remaining sections ─────────────────────────
        #
        # Each is wrapped in a container carrying the section's id, and that is
        # load-bearing rather than tidy: the capture harness clips a named view
        # to `#decoded-input`, `#events`, `#internal-calls`, `#state-changes`
        # and `#raw`, and an id on the HEADING clips the heading — a review
        # image of two words and no content, filed under the section's name.
        tdiv(id = "decoded-input"):
          h2(class = "sec-title next"): text "Decoded input"
          raw metaGrid(txPayloadRows(v))
          tdiv(class = "stub"):
            tdiv(class = "measure"):
              text UnknownSelectorNote

        tdiv(id = "events"):
          h2(class = "sec-title next"): text "Events"
          tdiv(class = "stub"):
            tdiv(class = "measure"):
              text "Events come from the transaction receipt, not from a trace. "
              text "They appear here once this chain's receipts are published."

        tdiv(id = "internal-calls"):
          h2(class = "sec-title sibling"): text "Internal calls"
          tdiv(class = "stub"):
            tdiv(class = "measure"):
              text "Internal calls " & traceSectionNote

        tdiv(id = "state-changes"):
          h2(class = "sec-title sibling"): text "State changes"
          tdiv(class = "stub"):
            tdiv(class = "measure"):
              text "State changes " & traceSectionNote

        # ── Raw native payload ────────────────────────────────
        if native.len > 0:
          tdiv(id = "raw"):
            h2(class = "sec-title next"): text "Raw (chain-native)"
            pre(class = "raw"): text native
