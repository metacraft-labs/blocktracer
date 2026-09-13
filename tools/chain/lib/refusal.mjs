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

import { SNAPSHOT_OUTCOMES } from './snapshot-format.mjs';

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
  // ── THE CONDITION IS SPELLED WITH BOTH OF ITS CLAUSES IN IT, AND THAT IS THE FIX ──────
  //
  // It used to be `node-no-longer-serves-body`, which names ONE half of what
  // `body-unavailable`'s condition asserts. The member's own sentence is "the node no
  // longer serves the transaction's body AND THE FILE STORE CANNOT SUPPLY IT EITHER", and
  // a condition named after the first clause is a condition any producer that has only
  // watched the node can honestly report — so four of them did, and 912 committed rows
  // published a durability-`permanent` claim nobody had checked the second half of.
  //
  // The rename is not cosmetic. A producer still spelling the old key gets
  // `UnknownRefusalCondition` by name, which is this module's stated policy for a condition
  // it does not know, rather than a silent classification into the member it used to reach.
  // And `refuseBodyUnavailable` — the only caller — now demands the store's own answer
  // before it will use it. See `STORE_ANSWERS_MEANING_NO_BODY`.
  'node-pruned-and-store-does-not-hold-it': 'body-unavailable',
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
  // ── AND THE FOURTH, WHICH IS THE ONE 912 ROWS WERE PUBLISHED WITHOUT ─────────────────
  //
  // The producer watched the NODE prune the body — a real observation, and the only one
  // a follower or a live capture ever makes — and did not ask the keyless TxFileStore.
  // That is the run not looking, which is what `not-attempted` means, and it is NOT
  // `body-unavailable`, whose condition requires the store to have been asked and to have
  // said no.
  //
  // WHY IT IS SAFE TO SAY THE BODY IS OBTAINABLE HERE, which is the claim every
  // `not-attempted` narrative makes and the reason `body-source-unreachable` may not use
  // this member. On this chain it is MEASURED, not assumed: 21 of 21 bodies sampled from
  // block 10 to block 75,969 answered 200 and self-verified, 333 of 333 first-in-block
  // transactions over the full sample had their body served, and 12 of 12 sampled from the
  // frozen mainnet capture did — INCLUDING SIX THAT CAPTURE HAD ITSELF RECORDED AS
  // `pruned` (CHAIN-CAPTURE.md §1.2, §6). The measurement covers the committed rows rather
  // than merely neighbouring them.
  //
  // It is a stronger claim than the other three narratives make and it is stated as one:
  // the other three rest on the run's own record of what it chose not to do, and this one
  // rests on somebody else's host still holding the bytes. If that host stops holding
  // them, these rows become `body-unavailable` — but only once a run has ASKED and been
  // told no, which is the whole content of the split.
  'node-pruned-body-store-not-asked': 'not-attempted',
  // ── AND THE ONE THAT IS *NOT* `not-attempted`, WHICH IS THE POINT ────────────────────
  //
  // The BODY SOURCE could not be asked: a 5xx, a 429, a TLS failure, a transport error or
  // a timeout from the keyless transaction file store. `ingest-range.mjs replayRange`
  // routed this — together with `absent`, `mismatched` and `truncated` — into
  // `refuseBodyUnavailable`, whose member is declared durability PERMANENT. So one
  // outage on somebody else's host published "this transaction can never be
  // re-executed" onto rows whose bodies the store holds and serves.
  //
  // AND IT IS NOT `not-attempted` EITHER, which is the less obvious half. Every
  // `not-attempted` narrative in this repository asserts that the body IS obtainable
  // from the file store — "so it is replayable from published data" — and that claim is
  // exactly what a run which could not reach the store has failed to establish. Filing
  // it there would trade a false permanence for a false availability. `not-attempted`
  // means the run did not look; this means the run looked and was not answered.
  'body-source-could-not-be-asked': 'body-source-unreachable',
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

/** The property `getPublicCallRequestsWithCalldata()` reads off `data.forPublic` without
 *  testing it. It is the accessor named in `CHAIN_ABSENT_OUTCOMES`' header, and its
 *  `TypeError` is the ONLY trace a private-only transaction left before `private-only`
 *  existed as an outcome. Two spellings because upstream reads both accumulators. */
const PRIVATE_ONLY_CRASH_PROPERTY = /\b(?:non)?[Rr]evertibleAccumulatedData\b/;

/**
 * Was this `refused` row actually a PRIVATE-ONLY transaction crashing the driver?
 *
 * ── WHY THIS PREDICATE EXISTS ─────────────────────────────────────────────────────────
 *
 * `private-only` is not a refusal (see `CHAIN_ABSENT_OUTCOMES`), and before the outcome
 * existed the driver CRASHED on these transactions rather than declining them: upstream's
 * `getPublicCallRequestsWithCalldata()` reads `data.forPublic.nonRevertibleAccumulatedData`
 * and `forPublic` is `undefined` when there is no public half, so `decideOutcome` filed a
 * bare `TypeError` — which `reasonForRuntimeClass` correctly maps to `runtime-refused`,
 * durability **repairable**. Seven committed rows therefore tell a reader that a better
 * runtime would trace them, about transactions that have no public execution at all and
 * never will.
 *
 * ── WHY IT IS SAFE TO DECIDE THIS FROM A COMMITTED ROW ────────────────────────────────
 *
 * The discriminator is already in the data and needs no re-capture: the crash is a
 * `TypeError` naming one of `forPublic`'s two accumulator fields as a property read off
 * `undefined`. That conjunction cannot be produced by any other condition this pipeline
 * files — a runtime that declined by name records its own class, and a `TypeError` from
 * anywhere else in the driver names a different property. It is deliberately NOT a bare
 * `TypeError` test and deliberately NOT a bare substring test on the message: the first
 * would sweep up every unrelated crash, and the second is the shape of misdiagnosis this
 * repository has paid for twice (`putIfAbsent`'s `412`, the refusal-name suffix
 * allowlist).
 *
 * ── WHY IT LIVES HERE ─────────────────────────────────────────────────────────────────
 *
 * `migrate-refusal-reasons.mjs` needs it to classify the committed captures and
 * `refusal-selftest.mjs` needs it to assert they stay classified. A second spelling of a
 * signature is a second thing to keep true — this module's whole reason for existing.
 *
 * @param {{refusal?: string, detail?: string, reason?: string}} row
 */
export function looksLikePrivateOnlyCrash(row) {
  if (row?.refusal !== 'TypeError') return false;
  const said = `${row?.detail ?? ''}`;
  // "Cannot read properties of undefined" is V8's wording for exactly the read upstream
  // makes. The older singular spelling ("property") is accepted because the message
  // changed between Node majors and these rows outlive a Node upgrade.
  if (!/Cannot read propert(?:y|ies) of undefined/.test(said)) return false;
  return PRIVATE_ONLY_CRASH_PROPERTY.test(said);
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

/** The answers from the keyless transaction file store that ESTABLISH the second clause of
 *  `body-unavailable` — "and the file store cannot supply it either".
 *
 *  `absent` is a 404: the store says it does not hold the key. `truncated` is a 200 that is
 *  not a body. `mismatched` is a 200 whose leading 32 bytes are some other transaction's
 *  hash, so the store answered about a different key and holds nothing for this one. All
 *  three are the store SPEAKING ABOUT THIS KEY.
 *
 *  `unavailable` is deliberately absent: a 5xx, a 429, a TLS failure or a timeout is the
 *  store saying nothing at all, which is `body-source-unreachable` and is repairable. That
 *  distinction is `backfill-bodies.mjs`'s and this list is the place it is enforced. */
export const STORE_ANSWERS_MEANING_NO_BODY =
  Object.freeze(['absent', 'truncated', 'mismatched']);

/** Thrown when a producer tries to publish `body-unavailable` without the store's answer.
 *
 *  ── WHY THE GUARD IS HERE AND NOT IN A LINT ──────────────────────────────────────────
 *
 *  `body-unavailable` is declared durability **permanent**: the page it reaches tells a
 *  reader that nothing anyone does to this pipeline will ever produce a trace. Its stated
 *  condition has TWO clauses — the node no longer serves the body, *and* the file store
 *  cannot supply it either — and only the first is observable from the node.
 *
 *  Four producers reached the member having established only the first, because the
 *  condition they named was spelled after that half. 912 committed rows carried the
 *  permanent claim as a result, across block ranges in which the store was later measured
 *  serving bodies 21 times out of 21 — six of them the very rows in question. Nothing in
 *  the pipeline could have caught that, because a producer that has the honest observation
 *  "the node pruned it" had a condition key that accepted it.
 *
 *  So the second clause is now a REQUIRED ARGUMENT rather than an assumption. A producer
 *  that never asked the store cannot supply one and therefore cannot reach this member;
 *  `refuseBodyNotSoughtFromStore` is where it goes instead. A guard that lives in the only
 *  function able to produce the member cannot be bypassed by adding a fifth producer. */
export class BodyUnavailableWithoutStoreEvidence extends Error {
  constructor(storeOutcome, where) {
    super(
      `refuseBodyUnavailable was called with storeOutcome `
      + `${JSON.stringify(storeOutcome ?? null)}, which is not one of `
      + `${STORE_ANSWERS_MEANING_NO_BODY.join(', ')}. \`body-unavailable\` is durability `
      + `PERMANENT and its condition has two clauses — the node no longer serves the body, `
      + `AND the file store cannot supply it either. A producer that only watched the node `
      + `has established the first and not the second, and publishing the member on that `
      + `half is how 912 committed rows came to assert a permanence nobody had checked. If `
      + `this run did not ask the store, the row is \`not-attempted\` and `
      + `\`refuseBodyNotSoughtFromStore\` writes it; if the store could not be reached, it `
      + `is \`body-source-unreachable\` and \`refuseBodySourceUnreachable\` writes it.`
      + (where ? ` (raised by ${where})` : ''));
    this.name = 'BodyUnavailableWithoutStoreEvidence';
    this.storeOutcome = storeOutcome ?? null;
    this.where = where ?? '';
  }
}

/** Did this row record the store being asked and answering that it holds no such body?
 *
 *  The committed-data half of the guard above. `refuseBodyUnavailable`'s callers write the
 *  store's own answer onto the row beside the reason, so the evidence for a permanent claim
 *  travels with the claim and a gate over the corpus can ask for it. A row asserting
 *  `body-unavailable` without one is a row whose second clause nobody checked. */
export function storeWasAskedAndSaidNoBody(row) {
  return STORE_ANSWERS_MEANING_NO_BODY.includes(row?.storeOutcome);
}

/** The node serves the effects, no longer serves the body, AND THE STORE WAS ASKED and
 *  holds no body for this key either. Both clauses, or this throws.
 *
 *  `observedAs` is the ONE clause that legitimately differs between producers: which store
 *  answer arrived, and at what depth the node's prune was observed. The claim about the
 *  chain is identical and is written here.
 *
 *  `storeOutcome` is `classify`'s own answer and is REQUIRED — see
 *  `BodyUnavailableWithoutStoreEvidence`. The caller is expected to put it on the row too,
 *  so the evidence outlives the run that gathered it. */
export function refuseBodyUnavailable({ blockNumber, observedAs, storeOutcome, where }) {
  if (!STORE_ANSWERS_MEANING_NO_BODY.includes(storeOutcome)) {
    throw new BodyUnavailableWithoutStoreEvidence(storeOutcome, where);
  }
  return {
    outcome: 'pruned',
    ...classifyRefusal({
      condition: 'node-pruned-and-store-does-not-hold-it',
      where,
      narrative:
        `The node still serves this transaction's effects but no longer serves its body: `
        + `getTxByHash prunes at the finalized tip and getTxEffect does not. It settled in `
        + `block ${blockNumber} and ${observedAs}. The keyless transaction file store — the `
        + `other publisher of bodies on this chain — was asked for it on this run and `
        + `answered ${storeOutcome}, so nothing serves it: it can no longer be re-executed `
        + `and no trace was recorded for it.`,
    }),
  };
}

/** The node pruned the body and THIS RUN NEVER ASKED THE FILE STORE.
 *
 *  ── THE MEMBER 912 COMMITTED ROWS SHOULD HAVE CARRIED ────────────────────────────────
 *
 *  A follower and a live capture see exactly one thing: `getTxByHash` has stopped answering
 *  for a transaction whose effects `getTxEffect` still serves. That is a true observation
 *  and it is HALF of `body-unavailable`'s condition. Neither producer consults the keyless
 *  `TxFileStore`, so neither has ever established the other half, and on this chain the
 *  other half is measured FALSE far more often than true: 21 of 21 bodies sampled from
 *  block 10 to block 75,969 answered 200 and self-verified, and 12 of 12 from the frozen
 *  mainnet capture did — six of them rows that capture had recorded as `pruned`.
 *
 *  So the honest member is `not-attempted`: the run did not look. `outcome` stays `pruned`
 *  because that IS what the producer observed of the node and it is the vocabulary
 *  `ingest.nim` and four committed fixtures already speak — the correction is to the
 *  published CLAIM, which is the `refusalReason`, not to the observation beside it.
 *
 *  `backfill-blocks.mjs` reached this conclusion first and wrote its own sentence for it;
 *  this is that sentence made shared, for the reason the header gives about the two
 *  paragraphs that had already drifted three ways. */
export function refuseBodyNotSoughtFromStore({ blockNumber, observedAs, where }) {
  return {
    outcome: 'pruned',
    ...classifyRefusal({
      condition: 'node-pruned-body-store-not-asked',
      where,
      narrative:
        `The node no longer serves this transaction's body — getTxByHash prunes at the `
        + `finalized tip and getTxEffect does not, which is why its effects are still `
        + `visible. It settled in block ${blockNumber} and ${observedAs}. That is the `
        + `NODE's answer and it is not the only publisher: the keyless transaction file `
        + `store serves bodies for the whole of this chain's history, and this run never `
        + `asked it. So nothing here says the transaction cannot be re-executed — it says `
        + `this run did not try. Re-running this range with the body proxy asks.`,
    }),
  };
}

/** The body source answered nothing about this key — the outage case, kept apart from
 *  both `body-unavailable` (the store said it does not hold it) and `not-attempted` (we
 *  never asked).
 *
 *  `storeOutcome` and `storeReason` are `classify`'s own answer, passed in rather than
 *  restated, so the row carries the store's words and this function carries the claim. */
export function refuseBodySourceUnreachable({ blockNumber, storeOutcome, storeReason,
                                              where }) {
  return {
    outcome: 'not-attempted',
    ...classifyRefusal({
      condition: 'body-source-could-not-be-asked',
      where,
      narrative:
        `This transaction is first in block ${blockNumber}, so it can be re-executed from `
        + `published data — but the source that serves transaction bodies could not be `
        + `asked about it on this run: ${storeReason || `it answered ${storeOutcome}`} `
        + `Nothing is known about whether the body is held, so nothing here is a `
        + `statement about the chain: re-running this range asks again.`,
    }),
  };
}

/**
 * Which member a row written before ING-3 should carry, decided from the row alone.
 *
 * ── WHY IT IS HERE AND NOT IN THE MIGRATION TOOL ──────────────────────────────────────
 *
 * For the reason `looksLikePrivateOnlyCrash` is here: `migrate-refusal-reasons.mjs` needs
 * it to classify the committed captures and `refusal-selftest.mjs` needs it to assert they
 * stay classified. A second spelling of a classification is a second thing to keep true,
 * and the tool is a SCRIPT — importing it to test its map would run it.
 *
 * ── THE `pruned` ARM IS THE WHOLE POINT ───────────────────────────────────────────────
 *
 * This was a frozen object literal, `FROM_OUTCOME`, whose `pruned: 'body-unavailable'`
 * entry sat under a comment claiming the three non-`refused` outcomes "carry their member
 * in the name and are exact". Two of them do. `pruned` does not: it names the NODE's
 * answer, and `body-unavailable` asserts the node's answer AND the file store's. A static
 * map from a one-clause observation to a two-clause member cannot be exact, and 912
 * committed rows are what that cost.
 *
 * So `pruned` is decided from the row's own evidence rather than from its name. A row
 * carrying the store's negative answer earned the permanent member; a row carrying none is
 * a row nobody asked, which is `not-attempted`.
 *
 * @param {{outcome?: string, refusal?: string, storeOutcome?: string}} row
 * @returns {{member: string|null, why: string}}
 */
export function memberForLegacyUntracedRow(row) {
  const outcome = row?.outcome;
  if (outcome === 'not-first-in-block') {
    return { member: 'not-first-in-block', why: 'the outcome names the member' };
  }
  if (outcome === 'not-attempted') {
    return { member: 'not-attempted', why: 'the outcome names the member' };
  }
  if (outcome === 'refused') {
    return { member: reasonForRuntimeClass(row?.refusal),
             why: `the runtime class the row recorded (${row?.refusal ?? 'none'})` };
  }
  if (outcome === 'pruned') {
    if (storeWasAskedAndSaidNoBody(row)) {
      return { member: 'body-unavailable',
               why: `the node pruned it AND the store answered ${row.storeOutcome} for its `
                    + `key, which is both clauses of the member's condition` };
    }
    return { member: 'not-attempted',
             why: 'the node pruned the body and the row carries no record of the file '
                  + 'store having been asked, so the second clause of `body-unavailable` '
                  + 'was never established — the run did not look' };
  }
  return { member: null, why: `no rule for outcome ${JSON.stringify(outcome ?? null)}` };
}

// ── outcomes ───────────────────────────────────────────────────────────────────────────
//
// The `outcome` field predates this module and four producers write it, so it is closed here
// rather than replaced: replacing it would rewrite `ingest.nim`'s parser and every committed
// fixture in one change, and the milestone is about the reason reaching the page, not about
// renaming the field it travels beside.

// THE THREE LISTS ARE READ FROM `snapshot-format.json`, NOT DECLARED HERE. They were three
// frozen literals in this file, and the format token's own gate — "every untraced row carries
// a reason on `@2`" — has to range over the same definition of untraced that this module
// audits against, on both sides of a seam one of which is Nim. A second copy of the partition
// is a second answer to which rows the version requires the member on. The reasoning behind
// each membership stays here, where it belongs; only the values moved.

/** A transaction with a recording. `divergent` is one: it did not reproduce the block, but a
 *  divergent recording is real, it steps, and Trace-Artifacts.md §6 gives it its own status.
 *  It is NOT a refusal. */
export const TRACED_OUTCOMES = SNAPSHOT_OUTCOMES.traced;

/** A transaction the chain published and this pipeline did not trace. Every one of these
 *  must carry a `refusalReason`. */
export const UNTRACED_OUTCOMES = SNAPSHOT_OUTCOMES.untraced;

/** THE OTHER KIND OF UNTRACED, AND IT IS THE ONE THIS FILE'S HEADER RESERVED `absent` FOR.
 *
 *  A private-only Aztec transaction has NO PUBLIC EXECUTION. Not one this pipeline declined,
 *  not one whose inputs went missing — one that never existed publicly. Its private half ran
 *  in a wallet, was proved, and only its effects were ever published. There is nothing to
 *  re-execute and no runtime, corpus or budget would change that.
 *
 *  IT MUST NOT BE A REFUSAL, and the cost of making it one is measurable rather than
 *  theoretical. Before this outcome existed the driver CRASHED on these — upstream's
 *  `getPublicCallRequestsWithCalldata()` reads `data.forPublic.nonRevertibleAccumulatedData`
 *  and `forPublic` is `undefined` for a private-only transaction — so `decideOutcome` filed
 *  them as `runtime-refused` with `refusal: "TypeError"`. `runtime-refused` is durability
 *  `repairable`, and `tools/capture/expectations.mjs` grades a page on whether its durability
 *  claim is supported by the cause it printed. So every one of these rows told a reader that
 *  a better runtime would trace it. Measured on the historic sample: 21% of first-in-block
 *  transactions in the 68000-68199 window and 9% in 45000-45199, which is not a rounding
 *  error in the answer to "what fraction of this chain is traceable".
 *
 *  THE PUBLISHER SIDE ALREADY HAD THE DISTINCTION AND NOTHING COULD REACH IT.
 *  `blocktracer_client/trace.nim` documents it in so many words: "`absent` with no
 *  `refusalReason` means the chain never published this execution — Aztec's private half —
 *  and nothing was declined. `absent` WITH one means this pipeline could have traced it and
 *  did not." `ingest.nim` maps every untraced outcome to `taAbsent` and copies
 *  `refusalReason` through, empty or not, and the validator permits an empty one. The only
 *  thing missing was a producer able to write the first case, because `auditRefusals`
 *  required a reason id on every untraced row.
 *
 *  A SENTENCE IS STILL MANDATORY. §2.3a's rule is unchanged: `absent` with no explanation is
 *  indistinguishable from a failed fetch. What is dropped is the reason ID, because the
 *  closed set is a set of things WE did, and this is not one of them. */
export const CHAIN_ABSENT_OUTCOMES = SNAPSHOT_OUTCOMES.chainAbsent;

export const OUTCOMES = Object.freeze(
  [...TRACED_OUTCOMES, ...UNTRACED_OUTCOMES, ...CHAIN_ABSENT_OUTCOMES]);

export const isUntracedOutcome = (o) => UNTRACED_OUTCOMES.includes(o);
export const isChainAbsentOutcome = (o) => CHAIN_ABSENT_OUTCOMES.includes(o);

/** The sentence a private-only transaction publishes. Written once, here, for the same
 *  reason `refuseNotFirstInBlock` is: three producers would otherwise spell it three ways.
 *
 *  It deliberately does NOT go through `classifyRefusal` — there is no reason id to choose
 *  and asking for one would be the fold this outcome exists to prevent. */
export function chainPublishedNoPublicExecution({ blockNumber }) {
  return {
    outcome: 'private-only',
    // No `refusalReason` key at all. An empty string would still be a claim that the
    // question was asked; its absence is the statement that it does not apply.
    reason:
      `This transaction has no public execution to trace. Its private half ran in a wallet `
      + `and was proved there; what the chain published for it in block ${blockNumber} is `
      + `the effects of that proof and nothing else, so there is no public bytecode, no `
      + `enqueued call and no execution to re-run. Nothing declined this transaction — the `
      + `execution was never public.`,
  };
}

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
  // COUNTED, AND COUNTED APART. A private-only transaction is untraced and is not a refusal,
  // so it belongs in neither `byReason` nor `unclassified` — but a row in no count at all is
  // the exact defect this function was written for (`not-first-in-block` used to be in none).
  // It gets its own figure and `accountedFor` ranges over both.
  let chainAbsent = 0;
  for (const t of transactions ?? []) {
    if (isChainAbsentOutcome(t?.outcome)) { chainAbsent++; continue; }
    if (!isUntracedOutcome(t?.outcome)) continue;
    if (isRefusalReason(t?.refusalReason)) by[t.refusalReason]++;
    else unclassified++;
  }
  const total = REFUSAL_REASON_IDS.reduce((n, id) => n + by[id], 0);
  // `unclassified` is published rather than thrown on, because a COUNT is a measurement and
  // `auditRefusals` is the gate. A reader of a snapshot must be able to see that the gate
  // has something to say; a counter that silently dropped these would be the original defect
  // in a new place.
  return { byReason: by, total, unclassified, chainAbsent };
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
  let chainAbsent = 0;
  for (const t of transactions ?? []) {
    const hash = t?.txHash ?? '(no txHash)';
    const outcome = t?.outcome;
    if (isChainAbsentOutcome(outcome)) {
      chainAbsent++;
      // The two halves of the distinction, both enforced. A reason id here would say this
      // pipeline declined something, and it did not; a missing SENTENCE would make it
      // indistinguishable from a failed fetch, which is §2.3a's rule and is why the
      // sentence stays mandatory even though the id is forbidden.
      if (t?.refusalReason != null) {
        problems.push(`${hash}: outcome ${outcome} means the chain published no such `
          + `execution and must carry NO refusalReason, but carries `
          + `${JSON.stringify(t.refusalReason)} — that is "we declined" and "it was never `
          + `public" folded into one row`);
      }
      if (typeof t?.reason !== 'string' || t.reason.trim().length === 0) {
        problems.push(`${hash}: outcome ${outcome} carries no stated reason — `
          + `absent with no explanation is indistinguishable from a failed fetch`);
      }
      continue;
    }
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
  return { traced, untraced, chainAbsent, problems };
}

/** The gate. Throws `UnexplainedAbsence` naming every offending transaction. */
export function assertRefusalsAreClosed(transactions) {
  const audit = auditRefusals(transactions);
  if (audit.problems.length) throw new UnexplainedAbsence(audit.problems);
  return audit;
}
