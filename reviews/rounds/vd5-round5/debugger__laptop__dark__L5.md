Expected elements: present

All must-show items are on the page: a slim identity bar with hash, chain link, `Partial` badge, both stepping directions, scrubber, `128 / 1315` readout and the FETCHING/OPENING/POSITIONING rail; Code with line 32 marked; Call Trace and Event Log as one tab strip with Call Trace open; Values below it as a pane, not a third tab; a metadata column. No spinner, no light chrome, no full-width band above the panes. The second bar row is the bar wrapping — the block's own Watch-for anticipates it — so I judged it, not failed it.

The texture is convincingly CodeTracer: mono throughout, file tabs, ACIR opcode column, editor-palette highlighting. The copy is where the register slips.

P1 — Transaction pane, Decoded input: `SELECTOR 0x`, `RAW 0x`, then "This selector is not in any ABI BlockTracer holds, so the parameters are shown as raw bytes." No selector exists and no bytes are shown; the note is unconditional in `demo_session.nim:306`. EVM vocabulary on a Noir transaction, asserting a lookup that never happened.

P2 — the wrapped bar row (NOIR/Share/Download trace, 25–490 px, 950 px of empty strip right of it) reads as explorer toolbar chrome; `Status reason: private-part-succeeded-public-part-succeeded` is an unframed enum slug wrapping mid-token; the Code pane narrates its own scroll position in two prose lines; `Sort by cost` is a navigation hyperlink doing a sort.

Fixes: gate the ABI note on state; move the two actions onto row 1's right.

Rating: 4/10

```json
{
  "view": "debugger",
  "size": "laptop",
  "theme": "dark",
  "image": "screenshots/debugger__laptop__dark.png",
  "reviewer": "L5",
  "expectedElements": "present",
  "missing": [],
  "rating": 4,
  "findings": [
    {
      "id": "debugger/laptop/dark/L5/1",
      "severity": "P1",
      "location": "Transaction pane, DECODED INPUT block (right column, y 665-830)",
      "finding": "The pane shows SELECTOR `0x` and RAW `0x`, then the note 'This selector is not in any ABI BlockTracer holds, so the parameters are shown as raw bytes. Supplying an ABI decodes them.' There is no selector to look up and no raw bytes on screen, so the copy describes a different state than the one rendered. The note is not conditional: `payloadNote: UnknownSelectorNote` is set unguarded in client/src/debugger/demo_session.nim:306, so it will also claim an ABI miss for a transaction whose selector IS decoded. Compounding it, Selector/Raw/ABI is EVM vocabulary rendered against an Aztec/Noir transaction whose Code pane shows .nr files and whose call trace counts ACIR opcodes, so one viewport carries two chain vocabularies. Gate the note on an actual unknown-selector state and say 'no calldata' when the payload is empty.",
      "criterion": "B8"
    },
    {
      "id": "debugger/laptop/dark/L5/2",
      "severity": "P2",
      "location": "identity bar, second row (y 45-88): NOIR, Share, Download trace",
      "finding": "At 1440 the bar wraps and the two actions plus the NOIR tag land alone on a full-width second row spanning only x 25-490, leaving ~950 px of empty strip to their right. The result reads as a separate explorer-style toolbar row sitting under the identity bar rather than as one wrapped object: the actions end up closer to the Code pane's title than to the hash they act on, and the bar's total height doubles to 88 px in the register where the header is meant to be slim and continuous with the desktop app. Right-align Share and Download trace on row 1, or push them to the right edge of row 2 so the group still terminates the bar.",
      "criterion": "B9"
    },
    {
      "id": "debugger/laptop/dark/L5/3",
      "severity": "P2",
      "location": "Transaction pane, 'Status reason:' line under the full hash (y 195-230)",
      "finding": "The chain's enum slug is printed as sentence copy — 'Status reason: private-part-succeeded-public-part-succeeded' — and wraps mid-token across two lines ('private-part-' / 'succeeded-public-part-succeeded'). Everywhere else this pane either writes designed sentences ('aztec private function executed client-side; only proofs, nullifiers and commitments are published') or explicitly frames machine text as machine text ('RAW (CHAIN-NATIVE)'). An unframed machine identifier delivered in the product's copy voice reads as a leaked debug string. Split it into the two facts it encodes (private: succeeded, public: succeeded), or label it chain-native and set it in mono so the register is declared.",
      "criterion": "B9"
    },
    {
      "id": "debugger/laptop/dark/L5/4",
      "severity": "P2",
      "location": "Code pane, notice between the file tabs and line 26 (y 150-185)",
      "finding": "'Showing from line 26 — the session's position is below, and the lines above it are not in this window.' is two lines of explanatory prose narrating the pane's own scroll position, in the explorer register's teaching voice, inside the pane where density is the virtue. The gutter already says line 26 and the marker on line 32 already says where the position is, so the sentence buys no comprehension and costs two code rows. The MUST-NOT-SHOW list records that a paragraph restating engine state above the panes was removed on 2026-08-29; this is the same instinct relocated one level down into a pane. Drop it, or reduce it to a scroll affordance on the gutter.",
      "criterion": "B1"
    },
    {
      "id": "debugger/laptop/dark/L5/5",
      "severity": "P2",
      "location": "Call Trace pane footer, 'Sort by cost' (right of 'Sorted by call order.', y 350-365)",
      "finding": "The sort toggle is drawn as an underlined blue text hyperlink — the identical primitive to the '← aztec' navigation link in the identity bar and the '101:0' block link in the Transaction pane. One primitive is therefore doing three jobs: leave the page, go to a block, and re-order a pane in place. A hyperlink that does not navigate is an explorer-register import; the desktop app expresses sort order as a control on the column header or a segmented toggle. Make it a control (a toggle on the 'ACIR opcodes' header, or a two-state segment beside 'Sorted by call order.') and reserve the underlined-link treatment for navigation.",
      "criterion": "B9"
    },
    {
      "id": "debugger/laptop/dark/L5/6",
      "severity": "P3",
      "location": "Transaction pane, badge column (Partial, Yes, Safe, Not observable, Trace ready; y 120-650)",
      "finding": "One pill primitive appears in three treatments within a 292 px column — amber outline (Partial), neutral outline (Yes, Safe, Not observable), green outline (Trace ready) — while the adjacent BLOCK row renders its value as an underlined link instead. Nothing distinguishes the pills that carry a status from the pills that are simply facts: CANONICAL 'Yes' and FINALITY 'Safe' are plain values wearing status chrome, which dilutes the badge as a signal by the time the eye reaches 'Trace ready'. Reserve the pill for status and render canonicality and finality as plain right-aligned values like FEE PAYER and TARGET.",
      "criterion": "B9"
    },
    {
      "id": "debugger/laptop/dark/L5/7",
      "severity": "P3",
      "location": "identity bar second row, 'NOIR' label at x 25-90",
      "finding": "The trace language is set as dim uppercase mono immediately left of two outlined pill buttons of the same cap height and vertical centre, so it reads as a third, disabled button rather than as metadata. It is the only item in the bar that is a fact rather than an action, and it is grouped with the actions. Move it next to the file tabs in the Code pane, where the language describes what is being shown, or into the identity group on row 1 beside 'block 101'.",
      "criterion": "B9"
    }
  ]
}
```
