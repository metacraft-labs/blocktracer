# debugger · laptop · light · ADV

Expected elements: present

Presence check passes on every item. The identity bar is slim and real (`← aztec · 0xb63616…6359 · Partial · block 101`, with NOIR / Share / Download trace at the right); the session fills 1440×900 below it with no explorer footer, no marketing chrome and no page scrollbar. The surface is product register despite being the light theme — 22–25 px rows, mono throughout, hairline pane borders, no marketing padding — so this is a designed light tool theme, not an explorer-register leak. Source pane shows a current position (line 32, blue row + ▶ gutter marker at x≈76, y≈458) that corresponds to the highlighted `calculate_damage` frame in the call trace; call trace has 7 frames; STATE has 11 values; eight stepping controls including reverse are visible at x≈14–265, y≈158–188; the TRANSACTION pane carries the identity. Nothing forbidden: no spinner (the three named phase chips are the honest treatment), no empty pane, no light explorer chrome.

**The single weakest element: the timeline/scrubber in the DEBUG CONTROLS row.** It sits at x≈286–459, y≈164–180 — a 173 px track only ~5 px tall, drawn as pale grey dots (visually near 2:1 against the white pane) with an ~18 px filled head in a different mark language (solid blue bars, not filled dots), so the elapsed portion does not read as the same track. This is the control for the one thing the product exists to do — move through 1,315 steps — and it is the faintest, smallest object on the screen.

What makes it a rubric failure rather than a taste note is what it was starved *by*. The same row spends x≈474–1046 on "Step 128 of 1315 — stepping starts when the replay engine finishes loading (18 MB)", which restates the banner sentence 90 px directly above it ("Stepping starts once the replay engine loads — 18 MB, fetched once and cached."), and then spends x≈1055–1131 on "128 / 1315", restating the step count already printed 580 px to its left in the same row. The pane is 1,135 px wide and roughly 650 px of it goes to saying the same two facts three times, while the position control gets 173 px. That is B1 inverted: space spent where it buys nothing, and withheld from the element that would buy the most.

Fix: collapse the duplicated sentence and the trailing `128 / 1315` into one label and give the reclaimed width to the scrubber, with a taller track, ticks and a single consistent mark for filled and unfilled.

Rating: n/a (adversarial reviewer)

```json
{
  "view": "debugger",
  "size": "laptop",
  "theme": "light",
  "reviewer": "ADV",
  "expectedElements": "present",
  "missing": [],
  "rating": null,
  "findings": [
    {
      "id": "debugger/laptop/light/ADV/1",
      "severity": "P2",
      "location": "DEBUG CONTROLS pane, timeline/scrubber at x≈286–459, y≈164–180, and the status text to its right at x≈474–1131",
      "finding": "The trace scrubber — the control for the product's core act of moving through 1,315 steps — is a 173 px track only ~5 px tall in pale low-contrast grey dots, with its filled head drawn as solid blue bars rather than filled dots, so elapsed and remaining do not read as one track. It is starved by duplication in its own row: x≈474–1046 restates the banner sentence 90 px above it ('stepping starts when the replay engine finishes loading (18 MB)' vs 'Stepping starts once the replay engine loads — 18 MB, fetched once and cached.'), and x≈1055–1131 restates the step count already printed at x≈474 as '128 / 1315'. Roughly 650 px of an 1,135 px pane says two facts three times while the position control gets 173 px.",
      "criterion": "B1"
    }
  ]
}
```
