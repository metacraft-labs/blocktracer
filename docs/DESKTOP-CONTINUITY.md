# Desktop continuity — the web debugger against CodeTracer

**Milestone:** VD.5 deliverable 7 — *"Continuity check against the desktop app's
equivalent panes, with divergences recorded."*

**Subject:** BlockTracer's debugger register — `/{chain}/tx/{hash}/debug`, the
home page's embedded session, and the panes they share.

**Reference:** CodeTracer desktop, `~/m/dev/codetracer` @ `eb1776ea`.

**Checked:** 2026-08-29, by reading the desktop's Nim sources directly
(`src/frontend/viewmodel/views/isonim_{calltrace,state,event_log,editor}_view.nim`,
`src/frontend/headless_app/layout_model.nim`, `src/frontend/ui/event_log.nim`,
`isonim_debug_controls_view.nim`) against this repository's
`client/src/components/debugger{,_css}.nim`, `client/src/debugger/*.nim` and the
captured screenshots — not by comparing names.

## What continuity means here

A desktop CodeTracer user must **recognise the tool**: the same pane
vocabulary, the same column semantics, the same ordering conventions, the same
control positions, a comparable density. It does **not** mean pixel identity,
and it does not mean copying affordances that need a running engine or
JavaScript — this route ships **zero JavaScript** by construction, and that
constraint is upstream of every row marked DELIBERATE below.

The distinction that matters when reading the table: a divergence forced by the
no-JS constraint is a *cost of the medium*, and a divergence that is not is a
*defect*. The check's job is to separate them, because the second kind is
invisible without the comparison — it looks like a design choice.

## What already matched

`defaultReplayLayout()` is **consumed, not restated**. The web walks the
desktop's own `LayoutNode` tree, so pane placement, the weight proportions and
the State/Event-Log stacking are identical by construction rather than by
agreement, and a change upstream arrives without an edit here. The source
pane's density is also a direct match (23 px pitch against Monaco's ~24 px).

## Divergence table

Verdicts: **DELIBERATE** — forced by the medium and defensible. **FIXED** —
a real gap, closed in VD.5. **OPEN** — a real gap, not closed. **HUMAN** — needs
a call this milestone cannot make.

| # | Pane | Divergence | Verdict |
|---|---|---|---|
| 1 | Call trace, event log | `.num` carried the explorer's numeric size/line-height into dense rows: the cost column rendered at 14 px/1.5 inside a 12 px/1.35 row, so the **cost number was larger than the function name it annotates** and the three list panes ran at three pitches (call trace 30, event log 30, state 25) where the desktop keeps one. | **FIXED** — `.num` is scoped to inherit size and line-height inside `.ct`, `.st`, `.ev`, `.mddl` and `.dc`; it keeps only the tabular-figure treatment those columns want. |
| 2 | Call trace | The indentation ladder was the **spacing scale**, which is geometric: steps of 16, 20, 24, **4** px, so depth 4 and depth 5 sat within a hairline of each other. Past `d5` there was no rule at all, so a deeper frame rendered at **zero** indent — a deep trace looked *flat*, which is indistinguishable from a correct shallow one. Desktop indents linearly and does not stop. | **FIXED** — a linear ladder to `d8`, and `depthClass` clamps beyond it and marks the row `.deeper` rather than emitting a class no rule answers. Covered by `test_debug_route`, which asserts every class the renderer can emit has a rule behind it. |
| 3 | State | Same defect: `d1`/`d2` only, on the geometric scale. A value nested three deep — any struct of structs — rendered at depth 2's indent, silently. | **FIXED** — same linear, clamped, marked ladder. |
| 4 | State | Column order was name → **type** → value. The desktop reads name → **value** → type. | **FIXED** — reordered, with the type kept as its own right-hand column so it stays scannable down the pane rather than landing at a different x on every row. |
| 5 | Debug controls | **`reverse-step-in` was missing entirely** — three reverse moves against four forward ones, on the surface whose premise is that time runs both ways. | **FIXED** — added; four pairs. |
| 6 | Debug controls | The toolbar was a **palindrome** (all reverse left, all forward right) while `DebugAction`'s own doc comment claimed "Backward first in each pair". The desktop lays out `[reverse-X][X]` pairs, which is how a desktop user reaches for them. | **FIXED** — reordered to the desktop's pairing; the comment is now true. |
| 7 | Debug controls | `reverse-step-out` and `step-out` **shared the glyph `⤴`** — two moves, one mark, on a toolbar whose whole point is direction. | **FIXED** — every glyph distinct. |
| 8 | Source | The tab strip named four files from the published bundle and **one was reachable**; the rest were inert `<span>`s. The desktop opens each file as its own tab. | **FIXED** — each document is a `:target` panel with a real link, and each panel carries its own strip so the active tab is right for any number of files, with no JavaScript. |
| 9 | Source | The pane rendered from line 1, so at `laptop` the current line fell **below the fold** — the toolbar claimed a step and no pane showed it. The desktop opens on the current statement. | **FIXED** — the pane opens on the position with a lead-in, and announces the window. Found independently by four of six reviewers in VD.5 round 1. |
| 10 | Metadata | The one pane the desktop does not have carried the **only dismiss control**, and nothing was behind it. The desktop's rule is the reverse: every GoldenLayout pane closes. | **FIXED** — removed. Dismissing it would also violate this route's own invariant that the metadata pane is present in every state. |
| 11 | Call trace | "Sort by cost" was styled as a link and was not one. The desktop call trace has **no sort concept at all**; this is a chain-domain addition (gas and opcodes are what a chain user ranks by). | **FIXED** — implemented as a real `:target` view. It renders **flat**: once rows are not in call order, an indent would draw a tree the ordering does not describe. |
| 12 | Call trace | Expand/collapse toggles, call arguments, `=> return value`, the `#index` suffix, the SVG connector tree and the search box are all absent. | **DELIBERATE** — every one needs JavaScript or a live engine. |
| 13 | Call trace | Module and cost columns added; the desktop has neither. | **DELIBERATE** — the chain domain's `1,315 ACIR opcodes` is the thing this product is for. |
| 14 | State | Locals/Globals/Watches tabs, the watch-expression input, the expand caret, the value-history button and the origin badge are all absent. | **DELIBERATE** — all need JS or a live engine. |
| 15 | State | A `changed` marker was added; the desktop has no such field, expressing change through value history instead. | **DELIBERATE** — the static route cannot offer history, so it marks the delta it *can* show. |
| 16 | Event log | Sort, search, category filter, dense/detailed toggle and the row counter are absent (desktop uses DataTables). | **DELIBERATE** — a JS widget. |
| 17 | Event log | Leading column inverted: the desktop leads with **time** (a graphical rr-ticks position bar), kind is fourth and iconographic. The web leads with **kind**. The scan axis is reversed. | **HUMAN** — the desktop's leading column is *graphical* and needs no JS to render statically, so the web could carry it. Whether the chain product should lead with time or kind is a product call. |
| 18 | Event log | Kind gets a text label and a per-kind glyph; the desktop gives kind no text at all. | **DELIBERATE, and better** — five kinds stay distinguishable without relying on colour. |
| 19 | Source | **No syntax highlighting.** Desktop uses Monaco. Design-System §3 makes editor tokens the one sanctioned register crossing, so this is the surface where the palette is most expected. | **OPEN** — raised by L3, L4 and L5 in *both* VD.5 rounds and the single most-cited finding of the milestone. The blocker is **tokenisation, not colour**: highlighting needs a lexer per language, which is the dependency shape (Monaco, Shiki, tree-sitter-wasm) this static route has deliberately refused — see `source_document.nim`. The colour side is nearer than it looks: `mapped/mapped.json` already carries `colors.editor.syntax.{primary,secondary,tertiary,subtle}` and the desktop ships a full lexical palette in `codetracerDark.json`/`codetracerWhite.json`, so that half is a port. But the DTCG family is four rungs of one neutral ramp with `modes.Light == modes.Dark`, so per-category hues and a real light mode still have to be decided. `renderSource` reserves the seam (one text node per line). |
| 20 | Controls | A 48-tick scrubber was added; the desktop's default layout places no scrubber (`Timeline` is a separate, unplaced pane). | **DELIBERATE** — a static page must express position. Discrete ticks avoid the per-render inline `style` the token lint's A5 rejects. |
| 21 | Naming | Web renders `CALL TRACE` (from the model's own title); the live desktop tab reads `CALLTRACE`. | **HUMAN, upstream** — the web is faithful to `defaultReplayLayout()`; **CodeTracer disagrees with its own model**. If either should change it is the desktop. |
| 22 | Event log | No captured evidence exists for this pane in VD.5 — `debugger--event-log` is `pending` on demo data (no transaction in the tree reverts), so the comparison above is **code-read only**. | **OPEN, in the evidence** — not in the code. Fix is one reverted transaction in the demo generator. |

## Summary

Ten divergences were real gaps and are fixed; nine are deliberate costs of a
no-JavaScript static route and are defensible as such; two need a human call
(the event log's scan axis, and a naming disagreement that is upstream's); one —
syntax highlighting — is a real gap left open with its blocker named, and the
blocker is the lexer this route will not take on, not a missing palette.

The gaps that mattered most were **not** the ones the no-JS constraint forced.
Rows 1–3 in particular were invisible on any single screenshot: a numeric class
leaking a larger size into dense rows, and two indentation ladders built on a
geometric scale that stopped ranking at the depths the panes are for. Nothing in
the register's own review rounds could have named them, because the rendered
page looked *deliberate*. They were found by comparing against the tool this
register exists to be continuous with, which is the argument for doing this
check at all.
