Expected elements: present

Presence check passes: slim identity bar (`← aztec · 0xb63616…6359 · Partial · block 101`), dark product surface, full-viewport session with no page scrollbar, source pane with line 32 marked `▶` and filled, seven-frame call trace with the current frame highlighted, ten-row state pane, eight stepping controls including reverse, a step scrubber with `Step 128 of 1315`, and a transaction pane carrying the full hash. The phase chips are named phases, not a spinner. No pane is blank.

Typographically this reads as a real tool: one pane-header idiom, tabular right-aligned opcode and value columns, a clear identity-bar hierarchy. Where it slips is in treating the same content class two or three ways.

Highest-priority fixes: (1) give the source pane token differentiation — right now `let`, `if`, `u32`, `Field` and numerals are one weight and one colour, so the product's primary reading surface is a flat texture; (2) pick one numeric convention — the call trace groups thousands (`1,315`), the state pane and `COST · MANA` do not (`10000`, `88000 / 200000`).

Also: the editor's `Showing from line 26 …` notice is UI prose set in the code face at code size across ~88 characters, so it reads as a line of the listing; hex identifiers use 6+4 ellipsis, 8+8 ellipsis and full-wrap in three places; the mono `128 / 1315` readout is the faintest text in the control row while a sentence beside it is the brightest; source pitch is ~23 px on ~13 px type, loose for this register.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L1",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/dark/L1/1",
      "severity": "P2",
      "location": "editor pane, source listing (lines 26-58)",
      "finding": "The source has no token differentiation at all: keywords (let, if, else), types (u32, Field), numerals (100, 0) and identifiers all render at one weight and one near-white value. The product's primary reading surface is a flat texture, so the eye finds the current statement only via the row fill, and nothing in the code itself carries hierarchy. Rubric B7's passing state is source in the CodeTracer editor palette; this is the debugger register's flagship view and it has no editor palette applied.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/2",
      "severity": "P2",
      "location": "call trace opcode column vs. state pane value column vs. transaction pane COST · MANA row",
      "finding": "Numeric formatting is not comparable across panes at the same magnitudes. The call trace groups thousands (1,315 / 1,208); the state pane does not (10000, 9000, 2000, 1000); the transaction pane does not (88000 / 200000 mana). Three four-to-five-digit columns on one screen, two conventions, no rule a reader can infer.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/3",
      "severity": "P2",
      "location": "editor pane, notice line above line 26 ('Showing from line 26 — the session's position is below…')",
      "finding": "UI prose is set in the monospace code face at code size and near-code lightness, flush with the gutter, so it reads as the first line of the listing rather than as chrome. It is also ~88 monospace characters on one line, well past a comfortable prose measure. Every other explanatory string in the view (the loading banner, the 'aztec private function executed client-side…' note) uses the sans face; this one does not.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/4",
      "severity": "P2",
      "location": "identity bar hash vs. transaction pane hash vs. transaction pane FEE PAYER / TARGET rows",
      "finding": "One content class, three truncation treatments: the identity bar middle-truncates at 6+4 (0xb63616…6359), the transaction pane at 8+8 (0xb636167a…66d46359), and FEE PAYER / TARGET are not truncated but wrapped in full onto a second right-aligned line, leaving orphan tails (e430d5d932, a59161624c) floating under the right edge with no label association. A reader cannot form one mental rule for how this product shows an identifier.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/5",
      "severity": "P2",
      "location": "DEBUG CONTROLS pane, status row right of the scrubber",
      "finding": "The step position is stated twice in two faces on one line: 'Step 128 of 1315 — stepping starts when the replay engine finishes loading (18 MB)' in bright sans, then '128 / 1315' in dim mono at the far right. The canonical numeric readout — the value a user scans on every step — is the lowest-emphasis text in the row, while an explanatory sentence is the highest. The hierarchy is inverted and the fact is duplicated.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/6",
      "severity": "P2",
      "location": "editor pane line pitch; state pane row pitch",
      "finding": "Line-height is loose for the debugger register: source is ~13 px type on a ~23 px pitch (~1.75), and state rows are ~12-13 px type on a ~25 px pitch. The result is 33 source lines and 10 state rows in a 1080 px viewport. Tightening to ~1.45 in the source pane and ~20 px rows in the state pane would show more information, not less, which is the direction rubric B rewards.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/dark/L1/7",
      "severity": "P2",
      "location": "TRANSACTION pane, label column",
      "finding": "Three label idioms stack in one column: uppercase letterspaced (BLOCK, CANONICAL, FINALITY, FEE PAYER, TARGET, COST · MANA, EXECUTIONS), sentence-case sans with a colon ('Status reason:') set inline with its value instead of in the label column, and lowercase mono (private, public) under EXECUTIONS. The pane's label/value grid stops being legible as a grid at the two exceptions.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L1/8",
      "severity": "P3",
      "location": "CALL TRACE pane, column header row, right side",
      "finding": "The header 'ACIR opcodes' is typeset as two different things — 'ACIR' uppercase, tracked, bold, white; 'opcodes' lowercase, gray, lighter — while its counterpart 'FRAME' on the same row is uppercase and tracked. Either make the whole header the FRAME idiom or make the unit a distinct, consistently applied sub-label.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L1/9",
      "severity": "P3",
      "location": "loading banner phase chips vs. pane titles vs. 'NOIR' in the identity bar",
      "finding": "The small-uppercase-letterspaced treatment carries five unrelated meanings: pane titles (EDITOR, DEBUG CONTROLS, CALL TRACE, TRANSACTION, STATE), a column header (FRAME), a VM label (NOIR), metadata field labels, and the live progress chips (FETCHING THE ENGINE AND THE TRACE / OPENING THE TRACE / POSITIONING AT THE REQUESTED STEP). A transient phase indicator and a permanent pane title should not share a type treatment; the chips currently scan as another row of pane labels.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/10",
      "severity": "P3",
      "location": "STATE pane rows, including the 'masses' / 'masses[2]' pair",
      "finding": "Name, value and type sit at one size and one weight in every row, so the row's internal hierarchy and the changed-value marking (9000, 2000) rest entirely on colour with no typographic reinforcement. The nested 'masses[2]' is indented from its parent 'masses' by roughly one character, too small to read as nesting at a glance and with no guide.",
      "criterion": "B6"
    },
    {
      "id": "debugger/wide/dark/L1/11",
      "severity": "P3",
      "location": "editor pane, right edge of lines 40 and 53",
      "finding": "Long source lines truncate by a right-edge fade with no ellipsis and no visible horizontal scrollbar, so 'shield_regen_perce…' and 'damage: Field, r…' dissolve mid-token. It is a fourth truncation idiom in the view and the only one that indicates content is cut without indicating how much or how to reach it.",
      "criterion": "B7"
    }
  ]
}
```
