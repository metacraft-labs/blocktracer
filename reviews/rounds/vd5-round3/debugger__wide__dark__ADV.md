Expected elements: present

Presence check passes. The identity bar is slim and carries `← aztec`, the truncated hash, a `Partial` badge and `block 101`; the surface is dark, dense and product-register with no explorer footer or page scrollbar; the editor pane is positioned (line 32 highlighted with a caret marker, matching step 128); the call trace shows seven frames with a selected frame; the state pane carries eleven named values with changed values marked; stepping controls for both directions are visible as a grouped, unmenued cluster; a trace scrubber is present; the transaction pane carries the full hash. No spinner, no empty pane, no light chrome.

The single weakest element is the **trace scrubber in the DEBUG CONTROLS bar** (x≈288–845, vertically centred on the controls row, immediately right of the stepping cluster).

It is the weakest because it is the one required element that does not do its job. It renders as three small filled blocks followed by a long dashed hairline — no thumb, no tick marks, no end labels, and no hit-target shape. You cannot read a position off it; the filled run stops at roughly 6% of the track while the session is at 128 of 1315 (9.7%), so the only thing it does express, it expresses wrongly. Its budget on the row confirms the misjudgement: the scrubber gets about a third of a 1490 px row while the remainder is spent restating the same number twice — the sentence "Step 128 of 1315 …" and, at the far right, "128 / 1315". In the register where density is a virtue, the product's signature position affordance is an ornament and the prose beside it is doing its work.

Severity: P2 (rubric B5 — current-position and state indication).

Rating: n/a (adversarial reviewer).

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "ADV",
  "expectedElements": "present",
  "missing": [],
  "rating": null,
  "findings": [
    {
      "id": "debugger/wide/dark/ADV/1",
      "severity": "P2",
      "location": "DEBUG CONTROLS bar — trace scrubber, x≈288–845, immediately right of the stepping button cluster",
      "finding": "The scrubber is a dashed hairline with three small filled blocks at its left end: no thumb, no ticks, no end labels, no readable hit target. Its filled run ends at roughly 6% of the track while the session sits at step 128 of 1315 (9.7%), so the one thing it expresses it expresses inaccurately, and position has to be read from the prose beside it. It occupies about a third of a 1490 px row whose remaining space restates the same value twice — 'Step 128 of 1315 …' and, right-aligned, '128 / 1315' — so the product's signature position affordance is starved while redundant text is not.",
      "criterion": "B5"
    }
  ]
}
```
