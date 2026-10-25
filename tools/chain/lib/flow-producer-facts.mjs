// lib/flow-producer-facts.mjs — FLOW MAINNET's constant facts, as `produce-flow-snapshot.mjs`
// publishes them.
//
// A clone of `eth-producer-facts.mjs`'s shape and not a widening of it, as that file and
// `producer-facts.mjs` both ask: a chain's recorder is a separate tool with a file like this
// of its own. Chain-Delivery DEL-6 is the second consumer the EVM producer was written to
// wait for, and DEL-7 is where the two may be compared and a seam extracted.

/** `provenance.recorder` — who recorded this capture's executions, and in what schema. */
export const RECORDER = Object.freeze({ id: 'flow-cadence', traceSchema: 'ctfs/v5' });

/**
 * `provenance.prestateStrategy` — one of Chain-Support-Matrix.md §1.4's six.
 *
 * `replay-preceding`: the helper reads the registers the block STARTED from (the access
 * node's state at height - 1) and re-executes the transactions before the target in the
 * block, in order, so the target runs on the state it ran on. Declared in advance in
 * `tools/chain/yield-method.json`'s `pinned.flow`.
 */
export const PRESTATE_STRATEGY = 'replay-preceding';

/**
 * `provenance.reachReason` — why history starts at `replayableFrom`. On Flow that floor is
 * the access node's RETENTION, not the chain's: a node serves state only from its own
 * spork's root, and earlier sporks are served, if at all, by earlier sporks' nodes
 * (Recorder-Flow CXP-FLOW-1; `tools/chain/flow-floor-census.mjs` measures which still do).
 * The reader's generic sentence would read as the start of the chain's history.
 */
export const reachReasonFor = (probe) => `the access node this capture read (${probe.accessNode}) `
  + `serves state only from its own spork's root, block ${probe.floor}, and refuses the block `
  + 'below it. That is the node\'s retention, an operational limit: earlier sporks are served '
  + 'only by their own nodes, so it is not where the chain\'s history begins';

/**
 * `provenance.verification` — what each trace is checked against, where its source comes
 * from, and what becomes of a transaction that cannot be checked (Source-Resolution.md §4:
 * a source that does not hash to the code that ran is discarded).
 */
export const VERIFICATION = 'each transaction is re-executed by the network\'s own FVM and '
  + 'compared with what the chain recorded (status, every event with its values, and the '
  + 'computation), and one that does not match is published as divergent, never as a '
  + 'trace of the chain. Its Cadence source is the contract code the execution read from '
  + 'chain state, so no third party supplies it, and a file that does not hash to that '
  + 'code is discarded';

/** A source bundle's `language`: these positions are positions in Cadence source text. */
export const POSITION_LANGUAGE = 'cadence';

/** A position stream's own `schema` token. */
export const POSITION_STREAM_SCHEMA = 'cadence-positions/1';

/** The call-trace stream's own `schema` token. */
export const CALLTRACE_STREAM_SCHEMA = 'cadence-call-frames/1';

/**
 * `provenance.vm.instructionSet` — the executable, formally defined format a Cadence
 * program on this chain is executed from, which Configuration.md §2.1 is the definition
 * of and which is broader than a bytecode ISA.
 *
 * STILL NO INSTRUCTION LISTING, and that is unchanged: Cadence is executed from its AST,
 * statement by statement, so a step IS a statement and this producer publishes no
 * `instructions/` sidecar rather than one with nothing in it. What changed on 2026-10-22
 * is that the member no longer travels inside a listing — it is declared on this
 * capture's `provenance.vm` and the reader publishes it onto the registry row, so a
 * chain without listings states its format like any other.
 *
 * `cadence-ast` AND NOT `cadence-interpreter`, which is what this constant said while
 * nothing imported it. The convention is read off the four chains that already declare
 * one — `evm`, `sbf`, `cairo`, `move` — and it has two rules, both stated in those
 * modules rather than inferred here. The token names the FORMAT, not the chain: the
 * Ethereum note says `evm` and not `ethereum-evm` because "the EVM's table is the same
 * on Base, Arbitrum and every other EVM instance", and the Starknet note says `cairo`
 * "is the same on every chain that runs the Cairo VM, so it names no chain". And the
 * token is the STEM its sibling schema tokens are built from — `evm` under
 * `evm-disassembly` and `evm-instructions/1`, `cairo` under `cairo-casm`, `sbf` under
 * `sbf-disassembly` — with the suffix naming the FORM the artifact is in where a stem
 * alone would not say.
 *
 * `cadence-interpreter` keeps the stem and FAILS THE FIRST RULE, which is the one that
 * decides: an interpreter is the EXECUTOR, a fact about one implementation of the runtime
 * rather than about the format a program is in, and nothing a consumer can select a table
 * or a renderer by. `cadence-ast` takes
 * the stem the sibling tokens here already use (`cadence`, `cadence-positions/1`,
 * `cadence-call-frames/1`) and names the form: the AST. The form is qualified rather
 * than left bare for the reason `cairo-casm` is qualified where `cairo` is not — a bare
 * `cadence` would be the only thing available to name a compiled Cadence too, and the
 * one job of this token is to say how a program is read.
 */
export const INSTRUCTION_SET = 'cadence-ast';

/** `transactions[].executions` — one transaction, one execution. */
// DEL-7: the one `*ForRow` helper all five chains had byte-identically (5 definitions,
// 1 distinct text, against 5-in-5 for `costVectorForRow` and `rolesForRow`). The shared
// implementation is `lib/producer-runtime.mjs`; the export keeps its contract name here,
// so this module stays the one place a producer imports its row shapes from.
export { oneExecutionPerTransaction as executionsForRow } from './producer-runtime.mjs';

/**
 * `transactions[].roles` — Flow's authorization trio, kept a trio.
 *
 * A Flow transaction names a PROPOSER (whose key's sequence number it consumes), a PAYER
 * (who pays the fee) and one or more AUTHORIZERS (whose accounts the `prepare` block may
 * act on), and the three are routinely different accounts: the payer is often an
 * application paying for its users. Each is published as its own role and none is
 * promoted to a `sender`, which on this chain would be wrong about who paid and who
 * authorised in one field. The words are the explorer's: `initiator` for the proposer,
 * `feePayer` for the payer and `signer` for each authorizer, which `reader.nim`'s `From`
 * column already recognises, taking `feePayer` first.
 *
 * An account that fills several roles is published once PER ROLE, so the shape does not
 * change with how many distinct accounts a transaction happened to use. A role whose
 * address is empty — the protocol's own transactions have no payer — is dropped rather
 * than published as a link to nowhere.
 *
 * @param {{proposer: string, payer: string, authorizers: string[]}} tx
 * @returns {{role: string, address: string}[]}
 */
export const rolesForRow = (tx) => [
  { role: 'feePayer', address: tx.payer },
  { role: 'initiator', address: tx.proposer },
  ...(tx.authorizers ?? []).map((a) => ({ role: 'signer', address: a })),
].filter((r) => /^0x[0-9a-f]{16}$/.test(r.address ?? '')
  && r.address !== '0x0000000000000000');

/**
 * `transactions[].cost` — Flow's fee as the vector it is.
 *
 * The chain's own record of what was charged is the `FlowFees.FeesDeducted` event the
 * transaction emitted: the fee in FLOW and the two efforts it was computed from. Those
 * three are published verbatim, as strings, beside the computation the FVM metered
 * against the sender's limit. A transaction whose result carries no `FeesDeducted` event
 * publishes the computation entry alone; a fee this tool computed itself would be a
 * figure nobody measured.
 *
 * @param {{computationUsed: number, gasLimit: number, events: {type: string, value: string}[]}} f
 */
export const costVectorForRow = ({ computationUsed, gasLimit, events }) => {
  const v = [{
    name: 'computation',
    used: String(computationUsed ?? ''),
    limit: String(gasLimit ?? ''),
    price: '',
    unit: 'computation',
    token: 'FLOW',
    refundable: false,
  }];
  const fees = (events ?? []).find((e) => /\.FlowFees\.FeesDeducted$/.test(e.type));
  if (fees) {
    const field = (name) => {
      const m = new RegExp(`${name}: ([0-9.]+)`).exec(fees.value);
      return m ? m[1] : '';
    };
    v.push(
      { name: 'fee', used: field('amount'), limit: '', price: '', unit: 'FLOW',
        token: 'FLOW', refundable: false },
      { name: 'executionEffort', used: field('executionEffort'), limit: '', price: '',
        unit: 'effort', token: 'FLOW', refundable: false },
      { name: 'inclusionEffort', used: field('inclusionEffort'), limit: '', price: '',
        unit: 'effort', token: 'FLOW', refundable: false },
    );
  }
  return v;
};
