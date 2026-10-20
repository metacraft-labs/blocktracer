// solana-producer-facts.mjs — THE FACTS THE SOLANA MAINNET PRODUCER STATES ABOUT THE CHAIN
// IT CAPTURES.
//
// A CLONE, NOT A PARAMETERISATION, for the reason eth-producer-facts.mjs gives in its own
// header: this is a data module for ONE producer. Nothing imports both, nothing selects
// between them, and Chain-Delivery DEL-7 is where a seam may be measured out of the three.
//
// ── WHAT DIFFERS FROM THE ETHEREUM MODULE, MEMBER BY MEMBER ───────────────────────────
//
//   * `PRESTATE_STRATEGY` is `forward-capture`, and it is NOT YET in
//     Chain-Support-Matrix.md §1.4's closed set: the reader refuses it by name
//     (`S5-PRESTATE-CLOSED`), so a tree from this producer publishes nothing until the row
//     exists. That is deliberate. Solana qualifies for none of §1.4's six rows
//     (Recorder-Solana CXP-SOL-1, measured: no RPC reads an account at a past slot), and
//     the honest response to a gap in the table is a row there, never a borrowed token
//     here. The row is requested (codetracer-pm Recorder-Solana "Spine Needs" (a), recorded
//     under Chain-Delivery DEL-3b) with the measurement behind it: 1,251 of 1,251 executed
//     transactions matched every fact the chain recorded.
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

/** `provenance.prestateStrategy` — see the header: requested, not yet in §1.4. */
export const PRESTATE_STRATEGY = 'forward-capture';

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
export const executionsForRow = (reason) => (reason
  ? [{ selector: 'transaction', reason }]
  : [{ selector: 'transaction' }]);

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
