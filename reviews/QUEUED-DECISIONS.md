# Queued taste calls and product gaps

Decisions this campaign has deliberately NOT taken, each with the evidence that
sharpened it, the options, and a recommendation. The campaign rule is that a
finding needing a taste call is a queue and not a stop: it is recorded here with
options and a recommendation, and the loop continues.

Nothing in this file has been implemented. Where a round CHANGED what is being
queued — as vd9-r1 did to Q2, whose original premise turned out to be wrong —
the correction is recorded rather than the entry being quietly rewritten.

Current as of round vd9-r1 (ledger 2026-08-31.7), with additions from the five
completed reviews of the incomplete vd9-r2 (see `rounds/vd9-r2/README.md`).

## Q1. The `⊙` / `⊘` branch-arm glyphs are too quiet
Options: (a) raise contrast only; (b) make the pair differ in SILHOUETTE not
interior stroke, so the distinction survives at 7px and in greyscale;
(c) drop the glyphs and rely on dimming alone (loses the affirmative signal
that was added deliberately, because inferring "ran" from silence was the
original defect).

vd9-r1 evidence: L5/debugger/wide/light filed the pair at P3 with a new angle —
the pane now runs a THREE-glyph vocabulary (`⊙`, `⊘`, `·`) with no key anywhere
on the page and no hover text visible in a still. L5/debugger/wide/dark reports
the marks landed on only one of two unrun arms. L3 could not re-measure on
`debugger--testnet` because that trace is source-less and renders no glyphs.

**L3 on `debugger/wide/light` measured it decisively and the answer is not the
one the old figure implied:**
  - `⊘` measures 9.15:1 (#484848 on white); `⊙` measures 4.29:1 (#0E7490 on the
    #A5F3FC current-line band) — UP from the 2.40:1 recorded last round, but
    with zero pixels actually reaching 4.5:1.
  - The two ARE distinguishable without colour: a wall-to-wall interior diagonal
    versus an isolated 2x3 central pip, on pixel-identical 8x9 rings. But with
    zero margin — the pip survives on a single background pixel column each side.
  - **The sharper problem is a third mark.** `⊙` shares its cyan with the twenty
    neutral `·` coverage marks, so hue separates `⊙` from `⊘` but NOT from the
    mark that means nothing. And the "cannot tell" case renders as a cyan middot
    rather than as blank, so the vocabulary is three marks, not two.

**L3 on `debugger/wide/dark` then settled it against the register's DEFAULT
theme, and the answer there is the opposite of the light-theme one:**
  - `⊘` 5.47:1 (#919191 on #1b1b1b); `⊙` 4.26:1 (#06b6d4 on the #334155
    current-line band) — so change 4's contrast work did land, 2.40:1 -> 4.26:1.
  - **With hue and background normalised away, the two 9x9 glyphs share
    IoU 0.79** — 23 of 29 lit pixels identical, only 6 differing, and 5 of those
    are `⊘`'s slash tails. 22% achromatic dissimilarity. **They are NOT
    distinguishable without colour.**
  - Cyan now carries SIX meanings in dark: current-line rail, call-trace
    selection rail, active-iteration underline, gutter step dot, the new `⊙`,
    and the type-name syntax token — one more than the round that first filed
    the token-overload defect.

**L3 on `debugger/laptop/light` is the third independent measurement and it
agrees, then sharpens the contrast half:**
  - Aligned ink maps differ by only 7.6px of ~33px mean ink = 23%, confined to a
    4x4px interior. They separate only above 4x magnification, and the two
    glyphs never share a surface, so a reader cannot even compare them directly.
  - **`⊙`'s RING FLANKS still measure 2.40:1 and 2.23:1 on the current-line
    band.** The 2.40:1 recorded last round is UNCHANGED; only the glyph's caps
    improved to 4.29:1. So the contrast work that appeared to land is partial —
    it lifted the part that was already easiest to see.

**This is no longer a taste call; it is a determined defect.** Two lenses
measured the pair on two themes and the register's default theme fails the
without-colour test outright (IoU 0.79), while the light theme passes only with
"zero margin". The `⊙`/`⊘` pair is held to the same three-fact bar as the
dimming, and a pair separated by 6 pixels and a hue does not meet it.

What remains a taste call is only WHICH replacement to draw. Recommendation:
(b) — differ in silhouette, not interior stroke — with a contrast floor and a
legend, and in this priority order:
  1. the `⊙` / `·` collision (cyan means "ran" and also means "nothing to say"),
     because that is the exact failure the affirmative mark was introduced to
     prevent;
  2. the `⊙` / `⊘` silhouette, now measured at IoU 0.79 in the default theme;
  3. cyan's six meanings, which is the wider token-overload finding this is one
     instance of;
  4. the legend — three marks with no key is a vocabulary a reader must guess.

## Q2. Call Trace region empty while the Transaction pane overflows
**Lever located and it is one line.** `client/src/debugger/session_layout.nim`
composes the middle column `tabs(Call Trace, Event Log, weight = 3.0)` above
`pane(Values, weight = 2.0)` — a 3:2 split. This is BlockTracer's OWN
composition file, NOT the vendored `layout_model.nim`, so changing it does not
touch the vendor hash manifest or the desktop app's default layout.

vd9-r1 measurements, which sharpen the old 47-57% figure considerably:
  - `debugger/wide/light` L2: tabbed region 348px empty = 57.9% of the card,
    64% of the interior below the FRAME header; middle column 46.7% blank.
    **AND: Values does NOT overflow — it has 122px (30.4%) of its own slack.
    Only the Transaction pane overflows, clipped mid-JSON at y=1075.**
  - `debugger--testnet` L4: 91% empty (source-less trace, so content-shaped).
  - `debugger--testnet` L2: three sibling panes 76-85% empty, Transaction clips.

**This materially changes the fix.** The old framing — "give Values the space
Call Trace is wasting" — is wrong, because Values does not want it either. The
column that is starved is the THIRD one, Transaction, which is a sibling of the
whole middle column, not of the tabs. So re-weighting 3:2 → 2:3 would move space
between two panes that both have slack and leave the starved pane untouched.

Revised options:
  (a) Re-weight the COLUMN split (`weight = 3.0` Code / `2.0` middle / and the
      Transaction rail), giving the Transaction pane more width or height.
  (b) Let the Transaction pane scroll within itself rather than clip, so
      `effectsMatched`/`effectsMismatched` are reachable.
  (c) Leave it: the fixture's trace is shallow and tuning to one transaction's
      call depth fits the layout to the corpus.

More vd9-r1 measurements, all agreeing:
  - `debugger/wide/light` L4: tabbed region 340px empty = 56% of the region,
    59% below the tab strip (13.6 unused rows); Values also 30% empty (122px of
    407px). **"~120-130px can move from the 606px middle column — which has a
    152px dead band in its widest frame row — to the overflowing 381px
    Transaction pane at ZERO cost to the call trace."**
  - `debugger/wide/dark` L4: 57.0% empty (346px of 607px), Values 29.8% empty,
    column carries 467px / 45.9% of slack; "the lever is the 912/607/382px
    column split, not the row split".
  - `debugger/laptop/light` L4: 48.8% empty — so the original 47-57% band holds
    at laptop and the 91% figure does not reproduce (that one was the
    source-less testnet trace, i.e. content-shaped, not layout-shaped).

**I DID (b) THIS ROUND** — see the fix list. The panes were never clipping:
`.panebody` is `overflow:auto` and scrolls. What was missing was any signal that
it does, because the fade treatment `debugger_css.nim` documents as "ONE
overflow treatment" existed only on the HORIZONTAL axis (`.src`, `pre.raw`).
Five reviewers across three triples read a silent scroll region as a hard clip.
`.panebody` now carries the same mask turned ninety degrees.

(a), the re-weighting, **stays queued** — the brief said keep it queued and I am
not overriding that, but the loop has changed what is being queued, so the
record should say so:

  * The original premise was wrong. It was "Call Trace is empty while Values and
    Transaction overflow". Values does NOT overflow — it has 30% slack of its
    own in every measurement. Re-weighting the ROW split 3:2 -> 2:3 would
    therefore have moved space between two panes that both have slack and left
    the starved one untouched. The queued fix as previously framed would not
    have worked.
  * The lever is the top-level COLUMN split, which is `weight = 3.0` (Code),
    `2.0` (middle), `1.0` (Transaction) — a sixth of the width for the pane
    holding the tallest content on the page.
  * Concrete proposal, from L4's numbers: Code 3.0 / middle 1.6 / Transaction
    1.65 gives roughly 922 / 492 / 507px at 1920, moving ~125px into Transaction
    while leaving Code where it is and staying inside the middle column's
    measured dead band.

This is now a well-evidenced one-line change rather than an open question, but
it is still a visible design decision that no reviewer has yet seen the result
of, which is exactly what a taste call is.

## Q3. `Status reason: private-part-succeeded-public-part-succeeded`
Still present; re-filed in vd9-r1 by L5 on `debugger/wide/light` (P2) and L5 on
`debugger/wide/dark`, which notes it has now become the FIRST prose in the pane
carrying the honesty claim.

Options: (a) map known reason tokens to sentences, unknown falling through
verbatim (the `roleLabel`/`costLabel` contract); (b) leave verbatim but give it
the machine-value treatment so a reader sees a code, not a malformed sentence;
(c) leave as is.

Recommendation: (a) is now the better answer and vd9-r1 is why. I applied
exactly that contract to `costLabel` this round against real data, and the
fall-through arm is what makes it safe: a chain whose reason is genuine prose is
never rewritten, because only known tokens map. The risk I previously assigned
to (a) — "BlockTracer paraphrasing a chain's status vocabulary" — is bounded by
the same mechanism that makes `roleLabel` acceptable, and that precedent is
already load-bearing in this module. Still queued because it is a copy decision
with a voice question attached, not because the mechanism is unclear.

## Q4. PRODUCT GAP, not a taste call — the 'supply an ABI' action
`tx-detail/wide/light` L5 filed it P1; it is the round's ONLY G1 failure.

There is no ABI-supply mechanism anywhere in the product: no route accepts one,
`/settings` has no field, nothing stores one. A control here could not succeed,
and this page's own MUST-NOT-SHOW forbids precisely that ("a disabled control
standing in for an absent one"; a button that "could only lead somewhere that
says no"). `panedismiss` and the inert `.ctsort` span were both deleted from
this codebase for it.

What I did this round: applied Rule 2 to the ACTION as it already applies to the
data — the note stops promising a remedy the reader cannot take and states that
BlockTracer cannot yet be given an ABI. **I did NOT weaken the expectation**:
it faithfully reflects Page-Descriptions §7.2, and the spec is not wrong — the
capability is simply unbuilt. So the triple should keep failing G1 until the
feature exists. That is the honest state and it needs a product decision, not a
visual one.

## Q5. Two competing right edges, 212px apart
`.stub` carries `max-width: var(--bt-layout-prose)` while the facts grid spans
the content column: notice cards end x≈1203, grid ends x≈1415. Filed by L2 on
`tx-detail/wide/light` and L2 on `tx-detail--mainnet-zero-trace/wide/light`,
independently measuring the same 212px.

Options: (a) drop the prose measure so edges align — REJECT, it would make the
prose less readable and the measure is deliberate typography; (b) let the card's
BORDER span the full column while an inner element keeps the text measure, so
alignment and readability both hold; (c) accept two edges and make the
difference read as intentional (e.g. indent the cards so they are visibly a
different class of object rather than a near-miss).

Recommendation: (b) or (c), not (a). This is a genuine taste call between
compositional alignment and typographic measure; what makes it a finding rather
than a preference is that 212px is close enough to read as a mistake.

## Q6. The phase rail says FETCHING on a positioned session
ADV/`debugger/laptop/light` filed P1: the rail highlights `FETCHING` while the
session is fully positioned (`128 / 1315`), and renders identically to the
dedicated `debugger--loading-phases` view.

**Do not "fix" this by claiming the engine is loaded.** The state is honest and
documented: `SessionView.hasFrame` is "True on the static route for a published
trace, where `phase` is still `spFetching`" — the panes carry a pre-rendered
positioned frame while the engine really is still being fetched. Both facts are
true simultaneously. `debugger_css.nim:1069` records that this exact
contradiction was raised as a P1 in an earlier round and adjudicated: "The
status was TRUE; the controls were the lie" — and the controls were then made
visibly inert.

So the remaining issue is legibility of the relationship, not correctness.
Options: (a) leave it — the state is true and already adjudicated; (b) say what
IS available while fetching, e.g. "Positioned from the published trace;
stepping needs the engine", so two true facts stop reading as a contradiction.

Recommendation: (b), as copy only. It changes how the state is said, not what
is claimed. Note that ADV/`debugger/wide/light` independently re-filed the
sibling half at P2 — judging the inert control treatment still too subtle at
7.35:1 — so a reader is plainly still assembling the wrong picture from these
elements even though every individual claim is true.

## Q7. The new zero-trace provenance sentence is right and not yet well made
Raised by the two completed vd9-r2 reviews of
`tx-detail--mainnet-zero-trace/wide/light` (ADV and L5, independently).

`b7cafba` replaced a sentence that had become false — it blamed the chain for a
fault on the recording side — with one that names the refusal. That was the right
correction and it is not in question here. What the round found is that the new
sentence is not finished:

  1. it ends in the bare enum `AvmToolchainRegression`, twice, unglossed, set in
     the body face;
  2. it ships pluralisation placeholders — `2 transaction(s)`, `27
     transaction(s)` — and a shouted `WERE`;
  3. **its own numbers do not cover its own subject.** The window is stated as
     67651-67686 and pruning as "below block 67650"; this transaction is at
     67650, so it falls in neither set. Both reviewers found this independently;
  4. the `Not observable` card claims permanence while citing only a fixable
     engine regression and never mentions that the body has since been pruned,
     so the card and the paragraph hand a reader two different reasons with no
     way to reconcile them.

(1) and (2) are presentation and have obvious fixes — gloss the enum or set it as
a machine value, and pluralise properly. (3) and (4) are NOT presentation: they
are honesty defects on the one element whose whole job is to be believed, and
they were introduced by the commit that fixed a different honesty defect on the
same element. They need someone who knows what the follower actually observed to
say which reason is true for THIS transaction, which is why they are queued
rather than guessed at.

Recommendation: fix (1) and (2) as rendering. Do not touch (3) or (4) without
re-deriving from the capture record — a third wrong sentence in the same place
would be worse than either of the first two.

## Q8. DIAGNOSED, not queued for want of understanding — the window arithmetic
`tx-detail--mainnet-zero-trace/wide/light` L4 filed this at P1 in the incomplete
vd9-r2, and traced it to a line rather than leaving it as an observation.

The provenance sentence scopes both refusals to "blocks 67651-67686", but the
subject transaction is at `67650:0` — printed in the BLOCK row and again in the
Raw block — so by the page's own arithmetic it is neither inside the replay
window nor "below block 67650", while the reason card above asserts the runtime
refused *it*.

Cause, per L4: `src/blocktracer/chain/ingest.nim:559` binds `"inside it"` to the
LAST window (`replFrom`-`tipAt`) while `refusedCount` aggregates across ALL
capture sessions. `client/fixtures/chain/aztec/snapshot.json` `captures[]` shows
this hash refused in the EARLIER 67619-67650 window.

So the sentence is not wrong about the world — the refusal really happened — it
is wrong about WHICH window it happened in, because one number is per-session and
the other is cumulative and they are printed as though they were the same scope.

This is queued rather than fixed only because it is not mine to guess: the
correct sentence depends on whether the intent is to report the last window or
every session, and that is a decision about what the page claims. Both readings
are defensible and they produce different sentences. What is NOT defensible is
the current pair, which cannot both be true.

Recommendation: scope the count to the window it is printed beside, or print the
window each refusal belongs to. Do not adjust the window bounds to include the
subject — that would make the arithmetic agree by moving the fact.

## Q9. A REGRESSION I INTRODUCED — the humanised cost label wraps to three lines
`tx-detail--mainnet-zero-trace/wide/light` L4, incomplete vd9-r2.

`costLabel` fixed the words and cost layout. `COST · TRANSACTIONFEE` was a
fourteen-letter unbreakable run that overflowed a 163px label column and wrapped
after the separator, making that row 1.6x the grid's row height. `Cost ·
Transaction fee` is correct English and *breaks in more places*, so it now wraps
to THREE lines and the row is 2.3x the grid's row height — measurably worse than
what it replaced, on the axis the original finding was about.

The words are right and should stay; the row height is now the defect. Options:
  (a) keep "Transaction fee" from breaking internally, so the row wraps to two
      lines ("Cost ·" / "Transaction fee") rather than three — strictly better
      than both the before and after states, and the smallest change;
  (b) widen the label column, which affects every row in the grid;
  (c) drop the `Cost · ` prefix where the grid has only one cost dimension.

Recommendation: (a). It is not applied here because no reviewer has seen it, and
shipping an unreviewed layout change to close an unreviewed layout regression is
how this campaign generates work rather than finishing it. It should be the first
thing the next round captures.
