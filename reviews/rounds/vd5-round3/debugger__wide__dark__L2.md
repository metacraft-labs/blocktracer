Expected elements: present

Backbone all present: slim identity bar (chain, truncated hash, `Partial`, block 101, back arrow), dark product surface, full-viewport pane grid with no footer and no page scrollbar, source pane with line 32 marked as the current position, a 7-frame call trace, a 10-row state pane, forward and reverse stepping controls, a scrubber. No spinner, no empty pane, no light chrome.

Inside each pane the columns hold: call-trace counts and state types right-align at x=1518, transaction values at x=1906. Unresolved is the page-level grid carrying the panes.

Findings, worst first:

1. The identity bar and status banner are inset 24 px on both edges; every pane below spans x=4 to x=1915. Nothing in the header aligns with the grid it sits on.
2. The right column wastes ~290 px: call trace content ends at y≈470 in a pane running to y=628, state ends at y≈937 in a pane running to y=1069 — while the source pane clips line 58 flush against its bottom border.
3. Gap scale is not one scale: 4 px column gutters, 16 px controls→panes, 40 px call trace→state, 10 px bottom margin, 24 px header inset.
4. Source lines 40 and 53 are cut mid-token at x=916 with no ellipsis, fade or scrollbar.

Highest-priority fixes: unify the page inset (header to the grid's 4 px, or the grid to 24 px), and make the right column's vertical split content-driven so the dead 290 px goes to the trace or the source.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L2",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/dark/L2/1",
      "severity": "P2",
      "location": "identity bar and status banner (y 0-115) versus the pane grid below (y 126-1069)",
      "finding": "Two page insets. Header content runs x=24 to x=1895 (24 px margins); every pane below spans x=4 to x=1915 (4 px margins). The back link '← aztec' sits 20 px right of the Debug Controls pane's left border and 'Download trace' ends 20 px left of the Transaction pane's right border, so no header element aligns with the column edges it sits above. Pick one inset for both bands.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L2/2",
      "severity": "P2",
      "location": "right column - call trace pane (x 921-1528, y 227-628) and state pane (y 669-1069)",
      "finding": "A fixed vertical split leaves roughly 290 px unused. Call-trace content stops at y~470 ('Sorted by call order.') inside a pane that runs to y=628 - 158 px, ~39% of the pane, is empty. The state pane's last row 'i' ends at y~937 inside a pane running to y=1069 - a further 129 px. Meanwhile the source pane runs the full column height and still clips its content at the bottom border. Size the split to content (or let the source column take the freed height) rather than 50/50.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L2/3",
      "severity": "P2",
      "location": "whole-page pane grid",
      "finding": "Five different gap values with no common unit: 4 px column gutters (editor right border 916 to call trace left border 921; call trace 1528 to transaction 1533), 16 px between the Debug Controls pane (ends 210) and the panes below (start 227), 40 px between the call trace pane (ends 628) and the state pane (starts 669), a 10 px bottom page margin (panes end 1069 of 1080) against 4 px side margins, and 24 px header insets. The 40 px band between the two right-hand panes is the most visible: it is ten times the gutter immediately to its left.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L2/4",
      "severity": "P2",
      "location": "editor pane, source lines 40 and 53, right border x=916",
      "finding": "Both lines are cut mid-token at the pane border - 'shield_regen_perce' and 'damage: Field, r' - with no ellipsis, no fade and no visible horizontal scrollbar, so nothing indicates the lines continue. Not filed as P1 clipped text because horizontal scroll inside a code pane is legitimate; it is the missing affordance that is below bar. The same pane also leaves line 58's glyphs 4 px off its bottom border, so the vertical cut is equally unsignalled.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L2/5",
      "severity": "P3",
      "location": "call trace pane, frame rows y 278-443",
      "finding": "The indentation unit is not constant. Frame-name left edges are x=933 (main), 954 (iterate_asteroids), 970 (calculate_damage), 986 (calculate_remaining_shield_pct): a 21 px first step then 16 px steps. A single guide rule sits at x~935 for every nested row regardless of depth, so depth 2 and depth 3 are separated by 16 px of whitespace alone.",
      "criterion": "B6"
    },
    {
      "id": "debugger/wide/dark/L2/6",
      "severity": "P3",
      "location": "transaction pane, BLOCK row (y 227-242) and the rule at y=249",
      "finding": "Proximity groups the wrong rows. Horizontal rules fall at y=146, 249, 281, 312, 363, 414, 444 - there is none above BLOCK, so BLOCK is enclosed with the hash and status-reason header block while CANONICAL, FINALITY, FEE PAYER, TARGET and COST-MANA each sit between their own pair of rules. The rule at 249 is 7 px below BLOCK and 8 px above CANONICAL, i.e. equidistant, so the grouping cannot be read from spacing either.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L2/7",
      "severity": "P3",
      "location": "transaction pane, FEE PAYER (y 320-354) and TARGET (y 371-405) values",
      "finding": "Both addresses wrap to a second line that is right-aligned: line 1 starts at x=1638, line 2 at x=1823, so the continuation ('e430d5d932', 'a59161624c') floats under the tail of line 1 with a 185 px ragged left edge and reads as a detached fragment. Every other value in the pane is a single right-aligned line. Left-aligning the wrapped value, or breaking at a fixed column, keeps it one block without dropping any characters.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L2/8",
      "severity": "P3",
      "location": "status banner row (y 63-115) and the Debug Controls row (y 147-210)",
      "finding": "Grouping gaps are indistinguishable from separation gaps. In the banner, the prose block occupies x 24-618 and the three phase chips x 650-1323, leaving 592 px (31% of the row) empty on the right while the prose is squeezed to two lines; the chip group's left edge at 650 matches no column edge on the page. In the controls row the gaps are buttons-to-scrubber 17 px, scrubber-to-sentence 17 px, sentence-to-'128' 13 px, '128'-to-'/' 12 px, so the step counter reads as a continuation of the sentence rather than as its own group.",
      "criterion": "B1"
    }
  ]
}
```
