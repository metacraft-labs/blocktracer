# debugger · wide · dark — L5 (brand and register consistency)

Expected elements: MISSING — the identity bar's link back to the transaction detail page

The identity bar's only navigational affordance is `← aztec` (periwinkle, x≈28–74, y=31), which names the **chain**. The hash `0xb63616…6359` beside it is plain white monospace, and this page's link vocabulary is unambiguous (periwinkle + underline: `← aztec`, `101:0`, `Sort by cost`), so the hash is not interactive. Nothing routes back to `/aztec/tx/0xb636…`. That is finding #1, P1, and the rating is capped at 4.

Everything else the backbone requires is there and is genuinely product-register: dark, dense, full-viewport, no explorer footer, no page scrollbar, named load phases instead of a spinner, a positioned session (line 32, step 128/1315), a seven-frame call trace with guide rules, a state pane with changed values marked.

The register failure that matters most after that is that **the editor pane has no syntax highlighting at all** — `let`, `if`, `else`, literals and even the comment on line 56 are one off-white. Brief §3 makes editor tokens the one sanctioned register crossing; monochrome source in the debugger's *own* editor is where a CodeTracer user stops recognising the tool. Second: `Status reason: private-part-succeeded-public-part-succeeded` ships a raw enum identifier as prose in the flagship pane.

Highest-priority fixes: (1) make the identity bar's hash the link back to the transaction page; (2) apply the CodeTracer editor palette to the source pane.

Rating: 4/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L5",
  "expectedElements": "missing",
  "missing": [
    "Identity bar: a link back to the transaction detail page. The only link is '← aztec' (back to the chain); the truncated hash '0xb63616…6359' is plain white monospace with none of the page's own link treatment (periwinkle + underline)."
  ],
  "rating": 4,
  "findings": [
    {
      "id": "debugger/wide/dark/L5/1",
      "severity": "P1",
      "location": "identity bar, left group (y≈31): '← aztec  0xb63616…6359  Partial  block 101'",
      "finding": "No link back to the transaction detail page. The only navigational affordance is '← aztec', which is styled as a link and labelled with the chain, so it reads as 'back to the aztec chain'. The truncated hash is plain white monospace with no underline while every actual link on this page (← aztec, 101:0, Sort by cost) is periwinkle and underlined, so by the page's own vocabulary the hash is not interactive. The debug route is a deliberate register crossing and the way back out of it is not rendered.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/2",
      "severity": "P2",
      "location": "EDITOR pane, source body, lines 26–58 (x≈10–915, y≈310–1075)",
      "finding": "The source has no syntax highlighting whatsoever: keywords (let, mut, if, else), literals (100, 0), types (Field, u32), string literals on lines 54 and 58, and the comment on line 56 are all rendered in the same off-white as identifiers and punctuation. Brief §3 and Design-System §7 make editor-token highlighting the one sanctioned register crossing precisely so source looks like CodeTracer everywhere; a monochrome buffer inside the debugger's own editor pane is the strongest single reason a desktop CodeTracer user would not recognise this as the same tool. A generic web highlighter would already be a P2 register error; none at all is worse.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L5/3",
      "severity": "P2",
      "location": "TRANSACTION pane, second line under the hash (x≈1543–1900, y≈188–214)",
      "finding": "'Status reason: private-part-succeeded-public-part-succeeded' surfaces a raw kebab-case enum identifier verbatim as visitor-facing copy, in the product's flagship pane, directly beneath the 'Partial' badge it is meant to explain. Copy is a design property in this product and the rest of the page holds a high bar for it (the load banner, the 'Showing from line 26…' notice, the private-execution note are all real sentences). This one line is the seam where the ViewModel shows through; it should read as prose, e.g. 'the private part succeeded and the public part succeeded'.",
      "criterion": "B8"
    },
    {
      "id": "debugger/wide/dark/L5/4",
      "severity": "P2",
      "location": "DEBUG CONTROLS pane, button row (x≈18–268, y≈168–196)",
      "finding": "The eight stepping controls are unlabelled glyph buttons whose vocabulary is a media transport (◀ ▶ ⏮ ⏭) plus four ambiguous arrows (↖ ↘ |← →|). Reverse stepping is present, which the spec demands, but it is not legible as reverse stepping: nothing distinguishes 'step back over' from 'step out', and there are no keyboard hints, no tooltips visible, and no textual anchor. A CodeTracer desktop user cannot map this row onto the commands they already know, so the product's entire premise is expressed in a vocabulary borrowed from a video player rather than from the debugger it continues.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L5/5",
      "severity": "P2",
      "location": "across panes: source line 32 highlight; CALL TRACE row 6 'calculate_damage'; STATE rows 'remaining_shield' 9000 and 'damage' 2000; links '← aztec', '101:0', 'Sort by cost'; active phase chip 'FETCHING THE ENGINE AND THE TRACE'",
      "finding": "The single accent indigo is carrying four different meanings on one screen: hyperlink, current position (source line and current frame), changed-since-last-step value, and active load phase. The accent hue family is one of the primitives shared across both registers, and here it is overloaded to the point where it no longer says 'you are here'. The current-position use is the one that must be unmistakable (B5); the changed-value bars in the STATE pane use the same hue at the same saturation and compete with it directly.",
      "criterion": "B5"
    },
    {
      "id": "debugger/wide/dark/L5/6",
      "severity": "P2",
      "location": "CALL TRACE pane footer, 'Sort by cost' (x≈1448–1519, y≈462); TRANSACTION pane, BLOCK row, '101:0' (x≈1862–1908, y≈235)",
      "finding": "Underlined periwinkle prose hyperlinks are used for in-tool controls. 'Sort by cost' is a sort control on a table whose column header ('ACIR opcodes', y≈259) is the natural place for it; rendering it as a web link in a footnote beside 'Sorted by call order.' imports the explorer register's link idiom into a pane that otherwise reads as desktop-app chrome. The underline treatment is a marketing-surface primitive; the debugger register needs its own control affordance for the same job.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/7",
      "severity": "P3",
      "location": "identity bar hash '0xb63616…6359' (y≈31) versus TRANSACTION pane hash '0xb636167a…66d46359' (y≈163)",
      "finding": "The same transaction hash is truncated by two different rules on one screen — 6+4 characters in the identity bar and 8+8 in the TRANSACTION pane. Truncation is a shared primitive across both registers and the monospace treatment is the product's texture; one rule, applied everywhere, is the point.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/8",
      "severity": "P3",
      "location": "identity bar, right group: 'NOIR' (x≈1676–1702, y≈31), left of the Share / Download trace pills",
      "finding": "'NOIR' — a registry fact of exactly the kind this product badges everywhere else (Partial, Safe, Yes, Trace ready, Not observable, and the T0–T2 debug tiers in the explorer register) — is rendered as bare grey letterspaced caps with no pill. It sits between the transaction identity and two outlined action pills and reads as a label with no owner. Badging it would make the shared badge primitive consistent across the register boundary.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/9",
      "severity": "P3",
      "location": "TRANSACTION pane, EXECUTIONS block (x≈1543–1908, y≈450–585)",
      "finding": "Two label vocabularies at the same level inside one pane: the row labels above are uppercase letterspaced grey (FEE PAYER, TARGET, COST · MANA, EXECUTIONS) while 'private' and 'public' immediately below are lowercase monospace, so they read as values rather than as the labels they are. The explanatory sentence between them also begins lowercase — 'aztec private function executed client-side; only proofs, nullifiers and commitments are published — no call structure to trace' — which is the only sentence on the page not sentence-cased.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L5/10",
      "severity": "P3",
      "location": "whole-page pane layout: ~10 px outer margin on all four edges, ~10 px gutters between EDITOR / CALL TRACE / TRANSACTION, ~8 px pane corner radii",
      "finding": "The session is built as floating rounded cards on a page background rather than as a contiguous, gutter-less workspace split by draggable sashes, which is the desktop app's pane vocabulary. The idiom is a web dashboard's. It is a defensible choice at 1920 and the pane headers are consistent, but VD.5 is meant to record divergences from the desktop app and this is the structural one — the gaps also spend width the EDITOR pane is short of, where lines 40 and 53 run out of the pane.",
      "criterion": "B9"
    }
  ]
}
```
