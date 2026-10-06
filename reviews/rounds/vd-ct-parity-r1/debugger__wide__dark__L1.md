# L1 — Typography and hierarchy — `debugger` wide/dark

Expected elements: present — all §4 must-show items for the `debugger` register
are on screen (slim identity bar with chain exit, provenance `Data` row as
pane-row not band, Code pane with position indicator, tabbed Call Trace/Event
Log with Call Trace open, separate Values pane below the tabs, bidirectional
stepping controls + scrubber + phase rail in the bar), and no must-not-show
item is present.

The vendored `.ct-tab` underline idiom landed cleanly on the file tab strip,
but the consolidation is unfinished: two selected-state treatments still
coexist on one screen.

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L1",
  "expectedElements": "present",
  "missing": [],
  "rating": 7,
  "findings": [
    {
      "id": "debugger/wide/dark/L1/1",
      "severity": "P2",
      "location": "source file tabs (shield.nr) vs Call Trace/Event Log tabs vs frame selector (1-8)",
      "finding": "The vendored .ct-tab underline idiom landed cleanly on the file tab strip (blue text + blue rule, legible), but Call Trace/Event Log still use a filled-box selected state and the frame-selector '3' button combines a filled box AND an underline. The screen still shows two coexisting selected-state treatments instead of one.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L1/2",
      "severity": "P2",
      "location": "Transaction pane, rows 1-2 (hash) vs identity bar hash",
      "finding": "The same tx hash is truncated three different ways in one view: identity bar (6+4 chars), Transaction pane header (8+8 chars), and a third row directly beneath that prints it in full, differentiated from the truncated line above only by weight and a dimmer gray, not by size.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/3",
      "severity": "P3",
      "location": "Transaction pane, FEE PAYER / TARGET rows",
      "finding": "These addresses print full-length and hard-wrap across two right-aligned lines at an arbitrary character cut, rather than truncating with a copy affordance like every other identifier on the page.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/4",
      "severity": "P3",
      "location": "Values pane, masses / masses[2] rows",
      "finding": "Nesting is signaled by a single-space indent only, with no guide rule, unlike Call Trace's indent-plus-guide-line treatment of the same parent/child relationship one pane to the left.",
      "criterion": "B6"
    }
  ]
}
```
