// recount.mjs — the ONE implementation of a snapshot's `counts`.
//
// ── WHY THIS IS A MODULE AND NOT THREE COPIES ──────────────────────────────────────────
//
// It was three copies, and they had drifted, and the drift reached committed data.
//
//   `follow-chain.mjs`   the full tally, missing `privateOnly` — so `accountedFor` there
//                        omitted the chain-absent rows and could not equal `transactions`
//                        on any snapshot holding one.
//   `ingest-range.mjs`   the full tally including `privateOnly`. The reference.
//   `backfill-blocks.mjs` spread `...s.counts` and recomputed only `blocks`,
//                        `blocksWithTransactions`, `transactions` and the refusal block —
//                        so every OUTCOME line survived a run that added rows, by
//                        construction, with a comment above it explaining that a snapshot
//                        whose counts describe a different set of rows than it holds "is
//                        worse than one with no counts at all".
//
// That third one is measurable in the tree: `client/fixtures/chain/aztec-testnet/snapshot.json`
// shipped `counts.pruned: 25` against **835** actual pruned rows, and its four outcome
// lines summed to 51 against `counts.transactions: 866`. The 815 rows a whole-history
// backfill added were all counted into `transactions` and none of them into `pruned`.
// `migrate-refusal-reasons.mjs` then rewrote the file without recounting at all, so nothing
// corrected it.
//
// Data-Contract.md §5.2 gives `counts` one job — it exists "so a partial ingest is
// detectable" — so a stale `counts` is the detector reading clean on exactly the condition
// it detects. This repository has already written down what to do about a condition that
// can be restated: "what was wrong was never the condition, it was that the condition was
// restatable at all" (`lib/replay.mjs`). So the tally is here, once.
//
// ── THE THREE POPULATIONS, AND WHY `accountedFor` RANGES OVER ALL OF THEM ──────────────
//
// The four outcome lines are NOT a partition and never were: `not-first-in-block` and
// `not-attempted` appear in none of them, and `private-only` is not an untraced outcome at
// all. So the figure that has to equal `transactions` is `accountedFor`, over
//
//   tracesPublished   replayed + divergent          — a container exists and it steps
//   untraced          every UNTRACED_OUTCOMES row    — this pipeline declined it, by name
//   privateOnly       every CHAIN_ABSENT_OUTCOMES row — the chain published no such execution
//
// and it is PUBLISHED rather than asserted, because a count is a measurement.
// `assertRefusalsAreClosed` is the gate; this is the reading.

import { refusalCounts } from './refusal.mjs';

/**
 * Recompute `s.counts` from `s.blocks`, `s.transactions` and `s.captures`.
 *
 * REPLACES the object rather than merging into it. A merge is how a stale outcome line
 * survives a run that changed the rows underneath it, which is the defect this module
 * exists to make unrepeatable: every field below is derived from the arrays on every call,
 * and a field that is not derived is not published.
 *
 * @param {object} s a snapshot, mutated in place
 * @returns {object} the counts, for a caller that wants to report them
 */
export function recountSnapshot(s) {
  const txs = s.transactions ?? [];
  const by = (o) => txs.filter((t) => t.outcome === o).length;
  const counts = {
    blocks: (s.blocks ?? []).length,
    blocksWithTransactions: (s.blocks ?? [])
      .filter((b) => (b.transactions ?? []).length).length,
    transactions: txs.length,
    bodyRetained: txs.filter((t) => t.bodyRetained).length,
    replayed: by('replayed'),
    divergent: by('divergent'),
    refused: by('refused'),
    pruned: by('pruned'),
  };
  counts.tracesPublished = counts.replayed + counts.divergent;
  // `null` AND NOT `undefined` FOR A `captures` THAT IS NOT AN ARRAY, because
  // `JSON.stringify` DROPS an undefined-valued key and a vanished count reads as a
  // snapshot that never had one. This is not hypothetical: `aztec-testnet-frames`'
  // `captures` was committed as a JSON OBJECT with numeric string keys, `.length` on it is
  // `undefined`, and `ingest.nim` — which gates on `caps.kind == JArray` — silently skipped
  // the whole per-capture recorder attribution for that snapshot. A `null` here says "this
  // is not countable" where an absent key said nothing at all.
  counts.captureSessions = Array.isArray(s.captures) ? s.captures.length : null;
  const refusals = refusalCounts(txs);
  counts.refusals = refusals.byReason;
  counts.refusalsTotal = refusals.total;
  counts.refusalsUnclassified = refusals.unclassified;
  counts.privateOnly = refusals.chainAbsent;
  counts.untraced = refusals.total + refusals.unclassified;
  counts.accountedFor = counts.tracesPublished + counts.untraced + counts.privateOnly;
  s.counts = counts;
  return counts;
}

/**
 * Which `counts` members disagree with the rows, WITHOUT writing anything.
 *
 * The read-only half, for a checker. `recountSnapshot` repairs a tally; this one reports a
 * tally that is already wrong, which is what a gate over committed data needs — a check
 * that fixed what it found would go green on a tree it had just changed.
 *
 * @param {object} s a snapshot
 * @returns {Array<{member: string, declared: unknown, actual: unknown}>}
 */
export function countsDisagreements(s) {
  const declared = s.counts ?? {};
  // Recomputed over a shallow copy so the subject is not repaired by being checked.
  const actual = recountSnapshot({ ...s, counts: {} });
  const out = [];
  for (const [member, want] of Object.entries(actual)) {
    if (member === 'refusals') {
      for (const [id, n] of Object.entries(want)) {
        const got = declared.refusals?.[id];
        if (got !== n) out.push({ member: `refusals.${id}`, declared: got, actual: n });
      }
      continue;
    }
    // A member the snapshot does not declare at all is reported as `undefined` rather than
    // skipped: an absent count is not a matching count, and treating it as one is how
    // `privateOnly` and `accountedFor` came to be absent from all three committed captures.
    if (declared[member] !== want) {
      out.push({ member, declared: declared[member], actual: want });
    }
  }
  return out;
}
