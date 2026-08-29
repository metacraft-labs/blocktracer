# Inspection note — the Call Trace / Event Log tabbed region

**This is an inspection note, not a ledger review. It carries no ledger block and
must not be ingested.** The reason is that `debugger--event-log` is a `pending`
view: `tools/capture/views.mjs` records that no transaction in the demo tree
reverts, so the pane can render only four of its five entry kinds while the
view's own must-show list requires the fifth ("the revert entry rendered as the
terminal, significant event it is"). A ledger block filed against that image
would be a P1 for a data gap that is already written down. What follows is
therefore scoped to the **tab mechanism and the region's presentation** — the
things the missing revert has no bearing on.

Images inspected, all four read directly:

- `screenshots/debugger--call-trace__wide__dark.png` — 608 × 588
- `screenshots/debugger--event-log__wide__dark.png` — 608 × 544
- `screenshots/debugger--call-trace__laptop__light.png` — 455 × 469
- `screenshots/debugger--event-log__laptop__light.png` — 455 × 425

Both are clips of `.ln.stack`, the whole region, so the strip is in every frame.
Corroborating full-page frames used for the geometry question:
`screenshots/debugger__wide__dark.png` and
`screenshots/debugger--divergent__wide__dark.png`. All colour and contrast
figures below are sampled pixels and computed WCAG ratios, not impressions.

---

## a. Is the active tab unmistakably distinguishable, in both states and both themes?

Yes, and by two independent signals, both of which survive at laptop/light.

**Signal one — text colour.** In dark, the open tab's label is `#F3F3F3`
(16.31:1 against the strip's `#161616`) and the closed tab's is `#919191`
(5.74:1). In light, the open tab is `#101010` (17.15:1 against the strip's
`#F3F3F3`) and the closed tab `#565656` (6.61:1). The separation is roughly
2.6–2.9× in ratio terms in both themes; nothing about it weakens at 1440.

**Signal two — a 2 px underline** under the open tab only. Dark uses indigo-400
`#818CF8` at y = 25–26; light uses indigo-600 `#4F46E5` at y = 26–27. Two pixels
in both themes, spanning the whole tab box: x = 1–91 for Call Trace, x = 92–175
for Event Log, identically at both viewports.

**Weight is not a signal, and neither is surface.** I counted full-strength
glyph pixels inside each label box: "CALL TRACE" renders 64 ink pixels at wide
whether it is the open tab or the closed one, and "EVENT LOG" renders 51 in both
states; at laptop the counts are 67 and 63, again identical across states. The
labels' horizontal ink extents are also identical between states (x 9–82 and
x 100–165). So the type is one weight, one size, one tracking, and only its
colour changes. There is likewise no per-tab surface: a row scan across the
strip at mid-height returns one uninterrupted background value from border to
border, so no tab is lifted or recessed relative to its neighbour.

Two signals is enough, and the underline in particular is unambiguous. I would
not raise a finding here.

## b. Does the inactive tab read as clickable? Is there a title-plus-caption risk?

This is the weakest part of the strip, and it is the failure mode the view's own
"Watch for" names. The answer is: **the strip does not read as a title plus a
caption, but the inactive tab does not positively read as a control either — it
is signalled entirely by de-emphasis, using a token this product spends on
things that are not controls.**

The title reading is ruled out by measurement. Every other pane title in the
shell — CODE, VALUES, TRANSACTION in `debugger__wide__dark.png` — is `#A2A2A2`
at 7.09:1. The open tab is brighter than that (`#F3F3F3`, 16.31:1) and the
closed tab dimmer (`#919191`, 5.74:1), so the pair brackets the pane-title value
rather than matching it, and the underline has no counterpart on any pane title
at desktop width. The strip is visibly not a pane header.

The affordance problem is the closed tab's colour. `#919191` is the same token
the shell uses for the *not-yet-reached* phase chips OPENING and POSITIONING in
the identity bar, and for the inert "NOIR" language label — both sampled at
exactly `(145,145,145)`. It is also dimmer than the immediately adjacent
non-interactive column header FRAME (`#A2A2A2`, 7.09:1 dark; `#484848`, 8.24:1
light, against the closed tab's 6.61:1). So in the Call Trace state the closed
tab "EVENT LOG" is the **lowest-contrast text in the entire region** — quieter
than the table's own column heading, and painted in the vocabulary this design
system otherwise uses for "not yet" and "just a label". It carries no box, no
rule, no chevron, no icon, no hover-independent hint. The only thing telling a
visitor it is clickable is inference from the underlined word beside it.

It is made worse by a cross-viewport inconsistency I checked deliberately. In
`debugger--narrow__mobile__dark.png` and `debugger--narrow__tablet__dark.png`
the Event Log is dropped entirely ("The event log and stepping need a wider
viewport") and the strip collapses to a single "CALL TRACE" — **still carrying
the 2 px indigo underline**, at x = 5–94, with no peer to be selected against.
So at tablet and mobile the underline means "pane title"; at laptop and wide it
means "open tab". A visitor who has met the narrow layout has been taught that
this exact treatment is decoration on a heading.

Contrast is not the issue — 5.74:1 and 6.61:1 both clear AA, so this is not a
legibility P1. It is an affordance issue, and I would call it **P2 against B10**
(control ergonomics: a control whose only signal is that it is quieter than the
static text next to it). Location: the tab strip, second label, x = 92–175,
y = 1–27 in all four images. The cheapest fixes are the usual ones — lift the
closed tab to at least the pane-title value so it is not the quietest thing in
the pane, and stop drawing the underline when the strip has only one tab.

## c. Do the two states give the region the same geometry?

**Yes — and the 44 px height difference between the two files is a fixture
artefact, not a tab-state shift.** This is worth stating precisely, because the
raw file sizes invite the opposite conclusion.

Within each theme the two states are pixel-identical where it matters:

| | Call Trace open | Event Log open |
| --- | --- | --- |
| Region width, wide | 608 px | 608 px |
| Region width, laptop | 455 px | 455 px |
| Strip band, wide/dark | y 1–26 | y 1–26 |
| Strip/body divider, wide/dark | y 27 | y 27 |
| Body top edge, wide/dark | y 28 | y 28 |
| Strip band, laptop/light | y 2–27 | y 2–27 |
| Strip/body divider, laptop/light | y 28 | y 28 |
| Body top edge, laptop/light | y 29 | y 29 |

Zero offset on every one. Header height, body top edge and width are the same in
both states, in both themes. The current-position row is also at the identical
y 183–207 in both, with the identical treatment (2 px indigo left accent at
x = 1–2, row fill `#312E81` dark / `#E0E7FF` light) — good cross-tab continuity
for B5.

The total heights do differ — 588 vs 544 at wide, 469 vs 425 at laptop, 44 px
each time — but that is because the two views are captured against **different
transactions**: `debugger--call-trace` uses `readyTx`, `debugger--event-log`
uses `divergentTx`, whose page carries an extra band above the session. I
confirmed this rather than assuming it. In `debugger__wide__dark.png` (readyTx,
Call Trace open) the region runs y 92–680, height 588. In
`debugger--divergent__wide__dark.png` (divergentTx, **also** Call Trace open —
the active underline sits at x 922–1012, the first tab, in both files) the
region runs y 166–709, height 544. So divergentTx yields a 544 px region with
the Call Trace tab open, exactly matching the Event Log crop. The tab mechanism
moves nothing.

No pixel offset to name, therefore no defect under (c). The only thing I would
flag is a **review-hygiene** point, not a design one: two views billed as "the
same region in its two states" are shot against two different transactions, so
any future geometry delta between them cannot be attributed without the
cross-check I just had to do. Worth pinning both to one fixture when the revert
transaction lands.

## d. Is the Event Log populated, does each kind read as its kind, and how empty is it?

**Populated, yes.** Eight real entries, no placeholder:

| # | Kind | Step | Content |
| --- | --- | --- | --- |
| 1 | CALL | 6 | `iterate_asteroids` · initial_shield=10000, regen=10% |
| 2 | OUTPUT | 22 | `----- iteration 0 -----` · stdout |
| 3 | WRITE | 31 | `shields[0]` 10000 → 9900 |
| 4 | EVENT | 58 | `ShieldImpact` iteration=0, damage=100 |
| 5 | OUTPUT | 74 | `Shield status 100% 10000` · stdout |
| 6 | WRITE | 96 | `shields[1]` 10000 → 8000 |
| 7 | CALL | 112 | `calculate_damage` mass=200 — **current position** |
| 8 | EVENT | 121 | `ShieldImpact` iteration=2, damage=2000 |

Four kinds, the fifth (revert) absent for the known data reason.

**Each kind does read as its kind, and by more than colour.** Every row carries
a gutter glyph whose *shape* differs — an arrow for CALL, a small centred dot
for OUTPUT, a filled diamond for WRITE, a hollow diamond for EVENT — plus the
kind spelled out in words, plus a body shaped to the kind: WRITE rows are the
only ones showing a before → after pair (`10000 → 9900`), EVENT rows lead with
an event name and named parameters, CALL rows with a callee and arguments,
OUTPUT rows with the printed text and a trailing stream tag. The colour-alone
anti-requirement is comfortably satisfied. Glyph colours sampled: CALL `#818CF8`,
WRITE `#60A5FA`, EVENT `#42BF70`, OUTPUT `#919191` in dark; `#544BE5`,
`#1E40AF`, `#609674`, `#585858` in light. CALL and WRITE are adjacent hues and I
would not trust them apart on hue alone in dark, but shape and word carry it.

**Emptiness.** Last ink row and empty tail:

- Event Log, wide/dark: content ends at y = 233; **310 px empty, 57.0 % of the
  region.**
- Call Trace, wide/dark: content ends at y = 252 (the footer line); **335 px
  empty, 57.0 % of the region.**
- Event Log, laptop/light: ends y = 233; 189 px empty, **44.5 %**.
- Call Trace, laptop/light: ends y = 252; 214 px empty, **45.6 %**.

So the comparison the question asks for comes out flat: **the two states are
equally empty, to within half a percentage point.** More than half the region is
dead space at wide in both. That is a real B1 finding, but it belongs to the
region as a whole and to the `debugger--call-trace` ledger review — which has
its own must-show item written to catch exactly this ("a call trace whose rows
end in the first third of a mostly empty region is the P2 this item exists to
catch"). I am recording the measurement here so the two states can be compared,
not filing it.

One thing the emptiness makes worse, and which *is* specific to the Event Log:
at laptop the detail column ellipsises — row 1 reads
`initial_shield=10000, r…` — while 189 px of the same pane sits unused below it.
Information is being dropped horizontally in a pane that has vertical room to
spare, with no affordance to recover it. **P3 against B1**, laptop/light, row 1
at y ≈ 44.

## e. B4, B3 and B10 applied to the tab strip

**B4 — pane structure and proportion. P2.** The strip's surface value is
reused for two other unrelated meanings inside the same region. In dark it is
`#161616`; so is the Call Trace's FRAME / ACIR-opcodes column-header band
(y 32–55); and so is the row tint on the Event Log's WRITE rows (y 83–106 and
y 158–181 — I checked that the tinted rows map exactly onto the two WRITE
entries and are not zebra striping, which would have hit rows 2/4/6/8). Light
does the same with `#F3F3F3`. One surface, three roles: *this is the tab
control*, *this is a column heading*, *this row mutated state*. §9 names "a
colour role used for two meanings" as a P2 example, and this is three. It also
means that in the Call Trace state the region opens with two stacked bands of
identical surface separated by a 1 px rule and a 4 px gutter, which is the
structural half of the title-plus-caption risk in (b).

Related and separately worth the P2: **the two states of one region have
inconsistent chrome**. The Call Trace state has a column-header band (FRAME /
ACIR opcodes) *and* a footer band carrying a status line and a control
("Sorted by call order." with a "Sort by cost" link, y 234–258). The Event Log
state has **neither** — no column header, so its numeric column (6, 22, 31, 58,
74, 96, 112, 121) is unlabelled and a reader cannot tell whether it is a step
index, a line number or a log ordinal; and no footer, so there is no ordering
statement, no count, and no control at all. B4 asks for consistent headers
across panes and this is the same pane in two states. Location: y 28–55 and
y 234–258 of the Call Trace crops, versus nothing at those positions in the
Event Log crops.

**B3 — hierarchy under load. Nothing at the strip; one P2 just below it.** The
strip itself is only two words and does not participate in load. But the current
row — the row B3 exists to protect — loses contrast in dark in *both* states. On
the `#312E81` current-row fill, the Event Log's kind word and step number stay
at `#919191`, which is **3.62:1**, down from 5.47:1 on a normal row. In the Call
Trace it is worse: the frame name, the single most important identifier in the
pane, switches from `#F3F3F3` (15.52:1) to indigo `#818CF8` on indigo, which is
**3.83:1**, and its module path drops to 3.62:1. Both are under the 4.5:1 AA
floor for text at this size, and both are on the one row that must be the most
legible in the pane. Light theme is fine (5.96:1 and 15.44:1 on `#E0E7FF`). I
would call this **P2**, with the note that a strict reading of §9's "text
unreadable in context — contrast below the floor" would make it P1; it is
readable, it is just under the floor. It is a dark-theme-only, current-row-only
failure and it is not an Event Log defect — it lives in both tabs and properly
belongs to the `debugger--call-trace` review. Location: wide/dark, y 183–207,
x 50–400.

**B10 — control ergonomics. P2 (the same one as in (b)), plus a P3.** The P2 is
the closed tab having no positive affordance signal. The P3 is target size: the
strip band is 26–27 px tall and the tabs are 91 px and 84 px wide, so the hit
areas are roughly 91 × 27 and 84 × 27. That is fine for the desktop register and
these views are captured at desktop sizes only — but the same component exists
at tablet and mobile in `debugger--narrow`, where 27 px would be under the touch
minimum. It happens not to matter today because the Event Log is dropped below
1440 and the strip degrades to a single non-interactive label, but the
27 px band is what would be inherited if the pair ever survives to narrow.
**P3**, tab strip, all four images.

One more B10 point, small: the Call Trace tab's underline runs x = 1–91, flush
against the region's left border with no inset, while the Event Log tab's runs
x = 92–175 and is visibly inset from its label. The first tab's rule therefore
touches the pane edge and reads faintly like part of the border. Defensible as
"the underline is the tab box", so **P3**, cosmetic, y 25–26 wide / y 26–27
laptop.

## f. Event Log defects the missing revert does not excuse

Everything here would still be true with a reverting transaction in the fixture.

1. **No column header, so the ordinal column is unlabelled.** (P2, folded into
   the B4 finding above.) The numbers 6 / 22 / 31 / 58 / 74 / 96 / 112 / 121 are
   correctly right-aligned as a numeric column, but nothing says what they
   count. The sibling tab labels its columns; this one does not.

2. **No footer, no count, no ordering statement, no control.** (P2, same
   finding.) The Call Trace states "Sorted by call order." and offers "Sort by
   cost". The Event Log states nothing. Combined with (3), a reader cannot tell
   whether they are looking at the whole log or the head of it.

3. **The log's completeness is unstated.** The highest entry shown is step 121
   of a 1315-step trace (the position readout in
   `debugger--divergent__wide__dark.png` reads `128 / 1315`), and 57 % of the
   pane below the last entry is blank. If eight entries is the whole log that is
   fine and the blank space is honest; if it is the first eight, the pane is
   showing an unquantified subset with no statement — which is the shape Rule 2
   and §9's "an unquantified quantity the spec requires quantified" exist to
   catch. The screenshot cannot distinguish the two, and *that is itself the
   finding*: the pane gives the reader no way to tell either. Note that the
   capture runs Chromium with `--hide-scrollbars`, so a scroll affordance would
   not photograph even if one exists. **P3 as observed, promotable to P2 if the
   log is in fact truncated.**

4. **No past/future boundary against the playhead.** The position is step 128.
   Entries at 6 through 121 have all already happened; none are marked as
   behind. The row marked current is the CALL at 112, not the last entry at or
   before 128 (the EVENT at 121), because the highlight follows the enclosing
   call frame — which is *consistent* with the Call Trace, whose highlighted
   frame is the same `calculate_damage` call, so I do not read it as a bug. But
   the consequence is that a log explicitly specified as "a position/ordering
   that ties entries to the trace" gives no visual answer to "which of these
   have already run", and the one row it does mark contradicts the ordinal
   ordering it prints. **P3 against B5**, wide/dark rows at y 183–207 and
   y 209–232.

5. **WRITE is the only kind with a row-surface tint, and in dark the tint is
   invisible.** `#161616` against the default `#1B1B1B` is a contrast ratio of
   **1.05:1** — a 2 % luminance step. Light is `#F3F3F3` against `#FFFFFF`,
   1.11:1, marginally more visible. So the encoding is asymmetric across the
   four kinds for essentially no perceptual return, while costing the surface
   role collision described under B4. Either commit to the tint at a legible
   step or drop it and let the glyph carry WRITE like it carries the other
   three. **P3**, rows at y 83–106 and y 158–181.

6. **The OUTPUT rows' stream tag is not in a column.** "stdout" trails the
   printed text and therefore sits at a different x on each OUTPUT row (y ≈ 69
   and y ≈ 145), and no other kind has a trailing tag, so the right side of the
   list is ragged. **P3**, wide/dark.

7. **Horizontal truncation at laptop with vertical room unused** — carried over
   from (d). **P3.**

---

## Summary

The tab mechanism is sound. The active tab is unmistakable in both states and
both themes by two independent signals (a ~2.7× contrast step and a 2 px indigo
underline), and the region's geometry is pixel-identical across the two states —
same width, same 27 px header band, same body top edge, same current-row
position and treatment. The 44 px height difference between the two files is a
fixture artefact and I verified it against the full-page frames.

What I would raise: the **closed tab has no positive affordance** and is painted
in the token this shell uses for inert labels, making it the quietest text in
the region (P2, B10); the **strip's surface is shared with two other roles**
inside the same region and the **two states have inconsistent chrome** — the
Event Log has neither the column header nor the footer-with-control its sibling
has (P2, B4); and the **current row loses contrast in dark** to 3.62–3.83:1 in
both states (P2, B3/B5, and not an Event Log defect — it belongs to the ready
view). Below that, a handful of P3s: the underline rendering as decoration on
the single-tab narrow layout, a 27 px strip height, an unstated log extent, no
past/future boundary against the playhead, an imperceptible WRITE tint, a ragged
stdout tag, and laptop truncation with 45 % of the pane empty.

Nothing in items 1–7 of section (f) is explained by the absent revert kind. When
the demo generator gains a reverting transaction and this view goes `ready`,
those findings will still be there, and the two views should be pinned to the
same fixture at that point so the pair really is one region in two states.
