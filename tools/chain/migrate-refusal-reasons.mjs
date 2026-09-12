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
// ── AND ONE ROW IS NOT A REFUSAL AT ALL ────────────────────────────────────────────────
//
// SEVEN committed rows carry `refusalReason: runtime-refused` and are `private-only`
// transactions — no public execution, nothing to re-run, and nothing this pipeline
// declined. Five are in `client/fixtures/chain/aztec` and two in
// `client/fixtures/chain/aztec-testnet-frames`. `runtime-refused` is durability
// **repairable**, and `tools/capture/expectations.mjs` grades a page on whether its
// durability claim is supported by the cause it printed, so every one of those rows told a
// reader that a better runtime would trace it.
//
// They are identifiable WITHOUT RE-CAPTURE, which is what makes this a migration rather
// than a lost measurement: the discriminator is in the committed `detail`. Before
// `private-only` existed the driver crashed on these — upstream's
// `getPublicCallRequestsWithCalldata()` reads `data.forPublic.nonRevertibleAccumulatedData`
// and `forPublic` is `undefined` — so the row records `refusal: "TypeError"` with that
// property named in the message. `looksLikePrivateOnlyCrash` is the signature, and it lives
// in `lib/refusal.mjs` so the producer side, this tool and the selftest share one spelling.
//
// `refusal` AND `detail` ARE KEPT ON THOSE ROWS, deliberately. They are the evidence for
// the reclassification, on captures that cannot be retaken, and a reader asking "how do you
// know this was private-only" should get the answer from the row rather than from this
// comment. No consumer miscounts them: every reader of the bare `refusal` field is guarded
// by `outcome === 'refused'`. What is dropped is the `refusalReason` — the closed set is a
// set of things WE did, and this is not one of them.
//
// ── WHAT IT WILL NOT DO ────────────────────────────────────────────────────────────────
//
// It never writes a `reason` FOR A REFUSAL. The sentence is the producer's own words about a
// capture that cannot be retaken, and a migration that composed one would be putting this
// tool's account of a 2026-08-31 refusal into a field whose whole value is that it was
// written by whatever observed it. A row with no reason is REPORTED and left alone, so the
// gap is visible rather than papered over.
//
// The private-only reclassification is the one exception, and it is an exception to the
// SUBJECT rather than to the rule. The sentence those rows carry — "the replay runtime
// refused with TypeError" — is not an observation whose value is that somebody wrote it; it
// is a statement this pipeline now knows to be false, and leaving it beside a corrected
// outcome would publish the contradiction. What replaces it is
// `chainPublishedNoPublicExecution`, the same shared sentence a fresh capture writes, so a
// migrated row and a newly captured one say the same thing — which is the property this
// file's header claims for the `refused` → member mapping, held to here as well.
//
// It never touches a traced row, and it re-runs clean: a row that already carries a member
// is left exactly as it is.
//
// ── AND IT RECOUNTS, WHICH IT DID NOT ──────────────────────────────────────────────────
//
// This tool rewrote all three committed snapshots and left `counts` exactly as it found it.
// `client/fixtures/chain/aztec-testnet/snapshot.json` therefore shipped `counts.pruned: 25`
// against 835 actual pruned rows, and its four outcome lines summed to 51 against
// `counts.transactions: 866`. Data-Contract.md §5.2 says `counts` exists "so a partial
// ingest is detectable", so a stale `counts` is not cosmetic — it is the detector reading
// clean on the thing it detects, and it is the exact defect ING-3 was written to eliminate,
// surviving in committed data because the tool that touched the rows never touched the
// tally. The recount is the SHARED one, `lib/recount.mjs`, rather than a fourth spelling.
//
// ── AND IT IS THE `@1` → `@2` MIGRATION ────────────────────────────────────────────────
//
// `blocktracer/chain-snapshot@2` requires `refusalReason` on every untraced row. That is
// precisely the requirement this file exists to satisfy, so this tool IS the migration and
// it stamps the token — but only after `auditRefusals` reports the file clean. A tool that
// relabelled rows it had just reported as failing would be manufacturing the claim the token
// makes instead of earning it, which is the defect being repaired one level up. A file with
// outstanding problems keeps its old token and says so.
//
// So the migration story is one command:
//
//   node tools/chain/migrate-refusal-reasons.mjs <snapshot.json…>
//
// and it is total rather than best-effort: every `@1` untraced row's member is derivable
// from data the row already carries — its `outcome` for three of the four legacy values, and
// its recorded runtime `refusal` class for the fourth. Nothing is guessed and nothing needs
// re-capture, which matters because these captures cannot be retaken.

import { readFileSync, writeFileSync, renameSync } from 'node:fs';

import { reasonForRuntimeClass, isRefusalReason, isUntracedOutcome,
         looksLikePrivateOnlyCrash, chainPublishedNoPublicExecution,
         refusalCounts, auditRefusals } from './lib/refusal.mjs';
import { recountSnapshot, countsDisagreements } from './lib/recount.mjs';
import { SNAPSHOT_FORMAT, assertReadableSnapshotFormat } from './lib/snapshot-format.mjs';

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
  const reclassified = [];

  for (const t of rows) {
    if (!isUntracedOutcome(t.outcome)) continue;
    // ── THE RECLASSIFICATION IS ASKED BEFORE THE `already` SHORT-CIRCUIT ─────────────
    //
    // A row that carries `runtime-refused` IS already classified, so the `already` test
    // below would leave it alone — which is exactly how seven of these shipped. The
    // question this asks is not "is there a member" but "is this a refusal at all", and a
    // wrong member is not corrected by a tool that only fills in blanks.
    if (t.outcome === 'refused' && looksLikePrivateOnlyCrash(t)) {
      // No public execution, so no reason ID: the closed set is a set of things WE did.
      // `refusal` and `detail` STAY — they are the evidence for this decision, on a
      // capture that cannot be retaken, and every reader of the bare `refusal` field is
      // guarded by `outcome === 'refused'` so nothing miscounts them as a refusal.
      delete t.refusalReason;
      Object.assign(t, chainPublishedNoPublicExecution({ blockNumber: t.blockNumber }));
      reclassified.push(t.txHash);
      continue;
    }
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

  // ── THE TALLY IS RECOMPUTED, WHICH IT WAS NOT ──────────────────────────────────────
  //
  // This tool rewrote all three committed snapshots and never touched `counts`, so a file
  // whose rows it had just changed kept a tally describing the rows it used to have. The
  // recount is the SHARED one (`lib/recount.mjs`) rather than a fourth spelling, and the
  // disagreements it repairs are PRINTED — a migration that silently corrected a published
  // number would be unreviewable, and the gap is the interesting part of the diff.
  const countsWere = countsDisagreements(snap);
  recountSnapshot(snap);
  const counts = refusalCounts(rows);
  const audit = auditRefusals(rows);
  const byReason = Object.entries(counts.byReason)
    .filter(([, n]) => n > 0).map(([k, n]) => `${k}=${n}`).join(' ');
  console.log(`${path}\n  ${rows.length} transaction(s): ${audit.traced} traced, `
    + `${audit.untraced} untraced, ${audit.chainAbsent} chain-absent\n`
    + `  +${added} classified, ${already} already classified, `
    + `${reclassified.length} reclassified private-only\n`
    + `  ${byReason || '(no refusals)'}`);
  if (reclassified.length) {
    console.log(`  private-only, from a driver TypeError on \`forPublic\`:\n    `
      + reclassified.join('\n    '));
  }
  if (countsWere.length) {
    console.log(`  counts: ${countsWere.length} member(s) disagreed with the rows and are `
      + `now derived from them:\n    `
      + countsWere.map((d) => `${d.member}: ${JSON.stringify(d.declared)} -> ${d.actual}`)
          .join('\n    '));
  }

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

  // ── AND THE TOKEN, WHICH IS WHAT THIS TOOL HAS ALWAYS ACTUALLY MIGRATED ─────────────
  //
  // `@2` requires `refusalReason` on every untraced row. That is exactly the requirement
  // this file exists to satisfy, so THIS is the `@1` → `@2` migration and stamping the
  // token here is the migration being expressible rather than a separate manual step.
  //
  // STAMPED ONLY AFTER THE AUDIT IS CLEAN. A token is a claim about the tree, and a tool
  // that relabelled rows it had just reported as failing would be manufacturing the claim
  // rather than earning it — which is the whole defect being repaired, one level up. So a
  // file with outstanding problems keeps its old token and is reported, and re-running the
  // tool after the rows are fixed promotes it.
  //
  // `assertReadableSnapshotFormat` first: a token this tree cannot read is refused by name
  // rather than overwritten (Data-Contract.md §3, §5.2). Overwriting it would be the one
  // thing §3 forbids outright — reading a schema you do not know and calling the result
  // yours.
  assertReadableSnapshotFormat(snap.format, path);
  let promoted = '';
  if (audit.problems.length === 0 && noReason.length === 0
      && snap.format !== SNAPSHOT_FORMAT) {
    promoted = `${snap.format} -> ${SNAPSHOT_FORMAT}`;
    snap.format = SNAPSHOT_FORMAT;
    console.log(`  format: ${promoted} — every untraced row now carries a member, which is `
      + `what ${SNAPSHOT_FORMAT} requires`);
  } else if (snap.format !== SNAPSHOT_FORMAT) {
    console.error(`  format: LEFT AT ${snap.format}. ${SNAPSHOT_FORMAT} requires a member on `
      + `every untraced row and this file does not yet meet that, so the token is not `
      + `stamped over it. Fix the rows above and re-run.`);
  }

  // A RECLASSIFICATION OR A STALE TALLY IS A REASON TO WRITE, not only a new member. The
  // condition was `added > 0`, so a file whose only defect was a wrong member or a count
  // that no longer described its rows was reported and left on disk.
  if (!check && (added > 0 || reclassified.length > 0 || countsWere.length > 0
                 || promoted.length > 0)) {
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
