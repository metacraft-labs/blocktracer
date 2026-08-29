Expected elements: MISSING — the `debugger-shell` identity bar (transaction identity, back-link, stepping controls, position readout, phase rail)

That is finding #1, it is P1, and it caps the rating at 4. The cause looks like the capture rather than the build: `views.mjs` clips this view to `.ln.stack`, so the bar is out of frame by construction while the block still inherits `debugger-shell`. The sibling `debugger` capture shows the bar present. I cannot certify presence for something outside the frame, and `present` is the only other value available. Fix in the harness — scope `debugger-shell` out of region-clipped views, or widen the clip. The backbone's other two items are satisfied in frame: dark product-register surface, and the region renders as a pane with no marketing chrome and no page scrollbar.

On density, the numerics are the pane's strongest work and the vertical budget its weakest. The cost column is right-aligned with thousands separators and the unit named once in the header (`ACIR opcodes`), so 11 and 1,315 stay comparable without a per-row unit. Exactly right.

The watch-for measurement: indent step ≈15 px, so at depth 4 the longest label (`calculate_remaining_shield_pct  zk_shields · src/shield.nr`) ends at x≈460 with ~100 px clear before the numbers; extrapolated, names reach the cost column around depth 10–11. The defining tension is never stressed at this fixture.

Highest-priority fixes: (1) the clip/backbone mismatch; (2) 326 px of the 588 px region — 55% — is empty below the footer.

Rating: 4/10

```json
{
  "view": "debugger--call-trace",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger--call-trace__wide__dark.png",
  "reviewer": "L4",
  "expectedElements": "missing",
  "missing": [
    "Inherited backbone `debugger-shell`, item 1 — the slim identity bar carrying the truncated hash and chain, the link back to the transaction detail page, the stepping controls, the position readout and the phase rail. Nothing above the CALL TRACE / EVENT LOG tab strip is in frame; the image begins at the strip."
  ],
  "rating": 4,
  "findings": [
    {
      "id": "debugger--call-trace/wide/dark/L4/1",
      "severity": "P1",
      "location": "above the tab strip (y=0) — the whole area the identity bar would occupy",
      "finding": "The `debugger-shell` identity bar is absent from the frame: the 608x588 image starts at the CALL TRACE / EVENT LOG strip, so the transaction hash, the chain, the back-link, the stepping controls, the position readout and the phase rail are all unverifiable. This reads as a capture defect rather than a build defect — `views.mjs` sets `clip: \".ln.stack\"` for this view with a documented rationale (the panel's own `.panehead` is `display:none` inside the stack, so the strip only appears in a region-level clip), while `expectations.mjs` still lists `inherits: [\"debugger-shell\"]`, whose first item is by construction outside that clip. The sibling `debugger` capture at the same route shows the bar. The mismatch is between the clip and the inherited block, and every one of the six reviewers of this image will hit it. Fix by making `debugger-shell` inheritance conditional on an unclipped capture, or by extending the clip to include the bar."
    },
    {
      "id": "debugger--call-trace/wide/dark/L4/2",
      "severity": "P2",
      "location": "region below the footer row — y 262 to 588, full pane width",
      "finding": "The region is 588 px tall. The tab strip, FRAME header, seven frames and footer occupy y 0-262; the remaining 326 px (55% of the region) is empty. Rows end at y=232, which is 39% down — the block's own must-show names this as the P2 it exists to catch, and it has occurred. The footer compounds it: `Sorted by call order.` / `Sort by cost` sit immediately under the last frame at y=246 rather than pinned to the pane's bottom edge, so the required sort affordance lands stranded in mid-pane and the void beneath reads as unclaimed surface rather than as a pane with room to grow. Either pin the footer to the region's bottom edge so the emptiness reads as headroom, or size the region to its frames with a floor and give the reclaimed height to the Values pane below it, which grows with a frame's locals where the trace does not.",
      "criterion": "B4"
    },
    {
      "id": "debugger--call-trace/wide/dark/L4/3",
      "severity": "P2",
      "location": "frame rows, left edge x 10-62 — `main` (y=69), `iterate_asteroids` (y=94), `calculate_damage` (y=119 and y=195)",
      "finding": "No collapse affordance exists on any frame that has children. `main`, `iterate_asteroids` and both `calculate_damage` frames are parents, and none carries a disclosure triangle, chevron or any other control, so there is no way to fold a subtree and no collapse state to read. Collapse is the primary density control for a call trace; without it a forty-frame trace has no management affordance at all and the pane's only response to depth is to get longer. The nesting guide is thin in the same way: a single vertical rail at x=16 marks every nested row regardless of its depth, so depth 2 and depth 3 are told apart by a 15 px indent alone. B6 asks for indentation *and* a guide, with collapse available and legible; this pane has indentation, one guide rail, and no collapse. Give each depth level its own rail and put a disclosure control in the gutter of every parent frame.",
      "criterion": "B6"
    },
    {
      "id": "debugger--call-trace/wide/dark/L4/4",
      "severity": "P2",
      "location": "the frame list as a whole — seven rows, y 69 to 221",
      "finding": "The fixture is seven frames at a maximum depth of four, in a single module, with costs spanning two orders of magnitude (11 to 1,315). The view's own summary promises the call trace 'at realistic depth and width', and its watch-for asks at what depth frame names stop being readable and whether cost magnitudes stay comparable across orders — neither question is stressed by this data. At 15 px per level the names have room to roughly depth 10, so the answer here is 'not at any depth shown'; there is no scroll behaviour, no repeated-frame recursion, no cost value that would break the column's width, and no volume at which the missing collapse control would bite. A view captured specifically to expose the pane's density limits shows a fixture that stays comfortably inside them, so it cannot fail in the way it was built to detect. Capture this view against a trace with thirty-plus frames reaching depth eight or more, across at least two modules.",
      "criterion": "B3"
    },
    {
      "id": "debugger--call-trace/wide/dark/L4/5",
      "severity": "P3",
      "location": "frame rows — baselines at y 69, 94, 119, 145, 170, 195, 221",
      "finding": "Row pitch is 25.3 px for roughly 12-13 px type, a line-height near 2.0. That is explorer-register rhythm inside a product-register pane: at ~20 px pitch, still comfortable for scanning a column of similar-looking identifiers and still matching the desktop app, the same 588 px region would hold about 22 frames instead of 13. It is P3 rather than P2 only because the region is 55% empty (finding 2), so nothing is currently being pushed out of view by the looseness — the cost lands entirely at volume, where it compounds with the absent collapse control.",
      "criterion": "B1"
    },
    {
      "id": "debugger--call-trace/wide/dark/L4/6",
      "severity": "P3",
      "location": "frame rows, module qualifier column — `zk_shields · src/shield.nr` repeated on the six rows at y 94, 119, 145, 170, 195, 221",
      "finding": "Six of the seven rows carry the identical qualifier `zk_shields · src/shield.nr`, occupying roughly a third of each row's horizontal extent to convey nothing that the row above did not already say. The type hierarchy is correct — the qualifier is dimmer than the bright monospace frame name — so this is a horizontal-budget and texture issue rather than a hierarchy one, and it is P3 at seven rows. At realistic volume, where most frames sit in one or two modules, the repetition becomes the pane's dominant texture and competes with the frame names that are the actual scanning target. The must-show requires the contract/module per frame, so do not drop it; render it only where it differs from the parent frame, or right-align it against the cost column so the varying frame names form one clean left-hand scan.",
      "criterion": "B1"
    }
  ]
}
```
