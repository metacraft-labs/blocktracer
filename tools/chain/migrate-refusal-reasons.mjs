#!/usr/bin/env node
// migrate-refusal-reasons.mjs — bring a snapshot written before ING-3 into the closed set.
//
//   node tools/chain/migrate-refusal-reasons.mjs client/fixtures/chain/*/snapshot.json
//   node tools/chain/migrate-refusal-reasons.mjs --check <paths…>    # report, write nothing
//
// ── WHY THIS EXISTS RATHER THAN A TOLERANT GATE ────────────────────────────────────────
//
// `assertRefusalsAreClosed` runs in the write path of every snapshot producer, and the
// committed captures predate the field it checks. The cheap fix is to make the gate ignore
// rows that carry no `refusalReason` — and that fix would be the defect. A gate with a
// legacy exemption is a gate whose coverage shrinks every time somebody is in a hurry, and
// the exempt set here is not small: `client/fixtures/chain/aztec-testnet` alone holds 841
// untraced rows, which is most of the untraced transactions this repository has ever
// published.
//
// So the snapshots move instead. This tool is committed rather than run once and deleted
// because the migration is a CLASSIFICATION and a reader has to be able to check it: which
// legacy outcome became which member, and on what grounds.
//
// ── THE CLASSIFICATION, AND WHERE IT IS AND IS NOT LOSSY ───────────────────────────────
//
// Three of the four legacy outcomes carry their member in the name and are exact:
//
//   not-first-in-block  →  not-first-in-block
//   pruned              →  body-unavailable
//   not-attempted       →  not-attempted
//
// The fourth is `refused`, which is every runtime throw, and its member is decided by the
// runtime error class the row already recorded in `refusal` — the same table
// `reasonForRuntimeClass` uses for a live capture, so a migrated row and a freshly captured
// one classify identically.
//
// IT IS LOSSY IN EXACTLY ONE PLACE, AND THAT LOSS IS OLDER THAN THIS TOOL. Two rows in
// `client/fixtures/chain/aztec` carry `refusal: "unknown"` — the two mainnet catches of
// 2026-08-31 that `lib/replay.mjs` records at length, filed by a classifier that was a
// suffix allowlist, whose bodies have since pruned. There is no class name to map, so they
// migrate to `runtime-refused`: a member with its own count, carrying `unknown` beside it as
// the evidence it is. That is the honest answer. Inventing a more specific member for them
// would be reading a cause out of a field that says the cause was never recorded.
//
// ── WHAT IT WILL NOT DO ────────────────────────────────────────────────────────────────
//
// It never writes a `reason`. The sentence is the producer's own words about a capture that
// cannot be retaken, and a migration that composed one would be putting this tool's account
// of a 2026-08-31 refusal into a field whose whole value is that it was written by whatever
// observed it. A row with no reason is REPORTED and left alone, so the gap is visible rather
// than papered over.
//
// It never touches a traced row, and it re-runs clean: a row that already carries a member
// is left exactly as it is.

import { readFileSync, writeFileSync, renameSync } from 'node:fs';

import { reasonForRuntimeClass, isRefusalReason, isUntracedOutcome,
         refusalCounts, auditRefusals } from './lib/refusal.mjs';

const args = process.argv.slice(2);
const check = args.includes('--check');
const paths = args.filter((a) => !a.startsWith('--'));

if (paths.length === 0) {
  console.error('usage: migrate-refusal-reasons.mjs [--check] <snapshot.json…>');
  process.exit(2);
}

/** The legacy outcome → member map, for the three that are exact. `refused` is absent on
 *  purpose: its member comes from the runtime class the row recorded, not from its outcome. */
const FROM_OUTCOME = {
  'not-first-in-block': 'not-first-in-block',
  pruned: 'body-unavailable',
  'not-attempted': 'not-attempted',
};

let anyProblem = false;

for (const path of paths) {
  const snap = JSON.parse(readFileSync(path, 'utf8'));
  const rows = snap.transactions ?? [];
  let added = 0;
  let already = 0;
  const noReason = [];

  for (const t of rows) {
    if (!isUntracedOutcome(t.outcome)) continue;
    if (isRefusalReason(t.refusalReason)) { already++; continue; }
    const id = t.outcome === 'refused'
      ? reasonForRuntimeClass(t.refusal)
      : FROM_OUTCOME[t.outcome];
    if (!id) {
      // Unreachable while `UNTRACED_OUTCOMES` and `FROM_OUTCOME` agree, and checked because
      // this tool's whole job is to leave nothing unclassified.
      console.error(`${path}: ${t.txHash} has untraced outcome ${JSON.stringify(t.outcome)} `
        + `with no migration rule. Add one here deliberately.`);
      anyProblem = true;
      continue;
    }
    t.refusalReason = id;
    added++;
    if (typeof t.reason !== 'string' || t.reason.trim().length === 0) noReason.push(t.txHash);
  }

  const counts = refusalCounts(rows);
  const audit = auditRefusals(rows);
  const byReason = Object.entries(counts.byReason)
    .filter(([, n]) => n > 0).map(([k, n]) => `${k}=${n}`).join(' ');
  console.log(`${path}\n  ${rows.length} transaction(s): ${audit.traced} traced, `
    + `${audit.untraced} untraced\n  +${added} classified, ${already} already classified\n`
    + `  ${byReason || '(no refusals)'}`);

  if (noReason.length) {
    // Reported, never filled in. See the header: the sentence belongs to whatever observed
    // the refusal, and a capture cannot be retaken.
    anyProblem = true;
    console.error(`  ${noReason.length} row(s) carry a member and NO stated reason — the `
      + `sentence is the producer's and this tool will not compose one:\n    `
      + noReason.slice(0, 10).join('\n    '));
  }
  if (audit.problems.length) {
    anyProblem = true;
    console.error(`  ${audit.problems.length} row(s) still fail the closed-set audit:\n    `
      + audit.problems.slice(0, 10).join('\n    '));
  }

  if (!check && added > 0) {
    // INDENT 1, which is what `follow-chain.mjs`'s `saveSnapshot` and
    // `backfill-blocks.mjs` both write. These files are forty thousand lines; re-indenting
    // one would land a whole-file diff in which the rows that actually changed cannot be
    // found, and a reviewer's only way to check that a frozen capture survived a migration
    // is to read the diff.
    const tmp = `${path}.tmp`;
    writeFileSync(tmp, JSON.stringify(snap, null, 1) + '\n');
    renameSync(tmp, path);
    console.log(`  written`);
  }
}

process.exit(anyProblem ? 1 : 0);
