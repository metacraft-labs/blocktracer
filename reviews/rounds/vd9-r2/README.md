# vd9-r2 — INCOMPLETE, and deliberately NOT ingested

This round was dispatched against the corpus captured after vd9-r1's five fixes
and after the follower's two commits (`30dce21`, `b7cafba`) changed the mainnet
zero-trace page's provenance copy. **Five of forty-two reviews completed.** The
other thirty-seven did not run: seventeen were dispatched and twelve of those
produced no model output at all over more than an hour — their transcripts hold
the prompt and nothing else — and the remaining twenty-five were never dispatched
because the concurrent-subagent cap was already saturated by the stalled ones.

## Why nothing here is in the ledger

Ingesting would have filed two triples at 3/6 and 2/6 lenses. `gate.mjs` would
then have reported G1 and G2 failures for those triples, and both would have been
artefacts of a dispatch stall rather than statements about the product — the
exact confusion the gate exists to prevent. `reviews/ledger.json` therefore still
holds vd9-r1 at revision 2026-08-31.7, whose reviews are of a SUPERSEDED capture
(the corpus was re-captured after the fixes landed), and `gate.mjs` says so for
every triple. That is the honest reading and it is the one the tooling gives
without being asked.

**`just review-verify reviews/rounds/vd9-r2` will FAIL on this directory**,
reporting five reports that never reached the ledger. That is the check working,
not a defect: the check was added in `f07f9a7` precisely so that a report on disk
which never became evidence cannot pass unnoticed. Do not silence it by ingesting
a partial round.

## What the five reviews establish

They are kept because they are evidence of what was seen, and two of them settle
open questions from vd9-r1:

* **`tx-detail/wide/light` L5 WITHDREW its r1 P1 on the absent 'supply an ABI'
  action and judged Rule 2 satisfied.** That P1 was the campaign's only G1
  failure. Its reasoning is better than the argument that produced the fix: the
  action branch of the expectation presumes raw bytes, and this transaction has
  none (`Raw —`), so a `supply an ABI` control would be inert *even in a product
  that accepted ABIs* — the "retry that cannot succeed" §1 forbids. The note
  naming the gap is the honest render. Three of three reviewers on this triple
  reported `present`, 0 P1.

* **`tx-detail--mainnet-zero-trace/wide/light` ADV and L5 both confirm the
  `RAW 0x` P1 is resolved** and report `present`, 0 P1. That triple carried 2 P1
  in r1.

Across all five: **0 P1**, 13 P2, 15 P3, and every reporting lens returned
`expectedElements: present`.

## What they found that is new, and unfixed

All of it is in the provenance sentence the follower's `b7cafba` introduced —
which is correct about the world where the previous sentence was false, and is
not yet well made:

1. It ends in the bare enum `AvmToolchainRegression`, twice, unglossed, in the
   body face (L5).
2. It ships pluralisation placeholders — `2 transaction(s)`, `27 transaction(s)`
   — and a shouted `WERE` (L5).
3. Its own numbers do not cover this transaction. The window is stated as
   67651-67686 and pruning as "below block 67650"; the subject is at 67650, so it
   falls in neither set (ADV and L5, independently).
4. The `Not observable` card claims permanence while citing only a fixable engine
   regression, and never states that the body has since been pruned — so the card
   and the paragraph give a reader two different reasons and no way to reconcile
   them (ADV).

(3) and (4) are the substantive ones: they are honesty defects on the one element
of the page whose entire job is to be believed, and they were introduced by the
commit that fixed a different honesty defect on the same element.

## To resume

Re-capture is NOT needed — `screenshots/` already matches this round's subjects
(`check-coverage` assertion F: 308 compared, 0 drifted). Re-dispatch all 42
reviews against the current capture, ingest as complete triples only, then
`just review-verify reviews/rounds/<round>` in both directions.

## Update — one triple completed and WAS ingested

After this README was first written, more reviewers unstalled. Thirteen of the
forty-two eventually reported, and `tx-detail/wide/light` reached 6/6.

**That triple was ingested** (ledger 2026-08-31.7 -> .8) because it is complete
and therefore says something about the product rather than about the dispatch.
`tx-detail--mainnet-zero-trace/wide/light` reached 5/6 — its L3 never returned —
and was NOT ingested, for the reason given above.

The result is that **G1 is now 7/7**: every triple in the gate scope reports
`expectedElements: present`, and the campaign's only G1 failure — the absent
'supply an ABI' action — is closed by the reviewer who filed it withdrawing it.

G2 is 1/7, and every one of the six failures is the gate correctly reporting that
those triples still carry vd9-r1 reviews of the PRE-FIX capture. Clearing them is
what the rest of vd9-r2 would have done. Nothing about those six is a product
statement; re-run their reviewers against the current corpus.

Seven reports in this directory are still not in the ledger and
`just review-verify reviews/rounds/vd9-r2` still fails naming them. That remains
correct and should stay failing until they are either re-run or superseded.


## Final state of this round — four triples were never completed

Dispatch was retried after the first stall and the reviewers restarted, but
throughput collapsed a second time: sixteen agents ran for hours against a
tightening rate limit, transcripts reaching 9 MB of image analysis apiece, and
the last measured window had one agent active. Twenty-two of forty-two reports
exist.

INGESTED — three complete triples, all re-reviewed against the current capture:

  tx-detail/wide/light                      6/6  G1 ok
  tx-detail--mainnet-zero-trace/wide/light  6/6  G1 FAIL (see below)
  debugger/wide/light                       6/6  G1 ok

NOT INGESTED — four incomplete triples, whose ledger entries are therefore still
vd9-r1's reviews of the PRE-FIX capture, which `gate.mjs` reports as
G2-superseded:

  debugger/wide/dark          L5, ADV        (2/6)
  debugger/laptop/light       L1, L5         (2/6)
  debugger/laptop/dark        none           (0/6)
  debugger--testnet/wide/light none          (0/6)

Their four loose reports are kept as evidence and are NOT in the ledger.
`just review-verify reviews/rounds/vd9-r2` names them, correctly, and should stay
failing until each triple is completed and ingested.

The mainnet G1 failure is not a regression: L3 reported `forbidden-present`
against an expectation that had gone stale, and the EXPECTATION was corrected in
`40aa0e0` rather than the page. Its second P1 — the page asserting permanence
while printing a repairable cause — survives that correction and is Q10.

## To finish this round

Do NOT re-capture. `screenshots/` already matches these subjects
(`check-coverage` assertion F: 308 compared, 0 drifted), so the four incomplete
triples can be reviewed against the corpus exactly as it stands. Dispatch the
twenty missing reviews, ingest each triple only at 6/6, then run BOTH directions
of `just review-verify`.

The single most useful one is `debugger--testnet/wide/light`, which has not been
reviewed at all this round: its subject publishes `transactionFee`, so the Q9
cost-label wrap regression should reproduce there and be measurable, and it is
the only real-chain subject in the debugger register.
