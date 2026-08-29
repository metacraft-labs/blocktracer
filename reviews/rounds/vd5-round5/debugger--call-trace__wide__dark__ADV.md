Expected elements: present

Presence check passes. The capture is region-clipped to `.ln.stack` (608×588), so the inherited `debugger-shell` backbone items — identity bar, stepping controls, phase rail, sibling panes, absence of explorer chrome — are out of frame by construction and are not judged here; they belong to the `debugger` full-viewport view. Everything the block requires *of this region* is present: the tab strip names CALL TRACE and EVENT LOG with CALL TRACE marked open; the tree reaches four levels (`main` → `iterate_asteroids` → `calculate_damage` → `calculate_remaining_shield_pct`) with indent guides, not indentation alone; each frame carries name plus `zk_shields · src/shield.nr`; the `ACIR opcodes` column is right-aligned with one unit and thousands separators throughout; the current frame is filled indigo, unmistakable; `Sorted by call order.` / `Sort by cost` supplies the ordering affordance.

The single weakest element is the **empty lower half of the call-trace region, below the `Sorted by call order.` footer row (roughly y≈262 to y≈588 of 588 — about 55% of the region's height)**. This region was given the largest weight in the column precisely because it is the session's primary navigation surface, and it spends 40% of that grant on seven rows and then stops. The footer strip does not even anchor to the pane's bottom edge; it floats directly under the last frame, so the ordering control sits mid-pane with a void beneath it and the pane reads as a short list dropped into a tall box rather than as the surface that outranks its siblings. This is the outcome the must-show item names in advance — rows ending in the first third of a mostly empty region — and it is the one thing on this frame that a CodeTracer user would notice before anything else. P2.

```json
{
  "view": "debugger--call-trace",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger--call-trace__wide__dark.png",
  "reviewer": "ADV",
  "expectedElements": "present",
  "missing": [],
  "rating": null,
  "findings": [
    {
      "id": "debugger--call-trace/wide/dark/ADV/1",
      "severity": "P2",
      "location": "call-trace region, below the 'Sorted by call order. / Sort by cost' footer row — approximately y=262 to y=588 of the 588px clip",
      "finding": "About 55% of the region's height is empty below the last frame, and the footer strip carrying the only ordering control floats directly under the last row instead of anchoring to the pane's bottom edge. The region was allotted the column's largest weight as the session's primary navigation surface but fills only its first ~40%, so it reads as a short list dropped into a tall box rather than the pane that outranks its siblings. This is the failure the must-show item names in advance: rows ending in the first third of a mostly empty region.",
      "criterion": "B4"
    }
  ]
}
```
