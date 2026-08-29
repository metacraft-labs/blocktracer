# debugger · wide · dark · L4 — Information density and legibility

Expected elements: present

Every required element is present: the slim identity bar (`← aztec`, `0xb63616…6359`, Partial, `block 101`), a dark product surface with no page scrollbar, the source pane positioned at line 32 with a filled current-line band and a `▶` gutter marker, a seven-frame call trace with a matching highlighted frame, eleven state values, eight stepping controls including three reverse affordances, and a scrubber reading `128 / 1315`. Loading is honest — named phase chips, no spinner. All text I measured clears 5.4:1.

The failures are density ones, and they cut both ways: the surface both wastes space and drops information it has room for. The source pane — 918×840, the largest region on the screen — renders every token at one colour (#DDDDDD for keywords, identifiers, numerals, comments and strings alike): no syntax highlighting at all. The right column ends its content at y≈580 and runs empty to y≈1056 (~475 px), while EVENT LOG sits behind a tab and the call trace has room for only six more frames. Above them, 215 px of chrome states "18 MB / stepping starts when the engine loads" twice and the step position twice.

Highest-priority fixes: (1) apply the CodeTracer editor token palette to the source pane; (2) let the right column carry more — event log alongside state, or metadata rows filling the pane — and cut the duplicated loading copy in the control row.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "reviewer": "L4",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/dark/L4/1",
      "severity": "P2",
      "location": "EDITOR pane, source body (x0–918, y308–1075), e.g. lines 27, 28, 41, 54",
      "finding": "The source has no syntax highlighting. Sampled pixels for the keyword 'let' (line 27), the identifier 'damage', the numeral '0', the comment on line 41 and the format string on line 54 are all exactly #DDDDDD. The largest pane on the screen — 918x840, about 46% of the viewport — carries 33 lines of Noir as one flat colour, so structure must be read word by word instead of scanned. Design-System §7 makes the editor tokens the one sanctioned crossing into every register; here they are absent from the debugger itself.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L4/2",
      "severity": "P2",
      "location": "Top chrome, y0–215: notice band (y58–118) and DEBUG CONTROLS row (y155–200)",
      "finding": "215 px — 20% of the viewport height — sits above the first content pane, and it repeats itself. The banner says 'Stepping starts once the replay engine loads — 18 MB, fetched once and cached'; the step readout 300 px below says 'stepping starts when the replay engine finishes loading (18 MB)'. 'Step 128 of 1315' is then restated as '128 / 1315' at x1435–1510 of the same row. Two facts, four statements, in the band that should be the densest on the page.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/3",
      "severity": "P2",
      "location": "TRANSACTION pane (x1533–1910), below the 'public · Trace ready' row at y≈580",
      "finding": "The pane's content ends at y≈580 and its border runs to y≈1056, leaving ~475 px (45% of the viewport height, ~178k px²) of empty pane. The CALL TRACE pane adds ~166 px of blank below 'Sorted by call order.' (y470–636) and STATE ~127 px below the 'i' row (y946–1073) — roughly 30% of the right half of the screen is empty, while the EVENT LOG is hidden behind a tab in the STATE header and the call trace can absorb only six more frames before it scrolls. In the information-maximal register this is space that buys nothing.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/4",
      "severity": "P2",
      "location": "EDITOR gutter line pitch (lines 26–58, y319–1058); CALL TRACE and STATE row pitch",
      "finding": "Source lines are on a 23.1 px pitch for a ~14.4 px mono face (line-height 1.60); call trace and state rows are on a 25 px pitch for a ~12.5 px face (line-height 2.0). A desktop editor runs 1.35–1.45 and a desktop tree view ~1.7. The editor pane is the one region that is genuinely full, and the looser rhythm costs it about five source lines at this viewport (33 shown, ~38 at desktop pitch). The rhythm reads as a web page's, not as the app the register is meant to be continuous with.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/5",
      "severity": "P2",
      "location": "Identity bar hash (x93–201); TRANSACTION pane header hash (x1621–1855, y163); FEE PAYER / TARGET rows (y325–405)",
      "finding": "Three identifier-overflow strategies coexist on one screen: the identity bar middle-truncates the tx hash to 12 characters ('0xb63616…6359'), the TRANSACTION pane middle-truncates the same hash to 18 ('0xb636167a…66d46359'), and FEE PAYER and TARGET wrap their full 66-character values across two right-aligned lines, leaving ragged 10-character orphans ('e430d5d932', 'a59161624c'). Confirming the bar and the pane name the same transaction requires comparing prefixes character by character, and the wrapped addresses cost two rows each while reading as two tokens.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L4/6",
      "severity": "P2",
      "location": "Identity bar, back link '← aztec' (x24–76, y18–46)",
      "finding": "The only back affordance in the identity bar is labelled with the chain, not the transaction; the hash beside it at x93–201 is plain white and carries no link treatment. The backbone requires a link back to the transaction detail page, and from the label alone a visitor reads this as 'back to aztec'. If it resolves to /aztec rather than to the tx page, the required return path is absent and this becomes a P1. Label the destination ('← transaction' or the hash rendered as the link).",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L4/7",
      "severity": "P3",
      "location": "Identity bar, x361–1674",
      "finding": "1313 px of the 1920 px bar — 68% — is empty between 'block 101' and the 'NOIR' label. At this viewport the full 66-character hash, or the status reason currently wrapping onto two lines inside the TRANSACTION pane, would fit in the bar without making it any taller.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/8",
      "severity": "P3",
      "location": "EDITOR pane row backgrounds, e.g. line 30 (y411) against line 31 (y434)",
      "finding": "Steppable lines carry a background band of #141414 against #101010 for non-steppable lines — a 1.05:1 difference that is invisible in practice. The information is real and useful (it tracks the gutter dot exactly across all 33 lines), but it is carried entirely by a 3 px dot at x78. Strengthen the band or the dot so the executable region can be seen as a shape.",
      "criterion": "B2"
    },
    {
      "id": "debugger/wide/dark/L4/9",
      "severity": "P3",
      "location": "CALL TRACE opcode column (x1470–1520) versus COST · MANA row (y428) and STATE value column (x1350–1410)",
      "finding": "Thousands separators are used in one numeric column and not the others: the call trace shows '1,315' and '1,208', while COST · MANA shows '88000 / 200000' and the state values show '10000', '9000', '2000'. Same magnitudes, three panes, two formats — comparing a cost against a step count means re-reading the digits.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L4/10",
      "severity": "P3",
      "location": "DEBUG CONTROLS scrubber, unfilled track x340–845 (y176–188)",
      "finding": "The unfilled scrubber dashes are #3A3A3A on #1B1B1B — 1.51:1, below the 3:1 floor for a graphical element. The filled head and the numerals carry the position, but the track that expresses how much trace remains is close to invisible, which is the one thing the scrubber exists to show.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L4/11",
      "severity": "P3",
      "location": "DEBUG CONTROLS button row, x20–270 (y168–196)",
      "finding": "Eight icon-only buttons at uniform 30 px spacing, with no labels, no keyboard hints and no grouping between the reverse pair, the step-in/out pair and the jump-to-end pair. Both directions are present and visible, which is what the register requires, but at 1920 the row has ~500 px of spare width and the desktop app indicates its keybindings; the icons themselves sit at 4.18:1, the weakest interactive element on the page.",
      "criterion": "B10"
    }
  ]
}
```
