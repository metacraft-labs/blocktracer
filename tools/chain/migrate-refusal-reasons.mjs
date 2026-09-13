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
// TWO — not three — of the four legacy outcomes carry their member in the name:
//
//   not-first-in-block  →  not-first-in-block
//   not-attempted       →  not-attempted
//
// The other two are decided from evidence the row carries rather than from its name.
//
// `refused` is every runtime throw, and its member is decided by the runtime error class
// the row already recorded in `refusal` — the same table `reasonForRuntimeClass` uses for a
// live capture, so a migrated row and a freshly captured one classify identically.
//
// `pruned` USED TO BE IN THE FIRST LIST, AND IT DOES NOT BELONG THERE. It was mapped
// straight to `body-unavailable` by a frozen literal, under this file's own claim that the
// mapping was "exact". It is not exact, and it is not even the same KIND of statement:
// `pruned` names what the NODE answered, and `body-unavailable`'s condition is "the node no
// longer serves the transaction's body AND THE FILE STORE CANNOT SUPPLY IT EITHER" at
// durability **permanent**. The map established the first clause and asserted the second.
//
// It was asserted 912 times — 835 rows in `client/fixtures/chain/aztec-testnet` and 77 in
// `client/fixtures/chain/aztec`, every one `firstInBlock: true`, `bodyRetained: 0`, in
// blocks 63,520–67,007 and 66,749–70,151. The second clause was never checked for any of
// them, and it was later measured FALSE across exactly that range: the keyless TxFileStore
// answered 200 and self-verified for 21 of 21 bodies sampled between block 10 and block
// 75,969, and for 12 of 12 sampled from the frozen mainnet capture — six of which that
// capture had itself recorded as `pruned` (CHAIN-CAPTURE.md §1.2, §6).
//
// So the arm is now `memberForLegacyUntracedRow` in `lib/refusal.mjs`, which asks the row
// whether the store was ever asked: a `pruned` row carrying the store's negative answer
// (`storeOutcome` of `absent`, `truncated` or `mismatched`) earned `body-unavailable`, and
// a `pruned` row carrying none is a row nobody asked — `not-attempted`, the member whose
// whole content is "the run did not look". The decision lives in the shared module for the
// reason `looksLikePrivateOnlyCrash` does: the selftest has to be able to assert it without
// running this script.
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
// THERE ARE TWO EXCEPTIONS AND BOTH ARE EXCEPTIONS TO THE SUBJECT RATHER THAN THE RULE: the
// sentence being replaced is not an observation whose value is that somebody wrote it, it
// is a statement this pipeline now knows to be FALSE, and leaving it beside a corrected
// member would publish the contradiction.
//
//   private-only  — "the replay runtime refused with TypeError", about a transaction with
//                   no public execution. Replaced by `chainPublishedNoPublicExecution`.
//   pruned with no store evidence — "…so it can no longer be re-executed". That clause is
//                   measured false for the range these rows sit in. Replaced by
//                   `refuseBodyNotSoughtFromStore`.
//
// In both cases the replacement is the SHARED sentence a fresh capture writes, so a
// migrated row and a newly captured one say the same thing — the property this file's
// header claims for the `refused` → member mapping, held to here as well.
//
// AND THE OBSERVATION INSIDE THE OLD SENTENCE IS CARRIED ACROSS VERBATIM. The false part of
// those 912 sentences is the conclusion; the clause before it — which finalized tip was
// measured, or that the row was already below the window when the follower first saw it —
// is a real measurement taken at a moment that cannot be revisited. It is extracted from
// the committed text and re-used as the new sentence's `observedAs`, and every row for
// which the extraction FAILS is counted and printed rather than quietly given a generic
// clause. A migration that dropped the measurement would be paying for a corrected claim
// with a lost one.
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
import { relative, resolve, sep } from 'node:path';

import { isRefusalReason, isUntracedOutcome, memberForLegacyUntracedRow,
         looksLikePrivateOnlyCrash, chainPublishedNoPublicExecution,
         storeWasAskedAndSaidNoBody, refuseBodyNotSoughtFromStore,
         refusalCounts, auditRefusals } from './lib/refusal.mjs';
import { recountSnapshot, countsDisagreements } from './lib/recount.mjs';
import { SNAPSHOT_FORMAT, assertReadableSnapshotFormat } from './lib/snapshot-format.mjs';

const args = process.argv.slice(2);
const check = args.includes('--check');
const migrateHeldOut = args.includes('--include-held-out');
const paths = args.filter((a) => !a.startsWith('--'));

if (paths.length === 0) {
  console.error('usage: migrate-refusal-reasons.mjs [--check] [--include-held-out] '
    + '<snapshot.json…>');
  process.exit(2);
}

const REPO_ROOT = resolve(new URL('../../', import.meta.url).pathname);

// ── THE THREE SUBJECTS THIS TOOL MUST NOT PROMOTE ──────────────────────────────────────
//
// `@1` is not only a legacy token, it is a SHAPE THE READER STILL HAS TO BE TESTED
// AGAINST — §3.1 rule 2 obliges a reader that accepts a token to consume every member it
// defines, and the only way to check that obligation is to hold an artifact in that shape
// and read it. These three are the whole supply of them.
//
// Run over the corpus with a glob, this tool would promote all three to `@2` in one
// command — it did, in a review rehearsal — leaving the reader's `@1` path with no subject
// at all and the `@1` half of "a tree may never claim one token while carrying another's
// mandatory members" vacuously true. That is a gate losing its population, which is the
// failure mode this whole campaign is about, arriving through the tool written to close it.
//
// They are named here rather than inferred from a path pattern because the intent is the
// point: each is deliberately frozen, each says so in its own `_comment`, and a new `@1`
// capture that is NOT a frozen subject should still be migrated. `--include-held-out` is
// the deliberate override, for the day the reader's `@1` support is actually retired.
const HELD_OUT_AT_V1 = Object.freeze({
  'client/fixtures/noir-frames/snapshot.json':
    'the Noir-frame fixture — the view side\'s only source-level container, and the `@1` '
    + 'subject for a snapshot with no untraced rows at all',
  'fixtures/chain-artifacts/aztec-testnet/snapshot.json':
    'the frozen artifact-resolution subject — the `@1` subject carrying untraced rows with '
    + 'NO member, which is the shape `@1` exists to permit and `@2` forbids',
  'tests/fixtures/chain-snapshots/aztec-mainnet-live/snapshot.json':
    'the live follower\'s own output, byte for byte — the `@1` subject `tests/tchainsnapshot.nim` '
    + 'reads, and the one that reproduces the `l1ChainId` KeyError',
});

/** Is this path one of the deliberately-frozen `@1` subjects? Compared repo-relative and
 *  slash-normalised so a caller's glob, absolute path or `./` prefix all reach the same
 *  answer — a hold-out list that a different spelling of the same file walks past is not a
 *  hold-out list. */
function heldOutReason(path) {
  const rel = relative(REPO_ROOT, resolve(path)).split(sep).join('/');
  return HELD_OUT_AT_V1[rel] ?? null;
}

/**
 * The MEASUREMENT out of an old `pruned` sentence, re-rendered as the clause the shared
 * producers pass, and without the conclusion the old sentence drew from it.
 *
 * ── WHAT IS BEING SAVED, AND WHY IT IS WORTH THE CODE ────────────────────────────────
 *
 * Those 912 sentences each end "it can no longer be re-executed", which is the false part.
 * Each also carries something TRUE that will not recur: the finalized tip the capture
 * measured at the moment it looked, or that the row was already below the replayable window
 * when a particular producer first saw it. That is exactly the clause
 * `refuseBodyUnavailable` gave its three producers their own wording for — "the ONE clause
 * that legitimately differs between producers" — and dropping it would pay for a corrected
 * claim with a lost measurement.
 *
 * ── THREE KNOWN SHAPES, MATCHED BY NAME, AND NOTHING ELSE ─────────────────────────────
 *
 * A single loose regex over the paragraph is not good enough and was tried: anchoring on
 * "getTxEffect does not." silently drops the capture shape's finalized tip, which lives in
 * a PARENTHETICAL earlier in the sentence, and splices a standalone sentence into a slot
 * written for a subordinate clause. So each committed shape is matched explicitly and
 * re-rendered in the producers' own words:
 *
 *   capture-chain  "…prunes at the finalized tip (block T when this snapshot was taken)…
 *                   This transaction settled in block B, D block(s) below it."
 *   follow-chain   "It was already below the replayable window when this follower first
 *                   saw it"
 *   backfill       "It was already below the replayable window when this record was
 *                   repaired"
 *
 * DELIBERATELY FALLIBLE. A shape not in this list returns `null`, the caller COUNTS it and
 * prints the count beside the stated fallback clause it used. A silent generic substitution
 * would be a migration composing the sentence a page shows, which is the one thing this
 * file's header says it will not do.
 *
 * @param {unknown} reason the committed sentence
 * @param {unknown} blockNumber the row's own settling block, for the capture shape's depth
 * @returns {string|null} a lowercase subordinate clause, no trailing punctuation
 */
function observationInsideOldPrunedSentence(reason, blockNumber) {
  if (typeof reason !== 'string') return null;
  const tip = /prunes at the finalized tip \(block (\d+) when this snapshot was taken\)/
    .exec(reason);
  if (tip) {
    const t = Number(tip[1]);
    // The depth is re-derived from the two numbers rather than read out of the prose, so a
    // sentence whose own arithmetic had drifted cannot carry the drift across.
    const depth = Number.isFinite(blockNumber) ? t - blockNumber : null;
    if (t === blockNumber) {
      return 'the finalized tip when this snapshot was taken was that same block — pruning '
           + 'takes the finalized block too';
    }
    if (depth !== null) {
      return `the finalized tip when this snapshot was taken was block ${t}, ${depth} `
           + `block(s) above it`;
    }
    return `the finalized tip when this snapshot was taken was block ${t}`;
  }
  const window =
    /[Ii]t was already below the replayable window when (this follower first saw it|this record was repaired)/
      .exec(reason);
  if (window) return `it was already below the replayable window when ${window[1]}`;
  return null;
}

let anyProblem = false;

for (const path of paths) {
  const heldOut = migrateHeldOut ? null : heldOutReason(path);
  if (heldOut) {
    console.log(`${path}\n  HELD OUT AT ${SNAPSHOT_FORMAT === 'blocktracer/chain-snapshot@2'
      ? 'blocktracer/chain-snapshot@1' : 'its current token'} — not migrated, deliberately.\n`
      + `  ${heldOut}\n`
      + `  The reader's older-token path needs a subject in that shape to be checked `
      + `against; promoting it would leave the check with an empty population. Pass `
      + `--include-held-out to override.`);
    continue;
  }

  const snap = JSON.parse(readFileSync(path, 'utf8'));
  const rows = snap.transactions ?? [];
  let added = 0;
  let already = 0;
  const noReason = [];
  const reclassified = [];
  const unsought = [];
  let clauseNotRecovered = 0;

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
    // ── AND THE SECOND CORRECTION, ALSO ASKED BEFORE THE `already` SHORT-CIRCUIT ─────
    //
    // For exactly the reason the first one is. A row carrying `body-unavailable` IS
    // classified, so the `already` test below leaves it alone — which is how 912 of them
    // shipped a durability-PERMANENT claim whose second clause nobody had checked. The
    // question is not "is there a member" but "is this member the one the row's own
    // evidence supports", and a wrong member is not corrected by a tool that only fills
    // in blanks.
    //
    // The discriminator is the same one a fresh capture uses and needs no re-capture:
    // `storeOutcome` is written onto the row by every producer that asked the file store,
    // so its ABSENCE is the record that the store was never asked. `refusal` and `detail`
    // have no bearing here and are untouched.
    if (t.outcome === 'pruned' && t.refusalReason === 'body-unavailable'
        && !storeWasAskedAndSaidNoBody(t)) {
      // The measurement inside the old sentence is carried across; only the conclusion
      // it drew is dropped. `clauseNotRecovered` counts the rows where the extraction
      // failed, so a silent generic clause is impossible.
      const observed = observationInsideOldPrunedSentence(t.reason, t.blockNumber);
      if (observed === null) clauseNotRecovered++;
      Object.assign(t, refuseBodyNotSoughtFromStore({
        blockNumber: t.blockNumber,
        observedAs: observed
          ?? 'the record does not preserve at what depth below the finalized tip that was '
             + 'observed',
        where: 'migrate-refusal-reasons.mjs',
      }));
      unsought.push(t.txHash);
      continue;
    }
    if (isRefusalReason(t.refusalReason)) { already++; continue; }
    const { member: id, why } = memberForLegacyUntracedRow(t);
    if (!id) {
      // Unreachable while `UNTRACED_OUTCOMES` and the shared classifier agree, and checked
      // because this tool's whole job is to leave nothing unclassified.
      console.error(`${path}: ${t.txHash} has untraced outcome ${JSON.stringify(t.outcome)} `
        + `with no migration rule (${why}). Add one in lib/refusal.mjs deliberately.`);
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
    + `${reclassified.length} reclassified private-only, `
    + `${unsought.length} reclassified not-attempted\n`
    + `  ${byReason || '(no refusals)'}`);
  if (reclassified.length) {
    console.log(`  private-only, from a driver TypeError on \`forPublic\`:\n    `
      + reclassified.join('\n    '));
  }
  if (unsought.length) {
    // PRINTED AS A COUNT AND A SAMPLE rather than 835 hashes: the interesting figure is
    // how many permanent claims were being made without the evidence for them, and the
    // diff carries the rows themselves.
    console.log(`  ${unsought.length} row(s) claimed \`body-unavailable\` — durability `
      + `PERMANENT — with no record of the transaction file store ever being asked. `
      + `Reclassified to \`not-attempted\`, whose narrative is that the run did not look. `
      + `First few:\n    ` + unsought.slice(0, 5).join('\n    ')
      + (unsought.length > 5 ? `\n    … and ${unsought.length - 5} more` : ''));
    console.log(`  of those, ${clauseNotRecovered} had no recoverable observation in the `
      + `old sentence and were given the stated fallback clause`
      + (clauseNotRecovered === 0 ? ' — none' : ''));
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
  if (!check && (added > 0 || reclassified.length > 0 || unsought.length > 0
                 || countsWere.length > 0 || promoted.length > 0)) {
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
