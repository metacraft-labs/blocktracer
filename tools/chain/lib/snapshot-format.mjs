// snapshot-format.mjs — the snapshot's version token, read from the one file both languages
// read (`tools/chain/snapshot-format.json`). Data-Contract.md §5.2.
//
// ── WHY A MODULE FOR ONE STRING ─────────────────────────────────────────────────────────
//
// Because it was ten strings. `blocktracer/chain-snapshot@1` was spelled at four producers
// (`follow-chain.mjs`, `capture-chain.mjs`, `ingest-range.mjs` twice), two consumers
// (`ingest.nim`'s gate, `backfill-blocks.mjs`'s refusal), one test helper and three committed
// fixtures — and the reader's gate was a bare `!=` against its own copy of the literal. A
// version gate spelled twice is two gates, and the interesting failure is not that one goes
// stale but that the tree can then claim a token whose requirements it does not meet.
//
// That is not hypothetical here. `refusalReason` became MANDATORY on every untraced row
// while the token stayed `@1`, and the evidence that this is a new format rather than an
// additive change is that `migrate-refusal-reasons.mjs` had to be written: the committed
// `@1` captures could not pass the gate their own producers now run. `@1` therefore named
// two incompatible shapes. See `snapshot-format.json` for the full statement.

import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const FORMAT_PATH = join(dirname(fileURLToPath(import.meta.url)), '..', 'snapshot-format.json');

// `readFileSync` rather than a JSON import assertion, for the reason `refusal.mjs` gives:
// the assertion syntax is still flagged on some Node versions this repository runs under,
// and a module that fails to LOAD takes the pipeline down for a reason unrelated to what it
// decides.
const spec = JSON.parse(readFileSync(FORMAT_PATH, 'utf8'));

if (spec.format !== 'blocktracer/snapshot-format@1') {
  throw new Error(
    `${FORMAT_PATH} declares format ${JSON.stringify(spec.format)}, and this module only `
    + `knows blocktracer/snapshot-format@1. Refusing to read a version policy it may not `
    + `understand — a half-read version gate is no gate.`);
}

/** The token a producer in this tree WRITES. */
export const SNAPSHOT_FORMAT = spec.current;

/** Every token this tree can read, in order. A token outside this list is refused by name
 *  and never partially read (Data-Contract.md §3, §5.2). */
export const READABLE_SNAPSHOT_FORMATS = Object.freeze([...spec.readable]);

if (!READABLE_SNAPSHOT_FORMATS.includes(SNAPSHOT_FORMAT)) {
  throw new Error(`${FORMAT_PATH}: \`current\` is ${JSON.stringify(SNAPSHOT_FORMAT)} and it `
    + `is not in \`readable\`. A tree that cannot read what it writes is not a version `
    + `policy.`);
}

export const isReadableSnapshotFormat = (t) => READABLE_SNAPSHOT_FORMATS.includes(t);

/** Does this token require `refusalReason` on every untraced row?
 *
 *  THE WHOLE CONTENT OF THE BUMP. `@1` left it optional and `@2` requires it, and the
 *  reader enforces exactly this difference — which is what makes the token a checkable
 *  statement about the tree rather than a label. A producer that writes the member must
 *  write the token that requires it; a tree carrying `@1` is read with the member optional,
 *  fully, with nothing skipped. */
export const requiresRefusalReason = (t) =>
  (spec.mandatoryMembers?.[t] ?? []).includes('transactions[].refusalReason');

/** The three populations a transaction row can be in. Single-sourced here because the
 *  mandatory-member gate above is only checkable against a definition of "untraced", and a
 *  second definition of that is a second answer. `lib/refusal.mjs` reads these. */
export const SNAPSHOT_OUTCOMES = Object.freeze({
  traced: Object.freeze([...spec.outcomes.traced]),
  untraced: Object.freeze([...spec.outcomes.untraced]),
  chainAbsent: Object.freeze([...spec.outcomes.chainAbsent]),
});

// The three lists must be DISJOINT and that is asserted rather than assumed: an outcome in
// two of them would make `accountedFor` double-count and would make "every untraced row
// carries a reason" true and false of the same row.
{
  const seen = new Set();
  for (const [group, members] of Object.entries(SNAPSHOT_OUTCOMES)) {
    for (const o of members) {
      if (seen.has(o)) {
        throw new Error(`${FORMAT_PATH}: outcome ${JSON.stringify(o)} appears in more than `
          + `one population (last seen in ${group}). The three are a partition; an overlap `
          + `makes one of the published counts a double-count.`);
      }
      seen.add(o);
    }
  }
}

/**
 * Refuse a token this tree cannot read, BY NAME.
 *
 * §3: "the site-generator and the conformance validator refuse a version they do not support
 * rather than misreading it." §5.2: the reader "refuses a token it does not know, by name,
 * rather than attempting a partial read". One implementation, so the producers' own
 * consistency checks and the reader say the same thing.
 *
 * @param {string} token the `format` member as found
 * @param {string} where the file or tool, for the message
 */
export function assertReadableSnapshotFormat(token, where) {
  if (isReadableSnapshotFormat(token)) return token;
  throw new Error(
    `${where}: unsupported chain snapshot format ${JSON.stringify(token ?? null)}; this `
    + `build reads ${READABLE_SNAPSHOT_FORMATS.join(' and ')}. Refused by name rather than `
    + `read in part — a snapshot half-read against the wrong schema publishes a chain that `
    + `never existed.`);
}
