Expected elements: present

Identity bar (chain, truncated hash, `Partial`, `block 101`), dark product surface, full-viewport session, line 32 marked current in the editor, a 7-frame call trace, a 10-row state pane, eight stepping buttons in mirrored pairs, a step scrubber and the transaction pane are all present. No spinner (the banner uses three named phase chips), no empty pane, no light chrome.

Typographically this is a restrained, competent scale — roughly three sizes and two families, with genuinely tabular right-aligned numerics in the state and call-trace panes. What lets it down is code and identifier treatment, which in this product *is* the texture.

The worst is the editor: source lines 26–58 carry **no syntax highlighting whatsoever**. `fn`, `let`, `mut`, `if`, `as`, the `100`/`0` literals, `Field`/`u32` types and the line-41 comment are all one colour and one weight. Design-System §7 makes the CodeTracer editor palette the one sanctioned register crossing; the flagship debugger surface has none of it, so the current line's code gets its emphasis entirely from the purple band.

Second, one hash is truncated three different ways on one screen: `0xb63616…6359` (6+4) in the identity bar, `0xb636167a…66d46359` (8+8) in the transaction pane, and FEE PAYER / TARGET untruncated but right-aligned and wrapped mid-string.

Third, the step readout inverts its own hierarchy: the transient loading sentence is the brightest text on the row while `128 / 1315` — the persistent position — is the dimmest, and both state the same numbers.

Highest-priority fixes: (1) apply the CodeTracer editor tokens to the source pane; (2) pick one hash truncation rule and one thousands-separator convention and use them everywhere.

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
      "location": "Editor pane, source lines 26–58",
      "finding": "The source carries no syntax highlighting at all. Keywords (`fn` L40, `let mut` L42, `if`/`else` L28/L31, `as` L43), numeric literals (`0` L27, `1` L29, `100` L28/L32/L42), type names (`Field`, `u32`) and the comment on L41 are rendered in the same colour and the same weight as plain identifiers. Design-System §7 makes the CodeTracer editor palette the one sanctioned register crossing, and this is the flagship product-register surface. The consequence for hierarchy is compounding: because every token is one weight, the current line (32) is distinguished only by its background band, and the code on it reads no differently from L31 or L33.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/2",
      "severity": "P2",
      "location": "Identity bar hash vs. TRANSACTION pane hash / FEE PAYER / TARGET",
      "finding": "One content class, three truncation strategies on one screen. The identity bar shows `0xb63616…6359` (6 hex + 4). The transaction pane shows the same hash as `0xb636167a…66d46359` (8 + 8). FEE PAYER and TARGET are not truncated at all — the full value is right-aligned and wrapped onto a second line (`…e2a272b5` / `e430d5d932`), so a hash breaks mid-token with no ellipsis and its continuation floats at the right margin where it is easy to mistake for a separate field. A reader cannot learn one rule for reading identifiers here.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/3",
      "severity": "P2",
      "location": "DEBUG CONTROLS row, right of the scrubber",
      "finding": "Hierarchy is inverted and the content is duplicated. `Step 128 of 1315 — stepping starts when the replay engine finishes loading (18 MB)` is set in the brightest, heaviest text on the row, while `128 / 1315` — the canonical, persistent position readout a debugger user actually scans — sits beside it as the dimmest text on the row. The loading caveat is transient and already stated verbatim in the banner above (`Stepping starts once the replay engine loads — 18 MB, fetched once and cached`); the position is permanent. The step numbers appear twice within 200 px in two different faces.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/4",
      "severity": "P2",
      "location": "CALL TRACE pane, highlighted row (`calculate_damage`, 6th frame)",
      "finding": "The current frame's name is set in a LIGHTER weight than every other frame name in the pane. `main`, `iterate_asteroids`, `calculate_damage` (row 3), `calculate_remaining_shield_pct`, `status_report` and the last row are all bold white; the selected row's name alone drops to a regular weight in a mid-blue. By type alone the current position is the weakest name in the column — the opposite of what B5 asks for — and it survives only because of the fill behind it. In a forty-frame trace with the band scrolled to an edge, that inversion is the whole problem.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L1/5",
      "severity": "P2",
      "location": "Editor pane, right edge, lines 40 and 53",
      "finding": "Long lines are hard-clipped at the pane's right edge with no ellipsis, no fade and no visible scroll affordance. Line 40 ends `…shield_regen_perce` and line 53 ends `damage: Field, r` — both cuts land mid-identifier, so the truncated token reads as a real (wrong) name rather than as an incomplete one. Horizontal scroll is the correct behaviour for a code viewport, but nothing in the type or the edge treatment says the line continues.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/6",
      "severity": "P2",
      "location": "CALL TRACE opcode column vs. step readout vs. COST · MANA",
      "finding": "The same quantity is formatted two ways on one screen. `main`'s opcode count is `1,315` with a thousands separator; the identical number appears twice on the controls row as `1315` and once more in the prose sentence as `1315`. COST · MANA renders `88000 / 200000` and the state pane renders `10000` / `9000` / `2000`, all without separators. B7 asks for comparable formatting across magnitudes; here the separator convention changes per pane, which defeats the tabular alignment the columns otherwise achieve.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/7",
      "severity": "P2",
      "location": "Shell-wide: pane titles, column headers, tabs, field labels, phase chips, `NOIR` in the identity bar",
      "finding": "A single ~10 px letterspaced all-caps style is doing six different jobs: pane title (`DEBUG CONTROLS`, `EDITOR`, `CALL TRACE`, `TRANSACTION`), column header (`FRAME`), tab control (`STATE` / `EVENT LOG`), field label (`BLOCK`, `CANONICAL`, `FINALITY`, `FEE PAYER`, `TARGET`), loading-phase chip (`OPENING THE TRACE`), and a bare VM identity token (`NOIR`, top right). Nothing about the type tells the eye whether a caps string names a pane, labels a value, or is clickable — the caps role carries no information, so the shell's top-level structure is not readable without reading it.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/8",
      "severity": "P2",
      "location": "Loading banner, phase chips `OPENING THE TRACE` and `POSITIONING AT THE REQUESTED STEP`",
      "finding": "The two inactive phase chips are ~10 px all-caps with positive letterspacing at low emphasis; the third is 32 characters long at that size. All-caps removes the ascender/descender silhouette that makes small text scannable, and letterspacing at 10 px pushes the phrase past the point where it is read as a shape. The honest phase vocabulary the spec requires is currently the least legible text on the screen — the exact case the view's Watch-for names.",
      "criterion": "B2"
    },
    {
      "id": "debugger/wide/dark/L1/9",
      "severity": "P2",
      "location": "CALL TRACE frame rows vs. EDITOR tab bar",
      "finding": "The same content in two faces. `src/shield.nr` is set in the proportional UI sans in the call trace's `zk_shields · src/shield.nr` metadata, and in the monospace face in the editor tab bar three panes to the left. File paths are machine identifiers and should sit on one side of the mono/proportional split; splitting them by pane means the reader's eye has to re-learn the correspondence when moving between the two panes that are meant to be cross-referenced.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/10",
      "severity": "P2",
      "location": "TRANSACTION pane, `Status reason:` row",
      "finding": "Label and value are typographically identical — same proportional face, same weight, same grey — in a pane where every other row uses a caps label against a distinct value treatment. The value is also a machine enum (`private-part-succeeded-public-part-succeeded`) set in the prose face and allowed to wrap at one of its own hyphens (`…public-part-` / `succeeded`), so a single token reads as two hyphenated words. Machine tokens elsewhere in this pane are monospace.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/11",
      "severity": "P3",
      "location": "STATE pane, `masses[2]` row beneath `masses`",
      "finding": "The child row is indented roughly 7 px — about half a character — from its parent, with no guide rule and no other cue. At that magnitude the indent reads as a stray leading space rather than as a nesting level, so the relationship between `masses` and its element is invisible.",
      "criterion": "B6"
    },
    {
      "id": "debugger/wide/dark/L1/12",
      "severity": "P3",
      "location": "CALL TRACE pane, indentation levels 2–4",
      "finding": "A single vertical guide rule is drawn at one x position while the tree indents to four levels, so `calculate_remaining_shield_pct` at depth 4 is expressed by whitespace alone. B6 asks for indentation AND a guide; the guide currently only covers depth 2. At realistic trace depth the frame names will be the only depth signal.",
      "criterion": "B6"
    },
    {
      "id": "debugger/wide/dark/L1/13",
      "severity": "P3",
      "location": "CALL TRACE pane, column header row",
      "finding": "The header row uses three treatments across two cells: `FRAME` is grey caps at label weight, and its right-hand sibling mixes bold white caps (`ACIR`) with regular grey lowercase (`opcodes`) inside one header. The unit qualifier is heavier than the thing it qualifies, and neither cell matches the other.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/14",
      "severity": "P3",
      "location": "STATE pane, `masses` row value column",
      "finding": "The array literal `[100, 2000, 200, 100, 100, 50, 50, 14]` is right-aligned into the same column as the scalar values, so it runs left across roughly half the pane and leaves the scalar column with no defined left boundary. Composite values and scalars need different alignment rules if the scalar column is to stay scannable.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/15",
      "severity": "P3",
      "location": "DEBUG CONTROLS, the eight stepping buttons",
      "finding": "The control cluster carries no type at all — eight icon-only buttons in four mirrored pairs, with no labels and no keyboard-shortcut indication. Reverse stepping is present and visible (the requirement is met), but which pair is step-over versus step-into versus run-to-end has to be inferred from small glyphs. A shortcut letter or a caps micro-label would make the group readable without hovering.",
      "criterion": "B10"
    }
  ]
}
```
