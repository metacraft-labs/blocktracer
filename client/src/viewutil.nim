## Small presentation helpers shared by the explorer components and pages:
## hash truncation, clean-URL builders, and the label/CSS-class mapping for the
## two status vocabularies the views surface (transaction outcome and trace
## availability). These map the contract enums to human labels + a class the
## design-system-token CSS colours; they hold no data of their own.

import blocktracer/contract/model

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
  of taOnDemand: "warn"
  of taAbsent, taUnsupported: "muted"

proc availabilityNote*(a: TraceAvailability): string =
  ## The one-line honest explanation the tx-detail hero shows beneath Debug.
  case a
  of taReady:
    "A recorded trace is published — Debug loads it immediately and anonymously."
  of taDivergent:
    "A trace exists but the differential oracle disagreed with the chain; it opens with a divergence banner."
  of taOnDemand:
    "No trace yet. Generating one runs the recorder in the pipeline (a signed-in job, not a page computation)."
  of taAbsent:
    "Structurally unobservable — there is no call structure to trace, so this is absent by nature, not a failed fetch."
  of taUnsupported:
    "No recorder exists for this VM yet, so no trace can be produced."
