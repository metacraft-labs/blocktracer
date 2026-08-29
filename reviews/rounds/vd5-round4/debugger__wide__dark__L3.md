# debugger · wide · dark · L3 — Colour, contrast and theme

Expected elements: present

All backbone items are on the image: slim identity bar (y 0–62) with `← aztec`, `0xb63616…6359`, an orange `Partial` chip and `block 101`; a dark product-register surface with no explorer chrome, no footer and no page scrollbar; editor pane with the current line marked at line 32; call trace with seven frames; STATE pane with eleven values; eight stepping controls including reverse (`◀`, x≈22–42); a scrubber at x 288–845; and the full transaction identity in the right-hand pane. No spinner, no empty pane, no light chrome.

The theme is designed, not inverted: a real four-step text ramp (#f3f3f3 / #dddddd / #a2a2a2 / #919191) and an accent tuned per surface (indigo-900 fill, indigo-400 text, indigo-300 on the timeline). Most text-on-surface pairs land 5–16:1. Two things undo it — the accent means five different things, and the surface ladder is inert.

The worst pair on the page is the one that matters most: the selected call-trace frame renders `calculate_damage` in #818cf8 on the #312e81 fill at **3.83:1**, its path at **3.62:1** — while the *identical* #312e81 fill under editor line 32 keeps #f3f3f3 at 10.29:1. The current position is the least legible text on a screen where nothing else falls below 4.8:1.

The editor body carries **no syntax colour at all**: across 825×770 px of Noir source the only saturated pixels are the current-line fill. Keywords, strings, numbers, comments and function names are all #f3f3f3, so B7's "CodeTracer editor palette" is absent rather than generic.

Highest-priority fixes: (1) white the selected frame's text like the editor's selected line; (2) ship the editor token palette.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "reviewer": "L3",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/dark/L3/1",
      "severity": "P2",
      "location": "Call trace pane, selected frame row (x 929–1520, y 403–420)",
      "finding": "The current frame's name renders #818cf8 on the #312e81 selection fill at 3.83:1 and its path 'zk_shields · src/shield.nr' at 3.62:1 — both below the 4.5:1 floor at ~12px, and the lowest-contrast text anywhere on the page. The identical #312e81 fill under editor line 32 keeps its text at #f3f3f3 / 10.29:1, so one selection surface is given two opposite text treatments in adjacent panes.",
      "criterion": "B2"
    },
    {
      "id": "debugger/wide/dark/L3/2",
      "severity": "P2",
      "location": "Editor pane body (x 90–915, y 305–1075)",
      "finding": "The source has no syntax colour at all. Sampling the whole code body, the only saturated pixels are the #312e81 current-line fill: keywords (let, fn, if, else), the string literal on line 54, numeric literals, the comments on lines 41 and 56 and every function name are all rendered #f3f3f3. B7 asks for the CodeTracer editor palette and §3 makes source colouring the one sanctioned register crossing; here it is monochrome, which is further from the desktop app than a generic highlighter would be.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L3/3",
      "severity": "P2",
      "location": "Whole screen — timeline (x 288–336), banner pill (x 652–905, y 79–99), editor line 32, call trace selected row, STATE values '9000' (y 732) and '2000' (y 883), links '← aztec' (x 22–78), '101:0' (x 1863–1908), 'Sort by cost' (x 1448–1519)",
      "finding": "One indigo family carries five unrelated meanings. #312e81 is simultaneously the current source line, the selected call frame and the active loading-phase pill; #818cf8 is simultaneously hyperlink, changed-value marker and the selected frame's own text; #a5b4fc is the elapsed timeline. Since these are the only chromatic elements on the surface apart from two status chips, 'blue' carries no information — a reader cannot tell from colour whether '9000' in the STATE pane is a link or a changed value, and the loading banner's active phase reads as a position marker.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/4",
      "severity": "P2",
      "location": "Timeline scrubber, unelapsed track (x 336–845, y 176–188)",
      "finding": "The unelapsed portion of the trace is drawn as #3a3a3a dashes on the #1b1b1b pane body — 1.51:1, far below the 3:1 floor for a graphical object that carries meaning. Four bright #a5b4fc pills show the 128 steps taken and the remaining 1,187 are almost invisible, so the scrubber reads as a short bar with a smudge after it rather than as position-within-1,315.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L3/5",
      "severity": "P2",
      "location": "All four panes — gutter between panes (e.g. x 916–920), pane header bars ('DEBUG CONTROLS' y 121–147, 'CALL TRACE' y 222–248, 'TRANSACTION' y 121–147) against their bodies",
      "finding": "The surface ladder does no work: page gutter #101010, pane header #161616, pane body #1b1b1b, chip #202020 — a mechanical +5 ramp whose largest step is 1.17:1 and whose header-to-body step is 1.05:1. Internal row rules are #282828 at 1.17:1. Every pane boundary therefore rests on a single 1px #3a3a3a border at 1.67:1 against the gutter, which is B4's named failure ('panes distinguished only by a hairline'). The header bars in particular do not read as a distinct surface level, only as text above a faint rule.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L3/6",
      "severity": "P3",
      "location": "Transaction pane, chips at CANONICAL 'Yes' (y 258–272), FINALITY 'Safe' (y 290–304) and EXECUTIONS 'Not observable' (y 474–488)",
      "finding": "The neutral #919191-on-#202020 chip carries two opposite meanings 200px apart: an affirmative registry fact ('Yes', 'Safe') and an unavailable capability ('Not observable'). Since 'Trace ready' just below it is green and 'Partial' above is orange, the reader has learned that chip colour is semantic, and the grey then means both things.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L3/7",
      "severity": "P3",
      "location": "Identity bar, truncated hash '0xb63616…6359' (x 93–204, y 24–40)",
      "finding": "The hash is #f3f3f3 with no underline and no link hue, identical to the 'Share'/'Download trace' label colour, while the only link-coloured element in the bar is '← aztec' (#818cf8). Nothing in the bar is coloured as a route back to the transaction detail page; the one link affordance present is labelled with the chain.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L3/8",
      "severity": "P3",
      "location": "Identity bar, right end — 'Share' (x 1722–1770) and 'Download trace' (x 1782–1900)",
      "finding": "Both buttons are #f3f3f3 text on #1b1b1b inside a #3a3a3a border — pixel-identical treatments for a light secondary action and the session's export. No colour, fill or border weight separates them, and neither is distinguished from the surrounding bar by more than a 1.67:1 outline.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L3/9",
      "severity": "P3",
      "location": "Editor pane row striping (e.g. lines 27/28 at y 399–445) and the two low text levels (#a2a2a2 banner prose y 71–107 vs #919191 transaction labels y 225–305)",
      "finding": "Two ladder steps are too small to function. The editor's zebra striping alternates #101010 and #141414 at 1.03:1, spending a surface level for no scanning benefit; and the secondary (#a2a2a2) and tertiary (#919191) text levels sit 1.24:1 apart while doing different jobs (pane titles and prose vs field labels and inactive tabs), so the emphasis ramp is effectively three levels, not four.",
      "criterion": "B2"
    }
  ]
}
```
