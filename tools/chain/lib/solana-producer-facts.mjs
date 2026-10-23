// solana-producer-facts.mjs — THE FACTS THE SOLANA MAINNET PRODUCER STATES ABOUT THE CHAIN
// IT CAPTURES.
//
// A CLONE, NOT A PARAMETERISATION, for the reason eth-producer-facts.mjs gives in its own
// header: this is a data module for ONE producer. Nothing imports both, nothing selects
// between them, and Chain-Delivery DEL-7 is where a seam may be measured out of the three.
//
// ── WHAT DIFFERS FROM THE ETHEREUM MODULE, MEMBER BY MEMBER ───────────────────────────
//
//   * `PRESTATE_STRATEGY` is `forward-capture`, Chain-Support-Matrix.md §1.4's SEVENTH row,
//     added 2026-10-22 on an operator decision. Solana qualified for none of the six before
//     it (Recorder-Solana CXP-SOL-1, measured: no RPC reads an account at a past slot), and
//     the honest response to that gap was a row there, never a borrowed token here — which
//     is why, until the row existed, the reader refused this producer's trees by name
//     (`S5-PRESTATE-CLOSED`) and they published nothing. The measurement behind the row:
//     1,251 of 1,251 executed transactions matched every fact the chain recorded.
//   * THE COST VECTOR HAS TWO DIMENSIONS, and they are not Ethereum's two. A Solana
//     transaction pays a FEE in lamports (base plus priority, one figure the metadata
//     states) and consumes COMPUTE UNITS, which are metered against a limit but are not
//     themselves priced per unit after the fact. Data-Contract.md §5.3 asks for them as
//     separate entries, each naming itself.
//   * The execution partition has one entry selected `transaction`, as on Ethereum: a
//     Solana transaction's instructions execute atomically as one unit, so there is no
//     public/private half for a selector to name.
//   * Identifiers are base58 (`identifier-encodings.json`), case-significant, 87–88
//     characters for a signature and 43–44 for an address. The producer declares the
//     encoding; it never lowercases.

/** `provenance.recorder` — who recorded this capture's executions, and in what schema. */
export const RECORDER = Object.freeze({ id: 'solana-sbf', traceSchema: 'ctfs/v5' });

/** `provenance.prestateStrategy` — §1.4's seventh row; see the header. */
export const PRESTATE_STRATEGY = 'forward-capture';

/**
 * `provenance.reachReason` — why history starts at `replayableFrom`. Under
 * `forward-capture` the floor is where the capture began reading account state, not a
 * limit of any node, so the reader's generic node-limit sentence would be wrong (CXP-SOL-6).
 */
// A tree may publish a later slice of its capture (the staging tree publishes one slot
// of three), so the sentence names both slots when they differ rather than calling the
// published floor the capture's start.
export const reachReasonFor = (captureStart, fromSlot) => {
  const begun = `this capture began reading account state at slot ${captureStart}, and no RPC serves account state at an earlier slot, so nothing before it can be replayed`;
  return fromSlot === captureStart ? begun : `this tree publishes from slot ${fromSlot}; ${begun}`;
};

/** `provenance.verification` — what the mandatory divergence oracle compares, and the refusal. */
export const VERIFICATION = 'each trace is compared with what the chain recorded for its transaction (error, compute units, fee, logs, balances, token amounts, inner instructions and return data), and a transaction that cannot be compared is refused, never guessed';

/** `provenance.identifierEncoding` — every identifier kind this chain publishes. */
export const IDENTIFIER_ENCODING = Object.freeze({ transaction: 'base58', address: 'base58', block: 'base58' });

/** A source bundle's `language`: positions point into a disassembly of the executable. */
export const POSITION_LANGUAGE = 'sbf-disassembly';

/** A position stream's own `schema` token. */
export const POSITION_STREAM_SCHEMA = 'sbf-disassembly-positions/1';

/** The instruction listing's own `schema` token. */
export const INSTRUCTION_STREAM_SCHEMA = 'sbf-instructions/1';

/** The call-trace stream's own `schema` token. */
export const CALLTRACE_STREAM_SCHEMA = 'sbf-call-frames/1';

/** `sidecar:instructions.isa` — the instruction set, not the chain (see the Ethereum note). */
export const INSTRUCTION_SET = 'sbf';

/**
 * `transactions[].executions` — one entry; an untraced row states its reason on it.
 * A fresh array per call, for the reason the Ethereum module gives.
 */
// DEL-7: the one `*ForRow` helper all five chains had byte-identically (5 definitions,
// 1 distinct text, against 5-in-5 for `costVectorForRow` and `rolesForRow`). The shared
// implementation is `lib/producer-runtime.mjs`; the export keeps its contract name here,
// so this module stays the one place a producer imports its row shapes from.
export { oneExecutionPerTransaction as executionsForRow } from './producer-runtime.mjs';

/**
 * `transactions[].cost` — the fee in lamports and the compute units consumed.
 *
 * `fee.price` is empty: the metadata states the total fee and not a per-unit price (the
 * priority fee is priced per compute unit in the message's ComputeBudget instructions,
 * which this producer does not decode, and a price it derived would be a figure the chain
 * never stated). `computeUnits.limit` is empty for the same reason — the limit lives in
 * the same instructions. `costUnits`, the block-packing cost the scheduler charged, is
 * carried as its own entry when the metadata states it, because it is a third and
 * different number that a reader would otherwise take for one of the first two.
 */
export const costVectorForRow = ({ fee, computeUnitsConsumed, costUnits } = {}) => {
  const v = [
    { name: 'fee', used: String(fee ?? ''), limit: '', price: '', unit: 'lamport', token: 'SOL', refundable: false },
    { name: 'computeUnits', used: String(computeUnitsConsumed ?? ''), limit: '', price: '', unit: 'compute-unit', token: '', refundable: false },
  ];
  if (costUnits !== undefined && costUnits !== null) {
    v.push({ name: 'costUnits', used: String(costUnits), limit: '', price: '', unit: 'cost-unit', token: '', refundable: false });
  }
  return v;
};

/** `transactions[].roles` — the fee payer, which is the first account key and the signer. */
export const rolesForRow = (row) => (row?.feePayer
  ? [{ role: 'sender', address: row.feePayer }]
  : []);

/**
 * `transactions[].payload` — `target` is the first top-level program that is not
 * ComputeBudget (which only sets limits and prices). There is no 4-byte selector on
 * Solana; an Anchor discriminator is 8 bytes and program-specific, so `selector` is empty
 * rather than a borrowed shape. `raw` is empty for the Ethereum module's measured reason.
 */
const COMPUTE_BUDGET = 'ComputeBudget111111111111111111111111111111';
export const payloadForRow = (row) => ({
  raw: '',
  selector: '',
  target: (row?.programs ?? []).find((p) => p !== COMPUTE_BUDGET) ?? '',
});
