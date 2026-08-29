# debugger · wide · dark — L1 (Typography and hierarchy)

Expected elements: present

Every backbone item is there: slim identity bar (`← aztec`, `0xb63616…6359`, `Partial`, `block 101`), dark product surface, full viewport with no explorer chrome, source pane with line 32 marked, a seven-frame call trace, a ten-row state pane, both stepping directions in the control cluster, a step scrubber, and the full hash in the TRANSACTION pane. The loading state is named phases, not a spinner. Nothing forbidden is present.

Typographically the surface is competent in the state pane and undermined nearly everywhere else by a type scale whose levels do not separate. The worst of it is the source pane: across lines 26–58 keywords, identifiers, literals, operators and the comment on line 56 are all one weight at one value (#ddd), so the flagship pane of a product whose texture is monospace has no token hierarchy at all. Structurally, `CALL TRACE` (y≈234) and `FRAME` (y≈260) are the same face, size, weight, colour and left edge — a pane title and a column header at one level — and the same holds for `TRANSACTION` over `BLOCK`/`CANONICAL`. Truncation is three different strategies on one screen: 6+4 with ellipsis in the identity bar, 8+8 in a different face in the TRANSACTION pane, no truncation at all for the 40-char FEE PAYER/TARGET hex (which soft-wraps, orphaning `e430d5d932` from its label), and hard mid-token clipping in the editor.

Highest-priority fixes: give the source pane the CodeTracer editor tokens, and separate the pane-title level from the column-header/field-label level.

Rating: 5/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L1",
  "expectedElements": "present",
  "missing": [],
  "rating": 5,
  "findings": [
    {
      "id": "debugger/wide/dark/L1/1",
      "severity": "P2",
      "location": "EDITOR pane, source body, lines 26–58 (x≈130–915, y≈310–1070)",
      "finding": "The source has no token differentiation whatsoever — `fn`, `let`, `if`, `else`, identifiers, the numeric literals `100`/`0`, the string literal on line 54 and the `//` comment on line 56 are all rendered at one weight in one value (#dddddd on #101010). In the pane the product exists for, a reader gets no structure without reading the words. Weight alone would carry most of it even before colour.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/2",
      "severity": "P2",
      "location": "CALL TRACE pane header (x≈930, y≈228–240) against its column header row (x≈930, y≈254–266); same relationship in TRANSACTION pane, y≈132 vs y≈231",
      "finding": "The pane title and the column header are typographically identical: same mono caps, same ~11px size, same grey, same letterspacing, same left edge, separated only by a hairline. `CALL TRACE` does not out-rank `FRAME`, and `TRANSACTION` does not out-rank `BLOCK` — measured cap heights differ by roughly 1px. Two structural levels are collapsed into one, so the eye cannot tell a pane boundary from a table boundary without reading the words.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L1/3",
      "severity": "P2",
      "location": "identity bar hash (x≈95–205, y≈24–40) versus TRANSACTION pane hash (x≈1610–1780, y≈155–172)",
      "finding": "The same transaction hash is truncated by two different rules and set in two different typefaces on one screen: `0xb63616…6359` (6 prefix + 4 suffix, monospace, letterforms with squared terminals) in the identity bar, `0xb636167a…66d46359` (8 + 8, geometric UI sans with a single-storey `a` and circular `6`) in the pane. A visitor comparing the two cannot immediately confirm they are the same value, which is the identity bar's only job.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/4",
      "severity": "P2",
      "location": "TRANSACTION pane, FEE PAYER value (x≈1637–1910, y≈318–358) and TARGET value (y≈370–408)",
      "finding": "Both 42-character addresses are rendered untruncated and soft-wrap to a second right-aligned line, so `e430d5d932` and `a59161624c` sit alone on their own lines with no label beside them and no visual tie to the row above. The wrap point is wherever the container ends, not a chosen boundary — no ellipsis, no middle-truncation, no character-level grouping. This is the widest content in the pane and the only content given no truncation strategy at all, three rows below a hash that does get one.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/5",
      "severity": "P2",
      "location": "CALL TRACE, current frame row `calculate_damage` (x≈968–1090, y≈400–423), against the identical unselected frame name at y≈330–343",
      "finding": "The row you are standing on carries the weakest type in the pane. The unselected `calculate_damage` at y≈336 is bold at #f3f3f3; the current frame's name at y≈411 drops to regular weight and a mid-blue (#818cf8) sitting on the #312e81 selection band — measured 3.8:1, below the 4.5 floor for 13px regular text. Weight and emphasis decrease exactly where hierarchy should peak, so the highlight band is doing all the work and the label is fighting it.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L1/6",
      "severity": "P2",
      "location": "EDITOR pane, notice line 'Showing from line 26 — the session's position is below…' (x≈20–762, y≈285–299)",
      "finding": "This is UI prose about the pane, but it is set in the same monospace at the same ~13px as the source immediately beneath it, on the same left origin. It reads as line 25 of the file rather than as a message from the tool. B7 names 'code and UI in the same face' as the failing case, and this is the one place in the product where the two abut directly.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/7",
      "severity": "P2",
      "location": "DEBUG CONTROLS row: 'Step 128 of 1315 — stepping starts when the replay engine finishes loading (18 MB)' (x≈860–1420, y≈173–190) and '128 / 1315' (x≈1435–1520, same baseline)",
      "finding": "The position is stated twice on one line, and the hierarchy is inverted between the two. The prose sentence is the brightest text (#f0f0f0, sans, full weight) and carries the numbers proportionally; the tabular monospace readout that a tool user actually scans for is at #919191, the dimmest text in the row. The scannable form should be the emphasised one, and the sentence should not repeat the count it precedes.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/8",
      "severity": "P2",
      "location": "CALL TRACE opcode column (x≈1460–1520, y≈278–440) versus TRANSACTION 'COST · MANA' value (x≈1690–1910, y≈422–437)",
      "finding": "Two numeric treatments for the same class of quantity. The opcode counts are monospace with thousands separators and right-aligned (`1,315`, `1,208`, `96`, `11`); the mana figures a few hundred pixels away are proportional sans with no separators (`88000 / 200000`), so the two five/six-digit numbers cannot be compared by eye and `200000` has to be counted digit by digit. Pick one figure style — tabular, separated — for every quantity in the shell.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/9",
      "severity": "P2",
      "location": "'STATE' / 'EVENT LOG' tabs (x≈930–1060, y≈668–685) against the 'DEBUG CONTROLS', 'EDITOR', 'CALL TRACE' and 'TRANSACTION' titles",
      "finding": "The pane-title level is expressed two ways. Four panes name themselves with dim grey (#919191) letterspaced caps at ~11px; the state pane names itself with a bold near-white ~12px sans tab plus a blue underline. Same structural role, opposite emphasis — so the state pane's title reads as the loudest header on the screen while the source pane's reads as the quietest.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L1/10",
      "severity": "P3",
      "location": "EDITOR pane, source body — baseline pitch measured between lines 26/27/28 (y≈312, 337, 358…)",
      "finding": "Line pitch is ≈23px on a ≈13px face, a leading ratio near 1.75 — prose leading in a code pane. CodeTracer's editor sits nearer 1.4, and the difference costs roughly ten lines of context in an 800px-tall pane. Tightening it increases information rather than reducing it.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L1/11",
      "severity": "P3",
      "location": "EDITOR pane right edge (x≈915) at line 40 (y≈642) and line 53 (y≈943)",
      "finding": "Long source lines are hard-clipped mid-token at the pane edge — `shield_regen_perce` and `damage: Field, r` — with no ellipsis and no static overflow affordance visible at rest. Horizontal scroll inside the code container is the right behaviour, but this is a fourth truncation appearance on a screen that already has three, and nothing marks the cut.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/12",
      "severity": "P3",
      "location": "TRANSACTION pane, 'Status reason: private-part-succeeded-public-part-succeeded' (x≈1540–1900, y≈182–212)",
      "finding": "A machine enum value is set as proportional running prose and wraps at its own hyphen (`public-part-` / `succeeded`), which reads as a hyphenated English word break rather than as one indivisible token. Identifiers of this kind belong in the mono face, or in the same pill treatment used for `Partial` and `Trace ready`.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/13",
      "severity": "P3",
      "location": "STATE pane, `masses[2]` row (x≈940, y≈800–816) under its parent `masses` (y≈775–791)",
      "finding": "The only cue that this row is a child of the array above it is a single monospace-character indent (~8px). At one level of nesting it is already ambiguous with a slightly longer name; there is no guide, no rule and no weight change to express the relationship.",
      "criterion": "B6"
    },
    {
      "id": "debugger/wide/dark/L1/14",
      "severity": "P3",
      "location": "CALL TRACE column header, 'ACIR opcodes' (x≈1425–1520, y≈254–266)",
      "finding": "This header mixes an all-caps token with a lowercase word in one label, and drops the second word to a dimmer value, while every other header on the screen ('FRAME', 'STATE', 'BLOCK', 'CANONICAL') is uniform caps. It reads as two labels rather than one, and breaks the caps-header convention at the only place it carries a unit.",
      "criterion": "B4"
    }
  ]
}
```
