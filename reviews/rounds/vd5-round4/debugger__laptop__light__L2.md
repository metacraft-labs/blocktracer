# debugger · laptop · light · L2 (Layout, alignment and spacing)

Expected elements: present

Identity bar (y 0–62), dense tool surface, no footer or page scrollbar (row 897 is
clean white edge to edge), source pane with the line-32 marker, a seven-frame call
trace, a populated state table, eight stepping controls including both directions, a
scrubber at x 286–458, the full hash in the TRANSACTION pane. Named phases, not a
spinner. Nothing empty.

A sound three-column grid spending its width in the wrong place.
The EDITOR pane is 683 px (x 4–686) and cuts the tails off seven of the twenty-six
visible source lines (26, 40–43, 48, 49) behind an opaque 19 px fade band at x 667–685
with no scroll affordance in the capture — the same band greys the last word of the
non-truncated info line at y 272. Meanwhile the TRANSACTION pane is blank for 251 px
below "public / Trace ready" (y 641–891) and CALL TRACE is blank for 81 px below its
footer (y 451–531).

The spacing scale is not one scale. Vertical gutters run 4 px (banner→controls), 6 px
(controls→editor) and 32 px (CALL TRACE y533 → STATE y566). The identity bar and
banner sit on a 24 px page gutter while the pane grid sits on 4 px, so nothing above
y 200 shares a left edge (25 / 24 / 13 / 17).

Highest-value fixes: give the source pane the width the TRANSACTION pane is wasting,
and put every gutter on one scale.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "laptop",
  "theme": "light",
  "reviewer": "L2",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/laptop/light/L2/1",
      "severity": "P2",
      "location": "EDITOR pane (x 4–686) versus TRANSACTION pane (x 1149–1435) and CALL TRACE pane (y 205–533)",
      "finding": "The column split starves the flagship pane and pads the others. The editor is 683 px wide and truncates lines 26, 40, 41, 42, 43, 48 and 49 at x~667 behind a uniform 19 px opaque fade band (x 667–685, constant #EEEEED for the pane's full height, no scrollbar thumb anywhere in 660 rows), while the TRANSACTION pane runs empty for 251 px (y 641–891, a third of its height) and the CALL TRACE pane runs empty for 81 px (y 451–531). The same fade also dims the final word of the wrapped, non-truncated info line at y 272, so undamaged prose reads as disabled.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L2/2",
      "severity": "P2",
      "location": "gutter between CALL TRACE (bottom border y 533) and STATE (top border y 566)",
      "finding": "This gutter is 32 px while every other seam on the page is 4–6 px: banner-to-DEBUG-CONTROLS is 4 px (y 116–119), DEBUG-CONTROLS-to-EDITOR is 6 px (y 199–204), and both column gutters are 4 px (x 687–690 and x 1145–1148). One gutter at 8x the others is not one spacing scale, and it costs 32 px of vertical room in a viewport where the editor is already slicing its last line.",
      "criterion": "B1"
    },
    {
      "id": "debugger/laptop/light/L2/3",
      "severity": "P2",
      "location": "left edge of the page, identity bar (y 0–62) and banner (y 64–115) against the pane grid (y 120 down)",
      "finding": "Two competing page gutters. The identity bar and the loading banner are full-bleed with 24 px inner padding ('←' at x 25, banner prose at x 24, 'Download trace' right edge at x 1415, i.e. 24 px from the viewport edge). The pane grid sits on a 4 px margin (pane borders at x 4 and x 1435) with 9–10 px header insets, so 'DEBUG CONTROLS' starts at x 13 and 'EDITOR' at x 14. Nothing in the top 200 px of the page shares a left edge: 25, 24, 13, 17 (first stepping button box at x 17).",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L2/4",
      "severity": "P2",
      "location": "DEBUG CONTROLS pane, stepping button row (x 17–269, y 159–188)",
      "finding": "Measured at y 173 the eight buttons are 29, 29, 27, 26, 32, 32, 32, 32 px wide — four different control sizes in one row, because each box is sized to its glyph rather than to a fixed control size. All seven inter-button gaps are an identical 2 px, so the four semantic pairs (reverse/forward, step-in/step-out, line-back/line-forward, start/end) get no proximity grouping at all; the controls read as one undifferentiated run of eight and the reverse control is not visually paired with its forward twin.",
      "criterion": "B10"
    },
    {
      "id": "debugger/laptop/light/L2/5",
      "severity": "P2",
      "location": "TRANSACTION pane value column, FEE PAYER (y 313–384) and TARGET (y 385–456) against the identity hash at y 150–175",
      "finding": "Two overflow strategies for the same kind of value, 200 px apart in one pane. The identity hash at the top is middle-truncated ('0xb636167a…66d46359', right edge x 1389), while FEE PAYER and TARGET hard-wrap in full onto three right-aligned lines each, leaving two-character orphans ('32' and '4c') alone on the last line. The consequence is row rhythm: those two rows are 69 px tall against 31 px for BLOCK, CANONICAL and FINALITY, so the pane's grid reads as three unrelated blocks rather than one fact table.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L2/6",
      "severity": "P3",
      "location": "CALL TRACE pane, frame rows y 255–431",
      "finding": "The depth ladder is uneven. Frame-name left edges are x 702 (main, d0), 724 (d1), 740 (d2), 756 (d3): the first step is 22 px and every later step is 16 px, so d0-to-d1 and d1-to-d2 do not look like the same move. A vertical guide rule is drawn only at depth 1 (x 706); depths 2 and 3 are expressed by indentation alone, which is what B6 asks to avoid.",
      "criterion": "B6"
    },
    {
      "id": "debugger/laptop/light/L2/7",
      "severity": "P3",
      "location": "STATE pane, below the 'i / 2 / u32' row (y 864–892)",
      "finding": "A row separator is drawn at y 863 under the last value row, leaving a 29 px ruled but empty stub — exactly one row height — between it and the pane's bottom border at y 893. It reads as a blank table row rather than as the end of the table.",
      "criterion": "B1"
    },
    {
      "id": "debugger/laptop/light/L2/8",
      "severity": "P3",
      "location": "STATE / EVENT LOG tab strip, active-tab underline at y 589–590",
      "finding": "The underline spans x 692–744, starting 1 px from the pane's inner left edge, while the 'STATE' label it underlines starts at x 700. The rule is offset 8 px to the left of the word it belongs to and sits flush against the pane border, so it reads as a pane edge decoration rather than as the tab's selected state.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L2/9",
      "severity": "P3",
      "location": "loading banner phase chips (y 77–101) against the identity bar controls (y 18–46)",
      "finding": "Two adjacent full-bleed bands with right edges 92 px apart: the third chip 'POSITIONING AT THE REQUESTED STEP' ends at x 1323 while 'Download trace' directly above it ends at x 1415, and the pane grid below ends at x 1435. The chips are left-flowing after the prose rather than right-aligned to the banner's own 24 px padding, leaving a 92 px ragged notch in the page's right edge at the top of the view. (The three chips are internally consistent — 12 px gaps at x 903–916 and 1058–1071.)",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L2/10",
      "severity": "P3",
      "location": "EDITOR pane, header / tab strip / info line (y 205–300)",
      "finding": "Three left edges inside 95 px of vertical space: the 'EDITOR' header label at x 14, the first file tab 'Nargo.toml' at x 22, and the 'Showing from line 26 —' info line at x 13. The tab strip is inset 8–9 px further than the two rules above and below it, so the pane's left rail visibly steps in and back out.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L2/11",
      "severity": "P3",
      "location": "EDITOR pane bottom edge (y ~893)",
      "finding": "The code viewport's height is not a multiple of the 23 px line height, so line 51 is sliced roughly in half by the pane's bottom border — the digits '51' and the brace are cut mid-glyph. It reads as a rendering accident rather than as a scroll position, and it is the more conspicuous because the STATE pane immediately to its right ends on a full empty row and the TRANSACTION pane ends on 251 px of white.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L2/12",
      "severity": "P3",
      "location": "STATE pane, 'masses' row (y 671–712)",
      "finding": "The array value wraps, making this row 42 px tall against the uniform 25 px of every other row in the table, so the column's scanning rhythm breaks at one point. The '[Field; 8]' type stays on the first line at the x 1134 type rail while the value's continuation '14]' hangs alone on the second line, leaving the type cell looking vertically detached from the bottom half of its own row.",
      "criterion": "B1"
    }
  ]
}
```
