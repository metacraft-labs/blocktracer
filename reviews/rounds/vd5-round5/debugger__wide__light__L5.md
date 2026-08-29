Expected elements: MISSING — a link back to the transaction detail page

Finding #1 is that absence and it is P1, so the rating is 4. The identity bar's only navigation is `← aztec`, which goes to the chain overview; the hash beside it is plain text with a copy affordance, not a link. Nothing on this surface returns to the transaction the session is debugging.

Every other MUST SHOW item is present, and the vocabulary is right: Code / Call Trace + Event Log / Values / Transaction, depth guides, a tabular ACIR column, and a phase rail that names phases instead of faking a percentage — a CodeTracer desktop user would recognise all of it.

The register slips are in the containers, not the content. All four panes are rounded, bordered cards on a grey canvas with a ~35 px gutter between the Code and Call Trace columns; the desktop app uses square, edge-to-edge panes with splitters. In the tabbed region ~330 px of its ~580 px height is blank below "Sorted by call order." — marketing whitespace in the primary navigation surface, while Code is the only region actually full. The Code pane's notice, "Showing from line 26 — the session's position is below…", is explanatory prose set in the code face, so it reads as an inserted source comment. DECODED INPUT shows `0x` for both SELECTOR and RAW while asserting "the parameters are shown as raw bytes" — there are none, and the stated cause is wrong.

Fix first: point the back link at the transaction page; correct the decoded-input copy.

Rating: 4/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "light",
  "image": "screenshots/debugger__wide__light.png",
  "reviewer": "L5",
  "expectedElements": "missing",
  "missing": ["A link back to the transaction detail page"],
  "rating": 4,
  "findings": [
    {
      "id": "debugger/wide/light/L5/1",
      "severity": "P1",
      "location": "identity bar, far left — the `← aztec` link beside the truncated hash",
      "finding": "The MUST SHOW 'link back to the transaction detail page' is absent. The bar's only link is `← aztec`, which targets the chain overview (client/src/pages/debug.nim:172, href = chainUrl(s.chain)), and the truncated hash next to it is a span with a copy affordance rather than an anchor. The debug route is a deliberate register crossing, so the way back across it must land on the transaction, not one level above it; as rendered the visitor leaves the debugger by leaving the transaction entirely."
    },
    {
      "id": "debugger/wide/light/L5/2",
      "severity": "P1",
      "location": "Transaction pane, DECODED INPUT — the SELECTOR and RAW rows and the sentence beneath them",
      "finding": "SELECTOR and RAW both render as the bare prefix `0x`, and the copy below states 'This selector is not in any ABI BlockTracer holds, so the parameters are shown as raw bytes. Supplying an ABI decodes them.' No raw bytes are shown — there are zero. An absent selector is presented as a value, and the reason given describes an unknown selector rather than a missing one, so a state is presented as a different state and the offered remedy (supply an ABI) cannot succeed. viewutil.nim:203-209 already has an em-dash convention for an absent selector, and demo_session.nim:306 attaches the note unconditionally.",
      "criterion": "B8"
    },
    {
      "id": "debugger/wide/light/L5/3",
      "severity": "P2",
      "location": "all four panes — most visibly the gutter between the Code and Call Trace columns (x≈900-920) and the seam between the tabbed region and Values (y≈672-685)",
      "finding": "Every pane is a rounded-corner, fully bordered card floating on a grey canvas with a wide gutter between cards. That is the explorer register's card primitive applied to the product register's flagship surface; the CodeTracer desktop app divides square, edge-to-edge panes with splitters and spends no canvas between them. The content and vocabulary read as the tool, the containers read as the marketing site, and the crossing does not look deliberate.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/light/L5/4",
      "severity": "P2",
      "location": "Call Trace / Event Log tabbed region, below the 'Sorted by call order.' footer (y≈342 to the card edge at y≈672)",
      "finding": "Roughly 330 px of the region's ~580 px height — about 57% — is blank white below the last frame, with the footer stranded at the top of it. The Values pane below is also ~29% empty (last row ends y≈958, card edge y≈1070), so Code is the only region carrying its allocation. This is explorer-register emptiness inside the debugger: the height belongs to whichever region has content, and at this fixture depth the navigation region does not need three fifths of the column.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/light/L5/5",
      "severity": "P2",
      "location": "Code pane, the notice row between the file tab strip and line 26",
      "finding": "'Showing from line 26 — the session's position is below, and the lines above it are not in this window.' is a full-width sentence set in the code face at the code's own size, directly above the listing, so it reads as an inserted source comment on line 25. Its voice is the explorer's — explaining the window to a first-time visitor — where the tool register states the fact (a line range in the header or gutter). It is the same tonal species as the engine-notice paragraph removed on 2026-08-29, relocated inside a pane.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/light/L5/6",
      "severity": "P2",
      "location": "identity bar, right of the scrubber — 'Engine loading — 18 MB' / '128 / 1315' / the phase rail / 'NOIR'",
      "finding": "The bar reads as a strip of unrelated objects rather than groups. The engine status and the position readout run together as one phrase with only a space between them, so '18 MB 128 / 1315' parses as a single quantity, although one is a download size and the other is where the session is standing. 'NOIR' then floats unlabelled between the phase rail and the Share button with no chrome of its own, adjacent to two bordered pill buttons. Group the session's state (status, readout, phase rail) and separate it from the page's actions.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/light/L5/7",
      "severity": "P2",
      "location": "Transaction pane, third line — 'Status reason: private-part-succeeded-public-part-succeeded'",
      "finding": "A raw chain enum slug is rendered as an English sentence in the body sans, wrapping to two lines across the pane's most valuable rows. It is the only row in the pane without an uppercase label in the left column, so it breaks the label/value grammar that BLOCK, CANONICAL and FINALITY establish immediately below it; and it reads 'succeeded … succeeded' directly under a warning-orange 'Partial' badge, leaving the reader to reconcile the two. Copy is a design property here, and a machine identifier set in prose voice belongs to neither register.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/light/L5/8",
      "severity": "P3",
      "location": "Transaction pane, the CANONICAL 'Yes', FINALITY 'Safe' and EXECUTIONS 'Not observable' values",
      "finding": "These non-interactive values are drawn as rounded, bordered pills identical in shape to the identity bar's actionable 'Share' and 'Download trace' buttons, while 'Trace ready' and 'Partial' use a separate tinted-badge treatment. Three chip shapes carry two meanings on one screen, and the one that means 'value' is the one that also means 'press me' 400 px away.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/light/L5/9",
      "severity": "P3",
      "location": "Call Trace pane footer, right edge — 'Sort by cost'",
      "finding": "An in-pane re-sort uses the blue underlined hyperlink primitive, which is the same treatment as the genuine navigation link '101:0' in the Transaction pane. One primitive for 'change this pane' and 'leave this page'. The desktop app expresses sort as a column-header affordance or a segmented toggle, which would also distinguish the two.",
      "criterion": "B9"
    }
  ]
}
```
