## Small presentation helpers shared by the explorer components and pages:
## hash truncation, clean-URL builders, and the label/CSS-class mapping for the
## two status vocabularies the views surface (transaction outcome and trace
## availability). These map the contract enums to human labels + a class the
## design-system-token CSS colours; they hold no data of their own.

import blocktracer_client
import ./reader
import ./debugger/session_view

proc truncHash*(h: string, lead = 6, tail = 4): string =
  ## `0x27a6c250…9a6c` — a copyable middle-truncated hash for dense tables.
  if h.len <= lead + tail + 1: return h
  h[0 ..< lead] & "…" & h[h.len - tail ..< h.len]

# ── clean-URL route builders (mirror the exporter) ─────────────────────────

proc chainUrl*(chain: string): string = "/" & chain
proc blocksUrl*(chain: string): string = "/" & chain & "/blocks"
proc blockUrl*(chain, hash: string): string = "/" & chain & "/block/" & hash
proc txUrl*(chain, hash: string): string = "/" & chain & "/tx/" & hash

# ── outcome ────────────────────────────────────────────────────────────────

proc outcomeLabel*(o: OutcomeOverall): string =
  case o
  of ooSucceeded: "Succeeded"
  of ooReverted: "Reverted"
  of ooPartial: "Partial"
  of ooFailedWithEffects: "Failed (with effects)"

proc outcomeClass*(o: OutcomeOverall): string =
  ## CSS modifier → a semantic design-system status colour.
  case o
  of ooSucceeded: "ok"
  of ooReverted, ooFailedWithEffects: "bad"
  of ooPartial: "warn"

# ── trace availability ─────────────────────────────────────────────────────

proc availabilityLabel*(a: TraceAvailability): string =
  case a
  of taReady: "Debug"
  of taOnDemand: "Generate trace"
  of taUnsupported: "No recorder"
  of taAbsent: "Not observable"
  of taDivergent: "Debug (divergent)"

proc availabilityClass*(a: TraceAvailability): string =
  case a
  of taReady: "ok"
  of taDivergent: "bad"
  of taOnDemand: "info"
  of taAbsent, taUnsupported: "muted"

proc availabilityState*(a: TraceAvailability): string =
  ## The badge beside the Debug action names the trace's STATE; the button
  ## names the ACTION. Previously the badge rendered the serialised enum
  ## (`onDemand`) — adapter vocabulary on an external-facing surface, and the
  ## same class of leak VD.1 removed from the deferred-section copy.
  case a
  of taReady: "Trace ready"
  of taOnDemand: "On demand"
  of taUnsupported: "No recorder"
  of taAbsent: "Not observable"
  of taDivergent: "Divergent"

proc roleLabel*(role: string): string =
  ## An adapter's role name → the label column's own vocabulary. The VD.1 round,
  ## and ledger@2026-08-29.1:tx-detail/wide/light/L5/7 — internal architecture
  ## leaking into visitor-facing copy: `feePayer` sat beside `Block`, `Canonical` and
  ## `Finality`, so one column carried two languages. Unknown roles fall through
  ## verbatim rather than being hidden — a new chain family must show up as an
  ## unstyled label to be noticed, not vanish.
  case role
  of "feePayer": "Fee payer"
  of "from", "sender": "From"
  of "to", "recipient": "To"
  of "signer": "Signer"
  of "proposer": "Proposer"
  of "relayer": "Relayer"
  else: role

proc outcomeReasonLabel*(o: OutcomeOverall): string =
  ## What to call `outcome.reason`.
  ##
  ## §7.2 asks for "status (with decoded revert reason if any)", and the label
  ## was `Revert reason:` unconditionally. On the demo's Aztec split
  ## transaction that renders "Revert reason: private-part-succeeded-public-
  ## part-succeeded" over a transaction in which nothing reverted — the label
  ## contradicting the value it introduces. The reason field is a status
  ## reason; only some statuses make it a revert.
  case o
  of ooReverted, ooFailedWithEffects: "Revert reason"
  of ooPartial, ooSucceeded: "Status reason"

proc outcomeReasonTone*(o: OutcomeOverall): string =
  ## How severe `outcome.reason` is — the colour half of `outcomeReasonLabel`.
  ##
  ## The two answer the same question and must not be able to disagree, which
  ## is why they are next to each other and read from the same `case`. Calling
  ## a reason a "Status reason" and then painting it in the danger colour is
  ## the label defect made again one layer down.
  case o
  of ooReverted, ooFailedWithEffects: "bad"
  of ooPartial, ooSucceeded: "note"

proc yesNo*(b: bool): string =
  ## A boolean fact in the explorer register reads as a word, not as a literal.
  if b: "Yes" else: "No"

proc sentenceCase*(s: string): string =
  ## An enum literal (`pending`, `finalized`) rendered as prose. Only the first
  ## letter moves; the rest is left alone so a hyphenated or camelCase value is
  ## still recognisably itself rather than silently rewritten.
  if s.len == 0: s
  else: (if s[0] in {'a'..'z'}: chr(ord(s[0]) - 32) else: s[0]) & s[1 .. ^1]

proc finalityClass*(finality: string): string =
  ## Finality is a status fact and gets the status vocabulary, so the page does
  ## not present three members of one family in three different primitives
  ## (VD.2 L3/7, L5/9).
  case finality
  of "finalized", "final", "irreversible": "ok"
  of "pending", "unconfirmed": "muted"
  of "reorged", "orphaned": "bad"
  else: "muted"

proc availabilityNote*(a: TraceAvailability): string =
  ## The one-line honest explanation the tx-detail hero shows beneath Debug.
  case a
  of taReady:
    "A recorded trace is published — Debug loads it immediately and anonymously."
  of taDivergent:
    "A trace exists but the differential oracle disagreed with the chain; it opens with a divergence banner."
  of taOnDemand:
    "No trace has been recorded for this transaction yet. Generating one replays the transaction on our side and publishes the result — it needs an account, and nothing is computed in your browser."
  of taAbsent:
    "Structurally unobservable — there is no call structure to trace, so this is absent by nature, not a failed fetch."
  of taUnsupported:
    "No recorder exists for this VM yet, so no trace can be produced."

# ── the transaction's facts, produced ONCE ─────────────────────────────────
#
# Page-Descriptions §7.1 puts the transaction's metadata inside the debugging
# session as a pane, and then states the constraint that makes that safe: the
# facts are "rendered in two places — the pre-rendered page and the metadata
# pane — **from one source**, and the two cannot be allowed to diverge."
#
# This is that source. `pages/tx.nim`'s overview grid and
# `components/debugger.nim`'s metadata pane both render the seq below and
# neither builds a row of its own, so a fact added here appears in both and a
# fact added to one of them appears in neither. M8b's
# `test_metadata_pane_and_page_cannot_diverge` drives exactly that: it mutates
# the underlying `TxView`, asserts both surfaces move, and asserts a
# hand-built second source fails.
#
# It lives in `viewutil` rather than in either view because a shared source
# owned by one of its two consumers is a source with a preferred consumer.

proc txMetadataRows*(chain: string, v: TxView): seq[MetaRow] =
  ## §7.2's overview facts, in spec order: block position, canonical, finality,
  ## the roles the adapter reported, the payload target, and the cost rows.
  ##
  ## Family-specific rows come from the adapter (`v.roles`, `v.cost`) and are
  ## emitted verbatim, so an EVM-shaped template cannot creep in: a Solana or
  ## Move transaction contributes whatever roles and cost dimensions it has.
  result.add MetaRow(label: "Block", value: $v.height & ":" & $v.index,
                     identifier: true, href: blockUrl(chain, v.blockHash))
  result.add MetaRow(label: "Canonical", value: yesNo(v.canonical),
                     badge: (if v.canonical: "muted" else: "bad"))
  result.add MetaRow(label: "Finality", value: sentenceCase(v.finality),
                     badge: finalityClass(v.finality))
  for role in v.roles:
    result.add MetaRow(label: roleLabel(role.role), value: role.address,
                       identifier: true)
  if v.payloadTarget.len > 0:
    result.add MetaRow(label: "Target", value: v.payloadTarget, identifier: true)
  for c in v.cost:
    var suffix = c.unit
    if c.token.len > 0: suffix.add " (" & c.token & ")"
    result.add MetaRow(label: "Cost · " & c.name,
                       value: c.used & " / " & c.limit,
                       suffix: suffix, identifier: true)

proc txExecutionRows*(v: TxView): seq[ExecutionRow] =
  ## The per-execution trace states — §7.1's "Aztec private/public split".
  ##
  ## Emitted for every transaction, including single-execution ones, because
  ## the pane is the only place a deep-linked visitor can see that the half
  ## they are NOT in is structurally absent. `pages/tx.nim` shows the list only
  ## when there is more than one execution, which is the right call for a page
  ## that already carries the headline affordance; the pane has no such
  ## headline.
  for e in v.executions:
    result.add ExecutionRow(
      selector: (if e.selector.len > 0: e.selector else: "execution"),
      availability: availabilityState(e.availability),
      reason: e.reason,
      badge: availabilityClass(e.availability))
