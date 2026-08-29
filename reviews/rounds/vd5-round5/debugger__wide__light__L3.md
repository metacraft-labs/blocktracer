Expected elements: present

All MUST SHOW items render: a slim identity bar (back-link, `0xb63616…6359`, Partial, block 101, ten stepping buttons in both directions, scrubber, quantified `Engine loading — 18 MB 128 / 1315`, phase rail); a **Code** pane positioned at line 32; a seven-frame call trace holding the taller share of the middle column; **CALL TRACE | EVENT LOG** as one tab strip with Call Trace open; a populated **Values** pane below it, not a third tab. No forbidden item: no spinner, no empty pane, no full-width prose band, no full-width pane row. The surface is light but it is tool chrome — 11–12 px monospace, hairline panes, no marketing whitespace — and the dark capture is genuinely dark (#1B1B1B panes), so this is not the register error.

Colour-wise the theme is legible — every text pair clears AA, lowest 5.10:1 — but under-specified. One accent, indigo #4F46E5/#6366F1, carries links, changed values, current position, the selected frame, the active tab, the scrubber, the executable-line dot and the active loading phase. Worse, marking something current *lowers* its contrast: the selected frame name drops 19.03:1 → 5.10:1; line number 32 drops 6.61:1 → 5.10:1. Meanwhile ten disabled buttons are the heaviest mass in the bar, and the code pane's whole surface ramp lives inside 8/255 while its outline sits at 2.55:1.

Highest-priority fixes: split the accent into distinct link / diff / position roles, and make the selected row gain contrast rather than lose it.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "light",
  "image": "screenshots/debugger__wide__light.png",
  "reviewer": "L3",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/light/L3/1",
      "severity": "P2",
      "location": "Call Trace pane, selected frame row `calculate_damage` (y≈287); Code pane gutter, line number 32",
      "finding": "Marking something as the current position lowers its contrast instead of raising it. The selected frame name is #4F46E5 on the #E0E7FF selection fill = 5.10:1, while the identical unselected label three rows above is #101010 on white = 19.03:1 — a 73% drop. The same happens in Code: line numbers are #565656 on #F3F3F3 (6.61:1) but line 32's number is #4F46E5 on #E0E7FF (5.10:1). The current position is therefore the lowest-contrast text on the page, in both panes that have one. The selection fill itself is only 1.23:1 against the pane, so the 2 px indigo left bar is doing nearly all the work.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/light/L3/2",
      "severity": "P2",
      "location": "whole page — identity bar `← aztec`; Call Trace footer `Sort by cost`; Transaction pane BLOCK `101:0`; Values rows `9000` and `2000`; Code line 32 left bar and gutter dots; CALL TRACE tab underline; scrubber",
      "finding": "A single accent hue carries at least eight unrelated roles. #4F46E5 is simultaneously the hyperlink colour (`← aztec`, `Sort by cost`, `101:0`), the changed-value diff colour (`9000`, `2000` in Values), the current-position colour (line-32 bar, selected-row bar and text) and the active-tab underline; #6366F1 is the scrubber fill and the executable-line dot. The sharpest collision is diff-vs-link: `9000` and `2000` are bit-identical to `101:0` two panes away, so a changed value reads as clickable and a link reads as changed. Colour therefore carries no role information anywhere on this surface — every accent occurrence has to be decoded from position.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/light/L3/3",
      "severity": "P2",
      "location": "identity bar, phase rail — active `FETCHING` chip (x≈1240–1310)",
      "finding": "The active phase chip fills with #E0E7FF, the exact token used for 'you are here' in Code (line 32) and in Call Trace (selected row). One tint therefore means both 'current position in the trace' and 'engine phase currently running' on the same screen, and the two are 900 px apart in the same visual field. Loading progress and trace position are unrelated state families and must not share a fill.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/light/L3/4",
      "severity": "P2",
      "location": "identity bar, stepping controls (x≈395–670) versus `Share` / `Download trace` (x≈1725–1900)",
      "finding": "Disabled state is expressed by adding weight rather than removing it. The ten disabled stepping buttons are #DDDDDD slabs with #C8C8C8 outlines on the white bar and #727272 glyphs (glyph 3.54:1, just over the 3:1 non-text floor and well under 4.5:1). They form the single largest and darkest mass in the identity bar, while the two genuinely available actions — `Share` and `Download trace` — are plain #101010 text on white with a hairline. Unavailable outranks available, which inverts the bar's emphasis exactly while the engine is loading and those buttons cannot be used.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/light/L3/5",
      "severity": "P2",
      "location": "Code pane, comment on line 41 and numeric literals on lines 28/32/49; Transaction pane, `Trace ready` chip (y≈544)",
      "finding": "The syntax palette is not a distinct editor family — it is drawn from the same generic ramp as the UI status colours. The comment green on line 41 is #166534, bit-identical to the `Trace ready` status chip's text green, so 'this is a comment' and 'the trace is ready' are one token. Numeric literals are #6D28D9, one step from the interaction accent #4F46E5: on line 32 the violet `100` sits ~300 px from an indigo position bar of the same family on the same row. Keywords #713F12 and types #155E75 complete a set of off-the-shelf 700/800-level primitives rather than the product lineage's editor tokens.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/light/L3/6",
      "severity": "P2",
      "location": "Code pane interior (y 95–1075) versus the pane outlines at x=4/916/921/1528 and y=63",
      "finding": "The surface ramp is compressed inside panes and heavy at their edges. Within the Code pane the header #F3F3F3, executable rows #F0F0EF, non-executable rows #EBEBEA and the 'Showing from line 26' note band #ECECEB all live inside an 8/255 window — every internal step is ≤1.05:1 and none is perceptible. The pane outline is #A2A2A2 at 2.55:1 against white, with white gutters between panes, so the four regions read as separately outlined cards floating on a page rather than one continuous tool surface. The dark capture's equivalent outline is #3A3A3A on #1B1B1B = 1.51:1, so the frame is ~70% stronger in light than in dark for no stated reason.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/light/L3/7",
      "severity": "P3",
      "location": "Code pane, non-executable rows (lines 30, 33, 35, 36, 38, 39, 45, 47, 51–52, 55, 59, 62)",
      "finding": "The executable/non-executable polarity is inverted, which is the clearest evidence this theme was derived by flipping lightness rather than re-designed. Non-executable rows are #EBEBEA against #EFEFEF for executable ones — the rows you cannot step to are the darker, visually heavier ones. In the dark capture the same pair is #0F0F0F against #141414, where darker correctly means recede; the sign was preserved through the flip. The delta is 1.05:1 either way, so the band carries no information and the whole signal rests on the ~2 px indigo step dot in the gutter, which itself only reaches 3.94:1 at its single darkest pixel.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/light/L3/8",
      "severity": "P3",
      "location": "Transaction pane — `Partial` (y≈111), `Yes` (y≈238), `Safe` (y≈270), `Not observable` (y≈454), `Trace ready` (y≈544); identity bar `NOIR` chip",
      "finding": "The chip family has three colour treatments with no legible rule. `Partial` is #9A3412 on #FFEDD5 and `Trace ready` is #166534 on #DCFCE7, but `Yes`, `Safe`, `Not observable` and `NOIR` are all #565656 on #F3F3F3 with the same outline. Neutral grey therefore means an affirmative (`Yes` for canonical, `Safe` for finality), an unavailability (`Not observable`) and a plain label (`NOIR`) at once — and `Not observable` sits directly above the green `Trace ready` as its matched private/public pair, so the one place the reader most needs a role contrast gets none.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/light/L3/9",
      "severity": "P3",
      "location": "identity bar scrubber (x≈688–952) versus all other accent uses",
      "finding": "Two accent steps are in play with no discernible rule: every interactive and positional accent is #4F46E5 (6.29:1 on white), but the scrubber fill and the code gutter's step dots are #6366F1 (4.47:1 on white). The scrubber is the one accent element the eye is meant to track during loading and it is the palest of them.",
      "criterion": "B2"
    },
    {
      "id": "debugger/wide/light/L3/10",
      "severity": "P3",
      "location": "Code pane, current line 32, right end (x≈870–916) versus Call Trace selected row (x≈924–1519)",
      "finding": "The same current-position role is rendered two ways. In Call Trace the selection is a flat #E0E7FF across the full row width; in Code the line-32 fill fades horizontally from #E0E7FF at the gutter to roughly #EAEBEE at x≈907, so at the right edge of the pane the highlight has decayed to about 1.02:1 against the surrounding rows. On a long line the current-position band effectively stops before the line does.",
      "criterion": "B5"
    }
  ]
}
```
