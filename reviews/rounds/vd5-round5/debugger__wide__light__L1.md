Expected elements: present

Every must-show item is there: slim identity bar (hash, chain, `Partial`, block, both-direction stepping controls, `128 / 1315` readout, scrubber, phase rail), Code pane positioned at line 32 with a ▶ marker, a seven-frame call trace, Call Trace and Event Log as one tab strip with Call Trace open, a Values pane below it (not a third tab), and a Transaction pane. No spinner, no empty pane, no full-width prose band, no full-width row. Typographically this is a tool, not a marketing page.

The scale is sound at the extremes — mono for code/hashes/values, right-aligned tabular opcode counts — but collapses in the middle: one uppercase micro-label does pane-title, section-header and field-label duty, so the Transaction pane reads as eleven equal stripes.

Numbers contradict each other: the bar prints `1315`, the call trace prints `1,315` for the same quantity; `COST · MANA` prints `88000 / 200000` ungrouped.

Hash handling is three strategies at once: `0xb63616…6359` (bar), `0xb636167a…66d46359` (pane), and FEE PAYER / TARGET wrapping mid-value onto a second line.

Measurements requested: the Code pane keeps ~120 characters and 40 legible rows; the call-trace region is ~57% empty below `Sorted by call order.`, which the Values pane could use.

Highest-priority fixes: (1) give the Transaction pane a third label level so sections outrank fields; (2) unify digit grouping and hash truncation across bar and panes.

Rating: 6/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "light",
  "image": "screenshots/debugger__wide__light.png",
  "reviewer": "L1",
  "expectedElements": "present",
  "missing": [],
  "rating": 6,
  "findings": [
    {
      "id": "debugger/wide/light/L1/1",
      "severity": "P2",
      "location": "Transaction pane, right column — label stripe from BLOCK down to RAW (CHAIN-NATIVE)",
      "finding": "One uppercase ~10px letterspaced grey label is used for the pane title (TRANSACTION), for group headers (EXECUTIONS, DECODED INPUT, RAW (CHAIN-NATIVE)) and for field labels (BLOCK, CANONICAL, FINALITY, FEE PAYER, TARGET, COST · MANA, SELECTOR, RAW). Nothing outranks anything, so DECODED INPUT reads as a peer of SELECTOR rather than its parent and the pane scans as eleven equal stripes. Three jobs need three levels.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/light/L1/2",
      "severity": "P2",
      "location": "Identity bar position readout (128 / 1315) vs Call Trace opcode column, `main` row (1,315)",
      "finding": "The same quantity is formatted two ways roughly 130px apart: the bar prints 1315 ungrouped, the call trace prints 1,315 grouped. COST · MANA in the Transaction pane compounds it with 88000 / 200000, and the Values pane prints 10000. A debugger's numeric columns need one grouping convention across magnitudes; here comparability breaks the moment two panes are read together.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/light/L1/3",
      "severity": "P2",
      "location": "Transaction pane, FEE PAYER and TARGET rows",
      "finding": "Both addresses wrap mid-value onto a second right-aligned line (…e2a272b5 / e430d5d932; …e6fe8f17 / a59161624c) with no break at a byte-group boundary, while the transaction hash 20px above uses a middle ellipsis and the identity bar uses a shorter one (0xb63616…6359 vs 0xb636167a…66d46359). Three truncation strategies for one data type on one screen; a wrapped hash also cannot be read as a single token.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/light/L1/4",
      "severity": "P2",
      "location": "Code pane file tabs (Nargo.toml / Prover.toml / src/main.nr / src/shield.nr) vs Call Trace / Event Log tab strip",
      "finding": "Two tab strips sit side by side with unrelated type: the file tabs are mixed-case ~13px untracked, the region tabs are uppercase ~11px letterspaced. A reader has to learn twice that these are tabs, and the uppercase strip additionally sits at the same treatment as the pane titles CODE and VALUES, so tab labels and pane titles are indistinguishable.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/light/L1/5",
      "severity": "P2",
      "location": "Identity bar, full width",
      "finding": "Ten objects carry five casing/weight treatments with no ranking between them: lowercase `aztec` and `block 101`, title-case `Partial`, mono `0xb63616…6359`, sentence-case `Engine loading — 18 MB`, uppercase `NOIR` / `FETCHING` / `OPENING` / `POSITIONING`, and semibold `Download trace`. Nothing tells the eye that identity is primary and the phase rail is status, so the bar reads as a strip of unrelated objects rather than three groups.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/light/L1/6",
      "severity": "P2",
      "location": "Call Trace frame rows and Values pane rows",
      "finding": "Both scanning panes run ~25px rows on ~12px monospace (≈2.05 line-height) while the Code listing — the pane meant for reading — runs tighter at ~23px on ~13px. The density is inverted: the columns of similar-looking values that most need a scannable rhythm are the loosest type on the page, and tightening them would show more frames and more values, not fewer.",
      "criterion": "B1"
    },
    {
      "id": "debugger/wide/light/L1/7",
      "severity": "P2",
      "location": "Code pane right edge, lines 40, 53 and 64; and Transaction pane RAW (CHAIN-NATIVE) block, the \"contract\" line",
      "finding": "Long lines are cut mid-identifier at the pane edge with no ellipsis, no wrap marker and no visible scrollbar — line 40 ends at `shield_regen_perce`, line 53 at `r`, line 64 loses its semicolon, and the JSON block ends at `\"0x1b31c04d5920b0b5936f12`. A hard clip mid-token is indistinguishable from content that ends there, which matters most for a truncated hex value.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/light/L1/8",
      "severity": "P3",
      "location": "Call Trace column header row, right side",
      "finding": "`FRAME` is uppercase while its opposite number reads `ACIR opcodes` — uppercase acronym plus lowercase noun on the same header line, so the two column headers do not read as a pair.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/light/L1/9",
      "severity": "P3",
      "location": "Values pane, remaining_shield (9000) and damage (2000) rows; Call Trace, current `calculate_damage` frame",
      "finding": "Changed values and the current frame are marked by hue and a left rule alone — the type is the same size and weight as the unchanged rows around them. One extra weight step on the changed figure would make the delta and the current position survive a squint and would not cost any information.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/light/L1/10",
      "severity": "P3",
      "location": "Values pane, unlabelled third column (Field, u32, [Field; 8])",
      "finding": "The Call Trace has a header row naming its columns; the Values pane has none, so the right-hand type column arrives without a label while the pane beside it establishes the opposite convention. A FRAME-weight header row (name / value / type) would make the two panes read as one family.",
      "criterion": "B4"
    }
  ]
}
```
