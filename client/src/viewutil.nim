## Small presentation helpers shared by the explorer components and pages:
## hash truncation, clean-URL builders, and the label/CSS-class mapping for the
## two status vocabularies the views surface (transaction outcome and trace
## availability). These map the contract enums to human labels + a class the
## design-system-token CSS colours; they hold no data of their own.

import blocktracer_client

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
  ## and ledger@2026-08-28.3:tx-detail/wide/light/L5/7 — internal architecture
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
