# debugger · laptop · light · L5 (brand and register consistency)

Expected elements: present

Every backbone item is there and carries real content: identity bar (y 0–62) with chain, truncated hash, Partial badge and block; source pane positioned at line 32 with a ▶ gutter marker and a matching highlighted `calculate_damage` frame in the call trace (y≈393) — genuine cross-pane position correspondence; seven-frame call trace; a state pane with eleven values and two changed values marked in blue; bidirectional stepping controls (x 20–266) with no menu; a scrubber and `Step 128 of 1315`; a full TRANSACTION metadata pane. No spinner, no empty pane, no explorer footer. The phase chips and the "18 MB, fetched once and cached" line are exactly the honest, quantified register this product asks for, and the Aztec privacy copy ("no call structure to trace") is the best-written text on the surface.

What holds it back is register leakage rather than absence. Explorer primitives keep appearing inside tool panes: a two-line prose narration inside the code pane, a blue text link for sorting, marketing-weight buttons in the identity bar, and a full-width paragraph banner where the desktop app would use a status line. A CodeTracer user would recognise the panes but would notice the surface explaining itself to them.

Highest-priority fixes: (1) move the editor's "Showing from line 26…" narration into the gutter/pane header and demote the top banner to a single status strip, recovering the ~120 px of pre-session chrome; (2) promote the timeline from a 170 px dotted hairline to a first-class trace element.

Rating: 7/10

```json
{
  "view": "debugger",
  "size": "laptop",
  "theme": "light",
  "image": "screenshots/debugger__laptop__light.png",
  "reviewer": "L5",
  "expectedElements": "present",
  "missing": [],
  "rating": 7,
  "findings": [
    {
      "id": "debugger/laptop/light/L5/1",
      "severity": "P2",
      "location": "identity bar, back affordance '← aztec' at x≈22–76, y≈31",
      "finding": "The only back control in the identity bar is labelled with the chain name, so it reads as 'back to the aztec chain', not 'back to this transaction'. The backbone requires a return path to the transaction detail page, and nothing on the surface names that destination: the truncated hash beside it (x≈93–201) is rendered in plain near-black mono with no link affordance, and the only visible link in the bar area is '101:0' in the TRANSACTION pane, which goes to the block. The crossing out of the product register is supposed to be as visible as the crossing in.",
      "criterion": "B9"
    },
    {
      "id": "debugger/laptop/light/L5/2",
      "severity": "P2",
      "location": "EDITOR pane, prose notice at y≈266–300, above line 26",
      "finding": "Two lines of explorer-register explanatory copy sit inside the code pane in the UI face — 'Showing from line 26 — the session's position is below, and the lines above it are not in this window.' A desktop editor never narrates its own viewport; it lets the gutter say where the window starts. This is marketing-page voice inside the tool's densest pane, and it costs ~35 px of code at the top of the only pane that is already clipping its content.",
      "criterion": "B9"
    },
    {
      "id": "debugger/laptop/light/L5/3",
      "severity": "P2",
      "location": "top banner band, y≈62–118 (prose x≈24–640; three pill chips x≈651–1324)",
      "finding": "The phase display is built from explorer primitives: a full-width paragraph plus three 32 px letter-spaced uppercase pills across a 56 px band. The information is right and must stay, but its treatment is a marketing banner. Combined with the 62 px identity bar, ~120 px — 13% of the 900 px viewport — is chrome before the first pane, in a register whose reference application spends that space on a one-line status strip.",
      "criterion": "B1"
    },
    {
      "id": "debugger/laptop/light/L5/4",
      "severity": "P2",
      "location": "DEBUG CONTROLS pane, timeline at x≈285–455, y≈166–180",
      "finding": "The trace timeline is a ~170 px dotted hairline with a small hatched head, visually subordinate to the 560 px sentence beside it; position is legible only from the text '128 / 1315' at x≈1050. In the CodeTracer desktop app the timeline is a primary, full-width element of the session, not an ornament wedged between the button group and a caption. This is the clearest divergence from the reference application on the screen.",
      "criterion": "B10"
    },
    {
      "id": "debugger/laptop/light/L5/5",
      "severity": "P2",
      "location": "TRANSACTION pane, 'Status reason' at y≈185–207",
      "finding": "The value is rendered as the raw internal token 'private-part-succeeded-public-part-succeeded' — a kebab-case enum member shown as visitor-facing copy, wrapped across two lines in the proportional UI face. Everywhere else on this surface the product speaks English ('no call structure to trace', 'Trace ready'), so this reads as a value that escaped before it was written. Copy is a design property here and this one is machine vocabulary.",
      "criterion": "B9"
    },
    {
      "id": "debugger/laptop/light/L5/6",
      "severity": "P2",
      "location": "EDITOR pane right edge (x≈684) versus CALL TRACE pane dead space (y≈455–555)",
      "finding": "Source lines 40–49 are cut mid-token at the pane's right edge with no visible horizontal scrollbar or wrap indicator ('fn calculate_shield_regeneration(initial_shield:Field, remaining_shiel'), while the call trace pane holds seven frames and leaves ~100 px blank below 'Sorted by call order.'. The split at 1440 starves the pane whose content is widest and gives slack to the pane that has none to use; a desktop editor either wraps or scrolls, it does not silently truncate code.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L5/7",
      "severity": "P3",
      "location": "CALL TRACE pane footer, 'Sort by cost' at x≈1063–1136, y≈444",
      "finding": "The sort control is a blue explorer-register text link in the pane's bottom edge, paired with the caption 'Sorted by call order.' Sorting is a pane control and in the reference application lives in the pane header as a toggle or segmented control; as a link at the foot it borrows the web surface's link role and puts a control where a caption is expected.",
      "criterion": "B9"
    },
    {
      "id": "debugger/laptop/light/L5/8",
      "severity": "P3",
      "location": "identity bar right cluster, 'NOIR' at x≈1197–1223",
      "finding": "An unlabelled grey uppercase datum sits immediately left of the 'Share' and 'Download trace' buttons, at similar size and vertical position, so it reads as a third, disabled button rather than as the VM/language fact it is. Either give it the same badge primitive as 'Partial' or separate it from the control cluster.",
      "criterion": "B3"
    },
    {
      "id": "debugger/laptop/light/L5/9",
      "severity": "P3",
      "location": "identity bar hash (x≈93–201) versus TRANSACTION pane hash (y≈162)",
      "finding": "The same hash is truncated two different ways on one screen: '0xb63616…6359' (6+4) in the identity bar and '0xb636167a…66d46359' (8+8) in the metadata pane. Hash truncation is a shared primitive across both registers and should have one rule; two rules within 130 px make the two strings momentarily look like two transactions.",
      "criterion": "B7"
    }
  ]
}
```
