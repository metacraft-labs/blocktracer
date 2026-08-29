Expected elements: present

All MUST-SHOW items present, no MUST-NOT-SHOW item: identity bar with identity, both stepping directions, scrubber, readout and phase rail; Code positioned at line 32; Call Trace and Event Log one tab strip, Call Trace open; Values a pane below it; Transaction pane; no spinner, light chrome, prose band or full-width row.

A disciplined, mostly very legible dark surface — body text 12.7–15.5:1, editor tokens 8.4–12.5:1 — let down by an elevation ramp too compressed to hold shape and one hue meaning four things. Figures sampled from the PNG; four further P3s cover role reuse and palette provenance.

- **P2** Call Trace row 6 (`calculate_damage`, y≈287): selecting the current frame *lowers* its contrast — name #818cf8 on the #312e81 fill 3.83:1, path #919191 3.62:1, versus 15.52:1 and 5.47:1 unselected. Code uses the same fill, keeping #f3f3f3 at 10.29:1.
- **P2** Indigo means link, current position, changed value and in-progress status at once. `9000`/`2000` in Values are exactly the `Sort by cost` link colour.
- **P2** Chip and button fill #202020 on #1b1b1b = 1.06:1 — chips and all eight stepping buttons have no visible body.
- **P2** Stepping glyphs are all #818181/4.18:1, the dimmest thing in the bar, with no enabled/disabled distinction.
- **P2** Scrubber track #3a3a3a on #1b1b1b = 1.51:1; only the ~20px filled head is visible.

Top fixes: put #f3f3f3 on the Call Trace selection fill as Code already does; split the indigo, keeping it for position and moving the Values diff role to its own hue.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L3",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/dark/L3/1",
      "severity": "P2",
      "location": "Call Trace pane, selected frame row `calculate_damage` (y≈287)",
      "finding": "Marking the current frame cuts its contrast by four times. On the #312e81 selection fill the frame name is #818cf8 (3.83:1) and the module path `zk_shields · src/shield.nr` is #919191 (3.62:1) — both below 4.5:1 — while the identical text one row up on #1b1b1b runs 15.52:1 and 5.47:1. Only the opcode count (#dddddd, 8.41:1) survives. The Code pane paints its current line with the same #312e81 fill but keeps #f3f3f3 on it at 10.29:1, so the two panes that share the selection fill disagree on its foreground. The current position is therefore the single hardest row to read in the pane that exists to show it.",
      "criterion": "B2"
    },
    {
      "id": "debugger/wide/dark/L3/2",
      "severity": "P2",
      "location": "identity bar back-link, Code pane line 32 gutter, Call Trace selected row and footer link, Values pane rows `remaining_shield`/`damage`, Transaction pane `101:0`",
      "finding": "One indigo carries four unrelated roles. #818cf8 is the link colour (`← aztec`, `Sort by cost`, `101:0`), the current-position colour (2px left rail, line number and `▶` caret on code line 32; 2px left rail and name on the selected frame), the diff/changed-value colour (2px left rail plus the numerals `9000` and `2000` in Values), and — through #312e81 and #a5b4fc — the in-progress status colour (`FETCHING` badge fill, scrubber head). The visible cost is in the Values pane: every other numeral there is #dddddd, so the two changed values are the only coloured text in the pane and they are painted in precisely the hue used for hyperlinks two panes to the right. Position and diff are different questions and must not share a swatch with navigation.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/3",
      "severity": "P2",
      "location": "Transaction pane chips (`Partial`, `Yes`, `Safe`, `Not observable`, `Trace ready`) and the eight stepping buttons in the identity bar (x≈396–670)",
      "finding": "The chip/button fill #202020 sits 1.06:1 against the #1b1b1b pane (ΔL* 1.3, at or under the just-noticeable threshold), so none of these components has a visible body — each is held only by its 1px border. That border is itself inconsistent in weight: `Partial` (#ea580c, 4.58:1) and `Trace ready` (#16a34a, 4.94:1) read as real chips, while `Yes`, `Safe` and `Not observable` are outlined at roughly 1.5:1 and read as loose grey text. One component renders as two different things within a single pane, and the stepping buttons read as bare glyphs rather than a grouped control cluster.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L3/4",
      "severity": "P2",
      "location": "identity bar, stepping control group (x≈396–670, y≈20–46)",
      "finding": "All eight stepping glyphs are exactly #818181 on #202020 = 4.18:1 — measured button by button, not one is brighter or dimmer than another. Two consequences. First, reverse stepping, which the expectation block calls this product's entire premise, is the lowest-contrast element in the bar it is required to be visible in: the hash beside it is 15.52:1, `Download trace` 15.52:1, `Engine loading — 18 MB` 12.68:1. Second, with the engine at `FETCHING` the block names the buttons' disabled state as one of the three carriers of loading status, but since every glyph is one value there is no disabled state to read.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L3/5",
      "severity": "P2",
      "location": "identity bar, position scrubber (x≈686–952, y≈22–42)",
      "finding": "The unfilled portion of the scrubber is #3a3a3a on #1b1b1b = 1.51:1, half the 3:1 floor for a non-text UI component, and it is drawn as a dotted rule so its effective coverage is lower still. Only the ~20px filled head at #a5b4fc (8.64:1) is legible. The timeline is a MUST-SHOW element, and with 92% of its length invisible the reader cannot see the extent the head is a fraction of and has to fall back on the `128 / 1315` readout for position within the trace.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/6",
      "severity": "P3",
      "location": "Transaction pane, CANONICAL / FINALITY / EXECUTIONS rows (y≈227–279 and y≈446–464) against the `public` row (y≈535)",
      "finding": "The neutral chip (#919191 text) is used for `Yes` (canonical — affirmative), `Safe` (finality — affirmative) and `Not observable` (private executions — a capability limit), while #4ade80 marks `Trace ready` a few rows below. A reader who learns green means available must read grey as its complement, which is right for `Not observable` and wrong for `Yes` and `Safe`. Colour-by-exception is a defensible policy, but the neutral currently spans an affirmation and a limitation in one pane.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/7",
      "severity": "P3",
      "location": "whole surface — greyscale ramp and accent set",
      "finding": "88.8% of the page area is three exactly achromatic values (#1b1b1b 41.1%, #161616 26.3%, #101010 21.4%), and every grey in the ramp from #0f0f0f to #f3f3f3 has zero saturation, while every accent is an unmodified stock ramp value: indigo-400 #818cf8, indigo-300 #a5b4fc, indigo-900 #312e81, orange-400 #fb923c, orange-600 #ea580c, green-400 #4ade80, green-600 #16a34a, blue-300 #93c5fd, cyan-300 #67e8f9, amber-400 #fbbf24, violet-300 #c4b5fd, green-500 #22c55e. The accents consequently float on a base that shares no hue with them, and the two families near-collide where they meet: comment green #22c55e beside chip green #4ade80, string orange #fdba74 and call amber #fbbf24 beside `Partial` orange #fb923c, numeric-literal violet #c4b5fd beside position indigo #818cf8. It reads as a default palette adopted rather than a theme designed.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L3/8",
      "severity": "P3",
      "location": "Code pane body and its right edge (x≈916–921); pane header strips; Transaction pane RAW block",
      "finding": "Two surface values each carry three meanings. #101010 is the page canvas, the Code pane body and the RAW (chain-native) block in the Transaction pane; #161616 is the pane header strip, the active file-tab strip and the steppable-code-line tint (which at 1.05:1 against #101010 is near-invisible anyway, and is already encoded by the `·` gutter dot). Because the Code pane body equals the canvas, the left column is separated from the page only by a #3a3a3a hairline at 1.67:1, while its three peers sit one step up at #1b1b1b — the flagship pane is the one with no elevation.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L3/9",
      "severity": "P3",
      "location": "identity bar, phase rail `OPENING` / `POSITIONING` (x≈1318–1480)",
      "finding": "The two phases not yet reached are #919191 on #1b1b1b — the same value as `NOIR`, `128 / 1315` and the module paths in the call trace. `Not yet reached` therefore has no colour role of its own, it borrows the generic muted grey, and the rail has only two values (active badge, muted text) for what is a three-state sequence. A completed phase would currently be indistinguishable from a pending one.",
      "criterion": "B5"
    }
  ]
}
```
