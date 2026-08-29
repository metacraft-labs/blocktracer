Expected elements: present

All required elements render: slim identity bar with truncated hash, chain link, both stepping directions, scrubber, position readout and phase rail; Code pane with the current line 32 marked; Call Trace and Event Log as one tab strip with Call Trace open and seven frames; Values as a separate pane below it; Transaction metadata pane. No spinner, no empty pane, no explanatory band above the panes, no full-width row.

Typographically the page is coherent — one mono face for data, one sans for chrome, four legible levels — and it fails at the boundaries: long values, and the identity bar.

- **P2** Transaction pane, FEE PAYER and TARGET: 40-hex addresses wrap mid-byte onto a second right-aligned line, with no ellipsis or separator. §6 names mid-byte truncation as the failing example.
- **P2** Numerals: separators in the Call Trace ACIR column (1,315 / 1,208) but nowhere else — Values shows 10000, 9000, 2000; COST·MANA shows 88000 / 200000.
- **P2** Call Trace: the path `zk_shields · src/shield.nr` is the smallest, dimmest type on the page, yet it is the only thing separating the two `calculate_damage` and two `calculate_remaining_shield_pct` frames.
- **P2** Identity bar: "Engine loading — 18 MB" and "128 / 1315" match the transaction hash in size and brightness, so transient status outranks identity; and four case conventions sit in one 44 px strip.
- **P2** Clipped lines carry no indicator — Code lines 40/53/64 stop mid-identifier at the pane edge; RAW block cuts `"contract": "0x1b31c04d5920b0b5936f12` at the panel edge.
- **P2** DECODED INPUT: SELECTOR and RAW both render as the bare prefix `0x`, reading as truncation that removed the value.

Highest-priority fixes: give long hex a single-line middle-elision rule (fee payer, target, raw values) instead of wrapping mid-byte; and set the identity bar's status text one step below the hash.

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
      "location": "Transaction pane, FEE PAYER and TARGET value rows",
      "finding": "Both 40-hex addresses wrap mid-byte onto a second, right-aligned line (0x01c8f081e2abedf0184953e2a272b5 / e430d5d932 and 0x1b31c04d5920b0b5936f12e6fe8f17 / a59161624c) with no ellipsis, no separator and no signal that the two lines are one value. The brief names truncation mid-byte as the failing example of hash treatment. Every other value row in the pane is a single line, so these two also break the row rhythm.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/2",
      "severity": "P2",
      "location": "Call Trace opcode column vs Values pane vs Transaction pane COST · MANA row",
      "finding": "Thousands separators are applied only in the Call Trace ACIR column (1,315 / 1,208); the same magnitudes appear unseparated in Values (10000, 9000, 2000, 1000) and in COST · MANA (88000 / 200000). One page shows two numeral conventions for comparable magnitudes, so the reader cannot judge scale at a glance across panes.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/3",
      "severity": "P2",
      "location": "Call Trace pane, module/file path beside each frame name",
      "finding": "The qualifier 'zk_shields · src/shield.nr' is the smallest and lowest-emphasis type on the page (~10 px), yet it is the only thing distinguishing the two calculate_damage frames (rows 3 and 6) and the two calculate_remaining_shield_pct frames (rows 4 and 7) from one another. The disambiguator is set below the ambiguous label, which inverts the hierarchy exactly where a deep trace needs it.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/4",
      "severity": "P2",
      "location": "Identity bar, centre — 'Engine loading — 18 MB' and '128 / 1315' against the hash at the far left",
      "finding": "The transient loading status and the byte counter are set at the same size and the same brightness as the transaction hash 0xb63616…6359, so the loudest text in the bar is the text that disappears when the session finishes loading. Identity should outrank status by at least one level of size or weight.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/5",
      "severity": "P2",
      "location": "Identity bar, full width",
      "finding": "Four case conventions share a 44 px strip with no rule mapping case to role: 'block 101' lowercase sans, 'Partial' title-case pill, 'FETCHING / OPENING / POSITIONING' and 'NOIR' uppercase letterspaced, 'Share' / 'Download trace' title case. Because case is not carrying a consistent meaning, the bar reads as a row of unrelated objects rather than as grouped identity, controls, status and actions.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/6",
      "severity": "P2",
      "location": "Code pane lines 40, 53 and 64; Transaction pane RAW (CHAIN-NATIVE) block, \"contract\" line",
      "finding": "Long lines stop dead at the container's right edge with no ellipsis, fade or visible scroll affordance: line 40 ends at 'shield_regen_perce', line 53 at 'damage: Field, r', and the raw JSON is cut at '\"contract\": \"0x1b31c04d5920b0b5936f12' with no closing quote. Nothing on screen tells the reader whether the value continues or ended, which is the one thing a truncation treatment exists to say.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/7",
      "severity": "P2",
      "location": "Transaction pane, DECODED INPUT — SELECTOR and RAW rows",
      "finding": "Both values render as the bare prefix '0x' with no digits, immediately above prose stating that the parameters are shown as raw bytes. Set in the same bright mono as real values, '0x' reads as a truncation that removed everything rather than as a stated absence; an empty value needs a word, not a prefix.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/8",
      "severity": "P3",
      "location": "Code pane, note line above line 26",
      "finding": "'Showing from line 26 — the session's position is below, and the lines above it are not in this window.' runs the full ~890 px pane width as a single ~110-character line in the UI sans, inside an otherwise monospace listing. At this measure the eye has to track back across the whole pane, and it is the only sans prose in the pane.",
      "criterion": "B2"
    },
    {
      "id": "debugger/wide/dark/L1/9",
      "severity": "P3",
      "location": "Call Trace pane, column header row",
      "finding": "'FRAME' is uppercase and letterspaced while its opposite number is 'ACIR opcodes' — an uppercase token followed by a lowercase word. One header row uses two treatments, so 'ACIR opcodes' reads as a caption rather than as the peer of FRAME.",
      "criterion": "B4"
    },
    {
      "id": "debugger/wide/dark/L1/10",
      "severity": "P3",
      "location": "Transaction pane, top two lines",
      "finding": "The truncated pill 0x636167a…66d46359 sits directly above the full 0x636167a05b9de55bde67756bdaed6e766d46359 on the next line. The pane's two brightest mono lines carry the same value, so the truncation buys no space and instead costs a level of hierarchy at the top of the pane.",
      "criterion": "B3"
    },
    {
      "id": "debugger/wide/dark/L1/11",
      "severity": "P3",
      "location": "Transaction pane, 'Status reason' line",
      "finding": "'private-part-succeeded-public-part-succeeded' wraps at an internal hyphen, breaking as 'public-part-' / 'succeeded'. A machine identifier broken at a hyphen at the line end is indistinguishable from typographic hyphenation, so the reader cannot tell whether the trailing hyphen is part of the value.",
      "criterion": "B7"
    },
    {
      "id": "debugger/wide/dark/L1/12",
      "severity": "P3",
      "location": "Transaction pane, EXECUTIONS section",
      "finding": "The sub-labels 'private' and 'public' are lowercase sans and share their left edge with the uppercase letterspaced section labels (BLOCK, CANONICAL, FINALITY, EXECUTIONS, DECODED INPUT). Sharing the edge makes them read as peers of the section labels in a different case rather than as a level below them.",
      "criterion": "B3"
    }
  ]
}
```
