// refusal.mjs — THE CLOSED SET of reasons this pipeline may give for not tracing a
// transaction, and the only place a transaction is allowed to be declined.
//
// Chain-Ingestion ING-3: "Every transaction the pipeline does not trace carries a reason
// from a closed set, and that reason reaches the page. An unexplained absence is a defect,
// not an outcome."
//
// ── WHY A REGISTRY AND NOT A STRING ────────────────────────────────────────────────────
//
// Before this module the pipeline had FOUR producers of untraced rows — `lib/replay.mjs`'s
// `decideOutcome`, `follow-chain.mjs`'s backfill arm, `backfill-blocks.mjs` and
// `capture-chain.mjs` — and each wrote its own `outcome` string and its own prose beside
// it. Between them they spelled six values (`refused`, `pruned`, `not-first-in-block`,
// `not-attempted`, plus the two traced ones), no two producers agreed on the whole list,
// and `follow-chain.mjs`'s `recount` counted FOUR of them. A transaction recorded
// `not-first-in-block` was therefore in the snapshot, carried a sentence, and appeared in
// NO count at all: `counts.replayed + divergent + refused + pruned` did not equal
// `counts.transactions`, and nothing anywhere noticed. That is the exact shape of an
// unexplained absence — not a missing sentence, a missing MEASUREMENT.
//
// So the reasons are a registry, closed the way `backfill-bodies.mjs`'s five store outcomes
// are closed, and every producer goes through `classifyRefusal`. A condition this file does
// not know is a THROW — `UnknownRefusalCondition` — and never a default. That is the whole
// point: a new condition has to be added here, deliberately, by someone who has to write
// down what produces it.
//
// ── THE TENSION THIS FILE HAS TO HOLD, STATED RATHER THAN HIDDEN ───────────────────────
//
// The replay runtime defines error classes by the DOZEN and gains more — 84 counted in an
// `aztec-avm-runtime` checkout at 86c36ad on 2026-09-09, and `lib/replay.mjs` records 92 at
// a revision it measured; the exact figure is somebody else's and moves. `lib/replay.mjs`
// stopped trying to enumerate them for exactly that reason and now recognises a refusal
// name BY SHAPE. Those names are not this set and must not become it — a set that grows
// whenever somebody else's tree grows is not closed.
//
// The two axes are therefore separate, and both travel:
//
//   refusalReason   OURS. A member of `REFUSAL_REASONS`, seven of them, closed here.
//   refusal         THEIRS. The runtime's own error class name, kept as EVIDENCE.
//
// Four of the seven are reached by a runtime class the runtime raises by name, and the
// mapping is in `REASON_FOR_RUNTIME_CLASS` below — each entry verified against the class
// as the runtime actually declares it, not guessed from its spelling. A class not in that
// table reaches `runtime-refused`, which is a MEMBER with a stated condition and its own
// count, carrying the class name that produced it. It is not a fallback for an unknown
// reason; it is the reason "the runtime declined by name, and the name is not one this
// registry classifies further". A reader can always tell which class it was.
//
// What is NOT permitted, and what `auditRefusals` exists to catch, is an untraced row with
// no `refusalReason`, or one carrying a value that is not a member.
//
// ── WHY THE MEMBERS ARE IN A JSON FILE AND NOT IN THIS ONE ─────────────────────────────
//
// Two languages have to agree about this set. THIS side produces the rows; `ingest.nim`
// publishes them and `validator.nim` refuses a tree that carries a reason it does not know.
// A set that is closed in JavaScript and open in Nim is not closed — it is one copy-paste
// away from the exact defect this module was written for. So the members live in
// `../refusal-reasons.json`, this module reads them at import and
// `src/blocktracer/chain/refusal_reasons.nim` reads the same bytes with `staticRead` at
// COMPILE time. A member added there is a member in both, and a member removed there fails
// the Nim build rather than leaving a stale id the validator would still wave through.
//
// The tables below — which producer conditions map to which member, and which runtime error
// classes resolve past `runtime-refused` — stay HERE, because the publisher side never sees
// a condition or a runtime class. It only ever sees a finished reason id.
//
// ── `absent` IS NOT IN THIS SET, AND THAT IS LOAD-BEARING ──────────────────────────────
//
// Trace-Artifacts.md §6 defines `ready`, `onDemand`, `unsupported`, `absent` and
// `divergent`. `absent` means THE CHAIN NEVER PUBLISHED THE EXECUTION — the Aztec private
// half — and it is a statement about the chain, not about us. Every member of this set is a
// statement about US: we could have traced it and did not, and here is what stopped us.
// Folding the two together would let "this execution was never public" and "our runtime
// declined this execution" render as one sentence, which is the confident lie in miniature.
// `REFUSAL_REASONS` therefore may never gain a member named `absent`, and
// `assertAbsentIsNotARefusal` asserts it.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

/** The file both languages read. Named once so a test can assert the Nim side reads THIS
 *  path and not a copy — grep `REFUSAL_REASONS_PATH`. */
export const REFUSAL_REASONS_PATH =
  join(dirname(dirname(fileURLToPath(import.meta.url))), 'refusal-reasons.json');

/** Thrown when a producer names a condition this registry does not know.
 *
 *  A pipeline failure, deliberately, and not a recorded row. `Error` subclass rather than a
 *  string so a caller can tell it apart from a chain fault, and `condition` is a field so a
 *  test can assert the pipeline NAMED the thing it did not recognise rather than merely
 *  dying near it. */
export class UnknownRefusalCondition extends Error {
  constructor(condition, where) {
    super(
      `refusal condition ${JSON.stringify(condition)} is not in the closed set defined by `
      + `tools/chain/lib/refusal.mjs. The known conditions are: `
      + `${Object.keys(CONDITIONS).sort().join(', ')}. This is a PIPELINE FAILURE and not a `
      + `row: a transaction may only be declined for a reason someone has written down. If `
      + `this condition is real, add it to REFUSAL_REASONS with the condition that produces `
      + `it — do not widen a neighbour to swallow it.`
      + (where ? ` (raised by ${where})` : ''));
    this.name = 'UnknownRefusalCondition';
    this.condition = condition;
    this.where = where ?? '';
  }
}

/** Thrown when a snapshot holds an untraced transaction with no reason, or with one that is
 *  not a member. The other half of "the set is closed": `classifyRefusal` guards the
 *  producers, this guards the FILE, so a row hand-edited or written by a tool that predates
 *  this module cannot be published unexplained. */
export class UnexplainedAbsence extends Error {
  constructor(problems) {
    super(`${problems.length} transaction(s) are untraced without a reason from the closed `
      + `set. An unexplained absence is a defect, not an outcome:\n  `
      + problems.slice(0, 20).join('\n  ')
      + (problems.length > 20 ? `\n  … and ${problems.length - 20} more` : ''));
    this.name = 'UnexplainedAbsence';
    this.problems = problems;
  }
}

// ── the closed set ─────────────────────────────────────────────────────────────────────
//
// Each member states the CONDITION that produces it, which is the thing that makes the set
// reviewable: a reader can ask "is that condition real, and is it distinct from its
// neighbours" without reading any producer.
//
// `durability` is not decoration. `tools/capture/expectations.mjs` grades a transaction page
// on whether its durability claim is supported by the cause it printed — "a permanent answer
// rather than a failed fetch" is true of a pruned body and false of a runtime refusal, and
// asserting the strong sentence under the repairable cause is a named defect there. So the
// claim is a property of the REASON, decided once, rather than prose a page writes.
//
//   permanent    nothing anyone does to this pipeline will produce a trace for this
//                transaction. The limitation is the chain's or the protocol's.
//   repairable   a better runtime, a mirrored corpus or a longer budget would trace it.
//                The page must not claim permanence for these.

/** The registry, read from the one file both languages read.
 *
 *  `readFileSync` at import rather than a JSON import assertion: the assertion syntax is
 *  still gated behind a flag on some of the Node versions this repository is run under, and
 *  a module that fails to LOAD would take the whole pipeline down for a reason unrelated to
 *  anything it decides. */
const registry = JSON.parse(readFileSync(REFUSAL_REASONS_PATH, 'utf8'));

if (registry.format !== 'blocktracer/refusal-reasons@1') {
  throw new Error(
    `${REFUSAL_REASONS_PATH} declares format ${JSON.stringify(registry.format)}, and this `
    + `module only knows blocktracer/refusal-reasons@1. Refusing to read a set it may not `
    + `understand — a half-read closed set is an open one.`);
}

/** @type {Readonly<Record<string, Readonly<{id: string, condition: string, durability: string, statedBy: string}>>>} */
export const REFUSAL_REASONS = Object.freeze(Object.fromEntries(
  registry.reasons.map((r) => {
    for (const k of ['id', 'condition', 'durability', 'statedBy']) {
      if (typeof r?.[k] !== 'string' || r[k].trim().length === 0) {
        throw new Error(`${REFUSAL_REASONS_PATH}: reason ${JSON.stringify(r?.id ?? r)} has no `
          + `${k}. Every member states the condition that produces it; that is what makes the `
          + `set reviewable rather than merely finite.`);
      }
    }
    if (r.durability !== 'permanent' && r.durability !== 'repairable') {
      throw new Error(`${REFUSAL_REASONS_PATH}: reason ${r.id} has durability `
        + `${JSON.stringify(r.durability)}, which is neither permanent nor repairable. A page `
        + `grades its own durability claim against this field.`);
    }
    return [r.id, Object.freeze({ ...r })];
  })));

/** The member ids, in a stable order. Counts are published in this order so a diff of two
 *  snapshots lines up. */
export const REFUSAL_REASON_IDS = Object.freeze(Object.keys(REFUSAL_REASONS));

export const isRefusalReason = (id) =>
  typeof id === 'string' && Object.prototype.hasOwnProperty.call(REFUSAL_REASONS, id);

/** `absent` is a statement about the CHAIN and may never become a member — see the header.
 *  Asserted rather than commented so the prose cannot go stale against the table. */
export function assertAbsentIsNotARefusal() {
  if (isRefusalReason('absent')) {
    throw new Error(
      'REFUSAL_REASONS has gained a member named `absent`. Trace-Artifacts.md §6 reserves '
      + '`absent` for an execution the chain never published — the Aztec private half — which '
      + 'is a statement about the chain and not about this pipeline. A refusal is "we declined, '
      + 'and here is why". They must not render as one sentence.');
  }
}

// ── conditions → reasons ───────────────────────────────────────────────────────────────
//
// A CONDITION is what a producer observed; a REASON is what the row says. They are mostly
// one to one, and the indirection earns itself in the one place they are not:
// `runtime-named-refusal` is a single condition whose reason depends on WHICH class the
// runtime named. Keeping the producer's vocabulary separate also means a producer names what
// it saw ("the node did not serve the body") rather than choosing a published reason, which
// is the decision this module exists to centralise.

/** Every condition a producer in this repository may report. Nothing else may be classified. */
const CONDITIONS = Object.freeze({
  'transaction-index-is-not-zero': 'not-first-in-block',
  'node-no-longer-serves-body': 'body-unavailable',
  'driver-wrote-no-container': 'no-container-written',
  'beyond-this-run-budget': 'not-attempted',
  // ── THREE CONDITIONS, ONE REASON, AND THAT IS THE POINT OF THE INDIRECTION ──────────
  //
  // A CONDITION is what a producer observed; a REASON is what the row says. These three
  // are different observations that make the same statement — the run stopped, the chain
  // did not — so they must NOT be one condition with a vague name, and they must not be
  // three reasons either. `not-attempted` already existed for the first; the other two
  // arrived with historic replay (`ingest-range.mjs --replay`).
  //
  // `historic-range-not-replayed` is the one that corrects a claim this repository used to
  // publish. Before the body proxy existed, a historic first-in-block transaction was
  // written `pruned` / `body-unavailable`, whose sentence ends "it can no longer be
  // re-executed" — and that was measured false: the keyless TxFileStore serves the body for
  // the entire chain (21 of 21 sampled from block 10 to block 75,969, all self-verified).
  // A range ingested without `--replay` has not met an obstacle; it has not looked.
  //
  // `endpoint-throttled-this-run` is the one that must never be allowed to become
  // `runtime-refused`. A rate limit is a fact about our client's quota. Filing it against
  // the transaction would put a repairable-but-real-sounding refusal on a row that a later
  // run would have traced without trouble, on data nobody would think to re-ask about.
  'historic-range-not-replayed': 'not-attempted',
  'endpoint-throttled-this-run': 'not-attempted',
  // Resolved through REASON_FOR_RUNTIME_CLASS by the class the runtime named.
  'runtime-named-refusal': null,
});

/** The runtime error classes this registry classifies FURTHER than `runtime-refused`.
 *
 *  Every entry was read off the class as `aztec-avm-runtime` declares it — the file and the
 *  `kind` discriminator are named in each reason's `statedBy` — rather than inferred from the
 *  spelling. `lib/replay.mjs` records at length what a guessed list of error-name SUFFIXES
 *  cost when it was used to decide whether a name was a name at all: forty-nine of the
 *  runtime's classes fell through it and two mainnet transactions were filed as
 *  `refusal: "unknown"` before both bodies pruned. This table is a different shape of thing —
 *  it never decides WHETHER something is a refusal, only whether a refusal already recognised
 *  is one of the four the milestone names — so a class missing from it loses a distinction,
 *  not a transaction. That is why it is allowed to exist and the suffix list was not. */
const REASON_FOR_RUNTIME_CLASS = Object.freeze({
  IntraBlockPredecessorsUnavailable: 'not-first-in-block',
  SettledTransactionNotFound: 'body-unavailable',
  MissingContractArtifact: 'artifact-unresolvable',
  SettlingBlockUnavailable: 'prestate-unavailable',
});

/** Which reason a runtime error class produces. Never throws: an unrecognised class is
 *  `runtime-refused`, a member, and the class name is what the row carries as evidence. */
export function reasonForRuntimeClass(className) {
  return REASON_FOR_RUNTIME_CLASS[className] ?? 'runtime-refused';
}

/**
 * Decide the published reason for one declined transaction.
 *
 * THE ONLY WAY A ROW MAY BECOME UNTRACED. Producers pass what they OBSERVED; this returns
 * what the row says. A condition outside `CONDITIONS` throws `UnknownRefusalCondition` — it
 * does not return a generic reason, and it does not return an empty one.
 *
 * @param {object}  o
 * @param {string}  o.condition     a key of `CONDITIONS`
 * @param {string} [o.runtimeClass] the runtime's error class, for `runtime-named-refusal`
 * @param {string} [o.narrative]    the producer's sentence for THIS transaction, with its
 *                                  block and index in it. The registry's `condition` is
 *                                  general; this is specific, and the page wants both.
 * @param {string} [o.where]        the producer, for the failure message
 * @returns {{refusalReason: string, reason: string, durability: string}}
 */
export function classifyRefusal({ condition, runtimeClass, narrative, where } = {}) {
  if (!Object.prototype.hasOwnProperty.call(CONDITIONS, condition)) {
    throw new UnknownRefusalCondition(condition, where);
  }
  const id = CONDITIONS[condition] ?? reasonForRuntimeClass(runtimeClass);
  const member = REFUSAL_REASONS[id];
  if (!member) {
    // Unreachable unless CONDITIONS or REASON_FOR_RUNTIME_CLASS names a reason the table
    // does not define. Checked anyway: this module's entire claim is that a reason outside
    // the set is a failure, and the claim has to hold against its own tables too.
    throw new UnknownRefusalCondition(
      `${condition} → ${id} (which is not a member)`, where);
  }
  return {
    refusalReason: id,
    reason: narrative && narrative.length > 0 ? narrative : member.condition,
  };
}

/** How durable this refusal is: `permanent` or `repairable`, or `''` for a non-member.
 *
 *  DERIVED, NEVER STORED. `classifyRefusal` used to return it and every producer spread it
 *  into the row, which would have put a second copy of the registry's own answer on 929
 *  committed rows — a field that can disagree with the table it came from, on data nobody
 *  can recapture. It is a property of the MEMBER, so it is looked up from the member. */
export function refusalDurability(id) {
  return REFUSAL_REASONS[id]?.durability ?? '';
}

// ── the two sentences every producer needs, written once ───────────────────────────────
//
// `follow-chain.mjs`, `backfill-blocks.mjs` and `capture-chain.mjs` each carried their own
// copy of these two paragraphs, and `backfill-blocks.mjs`'s comment already admitted why
// that was wrong: "a second wording of them would be a second thing to keep true". They
// had in fact already drifted — the pruned sentence read "when this follower first saw it"
// in one and "when this record was repaired" in another and named the finalized block in a
// third. The clause that VARIES is passed in; the claim does not.

/** The transaction is not first in its block. `blockNumber` and `txIndexInBlock` are the
 *  transaction's own, so the sentence is about THIS transaction rather than the class. */
export function refuseNotFirstInBlock({ blockNumber, txIndexInBlock, where }) {
  return {
    outcome: 'not-first-in-block',
    ...classifyRefusal({
      condition: 'transaction-index-is-not-zero',
      where,
      narrative:
        `Replaying this transaction needs the state left by the ${txIndexInBlock} `
        + `transaction(s) before it in block ${blockNumber}, and the node does not serve `
        + `intra-block intermediate state — it exists only inside the sequencer that built `
        + `the block. Only the first transaction in a block can be re-executed from `
        + `published data, so no trace was recorded for this one.`,
    }),
  };
}

/** The node serves the effects and no longer serves the body.
 *
 *  `observedAs` is the ONE clause that legitimately differs between producers: a follower
 *  says it was already below the window when it first looked, a backfill says it was below
 *  the window when the record was repaired, and a one-shot scan can name the finalized tip
 *  it measured. The claim about the chain is identical in all three and is written here. */
export function refuseBodyUnavailable({ blockNumber, observedAs, where }) {
  return {
    outcome: 'pruned',
    ...classifyRefusal({
      condition: 'node-no-longer-serves-body',
      where,
      narrative:
        `The node still serves this transaction's effects but no longer serves its body: `
        + `getTxByHash prunes at the finalized tip and getTxEffect does not. It settled in `
        + `block ${blockNumber} and ${observedAs}, so it can no longer be re-executed and no `
        + `trace was recorded for it.`,
    }),
  };
}

// ── outcomes ───────────────────────────────────────────────────────────────────────────
//
// The `outcome` field predates this module and four producers write it, so it is closed here
// rather than replaced: replacing it would rewrite `ingest.nim`'s parser and every committed
// fixture in one change, and the milestone is about the reason reaching the page, not about
// renaming the field it travels beside.

/** A transaction with a recording. `divergent` is one: it did not reproduce the block, but a
 *  divergent recording is real, it steps, and Trace-Artifacts.md §6 gives it its own status.
 *  It is NOT a refusal. */
export const TRACED_OUTCOMES = Object.freeze(['replayed', 'divergent']);

/** A transaction the chain published and this pipeline did not trace. Every one of these
 *  must carry a `refusalReason`. */
export const UNTRACED_OUTCOMES = Object.freeze([
  'refused', 'pruned', 'not-first-in-block', 'not-attempted',
]);

export const OUTCOMES = Object.freeze([...TRACED_OUTCOMES, ...UNTRACED_OUTCOMES]);

export const isUntracedOutcome = (o) => UNTRACED_OUTCOMES.includes(o);

// ── the measurement ────────────────────────────────────────────────────────────────────

/**
 * Per-reason refusal counts, ZERO-FILLED over the whole set.
 *
 * THE ZERO FILL IS THE FEATURE. The milestone's deliverable is that "a reason whose count
 * moves from zero is visible without anyone looking for it", and an ABSENT key is not a
 * zero — it is silence, and it reads as "this reason does not exist here" rather than "this
 * reason exists and did not fire". Publishing every member on every snapshot means the first
 * `not-first-in-block: 1` on Aztec mainnet is a diff against a line that was already there,
 * not a new key nobody was watching for.
 *
 * `total` is the sum, and it is published beside `counts.transactions` so the two can be
 * reconciled: `traced + total` must equal the transaction count, which is the check that
 * would have caught `not-first-in-block` falling out of `recount` entirely.
 */
export function refusalCounts(transactions) {
  const by = Object.fromEntries(REFUSAL_REASON_IDS.map((id) => [id, 0]));
  let unclassified = 0;
  for (const t of transactions ?? []) {
    if (!isUntracedOutcome(t?.outcome)) continue;
    if (isRefusalReason(t?.refusalReason)) by[t.refusalReason]++;
    else unclassified++;
  }
  const total = REFUSAL_REASON_IDS.reduce((n, id) => n + by[id], 0);
  // `unclassified` is published rather than thrown on, because a COUNT is a measurement and
  // `auditRefusals` is the gate. A reader of a snapshot must be able to see that the gate
  // has something to say; a counter that silently dropped these would be the original defect
  // in a new place.
  return { byReason: by, total, unclassified };
}

/**
 * Every way this set can be open, found in one pass over a snapshot's transactions.
 *
 * Returns findings rather than throwing so a caller can report all of them at once; the
 * throwing wrapper is `assertRefusalsAreClosed`.
 */
export function auditRefusals(transactions) {
  const problems = [];
  let traced = 0;
  let untraced = 0;
  for (const t of transactions ?? []) {
    const hash = t?.txHash ?? '(no txHash)';
    const outcome = t?.outcome;
    if (!OUTCOMES.includes(outcome)) {
      problems.push(`${hash}: outcome ${JSON.stringify(outcome ?? null)} is not one of `
        + `${OUTCOMES.join(', ')}`);
      continue;
    }
    if (TRACED_OUTCOMES.includes(outcome)) {
      traced++;
      // A traced transaction carrying a refusal reason is the two statements folded together
      // in the other direction, and it would be counted as a refusal by `refusalCounts`
      // if `isUntracedOutcome` ever widened.
      if (t?.refusalReason != null) {
        problems.push(`${hash}: outcome ${outcome} is traced and must carry no refusalReason, `
          + `but carries ${JSON.stringify(t.refusalReason)}`);
      }
      continue;
    }
    untraced++;
    if (t?.refusalReason == null) {
      problems.push(`${hash}: outcome ${outcome} is untraced and carries NO refusalReason — `
        + `an unexplained absence`);
    } else if (!isRefusalReason(t.refusalReason)) {
      problems.push(`${hash}: refusalReason ${JSON.stringify(t.refusalReason)} is outside the `
        + `closed set (${REFUSAL_REASON_IDS.join(', ')})`);
    } else if (typeof t?.reason !== 'string' || t.reason.trim().length === 0) {
      // §14 requires every one of these rows to state why. A member id is a machine's word;
      // the page shows a sentence, and a blank one is the failure mode that turns a specific
      // refusal into a generic error.
      problems.push(`${hash}: refusalReason ${t.refusalReason} carries no stated reason`);
    }
  }
  return { traced, untraced, problems };
}

/** The gate. Throws `UnexplainedAbsence` naming every offending transaction. */
export function assertRefusalsAreClosed(transactions) {
  const audit = auditRefusals(transactions);
  if (audit.problems.length) throw new UnexplainedAbsence(audit.problems);
  return audit;
}
