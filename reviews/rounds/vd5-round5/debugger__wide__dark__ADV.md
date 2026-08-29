Expected elements: present

Presence check passes on every item. The identity bar is slim and carries identity (`← aztec`, `0xb63616…6359`, `Partial`, `block 101`), both stepping directions in one group, a scrubber, the position readout and the phase rail; the four regions below it are all panes with no explanatory band, no toolbar row and no explorer chrome; Code is titled Code and shows the pinned position at line 32; Call Trace and Event Log are one tabbed region with Call Trace open and seven frames; Values is a separate pane below that region, not a third tab, and is populated; the Transaction pane carries the identity. Nothing forbidden is present.

The weakest element is the status cluster in the identity bar, between the scrubber and the two actions: **"Engine loading — 18 MB" with the phase rail showing FETCHING lit and OPENING and POSITIONING unlit.** The rail's grammar is sequential and unambiguous — it says the engine has not opened the trace and has not positioned it. Everything to the right and below contradicts it: the readout says 128 / 1315, line 32 is the current line, the call trace has seven resolved frames with per-frame ACIR opcode counts, Values holds twelve live bindings, and the stepping controls are rendered active rather than disabled. On the flagship view — the one whose own spec calls this a fully loaded, positioned session, and which has a separate `debugger--loading-phases` view for the loading states — the page's one status readout reports a different state from the state it is displaying. A CodeTracer user reading that strip cannot tell whether the four panes are live or stale, which is exactly the trust this register is built on. That is an honesty failure, not a polish issue: P1.

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "dark",
  "image": "screenshots/debugger__wide__dark.png",
  "reviewer": "ADV",
  "expectedElements": "present",
  "missing": [],
  "rating": null,
  "findings": [
    {
      "id": "debugger/wide/dark/ADV/1",
      "severity": "P1",
      "location": "identity bar, status cluster between the scrubber and the NOIR/Share actions — \"Engine loading — 18 MB\" plus the phase rail (FETCHING lit, OPENING and POSITIONING unlit)",
      "finding": "The status readout and phase rail announce a session that is still fetching and has not yet been opened or positioned, while the rest of the page shows a fully positioned session: position 128 / 1315, current line 32 highlighted in Code, seven resolved call-trace frames with opcode counts, twelve populated Values rows, and stepping controls rendered active rather than disabled. The page reports a different state from the one it is displaying, so the one element that is supposed to tell the user whether the panes are live is the element contradicting them.",
      "criterion": "B8"
    }
  ]
}
```
