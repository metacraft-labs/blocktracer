# vd10-r1 — COMPLETE. 30 reviews, 5 triples, both directions verified

Dispatched against the corpus captured after this session's three fixes, in five
batches of six. Every triple is 6/6 and in the ledger at revision 2026-09-01.5.
`just review-verify` passes both ways: 42 ledger reports still hash to what was
ingested, and all 30 files in this directory parse and are accounted for.

`tx-detail/wide/light` was NOT re-reviewed and did not need to be — its capture
hash never moved, so its vd9-r2 reviews remain reviews of the image on disk and
G2 stays green. Re-reviewing it would have been busywork. The round is therefore
30 reviews, not 42, and the gate says why for every triple.

  triple                                    G1  G2   P1   rating
  tx-detail/wide/light                      ok  ok    0   (carried from vd9-r2)
  debugger/wide/light                       ok  ok    1   6-7
  debugger/wide/dark                        ok  ok    1   6-7
  debugger/laptop/light                     ok  ok    1   4-7
  debugger/laptop/dark                      ok  ok    2   4-6
  debugger--testnet/wide/light              X   ok    2   4-6
  tx-detail--mainnet-zero-trace/wide/light  X   X     3   (unphotographable)

**G1 5/7, G2 6/7, G3 0/7.** G4/G5 need a named human and G6 cannot reach a
tier-1 verdict on darwin, so the gate stays 0/7 by construction.

## The two G1 failures are different in kind

`debugger--testnet` is a REAL, CORROBORATED presence failure and the round's most
important product finding. **Three lenses independently report the replay
telemetry absent** — instructions executed, effects matched, `effectsMismatched:
0`, which the expectation block calls "the evidence the session is faithful".
L4 established it is a REGRESSION and measured the proximate cause: the
provenance paragraph grew from 216px (vd9-r1) to 377px, 38.5% of the pane body,
and evicted the telemetry off the fold. In vd9-r2 `"instructionsExecuted": 345,`
was still legible at y1042 and filed only P2; now there is zero telemetry ink on
screen. Copy growth on one row pushed the page's proof of faithfulness out of the
photograph.

ADV and L1/L2 recorded `present` on the same image, judging the pane a scroll
region rather than a clip — the distinction this session spent two diagnoses
establishing. Both readings are defensible and the disagreement is itself the
finding: a must-show that is only reachable by scrolling is not shown.

`tx-detail--mainnet-zero-trace` is the STALE failure carried from vd9-r2 and
cannot be cleared by review. See Q15.

## What the round did to this session's three changes

  * **(a) the current-line arm glyph taking position ink — LANDED, with a
    theme-split cost.** Confirmed by six lenses. In the DEFAULT theme it wins on
    both axes: figure-ground 4.26 -> 7.14:1 (the recorded ceiling reproduced
    exactly), figure-figure 1.30 -> 2.17:1. In LIGHT it wins figure-ground
    (4.29 -> 7.30:1) and LOSES figure-figure, 1.71 -> 1.00:1, because the light
    position ink and the not-taken ink are luminance twins (0.0652 vs 0.0648).
    That is a specific ink collision, not a property of the change. Q1 updated.
  * **(b) the no-break cost label — INERT, and on this corpus INAPPLICABLE.**
    Six lenses. The synthetic subject's dimension is `mana`, ONE WORD, so
    `unbreakableDimension` has no internal space to convert and cannot fire at
    any width. The one subject that could exercise it, `debugger--testnet`,
    renders `COST · TRANSACTION FEE` on one line with 52-55px clear, so the
    label never wraps there either. The row is 46px against 30-32px siblings —
    1.44-1.53x — and every extra pixel is the VALUE's second line. **The fix may
    be correct and this corpus cannot photograph it.**
  * **(c) thousands grouping — landed mechanically, failed as a rule, and
    hardened an ambiguity.** Six lenses judge the rule un-inferable. The
    decisive counterexample is that `128 / 1,315` and `88000 / 200000` are the
    same N-slash-M construct 600-730px apart under opposite rules, and the ACIR
    counts are equally copyable to a reader and ARE grouped. Worse, the
    justification was FALSE — the two `1,315`s are a step count and an opcode
    total, equal by coincidence — and grouping made them character-identical
    where they used to look unlike. Corrected in source; Q20 records the remedy.
  * **(d) the fades, deliberately unchanged after this session refuted the
    queued fix — CONFIRMED CORRECT.** L2 WITHDREW the finding that created Q13.
    L3 WITHDREW the 5x light/dark gap. L3 reproduced the 2.19-2.22:1 in-box cost
    exactly at the shipped ramp, which is the independent confirmation that the
    earlier revert never achieved what it was made to achieve.

## Withdrawals on measurement — eleven, across five triples

The round's defining feature. Reviewers withdrew their own and each other's
prior findings, each time naming the method that produced the earlier number:

  * the Code pane "hard clip" that created Q13 (ink holds to x861, ramps to 6 by
    x913 — "the fade is real and correct");
  * the 5x theme gap on the pane mask (2.90x dark vs 2.82x light);
  * the 1.16:1 record — `"hydrationRounds": 6,` is not in the image at all; the
    genuine floor is 1.67:1 on the `{` of line 0, and the earlier method sampled
    a column with no glyph in it, comparing two backgrounds;
  * the 6.17:1 dark counterpart — the same glyph peaks at 2.28:1;
  * the 91% Call Trace emptiness — reproduced at 91.0% and re-classified
    CONTENT-shaped, with the layout half re-aimed at allocation;
  * the `⊙`/`·` collision — improved rather than refuted, so P3 not gone;
  * IoU 0.750 — a box/threshold artefact; 0.889 is stable across both themes;
  * the 2.43:1 coverage dot — all twelve read 6.86:1;
  * an ADV P1 that `128 / 1,315` was arithmetically impossible — a unit error,
    withdrawn on source evidence and renumbered `ADV/2` so the withdrawal stays
    legible;
  * "128 columns, 58 hidden" — 16% high; the widest rendered line is 120;
  * the fee "wrapping raw hex breaking the grid" — it is a right-aligned
    formatted decimal and the grid is intact.

## The standing measurements, re-tested

Columns 913/608/383 at 1920 and 683/454/287 at 1440 — 1.337x on a 1.333x
viewport ratio, i.e. a percentage-only split with no min-width and no reflow
rule, and byte-identical between the source-bearing and source-less subjects, so
the split never consults content. On `debugger--testnet` that puts **70.9% of the
page's ink in the 20.1%-wide column**, which is the only one that overflows —
and it is what evicted the telemetry. Q2's conclusion survives; its stated reason
did not (the 8%-vs-30% pair that founded it mixed measurement conventions).

## Two P1s that are neither stale nor disputed

  * the amber `Partial` badge contradicting `Status reason:
    private-part-succeeded-public-part-succeeded` — filed on four captures, Q19;
  * the phase rail lighting `FETCHING` on a demonstrably finished session — Q6.

And one new from ADV on `debugger--testnet`: `Supply sources` is a bare `<button>`
with no handler, href or `aria-disabled` on a page whose eight stepping controls
all carry `aria-disabled="true"` with bespoke reasons. The only control that
hides its incapacity, and it is the page's sole promised route out of its central
limitation.

## An incident worth recording

The `debugger--testnet` ADV reviewer ran `sips -c 1 1` on the capture, which
crops in place, and destroyed it. `screenshots/` is gitignored so there was no
git recovery. It regenerated the file immediately and the result hashes
`9c72728d492b` — byte-identical to the image every other lens reviewed and to
what the ledger holds, which the determinism harness is precisely what makes
possible. G2 verified it independently afterwards.
