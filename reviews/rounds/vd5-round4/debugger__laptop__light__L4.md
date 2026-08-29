# debugger · laptop · light · L4 (information density and legibility)

Expected elements: present

Everything the block requires is on screen carrying real content: the slim identity bar (`← aztec`, `0xb63616…6359`, `Partial`, `block 101`, back-link), a source pane positioned at line 32 with a gutter caret and row highlight, a call trace of seven frames with depth guides, a STATE pane with ten values, both stepping directions in one visible group, a scrubber plus `Step 128 of 1315`, and the full hash in the TRANSACTION pane. No spinner — the three named phase chips are exactly what B8 asks for — no empty pane, no explorer footer or nav, no page scrollbar. The light theme is a sanctioned capture variant of this view, not a register error.

Under the density lens the surface is genuinely information-rich but spends its space unevenly, and the pane whose rows are worth the most is the one that loses. The editor sets ~23 px line-height for ~14 px monospace and clips seven of its 26 visible lines mid-token at x≈683 with no ellipsis or visible scroll affordance. The 1315-step trace's only graphical position cue is 170 px wide inside an 1132 px band that restates the same number twice more in prose and digits. Two 40-hex addresses in the TRANSACTION pane wrap across three lines, breaking mid-byte and orphaning `32` and `4c`.

Highest-priority fixes: (1) tighten the source line-height and give the editor either more width or a visible horizontal-scroll affordance; (2) stop wrapping addresses mid-byte in the TRANSACTION pane, and give the scrubber the width the prose is wasting.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "laptop",
  "theme": "light",
  "reviewer": "L4",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/laptop/light/L4/1",
      "severity": "P2",
      "location": "EDITOR pane, right edge x≈683 — lines 26, 40, 41, 42, 43, 48, 49",
      "finding": "Seven of the 26 visible source lines are cut off at the pane's right edge mid-token (line 26 ends '…(initial_shield, re', line 41 ends 'after each h', line 42 ends '/ 100;') with no ellipsis, no fade and no visible horizontal scrollbar. Even the pane's own explanatory note is clipped ('…are not in' / 'this window.'). At 680 px the source pane holds roughly 64 monospace columns, which is under the measure this Noir source needs, and nothing on screen tells the reader that content continues.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L4/2",
      "severity": "P2",
      "location": "EDITOR pane body, line 26 at y≈320 through line 51 at y≈895",
      "finding": "Source line-height is ~23 px for ~14 px monospace (ratio ~1.6) — a reading rhythm, not a tool rhythm. In the register that pays for density this is the most expensive place to spend it: at the desktop app's ~1.4 the same 620 px of pane body would show roughly 33 lines instead of 26, which is seven more lines of context around the pinned position at no legibility cost.",
      "criterion": "B1"
    },
    {
      "id": "debugger/laptop/light/L4/3",
      "severity": "P2",
      "location": "TRANSACTION pane, FEE PAYER value y≈325–370 and TARGET value y≈400–445",
      "finding": "Both 40-hex-digit addresses wrap across three right-aligned lines and break mid-byte, leaving a two-character orphan alone on the third line ('32' at y≈370, '4c' at y≈445). A hash that wraps mid-byte cannot be scanned for a prefix/suffix match and cannot be read out or transcribed correctly. The label column beside each also leaves ~40 px of dead space under 'FEE PAYER' and 'TARGET' while the value fights for width, so the ragged wrap is not even buying density.",
      "criterion": "B7"
    },
    {
      "id": "debugger/laptop/light/L4/4",
      "severity": "P2",
      "location": "DEBUG CONTROLS band, scrubber at x≈285–455, y≈172",
      "finding": "The only graphical expression of position within a 1315-step trace is 170 px wide (~0.13 px per step, with ~28 px filled) inside an 1132 px band. The same row then restates the identical fact twice more — 'Step 128 of 1315 …' occupying ~560 px of prose and '128 / 1315' another ~80 px at the far right. Of three encodings of one number, the one that could show shape (where the current step sits, how the trace is distributed) got the least width and the two redundant textual ones got the most.",
      "criterion": "B1"
    },
    {
      "id": "debugger/laptop/light/L4/5",
      "severity": "P2",
      "location": "DEBUG CONTROLS, the eight stepping buttons at x≈18–268, y≈160–186",
      "finding": "The controls are icon-only glyphs at ~14 px in light grey on a near-white surface, with three near-identical pairs at this size (the two diagonal step-in/step-out arrows at x≈83–133, the two bracketed single arrows at x≈143–195, the two double arrows at x≈207–265). Both directions are present, so the presence check passes, but at this size and contrast a reader cannot tell which button reverses without hovering, and no keyboard hints are shown anywhere on the band — B10 asks for keyboard affordances to be indicated.",
      "criterion": "B10"
    },
    {
      "id": "debugger/laptop/light/L4/6",
      "severity": "P2",
      "location": "Loading banner, y≈62–118, and the stack above the EDITOR pane (y=0 to y≈195)",
      "finding": "The banner sets ~15 px prose across only ~590 px in two lines with generous leading, while ~500 px to its right carries only the three phase chips. Set at the pane register's ~13 px the same sentence fits one line. Together the identity bar (62 px), the banner (56 px) and the full-width DEBUG CONTROLS band (~77 px) consume ~195 px — 22% of a 900 px laptop viewport — before the first line of trace content, on the view whose whole claim is density.",
      "criterion": "B1"
    },
    {
      "id": "debugger/laptop/light/L4/7",
      "severity": "P3",
      "location": "CALL TRACE pane, y≈455–558 (below the 'Sorted by call order.' footer)",
      "finding": "About 105 px of the call-trace pane is empty while the EDITOR beside it is clipping lines horizontally and running content off the bottom edge. The STATE pane below has its own ~40 px of slack at y≈860–893, so no pane is actually starved vertically — but the column split at this viewport leaves visible dead space in the middle column that the source pane could use if the panes shared a horizontal boundary instead of a fixed one.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L4/8",
      "severity": "P3",
      "location": "CALL TRACE pane — column header 'ACIR opcodes' at x≈1040–1140, y≈242, and the 'Sort by cost' link at x≈1063, y≈444",
      "finding": "One quantity carries two names 200 px apart in the same pane: the numeric column is headed 'ACIR opcodes' but the sort control offers 'cost', so a reader cannot tell whether sorting by cost would reorder by the column they can see or by a measure not shown. The header itself also mixes two treatments in one label — 'ACIR' letterspaced uppercase, 'opcodes' lowercase.",
      "criterion": "B7"
    },
    {
      "id": "debugger/laptop/light/L4/9",
      "severity": "P3",
      "location": "STATE pane — 'remaining_shield 9000' at y≈632 versus 'damage 2000' at y≈800",
      "finding": "Changed values are marked two different ways with no legend: remaining_shield is accent-coloured text only, damage is accent-coloured text plus an accent bar in the pane's left gutter. If the bar means something distinct (written at this step rather than merely changed) it is unreadable as such; if it means the same thing, the two rows are inconsistently marked. Under load this is the pane where the eye should find the changed values first.",
      "criterion": "B5"
    },
    {
      "id": "debugger/laptop/light/L4/10",
      "severity": "P3",
      "location": "EDITOR pane bottom edge, y≈890–900 (line 51)",
      "finding": "The editor's last line is cut mid-glyph at the viewport edge and the pane draws no closing bottom border, while the CALL TRACE and STATE panes both close cleanly with a border at y≈893. The left column therefore reads as the page running off the bottom rather than as a bounded scroll container, which undercuts the 'session occupies the viewport' framing at exactly the seam where it is judged.",
      "criterion": "B4"
    }
  ]
}
```
