# debugger · wide · dark · L2 (layout, alignment and spacing)

Expected elements: present

All nine must-show items are on the image: slim 63 px identity bar (chain, truncated hash, `Partial`, block), dark product surface, panes filling y=120–1075 with no footer and no page scrollbar, current line 32 highlighted with a gutter marker, seven call-trace frames, ten state values, eight stepping controls including reverse, a scrubber, and the TRANSACTION pane. No spinner, no empty pane, no light chrome.

Detail alignment is genuinely good — 8 px inner padding on all four panes, 4 px gutters, numeric columns right-aligned to their headers (call trace at x=1518, matching `opcodes`), 25–26 px row rhythm, everything vertically centred to ±1 px in the identity bar and control row. The failures are all at the level above: how the space was divided.

The worst is proportion. TRANSACTION's last text is at y=582 in a pane that runs to y=1075 — 493 px, 52 %, empty — while the EDITOR pane is width-starved and fades lines 40 and 53 out mid-identifier at x≈916. Call trace wastes another 166 px, state 138 px. Then the spacing scale: every gap on the page is 4 px except the call-trace/state gap (y=635–662), which is 28 px. The identity bar's content is inset 24 px; the pane grid is inset 4 px, so nothing below aligns with the bar above.

Fixes: rebalance the three columns to content, and settle on one gutter value.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "reviewer": "L2",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/dark/L2/1",
      "severity": "P2",
      "location": "TRANSACTION pane (x 1533–1915) vs EDITOR pane (x 4–916)",
      "finding": "The column split starves the pane that needs width and over-feeds the one that does not. TRANSACTION's last text sits at y=582 inside a pane that runs to y=1075 — 493 px of empty pane, 52% of its height — while the source pane is narrow enough that lines 40 and 53 fade out mid-identifier at x≈916 ('shield_regen_perce…', 'damage: Field, r…'). Code area is 786 px ≈ 92 monospace columns; those lines need ~100. Roughly 100 px moved from the metadata column to the source pane would fix both.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L2/2",
      "severity": "P2",
      "location": "gap between CALL TRACE and STATE panes, y=635–662",
      "finding": "This gap is 28 px. Every other gap on the page — outer margins, the strip above the panes (y 116–119), controls-to-panes (y 217–220), and both column gutters (x 917–920, x 1529–1532) — is 4 px. One column is spaced on a different scale from the rest of the layout, and at 7× the page's unit it reads as an accidental margin rather than a decision.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L2/3",
      "severity": "P2",
      "location": "identity bar (y 0–62) against the pane grid below",
      "finding": "The identity bar insets its content 24 px on both sides (left edge of '← aztec' at x=24, right edge of 'Download trace' at x=1895). The pane grid below insets 4 px (borders at x=4 and x=1915). Nothing in the session aligns with the bar that names it: the bar's hash sits 20 px inside the left edge of the panel column, and its buttons 20 px inside the right. Either the bar should adopt the 4 px page margin or the panes should adopt the 24 px one.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L2/4",
      "severity": "P2",
      "location": "phase banner, y 64–114",
      "finding": "The explanatory sentence is forced to wrap to two lines inside x=24–618 while 597 px of the strip (x=1323–1920, 31% of its width) sits empty. The phase-chip group's right edge at x=1323 lands on no vertical anywhere in the layout — not the identity bar's 1895, not the debug-controls panel's 1528, not the page edge — so the void reads as a missing third element rather than as deliberate space.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L2/5",
      "severity": "P2",
      "location": "DEBUG CONTROLS, stepping-button cluster, x=17–269",
      "finding": "Eight controls in one flat run with identical 3 px gaps throughout, so proximity conveys no grouping — reverse/forward, step out/in, and the jump controls are indistinguishable as pairs. The boxes are also four different widths: 29, 29, 27, 26, 32, 32, 32, 32 px (all 28 px tall), so the buttons are sized to their glyphs rather than to one control size, and the two most important controls are not the largest.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L2/6",
      "severity": "P3",
      "location": "EDITOR pane, y 221–300",
      "finding": "Three left edges in the pane's first 80 px: the 'EDITOR' header label at x=13, the file-tab strip at x=22, the 'Showing from line 26…' notice back at x=13. The tabs are plain text with an underline and carry no box that would justify the 9 px offset.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L2/7",
      "severity": "P3",
      "location": "CALL TRACE pane, frame rows y 273–448",
      "finding": "The indent unit is not constant: main at x=932, depth 1 at x=954 (22 px), depth 2 at x=970 (16 px), depth 3 at x=986 (16 px). Separately, every nested row draws exactly one guide rule, always at x=936, so at depth 3 there is 50 px of blank indent with a single rule at the far left and depth is carried by whitespace alone.",
      "criterion": "B6"
    },
    {
      "id": "debugger/wide/dark/L2/8",
      "severity": "P3",
      "location": "STATE pane, first value row (separators at y=690 and y=719)",
      "finding": "The 'initial_shield' row is 29 px tall; every row after it is 25–26 px (separators at 719, 744, 769, 795, 820, 845, 870, 895, 921, 946). The extra 3–4 px on the first row breaks the column's rhythm at exactly the point the eye enters it.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L2/9",
      "severity": "P3",
      "location": "DEBUG CONTROLS row, x 286–1515",
      "finding": "Space allocation in the row is inverted: the scrubber gets 556 px (x 286–842, 36% of the bar) while the sentence 'Step 128 of 1315 — …' takes 558 px (x 859–1417) and the '128 / 1315' counter (x 1430–1515) sits only 13 px from it. At that separation the counter and the sentence read as one run rather than as a label and a readout, and the timeline — the element that expresses position — is the narrowest thing in the row.",
      "criterion": "B4"
    }
  ]
}
```
