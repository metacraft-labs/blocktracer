Expected elements: present

All nine must-show items render: slim identity bar (hash, chain, `block 101`, back link), dark product surface, full-bleed session, source pane with line 32 marked by a caret and an indigo fill, a seven-frame call trace, an eleven-row state pane, bidirectional stepping controls, a scrubber reading `Step 128 of 1315`, and a TRANSACTION metadata pane. No spinner, no empty pane, no light chrome — loading is expressed as three named phases.

On my lens the surface is structurally correct and substantially under-filled. Row pitch in all three data panes is ~25 px for 12–13 px monospace — leading near 2.0. The EDITOR shows 33 lines in an 845 px pane where 1.5 leading would carry 43; CALL TRACE spends 176 px of a 400 px pane on seven frames. Meanwhile the TRANSACTION rail is empty below y≈600 — roughly 480 px, 45% of the tallest pane — while the source pane hard-clips lines 40 and 53 mid-identifier (`shield_regen_perce|`) at its right edge with no ellipsis, fade or scrollbar. The wrong thing was dropped. Source carries no syntax highlighting at all, so the densest region reads as one weight. The top 218 px (20% of the viewport) is chrome before any content.

Contrast is not the problem: measured pairs run 5.4:1 to 15.5:1, and numerics are tabular and right-aligned throughout.

Highest-priority fixes: tighten row pitch to ~1.5 and give the clipped source the rail's dead width; add the editor palette.

Rating: 5/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L4",
  "expectedElements": "present",
  "missing": [],
  "rating": 5,
  "findings": [
    {
      "id": "debugger/wide/dark/L4/1",
      "severity": "P2",
      "location": "EDITOR gutter lines 26-58; CALL TRACE frame rows; STATE value rows",
      "finding": "Row pitch is ~25 px for 12-13 px monospace in all three data panes (line-height ~1.9-2.0), which is marketing-page leading in the product register. The editor shows 33 source lines in an 845 px pane; at a 1.5 line-height the same pane carries 43. The call trace spends 176 px of a 400 px pane on seven frames. The single highest-yield density change in the view.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/2",
      "severity": "P2",
      "location": "EDITOR pane right edge (x=915) at lines 40 and 53",
      "finding": "Long lines are hard-clipped mid-identifier with no ellipsis, no fade and no visible horizontal scrollbar: line 40 ends 'shield_regen_perce|' and line 53 ends 'damage: Field, r|'. At 1920 the wrong content was dropped -- function signatures were cut while the 390 px TRANSACTION rail beside them sits ~45% empty. The source pane should absorb the slack width.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/3",
      "severity": "P2",
      "location": "TRANSACTION pane, below 'public / Trace ready' (y~600 to the viewport floor)",
      "finding": "Roughly 480 px of the layout's tallest pane -- about 45% of its height -- is empty on the widest viewport, and nothing was promoted into it: not the EVENT LOG that is hidden behind a tab in the STATE pane, not a cost or execution breakdown. Space is not being spent where it buys comprehension.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/4",
      "severity": "P2",
      "location": "EDITOR pane, all visible lines (26-58)",
      "finding": "The source has no syntax highlighting whatsoever: 'fn', 'let', 'as', 'u32', the f-string literal on line 54 and the comment on line 56 all render in one foreground colour. The densest content in the view is a monochrome wall, so its structure must be read rather than scanned, and the current-line highlight is the only differentiation in an 845 px pane.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L4/5",
      "severity": "P2",
      "location": "Top of viewport: identity bar (y 0-60), phase banner (y 60-118), DEBUG CONTROLS pane (y 118-218)",
      "finding": "218 px -- 20% of a 1080 px viewport -- is consumed by chrome before any pane content begins. The DEBUG CONTROLS pane is 100 px tall to hold one 24 px row of nine icon buttons plus a scrubber; its header label and padding cost more vertical space than the controls themselves. Roughly 60 px is recoverable without losing anything.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/6",
      "severity": "P2",
      "location": "DEBUG CONTROLS, scrubber track x=285-841, caption x=857-1454",
      "finding": "The trace scrubber gets 556 px to express 1315 steps while its own text caption gets ~600 px immediately to its right, in a pane 1520 px wide. The track is an undifferentiated dotted rule with no ticks, no frame boundaries and no event marks, so position is not readable to better than roughly plus or minus 30 steps without reading the numeral.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L4/7",
      "severity": "P2",
      "location": "Identity bar hash vs TRANSACTION pane FEE PAYER and TARGET rows",
      "finding": "Two truncation strategies for the same data type in one view. The identity bar ellipsis-truncates ('0xb63616...6359') while FEE PAYER and TARGET wrap mid-hex onto a right-aligned second line ('...e2a272b5' / 'e430d5d932'), so the continuation fragment reads as an orphaned second value rather than the tail of the one above, and each row costs two lines.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L4/8",
      "severity": "P2",
      "location": "Identity bar, left edge",
      "finding": "The only link affordance in the identity bar is '<- aztec', labelled with the chain slug; the truncated transaction hash beside it is plain white with no underline or accent. The route back to the transaction detail page is therefore not visible as such -- the visible back-affordance reads as 'back to the chain'.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L4/9",
      "severity": "P3",
      "location": "DEBUG CONTROLS, button group x=20-265",
      "finding": "Nine stepping controls render as unlabelled ~24 px glyph buttons with no keyboard hints. The two arrow pairs (play/reverse, and step-in/step-out) are distinguishable only by glyph direction at that size, so the reverse-stepping control -- the product's premise -- is present but not identifiable at a glance.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L4/10",
      "severity": "P3",
      "location": "STATE pane tab strip, 'EVENT LOG' at x~1016",
      "finding": "The event log is behind a tab while ~480 px of the adjacent TRANSACTION rail is empty. At 1080 px of height with that much slack, tabbing rather than stacking hides a whole information class the viewport had room for.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/11",
      "severity": "P3",
      "location": "STATE pane, 'remaining_shield' (9000) and 'damage' (2000) rows",
      "finding": "Changed values are marked by hue alone against unchanged values of the same weight, size and alignment. In a column of similar four-digit magnitudes the changed rows are not scannable without colour; a gutter mark or weight change would carry the same information redundantly.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L4/12",
      "severity": "P3",
      "location": "Phase banner prose (x~330) and step caption (x~1380)",
      "finding": "'18 MB' and the 'stepping starts when the replay engine loads' statement each appear twice within 130 px of vertical distance -- once in the banner and once in the step counter caption -- spending two of the densest lines on the same fact.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/13",
      "severity": "P3",
      "location": "CALL TRACE pane, indent guides",
      "finding": "A vertical guide rule is drawn only at the first indent level; depths 2-4 ('calculate_damage', 'calculate_remaining_shield_pct') are expressed by indentation alone. At seven frames it stays traceable, but the guide does not scale with the depth it exists to support.",
      "criterion": "B6"
    }
  ]
}
```
