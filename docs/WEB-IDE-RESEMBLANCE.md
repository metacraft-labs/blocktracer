# Does the served BlockTracer debug route look like the CodeTracer IDE?

> **Status:** live.
> **Captured by:** `node tools/capture/compare-with-codetracer.mjs --out <dir>`
> **Last looked at:** 2026-10-14, against `https://blocktracer.org` and
> `https://ide.codetracer.com` (CodeTracer `cloud` 571c64cc — the same revision
> `client/hydrate/engine-pin.txt` pins the replay engine from).

## 0. Why this is a fourth axis and not a section of another file

[DESIGN-DIVERGENCES-WEB.md](./DESIGN-DIVERGENCES-WEB.md) says of itself, in its
own header: *"This document measures token PROVENANCE, not visual fidelity — a
binding can be 100% `bkToken` and still render nothing like CodeTracer."* It
names two other axes, [DESKTOP-CONTINUITY.md](./DESKTOP-CONTINUITY.md) (the
debugger register against the **desktop app**) and
[EXPLORER-TINT.md](./EXPLORER-TINT.md) (the explorer register's finish).

None of the three compares **what the two web deployments actually render**, and
neither does `tools/deploy/check-design-parity.mjs`: that asks whether every LIVE
row of the reachability register has a rule in the served stylesheet, whether the
`url()`s resolve and whether pages carry a script. All of those pass over a page
that looks nothing like the IDE — a rule can exist and match nothing, an icon can
load into an element nobody positioned, a script can hydrate the wrong chrome.
**Existence is not resemblance**, and the question this file answers is the
second one.

## 1. The subjects, because both needed choosing

**BlockTracer.** Not every transaction page is a workspace. A transaction with no
trace renders the degradation view — *"No trace, and none possible"*, ~5,712
bytes, no `lm_goldenlayout`. Measured 2026-10-14 on the live origin: every
sampled `/aztec/tx/…/debug` is that page and every sampled
`/aztec-testnet/tx/…/debug` is the real workspace (~19,885 bytes, carries
`lm_goldenlayout`). The first capture taken for this file photographed an
`/aztec` page and compared a fallback screen with an editor; the tool refuses a
page without the layout markers now.

**CodeTracer.** `https://ide.codetracer.com/` opens on a **welcome card** —
"Welcome to CodeTracer", recent folders, recent traces — not the IDE. Its own
copy names the way through: *"New file works here and opens an editor straight
away."* The tool clicks it and waits.

## 2. The verdict, 2026-10-14

**Structurally close in the workspace. Visibly different in the chrome.**

### What matches

| | CodeTracer IDE | BlockTracer `/…/debug` |
|---|---|---|
| Layout | multi-pane workspace, golden-layout | same, `lm_goldenlayout` |
| Palette | near-black panels on a darker page | the same family |
| Type | mono for code and identifiers | the same |
| Secondary panes | tabs beside the primary (`VCS`, `TESTS`) | tabs beside the primary (`Event Log` beside `Call Trace`) |
| `prefers-color-scheme: light` | **stays dark** | **stays dark** |

The light-mode row is worth its own sentence. BlockTracer's debug route renders
byte-for-byte identically under `light` and `dark`, which reads as a defect —
until CodeTracer is captured the same way and does the same. It is **shared
behaviour, not a divergence**, and the tool asserts the AGREEMENT rather than
either one's value, so a future change on either side shows up here instead of
being discovered as a bug report.

### What differs — three, named

- **D-W1 — panel header case and affordances.** CodeTracer: `FILES`, `VCS`,
  `TESTS`, `CONSTRAINTS` — uppercase, each carrying a pin and a close control.
  BlockTracer: `Code`, `Call Trace`, `Event Log`, `Values`, `Transaction` —
  title case, no pin, no close. This is the most visible chrome difference at a
  glance, and the cheapest to close.
- **D-W2 — no bottom status bar.** CodeTracer carries one:
  `unknown | UTF-8 | stable:` at the left, `BUILD PROBLEMS FIND IN FILES
  REQUESTS` centred, `cloud 571c64cc` at the right. BlockTracer has nothing
  there; its panes run to the bottom of the viewport.
- **D-W3 — the top bar is a different object.** CodeTracer: an icon toolbar and
  a command palette (*"Navigate to file or run a :command"*). BlockTracer:
  explorer chrome — a back link, the transaction hash, status badges, the block
  — with the step controls, scrubber and step counter inline beside them.
  **Partly deliberate:** this is an explorer showing one recorded execution, not
  an editor that opens files, so a file palette would name nothing. Recorded
  because it is the largest visual difference, not because it is plainly wrong.

## 3. What the tool asserts, and what it leaves to a reader

It asserts three things a picture settles and a stylesheet cannot: that the
BlockTracer subject really is the workspace, that the CodeTracer subject really
left the welcome card, and that the two origins answer `prefers-color-scheme`
the same way. **Everything else above came from looking at the images**, and the
tool does not re-judge it — a resemblance check that scored itself would be
measuring its own thresholds.

`--selftest` drives the two subject predicates over synthetic pages in both
directions, including the degradation page and the welcome card, because a
predicate that accepted either would photograph the wrong screen and report
success.
