# debugger · wide · dark — L5 (brand and register consistency)

Expected elements: MISSING — the identity bar's link back to the transaction detail page

The bar's only outbound link is `← aztec` (x≈28–74, y=31), which names the chain; `client/src/pages/debug.nim` confirms it targets `chainUrl`. The hash `0xb63616…6359` beside it is plain white monospace, while this page's link vocabulary is periwinkle-and-underlined (`← aztec`, `101:0`, `Sort by cost`), so the hash is not interactive. Page-Descriptions §8 still requires "a link back to the detail page", and §7.0 keeps `/{chain}/tx/{hash}` a distinct address — "they differ in what the visitor asked for" — so the source comment's "self-link" rationale does not hold. Finding #1, P1, rating capped at 4. Unchanged from round 4.

Round 4's other register P1 is fixed: the listing now carries CodeTracer editor tokens and the pane is titled CODE. The surface is otherwise convincingly product-register — dark, dense, full-viewport, named phases rather than a spinner, no explorer footer, no page scrollbar.

What remains is voice. `Status reason: private-part-succeeded-public-part-succeeded` (Transaction pane, row 3) ships a state-machine symbol as prose. The CODE pane's opening sentence, "Showing from line 26 — the session's position is below…", is explorer-register narration re-grown one level below the band §8 removed on 2026-08-29. And the bar's loudest object is the filled `Download trace` pill, while stepping — the product's premise — is eight unlabelled transport glyphs.

Fixes: (1) make the hash the link to `/aztec/tx/0xb636…`; (2) replace the raw status enum and the CODE pane sentence with tool-register treatments.

Rating: 4/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L5",
  "expectedElements": "missing",
  "missing": [
    "Identity bar: a link back to the transaction detail page. The only link is '← aztec', which is labelled with the chain and routes to the chain overview; the truncated hash '0xb63616…6359' carries none of this page's link treatment (periwinkle + underline)."
  ],
  "rating": 4,
  "findings": [
    {
      "id": "debugger/wide/dark/L5/1",
      "severity": "P1",
      "location": "identity bar, far left (x≈28–160, y=31)",
      "finding": "No link back to the transaction detail page. The bar's only navigational affordance is '← aztec', styled as a link and labelled with the chain, so it reads and behaves as 'back to the aztec chain'. The truncated hash beside it is plain white monospace while every real link on the page (← aztec, 101:0, Sort by cost) is periwinkle and underlined, so by the page's own vocabulary the hash is inert. The debug route is a deliberate register crossing and the way back across it — to /aztec/tx/0xb636…, which Page-Descriptions §7.0 keeps as a distinct address — is not rendered. The implementation's comment argues the link had become a self-link; §7.0 says the two addresses 'differ in what the visitor asked for', and the non-debug one is the crawlable, canonical, explorer-register surface, so it is not a self-link. Carried unresolved from round 4."
    },
    {
      "id": "debugger/wide/dark/L5/2",
      "severity": "P2",
      "location": "Transaction pane, third row, beneath the full hash",
      "finding": "'Status reason: private-part-succeeded-public-part-succeeded' ships a raw enum identifier as user-facing prose in the flagship pane. Every other string on this surface is product English; this one is a serialised symbol, hyphen-joined and wrapped over two lines. The debugger register is dense, not internal — a CodeTracer user reads the tool's language, not its state machine's. Render it as the two facts it encodes (private part succeeded, public part succeeded), ideally as the same badge pair already used two rows below for 'Not observable' and 'Trace ready'.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/3",
      "severity": "P2",
      "location": "CODE pane, full-width row beneath the file tab strip (y≈139)",
      "finding": "'Showing from line 26 — the session's position is below, and the lines above it are not in this window.' is explorer-register narration inside the densest pane of the tool register. It is a chatty sentence in the body voice, in a pane whose every other row is a gutter number and a token. The desktop app expresses a windowed listing structurally — an elision marker in the gutter, a dimmed rule at the window edge — not with a sentence explaining it. It is also the same species of furniture as the full-width loading band §8 removed on 2026-08-29, re-grown one level down: prose elsewhere on the page explaining a condition the object itself should draw.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/4",
      "severity": "P2",
      "location": "identity bar, right group (Share / Download trace, x≈1720–1910)",
      "finding": "The loudest object in the bar is the solid light-filled 'Download trace' pill — the explorer register's primary-CTA treatment, and the only filled button on the surface — given to a file download. The product's stated premise, reverse stepping, is eight small unlabelled glyphs at 40% of that contrast. The bar's emphasis therefore ranks a utility action above the controls the spec deliberately moved here to keep permanently on screen, which inverts the ranking that move was made to express.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L5/5",
      "severity": "P2",
      "location": "identity bar, control group (x≈395–670)",
      "finding": "The stepping controls speak a media-transport vocabulary (◀ ▶, ⏮ ⏭) plus four ambiguous arrow glyphs, with no labels, no keyboard hints and no textual anchor. Reverse stepping is present as the spec demands, but a CodeTracer desktop user cannot map this row onto the named commands they already know — nothing distinguishes 'step back over' from 'step out'. B9 asks for the same control vocabulary as the desktop app; this is a video player's. Placement is a sanctioned divergence and is not the issue; the iconography is.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/6",
      "severity": "P2",
      "location": "Transaction pane, rows CANONICAL / FINALITY / EXECUTIONS (y≈235–545)",
      "finding": "One badge primitive carries five different kinds of meaning within a single pane: an outcome (orange 'Partial'), a boolean ('Yes' for CANONICAL), a classification ('Safe' for FINALITY), an observability state ('Not observable'), and a readiness state (green 'Trace ready'). 'Yes' is the weakest — a plain boolean promoted into a chip while the rows above and below it render bare values right-aligned, so the badge stops signalling 'this is a status' and becomes decoration. Reserve the pill for status and let booleans be values.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/7",
      "severity": "P3",
      "location": "CALL TRACE pane — column header row (y≈135) and footer row (y≈338)",
      "finding": "Three casing conventions in one pane: the pane and column labels are uppercase micro-labels ('CALL TRACE', 'FRAME'), the adjacent column header mixes an uppercase acronym with a lowercase word ('ACIR opcodes'), and the footer is sentence case with a terminal full stop ('Sorted by call order.') beside a sentence-case link ('Sort by cost'). Pick one voice for pane chrome; the uppercase micro-label is the one the rest of the surface uses.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/8",
      "severity": "P3",
      "location": "whole workspace — gutters between CODE, CALL TRACE/VALUES and TRANSACTION columns",
      "finding": "The session is built as separated rounded cards floating on a page background rather than as the contiguous, gutter-less workspace split by sashes that is the desktop app's pane vocabulary. The idiom reads as a web dashboard. It is defensible at 1920 and the pane headers are consistent, but VD.5 exists to record divergences from the desktop app and this is the structural one; it should be a deliberate, written-down choice rather than an inherited web default.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/9",
      "severity": "P3",
      "location": "identity bar, status group (x≈960–1490)",
      "finding": "One state is spoken in two voices side by side: 'Engine loading — 18 MB' in sentence case with an em dash, immediately followed by the uppercase phase rail 'FETCHING OPENING POSITIONING'. Both are honest and both are wanted, but adjacent objects describing the same thing in different registers read as two unrelated widgets rather than one status. Fold the size into the active phase chip, or set the two in one voice.",
      "criterion": "B9"
    }
  ]
}
```
