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
        tdiv(style = "display:flex;gap:12px;align-items:center;flex-wrap:wrap"):
          h1(class = "h2"): text "Transaction"
          raw outcomeBadge(v.outcome)
        p(class = "lead", style = "font-family:var(--ct-font-mono);font-size:var(--ct-text-sm)"):
          text v.hash
        if v.outcomeReason.len > 0:
          p(class = "muted"): text "Revert reason: " & v.outcomeReason

        # ── Debug affordance (follows trace.availability) ─────
        tdiv(class = "debugcard"):
          tdiv(class = "row"):
            case headline
            of taReady, taDivergent:
              a(class = "btn primary", href = txUrl(chain, v.hash) & "/debug"):
                text availabilityLabel(headline)
            of taOnDemand:
              button(class = "btn ghost"): text availabilityLabel(headline)
            of taAbsent, taUnsupported:
              button(class = "btn disabled"): text availabilityLabel(headline)
            span(class = "badge " & availabilityClass(headline)):
              text $headline
          p(class = "note"): text availabilityNote(headline)
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
        tdiv(class = "eyebrow", style = "margin-top:var(--ct-space-2xl)"):
          text "Overview"
        dl(class = "dl"):
          dt: text "Block"
          dd:
            a(href = blockUrl(chain, v.blockHash)):
              text $v.height & " : " & $v.index
          dt: text "Canonical"
          dd: text $v.canonical
          dt: text "Finality"
          dd: text v.finality
          for role in v.roles:
            dt: text role.role
            dd:
              code: text role.address
          if v.payloadTarget.len > 0:
            dt: text "Target"
            dd:
              code: text v.payloadTarget
          for c in v.cost:
            dt: text "Cost · " & c.name
            dd:
              text c.used & " / " & c.limit & " " & c.unit
              if c.token.len > 0:
                span(class = "muted"): text "  (" & c.token & ")"

        # ── Decoded input ─────────────────────────────────────
        tdiv(class = "eyebrow", style = "margin-top:var(--ct-space-2xl)"):
          text "Decoded input"
        dl(class = "dl"):
          dt: text "Selector"
          dd:
            if v.payloadSelector.len > 0:
              code: text v.payloadSelector
            else:
              span(class = "muted"): text "—"
          dt: text "Raw"
          dd:
            code: text (if v.payloadRaw.len > 0: v.payloadRaw else: "0x")
        tdiv(class = "stub"):
          b: text "Deferred: "
          text "ABI-decoded parameters. Unknown selectors show raw bytes with a "
          text "\"supply an ABI\" action in the full explorer."

        # ── Deferred trace-derived sections ───────────────────
        tdiv(class = "eyebrow", style = "margin-top:var(--ct-space-2xl)"):
          text "Events · internal calls · state changes"
        tdiv(class = "stub"):
          text "Internal calls and state changes come from the execution trace. "
          b: text "Deferred: "
          text "these render once the CodeTracer replay embed lands (M5/M9 — the "
          text "WASM replay + ViewModels are a later slice)."

        # ── Raw native payload ────────────────────────────────
        if v.native != nil and v.native.kind != JNull:
          tdiv(class = "eyebrow", style = "margin-top:var(--ct-space-2xl)"):
            text "Raw (chain-native)"
          pre(class = "raw"): text pretty(v.native)
