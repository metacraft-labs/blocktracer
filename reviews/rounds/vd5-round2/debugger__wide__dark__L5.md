Expected elements: present

Every backbone item is there: slim identity bar (chain, truncated hash, `Partial`, block), dark dense product surface filling the viewport with no explorer chrome, source pane positioned at line 32 with a caret and highlight, a seven-frame call trace, a populated state pane, forward and reverse stepping controls in the open, a timeline with "Step 128 of 1315", and the transaction identity in both the bar and the right rail. The loading state is expressed as three named phases, not a spinner — that is the honest treatment the register asks for, and the copy ("18 MB, fetched once and cached"; "no call structure to trace") is the strongest brand asset on the screen.

The register itself is right; the divergences are all at the seams. The TRANSACTION pane (right rail) is the explorer's fact grid transplanted whole — letterspaced labels, badge pills for booleans, wide leading, prose paragraphs — sitting directly above a STATE pane at roughly half its row pitch, so the right column reads as two products stacked. In the identity bar, `Download trace` is a filled near-white pill and is the loudest element on a dark tool surface, outweighing the stepping controls. The EDITOR pane carries a prose banner narrating its own scroll position, which no desktop editor pane does. Tab and header primitives appear in three treatments across four panes.

Highest-priority fixes: re-cut the TRANSACTION pane to the STATE pane's density and label style; demote `Download trace` to the tool's own button weight.

Rating: 7/10

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "L5",
  "expectedElements": "present",
  "missing": [],
  "rating": 7,
  "findings": [
    {
      "id": "debugger/wide/dark/L5/1",
      "severity": "P2",
      "location": "right rail, TRANSACTION pane (BLOCK through EXECUTIONS rows)",
      "finding": "The metadata pane is the explorer register's overview grid moved across unchanged — letterspaced small-caps labels, generous row leading, badge pills for values, and multi-line prose — while the STATE pane immediately below it runs dense monospace rows at roughly half the row pitch. The right column therefore reads as a marketing fact panel bolted onto a tool, and the register crossing looks accidental rather than deliberate. A desktop CodeTracer user would not recognise this pane as belonging to the same application as the one under it.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/2",
      "severity": "P2",
      "location": "identity bar, far right — 'Download trace' button",
      "finding": "'Download trace' is a filled near-white pill and is the single highest-contrast element on the entire dark surface, louder than the current-line highlight and far louder than the stepping controls. Filled high-contrast CTA weight is explorer-register vocabulary; in the desktop app a secondary export action does not outrank the debugger's own controls. The visual hierarchy currently says the primary action of this page is exporting the trace rather than stepping through it.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/3",
      "severity": "P2",
      "location": "EDITOR pane, banner row above line 26",
      "finding": "'Showing from line 26 — the session's position is below, and the lines above it are not in this window.' is web-register explanatory prose inserted into a source pane. No editor in the desktop app narrates its own viewport, and the gutter already carries the information. The sentence also reads faintly apologetic ('are not in this window'), which is the wrong voice for a tool pane, and it costs a full row of source.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/4",
      "severity": "P2",
      "location": "pane headers — EDITOR file tabs vs STATE/EVENT LOG tabs vs CALL TRACE and TRANSACTION header bands",
      "finding": "Four panes use three different header primitives: CALL TRACE, TRANSACTION and DEBUG CONTROLS have an uppercase title band; EDITOR has a title band plus a second row of mixed-case monospace file tabs with an underline indicator; STATE/EVENT LOG has no title band at all, its uppercase tabs standing in for the header. Two visually different tab treatments express the same interaction, and one pane silently loses its title. Shared primitives are meant to be shared across the product, and here they are not shared across one screen.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L5/5",
      "severity": "P2",
      "location": "DEBUG CONTROLS pane, timeline track left of 'Step 128 of 1315'",
      "finding": "The scrubber renders as three small dots on a dotted hairline track. In a view that simultaneously announces 'FETCHING THE ENGINE AND THE TRACE', that shape reads as a loading ellipsis rather than as trace position, so the product's signature affordance is expressed in the vocabulary of a wait indicator. The desktop app's trace timeline is a substantial, scrubbable element; this is a hairline a user would not recognise as the same control.",
      "criterion": "B10"
    },
    {
      "id": "debugger/wide/dark/L5/6",
      "severity": "P2",
      "location": "identity bar, left — '← aztec' back link",
      "finding": "The only arrow-marked return affordance is labelled with the chain name, so the visible way out of the session goes to the chain rather than to the transaction detail page the session was launched from. The truncated hash sits beside it with no link affordance (no underline, no accent), so the route back to the transaction is at best invisible and at worst absent.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/7",
      "severity": "P3",
      "location": "identity bar, across its full width",
      "finding": "Four casing conventions inside one 40px bar: lowercase 'aztec', title-case 'Partial', lowercase 'block 101', letterspaced uppercase 'NOIR', and title-case 'Share' / 'Download trace'. 'NOIR' additionally carries no label, so a language badge is styled like an eyebrow heading. The bar is the first thing a returning desktop user reads and its typography currently has no single convention.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/8",
      "severity": "P3",
      "location": "TRANSACTION pane, CANONICAL row",
      "finding": "'Yes' is rendered in the same badge primitive used for status vocabulary elsewhere on the screen ('Partial', 'Safe', 'Trace ready', 'Not observable'). Spending a status badge on a plain boolean dilutes the badge role: badges should mean 'this is a state worth noticing', and a 'Yes' pill trains the eye to stop reading them.",
      "criterion": "B9"
    },
    {
      "id": "debugger/wide/dark/L5/9",
      "severity": "P3",
      "location": "notice band under the identity bar and DEBUG CONTROLS step counter",
      "finding": "The same fact is stated twice within about 90px of vertical space and in two different voices: 'Stepping starts once the replay engine loads — 18 MB, fetched once and cached' in the banner, and 'stepping starts when the replay engine finishes loading (18 MB)' appended to the step counter. The step counter is a numeric readout and should not carry a restated sentence; the duplication makes the honest-loading copy read as anxious rather than matter-of-fact.",
      "criterion": "B8"
    }
  ]
}
```
