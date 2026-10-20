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

/** A source bundle's `language`: these positions are positions in Cadence source text. */
export const POSITION_LANGUAGE = 'cadence';

/** A position stream's own `schema` token. */
export const POSITION_STREAM_SCHEMA = 'cadence-positions/1';

/** The call-trace stream's own `schema` token. */
export const CALLTRACE_STREAM_SCHEMA = 'cadence-call-frames/1';

/**
 * `vm.instructionSet`. Cadence is interpreted from its AST, statement by statement, so
 * there is no instruction set and no instruction listing: a step IS a statement, and this
 * producer publishes no `instructions/` sidecar rather than one with nothing in it.
 */
export const INSTRUCTION_SET = 'cadence-interpreter';

/** `transactions[].executions` — one transaction, one execution. */
export const executionsForRow = (reason) => (reason
  ? [{ selector: 'transaction', reason }]
  : [{ selector: 'transaction' }]);

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
