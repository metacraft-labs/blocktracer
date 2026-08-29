Expected elements: present

Every §4 backbone item is on the image: slim identity bar (hash, chain, back arrow, Partial chip), dark product-register surface, full-viewport session with no explorer footer or page scrollbar, source pane positioned at line 32, seven-frame call trace, eleven-row state pane, eight stepping controls including reverse, a scrubber at 128/1315, and a Transaction metadata pane. No spinner (named phases instead), no empty pane, no light chrome.

As a colour system it is a well-built greyscale shell with almost no designed colour in it. A pixel census: 97.9% of the surface is achromatic; the entire semantic vocabulary — Partial orange, Trace ready green — is 526 px, 0.025% of the screen.

Findings, worst first:

1. The editor viewport (x0–915, y300–1075) contains zero chromatic pixels other than the current-line band. `let`/`if`/`else`, the literals `100` and `0`, the string on line 54 and the comments on 41 and 56 all render at one grey, #dddddd. Half the flagship debugger surface has no editor palette at all (B7).
2. On the selected call-trace row (y≈411) the frame name is #818cf8 on #312e81 = 3.83:1 and its path #919191 on #312e81 = 3.62:1, while every unselected frame name is #f3f3f3 at 15.5:1. The current position is the least legible row in its pane (B5).
3. #818cf8 carries five meanings: link, current-position, changed-value, progress, active tab.

Highest-priority fixes: give the editor the CodeTracer token palette; split the indigo into separate position / link / diff roles.

Rating: 5/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L3",
  "expectedElements": "present",
  "missing": [],
  "rating": 5,
  "findings": [
    {
      "id": "debugger/wide/dark/L3/1",
      "severity": "P2",
      "location": "Editor pane, source viewport (x 0–915, y 300–1075)",
      "finding": "The source has no syntax highlighting whatsoever. A pixel census of the whole editor viewport returns zero chromatic pixels apart from the #312e81 current-line band: keywords (`let`, `mut`, `if`, `else` on lines 26–31), numeric literals (`0`, `100`, `1`), the format string on line 54 and the comments on lines 41 and 56 are all rendered in the identical #dddddd as identifiers and punctuation. Rubric B7 requires 'source in the CodeTracer editor palette' and names 'a generic web highlighter' as the failing case; no highlighter at all is below that bar, and §3 makes the lineage's editor tokens the one constant across both registers. This is the largest single region of the flagship debugger surface and it carries no colour information.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L3/2",
      "severity": "P2",
      "location": "Call Trace pane, selected frame row `calculate_damage` (y ≈ 402–420)",
      "finding": "The current frame is the lowest-contrast row in the pane. Its name renders #818cf8 on the #312e81 selection band = 3.83:1 and its path `zk_shields · src/shield.nr` renders #919191 on #312e81 = 3.62:1 — both below the 4.5:1 floor at ~12 px — while its opcode count stays #dddddd at 8.41:1 and every unselected frame name is #f3f3f3 at 15.52:1. Selecting a frame therefore reduces its legibility relative to its six neighbours, which inverts B5's requirement that where you are is unmistakable. Three different contrast levels coexist on that one row and the two most important of them fail.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/3",
      "severity": "P2",
      "location": "Whole page — accent #818cf8 (identity bar, gutter, State pane, Call Trace footer, Transaction pane, timeline)",
      "finding": "One accent value carries five unrelated meanings, so no instance of it means anything on its own. #818cf8 is: a navigation link (`← aztec`, identity bar); a hyperlink (`101:0` in the Transaction pane and `Sort by cost` at the Call Trace footer, both underlined); the current-position marker (line number 32 in the editor gutter); the changed-value marker (`9000` and `2000` in the State pane, plus their left edge bars); the timeline progress dots (x ≈ 290–320); and the active tab underline (`STATE`). A changed state value is coloured identically to a hyperlink two panes away, so the State pane's only diff signal reads as 'clickable'. There is no dedicated diff role in the theme at all. §9 names 'a colour role used for two meanings' as P2; this is five.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/4",
      "severity": "P2",
      "location": "Debug Controls pane, stepping button group (x 20–265, y 165–200), against identity bar top right (x 1720–1900)",
      "finding": "Colour weight is inverted against importance. All eight stepping glyphs — including the reverse-step control that is the product's stated premise — are a single #818181 on a #202020 fill = 4.18:1, the dimmest interactive elements on the surface, with no hue or luminance distinction between the forward and reverse directions and no enabled/disabled differentiation even though the banner states that stepping is not yet available. Meanwhile `Share` and `Download trace` in the identity bar are white-filled (#f3f3f3 fill, near-black label, ~16:1) and are the two strongest controls on the entire 1920×1080 image. Two ancillary actions carry the maximum colour weight the theme has; the controls the register exists for carry the minimum.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L3/5",
      "severity": "P2",
      "location": "Transaction pane, chip column (Partial y≈162, Yes y≈265, Safe y≈296, Not observable y≈481, Trace ready y≈571)",
      "finding": "Five status chips use three visual treatments with no semantic mapping between them. `Yes` (canonical — positive), `Safe` (finality — a positive assurance) and `Not observable` (a capability limitation) all render as the identical neutral #919191 outline on #202020 at 5.17:1, so 'neutral' means both 'good' and 'this cannot be done'. The two hued chips then contradict each other about the same object at a glance: `Partial` in orange (#fb923c on an #ea580c border) at the top of the pane and `Trace ready` in green (#4ade80 / #16a34a) 400 px below it. A reader scanning the chip column by colour gets caution, nothing, nothing, nothing, success, in that order, and none of the five hues is doing consistent semantic work.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/6",
      "severity": "P2",
      "location": "Debug Controls pane, timeline track (y ≈ 176–188, x 330–850)",
      "finding": "The scrubber track is #282828 on the #1b1b1b pane = 1.17:1, far below the 3:1 non-text contrast floor, so at 1× only the three #818cf8 dots at the far left (x 288–322) are perceivable and the track they sit on is invisible. The element that expresses position within a 1,315-step trace therefore has no visible extent — position has to be read from the text `128 / 1315` instead, which is the fallback the timeline exists to replace. Raising the track to at least 3:1 against the pane costs nothing in density.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/7",
      "severity": "P2",
      "location": "Pane boundaries across the whole layout — Editor / Call Trace / State / Transaction",
      "finding": "The surface ladder is compressed to the point of non-function and is applied inconsistently. Adjacent levels are #101010 / #161616 / #1b1b1b / #202020 — steps of 1.05:1 to 1.10:1. The Call Trace, State and Transaction pane bodies are all #1b1b1b, the exact same value as the identity bar and the page background, so those three panes have zero surface separation from the chrome and are held apart only by a #3a3a3a hairline at 1.51:1 — below the 3:1 non-text floor, which is B4's named failure ('panes distinguished only by a hairline'). The Editor pane body is #161616/#101010, a different level from its three peers for no stated reason, and header treatment does not match across panes: the Editor's header (#161616) is the same value as its own body, while the Call Trace header (#161616) does differ from its body (#1b1b1b).",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L3/8",
      "severity": "P2",
      "location": "Editor pane, row backgrounds and gutter markers (lines 26–58)",
      "finding": "The editor encodes which lines are steppable as a surface tint that cannot be seen. Sampling every row from line 26 to line 58 shows an exact 1:1 correlation: rows carrying the `·` gutter marker are #161616, rows without it are #101010 — a contrast of 1.05:1. The `·` marker itself is roughly #3a3a3a on #161616, about 1.6:1. Both signals for the editor's one debugger-specific affordance sit below perceptual threshold at 1×, where the tint reads as accidental zebra striping rather than as coverage information. Either it is a meaningful state that no one can perceive, or it is decoration adding noise to a code pane; both are colour-system faults.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/9",
      "severity": "P3",
      "location": "Whole page — palette provenance",
      "finding": "The theme reads as a carefully built greyscale shell with default accents dropped into it rather than as a designed palette. Every neutral is perfectly achromatic (r=g=b at #101010, #161616, #1b1b1b, #202020, #282828, #3a3a3a, #919191, #a2a2a2, #dddddd, #f3f3f3) with no hue temperature, while all four accents are exact stock utility-framework tokens — #818cf8 (indigo-400), #312e81 (indigo-900), #fb923c/#ea580c (orange-400/600), #4ade80/#16a34a (green-400/600). 97.9% of the surface is achromatic and the whole semantic vocabulary occupies 526 px, 0.025% of the image. §2 states the accent hue family is shared across both registers; nothing here ties the accent to a product hue family rather than to a framework default.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L3/10",
      "severity": "P3",
      "location": "Identity bar `← aztec` (x 22–78) versus Transaction pane `101:0` (x ≈ 1862–1910) and Call Trace footer `Sort by cost` (x ≈ 1448–1520)",
      "finding": "The link role has two treatments. `101:0` and `Sort by cost` are #818cf8 with an underline; `← aztec` is the same #818cf8 with no underline. Since #818cf8 is also used for non-interactive things (changed values, the current line number), the underline is currently the only reliable indicator of interactivity, and the page's one navigation-out affordance is the element that lacks it.",
      "criterion": "B5"
    }
  ]
}
```
