# Explorer tint — the web register's finish, moved toward CodeTracer

**Subject:** BlockTracer's **explorer** register — home, chains, chain, blocks,
block, transactions, transaction, address, contract source, search, settings,
docs. Not the debugger register; not the embed route.

**Instruction this implements**, in the operator's two sentences:

> "The SDK is about the debugger page mostly, but **the style of the web-site can
> be tinted a bit** towards the codetracer design system."
>
> "**The special arrangement on the blockexplorer page stays** (i.e. the top bar,
> the transaction details panel, etc)."

**Reference:** the product register living in this same repository —
`client/src/components/debugger_css.nim` — read against
`client/src/components/styles.nim`. The debugger register is CodeTracer's
lineage by [Design-System.md](../../codetracer-specs/BlockTracer/Design-System.md)
§2, so it is the nearest and most honest reference available: it is the same
design system, the same token set and the same browser, which means any
difference between the two files is a difference of *finish* and not of
platform.

**Checked:** 2026-09-11, against a real build (`client/dist`, 348 pages) and 52
captures of 13 explorer views at two viewports in both themes.

**Companion documents.** This is the third axis. The other two:

| Document | Measures |
| --- | --- |
| [DESIGN-DIVERGENCES-WEB.md](./DESIGN-DIVERGENCES-WEB.md) | Token **provenance** — is each `--bt-*` a `bkToken` or a tracked `bkLiteral`. CI-enforced both ways. |
| [DESKTOP-CONTINUITY.md](./DESKTOP-CONTINUITY.md) | The **debugger** register's visual fidelity against the CodeTracer desktop app. |
| **this file** | The **explorer** register's finish against the product register it ships beside. |

None is a superset of another, and the reason is recorded in Design-System.md
§8.1: **the divergence ledger measures token provenance, not visual fidelity.**
A binding can be 100% `bkToken` and render nothing like CodeTracer. That is
exactly the condition this document found the explorer in — see §1.

## 1. What "tinted" can and cannot mean here

The explorer was already, on every dimension the token ledger can see,
CodeTracer's web lineage: Space Grotesk and Space Mono from the brand, indigo
`brand.600` as the accent, `graphite.50` as the light canvas, the brand's
spacing ramp, the brand's radius ramp, the brand's focus ring. Measured on the
tree this pass started from: **247 bindings, 188 `bkToken`, 59 `bkLiteral`, 0
untracked, 12 rows** — and `node tools/design/check-tokens.mjs` green at 17/17.

So there was no provenance work to do, and the question "why does it not look
like CodeTracer?" had to be answered somewhere the ledger cannot see. Reading
the two stylesheets against each other, it is answered in **geometry and
elevation, not in colour**: the explorer painted brand-correct colours onto
rounded, drop-shadowed cards while the product register painted the same
colours onto flat, hairline-bordered panes.

**That finding is why this pass changes no colour value at all.** Four candidate
changes were evaluated and all four declined — three of them colour (D-T1, D-T2,
D-T4) and one typographic (D-T3) — with §3 recording the measurement that
declined each. This is the "tinted a bit" hedge doing real work: the dimension
that looked most like the tint, warming the neutrals toward CodeTracer's
`graphite` ramp, turns out to move *away* from CodeTracer once you check who
consumes that ramp. The measurement is in §3 D-T1.

**Arrangement is out of scope by instruction and is untouched.** The top bar,
the transaction details panel, the pane composition, the navigation, the
information hierarchy and what appears where are all exactly as they were. Every
change below is a property of how a surface is *finished*, not of what surfaces
exist or where they sit — no rule in this pass changes a `display`, `grid-*`,
`flex-*`, `position`, `padding`, `margin`, `width`, `gap` or `order`, and the
diff can be read for that in one pass.

What that was checked against: `manifest.json` records **all 52** captures as
changed, which is the expected reach — every explorer page carries these rules.
Structural identity was then read by eye on five before/after pairs at full
resolution — `tx-detail` light and dark, `txs-list` light, `contract-source`
light and `home` light — on which every element holds its position and only
corner radius and shadow differ. That is a sample, not a proof; there is no
automated check that could make it one (§5).

## 2. What moved

### T-1 — The radius ladder, shifted one rung so both registers share it

Design-System.md §2 is explicit that this is a shared primitive:

> Shared primitives are shared. Type scale ratios, spacing scale, radii,
> focus-ring treatment, motion durations and the accent hue family are common to
> both registers. What differs is density, surface colour and default theme.

It was not shared. Measured over the two stylesheets, the explorer's ladder sat
**exactly one rung above** the debugger's at every step:

| Role | Debugger (unchanged) | Explorer before | Explorer after |
| --- | --- | --- | --- |
| **Overlay** — floats over the document | `lg` 12px | *(not used)* | *(not used)* |
| Container — pane, card, table, code well | `md` 8px | `lg` **12px** | `md` **8px** |
| Panel / control — button, input, callout | `sm` 6px | `md` **8px** | `sm` **6px** |
| Chip / mark — badge, file pill, copy target | `xs` 4px | `sm` **6px** | `xs` **4px** |
| Pill | `full` | `full` | `full` (unchanged) |

**The top row is the point.** The debugger uses `--bt-radius-lg` exactly twice,
and both are things that float: `.livedemo`, the bounded product-register embed,
and `.kbdlgbox`, the keyboard-shortcuts dialog. Both also carry
`--bt-elevation-overlay`. So in the product register `lg` *means* "this is over
the page" — and the explorer was spending that radius on seven in-flow
containers.

That is the same category error as T-2 below, in a second channel: the explorer
was dressing structural containers in the geometry **and** the shadow the system
reserves for overlays. The two changes are one correction, and after them the
explorer uses no `lg` at all while the debugger keeps both of its overlay uses,
so the token stays live.

**Where the mismatch was directly visible: the home page.** `home--live-demo`
renders the explorer's chain cards immediately above `.livedemo`, the embedded
product-register session, so both registers are on one screen with nothing
between them. That capture is the one to read first in any before/after set —
it is the seam Design-System.md §2 calls a deliberate transition, and a seam is
where two ladders that should agree can be seen not to.

Sixteen rules moved. Nothing else changed: the *relationships* between the rungs
are preserved, so the ladder is the same ladder, one step sharper — which is why
this is a tint and not a redesign.

**No contrast consequence.** A corner radius is not a colour.

### T-2 — Elevation: an in-flow panel is held by its edge, not by a shadow

The product register separates surfaces with borders and surface tone and uses a
shadow only for things that genuinely float — measured, `debugger_css.nim` uses
`--bt-elevation-overlay` three times and `--bt-elevation-raised` **zero** times.
The explorer used `raised` on five surfaces — three of them structural
containers that do not float — and put the **modal** rung on a sixth.

What changed (the measurement common to all of them is below the table):

| Rule | Before | After | Why |
| --- | --- | --- | --- |
| `.dl` — the transaction details panel | border + `raised` | border | It is a panel, not a card. |
| `.tablewrap` — the transactions table | border + `raised` | border | Same. |
| `.notice` — degraded-state callout | border + thick status rail + `raised` | border + rail | Three channels for one notice. |
| `.debugcard` — the debug call to action | **`overlay`** | `raised` | It is in flow and nothing is drawn under it; it was wearing a modal shadow. |
| `.chaincard` — interactive chain card | `raised` | `raised` | Unchanged: genuinely lifted. |
| `table.txtbl tbody tr` — stacked mobile rows | `raised` | `raised` | Unchanged: genuinely cards. |

**The shadow that was removed, measured.** This is the part that makes T-2 a
measurement rather than a preference. `--bt-elevation-raised` resolves to:

* light — `0 1px 2px rgba(16,16,16,.06), 0 2px 8px rgba(16,16,16,.05)`
* dark — `0 1px 2px rgba(0,0,0,.55)`

Composited against the canvas each panel actually sits on:

| Theme | Canvas | Shadow at its darkest | Contrast vs canvas |
| --- | --- | --- | --- |
| light | `#ececeb` | outer layer `#dfdfde` | **1.13:1** |
| light | `#ececeb` | both layers stacked `#d5d5d4` | **1.24:1** |
| dark | `#000000` | `#000000` | **1.00:1** |

**In dark the shadow was a black shadow cast on a black canvas — 1.00:1,
nothing at all.** That is the same class of defect the surface-ladder's own
`$description` in `web.tokens.json` records for round 5, where four "distinct"
dark surfaces measured 1.051, 1.051 and 1.057:1 apart and none was perceptible.

The two channels that remain, both of which already carried the panel:

| Theme | Panel fill vs canvas | Hairline vs canvas |
| --- | --- | --- |
| light | `#ffffff` on `#ececeb` = **1.18:1** | `#a2a2a2` = **2.16:1** |
| dark | `#1b1b1b` on `#000000` = **1.22:1** | `#565656` = **2.86:1** |

**Stated precisely, because one of these numbers does not go the convenient
way.** In **dark**, both remaining channels are stronger than a removed channel
that measured 1.00:1 — nothing was given up. In **light**, the hairline at
2.16:1 is comfortably the strongest of the three, but the shadow's stacked peak
(1.24:1) is *marginally stronger than the fill step* (1.18:1), so light does
lose a real, faint third channel. That loss is the change, and it is accepted on
two grounds: the fill and the hairline are both above the surface ladder's own
1.15:1 perceptibility bar and remain, and a panel that reads by fill and edge is
what the product register looks like. The four before/after pairs in §1 are the
check that it still reads; on the densest of them — the transactions table — the
header strip, row hairlines and fill step carry it with no visible change beyond
the corner.

Both tokens stay live and neither is orphaned — `--bt-elevation-raised` keeps
three explorer uses, `--bt-elevation-overlay` keeps three debugger uses. That is
deliberate: §3.2 of the divergence ledger records `--bt-rhythm-row` as a token
that was emitted into every page and read by nothing, and this pass does not add
a second one.

### T-3 — A stale measurement in the stylesheet's own header

`styles.nim` described `.sec-title` as "a real 20px heading between the 32px page
title and 16px body". Measured in the shipped CSS, `--bt-type-h2-size` — the
token `.sec-title` reads — is **24px**. The 32px and 16px in the same sentence
are correct. Corrected to 24px.

This is the failure mode `check-tokens.mjs` B4 exists to catch one class of:
prose about a value goes stale when the value moves, and nothing recompiles a
sentence.

## 3. What was deliberately NOT changed, and the evidence for declining it

Four candidates were evaluated and rejected. Each is recorded because a later
pass that sweeps "everything that differs" will find them again.

### D-T1 — Do not warm the neutrals to the graphite ramp

**The idea:** the explorer's light canvas is `colors.graphite.50` `#ececeb`, a
faintly warm grey, while every surface, border and text colour on top of it
comes from `colors.neutral.*`, which resolves to the pure-achromatic
`colors.grey.*`. A warm canvas under cool neutrals looks like an oversight, and
"tint" invites fixing it by moving the neutrals onto `graphite`.

**Why not.** Measured in `codetracer-design-system` @ `dfb1de1b` (the SHA
`flake.nix` pins), the `graphite` ramp is consumed by exactly one thing:
`alias/alias.json`'s `colors.neutral-warm.*`, eight bindings. And
`colors.neutral-warm.*` is consumed by **nothing** — `grep -c graphite` returns
0 for `mapped/mapped.json` and 0 for `docs/codetracer-docs.tokens.json`.
CodeTracer's product lineage and its docs lineage are both built on the pure
`grey` ramp.

**So warming the explorer's neutrals would move it AWAY from CodeTracer, not
toward it.** The one visibly "CodeTracer-ish" colour move available is the one
that diverges. It is also unbuildable as stated: `graphite` has rungs
50/100/200/300/400/500/600/700/750/800 and the explorer's light theme alone
reads 50/100/150/250/350/400/450/500/800/1000, so half the ladder has no rung to
move to.

### D-T2 — Do not move the explorer's code well onto the debugger's pane surface

**The idea:** Design-System.md §7 says source code should look like CodeTracer
wherever it appears, "including in the explorer's contract-source browser". The
debugger's Code pane paints `--bt-surface-raised`; the explorer's `.codefile`
and `pre.raw` paint `--bt-surface-code`, which in light is the canvas colour, so
the same Noir source sits on white in one register and on grey in the other.

**Why not.** This is a decision already taken, with its reasoning recorded at
`debugger_css.nim:665-676`: the Code pane takes `raised` **because it is a pane
body**, and `--bt-surface-code` is "now only what its name says: the recessed
WELL an embedded listing sits in (`pre.raw`, the explorer's source blocks), and
it recesses to the page's own surface in both themes." The two registers are
rendering two different things — a pane whose whole job is the source, and a
listing embedded in a page of prose. §7 is satisfied by the **syntax palette**,
which does come from the product lineage in both themes. Undoing this would
reopen the round-5 finding that the flagship pane was byte-identical to the page
behind it.

### D-T3 — Do not lighten the heading weights, even though the brand does

**The idea:** the brand's own composite type styles in `brand/brand.json` set
`header.heading-{sm,md,lg}` to `{type.ui.fontWeight.medium}` and reserve bold
for `titles.*`. The explorer sets **700 at every heading level**. There is also
a live review finding — `reviews/ledger.json` @ `2026-09-01.9`,
`tx-detail/wide/light/L1/6`, P3, criterion A4 — measuring a **weight inversion**:
the one level-one title carries the page's lightest relative stroke (3px on a
24px glyph) and the six repeated level-two headings the heaviest (3–4px on a
17px cap), so "size and weight still pull in opposite directions".

**Why not.** Because the opposite experiment was already run and measured.
`web.tokens.json`'s `base.type.h3.$description` records:

> the VD.2 round found that 20px/500 against 16px/400 body was 'barely a step',
> so the weight goes to the same 700 the other headings use and the level is
> carried by size alone against its neighbours.

So there is measured evidence on **both** sides: one round measured 500 as too
weak at the 20px rung, another measured 700 as producing an inversion at the
24px rung. Resolving that is a design decision with a real trade-off against
scanability on a page that competes with Etherscan on exactly that — it belongs
to a review round with captures graded against the rubric, not to a finish pass
whose remit is "tinted a bit". Flipping it here would also have moved every
`.btn` label, because `.btn` reads `--bt-type-h3-weight`.

Recorded here as the **highest-value open candidate** for the next visual round.

### D-T4 — Do not strengthen the panel edge, even though it measures below 3:1

**The finding, which is real and pre-existing:** `--bt-border-default` measures
**2.16:1** against the light canvas and **2.86:1** against the dark one — under
the 3:1 WCAG 1.4.11 floor for a non-text boundary. T-2 removed a channel from
three containers, which makes the question sharper.

**Why not.** The obvious fix is `--bt-border-strong` (3.30:1 light, 4.37:1
dark). But the debugger's panes are bordered `--bt-border-default` as well —
four rules against one — so changing the explorer's containers would **diverge**
the two registers on the very primitive T-1 just converged, to fix a number in
one register only. The panel edge is also not the only channel: the fill step
(1.18:1 light, 1.22:1 dark) carries the boundary with it, and the panel's
contents are AA-clean throughout (§4).

The right fix is a design-system decision about `border.default` across both
registers and both themes, which is a token change, not a stylesheet change.
Recorded, not taken.

## 4. Contrast, measured

No colour token changed value in this pass, and no rule changed which colour
token it reads. The table below is therefore a **verification that nothing
moved**, taken from the built page (`client/dist/index.html`) so the numbers are
the ones a browser receives, not a re-resolution of the DTCG source.

Every text role against every surface it can sit on, both themes, WCAG AA
normal-text floor **4.5:1**:

| fg | value | canvas | raised | sunken | code |
| --- | --- | --- | --- | --- | --- |
| **light** | | | | | |
| `--bt-text-strong` | `#101010` | 16.10 | 19.03 | 14.01 | 16.10 |
| `--bt-text-default` | `#242424` | 13.13 | 15.52 | 11.43 | 13.13 |
| `--bt-text-muted` | `#484848` | 7.74 | 9.15 | 6.73 | 7.74 |
| `--bt-text-subtle` | `#565656` | 6.21 | 7.34 | 5.40 | 6.21 |
| `--bt-text-link` | `#4f46e5` | 5.32 | 6.29 | 4.63 | 5.32 |
| `--bt-text-code` | `#242424` | 13.13 | 15.52 | 11.43 | 13.13 |
| **dark** | | | | | |
| `--bt-text-strong` | `#f3f3f3` | 18.93 | 15.52 | 13.29 | 18.93 |
| `--bt-text-default` | `#dddddd` | 15.46 | 12.68 | 10.85 | 15.46 |
| `--bt-text-muted` | `#a2a2a2` | 8.23 | 6.75 | 5.78 | 8.23 |
| `--bt-text-subtle` | `#919191` | 6.66 | 5.47 | 4.68 | 6.66 |
| `--bt-text-link` | `#818cf8` | 7.04 | 5.77 | 4.94 | 7.04 |
| `--bt-text-code` | `#dddddd` | 15.46 | 12.68 | 10.85 | 15.46 |

**48 of 48 pass at 4.5:1**, in both themes, before and after — identical,
because nothing in this pass reads a different colour than it did.

The weakest pair in the set is `--bt-text-link` on `--bt-surface-sunken` in
light at **4.63:1**, clearing AA by 0.13. It is unchanged by this pass and is
worth knowing about: it is the margin that any future move of either token has
to respect.

## 5. Verification

Run from the repository root, against the tree this document describes:

```
cd client && nim c -r --mm:orc -d:isServer -d:release --hints:off src/static_export.nim
node tools/design/check-tokens.mjs          # 17/17
node tools/capture/capture.mjs --no-build --view <explorer views> --size laptop,wide --theme light,dark
```

Executed on 2026-09-11, every step's real exit code recorded rather than the
status of the `echo` after it:

| Step | Result |
| --- | --- |
| `static_export` | **348 pages** |
| `node tools/design/check-tokens.mjs` | **PASS 17/17**, register unchanged at **247 / 188 `bkToken` / 59 `bkLiteral` / 12 rows** |
| `… --require-built` | pass |
| `node tools/design/check-tokens-selftest.mjs` | pass |
| root `just test` | pass |
| `client && just test` | pass |
| **totals across the Nim suites** | **787 assertions, 0 failures** |
| captures | 52 images; **all 52** differ from their baselines |

**One real defect was caught by this repository's own guard, and it was mine.**
`test_static_export`'s *"no raw hex colour survives in the SHIPPED view rules"*
failed on `#a2a2a2` and `#ffffff`. Both were in an explanatory **comment** I had
written above `.dl` — and `globalCss`'s comments are inlined into every page's
`<style>` block, so prose about a colour is shipped bytes. That is the same trap
`debugger_css.nim` names at its narrow rules ("naming it puts it back in the
served bytes"). The comments now name tokens and ratios, never values.

The eight final captures were re-taken from the committed tree and hash-compared
against the set that was reviewed by eye: **8 of 8 identical**, which is the
check that the later comment edits — which do change the shipped CSS bytes —
changed no pixel.

**No golden images exist, so nothing in CI can catch a visual regression here.**
`git ls-files '*.png'` returns nothing. The `visual-design-canary` job asserts a
run's byte-identity *against itself* — determinism, not appearance — and
`require-deterministic.mjs` describes itself as "the gate every
baseline-comparing check must pass through FIRST". The gate is real and it
works; what is downstream of it is a perceptual comparison with **no committed
baselines to compare against**. That is why the before/after set here was read
by eye as well as hash-diffed, and why §3's declined changes are written down
rather than left to be rediscovered: on this axis the record IS the regression
test.

## 6. The review round this pass skipped, run afterwards

§5 is a *verification* record — it proves the tree builds and the checks pass.
It is not a review. The pass that produced §§1–5 captured 52 images of 13
explorer views at two viewports and read **five pairs by eye**, and no review
round, no iteration and no quality gate were run before the change merged. This
section is the review, run against `dev` after the fact, and it corrects three
claims made above.

### 6.1 What was captured, and how much of it was read

| | §§1–5 pass | This round |
| --- | --- | --- |
| Named views in `views.mjs` | — | **85** (51 `ready`, 34 `pending`) |
| Views captured | 13 | **51 of 51 ready** |
| Viewports | 2 of 4 | **4 of 4** |
| Themes | 2 | 2 |
| Images per state | 52 | **308** |
| States captured | 1 | **3** — pre-tint, tint, and the fix below |
| Images read by a reviewer | 5 pairs | **802 before/after crops + 126 fix crops**, by 22 disposable sub-agents |

`85 × 4 × 2 = 680` is **not** the breadth of a full run and should not be quoted
as one: 34 views are `pending`, and many `ready` views declare their own viewport
subset (the debugger is `wide`/`laptop` only, `--narrow` is `tablet`/`mobile`
only). The full ready corpus is **308** images, and `check-coverage` agrees.

### 6.2 The instrument was checked before the result was believed

Two independent full capture runs of the *same* tree produced **308 of 308
byte-identical** images, so the before/after differences below are the product
and not the runner. The determinism canary passes on this machine and correctly
reports itself `ADVISORY` rather than tier-1, for the darwin reason VD.0 records.

Two views were observed to drift **across** capture sessions before that control
was established, and both are worth recording because neither is in the canary
set and nothing else would have caught them:

* `search` — the exported page shipped the *"Search is not running on this site"*
  degraded notice in some builds and the working resolver in others, changing the
  page height by 22px. The freshness gate on `/assets/search.js` decides which,
  and `just export`'s dependency on `search-bundle` does not always re-run it.
* `debugger--testnet-frames` — the source pane opened on line 76 in one build and
  line 84 in another, an 87,000-pixel difference on one image.

Neither is caused by this pass. Both mean the corpus is not reproducible from an
arbitrary build state, which is a gap in what the canary certifies: its five
triples are all explorer views, so it measures nothing about the debugger
register or about bundle freshness.

### 6.3 The finding that matters: `.tablewrap` had no border to be held by

T-2's stated rationale is that these containers are *"held by their hairline and
header tone"*. **That was false for `.tablewrap`, and the review found it in the
pixels before it was explained in the CSS.** Five reviewers, working from
different view families and unaware of each other, independently named the table
container's missing edge as the weakest element on the page.

The cause is not elevation at all. `.tablewrap` carries a right-edge scroll mask
with `mask-clip: padding-box`. A mask clips everything the element paints outside
its clip box, and a border is outside the *padding* box — so the hairline this
rule has always declared had **never been painted**, on any route, in either
theme, before or during this pass. Reproduced in an isolated page:

| `mask-clip` | left edge, sampled mid-height |
| --- | --- |
| no mask at all | shadow ramp, then hairline, then surface |
| `padding-box` (what shipped) | canvas straight to surface — **no hairline, no shadow** |
| `border-box` | canvas, **hairline**, surface — shadow still clipped |

Two consequences, and the second is a correction to §2:

1. It is a **pre-existing** defect. The pre-tint build has no table hairline
   either. T-2 did not cause it; T-2's argument merely assumed its way out of it.
2. **T-2's removal of `.tablewrap`'s `box-shadow` changed no pixel.** The same
   clip was already discarding it. The 1.24:1 measurement §4 offers for that
   container is a measurement of a declaration with no rendered effect. The
   removal still stands — a shadow is wrong for a pane — but it was not the
   change the numbers described.

**Fixed here**, as one declaration: `mask-clip: border-box`. It restores the
hairline on the left, top and bottom; it does **not** restore a shadow, which
paints outside the border box and stays clipped; the right-edge fade is
untouched, which matters because that fade is the one overflow in this product
deliberately made visible. Measured: 94 of 308 images move, across exactly the 14
views that render a table, **zero change in image geometry**, and it costs the
same in both themes (144,214 light against 144,013 dark changed pixels) because a
border is not a shadow. Three confirmation reviewers over 126 crops returned *fix
is good*, unanimously, with the fade's ramp identical to within 1/255.

### 6.4 What the review upheld

The rest of the pass survives, and now with rendered evidence rather than five
pairs:

* **The radius ladder (T-1) is right.** Every rung moved together and the
  container-to-chip ratio is preserved exactly (12:6 became 8:4). Reviewers
  measured the arcs rather than taking the claim: no rung was orphaned and no
  component reads as foreign to its neighbours. On the *debugger* pages the
  shared `.btn` moved **onto** the rung the debugger's own step-control groups
  already used — the explorer arrived where the debugger was, which is the
  direction §1 asks for.
* **`.debugcard`'s drop from `overlay` to `raised` stands.** It was contested at
  P2 on the `--absent` and `--unsupported` variants, where the card carries no
  action and nothing now marks it as the page's principal object. Referred to an
  adversarial reviewer, which **downgraded it to P3**: on those two variants
  there *is* no action and none is coming, so the card is an explanatory panel
  and belongs at panel elevation. Restoring a modal shadow there would make the
  most elevated object on the page the one that says there is nothing to do.
  The reviewer's better-framed version of the concern is recorded below.
* **T-2 costs dark nothing at all.** Both elevation rungs composite to the canvas
  colour over a dark page — 1.000:1 — so the removed shadows were rendering zero
  pixels there. Every dark-theme reviewer confirmed it independently by scanning
  the perimeter outside each container: no shadow band exists in either half.

### 6.5 The light-theme asymmetry, measured across the whole corpus

§2 states, against its own case, that *"in light the shadow's stacked peak was
marginally stronger than the fill step, so light does give up a real if faint
third channel; dark gives up nothing at all."* **That is correct, and the full
corpus quantifies how lopsided it is.** Over 154 view/size pairs the tint moves

| | changed pixels |
| --- | --- |
| light | 2,448,345 |
| dark | 185,221 |
| ratio | **13.2×** |

with the two themes differing in *kind* and not only in degree: light's change is
broad and soft (mean delta ≈7/255 over a large area — a removed shading), dark's
is narrow and sharp (mean delta ≈34/255 — corner geometry only). In dark the tint
is, to a good approximation, a pure radius change.

**A note on the instrument, because it under-read the change it was used to
justify.** §4 argues T-2 from *peak contrast ratios*, which is the wrong measure
for a shadow: a shadow's signal is spatial extent times gradient, not its darkest
pixel. Peak contrast said the `.debugcard` demotion was worth 0.09 of a ratio
point; the pixels say it moved 49,153 of them on one card, because the blur
radius collapsed roughly threefold. Both numbers are true and only the second
describes what a reader sees. Where a future pass argues about elevation, it
should integrate over the affected area as well as quote a peak.

### 6.6 Left open, deliberately

Recorded rather than fixed, because each needs a decision this pass does not own:

* **The state pill is the weakest element on the transaction page.** "Not
  observable" / "No recorder" is small, low-contrast, and on the `--absent` and
  `--unsupported` variants it is the *only* mark identifying an otherwise
  unlabelled box — the page's whole trace verdict rests on its faintest
  component. If it is addressed, the differentiator must be a heading or a tonal
  fill, not elevation; the `.debugcard` is the one card on that page with no
  section heading.
* **`--bt-border-subtle` and `--bt-surface-sunken` are the same value in dark**,
  so the row divider under a `.dl` label cell is invisible against the cell's own
  background. A colour question, out of scope here by instruction.
* **The dark table header band** sits 13/255 above the row surface, so the
  "header tone" half of T-2's rationale is much weaker in dark than the hairline
  now beside it.
* **The debugger's inert phase chips kept their stadium radius** while every
  actionable control near them stepped down, so the thing you cannot click is now
  the rounder one. Two pixels on a 28px control; it does not mislead, but it is
  the one place the toolbar stops reading as one ladder.
* **The ladder has no headroom left.** Three rungs now live inside 4px, and a 4px
  chip inside a 6px panel is near the floor at which nesting reads as hierarchy
  rather than as two flat rectangles. A further step down is not available.
