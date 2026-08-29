Expected elements: present

Presence check passes on every item. The identity bar is slim and carries `← aztec`, `0xb63616…6359`, `Partial`, `block 101`, both stepping directions in one group, the 48-tick scrubber with a distinct position marker at tick 5, the `128 / 1315` readout and the phase rail; the four regions below it are all panes — no explanatory band, no toolbar row, no explorer header or footer, no page scrollbar. Code is titled Code and shows the pinned position at line 32 with a caret and a highlight. Call Trace and Event Log are one tabbed region with Call Trace open and seven frames, and it holds the larger share of the middle column. Values is a separate pane below that region, not a third tab, and holds ten bindings with two marked as changed. The light surface is the requested theme axis and reads as a dense tool, not as marketing chrome. Nothing forbidden is present.

The weakest element is the **DECODED INPUT block in the Transaction pane (right column, roughly y 570–710): the SELECTOR and RAW rows, both rendering the bare string `0x`, and the note beneath them.** Both values sit in the copyable monospace identifier treatment reserved for real hashes and addresses, so an absence is dressed as a value and reads as a truncated or failed render. The note then asserts a fallback the rows do not perform — "the parameters are shown as raw bytes" above zero bytes — and offers a remedy that cannot succeed: supplying an ABI decodes nothing when there is nothing to decode. `viewutil.nim:203` has an em-dash absence path for exactly this case; a two-character stub selector keeps it from firing. No calldata and undecodable calldata are different states with different answers, and the pane shows the second while holding the first. Honesty failure, so P1.

```json
{
  "view": "debugger",
  "size": "wide",
  "theme": "light",
  "image": "screenshots/debugger__wide__light.png",
  "reviewer": "ADV",
  "expectedElements": "present",
  "missing": [],
  "rating": null,
  "findings": [
    {
      "id": "debugger/wide/light/ADV/1",
      "severity": "P1",
      "location": "Transaction pane (right column), DECODED INPUT block ~y 570–710 — the SELECTOR and RAW rows and the note beneath them",
      "finding": "SELECTOR and RAW both render as the bare string `0x` in the copyable monospace identifier treatment used for real hashes and addresses, so an absent value is presented as a value and reads as a truncated or failed render. The note beneath them — 'This selector is not in any ABI BlockTracer holds, so the parameters are shown as raw bytes. Supplying an ABI decodes them.' — describes a raw-bytes fallback the rows do not perform, and offers an action that cannot change the answer, because there are no bytes to decode. The transaction has no calldata; the pane presents that as undecodable calldata, which is a different state with a different remedy. `client/src/viewutil.nim:203` already carries an em-dash absence path for this case and it never fires, because the published selector is the two-character stub `0x` rather than empty. Roughly 140 px of the narrowest, densest pane is spent saying nothing accurately.",
      "criterion": "B8"
    }
  ]
}
```
