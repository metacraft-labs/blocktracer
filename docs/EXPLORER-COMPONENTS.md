# Explorer components — the web register against CodeTracer's component layer

**Subject:** BlockTracer's **explorer** register — home, chains, chain, blocks,
block, transactions, transaction, address, contract source, search, static
content, 404, and every §14 degraded state on those pages. Not the debugger
register; not the embed route.

**Instruction this implements.** [EXPLORER-TINT.md](./EXPLORER-TINT.md) moved two
primitives — the radius ladder (T-1) and elevation (T-2) — and declined four
candidates. The operator's reply to that pass is why this one exists:

> "my request was not merely about adopting colors, font sizes, etc. I meant a
> more complete reuse of the style, **the way that tab bars look, panel
> separators, the elements inside the panels**, etc."

The two constraints from the same conversation are unchanged and bind this pass:

> "The special arrangement on the blockexplorer page stays (i.e. the top bar,
> the transaction details panel, etc)."
>
> "The SDK is about the debugger page mostly, but the style of the web-site can
> be tinted a bit towards the codetracer design system."

**Reference.** Not `debugger_css.nim` this time. The reference is CodeTracer's
own component layer — `codetracer/src/frontend/styles/components/*.styl` —
read element by element against the classes the explorer actually renders.
EXPLORER-TINT.md used the in-repo debugger register because the question then
was *finish*, and the two registers share a token set. The question now is
*components*, and a component the explorer does not have cannot be found by
reading a stylesheet that also does not have it.

**Read with:** `tools/visual-review-brief.md` §2–§3. The explorer register is
graded against the **2026 CodeTracer web direction** — light canvas, generous
whitespace — while `components/*.styl` is the **desktop application's** style
layer. So what is adopted from those files is *geometry, state and structure*;
surface colour and density stay the web lineage's, resolved through `--bt-*`
exactly as before. §3's warning is the boundary: "applying the explorer rubric
to the debugger produces a beautiful debugger that shows less information,
which is a regression dressed as a win" — and the reverse is equally true.

**Checked:** 2026-09-25, against a real build (`client/dist`, 348 pages), 14
captures of 7 explorer views in both themes, a computed-style probe of the eight
states a still image cannot photograph, and an element-geometry diff of the two
built trees over 1026 boxes on seven routes.

---

## 1. The pairing, element by element

Every class the explorer renders, the CodeTracer component that is its
counterpart, and what happened. "Adopted" means the declarations were taken
from that file; "declined" rows carry the measurement or the property of this
product that declined them.

### Adopted

| Explorer element | CodeTracer counterpart | What was adopted |
| --- | --- | --- |
| `.filetree a` — the contract-source file strip | `components/tab.styl` `.ct-tab` | The whole component. A tab is a **rail, not a box**: no side or top border, a `--bt-stroke-thick` bottom border always drawn, `--bt-radius-xs`, transparent fill, and the state in the rail's colour plus a fill that appears on hover. Was four bordered indigo pills. |
| `.codefile` / `.codehead` | `components/golden_layout.styl` `.lm_content` / `.lm_title`, and the in-repo `.panehead` / `.panetitle` | The pane-header declarations: the register's own `--bt-density-cell-y` rung (was `--bt-space-xs`, the one header on the site not on the rhythm), `--bt-border-subtle` for the head's internal division (was `--bt-border-default`, a boundary as strong as the pane's own outline), `align-items:center`, and the label type for the pane's metadata — `7 LINES` rather than `7 lines`. |
| `.codefile:target` | `components/golden_layout.styl` `SELECTED_PANEL_BORDER` | The selected-pane cue, **and its reasoning**: "the outline is now the *only* selection cue … and a sub-pixel stroke is antialiased down to roughly half strength, which read as no indicator at all". So the pane a tab jumped to takes `--bt-border-strong` — same weight, one rung of contrast up, no hue spent. Measured: `#a2a2a2` → `#818181` on `:target` and unchanged on its neighbours. |
| `.notice` — every §14 callout and the synthetic-data provenance band | `components/notifications.styl` `.ct-notification-{info,warning,error,success}-primary` | The tone runs round the **whole border** on the ordinary panel surface. The thick left rail is gone; there is no rail anywhere in CodeTracer. |
| `.notice .btn` — the remedy inside a callout | `components/notifications.styl` `.notification-action-button` | `border-radius: 999px` → `--bt-radius-full`, `border: 1px solid currentColor`, `background: transparent`, `color: inherit`. The control is drawn in the colour of the block it sits in rather than in the button vocabulary. Its **size** is deliberately not adopted — density is the thing the two registers do not share. |
| `.nav input`, `.search input` | `components/input.styl` | The **state ladder**, whose third rung the explorer had never drawn: `:not(:placeholder-shown)` takes `--bt-border-accent` and `--bt-text-strong`, so a resolver field with a value in it no longer looks identical to an empty one. Plus `:hover` strengthening the text, and the placeholder coming forward on hover and focus. |
| `.badge` | `components/button.styl` `.ct-origin-badge` | `vertical-align:middle`. An `inline-flex` chip is still an inline box, so it aligned on the baseline of the text *inside* it and sat low beside every value it qualifies. |
| `.btn` | `components/button.styl` base `button` | `white-space:nowrap`. A control's label is its identity, and the Debug cell is a `position:sticky` column at a fixed width — the one place a two-word label wraps. |
| `.empty` — the "nothing here, and why" table cell | `components/empty_states.styl` | `overflow-wrap:break-word`, and the `br{display:none}` rule with CodeTracer's own reason: "where the line falls is the panel's decision, not the author's". Seven pages supply the sentence and the table reflows from `wide` to `mobile`. |

### Already CodeTracer's, and left alone

These were already drawing the counterpart's declarations before this pass. They
are listed because a later sweep will otherwise find them and "fix" them.

| Explorer element | CodeTracer counterpart | Why nothing moved |
| --- | --- | --- |
| `table.tbl th` | `.panehead` + `.panetitle` | A sunken strip, uppercase label type, hairline beneath — the pane-header treatment, one per column. |
| `.dl dt` | `.panetitle` | Same treatment, one per row. The transaction details panel's labels were already the product register's. |
| `table.tbl tbody tr:hover` | `data_tables.styl` `tr:hover` | Both tint the hovered row to the hover surface. |
| `table.tbl td` row separators | `data_tables.styl` `tr { border-top }` | CodeTracer separates rows with a top border and this uses a bottom border with the last one suppressed. Identical rendering; changing it would move nothing and churn a rule. |
| the syntax palette in `.codeview` | the product lineage's editor tokens | Design-System.md §7's one sanctioned crossing, already in place. |
| focus / hover / active | shared across both registers | See §2 D-C1 — declined deliberately. |

### No counterpart — BlockTracer's own treatment stays

CodeTracer is a desktop debugger; several things a block explorer needs do not
exist in it at all. These keep what they have, and this row is the statement
that a third style was **not** invented for them.

`.hero`, `.display`/`.h1` and the marketing type scale · `.chaincard` and
`.chainstrip` · `.stats`/`.stat` · `.crumbs` · `.copyfield`/`.copyhint`/
`.copybtn` · `.provchip` · `.pager` · `.foot`, `.footlinks`, `.footcredit`,
`.ctcredit`, `.repolink` · `.stub` · `.linklist`/`.linkrow` · `.eyebrow` ·
`.lead` and the prose-link treatment · `.tablewrap`'s right-edge fade ·
`.txtbl`'s stacked-card reflow below 900px · `.execlist` · `.debugcard`.

Two of those deserve a sentence. **The prose link** — CodeTracer's design system
has no running-prose link component, because a desktop debugger has almost no
running prose; the underline-with-offset treatment is this product's and stays.
**`.tablewrap`'s fade** — `data_tables.styl` has no overflow treatment at all
(it hides `thead` and lets rows clip), and this file's own rule is "ONE overflow
treatment, and it is the fade", stated at `.src` in `debugger_css.nim`.

---

## 2. Declined, with the reason

### D-C1 — Do not adopt CodeTracer's inset focus ring

**The idea.** CodeTracer rings a focused control with
`box-shadow: inset 0 0 0 0.125em colors-ui-border-focus`, on `button`, on
`input`, on the golden-layout controls — an inset ring, not an outline with an
offset. It is one of the most recognisable things about the surface.

**Why not.** Design-System.md §2 lists the focus-ring treatment among the
primitives the two registers **share**, and `styles.nim`'s global
`:where(a,button,input,…):focus-visible` rule is inlined into every page
including the debug route. Changing it here changes the debugger too, on a
branch that does not own the debugger, and it orphans `--bt-focus-width` and
`--bt-focus-offset` — two tokens with divergence rows. This is a token-layer
decision about both registers, not a stylesheet change in one.

### D-C2 — Do not adopt `pointer-events:none` on a disabled control

**The idea.** `components/button.styl` gives `button:disabled` both
`cursor:not-allowed` and `pointer-events:none`, and the explorer had only the
first. Adopting the pair looks free.

**Why not, measured on the markup.** All three inert controls in this product
carry a `title` whose entire job is to name why they refuse — "the oldest block
this generation indexes" and "the head of the chain at this generation" in
`pages/blockview.nim`, and the share control's unanchored label in
`pages/debug.nim`. `pointer-events:none` removes the element from hit testing,
which suppresses the native tooltip, so the rule would delete the only statement
each of those controls makes. It would also silently void `cursor:not-allowed`.
CodeTracer can afford it: its disabled controls are real `<button>` elements
that the UA already blocks, and none of them explains itself in a `title`. The
explorer's are `<span>`s that never navigated.

### D-C3 — Do not put the table body in the mono face

**The idea.** `data_tables.styl` sets `font-family: "SpaceMono"` and
`letter-spacing: -0.00875em` on the whole data table, so CodeTracer's tables are
monospaced end to end. The explorer's are the sans face with mono only in the
hash and address cells.

**Why not.** This is a decision already taken and recorded at "Mono means
machine value" in `styles.nim`'s header: mono marks a copyable identifier and
nothing else, and the rule was *introduced* to fix breadcrumbs, placeholders and
grid labels that were mono and should not have been. CodeTracer's table is
entirely machine values; the explorer's carries a Method name, a Status word and
a revert reason in English. Reverting it would re-open a closed finding.

### D-C4 — Do not hide the table header

`data_tables.styl` sets `thead { display: none }`. That is a density decision for
a debugger pane where the columns are known and the vertical space is not, and
it is exactly the case §3 of the review brief names: applying it here would
produce a table that shows less information. It is also the one element in the
explorer that carries the pane-header treatment, per §1.

### D-C5 — Do not dim the empty state with opacity

`empty_states.styl` dims its message with `opacity: 0.6`. The explorer's `.empty`
uses `--bt-text-muted`, which is a measured role — 7.74:1 on the light canvas,
8.23:1 on the dark. Stacking the two would dim a measured colour by an
unmeasured factor. The same rule's `display:flex` centring is declined for the
reason CodeTracer's own file gives when it excludes `.dt-empty`: "it is a table
cell, and `display:flex` would take it out of the table layout". This is that
cell.

### D-C6 — There is no second tab bar to convert

The operator asked about "the way that tab bars look". The explorer register has
**exactly one** tab-shaped element, `.filetree`, and it is now the component.
The other three tab strips in the product — `.srctabs`, `.stacktabs` and the
tab-menu overflow — are all on the debug route and already carry it. There is no
hidden fourth, and that is a swept claim rather than an impression. The class
inventory over the thirteen explorer pages and the seven explorer components is

```
cd client/src && grep -ohE 'class *= *"[^"]*"' pages/*.nim components/*.nim \
  | sed 's/.*"\(.*\)"/\1/' | tr ' ' '\n' | sort -u
```

— 259 distinct names, and the only one in the set that switches between named
views on an explorer page is `.filetree`. (`.srctab*`, `.stacktab*` and the
`kb*` set are in that list because `pages/home.nim` renders the live-demo
session and `pages/settings.nim` renders the shortcut list; both are drawn by
`debugger_css.nim` and neither is this branch's.)

Its **selected** rung is spent on the panel rather than the tab, and that is a
property of the page and not a shortcut: every file in a bundle is rendered,
stacked, on one page, so the strip jumps between panes rather than switching
between them and at rest no tab is the one open. The selection is therefore
where it actually is — `.codefile:target`.

---

## 3. The arrangement did not move, and here is the measurement

`tools/capture/check-arrangement.mjs` loads seven routes in two built trees and
compares the page-absolute box of every structural element: the nav and each of
its parts, the page body, each section and its container, the details panel and
each of its rows, every table and every cell, the callouts, the pager, the
footer, and the full tag-plus-class sequence of the document.

```
node tools/capture/check-arrangement.mjs <before-dist> <after-dist>
```

Run on 2026-09-25 over `/`, `/chains`, `/demo`, `/demo/txs`, the transaction
page, the contract-source page and the 404. **1026 boxes compared, 7 routes.**

| Claim | Measured |
| --- | --- |
| **The top bar is where it was** | `.nav`, `.nav .inner`, `.nav .brand`, `.nav form`, `.nav input`, `.nav .links` — **zero** differences on all seven routes, in every one of x, y, width and height. Not "the nav box is unchanged": each of its six parts is measured separately, so a bar whose outer box held while its contents swapped places would still fail |
| **The transaction details panel is where it was** | `.dl` on the transaction page: `504,779` before and after, width `912` before and after. **Its x and its width never change on any route.** Its height changed by 1px, and one `dd` moved down 1px |
| **Nothing was added, removed, renamed or reordered** | the tag-plus-class sequence of `body *` is **identical** on all seven routes — 0 document-shape changes, 0 element-count changes |
| **No page was restructured** | `.pagebody`, `section.sec` and `section.sec > .inner` hold their x and their width everywhere; only their heights move, by 1–16px |
| **The embedded product-register session is untouched** | `.livedemo` keeps its size exactly — 912×523 before and after — and moves 1px with the badge above it |

**The whole class of difference that is never "finish" — x or width — is 17
boxes out of 1026, and there are exactly two causes:**

| element | dx | dwidth | count | cause |
| --- | --- | --- | --- | --- |
| `.noticehead` | −1 | +1 | 4 | the notice's tone moved from a `--bt-stroke-thick` LEFT border to a `--bt-stroke-hairline` one on all four edges, so its content box starts a pixel left and is a pixel wider |
| `.measure` (a notice's sentence) | −1 | 0 | 4 | " |
| `.badge` (a notice's label) | −1 | 0 | 4 | " |
| `.btn` (a notice's action) | −1 | 0 | 1 | " |
| `.filetree a` | 0, −2, −4, −6 | −2 | 4 | each tab lost its 1px left and right borders — a `.ct-tab` is a rail with no side edges — so every tab is 2px narrower and each one after the first shifts left by the accumulated width |

**Nothing outside a `.notice` or the tab strip changed its x or its width
anywhere in the corpus**, and both are elements this pass deliberately
re-drew. The remaining 756 differences are y and height, from three causes:

1. **1px down-shifts of badges and the rows containing them**, on every page
   with a `.badge`. `vertical-align:middle` changes where the chip sits on its
   line box, which changes that box's height by a pixel. This *is* the change —
   the badge sat low — and it accumulates down a long table to at most 5px.
2. **1px shifts of everything below a notice**, from the same border change.
3. **16px up-shift of the source listings** on the contract-source page. Four
   pane headers each lost 4px moving from `--bt-space-xs` to the register's own
   `--bt-density-cell-y`. The panes keep their x and their width; the tab strip
   above them keeps its own left edge and its own top.

### 3a. The check decides — the negative control

A guard that has never been seen to fail is not evidence, and this repository
has the scar: `reviews/` records checks that stayed green while measuring
nothing. So the check was driven against four planted trees, each built from a
one-line change to `styles.nim` and compared with the committed build, and the
source restored from git in a shell trap so an abort could not leave it
planted. `negative-control.sh` in the scratchpad is the script; the verdicts:

| plant | what it moves | expected | exit | verdict |
| --- | --- | --- | --- | --- |
| *(none — tree against itself)* | nothing | not caught | 0 | **PASS**, and repeated 10× |
| `.nav{height: +--bt-space-md}` | the top bar's height | caught | 1 | **PASS** — names `.nav` 64→80 and all four children |
| `.brand{order:2}` | the brand's place in the top bar | caught | 1 | **PASS** — `.brand` x 504→1281, `.nav .links` 663→504 |
| `.dl{grid-template-columns: ×2}` | the details panel's label column | caught | 1 | **PASS** — 97 boxes, `.dl dt` width 160→320 |
| `.crumbs .sep{color: muted}` | nothing — a colour | **not** caught | 0 | **PASS** — a finish change must not fire it |

The last row is the arm that matters as much as the other three: a check that
fired on everything would make "the arrangement moved" unfalsifiable, and this
whole pass is finish changes.

**Two instrument defects were found by running it, and both were mine.**

1. **A fifth plant is missing from the table because it was a bad plant.** The
   first attempt at "move the top bar" set `justify-content:flex-start` on
   `.nav .inner` and was NOT caught — correctly. `.nav .links` is `flex:1 1
   auto` and absorbs all the free space, so that declaration moves nothing.
   The plant was a no-op and the check was right; it was replaced by the two
   in the table. A negative control can fail by testing nothing, which is the
   same failure mode it exists to detect.
2. **The check was flaky, and the flake would have been a false "it moved".**
   Comparing one tree against itself reported differences on roughly one run
   in eight, always on `/` and always on the top bar — `.nav[0]: 0,3,1920,64
   -> 0,4,1920,64`. The cause: the home page autofocuses its resolver field,
   focusing scrolls it into view, `html{scroll-behavior:smooth}` makes that
   scroll an animation, and the probe was recording `rect + scrollY` for an
   element that is `position:fixed` and does not move with the page. Fixed by
   construction — the probe now walks ancestors and records a viewport-relative
   box for anything carried by a fixed element — plus a scroll-settle loop so
   no measurement lands mid-animation. Ten self-comparisons since: all clean.

   The second half of that fix matters more than the first: testing the
   element's own `position` fixes `.nav` and leaves its five `static` children
   still reading `y = 576` on a scrolled page. Those five children ARE the top
   bar's parts, so the half-fix would have left the check blind on exactly the
   element the constraint names first.

**And one defect in the reading rather than the instrument.** The first pass
over this report classified the differences with `\s+(\S+)\[` — a regex that
cannot match a selector containing a space. It silently dropped `.nav .inner`,
`.dl dd`, `table.tbl td` and every other descendant selector, i.e. most of the
corpus, and produced a confident "13 boxes moved" that was wrong. The figures
in §3 are from the corrected reading. The claim "zero `.nav` differences"
happened to survive because it had been checked a second way, by grepping the
raw report — which is the only reason it is in this document.

## 4. The states a still capture cannot show, asserted

Four of the nine adoptions are states no screenshot of a static page can
contain. They are verified by computed style rather than by eye, before and
after:

| | before | after |
| --- | --- | --- |
| `.codefile` that is `:target`, `border-color` | `#a2a2a2` (same as its neighbours) | `#818181`, neighbours unchanged at `#a2a2a2` |
| `.filetree a`, bottom border / fill / colour | `1px #a2a2a2` all round / `#dddddd` / link indigo | `2px #a2a2a2` bottom only / transparent / `#484848` |
| `.nav input` with a value, border / colour | `#a2a2a2` / `#242424` — identical to empty | `#4f46e5` / `#101010` |
| `.search input` with a value | identical to empty | `#4f46e5` / `#101010` |
| `.notice` tone | top `#a2a2a2`, left `#dc2626` at 2px | all four `#dc2626` at 1px |
| `.notice .btn` | radius 6px, `#a2a2a2` border, white fill | radius 100px, `currentColor` border, transparent |
| `.badge` `vertical-align` | `baseline` | `middle` |
| `.btn` `white-space` | `normal` | `nowrap` |

## 5. Verification

| Step | Result |
| --- | --- |
| `cd client && just export` | **348 pages** |
| `node tools/design/check-tokens.mjs` | **PASS 17/17**, register unchanged at 247 / 188 `bkToken` / 59 `bkLiteral` / 12 rows |
| `node tools/design/check-tokens-selftest.mjs` | pass |
| `client && just test` | see below |
| `node tools/capture/capture.mjs --view … --theme light,dark` | 14 images, all 14 differ from the pre-pass set |
| `node tools/capture/check-arrangement.mjs` | §3 |

**One suite is red and it is red on `dev` as well.**
`test_explorer_breadth`'s *"the pointer was read once per navigation, not once
per session"* fails with `pointerReads == 4` where it expects 2. It was run on
`origin/dev` @ `ef24db5` with this branch's only file stashed and it fails
identically there, so it is not this pass's. It is a reader-caching assertion
and touches no stylesheet.

**No golden images exist**, so nothing in CI catches a visual regression on this
axis — the same gap EXPLORER-TINT.md §5 records. That is why §3 is a mechanical
geometry diff rather than "I compared them by eye", and why §4 asserts computed
values rather than describing them.
