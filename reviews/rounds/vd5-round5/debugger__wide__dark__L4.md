Expected elements: present

All ten MUST SHOW items are present and no MUST NOT item is: identity bar with both stepping directions, Code pane positioned at line 32, Call Trace and Event Log as one tabbed region with Call Trace open, a seven-frame trace, a `Values` pane below the tabs (not a third tab), scrubber, and identity in both bar and Transaction pane. As a density surface it is close to the desktop app's vocabulary but spends its two scarcest resources — Code-pane width and navigation-column height — in the wrong places.

The measurement the watch-for asks for: the tabbed region is 580 px tall (y 93–673) and holds 245 px of content, so **320 px — 55% — is empty below "Sorted by call order."** The Values pane below is 396 px with ~115 px (29%) empty. The height belongs to Values, which is the pane that grows with trace depth; the call trace should size to its frames.

Meanwhile the Code pane clips code. Lines 40, 53 and 64 are cut mid-identifier (`shield_regen_perce`) at x=915 with no ellipsis, fade or scrollbar on either axis, while 23 px line pitch at ~14 px type yields only 40 rows in 990 px. The Transaction column clips too (`"contract": "0x1b31c04d5920b0b5936f12`) and wraps FEE PAYER/TARGET mid-hash 30/10.

Highest-priority fixes: (1) give the Code pane the ~60 px the metadata column can spare and add a scroll/truncation affordance; (2) let Values take the navigation column's spare 320 px.

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
      "location": "Code pane, right edge (x≈915), lines 40, 53, 56 and 64",
      "finding": "Code lines are cut at the pane's right edge mid-identifier — line 40 ends `shield_regen_perce`, line 53 ends `damage: Field, r`, line 64 loses its terminating `;` — with no ellipsis, no fade, no horizontal scrollbar and no vertical scrollbar either, so nothing tells the reader the listing continues in either direction. A signature the reader cannot finish is dropped information, not compressed information. Fix by widening the pane (see finding 4) and marking the overflow.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/2",
      "severity": "P2",
      "location": "navigation column — Call Trace tabbed region (y 93–673) versus Values pane (y 683–1078)",
      "finding": "The tabbed region is 580 px tall and holds 245 px of content (tab strip, FRAME header, 7 frames, footer row), leaving 320 px — 55% of the region — empty below 'Sorted by call order.' The Values pane below it is 396 px with 12 rows and ~115 px (29%) spare. The fixture's seven frames do not earn three fifths of the column; the Values pane is the one that grows without bound as a frame's locals accumulate, and it is the pane that should take the slack. Size the tabbed region to its frames with a floor, and give the remainder to Values.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L4/3",
      "severity": "P2",
      "location": "Code pane, code listing (line 26 at y≈166 through line 65 at y≈1066)",
      "finding": "Line pitch is 23.1 px for ~14 px monospace — a 1.65 line-height that yields 40 rows in 990 px of pane. The listing is already windowed (it starts at line 26 and runs past 65 at the viewport edge), so the padding is being paid for out of code the reader cannot see. At ~20 px pitch, still comfortable for the desktop app's density, the same pane shows ~46 lines.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/4",
      "severity": "P2",
      "location": "Transaction pane, RAW (CHAIN-NATIVE) block (x 1548–1900, y 745–1010)",
      "finding": "The chain-native JSON is pretty-printed at 2-space indent inside a 350 px column, so it spends 265 px on eleven short lines and still clips the only substantive value in it — `\"contract\": \"0x1b31c04d5920b0b5936f12` is cut at the box edge with no indicator, exactly as in the Code pane. A wrapped or flattened rendering would show the whole address in less height.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/5",
      "severity": "P2",
      "location": "identity bar, centre cluster (scrubber x 688–955, 'Engine loading — 18 MB' x 963–1120, '128 / 1315' x 1130–1220)",
      "finding": "The position readout is separated from the scrubber it reads out by the engine status label, and it is rendered dimmer than that label — the transient loading string is the brightest text in the cluster while `128 / 1315`, the most important number on a debugger surface, is mid-grey. The cluster reads as three unrelated objects rather than one position control. Put the readout adjacent to the scrubber and give it the higher emphasis level.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L4/6",
      "severity": "P2",
      "location": "Transaction pane, FEE PAYER and TARGET rows (y 299–380)",
      "finding": "Both 40-hex values wrap after 30 characters onto a ragged 10-character second line (`…e2a272b5` / `e430d5d932`), breaking mid-byte-run at a boundary with no meaning, and costing a row each. The same pane fits a full 42-character hash on one line at y=165, so the label/value two-column split is what forces the wrap. Break at a byte boundary or give these values their own full-width row under the label.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L4/7",
      "severity": "P2",
      "location": "Transaction pane, DECODED INPUT block (SELECTOR / RAW rows and the paragraph at y 650–710)",
      "finding": "Roughly 200 px — a section header, two rows and a three-line paragraph — conveys two empty values, both shown as `0x`. The paragraph states that 'the parameters are shown as raw bytes', but the RAW row shows no bytes, so the densest column on the page spends its most expensive vertical space explaining a decode that has nothing to decode. Collapse to one row when calldata is empty and drop the paragraph in that case.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L4/8",
      "severity": "P2",
      "location": "Call Trace pane, frame rows y 155–320 (path suffixes and the 'ACIR opcodes' header)",
      "finding": "The text that disambiguates frames is the smallest and lowest-contrast text in the pane: `calculate_damage` appears twice and `calculate_remaining_shield_pct` twice, and what separates them is the dim `zk_shields · src/shield.nr` suffix and the right-aligned opcode count under a dim `ACIR opcodes` header. Six of the seven rows repeat that identical suffix, so the low-contrast text is simultaneously redundant and load-bearing, and it consumes the horizontal room that indentation and the opcode column will need at realistic depth. Hoist the common module path to the pane header and show only the differing part per row, at a readable emphasis level.",
      "criterion": "B2"
    },
    {
      "id": "debugger/wide/dark/L4/9",
      "severity": "P2",
      "location": "identity bar, stepping controls (x 390–670)",
      "finding": "Eight icon-only buttons sit in four visually identical capsules with equal gaps, no labels and no keyboard shortcut hints. Two adjacent pairs of small monochrome arrow glyphs (◀▶, ↖↘, |←→|, ⏮⏭) are not distinguishable at a glance, and B10 expects keyboard affordances to be indicated. Add shortcut letters or a hint row; the space exists in the bar.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L4/10",
      "severity": "P3",
      "location": "Code pane header stack (y 68–155)",
      "finding": "Three chrome rows — the `CODE` title, the file tab strip, and the windowing notice 'Showing from line 26 — the session's position is below…' — occupy ~90 px, about four lines of code, before the listing starts; the neighbouring region spends two rows on the same job because its tab strip carries the title. The notice also restates what the highlighted row already shows. Merging the title into the tab strip and compressing the notice to a short marker on the first row would return two lines of code without removing the disclosure.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L4/11",
      "severity": "P3",
      "location": "Values pane header (y 697)",
      "finding": "The header is the bare word VALUES with no scope — no frame name, no step number. The values shown belong to the selected `calculate_damage` frame, but that name appears twice in the trace, so the pane's binding is recoverable only by looking at which row is highlighted two panes over. Appending the frame and step to the header costs no rows.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L4/12",
      "severity": "P3",
      "location": "Values pane, `masses` row (y 798) and `masses[2]` row (y 823)",
      "finding": "An eight-element array is printed inline in full and then one element, `masses[2]`, is repeated as an indented child row with no expander or collapse control on the parent, so the reader cannot tell whether the other seven children are hidden or simply absent. Give the array row a disclosure control whose state is legible.",
      "criterion": "B6"
    }
  ]
}
```
