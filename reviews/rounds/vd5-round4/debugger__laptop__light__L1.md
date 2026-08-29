# debugger · laptop · light · L1 — Typography and hierarchy

Expected elements: present

All backbone items are there: slim identity bar (y 0–56) with chain, truncated hash, `Partial` badge and `block 101`; no explorer header or footer; the session fills 1440×900; current position marked at editor line 32 (blue gutter number, ▶ glyph, row tint); a seven-frame call trace; a ten-row state pane; forward *and* reverse stepping buttons at x 20–270; a scrubber plus "Step 128 of 1315". No spinner — the three named phase chips are the honest treatment. No empty pane, no marketing chrome.

As a type surface it is competent and genuinely dense in places, but it has no single policy for the one thing it is mostly made of: identifiers. Five different overflow behaviours are visible at once, and the same hash appears at two truncation lengths 1 050 px apart. The worst instance is the TRANSACTION pane, where two 42-character addresses hard-wrap into three right-aligned lines ending in the orphans "32" and "4c" — each reads as three stacked values rather than one. Numeric formatting splits the same way: "1315" in the controls bar (twice, in two faces, on one line) against "1,315" in the call trace.

Leading is the other systemic issue: 1.7–1.9× in all three data panes, which is explorer rhythm in the product register and costs roughly three call-trace frames and four source lines.

Highest-priority fixes: (1) one identifier-overflow policy — middle-ellipsis at a fixed budget, never a wrap that orphans two characters; (2) tighten pane leading to ~1.45 and settle one digit-grouping rule.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "laptop",
  "theme": "light",
  "reviewer": "L1",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/laptop/light/L1/1",
      "severity": "P2",
      "location": "TRANSACTION pane (x 1150–1432), FEE PAYER row y 325–372 and TARGET row y 400–447",
      "finding": "The 42-character addresses hard-wrap into three right-aligned monospace lines whose last line holds two characters — '32' for FEE PAYER, '4c' for TARGET. A right-aligned three-line block with a two-glyph tail reads as three separate values, and the wrap points (21/19/2) fall mid-byte so no fragment is a meaningful boundary. The same wrap-to-orphan pattern recurs in the STATE pane's `masses` row (y 675–710), where '14]' sits alone on the second line.",
      "criterion": "B7"
    },
    {
      "id": "debugger/laptop/light/L1/2",
      "severity": "P2",
      "location": "identity bar hash (x 93, y 31) vs TRANSACTION pane hash (x 1232, y 162); call trace rows 4 and 7 (y 343, y 418); editor line 26 (y 320)",
      "finding": "Five overflow strategies coexist on one screen with no rule connecting them: middle-ellipsis at 6+4 in the identity bar (0xb63616…6359); middle-ellipsis at 8+8 for the SAME hash in the transaction pane (0xb636167a…66d46359); end-ellipsis on call-trace symbols and paths; hard wrap in the transaction pane; and a soft right-edge fade on source lines. The identical hash truncated to two different lengths 1 050 px apart is the clearest case — a reader cannot tell at a glance that they are the same value.",
      "criterion": "B7"
    },
    {
      "id": "debugger/laptop/light/L1/3",
      "severity": "P2",
      "location": "DEBUG CONTROLS readout, y 172, x 475–1130; against CALL TRACE opcode column, x 1090–1135",
      "finding": "The trace length is rendered three times in two formats. The controls line carries it twice on one line and in two faces — 'Step 128 of 1315' in the UI sans, then '128 / 1315' in monospace 40 px later — while the call trace renders the same 1315 as '1,315' with a thousands separator. The STATE pane then uses ungrouped 10000 / 2000 / 1000, and COST · MANA uses ungrouped '88000 / 200000'. Program values arguably should stay verbatim, but the step counter and the opcode counts are UI figures and must pick one grouping rule.",
      "criterion": "B7"
    },
    {
      "id": "debugger/laptop/light/L1/4",
      "severity": "P2",
      "location": "CALL TRACE pane, title at y 216 and column header row at y 241",
      "finding": "Two hierarchy levels are set identically: 'CALL TRACE' (pane title) and 'FRAME' (column header) are both ~11 px letterspaced caps in near-identical grey, 25 px apart and separated only by a hairline, so the header row reads as a second pane title. Within that same header row the casing is mixed — 'FRAME' all-caps against 'ACIR opcodes' in mixed case — so the two column labels do not read as a pair.",
      "criterion": "B4"
    },
    {
      "id": "debugger/laptop/light/L1/5",
      "severity": "P2",
      "location": "EDITOR pane, annotation at y 273–293, directly above source line 26",
      "finding": "The explanatory note 'Showing from line 26 — the session's position is below, and the lines above it are not in this window.' is set in the same monospace face, the same size and near-identical colour as the source beneath it. The only thing distinguishing prose from program text is the absent line number, so the eye lands on two lines of UI copy before it reaches the code and the current position. An annotation needs its own level — smaller, or the UI sans, or a clearly demoted colour.",
      "criterion": "B3"
    },
    {
      "id": "debugger/laptop/light/L1/6",
      "severity": "P2",
      "location": "EDITOR source rows (22 px pitch), CALL TRACE rows and STATE rows (both ~25 px pitch)",
      "finding": "Leading runs 1.7× in the source pane and ~1.9× in the call-trace and state panes at a 13 px monospace. That is explorer-register rhythm inside the product register: the call trace shows seven frames in a 210 px body where ~1.45 leading would show ten, and the editor shows 26 lines where it would show ~30. The fix adds information rather than removing it, which is the test the debugger rubric sets.",
      "criterion": "B1"
    },
    {
      "id": "debugger/laptop/light/L1/7",
      "severity": "P2",
      "location": "identity bar, x 24–202, y 31",
      "finding": "'← aztec' is the only link-styled element in the bar (blue, sans); the truncated hash 40 px to its right is near-black monospace with no underline, no colour and no weight change. Typographically nothing in the identity bar signals the route back to the transaction detail page — the one navigable-looking element points at the chain. The hash is the strongest type on the bar and should carry the affordance.",
      "criterion": "B3"
    },
    {
      "id": "debugger/laptop/light/L1/8",
      "severity": "P2",
      "location": "EDITOR pane text column, right edge x ≈ 680; lines 26, 40, 41, 42, 43, 48, 49",
      "finding": "The source measure is ~66 monospace columns, and 7 of the 26 visible lines fade out mid-token — including line 26, the call whose result the current line 32 consumes, and the signature on line 40. The fade is a deliberate treatment rather than a clip, but at this measure it is doing real work on a quarter of the visible source in a file written to ~90 columns.",
      "criterion": "B1"
    },
    {
      "id": "debugger/laptop/light/L1/9",
      "severity": "P3",
      "location": "STATE pane, type column at x 1095–1138",
      "finding": "A categorical text column ('Field', '[Field; 8]', 'u32') is right-aligned, so its left edge ripples against an otherwise clean value column. Alignment should follow data type: the numeric column right, the type labels left.",
      "criterion": "B7"
    },
    {
      "id": "debugger/laptop/light/L1/10",
      "severity": "P3",
      "location": "EDITOR tab strip, y 242, x 22–412",
      "finding": "The four tabs (Nargo.toml, Prover.toml, src/main.nr, src/shield.nr) are identical in face, size, weight and very nearly in colour; the active file is carried by a 1 px underline alone. One weight or colour step would let the active file be read without hunting for the rule.",
      "criterion": "B3"
    },
    {
      "id": "debugger/laptop/light/L1/11",
      "severity": "P3",
      "location": "phase chips in the banner, y 78–102, x 650–1325",
      "finding": "'FETCHING THE ENGINE AND THE TRACE' and 'POSITIONING AT THE REQUESTED STEP' are 30+ character all-caps letterspaced strings at ~11 px. All-caps removes word shape at exactly the length where it matters most, and these chips are the element a waiting visitor is meant to read fastest. Sentence case at the same size would be quicker to parse and would still read as a status chip.",
      "criterion": "B2"
    }
  ]
}
```
