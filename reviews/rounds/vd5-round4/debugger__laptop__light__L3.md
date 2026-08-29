# debugger · laptop · light · L3 (colour, contrast and theme)

Expected elements: present

Presence check passes. The identity bar (y 0–63) carries `← aztec`, `0xb63616…6359`, a `Partial` badge and `block 101`; the session fills the viewport with no footer or page scrollbar; line 32 is the pinned position; the call trace shows seven frames; the state pane ten values; eight stepping controls including reverse; a scrubber sits at x 285–460. No spinner, no empty pane, no explorer header/nav/footer — the surface is dense and tool-shaped, so I do not read the light theme as an explorer-register marketing surface.

But it is not a *designed* product-register light theme either. Measured, the whole page is seven fully desaturated neutrals plus three stock tint pairs; contrast is uniformly strong (every text pair 6.29:1–19:1) yet the colour system does almost no semantic work. The source pane has no syntax highlighting at all — a saturation scan of the entire code body (x 70–683, y 305–890) returns 60 chromatic pixels, all from the line-32 rail. Meanwhile one indigo carries six meanings, and the eight stepping controls sit at 3.54:1, the faintest pair on the page, on the product's premise.

Highest-priority fixes: (1) give the editor the CodeTracer token palette — Design-System §7 makes this the one sanctioned crossing and it is simply absent; (2) split the indigo, so current-position, changed-value and interactive are not one token.

Rating: 5/10

```json
{
  "view": "debugger",
  "size": "laptop",
  "theme": "light",
  "image": "screenshots/debugger__laptop__light.png",
  "reviewer": "L3",
  "expectedElements": "present",
  "missing": [],
  "rating": 5,
  "findings": [
    {
      "id": "debugger/laptop/light/L3/1",
      "severity": "P2",
      "location": "EDITOR pane, code body x 70–683, y 305–890 (lines 26–51)",
      "finding": "The source has no syntax highlighting whatsoever. Keywords (let, mut, if, else, fn, as), types (Field, u32), numerals (100, 0, 1) and the line-41 comment '// shields regain a percentage of the maxium capacity' all render at one flat #242424. A saturation scan of the whole code body finds 60 chromatic pixels, every one of them indigo bleed from the line-32 rail. Design-System §7 and brief §3 make the CodeTracer editor palette the one sanctioned register crossing; here there is no editor palette to cross with. The clearest cost is that a comment is indistinguishable from executable code.",
      "criterion": "B7"
    },
    {
      "id": "debugger/laptop/light/L3/2",
      "severity": "P2",
      "location": "whole page — indigo #4F46E5 at: '← aztec' (x 24–76, y 31), 'Sort by cost' (x 1063, y 443), '101:0' (x 1381, y 235), line-32 rail and line number (x 5–6, y 446–469), selected call-trace rail and frame name (x 692–693, y 381–405), changed-value rails and values '9000' / '2000' (x 692–693; y 623–646, y 790–813)",
      "finding": "One accent hue carries six distinct meanings: navigation link, action link, active loading phase, current position, row selection, and changed-since-last-step. The 2 px indigo left rail specifically means 'current line' in the editor, 'selected frame' in the call trace and 'value changed' in the state pane — three different things, one identical token. The only secondary differentiator is an underline, and it is applied to two of the three links ('Sort by cost', '101:0') but not to '← aztec'. In a debugger the current-position role and the diff role are the two that must never be confusable, and here they are the same colour at the same width in adjacent panes.",
      "criterion": "B5"
    },
    {
      "id": "debugger/laptop/light/L3/3",
      "severity": "P2",
      "location": "DEBUG CONTROLS pane, the eight stepping buttons at x 18–267, y 159–187",
      "finding": "Glyph #727272 on face #DDDDDD measures 3.54:1, and the face against the white pane behind it measures 1.36:1. That is the lowest contrast pair on the page by a wide margin — every other text-on-surface pair I measured lands between 6.29:1 and 19:1 — and it lands on the controls this product's premise depends on. If the grey is the disabled state (the banner says stepping has not started), disabled is not legible AS a state: there is no enabled control anywhere on screen to read it against, so the cluster reads as low-quality rather than as deliberately inactive.",
      "criterion": "B2"
    },
    {
      "id": "debugger/laptop/light/L3/4",
      "severity": "P2",
      "location": "EDITOR pane header (y 205–229) against its code body (y 260–890), compared with the CALL TRACE / STATE / TRANSACTION pane headers",
      "finding": "The editor's header bar and its code body are both #F3F3F3, so the pane header separates from its own content only by a #C8C8C8 hairline. Every other pane puts an #F3F3F3 header over a #FFFFFF body, so the surface step exists in three panes and is missing in the one that most needs it. #F3F3F3 is simultaneously the phase banner (y 63–120), all five pane headers, the editor tab strip, the editor code surface, and the neutral badge fill — one tone doing five structurally unrelated jobs, which is why the pane grid reads as flat.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L3/5",
      "severity": "P2",
      "location": "page-wide palette — neutrals #FFFFFF, #F3F3F3, #ECECEB, #DDDDDD, #C8C8C8, #A2A2A2, #242424; accents indigo-100/500/600, orange-100/800 ('Partial'), green-100/800 ('Trace ready')",
      "finding": "The theme reads as inherited rather than designed for this register. Every neutral is fully desaturated stock grey and every accent is a default framework tint pair; there is no editor background tone, no gutter tone, no distinct diff hue set, and no tool-surface colour that a CodeTracer desktop user would recognise. The result is the explorer register's light palette mapped onto a tool layout: correct density, correct pane vocabulary, but a colour system with only three hues and no roles of its own. Contrast is not the problem here — semantics are.",
      "criterion": "B9"
    },
    {
      "id": "debugger/laptop/light/L3/6",
      "severity": "P3",
      "location": "EDITOR pane, shaded lines 30, 33, 35, 36, 38, 39, 41, 45, 47",
      "finding": "Lines with no executable step are tinted #ECECEB against the #F3F3F3 line background — a measured 1.065:1, below any perceptual threshold on a display. The state is actually carried by the ~3 px indigo gutter dot on the other lines, so no information is lost, but a surface level has been spent on a signal it cannot deliver, and at closer inspection it reads as arbitrary zebra striping in a code pane rather than as a state.",
      "criterion": "B5"
    },
    {
      "id": "debugger/laptop/light/L3/7",
      "severity": "P3",
      "location": "TRANSACTION pane — 'Yes' (canonical, y 255–277), 'Safe' (finality, y 286–308), 'Not observable' (y 528–550), 'Trace ready' (y 618–641)",
      "finding": "Four badges of identical shape in one pane, with no readable rule for which get colour. 'Trace ready' is green fill on a green border; 'Yes' and 'Safe' — equally affirmative facts — take the same neutral #F3F3F3 fill as 'Not observable', which is the one genuinely negative fact in the group. Grey therefore means both 'confirmed' and 'unavailable' four rows apart.",
      "criterion": "B5"
    },
    {
      "id": "debugger/laptop/light/L3/8",
      "severity": "P3",
      "location": "EDITOR gutter, line 32: rail and line number at x 5–48 versus the ▶ arrow at x 76–86, y 452–464; and the timeline fill at x 287–305, y 163–182",
      "finding": "The single current-position marker is built from two tints of the same hue: the rail and the line number are #4F46E5, the ▶ arrow two characters away is #6366F1. The timeline's filled bars and the steppable-line gutter dots are also #6366F1 while every other accent on the page is #4F46E5. Two indigos are in use with no rule assigning them.",
      "criterion": "B7"
    },
    {
      "id": "debugger/laptop/light/L3/9",
      "severity": "P3",
      "location": "DEBUG CONTROLS pane, unfilled scrubber track x 307–460, y 172",
      "finding": "The dotted remainder of the track is #A2A2A2 on white — 2.55:1, under the 3:1 floor for a meaningful graphical object. It is the element that expresses how much of a 1,315-step trace is left, and it renders fainter than every hairline rule on the page.",
      "criterion": "B2"
    }
  ]
}
```
