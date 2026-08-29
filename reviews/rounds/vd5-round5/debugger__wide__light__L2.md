Expected elements: present

All ten MUST SHOW items are present and no MUST NOT SHOW item appears: slim identity bar with bidirectional stepping, scrubber, readout and phase rail; Code pane positioned at line 32; a 7-frame Call Trace tabbed with Event Log, Call Trace open; Values as a separate pane below the tabs; Transaction metadata pane. No spinner, no empty pane, no full-width prose band, no full-width row.

Alignment discipline is mostly good — 4px page margins and gutters throughout, 9–10px content insets in all three panes, numeric columns holding exactly (opcodes x1519; Values x1407/x1518), every identity-bar object vertically centred on y≈31 — but the space allocation is inverted and one column starts at the wrong height.

**Findings**

1. P2 — the tabbed region's top border is at y=92 while the Code and Transaction pane tops are at y=68; 24px of bare page shows above it (x921–1529). The three columns do not share a top edge.
2. P2 — 444px (45%) of the middle column is empty: call trace 331px/56% below the footer, Values 113px/29% below row `i`. Meanwhile Code fades lines 40, 53, 64 at x≈915. Neither middle pane needs height — take width from the 608px column.
3. P2 — the scrubber (x687–946) is separated from its own readout `128 / 1315` (x1133) by the status string, at the bar's uniform 16px gap.
4. P2 — RAW JSON hard-clips `"contract": "0x1b31c04…f12` mid-glyph at x≈1889 while Code fades: two overflow treatments, 77px unused below the box.

Fixes: level the three column tops; narrow the middle column and widen Code.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "light",
  "image": "screenshots/debugger__wide__light.png",
  "reviewer": "L2",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/light/L2/1",
      "severity": "P2",
      "location": "middle column, top edge of the Call Trace / Event Log tabbed region (x 921-1529, y 92)",
      "finding": "The three columns do not share a top edge. The Code pane and the Transaction pane both open their top border at y=68; the tabbed region's top border is at y=92, leaving a 24px band of bare page background above it and dropping the 'CALL TRACE' tab label 26px below the 'CODE' and 'TRANSACTION' titles, which are on one baseline. The step is plainly visible where the Code pane's right border meets the tab strip.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/light/L2/2",
      "severity": "P2",
      "location": "middle column - Call Trace region (y 92-679) and Values pane (y 684-1075), against the Code pane (x 4-917)",
      "finding": "Space allocation is inverted relative to content demand. The call trace region is 587px tall and its last frame plus footer end at y=347, leaving 331px (56%) empty; the Values pane is 391px tall and its last row ends at y=962, leaving 113px (29%) empty - 444px, 45% of the column, unused. In the same frame the 913px Code pane fades every line over ~110 characters (lines 40 'shield_regen_perce', 53, 64) and the Transaction pane clips its raw JSON. Because BOTH middle panes have slack, the fix is not redistributing height between them: the 608px column is too wide for what it holds and the width belongs to Code, which is the only starved pane at this viewport.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/light/L2/3",
      "severity": "P2",
      "location": "identity bar, between the scrubber (x 687-946) and the position readout '128 / 1315' (x 1133-1217)",
      "finding": "The position readout is the scrubber's value but is separated from it by the unrelated 'Engine loading - 18 MB' status string (x 964-1120). Every top-level object in the bar sits at the same 16-17px gap (hash-badge 17, badge-block 16, buttons-scrubber 16, scrubber-status 17, readout-phase rail 17), so proximity does no grouping work to the right of the divider at x=377 and the bar reads as a flat strip. The one place proximity does work is the stepping cluster, which uses a legible 2px intra-pair / 10px inter-pair / 16px to-neighbour scale.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/light/L2/4",
      "severity": "P2",
      "location": "Transaction pane, RAW (CHAIN-NATIVE) box (x 1546-1900, y 742-998), 'contract' line",
      "finding": "Two different overflow treatments for code on one page. The Code pane masks its right edge with a fade; this box hard-clips '\"contract\": \"0x1b31c04d5920b0b5936f12' mid-glyph at x~1889 against the rounded border, with no fade, ellipsis, wrap or scrollbar - and 77px of pane height sits unused below the box (content ends y=998, pane border y=1075). The same value is legible in full in the TARGET row 400px above, so no information is lost, but the surface contradicts itself about how overflow is expressed.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/light/L2/5",
      "severity": "P3",
      "location": "Call Trace region footer, 'Sorted by call order.' / 'Sort by cost' (y 332-347)",
      "finding": "The footer sits immediately under the last frame, 332px above the region's bottom border at y=679, so it floats mid-pane rather than reading as a footer. It is the element that makes the region's emptiness legible; pinning it to the pane foot would at least frame the gap as reserved space.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/light/L2/6",
      "severity": "P3",
      "location": "Code pane header stack (y 76-147)",
      "finding": "Three rows on two left edges: the 'CODE' title starts at x=13, the file-tab row 'Nargo.toml' at x=22, and the 'Showing from line 26...' note back at x=13. The 9px tab indent has no visible chrome on the inactive tabs to justify it, so the strip reads as nudged rather than inset.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/light/L2/7",
      "severity": "P3",
      "location": "Code pane, last visible row (line 65, y 1060-1074) at the pane's bottom border (y 1075)",
      "finding": "The pane height is not a multiple of the 23px line pitch, so the final row is bisected: the underscore of 'remaining_shield_pct_as_u32' sits 1px off the border, the row's alternating background band is cut mid-height, and there is 0px bottom padding where the top of the listing has a 12px gap under the note. The result reads as an accidental flush rather than as a signal that more lines follow.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/light/L2/8",
      "severity": "P3",
      "location": "Transaction pane, FEE PAYER (y 291-330) and TARGET (y 345-385) value cells",
      "finding": "Both hex values wrap mid-value to a right-aligned second line ('...e2a272b5' / 'e430d5d932'; '...f12e6fe8f17' / 'a59161624c'). Because the continuation is right-aligned it has a ragged left edge that lines up with nothing, and the two lines read as two values rather than one wrapped one.",
      "criterion": "B4"
    }
  ]
}
```
