Expected elements: present

Every backbone item is there: slim identity bar (chain, truncated hash, `Partial`, block 101), dark product surface, full-viewport session with no explorer chrome or page scrollbar, source pane with line 32 marked by both a fill and a `▶`, a 7-frame call trace, an 11-row state pane, eight stepping controls including reverse, a step scrubber (128/1315), and the transaction pane. No spinner — the load is expressed as three named phases, which is the right answer. No empty pane.

Density is the weak axis. The layout is one step looser than the register asks and spends its 1080 px badly. Editor line pitch is 23 px for ~13 px type, so 33 lines show where ~42 would at desktop-app density; call trace and state rows sit at 25 px; the DEBUG CONTROLS pane spends 98 px of height on a 24 px button row. Meanwhile the transaction pane is empty from y≈575 to 1080 (~500 px), the call trace from y≈462, the state pane from y≈945 — and the editor, the pane that actually ran out of room, clips line 40 mid-identifier (`shield_regen_perce|`) at x=915 and cuts line 58 in half at the viewport edge. The source pane does not keep a usable measure at 1920.

Worst single loss of information: the source is entirely unhighlighted — `fn`, `let`, `u32`, `100` and the `//` comments on lines 41 and 56 are all one grey.

Fixes: (1) apply the CodeTracer editor palette to the source pane; (2) let the editor take the width and height the right column is not using.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L4",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/dark/L4/1",
      "severity": "P2",
      "location": "EDITOR pane, lines 26–58",
      "finding": "The source carries no syntax highlighting at all. Keywords (fn, let, mut, else), types (Field, u32), numeric literals (100, 0) and the comments on lines 41 and 56 are rendered in one identical grey. This is the densest region on the screen and it is doing the least work per pixel: the reader has to parse the text to find a declaration, where a token palette would give it at a glance. Design-System §7 makes editor-token highlighting the one sanctioned register crossing, so an unhighlighted pane inside the debugger itself is the strongest form of the miss.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L4/2",
      "severity": "P2",
      "location": "right column — TRANSACTION pane below y≈575, CALL TRACE below y≈462, STATE below y≈945 — versus EDITOR pane right edge at x=915",
      "finding": "Roughly 500 px of the transaction pane, 180 px of the call trace and 145 px of the state pane are empty, while the one pane that has run out of room is clipped in both axes: line 40 is cut mid-identifier at 'shield_regen_perce', line 53 at 'damage: Field, r', and line 58 is sliced horizontally by the viewport bottom — none of them with an ellipsis, fade or visible scrollbar. At 1920 the split is fixed rather than content-driven, so the source pane is the pane that loses width first, which is the wrong pane. The Watch-for question is whether the source keeps a usable measure here; it does not.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L4/3",
      "severity": "P2",
      "location": "all panes — EDITOR line pitch, CALL TRACE and STATE row pitch, DEBUG CONTROLS pane height",
      "finding": "Row rhythm is one density step looser than the desktop app. Editor lines sit at 23 px pitch for ~13 px type (line 26 at y=319 to line 58 at y=1058), showing 33 lines where an 18–19 px pitch would show ~42; call trace and state rows are both at 25 px; the DEBUG CONTROLS pane occupies 98 px of height (y=120–218) to hold a single 24 px row of buttons, with ~22 px of padding above and below it. Individually small, together this is about a fifth of the viewport spent on air in a register where density is the virtue.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/4",
      "severity": "P2",
      "location": "STATE pane, the gap between the name column and the value column (e.g. 'initial_shield' … '10000', 'shield_regen_percentage' … '10')",
      "finding": "Names are left-aligned at x≈930 and values right-aligned at x≈1400, leaving up to ~300 px of empty row between them with no leader, no zebra banding and no rule. Ten near-identical rows at 25 px pitch across that gap is exactly the case where the eye loses the line and reads a value against the wrong name. The 'masses' row, whose inline array bridges the gap, is legible where its neighbours are not — which shows the gap is the problem, not the type size.",
      "criterion": "B2"
    },
    {
      "id": "debugger/wide/dark/L4/5",
      "severity": "P2",
      "location": "identity bar, x≈420 to x≈1650",
      "finding": "About 1200 px of the 1920 px bar carries nothing, yet the hash it exists to carry is truncated to 6+4 characters (0xb63616…6359) — a harder truncation than the same hash 380 px to the right in the transaction pane (0xb636167a…66d46359). Two truncation lengths for one identifier on one screen means neither can be matched against the other at a glance, and the shorter one is in the element with the space to spare. The bar could carry the full hash at this viewport.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/6",
      "severity": "P3",
      "location": "CALL TRACE pane, frames at depth 2–4 (calculate_damage, calculate_remaining_shield_pct)",
      "finding": "A vertical guide rule is drawn only at depth 1; deeper frames are expressed by indentation alone, and there is no disclosure control on any row. At the fixture's depth of four this still reads, but the pane gives no evidence it survives the forty-frame trace the rubric asks about, and there is no way to collapse a subtree to make it.",
      "criterion": "B6"
    },
    {
      "id": "debugger/wide/dark/L4/7",
      "severity": "P3",
      "location": "CALL TRACE pane, the module/path text on every frame row",
      "finding": "'zk_shields · src/shield.nr' repeats verbatim on six of the seven rows and consumes roughly 40% of each row's width for a value that never varies. Eliding the repeat (or showing the path once as a pane subtitle and only marking the row where it changes, main's src/main.nr) would return that width to the frame names, which are what is actually being scanned.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/8",
      "severity": "P3",
      "location": "DEBUG CONTROLS, the eight buttons at x=18–265",
      "finding": "All eight controls are icon-only with no labels and no keyboard-shortcut hints, and the step-out/step-in pair (↖ / ↘) is not self-evident at ~10 px. There is ~600 px of unused width in the same bar, so the density argument for dropping the legend does not hold at this viewport — nothing was gained by dropping it.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L4/9",
      "severity": "P3",
      "location": "DEBUG CONTROLS, scrubber track x=290–845",
      "finding": "555 px of track represents 1315 steps (2.4 steps/px) as a featureless dashed line with a single position block. It carries position and nothing else — no tick marks, no call-depth ribbon, no markers for the frame boundaries the call trace already knows about. It is the only element expressing the trace's volume and it currently expresses only the trace's length.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L4/10",
      "severity": "P3",
      "location": "TRANSACTION pane, FEE PAYER and TARGET rows",
      "finding": "66-character addresses wrap onto a second right-aligned line, breaking mid-hash ('…e2a272b5' / 'e430d5d932') with the continuation's left edge floating. Two right-aligned fragments of one identifier are harder to read and to compare than a single mid-truncated chip would be, and the pane has the vertical room to give each address its own full-width line.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L4/11",
      "severity": "P3",
      "location": "STATE / EVENT LOG tab strip at y≈676",
      "finding": "The event log is behind a tab while the column beneath it and the transaction pane beside it together hold roughly 650 px of empty height. At 1080 px this is the one viewport where both could be co-visible, so the tab is dropping information the layout has room for.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/12",
      "severity": "P3",
      "location": "EDITOR gutter, the dot column between the line numbers and the code",
      "finding": "The executable/traced-line marker is a single ~2 px low-contrast dot (present on 26–29, 31–32, 42–44, 57; absent on 30, 33, 41, 56). It is the only signal separating traced lines from untraceable ones, which is a first-class fact in this product, and at that size it is easier to miss than to read.",
      "criterion": "B2"
    }
  ]
}
```
