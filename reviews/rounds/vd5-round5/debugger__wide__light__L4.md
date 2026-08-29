Expected elements: present

Call Trace and Event Log are one tab strip with Call Trace open, Values is a separate pane below it, stepping runs both directions in the identity bar, and nothing is empty, spinning or banded. Small-text legibility is genuinely good: measured cap-heights 8–10 px (≈11–13 px type) at 7.3:1 minimum contrast, code at 22.9 px pitch. The failure is allocation, not legibility — space is spent where it buys nothing and withheld where it would.

The tabbed region is 588 px tall; frames end at y=345 and 334 px (57%) sits blank to the pane border at y=679, while the Code pane clips `fn calculate_shield_regeneration(…shield_regen_perce` at x=918 and the 383 px Transaction pane wraps 42-char addresses mid-hash. Neither the call trace nor Values needs that height at this fixture, and the EVENT LOG tab shows no count, so the render cannot justify the allocation it made.

The identity bar reads as a strip of unrelated objects: six of its seven boundaries are the identical 16–17 px (hash|Partial, Partial|block, buttons|scrubber, scrubber|status, status|phase rail), and the only large gap — 196 px at x1479–1675 — falls at the one boundary needing no emphasis. Its widest object, the 260 px scrubber, has no ticks, no scale and no depth or event markers; it restates "128 / 1315" printed 17 px to its right.

Highest-priority fixes: size the tabbed region to content and give the surplus to the Code pane's measure; put ticks or call-depth on the scrubber, or shrink it and group the bar.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "light",
  "image": "screenshots/debugger__wide__light.png",
  "reviewer": "L4",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/light/L4/1",
      "severity": "P2",
      "location": "middle column, tabbed Call Trace region, y 345–679",
      "finding": "334 px of the region's 588 px height — 57% — is empty below the 'Sorted by call order.' footer. The seven frames occupy y 156–345 (189 px, 32%). The region is given three fifths of the column height for content that fills a third of it, while the Code pane clips lines horizontally and the Transaction pane wraps addresses. Neither the call trace nor the Values pane below (which is itself 122 px short of its 391 px box) needs the surplus at this fixture; the only claimant is the Event Log, and its tab carries no count, so the render offers no evidence the height is earned. Size the region to content.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/light/L4/2",
      "severity": "P2",
      "location": "identity bar, x 202–1675",
      "finding": "The bar reads as a strip of unrelated objects rather than groups. Six of the seven boundaries are the same 16–17 px: hash|Partial 17 px, Partial|block-101 16 px, block|divider 16 px, buttons|scrubber 16 px, scrubber|status 17 px, status|phase-rail 17 px. Only the step-button pairs get a tighter 10 px, and one divider rule (x=377) is used once, between identity and controls. Meanwhile the single large gap — 196 px at x1479–1675 — separates the phase rail from NOIR, the boundary that needed the least emphasis. Proximity is carrying no grouping information anywhere in the densest strip on the page.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/light/L4/3",
      "severity": "P2",
      "location": "identity bar, scrubber, x 687–947",
      "finding": "The scrubber is the widest single object in the bar at 260 px and expresses one scalar — a 22 px fill, 8.5%, correctly proportional to 128/1315 — that is already printed as '128 / 1315' seventeen pixels to its right. It has no tick labels, no scale, no phase boundaries, no call-depth profile and no event density; the ~55 dots imply a resolution of 24 steps each that is not real, and the playhead is a ~5 px tick. 260 px of the identity bar buys nothing the adjacent number does not already give.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/light/L4/4",
      "severity": "P2",
      "location": "Call Trace pane, frame column, rows 2–7",
      "finding": "'zk_shields · src/shield.nr' repeats identically on six of the seven rows, consuming roughly 40% of each row's width on a constant. Worse for scanning under load: rows 3 and 6 are byte-identical — same name calculate_damage, same path, same cost 63 — and rows 4 and 7 likewise (calculate_remaining_shield_pct, 11). At realistic recursion depth the frames carry no per-frame disambiguator (call index, step number, iteration), so the only thing distinguishing one occurrence from another is which row happens to be selected.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/light/L4/5",
      "severity": "P2",
      "location": "Transaction pane, RAW (CHAIN-NATIVE) block, the \"contract\" line, y≈831",
      "finding": "The JSON hard-clips at the container's right edge — '\"contract\": \"0x1b31c04d5920b0b5936f12' stops flat with no ellipsis, no fade and no horizontal scrollbar — on the one payload the spec requires verbatim. The Code pane 1500 px to the left handles the same overflow with a deliberate fade (line 40, 'shield_regen_perce'). Two different overflow treatments in one viewport, and the harsher, affordance-free one is applied to the payload a visitor is most likely to want to copy whole.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/light/L4/6",
      "severity": "P2",
      "location": "Transaction pane, DECODED INPUT block, y 591–724",
      "finding": "About 130 px of the densest pane on the page is spent on the absence of data: a SELECTOR row whose entire value is '0x', a RAW row whose entire value is '0x', and a three-line proportional paragraph set at ~21 px leading for ~13 px type (1.6) — visibly looser than the 25 px data rows elsewhere and the loosest text in the product register. This is B1's named failure mode, marketing-grade padding in a pane, and it is occurring in the pane that has the least width to spare.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/light/L4/7",
      "severity": "P2",
      "location": "Code pane, current line 32 at y 292–314 within a window running y 161–1075",
      "finding": "The extra rows the full-height Code pane now keeps are legible — 40 lines at 22.9 px pitch, 13 px mono, 19:1 contrast — but they are all forward context. The current position sits at 14% of the window height: six rows of leading context (137 px) against thirty-three trailing (763 px). Stepping backwards is this product's premise, and the pane's new height has been spent entirely on the direction the visitor is not travelling. Bias the window so the position sits nearer a third down.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/light/L4/8",
      "severity": "P2",
      "location": "Transaction pane, first two rows, y≈111 and y≈137",
      "finding": "The same 40-hex value is rendered twice, 26 px apart — truncated as '0xb636167a…66d46359' beside the Partial badge, then in full as '0xb636167a05b9de55bde67756bdaed6e766d46359' on the line directly below — and a third time as '0xb63616…6359' in the identity bar. The full form fits the 383 px pane, so the truncated copy directly above it adds no information; it costs a row in the pane that is already too narrow for its addresses.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/light/L4/9",
      "severity": "P2",
      "location": "Call Trace pane, indentation guides at x=936",
      "finding": "Depth is drawn with a single vertical guide at a fixed x=936 for every nested frame regardless of level — verified identical at depth 1 (iterate_asteroids, y187), depth 2 (calculate_damage, y212) and depth 3 (calculate_remaining_shield_pct, y237). Only the text indent changes (~30 px per level). From depth two onward, depth is expressed by indentation alone, so at realistic depth a reader cannot count levels or trace a frame back to its parent; there is also no visible collapse affordance.",
      "criterion": "B6"
    },
    {
      "id": "debugger/wide/light/L4/10",
      "severity": "P3",
      "location": "identity bar, step controls, x 394–671",
      "finding": "Eight icon-only 24 px chips with ~11 px glyphs measured at 3.54:1 against their own fill — above the 3:1 non-text floor but the lowest-contrast marks on the page, and they are the primary controls. No labels and no keyboard hints anywhere, against B10's 'keyboard affordances are indicated'. The four idioms are also near-identical at this size: step-in/step-out read as two generic diagonal arrows, and '|←  →|' versus '|◀◀  ▶▶|' are two undifferentiated jump metaphors.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/light/L4/11",
      "severity": "P3",
      "location": "Transaction pane, FEE PAYER (y≈300) and TARGET (y≈352)",
      "finding": "42-character addresses wrap mid-string with the remainder right-aligned, giving a ragged left edge — '0x01c8f081e2abedf0184953e2a272b5' / 'e430d5d932'. A hash broken at an arbitrary character and then re-aligned to the opposite edge is hard to read and easy to copy wrong. At 383 px the pane is the narrowest column on the page; a full-width value row under the label, or middle truncation, would fit.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/light/L4/12",
      "severity": "P3",
      "location": "Call Trace / Event Log tab strip, EVENT LOG tab, x≈1017–1090",
      "finding": "The Event Log tab carries no item count. Half the content of the region is hidden behind it and its volume is unknowable from the render — which is also why the region's 334 px of empty height cannot be defended. A count on the tab would both justify the allocation and tell a visitor whether it is worth the click.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/light/L4/13",
      "severity": "P3",
      "location": "Values pane, type column (x≈1470–1520) and the masses[2] row (y≈817)",
      "finding": "The dedicated right-hand type column reads 'Field' on eight of ten rows, so a fixed column of the pane's width carries a constant. Separately, nesting under 'masses' is expressed by a single leading space (~8 px) on 'masses[2]' with no guide; at two or three levels of struct or array nesting that will not survive, and the array value '[100, 2000, 200, 100, 100, 50, 50, 14]' already fills its cell edge to edge with no truncation strategy visible for a longer one.",
      "criterion": "B1"
    }
  ]
}
```
