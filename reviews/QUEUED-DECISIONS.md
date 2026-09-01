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

## Q10. The page claims permanence with a repairable cause printed beneath it
`tx-detail--mainnet-zero-trace/wide/light` L3, vd9-r2, filed at P1 alongside the
expectation contradiction. This half is a PAGE defect and it survives that
reconciliation entirely.

The page asserts "No trace can be produced for this execution — a permanent
answer rather than a failed fetch", and that Internal calls and State changes are
empty "permanently, not yet". The cause it prints directly beneath is a toolchain
regression in our own replay runtime, which is by construction repairable. As L3
put it: deleting the recorder-blaming clause without changing the permanence
claims would leave an unsupported assertion with no stated basis at all.

§14.1a cuts both ways — "'Not now' and 'not ever' are different states … presenting
either as the other is the failure this table exists to prevent." The page is
currently presenting "not now" as "not ever". A reader told the answer is
permanent may never return to a page that will have a trace on it.

The expectation was corrected in the same session to demand a tense that MATCHES
the published cause, so this is now a live G1 failure rather than a silent one.
That is the right way round and it should stay failing until the page is fixed.

Where the fix goes: `viewutil.availabilityNote(taAbsent)` returns one sentence
for every absent execution, and its own docstring explains why it may not name a
cause — `absent` has more than one and the line cannot tell them apart. That
reasoning is still correct for the CAUSE. It does not extend to DURABILITY, which
the enum also cannot tell apart and which the sentence asserts anyway.

Options:
  (a) `availabilityNote` stops asserting durability at all, leaving both the
      cause and the permanence to the per-execution published reason beneath it —
      consistent with the docstring's own argument, and the smallest change;
  (b) thread the pruned-vs-refused distinction into the ViewModel so the sentence
      can be correct in both cases — more informative, more surface;
  (c) leave it, and accept that one of the two states is described wrongly.

Recommendation: (a). The module already decided that a claim specific enough to
be wrong belongs with the published reason rather than in the enum's sentence; it
simply did not apply that to the word "permanent". (c) is not available — it is
the §14.1a breach, on the page whose entire job is to be believed.

## Q11. The pane bottom fade works and costs contrast, and both are measured
Three lenses reviewed the fade added this session on `debugger/wide/light`, and
they do not agree, which is the finding.

FOR it:
  - L2: it reads as "there is more below" rather than as a cut — "the whole row
    including the line-number gutter dissolves, and the RAW block's own
    background fades with it so nothing ends on a hard edge". It also confirmed
    the fade resolved the mid-glyph cut five reviewers had filed as a clip.
  - L4: "fixes the mid-glyph cut", but at a ~24px ramp against a 23px line pitch
    it "reads as 'the last line is dim' rather than 'there is more'".
  - Both measured the vertical ramp at ~26px against the HORIZONTAL fade's ~48px
    in the same pane, and both wanted it longer.

AGAINST lengthening it:
  - L3 measured what it costs: at ~29px the band already exceeds the 23px line
    pitch and drives the last fully-inside-the-box line to **2.19-2.22:1** and a
    coverage dot to **2.43:1** — under the floor, on text that has not left the
    box.
  - L1 reports that in the Transaction pane the fade "renders behind its text".
  - L3 also found a second problem no ramp length fixes: masking the pane BODY
    fades the RAW block's own `#ECECEB` surface to `#FBFBFB` and erases its
    bottom boundary. The mask is applied to the scroll container, so it takes the
    surface with the ink.

The ramp was moved to `2xl` on L2/L4's evidence and reverted within the hour on
L3's, because a ratio against a floor outranks a legibility reading. It is back
at `lg` — the state all three actually reviewed.

**Both camps are right, and that is the useful result:** at a 23px line pitch
there is no ramp length that both reads as continuation and keeps the last line
legible. So the next move is a different treatment, not a different number.

Options:
  (a) fade the INK only, not the scroll container — put the mask on an inner
      wrapper so the pane's surfaces and borders stay solid. Fixes L3's second
      finding and L1's "behind its text", and lets the ramp lengthen without
      washing surfaces;
  (b) drop the mask and mark overflow with an edge rule or a persistent
      scrollbar — no contrast cost at all, less elegant, and it reintroduces the
      hard edge L2 credits the fade with removing;
  (c) keep the fade but apply it only when the pane actually overflows, which
      needs script and this route ships none;
  (d) leave it at `lg` and accept one dim last line.

Recommendation: (a). It is the only option that answers all four measurements,
and it keeps the "one overflow treatment, and it is the fade" rule the stylesheet
already commits to. Not done here because it is a structural change to every
pane, reviewed by nobody, at the end of a session — exactly the shape of change
this campaign keeps having to undo.

## Q2 — SECOND CORRECTION, from vd9-r2. The middle column cannot fund it either
The entry above records that the ORIGINAL premise was wrong: Values does not
overflow, it has slack, so re-weighting the ROW split would have moved space
between two panes that both had some. vd9-r2 corrects the correction.

`debugger/laptop/dark` L4 measured the Call Trace region 229px empty of a 463px
body — **49.5%**, so the standing observation holds at every viewport and theme
now measured (56.3% wide/dark, 58% wide/dark ADV, ~48-49% at both laptops). But:

  **Values carries only ~8% slack at laptop, not the ~30% it has at wide.**

So there is no viewport-independent slack inside the middle column at all. At
wide you could fund a re-weighting from Values; at laptop you could not. Any fix
that reallocates within column two is therefore correct at one viewport and wrong
at the other, which rules out the whole family of row-split answers rather than
just the one this entry started with.

L4 also names what the fade changed and did not: "the fade makes the
misallocation visible rather than fixing it" — and adds that the overflowing pane,
Transaction in column three, is ALSO the loosest-set on the page at 30.5px rows.
That matters for the remedy: the pane that is short of space is spending what it
has at a lower density than its neighbours, so a pure width increase would be
funding looseness rather than content.

Revised recommendation: the lever is the top-level COLUMN split (`weight = 3.0`
Code / `2.0` middle / `1.0` Transaction) AND the Transaction pane's own row
density, together. Neither alone is sufficient and the row split is now
positively ruled out. Still queued — it is a visible design decision no reviewer
has seen the result of — but the option space is much narrower than when this
entry was opened.

## Q6 — ESCALATED at laptop: the honest state loses the words that made it honest
`debugger/laptop/light` ADV, vd9-r2, filed P2 and named the mechanism.

At 1920 the phase rail is accompanied by `Engine loading — 18 MB`, which is the
phrase that tells a reader what the rail is about and why a positioned session
can still be fetching. **At 1440 that phrase is dropped**, leaving three
unlabelled chips whose terminal phase reads `POSITIONING` beside panes that are
visibly already positioned.

So the reconciliation recorded above — that the state is honest and only its
legibility is at issue — is viewport-dependent, and at the smaller viewport the
element that carried the honesty is the one responsive design discards first. A
reader at 1440 is not given the two true facts and left to assemble them; they
are given one of them and a contradiction.

That strengthens option (b): say what IS available while fetching, in words that
survive the breakpoint. It also adds a constraint the wide-viewport analysis
could not see — whatever carries the explanation must not be the first thing
dropped, which is an argument against putting it in the identity bar at all.

### Q2 — the conclusion the two laptop lenses reached independently
`debugger/laptop/light` L4 re-measured the region at **48.7% empty**, against
48.8% last round — reproducing to within one pixel, which is what makes this
layout-shaped rather than an artefact of one capture. And it found the same thing
`debugger/laptop/dark` L4 did, from the other side:

  * laptop/light: "the Values pane below is 89.4% full with a terminating list,
    so **neither pane in that column wants the height — the productive move is
    horizontal, not a re-weighting**."
  * laptop/dark: Values carries only ~8% slack, "so the slack cannot be
    re-weighted within the middle column at all."

Two lenses, two themes, one conclusion, reached without either being told the
other's number. Combined with the wide-viewport measurements this settles the
SHAPE of the answer even though the answer itself stays queued: the middle
column's emptiness is real and reproducible at every viewport, and it cannot be
spent on Values, so any fix is a change to the COLUMN widths — plus the
Transaction pane's own row density, which laptop/dark L4 measured as the loosest
on the page at 30.5px while being the pane that overflows.

The row-split option that opened this entry is now positively excluded by
measurement rather than merely doubted.

## Q12. "maxium" — a typo in source we display but did not write
`debugger/laptop/dark` L5, vd9-r2, filed P3.

`client/fixtures/demo-session/src/shield.nr:41` reads "shields regain a
percentage of the maxium capacity after each hit". It is real and it is on screen
in the flagship demo.

It is NOT fixed, and the reason is worth stating because the fix looks free. That
file is a Noir program the debugger is DEBUGGING — a third party's puzzle source,
rendered verbatim as the subject of a replay session, with recorded values and
executed-line sets keyed to it. Correcting an author's comment because it appears
in our screenshots is editing the specimen. The same instinct applied to a real
chain's published `reason` is the thing this campaign has twice refused.

Options:
  (a) leave it — the source is the subject and is shown as it is;
  (b) fix it, accepting that our copy diverges from upstream in a comment;
  (c) swap the fixture for one without the typo.

Recommendation: (a). A debugger that silently improves the code it is showing you
is worse than one that shows a typo. If the demo's source is ever authored rather
than borrowed, this stops being a question.

### Q11 — the mechanism, isolated
`debugger/laptop/dark` L2, vd9-r2, found why the fade costs contrast, and it is
not the ramp length after all:

  "the bottom fade reads as continuation in the Code pane but is **anchored to
  the pane border rather than the content box**, so in the Transaction pane it
  swallows the last complete prose line (4.07:1 -> 2.10:1 across one 11px line
  box) while **9px of padding below it stays untouched**."

That is the whole defect in one sentence. The mask is on `.panebody`, whose box
includes its padding, so the ramp begins at the PANE BORDER and spends its first
9px fading empty padding — then hits live text with most of its opacity already
gone. The ramp is not too long; it is in the wrong place, and lengthening it
(which I briefly did and reverted) would have pushed the fully-transparent end
further INTO the text rather than moving the ramp off the padding.

This confirms option (a) — mask an inner wrapper rather than the scroll container
— and upgrades it from "the option that answers all four measurements" to the one
the measurements point at directly. It also explains why the Code pane reads
correctly and the Transaction pane does not: `.src` carries its own mask on the
content element, so the Code pane was already doing (a) by accident.

Unchanged conclusion, much better grounded: fix the anchor, not the length.

### Q11 — I called this "fully specified" and was wrong within the hour
An earlier version of this section, written on `debugger/laptop/light` L2's
measurement alone, concluded that the fix was settled: anchor to the content box,
lengthen to ~46-50px, align to a line boundary. Two reports that landed minutes
later contradict the middle item, and the overconfident version is replaced
rather than quietly amended, because the reason it was wrong is instructive — I
generalised from the first lens to report a number.

**AGREED across every lens: the anchor is wrong.**
  * laptop/dark L2: the mask is "anchored to the pane border rather than the
    content box", spending its first 9px on padding.
  * laptop/light L3: text sitting "nine pixels clear of the pane border at y895"
    still ramps 4.54:1 -> 2.05:1, with a further line masked to 1.10:1.
Both describe the same fault from opposite ends.

**AGREED: nested surfaces are masked, and pane borders are NOT.**
  * wide/dark L2 confirms the RAW block's `#000` is lifted to `#1a1a1a` against a
    `#1b1b1b` pane, so its edges "stop being detectable from y≈1066".
  * laptop/light L3 REFUTES the stronger claim: all four pane bottom borders
    measure `#A2A2A2` at full strength, identical to their top borders.
These are consistent, not contradictory, and together they confirm the CSS
comment's own reasoning: the pane's surface and border belong to `.pane`, so they
survive; anything nested INSIDE `.panebody` does not. The RAW block is content;
the border is chrome.

**CONTESTED, and it is the length.**
  * laptop/light L2 wants ~46-50px: at ~1.2 line-pitches the ramp "dissolves
    inside a single line" and "reads as a smudge, not as recession".
  * wide/dark L2 says explicitly DO NOT lengthen it, and gives the better
    argument: the disputed 2.19:1 "is that line's y=1066 tail; the same line
    measures 9.2:1 at cap height, so it is the affordance working, not a
    legibility failure", and lengthening "would dim a second line in a register
    where density is the virtue".

That second reading also reframes L3's numbers: a ratio sampled across a glyph's
x-height or its descender tail is not the ratio a reader experiences if the cap
height is clean. Whether the low figures are a defect or the treatment doing its
job is the actual open question, and no measurement so far settles it because
none of them agree on where to sample.

Revised recommendation: fix the ANCHOR, which every lens agrees on and which is
the one change that cannot make anything worse, then RE-REVIEW before touching
the length. Anchoring alone moves the ramp off 9px of padding and onto the ink
boundary, which may resolve the length question without a decision — and if it
does not, the next round will be arguing about a treatment that is at least
positioned correctly.

## Q13. The horizontal fade does not reach, and two lenses found it independently
`debugger/wide/dark` L2 filed it as the round's most pointed new finding: the
Code pane "hard-clips line 40 mid-identifier at its right border x=916 with no
fade, ellipsis or gutter — the exact complaint the vertical fade answered,
unaddressed on the horizontal axis." `debugger/laptop/light` L5 reported the same
shape earlier in the round: "the Code pane's real overflow at 1440 is horizontal
and clipped mid-token."

This is awkward, because `.src` DOES carry a `to right` mask and has since before
this campaign — laptop/light L3 even measures the Code pane fading "only the
genuinely clipped line 52", so the treatment is present and works on some lines.
Something is defeating it on others.

Worth noting the irony precisely: the vertical fade was added this session
BECAUSE five reviewers read a silent scroll region as a hard clip, and the
horizontal axis — the one that already had the treatment — is now the one
producing that exact complaint.

Not diagnosed, and deliberately not guessed at. It needs someone to establish
whether the mask is being defeated (a nested element painting over it, a line
that overflows its container rather than the scroller), or whether these lines
are clipped by `.pane`'s `overflow:hidden` before `.src` ever sees them — which
would be a different bug in a different place. Both are cheap to check against
the built page and neither should be fixed before it is known which.

### Q2 — the row split is now PROVABLY not the lever
`debugger/wide/dark` L2 supplied the figure that ends the argument rather than
narrowing it: **total content in the middle column is 542px of 1010**, so no
redistribution between the tabbed region and Values can recover any of the 468px
void. There is not enough content in that column to fill it at any ratio.

It also measured where the space actually is: the widest Call Trace row wastes
152px HORIZONTALLY and Values 158px, while Code has 14px of slack and Transaction
wraps hashes. So the middle column is too WIDE, not badly divided — which is the
same conclusion both laptop lenses reached from Values being nearly full, arrived
at independently by a third route.

Re-measurement also holds to within a pixel across rounds: columns 913/608/383
against 912/607/382, tabbed region 57.2% empty against 57.0%.

### Q1 — the `⊙` / `·` collision, stated exactly
`debugger/laptop/light` L3 found the sharpest form of it: the neutral coverage
dot `·` is `#1A7B95`, three levels from `⊙`'s ink, and **it IS `⊙`'s own centre**
— 2.9 against 3.27 alpha-px, 11% apart. So the only thing distinguishing "this
branch arm ran" from "nothing to say about this line" is `⊙`'s ring, which
measures 1.60-2.71:1 on its flanks (mean 2.16, area-weighted 1.39:1).

The affirmative mark is the neutral mark plus a sub-3:1 ring. That is the failure
the affirmative mark was introduced to prevent, stated as a measurement rather
than an impression, and it is why the `⊙`/`·` collision is ranked above the
`⊙`/`⊘` one in this entry's recommendation.

Same lens re-measured the pair itself at IoU 0.781 and a 14.7% ink difference at
laptop, against 0.79 and 23% at wide — so the two glyphs are, if anything,
slightly harder to tell apart at the smaller viewport.

### Q1 — three L3 lenses, and they do NOT agree about the `⊙` / `·` collision
Reported as a disagreement rather than resolved, because the earlier Q11 entry in
this file was written as settled on one lens's evidence and contradicted within
the hour. The same mistake is available here and is being declined.

  * `debugger/laptop/light` L3: `·` is `#1A7B95`, three levels from `⊙`'s ink,
    and **is `⊙`'s own centre** (2.9 vs 3.27 alpha-px, 11% apart) — "only the
    sub-3:1 ring separates the two".
  * `debugger/wide/dark` L3: the collision is **NOT real in dark** — "`·` is not
    neutral, it is the same cyan at 7.09:1, and 2x2 vs a 9x9 ring separates
    cleanly"; the real cost is that cyan already means "covered" in that gutter,
    "so `⊘`/`⊙` has no colour left".
  * `debugger/laptop/dark` L3: `⊙` and `·` are "the identical hex `#06B6D4`,
    separated only by form (IoU 0.118)" — i.e. the forms are very different.

What all three actually agree on: the two marks share a HUE, and their FORMS
differ (a 2x2 dot against a 9x9 ring). The disagreement is whether the ring
registers. Where `⊙` sits on the current-line band in the LIGHT theme its ring
flanks measure 1.60-2.71:1, so the ring may not be seen at all and what is left
is a dot beside a dot; in dark on the plain pane the ring reads at 7.09:1 and the
distinction is obvious. That would make the collision REAL BUT CONDITIONAL — a
function of the band the glyph lands on rather than of the glyph — and it is a
hypothesis this file records, not a finding.

**The decisive measurement is separate and is not contested.** laptop/dark L3:
`⊙` on the current-line `#334155` has "a hard 4.26:1 ceiling — median 2.29:1,
flanks 2.67:1/2.24:1 — versus 7.09:1 on the plain pane, **so improving its caps
cannot fix it**."

That reframes the whole entry. Every previous option here proposed changing the
GLYPH — retint it, redraw it, drop it. The glyph is fine where it lands on the
pane. It fails on one background, and the ceiling is imposed by that background,
so a fourth option belongs on the list and is probably the right one:

  (e) change what `⊙` lands ON — lighten or retint the current-line band under a
      mark, or give the mark its own chip, so the gutter's marks are not being
      asked to carry meaning against a tint chosen for a different purpose.

Cyan's role count also rose again and the lenses do not agree on the number —
six across three tints (wide/dark), six across five values (laptop/light), eight
across three tints (laptop/dark). They agree it is more than one thing and that
`#67E8F9` means both "current position" and "type token" inside a single pane.

## Q14 — RESOLVED IN THIS SESSION, recorded because the failure was instructive
Not a queued decision; a note about how assertion F nearly lied to me.

After the fixes I ran `cd client && just export` several times to check the built
markup. `check-coverage` then reported **72 images drifted from `/demo` to
`/aztec`** — an alarming, specific result about a corpus that was perfectly
correct. The corpus had not moved. The DIST had: capture builds the tree with
`-d:publishDemoChain` and `just export` does not, so with the synthetic chain
absent from the registry every view resolving through the primary chain
re-resolved to `aztec`, and F dutifully compared the corpus against the wrong
tree.

I would have shipped a convergence report claiming F green — I verified it green
earlier in the session — while the check as it then stood reported 72 false
drifts to whoever ran it next. F exists BECAUSE nobody could see a stale corpus;
a version of it that cries wolf whenever someone runs the project's own export
recipe teaches people to disbelieve exactly the assertion that was written to be
believed.

Fixed: the wrong tree is now detected and named BEFORE the comparison, F reports
NOT RUN rather than inventing drift, and the message carries the exact rebuild
command. Verified both ways — correct tree PASSES 308/0, wrong tree produces the
diagnosis and **zero** drift lines where it previously produced 72.

The general lesson, which is the reason this is written down: F's verdict depends
on an input it does not control and did not check. Any assertion that reads a
BUILD rather than the source of truth has this shape, and E reads the same dist.

## Q9 — REFUTED on the debugger register. The regression is not universal
`debugger--testnet/wide/light` was the last triple reviewed and it was reviewed
precisely to test this, because its subject also publishes `transactionFee`.
Three lenses measured the cost row independently and all three refute it:

  * L1: 46px between bounding rules against 30px text rows — **1.53x / 1.44x**.
    "the label sets on one line (153px wide, 53px clear of the value) and only
    the unit `mana (FeeJuice)` takes a second line, so it is a two-line row, not
    three, and it is **below the 1.6x pre-change baseline** rather than at
    2.2-2.3x."
  * L2: "one-line label + two-line value at 46px = 1.44-1.53x the 30/32px grid
    rows (not three lines, not 2.2x)".
  * L4: 46px, 1.45x, and names the real defect: "**the defect is 19 unseparated
    digits, not the wrap**."

So the humanised label is an IMPROVEMENT here — the row is shorter than before
the change — and Q9 is specific to the explorer's `tx-detail` grid, whose 163px
label column is narrow enough to break "Transaction fee" into three lines. The
debugger's metadata pane has room for it.

Revised: Q9 stands as a real regression on `tx-detail` only, and the fix must be
scoped to that grid rather than to `costLabel`, which is doing the right thing.
L4's point is the more valuable one for both surfaces: a 19-digit ungrouped
decimal is the defect the base-ten conversion left behind, and it was filed
independently by L1 on mainnet in the previous round.

## Q11 — the mask costs far more in LIGHT than in DARK, measured on one line
`debugger--testnet/wide/light` L3 produced the cleanest comparison in the
campaign: the lowest text-on-surface ratio on the page is **1.16:1**, at the
descender of `"hydrationRounds": 6,` in the masked RAW block — and **the
identical mask on the identical line in the DARK capture measures 6.17:1**.

Same rule, same content, same position; a 5x difference in what it costs. That
explains why `wide/dark` L2 could reasonably call the fade "the affordance
working" while three light-theme lenses called it a legibility failure: in dark
the text starts at 5.47:1 and the mask crosses the floor at 12.5% opacity loss,
while in light it starts near-black on white and the same alpha ramp destroys it.

This is a strong additional argument for option (a) — mask the ink via an inner
wrapper rather than the scroll container — because it also implies any
ramp-length answer would have to differ per theme, which the token layer has no
mechanism for and which would be two designs rather than one.

## Q15. A gated triple stopped being photographable, and that is not mine to fix
`tx-detail--mainnet-zero-trace/wide/light` is in `reviews/ledger.json`'s
`gateScope` with a complete, ingested, six-lens triple. It can no longer be
captured. The published set was re-scoped to the window where every transaction
opens, so no real chain now carries a trace-less transaction to photograph;
`views.mjs` marks the view `pending` with exactly that reason, and
`check-coverage` assertion F went from 308 subjects to 300 with zero drift.

G2 fails on it and must keep failing — six reviews of an image the corpus no
longer publishes are still not six reviews of the image on disk. The gate's
SENTENCE was wrong, though, and is fixed: it said "the capture reviewed is
missing (… is gone)", which describes a deleted file and implies `just capture`
as the remedy. It now names the view's status, quotes `pendingReason`, and says
the decision is a gateScope one.

Options:
  (a) restore a trace-less real transaction to the published set, so the subject
      exists again — this is the sibling agent's re-scoping work and taking it
      here would be fighting it;
  (b) retire the triple from `gateScope` in its own commit naming the six
      reviews it retires and why, accepting that the campaign loses its only
      real-chain `tx-detail` subject;
  (c) leave it failing, honestly, until the re-scoping settles.

Recommendation: (c) now, then (a) or (b) once the sibling's set is final. Not
taken here because the corpus is moving and a gateScope edit made against a
half-landed re-scope is a decision taken twice. The three P1 on that triple —
including Q10, the permanence claim with a repairable cause printed beneath it —
are NOT retired by any of these options; they are findings about copy that
`isFull` still publishes and that is graded elsewhere.

## Q16. The 19-digit fee: the one remedy the grouping rule excludes
Four reviewers on two triples filed `1755555891986239551` (and
`3070954237478732800` on the other subject) as unreadable, all on rubric B7:

  * "19 digits set as one unbroken monospace run … 1.7 quintillion and 17
    quintillion are indistinguishable at a glance, and it is the largest number
    on the page";
  * "a reader cannot tell 1.75e18 from 1.75e17 without counting glyphs … the
    value column has only ~202px of room and the number already consumes ~133px
    of it, so this row is one order of magnitude away from a hard overflow";
  * "the defect is 19 unseparated digits, not the wrap" — filed while REFUTING
    the Q9 wrap regression on the same row;
  * "two such values could not be compared by eye, which is the whole job of a
    numeric cell in a facts grid".

They are right, and the obvious fix is forbidden. `groupDigits` states the rule:
a figure the reader will COPY is rendered exactly as published, because
`.copyable` is `user-select:all` and the rendered text is the copied text. This
value renders as `span(class = "identifier " & Copyable)`. Inserting separators
would silently corrupt an on-chain fee on its way to a terminal.

Two of the four named the remedy the rule permits: "lead with an abbreviated
magnitude and keep the exact figure secondary", "carry a scaled form beside the
exact one".

Options:
  (a) a scaled companion — `1.76 × 10¹⁸` or `1.76 Emana` as the read figure,
      with the exact integer kept copyable and secondary. Answers all four
      findings and keeps the rule. Costs a new element in a facts grid, and the
      choice between scientific notation and an SI prefix is a register
      decision (this product's register is an explorer, not a lab);
  (b) group the digits and drop `.copyable` from this row. Cheapest, and it
      trades a legibility defect for a data-integrity one — the exact fee is
      the fact the row exists to publish;
  (c) group VISUALLY without changing the text, e.g. per-three-digit spans with
      letter-spacing, so selection still yields the bare integer. Preserves both
      properties; adds markup to every cost cell and has never been reviewed;
  (d) leave it and let the unit suffix carry the magnitude.

Recommendation: (a), and it needs a round to look at it. NOT (b): a fee is the
one number on the page a reader might paste somewhere it matters.

Note a second, separable finding on the same string that two lenses raised and
that IS a copy defect rather than a taste call: the unit renders
`mana (FeeJuice)` — a gas unit and an asset name in one value, and `FeeJuice` is
the camel-cased machine spelling of an asset Aztec writes as `Fee Juice`. That
is `roleLabel`-shaped work, not a numeric one.

## Q13 — DIAGNOSED, and the entry's premise was wrong. The mask is not defeated
The entry above says two reviewers found the Code pane hard-clipping mid-token
and that "something is defeating" a mask which demonstrably works elsewhere, and
it names two candidate mechanisms — (i) the mask is defeated, (ii) `.pane`'s
`overflow:hidden` cuts before `.src` ever sees it. It says explicitly that the
answer must be established before anything is fixed.

**It was established, in the built page, and it is NEITHER of them.**

Measured on `debugger/wide/dark` and `debugger/laptop/light`:

  * `.src` really does overflow: 911 client / **1167 scroll** at wide, 681/1167
    at laptop, `scrollLeft:0` — **30.4 characters hidden at wide, 57.7 at
    laptop** at 8.43px/char.
  * Nothing clips ahead of it. `.panebody`'s scrollWidth EQUALS its clientWidth,
    so it never sees horizontal overflow; `.pane`'s inner edge (x=916.0) and
    `.src`'s padding-box edge (x=916.28) coincide to sub-pixel. The cut belongs
    unambiguously to `.src`'s own `overflow-x:auto`. **(ii) refuted.**
  * The mask is working, and it is exact. On the graded PNG, L40's strip ramps
    **11.7:1 → 7.2:1 → 5.2:1 → 2.7:1 → 1.6:1 → 1.0:1** over exactly 48px. A
    probe overriding the stop to `calc(100% - 400px)` predicted ink 35.8 and
    measured 36, which proves the gradient is sized to the border box (911) and
    not to the scroll area (1167). Lines with no ink in the band are flat — no
    ramp, because there is nothing to fade. **(i) refuted.**
  * The nested-mask hypothesis is refuted too: disabling `.panebody`'s `to
    bottom` mask leaves the strip values **byte-identical**.

**The mechanism is (iii): the treatment is correct and under-scaled.** The ramp
is `--bt-space-2xl` = 48px = **5.7 characters**, of which only the last ~2.6
visibly ramp; the content it is signalling is 30 characters at wide and 58 at
laptop. The signal covers 19% / 10% of what it signals. Both reviewers were
right about what they saw — a line ending mid-identifier at the pane edge with
no legible continuation cue — and wrong about the cause: there is no hard clip,
there is a fade too short to read as one.

Two consequences fall out of the ramp being a property of the CONTAINER rather
than of each ROW, and both are measured:

  * **False positive.** laptop L42 is COMPLETE, ends 9.3px inside the band, and
    its last glyph is drawn at mask alpha **0.19** — erased on a line with
    nothing hidden. L43's last glyph sits at 0.72.
  * **False negative.** laptop L41 overflows by 1.9 characters and L49 by 2.9;
    those fall in the near-transparent tail, so both read as complete when they
    are not. That is exactly the crop a reviewer describes as "clipped
    mid-token".

This is the useful result and it is more general than this pane: **a
container-edge overflow cue cannot be correct in a region whose rows have
different lengths.** No ramp length fixes either consequence, so — as with Q11,
and for the same structural reason — the next move is a different treatment and
not a different number.

Options, in order of how little they change:
  (a) restore the SECOND affordance the fade is currently carrying alone.
      `.src` has 256–486px of real scroll range and the only reason the frame
      shows nothing is that the capture harness runs Chromium with
      `--hide-scrollbars` (`tools/capture/lib/determinism.mjs`). An explicitly
      styled always-present horizontal scrollbar is row-independent and
      quantity-proportional. **But note what this exposes about the
      instrument:** every horizontal-overflow finding in this campaign was made
      against an image with the platform's primary overflow cue deliberately
      removed for determinism. That is a fair thing for the harness to do and it
      is not neutral, and it should be said out loud in the brief;
  (b) make the cue PER ROW, which is the only option that fixes the false
      positive and the false negative together. CSS cannot query a row's own
      overflow, so this is a marker emitted by `components/debugger.nim` — a
      code change, reviewed by nobody;
  (c) lengthen the ramp. The numbers argue against it: at 8.43px/char you would
      need ~100px to signal even a third of the hidden content, and Q11 already
      recorded that lengthening the VERTICAL ramp drove in-box text to 2.19:1.
      Same trade, on the flagship pane;
  (d) leave it, now that it is understood.

Recommendation: (a) first, because it is the honest one — the affordance exists
and the instrument is hiding it — with the brief amended to say so. Then (b).
NOT (c).

## Q17. A comment claimed a behaviour the page does not have
Found while diagnosing Q13, and separable from it. `.srcline`'s comment said
`min-width:max-content` "makes the rows as wide as the widest line, so the
current-line fill and the executed-line stripe extend across the whole scrolled
width". `max-content` resolves PER ROW: `debugger/wide/dark` has four distinct
`.srcline` widths and `debugger/laptop/light` thirteen. Driving the pane to
`scrollLeft = scrollWidth` leaves the `.srcline.cur` fill's right edge at x=660.3
against a visible edge at x=916 — the highlight stops 256px short, which is
verbatim the "rendering fault once the pane is scrolled" the comment claimed to
prevent.

The comment is corrected in this round, because a comment that reads as evidence
and is not is the exact defect check-tokens B4 exists to catch, and B4 cannot
see this one — it only checks `ledger@` citations.

The BEHAVIOUR is not fixed and is queued here. It needs the rows' containing
block to be `max-content` sized, which `.src` cannot be without a wrapper
element it does not have. It is also invisible in the whole corpus: every
capture is taken at `scrollLeft:0`, where the fill covers the scrollport and
nothing looks wrong. So it is a real defect that no reviewer can ever file,
which is worth noting as a category — the campaign grades stills, and a defect
that only appears after an interaction is outside what any number of review
rounds can reach.

Options: (a) add the wrapper and size it `width:max-content;min-width:100%`;
(b) leave it, and accept that a scrolled Code pane shows a short highlight;
(c) capture a scrolled variant of the Code pane so the class of defect becomes
visible to the loop at all.

Recommendation: (c) is the interesting one and is cheap — it would give the
campaign its first post-interaction subject. (a) after it, so the fix is
photographed rather than asserted.

## Q1 — the `⊙` / `·` collision is REFUTED, and the contrast half is fixed
Q1 ranked the `⊙`/`·` collision FIRST, on `debugger/laptop/light` L3's reading
that `·` "IS `⊙`'s own centre — 2.9 against 3.27 alpha-px, 11% apart", so that
"the affirmative mark is the neutral mark plus a sub-3:1 ring". The file already
recorded that three L3 lenses disagreed and declined to resolve it. It is now
measured in all four size/theme combinations of the built page, and the two
laptop/dark and wide/dark lenses were right:

  * `⊙` vs `·`: **IoU 0.138** (dark) / 0.154 (light), **88.4% apart**, 28.6
    alpha-px against 3.3 — a 10x11 ring against a 2x2 dot. Identical in all four
    combinations, so it is not conditional on the band either.
  * Isolating `⊙`'s centre DISC and comparing only that against `·` — the most
    charitable reading of the laptop/light lens — gives 7.3 vs 3.3 alpha-px
    (54.7% apart) and 8.9 vs 3.1 (65.4%), not 11%.

**The collision is not real.** The `⊙`/`⊘` pair, ranked second, reproduces:
IoU 0.750 (dark) / 0.781 (light), 12.6-13.7% apart. That half stands.

The CONTRAST half is fixed this round and was not the fix Q1 proposed. Every
option this entry carried proposed changing the GLYPH — retint it, redraw it,
drop it — and the later `(e)` proposed changing the BAND. The actual defect was
neither: the current line's ink pair was already designed, already measured at
7.14/7.30, already documented, and defeated by cascade order, because
`.srcline .mt` has equal specificity to `.srcline.cur .m` and comes later. One
selector restores it, at 7.21:1 light / 7.16:1 dark verified in the export.
Option (e) — retinting `--bt-mark-position-surface` — is now positively ruled
OUT rather than merely unnecessary: that token is read by `.ctrow.cur` and
`.evrow.cur` as well, carries 14-16 measured foreground pairs per page, and in
LIGHT there is no headroom at all — the lightest plausible band `#ecfeff` only
reaches `⊙` 5.15:1, at which point the band is a 1.06:1 step off white and stops
reading as a band.

WHAT REMAINS QUEUED is only recommendation (b): the pair is still not separable
without hue at IoU 0.750/0.781, and Q1's own text says the choice of replacement
silhouette is the taste call. Cyan's role count is also untouched and is the
wider token-overload finding.

## Q18. `▶` is never painted anywhere in the corpus, and nobody has filed it
Found while measuring Q1, in every view the harness captures.

`components/debugger.nim` documents a vocabulary of `⊘` / `⊙` / `·` with "the
ordinary marker underneath" — `▶` for the current line. The gutter enumeration
finds **zero** `▶` on `debugger`, `debugger--call-trace`, `debugger--event-log`,
`debugger--divergent`, `debugger--truncated`, `debugger--metadata-pane`,
`tx-detail--session`, or the home page's live demo.

The mechanism is structural rather than accidental. The line the session is
stopped at is also, on this fixture and plausibly on most, an arm that ran in
the displayed pass, so it carries `cur hit nt-i0 nt-i1 rn-i2 rnnow`.
`.srcline.rnnow .mg{display:none}` then hides the wrapper that would have drawn
`▶`, and the mark cell is given over to `⊙`. So the four-glyph vocabulary is
three glyphs in practice, and — before this round's fix — the cell identifying
where you are was painted in *executable* ink rather than *position* ink, which
made the lowest-contrast mark on the page the one saying "you are here". The
ink half is fixed; the missing glyph is not.

This is not obviously a defect, which is why it is queued rather than fixed. The
current line is already marked by the band, the border-left and the line number,
so nothing is unsignalled — the question is whether the gutter cell should show
position AND the arm, and there is no room in one cell for two glyphs.

Options:
  (a) show both, by giving the mark cell room for two glyphs — costs gutter
      width on the flagship pane, which Q2 says is the column already short of
      it;
  (b) prefer `▶` and drop the arm glyph on the current line — loses the
      affirmative "this arm ran" signal on the one line a reader is looking at
      hardest, which is the defect the arm glyphs were introduced to fix;
  (c) prefer the arm glyph, as today, and DELETE `▶` from the source comment and
      from the renderer, since it is dead code that documents a vocabulary the
      page does not have;
  (d) merge them — a single mark that carries both, e.g. the arm glyph in
      position ink, which is what this round's fix already accidentally does.

Recommendation: (d) is already shipped as a side effect and should be looked at
by a round before anything else is decided. If reviewers read the cyan `⊙` on
the band as "you are here AND this arm ran", the vocabulary is complete and (c)
follows — delete the dead `▶` rather than restore it. That is a question for
eyes, not for measurement, and this round's re-capture puts it in front of them.

## Q11 — SETTLED. Option (a) is a misconception, and two of the findings cannot both be answered
Q11 recommended option (a) — "fade the INK only, not the scroll container: put
the mask on an inner wrapper so the pane's surfaces and borders stay solid" —
and called it "the only option that answers all four measurements". It was
measured in the built page. It does not work, and it cannot.

**A mask composites the whole subtree at one alpha.** `mask-origin` and
`mask-clip` choose which RECTANGLE the mask covers, never which PAINT it applies
to. An inner wrapper still contains `pre.raw`, so it still contains that
element's background. Three variants were tried in-browser:

  * **a1, the inner wrapper** — worse than a no-op. The wrapper IS the scrolled
    content, so `calc(100% - 24px)` resolves against `scrollHeight`: the metadata
    pane's wrapper measured h=1178.27, bottom=1273.06, putting the ramp 174px
    BELOW the clip. In the visible area the fade vanishes entirely, pixel-for-
    pixel identical to deleting the mask. It also breaks layout — `.srcwrap`
    loses its definite height, the Code pane's wrapper collapses to 39.19px and
    the pane renders empty — and it relocates the call-trace ramp to mid-pane,
    fading content at no boundary at all.
  * **a2/a3, `mask-clip`/`mask-origin` to content-box or padding-box** —
    byte-identical to baseline, sha256 over the raw pixel buffer, all four
    captures. Every `.panebody` has `padding:0` and `border-width:0`, so the
    three boxes coincide and there is nothing for these properties to move.
  * **a4, a `.pane::after` gradient veil instead of a mask** — every number
    matches the mask to ±1/255. An overlay tinted with the pane surface
    composites toward exactly the colour the mask composites toward.
  * **a5, `padding-bottom` to reserve a glyph-free band** — identical to
    baseline. A scroll container clips at its PADDING box and content scrolls
    through it, so bottom padding reserves nothing mid-scroll.

**THE DEADLOCK, stated exactly.** Finding (1) requires the ramp not to touch
live glyphs. Finding (3) requires it not to touch the RAW well's surface. A mask
over a scroll container touches both by construction, and the only free
parameter — ramp length — trades one against the other. That is the same
deadlock this entry already described at the level of "reads as continuation
versus keeps the last line legible", now shown to be structural rather than a
matter of tuning.

### What reproduced, what did not
  * **(1) reproduced, and worse than recorded in one specific way.** The CSS
    comment says 2.19-2.22:1 and 2.43:1 were measured at the reverted `2xl` and
    that reverting to `lg` answered them. **They reproduce AT `lg`.** On
    `debugger/wide/light`, Code pane line 61 — entirely inside the clip — runs
    4.81 -> 3.19 -> **2.19:1**; its coverage dot reads **2.60:1** against
    **4.87:1** for the identical dot one line up outside the ramp; the gutter
    number reads 4.36:1 in dark. The Transaction pane's last fully-inside line
    goes 12.47:1 -> **3.04:1**. Three marks under 4.5:1 on text that has not
    left the box, in the shipped build. **The revert did not change what it was
    made to change**, and that is the load-bearing correction.
  * **(3) reproduced and understated.** `pre.raw`'s surface does not stop at
    `#FBFBFB`; it ramps to **(255,255,255)**, complete erasure, and its 1px
    `#A2A2A2` bottom border measures **1.06:1** against the pane instead of
    3.66:1 when scrolled to the end. On `debugger--testnet/wide/light` the
    entire visible extent of `pre.raw` is 24.8px and ALL of it is inside the
    ramp — that well never renders at full strength anywhere on that page.
  * **(2) "the fade renders behind its text" — not reproducible as stated.** A
    mask is an alpha channel on the element's own output; nothing can be behind
    anything. The observable it names is (3): the well's surface gradient reads
    as a band around the glyph.
  * **(4) "anchored to the pane BORDER rather than the content box, so it spends
    its first 9px fading padding" — REFUTED.** There is no padding anywhere in
    the chain; all 24px of the ramp fall on content. Its corollary — "`.src`
    masks the content element and was already doing the right thing by accident"
    — is wrong about mechanism too. `.src` reads correctly because it paints
    `--bt-surface-raised`, the SAME colour as the pane behind it, so fading it
    changes nothing visible; `pre.raw` paints `--bt-surface-code`, which differs,
    and is destroyed. Nothing to do with clip boxes. **This entry's "mechanism
    isolated" result from vd9-r2 should be treated as withdrawn.**
  * **(5) the 5x theme gap — attribution refuted, figure real, two ledger rows
    crossed.** `"hydrationRounds": 6,` sits at y=1248.95 on a canvas 1080 tall:
    it is **174px below the clip and not in either image**. The 1.16:1 IS real,
    on the `{` of line 0 at y=1072. The same rows in dark measure **1.31:1, not
    6.17:1** — a theme gap of 1.37x, not 5x. 6.17:1 does exist in the corpus, at
    `debugger/wide/**dark**` `pre.raw` y=1060. So the "cleanest comparison in the
    campaign" compared two different lines.
  * **(6) the compounding is confirmed and quantified**, and its mechanism is
    not the one the sibling diagnosis guessed: `.src` and `pre.raw` are
    DESCENDANTS of `.panebody`, so their paint passes through both masks.
    a = a_h x a_v matched measurement to within 1/255. Affected surface reaches
    full page-white ~10 rows earlier than the vertical mask alone, on `pre.raw`
    in the metadata pane only. **Surface only today — no ink lies in the overlap
    on any of the four captures.**
  * **NEW: the fade never switches off.** Anchored to the scroll container's
    border box, so a pane scrolled to its very END still fades its last line at
    full strength with zero content hidden below: the RAW block's last line goes
    13.13:1 -> 3.21:1 and its bottom border vanishes. This is the vertical
    analogue of Q13's false positive, and it is arguably worse — not a pane
    faded that never overflows, but a fade that stays on after the reader has
    arrived.

### The options, now that they are real
  (a) **withdrawn** — measured, does not work, breaks layout.
  (b) drop the mask; mark overflow with an edge rule or a persistent scrollbar.
      Zero contrast cost. Reintroduces the hard edge L2 credits the fade with
      removing, and Q13 shows the scrollbar is suppressed in the corpus by
      `--hide-scrollbars` anyway, so this needs the harness decision too;
  (c) keep the fade and move `--bt-surface-code` OUT of the masked subtree, so
      the RAW well's surface is painted by an element the mask does not cover.
      This is the only thing that answers (3), and it answers nothing else;
  (d) reserve a glyph-free band with a SPACER ELEMENT as the last child of the
      scroll content — not `padding-bottom`, which a5 measured to do nothing.
      At the end of the scroll the spacer sits under the ramp, so the last real
      line is legible and the fade correctly signals nothing; mid-scroll the
      ramp still falls on text that genuinely has more below it, which is the
      honest case. Answers (1) and the never-switches-off finding together, and
      does not answer (3);
  (e) accept the deadlock, leave `lg`, and record that the last line of an
      overflowing pane is dim by design.

Recommendation: **(d) then (c)**, in separate commits, each photographed. They
are independent and they answer different findings. NOT (a). And the CSS
comment's claim that reverting to `lg` answered finding (1) is corrected in this
round, because it does not.

## Q19. P1 — the outcome badge contradicts the reason printed beneath it
`debugger/wide/light` ADV, vd10-r1, and it is the round's best finding. The
amber `Partial` badge (identity bar x202-261 y20-42, and again in the transaction
pane at x1542-1601 y99-121) sits directly above `Status reason:
private-part-succeeded-public-part-succeeded` at y150-188. The badge asserts a
warn-toned partial outcome; the reason says both halves succeeded. One of the two
is false and the reader cannot tell which.

Q3 already held that reason STRING as a copy problem. This is a different and
sharper claim about the same pixels: not an infelicity, a contradiction.

### The mechanism, traced to the source
`ooPartial` does NOT mean "partially succeeded". The contract's own comment is
`ooPartial = "partial"  ## atomicity is not universal` — it names the SHAPE of
the commit, a transaction that committed as several independently-committing
units (NEAR receipts, TON branches, the Aztec private/public split). The demo
generator says so explicitly at `generator.nim:374`: "txB's `ooPartial` is the
Aztec split with BOTH halves succeeded", and its `parts` carry
`{"unit":"private","outcome":"succeeded"}` and
`{"unit":"public","outcome":"succeeded"}`.

So the model is right and the RENDERING is wrong. `outcomeClass` maps
`ooPartial -> "warn"` unconditionally, and `outcomeLabel` maps it to the English
word "Partial", which every explorer uses to mean "something did not fully
work". A split commit in which nothing failed is painted as a warning.

### Why it is not a one-line fix, which is the useful part
The tone cannot be computed from the enum, because the enum genuinely covers
both cases — a split where every part succeeded, and a split where one did not.
The information that separates them is `Outcome.parts`, and **the client's view
model drops it**: `contract/model.nim` has `outcome*: Outcome` (with `parts`),
while `client/src/reader.nim` flattens it to `outcome*: OutcomeOverall` in both
`TxView` and `TxRow`. `reason` survives the flattening; `parts` does not.

So every client surface that paints this badge — `pages/tx.nim:189`,
`components/tables.nim:97`, `debugger/demo_session.nim:341` feeding
`pages/debug.nim:170` — is computing a tone from a value that cannot carry the
answer. Deriving it from `reason` instead would mean parsing an opaque
chain-specific string, which is worse than the defect.

### Options
  (a) carry the parts. Add the one derived fact the badge needs to the view
      model — e.g. `outcomeAllPartsSucceeded: bool` populated where `TxView` and
      `TxRow` are built — and make `outcomeClass` consult it. Reading published
      parts is not the "deriving a fact the tree does not publish" §7.2 forbids;
      the parts ARE published. Touches three surfaces no reviewer has seen
      changed, which is why it is not taken here at the end of a session;
  (b) retone only: make `ooPartial` neutral rather than `warn` everywhere.
      One line, and wrong on the chains where a part really did fail — it would
      silence a genuine warning to fix a false one;
  (c) relabel only: `Partial` -> a word naming the SHAPE ("Split", "Two-part",
      "Multi-part"). Removes the "something went wrong" reading without touching
      tone or view model, and is honest for both cases, since a split commit is
      a split commit whether or not a part failed. Cheapest correct-in-all-cases
      option, and it is a copy decision;
  (d) (a) and (c) together — the badge names the shape, the tone names whether
      anything failed. This is the only combination in which the badge and the
      reason cannot contradict each other.

Recommendation: **(d)**, with (c) landable first and independently since it needs
no view-model change. NOT (b).

Note this also resolves the shape of Q3: once the badge stops claiming a
warning, the raw reason string is a copy problem again rather than half of a
contradiction, and Q3's options apply to it unchanged.
