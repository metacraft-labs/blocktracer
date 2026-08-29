## Small presentation helpers shared by the explorer components and pages:
## hash truncation, clean-URL builders, and the label/CSS-class mapping for the
## two status vocabularies the views surface (transaction outcome and trace
## availability). These map the contract enums to human labels + a class the
## design-system-token CSS colours; they hold no data of their own.

import std/[json, strutils]
import blocktracer_client
import ./reader
import ./debugger/session_view

proc truncHash*(h: string, lead = 6, tail = 4): string =
  ## `0x27a6c250…9a6c` — a copyable middle-truncated hash for dense tables.
  if h.len <= lead + tail + 1: return h
  h[0 ..< lead] & "…" & h[h.len - tail ..< h.len]

# ── clean-URL route builders (mirror the exporter) ─────────────────────────

proc chainsUrl*(): string = "/chains"
proc chainUrl*(chain: string): string = "/" & chain
proc blocksUrl*(chain: string): string = "/" & chain & "/blocks"
proc blocksFromUrl*(chain: string, height: int): string =
  ## §5.1's backwards-walking cursor, in the URL. The cursor is a block NUMBER,
  ## so the page is addressable and needs no server — and, unlike `?page=2`, it
  ## does not shift when the chain grows.
  "/" & chain & "/blocks/from/" & $height
proc blockUrl*(chain, hash: string): string = "/" & chain & "/block/" & hash
proc txsUrl*(chain: string): string = "/" & chain & "/txs"
proc txsFromUrl*(chain: string, height: int): string =
  "/" & chain & "/txs/from/" & $height
proc txUrl*(chain, hash: string): string = "/" & chain & "/tx/" & hash
proc debugUrl*(chain, hash: string): string =
  "/" & chain & "/tx/" & hash & "/debug"
proc addressUrl*(chain, address: string): string =
  "/" & chain & "/address/" & address
proc addressSegmentUrl*(chain, address, segment: string): string =
  ## One block-range page of an address's history (§2.2). The segment id IS the
  ## range, for the reason `reader.segmentId` states.
  "/" & chain & "/address/" & address & "/seg/" & segment
proc addressCodeUrl*(chain, address: string): string =
  "/" & chain & "/address/" & address & "/code"
proc searchUrl*(): string = "/search"
proc settingsUrl*(): string = "/settings"
proc aboutUrl*(): string = "/about"

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

func offersDebugAction*(a: TraceAvailability): bool =
  ## Whether the shared transactions table's first column carries an ACTION for
  ## this row, or a stated reason instead.
  ##
  ## §6 column 1: "Instant when the overlay's `trace.availability` is `ready`;
  ## on an on-demand chain the pipeline generates it first; **absent with a
  ## stated reason** when `unsupported`." So the last two rows get no control at
  ## all — not even a disabled one. `pages/tx.nim` makes the same decision for
  ## the same reason and says why: a greyed control still occupies the position
  ## of the primary action and still invites the click it will refuse.
  case a
  of taReady, taDivergent, taOnDemand: true
  of taAbsent, taUnsupported: false

func debugActionClass*(a: TraceAvailability): string =
  ## Weight of the row's Debug affordance. `ready` and `divergent` land IN the
  ## session (§7.0), so they carry the primary weight; `onDemand` asks the
  ## pipeline for one, which is a different and lesser promise.
  case a
  of taReady, taDivergent: "btn sm primary"
  of taOnDemand: "btn sm ghost"
  of taAbsent, taUnsupported: ""

func costLabel*(c: Cost): string =
  ## One dimension of §2.3's cost VECTOR, spelled the chain's own way.
  result = c.used
  if c.limit.len > 0: result.add " / " & c.limit
  if c.unit.len > 0: result.add " " & c.unit

proc feeLabel*(cost: seq[Cost]): string =
  ## The table's fee cell. Every dimension, joined — never the first one alone,
  ## because a chain whose cost has two dimensions has a fee this product would
  ## otherwise under-report by exactly one of them.
  var parts: seq[string]
  for c in cost: parts.add costLabel(c)
  parts.join(" · ")

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

func blockFinality*(info: ChainInfo, height: int): string =
  ## A block's finality, from the ONE mutable pointer every page already reads.
  ##
  ## Two values and not three. `current.json` carries the canonical tip and the
  ## finalized height and nothing between them (§3.3: "it carries the current
  ## generation, the canonical tip and the finalized height — and nothing else,
  ## so it stays small and hot"), so a chain's intermediate `safe` rung has no
  ## published source here. Rendering one would be a badge asserting a
  ## distinction the data plane does not make.
  if info.finalizedHeight > 0 and height <= info.finalizedHeight: "finalized"
  else: "unfinalized"

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

const UnknownSelectorNote* =
  "This selector is not in any ABI BlockTracer holds, so the parameters are " &
  "shown as raw bytes. Supplying an ABI decodes them."
  ## §7.2 section 3's degraded copy. A constant rather than a literal in a
  ## view, for the same reason `txMetadataRows` is a proc: the transaction
  ## route now lands in the SESSION for a published trace, so this sentence is
  ## rendered by the metadata pane too and two spellings of it would be two
  ## answers to the same question.

proc txPayloadRows*(v: TxView): seq[MetaRow] =
  ## §7.2 section 3's decoded input, as rows.
  ##
  ## The same shape as `txMetadataRows` and for the same reason: §7.1 requires
  ## the pre-rendered page and the metadata pane to render the transaction's
  ## facts "from one source". The selector and the raw calldata are facts, so
  ## they get one producer rather than a hand-written `<dl>` per surface.
  result.add MetaRow(label: "Selector",
                     value: (if v.payloadSelector.len > 0: v.payloadSelector
                             else: "—"),
                     identifier: v.payloadSelector.len > 0)
  result.add MetaRow(label: "Raw",
                     value: (if v.payloadRaw.len > 0: v.payloadRaw else: "0x"),
                     identifier: true)

proc txNativePayload*(v: TxView): string =
  ## §7.2 section 8 — the chain-native payload, verbatim and pretty-printed.
  ##
  ## Empty when the tree published none, which is a different thing from an
  ## empty object and is rendered as nothing at all rather than as `null`.
  if v.native == nil or v.native.kind == JNull: "" else: pretty(v.native)

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
