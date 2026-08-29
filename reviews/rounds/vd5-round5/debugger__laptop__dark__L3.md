Expected elements: present

Every must-show item renders. The identity bar carries chain, truncated hash, back link, both stepping directions, scrubber, readout and phase rail; Code marks line 32 as the pinned position; Call Trace and Event Log share one tab strip with Call Trace open; Values is a separate pane below it; the Transaction pane carries identity. No spinner, no empty pane, no light chrome, no full-width prose band — the `NOIR / Share / Download trace` strip (y 55–82) is the same `#1b1b1b` as the bar above with no divider between them, so it reads as the identity bar wrapping, not a second toolbar.

Chromatically: a competent dark surface with a well-judged syntax palette, undone by a surface ladder that does no work and one hue doing five jobs.

The pane grid runs `#101010 / #161616 / #1b1b1b / #202020` — adjacent steps at 1.05:1, invisible — so every pane boundary rests on a `#3a3a3a` hairline (1.51:1 over `#1b1b1b`) and rows on `#282828` separators (1.13:1), both under the 3:1 non-text floor. Assignment is also unsystematic: the Code body `#101010` is exactly the page canvas and the inter-pane gutter, and the shared `#161616` header sits *above* its body in Code but *below* it in the other three panes.

Indigo `#818cf8` means link, active-tab underline, scrubber fill and "changed value"; the changed values (`9000`, `2000`) land at 5.77:1 against unchanged values at 12.68:1, so the marked datum is the dimmer one.

Fixes: split the indigo token into link / diff / progress roles and lift changed values above unchanged; widen the surface steps or raise borders to ≥3:1, and give the Code body a level distinct from the canvas.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "laptop",
  "theme": "dark",
  "image": "screenshots/debugger__laptop__dark.png",
  "reviewer": "L3",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/laptop/dark/L3/1",
      "severity": "P2",
      "location": "pane grid — borders at x=4, x=686/691, x=1144/1149, x=1435; row separators in Call Trace and Values",
      "finding": "The surface ladder is #101010 / #161616 / #1b1b1b / #202020, with adjacent steps at 1.051, 1.051 and 1.057:1 — no step is perceptible, so pane identity is carried entirely by dividers that are themselves below the 3:1 non-text floor: the pane border #3a3a3a is 1.51:1 over #1b1b1b and 1.67:1 over #101010, and the row separator #282828 is 1.13:1 over #1b1b1b. This is B4's named failure — panes distinguished only by a hairline — with the hairline too faint to distinguish them.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/dark/L3/2",
      "severity": "P2",
      "location": "Code pane body vs page canvas and pane headers (CODE at y=92-110 vs CALL TRACE / VALUES / TRANSACTION headers)",
      "finding": "Surface levels are not assigned systematically. The Code pane body is #101010 — byte-identical to the page canvas (the 4px outer margin) and to the gutter between the Code and nav columns (x=687-690), so the pane has zero surface separation from the page. The other three pane bodies are #1b1b1b. Meanwhile the shared header token #161616 is lighter than the Code body but darker than the other three bodies, so the same header sits raised above its body in one pane and recessed below it in the other three. Elevation therefore has no consistent meaning.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/dark/L3/3",
      "severity": "P2",
      "location": "indigo #818cf8 across: back link '← aztec' (x=12,y=13), 'Sort by cost' (x=1099,y=357), '101:0' (x=1406,y=249), active tab underline (y=137-138 under CALL TRACE), active file tab underline (y=136-137 under src/shield.nr), scrubber played fill (x=687-701), Values changed rows (9000, 2000, and their left edge bars at x=692-694)",
      "finding": "One token, #818cf8, carries five unrelated meanings: 'this is a link', 'this tab is open', 'this file is open', 'this much of the trace has played', and 'this value changed at step N'. A reader cannot tell from colour whether an indigo string in the Values pane is clickable or is a diff marker. §9 names a colour role used for two meanings as below bar; this is five.",
      "criterion": "B5"
    },
    {
      "id": "debugger/laptop/dark/L3/4",
      "severity": "P2",
      "location": "Values pane — rows 'remaining_shield 9000' (y=647) and 'damage 2000' (y=815) vs 'initial_shield 10000' (y=622), 'mass 200' (y=764), 'regeneration 1000' (y=840)",
      "finding": "The changed values are the lowest-contrast text in the pane: #818cf8 on #1b1b1b is 5.77:1, while the unchanged values beside them are #dddddd at 12.68:1. Emphasis is expressed by hue at the cost of luminance, so the two values the reader most needs at this step are less legible than the five that did not move — a hierarchy inversion in the one pane whose job is to mark change.",
      "criterion": "B5"
    },
    {
      "id": "debugger/laptop/dark/L3/5",
      "severity": "P2",
      "location": "identity bar — position readout '128 / 1315' (x=1035-1122) beside 'Engine loading — 18 MB' (x=858-1028)",
      "finding": "The persistent position datum is rendered in the bar's lowest emphasis tier — the whole readout, numerator and denominator alike, is #919191 at 5.47:1 — while the transient loading status immediately to its left is #dddddd at 12.68:1, more than twice the contrast. The number that says where you are in the trace is dimmer than a message that disappears when the engine finishes, and it sits at the same emphasis as tertiary labels like 'BLOCK' and 'Sorted by call order'.",
      "criterion": "B3"
    },
    {
      "id": "debugger/laptop/dark/L3/6",
      "severity": "P2",
      "location": "identity bar — scrubber track, x=687-850, y=8-20",
      "finding": "The unplayed portion of the scrubber is a run of #3a3a3a ticks on the #1b1b1b bar — 1.51:1, half the 3:1 floor for a non-text UI component. Only the ~15px of #a5b4fc/#818cf8 fill at x=687-701 is visible, so the element that expresses position within 1,315 steps reads as a short indigo mark floating in an empty bar rather than as a scrubber with an extent. It is the lowest-contrast component in the identity bar.",
      "criterion": "B5"
    },
    {
      "id": "debugger/laptop/dark/L3/7",
      "severity": "P2",
      "location": "Code pane — current line 32 (y=334-350), gutter number '32' (x=44-66) and the ▶ position marker (x=74-86)",
      "finding": "The current-position glyphs are accent-on-accent: #818cf8 on the #312e81 highlight band is 3.83:1, below the 4.5:1 floor, while the code on the very same row is #f3f3f3 at 10.29:1. The marker and line number — the two elements whose only job is to say 'you are here' — are the least legible things on the row they identify, because the highlight container and the marker were both drawn from the indigo ramp without checking the pair. Non-current gutter numbers manage 5.74:1 against #161616, so the position row is a regression against its own neighbours.",
      "criterion": "B2"
    },
    {
      "id": "debugger/laptop/dark/L3/8",
      "severity": "P2",
      "location": "identity bar — the eight stepping/navigation icon buttons, x=394-668, y=3-25",
      "finding": "All eight icons render at exactly #818181 on #202020 — 4.18:1, identical across the cluster, with no variation between the reverse/forward pair, the step in/out pair and the jump-to-end pair. The expectation block relies on 'the buttons' disabled state' to carry the engine-loading state now that the prose band was removed, but there is no second colour in the cluster for that state to be expressed in: enabled and disabled are indistinguishable. At 4.18:1 the controls that are this product's premise are also the dimmest interactive glyphs on the page. The same token in the light capture is #727272 on #dddddd (3.54:1), which suggests one shared muted-icon value rather than a per-theme tuned pair.",
      "criterion": "B10"
    },
    {
      "id": "debugger/laptop/dark/L3/9",
      "severity": "P3",
      "location": "text ramp — #a2a2a2 (pane titles CODE/VALUES/TRANSACTION, FRAME header, 'Status reason', 'block 101') vs #919191 (BLOCK/CANONICAL/FINALITY labels, call-trace paths, Values type column, 'Sorted by call order')",
      "finding": "The muted end of the ramp has two rungs that do not separate: 6.75:1 versus 5.47:1 on #1b1b1b, a difference invisible at the 11px these are set in. The full ramp is #f3f3f3 / #dddddd / #a2a2a2 / #919191 / #818181 — five declared emphasis levels of which two are the same level in practice, so one of them buys nothing and the ramp is longer than the hierarchy it encodes.",
      "criterion": "B3"
    },
    {
      "id": "debugger/laptop/dark/L3/10",
      "severity": "P3",
      "location": "'Trace ready' chip (x=1210-1305, y=644) vs code comment on line 41 (x=155-680, y=551)",
      "finding": "Two greens from the same family carry opposite intents in one glance: #4ade80 on the chip means 'this succeeded, read it', #22c55e in the Code pane means 'this is a comment, skip it'. The Transaction pane and Code pane are both on screen, so the collision is visible without scrolling.",
      "criterion": "B7"
    },
    {
      "id": "debugger/laptop/dark/L3/11",
      "severity": "P3",
      "location": "Transaction pane status chips — 'Yes' (y=279), 'Safe' (y=311), 'Not observable' (y=553) vs 'Trace ready' (y=644) and 'Partial' (y=129)",
      "finding": "The chip family applies its semantic colours to two of five chips. 'Trace ready' is green and 'Partial' is orange, but 'Yes' (canonical), 'Safe' (finality) and 'Not observable' (a capability limit) all render identically at #919191 on #202020, so two affirmative facts and one limitation share a single neutral treatment. Either the semantic roles extend across the family or the two coloured chips should justify why they are the exceptions.",
      "criterion": "B8"
    }
  ]
}
```
