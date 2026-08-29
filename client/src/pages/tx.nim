## Transaction detail (`/{chain}/tx/{hash}`) — Page-Descriptions §7. The most
## important non-debugger page. Rendered strictly from the three data-plane
## layers (immutable facts + txstate + the trace overlay); nothing is computed
## in the page.
##
## Sections rendered here (the M5 skeleton subset): hero with the Debug
## affordance whose behaviour follows `trace.availability`; the overview grid;
## decoded-input summary; the per-execution trace list (the Aztec private/public
## split renders honestly — `absent` with its reason, never a failed fetch); and
## the raw chain-native payload. Deferred sections (events/logs, internal calls,
## state changes, and the full CodeTracer debugger embed) are shown as honest
## stubs, matching the spec's degraded-state copy.

import std/json
import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/tables

proc txPage*(chain: string, v: TxView): string =
  let headline = v.headline
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

        # ── Debug affordance (follows trace.availability) ─────
        tdiv(class = "debugcard group"):
          tdiv(class = "row"):
            case headline
            of taReady, taDivergent:
              a(class = "btn primary", href = txUrl(chain, v.hash) & "/debug"):
                text availabilityLabel(headline)
            of taOnDemand:
              button(class = "btn primary"): text availabilityLabel(headline)
            of taAbsent, taUnsupported:
              button(class = "btn disabled"): text availabilityLabel(headline)
            span(class = "badge coverage " & availabilityClass(headline)):
              text availabilityState(headline)
          p(class = "note"): text availabilityNote(headline)
          # Page-Descriptions §7.2 puts this line BESIDE the Debug action that
          # requests it. VD.2's round 2 measured it ~1000px below the button, in
          # a different section: proximity was grouping the explanation with the
          # wrong thing. Rounds 1-4 are not recorded in reviews/ledger.json, so
          # that measurement has no citable id; the round-5 findings on the same
          # separation are ledger@2026-08-29.1:tx-detail/wide/light/L2/3 and
          # ledger@2026-08-29.1:tx-detail/wide/light/L5/6.
          p(class = "note spec"):
            text "Internal calls and state changes come from the execution trace."
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
        # Rendered from `viewutil.txMetadataRows`, which is ALSO what the
        # debugger's metadata pane renders (Page-Descriptions §7.1: the two
        # surfaces render "from one source", and "the two cannot be allowed to
        # diverge"). This loop knows how to present a row; it does not know
        # which rows a transaction has, so it cannot grow a fact the pane
        # lacks — and the pane cannot grow one this page lacks.
        h2(class = "sec-title next"): text "Overview"
        dl(class = "dl"):
          for r in txMetadataRows(chain, v):
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

        # ── Decoded input ─────────────────────────────────────
        h2(class = "sec-title next"): text "Decoded input"
        dl(class = "dl"):
          dt: text "Selector"
          dd:
            if v.payloadSelector.len > 0:
              span(class = "identifier"): text v.payloadSelector
            else:
              span(class = "muted"): text "—"
          dt: text "Raw"
          dd:
            span(class = "identifier"): text (if v.payloadRaw.len > 0: v.payloadRaw else: "0x")
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            text "This selector is not in any ABI BlockTracer holds, so the "
            text "parameters are shown as raw bytes. Supplying an ABI decodes them."

        # ── Deferred trace-derived sections ───────────────────
        h2(class = "sec-title next"): text "Events"
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            text "Events come from the transaction receipt, not from a trace. "
            text "They appear here once this chain's receipts are published."

        h2(class = "sec-title sibling"): text "Internal calls"
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            text "Internal calls come from the execution trace. They appear here "
            text "once this transaction has a recorded trace."

        h2(class = "sec-title sibling"): text "State changes"
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            text "State changes come from the execution trace. They appear here "
            text "once this transaction has a recorded trace."

        # ── Raw native payload ────────────────────────────────
        if v.native != nil and v.native.kind != JNull:
          h2(class = "sec-title next"): text "Raw (chain-native)"
          pre(class = "raw"): text pretty(v.native)
