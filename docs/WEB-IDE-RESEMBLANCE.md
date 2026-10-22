# Does the served BlockTracer debug route look like the CodeTracer IDE?

> **Status:** live.
> **Captured by:** `node tools/capture/compare-with-codetracer.mjs --out <dir>`
> **Last looked at:** 2026-10-22, against a local `just export-hydrated` tree
> and `https://noirstudio.dev` **in replay mode, with a trace loaded**.
> Previously 2026-10-14, against `https://blocktracer.org` and
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

**AND THAT IS THE WRONG SUBJECT, found 2026-10-22.** "New file" opens an empty
editor, so the tool photographs an IDE with **no trace loaded**: `FILES | VCS |
TESTS` over an empty tree, an `#untitled0` tab holding one blank line,
`CONSTRAINTS — unavailable`, and about 85% of the frame flat empty grey. The
subject predicate asks whether the page got *past the welcome card*, which is
not the same question as whether it *has a trace open*, so the tool reported
success on it. Every row of §2 below that is about a POPULATED pane was
therefore being compared against emptiness.

The replacement needs no credentials and no desktop install:
**`https://noirstudio.dev`, then click `#run-image`** — the toolbar's run
control — and wait for `[id^=calltraceComponent]`. That is the same product in
**replay mode** with a real recording: `STATE` holding locals, `CALLTRACE`
holding frames, `EVENT LOG` with its own columns. Everything measured on
2026-10-22 below came from there. `compare-with-codetracer.mjs`'s CodeTracer
predicate should be strengthened from "past the welcome card" to "has a loaded
trace" before it is next believed.

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
  **CASE: CLOSED 2026-10-22.** The panes are now `CODE`, `CALL TRACE`,
  `EVENT LOG`, `VALUES`, `TRANSACTION`. The thing to check first was WHERE the
  capitals come from, and they are not a rule: measured on noirstudio.dev,
  `.lm_tab` and `.lm_title` both compute `text-transform: none` and the titles
  are literally `"FILES"`, `"STATE"`, `"SCRATCHPAD"`. A `text-transform` here
  would have been BlockTracer inventing chrome the product does not have in
  order to imitate a product that reaches the look another way, so the strings
  changed instead (`debugger/session_layout.nim`). File tabs stay as written in
  both: CodeTracer's document tab reads `src/main.nr`, and `.srctab` carries
  paths.
  **PIN AND CLOSE: DELIBERATELY NOT, and this is the file that should say so.**
  The vendored `golden_layout.styl` brings `.lm_close_tab` and `.lm_pin_tab`
  rules with it and they are INERT here by choice. This route ships no
  JavaScript, so a pin or a close would be an affordance with nothing behind
  it — and that exact control was REMOVED from the metadata pane for that
  reason (`pages/debug.nim`, "the `×` was the single affordance here not held
  to the standard the stepping toolbar holds itself to two panes away, where
  every button that cannot act renders visibly inert"). Closing D-W1's second
  half would mean re-adding the dead control that decision took out. It stays
  open as a DIVERGENCE WITH A REASON, not as work.
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

## 2a. The verdict, 2026-10-22 — what a loaded CodeTracer showed

Re-measuring against a CodeTracer with a trace open (§1) overturned most of a
review round's tab findings and turned up one real defect underneath them.

**The tab idiom was already right, and reproduced faithfully.** A reviewer
reported BlockTracer's pane tabs as having an inverted selection cue: the
inactive tab is rounded on all four corners and floats detached, which reads as
selected. Measured, that IS CodeTracer's own vocabulary for *inactive* —

| | active | inactive |
|---|---|---|
| `border-radius` | `5.76px 5.76px 0 0` (top only) | `5.76px` (all four) |
| `box-shadow` | `0 7.68px 0 0 <panel>` — a same-colour bridge into the body | none |
| `::before` / `::after` | concave connector curves flaring into the panel | none |
| background | `#282828` — **same as the panel body and as the inactive tab** | `#282828` |

— and BlockTracer draws all of it, through the vendored rules, reached by
`ct_components_css.activeTabCss()`. "Zero fill contrast", "tabs stretched to
half the panel" (`flex: 1 1 0%` upstream too) and "labels left-aligned with
dead slab after them" (`.lm_title` is `text-align: start; width: 100%`) are
likewise all upstream's design, faithfully copied.

**THE REAL DEFECT WAS SCALE: the window was drawn at 87.5%.**
`register.debugger.density.body-size` was 14px, and because
`data-register="debugger"` sits on `<html>` that is the ROOT font size — while
every dimension of the vendored chrome is an `em` or `rem` off it.

| | CodeTracer | BlockTracer, before | after |
|---|---|---|---|
| tab height | 24px | 21px | 24px |
| tab label | 14px | **12.25px** | 14px |
| corner radius | 5.76px | 5.04px | 5.76px |
| active shadow bridge | 7.68px | 6.72px | 7.68px |
| connector curve width | 26px | 22.75px | 26px |
| strip gap / height | 4 / 28px | 3.5 / 24.5px | 4 / 28px |
| header height | 32px | 28.5px | 32px |
| panel inset | 8px | 7px | 8px |

One token moved to `{type.fontSize.md}`. The register stays denser than the
explorer where density belongs — `cell-y`, `cell-x`, `control-*`, `card-pad`
and `line` are untouched; shrinking the ROOT instead silently rescaled rules
this repository does not own.

**Also closed in the same pass:** every `mask-image` fade removed (upstream
spends zero gradients, across all eight vendored stylesheets); drop shadows
removed from every resting surface (upstream's only soft shadow is on a
tooltip, an overlay); the notice band taught to flow its prose into columns, so
it falls 183px -> 96px at 1440 and 74px at 1920 instead of holding one height
at every width; the metadata grid's label column capped so values get 157px
instead of 114px; the scrubber playhead floored at 4px instead of 2px on a
260px track.

**Still open, and now measured rather than impressions:** the tab label resolves
to `#dddddd` where upstream's label tier is `#c8c8c8` — one rung on the neutral
ramp, and no `--bt-*` TEXT role carries `#c8c8c8`, so closing it means adding a
role rather than repointing the bridge. The inactive label already matches
exactly (`#727272` both sides). D-W2 and D-W3 are unchanged.

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
